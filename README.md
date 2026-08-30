# paseo-monitor

`paseo-monitor` is a cheap, stateless watcher for long-running external work.
A launchd-fired sweeper observes a due watch and reports state changes and
lifecycle events; the caller owns the liveness backstop. The complete design
is in `PLAN.md`.

The production entrypoint is the Python 3.8-compatible standard-library
executable `bin/paseo-monitor`. The previous POSIX shell implementation is
retained at `bin/paseo-monitor.sh` as the one-release rollback path.
Launchd remains the deliberate trigger: its GUI agent preserves
`SSH_AUTH_SOCK` and login-Keychain access for cluster probes. The installer
and interpreter resolver remain POSIX `sh` transition tooling.

## CLI

The CLI observes and records without requiring a delivery backend.
With no backend, registration and `status` explicitly say `delivery=none-configured`; reports remain available in the local watch log only.
Optional delivery uses one direct-argv backend: `--deliver paseo-queue` pipes
the report to `paseo-queue add <report-to>`, while `--deliver <command>` pipes
it to an arbitrary executable. Terminal transitions are reported by default;
`--report-transitions` opts into intermediate changes, and `--report-on`
narrows them to selected tokens. At registration, once the synchronous probe
succeeds, it emits a `class=started` report by default for a non-terminal first
observation through the configured delivery channel: `old=(none)` and
`new=<first observed token>`.
`--no-start-report` suppresses it. A terminal first observation subsumes the
start, so only the terminal report is emitted. `started` is exempt from
`--max-fires` and does not increment `fires`; the cap bounds change reports, so
`--max-fires 1` remains available for the terminal report.

Terminal, health, deadline, cancellation, and exhaustion reports bypass
`--report-on` and `--report-transitions`; intermediate transitions remain
opt-in. A clean `started` delivery does not clear `--failsafe`; only terminal
delivery does. If the delivery backend refuses the registration report, the
watch remains active, warns with the backend's stderr, records `undelivered`,
and retries on the next sweep. A queue delivery that returns exit 2 with
`no agent matches` is instead marked `unroutable`: sweeping stops until the
recipient is fixed and `poke <id>` explicitly retries the preserved report.

`rm <id>` or `rm --all` reports `class=watch-removed` for every nonterminal,
nonexpired, nonparked watch, even when it has already delivered intermediate
reports. The removal report carries no target `old`/`new` transition claims;
the last observed token remains in `detail`. Terminal, expired, and parked
watches have already reached an outcome and remain silent on removal. `reap`
stays silent because it removes only terminal or expired watches. `--max-fires
N` reports `class=exhausted` with `new=MAX-FIRES-REACHED` once the cap is
reached, then reporting stops while the watch log continues to record every
token change. These reports bypass `--report-on` and `--report-transitions`.

Ownership is explicit: `ls` and `status` show `owner=`, `report_to=`, and
`ours=yes|no`. `rm <id>` removes only the caller's watch; `rm --all` is scoped
to the caller. Use `rm --all-agents` for cross-owner removal: it lists every
live watch with owner, `report_to`, and target before removing them. There is
no interactive prompt: the caller is an unattended agent, and a prompt would
hang it rather than protect it. Each removal prints the deleted watch with
owner, `report_to`, and target.

Removed watches move to a graveyard retained under the same 30-day `reap` TTL.
`status <id>` and `log <id>` continue to resolve the removed watch. A queued
report can outlive its watch, so the envelope's `log=` citation pointer must
keep resolving after removal.

Removal is not reversible by re-registering the target: a third party can
create a new watch, but cannot recover the removed watch's `report_to`,
`deliver`, `context`, `prohibit`, `labels`, or `deadline` into that new
registration.

```sh
paseo-monitor watch --kind <kind> [kind args] --deadline <when> [options]
paseo-monitor watch --script <file> --reason "<why no kind fits>" --deadline <when> [options]
paseo-monitor kinds
paseo-monitor ls
paseo-monitor status [--mine|<id>]
paseo-monitor log <id> [-n N] [-f]
paseo-monitor poke <id>
paseo-monitor rm <id> | --all | --all-agents
paseo-monitor reap
paseo-monitor version | --version
paseo-monitor _sweep
```

