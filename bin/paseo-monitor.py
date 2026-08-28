#!/usr/bin/env python3
"""Python foundation for paseo-monitor.

This module deliberately grows beside the shell entrypoint.  P5 owns the public
CLI cutover; the functions here are the durable state, probe, and sweep
primitives that can read watches written by the shell implementation.
"""

from __future__ import print_function

import argparse
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
import uuid
import zlib
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from pathlib import Path


TIMESTAMP_FORMAT = "%Y-%m-%dT%H:%M:%S%z"
SPEC_KEYS = (
    "kind", "report_to", "owner", "provider", "interval", "deadline",
    "registered", "terminal", "report_on", "with_reason",
    "report_transitions", "dwell", "prohibit", "failsafe", "max_runs",
    "expires_in", "max_fires", "exhausted", "start_report", "deliver",
    "deliver_mode", "python", "helper", "reason", "script", "host",
    "job", "task", "agent", "path", "remote", "ref", "repo", "pr",
    "labels",
)
STDOUT_CAP = 4096
STDERR_CAP = 8192
SWEEP_PARALLELISM = 4


def _uint(value, default):
    if value is None or value == "" or not str(value).isdigit():
        return default
    return int(value)


@dataclass(frozen=True)
class Config:
    """Internal startup configuration; external names are read only here."""

    home: Path
    log_max_bytes: int = 5242880
    lock_grace_seconds: int = 5
    backoff_scale: int = 1
    fast_sweep: bool = False
    probe_timeout: int = 45
    context_max: int = 512
    sweep_parallelism: int = SWEEP_PARALLELISM

    @classmethod
    def from_env(cls, environ=None):
        env = os.environ if environ is None else environ
        home = env.get("PASEO_MONITOR_HOME") or os.path.join(
            env.get("HOME", os.path.expanduser("~")), ".paseo-monitor"
        )
        fast = env.get("PASEO_MONITOR_FAST_SWEEP", "0")
        return cls(
            home=Path(home),
            log_max_bytes=_uint(env.get("PASEO_MONITOR_LOG_MAX_BYTES", "5242880"), 5242880),
            lock_grace_seconds=_uint(env.get("PASEO_MONITOR_LOCK_GRACE_SECONDS", "5"), 5),
            backoff_scale=_uint(env.get("PASEO_MONITOR_BACKOFF_SCALE", "1"), 1),
            fast_sweep=fast in ("1", 1),
            probe_timeout=_uint(env.get("PASEO_MONITOR_PROBE_TIMEOUT", "45"), 45),
        )


# This is the sole startup read. Runtime functions receive CONFIG or use these
# immutable aliases; they do not inspect PASEO_MONITOR_* themselves.
CONFIG = Config.from_env()
PM_HOME = CONFIG.home
PM_LOG_MAX_BYTES = CONFIG.log_max_bytes
PM_LOCK_GRACE_SECONDS = CONFIG.lock_grace_seconds
PM_BACKOFF_SCALE = CONFIG.backoff_scale
PM_FAST_SWEEP = int(CONFIG.fast_sweep)
PM_PROBE_TIMEOUT = CONFIG.probe_timeout
PM_SWEEP_PARALLELISM = CONFIG.sweep_parallelism


@dataclass(frozen=True)
class ProbeResult:
    returncode: int
    stdout: bytes
    stderr: bytes
    timed_out: bool = False


@dataclass(frozen=True)
class ProbeObservation:
    token: str
    detail: str


@dataclass(frozen=True)
class SweepResult:
    skipped: bool = False
    processed: int = 0


class AgentResolutionError(RuntimeError):
    def __init__(self, message, code=2):
        super().__init__(message)
        self.code = code


_TZ_LOCK = threading.Lock()
def timestamp(epoch=None):
    """DST-correct New York time without zoneinfo (works on Python 3.8)."""
    with _TZ_LOCK:
        previous = os.environ.get("TZ")
        os.environ["TZ"] = "America/New_York"
        time.tzset()
        try:
            return time.strftime(TIMESTAMP_FORMAT, time.localtime(epoch))
        finally:
            if previous is None:
                os.environ.pop("TZ", None)
            else:
                os.environ["TZ"] = previous
            time.tzset()


def _as_bytes(content, newline=True):
    if isinstance(content, bytes):
        return content + (b"\n" if newline else b"")
    value = str(content).encode("utf-8")
    return value + (b"\n" if newline else b"")


def atomic_write_bytes(path, content):
    """Install bytes with the shell-compatible temporary-file-plus-rename."""
    target = Path(path)
    target.parent.mkdir(parents=True, exist_ok=True)
    temporary = target.parent / (".tmp.%s.%s" % (os.getpid(), target.name))
    try:
        with open(str(temporary), "wb") as handle:
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(str(temporary), str(target))
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


def atomic_write(path, content):
    atomic_write_bytes(path, _as_bytes(content))


def pm_atomic_write(path, content):
    return atomic_write(path, content)


def set_state(directory, state):
    try:
        atomic_write(Path(directory) / "state", state)
        return True
    except OSError:
        return False


def ensure_dirs(directory):
    root = Path(directory)
    (root / "watches").mkdir(parents=True, exist_ok=True)
    (root / "graveyard").mkdir(parents=True, exist_ok=True)
    return True


def load_config(environ=None):
    return Config.from_env(environ)


class Spec(dict):
    """Mapping with the original bytes needed for lossless persistence."""

    def __init__(self, *args, **kwargs):
        self.raw = kwargs.pop("raw", None)
        super().__init__(*args, **kwargs)
        self._snapshot = dict(self)


def read_spec(path):
    """Read shell spec key/value records, retaining values after the first =."""
    raw_bytes = Path(path).read_bytes()
    result = Spec(raw=raw_bytes)
    for raw in raw_bytes.splitlines():
        line = raw.decode("utf-8", "replace")
        if "=" in line:
            key, value = line.split("=", 1)
            if key not in result:
                result[key] = value
    result._snapshot = dict(result)
    return result


