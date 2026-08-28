#!/bin/sh
. "$(dirname "$0")/common.sh"
setup
trap teardown EXIT
PASEO_MONITOR_PROBE_TIMEOUT=1
export PASEO_MONITOR_PROBE_TIMEOUT
source_monitor

cat > "$SANDBOX/healthy-failed" <<'EOF'
#!/bin/sh
printf 'FAILED job-record\n'
exit 0
EOF
chmod +x "$SANDBOX/healthy-failed"
: > "$SANDBOX/out"
: > "$SANDBOX/err"
pm_run_with_timeout 10 "$SANDBOX/out" "$SANDBOX/err" "$SANDBOX/healthy-failed"
rc=$?
assert_rc "$rc" 0 "target FAILED is healthy observation"
pm_parse_probe_output "$SANDBOX/out" || fail "valid probe output rejected"
assert_eq "$PM_PARSED_TOKEN" FAILED "target token"
cat > "$SANDBOX/fragmented" <<'EOF'
#!/bin/sh
printf 'PENDING first\n'
sleep 1
printf 'DONE second\n'
EOF
chmod +x "$SANDBOX/fragmented"
pm_run_with_timeout 10 "$SANDBOX/out" "$SANDBOX/err" "$SANDBOX/fragmented"
rc=$?
assert_rc "$rc" 0 "fragmented stdout observation"
assert_eq "$(cat "$SANDBOX/out")" "PENDING first
DONE second" "fragmented stdout preserved"


cat > "$SANDBOX/broken" <<'EOF'
#!/bin/sh
printf 'FAILED stale-output\n'
exit 7
EOF
chmod +x "$SANDBOX/broken"
pm_run_with_timeout 10 "$SANDBOX/out" "$SANDBOX/err" "$SANDBOX/broken"
rc=$?
assert_rc "$rc" 7 "probe health rc"

cat > "$SANDBOX/slow" <<'EOF'
#!/bin/sh
sleep 3
printf 'DONE late\n'
EOF
chmod +x "$SANDBOX/slow"
pm_run_with_timeout 1 "$SANDBOX/out" "$SANDBOX/err" "$SANDBOX/slow"
rc=$?
assert_rc "$rc" 124 "hard timeout marker"

cat > "$SANDBOX/large" <<'EOF'
#!/bin/sh
dd if=/dev/zero bs=10000 count=1 2>/dev/null
EOF
chmod +x "$SANDBOX/large"
pm_run_with_timeout 10 "$SANDBOX/out" "$SANDBOX/err" "$SANDBOX/large"
rc=$?
assert_rc "$rc" 0 "large stdout observation"
size=$(wc -c < "$SANDBOX/out")
[ "$size" -le 4096 ] || fail "stdout cap exceeded: $size"
echo PASS: probe health, timeout, and stdout cap
