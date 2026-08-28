#!/bin/sh
. "$(dirname "$0")/common.sh"
setup
trap teardown EXIT
PASEO_MONITOR_LOG_MAX_BYTES=100000
export PASEO_MONITOR_LOG_MAX_BYTES

write_probe() {
    wt_path="$1"
    wt_mode="$2"
    cat > "$wt_path" <<EOF
#!/bin/sh
printf '%s detail-%s\\n' "\$(cat '$wt_mode')" "\$(cat '$wt_mode')"
EOF
    chmod +x "$wt_path"
}

# A held live global lock makes _sweep skip quietly.
printf 'LOCKED\n' > "$SANDBOX/lock-mode"
cat > "$SANDBOX/lock-probe" <<EOF
#!/bin/sh
printf '%s detail-%s\n' "\$(cat '$SANDBOX/lock-mode')" "\$(cat '$SANDBOX/lock-mode')"
sleep 2
EOF
chmod +x "$SANDBOX/lock-probe"
lock_registration="$($PMT_BIN watch --script "$SANDBOX/lock-probe" --reason 'lock test' --terminal DONE --no-start-report --deadline +300)" || fail "lock watch registration failed"
lock_id=$(printf '%s\n' "$lock_registration" | sed -n 's/^watch \([^ ]*\) registered.*/\1/p')
lock_dir="$PM_HOME/watches/$lock_id"
$PMT_BIN _sweep > "$SANDBOX/lock-holder.out" 2> "$SANDBOX/lock-holder.err" &
holder=$!
lock_ready=0
lock_attempt=0
while [ "$lock_attempt" -lt 20 ]; do
    if [ -d "$PM_HOME/sweep.lock" ]; then
        lock_ready=1
        break
    fi
    sleep 0.1
    lock_attempt=$((lock_attempt + 1))
done
[ "$lock_ready" -eq 1 ] || fail "lock-holder sweep did not acquire lock"
sweep_output="$($PMT_BIN _sweep)" || fail "lock skip returned nonzero"
[ -z "$sweep_output" ] || fail "lock skip was noisy: $sweep_output"
assert_eq "$(cat "$lock_dir/last")" LOCKED "held lock skipped watch"
wait "$holder" 2>/dev/null || fail "lock-holder sweep failed"

# Intermediate changes always enter the evidence log, but report only when opted in.
printf 'RUNNING\n' > "$SANDBOX/default-mode"
write_probe "$SANDBOX/default-probe" "$SANDBOX/default-mode"
default_registration="$($PMT_BIN watch --script "$SANDBOX/default-probe" --reason 'terminal only' --terminal DONE --no-start-report --deadline +300)" || fail "default watch registration failed"
default_id=$(printf '%s\n' "$default_registration" | sed -n 's/^watch \([^ ]*\) registered.*/\1/p')
default_dir="$PM_HOME/watches/$default_id"
printf 'PENDING\n' > "$SANDBOX/default-mode"
$PMT_BIN _sweep || fail "default intermediate sweep failed"
assert_grep "$default_dir/log" 'TOKEN-CHANGE RUNNING -> PENDING' "intermediate evidence"
if grep -q ' REPORT ' "$default_dir/log"; then fail "terminal-only watch reported intermediate"; fi

printf 'RUNNING\n' > "$SANDBOX/transition-mode"
write_probe "$SANDBOX/transition-probe" "$SANDBOX/transition-mode"
transition_registration="$($PMT_BIN watch --script "$SANDBOX/transition-probe" --reason 'transition opt in' --terminal DONE --report-transitions --no-start-report --deadline +300)" || fail "transition watch registration failed"
transition_id=$(printf '%s\n' "$transition_registration" | sed -n 's/^watch \([^ ]*\) registered.*/\1/p')
transition_dir="$PM_HOME/watches/$transition_id"
printf 'PENDING\n' > "$SANDBOX/transition-mode"
$PMT_BIN _sweep || fail "transition sweep failed"
assert_grep "$transition_dir/log" 'TOKEN-CHANGE RUNNING -> PENDING' "transition evidence"
assert_grep "$transition_dir/log" 'REPORT .*class=transition' "transition report"

# Terminal transitions report once and park the watch in terminal state.
printf 'RUNNING\n' > "$SANDBOX/terminal-mode"
write_probe "$SANDBOX/terminal-probe" "$SANDBOX/terminal-mode"
terminal_registration="$($PMT_BIN watch --script "$SANDBOX/terminal-probe" --reason 'terminal event' --terminal DONE --no-start-report --deadline +300)" || fail "terminal watch registration failed"
terminal_id=$(printf '%s\n' "$terminal_registration" | sed -n 's/^watch \([^ ]*\) registered.*/\1/p')
terminal_dir="$PM_HOME/watches/$terminal_id"
printf 'DONE\n' > "$SANDBOX/terminal-mode"
$PMT_BIN _sweep || fail "terminal sweep failed"
$PMT_BIN _sweep || fail "terminal repeat sweep failed"
assert_grep "$terminal_dir/log" 'REPORT .*class=terminal' "terminal report"
assert_eq "$(cat "$terminal_dir/state")" terminal "terminal state"
terminal_reports=$(grep -c ' REPORT ' "$terminal_dir/log")
assert_eq "$terminal_reports" 1 "terminal fires once"

# max-fires limits deliveries, not observed token changes.
printf 'A\n' > "$SANDBOX/max-mode"
write_probe "$SANDBOX/max-probe" "$SANDBOX/max-mode"
max_registration="$($PMT_BIN watch --script "$SANDBOX/max-probe" --reason 'max fires' --terminal DONE --report-transitions --max-fires 1 --no-start-report --deadline +300)" || fail "max watch registration failed"
max_id=$(printf '%s\n' "$max_registration" | sed -n 's/^watch \([^ ]*\) registered.*/\1/p')
max_dir="$PM_HOME/watches/$max_id"
printf 'B\n' > "$SANDBOX/max-mode"
$PMT_BIN _sweep || fail "max first sweep failed"
printf 'C\n' > "$SANDBOX/max-mode"
$PMT_BIN _sweep || fail "max second sweep failed"
printf 'DONE\n' > "$SANDBOX/max-mode"
$PMT_BIN _sweep || fail "max terminal sweep failed"
max_changes=$(grep -c 'TOKEN-CHANGE' "$max_dir/log")
max_reports=$(grep -c ' REPORT ' "$max_dir/log")
assert_eq "$max_changes" 3 "max records all observations"
assert_eq "$max_reports" 2 "max includes exhaustion announcement"
max_exhausted=$(awk '/class=exhausted/ {count++} END {print count + 0}' "$max_dir/log")
assert_eq "$max_exhausted" 1 "max exhaustion report count"
assert_grep "$max_dir/spec" '^exhausted=1$' "max exhaustion marker"
assert_grep "$max_dir/log" 'REPORT .*class=exhausted' "max exhaustion report"
assert_grep "$max_dir/log" 'class=exhausted.*old=B.*new=MAX-FIRES-REACHED' "max exhaustion old token"
assert_grep "$max_dir/log" 'new=MAX-FIRES-REACHED' "max exhaustion token"
echo PASS: sweep lock, edge trigger, event classes, and max-fires
