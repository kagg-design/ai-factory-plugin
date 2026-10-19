# TASK — in-session worker replies, Claude orchestrator attention, sanctioned task-commit amend

Author: auditors orchestrator, 2026-10-19. Evidence comes from the
`cloud-infrastructure-auditors-8ce0822d` runtime and the motivehr orchestrator's memory.

## Context

- Plugin root: `C:\laragon\www\Projects\claude-factory-plugin`. Windows PowerShell 5.1 with
  StrictMode. Every fix needs a regression in `tests\run-tests.ps1`.
- Workers and the Claude orchestrator both load this plugin (`worker-launch.ps1:113`,
  `start-factory.ps1:271`), so every hook in `hooks\hooks.json` must filter by session.
- Test only in synthetic repos. Do not touch live runtimes, and do not commit or push.

---

## A — an operator reply in the worker's own chat does not change factory state

**Problem.**

- `1219601069095157`, attempt 1 (interactive): its plan at 2026-10-18T22:48:15Z set
  `awaiting-input`. Igor answered in the worker chat at 08:07Z, and the worker committed
  `a92cffb5`. Sync prepare was refused ("still has a working background session"), so the
  worker emitted a blocked result at 08:29:14Z.
- Attempt 4: after Igor allowed the amend in the chat (Defect C), sync was refused again at
  09:45:54Z (`blocked`, session `working`). Only `answer -Mode auto` recovered it, and that
  relaunch discarded the live context.
- The same thing happened on `1219601021655407` and on motivehr
  `local:20260910-120248-fe77b72d` (memory file `answer-in-session-breaks-sync.md`).

Root cause:

- Nothing records a reply. `hooks\hooks.json` registers only PreToolUse (Bash|PowerShell) and
  Stop, and `capture-worker-stop.ps1` publishes only Stop events (`worker-event.ps1:131-176`).
- Reconcile promotes only `starting`/`planning` on a `working` row
  (`reconcile-worker-sessions.ps1:542-543`). `blocked` is a settled status (`:86`) with no way
  out.
- Worker sync accepts only `starting`/`planning`/`running` (`sync-task.ps1:73`; guard
  `:124-130`; re-check `:382-389`).
- No command unlocks a live session. `release` refuses `working` (`task-action.ps1:229-232`),
  and `answer` refuses a task with a `workerResult` (`answer-task.ps1:48`) and otherwise
  relaunches.
- Rework inherits `startMode` (`task-action.ps1:107-150`, `factory-scheduler.ps1:645`), so
  attempt 3 got "interactive start" plus `REWORK_REQUEST` and stopped at a plan (08:53:53Z).

**Required behavior.** When the operator writes in the live session that produced the waiting
state, the task returns to `running`. The same session can then go lease → sync → result.

- Eligible tasks:
  - `awaiting-input` from the current session's `FACTORY_PLAN` or invalid-marker report;
  - `blocked` from the current session's blocked `FACTORY_RESULT`;
  - `blocked` from the current session's blocked-session timeout (reconcile `:550-556`).
- These guards stay:
  - A row state alone never unlocks a task (`run-tests.ps1:2581-2595` stays green).
  - The reply's `sessionId` equals `backgroundSession.sessionId`, and the row matched by id,
    not by the name+cwd fallback (reconcile `:169-195`).
  - The reply's `capturedAt` is later than the waiting marker, `reworkRequestedAt` and the
    session's `startedAt`.
  - Never for `held`, `syncing`, `awaiting-review` or any later status, a validated result
    (`factory-common.ps1:362`), undelivered `pendingInstructions`, or an Asana task with
    `asanaQuestion` (`answer-task.ps1:40-47`).
- On promotion:
  - set `running`;
  - record `inSessionReply {sessionId, capturedAt, fromStatus}`, which explains the empty
    `answerHash` and `FACTORY-DECISIONS.md` to reviewers;
  - clear `error` and `holdReason`;
  - clear `workerResult` only when its status is `blocked`;
  - keep `commit`, `branch`, `worktree` and `plan`.
