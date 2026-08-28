# Claude Factory

Claude Factory is a removable Claude Code orchestration package that turns
normalized source tasks into a persistent development queue:

```text
Asana (read-only) → AI normalization → native intake boundary → queue
                   → background worker sessions → external Git worktrees
                   → tests → one task commit → human review
                   → serialized integration → push → cleanup
```

Asana is the built-in connector-backed adapter. Native intake is source-neutral,
so a normalized envelope from a manual or future adapter can enter through
`factory add --file <task.json>` without giving AI permission to edit the queue.
An operator can also create a native local task directly with `factory new`,
without Asana, AI normalization, or an intermediate JSON file.

The plugin is loaded only for a dedicated factory session. It is never copied
into the target repository and does not change the repository's `.claude`
directory, `CLAUDE.md`, or `.gitignore`.

## Requirements

- Windows PowerShell 5.1 or PowerShell 7
- Git
- Claude Code 2.1.139 or newer; the current Agent View release is recommended
- an authenticated Asana connector available to Claude Code for Asana-backed
  intake (`factory add --file` does not require it)
- remote development and production branches (`develop` and `master` by
  default)

Check Claude Code before starting:

```powershell
claude --version
```

## Start the factory

Add the plugin directory to `PATH`, then use the single `factory` entry point
from the target Git repository:

```powershell
cd D:\Projects\MotiveHR
factory start
```

When `-Repository` is omitted, the current directory is used and resolved to
its primary Git worktree. An explicit path remains available when launching
from elsewhere:

```powershell
factory start -Repository D:\Projects\MotiveHR
```

The launcher:

1. resolves the repository's primary Git worktree;
2. creates or migrates private per-repository config and state;
3. creates the external factory worktree root;
4. starts or reuses one hidden native scheduler process;
5. acquires a per-repository orchestrator lock;
6. changes to the target repository;
7. starts the selected orchestrator and uses the same runtime for new workers;
8. loads the factory protocol without adding files to the target repository;
9. stores a separate exact conversation UUID for Claude and Codex.

It does not add a task, create a task commit, merge, or push by itself.

Only one factory lead session can run for a repository. Different repositories
can run separate factory sessions at the same time.

`factory start` always selects the full Claude runtime. Use `factory start
-Agent codex` to select Codex for both the orchestrator and new workers. Normal
startup reuses the selected runtime's exact stored conversation. Claude may
attach an existing background Agent View row; Codex resumes its stored thread
UUID directly. Use `-New` only when a genuinely new conversation is required.

## Fast local commands

The plugin directory also exposes a native PowerShell command for deterministic
operations that do not need AI interpretation:

```powershell
cd D:\Projects\MotiveHR
factory start
factory status
factory inspect 1216632072822682
factory preview 1216632072822682
factory preview stop
factory chat 1216632072822682
factory new "Fix the profile export"
factory new
factory add --file D:\Tasks\normalized-task.json
factory go 1216632072822682
factory go 1216632072822682 --direct
factory hold 1216632072822682
factory reject 1216632072822682 -Yes
factory cleanup 1216632072822682
factory concurrency 5
factory doctor
factory completion status
factory paths
factory config edit
factory scheduler status
factory rotate
factory help
```

Named local workers use compact readable session names such as
`factory-local-fe35a8dc-fix-the-profile-export`. `fe35a8dc` is the task's
stable random nonce, not a Claude/Codex session ID. The full local task ID
remains in state and status; its timestamp and filesystem-only artifact hash
are omitted from the display name so the supplied title stays visible.

The plugin root contains both `factory.ps1` for PowerShell command discovery and
an extensionless Bash-compatible `factory` launcher. Consequently, the same
code can run from either orchestrator through its direct shell mode:

```text
!factory status
!factory inspect 1216632072822682
!factory preview 1216632072822682
!factory new "Fix the profile export"
!factory go 1216632072822682
!factory go 1216632072822682 --direct
!factory hold 1216632072822682
```

