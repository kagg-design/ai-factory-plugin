# Factory and Asana

The optional Asana integration uses the [RAD] Central Ticket Intake project
(`1215506997644941`). The board is
<https://app.asana.com/1/14748072439266/project/1215506997644941/board/1215507205009630>.
It talks directly to Asana's API with a personal access token; ChatGPT access
to Asana is not required.

## Factory setup

1. Set `FACTORY_ASANA_TOKEN` in the environment that starts the factory. Keep
   the token out of config files and logs. The account must be able to read and
   update tasks in the project.
2. Run `factory config path` for the target repository. In that private config,
   set `asana.enabled` to `true` and `launcher.path` to the absolute path of
   `rock-cycle.ps1`. For multiple rock epics, set `launcher.configPaths` to
   the absolute paths of their JSON configs. The shipped default stays disabled
   until setup is complete.
3. The factory's scheduler polls every five minutes. To inspect candidates
   without changing local state or Asana, run:

   ```powershell
   powershell -NoProfile -File scripts\asana-poller.ps1 -Repository C:\path\to\awesomehr -DryRun
   ```

   The scheduler invokes the poller and question/completion synchronizer while
   the factory is active. A paused factory does not poll or sync.

Tasks with Factory = Ready are claimed in priority and creation order, with a
maximum of two active Asana workers. A task with no Factory value retains the
existing terminal flow. Asana questions are posted as task comments; the worker
resumes after the field returns to Taken and all later comments are collected.
The 24-hour fallback opens a terminal prompt for Igor. A task whose description
contains `Merge gate: ask Igor before merging` requires `YES` in the `factory
go` terminal before publication. Done is reported only after the native
publication pipeline reaches its done state.

## Rock launcher setup

1. Edit `rock-cycle.json` for epic `1219601019224697`, and
   `rock-cycle-1219601069124635.json` for epic `1219601069124635`. Set each
   `repoPath` to a clean, read-only AwesomeHR checkout. Keep `stateDir`
   writable and outside the checkout. The launcher puts each epic's lock,
   state and logs in its own `stateDir\<epicGid>` directory and uses a separate
   mutex. If both configs point to the same checkout, their permitted
   `git fetch` commands can contend for Git metadata; use separate checkouts
   for full parallelism, or remove `Bash(git fetch *)` from `allowedTools`.
2. Confirm `claude mcp list` shows an Asana server named `asana`. Check a
   non-interactive call with `claude -p "list my Asana workspaces"
   --allowedTools mcp__asana`. Claude Code must already be logged in.
3. Set the same token environment variable for Igor's Windows logon session.
   Check the launcher's decision with `powershell -NoProfile -File
   .\rock-cycle.ps1 -DryRun -ConfigPath .\rock-cycle.json` and repeat with
   `-ConfigPath .\rock-cycle-1219601069124635.json`. These read Asana but
   write no state and do not start Claude.
4. Install one scheduled task per config:

   ```powershell
   powershell -NoProfile -File .\install-rock-cycle-task.ps1 -ConfigPath .\rock-cycle.json
   powershell -NoProfile -File .\install-rock-cycle-task.ps1 -ConfigPath .\rock-cycle-1219601069124635.json
   ```

   The task name includes the epic GID, so the second install does not replace
   the first. Both run every 30 minutes while Igor is logged on, start missed
   runs when possible, and ignore overlap within the same epic. Remove each
   with `uninstall-rock-cycle-task.ps1 -ConfigPath <path>`.

The launcher checks the epic and every dependency for changes and runs Claude
once daily after 09:00 local time even if nothing changed. `/pause` and
`/resume` comments by Igor on the epic control it. Factory wake-ups after
Question, Done, or Failed request an immediate cycle. When `launcher.configPaths`
lists both configs, the factory starts both launchers and each ignores a hint
task outside its epic and direct dependencies. An existing cycle keeps its
own lock and the scheduled run catches up. `-Task` is a hint and wake-up filter;
`epicGid` and `epicUrl` in the chosen config select the root task. This is a
launcher scope check and prompt instruction, not an Asana permission boundary
for Claude's MCP access.

## Verification

`tests/asana-integration.tests.ps1` covers the Done payload, Ready ordering,
and search fallback without contacting Asana. Live acceptance needs a sandbox
task and the token: check Ready → Taken, Question → Taken, Done, Failed,
timeout fallback, and duplicate polling before enabling unattended intake.
