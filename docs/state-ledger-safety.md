# State ledger overwrite regression

## Reproduction

Baseline: `b495246756c9da193eabf919af44854e1cafed68`, Windows PowerShell 5.1,
11 September 2026 UTC (12 September in Riga).

Before changing production code, this command ran a mutex-protected atomic
writer in one process while another repeatedly initialized the same disposable
project, using unmodified `File.Replace` and initialization code:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests/run-tests.ps1 -LedgerOnly -NativeLedgerRace
```

Observed failure, exit code 1:

```text
LEDGER RACE: Initialize replaced 6 tasks with 0; createdAt=null; iteration=116.
```

The default ledger test also forces the missing-path interleaving in a
temporary copy of the two scripts. It moves the target aside while the writer
owns the mutex and delays the initializer after its real missing-file check
until replacement finishes. It does not mock the existence result. Before the
fix, this failed with the same fingerprints at iteration 0. After the fix,
initialization waits for the writer and preserves all six tasks. This makes the
regression deterministic without adding fault-injection hooks to production.

The unmodified stress workload after the fix passed 250 initializations
overlapping 525 atomic writes, and a repeat passed with 527 writes. The default test additionally covers missing task
property backfill, idempotence, unlocked-write refusal, undeclared and partially
declared removal refusal, refusal logging, exact previous-version recovery,
real `reject-task` removal (including case-insensitive task lookup), a missing
ledger with an existing recovery copy, and retained orphaned recovery documents.

## Write boundary

Initialization creates runtime directories first, then holds the same project
mutex as all other ledger writers across config migration, the missing-state
decision, creation, and task-property migration. Creation uses the atomic
writer's non-overwriting move. An unchanged ledger is not rewritten.

`Write-FactoryJsonAtomic` recognizes `state.json` and checks that the current
thread holds its project mutex. Ownership is counted across nested acquisitions
and repeated loading of the common helpers. A serialized, parsed replacement
is compared with the current on-disk task IDs while that mutex is held. Missing
IDs require exact declarations through `-RemovedTaskIds`; production uses that
parameter only for the task selected by `reject-task.ps1`. Cleanup retains the
task ID and needs no exception.

Refusals throw and append a `state-write-refused` record, including caller,
PID, and the reason, to the project's `scheduler.stderr.log`. Neither the
ledger nor its backup is replaced on a refused write.

## Recovery copy

Retention is one preceding version at:

```text
<projectData>/state.json.previous.bak
```

Each successful replacement retains the previous on-disk document through
`File.Replace`. Initial creation also makes a recovery copy of that first
version. Idempotent initialization and refused writes leave the backup intact.
If the ledger is missing but this backup exists, initialization refuses to
create a blank ledger and reports the recovery path.

Recover by copying the inspected backup to `state.json` while all project
writers are stopped, preserving another copy of the damaged ledger first.
There is no automatic recovery, runtime migration, or orphan cleanup.
Existing GUID-named `.tmp`/`.bak` files and `state.json.pre-reboot-fix.bak` are
never scanned, rotated, or deleted by this change.

## Heartbeats and lock measurements

High-frequency heartbeats write only `scheduler-heartbeat.json`, at most once
per second during child work. They take no ledger mutex and do not read or
rewrite the ledger on each polling pass. Scheduler status overlays the heartbeat
only when PID, process start time, activity, and activity start time match the
durable scheduler record; stale or unreadable telemetry does not change process
identity. Tick results, lifecycle changes, and active/paused control retain
their existing durable state behavior. Doctor's diagnostic meaning is unchanged.

Measured using the real native scheduler with fake workers and a 15-second tick
interval in isolated runtimes. All holds of at least 1 ms were journaled:

| Workload | State-lock holds | Observation |
| --- | ---: | --- |
| Baseline busy child, 60 seconds | 195/min | All attributed to `factory-scheduler.ps1:148` |
| Fixed normal ticks, 60 seconds | 15-16/min | 9-10 scheduler, 3 initialization, 3 reconciliation |
| Fixed busy child, 15 seconds | 0 | Ledger bytes unchanged; heartbeat advances |

The default journal threshold is also corrected: an unset environment override
now preserves the intended 1,000 ms threshold instead of accidentally setting
it to 1 ms. Normal short holds therefore do not grow the production journal.
The checked-in measurement test records its observation window and results in
the disposable runtime and fails above 25 state-lock holds per minute.

Running scheduler processes load these changes on their next normal restart.
No live runtime was recovered, migrated, cleaned, or restarted during this work.

## Verification commands

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests/run-tests.ps1 -LedgerOnly
powershell -NoProfile -ExecutionPolicy Bypass -File tests/run-tests.ps1 -LedgerOnly -NativeLedgerRace
powershell -NoProfile -ExecutionPolicy Bypass -File tests/run-tests.ps1 -KeepTemp
git diff --check
```

The full harness retains its existing worker, sync, review, publication,
cleanup, reject, lease, and doctor checks. Ledger fixtures and measurement logs
remain under the OS temporary directory for inspection; they never target the
live factory runtime.

Completed verification: the full harness returned exit code 0 with
`All factory runtime tests passed.` Both focused ledger modes passed, and
`git diff --check` and PowerShell parsing checks passed.
