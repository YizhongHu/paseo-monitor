#!/bin/sh
. "$(dirname "$0")/common.sh"
setup
trap teardown EXIT
PASEO_MONITOR_LOG_MAX_BYTES=100000
export PASEO_MONITOR_LOG_MAX_BYTES

cat > "$MOCK_DIR/inspect.json" <<'EOF'
{"Status":"RUNNING","Labels":{"role":"monitor","job":"42124320","item":"a1913cc1","lane":"F2"}}
EOF
export PASEO_AGENT_ID=agent-1
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
prohibit='never scancel job 42124320 and never resubmit it; this unconditional target constraint must survive envelope truncation'
registration="$($PMT_BIN watch --script "$SANDBOX/probe" --reason 'HARVEST test' --terminal DONE --report-transitions --no-start-report --label extra=value --prohibit "$prohibit" --deliver "$SANDBOX/deliver" --deadline +300)" || fail "HARVEST registration failed"
printf '%s\n' "$registration" > "$SANDBOX/registration.out"
assert_grep "$SANDBOX/registration.out" 'paseo schedule create' "printed failsafe fallback"
id=$(printf '%s\n' "$registration" | sed -n 's/^watch \([^ ]*\) registered.*/\1/p')
dir="$PM_HOME/watches/$id"
assert_grep "$dir/spec" 'labels=role=monitor|job=42124320|item=a1913cc1|lane=F2|extra=value' "harvested and explicit labels"
: > "$MOCK_DIR/done"
printf '0\n' > "$dir/nextDue"
$PMT_BIN _sweep || fail "HARVEST report sweep failed"
assert_grep "$MOCK_DIR/report" 'PROHIBITIONS=never scancel job 42124320' "front-loaded prohibition"
assert_grep "$MOCK_DIR/report" 'labels=role=monitor|job=42124320|item=a1913cc1|lane=F2|extra=value' "report labels"
bytes=$(wc -c < "$MOCK_DIR/report" | tr -d ' ')
[ "$bytes" -le 2048 ] || fail "envelope too large: $bytes"
echo PASS: harvested Paseo labels, generic labels, and opaque prohibitions
