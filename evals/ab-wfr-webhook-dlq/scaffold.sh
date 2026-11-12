#!/usr/bin/env bash
set -euo pipefail

mkdir -p cmd/hookd docs internal/api internal/config internal/delivery internal/metrics internal/signing internal/store
cat > README.md <<'__EOF__'
# hookd

Delivers webhooks for our customers. A customer registers endpoints (URLs) under
their account, we POST each event to every endpoint of the account, sign it with
the endpoint's secret, and retry failures with exponential backoff.

    go run ./cmd/hookd -config config.json

- `internal/api`: the customer-facing HTTP API (API key per account).
- `internal/store`: endpoints and pending deliveries, persisted to one JSON
  file after every change.
- `internal/delivery`: the worker that sends due deliveries and retries them.
- `internal/signing`: the signature scheme receivers verify
  (`docs/receivers.md`).

Deleting an endpoint discards its pending deliveries.
__EOF__
cat > cmd/hookd/main.go <<'__EOF__'
// Command hookd runs the webhook API and the delivery worker.
package main

import (
	"context"
	"errors"
	"flag"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"example.com/hookd/internal/api"
	"example.com/hookd/internal/config"
	"example.com/hookd/internal/delivery"
	"example.com/hookd/internal/store"
)

func main() {
	path := flag.String("config", "config.json", "path to the config file")
	flag.Parse()
	logger := log.New(os.Stderr, "hookd ", log.LstdFlags)

	cfg, err := config.Load(*path)
	if err != nil {
		logger.Fatal(err)
	}
	st, err := store.Open(cfg.DataFile)
	if err != nil {
		logger.Fatal(err)
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	worker := &delivery.Worker{
		Store:       st,
		Sender:      delivery.NewHTTPSender(time.Duration(cfg.DeliveryTimeoutSeconds) * time.Second),
		MaxAttempts: cfg.MaxAttempts,
		Now:         time.Now,
		Log:         logger,
	}
	go worker.Run(ctx)

	srv := &http.Server{
		Addr:              cfg.Listen,
		Handler:           (&api.Server{Store: st, Keys: cfg.APIKeys, Now: time.Now}).Routes(),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       30 * time.Second,
		WriteTimeout:      30 * time.Second,
	}
	go func() {
		<-ctx.Done()
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		_ = srv.Shutdown(shutdownCtx)
	}()
	logger.Printf("listening on %s", cfg.Listen)
	if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		logger.Fatal(err)
	}
}
__EOF__
cat > config.example.json <<'__EOF__'
{
  "listen": ":8080",
  "data_file": "/var/lib/hookd/state.json",
  "api_keys": {"key_live_acme": "acct_acme"},
  "delivery_timeout_seconds": 10,
  "max_attempts": 8
}
__EOF__
cat > docs/receivers.md <<'__EOF__'
# Verifying hookd webhooks

Every delivery is a `POST` with a JSON body and these headers:

- `Hookd-Delivery`: the delivery id. Retries of one delivery reuse it, so use
  it to drop duplicates.
- `Hookd-Event`: the event type.
- `Hookd-Signature`: `t=<unix seconds>,v1=<hex>`.

To verify, compute HMAC-SHA256 with your endpoint secret over
`<t>.<raw body>` and compare it with `v1` in constant time. Reject the request
if `t` is more than 5 minutes from your clock.

Answer with any 2xx status within 10 seconds to acknowledge. Redirects are not
followed: a 3xx counts as a failed attempt, so register the final URL.
Anything else is retried with exponential backoff.
__EOF__
cat > go.mod <<'__EOF__'
module example.com/hookd

go 1.22
__EOF__
cat > internal/api/auth.go <<'__EOF__'
package api

import (
	"context"
	"crypto/subtle"
	"net/http"
	"strings"
)

type ctxKey struct{}

// auth resolves the bearer API key to an account and rejects unknown keys.
func (s *Server) auth(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		key, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
		if !ok {
			writeError(w, http.StatusUnauthorized, "missing API key")
			return
		}
		account := ""
		for k, acct := range s.Keys {
			if subtle.ConstantTimeCompare([]byte(k), []byte(key)) == 1 {
				account = acct
			}
		}
		if account == "" {
			writeError(w, http.StatusUnauthorized, "unknown API key")
			return
		}
		next(w, r.WithContext(context.WithValue(r.Context(), ctxKey{}, account)))
	}
}

func accountOf(r *http.Request) string {
	return r.Context().Value(ctxKey{}).(string)
}
__EOF__
cat > internal/api/handlers.go <<'__EOF__'
// Package api is the customer-facing HTTP API.
package api

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net/http"
	"net/url"
	"time"

	"example.com/hookd/internal/store"
)

const maxBody = 1 << 20

type Server struct {
	Store *store.Store
	// Keys maps API key -> account id.
	Keys map[string]string
	Now  func() time.Time
}

type endpointView struct {
	ID        string    `json:"id"`
	URL       string    `json:"url"`
	CreatedAt time.Time `json:"created_at"`
}

func view(ep store.Endpoint) endpointView {
	return endpointView{ID: ep.ID, URL: ep.URL, CreatedAt: ep.CreatedAt}
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func writeError(w http.ResponseWriter, status int, msg string) {
	writeJSON(w, status, map[string]string{"error": msg})
}

// decode reads a JSON body of at most maxBody bytes. It writes the error
// response itself and returns false on failure.
func decode(w http.ResponseWriter, r *http.Request, v any) bool {
	err := json.NewDecoder(http.MaxBytesReader(w, r.Body, maxBody)).Decode(v)
	var tooBig *http.MaxBytesError
	switch {
	case err == nil:
		return true
	case errors.As(err, &tooBig):
		writeError(w, http.StatusRequestEntityTooLarge, "body too large")
	default:
		writeError(w, http.StatusBadRequest, "invalid JSON body")
	}
	return false
}

func newID(prefix string) string {
	b := make([]byte, 12)
	if _, err := rand.Read(b); err != nil {
		panic(err) // crypto/rand never fails on supported platforms
	}
	return prefix + hex.EncodeToString(b)
}

// ownedEndpoint loads the {id} endpoint if it belongs to the caller's account.
// Anything else is a 404, so ids of other accounts are not revealed.
func (s *Server) ownedEndpoint(w http.ResponseWriter, r *http.Request) (store.Endpoint, bool) {
	ep, ok := s.Store.Endpoint(r.PathValue("id"))
	if !ok || ep.AccountID != accountOf(r) {
		writeError(w, http.StatusNotFound, "endpoint not found")
		return store.Endpoint{}, false
	}
	return ep, true
}

func (s *Server) createEndpoint(w http.ResponseWriter, r *http.Request) {
	var req struct {
		URL string `json:"url"`
	}
	if !decode(w, r, &req) {
		return
	}
	u, err := url.Parse(req.URL)
	if err != nil || u.Scheme != "https" || u.Host == "" {
		writeError(w, http.StatusBadRequest, "url must be an absolute https URL")
		return
	}
	ep := store.Endpoint{
		ID:        newID("ep_"),
		AccountID: accountOf(r),
		URL:       u.String(),
		Secret:    newID("whsec_"),
		CreatedAt: s.Now().UTC(),
	}
	if err := s.Store.CreateEndpoint(ep); err != nil {
		writeError(w, http.StatusInternalServerError, "could not save endpoint")
		return
	}
	// The secret is shown once, here; receivers need it to verify signatures.
	writeJSON(w, http.StatusCreated, map[string]any{"endpoint": view(ep), "secret": ep.Secret})
}

func (s *Server) listEndpoints(w http.ResponseWriter, r *http.Request) {
	views := []endpointView{}
	for _, ep := range s.Store.EndpointsFor(accountOf(r)) {
		views = append(views, view(ep))
	}
	writeJSON(w, http.StatusOK, map[string]any{"endpoints": views})
}

func (s *Server) deleteEndpoint(w http.ResponseWriter, r *http.Request) {
	ep, ok := s.ownedEndpoint(w, r)
	if !ok {
		return
	}
	if err := s.Store.DeleteEndpoint(ep.ID); err != nil {
		writeError(w, http.StatusInternalServerError, "could not delete endpoint")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) postEvent(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Type    string          `json:"type"`
		Payload json.RawMessage `json:"payload"`
	}
	if !decode(w, r, &req) {
		return
	}
	if req.Type == "" || len(req.Payload) == 0 {
		writeError(w, http.StatusBadRequest, "type and payload are required")
		return
	}
	now := s.Now().UTC()
	var ds []store.Delivery
	for _, ep := range s.Store.EndpointsFor(accountOf(r)) {
		ds = append(ds, store.Delivery{
			ID:            newID("dl_"),
			EndpointID:    ep.ID,
			EventType:     req.Type,
			Payload:       req.Payload,
			NextAttemptAt: now,
		})
	}
	if err := s.Store.Enqueue(ds); err != nil {
		writeError(w, http.StatusInternalServerError, "could not queue event")
		return
	}
	writeJSON(w, http.StatusAccepted, map[string]int{"deliveries": len(ds)})
}
__EOF__
cat > internal/api/handlers_test.go <<'__EOF__'
package api

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"example.com/hookd/internal/store"
)

