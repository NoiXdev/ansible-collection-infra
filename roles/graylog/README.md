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
