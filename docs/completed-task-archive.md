# Completed task history

`factory status` reports distinct task IDs with a production or development
outcome across `archive/completed-tasks.jsonl` and live `done` tasks. A task
already present in both counts once. Rejected rows are retained for audit and
excluded from COMPLETED. `factory status done --limit 25` lists the newest
completion rows; default limit is 50, allowed range 1–1000. Multiple commits for
a reopened task remain separate history rows, with one distinct completed ID.
If the archive is absent, status explicitly labels the figure as live-only and
points to `factory archive:seed`.

## Storage and recovery

Each UTF-8 JSONL row contains exactly `id`, `title`, `outcome`, `commit`,
`landedAt`, `attempts`, `source`, and `archivedAt`. The source is a compact
adapter/ID/URL object. Titles and source metadata are bounded so each serialized
row, including its newline, stays below 1,024 bytes. IDs and commits are never
truncated. Briefs, plans, review text, and worker results are not copied.

Cleanup appends after artifact removal, when recording `done`. Both retained
and discarded rejection paths append a rejected summary. These writes use the
existing project mutex and deduplicate by `(id, commit)`. The append is flushed
before the terminal ledger write; a failure between them leaves recoverable
history, and retrying does not duplicate the row. Interrupted cleanup before
finalization has no completion row. Archive operations never rewrite existing
bytes. Readers skip malformed rows with a warning; a subsequent append separates
an incomplete tail with a newline while retaining the original bytes.

Run `factory archive:seed --preview` to inspect the proposed union, then
`factory archive:seed` to append it. The command reads the two named recovery
snapshots, `archive/completed-tasks.json`, live terminal tasks, and all reachable
`fix(<id>):` / `feat(<id>):` subjects from the locally available production ref
(development ref for projects without production). Fetch the publication ref
first if it is unavailable or stale. The seeder does not fetch or change Git.
Only `done` and `rejected` snapshot tasks are eligible. Short commit hashes are
resolved locally when possible. Existing archive rows win on an identical key.
Repeat seeding with unchanged sources leaves the file byte-for-byte identical.

The exact misleading specification commit
`553ccc6ac3cafbda2418ea26ba5cfbd79afe73b6` is excluded from Git candidates.
Other documentation commits are not broadly excluded. Git-derived `landedAt`
uses the commit timestamp, which is not necessarily the production push time;
snapshot rows prefer publication/integration audit times and then task update
time. Unknown commit values are null. The two snapshots and old JSON archive
are retained in place unchanged. The ledger schema, task state machine, previous
backup, removal guard, and scheduler heartbeat are unchanged.

## MotiveHR source discrepancy (September 12, 2026)

The source specification expected 207 distinct IDs. That is the Git subject-ID
count, not the complete union of surviving sources. The operator explicitly
chose to preserve all 231 source IDs and report the discrepancy. Literal source
IDs are retained, including IDs recorded differently from their Git subject
scope; they are not silently canonicalized or discarded to force 207.

The live seed at production ref `ce9cd4e3b438483c9a190ab370ebe0cc589e8008`
produced 249 distinct `(id, commit)` rows and 231 distinct completed IDs:

| Source | Scanned | Eligible | New rows in union |
| --- | ---: | ---: | ---: |
| September 4 snapshot | 157 | 151 | 151 |
| September 1 snapshot | 139 | 108 | 0 |
| July 28 JSON archive | 6 | 6 | 6 |
| Live state | 2 | 2 | 2 |
| All production Git subjects | 225 | 224 | 90 |

Git contributes 207 distinct subject IDs. Recovery sources contain 24 additional
completed IDs, for 231 total. Applying the original September 4 Git cutoff
would yield only 205 IDs in the source union. All Git history is included to
preserve older deliveries missing from the snapshots, as authorized by the
operator. Reopened IDs explain why row count exceeds distinct IDs.

Live validation confirmed `factory status done --limit 3` reports **231** and
shows three of 249 rows in descending date order. The archive is 96,893 bytes;
its largest row including LF is 476 bytes. A second seed appended zero rows
with the same SHA-256:
`C20ED72811C0404451459E21598DB354D4C18E0560DB825563D92D48BF8EF96A`.
The known specification commit has zero archive rows. Recovery source SHA-256
values were checked before and after both seeds and remained unchanged:

| Preserved source | SHA-256 |
| --- | --- |
| September 4 snapshot | `71194255C46FA24A66890CE3E13A0C5229059AB95DE1CA619DA6963CCD3EB71D` |
| September 1 snapshot | `1C3C71057003B7787B5AE0E645F83E07F381E2D1324F9A2E813FE9556CEA6AAE` |
| July 28 JSON archive | `7717BCEF6A2D9D9B35B640D5015793063CF1184A570DD0A050FD5254E6440CD1` |

## Regression evidence

Before the implementation, the disposable wiped-ledger test observed COMPLETED
fall from **2 to 0**, despite two archived summaries. With the archive reader,
the same test preserves **2 to 2** and proves live/archive deduplication.

`powershell -File tests/run-tests.ps1 -ArchiveOnly` covers the wipe, missing
archive messaging, torn-tail recovery, project-mutex ownership, rejected
exclusion, newest-first bounded history, source preservation, reopened commits,
summary size including Unicode, and byte-for-byte repeat seeding. The complete
`tests/run-tests.ps1` harness also checks real cleanup, interrupted/resumed and
repeated cleanup, and both rejection paths using its fake runtimes.

Validation completed successfully on September 12, 2026:

- `powershell -NoProfile -ExecutionPolicy Bypass -File tests/run-tests.ps1 -KeepTemp`
  exited 0 with **All factory runtime tests passed**. Evidence is retained at
  `C:\tmp\claude-factory-plugin-tests-9802a6b7394648e5992ad8092ed38bf1`.
- The focused archive suite passed again after correcting `--preview` argument
  binding. PowerShell 7 history rendering and timestamp ordering also passed.
- Harness archive readback confirmed one production summary for regular and
  resumed cleanup, one development-only summary, and rejected summaries for
  both retained and discarded tasks.
- Changed scripts parse successfully, `git diff --check` passes, and the
  protected ledger, initialization, state template, and scheduler files have no
  changes in this patch.
