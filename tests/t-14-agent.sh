#!/bin/sh
. "$(dirname "$0")/common.sh"
setup
trap teardown EXIT
PASEO_MONITOR_LOG_MAX_BYTES=100000
export PASEO_MONITOR_LOG_MAX_BYTES
source_monitor
unset PM_SOURCE_ONLY

cat > "$MOCK_DIR/inspect.json" <<'EOF'
{"Status":"running","Archived":false,"PendingPermissions":[],"UpdatedAt":"2026-08-27T01:02:03Z"}
EOF
agent_reg="$($PMT_BIN watch --kind agent --agent agent-1 --report-on IDLE,BLOCKED-PERMISSION,CLOSED,ARCHIVED --no-start-report --deadline +300)" || fail "agent registration failed"
agent_id=$(printf '%s\n' "$agent_reg" | sed -n 's/^watch \([^ ]*\) registered.*/\1/p')
agent_dir="$PM_HOME/watches/$agent_id"
assert_eq "$(cat "$agent_dir/last")" RUNNING "agent running token"
assert_grep "$agent_dir/detail" 'updated_at=2026-08-27T01:02:03Z' "agent updated_at detail"
assert_grep "$agent_dir/spec" 'dwell=2' "agent dwell persisted"
agent_helper="$(sed -n 's/^helper=//p' "$agent_dir/spec")"
assert_eq "$agent_helper" "$SANDBOX/bin/paseo" "agent helper snapshotted as absolute path"
if PATH=/usr/bin:/bin:/usr/sbin:/sbin "$PMT_BIN" watch --kind agent --agent agent-1 --deadline +300 2>"$SANDBOX/missing-helper.err"; then
    fail "agent registration succeeded without paseo"
fi
assert_grep "$SANDBOX/missing-helper.err" 'required helper not found: paseo' "missing helper names binary"
pm_atomic_write "$agent_dir/nextDue" 0
pmt_sweep_minimal_path || fail "absolute helper sweep failed under minimal PATH"
assert_eq "$(cat "$agent_dir/last")" RUNNING "absolute helper executed without PATH"

# A watch registered before helper snapshotting has no helper= in its spec.
# It must recover by resolving from the current environment and back-filling,
# not exec an empty string and fail rc=127 on every sweep forever.
legacy_spec="$(grep -v '^helper=' "$agent_dir/spec")"
pm_atomic_write "$agent_dir/spec" "$legacy_spec"
assert_eq "$(sed -n 's/^helper=//p' "$agent_dir/spec")" "" "legacy spec has no helper"
pm_atomic_write "$agent_dir/nextDue" 0
$PMT_BIN _sweep || fail "legacy spec sweep failed"
assert_eq "$(sed -n 's/^helper=//p' "$agent_dir/spec")" "$SANDBOX/bin/paseo" "legacy spec back-filled with absolute helper"
assert_eq "$(cat "$agent_dir/health")" '0 healthy' "legacy spec recovered instead of rc=127"
pm_atomic_write "$agent_dir/nextDue" 0
pmt_sweep_minimal_path || fail "back-filled legacy watch failed under minimal PATH"

cat > "$MOCK_DIR/inspect.json" <<'EOF'
{"Status":"running","Archived":false,"PendingPermissions":[],"UpdatedAt":"2026-08-27T01:08:09Z"}
EOF
d7_reg="$($PMT_BIN watch --kind agent --agent agent-1 --report-on IDLE --report-to agent-2 --no-start-report --deliver paseo-queue --deadline +300)" || fail "minimal-path delivery registration failed"
d7_id=$(printf '%s\n' "$d7_reg" | sed -n 's/^watch \([^ ]*\) registered.*/\1/p')
d7_dir="$PM_HOME/watches/$d7_id"
assert_eq "$(sed -n 's/^helper=//p' "$d7_dir/spec")" "$SANDBOX/bin/paseo" "minimal-path helper absolute"
assert_eq "$(sed -n 's/^deliver=//p' "$d7_dir/spec")" "$SANDBOX/bin/paseo-queue" "minimal-path delivery absolute"
pm_atomic_write "$agent_dir/nextDue" 9999999999
cat > "$MOCK_DIR/inspect.json" <<'EOF'
{"Status":"idle","Archived":false,"PendingPermissions":[],"UpdatedAt":"2026-08-27T01:09:10Z"}
EOF
pm_atomic_write "$d7_dir/nextDue" 0
pmt_sweep_minimal_path || fail "minimal-path first delivery sweep failed"
pm_atomic_write "$d7_dir/nextDue" 0
pmt_sweep_minimal_path || fail "minimal-path second delivery sweep failed"
assert_eq "$(cat "$d7_dir/last")" IDLE "minimal-path probe observed transition"

