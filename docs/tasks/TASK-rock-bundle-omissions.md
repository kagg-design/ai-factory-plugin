# ROCK prototype omits required distribution files

Date: 2026-10-23. Found while finishing the authorized ROCK implementation and
test-fixture repair in the Factory development chat.

The initial feature commit `9840a27` added four runtime scripts, two resources
and two test suites without listing them in `MANIFEST.json`. The new slot-fill
helper also needs to ship with the test entrypoint. A checkout contains these
files, so source-based tests alone would not expose an incomplete distribution.

The manifest now includes these runtime/test dependencies and the ROCK rollout
documentation. The focused ROCK suite explicitly requires every new runtime and
test dependency to be both listed and present. This correction is part of the
already-authorized feature and test packaging work; no live runtime is changed.

The entrypoint dependency check also found five pre-existing omissions:
orchestrator-name, session-project-labels, timestamp-normalization,
worker-chat-attention-amend and worker-result-followup suites. They are now
listed. The test harness checks every directly referenced `.tests.ps1` against
the manifest, preventing the same packaging defect when more suites are added.
The final dependency check passed for all 22 directly referenced suites and all
132 manifest entries. The focused ROCK suite passed after the runtime/test files
were added to the bundle inventory.
