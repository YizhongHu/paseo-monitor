#!/bin/sh
# Shared isolated harness for paseo-monitor primitive tests.
set -u

PMT_SELF_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
PMT_REPO_ROOT="$(CDPATH= cd -- "$PMT_SELF_DIR/.." && pwd)"
PMT_BIN="$PMT_REPO_ROOT/bin/paseo-monitor"
PMT_MOCK_DIR="$PMT_REPO_ROOT/tests/mock"
SANDBOX=""
MOCK_DIR=""

setup() {
    SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/pm-test.XXXXXX")" || exit 1
    mkdir -p "$SANDBOX/bin" "$SANDBOX/home" "$SANDBOX/mock"
    cp "$PMT_MOCK_DIR/paseo" "$SANDBOX/bin/paseo"
    cp "$PMT_MOCK_DIR/paseo-queue" "$SANDBOX/bin/paseo-queue"
    cp "$PMT_MOCK_DIR/ssh" "$SANDBOX/bin/ssh"
    cp "$PMT_MOCK_DIR/git" "$SANDBOX/bin/git"
    cp "$PMT_MOCK_DIR/gh" "$SANDBOX/bin/gh"
    cp "$PMT_MOCK_DIR/globus" "$SANDBOX/bin/globus"
    chmod +x "$SANDBOX/bin/paseo" "$SANDBOX/bin/paseo-queue" "$SANDBOX/bin/ssh" "$SANDBOX/bin/git" "$SANDBOX/bin/gh" "$SANDBOX/bin/globus"
    PATH="$SANDBOX/bin:$PATH"
    export PATH
    PASEO_MONITOR_HOME="$SANDBOX/home/.paseo-monitor"
    PASEO_MONITOR_LOG_MAX_BYTES=128
    PASEO_MONITOR_LOCK_GRACE_SECONDS=0
    PASEO_MONITOR_BACKOFF_SCALE=0
    PASEO_MONITOR_FAST_SWEEP=1
    export PASEO_MONITOR_HOME PASEO_MONITOR_LOG_MAX_BYTES
    export PASEO_MONITOR_LOCK_GRACE_SECONDS PASEO_MONITOR_BACKOFF_SCALE PASEO_MONITOR_FAST_SWEEP
    unset PASEO_AGENT_ID
    MOCK_DIR="$SANDBOX/mock"
    export MOCK_DIR
    : > "$MOCK_DIR/agents.json"
    : > "$MOCK_DIR/calls.log"
    : > "$MOCK_DIR/ssh.script"
    : > "$MOCK_DIR/send.log"
}

teardown() {
    [ -n "$SANDBOX" ] && [ -d "$SANDBOX" ] && rm -rf "$SANDBOX"
}

fail() {
    echo "FAIL: $*" >&2
    [ -n "$SANDBOX" ] && echo "  sandbox: $SANDBOX" >&2
    exit 1
}

assert_eq() {
    [ "$1" = "$2" ] || fail "${3:-assert_eq}: expected [$2], got [$1]"
}

assert_rc() {
    [ "$1" = "$2" ] || fail "${3:-assert_rc}: expected rc=$1, got rc=$2"
}

assert_grep() {
    [ -f "$1" ] || fail "${3:-assert_grep}: file not found: $1"
    grep -q -- "$2" "$1" || fail "${3:-assert_grep}: pattern [$2] not found in $1"
}

source_monitor() {
    PM_SOURCE_ONLY=1
    export PM_SOURCE_ONLY
    # shellcheck disable=SC1090
    . "$PMT_BIN"
}

pmt_sweep_minimal_path() {
    # pmt_sweep_minimal_path -- exercise _sweep as launchd does.
    pmt_saved_path="$PATH"
    PATH=/usr/bin:/bin:/usr/sbin:/sbin
    export PATH
    "$PMT_BIN" _sweep
    pmt_rc=$?
    PATH="$pmt_saved_path"
    export PATH
    return "$pmt_rc"
}

json_agents() {
    cat > "$MOCK_DIR/agents.json"
}

mock_ssh_script() {
    while ! mkdir "$MOCK_DIR/ssh.lock" 2>/dev/null; do sleep 1; done
    : > "$MOCK_DIR/ssh.script"
    for pmts_line in "$@"; do printf '%s\n' "$pmts_line" >> "$MOCK_DIR/ssh.script"; done
    rmdir "$MOCK_DIR/ssh.lock"
}
