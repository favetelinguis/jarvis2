---
name: external-integration-design
description: "Use when designing, researching, implementing, reviewing, or refactoring an integration with an external system or provider, including feasibility research or deciding whether to add one. Covers third-party APIs, model providers such as OpenRouter, vendor SDKs, REST/GraphQL/gRPC/SOAP clients, legacy services, payment gateways, webhooks, and event subscriptions. Also use when handling 429s, timeouts, flaky vendors, duplicate requests, or DB/API state drift. Guides use of adapters, timeouts, retries, circuit breakers, rate limiting, idempotency, and transactional outbox."
---

# External Integration Design

Language-agnostic. Apply to any code that crosses a boundary to a system you do not control.

## Workflow

1. Identify the boundary: vendor, protocol, direction (outbound call, inbound webhook, or both),
   and whether each operation is read-only, idempotent, or state-changing.
2. Walk the pattern checklist below. For each item, apply it or state in one line why it does not
   apply. Do not skip silently.
3. Reuse the project's existing resilience, config, secret, and logging libraries before adding new ones.
4. Implement, then run the verification checklist against the result.
5. Read [references/patterns.md](references/patterns.md) for mechanism details (backoff formula,
   breaker parameters, rate-limit headers, outbox schema, webhook handling) when implementing
   any item you are not certain about.

## Pattern checklist

**Structure**

- Anti-Corruption Layer: vendor types, field names, and terminology stay inside the integration
  module. Explicit mappers translate vendor models to domain models, in both directions.
- Adapter: put the vendor SDK or HTTP client behind an internal interface owned by the domain.
  Core logic depends only on that interface, so the vendor can be swapped or faked in tests.
- Facade: collapse multi-call sequences (auth, fetch token, validate, submit) into one internal method.

**Resilience**

- Timeouts: every outbound call has an explicit connect timeout and read/total timeout. Never rely
  on library defaults, which are often infinite.
- Retries: exponential backoff with jitter and a max attempt count/total deadline. Retry only
  idempotent operations or requests carrying an idempotency key; retry only transient errors
  (network, 5xx, 429, 408), never 4xx validation or auth errors.
- Circuit breaker: closed, open, half-open. Set failure-rate threshold, window, and reset timeout
  explicitly.
- Bulkhead: isolate connection/worker pools per vendor so one slow vendor cannot starve the app.
- Fallback: define behavior when the vendor is down (degraded feature, stale cache, queued retry,
  or a clear error). Make it an explicit decision per operation.

**Traffic**

- Proactive client-side rate limiting (token bucket for bursts, leaky bucket for smooth cadence).
- Honor `Retry-After`, `X-RateLimit-*` and equivalent headers; adjust throttling dynamically.
- With multiple app instances, keep limiter state in an atomic shared store, not per-process memory.

**Consistency**

- Idempotency key (UUID) on every state-changing call that is not naturally idempotent. Generate
  it once per logical operation and reuse it on every retry of that operation.
- Transactional outbox when a local DB write and an external call must agree: write the event in the
  same local transaction, dispatch from a background worker, make consumers/vendor calls idempotent.

**Inbound webhooks**

- Verify the signature (e.g. HMAC) over the raw request body before parsing, using constant-time
  comparison; reject stale timestamps to prevent replay.
- Acknowledge fast (200/202), then process asynchronously. Deduplicate by event ID, because
  vendors deliver at least once and out of order.

**Operations**

- Propagate a correlation ID across the boundary; log vendor request IDs.
- Redact PII, tokens, and secrets from logs, traces, and error messages (including request/response bodies).
- Load credentials from a secret store or environment; never hardcode or commit them.

## Decision matrix

| Problem                                 | Pattern               | Key requirement                                   |
|-----------------------------------------|-----------------------|---------------------------------------------------|
| Unstable endpoint, recurring downtime   | Circuit breaker       | Explicit trip threshold and recovery probe period |
| Vendor 429s, bursty outbound traffic    | Rate limiter          | Queue locally; respect `Retry-After`              |
| Risk of duplicate charge or creation    | Idempotency key       | Unique key per operation, reused on retry         |
| Local DB and external API state diverge | Transactional outbox  | Commit event with the DB change, dispatch later   |
| Vendor model differs from domain        | Anti-corruption layer | Explicit mapping; no vendor fields in domain      |
| Slow vendor exhausts shared resources   | Bulkhead              | Dedicated pool/concurrency cap per vendor         |

## Gotchas

- Retrying a non-idempotent POST without an idempotency key causes duplicate side effects. Also
  retrying after a timeout is dangerous because the vendor may have processed the request.
- Retries multiply across layers (client x service x gateway). Retry at one layer only.
- Do not count 4xx client errors toward circuit breaker failure rate.
- Retry budgets must fit inside the caller's own deadline; total retry time must not exceed it.
- Parsing the webhook body before verifying the signature over the raw bytes breaks verification.
- SDK exceptions and error enums are vendor types too: translate them into domain errors in the adapter.

## Verification checklist

Run against generated code before finishing; fix and re-check any failure.

- [ ] No vendor SDK/schema type crosses the adapter's public interface (params, returns, errors).
- [ ] Every outbound call has explicit connect and read/total timeouts.
- [ ] Retries use backoff with jitter, a cap, and only for idempotent or keyed operations.
- [ ] Non-idempotent mutations send an idempotency key.
- [ ] Circuit breaker thresholds and a fallback path are defined, or the omission is justified.
- [ ] Rate limiting covers known vendor quotas and honors response headers.
- [ ] Secrets come from a secret store/env; none are hardcoded or logged.
- [ ] Webhook handlers verify signatures, acknowledge fast, and deduplicate.
- [ ] Tests use a fake/mock adapter and simulate timeouts, 429, 5xx, malformed responses, and duplicate webhooks.
