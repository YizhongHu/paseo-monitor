#!/bin/sh
. "$(dirname "$0")/common.sh"
setup
trap teardown EXIT
PASEO_MONITOR_LOG_MAX_BYTES=100000
export PASEO_MONITOR_LOG_MAX_BYTES
source_monitor
unset PM_SOURCE_ONLY

cat > "$SANDBOX/probe" <<'EOF'
#!/bin/sh
printf 'RUNNING ownership-test\n'
EOF
chmod +x "$SANDBOX/probe"

export PASEO_AGENT_ID=owner-a
first_reg="$($PMT_BIN watch --script "$SANDBOX/probe" --reason owner-a --terminal DONE --no-start-report --report-to route-a --context 'item=A context' --deadline +300)" || fail "owner-a registration failed"
first_id=$(printf '%s\n' "$first_reg" | sed -n 's/^watch \([^ ]*\) registered.*/\1/p')
export PASEO_AGENT_ID=owner-b
second_reg="$($PMT_BIN watch --script "$SANDBOX/probe" --reason owner-b --terminal DONE --no-start-report --report-to route-b --context 'item=B context' --deadline +300)" || fail "owner-b registration failed"
second_id=$(printf '%s\n' "$second_reg" | sed -n 's/^watch \([^ ]*\) registered.*/\1/p')
[ -n "$first_id" ] && [ -n "$second_id" ] || fail "watch ids missing"

ls_out="$($PMT_BIN ls)" || fail "ls failed"
printf '%s\n' "$ls_out" > "$SANDBOX/ls"
assert_grep "$SANDBOX/ls" 'owner=owner-a.*report_to=route-a.*ours=no' "owner-a attribution"
assert_grep "$SANDBOX/ls" 'owner=owner-b.*report_to=route-b.*ours=yes' "owner-b attribution"

all_out="$($PMT_BIN rm --all)" || fail "owner-b rm --all failed"
printf '%s\n' "$all_out" > "$SANDBOX/rm-owner"
assert_grep "$SANDBOX/rm-owner" "removed watch=$second_id owner=owner-b report_to=route-b" "rm reports deletion"
[ -f "$PM_HOME/graveyard/$second_id/spec" ] || fail "owner-b spec missing from graveyard"
[ -f "$PM_HOME/graveyard/$second_id/context" ] || fail "owner-b context missing from graveyard"
[ -f "$PM_HOME/graveyard/$second_id/log" ] || fail "owner-b log missing from graveyard"
[ -f "$PM_HOME/watches/$first_id/spec" ] || fail "owner-a watch removed by scoped rm"
[ -f "$PM_HOME/graveyard/$first_id/spec" ] && fail "owner-a watch unexpectedly archived"
export PASEO_AGENT_ID=owner-c
third_reg="$($PMT_BIN watch --script "$SANDBOX/probe" --reason owner-c --terminal DONE --no-start-report --report-to route-c --context 'item=C context' --deadline +300)" || fail "owner-c registration failed"
third_id=$(printf '%s\n' "$third_reg" | sed -n 's/^watch \([^ ]*\) registered.*/\1/p')
[ -n "$third_id" ] || fail "owner-c watch id missing"
export PASEO_AGENT_ID=owner-b

status_out="$($PMT_BIN status "$second_id")" || fail "graveyard status failed"
printf '%s\n' "$status_out" > "$SANDBOX/status"
assert_grep "$SANDBOX/status" 'state=removed owner=owner-b report_to=route-b ours=yes' "graveyard status attribution"
assert_grep "$SANDBOX/status" "log=$PM_HOME/watches/$second_id/log" "citation pointer remains stable"
log_out="$($PMT_BIN log "$second_id" -n 5)" || fail "graveyard log failed"
printf '%s\n' "$log_out" > "$SANDBOX/log"
assert_grep "$SANDBOX/log" "REGISTER" "graveyard log evidence"

all_agents_out="$($PMT_BIN rm --all-agents)" || fail "global rm failed"
printf '%s\n' "$all_agents_out" > "$SANDBOX/rm-global"
assert_grep "$SANDBOX/rm-global" "will-remove watch=$third_id owner=owner-c report_to=route-c" "global second owner listing"
assert_grep "$SANDBOX/rm-global" "removed watch=$third_id owner=owner-c report_to=route-c" "global second owner deletion"
assert_grep "$SANDBOX/rm-global" "will-remove watch=$first_id owner=owner-a report_to=route-a" "global attribution listing"
assert_grep "$SANDBOX/rm-global" "removed watch=$first_id owner=owner-a report_to=route-a" "global deletion receipt"
[ -f "$PM_HOME/graveyard/$first_id/spec" ] || fail "global rm did not archive owner-a watch"

old_deadline=$(( $(pm_now) - 2592001 ))
pm_atomic_write "$PM_HOME/graveyard/$first_id/spec" "$(sed "s/^deadline=.*/deadline=$old_deadline/" "$PM_HOME/graveyard/$first_id/spec")"
$PMT_BIN reap > "$SANDBOX/reap" || fail "graveyard reap failed"
[ ! -d "$PM_HOME/graveyard/$first_id" ] || fail "expired graveyard entry survived reap"
echo PASS: ownership-scoped rm, attribution, graveyard fallback, global listing, and graveyard reap
