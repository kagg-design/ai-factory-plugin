# TASK: Isolate test databases across factory worktrees

## Problem

Factory workers have separate Git worktrees but inherit byte-identical ignored
environment files. A project whose test runner names one persistent database can
therefore run migrations, truncation, and database tests from several workers
against the same database. File isolation does not prevent cross-worker test
failures or destructive interference.

The live MotiveHR inspection on 2026-08-16 confirmed the issue:

- `.env.testing` was absent;
- the primary checkout, integrator, and current worker had identical database
  connection settings in their copied `.env` files;
- `phpunit.xml` selected PostgreSQL database `motivehr_test`;
- many tests use Laravel `RefreshDatabase`;
- factory concurrency was greater than one.

No secret value was printed or persisted during the inspection. The configured
PostgreSQL role reported `CREATEDB` capability.

## Required behavior

1. Isolation is opt-in and configured only in private per-repository config.
2. The first worker launch creates a deterministic database derived from a safe
   configured prefix and task ID.
3. The database variable is added to the Claude worker process environment, so
   every test command spawned by that worker inherits it without repository
   changes.
4. Retry and answer reuse the same task database; hold preserves it.
5. Confirmed rejection and published-work cleanup stop every task process before
   dropping the exact task database and before removing Git artifacts.
6. A stop or database-drop failure leaves the worktree, branch, and task state
   intact for retry.
7. Integration and release commands use separate fixed database namespaces and
   cannot collide with workers.
8. Passwords are supplied to the PostgreSQL client through process environment,
   never command arguments, state, task payload, or logs.
9. Disabled isolation preserves existing behavior for non-PostgreSQL projects.

## Configuration

Minimal private configuration:

```json
{
  "testDatabaseIsolation": {
    "enabled": true,
    "provider": "postgresql",
    "databasePrefix": "project_test"
  }
}
```

The default object also supports custom connection file, environment-variable
names, maintenance database, and PostgreSQL client command. The role must have
`CREATEDB`. PostgreSQL 13 or newer is required for forced disconnect and drop.

## Acceptance checks

- Two different task IDs resolve to two different valid PostgreSQL identifiers.
- The database name never exceeds PostgreSQL's 63-byte ASCII identifier limit.
- A worker receives only its own database through its launch environment,
  including every agent-resolution fallback.
- Repeated launch initializes a task database idempotently.
- A terminal-looking live session is stopped before the database is dropped.
- A stop failure drops neither database nor Git artifacts.
- Cleanup and confirmed rejection drop the correct database exactly once.
- The integration command wrapper exposes the integrator database only to the
  wrapped command.
- Existing runtime, fallback, Agent View, Git safety, and transcript tests pass.

## Implementation outcome

Configuration schema v4 adds `testDatabaseIsolation`, disabled by default.
Shared helpers in `scripts/factory-common.ps1` validate names and paths, read the
ignored connection environment, invoke `psql` without command-line credentials,
create databases idempotently, and force-drop only an exactly derived owned
database.

`start-worker-session.ps1` records the task database and passes it through all
worker launch resolution paths. `cleanup-task.ps1` and `reject-task.ps1` remove
it after session shutdown. `run-isolated-test-command.ps1` provides scoped
integrator and release execution, and the tick skill requires that wrapper for
every configured or inferred command.

The fake PostgreSQL regression fixture tests creation, inheritance, namespace
separation, ordering, and removal without connecting to a real database.

## Verification

- All PowerShell scripts parsed successfully under Windows PowerShell 5.1.
- `tests/run-tests.ps1` passed with the fake PostgreSQL lifecycle, worker
  environment capture, cleanup/rejection ordering, integrator wrapper, doctor
  prerequisites, and all pre-existing factory runtime coverage.
- The private MotiveHR config migrated to v4 and enabled isolation with prefix
  `motivehr_test`; the file remains ignored under `runtime/`.
- A real PostgreSQL smoke test created and removed only
  `motivehr_test_worker_factory_isolation_probe_20260816`. A final query
  confirmed the probe database is absent and the existing shared
  `motivehr_test` database remains present.
- One MotiveHR planning session was already running before isolation was
  enabled. Its parent process cannot receive a new environment retroactively;
  future launches and retries use isolated databases.
