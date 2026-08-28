#!/bin/sh
. "$(dirname "$0")/common.sh"
setup
trap teardown EXIT
PASEO_MONITOR_LOG_MAX_BYTES=100000
export PASEO_MONITOR_LOG_MAX_BYTES

cat > "$SANDBOX/mode" <<'EOF'
RUNNING
EOF
cat > "$SANDBOX/probe" <<EOF
#!/bin/sh
printf '%s observed\n' "\$(cat '$SANDBOX/mode')"
EOF
chmod +x "$SANDBOX/probe"
cat > "$SANDBOX/deliver" <<EOF
#!/bin/sh
cat >> '$MOCK_DIR/reports'
EOF
chmod +x "$SANDBOX/deliver"

# The default registration report carries the first observed token and does
# not consume a change-report fire.
registration="$($PMT_BIN watch --script "$SANDBOX/probe" --reason 'started default' --terminal DONE --deliver "$SANDBOX/deliver" --deadline +300)" || fail "default registration failed"
id=$(printf '%s\n' "$registration" | sed -n 's/^watch \([^ ]*\) registered.*/\1/p')
dir="$PM_HOME/watches/$id"
assert_eq "$(grep -c ' REPORT ' "$dir/log")" 1 "started report recorded"
assert_grep "$MOCK_DIR/reports" 'class=started' "started report class"
assert_grep "$MOCK_DIR/reports" 'old=(none) new=RUNNING' "started report token"
assert_eq "$(cat "$dir/fires")" 0 "started report does not consume fire"

# Lifecycle reports ignore report-on filtering.
filtered_registration="$($PMT_BIN watch --script "$SANDBOX/probe" --reason 'started filter' --terminal DONE --report-on NEVER --deliver "$SANDBOX/deliver" --deadline +300)" || fail "filtered registration failed"
filtered_id=$(printf '%s\n' "$filtered_registration" | sed -n 's/^watch \([^ ]*\) registered.*/\1/p')
assert_grep "$PM_HOME/watches/$filtered_id/log" 'REPORT .*class=started' "started ignores report-on"

# Explicit opt-out suppresses the registration report.
no_start_registration="$($PMT_BIN watch --script "$SANDBOX/probe" --reason 'started opt out' --terminal DONE --no-start-report --deliver "$SANDBOX/deliver" --deadline +300)" || fail "no-start registration failed"
no_start_id=$(printf '%s\n' "$no_start_registration" | sed -n 's/^watch \([^ ]*\) registered.*/\1/p')
if grep -q 'class=started' "$PM_HOME/watches/$no_start_id/log"; then
    fail "--no-start-report delivered a start report"
fi

# A start is exempt from --max-fires, so the first terminal change still
# delivers after a max-fires=1 registration.
printf 'RUNNING\n' > "$SANDBOX/mode"
max_registration="$($PMT_BIN watch --script "$SANDBOX/probe" --reason 'started max fires' --terminal DONE --max-fires 1 --deliver "$SANDBOX/deliver" --deadline +300)" || fail "max-fires registration failed"
max_id=$(printf '%s\n' "$max_registration" | sed -n 's/^watch \([^ ]*\) registered.*/\1/p')
max_dir="$PM_HOME/watches/$max_id"
printf 'DONE\n' > "$SANDBOX/mode"
printf '0\n' > "$max_dir/nextDue"
$PMT_BIN _sweep || fail "max-fires terminal sweep failed"
assert_grep "$max_dir/log" 'REPORT .*class=started.*old=(none) new=RUNNING' "max-fires start report"
assert_grep "$max_dir/log" 'REPORT .*class=terminal.*old=RUNNING new=DONE' "max-fires terminal report"
max_fires="$(cat "$max_dir/fires")"
[ "$max_fires" -ge 1 ] || fail "max-fires terminal fire missing"

# A refusing backend is best-effort: registration succeeds, remains active,
# and records the undelivered start report for retry.
cat > "$SANDBOX/refuse" <<EOF
#!/bin/sh
printf 'backend refused start report\n' >&2
exit 9
EOF
chmod +x "$SANDBOX/refuse"
printf 'RUNNING\n' > "$SANDBOX/mode"
refuse_registration="$($PMT_BIN watch --script "$SANDBOX/probe" --reason 'started refusal' --terminal DONE --deliver "$SANDBOX/refuse" --deadline +300 2>"$SANDBOX/refuse.err")" || fail "refusing backend failed registration"
refuse_id=$(printf '%s\n' "$refuse_registration" | sed -n 's/^watch \([^ ]*\) registered.*/\1/p')
refuse_dir="$PM_HOME/watches/$refuse_id"
assert_eq "$(cat "$refuse_dir/state")" active "refusing backend leaves watch active"
[ -f "$refuse_dir/undelivered" ] || fail "refusing backend missing undelivered start report"
assert_grep "$SANDBOX/refuse.err" 'WARN delivery-failed' "refusing backend warning"
assert_grep "$SANDBOX/refuse.err" 'backend refused start report' "refusing backend stderr"

# A terminal first observation subsumes the start lifecycle report.
printf 'DONE\n' > "$SANDBOX/mode"
terminal_registration="$($PMT_BIN watch --script "$SANDBOX/probe" --reason 'started terminal' --terminal DONE --deliver "$SANDBOX/deliver" --deadline +300)" || fail "terminal registration failed"
terminal_id=$(printf '%s\n' "$terminal_registration" | sed -n 's/^watch \([^ ]*\) registered.*/\1/p')
terminal_dir="$PM_HOME/watches/$terminal_id"
assert_eq "$(grep -c ' REPORT ' "$terminal_dir/log")" 1 "terminal first observation has one report"
assert_grep "$terminal_dir/log" 'REPORT .*class=terminal.*old=(none) new=DONE' "terminal first observation report"
if grep -q 'class=started' "$terminal_dir/log"; then
    fail "terminal first observation also emitted started"
fi

# A clean start delivery does not release a failsafe schedule.
printf 'RUNNING\n' > "$SANDBOX/mode"
failsafe_registration="$($PMT_BIN watch --script "$SANDBOX/probe" --reason 'started failsafe' --terminal DONE --failsafe --provider claude --max-runs 1 --expires-in 5m --deliver "$SANDBOX/deliver" --deadline +300)" || fail "failsafe registration failed"
failsafe_id=$(printf '%s\n' "$failsafe_registration" | sed -n 's/^watch \([^ ]*\) registered.*/\1/p')
[ -f "$PM_HOME/watches/$failsafe_id/failsafe" ] || fail "clean start delivery cleared failsafe"
assert_grep "$PM_HOME/watches/$failsafe_id/log" 'REPORT .*class=started' "failsafe start report"

echo PASS: started report lifecycle, cap exemption, retry, terminal subsumption, and failsafe retention
