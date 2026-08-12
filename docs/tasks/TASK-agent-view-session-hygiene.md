# TASK — a closed task must leave no Agent View rows behind

Author: orchestrator session, 2026-08-12. Everything below was observed on live runs of this plugin
against the `motivehr` repository today. Every claim is backed by a command, a file:line or real
output; anything unverified is marked **(unverified)**.

**The complaint, in the owner's words:** a task that is finished and deployed should not leave
sessions visible in Agent View. Today task `1216457377933945` was integrated into develop and master,
its worktree and branch were gone, its factory row was `done` — and Agent View still listed **four**
background sessions for it.

## Why four rows survived one finished task

`claude rm <background-id>` is the only mechanism that removes an Agent View row. It appears in
exactly one place in the whole plugin:

- `scripts/cleanup-task.ps1:290` — and only for `$backgroundId`, i.e. the **single** id currently
  stored in `task.backgroundSession.id`.

Everything else that ends a session stops it and leaves the row:

| Site | What it does | Row left behind |
|---|---|---|
| `scripts/worker-launch.ps1:263, 294, 307, 337, 365, 379` | `Stop-FactoryClaudeSessionAndWait` on every stray from the `--agent` fallback ladder | yes, one per stray |
| `scripts/answer-task.ps1:44` | `claude stop` on the previous attempt's session before queuing a new one | yes, one per answer/relaunch cycle |
| `scripts/reject-task.ps1:209` | `claude stop` on the task's session before discarding artifacts | yes, always |
| `scripts/cleanup-task.ps1:280-298` | `stop` + `rm`, best-effort, **one id only** | every other row of that task |

So a task that was answered once and relaunched once accumulates rows, and cleanup removes exactly
one of them. That is the whole defect.

For the record, the four rows of `1216457377933945` and where each came from:

```text
6fb10840  done  started 10:49:32  ← stray from the native --agent attempt (stopped, never rm'd)
1b017bb1  done  started 10:49:34  ← the surviving first launch
6b349f1b  done  started ~17:02    ← a session started from Agent View / respawn during the chat
35c287bf  done  started 18:14     ← relaunch after /factory answer; the only one cleanup removed
```

The first two are two seconds apart because of the fallback ladder: the native `--agent` attempt is
spawned, detected as fallen back to the default template, stopped, and replaced. Note this is now
rare rather than constant — the version-scoped `agentResolutionCache` means the known-bad native path
is skipped on subsequent launches, so strays appear only on the **first** launch after a CLI version
change. Verified today: seven task launches produced seven rows, no strays.

## A second, worse symptom of the same area: the cleanup ordering deadlock

`scripts/cleanup-task.ps1` removes the worktree (line ~237) **before** it stops the session
(line ~283). But a session shown as `done` can still be a **live process whose cwd is that
worktree**, so the removal fails:

```text
error: failed to delete '...\worker-1216457377933945-a1': Permission denied
Remove-FactoryLongPathDirectory : ... because it is being used by another process
```

This happened three separate times today (tasks `1217297202745103`, `1217312332892449`,
`1216457377933945`). Each time the fix was to find the pid via `claude agents --json --all` and kill
it manually, then re-run — and on the third occasion cleanup had already unregistered the worktree,
so the re-run refused with "Residual worker directory is not a registered worktree" and the operator
had to finish by hand. `reject-task.ps1` has the same ordering (stop at :209, remove worktree at
:240) but happens to stop first, so it only hits this when the stopped process lingers.

## Required fix

### 1. One shared helper that removes every row of one task

Add to `scripts/factory-common.ps1` something like
`Remove-FactoryTaskAgentSessions -ClaudeCommand <cmd> -TaskId <id> -Worktree <path> [-KeepId <id>]`
returning the ids it removed and the ones it could not.

Enumeration must come from `claude agents --json --all`, which is the only source that lists
completed sessions. Match a row as belonging to the task when **both** hold:

- `kind -eq 'background'` — interactive rows are the operator's own sessions and must never be
  touched;
- the row is this task's: `cwd` equals the task worktree (compare with the existing
  `Test-FactorySamePath`), **or** `name` starts with the task's session-name prefix
  (`factory-<taskId>-`). The name fallback matters because by cleanup time the worktree may already
  be gone, which is exactly the state that stranded rows today.

Guard rails:

- Under `Set-StrictMode -Version 2.0` a row without `id` throws — use the guard already present at
  `scripts/orchestrator-session.ps1:48-52`. This is the same class of bug that broke the launcher on
  2026-08-08.
- Never remove a row whose name/cwd does not match the task. Never remove the orchestrator's own
  row (`scripts/orchestrator-session.ps1` owns it).
- `claude rm` on an already-gone id must not fail the caller: keep the best-effort contract that
  `cleanup-task.ps1:295` already has, and accumulate warnings instead of throwing.
- Stop before removing when the row is still live (`state` not in stopped/done/failed), reusing
  `Stop-FactoryClaudeSessionAndWait` so the process is verified gone rather than assumed.

### 2. Call it from every place that ends a session

- `worker-launch.ps1`: after each `Stop-FactoryClaudeSessionAndWait` on a stray, `rm` that stray.
  A stray is a session the plugin created and immediately abandoned; it has no value to the operator.