def serialize_spec(values):
    if isinstance(values, Spec) and values.raw is not None and dict(values) == values._snapshot:
        return values.raw
    if isinstance(values, (bytes, bytearray)):
        return bytes(values)
    keys = list(SPEC_KEYS) + [key for key in values if key not in SPEC_KEYS]
    items = []
    for key in keys:
        if key in values:
            items.append("%s=%s" % (key, values[key]))
    return ("\n".join(items) + "\n").encode("utf-8")


def write_spec(path, values):
    """Write canonical shell specs, or exact bytes when handed a byte string."""
    atomic_write_bytes(path, serialize_spec(values))


def update_spec(path, key, value):
    """Change one spec field without changing other fields or their order."""
    source = Path(path).read_bytes().splitlines(keepends=True)
    prefix = (str(key) + "=").encode("utf-8")
    replacement = (str(key) + "=" + str(value) + "\n").encode("utf-8")
    replaced = False
    output = []
    for line in source:
        if line.startswith(prefix):
            output.append(replacement)
            replaced = True
        else:
            output.append(line)
    if not replaced:
        output.append(replacement)
    atomic_write_bytes(path, b"".join(output))


def _log_path(directory, config=CONFIG):
    directory = Path(directory)
    return config.home / "sweep.log" if directory == config.home else directory / "log"


def rotate_log_if_big(directory, config=CONFIG):
    log = _log_path(directory, config)
    try:
        if log.is_file() and log.stat().st_size >= config.log_max_bytes:
            os.replace(str(log), str(log) + ".1")
    except OSError:
        return False
    return True


def log_line(directory, event, *details, **kwargs):
    config = kwargs.pop("config", CONFIG)
    log = _log_path(directory, config)
    Path(directory).mkdir(parents=True, exist_ok=True)
    line = "%s [%s] %s %s\n" % (timestamp(), os.getpid(), event, " ".join(str(x) for x in details))
    with open(str(log), "a", encoding="utf-8") as handle:
        handle.write(line)
    return rotate_log_if_big(directory, config)


def pm_log_path(directory, config=CONFIG):
    return str(_log_path(directory, config))


def pm_rotate_log_if_big(directory, config=CONFIG):
    return rotate_log_if_big(directory, config)


def _pid_alive(pid):
    try:
        os.kill(pid, 0)
    except (OSError, ValueError):
        return False
    return True


def lock_holder_alive(directory, config=CONFIG):
    lock = Path(directory) / "sweep.lock"
    if not lock.is_dir():
        return False
    pid_file = lock / "pid"
    if pid_file.is_file():
        try:
            value = pid_file.read_text(encoding="ascii").strip()
            if not value.isdigit():
                return False
            return _pid_alive(int(value))
        except (OSError, UnicodeError):
            return False
    try:
        return time.time() - lock.stat().st_mtime < config.lock_grace_seconds
    except OSError:
        return False


def _break_stale_lock(directory):
    root = Path(directory)
    lock = root / "sweep.lock"
    stale = root / ("sweep.lock.stale.%s" % os.getpid())
    try:
        os.replace(str(lock), str(stale))
    except OSError:
        return False
    shutil.rmtree(str(stale), ignore_errors=True)
    return True


def acquire_lock(directory, config=CONFIG):
    root = Path(directory)
    root.mkdir(parents=True, exist_ok=True)
    lock = root / "sweep.lock"
    try:
        lock.mkdir()
    except FileExistsError:
        if lock_holder_alive(root, config):
            return False
        _break_stale_lock(root)
        try:
            lock.mkdir()
        except FileExistsError:
            return False
    try:
        (lock / "pid").write_text("%s\n" % os.getpid(), encoding="ascii")
    except OSError:
        shutil.rmtree(str(lock), ignore_errors=True)
        return False
    return True


def release_lock(directory):
    lock = Path(directory) / "sweep.lock"
    if not lock.is_dir():
        return True
    pid_file = lock / "pid"
    try:
        if not pid_file.is_file() or pid_file.read_text(encoding="ascii").strip() != str(os.getpid()):
            return False
        shutil.rmtree(str(lock))
        return True
    except OSError:
        return False


def pm_acquire_lock(directory, config=CONFIG):
    return acquire_lock(directory, config)


def pm_release_lock(directory):
    return release_lock(directory)


def pm_lock_holder_alive(directory, config=CONFIG):
    return lock_holder_alive(directory, config)


def pm_ensure_dirs(directory):
    return ensure_dirs(directory)


def pm_now():
    return int(time.time())


def hash_jitter(watch_id, interval, config=CONFIG):
    if config.fast_sweep:
        return 0
    interval = max(int(interval), 1)
    return zlib.crc32(str(watch_id).encode("utf-8")) % interval


def next_due(now, interval, watch_id, config=CONFIG):
    now, interval = int(now), int(interval)
    return now if config.fast_sweep else now + interval + hash_jitter(watch_id, interval, config)


def _cap(data, limit):
    if data is None:
        return b""
    if isinstance(data, str):
        data = data.encode("utf-8", "replace")
    return data[:limit]


def run_probe(argv, timeout=None, config=CONFIG):
    """Execute argv directly with inherited env, /dev/null stdin, and caps."""
    if isinstance(argv, (str, bytes)) or not argv:
        raise TypeError("probe argv must be a non-empty sequence")
    seconds = config.probe_timeout if timeout is None else timeout
    try:
        completed = subprocess.run(
            list(argv), stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, timeout=seconds, check=False,
        )
        return ProbeResult(completed.returncode, _cap(completed.stdout, STDOUT_CAP),
                           _cap(completed.stderr, STDERR_CAP), False)
    except subprocess.TimeoutExpired as exc:
        return ProbeResult(124, _cap(exc.output, STDOUT_CAP), _cap(exc.stderr, STDERR_CAP), True)
    except OSError as exc:
        return ProbeResult(127, b"", _cap(str(exc), STDERR_CAP), False)


