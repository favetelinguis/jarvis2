# Live tour

`scripts/live-tour.sh` exercises the live workflows without touching your default Herdr session, Pi configuration or globally linked plugins.

```sh
HERDR_ENV=1 scripts/live-tour.sh
```

It starts an isolated named Herdr session with a temporary Git repository (containing a deliberately failing test), a mock OpenAI-compatible model, and a Jarvis2 server with these scenarios live: `:worktree_task`, `:agent_spawn`, `:review_fanout`, `:run_command`, `:agent_prompt`, `:test_loop`, `:attention`. It then posts the `issue-link` and `review-diff` actions, reports a Pi agent working then idle, and checks the app log and the mock model's request log:

| Step          | Expected                                                                                 |
| ------------- | ---------------------------------------------------------------------------------------- |
| `issue-link`  | linked worktree `task/issue-7` under the temp dir; Pi started with `Work on <issue URL>` |
| attention     | `notification.show` accepted by Herdr (visual delivery needs an attached client)         |
| `review-diff` | two reviewer agents; `reviews=2` logged; `review:latest` set                             |
| test loop     | `mix test` runs in a sibling pane, marker matched, failing tail prompted to the agent    |

Output is `PASS`/`FAIL` lines; the temp directory is deleted on success and kept on failure. The script needs `herdr`, `pi`, `git`, `curl`, `python3` and `mix`, and takes about two minutes.

Not covered: the HexDocs popup (needs `w3m`), link-handler dispatch and worktree event hooks (need `herdr plugin link`), the picker popup (needs an attached client; covered by an interactive check described in `PLAN.md`), and visual inspection of the dashboard.
