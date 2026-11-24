"""Unit tests of tests/lib/network_error.py, which tells tests/all.sh whether
a failed entry's log names an upstream network error (and so gets one fresh
rerun). tests/attest/selftest.sh runs them (CI too):

  python3 -I -m unittest discover -s tests/attest -p test_network_error.py -v
"""
import os
import subprocess
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
LIB = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lib")
sys.path.insert(0, LIB)
import network_error as ne  # noqa: E402

N8N_502 = ('Error response from daemon: unknown: failed to resolve reference "docker.n8n.io/n8nio/n8n:2.46.7": '
           'unexpected status from HEAD request to https://docker.n8n.io/v2/n8nio/n8n/manifests/2.46.7: 502 Bad Gateway')
APT_500 = ("E: Failed to fetch http://archive.ubuntu.com/ubuntu/dists/noble-updates/InRelease  "
           "500  Internal Server Error [IP: 91.189.91.83 80]")


class Upstream(unittest.TestCase):
    def match(self, line):
        self.assertIsNotNone(ne.find([line]), line)

    def no_match(self, line):
        self.assertIsNone(ne.find([line]), line)

    def test_apt_cache_policy_priorities(self):
        # The lines of the 2026-11-24 services logs: priorities, not HTTP 500.
        self.no_match("        500 http://archive.ubuntu.com/ubuntu noble-updates/main amd64 Packages")
        self.no_match("        500 https://repo.mysql.com/apt/ubuntu noble/mysql-8.4-lts amd64 Packages")
        self.no_match(" *** 8.4.13.1-1ubuntu24.04 990")

    def test_registry_502(self):
        self.match(N8N_502)

    def test_apt_500(self):
        self.match(APT_500)

    def test_apt_500_in_ansible_json(self):
        self.match('fatal: [testhost]: FAILED! => {"changed": false, "msg": "Failed to update apt cache: '
                   'W:Failed to fetch http://security.ubuntu.com/ubuntu/dists/noble-security/InRelease  '
                   '503  Service Unavailable [IP: 185.125.190.39 80], E:Some index files failed to download."}')

    def test_apt_dns(self):
        self.match("Err:1 http://archive.ubuntu.com/ubuntu noble InRelease Temporary failure resolving "
                   "'archive.ubuntu.com'")
        self.match("W: Failed to fetch http://ppa.launchpadcontent.net/x/InRelease  "
                   "Temporary failure resolving 'ppa.launchpadcontent.net'")

    def test_apt_hash_sum_mismatch(self):
        self.match("E: Failed to fetch https://repo.mysql.com/apt/ubuntu/dists/noble/x.gz  "
                   "Hash Sum mismatch")

    def test_registry_timeouts(self):
        self.match('Get "https://registry-1.docker.io/v2/": net/http: TLS handshake timeout')
        self.match('Get "https://ghcr.io/v2/postalserver/postal/manifests/3.5.0": dial tcp 140.82.121.34:443: '
                   'i/o timeout')
        self.match("read tcp 172.17.0.2:51234->104.16.99.215:443: read: connection reset by peer "
                   "(https://production.cloudflare.docker.com/registry-v2/x)")

    def test_gateway_timeout_spellings(self):
        self.match("Failed to fetch http://archive.ubuntu.com/ubuntu/x  504  Gateway Time-out")
        self.match("received unexpected HTTP status: 504 Gateway Timeout from https://quay.io/v2/x")

    def test_local_hosts_do_not_count(self):
        for url in ("http://graylog.test/api", "http://127.0.0.1:9000/", "http://10.0.0.5/",
                    "http://172.20.0.3:8080/", "http://192.168.1.2/", "http://[::1]:80/",
                    "http://n8n:5678/", "https://x.invalid/", "http://localhost:8080/",
                    "http://mail.example/", "http://host.docker.internal/", "http://box.local/",
                    "http://169.254.169.254/latest"):
            self.no_match(f'"msg": "Status code was 502 Bad Gateway", "url": "{url}"')
            self.no_match(f"unexpected status from GET request to {url}: 502 Bad Gateway")

    def test_phrase_without_host(self):
        self.no_match("read: connection reset by peer")
        self.no_match("502 Bad Gateway")

    def test_host_without_phrase(self):
        self.no_match("Get:1 http://archive.ubuntu.com/ubuntu noble InRelease [256 kB]")
        self.no_match("curl: (22) The requested URL returned error: 404 https://deb.nodesource.com/x")

    def test_quoted_local_host_for_resolving(self):
        self.no_match("Temporary failure resolving 'graylog.test'")
        self.no_match("Temporary failure resolving 'nowhere.invalid'")

    def test_first_match_is_returned_and_cut(self):
        long_line = APT_500 + " x" * 400
        found = ne.find(["ok", long_line, N8N_502])
        self.assertEqual(len(found), 300)
        self.assertTrue(found.startswith("E: Failed to fetch http://archive.ubuntu.com/"))


class Cli(unittest.TestCase):
    def run_cli(self, text):
        with tempfile.NamedTemporaryFile("w", suffix=".log", delete=False) as f:
            f.write(text)
        try:
            return subprocess.run([sys.executable, "-I", os.path.join(LIB, "network_error.py"), f.name],
                                  stdout=subprocess.PIPE, universal_newlines=True)
        finally:
            os.unlink(f.name)

    def test_match(self):
        r = self.run_cli("== a scenario\n" + N8N_502 + "\n")
        self.assertEqual((r.returncode, r.stdout.strip()), (0, N8N_502))

    def test_no_match(self):
        r = self.run_cli("== all fine\n        500 http://archive.ubuntu.com/ubuntu noble/main amd64 Packages\n")
        self.assertEqual((r.returncode, r.stdout), (1, ""))

    def test_undecodable_bytes(self):
        with tempfile.NamedTemporaryFile("wb", suffix=".log", delete=False) as f:
            f.write(b"\xff\xfe garbage\n" + APT_500.encode() + b"\n")
        try:
            r = subprocess.run([sys.executable, "-I", os.path.join(LIB, "network_error.py"), f.name],
                               stdout=subprocess.PIPE, universal_newlines=True)
        finally:
            os.unlink(f.name)
        self.assertEqual(r.returncode, 0)

    def test_missing_log(self):
        r = subprocess.run([sys.executable, "-I", os.path.join(LIB, "network_error.py"), "/nonexistent/x.log"],
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.assertEqual(r.returncode, 2)


if __name__ == "__main__":
    unittest.main()
