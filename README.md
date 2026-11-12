# noixdev.infra

[![ci](https://github.com/NoiXdev/ansible-collection-infra/actions/workflows/ci.yml/badge.svg)](https://github.com/NoiXdev/ansible-collection-infra/actions/workflows/ci.yml)
[![Latest tag](https://img.shields.io/github/v/tag/NoiXdev/ansible-collection-infra?label=release)](https://github.com/NoiXdev/ansible-collection-infra/tags)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Ansible roles for Docker-based Ubuntu servers. They replace a pile of one-off
playbooks with roles that are configured only through validated variables and
tested end to end, including a second run that must change nothing.

**Documentation: <https://docs.noix.dev/infra-collection/>**

Installation, a guide for every role, the variable reference and the changelog
are on the documentation site.

## Roles

| Role | Purpose |
|---|---|
| `base` | Packages, time zone, unattended upgrades, swap, journald limit, sshd hardening |
| `docker` | Docker CE with the compose plugin and a managed `daemon.json` |
| `tailscale` | Tailscale node, optionally a subnet router |
| `traefik` | Standalone Traefik with DNS-01 certificates, a Docker socket proxy and optional error pages |
| `portainer` | Portainer server or agent |
| `dashy` | Dashy start page from configuration, behind Traefik |
| `dns` | CoreDNS for internal names on private addresses, forwarding the rest |
| `harbor` | Harbor registry behind Traefik, with safe upgrades and backup scripts |
| `cloudpanel` | CloudPanel installed and kept updated: CloudPanel and system updates, reboots when required, health checks, error pages and a maintenance switch |
| `pulsix_manager` | Pulsix manager, database and any number of local workers |
| `pulsix_worker` | Any number of remote Pulsix workers, enrolled with one-time tokens |
| `fail2ban` | fail2ban on the systemd journal with nftables bans |
| `crowdsec` | CrowdSec agent and its firewall bouncer, which also covers published Docker ports |

## Install

```yaml
# requirements.yml
collections:
  - name: https://github.com/NoiXdev/ansible-collection-infra.git
    type: git
    version: v0.4.0
```

```bash
ansible-galaxy collection install -r requirements.yml
```

Requires `ansible-core` 2.16 or newer. See the
[documentation](https://docs.noix.dev/infra-collection/) for the first playbook.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Report vulnerabilities as described in
[SECURITY.md](SECURITY.md).

## License

[MIT](LICENSE)
