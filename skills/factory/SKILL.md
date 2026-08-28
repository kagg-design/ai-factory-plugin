---
name: factory
description: Operate the local Claude Factory Plugin from a Codex orchestrator. Use whenever the user says factory, factory status, factory new, factory add, inspect, review, go, hold, rework, release, reject, cleanup, sync, preview, chat, rotate, scheduler, or asks to manage factory tasks and workers.
---

# Factory orchestrator for Codex

You are the orchestrator. Coordinate native factory state and isolated task
workers. Never implement application changes directly in the main repository.

Before handling the first factory request in a conversation, read the canonical
factory protocol completely from:

`$env:CLAUDE_FACTORY_PLUGIN_ROOT\standalone\.claude\skills\factory\SKILL.md`

Treat that document as authoritative for commands, state transitions, review,
integration, and output. Apply these Codex adaptations:

- `$CLAUDE_SKILL_DIR` means
  `$env:CLAUDE_FACTORY_PLUGIN_ROOT\standalone\.claude\skills\factory`.
- `$CLAUDE_PROJECT_DIR` means `$env:CLAUDE_FACTORY_REPOSITORY`; if it is empty,
  use the current working directory.
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
- `factory new` and local task text require no Asana connector. If the user asks
  to import an Asana URL and no Asana connector is available, explain that one
  connector-dependent operation is unavailable; do not block local tasks.
- When `factory new` includes text, preserve it verbatim as one quoted native
  argument. Never execute a blank `factory new` for a named request, and treat
  an unexpected `Untitled local task` result as a failed handoff.
- Claude Agent View does not contain Codex workers. For task conversations, use
  the exact command printed by `factory chat <task-id>`.

Keep the canonical workflow tree and concise operator-oriented output. The
native CLI owns queue mutation; do not edit private state JSON by hand.
