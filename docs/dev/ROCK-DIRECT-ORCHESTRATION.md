# Direct ROCK orchestration and private memory

Date: 2026-10-23. Implementation branch: `codex/rock-direct-memory`.

## Purpose and current boundary

Factory owns task execution. A ROCK owns its goal, task planning, verification,
and project-level decisions. Their operational exchange is local and durable.
Asana remains a source of requirements and an interface for people. The direct
planner has no Asana connector, token transport, shell, or mutation tools.

The implementation is opt-in and ships disabled. A private Access verification
pilot is enabled on one completed task with an observation-only binding; Billing
watches that task. This does not authorize new workers or change Factory activity.
Historic epic instructions remain intact. Local regression tests use synthetic
Git repositories and model results; live pilot evidence is recorded separately.

The operating contract was clarified by Igor's supplied #ai conversation on
2026-10-23: one planning coordinator covers both ROCKs; tasks have one owner and
cross-repository prerequisites; live-behavior changes require human approval
before merge. Asana must retain readable milestones and human intervention from
a phone. Machine receipts remain local. See
`docs/tasks/TASK-rock-direct-memory-questions.md` for the agreed rollout decisions.
One shared coordinator now serializes events across both goals. Every model
request contains both goals, their task states and shared decision history.
Native prerequisite enforcement and a durable browser publication queue are
implemented. The browser consumer must have actual browser tools; PowerShell
does not create a browser session or fall back to a token transport.

## Storage and identity

`direct.memoryDir/<Asana epic GID>/` is shared by every participating project.
The default root is `%LOCALAPPDATA%\ClaudeFactory\rocks`. It is independent of
project runtime placement and the ROCK's display name. Git checkouts and reparse
points are refused. Existing `rock-orchestrator/<name>` state is retained.

```text
<epic GID>/
  memory.json              checkpoint, attributed decisions, questions, pause
  memory.json.previous.bak preceding valid revision
  events/<event hash>.json durable input, saved result, action receipts
  cycles/<event>-N-<nonce>.request.json
  cycles/<event>-N-<nonce>.output.json
  cycles/<event>-N-<nonce>.code.json exact local task commit evidence, when available
  sources/<content hash>.json imported browser snapshots, verbatim
```

Memory writes are atomic and protected by a dedicated ROCK mutex. The model
cannot write these files. The native runner records its decisions with actor
`rock:<GID>`. Operator answers have separate attribution. Imports are source
material and do not grant operator authority. A missing memory file with a
recovery copy is an error; it is never silently initialized as an empty ROCK.

The request contains a compact checkpoint, the latest 20 decisions, open questions
and the latest 10 answered questions. It also includes the full memory path and
source paths. Older binding decisions remain available through Read/Grep.
For events with a commit SHA, native `git show` supplies the exact local task diff
without fetching or changing a checkout. This survives worker cleanup and avoids
verifying an outdated read-only clone. The evidence is bounded and marks
truncation explicitly; it is not proof of deployment or CI success.

## Event and action protocol

After reconciliation, the native scheduler publishes Question, done and failed
events independently of Asana availability. Events have stable identities from
project, task, run/attempt and question/commit. An owning ROCK and its configured
watchers receive separate events. A watcher gets no authority to mutate the task.

A hidden process handles pending events under one shared coordinator runner
mutex, across both goals and all participating projects. Individual goal memory
and ownership stay separate. The Factory task mutex is not held over model
execution. Shared memory lives in `_coordinator/<coordinatorId>/memory.json`;
the browser outbox is its sibling `outbox/` directory.

The planner returns versioned JSON with the exact event ID, checkpoint, decisions,
and a bounded action list. Native validation rejects unknown fields, unknown
actions, duplicate action IDs, mismatched event IDs, and unowned targets.
The contract is published in `resources/rock-result.schema.json`. Direct model
execution defaults to 900 seconds (`direct.timeoutSeconds`, range 1-3600).

Supported actions:

- `answer`: answer the originating question, tied to exact task and attempt.
- `dispatch`: enqueue a new, owned Asana-identified task from a normalized spec.
- `escalate`: save an operator question locally and surface it through attention.
- `report`: queue a meaningful human-readable result for browser publication.
- `refresh`: request browser evidence from the main orchestrator without asking
  a human or posting a comment. Internal checkpoints are never auto-published.