- If the next Stop after the reply carries no marker (a conversational answer), return the
  task to `awaiting-input`.
- Decided (Decision 1): `rework` launches `auto` by default, with `-Mode interactive` for an
  explicit plan stop. `answer` keeps its explicit `-Mode` (`answer-task.ps1:7,109`), and
  `retry` inherits.

**Implementation notes.**

- `hooks\hooks.json`: add a UserPromptSubmit entry that runs a new
  `scripts\capture-worker-reply.ps1`.
  - It matches the task the same way as `capture-worker-stop.ps1:15-33` and always exits 0.
  - It writes `events\<task>\latest-reply.json` plus a history entry: `kind: reply`,
    `sessionId`, `capturedAt`, prompt SHA-256 and a bounded preview.
  - Never write `latest.json`: reconcile uses it for follow-up and `done` detection (`:291-316`,
    `:384-393`, `:564-567`).
  - Ignore the `FACTORY_PROMPT_FILE=` launch pointer.
  - The plugin does not use UserPromptSubmit today. Confirm its payload fields on the
    installed CLI (2.1.303) before relying on them.
- `factory-common.ps1`: add one shared promotion function. Call it from reconcile before
  `:538`, and from `sync-task.ps1` prepare under the state mutex before `:73`. That way a
  worker that reaches sync before the next 15-second tick is not refused.
- Codex has no hooks. In `resume-codex-worker.ps1`, the factory-owned chat path, record the
  same reply event (`source: codex-resume`, sessionId = thread id) and promote the task under
  the same guards before `codex resume` (`:42`).
- `task-action.ps1` rework gets a `-Mode` parameter (default `auto`), so
  `start-worker-session.ps1:312-338` no longer combines the interactive instruction with
  `REWORK_REQUEST`. Update both SKILL copies.

**Tests** (`tests\run-tests.ps1`, next to `:2336`, `:2368-2419`, `:2581-2595`, `:2639-2715`
and `:4151-4161`). Send synthetic payloads through `Invoke-FactoryHookWithUtf8Input` (`:108`).

1. A same-session reply → `running`, and sync prepare then succeeds. This also works when
   no reconcile has run in between.
2. Unchanged, with sync still refused: an earlier session, a reply before `planRecordedAt`,
   the launch pointer, `held`, a validated result.
3. Blocked result plus a reply → `running`; `workerResult` cleared, commit kept.
4. A Stop without a marker → `awaiting-input`. A Codex resume promotes the task.
5. Rework launches with "automatic start"; `-Mode interactive` still stops at a plan.

**Acceptance.** Plan → chat reply → commit → sync → result reaches `awaiting-review` in one
session with no orchestrator command.

**Out of scope.** Delivering rework findings into a live session; any change to review or GO.

---

## B — Claude orchestrators get no automatic attention delivery

**Problem.**

- The scheduler scans and dispatches attention only when `workerAgent == "codex"`
  (`factory-scheduler.ps1:686-692`; `orchestrator-attention.ps1:44-53`). The attention scan
  runs only from `wait-factory.ps1:26` and `orchestrator-attention.ps1:17`, so for Claude the
  journal advances only while someone runs `factory wait`.
- Auditors (`attentionBridge: true`, `workerAgent: claude`, orchestrator `a29bf31f`): the
  orchestrator cursor is 0 and `dispatch` is null. The 22:48Z plan and the
  08:29Z blocked edges were never journaled, and Igor found the waiting task himself.
- motivehr (revision 288, orchestrator cursor 0) stays responsive only by re-arming
  `factory wait` in background Bash: 446 calls since 2026-10-10. Its memory file
  `orchestrator-queue-watch.md` records silent stalls when a watcher died, including a
  1.5-hour hang on 2026-10-16.

**Required behavior.**

- The plugin keeps delivery alive, not the orchestrator model.
- After `factory start` or `factory restart`, each new deliverable edge reaches the
  conversation without operator typing:
  - once per revision;
  - acknowledged durably in `orchestrator-attention.json`;
  - redelivered after a restart only if it was never acknowledged.
