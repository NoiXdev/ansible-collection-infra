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
| `portainer` | Portainer server or agent; an agent can register itself as an environment on a server through its API (`portainer_agent_register_url`, `portainer_agent_register_api_token`, see the role's argument specs) |
| `dashy` | Dashy start page from configuration, behind Traefik |
| `dns` | CoreDNS for internal names on private addresses, forwarding the rest |
| `harbor` | Harbor registry behind Traefik, with safe upgrades and backup scripts |
| `cloudpanel` | CloudPanel installed and kept updated: CloudPanel and system updates, reboots when required, health checks, error pages and a maintenance switch |
| `listmonk` | listmonk newsletters with PostgreSQL, taking over an existing installation in place, with a database dump before every change and a restore when a change fails |
| `paperless` | Paperless-ngx v3 with PostgreSQL, Tika and an SMB2+ scanner share behind Traefik, with a one-time import of an old installation, a dump and file snapshot before every update, and a rollback when an update fails |
| `tandoor` | Tandoor Recipes 2 with PostgreSQL behind Traefik, with local or S3 media, invite-only users, a dump and media copy before every update, and a rollback when an update fails |
| `n8n` | n8n 2 with PostgreSQL behind Traefik, in normal or queue mode, with the owner and the encryption key from variables, a dump and a copy of the n8n home before every update, and a rollback when an update fails |
| `vaultwarden` | Vaultwarden, a password vault for the official Bitwarden apps, behind Traefik with SQLite or PostgreSQL (its own or yours), signups off, the admin page only with a hashed token, a backup before every update, and a rollback when an update fails |
| `graylog` | Central log server: inputs for container and host logs on private or public addresses or a domain with TLS, retention, a backup before every update and a rollback when one fails |
| `anubis` | Anubis proof-of-work bot protection: add `anubis@file` to a single Traefik router's or a whole entrypoint's middlewares (any number of domains), or use it from nginx on its own internal network (mailcow's nginx with `mailcow_anubis_url`), or from the host's own nginx on `127.0.0.1` only (host mode, the `nginx` role's sites with `anubis: true`), one of the three per host; TLS entrypoints only (its cookies are Secure), with TLS set on the entrypoint as the `traefik` role does, or set `COOKIE_SECURE` through `anubis_env`. Own policy, required redirect domains, a signing key that survives restarts, and new settings tried in a throwaway container before they replace the running Anubis; while Anubis is down, every protected router fails closed (500), so the role health-checks it on every run. **Traefik mode replaces every 401 from behind `anubis@file`** (the backend's, the router's own middlewares' such as `basicAuth`, also on paths the policy ALLOWs) with Anubis's answer (the challenge page for a browser), `WWW-Authenticate` and body included: routers whose legitimate clients get a 401 (container registries, Basic auth, token APIs, SPAs that answer 401) must not use it, and entrypoint mode suits only entrypoints without such routers. nginx and host mode pass upstream 401s through. **Redirect mode** (traefik mode, `anubis_public_url` set to the Anubis host's own `https://` URL, with `anubis_cookie_domain` and a required `anubis_private_key`) avoids this: Anubis answers on its own host and sends the browser back, so 401s pass through unchanged. The protected apps must be served over HTTPS as well, and DNS and the certificate of the Anubis host are yours to provide; existing setups without `anubis_public_url` are unchanged |
| `waf` | Web application firewall per site, in front of Traefik routers (the role writes a router per site, or a router of yours uses `waf@file`) or in front of the host's own nginx (host mode on `127.0.0.1` only, for the `nginx` role's sites with `waf: true`), one of the two per host. A new site starts in `detect` (matches are logged, nothing is blocked); `noix-waf-report` lists each site's matched rules with counts and example requests, and a site switches to `block` once its log is clean (`off` forwards without inspection, for emergencies). Per site: paranoia level, anomaly thresholds, extra methods and content types, how much of a request body is inspected (in `block` a larger body answers 413, so nothing passes uninspected), paths without inspection, rule exclusions scoped to a path prefix and optional CRS rule-exclusion plugins per site; a crafted `/v2/../admin` is matched as `/admin`. Anubis (`anubis@file` in the router's middlewares, or the nginx site's `anubis`) checks before the WAF. The log holds no request headers or bodies, and headers and cookies that carry credentials are not inspected. New settings are tested in a throwaway container before they replace the running WAF; while the WAF is down, its sites fail closed (504 behind Traefik, 502 on the host's nginx), never served uninspected. Response bodies are not inspected |
| `mailcow` | mailcow dockerized installed or taken over in place, kept on the latest stable release with a full backup before every update, a daily backup timer and health checks; a failed update leaves a marker that stops further runs and keeps its backup until removed; `/admin` and `/rspamd/` only from allowed networks, noix error pages, an integrated Roundcube kept on the newest release of its series; optionally Anubis in front of the web UI (`mailcow_anubis_url`, after the `anubis` role in nginx mode), with mail clients let through by its policy and every checked request failing closed while Anubis is down |
| `backrest` | Backrest (restic with a web UI) as a systemd service: apps' files and PostgreSQL or command dumps to an S3 repository on a schedule with retention, prune and check; an app that fails is left out of its snapshot while the healthy apps are saved, the backup then shows as failed and a report goes out (Discord or Healthchecks); the run fails when the last good backup is too old |
| `error_pages_export` | Internal: static export of the noix error pages, used by `cloudpanel`, `mailcow` and `nginx` (not meant to be run on its own) |
| `docker_check` | Internal: checks for the Docker CLI, the compose plugin and a running daemon, included first by every role that runs on Docker (not meant to be run on its own) |
| `pulsix_manager` | Pulsix manager, database and any number of local workers |
| `pulsix_worker` | Any number of remote Pulsix workers, enrolled with one-time tokens |
| `pulsix_agent` | Pulsix agent installed and enrolled with a pinned version, and on request the removal of Netdata, the Zabbix agent and the Checkmk agent once the agent is connected |
| `fail2ban` | fail2ban on the systemd journal with nftables bans |
| `crowdsec` | CrowdSec agent and its firewall bouncer, which also covers published Docker ports |
| `oh_my_zsh` | zsh with one shared, pinned Oh My Zsh checkout and a managed `~/.zshrc` per user, with the noix theme or your own |
| `motd` | Login banner in `/etc/update-motd.d` with a title, your own lines and system information |
| `nodejs` | Node.js from NodeSource, one pinned major series, with global npm packages at exact versions |
| `php` | PHP versions from packages.sury.org (Ubuntu 24.04 and 26.04) with one PHP-FPM master per pool on a socket without a version in its path, an optional classic mode, and a rolling restart of the pools after security updates |
| `composer` | Composer from the official phar at a pinned version and SHA-256, Composer 1 on request, and per-user `auth.json` (0600, written as the user) |
| `nginx` | nginx from nginx.org, pinned to a stable series, with PHP-pool, proxy and static sites, Let's Encrypt, hardening, Basic auth, rate limits, error pages, optional Anubis, an optional WAF per site (`waf: true`) and optional caching through the `varnish` role per site (`varnish: true`) |
| `redis` | Redis from packages.redis.io, pinned to a series, as the default instance or one instance per environment on a port or a unix socket |
| `varnish` | Varnish Cache from Varnish Software's repository, pinned to a series, as a cache in front of the `nginx` role's sites (`varnish: true`): only what the app marks cacheable is stored, unless a site sets a short microcache; per-site profiles for Shopware 6.7 and TYPO3, stale pages while the app is down, and PURGE and BAN from the host with each site's own token, acting on that site only |
| `mariadb` | MariaDB from mariadb.org, pinned to a series, with databases and users whose password and exact privileges are enforced |
| `mysql` | MySQL Community Server from MySQL's apt repository (amd64 only), pinned to a series, with databases and users whose password and exact privileges are enforced |

## Install

```yaml
# requirements.yml
collections:
  - name: https://github.com/NoiXdev/ansible-collection-infra.git
    type: git
    version: v0.6.0
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
