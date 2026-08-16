# Changelog

## Unreleased
- Added a source-neutral native intake boundary. Asana is now read-only from
  the orchestrator: AI fills a versioned normalized envelope, while native code
  validates identity and content, deduplicates under the state lock, atomically
  inserts tasks, and wakes the scheduler. Added `factory add --file
  <task.json>`, state v6 source migration, synthetic intake coverage, and
  operator documentation for future adapters.
- Added a formal exact-SHA review contract and native `factory go` publication
  pipeline. Reviews now pin both remote bases, trusted integration/release
  commands, and a plan hash; the native scheduler serially merges, tests,
  pushes development and production without force, verifies reachability, and
  runs guarded cleanup without an AI integration turn.
- Replaced recurring AI cron polling with one hidden native PowerShell scheduler
  per repository. It reconciles workers, fills capacity, records heartbeat and
  bounded backoff, starts with the orchestrator, and sleeps without model calls.
  Added unified
  `factory start`, `paths`, `config`, scheduler/control, and guarded project
  `purge` commands over the compatibility `.ps1` implementations.
- Preserved UTF-8 across Windows PowerShell 5.1 hook stdin and redirected
  Claude CLI output, added safe display-only repair for legacy CP437 mojibake,
  and stopped review cards from presenting stale plan questions as reasons.
- Added a native `factory` PowerShell CLI for deterministic reads plus `hold`,
  confirmed `reject`, safe `cleanup`, and concurrency changes, including direct
  `!factory ...` use from the orchestrator and continuous-tree output. Contextual
  Tab completion now exposes canonical commands and saved task IDs, while
  `factory completion` diagnoses or enables PSReadLine menu completion without
  editing the user's profile.
- Added opt-in PostgreSQL test-database isolation: every worker task receives a
  deterministic private database through its process environment, integration
  and release commands have separate databases, and final cleanup/rejection
  drops worker databases only after their sessions stop.
- Removed every completed attempt of a closed task from Agent View during
  `answer`, `reject`, and `cleanup`; fallback-launch strays are now removed
  immediately. Cleanup verifies live processes are gone before touching their
  worktrees, preserves JSONL transcripts, and reports per-ID `claude rm`
  failures without rolling back `done` state.
- Reused one exact per-repository orchestrator conversation across repeated
  startup, attaching its Agent View row or resuming its stored UUID, with
  explicit `-New` replacement semantics.
- Required `/factory status` task nodes and completed history to show both the
  untruncated task title and full canonical source URL.
- Removed completed worker sessions from Claude Agent View after successful
  `/factory cleanup`, with non-destructive warning behavior if session removal
  is unavailable.
- Added version-scoped inline-agent and additive system-prompt-file fallbacks
  for Claude Code releases that cannot resolve agents with `--bg --agent`,
  including verified stray-session shutdown, positive Agent View confirmation,
  per-path capability caching, and audited frontmatter deviations.
- Added PowerShell 5.1-safe native argument quoting and replaced `Get-FileHash`
  with .NET SHA-256 so worker launch is independent of ambient `PSModulePath`.
- Extended `/factory doctor` with PowerShell and worker-resolution diagnostics,
  and made the worker Git guard fail closed when its safety payload cannot be
  parsed.
- Changed `/factory reject` into a confirmed final discard that stops the
  worker, removes its worktree, branch, and private runtime metadata, and
  forgets the task; added `--yes` and artifact-preserving `--keep` modes.
- Redesigned `/factory status` as one continuous Unicode workflow tree with
  exact next commands, state filters, explicit session availability, hold
  reasons, and completed history collapsed by default.
- Persisted each full worker launch prompt as a private UTF-8 runtime file and
  replaced the native command-line payload with a short file pointer.
- Hardened session reconciliation against stale same-name Agent View rows and
  made launch record the authoritative full session UUID when available.
- Added recoverable machine-held sessions, `/factory answer`, and an idempotent
  durable decisions file for relaunching retained worker worktrees.
- Made missing `factory:worker` agent warnings fail closed instead of silently
  running the default template.
- Hardened cleanup so junctions and other reparse points are unlinked without
  traversing external targets.

- Added `/factory help [command]` with compact grouped guidance and per-command
  details, and replaced the overflowing slash-command argument hint with the
  short `help | <command>` form.
- Added `/factory sync <task-id>` to rebase one validated task commit onto the
  latest configured development branch in its existing worker worktree, rerun
  checks, and record a new reviewable SHA without creating a preview worktree.
- Added the recoverable `syncing` state so interrupted validation cannot be approved.
- Added `/factory cleanup <task-id>` for verified removal of completed worker
  worktrees and local branches, including Windows long-path residue handling.
- Added `/factory add [--auto] <URLs>` as an explicit compatibility alias for
  adding tasks; bare URLs remain an automatic-start compatibility form.
- Added the per-repository `conversationLanguage` setting for orchestrator,
  scheduler, and newly launched worker conversations while keeping code, logs,
  commands, source quotations, and project documentation unchanged.
- Named the lead Claude Code session `Claude Factory Orchestrator` so it is easy
  to find in session and resume lists.
- Renamed the product and internal plugin namespace from Asana Factory to Claude Factory.
- Fixed Claude Code 2.1.218 background launches by ignoring benign stderr warnings,
  removing the unsupported `--bg --session-id` combination, and reconciling the
  current `sessionId/status/name/cwd` agent schema.
- Made `-Repository` optional; `start-factory` now defaults to the current directory.
- Exposed the public command as `/factory` through a bundled standalone skill loaded
  by `start-factory.ps1`; no personal or target-repository files are installed.
- Renamed internal components to `factory:worker` and `/factory:tick`.
- Kept Asana as the current intake adapter pending the source-adapter redesign.

## 3.0.0

- Replaced one-shot worker subagents with first-class Claude Code background
  sessions that can be opened, interrupted, and continued through Agent View or
  `claude attach`.
- Added interactive `start` and autonomous `start --auto` modes.
- Added a read-only planning gate for interactive starts.
- Added dynamic per-repository concurrency changes without stopping live
  workers.
- Added background session IDs, full session UUIDs, transcript persistence,
  Stop-hook event capture, and Git-backed result reconciliation.
- Added explicit `awaiting-review` and immutable-SHA `go` approval. Unapproved
  worker results are never integrated.
- Added `chat`, `transcript`, `review`, `hold`, `rework`, and `reject` workflows.
- Silenced review-only queues by removing the recurring scheduler until new
  work or approval reactivates it.
- Added launcher support for `-Resume`, `-Continue`, and `-Model`.
- Added `/asana:factory doctor` diagnostics for CLI, plugin, Git, runtime, Agent View, locks, scheduler, and Asana connectivity.
- Added a per-repository launcher lock that prevents two factory lead sessions.
- Added schema migration from v2 private runtime files without overwriting
  repository-specific configuration.

## 2.1.0

- Shortened the plugin namespace from `/asana-factory:*` to `/asana:*`.
- The primary command is now `/asana:factory`.
- Expanded the English README with exact behavior and safety notes for
  `start-factory.ps1` and `cleanup-project.ps1`.
- Renamed the distributable package folder to `claude-asana-plugin`.

## 2.0.0

- Repackaged the factory as a self-contained Claude Code plugin.
- Removed all installation into target repository `.claude` directories.
- Added session-only loading through `--plugin-dir`.
- Added external sibling worktree placement.
- Added private per-repository runtime state and configuration.
- Added safe runtime cleanup tooling.
- Namespaced commands as `/asana:factory` and `/asana:factory-tick`.