PowerShell completes command names and status filters with `Tab`. Task commands
read the current repository's private factory state and complete task IDs while
displaying their titles. Completion is declared by the script itself, so command
metadata needs no `$PROFILE` edit. If `Tab` silently cycles one value at a time,
enable PSReadLine's menu for the current terminal with
`factory completion enable`. The command reports the exact persistent profile
line but never edits the profile automatically.

Native commands cover launcher/runtime/scheduler control, deterministic reads,
worktree browser preview, local task creation, validated normalized intake, formally reviewed `go`, `hold`, confirmed
`reject`, safe `cleanup`, and concurrency changes.
`factory start` in PowerShell opens the orchestrator; `start <URL>` inside an
orchestrator asks AI to read and normalize Asana content. Native
code owns URL validation, deduplication, state insertion, and scheduler wakeup;
AI never edits the queue directly. Judgment-heavy workflows such as Asana
normalization, `sync`, and `review` still use the active orchestrator. In Claude
they may be written as `/factory review <id>`; in Codex use the natural
`factory review <id>` or `review <id>` form. A
plain `factory reject <id>` prints the exact destructive preview; repeat it with
`-Yes` (or `--yes`) to discard, or use `-Keep` (or `--keep`) for state-only
rejection. The leading `!` explicitly selects native shell execution inside
either TUI. Without it, the text is handled by the orchestrator. Both
launchers are available when the plugin root is on `PATH`, as required by the
installation steps above.

Override the lead session name when needed:

```powershell
start-factory -Name "MotiveHR Factory Orchestrator"
```

### Resume and model selection

Open the resume picker in the correct repository context:

```powershell
start-factory -Resume
```

For normal factory startup, omit all mode flags: the stored orchestrator is
resumed automatically. `-Continue` selects the newest conversation in the
repository and may therefore resume an unrelated scheduled task or development
conversation. `-Resume` remains a manual recovery picker for legacy sessions.

Start a deliberately new orchestrator conversation:

```powershell
start-factory -New
```

Continue the repository's most recent conversation:

```powershell
factory start -Continue
```

Choose the lead and inherited worker model:

```powershell
factory start -Model sonnet
```

`-Resume` and `-Continue` are mutually exclusive.

### Rotate a long-running orchestrator

Prepare a fresh orchestrator conversation without changing durable Factory
work:

```powershell
factory rotate
```

From inside Claude or Codex, use `!factory rotate`. The command writes a
deterministic private handoff with operational settings, task counts, and every
unfinished task, then marks the selected runtime for replacement. Exit the
current TUI and run the exact command it prints (`factory start` for Claude or
`factory start -Agent codex` for Codex). That normal start creates a new
conversation instead of resuming the old UUID and injects the handoff into its
bootstrap context. Task state, workers, worktrees, commits, scheduler state,
and the previous resumable conversation are retained.

Use `factory rotate status` to inspect a pending request and `factory rotate
cancel` to cancel it. Rotation is explicit rather than token-count driven:
Claude/Codex own context compaction, while Factory owns only durable native
state and session identity.

### Full runtime selection

Select one runtime for the orchestrator and all newly launched workers:

```powershell
factory start -Agent claude
factory start -Agent codex
```

The selection is written only to the private per-project runtime config; it is
not added to the target repository. Omitting `-Agent` selects Claude, even if
the previous run used Codex. Changing it affects new worker attempts only and
never converts a session that is already running. `factory status` shows the
selected runtime beside worker capacity, and `factory doctor` verifies the
selected CLI.

The launcher keeps `orchestrator-session.json` for Claude and
`codex-orchestrator-session.json` for Codex. Switching runtimes therefore does
not merge or lose either conversation. The per-repository launcher mutex still
allows only one live orchestrator at a time.

On first Codex startup, Factory links its bundled `factory` skill into the
user-level Codex skill directory. The link points back to this plugin; no
`.codex`, skill, or factory file is written to the target repository. Prompt
commands use `factory status`, `factory new`, `factory review <id>`, and so on;
`$factory` is an internal explicit skill name, not the operator interface.

