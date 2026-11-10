# Changelog

## Unreleased

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
