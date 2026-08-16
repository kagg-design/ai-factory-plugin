# Native integration pipeline — phase 4

## Goal

Remove AI interpretation from the execution of an already reviewed Factory
commit while preserving AI judgment for code review and test selection.

## Delivered behavior

- `/factory review <id>` writes a validated private review decision for one
  full Git SHA.
- An approved review pins the development and production tips, publication
  mode, trusted integration and release commands, and a SHA-256 plan hash.
- `factory go <id>` validates that review, clean worker checkout, commit, and
  plan hash, records immutable approval, and starts the native scheduler.
- One scheduler tick integrates at most one approved task before filling worker
  capacity.
- `factory-integrator` and `factory-release` are reusable detached worktrees;
  the user's main checkout is never reset or merged.
- Every configured command runs through the isolated test wrapper.
- Development and production use explicit `HEAD:<branch>` non-force pushes and
  post-push reachability checks.
- A moved reviewed base, worker mutation, invalid plan, merge conflict, failed
  check, or rejected push stops the pipeline and records an actionable error.
- Production rebuilds and retests up to three times when its tested inputs race.
- Cleanup runs only after both remote branches contain the approved task SHA.

## Trust boundary

AI still performs requirement analysis, implementation, conflict-aware sync,
code review, risk assessment, and trusted test-command selection. Native code
performs only the pre-authorized plan. It does not invent commands, edit source,
resolve conflicts, force-push, or broaden publication scope.

## Verification

The synthetic test suite creates local bare development/production remotes,
records an approved review, issues exact-SHA approval, lets the native scheduler
perform both publication stages, verifies remote ancestry and audit state, and
confirms guarded worker cleanup.
