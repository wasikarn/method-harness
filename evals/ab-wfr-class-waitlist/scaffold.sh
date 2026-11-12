#!/usr/bin/env bash
set -euo pipefail

mkdir -p docs src src/http test
cat > README.md <<'__EOF__'
# class-booking

Booking API for fitness classes. Members book seats in a class slot, pay when
they book, and can cancel.

- `src/app.ts` wires the handlers; `src/http/` holds the router and routes.
- State lives in `src/db.ts` (in memory here; the production adapter keeps the
  same interface).
- Payments go through `src/payments.ts`.

    npm test

See `docs/api.md` for the HTTP API.
__EOF__
cat > docs/api.md <<'__EOF__'
# HTTP API

Every request carries `Authorization: Bearer <token>`. Errors come back as
`{ "error": "<message>" }` with the status of the error class in
`src/errors.ts`.

## Slots

`GET /slots/:id` returns the slot and `seatsLeft`.

## Bookings

`POST /slots/:id/bookings` with `{ "partySize": n }` books `n` seats
(1 to `maxPartySize`) and charges `price x n`. 409 if the slot has started or
there are not enough seats.

`GET /bookings/:id` returns a booking. Only its owner or an admin may read it.

`DELETE /bookings/:id` cancels a booking and refunds it in full. Only its owner
or an admin may cancel. 409 if it is already cancelled.
__EOF__
cat > package.json <<'__EOF__'
{
  "name": "class-booking",
  "version": "0.4.0",
  "private": true,
  "description": "Booking API for fitness classes: slots, bookings, payments.",
  "scripts": {
    "build": "tsc -p .",
    "test": "tsc -p . && node out/test/run.js"
  },
  "devDependencies": {
    "typescript": "^5.4.0"
  }
}
__EOF__
cat > src/app.ts <<'__EOF__'
import { authenticate } from "./auth";
import { Deps } from "./bookings";
import { HttpError, NotFound } from "./errors";
import { Response, Router } from "./http/router";
import { registerRoutes } from "./http/routes";

export interface RawRequest {
  method: string;
  path: string;
  authorization?: string;
  body?: unknown;
}

export function createApp(deps: Deps, tokens: Map<string, string>) {
  const router = new Router();
  registerRoutes(router, deps);

  return function handle(raw: RawRequest): Response {
    try {
      const user = authenticate(deps.db, tokens, raw.authorization);
      const found = router.match(raw.method, raw.path);
      if (!found) throw new NotFound("route");
      return found.handler({ method: raw.method, path: raw.path, user, params: found.params, body: raw.body });
    } catch (err) {
      if (err instanceof HttpError) return { status: err.status, body: { error: err.message } };
      console.error(err);
      return { status: 500, body: { error: "internal error" } };
    }
  };
}
__EOF__
cat > src/auth.ts <<'__EOF__'
import { Db } from "./db";
import { Unauthorized } from "./errors";
import { User } from "./types";

/** Resolves a bearer token to a user. Tokens are issued by the login service. */
export function authenticate(db: Db, tokens: Map<string, string>, header: string | undefined): User {
  const match = /^Bearer (\S+)$/.exec(header ?? "");
  const userId = match ? tokens.get(match[1]) : undefined;
  const user = userId ? db.users.get(userId) : undefined;
  if (!user) throw new Unauthorized();
  return user;
}
__EOF__
cat > src/bookings.ts <<'__EOF__'
import { seatsLeft } from "./capacity";
import { Clock } from "./clock";
import { Db } from "./db";
import { Conflict, Forbidden, NotFound } from "./errors";
import { Notifier } from "./notifications";
import { PaymentGateway } from "./payments";
import { priceFor } from "./pricing";
import { Booking, Slot, User } from "./types";

export interface Deps {
  db: Db;
  clock: Clock;
  payments: PaymentGateway;
  notifier: Notifier;
}

export function mustGetSlot(db: Db, slotId: string): Slot {
  const slot = db.slots.get(slotId);
  if (!slot) throw new NotFound("slot");
  return slot;
}

export function hasStarted(slot: Slot, clock: Clock): boolean {
  return slot.startsAt * 1000 <= clock.now();
}

export function createBooking(deps: Deps, user: User, slotId: string, partySize: number): Booking {
  const { db, clock, payments, notifier } = deps;
  const slot = mustGetSlot(db, slotId);
  if (hasStarted(slot, clock)) throw new Conflict("class has already started");
  if (seatsLeft(db, slot) < partySize) throw new Conflict("not enough seats left");
  const id = db.nextId("bk");
  const price = priceFor(slot, partySize);
  const chargeId = payments.charge(user.id, price, `booking-${id}`);
  const booking: Booking = {
    id,
    slotId,
    userId: user.id,
    partySize,
    status: "confirmed",
    chargeId,
    paidCents: price,
    createdAt: clock.now(),
  };
  db.bookings.set(id, booking);
  void notifier.send({ kind: "booking_confirmed", to: user.email, bookingId: id });
  return booking;
}

export function getBooking(db: Db, user: User, bookingId: string): Booking {
  const booking = db.bookings.get(bookingId);
  if (!booking) throw new NotFound("booking");
  if (booking.userId !== user.id && user.role !== "admin") throw new Forbidden();
  return booking;
}

