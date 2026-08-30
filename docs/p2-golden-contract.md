# P2 golden contract

`tests/t-31-golden.sh` compares the selected executable (the retained shell
entrypoint by default, or `PMT_BIN=bin/paseo-monitor` for Python) with fixtures
captured from the frozen shell authority (`reference/paseo-monitor.sh`). It runs
entirely in the test harness sandbox; it never reads or writes the real monitor
home.

Shared CLI and report fixtures live in `tests/golden/`. The state-layout
fixture is entrypoint-specific: Python uses
`tests/golden/state-layout.txt` and the retained shell/reference entrypoint
uses `tests/golden-shell/state-layout.txt`. This keeps both contracts exact:
Python requires root `sweep.log`; shell/reference requires its absence.

## Re-bless intentionally

When a contract change is deliberate, inspect the candidate diff first, then
regenerate only the P2 fixtures:

```sh
P2_REBLESS=1 sh tests/t-31-golden.sh
sh tests/t-31-golden.sh
```

`P2_REBLESS=1` selects `reference/paseo-monitor.sh` as the source, refreshes
the shared fixtures, and writes the shell-specific state-layout fixture.
Without that variable, the test exercises `bin/paseo-monitor` (or an explicit
`PMT_BIN`) and compares against the matching state-layout fixture. Review and
commit the resulting files together with the test; do not bless from the port
executable.

## Captured surfaces

- `help.txt`: complete `--help`, byte-for-byte.
- `kinds.txt`: complete `kinds`, byte-for-byte.
- `errors.txt`: exact stderr text and exit status for missing deadline,
  script-required flags, cadence-floor rejection, registration probe failure,
  missing `paseo`, and watch-not-found.
- `reports/*.txt`: delivered `started`, `terminal`, `deadline`, `watch-removed`,
  and `exhausted` envelopes. The test also asserts the front-loaded
  `PROHIBITIONS` field, a numeric `elapsed=<seconds>s`, a maximum 2048-byte
  envelope, and field-wise context truncation for the long-context case.
- `specs.txt`: serialized `spec` bodies for every bundled kind, including both
  local and remote `file-exists` registrations.
- `state-layout.txt` (under the selected fixture directory): live and graveyard
  durable files, their contents, the compatibility link, and the observed
  sweep beacon; Python additionally requires `sweep.log`, while
  shell/reference requires its absence.
- `surface-agreement.txt`: exact `kinds`/`--help` agreement plus required kind
  and deadline tokens in `README.md` and `skills/paseo-monitor/SKILL.md`.

## Normalization rules

Only values that are variable by construction are normalized:

- generated watch IDs and watch-directory path components become `<WATCH-ID>`;
- report timestamps become `<TIMESTAMP>` and event IDs become `<EVENT>`;
- elapsed seconds become `<SECONDS>` because wall-clock scheduling varies; the
  test separately requires the unnormalized report to contain numeric elapsed;
- epoch fields (`deadline`, `registered`, `nextDue`, and sweep-beacon epoch)
  become `<EPOCH>`;
- process IDs in log records become `<PID>`;
- temporary test sandbox paths become `<SANDBOX>` and the isolated monitor home
  becomes `<HOME>`;
- resolved interpreter and helper paths become `<PYTHON>` and `<HELPER>`.

Observed tokens, field order, report classes, report details, prohibition
placement, context field boundaries, marker text, spec key order, default
values, cadence values, state names, and file contents are not normalized.

A clean sweep of the Python entrypoint creates a timestamped `SWEEP` record
in `sweep.log` and updates `sweep.beacon`; `sweep.lock/` exists only while the
lock is held. Delivery-failure warnings emitted by the sweeper are also
recorded in `sweep.log` while remaining on stderr. The frozen shell reference
implementation retains the historical no-`sweep.log` clean-sweep observation;
its golden assertions remain unchanged. `undelivered` and `dwell` are optional
files and are listed only when the scenario creates them. The report-shape
assertions cover the parts whose exact bytes vary with runtime timing.