func newServer(t *testing.T) *Server {
	t.Helper()
	st, err := store.Open(filepath.Join(t.TempDir(), "state.json"))
	if err != nil {
		t.Fatal(err)
	}
	return &Server{
		Store: st,
		Keys:  map[string]string{"key_a": "acct_a", "key_b": "acct_b"},
		Now:   func() time.Time { return time.Date(2026, 3, 2, 9, 0, 0, 0, time.UTC) },
	}
}

func call(t *testing.T, h http.Handler, method, path, key, body string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(method, path, strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+key)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	return rec
}

func createEP(t *testing.T, h http.Handler, key string) string {
	t.Helper()
	rec := call(t, h, "POST", "/endpoints", key, `{"url":"https://example.test/hook"}`)
	if rec.Code != http.StatusCreated {
		t.Fatalf("create: %d %s", rec.Code, rec.Body)
	}
	var out struct {
		Endpoint struct{ ID string } `json:"endpoint"`
	}
	json.Unmarshal(rec.Body.Bytes(), &out)
	return out.Endpoint.ID
}

func TestCreateListDelete(t *testing.T) {
	s := newServer(t)
	h := s.Routes()
	id := createEP(t, h, "key_a")
	if rec := call(t, h, "GET", "/endpoints", "key_a", ""); !strings.Contains(rec.Body.String(), id) {
		t.Fatalf("list misses %s: %s", id, rec.Body)
	}
	if rec := call(t, h, "GET", "/endpoints", "key_a", ""); strings.Contains(rec.Body.String(), "whsec_") {
		t.Fatal("list must not show secrets")
	}
	if rec := call(t, h, "DELETE", "/endpoints/"+id, "key_b", ""); rec.Code != http.StatusNotFound {
		t.Fatalf("other account delete: want 404, got %d", rec.Code)
	}
	if rec := call(t, h, "DELETE", "/endpoints/"+id, "key_a", ""); rec.Code != http.StatusNoContent {
		t.Fatalf("delete: %d", rec.Code)
	}
}

func TestEventFansOutToAccountEndpointsOnly(t *testing.T) {
	s := newServer(t)
	h := s.Routes()
	createEP(t, h, "key_a")
	createEP(t, h, "key_a")
	createEP(t, h, "key_b")
	rec := call(t, h, "POST", "/events", "key_a", `{"type":"order.paid","payload":{"id":1}}`)
	if rec.Code != http.StatusAccepted || !strings.Contains(rec.Body.String(), `"deliveries":2`) {
		t.Fatalf("got %d %s", rec.Code, rec.Body)
	}
}

func TestRejectsBadInput(t *testing.T) {
	h := newServer(t).Routes()
	if rec := call(t, h, "POST", "/endpoints", "key_a", `{"url":"http://example.test"}`); rec.Code != 400 {
		t.Fatalf("http url: want 400, got %d", rec.Code)
	}
	big := `{"type":"x","payload":"` + strings.Repeat("a", maxBody) + `"}`
	if rec := call(t, h, "POST", "/events", "key_a", big); rec.Code != 413 {
		t.Fatalf("big body: want 413, got %d", rec.Code)
	}
	if rec := call(t, h, "GET", "/endpoints", "nope", ""); rec.Code != 401 {
		t.Fatalf("bad key: want 401, got %d", rec.Code)
	}
}
__EOF__
cat > internal/api/router.go <<'__EOF__'
package api

import (
	"net/http"

	"example.com/hookd/internal/metrics"
)

func (s *Server) Routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("POST /endpoints", s.auth(s.createEndpoint))
	mux.HandleFunc("GET /endpoints", s.auth(s.listEndpoints))
	mux.HandleFunc("DELETE /endpoints/{id}", s.auth(s.deleteEndpoint))
	mux.HandleFunc("POST /events", s.auth(s.postEvent))
	mux.HandleFunc("GET /metrics", metrics.Handler)
	return mux
}
__EOF__
cat > internal/config/config.go <<'__EOF__'
// Package config loads hookd's JSON config file.
package config

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
)

type Config struct {
	Listen   string `json:"listen"`
	DataFile string `json:"data_file"`
	// APIKeys maps an API key to the account it belongs to.
	APIKeys map[string]string `json:"api_keys"`
	// DeliveryTimeoutSeconds bounds one HTTP attempt.
	DeliveryTimeoutSeconds int `json:"delivery_timeout_seconds"`
	// MaxAttempts is how many times a delivery is tried before it is dropped.
	MaxAttempts int `json:"max_attempts"`
}

func Load(path string) (*Config, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	dec := json.NewDecoder(f)
	dec.DisallowUnknownFields()
	var c Config
	if err := dec.Decode(&c); err != nil {
		return nil, fmt.Errorf("config %s: %w", path, err)
	}
	if err := c.Validate(); err != nil {
		return nil, fmt.Errorf("config %s: %w", path, err)
	}
	return &c, nil
}

func (c *Config) Validate() error {
	switch {
	case c.Listen == "":
		return errors.New("listen is required")
	case c.DataFile == "":
		return errors.New("data_file is required")
	case len(c.APIKeys) == 0:
		return errors.New("api_keys is empty")
	case c.DeliveryTimeoutSeconds < 1 || c.DeliveryTimeoutSeconds > 60:
		return errors.New("delivery_timeout_seconds must be 1..60")
	case c.MaxAttempts < 1 || c.MaxAttempts > 10:
		return errors.New("max_attempts must be 1..10")
	}
	return nil
}
__EOF__
cat > internal/delivery/backoff.go <<'__EOF__'
package delivery

import "time"

const (
	baseDelay = time.Second
	maxDelay  = time.Hour
)

// Backoff is the wait before the next attempt after `attempt` failures.
func Backoff(attempt int) time.Duration {
	d := baseDelay << attempt
	if d > maxDelay {
		d = maxDelay
	}
	return d
}
__EOF__
cat > internal/delivery/client.go <<'__EOF__'
package delivery

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"net/http"
	"time"

	"example.com/hookd/internal/signing"
	"example.com/hookd/internal/store"
)

// StatusError is a non-2xx answer from the receiver.
type StatusError struct{ Code int }

func (e *StatusError) Error() string { return fmt.Sprintf("receiver answered %d", e.Code) }

type Sender interface {
	Send(ctx context.Context, ep store.Endpoint, d store.Delivery) error
}

type HTTPSender struct {
	Client *http.Client
	Now    func() time.Time
}

func NewHTTPSender(timeout time.Duration) *HTTPSender {
	return &HTTPSender{
		Client: &http.Client{
			Timeout: timeout,
			// Never follow redirects: that would re-send a signed payload to a
			// URL the customer did not register. The 3xx comes back as the
			// response and counts as a failed attempt (docs/receivers.md).
			CheckRedirect: func(*http.Request, []*http.Request) error {
				return http.ErrUseLastResponse
			},
		},
		Now: time.Now,
	}
}

func (s *HTTPSender) Send(ctx context.Context, ep store.Endpoint, d store.Delivery) error {
	ts := s.Now().Unix()
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, ep.URL, bytes.NewReader(d.Payload))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Hookd-Delivery", d.ID)
	req.Header.Set("Hookd-Event", d.EventType)
	req.Header.Set("Hookd-Signature", signing.Header(ep.Secret, ts, d.Payload))
	resp, err := s.Client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	// Drain a little so the connection can be reused.
	_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 64<<10))
	if resp.StatusCode < 200 || resp.StatusCode > 299 {
		return &StatusError{Code: resp.StatusCode}
	}
	return nil
}
__EOF__
cat > internal/delivery/worker.go <<'__EOF__'
// Package delivery sends due webhooks and retries failures.
package delivery

import (
	"context"
	"log"
	"time"

	"example.com/hookd/internal/metrics"
	"example.com/hookd/internal/store"
)

type Worker struct {
	Store       *store.Store
	Sender      Sender
	MaxAttempts int
	Now         func() time.Time
	Log         *log.Logger
}

// Run calls Tick every second until ctx is done.
func (w *Worker) Run(ctx context.Context) {
	t := time.NewTicker(time.Second)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			w.Tick(ctx)
		}
	}
}

// Tick sends every due delivery once.
func (w *Worker) Tick(ctx context.Context) {
	now := w.Now()
	for _, d := range w.Store.Due(now, 100) {
		ep, ok := w.Store.Endpoint(d.EndpointID)
		if !ok {
			// Endpoint was deleted; its deliveries are discarded (README).
			w.check(w.Store.Complete(d.ID))
			continue
		}
		err := w.Sender.Send(ctx, ep, d)
		if err == nil {
			metrics.Delivered.Add(1)
			w.check(w.Store.Complete(d.ID))
			continue
		}
		d.Attempt++
		if d.Attempt >= w.MaxAttempts {
			w.Log.Printf("delivery %s to %s dropped after %d attempts: %v", d.ID, ep.URL, d.Attempt, err)
			metrics.Dropped.Add(1)
			w.check(w.Store.Complete(d.ID))
			continue
		}
		metrics.Retried.Add(1)
		w.check(w.Store.Reschedule(d.ID, d.Attempt, now.Add(Backoff(d.Attempt)), err.Error()))
	}
}

