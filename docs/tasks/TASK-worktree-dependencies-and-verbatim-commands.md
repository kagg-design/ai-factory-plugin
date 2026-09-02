# TASK — install dependencies in the worktrees, and run the configured command verbatim

## What happened, 2026-09-01

One task (`local:20260831-194006-720f8ded`, TASK-PWA-002) added a Composer dependency —
`laravel-notification-channels/webpush`. Publishing it took **three attempts and about fifty minutes**,
and neither failure was in the task's code. The same commit, unchanged, passed every time it was run in
a worktree whose `vendor/` matched its `composer.lock`.

**Attempt 1** ran `php artisan test --parallel` and died with 3536 errors out of 4136 tests:

```
Illuminate\Database\QueryException: SQLSTATE[53200]: Out of memory: 7 ERROR:  out of shared memory
HINT:  You might need to increase "max_locks_per_transaction".
```

ParaTest had chosen **24 processes** (the machine's logical CPU count). The Postgres lock table is
`max_locks_per_transaction × max_connections`; at that cluster's defaults, 64 × 100 = 6400 slots, and one
migration transaction takes several hundred. Twenty-four backends migrating at once exhaust it.

**Attempt 2**, with the command pinned to `--processes=5`, failed the same size of failure for a
different reason:

```
1) Tests\Unit\Reports\AsOfBatchReadersTest::…
Error: Class "NotificationChannels\WebPush\PushSubscription" not found
  database/migrations/2026_08_31_200313_create_push_subscriptions_table.php:25
  …/Illuminate/Foundation/Testing/RefreshDatabase.php:119
```

The `factory-integrator` worktree's `composer.lock` already carried the new package — the merge brought
it — and its `vendor/` did not, because **nothing in the plugin installs dependencies in that worktree**.
The error surfaces inside a migration under `RefreshDatabase`, so every test that touches the database
fails, including thousands that have nothing to do with the change. The visible tail of the log is
hundreds of `Test code or tested code did not remove its own error handlers` lines, which is a
consequence, not the cause; the cause is only in the first numbered block.

**Attempt 3** succeeded after a human ran `composer install` in `factory-integrator` and
`factory-release` by hand and pinned `--processes=12`.

The same trap then hit the **worker** worktrees: a worker that rebases onto a development branch
carrying the new dependency has a fresh lock and a stale `vendor/`, and its own verification run fails
identically. That is not one task's bad luck — it is every task that follows any dependency change.

## Requirement 0 — the lease's staleness check is culture-dependent, and it voids the lease

**Highest priority in this file: with this bug present, the exclusive test lane guarantees nothing.**

Observed 2026-09-01, 14:28 UTC. A lease acquired at 14:26 for `review` was reclaimed **two minutes
later**, out from under the orchestrator, which then could not finalize its own sync:

```
Sync test lease token does not own this task's verify/review lane.
```

`test-lease.reclaims.jsonl`:

```json
{"reclaimedAt":"2026-09-01T14:28:42.0101254Z","taskId":"1217970193788232","phase":"review",
 "pid":57912,"heartbeatAt":"09/01/2026 14:28:28",
 "reason":"Test lease heartbeat is 20311214 second(s) old; TTL is 1800 second(s)."}
```

20,311,214 seconds is 235 days. Note the recorded heartbeat: `09/01/2026 14:28:28`, a `MM/dd/yyyy`
string — 1 September written US-style. This machine's culture is **en-GB**, so
`[DateTime]::TryParse("09/01/2026 …")` reads it as **9 January**, and 9 January → 1 September is
exactly 235 days. The lease then looks stale on the tick after it is taken.

Every writer is correct: `Get-FactoryUtcTimestamp` is `[DateTime]::UtcNow.ToString("o")`, and
`test-lease.ps1:186` / `:290` and the scheduler all use it. The two READERS are the defect:

```powershell
# test-lease.ps1:66-69  — Get-TestLeaseAgeSeconds
$heartbeatAt = [string](Get-FactoryNestedValue -Target $Holder -Name "heartbeatAt" -Default "")
if (-not [DateTime]::TryParse($heartbeatAt, [ref]$parsed)) { return [int]::MaxValue }

# test-lease.ps1:90  — Write-TestLeaseReclaimRecord
heartbeatAt = [string](Get-FactoryNestedValue -Target $Holder -Name "heartbeatAt" -Default "")
```

So by the time it is read the value is a `[DateTime]`, not the string that was written — `[string]`
on it yields a culture- or invariant-formatted date, and `TryParse` then interprets it under the
current culture. (Which component converts it was not pinned down: `ConvertFrom-Json` under
Windows PowerShell 5.1 was tested directly and returned a `System.String` for exactly this input,
so the conversion happens somewhere else in the path — possibly a different host or a different
PowerShell edition running the heartbeat, which `acquire` launches through ShellExecute.)

**The fix does not depend on finding that component:**

- Never `[string]` a value that might be a `DateTime`. Normalise on read: if it is already a
  `DateTime`, use it; if it is a string, parse it with `[DateTime]::TryParseExact` against `"o"`
  (and a small list of accepted round-trip formats) using `CultureInfo::InvariantCulture` and
  `DateTimeStyles::RoundtripKind | AssumeUniversal | AdjustToUniversal`.
- On write, always format explicitly with `ToString("o", CultureInfo::InvariantCulture)`.
- `return [int]::MaxValue` on an unparseable timestamp is the wrong default for a lock: an
  unreadable heartbeat means "I do not know", and the safe answer is **not stale**. Failing open on
  a mutex is how two full suites end up on one Postgres. Treat a parse failure as fresh, log it
  loudly, and let `factory doctor` report it.
- A reclaim must also check that the holder's PID is gone (`Test-TestLeaseProcess` already exists
  and was not consulted here — PID 57912 was alive and working). A live PID plus an unreadable
  timestamp is never a reason to steal the lane.

