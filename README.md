# Claude Asana Factory

Claude Asana Factory is a removable Claude Code plugin that turns Asana tasks
into a persistent development queue:

```text
Asana → queue → background worker sessions → external Git worktrees
      → tests → one task commit → human review
      → serialized integration → push → cleanup
```

The plugin is loaded only for a dedicated factory session. It is never copied
into the target repository and does not change the repository's `.claude`
directory, `CLAUDE.md`, or `.gitignore`.

## Requirements

- Windows PowerShell 5.1 or PowerShell 7
- Git
- Claude Code 2.1.139 or newer; the current Agent View release is recommended
- an authenticated Asana connector available to Claude Code
- remote development and production branches (`develop` and `master` by
  default)

Check Claude Code before starting:

```powershell
claude --version
```

## Start the factory

From the plugin directory:

```powershell
.\start-factory.ps1 -Repository D:\Projects\MotiveHR
```

The launcher:

1. resolves the repository's primary Git worktree;
2. creates or migrates private per-repository config and state;
3. creates the external factory worktree root;
4. acquires a per-repository process lock;
5. changes to the target repository;
6. starts Claude Code with this plugin loaded through `--plugin-dir`.

It does not add a task, create a task commit, merge, or push by itself.

Only one factory lead session can run for a repository. Different repositories
can run separate factory sessions at the same time.

### Resume and model selection

Open the resume picker in the correct repository context:

```powershell
.\start-factory.ps1 -Repository D:\Projects\MotiveHR -Resume
```

Continue the repository's most recent conversation:

```powershell
.\start-factory.ps1 -Repository D:\Projects\MotiveHR -Continue
```

Choose the lead and inherited worker model:

```powershell
.\start-factory.ps1 -Repository D:\Projects\MotiveHR -Model sonnet
```

`-Resume` and `-Continue` are mutually exclusive.

## Start modes

Every worker is a full Claude Code background session, not a one-shot
subagent. It has its own persistent conversation, branch, and external
worktree.

### Interactive start

```text
/asana:factory start <Asana URL>
```

The worker reads the task and relevant code without editing, returns a
`FACTORY_PLAN`, and waits. Open its conversation, discuss or change the plan,
then tell it to begin.

### Automatic start

```text
/asana:factory start --auto <Asana URL>
```

The worker begins implementation immediately. This mode is intended for clear,
small tasks that normally need no clarification.

Bare URLs remain a compatibility alias for automatic mode:

```text
/asana:factory <Asana URL> <Asana URL>
```

Both modes remain interruptible.

## Enter and steer a worker conversation

Open Agent View:

```powershell
claude agents
```

Or press `←` from an attached Claude Code session. Select a worker and press
Enter to enter its full conversation.

To attach directly from another terminal:

```powershell
claude attach <background-id>
```

While attached:

- `Esc` or `Ctrl+C` interrupts the current response or tool call;
- type the correction and press Enter;
- `←` on an empty prompt detaches back to Agent View without stopping work.

The factory also prints these commands:

```text
/asana:factory chat <task-id>
/asana:factory transcript <task-id>
```

Worker sessions are named `asana-<task-id>-<title>`, so they are easy to find
in Agent View.

## Human review gate

A successful worker ends in `awaiting-review`. It is never integrated
automatically.

Review the requirements, transcript, tests, and exact commit:

```text
/asana:factory review <task-id>
```

Approve the exact clean worker SHA:

```text
/asana:factory go <task-id>
```

Other decisions:

```text
/asana:factory hold <task-id>
/asana:factory reject <task-id>
/asana:factory rework <task-id> "Keep the old endpoint compatible"
```

`rework` preserves the same conversation and prints the attach command plus
the text to paste. A full background session is independent, so the factory
does not pretend it can inject keystrokes into the live TUI.

If the worktree HEAD changes after approval, integration stops and requires a
fresh review. The integrator merges the immutable approved SHA, not a moving
branch name.

## Dynamic concurrency

The default limit is three active workers:

```json
{
  "concurrency": 3,
  "maxConcurrency": 20
}
```

Show the current limit:

```text
/asana:factory concurrency
```

Change it while the queue is running:

```text
/asana:factory concurrency 5
```

