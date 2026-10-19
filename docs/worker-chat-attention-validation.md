# Worker chat and Claude attention validation

Validated on 2026-10-19 with Windows PowerShell 5.1 and installed Claude Code
2.1.303 (`C:\Users\igerg\.local\bin\claude.exe`). All repositories, worker
commits, remotes and runtime state used for these checks were synthetic. The
plugin checkout was neither committed nor pushed during validation. Existing
live runtimes were not used for the checks.

## Native hook spike

- The installed UserPromptSubmit implementation builds its payload with
  `session_id`, `cwd`, `hook_event_name` and `prompt`. The reply capture uses
  these fields, hashes the complete prompt and limits its preview to 240
  characters. Launch pointers are ignored.
- Both SessionStart and Stop command hooks with `asyncRewake: true` run in the
  background. A hook delayed by 12 seconds allowed the initial assistant turn
  to finish first. Exiting 2 with a synthetic message then started an idle
  background turn which replied `REWAKE_CONFIRMED`, without user input.
  The initial Stop carried `stop_hook_active: false`; the rewake turn's Stop
  carried `true`. Acknowledgement requires that flag and a claim predating
  the hook invocation, so an initial or duplicate Stop cannot acknowledge a
  batch whose continuation has not run yet.
- The installed schema accepts a positive timeout without a schema maximum.
  The command runner uses the configured seconds multiplied by 1000, and the
  rewake path still enforces that timeout. The separate 60-second SessionEnd
  budget is not a SessionStart/Stop ceiling. These hooks use an 86400-second
  timeout and voluntarily re-arm after 82800 seconds. The timeout/re-arm path
  is exercised with a short synthetic deadline; an all-day soak was not run.
- `claude respawn` fires SessionStart with source `resume` and the saved
  conversation UUID. A native `factory restart` also preserved that UUID and
  delivered new attention after restart.

The public [Claude hooks reference](https://code.claude.com/docs/en/hooks)
documents the reply payload, background hooks, idle wake on exit 2 and timeout
enforcement. The custom rewake prefix and summary were also confirmed in the
installed binary's hook schema and dispatch path.

## Durable delivery and restart

The live synthetic conversation was
`7f72f455-a607-4b8b-87f6-7656b4b62793`. Before restart it received the blocked
edge `LIVE_EDGE_BEFORE_RESTART`, claimed revision 1, acknowledged it on Stop,
and re-armed a single consumer. After native `factory restart`, the same
conversation received `LIVE_EDGE_AFTER_RESTART`; revisions 2 and 3 were
subsequently acknowledged and a replacement consumer was live.
After the stricter Stop proof guard was added, a further native respawn
received `LIVE_REWAKE_STOP_PROOF` and acknowledged revision 4 at
2026-10-19T11:00:24Z.

Restart regressions also cover a hook child surviving its owning Claude
process. Leases include the Claude host PID/start identity, and a heartbeat
older than 30 seconds is stale even if the child PID still exists. A replaced
consumer cannot clear a newer lease. Focused regressions cover stale children,
dead hosts, concurrent consumers, unacknowledged claim redelivery, Stop
acknowledgement, notify-only human edges, the auto-go exception and independent
manual-wait cursors.
SessionStart also waits briefly for a verified identity while a Factory launch
receipt exists, covering an initial hook that arrives before startup persists
the conversation UUID.

The first transport probe supplied a private runtime explicitly through its
test hook wrapper. The native restart probe used the synthetic repository's
default runtime placement, which daemon hooks can resolve without inherited
launcher environment variables. No existing project's runtime was selected.
All live spike sessions and its synthetic scheduler were stopped afterwards.

## Sanctioned amend

A tool-using Claude worker with `--permission-mode auto` invoked
`amend-task-commit.ps1` once against staged rework in `factory-worker/amend-live`.
It succeeded without a classifier denial:

```json
{
  "oldCommit": "71a4872e8c5a42364c552157258500e7e337a0a3",
  "commit": "5a8627b4c5da9f081e5b0947c5365114df263e31",
  "parent": "7ed33f39c1b5f9d8071c97b5d5b1cf8010bb9e42"
}
```

The helper preserved the parent and branch and left the worker clean. It did
not write a commit into Factory state. Regressions reject shared/wrong branches,
outside worktrees, detached HEAD, multiple task commits, merge commits,
HEAD already reachable from development,
unstaged/untracked files, interrupted Git operations, settled task states and
command shims. Message-only amendments require an external message file.

## Regressions

`tests/run-tests.ps1` includes `worker-chat-attention-amend.tests.ps1` and
additional rework/Codex resume checks. The focused suite verifies immediate
reply-to-sync promotion before a reconciliation tick, all identity/time/state
guards, blocked result retention rules, conversational Stops and completion
through the existing review gate. The native lifecycle suite remains part of
the complete harness.

Final results:

- Windows PowerShell 5.1 `tests/run-tests.ps1 -RuntimeOnly`: exit 0,
  `All factory runtime tests passed.` This includes the unchanged Codex
  attention transport assertions, automatic/interactive rework and the
  before-resume state observation.
- `tests/worker-chat-attention-amend.tests.ps1`: exit 0, including the isolated
  Codex resume boundary, startup identity race, rewake-only Stop proof and
  published-development-HEAD amend refusal.
- Auxiliary suites in the full harness completed successfully. The final
  runtime section was rerun directly in Windows PowerShell after correcting
  legacy launcher-name fixtures, manual-wait history isolation, completed-tick
  synchronization and two ambient `Get-FileHash` assertions.
- PowerShell source parsing and `git diff --check`: passed.
