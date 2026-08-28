#!/bin/sh
. "$(dirname "$0")/common.sh"
setup
trap teardown EXIT
PASEO_MONITOR_LOG_MAX_BYTES=100000
export PASEO_MONITOR_LOG_MAX_BYTES

cat > "$SANDBOX/probe" <<'EOF'
#!/bin/sh
if [ -f "$MOCK_DIR/done" ]; then printf 'DONE observed\n'; else printf 'RUNNING observed\n'; fi
EOF
chmod +x "$SANDBOX/probe"
cat > "$SANDBOX/deliver" <<'EOF'
#!/bin/sh
cat > "$MOCK_DIR/report"
EOF
chmod +x "$SANDBOX/deliver"
prohibit='never scancel job 42124320'
registration="$($PMT_BIN watch --script "$SANDBOX/probe" --reason 'failsafe test' --terminal DONE --failsafe --provider claude --max-runs 1 --expires-in 5m --prohibit "$prohibit" --deliver "$SANDBOX/deliver" --deadline +300)" || fail "failsafe registration failed"
id=$(printf '%s\n' "$registration" | sed -n 's/^watch \([^ ]*\) registered.*/\1/p')
dir="$PM_HOME/watches/$id"
schedule_id=$(cat "$dir/failsafe")
[ -n "$schedule_id" ] || fail "failsafe schedule id missing"
assert_grep "$MOCK_DIR/calls.log" 'paseo schedule create .*--every 5m --max-runs 1 --expires-in 5m --provider claude --json' "bounded schedule create"
prompt_file="$MOCK_DIR/schedule.$schedule_id"
assert_grep "$prompt_file" "status $id" "pointer-only watch id"
assert_grep "$prompt_file" "$prohibit" "failsafe prohibition"
if grep -Eq 'target=|report-to|context=|labels=' "$prompt_file"; then fail "failsafe prompt contains routing"; fi
: > "$MOCK_DIR/done"
printf '0\n' > "$dir/nextDue"
$PMT_BIN _sweep || fail "failsafe terminal sweep failed"
assert_grep "$MOCK_DIR/calls.log" "paseo schedule delete $schedule_id" "schedule cleanup"
[ ! -f "$dir/failsafe" ] || fail "failsafe schedule marker retained after clean delivery"
[ ! -f "$prompt_file" ] || fail "mock schedule was not deleted"
assert_eq "$(cat "$dir/state")" terminal "terminal state retained"
echo PASS: bounded pointer-only failsafe schedule and clean-delivery cleanup
