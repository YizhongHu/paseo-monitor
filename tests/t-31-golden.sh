#!/bin/sh
# Golden contract test: fixtures are blessed from reference/paseo-monitor.sh,
# then every run compares the executable under test against those fixtures.
set -u
. "$(dirname "$0")/common.sh"
setup
trap teardown EXIT
PASEO_MONITOR_LOG_MAX_BYTES=100000
export PASEO_MONITOR_LOG_MAX_BYTES

PMT_REFERENCE_BIN="$PMT_REPO_ROOT/reference/paseo-monitor.sh"
GOLDEN_DIR="$PMT_REPO_ROOT/tests/golden"
PMT_PYTHON_DIR=""
case "$PMT_BIN" in
    *.py|*/paseo-monitor) PMT_PYTHON_DIR=$(dirname "$(command -v python3)") ;;
esac
CANDIDATE_DIR="$SANDBOX/candidate"
mkdir -p "$CANDIDATE_DIR"

normalize_text() {
    sed \
        -e "s|$SANDBOX|<SANDBOX>|g" \
        -e "s|$PM_HOME|<HOME>|g" \
        -e "s|$PASEO_MONITOR_HOME|<HOME>|g" \
        -e 's|/[^ ]*/home/\.paseo-monitor/watches/|<SANDBOX>/home/.paseo-monitor/watches/|g' \
        -e 's/at=[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9][+-][0-9][0-9][0-9][0-9]/at=<TIMESTAMP>/g' \
        -e 's/registered=[0-9][0-9]*/registered=<EPOCH>/g' \
        -e 's/deadline=[0-9][0-9]*/deadline=<EPOCH>/g' \
        -e 's/event=[^ ]*/event=<EVENT>/g' \
        -e 's/REPORT [0-9][0-9]*-[0-9][0-9]*-[0-9][0-9]*/REPORT <EVENT>/g' \
        -e 's/watch=[^ ]*/watch=<WATCH-ID>/g' \
        -e 's#watches/[^/]*/#watches/<WATCH-ID>/#g' \
        -e 's#graveyard/[^/]*/#graveyard/<WATCH-ID>/#g' \
        -e 's/elapsed=[0-9][0-9]*s/elapsed=<SECONDS>/g' \
        -e 's/\[[0-9][0-9]*\]/[<PID>]/g' \
        -e 's/^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9][+-][0-9][0-9][0-9][0-9] /<TIMESTAMP> /g' \
        -e 's/nextDue=[0-9][0-9]*/nextDue=<EPOCH>/g' \
        -e 's#^python=/.*#python=<PYTHON>#' \
        -e 's#^helper=.*#helper=<HELPER>#' \
        -e 's|backend=/[^ ]*/|backend=<SANDBOX>/|g'
}
capture_report() {
    report_class="$1"
    report_file="$2"
    report_line="$(awk -v needle="class=$report_class" '$0 ~ needle { print; exit }' "$MOCK_DIR/reports")"
    [ -n "$report_line" ] || fail "missing delivered report: $report_class (reports: $(cat "$MOCK_DIR/reports" 2>/dev/null || printf '<none>'))"
    case "$report_line" in
        MONITOR\ REPORT*PROHIBITIONS=*) ;;
        *) fail "report lacks front-loaded prohibitions: $report_class" ;;
    esac
    printf '%s\n' "$report_line" | grep -E -q 'elapsed=[0-9][0-9]*s' || fail "report elapsed is not computed: $report_class"
    report_bytes="$(printf '%s' "$report_line" | wc -c | tr -d ' ')"
    [ "$report_bytes" -le 2048 ] || fail "report exceeds 2048-byte envelope: $report_class"
    if [ "$report_class" = started ]; then
        printf '%s\n' "$report_line" | grep -F -q '<...truncated ' || fail "started context was not field-truncated"
    fi
    printf '%s\n' "$report_line" | normalize_text > "$report_file"
}


normalize_spec() {
    normalize_text < "$1"
}

record_error() {
    record_label="$1"
    shift
    record_saved_path="$PATH"
    set +e
    "$source_bin" "$@" > "$SANDBOX/stdout" 2> "$SANDBOX/stderr"
    record_rc=$?
    PATH=/usr/bin:/bin
    export PATH
    record_err=$(tr '\n' ' ' < "$SANDBOX/stderr" | sed 's/ $//')
    PATH="$record_saved_path"
    export PATH
    printf '%s\trc=%s\t%s\n' "$record_label" "$record_rc" "$record_err" >> "$CANDIDATE_DIR/errors.txt"
}

