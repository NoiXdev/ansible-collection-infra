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
#     CHANGELOG.md and the single `version:` line of galaxy.yml changed (the version
#     bump of CONTRIBUTING.md's "Releasing"), so the tested code is exactly
#     the released code.
#
# The checks live in attest_carry.py beside this script (its `verify`), which
# tests/attest.sh shares. The tested note: its SSH signature (namespace
# noixdev-infra-tests) against .github/tests-allowed-signers as of the RELEASE
# commit, not a dry run, its commit and tree are the tested commit's, every
# entry that ran passed (failed is 0), a Docker version when anything ran, it
# finished at most 30 days ago, and every entry of tests/all.sh AT THE TESTED
# COMMIT (each suite of all_suites, host and services once per release as
# host-<release> and services-<release>) appears exactly once, ran or carried.
# A carried entry is proven from the note of its carriedFrom commit C, never
# from the tested note's word: C is an ancestor of the tested commit, its
# note passes the same note checks, the entry ran and passed there at most 30
# days ago, no valid note between C and the tested commit ran it again, and no
# file changed since C is shared, unmatched or of the entry's suite in
# tests/suites.conf at the tested commit; galaxy.yml changed in its single
# version: line only is no change there, as for the version bump above
# (attest_carry.py version_only). Schema 1 notes (everything ran)
# still pass. Needs full history and refs/notes/tests fetched
# (git fetch origin '+refs/notes/tests:refs/notes/tests'), git, ssh-keygen and
# python3. Exit 0 = release allowed.
set -euo pipefail

NOTES_REF=refs/notes/tests
here="$(cd "$(dirname "$0")" && pwd)"

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
  # The rule the plan and the carry checks use too (attest_carry.py version_only).
  if ! python3 -I "$here/attest_carry.py" version-only --repo . --from "$tested" --to "$release" >/dev/null; then
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

# Prints the ::error:: lines or the OK line; its exit status is the check's.
exec python3 -I "$here/attest_carry.py" verify --repo . --tested "$tested" --release "$release" \
  --notes-ref "$NOTES_REF" --now "$(date +%s)"
