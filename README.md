# Jarvis2

A Phoenix / LiveView control plane for [Herdr](https://herdr.dev). From the browser you can watch the
live Herdr session, start a Pi agent from a board card, and answer the questions and approvals it
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
| `JARVIS2_ROLES_DIR` | role Markdown directory (default: umbrella root `roles/`) |
| `JARVIS2_SKILLS_DIR` | Pi run skills directory (default: umbrella root `skills/`) |

A release works too: `MIX_ENV=prod mix release` then `_build/prod/rel/jarvis2/bin/jarvis2 start`.

## The showcase: a Pi agent on `openrouter/openai/gpt-6-luna`

1. Start with `mix run --no-halt` and sign in.
2. On **Kanban**, add a card with an idea, then drag it to **Agent**. The default agent is Pi; the
   step role selects model and thinking (the shipped roles use `openrouter/openai/gpt-6-luna` and `low`).
   Settings provide fallbacks when the role omits either value.
3. Jarvis2 creates a tab in the card's project workspace (or its worktree's workspace), starts Pi with a Jarvis2 MCP extension,
   and delivers the card. Answer card questions on the board and other questions in **Inbox**.
   When finished, archive the card to close its tab; restore it with a reason to reload its Pi session.

`MODEL=luna scripts/live-tour.sh` sets up an isolated Herdr session for a manual showcase
(it uses your real Pi configuration and OpenRouter credits).

Pi runs explicitly load `.pi/jarvis2-run.js`, which registers the `jarvis2_run` MCP server using the
run's URL and Herdr pane headers, regardless of the run's working directory. Its path is temporarily
hardcoded to `/home/favetelinguis/repos/jarvis2/.pi/jarvis2-run.js`. Pi runs advertise only skills
from `JARVIS2_SKILLS_DIR`, not skills discovered from the host or the run workspace. Skill instructions
are loaded on demand. Manual Pi sessions use the separate board integration below.

### Create cards from any Pi session

Open **Harness** and click **Install Pi integration** to add the card-creation tool to Pi's global
MCP configuration on the machine running Jarvis2. The page shows the target path and preserves
other servers. It uses `PI_CODING_AGENT_DIR` from Jarvis2's environment when set, otherwise
`~/.pi/agent`. It replaces the `jarvis2_board` entry when updating, and refuses invalid or
symlinked configurations.

Alternatively, add this entry under `mcpServers` in `~/.pi/agent/mcp.json` (keep any existing
entries):

```json
"jarvis2_board": {
  "url": "http://127.0.0.1:4747/mcp/board",
  "description": "Create Jarvis2 kanban cards for the current working directory.",
  "exposure": "direct"
}
```

Use the configured `JARVIS2_PORT` if it differs. Restart Pi or run `/reload` after changing its
configuration. Jarvis2 must be running. Pi supplies its session working directory explicitly; the
server requires an existing absolute directory. The card is created in Scratch, defaults to Plan,
and does not start an agent. Other kinds can be requested. The board endpoint also provides
`list_ready_cards`, `add_dependency` and `remove_dependency`; it can remove only harness-created
edges. The full unauthenticated `/mcp` endpoint remains available to local processes.

## Screens

| Route                             | Purpose                                                                                                                               |
| --------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| `/`                               | Dashboard: connection, workspace → tab → pane tree, agents, worktrees, layout diff, recent events |
| `/kanban` | Deliverables board; archive cards to close their tab and restore with a reason and Pi session reload |
| `/kanban/graph` | Project dependencies, ready cards and worktree lanes |
| `/inbox`                          | Every pending question and approval, with a count badge in the navigation                                                             |
| `/blackboard`                     | Notes shared between agents and you (JSON values)                                                                                     |
| `/events`                         | The journal, filterable by source, type prefix and run                                                                                |
| `/settings` | Which actions are enabled and defaults for new card agents |
| `/roles` | Assign roles to card steps and inspect role files |
| `/harness` | Install the Pi card-creation integration in the global MCP configuration |

Every page except `/login`, `/healthz`, `/status`, `/mcp` and `/mcp/board` needs a session.

## MCP tools

The MCP endpoints (`/mcp` and `/mcp/board`, streamable HTTP) are unauthenticated. Run-only tools resolve the active run
from the pane header. Agent state comes from Herdr; pending questions and approvals appear in `/inbox`, even while Herdr shows the agent as working. Every tool has a UI surface
or is agent-only:

