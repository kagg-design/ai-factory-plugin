# Codex Remote Orchestrator Spike

Date: 2026-09-09

## Goal

Determine whether a Factory orchestrator can remain attached to a local
repository and terminal while also appearing as a normal Codex task that can be
accessed through Codex Desktop and, subject to Remote availability, a phone.

## Result

The shared app-backed orchestrator design is technically viable on Windows
with Codex CLI 0.153.4:

1. Start one persistent `codex app-server --listen ws://127.0.0.1:<port>` per
   Factory runtime home.
2. Create and bootstrap a persisted thread through that server.
3. Save the thread ID in the Factory project runtime and the server PID,
   process start time, and endpoint in shared runtime state.
4. Enable Remote on the server and attach the terminal with `codex --remote
   <endpoint> resume -C <repo> <thread-id>`.

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

### Shared terminal attachment works

Codex CLI exposes a supported remote TUI transport for a listening app-server.
Production terminal attachment uses:

```text
codex --remote ws://127.0.0.1:<port> resume -C <canonical-repository> ... <thread-id>
```

The TUI and phone can therefore be clients of the same server-owned thread;
neither needs to take a separate direct JSONL writer lock. Passing `-C` on
every resume remains mandatory.

### Phone access requires a connected Remote relay

The app-backed proof thread was visible and usable from the operator's phone
through the connected `P16` host. The shared implementation now calls
`remoteControl/enable` on its own server and reports the returned state. Only
`connected` confirms mobile readiness. `connecting` and `errored` leave local
terminal operation intact but cannot promise phone access; Factory surfaces
that distinction instead of silently claiming remote visibility.

## Implemented production design

The app-server adapter owns Codex orchestrator threads and serves every
attached orchestrator TUI. Workers continue using the existing non-interactive
CLI adapter.

On the first `factory start -Agent codex`:

1. Resolve the real current `codex.exe`.
2. Start or reuse a healthy loopback app-server recorded under the selected
   runtime home, and negotiate experimental API support over WebSocket.
3. Enable Remote and print its actual state.
4. Find the saved Codex project by canonical repository root. Do not use a
   Factory project key or an outer Desktop project ID.
5. Create a non-ephemeral paginated thread with the repository `cwd`, the
   matched project ID when available, and an app-visible source.
6. Run the minimal no-tool bootstrap turn and wait for `turn/completed`.
7. Name the thread `Factory Orchestrator - <repository-name>`.
8. Persist a versioned identity that records `backend: shared-app-server` and
   the thread ID.
9. Close only the short-lived bootstrap client and launch interactive `codex
   --remote <endpoint> resume` with the canonical `-C` and writable roots. The
   server remains alive when the TUI exits.

On later starts, Factory reuses the server, validates the stored thread through
it, and resumes through the same remote endpoint. A legacy standalone identity
that is absent from app-server is replaced once; a prior one-shot app-backed
identity is reused and upgraded in place.

`factory agents` opens Codex's shared session dashboard in a second terminal.
`factory codex-server status|start|stop|restart` provides explicit Windows
lifecycle management because the CLI's native daemon lifecycle is unavailable
on this host. Stop and restart affect all Factory Codex terminals sharing the
runtime home, but not schedulers, workers, task state, or worktrees.

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
- Tests include a persistent fake WebSocket app-server covering initialization,
  Remote enablement, project lookup, thread creation, bootstrap completion,
  naming, stored identity, shared reuse, dashboard routing, failure cleanup,
  and legacy identity migration.
- Factory runtime, scheduler, task state, worktrees, and worker sessions must
  remain unchanged if app-thread creation fails.

## Spike cleanup

Remote control was returned to `disabled`. The empty and incorrectly rooted
test threads were deleted. After the operator's phone verification, the
correctly rooted proof thread was archived so it no longer clutters the active
task list. Generated protocol schemas and local probe scripts were not added
to the repository.
