#!/usr/bin/env bash
# Release check: fails unless the commit about to be released carries a
# valid, green, SIGNED attestation of the local test run from tests/attest.sh.
# The tag workflow release-gate.yml runs it on a pushed v* tag, so it flags a
# tag without one (it cannot stop the tag); maintainers run it before tagging.
#
#   .github/scripts/verify-tests-attestation.sh <release-commit>
#
# Which commit must be attested:
#   - the release commit itself, when it has a note;
#   - otherwise its first parent, but only when between the two nothing but
#     CHANGELOG.md and the `version:` line of galaxy.yml changed (the version
#     bump of CONTRIBUTING.md's "Releasing"), so the tested code is exactly
#     the released code.
#
# Checks: the note's SSH signature (namespace noixdev-infra-tests) against
# .github/tests-allowed-signers as of the RELEASE commit, then the payload:
# not a dry run, a Docker version is recorded, its commit and tree are the
# tested commit's, failed is 0, passed > 0, every entry passed, and the
# entries cover tests/all.sh AT THE TESTED COMMIT: each suite of all_suites by
# its exact label, the host suite as host-<release> for each release of
# host_releases. Needs full history and refs/notes/tests
# fetched (git fetch origin '+refs/notes/tests:refs/notes/tests'), git,
# ssh-keygen and python3. Exit 0 = release allowed.
set -euo pipefail

NAMESPACE=noixdev-infra-tests
NOTES_REF=refs/notes/tests
SIGNERS=.github/tests-allowed-signers

error() {
  echo "::error::$*"
  exit 1
}

[ "$#" -eq 1 ] || {
  echo "usage: $0 <release-commit>" >&2
  exit 2
}
for tool in git ssh-keygen python3; do
  command -v "$tool" >/dev/null 2>&1 || error "$tool is required"
done

release="$(git rev-parse --verify --quiet "$1^{commit}")" || error "$1 is not a commit"
has_note() { git notes --ref="$NOTES_REF" show "$1" >/dev/null 2>&1; }

if has_note "$release"; then
  tested="$release"
elif parent="$(git rev-parse --verify --quiet "$release^1")"; then
  tested="$parent"
  extra="$(git diff --name-only --no-renames "$tested" "$release" | grep -vxE 'CHANGELOG\.md|galaxy\.yml' || true)"
  if [ -n "$extra" ]; then
    more=$(($(echo "$extra" | wc -l) - 10))
    files="$(echo "$extra" | head -n 10 | tr '\n' ' ')"
    [ "$more" -le 0 ] || files="$files(and $more more) "
    error "${release:0:7} has no tests attestation, and its parent ${tested:0:7} differs from it beyond CHANGELOG.md and the version: line of galaxy.yml: $files- attest ${release:0:7} itself."
  fi
  without_version() { git show "$1:galaxy.yml" 2>/dev/null | grep -v '^version:' || true; }
  if [ "$(without_version "$tested")" != "$(without_version "$release")" ]; then
    error "${release:0:7} has no tests attestation, and galaxy.yml changed beyond its version: line since its parent ${tested:0:7} - attest ${release:0:7} itself."
  fi
else
  tested="$release"
fi
if [ "$tested" = "$release" ]; then
  echo "release ${release:0:7}: needs a tests attestation for ${tested:0:7}"
else
  echo "release ${release:0:7}: version bump only, needs a tests attestation for its parent ${tested:0:7}"
fi

if ! has_note "$tested"; then
  [ "$tested" = "$release" ] || release_too=" (nor for the release ${release:0:7})"
  error "No tests attestation for ${tested:0:7}${release_too:-}. Run tests/attest.sh on that commit (see CONTRIBUTING.md), then re-run this check."
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
git notes --ref="$NOTES_REF" show "$tested" >"$work/note"
git show "$release:$SIGNERS" >"$work/allowed_signers" 2>/dev/null ||
  error "$SIGNERS is missing at ${release:0:7}"
git show "$tested:tests/all.sh" >"$work/all.sh" 2>/dev/null ||
  error "tests/all.sh is missing at ${tested:0:7}"

# extract NOTE DIR: writes DIR/payload.json and DIR/payload.json.sig, prints
#   the signer. check PAYLOAD TESTED TREE ALLSH: the signed payload's content.
read -r -d '' py <<'PY' || true
import base64, binascii, json, re, sys

def error(msg):
    print("::error::" + msg)
    sys.exit(1)

def load(path):
    try:
        with open(path, "rb") as f:
            data = json.loads(f.read().decode("utf-8"))
    except (ValueError, UnicodeDecodeError):
        error("The tests attestation payload is not valid JSON.")
    if not isinstance(data, dict):
        error("The tests attestation payload is not a JSON object.")
    return data