Verification, added to `tests/run-tests.ps1`:

1. A holder whose `heartbeatAt` is a `[DateTime]` object, not a string, is not reported stale.
2. Age is computed identically under `en-GB`, `en-US` and `ru-RU` (set
   `[Threading.Thread]::CurrentThread.CurrentCulture` in the test).
3. An unparseable `heartbeatAt` is treated as FRESH and surfaces a doctor warning.
4. A lease whose holder PID is still alive is not reclaimed, whatever the timestamp says.

### 0b. The heartbeat never fires at all

Separate from the culture bug above, and it compounds it. Observed 2026-09-02, 00:43-00:55 UTC, on a
lease held by a worker that was demonstrably alive (four `php.exe` processes running its suite):

```json
"acquiredAt":  "2026-09-02T00:43:12.5871251Z",
"heartbeatAt": "2026-09-02T00:43:12.5871251Z"
```

Twelve minutes in, `heartbeatAt` is still byte-identical to `acquiredAt`. The heartbeat process had not
updated it once. `acquire` launches it with `UseShellExecute = $true` and a hidden window
(`test-lease.ps1:150-170`), deliberately detached so it cannot hold the caller's stdout pipe — which
also means **nothing observes whether it started or survived**, and its own failures go nowhere.

The consequence at the shipped default TTL of 30 minutes: any full-suite run that takes longer than the
TTL loses its lease legitimately, because the timestamp never advances. On this project a suite is ~2
minutes so it did not bite on its own — but combined with the culture bug it means the lease was never
actually being renewed by anything.

What to do:
- `acquire` should verify the heartbeat process is alive (it already captures the PID — check it, and
  record `heartbeatPid` liveness in `status`).
- The heartbeat should log its own failures somewhere the operator can read, not into a detached hidden
  window.
- `factory doctor` should flag a holder whose `heartbeatAt` equals its `acquiredAt` while the holder PID
  is alive — that combination means exactly this defect.
- Consider making the holder's own PID liveness the primary staleness signal and the timestamp the
  secondary one. `Test-TestLeaseProcess` already exists and is not consulted (see Requirement 0).

