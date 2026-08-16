# Native intake boundary — phase 5

## Goal

Remove AI ownership of Factory queue mutation while preserving AI judgment for
normalizing source content that cannot be interpreted safely by rigid code.

## Delivered behavior

- Native Asana preparation validates the exact host and task route, extracts a
  numeric source ID, canonicalizes the URL, and checks duplicates before any
  connector call.
- The Asana connector is read-only. AI may fill only semantic fields in a
  private versioned envelope and cannot change its native source identity or
  requested start mode.
- `resources/intake.schema.json` defines the source-neutral normalization
  contract, including a structured source identity and connector error.
- Native enqueue validates allowed fields and size limits, repeats
  deduplication under the project state mutex, and atomically creates the full
  queue object. AI never edits `state.json` or launches a worker directly.
- Successful intake enables the Factory and starts or wakes the native
  scheduler. Source failures are retained as blocked tasks without launching.
- `factory add --file <task.json>` imports a normalized envelope without AI or
  Asana and retains the operator's input file for reuse or audit.
- Asana retains its numeric state ID for compatibility. Other adapters use the
  collision-safe `adapter:id` form while preserving adapter and source ID as
  structured task metadata.
- State schema v6 adds `source` to existing task records without discarding
  legacy state.

## Trust boundary

AI and the Asana connector may read source material and normalize its meaning.
They do not validate URL authority, choose queue identity, decide duplicate
ownership, mutate state, activate the Factory, or start workers. Those actions
belong exclusively to native code.

## Verification

The synthetic end-to-end suite prepares an Asana URL, fills its normalization
draft, enqueues it, observes scheduler wakeup and worker launch, rejects a
duplicate URL, and cleans up the fixture. It also imports and deduplicates a
future-adapter envelope through `factory add --file`, verifies blocked-source
behavior and input-file retention, and migrates legacy state to version 6.