func (w *Worker) check(err error) {
	if err != nil {
		w.Log.Printf("store: %v", err)
	}
}
__EOF__
cat > internal/delivery/worker_test.go <<'__EOF__'
package delivery

import (
	"context"
	"errors"
	"io"
	"log"
	"path/filepath"
	"testing"
	"time"

	"example.com/hookd/internal/store"
)

type failingSender struct{ calls int }

func (f *failingSender) Send(context.Context, store.Endpoint, store.Delivery) error {
	f.calls++
	return errors.New("connection refused")
}

func TestRetriesThenDrops(t *testing.T) {
	st, err := store.Open(filepath.Join(t.TempDir(), "state.json"))
	if err != nil {
		t.Fatal(err)
	}
	now := time.Date(2026, 3, 2, 9, 0, 0, 0, time.UTC)
	st.CreateEndpoint(store.Endpoint{ID: "ep1", AccountID: "a", URL: "https://example.test/hook", Secret: "s"})
	st.Enqueue([]store.Delivery{{ID: "d1", EndpointID: "ep1", Payload: []byte("{}"), NextAttemptAt: now}})
	sender := &failingSender{}
	w := &Worker{Store: st, Sender: sender, MaxAttempts: 3, Now: func() time.Time { return now }, Log: log.New(io.Discard, "", 0)}
	for i := 0; i < 3; i++ {
		w.Tick(context.Background())
		now = now.Add(2 * time.Hour)
	}
	if sender.calls != 3 {
		t.Fatalf("want 3 attempts, got %d", sender.calls)
	}
	if len(st.Due(now.Add(24*time.Hour), 10)) != 0 {
		t.Fatal("delivery should be gone after the last attempt")
	}
}

func TestBackoffCapped(t *testing.T) {
	if Backoff(1) != 2*time.Second || Backoff(8) != 256*time.Second {
		t.Fatalf("unexpected backoff: %v %v", Backoff(1), Backoff(8))
	}
	if Backoff(20) != time.Hour {
		t.Fatalf("want cap of 1h, got %v", Backoff(20))
	}
}
__EOF__
cat > internal/metrics/metrics.go <<'__EOF__'
// Package metrics holds process-wide counters served at /metrics.
package metrics

import (
	"fmt"
	"net/http"
	"sync/atomic"
)

var (
	Delivered atomic.Int64
	Retried   atomic.Int64
	Dropped   atomic.Int64
)

func Handler(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "text/plain; version=0.0.4")
	fmt.Fprintf(w, "hookd_delivered_total %d\n", Delivered.Load())
	fmt.Fprintf(w, "hookd_retried_total %d\n", Retried.Load())
	fmt.Fprintf(w, "hookd_dropped_total %d\n", Dropped.Load())
}
__EOF__
cat > internal/signing/sign.go <<'__EOF__'
// Package signing implements the Hookd-Signature header (docs/receivers.md).
package signing

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"strconv"
)

// Sign returns hex(HMAC-SHA256(secret, "<ts>.<body>")).
func Sign(secret string, ts int64, body []byte) string {
	mac := hmac.New(sha256.New, []byte(secret))
	mac.Write([]byte(strconv.FormatInt(ts, 10)))
	mac.Write([]byte("."))
	mac.Write(body)
	return hex.EncodeToString(mac.Sum(nil))
}

// Header builds the Hookd-Signature header value.
func Header(secret string, ts int64, body []byte) string {
	return "t=" + strconv.FormatInt(ts, 10) + ",v1=" + Sign(secret, ts, body)
}
__EOF__
cat > internal/signing/sign_test.go <<'__EOF__'
package signing

import "testing"

func TestSignKnownVector(t *testing.T) {
	got := Sign("whsec_test", 1700000000, []byte(`{"id":1}`))
	if len(got) != 64 {
		t.Fatalf("want 64 hex chars, got %q", got)
	}
	if got != Sign("whsec_test", 1700000000, []byte(`{"id":1}`)) {
		t.Fatal("signature not deterministic")
	}
	if got == Sign("whsec_test", 1700000001, []byte(`{"id":1}`)) {
		t.Fatal("timestamp not covered by signature")
	}
}

func TestHeaderFormat(t *testing.T) {
	h := Header("s", 42, []byte("{}"))
	want := "t=42,v1=" + Sign("s", 42, []byte("{}"))
	if h != want {
		t.Fatalf("got %q want %q", h, want)
	}
}
__EOF__
cat > internal/store/models.go <<'__EOF__'
package store

import (
	"encoding/json"
	"time"
)

type Endpoint struct {
	ID        string    `json:"id"`
	AccountID string    `json:"account_id"`
	URL       string    `json:"url"`
	Secret    string    `json:"secret"`
	CreatedAt time.Time `json:"created_at"`
}

type Delivery struct {
	ID            string          `json:"id"`
	EndpointID    string          `json:"endpoint_id"`
	EventType     string          `json:"event_type"`
	Payload       json.RawMessage `json:"payload"`
	Attempt       int             `json:"attempt"`
	NextAttemptAt time.Time       `json:"next_attempt_at"`
	LastError     string          `json:"last_error,omitempty"`
}
__EOF__
cat > internal/store/store.go <<'__EOF__'
// Package store keeps endpoints and pending deliveries in memory and writes the
// whole state to one JSON file after every change.
package store

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"sync"
	"time"
)

var ErrNotFound = errors.New("not found")

type Store struct {
	mu         sync.Mutex
	path       string
	endpoints  map[string]*Endpoint
	deliveries map[string]*Delivery
}

// snapshot is the on-disk format.
type snapshot struct {
	Endpoints  []*Endpoint `json:"endpoints"`
	Deliveries []*Delivery `json:"deliveries"`
}

// Open loads the state file at path, or starts empty if it does not exist.
func Open(path string) (*Store, error) {
	s := &Store{
		path:       path,
		endpoints:  map[string]*Endpoint{},
		deliveries: map[string]*Delivery{},
	}
	raw, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return s, nil
	}
	if err != nil {
		return nil, err
	}
	var snap snapshot
	if err := json.Unmarshal(raw, &snap); err != nil {
		return nil, fmt.Errorf("state file %s: %w", path, err)
	}
	for _, ep := range snap.Endpoints {
		s.endpoints[ep.ID] = ep
	}
	for _, d := range snap.Deliveries {
		s.deliveries[d.ID] = d
	}
	return s, nil
}

// persistLocked writes the state atomically: temp file, fsync, rename, then
// fsync the directory so the rename itself survives a crash.
func (s *Store) persistLocked() error {
	snap := snapshot{}
	for _, ep := range s.endpoints {
		snap.Endpoints = append(snap.Endpoints, ep)
	}
	for _, d := range s.deliveries {
		snap.Deliveries = append(snap.Deliveries, d)
	}
	sort.Slice(snap.Endpoints, func(i, j int) bool { return snap.Endpoints[i].ID < snap.Endpoints[j].ID })
	sort.Slice(snap.Deliveries, func(i, j int) bool { return snap.Deliveries[i].ID < snap.Deliveries[j].ID })
	raw, err := json.Marshal(snap)
	if err != nil {
		return err
	}
	dir := filepath.Dir(s.path)
	tmp, err := os.CreateTemp(dir, ".state-*.json")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	if _, err := tmp.Write(raw); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	if err := os.Rename(tmp.Name(), s.path); err != nil {
		return err
	}
	d, err := os.Open(dir)
	if err != nil {
		return err
	}
	defer d.Close()
	return d.Sync()
}

func (s *Store) CreateEndpoint(ep Endpoint) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.endpoints[ep.ID] = &ep
	return s.persistLocked()
}

// Endpoint returns a copy of the endpoint.
func (s *Store) Endpoint(id string) (Endpoint, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	ep, ok := s.endpoints[id]
	if !ok {
		return Endpoint{}, false
	}
	return *ep, true
}

func (s *Store) EndpointsFor(accountID string) []Endpoint {
	s.mu.Lock()
	defer s.mu.Unlock()
	var out []Endpoint
	for _, ep := range s.endpoints {
		if ep.AccountID == accountID {
			out = append(out, *ep)
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].ID < out[j].ID })
	return out
}

// DeleteEndpoint removes the endpoint and discards its pending deliveries.
func (s *Store) DeleteEndpoint(id string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.endpoints[id]; !ok {
		return ErrNotFound
	}
	delete(s.endpoints, id)
	for did, d := range s.deliveries {
		if d.EndpointID == id {
			delete(s.deliveries, did)
		}
	}
	return s.persistLocked()
}

func (s *Store) Enqueue(ds []Delivery) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	for i := range ds {
		d := ds[i]
		s.deliveries[d.ID] = &d
	}
	return s.persistLocked()
}

