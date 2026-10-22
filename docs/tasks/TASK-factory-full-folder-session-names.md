# Use the full repository folder in automatic Factory session names

Requested and authorized in the Factory development chat on 2026-10-22.

## Observed behavior

The `am-logger` repository's saved Claude orchestrator was named
`Factory AmLogge-7b36`, even though its config had no `orchestrator.name`.
`Get-FactoryOrchestratorAlias` in `scripts/orchestrator-name.ps1` shortened
the first two folder-name fragments to five letters and appended four
characters from the internal project key. This was intentional old behavior,
but made recognizable project names look misspelled. The operator requested
the complete folder name automatically, without abbreviations or suffixes.

## Expected behavior and acceptance checks

- With no explicit name, `am-logger` produces `Factory am-logger`, and workers
  use `am-logger` as their complete ownership label.
- Preserve folder case, punctuation, Unicode and length. A long folder must
  not cause negative worker identity budgets or lose normal task identifiers.
- Explicit `orchestrator.name` and `factory start -Name ...` still override
  the default; the old generic configured name uses the folder fallback.
- Keep path hashes in internal project keys and runtime paths unchanged.
  Discovery must still distinguish repositories by verified paths and UUIDs,
  including repositories with the same folder basename.
- Both Claude and Codex use the shared name resolver. A live Claude session
  keeps its label until the supported explicit restart, which retains its
  exact conversation UUID and leaves workers and tasks intact.
- Verify through isolated test fixtures. Do not rename, restart or edit any
  live Factory session or private runtime as part of this change.

## Implementation

The automatic alias now returns the repository folder name directly. Legacy
orchestrator discovery accepts full folder labels, including spaces and dots.
Worker display budgeting preserves the full label and normal task identity.
The operations guide and session-name protocol describe the new default.

## Validation (2026-10-23)

Passed under Windows PowerShell 5.1:

- `tests/orchestrator-name.tests.ps1`: exact folder names, case, punctuation,
  Unicode, long folders and explicit overrides.
- `tests/session-project-labels.tests.ps1`: complete worker labels and normal
  task IDs, same-basename repository separation, legacy rows and native Codex
  naming through fake executables.
- `tests/claude-orchestrator-lifecycle.tests.ps1`: a live abbreviated label is
  reused; explicit restart applies the folder label with the same UUID and
  byte-identical task state in an isolated fixture.
- `tests/codex-orchestrator-start.tests.ps1`: new and resumed threads receive
  the complete folder name, including spaces, without a replacement thread.
- `git diff --check`.

Integration fixtures required execution outside the filesystem sandbox because
it prevented Git from initializing their temporary repositories. No live
Factory was restarted or renamed, and no live private config was changed.
