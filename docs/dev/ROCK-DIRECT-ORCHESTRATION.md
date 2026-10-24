# Direct ROCK orchestration and private memory

Updated: 2026-10-24. Implementation branch: `codex/rock-direct-memory`.

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
Native prerequisite enforcement and a durable publication queue are implemented.
The shared ROCK coordinator owns publication after the affected factories review
its proposal. Its publication phase uses the existing authorized Claude ROCK
Asana connection. The planner remains read-only. No separate Codex publisher,
chat heartbeat, new connector, REST client or token path is required.

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

## Sources and existing access

This Codex chat reads Asana through the browser. Igor explicitly authorized the
already-connected Claude ROCK Asana tools on 2026-10-24; that does not authorize
adding an Asana connector to this chat or introducing a new REST/token path.
Existing UTF-8 source snapshots and decision history remain in private memory.

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
completion. Set `direct.publication.enabled:true` and initially use
`transport:"disabled"` to inspect factory review proposals. The existing ROCK
adapter is enabled with `transport:"existing-rock"` after capability verification.
The legacy `direct.browserProjection` and browser receipts remain available for
recovery; they do not require a permanent external publisher.

```text
factory rock status
factory rock configure --file C:\private\rock-cycle.direct.json
factory rock cycle ROCK_GID
factory rock dependencies ROCK_GID
factory rock publication list
factory rock publication pending
factory rock publication review --file C:\private\factory-review.json
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

On 2026-10-24 Igor stopped the external current-chat heartbeat `rock` and chose
coordinator-owned publication. Both it and the older `rock-cycle-5` monitor remain
paused. The previously requested live report check is due 2026-10-24 13:05 UTC;
the paused heartbeat will not perform it automatically.
Final coordinator regressions also cover PowerShell 7 / ru-RU receipt dates and
refuse failed/rejected/held blockers even when old publication audits remain.

## Factory agreement and coordinator publication, 2026-10-24

A report proposal captures the participating factories' task/run/attempt/commit,
publication and pause evidence. Each existing factory orchestrator receives a
durable `rock-publication-review` attention event, reads `publication list`, and
submits an exact revision/factsHash review. It may approve, correct or reject.
Changed evidence or corrected text invalidates earlier approvals. A joint digest
requires all participating factories. Native status projection can be attested
deterministically. A paused factory cannot release publication.

Approval emits `publication-ready`; the native job handles it without calling
the planning model. The job drains a bounded batch, without an idle model loop
or chat timer. The coordinator publishes using only its existing Asana tools.
Claude 2.1.295+ fail-closed PreToolUse hooks constrain target, text, fields,
pagination and one mutation attempt per claim. Actual PostToolUse readback,
not model narration, provides the receipt. Native evidence is checked again
before writing and confirming. Uncertain writes remain blocked for inspection;
they are not automatically repeated. Blockages enter the same attention journal.

The existing adapter is Claude-specific. The local queue, review and receipt
interfaces are independent of that adapter. A supported Codex-only planner and
Asana adapter still require separate implementation and acceptance; shipping
this adapter does not make both products a runtime requirement.

`tests/rock-publication.tests.ps1` covers two factory reviews, corrections,
stale runs/commits, paused publication, actual tool schema, full pagination,
wrong tools/targets/text/fields, newer human instructions, write-attempt reuse,
native readback and no-change cycles. Remote Asana responses are fixtures in
this suite. A separate read-only live probe confirmed the existing ROCK tools
and fail-closed hooks. At 10:29 UTC on 2026-10-24 the guarded adapter read back
the already-published Access marker and real story GID 1219824846551038 with
zero external writes. Large epic responses require bounded 20-story pages,
explicit evidence fields and consistent newest-first pagination. Hook context
supplies progress even when Claude's display truncates a large tool response.
No new live worker cycle or new production write is claimed from these tests.

The current focused checks passed for publication/source completion, direct ROCK,
shared coordinator, Asana integration, local intake, live status, worker attention
and guarded amend, and quality gates. Manifest paths and PowerShell syntax passed.
This is targeted validation of the changed paths, not a new full runtime-suite run.

## Ordinary Asana add completion

An ordinary Asana `factory add` keeps its local worker transport. Native `done`
with a matching published commit and closed session creates a `source-completion`
edge for the existing factory orchestrator. It checks the exact source through
its authorized Asana capability, respects human holds, completes the card and
records actual readback with `factory source confirm TASK_ID --file RECEIPT`.
Already completed sources need no external write. No machine comment or custom
field change is necessary. ROCK-owned sources stay coordinator-owned.

The receipt binds source identity, run, attempt and commit. Failed, held, queued,
unpublished, foreign and stale results cannot close a source. Native confirmation
is idempotent and preserves factory activity/pause and worker mode. On 2026-10-24
the real rehire task 1219789513918047 was observed already completed in the browser;
its native completion receipt was saved without changing Asana.
