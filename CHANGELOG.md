# Changelog

## Unreleased

- `dns`: new role that runs CoreDNS on the host network. It answers `dns_records` (names with
  IPv4 and IPv6 addresses, `dns_ttl`) for the clients in `dns_allow` (all others are REFUSED) and
  forwards everything else to `dns_upstreams`, cached for `dns_cache` seconds. Records are served
  from a managed hosts file (not the host's `/etc/hosts`), and changes to them apply without a
  restart. It binds only `dns_bind` (wildcard addresses are refused), plus the node's Tailscale
  addresses with `dns_bind_tailscale`. Further variables: `dns_image`, `dns_dir`, `dns_project`,
  `dns_log_queries`, `dns_cpus`, `dns_memory`. The container is read-only without capabilities
  except `NET_BIND_SERVICE` and cannot gain privileges, and is recreated when the Corefile or
  the compose file changes.
  `dns_allow` must not contain `0.0.0.0/0` or `::/0`.
- `base`: `base_nonlocal_bind` (and `base_sshd_listen_addresses`) now also sets
  `net.ipv6.ip_nonlocal_bind`, so services can bind IPv6 addresses that are not up yet. It is
  skipped on a kernel without IPv6 (`ipv6.disable=1`).
- `traefik`: `traefik_acme_challenge: http` issues certificates with HTTP-01 on
  `traefik_acme_http_entrypoint` (an entrypoint on host port 80), one per router host, without a
  DNS API. The cert resolver is named after the challenge (`dns` or `http`); `dns` stays the
  default.
- `base`: the static route unit is started by the role itself, not only by a handler, so a run
  that failed after writing the script no longer leaves the routes unapplied.

## 0.3.0 — 2026-11-10

- `traefik`: entrypoints take `host_port`, the port published on the host (default: `port`), so
  two entrypoints can share a host port on different bind addresses. A redirect to such an
  entrypoint goes to its `host_port`.
- `traefik`: entrypoints take `middlewares`, which every router on the entrypoint gets; not
  allowed together with `redirect_to`.
- `traefik`: `traefik_docker_allow_empty_services` sets the Docker provider's
  `allowEmptyServices`, so containers without a healthy server keep their router (Traefik v3 answers them with 500, not 503).
- `traefik`: optional error pages (`traefik_error_pages_*`, off by default). The role writes
  `dynamic/error-pages.yml` with the middlewares `error-pages-errors` and
  `error-pages-compress`, which it attaches to the listed entrypoints, routers that answer with
  a fixed page (catch-all for unknown hosts, guards for names that must not be served on an
  entrypoint) and the service `error-pages`. Turning the feature off removes the file after
  Traefik has restarted without the middlewares.
- `traefik`: the error pages container (`traefik_error_pages_image`, default
  `noixdev/error-pages:1`) runs in the Traefik compose project as service `error-pages`:
  read-only, as 65532, without capabilities, with the image's healthcheck, CPU and memory limits
  and a volume on `/data` for maintenance mode. `traefik_error_pages_env` sets its environment
  (default theme `glass`, languages `en,de`). With `traefik_error_pages_container: false` it is
  not run and `traefik_error_pages_url` points at a service elsewhere.

## 0.2.0 — 2026-11-10

- Role `fail2ban`: journal backend, nftables bans, `sshd` and `recidive` jails, extra jails.
- Role `crowdsec`: CrowdSec and the iptables firewall bouncer from the official repository
  (key fingerprint checked), collections, acquisitions, allowlist parser, `INPUT` and
  `DOCKER-USER` chains, optional console enrollment.
- Shared `security_allowlist`, read by `fail2ban` and `crowdsec`, so management networks are
  never banned; entries are checked to be IP addresses or CIDRs.
- `base`: the sshd hardening drop-in now also enforces public-key-only authentication, connection
  and session limits, client keepalives, no agent forwarding, tunnels or gateway ports,
  `LogLevel VERBOSE` and modern key exchange, cipher and MAC lists. New variables
  `base_sshd_permit_root_login`, `base_sshd_allow_users`, `base_sshd_allow_tcp_forwarding` and
  others; see the role's argument specs.
- Roles `base`, `docker`, `tailscale`, `traefik`, `portainer`, `pulsix_manager`, `pulsix_worker`.
- Supported on Ubuntu 24.04 and 26.04; host roles are tested on both (`tests/host/run.sh`).