export function cancelBooking(deps: Deps, user: User, bookingId: string): Booking {
  const { db, payments, notifier } = deps;
  const booking = getBooking(db, user, bookingId);
  if (booking.status === "cancelled") throw new Conflict("booking is already cancelled");
  payments.refund(booking.chargeId, booking.paidCents);
  booking.status = "cancelled";
  void notifier.send({
    kind: "booking_cancelled",
    to: user.email,
    bookingId,
    refundCents: booking.paidCents,
  });
  return booking;
}
__EOF__
cat > src/capacity.ts <<'__EOF__'
import { Db } from "./db";
import { Slot } from "./types";

/** Seats held by confirmed bookings. A booking holds `partySize` seats. */
export function seatsTaken(db: Db, slotId: string): number {
  return db
    .bookingsForSlot(slotId)
    .filter((b) => b.status === "confirmed")
    .reduce((sum, b) => sum + b.partySize, 0);
}

export function seatsLeft(db: Db, slot: Slot): number {
  return slot.capacity - seatsTaken(db, slot.id);
}
__EOF__
cat > src/clock.ts <<'__EOF__'
export interface Clock {
  /** Milliseconds since the Unix epoch, like Date.now(). */
  now(): number;
}

export const systemClock: Clock = { now: () => Date.now() };

export class FakeClock implements Clock {
  constructor(private ms: number) {}
  now(): number {
    return this.ms;
  }
  advance(ms: number): void {
    this.ms += ms;
  }
}
__EOF__
cat > src/config.ts <<'__EOF__'
export const config = {
  /** Largest party one booking may hold. */
  maxPartySize: 8,
};
__EOF__
cat > src/db.ts <<'__EOF__'
import { Booking, Slot, User } from "./types";

export class Db {
  readonly users = new Map<string, User>();
  readonly slots = new Map<string, Slot>();
  readonly bookings = new Map<string, Booking>();
  private seq = 0;

  nextId(prefix: string): string {
    this.seq += 1;
    return `${prefix}_${this.seq}`;
  }

  bookingsForSlot(slotId: string): Booking[] {
    return [...this.bookings.values()].filter((b) => b.slotId === slotId);
  }
}
__EOF__
cat > src/env.d.ts <<'__EOF__'
// This package runs on any JS runtime; we only rely on the console.
declare const console: {
  log(...args: unknown[]): void;
  error(...args: unknown[]): void;
};
__EOF__
cat > src/errors.ts <<'__EOF__'
export class HttpError extends Error {
  constructor(readonly status: number, message: string) {
    super(message);
  }
}

export class BadRequest extends HttpError {
  constructor(message: string) {
    super(400, message);
  }
}

export class Unauthorized extends HttpError {
  constructor() {
    super(401, "sign in first");
  }
}

export class Forbidden extends HttpError {
  constructor() {
    super(403, "not allowed");
  }
}

export class NotFound extends HttpError {
  constructor(what: string) {
    super(404, `${what} not found`);
  }
}

export class Conflict extends HttpError {
  constructor(message: string) {
    super(409, message);
  }
}
__EOF__
cat > src/http/router.ts <<'__EOF__'
import { User } from "../types";

export interface Request {
  method: string;
  path: string;
  user: User;
  params: Record<string, string>;
  body: unknown;
}

export interface Response {
  status: number;
  body: unknown;
}

export type Handler = (req: Request) => Response;

interface Route {
  method: string;
  parts: string[];
  handler: Handler;
}

export class Router {
  private routes: Route[] = [];

  add(method: string, pattern: string, handler: Handler): void {
    this.routes.push({ method, parts: pattern.split("/").filter(Boolean), handler });
  }

  match(method: string, path: string): { handler: Handler; params: Record<string, string> } | undefined {
    const parts = path.split("/").filter(Boolean);
    for (const route of this.routes) {
      if (route.method !== method || route.parts.length !== parts.length) continue;
      const params: Record<string, string> = {};
      const ok = route.parts.every((p, i) => {
        if (p.startsWith(":")) {
          params[p.slice(1)] = decodeURIComponent(parts[i]);
          return true;
        }
        return p === parts[i];
      });
      if (ok) return { handler: route.handler, params };
    }
    return undefined;
  }
}
__EOF__
cat > src/http/routes.ts <<'__EOF__'
import { cancelBooking, createBooking, Deps, getBooking, mustGetSlot } from "../bookings";
import { seatsLeft } from "../capacity";
import { parsePartySize } from "../validation";
import { Router } from "./router";

export function registerRoutes(router: Router, deps: Deps): void {
  const { db } = deps;

  router.add("GET", "/slots/:id", (req) => {
    const slot = mustGetSlot(db, req.params.id);
    return { status: 200, body: { ...slot, seatsLeft: seatsLeft(db, slot) } };
  });

  router.add("POST", "/slots/:id/bookings", (req) => {
    const partySize = parsePartySize(req.body);
    return { status: 201, body: createBooking(deps, req.user, req.params.id, partySize) };
  });

  router.add("GET", "/bookings/:id", (req) => ({
    status: 200,
    body: getBooking(db, req.user, req.params.id),
  }));

  router.add("DELETE", "/bookings/:id", (req) => ({
    status: 200,
    body: cancelBooking(deps, req.user, req.params.id),
  }));
}
__EOF__
cat > src/notifications.ts <<'__EOF__'
export type Message =
  | { kind: "booking_confirmed"; to: string; bookingId: string }
  | { kind: "booking_cancelled"; to: string; bookingId: string; refundCents: number };

