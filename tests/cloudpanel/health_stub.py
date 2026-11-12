"""Health check stub for tests/cloudpanel/run.sh.

Answers GET /status/<code> with that HTTP status code, on 127.0.0.1 and the
port given as the only argument. The role requests it from the Ansible
controller, as it does with real health URLs.
"""

import http.server
import sys


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):  # noqa: N802 (http.server API)
        parts = self.path.strip("/").split("/")
        code = int(parts[1]) if len(parts) == 2 and parts[0] == "status" and parts[1].isdigit() else 404
        body = f"stub {code}\n".encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
