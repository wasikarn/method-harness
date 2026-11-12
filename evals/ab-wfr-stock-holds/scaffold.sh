#!/usr/bin/env bash
set -euo pipefail

cat > '.gitignore' <<'__STOCKD_EOF__'
/stockd
*.out
__STOCKD_EOF__
cat > 'Makefile' <<'__STOCKD_EOF__'
.PHONY: build test vet

build:
	go build -o stockd ./cmd/stockd

test:
	go test ./...

vet:
	go vet ./...
__STOCKD_EOF__
cat > 'README.md' <<'__STOCKD_EOF__'
# stockd

Stock-hold service for the web shop. When a shopper adds an item to the cart,
the shop asks stockd to *hold* the units for a while so nobody else can buy
them. At checkout the hold is *confirmed* (the units are sold); if the shopper
gives up, the hold is *released* and the units go back on sale.

    make build
    ./stockd -config config.example.json

API: see [docs/api.md](docs/api.md).

Known gap: holds that run out are refused at checkout, but their units are not
put back on sale until the cart releases them.
__STOCKD_EOF__
mkdir -p 'cmd/stockd'
cat > 'cmd/stockd/main.go' <<'__STOCKD_EOF__'
package main

import (
	"flag"
	"log"
	"net/http"
	"time"

	"example.com/stockd/internal/api"
	"example.com/stockd/internal/clock"
	"example.com/stockd/internal/config"
	"example.com/stockd/internal/reserve"
	"example.com/stockd/internal/store"
)

func main() {
	path := flag.String("config", "config.example.json", "config file")
	flag.Parse()

	cfg, err := config.Load(*path)
	if err != nil {
		log.Fatal(err)
	}
	st := store.NewMemory(cfg.Stock)
	svc := reserve.New(st, clock.Real{}, 15*time.Minute)

	srv := &http.Server{
		Addr:              cfg.ListenAddr,
		Handler:           api.Routes(api.NewHandler(svc)),
		ReadHeaderTimeout: 5 * time.Second,
	}
	log.Printf("stockd listening on %s", cfg.ListenAddr)
	log.Fatal(srv.ListenAndServe())
}
__STOCKD_EOF__
cat > 'config.example.json' <<'__STOCKD_EOF__'
{
  "listen_addr": ":8080",
  "stock": {
    "SKU-MUG": 40,
    "SKU-TEE": 25
  }
}
__STOCKD_EOF__
mkdir -p 'docs'
cat > 'docs/api.md' <<'__STOCKD_EOF__'
# stockd API

Every cart-scoped call must send the shopper's cart id in the `X-Cart-ID`
header. stockd refuses (403) any call that reads or changes another cart's
holds.

Errors come back as `{"error": "..."}` with these codes:

| Code | Meaning |
|------|---------|
| 400  | Bad request body or quantity below 1 |
| 403  | The hold belongs to another cart |
| 404  | No such hold |
| 409  | Not enough stock, or the hold is already confirmed |
| 410  | The hold ran out before checkout |
| 413  | Request body over 1 MiB |

## POST /reservations

Body `{"sku": "SKU-MUG", "qty": 2}`. Holds the units for 15 minutes.
201 with the reservation.

## POST /reservations/{id}/confirm

Turns the hold into a sale. 200 with the reservation.

## DELETE /reservations/{id}

Releases the hold and puts its units back on sale. 204. 404 if there is no
such hold.

## GET /carts/{cart}/reservations

Lists the cart's holds. `{cart}` must match `X-Cart-ID`.

## GET /stock/{sku}

Units on sale right now: `{"sku": "SKU-MUG", "available": 38}`. Public:
product pages call it without a cart, so it needs no `X-Cart-ID`.
__STOCKD_EOF__
cat > 'go.mod' <<'__STOCKD_EOF__'
module example.com/stockd

go 1.22
__STOCKD_EOF__
mkdir -p 'internal/api'
cat > 'internal/api/errors.go' <<'__STOCKD_EOF__'
package api

import (
	"encoding/json"
	"errors"
	"log"
	"net/http"

	"example.com/stockd/internal/reserve"
)

const maxBody = 1 << 20

func statusFor(err error) int {
	switch {
	case errors.Is(err, reserve.ErrBadQty):
		return http.StatusBadRequest
	case errors.Is(err, reserve.ErrNotOwner):
		return http.StatusForbidden
	case errors.Is(err, reserve.ErrNotFound):
		return http.StatusNotFound
	case errors.Is(err, reserve.ErrInsufficient), errors.Is(err, reserve.ErrConfirmed):
		return http.StatusConflict
	case errors.Is(err, reserve.ErrExpired):
		return http.StatusGone
	default:
		return http.StatusInternalServerError
	}
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	if err := json.NewEncoder(w).Encode(v); err != nil {
		log.Printf("write response: %v", err)
	}
}

func writeErr(w http.ResponseWriter, err error) {
	code := statusFor(err)
	msg := err.Error()
	if code == http.StatusInternalServerError {
		log.Printf("internal error: %v", err)
		msg = "internal error"
	}
	writeJSON(w, code, map[string]string{"error": msg})
}

// decode reads a JSON body of at most maxBody bytes into v. It writes the
// error response itself and returns false on failure.
func decode(w http.ResponseWriter, r *http.Request, v any) bool {
	r.Body = http.MaxBytesReader(w, r.Body, maxBody)
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	if err := dec.Decode(v); err != nil {
		var tooBig *http.MaxBytesError
		if errors.As(err, &tooBig) {
			writeJSON(w, http.StatusRequestEntityTooLarge, map[string]string{"error": "body too large"})
			return false
		}
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "bad request body"})
		return false
	}
	return true
}
__STOCKD_EOF__
mkdir -p 'internal/api'
cat > 'internal/api/handlers.go' <<'__STOCKD_EOF__'
package api

import (
	"net/http"

	"example.com/stockd/internal/reserve"
)

// Handler serves the stockd HTTP API.
type Handler struct {
	svc *reserve.Service
}

func NewHandler(svc *reserve.Service) *Handler { return &Handler{svc: svc} }

func cartOf(r *http.Request) string { return r.Header.Get("X-Cart-ID") }

func (h *Handler) create(w http.ResponseWriter, r *http.Request) {
	var req struct {
		SKU string `json:"sku"`
		Qty int    `json:"qty"`
	}
	if cartOf(r) == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "missing X-Cart-ID"})
		return
	}
	if !decode(w, r, &req) {
		return
	}
	res, err := h.svc.Reserve(cartOf(r), req.SKU, req.Qty)
	if err != nil {
		writeErr(w, err)
		return
	}
	writeJSON(w, http.StatusCreated, res)
}

func (h *Handler) confirm(w http.ResponseWriter, r *http.Request) {
	res, err := h.svc.Confirm(cartOf(r), r.PathValue("id"))
	if err != nil {
		writeErr(w, err)
		return
	}
	writeJSON(w, http.StatusOK, res)
}