export interface Notifier {
  /**
   * Queue a message. Never rejects: delivery failures are logged and retried
   * from the outbox, so callers do not need to await or catch.
   */
  send(message: Message): Promise<void>;
}

export class OutboxNotifier implements Notifier {
  readonly outbox: Message[] = [];

  async send(message: Message): Promise<void> {
    try {
      this.outbox.push(message);
    } catch (err) {
      console.error("notification not queued", err);
    }
  }
}
__EOF__
cat > src/payments.ts <<'__EOF__'
export class PaymentDeclined extends Error {}

export interface PaymentGateway {
  /**
   * Charge a member's card on file and return the charge id. The gateway
   * dedupes on `idempotencyKey`: a repeated key returns the original charge id
   * and does not charge again, so a retried request can never charge twice.
   * Throws PaymentDeclined if the card is declined.
   */
  charge(userId: string, cents: number, idempotencyKey: string): string;
  /** Refund part or all of a charge. */
  refund(chargeId: string, cents: number): void;
}

/** In-memory gateway for tests and local runs. Same contract as the real one. */
export class FakeGateway implements PaymentGateway {
  readonly charges: { id: string; userId: string; cents: number; key: string }[] = [];
  readonly refunds: { chargeId: string; cents: number }[] = [];
  readonly declined = new Set<string>();

  charge(userId: string, cents: number, idempotencyKey: string): string {
    const seen = this.charges.find((c) => c.key === idempotencyKey);
    if (seen) return seen.id;
    if (this.declined.has(userId)) throw new PaymentDeclined(`card declined for ${userId}`);
    const id = `ch_${this.charges.length + 1}`;
    this.charges.push({ id, userId, cents, key: idempotencyKey });
    return id;
  }

  refund(chargeId: string, cents: number): void {
    this.refunds.push({ chargeId, cents });
  }
}
__EOF__
cat > src/pricing.ts <<'__EOF__'
import { Slot } from "./types";

export function priceFor(slot: Slot, partySize: number): number {
  return slot.priceCents * partySize;
}
__EOF__
cat > src/types.ts <<'__EOF__'
export type Role = "member" | "admin";

export interface User {
  id: string;
  email: string;
  role: Role;
}

export interface Slot {
  id: string;
  title: string;
  /** Unix time in seconds, as delivered by the schedule feed. */
  startsAt: number;
  capacity: number;
  priceCents: number;
}

export type BookingStatus = "confirmed" | "cancelled";

export interface Booking {
  id: string;
  slotId: string;
  userId: string;
  partySize: number;
  status: BookingStatus;
  chargeId: string;
  paidCents: number;
  /** Clock time (ms) when the booking was made. */
  createdAt: number;
}
__EOF__
cat > src/validation.ts <<'__EOF__'
import { config } from "./config";
import { BadRequest } from "./errors";

export function parsePartySize(body: unknown): number {
  const value = (body as { partySize?: unknown } | null)?.partySize;
  if (typeof value !== "number" || !Number.isInteger(value)) {
    throw new BadRequest("partySize must be an integer");
  }
  if (value < 1 || value > config.maxPartySize) {
    throw new BadRequest(`partySize must be between 1 and ${config.maxPartySize}`);
  }
  return value;
}
__EOF__
cat > test/bookings.test.ts <<'__EOF__'
import { cancelBooking, createBooking, getBooking } from "../src/bookings";
import { eq, test, throws, world } from "./harness";

test("booking charges price x party size", () => {
  const w = world();
  const b = createBooking(w.deps, w.user("u1"), "spin", 2);
  eq(b.paidCents, 3000);
  eq(w.payments.charges.length, 1);
});

test("cannot overbook", () => {
  const w = world();
  createBooking(w.deps, w.user("u1"), "spin", 3);
  throws(() => createBooking(w.deps, w.user("u2"), "spin", 2), 409);
});

test("cannot book a class that started", () => {
  const w = world();
  w.clock.advance(3 * 86400 * 1000);
  throws(() => createBooking(w.deps, w.user("u1"), "spin", 1), 409);
});

test("only the owner or an admin can read a booking", () => {
  const w = world();
  const b = createBooking(w.deps, w.user("u1"), "spin", 1);
  throws(() => getBooking(w.db, w.user("u2"), b.id), 403);
  eq(getBooking(w.db, w.user("admin"), b.id).id, b.id);
});

test("cancel refunds in full once", () => {
  const w = world();
  const b = createBooking(w.deps, w.user("u1"), "spin", 2);
  cancelBooking(w.deps, w.user("u1"), b.id);
  eq(w.payments.refunds, [{ chargeId: b.chargeId, cents: 3000 }]);
  throws(() => cancelBooking(w.deps, w.user("u1"), b.id), 409);
});
__EOF__
cat > test/harness.ts <<'__EOF__'
import { Deps } from "../src/bookings";
import { FakeClock } from "../src/clock";
import { Db } from "../src/db";
import { OutboxNotifier } from "../src/notifications";
import { FakeGateway } from "../src/payments";

export const tests: { name: string; fn: () => void }[] = [];

export function test(name: string, fn: () => void): void {
  tests.push({ name, fn });
}

export function eq<T>(actual: T, expected: T, what = "value"): void {
  const a = JSON.stringify(actual);
  const e = JSON.stringify(expected);
  if (a !== e) throw new Error(`${what}: expected ${e}, got ${a}`);
}

