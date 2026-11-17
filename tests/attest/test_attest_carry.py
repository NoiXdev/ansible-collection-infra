"""Unit tests of .github/scripts/attest_carry.py, the shared helper of
tests/attest.sh and .github/scripts/verify-tests-attestation.sh.
tests/attest/selftest.sh runs them (CI too):

  python3 -I -m unittest discover -s tests/attest -p test_attest_carry.py -v
"""
import os
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime, timezone

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", ".github", "scripts"))
import attest_carry as ac  # noqa: E402

MAP = """\
# A comment line.
[ignore]
CHANGELOG.md
roles/*/README.md   # ignore wins over the suite

[shared]
plugins/
tests/all.sh

[suite e2e]
tests/run.sh
roles/traefik/
roles/docker_check/

[suite tandoor]
tests/tandoor/
roles/tandoor/
roles/traefik/
roles/docker_check/

[suite n8n]
roles/n8n/
"""

ALLSH = """\
#!/usr/bin/env bash
all_suites=(e2e host services tandoor)
host_releases=(24.04 26.04)
services_releases=(24.04 26.04)
"""


def iso(epoch):
    return datetime.fromtimestamp(epoch, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


class ParseMap(unittest.TestCase):
    def test_sections_and_comments(self):
        m = ac.parse_map(MAP)
        self.assertEqual(m["ignore"], ["CHANGELOG.md", "roles/*/README.md"])
        self.assertEqual(m["shared"], ["plugins/", "tests/all.sh"])
        self.assertEqual(list(m["suites"]), ["e2e", "tandoor", "n8n"])
        self.assertEqual(m["suites"]["e2e"], ["tests/run.sh", "roles/traefik/", "roles/docker_check/"])

    def test_pattern_outside_a_section(self):
        with self.assertRaisesRegex(ValueError, "line 2"):
            ac.parse_map("# head\nroles/x/\n[shared]\n")

    def test_unknown_header(self):
        with self.assertRaisesRegex(ValueError, "line 3"):
            ac.parse_map("[shared]\nplugins/\n[suites e2e]\n")

    def test_duplicate_suite(self):
        with self.assertRaisesRegex(ValueError, "line 5"):
            ac.parse_map("[suite a]\nx\n[suite b]\ny\n[suite a]\nz\n")


class Matches(unittest.TestCase):
    def test_prefix(self):
        self.assertTrue(ac.matches("roles/n8n/tasks/main.yml", "roles/n8n/"))

    def test_prefix_of_a_sibling(self):
        self.assertFalse(ac.matches("roles/n8n2/x", "roles/n8n/"))

    def test_glob(self):
        self.assertTrue(ac.matches("roles/php/README.md", "roles/*/README.md"))
        self.assertFalse(ac.matches("roles/php/README.txt", "roles/*/README.md"))

    def test_ignore_glob_stops_at_slash(self):
        self.assertTrue(ac.ignore_matches("roles/php/README.md", "roles/*/README.md"))
        self.assertFalse(ac.ignore_matches("roles/x/templates/README.md", "roles/*/README.md"))
        self.assertTrue(ac.ignore_matches(".github/workflows/ci.yml", ".github/workflows/"))

    def test_exact(self):
        self.assertTrue(ac.matches("tests/run.sh", "tests/run.sh"))
        self.assertFalse(ac.matches("tests/run.shx", "tests/run.sh"))


class AffectedSuites(unittest.TestCase):
    def setUp(self):
        self.m = ac.parse_map(MAP)

    def test_role_file_gives_that_suite(self):
        self.assertEqual(ac.affected_suites(self.m, ["roles/n8n/tasks/main.yml"]), {"n8n"})

    def test_shared_gives_all(self):
        self.assertEqual(ac.affected_suites(self.m, ["plugins/x.py"]), "ALL")

    def test_unmatched_gives_all(self):
        self.assertEqual(ac.affected_suites(self.m, ["foo/bar"]), "ALL")

    def test_ignored_alone_gives_none(self):
        self.assertEqual(ac.affected_suites(self.m, ["CHANGELOG.md"]), set())

    def test_ignore_wins(self):
        self.assertEqual(ac.affected_suites(self.m, ["roles/tandoor/README.md"]), set())

    def test_nested_readme_is_not_ignored(self):
        self.assertEqual(ac.affected_suites(self.m, ["roles/tandoor/templates/README.md"]), {"tandoor"})

    def test_ignore_wins_over_shared(self):
        m = ac.parse_map("[ignore]\nNOTES.md\n[shared]\nNOTES.md\n[suite a]\nNOTES.md\n")
        self.assertEqual(ac.affected_suites(m, ["NOTES.md"]), set())

    def test_file_in_two_suites(self):
        self.assertEqual(ac.affected_suites(self.m, ["roles/traefik/defaults/main.yml"]), {"e2e", "tandoor"})

    def test_union_over_files(self):
        self.assertEqual(ac.affected_suites(self.m, ["CHANGELOG.md", "roles/n8n/x", "tests/run.sh"]),
                         {"n8n", "e2e"})

    def test_nothing_changed(self):
        self.assertEqual(ac.affected_suites(self.m, []), set())


class Rename(unittest.TestCase):
    """Review Focus 1: a file renamed out of a suite's path still reruns it."""

    def git(self, *args):
        env = dict(os.environ, GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_NOSYSTEM="1",
                   GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@example.com",
                   GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@example.com")
        return subprocess.run(["git", "-C", self.repo] + list(args), check=True, env=env,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              universal_newlines=True).stdout.strip()

    def test_git_mv_out_of_a_role(self):
        with tempfile.TemporaryDirectory() as self.repo:
            self.git("init", "-q")
            os.makedirs(os.path.join(self.repo, "roles", "a"))
            with open(os.path.join(self.repo, "roles", "a", "x"), "w") as f:
                f.write("a long enough line so that git sees a rename\n" * 5)
            self.git("add", "-A")
            self.git("commit", "-q", "-m", "one")
            before = self.git("rev-parse", "HEAD")
            os.makedirs(os.path.join(self.repo, "tmp"))
            self.git("mv", "roles/a/x", "tmp/x")
            self.git("commit", "-q", "-m", "two")
            changed = ac.changed_files(self.repo, before, "HEAD")
            self.assertIn("roles/a/x", changed)
            self.assertIn("tmp/x", changed)
            m = ac.parse_map("[suite a]\nroles/a/\n")
            self.assertEqual(ac.affected_suites(m, changed), "ALL")


class ExpectedEntries(unittest.TestCase):
    def test_entries(self):
        self.assertEqual(ac.expected_entries(ALLSH), [
            ("e2e", "e2e"),
            ("host-24.04", "host"), ("host-26.04", "host"),
            ("services-24.04", "services"), ("services-26.04", "services"),
            ("tandoor", "tandoor"),
        ])

    def test_missing_array(self):
        with self.assertRaises(ValueError):
            ac.expected_entries("all_suites=(e2e host)\n")

    def test_two_lines(self):
        with self.assertRaises(ValueError):
            ac.expected_entries("all_suites=(e2e)\nall_suites=(e2e)\n")

    def test_malformed(self):
        with self.assertRaises(ValueError):
            ac.expected_entries("all_suites=(e2e b@d)\n")
        with self.assertRaises(ValueError):
            ac.expected_entries("all_suites=()\n")


class CheckMap(unittest.TestCase):
    ALL = "all_suites=(e2e tandoor n8n)\n"

    def test_clean(self):
        self.assertEqual(ac.check_map(ac.parse_map(MAP), self.ALL, ["traefik", "tandoor", "n8n", "docker_check"]), [])

    def test_missing_section(self):
        errors = ac.check_map(ac.parse_map(MAP), "all_suites=(e2e tandoor n8n harbor)\n", [])
        self.assertTrue(any("harbor" in e for e in errors), errors)

    def test_extra_section(self):
        errors = ac.check_map(ac.parse_map(MAP), "all_suites=(e2e tandoor)\n", [])
        self.assertTrue(any("n8n" in e for e in errors), errors)

    def test_unmapped_role(self):
        errors = ac.check_map(ac.parse_map(MAP), self.ALL, ["n8n", "zzz"])
        self.assertEqual(len(errors), 1, errors)
        self.assertIn("roles/zzz/", errors[0])

    def test_role_only_by_glob_is_unmapped(self):
        m = ac.parse_map(MAP + "roles/zz*/\n")
        errors = ac.check_map(m, self.ALL, ["zzz"])
        self.assertTrue(any("roles/zzz/" in e for e in errors), errors)

    def test_broad_ignore(self):
        for pattern in ["roles/tandoor/tasks/", "*.md", ".github/", ".github/scripts/x.sh",
                        ".github/*", "tests/README.md", "roles/tandoor/README.md"]:
            m = ac.parse_map(MAP.replace("CHANGELOG.md\n", "CHANGELOG.md\n" + pattern + "\n"))
            errors = ac.check_map(m, self.ALL, [])
            self.assertTrue(any(pattern in e and "ignore" in e for e in errors), (pattern, errors))

    def test_narrow_ignore(self):
        allowed = "README.md\nLICENSE\n.ansible-lint\n.yamllint\n.gitignore\n.github/workflows/\n" \
                  ".github/pull_request_template.md\n.github/ISSUE_TEMPLATE/\n"
        m = ac.parse_map(MAP.replace("CHANGELOG.md\n", "CHANGELOG.md\n" + allowed))
        self.assertEqual(ac.check_map(m, self.ALL, []), [])


class CheckMapDependencies(unittest.TestCase):
    """A suite lists every role its roles and its test files reference, transitively."""
    ALL = "all_suites=(a b)\n"
    MAP = "[suite a]\ntests/a/\nroles/nginx/\n[suite b]\nroles/php/\nroles/redis/\n"
    FILES = {
        "roles/nginx/tasks/main.yml": "- ansible.builtin.include_role:\n    name: noixdev.infra.php\n"
                                      "- noixdev.infra.warn:\n    msg: x\n",
        "roles/php/meta/main.yml": "dependencies:\n  - role: noixdev.infra.redis\n",
        "roles/redis/tasks/main.yml": "# Written by the noixdev.infra.redis role\n",
        "tests/a/converge.yml": "- hosts: all\n  roles: [noixdev.infra.nginx]\n",
    }
    ROLES = ["nginx", "php", "redis"]

    def errors(self, map_text, files):
        return ac.check_map(ac.parse_map(map_text), self.ALL, self.ROLES, files)

    def test_missing_include_role_dependency(self):
        errors = self.errors(self.MAP, self.FILES)
        self.assertTrue(any("[suite a]" in e and "roles/php/" in e and "roles/nginx/tasks/main.yml" in e
                            for e in errors), errors)

    def test_missing_transitive_dependency(self):
        errors = self.errors(self.MAP.replace("roles/nginx/\n", "roles/nginx/\nroles/php/\n", 1), self.FILES)
        self.assertEqual(len(errors), 1, errors)
        self.assertIn("[suite a]", errors[0])
        self.assertIn("roles/redis/", errors[0])
        self.assertIn("roles/php/meta/main.yml", errors[0])

    def test_complete(self):
        m = self.MAP.replace("roles/nginx/\n", "roles/nginx/\nroles/php/\nroles/redis/\n", 1)
        self.assertEqual(self.errors(m, self.FILES), [])

    def test_test_file_reference(self):
        files = dict(self.FILES, **{"tests/a/verify.yml": "- noixdev.infra.redis\n"})
        m = self.MAP.replace("roles/nginx/\n", "roles/nginx/\nroles/php/\n", 1)
        errors = self.errors(m, files)
        self.assertTrue(any("tests/a/verify.yml" in e and "roles/redis/" in e for e in errors), errors)

    def test_test_file_outside_the_section_does_not_count(self):
        files = {"tests/b/converge.yml": "- noixdev.infra.nginx\n"}
        self.assertEqual(self.errors("[suite a]\nroles/nginx/\nroles/php/\nroles/redis/\n[suite b]\nroles/php/\n"
                                     "roles/redis/\n", files), [])

    def test_cli_on_a_repository(self):
        with tempfile.TemporaryDirectory() as repo:
            env = dict(os.environ, GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_NOSYSTEM="1",
                       GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@example.com",
                       GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@example.com")
            files = dict(self.FILES, **{"tests/all.sh": self.ALL, "tests/suites.conf": self.MAP})
            for path, text in files.items():
                os.makedirs(os.path.join(repo, os.path.dirname(path)), exist_ok=True)
                with open(os.path.join(repo, path), "w") as f:
                    f.write(text)
            for args in (["init", "-q"], ["add", "-A"], ["commit", "-q", "-m", "x"]):
                subprocess.run(["git", "-C", repo] + args, check=True, env=env, stdout=subprocess.DEVNULL)
            r = subprocess.run([sys.executable, "-I", ac.__file__, "check-map", "--repo", repo, "--commit", "HEAD"],
                               stdout=subprocess.PIPE, universal_newlines=True, env=env)
            self.assertEqual(r.returncode, 1, r.stdout)
            self.assertIn("::error::[suite a] lacks roles/php/", r.stdout)
            self.assertIn("roles/nginx/tasks/main.yml", r.stdout)


class Payload(unittest.TestCase):
    C = "a" * 40
    T = "b" * 40

    def payload(self, **kw):
        p = {"schema": 2, "commit": self.C, "tree": self.T, "signer": "m@example.com",
             "suites": [{"label": "e2e", "result": "pass", "seconds": 3}],
             "carried": [{"label": "n8n", "carriedFrom": "c" * 40}],
             "passed": 1, "failed": 0, "carriedCount": 1, "arch": "arm64", "os": "Darwin",
             "docker": "29.0.0", "startedAt": "2026-11-01T10:00:00Z", "finishedAt": "2026-11-01T11:00:00Z"}
        p.update(kw)
        return p

    def test_valid(self):
        ac.check_payload(self.payload(), self.C, self.T, False)
        p1 = self.payload(schema=1)
        del p1["carried"], p1["carriedCount"]
        ac.check_payload(p1, self.C, self.T, False)

    def test_refusals(self):
        cases = {
            "schema": self.payload(schema=3),
            "schema True": self.payload(schema=True),
            "dry run": self.payload(dryRun=True),
            "commit": self.payload(commit="d" * 40),
            "tree": self.payload(tree="d" * 40),
            "suites": self.payload(suites=[{"label": "e2e"}]),
            "carried": self.payload(carried=[{"label": "n8n"}]),
            "docker unknown": self.payload(docker="unknown"),
            "docker missing": self.payload(docker=None),
            "duplicate": self.payload(carried=[{"label": "e2e", "carriedFrom": "c" * 40}]),
        }
        for name, p in cases.items():
            with self.assertRaises(ac.NoteError, msg=name):
                ac.check_payload(p, self.C, self.T, False)

    def test_dry_run_allowed(self):
        ac.check_payload(self.payload(dryRun=True, docker="unknown"), self.C, self.T, True)

    def test_nothing_ran_needs_no_docker(self):
        ac.check_payload(self.payload(suites=[], passed=0, docker="none"), self.C, self.T, False)

    def test_ran_entries(self):
        self.assertEqual(list(ac.ran_entries(self.payload())), ["e2e"])
        p1 = self.payload(schema=1)
        del p1["carried"]
        self.assertEqual(ac.ran_entries(p1)["e2e"]["result"], "pass")


class AgeSeconds(unittest.TestCase):
    NOW = 1800000000

    def test_age(self):
        self.assertEqual(ac.age_seconds({"finishedAt": iso(self.NOW - 3600)}, self.NOW), 3600)

    def test_two_days_in_the_future(self):
        """Review Focus 2: refused, not read as 0 days old."""
        with self.assertRaisesRegex(ac.NoteError, "future"):
            ac.age_seconds({"finishedAt": iso(self.NOW + 2 * 86400)}, self.NOW)

    def test_small_skew_is_tolerated(self):
        self.assertEqual(ac.age_seconds({"finishedAt": iso(self.NOW + 60)}, self.NOW), -60)

    def test_malformed(self):
        for value in [None, "yesterday", "2026-11-01 11:00:00"]:
            with self.assertRaises(ac.NoteError):
                ac.age_seconds({"finishedAt": value}, self.NOW)


class BuildPayload(unittest.TestCase):
    PLAN = [
        {"label": "e2e", "suite": "e2e", "action": "run", "reason": "x"},
        {"label": "services-24.04", "suite": "services", "action": "run", "reason": "x"},
        {"label": "services-26.04", "suite": "services", "action": "run", "reason": "x"},
        {"label": "n8n", "suite": "n8n", "action": "carry", "carriedFrom": "c" * 40, "reason": "x"},
    ]

    def build(self, summary, plan=None, docker="29.0.0", dry_run=False):
        return ac.build_payload(plan or self.PLAN, summary, "a" * 40, "b" * 40, "m@example.com", "arm64",
                                "Darwin", docker, "2026-11-01T10:00:00Z", "2026-11-01T11:00:00Z", dry_run)

    def test_green(self):
        p = self.build("e2e pass 3\nservices-24.04 pass 5 mysql_via_systemctl_shim\nservices-26.04 pass 4\n")
        self.assertEqual(list(p), ["schema", "commit", "tree", "signer", "suites", "carried", "passed", "failed",
                                   "carriedCount", "arch", "os", "docker", "startedAt", "finishedAt"])
        self.assertEqual(p["schema"], 2)
        self.assertEqual(p["suites"][1], {"label": "services-24.04", "result": "pass", "seconds": 5,
                                          "notes": ["mysql via systemctl shim"]})
        self.assertNotIn("notes", p["suites"][0])
        self.assertEqual(p["carried"], [{"label": "n8n", "carriedFrom": "c" * 40}])
        self.assertEqual((p["passed"], p["failed"], p["carriedCount"]), (3, 0, 1))
        ac.check_payload(p, "a" * 40, "b" * 40, False)

    def test_missing_and_failed(self):
        p = self.build("e2e fail 3\nservices-24.04 pass 5\n")
        self.assertEqual((p["passed"], p["failed"]), (1, 2))

    def test_nothing_ran(self):
        plan = [dict(e, action="carry", carriedFrom="c" * 40) for e in self.PLAN]
        p = self.build("", plan=plan, docker="unknown", dry_run=True)
        self.assertEqual(p["docker"], "none")
        self.assertIs(p["dryRun"], True)
        self.assertEqual((p["suites"], p["passed"], p["failed"], p["carriedCount"]), ([], 0, 0, 4))

    def test_bad_summary(self):
        for summary in ["e2e maybe 3\n", "n8n pass 3\n", "e2e pass 3\ne2e pass 3\n", "bogus pass 1\n"]:
            with self.assertRaises(ValueError, msg=summary):
                self.build(summary)


class ReleaseCheck(unittest.TestCase):
    """verify_release itself runs in tests/attest/selftest.sh (section 15)."""

    def test_signature_error_is_a_note_error(self):
        e = ac.SignatureError("does not verify", "m@example.com")
        self.assertIsInstance(e, ac.NoteError)
        self.assertEqual((e.message, e.signer), ("does not verify", "m@example.com"))

    def test_days_round_up(self):
        self.assertEqual([ac._days(a) for a in (1, 86400, 86401, 31 * 86400)], [1, 1, 2, 31])


class Constants(unittest.TestCase):
    def test_values(self):
        self.assertEqual((ac.MAX_AGE_DAYS, ac.CARRY_MARGIN_DAYS, ac.FUTURE_TOLERANCE_SECONDS, ac.NAMESPACE),
                         (30, 2, 86400, "noixdev-infra-tests"))


if __name__ == "__main__":
    unittest.main()