def run_with_timeout(seconds, stdout_path, stderr_path, *argv, **kwargs):
    config = kwargs.pop("config", CONFIG)
    result = run_probe(argv, timeout=seconds, config=config)
    Path(stdout_path).parent.mkdir(parents=True, exist_ok=True)
    Path(stderr_path).parent.mkdir(parents=True, exist_ok=True)
    Path(stdout_path).write_bytes(result.stdout)
    Path(stderr_path).write_bytes(result.stderr)
    return result.returncode


def pm_run_with_timeout(seconds, stdout_path, stderr_path, *argv, **kwargs):
    return run_with_timeout(seconds, stdout_path, stderr_path, *argv, **kwargs)


def parse_probe_output(source):
    data = Path(source).read_bytes() if isinstance(source, (str, os.PathLike)) else source
    if hasattr(data, "read"):
        data = data.read()
    if isinstance(data, str):
        data = data.encode("utf-8")
    line = data.splitlines()[0].decode("utf-8", "replace") if data.splitlines() else ""
    match = re.match(r"([^\s]+)(?:[ \t]+(.*))?$", line)
    if not match:
        raise ValueError("probe output is empty or has no token")
    return ProbeObservation(match.group(1), match.group(2) or "")


PM_PARSED_TOKEN = ""
PM_PARSED_DETAIL = ""


def pm_parse_probe_output(source):
    global PM_PARSED_TOKEN, PM_PARSED_DETAIL
    try:
        observation = parse_probe_output(source)
    except ValueError:
        return False
    PM_PARSED_TOKEN, PM_PARSED_DETAIL = observation.token, observation.detail
    return True


def _classify_ssh_error(text):
    lowered = text.lower()
    return "auth" if any(word in lowered for word in (
        "authentication", "permission denied", "permission", "auth ",
        "auth:", "passphrase", "password", "verification",
        "mfa", "keyboard-interactive",
    )) else "network"


def health_failure_class(returncode, stderr):
    text = stderr.decode("utf-8", "replace") if isinstance(stderr, bytes) else str(stderr)
    lowered = text.lower()
    if "env-unavailable" in lowered:
        return "env-unavailable"
    if returncode == 127:
        return "config"
    if returncode == 255 and any(word in lowered for word in (
        "authentication", "permission", "auth", "assword", "passphrase",
        "verification", "mfa", "keyboard-interactive",
    )):
        return "auth"
    return "network"


def pm_health_failure_class(returncode, stderr):
    return health_failure_class(returncode, stderr)


def run_remote_probe(stdout_path, stderr_path, host, *remote_argv, **kwargs):
    config = kwargs.pop("config", CONFIG)
    result = run_probe(("ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15", host) + remote_argv,
                       config=config)
    err = result.stderr.decode("utf-8", "replace")
    if result.returncode == 255:
        classification = _classify_ssh_error(err)
        err = "%s-class ssh-rc=255\n%s" % (classification, err)
    Path(stdout_path).parent.mkdir(parents=True, exist_ok=True)
    Path(stderr_path).parent.mkdir(parents=True, exist_ok=True)
    Path(stdout_path).write_bytes(result.stdout)
    Path(stderr_path).write_bytes(_cap(err, STDERR_CAP))
    return result.returncode


def pm_run_remote_probe(stdout_path, stderr_path, host, *remote_argv, **kwargs):
    return run_remote_probe(stdout_path, stderr_path, host, *remote_argv, **kwargs)


def _first_nonempty(lines):
    return next((line for line in lines if line.strip()), "")


def parse_slurm_probe_output(watch_dir, output_path):
    lines = Path(output_path).read_text(encoding="utf-8", errors="replace").splitlines()
    before, marker, after = [], False, []
    for line in lines:
        if line == "PASEO_MONITOR_SQUEUE":
            marker = True
            continue
        (after if marker else before).append(line)
    sacct = _first_nonempty(before)
    squeue = _first_nonempty(after)
    state = sacct or (squeue.split("|", 1)[0] if squeue else "")
    if "|" in state:
        state = state.split("|", 1)[-1].split("|", 1)[0]
    state = state.split()[0] if state.split() else ""
    if state:
        token, detail = state, "sacct=%s" % sacct
        if squeue:
            if squeue.split("|", 1)[0] == "PENDING" and "|" in squeue:
                token = "PENDING:" + squeue.split("|", 1)[1]
            detail += " squeue=%s" % squeue
    else:
        last_path = Path(watch_dir) / "last"
        last = last_path.read_text(
            encoding="utf-8", errors="replace"
        ).strip() if last_path.is_file() else ""
        detail_path = Path(watch_dir) / "detail"
        prior_detail = detail_path.read_text(
            encoding="utf-8", errors="replace"
        ) if detail_path.is_file() else ""
        queue_match = re.search(r"(?:^| )squeue=([^ ]*)", prior_detail)
        prior_queue = bool(queue_match and queue_match.group(1).split("|", 1)[0])
        if marker and last not in ("", "PENDING") and prior_queue:
            token, detail = "VANISHED", "sacct and squeue empty after last=%s" % last
        else:
            token, detail = "PENDING", "sacct empty (accounting lag); squeue=%s" % squeue
    atomic_write(output_path, "%s %s" % (token, detail))


def pm_slurm_probe_output(watch_dir, output_path):
    return parse_slurm_probe_output(watch_dir, output_path)


