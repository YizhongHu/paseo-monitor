#!/bin/sh
# paseo-monitor: stateless launchd-driven watcher for long-running work.
# POSIX sh only; see AGENTS.md for the portability and disposability contract.
set -u
PM_VERSION="v1.3.0"

# External knobs are read exactly once here. Runtime code uses PM_* only.
PM_HOME="${PASEO_MONITOR_HOME:-$HOME/.paseo-monitor}"
PM_LOG_MAX_BYTES="${PASEO_MONITOR_LOG_MAX_BYTES:-5242880}"
PM_LOCK_GRACE_SECONDS="${PASEO_MONITOR_LOCK_GRACE_SECONDS:-5}"
PM_BACKOFF_SCALE="${PASEO_MONITOR_BACKOFF_SCALE:-1}"
PM_FAST_SWEEP="${PASEO_MONITOR_FAST_SWEEP:-0}"
PM_PROBE_TIMEOUT="${PASEO_MONITOR_PROBE_TIMEOUT:-45}"
PM_CONTEXT_MAX=512
case "$PM_LOG_MAX_BYTES" in ''|*[!0-9]*) PM_LOG_MAX_BYTES=5242880 ;; esac
case "$PM_LOCK_GRACE_SECONDS" in ''|*[!0-9]*) PM_LOCK_GRACE_SECONDS=5 ;; esac
case "$PM_BACKOFF_SCALE" in ''|*[!0-9]*) PM_BACKOFF_SCALE=1 ;; esac
case "$PM_FAST_SWEEP" in 0|1) ;; *) PM_FAST_SWEEP=0 ;; esac
case "$PM_PROBE_TIMEOUT" in ''|*[!0-9]*) PM_PROBE_TIMEOUT=45 ;; esac
PM_LAUNCHD_LABEL=com.paseo-monitor.sweep
PM_INSTALLER="${PASEO_MONITOR_INSTALLER:-$(dirname "$0")/../install.sh}"
PM_RUNTIME_DIR="$(CDPATH= cd -- "$(dirname "$0")" 2>/dev/null && pwd)"
PM_PYTHON_RESOLVER="${PM_PYTHON_RESOLVER:-$PM_RUNTIME_DIR/resolve-python3}"
if [ ! -x "$PM_PYTHON_RESOLVER" ]; then
    PM_INSTALLER_DIR="$(CDPATH= cd -- "$(dirname "$PM_INSTALLER")" 2>/dev/null && pwd)"
    if [ -x "$PM_INSTALLER_DIR/bin/resolve-python3" ]; then
        PM_PYTHON_RESOLVER="$PM_INSTALLER_DIR/bin/resolve-python3"
    fi
fi
PM_PYTHON="${PASEO_MONITOR_PYTHON:-}"
if [ -z "$PM_PYTHON" ] && [ -x "$PM_PYTHON_RESOLVER" ]; then
    PM_PYTHON="$("$PM_PYTHON_RESOLVER" 2>/dev/null || printf '')"
fi
PM_PY_AGENT_PROBE='import json,sys; d=json.load(sys.stdin); status=str(d.get("Status",d.get("status","UNKNOWN"))).upper(); archived=bool(d.get("Archived",d.get("archived",False))) or bool(d.get("ArchivedAt",d.get("archivedAt",""))); perms=d.get("PendingPermissions",d.get("pendingPermissions",[])); perms=perms if isinstance(perms,list) else []; updated=d.get("UpdatedAt",d.get("updatedAt","")); token="ARCHIVED" if archived else ("BLOCKED-PERMISSION" if perms else status); prefix="went idle " if token=="IDLE" else ""; idle=(" idle_since="+str(updated)) if token=="IDLE" else ""; print("%s %sstatus=%s archived=%s pendingPermissions=%d queue_depth=%d updated_at=%s%s" % (token,prefix,status,str(archived).lower(),len(perms),len(perms),str(updated),idle))'
PM_PY_GLOBUS_PROBE="$(cat <<'PY'
import json, sys
data = json.load(sys.stdin)
status = str(data.get("status", data.get("Status", "UNKNOWN"))).upper()
def field(name):
    value = data.get(name, "")
    if value is None:
        return ""
    if isinstance(value, (dict, list)):
        return json.dumps(value, separators=(",", ":"))
    return str(value).replace("\n", " ")
print("%s nice_status=%s faults=%s fatal_error=%s effective_bytes_per_second=%s" % (
    status, field("nice_status"), field("faults"), field("fatal_error"),
    field("effective_bytes_per_second")))
PY
)"
PM_PY_HARVEST_LABELS='import json,sys; d=json.load(sys.stdin); d=d[0] if isinstance(d,list) and d else d; labels=d.get("Labels",d.get("labels",{})) if isinstance(d,dict) else {}; labels=labels if isinstance(labels,dict) else {}; print("|".join("%s=%s" % (k,str(labels[k]).replace("|"," ").replace("\n"," ")) for k in ("role","job","item","lane") if k in labels and labels[k] is not None))'
PM_PY_SCHEDULE_ID='import json,sys; d=json.load(sys.stdin); d=d if isinstance(d,dict) else {}; print(d.get("id",d.get("scheduleId",d.get("schedule_id",""))))'
PM_PY_CALLER_PROVIDER='import json,sys; d=json.load(sys.stdin); print(d.get("Provider",d.get("provider","")) if isinstance(d,dict) else "")'
PM_PY_DEFAULT_PROVIDER='import json,sys; d=json.load(sys.stdin); print(next((str(x.get("provider","")) for x in d if isinstance(x,dict) and str(x.get("status","")).lower()=="available" and str(x.get("enabled","")).lower()=="enabled"),"") if isinstance(d,list) else "")'

LC_ALL=C
export LC_ALL
umask 077

pm_kind_table() {
    printf '%s\n' \
        'slurm | Slurm job state | --host <host> --job <id> [--report-transitions] [--report-on <tokens>] [--with-reason] --deadline <when> | floor=120 | default=600 terminal-only, 300 transitions' \
        'pbs | PBS job state | --host <host> --job <id> [--report-transitions] [--report-on <tokens>] --deadline <when> | floor=120 | default=600 terminal-only, 300 transitions' \
        'globus | Globus transfer status | --task <id> --deadline <when> | floor=60 | default=300' \
        'agent | Paseo agent status | --agent <id> [--report-on <tokens>] [--dwell <sweeps>] --deadline <when> | floor=60 | default=60, dwell=2' \
        'file-exists | Absence / receipt pattern; job-id-keyed watches cannot observe a target that never entered the queue | --path <receipt-path> [--host <host>] --deadline <when> | floor=60 local, 120 remote | default=60 local, 120 remote | example: paseo-monitor watch --kind file-exists --path /scratch/run/receipt --deadline +3600' \
        'git-ref | Git ref SHA | --remote <remote> --ref <ref> --deadline <when> | floor=60 | default=120' \
        'pr-merge | Pull request merge state | --repo <owner/repo> --pr <number> --deadline <when> | floor=60 | default=300' \
        'script | Custom executable | --script <file> --reason "<why no kind fits>" --deadline <when> | floor=60 | default=60'
}

usage() {
    cat <<'EOF'
Usage: paseo-monitor <subcommand> [args]

A cheap, stateless watcher. One launchd-driven sweep observes due watches and
reports state changes; the caller owns the liveness backstop.

Subcommands:

  watch --kind <kind> [kind args] \
      [--report-to <agent>] [--interval <s>] --deadline <when> \
      [--terminal TOK,TOK] [--report-on TOK,TOK] [--report-transitions] \
      [--with-reason] [--dwell <n-sweeps>] [--label k=v ...] \
      [--provider <provider>] [--interval <s>] --deadline <when> \
      [--prohibit <text>] [--failsafe] [--max-fires <n>] \
      [--max-runs <n>] [--expires-in <duration>] [--no-start-report] \
      [--deliver paseo-queue|<command>]
  watch --script <file> --reason "<why no kind fits>" \
      --terminal TOK,TOK [same common options as --kind]
      Register a snapshotted custom probe.
  # --script requires --reason; probes are direct argv and never sh -c.
  kinds
      Print the bundled kind table.
  ls
      List live watches: kind, target, state, owner, report_to, nextDue, reason.
  status [--mine|<id>]
      Show all watches, only the caller's watches, or one watch by id.
  log <id> [-n N] [-f]
      Show a watch log, including a removed watch retained in the graveyard.
  poke <id>
      Probe now, out of band; also resumes a parked watch.
  rm <id> | --all | --all-agents
      Remove one watch, all of the caller's watches, or every watch.
      --all-agents lists every watch and owner before global removal.
  # rm reports owed active cancellations; reap remains silent.
  # --max-fires reports one exhausted event at the cap and keeps observing.
  # --failsafe example: watch ... --failsafe --expires-in 5m --max-runs 1
  # It schedules one bounded status/log check; it does not replace the probe.
  reap
      Drop watches and graveyard entries expired beyond the retention period.
  _sweep
      Run one stateless sweep; used by launchd.
  help | --help | -h
      Show this help message.
  version | --version
      Show the release version.

State layout (under PASEO_MONITOR_HOME, default ~/.paseo-monitor):
  sweep.lock/                   global mkdir lock, with lock/pid inside
  sweep.log                     sweeper events, rotated
  watches/<watch-id>/            one directory per live watch
  graveyard/<watch-id>/          removed spec, context, log, and retention data
  # The watches/<watch-id> compatibility link keeps old report citations valid.
  # Each live watch contains:
  #   spec, context, probe, last, detail, nextDue, health, state, undelivered,
  #   fires, log

Environment knobs (read once into internal PM_* variables):
  PASEO_MONITOR_HOME             State root (default: $HOME/.paseo-monitor)
  PASEO_MONITOR_LOG_MAX_BYTES    Rotate logs at this size (default: 5242880)
  PASEO_MONITOR_LOCK_GRACE_SECONDS
                                  Lock-without-pid grace window (default: 5)
  PASEO_MONITOR_BACKOFF_SCALE    Test-only backoff multiplier (default: 1)
  PASEO_MONITOR_FAST_SWEEP       Test-only fast-sweep mode (default: 0)
  PASEO_MONITOR_PROBE_TIMEOUT  Test-only hard timeout seconds (default: 45)

The external names above are never read below startup. Probes inherit the
calling environment deliberately; credentials such as SSH_AUTH_SOCK matter.
EOF
    printf '\nKind table:\n'
    pm_kind_table
}

# --- Fixed-name shell primitives copied from paseo-queue -----------------
pm_file_size() {
    stat -f %z "$1" 2>/dev/null || stat -c %s "$1" 2>/dev/null || wc -c < "$1" 2>/dev/null
}

pm_dir_mtime() {
    stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null
}

pm_log_path() {
    if [ "$1" = "$PM_HOME" ]; then
        printf '%s\n' "$PM_HOME/sweep.log"
    else
        printf '%s\n' "$1/log"
    fi
}

rotate_log_if_big() {
    # rotate_log_if_big <dir> -- one-generation rotation for sweep/watch logs.
    rlb_dir="$1"
    rlb_log="$(pm_log_path "$rlb_dir")"
    [ -f "$rlb_log" ] || return 0
    rlb_size="$(pm_file_size "$rlb_log")"
    if [ -n "$rlb_size" ] && [ "$rlb_size" -ge "$PM_LOG_MAX_BYTES" ]; then
        mv -f "$rlb_log" "$rlb_log.1" 2>/dev/null
    fi
    return 0
}

log_line() {
    # log_line <dir> <event> [detail...] -- append an operational event.
    ll_dir="$1"
    ll_event="$2"
    shift 2
    mkdir -p "$ll_dir" || return 1
    ll_log="$(pm_log_path "$ll_dir")"
    ll_ts="$(TZ=America/New_York date '+%Y-%m-%dT%H:%M:%S%z')"
    printf '%s [%s] %s %s\n' "$ll_ts" "$$" "$ll_event" "$*" >> "$ll_log" || return 1
    rotate_log_if_big "$ll_dir"
}

pm_atomic_write() {
    # pm_atomic_write <path> <content> -- install content with tmp+mv.
    paw_path="$1"
    paw_content="$2"
    paw_dir="$(dirname "$paw_path")"
    mkdir -p "$paw_dir" || return 1
    paw_tmp="$paw_dir/.tmp.$$.${paw_path##*/}"
    printf '%s\n' "$paw_content" > "$paw_tmp" || return 1
    mv -f "$paw_tmp" "$paw_path" || return 1
}

set_state() {
    # set_state <dir> <state> -- atomically install the state file.
    ss_dir="$1"
    ss_state="$2"
    pm_atomic_write "$ss_dir/state" "$ss_state" || {
        printf 'paseo-monitor: set_state failed for %s\n' "$ss_dir" >&2
        return 1
    }
}

ensure_dirs() {
    # ensure_dirs <dir> -- create the durable monitor directories.
    ed_dir="$1"
    mkdir -p "$ed_dir/watches" || return 1
    return 0
}

pm_is_full_uuid() {
    case "$1" in
        ????????-????-????-????-????????????) return 0 ;;
        *) return 1 ;;
    esac
}

PM_PY_MATCH_AGENT="$(cat <<'PY'
import json, sys
query = sys.argv[1]
try:
    data = json.load(sys.stdin)
except Exception:
    data = []
if isinstance(data, dict):
    data = data.get("agents", [])
if not isinstance(data, list):
    data = []
matched = {}
for agent in data:
    aid = agent.get("id", "")
    name = agent.get("name", "")
    if query and aid.startswith(query):
        matched[aid] = agent
    elif name == query:
        matched[aid] = agent
if len(matched) == 1:
    agent = next(iter(matched.values()))
    print("MATCH\t%s\t%s" % (agent.get("id", ""), agent.get("name", "")))
elif len(matched) == 0:
    print("NONE")
else:
    print("AMBIGUOUS\t" + "\t".join("%s (%s)" % (a.get("id", ""), a.get("name", "")) for a in matched.values()))
PY
)"

PM_PY_INSPECT_AGENT="$(cat <<'PY'
import json, sys
try:
    agent = json.load(sys.stdin)
except Exception:
    print("unknown 0 0")
    sys.exit(1)
if isinstance(agent, list):
    agent = agent[0] if agent else {}
