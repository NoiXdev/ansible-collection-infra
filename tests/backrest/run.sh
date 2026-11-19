#!/usr/bin/env bash
# End-to-end test of Backrest on a throwaway systemd host per Ubuntu release,
# with Docker inside (the docker role) running fixtures/compose.yaml: MinIO as
# the S3 target, a server that records reports, and PostgreSQL in the compose
# project "shop".
#
# The scenario "contract" installs the release binary and writes config.json by
# hand, and measures how Backrest really behaves: the release archives, the
# login hash, what Backrest writes back to its configuration, the backup RPC, an
# exclude file, failing hooks and the reports they send. It writes the answers
# to contract.md, and fails when the releases disagree.
#
# The scenario "refusals" runs the backrest role with settings it must refuse,
# "install" installs Backrest through the role and checks the service,
# "config" checks that the role owns config.json, and "apps" backs up two apps
# with a failing dump, an empty path, a late app and odd paths: the healthy app
# is saved, the failed part is left out and the backup is marked failed.
# The scenario "reports" checks the failure reports (one message per failed
# backup, secret URL) and the age check.
#
# BACKREST_UBUNTU selects the releases (default "24.04 26.04");
# NOIXDEV_INFRA_BACKREST_TESTS selects scenarios (see the end of the file);
# KEEP=1 leaves the test hosts running.
# The single-quoted scripts expand inside the test host, not here.
# shellcheck disable=SC2016,SC2119,SC2120
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
tests="$(dirname "$here")"
root="$(dirname "$tests")"
out="$tests/output/backrest"
releases="${BACKREST_UBUNTU:-24.04 26.04}"
host=

# The value of a top-level key in a YAML file: value_of <file> <key>.
value_of() { sed -n "s/^$2: *//p" "$1" 2>/dev/null || true; }
ui_bind="$(value_of "$here/vars.yml" test_backrest_bind)"
ui_url="http://$ui_bind"
s3_endpoint="$(value_of "$here/vars.yml" test_s3_endpoint)"
s3_bucket="$(value_of "$here/vars.yml" test_s3_bucket)"
capture_url="$(value_of "$here/vars.yml" test_capture_url)"

version=1.14.1
release_url="https://github.com/garethgeorge/backrest/releases/download/v$version"
checksums="backrest_${version}_checksums.txt"
config=/etc/backrest/config.json
data_dir=/var/lib/backrest
repo_id=offsite
plan_id=nightly
ui_user='admin'

# Generated for this run, so that no test secret lives in the repository.
ui_password="$(openssl rand -hex 16)"
repo_password="$(openssl rand -hex 16)"
s3_access_key="$(openssl rand -hex 10)"
s3_secret_key="$(openssl rand -hex 20)"
db_password="$(openssl rand -hex 16)"

# The command the owner runs for backrest_users: it reads the password from the
# variable, so the password is in no process list and no shell history.
bcrypt_command='printf %s "$BACKREST_PASSWORD" | htpasswd -inBC 10 "" | tr -d ":\n" | base64 | tr -d "\n"'

cleanup() {
  [ "${KEEP:-0}" = 1 ] || [ -z "$host" ] || docker rm -f -v "$host" >/dev/null 2>&1 || true
}
# shellcheck source=/dev/null
. "$here/../lib/suite.sh"
noix_exit_guard

mkdir -p "$out" "$tests/output/ansible_collections/noixdev"
noix_link_collection "$root" "$tests/output"
export ANSIBLE_COLLECTIONS_PATH="$tests/output:${ANSIBLE_COLLECTIONS_PATH:-$HOME/.ansible/collections}"

fail() { echo "$*" >&2; exit 1; }

# h <cmd...>: run in the test host; hi: the same with this script's stdin.
h() { docker exec "$host" "$@"; }
hi() { docker exec -i "$host" "$@"; }

# play [-e ...]: the test host's playbook; its output goes to converge.log.
play() {
  ansible-playbook -i "$here/inventory.yml" -e "test_host=$host" "$here/converge.yml" "$@" >"$out/converge.log" 2>&1
}
# converge [-e ...]: play, which must succeed.
converge() {
  play "$@" || { cat "$out/converge.log" >&2; fail "converge failed"; }
}
# converge_fails [-e ...]: play, which must fail.
converge_fails() {
  if play "$@"; then cat "$out/converge.log" >&2; fail "converge succeeded, but must fail"; fi
}
# converge_unchanged [-e ...]: the same again, which must change nothing.
# shellcheck disable=SC2120
converge_unchanged() {
  converge "$@"
  grep -Eq 'changed=0 +unreachable=0 +failed=0' "$out/converge.log" \
    || { cat "$out/converge.log" >&2; fail "the repeated converge changed something"; }
}

# The variables of the backrest role in this run (secrets of the run, mode
# 0600), and the converge calls that run the role.
write_role_vars() {
  local hash
  hash="$(BACKREST_PASSWORD="$ui_password" sh -c "$bcrypt_command")"
  (
    umask 077
    env "HASH=$hash" "USER_NAME=$ui_user" "URI=s3:$s3_endpoint/$s3_bucket/$1" "REPO_PASSWORD=$repo_password" \
      "S3_ACCESS_KEY=$s3_access_key" "S3_SECRET_KEY=$s3_secret_key" "BIND=$ui_bind" python3 -c '
import json, os
e = os.environ
print(json.dumps({
    "test_backrest": True,
    "backrest_bind": e["BIND"],
    "backrest_users": [{"name": e["USER_NAME"], "password_bcrypt": e["HASH"]}],
    "backrest_repo_uri": e["URI"],
    "backrest_repo_password": e["REPO_PASSWORD"],
    "backrest_repo_env": {"AWS_ACCESS_KEY_ID": e["S3_ACCESS_KEY"], "AWS_SECRET_ACCESS_KEY": e["S3_SECRET_KEY"]},
}))' >"$out/role-vars.json"
  )
}
role_converge() { converge -e "@$out/role-vars.json" "$@"; }
role_converge_unchanged() { converge_unchanged -e "@$out/role-vars.json" "$@"; }
role_converge_fails() { converge_fails -e "@$out/role-vars.json" "$@"; }

# h_bg <sh command>: runs it in the test host, detached.
h_bg() { docker exec -d "$host" sh -c "$1"; }

# restic_stand_in <seconds>: a command line for h_bg that runs a process named
# restic (what the role looks for) for that long. The name is the process's
# comm, which a copied binary would not give on a release whose coreutils is a
# single multi-call binary.
restic_stand_in() {
  printf 'python3 -c %s' "'open(\"/proc/self/comm\", \"w\").write(\"restic\"); import time; time.sleep($1)'"
}

# cfg <jq filter>: a value of config.json (null prints as "null").
cfg() { h cat "$config" | jq -r "$1"; }
# cfg_with <jq filter>: config.json with the filter applied, as JSON.
cfg_with() { h cat "$config" | jq -c "$1"; }
# save_config / restore_config: keep config.json aside and put it back.
save_config() { h cp -p "$config" /tmp/config.saved; }
restore_config() { h cp -p /tmp/config.saved "$config"; }

# api <Rpc> [json]: POST /v1.Backrest/<Rpc> with the login. Prints the answer,
# keeps its HTTP status for api_status and fails unless it is a 2xx.
api() {
  local rpc="$1" body='{}' status
  [ "$#" -lt 2 ] || body="$2"
  status="$(h curl -sS -o /tmp/api-answer -w '%{http_code}' --max-time 900 -u "$ui_user:$ui_password" \
    -H 'Content-Type: application/json' -d "$body" "$ui_url/v1.Backrest/$rpc")" || status=000
  printf '%s\n' "$status" >"$out/api.status"
  h cat /tmp/api-answer
  case "$status" in 2??) return 0 ;; *) return 1 ;; esac
}
api_status() { cat "$out/api.status"; }

