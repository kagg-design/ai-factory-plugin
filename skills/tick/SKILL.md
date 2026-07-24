---
name: tick
description: Reconcile conversational background worker sessions, integrate one explicitly approved commit, and refill the Claude Factory queue.
argument-hint: ""
user-invocable: true
allowed-tools:
  - Read
  - Write
  - Edit
  - Glob
  - Grep
  - Bash
  - PowerShell
  - CronCreate
  - CronList
  - CronDelete
---

Advance Claude Factory by one safe orchestration cycle. Speak in Russian.
Do not emit repetitive no-op commentary when nothing changed.

## Load and reconcile

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/project-context.ps1" -Repository "${CLAUDE_PROJECT_DIR}" -Initialize
```

Read `configPath` and `statePath`, then run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/reconcile-worker-sessions.ps1" -Repository "${CLAUDE_PROJECT_DIR}"
```

Re-read state. Use these v3 states:

```text
queued starting planning awaiting-input running awaiting-review approved
integrating production done held rejected blocked failed review
```

Never relaunch a task that retains a background session ID, usable worktree, or
validated commit.

If state is inactive, delete a stale matching cron job and stop. If paused,
launch and integrate nothing.

## 1. Integrate at most one explicitly approved task

Never integrate `awaiting-review`, `held`, or legacy `ready`. Select only the
oldest `approved` task.

Before changing status, require all of:

- `approval.commit` exactly equals `task.commit`;
- worker worktree exists and is clean;
- worker worktree `HEAD` exactly equals `approval.commit`;
- the approved commit is valid and reachable from the worker branch.

If any check fails, clear approval, return the task to `awaiting-review`, and
explain the exact mismatch. Merge the approved SHA, not a moving branch name.

Set a valid task to `integrating`. Use:

```text
<worktreeRoot>/factory-integrator
```

with local branch `factory/integrator`, based on a freshly fetched configured
remote development branch. Never use or reset the user's main checkout.
Record the exact remote development SHA used as base and merge the immutable
approved commit with `--no-ff`.

Resolve only obvious mechanical conflicts. Otherwise abort the merge, restore
the integrator base, and mark `review`.

### Integration tests and development push

Run `integrationTestCommands`. If empty, infer canonical full checks once from
repository docs and CI files and store them in private state. Every required
command must exit 0.

Immediately before push, fetch development again. If its remote SHA moved,
rebuild the integration on the new tip and rerun all tests. Push only:

```text
HEAD:<developmentBranch>
```

Never force-push. Verify the approved task commit is reachable from the remote
development branch. If automatic development push is disabled, set `review`
and preserve all work.

## 2. Production promotion

After development succeeds, set `production` and use:

```text
<worktreeRoot>/factory-release
```

with branch `factory/release`, reset only inside that reusable external
worktree to the fresh remote production branch.

For `merge-develop`, merge remote development with `--no-ff`. Honor
`allowUnrelatedDevelopCommitsToProduction`. For `task-only`, promote only this
task's tested integration and exclude unrelated development commits.

Run all `releaseTestCommands`, inferring and saving canonical commands once
when empty. Before push, fetch development and production again. If tested
inputs moved, rebuild and retest. Push only `HEAD:<productionBranch>`, never
force. Verify the task commit is reachable from all required remote branches.
If automatic promotion is disabled, set `review`.

## 3. Asana writes and cleanup

Perform only Asana writes explicitly enabled in config. Never mark the task
complete before production verification.

After remote verification:

1. Preserve the transcript path, last assistant message, session UUID, and
   result in state.
2. Stop the background row if still live.
3. Verify the worker worktree is clean and its commit reachable from all
   required remotes.
4. Remove the worker worktree, delete its local `factory-worker/*` branch, and
   prune worktree metadata.
5. Set the task to `done`.

Never delete uncommitted work or an unreachable commit.

## 4. Fill dynamic capacity

Active capacity is the number of tasks in:

```text
starting planning running
```

`awaiting-input` and `awaiting-review` sessions are idle and do not consume a
launch slot. While active capacity is below `config.concurrency`, select the
oldest `queued` task and run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/start-worker-session.ps1" -Repository "${CLAUDE_PROJECT_DIR}" -TaskId "TASK_ID" -Mode "TASK_START_MODE"
```

Launch one session per task. Each call creates or safely reuses the external
worktree, starts `claude --bg --agent factory:worker`, saves both the
short background ID and full session UUID, and returns immediately. Stop
filling capacity on the first launch failure so repeated errors do not fan out.

A lower concurrency never kills existing workers. An increase takes effect in
this loop immediately.

## 5. Quiet idle behavior

Keep the scheduler only while at least one task is:

```text
queued starting planning running approved integrating production
```

If only `awaiting-input`, `awaiting-review`, `held`, `rejected`, `blocked`,
`failed`, `review`, or `done` remain:

- set `active: false`;
- delete the matching `/factory:tick` cron job;
- clear `cronJobId`;
- preserve every session, commit, branch, worktree, and transcript.

New tasks, `go`, `resume`, or a concurrency increase restart it. When nothing
changed, finish silently; otherwise report one compact queue summary.
