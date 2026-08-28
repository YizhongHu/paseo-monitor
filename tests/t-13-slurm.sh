#!/bin/sh
. "$(dirname "$0")/common.sh"
setup
trap teardown EXIT
PASEO_MONITOR_LOG_MAX_BYTES=100000
export PASEO_MONITOR_LOG_MAX_BYTES
source_monitor
unset PM_SOURCE_ONLY
tab="$(printf '\t')"

# Accounting lag is a healthy observation and maps to PENDING.
mock_ssh_script "0${tab}"
lag_reg="$($PMT_BIN watch --kind slurm --host cannon --job lag-1 --no-start-report --deadline +300)" || fail "accounting lag registration failed"
lag_id=$(printf '%s\n' "$lag_reg" | sed -n 's/^watch \([^ ]*\) registered.*/\1/p')
lag_dir="$PM_HOME/watches/$lag_id"
assert_eq "$(cat "$lag_dir/last")" PENDING "empty sacct output maps to PENDING"
assert_grep "$MOCK_DIR/calls.log" 'ssh -o BatchMode=yes -o ConnectTimeout=15 cannon sacct -X -j lag-1' "Slurm SSH flags"
pm_atomic_write "$lag_dir/nextDue" 9999999999

# sacct's first word is authoritative, including CANCELLED and TIMEOUT.
mock_ssh_script "0${tab}RUNNING"
term_reg="$($PMT_BIN watch --kind slurm --host cannon --job term-1 --no-start-report --deadline +300)" || fail "terminal registration failed"
term_id=$(printf '%s\n' "$term_reg" | sed -n 's/^watch \([^ ]*\) registered.*/\1/p')
term_dir="$PM_HOME/watches/$term_id"
mock_ssh_script "0${tab}CANCELLED by 12345"
pm_atomic_write "$term_dir/nextDue" 0
$PMT_BIN _sweep || fail "cancelled sweep failed"
assert_eq "$(cat "$term_dir/last")" CANCELLED "cancelled first-word extraction"
assert_grep "$term_dir/log" 'new=CANCELLED' "cancelled terminal report"

mock_ssh_script "0${tab}RUNNING"
time_reg="$($PMT_BIN watch --kind slurm --host cannon --job timeout-1 --no-start-report --deadline +300)" || fail "timeout registration failed"
time_id=$(printf '%s\n' "$time_reg" | sed -n 's/^watch \([^ ]*\) registered.*/\1/p')
time_dir="$PM_HOME/watches/$time_id"
mock_ssh_script "0${tab}TIMEOUT"
pm_atomic_write "$time_dir/nextDue" 0
$PMT_BIN _sweep || fail "timeout sweep failed"
assert_eq "$(cat "$time_dir/last")" TIMEOUT "TIMEOUT terminal token"
assert_eq "$(cat "$time_dir/state")" terminal "TIMEOUT terminal state"

# UNKNOWN is reportable once, not silently retried as a health failure.
mock_ssh_script "0${tab}RUNNING"
unknown_reg="$($PMT_BIN watch --kind slurm --host cannon --job unknown-1 --no-start-report --deadline +300)" || fail "unknown registration failed"
unknown_id=$(printf '%s\n' "$unknown_reg" | sed -n 's/^watch \([^ ]*\) registered.*/\1/p')
unknown_dir="$PM_HOME/watches/$unknown_id"
mock_ssh_script "0${tab}UNKNOWN"
pm_atomic_write "$unknown_dir/nextDue" 0
$PMT_BIN _sweep || fail "unknown sweep failed"
mock_ssh_script "0${tab}UNKNOWN"
pm_atomic_write "$unknown_dir/nextDue" 0
$PMT_BIN _sweep || fail "repeated unknown sweep failed"
assert_eq "$(grep -c ' REPORT ' "$unknown_dir/log")" 1 "UNKNOWN reported once"
assert_eq "$(cat "$unknown_dir/health")" '0 healthy' "UNKNOWN is not probe failure"

