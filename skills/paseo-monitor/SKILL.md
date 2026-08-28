---
name: paseo-monitor
description: Monitor a long-running job, wait for a Slurm job, watch a Globus transfer, report when done, avoid going stale, stop polling, and report observed state changes through a cheap bounded watcher.
---

# paseo-monitor

Use `paseo-monitor` when the target is long-running and the completion check is
mechanical. Register one watch, record the resume context, then return to the
main task. The tool observes and records state changes; delivery is best-effort
and the caller owns liveness.

Prefer this observe-half beside `paseo-queue`, which handles ordered delivery.
Prefer it over `monitor-with-subagent` when a dumb probe suffices. For cluster
work, read `cluster-access`: cadence is bounded by facility policy.

## Minimum viable watch

```sh
paseo-monitor watch --kind slurm --host cannon --job 24211558 --deadline +3600
```

`--report-to` defaults to `$PASEO_AGENT_ID`. Reports go to the caller's queue
when `--deliver paseo-queue` is selected; without a delivery backend,
registration records the watch and its reports locally.

`paseo-monitor version` or `paseo-monitor --version` prints the release version.

## Ownership and removal

`ls` and `status` show `owner=`, `report_to=`, and `ours=yes|no`. `rm <id>`
removes only the caller's watch; `rm --all` is scoped to the caller. Use
`rm --all-agents` for cross-owner removal: it lists every live watch with
owner, `report_to`, and target before removing them. There is no interactive
prompt: the caller is an unattended agent, and a prompt would hang it rather
than protect it. Each removal prints the deleted watch with owner,
`report_to`, and target.

Removed watches move to a graveyard retained under the same 30-day `reap` TTL.
`status <id>` and `log <id>` continue to resolve the removed watch. A queued
report can outlive its watch, so the envelope's `log=` citation pointer must
keep resolving after removal.

Removal is not reversible by re-registering the target: a third party can
create a new watch, but cannot recover the removed watch's `report_to`,
`deliver`, `context`, `prohibit`, `labels`, or `deadline` into that new
registration.

For a failsafe schedule, `watch` accepts `--provider <provider>` and
`--provider <provider>/<model>`. If omitted, it uses the calling agent's
provider, then the first available and enabled provider.

## Reports

After the synchronous registration probe succeeds, reports arrive as follows:

| Class | When |
| --- | --- |
| `started` | At registration by default for a non-terminal first observation: `old=(none)`, `new=<first observed token>`. |
| `transition` | On an intermediate token change only when `--report-transitions` is enabled; `--report-on` enables this and narrows it to selected tokens. |
| `terminal` | On a terminal token change, including a terminal first observation. |
| `deadline` | When the deadline arrives before a terminal observation: `old=<last token>`, `new=DEADLINE`. |
| `health` | On an unobservable probe: protocol failure reports immediately; repeated auth/config or network failures report after three consecutive failures, with auth/config then parking the watch. |
| `cancelled` | On explicit `rm <id>` or `rm --all` when an active watch still owes a report: `new=CANCELLED`. |
| `exhausted` | Once `--max-fires N` is reached: `new=MAX-FIRES-REACHED`; observation and log recording continue. |

`--no-start-report` suppresses the default `started` report. A terminal first
observation subsumes `started`, so it emits only the terminal report. `started`
is exempt from `--max-fires` and does not increment `fires`; the cap bounds
change reports, leaving `--max-fires 1` available for the terminal report.

All lifecycle classes (`started`, `terminal`, `deadline`, `health`, `cancelled`,
and `exhausted`) bypass `--report-on` and `--report-transitions`. A registration
delivery failure warns with the backend's stderr, records `undelivered`, and
leaves the watch active for retry on the next sweep. A clean `started` delivery
does not clear `--failsafe`; only terminal delivery clears it.

Removing a watch that already reported stays silent; terminal, expired, and
parked watches have already reported. `reap` stays silent because it removes
only terminal or expired watches.

## Kind table

The table below is also emitted by `paseo-monitor kinds` and `paseo-monitor
--help`. Copy the invocation that matches the target.

Every watch requires `--deadline <when>`; malformed deadline values are rejected separately.

