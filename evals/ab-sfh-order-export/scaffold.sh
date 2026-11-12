#!/usr/bin/env bash
set -euo pipefail

mkdir -p cmd/exporter internal/config internal/export internal/upload

cat > go.mod <<'EOF'
module example.com/orderexport

go 1.22
EOF

cat > README.md <<'EOF'
# orderexport

Daily job: reads the day's orders (JSON lines), writes them to a CSV file and
uploads the file to the warehouse API. The scheduler re-runs a day whose run
exits non-zero.

    go run ./cmd/exporter -day 2026-11-11 -orders orders.jsonl
EOF

cat > internal/config/config.go <<'EOF'
package config

import (
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"log"
	"os"
)

type Config struct {
	OutputDir   string `json:"output_dir"`
	UploadURL   string `json:"upload_url"`
	MaxAttempts int    `json:"max_attempts"`
}

func Default() Config {
	return Config{
		OutputDir:   "out",
		UploadURL:   "http://warehouse.internal/v1/exports",
		MaxAttempts: 3,
	}
}

// Load reads an optional JSON config file. A missing file is not an error:
// the exporter ships without one and runs on Default() values, and says so in
// the log. Any other read or parse error is returned.
func Load(path string) (Config, error) {
	cfg := Default()
	data, err := os.ReadFile(path)
	if errors.Is(err, fs.ErrNotExist) {
		log.Printf("config %s not found, using defaults", path)
		return cfg, nil
	}
	if err != nil {
		return Config{}, fmt.Errorf("read config %s: %w", path, err)
	}
	if err := json.Unmarshal(data, &cfg); err != nil {
		return Config{}, fmt.Errorf("parse config %s: %w", path, err)
	}
	if cfg.MaxAttempts < 1 {
		return Config{}, fmt.Errorf("config %s: max_attempts must be at least 1", path)
	}
	return cfg, nil
}
EOF

cat > internal/export/source.go <<'EOF'
package export

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"os"
)

type Order struct {
	ID         string `json:"id"`
	TotalCents int64  `json:"total_cents"`
	Status     string `json:"status"`
}

// ReadOrders parses a JSON-lines file. A malformed line fails the whole read:
// a partial export would look complete to the warehouse.
func ReadOrders(path string) ([]Order, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("open orders: %w", err)
	}
	defer f.Close() // opened read-only: a Close error cannot lose data

	var orders []Order
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	line := 0
	for sc.Scan() {
		line++
		if len(bytes.TrimSpace(sc.Bytes())) == 0 {
			continue
		}
		var raw struct {
			ID         string `json:"id"`
			TotalCents *int64 `json:"total_cents"`
			Status     string `json:"status"`
		}
		if err := json.Unmarshal(sc.Bytes(), &raw); err != nil {
			return nil, fmt.Errorf("orders line %d: %w", line, err)
		}
		if raw.ID == "" || raw.TotalCents == nil || raw.Status == "" {
			return nil, fmt.Errorf("orders line %d: missing id, total_cents or status", line)
		}
		orders = append(orders, Order{ID: raw.ID, TotalCents: *raw.TotalCents, Status: raw.Status})
	}
	if err := sc.Err(); err != nil {
		return nil, fmt.Errorf("read orders: %w", err)
	}
	return orders, nil
}
EOF

cat > internal/export/writer.go <<'EOF'
package export

import (
	"encoding/csv"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
)

// WriteCSV writes orders to path atomically: a temp file in the same
// directory is renamed over path only after every byte is flushed, synced
// and closed without error.
func WriteCSV(path string, orders []Order) (err error) {
	tmp, err := os.CreateTemp(filepath.Dir(path), ".export-*.csv")
	if err != nil {
		return fmt.Errorf("create temp file: %w", err)
	}
	defer func() {
		if err != nil {
			// Cleanup on a path that is already failing: err is what the
			// caller sees. A second Close or a failed Remove changes nothing
			// for the caller, and path itself was never touched.
			_ = tmp.Close()
			_ = os.Remove(tmp.Name())
		}
	}()

	w := csv.NewWriter(tmp)
	if err = w.Write([]string{"id", "total_cents", "status"}); err != nil {
		return fmt.Errorf("write header: %w", err)
	}
	for _, o := range orders {
		rec := []string{o.ID, strconv.FormatInt(o.TotalCents, 10), o.Status}
		if err = w.Write(rec); err != nil {
			return fmt.Errorf("write order %s: %w", o.ID, err)
		}
	}
	w.Flush()
	if err = w.Error(); err != nil {
		return fmt.Errorf("flush csv: %w", err)
	}
	if err = tmp.Sync(); err != nil {
		return fmt.Errorf("sync %s: %w", tmp.Name(), err)
	}
	if err = tmp.Close(); err != nil {
		return fmt.Errorf("close %s: %w", tmp.Name(), err)
	}
	if err = os.Rename(tmp.Name(), path); err != nil {
		return fmt.Errorf("rename to %s: %w", path, err)
	}
	return nil
}
EOF

