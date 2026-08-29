# paseo-monitor — design plan

Status: **Python port in progress; interpreter-resolution groundwork landed in `bd32317`**. This plan records the decided contract and remaining design work. See "Open questions" for the minor residue.

Evidence base:

- **10 review rounds** with a `claude-fable-5` advisor (agent `31a23f45`, max
  thinking), argued against the orchestrator's independent analysis. Both sides
  were overruled at least twice; divergences are recorded in the Decision log.
- **3 ground-truth replies** from orchestrators who did the actual waiting
  (`2d4c8573`, `d62b20f8`, `235b9828`) — the source of most corrections here.
- **4 direct measurements** on the target machine: a 200-agent fleet census, a
  controlled stop-an-agent experiment, `git ls-remote` timing, and an
  end-to-end trace of `PendingPermissions` through 49 production `HOLD-PERM`
  log lines.

Forks are presented as options with leans rather than as a single answer.

## Problem

Paseo agents supervise long-running external work: Slurm jobs (hours to
days), Globus transfers, training runs, and other Paseo agents. Today an
agent must poll (a full turn and its token cost per check), block, or yield
and go stale with nobody to wake it.

`paseo-monitor` lets an agent register a *watch* and yield. A cheap non-LLM
sweeper observes the target and, on state **change** only, reports.

**Nothing runs on a cluster.** No `sbatch`, no monitoring job, **zero fairshare
impact**. The sweeper is laptop-side; cluster contact is only
`ssh <host> sacct -j <id>` from a login node — the command agents already run
by hand, which `cluster-access` permits as "light inspection."

Division of labour: **`paseo-monitor` observes. Delivery is pluggable and
`paseo-queue` is one optional backend, never a hard dependency** — see the
delivery layering below. The core tool must be useful standalone.

## Intended outcome (the acceptance bar)

1. `paseo-monitor` is on `PATH` locally and usable from a plain shell.
2. An agent **discovers it and learns to use it without being told**, from
   the information already in its context.

(2) is a requirement, not documentation polish. It drives the
Discoverability section and the zero-argument defaults.

## Verdict

Build it. Ten existing mechanisms were checked; none closes the gap.

| # | Exists today | Covers | Why it is not enough |
|---|---|---|---|
| 1 | `paseo heartbeat --cron` | wakes agent on cadence | unconditional; every fire costs a full turn |
| 2 | `paseo schedule --cron` | spawns fresh agent | same, plus no context; cannot run a shell command |
| 3 | `monitor-with-subagent` | correct semantics | pays an LLM to run `sacct \| grep`; context grows per check; dies on laptop sleep |
| 4 | `paseo-queue` | async ordered delivery | delivery only, no observation |
| 5 | harness `hub op:start` + `ready.log` | readiness regex | session-scoped; cannot notify another agent |
| 6 | Slurm `--mail-type`, `--dependency` | chains jobs; TPEN already uses it | notifies *jobs*, not agents |
| 7 | `globus task wait` | native bounded wait | needs a live process for days |
| 8 | `paseo wait`, `notifyOnFinish` | agent completion | blocks; own subagents only; `wait` is a shared broadcast release |
| 9 | `monit` | predicate+action daemon | no Paseo glue; cannot own watch lifecycle or delivery |
| 10 | `paseo-loop` skill | — | empty directory |

Economics: a 3-day Slurm job at 5-minute cadence is ~864 LLM turns under
mechanism 3. Under `paseo-monitor` it is ~864 `ssh … sacct` calls and **one**
agent turn.

## Ground truth

### Reply 1 — `2d4c8573`, the he-cutover orchestration run

5 stacked slices, ~12 subagents, many Cannon jobs. The most load-bearing
evidence in this document, because it is a real run rather than my
speculation.

**What it waited on:** subagent completion (*dominant*), Slurm jobs only
**indirectly** via those subagents, and **git refs moving** after a lane
pushed. Never a transfer, never a build.

**How it waited:** almost never polled — Paseo/agent completion notifications
did the waking. Between turns it ran cheap `git ls-remote` / `rev-parse`
checks, which it described as *"near-free and high value"*. It **never used a
heartbeat.**

**What went wrong:**

1. An agent was stopped by the user, and it only found out when a send
   returned *agent-was-stopped* — it had been reasoning about a lane that was
   already dead.
2. A report arrived **truncated mid-sentence**, costing a round-trip to
   re-request verdicts.
3. It **misreported its own elapsed idle time** — said 51 minutes, actual 31.

**Mid-flight transitions:** *yes, decisively.* Three cases a deadline-only
wake would have missed entirely — a `QOSMaxSubmitJobPerUserLimit` submit
rejection, an agent killed, and an agent sitting blocked awaiting a ruling.

**Distinct kinds monitored: four** — subagent lifecycle, Slurm job state,
scheduler quota/admission, git ref movement.

**To resume after compaction it needs:** Task Orchestrator item id, branch,
exact full SHA, what changed, and where the receipt/log lives — and notes that
**"SHA plus item id alone would let me resume."**

### What reply 1 changes

- **D3 settled: the sweeper survives, no-daemon is dead.** Not a judgement
  call any more — three named mid-flight events mattered, and a deadline-only
  wake catches none of them.
- **Small-stable-N holds** at 4, so A1 and the whole cut list stand.
- **D5 was wrong.** Only 2 of my 4 proposed kinds were used; two kinds I never
  had are needed.
- **`agent` probe scope settled:** killed/stopped, archived, *and*
  `holding-permission` are all reportable. Closes a prior open question.
- **Truncation is an observed failure mode, not a hypothetical** — and it
  happened in this very design session too, when the advisor's round-2 output
  reached me truncated at ~8,700 chars. Drives the report shape below.
- **Agents get their own elapsed-time arithmetic wrong**, so reports must
  carry absolute timestamps *and* precomputed elapsed.
- **Adoption risk, serious:** the caller's one-shot heartbeat is the only
  guarantee in the system, and the one agent with real data **has never used a
  heartbeat.** Printing a copy-pasteable command may not be enough. Under
  review as round-5 Q4.

### Fleet census — the incumbent cost, measured

Counted directly from `paseo ls -a -g --json`, agents whose sole job was
watching one target:

| Metric | Value |
|---|---|
| Dedicated LLM monitor agents | **53** |
| on `codex/gpt-5.6-terra`, thinking **high** | 37 |
| on `claude/claude-sonnet-5`, thinking medium | 14 |
| on `codex/gpt-5.6-luna` | 2 |
| Sustained creation rate | **~15–17 per day** (17 on one day, 15 the next, ~20 in the last 24h) |

Titles carry the target inline — `Monitor P2 verifier 42156098`, `Monitor F7
retry 42117421`, `Monitor corrected F9 probe 42124320` — so the dominant
target is unambiguously a **Slurm job id**. Their labels (`role: monitor`,
`job: 42124320`, `item: dda22660`, `lane: f7-cannon-verify`) are already
exactly the typed context fields proposed above, which independently
validates typed fields over free-text `--context`.

Each of these is a whole LLM agent, mostly on a *high-reasoning* model, whose
entire function was to run `sacct` on a loop. This is the quantified case for
the tool. One instance (`F4 42-row eval monitor`, `gpt-5.6-luna`, thinking
**low**, labelled `role: observation-only`) shows someone already hand-tuning
the cost downward — felt pain, not hypothetical waste.

### The causal reframe — `slurm` before `agent`

Reply 1 reported subagent completion as *dominant* and Slurm as merely
*indirect*. The census explains why, and inverts the conclusion: **those
subagents were themselves mostly Slurm monitors.** Agent-completion watching
at the orchestrator layer is largely an *artifact* of having delegated
Slurm-watching to LLM agents.

So the two kinds are not independent — one manufactures the other. If
`paseo-monitor` watches Slurm directly, a large fraction of the
agent-completion watches never need to exist, because the agents being watched
never get spawned. That reprioritizes D5: **`slurm` is the highest-value probe,
not `agent`.**

### Measured probe costs

- `git ls-remote origin refs/heads/dev` against the TPEN remote: **0.31 s /
  0.76 s / 0.51 s** real, ~0.04 s user. Network-bound but sub-second —
  confirms `git-ref` is viable at a low interval, and that reply 1's
  "near-free" characterization is accurate.

### The `agent` probe blind spot — **measured, not inferred**

Observed `Status` values across 200 agents: `running` (4), `idle` (36),
`closed` (160), plus a separate nullable `archivedAt`. There is **no `stopped`
status**, and `paseo stop` is documented as "interrupt an agent if it is
running (no-op for idle agents)".

**Controlled experiment.** Created a scratch `claude/haiku` agent, let it run,
cancelled it (the analogue of a user stop), inspected it, then archived it.
Result:

```
Status              = 'idle'
Archived            = False
PendingPermissions  = []
```

**Byte-identical to a normally-finished agent.** So "stopped reads as idle" is
measured fact, not inference — and it is exactly reply 1's failure #1, where it
reasoned about a dead lane and learned only via a failed send. No polling
cadence can fix an unrepresented state.

**A second measured result removes the partial recovery I had assumed.**
`paseo inspect <id> --json` exposes **no attention fields at all**. Full key
set:

```
Archived, ArchivedAt, AvailableModes, Capabilities, CreatedAt, Cwd, Id,
LastUsage, Mode, Model, Name, ParentAgentId, PendingPermissions, Provider,
Status, Thinking, UpdatedAt, Worktree
```

No `RequiresAttention`, no `AttentionReason`, no `AttentionTimestamp`.
`paseo ls --json` exposes even less: `created, cwd, id, name, provider,
shortId, status, thinking`.

Those fields *do* exist — `attentionReason: "finished"` is directly observed —
but **only on the MCP/daemon API surface**, never in the CLI JSON. A POSIX `sh`
probe shelling out to the CLI therefore cannot read them. The dwell-fact
reframe (token `idle`, detail `idle_since=` / `attention=`) loses its
`attention=` half, leaving only `idle_since=`, derivable from `UpdatedAt`.

**Third result — initially unvalidated, now VALIDATED by production
forensics.** `PendingPermissions` is exposed by `paseo inspect --json`, making
it the natural signal for the permission-dwell event replies 2 and 3 both
ranked highest. My forced-prompt experiment failed to confirm it: the scratch
agent in `default` ("Always Ask") mode auto-approved a shell command without
prompting, and `list_pending_permissions` returned 0. (Cause: Always-Ask still
passes classifier-safe / allowlisted commands, so `echo` was never going to
prompt.)

