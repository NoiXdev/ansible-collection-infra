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
| `listmonk` | listmonk newsletters with PostgreSQL, taking over an existing installation in place, with a database dump before every change and a restore when a change fails |
| `paperless` | Paperless-ngx v3 with PostgreSQL, Tika and an SMB2+ scanner share behind Traefik, with a one-time import of an old installation, a dump and file snapshot before every update, and a rollback when an update fails |
| `tandoor` | Tandoor Recipes 2 with PostgreSQL behind Traefik, with local or S3 media, invite-only users, a dump and media copy before every update, and a rollback when an update fails |
| `n8n` | n8n 2 with PostgreSQL behind Traefik, in normal or queue mode, with the owner and the encryption key from variables, a dump and a copy of the n8n home before every update, and a rollback when an update fails |
| `anubis` | Anubis proof-of-work bot protection: add `anubis@file` to a single Traefik router's or a whole entrypoint's middlewares (any number of domains), or use it from nginx on its own internal network (mailcow's nginx with `mailcow_anubis_url`), or from the host's own nginx on `127.0.0.1` only (host mode, the `nginx` role's sites with `anubis: true`), one of the three per host; TLS entrypoints only (its cookies are Secure), with TLS set on the entrypoint as the `traefik` role does, or set `COOKIE_SECURE` through `anubis_env`. Own policy, required redirect domains, a signing key that survives restarts, and new settings tried in a throwaway container before they replace the running Anubis; while Anubis is down, every protected router fails closed (500), so the role health-checks it on every run. **Traefik mode replaces every 401 from behind `anubis@file`** (the backend's, the router's own middlewares' such as `basicAuth`, also on paths the policy ALLOWs) with Anubis's answer (the challenge page for a browser), `WWW-Authenticate` and body included: routers whose legitimate clients get a 401 (container registries, Basic auth, token APIs, SPAs that answer 401) must not use it, and entrypoint mode suits only entrypoints without such routers. nginx and host mode pass upstream 401s through. A redirect mode with its own Anubis host (Anubis's `PUBLIC_URL` setup) would avoid this; it is not part of the role yet |
| `mailcow` | mailcow dockerized installed or taken over in place, kept on the latest stable release with a full backup before every update, a daily backup timer and health checks; a failed update leaves a marker that stops further runs and keeps its backup until removed; `/admin` and `/rspamd/` only from allowed networks, noix error pages, an integrated Roundcube kept on the newest release of its series; optionally Anubis in front of the web UI (`mailcow_anubis_url`, after the `anubis` role in nginx mode), with mail clients let through by its policy and every checked request failing closed while Anubis is down |
| `error_pages_export` | Internal: static export of the noix error pages, used by `cloudpanel`, `mailcow` and `nginx` (not meant to be run on its own) |
| `docker_check` | Internal: checks for the Docker CLI, the compose plugin and a running daemon, included first by every role that runs on Docker (not meant to be run on its own) |
| `pulsix_manager` | Pulsix manager, database and any number of local workers |
| `pulsix_worker` | Any number of remote Pulsix workers, enrolled with one-time tokens |
| `fail2ban` | fail2ban on the systemd journal with nftables bans |
| `crowdsec` | CrowdSec agent and its firewall bouncer, which also covers published Docker ports |
| `oh_my_zsh` | zsh with one shared, pinned Oh My Zsh checkout and a managed `~/.zshrc` per user, with the noix theme or your own |
| `motd` | Login banner in `/etc/update-motd.d` with a title, your own lines and system information |
| `nodejs` | Node.js from NodeSource, one pinned major series, with global npm packages at exact versions |
| `php` | PHP versions from the ondrej/php PPA (Ubuntu 24.04 only for now) with one PHP-FPM master per pool on a socket without a version in its path, an optional classic mode, and a rolling restart of the pools after security updates |
| `composer` | Composer from the official phar at a pinned version and SHA-256, Composer 1 on request, and per-user `auth.json` (0600, written as the user) |
| `nginx` | nginx from nginx.org, pinned to a stable series, with PHP-pool, proxy and static sites, Let's Encrypt, hardening, Basic auth, rate limits, error pages and optional Anubis |
| `redis` | Redis from packages.redis.io, pinned to a series, as the default instance or one instance per environment on a port or a unix socket |
| `mariadb` | MariaDB from mariadb.org, pinned to a series, with databases and users whose password and exact privileges are enforced |
| `mysql` | MySQL Community Server from MySQL's apt repository (amd64 only), pinned to a series, with databases and users whose password and exact privileges are enforced |

## Install

```yaml
# requirements.yml
collections:
  - name: https://github.com/NoiXdev/ansible-collection-infra.git
    type: git
    version: v0.5.0
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
