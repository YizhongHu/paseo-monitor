#!/bin/sh
. "$(dirname "$0")/common.sh"
setup
trap teardown EXIT
PASEO_MONITOR_LOG_MAX_BYTES=100000
export PASEO_MONITOR_LOG_MAX_BYTES
PASEO_MONITOR_BACKOFF_SCALE=1
export PASEO_MONITOR_BACKOFF_SCALE

cat > "$SANDBOX/mode" <<'EOF'
RUNNING
EOF
cat > "$SANDBOX/probe" <<EOF
#!/bin/sh
mode=\$(cat '$SANDBOX/mode')
case "\$mode" in
    AUTH) printf 'Permission denied (publickey)\\n' >&2; exit 255 ;;
    NET) printf 'Connection refused\\n' >&2; exit 1 ;;
    ENV) printf 'ENV-UNAVAILABLE\n' >&2; exit 1 ;;
    CONFIG) printf 'helper missing\n' >&2; exit 127 ;;
    *) printf '%s detail\\n' "\$mode" ;;
esac
EOF
chmod +x "$SANDBOX/probe"
if $PMT_BIN watch --script "$SANDBOX/probe" --reason 'missing deadline' --terminal DONE; then
    fail "missing deadline accepted"
fi

# Deadline is a durable event and is suppressed after the first expiry.
deadline_reg="$($PMT_BIN watch --script "$SANDBOX/probe" --reason 'deadline test' --terminal DONE --no-start-report --deadline +300)" || fail "deadline registration failed"
deadline_id=$(printf '%s\n' "$deadline_reg" | sed -n 's/^watch \([^ ]*\) registered.*/\1/p')
deadline_dir="$PM_HOME/watches/$deadline_id"
printf '%s\n' "$(sed 's/^deadline=.*/deadline=1/' "$deadline_dir/spec")" > "$deadline_dir/spec"
$PMT_BIN _sweep || fail "deadline sweep failed"
$PMT_BIN _sweep || fail "deadline repeat sweep failed"
assert_eq "$(cat "$deadline_dir/state")" expired "deadline state"
deadline_reports=$(grep -c ' REPORT ' "$deadline_dir/log")
assert_eq "$deadline_reports" 1 "deadline reports once"
assert_eq "$(cat "$deadline_dir/fires")" 1 "deadline fire once"
assert_grep "$deadline_dir/log" 'could not determine state; last observation RUNNING' "deadline evidence"

printf 'RUNNING\n' > "$SANDBOX/mode"
# Auth failures count, park at strike three, and stop probing while parked.
auth_reg="$($PMT_BIN watch --script "$SANDBOX/probe" --reason 'auth test' --terminal DONE --no-start-report --deadline +300)" || fail "auth registration failed"
auth_id=$(printf '%s\n' "$auth_reg" | sed -n 's/^watch \([^ ]*\) registered.*/\1/p')
auth_dir="$PM_HOME/watches/$auth_id"
printf 'AUTH\n' > "$SANDBOX/mode"
: > "$SANDBOX/probe-calls"
# The probe itself is snapshotted; count invocations by replacing the source
printf '%s\n' 0 > "$auth_dir/nextDue"
$PMT_BIN _sweep || fail "auth strike one failed"
printf '%s\n' 0 > "$auth_dir/nextDue"
$PMT_BIN _sweep || fail "auth strike two failed"
printf '%s\n' 0 > "$auth_dir/nextDue"
$PMT_BIN _sweep || fail "auth strike three failed"
assert_eq "$(cat "$auth_dir/health")" '3 auth' "auth health strikes"
assert_eq "$(cat "$auth_dir/state")" parked "auth park"
assert_grep "$auth_dir/log" 'PARKED auth failures=3' "auth park evidence"
printf 'RUNNING\n' > "$SANDBOX/mode"
$PMT_BIN _sweep || fail "parked auth sweep failed"
assert_eq "$(cat "$auth_dir/health")" '3 auth' "parked watch not probed"
printf '%s\n' "$(sed 's/^deadline=.*/deadline=1/' "$auth_dir/spec")" > "$auth_dir/spec"
$PMT_BIN _sweep || fail "parked deadline sweep failed"
assert_eq "$(cat "$auth_dir/state")" expired "parked deadline expiry"
assert_grep "$auth_dir/log" 'REPORT .*class=deadline' "parked deadline report"

# poke resumes a parked watch and performs an immediate healthy observation.
printf 'RUNNING\n' > "$SANDBOX/mode"
# Restore a future deadline and parked state for the explicit resume check.
printf '%s\n' "$(sed 's/^deadline=.*/deadline=9999999999/' "$auth_dir/spec")" > "$auth_dir/spec"
printf '%s\n' parked > "$auth_dir/state"
$PMT_BIN poke "$auth_id" || fail "poke failed"
assert_eq "$(cat "$auth_dir/state")" active "poke resumes park"
assert_eq "$(cat "$auth_dir/health")" '0 healthy' "poke healthy observation"

