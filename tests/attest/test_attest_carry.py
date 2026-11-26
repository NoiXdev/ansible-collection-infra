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


class AlwaysAll(unittest.TestCase):
    """The attestation's own files rerun every suite, whatever the map says."""
    LAX = ("[ignore]\ntests/suites.conf\ntests/attest/\n.github/scripts/\n"
           "[suite e2e]\ntests/all.sh\ntests/attest.sh\ntests/lib/\nroles/e2e/\n")
    PATHS = ["tests/suites.conf", "tests/all.sh", "tests/attest.sh", "tests/attest/selftest.sh",
             "tests/lib/suite.sh", ".github/scripts/attest_carry.py"]

    def test_ignored_or_suite_mapped_still_all(self):
        m = ac.parse_map(self.LAX)
        for path in self.PATHS:
            self.assertEqual(ac.classify(m, path)[0], "shared", path)
            self.assertEqual(ac.affected_suites(m, [path]), "ALL", path)

    def test_neighbours_follow_the_map(self):
        m = ac.parse_map(self.LAX)
        self.assertEqual(ac.affected_suites(m, ["roles/e2e/tasks/main.yml"]), {"e2e"})
        self.assertEqual(ac.classify(m, "tests/attest.sh.orig")[0], "unmatched")
        self.assertEqual(ac.classify(m, "tests/library/x")[0], "unmatched")


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


class VersionOnly(unittest.TestCase):
    """A change of galaxy.yml in its version: line only touches no suite."""

    GALAXY = "namespace: noixdev\nname: infra\nversion: 0.6.0\ndescription: d\n"

    git = Rename.git

    def commits(self, before: bytes, after):
        """Two commits with galaxy.yml as before and after (None: removed)."""
        path = os.path.join(self.repo, "galaxy.yml")
        self.git("init", "-q")
        with open(path, "wb") as f:
            f.write(before)
        with open(os.path.join(self.repo, "other"), "w") as f:
            f.write("x\n")
        self.git("add", "-A")
        self.git("commit", "-q", "-m", "one")
        a = self.git("rev-parse", "HEAD")
        if after is None:
            os.remove(path)
        else:
            with open(path, "wb") as f:
                f.write(after)
        self.git("add", "-A")
        self.git("commit", "-q", "--allow-empty", "-m", "two")
        return a, self.git("rev-parse", "HEAD")

    def check(self, before, after, expected):
        with tempfile.TemporaryDirectory() as self.repo:
            a, b = self.commits(before, after)
            self.assertIs(ac.version_only(self.repo, a, b), expected)
            changed, dropped = ac.relevant_changes(self.repo, a, b)
            self.assertIs(dropped, expected)
            self.assertEqual("galaxy.yml" in changed, not expected)

    def test_version_only(self):
        self.check(self.GALAXY.encode(), self.GALAXY.replace("0.6.0", "0.7.0").encode(), True)

    def test_another_line_too(self):
        after = self.GALAXY.replace("0.6.0", "0.7.0").replace("description: d", "description: e")
        self.check(self.GALAXY.encode(), after.encode(), False)

    def test_whitespace_change_too(self):
        after = self.GALAXY.replace("0.6.0", "0.7.0").replace("name: infra", "name:  infra")
        self.check(self.GALAXY.encode(), after.encode(), False)

    def test_second_version_line(self):
        after = self.GALAXY.replace("0.6.0", "0.7.0") + "version: 0.7.0\n"
        self.check(self.GALAXY.encode(), after.encode(), False)

    def test_version_line_moved(self):
        after = "version: 0.7.0\nnamespace: noixdev\nname: infra\ndescription: d\n"
        self.check(self.GALAXY.encode(), after.encode(), False)

    def test_removed(self):
        self.check(self.GALAXY.encode(), None, False)

    def test_more_than_a_version_on_the_line(self):
        # YAML also breaks lines at NEL, U+2028 and U+2029, and a flow mapping
        # or a comment could hide more: the version line holds a version only.
        for line in ("version: 0.7.0\u2028description: e", "version: 0.7.0\x85build_ignore: []",
                     "version: {a: 1}", "version: 0.7.0 # x", "version: 0.7.0, x"):
            with self.subTest(line=line):
                after = self.GALAXY.replace("version: 0.6.0", line)
                self.check(self.GALAXY.encode(), after.encode(), False)

    def test_version_spellings(self):
        for line in ("version: 0.7.0-rc.1", "version: 1.0.0+build.5", 'version: "0.7.0"', "version: '0.7.0'",
                     "version:  0.7.0 "):
            with self.subTest(line=line):
                after = self.GALAXY.replace("version: 0.6.0", line)
                self.check(self.GALAXY.encode(), after.encode(), True)

    def test_crlf_on_both_sides(self):
        crlf = self.GALAXY.replace("\n", "\r\n")
        self.check(crlf.encode(), crlf.replace("0.6.0", "0.7.0").encode(), True)

    def test_crlf_on_one_side(self):
        after = self.GALAXY.replace("0.6.0", "0.7.0").replace("\n", "\r\n")
        self.check(self.GALAXY.encode(), after.encode(), False)

    def test_unchanged_galaxy(self):
        with tempfile.TemporaryDirectory() as self.repo:
            a, b = self.commits(self.GALAXY.encode(), self.GALAXY.encode())
            self.assertEqual(ac.relevant_changes(self.repo, a, b), ([], False))
            self.assertIs(ac.version_only(self.repo, a, b), True)

    def test_cli(self):
        with tempfile.TemporaryDirectory() as self.repo:
            a, b = self.commits(self.GALAXY.encode(), self.GALAXY.replace("0.6.0", "0.7.0").encode())
            cli = [sys.executable, "-I", ac.__file__, "version-only", "--repo", self.repo]
            self.assertEqual(subprocess.run(cli + ["--from", a, "--to", b]).returncode, 0)
            self.assertEqual(subprocess.run(cli + ["--from", a, "--to", a]).returncode, 0)
        with tempfile.TemporaryDirectory() as self.repo:
            a, b = self.commits(self.GALAXY.encode(), b"version: 0.7.0\n")
            cli[-1] = self.repo
            r = subprocess.run(cli + ["--from", a, "--to", b], stdout=subprocess.PIPE)
            self.assertEqual(r.returncode, 1)