export function throws(fn: () => unknown, status: number): void {
  try {
    fn();
  } catch (err) {
    eq((err as { status?: number }).status, status, "error status");
    return;
  }
  throw new Error(`expected an error with status ${status}`);
}

/** 2026-03-02T09:00:00Z */
export const T0 = 1772442000000;

export function world() {
  const db = new Db();
  const clock = new FakeClock(T0);
  const payments = new FakeGateway();
  const notifier = new OutboxNotifier();
  const deps: Deps = { db, clock, payments, notifier };
  db.users.set("u1", { id: "u1", email: "ann@example.com", role: "member" });
  db.users.set("u2", { id: "u2", email: "bob@example.com", role: "member" });
  db.users.set("u3", { id: "u3", email: "cy@example.com", role: "member" });
  db.users.set("admin", { id: "admin", email: "ops@example.com", role: "admin" });
  // Spin class three days out, 4 seats, $15.00 a seat.
  db.slots.set("spin", { id: "spin", title: "Spin", startsAt: T0 / 1000 + 3 * 86400, capacity: 4, priceCents: 1500 });
  return { db, clock, payments, notifier, deps, user: (id: string) => db.users.get(id)! };
}
__EOF__
cat > test/run.ts <<'__EOF__'
import "./bookings.test";
import { tests } from "./harness";

let failed = 0;
for (const t of tests) {
  try {
    t.fn();
    console.log(`ok   ${t.name}`);
  } catch (err) {
    failed += 1;
    console.log(`FAIL ${t.name}: ${(err as Error).message}`);
  }
}
console.log(`${tests.length - failed}/${tests.length} passed`);
if (failed > 0) throw new Error(`${failed} test(s) failed`);
__EOF__
cat > tsconfig.json <<'__EOF__'
{
  "compilerOptions": {
    "target": "es2020",
    "module": "commonjs",
    "lib": ["es2020"],
    "types": [],
    "strict": true,
    "noImplicitReturns": true,
    "outDir": "out",
    "rootDir": "."
  },
  "include": ["src", "test"]
}
__EOF__

git init -q . && git config user.email dev@example.com && git config user.name dev
git add -A && git commit -qm 'Initial import'

mkdir -p docs src src/http test
cat > README.md <<'__EOF__'
# class-booking

Booking API for fitness classes. Members book seats in a class slot, pay when
they book, and can cancel. When a class is full they can join its waitlist;
seats freed by a cancellation go to the waitlist in the order people joined.

- `src/app.ts` wires the handlers; `src/http/` holds the router and routes.
- State lives in `src/db.ts` (in memory here; the production adapter keeps the
  same interface).
- Payments go through `src/payments.ts`. Refund rules are in `src/refunds.ts`
  and `src/config.ts`.

    npm test

See `docs/api.md` for the HTTP API.
__EOF__
cat > docs/api.md <<'__EOF__'
# HTTP API

Every request carries `Authorization: Bearer <token>`. Errors come back as
`{ "error": "<message>" }` with the status of the error class in
`src/errors.ts`.

## Slots

`GET /slots/:id` returns the slot and `seatsLeft`.

## Bookings

`POST /slots/:id/bookings` with `{ "partySize": n }` books `n` seats
(1 to `maxPartySize`) and charges `price x n`. 409 if the slot has started or
there are not enough seats.

`GET /bookings/:id` returns a booking. Only its owner or an admin may read it.

`DELETE /bookings/:id` cancels a booking. Only its owner or an admin may
cancel. 409 if it is already cancelled or the class has started.

Refunds: a booking cancelled at least `refundWindowHours` (24) before the class
starts is refunded in full. After that, `lateCancelRefundPercent` (50%) of the
price is refunded. The freed seats are offered to the waitlist.

## Waitlist

`POST /slots/:id/waitlist` with `{ "partySize": n }` joins the waitlist of a
full class. 201 with `{ "position": p }`. 409 if enough seats are free (book
instead), the party is larger than the class, the class has started, you
already hold a booking or a waitlist place for it, or the waitlist is full
(`maxWaitlist`).

`GET /slots/:id/waitlist` returns `{ "length": n, "position": p }`: how many
parties are waiting and your own place in line. `position` is 1-based (1 means
you are next) and 0 when you are not on the waitlist.

`DELETE /slots/:id/waitlist` takes you off the waitlist. It is idempotent: 204
whether or not you were on it, so a retried request is safe.

When seats free up, waiting parties are booked in the order they joined and
charged at once. A party whose card is declined loses its place and is told by
email.
__EOF__
cat > package.json <<'__EOF__'
{
  "name": "class-booking",
  "version": "0.5.0",
  "private": true,
  "description": "Booking API for fitness classes: slots, bookings, payments, waitlists.",
  "scripts": {
    "build": "tsc -p .",
    "test": "tsc -p . && node out/test/run.js"
  },
  "devDependencies": {
    "typescript": "^5.4.0"
  }
}
__EOF__
cat > src/bookings.ts <<'__EOF__'
import { seatsLeft } from "./capacity";
import { Clock } from "./clock";
import { Db } from "./db";
import { Conflict, Forbidden, NotFound } from "./errors";
import { Notifier } from "./notifications";
import { PaymentGateway } from "./payments";
import { priceFor } from "./pricing";
import { Booking, Slot, User } from "./types";

export interface Deps {
  db: Db;
  clock: Clock;
  payments: PaymentGateway;
  notifier: Notifier;
}