# The status of the newest backup operation.
last_status() {
  api GetOperations '{"selector":{},"lastN":"200"}' | python3 -c '
import json, sys
ops = [o for o in json.load(sys.stdin).get("operations", []) if "operationBackup" in o]
print(ops[-1].get("status", "") if ops else "none")'
}
snapshot_count() {
  api ListSnapshots "{\"repoId\":\"$repo_id\",\"planId\":\"$plan_id\"}" | python3 -c '
import json, sys
print(len(json.load(sys.stdin).get("snapshots", [])))'
}
# The id of the newest snapshot. Retention keeps one snapshot per day, so the
# number of snapshots is no sign of a new one.
newest_snapshot() {
  api ListSnapshots "{\"repoId\":\"$repo_id\",\"planId\":\"$plan_id\"}" | python3 -c '
import json, sys
print(max(json.load(sys.stdin)["snapshots"], key=lambda s: int(s.get("unixTimeMs", 0)))["id"])'
}
# The entries of the directory <path> in the newest snapshot, one per line.
# Fails when the directory is not in the snapshot.
snapshot_entries() {
  local body
  body="$(python3 -c '
import json, sys
print(json.dumps({"repoId": sys.argv[1], "snapshotId": sys.argv[2], "path": sys.argv[3]}))' "$repo_id" "$(newest_snapshot)" "$1")"
  api ListSnapshotFiles "$body" | python3 -c '
import json, sys
for entry in json.load(sys.stdin).get("entries", []):
    print(entry["path"])'
}
# The entries below the directory <path>: the listing starts with the directory itself.
snapshot_children() { snapshot_entries "$1" | grep -vxF -- "$1" || true; }
# in_snapshot <path>...: every path is in the newest snapshot.
in_snapshot() {
  local p
  for p in "$@"; do
    snapshot_entries "$(dirname "$p")" | grep -qxF -- "$p" || fail "$p is not in the newest snapshot"
  done
}
# not_in_snapshot <path>...: none of the paths is in the newest snapshot.
not_in_snapshot() {
  local p
  for p in "$@"; do
    if snapshot_entries "$(dirname "$p")" 2>/dev/null | grep -qxF -- "$p"; then fail "$p is in the newest snapshot"; fi
  done
}

# The lines the capture server received, and how to start counting again.
reports() { h sh -c 'cat /srv/capture/reports.log 2>/dev/null || true'; }
reports_clear() { h sh -c ': >/srv/capture/reports.log'; }
# How many reports arrived, once a failure has had the time to send them all.
reports_settled() {
  sleep 5
  reports | wc -l | tr -d ' '
}

# reports_to <name>: the lines the capture server received for the URL <capture>/<name>.
capture_path="/${capture_url#*://*/}"
reports_to() { reports | grep -F " $capture_path/$1" || true; }
# reports_settled_to <name>: how many reports arrived for that URL, once a failure has had the time to send them.
reports_settled_to() {
  sleep 5
  reports_to "$1" | wc -l | tr -d ' '
}

# Starts Backrest's plan and reports whether the RPC answered with a 2xx.
backup() { api Backup "{\"value\":\"$plan_id\"}" >/dev/null; }
# run_backup: a backup whose result is read from the operations; the RPC
# answers 200 for a good backup and 500 for a failed one, and nothing else.
run_backup() {
  backup || case "$(api_status)" in 500) ;; *) fail "the backup answered $(api_status)" ;; esac
}

wait_ui() {
  local _
  for _ in $(seq 1 180); do
    if h curl -fsS -o /dev/null "$ui_url/" 2>/dev/null; then return 0; fi
    sleep 1
  done
  h journalctl -u backrest --no-pager -n 50 >&2 || true
  fail "Backrest did not answer on $ui_url"
}

# reconfigure <json>: stops Backrest, merges {"plan":{...},"repo":{...},
# "auth":{...}} into the first plan, the first repository and the login, and
# starts it again (Backrest reads its configuration only at start).
reconfigure() {
  h systemctl stop backrest
  hi env "PATCH=$1" "CONFIG=$config" python3 -c '
import json, os
patch = json.loads(os.environ["PATCH"])
with open(os.environ["CONFIG"], encoding="utf-8") as f:
    c = json.load(f)
c["plans"][0].update(patch.get("plan", {}))
c["repos"][0].update(patch.get("repo", {}))
c["auth"].update(patch.get("auth", {}))
with open(os.environ["CONFIG"], "w", encoding="utf-8") as f:
    json.dump(c, f, indent=2)'
  h systemctl start backrest
  wait_ui
}
# hooks <plan hooks> <repo hooks>: comma-separated JSON objects, either empty.
hooks() { reconfigure "{\"plan\":{\"hooks\":[$1]},\"repo\":{\"hooks\":[$2]}}"; }

# start_host <ubuntu>: a fresh systemd host with Docker and the fixtures.
start_host() {
  local ubuntu="$1" _
  host="noixdev-infra-backrest-$ubuntu"
  docker build -q --build-arg "UBUNTU=$ubuntu" -t "noixdev-infra-host:$ubuntu" "$tests/host" >/dev/null
  docker rm -f -v "$host" >/dev/null 2>&1 || true
  # The anonymous volumes give the inner Docker a file system it can mount
  # overlays on; "docker rm -v" removes them with the host.
  docker run -d --privileged --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
    --tmpfs /run --tmpfs /run/lock -v /var/lib/docker -v /var/lib/containerd \
    --name "$host" "noixdev-infra-host:$ubuntu" >/dev/null
  until (h systemctl is-system-running 2>/dev/null || true) | grep -Eq "running|degraded"; do sleep 1; done
  # The image's policy-rc.d (exit 101) keeps package scripts from starting
  # services; servers have none.
  h rm -f /usr/sbin/policy-rc.d

  echo "== test host (ubuntu $ubuntu)"
  converge
  # shellcheck disable=SC2119
  converge_unchanged

  h mkdir -p /opt/fixtures /srv/capture
  docker cp -q "$here/fixtures/compose.yaml" "$host:/opt/fixtures/compose.yaml"
  printf 'S3_ACCESS_KEY=%s\nS3_SECRET_KEY=%s\nS3_BUCKET=%s\nDB_PASSWORD=%s\n' \
    "$s3_access_key" "$s3_secret_key" "$s3_bucket" "$db_password" | hi sh -c 'umask 077; cat >/opt/fixtures/.env'
  h sh -c 'cd /opt/fixtures && docker compose up -d --quiet-pull --wait' >"$out/fixtures.log" 2>&1 \
    || { cat "$out/fixtures.log" >&2; fail "the fixtures did not start"; }
  for _ in $(seq 1 120); do
    if h curl -fsS -o /dev/null "$s3_endpoint/minio/health/live" 2>/dev/null \
      && h curl -fsS -o /dev/null "http://127.0.0.1:9099/" 2>/dev/null; then
      return 0
    fi
    sleep 1
  done
  fail "MinIO or the capture server did not answer"
}

