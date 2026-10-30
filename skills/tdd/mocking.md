# When to mock

Mock at **system boundaries** only: external APIs (payment, email, an LLM provider), time and randomness, and sometimes the filesystem or the database (prefer a real test database).

Never mock your own modules, internal collaborators, or anything you control.

## Make boundaries easy to fake

1. **Pass external dependencies in** rather than creating them inside: `process_payment(order, payment_client)`, not a function that builds its own client from environment variables.
2. **One function per external operation**, not one generic fetcher with conditional logic. Each fake then returns one shape, and a test shows which operations it exercises.
3. **Reuse the project's existing fakes and helpers** before writing a new one.
