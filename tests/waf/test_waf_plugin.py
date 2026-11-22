"""Unit tests of plugins/filter/waf_plugin.py (no Ansible needed)."""

import importlib.util
import pathlib
import unittest

_PATH = pathlib.Path(__file__).resolve().parents[2] / "plugins" / "filter" / "waf_plugin.py"
_SPEC = importlib.util.spec_from_file_location("waf_plugin", _PATH)
waf_plugin = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(waf_plugin)

NC = "nextcloud-rule-exclusions"
ALLOWED = "(only SecRule, SecAction and SecMarker)"


def check(text, kind="before", name="x"):
    return waf_plugin.waf_plugin_check(name, {kind: text})


class PickTest(unittest.TestCase):
    def test_pick_github_layout(self):
        top = f"{NC}-plugin-1.7.1/plugins/"
        paths = [top + f"{NC}-before.conf", top + f"{NC}-config.conf", f"{NC}-plugin-1.7.1/README.md"]
        got = waf_plugin.waf_plugin_pick(paths, NC)
        self.assertEqual(got["files"], {"before": top + f"{NC}-before.conf", "config": top + f"{NC}-config.conf"})
        self.assertEqual(got["errors"], [])

    def test_pick_top_level(self):
        got = waf_plugin.waf_plugin_pick(["x-after.conf", "README.md"], "x")
        self.assertEqual(got, {"files": {"after": "x-after.conf"}, "errors": []})

    def test_pick_plugins_dir(self):
        got = waf_plugin.waf_plugin_pick(["plugins/x-config.conf", "x-before.conf"], "x")
        self.assertEqual(got, {"files": {"config": "plugins/x-config.conf"}, "errors": []})

    def test_pick_two_places(self):
        paths = [f"plugins/{NC}-before.conf", f"a/plugins/{NC}-before.conf"]
        got = waf_plugin.waf_plugin_pick(paths, NC)
        self.assertEqual(got["errors"], [f"has {NC}-before.conf in more than one place"])

    def test_pick_two_directories(self):
        got = waf_plugin.waf_plugin_pick(["a/x-after.conf", "b/x-after.conf"], "x")
        self.assertEqual(got["errors"], ["has x-after.conf in more than one place"])

    def test_pick_none(self):
        got = waf_plugin.waf_plugin_pick(["README.md", "y-config.conf"], "x")
        self.assertEqual(got["files"], {})
        self.assertEqual(got["errors"], ["has no x-config.conf, x-before.conf or x-after.conf"])


class CheckTest(unittest.TestCase):
    def test_check_ok(self):
        text = (
            'SecAction "id:9590001,phase:1,pass,nolog"\n'
            'SecRule REQUEST_URI "@beginsWith /x" \\\n'
            '    "id:9590002,phase:1,pass,nolog,chain"\n'
            '    SecRule REQUEST_METHOD "POST" "t:none,ctl:ruleRemoveById=942100"\n'
            "SecMarker END-X\n"
        )
        got = check(text)
        self.assertEqual(got, {"ids": [9590001, 9590002], "low": 9590001, "high": 9590002, "errors": []})

    def test_check_no_id_at_all(self):
        got = check("SecMarker END-X\n")
        self.assertEqual(got["errors"], ["has no rule with an id"])
        self.assertEqual((got["low"], got["high"], got["ids"]), (0, 0, []))

    def test_check_comment_include(self):
        self.assertEqual(check('# Include foo\nSecAction "id:9590001"\n')["errors"], [])
        got = check('Include foo\nSecAction "id:9590001"\n')
        self.assertEqual(got["errors"], [f"x-before.conf line 1: Include is not allowed in a plugin {ALLOWED}"])

    def test_check_config_wide(self):
        text = 'SecRuleRemoveById 942100\nSecDefaultAction "phase:1,pass"\nSecAuditLogParts ABHZ\nSecAction "id:9590001"\n'
        got = check(text)
        self.assertEqual(
            got["errors"],
            [f"x-before.conf line {n}: {d} is not allowed in a plugin {ALLOWED}"
             for n, d in [(1, "SecRuleRemoveById"), (2, "SecDefaultAction"), (3, "SecAuditLogParts")]],
        )

    def test_check_ctl_audit(self):
        got = check('SecAction "id:9590001,ctl:auditLogParts=+B"\nSecAction "id:9590002,CTL:AUDITENGINE=On"\n')
        self.assertEqual(
            got["errors"],
            ["x-before.conf line 1: ctl:auditLogParts is not allowed in a plugin",
             "x-before.conf line 2: ctl:AUDITENGINE is not allowed in a plugin"],
        )
        self.assertEqual(check('SecAction "id:9590001,ctl:ruleRemoveById=942100"\n')["errors"], [])

    def test_check_ids(self):
        got = check('SecRule ARGS "x" "phase:1,pass"\nSecAction "id:5099906"\n')
        self.assertEqual(
            got["errors"],
            ["x-before.conf line 1: a rule without an id",
             "x-before.conf line 2: rule id 5099906 is outside 9500000-9999999"],
        )

    def test_check_chain_continuation_needs_no_id(self):
        text = 'SecRule A "x" "id:9500000,chain"\nSecRule B "y" "chain"\nSecRule C "z" "t:none"\nSecRule D "w" "pass"\n'
        got = check(text)
        self.assertEqual(got["errors"], ["x-before.conf line 4: a rule without an id"])
        self.assertEqual(got["ids"], [9500000])

    def test_check_crlf_and_trailing_backslash(self):
        got = check('SecAction \\\r\n "id:9590001"\r\n# end \\')
        self.assertEqual(got["errors"], [])
        self.assertEqual(got["ids"], [9590001])
        self.assertEqual(check('SecAction "id:9590001"\nSecMarker X \\')["errors"], [])

    def test_check_line_number_is_start_of_directive(self):
        got = check('\n# c\nInclude \\\n  foo\n')
        self.assertEqual(got["errors"][0], f"x-before.conf line 3: Include is not allowed in a plugin {ALLOWED}")

    def test_check_files_sorted_ids_across_files(self):
        got = waf_plugin.waf_plugin_check(
            "x", {"config": 'SecAction "id:9590009"', "before": 'SecAction "id:9590001"'}
        )
        self.assertEqual((got["ids"], got["low"], got["high"]), ([9590001, 9590009], 9590001, 9590009))

    def test_filters(self):
        self.assertEqual(
            set(waf_plugin.FilterModule().filters()), {"waf_plugin_pick", "waf_plugin_check"}
        )


if __name__ == "__main__":
    unittest.main()