# Downloads the release into the test host, checks both archives against the
# checksum file and installs the binary for the host's architecture. Sets
# sha256_x86_64, sha256_arm64 and binary_in_archive.
install_release() {
  local arch asset paths
  h mkdir -p /opt/release
  for asset in "$checksums" backrest_Linux_x86_64.tar.gz backrest_Linux_arm64.tar.gz; do
    h curl -fsSL --retry 3 -o "/opt/release/$asset" "$release_url/$asset"
  done
  h sh -c "cd /opt/release && grep -E ' backrest_Linux_(x86_64|arm64)\.tar\.gz\$' $checksums | sha256sum -c --status" \
    || fail "the release archives do not match $checksums"
  sha256_x86_64="$(h sh -c "sed -n 's/  backrest_Linux_x86_64\.tar\.gz\$//p' /opt/release/$checksums")"
  sha256_arm64="$(h sh -c "sed -n 's/  backrest_Linux_arm64\.tar\.gz\$//p' /opt/release/$checksums")"
  if [ "${#sha256_x86_64}" != 64 ] || [ "${#sha256_arm64}" != 64 ]; then fail "$checksums lacks a Linux archive"; fi
  binary_in_archive=
  for asset in backrest_Linux_x86_64.tar.gz backrest_Linux_arm64.tar.gz; do
    paths="$(h tar -tzf "/opt/release/$asset" | sed 's#^\./##' | grep -E '(^|/)backrest$')"
    [ -z "$binary_in_archive" ] || [ "$binary_in_archive" = "$paths" ] || fail "the archives disagree on the binary: $paths"
    binary_in_archive="$paths"
  done
  case "$(h dpkg --print-architecture)" in
    amd64) arch=x86_64 ;;
    arm64) arch=arm64 ;;
    *) fail "no Backrest archive for this architecture" ;;
  esac
  h tar -xzf "/opt/release/backrest_Linux_$arch.tar.gz" -C /usr/local/bin "$binary_in_archive"
  h chmod 0755 "/usr/local/bin/$binary_in_archive"
}

# write_config <login hash>: config.json by hand, with one repository on MinIO,
# one plan and one login; and the systemd unit.
write_config() {
  h mkdir -p /etc/backrest "$data_dir" /var/cache/backrest
  hi env "HASH=$1" "CONFIG=$config" "URI=s3:$s3_endpoint/$s3_bucket/contract" "REPO=$repo_id" "PLAN=$plan_id" \
    "REPO_PASSWORD=$repo_password" "S3_ACCESS_KEY=$s3_access_key" "S3_SECRET_KEY=$s3_secret_key" "UI_USER=$ui_user" python3 -c '
import json, os
e = os.environ
config = {
    "modno": 1,
    "version": 6,
    "instance": "contract",
    "repos": [{
        "id": e["REPO"],
        "uri": e["URI"],
        "password": e["REPO_PASSWORD"],
        "env": ["AWS_ACCESS_KEY_ID=" + e["S3_ACCESS_KEY"], "AWS_SECRET_ACCESS_KEY=" + e["S3_SECRET_KEY"]],
        "autoInitialize": True,
        "prunePolicy": {"schedule": {"disabled": True}},
        "checkPolicy": {"schedule": {"disabled": True}},
    }],
    "plans": [{
        "id": e["PLAN"],
        "repo": e["REPO"],
        "paths": ["/srv/data"],
        "schedule": {"disabled": True},
        "retention": {"policyKeepAll": True},
    }],
    "auth": {"users": [{"name": e["UI_USER"], "passwordBcrypt": e["HASH"]}]},
}
with open(e["CONFIG"], "w", encoding="utf-8") as f:
    json.dump(config, f, indent=2)
os.chmod(e["CONFIG"], 0o600)'
  hi sh -c 'cat >/etc/systemd/system/backrest.service' <<UNIT
[Unit]
Description=Backrest
After=network-online.target docker.service

[Service]
Environment=BACKREST_PORT=$ui_bind
Environment=BACKREST_CONFIG=$config
Environment=BACKREST_DATA=$data_dir
Environment=XDG_CACHE_HOME=/var/cache/backrest
ExecStart=/usr/local/bin/backrest
Restart=on-failure

[Install]
WantedBy=multi-user.target
UNIT
  h systemctl daemon-reload
}

# Whether the first start wrote the repository id back: yes or no.
guid_is_written() {
  h env "CONFIG=$config" python3 -c '
import json, os
with open(os.environ["CONFIG"], encoding="utf-8") as f:
    repo = json.load(f)["repos"][0]
print("yes" if len(repo.get("guid", "")) == 64 and "autoInitialize" not in repo else "no")'
}

# login_status <password>: the HTTP status of an RPC with this password.
login_status() {
  h curl -s -o /dev/null -w '%{http_code}' -u "$ui_user:$1" -H 'Content-Type: application/json' -d '{}' \
    "$ui_url/v1.Backrest/GetConfig"
}

