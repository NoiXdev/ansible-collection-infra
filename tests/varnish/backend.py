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
    vary=    Vary
    status=  the status code (default 200)
    size=    the body is that many bytes: the line above, a newline and digits
    sleep=   seconds to wait before answering
    gzip=    the body is gzipped when the request accepts gzip (Vary:
             Accept-Encoding either way)
    echo=    the name of a request header: its value comes back in X-Echo
             (no X-Echo when the request has no such header)
    inv=     sw-invalidation-states (Shopware's states that make a hit pass)
    bypass=  sw-dynamic-cache-bypass (Shopware's "do not store this")
    esi=1    Surrogate-Control: content="ESI/1.0", and the body is
             "<p><line></p>", a newline and <esi:include src="/frag"/>

A GET with Upgrade: websocket gets the WebSocket handshake (101, with
X-Echo for echo= as above) and then every frame back as it came, until the
client closes.

While the file /tmp/backend-sick exists every request answers 500 "sick"
(counted like the others), GET /health included; otherwise GET /health
answers 200 and is not counted.
"""

import base64
import gzip
import hashlib
import struct
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from os.path import exists
from urllib.parse import parse_qs, urlsplit

SICK = "/tmp/backend-sick"
HEADERS = {
    "cc": "Cache-Control",
    "xkey": "xkey",
    "tags": "X-Cache-Tags",
    "vary": "Vary",
    "inv": "sw-invalidation-states",
    "bypass": "sw-dynamic-cache-bypass",
}

WEBSOCKET_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

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
        host = self.headers.get("Host", "")
        if exists(SICK):
            if url.path != "/health":
                count(host, self.path)
            self.send(500, b"sick\n", [])
            return
        if url.path == "/health" and self.command == "GET":
            self.send(200, b"ok\n", [])
            return
        params = parse_qs(url.query, keep_blank_values=True)
        if self.command == "GET" and "websocket" in self.headers.get("Upgrade", "").lower():
            self.websocket(params)
            return
        line = f"count={count(host, self.path)} host={host} path={self.path}"
        if "sleep" in params:
            time.sleep(float(params["sleep"][-1]))
        status = int(params["status"][-1]) if "status" in params else 200
        body = sized(line, int(params["size"][-1])) if "size" in params else (line + "\n").encode()
        headers = [(name, params[key][-1]) for key, name in HEADERS.items() if key in params]
        if "esi" in params:
            body = f'<p>{line}</p>\n<esi:include src="/frag"/>\n'.encode()
            headers.append(("Surrogate-Control", 'content="ESI/1.0"'))
        headers += [("Set-Cookie", value) for value in params.get("sc", [])]
        if "echo" in params and params["echo"][-1] in self.headers:
            headers.append(("X-Echo", self.headers[params["echo"][-1]]))
        if "gzip" in params:
            headers.append(("Vary", "Accept-Encoding"))
            if "gzip" in self.headers.get("Accept-Encoding", ""):
                body = gzip.compress(body)
                headers.append(("Content-Encoding", "gzip"))
        self.send(status, body, headers)

    def websocket(self, params):
        key = self.headers.get("Sec-WebSocket-Key", "")
        accept = base64.b64encode(hashlib.sha1((key + WEBSOCKET_GUID).encode()).digest()).decode()
        self.send_response(101)
        self.send_header("Upgrade", "websocket")
        self.send_header("Connection", "Upgrade")
        self.send_header("Sec-WebSocket-Accept", accept)
        if "echo" in params and params["echo"][-1] in self.headers:
            self.send_header("X-Echo", self.headers[params["echo"][-1]])
        self.end_headers()
        self.wfile.flush()
        self.close_connection = True
        while True:
            head = self.rfile.read(2)
            if len(head) < 2:
                return
            opcode, length = head[0] & 0x0F, head[1] & 0x7F
            if length == 126:
                length = struct.unpack("!H", self.rfile.read(2))[0]
            elif length == 127:
                length = struct.unpack("!Q", self.rfile.read(8))[0]
            mask = self.rfile.read(4) if head[1] & 0x80 else b"\0\0\0\0"
            payload = bytes(b ^ mask[i % 4] for i, b in enumerate(self.rfile.read(length)))
            self.wfile.write(frame(opcode, payload))
            self.wfile.flush()
            if opcode == 8:
                return

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


def frame(opcode, payload):
    """One unmasked WebSocket frame (a server's)."""
    if len(payload) < 126:
        head = bytes([0x80 | opcode, len(payload)])
    elif len(payload) < 65536:
        head = bytes([0x80 | opcode, 126]) + struct.pack("!H", len(payload))
    else:
        head = bytes([0x80 | opcode, 127]) + struct.pack("!Q", len(payload))
    return head + payload


def main(argv):
    if len(argv) != 4 or argv[1] != "serve":
        sys.exit("usage: backend.py serve ADDRESS PORT")
    ThreadingHTTPServer((argv[2], int(argv[3])), Handler).serve_forever()


if __name__ == "__main__":
    main(sys.argv)