status = agent.get("Status", agent.get("status", "unknown"))
archived = agent.get("Archived", agent.get("archived", False))
permissions = agent.get("PendingPermissions", agent.get("pendingPermissions", []))
if not isinstance(permissions, list):
    permissions = []
print("%s %s %d" % (str(status).lower(), 1 if archived else 0, len(permissions)))
PY
)"

pm_match_agent() {
    "$PM_PYTHON" -c "$PM_PY_MATCH_AGENT" "$1"
}

resolve_agent() {
    # resolve_agent <query> <allow_orphan:0|1> -- print UUID<TAB>name.
    ra_query="$1"
    ra_allow_orphan="${2:-0}"
    ra_json="$(paseo ls --json 2>/dev/null)" || {
        printf 'paseo-monitor: paseo ls --json failed (daemon unreachable?)\n' >&2
        return 3
    }
    ra_result="$(printf '%s' "$ra_json" | pm_match_agent "$ra_query")"
    ra_tag="$(printf '%s\n' "$ra_result" | cut -f1)"
    case "$ra_tag" in
        MATCH)
            printf '%s\t%s\n' "$(printf '%s\n' "$ra_result" | cut -f2)" "$(printf '%s\n' "$ra_result" | cut -f3-)"
            return 0
            ;;
        AMBIGUOUS)
            {
                printf 'paseo-monitor: ambiguous agent "%s", candidates:\n' "$ra_query"
                printf '%s\n' "$ra_result" | cut -f2- | tr '\t' '\n' | sed 's/^/  /'
            } >&2
            return 2
            ;;
        *)
            if [ "$ra_allow_orphan" = "1" ] && pm_is_full_uuid "$ra_query" && [ -d "$PM_HOME/watches/$ra_query" ]; then
                printf '%s\t\n' "$ra_query"
                return 0
            fi
            printf 'paseo-monitor: no agent matches "%s"\n' "$ra_query" >&2
            return 2
            ;;
    esac
}

inspect_agent() {
    # inspect_agent <uuid> -- print status archived pending-permission-count.
    ia_json="$(paseo inspect "$1" --json 2>/dev/null)" || return 1
    [ -n "$ia_json" ] || return 1
    printf '%s' "$ia_json" | "$PM_PYTHON" -c "$PM_PY_INSPECT_AGENT"
}

lock_holder_alive() {
    # lock_holder_alive <dir> -- liveness by pid plus process identity.
    lha_lockdir="$1/sweep.lock"
    [ -d "$lha_lockdir" ] || return 1
    if [ -f "$lha_lockdir/pid" ]; then
        lha_pid="$(cat "$lha_lockdir/pid" 2>/dev/null)"
        case "$lha_pid" in ''|*[!0-9]*) return 1 ;; esac
        if kill -0 "$lha_pid" 2>/dev/null &&
            ps -p "$lha_pid" -o command= 2>/dev/null | grep -q 'paseo-monitor'; then
            return 0
        fi
        return 1
    fi
    lha_now="$(date +%s)"
    lha_mtime="$(pm_dir_mtime "$lha_lockdir")"
    if [ -n "$lha_mtime" ] && [ $((lha_now - lha_mtime)) -lt "$PM_LOCK_GRACE_SECONDS" ]; then
        return 0
    fi
    return 1
}

break_stale_lock() {
    bsl_dir="$1"
    bsl_stale="$bsl_dir/sweep.lock.stale.$$"
    if mv "$bsl_dir/sweep.lock" "$bsl_stale" 2>/dev/null; then
        rm -rf "$bsl_stale" 2>/dev/null
    fi
    return 0
}

acquire_lock() {
    # acquire_lock <dir> -- mkdir-based exclusive global sweep lock.
    al_dir="$1"
    mkdir -p "$al_dir" || return 1
    if mkdir "$al_dir/sweep.lock" 2>/dev/null; then
        printf '%s\n' "$$" > "$al_dir/sweep.lock/pid"
        return 0
    fi
    lock_holder_alive "$al_dir" && return 1
    break_stale_lock "$al_dir"
    if mkdir "$al_dir/sweep.lock" 2>/dev/null; then
        printf '%s\n' "$$" > "$al_dir/sweep.lock/pid"
        return 0
    fi
    return 1
}

release_lock() {
    rl_dir="$1"
    [ -d "$rl_dir/sweep.lock" ] || return 0
    [ -f "$rl_dir/sweep.lock/pid" ] || return 1
    [ "$(cat "$rl_dir/sweep.lock/pid" 2>/dev/null)" = "$$" ] || return 1
    rm -rf "$rl_dir/sweep.lock" 2>/dev/null
}

pm_init_state() {
    mkdir -p "$PM_HOME/watches" "$PM_HOME/graveyard" || {
        printf 'paseo-monitor: cannot create state root: %s\n' "$PM_HOME" >&2
        return 1
    }
}

pm_is_graveyard() {
    [ -f "$1/graveyard" ]
}

pm_watch_owner() {
    pwo_dir="$1"
    pwo_owner="$(pm_spec_value owner "$pwo_dir/spec" 2>/dev/null || printf '')"
    [ -n "$pwo_owner" ] && printf '%s\n' "$pwo_owner" || printf '(unrecorded)\n'
}

pm_watch_source() {
    # pm_watch_source <id> -- print live or graveyard directory.
    pws_id="$1"
    pws_live="$PM_HOME/watches/$pws_id"
    if [ -f "$pws_live/graveyard" ]; then
        printf '%s\n' "$PM_HOME/graveyard/$pws_id"
    elif [ -f "$pws_live/spec" ]; then
        printf '%s\n' "$pws_live"
    elif [ -f "$PM_HOME/graveyard/$pws_id/spec" ]; then
        printf '%s\n' "$PM_HOME/graveyard/$pws_id"
    else
        return 1
    fi
}

pm_watch_owner_key() {
    pwok_dir="$1"
    printf '%s\n' "$(pm_spec_value owner "$pwok_dir/spec" 2>/dev/null || printf '')"
}

PM_PROBE_TIMEOUT=45
PM_SWEEP_PARALLELISM=4
PM_DEFAULT_TERMINAL="COMPLETED,SUCCEEDED,FAILED,CANCELLED,TIMEOUT,ERROR,CLOSED,ARCHIVED,DONE"
pm_now() {
    date +%s
}

pm_sweep_beacon() {
    psb_now="$(pm_now)"
    psb_stamp="$(TZ=America/New_York date '+%Y-%m-%dT%H:%M:%S%z')"
    pm_atomic_write "$PM_HOME/sweep.beacon" "$psb_now $psb_stamp"
}
 
pm_trigger_plist() {
    printf '%s\n' "$HOME/Library/LaunchAgents/$PM_LAUNCHD_LABEL.plist"
}

pm_trigger_is_fresh() {
    pti_plist="$(pm_trigger_plist)"
    [ -f "$pti_plist" ] || return 1
    grep -q 'paseo-monitor: managed launchd agent' "$pti_plist" || return 1
    command -v launchctl >/dev/null 2>&1 || return 1
    launchctl print "gui/$(id -u)/$PM_LAUNCHD_LABEL" >/dev/null 2>&1
}

pm_trigger_state() {
    pt_state_plist="$(pm_trigger_plist)"
    [ -f "$pt_state_plist" ] || {
        printf 'not-installed\n'
        return 0
    }
    pm_trigger_is_fresh && printf 'fresh\n' || printf 'stale\n'
}

pm_self_heal_trigger() {
    pti_plist="$(pm_trigger_plist)"
    [ -f "$pti_plist" ] || return 0
    pm_trigger_is_fresh && return 0
    pti_installer="$PM_INSTALLER"
    if [ ! -f "$pti_installer" ]; then
        pti_repo="$(sed -n '/<key>WorkingDirectory<\/key>/{n;s/^[[:space:]]*<string>\(.*\)<\/string>$/\1/p;}' "$pti_plist")"
        pti_installer="$pti_repo/install.sh"
    fi
    [ -f "$pti_installer" ] || return 1
    sh "$pti_installer" install >/dev/null 2>&1
}
pm_spec_value() {
    psv_key="$1"
    psv_file="$2"
    sed -n "s/^${psv_key}=//p" "$psv_file" | sed -n '1p'
}
 
pm_valid_uint() {
    case "$1" in ''|*[!0-9]*) return 1 ;; esac
    return 0
}
 
pm_hash_jitter() {
    phj_id="$1"
    phj_interval="$2"
    [ "$PM_FAST_SWEEP" = 1 ] && {
        printf '0\n'
        return 0
    }
    phj_hash="$(printf '%s\n' "$phj_id" | cksum | cut -d ' ' -f1)"
    printf '%s\n' "$((phj_hash % phj_interval))"
}
 
pm_next_due() {
    pnd_now="$1"
    pnd_interval="$2"
    pnd_id="$3"
    pnd_jitter="$(pm_hash_jitter "$pnd_id" "$pnd_interval")"
    if [ "$PM_FAST_SWEEP" = 1 ]; then
        printf '%s\n' "$pnd_now"
    else
        printf '%s\n' "$((pnd_now + pnd_interval + pnd_jitter))"
    fi
}
 
pm_run_with_timeout() {
    # pm_run_with_timeout <seconds> <stdout> <stderr> <argv...>
    [ "$#" -ge 4 ] || return 2
    pmt_seconds="$1"
    pmt_out="$2"
    pmt_err="$3"
    shift 3
    pm_valid_uint "$pmt_seconds" || return 2
    pmt_base="${pmt_out}.$$"
    pmt_out_pipe="${pmt_base}.out.pipe"
    pmt_err_pipe="${pmt_base}.err.pipe"
    pmt_timeout_marker="${pmt_base}.timed-out"
    rm -f "$pmt_out_pipe" "$pmt_err_pipe" "$pmt_timeout_marker"
    mkfifo "$pmt_out_pipe" "$pmt_err_pipe" || return 2
    (
        dd bs=1 count=4096 2>/dev/null
        cat >/dev/null
    ) <"$pmt_out_pipe" >"$pmt_out" &
    pmt_out_cap=$!
    (
        dd bs=1 count=8192 2>/dev/null
        cat >/dev/null
    ) <"$pmt_err_pipe" >"$pmt_err" &
    pmt_err_cap=$!
    "$@" </dev/null >"$pmt_out_pipe" 2>"$pmt_err_pipe" &
    pmt_child=$!
    (
        sleep "$pmt_seconds" &
        pmt_sleep_pid=$!
        trap 'kill "$pmt_sleep_pid" 2>/dev/null; exit 0' 0 1 2 3 15
        wait "$pmt_sleep_pid"
        trap - 0 1 2 3 15
        if kill -0 "$pmt_child" 2>/dev/null; then
            : > "$pmt_timeout_marker"
            kill "$pmt_child" 2>/dev/null
        fi
    ) &
    pmt_killer=$!
    wait "$pmt_child" 2>/dev/null
    pmt_rc=$?
    if [ -f "$pmt_timeout_marker" ]; then
        kill "$pmt_out_cap" "$pmt_err_cap" 2>/dev/null
        wait "$pmt_out_cap" 2>/dev/null
        wait "$pmt_err_cap" 2>/dev/null
        kill "$pmt_killer" 2>/dev/null
        wait "$pmt_killer" 2>/dev/null
        rm -f "$pmt_out_pipe" "$pmt_err_pipe" "$pmt_timeout_marker"
        return 124
    fi
    kill "$pmt_killer" 2>/dev/null
    wait "$pmt_killer" 2>/dev/null
    wait "$pmt_out_cap" 2>/dev/null
    wait "$pmt_err_cap" 2>/dev/null
    rm -f "$pmt_out_pipe" "$pmt_err_pipe"
    return "$pmt_rc"
}
 
pm_remote_shell_quote() {
    # pm_remote_shell_quote <value> -- quote one value for an SSH remote shell.
    printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

pm_run_remote_probe() {
    # pm_run_remote_probe <stdout> <stderr> <host> <remote argv...>.
    # Normalize ssh-level rc=255 while preserving the existing health path.
    prr_out="$1"
    prr_err="$2"
    prr_host="$3"
    shift 3
    pm_run_with_timeout "$PM_PROBE_TIMEOUT" "$prr_out" "$prr_err" \
        ssh -o BatchMode=yes -o ConnectTimeout=15 "$prr_host" "$@"
    prr_rc=$?
    if [ "$prr_rc" -eq 255 ]; then
        prr_err_text="$(cat "$prr_err" 2>/dev/null || printf '')"
        prr_class="$(pm_health_failure_class "$prr_rc" "$prr_err_text")"
        {
            printf '%s-class ssh-rc=255\n' "$prr_class"
            [ -n "$prr_err_text" ] && printf '%s\n' "$prr_err_text"
        } > "$prr_err.classified.$$"
        mv -f "$prr_err.classified.$$" "$prr_err"
    fi
    return "$prr_rc"
}

pm_slurm_probe_output() {
    # pm_slurm_probe_output <watch-dir> <stdout> -- map sacct/squeue artifacts.
    pspo_dir="$1"
    pspo_out="$2"
    pspo_sacct="$(sed '/^PASEO_MONITOR_SQUEUE$/,$d' "$pspo_out" | sed '/^[[:space:]]*$/d' | sed -n '1p')"
    pspo_squeue=""
    pspo_has_squeue=0
    grep -q '^PASEO_MONITOR_SQUEUE$' "$pspo_out" && pspo_has_squeue=1
    if grep -q '^PASEO_MONITOR_SQUEUE$' "$pspo_out"; then
        pspo_squeue="$(sed -n '/^PASEO_MONITOR_SQUEUE$/,$p' "$pspo_out" | sed '1d' | sed '/^[[:space:]]*$/d' | sed -n '1p')"
    fi
    pspo_state="$pspo_sacct"
    if [ -z "$pspo_state" ] && [ -n "$pspo_squeue" ]; then
        pspo_state="${pspo_squeue%%|*}"
    fi
    case "$pspo_state" in
        *'|'*) pspo_state="${pspo_state#*|}"; pspo_state="${pspo_state%%|*}" ;;
    esac
    pspo_state="${pspo_state%% *}"
    if [ -n "$pspo_state" ]; then
        pspo_token="$pspo_state"
        pspo_detail="sacct=$pspo_sacct"
        if [ -n "$pspo_squeue" ]; then
            pspo_sq_state="${pspo_squeue%%|*}"
            pspo_sq_reason="${pspo_squeue#*|}"
            if [ "$pspo_sq_state" = "$pspo_squeue" ]; then pspo_sq_reason="" ; fi
            if [ "$pspo_sq_state" = PENDING ] && [ -n "$pspo_sq_reason" ]; then
                pspo_token="PENDING:$pspo_sq_reason"
            fi
            pspo_detail="$pspo_detail squeue=$pspo_squeue"
        fi
    elif [ "$pspo_has_squeue" -eq 1 ] &&
        [ -n "$(cat "$pspo_dir/last" 2>/dev/null || printf '')" ] &&
        [ "$(cat "$pspo_dir/last" 2>/dev/null || printf '')" != PENDING ]; then
        pspo_token=VANISHED
        pspo_detail="sacct and squeue empty after last=$(cat "$pspo_dir/last")"
    else
        pspo_token=PENDING
        pspo_detail="sacct empty (accounting lag); squeue=$pspo_squeue"
    fi
    printf '%s %s\n' "$pspo_token" "$pspo_detail" > "$pspo_out"
}

