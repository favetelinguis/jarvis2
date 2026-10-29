# Umbrella project

- Jarvis2 is a Phoenix/LiveView control plane for Herdr. See `README.md` for setup, architecture, and the safety model.
- The umbrella root `mix.exs` lists the active apps: `apps/herdr_client` owns the Herdr socket client and test fake; `apps/jarvis2` owns contexts, persistence, MCP, and `lib/jarvis2_web`. Put business logic in contexts; keep LiveViews and MCP tools thin.
- `:jarvis2` depends on `:herdr_client` via `in_umbrella: true`. Keep app boundaries explicit and use public APIs; add cross-app dependencies in the consuming app's `mix.exs`. The apps share `config/`, `deps/`, `_build/`, and `mix.lock`.
- Use the Elixir/OTP versions in `mise.toml`. Run checks from the umbrella root; for a focused test, use `mix test apps/<app>/test/<file>_test.exs` (optionally append `:line`).
- Reuse `Jarvis2.DataCase` or `Jarvis2Web.ConnCase` for database/web tests and `Jarvis2.Test.FakeHerdr` for socket tests. Test configuration uses a temporary SQLite database and disables live Herdr integration; avoid real sessions in automated tests.
- Normal startup can create a Herdr session, modify persistent state, and expose a local server. Review `README.md`'s safety model before live testing, particularly its unauthenticated local MCP endpoint and real command execution.

# Project checks

- During development, use Expert diagnostics for fast feedback on changed Elixir files and run focused tests when useful. Batch related edits rather than running every check after each edit.
- Before finishing Elixir changes, run formatting checks, compile with warnings as errors, and run relevant tests and Credo. Run the full `mix test` suite before finishing when practical.
- Report failed or unrun checks, including pre-existing Credo findings; do not silently suppress them.
