# P2 golden contract

`tests/t-31-golden.sh` compares the current executable (`bin/paseo-monitor`) with
fixtures captured from the frozen shell authority (`reference/paseo-monitor.sh`).
It runs entirely in the test harness sandbox; it never reads or writes the real
monitor home.

## Re-bless intentionally

When a contract change is deliberate, inspect the candidate diff first, then
regenerate only the P2 fixtures:

```sh
P2_REBLESS=1 sh tests/t-31-golden.sh
sh tests/t-31-golden.sh
```

`P2_REBLESS=1` selects `reference/paseo-monitor.sh` as the source and copies its
normalized candidates into `tests/golden/`. Without that variable, the test
always exercises `bin/paseo-monitor` and compares it to the committed files.
Review and commit the resulting files together with the test; do not bless from
the port executable.

## Captured surfaces

- `help.txt`: complete `--help`, byte-for-byte.
- `kinds.txt`: complete `kinds`, byte-for-byte.
- `errors.txt`: exact stderr text and exit status for missing deadline,
  script-required flags, cadence-floor rejection, registration probe failure,
  missing `paseo`, and watch-not-found.
- `reports/*.txt`: delivered `started`, `terminal`, `deadline`, `cancelled`,
  and `exhausted` envelopes. The test also asserts the front-loaded
  `PROHIBITIONS` field, a numeric `elapsed=<seconds>s`, a maximum 2048-byte
  envelope, and field-wise context truncation for the long-context case.
- `specs.txt`: serialized `spec` bodies for every bundled kind, including both
  local and remote `file-exists` registrations.
- `state-layout.txt`: live and graveyard durable files, their contents, the
  compatibility link, and the observed sweep beacon.
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

A clean sweep creates `sweep.beacon`; it does not emit `sweep.log`, and
`sweep.lock/` exists only while the lock is held. Those observations are stated
in `state-layout.txt` rather than fabricated into the fixture. `undelivered`
and `dwell` are optional files and are listed only when the scenario creates
them. The report-shape assertions cover the parts whose exact bytes vary with
runtime timing.
