# TASK — a correct FACTORY_RESULT gets rejected: marker lookup and changedFiles validation

## The problem, as seen by the operator

One task, `motivehr` / TASK-PWA-001 (`local:20260830-171624-a9ff2bfd`), 2026-08-30. The worker
finished, committed `ad88ed1`, left a clean tree — and then the envelope took **three rounds** to be
accepted. The code under review never changed: `HEAD` stayed `ad88ed1` and
`git status --porcelain` stayed empty through all three.

```
round 1  status: failed   error: Reported changedFiles do not match commit 'ad88ed15785f75db38ed...'
round 2  status: held     error: Background session stopped without a FACTORY_RESULT.
round 3  status: awaiting-review
```

Round 2 is the interesting one: the transcript **and** the stored event both contain a complete,
valid `FACTORY_RESULT` block with the right SHA and 17 correct paths. The factory reported that no
result had been emitted at all.

Round 3 only worked because the orchestrator ran the validator's own git command by hand and pasted
the twenty expected paths into the worker's instructions. That is not a workflow; that is a person
doing the plugin's job.

Cost: about 35 minutes of operator and worker time, on a task whose implementation was already
correct and had already passed 4036 tests.

---

## Bug A — the marker is located with `LastIndexOf`, so a mention inside the payload wins

`scripts/worker-event.ps1`, `Publish-FactoryWorkerEvent`, lines 24-47:

```powershell
foreach ($candidate in @(
    [pscustomobject]@{ Marker = "FACTORY_RESULT"; Kind = "result" },
    [pscustomobject]@{ Marker = "FACTORY_PLAN"; Kind = "plan" }
)) {
    $markerIndex = $Message.LastIndexOf([string]$candidate.Marker, [StringComparison]::Ordinal)
    if ($markerIndex -lt 0) { continue }
    $jsonText = $Message.Substring($markerIndex + ([string]$candidate.Marker).Length).Trim()
    ...
    $firstBrace = $jsonText.IndexOf('{')
    $lastBrace = $jsonText.LastIndexOf('}')
    if ($firstBrace -lt 0 -or $lastBrace -lt $firstBrace) { continue }
```

`LastIndexOf` takes the **last** occurrence of the literal in the whole message. In round 2 the
worker's own `notes` field contained the string, because the orchestrator's instruction had asked it
to "emit `FACTORY_RESULT` again":

```json
"notes": "Повторная выдача FACTORY_RESULT после отказа фабрики «Reported changedFiles do not match commit» ..."
```

So the marker matched inside `notes`, the substring after it held no `{`, `continue` ran, the
`FACTORY_PLAN` candidate was not found either, and `$kind` stayed at its initial value `"message"`.
The event was written as an ordinary message; the task later held with *"stopped without a
FACTORY_RESULT"*. Nothing anywhere said "a marker was found and could not be used" — the
`invalid-marker` branch is only reachable when `ConvertFrom-Json` throws, not when the brace scan
walks off the end.

