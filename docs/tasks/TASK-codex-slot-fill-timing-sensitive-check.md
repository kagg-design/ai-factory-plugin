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

## Repair

Igor authorized repair in the Factory development chat on 2026-10-23.
FakeCodex workers now wait on a test-owned release file, independently of cold
startup time (with a four-minute containment ceiling). The slot-fill test keeps
the three-launch and three-live-process assertions. Elapsed time is diagnostic.
A test-only capture helper separately bounds process exit and pipe completion;
it identifies a pipe held after the launcher has exited.

The negative control changes `bInheritHandles` to true in both launcher boundaries
of a disposable plugin copy. It failed with `SLOT_FILL_INHERITED_PIPE`, as required,
then released and natively rejected its fake workers. The production launchers
are unchanged. The full entrypoint includes this negative control.

Positive comparison with the controlled worker fixture passed on both roots:
baseline 30.667 seconds, ROCK branch 30.361 seconds, three live workers each.
A further branch run alongside the full suite passed in 31.528 seconds. These
are observations of host-dependent setup time, not a performance benchmark.

Focused checks:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\rock-scheduler-compat.tests.ps1 -PluginRoot <checkout>
powershell -NoProfile -ExecutionPolicy Bypass -File tests\rock-scheduler-compat.tests.ps1 -PluginRoot <checkout> -InjectInheritedPipe
```

The second command succeeds only when the deliberately broken copy is detected
with the specific inherited-pipe diagnostic. Other failures are not accepted as
proof that the regression check works.

The first full run passed the repaired slot-fill gate (30.525 seconds, all three
workers alive) and then exposed another fixture assumption at rejection: the
shared FakeCodex log was expected to contain exactly one deletion globally.
Fake workers reuse the same thread UUID; releasing the controlled slot workers
before native cleanup can now legitimately add prior deletions. The rejection
check now snapshots the count around the exact operation and requires a delta
of one, retaining detection of missing or duplicate deletion.

After this correction, `tests/run-tests.ps1 -RuntimeOnly` passed to exit code 0:
`All factory runtime tests passed.` The slot-fill check again returned three live
workers (29.893 seconds). The full entrypoint's preceding 22 standalone suites
had already passed, including the ledger repair and inherited-pipe negative
control. No single uninterrupted full rerun is claimed after the final assertion
correction; its complete runtime portion was rerun successfully.