## Requirement 1 — whatever creates or refreshes a worktree installs its dependencies

The integrator and release worktrees are reset to a fresh base and merged into on every publication
(`integrate-task.ps1`), and worker worktrees are rebased by `sync-task.ps1 prepare`. **Each of those
points must bring `vendor/` into line with the lock it now has.**

For a PHP/Composer project that means `composer install --no-interaction --no-progress`, **including dev
dependencies**, because the configured check commands need them: `brianium/paratest` is a `require-dev`,
and without it Collision refuses outright with
`Running Collision 8.x artisan test command in parallel requires at least ParaTest 7.x`.

Notes that matter in practice:

- **Only when it can change anything.** Comparing the lock's hash against the installed
  `vendor/composer/installed.json` is enough to skip the no-op case; a full `composer install` on an
  unchanged tree still costs ~20 seconds, and publications already pay for two check sets.
- **Never in a worktree with a live worker.** A batch pass over every worktree at once was tried by hand
  on 2026-09-01 and abandoned: replacing `vendor/` under a worker that is running its own tests breaks
  that run. The install belongs to the operation that moved the base (create, reset, rebase), and to
  nothing else.
- **A worktree whose lock predates the change legitimately has no such package.** "Package missing" is
  not a health check; "lock hash differs from installed" is.
- The project is not necessarily PHP. Infer the ecosystem the same way the check commands are inferred
  (`composer.json` → Composer, `package-lock.json` → `npm ci`), and do nothing when nothing is
  recognised.

## Requirement 2 — a configured command runs verbatim

`Resolve-FactoryReviewCommands` (`scripts/factory-common.ps1:401-408`) rewrites any command matching
exactly `^php artisan test$` into `php artisan test --parallel`:

```powershell
if ($command -match '^(?i:php(?:\.exe)?\s+artisan\s+test)$') {
    "$command --parallel"
}
```

So an operator who deliberately configures the single-process form gets the parallel one, the pin is
silently void, and the failure log names a command that appears nowhere in the config — which reads as
"somebody changed my settings". This cost one wrong diagnosis on 2026-09-01: the parallel form was
assumed to be a stale config value rather than a rewrite.

**A value in `integrationTestCommands` / `releaseTestCommands` / `workerRequiredChecks` must be executed
exactly as written.** If parallelism is wanted by default, put it in the *inference* that fills those
fields when they are empty (Requirement 3), or behind an explicit config flag — not in string surgery
over a value the operator set.

## Requirement 3 — inference must not choose an unbounded process count

`Get-FactoryInferredReviewCommands` (`factory-common.ps1:372-386`) emits `php artisan test --parallel`
with no `--processes`, which means "as many as there are cores". On a 24-thread machine that is what
killed attempt 1.

Inference should emit a bounded form. A defensible default is half the logical processors, clamped to a
small maximum, because each process is a database connection running migrations rather than a CPU-bound
worker: measured on this machine, 5 processes and 12 processes both passed the 4136-test suite (2:16 and
2:31 wall clock — the run is I/O bound, so more processes buy almost nothing), while 24 failed outright.
Whatever the rule, it must be **written down in the emitted command**, so `factory status` and the
failure logs show the number that was actually used.

Also add `composer install --no-interaction --no-progress` as the first inferred command when
`composer.json` exists — belt and braces behind Requirement 1, and it makes a fresh project work before
anybody has configured anything.

## Requirement 4 — `prepare` must re-rebase when the base moved

Already filed as item A of the addendum to `TASK-serialize-the-test-lane.md`, and it fired twice more
today, so it is repeated here with fresh evidence.

`sync-task.ps1 prepare` answered `alreadyPrepared: true` and did nothing, while `finalize` refused:

```
Sync candidate 'fa70939…' does not contain current development base '631d676…'
```

The development tip had moved between the two calls (a human pushed a documentation commit). The task
could then be neither re-prepared nor finalized, and the operator had to `git rebase origin/develop` in
the worktree by hand. `prepare` must compare the recorded base against the current remote tip and rebase
again when they differ; the prepared marker should mean "prepared against base X", not "prepared".