test_contract() {
  local ubuntu="$1" linux_hash local_hash before after entries _
  local sleep_hook fail_start fail_finish report status count start elapsed
  sleep_hook='{"conditions":["CONDITION_SNAPSHOT_START"],"onError":"ON_ERROR_FATAL","actionCommand":{"command":"sleep 4"}}'
  fail_start='{"conditions":["CONDITION_SNAPSHOT_START"],"onError":"ON_ERROR_FATAL","actionCommand":{"command":"exit 1"}}'
  fail_finish='{"conditions":["CONDITION_SNAPSHOT_SUCCESS"],"onError":"ON_ERROR_FATAL","actionCommand":{"command":"exit 1"}}'
  report='{"conditions":["CONDITION_ANY_ERROR","CONDITION_SNAPSHOT_WARNING"],"actionDiscord":{"webhookUrl":"'"$capture_url"'","template":"contract report"}}'

  echo "== contract: the release archives (ubuntu $ubuntu)"
  install_release

  echo "== contract: the first start"
  h mkdir -p /srv/data/kept /srv/data/left-out
  h sh -c 'echo kept >/srv/data/kept/file; echo left-out >/srv/data/left-out/file'
  linux_hash="$(h env "BACKREST_PASSWORD=$ui_password" sh -c "$bcrypt_command")"
  write_config "$linux_hash"
  h systemctl start backrest
  wait_ui
  guid_written_back=no
  for _ in $(seq 1 120); do
    guid_written_back="$(guid_is_written)"
    [ "$guid_written_back" = no ] || break
    sleep 1
  done
  restic_binary="$(h sh -c "ls -d $data_dir/restic* 2>/dev/null | head -n 1")"

  echo "== contract: the login"
  [ "$(login_status "$ui_password")" = 200 ] || fail "the hash made on Linux does not log in"
  api_wrong_password="$(login_status "wrong-$ui_password")"
  api_no_login="$(h curl -s -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' -d '{}' "$ui_url/v1.Backrest/GetConfig")"
  ui_status="$(h curl -s -o /dev/null -w '%{http_code}' "$ui_url/")"
  command -v htpasswd >/dev/null || fail "htpasswd is missing on this machine: the login hash cannot be proved here"
  local_hash="$(BACKREST_PASSWORD="$ui_password" sh -c "$bcrypt_command")"
  reconfigure "{\"auth\":{\"users\":[{\"name\":\"$ui_user\",\"passwordBcrypt\":\"$local_hash\"}]}}"
  [ "$(login_status "$ui_password")" = 200 ] || fail "the hash made on $(uname -s) does not log in"

  echo "== contract: a plain restart"
  before="$(h sha256sum "$config")"
  h systemctl restart backrest
  wait_ui
  sleep 3
  after="$(h sha256sum "$config")"
  if [ "$before" = "$after" ]; then restart_rewrites_config=no; else restart_rewrites_config=yes; fi

  echo "== contract: the backup RPC"
  hooks "$sleep_hook" ""
  start=$SECONDS
  backup || fail "the backup failed: $(api_status)"
  elapsed=$((SECONDS - start))
  backup_rpc_status="$(api_status)"
  status="$(last_status)"
  count="$(snapshot_count)"
  if [ "$status" != STATUS_SUCCESS ] || [ "$count" != 1 ]; then fail "the first backup: status $status, $count snapshots"; fi
  if [ "$elapsed" -ge 4 ]; then backup_rpc_blocks=yes; else backup_rpc_blocks=no; fi

  echo "== contract: an exclude file"
  entries="$(snapshot_entries /srv/data)"
  grep -qx /srv/data/left-out <<<"$entries" || fail "the path to leave out is not in a snapshot without the flag: $entries"
  h sh -c "printf '/srv/data/left-out\n' >$data_dir/excludes"
  reconfigure "{\"plan\":{\"hooks\":[],\"backup_flags\":[\"--exclude-file=$data_dir/excludes\"]}}"
  backup || fail "the backup with the exclude file failed: $(api_status)"
  entries="$(snapshot_entries /srv/data)"
  exclude_file_flag=no
  if grep -qx /srv/data/kept <<<"$entries" && ! grep -qx /srv/data/left-out <<<"$entries"; then
    exclude_file_flag=yes
  fi

  echo "== contract: a failing start hook"
  hooks "$fail_start" "$report"
  reports_clear
  count="$(snapshot_count)"
  if backup; then start_hook_rpc=answered; else start_hook_rpc="$(api_status)"; fi
  start_hook_status="$(last_status)"
  start_hook_new_snapshots=$(($(snapshot_count) - count))
  report_start_hook="$(reports_settled)"
  start_hook_fatal=no
  [ "$start_hook_status" != STATUS_ERROR ] || [ "$start_hook_new_snapshots" != 0 ] || start_hook_fatal=yes

  echo "== contract: a failing hook after the snapshot"
  hooks "$fail_finish" "$report"
  reports_clear
  count="$(snapshot_count)"
  if backup; then finish_hook_rpc=answered; else finish_hook_rpc="$(api_status)"; fi
  finish_hook_status="$(last_status)"
  finish_hook_new_snapshots=$(($(snapshot_count) - count))
  report_finish_hook="$(reports_settled)"
  finish_marks_failed=no
  [ "$finish_hook_status" != STATUS_ERROR ] || [ "$report_finish_hook" = 0 ] || finish_marks_failed=yes

  echo "== contract: a failing restic"
  reconfigure "{\"plan\":{\"hooks\":[],\"paths\":[\"/srv/does-not-exist\"]},\"repo\":{\"hooks\":[$report]}}"
  reports_clear
  if backup; then restic_error_rpc=answered; else restic_error_rpc="$(api_status)"; fi
  restic_error_status="$(last_status)"
  report_restic_error="$(reports_settled)"
  reconfigure '{"plan":{"paths":["/srv/data"]}}'

  echo "== contract: the other report types"
  hooks "$fail_start" '{"conditions":["CONDITION_ANY_ERROR"],"actionHealthchecks":{"webhookUrl":"'"$capture_url"'","template":"contract report"}}'
  reports_clear
  backup || true
  report_healthchecks="$(reports_settled)"
  report_healthchecks_path="$(reports | sed -n '1s/^POST \([^ ]*\) .*/\1/p')"
  hooks "$fail_start" '{"conditions":["CONDITION_ANY_ERROR"],"actionWebhook":{"webhookUrl":"'"$capture_url"'","method":"POST","template":"contract report"}}'
  reports_clear
  backup || true
  report_webhook="$(reports_settled)"
  webhook_status="$(last_status)"
  hooks "" ""

  write_contract "$out/contract-$ubuntu.md"
  contract_cleanup
}

# Leaves the host as the next scenario expects it: no Backrest at all.
contract_cleanup() {
  h systemctl disable --now backrest
  h rm -rf /etc/systemd/system/backrest.service /usr/local/bin/backrest /etc/backrest "$data_dir" \
    /var/cache/backrest /opt/release /srv/data
  h systemctl daemon-reload
}

# refused <message> [-e ...]: the role stops before any change, with a message.
refused() {
  local message="$1"
  shift
  role_converge_fails "$@"
  grep -qF -- "$message" "$out/converge.log" \
    || { cat "$out/converge.log" >&2; fail "the refusal lacks \"$message\""; }
  h test ! -e /usr/local/bin/backrest || fail "$message: the binary was installed"
  h test ! -e /etc/backrest || fail "$message: /etc/backrest was created"
}

test_refusals() {
  echo "== refusals (ubuntu $1)"
  write_role_vars refusals
  refused 'backrest_users is empty' -e '{"backrest_users": []}'
  refused 'not the base64 of a bcrypt' -e '{"backrest_users": [{"name": "a", "password_bcrypt": "plain"}]}'
  refused 'no checksum for' -e backrest_version=1.14.0
  refused 'backrest_repo_uri' -e backrest_repo_uri=
  refused 'backrest_repo_password' -e backrest_repo_password=
  refused 'app name' -e '{"backrest_apps": [{"name": "Bad Name"}]}'
  refused 'more than once' -e '{"backrest_apps": [{"name": "a"}, {"name": "a"}]}'
  refused 'dump.type' -e '{"backrest_apps": [{"name": "a", "dump": {"type": "mysql"}}]}'
  refused 'dump.output' -e '{"backrest_apps": [{"name": "a", "dump": {"type": "command", "command": "/bin/true"}}]}'
  refused 'backrest_notify_type' -e backrest_notify_type=mail -e backrest_notify_url=https://x.invalid
  refused 'backrest_notify_type' -e backrest_notify_type=webhook -e backrest_notify_url=https://x.invalid
}

test_install() {
  local sum status user
  echo "== install (ubuntu $1)"
  write_role_vars install
  role_converge
  h systemctl is-active backrest
  status="$(h curl -s -o /dev/null -w '%{http_code}' "$ui_url/")"
  [ "$status" = "$(value_of "$here/contract.md" ui_status)" ] || fail "the UI answers $status"
  user="$(h systemctl show backrest -p User --value)"
  if [ -n "$user" ] && [ "$user" != root ]; then fail "Backrest runs as $user, not root"; fi
  [ "$(h stat -c %a /etc/backrest/backrest.env)" = 600 ] || fail "backrest.env is not mode 0600"
  role_converge_unchanged
  # An app name with an underscore passes validation; the app joins the list of active apps.
  role_converge -e '{"backrest_apps": [{"name": "my_app"}]}'
  [ "$(h cat "$data_dir/active-apps")" = my_app ] || fail "the active app is not listed"
  role_converge_unchanged -e '{"backrest_apps": [{"name": "my_app"}]}'
  role_converge
  # A failed download keeps the working binary and the service.
  sum="$(h sha256sum /usr/local/bin/backrest)"
  role_converge_fails -e backrest_version=9.9.9 -e '{"backrest_sha256": {"x86_64": "00", "arm64": "00"}}'
  [ "$(h sha256sum /usr/local/bin/backrest)" = "$sum" ] || fail "a failed download replaced the binary"
  h systemctl is-active backrest
}

