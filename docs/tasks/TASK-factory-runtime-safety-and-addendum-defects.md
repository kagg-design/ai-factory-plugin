# Factory runtime safety and liveness addendum — 2026-09-04

This task is the English repository record of the external follow-up defect
report. The source report remains outside this repository. It corrects two
claims in the earlier liveness task and adds four measured defects plus one
runtime-placement risk.

## Corrections to the earlier report

1. PowerShell failures already return a nonzero process exit code. The earlier
   zero-code observation came from reading the exit code of `tail` in a shell
   pipeline. No error-exit rewrite is required.
2. The long worker, dependency, Git, and test operations audited in the
   follow-up already run outside the global state mutex. The measured 30-second
   mutex timeouts are real, but their holder is unknown. The correct response is
   instrumentation, not speculative lock-boundary restructuring.

## Required behavior

### 1. Recover scheduler status after a transient tick failure

- Reset the current loop error before each tick.
- A failed tick records `lastError`, `lastFailureAt`, and the failure count once.
- The next successful tick clears `lastError`, returns the live process to
  `running`, and preserves the historical failure timestamp.
- A live scheduler retrying after an error must not be reported as a dead
  scheduler, start a duplicate process, or repeatedly wake an orchestrator.

### 2. Separate AI review work from the human `go` decision

For a closed `awaiting-review` task:

- no current approved review means `REVIEW`, an orchestrator action;
- `review.commit == task.commit`, verdict `approved`, and no approval means
  `GO`, a human-operator action.

Default `factory wait` calls are an orchestrator boundary and must ignore the
second state. The task remains prominent in `factory status`, with
`factory go <id>` as its next command. Native callers may explicitly include
human approval notifications.

### 3. Reclaim a test lane when both recorded processes are dead

- A live holder PID always prevents reclaim.
- A live recorded heartbeat PID also prevents reclaim.
- When both positive recorded PIDs are absent from the process table and the
  heartbeat timestamp is readable, reclaim immediately without waiting for the
  normal TTL.
- A missing heartbeat PID is not proof of death and does not permit early
  reclaim; ordinary TTL behavior remains available.
- An unreadable heartbeat remains fail-closed.
- Record every reclaim in the existing private audit log.

### 4. Remove phantom test-lane waiters

`test-lease.ps1 -Action status` must remove queue rows whose waiter process no
longer exists, persist the cleaned queue, report how many rows were removed, and
show only live waiters. Acquisition must retain the same cleanup behavior.

### 5. Attribute the unexplained state-lock timeouts

While the global mutex is held, keep a private owner record with its token,
project key, PID and process start time, call site, acquisition time, and wait
duration. On release, append slow waits or holds to a JSONL audit. On timeout,
append a timeout event and include the current recorded holder in the error.
Diagnostic-write failures must never break factory operations.

### 6. Put active runtime beyond the reach of Git cleanup

Fresh projects default to the deterministic external location:

```text
%LOCALAPPDATA%\ClaudeFactory\projects\<repository-name>-<canonical-path-hash>
```

The mapping is derived automatically from the canonical main-worktree path;
operators do not maintain a manual mapping. An explicit
`CLAUDE_FACTORY_HOME` remains authoritative.

Upgrading an existing project must continue selecting its legacy
`<plugin>\runtime\projects\...` directory so the factory cannot silently open
an empty queue. Provide:

- `factory runtime` for exact active/legacy/recommended paths, placement risk,
  size, state path, current mutex owner, and contention log;
- `factory runtime migrate` as a stopped, copy-only migration.

Migration must refuse a live orchestrator, scheduler, worker or publication,
preview, or test-lane holder. It copies into a temporary external directory, compares every
original file by relative path, length, and SHA-256, atomically publishes the
verified copy, writes a receipt, and retains the source. It must not run
automatically against the live MotiveHR runtime.

Repository agent instructions must forbid broad ignored-file cleanup such as
`git clean -x` and `git clean -X`. This is defense in depth for legacy runtime;
the external default is the hard boundary that prevents repository-scoped Git
cleanup from reaching active state.

## Verification

- A synthetic scheduler fails once, is observed as failed, then returns to
  running after a successful tick with no current error and the original
  failure timestamp preserved.
- A current approved review produces a human `GO` event; default wait ignores
  it, while an explicit human-approval wait returns it.
- A fresh lease with dead owner and heartbeat PIDs is reclaimed before TTL.
- Status removes a dead waiter, retains a live waiter, and persists the result.
- Mutex tests exercise the owner record, slow-release audit, and timeout
  attribution against synthetic runtime only.
- A fresh synthetic repository resolves to LocalAppData, while an existing
  legacy project remains selected.
- Synthetic migration verifies all source files, writes its receipt, and leaves
  the source untouched.
- No test or migration mutates the live MotiveHR runtime.
