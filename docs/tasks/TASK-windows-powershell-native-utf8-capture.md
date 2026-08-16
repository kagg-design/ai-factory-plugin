# TASK — Preserve UTF-8 across Windows PowerShell native and hook boundaries

## Problem

The native `factory status` command exposed already-corrupted Russian text in a
review card:

```text
Reason: 1. STEP 1 ╤ü╨╜╨╕╨╝╨░╨╡╨╝? ...
```

PowerShell 7 and its terminal were both configured for UTF-8. Reading the
private state with an explicit strict UTF-8 decoder produced the same text, so
the renderer was not the original corruption point.

The affected worker event, session metadata, plan, and result already contained
the mojibake. UTF-8 bytes emitted by Claude Code had been decoded by Windows
PowerShell 5.1 through OEM code page 437 before the values were written as
valid UTF-8 JSON. For example, the UTF-8 bytes for `снимаем` became
`╤ü╨╜╨╕╨╝╨░╨╡╨╝`.

There was also an independent status-selection defect: a completed task in
`awaiting-review` inherited the first stale `plan.questions` entry as its
current `Reason`. That made a historical planning question both misleading and
large enough to dominate the card.

## Requirements

- Configure every hook stdin reader for UTF-8 before calling
  `[Console]::In.ReadToEnd()`.
- Configure the shared native-process helper to decode redirected stdout and
  stderr explicitly as UTF-8.
- Route captured Claude CLI diagnostics and Agent View JSON through that helper
  instead of ambient Windows PowerShell decoding.
- Keep `Reason` state-aware. A plan question is current only for
  `awaiting-input`; it must not appear for `awaiting-review`.
- Keep status reasons short even when the underlying blocker is verbose.
- Repair the known reversible CP437/UTF-8 mojibake only in CLI display. Do not
  rewrite private history automatically.
- Leave live MotiveHR task `1217516118946154`, its state, session, and worktree
  untouched while its orchestrator review is running.

## Acceptance criteria

- A fake native CLI writes a Russian UTF-8 probe and
  `Invoke-FactoryNativeProcess` returns the exact original string under Windows
  PowerShell 5.1.
- A Stop hook receives a UTF-8 JSON payload through redirected stdin, persists
  a Russian worker-result note, and reconcile returns the exact original
  string.
- CLI status repairs a legacy CP437-decoded UTF-8 reason for display without
  writing the state file.
- An `awaiting-review` fixture with stale plan questions prints no question as
  `Reason`.
- The complete runtime test suite passes.

## Implementation outcome

`scripts/factory-common.ps1` now establishes UTF-8 console defaults and sets
`ProcessStartInfo.StandardOutputEncoding` and `StandardErrorEncoding`
explicitly. Claude version, Agent View, and MCP captures use the shared native
process path. Both hook entry points set UTF-8 before reading stdin; the
worktree-create hook receives the same protection by dot-sourcing the common
module before its read.

The CLI now treats plan questions as reasons only in `awaiting-input`, caps
status reason length, and reverses the known CP437/UTF-8 transformation for
display when strict validation proves it is reversible. The stored data is not
silently migrated.

Regression coverage sends UTF-8 bytes across real redirected process
boundaries under Windows PowerShell 5.1. The full runtime suite passes. During
diagnosis, MotiveHR runtime files were read only; no reconcile, task action,
session operation, state write, or worktree command was run against task
`1217516118946154`.