// Due returns up to limit deliveries whose next attempt is at or before now,
// oldest first.
func (s *Store) Due(now time.Time, limit int) []Delivery {
	s.mu.Lock()
	defer s.mu.Unlock()
	var out []Delivery
	for _, d := range s.deliveries {
		if !d.NextAttemptAt.After(now) {
			out = append(out, *d)
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].NextAttemptAt.Before(out[j].NextAttemptAt) })
	if len(out) > limit {
		out = out[:limit]
	}
	return out
}

// Complete removes a delivery that needs no more attempts.
func (s *Store) Complete(id string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	delete(s.deliveries, id)
	return s.persistLocked()
}

func (s *Store) Reschedule(id string, attempt int, next time.Time, lastErr string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	d, ok := s.deliveries[id]
	if !ok {
		return ErrNotFound
	}
	d.Attempt, d.NextAttemptAt, d.LastError = attempt, next, lastErr
	return s.persistLocked()
}
__EOF__

git init -q . && git config user.email dev@example.com && git config user.name dev
git add -A && git commit -qm 'Initial import'

mkdir -p cmd/hookd docs internal/api internal/config internal/delivery internal/metrics internal/signing internal/store
cat > README.md <<'__EOF__'
# hookd

Delivers webhooks for our customers. A customer registers endpoints (URLs) under
their account, we POST each event to every endpoint of the account, sign it with
the endpoint's secret, and retry failures with exponential backoff.

    go run ./cmd/hookd -config config.json

- `internal/api`: the customer-facing HTTP API (API key per account).
- `internal/store`: endpoints, pending deliveries and dead letters, persisted
  to one JSON file after every change.
- `internal/delivery`: the worker that sends due deliveries and retries them.
- `internal/signing`: the signature scheme receivers verify
  (`docs/receivers.md`).

Deleting an endpoint discards its pending deliveries and dead letters.

## Retries and dead letters

Each endpoint has `max_attempts` (1..100, default `max_attempts` from the
config). A delivery that fails that many times, or that the receiver rejects
with a 4xx other than 408 or 429, moves to the endpoint's dead-letter queue
instead of being dropped. Customers can list it with
`GET /endpoints/{id}/dead-letters` and move it back into the delivery queue
with `POST /endpoints/{id}/dead-letters/replay`. Each endpoint keeps its 1000
most recent dead letters.

The `hookd_dropped_total` metric is replaced by `hookd_dead_lettered_total`.

## Secret rotation

`POST /endpoints/{id}/rotate-secret` issues a new signing secret and returns it.
The previous secret keeps signing alongside the new one for `rotation_grace`
seconds (config; a day by default) so receivers can switch without rejecting
webhooks.
__EOF__
cat > cmd/hookd/main.go <<'__EOF__'
// Command hookd runs the webhook API and the delivery worker.
package main

import (
	"context"
	"errors"
	"flag"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"example.com/hookd/internal/api"
	"example.com/hookd/internal/config"
	"example.com/hookd/internal/delivery"
	"example.com/hookd/internal/store"
)

func main() {
	path := flag.String("config", "config.json", "path to the config file")
	flag.Parse()
	logger := log.New(os.Stderr, "hookd ", log.LstdFlags)

	cfg, err := config.Load(*path)
	if err != nil {
		logger.Fatal(err)
	}
	st, err := store.Open(cfg.DataFile)
	if err != nil {
		logger.Fatal(err)
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	worker := &delivery.Worker{
		Store:  st,
		Sender: delivery.NewHTTPSender(time.Duration(cfg.DeliveryTimeoutSeconds) * time.Second),
		Now:    time.Now,
		Log:    logger,
	}
	go worker.Run(ctx)
	go pruneSecrets(ctx, st, logger)

	apiServer := &api.Server{
		Store:              st,
		Keys:               cfg.APIKeys,
		Now:                time.Now,
		DefaultMaxAttempts: cfg.MaxAttempts,
		RotationGrace:      time.Duration(cfg.RotationGrace),
	}
	srv := &http.Server{
		Addr:              cfg.Listen,
		Handler:           apiServer.Routes(),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       30 * time.Second,
		WriteTimeout:      30 * time.Second,
	}
	go func() {
		<-ctx.Done()
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		_ = srv.Shutdown(shutdownCtx)
	}()
	logger.Printf("listening on %s", cfg.Listen)
	if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		logger.Fatal(err)
	}
}

// pruneSecrets drops rotated-out signing secrets once their grace period ends.
func pruneSecrets(ctx context.Context, st *store.Store, logger *log.Logger) {
	t := time.NewTicker(time.Minute)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case now := <-t.C:
			if err := st.PruneSecrets(now); err != nil {
				logger.Printf("prune secrets: %v", err)
			}
		}
	}
}
__EOF__
cat > config.example.json <<'__EOF__'
{
  "listen": ":8080",
  "data_file": "/var/lib/hookd/state.json",
  "api_keys": {"key_live_acme": "acct_acme"},
  "delivery_timeout_seconds": 10,
  "max_attempts": 8,
  "rotation_grace": 86400
}
__EOF__
cat > docs/receivers.md <<'__EOF__'
# Verifying hookd webhooks

Every delivery is a `POST` with a JSON body and these headers:

- `Hookd-Delivery`: the delivery id. Retries of one delivery reuse it, and so
  does a replay from the dead-letter queue, so use it to drop duplicates.
- `Hookd-Event`: the event type.
- `Hookd-Signature`: `t=<unix seconds>,v1=<hex>[,v1=<hex>...]`.

To verify, compute HMAC-SHA256 with your endpoint secret over
`<t>.<raw body>` and compare it in constant time with each `v1` in the header.
Accept the request if any of them matches. Reject it if `t` is more than 5
minutes from your clock.

After a secret rotation the header carries one `v1` per valid secret: the new
one and, for the grace period, the previous one. Switch your verifier to the
new secret any time within the grace period.

Answer with any 2xx status within 10 seconds to acknowledge. Redirects are not
followed: a 3xx counts as a failed attempt, so register the final URL. A 4xx
other than 408 or 429 is not retried; the delivery goes to the dead-letter
queue. Anything else is retried with exponential backoff.
__EOF__
cat > internal/api/handlers.go <<'__EOF__'
// Package api is the customer-facing HTTP API.
package api

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net/http"
	"net/url"
	"time"

	"example.com/hookd/internal/store"
)

const (
	maxBody = 1 << 20
	// maxAttemptsLimit caps an endpoint's max_attempts. With the one-hour
	// backoff cap, 100 attempts keep retrying a dead receiver for about four
	// days.
	maxAttemptsLimit = 100
)

type Server struct {
	Store *store.Store
	// Keys maps API key -> account id.
	Keys map[string]string
	Now  func() time.Time
	// DefaultMaxAttempts applies to endpoints created without max_attempts.
	DefaultMaxAttempts int
	// RotationGrace is how long a rotated-out secret keeps signing.
	RotationGrace time.Duration
}

type endpointView struct {
	ID          string    `json:"id"`
	URL         string    `json:"url"`
	MaxAttempts int       `json:"max_attempts"`
	CreatedAt   time.Time `json:"created_at"`
}

