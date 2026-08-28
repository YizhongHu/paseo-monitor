#!/bin/sh
. "$(dirname "$0")/common.sh"
setup
trap teardown EXIT

set +e
"$SANDBOX/bin/paseo" schedule create 'missing provider' --every 5m --max-runs 1 --expires-in 5m --json 2>"$SANDBOX/missing-provider.err"
missing_rc=$?
set -e
assert_eq "$missing_rc" 1 "provider-less schedule create exit status"
assert_grep "$SANDBOX/missing-provider.err" 'MISSING_PROVIDER' "provider-less schedule error"

with_provider="$($SANDBOX/bin/paseo schedule create 'with provider' --every 5m --max-runs 1 --expires-in 5m --provider claude --json)" || fail "provider schedule create failed"
assert_grep "$SANDBOX/mock/calls.log" 'schedule create .*--provider claude --json' "provider recorded by mock"
assert_grep "$SANDBOX/mock/calls.log" 'schedule create .*--provider claude --json' "provider accepted by mock"
[ -n "$with_provider" ] || fail "provider schedule response missing"
provider_list="$($SANDBOX/bin/paseo provider ls --json)" || fail "provider list failed"
assert_grep "$SANDBOX/mock/calls.log" 'provider ls --json' "provider list recorded by mock"
printf '%s\n' "$provider_list" | grep -q '"provider":"claude"' || fail "provider list response missing claude"
echo PASS: paseo mock enforces schedule provider contract