cat > "$MOCK_DIR/inspect.json" <<'EOF'
{"Status":"running","Archived":false,"PendingPermissions":[],"UpdatedAt":"2026-08-27T01:10:11Z"}
EOF
pm_atomic_write "$agent_dir/last" RUNNING
rm -f "$agent_dir/dwell"
assert_grep "$MOCK_DIR/calls.log" 'paseo-queue add agent-2' "minimal-path delivery executed"
pm_atomic_write "$agent_dir/nextDue" 0

# A one-sweep running/idle flap is held as a candidate and not reported.
cat > "$MOCK_DIR/inspect.json" <<'EOF'
{"Status":"idle","Archived":false,"PendingPermissions":[],"UpdatedAt":"2026-08-27T01:03:04Z"}
EOF
pm_atomic_write "$agent_dir/nextDue" 0
$PMT_BIN _sweep || fail "first idle dwell sweep failed"
assert_eq "$(cat "$agent_dir/last")" RUNNING "idle candidate suppressed"
assert_grep "$agent_dir/log" 'DWELL IDLE count=1/2' "idle dwell evidence"
cat > "$MOCK_DIR/inspect.json" <<'EOF'
{"Status":"running","Archived":false,"PendingPermissions":[],"UpdatedAt":"2026-08-27T01:04:05Z"}
EOF
pm_atomic_write "$agent_dir/nextDue" 0
$PMT_BIN _sweep || fail "flap return sweep failed"
assert_eq "$(cat "$agent_dir/last")" RUNNING "running idle flap suppressed"
if grep -q 'class=transition' "$agent_dir/log"; then fail "flap produced a report"; fi

# A real idle transition dwells for two observations and reports facts only.
cat > "$MOCK_DIR/inspect.json" <<'EOF'
{"Status":"idle","Archived":false,"PendingPermissions":[],"UpdatedAt":"2026-08-27T01:05:06Z"}
EOF
pm_atomic_write "$agent_dir/nextDue" 0
$PMT_BIN _sweep || fail "idle candidate replay failed"
pm_atomic_write "$agent_dir/nextDue" 0
$PMT_BIN _sweep || fail "idle dwell completion failed"
assert_eq "$(cat "$agent_dir/last")" IDLE "idle transition accepted after dwell"
assert_grep "$agent_dir/log" 'went idle' "idle fact wording"
assert_grep "$agent_dir/log" 'updated_at=2026-08-27T01:05:06Z' "verbatim updated_at"
assert_grep "$agent_dir/log" 'idle_since=2026-08-27T01:05:06Z' "idle_since fact"

# Pending permissions are the validated stall signal and include queue depth.
cat > "$MOCK_DIR/inspect.json" <<'EOF'
{"Status":"running","Archived":false,"PendingPermissions":[{"id":"p1"},{"id":"p2"}],"UpdatedAt":"2026-08-27T01:06:07Z"}
EOF
pm_atomic_write "$agent_dir/nextDue" 0
$PMT_BIN _sweep || fail "permission stall sweep failed"
assert_eq "$(cat "$agent_dir/last")" BLOCKED-PERMISSION "permission stall token"
assert_grep "$agent_dir/log" 'class=transition' "permission stall report"
assert_grep "$agent_dir/log" 'pendingPermissions=2 queue_depth=2' "permission queue depth"

# Archived is an observable terminal event, distinct from idle.
cat > "$MOCK_DIR/inspect.json" <<'EOF'
{"Status":"idle","Archived":true,"ArchivedAt":"2026-08-27T01:07:08Z","PendingPermissions":[],"UpdatedAt":"2026-08-27T01:07:08Z"}
EOF
pm_atomic_write "$agent_dir/nextDue" 0
$PMT_BIN _sweep || fail "archived sweep failed"
assert_eq "$(cat "$agent_dir/last")" ARCHIVED "archived token"
assert_eq "$(cat "$agent_dir/state")" terminal "archived terminal state"
echo PASS: agent permission stalls, idle dwell facts, and archived state
