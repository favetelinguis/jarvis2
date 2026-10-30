# Integration pattern details

Contents: Backoff, Circuit breaker, Rate limiting, Idempotency, Transactional outbox, Webhooks, Testing.

## Backoff

`delay = min(cap, base * 2^attempt) ` then apply jitter. Prefer full jitter:
`delay = random(0, min(cap, base * 2^attempt))`. Typical: base 100-500 ms, cap 10-30 s,
3-5 attempts, plus an overall deadline. If the response has `Retry-After`, wait at least that long.

Retry on: connection errors, timeouts (idempotent/keyed only), 408, 429, 502, 503, 504.
Do not retry: 400, 401, 403, 404, 409, 422 (fix the request or credentials instead).

## Circuit breaker

- Closed: calls pass; track outcomes in a sliding window (count- or time-based).
- Open: fail immediately (or use the fallback) once failure rate exceeds the threshold
  (e.g. 50% over >= 20 calls in 60 s). Stay open for the reset timeout (e.g. 30 s).
- Half-open: allow a few trial calls; success closes the circuit, failure reopens it.
- Count timeouts, connection errors, and 5xx as failures; not 4xx. Treat slow calls as failures
  when they exceed a latency threshold.
- Keep one breaker per vendor (or per vendor endpoint group), not one global breaker.
- Emit a metric/log on every state change.

## Rate limiting

- Token bucket: capacity = allowed burst, refill = sustained rate. Leaky bucket: constant drain rate.
- Set the local limit below the vendor quota (e.g. 80-90%) to leave headroom.
- On response headers: `Retry-After` (seconds or HTTP date), `X-RateLimit-Remaining`,
  `X-RateLimit-Reset` (epoch or seconds; check vendor docs). Pause or slow the limiter accordingly.
- Multi-instance: shared atomic store (e.g. Redis script with sliding window or token bucket),
  or divide the quota across instances.
- Prefer queueing with a bounded queue and timeout over unbounded waiting; shed load when full.

## Idempotency

- Generate the key once per logical operation (UUID v4, or a deterministic key derived from the
  business entity, e.g. `order-123-charge`). Persist it before the first attempt so a crash and
  restart reuses the same key.
- Send via the vendor-specified header (commonly `Idempotency-Key`).
- When the vendor lacks idempotency support, make the operation safe by reading state first
  (lookup by your own reference ID) before retrying.
- Inbound: record processed event/message IDs in a store with a unique constraint.

## Transactional outbox

1. In one local DB transaction: write the business change and insert an outbox row
   (`id`, `aggregate_id`, `type`, `payload`, `status`, `attempts`, `created_at`, `next_attempt_at`).
2. A background worker polls (or tails the log) for pending rows, calls the external system with the
   row `id` as idempotency key, then marks the row done.
3. Delivery is at-least-once; the external call and downstream consumers must be idempotent.
4. Use row locking that skips locked rows (or a single leader) for multiple workers; apply backoff and
   a dead-letter state after max attempts; alert on a growing backlog.

## Webhooks

1. Read the raw body bytes.
2. Verify signature: compute HMAC (usually SHA-256) over the exact string the vendor documents
   (often `timestamp + "." + body`) with the shared secret; compare in constant time.
3. Reject timestamps outside a tolerance (e.g. 5 min) to stop replay.
4. Check the event ID against the dedup store; if seen, return 200 and stop.
5. Persist the event (or enqueue) and return 200/202 immediately; process in a worker.
6. Do not assume ordering; fetch current state from the vendor API or compare version/timestamps.
7. Support secret rotation by accepting more than one active secret.
8. Return non-2xx only for failures where a vendor retry is wanted (e.g. could not persist).

## Testing

- Fake the adapter interface for domain tests; contract-test the adapter against recorded or
  sandbox vendor responses.
- Simulate: connect timeout, read timeout, 429 with `Retry-After`, 500/503, malformed or
  schema-drifted payload, duplicate and out-of-order webhooks, invalid signature, breaker open.
- Assert on behavior: retry count, same idempotency key across retries, fallback used, no secrets in logs.
- Make clock and randomness injectable so backoff and breaker timing tests are deterministic.