pm_pbs_probe_output() {
    # pm_pbs_probe_output <watch-dir> <stdout> -- map qstat live/history artifacts.
    pppo_dir="$1"
    pppo_out="$2"
    pppo_live="$pppo_out"
    pppo_history=""
    if grep -q '^PASEO_MONITOR_PBS_HISTORICAL$' "$pppo_out"; then
        pppo_live="$pppo_out.live.$$"
        pppo_history="$pppo_out.history.$$"
        sed '/^PASEO_MONITOR_PBS_HISTORICAL$/,$d' "$pppo_out" > "$pppo_live"
        sed -n '/^PASEO_MONITOR_PBS_HISTORICAL$/,$p' "$pppo_out" | sed '1d' > "$pppo_history"
    fi
    pppo_state="$(sed -n 's/^[[:space:]]*job_state[[:space:]]*=[[:space:]]*//p' "$pppo_live" | sed -n '1p')"
    pppo_source=qstat
    pppo_record="$pppo_live"
    if [ -z "$pppo_state" ] && [ -n "$pppo_history" ]; then
        pppo_state="$(sed -n 's/^[[:space:]]*job_state[[:space:]]*=[[:space:]]*//p' "$pppo_history" | sed -n '1p')"
        pppo_source=qstat-x
        pppo_record="$pppo_history"
    fi
    pppo_state="${pppo_state%% *}"
    pppo_state="$(printf '%s\n' "$pppo_state" | tr 'a-z' 'A-Z')"
    if [ -n "$pppo_state" ]; then
        pppo_raw="$(tr '\n' ' ' < "$pppo_record" | cut -c1-384)"
        printf '%s %s=%s\n' "$pppo_state" "$pppo_source" "$pppo_raw" > "$pppo_out"
    else
        printf 'UNKNOWN qstat live and historical lookup empty\n' > "$pppo_out"
    fi
    [ "$pppo_live" = "$pppo_out" ] || rm -f "$pppo_live" "$pppo_history"
}
pm_git_ref_probe_output() {
    # pm_git_ref_probe_output <watch-dir> <stdout> -- extract the observed SHA.
    pgr_dir="$1"
    pgr_out="$2"
    pgr_line="$(sed -n '1p' "$pgr_out")"
    pgr_sha="$(printf '%s\n' "$pgr_line" | cut -f1)"
    pgr_ref="$(printf '%s\n' "$pgr_line" | cut -f2)"
    case "$pgr_sha" in
        ''|*[!0-9A-Fa-f]*) return 1 ;;
    esac
    pgr_old="$(cat "$pgr_dir/last" 2>/dev/null || printf '')"
    [ -n "$pgr_old" ] || pgr_old="$pgr_sha"
    printf '%s old=%s new=%s ref=%s observed=%s\n' \
        "$pgr_sha" "$pgr_old" "$pgr_sha" "$pgr_ref" "$pgr_line" > "$pgr_out"
}
 
pm_parse_probe_output() {
    ppo_line="$(sed -n '1p' "$1")"
    [ -n "$ppo_line" ] || return 1
    ppo_token="${ppo_line%% *}"
    [ -n "$ppo_token" ] || return 1
    ppo_detail="${ppo_line#"$ppo_token"}"
    ppo_detail="${ppo_detail# }"
    PM_PARSED_TOKEN="$ppo_token"
    PM_PARSED_DETAIL="$ppo_detail"
    return 0
}
pm_resolve_binary() {
    # pm_resolve_binary <name> -- resolve one executable to an absolute path.
    prb_name="$1"
    if [ "$prb_name" = python3 ]; then
        [ -n "$PM_PYTHON" ] || {
            [ -x "$PM_PYTHON_RESOLVER" ] || return 1
            PM_PYTHON="$("$PM_PYTHON_RESOLVER" 2>/dev/null || printf '')"
        }
        [ -n "$PM_PYTHON" ] || return 1
        PM_RESOLVED_BINARY="$PM_PYTHON"
        return 0
    fi
    case "$prb_name" in
        /*)
            [ -x "$prb_name" ] || {
                printf 'paseo-monitor: required helper not found: %s\n' "$prb_name" >&2
                return 1
            }
            PM_RESOLVED_BINARY="$prb_name"
            return 0
            ;;
        */*)
            [ -x "$prb_name" ] || {
                printf 'paseo-monitor: required helper not found: %s\n' "$prb_name" >&2
                return 1
            }
            prb_dir="${prb_name%/*}"
            prb_base="${prb_name##*/}"
            prb_abs_dir="$(CDPATH= cd -P -- "$prb_dir" 2>/dev/null && pwd)" || return 1
            PM_RESOLVED_BINARY="$prb_abs_dir/$prb_base"
            return 0
            ;;
    esac
    prb_old_ifs="$IFS"
    IFS=:
    for prb_dir in ${PATH:-}; do
        [ -n "$prb_dir" ] || prb_dir=.
        [ -x "$prb_dir/$prb_name" ] || continue
        case "$prb_dir" in
            /*) PM_RESOLVED_BINARY="$prb_dir/$prb_name" ;;
            *) prb_abs_dir="$(CDPATH= cd -P -- "$prb_dir" 2>/dev/null && pwd)" || continue
                PM_RESOLVED_BINARY="$prb_abs_dir/$prb_name" ;;
        esac
        IFS="$prb_old_ifs"
        return 0
    done
    IFS="$prb_old_ifs"
    printf 'paseo-monitor: required helper not found: %s\n' "$prb_name" >&2
    return 1
}

pm_kind_helper() {
    # pm_kind_helper <kind> -- resolve helpers required by a bundled kind.
    pkh_kind="$1"
    case "$pkh_kind" in
        agent) pm_resolve_binary paseo ;;
        globus) pm_resolve_binary globus ;;
        pr-merge) pm_resolve_binary gh ;;
        *) PM_RESOLVED_BINARY="" ;;
    esac
}

pm_spec_backfill() {
    # pm_spec_backfill <dir> <key> <value> -- add or replace one spec key in place.
    psb_dir="$1"
    psb_key="$2"
    psb_val="$3"
    [ -f "$psb_dir/spec" ] || return 1
    psb_new="$(awk -v k="$psb_key" -v v="$psb_val" '
        index($0, k "=") == 1 { print k "=" v; found = 1; next }
        { print }
        END { if (!found) print k "=" v }
    ' "$psb_dir/spec")" || return 1
    pm_atomic_write "$psb_dir/spec" "$psb_new"
}


pm_agent_dwell_accept() {
    # pm_agent_dwell_accept <watch-dir> <token> -- return 1 while candidate is dwelling.
    pada_dir="$1"
    pada_token="$2"
    pada_dwell="$(pm_spec_value dwell "$pada_dir/spec")"
    case "$pada_token" in IDLE|RUNNING) ;; *) rm -f "$pada_dir/dwell"; return 0 ;; esac
    pm_valid_uint "$pada_dwell" || pada_dwell=0
    [ "$pada_dwell" -gt 1 ] || {
        rm -f "$pada_dir/dwell"
        return 0
    }
    pada_old="$(cat "$pada_dir/last" 2>/dev/null || printf '')"
    [ "$pada_token" != "$pada_old" ] || {
        rm -f "$pada_dir/dwell"
        return 0
    }
    pada_saved="$(cat "$pada_dir/dwell" 2>/dev/null || printf '')"
    pada_saved_token="${pada_saved%% *}"
    pada_saved_count="${pada_saved#* }"
    pm_valid_uint "$pada_saved_count" || pada_saved_count=0
    if [ "$pada_saved_token" = "$pada_token" ]; then
        pada_count=$((pada_saved_count + 1))
    else
        pada_count=1
    fi
    if [ "$pada_count" -lt "$pada_dwell" ]; then
        pm_atomic_write "$pada_dir/dwell" "$pada_token $pada_count" || :
        log_line "$pada_dir" DWELL "$pada_token count=$pada_count/$pada_dwell" || :
        return 1
    fi
    rm -f "$pada_dir/dwell"
    return 0
}
 
pm_run_registered_probe() {
    prp_dir="$1"
    prp_out="$2"
    prp_err="$3"
    prp_kind="$(pm_spec_value kind "$prp_dir/spec")"
    prp_host="$(pm_spec_value host "$prp_dir/spec")"
    prp_job="$(pm_spec_value job "$prp_dir/spec")"
    prp_task="$(pm_spec_value task "$prp_dir/spec")"
    prp_agent="$(pm_spec_value agent "$prp_dir/spec")"
    prp_path="$(pm_spec_value path "$prp_dir/spec")"
    prp_remote="$(pm_spec_value remote "$prp_dir/spec")"
    prp_ref="$(pm_spec_value ref "$prp_dir/spec")"
    prp_repo="$(pm_spec_value repo "$prp_dir/spec")"
    prp_pr="$(pm_spec_value pr "$prp_dir/spec")"
    prp_with_reason="$(pm_spec_value with_reason "$prp_dir/spec")"
    prp_helper="$(pm_spec_value helper "$prp_dir/spec")"
    prp_python="$(pm_spec_value python "$prp_dir/spec")"
    # Watches registered before helper snapshotting carry no helper=/python= in
    # their spec. Resolve once from the current environment and back-fill, so a
    # pre-existing watch recovers instead of exec'ing an empty string (rc 127)
    # on every sweep forever. Newly registered watches never reach this path.
    if [ -z "$prp_helper" ]; then
        pm_kind_helper "$prp_kind" || return 127
        prp_helper="$PM_RESOLVED_BINARY"
        [ -z "$prp_helper" ] || pm_spec_backfill "$prp_dir" helper "$prp_helper" || :
    fi
    if [ -z "$prp_python" ] && pm_resolve_binary python3 2>/dev/null; then
        prp_python="$PM_RESOLVED_BINARY"
        pm_spec_backfill "$prp_dir" python "$prp_python" || :
    fi
    case "$prp_kind" in
        script)
            pm_run_with_timeout "$PM_PROBE_TIMEOUT" "$prp_out" "$prp_err" "$prp_dir/probe"
            ;;
        slurm)
            if [ "$prp_with_reason" = 1 ]; then
                prp_job_q="$(pm_remote_shell_quote "$prp_job")"
                prp_slurm_cmd="sacct -X -j $prp_job_q --parsable2 --noheader --format=State; prp_sacct_rc=\$?; printf '\\nPASEO_MONITOR_SQUEUE\\n'; squeue -h -j $prp_job_q -o '%T|%R'; prp_squeue_rc=\$?; [ \$prp_sacct_rc -eq 0 ] && [ \$prp_squeue_rc -eq 0 ]"
                pm_run_remote_probe "$prp_out" "$prp_err" "$prp_host" "$prp_slurm_cmd"
                prp_rc=$?
                [ "$prp_rc" -eq 0 ] || return "$prp_rc"
                pm_slurm_probe_output "$prp_dir" "$prp_out"
                return 0
            fi
            pm_run_remote_probe "$prp_out" "$prp_err" "$prp_host" \
                sacct -X -j "$prp_job" --parsable2 --noheader --format=State
            prp_rc=$?
            [ "$prp_rc" -eq 0 ] || return "$prp_rc"
            pm_slurm_probe_output "$prp_dir" "$prp_out"
            return 0
            ;;
        pbs)
            prp_job_q="$(pm_remote_shell_quote "$prp_job")"
            prp_pbs_cmd="qstat -f $prp_job_q || { printf '\\nPASEO_MONITOR_PBS_HISTORICAL\\n'; qstat -x -f $prp_job_q; :; }"
            pm_run_remote_probe "$prp_out" "$prp_err" "$prp_host" \
                "$prp_pbs_cmd"
            prp_rc=$?
            [ "$prp_rc" -eq 0 ] || return "$prp_rc"
            pm_pbs_probe_output "$prp_dir" "$prp_out"
            return $?
            ;;
        globus)
            pm_run_with_timeout "$PM_PROBE_TIMEOUT" "$prp_out" "$prp_err" \
                "$prp_helper" task show "$prp_task" -F json --jq '{status: .status, nice_status: .nice_status, faults: .faults, fatal_error: .fatal_error, effective_bytes_per_second: .effective_bytes_per_second}'
            prp_rc=$?
            [ "$prp_rc" -eq 0 ] || return "$prp_rc"
            prp_globus_line="$("$prp_python" -c "$PM_PY_GLOBUS_PROBE" < "$prp_out" 2>>"$prp_err")" || return 1
            printf '%s\n' "$prp_globus_line" > "$prp_out"
            return 0
            ;;
        agent)
            pm_run_with_timeout "$PM_PROBE_TIMEOUT" "$prp_out" "$prp_err" \
                "$prp_helper" inspect "$prp_agent" --json
            prp_rc=$?
            [ "$prp_rc" -eq 0 ] || return "$prp_rc"
            prp_agent_line="$("$prp_python" -c "$PM_PY_AGENT_PROBE" < "$prp_out" 2>>"$prp_err")" || return 1
            printf '%s\n' "$prp_agent_line" > "$prp_out"
            return 0
            ;;
        file-exists)
            if [ -n "$prp_host" ]; then
                pm_run_remote_probe "$prp_out" "$prp_err" "$prp_host" \
                    ls -d "$prp_path"
            else
                pm_run_with_timeout "$PM_PROBE_TIMEOUT" "$prp_out" "$prp_err" \
                    ls -d "$prp_path"
            fi
            prp_rc=$?
            if [ "$prp_rc" -eq 0 ]; then
                prp_file_detail="$(sed -n '1p' "$prp_out")"
                printf 'EXISTS %s\n' "$prp_file_detail" > "$prp_out"
                return 0
            fi
            [ -n "$prp_host" ] && [ "$prp_rc" -eq 255 ] && return "$prp_rc"
            printf 'ABSENT %s\n' "$prp_path" > "$prp_out"
            return 0
            ;;
        git-ref)
            pm_run_with_timeout "$PM_PROBE_TIMEOUT" "$prp_out" "$prp_err" \
                git ls-remote "$prp_remote" "$prp_ref"
            prp_rc=$?
            [ "$prp_rc" -eq 0 ] || return "$prp_rc"
            pm_git_ref_probe_output "$prp_dir" "$prp_out"
            return $?
            ;;
        pr-merge)
            pm_run_with_timeout "$PM_PROBE_TIMEOUT" "$prp_out" "$prp_err" \
                "$prp_helper" pr view "$prp_pr" --repo "$prp_repo" --json state --jq .state
            ;;
        *)
            return 127
            ;;
    esac
}
 
pm_terminal_token() {
    ptt_token="$1"
    ptt_list="$2"
    pm_match_csv "$ptt_token" "$ptt_list"
}
 
pm_match_csv() {
    pmc_token="$1"
    pmc_list="$2"
    pmc_old_ifs="$IFS"
    IFS=','
    for pmc_item in $pmc_list; do
        [ "$pmc_item" = "$pmc_token" ] && {
            IFS="$pmc_old_ifs"
            return 0
        }
    done
    IFS="$pmc_old_ifs"
    return 1
}
 
pm_deliver() {
    # pm_deliver <watch-dir> <report> -- one optional push backend.
    pmd_dir="$1"
    pmd_report="$2"
    pmd_backend="$(pm_spec_value deliver "$pmd_dir/spec")"
    [ -n "$pmd_backend" ] || return 0
    pmd_mode="$(pm_spec_value deliver_mode "$pmd_dir/spec")"
    pmd_err="$pmd_dir/.delivery.stderr"
    rm -f "$pmd_err"
    if [ "$pmd_mode" = queue ] || [ "$pmd_backend" = paseo-queue ]; then
        pmd_agent="$(pm_spec_value report_to "$pmd_dir/spec")"
        if [ -z "$pmd_agent" ]; then
            printf 'paseo-monitor: WARN delivery-failed watch=%s backend=%s\n' \
                "$(basename "$pmd_dir")" "$pmd_backend" >&2
            printf 'delivery backend requires report_to\n' > "$pmd_err"
            return 1
        fi
        printf '%s\n' "$pmd_report" | "$pmd_backend" add "$pmd_agent" 2>"$pmd_err"
        pmd_rc=$?
    else
        printf '%s\n' "$pmd_report" | "$pmd_backend" 2>"$pmd_err"
        pmd_rc=$?
    fi
    if [ "$pmd_rc" -ne 0 ]; then
        pmd_err_text="$(dd bs=1 count=8192 < "$pmd_err" 2>/dev/null || printf '')"
        printf '%s' "$pmd_err_text" > "$pmd_err"
        printf 'paseo-monitor: WARN delivery-failed watch=%s backend=%s rc=%s\n' \
            "$(basename "$pmd_dir")" "$pmd_backend" "$pmd_rc" >&2
        [ -n "$pmd_err_text" ] && printf '%s\n' "$pmd_err_text" >&2
        return "$pmd_rc"
    fi
    rm -f "$pmd_err"
    return 0
}

pm_harvest_labels() {
    # pm_harvest_labels -- copy labels exposed by Paseo, then env fallbacks.
    phl_labels=""
    if [ -n "${PASEO_AGENT_ID:-}" ] && command -v paseo >/dev/null 2>&1; then
        phl_json="$(paseo inspect "$PASEO_AGENT_ID" --json 2>/dev/null || printf '')"
        [ -n "$phl_json" ] && phl_labels="$(printf '%s' "$phl_json" | "$PM_PYTHON" -c "$PM_PY_HARVEST_LABELS" 2>/dev/null || printf '')"
    fi
    [ -n "$phl_labels" ] || phl_labels="${PASEO_LABELS:-}"
    [ -n "${PASEO_LABEL_ROLE:-}" ] && phl_labels="${phl_labels}${phl_labels:+|}role=$PASEO_LABEL_ROLE"
    [ -n "${PASEO_LABEL_JOB:-}" ] && phl_labels="${phl_labels}${phl_labels:+|}job=$PASEO_LABEL_JOB"
    [ -n "${PASEO_LABEL_ITEM:-}" ] && phl_labels="${phl_labels}${phl_labels:+|}item=$PASEO_LABEL_ITEM"
    [ -n "${PASEO_LABEL_LANE:-}" ] && phl_labels="${phl_labels}${phl_labels:+|}lane=$PASEO_LABEL_LANE"
    printf '%s\n' "$phl_labels"
}

pm_paseo_bin() {
    # pm_paseo_bin <watch-dir> -- absolute `paseo`, snapshotted like every other
    # helper. The sweeper's PATH is not the caller's, so a bare name here fails
    # rc=127 under launchd exactly as the agent probe once did.
    ppb_dir="$1"
    PM_PASEO_BIN="$(pm_spec_value paseo_bin "$ppb_dir/spec" 2>/dev/null || printf '')"
    [ -n "$PM_PASEO_BIN" ] && return 0
    pm_resolve_binary paseo 2>/dev/null || return 1
    PM_PASEO_BIN="$PM_RESOLVED_BINARY"
    pm_spec_backfill "$ppb_dir" paseo_bin "$PM_PASEO_BIN" || :
    return 0
}

pm_discover_provider() {
    pdp_provider=""
    pm_resolve_binary paseo 2>/dev/null || return 1
    pdp_paseo="$PM_RESOLVED_BINARY"
    if [ -n "${PASEO_AGENT_ID:-}" ]; then
        pdp_json="$("$pdp_paseo" inspect "$PASEO_AGENT_ID" --json 2>/dev/null || printf '')"
        [ -n "$pdp_json" ] && pdp_provider="$(printf '%s' "$pdp_json" | "$PM_PYTHON" -c "$PM_PY_CALLER_PROVIDER" 2>/dev/null || printf '')"
    fi
    if [ -z "$pdp_provider" ]; then
        pdp_json="$("$pdp_paseo" provider ls --json 2>/dev/null || printf '')"
        [ -n "$pdp_json" ] && pdp_provider="$(printf '%s' "$pdp_json" | "$PM_PYTHON" -c "$PM_PY_DEFAULT_PROVIDER" 2>/dev/null || printf '')"
    fi
    [ -n "$pdp_provider" ] || return 1
    printf '%s\n' "$pdp_provider"
}

pm_schedule_create() {
    # pm_schedule_create <watch-dir> <every> <max-runs> <expires-in> <prompt> <provider>.
    psc_dir="$1"
    psc_every="$2"
    psc_max_runs="$3"
    psc_expires="$4"
    psc_prompt="$5"
    psc_provider="$6"
    [ -n "$psc_provider" ] || {
        PM_SCHEDULE_ERROR=PROVIDER_UNAVAILABLE
        return 2
    }
    PM_SCHEDULE_ERROR=""
    psc_out="$psc_dir/.failsafe.stdout"
    psc_err="$psc_dir/.failsafe.stderr"
    pm_paseo_bin "$psc_dir" || {
        PM_SCHEDULE_ERROR=HELPER_NOT_FOUND
        printf 'paseo-monitor: required helper not found: paseo (--failsafe)\n' >&2
        return 127
    }
    pm_run_with_timeout "$PM_PROBE_TIMEOUT" "$psc_out" "$psc_err" \
        "$PM_PASEO_BIN" schedule create "$psc_prompt" --every "$psc_every" \
        --max-runs "$psc_max_runs" --expires-in "$psc_expires" \
        --provider "$psc_provider" --json
    psc_rc=$?
    if [ "$psc_rc" -ne 0 ]; then
        PM_SCHEDULE_ERROR="$(sed -n 's/.*\(MISSING_PROVIDER\).*/\1/p' "$psc_err" 2>/dev/null | sed -n '1p')"
        [ -n "$PM_SCHEDULE_ERROR" ] || PM_SCHEDULE_ERROR=SCHEDULE_CREATE_FAILED
        [ -s "$psc_err" ] && cat "$psc_err" >&2
        rm -f "$psc_out" "$psc_err"
        return "$psc_rc"
    fi
    psc_id="$("$PM_PYTHON" -c "$PM_PY_SCHEDULE_ID" < "$psc_out" 2>/dev/null || printf '')"
    case "$psc_id" in
        ''|*[!A-Za-z0-9._:-]*) psc_id="$(sed -n 's/.*\"id\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p' "$psc_out" | sed -n '1p')" ;;
    esac
    rm -f "$psc_out" "$psc_err"
    [ -n "$psc_id" ] || return 1
    pm_atomic_write "$psc_dir/failsafe" "$psc_id" || return 1
    log_line "$psc_dir" FAILSAFE-CREATED "schedule=$psc_id every=$psc_every max-runs=$psc_max_runs expires-in=$psc_expires" || :
    return 0
}

