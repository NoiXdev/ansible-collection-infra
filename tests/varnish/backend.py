#!/usr/bin/env python3
"""The backend of the varnish suite, in place of nginx's inner server.

    backend.py serve ADDRESS PORT

Answers any method and path with the body "count=<n> host=<Host> path=<path>"
(path is the request target with its query; n counts the requests for that
host and path, from 1). Query parameters set the answer:

    cc=      Cache-Control
    sc=      Set-Cookie (one header per sc=)
    xkey=    xkey
    tags=    X-Cache-Tags
    status=  the status code (default 200)
    size=    the body is that many bytes: the line above, a newline and digits
    sleep=   seconds to wait before answering

GET /health answers 200, or 500 while the file /tmp/backend-sick exists.
"""

import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from os.path import exists
from urllib.parse import parse_qs, urlsplit

SICK = "/tmp/backend-sick"
HEADERS = {"cc": "Cache-Control", "xkey": "xkey", "tags": "X-Cache-Tags"}

counts = {}
counts_lock = threading.Lock()


def count(host, path):
    with counts_lock:
        counts[(host, path)] = counts.get((host, path), 0) + 1
        return counts[(host, path)]


def sized(line, size):
    body = (line + "\n").encode()
    filler = b"0123456789" * (size // 10 + 1)
    return (body + filler)[:size]


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def answer(self):
        length = int(self.headers.get("Content-Length") or 0)
        if length:
            self.rfile.read(length)
        url = urlsplit(self.path)
        if url.path == "/health" and self.command == "GET":
            sick = exists(SICK)
            self.send(500 if sick else 200, b"sick\n" if sick else b"ok\n", [])
            return
        params = parse_qs(url.query, keep_blank_values=True)
        host = self.headers.get("Host", "")
        line = f"count={count(host, self.path)} host={host} path={self.path}"
        if "sleep" in params:
            time.sleep(float(params["sleep"][-1]))
        status = int(params["status"][-1]) if "status" in params else 200
        body = sized(line, int(params["size"][-1])) if "size" in params else (line + "\n").encode()
        headers = [(name, params[key][-1]) for key, name in HEADERS.items() if key in params]
        headers += [("Set-Cookie", value) for value in params.get("sc", [])]
        self.send(status, body, headers)

    def send(self, status, body, headers):
        self.send_response(status)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        for name, value in headers:
            self.send_header(name, value)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    # Every method (PURGE and BAN too) gets the same answer.
    def __getattr__(self, name):
        if name.startswith("do_"):
            return self.answer
        raise AttributeError(name)


def main(argv):
    if len(argv) != 4 or argv[1] != "serve":
        sys.exit("usage: backend.py serve ADDRESS PORT")
    ThreadingHTTPServer((argv[2], int(argv[3])), Handler).serve_forever()


if __name__ == "__main__":
    main(sys.argv)
