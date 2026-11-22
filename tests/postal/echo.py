"""The suite's HTTP endpoint for Postal's routes: stores the body of each POST
as <dir>/<n>.body (1, 2, ...) and answers 200. It listens on --bind and
--port (the test host's loopback, which the worker on the host's network
reaches)."""

import argparse
import http.server
import itertools
import os
import threading

parser = argparse.ArgumentParser()
parser.add_argument("--bind", default="127.0.0.1")
parser.add_argument("--port", type=int, default=8090)
parser.add_argument("--dir", required=True)
options = parser.parse_args()
os.makedirs(options.dir, exist_ok=True)
numbers = itertools.count(1)
lock = threading.Lock()


class Echo(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length") or 0))
        with lock:
            number = next(numbers)
        # Written aside and renamed, so that the suite never reads half a body.
        path = os.path.join(options.dir, f"{number}.body")
        with open(path + ".part", "wb") as file:
            file.write(body)
        os.rename(path + ".part", path)
        answer = b"stored\n"
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(answer)))
        self.end_headers()
        self.wfile.write(answer)

    def log_message(self, format, *args):  # noqa: A002 (the base class's name)
        pass


http.server.ThreadingHTTPServer((options.bind, options.port), Echo).serve_forever()
