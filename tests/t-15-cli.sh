#!/bin/sh
. "$(dirname "$0")/common.sh"
setup
trap teardown EXIT
PASEO_MONITOR_LOG_MAX_BYTES=100000
export PASEO_MONITOR_LOG_MAX_BYTES
export PASEO_AGENT_ID=cli-test

kinds="$($PMT_BIN kinds)"
assert_grep "$PMT_REPO_ROOT/bin/paseo-monitor" 'file-exists | Absence / receipt pattern' "kinds file-exists absence row"
assert_eq "$(printf '%s\n' "$kinds" | grep -c '^')" 8 "kind count"
help="$($PMT_BIN --help)"
printf '%s\n' "$kinds" > "$SANDBOX/kinds"
assert_grep "$SANDBOX/kinds" 'Absence / receipt pattern' "kinds absence framing"
assert_grep "$SANDBOX/kinds" 'example: paseo-monitor watch --kind file-exists --path /scratch/run/receipt --deadline +3600' "kinds receipt invocation"
printf '%s\n' "$help" > "$SANDBOX/help"
assert_grep "$SANDBOX/help" '--deadline <when>' "help marks deadline required"
assert_grep "$SANDBOX/help" 'status \[--mine|<id>\]' "help documents ownership filter"
assert_grep "$SANDBOX/help" '--failsafe example: watch \.\.\. --failsafe --expires-in 5m --max-runs 1' "help explains bounded failsafe"
assert_grep "$SANDBOX/help" 'example: paseo-monitor watch --kind file-exists --path /scratch/run/receipt --deadline +3600' "help receipt invocation"
script_help="$(printf '%s\n' "$help" | sed -n '/^  watch --script/,/^      Register/p')"
assert_grep "$SANDBOX/help" '--terminal TOK,TOK \[same common options as --kind\]' "script terminal synopsis"
case "$script_help" in
    *'[--terminal TOK,TOK]'*) fail "script synopsis still brackets terminal" ;;
esac
assert_grep "$SANDBOX/help" 'rm reports owed active cancellations' "help cancellation behavior"
assert_grep "$SANDBOX/help" '--max-fires reports one exhausted event' "help exhaustion behavior"
while IFS= read -r kind_line; do
    case "$help" in
        *"$kind_line"*) ;;
        *) fail "help kind table: pattern [$kind_line] not found" ;;
    esac
done <<EOF
$(printf '%s\n' "$kinds")
EOF

cat > "$SANDBOX/probe" <<'EOF'
#!/bin/sh
printf 'DONE artifact-ready\n'
EOF
chmod +x "$SANDBOX/probe"
if $PMT_BIN watch --script "$SANDBOX/probe" --reason 'missing deadline' --terminal DONE 2>"$SANDBOX/missing-deadline.err"; then
    fail "missing deadline accepted"
fi
assert_grep "$SANDBOX/missing-deadline.err" '--deadline is required' "missing deadline required error"
if $PMT_BIN watch --script "$SANDBOX/probe" --reason 'bad deadline' --terminal DONE --deadline malformed 2>"$SANDBOX/bad-deadline.err"; then
    fail "malformed deadline accepted"
fi
assert_grep "$SANDBOX/bad-deadline.err" 'deadline must be epoch seconds' "malformed deadline error"
if grep -q -- '--deadline is required' "$SANDBOX/bad-deadline.err"; then
    fail "malformed deadline used missing-value error"
fi
watch_out="$($PMT_BIN watch --script "$SANDBOX/probe" --reason 'artifact completion has no bundled kind' --terminal DONE --deadline +300)" || fail "script registration failed"
watch_id=$(printf '%s\n' "$watch_out" | sed -n 's/^watch \([^ ]*\) registered.*/\1/p')
[ -n "$watch_id" ] || fail "watch id missing"
watch_dir="$PM_HOME/watches/$watch_id"
printf '%s\n' "$watch_out" > "$SANDBOX/registration.out"
assert_grep "$SANDBOX/registration.out" 'delivery=none-configured' "registration local-only delivery"
assert_grep "$SANDBOX/registration.out" 'reports recorded locally only' "registration local-only wording"
ls_out="$($PMT_BIN ls)"
printf '%s\n' "$ls_out" > "$SANDBOX/ls"
assert_grep "$SANDBOX/ls" "kind=script" "ls kind"
assert_grep "$SANDBOX/ls" "target=$SANDBOX/probe" "ls target names the script, not the reason"
assert_grep "$SANDBOX/ls" 'reason=artifact completion has no bundled kind' "ls reason"
status_out="$($PMT_BIN status "$watch_id" 2>"$SANDBOX/status.err")"
printf '%s\n' "$status_out" > "$SANDBOX/status.out"
assert_grep "$SANDBOX/status.out" 'last-sweep-age: unknown' "status freshness header"
assert_grep "$SANDBOX/status.out" 'last_token=DONE' "status last token"
assert_grep "$SANDBOX/status.out" 'last_transition=(none)' "status transition"
assert_grep "$SANDBOX/status.out" 'delivery=none-configured' "status local-only delivery"
if grep -q 'delivery_attempted=\|undelivered=\|delivery_error=' "$SANDBOX/status.out"; then
    fail "local-only status emitted configured-delivery fields"