pm_atomic_write "$unknown_dir/nextDue" 9999999999
# Reason mode executes sacct and squeue together and makes a compound token.
: > "$MOCK_DIR/calls.log"
reason_tab="$(printf '\t')"
mock_ssh_script "0${reason_tab}PENDING\\nPASEO_MONITOR_SQUEUE\\nPENDING|Priority"
reason_reg="$($PMT_BIN watch --kind slurm --host cannon --job reason-1 --report-on PENDING:Priority,PENDING:Resources --no-start-report --deadline +300)" || fail "reason registration failed"
reason_id=$(printf '%s\n' "$reason_reg" | sed -n 's/^watch \([^ ]*\) registered.*/\1/p')
reason_dir="$PM_HOME/watches/$reason_id"
assert_eq "$(grep '^interval=' "$reason_dir/spec" | cut -d= -f2)" 300 "transition-reporting Slurm default interval"
assert_eq "$(cat "$reason_dir/last")" PENDING:Priority "reason compound token"
assert_grep "$MOCK_DIR/calls.log" 'sacct -X -j' "reason sacct invocation"
assert_grep "$MOCK_DIR/calls.log" 'squeue -h -j' "reason squeue invocation"
assert_eq "$(grep -c '^ssh ' "$MOCK_DIR/calls.log")" 1 "reason one SSH round trip"
mock_ssh_script "0${reason_tab}PENDING\\nPASEO_MONITOR_SQUEUE\\nPENDING|Resources"
pm_atomic_write "$reason_dir/nextDue" 0
$PMT_BIN _sweep || fail "reason transition sweep failed"
assert_eq "$(cat "$reason_dir/last")" PENDING:Resources "reason transition token"
assert_grep "$reason_dir/log" 'class=transition' "reason transition report"
pm_atomic_write "$reason_dir/nextDue" 9999999999

# Without reason reporting, squeue is not fetched; an empty sacct observation
# after RUNNING is not enough evidence for VANISHED.
mock_ssh_script "0${tab}RUNNING"
: > "$MOCK_DIR/calls.log"
off_reg="$($PMT_BIN watch --kind slurm --host cannon --job reason-off --no-start-report --deadline +300)" || fail "reason-off registration failed"
off_id=$(printf '%s\n' "$off_reg" | sed -n 's/^watch \([^ ]*\) registered.*/\1/p')
off_dir="$PM_HOME/watches/$off_id"
mock_ssh_script "0${tab}"
pm_atomic_write "$off_dir/nextDue" 0
$PMT_BIN _sweep || fail "reason-off sweep failed"
assert_eq "$(cat "$off_dir/last")" PENDING "reason-off stable token"
assert_eq "$(grep '^interval=' "$off_dir/spec" | cut -d= -f2)" 600 "terminal-only Slurm default interval"
if grep -q 'squeue' "$MOCK_DIR/calls.log"; then fail "reason-off path touched squeue"; fi
if grep -q ' REPORT ' "$off_dir/log"; then fail "reason-off path emitted spurious edge"; fi
pm_atomic_write "$off_dir/nextDue" 9999999999

# Both accounting and queue disappearance after an observed running job is VANISHED.
mock_ssh_script "0${reason_tab}RUNNING\\nPASEO_MONITOR_SQUEUE\\nRUNNING|None"
vanish_reg="$($PMT_BIN watch --kind slurm --host cannon --job vanish-1 --with-reason --no-start-report --deadline +300)" || fail "vanished registration failed"
vanish_id=$(printf '%s\n' "$vanish_reg" | sed -n 's/^watch \([^ ]*\) registered.*/\1/p')
vanish_dir="$PM_HOME/watches/$vanish_id"
mock_ssh_script "0${reason_tab}\\nPASEO_MONITOR_SQUEUE\\n"
pm_atomic_write "$vanish_dir/nextDue" 0
$PMT_BIN _sweep || fail "vanished sweep failed"
assert_eq "$(cat "$vanish_dir/last")" VANISHED "vanished token"
assert_grep "$vanish_dir/log" 'new=VANISHED' "vanished report"
# Concurrent consumers must each receive one scripted response.
mock_ssh_script "0${tab}LOCK-A" "0${tab}LOCK-B" "0${tab}LOCK-C" "0${tab}LOCK-D"
ssh cannon lock-a > "$SANDBOX/ssh-a" &
ssh cannon lock-b > "$SANDBOX/ssh-b" &
ssh cannon lock-c > "$SANDBOX/ssh-c" &
ssh cannon lock-d > "$SANDBOX/ssh-d" &
wait
cat "$SANDBOX"/ssh-? | sort > "$SANDBOX/ssh-all"
assert_eq "$(cat "$SANDBOX/ssh-all" | sort)" "LOCK-A
LOCK-B
LOCK-C
LOCK-D" "concurrent scripted SSH responses"
assert_eq "$(wc -l < "$MOCK_DIR/ssh.script" | tr -d ' ')" 0 "concurrent script fully consumed"

echo PASS: Slurm accounting, terminal, anomaly, reason, and SSH-round-trip behavior
