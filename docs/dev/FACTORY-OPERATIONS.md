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

Start the factory without `-Continue` for normal use. If the old orchestrator
conversation history is specifically required, use:

```powershell
start-factory.ps1 -Resume
```

In the resume picker, inspect the conversation preview instead of relying only
on its name. An unrelated resumed session may previously have been renamed
`Claude Factory Orchestrator`.

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

Example:

```text
awaiting-review 3 · awaiting-input 1 · held 5
concurrency 3, active workers 0
scheduler absent
active=true, paused=false
```

This means:

- three workers produced commits that require human review;
- one worker is waiting for a reply in its conversation;
- five tasks are intentionally held;
- no task currently requires automatic orchestration;
- the factory is enabled and is not paused.

An absent scheduler is expected in this state. The recurring job removes
itself when only human decisions remain, avoiding pointless polling.

The scheduler is recreated when:

- a new task is added;
- `/factory go <task-id>` approves a task;
- `/factory resume` is run;
- concurrency is increased while queued work exists.

If `/factory resume` finds no actionable work, its tick will run once and the
scheduler will remove itself again.

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
| `rejected`        | result was rejected                           | retain or clean up separately       |
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
/factory reject 1216632072822682
/factory rework 1216632072822682 "Keep the old endpoint compatible"
```

`rework` retains the conversation and worktree. The orchestrator prints the
instructions to paste into the worker conversation.

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
worker branch, preserves the transcript and result, and marks the task `done`.

The command enables Git long-path handling and removes verified clean residue
that Windows may leave behind. It never removes an unpublished recorded
commit. `reject` only changes task state and deliberately retains artifacts;
it does not replace `cleanup`.

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
- `doctor` checks the CLI, runtime files, locks, worktrees, and scheduler.

If the launcher reports that a factory is already running, inspect Agent View
and other terminals first. Only one lead factory process may run for a
repository.

## 13. Concurrency

Show or change the current worker limit:

```text
/factory concurrency
/factory concurrency 5
```

Increasing the limit starts additional queued tasks. Decreasing it never kills
workers that are already running.

`planning`, `starting`, and `running` consume capacity. `awaiting-input` and
`awaiting-review` do not.

## 14. Operations to avoid

- Do not enter `/factory ...` commands directly in Agent View.
- Do not use `-Continue` for normal factory startup.
- Do not manually delete worker worktrees or branches before review completes.
- Do not push or merge from a worker branch.
- Do not run `cleanup-project.ps1 -Force` without manual inspection; it can
  remove uncommitted work.
- Do not run `go` before reading `/factory review`.

## 15. Daily checklist

```text
1. Start start-factory.ps1 without -Continue.
2. Run /factory status.
3. For awaiting-input: run /factory chat <id>, open the worker, and reply.
4. For awaiting-review: run /factory review <id>.
5. If acceptable: run /factory go <id>.
6. Run /factory status again later.
```