`--deadline <when>` is required for every watch; malformed deadline values are rejected separately.

Common watch options include `--report-transitions`, `--report-on TOK,TOK`,
`--label k=v`, `--prohibit TEXT`, `--failsafe`, `--provider PROVIDER[/MODEL]`,
`--max-fires N`, `--max-runs N`, `--expires-in DURATION`, and
`--no-start-report`. `--with-reason` is the Slurm reason-detail switch;
reason tokens in `--report-on` derive it automatically. Slurm and PBS have
120-second floors; their defaults are 600 seconds terminal-only and 300
seconds when transitions are enabled. Other kind floors and defaults are
listed by `paseo-monitor kinds` and in the skill table.

Kind floors and defaults:

| Kind | Floor | Default interval |
| --- | --- | --- |
| `slurm` | 120s | 600s terminal-only, 300s transitions |
| `pbs` | 120s | 600s terminal-only, 300s transitions |
| `globus` | 60s | 300s |
| `agent` | 60s | 60s; default dwell 2 |
| `file-exists` (absence / receipt pattern) | 60s local, 120s remote | 60s local, 120s remote |
| `git-ref` | 60s | 120s |
| `pr-merge` | 60s | 300s |
| `script` | 60s | 60s |

PBS probes treat the live `qstat -f` completion message
`Job has finished, use -x or -H` as a positive terminal signal and perform a
historical `qstat -x -f` lookup for the terminal state and exit details.

For an absence / receipt watch, key `file-exists` to a pre-agreed receipt path:

```sh
paseo-monitor watch --kind file-exists --path /scratch/run/receipt --deadline +3600
```

Job-id-keyed watches cannot observe a target that never entered the queue.

`status --mine` lists only live watches whose explicit `owner` matches
`$PASEO_AGENT_ID`; `status <id>` remains the precise lookup, and plain
`status` still lists all live watches. Without `PASEO_AGENT_ID`, `--mine`
fails rather than guessing an owner.

`--failsafe` creates a bounded one-shot Paseo schedule in the daemon. For
example, `paseo-monitor watch --kind slurm --host cannon --job 24211558
--deadline +3600 --failsafe --expires-in 5m --max-runs 1` schedules one
bounded follow-up that tells a fresh agent to inspect `status` and `log`.
It is only a liveness backstop: it does not replace the observation probe,
guarantee delivery, or reconstruct state or routing from its pointer. Its
pointer-only prompt contains the watch id, the `status`/`log` procedure, and
the opaque prohibition text, never routing or state. A clean `started` report
leaves the schedule in place; a clean terminal report removes it. Use
`--max-runs` and `--expires-in` for explicit bounds; without them, one run
expires at the watch deadline. If schedule creation fails, registration warns,
still prints the watch id, exits 0, and prints a `paseo schedule create`
fallback. The emitted fallback currently omits `--provider`; if the installed
Paseo CLI requires one, add an available provider before running it. The
optional Layer 4 backstop must never take down Layer 1 observation.
`--provider PROVIDER[/MODEL]` selects the schedule provider; without it, the
caller's provider is used, then the first available and enabled provider.

At registration the tool attempts to harvest the caller's `role`, `job`,
`item`, and `lane` labels from `paseo inspect "$PASEO_AGENT_ID" --json` when
the CLI exposes them. Some installed CLI versions omit labels; explicit
`--label k=v` is the reliable fallback. `branch` and `sha` are recommended
label keys, never dedicated flags. `--prohibit` is a courier, not an
enforcer: use it only for unconditional target-scoped constraints. Put
conditional or situational constraints in Task Orchestrator notes and point
to them.

Registration output states that delivery is best-effort. The caller owns its
liveness backstop.

Agent watches default to `--dwell 2`; the setting remains specific to this kind.

### Agent stall watch

The `agent` kind watches stalls and observable lifecycle changes, not a
completion event:

