#!/bin/sh
. "$(dirname "$0")/common.sh"
setup
trap teardown EXIT
source_monitor
json_agents <<'JSON'
[{"id":"11111111-1111-1111-1111-111111111111","name":"alpha"},{"id":"22222222-2222-2222-2222-222222222222","name":"beta"}]
JSON
match="$(cat "$MOCK_DIR/agents.json" | pm_match_agent alpha)"
assert_eq "$match" "$(printf 'MATCH\t11111111-1111-1111-1111-111111111111\talpha')" "name match"
match="$(cat "$MOCK_DIR/agents.json" | pm_match_agent 2222222)"
assert_eq "$match" "$(printf 'MATCH\t22222222-2222-2222-2222-222222222222\tbeta')" "prefix match"

cat > "$MOCK_DIR/inspect.json" <<'JSON'
{"Status":"Idle","Archived":false,"PendingPermissions":[{"id":1}]}
JSON
assert_eq "$(inspect_agent 11111111-1111-1111-1111-111111111111)" 'idle 0 1' "inspect bridge"
resolve="$(resolve_agent alpha)"
assert_eq "$resolve" "$(printf '11111111-1111-1111-1111-111111111111\talpha')" "agent resolution"
echo PASS: python3 -c JSON bridge and agent resolution
