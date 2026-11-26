#!/usr/bin/env bash
# The tests' caching stack (tests/cache/compose.yaml): apt over http
# (noix-test-apt), Docker Hub pulls (noix-test-hub) and a resolver that logs
# every query (noix-test-dns), on Docker's default bridge next to the test
# hosts. tests/all.sh starts it; the helpers in tests/lib/suite.sh point the
# test hosts at it.
#
#   tests/cache.sh up       build and start it (a running service stays as it
#                           is, so its address does not change), wait until all
#                           three answer, print their addresses
#   tests/cache.sh down     stop it; the caches' volumes stay
#   tests/cache.sh status   "up" (exit 0) when all three run, else "down" (1)
#   tests/cache.sh report [SINCE]
#                           the check mode: what went past the caches since
#                           SINCE (epoch or ISO time; default: the last up)
#
# Docker Hub credentials, if wanted, go in
# ~/.config/noixdev-infra/test-cache-hub.env (REGISTRY_PROXY_USERNAME,
# REGISTRY_PROXY_PASSWORD; mode 0600), never in the repository.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
compose=(docker compose -f "$here/cache/compose.yaml")
services=(noix-test-apt noix-test-hub noix-test-dns)

fail() { echo "tests/cache.sh: $*" >&2; exit 2; }
addr() { docker inspect -f '{{with index .NetworkSettings.Networks "bridge"}}{{.IPAddress}}{{end}}' "$1" 2>/dev/null; }
running() { [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = true ]; }
answers() {
  case "$1" in
    noix-test-apt) docker exec noix-test-apt bash -c 'exec 3<>/dev/tcp/127.0.0.1/3142' ;;
    noix-test-hub) docker exec noix-test-hub wget -q -O /dev/null http://127.0.0.1:5000/v2/ ;;
    noix-test-dns) docker exec noix-test-dns bash -c 'exec 3<>/dev/tcp/127.0.0.1/53' ;;
  esac >/dev/null 2>&1
}

up() {
  local out
  out="$("${compose[@]}" build -q 2>&1)" || fail "the stack's images do not build: $(tail -3 <<<"$out")"
  "${compose[@]}" up -d --quiet-pull >/dev/null 2>&1 || fail "the stack does not start: $("${compose[@]}" up -d 2>&1 | tail -3)"
  local s
  for s in "${services[@]}"; do
    for _ in $(seq 60); do
      answers "$s" && break
      sleep 1
    done
    answers "$s" || fail "$s does not answer"
  done
  docker exec noix-test-dns sh -c 'date +%s >/var/log/noix-dns/up-since'
  for s in "${services[@]}"; do
    echo "$s $(addr "$s")"
  done
}

status() {
  local s
  for s in "${services[@]}"; do
    running "$s" || { echo down; return 1; }
  done
  echo up
}

report() {
  local since="${1:-}" tmp
  status >/dev/null || fail "the stack is down; nothing to report"
  if [ -z "$since" ]; then
    since="$(docker exec noix-test-dns cat /var/log/noix-dns/up-since 2>/dev/null || echo 0)"
  elif ! [[ "$since" =~ ^[0-9]+$ ]]; then
    since="$(python3 -I -c 'import sys
from datetime import datetime, timezone
t = datetime.fromisoformat(sys.argv[1].replace("Z", "+00:00"))
print(int((t if t.tzinfo else t.replace(tzinfo=timezone.utc)).timestamp()))' "$since")" || fail "SINCE must be an epoch or an ISO time"
  fi
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064 # $tmp is fixed now
  trap "rm -rf '$tmp'" RETURN
  docker exec noix-test-dns cat /var/log/noix-dns/queries.log >"$tmp/dns.log" 2>/dev/null || true
  docker exec noix-test-apt cat /var/log/apt-cacher-ng/apt-cacher.log >"$tmp/apt.log" 2>/dev/null || true
  docker logs noix-test-hub >"$tmp/hub.log" 2>&1 || true
  python3 -I "$here/cache/report.py" --dns "$tmp/dns.log" --apt "$tmp/apt.log" --hub "$tmp/hub.log" --since "$since"
}

case "${1:-}" in
  up) up ;;
  down) "${compose[@]}" down >/dev/null 2>&1 || fail "the stack does not stop" ;;
  status) status ;;
  report) report "${2:-}" ;;
  *)
    echo "usage: tests/cache.sh up|down|status|report [SINCE]" >&2
    exit 2
    ;;
esac
