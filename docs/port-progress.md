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

## Next lanes

- **P4:** concrete target probes and registration-facing probe behavior beyond
  the foundation's file/script/remote/PBS/Slurm paths.
- **P4b:** delivery backends, report envelopes, undelivered retry, and envelope
  caps.
- **P5:** public Python CLI and cutover-facing command/error compatibility.
- **P6:** deliberate entrypoint/installer cutover; until then do not replace
  `bin/paseo-monitor`.
