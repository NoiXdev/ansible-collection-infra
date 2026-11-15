#!/usr/bin/env python3
"""HTTP and WebSocket echo for the nginx tests (stdlib only).

  upstream.py serve ADDRESS PORT
      Answers GET with "node upstream" and the X-Forwarded-* headers it got,
      and echoes the text frames of a WebSocket upgrade.
  upstream.py ws-check ADDRESS PORT SERVER_NAME MESSAGE
      Opens a WebSocket over TLS (SNI SERVER_NAME, no certificate check),
      sends MESSAGE and prints what comes back.
"""
import base64
import hashlib
import http.server
import os
import socket
import ssl
import struct
import sys

GUID = b"258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


def accept_key(key):
    return base64.b64encode(hashlib.sha1(key.encode() + GUID).digest()).decode()


def read_exact(stream, size):
    data = b""
    while len(data) < size:
        chunk = stream.read(size - len(data))
        if not chunk:
            raise EOFError("connection closed")
        data += chunk
    return data


def read_frame(stream):
    first, second = read_exact(stream, 2)
    opcode, masked, size = first & 0x0F, second & 0x80, second & 0x7F
    if size == 126:
        size = struct.unpack("!H", read_exact(stream, 2))[0]
    elif size == 127:
        size = struct.unpack("!Q", read_exact(stream, 8))[0]
    mask = read_exact(stream, 4) if masked else b""
    payload = read_exact(stream, size)
    if masked:
        payload = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
    return opcode, payload


def frame(opcode, payload, mask):
    head = bytes([0x80 | opcode])
    bit = 0x80 if mask else 0
    if len(payload) < 126:
        head += bytes([bit | len(payload)])
    elif len(payload) < 65536:
        head += bytes([bit | 126]) + struct.pack("!H", len(payload))
    else:
        head += bytes([bit | 127]) + struct.pack("!Q", len(payload))
    if not mask:
        return head + payload
    key = os.urandom(4)
    return head + key + bytes(b ^ key[i % 4] for i, b in enumerate(payload))


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self):  # noqa: N802 (the stdlib's name)
        if self.headers.get("Upgrade", "").lower() == "websocket":
            self.send_response(101, "Switching Protocols")
            self.send_header("Upgrade", "websocket")
            self.send_header("Connection", "Upgrade")
            self.send_header("Sec-WebSocket-Accept", accept_key(self.headers["Sec-WebSocket-Key"]))
            self.end_headers()
            self.wfile.flush()
            self.close_connection = True
            while True:
                try:
                    opcode, payload = read_frame(self.rfile)
                except EOFError:
                    return
                if opcode == 0x8:
                    self.wfile.write(frame(0x8, b"", False))
                    return
                if opcode == 0x1:
                    self.wfile.write(frame(0x1, payload, False))
                    self.wfile.flush()
        body = "node upstream\n" + "".join(
            f"{name}: {self.headers.get(name, '')}\n"
            for name in ("Host", "X-Forwarded-For", "X-Forwarded-Proto", "X-Forwarded-Host")
        )
        data = body.encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        pass


def ws_check(address, port, server_name, message):
    context = ssl.create_default_context()
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE
    raw = socket.create_connection((address, int(port)), timeout=10)
    sock = context.wrap_socket(raw, server_hostname=server_name)
    key = base64.b64encode(os.urandom(16)).decode()
    sock.sendall(
        (
            "GET /ws HTTP/1.1\r\n"
            f"Host: {server_name}\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            f"Sec-WebSocket-Key: {key}\r\n"
            "Sec-WebSocket-Version: 13\r\n\r\n"
        ).encode()
    )
    stream = sock.makefile("rb")
    status = stream.readline().decode().strip()
    headers = {}
    while True:
        line = stream.readline().decode().strip()
        if not line:
            break
        name, _, value = line.partition(":")
        headers[name.strip().lower()] = value.strip()
    if not status.startswith("HTTP/1.1 101"):
        sys.exit(f"no upgrade: {status}")
    if headers.get("sec-websocket-accept") != accept_key(key):
        sys.exit("wrong Sec-WebSocket-Accept")
    sock.sendall(frame(0x1, message.encode(), True))
    opcode, payload = read_frame(stream)
    if opcode != 0x1:
        sys.exit(f"unexpected opcode {opcode}")
    print(payload.decode())
    sock.sendall(frame(0x8, b"", True))


def main():
    if sys.argv[1:2] == ["serve"] and len(sys.argv) == 4:
        server = http.server.ThreadingHTTPServer((sys.argv[2], int(sys.argv[3])), Handler)
        server.serve_forever()
    elif sys.argv[1:2] == ["ws-check"] and len(sys.argv) == 6:
        ws_check(*sys.argv[2:])
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
