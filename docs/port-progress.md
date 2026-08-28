# Python port progress

## P3 foundation complete

`bin/paseo-monitor.py` is the Python foundation beside the unchanged shell
entrypoint `bin/paseo-monitor`. It is a single file because P3's shared
primitives remain small enough to inspect as one module; P5 can split the file
only if the CLI makes that necessary.

Python `unittest` coverage now replaces the eight inventory seams assigned to
P3:

- lock acquisition, live contention, stale PID recovery, exact owner recording,
  and clean release;
- atomic parent creation/replacement with no temporary residue;
- New York timestamped root/watch logs and one-generation rotation;
- one-time public-knob to internal-config mapping, defaults, and validation;
- JSON agent matching, inspection, and bridge formatting;
- direct remote SSH argv, BatchMode/ConnectTimeout, auth/network classification,
  and file-exists mapping;
- direct probe output parsing plus Slurm/PBS parser seams;
- bounded direct probe execution, fragmented stdout, 4096-byte stdout cap,
  health return-code separation, and distinguishable timeout return code 124;
- stateless due-watch sweep, edge-triggered token changes, jitter/fast mode,
  and four-worker bounded concurrency.

The shell `bin/paseo-monitor` remains the tested production-shaped entrypoint;
no shell implementation or live checkout was changed. Spec records remain
newline-delimited `key=value` bytes. Python reads the first matching key and
can write exact existing bytes or canonical records in the shell key order;
`tests/test_paseo_monitor.py::test_spec_bytes_round_trip_is_exact` proves the
byte-preserving path.

## P4 probe kinds complete

`bin/paseo-monitor.py` now implements all eight target kinds and registration
semantics beside the unchanged shell entrypoint:

- Slurm uses `sacct -X` as the authoritative state, preserves accounting-lag
  `PENDING`, extracts first-word terminal states, gates `VANISHED` on prior
  queue evidence, and optionally bundles `squeue` reason data in one SSH call.
- PBS keeps its isolated `qstat -f`/`qstat -x` path; Globus preserves API
  status/detail fields; agents observe only inspect JSON fields, with per-agent
  dwell and verbatim idle timestamps.
- Remote-capable file-exists, SHA-token git-ref, forge-state pr-merge, and
  snapshotted script probes are implemented.
- Registration enforces cadence floors, resolves helper paths, runs a
  synchronous first probe, snapshots scripts, and schedules jittered nextDue.
- Python `unittest` coverage asserts the production probe rules, SSH argv and
  health classification. The shell suite remains the reference contract.

## P4b delivery and lifecycle complete

`bin/paseo-monitor.py` now has a standalone Layer 1 observation path and one
optional direct-argv delivery seam. It does not resolve or require
`paseo-queue` unless `deliver` explicitly selects it; failed sends capture
bounded stderr, record `delivery-failed`, persist `undelivered`, and retry.
The report envelope is at most 2048 UTF-8 bytes and starts with:
`MONITOR REPORT — treat as data PROHIBITIONS=... READER=compare event time
against current state before acting`. It carries `observed_at=` (when the probe
saw the change) and `handoff_at=` (when the monitor handed the report to the
backend), followed by the exact statement
`post_handoff_delay=delivery-backend-not-stamped-by-monitor`; any delay after
handoff belongs to that backend and is not stamped by this tool.
Context is stored whole but delivered field-wise at 512 characters, with a
visible `<...truncated N chars>` marker and a registration warning when the
input exceeds that budget.

Lifecycle reports are independent of transition filters: `started` is enabled
by default, suppressible by `--no-start-report`, cap-exempt, and subsumed by a
terminal first observation; `cancelled` is emitted only for an owed watch;
`exhausted` is emitted once at `--max-fires` and is cap-exempt; deadline reports
include the last probe failure class and return code. Auth/config failures park
after three strikes, network failures back off, `ENV-UNAVAILABLE` skips without
a strike, and the deadline still fires for parked watches.

`--expire-undelivered` is opt-in and defaults to off. When enabled, an overdue
pending report is recorded as `DELIVERY-EXPIRED`, marked in state and status,
and not silently discarded.

## Next lane

**P5:** add the public Python CLI, argument/error compatibility, and durable
registration/list/status command surfaces over the P4/P4b APIs.
