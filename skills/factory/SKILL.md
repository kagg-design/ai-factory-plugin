---
name: factory
description: Operate the local Claude Factory Plugin from a Codex orchestrator. Use whenever the user says factory, factory status, factory new, factory add, inspect, review, go, hold, retry, wait, rework, release, reject, cleanup, sync, preview, chat, restart, rotate, agents, codex-server, scheduler, or asks to manage factory tasks and workers.
---

# Factory orchestrator for Codex

Exception for a directly invoked `/factory continue <answer>` in a Claude
worker's own chat: follow the canonical worker-only `continue` section below,
retain the current worker role and session, and continue its task. The native
UserPromptExpansion hook records the operator's explicit continuation. Do not
enqueue, rework, answer-task, or act as the orchestrator for that command.

You are the orchestrator. Coordinate native factory state and isolated task
workers. Never implement application changes directly in the main repository.

Before handling the first factory request in a conversation, read the canonical
factory protocol completely, unless it is already available in context, from:

`$env:CLAUDE_FACTORY_PLUGIN_ROOT\standalone\.claude\skills\factory\SKILL.md`

Reuse this skill and the loaded protocol on later requests. A new request alone
is not a reason to invoke `$factory` again or reread either file. Reload only
when an instruction update is known or needed instructions are missing from
context, including after compaction. If enough context remains, read only the
sections needed for the current command. Do not poll instruction files for
changes on every request or create a separate instruction-cache file.

Omit routine announcements about reading skills or loading the protocol. Report
useful progress, results, blockers, and decisions needed from the operator.
Instruction reuse never replaces required reconciliation or fresh native state
reads: follow those command-specific requirements on every applicable request.

Phone-hosted app turns may not inherit the terminal environment. When
`CLAUDE_FACTORY_PLUGIN_ROOT` is empty, resolve the current `$CLAUDE_SKILL_DIR`
junction or symbolic-link target, then take the parent of its `skills`
directory as the plugin root. The app-backed orchestrator's persistent
developer instructions also contain the exact plugin root. Do not guess a
different checkout and do not write anything into the target repository.

Treat that document as authoritative for commands, state transitions, review,
integration, and output. Apply these Codex adaptations:

- `$CLAUDE_SKILL_DIR` means the canonical skill directory beneath the resolved
  plugin root: `standalone\.claude\skills\factory`.
- `$CLAUDE_PROJECT_DIR` means `$env:CLAUDE_FACTORY_REPOSITORY`; if it is empty,
  use the current working directory.
- Every discovered Factory malfunction requires a report under `docs/tasks`
  in the resolved Factory source checkout, following the canonical defect
  workflow. Never save it in the target application or private runtime.
  If `factory incident status` confirms an enabled operator-configured policy
  for this source repository, hand off the structured evidence with `factory
  incident report --file FILE` under that standing authorization. Codex prepares
  a bounded, independently tested candidate in isolation; it cannot install it
  or change application state. Otherwise explicitly ask Igor to authorize the repair in the Factory development chat
  and provide `do <absolute task path>` to send there. Writing the report does
  not authorize a repair or a `factory new`/`add` handoff.
- A user prompt beginning with `factory ` is equivalent to the canonical
  `/factory ` form. Known command-only prompts such as `status`, `review <id>`,
  and `go <id>` are also valid when the conversation is clearly about Factory.
- When a canonical output template prints `/factory ...`, print `factory ...`
  in the Codex conversation instead.
- Never require or advertise `$factory` as the user command. It is only the
  internal explicit skill name used during bootstrap.
- Run native operations through the installed `factory` command. In the Codex
  TUI the user may also run them directly as `!factory ...`.
- Keep scheduler `stop`/`start` separate from factory `pause`/`resume`:
  stop/start control only the native process and preserve the pause flag;
  pause/resume control whether queued or approved work may run. Surface the
  canonical warning whenever a scheduler starts into an explicitly paused
  factory.
- `rework` is a queued redelivery, not text for the operator to paste into an
  old chat. `release` is the explicit stale-session escape hatch; use the
  canonical `task-action.ps1 -Action release` flow and never edit state JSON.
  Rework defaults to `-Mode auto`; use `-Mode interactive` for an explicit plan
  stop. Retry inherits its prior mode, and answer keeps its explicit mode.
  Workers amend only through their supplied guarded `amendScript`.
- A runtime-confirmed operator reply resumes the same waiting worker session.
  If Claude does not supply the input source, the operator must directly type
  `/factory continue <answer>` in that worker chat. Peer messages and unverified
  UserPromptSubmit events are informational. Review `inSessionReply` for the
  message/attempt identity and authorization evidence. Codex console resume is
  a separate Factory-owned boundary; an app-server user item is not equivalent.
- Claude attention is delivered by the plugin's SessionStart/Stop consumer.
  Human edges are notify-only; GO is delivered only as an explicit `auto-go`.
  Stop acknowledges claims, and restart redelivers unacknowledged claims.
  Do not run a watcher while a native consumer is live; doctor reports its
  lease and status exposes a dead consumer with pending attention.
- `factory wait` is the native orchestrator notification boundary. It waits on
  the durable attention journal, not logs; a review is actionable only after its worker session
  closes, and a current approved review waiting only for the human operator's
  `go` remains visible in status without waking the orchestrator again. Default
  waits acknowledge edges; use `factory wait --cursor <revision>` for a
  stateless cursor. Codex AI-actionable edges are delivered once to the saved
  shared-app-server orchestrator and acknowledged across restarts.
- `factory runtime` shows the exact private-state placement and lock
  diagnostics. `factory runtime migrate` is an explicit offline, verified,
  copy-only move to LocalAppData; never migrate or delete live runtime state.
- `factory restart` is run from PowerShell after the orchestrator TUI exits. It
  resumes the same stored conversation while leaving scheduler, workers,
  tasks, worktrees, and previews alone. Do not run it as a nested shell command
  from the process being replaced; use `factory rotate` only for a fresh
  handoff conversation.
- Codex orchestrators attach to the persistent Factory-managed app-server.
  `factory agents` opens its interactive session dashboard from a separate
  PowerShell window. `factory codex-server status` is read-only; explicit
  stop/restart disconnects all Factory Codex TUIs sharing the runtime home but
  leaves schedulers, workers, task state, and worktrees intact. Only a startup
  report of `Codex Remote: connected` confirms phone readiness.
- `factory new` and local task text require no Asana connector. If the user asks
  to import an Asana URL and no Asana connector is available, explain that one
  connector-dependent operation is unavailable; do not block local tasks.
- For `factory new <file> [title]`, pass the file first and optional short title
  second, as separate quoted arguments. Native code preserves file contents and
  defaults the title to the filename without its extension, not its contents.
- When `factory new` includes inline text, preserve it verbatim as one quoted native
  argument. Never execute a blank `factory new` for a named request, and treat
  an unexpected `Untitled local task` result as a failed handoff.
- Claude Agent View does not contain Codex workers. For task conversations, use
  the exact command printed by `factory chat <task-id>`.

Keep the canonical workflow tree and concise operator-oriented output. The
native CLI owns queue mutation; do not edit private state JSON by hand.