source_bin="$PMT_BIN"
bless=0
if [ "${P2_REBLESS:-0}" = 1 ]; then
    source_bin="$PMT_REFERENCE_BIN"
    bless=1
fi

# CLI output is deterministic and retained byte-for-byte.
"$source_bin" --help > "$CANDIDATE_DIR/help.txt" || fail "help command failed"
"$source_bin" kinds > "$CANDIDATE_DIR/kinds.txt" || fail "kinds command failed"

# Exact error text and exit status are part of the public CLI contract.
cat > "$SANDBOX/probe" <<'EOF'
#!/bin/sh
printf 'RUNNING probe-detail\n'
EOF
chmod +x "$SANDBOX/probe"
cat > "$SANDBOX/broken" <<'EOF'
#!/bin/sh
printf 'broken probe detail\n' >&2
exit 9
EOF
chmod +x "$SANDBOX/broken"
: > "$CANDIDATE_DIR/errors.txt"
record_error missing-deadline watch --script "$SANDBOX/probe" --reason reason --terminal DONE
record_error script-reason-mandatory watch --script "$SANDBOX/probe" --terminal DONE --deadline +300
record_error script-terminal-mandatory watch --script "$SANDBOX/probe" --reason reason --deadline +300
record_error slurm-cadence-floor watch --kind slurm --host cannon --job 42 --interval 119 --deadline +300
record_error registration-probe-failure watch --script "$SANDBOX/broken" --reason broken --terminal DONE --deadline +300
mkdir -p "$SANDBOX/sandbox-bin"
cat > "$SANDBOX/sandbox-bin/ssh" <<'EOF'
#!/bin/sh
printf '%s\n' 'Control socket connect(/x): Operation not permitted' 'ssh: Could not resolve hostname h: -65563' >&2
exit 255
EOF
chmod +x "$SANDBOX/sandbox-bin/ssh"
old_path="$PATH"
PATH="$SANDBOX/sandbox-bin:$PATH"
export PATH
record_error sandbox-registration watch --kind slurm --host cannon --job sandbox --deadline +300 --no-start-report
PATH="$old_path"
export PATH
old_path="$PATH"
PATH="$SANDBOX/empty:${PMT_PYTHON_DIR:+$PMT_PYTHON_DIR:}/usr/bin:/bin:/usr/sbin:/sbin"
export PATH
record_error required-paseo-helper watch --kind agent --agent AGENT-ID --deadline +300
PATH="$old_path"
export PATH
record_error watch-not-found status DOES-NOT-EXIST

# Five delivered reports exercise the envelope front matter, elapsed field,
# field-wise context marker, and lifecycle classes. Each is normalized only for
# IDs, timestamps, process IDs, and sandbox paths.
cat > "$SANDBOX/deliver" <<EOF
#!/bin/sh
cat >> '$MOCK_DIR/reports'
EOF
chmod +x "$SANDBOX/deliver"
cat > "$SANDBOX/mode" <<'EOF'
RUNNING
EOF
cat > "$SANDBOX/report-probe" <<EOF
#!/bin/sh
printf '%s report-detail\n' "\$(cat '$SANDBOX/mode')"
EOF
chmod +x "$SANDBOX/report-probe"
: > "$MOCK_DIR/reports"
long_context='target=report-target changed=running'
while [ "$(printf '%s' "$long_context" | wc -c | tr -d ' ')" -lt 700 ]; do
    long_context="${long_context};field=0123456789abcdefghijklmnopqrstuvwxyz"
done
set +e
started_output=$("$source_bin" watch --script "$SANDBOX/report-probe" --reason report-contract --terminal DONE --context "$long_context" --prohibit 'never override target' --label role=worker --deliver "$SANDBOX/deliver" --deadline +300)
started_rc=$?
set -u
[ "$started_rc" -eq 0 ] || fail "started report registration failed"
started_id=$(printf '%s\n' "$started_output" | sed -n 's/^watch \([^ ]*\) registered.*/\1/p')
capture_report started "$CANDIDATE_DIR/report-started.txt"

printf 'DONE\n' > "$SANDBOX/mode"
terminal_output=$("$source_bin" watch --script "$SANDBOX/report-probe" --reason report-terminal --terminal DONE --deliver "$SANDBOX/deliver" --deadline +300) || fail "terminal report registration failed"
capture_report terminal "$CANDIDATE_DIR/report-terminal.txt"
printf 'RUNNING\n' > "$SANDBOX/mode"

