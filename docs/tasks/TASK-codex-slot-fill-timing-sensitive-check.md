# Codex slot-fill elapsed-time check fails on the baseline

Date: 2026-10-23. Observed during direct ROCK regression checks.

## Confirmed observations

`tests/run-tests.ps1 -RuntimeOnly` reached the three-slot Codex launch test and
launched all three synthetic workers, then failed the 28-second assertion
(tests/run-tests.ps1:4160): 29.78 seconds. The message attributes that duration to
waiting for a detached descendant, but elapsed time alone does not prove it.

An isolated comparison using tests/rock-scheduler-compat.tests.ps1 ran the same
three-slot setup on the untouched source checkout and the ROCK worktree:

- Baseline 37aeca7f68d92ee0496f3c03a6ef0495ebd94cad: 3 launches, 28.781 seconds.
- ROCK worktree: 3 launches, 30.286 seconds.

Both exceeded the original threshold. The single-run difference is insufficient
to attribute an additional performance regression; no production malfunction is
established by these observations. The comparison test also checks that all three
recorded worker processes remain alive when the scheduler returns, rather than
inferring pipe waiting from elapsed time alone.

A subsequent isolated run with the process-liveness assertions enabled returned
all three workers alive in both cases: baseline 28.637 seconds, ROCK-disabled
branch 27.676 seconds. The comparison exited successfully and cleaned its fixtures
through native rejection. The baseline still exceeded the original 28-second
limit in that run, confirming that threshold is not a reliable pipe-wait diagnosis.

## Reproduction

From the ROCK worktree, with Windows PowerShell:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\rock-scheduler-compat.tests.ps1 -PluginRoot C:\Users\igerg\.codex\worktrees\rock-direct-memory\claude-factory-plugin -BaselinePluginRoot C:\laragon\www\Projects\claude-factory-plugin
```

This uses only temporary repositories and locally compiled FakeClaude/FakeCodex.
There are no live Factory task/session IDs. The long runtime fixture was
C:\tmp\claude-factory-plugin-tests-0f0c3325b600470abe305cacea9091c8; its own harness
performed normal fixture cleanup.

## Acceptance for a separate repair

- Separate slow setup/launch time from waiting for a finished descendant.
- Preserve the regression that three slots are filled in one tick and every
  worker is still alive after the tick; do not merely increase a timeout blindly.
- Exercise a deliberate inherited-pipe wait so the check still detects the bug.
- Repeat the comparison under a quiet and a busy host before attributing changes.
- Use only isolated fixtures and preserve all live runtime.

This diagnostic report does not authorize a separate repair.
