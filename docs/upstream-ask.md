# Paseo CLI observability: stopped state, attention fields, and permission rules

**Issue:** [YizhongHu/paseo-monitor#1](https://github.com/YizhongHu/paseo-monitor/issues/1) — local upstream-ask draft.

## Ask

Please address these three related observability gaps in one upstream change or issue. They prevent a bounded, non-LLM watcher from reporting agent state without guessing.

### 1. Expose a field that distinguishes stopped from finished

Expose a stable field that distinguishes an agent interrupted by a user from one that finished normally.

**Measurement:** A cancelled agent read `Status='idle'`, `Archived=False`, and `PendingPermissions=[]`. That was byte-identical to a normally-finished agent. In a 200-agent census, the observed `Status` values were `running` (4), `idle` (36), and `closed` (160), with a separate nullable `archivedAt`; there was no `stopped` status. No polling cadence can recover a state that is not represented.

### 2. Expose attention fields in CLI JSON

Expose `requiresAttention`, `attentionReason`, and `attentionTimestamp` through the CLI JSON returned by `paseo inspect <id> --json` (and, where applicable, `paseo ls --json`).

**Measurement:** The fields exist on the MCP/daemon surface; `attentionReason: "finished"` was directly observed. `paseo inspect <id> --json` exposed exactly these keys and none of the attention fields: `Archived, ArchivedAt, AvailableModes, Capabilities, CreatedAt, Cwd, Id, LastUsage, Mode, Model, Name, ParentAgentId, PendingPermissions, Provider, Status, Thinking, UpdatedAt, Worktree`. `paseo ls --json` exposed only `created, cwd, id, name, provider, shortId, status, thinking`. A POSIX `sh` probe shelling out to the CLI therefore cannot reach the attention fields.

### 3. Document `PendingPermissions` population rules

Document when `PendingPermissions` is populated and how a caller can reproduce or rely on it.

**Measurement:** The field demonstrably populates through the CLI in production: `paseo-queue` reads the identical `paseo inspect <uuid> --json` field and logs `HOLD-PERM`; 49 `HOLD-PERM n=1` lines were present in real dispatcher logs from 2026-08-26. A deliberate forced-prompt reproduction did not populate it: an agent in `default` ("Always Ask") mode auto-approved a classifier-safe `echo` without prompting, and `list_pending_permissions` returned 0. The production behavior is real, but its exact population rules are not reproducible on demand from that experiment.

## Why the watcher does not call the daemon API directly

Reading the daemon API directly was considered and rejected. It has no stability contract, so an unannounced shape change could silently break watches. This is a CLI omission, not an architecture problem; routing around it would permanently add complexity to avoid a temporary missing CLI field.

## Cross-reference

The design document records `getpaseo/paseo#3797` as an upstream reference; verification found that reference is currently PR [#3797](https://github.com/getpaseo/paseo/pull/3797). This consolidated ask is filed in the issue linked at the top of this document.
