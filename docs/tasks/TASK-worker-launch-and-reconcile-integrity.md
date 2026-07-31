# TASK — worker launch payload, session binding, and destructive cleanup

Author: orchestrator session, 2026-07-31. Everything below was observed on a live run of
this plugin against the `motivehr` repository today; nothing here is speculative unless it
says so explicitly.

## Context you need before touching anything

- Plugin root: `C:\laragon\www\Projects\claude-factory-plugin`. Scripts in `scripts\`,
  user-facing command surface in `skills\factory\SKILL.md`, worker agent in `agents\worker.md`.
- Private runtime state: `runtime\projects\<projectKey>\state.json` (+ `sessions\`, `events\`).
  The project in play is `motivehr-4893d8fb`.
- Worker worktrees live OUTSIDE the target repo: `C:\laragon\www\.claude-factory-worktrees\<projectKey>\`.
- Every script is launched as **Windows PowerShell 5.1** (`powershell -NoProfile -ExecutionPolicy Bypass -File ...`),
  not `pwsh` 7. Native-argument quoting and `Remove-Item -Recurse` semantics differ from 7 —
  fixes must be correct under 5.1.
- There is a test harness: `tests\run-tests.ps1`. It builds a temp repo, a temp runtime and a
  **fake `claude` shim** (`claude-fake.cmd`), so launcher behaviour is testable without spawning
  real sessions. Add regressions there.

### Live work you must not disturb

| Task | State | Why it matters |
|---|---|---|
| `1216643944203164` | **running**, background session `51962867`, worktree `worker-1216643944203164-a1` | A worker is editing files right now. Do not stop it, do not clean it, do not rewrite its row in `state.json`. |
| `1216632072822682` | `awaiting-review`, commit `57bf282` in `worker-1216632072822682-a1` | Reviewed and waiting for the user's `go`. The commit is NOT on `develop`. Never run cleanup against it. |

`scripts\reconcile-worker-sessions.ps1` currently has **uncommitted** changes from this session
(the P2 fix below). `git status` in the plugin repo also shows `main` ahead of `origin/main` by 2 —
that predates this work. **Do not commit or push anything**: in this project commits happen only on
the owner's explicit "go".

---

## P1 — The FACTORY_TASK payload reaches the worker truncated

**Symptom.** Two independent workers reported their own task payload was cut off mid-value and
had to reconstruct the task themselves.

**Evidence.**

- Task `1216632072822682`, first assistant message: *"Task recovered from Asana (the launcher
  truncated the title mid-word)."*
- Task `1216643944203164`, first assistant message: *"I'll start by reading the full task payload —
  the FACTORY_TASK block appears truncated in my context"*, then *"The task payload in my context is
  truncated at `title: "Team`"*. The real title is
  `Team PTO: show annual PTO taken to date, and who else downstream is out at the same time`.
- In `claude logs 51962867` the rendered prompt shows the JSON with **quote characters missing** —
  `taskId:  1216643944203164,` / `title:  Team` — and it stops at the first space inside the
  quoted title value.

**Root cause (strongly suspected, verify first).** `scripts\start-worker-session.ps1` builds the
whole prompt, including `$payloadJson`, and appends it as the last **native argv entry**:

```powershell
$claudeArguments += $prompt
...
$launchLines = @(& $ClaudeCommand @claudeArguments 2>&1 | ...)
```

Windows PowerShell 5.1 rebuilds a native command line from `$claudeArguments` and mangles
arguments that contain `"` and newlines: quotes are stripped and the value can terminate early at
whitespace. The stripped quotes visible in the log are the fingerprint. A large brief additionally
risks the ~32 KB `CreateProcess` command-line cap.

**Required change.** Stop shipping the payload through argv.

- Write the full prompt (or at minimum the `FACTORY_TASK` JSON) to a file, e.g.
  `runtime\projects\<key>\sessions\<safeTaskId>-prompt.txt`, UTF-8, one file per attempt.
- Pass a short prompt on the command line that contains no quotes and no newlines, telling the
  worker to read that absolute path as its first action; or feed the prompt through stdin if the
  CLI supports it. Either way the argv entry must be short and quote-free.
