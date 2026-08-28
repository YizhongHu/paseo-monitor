#!/bin/sh
. "$(dirname "$0")/common.sh"
setup
trap teardown EXIT
PASEO_MONITOR_LOG_MAX_BYTES=100000
export PASEO_MONITOR_LOG_MAX_BYTES

set_globus() {
    printf '%s\n' "$1" > "$MOCK_DIR/globus.output"
}
active_json='{"status":"ACTIVE","nice_status":"Transferring","faults":["NONE"],"fatal_error":null,"effective_bytes_per_second":12.5}'
inactive_json='{"status":"INACTIVE","nice_status":"Paused","faults":["SOURCE_UNAVAILABLE"],"fatal_error":null,"effective_bytes_per_second":0}'
succeeded_json='{"status":"SUCCEEDED","nice_status":"Succeeded","faults":[],"fatal_error":null,"effective_bytes_per_second":12.5}'
failed_json='{"status":"FAILED","nice_status":"Failed","faults":["NETWORK"],"fatal_error":"transfer failed","effective_bytes_per_second":0}'

set_globus "$active_json"
first_registration="$($PMT_BIN watch --kind globus --task TASK-1 --report-transitions --deadline +300)" || fail "Globus ACTIVE registration failed"
first_id=$(printf '%s\n' "$first_registration" | sed -n 's/^watch \([^ ]*\) registered.*/\1/p')
first_dir="$PM_HOME/watches/$first_id"
assert_eq "$(cat "$first_dir/last")" ACTIVE "ACTIVE token"
assert_grep "$first_dir/detail" 'nice_status=Transferring' "nice_status detail"
assert_grep "$first_dir/detail" 'faults=\["NONE"\]' "faults detail"
assert_grep "$first_dir/detail" 'effective_bytes_per_second=12.5' "throughput detail"
assert_grep "$MOCK_DIR/calls.log" 'globus task show TASK-1 -F json --jq' "built-in globus jq invocation"

set_globus "$inactive_json"
printf '0\n' > "$first_dir/nextDue"
$PMT_BIN _sweep || fail "INACTIVE sweep failed"
assert_eq "$(cat "$first_dir/last")" INACTIVE "INACTIVE token"
set_globus "$succeeded_json"
printf '0\n' > "$first_dir/nextDue"
$PMT_BIN _sweep || fail "SUCCEEDED sweep failed"
assert_eq "$(cat "$first_dir/last")" SUCCEEDED "SUCCEEDED token"
assert_eq "$(cat "$first_dir/state")" terminal "SUCCEEDED terminal state"

set_globus "$active_json"
second_registration="$($PMT_BIN watch --kind globus --task TASK-2 --deadline +300)" || fail "second Globus ACTIVE registration failed"
second_id=$(printf '%s\n' "$second_registration" | sed -n 's/^watch \([^ ]*\) registered.*/\1/p')
second_dir="$PM_HOME/watches/$second_id"
set_globus "$failed_json"
printf '0\n' > "$second_dir/nextDue"
$PMT_BIN _sweep || fail "FAILED sweep failed"
assert_eq "$(cat "$second_dir/last")" FAILED "FAILED token"
assert_eq "$(cat "$second_dir/state")" terminal "FAILED terminal state"
assert_grep "$second_dir/log" 'fatal_error=transfer failed' "fatal error detail"
echo PASS: Globus ACTIVE, INACTIVE, SUCCEEDED, FAILED, and detail fields
