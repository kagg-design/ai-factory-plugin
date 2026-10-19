# Factory quality gates: security check before merge, escaped-defect metrics

Spec for Codex. Target: Igor's factory (PowerShell scripts + Claude skills on his Windows laptop). Date: 2026-10-19, rev. 3 (rev. 2: metrics per project, metrics task, Part C — gate fixes; rev. 3: C4 covers amend, C6 is decided, new C7 — each factory claims only its own repo's tasks). It builds on `factory-asana-integration-spec.md` rev. 2: the Factory field, the comment tags, owners and watchers.

## 1. Context

- The factory merges into `develop` and `master`, and Buddy deploys straight after. **A merge is a deploy.**
- The company's AI Adoption Matrix (Development, Transformative) asks for two things this spec adds:
  - merging is gated by acceptance criteria, automated tests **and security scans**;
  - people supervise the system through **escaped-defect and regression rates** rather than reviewing every change.
- **Part A** adds a security check to the factory's pre-merge gate.
- **Part B** adds escaped-defect metrics.
- Neither part uses Claude. Both are plain PowerShell, the Asana REST API and repo commands, so they cost no tokens.

Asana IDs (workspace, project, sections, the Factory field and its options, Resolution) are in section 2 of rev. 2. Additional IDs:

| What | GID |
|---|---|
| Field Type | `1215172784016194` |
| Type = Bug | read the option list once at startup; don't hard-code it |
| Field Reporter (text) | `1215172784016216` |
| Field Priority | `888632492263633` |

## Part A — Security check before merge

### A1. Configuration

Per repository:

```json
"repos": {
  "awesomehr": {
    "securityCommand": "composer security",
    "securityPresentWhen": "composer.json has scripts.security"
  },
  "cloud-infrastructure-auditors": {
    "securityCommand": null
  }
}
```

The AwesomeHR side — the `composer security` command itself — is a separate task on the board, "AwesomeHR: security checks before merge — dependency audit and secret scan". Until it merges, the command does not exist yet.

### A2. Behavior

1. After the tests pass and before merging into `develop`, the worker runs `securityCommand` in its worktree.
2. **Exit 0.** Continue. Copy the command's summary lines into the DONE comment under a `Security:` line.
3. **Non-zero.** Treat it exactly like a failing test:
   - fix the finding within the task (upgrade the dependency, remove the credential), or
   - if the fix is outside the task's scope, set FAILED and include the summary.
4. **Baseline.** The worker never adds a baseline entry on its own: suppressing a finding is a decision. It asks with `QUESTION (factory):` and waits for the owning orchestrator or Igor.
5. **Not configured for the repo.** Skip. The DONE comment says `Security: not configured for this repo`.
6. **Configured but not present in the repo yet** (`securityPresentWhen` is false). Skip and merge. The DONE comment says `Security: command not present yet`.
7. **No secret values.** The repo command masks them. The factory relays only the summary lines and never raw scanner output.

The AwesomeHR security task carries a merge gate. The factory already handles merge gates (rev. 2, A3).

### A3. Acceptance

- [ ] An awesomehr task that introduces a known-vulnerable dependency is not merged: the worker fixes it or sets FAILED with the summary.
- [ ] A clean task's DONE comment has a `Security:` line with the summary.
- [ ] A finding the worker would like to baseline produces a QUESTION, not a baseline edit.
- [ ] A repo with no command: `Security: not configured for this repo`.
- [ ] Before the AwesomeHR security task merges: `Security: command not present yet`, and the merge goes ahead.

## Part B — Escaped-defect metrics

### B1. Definitions

- **Factory task:** any task on the board with a Factory value.
- **Done task:** Factory = Done. Its `completed_at` is the done time.
- **Escaped defect:** a task with Type = Bug whose description contains:
  ```
  Escaped-from: <gid>[, <gid>...]
  Found-in: verification | ci | stage | prod | external
  Regression: yes          (optional)
  ```
  - Every gid in `Escaped-from` must be a Done task.
  - `external` means a real external system was affected, e.g. tasks created on the live board by a test run.
  - Orchestrators follow this rule from 2026-10-19: Igor's comment on the access epic, written into its Factory interface section. The factory follows it too when it files such a task itself.
- **Fallback.** Some bugs have no `Escaped-from` line but look like escaped defects: Type = Bug, a Factory value, and Reporter = `access-orchestrator` or `billing-orchestrator`. Count each one with origin `unknown` and Found-in `unknown`, and list it separately in the report so Igor can fix it.
- **Seed.** Five follow-ups were filed before the rule existed. A description line, if present, wins over the seed.

| Bug | Escaped from | Found in |
|---|---|---|
| `1219603269391307` bamboohr:reset guard | `1219601066607741` account storage | verification |
| `1219603808377002` Metabase lookup asks every address | `1219601066591116` Metabase connector | verification |
| `1219607755346455` lifecycle tests must not reach Asana | `1219600878769036` dispatch point | external — a test run created 50 tasks on the live board |
| `1219609793800273` offboarding executor follow-up | `1219600856229897` offboarding executor | verification |
| `1219610138861663` PlanetScale default postgres role | `1219600856222205` PlanetScale | verification |

