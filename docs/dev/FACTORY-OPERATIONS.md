# Claude Factory Operator Guide

This guide covers day-to-day factory operation: starting the orchestrator,
reading `/factory status`, opening a task conversation, reviewing a result,
and authorizing integration.

## 1. Factory components

The factory has four distinct layers:

1. **Orchestrator** — the main Claude or Codex Factory conversation. Start it
   with `factory start` or `factory start -Agent codex`.
2. **Factory task** — a persistent queue entry created by native code. An
   Asana ID looks like `1216632072822682`, another adapter ID looks like
   `linear:ENG-123`, and an operator-created task uses `local:...`.
3. **Worker** — a separate Claude Code or Codex session for one task. Claude
   workers appear in Agent View; Codex workers have a resumable thread UUID.
4. **Native scheduler** — one hidden PowerShell process that reconciles workers,
   fills capacity, executes formally approved publication plans, publishes a
   heartbeat, and sleeps without consuming AI turns.

Queue state, session metadata, and worker results are stored independently of
the orchestrator conversation:

```text
<plugin>\runtime\projects\<project-key>\state.json
```

Closing the orchestrator or starting a fresh orchestrator conversation does
not remove tasks, worker sessions, branches, commits, or worktrees.

The launcher stores separate exact conversation UUIDs for the Claude and Codex
orchestrators in private project runtime. Normal startup resumes the selected
conversation. A per-repository mutex prevents two live orchestrators.

## 2. Safe startup

Start the factory from the target Git repository:

```powershell
cd C:\laragon\www\motivehr
factory start
```

Claude is the default full runtime. Select Codex for both the orchestrator and
new workers when needed:

```powershell
factory start -Agent claude
factory start -Agent codex
```

Omitting `-Agent` always selects Claude. The selection is stored in private
project `config.json` and affects only new attempts. Existing Claude and Codex
workers keep their original runtime and can coexist while they finish.

Then check its state without waiting for AI interpretation:

```powershell
factory status
```

From inside the orchestrator conversation, direct shell mode runs the same
code:

```text
!factory status
```

In Claude, the AI-backed form is:

```text
/factory status
```

In Codex, use natural commands without `$factory`:

```text
factory status
factory new
factory review <task-id>
```

If orchestration was stopped or paused:

```powershell
factory resume
```

### Why normal startup should not use `-Continue`

Claude Code interprets `--continue` as "continue the newest conversation in
the current directory." That conversation may belong to a scheduled task,
ordinary development work, or another session rather than the factory.

Start the factory without flags for normal use; it resumes the stored
orchestrator exactly. For manual recovery of a legacy conversation that predates
the stored identity, use:

```powershell
factory start -Resume
```

In the resume picker, inspect the conversation preview instead of relying only
on its name. An unrelated resumed session may previously have been renamed
`Claude Factory Orchestrator`.

Use `factory start -New` only to deliberately replace the stored
conversation. The launcher still refuses to create a new one while a matching
interactive or background orchestrator is live.

## 3. Where commands belong

Run `/factory ...` commands inside Claude. Inside Codex, use `factory ...` or a
clear command such as `review <task-id>`. `$factory` is only an internal skill
identifier and is not part of the operator interface.

Deterministic operations also have a native fast path:

```text
!factory help
!factory status [state|all]
!factory inspect <task-id>
!factory chat <task-id>
!factory new [--auto] [text]
!factory add --file <task.json>
!factory go <task-id> [--direct]
!factory hold <task-id>
!factory reject <task-id> [-Yes|-Keep] [reason]
!factory cleanup <task-id>
!factory concurrency [number]
!factory doctor
!factory completion [status|enable]
```

Outside Claude, `factory start`, `factory paths`, `factory config`, and
`factory scheduler` replace the old root-script commands. The `.ps1` files
remain internal implementations and compatibility entry points.

The `!` is direct shell mode in both TUIs. The extensionless `factory` launcher in the
plugin root translates the Bash/WSL path when necessary and delegates to the
same `factory.ps1` implementation. The plugin root must be on `PATH`, as in the
installation instructions. In an ordinary PowerShell terminal, omit `!` and
run `factory status`, for example. PowerShell provides `Tab` completion for
command names, status filters, and saved task IDs. The script supplies
completion metadata without profile setup.

If `Tab` replaces one candidate at a time instead of opening a readable menu,
the current PSReadLine binding is `TabCompleteNext`. Run:

```powershell
factory completion status
factory completion enable
```

The second command selects `MenuComplete` for the current terminal only. To
make it persistent, add the line reported by the command to `$PROFILE`
yourself; Factory never edits a PowerShell profile automatically.

Local task creation, normalized file intake, `go`, `hold`, confirmed `reject`,
safe `cleanup`, and concurrency changes are native because their execution is
deterministic. Asana-backed `start` still uses `/factory ...`, but AI only reads
and normalizes the source task; native code validates its identity,
deduplicates, adds it to state, and wakes the scheduler. Commands that require
code judgment (`sync` and `review`) also use `/factory ...`. A plain native
`factory reject <id>` is a preview when artifacts
exist. Repeat with `-Yes` or `--yes` to remove the task and its artifacts, or
use `-Keep` or `--keep` to retain artifacts in rejected state.

