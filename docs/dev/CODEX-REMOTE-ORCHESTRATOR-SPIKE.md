# Codex Remote Orchestrator Spike

Date: 2026-09-09

## Goal

Determine whether a Factory orchestrator can remain attached to a local
repository and terminal while also appearing as a normal Codex task that can be
accessed through Codex Desktop and, subject to Remote availability, a phone.

## Result

The app-backed orchestrator design is technically viable on Windows with Codex
CLI 0.153.4:

1. Start a one-shot `codex app-server --stdio` client.
2. Create and bootstrap a persisted thread through the app-server protocol.
3. Save that thread ID in the Factory project runtime.
4. Attach the terminal TUI to the same thread with `codex resume -C <repo>`.

The proof thread appeared in the Codex Desktop task list and the same thread was
successfully continued through `codex exec resume`. The existing standalone
Factory thread did not appear in the app-server thread list or Codex Desktop.

Phone visibility was verified by the operator. The proof thread appeared under
the `hcaptcha-wordpress-plugin` project on host `P16`, showed the completed
bootstrap exchange, and offered the phone action `Work on P16`. The proof
thread ID was `01a086f3-6884-7e60-b440-6e14d57b0683`; it was archived after
the verification. The CLI could not permanently delete this app-backed task,
so production cleanup must use an app-supported lifecycle operation instead of
assuming that `codex delete` handles every thread source.

## Evidence

### Standalone CLI threads are not app tasks

The current Factory implementation creates an orchestrator with `codex exec
--json` and opens it with `codex resume`. Its thread ID was persisted and could
be resumed locally, but both app-server `thread/list` and the Codex Desktop task
API omitted it. `--include-non-interactive` affects local resume selection; it
does not publish a thread to the app task list.

### App-server works on Windows

`codex app-server --stdio` initialized successfully on Windows and exposed the
generated experimental v2 protocol, including:

- `project/list`;
- `thread/start`, `thread/resume`, `thread/name/set`, and
  `thread/metadata/update`;
- `turn/start`;
- `remoteControl/enable`, `remoteControl/status/read`, and pairing methods.

The ready-made `codex remote-control start` command is not usable on this host:
it exits with `app-server daemon lifecycle is only supported on Unix
platforms`. This restriction applies to the daemon launcher, not to app-server
itself.

### A first turn is required

A persisted `thread/start` without a turn was neither visible in Codex Desktop
nor resumable after the one-shot app-server exited because it had no rollout.
The working sequence is:

```text
initialize
initialized
project/list
thread/start
turn/start
wait for turn/completed
thread/name/set
```

The bootstrap turn must explicitly prohibit skills, tools, commands, and file
changes. Its only purpose is to create the persisted rollout. Factory protocol
loading belongs to the first real operator request after terminal attachment.

### Project identity differs between APIs

The Codex Desktop wrapper's project ID is not accepted by app-server. Factory
must call `project/list` and match the canonical repository root. For hCaptcha,
the app-server project was found from its root and was accepted by
`thread/start`. The outer Desktop task projection still reported
`projectId=null`, but retained the correct repository `cwd` and displayed the
task. This affects sidebar grouping, not resumability.

### Terminal attachment works

The app-created proof thread completed a second turn through
`codex exec resume`. Production terminal attachment can therefore continue to
use the normal interactive form:

```text
codex resume -C <canonical-repository> ... <thread-id>
```

Passing `-C` on every resume is mandatory. A spike invocation that omitted it
changed the test thread's saved `cwd` to the caller's directory; app-server
`thread/resume` repaired it.

### Phone access is proven; explicit relay management is not required

A reversible protocol test produced an environment ID and moved from
`disabled` to `connecting`, then to `errored`. The test called
`remoteControl/disable` and restored the initial disabled state. No pairing code
was created. Despite that explicit protocol result, the app-backed proof thread
was visible and usable from the operator's phone through the already connected
`P16` host. Factory therefore does not need to manage account-level Remote
enablement or pairing. Those remain Codex application responsibilities.

## Implemented production design

The app-server adapter is now used only to create and validate a Codex
orchestrator thread. Workers continue using the existing non-interactive CLI
adapter.

On the first `factory start -Agent codex`:

1. Resolve the real current `codex.exe`.
2. Start a bounded one-shot app-server process and negotiate experimental API
   support.
3. Find the saved Codex project by canonical repository root. Do not use a
   Factory project key or an outer Desktop project ID.
4. Create a non-ephemeral paginated thread with the repository `cwd`, the
   matched project ID when available, and an app-visible source.
5. Run the minimal no-tool bootstrap turn and wait for `turn/completed`.
6. Name the thread `Factory Orchestrator - <repository-name>`.
7. Persist a versioned identity that records `backend: app-server` and the
   thread ID.
8. Close the one-shot app-server and launch interactive `codex resume` with the
   canonical `-C`, Factory runtime environment, and writable roots.

On later starts, Factory validates the stored thread through app-server and
resumes it directly. A legacy standalone identity that is absent from
app-server is replaced once; its ID remains in migration metadata so Factory
does not silently alternate between two orchestrators.

Do not silently fall back to a standalone thread when app-backed creation
fails. Such a fallback would recreate the exact visibility defect. Report the
app-server failure and leave the scheduler and task state untouched.

## Implementation risks and tests

- The app-server v2 protocol is experimental and may change between Codex CLI
  versions. Capability detection and bounded timeouts are required.
- JSON-RPC stdout must be read continuously so notifications cannot fill the
  pipe while waiting for a response.
- The adapter must answer or fail closed on unexpected server approval/tool
  requests during bootstrap.
- Tests include a fake line-oriented app-server covering initialization,
  project lookup, thread creation, bootstrap completion, naming, stored
  identity, failure cleanup, reuse, and legacy identity migration.
- Factory runtime, scheduler, task state, worktrees, and worker sessions must
  remain unchanged if app-thread creation fails.

## Spike cleanup

Remote control was returned to `disabled`. The empty and incorrectly rooted
test threads were deleted. After the operator's phone verification, the
correctly rooted proof thread was archived so it no longer clutters the active
task list. Generated protocol schemas and local probe scripts were not added
to the repository.
