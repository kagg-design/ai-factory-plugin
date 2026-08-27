# TASK — the pipeline's merge commits must name the task they publish

## The problem, as seen by the operator

`git log` on a project's production branch reads like this today (real output, `motivehr`, 2026-08-27):

```
da3c25d Merge commit '344b3012503c989a01fe4e1fc99dc67bdeb4ccc9' into factory/release
344b301 Merge commit '85c319da36aeccd3e7ceb761671a2d285e0d83e2' into factory/integrator
85c319d fix(local:20260827-172032-b2757c43): needles a Faker name cannot collide with
```

Two of those three lines carry no information a human can use. `factory/integrator` and
`factory/release` are internal worktree branches that exist for seconds; the quoted SHA is the thing
being merged, which the reader would have to look up to learn anything at all. Eleven tasks were
published to that repository on one day, so the history is now mostly these lines.

> **Igor Gergel, 2026-08-27:** «Сообщение нечитаемое абсолютно. Можно как-то сделать так, чтобы здесь
> я видел номер задачи, которая мержится?»

Yes. Every fact needed is already in scope at the merge call site; nothing has to be looked up or
stored.

## Where it comes from

`scripts/integrate-task.ps1`:

- **`Invoke-PipelineMerge`, lines 85-99** — the only place either merge is created:

  ```powershell
  $merge = Invoke-FactoryNativeProcess -Command "git" -Arguments @(
      "-c", "commit.gpgsign=false", "-C", $Worktree,
      "merge", "--no-ff", "--no-edit", $Commit
  )
  ```

  No `-m`, so git writes its own message from the ref it was handed — a raw SHA — and the branch the
  worktree happens to be on.

- **Call site 1, line 302** — development: `-Commit $taskCommit -Label "Development"`, in the
  integrator worktree based on the fetched development tip.
- **Call site 2, line 307** — production: `-Commit $productionSource -Label "Production"`, in the
  release worktree based on the fetched production tip. `$productionSource` is `$taskCommit` when
  `productionMode` is `task-only` and the *development merge commit* otherwise (`merge-develop`),
  which is why the second line above quotes a merge SHA rather than the task's own commit.

## What is in scope at both call sites

Verified against a live `state.json`, so use these and do not invent fields:

| Value | Development | Production |
|---|---|---|
| `$task.id` | `1217866656111884` or `local:20260827-142830-0f64896c` | same |
| `$task.title` | `Team PTO: фильтр «только прямые подчинённые»` | same |
| `$task.source.adapter` | `asana` / `local` | same |
| `$task.url` | `https://app.asana.com/0/0/1217866656111884`, or `factory://local/<id>` for a local task | same |
| `$task.source.suppliedUrl` | the URL the operator actually pasted, including the project segment | same |
| `$taskCommit` | the approved task commit | same |
| `$plan.developmentBranch` / `$plan.productionBranch` | `develop` / `master` | same |
| `$Label` | `"Development"` | `"Production"` |

## Required shape

`Invoke-PipelineMerge` takes the message from the caller. Both call sites pass one built from the
task. Development merge:

```
Merge task 1217866656111884 into develop

Team PTO: фильтр «только прямые подчинённые»

Task:    https://app.asana.com/1/14748072439266/project/1215506997644941/task/1217866656111884
Commit:  dc87716
```

Production merge, `merge-develop` mode — the second line says what is actually being promoted,
because it is the development merge and may carry unrelated commits:

```
Merge task 1217866656111884 into master

Team PTO: фильтр «только прямые подчинённые»

Promoting: develop (may include commits from other tasks)
Task:      https://app.asana.com/1/14748072439266/project/1215506997644941/task/1217866656111884
Commit:    dc87716
```

Production merge, `task-only` mode: same, with `Promoting: this task's commit only`.

Rules for building it:

1. **Subject line: `Merge task <id> into <branch>`.** The id is `$task.id` verbatim — for a local
   task that is `local:20260827-142830-0f64896c`, which is ugly but is the identifier the operator
   sees everywhere else, so it stays. The branch is the real target (`develop` / `master`), never the
   internal `factory/*` branch the worktree sits on.