class ReleaseSuites(unittest.TestCase):
    """A suite with a <suite>_releases=(...) line has one entry per release."""

    def test_split_suite(self):
        allsh = ALLSH.replace("tandoor)", "tandoor postal)") + "postal_releases=(24.04 26.04)\n"
        self.assertEqual(ac.expected_entries(allsh)[-3:], [
            ("tandoor", "tandoor"), ("postal-24.04", "postal"), ("postal-26.04", "postal")])

    def test_old_all_sh(self):
        # The array lines of tests/all.sh at 538f4c8 (the v0.7.0 candidate).
        old = ("all_suites=(e2e host services harbor listmonk paperless tandoor n8n anubis mailcow cloudpanel "
               "pulsix_agent backrest vaultwarden postal waf varnish graylog)\n"
               "host_releases=(24.04 26.04)\nservices_releases=(24.04 26.04)\n")
        labels = [label for label, _ in ac.expected_entries(old)]
        self.assertEqual(len(labels), 20)
        self.assertIn("postal", labels)
        self.assertIn("services-26.04", labels)

    def test_two_release_lines(self):
        with self.assertRaises(ValueError):
            ac.expected_entries(ALLSH + "host_releases=(24.04)\n")

    def test_empty_release_line(self):
        with self.assertRaises(ValueError):
            ac.expected_entries(ALLSH.replace("tandoor)", "tandoor postal)") + "postal_releases=()\n")


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


MC_ALLSH = """\
#!/usr/bin/env bash
# Entries:
#   e2e          tests/run.sh
#   tandoor      tests/tandoor/run.sh
set -euo pipefail
all_suites=(e2e tandoor n8n)
tandoor_releases=(24.04 26.04)
release_vars=()
long_first=(tandoor n8n)
ram_gb=(tandoor:2)
for s in "${all_suites[@]}"; do
  echo "$s"
done
"""


