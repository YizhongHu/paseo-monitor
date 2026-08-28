#!/bin/sh
. "$(dirname "$0")/common.sh"
setup
trap teardown EXIT
source_monitor
ensure_dirs "$PM_HOME"
log_line "$PM_HOME" EVENT first || fail "root log failed"
assert_grep "$PM_HOME/sweep.log" 'EVENT first' "root log"
case "$(TZ=America/New_York date '+%Y-%m-%dT%H:%M:%S%z')" in
    *) assert_grep "$PM_HOME/sweep.log" '[-+][0-9][0-9][0-9][0-9] \[' "timezone timestamp" ;;
esac
printf '012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789\n' > "$PM_HOME/sweep.log"
rotate_log_if_big "$PM_HOME" || fail "rotation failed"
[ -f "$PM_HOME/sweep.log.1" ] || fail "rotated log missing"
[ ! -f "$PM_HOME/sweep.log" ] || fail "old log was not moved"
mkdir -p "$PM_HOME/watches/w1"
log_line "$PM_HOME/watches/w1" WATCH detail || fail "watch log failed"
assert_grep "$PM_HOME/watches/w1/log" 'WATCH detail' "watch log"
echo PASS: timestamped log and rotation
