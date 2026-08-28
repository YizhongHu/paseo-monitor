#!/bin/sh
. "$(dirname "$0")/common.sh"
setup
trap teardown EXIT
PASEO_MONITOR_LOG_MAX_BYTES=100000
export PASEO_MONITOR_LOG_MAX_BYTES
export PASEO_AGENT_ID=cancellation-test

cat > "$SANDBOX/probe" <<'EOF'
#!/bin/sh
if [ -f "$MOCK_DIR/done" ]; then
    printf 'DONE terminal\n'
else
    printf 'RUNNING active\n'
fi
EOF
chmod +x "$SANDBOX/probe"
cat > "$SANDBOX/deliver" <<'EOF'
#!/bin/sh
cat >> "$MOCK_DIR/reports"
EOF
chmod +x "$SANDBOX/deliver"
: > "$MOCK_DIR/reports"

count_reports() {
    awk '/MONITOR REPORT/ {count++} END {print count + 0}' "$1"
}

# An active watch that has never fired reports exactly one cancellation with
# the last observation as its old token.
active_reg="$($PMT_BIN watch --script "$SANDBOX/probe" --reason 'cancel active watch' --terminal DONE --no-start-report --deliver "$SANDBOX/deliver" --deadline +300)" || fail "active registration failed"
active_id=$(printf '%s\n' "$active_reg" | sed -n 's/^watch \([^ ]*\) registered.*/\1/p')
[ -n "$active_id" ] || fail "active watch id missing"
active_dir="$PM_HOME/watches/$active_id"
assert_eq "$(cat "$active_dir/last")" RUNNING "active last token"
$PMT_BIN rm "$active_id" || fail "active rm failed"
assert_eq "$(count_reports "$MOCK_DIR/reports")" 1 "active cancellation report count"
assert_grep "$MOCK_DIR/reports" "watch=$active_id" "active cancellation watch"
assert_grep "$MOCK_DIR/reports" 'class=cancelled' "active cancellation class"
assert_grep "$MOCK_DIR/reports" 'old=RUNNING' "active cancellation old token"
assert_grep "$MOCK_DIR/reports" 'new=CANCELLED' "active cancellation new token"

# A watch that already delivered its terminal event does not report again on rm.
: > "$MOCK_DIR/reports"
printf 'DONE terminal\n' > "$MOCK_DIR/done"
fired_reg="$($PMT_BIN watch --script "$SANDBOX/probe" --reason 'cancel fired watch' --terminal DONE --no-start-report --deliver "$SANDBOX/deliver" --deadline +300)" || fail "fired registration failed"
fired_id=$(printf '%s\n' "$fired_reg" | sed -n 's/^watch \([^ ]*\) registered.*/\1/p')
fired_dir="$PM_HOME/watches/$fired_id"
assert_eq "$(count_reports "$MOCK_DIR/reports")" 1 "fired initial report count"
$PMT_BIN rm "$fired_id" || fail "fired rm failed"
assert_eq "$(count_reports "$MOCK_DIR/reports")" 1 "fired rm report count"
rm -f "$MOCK_DIR/done"

# rm --all applies the owed-cancellation rule independently to every watch.
: > "$MOCK_DIR/reports"
all_one_reg="$($PMT_BIN watch --script "$SANDBOX/probe" --reason 'bulk cancellation one' --terminal DONE --no-start-report --deliver "$SANDBOX/deliver" --deadline +300)" || fail "bulk one registration failed"
all_one_id=$(printf '%s\n' "$all_one_reg" | sed -n 's/^watch \([^ ]*\) registered.*/\1/p')
all_two_reg="$($PMT_BIN watch --script "$SANDBOX/probe" --reason 'bulk cancellation two' --terminal DONE --no-start-report --deliver "$SANDBOX/deliver" --deadline +300)" || fail "bulk two registration failed"
all_two_id=$(printf '%s\n' "$all_two_reg" | sed -n 's/^watch \([^ ]*\) registered.*/\1/p')
$PMT_BIN rm --all || fail "bulk rm failed"
assert_eq "$(count_reports "$MOCK_DIR/reports")" 2 "bulk cancellation report count"
assert_grep "$MOCK_DIR/reports" "watch=$all_one_id.*class=cancelled" "bulk first cancellation"
assert_grep "$MOCK_DIR/reports" "watch=$all_two_id.*class=cancelled" "bulk second cancellation"