test_config() {
  local guid sync other_uri third_uri status
  echo "== config (ubuntu $1)"
  command -v jq >/dev/null || fail "jq is missing on this machine"
  other_uri="s3:$s3_endpoint/$s3_bucket/config-other"
  third_uri="s3:$s3_endpoint/$s3_bucket/config-third"
  write_role_vars config
  (
    umask 077
    python3 -c '
import json
print(json.dumps({"backrest_repo_password": "p\"a\x27ss $HOME \\n {x} #é"}))' >"$out/hard-password.json"
  )
  role_converge
  guid="$(cfg '.repos[0].guid')"
  [ "${#guid}" = 64 ] || fail "the repository id was not written back"
  sync="$(cfg '.sync.identity.keyId')"
  [ "$sync" != null ] && [ -n "$sync" ] || fail "no sync identity in config.json"
  [ "$(h stat -c %a "$config")" = 600 ] || fail "config.json is not mode 0600"
  [ "$(h stat -c %a "$data_dir/excludes")" = 600 ] || fail "the exclude file is not mode 0600"
  # The UI requires a login.
  [ "$(login_status "$ui_password")" = 200 ] || fail "the right password does not log in"
  [ "$(login_status "wrong-$ui_password")" = 401 ] || fail "a wrong password does not answer 401"
  status="$(h curl -s -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' -d '{}' "$ui_url/v1.Backrest/GetConfig")"
  [ "$status" = 401 ] || fail "a request without a login answers $status"
  # The guid and the sync identity are kept; the empty exclude file is left alone.
  h sh -c "echo /nonexistent >$data_dir/excludes"
  role_converge_unchanged
  [ "$(cfg '.repos[0].guid')" = "$guid" ] || fail "the repository id changed"
  [ "$(h cat "$data_dir/excludes")" = /nonexistent ] || fail "the exclude file was replaced"
  h sh -c ": >$data_dir/excludes"
  [ "$(cfg '.repos[0].prunePolicy.schedule.cron')" = '0 5 * * 0' ] || fail "prune schedule"
  [ "$(cfg '.repos[0].checkPolicy.schedule.cron')" = '0 6 1 * *' ] || fail "check schedule"
  [ "$(cfg '.repos[0].checkPolicy.readDataSubsetPercent')" = 5 ] || fail "check read percent"
  [ "$(cfg '.plans[0].retention.policyTimeBucketed.monthly')" = 6 ] || fail "retention"
  role_converge -e '{"backrest_extra_paths": ["/srv/extra"], "backrest_excludes": ["*.tmp"]}'
  cfg '.plans[0].paths' | grep -q /srv/extra || fail "extra path missing"
  cfg '.plans[0].excludes' | grep -qF '*.tmp' || fail "exclude pattern missing"
  # A plan changed in the UI is put back.
  api SetConfig "$(cfg_with '.plans[0].schedule.cron="0 9 * * *"')" >/dev/null || fail "SetConfig answered $(api_status)"
  role_converge
  [ "$(cfg '.plans[0].schedule.cron')" = '0 2 * * *' ] || fail "the plan changed in the UI was not put back"
  [ "$(cfg '.sync.identity.keyId')" = "$sync" ] || fail "the sync identity changed"
  role_converge_unchanged
  # A new URI drops the guid and initialises the new repository.
  role_converge -e backrest_repo_uri="$other_uri"
  [ "$(cfg '.repos[0].guid')" != "$guid" ] || fail "the old repository id was kept"
  # A hard password reaches restic.
  role_converge -e backrest_repo_uri="$third_uri" -e "@$out/hard-password.json"
  backup || fail "the backup answered $(api_status)"
  [ "$(last_status)" = STATUS_SUCCESS ] || fail "the backup did not succeed"
  h python3 -m json.tool "$config" >/dev/null
  # A broken file stops the run, unchanged and unprinted.
  save_config
  h sh -c 'echo "secret-line {" > /etc/backrest/config.json'
  role_converge_fails
  grep -q 'not valid JSON' "$out/converge.log" || fail "no message about invalid JSON"
  ! grep -q secret-line "$out/converge.log" || fail "the broken content was printed"
  [ "$(h cat "$config")" = 'secret-line {' ] || fail "the broken file was changed"
  restore_config
  h sh -c "sed -i 's/\"version\": *6/\"version\": 7/' $config"
  role_converge_fails
  grep -q 'format version 7' "$out/converge.log" || fail "no message about format version 7"
  restore_config
  # A change waits for a running backup, and gives up after the wait.
  h_bg "$(restic_stand_in 20)"
  role_converge -e backrest_repo_uri="$third_uri" -e "@$out/hard-password.json" -e '{"backrest_schedule": "0 3 * * *"}'
  [ "$(cfg '.plans[0].schedule.cron')" = '0 3 * * *' ] || fail "the change did not follow the wait"
  h_bg "$(restic_stand_in 600)"
  role_converge_fails -e backrest_repo_uri="$third_uri" -e "@$out/hard-password.json" -e '{"backrest_schedule": "0 4 * * *"}' -e backrest_restart_wait=5
  grep -q 'backup is running' "$out/converge.log" || fail "no message about the running backup"
  [ "$(cfg '.plans[0].schedule.cron')" = '0 3 * * *' ] || fail "a failed wait changed the configuration"
  h pkill -x restic || true
}

# compose <args>: docker compose in the fixtures' project.
compose() { h sh -c "cd /opt/fixtures && docker compose $*" >"$out/compose.log" 2>&1 || { cat "$out/compose.log" >&2; fail "docker compose $* failed"; }; }

# pg_restore_list_ok <file>: the dump is readable by pg_restore.
pg_restore_list_ok() {
  h sh -c "docker exec -i \$(docker ps -q --filter label=com.docker.compose.project=shop --filter label=com.docker.compose.service=db) pg_restore --list <'$1' >/dev/null"
}

# The dump directory is a 1 MB file system for the scenario "apps", so that
# fill_dump_dir can fill it without touching the disk of the test host.
dump_dir=/var/lib/backrest-dumps
fill_dump_dir() { h sh -c "dd if=/dev/zero of=$dump_dir/.filler bs=64k 2>/dev/null || true"; h sh -c "! dd if=/dev/zero of=$dump_dir/.probe bs=4k count=1 2>/dev/null"; }
free_dump_dir() { h rm -f "$dump_dir/.filler" "$dump_dir/.probe"; }

# write_apps_vars: the app lists of the scenario "apps" as extra-vars files in
# $out. A paths value with shell characters, escapes and globs must stay literal.
write_apps_vars() {
  python3 -c '
import json, sys
out = sys.argv[1]
odd = "/srv/odd $(touch \\/tmp\\/pwned) *[a]?"
sibling = "/srv/odd $(touch \\/tmp\\/pwned) xaz"
shop = {"name": "shop", "paths": ["/srv/shop"],
        "dump": {"type": "postgres", "project": "shop", "service": "db", "user": "shop", "database": "shop"}}
notes = {"name": "notes", "dump": {"type": "command", "command": "/usr/local/bin/notes-dump", "output": "/srv/notes-dump"}}
late = {"name": "late", "requires_path": "/srv/late/installed", "paths": ["/srv/late/data"]}
oddapp = {"name": "odd", "paths": [odd, sibling]}
odd_dumps = "/srv/odd-dumps $(touch \\/tmp\\/pwned) *[a]?"
with open("%s/with-odd-dump-dir.json" % out, "w", encoding="utf-8") as f:
    json.dump({"backrest_dump_dir": odd_dumps, "backrest_extra_paths": ["/srv/odd-dumps $(touch \\/tmp\\/pwned) xaz"]}, f)
for name, apps in (("apps", [shop, notes]), ("with-late-app", [shop, notes, late]), ("with-odd-path", [shop, notes, oddapp])):
    with open("%s/%s.json" % (out, name), "w", encoding="utf-8") as f:
        json.dump({"backrest_apps": apps}, f)' "$out"
}