pm_clear_failsafe() {
    # pm_clear_failsafe <watch-dir> -- remove the daemon schedule after delivery.
    pcf_dir="$1"
    [ -f "$pcf_dir/failsafe" ] || return 0
    pcf_id="$(cat "$pcf_dir/failsafe" 2>/dev/null || printf '')"
    [ -n "$pcf_id" ] || return 0
    pm_paseo_bin "$pcf_dir" || {
        log_line "$pcf_dir" FAILSAFE-DELETE-FAILED "schedule=$pcf_id paseo not resolvable" || :
        return 0
    }
    if "$PM_PASEO_BIN" schedule delete "$pcf_id" >/dev/null 2>&1; then
        rm -f "$pcf_dir/failsafe"
        log_line "$pcf_dir" FAILSAFE-DELETED "schedule=$pcf_id" || :
    else
        log_line "$pcf_dir" FAILSAFE-DELETE-FAILED "schedule=$pcf_id" || :
    fi
    return 0
}

pm_report_value() {
    # pm_report_value <value> <bytes> -- cap untrusted envelope fields.
    printf '%s' "$1" | tr '\n' ' ' | cut -c1-"$2"
}

pm_report_context() {
    # pm_report_context <value> <chars> -- retain complete semicolon fields.
    prc_value="$(printf '%s' "$1" | tr '\n' ' ')"
    printf '%s' "$prc_value" | awk -v limit="$2" '
        BEGIN { RS = ""; ORS = "" }
        {
            total = length($0)
            if (total <= limit) {
                printf "%s", $0
                exit
            }
            prefix = ""
            field_count = split($0, fields, ";")
            for (i = 1; i <= field_count; i++) {
                candidate = fields[i]
                if (i > 1) candidate = prefix ";" fields[i]
                omitted = total - length(candidate)
                marker = "<...truncated " omitted " chars>"
                if (length(candidate) + length(marker) <= limit)
                    prefix = candidate
                else
                    break
            }
            printf "%s<...truncated %d chars>", prefix, total - length(prefix)
        }'
}

pm_report_envelope() {
    # pm_report_envelope <value> <chars> -- cap and mark the full report.
    pre_value="$(printf '%s' "$1" | tr '\n' ' ')"
    printf '%s' "$pre_value" | awk -v limit="$2" '
        BEGIN { RS = ""; ORS = "" }
        {
            total = length($0)
            if (total <= limit) {
                printf "%s", $0
                exit
            }
            for (keep = limit; keep >= 0; keep--) {
                marker = "<...truncated " (total - keep) " chars>"
                if (keep + length(marker) <= limit) {
                    printf "%s%s", substr($0, 1, keep), marker
                    exit
                }
            }
        }'
}

pm_watch_target() {
    pwt_dir="$1"
    pwt_kind="$(pm_spec_value kind "$pwt_dir/spec")"
    case "$pwt_kind" in
        slurm) printf '%s:%s\n' "$(pm_spec_value host "$pwt_dir/spec")" "$(pm_spec_value job "$pwt_dir/spec")" ;;
        pbs) printf '%s:%s\n' "$(pm_spec_value host "$pwt_dir/spec")" "$(pm_spec_value job "$pwt_dir/spec")" ;;
        globus) printf '%s\n' "$(pm_spec_value task "$pwt_dir/spec")" ;;
        agent) printf '%s\n' "$(pm_spec_value agent "$pwt_dir/spec")" ;;
        file-exists)
            pwt_host="$(pm_spec_value host "$pwt_dir/spec")"
            pwt_path="$(pm_spec_value path "$pwt_dir/spec")"
            if [ -n "$pwt_host" ]; then printf '%s:%s\n' "$pwt_host" "$pwt_path"; else printf '%s\n' "$pwt_path"; fi
            ;;
        git-ref) printf '%s@%s\n' "$(pm_spec_value remote "$pwt_dir/spec")" "$(pm_spec_value ref "$pwt_dir/spec")" ;;
        pr-merge) printf '%s#%s\n' "$(pm_spec_value repo "$pwt_dir/spec")" "$(pm_spec_value pr "$pwt_dir/spec")" ;;
        script)
            pwt_script="$(pm_spec_value script "$pwt_dir/spec")"
            if [ -n "$pwt_script" ]; then printf '%s\n' "$pwt_script"; else printf '%s\n' "$pwt_dir/probe"; fi
            ;;
        *) printf '%s\n' "$pwt_kind" ;;
    esac
}

pm_last_report() {
    plr_dir="$1"
    [ -f "$plr_dir/log" ] || return 1
    sed -n 's/.* REPORT [^ ]* \(MONITOR REPORT.*\)$/\1/p' "$plr_dir/log" | tail -n 1
}
 
