# Targeted workers, full local publication checks, asynchronous CI

The default verification policy is:

1. Workers add regression coverage and run targeted tests plus relevant lint or
   static analysis. Before reporting the final commit, they use native sync
   under the verify lease, release that lease, and rerun targeted checks on the
   synchronized commit. Explicit repository/operator requirements and concrete
   cross-cutting risks can still require a full suite under the verify lease.
2. `go` validates the exact approved commit and runs the configured full local
   integration checks. Release candidate checks remain enabled and run alongside
   integration checks when a production branch is configured. Failed local
   checks still prevent pushes. No review, SHA, database-isolation, or lease
   guard is removed.
3. After accepted pushes, GitHub Actions runs normally. Factory records each
   exact published candidate SHA and branch in `publication-ci.json` under the
   selected private project runtime. This journal survives task cleanup/archive.
   CI does not hold the test lane or delay the next task until it finishes.

No workflow file, deployment dependency, or skip/hotfix marker is changed.
`done` continues to mean that local publication and cleanup finished, not that
CI passed or deployment completed. Worker notes must describe actual targeted
coverage rather than imply a full-suite pass.

## Observation and failures

`factory status` shows a compact CI section; `factory ci` shows recent entries,
their published SHAs, branches, task titles, last observation, and run URLs.
The native scheduler's regular reconciliation and `factory wait` perform
rate-limited snapshots. There is no additional daemon and no `gh run watch`.
GitHub reads run outside task-state/journal write locks. Each `gh` call times out
after three seconds; each poll starts at most ten reads within an eight-second
budget (at most one call may finish beyond the budget).

The observer uses [GitHub's workflow-runs API](https://docs.github.com/en/rest/actions/workflow-runs)
through the locally authenticated `gh` executable. It requires Actions read
access. It filters by repository, exact SHA, branch, and `push` event, including
deployment workflows triggered by that push. Local and non-GitHub remotes are
not monitored. No run is created, cancelled, rerun, or otherwise changed.

Pending/running or not-yet-visible CI does **not** block publication. Known
`failure`, `timed_out`, `action_required`, or `startup_failure` outcomes block
further pushes and leave not-yet-started approvals queued. Workers can continue.
The gate is checked before candidate preparation and again before each push;
it is not an atomic guarantee against a remote failure occurring after the
last snapshot. CI failures trigger the existing attention journal once per
unchanged issue, including when the associated task has already been cleaned.

A successful rerun of the same failed run, on that exact SHA, clears its
failure. A different SHA/workflow success, a pending/cancelled rerun, or an API
error cannot clear known red evidence. Older API attempts cannot roll back
the recorded attempt or reuse an acknowledgement of an earlier failure.
An entirely skipped set, cancelled runs, or neutral results are unverified,
not green. When at least one workflow succeeds and its only companions are
skipped workflows, the aggregate passes and detail output explicitly counts
the skips. This covers repositories where standalone CI stands aside because
the deploy workflow invokes CI. A passed workflow is not a claim that every
optional job/test ran. Authentication errors, timeouts, and truncated snapshots
(more than 100 matching runs), missing known runs, or stale attempts remain
unverified and visible; they do not create
a new failure block, but preserve existing ones. An unreadable/corrupt journal
blocks publications instead of resetting history.

Snapshots are at most every 30 seconds per unresolved entry; successful or
otherwise terminal unverified entries are checked every five minutes. Monitoring
covers the last seven days; unacknowledged failures are retained and polled
beyond that window. History is not automatically deleted. Runs started/rerun
outside that window on an already successful SHA are not monitored.

## Explicit recovery

Inspect the failing run first. A successful rerun clears the block automatically.
If the operator decides to proceed despite the failure (for example, to publish
a repair), use the **published candidate SHA shown by `factory ci`**, not the
worker SHA:

```powershell
factory ci acknowledge <full-published-sha> "Failure investigated; authorize publication of the repair"
```

This audits the operator's reason and accepts only the currently recorded failed
run attempts for that SHA. It does not change the workflow or label CI green.
A new failed attempt blocks again. It is not a general bypass of local tests,
review, or publication validation. The orchestrator must not acknowledge a
failure without explicit operator authorization. Other known failures remain
blocking; an acknowledged failure is still displayed as failed.

If CI becomes red during local candidate checks, approval is preserved but the
checks may run again when the gate opens. If development was already pushed
before a failure blocks production, Factory retains a partial-publication
blocker for explicit review/recovery; it does not pretend nothing was pushed.

## Rollout

No task-state schema migration or runtime move is needed. Old configs default
to monitoring future GitHub publications. `ciMonitoring.enabled: false` opts
out of registering new pushes, but does not erase existing evidence or bypass
known failures. Previously published tasks are not automatically backfilled.

Existing native schedulers load the updated reconciliation and integration
scripts on subsequent calls, so no restart is required for those paths. Already
running integration processes finish using their loaded code. New worker
sessions receive the targeted policy; already-running workers may retain the
old instructions. Reload/restart an idle orchestrator when convenient to refresh
its protocol; do not interrupt active work merely to change test policy.

Review existing `workerRequiredChecks` before rollout. A private instruction
explicitly requiring every worker to run a full suite remains authoritative;
the plugin does not silently rewrite it. Replace that instruction with targeted
coverage when opting that project into this policy. Preserve any required full
suite command/process limit for explicitly requested or risk-justified runs,
and leave `integrationTestCommands` / `releaseTestCommands` unchanged.

Synthetic checks: `powershell -NoProfile -File tests/publication-ci.tests.ps1`.
Native local Git publication/CI-gate E2E:
`powershell -NoProfile -File tests/publication-ci-pipeline.tests.ps1`.

### Verification on 2026-09-25

- CI observer: 54 assertions passed, including run identity, pending/failed
  outcomes, reruns, stale attempts, acknowledgements, concurrent registration,
  attention deduplication, bounded reads, corruption, and skipped companions.
- Native pipeline E2E passed: pending CI permits publication and cleanup; known
  failure prevents a push and preserves approval; explicit acknowledgement
  permits a repair; a failure injected during local checks is caught before
  push and releases the lease. All pushes used temporary local bare repos.
- Existing `factory-status.tests.ps1` passed. PowerShell parsing, manifest paths,
  and `git diff --check` passed.
- A read-only GitHub smoke check read two workflows for MotiveHR's then-current
  `origin/develop` SHA: one running and one skipped. It wrote no runtime data.
- The full `run-tests.ps1 -RuntimeOnly` run reached the previously documented
  three-Codex-slot timing assertion: all three launches returned, but took
  24.189 seconds against its 20-second limit. The suite is not fully green;
  that threshold was not weakened. Earlier baseline reproduction is recorded
  in [worker environment verification](WORKER-ENV-GUARD-VERIFICATION-2026-09-22.md).
- The generic Codex skill validator parsed the canonical skill's YAML but
  rejects its existing Claude-only `argument-hint` and
  `disable-model-invocation` fields. Those fields were preserved; protocol
  contract checks in the runtime harness passed.
