# Changelog

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
