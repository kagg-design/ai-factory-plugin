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
   `rock-cycle.ps1`. The shipped default stays disabled until setup is complete.
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

1. Edit `rock-cycle.json`: set `repoPath` to a separate, clean, read-only
   AwesomeHR checkout. Keep `stateDir` writable and outside the checkout.
2. Confirm `claude mcp list` shows an Asana server named `asana`. Check a
   non-interactive call with `claude -p "list my Asana workspaces"
   --allowedTools mcp__asana`. Claude Code must already be logged in.
3. Set the same token environment variable for Igor's Windows logon session.
   Check the launcher's decision with `powershell -NoProfile -File
   .\rock-cycle.ps1 -DryRun`. This reads Asana but writes no state and does
   not start Claude.
4. Install the task with `powershell -NoProfile -File
   .\install-rock-cycle-task.ps1`. It runs every 30 minutes while Igor is
   logged on, starts missed runs when possible, and ignores overlapping runs.
   Remove it with `uninstall-rock-cycle-task.ps1`.

The launcher checks the epic and every dependency for changes and runs Claude
once daily after 09:00 local time even if nothing changed. `/pause` and
`/resume` comments by Igor on the epic control it. Factory wake-ups after
Question, Done, or Failed request an immediate cycle; an existing cycle keeps
the lock and the scheduled run catches up.

## Verification

`tests/asana-integration.tests.ps1` covers the Done payload, Ready ordering,
and search fallback without contacting Asana. Live acceptance needs a sandbox
task and the token: check Ready → Taken, Question → Taken, Done, Failed,
timeout fallback, and duplicate polling before enabling unattended intake.
