# Claude Factory Operator Guide

This guide covers day-to-day factory operation: starting the orchestrator,
reading `/factory status`, opening a task conversation, reviewing a result,
and authorizing integration.

## 1. Factory components

The factory has four distinct layers:

1. **Orchestrator** — the main `Claude Factory Orchestrator` conversation.
   Run all `/factory ...` commands there.
2. **Factory task** — a persistent queue entry imported from Asana. Its primary
   ID looks like `1216632072822682`.
3. **Worker** — a separate Claude Code background session for one task. It has
   a short session ID such as `1a20569f` and a name such as
   `factory-1216632072822682-surface-pending-pto-requests`.
4. **Scheduler** — a recurring `/factory:tick` job that launches queued work,
   reconciles worker results, and serially integrates approved commits.

Queue state, session metadata, and worker results are stored independently of
the orchestrator conversation:

```text
<plugin>\runtime\projects\<project-key>\state.json
```

Closing the orchestrator or starting a fresh orchestrator conversation does
not remove tasks, worker sessions, branches, commits, or worktrees.

The launcher also stores the orchestrator's exact conversation UUID in the
private project runtime. Normal startup attaches to that conversation when it
is in Agent View, or resumes it after an ordinary `Ctrl+C` exit. This prevents
accidental duplicate orchestrators from normal repeated startup.

## 2. Safe startup

Start the factory from the target Git repository:

```powershell
cd C:\laragon\www\motivehr
C:\laragon\www\Projects\claude-factory-plugin\start-factory.ps1
```

Then check its state:

```text
/factory status
```

If orchestration was stopped or paused:

```text
/factory resume
```

### Why normal startup should not use `-Continue`

Claude Code interprets `--continue` as "continue the newest conversation in
the current directory." That conversation may belong to a scheduled task,
ordinary development work, or another session rather than the factory.

Start the factory without flags for normal use; it resumes the stored
orchestrator exactly. For manual recovery of a legacy conversation that predates
the stored identity, use:

```powershell
start-factory.ps1 -Resume
```

In the resume picker, inspect the conversation preview instead of relying only
on its name. An unrelated resumed session may previously have been renamed
`Claude Factory Orchestrator`.

Use `start-factory.ps1 -New` only to deliberately replace the stored
conversation. The launcher still refuses to create a new one while a matching
interactive or background orchestrator is live.

## 3. Where commands belong

Run `/factory ...` commands inside the `Claude Factory Orchestrator`
conversation.

Pressing `←` opens **Agent View**. Agent View is a background-session
dispatcher, not the orchestrator prompt.

- `←` moves from the current conversation to Agent View.
- `Enter` on a selected row opens that session.
- `Esc` returns to the original conversation.
- Typing a new prompt directly in Agent View creates a new background agent.

If `/factory status` is entered directly in Agent View, Claude may dispatch a
new agent for it. Return to the orchestrator and run the command there.

### Command help

The slash-command hint is deliberately short so it fits in the terminal:

```text
/factory help
```

This prints a one-screen overview grouped into adding work, opening tasks,
review decisions, and orchestration controls. For details about one command:

```text
/factory help sync
/factory help cleanup
```

Help is read-only and never executes the command it describes.

## 4. Reading `/factory status`

The default report is organized around operator actions, not internal state
counts. Every unfinished task is shown as a narrow card:

```text
╭─ Factory · MotiveHR
│  ○ idle · workers 0/3 · scheduler sleeping
├─ ◆ NEEDS YOUR ACTION · 2
│  ├─ REVIEW · 1216643944203164 — Team PTO: taken-YTD + overlaps
│  │  ├─ State: ready for review
│  │  ├─ Commit: 1079d949
│  │  ├─ Session: 51962867 · done
│  │  ├─ Notice: branch is behind the current development branch
│  │  ├─ → Next: /factory sync 1216643944203164
│  │  └─ Open: /factory chat 1216643944203164
│  └─ HELD · 1216606487211903 — Taken-YTD duplicate
│     ├─ State: held by operator
│     ├─ Reason: held by operator
│     ├─ Session: 3abc1234 · stopped
│     ├─ → Next: /factory inspect 1216606487211903
│     ├─ Open: /factory chat 1216606487211903
│     └─ Resume: /factory answer 1216606487211903 --text "Continue"
├─ ✓ COMPLETED · 3
│  └─ History: /factory status done
╰─ Factory enabled · no runnable tasks · scheduler sleeping
```

