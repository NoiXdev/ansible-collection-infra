"""The caching stack's configuration: settings the tests rely on."""
import pathlib
import re
import unittest

HERE = pathlib.Path(__file__).resolve().parent


class AptCacherNg(unittest.TestCase):
    def setting(self, name):
        text = (HERE / "apt" / "acng.conf").read_text(encoding="utf-8")
        found = re.findall(rf"^{name}:\s*(\S+)\s*$", text, re.MULTILINE)
        self.assertEqual(len(found), 1, f"{name} must be set once in tests/cache/apt/acng.conf")
        return found[0]

    def test_volatile_files_are_fetched_whole(self):
        """A resumed or If-Range download of an index that changed upstream
        meanwhile mixes two versions: on 2026-11-26 the cache served a
        noble-security InRelease whose signature did not match its text."""
        self.assertEqual(self.setting("VfileUseRangeOps"), "-1")


if __name__ == "__main__":
    unittest.main()