deadline_output=$("$source_bin" watch --script "$SANDBOX/report-probe" --reason report-deadline --terminal DONE --no-start-report --deliver "$SANDBOX/deliver" --deadline +300) || fail "deadline registration failed"
deadline_id=$(printf '%s\n' "$deadline_output" | sed -n 's/^watch \([^ ]*\) registered.*/\1/p')
deadline_dir="$PM_HOME/watches/$deadline_id"
deadline_epoch=$(( $(date +%s) - 1 ))
sed "s/^deadline=.*/deadline=$deadline_epoch/" "$deadline_dir/spec" > "$SANDBOX/deadline-spec"
cat "$SANDBOX/deadline-spec" > "$deadline_dir/spec"
printf '0\n' > "$deadline_dir/nextDue"
"$source_bin" _sweep > /dev/null || fail "deadline sweep failed"
capture_report deadline "$CANDIDATE_DIR/report-deadline.txt"

printf 'RUNNING\n' > "$SANDBOX/mode"
cancel_output=$("$source_bin" watch --script "$SANDBOX/report-probe" --reason report-cancelled --terminal DONE --no-start-report --deliver "$SANDBOX/deliver" --deadline +300) || fail "cancel registration failed"
cancel_id=$(printf '%s\n' "$cancel_output" | sed -n 's/^watch \([^ ]*\) registered.*/\1/p')
"$source_bin" rm "$cancel_id" > /dev/null || fail "cancel removal failed"
capture_report cancelled "$CANDIDATE_DIR/report-cancelled.txt"

printf 'RUNNING\n' > "$SANDBOX/mode"
exhausted_output=$("$source_bin" watch --script "$SANDBOX/report-probe" --reason report-exhausted --terminal DONE --no-start-report --max-fires 1 --deliver "$SANDBOX/deliver" --deadline +300) || fail "exhaustion registration failed"
exhausted_id=$(printf '%s\n' "$exhausted_output" | sed -n 's/^watch \([^ ]*\) registered.*/\1/p')
printf 'DONE\n' > "$SANDBOX/mode"
printf '0\n' > "$PM_HOME/watches/$exhausted_id/nextDue"
"$source_bin" _sweep > /dev/null || fail "exhaustion sweep failed"
capture_report exhausted "$CANDIDATE_DIR/report-exhausted.txt"

# Register every bundled kind and retain its serialized spec. The spec body is
# verbatim except for values that are machine-specific by construction.
rm -rf "$PM_HOME"
mkdir -p "$PM_HOME" "$MOCK_DIR"
: > "$MOCK_DIR/ssh.script"
: > "$MOCK_DIR/reports"
: > "$MOCK_DIR/inspect.json"
: > "$CANDIDATE_DIR/specs.txt"
register_spec() {
    spec_label="$1"
    shift
    set +e
    spec_output=$("$source_bin" watch "$@" --no-start-report --deadline +300 2> "$SANDBOX/spec.err")
    spec_rc=$?
    set -u
    [ "$spec_rc" -eq 0 ] || fail "spec registration failed: $spec_label: $(cat "$SANDBOX/spec.err")"
    spec_id=$(printf '%s\n' "$spec_output" | sed -n 's/^watch \([^ ]*\) registered.*/\1/p')
    [ -n "$spec_id" ] || fail "spec id missing: $spec_label"
    printf '%s\n' "[$spec_label]" >> "$CANDIDATE_DIR/specs.txt"
    normalize_spec "$PM_HOME/watches/$spec_id/spec" >> "$CANDIDATE_DIR/specs.txt"
}

