"""Unit tests of .github/release/release.py, the release tool that release.yml calls:

  python3 -I -m unittest discover -s .github/release -p test_release.py
"""
import os
import subprocess
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import release as rl  # noqa: E402

REPO_ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
SLUG = "NoiXdev/ansible-collection-infra"

GALAXY = "namespace: noixdev\nname: infra\nversion: 0.5.0\nreadme: README.md\n"
README = "# infra\n\n```yaml\ncollections:\n  - name: noixdev.infra\n    version: v0.5.0\n```\n"
CHANGELOG = (
    "# Changelog\n\n## Unreleased\n\n- entry\n\n"
    "## 0.5.0 — 2026-11-14\n\n- old entry\n- another\n"
)


def git(repo, *args):
    subprocess.run(["git", "-C", repo, *args], check=True, capture_output=True)


class RepoCase(unittest.TestCase):
    def make_repo(self, galaxy=GALAXY, readme=README, changelog=CHANGELOG, tags=("v0.5.0",)):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        d = tmp.name
        git(d, "init", "-q")
        for name, text in (("galaxy.yml", galaxy), ("README.md", readme), ("CHANGELOG.md", changelog)):
            with open(os.path.join(d, name), "w", encoding="utf-8", newline="") as f:
                f.write(text)
        git(d, "add", ".")
        git(d, "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false",
            "commit", "-q", "-m", "init")
        for t in tags:
            git(d, "tag", t)
        return d

    def refuses(self, repo, bump="minor"):
        with self.assertRaises(rl.ReleaseError) as cm:
            rl.preflight(repo, bump)
        return str(cm.exception)


class Versions(unittest.TestCase):
    def test_next_version(self):
        self.assertEqual(rl.next_version("0.5.0", "patch"), "0.5.1")
        self.assertEqual(rl.next_version("0.5.0", "minor"), "0.6.0")
        self.assertEqual(rl.next_version("0.5.3", "major"), "1.0.0")


class Edits(unittest.TestCase):
    def test_bump_changelog_heading(self):
        out = rl.bump_changelog(CHANGELOG, "0.6.0", "2026-11-20")
        self.assertTrue(out.startswith(
            "# Changelog\n\n## Unreleased\n\n## 0.6.0 — 2026-11-20\n\n- entry"))
        old = "## 0.5.0 — 2026-11-14\n\n- old entry\n- another\n"
        self.assertTrue(out.endswith(old))

    def test_set_galaxy_version_only_line(self):
        out = rl.set_galaxy_version(GALAXY, "0.6.0")
        a, b = GALAXY.split("\n"), out.split("\n")
        self.assertEqual(len(a), len(b))
        for x, y in zip(a, b):
            if x.startswith("version:"):
                self.assertEqual(y, "version: 0.6.0")
            else:
                self.assertEqual(x, y)
        for bad in ('version: "0.5.0"', "version: 0.5.0-rc.1"):
            with self.assertRaises(rl.ReleaseError):
                rl.set_galaxy_version("name: x\n" + bad + "\n", "0.6.0")

    def test_set_readme_version(self):
        out = rl.set_readme_version(README, "0.6.0")
        self.assertEqual(out, README.replace("    version: v0.5.0", "    version: v0.6.0"))