func (h *Handler) release(w http.ResponseWriter, r *http.Request) {
	if err := h.svc.Release(cartOf(r), r.PathValue("id")); err != nil {
		writeErr(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (h *Handler) listCart(w http.ResponseWriter, r *http.Request) {
	cart := r.PathValue("cart")
	if cart != cartOf(r) {
		writeErr(w, reserve.ErrNotOwner)
		return
	}
	writeJSON(w, http.StatusOK, h.svc.Cart(cart))
}

func (h *Handler) stock(w http.ResponseWriter, r *http.Request) {
	sku := r.PathValue("sku")
	writeJSON(w, http.StatusOK, map[string]any{"sku": sku, "available": h.svc.Available(sku)})
}
__STOCKD_EOF__
mkdir -p 'internal/api'
cat > 'internal/api/handlers_test.go' <<'__STOCKD_EOF__'
package api

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"example.com/stockd/internal/clock"
	"example.com/stockd/internal/model"
	"example.com/stockd/internal/reserve"
	"example.com/stockd/internal/store"
)

func server() http.Handler {
	st := store.NewMemory(map[string]int{"MUG": 5})
	clk := &clock.Fixed{T: time.Date(2026, 3, 1, 12, 0, 0, 0, time.UTC)}
	return Routes(NewHandler(reserve.New(st, clk, 15*time.Minute)))
}

func do(h http.Handler, method, path, cart, body string) *httptest.ResponseRecorder {
	req := httptest.NewRequest(method, path, strings.NewReader(body))
	if cart != "" {
		req.Header.Set("X-Cart-ID", cart)
	}
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	return rec
}

func TestCreateAndRelease(t *testing.T) {
	h := server()
	rec := do(h, "POST", "/reservations", "c1", `{"sku":"MUG","qty":2}`)
	if rec.Code != http.StatusCreated {
		t.Fatalf("create: %d %s", rec.Code, rec.Body)
	}
	var res model.Reservation
	if err := json.Unmarshal(rec.Body.Bytes(), &res); err != nil {
		t.Fatal(err)
	}
	if rec := do(h, "DELETE", "/reservations/"+res.ID, "c2", ""); rec.Code != http.StatusForbidden {
		t.Fatalf("release by other cart: %d", rec.Code)
	}
	if rec := do(h, "DELETE", "/reservations/"+res.ID, "c1", ""); rec.Code != http.StatusNoContent {
		t.Fatalf("release: %d", rec.Code)
	}
}

func TestListOtherCart(t *testing.T) {
	h := server()
	if rec := do(h, "GET", "/carts/c1/reservations", "c2", ""); rec.Code != http.StatusForbidden {
		t.Fatalf("list other cart: %d", rec.Code)
	}
}

func TestBodyTooLarge(t *testing.T) {
	h := server()
	body := `{"sku":"` + strings.Repeat("x", maxBody) + `","qty":1}`
	if rec := do(h, "POST", "/reservations", "c1", body); rec.Code != http.StatusRequestEntityTooLarge {
		t.Fatalf("got %d", rec.Code)
	}
}
__STOCKD_EOF__
mkdir -p 'internal/api'
cat > 'internal/api/routes.go' <<'__STOCKD_EOF__'
package api

import "net/http"

// Routes wires the handlers into a mux.
func Routes(h *Handler) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("POST /reservations", h.create)
	mux.HandleFunc("POST /reservations/{id}/confirm", h.confirm)
	mux.HandleFunc("DELETE /reservations/{id}", h.release)
	mux.HandleFunc("GET /carts/{cart}/reservations", h.listCart)
	mux.HandleFunc("GET /stock/{sku}", h.stock)
	return mux
}
__STOCKD_EOF__
mkdir -p 'internal/clock'
cat > 'internal/clock/clock.go' <<'__STOCKD_EOF__'
package clock

import "time"

// Clock lets tests control time.
type Clock interface {
	Now() time.Time
}

// Real is the wall clock.
type Real struct{}

func (Real) Now() time.Time { return time.Now() }

// Fixed is a settable clock for tests.
type Fixed struct{ T time.Time }

func (f *Fixed) Now() time.Time { return f.T }

func (f *Fixed) Advance(d time.Duration) { f.T = f.T.Add(d) }
__STOCKD_EOF__
mkdir -p 'internal/config'
cat > 'internal/config/config.go' <<'__STOCKD_EOF__'
package config

import (
	"encoding/json"
	"fmt"
	"os"
)

// Config is read from a JSON file at start-up.
type Config struct {
	ListenAddr string         `json:"listen_addr"`
	Stock      map[string]int `json:"stock"` // SKU -> units on sale at start
}

// Load reads and checks the config file.
func Load(path string) (Config, error) {
	var c Config
	b, err := os.ReadFile(path)
	if err != nil {
		return c, err
	}
	if err := json.Unmarshal(b, &c); err != nil {
		return c, fmt.Errorf("parse %s: %w", path, err)
	}
	if c.ListenAddr == "" {
		c.ListenAddr = ":8080"
	}
	for sku, n := range c.Stock {
		if n < 0 {
			return c, fmt.Errorf("stock for %s is negative", sku)
		}
	}
	return c, nil
}
__STOCKD_EOF__
mkdir -p 'internal/config'
cat > 'internal/config/config_test.go' <<'__STOCKD_EOF__'
package config

import (
	"os"
	"path/filepath"
	"testing"
)

func write(t *testing.T, body string) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), "c.json")
	if err := os.WriteFile(p, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	return p
}

func TestLoadDefaults(t *testing.T) {
	c, err := Load(write(t, `{"stock": {"A": 3}}`))
	if err != nil {
		t.Fatal(err)
	}
	if c.ListenAddr != ":8080" || c.Stock["A"] != 3 {
		t.Fatalf("got %+v", c)
	}
}

func TestLoadRejectsNegativeStock(t *testing.T) {
	if _, err := Load(write(t, `{"stock": {"A": -1}}`)); err == nil {
		t.Fatal("want error")
	}
}
__STOCKD_EOF__
mkdir -p 'internal/model'
cat > 'internal/model/model.go' <<'__STOCKD_EOF__'
package model

import "time"

type Status string

const (
	StatusHeld      Status = "held"
	StatusConfirmed Status = "confirmed"
)

// Reservation holds Qty units of SKU for a cart. A held reservation is valid
// strictly before ExpiresAt; at ExpiresAt it has run out. Confirming turns the
// hold into a sale: the units stay off sale for good, and ExpiresAt is kept
// only as a record of when the hold would have run out.
type Reservation struct {
	ID        string    `json:"id"`
	CartID    string    `json:"cart_id"`
	SKU       string    `json:"sku"`
	Qty       int       `json:"qty"`
	Status    Status    `json:"status"`
	CreatedAt time.Time `json:"created_at"`
	ExpiresAt time.Time `json:"expires_at"`
}
__STOCKD_EOF__
mkdir -p 'internal/reserve'
cat > 'internal/reserve/service.go' <<'__STOCKD_EOF__'
package reserve

import (
	"errors"
	"time"

	"example.com/stockd/internal/clock"
	"example.com/stockd/internal/model"
	"example.com/stockd/internal/store"
)

var (
	ErrBadQty       = errors.New("quantity must be at least 1")
	ErrInsufficient = errors.New("not enough stock")
	ErrNotFound     = store.ErrNotFound
	ErrNotOwner     = errors.New("reservation belongs to another cart")
	ErrExpired      = errors.New("reservation has run out")
	ErrConfirmed    = errors.New("reservation is already confirmed")
)

// Service holds, confirms and releases stock for carts.
type Service struct {
	store store.Store
	clock clock.Clock
	hold  time.Duration
}

// New returns a Service whose holds last for hold.
func New(s store.Store, c clock.Clock, hold time.Duration) *Service {
	return &Service{store: s, clock: c, hold: hold}
}

// Reserve takes qty units of sku off sale and holds them for the cart.
func (s *Service) Reserve(cartID, sku string, qty int) (model.Reservation, error) {
	if qty <= 0 {
		return model.Reservation{}, ErrBadQty
	}
	if !s.store.Take(sku, qty) {
		return model.Reservation{}, ErrInsufficient
	}
	now := s.clock.Now()
	return s.store.Insert(model.Reservation{
		CartID:    cartID,
		SKU:       sku,
		Qty:       qty,
		Status:    model.StatusHeld,
		CreatedAt: now,
		ExpiresAt: now.Add(s.hold),
	}), nil
}

// Confirm turns a live hold into a sale.
func (s *Service) Confirm(cartID, id string) (model.Reservation, error) {
	now := s.clock.Now()
	return s.store.Update(id, func(r *model.Reservation) error {
		if r.CartID != cartID {
			return ErrNotOwner
		}
		if r.Status == model.StatusConfirmed {
			return ErrConfirmed
		}
		if !now.Before(r.ExpiresAt) {
			return ErrExpired
		}
		r.Status = model.StatusConfirmed
		return nil
	})
}

