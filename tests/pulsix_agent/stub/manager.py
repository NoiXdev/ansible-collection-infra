#!/usr/bin/python3
"""Stand-in for the Pulsix manager's agent endpoint: accepts TCP connections on
127.0.0.1:18444 and [::1]:18444 and holds them open until the peer closes."""
import socket
import threading

PORT = 18444


def hold(conn):
    try:
        while conn.recv(4096):
            pass
    except OSError:
        pass
    finally:
        conn.close()


def serve(family, host):
    sock = socket.socket(family, socket.SOCK_STREAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    if family == socket.AF_INET6:
        sock.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
    sock.bind((host, PORT))
    sock.listen(16)
    while True:
        conn, _ = sock.accept()
        threading.Thread(target=hold, args=(conn,), daemon=True).start()


if __name__ == "__main__":
    # Bind both before serving, so a missing IPv6 loopback fails loudly.
    v6 = threading.Thread(target=serve, args=(socket.AF_INET6, "::1"), daemon=True)
    v6.start()
    serve(socket.AF_INET, "127.0.0.1")
