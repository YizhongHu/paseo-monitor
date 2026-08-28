#!/bin/sh
. "$(dirname "$0")/common.sh"
setup
trap teardown EXIT
split_output="$(source_monitor; printf '%s|%s|%s|%s|%s\n' "$PM_HOME" "$PM_LOG_MAX_BYTES" "$PM_LOCK_GRACE_SECONDS" "$PM_BACKOFF_SCALE" "$PM_FAST_SWEEP")"
assert_eq "$split_output" "$PASEO_MONITOR_HOME|128|0|0|1" "PM knob values"
# The runtime source has one startup read for each public knob and no runtime
# lookup of the external names outside the startup block and usage text.
assert_grep "$PMT_BIN" 'PM_HOME="${PASEO_MONITOR_HOME:-' "home startup read"
assert_grep "$PMT_BIN" 'PM_FAST_SWEEP="${PASEO_MONITOR_FAST_SWEEP:-' "fast startup read"
echo PASS: external PASEO_MONITOR knobs split into PM variables
