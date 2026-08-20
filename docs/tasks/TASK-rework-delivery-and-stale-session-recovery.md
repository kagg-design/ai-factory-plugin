# TASK — rework delivery, stale-session recovery, scheduler observability, and the guard's `merge` pattern

Author: orchestrator session, 2026-08-19, extended 2026-08-20 with P8 and P9. Everything below was
observed on live runs of this plugin against the `motivehr` repository on those two days, with the
exact task ids, timestamps and error text quoted. Nothing is speculative unless it says so.

Today's cost of these defects: **three finished tasks could not be published through any command
sequence the plugin offers.** Two of them had to be re-done from scratch by fresh workers
(`local:20260819-082401-b138a998`, `local:20260819-084706-16a62d02`) and one is on its third
worker (`local:20260819-093226-2c5b2031`) — roughly two hours of worker time and four full test
suite runs to move code that was already reviewed and green.

## Context you need before touching anything

- Plugin root: `C:\laragon\www\Projects\claude-factory-plugin`. Scripts in `scripts\`, the command
  surface in `skills\factory\SKILL.md` and `standalone\.claude\skills\factory\SKILL.md`, worker
  agent in `agents\worker.md`.
- Private runtime: `runtime\projects\<projectKey>\state.json` plus `sessions\` and `events\`. The
  project in play is `motivehr-4893d8fb`.
- Worker worktrees live outside the target repo: `C:\laragon\www\.claude-factory-worktrees\<projectKey>\`.
- Every script runs under **Windows PowerShell 5.1** with `Set-StrictMode` in effect through
  `factory-common.ps1`. Several defects below are StrictMode property accesses; fixes must be
  correct under 5.1, not only under `pwsh` 7.
- There is a test harness: `tests\run-tests.ps1`, with a fake `claude` (`tests\FakeClaude.cs`), a
  fake `codex` and a fake `psql`. It builds a temp repo and a temp runtime, so launcher, reconcile
  and sync behaviour are all testable without spawning real sessions. **Every fix below needs a
  regression there** — all of these defects are state-machine defects, which is exactly what that
  harness covers.
- The orchestrator that hit these is a **background** Claude session. It cannot type into a worker's
  chat, and it cannot answer an interactive prompt. Any recovery path whose last step is "the
  operator attaches to the worker session and tells it what to do" does not exist for that caller —
  which is how P1 becomes fatal rather than inconvenient.

### Live work you must not disturb

| Task | State | Why it matters |
|---|---|---|
| `local:20260819-093226-2c5b2031` | **running**, third attempt at porting TASK-SURVEY-003 | A worker is editing files right now. Do not stop it, clean it, or rewrite its row. |
| `local:20260819-085258-7d025ad7` | `awaiting-review`, commit `6c44331`, session record stuck at `working` — this is the P2 specimen | Do not reject or clean it: the running task above reads that commit's diff out of this repository. It is also the best live reproduction you will get. |
| `local:20260818-155355-e5f06e2b` | `awaiting-review`, commit `0a0d62e` | Same: reachable-object source, not yet superseded. |

Do not commit or push in the plugin repository. In this project commits happen only on the owner's
explicit "go".

---

## P1 — `rework` records instructions that nothing can ever deliver

**Symptom.** `task-action.ps1 -Action rework` reports success and writes the instructions into the
task. The worker never receives them. The task then sits in a state where every other command
refuses it, and the only way forward is to throw the task away and re-do the work in a new task.

**Evidence.** Task `local:20260818-154808-badf6a52` (TASK-SURVEY-002, commit `7c8868f`, reviewed,
two small findings). `rework` ran at 07:28:15Z and wrote `pendingInstructions` and
`reworkRequestedAt`. Thirty minutes and several scheduler ticks later the worker had not been
prompted, `attemptPrepared` was still `false`, and:

- `answer-task.ps1` → `Task 'local:20260818-154808-badf6a52' already has a validated result or commit.`
- `task-action.ps1 -Action hold` → `Task 'local:20260818-154808-badf6a52' cannot be held from status 'running'.`
- `task-action.ps1 -Action retry` → `not in a retryable machine state`
- `sync-task.ps1` / `record-review.ps1` → refused (see P2)

The same sequence repeated on `local:20260818-155434-930bf82a` after a `changes-required` review.

**Root cause.** Three files disagree about who delivers `pendingInstructions`.

1. `scripts\task-action.ps1:102-111` — rework requires an existing `backgroundSession.id`, clears
   `review`/`approval`, sets status `awaiting-input`, stores `pendingInstructions`. It deliberately
   keeps the session, on the assumption that a live session is waiting for input.
2. `scripts\start-worker-session.ps1:52-65` — the launcher's first action is: if the task has a
   `backgroundSession.id`, print `reused = true` and **exit 0 without launching anything**. So the
   scheduler cannot deliver either; it reports "reused" every tick.
3. `scripts\answer-task.ps1:38` — the one command that does remove the session and relaunch
   (`Close-FactoryTaskWorkerSessions` at :56) refuses outright once the task has a `commit` or a
   `workerResult`. Post-commit rework is precisely the case it rejects.

There is also a fourth hole underneath: **nothing in the launch path reads `pendingInstructions` at
all.** `grep -n pendingInstructions scripts\*.ps1` returns only writers (`task-action.ps1:110`,
`sync-task.ps1:264`, `sync-task.ps1:154` clearing it) plus one reader in `factory-cli.ps1:172` that
only prints it. `worker-launch.ps1` never mentions it. So even a fresh launch of the same task would
drop the instructions on the floor.

**Required fix.**

- Make `rework` a real delivery, end to end: dispose of the current worker session the way
  `answer-task.ps1` does, clear the stored `backgroundSession`, keep `commit`, `workerResult`,
  `branch`, `worktree` and `pendingInstructions`, and set a status the scheduler will actually pick
  up (`queued` is the existing mechanism; if you introduce a distinct `reworking`, the scheduler's
  capacity loop and `SKILL.md` must learn it in the same change).
- Make the launch path compose `pendingInstructions` into the worker prompt whenever they are
  present, alongside the existing task payload, and clear them once the prompt file is written —
  not before. A worker resuming a task with an existing commit must be told, in the prompt, that a
  commit already exists, that it is being asked to amend or add to it, and what the findings are.
- `answer-task.ps1`'s guard must stop being an absolute: a task with a commit is answerable when
  `reworkRequestedAt` (or an equivalent explicit flag) is set. Keep the guard for the case it was
  written for — a stray answer arriving for a finished task.
- Whatever you choose, the invariant to preserve is the one the review chain depends on: after
  rework, `review` and `approval` are null, so the amended commit must be reviewed again before
  `go`. Do not let rework leave an approval standing.

**Acceptance.** In the harness: a task with a validated commit and a recorded review is reworked;
within one scheduler tick a fake-claude session is launched for it; the prompt file passed to that
session contains the instruction text verbatim; the task's `review` is null; `pendingInstructions`
is cleared after the prompt is written; and the previous session id is gone from the task row.

---

## P2 — reconcile keeps a vanished session `working`, and downgrades a valid status to `running`

**Symptom.** A task whose worker finished its turn is recorded as having a `working` session
forever. Because two commands refuse a "working" session and one refuses the resulting status, the
task cannot be synced, reviewed, held or retried. It is unrecoverable without hand-editing
`state.json`.

**Evidence.** Task `local:20260819-085258-7d025ad7` (live now — see the table above). Its worker
committed `6c44331`, emitted `FACTORY_RESULT`, and stopped; the transcript's last write was 12:11
local and the task moved to `awaiting-review`. At 12:30:

- `claude agents --json` still listed session `8ae63db1` as `working` — 19 minutes after the turn
  ended.
- `sync-task.ps1` → `Task 'local:20260819-085258-7d025ad7' still has a working background session.` (`sync-task.ps1:80`)
- `record-review.ps1:82` refuses on the same condition, and so do `cleanup-task.ps1:136` and
  `task-action.ps1:127` — four call sites share this guard, so one stale flag closes every door.
- I then removed the Agent View row with `Remove-FactoryTaskAgentSessions` (from
  `factory-common.ps1`). `claude agents --json --all` no longer lists it. Two subsequent
  `reconcile-worker-sessions.ps1` runs left `backgroundSession.state` at `working` and did not even
  refresh `lastSeenAt`. The task is now permanently un-syncable and un-reviewable.

Earlier the same morning, the same defect produced the *other* half of P1's dead end: task
`local:20260818-154808-badf6a52` was set to `awaiting-input` by rework at 07:28:15Z, and reconcile
immediately overwrote that with `running`, which is why `hold` then refused it.

**Root cause.** `scripts\reconcile-worker-sessions.ps1`:

- Line 90: everything that maintains session state lives inside `if ($null -ne $sessionRow)`. When
  the runtime no longer reports the session, there is **no else branch** — the stale value is
  preserved indefinitely. A missing row is treated as "no news" when it is in fact the strongest
  possible news: the session is gone.
- Lines 308-309: `if ($sessionState -eq "working" -and $task.status -in @("starting","planning","awaiting-input"))`
  → status becomes `running`/`planning`. `awaiting-input` is in that list, so a session the runtime
  merely *reports* as working overrides an operator-set state. Rework's `awaiting-input` never
  survives one tick.

**Required fix.**

- Add the missing branch: when the session is absent from the runtime listing and the recorded state
  is not already terminal, record it as `stopped` (or a distinct `missing`) with a timestamp, and
  let the existing status rules apply — note that the `stopped` branch at :315 correctly leaves
  `awaiting-review`, `approved` and `done` alone, which is the behaviour this case needs.
- Never derive a status from session state alone when the task carries a validated
  `commit`/`workerResult`, and never move a task out of an operator-set state
  (`awaiting-input` set by rework, `held`, `syncing`) on the strength of a session row. The
  recorded artifacts outrank the session's liveness signal.
- Do not refresh `lastSeenAt` for a session that was not seen. It currently lies: my 07:48 run
  bumped it for a session that had not existed for minutes.
- Give the operator one explicit escape hatch, callable from a background session, that clears a
  stale session record and restores the status implied by the recorded artifacts — e.g.
  `task-action.ps1 -Action release`, plus a line in both SKILL.md copies. Today the only exits from
  this state are `reject` (throws the work away) and editing `state.json` by hand.

**Acceptance.** In the harness: a task with a validated commit whose fake session disappears from
the listing is reconciled to `stopped` while its status stays `awaiting-review`, and `sync` and
`record-review` both accept it afterwards. A task in `awaiting-input` with `reworkRequestedAt` set
is not moved to `running` by a `working` row. `lastSeenAt` is unchanged when the row is absent.

---

## P3 — a conflicting `sync` is a dead end, and its own instructions are undeliverable

**Symptom.** `sync-task.ps1 -Action prepare` aborts the rebase and throws on the first conflict.
There is no way to hand the conflict to the worker (P1), and no way to accept a resolution the
operator produced by hand, because `prepare` insists the worktree HEAD equals the recorded commit
and only `prepare` may write a new commit into the task row.

**Evidence.** Task `local:20260818-155355-e5f06e2b`:
`Could not synchronize task ... with 'origin/develop'. Conflicts: docs/dev/016-survey-engine.md.`
The conflict was three lines of a documentation list. I resolved it by hand in the worker worktree
(the rebase completes cleanly, producing `c649668`), then had to throw that away, because a
worktree HEAD the plugin did not create is not accepted anywhere. The task had to be re-done by a
new worker instead — twice, since the second attempt hit P2.

I also tried `rerere`: with `rerere.enabled true` and the resolution recorded, the plugin's rebase
does replay it (`Recorded preimage` / resolution applied), but rerere does not stage the file, so
`git rebase` still stops and `sync-task.ps1:241-250` sees a non-zero exit code and aborts. rerere
alone cannot rescue this path.

**Required fix.** Any one of these is acceptable; pick one and document it:

- Keep the rebase in progress instead of aborting, record a `syncing-conflict` state with the
  conflicted paths in the task row, and expose the resolution as work a worker can be dispatched to
  (which needs P1 fixed anyway). Provide `-Action abandon` to abort and restore cleanly.
- Or let `-Action finalize` accept a worktree whose HEAD the operator/worker produced: verify it is
  a single-parent commit on the recorded worker branch, that the configured development branch is
  its ancestor, and that the tree is clean, then record the new SHA. That is the same set of checks
  `prepare` already performs after its own rebase.
- Or honour `rerere.autoUpdate` and `git rebase --continue` when every conflicted path has been
  resolved and staged by rerere, and only abort when something is genuinely unresolved.

**Acceptance.** In the harness: a task whose rebase conflicts ends in a state from which the
operator can reach `awaiting-review` with a correct new SHA, using only documented commands, without
touching `state.json` and without launching a new task.

---

## P4 — the worker git guard blocks `git merge-base`, and blocks `cherry-pick` inside the worker's own branch

**Symptom.** Workers cannot run read-only history queries, and cannot move a commit within their own
worktree. Today's port had to be done with `git diff | git apply`, a recipe the worker discovered by
trial and error.

**Evidence.** `scripts\worker-git-guard.ps1:24` is `'(?i)(^|[;&|]\s*)git\s+merge\b'`. `\b` matches
between `merge` and `-`, so **`git merge-base` and `git merge-tree` are refused** — both read-only.
The worker on task `local:20260819-085258-7d025ad7` reported exactly that, and reported that the
denial text also catches the word `merge` anywhere it appears in a compound command. Line 25 blocks
`git cherry-pick` outright, although a cherry-pick inside the worker's own `factory-worker/*`
worktree touches no shared ref and is the same class of operation as the `commit` the guard allows.

The workaround the worker had to invent, and which is now the documented recipe in the operator's
notes, is:

```
git diff <sha>^ <sha> | git apply -p0 --3way
```

`-p0` is mandatory because the target repository sets `diff.noprefix`; with `-p1` half the files
report "does not exist in index" and nothing lands.

**Required fix.**

- Anchor the patterns to a whole git subcommand: `git\s+merge(?![-\w])`, and the same for any other
  pattern where a hyphenated sibling exists. Read-only commands must not be caught by a guard whose
  stated purpose is shared-history mutation.
- Decide explicitly about `cherry-pick` and `revert` inside the worker's own worktree. The guard's
  own reason string says "Push, merge, rebase, shared-branch checkout, and worktree deletion are
  reserved for the factory orchestrator" — cherry-pick is in none of those categories. If you keep
  it blocked, put the `git apply -p0 --3way` recipe into `agents\worker.md` so the next worker does
  not have to rediscover it.
- The denial message should name the offending command, so a worker can tell "your command is
  blocked" from "something in your command line matched a word".

**Acceptance.** Harness or unit test over the guard's matcher: `git merge-base A B`,
`git merge-tree`, `git log --merges` and `git diff` are allowed; `git merge foo`, `git push`,
`git rebase` are blocked; whatever you decide for `cherry-pick` is asserted.

---

## P5 — `sync -Action finalize` throws StrictMode noise when the test report omits `notes`

**Symptom.** `The property 'notes' cannot be found on this object. Verify that the property exists.`
— with no mention of the file, the field, or that `notes` is optional. It took a read of the script
to learn that the value has a default two lines below the failure.

**Evidence.** `scripts\sync-task.ps1:142-146` reads `[string]$testReport.notes` directly inside an
`if`, then falls back to a default in the `else`. Under StrictMode the property access itself throws
before the fallback can apply. Reproduced today with a report containing only `tests`.

**Required fix.** Read it through `Get-FactoryNestedValue -Target $testReport -Name "notes" -Default ""`,
as the rest of the codebase does. Then audit the sibling readers in the same file and in
`record-review.ps1` for the same pattern — the review file's optional fields are read correctly, so
this looks like a single oversight rather than a habit. Validation errors on operator-supplied JSON
should name the file and the field.

---

## P6 — a cleanup failure is reported as a production failure

**Symptom.** A task whose work was pushed to both branches is left `blocked` with an error message
about a missing property, and the real cause (cleanup) is invisible.

**Evidence.** `scripts\integrate-task.ps1:411-415`:

```powershell
$cleanup = (& powershell ... cleanup-task.ps1 ... -FinalizeProduction) | ConvertFrom-Json
[ordered]@{
    taskId = $TaskId
    status = [string]$cleanup.status
```

If `cleanup-task.ps1` throws or writes nothing, `$cleanup` is `$null` and `[string]$cleanup.status`
throws under StrictMode. That throw lands in the outer `catch` (:421), which records it against the
**production** stage — after both pushes have already succeeded. Observed 2026-08-18 on task
`1217555189255186`: `status = blocked`, error text about a missing `status` property, while the
commit was already on `master`. The wasted time went into looking for a bug in the task's code.

**Required fix.** Treat cleanup as its own stage. Verify `$cleanup` is an object with a `status`
before reading it; on cleanup failure keep the production audit truthful (pushes verified), record
the failure as `cleanup`, and give the operator a way to re-run just cleanup. A task whose commit is
reachable from both remote branches must never be reported as a production failure.

---

## P7 — two more from 2026-08-18, still worth fixing in the same pass

Observed on live runs on 18.08, not re-verified today; both are in the same family as the above.

1. **`config.json` is replaced non-atomically, and readers have no retry.** Twice in one day a child
   process failed with `Read-FactoryJson: Could not find file ...\config.json`
   (`run-isolated-test-command.ps1:19`) while the plugin was migrating the config, and once `go`
   failed with `Move-Item ... config.json ... IOException` because the 15-second scheduler had the
   file open. The config survived both times; the task fell out of the pipeline. Write via a temp
   file plus atomic replace, and read with a short retry.
2. **`factory preview stop` does not kill its process tree.** It reports "stopped" while
   `powershell`, `node` and `esbuild` processes with the worktree in their command line stay alive
   and hold handles inside `node_modules`. Cleanup then unregisters the worktree, fails to delete the
   directory, trips its own "residual worker directory is not a registered worktree" guard, throws —
   and P6 turns that into a false production failure. Net effect: **previewing a task makes its
   publication end in a lie.** Stop the whole tree (match on the worktree path in the command line),
   verify the directory is gone, and never leave a junctioned `node_modules` behind.

---

## P8 — the scheduler stops ticking, reports itself as stopped while it is working, and leaves no trace either way

Added 2026-08-20, after this cost two publications about twenty minutes each.

**Symptom.** An approved task sits in `approved` indefinitely. `factory scheduler` says
`Native scheduler: stopped`, `lastError` is empty, and both log files it names do not exist. The
operator restarts it by hand, the task publishes normally, and half an hour later the same thing
happens again.

**Evidence, today, on this project.**

- 14:29 local: task `local:20260820-110809-9e86e4e4` had been `approved` since 14:24 and had not
  moved. `factory scheduler` → `Native scheduler: stopped`, `Last tick: 11:08:38Z` — twenty minutes
  earlier, with a 15-second interval and a runnable task in the queue. Nothing was integrating in
  that window. Restarting it (`factory-scheduler.ps1 -Action resume`) published the task without any
  other change.
- 14:47 local: same reading again (`Last tick: 11:41:06Z`), same fix.
- 15:37 local: the third instance (pid 115288) **is alive** and `factory scheduler` says `running`,
  but `Heartbeat: 12:33:11Z` has not moved for four minutes — because the scheduler is inside
  `integrate-task.ps1`, which runs the full test suite twice, synchronously, without touching the
  heartbeat. So the same field means "dead" and "busy for the next fifteen minutes", and the
  operator cannot tell which. Restarting on that reading would put a **second** scheduler next to a
  live integration.
- `runtime\projects\motivehr-4893d8fb\scheduler.stdout.log` and `scheduler.stderr.log`, both named
  in the status object, **do not exist**. `Get-ChildItem` on that directory lists only `config.json`
  and `state.json`. A scheduler that dies leaves nothing at all to look at.

**Required fix.**

- Refresh the heartbeat from inside long work, or record what the scheduler is doing so that "busy
  integrating `<task>` since `<time>`" and "not ticking" are different, visible states. Never let a
  working scheduler be reported as stopped.
- Make `resume`/`start` refuse to spawn a second scheduler while another one holds work in flight,
  and say why. Right now the guard is only the recorded pid.
- Actually write the two log files the status object advertises: one line per tick with what it
  found and what it started, and a final line on exit with the reason. If the process is expected to
  be silent, stop advertising the paths.
- Investigate the twenty-minute gaps with a runnable task and no ticks (the first two readings). If
  a tick can throw and take the loop down, it must record that in `lastError` and in the log before
  it dies; if the process is being killed from outside — note that these calls came from a
  background orchestrator session whose shell process exits immediately after `Start-Process`
  (`factory-scheduler.ps1:259-264` uses `Start-Process -WindowStyle Hidden -PassThru`, a plain child
  of that shell) — then the scheduler must survive its launcher, and `doctor` should say whether it
  did.
- `factory status`'s footer already prints the scheduler line, but it reads as decoration
  (`scheduler native sleeping`). When there is runnable work and the scheduler is not ticking, that
  has to read as a problem, in the `NEEDS YOUR ACTION` sense.

**Acceptance.** In the harness: with a runnable approved task, a scheduler whose loop throws records
`lastError`, writes the reason to `scheduler.stderr.log` and is reported as failed rather than
sleeping; a scheduler inside a long integration is reported as busy with the task name and is not
restartable by `resume`; a tick that finds nothing to do still updates the heartbeat.

## P9 — raw ANSI test output is persisted into `state.json`

**Symptom.** `state.json` for this project is **4.1 MB** with three unfinished tasks. One failed
integration stored a 331 KB `summary` string containing the entire test run with every escape
sequence intact; reading the actual failure meant stripping `\x1b\[[0-9;]*m` from it first and
searching the tail. See `docs\tasks\TASK-encoding-state-bloat.md` for the earlier, worse version of
this problem (483 MB, different root cause: an encoding round-trip).

**Required fix.** Strip ANSI before storing, keep a bounded tail (the failure block and the summary
line are what anybody reads), and put the full output in a file next to the task's events with its
path in the task row. Keep the exit code and the command verbatim — those are what the pipeline
decides on.

## Tests

Add regressions to `tests\run-tests.ps1` for P1, P2, P3, P4 and P5 — that harness already fakes the
`claude` CLI, so all five are reachable without a real session. P6 needs a fake `cleanup-task.ps1`
failure path; if wiring that is disproportionate, at minimum add the null guard and say in the PR
that it is untested. Run the whole harness before you finish; do not leave it red.

## Do not

- Do not weaken the review chain: an approved review must still pin one immutable SHA, rework must
  still clear `review` and `approval`, and `go` must still refuse a commit that has not been
  reviewed since it changed.
- Do not weaken the single-parent task-commit rule or the "one commit above the development branch"
  invariant.
- Do not make any command push, merge or promote as a side effect of a recovery path.
- Do not silently rewrite `state.json` outside the mutex, and keep every state write atomic.
- Do not commit or push in this repository — the owner does that on an explicit "go".
