# TASK — Native Factory scheduler and unified PowerShell entry point

## Goal

Remove recurring AI turns from queue polling and capacity management. Keep AI
only for operations that require code judgment: intake normalization, sync test
selection, review, conflict decisions, integration test selection, and release
assessment.

## Native scheduler

`scripts/factory-scheduler.ps1` owns one hidden process per repository. It:

- validates identity with a named mutex plus recorded PID/process start time;
- reconciles Claude background worker sessions;
- launches the oldest queued tasks up to configured concurrency;
- publishes PID, heartbeat, last tick, last transition, failures, and backoff;
- sleeps without model calls when the queue is idle or waiting for decisions;
- starts with the orchestrator and stops gracefully on explicit Factory stop;
- never creates a Claude cron job; a legacy `/factory:tick` deletes itself on
  its next one-shot skill run before clearing `cronJobId`.

Worker launch failures stop the current fill loop and enter bounded exponential
backoff. Lower concurrency never terminates running workers.

Approved integration remains a one-shot `factory:tick` skill operation because
it can require test-command selection and conflict judgment. After that stage,
the skill returns capacity control to one native tick.

## Unified operator entry point

The root PowerShell scripts remain implementation and compatibility files. The
normal interface is:

```powershell
factory start [-New|-Resume|-Continue] [-Model name]
factory paths
factory config [path|edit]
factory scheduler [status|start|stop|tick]
factory tick
factory pause
factory resume
factory stop
factory purge [-Yes] [-Force]
```

`factory purge` is deliberately distinct from task-level `factory cleanup`.
It prints the exact private runtime and registered worktrees before doing
anything. `-Yes` confirms guarded project cleanup; `-Force` additionally allows
loss of dirty or unpublished worktrees.

## State and config

Config v5 adds `nativeScheduler` settings for enablement, automatic startup,
poll interval, and maximum backoff. State v4 adds the scheduler identity and
health record. Migration adds missing properties without overwriting private
per-project settings.

## Acceptance criteria

- Repeated startup reuses one scheduler process for a repository.
- The scheduler process does not keep the launching terminal or a captured
  PowerShell pipeline open.
- A native tick launches queued workers up to capacity without AI.
- Pause retains the process and artifacts; resume starts/ticks immediately;
  stop ends the exact scheduler process without stopping workers.
- Status and doctor report native scheduler health instead of Claude cron state.
- Tests verify startup, duplicate suppression, heartbeat, graceful stop,
  migration, and native worker launch in an isolated synthetic repository.
- No live project runtime, worker, worktree, or reviewed task is used by tests.