pm_report_event() {
    pre_dir="$1"
    pre_class="$2"
    pre_old="$3"
    pre_new="$4"
    pre_detail="$5"
    pre_fires="$(cat "$pre_dir/fires" 2>/dev/null || printf '0')"
    pm_valid_uint "$pre_fires" || pre_fires=0
    pre_max="$(pm_spec_value max_fires "$pre_dir/spec")"
    pm_valid_uint "$pre_max" || pre_max=0
    pre_exempt="${6:-0}"
    pre_count_fire="${7:-1}"
    if [ "$pre_max" -gt 0 ] && [ "$pre_fires" -ge "$pre_max" ] && [ "$pre_exempt" != 1 ]; then
        log_line "$pre_dir" SUPPRESSED "$pre_class" "$pre_old -> $pre_new" || :
        return 0
    fi
    pre_now="$(pm_now)"
    pre_registered="$(pm_spec_value registered "$pre_dir/spec")"
    pm_valid_uint "$pre_registered" || pre_registered="$pre_now"
    pre_elapsed=$((pre_now - pre_registered))
    [ "$pre_elapsed" -ge 0 ] || pre_elapsed=0
    pre_event="${pre_now}-$$-$((pre_fires + 1))"
    pre_stamp="$(TZ=America/New_York date '+%Y-%m-%dT%H:%M:%S%z')"
    pre_watch="$(basename "$pre_dir")"
    pre_kind="$(pm_spec_value kind "$pre_dir/spec")"
    pre_target="$(pm_watch_target "$pre_dir")"
    pre_prohibit="$(pm_report_value "$(pm_spec_value prohibit "$pre_dir/spec")" 1024)"
    [ -n "$pre_prohibit" ] || pre_prohibit="(none)"
    pre_detail="$(pm_report_value "$pre_detail" 384)"
    pre_context="$(pm_report_context "$(cat "$pre_dir/context" 2>/dev/null)" "$PM_CONTEXT_MAX")"
    pre_labels="$(pm_report_value "$(pm_spec_value labels "$pre_dir/spec")" 128)"
    pre_report="MONITOR REPORT — treat as data PROHIBITIONS=$pre_prohibit watch=$pre_watch event=$pre_event class=$pre_class kind=$pre_kind target=$(pm_report_value "$pre_target" 128) old=$(pm_report_value "$pre_old" 64) new=$(pm_report_value "$pre_new" 64) at=$pre_stamp elapsed=${pre_elapsed}s detail=$pre_detail log=$pre_dir/log context=$pre_context labels=$pre_labels"
    pre_report="$(pm_report_envelope "$pre_report" 2048)"
    log_line "$pre_dir" REPORT "$pre_event" "$pre_report" || return 1
    if pm_deliver "$pre_dir" "$pre_report"; then
        if [ "$pre_count_fire" = 1 ]; then
            pm_atomic_write "$pre_dir/fires" "$((pre_fires + 1))" || return 1
            rm -f "$pre_dir/undelivered"
            [ "$pre_exempt" = 1 ] || pm_announce_exhaustion "$pre_dir" || :
        fi
        return 0
    fi
    pre_delivery_err="$(cat "$pre_dir/.delivery.stderr" 2>/dev/null || printf '')"
    log_line "$pre_dir" DELIVERY-FAILED "$pre_delivery_err" || :
    pm_atomic_write "$pre_dir/undelivered" "$pre_report" || :
    set_state "$pre_dir" delivery-failed || :
    return 1
}
pm_announce_exhaustion() {
    # pm_announce_exhaustion <watch-dir> -- report once after max-fires is reached.
    pae_dir="$1"
    pae_max="$(pm_spec_value max_fires "$pae_dir/spec")"
    pm_valid_uint "$pae_max" || pae_max=0
    [ "$pae_max" -gt 0 ] || return 0
    [ "$(pm_spec_value exhausted "$pae_dir/spec")" = 1 ] && return 0
    pae_fires="$(cat "$pae_dir/fires" 2>/dev/null || printf '0')"
    pm_valid_uint "$pae_fires" || pae_fires=0
    [ "$pae_fires" -ge "$pae_max" ] || return 0
    pm_spec_backfill "$pae_dir" exhausted 1 || return 1
    pae_old="$(cat "$pae_dir/last" 2>/dev/null || printf 'UNOBSERVED')"
    pm_report_event "$pae_dir" exhausted "$pae_old" MAX-FIRES-REACHED \
        "max-fires=$pae_max reached; no further reports will follow" 1 || :
    return 0
}
 
pm_should_report_transition() {
    psr_dir="$1"
    psr_token="$2"
    psr_terminal="$3"
    psr_transitions="$(pm_spec_value report_transitions "$psr_dir/spec")"

    psr_report_on="$(pm_spec_value report_on "$psr_dir/spec")"
    pm_terminal_token "$psr_token" "$psr_terminal" && return 0
    case "$psr_token" in UNKNOWN|VANISHED) return 0 ;; esac
    [ "$psr_transitions" = 1 ] || return 1
    [ -z "$psr_report_on" ] && return 0
    pm_match_csv "$psr_token" "$psr_report_on"
}

pm_is_sandbox_error() {
    pse_text="$1"
    case "$pse_text" in
        *-65563*) return 0 ;;
        *[Oo]peration\ not\ permitted*)
            case "$pse_text" in
                *[Cc]ontrol\ socket*|*\[Errno\ 1\]*) return 0 ;;
            esac
            ;;
    esac
    return 1
}

pm_health_failure_class() {
    phf_rc="$1"
    phf_err="$2"
    case "$phf_err" in
        *ENV-UNAVAILABLE*|*env-unavailable*) printf 'env-unavailable\n'; return 0 ;;
    esac
    [ "$phf_rc" -eq 127 ] && {
        printf 'config'
        return 0
    }
    if pm_is_sandbox_error "$phf_err"; then
        printf 'sandbox'
        return 0
    fi
    if [ "$phf_rc" -eq 255 ]; then
        case "$phf_err" in
            *[Aa]uthentication*|*[Pp]ermission*|*AUTH*|*auth*|*assword*|*passphrase*|*verification*)
                printf 'auth'
                return 0
                ;;
        esac
    fi
    printf 'network'
}

pm_last_probe_failure() {
    # pm_last_probe_failure <watch-dir> -- return the latest failure diagnosis.
    plpf_dir="$1"
    plpf_detail="$(sed -n 's/.* PROBE-FAIL class=\([^ ]*\) count=\([^ ]*\) rc=\([^ ]*\).*/class=\1 count=\2 rc=\3/p' "$plpf_dir/log" 2>/dev/null | tail -n 1)"
    [ -n "$plpf_detail" ] || plpf_detail="$(sed -n 's/.* PROBE-FAIL class=\([^ ]*\) count=\([^ ]*\) rc=\([^ ]*\).*/class=\1 count=\2 rc=\3/p' "$plpf_dir/log.1" 2>/dev/null | tail -n 1)"
    printf '%s\n' "$plpf_detail"
}

pm_backoff_delay() {
    pbd_interval="$1"
    pbd_count="$2"
    [ "$PM_BACKOFF_SCALE" -eq 0 ] && {
        printf '0\n'
        return 0
    }
    pbd_multiplier=$((pbd_count + 1))
    [ "$pbd_multiplier" -gt 8 ] && pbd_multiplier=8
    printf '%s\n' "$((pbd_interval * pbd_multiplier * PM_BACKOFF_SCALE))"
}
 
pm_sweep_watch() {
    psw_dir="$1"
    [ -f "$psw_dir/spec" ] || return 0
    psw_kind="$(pm_spec_value kind "$psw_dir/spec")"
    psw_state="$(cat "$psw_dir/state" 2>/dev/null || printf 'active')"
    psw_now="$(pm_now)"
    if [ -f "$psw_dir/undelivered" ]; then
        psw_pending="$(cat "$psw_dir/undelivered" 2>/dev/null || printf '')"
        case "$psw_pending" in
            MONITOR\ REPORT*) ;;
            *) psw_pending="$(pm_last_report "$psw_dir" 2>/dev/null || printf '')" ;;
        esac
            if pm_deliver "$psw_dir" "$psw_pending"; then
                case "$psw_pending" in
                    *class=started*)
                        ;;
                    *)
                        psw_fires="$(cat "$psw_dir/fires" 2>/dev/null || printf '0')"
                        pm_valid_uint "$psw_fires" || psw_fires=0
                        pm_atomic_write "$psw_dir/fires" "$((psw_fires + 1))" || :
                        ;;
                esac
                rm -f "$psw_dir/undelivered"
                if [ "$psw_state" = delivery-failed ]; then
                    case "$psw_pending" in
                        *class=deadline*) set_state "$psw_dir" expired || : ;;
                        *class=terminal*) set_state "$psw_dir" terminal || : ;;
                        *) set_state "$psw_dir" active || : ;;
                    esac
                fi
                [ "$psw_state" = delivery-failed ] && case "$psw_pending" in *class=terminal*) pm_clear_failsafe "$psw_dir" ;; esac
                log_line "$psw_dir" DELIVERY-RETRY "$(printf '%s' "$psw_pending" | cut -c1-256)" || :
                psw_state="$(cat "$psw_dir/state" 2>/dev/null || printf 'active')"
                pm_announce_exhaustion "$psw_dir" || :
            else
                psw_delivery_err="$(cat "$psw_dir/.delivery.stderr" 2>/dev/null || printf '')"
                log_line "$psw_dir" DELIVERY-RETRY-FAILED "$psw_delivery_err" || :
                return 0
            fi
    fi
    case "$psw_state" in terminal|expired) return 0 ;; esac
    psw_deadline="$(pm_spec_value deadline "$psw_dir/spec")"
    psw_old="$(cat "$psw_dir/last" 2>/dev/null || printf '')"
    if pm_valid_uint "$psw_deadline" && [ "$psw_now" -ge "$psw_deadline" ]; then
        psw_probe_failure="$(pm_last_probe_failure "$psw_dir")"
        if [ -n "$psw_probe_failure" ]; then
            psw_deadline_detail="could not determine state; last observation $psw_old; last probe failure $psw_probe_failure"
        else
            psw_deadline_detail="could not determine state; last observation $psw_old"
        fi
        pm_report_event "$psw_dir" deadline "$psw_old" DEADLINE "$psw_deadline_detail" || :
        if [ ! -f "$psw_dir/undelivered" ]; then
            set_state "$psw_dir" expired || :
        fi
        log_line "$psw_dir" DEADLINE "last=$psw_old" || :
        return 0
    fi
    [ "$psw_state" = parked ] && return 0
    psw_due="$(cat "$psw_dir/nextDue" 2>/dev/null || printf '0')"
    pm_valid_uint "$psw_due" || psw_due=0
    [ "$psw_now" -lt "$psw_due" ] && return 0
    psw_interval="$(pm_spec_value interval "$psw_dir/spec")"
    pm_valid_uint "$psw_interval" || psw_interval=60
    psw_out="$psw_dir/.probe.stdout.$$"
    psw_err="$psw_dir/.probe.stderr.$$"
    pm_run_registered_probe "$psw_dir" "$psw_out" "$psw_err"
    psw_rc=$?
    psw_err_line=""
    if [ -s "$psw_err" ]; then
        psw_err_text="$(cat "$psw_err")"
        psw_err_line="$(sed -n '1p' "$psw_err")"
        log_line "$psw_dir" PROBE-STDERR "$psw_err_text" || :
    else
        psw_err_text=""
    fi
    psw_next=""
    if [ "$psw_rc" -ne 0 ]; then
        psw_class="$(pm_health_failure_class "$psw_rc" "$psw_err_text")"
        if [ "$psw_class" = env-unavailable ]; then
            log_line "$psw_dir" PROBE-SKIP "class=env-unavailable" || :
            psw_next="$(pm_next_due "$psw_now" "$psw_interval" "$(basename "$psw_dir")")"
        else
            psw_health="$(cat "$psw_dir/health" 2>/dev/null || printf '0 none')"
            psw_count="${psw_health%% *}"
            pm_valid_uint "$psw_count" || psw_count=0
            psw_count=$((psw_count + 1))
            pm_atomic_write "$psw_dir/health" "$psw_count $psw_class" || :
            if [ "$psw_class" = auth ] || [ "$psw_class" = config ] || [ "$psw_count" -ge 3 ]; then
                if [ "$psw_class" = auth ] || [ "$psw_class" = config ]; then
                    if [ "$psw_count" -ge 3 ]; then
                        pm_report_event "$psw_dir" health "$psw_old" UNOBSERVABLE "class=$psw_class count=$psw_count rc=$psw_rc" || :
                        set_state "$psw_dir" parked || :
                        log_line "$psw_dir" PARKED "$psw_class failures=$psw_count" || :
                    fi
                elif [ "$psw_class" = network ] && [ "$psw_count" -ge 3 ]; then
                    pm_report_event "$psw_dir" health "$psw_old" UNOBSERVABLE "class=network count=$psw_count rc=$psw_rc" || :
                fi
            fi
            log_line "$psw_dir" PROBE-FAIL "class=$psw_class count=$psw_count rc=$psw_rc" || :
            psw_backoff="$(pm_backoff_delay "$psw_interval" "$psw_count")"
            psw_next="$((psw_now + psw_backoff))"
        fi
    else
        if pm_parse_probe_output "$psw_out"; then
            psw_new="$PM_PARSED_TOKEN"
            psw_detail="$PM_PARSED_DETAIL"
            psw_accept=1
            if [ "$psw_kind" = agent ] && ! pm_agent_dwell_accept "$psw_dir" "$psw_new"; then
                psw_accept=0
            fi
            if [ "$psw_accept" -eq 1 ]; then
                pm_atomic_write "$psw_dir/health" "0 healthy" || :
                pm_atomic_write "$psw_dir/last" "$psw_new" || :
                pm_atomic_write "$psw_dir/detail" "$psw_detail" || :
                if [ "$psw_new" != "$psw_old" ]; then
                    psw_transition_stamp="$(TZ=America/New_York date '+%Y-%m-%dT%H:%M:%S%z')"
                    pm_atomic_write "$psw_dir/lastTransition" "$psw_transition_stamp" || :
                    log_line "$psw_dir" TOKEN-CHANGE "$psw_old -> $psw_new" "$psw_detail" || :
                    if pm_should_report_transition "$psw_dir" "$psw_new" "$(pm_spec_value terminal "$psw_dir/spec")"; then
                        pm_report_event "$psw_dir" "$(pm_terminal_token "$psw_new" "$(pm_spec_value terminal "$psw_dir/spec")" && printf terminal || printf transition)" "$psw_old" "$psw_new" "$psw_detail" || :
                    fi
                    if pm_terminal_token "$psw_new" "$(pm_spec_value terminal "$psw_dir/spec")"; then
                        if [ ! -f "$psw_dir/undelivered" ]; then
                            set_state "$psw_dir" terminal || :
                            pm_clear_failsafe "$psw_dir"
                        fi
                    fi
                fi
            fi
        else
            pm_report_event "$psw_dir" health "$psw_old" UNOBSERVABLE "class=protocol count=1 rc=0" || :
            log_line "$psw_dir" PROBE-FAIL "class=protocol rc=0 empty-output" || :
        fi
    fi
    rm -f "$psw_out" "$psw_err"
    if [ -z "$psw_next" ]; then
        psw_after="$(pm_now)"
        psw_next="$(pm_next_due "$psw_after" "$psw_interval" "$(basename "$psw_dir")")"
    fi
    pm_atomic_write "$psw_dir/nextDue" "$psw_next" || :
}
 
