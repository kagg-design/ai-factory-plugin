---
name: factory-tick
description: Reconcile workers, integrate one completed task, promote it, clean it up, and refill the asynchronous Asana Factory queue.
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
  - Agent(asana:asana-fix-worker)
  - CronCreate
  - CronList
  - CronDelete
---

Advance the Asana Factory by one safe orchestration cycle. Speak in Russian and finish with one compact queue summary.

## Load private context

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/project-context.ps1" -Repository "${CLAUDE_PROJECT_DIR}" -Initialize
```

Read the returned `configPath`, `statePath`, `worktreeRoot`, and `resultSchemaPath`. These are outside the repository. Write state atomically and use UTC ISO-8601 timestamps.

If state is inactive, delete a stale matching cron job and stop. If paused, launch and integrate nothing.

Use only these task states:

```text
queued
running
ready
integrating
production
done
blocked
failed
review
```

Never launch a second worker for a task with a live agent ID, retained worktree, or usable commit.

## 1. Reconcile workers

For every `running` task:

- inspect the stored background agent/task ID;
- retrieve completion output when available;
- parse JSON after `FACTORY_RESULT`;
- validate against `resultSchemaPath`;
- independently verify branch, commit, reachability, worktree mapping, clean worktree, changed files, and reported tests.

Transitions:

- valid `completed` result â†’ `ready`;
- worker `blocked` â†’ `blocked`;
- worker `failed` or invalid result â†’ `failed`;
- still working â†’ remain `running`.

After a restart, reconstruct cautiously from Git if task UI state is missing. Never relaunch solely because `/tasks` no longer shows an old agent.

## 2. Integrate at most one ready task

Integration is strictly serialized. Select the oldest `ready` task and set it to `integrating`.

Use a reusable worktree under the returned external `worktreeRoot`:

```text
<worktreeRoot>/factory-integrator
```

with local branch `factory/integrator`. Create it from the fresh configured remote development branch when absent. If present, require a clean tree, fetch, and reset it to the current remote development branch. Never operate on the user's main checkout.

Record the exact remote development SHA used as the base. Merge the worker branch with `--no-ff`; use its commit only if the branch is unavailable.

Resolve only obvious mechanical conflicts. Otherwise abort and mark `review`.

### Integration tests

Use `integrationTestCommands`. If empty, infer canonical full checks once from `CLAUDE.md`, README, CI workflows, `composer.json`, `package.json`, Makefile, or task-runner files and save them in state.

All required commands must exit 0. On failure, preserve useful logs and the worker worktree, reset the integrator to its base, mark `failed`, and do not push.

### Development push

Immediately before push:

1. fetch the development branch again;
2. compare its SHA with the recorded base;
3. if it moved, rebuild on the new tip and rerun all integration tests;
4. push only `HEAD:<developmentBranch>`;
5. never force-push.

Fetch and verify the task change is reachable from the remote development branch. If automatic development push is disabled, mark `review`.

## 3. Production promotion

After development succeeds, set the task to `production`.

Use a separate reusable external worktree:

```text
<worktreeRoot>/factory-release
```

with branch `factory/release`, reset to the current remote production branch.

### merge-develop mode

Fetch both branches and merge remote development into release with `--no-ff`. When `allowUnrelatedDevelopCommitsToProduction` is false, block if production..development contains unrelated non-factory commits.

### task-only mode

Promote only this task's integrated merge or commit and exclude unrelated development work. Record exact promoted SHAs.

### Release tests and push

Use `releaseTestCommands`; if empty, infer and save canonical commands as above. All commands must exit 0.

Before push, fetch production and development again and verify the tested inputs did not move. If they moved, rebuild and retest. Push only `HEAD:<productionBranch>`, never force.

Verify the task change is reachable from both configured remote branches. If automatic production promotion is disabled, set `review` after development.

## 4. Asana writes

Only perform Asana writes explicitly enabled in configuration. Never complete a task before production verification. Report factual commit and test information only.

## 5. Cleanup

Only after remote verification:

1. verify the worker worktree is clean;
2. verify its commit is reachable from all required remote branches;
3. remove the worker worktree with `git worktree remove`;
4. delete its local `factory-worker/*` branch;
5. run `git worktree prune`;
6. set the task to `done`.

Never delete uncommitted work or an unreachable commit. Keep integrator and release worktrees while work remains. Remove them when fully idle only if clean.

## 6. Fill capacity

If not paused, count `running` tasks. While below `concurrency`, launch the oldest `queued` tasks as separate background `asana:asana-fix-worker` subagents.

Pass one complete normalized JSON payload per worker containing task ID, URL, title, brief, acceptance criteria, source notes, Git branch configuration, and required checks. Require `FACTORY_RESULT`.

Persist the returned agent/task ID immediately and set the task to `running`. Launch independent workers in one parallel Agent batch when possible. Never pass multiple Asana tasks to one worker.

The plugin's WorktreeCreate hook places each worker in an external sibling worktree and creates a `factory-worker/*` branch from the configured remote development branch.

## 7. Idle

The factory is idle only when no task is `queued`, `running`, `ready`, `integrating`, or `production`.

When idle, set `active: false`, delete the matching recurring `/asana:factory-tick` job, clear `cronJobId`, preserve blocked/failed/review tasks, and report final counts. When only workers are running, save state, report one line, and end the tick without spinning.
