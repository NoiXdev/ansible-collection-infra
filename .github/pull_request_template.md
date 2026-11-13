## Summary

<!-- What does this PR change, and why? -->

## Type of change

- [ ] Bug fix
- [ ] New feature, role or variable
- [ ] Refactor / chore
- [ ] Documentation

## Checklist

- [ ] `ansible-lint` passes
- [ ] `tests/all.sh` (or the suites of the roles the change touches) passes locally; CI runs lint and shellcheck only (a release needs `tests/attest.sh`, the signed full run)
- [ ] New variables have an argument spec and a default
- [ ] The second converge changes nothing (idempotent)
- [ ] No private values (hosts, addresses, domains, tokens) in the change
- [ ] Commit messages follow [Conventional Commits](https://www.conventionalcommits.org/)
- [ ] History is linear: this branch is rebased on `main`

## Related issues

<!-- Closes #123, refs #456 -->