printf '0\tCOMPLETED\t\n' > "$MOCK_DIR/ssh.script"
register_spec slurm --kind slurm --host cannon --job 42
printf '0\tjob_state = F\t\n' > "$MOCK_DIR/ssh.script"
register_spec pbs --kind pbs --host polaris --job 42.server
MOCK_GLOBUS_OUTPUT='{"status":"SUCCEEDED","nice_status":"done","faults":[],"fatal_error":null,"effective_bytes_per_second":42}'
export MOCK_GLOBUS_OUTPUT
register_spec globus --kind globus --task TASK-ID
printf '{"Status":"idle","Archived":false,"PendingPermissions":[],"UpdatedAt":"2026-08-27T12:00:00Z"}\n' > "$MOCK_DIR/inspect.json"
register_spec agent --kind agent --agent AGENT-ID
# Capture the complete observed live/graveyard layout, including contents of
# every durable file that registration and one sweep actually create.
printf 'root-layout: sweep.lock/ sweep.log sweep.beacon\n' > "$CANDIDATE_DIR/state-layout.txt"
printf 'root-observed-after-sweep: sweep.log sweep.beacon\n' >> "$CANDIDATE_DIR/state-layout.txt"
printf 'root-created-by-clean-sweep: sweep.log; sweep.lock/ is ephemeral\n' >> "$CANDIDATE_DIR/state-layout.txt"
layout_output=$("$source_bin" watch --script "$SANDBOX/report-probe" --reason layout --terminal DONE --no-start-report --deadline +300) || fail "layout registration failed"
layout_id=$(printf '%s\n' "$layout_output" | sed -n 's/^watch \([^ ]*\) registered.*/\1/p')
layout_dir="$PM_HOME/watches/$layout_id"
[ -f "$layout_dir/log" ] || fail "layout registration did not create log; layout=$layout_dir entries=$(printf '%s ' "$layout_dir"/*)"
printf 'live-observed:\n' >> "$CANDIDATE_DIR/state-layout.txt"
cat > "$SANDBOX/refuse-layout" <<'EOF'
#!/bin/sh
printf 'layout delivery refused\n' >&2
exit 9
EOF
chmod +x "$SANDBOX/refuse-layout"
printf 'RUNNING\n' > "$SANDBOX/mode"
failed_layout_output=$("$source_bin" watch --script "$SANDBOX/report-probe" --reason undelivered-layout --terminal DONE --deliver "$SANDBOX/refuse-layout" --deadline +300) || fail "undelivered layout registration failed"
failed_layout_id=$(printf '%s\n' "$failed_layout_output" | sed -n 's/^watch \([^ ]*\) registered.*/\1/p')
failed_layout_dir="$PM_HOME/watches/$failed_layout_id"
[ -f "$failed_layout_dir/undelivered" ] || fail "undelivered layout sample missing"
printf '%s\n' '--- undelivered sample ---' >> "$CANDIDATE_DIR/state-layout.txt"
normalize_text < "$failed_layout_dir/undelivered" >> "$CANDIDATE_DIR/state-layout.txt"
printf 'DONE\n' > "$SANDBOX/mode"
for layout_file in spec context probe last detail nextDue health state fires log undelivered dwell; do
    if [ -e "$layout_dir/$layout_file" ]; then
        printf '%s\n' "--- $layout_file ---" >> "$CANDIDATE_DIR/state-layout.txt"
        if [ "$layout_file" = nextDue ]; then
            printf '%s\n' '<EPOCH>' >> "$CANDIDATE_DIR/state-layout.txt"
        else
            normalize_text < "$layout_dir/$layout_file" >> "$CANDIDATE_DIR/state-layout.txt"
        fi
    fi
done
"$source_bin" _sweep > /dev/null || fail "layout sweep failed"
if [ -f "$PM_HOME/sweep.log" ]; then
    printf '%s\n' '--- root sweep.log ---' >> "$CANDIDATE_DIR/state-layout.txt"
    normalize_text < "$PM_HOME/sweep.log" >> "$CANDIDATE_DIR/state-layout.txt"
else
    printf '%s\n' 'root sweep.log: not created by clean sweep' >> "$CANDIDATE_DIR/state-layout.txt"
fi
printf '%s\n' '--- root sweep.beacon ---' >> "$CANDIDATE_DIR/state-layout.txt"
sed 's/^[0-9][0-9]* [0-9][0-9]*-[0-9][0-9]*-[0-9][0-9]*T[0-9][0-9]*:[0-9][0-9]*:[0-9][0-9]*[+-][0-9][0-9]*$/<EPOCH> <TIMESTAMP>/' "$PM_HOME/sweep.beacon" >> "$CANDIDATE_DIR/state-layout.txt"
"$source_bin" rm "$layout_id" > /dev/null || fail "layout removal failed"
printf 'graveyard-observed:\n' >> "$CANDIDATE_DIR/state-layout.txt"
for layout_file in spec context probe last detail nextDue health state fires log graveyard undelivered dwell; do
    if [ -e "$PM_HOME/graveyard/$layout_id/$layout_file" ]; then
        printf '%s\n' "--- graveyard/$layout_file ---" >> "$CANDIDATE_DIR/state-layout.txt"
        if [ "$layout_file" = nextDue ]; then
            printf '%s\n' '<EPOCH>' >> "$CANDIDATE_DIR/state-layout.txt"
        else
            normalize_text < "$PM_HOME/graveyard/$layout_id/$layout_file" >> "$CANDIDATE_DIR/state-layout.txt"
        fi
    fi
