#!/bin/sh
. "$(dirname "$0")/common.sh"
setup
trap teardown EXIT
PASEO_MONITOR_LOG_MAX_BYTES=100000
export PASEO_MONITOR_LOG_MAX_BYTES
tab="$(printf '\t')"

cat > "$SANDBOX/probe" <<'EOF'
#!/bin/sh
printf 'DONE observed\n'
EOF
chmod +x "$SANDBOX/probe"
cat > "$SANDBOX/deliver" <<'EOF'
#!/bin/sh
cat >> "$MOCK_DIR/report"
EOF
chmod +x "$SANDBOX/deliver"

mock_ssh_script "0${tab}COMPLETED"
script_reg="$($PMT_BIN watch --script "$SANDBOX/probe" --reason 'terminal registration test' --terminal DONE --report-transitions --max-fires 1 --failsafe --provider claude --max-runs 1 --expires-in 5m --deliver "$SANDBOX/deliver" --deadline +1)" || fail "terminal script registration failed"
script_id=$(printf '%s\n' "$script_reg" | sed -n 's/^watch \([^ ]*\) registered.*/\1/p')
script_dir="$PM_HOME/watches/$script_id"
assert_eq "$(cat "$script_dir/last")" DONE "script terminal token recorded"
assert_eq "$(cat "$script_dir/state")" terminal "script terminal state at registration"
assert_eq "$(cat "$script_dir/fires")" 2 "script terminal and exhaustion reports delivered at registration"
assert_eq "$(grep -c ' REPORT ' "$script_dir/log")" 2 "script terminal report count"
assert_grep "$script_dir/log" 'class=exhausted.*new=MAX-FIRES-REACHED' "script exhaustion envelope"
assert_grep "$MOCK_DIR/report" 'class=terminal.*new=DONE' "script terminal envelope"
assert_grep "$MOCK_DIR/calls.log" 'paseo schedule delete ' "immediate failsafe cleanup"
[ ! -f "$script_dir/failsafe" ] || fail "immediate terminal retains failsafe marker"

printf '0\n' > "$script_dir/nextDue"
printf '%s\n' "$(sed 's/^deadline=.*/deadline=0/' "$script_dir/spec")" > "$script_dir/spec"
$PMT_BIN _sweep || fail "terminal script follow-up sweep failed"
assert_eq "$(grep -c ' REPORT ' "$script_dir/log")" 2 "script terminal does not re-report"
if grep -q 'class=deadline' "$script_dir/log"; then fail "terminal script emitted deadline event"; fi

mock_ssh_script "0${tab}COMPLETED"
slurm_reg="$($PMT_BIN watch --kind slurm --host cannon --job finished-1 --report-transitions --max-fires 1 --deliver "$SANDBOX/deliver" --deadline +1)" || fail "terminal Slurm registration failed"
slurm_id=$(printf '%s\n' "$slurm_reg" | sed -n 's/^watch \([^ ]*\) registered.*/\1/p')
slurm_dir="$PM_HOME/watches/$slurm_id"
assert_eq "$(cat "$slurm_dir/last")" COMPLETED "Slurm terminal token recorded"
assert_eq "$(cat "$slurm_dir/state")" terminal "Slurm terminal state at registration"
assert_eq "$(cat "$slurm_dir/fires")" 2 "Slurm terminal and exhaustion reports delivered at registration"
assert_eq "$(grep -c ' REPORT ' "$slurm_dir/log")" 2 "Slurm terminal report count"
assert_grep "$slurm_dir/log" 'class=exhausted.*new=MAX-FIRES-REACHED' "Slurm exhaustion envelope"
printf '0\n' > "$slurm_dir/nextDue"
$PMT_BIN _sweep || fail "terminal Slurm follow-up sweep failed"
assert_eq "$(grep -c ' REPORT ' "$slurm_dir/log")" 2 "Slurm terminal does not re-report"
if grep -q 'class=deadline' "$slurm_dir/log"; then fail "terminal Slurm emitted deadline event"; fi

echo PASS: terminal-at-registration reports once for script and Slurm