Codex orchestrator bootstrap and workers use the supported resumable session
interfaces. Worker
thread UUID, PID, transcript, and exact resume command are stored in private
runtime state. They do not appear in Claude Agent View. Use `factory chat
<task-id>` to obtain the capture-aware PowerShell command; it opens `codex
resume` and, after the interactive TUI exits, performs one short resume turn so
the resulting `FACTORY_PLAN` or `FACTORY_RESULT` is reconciled into Factory.
The ordinary Codex picker can also show these sessions with `codex resume --all
--include-non-interactive`, but a raw picker/resume does not run Factory's
post-chat capture step.

Local tasks do not require Asana or any connector:

```text
factory new
factory new "Describe the change"
```

An Asana connector is needed only when the Codex orchestrator must read an
Asana URL. It can be connected later without changing local task operation.

### Conversation language

Set the language used for orchestrator, scheduler, and worker conversation in
the private per-repository config:

```json
{
  "conversationLanguage": "Russian"
}
```

Open the correct config with:

```powershell
factory config edit -Repository D:\Projects\MotiveHR
```

The setting applies to subsequent orchestrator commands and newly launched
workers. The native scheduler itself emits operational English only and does
not consume conversation turns.
New workers receive it in their trusted task payload. Existing worker sessions
retain the instructions with which they were launched.

## Start modes

Every worker has its own persistent CLI session, branch, and external worktree.
Claude workers use Claude Code background sessions; Codex workers use durable
Codex exec threads.

### Interactive start

```text
/factory start <Asana URL>
```

Worker launch prefers the plugin agent `factory:worker`. If a Claude Code
version cannot resolve a session-only plugin agent during `--bg` startup, the
launcher stops and verifies removal of the default-template session, then
relaunches once with the byte-identical `agents/worker.md` prompt supplied as an
inline agent. If that agent is also unresolved, it stops that stray session and
launches without `--agent`, appending the stripped worker body from a private
UTF-8 prompt file. The successful resolution path is stored as `plugin`,
`inline-fallback`, or `system-prompt` and cached for that Claude Code version.
A version change automatically probes the native plugin path again.

The launcher uses explicit Windows native-argument quoting so inline JSON is not
mangled by Windows PowerShell 5.1. The system-prompt path avoids the large JSON
argument entirely. Prompt hashes use .NET SHA-256 rather than `Get-FileHash`,
avoiding ambient `PSModulePath` incompatibilities. Every failed path is terminal
unless a later verified resolution exists, and every stray session is stopped.

The inline definition carries the agent `description` and prompt body. The
system-prompt workaround is explicitly additive to Claude's default system
prompt. Worker model and effort remain explicit CLI flags, but agent
frontmatter name, description, `maxTurns`, and any tools restriction are not
applied on that path; these deviations are stored in launch metadata and shown
by `/factory doctor`.

The worker reads the task and relevant code without editing, returns a
`FACTORY_PLAN`, and waits. Open its conversation, discuss or change the plan,
then tell it to begin.

### Automatic start

```text
/factory start --auto <Asana URL>
```

The worker begins implementation immediately. This mode is intended for clear,
small tasks that normally need no clarification.

`add` is an explicit alias for `start` and supports the same modes:

```text
/factory add <Asana URL>
/factory add --auto <Asana URL>
```

Bare URLs remain a compatibility alias for automatic mode:

```text
/factory <Asana URL> <Asana URL>
```

Both modes remain interruptible.

For each Asana URL, native code first validates and canonicalizes the URL,
extracts its task ID, and checks private state for a duplicate. Only a new task
is read through the Asana connector. AI then writes semantic content into the
private `resources/intake.schema.json` envelope; it cannot choose the source
identity or start mode. A second native boundary validates the envelope,
repeats deduplication under the state lock, atomically adds the complete task,
and starts or wakes the scheduler.

Manual and future adapters can bypass AI and Asana with an already normalized
envelope:

```powershell
factory add --file D:\Tasks\normalized-task.json
```

Non-Asana state IDs use `adapter:id`; Asana keeps its numeric ID for backward
compatibility. The input file is validated but not modified or deleted.

