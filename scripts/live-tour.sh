#!/bin/bash
# Scripted tour of the live workflows against an isolated Herdr session.
#
#   scripts/live-tour.sh              mock model: automated PASS/FAIL checks, safe for CI-style use.
#   TOUR=review scripts/live-tour.sh  mock implementer/fix review, including a human blocker.
#   MODEL=luna scripts/live-tour.sh   showcase: starts Jarvis2 against an isolated Herdr session and
#                                     leaves it running so you can start a real openrouter/openai/gpt-6-luna
#                                     run from the browser. Uses your real Pi configuration and credits.
#
# Requires HERDR_ENV=1, herdr, pi, git, curl, python3 and mise/mix. The mock mode never touches the
# default Herdr session or your Pi configuration. Results are summarised as PASS/FAIL lines; the app
# log is kept in the printed temp dir on failure.
set -u
[ "${HERDR_ENV:-}" = 1 ] || { echo "HERDR_ENV=1 is required" >&2; exit 2; }
root=$(cd "$(dirname "$0")/.." && pwd)
d=$(mktemp -d /tmp/jarvis2-tour.XXXXXX)
n=jarvis2
free_port(){ python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])'; }
luna=0; [ "${MODEL:-mock}" = luna ] && luna=1
review=0; [ "${TOUR:-}" = review ] && review=1
[ "$luna" = 1 ] && [ "$review" = 1 ] && { echo "TOUR=review requires the mock model" >&2; exit 2; }
mp=$(free_port); jp=$(free_port)
[ "$luna" = 1 ] && jp=${JARVIS2_PORT:-4747}   # your Pi MCP config points at this port
fail=0; mock=; app=
check(){ if grep -q -- "$2" "$d/app.log"; then echo "PASS $1"; else echo "FAIL $1"; fail=1; fi; }

export XDG_CONFIG_HOME="$d/config" XDG_DATA_HOME="$d/data" HERDR_CONFIG_PATH="$d/config/herdr/config.toml" \
  ZDOTDIR="$d/home"
mkdir -p "$d/config/herdr" "$d/home" "$d/pi" "$d/repo" "$d/state"; touch "$d/home/.zshrc"
printf 'onboarding = false\n' > "$HERDR_CONFIG_PATH"
unset HERDR_SOCKET_PATH HERDR_PANE_ID HERDR_WORKSPACE_ID HERDR_TAB_ID
if [ "$luna" = 1 ]; then
  pi auth check --provider openrouter --model openai/gpt-6-luna --no-refresh >/dev/null 2>&1 \
    || { echo "Pi has no OpenRouter credentials (set OPENROUTER_API_KEY or log in with pi)" >&2; exit 2; }
  grep -qs jarvis2 "${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}/mcp.json" \
    || echo "note: add the jarvis2 server from .pi/mcp.json to ${PI_CODING_AGENT_DIR:-~/.pi/agent}/mcp.json so agents can call its tools" >&2
else
  export PI_CODING_AGENT_DIR="$d/pi" PI_OFFLINE=1 PI_SKIP_VERSION_CHECK=1
  [ "$review" = 1 ] && export MOCK_REVIEW_FLOW=1
  printf '{"providers":{"mock":{"baseUrl":"http://127.0.0.1:%s/v1","api":"openai-completions","apiKey":"x","models":[{"id":"mock"}]}}}\n' "$mp" > "$d/pi/models.json"
  printf '{"defaultProvider":"mock","defaultModel":"mock","quietStartup":true}\n' > "$d/pi/settings.json"
  python3 "$root/scripts/mock_model.py" "$mp" "$d/requests.log" & mock=$!
fi
(cd "$d/repo" && git init -q -b main && mkdir test && printf 'defmodule T.MixProject do\n  use Mix.Project\n  def project, do: [app: :t, version: "0.1.0"]\nend\n' > mix.exs \
  && printf 'ExUnit.start()\n' > test/test_helper.exs \
  && printf 'defmodule XTest do\n  use ExUnit.Case\n  test "fails", do: assert(1 == 2)\nend\n' > test/x_test.exs \
  && git add . && git -c user.email=a@b -c user.name=t commit -q -m init)
