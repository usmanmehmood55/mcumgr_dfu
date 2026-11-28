"""Serve the Chrome harness build and append posted evidence lines to a file.

Usage (from hil/): python3 tool/serve_harness.py PORT EVIDENCE_JSONL [CANDIDATE_JSON]
Open http://127.0.0.1:PORT/?case=probe&side=left&factory=ID&write=128,244&pipeline=1,4
"""
import json
import sys
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

port, evidence = int(sys.argv[1]), Path(sys.argv[2]).resolve()
candidate = json.loads(Path(sys.argv[3]).read_text())["image"] if len(sys.argv) > 3 else None
root = Path(__file__).resolve().parent.parent / "chrome" / "build" / "web"


class Handler(SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(root), **kwargs)

    def log_message(self, *args):
        pass

    def end_headers(self):
        self.send_header("Cache-Control", "no-store")
        super().end_headers()

    def do_GET(self):
        if candidate and self.path in ("/candidate.json", "/candidate.bin"):
            body = json.dumps(candidate).encode() if self.path.endswith("json") else Path(candidate["path"]).read_bytes()
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            super().do_GET()

    def do_POST(self):
        if self.path != "/evidence":
            self.send_error(404)
            return
        data = self.rfile.read(min(65536, int(self.headers["Content-Length"])))
        with evidence.open("ab") as output:
            output.write(data + b"\n")
        self.send_response(204)
        self.end_headers()


ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
