#!/bin/sh
. "$(dirname "$0")/common.sh"
setup
trap teardown EXIT
source_monitor

remote_dir="$SANDBOX/remote-watch"
mkdir -p "$remote_dir"
cat > "$remote_dir/spec" <<'EOF'
kind=file-exists
host=cannon
path=/scratch/result
EOF
: > "$remote_dir/out"
: > "$remote_dir/err"
tab="$(printf '\t')"

mock_ssh_script "255${tab}${tab}Permission denied (publickey)"
pm_run_remote_probe "$remote_dir/out" "$remote_dir/err" cannon ls -d /scratch/result
rc=$?
assert_rc "$rc" 255 "ssh auth failure rc"
assert_eq "$(pm_health_failure_class "$rc" "$(cat "$remote_dir/err")")" auth "ssh auth classification"
assert_grep "$remote_dir/err" 'auth-class ssh-rc=255' "auth class evidence"
assert_grep "$MOCK_DIR/calls.log" 'BatchMode=yes' "BatchMode on auth probe"
assert_grep "$MOCK_DIR/calls.log" 'ConnectTimeout=15' "ConnectTimeout on auth probe"

mock_ssh_script "255${tab}${tab}ssh: connect to host cannon port 22: Connection timed out"
pm_run_remote_probe "$remote_dir/out" "$remote_dir/err" cannon ls -d /scratch/result
rc=$?
assert_rc "$rc" 255 "ssh network failure rc"
assert_eq "$(pm_health_failure_class "$rc" "$(cat "$remote_dir/err")")" network "ssh network classification"
assert_grep "$remote_dir/err" 'network-class ssh-rc=255' "network class evidence"

mock_ssh_script "0${tab}/scratch/result"
pm_run_registered_probe "$remote_dir" "$remote_dir/out" "$remote_dir/err" || fail "remote file probe failed"
pm_parse_probe_output "$remote_dir/out" || fail "remote file output invalid"
assert_eq "$PM_PARSED_TOKEN" EXISTS "remote file present token"
assert_grep "$MOCK_DIR/calls.log" 'ssh -o BatchMode=yes -o ConnectTimeout=15 cannon ls -d /scratch/result' "remote file argv"

mock_ssh_script "1${tab}${tab}ls: cannot access /scratch/result: No such file"
pm_run_registered_probe "$remote_dir" "$remote_dir/out" "$remote_dir/err" || fail "remote file absence probe failed"
pm_parse_probe_output "$remote_dir/out" || fail "remote absence output invalid"
assert_eq "$PM_PARSED_TOKEN" ABSENT "remote file absent token"
echo PASS: shared SSH auth and network classification, flags, and remote file mapping
