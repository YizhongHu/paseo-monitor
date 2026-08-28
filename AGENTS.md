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
**2026-08-25** (`7accacdde5bf8eb07f4d6fd18542bf1fb0500975`). The repositories are
siblings by design: copy, do not import or source a runtime library. If a bug
is found in either repository's copied primitive, check the other repository
for the same bug and fix both deliberately.

This is a disposable stopgap, with the same posture as paseo-queue. The eventual
home is the Paseo daemon, which owns long-lived agent lifecycle and terminals.
Do not over-engineer this repository or make it a dependency of the daemon. The
two tools die on different upstream events: paseo-queue is retired when
getpaseo/paseo#3797 ships; paseo-monitor then swaps its delivery function and
continues until its daemon replacement exists.

## Implementation constraints

- POSIX `sh` only. `/bin/sh` is bash 3.2.57 in `sh` mode. No arrays, `[[ ]]`,
  `local`, or process substitution.
- No `jq`, `flock`, `setsid`, `date +%s%N`, or `timeout(1)`.
- Use Python 3.8 only for JSON one-liners, through `python3 -c "$VAR"`.
  Never attach a heredoc to the `python3` invocation: it steals the JSON input
  stream. Do not put substantial logic in Python.
- Operational log timestamps use `America/New_York`.
- Launchd is the required macOS trigger because its GUI agent preserves the
  credential environment needed by SSH probes. Do not pre-build a scheduler
  abstraction layer.
- The probe contract is direct argv execution, stdin `/dev/null`, bounded
  stdout/stderr, and a hard timeout. Never execute a probe through `sh -c`.
- Do not sanitize the inherited environment: SSH and Kerberos credential
  variables are required by cluster probes.
- Tests use per-test `mktemp` sandboxes, isolated `PASEO_MONITOR_HOME`, mock
  shims first on `PATH`, and fast knobs. They must not touch a real daemon,
  cluster, or `~/.paseo-monitor`.
- Run `sh -n` on every script and `tests/run-tests.sh` before committing.
- Never put backticks in commit messages.

## State contract

The default state root is `~/.paseo-monitor`; `PASEO_MONITOR_HOME` overrides it.
Its durable layout is specified in `PLAN.md` and must remain exactly:
`sweep.lock/`, `sweep.log`, and `watches/<watch-id>/` containing `spec`,
`context`, `probe`, `last`, `detail`, `nextDue`, `health`, `state`,
`undelivered`, `fires`, and `log` as applicable.
