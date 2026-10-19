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
active Asana workers. Each private config records its own `repo` (initialized
from the Git remote, or checkout name for local remotes). The first line
`Repo: owner/name` selects a task's repository; otherwise `defaultRepo`
(`awesomehr`) owns it. Other factories skip it before Taken, branches or
worktrees. Manual `factory add <asana-link>` and `--file` intake refuse another
repo unless `--force` is explicit. A task without a Factory value keeps the
existing terminal flow. Ready is compared by option GID, reread before claim,
and Taken must read back successfully before work starts.

A new Ready after a settled run snapshots the previous run in `previousRuns`,
clears its result/review/approval, and queues the current description into a new
attempt and worktree. Old artifacts remain available for inspection. Use a
`Start-from: <commit>` directive to choose the fresh run's base. An active old
worker must be stopped/released before a fresh claim.

## Quality gates

Repository profiles under `repos` configure `securityCommand` and optional
`securityPresentWhen`. AwesomeHR defaults to `composer security`, present only
when `composer.json` defines `scripts.security`; auditors have no command.
Workers run `securityScript` after tests. The native pipeline independently
checks the worker worktree before constructing candidates and after candidate
tests, before publishing. Nonzero security exits set Failed and retain the
worktree. Missing commands are skipped with `Security: command not present yet`;
unconfigured repositories report `Security: not configured for this repo`.
DONE includes the final task HEAD and the security summary.

Security commands must mask secrets and prefix summary lines with `Security:`,
`Summary:` or `[security-summary]`. Only these lines enter Factory state and
Asana; raw scanner output is never written to a Factory log. Workers must ask
`QUESTION (factory):` before baselining or suppressing a finding. They must emit
a new result after any rebase or amend. The guarded amend script invalidates
older results; sync finalize records the final rebased HEAD.

`Merge gate: ask Igor before merging` requires an additional confirmation for
the exact SHA, including for direct approvals. Factory posts `MERGE GATE
(factory): ready to merge ...`, then waits. Igor can comment `/merge` on Asana
or run `factory merge <id> --yes`. Factory records `Igor confirmed
(terminal|comment)` on Asana before merging. Tagged comments never count as
Igor. Changing the SHA invalidates its confirmation. Status and native attention
show this as a human decision; orchestration must never supply `--yes` itself.

`stallHours` defaults to 2. Session/transcript/event activity, rather than poll
heartbeats, controls the stall deadline. Stalled workers become Failed with
`stalled, no activity since ...`; their exact session is stopped outside the
state lock, retaining the checkout, branch and transcript for inspection.

Copied `.env*` files blank `blankEnvKeys`: `ASANA_ACCESS_TOKEN`, `ACCESS_*`,
`BILLING_*`, `GITHUB_APP_*`, `GCS_KEY_FILE`, `*_TOKEN`, `*_SECRET`, and
`*_API_KEY` by default. `APP_KEY` and `DB_*` remain intact. Logs contain blanked
key names only. This applies to worker, hook-created and pipeline worktrees.

## Escaped-defect metrics

```powershell
.\factory-metrics.ps1 -Repository C:\path\to\awesomehr -DryRun
.\factory-metrics.ps1 -Repository C:\path\to\awesomehr -Since 2026-10-12 -Until 2026-10-19T10:05:00Z -Post
.\install-factory-metrics-task.ps1 -Repository C:\path\to\awesomehr
```

The installer registers Monday 09:00 local with `-Post`, using Windows
PowerShell 5.1 and the logged-in user's environment PAT. Run the installer once
for the shared board, using the factory config whose `metricsTaskGid` should
receive the report (default `1219642983524480`). It does not run the report
while installing. Both scripts are deterministic PowerShell with no AI calls.

Metrics search every Factory-valued task, including completed tasks, discover
the Type=Bug option at startup, and read comments for timing/count metrics.
Asana search uses a created-at cursor, with project-list pagination for full
timestamp buckets ([API contract](https://developers.asana.com/reference/searchtasksforworkspace)).
Bug descriptions use `Escaped-from: <Done gids>`,
`Found-in: verification|ci|stage|prod|external`, and optional `Regression: yes`.
Lines override the five historical seeds. Reporter-tagged bugs without origins
are counted as unknown and listed for repair. Invalid origins and malformed
lines are diagnosed without stopping the report.

Reports live under the selected factory's private state directory:
`metrics/<repo>/escaped-defects.csv`, `weekly.csv`, `latest.md`, plus `_all`.
Each defect counts once in every origin project and once in totals. Fallback
defects use the bug's repo because their origins are unknown. New repos appear
on the first report that sees one of their tasks.

Window boundaries are inclusive UTC. Done uses `completed_at`; defects use the
bug's `created_at`. Escape rate is the share of the period's Done cohort with a
defect found by Until; defects/Done divides defects found in the period by that
cohort. Cycle time uses the latest TAKEN/DONE pair per completed task;
transitional tasks without both are excluded and counted. Medians and p90 use
linear interpolation. Failed-now and FAILED-comment counts are displayed
separately because they can overlap; weekly `failed` is their sum. Time to find
uses each valid bug/origin pair. Reports use current board fields with timestamp
cutoffs; the API does not reconstruct historical Factory field values.

`-Post` appends one weekly row per project and posts exactly one
`[factory-metrics]` comment, containing all projects and totals. An empty
`metricsTaskGid` skips posting. Without `-Post`, files are refreshed without a
weekly row or comment. `-DryRun` only prints, including when combined with
`-Post`: no files, initialization, state or Asana writes.

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
`ANSWER (Igor via terminal):`. Done is reported only after the native
publication pipeline reaches done.

## Rock launcher setup

1. Edit `rock-cycle.json`. It defines the named `access` and `billing`
   orchestrators, their epic GIDs, and their `repoPath` and `extraDirs`.
   Its paths point to the dedicated local checkouts under
   `C:\laragon\www\Projects\rock-readonly`; update them if those checkouts move.
   Several orchestrators may share the same checkout because this launcher
   runs their Claude processes sequentially. Its global mutex also prevents
   separate launcher processes from overlapping.
2. Confirm `claude mcp list` shows Asana connected. For the connected
   `claude.ai Asana` server, tool names begin `mcp__claude_ai_Asana__`.
   Check a
   non-interactive call with
   `claude -p "read my Asana epic" --allowedTools mcp__claude_ai_Asana__get_task`.
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
Each Claude process has a 90-minute limit. The interactive launcher prints
when it checks Asana, when Claude starts, and once per minute while it runs.
An untagged `/pause` or `/resume` comment by Igor on one epic controls only
that orchestrator. Each runs once daily after 09:00 local time even without
other changes.

## Verification

`tests/asana-integration.tests.ps1` covers factory fields, repo routing,
comment tags, named rock selection, pause handling, and pagination without
contacting Asana. `tests/quality-gates.tests.ps1` adds seeded metrics, malformed
lines, cross-project origins, dry runs/posts, Ready claims, merge confirmation,
environment redaction and stalled-session fixtures. The publication pipeline
and worker-chat suites cover security failure before push, pending merge gates
and recording the final amended HEAD. Live acceptance needs sandbox tasks and
the token: verify
Ready → Taken, Question → Taken, Done, Failed, timeout fallback, duplicate
polling, shared-task cross-wakes, and separate pause controls before
enabling unattended intake.