```sh
paseo-monitor watch --kind agent --agent <id> \
  --report-to "$PASEO_AGENT_ID" --deadline +3600
```

`paseo inspect <id> --json` exposes `Status`, `Archived`/`ArchivedAt`,
`PendingPermissions`, and `UpdatedAt`. Permission holds report as
`BLOCKED-PERMISSION`; permission queue depth and verbatim `updated_at=` are
included in the detail. For an idle observation the detail says `went idle`
and includes `idle_since=` with that same unmodified `UpdatedAt` value. Use
`--dwell N` to require N consecutive observations for an agent transition;
this narrow flap control applies only to agents.

**Measured gap:** a stopped agent is byte-identical to a normally finished
agent (`Status=idle`, `Archived=False`, `PendingPermissions=[]`), and the CLI
has no `stopped` status or attention field. No polling cadence can recover
that absent state. The probe therefore says **went idle**, never **finished**.
For certainty, pair this with an **absence watch** on a receipt or checkpoint
file; that workaround observes the artifact rather than inventing a verdict.

## State and knobs

Default state is `~/.paseo-monitor`. The state root contains `sweep.lock/`,
`sweep.log`, `sweep.beacon`, `watches/<watch-id>/`, and
`graveyard/<watch-id>/`. Removed watches retain their spec, context, log, and
routing data in the graveyard under the same 30-day `reap` TTL; the
`watches/<watch-id>` compatibility link keeps `status`/`log` citations
resolvable. A queued report can outlive its watch, so the envelope's `log=`
citation pointer must keep resolving after removal. A watch directory contains
`spec`, `context`, `probe`, `last`, `detail`, `dwell`, `nextDue`, `health`,
`state`, `undelivered`, `fires`, and `log` as applicable.

External knobs are read once at process startup into internal `PM_*` variables;
runtime code must use only the internal names:

| External knob | Default | Purpose |
| --- | --- | --- |
| `PASEO_MONITOR_HOME` | `$HOME/.paseo-monitor` | State root |
| `PASEO_MONITOR_LOG_MAX_BYTES` | `5242880` | Single-generation log rotation threshold |
| `PASEO_MONITOR_LOCK_GRACE_SECONDS` | `5` | Lock-without-pid liveness grace window |
| `PASEO_MONITOR_BACKOFF_SCALE` | `1` | Test-only backoff multiplier |
| `PASEO_MONITOR_FAST_SWEEP` | `0` | Test-only fast-sweep mode |

The inherited environment is intentionally not sanitized. In particular,
credential variables needed by SSH and Kerberos probes remain available.

## Installation

From a checkout:

```sh
./install.sh
export PATH="$HOME/.local/bin:$PATH"
paseo-monitor --help
```

Installation creates the idempotent symlink
`~/.local/bin/paseo-monitor -> bin/paseo-monitor` and bootstraps the managed
launchd user agent `com.paseo-monitor.sweep` with `StartInterval=60` and
`RunAtLoad=true`. The agent is deliberate: a GUI launchd process carries
`SSH_AUTH_SOCK` and login-Keychain access required by cluster probes, unlike a
bare cron process. Re-running the installer safely reloads the marked plist;
`./install.sh uninstall` removes the agent and CLI symlink without deleting
watch state.

`paseo-monitor version` and `paseo-monitor --version` print
`paseo-monitor v1.3.0`.

## Development

Run the retained shell compatibility suite with:

```sh
tests/run-tests.sh
```

The harness defaults to `PMT_MODE=shell` because the `t-*.sh` suite retains
shell-internal assertions and is the frozen compatibility contract. Set
`PMT_MODE=python` (or `PMT_BIN=bin/paseo-monitor`) only when exercising a
Python-safe fixture against the Python candidate. Python implementation seams
are covered by:

```sh
python3 -m unittest discover -s tests -p 'test_paseo_monitor.py'
```

Each test creates a fresh temporary sandbox and places mock `paseo`,
`paseo-queue`, and `ssh` commands first on `PATH`. Tests never use a real
cluster, daemon, or user monitor state.