// Release drops a hold and puts its units back on sale.
func (s *Service) Release(cartID, id string) error {
	r, err := s.store.Remove(id, func(r model.Reservation) error {
		if r.CartID != cartID {
			return ErrNotOwner
		}
		if r.Status == model.StatusConfirmed {
			return ErrConfirmed
		}
		return nil
	})
	if err != nil {
		return err
	}
	s.store.Restock(r.SKU, r.Qty)
	return nil
}

// Cart lists the cart's reservations.
func (s *Service) Cart(cartID string) []model.Reservation {
	return s.store.ByCart(cartID)
}

// Available is the number of units of sku on sale.
func (s *Service) Available(sku string) int {
	return s.store.Available(sku)
}
__STOCKD_EOF__
mkdir -p 'internal/reserve'
cat > 'internal/reserve/service_test.go' <<'__STOCKD_EOF__'
package reserve

import (
	"errors"
	"testing"
	"time"

	"example.com/stockd/internal/clock"
	"example.com/stockd/internal/store"
)

func setup() (*Service, *store.Memory, *clock.Fixed) {
	st := store.NewMemory(map[string]int{"MUG": 5})
	clk := &clock.Fixed{T: time.Date(2026, 3, 1, 12, 0, 0, 0, time.UTC)}
	return New(st, clk, 15*time.Minute), st, clk
}

func TestReserveConfirm(t *testing.T) {
	svc, st, _ := setup()
	r, err := svc.Reserve("c1", "MUG", 2)
	if err != nil {
		t.Fatal(err)
	}
	if st.Available("MUG") != 3 {
		t.Fatalf("available = %d", st.Available("MUG"))
	}
	if _, err := svc.Confirm("c1", r.ID); err != nil {
		t.Fatal(err)
	}
	if err := svc.Release("c1", r.ID); !errors.Is(err, ErrConfirmed) {
		t.Fatalf("release after confirm: %v", err)
	}
}

func TestConfirmAfterHoldRunsOut(t *testing.T) {
	svc, _, clk := setup()
	r, _ := svc.Reserve("c1", "MUG", 1)
	clk.Advance(15 * time.Minute)
	if _, err := svc.Confirm("c1", r.ID); !errors.Is(err, ErrExpired) {
		t.Fatalf("err = %v, want ErrExpired", err)
	}
}

func TestReleaseOtherCart(t *testing.T) {
	svc, st, _ := setup()
	r, _ := svc.Reserve("c1", "MUG", 1)
	if err := svc.Release("c2", r.ID); !errors.Is(err, ErrNotOwner) {
		t.Fatalf("err = %v", err)
	}
	if err := svc.Release("c1", r.ID); err != nil {
		t.Fatal(err)
	}
	if st.Available("MUG") != 5 {
		t.Fatalf("available = %d", st.Available("MUG"))
	}
}

func TestReserveBadQty(t *testing.T) {
	svc, _, _ := setup()
	if _, err := svc.Reserve("c1", "MUG", 0); !errors.Is(err, ErrBadQty) {
		t.Fatalf("err = %v", err)
	}
}
__STOCKD_EOF__
mkdir -p 'internal/store'
cat > 'internal/store/memory.go' <<'__STOCKD_EOF__'
package store

import (
	"fmt"
	"sort"
	"sync"

	"example.com/stockd/internal/model"
)

// Memory is an in-process Store.
type Memory struct {
	mu    sync.Mutex
	stock map[string]int
	res   map[string]model.Reservation
	next  int
}

func NewMemory(stock map[string]int) *Memory {
	m := &Memory{stock: map[string]int{}, res: map[string]model.Reservation{}}
	for sku, n := range stock {
		m.stock[sku] = n
	}
	return m
}

func (m *Memory) Take(sku string, qty int) bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.stock[sku] < qty {
		return false
	}
	m.stock[sku] -= qty
	return true
}

func (m *Memory) Restock(sku string, qty int) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.stock[sku] += qty
}

func (m *Memory) Available(sku string) int {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.stock[sku]
}

func (m *Memory) Insert(r model.Reservation) model.Reservation {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.next++
	r.ID = fmt.Sprintf("r%d", m.next)
	m.res[r.ID] = r
	return r
}

func (m *Memory) Get(id string) (model.Reservation, bool) {
	m.mu.Lock()
	defer m.mu.Unlock()
	r, ok := m.res[id]
	return r, ok
}

func (m *Memory) Update(id string, fn func(*model.Reservation) error) (model.Reservation, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	r, ok := m.res[id]
	if !ok {
		return model.Reservation{}, ErrNotFound
	}
	if err := fn(&r); err != nil {
		return model.Reservation{}, err
	}
	m.res[id] = r
	return r, nil
}

func (m *Memory) Remove(id string, check func(model.Reservation) error) (model.Reservation, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	r, ok := m.res[id]
	if !ok {
		return model.Reservation{}, ErrNotFound
	}
	if check != nil {
		if err := check(r); err != nil {
			return model.Reservation{}, err
		}
	}
	delete(m.res, id)
	return r, nil
}

func (m *Memory) ByCart(cartID string) []model.Reservation {
	m.mu.Lock()
	defer m.mu.Unlock()
	var out []model.Reservation
	for _, r := range m.res {
		if r.CartID == cartID {
			out = append(out, r)
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].CreatedAt.Before(out[j].CreatedAt) })
	return out
}
__STOCKD_EOF__
mkdir -p 'internal/store'
cat > 'internal/store/memory_test.go' <<'__STOCKD_EOF__'
package store

import (
	"errors"
	"testing"

	"example.com/stockd/internal/model"
)

func TestTake(t *testing.T) {
	m := NewMemory(map[string]int{"A": 3})
	if !m.Take("A", 2) {
		t.Fatal("take 2 of 3 should succeed")
	}
	if m.Take("A", 2) {
		t.Fatal("take 2 of 1 should fail")
	}
	if got := m.Available("A"); got != 1 {
		t.Fatalf("available = %d, want 1", got)
	}
}

func TestRemoveCheck(t *testing.T) {
	m := NewMemory(nil)
	r := m.Insert(model.Reservation{CartID: "c1"})
	stop := errors.New("stop")
	if _, err := m.Remove(r.ID, func(model.Reservation) error { return stop }); err != stop {
		t.Fatalf("err = %v, want stop", err)
	}
	if _, ok := m.Get(r.ID); !ok {
		t.Fatal("check failed, reservation must stay")
	}
	if _, err := m.Remove(r.ID, nil); err != nil {
		t.Fatal(err)
	}
	if _, err := m.Remove(r.ID, nil); err != ErrNotFound {
		t.Fatalf("err = %v, want ErrNotFound", err)
	}
}
__STOCKD_EOF__
mkdir -p 'internal/store'
cat > 'internal/store/store.go' <<'__STOCKD_EOF__'
package store

import (
	"errors"

	"example.com/stockd/internal/model"
)

var ErrNotFound = errors.New("reservation not found")

// Store keeps stock levels and reservations. Every method is atomic.
type Store interface {
	// Take removes qty units of sku from sale if at least qty are on sale,
	// and reports whether it did.
	Take(sku string, qty int) bool
	// Restock puts qty units of sku back on sale.
	Restock(sku string, qty int)
	// Available is the number of units of sku on sale.
	Available(sku string) int

	// Insert stores r under a new ID and returns it.
	Insert(r model.Reservation) model.Reservation
	Get(id string) (model.Reservation, bool)
	// Update runs fn on the stored reservation and saves the result if fn
	// returns nil.
	Update(id string, fn func(*model.Reservation) error) (model.Reservation, error)
	// Remove deletes the reservation if check returns nil for it. A nil
	// check always deletes.
	Remove(id string, check func(model.Reservation) error) (model.Reservation, error)
	ByCart(cartID string) []model.Reservation
}
__STOCKD_EOF__

