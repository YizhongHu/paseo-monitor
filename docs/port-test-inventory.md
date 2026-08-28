# Port test inventory

P1 separates fixture setup from the executable under test. The test suite had 27
`source_monitor` invocations before P1 and has 8 after P1. The eight remaining
invocations are deliberate internal-unit seams; they are not fixture setup.

## Remaining internal-coupled tests

| Test | Invariant currently asserted | Disposition |
| --- | --- | --- |
| `tests/t-01-lock.sh` | `mkdir`-based global lock acquisition rejects a live owner, recovers a dead PID, records the acquiring PID, and releases cleanly. | **Python unit test in P3** for the lock primitive, especially stale-PID recovery and PID ownership. Live-lock exclusion is also exercised at the CLI level by `t-08-sweeper.sh`, but that does not replace the stale-PID and exact-owner assertions. |
| `tests/t-02-atomic-write.sh` | Atomic writes create parent state, replace existing content, leave no temporary file, and support `set_state`. | **Python unit test in P3.** The temporary-file-plus-rename invariant is implementation-level; no CLI command exposes it without weakening the assertion. |
| `tests/t-03-log-rotation.sh` | Log lines use the required New York timestamp format; oversized root logs rotate to `.1`; watch logs use the same writer. | **Python unit test in P3.** CLI tests observe emitted logs, but cannot preserve the direct rotation and timestamp-writer assertions exactly. |
| `tests/t-04-knob-split.sh` | Startup maps public `PASEO_MONITOR_*` knobs to internal values exactly once, with the expected defaults and validation boundary. | **Python unit test in P3.** The current test also greps shell source for `PM_HOME` and `PM_FAST_SWEEP` assignments. Those source-text assertions cannot apply to a Python entrypoint and must be replaced in P3 by behavior/configuration assertions; no assertion was weakened in P1. |
| `tests/t-05-json-bridge.sh` | JSON agent records resolve by exact name and UUID prefix; status/archive/permission fields bridge to the normalized internal result. | **Python unit test in P3.** Direct `pm_match_agent`, `inspect_agent`, and `resolve_agent` calls are helper contracts; routing them through a full CLI flow would lose exact bridge-result assertions. |
| `tests/t-06-probe-contract.sh` | Direct probe execution preserves fragmented stdout, caps stdout at 4096 bytes, distinguishes target observations from probe-health exit codes, and returns `124` for hard timeout. | **Python unit test in P3.** The timeout marker, output cap, and health-vs-target separation are direct runner invariants. A CLI test could cover outcomes but would not preserve all four assertions exactly. |
| `tests/t-12-remote-harness.sh` | SSH probes use `BatchMode=yes` and `ConnectTimeout=15`; authentication and network failures both retain rc 255 but classify separately; registered remote file probes map present/absent output correctly. | **Python unit test in P3.** The direct remote runner and classifier assertions are narrower than the public registration flow; replacing them with CLI-only checks would weaken argv and classification coverage. |
| `tests/t-20-pbs.sh` | The Slurm parser extracts the first state token (`COMPLETED`) at the PBS/Slurm seam after PBS behavior is exercised. | **Python unit test in P3.** The direct `pm_parse_probe_output` call is a parser seam assertion; the surrounding PBS behavior remains CLI-level. |

P1 did not delete or weaken any assertion in these eight tests. They remain
against the shell implementation until P3 ports their internal contracts to
Python tests. `tests/common.sh` retains `source_monitor` solely to support these
seams.

## Fixture-only decoupling

The following tests no longer source the monitor implementation. Their durable
fixture writes now use plain shell (`printf` redirects), and time fixtures use
`date +%s`:

- `t-07-registration.sh`
- `t-08-sweeper.sh`
- `t-09-delivery.sh`
- `t-10-health.sh`
- `t-13-slurm.sh`
- `t-14-agent.sh`
- `t-15-cli.sh`
- `t-16-git-ref.sh`
- `t-17-pr-merge.sh`
- `t-18-globus.sh`
- `t-19-file-exists.sh`
- `t-21-harvest.sh`
- `t-22-failsafe.sh`
- `t-23-fast-terminal.sh`
- `t-24-cancellation.sh`
- `t-25-started-report.sh`
- `t-26-failsafe-failure.sh`
- `t-27-provider.sh`
- `t-30-ownership.sh`

`t-08-sweeper.sh` previously sourced `acquire_lock` only to hold the global
lock. It now starts a real `_sweep` with a sleeping probe and contends through
the CLI, preserving the quiet-skip and unchanged-observation assertions without
shell sourcing. `t-15-cli.sh` likewise uses the public `status` command rather
than calling `pm_status` directly.

The remaining count is measured as invocations in `tests/t-*.sh`, excluding the
`source_monitor` function definition in `tests/common.sh`: **27 before, 8
after**.