func view(ep store.Endpoint) endpointView {
	return endpointView{ID: ep.ID, URL: ep.URL, MaxAttempts: ep.MaxAttempts, CreatedAt: ep.CreatedAt}
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func writeError(w http.ResponseWriter, status int, msg string) {
	writeJSON(w, status, map[string]string{"error": msg})
}

// decode reads a JSON body of at most maxBody bytes. It writes the error
// response itself and returns false on failure.
func decode(w http.ResponseWriter, r *http.Request, v any) bool {
	err := json.NewDecoder(http.MaxBytesReader(w, r.Body, maxBody)).Decode(v)
	var tooBig *http.MaxBytesError
	switch {
	case err == nil:
		return true
	case errors.As(err, &tooBig):
		writeError(w, http.StatusRequestEntityTooLarge, "body too large")
	default:
		writeError(w, http.StatusBadRequest, "invalid JSON body")
	}
	return false
}

func newID(prefix string) string {
	b := make([]byte, 12)
	if _, err := rand.Read(b); err != nil {
		panic(err) // crypto/rand never fails on supported platforms
	}
	return prefix + hex.EncodeToString(b)
}

// ownedEndpoint loads the {id} endpoint if it belongs to the caller's account.
// Anything else is a 404, so ids of other accounts are not revealed.
func (s *Server) ownedEndpoint(w http.ResponseWriter, r *http.Request) (store.Endpoint, bool) {
	ep, ok := s.Store.Endpoint(r.PathValue("id"))
	if !ok || ep.AccountID != accountOf(r) {
		writeError(w, http.StatusNotFound, "endpoint not found")
		return store.Endpoint{}, false
	}
	return ep, true
}

func (s *Server) createEndpoint(w http.ResponseWriter, r *http.Request) {
	var req struct {
		URL         string `json:"url"`
		MaxAttempts int    `json:"max_attempts"`
	}
	if !decode(w, r, &req) {
		return
	}
	u, err := url.Parse(req.URL)
	if err != nil || u.Scheme != "https" || u.Host == "" {
		writeError(w, http.StatusBadRequest, "url must be an absolute https URL")
		return
	}
	attempts := req.MaxAttempts
	if attempts == 0 {
		attempts = s.DefaultMaxAttempts
	}
	if attempts < 1 || attempts > maxAttemptsLimit {
		writeError(w, http.StatusBadRequest, "max_attempts must be 1..100")
		return
	}
	ep := store.Endpoint{
		ID:          newID("ep_"),
		AccountID:   accountOf(r),
		URL:         u.String(),
		Secrets:     []store.Secret{{Value: newID("whsec_")}},
		MaxAttempts: attempts,
		CreatedAt:   s.Now().UTC(),
	}
	if err := s.Store.CreateEndpoint(ep); err != nil {
		writeError(w, http.StatusInternalServerError, "could not save endpoint")
		return
	}
	// The secret is shown once, here; receivers need it to verify signatures.
	writeJSON(w, http.StatusCreated, map[string]any{"endpoint": view(ep), "secret": ep.Secrets[0].Value})
}

func (s *Server) listEndpoints(w http.ResponseWriter, r *http.Request) {
	views := []endpointView{}
	for _, ep := range s.Store.EndpointsFor(accountOf(r)) {
		views = append(views, view(ep))
	}
	writeJSON(w, http.StatusOK, map[string]any{"endpoints": views})
}

func (s *Server) deleteEndpoint(w http.ResponseWriter, r *http.Request) {
	ep, ok := s.ownedEndpoint(w, r)
	if !ok {
		return
	}
	if err := s.Store.DeleteEndpoint(ep.ID); err != nil {
		writeError(w, http.StatusInternalServerError, "could not delete endpoint")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// rotateSecret issues a new signing secret. Like createEndpoint, this is the
// only time the new secret is shown.
func (s *Server) rotateSecret(w http.ResponseWriter, r *http.Request) {
	ep, ok := s.ownedEndpoint(w, r)
	if !ok {
		return
	}
	secret := newID("whsec_")
	updated, err := s.Store.RotateSecret(ep.ID, secret, s.Now().UTC(), s.RotationGrace)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "could not rotate secret")
		return
	}
	var previousExpiresAt *time.Time
	if len(updated.Secrets) > 1 {
		previousExpiresAt = &updated.Secrets[1].ExpiresAt
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"secret":                     secret,
		"previous_secret_expires_at": previousExpiresAt,
	})
}

func (s *Server) listDeadLetters(w http.ResponseWriter, r *http.Request) {
	dls := s.Store.DeadLetters(r.PathValue("id"))
	if dls == nil {
		dls = []store.DeadLetter{}
	}
	writeJSON(w, http.StatusOK, map[string]any{"dead_letters": dls})
}

func (s *Server) replayDeadLetters(w http.ResponseWriter, r *http.Request) {
	ep, ok := s.ownedEndpoint(w, r)
	if !ok {
		return
	}
	n, err := s.Store.ReplayDeadLetters(ep.ID, s.Now().UTC())
	if err != nil {
		writeError(w, http.StatusInternalServerError, "could not replay dead letters")
		return
	}
	writeJSON(w, http.StatusAccepted, map[string]int{"replayed": n})
}

func (s *Server) postEvent(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Type    string          `json:"type"`
		Payload json.RawMessage `json:"payload"`
	}
	if !decode(w, r, &req) {
		return
	}
	if req.Type == "" || len(req.Payload) == 0 {
		writeError(w, http.StatusBadRequest, "type and payload are required")
		return
	}
	now := s.Now().UTC()
	var ds []store.Delivery
	for _, ep := range s.Store.EndpointsFor(accountOf(r)) {
		ds = append(ds, store.Delivery{
			ID:            newID("dl_"),
			EndpointID:    ep.ID,
			EventType:     req.Type,
			Payload:       req.Payload,
			NextAttemptAt: now,
		})
	}
	if err := s.Store.Enqueue(ds); err != nil {
		writeError(w, http.StatusInternalServerError, "could not queue event")
		return
	}
	writeJSON(w, http.StatusAccepted, map[string]int{"deliveries": len(ds)})
}
__EOF__
cat > internal/api/handlers_test.go <<'__EOF__'
package api

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"example.com/hookd/internal/store"
)

func newServer(t *testing.T) *Server {
	t.Helper()
	st, err := store.Open(filepath.Join(t.TempDir(), "state.json"))
	if err != nil {
		t.Fatal(err)
	}
	return &Server{
		Store:              st,
		Keys:               map[string]string{"key_a": "acct_a", "key_b": "acct_b"},
		Now:                func() time.Time { return time.Date(2026, 3, 2, 9, 0, 0, 0, time.UTC) },
		DefaultMaxAttempts: 8,
		RotationGrace:      24 * time.Hour,
	}
}

func call(t *testing.T, h http.Handler, method, path, key, body string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(method, path, strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+key)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	return rec
}

func createEP(t *testing.T, h http.Handler, key string) string {
	t.Helper()
	rec := call(t, h, "POST", "/endpoints", key, `{"url":"https://example.test/hook"}`)
	if rec.Code != http.StatusCreated {
		t.Fatalf("create: %d %s", rec.Code, rec.Body)
	}
	var out struct {
		Endpoint struct{ ID string } `json:"endpoint"`
	}
	json.Unmarshal(rec.Body.Bytes(), &out)
	return out.Endpoint.ID
}

func TestCreateListDelete(t *testing.T) {
	s := newServer(t)
	h := s.Routes()
	id := createEP(t, h, "key_a")
	if rec := call(t, h, "GET", "/endpoints", "key_a", ""); !strings.Contains(rec.Body.String(), id) {
		t.Fatalf("list misses %s: %s", id, rec.Body)
	}
	if rec := call(t, h, "GET", "/endpoints", "key_a", ""); strings.Contains(rec.Body.String(), "whsec_") {
		t.Fatal("list must not show secrets")
	}
	if rec := call(t, h, "DELETE", "/endpoints/"+id, "key_b", ""); rec.Code != http.StatusNotFound {
		t.Fatalf("other account delete: want 404, got %d", rec.Code)
	}
	if rec := call(t, h, "DELETE", "/endpoints/"+id, "key_a", ""); rec.Code != http.StatusNoContent {
		t.Fatalf("delete: %d", rec.Code)
	}
}

func TestEventFansOutToAccountEndpointsOnly(t *testing.T) {
	s := newServer(t)
	h := s.Routes()
	createEP(t, h, "key_a")
	createEP(t, h, "key_a")
	createEP(t, h, "key_b")
	rec := call(t, h, "POST", "/events", "key_a", `{"type":"order.paid","payload":{"id":1}}`)
	if rec.Code != http.StatusAccepted || !strings.Contains(rec.Body.String(), `"deliveries":2`) {
		t.Fatalf("got %d %s", rec.Code, rec.Body)
	}
}

func TestRejectsBadInput(t *testing.T) {
	h := newServer(t).Routes()
	if rec := call(t, h, "POST", "/endpoints", "key_a", `{"url":"http://example.test"}`); rec.Code != 400 {
		t.Fatalf("http url: want 400, got %d", rec.Code)
	}
	if rec := call(t, h, "POST", "/endpoints", "key_a", `{"url":"https://example.test","max_attempts":101}`); rec.Code != 400 {
		t.Fatalf("max_attempts 101: want 400, got %d", rec.Code)
	}
	big := `{"type":"x","payload":"` + strings.Repeat("a", maxBody) + `"}`
	if rec := call(t, h, "POST", "/events", "key_a", big); rec.Code != 413 {
		t.Fatalf("big body: want 413, got %d", rec.Code)
	}
	if rec := call(t, h, "GET", "/endpoints", "nope", ""); rec.Code != 401 {
		t.Fatalf("bad key: want 401, got %d", rec.Code)
	}
}

func TestRotateSecret(t *testing.T) {
	s := newServer(t)
	h := s.Routes()
	id := createEP(t, h, "key_a")
	if rec := call(t, h, "POST", "/endpoints/"+id+"/rotate-secret", "key_b", ""); rec.Code != http.StatusNotFound {
		t.Fatalf("other account rotate: want 404, got %d", rec.Code)
	}
	rec := call(t, h, "POST", "/endpoints/"+id+"/rotate-secret", "key_a", "")
	if rec.Code != http.StatusOK || !strings.Contains(rec.Body.String(), `"secret":"whsec_`) {
		t.Fatalf("rotate: %d %s", rec.Code, rec.Body)
	}
	ep, _ := s.Store.Endpoint(id)
	if got := ep.ActiveSecrets(s.Now()); len(got) != 2 {
		t.Fatalf("want both secrets active right after rotation, got %d", len(got))
	}
}

func TestReplayIsScopedToOwner(t *testing.T) {
	s := newServer(t)
	h := s.Routes()
	id := createEP(t, h, "key_a")
	if rec := call(t, h, "POST", "/endpoints/"+id+"/dead-letters/replay", "key_b", ""); rec.Code != http.StatusNotFound {
		t.Fatalf("other account replay: want 404, got %d", rec.Code)
	}
	if rec := call(t, h, "POST", "/endpoints/"+id+"/dead-letters/replay", "key_a", ""); rec.Code != http.StatusAccepted {
		t.Fatalf("replay: %d", rec.Code)
	}
}
__EOF__
cat > internal/api/router.go <<'__EOF__'
package api

