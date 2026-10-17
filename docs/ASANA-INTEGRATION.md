# Factory and Asana

The optional integration uses the [RAD] Central Ticket Intake
[board](https://app.asana.com/1/14748072439266/project/1215506997644941/board/1215507205009630).
The factory and rock launcher use a personal access token through the Asana API.
ChatGPT access to Asana is not required.

## Factory setup

1. Set `FACTORY_ASANA_TOKEN` for the Windows account that runs the factory.
   Keep the token out of files, logs, and comments.
2. Run `factory config path` for the target repository. Set `asana.enabled`
   to `true` and `launcher.path` to the absolute path of `rock-cycle.ps1`.
   The shipped default is disabled until setup is complete.
3. Preview candidate tasks without writing local state or Asana:

   ```powershell
   powershell -NoProfile -File scripts\asana-poller.ps1 -Repository C:\path\to\awesomehr -DryRun
   ```

The scheduler polls every five minutes while the factory is active. It claims
only tasks with Factory = Ready, in priority and creation order, up to two
active Asana workers. A task whose description begins `Repo: owner/name` is
skipped when the configured repository's Git remote identifies another repo.
A task without a Factory value keeps the existing terminal flow.

The factory starts one rock launcher after Question, Done, or Failed. The
launcher chooses orchestrators from the task's Asana dependents. Factory
comments begin with `TAKEN (factory):`, `QUESTION (factory):`,
`DONE (factory):`, or `FAILED (factory):`. Orchestrator comments identify
their speaker with `[access-orchestrator]` or `[billing-orchestrator]`;
answers begin `ANSWER (access-orchestrator):` or
`ANSWER (billing-orchestrator):`. An untagged comment is Igor's. When answers
conflict, Igor's answer takes precedence.

Questions resume only after Factory returns to Taken and every subsequent
comment is passed to the worker. After 24 hours, the terminal fallback posts
`ANSWER (Igor via terminal):`. A task that says
`Merge gate: ask Igor before merging` still requires Igor's explicit YES
before publication. Done is reported only after the native publication
pipeline reaches done.

## Rock launcher setup

1. Edit `rock-cycle.json`. It defines the named `access` and `billing`
   orchestrators, their epic GIDs, and their `repoPath` and `extraDirs`.
   Its paths point to the dedicated local checkouts under
   `C:\laragon\www\Projects\rock-readonly`; update them if those checkouts move.
   Several orchestrators may share the same checkout because this launcher
   runs their Claude processes sequentially. Its global mutex also prevents
   separate launcher processes from overlapping.
2. Confirm `claude mcp list` shows Asana connected. Check a
   non-interactive call with
   `claude -p "list my Asana workspaces" --allowedTools mcp__asana`.
   Claude Code must already be logged in.
3. Preview both decisions, or one named orchestrator:

   ```powershell
   powershell -NoProfile -File .\rock-cycle.ps1 -DryRun
   powershell -NoProfile -File .\rock-cycle.ps1 -Epic access -DryRun
   powershell -NoProfile -File .\rock-cycle.ps1 -Epic billing -DryRun
   ```

   `-EpicGid <gid>` remains accepted as a compatibility alias for a
   configured epic. `-Task <gid>` looks up that task's Asana dependents and
   selects every configured epic among them. If none match, both epic change
   checks run without forcing Claude. `-DryRun` reads Asana but writes no
   state and does not start Claude.
4. Install one scheduled task to run both orchestrators every 30 minutes:

   ```powershell
   powershell -NoProfile -File .\install-rock-cycle-task.ps1
   ```

   It runs only while Igor is logged on, starts missed runs when possible,
   and ignores overlapping scheduled runs. Remove it with
   `uninstall-rock-cycle-task.ps1`.

The launcher checks each epic and its dependencies for changes. A task may be
owned by one orchestrator as an epic child and watched by another as a
dependency. Both see its changes; the watcher is instructed to treat it as
read-only. Claude's Asana MCP permissions are broader than this instruction,
so correct ownership still depends on the epic instructions and the agent
following them. Claude runs in `dontAsk` mode with Edit, Write, and NotebookEdit
denied. The launcher runs access, then billing, one Claude process
at a time. Each has `stateDir\<name>` for its lock, state, and logs.
An untagged `/pause` or `/resume` comment by Igor on one epic controls only
that orchestrator. Each runs once daily after 09:00 local time even without
other changes.

## Verification

`tests/asana-integration.tests.ps1` covers factory fields, repo routing,
comment tags, named rock selection, pause handling, and pagination without
contacting Asana. Live acceptance needs sandbox tasks and the token: verify
Ready → Taken, Question → Taken, Done, Failed, timeout fallback, duplicate
polling, shared-task cross-wakes, and separate pause controls before
enabling unattended intake.