fi
log_out="$($PMT_BIN log "$watch_id" -n 3)"
printf '%s\n' "$log_out" > "$SANDBOX/log"
assert_grep "$SANDBOX/log" 'REGISTER' "log output"

printf '%s\n' parked > "$watch_dir/state"
$PMT_BIN status "$watch_id" > "$SANDBOX/parked-status.out" 2> "$SANDBOX/parked-status.err"
assert_grep "$SANDBOX/parked-status.err" 'state=parked; will not probe until poked' "parked status diagnosis"
poke_out="$($PMT_BIN poke "$watch_id")" || fail "poke failed"
assert_eq "$(cat "$watch_dir/state")" active "poke resumes parked watch"
assert_grep "$watch_dir/log" 'POKE resumed parked watch' "poke park resume"
printf '%s\n' delivery-failed > "$watch_dir/state"
printf '%s\n' 'delivery backend exploded rc=9' > "$watch_dir/.delivery.stderr"
printf '%s\n' 'pending report' > "$watch_dir/undelivered"
sed 's|^deliver=.*|deliver=/bin/false|' "$watch_dir/spec" > "$SANDBOX/configured-spec"
mv "$SANDBOX/configured-spec" "$watch_dir/spec"
$PMT_BIN status "$watch_id" > "$SANDBOX/delivery-status.out" 2> "$SANDBOX/delivery-status.err"
assert_grep "$SANDBOX/delivery-status.out" 'undelivered=yes.*delivery_error=delivery backend exploded rc=9' "status delivery error"
assert_grep "$SANDBOX/delivery-status.out" 'sweeper_log=.*sweep.log' "status sweeper log pointer"
printf '%s\n' '1 network' > "$watch_dir/health"
$PMT_BIN status "$watch_id" > "$SANDBOX/warn.out" 2> "$SANDBOX/warn.err"
assert_grep "$SANDBOX/warn.err" 'WARN watch=' "status warning stream"
assert_grep "$SANDBOX/warn.err" 'health=1 network' "health warning"

old_id="$($PMT_BIN watch --script "$SANDBOX/probe" --reason old --terminal DONE --deadline +300 | sed -n 's/^watch \([^ ]*\) registered.*/\1/p')" || fail "old watch registration failed"
old_dir="$PM_HOME/watches/$old_id"
printf '%s\n' terminal > "$old_dir/state"
old_deadline=$(( $(date +%s) - 2592001 ))
printf '%s\n' "$(sed "s/^deadline=.*/deadline=$old_deadline/" "$old_dir/spec")" > "$old_dir/spec"
recent_id="$($PMT_BIN watch --script "$SANDBOX/probe" --reason recent --terminal DONE --deadline +300 | sed -n 's/^watch \([^ ]*\) registered.*/\1/p')" || fail "recent watch registration failed"
recent_dir="$PM_HOME/watches/$recent_id"
printf '%s\n' terminal > "$recent_dir/state"
recent_deadline=$(( $(date +%s) - 2591900 ))
printf '%s\n' "$(sed "s/^deadline=.*/deadline=$recent_deadline/" "$recent_dir/spec")" > "$recent_dir/spec"
reap_out="$($PMT_BIN reap)"
printf '%s\n' "$reap_out" > "$SANDBOX/reap"
[ ! -d "$old_dir" ] || fail "long-expired watch retained"
[ -f "$recent_dir/spec" ] || fail "recent terminal watch reaped"
$PMT_BIN rm "$recent_id" || fail "rm one failed"
[ -f "$PM_HOME/graveyard/$recent_id/spec" ] || fail "rm one did not retain watch"
$PMT_BIN rm --all || fail "rm all failed"
[ -f "$PM_HOME/graveyard/$watch_id/spec" ] || fail "rm all did not retain watch"
echo PASS: CLI kinds, ls, status, log, poke, rm, and reap