Create a task directly from operator text without a connector or JSON envelope:

```powershell
factory new "Fix the profile export"
factory new --auto "Remove the obsolete navigation item"
```

The default is interactive and waits for plan approval. `--auto` requires
non-empty text and begins implementation immediately. Running `factory new`
without text creates an intentionally empty interactive worker; open it with
the printed `factory chat <local-task-id>` command and tell it what to do. Local
tasks receive collision-safe `local:...` IDs. The `local` adapter is reserved
for this native command and cannot be imported through `factory add --file`.

## Enter and steer a worker conversation

For a Claude worker, open Agent View:

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
/factory chat <task-id>
/factory transcript <task-id>
```

Worker sessions are named `factory-<task-id>-<title>`, so they are easy to find
in Agent View.

For a Codex worker, run `factory chat <task-id>` and then execute the printed
PowerShell command in a separate terminal. Codex sessions are deliberately not
listed in Claude Agent View.

## Human review gate

A successful worker ends in `awaiting-review`. The normal path requires a
formal AI review and explicit operator approval.

Review the requirements, transcript, tests, and exact commit:

```text
/factory review <task-id>
```

Review records the verdict, risks, trusted integration/release commands, exact
remote bases, and a hash of the immutable publication plan. Approve that exact
clean worker SHA and plan:

```text
/factory go <task-id>
```

After review, the deterministic equivalent is also available without an AI
turn:

```powershell
factory go <task-id>
```

For a small result that the operator has already assessed from the worker
output, the independent AI review can be skipped explicitly:

```powershell
factory go <task-id> --direct
```

From the orchestrator, use `!factory go <task-id> --direct` for the same native
path. Direct approval does not weaken the publication pipeline: it still
requires the exact validated worker SHA, a clean idle worktree, at least one
passed worker check and no failed checks, a single commit on the current
development base, and trusted integration/release commands from private config
or previously resolved review state. It records `operator-direct` in both the
review and approval audit, pins the immutable plan hash, and runs the same
isolated checks before each push. It refuses to override an existing
`changes-required` or `blocked` review for that commit.

`factory status` advertises the direct path only when the saved task result and
private publication configuration pass a read-only preflight. Running the
command directly performs the same preflight before any review state is
written and names each blocking private setting with `factory config edit` as
the corrective command. `factory doctor` reports this publication readiness as
a warning rather than declaring an otherwise usable factory unhealthy.

Publication runs asynchronously after `go`; the command prints `factory
inspect <task-id>` as the monitoring command. If integration or promotion
fails, the failed audit remains visible but its immutable plan cannot be
approved again. Status points back to `review`, and only a freshly recorded
formal review clears the active failure marker and enables another `go`.
The already-running native scheduler hot-loads publication code in a fresh
child process for each approved task, so updating the Factory plugin does not
require restarting an active factory.

Other decisions:

```text
/factory hold <task-id>
/factory reject <task-id> "Duplicate; already implemented elsewhere"
/factory reject <task-id> --yes
/factory reject <task-id> --keep
/factory rework <task-id> "Keep the old endpoint compatible"
/factory release <task-id>
```

`rework` stops the previous worker session, preserves its branch, worktree,
commit, and result, clears review and approval, and queues a new attempt. The
launcher writes the findings and retained commit into the new worker prompt,
then clears the pending delivery marker. `release` is the explicit recovery
path for a saved session identity that is no longer present in the runtime; it
restores the state implied by validated artifacts without changing Git.

If the worktree HEAD or a reviewed remote base changes after review, integration
stops and requires synchronization/review again. The native scheduler prepares
the development and production candidates in the existing reusable integrator
and release worktrees, then runs their recorded check sets concurrently in
separate processes and isolated test databases. After both candidates pass, it
re-fetches the remote tips and pushes the exact tested development candidate,
then the exact tested production candidate, sequentially and without force. It
verifies reachability and cleans the worker; it never asks AI to resolve a merge
conflict implicitly.

Pipeline merge commits use operator-facing messages instead of Git's internal
worktree names. Their subject is `Merge task <task-id> into <target-branch>`;
the body carries the full title, the connector's originally supplied URL (or
`Source: local / <source-id>`), the short approved task commit, and what the
production merge promotes. Messages are written through a temporary UTF-8
without BOM file, so non-ASCII titles and punctuation never cross the Windows
PowerShell 5.1 native argument boundary. Internal `factory://` URIs are never
written to Git history.

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
/factory concurrency
```

Change it while the queue is running:

```text
/factory concurrency 5
```

Increasing from three to five lets the next tick start up to two additional
queued workers immediately. Decreasing the limit never kills workers already
running; the scheduler simply waits before starting more.

`planning`, `starting`, and `running` tasks consume active capacity.
`awaiting-input` and `awaiting-review` sessions are idle and do not.

## Commands

```text
/factory help [command]
/factory start <URLs>
/factory start --auto <URLs>
/factory status
/factory doctor
/factory concurrency [N]
/factory chat <task-id>
/factory transcript <task-id>
/factory inspect <task-id>
/factory sync <task-id>
/factory review <task-id>
/factory answer <task-id> --text "decision"
/factory go <task-id>
/factory hold <task-id>
/factory rework <task-id> [instructions]
/factory release <task-id>
/factory reject <task-id> [reason] [--yes|--keep]
/factory cleanup <task-id>
/factory retry <task-id>
/factory rotate
/factory pause
/factory resume
/factory stop
```

Scheduler process control and factory permission are deliberately separate.
`factory scheduler stop`/`start` (and the top-level `factory stop`) stop or
start only the native process and preserve both `active` and `paused`. Use
`factory pause` to suspend new launches/publication while keeping the process,
and `factory resume` to permit work, start the scheduler if necessary, and tick
immediately. Starting a scheduler while an explicit pause remains set does not
clear that pause: the command warns that the process is running but inert and
names `factory resume`. With runnable work, both scheduler and factory status
show this combination as an actionable problem.

Successful `/factory cleanup` removes every background row belonging to the
task from Claude Agent View, including older attempts. Live processes are
stopped and verified before the worktree is touched. An individual `claude rm`
failure is reported through `agentSessionWarning` without rolling a finalized
task back from `done`.

The slash-command hint is intentionally short. Use `/factory help` for a
one-screen grouped overview or `/factory help <command>` for syntax,
prerequisites, side effects, safety behavior, and the usual next step for one
command.

`/factory status` shows unfinished tasks in one continuous workflow-style tree
with full task ID, untruncated title, canonical task URL, reason, session, and
exact next command. Completed rows are collapsed by default. Use
`/factory status held`, `/factory status awaiting-review`,
`/factory status done`, or `/factory status all` to filter the report. Status is
read-only: it reports commands but never launches or changes a task by itself.

When the queue contains only tasks waiting for input or review, the native
scheduler remains asleep and emits no AI messages. Adding a task, approving one,
resuming, or increasing concurrency wakes it immediately.

During reconciliation, worker launch, or publication, scheduler status changes
to `busy` and includes the operation, task ID/title, start time, and a heartbeat
that continues to refresh while the child process runs. `factory start` and
`factory resume` refuse to start or tick a second scheduler while that ownership
is in flight. Every tick is appended as one JSON line to
`scheduler.stdout.log`; failures and unexpected process loss go to
`scheduler.stderr.log`. Both paths are shown by `factory scheduler status`.
If runnable work exists while the scheduler is stopped or failed, `factory
status` places the scheduler under `NEEDS YOUR ACTION` instead of describing it
as sleeping, and `factory doctor` reports the same failure and log path.

`sync` updates the existing clean worker worktree before review. It fetches the
configured remote development branch, rebases the one task commit onto it,
reruns appropriate checks through the orchestrator, records the new SHA and
test results, and returns the task to `awaiting-review`. It does not create a
second preview worktree. Conflicts are aborted without changing the original
branch. An operator or worker may resolve one by placing a clean, single-parent
commit directly on the recorded worker branch, with the current development
tip as its parent; rerunning `/factory sync <task-id>` validates and adopts that
HEAD. An interrupted validation remains `syncing` and cannot be approved until
the same command successfully finalizes it.

`cleanup` is intentionally strict. It reconciles the task first, refuses
active sessions and dirty worktrees, refreshes the configured remote branches,
and requires the recorded commit to be reachable from both development and
production. It then stops every live process for the task, verifies that none
still holds the directory, removes all of the task's Agent View rows, and only
then deletes the worker worktree and local `factory-worker/*` branch. It keeps
the transcript and result in private state and marks the task `done`. Claude
Code 2.1.228 was verified to leave JSONL transcripts intact after `claude rm`.
Cleanup also uses Git long-path support and finishes removal of verified clean
residue left by Windows.

`reject` is the normal way to abandon a task. It first shows the exact session,
worktree, branch, commit, and private metadata that will be lost, then asks for
confirmation. Once confirmed, it stops the session, removes those artifacts,
removes all Agent View rows from current and previous attempts, and forgets the
task so it disappears from status. `reject --yes` skips the question. `reject
--keep` provides the former state-only behavior and leaves a `rejected` task
available for inspection.

Use `cleanup` instead for completed work that was published: cleanup verifies
both remote branches and retains the task as `done` history.

Worker launch prompts are persisted as UTF-8 files in the private runtime and
the background process receives only a short file pointer. Reconciliation binds
identity-bearing metadata only through the background ID or full session UUID,
so an older same-name Agent View row cannot replace the live attempt.
`/factory doctor` reports the PowerShell runtime, required JSON cmdlets, worker
definition readiness, fallback deviations, the cached worker-agent resolution
path, and publication-pipeline readiness. A disabled publication pipeline is a
warning because planning and implementation remain usable; having no working
worker-launch path for the installed CLI is a required failure. The worker Git
guard fails closed when its hook payload cannot be parsed; an internal guard
error is never treated as permission to run a prohibited Git operation.


A session that stops without `FACTORY_RESULT` is machine-held and can be resumed
with `retry`, or supplied durable decisions with `answer`. `answer` refreshes an
ignored `FACTORY-DECISIONS.md` in the retained worktree, removes the superseded
Agent View rows without deleting their transcripts, and queues one attempt.
Manual holds remain distinct and are not automatically retryable.

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

### Browser preview

Open the application exactly from a worker worktree before approving it:

```powershell
factory preview 1216632072822682
```

The default profile starts Laravel and Vite on separate free IPv4-loopback
ports, waits for both, opens the app URL, and records the exact PIDs, process
start times, ports, worktree, and logs in private runtime data. It temporarily
links `vendor` and `node_modules` from the main repository only when the worker
does not have its own directories and the relevant lock file still matches.
Those junctions are removed when preview stops. The app uses the copied project
environment and development database, not the isolated worker test database.
Stop also finds `powershell`, `pwsh`, `php`, `node`, `npm`, `npx`, and `esbuild`
processes whose command lines still reference the worktree, terminates their
trees, and verifies that none remain before removing dependency junctions.

Only one preview is active per repository. Starting another task performs an
automatic switch:

```powershell
factory preview 1216643944203164
```

Repeating the active task reopens its URL without replacing its processes.
Inspect or stop the current preview with:

```powershell
factory preview
factory preview stop
```

Use `--no-open` when a caller needs only the URL. Approval, confirmed rejection,
task cleanup, project purge, and `factory stop` stop the applicable preview
before integration or worktree removal. Closing a browser tab cannot reliably
signal process ownership and therefore does not stop it.

## Integration

Approved tasks are integrated one at a time in `factory-integrator`. The
factory:

1. fetches the current remote development branch;
2. merges the approved SHA;
3. runs integration tests;
4. fetches again and stops before development push if its reviewed base moved;
5. pushes without force;
6. promotes in the separate `factory-release` worktree, rebuilding and
   retesting when a release input races;
7. runs release tests and verifies remote reachability;
8. cleans the worker only after verification.

Cleanup is audited as a separate stage after both remote pushes are verified.
If it fails, development and production remain recorded as `published`, the
task becomes `blocked` with `cleanup: failed`, and `factory cleanup <task-id>`
retries only artifact cleanup without republishing anything.

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

Each executed check retains its command verbatim and its numeric exit code. The
task audit stores an ANSI-free summary capped at 8,192 characters; for failures
that summary is the useful tail rather than the start of a large test run. The
complete ANSI-free output is written under the task's private `events`
directory, and the test row's `outputPath` points to that file. This keeps
`state.json` bounded without losing diagnostics.

### Isolated PostgreSQL test databases

Git worktrees isolate files, not external services. Enable per-worktree test
database isolation in the private repository config when concurrent workers use
PostgreSQL:

```json
{
  "testDatabaseIsolation": {
    "enabled": true,
    "provider": "postgresql",
    "databasePrefix": "project_test"
  }
}
```

Connection values are read from the ignored `.env` by default. The configured
PostgreSQL role must have `CREATEDB`; credentials are passed to `psql` through
process environment and are never written to factory state. Each worker gets a
deterministic database such as `project_test_worker_1217492299682856` through
`DB_DATABASE`. The dedicated Claude process and every command it starts inherit
that value, including PHPUnit, whose non-forced XML value does not replace an
existing process variable.

Worker databases survive `held`, `answer`, and retry so the retained worktree
keeps its test state. Confirmed `reject` and successful `cleanup` stop all task
processes first, then drop the database with PostgreSQL `WITH (FORCE)` before
removing Git artifacts. Integration and release checks run through
`scripts/run-isolated-test-command.ps1` and use the persistent, separate
`<prefix>_integrator` and `<prefix>_release` databases. PostgreSQL 13 or newer is
required for forced cleanup.

The full object in `config.default.json` allows custom environment-variable
names, connection file, maintenance database, and `psql` command. Keep this
configuration private; it does not belong in the target repository.

Private config and state writes use a validated temporary file followed by an
atomic same-directory replacement. Readers retry briefly so a scheduler or
child process does not fail during the replacement window.

## Private state

Show the paths for one repository:

```powershell
factory paths -Repository D:\Projects\MotiveHR
```

Open its config:

```powershell
factory config edit -Repository D:\Projects\MotiveHR
```

Private data is stored under:

```text
<plugin>\runtime\projects\<repository-name>-<path-hash>\
```

It includes config, queue state, background-session metadata, captured Stop
events, transcript paths, scheduler identity/heartbeat, and resolved test
commands. Older config is migrated to v7 and state to v9 by adding missing
fields; repository-specific settings are preserved. Test database isolation
remains disabled unless explicitly enabled per repository.

The root `.ps1` files remain implementation entry points for compatibility and
testing. Normal operation uses `factory start`, `factory paths`, `factory
config`, and the other `factory ...` subcommands.

## Tests

Run the local PowerShell runtime suite:

```powershell
.\tests\run-tests.ps1
```

The suite uses a temporary local Git remote and a fake Claude CLI. It does not
call a model, Asana, or a real project remote. It verifies external worktree
creation, background-session metadata, Stop-hook capture, the review gate,
exact-SHA approval, linked-worktree project identity, dynamic concurrency,
scheduler failure/busy recovery, and bounded pipeline-output persistence.

## Safe cleanup

Stop and review the factory first:

```powershell
factory purge -Repository D:\Projects\MotiveHR
factory purge -Repository D:\Projects\MotiveHR -Yes
```

The first command is a preview. Without `-Force`, confirmed cleanup refuses to
remove registered factory worktrees.
This preserves active sessions, uncommitted changes, and commits that still
need review.

Emergency cleanup:

```powershell
factory purge -Repository D:\Projects\MotiveHR -Yes -Force
```

`-Force` may remove registered worktrees and their uncommitted changes. Use it
only after manual inspection.

After each repository is safely cleaned, deleting the plugin directory removes
the factory completely. Normal Claude Code sessions launched without
`start-factory` never see `/factory`.