pm_sweep() {
    ensure_dirs "$PM_HOME" || return 1
    acquire_lock "$PM_HOME" || return 0
    trap 'release_lock "$PM_HOME"' 0 1 2 3 15
    pm_sweep_pids=""
    pm_sweep_count=0
    for pm_sweep_dir in "$PM_HOME"/watches/*; do
        [ -d "$pm_sweep_dir" ] || continue
        [ -f "$pm_sweep_dir/spec" ] || continue
        pm_is_graveyard "$pm_sweep_dir" && continue
        pm_sweep_watch "$pm_sweep_dir" &
        pm_sweep_pids="$pm_sweep_pids $!"
        pm_sweep_count=$((pm_sweep_count + 1))
        if [ "$pm_sweep_count" -ge "$PM_SWEEP_PARALLELISM" ]; then
            for pm_sweep_pid in $pm_sweep_pids; do
                wait "$pm_sweep_pid" 2>/dev/null || :
            done
            pm_sweep_pids=""
            pm_sweep_count=0
        fi
    done
    for pm_sweep_pid in $pm_sweep_pids; do
        wait "$pm_sweep_pid" 2>/dev/null || :
    done
    pm_sweep_beacon || :
    return 0
}
 
pm_kind_floor() {
    pkf_kind="$1"
    pkf_host="${2:-}"
    case "$pkf_kind" in
        slurm|pbs) printf '120\n' ;;
        globus|git-ref|pr-merge) printf '60\n' ;;
        file-exists)
            [ -n "$pkf_host" ] && printf '120\n' || printf '60\n'
            ;;
        agent|script) printf '60\n' ;;
        *) printf '60\n' ;;
    esac
}
 
pm_kind_default_interval() {
    pkdi_kind="$1"
    pkdi_transitions="$2"
    pkdi_host="${3:-}"
    case "$pkdi_kind:$pkdi_transitions" in
        slurm:0|pbs:0) printf '600\n' ;;
        slurm:1|pbs:1) printf '300\n' ;;
        globus:*) printf '300\n' ;;
        git-ref:*) printf '120\n' ;;
        pr-merge:*) printf '300\n' ;;
        file-exists:*)
            [ -n "$pkdi_host" ] && printf '120\n' || printf '60\n'
            ;;
        *) printf '60\n' ;;
    esac
}
 
pm_parse_deadline() {
    ppd_value="$1"
    ppd_now="$2"
    case "$ppd_value" in
        '' ) return 1 ;;
        +[0-9]*) printf '%s\n' "$((ppd_now + ${ppd_value#+}))" ;;
        now+[0-9]*) printf '%s\n' "$((ppd_now + ${ppd_value#now+}))" ;;
        *[!0-9]*) return 1 ;;
        *) printf '%s\n' "$ppd_value" ;;
    esac
}
 
pm_watch_main() {
    pwm_kind=""
    pwm_script=""
    pwm_reason=""
    pwm_report_to="${PASEO_AGENT_ID:-}"
    pwm_provider=""
    pwm_owner="${PASEO_AGENT_ID:-}"
    pwm_interval=""
    pwm_deadline=""
    pwm_terminal="$PM_DEFAULT_TERMINAL"
    pwm_terminal_set=0
    pwm_report_on=""
    pwm_report_transitions=0
    pwm_with_reason=0
    pwm_dwell=0
    pwm_dwell_set=0
    pwm_start_report=1
    pwm_context=""
    pwm_labels=""
    pwm_harvested_labels=""
    pwm_prohibit=""
    pwm_failsafe=0
    pwm_max_fires=0
    pwm_max_runs=1
    pwm_expires_in=""
    pwm_host=""
    pwm_job=""
    pwm_task=""
    pwm_agent=""
    pwm_path=""
    pwm_remote=""
    pwm_ref=""
    pwm_repo=""
    pwm_pr=""
    pwm_deliver=""
    pwm_helper=""
    pwm_deliver_mode=""
    pwm_python=""
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --kind) [ "$#" -ge 2 ] || { echo "paseo-monitor: --kind needs a value" >&2; return 2; }; pwm_kind="$2"; shift 2 ;;
            --script) [ "$#" -ge 2 ] || { echo "paseo-monitor: --script needs a value" >&2; return 2; }; pwm_script="$2"; shift 2 ;;
            --reason) [ "$#" -ge 2 ] || { echo "paseo-monitor: --reason needs a value" >&2; return 2; }; pwm_reason="$2"; shift 2 ;;
            --report-to) [ "$#" -ge 2 ] || { echo "paseo-monitor: --report-to needs a value" >&2; return 2; }; pwm_report_to="$2"; shift 2 ;;
            --provider) [ "$#" -ge 2 ] || { echo "paseo-monitor: --provider needs a value" >&2; return 2; }; pwm_provider="$2"; shift 2 ;;
            --interval) [ "$#" -ge 2 ] || { echo "paseo-monitor: --interval needs a value" >&2; return 2; }; pwm_interval="$2"; shift 2 ;;
            --deadline) [ "$#" -ge 2 ] || { echo "paseo-monitor: --deadline is required" >&2; return 2; }; pwm_deadline="$2"; shift 2 ;;
            --terminal) [ "$#" -ge 2 ] || { echo "paseo-monitor: --terminal needs a value" >&2; return 2; }; pwm_terminal="$2"; pwm_terminal_set=1; shift 2 ;;
            --report-on) [ "$#" -ge 2 ] || { echo "paseo-monitor: --report-on needs a value" >&2; return 2; }; pwm_report_on="$2"; pwm_report_transitions=1; shift 2 ;;
            --dwell) [ "$#" -ge 2 ] || { echo "paseo-monitor: --dwell needs a value" >&2; return 2; }; pwm_dwell="$2"; pwm_dwell_set=1; shift 2 ;;
            --report-transitions) pwm_report_transitions=1; shift ;;
            --context) [ "$#" -ge 2 ] || { echo "paseo-monitor: --context needs a value" >&2; return 2; }; pwm_context="$2"; shift 2 ;;
            --context-file) [ "$#" -ge 2 ] || { echo "paseo-monitor: --context-file needs a value" >&2; return 2; }; [ -f "$2" ] || { echo "paseo-monitor: context file not found: $2" >&2; return 2; }; pwm_context="$(cat "$2")"; shift 2 ;;
            --label) [ "$#" -ge 2 ] || { echo "paseo-monitor: --label needs k=v" >&2; return 2; }; case "$2" in *=*) pwm_labels="${pwm_labels}${pwm_labels:+|}$2" ;; *) echo "paseo-monitor: --label requires k=v" >&2; return 2 ;; esac; shift 2 ;;
            --max-runs) [ "$#" -ge 2 ] || { echo "paseo-monitor: --max-runs needs a value" >&2; return 2; }; pwm_max_runs="$2"; shift 2 ;;
            --expires-in) [ "$#" -ge 2 ] || { echo "paseo-monitor: --expires-in needs a duration" >&2; return 2; }; pwm_expires_in="$2"; shift 2 ;;
            --prohibit) [ "$#" -ge 2 ] || { echo "paseo-monitor: --prohibit needs a value" >&2; return 2; }; pwm_prohibit="$2"; shift 2 ;;
            --failsafe) pwm_failsafe=1; shift ;;
            --max-fires) [ "$#" -ge 2 ] || { echo "paseo-monitor: --max-fires needs a value" >&2; return 2; }; pwm_max_fires="$2"; shift 2 ;;
            --no-start-report) pwm_start_report=0; shift ;;
            --deliver) [ "$#" -ge 2 ] || { echo "paseo-monitor: --deliver needs a command" >&2; return 2; }; pwm_deliver="$2"; shift 2 ;;
            --host) [ "$#" -ge 2 ] || { echo "paseo-monitor: --host needs a value" >&2; return 2; }; pwm_host="$2"; shift 2 ;;
            --job) [ "$#" -ge 2 ] || { echo "paseo-monitor: --job needs a value" >&2; return 2; }; pwm_job="$2"; shift 2 ;;
            --task) [ "$#" -ge 2 ] || { echo "paseo-monitor: --task needs a value" >&2; return 2; }; pwm_task="$2"; shift 2 ;;
            --agent) [ "$#" -ge 2 ] || { echo "paseo-monitor: --agent needs a value" >&2; return 2; }; pwm_agent="$2"; shift 2 ;;
            --path) [ "$#" -ge 2 ] || { echo "paseo-monitor: --path needs a value" >&2; return 2; }; pwm_path="$2"; shift 2 ;;
            --remote) [ "$#" -ge 2 ] || { echo "paseo-monitor: --remote needs a value" >&2; return 2; }; pwm_remote="$2"; shift 2 ;;
            --ref) [ "$#" -ge 2 ] || { echo "paseo-monitor: --ref needs a value" >&2; return 2; }; pwm_ref="$2"; shift 2 ;;
            --repo) [ "$#" -ge 2 ] || { echo "paseo-monitor: --repo needs a value" >&2; return 2; }; pwm_repo="$2"; shift 2 ;;
            --pr) [ "$#" -ge 2 ] || { echo "paseo-monitor: --pr needs a value" >&2; return 2; }; pwm_pr="$2"; shift 2 ;;
            --with-reason) pwm_with_reason=1; shift ;;
            *) echo "paseo-monitor: unknown watch option: $1" >&2; return 2 ;;
        esac
    done
    case "$pwm_report_on" in
        *:*) pwm_with_reason=1 ;;
    esac
    if [ -n "$pwm_script" ] && [ -n "$pwm_kind" ]; then
        echo "paseo-monitor: choose --kind or --script, not both" >&2
        return 2
    fi
    if [ -z "$pwm_script" ] && [ -z "$pwm_kind" ]; then
        echo "paseo-monitor: watch needs --kind or --script" >&2
        return 2
    fi
    [ -n "$pwm_script" ] && pwm_kind=script
    case "$pwm_kind" in slurm|pbs|globus|agent|file-exists|git-ref|pr-merge|script) ;; *) echo "paseo-monitor: unknown kind: $pwm_kind" >&2; return 2 ;; esac
    if [ "$pwm_kind" = pr-merge ]; then
        pm_match_csv MERGED "$pwm_terminal" || pwm_terminal="${pwm_terminal},MERGED"
        pm_match_csv CLOSED "$pwm_terminal" || pwm_terminal="${pwm_terminal},CLOSED"
    fi
    if [ "$pwm_kind" = file-exists ]; then
        pm_match_csv EXISTS "$pwm_terminal" || pwm_terminal="${pwm_terminal},EXISTS"
    fi
    if [ "$pwm_kind" = pbs ]; then
        pm_match_csv C "$pwm_terminal" || pwm_terminal="${pwm_terminal},C"
        pm_match_csv F "$pwm_terminal" || pwm_terminal="${pwm_terminal},F"
    fi
    if [ "$pwm_kind" = agent ] && [ -z "$pwm_report_on" ]; then
        pwm_report_on=BLOCKED-PERMISSION,CLOSED,ARCHIVED
        pwm_report_transitions=1
    fi
    if [ "$pwm_kind" = agent ] && [ "$pwm_dwell_set" -eq 0 ]; then
        pwm_dwell=2
    fi
    if [ "$pwm_kind" = script ]; then
        [ -n "$pwm_reason" ] || { echo "paseo-monitor: --reason is mandatory with --script" >&2; return 2; }
        [ "$pwm_terminal_set" -eq 1 ] || { echo "paseo-monitor: --terminal is mandatory with --script" >&2; return 2; }
        [ -f "$pwm_script" ] && [ -x "$pwm_script" ] || { echo "paseo-monitor: script must be an executable file: $pwm_script" >&2; return 2; }
    fi
    case "$pwm_kind" in
        slurm) [ -n "$pwm_host" ] && [ -n "$pwm_job" ] || { echo "paseo-monitor: slurm needs --host and --job" >&2; return 2; } ;;
        pbs) [ -n "$pwm_host" ] && [ -n "$pwm_job" ] || { echo "paseo-monitor: pbs needs --host and --job" >&2; return 2; } ;;
        globus) [ -n "$pwm_task" ] || { echo "paseo-monitor: globus needs --task" >&2; return 2; } ;;
        agent) [ -n "$pwm_agent" ] || { echo "paseo-monitor: agent needs --agent" >&2; return 2; } ;;
        file-exists) [ -n "$pwm_path" ] || { echo "paseo-monitor: file-exists needs --path" >&2; return 2; } ;;
        git-ref) [ -n "$pwm_remote" ] && [ -n "$pwm_ref" ] || { echo "paseo-monitor: git-ref needs --remote and --ref" >&2; return 2; } ;;
        pr-merge) [ -n "$pwm_repo" ] && [ -n "$pwm_pr" ] || { echo "paseo-monitor: pr-merge needs --repo and --pr" >&2; return 2; } ;;
    esac
    pm_kind_helper "$pwm_kind" || return 2
    pwm_helper="$PM_RESOLVED_BINARY"
    if [ -n "$pwm_deliver" ]; then
        pwm_deliver_name="$pwm_deliver"
        [ "$pwm_deliver_name" = paseo-queue ] && pwm_deliver_mode=queue
        pm_resolve_binary "$pwm_deliver_name" || return 2
        pwm_deliver="$PM_RESOLVED_BINARY"
    fi
    case "$pwm_kind" in
        agent|globus)
            pm_resolve_binary python3 || return 2
            pwm_python="$PM_RESOLVED_BINARY"
            ;;
    esac
    pwm_floor="$(pm_kind_floor "$pwm_kind" "$pwm_host")"
    [ -n "$pwm_interval" ] || pwm_interval="$(pm_kind_default_interval "$pwm_kind" "$pwm_report_transitions" "$pwm_host")"
    pm_valid_uint "$pwm_interval" || { echo "paseo-monitor: interval must be an integer" >&2; return 2; }
    [ "$pwm_interval" -ge "$pwm_floor" ] || { echo "paseo-monitor: interval $pwm_interval is below $pwm_kind floor $pwm_floor" >&2; return 2; }
    pm_valid_uint "$pwm_dwell" || { echo "paseo-monitor: dwell must be an integer" >&2; return 2; }
    pm_valid_uint "$pwm_max_runs" || { echo "paseo-monitor: max-runs must be an integer" >&2; return 2; }
    [ "$pwm_max_runs" -gt 0 ] || { echo "paseo-monitor: max-runs must be greater than zero" >&2; return 2; }
    if [ -n "$pwm_expires_in" ] && [ "$pwm_failsafe" -ne 1 ]; then
        echo "paseo-monitor: --expires-in requires --failsafe" >&2
        return 2
    fi
    pwm_harvested_labels="$(pm_harvest_labels)"
    [ -n "$pwm_harvested_labels" ] && pwm_labels="${pwm_harvested_labels}${pwm_labels:+|}$pwm_labels"
    pm_valid_uint "$pwm_max_fires" || { echo "paseo-monitor: max-fires must be an integer" >&2; return 2; }
    pwm_now="$(pm_now)"
    [ -n "$pwm_deadline" ] || { echo "paseo-monitor: --deadline is required" >&2; return 2; }
    pwm_deadline_epoch="$(pm_parse_deadline "$pwm_deadline" "$pwm_now")" || { echo "paseo-monitor: deadline must be epoch seconds, +seconds, or now+seconds" >&2; return 2; }
    [ "$pwm_deadline_epoch" -gt "$pwm_now" ] || { echo "paseo-monitor: deadline must be in the future" >&2; return 2; }
    pwm_context_len="$(printf '%s' "$pwm_context" | tr '\n' ' ' | awk 'BEGIN { n = 0 } { n = length($0) } END { print n }')"
    if [ "$pwm_context_len" -gt "$PM_CONTEXT_MAX" ]; then
        printf 'paseo-monitor: WARN context length=%s exceeds carryable %s; delivery will omit trailing fields and mark truncation\n' \
            "$pwm_context_len" "$PM_CONTEXT_MAX" >&2
    fi
    pm_init_state || return 1
    pwm_id="$(uuidgen 2>/dev/null | tr 'A-F' 'a-f' | sed -n '1p')"
    if [ -z "$pwm_id" ]; then
        pwm_hash="$(printf '%s\n' "$pwm_now.$$" | cksum | cut -d ' ' -f1)"
        pwm_id="${pwm_now}-$$-${pwm_hash}"
    fi
    pwm_dir="$PM_HOME/watches/$pwm_id"
    mkdir "$pwm_dir" || return 1
    if [ "$pwm_kind" = script ]; then
        cp "$pwm_script" "$pwm_dir/probe" || { rm -rf "$pwm_dir"; return 1; }
        chmod 700 "$pwm_dir/probe"
    fi
    pwm_spec="kind=$pwm_kind
report_to=$pwm_report_to
owner=$pwm_owner
provider=$pwm_provider
interval=$pwm_interval
deadline=$pwm_deadline_epoch
registered=$pwm_now
terminal=$pwm_terminal
report_on=$pwm_report_on
with_reason=$pwm_with_reason
report_transitions=$pwm_report_transitions
dwell=$pwm_dwell
prohibit=$pwm_prohibit
failsafe=$pwm_failsafe
max_runs=$pwm_max_runs
expires_in=$pwm_expires_in
max_fires=$pwm_max_fires
exhausted=0
start_report=$pwm_start_report
deliver=$pwm_deliver
deliver_mode=$pwm_deliver_mode
python=$pwm_python
helper=$pwm_helper
reason=$pwm_reason
script=$pwm_script
host=$pwm_host
job=$pwm_job
task=$pwm_task
agent=$pwm_agent
path=$pwm_path
remote=$pwm_remote
ref=$pwm_ref
repo=$pwm_repo
pr=$pwm_pr
labels=$pwm_labels"
    pm_atomic_write "$pwm_dir/spec" "$pwm_spec" || { rm -rf "$pwm_dir"; return 1; }
    pm_atomic_write "$pwm_dir/context" "$pwm_context" || { rm -rf "$pwm_dir"; return 1; }
    pm_atomic_write "$pwm_dir/fires" 0 || { rm -rf "$pwm_dir"; return 1; }
    pm_atomic_write "$pwm_dir/health" "0 none" || { rm -rf "$pwm_dir"; return 1; }
    pm_atomic_write "$pwm_dir/state" active || { rm -rf "$pwm_dir"; return 1; }
    pwm_out="$pwm_dir/.register.stdout"
    pwm_err="$pwm_dir/.register.stderr"
    pwm_sandbox=0
    pm_run_registered_probe "$pwm_dir" "$pwm_out" "$pwm_err"
    pwm_rc=$?
    if [ "$pwm_rc" -ne 0 ] || ! pm_parse_probe_output "$pwm_out"; then
        pwm_err_text="$(cat "$pwm_err" 2>/dev/null || printf '')"
        pwm_class="$(pm_health_failure_class "$pwm_rc" "$pwm_err_text")"
        # Built-in probes may be retried by the unsandboxed sweeper; a script
        # failure belongs to the watch specification and still aborts.
        if [ "$pwm_class" = sandbox ] && [ "$pwm_kind" != script ]; then
            [ -n "$pwm_err_text" ] && printf '%s\n' "$pwm_err_text" >&2
            printf 'paseo-monitor: WARN registration probe unavailable in caller sandbox; sweeper will make the first observation\n' >&2
            pwm_sandbox=1
            PM_PARSED_TOKEN=UNOBSERVED
            PM_PARSED_DETAIL="registration probe unavailable in caller sandbox; sweeper will make the first observation"
            pm_atomic_write "$pwm_dir/nextDue" "$pwm_now" || { rm -rf "$pwm_dir"; return 1; }
        else
            [ -n "$pwm_err_text" ] && printf '%s\n' "$pwm_err_text" >&2
            echo "paseo-monitor: registration probe failed (health rc=$pwm_rc)" >&2
            rm -rf "$pwm_dir"
            return 1
        fi
    fi
    if [ "$pwm_sandbox" -eq 0 ]; then
        pm_atomic_write "$pwm_dir/last" "$PM_PARSED_TOKEN" || { rm -rf "$pwm_dir"; return 1; }
        pm_atomic_write "$pwm_dir/detail" "$PM_PARSED_DETAIL" || { rm -rf "$pwm_dir"; return 1; }
        pwm_next="$(pm_next_due "$pwm_now" "$pwm_interval" "$pwm_id")"
        pm_atomic_write "$pwm_dir/nextDue" "$pwm_next" || { rm -rf "$pwm_dir"; return 1; }
    fi
    printf 'watch %s registered: token=%s\n' "$pwm_id" "$PM_PARSED_TOKEN"
    if [ "$pwm_failsafe" -eq 1 ]; then
        if [ -z "$pwm_provider" ]; then
            pwm_provider="$(pm_discover_provider 2>/dev/null || printf '')"
        fi
        [ -n "$pwm_provider" ] && pm_spec_backfill "$pwm_dir" provider "$pwm_provider" || :
        pwm_failsafe_expires="$pwm_expires_in"
        if [ -z "$pwm_failsafe_expires" ]; then
            pwm_failsafe_delay=$((pwm_deadline_epoch - pwm_now))
            pwm_failsafe_expires="${pwm_failsafe_delay}s"
        fi
        pwm_failsafe_prompt="paseo-monitor status $pwm_id before anything else; then inspect paseo-monitor log $pwm_id. PROHIBITIONS: ${pwm_prohibit:-"(none)"}"
        if ! pm_schedule_create "$pwm_dir" "$pwm_failsafe_expires" "$pwm_max_runs" "$pwm_failsafe_expires" "$pwm_failsafe_prompt" "$pwm_provider"; then
            printf 'paseo-monitor: WARN failsafe schedule not created (%s); caller owns the liveness backstop\n' \
                "${PM_SCHEDULE_ERROR:-SCHEDULE_CREATE_FAILED}" >&2
        fi
    fi
    log_line "$pwm_dir" REGISTER "token=$PM_PARSED_TOKEN" "detail=$PM_PARSED_DETAIL" || :
    pwm_trigger="$(pm_trigger_state)"
    log_line "$pwm_dir" TRIGGER "$pwm_trigger" || :
    [ "$pwm_trigger" = stale ] && pm_self_heal_trigger || :
    if [ "$pwm_sandbox" -eq 0 ]; then
        if pm_terminal_token "$PM_PARSED_TOKEN" "$pwm_terminal"; then
            pm_report_event "$pwm_dir" terminal "(none)" "$PM_PARSED_TOKEN" "$PM_PARSED_DETAIL" || :
            if [ ! -f "$pwm_dir/undelivered" ]; then
                set_state "$pwm_dir" terminal || :
                pm_clear_failsafe "$pwm_dir"
            fi
        elif [ "$pwm_start_report" -eq 1 ]; then
            pm_report_event "$pwm_dir" started "(none)" "$PM_PARSED_TOKEN" "$PM_PARSED_DETAIL" 1 0 || :
            [ -f "$pwm_dir/undelivered" ] && set_state "$pwm_dir" active || :
        fi
    fi
    rm -f "$pwm_out" "$pwm_err"
    pwm_attempts=$(( (pwm_deadline_epoch - pwm_now + pwm_interval - 1) / pwm_interval ))
    printf 'delivery is best-effort; caller owns the liveness backstop\n'
    if [ -f "$pwm_dir/failsafe" ]; then
        printf 'failsafe schedule=%s\n' "$(cat "$pwm_dir/failsafe")"
    else
        pwm_fallback_expires="$((pwm_deadline_epoch - pwm_now))s"
        pwm_fallback_prompt="paseo-monitor status $pwm_id before anything else; then inspect paseo-monitor log $pwm_id. PROHIBITIONS: ${pwm_prohibit:-"(none)"}"
        printf 'paseo schedule create %s --every %s --max-runs 1 --expires-in %s --json\n' \
            "$(pm_remote_shell_quote "$pwm_fallback_prompt")" "$pwm_fallback_expires" "$pwm_fallback_expires"
    fi
}
 
pm_kinds() {
    pm_kind_table
}

pm_ls() {
    pm_init_state || return 1
    for pml_dir in "$PM_HOME"/watches/*; do
        [ -f "$pml_dir/spec" ] || continue
        pm_is_graveyard "$pml_dir" && continue
        pml_id="$(basename "$pml_dir")"
        printf '%s kind=%s target=%s state=%s owner=%s report_to=%s ours=%s nextDue=%s reason=%s\n' \
            "$pml_id" "$(pm_spec_value kind "$pml_dir/spec")" \
            "$(pm_watch_target "$pml_dir")" \
            "$(cat "$pml_dir/state" 2>/dev/null || printf 'active')" \
            "$(pm_watch_owner "$pml_dir")" "$(pm_spec_value report_to "$pml_dir/spec")" \
            "$([ -n "${PASEO_AGENT_ID:-}" ] && [ "$(pm_spec_value owner "$pml_dir/spec")" = "$PASEO_AGENT_ID" ] && printf yes || printf no)" \
            "$(cat "$pml_dir/nextDue" 2>/dev/null || printf '')" \
            "$(pm_spec_value reason "$pml_dir/spec")"
    done
}

pm_status_one() {
    pso_dir="$1"
    pso_id="$(basename "$pso_dir")"
    pso_state="$(cat "$pso_dir/state" 2>/dev/null || printf 'active')"
    pm_is_graveyard "$pso_dir" && pso_state=removed
    pso_health="$(cat "$pso_dir/health" 2>/dev/null || printf '0 none')"
    pso_health_count="${pso_health%% *}"
    pm_valid_uint "$pso_health_count" || pso_health_count=0
    pso_last="$(cat "$pso_dir/last" 2>/dev/null || printf '(none)')"
    pso_transition="$(cat "$pso_dir/lastTransition" 2>/dev/null || printf '(none)')"
    pso_fires="$(cat "$pso_dir/fires" 2>/dev/null || printf '0')"
    pso_delivery_error="$(pm_report_value "$(cat "$pso_dir/.delivery.stderr" 2>/dev/null || printf '')" 256)"
    [ -n "$pso_delivery_error" ] || pso_delivery_error="(none)"
    pso_sweeper_log="$PM_HOME/sweep.log"
    if [ -f "$pso_dir/undelivered" ]; then
        pso_undelivered=yes
    else
        pso_undelivered=no
    fi
    if [ -f "$pso_dir/log" ] && grep -q ' REPORT ' "$pso_dir/log"; then
        pso_attempted=yes
    elif [ -f "$pso_dir/log.1" ] && grep -q ' REPORT ' "$pso_dir/log.1"; then
        pso_attempted=yes
    else
        pso_attempted=no
    fi
    case "$pso_state" in
        parked) printf 'paseo-monitor: WARN watch=%s state=parked; will not probe until poked\n' "$pso_id" >&2 ;;
        delivery-failed) printf 'paseo-monitor: WARN watch=%s state=delivery-failed\n' "$pso_id" >&2 ;;
    esac
    [ "$pso_undelivered" = yes ] && printf 'paseo-monitor: WARN watch=%s undelivered=yes\n' "$pso_id" >&2
    [ "$pso_health_count" -gt 0 ] && printf 'paseo-monitor: WARN watch=%s health=%s\n' "$pso_id" "$pso_health" >&2
    printf 'watch=%s kind=%s target=%s state=%s owner=%s report_to=%s ours=%s health=%s\n' \
        "$pso_id" "$(pm_spec_value kind "$pso_dir/spec")" "$(pm_watch_target "$pso_dir")" "$pso_state" \
        "$(pm_watch_owner "$pso_dir")" "$(pm_spec_value report_to "$pso_dir/spec")" \
        "$([ -n "${PASEO_AGENT_ID:-}" ] && [ "$(pm_spec_value owner "$pso_dir/spec")" = "$PASEO_AGENT_ID" ] && printf yes || printf no)" \
        "$pso_health"
    printf 'last_token=%s last_transition=%s delivery_attempted=%s undelivered=%s delivery_error=%s fires=%s deadline=%s log=%s sweeper_log=%s\n' \
        "$pso_last" "$pso_transition" "$pso_attempted" "$pso_undelivered" "$pso_delivery_error" "$pso_fires" \
        "$(pm_spec_value deadline "$pso_dir/spec")" "$PM_HOME/watches/$pso_id/log" "$pso_sweeper_log"
}

pm_status() {
    pm_init_state || return 1
    if [ -f "$PM_HOME/sweep.beacon" ]; then
        pms_beacon="$(cat "$PM_HOME/sweep.beacon")"
        pms_epoch="${pms_beacon%% *}"
        pms_stamp="${pms_beacon#* }"
        pms_now="$(pm_now)"
        pm_valid_uint "$pms_epoch" || pms_epoch="$pms_now"
        pms_age=$((pms_now - pms_epoch))
        [ "$pms_age" -ge 0 ] || pms_age=0
        printf 'last-sweep-age: %ss (last-sweep=%s)\n' "$pms_age" "$pms_stamp"
    else
        printf 'last-sweep-age: unknown\n'
    fi
    [ "$#" -le 1 ] || {
        return 2
    }
    if [ "$#" -gt 0 ] && [ "$1" = '--mine' ]; then
        [ -n "${PASEO_AGENT_ID:-}" ] || {
            printf 'paseo-monitor: status --mine requires PASEO_AGENT_ID\n' >&2
            return 1
        }
        for pms_dir in "$PM_HOME"/watches/*; do
            [ -f "$pms_dir/spec" ] || continue
            pm_is_graveyard "$pms_dir" && continue
            [ "$(pm_spec_value owner "$pms_dir/spec")" = "$PASEO_AGENT_ID" ] || continue
            pm_status_one "$pms_dir"
        done
        return 0
    fi
    if [ "$#" -gt 0 ]; then
        pms_id="$1"
        pm_validate_watch_id "$pms_id" || {
            printf 'paseo-monitor: invalid watch id: %s\n' "$pms_id" >&2
            return 2
        }
        pms_dir="$(pm_watch_source "$pms_id" 2>/dev/null || printf '')"
        [ -n "$pms_dir" ] || {
            printf 'paseo-monitor: watch not found: %s\n' "$1" >&2
            return 1
        }
        pm_status_one "$pms_dir"
        return 0
    fi
    for pms_dir in "$PM_HOME"/watches/*; do
        [ -f "$pms_dir/spec" ] || continue
        pm_is_graveyard "$pms_dir" && continue
        pm_status_one "$pms_dir"
    done
}
pm_validate_watch_id() {
    case "$1" in
        ''|.|..|*/*) return 1 ;;
    esac
    return 0
}

