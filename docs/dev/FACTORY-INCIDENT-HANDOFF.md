# Factory defect handoff to Codex

Factory orchestrators report plugin defects directly to one durable local queue.
No Asana comment, permanent Codex supervisor or chat timer is required. Ordinary
application defects and expected worker/test failures stay in their own workflow.

An operator configures this shared policy once with `factory incident configure
--file POLICY`, from an initialized Factory repository:

```json
{"version":1,"enabled":true,"autoDispatch":true,
 "sourceRepository":"C:\\path\\to\\claude-factory-plugin",
 "codexCommand":"codex","maxAttempts":1,"timeoutSeconds":1800,
 "validationScripts":["tests/rock-publication.tests.ps1",
                      "tests/worker-chat-attention-amend.tests.ps1"]}
```

This is standing authorization for diagnosis and a candidate Factory repair,
not permission to install it or alter application state. Shipped installations
have no enabled policy. A missing Codex installation leaves a visible failed
handoff; it does not become a requirement for normal application workers.

`factory incident report --file EVIDENCE` accepts:

```json
{"version":1,"component":"attention","errorCode":"duplicate-source-edges",
 "summary":"One completion is delivered repeatedly",
 "observed":"Stable task/fingerprint produced repeated attention entries",
 "expected":"One edge for one unchanged fingerprint",
 "reproduction":"Run two native attention scans of the same fixture",
 "evidenceReferences":["task:123","bounded-log-reference"],
 "existingReport":"docs/tasks/TASK-existing-defect.md"}
```

Allowed components are scheduler, worker-launch, orchestrator, attention, CLI,
ROCK, runtime and publication. A stable component/code and source commit identify
one defect across projects. Repeated reports retain their occurrence count and
origins, without another repair. A native report specification is saved under
Factory `docs/tasks`; an existing report can be reused. Secrets are prohibited;
native capture uses bounded evidence/references and redacts common secret forms.

Reporting immediately starts a bounded hidden job when autoDispatch is enabled.
The scheduler also reports unhandled native loop/process errors. Codex uses its
existing CLI authorization in a separate detached worktree. It receives no new
application work and cannot satisfy human gates. Native code independently runs
the policy's tests, validates the base and changed paths, and retains a patch hash
and receipt. A model's assertion of success is not a test result.

The handoff ends at ready-for-review, not-a-factory-defect, needs-human, or failed.
A candidate is not automatically installed. The existing Factory development
orchestrator reviews it and performs any authorized integration. Results are
projected into the originating factories' existing attention journals. The
controller, live runtime, environment files and application repositories are
outside the candidate scope. Worktrees/evidence are retained after failure.

Use `factory incident list`, `status ID`, `run [ID]` or explicit `retry ID`.
Failed/interrupted jobs never retry themselves. Retry requires an available
attempt budget; a running reservation excludes other repair jobs across projects.
When no event is queued, no model is called. No Runtime directory is cleaned.

`tests/factory-incidents.tests.ps1` exercises shared deduplication, concurrent
reservation, a real isolated Git diff and native PowerShell regression, failed
tests despite model success, protected paths, no automatic install, origin
notifications and unchanged application activity/pause/task sets.
