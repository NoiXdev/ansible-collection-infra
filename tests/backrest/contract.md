# Backrest 1.14.1: the measured contract

Written by `tests/backrest/run.sh` (scenario `contract`) from a real Backrest
1.14.1. Do not edit it by hand; run `NOIXDEV_INFRA_BACKREST_TESTS=contract
tests/all.sh backrest` instead.

```text
sha256_x86_64: acc7835a9c55b3d254f0fa285cacbe87ac912cb7e069d0211924838020e6921c
sha256_arm64: b53718cd6e042e7d99538cb652968ab966a5c53fabd556785648ceb13320a320
binary_in_archive: backrest
bcrypt_command: printf %s "$BACKREST_PASSWORD" | htpasswd -inBC 10 "" | tr -d ":\n" | base64 | tr -d "\n"
guid_written_back: yes
restart_rewrites_config: no
exclude_file_flag: yes
start_hook_fatal: yes
finish_marks_failed: no
report_count: start_hook=1 finish_hook=0 restic_error=1
backup_rpc: POST /v1.Backrest/Backup {"value":"<plan id>"}
ui_status: 200
```

## Details

```text
restic_binary: /var/lib/backrest/restic
login: wrong password 401, no login 401
backup_rpc_blocks: yes (a 4 second start hook; answers 200 when the backup succeeded)
start_hook: status STATUS_ERROR, new snapshots 0, RPC 500
finish_hook: status STATUS_ERROR, new snapshots 1, RPC 500, CONDITION_ANY_ERROR reports 0
restic_error: status STATUS_ERROR, RPC 500
report_healthchecks: 1 to /report/fail
report_webhook: 0 (backup status STATUS_ERROR)
```