pm_log() {
    [ "$#" -ge 1 ] || {
        printf 'paseo-monitor: log needs a watch id\n' >&2
        return 2
    }
    plg_id="$1"
    pm_validate_watch_id "$plg_id" || {
        printf 'paseo-monitor: invalid watch id: %s\n' "$plg_id" >&2
        return 2
    }
    shift
    plg_n=20
    plg_follow=0
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -n)
                [ "$#" -ge 2 ] || { printf 'paseo-monitor: -n needs a value\n' >&2; return 2; }
                pm_valid_uint "$2" || { printf 'paseo-monitor: -n must be an integer\n' >&2; return 2; }
                plg_n="$2"
                shift 2
                ;;
            -f) plg_follow=1; shift ;;
            *) printf 'paseo-monitor: unknown log option: %s\n' "$1" >&2; return 2 ;;
        esac
    done
    plg_path="$PM_HOME/watches/$plg_id/log"
    [ -f "$plg_path" ] || plg_path="$PM_HOME/graveyard/$plg_id/log"
    [ -f "$plg_path" ] || [ -f "$plg_path.1" ] || {
        printf 'paseo-monitor: log not found for watch: %s\n' "$plg_id" >&2
        return 1
    }
    if [ "$plg_follow" -eq 1 ]; then
        [ -f "$plg_path" ] || {
            printf 'paseo-monitor: log not found for watch: %s\n' "$plg_id" >&2
            return 1
        }
        tail -n "$plg_n" -f "$plg_path"
    elif [ -f "$plg_path.1" ] && [ -f "$plg_path" ]; then
        cat "$plg_path.1" "$plg_path" | tail -n "$plg_n"
    elif [ -f "$plg_path" ]; then
        tail -n "$plg_n" "$plg_path"
    else
        tail -n "$plg_n" "$plg_path.1"
    fi
}