class MapChanges(unittest.TestCase):
    """map_changes: which suites a change of tests/suites.conf or tests/all.sh touches."""

    def sc(self, new):
        return ac.suites_conf_changes(MAP, new)

    def sh(self, new, old=MC_ALLSH):
        return ac.allsh_changes(old, new)

    def test_new_section_is_that_suite(self):
        self.assertEqual(self.sc(MAP + "\n[suite watchtower]\ntests/watchtower/\n"), {"watchtower"})

    def test_pattern_added_is_that_suite(self):
        new = MAP.replace("tests/tandoor/\n", "tests/tandoor/\nroles/tandoor/extra/\n")
        self.assertEqual(self.sc(new), {"tandoor"})

    def test_pattern_moved_between_sections(self):
        new = MAP.replace("tests/tandoor/\n", "").replace("roles/n8n/\n", "roles/n8n/\ntests/tandoor/\n")
        self.assertEqual(self.sc(new), {"tandoor", "n8n"})

    def test_reorder_and_comments_are_nothing(self):
        new = MAP.replace("tests/tandoor/\nroles/tandoor/\n", "roles/tandoor/\ntests/tandoor/\n")
        new = new.replace("# A comment line.", "# Another comment.\n")
        self.assertNotEqual(new, MAP)
        self.assertEqual(self.sc(new), set())

    def test_ignore_or_shared_changed_is_all(self):
        self.assertEqual(self.sc(MAP.replace("[ignore]\n", "[ignore]\nroles/\n")), "ALL")
        self.assertEqual(self.sc(MAP.replace("[shared]\n", "[shared]\ngalaxy.yml\n")), "ALL")

    def test_section_removed_is_all(self):
        self.assertEqual(self.sc(MAP.replace("[suite n8n]\nroles/n8n/\n", "")), "ALL")

    def test_unparseable_is_all(self):
        self.assertEqual(self.sc("roles/x/\n" + MAP), "ALL")
        self.assertEqual(ac.suites_conf_changes("roles/x/\n" + MAP, MAP), "ALL")

    def test_new_suite_in_allsh(self):
        new = MC_ALLSH.replace("all_suites=(e2e tandoor n8n)", "all_suites=(e2e tandoor n8n watchtower)")
        new = new.replace("#   tandoor      tests/tandoor/run.sh\n",
                          "#   tandoor      tests/tandoor/run.sh\n#   watchtower   tests/watchtower/run.sh\n")
        new = new.replace("tandoor_releases=(24.04 26.04)\n", "tandoor_releases=(24.04 26.04)\nwatchtower_releases=(24.04)\n")
        self.assertEqual(self.sh(new), {"watchtower"})

    def test_existing_releases_changed(self):
        self.assertEqual(self.sh(MC_ALLSH.replace("tandoor_releases=(24.04 26.04)", "tandoor_releases=(24.04)")),
                         {"tandoor"})

    def test_existing_setting_changed(self):
        self.assertEqual(self.sh(MC_ALLSH.replace("ram_gb=(tandoor:2)", "ram_gb=(tandoor:3)")), {"tandoor"})
        self.assertEqual(self.sh(MC_ALLSH.replace("long_first=(tandoor n8n)", "long_first=(tandoor n8n e2e)")),
                         {"e2e"})
        self.assertEqual(self.sh(MC_ALLSH.replace("release_vars=()", "release_vars=(tandoor:UBUNTU)")),
                         {"tandoor"})

    def test_setting_reordered_is_all(self):
        self.assertEqual(self.sh(MC_ALLSH.replace("long_first=(tandoor n8n)", "long_first=(n8n tandoor)")), "ALL")

    def test_suite_removed_or_reordered_is_all(self):
        self.assertEqual(self.sh(MC_ALLSH.replace("all_suites=(e2e tandoor n8n)", "all_suites=(e2e tandoor)")), "ALL")
        self.assertEqual(self.sh(MC_ALLSH.replace("all_suites=(e2e tandoor n8n)", "all_suites=(e2e n8n tandoor)")), "ALL")

    def test_releases_for_unknown_suite_is_all(self):
        self.assertEqual(self.sh(MC_ALLSH.replace("release_vars=()\n", "release_vars=()\nnope_releases=(24.04)\n")), "ALL")
        self.assertEqual(self.sh(MC_ALLSH.replace("ram_gb=(tandoor:2)", "ram_gb=(tandoor:2 nope:1)")), "ALL")

    def test_other_line_is_all(self):
        self.assertEqual(self.sh(MC_ALLSH.replace('  echo "$s"', '  echo "$s" >&2')), "ALL")
        self.assertEqual(self.sh(MC_ALLSH.replace('  echo "$s"', '   echo "$s"')), "ALL")

    def test_declaration_moved(self):
        new = MC_ALLSH.replace("all_suites=(e2e tandoor n8n)\n", "").replace("done\n", "done\nall_suites=(e2e tandoor n8n)\n")
        self.assertEqual(self.sh(new), "ALL")

    def test_declaration_twice_is_all(self):
        self.assertEqual(self.sh(MC_ALLSH + "ram_gb=(tandoor:2)\n"), "ALL")
        self.assertEqual(self.sh(MC_ALLSH.replace("ram_gb=(tandoor:2)", "ram_gb=(tandoor:2 tandoor:3)")), "ALL")

    def test_heredoc_makes_comments_count(self):
        with_heredoc = MC_ALLSH + "cat <<EOF\nx\nEOF\n"
        changed = with_heredoc.replace("# Entries:", "# The entries:")
        self.assertEqual(self.sh(changed, with_heredoc), "ALL")
        self.assertEqual(self.sh(MC_ALLSH.replace("# Entries:", "# The entries:")), set())

    def test_here_string_is_no_heredoc(self):
        with_here_string = MC_ALLSH + 'read -r a b <<<"$x"\n'
        changed = with_here_string.replace("# Entries:", "# The entries:")
        self.assertEqual(self.sh(changed, with_here_string), set())

    def test_unchanged_is_nothing(self):
        self.assertEqual(self.sc(MAP), set())
        self.assertEqual(self.sh(MC_ALLSH), set())

    def git(self, *args):
        env = dict(os.environ, GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_NOSYSTEM="1",
                   GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@example.com",
                   GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@example.com")
        return subprocess.run(["git", "-C", self.repo] + list(args), check=True, env=env,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              universal_newlines=True).stdout.strip()

    def write(self, path, text):
        full = os.path.join(self.repo, path)
        os.makedirs(os.path.dirname(full), exist_ok=True)
        with open(full, "w") as f:
            f.write(text)

    def test_map_changes_reads_commits(self):
        with tempfile.TemporaryDirectory() as self.repo:
            self.git("init", "-q")
            self.write("tests/suites.conf", MAP)
            self.write("tests/all.sh", MC_ALLSH)
            self.git("add", "-A")
            self.git("commit", "-q", "-m", "one")
            a = self.git("rev-parse", "HEAD")
            self.write("tests/suites.conf", MAP + "\n[suite watchtower]\ntests/watchtower/\n")
            self.write("tests/all.sh", MC_ALLSH.replace("all_suites=(e2e tandoor n8n)",
                                                        "all_suites=(e2e tandoor n8n watchtower)"))
            self.git("commit", "-q", "-am", "two")
            b = self.git("rev-parse", "HEAD")
            self.assertEqual(ac.map_changes(self.repo, a, b), {"watchtower"})
            self.assertEqual(ac.map_changes(self.repo, a, a), set())
            self.git("rm", "-q", "tests/all.sh")
            self.git("commit", "-q", "-m", "three")
            self.assertEqual(ac.map_changes(self.repo, a, self.git("rev-parse", "HEAD")), "ALL")


if __name__ == "__main__":
    unittest.main()