test_apps() {
  local before n good pid failed_status=STATUS_ERROR odd sibling odd_dumps odd_dumps_sibling
  odd='/srv/odd $(touch \/tmp\/pwned) *[a]?'
  sibling='/srv/odd $(touch \/tmp\/pwned) xaz'
  odd_dumps='/srv/odd-dumps $(touch \/tmp\/pwned) *[a]?'
  odd_dumps_sibling='/srv/odd-dumps $(touch \/tmp\/pwned) xaz'
  echo "== apps (ubuntu $1)"
  command -v shellcheck >/dev/null || fail "shellcheck is missing on this machine"
  write_role_vars apps
  write_apps_vars
  h mkdir -p /srv/shop /srv/notes-dump /srv/late/data
  h sh -c 'echo a >/srv/shop/a.txt; echo late >/srv/late/data/b.txt'
  hi sh -c 'cat >/usr/local/bin/notes-dump && chmod 0755 /usr/local/bin/notes-dump' <<'NOTES'
#!/bin/sh
case "$(cat /srv/notes-mode 2>/dev/null)" in
  file) rm -rf /srv/notes-dump; echo x >/srv/notes-dump ;;
  fail) exit 1 ;;
  *) [ -d /srv/notes-dump ] || rm -f /srv/notes-dump; mkdir -p /srv/notes-dump && echo notes >/srv/notes-dump/out ;;
esac
NOTES
  h sh -c "mkdir -p $dump_dir && mount -t tmpfs -o size=1m tmpfs $dump_dir"
  compose up -d --wait db
  h sh -c 'docker exec $(docker ps -q --filter label=com.docker.compose.service=db) psql -q -U shop -c "create table if not exists t (i int); insert into t values (1)"' >/dev/null

  role_converge -e "@$out/apps.json"
  role_converge_unchanged -e "@$out/apps.json"
  [ "$(cfg '.plans[0].hooks | length')" = 2 ] || fail "the plan has no hooks"
  [ "$(cfg '.plans[0].hooks[0].conditions[0]')" = CONDITION_SNAPSHOT_START ] || fail "the first hook is not on the start"
  [ "$(cfg '.plans[0].hooks[1].conditions[0]')" = CONDITION_SNAPSHOT_SUCCESS ] || fail "the second hook is not after the snapshot"
  [ "$(cfg '.plans[0].hooks[0].onError')" = ON_ERROR_FATAL ] || fail "the start hook is not fatal"
  [ "$(cfg '.plans[0].hooks[1].onError')" = ON_ERROR_FATAL ] || fail "the finish hook is not fatal"
  [ "$(h stat -c '%U %a' /usr/local/sbin/backrest-prepare /usr/local/sbin/backrest-finish | tr '\n' ' ')" = 'root 700 root 700 ' ] \
    || fail "the scripts are not root 0700"
  h cat /usr/local/sbin/backrest-prepare >"$out/backrest-prepare.sh"
  h cat /usr/local/sbin/backrest-finish >"$out/backrest-finish.sh"
  shellcheck -s sh "$out/backrest-prepare.sh" "$out/backrest-finish.sh" || fail "shellcheck found problems in the scripts"
  # A changed script alone is written, and the service is not restarted.
  h sh -c 'echo "# edited" >>/usr/local/sbin/backrest-finish'
  pid="$(h systemctl show backrest -p MainPID --value)"
  role_converge -e "@$out/apps.json"
  [ "$(h systemctl show backrest -p MainPID --value)" = "$pid" ] || fail "a changed script restarted the service"
  ! h grep -q '# edited' /usr/local/sbin/backrest-finish || fail "the changed script was not put back"
  role_converge_unchanged -e "@$out/apps.json"

  run_backup
  [ "$(last_status)" = STATUS_SUCCESS ] || fail "the first backup did not succeed"
  h test -f "$data_dir/last-success"
  in_snapshot "$dump_dir/shop.dump" /srv/shop/a.txt /srv/notes-dump/out
  pg_restore_list_ok "$dump_dir/shop.dump"

  # One failed dump: the other app is saved, the stale dump is not.
  before="$(h stat -c %Y "$data_dir/last-success")"
  compose stop db
  run_backup
  [ "$(last_status)" = "$failed_status" ] || fail "a failed dump did not fail the backup"
  in_snapshot /srv/shop/a.txt /srv/notes-dump/out
  not_in_snapshot "$dump_dir/shop.dump"
  h test -s "$dump_dir/shop.dump" || fail "the last good dump was removed"
  h grep -q '^shop: ' "$data_dir/prepare-failures" || fail "the failure is not recorded"
  [ "$(h stat -c %Y "$data_dir/last-success")" = "$before" ] || fail "last-success moved after a failed backup"
  compose up -d --wait db
  run_backup
  [ "$(last_status)" = STATUS_SUCCESS ] || fail "the healthy run did not succeed"
  in_snapshot "$dump_dir/shop.dump"
  h test ! -s "$data_dir/prepare-failures" || fail "the failures were not cleared"

  # An empty path (an unmounted volume) is left out and reported.
  h mount -t tmpfs tmpfs /srv/shop
  run_backup
  # restic never leaves out a path it was given, only what is below it.
  [ -z "$(snapshot_children /srv/shop)" ] || fail "the empty path has entries in the snapshot"
  h grep -q '^shop: /srv/shop' "$data_dir/prepare-failures" || fail "the empty path is not recorded"
  h umount /srv/shop
  [ "$(last_status)" = "$failed_status" ] || fail "an empty path did not fail the backup"

  # An app that is not installed is skipped; once installed it fails until the next run.
  role_converge -e "@$out/with-late-app.json"
  run_backup
  [ "$(last_status)" = STATUS_SUCCESS ] || fail "a missing app failed the backup"
  h touch /srv/late/installed
  run_backup
  h grep -q '^late: .*run the playbook' "$data_dir/prepare-failures" || fail "the app that joined late is not recorded"
  [ "$(last_status)" = "$failed_status" ] || fail "the app that joined late did not fail the backup"
  role_converge -e "@$out/with-late-app.json"
  run_backup
  [ "$(last_status)" = STATUS_SUCCESS ] || fail "the app did not join after the playbook"
  in_snapshot /srv/late/data/b.txt

  # The script's own failure: no snapshot, a failed backup.
  n="$(newest_snapshot)"
  h sh -c "rm -f $data_dir/excludes && mkdir $data_dir/excludes"
  run_backup
  [ "$(last_status)" = STATUS_ERROR ] || fail "the failing script did not fail the backup"
  [ "$(newest_snapshot)" = "$n" ] || fail "a snapshot was taken although the script failed"
  h sh -c "rmdir $data_dir/excludes && : >$data_dir/excludes"

  # A command that leaves a file instead of a directory fails the app.
  h sh -c 'echo file >/srv/notes-mode'
  run_backup
  h grep -q '^notes: .*must be a directory' "$data_dir/prepare-failures" || fail "a file as command output is not recorded"
  [ "$(last_status)" = STATUS_ERROR ] || fail "a file as command output did not fail the backup"
  h sh -c 'rm -f /srv/notes-mode'
  run_backup
  [ "$(last_status)" = STATUS_SUCCESS ] || fail "the command dump did not recover"
  in_snapshot /srv/notes-dump/out
  # A failing command keeps its old output on disk, out of the snapshot.
  h sh -c 'echo fail >/srv/notes-mode'
  run_backup
  [ "$(last_status)" = STATUS_ERROR ] || fail "a failing command did not fail the backup"
  h grep -q '^notes: ' "$data_dir/prepare-failures" || fail "the failing command is not recorded"
  h test -s /srv/notes-dump/out || fail "the old command output was removed"
  [ -z "$(snapshot_children /srv/notes-dump)" ] || fail "the stale command output is in the snapshot"
  in_snapshot /srv/shop/a.txt
  h sh -c 'rm -f /srv/notes-mode'
  run_backup
  [ "$(last_status)" = STATUS_SUCCESS ] || fail "the command dump did not recover again"

  # None or two running containers.
  compose up -d --scale db=2 db
  run_backup
  h grep -q '^shop: .*2 containers' "$data_dir/prepare-failures" || fail "two containers are not recorded"
  compose up -d --scale db=1 --wait db
  run_backup
  [ "$(last_status)" = STATUS_SUCCESS ] || fail "one container again did not succeed"

  # A full disk keeps the last good dump.
  good="$(h sha256sum "$dump_dir/shop.dump")"
  fill_dump_dir
  run_backup
  [ "$(last_status)" = "$failed_status" ] || fail "a full disk did not fail the backup"
  [ "$(h sha256sum "$dump_dir/shop.dump")" = "$good" ] || fail "a full disk changed the last good dump"
  not_in_snapshot "$dump_dir/shop.dump"
  h grep -q '^shop: ' "$data_dir/prepare-failures" || fail "the full disk is not recorded"
  h test ! -e "$dump_dir/shop.dump.tmp" || fail "the temporary dump was left"
  free_dump_dir

  # Paths with spaces, shell characters and globs stay literal: the one that is
  # left out is not confused with its neighbour that matches it as a pattern.
  h mkdir -p "$odd" "$sibling"
  h sh -c "echo a >'$odd/a'; echo a >'$sibling/a'"
  role_converge -e "@$out/with-odd-path.json"
  run_backup
  [ "$(last_status)" = STATUS_SUCCESS ] || fail "the odd paths did not back up"
  in_snapshot "$odd/a" "$sibling/a"
  h test ! -e /tmp/pwned || fail "a path was executed"
  h mount -t tmpfs tmpfs "$odd"
  run_backup
  [ -z "$(snapshot_children "$odd")" ] || fail "the emptied odd path has entries in the snapshot"
  in_snapshot "$sibling/a"
  h grep -qF "odd: $odd is missing or empty" "$data_dir/prepare-failures" || fail "the odd path is not recorded"
  h test ! -e /tmp/pwned || fail "a path was executed"
  h umount "$odd"
  # restic does not leave out a path it was given, so the exclude line is proved
  # with a stale dump below an odd dump directory, next to a file of the same
  # name in a directory that the unescaped line would match.
  h umount "$dump_dir"
  h mkdir -p "$odd_dumps" "$odd_dumps_sibling"
  h sh -c "echo kept >'$odd_dumps_sibling/shop.dump'"
  role_converge -e "@$out/apps.json" -e "@$out/with-odd-dump-dir.json"
  run_backup
  [ "$(last_status)" = STATUS_SUCCESS ] || fail "the odd dump directory did not back up"
  in_snapshot "$odd_dumps/shop.dump" "$odd_dumps_sibling/shop.dump"
  compose stop db
  run_backup
  [ "$(last_status)" = "$failed_status" ] || fail "a failed dump in the odd directory did not fail the backup"
  not_in_snapshot "$odd_dumps/shop.dump"
  in_snapshot "$odd_dumps_sibling/shop.dump"
  h test -s "$odd_dumps/shop.dump" || fail "the last good dump was removed"
  h test ! -e /tmp/pwned || fail "a path was executed"
  compose up -d --wait db
}

