# Contributor rules for paseo-monitor

## Core doctrine

**Artifacts over narratives — deterministic probes cannot confabulate.** This is
paseo-monitor's core epistemic claim: a bounded probe records target evidence
instead of inventing a story. Keep reports grounded in the files and command
artifacts the probe actually observed.

**Automation text carries identities, not state.** Agent IDs, work-item IDs,
paths, and other pointers may travel through automation text. Target state must
come from a deterministic probe observation, never from prose supplied by an
agent or from an inferred narrative.

## Ancestry and disposability

The copied shell primitives originate in paseo-queue commit **7accacd** dated
**2026-08-25** (`7accacdde5bf8eb07f4d6fd18542bf1fb0500975`). This is historical
ancestry only. `paseo-monitor` is being ported to Python while `paseo-queue`
remains shell, so the cross-repo "fix both" rule is suspended for
language-specific and runtime changes. `paseo-queue` has its own filed Python
port item; when both tools are Python, deliberately check genuinely shared
primitives in both repositories again.

This is a disposable stopgap, with the same posture as paseo-queue. The eventual
home is the Paseo daemon, which owns long-lived agent lifecycle and terminals.
Do not over-engineer this repository or make it a dependency of the daemon. The
two tools die on different upstream events: paseo-queue is retired when
getpaseo/paseo#3797 ships; paseo-monitor then swaps its delivery function and
continues until its daemon replacement exists.

## Implementation constraints

- Python runtime target: Python 3.8-compatible standard library only. No
  third-party imports.
- Installation resolves and pins the interpreter. It runs each candidate and
  requires the expected stdout marker and version; exit status is never
  evidence. `/usr/bin/python3` on the target machine prints an `xcrun` error
  and exits 0.
- `xcode-select` currently points at a gutted
  `/Library/Developer/CommandLineTools` whose `usr/bin` has 6 entries and no
  `xcrun`; `sudo xcode-select -s
  /Applications/Xcode.app/Contents/Developer` yields Python 3.9.6.
- Python 3.8 has no `zoneinfo`; operational log timestamps use
  `America/New_York` through `TZ` and `time.tzset()`.
- Interpreter and external helper paths follow the existing resolve-and-
  snapshot pattern (`helper=`, `paseo_bin=`), avoiding the `rc=127` class.
- `launchd` remains the required macOS trigger because its GUI agent preserves
  the credential environment needed by SSH probes.
- The probe contract is direct argv execution, stdin `/dev/null`, bounded
  stdout/stderr, and a hard timeout. Never execute a probe through `sh -c`.
- Do not sanitize the inherited environment: SSH and Kerberos credential
  variables are required by cluster probes.
- Transition tooling remains POSIX `sh` (installer, resolver, and generated
  launcher); run `sh -n` on every script and `tests/run-tests.sh` before
  committing.
- Tests use per-test `mktemp` sandboxes, isolated `PASEO_MONITOR_HOME`, mock
  shims first on `PATH`, and fast knobs. They must not touch a real daemon,
  cluster, or `~/.paseo-monitor`.
- Never put backticks in commit messages.

## State contract

The default state root is `~/.paseo-monitor`; `PASEO_MONITOR_HOME` overrides it.
Its durable layout is specified in `PLAN.md` and must remain exactly:
`sweep.lock/`, `sweep.log`, and `watches/<watch-id>/` containing `spec`,
`context`, `probe`, `last`, `detail`, `nextDue`, `health`, `state`,
`undelivered`, `fires`, and `log` as applicable.