| Tool                                               | Where you see it                                                        |
| -------------------------------------------------- | ----------------------------------------------------------------------- |
| `whoami`, `log`, `wait_for_event`, `notify_human`  | agent-only (calls appear in `/events`)                                  |
| `blackboard_put/get/list`                          | `/blackboard`                                                           |
| `create_card` | creates a Scratch card on `/kanban`; no run identity required |
| `list_ready_cards`, `add_dependency`, `remove_dependency` | board endpoint only; dependencies on `/kanban` and `/kanban/graph` |
| `list_agents`, `get_layout`, `list_worktrees`      | `/`                                                                     |
| `read_agent`                                       | agent-only                                                              |
| `prompt_agent`, `spawn_agent`, `run_command`       | `fleet.*` rows in `/events`                                             |
| `run_mix` | job data in the `runs` table; calls appear in `/events` |
| `ask_human`, `request_approval`, `wait_for_answer` | `/inbox` and `/events` (run pane only) |
| `submit_result` | agent-only; calls appear in `/events` (run pane only) |
| `spawn_subagent`, `wait_for_subagent` | run-only fix review; calls appear in `/events` |
| `ask_questions`, `submit_deliverable`, `report_skill` | kanban card (kanban run pane only)                                |

Resources: `jarvis2://session`, `layout` and `worktrees` (dashboard), `events/recent` and `journal`
(`/events`), `blackboard` (`/blackboard`). `jarvis2://layout` includes the net layout diff (membership,
focus, geometry, split ratios, agent state; limited to 64 changes, `resynced` after a subscription gap,
`unavailable` when invalid or oversized). Browser-origin requests to `/mcp` are rejected.

Only the board UI moves cards into or out of Archive; MCP has no archive or restore tool. Restore
prompts preserve the reason, idea and role instructions; optional history and prior deliverables may
be truncated. The entire agent prompt is limited to 65,536 bytes. If
mandatory content does not fit, the step is refused. If the saved Pi session is missing, Pi starts a
fresh session with that context.

A Scratch card can depend on other cards in the same project, including cards in another worktree.
The board and graph refuse to start it until its prerequisites are satisfied. A Plan prerequisite can
be needed as an accepted plan or as a completed implementation. Archived prerequisites do not satisfy
a dependency. Reopening a prerequisite does not stop a dependent already running; it is marked stale.
Prerequisite results are passed as bounded text, not as code shared across worktrees.

On the graph page, **Arrange** explicitly starts a read-only-prompted agent to propose dependencies
for up to 50 oldest unarranged Scratch cards. Review and select the proposed edges before accepting;
dismissing changes nothing. Re-arrange removes only arranger-created edges on Scratch cards, never
human or harness edges. The nudge threshold in Settings defaults to 3; 0 disables the nudge. The
arranger's read-only restriction is a prompt instruction, **not a sandbox**: it runs with the same
machine access as other Pi agents.

Plan cards have Planning and Implementation stages. Once a plan is Done, **Accept plan** overwrites
`PLAN.md` in the planner run's checkout (the chosen worktree, if any) and starts a new implementer pane in the same tab (or a new
tab if the planner pane is gone). The accepted plan remains visible alongside the implementation report.
Dragging a Done card back to Agent instead reopens its current stage with feedback. Archive and restore
retain the current stage.

Agents file cards audit root `AGENTS.md` and `CLAUDE.md` and propose a complete `AGENTS.md`. Review the server-computed diff and reasons, then Apply to write it in the run checkout and archive the card; Reopen with feedback to revise it. Jarvis2 never writes `CLAUDE.md`. It rejects changes to either file during the run and changes to `AGENTS.md` after submission.

Research, Explain, Review, Refine, Slides and Architecture have a single stage and instruct the agent not to edit or
publish changes. Slides delivers a self-contained HTML deck with an in-board preview and browser download. Architecture scans a codebase for deepening opportunities and delivers an HTML report the same way; paste a candidate's "Plan card idea" into a Plan card to design and implement it.
Planning retains its
existing prompt, while implementation explicitly allows edits and tests but asks the agent not to commit,
push or alter `PLAN.md`. These are prompt rules, not a sandbox: agents can make real changes. Review the
safety model before starting them. Agents started before the `submit_plan` rename must be restarted by
moving their card to Scratch and back to Agent.

`ask_human` and `request_approval` return a ticket immediately; the agent polls `wait_for_answer(ticket,
timeout_s ≤ 100)` until it is no longer `pending`. Questions expire after an hour and are cancelled on
result submission or when the run stops, fails or is lost; a run may have five open at a time.

## Roles

Each step maps to a role on `/roles`. Role files are re-read on each new step; a resumed live agent
keeps its existing role. New runs show the role as the pane label and Herdr agent display name; the
underlying agent name remains unique. To edit a role, change its Markdown file in `roles/` (or
`JARVIS2_ROLES_DIR`):

```markdown
---
name: planner
description: Turns ideas into plans.
model: openrouter/openai/gpt-6-luna
effort: low
---
Role instructions go here.
```