- Keep the file after launch — it makes the payload auditable and lets a worker re-read it after a
  compaction. This also gives the P4 flow a natural home.

**Acceptance.** A test in `tests\run-tests.ps1` that launches with a title and brief containing
spaces, `"`, `'`, `&`, `|`, `%`, a newline and a non-ASCII em dash, then asserts that what the fake
`claude` shim can actually read is byte-identical to the intended payload (compare a hash), and
that the argv it received carries no raw payload text.

---

## P2 — Reconcile binds a task to a dead session row and forces a live worker into `held`

**Symptom.** After relaunching a worker on the same task, `reconcile-worker-sessions.ps1` reported
`running -> held` on every cycle while the worker was demonstrably alive and editing files. With the
2-minute `/factory:tick` cron this reburied the task each pass.

**Evidence.** `claude agents --json --all` contained two rows with the **same `name` and same `cwd`**:

```
index  8   id=c080790e  state=stopped   (previous attempt, already stopped)
index 26   id=51962867  state=working   (live worker, pid 165404)
```

The matcher looped rows in array order and accepted the first row satisfying *any* criterion,
including the `name` + `cwd` fallback — so the stopped row won. Worse, the row it picked was then
written back into the task: `backgroundSession.sessionId` and `transcriptPath` were overwritten with
the **old** session's UUID and transcript while `backgroundSession.id` still held the new short id.
That poisoned the row permanently, so even an id-aware matcher kept resolving to the dead session.
Both were repaired by hand for the live task.

**What is already in the working tree.** `scripts\reconcile-worker-sessions.ps1` now matches in
three ordered passes — `backgroundId`, then `sessionId`, then the `name` + `cwd` shape fallback — and
only adopts `sessionId` from a row whose `id` equals the stored `backgroundSession.id` (or when
nothing is recorded yet). Review it, keep or improve it, and cover it with tests.

**Still to do.**

- Apply the same "is this really my row" guard to `name`, `transcriptPath` and
  `lastAssistantMessage` adoption — they came from the same block and can carry the same poison.
- Fill `backgroundSession.sessionId` at launch time in `start-worker-session.ps1` instead of leaving
  it `null` for reconcile to guess: query `claude agents --json --all` once right after the launch and
  match on the short id the launcher already parsed.

**Acceptance.** Tests with a synthetic agent listing where a stale row sharing `name` + `cwd`
precedes the live row: the task must end up with the live row's state, and `sessionId` must never be
overwritten by a foreign row.

---

## P3 — A machine-imposed `held` has no way back

**Symptom.** Reconcile maps a `stopped` session to `held` for any task not in
`awaiting-review/approved/done`. But `held` is also the human state ("I am holding this"), carrying
`holdReason`, and **no command returns a task from it**: `retry` accepts only `blocked`/`failed`,
`go` demands a validated commit, `resume` is a global un-pause. Combined with P2 this made a healthy
worker unrecoverable without hand-editing `state.json` — which `SKILL.md` explicitly forbids.

**Required change.** Separate "the machine noticed the session died" from "a human parked this":

- either add a distinct state, or always set an explicit `holdReason`
  (e.g. `background session stopped without a FACTORY_RESULT`) so the two are distinguishable;
- extend `task-action.ps1` / the `retry` path to accept such a task when a usable worktree exists and
  no validated commit is recorded, clearing the background row and re-queuing;
- document the recovery command in `skills\factory\SKILL.md`. Today the command list has no exit from
  `held` at all.

**Acceptance.** A stopped session leaves a machine-distinguishable marker, and one documented
command relaunches from it. No hand edits.

---

## P4 — "Deliver answers and relaunch" is not a first-class command

**Symptom.** An interactive worker emits `FACTORY_PLAN` with open questions and waits in its own
chat. When the owner cannot attach — today they were on a phone, and `claude attach` needs a TUI —
there is no supported way to deliver the answers. What had to be done by hand for
`1216643944203164`:

1. write `FACTORY-DECISIONS.md` into the worker's worktree (already covered by the
   `FACTORY-DECISIONS.md` line in the repo's `.git\info\exclude`, which is shared with worktrees);