export function mustGetSlot(db: Db, slotId: string): Slot {
  const slot = db.slots.get(slotId);
  if (!slot) throw new NotFound("slot");
  return slot;
}

export function hasStarted(slot: Slot, clock: Clock): boolean {
  return slot.startsAt * 1000 <= clock.now();
}

export function createBooking(deps: Deps, user: User, slotId: string, partySize: number): Booking {
  const { db, clock, payments, notifier } = deps;
  const slot = mustGetSlot(db, slotId);
  if (hasStarted(slot, clock)) throw new Conflict("class has already started");
  if (seatsLeft(db, slot) < partySize) throw new Conflict("not enough seats left");
  const id = db.nextId("bk");
  const price = priceFor(slot, partySize);
  const chargeId = payments.charge(user.id, price, `booking-${id}`);
  const booking: Booking = {
    id,
    slotId,
    userId: user.id,
    partySize,
    status: "confirmed",
    chargeId,
    paidCents: price,
    refundedCents: 0,
    createdAt: clock.now(),
  };
  db.bookings.set(id, booking);
  // Booking directly ends any wait for this class.
  for (const entry of db.waitlistForSlot(slotId)) {
    if (entry.userId === user.id) db.waitlist.delete(entry.id);
  }
  void notifier.send({ kind: "booking_confirmed", to: user.email, bookingId: id });
  return booking;
}

export function getBooking(db: Db, user: User, bookingId: string): Booking {
  const booking = db.bookings.get(bookingId);
  if (!booking) throw new NotFound("booking");
  if (booking.userId !== user.id && user.role !== "admin") throw new Forbidden();
  return booking;
}
__EOF__
cat > src/cancellation.ts <<'__EOF__'
import { Deps, getBooking, hasStarted, mustGetSlot } from "./bookings";
import { Conflict } from "./errors";
import { refundFor } from "./refunds";
import { Booking, User } from "./types";
import { promoteFromWaitlist } from "./waitlist";

/**
 * Cancel a booking: refund it under the refund policy, free its seats and
 * offer them to the waitlist. An admin may cancel on a member's behalf; the
 * member is the one told.
 */
export function cancelBooking(deps: Deps, user: User, bookingId: string): Booking {
  const { db, clock, payments, notifier } = deps;
  const booking = getBooking(db, user, bookingId);
  const slot = mustGetSlot(db, booking.slotId);
  if (hasStarted(slot, clock)) throw new Conflict("class has already started");

  const refund = refundFor(booking, slot, clock.now());
  if (refund > 0) payments.refund(booking.chargeId, refund);
  booking.status = "cancelled";
  booking.refundedCents = refund;

  const owner = db.users.get(booking.userId);
  if (owner) {
    void notifier.send({ kind: "booking_cancelled", to: owner.email, bookingId, refundCents: refund });
  }
  promoteFromWaitlist(deps, slot);
  return booking;
}
__EOF__
cat > src/config.ts <<'__EOF__'
export const config = {
  /** Largest party one booking may hold. */
  maxPartySize: 8,
  /** Cancel at least this many hours before the class for a full refund. */
  refundWindowHours: 24,
  /** Share of the price refunded when cancelling later than that. */
  lateCancelRefundPercent: 50,
  /** Most parties one slot's waitlist may hold. */
  maxWaitlist: 20,
};
__EOF__
cat > src/db.ts <<'__EOF__'
import { Booking, Slot, User, WaitlistEntry } from "./types";

export class Db {
  readonly users = new Map<string, User>();
  readonly slots = new Map<string, Slot>();
  readonly bookings = new Map<string, Booking>();
  readonly waitlist = new Map<string, WaitlistEntry>();
  private seq = 0;

  nextId(prefix: string): string {
    this.seq += 1;
    return `${prefix}_${this.seq}`;
  }

  bookingsForSlot(slotId: string): Booking[] {
    return [...this.bookings.values()].filter((b) => b.slotId === slotId);
  }

  waitlistForSlot(slotId: string): WaitlistEntry[] {
    return [...this.waitlist.values()].filter((e) => e.slotId === slotId);
  }
}
__EOF__
cat > src/http/routes.ts <<'__EOF__'
import { createBooking, Deps, getBooking, mustGetSlot } from "../bookings";
import { cancelBooking } from "../cancellation";
import { seatsLeft } from "../capacity";
import { parsePartySize } from "../validation";
import { joinWaitlist, leaveWaitlist, positionOf, queue } from "../waitlist";
import { Router } from "./router";