There are deliberately no approve, merge, shell, arbitrary write, or operator
impersonation actions. Existing tasks cannot be overwritten by dispatch. Failed
work requires inspection, a distinct follow-up task, or escalation.

Results are saved before actions run. Native intake and answer operations also
record their action IDs, closing the crash window between execution and receipt.
A replay uses the saved result and never invokes the model again. State updates
and operator questions are idempotent. Invalid model output stops after three
attempts and produces one durable operator question. Non-transient application
errors also stop after three attempts. Paused factories and still-closing worker
sessions defer actions without unpausing anything.

Pending events and unresolved questions count as unfinished work when an
already-active Factory considers going idle. Events are captured both before and
after publication in a tick. An inactive Factory is never activated by a ROCK
action. Start/resume it explicitly when enabling a pilot. An automatic ROCK
answer also cannot release a manually held task.

Direct dispatch preserves Asana task identity and URL, but uses the local Factory
execution mode (`asanaMode=false`, `rockId` set). It does not depend on Ready or
Taken, send machine comments, or enter the old Asana answer loop. The legacy poller
skips tasks assigned to a configured direct owner. Global worker concurrency and
the publication pipeline remain authoritative. The planner cannot satisfy a merge
gate or GO approval. Imported specs must retain every existing merge-gate condition.
Trusted ownership bindings default to `requiresMergeGate:true`. Native intake
appends the gate even if the generated spec omits it. An explicitly reviewed
binding can set false for a task that does not change live behavior.

## Browser sources

The operator explicitly requires browser access to Asana, without an Asana app
connector. A proposed new API/token read path was rejected by automatic approval
review and was not applied. The direct implementation uses local UTF-8 snapshots
read through the existing browser. No new Asana API read path is introduced.

Bootstrap requires the epic description, binding historical decisions, outstanding
questions, owned task requirements, watchers, and relevant external reports.
`factory rock import` retains the supplied file verbatim. Multiple snapshots are
allowed; no existing source is deleted. Factory's main orchestrator can perform
the browser reads and import snapshots. If the planner has no sources it queues
a `rock-source-refresh` attention event rather than calling the model blind.
The notification is AI-actionable and explicitly requests browser access only.

This version does not automatically detect changes made in Asana between imported
snapshots. Sources must be refreshed through the browser before dispatch when
requirements or external prerequisites may have changed. Full unattended browser
refresh and board-status projection need a verified browser-capable orchestrator;
they are rollout decisions, not implicit token/connector fallbacks.
Sources older than 60 minutes request a browser refresh before another model
call. Replacing source snapshots during an in-flight plan prevents automatically
applying that saved plan; its result is retained for inspection.

## Configuration and commands

In a separate reviewed copy of `rock-cycle.json`, enable `direct.enabled` and set
an external `direct.memoryDir`. Each orchestrator needs explicit `ownedTasks` and
`watchedTasks`. A binding is:

```json
{"taskId":"123456789","repository":"C:\\path\\to\\main-repository"}
```

Each task has exactly one owner across this configuration. Its repository is the
canonical main checkout, not the ROCK's read-only code checkout. Watchers can span
repositories. The configuration is operator-maintained; agent output cannot alter
bindings. This permits a safe pilot with only a small set of known tasks.
Only directly owned tasks are excluded from legacy intake/wake-ups. Unbound
tasks retain their old launcher path during a pilot; keep the direct config in
a separate file rather than switching the shared legacy launcher's config.

Enable each participating project's private config:

```json
"rocks": {"enabled":true,"configPath":"C:\\private\\rock-cycle.direct.json"}
```

Before enabling, import source snapshots and review all ownership bindings. A
project must have its existing Factory runtime initialized. Starting this feature
does not create a project runtime or resume an explicitly paused factory.
Updating the board is a separate durable projection and never blocks native
completion. Set `direct.browserProjection.enabled:true` and nominate its
`consumerRepository`. That main orchestrator receives browser-work attention.
It must have browser tools; otherwise it defers with a concrete reason.
For a separate authorized Codex browser chat, set `consumerMode:"external"`;
the native Factory consumer then receives no duplicate browser-work attention.

