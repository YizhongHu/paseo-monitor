#!/bin/sh
. "$(dirname "$0")/common.sh"
setup
trap teardown EXIT
cat > "$SANDBOX/probe" <<'EOF'
#!/bin/sh
printf 'OLD snapshotted-detail\n'
EOF
chmod +x "$SANDBOX/probe"
register_output="$($PMT_BIN watch --script "$SANDBOX/probe" --reason 'test snapshot' --terminal DONE --no-start-report --deadline +300)" || fail "script registration failed"
watch_id=$(printf '%s\n' "$register_output" | sed -n 's/^watch \([^ ]*\) registered.*/\1/p')
[ -n "$watch_id" ] || fail "watch id missing"
watch_dir="$PM_HOME/watches/$watch_id"
assert_eq "$(cat "$watch_dir/last")" OLD "registration observation"
assert_grep "$watch_dir/spec" 'reason=test snapshot' "script reason in spec"
ls_output="$($PMT_BIN ls)" || fail "ls failed"
printf '%s\n' "$ls_output" > "$SANDBOX/ls-output"
assert_grep "$SANDBOX/ls-output" 'reason=test snapshot' "reason in ls"

cat > "$SANDBOX/probe" <<'EOF'
#!/bin/sh
printf 'NEW edited-and-deleted\n'
EOF
chmod +x "$SANDBOX/probe"
rm "$SANDBOX/probe"
$PMT_BIN _sweep || fail "sweep after source deletion failed"
assert_eq "$(cat "$watch_dir/last")" OLD "snapshotted probe survived source deletion"

cat > "$SANDBOX/broken" <<'EOF'
#!/bin/sh
printf 'BROKEN output\n'
exit 9
EOF
chmod +x "$SANDBOX/broken"
if $PMT_BIN watch --script "$SANDBOX/broken" --reason 'broken test' --terminal DONE --deadline +300; then
    fail "broken registration succeeded"
fi

tab="$(printf '\t')"
mock_ssh_script "255${tab}${tab}Control socket connect(/x): Operation not permitted\\nssh: Could not resolve hostname h: -65563"
sandbox_stderr="$SANDBOX/sandbox.err"
sandbox_output="$($PMT_BIN watch --kind slurm --host cannon --job sandbox --deadline +300 --no-start-report 2>"$sandbox_stderr")" || fail "sandbox registration failed"
sandbox_id=$(printf '%s\n' "$sandbox_output" | sed -n 's/^watch \([^ ]*\) registered.*/\1/p')
[ -n "$sandbox_id" ] || fail "sandbox watch id missing"
sandbox_dir="$PM_HOME/watches/$sandbox_id"
[ -d "$sandbox_dir" ] || fail "sandbox watch was not created"
assert_eq "$(cat "$sandbox_dir/state")" active "sandbox watch state"
assert_grep "$sandbox_stderr" 'WARN registration probe unavailable in caller sandbox' "sandbox registration warning"
for sandbox_sweep in 1 2 3; do
    printf '0\n' > "$sandbox_dir/nextDue"
    mock_ssh_script "255${tab}${tab}Control socket connect(/x): Operation not permitted\\nssh: Could not resolve hostname h: -65563"
    $PMT_BIN _sweep || fail "sandbox failure sweep $sandbox_sweep failed"
done
assert_eq "$(cat "$sandbox_dir/state")" active "sandbox watch not parked"
assert_eq "$(cat "$sandbox_dir/health")" "3 sandbox" "sandbox health class"

mock_ssh_script "0${tab}RUNNING"
$PMT_BIN _sweep || fail "sandbox watch sweep failed"
assert_eq "$(cat "$sandbox_dir/last")" RUNNING "sweeper first observation"

watch_count=$(for d in "$PM_HOME"/watches/*; do [ -d "$d" ] && printf x; done | wc -c | tr -d ' ')
if $PMT_BIN watch --script "$SANDBOX/broken" --reason 'floor test' --terminal DONE --interval 59 --deadline +300; then
    fail "script cadence floor accepted"
fi
if $PMT_BIN watch --kind slurm --host cannon --job 42 --interval 119 --deadline +300; then
    fail "slurm cadence floor accepted"
fi
echo PASS: registration snapshot, broken probe, reason, and cadence floors