import (
	"net/http"

	"example.com/hookd/internal/metrics"
)

func (s *Server) Routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("POST /endpoints", s.auth(s.createEndpoint))
	mux.HandleFunc("GET /endpoints", s.auth(s.listEndpoints))
	mux.HandleFunc("DELETE /endpoints/{id}", s.auth(s.deleteEndpoint))
	mux.HandleFunc("POST /endpoints/{id}/rotate-secret", s.auth(s.rotateSecret))
	mux.HandleFunc("GET /endpoints/{id}/dead-letters", s.auth(s.listDeadLetters))
	mux.HandleFunc("POST /endpoints/{id}/dead-letters/replay", s.auth(s.replayDeadLetters))
	mux.HandleFunc("POST /events", s.auth(s.postEvent))
	mux.HandleFunc("GET /metrics", metrics.Handler)
	return mux
}
__EOF__
cat > internal/config/config.go <<'__EOF__'
// Package config loads hookd's JSON config file.
package config

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
)

type Config struct {
	Listen   string `json:"listen"`
	DataFile string `json:"data_file"`
	// APIKeys maps an API key to the account it belongs to.
	APIKeys map[string]string `json:"api_keys"`
	// DeliveryTimeoutSeconds bounds one HTTP attempt.
	DeliveryTimeoutSeconds int `json:"delivery_timeout_seconds"`
	// MaxAttempts is the default max_attempts for endpoints created without
	// one: how many times a delivery is tried before it is dead-lettered.
	MaxAttempts int `json:"max_attempts"`
	// RotationGrace is how long, in seconds, a rotated-out signing secret
	// keeps signing next to the new one. Defaults to a day.
	RotationGrace int `json:"rotation_grace"`
}

const defaultRotationGrace = 24 * 60 * 60

func Load(path string) (*Config, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	dec := json.NewDecoder(f)
	dec.DisallowUnknownFields()
	var c Config
	if err := dec.Decode(&c); err != nil {
		return nil, fmt.Errorf("config %s: %w", path, err)
	}
	if c.RotationGrace == 0 {
		c.RotationGrace = defaultRotationGrace
	}
	if err := c.Validate(); err != nil {
		return nil, fmt.Errorf("config %s: %w", path, err)
	}
	return &c, nil
}

func (c *Config) Validate() error {
	switch {
	case c.Listen == "":
		return errors.New("listen is required")
	case c.DataFile == "":
		return errors.New("data_file is required")
	case len(c.APIKeys) == 0:
		return errors.New("api_keys is empty")
	case c.DeliveryTimeoutSeconds < 1 || c.DeliveryTimeoutSeconds > 60:
		return errors.New("delivery_timeout_seconds must be 1..60")
	case c.MaxAttempts < 1 || c.MaxAttempts > 10:
		return errors.New("max_attempts must be 1..10")
	case c.RotationGrace < 60 || c.RotationGrace > 7*24*60*60:
		return errors.New("rotation_grace must be 60..604800 seconds")
	}
	return nil
}
__EOF__
cat > internal/delivery/backoff.go <<'__EOF__'
package delivery

import (
	"math/rand"
	"time"
)

const (
	baseDelay = time.Second
	maxDelay  = time.Hour
)

// Backoff is the wait before the next attempt after `attempt` failures:
// doubling from one second, capped at an hour, with jitter.
func Backoff(attempt int) time.Duration {
	d := baseDelay << attempt
	if d > maxDelay {
		d = maxDelay
	}
	return jitter(d)
}

// jitter spreads retries over [d/2, d) so endpoints that failed together do
// not all retry in the same second. The top-level math/rand functions are
// seeded randomly at startup since Go 1.20 (go.mod: go 1.22), so there is no
// Seed call.
func jitter(d time.Duration) time.Duration {
	half := d / 2
	return half + time.Duration(rand.Int63n(int64(half)))
}
__EOF__
cat > internal/delivery/client.go <<'__EOF__'
package delivery

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"time"

	"example.com/hookd/internal/signing"
	"example.com/hookd/internal/store"
)

// StatusError is a non-2xx answer from the receiver.
type StatusError struct{ Code int }

func (e *StatusError) Error() string { return fmt.Sprintf("receiver answered %d", e.Code) }

type Sender interface {
	Send(ctx context.Context, ep store.Endpoint, d store.Delivery) error
}

type HTTPSender struct {
	Client *http.Client
	Now    func() time.Time
}

func NewHTTPSender(timeout time.Duration) *HTTPSender {
	return &HTTPSender{
		Client: &http.Client{
			Timeout: timeout,
			// Never follow redirects: that would re-send a signed payload to a
			// URL the customer did not register. The 3xx comes back as the
			// response and counts as a failed attempt (docs/receivers.md).
			CheckRedirect: func(*http.Request, []*http.Request) error {
				return http.ErrUseLastResponse
			},
		},
		Now: time.Now,
	}
}

func (s *HTTPSender) Send(ctx context.Context, ep store.Endpoint, d store.Delivery) error {
	now := s.Now()
	secrets := ep.ActiveSecrets(now)
	if len(secrets) == 0 {
		return errors.New("endpoint has no valid signing secret")
	}
	ts := now.Unix()
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, ep.URL, bytes.NewReader(d.Payload))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Hookd-Delivery", d.ID)
	req.Header.Set("Hookd-Event", d.EventType)
	req.Header.Set("Hookd-Signature", signing.Header(secrets, ts, d.Payload))
	resp, err := s.Client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	// Drain a little so the connection can be reused.
	_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 64<<10))
	if resp.StatusCode < 200 || resp.StatusCode > 299 {
		return &StatusError{Code: resp.StatusCode}
	}
	return nil
}
__EOF__
cat > internal/delivery/worker.go <<'__EOF__'
// Package delivery sends due webhooks and retries failures.
package delivery

import (
	"context"
	"errors"
	"log"
	"net/http"
	"time"

	"example.com/hookd/internal/metrics"
	"example.com/hookd/internal/store"
)

type Worker struct {
	Store  *store.Store
	Sender Sender
	Now    func() time.Time
	Log    *log.Logger
}

// Run calls Tick every second until ctx is done.
func (w *Worker) Run(ctx context.Context) {
	t := time.NewTicker(time.Second)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			w.Tick(ctx)
		}
	}
}

// Tick sends every due delivery once. A delivery that has used up its
// endpoint's max_attempts, or that the receiver rejected for good, goes to the
// dead-letter queue.
func (w *Worker) Tick(ctx context.Context) {
	now := w.Now()
	for _, d := range w.Store.Due(now, 100) {
		ep, ok := w.Store.Endpoint(d.EndpointID)
		if !ok {
			// Endpoint was deleted; its deliveries are discarded (README).
			w.check(w.Store.Complete(d.ID))
			continue
		}
		err := w.Sender.Send(ctx, ep, d)
		if err == nil {
			metrics.Delivered.Add(1)
			w.check(w.Store.Complete(d.ID))
			continue
		}
		d.Attempt++
		if d.Attempt >= ep.MaxAttempts || permanent(err) {
			w.Log.Printf("delivery %s to %s dead-lettered after %d attempt(s): %v", d.ID, ep.URL, d.Attempt, err)
			metrics.DeadLettered.Add(1)
			w.check(w.Store.DeadLetter(d, err.Error(), now))
			continue
		}
		metrics.Retried.Add(1)
		w.check(w.Store.Reschedule(d.ID, d.Attempt, now.Add(Backoff(d.Attempt)), err.Error()))
	}
}

// permanent reports whether retrying cannot help: the receiver rejected the
// request itself (4xx), except 408 and 429, which ask us to come back later.
func permanent(err error) bool {
	var se *StatusError
	if !errors.As(err, &se) {
		return false
	}
	return se.Code >= 400 && se.Code < 500 &&
		se.Code != http.StatusRequestTimeout && se.Code != http.StatusTooManyRequests
}

func (w *Worker) check(err error) {
	if err != nil {
		w.Log.Printf("store: %v", err)
	}
}
__EOF__
cat > internal/delivery/worker_test.go <<'__EOF__'
package delivery

import (
	"context"
	"errors"
	"io"
	"log"
	"path/filepath"
	"testing"
	"time"

	"example.com/hookd/internal/store"
)

type fakeSender struct {
	calls int
	err   error
}

func (f *fakeSender) Send(context.Context, store.Endpoint, store.Delivery) error {
	f.calls++
	return f.err
}

func setup(t *testing.T, sender Sender) (*store.Store, *Worker, *time.Time) {
	t.Helper()
	st, err := store.Open(filepath.Join(t.TempDir(), "state.json"))
	if err != nil {
		t.Fatal(err)
	}
	now := time.Date(2026, 3, 2, 9, 0, 0, 0, time.UTC)
	st.CreateEndpoint(store.Endpoint{ID: "ep1", AccountID: "a", URL: "https://example.test/hook",
		Secrets: []store.Secret{{Value: "s"}}, MaxAttempts: 3})
	st.Enqueue([]store.Delivery{{ID: "d1", EndpointID: "ep1", Payload: []byte("{}"), NextAttemptAt: now}})
	w := &Worker{Store: st, Sender: sender, Now: func() time.Time { return now }, Log: log.New(io.Discard, "", 0)}
	return st, w, &now
}