| Kind | Description | Parameters | Floor | Default interval | Copy-pasteable invocation |
| --- | --- | --- | --- | --- | --- |
| `slurm` | Slurm job state | `--host <host> --job <id> [--report-transitions] [--report-on <tokens>] [--with-reason] --deadline <when>` | 120s | 600s terminal-only, 300s transitions | `paseo-monitor watch --kind slurm --host cannon --job 24211558 --deadline +3600` |
| `pbs` | PBS job state | `--host <host> --job <id> [--report-transitions] [--report-on <tokens>] --deadline <when>` | 120s | 600s terminal-only, 300s transitions | `paseo-monitor watch --kind pbs --host polaris --job 123.server --deadline +3600` |
| `globus` | Globus transfer status | `--task <id> --deadline <when>` | 60s | 300s | `paseo-monitor watch --kind globus --task TASK-ID --deadline +3600` |
| `agent` | Paseo agent status | `--agent <id> [--report-on <tokens>] [--dwell <sweeps>] --deadline <when>` (default dwell: 2) | 60s | 60s | `paseo-monitor watch --kind agent --agent AGENT-ID --report-on BLOCKED-PERMISSION,CLOSED,ARCHIVED --deadline +3600` |
| `file-exists` | Absence / receipt pattern; job-id-keyed watches cannot observe a target that never entered the queue | `--path <receipt-path> [--host <host>] --deadline <when>` | 60s local, 120s remote | 60s local, 120s remote | `paseo-monitor watch --kind file-exists --path /scratch/run/receipt --deadline +3600` |
| `git-ref` | Git ref SHA | `--remote <remote> --ref <ref> --deadline <when>` | 60s | 120s | `paseo-monitor watch --kind git-ref --remote ORIGIN --ref refs/heads/main --deadline +3600` |
| `pr-merge` | Pull request merge state | `--repo <owner/repo> --pr <number> --deadline <when>` | 60s | 300s | `paseo-monitor watch --kind pr-merge --repo OWNER/REPO --pr 123 --deadline +3600` |
| `script` | Custom executable | `--script <file> --reason "<why no kind fits>" --deadline <when>` | 60s | 60s | `paseo-monitor watch --script ./probe.sh --reason "custom direct-argv check" --terminal DONE --deadline +3600` |

`pr-merge` treats both `MERGED` and `CLOSED` as terminal. `CLOSED` is an
observed unmerged human-gate decision, so leaving it active would poll forever
until the deadline instead of reporting the gate outcome.

Agent watches default to `--dwell 2`; the setting remains specific to this kind.

Examples:

```sh
paseo-monitor watch --kind slurm --host cannon --job 24211558 \
  --report-to "$PASEO_AGENT_ID" --deliver paseo-queue \
  --context 'target=24211558 changed=queued; item=0fc2d958; sha=0123456789abcdef0123456789abcdef01234567; branch=main; purpose=wait for outputs; next-owner=caller; evidence=artifact:/path/to/receipt; prohibitions=no polling, no unstated verdicts'

paseo-monitor watch --kind globus --task TASK-ID \
  --context 'target=TASK-ID changed=active; item=ITEM-ID; sha=FULL_SHA; branch=BRANCH; purpose=wait for transfer; next-owner=caller; evidence=artifact:/path/to/receipt; prohibitions=no polling'

paseo-monitor watch --kind agent --agent AGENT-ID --report-on BLOCKED-PERMISSION,CLOSED,ARCHIVED --dwell 2

paseo-monitor watch --kind file-exists --path /scratch/run/receipt --host cannon \
  --context 'target=/scratch/run/receipt changed=absent; item=ITEM-ID; sha=FULL_SHA; branch=BRANCH; purpose=wait for receipt; next-owner=caller; evidence=artifact:/path/to/plan; prohibitions=no inferred completion'

paseo-monitor watch --script ./probe.sh --reason "the target needs a custom direct-argv check" \
  --terminal DONE --context 'target=custom-id changed=running; item=ITEM-ID; sha=FULL_SHA; branch=BRANCH; purpose=wait for custom result; next-owner=caller; evidence=artifact:/path/to/log; prohibitions=no shell-string execution'
```

`file-exists` emits `ABSENT` or `EXISTS`. Use it as the absence / receipt
pattern, keyed to a pre-agreed receipt path:

```sh
paseo-monitor watch --kind file-exists --path /scratch/run/receipt --deadline +3600
```

