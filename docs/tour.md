# Live tour

`scripts/live-tour.sh` exercises attention and the test loop in an isolated named Herdr session without touching your default session or Pi configuration.

```sh
HERDR_ENV=1 scripts/live-tour.sh
```

It creates a temporary Git repository with a failing Mix test, a mock OpenAI-compatible model, and a Jarvis2 server with `:run_command`, `:agent_prompt`, `:test_loop`, and `:attention` enabled. A Pi agent is started in the workspace and its lifecycle is reported to trigger a notification and the test loop. The script checks that the failing test output is prompted to the agent; visual notification delivery requires an attached client.

Output is `PASS`/`FAIL` lines; the temp directory is deleted on success and kept on failure. The script needs `herdr`, `pi`, `git`, `curl`, `python3`, and `mix`.