git init -q . && git config user.email dev@example.com && git config user.name dev
git add -A && git commit -qm "stockd 0.1.0"

# --- pull request ---

cat > 'CHANGELOG.md' <<'__STOCKD_EOF__'
# Changelog

## 0.2.0

- Stock is kept per warehouse. Holds draw from open warehouses in priority
  order and split across them when needed; each reservation lists its `parts`.
- New sweeper puts run-out holds back on sale every `sweep_seconds`.
- Hold length is configurable with `hold_minutes` (default 15).
- New cart endpoints: hold several lines at once, and release a whole cart.
- `DELETE /reservations/{id}` answers 204 when the hold is already gone.
- `GET /stock/{sku}` also reports units per warehouse.
- Quantity checks moved to the API layer.

## 0.1.0

- First release: hold, confirm and release stock for carts.
__STOCKD_EOF__
cat > 'README.md' <<'__STOCKD_EOF__'
# stockd

Stock-hold service for the web shop. When a shopper adds an item to the cart,
the shop asks stockd to *hold* the units for a while so nobody else can buy
them. At checkout the hold is *confirmed* (the units are sold); if the shopper
gives up, the hold is *released* and the units go back on sale.

Stock lives in several warehouses. A hold draws from the open warehouses in
priority order and is split across them when one alone does not have enough.
A background sweeper puts the units of run-out holds back on sale.

    make build
    ./stockd -config config.example.json

Config keys: see `internal/config/config.go`. API: see [docs/api.md](docs/api.md).
__STOCKD_EOF__
mkdir -p 'cmd/stockd'
cat > 'cmd/stockd/main.go' <<'__STOCKD_EOF__'
package main

import (
	"context"
	"errors"
	"flag"
	"log"
	"net/http"
	"os/signal"
	"syscall"
	"time"

	"example.com/stockd/internal/api"
	"example.com/stockd/internal/clock"
	"example.com/stockd/internal/config"
	"example.com/stockd/internal/reserve"
	"example.com/stockd/internal/store"
)

func main() {
	path := flag.String("config", "config.example.json", "config file")
	flag.Parse()

	cfg, err := config.Load(*path)
	if err != nil {
		log.Fatal(err)
	}
	st := store.NewMemory(cfg.Stock)
	hold := time.Duration(cfg.HoldMinutes) * time.Second
	svc := reserve.New(st, clock.Real{}, hold, cfg.Warehouses)

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	go svc.RunSweeper(ctx, time.Duration(cfg.SweepSeconds)*time.Second)

	srv := &http.Server{
		Addr:              cfg.ListenAddr,
		Handler:           api.Routes(api.NewHandler(svc)),
		ReadHeaderTimeout: 5 * time.Second,
	}
	drained := make(chan struct{})
	go func() {
		defer close(drained)
		<-ctx.Done()
		shutdown, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		if err := srv.Shutdown(shutdown); err != nil {
			log.Printf("shutdown: %v", err)
		}
	}()
	log.Printf("stockd listening on %s (holds last %s)", cfg.ListenAddr, hold)
	if err := srv.ListenAndServe(); !errors.Is(err, http.ErrServerClosed) {
		log.Fatal(err)
	}
	<-drained
}
__STOCKD_EOF__
cat > 'config.example.json' <<'__STOCKD_EOF__'
{
  "listen_addr": ":8080",
  "hold_minutes": 15,
  "sweep_seconds": 30,
  "warehouses": [
    {"id": "bangna", "priority": 1, "enabled": true},
    {"id": "lamlukka", "priority": 2, "enabled": true}
  ],
  "stock": {
    "bangna": {"SKU-MUG": 30, "SKU-TEE": 25},
    "lamlukka": {"SKU-MUG": 10}
  }
}
__STOCKD_EOF__
mkdir -p 'docs'
cat > 'docs/api.md' <<'__STOCKD_EOF__'
# stockd API

Every cart-scoped call must send the shopper's cart id in the `X-Cart-ID`
header. stockd refuses (403) any call that reads or changes another cart's
holds.

Errors come back as `{"error": "..."}` with these codes:

| Code | Meaning |
|------|---------|
| 400  | Bad request body or quantity below 1 |
| 403  | The hold belongs to another cart |
| 404  | No such hold |
| 409  | Not enough stock, or the hold is already confirmed |
| 410  | The hold ran out before checkout |
| 413  | Request body over 1 MiB |

A reservation looks like:

    {"id": "r7", "cart_id": "c1", "sku": "SKU-MUG", "qty": 3,
     "parts": [{"warehouse": "bangna", "qty": 2}, {"warehouse": "lamlukka", "qty": 1}],
     "status": "held", "created_at": "...", "expires_at": "..."}

## POST /reservations

Body `{"sku": "SKU-MUG", "qty": 2}`. Holds the units for `hold_minutes`
(default 15). 201 with the reservation.

## POST /reservations/{id}/confirm

Turns the hold into a sale. 200 with the reservation.

## DELETE /reservations/{id}

Releases the hold and puts its units back on sale. 204, also when the hold
is already gone (released earlier or dropped by the sweeper), so a client
can safely retry.

## GET /carts/{cart}/reservations

Lists the cart's holds.

## POST /carts/{cart}/reservations

Body `{"lines": [{"sku": "SKU-MUG", "qty": 2}, ...]}`. Holds every line or
none: if one line cannot be held, the lines already held are released and
the error for that line is returned. 201 with the list of reservations.

## DELETE /carts/{cart}/reservations

Releases every hold of the cart that is not confirmed yet.
200 `{"released": 2}`.

## GET /stock/{sku}

Units on sale right now, in total and per open warehouse:
`{"sku": "SKU-MUG", "available": 38, "warehouses": {"bangna": 28, "lamlukka": 10}}`.
Public: product pages call it without a cart, so it needs no `X-Cart-ID`.
__STOCKD_EOF__
mkdir -p 'internal/api'
cat > 'internal/api/handlers.go' <<'__STOCKD_EOF__'
package api

import (
	"errors"
	"log"
	"net/http"

	"example.com/stockd/internal/model"
	"example.com/stockd/internal/reserve"
)

// Handler serves the stockd HTTP API.
type Handler struct {
	svc *reserve.Service
}

func NewHandler(svc *reserve.Service) *Handler { return &Handler{svc: svc} }

func cartOf(r *http.Request) string { return r.Header.Get("X-Cart-ID") }

type line struct {
	SKU string `json:"sku"`
	Qty int    `json:"qty"`
}

func (h *Handler) create(w http.ResponseWriter, r *http.Request) {
	var req line
	if cartOf(r) == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "missing X-Cart-ID"})
		return
	}
	if !decode(w, r, &req) {
		return
	}
	if req.Qty < 1 {
		writeErr(w, reserve.ErrBadQty)
		return
	}
	res, err := h.svc.Reserve(cartOf(r), req.SKU, req.Qty)
	if err != nil {
		writeErr(w, err)
		return
	}
	writeJSON(w, http.StatusCreated, res)
}

// reserveCart holds several lines at once: all of them or none.
func (h *Handler) reserveCart(w http.ResponseWriter, r *http.Request) {
	cart := r.PathValue("cart")
	if cart != cartOf(r) {
		writeErr(w, reserve.ErrNotOwner)
		return
	}
	var req struct {
		Lines []line `json:"lines"`
	}
	if !decode(w, r, &req) {
		return
	}
	made := []model.Reservation{}
	for _, l := range req.Lines {
		res, err := h.svc.Reserve(cart, l.SKU, l.Qty)
		if err != nil {
			for _, m := range made {
				if rerr := h.svc.Release(cart, m.ID); rerr != nil && !errors.Is(rerr, reserve.ErrNotFound) {
					log.Printf("undo hold %s: %v", m.ID, rerr)
				}
			}
			writeErr(w, err)
			return
		}
		made = append(made, res)
	}
	writeJSON(w, http.StatusCreated, made)
}

