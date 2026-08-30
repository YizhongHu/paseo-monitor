# Python port progress

## P3 foundation complete

`bin/paseo-monitor` is the Python cutover target. The retained shell
implementation is `bin/paseo-monitor.sh`; it remains available for rollback and
is the source used by shell compatibility tests. The Python implementation is
single-file and keeps the same public CLI, state layout, and probe contracts.

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

The shell `bin/paseo-monitor.sh` remains the compatibility-tested production
entrypoint; no live checkout was changed by the port work. Spec records remain
newline-delimited `key=value` bytes. Python reads the first matching key and
can write exact existing bytes or canonical records in the shell key order;
`tests/test_paseo_monitor.py::test_spec_bytes_round_trip_is_exact` proves the
byte-preserving path.

## P4 probe kinds complete

`bin/paseo-monitor` implements all eight target kinds and registration semantics
beside the retained shell rollback entrypoint:
- Slurm uses `sacct -X` as the authoritative state, preserves accounting-lag
  `PENDING`, extracts first-word terminal states, gates `VANISHED` on prior
  queue evidence, and optionally bundles `squeue` reason data in one SSH call.
- PBS keeps its isolated `qstat -f`/`qstat -x -f` path; a live completion message
  triggers the historical lookup so terminal state and exit details remain
  observable. Globus preserves API status/detail fields; agents observe only
  inspect JSON fields, with per-agent dwell and verbatim idle timestamps.
- Remote-capable file-exists, SHA-token git-ref, forge-state pr-merge, and
  snapshotted script probes are implemented.
- Registration enforces cadence floors, resolves helper paths, runs a
  synchronous first probe, snapshots scripts, and schedules jittered nextDue.
- Python `unittest` coverage asserts the production probe rules, SSH argv and
  health classification. The shell suite remains the reference contract.

## P4b delivery and lifecycle complete

`bin/paseo-monitor` has a standalone Layer 1 observation path and one optional
direct-argv delivery seam. It does not resolve or require `paseo-queue` unless
`deliver` explicitly selects it; failed sends capture bounded stderr, record
`delivery-failed`, persist `undelivered`, and retry. A queue exit 2 containing
`no agent matches` is classified as `unroutable`, which stops sweeping until
the recipient is fixed and `poke` retries the preserved report.
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
terminal first observation; `watch-removed` is emitted on removal for every
nonterminal, nonexpired, nonparked watch, including watches with prior
intermediate reports; `exhausted` is emitted once at `--max-fires` and is
cap-exempt; deadline reports include the last probe failure class and return
code.
after three strikes, network failures back off, `ENV-UNAVAILABLE` skips without
a strike, and the deadline still fires for parked watches.

`--expire-undelivered` is opt-in and defaults to off. When enabled, an overdue
pending report is recorded as `DELIVERY-EXPIRED`, marked in state and status,
and not silently discarded.

## Cutover readiness

Python cutover is complete: the deployed launcher and managed launchd job
target `bin/paseo-monitor`. The shell implementation remains available as
`bin/paseo-monitor.sh`, the rollback entrypoint, and its disposable smoke
(`version`, `--help`, registration, and `_sweep`) passes alongside the Python
entrypoint.

Rollback remains prepared but not exercised against the production launchd
job. A live rollback drill is intentionally still production-lane-only:
`ISOLATION.md` forbids `launchctl` from development lanes, and this pass did
not stop or reload the real job or touch real watch state.

## P5 public CLI and cutover handoff

`bin/paseo-monitor` now owns the complete public command surface:
`watch`, `kinds`, `ls`, `status`, `log`, `poke`, `rm`, `reap`, `_sweep`,
`help`, and `version`. The P2 golden harness runs against this executable and
reproduces every committed fixture: help, kinds, errors, all five report
classes, bundled specs, durable state layout, and surface agreement.

Removed watches are moved into `graveyard/<id>` and leave a
`watches/<id>` compatibility symlink. `status` and `log` resolve either live
or graveyard storage; `reap` removes expired graveyard entries and their links.
`rm --all` requires `PASEO_AGENT_ID` and is caller-scoped. `--all-agents`
Status includes sweep freshness, ownership, last token/transition, delivery
attempt/error, undelivered state, fires, deadline, log and sweeper-log paths.
Parked watches explicitly report that they will not probe until poked;
unroutable watches report that the recipient must be fixed and poked.
Sweeps atomically write `sweep.beacon`.

`install.sh` uses the pinned interpreter from `bin/resolve-python3` for the
installed launcher, which executes `bin/paseo-monitor`; the retained shell
rollback entrypoint is `bin/paseo-monitor.sh`. The marker-protected launchd
plist remains the trigger (`StartInterval=60`, `RunAtLoad`, explicit `PATH`)
and skills are copied to all three supported roots.

Deliberate compatibility boundary: direct Python library tests retain P4b's
`observed_at`/`handoff_at` report envelope, while CLI invocations use the P2
shell-compatible `at=` envelope and numeric event IDs. This keeps the frozen
CLI golden bytes intact without regressing the P4b API contract.

## Cutover packaging readiness

The cutover target is `bin/paseo-monitor`, now the Python executable. The
shell implementation is retained as `bin/paseo-monitor.sh` for one release and
is used by the shell compatibility tests and installer bootstrap helpers.
`install.sh` pins the interpreter and launches the Python target; rollback can
restore the shell launcher without touching the persisted watch state.

The persisted `python=` field remains kind-specific: it is populated for
`agent` and `globus`, where the shell implementation needs the interpreter,
and is empty for kinds that do not use the embedded Python bridge. Golden
normalization preserves that distinction rather than accepting an empty value
as a resolved interpreter.