# Removing a failsafe watch releases the daemon schedule before its directory vanishes.
failsafe_reg="$($PMT_BIN watch --script "$SANDBOX/probe" --reason 'rm failsafe cleanup' --terminal DONE --no-start-report --failsafe --provider claude --max-runs 1 --expires-in 5m --deliver "$SANDBOX/deliver" --deadline +300)" || fail "rm failsafe registration failed"
failsafe_id=$(printf '%s\n' "$failsafe_reg" | sed -n 's/^watch \([^ ]*\) registered.*/\1/p')
failsafe_dir="$PM_HOME/watches/$failsafe_id"
failsafe_schedule=$(cat "$failsafe_dir/failsafe")
[ -n "$failsafe_schedule" ] || fail "rm failsafe schedule marker missing"
$PMT_BIN rm "$failsafe_id" || fail "rm failsafe failed"
assert_grep "$MOCK_DIR/calls.log" "paseo schedule delete $failsafe_schedule" "rm failsafe schedule cleanup"
[ ! -f "$MOCK_DIR/schedule.$failsafe_schedule" ] || fail "rm failsafe schedule retained"

# Reaping an old terminal watch releases its schedule but remains silent.
: > "$MOCK_DIR/reports"
reap_reg="$($PMT_BIN watch --script "$SANDBOX/probe" --reason 'reap failsafe cleanup' --terminal DONE --no-start-report --failsafe --provider claude --max-runs 1 --expires-in 5m --deliver "$SANDBOX/deliver" --deadline +300)" || fail "reap failsafe registration failed"
reap_id=$(printf '%s\n' "$reap_reg" | sed -n 's/^watch \([^ ]*\) registered.*/\1/p')
reap_dir="$PM_HOME/watches/$reap_id"
reap_schedule=$(cat "$reap_dir/failsafe")
printf '%s\n' terminal > "$reap_dir/state"
reap_deadline=$(( $(date +%s) - 2592001 ))
printf '%s\n' "$(sed "s/^deadline=.*/deadline=$reap_deadline/" "$reap_dir/spec")" > "$reap_dir/spec"
$PMT_BIN reap || fail "reap failed"
assert_eq "$(count_reports "$MOCK_DIR/reports")" 0 "reap report count"
assert_grep "$MOCK_DIR/calls.log" "paseo schedule delete $reap_schedule" "reap schedule cleanup"
[ ! -d "$reap_dir" ] || fail "reaped watch retained"

# The launchd-style minimal PATH still cleans up an absolute snapshotted paseo.
: > "$MOCK_DIR/reports"
printf 'RUNNING active\n' > "$SANDBOX/mode"
cat > "$SANDBOX/minimal-probe" <<'EOF'
#!/bin/sh
if [ -f "$MOCK_DIR/mode" ]; then
    cat "$MOCK_DIR/mode"
else
    printf 'RUNNING active\n'
fi
EOF
chmod +x "$SANDBOX/minimal-probe"
minimal_reg="$($PMT_BIN watch --script "$SANDBOX/minimal-probe" --reason 'minimal PATH cleanup' --terminal DONE --no-start-report --failsafe --provider claude --max-runs 1 --expires-in 5m --deliver "$SANDBOX/deliver" --deadline +300)" || fail "minimal PATH registration failed"
minimal_id=$(printf '%s\n' "$minimal_reg" | sed -n 's/^watch \([^ ]*\) registered.*/\1/p')
minimal_dir="$PM_HOME/watches/$minimal_id"
minimal_schedule=$(cat "$minimal_dir/failsafe")
printf 'DONE terminal\n' > "$MOCK_DIR/mode"
printf '0\n' > "$minimal_dir/nextDue"
pmt_sweep_minimal_path || fail "minimal PATH sweep failed"
assert_grep "$MOCK_DIR/calls.log" "paseo schedule delete $minimal_schedule" "minimal PATH schedule cleanup"
[ ! -f "$MOCK_DIR/schedule.$minimal_schedule" ] || fail "minimal PATH schedule retained"
assert_grep "$MOCK_DIR/reports" "watch=$minimal_id.*class=terminal" "minimal PATH terminal report"

echo PASS: cancellation reporting, bulk removal, reap, and failsafe cleanup