func (h *Handler) confirm(w http.ResponseWriter, r *http.Request) {
	res, err := h.svc.Confirm(cartOf(r), r.PathValue("id"))
	if err != nil {
		writeErr(w, err)
		return
	}
	writeJSON(w, http.StatusOK, res)
}

func (h *Handler) release(w http.ResponseWriter, r *http.Request) {
	err := h.svc.Release(cartOf(r), r.PathValue("id"))
	// A hold that is already gone (released before, or dropped by the
	// sweeper) is what the caller wants: answer 204 so a retried DELETE
	// does not show the shopper an error. Nothing is restocked twice,
	// because Release only restocks a hold it removed.
	if err != nil && !errors.Is(err, reserve.ErrNotFound) {
		writeErr(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (h *Handler) releaseCart(w http.ResponseWriter, r *http.Request) {
	n := h.svc.ReleaseCart(r.PathValue("cart"))
	writeJSON(w, http.StatusOK, map[string]int{"released": n})
}

func (h *Handler) listCart(w http.ResponseWriter, r *http.Request) {
	cart := r.PathValue("cart")
	if cart != cartOf(r) {
		writeErr(w, reserve.ErrNotOwner)
		return
	}
	writeJSON(w, http.StatusOK, h.svc.Cart(cart))
}

// stock is public: product pages call it without a cart (docs/api.md).
func (h *Handler) stock(w http.ResponseWriter, r *http.Request) {
	sku := r.PathValue("sku")
	per := h.svc.Available(sku)
	total := 0
	for _, n := range per {
		total += n
	}
	writeJSON(w, http.StatusOK, map[string]any{"sku": sku, "available": total, "warehouses": per})
}
__STOCKD_EOF__
mkdir -p 'internal/api'
cat > 'internal/api/handlers_test.go' <<'__STOCKD_EOF__'
package api

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"example.com/stockd/internal/clock"
	"example.com/stockd/internal/config"
	"example.com/stockd/internal/model"
	"example.com/stockd/internal/reserve"
	"example.com/stockd/internal/store"
)

func server() http.Handler {
	st := store.NewMemory(map[string]map[string]int{"w1": {"MUG": 3, "TEE": 1}, "w2": {"MUG": 2}})
	clk := &clock.Fixed{T: time.Date(2026, 3, 1, 12, 0, 0, 0, time.UTC)}
	whs := []config.Warehouse{{ID: "w1", Priority: 1, Enabled: true}, {ID: "w2", Priority: 2, Enabled: true}}
	return Routes(NewHandler(reserve.New(st, clk, 15*time.Minute, whs)))
}

func do(h http.Handler, method, path, cart, body string) *httptest.ResponseRecorder {
	req := httptest.NewRequest(method, path, strings.NewReader(body))
	if cart != "" {
		req.Header.Set("X-Cart-ID", cart)
	}
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	return rec
}

func available(t *testing.T, h http.Handler, sku string) int {
	t.Helper()
	var got struct {
		Available int `json:"available"`
	}
	if err := json.Unmarshal(do(h, "GET", "/stock/"+sku, "", "").Body.Bytes(), &got); err != nil {
		t.Fatal(err)
	}
	return got.Available
}

func TestCreateAndRelease(t *testing.T) {
	h := server()
	rec := do(h, "POST", "/reservations", "c1", `{"sku":"MUG","qty":2}`)
	if rec.Code != http.StatusCreated {
		t.Fatalf("create: %d %s", rec.Code, rec.Body)
	}
	var res model.Reservation
	if err := json.Unmarshal(rec.Body.Bytes(), &res); err != nil {
		t.Fatal(err)
	}
	if rec := do(h, "DELETE", "/reservations/"+res.ID, "c2", ""); rec.Code != http.StatusForbidden {
		t.Fatalf("release by other cart: %d", rec.Code)
	}
	for i := 0; i < 2; i++ {
		if rec := do(h, "DELETE", "/reservations/"+res.ID, "c1", ""); rec.Code != http.StatusNoContent {
			t.Fatalf("release #%d: %d", i+1, rec.Code)
		}
	}
	if got := available(t, h, "MUG"); got != 5 {
		t.Fatalf("available = %d, want 5", got)
	}
}

func TestCreateBadQty(t *testing.T) {
	h := server()
	if rec := do(h, "POST", "/reservations", "c1", `{"sku":"MUG","qty":0}`); rec.Code != http.StatusBadRequest {
		t.Fatalf("got %d", rec.Code)
	}
}

func TestReserveCartAllOrNothing(t *testing.T) {
	h := server()
	rec := do(h, "POST", "/carts/c1/reservations", "c1", `{"lines":[{"sku":"MUG","qty":2},{"sku":"HAT","qty":1}]}`)
	if rec.Code != http.StatusConflict {
		t.Fatalf("got %d %s", rec.Code, rec.Body)
	}
	if got := available(t, h, "MUG"); got != 5 {
		t.Fatalf("MUG available = %d, want 5 after undo", got)
	}
	rec = do(h, "POST", "/carts/c1/reservations", "c1", `{"lines":[{"sku":"MUG","qty":2},{"sku":"TEE","qty":1}]}`)
	if rec.Code != http.StatusCreated {
		t.Fatalf("got %d %s", rec.Code, rec.Body)
	}
}

func TestReserveCartOtherCart(t *testing.T) {
	h := server()
	if rec := do(h, "POST", "/carts/c1/reservations", "c2", `{"lines":[]}`); rec.Code != http.StatusForbidden {
		t.Fatalf("got %d", rec.Code)
	}
}

func TestListOtherCart(t *testing.T) {
	h := server()
	if rec := do(h, "GET", "/carts/c1/reservations", "c2", ""); rec.Code != http.StatusForbidden {
		t.Fatalf("list other cart: %d", rec.Code)
	}
}

func TestBodyTooLarge(t *testing.T) {
	h := server()
	body := `{"sku":"` + strings.Repeat("x", maxBody) + `","qty":1}`
	if rec := do(h, "POST", "/reservations", "c1", body); rec.Code != http.StatusRequestEntityTooLarge {
		t.Fatalf("got %d", rec.Code)
	}
}
__STOCKD_EOF__
mkdir -p 'internal/api'
cat > 'internal/api/routes.go' <<'__STOCKD_EOF__'
package api

import "net/http"

// Routes wires the handlers into a mux.
func Routes(h *Handler) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("POST /reservations", h.create)
	mux.HandleFunc("POST /reservations/{id}/confirm", h.confirm)
	mux.HandleFunc("DELETE /reservations/{id}", h.release)
	mux.HandleFunc("GET /carts/{cart}/reservations", h.listCart)
	mux.HandleFunc("POST /carts/{cart}/reservations", h.reserveCart)
	mux.HandleFunc("DELETE /carts/{cart}/reservations", h.releaseCart)
	mux.HandleFunc("GET /stock/{sku}", h.stock)
	return mux
}
__STOCKD_EOF__
mkdir -p 'internal/config'
cat > 'internal/config/config.go' <<'__STOCKD_EOF__'
package config

import (
	"encoding/json"
	"fmt"
	"os"
)

// Warehouse is one stock location.
type Warehouse struct {
	ID string `json:"id"`
	// Priority orders the warehouses a hold draws from: 1 is tried first,
	// then 2, and so on. Ties go by ID.
	Priority int `json:"priority"`
	// Enabled is false while a warehouse is closed (e.g. for a stock count).
	// Nothing is held from a closed warehouse.
	Enabled bool `json:"enabled"`
}

// Config is read from a JSON file at start-up.
type Config struct {
	ListenAddr string      `json:"listen_addr"`
	Warehouses []Warehouse `json:"warehouses"`
	// Stock is warehouse ID -> SKU -> units on sale at start.
	Stock map[string]map[string]int `json:"stock"`
	// HoldMinutes is how long a hold lasts, in minutes. Default 15.
	HoldMinutes int `json:"hold_minutes"`
	// SweepSeconds is how often run-out holds are put back on sale, in
	// seconds. Default 30.
	SweepSeconds int `json:"sweep_seconds"`
}

// Load reads and checks the config file.
func Load(path string) (Config, error) {
	var c Config
	b, err := os.ReadFile(path)
	if err != nil {
		return c, err
	}
	if err := json.Unmarshal(b, &c); err != nil {
		return c, fmt.Errorf("parse %s: %w", path, err)
	}
	if c.ListenAddr == "" {
		c.ListenAddr = ":8080"
	}
	if c.HoldMinutes == 0 {
		c.HoldMinutes = 15
	}
	if c.SweepSeconds == 0 {
		c.SweepSeconds = 30
	}
	if c.HoldMinutes < 0 || c.SweepSeconds < 0 {
		return c, fmt.Errorf("hold_minutes and sweep_seconds must be positive")
	}
	if len(c.Warehouses) == 0 {
		return c, fmt.Errorf("at least one warehouse is required")
	}
	known := map[string]bool{}
	for _, w := range c.Warehouses {
		if w.ID == "" || known[w.ID] {
			return c, fmt.Errorf("warehouse id %q is empty or repeated", w.ID)
		}
		known[w.ID] = true
	}
	for wh, skus := range c.Stock {
		if !known[wh] {
			return c, fmt.Errorf("stock for unknown warehouse %q", wh)
		}
		for sku, n := range skus {
			if n < 0 {
				return c, fmt.Errorf("stock for %s in %s is negative", sku, wh)
			}
		}
	}
	return c, nil
}
__STOCKD_EOF__
mkdir -p 'internal/config'
cat > 'internal/config/config_test.go' <<'__STOCKD_EOF__'
package config

import (
	"os"
	"path/filepath"
	"testing"
)

func write(t *testing.T, body string) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), "c.json")
	if err := os.WriteFile(p, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	return p
}

