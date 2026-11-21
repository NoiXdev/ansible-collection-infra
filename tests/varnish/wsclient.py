#!/usr/bin/env python3
"""A WebSocket client for the varnish suite.

    wsclient.py ADDRESS PORT PATH [HEADER: VALUE ...]

Sends the handshake for PATH to ADDRESS:PORT with the headers given (Host
among them), prints the answer's status line and headers, and after a 101
sends one masked text frame "noix-ping" and prints "echo: <payload>" of the
frame that comes back, then closes. Exits 0 when the echo came back, 1
otherwise.
"""

import base64
import os
import socket
import sys


def frame(opcode, payload):
    mask = os.urandom(4)
    masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
    return bytes([0x80 | opcode, 0x80 | len(payload)]) + mask + masked


def read_exactly(conn, size):
    data = b""
    while len(data) < size:
        chunk = conn.recv(size - len(data))
        if not chunk:
            raise EOFError("the connection closed")
        data += chunk
    return data


def main(argv):
    if len(argv) < 4:
        sys.exit("usage: wsclient.py ADDRESS PORT PATH [HEADER: VALUE ...]")
    address, port, path, headers = argv[1], int(argv[2]), argv[3], argv[4:]
    key = base64.b64encode(os.urandom(16)).decode()
    request = [f"GET {path} HTTP/1.1", "Upgrade: websocket", "Connection: Upgrade",
               f"Sec-WebSocket-Key: {key}", "Sec-WebSocket-Version: 13"] + headers
    conn = socket.create_connection((address, port), timeout=10)
    conn.sendall(("\r\n".join(request) + "\r\n\r\n").encode())
    answer = b""
    while b"\r\n\r\n" not in answer:
        chunk = conn.recv(4096)
        if not chunk:
            break
        answer += chunk
    head = answer.split(b"\r\n\r\n", 1)[0].decode(errors="replace")
    print(head.replace("\r\n", "\n"))
    if not head.startswith("HTTP/1.1 101"):
        return 1
    conn.sendall(frame(1, b"noix-ping"))
    first = read_exactly(conn, 2)
    payload = read_exactly(conn, first[1] & 0x7F)
    print("echo: " + payload.decode(errors="replace"))
    conn.sendall(frame(8, b""))
    conn.close()
    return 0 if payload == b"noix-ping" else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