```text
factory rock status
factory rock configure --file C:\private\rock-cycle.direct.json
factory rock cycle ROCK_GID
factory rock dependencies ROCK_GID
factory rock browser list
factory rock browser claim ROCK_GID
factory rock browser confirm --file C:\private\observed-receipt.json
factory rock questions
factory rock import ROCK_GID --file C:\private\snapshot.txt
factory rock answer ROCK_GID QUESTION_ID --text "operator decision"
factory rock pause ROCK_GID
factory rock resume ROCK_GID
factory rock retry ROCK_GID FAILED_EVENT_ID
factory answer TASK_ID --text "operator answer to the worker"
```

For live operator questions, show context/options/recommendation and wait for the
operator. Never run an operator-answer command on the operator's behalf. An answer
does not approve a merge gate or publication. `factory rock pause` controls the
ROCK; Factory `pause` still controls task launches and publication.

`rock-cycle.ps1 -DryRun` reports direct storage without state writes. A scheduled
invocation in direct mode only inspects inputs: unchanged schedules create no
event and call no model. Native task events arrive without polling Asana. The former Asana `/pause`
comments do not control this local mode; migrate that control explicitly.

For rollback, pause the ROCK and drain/hold its direct tasks first. Keep the
project binding available while a direct worker is waiting for its answer. Then
disable future direct scheduling. Retain all ROCK/project state and snapshots.
Do not turn legacy Ready polling back on for unfinished direct work without
reconciling task ownership. No runtime deletion or automatic migration is involved.

## Verification and rollout

`tests/rock-direct.tests.ps1` covers persistence, stable identity, ownership,
watchers, result validation, native intake, answer correlation, pause, human-only
questions, crash replay, escalation and bounded failure. Existing Asana tests
remain relevant for the disabled/legacy mode. A real model/browser integration
is separate from these offline checks; see the pilot record below.

Recommended rollout: import Access sources; pilot direct questions on one task;
verify its ordinary review/GO/merge gate; then enable direct dispatch and Billing
watchers. Keep meaningful human-visible updates on the board through the browser
using the agreed projection policy. Metrics that currently derive cycle time
from TAKEN/DONE comments need an explicit local-event source before those metrics
can describe direct tasks accurately.

## Implementation validation, 2026-10-23

The focused ROCK, Asana integration, quality gates/metrics, worker chat/attention,
local-file intake, parallel-safety and Factory-status suites passed on isolated
fixtures. The ROCK suite includes the actual public question/answer/import paths,
safe legacy rollback, exact local commit evidence and corrupt-memory isolation.
PowerShell parsing, JSON parsing and `git diff --check` also passed.

Igor authorized the fixture repairs. The ledger test now packages its runtime
dependencies. The Codex slot test uses controlled worker lifetime, verifies all
three live workers, and bounds output-pipe completion separately from cold start.
A negative control enables handle inheritance only in a disposable plugin copy;
the check detects that exact defect. Production launchers are unchanged.

The full entrypoint passed all 22 preliminary suites, including the forced ledger
race and pipe-inheritance negative control. Its runtime section then passed the
slot gate (30.525 seconds) and exposed a cumulative FakeCodex deletion-count
assertion. After isolating that assertion to the exact rejection operation,
`tests/run-tests.ps1 -RuntimeOnly` passed to exit code 0, including publication,
recovery, CLI, sync and Codex checks. Its slot gate returned all three workers
alive in 29.893 seconds. Validation therefore comprises the full preliminary run
and the successful runtime rerun, rather than a single uninterrupted full run.

The comparison is reproducible with `tests/rock-scheduler-compat.tests.ps1` and
its optional `-BaselinePluginRoot`; `-InjectInheritedPipe` exercises the negative
control. A further run alongside the full suite passed with all workers alive.
The final manifest contains all 22 referenced suites and their new dependencies;
all 132 entries exist. The focused ROCK suite passed after adding bundle checks.
Separate repair and evidence reports are under `docs/tasks`.

Those earlier checks ran on the isolated branch based on `37aeca7`. Main's
`99f4043` (CI attention replay / stale Claude claims) was subsequently merged as
`fb2a747`; its publication/CI suite passed with 90 assertions after integration.

## Cross-factory prerequisites and browser receipts

Each owned binding may include `prerequisites`, for example:

