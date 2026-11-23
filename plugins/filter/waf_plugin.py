"""Filters of the waf role for CRS plugins: waf_plugin_pick and waf_plugin_check.

waf_plugin_pick finds the config, before and after file of a plugin in the
file list of an unpacked archive or src tree. waf_plugin_check refuses what a
plugin may not contain (only SecRule, SecAction and SecMarker, one directive
per line; no ctl: on the audit engine or the audit log parts; no macro or
target that copies the request headers, cookies or the full request into the
log; every rule with an id in 9500000-9999999) and reports the ids it uses.
Pure Python, runs on the controller.
"""

import re

KINDS = ("config", "before", "after")
ID_MIN = 9500000
ID_MAX = 9999999
ALLOWED = ("secrule", "secaction", "secmarker")
_CTL = re.compile(r"\bctl:\s*(auditengine|auditlogparts)\b", re.IGNORECASE)
# Quote-unaware on purpose: any id:<digits> in a rule counts, however the
# quotes and escapes are read by the engine.
_ID = re.compile(r"""(?:^|(?<=[,\s'"]))id:\s*'?(\d+)""", re.IGNORECASE)
# A directive name anywhere after the first word. The text inside plain
# double-quoted strings is masked first (see _mask_quoted); the start of a
# match is checked separately (whitespace, the start of the text or of a
# line, or right after a closing double quote).
_DIRECTIVE = re.compile(r"(?=(sec[a-z]+|include(?:optional)?)(?![a-z0-9_]))", re.IGNORECASE)
# Macros and a target that can copy a credential into the log, quote-unaware.
_SECRET_MACRO = re.compile(r"%\{\s*(request_headers|request_cookies)\s*[.:}]", re.IGNORECASE)
_FULL_REQUEST = re.compile(r"(?<![a-z0-9_])full_request(?![a-z0-9_])", re.IGNORECASE)
_SECRET = "is not allowed in a plugin (it can copy a credential into the log)"


def waf_plugin_pick(paths, name):
    """Return {"files": {kind: path}, "errors": [str]} for the plugin name."""
    wanted = {kind: f"{name}-{kind}.conf" for kind in KINDS}
    # Two groups of locations, in order; the first group with any file wins.
    prefixes = (
        lambda p, f: p == f"plugins/{f}" or (p.count("/") == 2 and p.endswith(f"/plugins/{f}")),
        lambda p, f: p == f or (p.count("/") == 1 and p.endswith(f"/{f}")),
    )
    unique = sorted(set(paths))
    for match in prefixes:
        found = {kind: [p for p in unique if match(p, f)] for kind, f in wanted.items()}
        if not any(found.values()):
            continue
        files, errors = {}, []
        for kind in KINDS:
            if len(found[kind]) > 1:
                errors.append(f"has {wanted[kind]} in more than one place")
            elif found[kind]:
                files[kind] = found[kind][0]
        return {"files": files, "errors": errors}
    return {"files": {}, "errors": [f"has no {wanted['config']}, {wanted['before']} or {wanted['after']}"]}


def _directives(text):
    """Yield (line number, directive text, line starts, problems).

    Continuation lines are joined; line starts are the offsets in the
    directive text where a physical line begins, and problems are
    (line number, message) pairs found while joining.
    """
    text = text.replace("\r\n", "\n").replace("\r", "\n")
    start, parts, problems = 0, [], []
    lines = text.split("\n")

    def joined():
        offsets, at = [], 0
        for part in parts:
            offsets.append(at)
            at += len(part)
        return start, "".join(parts), offsets, problems

    for number, line in enumerate(lines, 1):
        if not parts:
            start = number
            if line.lstrip().startswith("#"):
                nxt = lines[number].strip() if number < len(lines) else ""
                risky = line.rstrip().endswith("\\") and bool(nxt) and not nxt.startswith("#")
                yield start, line.rstrip() if risky else "#", [0], []
                continue
        elif line.lstrip().startswith("#"):
            problems.append((number, "a comment inside a continued directive"))
        if line.endswith("\\"):
            parts.append(line[:-1])
            continue
        parts.append(line)
        yield joined()
        parts, problems = [], []
    if parts:
        yield joined()


def _arguments(directive):
    """The words of a directive, quotes removed (quoted or bare)."""
    return [
        next(g for g in match.groups() if g is not None)
        for match in re.finditer(r'"((?:[^"\\]|\\.)*)"|\'((?:[^\'\\]|\\.)*)\'|(\S+)', directive)
    ]


def _last_argument(directive):
    """The last argument of a directive, quotes removed (quoted or bare)."""
    words = _arguments(directive)
    return words[-1] if words else ""


