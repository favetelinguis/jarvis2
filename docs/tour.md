# Live tour

`scripts/live-tour.sh` runs Jarvis2 with an isolated `XDG_CONFIG_HOME`; its `jarvis2` session is separate
from your normal sessions. `HERDR_ENV=1` is required by this script, not by Jarvis2.

## Automated check (mock model)

```sh
HERDR_ENV=1 scripts/live-tour.sh
```

It creates a temporary Git repository with a failing Mix test, a mock OpenAI-compatible model and a Jarvis2
server with `run_command`, `agent_prompt`, `test_loop` and `attention` enabled. A Pi agent is started in the
workspace and its lifecycle is reported to trigger a notification and the test loop. The script checks that
the failing test output is prompted back to the agent; visual notification delivery needs an attached client.

Output is `PASS`/`FAIL` lines. The temp directory is deleted on success and kept on failure. The mock mode
uses a temporary Pi configuration and never calls a real model.

## Manual showcase (real model)

```sh
HERDR_ENV=1 MODEL=luna scripts/live-tour.sh
```

This starts Jarvis2 against an isolated Herdr session, prints the single-use sign-in link and waits. Open the link, choose **New run** (defaults: `pi`,
`openrouter/openai/gpt-6-luna`, thinking `low`) and give it a task such as *Ask me which file to change, then
ask for approval before editing*. Watch the pane using the attach command printed by the script (including its `XDG_CONFIG_HOME`);
answer the agent's questions in **Inbox** or on the run page; press Enter in the script to clean up.

It uses your real Pi configuration and OpenRouter credentials (so it costs tokens). For the agent to call
Jarvis2's tools, add the `jarvis2` server from `.pi/mcp.json` to `~/.pi/agent/mcp.json`; the script warns if
it is missing. It binds `JARVIS2_PORT` (default `4747`) because that is what the Pi MCP configuration points at.

Both modes need `herdr`, `pi`, `git`, `curl`, `python3` and `mix`.