Job-id-keyed watches cannot observe a target that never entered the queue.
An `ABSENT -> EXISTS` edge reports successful appearance; `ABSENT` through the
deadline produces one deadline event, which covers a synchronously rejected
submission with no job id. With `--host`, the probe uses SSH `BatchMode` and
`ConnectTimeout` and follows remote auth parking and facility cadence floors.

The `--context` resume format is required: target id and what changed; Task
Orchestrator item id; exact full SHA and branch; why or purpose; who owns the
next action; one evidence line citing an artifact; and prohibitions. `branch`
and `sha` are recommended label keys for `--label`, never CLI flags.

Other common watch options are `--max-fires N`, `--no-start-report`, and
`--deliver paseo-queue|COMMAND`; the complete syntax is shown by
`paseo-monitor --help`.

### Labels, prohibitions, and failsafe

At registration the tool harvests `role`, `job`, `item`, and `lane` from the
caller's Paseo agent metadata when the CLI exposes them, and echoes them in
reports. Add other metadata with repeated `--label k=v`; `branch` and `sha`
are recommended label keys, not dedicated flags. If the installed Paseo CLI
does not expose labels in `inspect --json`, harvesting is empty and explicit
`--label` remains the reliable path.

`--prohibit` is an opaque courier field. It is copied into the fixed,
front-loaded `PROHIBITIONS` report slot and into an optional failsafe prompt;
the tool does not interpret or enforce it. Use it only for unconditional,
target-scoped constraints such as “never scancel job 42124320”. Conditional
or situational constraints belong in Task Orchestrator notes, referenced by a
pointer. Without the prohibition, a fresh context may helpfully retry.

`--failsafe` creates a bounded one-shot Paseo schedule. Use `--max-runs` and
`--expires-in` to bound it; the default is one run expiring at the watch
deadline. The schedule prompt contains only the watch id, the `status`/`log`
procedure, and the copied prohibition text—never routing or state. A clean
terminal report removes the schedule. If schedule creation fails, registration
warns, still prints the watch id, exits 0, and prints a `paseo schedule create`
fallback. The emitted fallback currently omits `--provider`; if the installed
Paseo CLI requires one, add an available provider before running it. The
optional Layer 4 backstop must never take down Layer 1 observation.
A provider can be selected with `--provider <provider>` or
`--provider <provider>/<model>`; without it, the caller's provider is used,
then the first available and enabled provider. If the failsafe fires, run
`paseo-monitor status <id>` before anything else.

## Required liveness ritual

Treat this as one caller-owned backstop, not separate optional habits:

1. Register the watch with `--failsafe` when the surrounding workflow has a
   failsafe path.
2. At every turn start, run `paseo-monitor status`. Its `last-sweep-age` header
   lets the caller detect a dead or stale sweeper.
3. When the tool reports a terminal change, it clears its own schedule by
   retaining the terminal state and no longer probing it.
4. If the caller's failsafe fires first, run `paseo-monitor status <id>` before
   doing anything else, then inspect `paseo-monitor log <id>`.

Delivery is best-effort. A report in the watch log is evidence that observation
and report recording happened; it is not evidence that another process acted.
Do not over-trust the delivery path.

## Agent and custom-probe gaps

The `agent` probe cannot distinguish a stopped read from a normally idle read:
`Status=idle`, no pending permissions, and no archive field are byte-identical.
It reports `went idle`, not a completion verdict. Use an absence watch on a
receipt or checkpoint as the workaround when the artifact is authoritative.

A `--script` probe is snapshotted at registration and exec'd directly as argv.
A user script that merely invokes bare `ssh host squeue` inherits raw ssh and
remote exit-code ambiguity; its output and health code must follow the probe
contract (`TOKEN [detail]`, exit 0 for an observation). Recommend
`ControlPersist` in SSH configuration to reduce connection overhead; the tool
does not manage sockets.

## Recovery commands

```sh
paseo-monitor status [<id>]
paseo-monitor log <id> [-n N] [-f]
paseo-monitor poke <id>
paseo-monitor ls
paseo-monitor rm <id> | --all
paseo-monitor reap
```

`poke` probes out of band and resumes a parked watch. `reap` removes only
watches whose terminal or expired deadline is older than the long retention
period. Explicit `rm` is the normal cleanup path; terminal state is retained
for recovery until then.
