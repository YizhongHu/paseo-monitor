#!/bin/sh
. "$(dirname "$0")/common.sh"
setup
trap teardown EXIT

cat > "$SANDBOX/bin/launchctl" <<'EOF'
#!/bin/sh
case "$1" in
    print)
        [ -f "$MOCK_DIR/launchd.loaded" ] || exit 1
        exit 0
        ;;
    bootstrap)
        : > "$MOCK_DIR/launchd.loaded"
        printf 'bootstrap %s %s\n' "$2" "$3" >> "$MOCK_DIR/launchd.calls"
        exit 0
        ;;
    bootout)
        rm -f "$MOCK_DIR/launchd.loaded"
        printf 'bootout %s\n' "$2" >> "$MOCK_DIR/launchd.calls"
        exit 0
        ;;
    *) exit 1 ;;
esac
EOF
chmod +x "$SANDBOX/bin/launchctl"
export HOME="$SANDBOX/home"
PATH="$SANDBOX/bin:$HOME/.local/bin:$PATH"
export PATH
PASEO_MONITOR_HOME="$HOME/.paseo-monitor"
export PASEO_MONITOR_HOME

./install.sh || fail "launchd install failed"
plist="$HOME/Library/LaunchAgents/com.paseo-monitor.sweep.plist"
[ -f "$plist" ] || fail "plist missing"
assert_grep "$plist" 'paseo-monitor: managed launchd agent' "managed marker"
assert_grep "$plist" '<key>StartInterval</key>' "start interval key"
assert_grep "$plist" '<integer>60</integer>' "start interval value"
assert_grep "$plist" '<key>RunAtLoad</key>' "run at load key"
assert_grep "$plist" '<key>PATH</key>' "launchd PATH key"
assert_grep "$plist" "<string>$PATH</string>" "launchd PATH value"
[ -f "$MOCK_DIR/launchd.loaded" ] || fail "launchd agent not bootstrapped"
for skill_root in "$HOME/.claude/skills" "$HOME/.codex/skills" "$HOME/.agents/skills"; do
    [ -f "$skill_root/paseo-monitor/SKILL.md" ] || fail "skill missing from $skill_root"
    cmp -s "$skill_root/paseo-monitor/SKILL.md" "$PMT_REPO_ROOT/skills/paseo-monitor/SKILL.md" || fail "skill mismatch in $skill_root"
done
./install.sh >/dev/null || fail "idempotent launchd install failed"
assert_grep "$MOCK_DIR/launchd.calls" 'bootout gui/' "reload existing agent"

rm -f "$MOCK_DIR/launchd.loaded"
cat > "$SANDBOX/probe" <<EOF
#!/bin/sh
printf 'RUNNING detail\n'
EOF
chmod +x "$SANDBOX/probe"
registration="$("$HOME/.local/bin/paseo-monitor" watch --script "$SANDBOX/probe" --reason 'trigger check' --terminal DONE --deadline +300)" || fail "registration self-heal failed"
watch_id=$(printf '%s\n' "$registration" | sed -n 's/^watch \([^ ]*\) registered.*/\1/p')
[ -f "$MOCK_DIR/launchd.loaded" ] || fail "registration did not self-heal launchd"
$PMT_BIN _sweep || fail "beacon sweep failed"
status_output="$($PMT_BIN status "$watch_id")" || fail "beacon status failed"
printf '%s\n' "$status_output" > "$SANDBOX/status"
assert_grep "$SANDBOX/status" 'last-sweep-age:' "freshness beacon header"

./install.sh uninstall || fail "launchd uninstall failed"
[ ! -f "$plist" ] || fail "plist survived uninstall"
[ ! -f "$MOCK_DIR/launchd.loaded" ] || fail "launchd job survived uninstall"
[ ! -e "$HOME/.local/bin/paseo-monitor" ] || fail "CLI symlink survived uninstall"
echo PASS: launchd marker install, bootstrap idempotence, and uninstall
