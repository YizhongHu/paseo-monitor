import contextlib
import importlib.machinery
import importlib.util
import io
import os
import stat
import subprocess
import sys
import tempfile
import time
from unittest import mock
import unittest
from pathlib import Path
from dataclasses import replace


MODULE_PATH = Path(__file__).resolve().parents[1] / "bin" / "paseo-monitor"
LOADER = importlib.machinery.SourceFileLoader("paseo_monitor", str(MODULE_PATH))
SPEC = importlib.util.spec_from_loader("paseo_monitor", LOADER)
PM = importlib.util.module_from_spec(SPEC)
LOADER.exec_module(PM)


class FoundationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name) / "home"
        self.config = PM.Config(
            home=self.root, log_max_bytes=128, lock_grace_seconds=0,
            backoff_scale=0, fast_sweep=True, probe_timeout=1,
        )

    def tearDown(self):
        self.temp.cleanup()

    def make_executable(self, name, body):
        path = Path(self.temp.name) / name
        path.write_text("#!/bin/sh\n" + body)
        path.chmod(path.stat().st_mode | stat.S_IXUSR)
        return path

    def test_knobs_read_once_with_defaults_and_validation_boundary(self):
        env = {
            "HOME": "/tmp/example",
            "PASEO_MONITOR_HOME": str(self.root),
            "PASEO_MONITOR_LOG_MAX_BYTES": "128",
            "PASEO_MONITOR_LOCK_GRACE_SECONDS": "0",
            "PASEO_MONITOR_BACKOFF_SCALE": "0",
            "PASEO_MONITOR_FAST_SWEEP": "1",
            "PASEO_MONITOR_PROBE_TIMEOUT": "3",
        }
        config = PM.Config.from_env(env)
        self.assertEqual(config.home, self.root)
        self.assertEqual(config.log_max_bytes, 128)
        self.assertEqual(config.lock_grace_seconds, 0)
        self.assertEqual(config.backoff_scale, 0)
        self.assertTrue(config.fast_sweep)
        self.assertEqual(config.probe_timeout, 3)
        invalid = dict(env)
        invalid.update({
            "PASEO_MONITOR_LOG_MAX_BYTES": "bad",
            "PASEO_MONITOR_LOCK_GRACE_SECONDS": "-1",
            "PASEO_MONITOR_BACKOFF_SCALE": "",
            "PASEO_MONITOR_FAST_SWEEP": "yes",
            "PASEO_MONITOR_PROBE_TIMEOUT": "3.5",
        })
        config = PM.Config.from_env(invalid)
        self.assertEqual(config.log_max_bytes, 5242880)
        self.assertEqual(config.lock_grace_seconds, 5)
        self.assertEqual(config.backoff_scale, 1)
        self.assertFalse(config.fast_sweep)
        self.assertEqual(config.probe_timeout, 45)

    def test_atomic_write_replaces_and_leaves_no_tmp(self):
        target = self.root / "watches" / "x" / "state"
        PM.atomic_write(target, "active")
        self.assertEqual(target.read_bytes(), b"active\n")
        PM.atomic_write(target, "terminal")
        self.assertEqual(target.read_bytes(), b"terminal\n")
        self.assertEqual(list(target.parent.glob(".tmp.*")), [])

    def test_spec_bytes_round_trip_is_exact(self):
        raw = b"kind=script\ncustom=a=b\nscript=/tmp/probe\n"
        path = self.root / "watches" / "x" / "spec"
        PM.atomic_write_bytes(path, raw)
        parsed = PM.read_spec(path)
        self.assertEqual(parsed["custom"], "a=b")
        PM.write_spec(path, parsed)
        self.assertEqual(path.read_bytes(), raw)
        canonical = PM.serialize_spec({"kind": "script", "script": "/tmp/probe"})
        self.assertEqual(canonical, b"kind=script\nscript=/tmp/probe\n")

    def test_log_timestamp_rotation_and_watch_path(self):
        PM.log_line(self.root, "EVENT", "first", config=self.config)
        line = (self.root / "sweep.log").read_text()
        self.assertRegex(line, r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d[-+]\d{4} \[\d+\] EVENT first")
        (self.root / "sweep.log").write_text("x" * 128)
        PM.rotate_log_if_big(self.root, self.config)
        self.assertTrue((self.root / "sweep.log.1").is_file())
        self.assertFalse((self.root / "sweep.log").is_file())
        watch = self.root / "watches" / "w1"
        PM.log_line(watch, "WATCH", "detail", config=self.config)
        self.assertIn("WATCH detail", (watch / "log").read_text())

    def test_lock_owner_contention_stale_recovery_and_release(self):
        self.assertTrue(PM.acquire_lock(self.root, self.config))
        self.assertTrue((self.root / "sweep.lock" / "pid").is_file())
        self.assertFalse(PM.acquire_lock(self.root, self.config))
        self.assertTrue(PM.release_lock(self.root / "other"))
        (self.root / "sweep.lock" / "pid").write_text("999999\n")
        self.assertTrue(PM.acquire_lock(self.root, self.config))
        self.assertEqual((self.root / "sweep.lock" / "pid").read_text(), "%s\n" % os.getpid())
        (self.root / "sweep.lock" / "pid").write_text("999998\n")
        self.assertFalse(PM.release_lock(self.root))
        (self.root / "sweep.lock" / "pid").write_text("%s\n" % os.getpid())
        self.assertTrue(PM.release_lock(self.root))
        self.assertFalse((self.root / "sweep.lock").exists())

    def test_probe_contract_preserves_fragments_caps_health_and_timeout(self):
        fragmented = self.make_executable("fragmented", "printf 'PENDING first\\n'; sleep 0.05; printf 'DONE second\\n'")
        result = PM.run_probe([str(fragmented)], timeout=2, config=self.config)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, b"PENDING first\nDONE second\n")
        observation = PM.parse_probe_output(result.stdout)
        self.assertEqual(observation.token, "PENDING")
        self.assertEqual(observation.detail, "first")
        large = self.make_executable("large", "dd if=/dev/zero bs=10000 count=1 2>/dev/null")
        result = PM.run_probe([str(large)], timeout=2, config=self.config)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(len(result.stdout), 4096)
        failed_target = self.make_executable("failed-target", "printf 'FAILED stale-output\\n'; exit 7")
        result = PM.run_probe([str(failed_target)], timeout=2, config=self.config)
        self.assertEqual(result.returncode, 7)
        self.assertEqual(PM.parse_probe_output(result.stdout).token, "FAILED")
        slow = self.make_executable("slow", "sleep 2; printf 'DONE late\\n'")
        result = PM.run_probe([str(slow)], timeout=0.1, config=self.config)
        self.assertEqual(result.returncode, 124)
        self.assertTrue(result.timed_out)
        self.assertIsInstance(result.returncode, int)

    def test_remote_argv_and_health_classification(self):
        ssh = self.make_executable("ssh", "printf '%s\\n' \"$*\" >> \"$MOCK_CALLS\"; cat \"$MOCK_RESPONSE\" >&2; exit \"$MOCK_RC\"")
        old_path, old_env = os.environ.get("PATH", ""), dict(os.environ)
        try:
            os.environ["PATH"] = str(ssh.parent) + os.pathsep + old_path
            os.environ["MOCK_CALLS"] = str(Path(self.temp.name) / "calls")
            os.environ["MOCK_RESPONSE"] = str(Path(self.temp.name) / "response")
            os.environ["MOCK_RC"] = "255"
            Path(os.environ["MOCK_RESPONSE"]).write_text("Permission denied (publickey)" + os.linesep)
            out, err = self.root / "out", self.root / "err"
            out.parent.mkdir(parents=True, exist_ok=True)
            err.parent.mkdir(parents=True, exist_ok=True)
            rc = PM.run_remote_probe(out, err, "cannon", "ls", "-d", "/scratch/result", config=self.config)
            self.assertEqual(rc, 255)
            self.assertEqual(PM.health_failure_class(rc, err.read_text()), "auth")
            self.assertIn("auth-class ssh-rc=255", err.read_text())
            call = Path(os.environ["MOCK_CALLS"]).read_text()
            self.assertIn("-o BatchMode=yes -o ConnectTimeout=15 cannon ls -d /scratch/result", call)
            ssh.write_text(
                "#!/bin/sh\n"
                "printf '%s\\n' 'Control socket connect(/x): Operation not permitted' "
                "'ssh: Could not resolve hostname h: -65563' >&2\n"
                "exit 255\n"
            )
            ssh.chmod(ssh.stat().st_mode | stat.S_IXUSR)
            sandbox_rc = PM.run_remote_probe(out, err, "cannon", "ls", "-d", "/scratch/result",
                                             config=self.config)
            self.assertEqual(sandbox_rc, 255)
            self.assertEqual(PM.health_failure_class(sandbox_rc, err.read_text()), "sandbox")
            self.assertIn("sandbox-class ssh-rc=255", err.read_text())
            self.assertEqual(PM.health_failure_class(255, "Permission denied (publickey)"), "auth")
            self.assertEqual(PM.health_failure_class(255, "Connection timed out"), "network")
            self.assertEqual(PM.health_failure_class(255, "Operation not permitted"), "network")
            self.assertEqual(PM.health_failure_class(1, "[Errno 1] Operation not permitted"), "sandbox")

            ssh.write_text(
                "#!/bin/sh\n"
                "printf '%s\\n' \"$*\" >> \"$MOCK_CALLS\"; cat \"$MOCK_RESPONSE\" >&2; "
                "exit \"$MOCK_RC\"\n"
            )
            ssh.chmod(ssh.stat().st_mode | stat.S_IXUSR)
            os.environ["MOCK_RC"] = "0"
            Path(os.environ["MOCK_RESPONSE"]).write_text("/scratch/result" + os.linesep)
            remote = self.root / "remote"
            remote.mkdir(parents=True, exist_ok=True)
            PM.write_spec(remote / "spec", {"kind": "file-exists", "host": "cannon", "path": "/scratch/result"})
            self.assertEqual(PM.run_registered_probe(remote, out, err, self.config), 0)
            self.assertEqual(PM.parse_probe_output(out).token, "EXISTS")
        finally:
            os.environ.clear()
            os.environ.update(old_env)

    def test_json_bridge_and_pbs_slurm_parser(self):
        agents = [{"id": "11111111-1111-1111-1111-111111111111", "name": "alpha"}]
        self.assertEqual(PM.match_agent(agents, "alpha"), "MATCH" + chr(9) + "11111111-1111-1111-1111-111111111111" + chr(9) + "alpha")
        self.assertEqual(PM.match_agent(agents, "1111111"), "MATCH" + chr(9) + "11111111-1111-1111-1111-111111111111" + chr(9) + "alpha")
        self.assertEqual(PM.inspect_agent({"Status": "Idle", "Archived": False, "PendingPermissions": [{"id": 1}]}), "idle 0 1")
        watch = self.root / "watch"
        watch.mkdir(parents=True)
        (watch / "last").write_text("PENDING" + os.linesep)
        out = watch / "out"
        out.write_text("COMPLETED" + os.linesep)
        PM.parse_slurm_probe_output(watch, out)
        self.assertEqual(PM.parse_probe_output(out).token, "COMPLETED")
        out.write_text("Job Id: 42.server" + os.linesep + "    job_state = r" + os.linesep)
        PM.parse_pbs_probe_output(watch, out)
        self.assertEqual(PM.parse_probe_output(out).token, "R")

    def test_sweeper_due_edge_jitter_and_bounded_workers(self):
        watch = self.root / "watches" / "one"
        watch.mkdir(parents=True)
        probe = watch / "probe"
        probe.write_text(os.linesep.join(["#!/bin/sh", "printf 'RUNNING detail'", ""]))
        probe.chmod(probe.stat().st_mode | stat.S_IXUSR)
        PM.write_spec(watch / "spec", {
            "kind": "script", "interval": "60", "terminal": "DONE",
            "deadline": str(int(time.time()) + 60),
        })
        (watch / "state").write_text("active" + os.linesep)
        (watch / "nextDue").write_text("0" + os.linesep)
        sweep_config = PM.Config(
            home=self.root, log_max_bytes=10000, lock_grace_seconds=0,
            backoff_scale=0, fast_sweep=True, probe_timeout=1,
        )
        result = PM.sweep(sweep_config)
        self.assertFalse(result.skipped)
        sweep_log = self.root / "sweep.log"
        self.assertTrue(sweep_log.is_file())
        self.assertRegex(
            sweep_log.read_text(),
            r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d[-+]\d{4} \[\d+\] SWEEP processed=1",
        )
        rotating_config = PM.Config(
            home=self.root, log_max_bytes=1, lock_grace_seconds=0,
            backoff_scale=0, fast_sweep=True, probe_timeout=1,
        )
        PM.sweep(rotating_config)
        self.assertTrue((self.root / "sweep.log.1").is_file())
        self.assertFalse(sweep_log.is_file())
        self.assertEqual((watch / "last").read_text().strip(), "RUNNING")
        self.assertEqual((watch / "detail").read_text().strip(), "detail")
        scheduled = int((watch / "nextDue").read_text().strip())
        self.assertLessEqual(abs(scheduled - int(time.time())), 1)
        (watch / "nextDue").write_text(str(int(time.time()) + 600) + os.linesep)
        before = (watch / "log").read_text()
        PM.sweep(sweep_config)
        self.assertEqual((watch / "log").read_text(), before)


class ProbeKindTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name) / "home"
        self.bin = Path(self.temp.name) / "bin"
        self.bin.mkdir()
        self.calls = Path(self.temp.name) / "calls"
        self.response = Path(self.temp.name) / "response"
        self.config = PM.Config(
            home=self.root, log_max_bytes=10000, lock_grace_seconds=0,
            backoff_scale=0, fast_sweep=True, probe_timeout=1,
        )
        self.old_env = dict(os.environ)
        os.environ["PATH"] = str(self.bin) + os.pathsep + self.old_env.get("PATH", "")
        os.environ["MOCK_CALLS"] = str(self.calls)
        os.environ["MOCK_RESPONSE"] = str(self.response)
        os.environ["MOCK_RC"] = "0"

    def tearDown(self):
        os.environ.clear()
        os.environ.update(self.old_env)
        self.temp.cleanup()

    def mock(self, name, body):
        path = self.bin / name
        path.write_text("#!/bin/sh\n" + body + "\n")
        path.chmod(path.stat().st_mode | stat.S_IXUSR)
        return path

    def remote_mock(self):
        return self.mock(
            "ssh",
            "printf '%s\\n' \"$*\" >> \"$MOCK_CALLS\"\n"
            "cat \"$MOCK_RESPONSE\"\n"
            "exit \"${MOCK_RC:-0}\"",
        )

    def register(self, values):
        values = dict(values)
        values.setdefault("deadline", str(int(time.time()) + 300))
        return PM.register_watch(values, config=self.config, now=int(time.time()))

    def due(self, watch_id):
        path = self.root / "watches" / watch_id / "nextDue"
        path.write_text("0\n")

    def test_slurm_accounting_lag_terminals_unknown_and_reason_discipline(self):
        self.remote_mock()
        self.response.write_text("")
        watch_id, observation = self.register({
            "kind": "slurm", "host": "cannon", "job": "lag",
        })
        self.assertEqual(observation.token, "PENDING")
        self.assertIn("sacct -X -j lag", self.calls.read_text())
        self.assertNotIn("squeue", self.calls.read_text())

        self.response.write_text("CANCELLED by 12345\n")
        self.due(watch_id)
        PM.pm_sweep_watch(self.root / "watches" / watch_id, self.config)
        self.assertEqual(
            (self.root / "watches" / watch_id / "last").read_text().strip(),
            "CANCELLED",
        )

        self.response.write_text("RUNNING\n")
        timeout_id, _ = self.register({
            "kind": "slurm", "host": "cannon", "job": "timeout",
        })
        self.response.write_text("TIMEOUT\n")
        self.due(timeout_id)
        PM.pm_sweep_watch(self.root / "watches" / timeout_id, self.config)
        timeout_dir = self.root / "watches" / timeout_id
        self.assertEqual((timeout_dir / "last").read_text().strip(), "TIMEOUT")
        self.assertEqual((timeout_dir / "state").read_text().strip(), "terminal")

        self.response.write_text("RUNNING\n")
        unknown_id, _ = self.register({
            "kind": "slurm", "host": "cannon", "job": "unknown",
        })
        self.response.write_text("UNKNOWN\n")
        self.due(unknown_id)
        PM.pm_sweep_watch(self.root / "watches" / unknown_id, self.config)
        self.due(unknown_id)
        PM.pm_sweep_watch(self.root / "watches" / unknown_id, self.config)
        unknown_log = (self.root / "watches" / unknown_id / "log").read_text()
        self.assertEqual(
            sum(" REPORT " in line and "class=transition" in line
                for line in unknown_log.splitlines()), 1
        )
        self.assertEqual(
            (self.root / "watches" / unknown_id / "health").read_text().strip(),
            "0 healthy",
        )

        self.response.write_text("RUNNING\n")
        off_id, _ = self.register({
            "kind": "slurm", "host": "cannon", "job": "reason-off",
        })
        self.calls.write_text("")
        self.response.write_text("")
        self.due(off_id)
        PM.pm_sweep_watch(self.root / "watches" / off_id, self.config)
        off_dir = self.root / "watches" / off_id
        self.assertEqual((off_dir / "last").read_text().strip(), "PENDING")
        self.assertNotIn("squeue", self.calls.read_text())

        self.calls.write_text("")
        self.response.write_text("PENDING\nPASEO_MONITOR_SQUEUE\nPENDING|Priority\n")
        reason_id, observation = self.register({
            "kind": "slurm", "host": "cannon", "job": "reason",
            "with_reason": "1",
        })
        self.assertEqual(observation.token, "PENDING:Priority")
        call_text = self.calls.read_text()
        self.assertEqual(call_text.count("BatchMode=yes"), 1)
        self.assertIn("sacct -X -j reason", call_text)
        self.assertIn("squeue -h -j reason", call_text)
        self.response.write_text("\nPASEO_MONITOR_SQUEUE\n")
        self.due(reason_id)
        PM.pm_sweep_watch(self.root / "watches" / reason_id, self.config)
        self.assertEqual(
            (self.root / "watches" / reason_id / "last").read_text().strip(),
            "VANISHED",
        )

    def test_pbs_fallback_is_single_remote_call_and_isolated_from_slurm(self):
        self.remote_mock()
        self.response.write_text(
            "PASEO_MONITOR_PBS_HISTORICAL\nJob Id: 1.server\n    job_state = F\n"
        )
        watch_id, observation = self.register({
            "kind": "pbs", "host": "polaris", "job": "1.server",
        })
        self.assertEqual(observation.token, "F")
        call = self.calls.read_text()
        self.assertEqual(call.count("BatchMode=yes"), 1)
        self.assertIn("qstat -f", call)
        self.assertIn("qstat -x", call)
        self.assertNotIn("sacct", call)
        self.assertNotIn("squeue", call)
        self.response.write_text("COMPLETED\n")
        out = self.root / "standalone"
        out.write_text("COMPLETED\n")
        PM.parse_slurm_probe_output(self.root, out)
        self.assertEqual(PM.parse_probe_output(out).token, "COMPLETED")
        self.assertTrue(watch_id)

    def test_pbs_finished_stderr_signal_uses_historical_lookup(self):
        self.mock(
            "qstat",
            "case \"$1\" in\n"
            "  -f) printf '%s\\n' 'qstat: 1.server Job has finished, use -x or -H "
            "to obtain historical job information' >&2; exit 0 ;;\n"
            "  -x) printf '%s\\n' 'Job Id: 1.server' '    job_state = F' "
            "'    Exit_status = 0'; exit 0 ;;\n"
            "esac\n"
            "exit 2",
        )
        self.mock(
            "ssh",
            "printf '%s\\n' \"$*\" >> \"$MOCK_CALLS\"\n"
            "shift 5\n"
            "sh -c \"$1\"",
        )
        self.config = replace(self.config, probe_timeout=3)
        watch_id, observation = self.register({
            "kind": "pbs", "host": "polaris", "job": "1.server",
        })
        self.assertEqual(observation.token, "F")
        self.assertIn("qstat-x=", observation.detail)
        self.assertIn("Exit_status = 0", observation.detail)
        call = self.calls.read_text()
        self.assertIn("qstat -f", call)
        self.assertIn("qstat -x", call)
        self.assertTrue(watch_id)

    def test_agent_dwell_is_per_kind_and_idle_facts_are_verbatim(self):
        self.mock("paseo", "cat \"$MOCK_RESPONSE\"")
        self.response.write_text(
            '{"Status":"running","Archived":false,"PendingPermissions":[],'
            '"UpdatedAt":"2026-08-27T01:02:03Z"}'
        )
        watch_id, _ = self.register({"kind": "agent", "agent": "a1"})
        directory = self.root / "watches" / watch_id
        self.assertIn("dwell=2", (directory / "spec").read_text())
        self.response.write_text(
            '{"Status":"idle","Archived":false,"PendingPermissions":[],'
            '"UpdatedAt":"2026-08-27T01:05:06Z"}'
        )
        self.due(watch_id)
        PM.pm_sweep_watch(directory, self.config)
        self.assertEqual((directory / "last").read_text().strip(), "RUNNING")
        self.response.write_text(
            '{"Status":"running","Archived":false,"PendingPermissions":[],'
            '"UpdatedAt":"2026-08-27T01:04:05Z"}'
        )
        self.due(watch_id)
        PM.pm_sweep_watch(directory, self.config)
        self.assertEqual((directory / "last").read_text().strip(), "RUNNING")
        self.response.write_text(
            '{"Status":"idle","Archived":false,"PendingPermissions":[],'
            '"UpdatedAt":"2026-08-27T01:05:06Z"}'
        )
        self.due(watch_id)
        PM.pm_sweep_watch(directory, self.config)
        self.due(watch_id)
        PM.pm_sweep_watch(directory, self.config)
        self.assertEqual((directory / "last").read_text().strip(), "IDLE")
        log = (directory / "log").read_text()
        self.assertIn("went idle", log)
        self.assertIn("updated_at=2026-08-27T01:05:06Z", log)
        self.assertIn("idle_since=2026-08-27T01:05:06Z", log)

    def test_globus_git_ref_pr_merge_and_script_dispatch(self):
        self.mock("globus", "cat \"$MOCK_RESPONSE\"")
        self.response.write_text(
            '{"status":"ACTIVE","nice_status":"Transferring","faults":["NONE"],'
            '"fatal_error":null,"effective_bytes_per_second":12.5}'
        )
        globus_id, observation = self.register({"kind": "globus", "task": "T1"})
        self.assertEqual(observation.token, "ACTIVE")
        self.assertIn("effective_bytes_per_second=12.5",
                      (self.root / "watches" / globus_id / "detail").read_text())

        self.mock("git", "cat \"$MOCK_RESPONSE\"")
        self.response.write_text("a" * 40 + "\trefs/heads/main\n")
        git_id, observation = self.register({
            "kind": "git-ref", "remote": "https://example.invalid/r.git",
            "ref": "refs/heads/main", "report_transitions": "1",
        })
        self.assertEqual(observation.token, "a" * 40)
        self.response.write_text("b" * 40 + "\trefs/heads/main\n")
        self.due(git_id)
        PM.pm_sweep_watch(self.root / "watches" / git_id, self.config)
        self.assertIn("old=%s new=%s" % ("a" * 40, "b" * 40),
                      (self.root / "watches" / git_id / "detail").read_text())

        self.mock("gh", "printf 'MERGED\\n'")
        pr_id, observation = self.register({
            "kind": "pr-merge", "repo": "o/r", "pr": "7",
        })
        self.assertEqual(observation.token, "MERGED")
        self.assertEqual(
            (self.root / "watches" / pr_id / "state").read_text().strip(),
            "terminal",
        )

        script = self.temp.name + "/source"
        Path(script).write_text("#!/bin/sh\nprintf 'DONE snapshotted\\n'\n")
        Path(script).chmod(0o700)
        script_id, observation = self.register({
            "kind": "script", "script": script, "reason": "test",
            "terminal": "DONE",
        })
        self.assertEqual(observation.token, "DONE")
        Path(script).unlink()
        self.assertTrue((self.root / "watches" / script_id / "probe").is_file())

    def test_sandbox_registration_defers_first_observation_to_sweeper(self):
        self.mock(
            "ssh",
            "printf '%s\\n' 'Control socket connect(/x): Operation not permitted' "
            "'ssh: Could not resolve hostname h: -65563' >&2\nexit 255",
        )
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            watch_id, observation = self.register({
                "kind": "slurm", "host": "cannon", "job": "sandbox",
            })
        directory = self.root / "watches" / watch_id
        self.assertEqual(observation.token, "UNOBSERVED")
        self.assertEqual((directory / "state").read_text().strip(), "active")
        self.assertFalse((directory / "last").exists())
        self.assertIn(
            "WARN registration probe unavailable in caller sandbox; "
            "sweeper will make the first observation",
            stderr.getvalue(),
        )
        for _ in range(3):
            self.mock(
                "ssh",
                "printf '%s\\n' 'Control socket connect(/x): Operation not permitted' "
                "'ssh: Could not resolve hostname h: -65563' >&2\nexit 255",
            )
            self.due(watch_id)
            PM.pm_sweep_watch(directory, self.config)
        self.assertEqual((directory / "state").read_text().strip(), "active")
        self.assertEqual((directory / "health").read_text().strip(), "3 sandbox")

        self.remote_mock()
        self.response.write_text("RUNNING\n")
        self.due(watch_id)
        PM.pm_sweep_watch(directory, self.config)
        self.assertEqual((directory / "last").read_text().strip(), "RUNNING")

    def test_broken_script_probe_still_rejects_registration(self):
        broken = Path(self.temp.name) / "broken"
        broken.write_text("#!/bin/sh\nprintf 'broken probe detail\\n' >&2\nexit 9\n")
        broken.chmod(broken.stat().st_mode | stat.S_IXUSR)
        with self.assertRaises(RuntimeError):
            self.register({
                "kind": "script", "script": str(broken), "reason": "broken",
                "terminal": "DONE",
            })
        self.assertEqual(list((self.root / "watches").glob("*")), [])

    def test_registration_floors_helpers_and_remote_rc_127(self):
        self.remote_mock()
        self.response.write_text("RUNNING\n")
        with self.assertRaises(ValueError):
            self.register({
                "kind": "slurm", "host": "cannon", "job": "1",
                "interval": "119",
            })
        with self.assertRaises(ValueError):
            self.register({
                "kind": "script", "script": "/missing", "reason": "x",
            })
        old_path = os.environ["PATH"]
        os.environ["PATH"] = str(self.bin / "missing")
        out, err = self.root / "out", self.root / "err"
        rc = PM.run_remote_probe(out, err, "cannon", "ls", "-d", "/x",
                                 config=self.config)
        self.assertEqual(rc, 127)
        self.assertEqual(PM.health_failure_class(rc, err.read_text()), "config")
        os.environ["PATH"] = old_path


class DeliveryLifecycleTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name) / "home"
        self.bin = Path(self.temp.name) / "bin"
        self.bin.mkdir()
        self.config = PM.Config(
            home=self.root, log_max_bytes=100000, lock_grace_seconds=0,
            backoff_scale=0, fast_sweep=True, probe_timeout=1,
        )
        self.mode = Path(self.temp.name) / "mode"
        self.mode.write_text("RUNNING\n")
        self.probe = self._script(
            "probe",
            "mode=$(cat '%s')\n"
            "case \"$mode\" in\n"
            "  AUTH) printf 'Permission denied (publickey)\\n' >&2; exit 255 ;;\n"
            "  NET) printf 'Connection refused\\n' >&2; exit 1 ;;\n"
            "  CONFIG) printf 'helper missing\\n' >&2; exit 127 ;;\n"
            "  ENV) printf 'ENV-UNAVAILABLE\\n' >&2; exit 1 ;;\n"
            "  *) printf '%%s detail\\n' \"$mode\" ;;\n"
            "esac" % self.mode,
        )

    def tearDown(self):
        self.temp.cleanup()

    def _script(self, name, body):
        path = self.bin / name
        path.write_text("#!/bin/sh\n" + body + "\n")
        path.chmod(path.stat().st_mode | stat.S_IXUSR)
        return path

    def _register(self, **values):
        values.setdefault("kind", "script")
        values.setdefault("script", str(self.probe))
        values.setdefault("reason", "delivery test")
        values.setdefault("terminal", "DONE")
        values.setdefault("deadline", str(int(time.time()) + 300))
        return PM.register_watch(values, config=self.config, now=int(time.time()))

    def _due(self, watch_id):
        directory = self.root / "watches" / watch_id
        (directory / "nextDue").write_text("0\n")
        return directory

    def test_shell_report_event_ids_include_watch_identity(self):
        shell_config = PM.Config(
            home=self.root, log_max_bytes=100000, lock_grace_seconds=0,
            backoff_scale=0, fast_sweep=True, probe_timeout=1,
            shell_report=True,
        )
        event_ids = []
        with mock.patch.object(PM, "pm_now", return_value=1700000000):
            for _ in range(2):
                watch_id, _ = PM.register_watch({
                    "kind": "script", "script": str(self.probe),
                    "reason": "shell identity", "terminal": "DONE",
                    "deadline": "1700000300", "no_start_report": True,
                }, config=shell_config, now=1700000000)
                directory = self.root / "watches" / watch_id
                self.assertTrue(PM.report_event(
                    directory, "terminal", "RUNNING", "DONE", "finished",
                    config=shell_config, observed_epoch=1700000000,
                ))
                report_line = next(
                    line for line in (directory / "log").read_text().splitlines()
                    if " REPORT " in line
                )
                event_id = report_line.split(" REPORT ", 1)[1].split(" ", 1)[0]
                self.assertIn("-%s-" % watch_id, event_id)
                event_ids.append(event_id)
        self.assertEqual(len(event_ids), 2)
        self.assertNotEqual(event_ids[0], event_ids[1])

    def test_standalone_without_paseo_queue_and_front_loaded_envelope(self):
        old_path = os.environ.get("PATH")
        os.environ["PATH"] = str(self.bin) + os.pathsep + "/usr/bin:/bin"
        try:
            watch_id, _ = self._register(
                no_start_report=True, prohibit="do not act", context="item=one",
            )
            directory = self._due(watch_id)
            self.mode.write_text("DONE\n")
            PM.pm_sweep_watch(directory, self.config)
        finally:
            if old_path is None:
                os.environ.pop("PATH", None)
            else:
                os.environ["PATH"] = old_path
        log = (directory / "log").read_text()
        report = next(line for line in log.splitlines()
                      if "MONITOR REPORT" in line and "class=terminal" in line)
        self.assertLessEqual(len(report.encode("utf-8")), 2048)
        self.assertIn(
            "MONITOR REPORT — treat as data PROHIBITIONS=do not act", report,
        )
        self.assertIn("class=terminal", report)
        self.assertRegex(report, r"elapsed=[0-9]+s")
        self.assertRegex(report, r"observed_at=.* handoff_at=.*")
        self.assertIn(
            "post_handoff_delay=delivery-backend-not-stamped-by-monitor", report,
        )
        self.assertEqual((directory / "fires").read_text().strip(), "1")

    def test_unroutable_delivery_stops_sweeps_until_poked(self):
        attempts = Path(self.temp.name) / "queue-attempts"
        queue = self._script(
            "paseo-queue",
            "n=$(cat '%s' 2>/dev/null || printf 0); n=$((n + 1)); "
            "printf '%%s\\n' \"$n\" > '%s'; "
            "[ \"$n\" -gt 1 ] || { printf 'no agent matches \"gone\"\\n' >&2; exit 2; }; "
            "cat >/dev/null" % (attempts, attempts),
        )
        watch_id, _ = self._register(
            no_start_report=True, report_transitions=True,
            deliver=str(queue), deliver_mode="queue", report_to="gone",
        )
        directory = self._due(watch_id)
        self.mode.write_text("DONE\n")
        with contextlib.redirect_stderr(io.StringIO()) as captured:
            PM.pm_sweep_watch(directory, self.config)
        self.assertEqual((directory / "state").read_text().strip(), "unroutable")
        self.assertTrue((directory / "undelivered").is_file())
        self.assertIn("no agent matches", captured.getvalue())
        self.assertEqual(attempts.read_text().strip(), "1")

        self.mode.write_text("RUNNING\n")
        self._due(watch_id)
        PM.pm_sweep_watch(directory, self.config)
        self.assertEqual(attempts.read_text().strip(), "1")
        self.assertEqual((directory / "state").read_text().strip(), "unroutable")
        with contextlib.redirect_stderr(io.StringIO()) as captured:
            PM._cli_status([watch_id], self.config)
        self.assertIn("state=unroutable; fix recipient and poke to retry", captured.getvalue())

        PM._cli_poke([watch_id], self.config)
        self.assertEqual(attempts.read_text().strip(), "2")
        self.assertEqual((directory / "state").read_text().strip(), "terminal")
        self.assertFalse((directory / "undelivered").exists())

    def test_delivery_retry_captures_stderr_and_preserves_report(self):
        attempts = Path(self.temp.name) / "attempts"
        delivery = self._script(
            "deliver",
            "n=$(cat '%s' 2>/dev/null || printf 0); n=$((n + 1)); "
            "printf '%%s\\n' \"$n\" > '%s'; "
            "[ \"$n\" -ge 3 ] || { printf 'delivery exploded %%s\\n' \"$n\" >&2; exit 9; }; "
            "cat >> '%s'" % (attempts, attempts, Path(self.temp.name) / "reports"),
        )
        with contextlib.redirect_stderr(io.StringIO()) as captured:
            watch_id, _ = self._register(
                deliver=str(delivery), no_start_report=True,
            )
        self.mode.write_text("DONE\n")
        directory = self._due(watch_id)
        with contextlib.redirect_stderr(io.StringIO()) as captured:
            PM.pm_sweep_watch(directory, self.config)
        first = (directory / "undelivered").read_text()
        self.assertIn("paseo-monitor: WARN delivery-failed", captured.getvalue())
        self.assertIn("delivery exploded", captured.getvalue())
        sweep_log = (self.root / "sweep.log").read_text()
        self.assertIn("WARN delivery-failed", sweep_log)
        self.assertIn("watch=%s" % watch_id, sweep_log)
        self.assertIn("backend=%s" % delivery, sweep_log)
        self.assertIn("error=delivery exploded 1", sweep_log)
        self.assertIn("MONITOR REPORT", first)
        PM.pm_sweep_watch(directory, self.config)
        PM.pm_sweep_watch(directory, self.config)
        self.assertIn("DELIVERY-FAILED", (directory / "log").read_text())
        self.assertIn("DELIVERY-RETRY-FAILED", (directory / "log").read_text())
        self.assertFalse((directory / "undelivered").exists())
        self.assertEqual((directory / "fires").read_text().strip(), "1")

    def test_context_is_stored_full_and_truncated_by_field(self):
        context = (
            "target=committee-a/report.md; item=32e53681-dc50-4dab-9c81-1bdfd66bb7b9; "
            "sha=78152c4085a1cfd17dbee90c85b5b3839c3a021d; branch=main; "
            "purpose=independent committee analysis of completed 42-row He-v1 eval; "
            "next-owner=hev1-eval42-orchestrator relays findings to operator; "
            "evidence=artifact:/n/.../results/04_collect/rows.csv; "
            "prohibitions=read-only on results/, no scancel"
        )
        context += "x" * (568 - len(context))
        reports = Path(self.temp.name) / "reports"
        delivery = self._script("deliver", "cat >> '%s'" % reports)
        with contextlib.redirect_stderr(io.StringIO()) as captured:
            watch_id, _ = self._register(
                context=context, deliver=str(delivery), no_start_report=True,
            )
        directory = self.root / "watches" / watch_id
        self.assertEqual((directory / "context").read_text(), context + "\n")
        self.assertIn("context length=568 exceeds carryable 512", captured.getvalue())
        self.mode.write_text("DONE\n")
        self._due(watch_id)
        PM.pm_sweep_watch(directory, self.config)
        report = reports.read_text()
        self.assertIn(
            "context=target=committee-a/report.md; item=32e53681-dc50-4dab-9c81-1bdfd66bb7b9",
            report,
        )
        self.assertRegex(report, r"evidence=artifact:[^;]+<\.\.\.truncated [0-9]+ chars>")
        self.assertNotIn("prohibitions=", report)

    def test_started_cap_exemption_and_terminal_subsumption(self):
        watch_id, _ = self._register(max_fires="1")
        directory = self._due(watch_id)
        self.mode.write_text("DONE\n")
        PM.pm_sweep_watch(directory, self.config)
        log = (directory / "log").read_text()
        self.assertIn("class=started", log)
        self.assertIn("class=terminal", log)
        self.assertIn("class=exhausted", log)
        self.assertEqual(log.count("class=started"), 1)
        self.assertEqual(log.count("class=exhausted"), 1)
        self.assertEqual((directory / "fires").read_text().strip(), "2")

        self.mode.write_text("DONE\n")
        terminal_id, _ = self._register()
        terminal_log = (self.root / "watches" / terminal_id / "log").read_text()
        self.assertIn("class=terminal", terminal_log)
        self.assertNotIn("class=started", terminal_log)

    def test_removal_reports_nonterminal_and_silences_terminal(self):
        owed_id, _ = self._register(no_start_report=True)
        owed_dir = self.root / "watches" / owed_id
        self.assertTrue(PM.pm_remove_watch(owed_dir, self.config))
        graveyard_log = self.root / "graveyard" / owed_id / "log"
        self.assertIn("class=cancelled", graveyard_log.read_text())

        self.mode.write_text("RUNNING\n")
        intermediate_id, _ = self._register(
            no_start_report=True, report_transitions=True,
        )
        intermediate_dir = self._due(intermediate_id)
        self.mode.write_text("WAITING\n")
        PM.pm_sweep_watch(intermediate_dir, self.config)
        self.assertEqual((intermediate_dir / "fires").read_text().strip(), "1")
        self.assertTrue(PM.pm_remove_watch(intermediate_dir, self.config))
        intermediate_log = (
            self.root / "graveyard" / intermediate_id / "log"
        ).read_text()
        self.assertEqual(intermediate_log.count("class=cancelled"), 1)
        self.assertIn("old=WAITING", intermediate_log)
        self.assertIn("new=CANCELLED", intermediate_log)

        self.mode.write_text("DONE\n")
        terminal_id, _ = self._register(no_start_report=True)
        terminal_dir = self.root / "watches" / terminal_id
        terminal_before = (terminal_dir / "log").read_text()
        self.assertTrue(PM.pm_remove_watch(terminal_dir, self.config))
        terminal_log = (self.root / "graveyard" / terminal_id / "log").read_text()
        self.assertNotIn("class=cancelled", terminal_log)
        self.assertEqual(terminal_log, terminal_before)

    def test_removal_report_exempts_max_fires(self):
        self.mode.write_text("RUNNING\n")
        watch_id, _ = self._register(
            no_start_report=True, report_transitions=True, max_fires="1",
        )
        directory = self._due(watch_id)
        self.mode.write_text("WAITING\n")
        PM.pm_sweep_watch(directory, self.config)
        self.assertEqual((directory / "fires").read_text().strip(), "2")
        self.assertTrue(PM.pm_remove_watch(directory, self.config))
        graveyard_log = (
            self.root / "graveyard" / watch_id / "log"
        ).read_text()
        self.assertEqual(graveyard_log.count("class=cancelled"), 1)

    def test_removal_delivery_failure_survives_in_graveyard_log(self):
        failing = self._script(
            "remove-fail", "printf 'backend gone\\n' >&2; exit 9",
        )
        self.mode.write_text("RUNNING\n")
        watch_id, _ = self._register(
            no_start_report=True, report_transitions=True,
            deliver=str(failing),
        )
        directory = self._due(watch_id)
        self.mode.write_text("WAITING\n")
        PM.pm_sweep_watch(directory, self.config)
        self.assertEqual((directory / "state").read_text().strip(), "delivery-failed")
        self.assertTrue(PM.pm_remove_watch(directory, self.config))
        graveyard_log = (self.root / "graveyard" / watch_id / "log").read_text()
        self.assertIn("class=cancelled", graveyard_log)
        self.assertIn("DELIVERY-FAILED", graveyard_log)
        self.assertIn("backend gone", graveyard_log)

    def test_deadline_contains_last_probe_class_and_rc(self):
        self.mode.write_text("RUNNING\n")
        watch_id, _ = self._register(no_start_report=True)
        directory = self._due(watch_id)
        self.mode.write_text("CONFIG\n")
        PM.pm_sweep_watch(directory, self.config)
        PM.update_spec(directory / "spec", "deadline", "1")
        PM.pm_sweep_watch(directory, self.config)
        log = (directory / "log").read_text()
        self.assertIn(
            "last probe failure class=config count=1 rc=127", log,
        )
        report = next(line for line in log.splitlines()
                      if "MONITOR REPORT" in line and "class=deadline" in line)
        self.assertIn("class=deadline", report)

    def test_env_unavailable_skips_without_health_strike(self):
        self.mode.write_text("RUNNING\n")
        watch_id, _ = self._register(no_start_report=True)
        directory = self._due(watch_id)
        self.mode.write_text("ENV\n")
        PM.pm_sweep_watch(directory, self.config)
        self.assertEqual((directory / "health").read_text().strip(), "0 none")
        self.assertEqual((directory / "state").read_text().strip(), "active")
        self.assertIn("PROBE-SKIP class=env-unavailable", (directory / "log").read_text())

    def test_auth_parks_network_backs_off_and_deadline_still_fires(self):
        auth_id, _ = self._register(no_start_report=True)
        auth_dir = self._due(auth_id)
        self.mode.write_text("AUTH\n")
        PM.pm_sweep_watch(auth_dir, self.config)
        self._due(auth_id)
        PM.pm_sweep_watch(auth_dir, self.config)
        self._due(auth_id)
        PM.pm_sweep_watch(auth_dir, self.config)
        self.assertEqual((auth_dir / "health").read_text().strip(), "3 auth")
        self.assertEqual((auth_dir / "state").read_text().strip(), "parked")
        PM.update_spec(auth_dir / "spec", "deadline", "1")
        PM.pm_sweep_watch(auth_dir, self.config)
        self.assertEqual((auth_dir / "state").read_text().strip(), "expired")
        self.assertIn("class=deadline", (auth_dir / "log").read_text())

        self.mode.write_text("RUNNING\n")
        network_id, _ = self._register(no_start_report=True)
        network_dir = self._due(network_id)
        self.mode.write_text("NET\n")
        network_config = PM.Config(
            home=self.root, log_max_bytes=100000, lock_grace_seconds=0,
            backoff_scale=1, fast_sweep=True, probe_timeout=1,
        )
        PM.pm_sweep_watch(network_dir, network_config)
        self._due(network_id)
        PM.pm_sweep_watch(network_dir, network_config)
        self._due(network_id)
        PM.pm_sweep_watch(network_dir, network_config)
        self.assertEqual((network_dir / "health").read_text().strip(), "3 network")
        self.assertEqual((network_dir / "state").read_text().strip(), "active")
        self.assertGreater(int((network_dir / "nextDue").read_text().strip()), int(time.time()))

    def test_undelivered_expiry_is_opt_in_and_visible(self):
        delivery = self._script(
            "always-fail", "printf 'backend down\\n' >&2; exit 7",
        )
        default_id, _ = self._register(
            deliver=str(delivery), no_start_report=True,
        )
        default_dir = self._due(default_id)
        self.mode.write_text("DONE\n")
        PM.pm_sweep_watch(default_dir, self.config)
        (default_dir / "undelivered_at").write_text("1\n")
        PM.pm_sweep_watch(default_dir, self.config)
        self.assertEqual((default_dir / "state").read_text().strip(), "delivery-failed")
        self.assertTrue((default_dir / "undelivered").exists())
        default_spec = PM.read_spec(default_dir / "spec")
        self.assertEqual(default_spec.get("expire_undelivered"), "0")

        on_id, _ = self._register(
            deliver=str(delivery), no_start_report=True, expire_undelivered="1s",
        )
        on_dir = self._due(on_id)
        self.mode.write_text("DONE\n")
        PM.pm_sweep_watch(on_dir, self.config)
        (on_dir / "undelivered_at").write_text("1\n")
        PM.pm_sweep_watch(on_dir, self.config)
        self.assertEqual((on_dir / "state").read_text().strip(), "delivery-expired")
        self.assertIn("undelivered_expired=yes", PM.pm_status(on_dir, self.config))
        self.assertIn("DELIVERY-EXPIRED", (on_dir / "log").read_text())


class PublicCliFixTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name) / "home"
        self.bin = Path(self.temp.name) / "bin"
        self.bin.mkdir()
        self.probe = self.bin / "probe"
        self.probe.write_text("#!/bin/sh\nprintf 'RUNNING detail\\n'\n")
        self.probe.chmod(0o700)
        self.config = PM.Config(
            home=self.root, log_max_bytes=100000, lock_grace_seconds=0,
            backoff_scale=0, fast_sweep=True, probe_timeout=1,
        )

    def tearDown(self):
        self.temp.cleanup()

    def test_graveyard_moves_and_cli_status_log_reap_resolve_removed_watch(self):
        watch_id, _ = PM.register_watch({
            "kind": "script", "script": str(self.probe), "reason": "graveyard",
            "terminal": "DONE", "deadline": str(int(time.time()) + 300),
        }, config=self.config)
        live = self.root / "watches" / watch_id
        before = (live / "log").read_text()
        self.assertTrue(PM.remove_watch(live, self.config))
        grave = self.root / "graveyard" / watch_id
        self.assertTrue(grave.is_dir())
        self.assertTrue((self.root / "watches" / watch_id).is_symlink())
        self.assertTrue(os.path.samefile(str(live), str(grave)))
        env = dict(os.environ, PASEO_MONITOR_HOME=str(self.root))
        status = subprocess.run(
            [sys.executable, str(MODULE_PATH), "status", watch_id],
            env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, check=False,
        )
        self.assertEqual(status.returncode, 0)
        self.assertIn("state=removed", status.stdout)
        log = subprocess.run(
            [sys.executable, str(MODULE_PATH), "log", watch_id, "-n", "20"],
            env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, check=False,
        )
        self.assertEqual(log.returncode, 0)
        self.assertIn("REGISTER", log.stdout)
        PM.update_spec(grave / "spec", "deadline", "1")
        self.assertEqual(PM._cli_reap(self.config), 0)
        self.assertFalse(grave.exists())
        self.assertFalse((self.root / "watches" / watch_id).exists())

    def test_failsafe_fallback_prints_provider_or_placeholder(self):
        paseo = self.bin / "paseo"
        paseo.write_text("#!/bin/sh\nprintf 'schedule failed\\n' >&2\nexit 9\n")
        paseo.chmod(0o700)
        env = dict(os.environ)
        env["PASEO_MONITOR_HOME"] = str(self.root)
        env["PATH"] = str(self.bin) + os.pathsep + os.path.dirname(sys.executable)
        result = subprocess.run(
            [sys.executable, str(MODULE_PATH), "watch", "--script", str(self.probe),
             "--reason", "failsafe", "--terminal", "DONE", "--failsafe",
             "--provider", "provider-a", "--deadline", "+300"],
            env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, check=False,
        )
        self.assertEqual(result.returncode, 0)
        self.assertIn("--provider provider-a", result.stdout)

    def test_p2_golden_fixtures_against_python_entrypoint(self):
        env = dict(os.environ)
        env["PMT_BIN"] = str(MODULE_PATH)
        result = subprocess.run(
            ["sh", str(MODULE_PATH.parents[1] / "tests" / "t-31-golden.sh")],
            cwd=str(MODULE_PATH.parents[1]), env=env,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, check=False,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("PASS: CLI, report envelope, specs, state layout", result.stdout)