Use filters when the default view is too broad:

```text
/factory status held
/factory status awaiting-review
/factory status done
/factory status all
```

`status done` is history: it shows task ID, full title, canonical task URL,
completion summary, and the corresponding `inspect` command. It does not
present an old attach command as the main action. The default view omits
completed task rows.

An absent scheduler is expected when every unfinished task requires an operator
decision. It is recreated when work is queued, a task is approved, the factory
is resumed, or concurrency is increased while queued work exists.

## 5. IDs shown in status output

One status row can contain three different identifiers:

```text
task 1216632072822682
commit 57bf282
claude attach 1a20569f
```

| Value              | Meaning                                           |
|--------------------|---------------------------------------------------|
| `1216632072822682` | Asana and factory task ID                         |
| `57bf282`          | abbreviated Git commit SHA produced by the worker |
| `1a20569f`         | short Claude background-session ID                |

In Agent View, find the session name containing the full task ID:

```text
factory-1216632072822682-surface-pending-pto-requests
```

Agent View can also contain old and completed sessions that are no longer
active factory tasks.

## 6. Task statuses

| Status            | Meaning                                       | Operator action                     |
|-------------------|-----------------------------------------------|-------------------------------------|
| `queued`          | waiting for capacity                          | usually none                        |
| `starting`        | worktree and session are being created        | wait                                |
| `planning`        | worker is inspecting the task                 | wait for its plan                   |
| `awaiting-input`  | worker needs a reply                          | open its conversation               |
| `running`         | implementation or tests are in progress       | monitor or steer                    |
| `syncing`         | task was rebased and checks must be recorded  | rerun `/factory sync <id>`          |
| `awaiting-review` | a validated commit is ready                   | `/factory review <id>`              |
| `approved`        | the exact SHA was approved                    | scheduler begins integration        |
| `integrating`     | development merge and checks are running      | do not interfere                    |
| `production`      | production promotion is running               | wait for the result                 |
| `held`            | task and artifacts are retained but held      | decide later                        |
| `rejected`        | rejected with `--keep`; artifacts retained    | inspect or discard with `reject`    |
| `blocked`         | an external or technical blocker exists       | `/factory inspect <id>`             |
| `failed`          | the attempt failed                            | inspect, then `/factory retry <id>` |
| `done`            | integration, push, and verification completed | none                                |

A Claude session state shown in parentheses is a separate concept:

- `(blocked)` usually means the session is idle and waiting for input;
- `(done)` means the background session finished its turn.

A session may be `(done)` while its factory task remains `awaiting-review`
until a human reviews and approves its commit.

## 7. Opening a specific task

Ask the orchestrator for connection details:

```text
/factory chat 1216632072822682
```

Then:

1. press `←`;
2. find `factory-1216632072822682-...`;
3. select the row;
4. press `Enter`.

Alternatively, attach from a separate terminal:

```powershell
claude attach 1a20569f
```

If the session has stopped, `/factory chat` also prints the appropriate
`claude respawn <session-id>` command.

Do not start a nested interactive `claude attach` TUI from inside the
orchestrator. Use Agent View or a second terminal.

## 8. Interactive task flow

Add a task that requires plan review:

```text
/factory start <Asana URL>
```

`add` is an explicit alias with the same behavior:

```text
/factory add <Asana URL>
/factory add --auto <Asana URL>
```

The worker reads the task and relevant code without editing, emits a
`FACTORY_PLAN`, moves to `awaiting-input`, and waits in its own conversation.

Open the worker conversation and approve or revise its plan. For example:

```text
The plan is approved. Begin implementation.
```

After the worker finishes, return to the orchestrator and reconcile:

```text
/factory status
```

## 9. Automatic task flow

For a small, unambiguous task that should not wait for plan approval:

```text
/factory start --auto <Asana URL>
```

The worker begins implementation immediately. Human review and explicit
approval are still required before integration.

## 10. Review and approval

Run a read-only review first:

```text
/factory review 1216632072822682
```

The orchestrator checks the requirements, plan, transcript, exact diff,
reported tests, and current commit SHA.