func TestRetriesThenDeadLetters(t *testing.T) {
	sender := &fakeSender{err: errors.New("connection refused")}
	st, w, now := setup(t, sender)
	for i := 0; i < 3; i++ {
		w.Tick(context.Background())
		*now = now.Add(2 * time.Hour)
	}
	if sender.calls != 3 {
		t.Fatalf("want 3 attempts, got %d", sender.calls)
	}
	if len(st.Due(now.Add(24*time.Hour), 10)) != 0 {
		t.Fatal("delivery should have left the queue after the last attempt")
	}
	if dls := st.DeadLetters("ep1"); len(dls) != 1 || dls[0].Delivery.Attempt != 3 {
		t.Fatalf("dead letters: %+v", dls)
	}
}

func TestClientErrorIsNotRetried(t *testing.T) {
	sender := &fakeSender{err: &StatusError{Code: 410}}
	st, w, _ := setup(t, sender)
	w.Tick(context.Background())
	if len(st.DeadLetters("ep1")) != 1 {
		t.Fatal("a 410 should be dead-lettered at once")
	}
}

func TestRateLimitIsRetried(t *testing.T) {
	sender := &fakeSender{err: &StatusError{Code: 429}}
	st, w, now := setup(t, sender)
	w.Tick(context.Background())
	if len(st.DeadLetters("ep1")) != 0 || len(st.Due(now.Add(time.Hour), 10)) != 1 {
		t.Fatal("a 429 should be retried")
	}
}

func TestBackoffGrowsWithJitterAndCap(t *testing.T) {
	for i := 0; i < 50; i++ {
		if d := Backoff(1); d < time.Second || d >= 2*time.Second {
			t.Fatalf("Backoff(1) = %v, want [1s, 2s)", d)
		}
		if d := Backoff(20); d < 30*time.Minute || d >= time.Hour {
			t.Fatalf("Backoff(20) = %v, want [30m, 1h)", d)
		}
	}
}
__EOF__
cat > internal/metrics/metrics.go <<'__EOF__'
// Package metrics holds process-wide counters served at /metrics.
package metrics

import (
	"fmt"
	"net/http"
	"sync/atomic"
)

var (
	Delivered    atomic.Int64
	Retried      atomic.Int64
	DeadLettered atomic.Int64
)

func Handler(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "text/plain; version=0.0.4")
	fmt.Fprintf(w, "hookd_delivered_total %d\n", Delivered.Load())
	fmt.Fprintf(w, "hookd_retried_total %d\n", Retried.Load())
	fmt.Fprintf(w, "hookd_dead_lettered_total %d\n", DeadLettered.Load())
}
__EOF__
cat > internal/signing/sign.go <<'__EOF__'
// Package signing implements the Hookd-Signature header (docs/receivers.md).
package signing

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"strconv"
	"strings"
)

// Sign returns hex(HMAC-SHA256(secret, "<ts>.<body>")).
func Sign(secret string, ts int64, body []byte) string {
	mac := hmac.New(sha256.New, []byte(secret))
	mac.Write([]byte(strconv.FormatInt(ts, 10)))
	mac.Write([]byte("."))
	mac.Write(body)
	return hex.EncodeToString(mac.Sum(nil))
}

// Header builds the Hookd-Signature header value with one v1 entry per
// secret. While a rotation's grace period runs the endpoint has two valid
// secrets, so receivers still on the previous one can verify too.
func Header(secrets []string, ts int64, body []byte) string {
	var b strings.Builder
	b.WriteString("t=")
	b.WriteString(strconv.FormatInt(ts, 10))
	for _, secret := range secrets {
		b.WriteString(",v1=")
		b.WriteString(Sign(secret, ts, body))
	}
	return b.String()
}
__EOF__
cat > internal/signing/sign_test.go <<'__EOF__'
package signing

import "testing"

func TestSignKnownVector(t *testing.T) {
	got := Sign("whsec_test", 1700000000, []byte(`{"id":1}`))
	if len(got) != 64 {
		t.Fatalf("want 64 hex chars, got %q", got)
	}
	if got != Sign("whsec_test", 1700000000, []byte(`{"id":1}`)) {
		t.Fatal("signature not deterministic")
	}
	if got == Sign("whsec_test", 1700000001, []byte(`{"id":1}`)) {
		t.Fatal("timestamp not covered by signature")
	}
}

func TestHeaderFormat(t *testing.T) {
	h := Header([]string{"s"}, 42, []byte("{}"))
	want := "t=42,v1=" + Sign("s", 42, []byte("{}"))
	if h != want {
		t.Fatalf("got %q want %q", h, want)
	}
}

func TestHeaderSignsWithEverySecret(t *testing.T) {
	h := Header([]string{"new", "old"}, 42, []byte("{}"))
	want := "t=42,v1=" + Sign("new", 42, []byte("{}")) + ",v1=" + Sign("old", 42, []byte("{}"))
	if h != want {
		t.Fatalf("got %q want %q", h, want)
	}
}
__EOF__
cat > internal/store/dlq.go <<'__EOF__'
package store

import "time"

// maxDeadLetters caps each endpoint's dead-letter queue; the oldest go first.
const maxDeadLetters = 1000

// DeadLetter moves a delivery that will not be retried from the delivery
// queue into its endpoint's dead-letter queue.
func (s *Store) DeadLetter(d Delivery, reason string, at time.Time) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	delete(s.deliveries, d.ID)
	q := append(s.deadLetters[d.EndpointID], DeadLetter{Delivery: d, Reason: reason, DeadAt: at})
	if len(q) > maxDeadLetters {
		q = append([]DeadLetter(nil), q[len(q)-maxDeadLetters:]...)
	}
	s.deadLetters[d.EndpointID] = q
	return s.persistLocked()
}

// DeadLetters returns a copy of the endpoint's dead-letter queue, oldest first.
func (s *Store) DeadLetters(endpointID string) []DeadLetter {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]DeadLetter(nil), s.deadLetters[endpointID]...)
}

// ReplayDeadLetters moves the endpoint's dead letters back into the delivery
// queue, due now, with a fresh attempt count. They keep their delivery ids so
// receivers can still drop duplicates.
func (s *Store) ReplayDeadLetters(endpointID string, now time.Time) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	q := s.deadLetters[endpointID]
	for _, dl := range q {
		d := dl.Delivery
		d.Attempt, d.NextAttemptAt, d.LastError = 0, now, ""
		s.deliveries[d.ID] = &d
	}
	delete(s.deadLetters, endpointID)
	return len(q), s.persistLocked()
}
__EOF__
cat > internal/store/models.go <<'__EOF__'
package store

import (
	"encoding/json"
	"time"
)

type Secret struct {
	Value string `json:"value"`
	// ExpiresAt is zero for the current secret. A rotated-out secret keeps
	// signing until then.
	ExpiresAt time.Time `json:"expires_at,omitempty"`
}

type Endpoint struct {
	ID        string `json:"id"`
	AccountID string `json:"account_id"`
	URL       string `json:"url"`
	// Secrets holds the current secret first, then rotated-out secrets that
	// are still in their grace period.
	Secrets []Secret `json:"secrets"`
	// LegacySecret is the single secret of state files written before
	// rotation existed. Open moves it into Secrets.
	LegacySecret string `json:"secret,omitempty"`
	// MaxAttempts is how many times a delivery is tried before it is
	// dead-lettered.
	MaxAttempts int       `json:"max_attempts"`
	CreatedAt   time.Time `json:"created_at"`
}

// ActiveSecrets returns the secrets that may sign at now, current first.
func (ep Endpoint) ActiveSecrets(now time.Time) []string {
	var out []string
	for _, s := range ep.Secrets {
		if s.ExpiresAt.IsZero() || now.Before(s.ExpiresAt) {
			out = append(out, s.Value)
		}
	}
	return out
}

type Delivery struct {
	ID            string          `json:"id"`
	EndpointID    string          `json:"endpoint_id"`
	EventType     string          `json:"event_type"`
	Payload       json.RawMessage `json:"payload"`
	Attempt       int             `json:"attempt"`
	NextAttemptAt time.Time       `json:"next_attempt_at"`
	LastError     string          `json:"last_error,omitempty"`
}

// DeadLetter is a delivery hookd stopped retrying.
type DeadLetter struct {
	Delivery Delivery  `json:"delivery"`
	Reason   string    `json:"reason"`
	DeadAt   time.Time `json:"dead_at"`
}
__EOF__
cat > internal/store/secrets.go <<'__EOF__'
package store

import "time"

