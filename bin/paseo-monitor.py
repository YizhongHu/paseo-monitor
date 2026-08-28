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
        "authentication", "permission denied", "passphrase", "password",
        "verification", "mfa", "keyboard-interactive",
    )) else "network"


def health_failure_class(returncode, stderr):
    text = stderr.decode("utf-8", "replace") if isinstance(stderr, bytes) else str(stderr)
    lowered = text.lower()
    if "env-unavailable" in lowered:
        return "env-unavailable"
    if returncode == 127:
        return "config"
    if returncode == 255 and any(word in lowered for word in (
        "authentication", "permission", "auth", "assword", "passphrase", "verification",
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
    elif marker and (Path(watch_dir) / "last").read_text(encoding="utf-8", errors="replace").strip() not in ("", "PENDING"):
        token, detail = "VANISHED", "sacct and squeue empty after last=%s" % (Path(watch_dir) / "last").read_text().strip()
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


def pm_pbs_probe_output(watch_dir, output_path):
    return parse_pbs_probe_output(watch_dir, output_path)


def _json_data(value):
    if hasattr(value, "read"):
        return json.load(value)
    if isinstance(value, (bytes, str)):
        text = value.decode("utf-8") if isinstance(value, bytes) else value
        if os.path.isfile(text):
            with open(text, "r", encoding="utf-8") as handle:
                return json.load(handle)
        return json.loads(text)
    return value


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


def _spec_probe(directory, spec, out, err, config):
    kind = spec.get("kind", "")
    if kind == "script":
        return run_with_timeout(config.probe_timeout, out, err, str(Path(directory) / "probe"), config=config)
    if kind == "file-exists":
        if spec.get("host"):
            rc = run_remote_probe(out, err, spec["host"], "ls", "-d", spec.get("path", ""), config=config)
        else:
            rc = run_with_timeout(config.probe_timeout, out, err, "ls", "-d", spec.get("path", ""), config=config)
        if rc == 0:
            first = Path(out).read_text(encoding="utf-8", errors="replace").splitlines()
            atomic_write(out, "EXISTS %s" % (first[0] if first else spec.get("path", "")))
            return 0
        if spec.get("host") and rc == 255:
            return rc
        atomic_write(out, "ABSENT %s" % spec.get("path", ""))
        return 0
    if kind in ("slurm", "pbs"):
        if kind == "slurm":
            rc = run_remote_probe(out, err, spec.get("host", ""), "sacct", "-X", "-j", spec.get("job", ""), "--parsable2", "--noheader", "--format=State", config=config)
            if rc == 0:
                parse_slurm_probe_output(directory, out)
            return rc
        command = "qstat -f '%s' || { printf '\\nPASEO_MONITOR_PBS_HISTORICAL\\n'; qstat -x '%s'; :; }" % (spec.get("job", ""), spec.get("job", ""))
        rc = run_remote_probe(out, err, spec.get("host", ""), command, config=config)
        if rc == 0:
            parse_pbs_probe_output(directory, out)
        return rc
    return 127

def run_registered_probe(directory, stdout_path, stderr_path, config=CONFIG):
    spec = read_spec(Path(directory) / "spec")
    return _spec_probe(Path(directory), spec, Path(stdout_path), Path(stderr_path), config)


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


def _sweep_watch(directory, config=CONFIG):
    directory = Path(directory)
    spec_path = directory / "spec"
    if not spec_path.is_file() or (directory / "graveyard").is_file():
        return False
    spec = read_spec(spec_path)
    state = (directory / "state").read_text(encoding="utf-8").strip() if (directory / "state").is_file() else "active"
    if state in ("terminal", "expired", "parked"):
        return False
    now = pm_now()
    deadline = _uint(spec.get("deadline", ""), 0)
    if deadline and now >= deadline:
        old = (directory / "last").read_text(encoding="utf-8").strip() if (directory / "last").is_file() else ""
        log_line(directory, "DEADLINE", "last=%s" % old, config=config)
        set_state(directory, "expired")
        return True
    due = _uint((directory / "nextDue").read_text().strip() if (directory / "nextDue").is_file() else "0", 0)
    if now < due:
        return False
    out, err = directory / (".probe.stdout.%s" % os.getpid()), directory / (".probe.stderr.%s" % os.getpid())
    try:
        rc = _spec_probe(directory, spec, out, err, config)
        stderr = err.read_text(encoding="utf-8", errors="replace") if err.is_file() else ""
        if rc:
            health_path = directory / "health"
            current = health_path.read_text().strip().split() if health_path.is_file() else ["0", "none"]
            count = _uint(current[0] if current else "0", 0) + 1
            classification = health_failure_class(rc, stderr)
            atomic_write(health_path, "%s %s" % (count, classification))
            log_line(directory, "PROBE-FAIL", "class=%s" % classification, "count=%s" % count, "rc=%s" % rc, config=config)
            delay = _uint(spec.get("interval", "60"), 60) * min(count + 1, 8) * config.backoff_scale
            atomic_write(directory / "nextDue", now + delay)
            return True
        observation = parse_probe_output(out)
        old = (directory / "last").read_text(encoding="utf-8").strip() if (directory / "last").is_file() else ""
        atomic_write(directory / "health", "0 healthy")
        atomic_write(directory / "last", observation.token)
        atomic_write(directory / "detail", observation.detail)
        classification = event_class(old, observation.token, _terminal_tokens(spec))
        if classification:
            log_line(directory, "TOKEN-CHANGE", "%s -> %s" % (old, observation.token), observation.detail, config=config)
            log_line(directory, "EVENT", "class=%s" % classification, "old=%s" % old, "new=%s" % observation.token, config=config)
            if classification == "terminal":
                set_state(directory, "terminal")
        interval = _uint(spec.get("interval", "60"), 60)
        atomic_write(directory / "nextDue", next_due(pm_now(), interval, directory.name, config))
        return True
    except (OSError, ValueError) as exc:
        log_line(directory, "PROBE-FAIL", "class=protocol", "detail=%s" % exc, config=config)
        atomic_write(directory / "nextDue", next_due(pm_now(), _uint(spec.get("interval", "60"), 60), directory.name, config))
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
