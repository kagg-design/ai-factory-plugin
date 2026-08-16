# Native direct approval

## Goal

Allow an operator to send a small, already-understood worker result into the
native publication pipeline without paying for a separate AI code-review turn,
while retaining every deterministic Git and integration safeguard.

## Delivered behavior

- `factory go <task-id> --direct` and `!factory go <task-id> --direct` skip the
  independent AI review by explicit operator request.
- The command accepts only an `awaiting-review` or held task with an exact
  validated worker commit, an idle clean worker worktree, at least one passed
  worker check, and no failed worker checks.
- The task commit must remain a single commit based on the current configured
  remote development tip. A stale task is sent through the existing sync path.
- Integration and release commands come only from private project config or
  previously resolved trusted review state. Direct approval never executes a
  command merely because task text or the worker result reported it.
- Native code records an `operator-direct` review and approval, pins the exact
  SHA and hashed immutable integration plan, then wakes the unchanged native
  scheduler pipeline.
- A `changes-required` or `blocked` review for the same commit cannot be
  overridden through direct approval.
- Status shows direct approval as an alternative only when no known negative
  review exists. Inspect output distinguishes a skipped review and its approval
  mode from an independently reviewed task.

## Trust boundary

The operator owns the decision to skip independent code judgment. Native code
owns task eligibility, worker-result validation, worktree and branch checks,
remote-base pinning, trusted command resolution, plan hashing, state mutation,
and scheduler wakeup. The existing integrator still merges the immutable SHA,
runs isolated checks, pushes without force, verifies both remote branches, and
performs guarded cleanup.

## Verification

The synthetic end-to-end suite proves that direct approval cannot override a
known `changes-required` review, then directly approves a clean fixture using
previously resolved trusted checks. It verifies review and approval audit
modes, the 64-character plan hash, full development and production publication,
remote reachability, and guarded cleanup through the existing native pipeline.