export function registerRoutes(router: Router, deps: Deps): void {
  const { db } = deps;

  router.add("GET", "/slots/:id", (req) => {
    const slot = mustGetSlot(db, req.params.id);
    return { status: 200, body: { ...slot, seatsLeft: seatsLeft(db, slot) } };
  });

  router.add("POST", "/slots/:id/bookings", (req) => {
    const partySize = parsePartySize(req.body);
    return { status: 201, body: createBooking(deps, req.user, req.params.id, partySize) };
  });

  router.add("GET", "/bookings/:id", (req) => ({
    status: 200,
    body: getBooking(db, req.user, req.params.id),
  }));

  router.add("DELETE", "/bookings/:id", (req) => ({
    status: 200,
    body: cancelBooking(deps, req.user, req.params.id),
  }));

  router.add("POST", "/slots/:id/waitlist", (req) => {
    const partySize = parsePartySize(req.body);
    const entry = joinWaitlist(deps, req.user, req.params.id, partySize);
    return { status: 201, body: { position: positionOf(db, entry.slotId, req.user.id) } };
  });

  router.add("GET", "/slots/:id/waitlist", (req) => {
    const slot = mustGetSlot(db, req.params.id);
    const entries = queue(db, slot.id);
    return {
      status: 200,
      body: { length: entries.length, position: positionOf(db, slot.id, req.user.id), entries },
    };
  });

  router.add("DELETE", "/slots/:id/waitlist", (req) => {
    mustGetSlot(db, req.params.id);
    leaveWaitlist(db, req.user, req.params.id);
    return { status: 204, body: null };
  });
}
__EOF__
cat > src/notifications.ts <<'__EOF__'
export type Message =
  | { kind: "booking_confirmed"; to: string; bookingId: string }
  | { kind: "booking_cancelled"; to: string; bookingId: string; refundCents: number }
  | { kind: "waitlist_promoted"; to: string; bookingId: string }
  | { kind: "waitlist_payment_failed"; to: string; slotId: string };

export interface Notifier {
  /**
   * Queue a message. Never rejects: delivery failures are logged and retried
   * from the outbox, so callers do not need to await or catch.
   */
  send(message: Message): Promise<void>;
}

export class OutboxNotifier implements Notifier {
  readonly outbox: Message[] = [];

  async send(message: Message): Promise<void> {
    try {
      this.outbox.push(message);
    } catch (err) {
      console.error("notification not queued", err);
    }
  }
}
__EOF__
cat > src/refunds.ts <<'__EOF__'
import { config } from "./config";
import { Booking, Slot } from "./types";

const SECONDS_PER_HOUR = 3600;

/**
 * How much of a booking to refund if it is cancelled now: all of it up to
 * `refundWindowHours` before the class, `lateCancelRefundPercent` after that.
 */
export function refundFor(booking: Booking, slot: Slot, now: number): number {
  const hoursBefore = (slot.startsAt - now) / SECONDS_PER_HOUR;
  if (hoursBefore >= config.refundWindowHours) return booking.paidCents;
  return Math.floor((booking.paidCents * config.lateCancelRefundPercent) / 100);
}
__EOF__
cat > src/types.ts <<'__EOF__'
export type Role = "member" | "admin";

export interface User {
  id: string;
  email: string;
  role: Role;
}

export interface Slot {
  id: string;
  title: string;
  /** Unix time in seconds, as delivered by the schedule feed. */
  startsAt: number;
  capacity: number;
  priceCents: number;
}

export type BookingStatus = "confirmed" | "cancelled";

export interface Booking {
  id: string;
  slotId: string;
  userId: string;
  partySize: number;
  status: BookingStatus;
  chargeId: string;
  paidCents: number;
  refundedCents: number;
  /** Clock time (ms) when the booking was made. */
  createdAt: number;
}

export interface WaitlistEntry {
  id: string;
  slotId: string;
  userId: string;
  /** Where to tell them a seat freed up. */
  email: string;
  partySize: number;
  /** Clock time (ms) when they joined. */
  joinedAt: number;
}
__EOF__
cat > src/waitlist.ts <<'__EOF__'
import { Deps, mustGetSlot } from "./bookings";
import { seatsLeft } from "./capacity";
import { config } from "./config";
import { Db } from "./db";
import { Conflict } from "./errors";
import { PaymentDeclined } from "./payments";
import { priceFor } from "./pricing";
import { Booking, Slot, User, WaitlistEntry } from "./types";

/** A slot's waitlist, first come first served. */
export function queue(db: Db, slotId: string): WaitlistEntry[] {
  return db.waitlistForSlot(slotId).sort((a, b) => a.joinedAt - b.joinedAt);
}

export function joinWaitlist(deps: Deps, user: User, slotId: string, partySize: number): WaitlistEntry {
  const { db, clock } = deps;
  const slot = mustGetSlot(db, slotId);
  // startsAt is Unix seconds (schedule feed); the clock is in milliseconds.
  if (slot.startsAt * 1000 <= clock.now()) throw new Conflict("class has already started");
  if (partySize > slot.capacity) throw new Conflict("party is larger than the class");
  if (seatsLeft(db, slot) >= partySize) throw new Conflict("seats are free; book instead");
  const entries = queue(db, slotId);
  if (entries.some((e) => e.userId === user.id)) throw new Conflict("already on the waitlist");
  if (db.bookingsForSlot(slotId).some((b) => b.userId === user.id && b.status === "confirmed")) {
    throw new Conflict("you already hold a booking for this class");
  }
  if (entries.length >= config.maxWaitlist) throw new Conflict("the waitlist is full");
  const entry: WaitlistEntry = {
    id: db.nextId("wl"),
    slotId,
    userId: user.id,
    email: user.email,
    partySize,
    joinedAt: clock.now(),
  };
  db.waitlist.set(entry.id, entry);
  return entry;
}

export function leaveWaitlist(db: Db, user: User, slotId: string): void {
  for (const entry of queue(db, slotId)) {
    if (entry.userId === user.id) db.waitlist.delete(entry.id);
  }
}

/** 1-based place in line (see docs/api.md); 0 when not on the waitlist. */
export function positionOf(db: Db, slotId: string, userId: string): number {
  return queue(db, slotId).findIndex((e) => e.userId === userId) + 1;
}

