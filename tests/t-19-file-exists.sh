#!/bin/sh
. "$(dirname "$0")/common.sh"
setup
trap teardown EXIT
PASEO_MONITOR_LOG_MAX_BYTES=100000
export PASEO_MONITOR_LOG_MAX_BYTES
source_monitor
unset PM_SOURCE_ONLY
tab="$(printf '\t')"

# A pre-agreed receipt path observes absence before the submitter's artifact exists.
mock_ssh_script "1${tab}"
absent_registration="$($PMT_BIN watch --kind file-exists --host polaris --path /scratch/run/receipt --no-start-report --deadline +300)" || fail "remote ABSENT registration failed"
absent_id=$(printf '%s\n' "$absent_registration" | sed -n 's/^watch \([^ ]*\) registered.*/\1/p')
absent_dir="$PM_HOME/watches/$absent_id"
assert_eq "$(cat "$absent_dir/last")" ABSENT "missing remote receipt token"
assert_grep "$MOCK_DIR/calls.log" 'ssh -o BatchMode=yes -o ConnectTimeout=15 polaris ls -d /scratch/run/receipt' "remote file-exists SSH discipline"
$PMT_BIN ls > "$SANDBOX/ls.out"
assert_grep "$SANDBOX/ls.out" 'target=polaris:/scratch/run/receipt' "remote file-exists target names the host"

mock_ssh_script "0${tab}/scratch/run/receipt"
printf '0\n' > "$absent_dir/nextDue"
$PMT_BIN _sweep || fail "remote EXISTS sweep failed"
assert_eq "$(cat "$absent_dir/last")" EXISTS "remote receipt appearance token"
assert_eq "$(grep -c ' REPORT ' "$absent_dir/log")" 1 "ABSENT to EXISTS edge report"
assert_grep "$absent_dir/log" 'class=terminal.*new=EXISTS' "EXISTS report envelope"

# A receipt that remains absent still produces one deadline event, not a poll storm.
mock_ssh_script "1${tab}"
deadline_registration="$($PMT_BIN watch --kind file-exists --host polaris --path /scratch/run/never --no-start-report --deadline +1)" || fail "deadline ABSENT registration failed"
deadline_id=$(printf '%s\n' "$deadline_registration" | sed -n 's/^watch \([^ ]*\) registered.*/\1/p')
deadline_dir="$PM_HOME/watches/$deadline_id"
assert_eq "$(cat "$deadline_dir/last")" ABSENT "deadline watch starts absent"
sleep 2
$PMT_BIN _sweep || fail "deadline sweep failed"
$PMT_BIN _sweep || fail "repeat deadline sweep failed"
assert_eq "$(cat "$deadline_dir/state")" expired "absent watch expires at deadline"
assert_eq "$(grep -c ' REPORT .*class=deadline' "$deadline_dir/log")" 1 "deadline fires exactly once"
echo PASS: remote file-exists ABSENT to EXISTS and deadline absence
