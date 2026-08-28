#!/bin/sh
. "$(dirname "$0")/common.sh"
setup
trap teardown EXIT
PASEO_MONITOR_LOG_MAX_BYTES=100000
export PASEO_MONITOR_LOG_MAX_BYTES
source_monitor
unset PM_SOURCE_ONLY
tab="$(printf '\t')"

mock_ssh_script "0${tab}Job Id: 123.server\\n    job_state = R\\n    queue = workq"
registration="$($PMT_BIN watch --kind pbs --host polaris --job 123.server --deadline +300)" || fail "PBS registration failed"
watch_id=$(printf '%s\n' "$registration" | sed -n 's/^watch \([^ ]*\) registered.*/\1/p')
watch_dir="$PM_HOME/watches/$watch_id"
assert_eq "$(cat "$watch_dir/last")" R "PBS qstat running state"
assert_eq "$(grep '^interval=' "$watch_dir/spec" | cut -d= -f2)" 600 "PBS terminal-only default interval"
assert_grep "$watch_dir/detail" 'qstat=.*job_state = R' "PBS qstat detail"
assert_grep "$MOCK_DIR/calls.log" 'polaris qstat -f.*123.server' "PBS qstat SSH invocation"
if grep -q 'sacct\|squeue' "$MOCK_DIR/calls.log"; then fail "PBS path touched Slurm commands"; fi

mock_ssh_script "0${tab}Job Id: 123.server\\n    job_state = C\\n    exit_status = 0"
printf '0\n' > "$watch_dir/nextDue"
$PMT_BIN _sweep || fail "PBS completed sweep failed"
assert_eq "$(cat "$watch_dir/last")" C "PBS completed state"
assert_eq "$(cat "$watch_dir/state")" terminal "PBS C terminal state"
assert_grep "$watch_dir/log" 'class=terminal.*new=C' "PBS terminal report"

# A live-only miss falls back to qstat -x in the same SSH invocation.
historical_tab="$(printf '\t')"
mock_ssh_script "0${historical_tab}PASEO_MONITOR_PBS_HISTORICAL\\nJob Id: 124.server\\n    job_state = F\\n    exit_status = 0"
historical_reg="$($PMT_BIN watch --kind pbs --host polaris --job 124.server --deadline +300)" || fail "PBS historical registration failed"
historical_id=$(printf '%s\n' "$historical_reg" | sed -n 's/^watch \([^ ]*\) registered.*/\1/p')
historical_dir="$PM_HOME/watches/$historical_id"
assert_eq "$(cat "$historical_dir/last")" F "PBS qstat -x terminal state"
assert_grep "$MOCK_DIR/calls.log" 'qstat -x.*124.server' "PBS qstat -x invocation"

# A target missing from both live and historical lookup is an observed UNKNOWN.
mock_ssh_script "0${tab}Job Id: 125.server\\n    job_state = R"
unknown_reg="$($PMT_BIN watch --kind pbs --host polaris --job 125.server --deadline +300)" || fail "PBS unknown registration failed"
unknown_id=$(printf '%s\n' "$unknown_reg" | sed -n 's/^watch \([^ ]*\) registered.*/\1/p')
unknown_dir="$PM_HOME/watches/$unknown_id"
mock_ssh_script "0${historical_tab}PASEO_MONITOR_PBS_HISTORICAL"
printf '0\n' > "$unknown_dir/nextDue"
$PMT_BIN _sweep || fail "PBS unknown sweep failed"
assert_eq "$(cat "$unknown_dir/last")" UNKNOWN "PBS unknown live and historical state"
assert_grep "$unknown_dir/log" 'new=UNKNOWN' "PBS UNKNOWN report"

if $PMT_BIN watch --kind pbs --host polaris --job 999.server --interval 119 --deadline +300; then
    fail "PBS remote cadence floor accepted"
fi

# The existing Slurm parser remains independently callable and unchanged by PBS.
slurm_dir="$SANDBOX/slurm-watch"
mkdir -p "$slurm_dir"
printf 'COMPLETED\n' > "$slurm_dir/out"
printf 'COMPLETED\n' > "$slurm_dir/last"
pm_slurm_probe_output "$slurm_dir" "$slurm_dir/out"
pm_parse_probe_output "$slurm_dir/out" || fail "Slurm parser regression"
assert_eq "$PM_PARSED_TOKEN" COMPLETED "Slurm parser remains intact"
echo PASS: PBS qstat parsing, remote floor, and Slurm seam isolation