The name must match the filename stem, use lowercase letters, digits and single hyphens, and be at
most 64 bytes. Model and effort are optional; Settings supplies omitted values. Effort is one of
`off`, `minimal`, `low`, `medium`, `high`, `xhigh`, or `max`. Unknown frontmatter keys are ignored.
Jarvis2 appends one shared "Working with the human" section (questions, results, skill reports) to every role prompt, so role files hold only the job, its restrictions and which skills to load, in order. Domain detail lives in `skills/<name>/SKILL.md`.
The `fix` role is opted into subagent spawning with `subagent: true`; other roles are not eligible by default.
Role instructions govern the agent's job and any restrictions; they are not a sandbox. Missing or
invalid mapped roles prevent a new step from starting. Agents report loaded skills with `report_skill`;
the card shows these self-reports by stage, including across reopen and restore. A skill that an agent
fails to report is not visible. Pi runs receive the skills in `skills/` (`grilling`, `requirements-engineering`, `implement-plan`,
`grill-me`, `grill-with-docs`, `tdd`, `domain-modeling`, `codebase-design`, `improve-codebase-architecture`, `code-review`, `research`,
`explain-change`, `slide-deck`, `external-integration-design`, `agents-file`) in any working directory.

`GLOSSARY.md` (domain terms) and `docs/adr/` (hard-to-reverse decisions) in the project root are the shared
language: every role reads them and uses their terms. Read-only roles never edit them; they draft the changes in
their deliverable (a plan's Language and Decisions sections), and the implementer writes them with the code.

## Safety model

- **Dedicated session.** Jarvis2 creates and uses only the Herdr session `jarvis2`; it never stops or
  deletes it. Runs make real changes in that session. Disabled scenario actions are refused;
  `JARVIS2_SCENARIOS` can restrict which actions may be enabled in Settings.
- **Loopback only.** Bound to `127.0.0.1`; requests with a non-loopback `Host` are refused (DNS rebinding);
  the LiveView socket checks origin; both MCP endpoints refuse browser origins. Sign-in uses single-use codes and a
  signed session cookie.
- **MCP identity is unauthenticated.** `X-Herdr-Pane` selects an active run, including one that has
  submitted a result. Any local process can claim another pane and call MCP tools or answer for its run.
  This also permits asking kanban questions, submitting a deliverable, or starting model-spending subagents when enabled.
  Any local process can create Scratch cards and manage harness-created dependencies through the board MCP endpoint without a pane identity.
  A fresh mirror checks the recorded terminal against the pane. Loopback binding, Host and Origin checks,
  scenario gates, execution/prompt guards and rate limits remain in place.
- **Guarded UI and MCP.** UI run actions act as the system caller `ui` through the execution and prompt
  guards and are audited as `fleet.*` events. They skip scenario toggles and the "caller must be a detected
  agent" check; other guard checks still apply.
- **Worktrees.** A card can create a Git branch and worktree in the selected repository. Jarvis2 never sends `trust_repository`, removes worktrees, or explicitly closes workspaces. Herdr may close a workspace when its last tab closes.
- **Slide decks.** Agent-written HTML is untrusted. Preview and standalone views use a sandbox and restrictive CSP;
  downloads contain a CSP meta and are checked for common external references. The check is not a security
  boundary: a downloaded file runs scripts outside the preview sandbox and can navigate to remote sites. Review
  decks before sharing or opening them, especially on a networked machine.
- **Agents file Apply.** Apply writes the fixed `AGENTS.md` name (or its in-checkout symlink target) in the run working directory, including worktrees. Fingerprints detect ordinary edits but are not a sandbox or an atomic lock against concurrent external filesystem changes. The agent itself has normal machine access; its read-only restriction is a prompt rule. Review removals and keep backups.
- **Role files are trusted.** Role prompts are not sandboxed and can instruct an agent to make real
  changes. The model identifier is validated because it reaches a shell command line. A fix subagent
  shares its spawner's checkout; read-only review is a prompt rule, not a sandbox. The `subagents`
  scenario is disabled by default and can be restricted by `JARVIS2_SCENARIOS`.
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
  pane/tab renaming, which can overwrite manual labels (role-labelled run panes are preserved); see `examples/herdr-config.snippet.toml`.
  The shared Herdr configuration also applies when you attach to `jarvis2`.
- `custom_worker`: shows a running `run_mix` job on the server's own pane, if it is in the dedicated session.

## Development

```sh
mix test                     # umbrella: herdr_client + jarvis2
mix format --check-formatted
mix compile --warnings-as-errors
mix credo                    # reports existing findings in the guarded-execution code
scripts/live-tour.sh         # automation tour against an isolated Herdr session and a mock model
TOUR=review scripts/live-tour.sh  # normal and blocked fix-review flows (isolated test database)
```

Layout: `apps/herdr_client` (socket client and a fake Herdr for tests) and `apps/jarvis2` (contexts under
`lib/jarvis2`, web under `lib/jarvis2_web`). Contexts own the logic; LiveViews and MCP tools are thin
front-ends over them.
