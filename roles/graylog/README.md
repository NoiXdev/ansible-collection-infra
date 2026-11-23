# graylog

Runs Graylog, a log management server, in Docker Compose behind the `traefik`
role: the web interface, inputs for GELF and syslog senders, a retention for
the messages, a backup before every update and a rollback when an update
fails.

Docker comes from the playbook (the `docker` role); the role checks for it.
`graylog_hostname`, `graylog_root_password` and `graylog_password_secret` are
required (keep the secrets in a vault). The full reference is in
`meta/argument_specs.yml`, the defaults in `defaults/main.yml`.

The search engine refuses to start with `vm.max_map_count` below 262144, so
the role writes a sysctl drop-in (`/etc/sysctl.d/60-noixdev-graylog.conf`).
The drop-in writes the larger of 262144 and the current runtime value, so a
higher value an operator set is kept.

## Variables

| Variable | Default | Purpose |
|---|---|---|
| `graylog_version` | `7.2.2` | Graylog release, `X.Y.Z`, 7.0.0 or newer; no `latest` |
| `graylog_mongodb_version` | `8.0.38` | MongoDB release, `X.Y.Z`, major 7 or 8 |
| `graylog_image`, `graylog_datanode_image`, `graylog_mongodb_image` | Docker Hub repositories | Images without their tags |
| `graylog_dir` | `/opt/graylog` | The compose project: compose file, secrets, markers |
| `graylog_data_dir` | `<graylog_dir>/data` | The data and the backups; no comma in the path |
| `graylog_data_dir_mountpoint` | `false` | Refuse every run while the data directory is not a mountpoint |
| `graylog_hostname` | required | The host name Traefik routes to the web interface |
| `graylog_url` | `https://<hostname>` | The origin the browsers see |
| `graylog_traefik_network` | `proxy` | Traefik's network |
| `graylog_traefik_entrypoints` | `[]` | Entrypoints of the router (empty: Traefik's default ones) |
| `graylog_traefik_middlewares` | `[]` | Middlewares of the router, an IP allowlist for example |
| `graylog_traefik_priority` | `100` | Priority of the router |
| `graylog_root_username` | `admin` | The root user of the web interface |
| `graylog_root_password` | required | Its password |
| `graylog_password_secret` | required | The secret of the server and the Data Node, 16 characters or more |
| `graylog_server_heap` | `1g` | JVM heap of the server (`512m`, `2g`) |
| `graylog_datanode_heap` | `2g` | JVM heap of the Data Node |
| `graylog_mongodb_cache_gb` | `0.5` | MongoDB's cache in GB |
| `graylog_inputs` | GELF UDP 12201, syslog UDP 1514 | The inputs: `name`, `type`, `port`, `bind`, `traefik`, `token`, `options`; one UDP and one TCP input may share a port |
| `graylog_input_title_prefix` | `"ansible: "` | Title prefix of the inputs the role manages |
| `graylog_retention_days` | `30` | Days the default index set keeps messages |
| `graylog_env` | `{}` | More settings of the server; the ones the role sets itself are refused |
| `graylog_update_backup_logs` | `true` | Copy the Data Node's index before an update |
| `graylog_backups_keep` | `2` | Backups before updates that are kept |
| `graylog_health_timeout` | `600` | Seconds to wait until Graylog is healthy |
| `graylog_rollback_timeout` | the health timeout | Seconds a rollback waits for the previous version |
| `graylog_restore_interrupted` | `false` | For one run: restore the backup of an update that did not finish |

## Inputs

Each entry of `graylog_inputs` is an input titled `graylog_input_title_prefix`
plus its name. On every run the role creates the missing ones, updates the
changed ones (the same input, so its id stays) and deletes the inputs with the
prefix that no entry names; inputs without the prefix, made in the web
interface, are never touched. After a change of the prefix the inputs with
the old one stay, and still hold their ports: delete them in the web
interface. Every input of the role must be `RUNNING`, or the run fails.
Changes made by hand to the role's inputs are reset only when the role's
settings for them change, and swapping the ports of two inputs may need a
second run.

- `bind` publishes the port on those host addresses only, and nothing else
  restricts who sends: use the host's or the cloud's firewall. A port below
  1024 is the port plus 10000 inside the container (Graylog does not run as
  root), so a syslog input on 514 listens on 10514 there.
- `traefik` routes the input through Traefik: a `gelf_http` input gets an
  HTTPS router on the host name; `gelf_tcp` and `syslog_tcp` get a TCP router
  with TLS ended at Traefik, chosen by the server name (SNI) the sender sends,
  `sni` (default the host name). A sender that connects to an IP address, or
  sends no server name, needs `sni: '*'` on an entrypoint of its own;
  otherwise Traefik drops its messages without an error. An entrypoint with
  a `'*'` route serves that one input only, and the role refuses to share it.
- A TCP route serves the certificate Traefik holds for the server name, for
  example one it obtains for a name listed in the `traefik` role's
  certificate domains, else Traefik's default one; a `'*'` route serves the
  default one to a sender without a server name.
- `token` makes a `gelf_http` input accept only requests with the header
  `Authorization: Bearer <token>`.
- `options` sets further settings of the input, by Graylog's names (as
  `max_message_size`); the address, the port and the token are the role's.

## Retention

The default index set gets a new index every day and deletes the oldest
beyond `graylog_retention_days` indices, set on every run. The role uses
Graylog's classic rotation for it, not the data tiering, which keeps messages
between a minimum and a maximum age. Further index sets, streams, dashboards
and alerts are made in the web interface.