pm_teardown_watch() {
    # pm_teardown_watch <dir> -- release a watch's outside-world claims before
    # the directory goes away. Reports the cancellation ONLY when the watch
    # still owed one: a watch that already fired, or that legitimately went
    # quiet at terminal/expiry, has nothing further to say and reporting it
    # would be noise. A watch removed while still active and never having
    # fired leaves a caller waiting forever, which is the gap worth closing.
    ptw_dir="$1"
    ptw_state="$(cat "$ptw_dir/state" 2>/dev/null || printf 'active')"
    ptw_fires="$(cat "$ptw_dir/fires" 2>/dev/null || printf '0')"
    pm_valid_uint "$ptw_fires" || ptw_fires=0
    pm_clear_failsafe "$ptw_dir" || :
    case "$ptw_state" in terminal|expired) return 0 ;; esac
    [ "$ptw_fires" -eq 0 ] || return 0
    ptw_last="$(cat "$ptw_dir/last" 2>/dev/null || printf 'UNOBSERVED')"
    pm_report_event "$ptw_dir" cancelled "$ptw_last" CANCELLED \
        "watch removed before it reported; last observation $ptw_last" || {
        printf 'paseo-monitor: WARN cancellation report undelivered for %s\n' \
            "$(basename "$ptw_dir")" >&2
        [ -f "$ptw_dir/undelivered" ] && cat "$ptw_dir/undelivered" >&2
    }
    return 0
}

pm_archive_watch() {
    # pm_archive_watch <live-watch-dir> -- retain all evidence and routing.
    paw_dir="$1"
    paw_id="$(basename "$paw_dir")"
    paw_dest="$PM_HOME/graveyard/$paw_id"
    [ ! -e "$paw_dest" ] || return 1
    mv "$paw_dir" "$paw_dest" || return 1
    pm_atomic_write "$paw_dest/graveyard" removed || return 1
    ln -s "../graveyard/$paw_id" "$PM_HOME/watches/$paw_id" || return 1
    return 0
}

pm_rm() {
    [ "$#" -eq 1 ] || {
        printf 'paseo-monitor: rm needs <id>, --all, or --all-agents\n' >&2
        return 2
    }
    pm_init_state || return 1
    prm_mode="$1"
    case "$prm_mode" in
        --all|--all-agents)
            prm_count=0
            prm_caller="${PASEO_AGENT_ID:-}"
            if [ "$prm_mode" = --all ] && [ -z "$prm_caller" ]; then
                printf 'paseo-monitor: refusing rm --all without PASEO_AGENT_ID; use --all-agents for global removal\n' >&2
                return 1
            fi
            acquire_lock "$PM_HOME" || return 1
            trap 'release_lock "$PM_HOME"' 0 1 2 3 15
            if [ "$prm_mode" = --all-agents ]; then
                printf 'cross-owner removal authorized by --all-agents; no interactive prompt used\n'
                for prm_dir in "$PM_HOME"/watches/*; do
                    [ -f "$prm_dir/spec" ] || continue
                    pm_is_graveyard "$prm_dir" && continue
                    printf 'will-remove watch=%s owner=%s report_to=%s target=%s\n' \
                        "$(basename "$prm_dir")" "$(pm_watch_owner "$prm_dir")" \
                        "$(pm_spec_value report_to "$prm_dir/spec")" "$(pm_watch_target "$prm_dir")"
                done
            fi
            for prm_dir in "$PM_HOME"/watches/*; do
                [ -f "$prm_dir/spec" ] || continue
                pm_is_graveyard "$prm_dir" && continue
                prm_owner="$(pm_watch_owner_key "$prm_dir")"
                [ "$prm_mode" = --all-agents ] || [ "$prm_owner" = "$prm_caller" ] || continue
                prm_id="$(basename "$prm_dir")"
                prm_report_to="$(pm_spec_value report_to "$prm_dir/spec")"
                prm_target="$(pm_watch_target "$prm_dir")"
                prm_owner_display="$(pm_watch_owner "$prm_dir")"
                pm_teardown_watch "$prm_dir"
                pm_archive_watch "$prm_dir" || {
                    printf 'paseo-monitor: could not archive watch: %s\n' "$prm_id" >&2
                    return 1
                }
                printf 'removed watch=%s owner=%s report_to=%s target=%s\n' \
                    "$prm_id" "$prm_owner_display" "$prm_report_to" "$prm_target"
                prm_count=$((prm_count + 1))
            done
            printf 'removed %s watch(es)\n' "$prm_count"
            return 0
            ;;
    esac
    prm_id="$prm_mode"
    pm_validate_watch_id "$prm_id" || {
        printf 'paseo-monitor: invalid watch id: %s\n' "$prm_id" >&2
        return 2
    }
    prm_dir="$PM_HOME/watches/$prm_id"
    [ -f "$prm_dir/spec" ] || {
        printf 'paseo-monitor: watch not found: %s\n' "$prm_id" >&2
        return 1
    }
    prm_caller="${PASEO_AGENT_ID:-}"
    prm_owner="$(pm_watch_owner_key "$prm_dir")"
    [ "$prm_owner" = "$prm_caller" ] || {
        printf 'paseo-monitor: refusing cross-owner deletion watch=%s owner=%s; use --all-agents for global removal\n' \
            "$prm_id" "$(pm_watch_owner "$prm_dir")" >&2
        return 1
    }
    acquire_lock "$PM_HOME" || return 1
    trap 'release_lock "$PM_HOME"' 0 1 2 3 15
    prm_report_to="$(pm_spec_value report_to "$prm_dir/spec")"
    prm_target="$(pm_watch_target "$prm_dir")"
    prm_owner_display="$(pm_watch_owner "$prm_dir")"
    pm_teardown_watch "$prm_dir"
    pm_archive_watch "$prm_dir" || {
        printf 'paseo-monitor: could not archive watch: %s\n' "$prm_id" >&2
        return 1
    }
    printf 'removed watch=%s owner=%s report_to=%s target=%s\n' \
        "$prm_id" "$prm_owner_display" "$prm_report_to" "$prm_target"
}

pm_reap() {
    pm_init_state || return 1
    acquire_lock "$PM_HOME" || return 1
    trap 'release_lock "$PM_HOME"' 0 1 2 3 15
    preap_now="$(pm_now)"
    preap_retention=2592000
    preap_count=0
    for preap_dir in "$PM_HOME"/watches/*; do
        [ -f "$preap_dir/spec" ] || continue
        pm_is_graveyard "$preap_dir" && continue
        preap_state="$(cat "$preap_dir/state" 2>/dev/null || printf '')"
        case "$preap_state" in terminal|expired) ;; *) continue ;; esac
        preap_deadline="$(pm_spec_value deadline "$preap_dir/spec")"
        pm_valid_uint "$preap_deadline" || continue
        [ "$preap_now" -ge "$preap_deadline" ] || continue
        [ "$((preap_now - preap_deadline))" -ge "$preap_retention" ] || continue
        pm_clear_failsafe "$preap_dir" || :
        rm -rf "$preap_dir"
        preap_count=$((preap_count + 1))
    done
    for preap_dir in "$PM_HOME"/graveyard/*; do
        [ -d "$preap_dir" ] || continue
        [ -f "$preap_dir/spec" ] || continue
        preap_deadline="$(pm_spec_value deadline "$preap_dir/spec")"
        pm_valid_uint "$preap_deadline" || continue
        [ "$preap_now" -ge "$preap_deadline" ] || continue
        [ "$((preap_now - preap_deadline))" -ge "$preap_retention" ] || continue
        preap_id="$(basename "$preap_dir")"
        rm -rf "$preap_dir"
        rm -f "$PM_HOME/watches/$preap_id"
        preap_count=$((preap_count + 1))
    done
    printf 'reaped %s watch(es)\n' "$preap_count"
}


pm_poke() {
    [ "$#" -eq 1 ] || {
        printf 'paseo-monitor: poke needs a watch id\n' >&2
        return 2
    }
    pm_init_state || return 1
    pmp_id="$1"
    pm_validate_watch_id "$pmp_id" || {
        printf 'paseo-monitor: invalid watch id: %s\n' "$pmp_id" >&2
        return 2
    }
    pmp_dir="$PM_HOME/watches/$1"
    [ -f "$pmp_dir/spec" ] || {
        printf 'paseo-monitor: watch not found: %s\n' "$1" >&2
        return 1
    }
    acquire_lock "$PM_HOME" || return 1
    trap 'release_lock "$PM_HOME"' 0 1 2 3 15
    pmp_state="$(cat "$pmp_dir/state" 2>/dev/null || printf 'active')"
    [ "$pmp_state" = parked ] && {
        set_state "$pmp_dir" active || :
        log_line "$pmp_dir" POKE "resumed parked watch" || :
    }
    pm_atomic_write "$pmp_dir/nextDue" 0 || :
    pm_sweep_watch "$pmp_dir"
}


if [ "${PM_SOURCE_ONLY:-0}" -ne 1 ]; then
    if [ "$(id -u)" = 0 ]; then
        printf 'paseo-monitor: refusing to run as root\n' >&2
        exit 1
    fi
    case "${1:-help}" in
        version|--version)
            printf 'paseo-monitor %s\n' "$PM_VERSION"
            ;;
        help|--help|-h)
            usage
            ;;
        watch)
            shift
            pm_watch_main "$@"
            ;;
        kinds)
            pm_kinds
            ;;
        ls)
            pm_ls
            ;;
        _sweep)
            pm_sweep
            ;;
        status)
            shift
            pm_status "$@"
            ;;
        poke)
            shift
            pm_poke "$@"
            ;;
        log)
            shift
            pm_log "$@"
            ;;
        rm)
            shift
            pm_rm "$@"
            ;;
        reap)
            shift
            pm_reap "$@"
            ;;
        *)
            printf 'paseo-monitor: unknown subcommand: %s\n' "$1" >&2
            printf 'Try paseo-monitor --help.\n' >&2
            exit 2
            ;;
    esac
fi