cat > internal/export/job.go <<'EOF'
package export

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
)

type Uploader interface {
	Upload(ctx context.Context, key string, body []byte) error
}

// Run exports one day's orders: read, write the CSV, upload it. Every failure
// is returned; main exits non-zero so the scheduler re-runs the day.
func Run(ctx context.Context, day, ordersPath, outDir string, up Uploader) (int, error) {
	orders, err := ReadOrders(ordersPath)
	if err != nil {
		return 0, err
	}
	out := filepath.Join(outDir, "orders-"+day+".csv")
	if err := WriteCSV(out, orders); err != nil {
		return 0, fmt.Errorf("write %s: %w", out, err)
	}
	body, err := os.ReadFile(out)
	if err != nil {
		return 0, fmt.Errorf("reread %s: %w", out, err)
	}
	if err := up.Upload(ctx, "orders-"+day, body); err != nil {
		return 0, err
	}
	return len(orders), nil
}
EOF

cat > internal/upload/client.go <<'EOF'
package upload

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"log"
	"net/http"
	"time"
)

type Client struct {
	URL         string
	HTTP        *http.Client
	MaxAttempts int
	Backoff     time.Duration
}

// Upload posts an export file. Every attempt carries the same
// Idempotency-Key, so a retry after a lost response cannot create a second
// import on the warehouse side. Only network errors, 429 and 5xx are
// retried; the last error is returned once attempts run out.
func (c *Client) Upload(ctx context.Context, key string, body []byte) error {
	var lastErr error
	for attempt := 1; attempt <= c.MaxAttempts; attempt++ {
		retry, err := c.try(ctx, key, body)
		if err == nil {
			return nil
		}
		lastErr = err
		if !retry || attempt == c.MaxAttempts {
			break
		}
		log.Printf("upload %s attempt %d/%d failed, retrying: %v", key, attempt, c.MaxAttempts, err)
		select {
		case <-ctx.Done():
			return fmt.Errorf("upload %s: %w (last error: %v)", key, ctx.Err(), lastErr)
		case <-time.After(c.Backoff * time.Duration(attempt)):
		}
	}
	return fmt.Errorf("upload %s: %w", key, lastErr)
}

func (c *Client) try(ctx context.Context, key string, body []byte) (retry bool, err error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.URL, bytes.NewReader(body))
	if err != nil {
		return false, err
	}
	req.Header.Set("Content-Type", "text/csv")
	req.Header.Set("Idempotency-Key", key)

	resp, err := c.HTTP.Do(req)
	if err != nil {
		return ctx.Err() == nil, err
	}
	defer resp.Body.Close()

	// The body only matters as text for an error message; the status code
	// alone decides success, so a failed read here just shortens the message.
	msg, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
	switch {
	case resp.StatusCode >= 200 && resp.StatusCode < 300:
		return false, nil
	case resp.StatusCode == http.StatusTooManyRequests || resp.StatusCode >= 500:
		return true, fmt.Errorf("warehouse returned %d: %s", resp.StatusCode, msg)
	default:
		return false, fmt.Errorf("warehouse returned %d: %s", resp.StatusCode, msg)
	}
}
EOF

cat > cmd/exporter/main.go <<'EOF'
package main

import (
	"context"
	"flag"
	"log"
	"net/http"
	"os"
	"time"

	"example.com/orderexport/internal/config"
	"example.com/orderexport/internal/export"
	"example.com/orderexport/internal/upload"
)

func main() {
	cfgPath := flag.String("config", "exporter.json", "optional config file")
	day := flag.String("day", time.Now().UTC().AddDate(0, 0, -1).Format("2006-01-02"), "day to export")
	orders := flag.String("orders", "orders.jsonl", "orders file (JSON lines)")
	flag.Parse()

	cfg, err := config.Load(*cfgPath)
	if err != nil {
		log.Fatal(err)
	}
	if err := os.MkdirAll(cfg.OutputDir, 0o755); err != nil {
		log.Fatal(err)
	}
	up := &upload.Client{
		URL:         cfg.UploadURL,
		HTTP:        &http.Client{Timeout: 30 * time.Second},
		MaxAttempts: cfg.MaxAttempts,
		Backoff:     2 * time.Second,
	}
	n, err := export.Run(context.Background(), *day, *orders, cfg.OutputDir, up)
	if err != nil {
		log.Fatalf("export %s failed: %v", *day, err)
	}
	log.Printf("exported %d orders for %s", n, *day)
}
EOF

git init -q . && git config user.email dev@example.com && git config user.name dev && git add -A && git commit -qm init
