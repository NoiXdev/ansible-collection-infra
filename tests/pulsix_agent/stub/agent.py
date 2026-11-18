#!/usr/bin/python3
"""Stand-in for the Pulsix agent in the pulsix_agent role's tests.

Without /etc/pulsix/agent.crt it enrolls: the test token below writes the file,
any other token exits with 2, like the real agent after a refusal. Then it
follows /var/lib/pulsix-stub/mode, which it polls about once a second, so a
scenario can change the mode of a running agent:

  ok             hold a connection to PULSIX_MANAGER_ADDR
  crash          exit 1 two seconds after the mode was seen
  no-connection  run, connect nowhere
  stream-failed  connected, log "agent stream failed" every 3 s
  refused        connected, log the certificate refusal every 3 s
  drop           connect, close the connection after 10 s, keep running

It logs to stderr (the journal).
"""
import os
import socket
import sys
import time

VALID_TOKEN = "pxa1.test-valid"
CERT = "/etc/pulsix/agent.crt"
MODE_FILE = "/var/lib/pulsix-stub/mode"
LINES = {
    "stream-failed": "agent stream failed: stub",
    "refused": "the manager refused this agent's certificate",
}


def log(text):
    print(text, file=sys.stderr, flush=True)


def parse_addr(addr):
    """host:port or [ipv6]:port -> (host, port)."""
    host, _, port = addr.rpartition(":")
    return host.strip("[]"), int(port)


def read_mode():
    try:
        with open(MODE_FILE) as handle:
            return handle.read().strip() or "ok"
    except OSError:
        return "ok"


def enroll():
    if os.path.exists(CERT):
        return
    if os.environ.get("PULSIX_ENROLL_TOKEN", "") != VALID_TOKEN:
        log("enrollment refused")
        sys.exit(2)
    os.makedirs(os.path.dirname(CERT), mode=0o700, exist_ok=True)
    with open(CERT, "w") as handle:
        handle.write("stub certificate\n")
    log("enrolled")


def connect(addr):
    host, port = parse_addr(addr)
    try:
        return socket.create_connection((host, port), timeout=2)
    except OSError as err:
        log("cannot connect to %s: %s" % (addr, err))
        return None


def main():
    enroll()
    addr = os.environ.get("PULSIX_MANAGER_ADDR", "")
    mode = None
    since = time.time()
    conn = None
    connected_at = 0.0
    dropped = False
    last_line = 0.0
    while True:
        new = read_mode()
        if new != mode:
            mode, since, dropped = new, time.time(), False
            log("mode: %s" % mode)
            if mode in ("no-connection", "crash") and conn:
                conn.close()
                conn = None
        now = time.time()
        if mode == "crash":
            if now - since >= 2:
                sys.exit(1)
        elif mode in ("ok", "stream-failed", "refused", "drop"):
            if conn is not None:
                # A closed peer reads as EOF; drop it and connect again.
                conn.setblocking(False)
                try:
                    if conn.recv(1) == b"":
                        conn.close()
                        conn = None
                except BlockingIOError:
                    pass
                except OSError:
                    conn = None
            if conn is None and not dropped:
                conn = connect(addr)
                connected_at = now
            if mode == "drop" and conn is not None and now - connected_at >= 10:
                conn.close()
                conn = None
                dropped = True
            if mode in LINES and conn is not None and now - last_line >= 3:
                log(LINES[mode])
                last_line = now
        time.sleep(1)


if __name__ == "__main__":
    main()