**The trigger is routine, not exotic.** Any instruction that names the marker ("emit FACTORY_RESULT
again", "your FACTORY_RESULT was rejected because…") will be quoted back in `notes` or `summary` by a
model that is being conscientious about explaining itself.

### Required

Locate the marker deterministically:

1. Prefer the **first** match of the marker on a line of its own — `(?m)^[ \t]*FACTORY_RESULT[ \t]*$`
   — which is exactly the shape `agents/worker.md` and `resources/codex-worker-instructions.md`
   already document.
2. If no standalone-line match exists, fall back to the **first** `IndexOf`, not the last.
3. Parse the JSON from the first `{` after the chosen marker to its matching close.
4. If a marker is found and the JSON cannot be parsed, the event must be `invalid-marker` **and the
   reason must reach the task's `error`**, so the operator sees "your JSON is broken" rather than
   "you emitted nothing".

`FACTORY_PLAN` runs through the same loop and gets the same fix for free. Keep both in one code path.

---

## Bug B — `changedFiles` is checked by string equality against a rename-blind git command

`scripts/reconcile-worker-sessions.ps1`, lines 293-301:

```powershell
$actualFiles = @(& git -C $task.worktree diff-tree --no-commit-id --name-only -r $resolvedCommit 2>$null |
    Where-Object { $_ } |
    Sort-Object -Unique)
$reportedFiles = @($result.changedFiles | ForEach-Object { [string]$_ } | Sort-Object -Unique)
if (($actualFiles -join "`n") -ne ($reportedFiles -join "`n")) {
    $validationError = "Reported changedFiles do not match commit '$resolvedCommit'."
}
```

`diff-tree` here carries no `-M`, so rename detection is **off** and every `git mv` in the commit
appears as two paths. Meanwhile git's own default is `diff.renames=true` (since 2.9), so everything a
worker naturally reaches for — `git show --name-only`, `git log --stat`, `git diff --stat` — collapses
a rename into one path. The two sides disagree by construction on any commit containing a rename.

TASK-PWA-001 moved four icons from `public/icons/` to `public/`. The worker reported 17 paths; the
validator expected 20. The three "missing" ones were the delete sides of the renames:

```
public/icons/icon-192.png
public/icons/icon-512.png
public/icons/icon-maskable-512.png
```

The worker's list was not wrong. It was a different, equally true rendering of the same commit.

**And the contract never said which one.** `agents/worker.md:96-97` asks the worker to "Capture the
branch, full SHA, absolute worktree path, changed files, and exact test outcomes", and the schema at
`resources/result.schema.json:12` says `changedFiles` is an array of strings. No command is named in
either place, nor in `resources/codex-worker-instructions.md:78`. So the plugin validates a hand-copied
list against a specific git invocation it never disclosed.

### Required — preferred shape

Stop asking a language model for a list git already knows.

- `scripts/sync-task.ps1` already owns the helper — `Get-FactoryChangedFiles` — and uses it at lines
  154, 190, 208 and 285. Use the same helper in `reconcile-worker-sessions.ps1`: **derive**
  `changedFiles` from the validated commit and store the derived list on the task.
- Keep the worker's reported list for diagnostics only: when it differs from the derived one, write a
  note into the event (or the task's log), do not fail the task.
- The three checks that actually protect integrity stay exactly as they are, and stay blocking:
  `HEAD` equals the result commit, the worktree is on the task branch, the worktree is clean.

Rationale: a mismatch in this list has never indicated a real problem. It cannot — the commit is the
authority, and it is right there. The check's only demonstrated effect is rejecting correct work.

### Required — acceptable alternative

If the list must stay a check rather than a derivation, then:

- compare **rename-insensitively** on both sides (add `-M` to the validator, or normalise both lists
  through the same command), and
- write the exact command into both worker contracts (`agents/worker.md` and
  `resources/codex-worker-instructions.md`) so the worker and the validator quote the same thing.

Half of this is not enough: documenting the command without fixing the comparison leaves every
rename-carrying commit one typo away from a false rejection.

---

## Bug C — the rejection does not say what differed

The whole message is:

```
Reported changedFiles do not match commit 'ad88ed15785f75db38ed9434f5294bdff8544022'.
```

The operator (or the worker) then has to guess whether a path is missing, extra, or misspelled. In
this case the answer was three specific paths, and finding it required reading the plugin's source.

### Required

When the list check fails — whichever shape survives Bug B — the error names the difference: the
paths present in the commit and absent from the report, and vice versa, capped at a handful with a
"+N more" tail. One line of PowerShell, one round saved every time it fires.

---

## Note D — `claude stop` bypasses the Stop hook (document, do not "fix")

`claude stop <id>` terminates the background session without running its `Stop` hook, so a result
that session printed never becomes an event. During round 2 above, stopping the session that looked
stuck in `working` destroyed the only path by which its (already printed) result could have been
imported.

Add to the skill's troubleshooting section, in `standalone/.claude/skills/factory/SKILL.md`: before
stopping a session that appears stuck in `working`, read

```
runtime/projects/<project>/events/<task-artifact-name>/latest.json
```

which stores `lastAssistantMessage` whole plus the parsed `payload`, and says whether the last turn
was classified as `result`, `plan`, `message` or `invalid-marker`. That file answered the whole
question in five seconds once someone thought to open it.

---

## Verification

Add cases to `tests/run-tests.ps1`, in the style already there:

1. A result payload whose `notes` contains the literal `FACTORY_RESULT` is still classified `result`,
   with the payload parsed. *(Bug A, the exact round-2 failure.)*
2. The same for `FACTORY_PLAN` inside a plan's own prose.
3. A marker followed by unparsable JSON produces `invalid-marker`, and the reason reaches the task's
   `error`.
4. A fixture commit created with `git mv` validates and the task reaches `awaiting-review`.
   *(Bug B, the exact round-1 failure.)* If the derivation route is taken, assert that the task's
   stored `changedFiles` lists **both** sides of the rename, so the review UI keeps showing the
   deletion.
5. A deliberately wrong reported list produces an error naming the missing and the extra path.
   *(Bug C.)*

Run the existing suite as well; these three functions sit on the path every task takes.

## Out of scope

- The state machine, `integrate-task.ps1`, and everything about publication.
- The `motivehr` repository. TASK-PWA-001 is published (develop `e32bad3`, master `f7eb502`); nothing
  there needs to change for this.
- Making the worker's reported list richer (statuses, rename arrows). If it becomes diagnostics, plain
  paths are enough.
