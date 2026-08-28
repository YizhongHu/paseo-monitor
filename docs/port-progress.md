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

## Next lanes

- **P4b:** add delivery backends, report envelopes, undelivered retry, and
  envelope caps on top of the P4 observation/event hooks.
- **P5:** add the public Python CLI, argument/error compatibility, and durable
  registration/list/status command surfaces over the P4 registration API.
- **P6:** deliberate entrypoint/installer cutover; until then do not replace
  `bin/paseo-monitor`.