- Deliverable edges are the default-wait set (`wait-factory.ps1:33-36`): AI-actionable edges
  for action, human edges as notify-only (Decision 2).
- GO stays human unless `autoGoApprovedReviews` turns it into `auto-go`
  (`factory-common.ps1:503-512`).
- A dead consumer with pending edges appears under NEEDS YOUR ACTION. It is never silent.

**Recommended design: a plugin-owned rewake hook.**

- **Spike first.** The installed CLI binary (`C:\Users\igerg\.local\bin\claude`, 2.1.303)
  contains the command-hook keys `asyncRewake`, `rewakeMessage` and `rewakeSummary`, plus
  code that wakes the model when such a hook exits with code 2. Nothing in the repo documents
  or uses this. Verify each point and record the result in the PR:
  - a background SessionStart or Stop hook does not block the turn;
  - exit 2 starts a turn in an idle `--bg` session and carries the hook's output;
  - the hook's timeout ceiling;
  - whether SessionStart fires after `claude respawn`.
- `factory-scheduler.ps1:686-710`: scan every tick for every runtime. Codex dispatch stays as
  it is.
- `hooks\hooks.json`: SessionStart and Stop entries (`asyncRewake`, long timeout) that run a
  new `scripts\orchestrator-attention-hook.ps1`. The hook:
  - exits 0 unless `session_id` equals the `orchestrator-session.json` sessionId and `cwd`
    is the repository root;
  - holds a single consumer lease, `claudeConsumer {sessionId, pid, processStartTimeUtc,
    heartbeatAt}`, and exits 0 if a live consumer already exists (`Test-FactoryRecordedProcess`);
  - on Stop, marks this session's delivered claim as acknowledged. The turn that just ran
    is the proof, so the model never has to acknowledge anything;
  - polls like `wait-factory.ps1:22-72` for deliverable edges above
    `orchestratorAcknowledgedRevision`, then claims them (token, through, revisions). It
    advances the cursor before waking, as the Codex path does
    (`orchestrator-attention.ps1:88-106`), prints the batch with the existing prompt text
    (`:108-118`) and exits 2;
  - on SessionStart, re-emits an unacknowledged claim left by a dead consumer exactly once,
    marked `redelivered`;
  - exits 2 with a no-op re-arm line before a hard timeout cap, if the spike finds one
    (Decision 3).
- A manual `factory wait` moves only `waitAcknowledgedRevision`.
- `Get-FactoryOperatorActionEvents` (`factory-common.ps1:544-576`) emits an
  `orchestrator-attention` event when deliverable edges are older than 60 seconds and no live
  consumer exists. `factory doctor` reports the lease.
- Docs (`README.md:741-762`, `standalone\.claude\skills\factory\SKILL.md:970-990`): Claude
  delivery is native, so the
  orchestrator must not run its own watcher while a consumer is live.

**Alternatives.**

- A Stop hook returning `decision: block`: unverified, and it fires only at turn end.
- A scheduler-launched `claude --bg --resume`: SKILL.md `:178-179` says it can fork a
  registered session.
- A model-armed Monitor or background watcher: ruled out by the motivehr evidence above.
- Remote Control (`start-factory.ps1:275`): no programmatic client.

**Tests** (`tests\run-tests.ps1` around `:4023-4047` and `:1380`, plus
`tests\claude-orchestrator-lifecycle.tests.ps1`):

1. A Claude tick journals an edge with no `factory wait` call.
2. The orchestrator-session hook exits 2 with the batch, and the cursor and claim persist.
3. A later Stop acknowledges the claim, and no re-emit follows.
4. Worker sessions, foreign sessions and a second consumer exit 0.
5. A crash followed by SessionStart redelivers exactly once.
6. GO is delivered only as `auto-go`.
7. `factory wait` leaves the orchestrator cursor alone.
8. A dead consumer shows in `factory status`.

