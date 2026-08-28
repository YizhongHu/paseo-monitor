#!/bin/sh
. "$(dirname "$0")/common.sh"
setup
trap teardown EXIT
source_monitor
unset PM_SOURCE_ONLY

cat > "$SANDBOX/probe" <<'EOF'
#!/bin/sh
printf 'RUNNING observed\n'
EOF
chmod +x "$SANDBOX/probe"
cat > "$SANDBOX/bin/paseo" <<'EOF'
#!/bin/sh
printf 'paseo %s\n' "$*" >> "$MOCK_DIR/calls.log"
if [ "${1:-}" = schedule ] && [ "${2:-}" = create ]; then
    printf '{"code":"MISSING_PROVIDER","message":"Provider is required"}\n' >&2
    exit 1
fi
exit 2
EOF
chmod +x "$SANDBOX/bin/paseo"

registration="$($PMT_BIN watch --script "$SANDBOX/probe" --reason 'failsafe failure' --terminal DONE --no-start-report --failsafe --provider claude --deadline +300 2>"$SANDBOX/register.err")"
registration_rc=$?
assert_eq "$registration_rc" 0 "failsafe failure registration exit status"
id=$(printf '%s\n' "$registration" | sed -n 's/^watch \([^ ]*\) registered.*/\1/p')
[ -n "$id" ] || fail "watch id missing after failsafe failure"
dir="$PM_HOME/watches/$id"
[ -d "$dir" ] || fail "watch directory removed after failsafe failure"
assert_eq "$(cat "$dir/state")" active "watch remains active after failsafe failure"
assert_grep "$SANDBOX/register.err" 'paseo-monitor: WARN failsafe schedule not created (MISSING_PROVIDER); caller owns the liveness backstop' "failsafe warning"

ordered_registration="$($PMT_BIN watch --script "$SANDBOX/probe" --reason 'failsafe ordering' --terminal DONE --no-start-report --failsafe --provider claude --deadline +300 2>&1)"
ordered_registered_line="$(printf '%s\n' "$ordered_registration" | grep -n '^watch .* registered:' | cut -d: -f1)"
ordered_warn_line="$(printf '%s\n' "$ordered_registration" | grep -n 'WARN failsafe schedule not created' | cut -d: -f1)"
[ "$ordered_registered_line" -lt "$ordered_warn_line" ] || fail "registration line followed failsafe warning"
ls_output="$($PMT_BIN ls)" || fail "ls failed after failsafe failure"
printf '%s\n' "$ls_output" | grep -q "$id kind=script .* state=active" || fail "ls did not show surviving active watch"
echo PASS: failsafe failure preserves active watch and warns
