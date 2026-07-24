# Changelog

## 2.1.0

- Shortened the plugin namespace from `/asana-factory:*` to `/asana:*`.
- The primary command is now `/asana:factory`.
- Expanded the English README with exact behavior and safety notes for `start-factory.ps1` and `cleanup-project.ps1`.
- Renamed the distributable package folder to `claude-asana-plugin`.

## 2.0.0

- Repackaged the factory as a self-contained Claude Code plugin.
- Removed all installation into target repository `.claude` directories.
- Added session-only loading through `--plugin-dir`.
- Added external sibling worktree placement through a `WorktreeCreate` hook.
- Added private per-repository runtime state and configuration.
- Added safe runtime cleanup tooling.
- Changed all user documentation to English.
- Namespaced commands as `/asana:factory` and `/asana:factory-tick`.
