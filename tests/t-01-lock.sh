#!/bin/sh
. "$(dirname "$0")/common.sh"
setup
trap teardown EXIT
source_monitor
ensure_dirs "$PM_HOME"
acquire_lock "$PM_HOME" || fail "first acquire failed"
[ -f "$PM_HOME/sweep.lock/pid" ] || fail "pid file missing"
release_lock "$PM_HOME" || fail "release failed"

# A live monitor process must contend for the lock.
sh -c 'PM_SOURCE_ONLY=1; export PM_SOURCE_ONLY; . "$1"; acquire_lock "$2"; sleep 2' sh "$PMT_BIN" "$PM_HOME" &
holder=$!
sleep 1
if acquire_lock "$PM_HOME"; then fail "contender acquired live lock"; fi
kill "$holder" 2>/dev/null || true
wait "$holder" 2>/dev/null || true

# A dead pid is stale and can be recovered.
mkdir -p "$PM_HOME/sweep.lock"
printf '999999\n' > "$PM_HOME/sweep.lock/pid"
acquire_lock "$PM_HOME" || fail "stale lock was not recovered"
assert_eq "$(cat "$PM_HOME/sweep.lock/pid")" "$$" "recovered pid"
release_lock "$PM_HOME" || fail "final release failed"
echo PASS: lock acquire, contention, stale-pid recovery
