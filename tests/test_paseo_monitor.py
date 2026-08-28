import importlib.util
import os
import stat
import tempfile
import time
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).resolve().parents[1] / "bin" / "paseo-monitor.py"
SPEC = importlib.util.spec_from_file_location("paseo_monitor", str(MODULE_PATH))
PM = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PM)


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
        self.assertEqual((watch / "last").read_text().strip(), "RUNNING")
        self.assertEqual((watch / "detail").read_text().strip(), "detail")
        self.assertEqual((watch / "nextDue").read_text().strip(), str(int(time.time())))
        (watch / "nextDue").write_text(str(int(time.time()) + 600) + os.linesep)
        before = (watch / "log").read_text()
        PM.sweep(sweep_config)
        self.assertEqual((watch / "log").read_text(), before)