config_reg="$($PMT_BIN watch --script "$SANDBOX/probe" --reason 'config test' --terminal DONE --no-start-report --deadline +300)" || fail "config registration failed"
config_id=$(printf '%s\n' "$config_reg" | sed -n 's/^watch \([^ ]*\) registered.*/\1/p')
config_dir="$PM_HOME/watches/$config_id"
printf 'CONFIG\n' > "$SANDBOX/mode"
printf '%s\n' 0 > "$config_dir/nextDue"
$PMT_BIN _sweep || fail "config strike failed"
assert_eq "$(cat "$config_dir/health")" '1 config' "rc=127 config class"
assert_grep "$config_dir/log" 'PROBE-FAIL class=config count=1 rc=127' "config failure evidence"
if grep -q 'class=network.*rc=127' "$config_dir/log"; then fail "rc=127 classified as network"; fi
printf '%s\n' 0 > "$config_dir/nextDue"
$PMT_BIN _sweep || fail "config strike two failed"
printf '%s\n' 0 > "$config_dir/nextDue"
$PMT_BIN _sweep || fail "config strike three failed"
assert_eq "$(cat "$config_dir/health")" '3 config' "config health strikes"
assert_eq "$(cat "$config_dir/state")" parked "config failure parks"
assert_grep "$config_dir/log" 'PARKED config failures=3' "config park evidence"
printf '%s\n' "$(sed 's/^deadline=.*/deadline=1/' "$config_dir/spec")" > "$config_dir/spec"
$PMT_BIN _sweep || fail "parked config deadline sweep failed"
assert_eq "$(cat "$config_dir/state")" expired "parked config deadline expiry"
assert_grep "$config_dir/log" 'REPORT .*class=deadline' "parked config deadline report"
assert_grep "$config_dir/log" 'could not determine state; last observation RUNNING; last probe failure class=config count=3 rc=127' "deadline failure diagnosis"
printf 'RUNNING\n' > "$SANDBOX/mode"
printf '%s\n' "$(sed 's/^deadline=.*/deadline=9999999999/' "$config_dir/spec")" > "$config_dir/spec"
printf '%s\n' parked > "$config_dir/state"
$PMT_BIN poke "$config_id" || fail "config poke failed"
assert_eq "$(cat "$config_dir/state")" active "config poke resumes park"
assert_eq "$(cat "$config_dir/health")" '0 healthy' "config poke healthy observation"
# Network failures back off but never park.
printf 'RUNNING\n' > "$SANDBOX/mode"
network_reg="$($PMT_BIN watch --script "$SANDBOX/probe" --reason 'network test' --terminal DONE --no-start-report --deadline +300)" || fail "network registration failed"
network_id=$(printf '%s\n' "$network_reg" | sed -n 's/^watch \([^ ]*\) registered.*/\1/p')
printf 'NET\n' > "$SANDBOX/mode"
network_dir="$PM_HOME/watches/$network_id"
printf '%s\n' 0 > "$network_dir/nextDue"
$PMT_BIN _sweep || fail "network strike one failed"
printf '%s\n' 0 > "$network_dir/nextDue"
$PMT_BIN _sweep || fail "network strike two failed"
printf '%s\n' 0 > "$network_dir/nextDue"
$PMT_BIN _sweep || fail "network strike three failed"
assert_eq "$(cat "$network_dir/state")" active "network does not park"
assert_eq "$(cat "$network_dir/health")" '3 network' "network health strikes"
network_due=$(cat "$network_dir/nextDue")
network_now=$(date +%s)
[ "$network_due" -gt "$network_now" ] || fail "network nextDue did not back off"

# Login/session environment loss skips without changing health or parking.
printf 'RUNNING\n' > "$SANDBOX/mode"
env_reg="$($PMT_BIN watch --script "$SANDBOX/probe" --reason 'env test' --terminal DONE --no-start-report --deadline +300)" || fail "env registration failed"
env_id=$(printf '%s\n' "$env_reg" | sed -n 's/^watch \([^ ]*\) registered.*/\1/p')
env_dir="$PM_HOME/watches/$env_id"
printf 'ENV\n' > "$SANDBOX/mode"
$PMT_BIN _sweep || fail "environment skip failed"
assert_eq "$(cat "$env_dir/health")" '0 none' "environment skip has no strike"
assert_eq "$(cat "$env_dir/state")" active "environment skip does not park"
assert_grep "$env_dir/log" 'PROBE-SKIP class=env-unavailable' "environment skip evidence"

# Terminal state remains available for recovery status, including the beacon.
printf 'RUNNING\n' > "$SANDBOX/mode"
terminal_reg="$($PMT_BIN watch --script "$SANDBOX/probe" --reason 'retention test' --terminal DONE --no-start-report --deadline +300)" || fail "retention registration failed"
terminal_id=$(printf '%s\n' "$terminal_reg" | sed -n 's/^watch \([^ ]*\) registered.*/\1/p')
terminal_dir="$PM_HOME/watches/$terminal_id"
printf 'DONE\n' > "$SANDBOX/mode"
$PMT_BIN _sweep || fail "retention terminal sweep failed"
[ -d "$terminal_dir" ] || fail "terminal watch was collected"
status_output="$($PMT_BIN status "$terminal_id")" || fail "status failed"
printf '%s\n' "$status_output" > "$SANDBOX/status"
assert_grep "$SANDBOX/status" 'last-sweep-age:' "status freshness header"
assert_grep "$SANDBOX/status" 'last_token=DONE' "status last token"
assert_grep "$SANDBOX/status" 'last_transition=' "status transition time"
assert_grep "$SANDBOX/status" 'delivery=none-configured' "status local-only delivery"
if grep -q 'delivery_attempted=\|undelivered=\|delivery_error=' "$SANDBOX/status"; then
    fail "local-only status emitted configured-delivery fields"
fi
assert_grep "$SANDBOX/status" 'health=0 healthy' "status health"

echo PASS: deadline, auth park, network backoff, env skip, poke, retention, and status
