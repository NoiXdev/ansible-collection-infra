# Contributing

Thanks for your interest in `noixdev.infra`! This short guide helps you get started.
User documentation lives at <https://docs.noix.dev/infra-collection/>.

## Setup

You need `ansible-core` 2.16 or newer, [ansible-lint](https://ansible.readthedocs.io/projects/lint/),
and Docker (the end-to-end tests start privileged containers).

```bash
pip install ansible-core ansible-lint
ansible-galaxy collection install community.docker community.general ansible.posix
```

Run the checks before you push. The Docker test suites run on your machine only, not
in CI:

```bash
ansible-lint                     # configured in .ansible-lint (production profile)
shellcheck tests/**/*.sh         # the test scripts; CI also checks the stubs (ci.yml)
tests/all.sh                     # every Docker test suite, one after the other
tests/all.sh mailcow listmonk    # only the named suites
```

`tests/all.sh` runs `e2e` (`tests/run.sh`, the container roles in Docker-in-Docker),
`host` (`tests/host/run.sh` on Ubuntu 24.04 and 26.04, set `HOST_UBUNTU` for fewer),
`harbor`, `listmonk`, `anubis`, `mailcow` and `cloudpanel` (`tests/<suite>/run.sh`). It stops at
the first failing suite unless you pass `--keep-going`, and ends with a summary of each
suite's result and runtime; the output of each suite is also in
`tests/output/all/<suite>.log`. `--summary FILE` writes a machine-readable summary, one line
per run (`<label> <pass|fail|skipped> <seconds>`). The `harbor` suite needs amd64 images: its test host
runs natively, and on another architecture (an arm64 Mac) the Harbor images inside it
run as `linux/amd64` under emulation, which is slow. The `mailcow` suite needs network
access and about 5 GB of images, `cloudpanel` runs CloudPanel's real installer.

Each test converges the roles, converges again (the second run must change nothing),
and then verifies the result. `KEEP=1` leaves the test container running for
inspection.

CI (GitHub Actions) runs `ansible-lint`, `shellcheck` and the self-test of the attestation
(`tests/attest/selftest.sh`, no Docker) only.

### Signed test run

A release needs proof that every suite passed on the released code. `tests/attest.sh`
gives it: it runs `tests/all.sh --keep-going` (always every suite, `harbor` included) and
signs the result for the commit it ran on.

```bash
git push                         # the commit has to be on GitHub first
tests/attest.sh                  # takes the full run's time; no arguments
```

It refuses to start while a variable that narrows or changes what the suites run is set
(`HOST_UBUNTU`, `UBUNTU`, `KEEP`, `STUB_ONLY` and the others in `coverage_knobs` of
`tests/attest.sh`; a new suite knob belongs there). It needs a clean working tree
(untracked files included), HEAD on a branch of `origin`, Docker,
`python3`, `ssh-keygen`, `gh` logged in (`gh auth login`) and an SSH signing key:
`TESTS_SIGNING_KEY`, else `git config user.signingkey`, else `~/.ssh/id_ed25519.pub` (a
`.pub` file signs through the SSH agent; a `key::` literal is not supported). The signer is
`TESTS_SIGNER`, else `git config user.email`. It refuses to publish when HEAD moved or the
working tree is not clean at the end of the run (it compares the end state only).

It publishes, for HEAD, a git note under `refs/notes/tests` (the payload, one JSON line in
base64: commit, tree, signer, each suite's result and runtime, the counts, architecture, OS,
Docker version and times; no host names, user names or paths) with an SSH signature over it
(`ssh-keygen -Y sign`, namespace `noixdev-infra-tests`), and a commit status `tests/local`
(success or failure, with the counts). A red run is published too and exits 1. Before it
pushes, it replaces the local `refs/notes/tests` by `origin`'s, so a note that exists only
locally is dropped, never pushed.

The tag workflow `release-gate.yml` (check "tests attestation") runs
`.github/scripts/verify-tests-attestation.sh` on the tagged commit and flags a tag without a
green attestation; it cannot stop the tag, so run the check before tagging. The check verifies
the signature against `.github/tests-allowed-signers` of that commit, refuses dry-run results
and results without a Docker version, and requires a green result that covers `tests/all.sh`
at the tested commit: every suite in `all_suites` by its exact label, the `host` suite as
`host-<release>` for each release in `host_releases`. The tested commit
is the tagged commit itself or, when that has no note, its parent, if only `CHANGELOG.md`
and the `version:` line of `galaxy.yml` differ between them.

Owner setup, not done by the script: a maintainer's public key has to be listed in
`.github/tests-allowed-signers` (principal, `namespaces="noixdev-infra-tests"`, key);
optionally, branch protection on `main` can require the status `tests/local`.

## Guidelines

- Write code, comments, commit messages and documentation in English.
- **Every variable needs an argument spec.** Declare a new variable in the role's
  `meta/argument_specs.yml` (type, description, choices where they apply) and give it a
  default in `defaults/main.yml`. A variable without a spec is not accepted.
- New behaviour comes with tests: extend the converge and verify playbooks under `tests/`.
  A second converge must report no changes, so keep tasks idempotent.
- Secrets never reach the output or the command line: use `no_log` and files with
  restrictive modes.
- **No private values in this public collection.** No real host names, addresses,
  domains, e-mail addresses, tokens or keys, in roles, defaults, tests or docs. Use
  the documentation ranges (RFC 5737 for IPv4, RFC 3849 for IPv6) and `example.com`.
  `.github/tests-allowed-signers` is the one exception: it lists the maintainers' public
  signing keys.
- User-facing documentation is on the docs site, not in this repository. When you
  change behaviour or a variable, say so in the pull request so the docs can follow.
- Commit messages follow [Conventional Commits](https://www.conventionalcommits.org/)
  (`feat`, `fix`, `docs`, `refactor`, `perf`, `test`, `build`, `ci`, `chore`).
- Keep the history linear: rebase on `main` instead of merging it into your branch.

## Releasing

Maintainers cut a release like this:

1. Bump `version` in `galaxy.yml`.
2. Move the entries of `CHANGELOG.md` from *Unreleased* under the new version.
3. Commit (`chore: bump the collection to X.Y.Z`) on `main` once CI is green, and push it.
4. Run `tests/attest.sh` on the bump commit, unless you already attested its parent (the
   last commit before step 1). The bump commit may then change only `CHANGELOG.md` and the
   `version:` line of `galaxy.yml`.
5. Check the attestation locally:
   `git fetch origin '+refs/notes/tests:refs/notes/tests'` and
   `.github/scripts/verify-tests-attestation.sh HEAD` (exit 0 = release allowed).
6. Tag the commit `vX.Y.Z` and push the tag. The tag's check "tests attestation"
   (`release-gate.yml`) runs the same verification and flags the tag when it fails; it
   cannot stop the tag, which is why step 5 comes first.

Users install a release by its tag, so never move or reuse a tag. While the version is
0.x, a minor release may change variables; say so in the changelog.

## Reporting bugs and ideas

Use the issue templates. For security problems follow [SECURITY.md](SECURITY.md)
instead. By contributing you agree that your work is licensed under the
[MIT licence](LICENSE).
