# noixdev.infra

Reusable Ansible roles for Docker-based Linux servers (Debian, Ubuntu).

Every role is configured only through variables. Each variable is documented in
the role's `meta/argument_specs.yml` and has a default in `defaults/main.yml`.

| Role | Purpose |
|---|---|
| `base` | Packages, time zone, unattended upgrades, swap, journald limit, sshd hardening |
| `fail2ban` | fail2ban on the systemd journal with nftables bans: sshd and repeat offenders |
| `crowdsec` | CrowdSec agent and its firewall bouncer, which also covers published Docker ports |
| `docker` | Docker CE with the compose plugin and a managed `daemon.json` |
| `tailscale` | Tailscale node, optionally a subnet router |
| `traefik` | Standalone Traefik with DNS-01 certificates and a Docker socket proxy |
| `portainer` | Portainer server or agent |
| `pulsix_manager` | Pulsix manager, database and any number of local workers |
| `pulsix_worker` | Any number of remote Pulsix workers, enrolled with one-time tokens |

## Install

```yaml
# requirements.yml
collections:
  - name: https://github.com/NoiXdev/ansible-collection-infra.git
    type: git
    version: v0.2.0
```

```bash
ansible-galaxy collection install -r requirements.yml
```

## Example

```yaml
- hosts: control
  become: true
  vars:
    # Never banned by fail2ban or CrowdSec; see "Lockout guard" below.
    security_allowlist: [10.20.0.0/24, 100.64.0.0/10, "fd7a:115c:a1e0::/48"]
  roles:
    - noixdev.infra.base
    - noixdev.infra.docker
    - noixdev.infra.fail2ban
    - noixdev.infra.crowdsec
    - role: noixdev.infra.traefik
      vars:
        traefik_acme_email: ops@example.com
        traefik_dns_env: { HETZNER_API_TOKEN: "{{ vault_hetzner_dns_token }}" }
        traefik_cert_domains: [{ main: example.com, sans: ["*.example.com"] }]
    - role: noixdev.infra.pulsix_manager
      vars:
        pulsix_manager_db_password: "{{ vault_pulsix_db_password }}"
        pulsix_manager_master_key: "{{ vault_pulsix_master_key }}"
        pulsix_manager_public_url: https://pulsix.example.com
        pulsix_manager_host: pulsix.example.com
        pulsix_manager_trusted_proxies: 172.31.255.254
        pulsix_manager_grpc_bind: [10.20.0.5]
        pulsix_manager_workers:
          - { name: ctl-1 }
          - { name: ctl-2, max_concurrent: 4 }

- hosts: workers
  become: true
  roles:
    - noixdev.infra.docker
    - role: noixdev.infra.pulsix_worker
      vars:
        pulsix_worker_manager_addr: 10.20.0.5:8444
        pulsix_worker_instances:
          - { name: edge-1 }
```

### Lockout guard: `security_allowlist`

**Put your management networks here (VPN, private network) so a typo can't
lock you out.** `security_allowlist` is a list of IP addresses or CIDRs that
both `fail2ban` (`ignoreip`) and `crowdsec` (a whitelist parser) never ban.
Set it once for all hosts, for example in `group_vars/all`. Each role adds its
own list on top (`fail2ban_ignoreip`, `crowdsec_allowlist`), and both stop the
run if an entry is not an IP address or CIDR.

### SSH hardening

With `base_sshd_hardening` (on by default) `base` writes
`/etc/ssh/sshd_config.d/50-base.conf`, checked with `sshd -t`: key-only
login (`AuthenticationMethods publickey`), root with a key only
(`base_sshd_permit_root_login`), no agent or X11 forwarding, tunnels, gateway
ports or user environment, TCP forwarding off (`base_sshd_allow_tcp_forwarding`),
`MaxAuthTries 3`, `LoginGraceTime 30`, `MaxSessions 10` (Ansible multiplexes
sessions), `MaxStartups 10:30:60`, idle sessions closed after 10 minutes,
`LogLevel VERBOSE` (key fingerprints in the log) and modern key exchange,
cipher and MAC lists that OpenSSH 9.6 (Ubuntu 24.04) and later accept.
`base_sshd_allow_users` adds an `AllowUsers` line; include the user Ansible
connects as.

### fail2ban

One file, `/etc/fail2ban/jail.d/50-noixdev.local`: journal backend, nftables
ban actions, `bantime` 1h, `findtime` 10m, `maxretry` 5. The `sshd` jail
watches `base_sshd_port` (22 otherwise); `recidive` bans hosts banned again
and again for a week on every port. Further jails go in
`fail2ban_extra_jails`:

```yaml
fail2ban_extra_jails:
  - name: nginx-http-auth
    enabled: true
    port: http,https
    backend: auto
    logpath: /var/log/nginx/error.log
```

### CrowdSec

Installs CrowdSec and `crowdsec-firewall-bouncer-iptables` from the official
repository; the downloaded signing key must carry
`crowdsec_apt_key_fingerprint`. The role installs `crowdsec_collections`
(`crowdsecurity/linux`, `crowdsecurity/sshd`), writes one acquisition file per
`crowdsec_acquisitions` entry (default: the journal of `ssh.service`) and
removes the `setup.*.yaml` files the package generates, so no log is read
twice. It registers the bouncer once as `crowdsec_bouncer_name` and keeps its
API key in the bouncer configuration only (never in the output).

The bouncer blocks in `INPUT` and, when Docker is present, in `DOCKER-USER`,
which covers published container ports that bypass `INPUT`.
`crowdsec_bouncer_docker_user` decides: unset means "only if `/usr/bin/docker`
exists when the role runs", so run `docker` before `crowdsec`; `true` or
`false` overrides. With it, the bouncer starts after `docker.service`.

Traefik access logs, as an example of a further source (Traefik must write its
access log to a file on the host; not enabled by default):

```yaml
crowdsec_collections: [crowdsecurity/linux, crowdsecurity/sshd, crowdsecurity/traefik]
crowdsec_acquisitions:
  - name: sshd
    source: journalctl
    journalctl_filter: [_SYSTEMD_UNIT=ssh.service]
    labels: { type: syslog }
  - name: traefik
    source: file
    filenames: [/opt/traefik/logs/access.log]
    labels: { type: traefik }
```

`crowdsec_console_enroll_key` (empty by default) enrolls the instance in the
CrowdSec console once; accept it there. Until then every run tries again and
reports a change. Keep the key in a vault.

### Pulsix workers

- **Local workers** (`pulsix_manager_workers`) run next to the manager and
  enroll themselves through the manager CLI once the setup wizard has created
  the first organization. Run the role again after the wizard.
- **Remote workers** (`pulsix_worker_instances`) enroll once with a one-time token from
  the Workers page (valid one hour, single use). The token carries the
  manager CA's fingerprint, so the worker pins the CA before it first
  connects, and its private key is created on its own host. Pass the tokens at
  run time:

  ```bash
  ansible-playbook workers.yml -e @tokens.yml   # {pulsix_worker_enroll_tokens: {edge-1: pxw1.…}}
  ```

  A worker that already has an identity needs no token. Removing a worker from
  the list stops it; revoke it on the Workers page as well.

## Development

```bash
ansible-lint
tests/run.sh                    # container roles, Docker-in-Docker
UBUNTU=24.04 tests/host/run.sh  # host roles on a systemd Ubuntu container
UBUNTU=26.04 tests/host/run.sh
```

## License

MIT
