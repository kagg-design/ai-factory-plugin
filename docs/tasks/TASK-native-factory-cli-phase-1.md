# TASK — Native read-only Factory CLI, phase 1

## Problem

Every `/factory ...` request currently passes through the orchestrator model.
That is appropriate for work that requires interpretation, review, or tool
selection, but it makes deterministic operations such as reading state and
printing diagnostics slower than necessary.

The operator also has two different command-entry environments:

- an ordinary PowerShell terminal;
- Claude Code's orchestrator prompt, where `!` enters direct shell mode.

The first native phase needs to work in both places without copying files into
the target repository and without adding another executable installer.

## Scope

Add a repository-root `factory.ps1` command. The plugin directory is already on
`PATH` for normal installation, so PowerShell resolves it as `factory`.

Implement these deterministic commands:

```text
factory help [command]
factory status [state|all]
factory inspect <task-id>
factory doctor
```

Inside the Claude Factory Orchestrator, the same code is invoked in direct
shell mode:

```text
!factory status
!factory inspect <task-id>
```

The leading `!` prevents the prompt from being interpreted as an AI request.
State-changing workflows remain `/factory ...` commands in this phase.

## Requirements

- Resolve the target repository from the current location by default and
  retain an explicit `-Repository` override.
- Reconcile background-session state before `status` and `inspect`, with an
  explicit `-NoReconcile` diagnostic/test escape hatch.
- Render `status` as one continuous Unicode tree with full task ID, title,
  canonical URL, session state, reason, and exact next orchestrator command.
- Keep completed task rows collapsed by default and support state, `done`, and
  `all` filters.
- Keep long task descriptions out of the default status view. `inspect` may
  show the complete requirements, but it must wrap long text while preserving
  the tree trunk.
- Render doctor JSON as concise `OK`, `WARN`, and `FAIL` lines and return a
  non-zero process exit for an unhealthy required check.
- Provide native PowerShell Tab completion for commands and status filters,
  plus dynamic task-ID completion for `inspect` using the current repository's
  private state.
- Support both Windows PowerShell 5.1 and PowerShell 7.
- Do not require a PowerShell profile edit, a copied target-repository file, or
  an additional global installation step.
- Do not use AI or an external source connector to render help or saved state.

## Acceptance criteria

- `Get-Command factory` resolves the root script after the plugin directory is
  added to `PATH`.
- `factory <Tab>` completes native subcommands; `factory status h<Tab>`
  completes `held`; `factory inspect <prefix><Tab>` completes saved task IDs
  and displays their titles.
- Default status omits completed task rows and points to `factory status done`.
- Filtered and completed-history status output does not leak tasks from other
  states.
- Status and inspect show full title and canonical URL, and identify whether a
  background session can be opened.
- `!factory status` can be used from the orchestrator without invoking the
  `/factory` skill.
- Runtime regression tests exercise help, status, filters, inspect, doctor,
  and completion under Windows PowerShell 5.1.

## Implementation outcome

`factory.ps1` now supplies the native command surface and parameter metadata.
PowerShell reads that metadata directly, so command/filter completion and
dynamic task-ID completion work without modifying `$PROFILE`.

`scripts/factory-cli.ps1` owns deterministic context loading, reconciliation,
state inspection, continuous-tree rendering, line wrapping, next-action
selection, and doctor formatting. The status view was validated against the
live MotiveHR private state using `-NoReconcile`; no MotiveHR state or Git data
was changed by that validation.

Mutating native commands, richer Claude shell completion, and removal of the
AI-backed slash implementations are deliberately deferred to later phases.

A post-implementation live display check exposed pre-existing OEM-decoded
worker text and a stale-plan-question selector. Their fix and process-boundary
UTF-8 regression coverage are documented separately in
`TASK-windows-powershell-native-utf8-capture.md`.
