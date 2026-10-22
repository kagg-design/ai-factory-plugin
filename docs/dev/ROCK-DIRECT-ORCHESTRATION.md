# Direct ROCK orchestration and private memory

Date: 2026-10-23. Implementation branch: `codex/rock-direct-memory`.

## Purpose and current boundary

Factory owns task execution. A ROCK owns its goal, task planning, verification,
and project-level decisions. Their operational exchange is local and durable.
Asana remains a source of requirements and an interface for people. The direct
planner has no Asana connector, token transport, shell, or mutation tools.

The implementation is opt-in and ships disabled. It has not been activated on
the live Access or Billing ROCK, and their Asana instructions are not edited.
Local tests use synthetic Git repositories and model results.

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

A hidden process runs one cycle per pending event. A dedicated runner mutex
prevents overlapping cycles of the same ROCK across projects. The Factory task
mutex is not held over model execution. Different ROCKs have separate ownership.

The planner returns versioned JSON with the exact event ID, checkpoint, decisions,
and a bounded action list. Native validation rejects unknown fields, unknown
actions, duplicate action IDs, mismatched event IDs, and unowned targets.
The contract is published in `resources/rock-result.schema.json`. Direct model
execution defaults to 900 seconds (`direct.timeoutSeconds`, range 1-3600).

Supported actions:

- `answer`: answer the originating question, tied to exact task and attempt.
- `dispatch`: enqueue a new, owned Asana-identified task from a normalized spec.
- `escalate`: save an operator question locally and surface it through attention.

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
For a pilot and any merge-gated task, set `requiresMergeGate:true` on its trusted
ownership binding. Native intake appends the gate even if the generated spec
omits it.

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
Direct task status is currently local. Updating the board through the browser is
a separate projection step and never blocks native completion.

```text
factory rock status
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
invocation in direct mode supplies a periodic event bucket; native task events
arrive through the scheduler without polling Asana. The former Asana `/pause`
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
run has not been performed as part of the offline implementation.

Recommended rollout: import Access sources; pilot direct questions on one task;
verify its ordinary review/GO/merge gate; then enable direct dispatch and Billing
watchers. Keep meaningful human-visible updates on the board through the browser
after agreeing the projection policy. Metrics that currently derive cycle time
from TAKEN/DONE comments need an explicit local-event source before those metrics
can describe direct tasks accurately.

## Implementation validation, 2026-10-23

The focused ROCK, Asana integration, quality gates/metrics, worker chat/attention,
local-file intake, parallel-safety and Factory-status suites passed on isolated
fixtures. The ROCK suite includes the actual public question/answer/import paths,
safe legacy rollback, exact local commit evidence and corrupt-memory isolation.
PowerShell parsing, JSON parsing and `git diff --check` also passed.

The complete entrypoint is not green: it stops in an existing ledger fixture
that omits runtime dependencies. The separate `-RuntimeOnly` run proceeded through
publication, recovery, sync, CLI and orchestrator checks, then failed a 28-second
Codex launch threshold at 29.78 seconds. An isolated baseline/branch comparison
returned with all three workers still alive: baseline 28.637 seconds, ROCK-disabled
branch 27.676 seconds. This provides functional compatibility evidence, not a
claim that the full suite passed. Separate reports are under `docs/tasks`.

The comparison is reproducible with `tests/rock-scheduler-compat.tests.ps1` and
its optional `-BaselinePluginRoot`. It does not weaken the existing timing gate.
