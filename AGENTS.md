# Project checks

- During development, use Expert diagnostics for fast feedback on changed Elixir files and run focused tests when useful. Batch related edits rather than running every check after each edit.
- Before finishing Elixir changes, run formatting checks, compile with warnings as errors, and run relevant tests and Credo. Run the full `mix test` suite before finishing when practical.
- Report failed or unrun checks, including pre-existing Credo findings; do not silently suppress them.
