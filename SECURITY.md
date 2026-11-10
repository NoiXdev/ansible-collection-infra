# Security

We take the security of this collection seriously. Thank you for reporting
vulnerabilities responsibly.

## Reporting a vulnerability

Please report security issues **privately** by email to **security@noix.dev**, not
through public GitHub issues. You can also
[open a private security advisory](https://github.com/NoiXdev/ansible-collection-infra/security/advisories/new)
if you prefer to stay on GitHub.

To help us respond quickly, please include:

- a description of the vulnerability and its potential impact,
- step-by-step reproduction instructions (proof of concept),
- the affected collection version or tag, the role, and the target OS release.

**Redact before you send.** Hostnames, addresses, inventory and credentials from
your setup are not needed to reproduce a report.

## Process

- **Initial response:** typically within 3 business days.
- We confirm receipt, assess the report and keep you updated on progress.
- Once a fix is ready, we coordinate disclosure with you. On request, we credit you
  as the reporter.

Please give us reasonable time to fix the issue before any details are made public.

## Supported versions

Security updates are provided for the latest release and the `main` branch.

## Scope notes

The roles change the security posture of the servers they run on: sshd
hardening, fail2ban and CrowdSec bans, firewall rules, and secrets such as
tokens and keys that are written to disk. Reports that show a role leaking a
secret (in output, logs or file permissions), weakening a setting without
saying so, or letting a ban lock out an allowlisted address are especially
welcome.