cleanup(){ herdr session stop "$n" >/dev/null 2>&1; herdr session delete "$n" >/dev/null 2>&1; kill $mock $app 2>/dev/null; wait 2>/dev/null
  if [ "$fail" = 0 ]; then rm -rf "$d"; else echo "kept $d"; fi; }
trap cleanup EXIT
cd "$root"
if [ "$review" = 1 ]; then
  mkdir -p "$d/roles" "$d/tmp"
  git -C "$d/repo" worktree add -q -b tour-linked "$d/linked" || { fail=1; exit 1; }
  cp "$root/roles/fix.md" "$d/roles/fix.md"
  python3 - "$d/roles/fix.md" <<'PY'
import pathlib, re, sys
path = pathlib.Path(sys.argv[1])
text = path.read_text()
text = re.sub(r'^model: .*$', 'model: mock/mock', text, flags=re.MULTILINE)
text = re.sub(r'^effort: .*$', 'effort: off', text, flags=re.MULTILINE)
path.write_text(text)
PY
  export JARVIS2_ROLES_DIR="$d/roles" TMPDIR="$d/tmp" TOUR_REPO="$d/repo" TOUR_PORT="$jp" TOUR_REQUEST_LOG="$d/requests.log"
  if MIX_ENV=test timeout 180 mix run scripts/live-review.exs >"$d/app.log" 2>&1; then
    grep '^PASS ' "$d/app.log"
  else
    echo "FAIL review tour; see $d/app.log and $d/requests.log" >&2
    fail=1
  fi
  exit "$fail"
fi
if [ "$luna" = 1 ]; then
  JARVIS2_PORT=$jp JARVIS2_STATE_DIR="$d/state" \
    mix run --no-halt >"$d/app.log" 2>&1 & app=$!
  for _ in $(seq 1 200); do curl -s -o /dev/null "http://127.0.0.1:$jp/healthz" && break; sleep .2; done
  echo "Isolated Herdr session: $n   (watch it with: XDG_CONFIG_HOME=$XDG_CONFIG_HOME herdr session attach $n)"
  grep -a 'Jarvis2 UI' "$d/app.log" || { echo "Jarvis2 did not start; see $d/app.log" >&2; fail=1; exit 1; }
  echo "Open the link above, add a Kanban card and drag it to Agent (defaults: pi, openrouter/openai/gpt-6-luna, thinking low)."
  echo "Press Enter here to stop and clean up."
  read -r _
  exit 0
fi
JARVIS2_PORT=$jp JARVIS2_STATE_DIR="$d/state" \
  mix run --no-halt -e "Application.put_env(:jarvis2, :live_scenarios, [:run_command, :agent_prompt, :test_loop, :attention]); Application.put_env(:jarvis2, :test_loop_roots, [\"$d\"])" >"$d/app.log" 2>&1 & app=$!
for _ in $(seq 1 200); do curl -s -o /dev/null "http://127.0.0.1:$jp/healthz" && break; sleep .2; done
pane=$(herdr --session "$n" workspace create --label jarvis2 --cwd "$d/repo" --no-focus | python3 -c 'import json,sys;print(json.load(sys.stdin)["result"]["root_pane"]["pane_id"])')
herdr --session "$n" agent start tour --kind pi --pane "$pane" >/dev/null || { echo "FAIL agent start"; fail=1; exit 1; }
sleep 3
# Herdr's detector does not see Pi's mock turn, so report the lifecycle explicitly.
herdr --session "$n" pane report-agent "$pane" --source custom:tour --agent pi --state blocked >/dev/null
sleep 2
herdr --session "$n" pane report-agent "$pane" --source custom:tour --agent pi --state working >/dev/null
sleep 2
herdr --session "$n" pane report-agent "$pane" --source custom:tour --agent pi --state idle >/dev/null
sleep 45

check "attention notification accepted" 'live :attention "notification.show".*outcome=ok'
check "test loop matched marker"        'test loop wait=matched'
check "failure prompted to the agent"   'live :agent_prompt "agent.prompt" caller="system:test-loop" outcome=ok'
grep -q 'failed (exit 2)' "$d/requests.log" && echo "PASS agent received test failure" || { echo "FAIL agent received test failure"; fail=1; }
exit $fail
