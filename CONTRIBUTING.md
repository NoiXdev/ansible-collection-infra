# Contributing

Thanks for your interest in `noixdev.infra`! This short guide helps you get started.
User documentation lives at <https://docs.noix.dev/infra-collection/>.

## Setup

You need `ansible-core` 2.16 or newer, [ansible-lint](https://ansible.readthedocs.io/projects/lint/),
and Docker (the end-to-end tests start privileged containers).

```bash
pip install ansible-core ansible-lint
ansible-galaxy collection install community.docker community.general ansible.posix ansible.mysql
```

Run the checks before you push. The Docker test suites run on your machine only, not
in CI:

```bash
ansible-lint                     # configured in .ansible-lint (production profile)
shellcheck tests/**/*.sh         # the test scripts; CI also checks the stubs (ci.yml)
tests/all.sh                     # the Docker test suites, one after the other
tests/all.sh mailcow listmonk    # only the named suites
tests/all.sh host-24.04          # or entries by label (host-<release>, services-<release>)
UBUNTU=24.04 tests/services/run.sh  # the service roles, on their own (also UBUNTU=26.04)
```

`tests/all.sh` runs the suites `e2e` (`tests/run.sh`, the container roles in Docker-in-Docker),
`host` (`tests/host/run.sh` on Ubuntu 24.04 and 26.04, set `HOST_UBUNTU` for fewer),
`harbor`, `listmonk`, `paperless`, `tandoor`, `n8n`, `anubis`, `mailcow`, `cloudpanel`, `pulsix_agent`, `backrest`, `vaultwarden`, `postal`, `waf`, `varnish` and `graylog` (`tests/<suite>/run.sh`). It stops at
the first failing suite unless you pass `--keep-going`, and ends with a summary of each
suite's result and runtime; the output of each suite is also in
`tests/output/all/<suite>.log`. `--summary FILE` writes a machine-readable summary, one line
per run (`<label> <pass|fail|skipped> <seconds>[ <note>...]`). The `harbor` suite needs amd64 images: its test host
runs natively, and on another architecture (an arm64 Mac) the Harbor images inside it
run as `linux/amd64` under emulation, which is slow. Docker Desktop on Apple silicon needs
Rosetta 2 (`softwareupdate --install-rosetta`) and a restart; the suite and `tests/attest.sh`
check this first. The `pulsix_agent` suite runs a stub agent and manager, but its
`release_match` scenario downloads the pinned Pulsix release and needs network access. The
`backrest` suite downloads the pinned Backrest release, runs MinIO and PostgreSQL beside it and
checks Ubuntu 24.04 and 26.04 in one entry (`BACKREST_UBUNTU` for fewer); the
`vaultwarden` suite does the same with Traefik and PostgreSQL (`VAULTWARDEN_UBUNTU`,
`NOIXDEV_INFRA_VAULTWARDEN_TESTS` picks scenarios). The `postal`
suite runs Postal with Traefik and Mailpit on Ubuntu 24.04 and 26.04 (`POSTAL_UBUNTU` for fewer,
`NOIXDEV_INFRA_POSTAL_TESTS` picks scenarios); Postal's image is amd64 only, so on another
architecture it runs under emulation like Harbor's. The `waf`
suite runs Traefik, Anubis, nginx and PHP beside the WAF on a systemd test host with Docker
inside, sends its attack payloads only to its own containers there, publishes no port on your
machine and checks Ubuntu 24.04 and 26.04 in one entry (`WAF_UBUNTU` for fewer,
`NOIXDEV_INFRA_WAF_TESTS` picks scenarios). The
`varnish` suite installs Varnish Software's packages from their repository (network access) and
checks Ubuntu 24.04 and 26.04 in one entry (`VARNISH_UBUNTU` for fewer): the cache scenarios put
a small backend behind Varnish, the `nginx` and `waf` scenarios run the php, varnish, nginx and
waf roles on one host with Docker inside (WebSocket upgrades, the path around a stopped Varnish,
the nginx run's refusals). The
`graylog` suite runs Graylog with Traefik on a systemd test host with Docker inside and checks
Ubuntu 24.04 and 26.04 in one entry (`GRAYLOG_UBUNTU` for fewer, `NOIXDEV_INFRA_GRAYLOG_TESTS`
picks scenarios). The
`mailcow` suite needs network
access and about 5 GB of images, `paperless` about 4 GB of images and half an hour
(`NOIXDEV_INFRA_PAPERLESS_TESTS` picks scenarios), `tandoor` about 2 GB and `n8n` about 3 GB of images, `cloudpanel` runs CloudPanel's real installer.
`tests/services/run.sh` (nodejs, redis, mariadb, mysql, php, composer, nginx) is part of `tests/all.sh` as the
`services` suite, once per Ubuntu release (`SERVICES_UBUNTU`), so the signed run has the entries
`services-24.04` and `services-26.04`; run it on its own with `UBUNTU=24.04` or `UBUNTU=26.04`.
On Apple silicon the mysql role runs under emulation without a working `mysql.service`, so the
suite uses a `systemctl` shim there and its entry carries the note "mysql via systemctl shim"
(shown in the `tests/local` status and the release check's OK line). A real amd64 mysql run
stays a manual step of the owner before a release.

Each test converges the roles, converges again (the second run must change nothing),
and then verifies the result. `KEEP=1` leaves the test container running for
inspection.

A suite sources `tests/lib/suite.sh`, links the collection with `noix_link_collection`, calls
`noix_exit_guard` near the top and `noix_done` at its end and before any intended `exit 0`.
Without `noix_done`, macOS bash 3.2 would exit 0 on a `set -u` error under the EXIT trap, and a
broken run would look green.

CI (GitHub Actions) runs `ansible-lint`, `shellcheck` and the self-test of the attestation
(`tests/attest/selftest.sh`, no Docker) only.

### Signed test run

A release needs proof that every suite passed on the released code. `tests/attest.sh`
gives it: it runs what needs running, carries the rest from an earlier signed run, and
signs the result for the commit.

```bash
git push                         # the commit has to be on GitHub first
tests/attest.sh --plan           # what would run or be carried; runs and signs nothing
tests/attest.sh                  # runs the entries that need it, signs, publishes
tests/attest.sh --all            # runs every entry, carries nothing
```

`--plan` runs and signs nothing, but it still replaces your local `refs/notes/tests` with
origin's first, so the plan sees what the release check will see. A note that exists only
locally (for example from a run whose push was refused) is dropped.

The entries are those of `tests/all.sh`: each suite, `host` once per release as `host-<release>`
and `services` once per release as `services-<release>`. For each entry it either runs or
carries it from the newest valid, signed run of an ancestor of HEAD that RAN it. It runs when
any of these holds: a file of its suite changed since that run; that run was red; that run
is older than 28 days; a shared path changed; a changed file is in no section of the map.
HEAD's own red run counts. `--plan` prints one line per entry, `run <reason>` or
`carry from <sha7> (<N> days)`. A commit that changes only ignored files (such as
`CHANGELOG.md`) is attested without running anything and without Docker.

The map is `tests/suites.conf`, read by `.github/scripts/attest_carry.py`. Its sections are
`[ignore]` (files that touch no suite), `[shared]` (every suite) and `[suite <name>]` (the
suite's test files, the roles its playbooks converge, including the roles they pull in, and the
fixtures it reads). A changed file is matched in this order: ignore, shared, suites, and no
match means all suites. An ignore pattern matches segment by segment, and `check-map` accepts
only narrow ignore patterns. `tests/suites.conf`, `tests/all.sh`, `tests/attest.sh`,
`tests/attest/`, `tests/lib/` and `.github/scripts/` always mean all suites, whatever the map
says. A new suite or role needs a map entry; check it with:

```bash
python3 -I .github/scripts/attest_carry.py check-map --repo . --commit HEAD
```

It checks that every suite has a section, every role is in some suite, and each suite lists
every role that its roles and test files reference as `noixdev.infra.X`. CI runs it in the
selftest, and `tests/attest.sh` runs it first.

It refuses to start while a variable that narrows or changes what the suites run is set
(`HOST_UBUNTU`, `SERVICES_UBUNTU`, `UBUNTU`, `KEEP`, `STUB_ONLY`, `NOIXDEV_INFRA_SERVICES`,
`NOIXDEV_INFRA_N8N_TESTS`, `NOIXDEV_INFRA_PAPERLESS_TESTS`, `NOIXDEV_INFRA_TANDOOR_TESTS`,
`NOIXDEV_INFRA_MAILCOW_DOCKER_VOLUME` and the others in `coverage_knobs` of `tests/attest.sh`;
a new suite knob belongs there). It needs a clean working tree
(untracked files included), HEAD on a branch of `origin`, Docker,
`python3`, `ssh-keygen`, `gh` logged in (`gh auth login`) and an SSH signing key:
`TESTS_SIGNING_KEY`, else `git config user.signingkey`, else `~/.ssh/id_ed25519.pub` (a
`.pub` file signs through the SSH agent; a `key::` literal is not supported). The signer is
`TESTS_SIGNER`, else `git config user.email`. It refuses to publish when HEAD moved or the
working tree is not clean at the end of the run (it compares the end state only).

It publishes, for HEAD, a git note under `refs/notes/tests` (the payload, one JSON line in
base64, schema 2: commit, tree, signer, each entry that ran with its result, runtime and notes,
each carried entry with the commit it was carried from, the counts, architecture, OS,
Docker version and times; no host names, user names or paths) with an SSH signature over it
(`ssh-keygen -Y sign`, namespace `noixdev-infra-tests`), and a commit status `tests/local`
(success or failure, reading "<ran> ran, <passed> passed, <failed> failed, <carried> carried (...)"). A red run is published too and exits 1. Before it
pushes, it replaces the local `refs/notes/tests` by `origin`'s, so a note that exists only
locally is dropped, never pushed.

The tag workflow `release-gate.yml` (check "tests attestation") runs
`.github/scripts/verify-tests-attestation.sh` on the tagged commit and flags a tag without a
green attestation; it cannot stop the tag, so run the check before tagging. The check accepts
schema 1 and schema 2 notes and verifies the signature against `.github/tests-allowed-signers`
of that commit. It refuses dry-run results and results without a Docker version, and requires a
green result that covers `tests/all.sh` at the tested commit: every suite in `all_suites` by its
exact label, the `host` suite as `host-<release>` for each release in `host_releases` and
`services` as `services-<release>`. Every entry, the ones that ran included, is at most 30
days old when the check runs (the age is measured at check time, so a release check can fail
days after a good run); `tests/attest.sh` therefore carries an entry only while its source is
younger than 28 days. Each carried entry is re-verified against the signature of its source
note, using the release commit's allowed-signers file: the source is an ancestor, the entry ran
and passed there, no newer valid run ran it, no relevant file changed since, and the source is
at most 30 days old at check time. When anything is carried, the check also runs `check-map`
at the tested commit. The tested commit is the tagged commit itself or, when that has no note,
its parent, if only `CHANGELOG.md` and the `version:` line of `galaxy.yml` differ between them.

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

Maintainers cut a release with the `release` workflow:

1. Attest the last commit before the bump, once it is on `main` and CI is green: run
   a real amd64 mysql test by hand first when the run would use the systemctl shim,
   then `tests/attest.sh`, and push the notes. Do not attest the bump commit itself: it
   always changes `galaxy.yml`, a shared file, so that would rerun every entry (hours).
2. Make sure `## Unreleased` in `CHANGELOG.md` has the entries of the release.
3. Run the workflow `release` from the Actions tab on `main`: first with `dry_run` on (the
   default), read its summary, then again with `dry_run` off. `bump` is `patch`, `minor`
   (the default) or `major`. One release runs at a time.

What the workflow checks, in this order, before it writes anything:

- It runs on `main`, and `ci.yml` has a green push run for that exact commit.
- For a real run, the webhook is an organization secret named
  `DISCORD_WEBHOOK_RELEASE_NOTIFICATION`, shared with this repository (no environment is
  needed; a variable is not read, as variables show unmasked in the logs). A real run refuses
  without it, so a release is never left unannounced.
- The version in `galaxy.yml` has its tag `vX.Y.Z`. If it has none, an earlier release
  stopped half-way and the workflow refuses to bump past it (see below).
- The shapes it edits can be placed: `## Unreleased` is there once and is the first
  `## ` heading, it has at least one entry (blank lines and an HTML comment do not
  count), the new version's heading is not there yet, and `README.md` has exactly one
  install example with a `version: v…` line.
- The release check (`.github/scripts/verify-tests-attestation.sh`) accepts the guarded
  commit, and then accepts the local bump commit, whose tree it records.

A dry run stops here and writes nothing. A real run then:

1. Creates the bump commit `chore: bump the collection to X.Y.Z` on `main` through the
   API (a verified commit, and only if `main` has not moved since the checks). It changes
   only `CHANGELOG.md` and the `version:` line of `galaxy.yml`: the heading
   `## X.Y.Z — YYYY-MM-DD` (UTC date of the run) goes under a new empty `## Unreleased`.
   Its tree must equal the tree that passed the check.
2. Creates the lightweight tag `vX.Y.Z` on it, together with the GitHub release of the same
   name. The release text is the version's changelog section, cut at a line boundary if it
   would pass 60 000 bytes, with a pointer to `CHANGELOG.md`.
3. Commits `docs: point the install example at vX.Y.Z` (the install example of
   `README.md`).
4. Posts the release to Discord, last.

The tag and the commits are made with the workflow's own token, so they start no further
workflow: the tag does not run `release-gate.yml`, because the workflow ran the same check
before tagging, and the README commit, the new head of `main`, has no `ci.yml` run until the
next push. The next release needs a new `## Unreleased` entry anyway, and that push runs CI.

### When a run stops half-way

The error message of the `publish` job says what exists: the bump commit, the tag and
release, the README commit. Finish what is missing by hand, as in "Releasing by hand"
(revert the bump commit, or tag it after checking its tree, or create the release for the
tag, or bump the README install example). If only the README commit failed, the
announcement still goes out and the run turns red afterwards. If only the Discord post
failed, everything else is complete and the final step says so: post it by hand.
Re-running a failed publish never writes twice: when the bump commit or the tag is
already there, the commit step fails and its message names what it found (after "Re-run
failed jobs", an earlier attempt of the run may have created it); it says "nothing was
written" only when it found neither. The workflow never repeats a step past what exists:
when `galaxy.yml` on `main` has a version without a tag, it refuses to bump again, and the
fix is to finish the previous release by hand. A failed Discord post does not undo the
release.

### Releasing by hand

1. Attest the last commit before the bump as in step 1 above.
2. Bump `version` in `galaxy.yml`.
3. Move the entries of `CHANGELOG.md` from *Unreleased* under the new version.
4. Commit (`chore: bump the collection to X.Y.Z`) on `main` and push it. The bump commit
   may change only `CHANGELOG.md` and the `version:` line of `galaxy.yml`, so that the
   gate accepts the note of its parent.
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