2. **The title goes in the body, not the subject.** Titles here run to 80+ characters and are
   frequently non-ASCII; a 50-character subject convention cannot hold them, and truncating a title
   mid-word is worse than putting it on its own line. Take the first non-empty line of `$task.title`,
   trimmed. Omit the paragraph entirely when the title is empty — never emit a blank line where a
   title should be.
3. **`Task:` carries `$task.source.suppliedUrl` for a connector task** — it is the one that includes
   the workspace and project segments and therefore opens for a human, unlike the bare
   `$task.url` form (`https://app.asana.com/0/0/<id>`). Fall back to `$task.url` when
   `suppliedUrl` is absent.
4. **A `factory://` URI must never appear in a commit message.** For `adapter = local` emit
   `Source:  local / <source id>` instead of a `Task:` line. That URI is internal and the public
   skill already forbids showing it to the operator as a URL; a commit message is the most public
   place there is.
5. **`Commit:` is the short `$taskCommit`.** Keep it: it is what makes the merge greppable back to
   the branch that produced it, and in `merge-develop` mode it is the only mention of the task's own
   commit anywhere in the merge.

## Two implementation constraints, and they are the whole risk

**Do not pass the message as an argument.** These titles are Cyrillic today and will be worse
tomorrow, and passing non-ASCII argv to a native process from PowerShell 5.1 is exactly the hazard
`docs/tasks/TASK-windows-powershell-native-utf8-capture.md` was written about. Write the composed
message to a UTF-8 (no BOM) temp file and use `git merge --no-ff --no-edit -F <file>`, then delete the
file in a `finally`. This also removes any quoting question about a title containing `"`, `'`, `«»`,
`$` or a newline — none of which can then reach a command line.

**Do not change what is merged, or when.** `--no-ff` stays, `commit.gpgsign=false` stays, the abort
path on conflict stays, and the function must still return the merge commit SHA it returns today
(`integrate-task.ps1:98`), because `$integrationMerge` becomes `$productionSource` and both are
recorded in the audit objects at lines 328 and 351. A message-only change must not move a single
SHA that the pipeline validates afterwards.

## Out of scope, deliberately

- **The worker's own commit subject** (`fix(local:20260827-172032-b2757c43): …`). It is written by the
  worker agent, not by this script, and changing that convention is a different decision.
- **Rewriting history.** The eleven merges already on `motivehr`'s branches stay as they are.
- **`Merge branch 'develop'` commits** made by a human pushing develop into master by hand. Not ours.
- Any change to `sync-task.ps1`'s rebase, which produces no merge commit at all.

## Acceptance

`tests/run-tests.ps1` is the harness — it already builds a scratch repository with a real remote and
drives the pipeline with fake `claude`/`codex`/`psql` binaries. Add coverage there, and make it assert
the message rather than the exit code:

- [ ] A connector task published end to end: the development merge subject is
      `Merge task <id> into <development branch>`, the body carries the title, and the `Task:` line
      carries `suppliedUrl`.
- [ ] The production merge in `merge-develop` mode names `develop` as what is being promoted; in
      `task-only` mode it says the task's commit only.
- [ ] A **local** task: no `factory://` anywhere in either message, and a `Source: local / <id>` line
      instead.
- [ ] A task whose title is **Cyrillic and contains `«»` and an apostrophe**: the message round-trips
      byte-for-byte through `git log -1 --format=%B`. This is the test that would have caught the
      argv encoding trap, so it is not optional.
- [ ] A task with an **empty title**: no stray blank paragraph, and the merge still succeeds.
- [ ] Both merge SHAs still flow into the audit objects, and `Test-PipelineAncestor` still passes for
      the task commit against both published branches — i.e. the existing publication assertions in
      the harness are unchanged and still green.
- [ ] `pwsh tests/run-tests.ps1` green as a whole; no other test edited to accommodate this.
