#!/bin/sh
. "$(dirname "$0")/common.sh"
setup
trap teardown EXIT
PASEO_MONITOR_LOG_MAX_BYTES=100000
export PASEO_MONITOR_LOG_MAX_BYTES
source_monitor
unset PM_SOURCE_ONLY

MOCK_GH_STATE=OPEN
export MOCK_GH_STATE
merged_registration="$($PMT_BIN watch --kind pr-merge --repo OWNER/REPO --pr 123 --no-start-report --deadline +300)" || fail "pr-merge MERGED registration failed"
merged_id=$(printf '%s\n' "$merged_registration" | sed -n 's/^watch \([^ ]*\) registered.*/\1/p')
merged_dir="$PM_HOME/watches/$merged_id"
assert_eq "$(cat "$merged_dir/last")" OPEN "PR starts open"
assert_grep "$MOCK_DIR/calls.log" 'gh pr view 123 --repo OWNER/REPO --json state --jq .state' "gh state invocation"

MOCK_GH_STATE=MERGED
export MOCK_GH_STATE
printf '0\n' > "$merged_dir/nextDue"
$PMT_BIN _sweep || fail "MERGED sweep failed"
assert_eq "$(cat "$merged_dir/last")" MERGED "MERGED state observed"
assert_eq "$(cat "$merged_dir/state")" terminal "MERGED is terminal"
assert_eq "$(grep -c ' REPORT ' "$merged_dir/log")" 1 "MERGED report"
assert_grep "$merged_dir/log" 'class=terminal.*new=MERGED' "MERGED terminal envelope"

MOCK_GH_STATE=OPEN
export MOCK_GH_STATE
closed_registration="$($PMT_BIN watch --kind pr-merge --repo OWNER/REPO --pr 124 --no-start-report --deadline +300)" || fail "pr-merge CLOSED registration failed"
closed_id=$(printf '%s\n' "$closed_registration" | sed -n 's/^watch \([^ ]*\) registered.*/\1/p')
closed_dir="$PM_HOME/watches/$closed_id"
assert_eq "$(cat "$closed_dir/last")" OPEN "second PR starts open"
assert_eq "$(cat "$closed_dir/state")" active "CLOSED watch starts active"
MOCK_GH_STATE=CLOSED
export MOCK_GH_STATE
printf '0\n' > "$closed_dir/nextDue"
$PMT_BIN _sweep || fail "CLOSED sweep failed"
assert_eq "$(cat "$closed_dir/state")" terminal "CLOSED is terminal"
assert_eq "$(grep -c ' REPORT ' "$closed_dir/log")" 1 "CLOSED report"
assert_grep "$closed_dir/log" 'class=terminal.*new=CLOSED' "CLOSED terminal envelope"
echo PASS: pr-merge MERGED and CLOSED terminal ruling
