#!/usr/bin/env python3
"""The check mode of the tests' caching stack (tests/cache.sh report): what
went past the caches since a time, from the logging resolver's queries, and
how the apt cache and the Docker Hub proxy did. Standard library only, run as
`python3 -I`.

  report.py --dns FILE --apt FILE --hub FILE --since EPOCH

A missing file counts as empty. It only reports; it always exits 0 unless its
arguments are wrong. A lower bound: a resolver that a role or a suite brings
itself (the dns role's CoreDNS forwards to public resolvers) is not seen.
"""
import argparse
import re
from collections import Counter
from datetime import datetime, timezone

FIRST = "test cache report (a lower bound: resolvers a role or suite brings itself are not seen)"

DNS_RE = re.compile(r"^(\w{3}) +(\d+) (\d\d:\d\d:\d\d) dnsmasq\[\d+\]: query\[[A-Za-z0-9]+\] (\S+) from \S+$")
ACCESS_RE = re.compile(r'^\S+ - \S+ \[([^\]]+)\] "(\w+) (\S+) HTTP/[\d.]+" (\d{3}) ')
UPSTREAM_RE = re.compile(r'^time="([^"]+)".*msg="Adding new scheduler entry')


def lines(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.read().splitlines()
    except OSError:
        return []


def dns_time(month, day, clock, now):
    """dnsmasq logs no year: the latest year that does not lie in the future."""
    for year in (now.year, now.year - 1):
        t = datetime.strptime(f"{year} {month} {day} {clock}", "%Y %b %d %H:%M:%S").replace(tzinfo=timezone.utc)
        if t.timestamp() <= now.timestamp() + 86400:
            return t.timestamp()
    return 0


def direct_names(path, since, now):
    counts = Counter()
    for line in lines(path):
        m = DNS_RE.match(line)
        if m and dns_time(m.group(1), m.group(2), m.group(3), now) >= since:
            counts[m.group(4).rstrip(".").lower()] += 1
    return counts


def apt_stats(path, since):
    """(requests, misses, bytes to the hosts, bytes from upstream): apt-cacher-ng
    logs an O line per file it sends and an I line per file it fetched."""
    sent = fetched = sent_bytes = fetched_bytes = 0
    for line in lines(path):
        parts = line.split("|")
        if len(parts) < 5 or not parts[0].isdigit() or not parts[2].isdigit() or int(parts[0]) < since:
            continue
        if parts[1] == "O":
            sent += 1
            sent_bytes += int(parts[2])
        elif parts[1] == "I":
            fetched += 1
            fetched_bytes += int(parts[2])
    return sent, fetched, sent_bytes, fetched_bytes


def hub_stats(path, since):
    manifests = blobs = upstream = limited = errors = 0
    for line in lines(path):
        m = ACCESS_RE.match(line)
        if m:
            try:
                t = datetime.strptime(m.group(1), "%d/%b/%Y:%H:%M:%S %z").timestamp()
            except ValueError:
                continue
            if t < since:
                continue
            uri, status = m.group(3), int(m.group(4))
            if "/manifests/" in uri:
                manifests += 1
            elif "/blobs/" in uri:
                blobs += 1
            if status == 429:
                limited += 1
            elif status >= 500:
                errors += 1
            continue
        m = UPSTREAM_RE.match(line)
        if m:
            stamp = re.sub(r"(\.\d+)?Z$", "+00:00", m.group(1))
            try:
                t = datetime.fromisoformat(stamp).timestamp()
            except ValueError:
                continue
            if t >= since:
                upstream += 1
    return manifests, blobs, upstream, limited, errors


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dns", required=True)
    ap.add_argument("--apt", required=True)
    ap.add_argument("--hub", required=True)
    ap.add_argument("--since", required=True, type=float)
    a = ap.parse_args()
    now = datetime.now(timezone.utc)

    direct = direct_names(a.dns, a.since, now)
    ranked = sorted(direct.items(), key=lambda kv: (-kv[1], kv[0]))
    sent, fetched, sent_bytes, fetched_bytes = apt_stats(a.apt, a.since)
    manifests, blobs, upstream, limited, errors = hub_stats(a.hub, a.since)

    print(FIRST)
    print("direct:")
    for name, count in ranked:
        print(f"  {count} {name}")
    print("apt:")
    print(f"  requests: {sent}, hits: {max(sent - fetched, 0)}, misses: {fetched}")
    print(f"  bytes to the hosts: {sent_bytes}, from upstream: {fetched_bytes}")
    print("hub:")
    print(f"  manifest requests: {manifests}, blob requests: {blobs}, fetched from Docker Hub: {upstream}")
    print(f"  rate limited (429): {limited}, server errors (5xx): {errors}")
    verdict = f"verdict: {len(ranked)} names went direct"
    if ranked:
        verdict += " (top: " + ", ".join(name for name, _ in ranked[:3]) + ")"
    print(verdict)


if __name__ == "__main__":
    main()