- `answer-task.ps1`: after stopping the previous attempt's row, remove it. The transcript survives on
  disk (`~/.claude/projects/...`), so nothing diagnostic is lost — state it in the docblock.
- `reject-task.ps1`: remove **all** of the task's rows, not just the stored one. Rejection is the
  "leave nothing behind" command, so this is squarely in its contract.
- `cleanup-task.ps1`: remove all of the task's rows; report `removedAgentSessions` as a list and keep
  `agentSessionWarning` for the best-effort failures. Preserve the existing rule that Agent View
  cleanup never turns a finalized task back into a failure.

### 3. Fix the ordering in `cleanup-task.ps1`

Stop and remove the task's sessions **before** touching the worktree, because a finished-but-alive
session holds the directory. Keep every existing safeguard (refuse active tasks, dirty worktrees,
unsafe paths, commits not reachable from both remotes) — this is a reordering, not a relaxation.

If a stop leaves a process alive past the timeout, say so and abort before removing anything, so the
operator gets a clear "session N still holds the worktree" instead of a half-finished cleanup.

### 4. Do not let `claude rm` become a data-loss path

`claude rm` removes the Agent View row. Confirm and document that it does **not** delete the
transcript under `~/.claude/projects/...`; the factory relies on `backgroundSession.transcriptPath`
for `/factory transcript` after a task is done. **(unverified: whether any Claude CLI version also
prunes transcript files on `rm` — check before shipping.)** If it does, keep the row and only prune
strays.

## Acceptance criteria

- A task taken through `answer` at least once and then `go` → integrate → `cleanup` leaves **zero**
  background rows in `claude agents --json --all`, and its transcript files still exist.
- `reject` leaves zero background rows for the rejected task.
- A launch that falls back through the `--agent` ladder leaves zero stray rows, whether the fallback
  succeeds or fails.
- Rows belonging to other tasks, and every `kind: interactive` row, are untouched — assert this with
  a fixture that contains rows for two tasks plus an interactive row with no `id` field.
- `cleanup` on a task whose finished session still holds the worktree now succeeds without manual
  intervention, and the ordering is covered by a test.
- `claude rm` failing for one id neither aborts cleanup nor hides the failure: the task still ends
  `done`, with the failure named in `agentSessionWarning`.
- `tests/run-tests.ps1` covers all of the above through `claude-fake.cmd`, including an agents
  listing that mixes background rows for two different tasks with an `id`-less interactive row.

## Live state you must not disturb

At the time of writing the queue holds seven open tasks: five `awaiting-review` with validated
commits (`1216457074192302`, `1217117072190144`, `1217339586686611`, `1216804185024501`,
`1217083054436552`) and two `awaiting-input` (`1216471604508800`, `1217362698939962`). Their Agent
View rows are legitimate and must survive — this task is about rows whose task is finished or
discarded, not about tidying live ones. `1216457377933945` is already fully closed and its four rows
were removed by hand today, so it is no longer a reproduction case; build the fixtures instead.

## Implementation outcome (2026-08-12)

The session lifecycle is now centralized in `scripts/factory-common.ps1`.
`Remove-FactoryTaskAgentSessions` enumerates `claude agents --json --all`, ignores
all non-background rows (including an interactive row without `id`), protects
the orchestrator row, and matches a task only by normalized worktree path or its
`factory-<task-id>-` name prefix. It uses a two-phase operation: first stop and
verify every live process, then remove Agent View rows. If any process remains
live, no row is removed and cleanup/reject abort before touching task artifacts.
Rows that report a terminal state but still expose a PID are treated as live.

`answer-task.ps1` removes superseded attempt rows before queuing the next
attempt. `reject-task.ps1` removes all matching rows before discarding the
worktree and task state. `cleanup-task.ps1` performs every existing Git safety
check first, then removes task sessions before worktree deletion; individual
`claude rm` failures are accumulated in `agentSessionWarning` and cannot roll a
finalized task back from `done`. Every abandoned session created by the worker
resolution ladder is removed immediately after its verified stop.

The transcript safety probe was run in `C:\tmp` with Claude Code 2.1.228. Probe
session `f3a1b0e9` wrote
`C:\Users\igerg\.claude\projects\C--tmp\f3a1b0e9-4f17-4fc1-b2b8-84c9a70c7628.jsonl`.
After `claude stop f3a1b0e9` and `claude rm f3a1b0e9`, the Agent View row was
gone while the transcript file still existed at 28,024 bytes. The probe was the
only real session changed during implementation; no MotiveHR task, worktree, or
factory runtime state was modified.

The fake CLI now keeps a session event registry and supplies mixed rows for two
tasks, an orchestrator, and an id-less interactive session. Regression coverage
includes answer/relaunch history, successful and failed fallback ladders,
multi-row rejection, a terminal-looking process holding a cleanup worktree,
stop failure before artifact mutation, transcript retention, and one-ID rm
failure with continued `done` finalization. The complete runtime suite passes.

## Out of scope

- The `--agent` bg-spawn regression itself (see `TASK-bg-agent-inline-fallback-also-dead.md`); this
  task only stops its debris from accumulating.
- Any change to review/approval/integration gates or Git policy.
- Removing interactive sessions, or anything in Agent View the plugin did not create.
- Committing or pushing anything, in this repo or in `motivehr`.
