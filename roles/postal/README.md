# postal

Runs Postal, a mail delivery platform, in Docker Compose behind the `traefik`
role: the web interface and the sending API, SMTP with STARTTLS, open and
click tracking, spam and virus checks, the database of your choice (a MariaDB
container of its own or a MariaDB server of your own), a backup before every
update and a rollback when an update fails.

This part of the role installs Postal with a MariaDB container of its own
or on a MariaDB server of your own, creates the first admin
(`postal_admin_email`, `postal_admin_password`), prints the DNS records to
set, applies changed settings, routes the API, the web interface and the
tracking domains through Traefik, gives the SMTP services a certificate for
STARTTLS, runs the spam and virus checks and checks on every run that Postal
answers; updates follow. A MariaDB server of your own must be MariaDB 10.6 or
newer, reachable from the host and from Traefik's network, with a user that
has all privileges on `postal_db_name` and on the message databases
(`<postal_message_db_prefix>-%`); every run checks that before it changes
anything. With
`postal_smtp_tls: traefik` the certificate is the one Traefik obtained for
`postal_smtp_hostname`: the role installs `/usr/local/sbin/postal-smtp-cert`
and a systemd timer that copies it twice a day and restarts the SMTP services
when it changed, and the first run waits for it. With `files` it copies
`postal_smtp_tls_cert` and `postal_smtp_tls_key` on every run. A customer
tracking domain added in Postal gets its router and its certificate on the
next run of the role, once Postal has verified its CNAME; its certificate
comes from HTTP-01 (the `traefik` role's `traefik_acme_http_resolver` with the
DNS-01 challenge). A password of the database user must not hold a double
quote or a backslash, which Postal cannot read. Docker comes from the playbook
(the `docker` role); the role checks for it. The host must be x86_64, as
Postal's image exists for that architecture only. `postal_web_hostname`,
`postal_dns_domain` and `postal_db_password` (keep it in a vault) are
required. The full reference is in `meta/argument_specs.yml`, the defaults in
`defaults/main.yml`.

## Variables

| Variable | Default | Purpose |
|---|---|---|
| `postal_version` | `3.5.0` | Postal release, `X.Y.Z`, 3.0.0 or newer; no `latest` |
| `postal_image` | `ghcr.io/postalserver/postal` | Image repository |
| `postal_dir` | `/opt/postal` | The compose project: compose file, configuration, markers |
| `postal_data_dir` | `<postal_dir>/data` | The data and the backups; no comma in the path |
| `postal_data_dir_mountpoint` | `false` | Refuse every run while the data directory is not a mountpoint |
| `postal_web_hostname` | required | The host name Traefik routes to the web interface and API |
| `postal_smtp_hostname` | the web host name | The host name of the SMTP services and their certificate |
| `postal_dns_domain` | required | The domain Postal's DNS names are derived from |
| `postal_dns` | `{}` | Overrides of the derived DNS names and DKIM settings |
| `postal_traefik_network` | `proxy` | Traefik's network |
| `postal_traefik_entrypoints` | `[]` | Entrypoints of the API and tracking routers |
| `postal_traefik_ui_entrypoints` | the API's | Entrypoints of the web interface router |
| `postal_traefik_track_cert_resolver` | `http` | Certificate resolver of the customer tracking domains |
| `postal_track_hostnames` | `[]` | More tracking host names, with the entrypoint's certificates |
| `postal_database` | `mariadb` | `mariadb` (a container of the project) or `mariadb_external` (MariaDB 10.6 or newer of your own) |
| `postal_db_password` | required | Password of the database user |
| `postal_db_host` | required with `mariadb_external` | Host name or address of the external server |
| `postal_signing_key`, `postal_rails_secret_key` | `""` | Keys of the installation; empty generates them on a fresh install; a takeover needs both |
| `postal_smtp_port` | `25` | Port of the receiving SMTP service |
| `postal_smtp_submission_port` | `587` | Port of the submission service; `0` switches it off |
| `postal_smtp_tls` | `traefik` | `traefik`, `files` or `off` |
| `postal_traefik_acme_file` | `/opt/traefik/acme/acme.json` | Traefik's certificate storage, with `traefik` |
| `postal_smtp_tls_cert`, `postal_smtp_tls_key` | `""` | Certificate (with its chain) and key on the host, with `files` |
| `postal_spam` | `none` | `none` or `rspamd` |
| `postal_clamav` | `false` | Virus checks with ClamAV |
| `postal_admin_email`, `postal_admin_password` | `""` | The first admin, created once on an install |
| `postal_backups_keep` | `3` | Backups before updates that are kept |
| `postal_health_timeout` | `300` | Seconds to wait until Postal is healthy |
| `postal_config_extra` | `{}` | More of Postal's configuration; the keys the role owns are refused |

Further variables (mail, single sign-on, log shipping, IP pools, relays,
worker and health ports, the pins of rspamd and ClamAV) are documented in
`meta/argument_specs.yml`.
