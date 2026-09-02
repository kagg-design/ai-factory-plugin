# TASK — serialize the test lane, stop gating the coding lane

## The problem, as seen by the operator

> **Igor Gergel, 2026-08-31:** "I do not think our bottleneck is the number of tasks writing code.
> Imagine 20 developers working on a project. They write code in parallel and update from `develop`
> only before pushing. Our narrow and expensive stage is testing. When do we run it? Before push.
> Therefore the only strict limit should be allowing no more than one task into test/push."

He is right, and the current knob is on the wrong axis. `concurrency` gates **launches**, counted over
tasks in `starting | planning | running` (see the tick skill's "Fill dynamic capacity"). A task parked
in `awaiting-input` is idle and frees its slot, so the knob does not limit what actually costs money:
it limits how many workers exist, not how many full test suites run at once.

What that produced on 2026-08-31, with 32 tasks enqueued from one Asana batch:

- `concurrency: 10` would have launched ten workers immediately; lowered to 1, then 5, then 3 by hand.
- Every answered Step 0 relaunched a worker, which woke the scheduler, which **cleared `paused`** as a
  side effect of `set-concurrency` on an increase — the batch grew from the five the operator chose to
  eight, twice, in queue order rather than by his choice.
- `hold` cannot be used on a `queued` task (`cannot be held from status 'queued'`), so there was no
  way to keep the other 27 out of the batch except pausing the whole factory, which does not stick.
- Three workers ran full parallel suites (8 processes each) while a publication ran **two more** check
  sets of its own (`integrate-task.ps1:366-367` starts the integrator and the release sets together,
  `checksParallel = true`). That is up to five concurrent suites, ~40 PHP processes, on one machine
  with one Postgres.

Meanwhile the coding phase is genuinely parallel and cheap: isolated worktrees, isolated test
databases (`testDatabaseIsolation`), no shared state. Nothing about it needs a limit.

## The shape to build

Two lanes with different rules.

**The coding lane is wide.** Many workers write code at once. No rebase during coding — churn against
a moving `develop` buys nothing while the work is unfinished.

**The test lane is exactly one.** Anything that runs the FULL suite takes an exclusive lease:

1. a worker's final verification before it emits its result;
2. the orchestrator's review runs;
3. the pipeline's integration check set;
4. the pipeline's release check set.

**The rebase moves inside the lease**, immediately before the verification run — exactly the
`git pull --rebase` a developer does before pushing. That also deletes a whole class of failure the
factory hits today: `Remote branch tips moved after review. Run sync and review again before go.`
fires because verification and push are separated in time. Inside one lease they are not.

Targeted tests — a worker running its own new test file while it iterates — need no lease. Only the
full suite does. Serializing everything would make the coding lane slow for no benefit.

## Requirements

### 1. A lease primitive

`scripts/test-lease.ps1` with `-Action acquire|release|status|reclaim`, state in
`runtime/projects/<key>/test-lease.json`:

```json
{
  "holder": { "taskId": "...", "phase": "verify|integration|release|review", "pid": 1234,
              "acquiredAt": "...", "heartbeatAt": "..." },
  "queue": [ { "taskId": "...", "phase": "...", "requestedAt": "...", "priority": 10 } ]
}
```

- `acquire` blocks (or returns a wait token the caller polls) and writes through the existing state
  mutex used by `Write-FactoryJsonAtomic`.
- A heartbeat is refreshed while the run is in flight; a lease whose heartbeat is older than a
  configurable TTL (default 30 minutes — a full suite here is ~2 minutes) is **reclaimable**, and
  reclaiming writes a line naming the abandoned holder. A crashed worker must never wedge the lane.
- `release` is idempotent and safe from a `finally`.

### 2. Priority, not just FIFO

A publication outranks a worker's verification: it holds a SHA that has already been reviewed, and
every minute it waits is a minute in which `develop` can move and invalidate it. So
`integration` and `release` sort above `verify` and `review`; ties break on `requestedAt`.

### 3. Split the knob

- `codingConcurrency` (default 8) gates launches, replacing today's `concurrency` for that purpose.
- The test lane is 1 and is not a tunable. If a future machine can take two, that is a separate
  decision with evidence, not a config field somebody raises hopefully.
- Accept `concurrency` as a deprecated alias for one version so existing project configs keep
  working, and have `factory doctor` say which one is in effect.

### 4. Fix the two levers that fought the operator

- **`set-concurrency.ps1` must not resume a paused factory.** Today an increase calls the scheduler's
  resume, so raising the limit silently un-pauses the queue. Raising a limit and starting work are two
  decisions; the skill can still *suggest* `factory resume` in its output.
- **`hold` must be allowed from `queued`.** A queued task has no worktree, no session and no commit —
  holding it is the cheapest possible operation, and it is the only way to say "not this one, not
  yet". Keep the existing refusals for states where holding would strand real work.

### 5. Teach the contracts about the lease

`agents/worker.md` and `resources/codex-worker-instructions.md` currently ask for
"tests directly relevant to the changed behavior" (`workerRequiredChecks`), while the orchestrator's
briefs ask for the full parallel suite. Under the lease the worker must:

- run targeted tests freely while coding;
- call the lease script before the full suite, and release it in a `finally`;
- rebase (via `sync-task.ps1 prepare`) **while holding** the lease, then run the suite, then emit its
  result.

The worker must not decide on its own whether the lane is busy — it asks and waits.

### 6. Use the exclusivity you just bought

With the lane exclusive there is no reason for the pipeline to run the suite single-process. The
inferred commands in this project are `vendor/bin/pint --test` and `php artisan test` — no
`--parallel` — which is why one publication occupies roughly seven minutes of wall clock. Under an
exclusive lease the pipeline's own runs should use the project's parallel form, and the inference that
fills `integrationTestCommands` / `releaseTestCommands` when they are empty should prefer it.

The integrator and release check sets may stay parallel **with each other**: they are two halves of
one publication and one lease.

### 7. Make it visible

- `factory status` shows the lease: who holds it, which phase, how long, and the queue behind it. The
  operator's first question when nothing seems to be moving is "what is testing right now".
- `factory doctor` reports a stale or reclaimed lease.

## What must not change

- Worktree creation, test-database isolation, and the per-process database suffixes.
- The three integrity checks before publication (HEAD equals the result commit, branch matches,
  worktree clean).
- The `motivehr` repository. Nothing here is a product change.

## Verification

Add to `tests/run-tests.ps1`, in its existing style:

1. Two competing `acquire` calls serialize: the second observes the first as holder and proceeds only
   after `release`.
2. A lease whose heartbeat is older than the TTL is reclaimed, and the reclaim is recorded.
3. `release` from a `finally` after a simulated failure leaves the lane free.
4. A publication queued behind a worker verification is served first.
5. `hold` succeeds from `queued` and the task can later be released the ordinary way.
6. `set-concurrency` on an increase leaves `paused: true` untouched.
7. `codingConcurrency` gates launches; a task in `awaiting-input` does **not** free a coding slot for
   a new launch while the operator has capped the lane (i.e. the count is over launched workers, not
   over active phases).

## The cost of this design, stated

Throughput becomes bounded by suite duration rather than by machine thrash. A full parallel suite here
is ~2 minutes; a publication runs two check sets, so ~4-5 minutes per publication. That is an upper
bound of roughly ten to twelve publications an hour, and if twenty tasks finish coding at once they
queue for the lane. That is the correct trade: an ordered queue with a visible holder beats five
suites fighting over one Postgres, and it is exactly how twenty developers behave when there is one
CI runner.

## Related

- `docs/tasks/TASK-result-marker-and-changed-files-validation.md` — the other two boundary bugs found
  in the same session.
- `docs/tasks/TASK-worktree-test-database-isolation.md` — why each worker already has its own database.
- Making the suite itself faster (persistent connections, fewer migrations per process) is a separate
  ticket; this one is about who may run it, not how long it takes.

---

## Addendum, 2026-09-01 — what the first day of the lease actually hit

The lease landed and works: `acquire`/`release`/`status` behave, the heartbeat holds a long review, and
`sync` refusing to run without a token caught the orchestrator immediately. Three things surfaced in
the first eleven publications' worth of use, all outside the lease itself.

### A. `prepare` will not re-rebase, and `finalize` refuses a stale base — the two halves deadlock

Observed on `local:20260831-162741-0c63f991`. Sequence: a `prepare` in the morning rebased onto develop
`ed29d35` and recorded the branch as prepared. Two publications later develop was `ed149e4`. Then:

- `sync-task.ps1 prepare` answered `alreadyPrepared: true` and did nothing;
- `sync-task.ps1 finalize` threw `Sync candidate '<head>' does not contain current development base
  '<base>'` (sync-task.ps1:150-153).

So the task could neither be re-prepared nor finalized, and the orchestrator had to rebase the worktree
by hand to get out. **Required:** `prepare` compares the recorded base against the current remote tip
and rebases again when it moved, regardless of the prepared marker. The marker should mean "prepared
against base X", not "prepared".

### B. The pipeline cannot run the suite in parallel yet — two separate reasons

Requirement 6 above says the pipeline should use the project's parallel form. Two things block it:

1. **`brianium/paratest` is a `require-dev`**, and the `factory-integrator` / `factory-release`
   worktrees had been installed without dev dependencies, so Collision refused outright:
   `Running Collision 8.x artisan test command in parallel requires at least ParaTest 7.x`. Installing
   dev deps in both worktrees fixed that — but nothing in the plugin does it, so it will regress the
   next time those worktrees are rebuilt. Whatever prepares them must install dev dependencies if the
   configured check commands need them.
2. **With parallel working, the two check sets together exhaust Postgres.** `integrate-task.ps1:383-384`
   starts the integrator and release sets at the same time (`checksParallel = true`), so at
   `--processes=8` each that is sixteen databases migrating at once, and the run dies with
   `SQLSTATE[53200]: out of shared memory — you might need to increase max_locks_per_transaction`.

So requirement 6 needs a precondition: **serialise the two check sets** (they are two halves of one
publication and one lease, so nothing is lost but wall clock), or cap the process count, or document
the server setting. Until then the pipeline stays on the single-process form and a publication costs
about seven minutes.

### C. The lease guards the plugin's scripts, not a human at a terminal

The orchestrator ran two full suites by hand, in the same worktree, against the same test-database
prefix, and got `SQLSTATE[40P01] deadlock detected` during migrations. The lease was held at the time —
by that same orchestrator, for a different purpose. Not a defect in the lease; a note for the skill:
**any hand-run full suite has to take the lease too**, and `factory status` showing the holder is what
makes that checkable.
