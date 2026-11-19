# vaultwarden

Runs Vaultwarden, a Bitwarden-compatible password server, in Docker Compose
behind the `traefik` role: the vault, its admin page, the database of your
choice (a file, a container of its own or a server of your own), mail and
push notifications, backups before every update and a rollback when an
update fails.

Docker comes from the playbook (the `docker` role); the role checks for it.
Settings and their defaults are in `defaults/main.yml`; `vaultwarden_hostname`
is required.