/** Book one waiting party and charge them. Undefined if their card is declined. */
function promote(deps: Deps, slot: Slot, entry: WaitlistEntry): Booking | undefined {
  const { db, clock, payments, notifier } = deps;
  const price = priceFor(slot, entry.partySize);
  let chargeId: string;
  try {
    chargeId = payments.charge(entry.userId, price, `waitlist-${entry.slotId}`);
  } catch (err) {
    if (!(err instanceof PaymentDeclined)) throw err;
    db.waitlist.delete(entry.id);
    void notifier.send({ kind: "waitlist_payment_failed", to: entry.email, slotId: slot.id });
    return undefined;
  }
  db.waitlist.delete(entry.id);
  const booking: Booking = {
    id: db.nextId("bk"),
    slotId: slot.id,
    userId: entry.userId,
    partySize: entry.partySize,
    status: "confirmed",
    chargeId,
    paidCents: price,
    refundedCents: 0,
    createdAt: clock.now(),
  };
  db.bookings.set(booking.id, booking);
  void notifier.send({ kind: "waitlist_promoted", to: entry.email, bookingId: booking.id });
  return booking;
}

/** Offer free seats to the waitlist, in the order people joined. */
export function promoteFromWaitlist(deps: Deps, slot: Slot): Booking[] {
  const promoted: Booking[] = [];
  for (;;) {
    const next = queue(deps.db, slot.id)[0];
    if (!next || seatsLeft(deps.db, slot) <= 0) break;
    const booking = promote(deps, slot, next);
    if (booking) promoted.push(booking);
  }
  return promoted;
}
__EOF__
cat > test/bookings.test.ts <<'__EOF__'
import { createBooking, getBooking } from "../src/bookings";
import { cancelBooking } from "../src/cancellation";
import { eq, HOUR_MS, test, throws, world } from "./harness";

test("booking charges price x party size", () => {
  const w = world();
  const b = createBooking(w.deps, w.user("u1"), "spin", 2);
  eq(b.paidCents, 3000);
  eq(w.payments.charges.length, 1);
});

test("cannot overbook", () => {
  const w = world();
  createBooking(w.deps, w.user("u1"), "spin", 3);
  throws(() => createBooking(w.deps, w.user("u2"), "spin", 2), 409);
});

test("cannot book a class that started", () => {
  const w = world();
  w.clock.advance(3 * 86400 * 1000);
  throws(() => createBooking(w.deps, w.user("u1"), "spin", 1), 409);
});

test("only the owner or an admin can read a booking", () => {
  const w = world();
  const b = createBooking(w.deps, w.user("u1"), "spin", 1);
  throws(() => getBooking(w.db, w.user("u2"), b.id), 403);
  eq(getBooking(w.db, w.user("admin"), b.id).id, b.id);
});

test("only the owner or an admin can cancel", () => {
  const w = world();
  const b = createBooking(w.deps, w.user("u1"), "spin", 1);
  throws(() => cancelBooking(w.deps, w.user("u2"), b.id), 403);
  eq(cancelBooking(w.deps, w.user("admin"), b.id).status, "cancelled");
});

test("cannot cancel once the class started", () => {
  const w = world();
  const b = createBooking(w.deps, w.user("u1"), "spin", 1);
  w.clock.advance(3 * 86400 * 1000 + HOUR_MS);
  throws(() => cancelBooking(w.deps, w.user("u1"), b.id), 409);
});
__EOF__
cat > test/harness.ts <<'__EOF__'
import { createApp } from "../src/app";
import { Deps } from "../src/bookings";
import { FakeClock } from "../src/clock";
import { Db } from "../src/db";
import { OutboxNotifier } from "../src/notifications";
import { FakeGateway } from "../src/payments";

export const tests: { name: string; fn: () => void }[] = [];

export function test(name: string, fn: () => void): void {
  tests.push({ name, fn });
}

export function eq<T>(actual: T, expected: T, what = "value"): void {
  const a = JSON.stringify(actual);
  const e = JSON.stringify(expected);
  if (a !== e) throw new Error(`${what}: expected ${e}, got ${a}`);
}

export function throws(fn: () => unknown, status: number): void {
  try {
    fn();
  } catch (err) {
    eq((err as { status?: number }).status, status, "error status");
    return;
  }
  throw new Error(`expected an error with status ${status}`);
}

/** 2026-03-02T09:00:00Z */
export const T0 = 1772442000000;
export const HOUR_MS = 3600 * 1000;

export function world() {
  const db = new Db();
  const clock = new FakeClock(T0);
  const payments = new FakeGateway();
  const notifier = new OutboxNotifier();
  const deps: Deps = { db, clock, payments, notifier };
  db.users.set("u1", { id: "u1", email: "ann@example.com", role: "member" });
  db.users.set("u2", { id: "u2", email: "bob@example.com", role: "member" });
  db.users.set("u3", { id: "u3", email: "cy@example.com", role: "member" });
  db.users.set("admin", { id: "admin", email: "ops@example.com", role: "admin" });
  // Spin class three days out, 4 seats, $15.00 a seat.
  db.slots.set("spin", { id: "spin", title: "Spin", startsAt: T0 / 1000 + 3 * 86400, capacity: 4, priceCents: 1500 });
  const tokens = new Map([["t1", "u1"], ["t2", "u2"], ["t3", "u3"]]);
  const app = createApp(deps, tokens);
  return { db, clock, payments, notifier, deps, app, user: (id: string) => db.users.get(id)! };
}
__EOF__
cat > test/refunds.test.ts <<'__EOF__'
import { createBooking } from "../src/bookings";
import { cancelBooking } from "../src/cancellation";
import { eq, HOUR_MS, test, world } from "./harness";

