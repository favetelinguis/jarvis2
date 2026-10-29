#!/bin/bash
# Scripted tour of the live workflows against an isolated Herdr session and a mock model.
# Requires HERDR_ENV=1, herdr, pi, git, curl, python3 and mise/mix. It never touches the
# default Herdr session, your Pi configuration, or globally linked plugins. Results are
# summarised as PASS/FAIL lines; the app log is kept in the printed temp dir on failure.
set -u
[ "${HERDR_ENV:-}" = 1 ] || { echo "HERDR_ENV=1 is required" >&2; exit 2; }
root=$(cd "$(dirname "$0")/.." && pwd)
d=$(mktemp -d /tmp/jarvis2-tour.XXXXXX)
n="jarvis2-tour-${d##*.}"
free_port(){ python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])'; }
mp=$(free_port); jp=$(free_port)
fail=0
check(){ if grep -q -- "$2" "$d/app.log"; then echo "PASS $1"; else echo "FAIL $1"; fail=1; fi; }

export XDG_CONFIG_HOME="$d/config" XDG_DATA_HOME="$d/data" HERDR_CONFIG_PATH="$d/config/herdr/config.toml" \
  ZDOTDIR="$d/home" PI_CODING_AGENT_DIR="$d/pi" PI_OFFLINE=1 PI_SKIP_VERSION_CHECK=1
mkdir -p "$d/config/herdr" "$d/home" "$d/pi" "$d/repo" "$d/state"; touch "$d/home/.zshrc"
printf 'onboarding = false\n' > "$HERDR_CONFIG_PATH"
printf '{"providers":{"mock":{"baseUrl":"http://127.0.0.1:%s/v1","api":"openai-completions","apiKey":"x","models":[{"id":"mock"}]}}}\n' "$mp" > "$d/pi/models.json"
printf '{"defaultProvider":"mock","defaultModel":"mock","quietStartup":true}\n' > "$d/pi/settings.json"
unset HERDR_SOCKET_PATH HERDR_PANE_ID HERDR_WORKSPACE_ID HERDR_TAB_ID

python3 "$root/scripts/mock_model.py" "$mp" "$d/requests.log" & mock=$!
(cd "$d/repo" && git init -q -b main && mkdir test && printf 'defmodule T.MixProject do\n  use Mix.Project\n  def project, do: [app: :t, version: "0.1.0"]\nend\n' > mix.exs \
  && printf 'ExUnit.start()\n' > test/test_helper.exs \
  && printf 'defmodule XTest do\n  use ExUnit.Case\n  test "fails", do: assert(1 == 2)\nend\n' > test/x_test.exs \
  && git add . && git -c user.email=a@b -c user.name=t commit -q -m init)
herdr --session "$n" server >"$d/server.log" 2>&1 & server=$!
cleanup(){ herdr session stop "$n" >/dev/null 2>&1; herdr session delete "$n" >/dev/null 2>&1; kill $server $mock $app 2>/dev/null; wait 2>/dev/null
  if [ "$fail" = 0 ]; then rm -rf "$d"; else echo "kept $d"; fi; }
trap cleanup EXIT
for _ in $(seq 1 100); do herdr --session "$n" api snapshot >/dev/null 2>&1 && break; sleep .1; done
herdr --session "$n" workspace create --cwd "$d/repo" --no-focus >/dev/null
sock=$(herdr session list --json | python3 -c 'import json,sys;print(next(s["socket_path"] for s in json.load(sys.stdin)["sessions"] if s["name"]==sys.argv[1]))' "$n")

cd "$root"
HERDR_SOCKET_PATH="$sock" JARVIS2_LIVE=1 JARVIS2_PORT=$jp HERDR_PLUGIN_STATE_DIR="$d/state" \
  mix run --no-halt -e "Application.put_env(:jarvis2, :live_scenarios, [:worktree_task, :agent_spawn, :review_fanout, :run_command, :agent_prompt, :test_loop, :attention]); Application.put_env(:jarvis2, :worktree_root, \"$d/wt\"); Application.put_env(:jarvis2, :test_loop_roots, [\"$d\"])" >"$d/app.log" 2>&1 & app=$!
for _ in $(seq 1 200); do curl -s -o /dev/null "http://127.0.0.1:$jp/" && break; sleep .2; done
sleep 3
token=$(cat "$d/state/token")
post(){ curl -s -o /dev/null -X POST -H "authorization: Bearer $token" -H 'content-type: application/json' -d "$2" "http://127.0.0.1:$jp/hook/action/$1"; }
ctx='{"workspace_id":"w1","focused_pane_id":"w1:p1"}'

post issue-link "{\"context\":$ctx,\"clicked_url\":\"https://github.com/a/b/issues/7\"}"
sleep 22
post review-diff "{\"context\":$ctx}"
sleep 20
# Herdr's detector does not see Pi's mock turn, so report the lifecycle that triggers the test loop.
herdr --session "$n" pane report-agent w2:p1 --source custom:tour --agent pi --state working >/dev/null
sleep 2
herdr --session "$n" pane report-agent w2:p1 --source custom:tour --agent pi --state idle >/dev/null
sleep 45

check "worktree workspace created"     'live :worktree_task "worktree.create".*outcome=ok'
check "issue agent started"             'live agent.start caller="w1:p1" outcome=ok'
check "attention notification accepted" 'live :attention "notification.show".*outcome=ok'
check "review fan-out finished"         'review-diff finished reviews=2'
check "test loop matched marker"        'test loop wait=matched'
check "failure prompted to the agent"   'live :agent_prompt "agent.prompt" caller="system:test-loop" outcome=ok'
grep -q 'Work on https://github.com/a/b/issues/7' "$d/requests.log" && echo "PASS agent received the issue" || { echo "FAIL agent received the issue"; fail=1; }
grep -q 'failed (exit 2)' "$d/requests.log" && echo "PASS agent received test failure" || { echo "FAIL agent received test failure"; fail=1; }
[ -d "$d/wt/repo/issue-7" ] && echo "PASS worktree checkout exists" || { echo "FAIL worktree checkout exists"; fail=1; }
exit $fail