func TestLoadDefaults(t *testing.T) {
	c, err := Load(write(t, `{"warehouses": [{"id": "main", "priority": 1, "enabled": true}],
		"stock": {"main": {"A": 3}}}`))
	if err != nil {
		t.Fatal(err)
	}
	if c.ListenAddr != ":8080" || c.Stock["main"]["A"] != 3 {
		t.Fatalf("got %+v", c)
	}
	if c.HoldMinutes != 15 || c.SweepSeconds != 30 {
		t.Fatalf("defaults: hold=%d sweep=%d", c.HoldMinutes, c.SweepSeconds)
	}
}

func TestLoadRejectsNegativeStock(t *testing.T) {
	_, err := Load(write(t, `{"warehouses": [{"id": "main", "priority": 1, "enabled": true}],
		"stock": {"main": {"A": -1}}}`))
	if err == nil {
		t.Fatal("want error")
	}
}

func TestLoadRejectsUnknownWarehouse(t *testing.T) {
	_, err := Load(write(t, `{"warehouses": [{"id": "main", "priority": 1, "enabled": true}],
		"stock": {"north": {"A": 1}}}`))
	if err == nil {
		t.Fatal("want error")
	}
}

func TestLoadNeedsWarehouse(t *testing.T) {
	if _, err := Load(write(t, `{}`)); err == nil {
		t.Fatal("want error")
	}
}
__STOCKD_EOF__
mkdir -p 'internal/model'
cat > 'internal/model/model.go' <<'__STOCKD_EOF__'
package model

import "time"

type Status string

const (
	StatusHeld      Status = "held"
	StatusConfirmed Status = "confirmed"
)

// Part is the share of a reservation drawn from one warehouse.
type Part struct {
	Warehouse string `json:"warehouse"`
	Qty       int    `json:"qty"`
}

// Reservation holds Qty units of SKU for a cart, drawn from one or more
// warehouses (Parts; their Qty adds up to Qty). A held reservation is valid
// strictly before ExpiresAt; at ExpiresAt it has run out. Confirming turns the
// hold into a sale: the units stay off sale for good, and ExpiresAt is kept
// only as a record of when the hold would have run out.
type Reservation struct {
	ID        string    `json:"id"`
	CartID    string    `json:"cart_id"`
	SKU       string    `json:"sku"`
	Qty       int       `json:"qty"`
	Parts     []Part    `json:"parts"`
	Status    Status    `json:"status"`
	CreatedAt time.Time `json:"created_at"`
	ExpiresAt time.Time `json:"expires_at"`
}
__STOCKD_EOF__
mkdir -p 'internal/reserve'
cat > 'internal/reserve/allocate.go' <<'__STOCKD_EOF__'
package reserve

import (
	"sort"

	"example.com/stockd/internal/config"
)

// drawOrder returns the open warehouses in the order holds draw from them:
// priority 1 first, then 2, and so on, ties by ID (see config.Warehouse).
// Closed warehouses are left out.
func drawOrder(whs []config.Warehouse) []config.Warehouse {
	out := make([]config.Warehouse, 0, len(whs))
	for _, w := range whs {
		if w.Enabled {
			out = append(out, w)
		}
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].Priority != out[j].Priority {
			return out[i].Priority < out[j].Priority
		}
		return out[i].ID < out[j].ID
	})
	return out
}
__STOCKD_EOF__
mkdir -p 'internal/reserve'
cat > 'internal/reserve/allocate_test.go' <<'__STOCKD_EOF__'
package reserve

import (
	"testing"

	"example.com/stockd/internal/config"
)

func TestDrawOrder(t *testing.T) {
	got := drawOrder([]config.Warehouse{
		{ID: "c", Priority: 2, Enabled: true},
		{ID: "b", Priority: 1, Enabled: true},
		{ID: "closed", Priority: 1, Enabled: false},
		{ID: "a", Priority: 2, Enabled: true},
	})
	want := []string{"b", "a", "c"}
	if len(got) != len(want) {
		t.Fatalf("got %v", got)
	}
	for i, w := range got {
		if w.ID != want[i] {
			t.Fatalf("position %d: got %s, want %s", i, w.ID, want[i])
		}
	}
}
__STOCKD_EOF__
mkdir -p 'internal/reserve'
cat > 'internal/reserve/service.go' <<'__STOCKD_EOF__'
package reserve

import (
	"errors"
	"time"

	"example.com/stockd/internal/clock"
	"example.com/stockd/internal/config"
	"example.com/stockd/internal/model"
	"example.com/stockd/internal/store"
)

var (
	ErrBadQty       = errors.New("quantity must be at least 1")
	ErrInsufficient = errors.New("not enough stock")
	ErrNotFound     = store.ErrNotFound
	ErrNotOwner     = errors.New("reservation belongs to another cart")
	ErrExpired      = errors.New("reservation has run out")
	ErrConfirmed    = errors.New("reservation is already confirmed")
)

// Service holds, confirms and releases stock for carts.
type Service struct {
	store store.Store
	clock clock.Clock
	hold  time.Duration
	order []config.Warehouse
}

// New returns a Service whose holds last for hold and draw from the open
// warehouses in whs.
func New(s store.Store, c clock.Clock, hold time.Duration, whs []config.Warehouse) *Service {
	return &Service{store: s, clock: c, hold: hold, order: drawOrder(whs)}
}

