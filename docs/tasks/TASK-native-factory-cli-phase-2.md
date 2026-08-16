# TASK — Native Factory CLI actions and PowerShell completion UX

## Goal

Move deterministic operator actions out of the AI request path and make native
PowerShell completion visibly usable.

## Delivered surface

```powershell
factory chat <task-id>
factory hold <task-id>
factory reject <task-id> [-Yes|-Keep] [reason]
factory cleanup <task-id>
factory concurrency [number]
factory completion [status|enable]
```

The commands reuse the existing state-transition and cleanup scripts rather
than duplicating their safety rules. `reject` prints a removal preview whenever
artifacts exist and requires an explicit `-Yes`/`--yes`; `-Keep`/`--keep`
retains artifacts. `cleanup` continues to refuse active work, dirty worktrees,
unpublished commits, and commits not reachable from configured remote branches.

## Completion behavior

The command list now exposes canonical names only. The previous one-letter
aliases were the first candidates returned by PowerShell and made completion
look broken when `Tab` was bound to `TabCompleteNext`.

`factory completion status` reports the current PSReadLine binding.
`factory completion enable` changes `Tab` to `MenuComplete` for the current
terminal process. It does not edit `$PROFILE`; the persistent opt-in line is
shown to the operator instead.

## Boundary

Code-judgment and orchestration workflows remain AI-backed: `start`, `sync`,
`review`, and `go`. Replacing the scheduler/tick loop is a separate phase.

## Acceptance criteria

- Native state changes do not invoke an AI model.
- Task arguments complete from the current repository's private state.
- Destructive rejection is previewed and explicitly confirmed.
- Both PowerShell-style and double-dash confirmation flags are accepted.
- Completion can be diagnosed and enabled without modifying the user profile.
- Windows PowerShell 5.1 and PowerShell 7 parse and run the command surface.
- Tests use an isolated synthetic repository and never touch a live project.