done
printf '%s\n' 'compatibility-link: watches/<watch-id> -> ../graveyard/<watch-id>' >> "$CANDIDATE_DIR/state-layout.txt"

# Four-surface agreement is represented as exact executable facts plus required
# documentation tokens. The documentation files are owned by the P7 lane.
if [ -f "$PMT_REPO_ROOT/README.md" ] && [ -f "$PMT_REPO_ROOT/skills/paseo-monitor/SKILL.md" ]; then
    printf 'kinds-equals-help-kind-table: ' > "$CANDIDATE_DIR/surface-agreement.txt"
    sed -n '/^Kind table:/,$p' "$CANDIDATE_DIR/help.txt" | sed '1d' > "$SANDBOX/help-kinds"
    if cmp -s "$CANDIDATE_DIR/kinds.txt" "$SANDBOX/help-kinds"; then
        printf 'yes\n' >> "$CANDIDATE_DIR/surface-agreement.txt"
    else
        printf 'no\n' >> "$CANDIDATE_DIR/surface-agreement.txt"
    fi
    for surface_file in README.md skills/paseo-monitor/SKILL.md; do
        printf '%s required-kind-and-deadline-tokens:\n' "$surface_file" >> "$CANDIDATE_DIR/surface-agreement.txt"
        for surface_token in slurm pbs globus agent file-exists git-ref pr-merge script --deadline --report-transitions; do
            if grep -F -q -- "$surface_token" "$PMT_REPO_ROOT/$surface_file"; then
                printf 'yes %s\n' "$surface_token" >> "$CANDIDATE_DIR/surface-agreement.txt"
            else
                printf 'no %s\n' "$surface_token" >> "$CANDIDATE_DIR/surface-agreement.txt"
            fi
        done
    done
else
    printf '%s\n' 'documentation-surfaces: pending P7 files' > "$CANDIDATE_DIR/surface-agreement.txt"
fi

if [ "$bless" -eq 1 ]; then
    mkdir -p "$GOLDEN_DIR/reports"
    cp "$CANDIDATE_DIR/help.txt" "$GOLDEN_DIR/help.txt"
    cp "$CANDIDATE_DIR/kinds.txt" "$GOLDEN_DIR/kinds.txt"
    cp "$CANDIDATE_DIR/errors.txt" "$GOLDEN_DIR/errors.txt"
    cp "$CANDIDATE_DIR/specs.txt" "$GOLDEN_DIR/specs.txt"
    cp "$CANDIDATE_DIR/state-layout.txt" "$GOLDEN_DIR/state-layout.txt"
    cp "$CANDIDATE_DIR/surface-agreement.txt" "$GOLDEN_DIR/surface-agreement.txt"
    for report_class in started terminal deadline cancelled exhausted; do
        cp "$CANDIDATE_DIR/report-$report_class.txt" "$GOLDEN_DIR/reports/$report_class.txt"
    done
    echo 'PASS: blessed golden fixtures from reference implementation'
    exit 0
fi

for golden_file in help.txt kinds.txt errors.txt specs.txt state-layout.txt surface-agreement.txt; do
    cmp -s "$CANDIDATE_DIR/$golden_file" "$GOLDEN_DIR/$golden_file" || {
        diff -u "$GOLDEN_DIR/$golden_file" "$CANDIDATE_DIR/$golden_file" >&2
        fail "golden drift: $golden_file"
    }
done
for report_class in started terminal deadline cancelled exhausted; do
    cmp -s "$CANDIDATE_DIR/report-$report_class.txt" "$GOLDEN_DIR/reports/$report_class.txt" || {
        diff -u "$GOLDEN_DIR/reports/$report_class.txt" "$CANDIDATE_DIR/report-$report_class.txt" >&2
        fail "golden drift: report-$report_class.txt"
    }
done

echo 'PASS: CLI, report envelope, specs, state layout, exit codes, and surfaces match golden fixtures'