2. append a pointer paragraph to `task.brief` so the relaunched worker reads that file first;
3. `claude stop <old background id>`;
4. clear `backgroundSession`, set `status=queued`, `startMode=auto`, then launch.

Steps 2 and 4 are exactly the manual state mutation the skill prohibits, because no script exists.

**Required change.** Add `scripts\answer-task.ps1` and a `/factory answer <task-id> (-File|-Text)`
command that does all of it idempotently under the project mutex: write/refresh the decisions file,
ensure the exclude entry, add-or-replace the brief pointer, stop the previous background row, clear
`backgroundSession`/`error`, set `queued` plus the requested mode, bump `attempts`, and leave the
launch to the tick. Re-running it must not duplicate the pointer or the file.

**Acceptance.** Covered in `tests\run-tests.ps1`; listed in `SKILL.md`; running it twice is a no-op
beyond refreshing the answers.

---

## P5 — Cleanup can delete through directory junctions, outside the worktree

**Symptom.** After two `cleanup` runs today, `C:\laragon\www\motivehr\node_modules` in the owner's
main checkout was an empty real directory. It had been populated the previous evening — the built
assets in `public\build` are stamped 2026-07-30 16:03, which requires the dependencies — and had to
be restored with `npm ci`.

**Mechanism.** `Remove-FactoryLongPathDirectory` (`scripts\cleanup-task.ps1:42-62`) removes the
worktree with `Remove-Item -LiteralPath $fullPath -Recurse -Force`, falling back to
`[IO.Directory]::Delete("\\?\$fullPath", $true)`. Under Windows PowerShell 5.1 / .NET Framework both
of those recurse **into** directory junctions rather than deleting the link, so anything junctioned
from inside a worker worktree is deleted at its real location. A worker on task `1216722772084729`
stated in its own transcript that it had created junctions for `vendor` and `node_modules` pointing
at the main checkout, precisely to get a debug script running.

**Honest caveat.** Not proven: those worktrees are already gone, so the junctions cannot be
inspected, and the one surviving worker worktree has real directories rather than links. Treat the
mechanism as the fix target regardless — it is a real hazard whether or not it fired here.

**Required change.** Before recursing, walk the tree and delete every reparse point as a *link*
(`(Get-Item -Force).Attributes -band [IO.FileAttributes]::ReparsePoint` →
`[IO.Directory]::Delete($path, $false)`), never as a directory; refuse to remove anything whose
resolved target lies outside the worktree root; log each reparse point removed so a destructive pass
is auditable.

**Acceptance.** A test that creates a junction inside a fake worker worktree pointing at a sentinel
directory containing a file, runs the cleanup path, and asserts the worktree is gone while the
sentinel file still exists.

---

## P6 — `--agent factory:worker` does not resolve; workers silently run the default template

**Evidence.** Both launches today printed, from the CLI itself:

```
warning: no agent named 'factory:worker' — spawning with default template
```

even though `start-worker-session.ps1` passes `--plugin-dir <pluginRoot> --agent factory:worker` and
`agents\worker.md` exists. So whatever `agents\worker.md` defines — tools, permissions, model,
protocol reminders — is not in effect for any worker this plugin has launched.

**Required change.** Establish the correct way to address a plugin-provided agent for a `--bg`
launch, verify by launching and confirming the warning is gone, and make the launcher **fail loudly**
instead of accepting a silent fallback to the default template.

**Acceptance.** No such warning in `sessions\<taskId>.json` `launchOutput`; a test asserts the shim
receives a resolvable agent reference and that a missing agent aborts the launch.

---

## Suggested order

P1 → P2 → P6 → P3 → P4 → P5. P1 and P2 are the two that actively corrupt a run; P6 means nothing has
ever run under the intended worker profile; P3 and P4 are the missing operator escapes that turned a
small fault into a manual repair; P5 is the one that can damage things outside the factory.

Run `tests\run-tests.ps1` before and after. Report what you changed and what you could not verify —
do not commit, do not push, and do not touch the two live tasks listed at the top.