### B2. Script `factory-metrics.ps1`

**Parameters**

| Parameter | Meaning |
|---|---|
| `-Since <date>` | Start of the window. Default: 7 days ago. |
| `-Until <date>` | End of the window. Default: now. |
| `-Post` | Post the summary comment. |
| `-DryRun` | Print the summary; write nothing, post nothing. |

**Reads**

- Every task in the project with a Factory value: search with `custom_fields.<factory>.is_set=true` and `opt_fields=name,notes,completed,completed_at,created_at,custom_fields,permalink_url`.
- Stories only where timings need them: the `TAKEN (factory)`, `DONE (factory)`, `QUESTION (factory)` and `FAILED (factory)` comments.
- A task's repo is taken from its first line `Repo: <owner>/<name>`; without one it is the default repo from config (awesomehr).

**Computes** — all-time and for the window, per repo and in total:

- **done** — Done tasks, by `completed_at`.
- **escaped** — escaped defects, counted by the bug's `created_at`, which is when it was found.
- **escape rate** — Done tasks with at least one escaped defect, divided by Done tasks. Also report defects per Done task. Bug fixes count as Done tasks too, because a fix can escape as well.
- **by Found-in** — counts, including `unknown`.
- **regressions** — count.
- **time to find** — the bug's `created_at` minus its origin's `completed_at`, as a median.
- **cycle time** — from `TAKEN (factory)` to `DONE (factory)`, as median and p90. Tasks without both comments (transitional mode) are left out and counted.
- **failed** — tasks now in Failed, plus `FAILED (factory)` comments in the window.
- **questions** — `QUESTION (factory)` comments in the window.

**Writes** — one folder per project, i.e. per repo the factory works in, inside the factory state dir:

```
metrics\awesomehr\
metrics\cloud-infrastructure-auditors\
metrics\_all\            totals across projects
```

A new project gets its folder on the first run that sees a task for it. Each folder holds:

| File | Content |
|---|---|
| `escaped-defects.csv` | Rewritten each run. One row per bug: gid, name, origin gids, Found-in, regression, bug `created_at`, origin `completed_at`, days to find, source (`line`, `seed` or `fallback`). |
| `weekly.csv` | One row appended per run with `-Post`: window, done, escaped, escape rate, questions, failed, median cycle time. |
| `latest.md` | Human-readable summary, plus sections "Fallback — needs an Escaped-from line" and "Unparsed lines". |

A defect belongs to the project of its origin task. If its origins span projects, it is counted once in each of them and once in `_all`.

**Posts** (with `-Post`) one comment starting with `[factory-metrics]` on the task in config `metricsTaskGid`, with one section per project and a total. The task is **Factory: weekly metrics**, `1219642983524480`. It is not a dependency of any epic, so the comment wakes no orchestrator. If `metricsTaskGid` is empty, the script posts nothing.

`[factory-metrics]` is an agent tag. Like every tagged comment, it never counts as Igor (rev. 2, 3.2).

**Schedule.** `install-factory-metrics-task.ps1` registers a weekly run, Monday 09:00 local, with `-Post`.

**Safety**

- Read-only on Asana except that one comment.
- The PAT comes from the env var, as in rev. 2.
- A malformed line goes into "Unparsed lines" and never stops the run.

### B3. Acceptance

- [ ] A run with `-Until 2026-10-19T10:05:00Z` counts the 5 seeded escaped defects: 4 `verification`, 1 `external`. The Done count matches the board's Factory = Done tasks at that time; on 2026-10-19 that was 29 across both repos.
- [ ] A new Bug with an `Escaped-from` line is picked up on the next run, and its line overrides the seed.
- [ ] A Bug that matches the fallback but has no line is counted and listed under "Fallback".
- [ ] A malformed `Escaped-from` line goes into "Unparsed lines"; the run completes.
- [ ] The folders `awesomehr`, `cloud-infrastructure-auditors` and `_all` exist after the first run, and `_all` equals the sum of the projects, apart from defects counted in several projects.
- [ ] `-Post` puts one comment on `1219642983524480` with a section per project.
- [ ] `-DryRun` writes and posts nothing.
- [ ] Without `metricsTaskGid`, `-Post` writes the files and posts nothing.
- [ ] No secret value appears in any output.

## Part C — Gate fixes

The access orchestrator found these in the first two days: cycles 13, 14 and 16 on the access epic, questions Q12 and Q13. Each one weakens a gate that rev. 2 already describes.

### C1. Claim only Ready

**Seen:** a task whose Factory field had been set to Done by mistake was taken 79 s later, and Taken was never set.

**Fix:**
- Compare the Factory value by option gid (`1219588322328562`), never by name or by "has a value".
- Re-read the task right before claiming it.
- Set Taken, then read it back. If the read-back is not Taken, abort the claim and log it.

### C2. Enforce the merge gate