The cheap validation was to stop experimenting and **grep production
forensics** — `paseo-queue` already logs `HOLD-PERM` off the *same* CLI field.
Traced end to end:

| Step | Evidence |
|---|---|
| `paseo inspect <uuid> --json` | `bin/paseo-queue:391` — the identical command |
| `perms = a.get("PendingPermissions", …)` → `nperms` | `:108`, `:111` |
| `if [ "$dp_nperms" -gt 0 ]` → `holding-permission` | `:1201–1203` |
| Logged as `HOLD-PERM n=<count>` | `:1000` |
| **Production result** | **49 `HOLD-PERM n=1` lines**, 2026-08-26, real dispatcher pids |

So the field **demonstrably populates through the CLI in production**. Note the
repository's own `t-06` test proves nothing here — it is mock-only. Zero new
experiments were required, which is the lesson: *check existing forensics before
building an experiment.*

**Design consequence — the `agent` kind ships.** Its honest CLI observable set
is `Status`, `Archived`/`ArchivedAt`, `PendingPermissions`, `UpdatedAt`:

- `closed` / `archived` / gone — fully observable.
- **Permission dwell — validated above**, so the #2 priority event stands on
  production evidence rather than inference.
- **Idle dwell** reported as **verbatim `updated_at=`**. `UpdatedAt` semantics
  are themselves unmeasured, so the probe emits the raw value rather than a
  derived duration — artifacts-over-narratives applied to the tool's own
  uncertainty.
- **The `running -> idle` edge regains importance** as the only
  completion-ish signal available for *non-child* agents (`notifyOnFinish`
  covers only your own subagents). The probe says **"went idle"**, never
  "finished" — and a caller who needs certainty pairs it with an **absence
  watch** per the round-9 doctrine.

Marginal cost is ~10 lines of token mapping over the inspect-classify code the
delivery path already ships for orphan-target checks. Nearly free, which
settles the v1 slot question.

The stopped-vs-finished ambiguity ships as a **loudly documented gap** in the
kind's own docs, with the absence-watch workaround named — rather than pulling
`closed`/`archived` coverage merely to avoid documenting a gap.

### Reply 2 — `d62b20f8`

**What it waited on:** a Slurm job of **4 d 08 h / 100k steps**, **Globus
transfers (~53 min)**, another agent finishing an emit, and **agent permission
prompts**. Explicitly *not* builds, *not* files appearing.

**How it waited:** an hourly Paseo heartbeat as failsafe, a **background
`until` shell loop on a predicate**, subagent monitors, and polling in its own
turns — *"all four, badly mixed."*

**What broke:**

1. **~6 hourly heartbeat firings returned "quiet" — pure waste.** Quantifies
   the unconditional-cadence problem exactly.
2. **Its heartbeat body carried a STALE ROUTING TARGET** — it named a lane
   that had since stood down, so it would have notified the wrong owner *at
   exactly the completion hour*. In its words: **"Automation text decays while
   the world moves."**

**Mid-flight:** *"YES, decisively — and not job state."* The reportable event
was **a subagent blocking on a permission prompt**. The operator had to say
*"it keeps stalling"* **three times**. It approved **9 prompts in 4 hours**.
And, independently confirming the census finding: *"A stalled lane is
INVISIBLE: list_agents shows idle/finished, identical to healthy."* Its verdict
on D3 was explicit: **"Build the sweeper."**

**~5 kinds:** Slurm state, Globus task, **agent-pending-permission**,
agent-idle/queue-depth, artefact-exists. *"Don't over-extend."*

**Resume needs:** what was watched, **why**, what changed, **who owns the next
action**, and exact IDs/paths — *"I retain nothing; a bare 'job done' is
unresumable."*

### Cross-reply synthesis

| Signal | Reply 1 | Reply 2 |
|---|---|---|
| Mid-flight matters → sweeper | yes | **yes, "build the sweeper"** |
| Small N | 4 | ~5 |
| Stalled/blocked agent invisible via `Status` | yes | **yes, independently** |
| Bare "done" unresumable; needs typed IDs | yes | **yes** |
| `slurm` | yes (indirect) | yes, 4d08h |
| `globus` | never | **yes — validates the kind** |
| `agent` permission/stall | yes | **top event: 9 prompts / 4 h** |
| `git-ref` | **yes, "near-free"** | not mentioned |
| `file` / artefact-exists | never | 5th of 5 |
| `quota` / admission | **yes (QOS reject)** | not mentioned |
| Used a heartbeat? | **never** | yes — **and got burned by staleness** |

Three findings are now unanimous across two independent runs plus the census:
the sweeper is required, N is small, and **a blocked agent is
indistinguishable from a healthy one through `Status`**.

### The routing-decay problem — **resolved**

Reply 2's stale-routing failure attacked this design directly:
`--report-to`, `--context`, and the printed failsafe body were all **static
text registered once and fired days later.** Registration-time validation
covers the *probe*; nothing validated the *routing*. A 4-day watch could
deliver a correct observation to an owner who stood down two days ago.

**Governing principle:**

> **Automation text carries IDENTITIES, not STATE. State is read at fire
> time.**

The registration sync-probe validates *observability*, which is stable.
Routing and ownership are *state*, which is not. That single distinction sorts
every case:

- **Validate the target before delivery.** Half-built already: `paseo-queue`
  halts `halted-closed` on a dead target. Add a **pre-enqueue target inspect**
  (reusing the copied agent-probe logic) that marks the watch
  `orphaned-target` and surfaces a `status` WARN; and enqueue with `--wait
  --wait-timeout` so exit 1 catches `halted-closed`.
- **Stamp staleness.** ~90% shipped via the envelope's elapsed field; add a
  *stale-context* line once registration age passes a threshold.
- **`--context` carries pointers, never copied ownership** — a TO item id, a
  path. Skill convention, not a code change.
- Fire-time owner resolution is deferred, but its *semantics* move into the
  failsafe agent prompt.

**Critical corollary — the failsafe body has the same disease.** Reply 2's
heartbeat decayed precisely because it **embedded routing**. So the failsafe
prompt must be **pointer-only**: a watch id plus a procedure, nothing that can
go stale. That is the fix for the exact observed failure, and I had been about
to ship the bug.

**Nothing here touches the probe contract** — it is entirely a delivery-path
concern.

### Reply 3 — `235b9828`

**What it waited on:** Slurm jobs across three time scales (CPU verify ~2 min,
GPU probe 32 min, **a 42-row run queued for DAYS**), Paseo subagents
finishing, **Task Orchestrator claim expiries**, and **human PR merges**.

**How it waited:** mostly Paseo completion notifications; one
`monitor-with-subagent` plus **a 3-hour cron heartbeat** for the 42-row run;
and a lot of manual `squeue`/`sacct` in its own turns. Note it **already uses
cron** — empirical support for the cron trigger option in D3.

**What broke — and this is the most important single finding in the
document:**

1. Burned many turns on "still running" (`42 PENDING`, repeatedly).
2. A subagent reported *"blocked, env terminated twice, planner never ran."*
   **Both claims were false.** Its own logs showed the planner wrote 42 rows
   and the sync succeeded in 6 m 48 s. The orchestrator *nearly troubleshot a
   nonexistent failure.* Its conclusion: **"Completion REPORTS lie; artifacts
   don't. Let watches cite artifacts."**