### 4b. And a worker has no sanctioned way to re-rebase at all

Found 2026-09-01 by the worker on task `1217970363179091`, and it makes Requirement 4 more urgent than
it looks. The two facts together close every door:

- `sync-task.ps1 prepare` answers `alreadyPrepared: true` and does not re-rebase (Requirement 4).
- `git rebase` is DENIED to a worker by the plugin's own git guard, which refuses history rewriting on
  `factory-worker/*`.

So when the development tip moves under a worker — which on a busy day is every few minutes — the
worker cannot rebase through the plugin and cannot rebase around it. The one it found is
`git reset --hard origin/develop` followed by `git cherry-pick <its own commit>`, which for the
single-commit branches the contract requires is equivalent to a rebase and happens to be allowed. That
is a worker reasoning its way around a hole, not a workflow.

Fix `prepare` (Requirement 4) and the hole closes. Do NOT relax the guard: it is protecting against
much worse than the inconvenience of one command. If a sanctioned escape hatch is wanted anyway, it
belongs in `sync-task.ps1` as an explicit `-Force` re-prepare that the guard recognises, not in the
worker's hands.

Worth checking while in there: whether the guard's deny list and `prepare`'s own git calls are
consistent, since `prepare` must itself do the thing the guard forbids.

### 4c. A `blocked` session is invisible, and it costs hours

Two tasks on 2026-09-01 sat with `backgroundSession.state = "blocked"` for **nine and twelve hours**
(`1217970363200004` from 14:26, `1217970226784204` from 16:51). Neither carried an `error`, neither had
a `holdReason`, and `factory status` renders them as ordinary work in progress — one as `planning`, one
as `running`. The orchestrator found them only by dumping state by hand while looking for something
else.

Both were almost certainly waiting on the git guard's refusal of `git rebase` (Requirement 4b): the
worker asks for a permission that nothing will ever grant, and stops.

What is needed, in order of value:

1. **Surface it.** `factory status` must show a blocked session AS blocked, with how long it has been
   blocked, and `factory doctor` must report one. A state the operator cannot see is a state that
   costs a working day.
2. **Say what it is waiting for.** The session record knows the tool call that stalled; carry enough of
   it into state that the operator can act without attaching.
3. **Time it out.** A session blocked longer than a configurable threshold should transition the task
   to `blocked` with a `holdReason` naming the stall, so the scheduler stops counting it as an active
   worker — it is holding a coding slot the whole time (see `Get-FactoryLaunchedWorkerCount`).
4. Worth telling workers too: the contract should say that if a command is refused, the worker emits
   its result with the refusal in `notes` rather than waiting. That is a `resources/codex-worker-instructions.md`
   and `agents/worker.md` change.

## Verification

Add to `tests/run-tests.ps1`, in its existing style:

1. A worktree whose lock differs from its installed set gets dependencies installed by
   create/reset/rebase; one whose lock matches is left alone (assert the install was not invoked).
2. A configured command is passed to the runner byte-for-byte, including the bare `php artisan test`
   form, with no `--parallel` appended.
3. Inference emits a bounded `--processes=N` and, for a Composer project, an install command before the
   test command.
4. `prepare` on a task whose recorded base is behind the remote tip rebases and updates the recorded
   base; `finalize` then succeeds.
5. The batch case is refused: an install is never run in a worktree whose task has a live session.

## What must not change

- The three integrity checks before publication (HEAD equals the result commit, branch matches, worktree
  clean).
- Test-database isolation and the per-process database suffixes.
- The `motivehr` repository. Nothing here is a product change.

## Related

- `docs/tasks/TASK-serialize-the-test-lane.md` — the lease, and the addendum this extends.
- `docs/tasks/TASK-result-marker-and-changed-files-validation.md` — the other boundary bugs.
- `docs/tasks/TASK-worktree-test-database-isolation.md` — why each worker already has its own database.
