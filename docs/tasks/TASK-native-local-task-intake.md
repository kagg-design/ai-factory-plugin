# Native local task intake

## Goal

Let an operator create Factory work from their own text, including an
intentionally blank worker conversation, without manufacturing a normalized
JSON file or routing a deterministic queue operation through AI.

## Delivered behavior

- `factory new "task text"` creates an interactive local task. The worker
  proposes a plan and waits for approval before implementation.
- `factory new --auto "task text"` creates an automatic local task and starts
  implementation immediately. Empty automatic tasks are rejected.
- `factory new` creates an intentionally blank interactive task. Its worker is
  told to ask the operator what should be implemented and wait before editing.
- Native code derives a readable title, preserves the complete brief, assigns
  a collision-safe `local:timestamp-random` ID, atomically updates project
  state, and starts or wakes the scheduler.
- The command prints the exact `factory chat <task-id>` handoff. From the
  orchestrator, `!factory new ...` reaches the same native implementation
  without consuming an AI command turn.
- Status, done history, and inspect output render `Source: local / <source-id>`
  instead of exposing the internal `factory://local/...` identity URI.
- The `local` adapter is reserved for this trusted command and cannot be
  imported through `factory add --file`.

## Trust boundary

The operator's text is stored directly as task meaning; no connector or AI
normalization step participates in intake. Native code exclusively owns ID
generation, validation, state mutation, deduplication, and scheduler wakeup.
The worker model remains responsible for planning or implementation after the
task has entered the queue.

## Verification

The synthetic end-to-end suite creates an empty interactive local task and an
automatic text task, waits for native scheduler launch, verifies stored source
identity, mode, title, brief, session metadata, and status rendering, then
cleans up both fixtures. It also proves that empty `--auto` input cannot mutate
state and that normalized file intake cannot impersonate the reserved local
adapter.