// Reserve takes qty units of sku off sale and holds them for the cart. When
// no single warehouse has enough, the hold is split across warehouses in
// draw order.
func (s *Service) Reserve(cartID, sku string, qty int) (model.Reservation, error) {
	var parts []model.Part
	need := qty
	for _, w := range s.order {
		if need == 0 {
			break
		}
		got := s.store.TakeUpTo(sku, w.ID, need)
		if got > 0 {
			parts = append(parts, model.Part{Warehouse: w.ID, Qty: got})
			need -= got
		}
	}
	if need > 0 {
		return model.Reservation{}, ErrInsufficient
	}
	now := s.clock.Now()
	return s.store.Insert(model.Reservation{
		CartID:    cartID,
		SKU:       sku,
		Qty:       qty,
		Parts:     parts,
		Status:    model.StatusHeld,
		CreatedAt: now,
		ExpiresAt: now.Add(s.hold),
	}), nil
}

// Confirm turns a live hold into a sale.
func (s *Service) Confirm(cartID, id string) (model.Reservation, error) {
	now := s.clock.Now()
	return s.store.Update(id, func(r *model.Reservation) error {
		if r.CartID != cartID {
			return ErrNotOwner
		}
		if r.Status == model.StatusConfirmed {
			return ErrConfirmed
		}
		if !now.Before(r.ExpiresAt) {
			return ErrExpired
		}
		r.Status = model.StatusConfirmed
		return nil
	})
}

// Release drops a hold and puts its units back on sale.
func (s *Service) Release(cartID, id string) error {
	r, err := s.store.Remove(id, func(r model.Reservation) error {
		if r.CartID != cartID {
			return ErrNotOwner
		}
		if r.Status == model.StatusConfirmed {
			return ErrConfirmed
		}
		return nil
	})
	if err != nil {
		return err
	}
	s.restock(r)
	return nil
}

// ReleaseCart drops every hold of the cart that is not yet confirmed and
// returns how many it dropped.
func (s *Service) ReleaseCart(cartID string) int {
	n := 0
	for _, r := range s.store.ByCart(cartID) {
		got, err := s.store.Remove(r.ID, func(cur model.Reservation) error {
			if cur.Status != model.StatusHeld {
				return ErrConfirmed
			}
			return nil
		})
		if err != nil {
			continue // confirmed, or released by another call meanwhile
		}
		s.restock(got)
		n++
	}
	return n
}

func (s *Service) restock(r model.Reservation) {
	for _, p := range r.Parts {
		s.store.Restock(r.SKU, p.Warehouse, p.Qty)
	}
}

// Cart lists the cart's reservations.
func (s *Service) Cart(cartID string) []model.Reservation {
	return s.store.ByCart(cartID)
}

// Available is the number of units of sku on sale in each open warehouse.
func (s *Service) Available(sku string) map[string]int {
	out := map[string]int{}
	for _, w := range s.order {
		out[w.ID] = s.store.Available(sku, w.ID)
	}
	return out
}
__STOCKD_EOF__
mkdir -p 'internal/reserve'
cat > 'internal/reserve/service_test.go' <<'__STOCKD_EOF__'
package reserve

import (
	"errors"
	"testing"
	"time"

	"example.com/stockd/internal/clock"
	"example.com/stockd/internal/config"
	"example.com/stockd/internal/store"
)

var testWarehouses = []config.Warehouse{
	{ID: "w1", Priority: 1, Enabled: true},
	{ID: "w2", Priority: 2, Enabled: true},
}

// setup has 5 MUG on sale: 3 in w1 and 2 in w2.
func setup() (*Service, *store.Memory, *clock.Fixed) {
	st := store.NewMemory(map[string]map[string]int{"w1": {"MUG": 3}, "w2": {"MUG": 2}})
	clk := &clock.Fixed{T: time.Date(2026, 3, 1, 12, 0, 0, 0, time.UTC)}
	return New(st, clk, 15*time.Minute, testWarehouses), st, clk
}

func TestReserveConfirm(t *testing.T) {
	svc, st, _ := setup()
	r, err := svc.Reserve("c1", "MUG", 2)
	if err != nil {
		t.Fatal(err)
	}
	if st.Available("MUG", "w1") != 1 {
		t.Fatalf("w1 available = %d", st.Available("MUG", "w1"))
	}
	if _, err := svc.Confirm("c1", r.ID); err != nil {
		t.Fatal(err)
	}
	if err := svc.Release("c1", r.ID); !errors.Is(err, ErrConfirmed) {
		t.Fatalf("release after confirm: %v", err)
	}
}

func TestReserveSplitsAcrossWarehouses(t *testing.T) {
	svc, st, _ := setup()
	r, err := svc.Reserve("c1", "MUG", 4)
	if err != nil {
		t.Fatal(err)
	}
	if len(r.Parts) != 2 || r.Parts[0].Warehouse != "w1" || r.Parts[0].Qty != 3 || r.Parts[1].Qty != 1 {
		t.Fatalf("parts = %+v", r.Parts)
	}
	if err := svc.Release("c1", r.ID); err != nil {
		t.Fatal(err)
	}
	if st.Available("MUG", "w1") != 3 || st.Available("MUG", "w2") != 2 {
		t.Fatal("release must restock each warehouse")
	}
}

func TestReserveInsufficient(t *testing.T) {
	svc, _, _ := setup()
	if _, err := svc.Reserve("c1", "MUG", 6); !errors.Is(err, ErrInsufficient) {
		t.Fatalf("err = %v", err)
	}
}

func TestConfirmAfterHoldRunsOut(t *testing.T) {
	svc, _, clk := setup()
	r, _ := svc.Reserve("c1", "MUG", 1)
	clk.Advance(15 * time.Minute)
	if _, err := svc.Confirm("c1", r.ID); !errors.Is(err, ErrExpired) {
		t.Fatalf("err = %v, want ErrExpired", err)
	}
}

func TestReleaseOtherCart(t *testing.T) {
	svc, _, _ := setup()
	r, _ := svc.Reserve("c1", "MUG", 1)
	if err := svc.Release("c2", r.ID); !errors.Is(err, ErrNotOwner) {
		t.Fatalf("err = %v", err)
	}
}

func TestReleaseCartKeepsConfirmed(t *testing.T) {
	svc, _, _ := setup()
	a, _ := svc.Reserve("c1", "MUG", 1)
	svc.Reserve("c1", "MUG", 1)
	if _, err := svc.Confirm("c1", a.ID); err != nil {
		t.Fatal(err)
	}
	if n := svc.ReleaseCart("c1"); n != 1 {
		t.Fatalf("released %d, want 1", n)
	}
	if got := len(svc.Cart("c1")); got != 1 {
		t.Fatalf("cart has %d, want the confirmed one", got)
	}
}
__STOCKD_EOF__
mkdir -p 'internal/reserve'
cat > 'internal/reserve/sweeper.go' <<'__STOCKD_EOF__'
package reserve

import (
	"context"
	"errors"
	"log"
	"time"

	"example.com/stockd/internal/store"
)

// Sweep puts the units of run-out holds back on sale and returns how many
// holds it dropped.
func (s *Service) Sweep() int {
	now := s.clock.Now()
	n := 0
	for _, r := range s.store.Due(now) {
		got, err := s.store.Remove(r.ID, nil)
		if errors.Is(err, store.ErrNotFound) {
			continue // released by the cart meanwhile
		}
		if err != nil {
			log.Printf("sweep %s: %v", r.ID, err)
			continue
		}
		s.restock(got)
		n++
	}
	return n
}

// RunSweeper calls Sweep every interval until ctx is done.
func (s *Service) RunSweeper(ctx context.Context, interval time.Duration) {
	t := time.NewTicker(interval)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			if n := s.Sweep(); n > 0 {
				log.Printf("sweeper: released %d run-out holds", n)
			}
		}
	}
}
__STOCKD_EOF__
mkdir -p 'internal/reserve'
cat > 'internal/reserve/sweeper_test.go' <<'__STOCKD_EOF__'
package reserve

import (
	"testing"
	"time"
)