If the result is acceptable:

```text
/factory go 1216632072822682
```

`go` approves only the exact clean worker SHA. If the worker HEAD changes
after approval, integration stops and requires a new review.

Other decisions:

```text
/factory hold 1216632072822682
/factory reject 1216632072822682 "Duplicate; already implemented"
/factory reject 1216632072822682 --yes
/factory reject 1216632072822682 --keep
/factory rework 1216632072822682 "Keep the old endpoint compatible"
```

`rework` retains the conversation and worktree. The orchestrator prints the
instructions to paste into the worker conversation.

`reject` is a final discard by default. Before changing anything, the
orchestrator lists the background session, worktree, local worker branch,
commit, and private prompt/event/session metadata that will be removed. Confirm
the preview to stop the task's live processes, remove every Agent View row from
current and previous attempts, remove all other artifacts (including dirty or
unpublished work), delete the task from private state, and make it disappear
from `/factory status`.

Use `--yes` when the preview is unnecessary and the loss is already understood.
Use `--keep` only when the rejected task must remain inspectable: it marks the
task `rejected` and records the reason without deleting anything. The factory
uses `--yes`, not an ambiguous `--force`, for confirmation bypass.

### Synchronizing before review

Refresh the same worker worktree against the latest configured development
branch:

```text
/factory sync 1216632072822682
```

The command fetches `remote/developmentBranch`, rebases the single task commit
onto it, reruns appropriate focused tests and lint/static-analysis checks, and
records the new commit SHA before returning the task to `awaiting-review`.
There is no separate preview worktree: inspect and run the application from the
existing worker path returned by `/factory inspect <task-id>`.

Synchronization requires a clean, idle task in `awaiting-review` or `held`.
The task SHA changes, so prior review and approval are cleared. Rebase conflicts
are aborted and reported without modifying the original branch. If validation
is interrupted after a successful rebase, the task remains `syncing`, cannot be
approved, and the same `/factory sync <task-id>` resumes its checks.

The source branch is configured per repository:

```json
{"remote": "origin", "developmentBranch": "develop"}
```

### Cleaning up one task

After a task commit is safely present in both configured remote branches,
remove its worker artifacts from the orchestrator:

```text
/factory cleanup 1216722772084729
```

Cleanup reconciles the task, refuses active sessions and dirty worktrees,
refreshes the remote development and production branches, verifies that the
recorded commit is reachable from both, removes the worker worktree and local
worker branch, preserves the factory result metadata, marks the task `done`,
and removes every background session for the task from Claude Agent View.

After all Git safety checks pass, cleanup stops and verifies every live task
process before touching the worktree. This includes a terminal-looking row that
still has a PID and can hold the directory on Windows. A stop failure aborts
before artifact removal. Agent View `rm` is best effort: if one row cannot be
removed, cleanup continues, remains `done`, and returns an
`agentSessionWarning` naming the ID; remove that row manually with
`claude rm <id>`.

`claude rm` removes the Agent View index row, not the JSONL transcript. This was
verified with Claude Code 2.1.228: the transcript under `~/.claude/projects`
remained byte-present after stop and rm, so `/factory transcript` history is
preserved.

The command enables Git long-path handling and removes verified clean residue
that Windows may leave behind. It never removes an unpublished recorded
commit. This is deliberately different from `reject`: cleanup is for published
work, preserves a `done` history record, and will not discard unique changes.
Reject is for abandoned work, removes the task record, and requires an explicit
preview confirmation unless `--yes` is supplied.

## 11. Pause, stop, and recovery

Prevent new launches and integration while retaining all artifacts:

```text
/factory pause
```

Resume orchestration:

```text
/factory resume
```

Deactivate the queue and remove its scheduler while retaining sessions,
branches, commits, and worktrees:

```text
/factory stop
```

After restarting the computer or Claude Code, start the factory without
`-Continue`, then run:

```text
/factory status
/factory resume
```

If a background session stops without a valid `FACTORY_RESULT`, reconciliation
sets `held` with a machine `holdReason`. Continue the retained worktree with:

```text
/factory retry <task-id>
```

A manual hold has a different reason and is not accepted by `retry`. Retry also
refuses a missing worktree or a task that already has a validated commit/result.