_DOUBLE_QUOTED = re.compile(r'"((?:[^"\\]|\\.)*)"')


def _mask_quoted(directive):
    """Blank the inside of double-quoted strings, keeping length and quotes.

    A string whose inner text holds an escaped quote, or a quote that is
    never closed, is left as it is, so it is scanned (fails closed where
    this reading could differ from the engine's).
    """
    out, at = [], 0
    while True:
        quote = directive.find('"', at)
        if quote < 0:
            break
        match = _DOUBLE_QUOTED.match(directive, quote)
        if not match:
            break
        inner = match.group(1)
        out.append(directive[at:quote + 1])
        out.append(inner if '\\"' in inner else " " * len(inner))
        out.append('"')
        at = match.end()
    out.append(directive[at:])
    return "".join(out)


def _second_directive(directive, starts, after):
    """The first directive name that starts a word at or after offset after.

    Words inside plain double-quoted strings are not read; a word right
    after a closing double quote is a directive for the engine.
    """
    masked = _mask_quoted(directive)
    for match in _DIRECTIVE.finditer(masked, after):
        at = match.start()
        if at == 0 or masked[at - 1].isspace() or masked[at - 1] == '"' or at in starts:
            return directive[at:match.end(1)]
    return None


def _actions(argument):
    """Split an action list on commas outside single quotes."""
    out, current, quoted = [], "", False
    for char in argument:
        if char == "'":
            quoted = not quoted
        if char == "," and not quoted:
            out.append(current.strip())
            current = ""
        else:
            current += char
    out.append(current.strip())
    return out


def waf_plugin_check(name, files):
    """Return {"ids", "low", "high", "errors"} for the file texts of a plugin."""
    ids, errors = [], []
    for kind in KINDS:
        if kind not in files:
            continue
        fname = f"{name}-{kind}.conf"
        chained = 0  # start line of the rule whose actions had chain, else 0
        for number, directive, starts, problems in _directives(files[kind]):
            errors.extend(f"{fname} line {line}: {problem}" for line, problem in problems)
            stripped = directive.strip()
            if not stripped:
                continue
            if stripped.startswith("#"):
                if stripped.endswith("\\"):
                    errors.append(f"{fname} line {number}: a comment that ends in \\")
                continue
            word = stripped.split(None, 1)[0]
            if word.lower() not in ALLOWED:
                errors.append(
                    f"{fname} line {number}: {word} is not allowed in a plugin "
                    "(only SecRule, SecAction and SecMarker)"
                )
                continue
            word_end = directive.index(word) + len(word)
            second = _second_directive(directive, starts, word_end)
            if second:
                errors.append(
                    f"{fname} line {number}: {second} after the first directive word is not allowed "
                    "in a plugin (one directive per line)"
                )
            if word.lower() == "secmarker":
                if len(_arguments(stripped)) > 2:
                    errors.append(f"{fname} line {number}: SecMarker takes one name")
                continue
            rest = stripped[len(word):]
            argument = _last_argument(stripped)
            ctl = _CTL.search(rest)
            if ctl:
                errors.append(f"{fname} line {number}: ctl:{ctl.group(1)} is not allowed in a plugin")
            macro = _SECRET_MACRO.search(rest)
            if macro:
                errors.append(f"{fname} line {number}: %{{{macro.group(1).upper()}...}} {_SECRET}")
            if _FULL_REQUEST.search(rest):
                errors.append(f"{fname} line {number}: FULL_REQUEST {_SECRET}")
            found = _ID.findall(rest)
            if not found and not chained:
                errors.append(f"{fname} line {number}: a rule without an id")
            if len(found) > 1:
                errors.append(f"{fname} line {number}: a rule with more than one id")
            for rule_id in found:
                ids.append(int(rule_id))
                if not ID_MIN <= int(rule_id) <= ID_MAX:
                    errors.append(
                        f"{fname} line {number}: rule id {int(rule_id)} is outside {ID_MIN}-{ID_MAX}"
                    )
            chained = number if any(a.lower() == "chain" for a in _actions(argument)) else 0
        if chained:
            errors.append(f"{fname} line {chained}: a chain that no rule continues")
    ids = sorted(set(ids))
    if not ids:
        errors.append("has no rule with an id")
    return {"ids": ids, "low": min(ids, default=0), "high": max(ids, default=0), "errors": errors}


class FilterModule:
    """Ansible filter plugin entry point."""

    def filters(self):
        return {"waf_plugin_pick": waf_plugin_pick, "waf_plugin_check": waf_plugin_check}