class Preflight(RepoCase):
    def test_ok_prints_next(self):
        d = self.make_repo()
        self.assertEqual(rl.preflight(d, "minor"), "0.6.0")
        self.assertEqual(rl.preflight(d, "major"), "1.0.0")

    def test_preflight_refuses_untagged_current_version(self):
        msg = self.refuses(self.make_repo(tags=()))
        self.assertIn("v0.5.0", msg)
        self.assertIn("by hand", msg)
        self.assertIn("tag", msg)
        self.assertIn("release", msg)

    def test_preflight_refuses_existing_next_tag(self):
        msg = self.refuses(self.make_repo(tags=("v0.5.0", "v0.6.0")))
        self.assertIn("v0.6.0", msg)
        self.assertIn("exists", msg)

    def test_preflight_refuses_empty_unreleased(self):
        for body in ("\n\n  \n", "<!-- nothing yet -->\n", "<!--\nnothing\nyet\n-->\n\n"):
            cl = "# Changelog\n\n## Unreleased\n\n" + body + "## 0.5.0 — 2026-11-14\n\n- old\n"
            msg = self.refuses(self.make_repo(changelog=cl))
            self.assertIn("Unreleased", msg)
            self.assertIn("empty", msg)

    def test_preflight_refuses_unreleased_shapes(self):
        old = "## 0.5.0 — 2026-11-14\n\n- old\n"
        cases = {
            "missing": "# Changelog\n\n" + old,
            "twice": "# Changelog\n\n## Unreleased\n\n- a\n\n## Unreleased\n\n- b\n\n" + old,
            "not first": "# Changelog\n\n## 0.4.0 — 2026-10-01\n\n- x\n\n## Unreleased\n\n- a\n\n" + old,
            "target present": "# Changelog\n\n## Unreleased\n\n- a\n\n## 0.6.0 — 2026-11-01\n\n- b\n\n" + old,
        }
        for name, cl in cases.items():
            with self.subTest(name):
                msg = self.refuses(self.make_repo(changelog=cl))
                self.assertTrue("Unreleased" in msg or "0.6.0" in msg, msg)

    def test_preflight_refuses_readme_shapes(self):
        for name, readme in (("zero", "# infra\n"), ("two", README + "    version: v0.4.0\n")):
            with self.subTest(name):
                msg = self.refuses(self.make_repo(readme=readme))
                self.assertIn("README.md", msg)

    def test_galaxy_shapes(self):
        msg = self.refuses(self.make_repo(galaxy="name: x\nversion: 0.5.0\nversion: 0.5.0\n"))
        self.assertIn("galaxy.yml", msg)


class AfterRelease(RepoCase):
    def test_real_shape_with_empty_unreleased_passes_structure_check(self):
        with open(os.path.join(REPO_ROOT, "CHANGELOG.md"), encoding="utf-8", newline="") as f:
            real = f.read()
        i = real.index("## Unreleased") + len("## Unreleased")
        j = real.index("\n## ", i)
        empty = real[:i] + "\n" + real[j:]
        with self.assertRaises(rl.ReleaseError) as cm:
            rl.bump_changelog(empty, "9.9.9", "2026-01-01")
        self.assertIn("empty", str(cm.exception))
        marked = empty[:i] + "\n\n- placeholder entry" + empty[i:]
        rl.bump_changelog(marked, "9.9.9", "2026-01-01")


class Apply(RepoCase):
    def test_apply_writes_both_files(self):
        d = self.make_repo()
        rl.apply(d, "0.6.0", "2026-11-20")
        with open(os.path.join(d, "galaxy.yml"), encoding="utf-8") as f:
            self.assertIn("version: 0.6.0\n", f.read())
        with open(os.path.join(d, "CHANGELOG.md"), encoding="utf-8") as f:
            self.assertIn("## 0.6.0 — 2026-11-20\n", f.read())

    def test_apply_writes_nothing_on_bad_shape(self):
        d = self.make_repo(readme="# infra\n")
        with self.assertRaises(rl.ReleaseError):
            rl.apply(d, "0.6.0", "2026-11-20")
        with open(os.path.join(d, "galaxy.yml"), encoding="utf-8") as f:
            self.assertEqual(f.read(), GALAXY)


NOTES = "# Changelog\n\n## Unreleased\n\n## 0.6.0 — 2026-11-20\n\n- a\n- b\n\n## 0.5.0 — 2026-11-14\n\n- old\n"


