---
name: tick
description: Migrate a legacy Claude cron tick and hand control to the native Factory scheduler.
argument-hint: ""
user-invocable: true
allowed-tools:
  - Read
  - PowerShell
  - CronList
  - CronDelete
---

This is a compatibility shim for installations that still have a saved
`/factory:tick` Claude cron job. It must never review code, select test commands,
merge a branch, resolve a conflict, push, or launch a worker itself.

Load private context with `project-context.ps1 -Initialize`, then read state. If
`cronJobId` is non-empty, use `CronList`, delete only that exact job when its
prompt is `/factory:tick`, and clear `cronJobId` atomically. Never create a
replacement Claude cron job.

Then hand the single cycle to deterministic code:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/factory-scheduler.ps1" -Action tick -Repository "${CLAUDE_PROJECT_DIR}"
```

The native scheduler owns reconciliation, formally approved exact-SHA
integration, isolated checks, non-force publication, guarded cleanup, capacity,
backoff, and idle sleeping. Report only a compact error or transition summary;
finish silently when nothing changed.