**Seen:** the merge-gated dispatch point merged about 5 minutes after Ready, with no TAKEN, no ask and no confirmation on Asana.

**Fix:**
1. A task whose description contains `Merge gate: ask Igor before merging` is never merged without Igor's explicit yes.
2. Before asking, the factory posts on the task: `MERGE GATE (factory): ready to merge <sha>. Waiting for Igor: answer in the terminal, or comment /merge here.`
3. Igor answers in the terminal or with an untagged comment starting `/merge`, which can come from his phone. Either counts.
4. Before merging, the factory records it on the task: `MERGE GATE (factory): Igor confirmed (<terminal|comment>) at <UTC time>. Merging <sha>.`
5. No recorded confirmation, no merge.

### C3. A new Ready means a fresh run

**Seen:** after FAILED and a re-groom, the task went Ready again, and the factory merged the old retained result, not the re-groomed spec.

**Fix:**
- A task set to Ready after any earlier run starts a fresh run from its current description.
- A result produced before the latest Ready is never merged.
- If the description names a commit to start from, the fresh run starts there.

### C4. Record the result after the final rebase

**Seen:**
- In the AwesomeHR factory, a worker rebased after its result commit had been recorded. The factory then saw a HEAD mismatch and set FAILED.
- On 2026-10-19 the auditors factory hit a similar problem with `git commit --amend`, which Igor had to sort out by hand.

**Fix:**
- The recorded result is the HEAD after the last history change, whether that was a rebase or an amend. The DONE comment names that HEAD.
- Never rebase or amend after recording a result without recording it again.

### C5. Stalled workers

**Seen:** FAILED came 11.5 h after the worker's last activity.

**Fix:** if a worker shows no activity for `stallHours` (default 2), post `FAILED (factory): stalled, no activity since <time>` and release the worktree for inspection.

### C6. No live credentials in worktrees (Q12, option b)

**Seen:** every worktree's `.env` is a copy of the developer `.env`, live Asana token included. A test run created 50 tasks on the live board this way. The `phpunit.xml` pin now covers the test suite, but not artisan commands a worker runs.

**Fix:**
- When a worktree is created, copy `.env` but blank every key matching config `blankEnvKeys`.
- Default list: `ASANA_ACCESS_TOKEN`, `ACCESS_*`, `BILLING_*`, `GITHUB_APP_*`, `GCS_KEY_FILE`, and any `*_TOKEN`, `*_SECRET` or `*_API_KEY`.
- Keep `APP_KEY`, `DB_*` and anything the local test database needs.
- Log the names of the blanked keys, never the values.

Decided: Igor answered Q12 — b on 2026-10-19.

### C7. Each factory claims only its own repo's tasks

**Seen (2026-10-19):** the cloud-infrastructure-auditors factory claimed TASK-ACCESS-OFFBOARD-003, an AwesomeHR task. It created a worktree and a branch in the auditors repo and wrote the task's spec file there; Igor stopped it by hand. Rev. 2's rule (`factory-asana-integration-spec.md`, A2: a task whose description starts with `Repo:` belongs to another repo) never said whose a task *without* that line is, so the auditors factory took it as its own. A merge there would have deployed the auditors.

**Fix:**
- **Own repo.** Every factory instance has a configured `repo`: `awesomehr` or `cloud-infrastructure-auditors`, plus any later one.
- **The task's repo** comes from its first line `Repo: <owner>/<name>` if there is one. Otherwise it is the board default, config `defaultRepo` = `awesomehr`.
- **Claim only a match.** The poller claims a Ready task only when the task's repo equals its own. The check runs before Taken is set and before any worktree or branch exists. A mismatch is skipped silently, logged at debug level only.
- **Manual `add` too.** `add <asana-link>` for a task of another repo refuses with a clear message naming both repos, unless `--force` is given.
- This replaces rev. 2's A2 "Repo" bullet.

### C8. Acceptance

- [ ] A task with Factory = Done, Failed or empty is never claimed. A claim whose read-back is not Taken aborts.
- [ ] A merge-gated task waits at the `MERGE GATE` comment. It merges after a terminal yes or a `/merge` comment, and the confirmation is recorded on the task before the merge.
- [ ] Re-Ready after FAILED runs from the current description. A stale result is not merged.
- [ ] The DONE comment's HEAD equals the merged commit even when the worker rebased or amended.
- [ ] A worker silent for `stallHours` gets FAILED with "stalled".
- [ ] A new worktree's `.env` has the listed keys blank and `APP_KEY` and `DB_*` intact. The log lists only key names.
- [ ] A Ready task without a `Repo:` line is never claimed by the auditors factory. A task with `Repo: …/cloud-infrastructure-auditors` is never claimed by the AwesomeHR factory. No worktree or branch is created for a skipped task.
- [ ] `add` of another repo's task refuses without `--force`.

## 4. Out of scope

- **Audit samples:** Igor's detailed review of every Nth Done task. Next step.
- **Turning recurring escaped defects into permanent repo rules** (CLAUDE.md, guard tests). This is the orchestrators' job, via the factory's normal tasks.
