# shellcheck shell=bash
# Shared by every Docker test suite (tests/run.sh, tests/*/run.sh); source it,
# do not run it. Works under bash 3.2 (macOS): no associative arrays, no
# mapfile, no ${var,,}, no declare -n.
#
#   . "$(dirname "$0")/../lib/suite.sh"   # path of the suite to tests/lib
#   cleanup() { ...; }                    # optional
#   noix_exit_guard
#   ...
#   noix_done                             # end of the suite, and before an
#                                         # intended early "exit 0"

noix_finished=0

# Under bash 3.2, "set -u" on an unbound variable runs the EXIT trap with
# $?=0, so the suite would exit 0 although it stopped on an error. A suite
# that reaches its end (or an intended early exit) says so with noix_done.
noix_on_exit() {
  local rc=$?
  trap - EXIT
  if declare -F cleanup >/dev/null; then
    cleanup || true
  fi
  if [ "$rc" = 0 ] && [ "$noix_finished" != 1 ]; then
    rc=1
    echo "== stopped before the end (an error without exit status)" >&2
  fi
  exit "$rc"
}

noix_exit_guard() {
  trap noix_on_exit EXIT
}

noix_done() {
  noix_finished=1
}

# noix_link_collection ROOT TESTS_OUTPUT_DIR: makes
# TESTS_OUTPUT_DIR/ansible_collections/noixdev/infra a symlink to ROOT. Suites
# share that link, so it must not be rewritten while it is correct (ln -sfn
# removes and recreates it, and a suite reading it at that moment fails), and a
# second suite creating it at the same time must not fail this one.
noix_link_collection() {
  local root="$1" dir link
  dir="$2/ansible_collections/noixdev"
  link="$dir/infra"
  mkdir -p "$dir"
  [ "$(readlink "$link" 2>/dev/null || true)" != "$root" ] || return 0
  if [ -L "$link" ]; then
    rm -f "$link"
  fi
  if [ -d "$link" ] && [ ! -L "$link" ]; then
    echo "cannot link $link to $root: a directory is in the way" >&2
    return 1
  fi
  # -n: never follow an existing link or directory at $link into $root. Whether
  # ln succeeded or lost a race, the link must now point at the root.
  ln -sn "$root" "$link" 2>/dev/null || true
  [ "$(readlink "$link" 2>/dev/null || true)" = "$root" ] || {
    echo "cannot link $link to $root" >&2
    return 1
  }
}

# noix_lock FILE: waits until this suite holds an exclusive lock on FILE, for
# a cache that two suites running at the same time (tests/all.sh -j) share.
# The lock is a flock on file descriptor 9, which the shell keeps open (python3
# takes it on that descriptor and exits); it ends with noix_unlock or when the
# suite's process ends, however it ends, so a killed suite leaves no stale
# lock. A command run while it is held inherits the descriptor and holds the
# lock as long as it runs: give each one 9>&-, so that one left behind does
# not. One lock at a time per suite.
noix_lock() {
  exec 9>>"$1" || return 1
  python3 -I -c 'import fcntl; fcntl.flock(9, fcntl.LOCK_EX)'
}

noix_unlock() {
  exec 9>&-
}

# --- the tests' caching stack (tests/cache.sh) -------------------------------
# With the stack up and NOIXDEV_INFRA_TEST_CACHE not 0, a test host's apt
# fetches over http, its Docker daemon's Docker Hub pulls and its name lookups
# go through the stack (apt-cacher-ng, a registry proxy, a logging resolver) on
# Docker's default bridge. Each helper prints its arguments one per line, and
# nothing at all when the cache is off or a service of the stack is down, so a
# suite then runs exactly as without the stack. noix_cache_array collects the
# lines into an array:
#   noix_cache_array cache noix_cache_run_args
#   docker run -d ... ${cache[@]+"${cache[@]}"} IMAGE

# noix_cache_on: the cache is wanted and every service of the stack runs.
noix_cache_on() {
  [ "${NOIXDEV_INFRA_TEST_CACHE:-1}" != 0 ] || return 1
  local s
  for s in noix-test-apt noix-test-hub noix-test-dns; do
    [ "$(docker inspect -f '{{.State.Running}}' "$s" 2>/dev/null)" = true ] || return 1
  done
}

# noix_cache_addr NAME: a stack container's address on the default bridge.
noix_cache_addr() {
  docker inspect -f '{{with index .NetworkSettings.Networks "bridge"}}{{.IPAddress}}{{end}}' "$1" 2>/dev/null
}

# noix_cache_array VAR COMMAND...: VAR becomes an array of COMMAND's lines.
noix_cache_array() {
  local __var="$1" __line
  shift
  eval "$__var=()"
  while IFS= read -r __line; do
    eval "$__var+=(\"\$__line\")"
  done < <("$@")
}

# noix_cache_run_args: docker run arguments of a test host (before the
# image): the logging resolver, which a Docker daemon in the host passes on to
# its containers.
noix_cache_run_args() {
  noix_cache_on || return 0
  local dns
  dns="$(noix_cache_addr noix-test-dns)"
  [ -n "$dns" ] || return 0
  printf '%s\n' --dns "$dns"
}

# noix_cache_dind_args: the arguments after a docker:<v>-dind image, for its
# dockerd: the Docker Hub mirror, and the resolver for the inner containers
# (the host's own would be skipped as a loopback one only on a user network,
# but the explicit one keeps them on the logging resolver either way).
noix_cache_dind_args() {
  noix_cache_on || return 0
  local hub dns
  hub="$(noix_cache_addr noix-test-hub)"
  dns="$(noix_cache_addr noix-test-dns)"
  [ -n "$hub" ] && [ -n "$dns" ] || return 0
  printf '%s\n' "--registry-mirror=http://$hub:5000" "--insecure-registry=$hub:5000" "--dns=$dns"
}

# noix_cache_host_setup CONTAINER: a systemd test host's apt fetches over http
# go through the apt cache (https stays direct); right after the host booted,
# before any play. Nothing for a host without apt.
noix_cache_host_setup() {
  noix_cache_on || return 0
  local apt
  apt="$(noix_cache_addr noix-test-apt)"
  [ -n "$apt" ] || return 0
  printf 'Acquire::http::Proxy "http://%s:3142";\n' "$apt" |
    docker exec -i "$1" sh -c '[ -d /etc/apt/apt.conf.d ] || exit 0; cat >/etc/apt/apt.conf.d/00noixdev-test-cache'
}

# noix_cache_play_args: ansible-playbook arguments for the plays of a suite
# whose test host gets Docker from the docker role: docker_daemon_extra with
# the Docker Hub mirror and the resolver. Not for a suite that checks the
# role's daemon.json or sets docker_daemon_extra itself.
noix_cache_play_args() {
  noix_cache_on || return 0
  local hub dns dir file
  hub="$(noix_cache_addr noix-test-hub)"
  dns="$(noix_cache_addr noix-test-dns)"
  [ -n "$hub" ] && [ -n "$dns" ] || return 0
  dir="${NOIX_CACHE_VARS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/output/cache}"
  file="$dir/docker-vars.yml"
  mkdir -p "$dir"
  # Written whole and renamed: suites running at the same time share it.
  printf '%s\n' "# Written by tests/lib/suite.sh (noix_cache_play_args)." "docker_daemon_extra:" \
    "  registry-mirrors: [\"http://$hub:5000\"]" "  insecure-registries: [\"$hub:5000\"]" \
    "  dns: [\"$dns\"]" >"$file.$$"
  mv -f "$file.$$" "$file"
  printf '%s\n' -e "@$file"
}
