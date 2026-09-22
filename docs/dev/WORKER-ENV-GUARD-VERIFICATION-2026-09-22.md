# Worker environment guard verification — 2026-09-22

Implements `CODEX-FACTORY-WORKER-ENV-002` against baseline `86de536`.

## Behavior

- Worker ownership comes from the Git branch, canonical worktree, and ledger.
- An absent/empty process database variable is allowed. A present foreign
  database or task ID is still refused, as is an incorrect ledger database.
- An inherited `CLAUDE_FACTORY_PROMPT_PATH` no longer decides authorization.
- Visible `artisan test`, `phpunit`, and `paratest` invocations must explicitly
  pin the configured database variable to the assigned database. Ordinary file
  reads, Git inspection, and lint commands do not need a database assignment.
- Refusals distinguish ledger/process/command values, quote expected and actual
  values, and include guard and parent PIDs where the OS permits inspection.
- Existing Git restrictions and fail-closed behavior remain enabled. No product
  environment file, PHPUnit configuration, or daemon database pin was changed.
- The optional `hold blocked` state transition was not included in this fix.

## Automated tests

`tests/worker-environment-guard.tests.ps1` passed 63 real hook subprocess probes
in Windows PowerShell 5.1. Coverage includes empty/foreign environments,
corrupted ledger assignments, stale prompt paths, foreign task IDs, explicit
Bash/PowerShell pins, misleading comments/strings/heredocs, nested shell
commands, multiple test invocations, custom database variables, missing ledger
ownership, disabled isolation, and preservation of the Git push restriction.

`tests/parallel-safety.tests.ps1` passed, including overlapping detached fake
workers, Composer fallback, result diagnostics, and the durable exclusive test
lease. Syntax checks, bundle-manifest checks, and `git diff --check` passed.

The larger `tests/run-tests.ps1 -RuntimeOnly -KeepTemp` run did **not** finish:
its existing three-slot Codex scheduling timing assertion requires less than
20 seconds and observed 21.52 seconds. A focused repeat launched three workers
in 22.12 seconds, with all three still alive. An unmodified `86de536` archive
also exceeded the same threshold (20.67 seconds; all three workers alive).
The threshold was not weakened and the unrelated scheduler code was not changed.

## Live cross-session E2E

The operator explicitly approved recycling the shared Claude daemon. Existing
MotiveHR background sessions were restored with their original conversation
IDs. Subsequent harness retries used the already recycled daemon without
interrupting newly active user sessions.

The final successful run used Claude Code 2.1.278, real daemon-hosted background
sessions, the plugin's actual hooks, an isolated fixture ledger, two disposable
Git worktrees, and two newly created PostgreSQL databases. These were probe
sessions, not re-runs of the user's blocked business task. The script did not
exercise Asana intake or publication.

| Session | Worktree | Tool calls | Refusals/errors | Database identity assertion |
| --- | --- | ---: | ---: | --- |
| `0bec7d0b` | one, round 1 | 2 | 0 | passed |
| `438ba4ce` | two, round 1 | 2 | 0 | passed |
| `52fb0f14` | one, round 2 | 2 | 0 | passed |
| `362bfd00` | two, round 2 | 2 | 0 | passed |

Every session first read its worktree with an empty process database variable,
then ran a real PHPUnit test with an explicit inline database assignment. The
test asserted both `getenv('DB_DATABASE')` and PostgreSQL's
`SELECT current_database()` against its assigned database:

- one: `factory_env_d2368b862ddf_worker_one`
- two: `factory_env_d2368b862ddf_worker_two`

Both worktree sessions were observed alive concurrently. Each suite passed one
test with two assertions. The test sessions were stopped and removed from Agent
View, and only their newly created databases were dropped afterwards. Fixture
files and transcripts remain available for audit.

The machine-readable successful report is retained locally at
`C:\Users\igerg\AppData\Local\Temp\factory-worker-live-eaf6bc7a56114807ba3a1ec3092cffd3\report.json`.
Earlier harness attempts exposed test-only issues with PowerShell 5 JSON arrays,
Claude's variadic `--tools` argument, and distinguishing empty from unset shell
variables; those were corrected before this successful run.

`TASK-MANUAL-001` (`local:20260922-102914-1c0d5688`) remains `blocked`, attempt 5.
No rework/retry or application implementation was started. MotiveHR source,
configuration, and task assignment were not edited.

## Activation

The existing hook starts a new PowerShell process per shell call and reads the
updated plugin files. A factory restart is not needed to activate this guard
fix in an already loaded plugin session. New worker sessions receive the updated
written worker protocol; existing blocked tasks still need an explicit operator
decision to continue/rework them.