`factory new` is fully local and requires no Asana connection. Asana is needed
only for importing an Asana URL; connect that adapter later if a project needs
it.

In Claude, pressing `←` opens **Agent View**. Agent View is a background-session
dispatcher, not the orchestrator prompt.

- `←` moves from the current conversation to Agent View.
- `Enter` on a selected row opens that session.
- `Esc` returns to the original conversation.
- Typing a new prompt directly in Agent View creates a new background agent.

If `/factory status` is entered directly in Agent View, Claude may dispatch a
new agent for it. Return to the orchestrator and run the command there.

Codex does not mirror Claude Agent View. `factory start -Agent codex` resumes
the exact stored orchestrator thread, and `factory chat <task-id>` prints the
exact command for a Codex worker thread.

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
│  ○ idle · workers 0/3 · native scheduler sleeping (PID 12345)
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
╰─ Factory enabled · no runnable tasks · native scheduler sleeping
```

Use filters when the default view is too broad:

```text
/factory status held
/factory status awaiting-review
/factory status done
/factory status all
```

`status done` is history: it shows task ID, full title, completion summary, the
corresponding `inspect` command, and either the canonical connector URL or the
local source identity. It does not present an old attach command as the main
action. The default view omits completed task rows.

The native scheduler normally remains alive and sleeps cheaply when every task
requires an operator decision. `factory scheduler status` shows its exact PID,
heartbeat, last tick, and last error. `factory start` and `factory resume`
restart it when needed; no Claude cron job is created.

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

A non-Asana normalized envelope uses a source-qualified factory ID such as
`linear:ENG-123`. The original adapter and source ID remain separately stored
on the task.

A task created with `factory new` uses a collision-safe ID such as
`local:20260816-142530-a1b2c3d4`. Status and inspect output identify it as a
local source without exposing the internal identity URI.

Its worker session uses the local task's random nonce as a stable short code.
It omits the timestamp and separate filesystem artifact hash, leaving more room
for the operator title. The nonce is not the Claude/Codex session ID:

```text
factory-local-a1b2c3d4-fix-profile-export
```

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
| `awaiting-review` | a validated commit is ready                   | review, or explicit direct approval |
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

For a Claude worker, then:

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

Codex workers do not appear in Claude Agent View. `/factory chat <id>` prints a
capture-aware PowerShell command. Run it in a second terminal: it opens the
exact Codex thread and, after the TUI exits, asks that same thread for its
current `FACTORY_PLAN` or `FACTORY_RESULT` and reconciles the JSONL output.
`codex resume --all --include-non-interactive` is useful for browsing, but raw
resume bypasses this post-chat Factory capture.

### Preview the worker application

For a UI change, launch the application from the saved worker worktree instead
of opening the normal development checkout:

```powershell
factory preview 1216632072822682
```

From the orchestrator, use the deterministic shell form:

```text
!factory preview 1216632072822682
```

Factory starts the configured Laravel and Vite commands on free loopback-only
ports, waits until both accept connections, opens the browser, and prints the
URL, worktree, PIDs, ports, and private log directory. `factory preview` shows
the current preview. `factory preview stop` stops both process trees and cleans
the matching `public/hot` file plus dependency junctions created for preview.

There is one active preview per project. Starting a different task stops the
previous preview automatically; repeating the current task reuses its live
processes. Use `factory preview <id> --no-open` to start it without opening a
browser. Closing the browser tab alone does not stop the servers.

The default preview uses the worktree's copied project environment and shared
development data. It is not connected to the isolated worker test database.
Factory stops the applicable preview before approval, confirmed rejection,
task cleanup, project purge, or `factory stop`. Tasks without an existing
worktree and tasks already approved, integrating, in production, or done are
not previewable through this command.

## 8. Interactive task flow

### Create a task from your own text

For work that does not come from Asana or another connector, create the task
directly:

```powershell
factory new "Fix the profile export"
```

This path is entirely native: it does not call AI for intake, require a JSON
file, or ask Asana for anything. Native code assigns a `local:...` ID, writes
the complete queue entry, and wakes the scheduler. The default mode is
interactive, so the worker first proposes a plan and waits for approval.

To open a blank worker and explain the task in its conversation, run:

```powershell
factory new
```

Factory prints the exact `factory chat <local-task-id>` command. The worker is
explicitly instructed to ask what should be implemented and to wait before
editing files.

For a clear task that should begin immediately:

```powershell
factory new --auto "Remove the obsolete navigation item"
```

`--auto` requires non-empty text. It skips plan approval for implementation,
but it does not bypass the normal review and integration controls. The `local`
source adapter is reserved for this command and cannot be impersonated through
`factory add --file`.

From the orchestrator, prepend `!` to use the same native paths without an AI
command turn:

```text
!factory new "Fix the profile export"
!factory new
```

### Create a task from Asana

Add a task that requires plan review:

```text
/factory start <Asana URL>
```

`add` is an explicit alias with the same behavior:

```text
/factory add <Asana URL>
/factory add --auto <Asana URL>
```

The orchestrator does not write queue state. Native preparation validates the
Asana URL and checks duplicates before the connector is called. AI reads Asana
and fills only semantic fields in a private versioned envelope. Native enqueue
then validates `resources/intake.schema.json`, repeats deduplication while
holding the state lock, atomically creates the task, and wakes the scheduler.

To import a normalized envelope without AI or Asana:

```powershell
factory add --file C:\path\task.json
```

The source file is retained. A connector failure can be represented by
`sourceError`; that task is saved as `blocked` and is not launched.

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

Run a code review first:

```text
/factory review 1216632072822682
```

The orchestrator checks the requirements, plan, transcript, exact diff,
reported tests, and current commit SHA. It then records a formal private review
containing the verdict, residual risks, trusted integration/release checks,
current development and production tips, and a hash of that immutable plan.

If the result is acceptable:

```text
/factory go 1216632072822682
```

`go` approves only the exact clean worker SHA and matching formal plan hash. It
is also available directly as `factory go <id>` or `!factory go <id>`; those
forms do not invoke AI. The native scheduler prepares development and production
candidates in its existing isolated integrator/release worktrees and runs both
recorded check sets concurrently in separate processes and isolated test
databases. Only after both pass does it re-fetch the reviewed bases and push the
exact tested development and production candidates sequentially, without force.
It then verifies both remotes and performs guarded cleanup. If either remote
moved since review, the worker HEAD changed, a check failed, or a conflict
occurred, publication stops with an exact saved reason instead of asking AI to
repair it implicitly.

The scheduler invokes the publication pipeline as a fresh child process for
each approved task. Plugin updates to that pipeline are therefore hot-loaded by
an already-running factory; the scheduler and its active task queue do not need
to be restarted.

For a small change whose worker output is sufficient for the operator to make
the decision, skip the separate AI review explicitly:

```powershell
factory go 1216632072822682 --direct
```

Inside the orchestrator, run the native form:

```text
!factory go 1216632072822682 --direct
```

`--direct` skips only independent AI code judgment. Native validation still
requires the exact validated worker SHA, an idle clean worktree, at least one
passed worker check and no failed worker checks, a single task commit based on
the current configured development tip, and non-empty trusted integration and
release commands from private config or previously resolved review state. It
records `operator-direct` in the review and approval audit, hashes the same
immutable publication plan, and runs the unchanged isolated integration and
release checks before pushing.

Direct approval cannot override a `changes-required` or `blocked` review for
the same commit. It also never copies a shell command from task text or a
worker-reported test merely to make approval succeed. Configure trusted checks
or use the normal review path instead.

The status tree shows `go --direct` only when a read-only preflight finds the
task result, automatic development push, automatic production promotion, and
trusted commands ready. Invoking the command repeats that preflight before it
writes review state and reports concise blockers plus `factory config edit`.
The deeper review and integration checks still run afterward; the preflight
does not replace or weaken them.

Publication is asynchronous. Native `go` prints `factory inspect <task-id>` so
the operator has an explicit monitoring command. If a publication stage fails,
the task retains the failed stage, checks, and error for diagnosis, but the
associated immutable plan is stale. Status requires a fresh review, and
ordinary `go`, `go --direct`, and the integrator all refuse to reuse that plan.
A successfully recorded replacement review clears the active stage markers and
permits a new approval.

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
There is no separate preview worktree: `factory preview <task-id>` runs the
application directly from the existing worker path returned by
`/factory inspect <task-id>`.

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

```powershell
factory pause
```

Resume orchestration:

```powershell
factory resume
```

Deactivate the queue and stop its scheduler while retaining sessions,
branches, commits, and worktrees:

```powershell
factory stop
```

After restarting the computer or Claude Code, run:

```text
factory start
factory status
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
factory scheduler status
```

- `status` reconciles sessions and summarizes the queue.
- `inspect` shows all normalized data for one task.
- `transcript` summarizes the worker conversation.
- `doctor` checks the selected worker CLI, PowerShell runtime and required
  cmdlets, parsed worker definition, agent-resolution cache, publication
  readiness, runtime files, locks, worktrees, and scheduler. Publication
  settings that intentionally disable direct release are a warning, not a
  required factory-health failure.
- `factory scheduler status` validates the recorded PID/start time and reports
  the native heartbeat without calling AI.

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

Integration and release checks are executed by the native pipeline through the
bundled wrapper. Their databases are `<prefix>_integrator` and
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
- Do not run `factory purge -Yes -Force` without reading its preview; it can
  remove uncommitted work.
- Do not run `go` before reading `/factory review`.

## 16. Daily checklist

```text
1. Run factory start.
2. Run /factory status.
3. For awaiting-input: run /factory chat <id>, open the worker, and reply.
4. For awaiting-review: run /factory review <id>.
5. If acceptable: run /factory go <id>.
6. Run /factory status again later.
```
