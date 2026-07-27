# TASK: state.json grows without bound and kills the factory (encoding round-trip)

Status: **blocker**. Reproduced on 2026-07-27 against repository `C:\laragon\www\motivehr`
(project key `motivehr-4893d8fb`). The factory could not run at all until the state file was
repaired by hand.

## Symptom

`runtime/projects/<key>/state.json` grew to **483 MB** with only four queued tasks. Every
factory command then failed:

```
Get-Content : Exception of type 'System.OutOfMemoryException' was thrown.
At C:\laragon\www\Projects\claude-factory-plugin\scripts\factory-common.ps1:20 char:9
+         Get-Content -LiteralPath $temporaryPath -Raw | ConvertFrom-Js ...
```

Inside the file, one task's `plan.understanding` field alone occupied ~222 MB. Its content
starts as clean readable text and degenerates exactly where the worker's Russian prose began:

```
"understanding": "Asana 1216463560157756 (Angela Meeker ...) was reopened on 2026-07-24: the
/pto/calendar iCal Feeds modal hands out the SAME Who\u0027s Out URL ... ignores the page
filters entirely A��'A+�?TA
   ... 222 MB of  A�A�A��,���A,A�A��?�A,A�A��'A+�?TA�A�A��?sA�A.A�A��'A��,���A��?sA,A� ...
```

## Root cause

The read and write sides of the JSON helpers use **different encodings**, so every state
rewrite re-corrupts and multiplies every non-ASCII character.

Environment (verified):

```
PSVersion               5.1.26100.8875
[Text.Encoding]::Default  Windows-1252
ANSI code page            1252
```

- **Write** — `scripts/factory-common.ps1:16-17` writes UTF-8 **without BOM**:
  ```powershell
  $utf8 = New-Object System.Text.UTF8Encoding($false)
  [IO.File]::WriteAllText($temporaryPath, $json + [Environment]::NewLine, $utf8)
  ```
- **Read** — every reader omits `-Encoding`, e.g. `scripts/reconcile-worker-sessions.ps1:36`:
  ```powershell
  $state = Get-Content -LiteralPath $context.statePath -Raw | ConvertFrom-Json
  ```
  In PowerShell 5.1 `Get-Content` defaults to the ANSI code page (1252), and because the file
  carries **no BOM** there is no hint to override that default.

So each cycle is: UTF-8 bytes → read as cp1252 (one 2-byte character becomes two characters)
→ written back as UTF-8 (each of those becomes 2 bytes) → read again as cp1252 (now four
characters) → ... Character count roughly doubles-to-triples per write.

Measured on the live project, starting from a repaired 69 KB state and running only
`reconcile-worker-sessions.ps1`:

| after reconcile | non-ASCII chars | file size |
| --- | --- | --- |
| 1 | 1 174 | 65 132 B |
| 2 | 1 937 | 66 782 B |
| 3 | 5 695 | 75 269 B |

With the scheduler at `*/2 * * * *` this reaches hundreds of megabytes in well under an hour.

Why `plan` was the field that exploded: `reconcile-worker-sessions.ps1` refreshes
`backgroundSession.lastAssistantMessage` from `events/<task>/latest.json` on every pass, so that
field is overwritten with clean bytes each time. `task.plan` is only assigned while the task is
in `starting|planning|running` (line ~83-96); once a task sits in `awaiting-input` the stale
plan is merely re-serialised on every write, so it is the value that accumulates. The task that
entered `awaiting-input` earliest was the largest.

## Required fix

Make every JSON read explicitly UTF-8. Do not rely on `Get-Content` defaults anywhere.

Suggested shape — one helper in `scripts/factory-common.ps1`, used by all call sites:

```powershell
function Read-FactoryJson {
    param([Parameter(Mandatory = $true)][string]$Path)

    $utf8 = New-Object System.Text.UTF8Encoding($false)
    return [IO.File]::ReadAllText($Path, $utf8) | ConvertFrom-Json
}
```

`[IO.File]::ReadAllText` with an explicit UTF8Encoding is preferred over
`Get-Content -Encoding UTF8` because it behaves identically on PowerShell 5.1 and 7+ and does
not depend on BOM detection.

Call sites to convert (all currently missing `-Encoding`):