```json
{"taskId":"222","repository":"C:\\repo-b","requiresMergeGate":true,
 "prerequisites":[{"taskId":"111","repository":"C:\\repo-a","stage":"production"}]}
```

Prerequisites must reference known owned tasks in their canonical repository;
self edges, duplicates and cycles are rejected. Stages are `done`, `development`
or `production` (publication, not deployment); optional `commit` and `runId`
pins narrow the acceptable evidence. Native ledger and retained completed
archive supply evidence. Missing/corrupt evidence blocks launch. Publication must
match the exact task commit. Checks run at dispatch, intake and immediately before
worker reservation, and the scheduler skips blocked queue entries so independent
work can fill a slot. A binding with `mode:"observe"` cannot answer, dispatch or
launch a worker and is suitable for verification pilots.

Browser comments target only the owning epic, carry actor attribution and a
stable marker. Status projections target only configured owned tasks; stale
pending projections are superseded. A claim has a nonce and a ten-minute lease.
The browser consumer checks current human holds and decisions before writing,
then reads the actual rendered result and confirms the full text and marker (or
the status field), exact target URL and current nonce. See the canonical Factory
skill for receipt examples and the UI procedure.

An expired claim requires inspection for a possibly successful earlier post.
`defer` records a blocked attempt; `retry` requires its exact claim. `absent` can
requeue a comment only after inspecting all comments and finding no marker.
There is no automatic repost after an uncertain click. A published receipt is
idempotent. Internal questions/answers and technical receipts stay local.

The supervisor may `discard` a fresh, unposted claim with a recorded review reason;
uncertain earlier browser actions must be verified first. `factory rock withdraw
GID QUESTION_ID --text REASON` withdraws an erroneous agent question only while its
browser projection is still unposted. This records a review, never an operator
answer or merge approval. Published questions require a visible correction.

`factory rock pause/resume` without a GID controls the shared coordinator; with a
GID it controls one goal. These commands preserve Factory pause and activity.

`tests/rock-coordinator.tests.ps1` exercises two native project runtimes, joint
history, watcher limits, graph validation, publication pins, retained/corrupt
archives, a real scheduler dependency race, shared pause, cross-process exclusion,
browser leases/receipts and no-change scheduling. It passed alongside the focused
direct, Asana, quality-gate and worker-chat suites. These tests use disposable
fixtures, not the live Factory runtime.

## Access verification pilot, 2026-10-23

Native `rock configure` enabled only completed DIGEST-005 (1219767634564705) as
an Access-owned observation binding; Billing watches it. Neither Factory was
activated. Four real read-only model events completed with joint context and
shared history. The exact task commit `6daab7fbb2e800afc35b812374a4c1182138e2e6`
was inspected from a bounded diff and six full-file blobs, not a stale checkout.
No application tests, worker launches or deploys were performed by this pilot.

Fresh browser observations showed the existing drift task 1219738550184629 open,
with an `As of 2026-10-23 09:05 ET` header and RAD Bot among collaborators. This
matches the update-in-place case; Buddy's deployed SHA/time and the following
morning's update were not established by that observation.

Supervisor review withdrew two erroneous agent questions without inventing human
answers, rejected internal/stale publication intents before any post, and queued
one concise reviewed milestone. That milestone was posted through the browser to
the Access epic, then confirmed against its full rendered text and stable marker
`[factory-rock/q4-2026-access-pilot/5492276fb0346c85]`. The durable receipt is
published. A repeated native cycle returned processed=0 and browserPending=0,
with no model launch or duplicate post.

Igor authorized this Codex chat as an external browser consumer checking every
minute, quiet when unchanged. Broad task migration and a live worker question /
next-task dispatch remain outside this completed-task verification pilot: no
eligible Ready Access task was visible. Read all binding historical decisions
and configure exact new owner/prerequisite bindings before that next phase.

On 2026-10-24 the authorized current-chat heartbeat `rock` was enabled at a
one-minute cadence with `consumerMode:"external"`. It checks the local queue
first and stays silent when unchanged. The older `rock-cycle-5` monitor in a
different chat remains paused. Next live check is due 2026-10-24 13:05 UTC.
Final coordinator regressions also cover PowerShell 7 / ru-RU receipt dates and
refuse failed/rejected/held blockers even when old publication audits remain.