def parse_pbs_probe_output(watch_dir, output_path):
    lines = Path(output_path).read_text(encoding="utf-8", errors="replace").splitlines()
    marker = "PASEO_MONITOR_PBS_HISTORICAL"
    split = lines.index(marker) if marker in lines else len(lines)
    live, historical = lines[:split], lines[split + 1:]
    def state(rows):
        for row in rows:
            match = re.match(r"\s*job_state\s*=\s*(\S+)", row)
            if match:
                return match.group(1).split()[0].upper()
        return ""
    current = state(live)
    source, record = "qstat", live
    if not current and historical:
        current, source, record = state(historical), "qstat-x", historical
    if current:
        detail = "%s=%s" % (source, " ".join(record)[:384])
        atomic_write(output_path, "%s %s" % (current, detail))
    else:
        atomic_write(output_path, "UNKNOWN qstat live and historical lookup empty")


def _json_data(value):
    if hasattr(value, "read"):
        return json.load(value)
    if isinstance(value, os.PathLike):
        with open(str(value), "r", encoding="utf-8") as handle:
            return json.load(handle)
    if isinstance(value, (bytes, str)):
        text = value.decode("utf-8") if isinstance(value, bytes) else value
        if os.path.isfile(text):
            with open(text, "r", encoding="utf-8") as handle:
                return json.load(handle)
        return json.loads(text)
    return value


def _json_object(source):
    value = _json_data(source)
    if not isinstance(value, dict):
        raise ValueError("probe JSON must be an object")
    return value


def parse_agent_probe_output(source):
    """Map the observable paseo inspect fields to a stable watch token."""
    agent = _json_object(source)
    status = str(agent.get("Status", agent.get("status", "UNKNOWN"))).upper()
    archived = bool(agent.get("Archived", agent.get("archived", False)))
    archived = archived or bool(agent.get("ArchivedAt", agent.get("archivedAt", "")))
    permissions = agent.get("PendingPermissions", agent.get("pendingPermissions", []))
    if not isinstance(permissions, list):
        permissions = []
    updated = str(agent.get("UpdatedAt", agent.get("updatedAt", "")))
    token = "ARCHIVED" if archived else (
        "BLOCKED-PERMISSION" if permissions else status
    )
    prefix = "went idle " if token == "IDLE" else ""
    idle = " idle_since=%s" % updated if token == "IDLE" else ""
    detail = (
        "%sstatus=%s archived=%s pendingPermissions=%d queue_depth=%d "
        "updated_at=%s%s"
        % (prefix, status, str(archived).lower(), len(permissions),
           len(permissions), updated, idle)
    )
    return ProbeObservation(token, detail)


def parse_globus_probe_output(source):
    data = _json_object(source)

    def field(name):
        value = data.get(name, "")
        if value is None:
            return ""
        if isinstance(value, (dict, list)):
            return json.dumps(value, separators=(",", ":"))
        return str(value).replace("\n", " ")

    status = str(data.get("status", data.get("Status", "UNKNOWN"))).upper()
    if status not in ("ACTIVE", "INACTIVE", "SUCCEEDED", "FAILED"):
        status = "UNKNOWN"
    detail = "nice_status=%s faults=%s fatal_error=%s effective_bytes_per_second=%s" % (
        field("nice_status"), field("faults"), field("fatal_error"),
        field("effective_bytes_per_second"),
    )
    return ProbeObservation(status, detail)


def parse_git_ref_probe_output(watch_dir, output_path):
    lines = Path(output_path).read_text(
        encoding="utf-8", errors="replace"
    ).splitlines()
    line = _first_nonempty(lines)
    fields = line.split("\t")
    sha = fields[0] if fields else ""
    if not re.match(r"^[0-9A-Fa-f]+$", sha):
        raise ValueError("git ls-remote returned no SHA")
    ref = fields[1] if len(fields) > 1 else ""
    last_path = Path(watch_dir) / "last"
    old = last_path.read_text(encoding="utf-8", errors="replace").strip() if last_path.is_file() else ""
    if not old:
        old = sha
    detail = "old=%s new=%s ref=%s observed=%s" % (old, sha, ref, line)
    return ProbeObservation(sha, detail)


def parse_pr_merge_probe_output(source):
    line = _first_nonempty(Path(source).read_text(
        encoding="utf-8", errors="replace"
    ).splitlines())
    if not line:
        raise ValueError("gh returned no pull request state")
    state = line.split()[0].upper()
    return ProbeObservation(state, "state=%s" % state)


def parse_file_exists_probe_output(path, observed_path):
    lines = Path(observed_path).read_text(
        encoding="utf-8", errors="replace"
    ).splitlines()
    return ProbeObservation("EXISTS", lines[0] if lines else str(path))


def pm_agent_probe_output(source):
    return parse_agent_probe_output(source)


def pm_globus_probe_output(source):
    return parse_globus_probe_output(source)


def pm_git_ref_probe_output(watch_dir, output_path):
    observation = parse_git_ref_probe_output(watch_dir, output_path)
    atomic_write(output_path, "%s %s" % (observation.token, observation.detail))
    return observation


def pm_pr_merge_probe_output(source):
    return parse_pr_merge_probe_output(source)




def match_agent(data, query):
    data = _json_data(data)
    if isinstance(data, dict):
        data = data.get("agents", [])
    matched = {}
    for agent in data if isinstance(data, list) else []:
        if not isinstance(agent, dict):
            continue
        aid, name = str(agent.get("id", "")), str(agent.get("name", ""))
        if query and aid.startswith(query):
            matched[aid] = agent
        elif name == query:
            matched[aid] = agent
    if len(matched) == 1:
        agent = next(iter(matched.values()))
        return "MATCH\t%s\t%s" % (agent.get("id", ""), agent.get("name", ""))
    if not matched:
        return "NONE"
    return "AMBIGUOUS\t" + "\t".join("%s (%s)" % (a.get("id", ""), a.get("name", "")) for a in matched.values())


def pm_match_agent(data, query):
    return match_agent(data, query)


