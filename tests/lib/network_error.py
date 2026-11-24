#!/usr/bin/env python3
"""Whether a suite's log names an upstream network error: a mirror's or a
registry's 5xx, a DNS failure or a timeout on the way to a host on the
internet. tests/all.sh asks it about the log of an entry that failed, and runs
such an entry once more from scratch (only the second run counts). Standard
library only, Python 3.9 or later, run as `python3 -I`.

  network_error.py LOG

Prints the first matching line (stripped, at most 300 characters) and exits
0; exits 1 when no line matches, 2 when LOG cannot be read.

A line matches when it has a transient phrase (an HTTP 5xx with its reason,
a registry's unexpected 5xx status, "Temporary failure resolving", "Could not
resolve host", "TLS handshake timeout", "i/o timeout", "connection reset by
peer", "Connection timed out", "Hash Sum mismatch") AND names an upstream host
in the same line: in a URL, or as apt's or curl's host that did not resolve.
A host is upstream unless it is a single label (a container or "localhost"),
an IP that is not global (loopback, private, link-local), or under .test,
.invalid, .local, .localhost, .internal or .example, the names the suites use
for their own services. apt-cache policy's "500 http://..." (a priority) has
no reason phrase, so it does not match.
"""
import ipaddress
import re
import sys
from typing import Iterable, Optional

MAX_LINE = 300
LOCAL_SUFFIXES = (".test", ".invalid", ".local", ".localhost", ".internal", ".example")

PHRASE_RE = re.compile(
    r"\b5\d\d\s+(?:Internal Server Error|Bad Gateway|Service Unavailable|Gateway Time-?out)\b"
    r"|unexpected status from (?:HEAD|GET) request to \S+: 5\d\d\b"
    r"|received unexpected HTTP status: 5\d\d\b"
    r"|Temporary failure resolving|Could not resolve host|TLS handshake timeout|i/o timeout"
    r"|connection reset by peer|Connection timed out|Hash Sum mismatch")
URL_HOST_RE = re.compile(r"\bhttps?://(?:[^/\s\"'@]*@)?(\[[0-9A-Fa-f:.]+\]|[^/\s\"'\]\[)(>:,;]+)")
NAMED_HOST_RE = re.compile(r"(?:Temporary failure resolving|Could not resolve host:?) '?([^'\s;,)\"]+)")


def upstream(host: str) -> bool:
    """Whether host is on the internet rather than one of the tests' own."""
    host = host.strip("[]").rstrip(".").lower()
    try:
        return ipaddress.ip_address(host).is_global
    except ValueError:
        pass
    if "." not in host:
        return False
    return not host.endswith(LOCAL_SUFFIXES)


def find(lines: Iterable[str]) -> Optional[str]:
    """The first line with a transient phrase and an upstream host, or None."""
    for line in lines:
        if not PHRASE_RE.search(line):
            continue
        hosts = URL_HOST_RE.findall(line) + NAMED_HOST_RE.findall(line)
        if any(upstream(h) for h in hosts):
            return line.strip()[:MAX_LINE]
    return None


def main(argv) -> int:
    if len(argv) != 2:
        print("usage: network_error.py LOG", file=sys.stderr)
        return 2
    try:
        with open(argv[1], encoding="utf-8", errors="replace") as f:
            found = find(f)
    except OSError as e:
        print(f"network_error.py: cannot read {argv[1]}: {e.strerror}", file=sys.stderr)
        return 2
    if found is None:
        return 1
    print(found)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