class Notes(unittest.TestCase):
    def test_notes_section_only(self):
        self.assertEqual(rl.release_notes(NOTES, "0.6.0", SLUG), "- a\n- b")

    def test_notes_cut_at_line_boundary_utf8(self):
        lines = ["- entry %d ü — %s" % (i, "x" * 40) for i in range(1200)]
        cl = "# Changelog\n\n## 0.6.0 — 2026-11-20\n\n" + "\n".join(lines) + "\n\n## 0.5.0 — 2026-11-14\n\n- old\n"
        self.assertGreater(len("\n".join(lines).encode("utf-8")), 70000 - 2000)
        out = rl.release_notes(cl, "0.6.0", SLUG)
        raw = out.encode("utf-8")
        self.assertLessEqual(len(raw), 60000)
        raw.decode("utf-8")
        pointer = out.split("\n")[-1]
        self.assertIn("https://github.com/NoiXdev/ansible-collection-infra/blob/v0.6.0/CHANGELOG.md", pointer)
        kept = out.split("\n\n… cut at")[0].split("\n")
        self.assertGreater(len(kept), 1)
        self.assertEqual(kept, lines[:len(kept)])
        self.assertGreater(len(raw), 59000)


class Cli(RepoCase):
    def run_cli(self, *args):
        return subprocess.run([sys.executable, "-I", os.path.join(HERE, "release.py"), *args],
                              capture_output=True, text=True)

    def test_cli_error_convention(self):
        d = self.make_repo(tags=())
        r = self.run_cli("preflight", "--bump", "minor", "--repo", d)
        self.assertEqual(r.returncode, 1)
        self.assertTrue(r.stderr.startswith("::error::"), r.stderr)
        self.assertEqual(self.run_cli("bogus").returncode, 2)

    def test_cli_happy_paths(self):
        d = self.make_repo()
        r = self.run_cli("preflight", "--bump", "minor", "--repo", d)
        self.assertEqual((r.returncode, r.stdout), (0, "0.6.0\n"))
        self.assertEqual(self.run_cli("apply", "--version", "0.6.0", "--date", "2026-11-20", "--repo", d).returncode, 0)
        r = self.run_cli("notes", "--version", "0.6.0", "--repo-slug", SLUG, "--repo", d)
        self.assertEqual((r.returncode, r.stdout), (0, "- entry"))
        self.assertEqual(self.run_cli("readme", "--version", "0.6.0", "--repo", d).returncode, 0)
        with open(os.path.join(d, "README.md"), encoding="utf-8") as f:
            self.assertIn("    version: v0.6.0\n", f.read())


class CliNotesSize(RepoCase):
    def test_cli_notes_output_within_limit(self):
        # Fixed-width lines, so one of the widths lands the body exactly on the limit.
        for width in (1, 2, 3, 4, 5):
            with self.subTest(width=width):
                lines = ["x" * width] * (70000 // (width + 1))
                cl = ("# Changelog\n\n## 0.6.0 \u2014 2026-11-20\n\n" + "\n".join(lines)
                      + "\n\n## 0.5.0 \u2014 2026-11-14\n\n- old\n")
                d = self.make_repo(changelog=cl, tags=("v0.5.0",))
                r = subprocess.run([sys.executable, "-I", os.path.join(HERE, "release.py"), "notes",
                                    "--version", "0.6.0", "--repo-slug", SLUG, "--repo", d],
                                   capture_output=True)
                self.assertEqual(r.returncode, 0)
                self.assertLessEqual(len(r.stdout), 60000)
                self.assertGreater(len(r.stdout), 59000)
                r.stdout.decode("utf-8")


class RealRepo(unittest.TestCase):
    def test_real_repo_shapes(self):
        def read(n):
            with open(os.path.join(REPO_ROOT, n), encoding="utf-8", newline="") as f:
                return f.read()
        # Structure only: the real Unreleased section is empty right after a release.
        cl = read("CHANGELOG.md")
        marker = "## Unreleased"
        i = cl.index(marker) + len(marker)
        rl.bump_changelog(cl[:i] + "\n\n- placeholder entry" + cl[i:], "9.9.9", "2026-01-01")
        rl.set_galaxy_version(read("galaxy.yml"), "9.9.9")
        rl.set_readme_version(read("README.md"), "9.9.9")


if __name__ == "__main__":
    unittest.main()
