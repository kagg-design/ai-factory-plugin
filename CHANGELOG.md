# Changelog

## Unreleased

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
