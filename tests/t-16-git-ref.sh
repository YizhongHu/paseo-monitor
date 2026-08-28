#!/bin/sh
. "$(dirname "$0")/common.sh"
setup
trap teardown EXIT
PASEO_MONITOR_LOG_MAX_BYTES=100000
export PASEO_MONITOR_LOG_MAX_BYTES
source_monitor
unset PM_SOURCE_ONLY

sha_a=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
sha_b=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
sha_c=cccccccccccccccccccccccccccccccccccccc
printf '%s\trefs/heads/main\n' "$sha_a" > "$MOCK_DIR/git.output"
registration="$($PMT_BIN watch --kind git-ref --remote https://example.invalid/repo.git --ref refs/heads/main --report-transitions --max-fires 1 --no-start-report --deadline +300)" || fail "git-ref registration failed"
watch_id=$(printf '%s\n' "$registration" | sed -n 's/^watch \([^ ]*\) registered.*/\1/p')
[ -n "$watch_id" ] || fail "watch id missing"
watch_dir="$PM_HOME/watches/$watch_id"
assert_eq "$(cat "$watch_dir/last")" "$sha_a" "registration captures ref SHA"
assert_grep "$watch_dir/detail" "old=$sha_a new=$sha_a" "registration detail has old/new SHA"
assert_grep "$MOCK_DIR/calls.log" 'git ls-remote https://example.invalid/repo.git refs/heads/main' "git ls-remote invocation"

printf '%s\trefs/heads/main\n' "$sha_b" > "$MOCK_DIR/git.output"
printf '0\n' > "$watch_dir/nextDue"
$PMT_BIN _sweep || fail "first moving-ref sweep failed"
assert_eq "$(cat "$watch_dir/last")" "$sha_b" "first ref movement observed"
assert_grep "$watch_dir/log" "old=$sha_a new=$sha_b" "first ref report carries old/new"

printf '%s\trefs/heads/main\n' "$sha_c" > "$MOCK_DIR/git.output"
printf '0\n' > "$watch_dir/nextDue"
$PMT_BIN _sweep || fail "second moving-ref sweep failed"
assert_eq "$(cat "$watch_dir/last")" "$sha_c" "second ref movement observed"
assert_grep "$watch_dir/log" "old=$sha_b new=$sha_c" "second ref evidence carries old/new"
assert_eq "$(grep -c 'TOKEN-CHANGE' "$watch_dir/log")" 2 "all ref movements recorded"
assert_eq "$(grep -c ' REPORT ' "$watch_dir/log")" 2 "max-fires includes exhaustion announcement"
assert_grep "$watch_dir/log" 'REPORT .*class=exhausted.*new=MAX-FIRES-REACHED' "max-fires exhaustion announcement"
assert_grep "$watch_dir/log" 'SUPPRESSED transition' "max-fires suppression evidence"
echo PASS: git-ref SHA token, old/new detail, and max-fires
