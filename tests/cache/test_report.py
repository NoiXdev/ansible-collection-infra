"""Unit tests of tests/cache/report.py, the check mode of the tests' caching
stack (tests/cache.sh report):

  python3 -I -m unittest discover -s tests/cache -p 'test_*.py'
"""
import os
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
REPORT = os.path.join(HERE, "report.py")
FIX = os.path.join(HERE, "fixtures")
# 2026-11-26 07:50:00 UTC: after the fixtures' "old" lines, before the rest.
SINCE = str(int(datetime(2026, 11, 26, 7, 50, tzinfo=timezone.utc).timestamp()))
FIRST = "test cache report (a lower bound: resolvers a role or suite brings itself are not seen)"


def run(dns=None, apt=None, hub=None, since=SINCE):
    args = [sys.executable, "-I", REPORT, "--since", since,
            "--dns", dns or os.path.join(FIX, "dns.log"),
            "--apt", apt or os.path.join(FIX, "apt.log"),
            "--hub", hub or os.path.join(FIX, "hub.log")]
    r = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True)
    return r.returncode, r.stdout.splitlines()


class Report(unittest.TestCase):
    def test_direct_names_counted_and_sorted(self):
        rc, out = run()
        self.assertEqual(rc, 0)
        self.assertEqual(out[0], FIRST)
        direct = out[out.index("direct:") + 1:out.index("apt:")]
        # Names fold case and the root dot; A and AAAA queries both count.
        self.assertEqual(direct, ["  4 download.docker.com", "  1 ghcr.io"])
        self.assertEqual(out[-1], "verdict: 2 names went direct (top: download.docker.com, ghcr.io)")

    def test_since_filters(self):
        _, out = run()
        self.assertFalse(any("old.example.com" in line for line in out))
        _, everything = run(since="0")
        self.assertTrue(any("old.example.com" in line for line in everything))

    def test_apt_hits_and_misses(self):
        _, out = run(since="0")
        apt = out[out.index("apt:") + 1:out.index("hub:")]
        self.assertIn("  requests: 4, hits: 2, misses: 2", apt)
        self.assertIn("  bytes to the hosts: 7500, from upstream: 3500", apt)

    def test_hub_rate_limit_and_5xx(self):
        _, out = run()
        hub = out[out.index("hub:") + 1:-1]
        self.assertIn("  manifest requests: 4, blob requests: 1, fetched from Docker Hub: 1", hub)
        self.assertIn("  rate limited (429): 1, server errors (5xx): 1", hub)

    def test_missing_logs_report_zeros(self):
        with tempfile.TemporaryDirectory() as d:
            missing = os.path.join(d, "none.log")
            rc, out = run(dns=missing, apt=missing, hub=missing)
        self.assertEqual(rc, 0)
        self.assertEqual(out[0], FIRST)
        self.assertIn("  requests: 0, hits: 0, misses: 0", out)
        self.assertIn("  manifest requests: 0, blob requests: 0, fetched from Docker Hub: 0", out)
        self.assertEqual(out[-1], "verdict: 0 names went direct")


if __name__ == "__main__":
    unittest.main()