Increasing from three to five lets the next tick start up to two additional
queued workers immediately. Decreasing the limit never kills workers already
running; the scheduler simply waits before starting more.

`planning`, `starting`, and `running` tasks consume active capacity.
`awaiting-input` and `awaiting-review` sessions are idle and do not.

## Commands

```text
/asana:factory start <URLs>
/asana:factory start --auto <URLs>
/asana:factory status
/asana:factory doctor
/asana:factory concurrency [N]
/asana:factory chat <task-id>
/asana:factory transcript <task-id>
/asana:factory inspect <task-id>
/asana:factory review <task-id>
/asana:factory go <task-id>
/asana:factory hold <task-id>
/asana:factory rework <task-id> [instructions]
/asana:factory reject <task-id>
/asana:factory retry <task-id>
/asana:factory pause
/asana:factory resume
/asana:factory stop
```

When the queue contains only tasks waiting for input or review, the recurring
tick is removed so it does not print no-op messages. Adding a task, approving
one, resuming, or increasing concurrency recreates it.

## Worktree isolation

Factory worktrees are siblings of the repository:

```text
D:\Projects\.claude-factory-worktrees\
└── MotiveHR-a1b2c3d4\
    ├── worker-121234567-a1\
    ├── factory-integrator\
    └── factory-release\
```

Worker branches use:

```text
factory-worker/<task-id>-a<attempt>
```

Each background session starts inside its already registered linked worktree,
so Claude Code does not create a nested `.claude/worktrees` checkout. A
PreToolUse hook denies push, merge, rebase, shared-branch checkout, and
worktree deletion from worker branches.

Workers may edit, test, and create one final task commit. Only the serialized
factory integrator may merge or push.

## Integration

Approved tasks are integrated one at a time in `factory-integrator`. The
factory:

1. fetches the current remote development branch;
2. merges the approved SHA;
3. runs integration tests;
4. fetches again and rebuilds if the remote moved;
5. pushes without force;
6. promotes in the separate `factory-release` worktree;
7. runs release tests and verifies remote reachability;
8. cleans the worker only after verification.

`merge-develop` promotes the complete current development branch:

```json
{
  "productionMode": "merge-develop",
  "allowUnrelatedDevelopCommitsToProduction": true
}
```

Use `task-only` when production must receive only the approved factory task:

```json
{
  "productionMode": "task-only",
  "allowUnrelatedDevelopCommitsToProduction": false
}
```

Set canonical project checks explicitly when possible:

```json
{
  "integrationTestCommands": [
    "composer test",
    "composer lint"
  ],
  "releaseTestCommands": [
    "composer test",
    "composer lint"
  ]
}
```

## Private state

Show the paths for one repository:

```powershell
.\show-project-paths.ps1 -Repository D:\Projects\MotiveHR
```

Open its config:

```powershell
.\edit-project-config.ps1 -Repository D:\Projects\MotiveHR
```

Private data is stored under:

```text
<plugin>\runtime\projects\<repository-name>-<path-hash>\
```

It includes config, queue state, background-session metadata, captured Stop
events, transcript paths, and resolved test commands. Existing v2 config and
state are migrated by adding missing v3 fields; repository-specific settings
are preserved.

## Tests

Run the local PowerShell runtime suite:

```powershell
.\tests\run-tests.ps1
```

The suite uses a temporary local Git remote and a fake Claude CLI. It does not
call a model, Asana, or a real project remote. It verifies external worktree
creation, background-session metadata, Stop-hook capture, the review gate,
exact-SHA approval, linked-worktree project identity, and dynamic concurrency.

## Safe cleanup

Stop and review the factory first:

```powershell
.\cleanup-project.ps1 -Repository D:\Projects\MotiveHR
```

Without `-Force`, cleanup refuses to remove registered factory worktrees.
This preserves active sessions, uncommitted changes, and commits that still
need review.

Emergency cleanup:

```powershell
.\cleanup-project.ps1 -Repository D:\Projects\MotiveHR -Force
```

`-Force` may remove registered worktrees and their uncommitted changes. Use it
only after manual inspection.

After each repository is safely cleaned, deleting the plugin directory removes
the factory completely. Normal Claude Code sessions launched without
`--plugin-dir` never see `/asana:factory`.
