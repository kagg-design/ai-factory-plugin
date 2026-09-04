# Factory liveness defects — 2026-09-04

This report was assembled from the `motivehr-4893d8fb` factory logs and state
between 2026-08-20 and 2026-09-04. The observations below are measured rather
than hypothetical. The temporary external `watch-queue.py` workaround should
be unnecessary after these defects are fixed.

## 1. A launch that never creates a session permanently occupies a slot

A task can remain in `starting` after its worktree and branch are created but
before a background session is recorded. The scheduler used to count the task
as a worker based only on status, so it could neither recover the launch nor use
the slot for queued work.

Observed example: `local:20260904-074412-998e2f9a` remained in `starting` for 34
minutes without a session. Alongside `local:20260904-081006-900b8b64`, state
reported two active workers while 34 consecutive scheduler ticks launched
nothing.

Required behavior:

- Write `launchStartedAt` when reserving a launch.
- After a configurable timeout (300 seconds by default), change
  `starting`/`planning` without a session to an explicit retryable failure.
- Do not count a sessionless launch as occupied coding capacity.
- Allow `retry` for `starting`/`planning` without a session and for the resulting
  launch failure.

## 2. A dead scheduler must be visible to the operator

On 2026-09-02 the scheduler recorded a `process-missing` event, but queued work
did not move until the condition was discovered manually.

When runnable work exists and the scheduler process is stopped or dead,
`factory status` must put the scheduler under `NEEDS YOUR ACTION` with the
saved reason, detection time, and exact recovery command. A live process with
a failed tick is retrying and must not trigger duplicate recovery. A heartbeat
stored only in private state is insufficient.

## 3. Instrument the unexplained global state-mutex timeouts

Correction from the follow-up audit: the original mechanism stated here was
wrong. Worktree creation, dependency installation, Git synchronization, and
test execution were already outside the global state mutex. Do not restructure
those paths in response to this report.

Between 2026-08-20 and 2026-09-04, 97 of 34,150 scheduler ticks exceeded 60
seconds; the slowest took 1,811 seconds. The same period contained 88 factory
state-lock timeouts, 14 tick exceptions, and 16 loop errors.

The global mutex has a 30-second acquisition timeout, but the process and call
site responsible for the measured timeouts are unknown. Record the current
owner PID, process start time, caller, acquisition time, wait duration, and hold
duration in private runtime diagnostics. A timeout must include the recorded
holder and append an audit row. Diagnostics must never become a new failure
mode. Enqueue must continue to atomically add a task and return without waiting
for worker launch.

## 4. Factory needs a native operator-action signal

Polling scheduler logs is unsafe on Windows because a log reader can interfere
with the writer. Provide a native `factory wait` boundary that blocks on atomic
factory state and returns when input, a closed-session review, a blocker, a
failure, a stalled launch, or a dead scheduler requires the operator.

An `awaiting-review` task whose worker session is still live is waiting, not yet
actionable. Both review finalization and approval already reject such a task.

## Safety and regression requirements

- Test only against a synthetic repository and private runtime; do not mutate
  the live MotiveHR factory state.
- Kill or simulate loss of a launcher after the transition to `starting` and
  verify automatic failure plus native retry.
- Verify enqueue returns before launch and long sync work does not block the
  global state mutex.
- Verify `factory wait` ignores a live closing review session and returns after
  the session becomes terminal.
