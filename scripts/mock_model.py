"""OpenAI-compatible streaming endpoint for the isolated live tour.

Usage: mock_model.py PORT REQUEST_LOG. Set MOCK_REVIEW_FLOW=1 for the scripted
implementer/fix conversation; otherwise every request gets the test-loop reply.
"""
import json
import re
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps({"data": [{"id": "mock"}]}).encode())

    def do_POST(self):
        import os

        size = int(self.headers.get("content-length", 0))
        body = json.loads(self.rfile.read(size) or b"{}")
        messages = body.get("messages", [])
        review = os.environ.get("MOCK_REVIEW_FLOW") == "1"
        with open(sys.argv[2], "a") as log:
            log.write(json.dumps(body if review else messages[-1]) + "\n")

        if review:
            tool, args, reply = review_reply(messages)
        else:
            time.sleep(3)
            tool, args, reply = None, None, "REVIEW-FINDING mock reply"

        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.end_headers()
        base = {"id": "c1", "object": "chat.completion.chunk", "created": 1, "model": "mock"}

        def emit(delta, finish=None):
            chunk = {**base, "choices": [{"index": 0, "delta": delta, "finish_reason": finish}]}
            self.wfile.write(("data: " + json.dumps(chunk) + "\n\n").encode())
            self.wfile.flush()

        if tool:
            emit({"role": "assistant", "tool_calls": [{
                "index": 0, "id": "call_" + str(time.time_ns()), "type": "function",
                "function": {"name": tool if tool in ("bash", "edit") else "mcp__jarvis2_run__" + tool,
                             "arguments": json.dumps(args)},
            }]})
            emit({}, "tool_calls")
        else:
            emit({"role": "assistant", "content": reply})
            emit({}, "stop")
        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()


def review_reply(messages):
    # All markers and tool outputs belong to the temporary mock project.
    transcript = json.dumps(messages)
    blocked = "TOUR_BLOCKED" in transcript
    child = "Working as a subagent" in transcript
    calls = [call for msg in messages for call in msg.get("tool_calls", [])]
    last = calls[-1]["function"]["name"].removeprefix("mcp__jarvis2_run__") if calls else None
    result = str(messages[-1].get("content", "")) if messages and messages[-1].get("role") == "tool" else ""

    if child:
        if last == "submit_result":
            return None, None, "Review submitted."
        if last is None:
            return "bash", {"command": "printf 'TOUR_ENV run=%s pane=%s\\n' \"$JARVIS2_RUN_ID\" \"$HERDR_PANE_ID\""}, None
        if last != "bash" or not re.search(r"TOUR_ENV run=[0-9a-f-]{36} pane=\S+", result):
            return None, None, "Missing subagent environment: " + result
        report = ("Verdict: blocked\n[blocker] Which format? | conflict | A | B"
                  if blocked else "Verdict: fix\n[must] sample.txt:1 | missing line | add it")
        return "submit_result", {"summary": report}, None

    if last == "submit_deliverable":
        return None, None, "Implementation complete."
    if last == "edit":
        content = ("Fix review: blocked; answer applied: TOUR_ANSWER" if blocked
                   else "Fix review: fix; sample finding addressed.")
        return "submit_deliverable", {"content": content}, None
    if "TOUR_ANSWER" in transcript:
        return "edit", {"path": "sample.txt", "edits": [{"oldText": "initial\n", "newText": "initial\nreview-fixed\n"}]}, None
    if last == "ask_questions":
        return None, None, "Waiting for the human's answer."
    if last == "wait_for_subagent" and '"finished"' in result:
        if blocked:
            return "ask_questions", {"questions": [{
                "title": "Which format?", "body": "The requirement conflicts.",
                "recommended": "A", "options": ["B"],
            }]}, None
        return "edit", {"path": "sample.txt", "edits": [{"oldText": "initial\n", "newText": "initial\nreview-fixed\n"}]}, None
    if last in ("spawn_subagent", "wait_for_subagent"):
        match = re.search(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", result)
        if not match:
            return None, None, "Review unavailable: " + result
        return "wait_for_subagent", {"id": match.group(), "timeout_s": 30}, None
    return "spawn_subagent", {"role": "fix", "task": "TOUR_BLOCKED" if blocked else "TOUR_NORMAL"}, None


ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