- `scripts/factory-common.ps1:20` — the atomic-write verification read
- `scripts/reconcile-worker-sessions.ps1:36, 94, 104, 124`
- `scripts/project-context.ps1:59, 60, 69, 70`
- `scripts/start-worker-session.ps1:21, 35, 279, 316`
- `scripts/capture-worker-stop.ps1:18, 105`
- `scripts/task-action.ps1:16`
- `scripts/factory-doctor.ps1:9, 10, 37`
- `scripts/set-concurrency.ps1:14`
- `scripts/create-worktree.ps1:10`
- `tests/run-tests.ps1:27, 30, 97, 98, 101, 108, 159, 168, 176, 226, 238`

Belt-and-braces option worth considering on top of the encoding fix: escape non-ASCII to
`\uXXXX` before writing, so the state file is pure ASCII and any future encoding mismatch is a
no-op rather than data loss. PowerShell 5.1's `ConvertTo-Json` does not do this by itself.

## Secondary bugs found in the same session

Both are independent of the encoding issue and worth fixing while you are in these files.

### 1. Background session ID is parsed with ANSI colour codes glued on

`scripts/start-worker-session.ps1:258-267` regexes the launch output for the background ID.
The output contains ANSI colour escapes, and `ESC[36m` leaks into the capture group:

| actual session ID | value stored in state |
| --- | --- |
| `d69d4ba6` | `36md69d4ba6` |
| `44a42f51` | `36m44a42f51` |
| `cac3431a` | `36mcac3431a` |

Consequence: `attachCommand` is unusable, and `reconcile-worker-sessions.ps1:44-51` can never
match the session row (it matches on `id`, and `sessionId` is still null at that point), so no
session-state transition is ever applied to that task. Three of four launches hit this; the
first one happened to parse cleanly, so it is intermittent, not universal.

Fix: strip ANSI sequences from `$launchOutput` before matching, e.g.
`$launchOutput -replace "\x1b\[[0-9;]*[A-Za-z]", ""`, and/or prefer the machine-readable
`claude agents --json --all` row (match on `cwd` = the worker worktree) over scraping stdout.

### 2. The plan event has no recency guard, so status flip-flops

`reconcile-worker-sessions.ps1:83-96` sets `status = awaiting-input` whenever
`latest-plan.json` exists and the task is in `starting|planning|running`. Unlike the result
block (which guards on `resultRecordedAt` / `reworkRequestedAt`, lines 104-112), there is no
check that the plan event is newer than the last transition. Observed effect: a task that the
user has already sent back to work bounces `planning` → `awaiting-input` → `planning` on
successive reconciles. Add a `planRecordedAt` field and the same recency comparison the result
block uses.

## Verification

1. Regression test in `tests/run-tests.ps1` (the reconcile test around lines 226-238 is the
   natural hook): seed a task whose `plan.understanding` contains non-ASCII text — Cyrillic,
   an em dash and a bullet, e.g. `"Проверка — тест • ok"` — then run
   `reconcile-worker-sessions.ps1` at least five times and assert that
   - `state.json` size does not grow, and
   - the non-ASCII text round-trips byte-identically.
   Without the fix this test fails on the second pass.
2. Add a test asserting a background ID captured from output containing `ESC[36m` yields the
   bare ID.
3. Manual check on the live project: run reconcile ten times and confirm
   `(Get-Item state.json).Length` is stable.

## Context / constraints

- Never write plugin files into the target repository (`C:\laragon\www\motivehr`). Runtime state
  lives under `runtime/projects/<key>/`.
- The live state file has already been repaired by hand and rewritten as pure ASCII, so it is
  currently stable while the scheduler stays off. The corrupt original is kept for inspection at
  `runtime/projects/motivehr-4893d8fb/state.corrupt-483mb.json.bak` (483 MB) — safe to delete
  once you no longer need it.
- Four tasks are mid-flight in that project with live background worker sessions and
  uncommitted work in their worktrees. Do not reset, prune or clean any
  `.claude-factory-worktrees/**` path, and do not stop the worker sessions.
- The `/factory:tick` scheduler is deliberately deleted right now, because re-enabling it before
  this fix lands destroys the state file again within the hour.
- An earlier, already-fixed bug in the same launcher is worth knowing about as precedent:
  `claude --bg` emits a compatibility warning on stderr, and with
  `$ErrorActionPreference = "Stop"` that terminated the launch; it was solved by scoping
  `$ErrorActionPreference = "Continue"` around the native call (`start-worker-session.ps1:240-252`).
  The same "native tool output is not a PowerShell error stream" caution applies to bug 1 above.