def inspect_agent(data):
    agent = _json_data(data)
    if isinstance(agent, list):
        agent = agent[0] if agent else {}
    if not isinstance(agent, dict):
        raise ValueError("agent JSON must be an object")
    status = agent.get("Status", agent.get("status", "unknown"))
    archived = agent.get("Archived", agent.get("archived", False)) or bool(agent.get("ArchivedAt", agent.get("archivedAt", "")))
    permissions = agent.get("PendingPermissions", agent.get("pendingPermissions", []))
    if not isinstance(permissions, list):
        permissions = []
    return "%s %s %d" % (str(status).lower(), 1 if archived else 0, len(permissions))


def resolve_agent(query, allow_orphan=False, home=PM_HOME, paseo_bin="paseo"):
    try:
        result = subprocess.run([paseo_bin, "ls", "--json"], stdin=subprocess.DEVNULL,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=CONFIG.probe_timeout,
                                check=False)
    except OSError as exc:
        raise AgentResolutionError("paseo-monitor: paseo ls --json failed (daemon unreachable?)", 3) from exc
    if result.returncode != 0:
        raise AgentResolutionError("paseo-monitor: paseo ls --json failed (daemon unreachable?)", 3)
    tag = match_agent(result.stdout, query)
    if tag.startswith("MATCH\t"):
        _, aid, name = tag.split("\t", 2)
        return "%s\t%s" % (aid, name)
    if tag.startswith("AMBIGUOUS"):
        raise AgentResolutionError('paseo-monitor: ambiguous agent "%s"' % query)
    if allow_orphan and re.match(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", query):
        if (Path(home) / "watches" / query).is_dir():
            return query + "\t"
    raise AgentResolutionError('paseo-monitor: no agent matches "%s"' % query)


def resolve_binary(name, environ=None):
    """Resolve a helper once, returning an executable absolute path."""
    if not name:
        raise FileNotFoundError("empty helper name")
    if os.path.dirname(name):
        candidate = os.path.abspath(name)
        if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate
        raise FileNotFoundError(name)
    env = os.environ if environ is None else environ
    for directory in env.get("PATH", "").split(os.pathsep):
        directory = directory or os.curdir
        candidate = os.path.abspath(os.path.join(directory, name))
        if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate
    raise FileNotFoundError(name)


def _helper_for_kind(kind, spec):
    helper = spec.get("helper", "")
    if helper:
        return helper
    names = {"agent": "paseo", "globus": "globus", "pr-merge": "gh"}
    return resolve_binary(names[kind]) if kind in names else ""


def _shell_quote(value):
    import shlex
    return shlex.quote(str(value))


def _probe_helper(kind, spec, err):
    try:
        return _helper_for_kind(kind, spec)
    except FileNotFoundError:
        name = spec.get("helper") or {
            "agent": "paseo", "globus": "globus", "pr-merge": "gh"
        }.get(kind, kind)
        Path(err).write_text("required helper not found: %s\n" % name)
        return None


def _spec_probe(directory, spec, out, err, config):
    """Run exactly one registered probe and normalize its observation."""
    kind = spec.get("kind", "")
    if kind == "script":
        return run_with_timeout(
            config.probe_timeout, out, err, str(Path(directory) / "probe"),
            config=config,
        )
    if kind == "file-exists":
        if spec.get("host"):
            rc = run_remote_probe(
                out, err, spec["host"], "ls", "-d", spec.get("path", ""),
                config=config,
            )
        else:
            rc = run_with_timeout(
                config.probe_timeout, out, err, "ls", "-d",
                spec.get("path", ""), config=config,
            )
        if rc == 0:
            observation = parse_file_exists_probe_output(spec.get("path", ""), out)
            atomic_write(out, "%s %s" % (observation.token, observation.detail))
            return 0
        # A remote health failure is never mistaken for target absence.
        if spec.get("host") and rc == 255:
            return rc
        atomic_write(out, "ABSENT %s" % spec.get("path", ""))
        return 0
    if kind == "slurm":
        host, job = spec.get("host", ""), spec.get("job", "")
        if str(spec.get("with_reason", "")) in ("1", "true", "True"):
            quoted = _shell_quote(job)
            command = (
                "sacct -X -j %s --parsable2 --noheader --format=State; "
                "pr_sacct_rc=$?; printf '\\nPASEO_MONITOR_SQUEUE\\n'; "
                "squeue -h -j %s -o '%%T|%%R'; pr_squeue_rc=$?; "
                "[ $pr_sacct_rc -eq 0 ] && [ $pr_squeue_rc -eq 0 ]"
            ) % (quoted, quoted)
            rc = run_remote_probe(out, err, host, command, config=config)
        else:
            rc = run_remote_probe(
                out, err, host, "sacct", "-X", "-j", job, "--parsable2",
                "--noheader", "--format=State", config=config,
            )
        if rc == 0:
            parse_slurm_probe_output(directory, out)
        return rc
    if kind == "pbs":
        job = _shell_quote(spec.get("job", ""))
        command = (
            "qstat -f %s || { printf '\\nPASEO_MONITOR_PBS_HISTORICAL\\n'; "
            "qstat -x %s; :; }"
        ) % (job, job)
        rc = run_remote_probe(
            out, err, spec.get("host", ""), command, config=config
        )
        if rc == 0:
            parse_pbs_probe_output(directory, out)
        return rc
    if kind == "agent":
        helper = _probe_helper(kind, spec, err)
        if helper is None:
            return 127
        rc = run_with_timeout(
            config.probe_timeout, out, err, helper, "inspect",
            spec.get("agent", ""), "--json", config=config,
        )
        if rc == 0:
            observation = parse_agent_probe_output(out)
            atomic_write(out, "%s %s" % (observation.token, observation.detail))
        return rc
    if kind == "globus":
        helper = _probe_helper(kind, spec, err)
        if helper is None:
            return 127
        rc = run_with_timeout(
            config.probe_timeout, out, err, helper, "task", "show",
            spec.get("task", ""), "-F", "json",
            "--jq", "{status: .status, nice_status: .nice_status, faults: .faults, fatal_error: .fatal_error, effective_bytes_per_second: .effective_bytes_per_second}",
            config=config,
        )
        if rc == 0:
            observation = parse_globus_probe_output(out)
            atomic_write(out, "%s %s" % (observation.token, observation.detail))
        return rc
    if kind == "git-ref":
        rc = run_with_timeout(
            config.probe_timeout, out, err, "git", "ls-remote",
            spec.get("remote", ""), spec.get("ref", ""), config=config,
        )
        if rc == 0:
            observation = parse_git_ref_probe_output(directory, out)
            atomic_write(out, "%s %s" % (observation.token, observation.detail))
        return rc
    if kind == "pr-merge":
        helper = _probe_helper(kind, spec, err)
        if helper is None:
            return 127
        return run_with_timeout(
            config.probe_timeout, out, err, helper, "pr", "view",
            spec.get("pr", ""), "--repo", spec.get("repo", ""), "--json",
            "state", "--jq", ".state", config=config,
        )
    return 127


KIND_FLOORS = {
    "slurm": 120, "pbs": 120, "globus": 60, "agent": 60,
    "git-ref": 60, "pr-merge": 60, "script": 60,
}
DEFAULT_TERMINAL = (
    "COMPLETED,SUCCEEDED,FAILED,CANCELLED,TIMEOUT,ERROR,CLOSED,ARCHIVED,DONE"
)


def kind_floor(kind, host=""):
    if kind == "file-exists":
        return 120 if host else 60
    return KIND_FLOORS.get(kind, 60)


def kind_default_interval(kind, transitions=False, host=""):
    if kind in ("slurm", "pbs"):
        return 300 if transitions else 600
    if kind == "file-exists":
        return 120 if host else 60
    return {
        "globus": 300, "git-ref": 120, "pr-merge": 300,
    }.get(kind, 60)


def pm_kind_floor(kind, host=""):
    return kind_floor(kind, host)


def pm_kind_default_interval(kind, transitions=False, host=""):
    return kind_default_interval(kind, transitions, host)


def parse_deadline(value, now=None):
    now = pm_now() if now is None else int(now)
    text = str(value or "")
    if text.startswith("+") and text[1:].isdigit():
        return now + int(text[1:])
    if text.startswith("now+") and text[4:].isdigit():
        return now + int(text[4:])
    if text.isdigit():
        return int(text)
    raise ValueError("deadline must be epoch seconds, +seconds, or now+seconds")


def pm_parse_deadline(value, now=None):
    return parse_deadline(value, now)


def _truthy(value):
    return str(value).lower() in ("1", "true", "yes")


def prepare_registration(values, now=None):
    """Validate and complete a registration spec before any state is written."""
    spec = dict(values)
    kind = spec.get("kind", "")
    if kind not in set(KIND_FLOORS) | {"file-exists"}:
        raise ValueError("unknown kind: %s" % kind)
    if kind == "script":
        if not spec.get("reason"):
            raise ValueError("--reason is mandatory with --script")
        if "terminal" not in spec or not spec.get("terminal"):
            raise ValueError("--terminal is mandatory with --script")
        source = Path(str(spec.get("script", "")))
        if not source.is_file() or not os.access(str(source), os.X_OK):
            raise ValueError("script must be an executable file: %s" % source)
    required = {
        "slurm": ("host", "job"), "pbs": ("host", "job"),
        "globus": ("task",), "agent": ("agent",), "file-exists": ("path",),
        "git-ref": ("remote", "ref"), "pr-merge": ("repo", "pr"),
    }.get(kind, ())
    for key in required:
        if not spec.get(key):
            raise ValueError("%s needs %s" % (kind, " and ".join(required)))
    if kind == "script":
        spec["script"] = str(Path(str(spec["script"])).resolve())
    if kind == "agent":
        spec.setdefault("report_on", "BLOCKED-PERMISSION,CLOSED,ARCHIVED")
        spec.setdefault("dwell", "2")
        spec["report_transitions"] = "1"
    if kind == "pr-merge":
        terminal = [x for x in str(spec.get("terminal", DEFAULT_TERMINAL)).split(",") if x]
        for token in ("MERGED", "CLOSED"):
            if token not in terminal:
                terminal.append(token)
        spec["terminal"] = ",".join(terminal)
    elif kind == "file-exists":
        terminal = [x for x in str(spec.get("terminal", DEFAULT_TERMINAL)).split(",") if x]
        if "EXISTS" not in terminal:
            terminal.append("EXISTS")
        spec["terminal"] = ",".join(terminal)
    elif kind == "pbs":
        terminal = [x for x in str(spec.get("terminal", DEFAULT_TERMINAL)).split(",") if x]
        for token in ("C", "F"):
            if token not in terminal:
                terminal.append(token)
        spec["terminal"] = ",".join(terminal)
    else:
        spec.setdefault("terminal", DEFAULT_TERMINAL)
    transitions = _truthy(spec.get("report_transitions", False)) or bool(spec.get("report_on"))
    if ":" in str(spec.get("report_on", "")):
        spec["with_reason"] = "1"
    spec.setdefault("with_reason", "0")
    interval = spec.get("interval")
    interval = kind_default_interval(kind, transitions, spec.get("host", "")) if interval in (None, "") else _uint(interval, -1)
    if interval < 0 or str(interval) != str(spec.get("interval", interval)) and spec.get("interval") not in (None, ""):
        raise ValueError("interval must be an integer")
    if interval < kind_floor(kind, spec.get("host", "")):
        raise ValueError(
            "interval %s is below %s floor %s" % (interval, kind, kind_floor(kind, spec.get("host", "")))
        )
    spec["interval"] = str(interval)
    spec["deadline"] = str(parse_deadline(spec.get("deadline"), now))
    if int(spec["deadline"]) <= int(now):
        raise ValueError("deadline must be in the future")
    for key, default in (("dwell", "0"), ("max_fires", "0"), ("max_runs", "1")):
        if key not in spec or spec[key] in (None, ""):
            spec[key] = default
        if not pm_valid_uint(spec[key]):
            raise ValueError("%s must be an integer" % key.replace("_", "-"))
    if int(spec["max_runs"]) <= 0:
        raise ValueError("max-runs must be greater than zero")
    return spec


def register_watch(values, config=CONFIG, now=None, watch_id=None):
    """Create a durable watch only after its synchronous first probe succeeds."""
    now = pm_now() if now is None else int(now)
    spec = prepare_registration(values, now)
    ensure_dirs(config.home)
    watch_id = watch_id or str(uuid.uuid4())
    directory = Path(config.home) / "watches" / watch_id
    directory.mkdir(parents=False)
    try:
        kind = spec["kind"]
        if kind in ("agent", "globus", "pr-merge"):
            try:
                spec["helper"] = resolve_binary(spec.get("helper") or {
                    "agent": "paseo", "globus": "globus", "pr-merge": "gh"
                }[kind])
            except FileNotFoundError as exc:
                raise ValueError("required helper not found: %s" % (spec.get("helper") or {
                    "agent": "paseo", "globus": "globus", "pr-merge": "gh"
                }[kind])) from exc
        spec.setdefault("state", "active")
        spec.setdefault("registered", str(now))
        spec.setdefault("owner", "")
        spec.setdefault("report_to", "")
        write_spec(directory / "spec", spec)
        if kind == "script":
            target = directory / "probe"
            shutil.copyfile(spec["script"], str(target))
            target.chmod(0o700)
        atomic_write(directory / "context", spec.get("context", ""))
        atomic_write(directory / "fires", "0")
        atomic_write(directory / "health", "0 none")
        atomic_write(directory / "state", "active")
        out, err = directory / ".register.stdout", directory / ".register.stderr"
        rc = _spec_probe(directory, spec, out, err, config)
        if rc:
            message = err.read_text(encoding="utf-8", errors="replace") if err.is_file() else ""
            raise RuntimeError("registration probe failed (health rc=%s)%s" % (
                rc, ": %s" % message.strip() if message.strip() else ""
            ))
        observation = parse_probe_output(out)
        atomic_write(directory / "last", observation.token)
        atomic_write(directory / "detail", observation.detail)
        atomic_write(directory / "nextDue", next_due(now, int(spec["interval"]), watch_id, config))
        if observation.token in _terminal_tokens(spec):
            set_state(directory, "terminal")
        log_line(directory, "REGISTER", "token=%s" % observation.token,
                 "detail=%s" % observation.detail, config=config)
        return watch_id, observation
    except Exception:
        shutil.rmtree(str(directory), ignore_errors=True)
        raise
    finally:
        for path in (directory / ".register.stdout", directory / ".register.stderr"):
            try:
                path.unlink()
            except FileNotFoundError:
                pass


def pm_register_watch(values, config=CONFIG, now=None, watch_id=None):
    return register_watch(values, config=config, now=now, watch_id=watch_id)

def run_registered_probe(directory, stdout_path, stderr_path, config=CONFIG):
    directory = Path(directory)
    spec = read_spec(directory / "spec")
    kind = spec.get("kind", "")
    if kind in ("agent", "globus", "pr-merge") and not spec.get("helper"):
        try:
            helper = _helper_for_kind(kind, spec)
        except FileNotFoundError:
            return 127
        update_spec(directory / "spec", "helper", helper)
        spec["helper"] = helper
    return _spec_probe(directory, spec, Path(stdout_path), Path(stderr_path), config)


def pm_run_registered_probe(directory, stdout_path, stderr_path, config=CONFIG):
    return run_registered_probe(directory, stdout_path, stderr_path, config)


def pm_spec_value(key, path):
    return read_spec(path).get(key, "")


def pm_valid_uint(value):
    return bool(value is not None and str(value).isdigit())


def pm_hash_jitter(watch_id, interval, config=CONFIG):
    return hash_jitter(watch_id, interval, config)


def pm_next_due(now, interval, watch_id, config=CONFIG):
    return next_due(now, interval, watch_id, config)

def _terminal_tokens(spec):
    return set(token for token in spec.get("terminal", "").split(",") if token)


def event_class(old, new, terminal_tokens):
    if old == new:
        return None
    return "terminal" if new in terminal_tokens else "transition"


def _agent_dwell_accept(directory, spec, token):
    """Apply dwell only to agent RUNNING/IDLE observations."""
    if spec.get("kind") != "agent" or token not in ("IDLE", "RUNNING"):
        try:
            (Path(directory) / "dwell").unlink()
        except FileNotFoundError:
            pass
        return True
    dwell = _uint(spec.get("dwell", "0"), 0)
    if dwell <= 1:
        try:
            (Path(directory) / "dwell").unlink()
        except FileNotFoundError:
            pass
        return True
    directory = Path(directory)
    old = (directory / "last").read_text().strip() if (directory / "last").is_file() else ""
    if token == old:
        try:
            (directory / "dwell").unlink()
        except FileNotFoundError:
            pass
        return True
    saved = (directory / "dwell").read_text().strip().split() if (directory / "dwell").is_file() else []
    count = _uint(saved[1], 0) + 1 if len(saved) == 2 and saved[0] == token else 1
    if count < dwell:
        atomic_write(directory / "dwell", "%s %s" % (token, count))
        log_line(directory, "DWELL", token, "count=%s/%s" % (count, dwell))
        return False
    try:
        (directory / "dwell").unlink()
    except FileNotFoundError:
        pass
    return True


def _report_requested(spec, classification, token, old):
    if classification == "terminal":
        return True
    if token == "UNKNOWN" and old != "UNKNOWN":
        return True
    requested = set(x for x in spec.get("report_on", "").split(",") if x)
    return token in requested or _truthy(spec.get("report_transitions", False))


def _report_transition(directory, spec, classification, old, observation, config):
    if not _report_requested(spec, classification, observation.token, old):
        return
    limit = _uint(spec.get("max_fires", "0"), 0)
    fires_path = Path(directory) / "fires"
    fires = _uint(fires_path.read_text().strip(), 0) if fires_path.is_file() else 0
    exhausted_path = Path(directory) / "exhausted"
    if limit and fires >= limit:
        if not exhausted_path.is_file():
            log_line(directory, "REPORT", "class=exhausted", "old=%s" % old,
                     "new=MAX-FIRES-REACHED", config=config)
            atomic_write(exhausted_path, "1")
        log_line(directory, "SUPPRESSED", classification, "old=%s" % old,
                 "new=%s" % observation.token, config=config)
        return
    atomic_write(fires_path, str(fires + 1))
    log_line(directory, "REPORT", "class=%s" % classification,
             "old=%s" % old, "new=%s" % observation.token,
             observation.detail, config=config)


def _sweep_watch(directory, config=CONFIG):
    directory = Path(directory)
    spec_path = directory / "spec"
    if not spec_path.is_file() or (directory / "graveyard").is_file():
        return False
    spec = read_spec(spec_path)
    state = (directory / "state").read_text(
        encoding="utf-8"
    ).strip() if (directory / "state").is_file() else "active"
    if state in ("terminal", "expired", "parked"):
        return False
    now = pm_now()
    deadline = _uint(spec.get("deadline", ""), 0)
    if deadline and now >= deadline:
        old = (directory / "last").read_text().strip() if (directory / "last").is_file() else ""
        log_line(directory, "DEADLINE", "last=%s" % old, config=config)
        log_line(directory, "REPORT", "class=deadline", "old=%s" % old,
                 "new=DEADLINE", config=config)
        set_state(directory, "expired")
        return True
    due = _uint(
        (directory / "nextDue").read_text().strip()
        if (directory / "nextDue").is_file() else "0", 0
    )
    if now < due:
        return False
    out = directory / (".probe.stdout.%s" % os.getpid())
    err = directory / (".probe.stderr.%s" % os.getpid())
    try:
        rc = _spec_probe(directory, spec, out, err, config)
        stderr = err.read_text(
            encoding="utf-8", errors="replace"
        ) if err.is_file() else ""
        if rc:
            health_path = directory / "health"
            current = health_path.read_text().strip().split() if health_path.is_file() else ["0", "none"]
            count = _uint(current[0] if current else "0", 0) + 1
            classification = health_failure_class(rc, stderr)
            atomic_write(health_path, "%s %s" % (count, classification))
            log_line(directory, "PROBE-FAIL", "class=%s" % classification,
                     "count=%s" % count, "rc=%s" % rc, config=config)
            delay = _uint(spec.get("interval", "60"), 60) * min(count + 1, 8) * config.backoff_scale
            atomic_write(directory / "nextDue", now + delay)
            return True
        observation = parse_probe_output(out)
        old = (directory / "last").read_text().strip() if (directory / "last").is_file() else ""
        if not _agent_dwell_accept(directory, spec, observation.token):
            atomic_write(directory / "health", "0 healthy")
            interval = _uint(spec.get("interval", "60"), 60)
            atomic_write(directory / "nextDue", next_due(pm_now(), interval, directory.name, config))
            return True
        atomic_write(directory / "health", "0 healthy")
        atomic_write(directory / "last", observation.token)
        atomic_write(directory / "detail", observation.detail)
        classification = event_class(old, observation.token, _terminal_tokens(spec))
        if classification:
            log_line(directory, "TOKEN-CHANGE",
                     "%s -> %s" % (old, observation.token),
                     observation.detail, config=config)
            log_line(directory, "EVENT", "class=%s" % classification,
                     "old=%s" % old, "new=%s" % observation.token,
                     config=config)
            _report_transition(directory, spec, classification, old, observation, config)
            if classification == "terminal":
                set_state(directory, "terminal")
        interval = _uint(spec.get("interval", "60"), 60)
        atomic_write(directory / "nextDue", next_due(now, interval, directory.name, config))
        return True
    except (OSError, ValueError) as exc:
        log_line(directory, "PROBE-FAIL", "class=protocol",
                 "detail=%s" % exc, config=config)
        atomic_write(
            directory / "nextDue",
            next_due(now, _uint(spec.get("interval", "60"), 60), directory.name, config),
        )
        return True
    finally:
        for path in (out, err):
            try:
                path.unlink()
            except FileNotFoundError:
                pass


def pm_sweep_watch(directory, config=CONFIG):
    return _sweep_watch(directory, config)


def sweep(config=CONFIG):
    ensure_dirs(config.home)
    if not acquire_lock(config.home, config):
        return SweepResult(skipped=True, processed=0)
    try:
        watch_dirs = [path for path in (config.home / "watches").iterdir() if path.is_dir() and (path / "spec").is_file()]
        processed = 0
        with ThreadPoolExecutor(max_workers=config.sweep_parallelism) as executor:
            for changed in executor.map(lambda path: _sweep_watch(path, config), watch_dirs):
                processed += int(bool(changed))
        return SweepResult(skipped=False, processed=processed)
    finally:
        release_lock(config.home)


def pm_sweep(config=CONFIG):
    return sweep(config)


def refuse_root():
    return hasattr(os, "geteuid") and os.geteuid() == 0


def main(argv=None):
    if refuse_root():
        print("paseo-monitor: refusing to run as root", file=sys.stderr)
        return 1
    parser = argparse.ArgumentParser(prog="paseo-monitor.py")
    parser.add_argument("command", nargs="?", choices=("_sweep", "version"), default="_sweep")
    args = parser.parse_args(argv)
    if args.command == "version":
        print("v1.3.0")
        return 0
    result = sweep()
    return 0 if not result.skipped else 0


if __name__ == "__main__":
    sys.exit(main())