test("late cancellation refunds half", () => {
  const w = world();
  const b = createBooking(w.deps, w.user("u1"), "spin", 2);
  w.clock.advance(3 * 86400 * 1000 - 2 * HOUR_MS);
  const cancelled = cancelBooking(w.deps, w.user("u1"), b.id);
  eq(cancelled.refundedCents, 1500);
  eq(w.payments.refunds, [{ chargeId: b.chargeId, cents: 1500 }]);
});

test("the member is told about the refund, even when an admin cancels", () => {
  const w = world();
  const b = createBooking(w.deps, w.user("u1"), "spin", 1);
  cancelBooking(w.deps, w.user("admin"), b.id);
  const msg = w.notifier.outbox.find((m) => m.kind === "booking_cancelled");
  eq(msg?.to, "ann@example.com");
});
__EOF__
cat > test/run.ts <<'__EOF__'
import "./bookings.test";
import "./refunds.test";
import "./waitlist.test";
import { tests } from "./harness";

let failed = 0;
for (const t of tests) {
  try {
    t.fn();
    console.log(`ok   ${t.name}`);
  } catch (err) {
    failed += 1;
    console.log(`FAIL ${t.name}: ${(err as Error).message}`);
  }
}
console.log(`${tests.length - failed}/${tests.length} passed`);
if (failed > 0) throw new Error(`${failed} test(s) failed`);
__EOF__
cat > test/waitlist.test.ts <<'__EOF__'
import { createBooking } from "../src/bookings";
import { cancelBooking } from "../src/cancellation";
import { joinWaitlist, positionOf } from "../src/waitlist";
import { eq, test, throws, world } from "./harness";

function fullSpin() {
  const w = world();
  const ann = createBooking(w.deps, w.user("u1"), "spin", 3);
  const admin = createBooking(w.deps, w.user("admin"), "spin", 1);
  return { w, ann, admin };
}

test("cannot join the waitlist while seats are free", () => {
  const w = world();
  throws(() => joinWaitlist(w.deps, w.user("u2"), "spin", 1), 409);
});

test("positions are 1-based and 0 when not waiting", () => {
  const { w } = fullSpin();
  joinWaitlist(w.deps, w.user("u2"), "spin", 1);
  eq(positionOf(w.db, "spin", "u2"), 1);
  eq(positionOf(w.db, "spin", "u3"), 0);
});

test("cannot join twice or while holding a booking", () => {
  const { w } = fullSpin();
  joinWaitlist(w.deps, w.user("u2"), "spin", 1);
  throws(() => joinWaitlist(w.deps, w.user("u2"), "spin", 1), 409);
  throws(() => joinWaitlist(w.deps, w.user("u1"), "spin", 1), 409);
});

test("a cancellation books the next party and charges them", () => {
  const { w, admin } = fullSpin();
  joinWaitlist(w.deps, w.user("u2"), "spin", 1);
  cancelBooking(w.deps, w.user("admin"), admin.id);
  const promoted = w.db.bookingsForSlot("spin").find((b) => b.userId === "u2");
  eq(promoted?.status, "confirmed");
  eq(w.payments.charges.map((c) => c.userId), ["u1", "admin", "u2"]);
  eq(positionOf(w.db, "spin", "u2"), 0);
});

test("booking directly leaves the waitlist", () => {
  const w = world();
  const ann = createBooking(w.deps, w.user("u1"), "spin", 3);
  joinWaitlist(w.deps, w.user("u2"), "spin", 2);
  createBooking(w.deps, w.user("u2"), "spin", 1);
  eq(positionOf(w.db, "spin", "u2"), 0);
  cancelBooking(w.deps, w.user("u1"), ann.id);
  eq(w.db.bookingsForSlot("spin").filter((b) => b.userId === "u2").length, 1);
});

test("a declined card loses its place", () => {
  const { w, admin } = fullSpin();
  w.payments.declined.add("u2");
  joinWaitlist(w.deps, w.user("u2"), "spin", 1);
  cancelBooking(w.deps, w.user("admin"), admin.id);
  eq(w.db.bookingsForSlot("spin").some((b) => b.userId === "u2"), false);
  eq(positionOf(w.db, "spin", "u2"), 0);
});

test("waitlist routes: join, read, leave twice", () => {
  const { w } = fullSpin();
  const join = w.app({ method: "POST", path: "/slots/spin/waitlist", authorization: "Bearer t2", body: { partySize: 1 } });
  eq(join, { status: 201, body: { position: 1 } });
  const read = w.app({ method: "GET", path: "/slots/spin/waitlist", authorization: "Bearer t2" });
  eq((read.body as { position: number }).position, 1);
  eq(w.app({ method: "DELETE", path: "/slots/spin/waitlist", authorization: "Bearer t2" }).status, 204);
  eq(w.app({ method: "DELETE", path: "/slots/spin/waitlist", authorization: "Bearer t2" }).status, 204);
});
__EOF__

git add -A && git commit -qm 'Add class waitlists and a cancellation refund policy'
git diff HEAD~1 HEAD > pr.diff