**Acceptance.** The harness is green. In a synthetic live spike, an idle background
orchestrator receives a blocked edge without typing, both before and after `factory restart`.
The Codex asserts at `:4041-4043` stay unchanged.

**Out of scope.** The Codex transport; acting on human decisions.

---

## C — rework requires an amend that the auto-mode classifier denies

**Problem.**

- `agents\worker.md:30-32`, `:89` and `:125-129`, and `REWORK_REQUEST`
  (`start-worker-session.ps1:330-333`), require amending the single task commit.
- At 09:02:20Z, `git commit --amend --no-edit` was denied in Bash and PowerShell
  ("[Git Destructive]"). The task stayed blocked until Igor allowed it. motivehr
  `factory-traps.md:235-253` (2026-08-27) records the same denials.
- The classifier did allow `sync-task.ps1`, which rebases and resets internally (`:348`,
  `:372`). Its refusals came from the factory guard (`:129`).

**Required behavior.**

- A sanctioned factory script performs the amend after validating the task, branch and
  worktree.
- Workers never run `git commit --amend` directly. They never try other command forms or a
  `reset --soft` workaround.
- If the script itself is refused, the worker emits a blocked result (`worker.md:162-165`).

**Implementation notes.**

- New `scripts\amend-task-commit.ps1 -Repository -TaskId [-MessageFile]`, exposed as
  `amendScript` next to `syncScript` (`start-worker-session.ps1:305-306`) for both Claude and
  Codex workers.
- Validate everything before resolving Git:
  - task status is `starting`, `planning` or `running`;
  - the worktree is inside `worktreeRoot` and equals `task.worktree`;
  - the current branch equals `task.branch` and matches `factory-worker/*`. Never the
    development or production branch, and never a detached HEAD;
  - HEAD has a single parent, and `HEAD^` is an ancestor of `<remote>/<developmentBranch>`;
  - no rebase, merge, cherry-pick or revert is in progress;
  - no unmerged, unstaged or untracked paths;
  - the staged diff is non-empty unless `-MessageFile` is given, and `-MessageFile` lies
    outside the worktree;
  - the script holds the per-task sync operation mutex (`sync-task.ps1:59-60`).
- Move `Resolve-FactorySyncGit` (`sync-task.ps1:33-53`) into `factory-common.ps1`. Run
  `commit --amend --no-edit` (or `-F`) with Git hooks enabled.
- Afterwards, check that the parent and branch are unchanged and the worktree is clean, then
  print `{oldCommit, commit, parent}`.
- Write no commit into state. Reconcile still validates `FACTORY_RESULT`.
- Update `worker.md` and the `REWORK_REQUEST` text to name `amendScript`.

**Alternative (not recommended).** A launch-time allow rule, or a `permissionDecision: allow`
from `worker-git-guard.ps1` (which already emits deny at `:79-88`). Neither is verified to
override the classifier, and both would run the raw command without these checks.

**Tests** (`tests\run-tests.ps1`, near `:2639-2715`):

- Success keeps the parent, gives a single-parent HEAD and leaves a clean tree.
- Refused: a shared or wrong branch, a worktree outside the root, two commits, a merge
  commit, unstaged or untracked files, a cherry-pick in progress, `awaiting-review`, `held`,
  a shim Git.

**Acceptance.** The harness is green. A Claude auto-mode worker in a synthetic repo completes
a rework amend through `amendScript` with no denial.

**Out of scope.** Relaxing `worker-git-guard.ps1` or `codex-git-proxy.ps1`.

---

## Decisions (Igor, 2026-10-19)

1. Rework launches in `auto` by default; `-Mode interactive` stays available for an explicit
   plan stop. `answer` keeps its explicit `-Mode`, and `retry` inherits.
2. Human edges (`awaiting-input`, `asana-question`) are delivered to the Claude orchestrator as
   notify-only, together with the AI-actionable edges. GO stays human unless
   `autoGoApprovedReviews` is true.
3. If the hook's runtime is capped, periodic no-op wake turns are acceptable. Keep them rare
   and say so in the wake text.
