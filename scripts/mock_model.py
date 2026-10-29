"""Tiny OpenAI-compatible streaming endpoint used by scripts/live-tour.sh.

Usage: mock_model.py PORT REQUEST_LOG. Every request is answered after three seconds.
"""
import json,sys,time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
class H(BaseHTTPRequestHandler):
    def log_message(self,*a): pass
    def do_GET(self):
        self.send_response(200);self.send_header('content-type','application/json');self.end_headers()
        self.wfile.write(json.dumps({"data":[{"id":"mock"}]}).encode())
    def do_POST(self):
        n=int(self.headers.get('content-length',0));body=json.loads(self.rfile.read(n) or b'{}')
        open(sys.argv[2],'a').write(json.dumps(body.get('messages',[])[-1])[:300]+'\n')
        time.sleep(3)
        self.send_response(200);self.send_header('content-type','text/event-stream');self.end_headers()
        def ev(o): self.wfile.write(('data: '+json.dumps(o)+'\n\n').encode());self.wfile.flush()
        base={"id":"c1","object":"chat.completion.chunk","created":1,"model":"mock"}
        ev({**base,"choices":[{"index":0,"delta":{"role":"assistant","content":"REVIEW-FINDING mock reply"},"finish_reason":None}]})
        ev({**base,"choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}})
        self.wfile.write(b'data: [DONE]\n\n')
ThreadingHTTPServer(('127.0.0.1',int(sys.argv[1])),H).serve_forever()
