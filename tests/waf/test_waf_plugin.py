"""Unit tests of plugins/filter/waf_plugin.py (no Ansible needed)."""

import importlib.util
import pathlib
import tarfile
import unittest

_PATH = pathlib.Path(__file__).resolve().parents[2] / "plugins" / "filter" / "waf_plugin.py"
_SPEC = importlib.util.spec_from_file_location("waf_plugin", _PATH)
waf_plugin = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(waf_plugin)

NC = "nextcloud-rule-exclusions"
ALLOWED = "(only SecRule, SecAction and SecMarker)"
SECOND = "after the first directive word is not allowed in a plugin (one directive per line)"
SECRET = "is not allowed in a plugin (it can copy a credential into the log)"


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
        got = check('SecAction \\\r\n "id:9590001"\r\nSecMarker END \\')
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

    def test_check_escaped_quote_hidden_id(self):
        got = check('SecAction "msg:\'a\\\',id:9590001,b\',id:5000000"\n')
        self.assertIn("x-before.conf line 1: rule id 5000000 is outside 9500000-9999999", got["errors"])

    def test_check_two_ids(self):
        got = check('SecAction "id:9590001,id:9590002"\n')
        self.assertEqual(got["errors"], ["x-before.conf line 1: a rule with more than one id"])
        got = check('SecAction "id:9590001,id:5000000"\n')
        self.assertIn("x-before.conf line 1: a rule with more than one id", got["errors"])
        self.assertIn("x-before.conf line 1: rule id 5000000 is outside 9500000-9999999", got["errors"])

    def test_check_faked_chain(self):
        got = check('SecAction "id:9590001,msg:\'a\\\',chain,b\'"\nSecAction "id:5000001"\n')
        self.assertIn("x-before.conf line 2: rule id 5000001 is outside 9500000-9999999", got["errors"])

    def test_check_chain_open_at_eof_and_per_file(self):
        got = waf_plugin.waf_plugin_check(
            "x", {"config": 'SecAction "id:9590002,chain"\n', "before": 'SecAction "id:5000001"\n'}
        )
        self.assertEqual(
            got["errors"],
            ["x-config.conf line 1: a chain that no rule continues",
             "x-before.conf line 1: rule id 5000001 is outside 9500000-9999999"],
        )

    def test_check_comment_ending_in_backslash(self):
        got = check("# note \\\nInclude foo\nSecAction \"id:9590001\"\n")
        self.assertEqual(got["errors"][0], "x-before.conf line 1: a comment that ends in \\")
        self.assertIn(f"x-before.conf line 2: Include is not allowed in a plugin {ALLOWED}", got["errors"])

    def test_check_realistic_chained_rule(self):
        text = (
            'SecRule REQUEST_FILENAME "@contains /x" \\\n'
            '    "id:9590010,phase:1,pass,nolog,msg:\'a,b\',chain"\n'
            '    SecRule REQUEST_METHOD "POST" \\\n'
            '        "t:none,ctl:ruleRemoveTargetById=942100;ARGS:x"\n'
        )
        self.assertEqual(check(text), {"ids": [9590010], "low": 9590010, "high": 9590010, "errors": []})

    def test_check_commented_out_rule_run(self):
        text = (
            '# SecRule A "@eq 0" \\\n#     "id:9508010,\\\n#     pass"\\\n#     nolog\n'
            'SecAction "id:9590001,pass,nolog"\n'
        )
        got = check(text)
        self.assertEqual((got["errors"], got["ids"]), ([], [9590001]))

    def test_check_backslash_comment_before_blank_or_eof(self):
        self.assertEqual(check('# a \\\n\nSecAction "id:9590001"\n')["errors"], [])
        self.assertEqual(check('SecAction "id:9590001"\n# a \\')["errors"], [])

    def test_check_second_directive_on_one_line(self):
        got = check('SecAction "id:9500001,phase:1,pass,nolog" SecRuleRemoveById 949110\n')
        self.assertEqual(got["errors"], [f"x-before.conf line 1: SecRuleRemoveById {SECOND}"])

    def test_check_second_directive_after_continuation(self):
        got = check('SecAction "id:9500001,pass,nolog" \\\nSecRuleRemoveById 949110\n')
        self.assertEqual(got["errors"], [f"x-before.conf line 1: SecRuleRemoveById {SECOND}"])
        got = check('SecAction "id:9500001,pass,nolog"\\\nSecRuleRemoveById 949110\n')
        self.assertEqual(got["errors"], [f"x-before.conf line 1: SecRuleRemoveById {SECOND}"])
        got = check('SecAction "id:9500001,pass,nolog" \\\nInclude /etc/passwd\n')
        self.assertEqual(got["errors"], [f"x-before.conf line 1: Include {SECOND}"])
        got = check('SecAction "id:9500001,pass,nolog" \\\n  includeOptional /etc/passwd\n')
        self.assertEqual(got["errors"], [f"x-before.conf line 1: includeOptional {SECOND}"])

    def test_check_second_directive_inside_quotes(self):
        got = check('SecAction "id:9500001,pass,nolog,msg:\'x SecRuleEngine Off\'"\n')
        self.assertEqual(got["errors"], [f"x-before.conf line 1: SecRuleEngine {SECOND}"])

    def test_check_second_directive_after_secmarker(self):
        got = check('SecMarker X SecRuleEngine Off\nSecAction "id:9500001"\n')
        self.assertEqual(
            got["errors"],
            [f"x-before.conf line 1: SecRuleEngine {SECOND}", "x-before.conf line 1: SecMarker takes one name"],
        )
        got = check('SecMarker X \\\nSecDefaultAction "phase:2,pass"\nSecAction "id:9500001"\n')
        self.assertEqual(
            got["errors"],
            [f"x-before.conf line 1: SecDefaultAction {SECOND}", "x-before.conf line 1: SecMarker takes one name"],
        )

    def test_check_secmarker_one_name(self):
        got = check('SecMarker A B\nSecAction "id:9500001"\n')
        self.assertEqual(got["errors"], ["x-before.conf line 1: SecMarker takes one name"])
        self.assertEqual(check('SecMarker "END-X"\nSecMarker END-Y\nSecAction "id:9500001"\n')["errors"], [])

    def test_check_lone_cr_is_a_line_break(self):
        got = check('SecAction "id:9500001,pass,nolog"\rSecRuleRemoveById 949110\r')
        self.assertEqual(got["errors"], [f"x-before.conf line 2: SecRuleRemoveById is not allowed in a plugin {ALLOWED}"])
        got = check('SecAction "id:9500001" \\\rSecRuleRemoveById 949110\r')
        self.assertEqual(got["errors"], [f"x-before.conf line 1: SecRuleRemoveById {SECOND}"])
        got = check('SecAction \\\r "id:9500001"\rSecAction "id:9500002"\r\n')
        self.assertEqual((got["errors"], got["ids"]), ([], [9500001, 9500002]))

    def test_check_directive_like_words_that_pass(self):
        text = (
            'SecRule REQUEST_HEADERS:X-SecFoo "@rx x" "id:9500001,phase:1,pass,nolog,setvar:tx.secret=1"\n'
            'SecRule TX:secret "@eq 1" "id:9500002,phase:1,pass,nolog,msg:\'Secure_x\'"\n'
            'SecRule ARGS:included "@rx Security2" "id:9500003,phase:2,pass,nolog"\n'
        )
        self.assertEqual(check(text)["errors"], [])

    def test_check_comment_inside_continuation(self):
        got = check('SecAction "id:9500001,pass" \\\n# SecRuleRemoveById 949110\n')
        self.assertEqual(
            got["errors"],
            ["x-before.conf line 2: a comment inside a continued directive",
             f"x-before.conf line 1: SecRuleRemoveById {SECOND}"],
        )
        got = check('SecAction "id:9500001,pass" \\\n  # note \\\n  ",nolog"\n')
        self.assertEqual(got["errors"], ["x-before.conf line 2: a comment inside a continued directive"])

    def test_check_credential_macros(self):
        cases = [
            ("logdata:'%{REQUEST_HEADERS.authorization}'", "REQUEST_HEADERS"),
            ("logdata:'%{request_headers:Cookie}'", "REQUEST_HEADERS"),
            ("msg:'%{ Request_Cookies.session}'", "REQUEST_COOKIES"),
            ("logdata:%{REQUEST_COOKIES:sid}", "REQUEST_COOKIES"),
        ]
        for action, name in cases:
            with self.subTest(action=action):
                got = check(f'SecAction "id:9500001,pass,log,{action}"\n')
                self.assertEqual(got["errors"], [f"x-before.conf line 1: %{{{name}...}} {SECRET}"])

    def test_check_full_request(self):
        for text in ('SecRule FULL_REQUEST "@rx x" "id:9500001,pass"\n',
                     'SecAction "id:9500001,pass,log,logdata:\'%{full_request}\'"\n'):
            with self.subTest(text=text):
                self.assertEqual(check(text)["errors"], [f"x-before.conf line 1: FULL_REQUEST {SECRET}"])

    def test_check_harmless_macros_and_targets(self):
        text = (
            'SecRule REQUEST_HEADERS:Foo|REQUEST_HEADERS_NAMES "@rx x" "id:9500001,phase:1,pass,log,'
            "logdata:'%{REQUEST_HEADERS_NAMES} %{tx.anomaly_score} %{MATCHED_VAR} %{REQUEST_FILENAME}'\"\n"
            'SecRule FULL_REQUEST_LENGTH "@gt 1" "id:9500002,phase:2,pass,nolog"\n'
        )
        self.assertEqual(check(text)["errors"], [])

    def test_check_real_nextcloud_plugin(self):
        archive = pathlib.Path(__file__).resolve().parent / "fixtures" / "plugins" / f"{NC}-plugin-1.7.1.tar.gz"
        if not archive.is_file():
            self.skipTest("fixture archive not present")
        with tarfile.open(archive) as tar:
            members = {m.name: m for m in tar.getmembers() if m.isfile()}
            picked = waf_plugin.waf_plugin_pick(list(members), NC)
            self.assertEqual(picked["errors"], [])
            texts = {
                kind: tar.extractfile(members[path]).read().decode("utf-8")
                for kind, path in picked["files"].items()
            }
        got = waf_plugin.waf_plugin_check(NC, texts)
        self.assertEqual(got["errors"], [])
        self.assertEqual((got["low"], got["high"]), (9508097, 9508992))

    def test_filters(self):
        self.assertEqual(
            set(waf_plugin.FilterModule().filters()), {"waf_plugin_pick", "waf_plugin_check"}
        )


if __name__ == "__main__":
    unittest.main()
