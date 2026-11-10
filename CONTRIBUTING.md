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

Run the checks before you push:

```bash
ansible-lint                     # configured in .ansible-lint (production profile)
tests/run.sh                     # container roles, Docker-in-Docker
UBUNTU=24.04 tests/host/run.sh   # host roles on a systemd Ubuntu 24.04 container
UBUNTU=26.04 tests/host/run.sh   # host roles on Ubuntu 26.04
```

Each test converges the roles, converges again (the second run must change nothing),
and then verifies the result. `KEEP=1` leaves the test container running for
inspection. CI runs the same three jobs.

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
- User-facing documentation is on the docs site, not in this repository. When you
  change behaviour or a variable, say so in the pull request so the docs can follow.
- Commit messages follow [Conventional Commits](https://www.conventionalcommits.org/)
  (`feat`, `fix`, `docs`, `refactor`, `perf`, `test`, `build`, `ci`, `chore`).
- Keep the history linear: rebase on `main` instead of merging it into your branch.

## Releasing

Maintainers cut a release like this:

1. Bump `version` in `galaxy.yml`.
2. Move the entries of `CHANGELOG.md` from *Unreleased* under the new version.
3. Commit (`chore: bump the collection to X.Y.Z`) on `main` once CI is green.
4. Tag the commit `vX.Y.Z` and push the tag.

Users install a release by its tag, so never move or reuse a tag. While the version is
0.x, a minor release may change variables; say so in the changelog.

## Reporting bugs and ideas

Use the issue templates. For security problems follow [SECURITY.md](SECURITY.md)
instead. By contributing you agree that your work is licensed under the
[MIT licence](LICENSE).