To make decisions durable before relaunching a worker:

```text
/factory answer <task-id> --text "decision text"
/factory answer <task-id> --file D:\path\decisions.md
```

This writes the ignored `FACTORY-DECISIONS.md` inside the retained worktree,
stops and removes superseded task rows from Agent View, and queues one new
attempt. Their JSONL transcripts remain on disk. Repeating the same answer
refreshes the file without duplicating the pointer or attempt.
## 12. Diagnostics

```text
/factory status
/factory inspect <task-id>
/factory transcript <task-id>
/factory doctor
```

- `status` reconciles sessions and summarizes the queue.
- `inspect` shows all normalized data for one task.
- `transcript` summarizes the worker conversation.
- `doctor` checks the CLI, PowerShell runtime and required cmdlets, parsed worker
  definition, agent-resolution cache, runtime files, locks, worktrees, and
  scheduler.

A worker session reports `agentResolution: plugin` when Claude resolved the
session-only plugin agent directly. `inline-fallback` means the launcher safely
stopped a default-template session and supplied the same `agents/worker.md`
prompt inline. `system-prompt` means both agent-resolution forms were rejected,
their stray sessions were stopped, and the launcher appended a private,
byte-identical copy of the stripped worker body to Claude's default system
prompt without `--agent`. That last path keeps model and effort CLI flags but
does not apply the agent frontmatter name, description, `maxTurns`, or tools
restriction. The active path, per-path outcomes, prompt hash, and accepted
deviations are audited. The choice is cached only for the current Claude Code
version; an older `inline-fallback` cache migrates to `system-prompt`, while a
new CLI version probes the plugin path again.

`/factory doctor` treats the resolution check as required. A cache proving that
plugin, inline, and system-prompt paths all failed makes the factory unhealthy.

If the launcher reports that a factory is already running, inspect Agent View
and other terminals first. Only one lead factory process may run for a
repository.

## 13. Test database isolation

Separate worktrees still share any database named by their copied `.env` or
test-runner configuration. For a PostgreSQL project, enable isolation in the
private runtime config:

```json
{
  "testDatabaseIsolation": {
    "enabled": true,
    "provider": "postgresql",
    "databasePrefix": "project_test"
  }
}
```

The connection defaults to the ignored `.env` and its standard `DB_HOST`,
`DB_PORT`, `DB_USERNAME`, and `DB_PASSWORD` keys. The role must have `CREATEDB`.
Do not put credentials in factory config.

Worker `TASK_ID` receives `<prefix>_worker_<task_id>` as `DB_DATABASE` in the
Claude process environment. A retry or answer reuses it; a hold preserves it.
`cleanup` and confirmed `reject` stop every matching task process and then drop
the exact derived database before touching the worktree. If the database cannot
be dropped, Git artifacts and task state remain available for a safe retry.

Integration and release checks must use the bundled wrapper exactly as required
by the internal tick skill. Their databases are `<prefix>_integrator` and
`<prefix>_release`, so they cannot collide with running workers. PostgreSQL 13+
is required for `DROP DATABASE ... WITH (FORCE)`.

If isolation is disabled, the wrapper runs commands normally. Until isolation
is enabled, concurrent database-backed test runs are unsafe; lower factory
concurrency or serialize those checks externally.

## 14. Concurrency

Show or change the current worker limit:

```text
/factory concurrency
/factory concurrency 5
```

Increasing the limit starts additional queued tasks. Decreasing it never kills
workers that are already running.

`planning`, `starting`, and `running` consume capacity. `awaiting-input` and
`awaiting-review` do not.

## 15. Operations to avoid

- Do not enter `/factory ...` commands directly in Agent View.
- Do not use `-Continue` for normal factory startup.
- Do not manually delete worker worktrees or branches before review completes.
- Do not push or merge from a worker branch.
- Do not run `cleanup-project.ps1 -Force` without manual inspection; it can
  remove uncommitted work.
- Do not run `go` before reading `/factory review`.

## 16. Daily checklist

```text
1. Start start-factory.ps1 without -Continue.
2. Run /factory status.
3. For awaiting-input: run /factory chat <id>, open the worker, and reply.
4. For awaiting-review: run /factory review <id>.
5. If acceptable: run /factory go <id>.
6. Run /factory status again later.
```
