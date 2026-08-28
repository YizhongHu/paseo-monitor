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
case "${1:-}" in
    inspect)
        printf '{"Provider":"codex"}\n'
        ;;
    provider)
        printf '[{"provider":"claude","status":"available","enabled":"Enabled"}]\n'
        ;;
    schedule)
        [ "${2:-}" = create ] || exit 2
        provider=''
        previous=''
        for argument in "$@"; do
            if [ "$previous" = --provider ]; then provider="$argument"; fi
            previous="$argument"
        done
        [ -n "$provider" ] || exit 2
        printf '%s\n' "$provider" > "$MOCK_DIR/last-provider"
        printf '{"id":"provider-test-schedule"}\n'
        ;;
    *)
        exit 2
        ;;
esac
EOF
chmod +x "$SANDBOX/bin/paseo"

explicit_registration="$($PMT_BIN watch --script "$SANDBOX/probe" --reason 'explicit provider' --terminal DONE --no-start-report --failsafe --provider codex/gpt-5.6-luna --max-runs 1 --expires-in 5m --deadline +300)" || fail "explicit provider registration failed"
explicit_id=$(printf '%s\n' "$explicit_registration" | sed -n 's/^watch \([^ ]*\) registered.*/\1/p')
assert_eq "$(cat "$PM_HOME/watches/$explicit_id/spec" | sed -n 's/^provider=//p')" codex/gpt-5.6-luna "explicit provider persisted"
assert_grep "$MOCK_DIR/calls.log" 'schedule create .*--provider codex/gpt-5.6-luna --json' "explicit provider forwarded"

export PASEO_AGENT_ID=caller-1
caller_registration="$($PMT_BIN watch --script "$SANDBOX/probe" --reason 'caller provider' --terminal DONE --no-start-report --failsafe --max-runs 1 --expires-in 5m --deadline +300)" || fail "caller provider registration failed"
caller_id=$(printf '%s\n' "$caller_registration" | sed -n 's/^watch \([^ ]*\) registered.*/\1/p')
assert_eq "$(cat "$PM_HOME/watches/$caller_id/spec" | sed -n 's/^provider=//p')" codex "caller provider default"
assert_grep "$MOCK_DIR/calls.log" 'schedule create .*--provider codex --json' "caller provider forwarded"

unset PASEO_AGENT_ID
fallback_registration="$($PMT_BIN watch --script "$SANDBOX/probe" --reason 'listed provider' --terminal DONE --no-start-report --failsafe --max-runs 1 --expires-in 5m --deadline +300)" || fail "provider list registration failed"
fallback_id=$(printf '%s\n' "$fallback_registration" | sed -n 's/^watch \([^ ]*\) registered.*/\1/p')
assert_eq "$(cat "$PM_HOME/watches/$fallback_id/spec" | sed -n 's/^provider=//p')" claude "provider list default"
assert_grep "$MOCK_DIR/calls.log" 'schedule create .*--provider claude --json' "provider list forwarded"
echo PASS: explicit, caller, and provider-list defaults are forwarded
