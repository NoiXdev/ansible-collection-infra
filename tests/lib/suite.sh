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

# noix_lock DIR: waits until this suite holds the lock directory DIR, for a
# cache that two suites running at the same time (tests/all.sh -j) share.
# mkdir is atomic; DIR/pid names the holder, and a lock whose holder is gone
# (a suite that was killed) is taken over. noix_unlock DIR releases it.
noix_lock() {
  local dir="$1" pid
  until mkdir "$dir" 2>/dev/null; do
    pid="$(cat "$dir/pid" 2>/dev/null || true)"
    if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then
      # Read again: another waiter may have taken the stale lock meanwhile.
      [ "$(cat "$dir/pid" 2>/dev/null || true)" != "$pid" ] || rm -rf "$dir"
      continue
    fi
    sleep 1
  done
  echo "$$" >"$dir/pid"
}

noix_unlock() {
  [ "$(cat "$1/pid" 2>/dev/null || true)" != "$$" ] || rm -rf "$1"
}