func TestSweepReleasesRunOutHolds(t *testing.T) {
	svc, st, clk := setup()
	if _, err := svc.Reserve("c1", "MUG", 4); err != nil {
		t.Fatal(err)
	}
	clk.Advance(10 * time.Minute)
	if n := svc.Sweep(); n != 0 {
		t.Fatalf("swept %d live holds", n)
	}
	clk.Advance(5 * time.Minute)
	if n := svc.Sweep(); n != 1 {
		t.Fatalf("swept %d, want 1", n)
	}
	if got := st.Available("MUG", "w1") + st.Available("MUG", "w2"); got != 5 {
		t.Fatalf("available = %d, want 5", got)
	}
}

func TestSweepSkipsReleased(t *testing.T) {
	svc, _, clk := setup()
	r, _ := svc.Reserve("c1", "MUG", 1)
	if err := svc.Release("c1", r.ID); err != nil {
		t.Fatal(err)
	}
	clk.Advance(time.Hour)
	if n := svc.Sweep(); n != 0 {
		t.Fatalf("swept %d", n)
	}
}
__STOCKD_EOF__
mkdir -p 'internal/store'
cat > 'internal/store/memory.go' <<'__STOCKD_EOF__'
package store

import (
	"fmt"
	"sort"
	"sync"
	"time"

	"example.com/stockd/internal/model"
)

type key struct{ sku, warehouse string }

// Memory is an in-process Store.
type Memory struct {
	mu    sync.Mutex
	stock map[key]int
	res   map[string]model.Reservation
	next  int
}

// NewMemory starts with stock given as warehouse -> SKU -> units.
func NewMemory(stock map[string]map[string]int) *Memory {
	m := &Memory{stock: map[key]int{}, res: map[string]model.Reservation{}}
	for wh, skus := range stock {
		for sku, n := range skus {
			m.stock[key{sku, wh}] = n
		}
	}
	return m
}

func (m *Memory) TakeUpTo(sku, warehouse string, max int) int {
	m.mu.Lock()
	defer m.mu.Unlock()
	k := key{sku, warehouse}
	n := m.stock[k]
	if max < n {
		n = max
	}
	m.stock[k] -= n
	return n
}

func (m *Memory) Restock(sku, warehouse string, qty int) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.stock[key{sku, warehouse}] += qty
}

func (m *Memory) Available(sku, warehouse string) int {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.stock[key{sku, warehouse}]
}

func (m *Memory) Insert(r model.Reservation) model.Reservation {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.next++
	r.ID = fmt.Sprintf("r%d", m.next)
	m.res[r.ID] = r
	return r
}

func (m *Memory) Get(id string) (model.Reservation, bool) {
	m.mu.Lock()
	defer m.mu.Unlock()
	r, ok := m.res[id]
	return r, ok
}

func (m *Memory) Update(id string, fn func(*model.Reservation) error) (model.Reservation, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	r, ok := m.res[id]
	if !ok {
		return model.Reservation{}, ErrNotFound
	}
	if err := fn(&r); err != nil {
		return model.Reservation{}, err
	}
	m.res[id] = r
	return r, nil
}

func (m *Memory) Remove(id string, check func(model.Reservation) error) (model.Reservation, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	r, ok := m.res[id]
	if !ok {
		return model.Reservation{}, ErrNotFound
	}
	if check != nil {
		if err := check(r); err != nil {
			return model.Reservation{}, err
		}
	}
	delete(m.res, id)
	return r, nil
}

func (m *Memory) ByCart(cartID string) []model.Reservation {
	m.mu.Lock()
	defer m.mu.Unlock()
	var out []model.Reservation
	for _, r := range m.res {
		if r.CartID == cartID {
			out = append(out, r)
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].CreatedAt.Before(out[j].CreatedAt) })
	return out
}

func (m *Memory) Due(now time.Time) []model.Reservation {
	m.mu.Lock()
	defer m.mu.Unlock()
	var out []model.Reservation
	for _, r := range m.res {
		// A hold is valid strictly before ExpiresAt (see model.Reservation),
		// so one that expires exactly now is already due.
		if !r.ExpiresAt.After(now) {
			out = append(out, r)
		}
	}
	return out
}
__STOCKD_EOF__
mkdir -p 'internal/store'
cat > 'internal/store/memory_test.go' <<'__STOCKD_EOF__'
package store

import (
	"errors"
	"testing"
	"time"

	"example.com/stockd/internal/model"
)

func TestTakeUpTo(t *testing.T) {
	m := NewMemory(map[string]map[string]int{"w1": {"A": 3}})
	if got := m.TakeUpTo("A", "w1", 2); got != 2 {
		t.Fatalf("took %d, want 2", got)
	}
	if got := m.TakeUpTo("A", "w1", 2); got != 1 {
		t.Fatalf("took %d, want 1 (only 1 left)", got)
	}
	if got := m.Available("A", "w1"); got != 0 {
		t.Fatalf("available = %d, want 0", got)
	}
	if got := m.TakeUpTo("A", "w2", 1); got != 0 {
		t.Fatalf("took %d from empty warehouse", got)
	}
}

func TestRemoveCheck(t *testing.T) {
	m := NewMemory(nil)
	r := m.Insert(model.Reservation{CartID: "c1"})
	stop := errors.New("stop")
	if _, err := m.Remove(r.ID, func(model.Reservation) error { return stop }); err != stop {
		t.Fatalf("err = %v, want stop", err)
	}
	if _, ok := m.Get(r.ID); !ok {
		t.Fatal("check failed, reservation must stay")
	}
	if _, err := m.Remove(r.ID, nil); err != nil {
		t.Fatal(err)
	}
	if _, err := m.Remove(r.ID, nil); err != ErrNotFound {
		t.Fatalf("err = %v, want ErrNotFound", err)
	}
}

func TestDue(t *testing.T) {
	m := NewMemory(nil)
	now := time.Date(2026, 3, 1, 12, 0, 0, 0, time.UTC)
	m.Insert(model.Reservation{ExpiresAt: now.Add(-time.Second)})
	m.Insert(model.Reservation{ExpiresAt: now})
	m.Insert(model.Reservation{ExpiresAt: now.Add(time.Second)})
	if got := len(m.Due(now)); got != 2 {
		t.Fatalf("due = %d, want 2", got)
	}
}
__STOCKD_EOF__
mkdir -p 'internal/store'
cat > 'internal/store/store.go' <<'__STOCKD_EOF__'
package store

import (
	"errors"
	"time"

	"example.com/stockd/internal/model"
)

var ErrNotFound = errors.New("reservation not found")

// Store keeps stock levels per warehouse and reservations. Every method is
// atomic.
type Store interface {
	// TakeUpTo removes up to max units of sku in warehouse from sale and
	// returns how many it removed (fewer than max when fewer are on sale).
	TakeUpTo(sku, warehouse string, max int) int
	// Restock puts qty units of sku back on sale in warehouse.
	Restock(sku, warehouse string, qty int)
	// Available is the number of units of sku on sale in warehouse.
	Available(sku, warehouse string) int

	// Insert stores r under a new ID and returns it.
	Insert(r model.Reservation) model.Reservation
	Get(id string) (model.Reservation, bool)
	// Update runs fn on the stored reservation and saves the result if fn
	// returns nil.
	Update(id string, fn func(*model.Reservation) error) (model.Reservation, error)
	// Remove deletes the reservation if check returns nil for it. A nil
	// check always deletes.
	Remove(id string, check func(model.Reservation) error) (model.Reservation, error)
	ByCart(cartID string) []model.Reservation
	// Due lists reservations whose ExpiresAt is at or before now.
	Due(now time.Time) []model.Reservation
}
__STOCKD_EOF__

git add -A && git commit -qm "Multi-warehouse holds, run-out sweeper and cart endpoints"
git diff HEAD~1 HEAD > pr.diff