**Mid-flight: yes, but only on expensive waits.** Reportable events named:
`PENDING -> RUNNING` (first start), **`squeue` REASON changing
`Priority -> Resources`**, `TIMEOUT` (*"under `--no-requeue` a timeout is a
LOST row — needs immediate receipt, not end-of-run discovery"*), a job
vanishing with no `sacct` terminal record, and a subagent hitting a permission
prompt. For short CPU jobs, *"done yet" sufficed.* Verdict: **"sweeper yes,
but make it opt-in per watch."**

**Five kinds:** Slurm state, Paseo agent status, **TO claim expiry**, **file
appearing**, **PR merge state**. *"Bet on small."*

**Resume needs:** target id + what changed + **one evidence line** +
**PROHIBITIONS (never `scancel`/resubmit)** + the TO item id holding durable
notes. *"Without the prohibition a fresh context 'helpfully' retries."*

### Three-way synthesis

Unanimous across three independent runs: **the sweeper is required**, **N is
small (4, ~5, 5)**, **a blocked/stalled agent is invisible through `Status`**,
and **a bare "done" is unresumable — reports need typed IDs.**

Each reply contributed one field the others missed, and the union is the
report schema:

| Field | Source |
|---|---|
| target id, what changed | all three |
| TO item id | replies 1 and 3 |
| exact full SHA, branch | reply 1 |
| why / purpose | reply 2 |
| **who owns the next action** | reply 2 |
| **one evidence line citing an artifact** | reply 3 |
| **prohibitions** | reply 3 |

Kind demand, consolidated:

| Kind | R1 | R2 | R3 |
|---|---|---|---|
| Slurm state | ✅ | ✅ | ✅ |
| agent stall / permission | ✅ | ✅ | ✅ |
| Globus task | — | ✅ | — |
| git-ref / PR merge | ✅ | — | ✅ |
| file / artefact exists | — | 5th | ✅ |
| TO claim expiry | — | — | ✅ |
| quota / admission | ✅ | — | — |

**`file` is no longer a cut candidate** — reply 3 validates it. The round-7 Q4
cut proposal is withdrawn.

### Two corrections to earlier rulings

**1. `sacct`-only is insufficient.** Round 3 concluded that `sacct -X` alone
knows the whole lifecycle, dissolving the `squeue -> sacct` handoff. That holds
for *terminal* state — but reply 3 wants **`squeue` REASON transitions
(`Priority -> Resources`)**, and REASON exists only in `squeue`. So a watch
that reports mid-flight transitions needs both commands after all. The handoff
returns, scoped to transition-reporting watches.

**2. Artifacts over narratives — a new first-class principle.** An LLM monitor
*fabricated a failure* that its own logs contradicted. This is the sharpest
argument yet for a dumb probe: a probe that cites `sacct` output or a byte
count **cannot editorialize**. It also upgrades the report-shape decision from
"short because of truncation" to "**cite, never summarize**". Every report
carries one evidence line pointing at primary evidence — the `sacct` row, the
log path, the row count — not a narrative about it.

### Mid-flight becomes opt-in

Reply 3's refinement, and it is right: cheap short waits do not want
transition reports, expensive long waits do. So the default is **terminal
states only**, with `--report-transitions` opting into intermediate events.
This cuts report volume and probe cost on the short-job case, which reply 3
says "done yet" already served. Edge-triggering remains the mechanism; what
becomes configurable is *which* tokens are reportable.

## Live decisions — options, not a single answer

### D1 — How is a monitoring workflow packaged? **Resolved: A1**

| Option | What ships | Cost | Right when |
|---|---|---|---|
| **A1 Programs + argv** | ~5 maintainer-authored probes, params via argv, `--script` escape hatch | agents type `--host cannon` each time | few workflows |
| A2 Declarative recipes only | an engine | at the time, could not express file size-stability; that kind was later cut, so the objection is now historical | never, here |
| A3 Programs + recipe DSL | both, plus a format to design/document/test/version | permanent carrying cost against a benefit that occurs ~never | contribution is frequent (10+ workflows) |
| A4 Programs + named presets | preset format, override precedence, parsing | honestly 60–100 lines and a new concept, not ~20 | many per-facility default bundles |

**Pick: A1.** The decisive reframe: *at a small stable N, the reuse unit is
the **invocation**, not the probe.* Variation across watches is parameter
variation (job id, host, interval), never logic variation — and
parameterization needs argv, not a DSL.

A4 collapses into A1 for free: the honest implementation of a preset is a
**3-line wrapper probe** (`probes/slurm-cannon` execs `probes/slurm --host
cannon`), because kind resolution is already "a file in the probes dir". So
presets need zero new mechanism — and should **not be pre-built**. Add one
only when per-facility defaults actually diverge; if they never do, `--host`
was enough.

A3 is dead: the engine tier existed to make *contribution* cheap, and the
constraint says contribution will not happen. Its one real virtue
(params-as-data makes an agent-proposed diff safe to review) only mattered
under frequent promotion; at roughly one promotion a year the maintainer
reviews shell directly.

Correction worth carrying, since the reasoning gets repeated: A2 does **not**
die from Slurm's `squeue -> sacct` branching. `sacct` alone knows the whole
lifecycle, so that handoff dissolves. What made Slurm "non-obvious" was
*knowledge* (use `sacct -X`, not `squeue`), not *branching*. A2 dies from
engine cost. (The size-stability objection was real when raised, but
`file-stable` was later cut entirely, so engine cost is the whole case now.)

### D2 — Where does it live? **Lean: separate sibling repo**

Reopened by D1, and it survives. Concrete size estimate under the final
design: ~1,000–1,100 lines total, of which **~290 (≈27%) is copied
plumbing** — not the "duplication exceeds own logic" case feared.

The reason is instructive: **the sweeper redesign already evaporated the
shareable half.** `spawn_dispatcher`, `dp_sleep_seconds`, the backoff
schedules, and most trap discipline all disappear under a sweeper. What
remains novel — sweep semantics, probe contract, park policy, registration —
is not queue-shaped code.

Copy, do not extract. Extracting a library from a tool whose own `AGENTS.md`
says *disposable, do not over-engineer* inverts its contract: it makes every
monitor-driven change re-test a frozen tool, and makes "delete this
repository" no longer true. Runtime-sourced libs are also fragile here — the
installed binary is a symlink and macOS bash 3.2 has no `readlink -f`.
**Shared by ancestry, not by import**: one line in each `AGENTS.md` naming
the source commit, and a rule that a bug found in one is checked in both.

Ranked: separate repo > same repo, two self-contained binaries sharing only
the *test harness* > sourced lib > subcommand (no).

Flip conditions, concretely: copied fraction climbs past ~50%; **the process
models converge** (the real one — under the rejected per-watch design the
monitor *was* `paseo-queue` with a different loop body, and a subcommand
would have been defensible); or the lifecycles converge. They don't:
`paseo-queue` dies when getpaseo/paseo#3797 ships, and `paseo-monitor` then
swaps one delivery function and lives on.

### D3 — What advances a watch? **Settled: launchd-driven stateless sweeper**

**The architecture is not an async executor, and never was.** The sweeper is
stateless: it takes a lock, advances due watches, exits. That *is* a cron job.
So two questions must be separated, and only the second is still open:

1. *Is a periodic stateless sweep required?* **Yes — settled on evidence.**
2. *What fires it?* **Reopened.**

#### Is a sweep required? Yes.

| Option | Latency | Survives sleep/reboot |
|---|---|---|
| Periodic stateless sweep | one interval (~60 s) | yes |
| ~~No trigger, opportunistic only~~ | caller's heartbeat cadence | trivially |
| ~~Per-watch long-lived process~~ | seconds | **no** |

Per-watch processes are rejected outright: a days-long `sh` loop dies across
sleep and reboot, and **a dead watcher cannot fire its own deadline**.

The no-daemon option was genuinely attractive and is **dead on evidence.** It
only works if the sole question ever asked is *"is it done yet?"* — and both
replies name mid-flight events it would have missed. Reply 2's verdict was
explicit: *"Build the sweeper."*

#### What fires it? **Settled: launchd — on the credential environment**

The sleep argument I attacked was **conceded**: for a stateless sweeper on an
every-minute line the differential is bounded at ~60 s (cron fires at the next
minute tick after wake). It only ever bit at coarse cadences. So that is *not*
why launchd wins.

**launchd wins on the credential environment**, and the measured evidence is
stronger than the argument as originally made.

| | idempotent crontab | launchd user agent |
|---|---|---|
| Fire after wake | next minute (≤60 s later) | immediate |
| **Credential environment** | **env-less — no auth socket, no login keychain** | **login-session env, native `SSH_AUTH_SOCK`** |
| Install | one `crontab` line | plist + `launchctl bootstrap gui/$UID` |
| Shared mutable state | yes — one user-global file, non-atomic edit | no |
| Clobber risk here | ~none (user has no crontab) | none |
| Auditability | `crontab -l`, one greppable line | opaque plist |

**Measured on this machine:**

- `SSH_AUTH_SOCK=/private/tmp/com.apple.launchd.<id>/Listeners` — the agent
  socket is **launchd-provided**. A gui launchd agent inherits it natively; its
  lifecycle *coincides with* the credential environment's lifecycle. cron would
  need it injected.
- `Host cannon` — the **#1 target** — uses `IdentityFile` + `IdentitiesOnly
  yes` + **`UseKeychain yes`**. Its auth path therefore depends on the **macOS
  login Keychain**, a login-session resource a bare cron job cannot reach.
- `Host aurora` / `Host polaris` specify **no** `IdentityFile`, so they fall
  back to **agent keys** — i.e. they depend directly on `SSH_AUTH_SOCK`.
- `Host frontier` has `ControlMaster no`, consistent with OLCF being out of
  scope for v1 (interactive-only auth).

So **both** credential mechanisms in play — agent socket for ALCF, login
Keychain for Cannon — are login-session-scoped, and cron has neither. Under
cron the **#1 kind (ssh Slurm probes) becomes an auth-failure generator**, and
worse, those failures would **trip sticky auth-parks on healthy watches**
within minutes of install.

Socket-discovery workarounds are exactly the fragile shell the project bans,
and snapshotting the socket path decays by the **round-7 copied-state
principle** — the same rule that resolved routing decay also kills this
workaround. Pleasing internal consistency.

**Also corrected: my "logged-out is a wash" claim was wrong.** When the daemon
is down, the *enqueue itself fails* (`paseo ls` resolution fails), so nothing
queues — the monitor's `undelivered` retry carries it, not a queue hold.

This is an **engineering preference, not a native-answer mandate.** cron stays
viable if auditability is weighted higher, but only with three additions:
**(1)** an `env-unavailable` health class that **skips without a park strike**,
**(2)** an explicit socket/key strategy, **(3)** absolute-path env discipline.
**(1) is worth adding regardless** as hardening — even under launchd, a login
session can end, and the right response is skip, never park.

**"Temporary" was the wrong half of the proposal** (confirmed). A self-removing
line converts the rank-1 failure — silent non-delivery — into an install/remove
race. Disposability comes instead from **idempotence + millisecond no-op sweeps
+ one documented uninstall line**. And: one sweeper line, never one per watch.

#### Trigger-death guards (scheduler-agnostic, keep either way)

1. **Marker-comment idempotent install, performed under the existing global
   mkdir lock** — because `crontab` read-modify-write is non-atomic.
2. **Last-sweep freshness beacon in `status`** — the *universal*
   trigger-death detector. One mechanism catches a removed line, a moved
   binary, dead cron, a booted-out launchd agent, and version skew.
3. **Self-healing**: auto-reinstall plus a freshness check at watch
   registration.

The swap between schedulers is **~30 lines and reversible**; probe contract,
park policy, retention, delivery, deadline, and failsafe are all untouched.

### D4 — How much decay tracking? **Lean: record + report once**

- **Record + report once** — count consecutive failures, back off, emit one
  "cannot observe" event. Matches "keep an eye out for" while remediating
  nothing.
- Record only — expose the count in `status`, never emit. Thinnest
  defensible reading; requires the caller to look.
- ~~Nothing~~ — makes credential decay indistinguishable from a healthy
  "still running".

### D5 — What ships in v1? **Final: 6 built-ins**

My proposed set was `slurm`, `globus`, `agent`, `file`. Three replies plus the
census reordered it, changed what `agent` is *for*, added two kinds, and cut
one sub-kind.

| Kind | Priority | Demand | Status |
|---|---|---|---|
| `slurm` | **1st** | R1 R2 R3 | Census: 53 monitor agents with Slurm ids in their titles, ~15–17/day. R2 a **4 d 08 h** watch; R3 a 42-row run **queued for days**. One probe file, `--with-reason` for REASON transitions. |
| `agent` | **2nd** | R1 R2 R3 | **Reinstated, refocused** on stalls not completions. R2's top event was a subagent **blocked on a permission prompt** — 9 prompts in 4 h, a human reporting the stall three times. **Permission dwell validated** by 49 production `HOLD-PERM` lines off the same CLI field. |
| `globus` | **3rd** | R2 | Validated (~53 min transfers); contract verified against a live account. |
| `file-exists` | **4th** | R2 R3 | Cut proposal **withdrawn** — R3 validates it. Workhorse of the absence pattern. `file-stable` stays cut. |
| `git-ref` | **5th** | R1 | "Near-free and high value"; measured 0.31–0.76 s. First non-terminal kind, which makes `--max-fires` load-bearing. |
| `pr-merge` | **6th** | R3 | **In, and does not collapse into `git-ref`** — base-branch attribution ambiguity. The **only kind watching a human gate**, since TPEN merges stacks bottom-up by hand. |
| ~~`TO claim expiry`~~ | **out** | R3 | Routed to `--script`: single-source evidence, would couple the tool to a project-local TO REST schema, and the 900 s TTL belongs to the claim holder self-guarding. |
| ~~`quota` / admission~~ | **out** | R1 | Not expressible as an entity watch — resolved as a protocol rule plus the absence pattern. See the admission gap. |

**The `agent` demotion I floated after the census was wrong, and is
withdrawn.** The census reframe was correct that *completion*-watching demand
is largely manufactured by monitor-agents — but the high-value agent event is
**pending-permission**, which is intrinsic to permission-gated agents, is not
manufactured by anything, and is *not* covered by `notifyOnFinish` across
lanes. Completion is already covered; **stalls are not**, and they are
invisible through `Status`.

So the `agent` probe reads `Status`, `archivedAt`, `PendingPermissions`, **and
`attentionReason`**. Whether it splits into `agent-permission` and
`agent-idle` (reply 2's framing) or stays one kind with a richer token set
(`RUNNING` / `IDLE` / `BLOCKED-PERMISSION` / `CLOSED`) is round-7 Q3; I lean
one kind, since the probe command is identical and only the token mapping
differs.

#### The admission gap — **resolved**

`QOSMaxSubmitJobPerUserLimit` rejected a submit **synchronously**: no job id,
no `sacct` row, no log, no trace findable afterwards. Only the submitting lane
ever knew. Every watch keys to an **observable entity**, so a failure that
*prevented the entity from existing* cannot be observed by an entity-watcher at
any cadence.

The resolving principle: **monitors observe unattended change; synchronous
rejections happen while somebody is looking.** So this is a scope boundary, not
a missing probe.

- **(a) Primary — a protocol rule, not a feature.** The submitting lane reports
  its own synchronous submit failure immediately via `paseo-queue`. It is the
  only party that ever had the information.
- **(c) Backstop, and it needs *no new watch type*.** An existence probe plus
  the mandatory deadline *already* expresses absence: the `ABSENT -> EXISTS`
  edge is a normal edge trigger, and **the deadline event IS the absence
  report**. The essential trick is to key the watch on a **pre-agreed artifact
  that exists independently of the submit** — a job *name*, a receipt path, a
  ref — and **never on the job id that may never be assigned.**
- **(b) Rejected for v1** — an account-level quota probe is a scalar-threshold
  shape, preventive rather than reactive, and buys little.

So the gap closes with one documented protocol rule plus a naming discipline
for `--expect`-style watches. No new mechanism.

### Rejected, for the record

- **`paseo schedule` as the *sweep driver*** — spawns a fresh *agent* per fire,
  so every tick would cost an LLM turn, and it cannot run a plain shell
  command. Note this rejection is scoped to the **sweep trigger only**;
  schedules *are* the right mechanism for the opt-in `--failsafe`, precisely
  because they are daemon-owned and therefore an independent failure domain.
  One fire is cheap; one fire per minute is not.
- **`monit` as a dependency** — its `check program` contract validates the
  design, but the hard parts here (Paseo delivery glue, watch lifecycle,
  deadline, agent-facing CLI) are exactly what it does not do. The monit-vs-nagios
  history settles it: nagios kept plugins as programs behind a thin contract
  and aged better; monit's DSL grew conditionals until it was a bad language.
- **Replacing `monitor-with-subagent`** — it stays right for
  judgment-per-check ("does this loss curve look sick?") and for
  terminal-mediated facilities. Complement, not replacement.

## Architecture: stateless launchd sweeper

Nothing lives longer than one sweep:

```
launchd user agent (StartInterval 60, RunAtLoad true)
  -> paseo-monitor _sweep
       take ONE global mkdir lock; SKIP if held
       for each watch dir where nextDue has elapsed:
         run probe with hard timeout (parallel, capped)
         compare first token against last
         fire? -> paseo-queue add
         update state, nextDue
       exit
```

Why, from runtime evidence: every existing `paseo-queue` dispatcher observed
was `state=stopped, dispatcher=down`, with `LINGER=10`. Those dispatchers are
*reactive and short-lived* — which is why the model works there. Watches live
for **days**. A detached loop will die, and when it dies the agent is never
woken and waits forever — strictly worse than polling, because the agent
believes it will be woken.

Consequences:

- Process-death exposure collapses from *days* to *one sweep interval*.
- launchd survives reboot (loads at login) and sleep (coalesces to one fire
  on wake). `cron` on macOS skips sleep entirely. `launchd` is not on the
  banned-tools list; `setsid`/`flock` are, and are not needed.
- Orphan recovery is free: every sweep recomputes due work from disk. No
  recovery cron, no multi-day stale locks. `paseo-queue`'s documented
  pid-reuse lock window shrinks from days to seconds.
- Only a global sweeper can see all due watches and **group by (kind, host)**
  — `sacct -j 1,2,3` takes job lists, so N Slurm watches on one cluster can
  become one SSH per sweep. Per-watch processes structurally never can.
  (v2; v1 uses jittered `nextDue`.)
- Kills the ~86,400 forks/day symptom: `sleep` is not a builtin in bash 3.2
  `sh` mode, so 1-second increments mean one fork+exec per second per watch.
  That dance exists only to keep TERM traps responsive in long-lived sleeping
  processes — a workaround for precisely the wrong process model.

Latency floor is the sweep interval. Targets run hours-to-days and delivery
already waits for the target agent to be idle, so this is free.

## Discoverability

Mirror `paseo-queue`'s proven install pattern.

- `~/.local/bin/paseo-monitor` — symlink to `bin/paseo-monitor`, on `PATH`.
- `SKILL.md` copied to **all three** skill roots:
  `~/.claude/skills/`, `~/.codex/skills/`, `~/.agents/skills/`.
  `skills/paseo-monitor/SKILL.md` in-repo is canonical; `install.sh` reads it
  and is idempotent.
- `paseo-monitor --help` is the authoritative flag reference.

**SKILL.md is the discovery surface, not the CLI.** Agents do not browse
CLIs; they read skills and copy patterns. So:

1. The kind table lives **in SKILL.md** with exact copy-pasteable
   invocations, regenerated at install.
2. `paseo-monitor kinds` exists as the freshness check against skill drift —
   a trivial ~15-line print of the hardcoded table (name, description, params,
   floor, default interval). `--help` + SKILL.md is 90%; `kinds` is
   the cheap remaining 10%.
3. **Day-one coverage decides the habit.** If an agent's first three needs
   are covered, recipe-first becomes the learned pattern; if the first need
   falls through to `--script`, the opposite habit forms. Ship coverage
   before advertising the tool.

Ownership is explicit at registration: `owner` records `$PASEO_AGENT_ID`,
`report_to` records the report route, and `ls`/`status` add `ours=yes|no`
relative to the current caller. `rm <id>` removes only a watch owned by the
caller. `rm --all` removes only the caller's watches. `rm --all-agents` is the
cross-owner operation: it lists every live watch with owner, `report_to`, and
target, then removes them. There is no interactive prompt: the caller is an
unattended agent, and a prompt would hang it rather than protect it. Every
removal prints the watch id, owner, `report_to`, and target.

The removed watch is moved to a graveyard, not discarded. It remains resolvable
through `status <id>` and `log <id>` under the existing 30-day `reap` TTL. A
queued report can outlive its watch, so the envelope's `log=` citation pointer
must keep resolving after removal.

Removal is not reversible by re-registering the target: a third party can
create a new watch, but cannot recover the removed watch's `report_to`,
`deliver`, `context`, `prohibit`, `labels`, or `deadline` into that new
registration.

The `watch` command accepts `--provider <provider>` and
`--provider <provider>/<model>`. For `--failsafe`, an omitted provider uses the
calling agent's provider, then the first available and enabled provider.

The `version` and `--version` commands print the release version.

The `description:` frontmatter is what lands in an agent's system prompt. It
must carry the phrases an agent will actually be thinking: monitor a
long-running job, wait for a Slurm job, watch a Globus transfer, report when
done, avoid going stale, stop polling.

Cross-links: `monitor-with-subagent` ("prefer `paseo-monitor` when a dumb
probe suffices"), the `paseo` skill (name it beside `paseo-queue` as the
observe-half), `cluster-access` (cadence is bounded by facility policy).

Ease of use is part of discoverability. **`--report-to` defaults to
`$PASEO_AGENT_ID`**, which Paseo already exports into every agent environment
(verified: it resolves to the calling agent). Minimum viable invocation:

```sh
paseo-monitor watch --kind slurm --host cannon --job 24211558 --deadline +3600
```

## CLI surface

```sh
paseo-monitor watch --kind <kind> [kind args] \
    [--report-to <agent>] [--interval <s>] --deadline <when> \
    [--terminal TOK,TOK] [--report-on TOK,TOK] [--report-transitions] \
    [--with-reason] [--dwell <n-sweeps>] [--context <text>|--context-file <f>] \
    [--label k=v ...] [--provider <provider>[/<model>]] \
    [--prohibit <text>] [--failsafe] [--max-fires <n>] \
    [--max-runs <n>] [--expires-in <duration>] [--no-start-report]

paseo-monitor watch --script <file> --reason "<why no kind fits>" \
    --deadline <when> --terminal TOK,TOK [...]

`paseo-monitor kinds`             # the kind table: name, params, floors
`paseo-monitor ls`                # live watches + owner/report_to/ours
`paseo-monitor status [<id>]`     # + recovery fields; WARN lines on stderr
`paseo-monitor log <id> [-n N] [-f]`
`paseo-monitor poke <id>`         # probe now, out of band; also resumes a park
`paseo-monitor rm <id> | --all | --all-agents`
`paseo-monitor reap`              # drop expired watches and graveyard entries
`paseo-monitor version | --version`
```

`--deadline <when>` is required for every watch; malformed values are rejected separately.
`--provider` is optional. It accepts a provider name or `provider/model`; when
`--failsafe` is enabled and it is omitted, selection is the calling agent's
provider, then the first available and enabled provider.

`rm <id>` and `rm --all` are caller-scoped. Use `--all-agents` for cross-owner
removal; it lists every live watch and owner before acting. There is no
interactive prompt: the caller is an unattended agent, and a prompt would
hang it rather than protect it.

`poke`, not `drain` — `drain` is queue vocabulary meaning something else.

**`--report-to`, not `--notify`.** The tool *reports*; it never "notifies" or
"wakes". This is deliberate vocabulary discipline against over-trust (see
Responsibility split). Words like "ensures", "guarantees", and "wake" are
banned from the docs.

**`--reason` is mandatory on `--script`.** It costs an agent nothing, shows
up in `ls`, and gives the promotion queue for free: three script watches in a
month whose reasons all mention HTTP endpoints *is* the signal to author
probe #6. Governance telemetry, not a gate.

`--context` is not decoration. The report is a *prompt* to an agent that may
have compacted since registering. "job 24211558 now COMPLETED" is useless;
"he-v1 production run finished; verify outputs per TPEN receipt rules,
orchestrator item tpen-142" resumes work.

## Probe contract

One contract, honoured identically by bundled probes and `--script`.

- Probe is **exec'd directly as argv**, never `sh -c` on a string.
- Prints one line: `TOKEN [free-text detail]`. The **first word** is the
  state token used for edge comparison; the remainder passes through into the
  report. This carries "loss went NaN" or "stalled at 40%" with no expression
  language.
- **Exit code reports probe health, not target state.** `0` = observation
  succeeded; nonzero = could not observe. This is what makes "job FAILED"
  distinguishable from "SSH credential expired".
- `stdin < /dev/null`; stdout capped ~4 KiB; stderr to the watch log, capped.
- Mandatory per-probe hard timeout, default below the sweep interval.
  **macOS ships no `timeout(1)`** — verified: only `/usr/local/bin/timeout`
  from Homebrew exists here, nothing in `/usr/bin`. Implement
  `pm_run_with_timeout` (background child + killer subshell); depend on no
  external binary.
- `--script` probes are **snapshotted into the watch dir at registration**.
  Kills three bugs: agent edits the script mid-watch, `/tmp` cleanup deletes
  it, and TOCTOU. The watch dir becomes self-contained.
- **No `--describe` metadata protocol.** A self-describing probe contract is
  extensibility machinery for third-party kinds, and third-party kinds are
  ~never. The kind table is hardcoded; adding probe #6 means editing the
  repo — which *is* the governance bright line, enforced by the filesystem.

### Trigger semantics

Six event classes, and the distinction matters:

| Class | Reported |
|---|---|
| **Terminal** tokens | always |
| **Health / deadline** events | always |
| **Intermediate** transitions | **opt-in** via `--report-on` |
| **`cancelled`** removal events | always |
| **`exhausted`** max-fires events | always |
| **`started`** registration events | always by default; suppressed by `--no-start-report` |

`started` is emitted by default at registration after the synchronous probe
succeeds, through the configured delivery channel. Its envelope carries
`class=started`, `old=(none)`, and `new=<first observed token>`. A terminal
first observation subsumes it: only the terminal report is emitted. A delivery
failure at registration warns with the backend's stderr and records
`undelivered`. Transient failures leave the watch active for retry; a queue
exit 2 containing `no agent matches` marks it `unroutable` and stops sweeps.
does not increment `fires`: the cap bounds change reports, so `--max-fires 1`
still leaves the terminal report available. A clean `started` delivery does not
clear `--failsafe`; only terminal delivery does. Like every other lifecycle
class, it bypasses `--report-on` / `--report-transitions`. Pass
`--no-start-report` to suppress the registration report.

`cancelled` is emitted by explicit `rm <id>` or `rm --all` for every
nonterminal, nonexpired, nonparked watch, even when it has already delivered
intermediate reports. Its envelope carries `class=cancelled`,
`old=<last observed token>`, and `new=CANCELLED`; if delivery fails, the final
attempt and error remain in the graveyard log. Terminal, expired, and parked
watches have already reported an outcome, so removal stays silent. `reap`
stays silent because it only removes terminal or expired watches.

`exhausted` is emitted once when a watch reaches `--max-fires`, with
`new=MAX-FIRES-REACHED`; it announces that no further reports follow.
Observation continues after exhaustion: the watch log still records every token
change, so the evidence trail keeps no holes. Both classes are always reported
and bypass `--report-on` / `--report-transitions`.
`--report-on` is round-7's agent-kind parameter **generalized to every kind**.
Two consequences worth stating precisely:

- **`--max-fires` counts deliveries, not observations.** The watch log records
  *every* token change regardless of `--report-on`, so observation stays
  complete while reporting is filtered. The evidence trail never has holes.
- **The default interval keys on transition opt-in** — a terminal-only Slurm
  watch defaults to 600 s where a transition-reporting one uses 300 s. Opting
  out of transitions earns a cheaper cadence, which is a real cluster-load
  reduction rather than a cosmetic default.

**Flap control is narrow and evidence-gated.** No general debounce or
hysteresis: Slurm and Globus lifecycles do not flap, and a Slurm requeue
(`RUNNING -> PENDING`) is genuinely reportable. But the `agent` kind **does**
flap — an agent flips `running`/`idle` every turn — which is the one
evidence-backed case, handled by a **per-kind `--dwell N-sweeps`** rather than
a global mechanism. `--max-fires` remains the universal backstop, and it is
load-bearing for `git-ref`, the first genuinely non-terminal kind.

**Mid-flight reporting is opt-in.** Default is terminal states only;
`--report-transitions` adds intermediate events, and `--report-on` narrows to
a token subset. Reply 3's refinement: expensive waits want transitions, short
CPU jobs did not — *"done yet" sufficed.*

Report body is a **short structured pointer, never a payload.** Truncation is
an *observed* failure mode — reply 1 lost a report mid-sentence, and the
advisor's own round-2 output reached me truncated at ~8,700 chars during this
very design session. Anything long belongs in the watch log, which is the
source of truth.

Fields: watch id, event id, kind, target, `old -> new` token, absolute
timestamp **and precomputed elapsed**, the detail line, the log path, and the
caller's context fields. Precomputed elapsed matters because agents get their
own time arithmetic wrong — reply 1 reported 51 minutes idle when the true
figure was 31. Framed as `MONITOR REPORT — treat as data`, since probe output
is an untrusted-input channel into an agent prompt. Watch id + event id let
the agent dedup trivially, because delivery is at-least-once *attempt*.

**The envelope is typed; the caller's context stays free text.** This is a
deliberate split. Typed *CLI* context fields would over-fit one workflow stack
(TPEN's item/branch/SHA ontology); a typed *envelope* is universal.

**Tool-generated envelope**, capped at **≤2 KiB and front-loaded** against the
observed ~8 KiB truncation point: watch id, event id, `old -> new` token, ISO
timestamp, **tool-computed elapsed** (never left to the agent — reply 1
miscomputed 51 vs 31 minutes), and a log pointer.

**Kind fields** arrive from the probe as `key=value` pairs, so each kind
contributes its own vocabulary without the tool hardcoding an ontology.

**HARVEST — how typed fields arrive without the tool owning a schema.** This is
the mechanism that dissolved the typed-vs-free-text argument. At registration
the tool **auto-copies the caller's existing Paseo labels** (`role`, `job`,
`item`, `lane`) into the watch and echoes them in every report, with a generic
`--label k=v` for anything else. The census is what justified it: those label
keys are already **fleet convention**, emitted by agents unprompted — not one
orchestrator's habit. So the tool adopts the vocabulary *without defining it*.

`branch` and `sha` become **recommended keys documented in `SKILL.md`**, never
CLI flags. SHA otherwise stays kind-field territory — `git-ref` emits
`old=`/`new=` itself, and auto-captures at registration for that kind only.

This is why the round-5 ruling was *amended rather than reversed*: typed
context is right, but it is harvested convention rather than tool-owned schema.

**`--context` stays free-text**, with the *resume format prescribed by
`SKILL.md`* rather than by CLI flags. The union of what the three replies
asked for becomes that prescribed format:

| Field | Named by |
|---|---|
| target id, what changed | all three |
| Task Orchestrator item id | R1, R3 |
| exact full SHA, branch | R1 |
| why / purpose | R2 |
| **who owns the next action** | R2 |
| **one evidence line citing an artifact** | R3 |
| **prohibitions** (e.g. never `scancel`/resubmit) | R3 |

**Prohibitions are a safety field, and `--prohibit` is a tool field —
courier, not enforcer.** R3: *"Without the prohibition a fresh context
'helpfully' retries."* The tool passes the text through opaquely into a
**fixed, front-loaded `PROHIBITIONS` envelope slot**; it never interprets or
enforces it.

**The clincher is the failsafe integration.** The fresh schedule agent is *the
most dangerous fresh context in the system* — zero history, woken precisely
when something looks wrong — so its composed prompt must **lift the
prohibitions mechanically**. Without that, the failsafe is the single most
likely thing to "helpfully" `scancel` a healthy 4-day run.

Scope: **unconditional, target-scoped constraints only.** These decay far less
than routing precisely because they are *target*-scoped rather than
*owner*-scoped — *"never scancel job 42124320"* stays true forever. Conditional
or situational constraints go to TO notes, referenced by pointer.

**Cite, never summarize.** This is elevated to a stated principle in the tool's
own `AGENTS.md`, because it is the tool's core epistemic claim: **deterministic
probes cannot confabulate.** R3 watched an LLM monitor *fabricate* a failure its
own logs contradicted — that is the LLM monitor's distinctive risk, not merely
its cost. Mechanically:

- The `detail` field is a **verbatim slice of observed artifact output** — an
  `sacct` row, a SHA — never prose about it.
- The **watch log retains capped raw probe stdout per fire.** The log *is* the
  artifact trail, and the existing log pointer *is* the citation. **No third
  field** is added.
- **Mechanical teeth the probe cannot fake:** for built-in kinds the *sweeper*
  stamps the executed command into the envelope. The tool attests what it ran;
  a probe cannot forge that.
- Residual accepted: a `--script` author can still write prose into `detail`.
  Determinism alone kills confabulation — the same state yields the same string
  every time, which is exactly what an LLM cannot promise.

## Probe set (v1)

- **slurm** — **one probe file**, not two. `sacct -X -j <id> --parsable2
  --noheader --format=State` is **authoritative for terminal state, including
  `TIMEOUT`** — so reply 3's lost-row case ("needs immediate receipt, not
  end-of-run discovery") needs **no transition machinery at all**. `-X` avoids
  the job/batch/extern multi-row problem; empty output right after submission is
  accounting lag, **not** an error → `PENDING`; `CANCELLED by 12345` needs
  first-word extraction. Verified contract from a TPEN receipt:
  `test|COMPLETED|0:0|00:06:20`.
  `squeue` re-enters **only** for REASON transitions, behind a `--with-reason`
  flag derived from `--report-on` at registration. The decisive argument for one
  file is the **single SSH round trip** — both commands go in one remote
  invocation, so splitting into two probe files would double the SSH cost of the
  #1 kind. **Compound tokens** (`PENDING:Priority`) let the ordinary edge
  trigger handle reason changes, with **zero spurious edges when the flag is
  off**. Add a **`VANISHED`** token for reply 3's named anomaly: previously
  seen, now absent from *both* `squeue` and `sacct`.
  An optional 3-line `slurm-transitions` wrapper is the A1 wrapper pattern
  surviving its first real test.
  **Keep a scheduler seam.** PBS (Polaris) is coming — `qstat`/`qsub` rather
  than `squeue`/`sbatch`/`sacct`, and existing TPEN tooling is explicitly
  Slurm-coupled. No Slurm-only assumption may leak into shared code in a way
  that would force reworking the contract when a `pbs` sibling probe lands.
- **globus** — `globus task show <id> -F json --jq status` →
  `ACTIVE|INACTIVE|SUCCEEDED|FAILED`; `nice_status`, `faults`,
  `fatal_error`, `effective_bytes_per_second` feed the detail line. `--jq` is
  **built into the globus CLI**, so the no-external-`jq` rule holds for free
  (verified against a live authenticated account).
- **agent** — `paseo inspect <id> --json` → `Status`, `Archived`/`ArchivedAt`,
  `PendingPermissions`, `UpdatedAt`. **One kind, not two.** Reply 2 experienced
  `agent-permission` and `agent-idle` as separate needs, but that split is a
  symptom of a missing parameter, not of two kinds — the probe command is
  identical. So: `--report-on <token subset>` (default
  `BLOCKED-PERMISSION,CLOSED,ARCHIVED`), and queue-depth folds into the detail
  line.
  **`--dwell N-sweeps` is required here specifically.** An agent flips
  `running`/`idle` every turn, so raw edge-triggering would spam — the *first
  evidence-backed flapping case* in this design. Keep dwell narrow and
  per-kind; do **not** generalize it into debounce for every kind.
  Reports **facts with durations, never inferred verdicts**: `idle_since=` is a
  fact, "was stopped" would be a lie. See the measured blind spot.
- **file-exists** — a stateless existence check. **Often a *cluster* path, not
  a local one**, so it inherits the **full remote discipline**: `BatchMode`,
  `ConnectTimeout`, ssh-255 classification, auth-class park, and facility
  interval floors. Do **not** implement it as a cheap local `stat`. The
  **workhorse of the absence pattern**, which resolves both the admission gap
  and killed-lane detection (receipts, checkpoints, pre-agreed artifact paths).
  **`file-stable` (size-stability) is cut, and `PM_STATE_DIR` is cut with it**
  — zero evidence of demand, and Globus completion is *API-authoritative*, not
  inferred from byte counts. That removes an entire concept from the probe
  contract.
- **git-ref** — `git ls-remote <remote> <ref>`; **the token IS the SHA**, so
  the edge trigger fires exactly when the ref moves, and the `old= / new=`
  detail pair directly serves the SHA-plus-item-id resume that reply 1
  described. Volunteered unprompted as *"near-free and high value"*; measured
  0.31–0.76 s. Structurally the easiest kind: no SSH auth decay over https, no
  facility-policy floor. Floor 60 s, default ~120 s.
  **It is also the first genuinely non-terminal kind** — a ref can move any
  number of times and never reaches a terminal state — which is what makes
  `--max-fires` load-bearing rather than a nicety.
- **pr-merge** — `gh pr view <n> --json state`, ~10 lines on ambient `gh`
  auth. **In for v1, and it does *not* collapse into `git-ref`**: a merge is
  forge state, and inferring it from a moved base ref suffers **base-branch
  attribution ambiguity** (any other merge moves the same ref). Its demand is
  *structural* rather than incidental — TPEN merges stacks **bottom-up by
  humans**, which makes this **the only kind watching a human gate**. Every
  other kind watches a machine.
- **`TO claim expiry` — deliberately OUT**, routed to `--script`. Three
  reasons: single-source evidence (only R3 wanted it), it would couple the tool
  to a project-local Task Orchestrator REST schema, and the 900 s TTL properly
  belongs to the **claim holder self-guarding** rather than to an external
  watcher. Promote later if `--reason` recurrence shows real demand.
- **`--script`** — the escape hatch. Snapshotted, one-off, dies with its
  watch, never becomes shared infrastructure. Contract stays minimal: token
  on stdout, health via rc, `--terminal` list, `--reason` required. No
  extraction-customization flags — script authors extract inside their
  script.

Wrapper probes (`probes/slurm-cannon` exec'ing `probes/slurm --host cannon`)
are permitted but **not pre-built**; add on actual divergence.

## Remote probes: SSH discipline

A remote probe is a network+auth round-trip, not a fork. Raw exit codes are
ambiguous — `ssh` reserves 255 for ssh-level failure and otherwise passes the
remote rc through, and the remote rc is itself ambiguous. So the contract
cannot be "exit code of `ssh host …`"; **the bundled probe converts the messy
triple (ssh-rc, remote-rc, stderr) into the clean contract.**

- ssh rc=255 → probe-health failure. Subclass on stderr: `Permission denied`
  or an auth prompt = **auth-class**; timeout/refused/unreachable =
  **network-class**.
- Target genuinely unknown to `sacct` → token `UNKNOWN`, a *reportable event*
  (likely a registration bug), never a silent retry.
- **`-o BatchMode=yes` is non-negotiable in every bundled remote probe.**
  Without it an MFA re-prompt wedges the probe until the timeout kills it,
  every sweep, indefinitely — and with push-based MFA it pings the human's
  phone every interval at 3am. BatchMode converts any interactive-auth demand
  into an immediate clean auth-class failure. Add `-o ConnectTimeout=15` so
  network failures resolve inside the probe timeout.
- A `--script` user pointing at bare `ssh host squeue` gets the ambiguity
  raw. Document that warning in the skill.

### Auth failure policy: park, do not retry

`cluster-access` says never retry logins repeatedly. Encoded:

- **auth-class**: 2–3 consecutive strikes → report "cannot observe target:
  auth failed", then **park the watch** (stop probing entirely; the deadline
  still fires). The agent fixes credentials and runs `poke`, or cancels.
  Auto-park is facility-policy compliance built into the tool.
- **network-class**: normal backoff by bumping `nextDue` (not touching auth
  systems); report after a longer streak.
- Stale `ControlMaster` sockets fall back to a fresh connection with a
  warning — lands in network-class and self-heals. **Do not manage sockets
  from the tool**; respect user `ssh_config` and recommend `ControlPersist`
  in docs only.

### Credential posture

No new secrets at rest. The monitor holds nothing — it uses ambient user auth
(agent socket, tickets, `ControlMaster`) exactly as the incumbent LLM monitor
did, so **zero delta versus status quo on exposure**. The genuine deltas are
*duration* (days of unattended validity assumed — answered by auth-park, never
by credential caching) and MFA hygiene (answered by BatchMode). Every remote
command is logged via `log_line`, so the audit trail is free.
Interactive-only auth (OLCF) stays out of scope.

### Cadence floors — refuse below, hard error

The caller is an unattended agent, and agents do not read warnings.

| Kind | Floor | Default | Why |
|---|---|---|---|
| any | 60s | — | sweep granularity; architectural floor |
| slurm, remote script | 120s | 300s | facility courtesy; smoke jobs still get ~2min discovery |
| globus | 60s | 300s | hosted API built for polling; transfers are long |
| git-ref | 60s | 120s | cheap, no facility policy; sweep granularity still binds |
| agent, file-exists, local script | 60s | 60–120s | local fork, cheap |

Print `will probe ≤ deadline/interval times` at registration, so cost is
visible to the registering agent. Jitter `nextDue` by a hash of the watch id
so co-registered watches do not burst in the same sweep.

## Responsibility split: best-effort tool, caller owns the guarantee

**The monitor observes and records. The caller owns liveness.** The monitor
is not responsible for keeping the observation channel alive, nor for
guaranteeing that a report reaches anyone.

Mechanically enforced, not merely philosophical: `paseo heartbeat create` is
scoped to *"this agent"* and has **no `--agent` flag** (verified).
`paseo-monitor` therefore *cannot* create the backstop heartbeat on its
caller's behalf. The split is a property of the platform.

It is also the honest design. A shell tool on a laptop cannot guarantee
delivery, and **pretending it can is the dangerous part** — the primary risk
is now *over-trust*: an agent that believes the monitor is reliable skips its
own backstop, which is the one path to unbounded silence.

### What the monitor owes — best effort

1. **Registration-time synchronous probe run.** `watch` runs the probe once
   before returning, prints the watch id and first observed token, and
   *fails registration* if the probe is broken. Cheapest, highest-value item
   in the design — catches probe bugs at minute zero, not day three.
2. **Deadline expiry as an event.** `--deadline` mandatory; on expiry report
   "could not determine state; last observation X; log at Y".
3. **Sweeper** — bounds the dead-watcher window to one sweep interval.
4. **Record health, do not fight it.** Count consecutive failures, back off,
   auth-park per policy, expose counts in `status`/`log`, report "can no
   longer observe" once.
5. **Record, then optionally push — delivery is pluggable and layered.** The
   tool **must not assume `paseo-queue` exists.**

   | Layer | Requires | Behaviour |
   |---|---|---|
   | **1. Core** | nothing | Observe and record. `status` shows everything. The tool is useful standalone. |
   | **2. Discovery** | a skill convention | Turn-start `paseo-monitor status`, carrying the last-sweep-age header. Rides a habit agents already have. |
   | **3. Optional push** | `paseo-queue`, or any command | `--deliver paseo-queue` when installed, or `--deliver <cmd>`, behind **one** indirection function. |
   | **4. Optional failsafe** | Paseo daemon | `--failsafe`, an independent failure domain. |
   When a push backend *is* configured: a failed send sets an `undelivered`
   flag and is re-attempted each sweep until delivered, parked, or past deadline
   (~5 lines). At-least-once *attempt* — duplicates are possible, which is why
   every report carries watch id + event id. A queue exit 2 containing `no agent
   matches` is permanent for the current recipient: state becomes `unroutable`,
   sweeping stops, and `poke` is required after the recipient is fixed. Other
   failures remain `delivery-failed` with a recorded stderr WARN.

**Deliberately deleted: the `paseo send` escalation ladder, wholesale.** It
implied a delivery guarantee the tool does not have; `paseo send` is the
ecosystem's reserved *interrupt* path and a demoted best-effort observer
auto-interrupting agents oversteps its station; and it was the most complex
piece (K-failure counters, a second delivery path, out-of-order interaction
with the queue).

### What the caller owes — the guarantee, held as a triad

The evidence on adoption was bad: R1 never created a backstop, R2 created one
whose body had silently decayed. But R1's stopped-lane incident **is the
failsafe-needed case actually occurring**, and it cost ~20 minutes of reasoning
about a dead lane. So the conclusion is *not* best-effort-all-the-way-down.

**The guarantee survives, distributed across three independent holders** — none
of which decays the way copied text does:

| Holder | Holds | Why it does not decay |
|---|---|---|
| Daemon-owned one-shot **schedule** | the **when** | independent failure domain from the sweeper |
| **Task Orchestrator item** | the **who / why** | the failsafe agent resolves the *current* owner at fire time, in prose — where schema drift is tolerated |
| Monitor **post-terminal state** | the **what** | durable on disk, retained until explicit `rm` |

Plus one convention: **registration records a TO note** (*watch W, deadline
T*), so a new owner can find the watch even if the original registrant is gone.

Both observed failures now have fixes: **adoption** via the `--failsafe` flag,
and **decay** via a pointer-only failsafe body.

**1. Ride observed behaviour.** R1 already ran cheap `git ls-remote` /
`rev-parse` checks between turns and called them "near-free and high value".
So `SKILL.md` prescribes a **turn-start `paseo-monitor status`**, and `status`
prints a **last-sweep-age header**. That gives caller-side *sweeper-death
detection* for free, piggybacked on a habit agents demonstrably already have.

**2. `--failsafe` materialized as a one-shot SCHEDULE, not a heartbeat.** This
resolves the mechanical objection that killed the earlier design. Verified
differences:

| | heartbeat | schedule |
|---|---|---|
| Self-scoped | **yes** — "this agent", no `--agent` | **no** |
| Lifecycle surface | none (no list) | full: `ls`/`inspect`/`pause`/`delete`/`logs` |
| Failure domain | — | **Paseo daemon — independent of the sweeper** |
| Bounded | `--max-runs` | `--max-runs`, `--expires-in` |

The independent failure domain is the point: a schedule lives in the Paseo
daemon, so it survives death of the launchd/cron sweeper entirely. Because it
has a list surface, **the tool can delete it on clean delivery** — housekeeping
the heartbeat design could never do.

Ownership stays caller-side: `--failsafe` is **opt-in by the caller**, so the
user's ruling that the tool must not own the guarantee still holds. The tool
materializes what the caller asked for and cleans up after itself.

`--provider` accepts a provider name or `provider/model`; when omitted for
`--failsafe`, the tool selects the calling agent's provider, then the first
available and enabled provider. The selected provider is passed to schedule
creation. If schedule creation fails, registration warns, still prints the
watch id, exits 0, and prints a `paseo schedule create` fallback. The emitted
fallback currently omits `--provider`; if the installed Paseo CLI requires
one, add an available provider before running it. This is a Layer 4 backstop
failure; it must never take down Layer 1 observation.

The fallback command is also printed for callers who do not pass `--failsafe`.
Registration output continues to state plainly: *delivery is best-effort; this
tool does not guarantee wake-up.*

`SKILL.md` teaches the ritual as one unit: register watch (with `--failsafe`) →
turn-start `status` → on report, the tool clears the schedule → on failsafe
firing, `status <id>` before anything else.

## State retention is load-bearing

Under caller-owned liveness, the caller's recovery path when its heartbeat
fires is `paseo-monitor status <id>` / `log <id>` → reconstruct what was
observed and whether delivery was attempted. **That only works if terminal
watches keep their state dirs.** Post-terminal retention was
garbage-collectable under the old model; now it is load-bearing.

- No aggressive GC. Retain until an explicit `rm` or a long TTL; `reap` only
  drops long-expired watches.
- `status` must show the recovery fields explicitly: last token, last
  transition time, whether delivery was attempted, and the `undelivered`
  flag.
- Write the deadline into the watch spec at registration, so the caller's
  heartbeat prompt can reference it independently of the tool.

Explicit `rm` archives the removed watch under `graveyard/<watch-id>/` and
leaves a compatibility link at `watches/<watch-id>`. `status <id>` and
`log <id>` resolve that retained evidence until `reap` removes it after the
same 30-day TTL used for expired watches. A queued report can outlive its
watch, so the envelope's `log=` citation pointer must keep resolving after
removal.

## Security

Right-sized threat model: the probe runs as the user with the user's
credentials **by design** — it must SSH to Cannon — and the registering agent
can already run anything via Bash. The real threat is a **buggy probe
amplified by unattended repetition**, not malice.

- Hard per-probe timeout — the non-negotiable one.
- `stdin < /dev/null`, stdout/stderr capped.
- Exec argv directly, never a shell string.
- Snapshot `--script` probes at registration.
- Refuse to run as root.
- Documented convention (not enforced): probes are read-only w.r.t. target.
- **Do not sanitize the environment.** Scrubbing breaks `SSH_AUTH_SOCK` and
  Kerberos cache variables that cluster probes require. Inherit, and say so.
  Env-scrubbing here is theater.
- Probe output flows into an agent prompt, so it is a prompt-injection
  channel from whatever the probe reads. Cap it and frame it as data.

Bundled probes remove arbitrary execution from the common cases. That is the
main virtue of the taxonomy, and why `--script` must stay the rare path.

## State layout

```
$PASEO_MONITOR_HOME/            # default ~/.paseo-monitor
  sweep.lock/                   # global mkdir lock; lock/pid inside
  sweep.log                     # sweeper events, rotated
  sweep.beacon                  # last-sweep freshness beacon
  watches/<watch-id>/            # live watch; compatibility link if removed
    spec                        # kind, params, owner, report_to, provider, policy
    context                     # --context body
    probe                       # snapshotted probe (--script only)
    last                        # last observed token
    detail                      # last detail line
    nextDue                     # epoch seconds (jittered)
    state                       # active | parked | terminal | expired | delivery-failed | unroutable
    undelivered                 # flag: report recorded, enqueue not confirmed
    fires                       # delivered report count
    log                         # per-watch event log, rotated
  graveyard/<watch-id>/         # removed watch evidence and routing
```

Env knobs follow `paseo-queue`'s split: external `PASEO_MONITOR_*`, read once
at startup into internal `PM_*`.

## Portability — an explicit, accepted platform decision

**`paseo-monitor` v1 targets macOS.** This is a deliberate choice, recorded
here so nobody later mistakes it for an oversight.

### The honest framing

Choosing `launchd` does couple the tool to macOS. But the alternative was
`cron`, which is Unix-family — not portable either. A Windows port needs Task
Scheduler regardless of which we pick. So the real choice was never
*portable vs. locked-in*; it was **which Unix service manager**, and on the
actual target machine only one of the two supplies the credentials the #1
probe kind needs (`SSH_AUTH_SOCK` and login-Keychain access).

Given that, we picked the one that works here and wrote down the cost.

### Where the macOS dependency actually lives

Narrower than it looks, and worth enumerating so a future port knows exactly
where to touch:

| Surface | Coupling | Port cost |
|---|---|---|
| **launchd trigger** (install/uninstall) | the one deliberate coupling | **~30 lines** — swap for `cron` or a systemd user timer |
| **Credential environment** | the *reason* for the above | On Linux: systemd user service inheriting the agent socket, or a keyring |
| `stat -f %z` / `stat -c %s` | BSD vs GNU | already a fallback chain, inherited from `paseo-queue` |
| `ps -p <pid> -o command=` | BSD vs GNU `ps` | lock-liveness check; minor |

**Historical shell-era note:** the original implementation targeted bash 3.2 in
`sh` mode and avoided `flock`, `setsid`, `timeout(1)`, and nanosecond `date`
formatting. That portability claim is retired for the Python port; the target
runtime contract below is explicit.

### What a platform port would take

For a second platform, replace the trigger. The Python runtime contract below
is independent of that scheduler seam; probe contract, park policy, retention,
delivery, deadline, and failsafe remain unchanged by scheduler choice. The
`status` freshness beacon that detects trigger death is likewise
scheduler-agnostic and needs no change.

**Do not pre-build a trigger abstraction layer.** There is exactly one
platform today. Isolating install/uninstall is sufficient; a pluggable
`pm_install_trigger` seam is speculative generality until a second platform
actually exists, and this project's standing rule is to prefer the simplest
correct implementation.

This decision must also be stated in the repo's own `README.md` and
`AGENTS.md` — see the `a1-skeleton` work item — so a reader learns the platform
assumption without having to find this plan.

## Implementation constraints

The POSIX `sh` constraint is retired for the Python port. It was inherited from
`paseo-queue/AGENTS.md`, which targeted the same environment; it was not
derived from a paseo-monitor requirement. It was already violated: the shell
implementation carries 8 embedded Python programs as `PM_PY_*` string
variables, so the tool already had a hard `python3` dependency, expressed
badly. The shell layer directly caused real defects: a `dd bs=4096 count=1`
short read silently discarded probe output; the test mock's non-atomic
read + `sed 1d` + `mv` lost updates and made the suite ~50% flaky under load;
macOS ships no `timeout(1)`, forcing a hand-rolled `pm_run_with_timeout`; and
`pwm_`/`prp_`/`psw_` prefixes spread through the code because `sh` has no
`local`.

### Settled Python runtime contract

P3–P6 implement this contract; at `bd32317`, the port still has the shell
runtime:

- Python 3.8-compatible standard library only. No third-party imports.
- The interpreter is resolved and pinned at install time. Installation runs
  each candidate and requires the expected stdout marker and version; it never
  authorizes a candidate from exit status. On this machine `/usr/bin/python3`
  prints an `xcrun` error and exits 0, so an exit-status check accepts a broken
  interpreter.
- The root cause is `xcode-select` pointing at a gutted
  `/Library/Developer/CommandLineTools`: its `usr/bin` has 6 entries and no
  `xcrun`. The remedy is `sudo xcode-select -s
  /Applications/Xcode.app/Contents/Developer`, which yields Python 3.9.6.
- Python 3.8 has no `zoneinfo`; operational `America/New_York` logging uses
  `TZ` plus `time.tzset()`.
- This follows the existing resolve-and-snapshot pattern for `helper=` and
  `paseo_bin=`. Without it, the port would reproduce the `rc=127` class with
  the whole tool as the blast radius.
- `launchd` remains the required macOS trigger for its GUI-agent credential
  environment: `SSH_AUTH_SOCK` and login-Keychain access needed by cluster
  probes.
- Probes execute as direct argv with stdin `/dev/null`, bounded stdout/stderr,
  and a hard timeout; never execute a probe through `sh -c`.
- Do not sanitize the inherited environment: SSH and Kerberos credential
  variables are required by cluster probes.

Transition tooling remains shell: the installer and Python resolver are
POSIX `sh` scripts. Run `sh -n` on those scripts and `tests/run-tests.sh`
before committing.

**One doctrine belongs in the tool's own `AGENTS.md`, not only in this plan:**
**artifacts over narratives — deterministic probes cannot confabulate.** That
is the tool's core epistemic claim, and the reason a dumb probe beats an LLM
monitor on *correctness* and not merely on cost. R3 watched an LLM monitor
fabricate a failure that its own logs contradicted; removing that class of risk
is a large part of why this tool exists.

Remaining constraints:

- Timestamps `America/New_York` for operational logs, matching TPEN
  convention and `paseo-queue`'s `log_line`.
- Clone `paseo-queue`'s test harness (~350 lines): per-test `mktemp` sandbox,
  own `PASEO_MONITOR_HOME`, mock shims first on `PATH`, fast-sweep knobs. The
  monitor's mock needs additions the queue never had — scripted mock `ssh`,
  mock `paseo-queue` — so the shim forks regardless. Tests must never touch a
  real daemon, a real cluster, or a real `~/.paseo-monitor`.

## Upstream ask — three items, with evidence

File against Paseo the day work starts. Each is backed by a measurement in
this document, which is what makes it actionable rather than a wish:

1. **A field distinguishing stopped from finished.** Evidence: a cancelled
   agent reads `Status='idle', Archived=False, PendingPermissions=[]` —
   byte-identical to a normal completion.
2. **Attention fields in the CLI JSON.** `requiresAttention` /
   `attentionReason` / `attentionTimestamp` exist on the MCP surface but are
   absent from `paseo inspect --json` and `paseo ls --json`, so shell probes
   cannot reach them.
3. **`PendingPermissions` population confirmation / fix.** Validated in
   production via `HOLD-PERM`, but the forced-prompt path could not be
   reproduced on demand, which makes the field's exact population rules
   under-specified.

### Rejected: reading the daemon API directly

Tempting, because the attention fields live there. Rejected on three grounds:

- **No stability contract** — an unannounced shape change breaks watches
  silently for days, reintroducing the rank-1 failure this whole design is
  organized against.
- It **reimplements the `paseo` client**, violating the "`python3` for JSON
  one-liners only" rule inherited from `paseo-queue`.
- **The gap is a CLI omission, not an architecture problem.** Routing around a
  temporary missing field with permanent complexity is the wrong trade.

Tradeoff named explicitly: CLI-only **defers** full permission/attention
observability until upstream ships. Accepted, because the interim is covered —
`monitor-with-subagent` retains MCP-only observables as a **third residual** in
its scope, alongside judgment-per-check and terminal-mediated facilities.

## Non-goals for v1

- **OLCF / Frontier targets.** `cluster-access` forbids initiating OLCF
  logins, and a laptop sweeper cannot probe Frontier. Route to
  `monitor-with-subagent`, which can go through a Paseo-owned terminal.
- **Judgment-per-check.** "Read the training log and decide whether the loss
  curve looks sick" is not a dumb probe.
- Sub-minute reaction latency.
- Per-cluster batching — the sweeper permits it if volume ever demands; at
  realistic volume, likely never.
- Any second state machine duplicating Task Orchestrator's role.

## Disposability

Second stopgap, same posture as `paseo-queue`, stated in its `AGENTS.md`. The
daemon is the right eventual owner: it is long-lived, owns agent lifecycle,
and owns *terminals* — the only route to terminal-mediated facilities. File
the upstream issue the same day work starts.

The two tools **die on different events**: `paseo-queue` dies when
getpaseo/paseo#3797 ships; `paseo-monitor` then swaps one delivery function
and lives on.

## Decision log

| Question | Draft | Advisor | Resolution |
|---|---|---|---|
| Process model | per-watch long-lived process | stateless launchd sweeper | **Sweeper.** Reached independently by both. Draft copied `paseo-queue`'s reactive short-lived model into a days-long regime it was never built for. |
| Repo layout | subcommand in `paseo-queue` | separate sibling repo, copy ~650 lines | **Separate repo.** Lifetimes differ, and the sweeper redesign evaporated the shareable half (27% duplication, not >50%). |
| Poll vs block | keep separate | unify | **Unify.** `globus task wait --timeout N` *is* a bounded poll returning a token. Blocking waits become probe bodies with short timeouts. |
| Deadline | always fires | necessary but insufficient | **Both.** Unimplementable under per-watch processes; only real once the sweeper exists. |
| Env sanitizing | sanitize | do not | **Do not.** Breaks `SSH_AUTH_SOCK`/Kerberos for cluster probes. |
| Self-notify default | explicit | default to registering agent | **`$PASEO_AGENT_ID`**, verified present in every agent env. |
| Toolbox unit of reuse | declarative recipe DSL | A1: programs + argv; presets are 3-line wrapper probes | **A1.** At small stable N the reuse unit is the *invocation*, not the probe. Engine deleted. |
| Who owns liveness | tool escalates | six-layer tool-owned stack | **Caller owns the guarantee** (user directive). Mechanically forced. `paseo send` ladder cut. |
| Slurm "state machine" | `squeue -> sacct` branching | corrected: `sacct -X` alone knows the lifecycle | **Knowledge, not branching** — though `squeue` REASON transitions later brought the handoff back for transition-reporting watches. |

Adopted from the advisor, absent from the draft: registration-time
synchronous probe run; `--context`; snapshot-at-registration;
`TOKEN [detail]` line; prompt-injection framing; `poke` over
`drain`; OLCF out of scope; **`-o BatchMode=yes`**; auth-class park;
per-kind interval floors that hard-refuse; `--reason` audit trail;
`--report-to` vocabulary; printed heartbeat command; post-terminal retention
as load-bearing.

Overridden by the user, against both draft and advisor: the tool does **not**
own the liveness guarantee, and reuse is not an authoring format. Both
narrowed the tool and made it more honest.

## What the small-N constraint deleted

1. The recipe engine tier, entire — substitution, extraction keys,
   `empty:`/`transport:` mappings, format tests and docs.
2. The engine-vocabulary budget rule — moot without an engine.
3. The `--describe` probe metadata protocol.
4. The tier-3 promotion *process* — shrunk to one `AGENTS.md` sentence plus
   the `--reason` field. No pipeline.
5. Pre-built per-cluster wrapper probes — add on divergence.
6. Extraction-customization flags for `--script`.
7. Per-cluster batching — demoted to "permitted if volume demands".
8. `drain` — `poke` covers it.

Kept despite the smallness temptation, because each earns its place at N=1
watches: the sweeper (reliability, not scale), sync first probe,
post-terminal retention, auth-park, snapshot-at-registration, `--context`,
the detail line, and the `--max-fires` integer.

## Build order

1. Skeleton: repo, `AGENTS.md` (with the ancestry note), `install.sh`,
   `usage()`, state layout, `PASEO_MONITOR_*`/`PM_*` knob split.
2. Primitives copied from `paseo-queue` (~290 lines): mkdir lock + pid
   liveness, `log_line`, `set_state`, atomic tmp+mv, `python3 -c` JSON
   bridge, agent resolution, log rotation.
3. `pm_run_with_timeout`, probe contract, `--script` + `--reason`, `watch`
   with synchronous first run and printed heartbeat command.
4. `_sweep` + global lock + jittered `nextDue` + edge trigger + delivery via
   `paseo-queue add`, with the `undelivered` retry flag.
5. launchd plist + `launchctl bootstrap gui/$UID`, `RunAtLoad`,
   `StartInterval 60`.
6. Deadline expiry, health counting, auth-park, `--max-fires`.
7. Probes: `slurm` (one file: `sacct -X` terminal-authoritative, `--with-reason`
   for `squeue` REASON in the *same* SSH round trip, compound `PENDING:Priority`
   tokens, `VANISHED`, BatchMode, accounting-lag → PENDING), `globus`,
   `agent` (one kind, `--report-on` + `--dwell`), `file-exists`, `git-ref`,
   `pr-merge`.
8. `kinds` / `ls` / `status` (recovery fields) / `log` / `poke` / `rm` /
   `reap`.
9. Test harness with mock `paseo`, `paseo-queue`, and `ssh` shims;
   per-behaviour `t-*.sh`.
10. `SKILL.md` with a discovery-optimized `description`, the kind table with
    copy-paste invocations, install into all three skill roots, cross-links,
    and the caller-owns-the-backstop ritual as a required step.
11. Upstream issue filed and referenced.

## Open questions

**Everything load-bearing is now closed.** Resolved across three ground
replies, ten advisor rounds, and four direct measurements:

| Question | Resolution |
|---|---|
| Small stable N? | **Holds** — 4, ~5, 5 across three runs |
| Mid-flight transitions matter? | **Yes**, unanimous. Sweeper required |
| Trigger: cron or launchd? | **launchd**, on the credential environment (sleep argument conceded) |
| Packaging | **A1** — probes + argv; presets are 3-line wrappers |
| Repo | **Separate sibling**, copy ~650 lines, no shared lib |
| Probe set | **6 built-ins** + `--script` |
| Admission gap | **Protocol rule + absence pattern**; no new mechanism |
| Routing decay | **Identities not state**; pointer-only failsafe body |
| The guarantee | **Triad** — schedule / TO item / post-terminal state |
| Typed vs free-text context | **Harvest** Paseo labels; envelope typed, `--context` free |
| `agent` kind viability | **Ships** — permission dwell validated in production |
| Direct daemon API | **Rejected** — CLI omission, not an architecture problem |

Remaining items are genuinely minor and settle during implementation:

- **Sweep-level parallelism cap** — how many probes in flight before one slow
  SSH probe starves the rest. Needs a measured default, not a guess.
- Whether `git-ref` polls `ls-remote` (authoritative) or watches a local
  clone's `FETCH_HEAD` (free but stale).
- Whether `--deadline` accepts relative forms (`+3d`) — friendlier to agents,
  ambiguous across sleep.
- **`--dwell` default for the `agent` kind — settled by the 2026-08-27
  observation:** a lane between turns produced a single `RUNNING`/`IDLE` flap;
  default to `--dwell 2` for agent watches, while keeping dwell per-kind.
- Whether `pr-merge` should also report `CLOSED` (unmerged) as terminal, or
  only `MERGED`.