# force_restic_failure: restic fails for the plan (its only path does not exist),
# while the start hook still succeeds. heal_restic puts the configuration back.
force_restic_failure() {
  save_config
  reconfigure '{"plan":{"paths":["/srv/does-not-exist"]}}'
}
heal_restic() {
  h systemctl stop backrest
  restore_config
  h systemctl start backrest
  wait_ui
}

# finish_fails: runs backrest-finish by hand, which must exit 1; its output is in $out/finish.out.
finish_fails() {
  if h /usr/local/sbin/backrest-finish >"$out/finish.out" 2>&1; then fail "backrest-finish succeeded, but must fail"; fi
}

test_reports() {
  local type notify=/etc/backrest/notify.curl finish=/usr/local/sbin/backrest-finish body
  echo "== reports (ubuntu $1)"
  command -v jq >/dev/null || fail "jq is missing on this machine"
  command -v shellcheck >/dev/null || fail "shellcheck is missing on this machine"
  write_role_vars reports
  python3 -c '
import json, sys
shop = {"name": "shop", "paths": ["/srv/shop"],
        "dump": {"type": "postgres", "project": "shop", "service": "db", "user": "shop", "database": "shop"}}
with open(sys.argv[1] + "/reports-apps.json", "w", encoding="utf-8") as f:
    json.dump({"backrest_apps": [shop]}, f)' "$out"
  h mkdir -p /srv/shop
  h sh -c 'echo a >/srv/shop/a.txt'
  compose up -d --wait db
  h sh -c 'docker exec $(docker ps -q --filter label=com.docker.compose.service=db) psql -q -U shop -c "create table if not exists t (i int); insert into t values (1)"' >/dev/null 2>&1
  # The scenario starts from a host without a good backup yet, inside its grace period.
  h rm -f "$data_dir/last-success"
  role_converge -e "@$out/reports-apps.json"

  # A failure that Backrest itself sees is reported once, for each report type.
  for type in discord healthchecks; do
    role_converge -e "@$out/reports-apps.json" -e backrest_notify_type="$type" -e backrest_notify_url="$capture_url/$type"
    h cat "$finish" >"$out/backrest-finish-$type.sh"
    shellcheck -s sh "$out/backrest-finish-$type.sh" || fail "shellcheck found problems in the $type finish script"
    reports_clear
    force_restic_failure
    run_backup
    [ "$(reports_settled_to "$type")" = 1 ] || fail "a failing restic did not send exactly one $type report"
    heal_restic
  done
  reports_to healthchecks | grep -qF "POST $capture_path/healthchecks/fail " || fail "healthchecks did not get the report on /fail"
  [ "$(cfg '.repos[0].hooks[0].onError')" = ON_ERROR_IGNORE ] || fail "the report hook is not ignored on error"
  cfg '.repos[0].hooks[0].conditions' | grep -q CONDITION_SNAPSHOT_WARNING || fail "the report hook is not on warnings"
  cfg '.repos[0].hooks[0].conditions' | grep -q CONDITION_ANY_ERROR || fail "the report hook is not on errors"

  # One failed app sends exactly one report, from backrest-finish.
  role_converge -e "@$out/reports-apps.json" -e backrest_notify_type=discord -e backrest_notify_url="$capture_url/partial"
  reports_clear
  compose stop db
  run_backup
  [ "$(reports_settled_to partial)" = 1 ] || fail "one failed app did not send exactly one report"
  reports_to partial | grep -q shop || fail "the report does not name the failed app"
  compose up -d --wait db

  # The URL is a secret.
  ! h grep -qF "$capture_url" "$finish" || fail "the notify URL is in the finish script"
  ! h grep -qF "$capture_url" /usr/local/sbin/backrest-prepare || fail "the notify URL is in the prepare script"
  [ "$(h stat -c '%U %a' "$notify")" = 'root 600' ] || fail "the notify file is not root 0600"
  ! grep -qF "$capture_url" "$out/converge.log" || fail "the notify URL is in the output of the role"
  role_converge_unchanged -e "@$out/reports-apps.json" -e backrest_notify_type=discord -e backrest_notify_url="$capture_url/partial"

  # A failure line with quotes and backslashes arrives as valid JSON.
  role_converge -e "@$out/reports-apps.json" -e backrest_notify_type=discord -e backrest_notify_url="$capture_url/json"
  reports_clear
  hi sh -c "cat >$data_dir/prepare-failures" <<'FAILURES'
shop: /srv/q"uo\te is missing or empty
shop: caf'é $(x) `y`
FAILURES
  finish_fails
  body="$(reports_to json | sed 's/^POST [^ ]* //')"
  [ "$(printf '%s\n' "$body" | wc -l | tr -d ' ')" = 1 ] || fail "the report did not arrive as one message"
  printf '%s\n' "$body" | python3 -c '
import json, sys
content = json.load(sys.stdin)["content"]
assert "shop: /srv/q\"uo\\te is missing or empty" in content, content
assert "caf\x27é $(x) `y`" in content, content' || fail "the report is not the expected JSON: $body"

  # A very long list stays below Discord's limit, with a marker.
  reports_clear
  hi sh -c "cat >$data_dir/prepare-failures" < <(python3 -c '
for i in range(120):
    print("shop: /srv/shop/%03d-%s is missing or empty" % (i, "x" * 40))')
  finish_fails
  body="$(reports_to json | sed 's/^POST [^ ]* //')"
  printf '%s\n' "$body" | python3 -c '
import json, sys
content = json.load(sys.stdin)["content"]
assert len(content) < 2000, len(content)
assert "truncated" in content' || fail "a long report is not truncated below 2000 characters"

  # A failed send never changes the exit status and prints nothing of the URL.
  role_converge -e "@$out/reports-apps.json" -e backrest_notify_type=discord -e backrest_notify_url="http://127.0.0.1:9/secret-token-42"
  hi sh -c "echo 'shop: broken' >$data_dir/prepare-failures"
  finish_fails
  ! grep -q secret-token-42 "$out/finish.out" || fail "the notify URL is in the output of the finish script"
  grep -q 'report could not be sent' "$out/finish.out" || fail "no message about the failed send"
  grep -q 'shop: broken' "$out/finish.out" || fail "the failures are not printed"

  # Healthchecks gets the text on /fail.
  role_converge -e "@$out/reports-apps.json" -e backrest_notify_type=healthchecks -e backrest_notify_url="$capture_url/hc/"
  reports_clear
  finish_fails
  reports_to hc | grep -F "POST $capture_path/hc/fail " | grep -qF 'shop: broken' || fail "healthchecks did not get the failures: $(reports)"
  # A missing failures file is reported as well.
  reports_clear
  h rm -f "$data_dir/prepare-failures"
  finish_fails
  reports_to hc | grep -q 'prepare-failures is missing' || fail "a missing failures file was not reported"

  # No URL, no hooks, no file.
  role_converge -e "@$out/reports-apps.json" -e backrest_notify_url=
  [ "$(cfg '.repos[0].hooks | length')" = 0 ] || fail "the report hook was not removed"
  h test ! -e "$notify" || fail "the notify file was not removed"
  role_converge_unchanged -e "@$out/reports-apps.json" -e backrest_notify_url=
  # A URL with a line break could add options to the curl file.
  role_converge_fails -e "@$out/reports-apps.json" -e '{"backrest_notify_url": "http://127.0.0.1:9/a\nb"}'
  grep -q 'backrest_notify_url must' "$out/converge.log" || fail "no message about the notify URL"

  # A fresh install has its grace period, from the first-run marker.
  h rm -f "$data_dir/last-success"
  h touch "$data_dir/first-run"
  role_converge -e "@$out/reports-apps.json"
  # Too old: everything converges first, then the run fails, naming the age.
  h touch -d '26 hours ago' "$data_dir/first-run"
  role_converge_fails -e "@$out/reports-apps.json" -e '{"backrest_schedule": "0 1 * * *"}'
  grep -q 'older than 25 hours' "$out/converge.log" || fail "no message about the age"
  [ "$(cfg '.plans[0].schedule.cron')" = '0 1 * * *' ] || fail "the configuration was not applied before the age check failed"
  # The verdict is read before the role starts a stopped service.
  run_backup
  [ "$(last_status)" = STATUS_SUCCESS ] || fail "the backup did not succeed"
  h touch -d '26 hours ago' "$data_dir/last-success"
  h systemctl stop backrest
  role_converge_fails -e "@$out/reports-apps.json"
  grep -q 'older than 25 hours' "$out/converge.log" || fail "a stopped service hid the missed night"
  [ "$(h systemctl is-active backrest)" = active ] || fail "the role did not start the service"
  run_backup
  [ "$(last_status)" = STATUS_SUCCESS ] || fail "the backup did not succeed again"
  role_converge_unchanged -e "@$out/reports-apps.json"
}

# write_contract <file>: the measured answers. No value may depend on the run.
write_contract() {
  cat >"$1" <<CONTRACT
# Backrest $version: the measured contract

Written by \`tests/backrest/run.sh\` (scenario \`contract\`) from a real Backrest
$version. Do not edit it by hand; run \`NOIXDEV_INFRA_BACKREST_TESTS=contract
tests/all.sh backrest\` instead.

\`\`\`text
sha256_x86_64: $sha256_x86_64
sha256_arm64: $sha256_arm64
binary_in_archive: $binary_in_archive
bcrypt_command: $bcrypt_command
guid_written_back: $guid_written_back
restart_rewrites_config: $restart_rewrites_config
exclude_file_flag: $exclude_file_flag
start_hook_fatal: $start_hook_fatal
finish_marks_failed: $finish_marks_failed
report_count: start_hook=$report_start_hook finish_hook=$report_finish_hook restic_error=$report_restic_error
backup_rpc: POST /v1.Backrest/Backup {"value":"<plan id>"}
ui_status: $ui_status
\`\`\`

## Details

\`\`\`text
restic_binary: $restic_binary
login: wrong password $api_wrong_password, no login $api_no_login
backup_rpc_blocks: $backup_rpc_blocks (a 4 second start hook; answers $backup_rpc_status when the backup succeeded)
start_hook: status $start_hook_status, new snapshots $start_hook_new_snapshots, RPC $start_hook_rpc
finish_hook: status $finish_hook_status, new snapshots $finish_hook_new_snapshots, RPC $finish_hook_rpc, CONDITION_ANY_ERROR reports $report_finish_hook
restic_error: status $restic_error_status, RPC $restic_error_rpc
report_healthchecks: $report_healthchecks to $report_healthchecks_path
report_webhook: $report_webhook (backup status $webhook_status)
\`\`\`
CONTRACT
}

# All scenarios by default; NOIXDEV_INFRA_BACKREST_TESTS="refusals install" runs only these.
scenarios="${NOIXDEV_INFRA_BACKREST_TESTS:-contract refusals install config apps reports}"
first=
for ubuntu in $releases; do
  start_host "$ubuntu"
  for scenario in $scenarios; do
    case "$scenario" in
      contract) test_contract "$ubuntu" ;;
      refusals) test_refusals "$ubuntu" ;;
      install) test_install "$ubuntu" ;;
      config) test_config "$ubuntu" ;;
      apps) test_apps "$ubuntu" ;;
      reports) test_reports "$ubuntu" ;;
      *) fail "unknown scenario $scenario (contract, refusals, install, config, apps, reports)" ;;
    esac
  done
  case " $scenarios " in
    *" contract "*)
      if [ -z "$first" ]; then
        first="$ubuntu"
      else
        diff "$out/contract-$first.md" "$out/contract-$ubuntu.md" >&2 \
          || fail "Backrest behaves differently on Ubuntu $first and $ubuntu"
      fi
      ;;
  esac
  cleanup
done
case " $scenarios " in
  *" contract "*) cp "$out/contract-$first.md" "$here/contract.md" ;;
esac

noix_done
echo "== all backrest tests passed"
