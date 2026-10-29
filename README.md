# Jarvis2

A Phoenix / LiveView control plane for [Herdr](https://herdr.dev). From the browser you can watch the
live Herdr session, start a Pi agent in a new pane, steer it, and answer the questions and approvals it
raises through MCP. Everything that matters is stored in SQLite, so a restart loses nothing but the
in-memory Herdr mirror.

## Quick start

```sh
mix deps.get
mix run --no-halt          # or: iex --sname jarvis2 -S mix
```

Migrations run at boot. The server prints a single-use sign-in link:

```
Jarvis2 UI: http://127.0.0.1:4747/login?code=…  (single use, 10 minutes)
```

Open it in your browser. The code is printed to stdout rather than logged. If it expires, restart, or
paste the long-lived token from `$JARVIS2_STATE_DIR/token` (default `~/.local/state/jarvis2/token`) on
the login page. Jarvis2 creates and uses its own Herdr session; it need not run inside Herdr.
Watch the session with `herdr session attach jarvis2`.

| Variable            | Meaning                                                                    |
| ------------------- | -------------------------------------------------------------------------- |
| `JARVIS2_PORT`      | HTTP port on `127.0.0.1` (default `4747`)                                  |
| `JARVIS2_STATE_DIR` | token, cookie secret and `jarvis2.db` (default `~/.local/state/jarvis2`)   |
| `JARVIS2_SCENARIOS` | optional comma-separated lock-down of the actions that may ever be enabled |

A release works too: `MIX_ENV=prod mix release` then `_build/prod/rel/jarvis2/bin/jarvis2 start`.

## The showcase: a Pi agent on `openrouter/openai/gpt-6-luna`

1. Start with `mix run --no-halt` and sign in.
2. **New run**: the form is prefilled with agent `pi`, model `openrouter/openai/gpt-6-luna`, thinking `low`.
   Give it a task, for example _Ask me which file to change, then ask for approval before editing_.
3. Jarvis2 splits a pane next to the anchor pane, starts Pi there with
   `--provider openrouter --model openai/gpt-6-luna --thinking low`, and delivers the task. The run page
   shows status and a live timeline. The agent's questions appear as cards on the run
   page and in the **Inbox**; answering unblocks it. `submit_result` finishes the run.

`MODEL=luna scripts/live-tour.sh` sets up an isolated Herdr session for a manual showcase
(it uses your real Pi configuration and OpenRouter credits).

For an agent to call Jarvis2's tools, Pi needs the `jarvis2` MCP server. The repository's `.pi/mcp.json`
(used after Pi project trust) sends `X-Herdr-Pane` and `X-Herdr-Workspace` from the pane environment.
For runs started in other directories, add the same `jarvis2` entry, including those headers, to
`~/.pi/agent/mcp.json`.

## Screens

| Route                             | Purpose                                                                                                                               |
| --------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| `/`                               | Dashboard: connection, workspace → tab → pane tree, agents, worktrees, layout diff, recent events, _Apply dev layout_ |
| `/runs`, `/runs/new`, `/runs/:id` | Runs with status filter; start form; run page with questions, prompt box, timeline, stop; Mix jobs                     |
| `/inbox`                          | Every pending question and approval, with a count badge in the navigation                                                             |
| `/blackboard`                     | Notes shared between agents and you (JSON values)                                                                                     |
| `/events`                         | The journal, filterable by source, type prefix and run                                                                                |
| `/settings`                       | Which actions are enabled and defaults for new runs                                                                |

Every page except `/login`, `/healthz`, `/status` and `/mcp` needs a session.

## MCP tools

The MCP endpoint (`/mcp`, streamable HTTP) is unauthenticated. Run-only tools resolve the active run
from the pane header. Agent state comes from Herdr; pending questions and approvals appear on the
run page and in `/inbox`, even while Herdr shows the agent as working. Every tool has a UI surface
or is agent-only:

| Tool                                               | Where you see it                                                        |
| -------------------------------------------------- | ----------------------------------------------------------------------- |
| `whoami`, `log`, `wait_for_event`, `notify_human`  | agent-only (calls appear in `/events`)                                  |
| `blackboard_put/get/list`                          | `/blackboard`                                                           |
| `list_agents`, `get_layout`, `list_worktrees`      | `/`                                                                     |
| `read_agent`                                       | agent-only                                                              |
| `prompt_agent`, `spawn_agent`, `run_command`       | `fleet.*` rows in `/events`                                             |
| `apply_layout`                                     | _Apply dev layout_ on `/`                                               |
| `run_mix`                                          | a run of kind `mix` on `/runs`                                          |
| `ask_human`, `request_approval`, `wait_for_answer` | run page and `/inbox` (run pane only)                                 |
| `submit_result`                                    | run page _Result_ (run pane only)                                     |

Resources: `jarvis2://session`, `layout` and `worktrees` (dashboard), `events/recent` and `journal`
(`/events`), `blackboard` (`/blackboard`). `jarvis2://layout` includes the net layout diff (membership,
focus, geometry, split ratios, agent state; limited to 64 changes, `resynced` after a subscription gap,
`unavailable` when invalid or oversized). Browser-origin requests to `/mcp` are rejected.

`ask_human` and `request_approval` return a ticket immediately; the agent polls `wait_for_answer(ticket,
timeout_s ≤ 100)` until it is no longer `pending`. Questions expire after an hour and are cancelled on
result submission or when the run stops, fails or is lost; a run may have five open at a time.

## Safety model

- **Dedicated session.** Jarvis2 creates and uses only the Herdr session `jarvis2`; it never stops or
  deletes it. Runs make real changes in that session. Disabled scenario actions are refused;
  `JARVIS2_SCENARIOS` can restrict which actions may be enabled in Settings.
- **Loopback only.** Bound to `127.0.0.1`; requests with a non-loopback `Host` are refused (DNS rebinding);
  the LiveView socket checks origin; `/mcp` refuses browser origins. Sign-in uses single-use codes and a
  signed session cookie.
- **MCP identity is unauthenticated.** `X-Herdr-Pane` selects an active run, including one that has
  submitted a result. Any local process can claim another pane and call MCP tools or answer for its run.
  A fresh mirror checks the recorded terminal against the pane. Loopback binding, Host and Origin checks,
  scenario gates, execution/prompt guards and rate limits remain in place.
- **Guarded UI and MCP.** UI run actions act as the system caller `ui` through the execution and prompt
  guards and are audited as `fleet.*` events. They skip scenario toggles and the "caller must be a detected
  agent" check; other guard checks still apply.
- **Redaction.** Prompt, command and summary text, blackboard values and matched output lines are never stored in
  the journal (only their sizes); credential-looking keys and bearer strings are masked.

Existing PoC safeguards remain: `prompt_agent` needs a fresh mirror and a detected caller, targets only a ready
agent in the same workspace, refuses self-prompts and cycles, and allows four attempts a minute per caller;
`spawn_agent` and `run_command` create a sibling pane in the caller's directory, recheck the new terminal and
serialise per caller. These are process-local limits, not a security boundary: pane headers are advisory, state
is not shared between instances, and Herdr offers no atomic expected-occupant check. `run_command` sends one
shell line to the new pane and is **not sandboxed**. `run_mix` runs an allow-listed task (`test`, `compile`,
`format --check-formatted`) in the project where the server started; it executes that project's code
and needs GNU `timeout`. Herdr serves one request per connection, so Jarvis2 opens one per request.

## Automations

Enabled from Settings, each records `automation.*` rows in the journal:

- `attention`: notification and window title when an agent becomes blocked or done.
- `test_loop` (with `run_command` and `agent_prompt`): when an agent in a Mix project under `:test_loop_roots`
  (default: the server's project) finishes a turn, runs `mix test` in a sibling pane and prompts the agent with
  a sanitised tail on failure (three failures per pane, 20 s apart). Runs project code; the tail may contain
  secrets printed by tests.
- `output_watcher`: notification when watched pane output matches.
- `sidebar_tokens` / `pane_hygiene`: `$agent_state` and `$last_tool` sidebar tokens (60 s TTL) and
  pane/tab renaming, which can overwrite manual labels; see `examples/herdr-config.snippet.toml`.
  The shared Herdr configuration also applies when you attach to `jarvis2`.
- `custom_worker`: shows a running `run_mix` job on the server's own pane, if it is in the dedicated session.
- `declarative_layout`: the _dev_ layout, a **new** tab with three labelled shells.

## Development

```sh
mix test                     # umbrella: herdr_client + jarvis2
mix format --check-formatted
mix compile --warnings-as-errors
mix credo                    # reports existing findings in the guarded-execution code
scripts/live-tour.sh         # end-to-end check against an isolated Herdr session and a mock model
```

Layout: `apps/herdr_client` (socket client and a fake Herdr for tests) and `apps/jarvis2` (contexts under
`lib/jarvis2`, web under `lib/jarvis2_web`). Contexts own the logic; LiveViews and MCP tools are thin
front-ends over them. See `plan.md` for the design and decisions.
