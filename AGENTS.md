# Umbrella project

- Jarvis2 is a Phoenix/LiveView control plane for Herdr. See `README.md` for setup, architecture, and the safety model.
- The umbrella root `mix.exs` lists the active apps: `apps/herdr_client` owns the Herdr socket client and test fake; `apps/jarvis2` owns contexts, persistence, MCP, and `lib/jarvis2_web`. Put business logic in contexts; keep LiveViews and MCP tools thin.
- `:jarvis2` depends on `:herdr_client` via `in_umbrella: true`. Keep app boundaries explicit and use public APIs; add cross-app dependencies in the consuming app's `mix.exs`. The apps share `config/`, `deps/`, `_build/`, and `mix.lock`.
- Use the Elixir/OTP versions in `mise.toml`. Run checks from the umbrella root; for a focused test, use `mix test apps/<app>/test/<file>_test.exs` (optionally append `:line`).
- Reuse `Jarvis2.DataCase` or `Jarvis2Web.ConnCase` for database/web tests and `Jarvis2.Test.FakeHerdr` for socket tests. Test configuration uses a temporary SQLite database and disables live Herdr integration; avoid real sessions in automated tests.
- Normal startup can create a Herdr session, modify persistent state, and expose a local server. Review `README.md`'s safety model before live testing, particularly its unauthenticated local MCP endpoint and real command execution.

- `GLOSSARY.md` is the project's domain language and `docs/adr/` records its hard-to-reverse decisions. Read them before design or review work, use their terms in names, tests and docs, and update them (see the `domain-modeling` skill) when a change adds or changes a domain term or makes a decision that is hard to reverse, surprising and a real trade-off. They are the exception to "no new doc files".

# Project checks

- During development, use Expert diagnostics for fast feedback on changed Elixir files and run focused tests when useful. Batch related edits rather than running every check after each edit.
- Before finishing Elixir changes, run formatting checks, compile with warnings as errors, and run relevant tests and Credo. Run the full `mix test` suite before finishing when practical.
- Report failed or unrun checks, including pre-existing Credo findings; do not silently suppress them.

# Adding and editing skills

- Skills use progressive disclosure and are never invoked manually by a human. The agent decides to load one from its name and description, so write the description to say what the skill does and when to use it (trigger conditions and keywords); a vague description means the skill never loads.
- Project skills live in `skills/<name>/SKILL.md` at the umbrella root; add new ones there.
- Keep `SKILL.md` short and put detail in referenced files that are loaded only when needed.
- A role prompt (`roles/*.md`) acts as a meta skill: it should not hold domain detail itself, but describe which skills exist, when to load them, and how to navigate from one skill to the next.
- Reference skills to learn from or reuse live in `~/repos/skills` and `~/repos/agent-skills`. Check them before writing a new skill, and follow their conventions.