// RotateSecret makes secret the endpoint's current secret. The previous
// current secret keeps signing until now+grace; older rotated-out secrets
// keep their own expiry and are dropped once past it.
func (s *Store) RotateSecret(id, secret string, now time.Time, grace time.Duration) (Endpoint, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	ep, ok := s.endpoints[id]
	if !ok {
		return Endpoint{}, ErrNotFound
	}
	next := []Secret{{Value: secret}}
	for i, old := range ep.Secrets {
		if i == 0 {
			old.ExpiresAt = now.Add(grace)
		}
		if old.ExpiresAt.After(now) {
			next = append(next, old)
		}
	}
	ep.Secrets = next
	return *ep, s.persistLocked()
}

// PruneSecrets drops rotated-out secrets whose grace period has ended.
func (s *Store) PruneSecrets(now time.Time) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	changed := false
	for _, ep := range s.endpoints {
		var kept []Secret
		for _, sec := range ep.Secrets {
			if sec.ExpiresAt.IsZero() || sec.ExpiresAt.After(now) {
				kept = append(kept, sec)
			}
		}
		if len(kept) != len(ep.Secrets) {
			ep.Secrets = kept
			changed = true
		}
	}
	if !changed {
		return nil
	}
	return s.persistLocked()
}
__EOF__
cat > internal/store/store.go <<'__EOF__'
// Package store keeps endpoints, pending deliveries and dead letters in memory
// and writes the whole state to one JSON file after every change.
package store

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"sync"
	"time"
)

var ErrNotFound = errors.New("not found")

type Store struct {
	mu          sync.Mutex
	path        string
	endpoints   map[string]*Endpoint
	deliveries  map[string]*Delivery
	deadLetters map[string][]DeadLetter // by endpoint id, oldest first
}

// snapshot is the on-disk format.
type snapshot struct {
	Endpoints  []*Endpoint `json:"endpoints"`
	Deliveries []*Delivery `json:"deliveries"`
}

// Open loads the state file at path, or starts empty if it does not exist.
func Open(path string) (*Store, error) {
	s := &Store{
		path:        path,
		endpoints:   map[string]*Endpoint{},
		deliveries:  map[string]*Delivery{},
		deadLetters: map[string][]DeadLetter{},
	}
	raw, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return s, nil
	}
	if err != nil {
		return nil, err
	}
	var snap snapshot
	if err := json.Unmarshal(raw, &snap); err != nil {
		return nil, fmt.Errorf("state file %s: %w", path, err)
	}
	for _, ep := range snap.Endpoints {
		if len(ep.Secrets) == 0 && ep.LegacySecret != "" {
			ep.Secrets = []Secret{{Value: ep.LegacySecret}}
		}
		ep.LegacySecret = ""
		s.endpoints[ep.ID] = ep
	}
	for _, d := range snap.Deliveries {
		s.deliveries[d.ID] = d
	}
	return s, nil
}

// persistLocked writes the state atomically: temp file, fsync, rename, then
// fsync the directory so the rename itself survives a crash.
func (s *Store) persistLocked() error {
	snap := snapshot{}
	for _, ep := range s.endpoints {
		snap.Endpoints = append(snap.Endpoints, ep)
	}
	for _, d := range s.deliveries {
		snap.Deliveries = append(snap.Deliveries, d)
	}
	sort.Slice(snap.Endpoints, func(i, j int) bool { return snap.Endpoints[i].ID < snap.Endpoints[j].ID })
	sort.Slice(snap.Deliveries, func(i, j int) bool { return snap.Deliveries[i].ID < snap.Deliveries[j].ID })
	raw, err := json.Marshal(snap)
	if err != nil {
		return err
	}
	dir := filepath.Dir(s.path)
	tmp, err := os.CreateTemp(dir, ".state-*.json")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	if _, err := tmp.Write(raw); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	if err := os.Rename(tmp.Name(), s.path); err != nil {
		return err
	}
	d, err := os.Open(dir)
	if err != nil {
		return err
	}
	defer d.Close()
	return d.Sync()
}

func (s *Store) CreateEndpoint(ep Endpoint) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.endpoints[ep.ID] = &ep
	return s.persistLocked()
}

// Endpoint returns a copy of the endpoint.
func (s *Store) Endpoint(id string) (Endpoint, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	ep, ok := s.endpoints[id]
	if !ok {
		return Endpoint{}, false
	}
	return *ep, true
}

func (s *Store) EndpointsFor(accountID string) []Endpoint {
	s.mu.Lock()
	defer s.mu.Unlock()
	var out []Endpoint
	for _, ep := range s.endpoints {
		if ep.AccountID == accountID {
			out = append(out, *ep)
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].ID < out[j].ID })
	return out
}

// DeleteEndpoint removes the endpoint and discards its pending deliveries and
// dead letters.
func (s *Store) DeleteEndpoint(id string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.endpoints[id]; !ok {
		return ErrNotFound
	}
	delete(s.endpoints, id)
	delete(s.deadLetters, id)
	for did, d := range s.deliveries {
		if d.EndpointID == id {
			delete(s.deliveries, did)
		}
	}
	return s.persistLocked()
}

func (s *Store) Enqueue(ds []Delivery) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	for i := range ds {
		d := ds[i]
		s.deliveries[d.ID] = &d
	}
	return s.persistLocked()
}

// Due returns up to limit deliveries whose next attempt is at or before now,
// oldest first.
func (s *Store) Due(now time.Time, limit int) []Delivery {
	s.mu.Lock()
	defer s.mu.Unlock()
	var out []Delivery
	for _, d := range s.deliveries {
		if !d.NextAttemptAt.After(now) {
			out = append(out, *d)
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].NextAttemptAt.Before(out[j].NextAttemptAt) })
	if len(out) > limit {
		out = out[:limit]
	}
	return out
}

// Complete removes a delivery that needs no more attempts.
func (s *Store) Complete(id string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	delete(s.deliveries, id)
	return s.persistLocked()
}

func (s *Store) Reschedule(id string, attempt int, next time.Time, lastErr string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	d, ok := s.deliveries[id]
	if !ok {
		return ErrNotFound
	}
	d.Attempt, d.NextAttemptAt, d.LastError = attempt, next, lastErr
	return s.persistLocked()
}
__EOF__
cat > internal/store/store_test.go <<'__EOF__'
package store

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

var t0 = time.Date(2026, 3, 2, 9, 0, 0, 0, time.UTC)

func TestOpenMovesLegacySecret(t *testing.T) {
	path := filepath.Join(t.TempDir(), "state.json")
	old := `{"endpoints":[{"id":"ep1","account_id":"a","url":"https://x.test","secret":"whsec_old"}],"deliveries":[]}`
	if err := os.WriteFile(path, []byte(old), 0o600); err != nil {
		t.Fatal(err)
	}
	s, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	ep, _ := s.Endpoint("ep1")
	if got := ep.ActiveSecrets(t0); len(got) != 1 || got[0] != "whsec_old" {
		t.Fatalf("secrets after migration: %v", got)
	}
}

func TestRotateKeepsPreviousSecretForGrace(t *testing.T) {
	s, _ := Open(filepath.Join(t.TempDir(), "state.json"))
	s.CreateEndpoint(Endpoint{ID: "ep1", Secrets: []Secret{{Value: "one"}}, MaxAttempts: 3})
	ep, err := s.RotateSecret("ep1", "two", t0, time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	if got := ep.ActiveSecrets(t0.Add(30 * time.Minute)); len(got) != 2 || got[0] != "two" {
		t.Fatalf("during grace: %v", got)
	}
	if got := ep.ActiveSecrets(t0.Add(2 * time.Hour)); len(got) != 1 || got[0] != "two" {
		t.Fatalf("after grace: %v", got)
	}
	s.PruneSecrets(t0.Add(2 * time.Hour))
	ep, _ = s.Endpoint("ep1")
	if len(ep.Secrets) != 1 {
		t.Fatalf("prune kept %v", ep.Secrets)
	}
}

func TestDeadLetterAndReplay(t *testing.T) {
	s, _ := Open(filepath.Join(t.TempDir(), "state.json"))
	s.CreateEndpoint(Endpoint{ID: "ep1", Secrets: []Secret{{Value: "one"}}, MaxAttempts: 3})
	d := Delivery{ID: "d1", EndpointID: "ep1", Payload: []byte("{}"), Attempt: 3, NextAttemptAt: t0}
	s.Enqueue([]Delivery{d})
	if err := s.DeadLetter(d, "receiver answered 500", t0); err != nil {
		t.Fatal(err)
	}
	if len(s.Due(t0, 10)) != 0 || len(s.DeadLetters("ep1")) != 1 {
		t.Fatal("delivery should have moved to the dead-letter queue")
	}
	n, err := s.ReplayDeadLetters("ep1", t0)
	if err != nil || n != 1 {
		t.Fatalf("replay: %d %v", n, err)
	}
	due := s.Due(t0, 10)
	if len(due) != 1 || due[0].ID != "d1" || due[0].Attempt != 0 {
		t.Fatalf("replayed delivery: %+v", due)
	}
	if len(s.DeadLetters("ep1")) != 0 {
		t.Fatal("replay should empty the queue")
	}
}
__EOF__

git add -A && git commit -qm 'Add per-endpoint retries, a dead-letter queue and secret rotation'
git diff HEAD~1 HEAD > pr.diff
