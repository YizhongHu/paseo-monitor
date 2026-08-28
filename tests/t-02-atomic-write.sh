#!/bin/sh
. "$(dirname "$0")/common.sh"
setup
trap teardown EXIT
source_monitor
atomic_target="$PM_HOME/watches/example/state"
pm_atomic_write "$atomic_target" active || fail "atomic write failed"
assert_eq "$(cat "$atomic_target")" active "atomic content"
set_state "$PM_HOME/watches/example" parked || fail "set_state failed"
assert_eq "$(cat "$PM_HOME/watches/example/state")" parked "set_state content"
[ ! -e "$PM_HOME/watches/example/.tmp.$$.$(basename "$atomic_target")" ] || fail "temporary file remained"
printf 'next\n' > "$PM_HOME/watches/example/other"
pm_atomic_write "$PM_HOME/watches/example/other" terminal || fail "atomic replacement failed"
assert_eq "$(cat "$PM_HOME/watches/example/other")" terminal "atomic replacement"
echo PASS: atomic tmp+mv write