mode = sys.argv[1]
if mode == "extract":
    note_path, out = sys.argv[2:]
    lines = open(note_path, encoding="utf-8").read().splitlines()
    payloads = [l[len("payload: "):] for l in lines if l.startswith("payload: ")]
    if len(payloads) != 1:
        error("The tests attestation note has no single payload line.")
    try:
        payload = base64.b64decode(payloads[0].strip(), validate=True)
    except (binascii.Error, ValueError):
        error("The tests attestation payload is not valid base64.")
    begin = "-----BEGIN SSH SIGNATURE-----"
    end = "-----END SSH SIGNATURE-----"
    if lines.count(begin) != 1 or lines.count(end) != 1 or lines.index(begin) > lines.index(end):
        error("The tests attestation note has no single SSH signature.")
    signature = lines[lines.index(begin):lines.index(end) + 1]
    with open(out + "/payload.json", "wb") as f:
        f.write(payload)
    with open(out + "/payload.json.sig", "w", encoding="utf-8") as f:
        f.write("\n".join(signature) + "\n")
    signer = load(out + "/payload.json").get("signer")
    if not isinstance(signer, str) or not re.fullmatch(r"[^\s]+", signer):
        error("The tests attestation payload names no signer.")
    print(signer)

elif mode == "check":
    payload_path, tested, tree, allsh_path = sys.argv[2:]
    p = load(payload_path)
    if p.get("schema") != 1:
        error(f"Unknown tests attestation schema {p.get('schema')!r}.")
    if "dryRun" in p:
        error("The tests attestation is from a dry run (tests/attest.sh self-test mode), not a real run.")
    docker = p.get("docker")
    if not isinstance(docker, str) or docker.strip() in ("", "unknown"):
        error("The tests attestation records no Docker version, so the suites did not run on Docker.")
    commit = p.get("commit")
    if commit != tested:
        error(f"The tests attestation is for {str(commit)[:7]}, not {tested[:7]}.")
    if p.get("tree") != tree:
        error(f"The tests attestation's tree does not match {tested[:7]}.")
    suites, passed, failed = p.get("suites"), p.get("passed"), p.get("failed")
    if (not isinstance(suites, list) or type(passed) is not int or type(failed) is not int
            or not all(isinstance(e, dict) and isinstance(e.get("label"), str)
                       and isinstance(e.get("result"), str) for e in suites)):
        error("The tests attestation payload is malformed (suites, passed, failed).")
    not_passed = [e["label"] for e in suites if e["result"] != "pass"]
    if failed != 0 or passed <= 0 or not_passed:
        detail = f" (not passed: {' '.join(not_passed)})" if not_passed else ""
        error(f"The tests attestation for {tested[:7]} is red: {passed} passed, {failed} failed{detail}.")
    allsh = open(allsh_path, encoding="utf-8").read()
    def array(name):
        lines = re.findall(r"^" + name + r"=\(([^)]*)\)[ \t]*$", allsh, re.M)
        if len(lines) != 1 or not lines[0].split():
            error(f"tests/all.sh at {tested[:7]} has no single {name}=(...) line.")
        return lines[0].split()
    expected = []
    for suite in array("all_suites"):
        if suite == "host":
            expected += ["host-" + r for r in array("host_releases")]
        else:
            expected.append(suite)
    labels = {e["label"] for e in suites}
    missing = [l for l in expected if l not in labels]
    if missing:
        error(f"The tests attestation for {tested[:7]} does not cover every suite of tests/all.sh; "
              f"missing or not passed: {' '.join(missing)}.")
    labels = " ".join(e["label"] for e in suites)
    print(f"Tests attestation OK for {tested[:7]}, signed by {p['signer']}: "
          f"{passed} passed, {failed} failed ({labels}; {p.get('arch')}, {p.get('os')}, "
          f"finished {p.get('finishedAt')})")
PY

signer="$(python3 -I -c "$py" extract "$work/note" "$work")" || {
  # python printed the ::error:: line on stdout, which $(...) captured.
  echo "$signer"
  exit 1
}
if ! ssh-keygen -Y verify -f "$work/allowed_signers" -I "$signer" -n "$NAMESPACE" \
  -s "$work/payload.json.sig" <"$work/payload.json" >/dev/null; then
  error "The tests attestation signature for ${tested:0:7} does not verify for $signer (namespace $NAMESPACE) against $SIGNERS of ${release:0:7}."
fi
python3 -I -c "$py" check "$work/payload.json" "$tested" "$(git rev-parse "$tested^{tree}")" "$work/all.sh"
