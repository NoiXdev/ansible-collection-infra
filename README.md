# noixdev.infra

Reusable Ansible roles for Docker-based Linux servers (Debian, Ubuntu).

Every role is configured only through variables. Each variable is documented in
the role's `meta/argument_specs.yml` and has a default in `defaults/main.yml`.

| Role | Purpose |
|---|---|
| `base` | Packages, time zone, unattended upgrades, swap, journald limit, sshd hardening |
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
    version: v0.1.0
```

```bash
ansible-galaxy collection install -r requirements.yml
```

## Example

```yaml
- hosts: control
  become: true
  roles:
    - noixdev.infra.base
    - noixdev.infra.docker
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
tests/run.sh
```

## License

MIT
