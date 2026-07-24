# Claude Asana Factory

A self-contained, removable Claude Code plugin for running a continuous queue of Asana development tasks.

It is intentionally **not copied into the target repository**. The repository does not receive skills, agents, hooks, README files, or Claude settings.

## What it does

- Accepts one or more Asana task URLs.
- Keeps a persistent per-repository queue.
- Runs several independent fixes in parallel.
- Creates a separate Git worktree and branch for every worker.
- Reads task details through the configured Asana connector.
- Requires focused tests, lint/static analysis, and one final commit.
- Integrates completed tasks into `develop` one at a time.
- Runs integration tests and pushes `develop`.
- Optionally promotes `develop` to `master`, runs release tests, and pushes `master`.
- Removes worker worktrees only after remote verification.
- Accepts more Asana URLs while existing tasks are still running.

## Why this version is removable

The plugin is loaded only by the supplied launcher:

```powershell
claude --plugin-dir <this-folder>
```

It is not installed globally and it does not modify:

- `<repository>/.claude/`
- `<repository>/.gitignore`
- `<repository>/CLAUDE.md`
- user-level Claude settings

To stop using it, exit the factory session and stop launching Claude through `start-factory.ps1`.

To remove it completely:

1. Run `cleanup-project.ps1` for every repository used by the factory.
2. Delete this plugin folder.

Normal Claude Code sessions remain unchanged.

## Requirements

- Windows PowerShell 5.1 or PowerShell 7.
- Git.
- Claude Code 2.1.208 or newer is recommended.
- An authenticated Asana connector available in Claude Code.
- Remote branches named `develop` and `master`, unless changed in the private project configuration.

## Folder layout

Extract the plugin anywhere outside the repository, for example:

```text
D:\Tools\claude-asana-plugin\
```

Target repositories remain separate:

```text
D:\Projects\MotiveHR\
D:\Projects\AnotherProject\
```

Worker worktrees are created outside the repository:

```text
D:\Projects\.claude-factory-worktrees\
    MotiveHR-a1b2c3d4\
        worker-bright-oak-a1b2c3\
        factory-integrator\
        factory-release\
```

There is no nested `.claude/worktrees` tree and no recursive directory structure.

## What `start-factory.ps1` does

Run it from the extracted plugin directory:

```powershell
.\start-factory.ps1 -Repository D:\Projects\MotiveHR
```

The script performs these steps:

1. Resolves the supplied path to the actual Git repository root.
2. Sets `CLAUDE_FACTORY_HOME` to this plugin folder's private `runtime` directory.
3. Creates or reuses a repository-specific runtime directory identified by the repository name and a short hash of its full path.
4. Creates the private `config.json`, `state.json`, and external worktree root when they do not yet exist.
5. Prints the repository, configuration, state, and worktree paths before Claude starts.
6. Changes the current directory to the repository root.
7. Starts a dedicated Claude Code process with this plugin loaded through `--plugin-dir`, `auto` permission mode, and Remote Control enabled under the supplied session name.

It does **not** copy anything into the repository, create a worker task, merge code, or push branches by itself. After Claude opens, add tasks with `/asana:factory ...` or resume an existing queue with `/asana:factory resume`.

## Start

From the plugin directory:

```powershell
.\start-factory.ps1 -Repository D:\Projects\MotiveHR
```

The launcher:

- initializes private per-repository configuration and state;
- changes to the repository root;
- starts a dedicated Claude Code session with this plugin only;
- enables Remote Control;
- does not install or copy the plugin into the repository.

Check the Asana connector:

```text
/mcp
```

Add tasks:

```text
/asana:factory https://app.asana.com/0/.../... https://app.asana.com/0/.../...
```

Add more tasks later with the same command.

## Commands

```text
/asana:factory status
/asana:factory pause
/asana:factory resume
/asana:factory retry <task-id>
/asana:factory inspect <task-id>
/asana:factory stop
```

The skill is namespaced because it comes from a plugin. It cannot collide with an existing `/factory` skill.

## Configuration

Show the per-repository paths:

```powershell
.\show-project-paths.ps1 -Repository D:\Projects\MotiveHR
```

Open the private configuration:

```powershell
.\edit-project-config.ps1 -Repository D:\Projects\MotiveHR
```

The configuration is stored under this plugin package's `runtime` directory, not in the repository.

Important defaults:

```json
{
  "concurrency": 3,
  "developmentBranch": "develop",
  "productionBranch": "master",
  "productionMode": "merge-develop",
  "allowUnrelatedDevelopCommitsToProduction": true
}
```

`merge-develop` promotes the complete current `develop` branch to `master`.
Use `task-only` to promote only the factory task:

```json
{
  "productionMode": "task-only",
  "allowUnrelatedDevelopCommitsToProduction": false
}
```

For deterministic test execution, specify commands explicitly:

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

When the arrays are empty, Claude infers canonical commands from repository documentation and CI files, then stores the resolved commands in private project state.

## Worktree isolation

The plugin replaces Claude Code's default worktree location for this dedicated session. Worker worktrees are created as siblings of the repository under `.claude-factory-worktrees`.

Each worker branch is prefixed with:

```text
factory-worker/
```

A plugin hook blocks worker branches from pushing, merging, rebasing, deleting worktrees, or switching to shared branches. Integration remains the orchestrator's responsibility.

The custom worktree hook also copies configured ignored files such as `.env` when they exist and are ignored by Git.

The custom `WorktreeCreate` hook affects all worktree-isolated agents in this dedicated factory session. Do not use this session for unrelated worktree workflows. Use a normal Claude Code session for ordinary interactive development.

## What `cleanup-project.ps1` does

Run it only after the factory is stopped and completed work has been reviewed:

```powershell
.\cleanup-project.ps1 -Repository D:\Projects\MotiveHR
```

Without `-Force`, the script is deliberately conservative:

1. Resolves the same private runtime and worktree paths used by the launcher.
2. Reads Git's registered worktree list.
3. Stops with an error if factory worktrees are still registered, so active or recoverable work is not removed accidentally.
4. Prunes stale Git worktree metadata.
5. Removes the repository's empty external factory worktree directory when safe.
6. Removes the repository-specific private configuration, queue state, resolved test commands, and task history from the plugin's `runtime/projects` directory.
7. Removes the shared `.claude-factory-worktrees` container only when it has become empty.

It does **not** delete the target repository, ordinary branches, remote branches, pushed commits, or the plugin itself.

`-Force` tells the script to forcibly unregister and remove factory worktrees and recursively remove their runtime directory. Use it only after manually checking for uncommitted or otherwise valuable work:

```powershell
.\cleanup-project.ps1 -Repository D:\Projects\MotiveHR -Force
```

Deleting the plugin folder after cleanup removes the plugin completely. A normal Claude Code session was never modified.

## Operational notes

- Keep the dedicated Claude Code process running while work is in progress.
- The queue survives session restarts because state is stored under `runtime/projects` in this plugin package.
- Resume by running `start-factory.ps1` again and then `/asana:factory resume`.
- Background agents can be inspected with `/tasks`.
- A normal Claude Code session launched without `--plugin-dir` does not see this plugin.
