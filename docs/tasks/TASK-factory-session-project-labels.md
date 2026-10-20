# TASK — identify every Factory session by its factory label

Reported: 2026-10-20, 17:14 Europe/Riga.

## Problem

The operator requested that sessions belonging to different factories be
distinguishable at a glance in Claude Agent View. The implementation labels
orchestrators, but not their workers. Restarting an orchestrator cannot fix
the worker naming function, including names generated for new workers.

This is a confirmed gap in the requested session identification behavior.
It is not caused by the operator omitting a restart.

## Evidence

Commit `0fe217fa868b17cbdad0828a1d3b613d31a16694` added per-project
orchestrator names. `scripts/orchestrator-name.ps1` resolves
`orchestrator.name` and formats `Factory · <alias>`.

`scripts/factory-common.ps1:1595`, `Get-FactoryWorkerSessionName`, accepts
only `TaskId` and `Title`. It returns `factory-<task-id>-<title>` or
`factory-local-<nonce>-<title>`, without a repository or factory label.
`scripts/start-worker-session.ps1:102` invokes that function without project
configuration or context. `tests/orchestrator-name.tests.ps1` covers
orchestrators only; the local intake tests explicitly expect unlabelled
worker names.

Read-only `claude agents --json --all` on 2026-10-20 confirmed:

| Background ID | Name | Ownership evidence |
| --- | --- | --- |
| `4323670e` | `Factory · AwesomeHR` | cwd `C:\laragon\www\motivehr` |
| `a29bf31f` | `Factory · Auditors` | cwd `C:\laragon\www\Projects\cloud-infrastructure-auditors` |
| `faf4e327` | `factory-local-c068b7ec-task-access-sync-002-partial` | cwd under `C:\laragon\www\.claude-factory-worktrees\motivehr-4893d8fb\worker-local-20261020-113041-c068b7ec-1917c969c0c2-a1` |
| `d40811f8` | `factory-1219601066590603-access-zenhub-connector` | cwd under `C:\laragon\www\.claude-factory-worktrees\motivehr-4893d8fb\worker-1219601066590603-a1` |

Both workers belong to AwesomeHR. The screenshot places the two factories
and their workers in one list, with no visible factory association on the
worker rows. Their cwd provides diagnostic evidence but is not displayed
as part of the session name in that view.

`docs/dev/FACTORY-OPERATIONS.md` describes applying a changed orchestrator
label through `factory restart`. That behavior concerns the orchestrator's
stored conversation; it does not add a factory label to worker names.

## Reproduction

1. Configure two repositories with different `orchestrator.name` values,
   for example `AwesomeHR` and `Auditors`.
2. Start both factories and launch local and Asana workers.
3. Open Claude Agent View.
4. Observe labelled orchestrators alongside generic `factory-...` workers.
5. Inspect the worker name generation path: restarting the factory still
   generates the same worker names without a factory label.

## Expected behavior (operator clarification, 2026-10-20)

Every Factory-owned session should visibly identify its factory before the
task-specific suffix. The operator explicitly requested the shorter format
below. `Factory` alone identifies the orchestrator; workers start directly
with the factory alias, without `Factory`, `worker`, or `orchestrator` words.
Use the same configured alias and stable repository-derived fallback for
orchestrators and workers:

```text
Factory AwesomeHR
AwesomeHR · c068b7ec · access-sync
Factory Auditors
Auditors · <task-id> · <title>
```

The final format must account for the native display/name length limit:
preserve factory ownership and a useful task identity, shortening the title
first. Verify Claude and Codex session naming paths, rather than changing
only one launcher.

## Existing sessions and safety

Investigate supported native rename behavior separately from launch-time
naming. Do not edit Claude private session registries or Factory state JSON
to change labels. Do not stop, remove, respawn, or resume a live production
session merely to apply a display label. If changing an existing row needs
a session transition, document its exact safe procedure and limits; do not
claim that restarting the orchestrator migrates worker labels automatically.

Keep matching and cleanup compatible with older worker names. Use verified
session identities and repository/worktree ownership so changing the display
format cannot remove another factory's sessions. Retain transcripts, task
state, worktrees, commits, attention delivery, and review/merge gates.

## Acceptance checks

- In one mixed Agent View list, the factory and role of each new session
  are apparent from its name, for two explicitly named factories and two
  factories using repository-derived fallback names.
- Both local and Asana task workers carry the correct factory label.
- Long aliases and titles retain the ownership label and task identity
  within the supported name length. Existing Unicode title behavior remains
  supported.
- Claude and Codex launch paths use the same ownership convention.
- Retry, answer, rework, resume, reconciliation, and cleanup continue to
  resolve the exact task session, including legacy unlabelled rows.
- Tests cover mixed factories, legacy names, and unrelated interactive
  sessions. No test starts or renames a live production session.
- Document whether and how existing labels can be updated, with a clear
  distinction between orchestrator restart and worker lifecycle changes.
- No live factory runtime state or working session is changed while
  implementing or validating the source fix.

## Implementation outcome (2026-10-20)

- Both runtimes now name orchestrators `Factory <alias>` and workers
  `<alias> · <task-id> · <title>`, using the same configured or derived alias.
  Local tasks use the eight-character task code. Normal Asana GIDs stay whole,
  even with a maximum-length alias. Titles are shortened before identities.
- Claude launches receive the name through `--name`. Codex app-backed
  orchestrators receive the same native title; new exec workers are named by
  their detached helper after observing the exact emitted thread ID. The API
  update verifies the thread and does not start a turn. Name failures remain
  separate from worker results and appear in inspection as a warning.
  Neither the detached helper nor its metadata API process holds the worker
  directory as its cwd, so naming can finish concurrently with worktree cleanup.
- Discovery accepts both old orchestrator formats. A stopped conversation
  needing a new label goes through transcript verification, removal of its
  exact Agent View row, and UUID-checked resume. Pending old-format launch
  receipts are recovered without dispatching a second launch.
- Worker reconciliation still uses recorded identity before name/path
  fallback. Cleanup supports old/new labels and earlier canonical attempt
  paths inside the same project worktree root. A matching task ID or display
  name in another factory is insufficient authority to stop its session.
- The operations guide and canonical protocol describe existing-session
  migration. Running Claude workers keep their current names until their
  normal lifecycle launches another attempt; an orchestrator restart does
  not relaunch workers.

Validation uses fake executables, isolated temporary repositories, and
in-memory session rows. No live factory was restarted, renamed, reconciled,
or cleaned up by implementation or validation commands. Those commands did
not modify live queues, worktrees, transcripts, or runtime files.

Targeted naming, Claude lifecycle, Codex startup/snapshot, local intake, and
status regressions passed. The runtime harness's culture/lease test was
corrected to compare the observed age against each call's actual wall-clock
interval: its previous two-second cross-call limit failed when child process
startup took longer. The asynchronous enqueue fixture now uses a bounded
30-second deadline and reports the actual task status/error on failure,
instead of assuming scheduler wakeup always completes within five seconds.
The full `tests/run-tests.ps1 -RuntimeOnly -KeepTemp` run passed, including
enqueue/wakeup, retry/answer/rework, cleanup/reject, publication, Codex startup,
rotation, and worker lifecycle checks. PowerShell parsing and
`git diff --check` also passed.
