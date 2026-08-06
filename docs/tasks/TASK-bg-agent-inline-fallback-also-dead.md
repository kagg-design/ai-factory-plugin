# TASK — the inline `--agents` fallback is dead too: `--agent` cannot be resolved at bg-spawn at all on 2.1.222

Author: orchestrator session, 2026-08-05. Everything below was observed on live runs of this plugin
against the `motivehr` repository today, on **`claude --version` → 2.1.222 (Claude Code)**, plugin
manifest **factory v3.0.0**, `$PSVersionTable.PSVersion` → **5.1.26100.8875**. Every claim is backed
by a command and its real output; anything unverified is marked **(unverified)**.

This is the successor to `TASK-bg-agent-resolution-and-psmodulepath.md`. That task's P1 fix (one
automatic inline `--agents` fallback, version-scoped capability cache) **is present in the working
copy and executes exactly as specified — and it does not work**, because the CLI rejects the inline
agent name for the same reason it rejects the plugin one. P2 (.NET SHA-256, doctor cmdlet checks) is
in place and healthy; nothing below concerns P2.

**Net effect: the factory still cannot launch any worker.** Ten freshly queued tickets are waiting.
The launcher continues to fail closed, which is why the queue stalls instead of producing
default-template garbage in a worktree.

## Context you need before touching anything

- Plugin root: `C:\laragon\www\Projects\claude-factory-plugin`. Scripts in `scripts\`, command
  surface in `skills\factory\SKILL.md` (+ the public copy under `standalone\`), worker agent in
  `agents\worker.md`, hooks in `hooks\hooks.json`.
- Private runtime state: `runtime\projects\motivehr-4893d8fb\state.json` (+ `sessions\`, `events\`).
- Worker worktrees live OUTSIDE the target repo:
  `C:\laragon\www\.claude-factory-worktrees\motivehr-4893d8fb\`.
- Every script is launched as **Windows PowerShell 5.1**
  (`powershell -NoProfile -ExecutionPolicy Bypass -File ...`), not `pwsh` 7. `Set-StrictMode -Version 2.0`
  is in force in every script — see the defect in §0, it is exactly that class of bug.
- Test harness: `tests\run-tests.ps1`, with a fake `claude` shim (`claude-fake.cmd`). Add regressions
  there.
- In this project commits happen only on the owner's explicit "go". **Do not commit or push.**

### Working-copy state you are inheriting

`git status --short` in the plugin root shows exactly one modification:

```text
 M scripts/worker-launch.ps1
```

That is the §0 fix below, made by this session. Keep it; it is a prerequisite for reaching the
fallback path at all.

### Live state you must not disturb

| Task | State | Why it matters |
|---|---|---|
| `1217140309435580` | `queued` via `/factory answer`, `attempts: 3`, no commit, no session, worktree `worker-1217140309435580-a1` and branch `factory-worker/1217140309435580-a1` retained and clean, `FACTORY-DECISIONS.md` written into the worktree (excluded via `.git/info/exclude`) | The reproduction case. Two launch attempts were burned by the two defects below; the owner then recorded a product decision on 2026-08-06, which requeued it. Leave the worktree, the branch and the decisions file in place. Do not hand-edit its row. |
| `1217066872630122` | `failed`, `attempts: 4`, worktree and branch retained | The previous task's reproduction case. Still untouched. |
| 8 tickets: `1216643571330166`, `1216914175564309`, `1216454325244733`, `1217120416645639`, `1217130629417167`, `1216607302390215`, `1217183546448380`, `1216603370048355` | `queued`, `attempts: 0`, no worktree, no session | Added 2026-08-05, `startMode: interactive`. They must NOT be launched until the launcher works, or eight attempts get burned for nothing. (A ninth, `1216633565784989`, was discarded on 2026-08-06 as a duplicate — it had no artifacts.) |
| `1216795216668137`, `1216836795830520` | `held` (manual, operator) | Awaiting an owner decision. Never retryable through `task-action.ps1 -Action retry`. |
| `1216606487211903`, `1216644215490259`, `1216729457342566` | `rejected` (`reject --keep`) | Kept deliberately for inspection. |

The factory was deliberately left `active: true`, **`paused: true`**, `schedulerJobId: null`, and the
`/factory:tick` cron job was deleted. That is not quiet-idle (runnable work exists) — it is a manual
hold so the two-minute tick cannot burn an attempt per queued ticket while the launcher is broken.
`/factory resume` is the intended way back once the fix lands.

`state.agentResolutionCache` currently reads:

```json
{
  "claudeVersion": "2.1.222",
  "preferredResolution": "inline-fallback",
  "checkedAt": "2026-08-05T18:40:33.1490654Z",
  "reason": "session-only plugin agent was not resolved for background launch"
}
```

That cache is correct about the native path and now wrong about the fallback being usable. Whatever
you implement must be able to invalidate or extend it — see §2.7.

---

## §0 — DONE IN THE WORKING COPY: StrictMode crash before the fallback could run

**Symptom.** The very first launch of `1217140309435580` died here, after the worktree had already
been created:

```text
Preparing worktree (new branch 'factory-worker/1217140309435580-a1')
Where-Object : The property 'id' cannot be found on this object. Verify that the property exists.
At C:\laragon\www\Projects\claude-factory-plugin\scripts\worker-launch.ps1:127 char:26
+ ...  = @($rows | Where-Object { [string]$_.id -eq $BackgroundId } | Selec ...
```

**Root cause — confirmed.** `Stop-FactoryClaudeSessionAndWait` polls `claude agents --json --all` and
filtered on `[string]$_.id`. Only `kind: "background"` rows carry `id`; `kind: "interactive"` rows do
not, and under `Set-StrictMode -Version 2.0` reading a missing property throws
`PropertyNotFoundStrict`. On this machine five interactive sessions were listed, so the crash was
deterministic. Real output shape:

```json
{"pid":167548,"cwd":"C:\\laragon\\www\\motivehr","kind":"interactive","startedAt":1785954426006,
 "sessionId":"a6011b83-...","name":"Claude Factory Orchestrator","status":"busy"}
{"id":"dc4d8ebd","cwd":"C:\\laragon\\www\\.claude-factory-worktrees\\motivehr-4893d8fb\\worker-1217140309435580-a1",
 "kind":"background","startedAt":1785955230058,"sessionId":"dc4d8ebd-...","name":"factory-...","state":"stopped"}
```

Note the consequence: the crash happened **inside the stray-session cleanup**, i.e. at the moment the
launcher was trying to guarantee it never leaves two sessions alive for one task. The stray was in
fact stopped (its `claude stop` had already returned 0); only the confirmation poll crashed.

**Fix applied** — the same guard already used at `scripts\start-worker-session.ps1:284`:

```powershell
$row = @($rows | Where-Object {
    $null -ne $_.PSObject.Properties["id"] -and
    [string]$_.id -eq $BackgroundId
} | Select-Object -First 1)
```

**What you still owe here:**

1. Audit every other `claude agents --json` consumer for the same unguarded-property class. Verified
   already-safe: `scripts\orchestrator-session.ps1:48-52`, `scripts\start-worker-session.ps1:284`,
   `scripts\reconcile-worker-sessions.ps1:97`. `worker-launch.ps1:127` was the only unguarded one at
   the time of writing — re-check after your changes.
2. Add a regression to `tests\run-tests.ps1`: make `claude-fake.cmd` emit an agents listing that
   contains at least one `interactive` row **without** an `id` key, and assert the launcher survives
   the stray-cleanup poll. The existing fixtures apparently only contain background rows, which is
   why this shipped.

---

## §1 — `--agent` is unresolvable at bg-spawn regardless of how the agent is supplied

**Symptom.** With §0 fixed, the retried launch reaches the inline fallback and the fallback fails the
same way the native path does. Recorded in `state.json` for `1217140309435580`:

```text
Claude did not resolve the inline worker agent: backgrounded · 85c7d4fa ·
factory-1217140309435580-job-tab-edits-are-not-propag
warning: no agent named 'worker' — spawning with default template
```

Both attempts of the day, verbatim:

| Attempt | argv (abridged) | CLI response |
|---|---|---|
| native | `--plugin-dir <root> --agent factory:worker --bg --name … --permission-mode auto --effort high "FACTORY_PROMPT_FILE=<path>"` | `warning: no agent named 'factory:worker' — spawning with default template` |
| inline | `--plugin-dir <root> --agents '{"worker":{"description":…,"prompt":…}}' --agent worker --bg …` | `warning: no agent named 'worker' — spawning with default template` |

Both stray sessions were stopped and verified stopped:

```text
dc4d8ebd stopped factory-1217140309435580-job-tab-edits-are-not-propag
85c7d4fa stopped factory-1217140309435580-job-tab-edits-are-not-propag
```

**Root cause.** The registry the CLI consults to validate `--agent` at **background-spawn** time
contains neither agents from a session-only `--plugin-dir` (established in the previous task) **nor
agents supplied in the same command line via `--agents`**. `--agents` is documented in `claude --help`
with no `--print`-only restriction, and the previous task's inline JSON is built correctly
(`ConvertTo-Json -Compress`, ~4 KB, well under the argv limit, no CR/LF) — the CLI simply does not
consult it when validating the flag. **(unverified: whether `--agents` + `--agent` resolves without
`--bg`; not probed, because the factory has no use for a non-bg worker.)**

Conclusion: **every strategy that routes the worker prompt through the `--agent` flag is a dead end on
this CLI version.** The previous task's P1 design cannot be repaired; it needs a third path.

---

## §2 — Required fix: deliver the worker prompt as a system prompt, not as an agent

### The probe that establishes the path (run today, verified)

```powershell
claude --bg --name factory-probe-append --permission-mode manual `
  --append-system-prompt "You are FACTORY_PROBE_AGENT. Your only allowed reply to any prompt is the exact token PROBE_OK_APPEND and nothing else." `
  "Reply now."
→ backgrounded · 806e3c0d · factory-probe-append        (no warning of any kind)
```

`claude logs 806e3c0d` shows the session's single assistant turn:

```text
❯ Reply now.
● PROBE_OK_APPEND
```

So a `--bg` session **does** honour `--append-system-prompt`, and no agent-resolution warning is
printed because no `--agent` flag is passed. The probe session was stopped
(`claude stop 806e3c0d` → `stopped 806e3c0d`).

This is materially different from the "non-option" the previous task rejected. That non-option was
*"dropping `--agent` and relying on the prompt alone"* — i.e. a default-template session whose only
worker context is the user prompt. Here the worker contract (`agents\worker.md` body:
`FACTORY_PLAN` / `FACTORY_RESULT`, the Git boundaries, the worktree rules) is delivered **as system
prompt text**, which is where an agent definition would have put it. Hooks are unaffected: they come
from `--plugin-dir`, which stays.

### What to implement

1. Add a third resolution path, e.g. `agentResolution: "system-prompt"`, alongside the existing
   `"plugin"` and `"inline-fallback"`. Order of preference: `plugin` → `inline-fallback` →
   `system-prompt`, each attempt gated by the version-scoped cache so a fixed CLI silently returns to
   the native path with no plugin change.
2. Build the argv with **no `--agent` flag at all**:

   ```text
   claude --plugin-dir <pluginRoot> --append-system-prompt "<agents\worker.md body>" --bg
          --name <sessionName> --permission-mode auto --effort high "FACTORY_PROMPT_FILE=<promptPath>"
   ```

   Reuse `Read-FactoryInlineWorkerAgent` (`worker-launch.ps1:143-166`) for the body — it already
   strips the YAML frontmatter and fails closed on a malformed file or an empty body. Keep the
   existing byte-exactness discipline: the whole point of `FACTORY_PROMPT_FILE=<path>` is that long
   argv values were being mangled (see `TASK-worker-launch-and-reconcile-integrity.md`), and the
   worker body is ~4 KB of argv. **Verify byte-exact transport in the harness**, and if 5.1 argument
   quoting proves unsafe for that payload, prefer a file-based variant — `claude --help` also lists
   `--append-system-prompt-file` under `--bare`; **(unverified: whether
   `--append-system-prompt-file` is accepted outside `--bare`.)** Probe it before choosing, it is the
   safer transport if it exists.
3. **Evaluate `--system-prompt` (full replacement) against `--append-system-prompt`.** `--system-prompt`
   is closer to agent semantics — it replaces the default template instead of layering the worker on
   top of it — but it also drops everything the default template provides, and it is **(unverified:
   not probed today)**. Probe both in a scratch directory, pick one, and record why in this file. If
   you keep `--append-system-prompt`, state explicitly that the worker prompt is additive to the
   default template, because that is a real behavioural difference from the `plugin` path.
4. **The fallback-warning guard can no longer detect this path's failure mode.** With no `--agent`
   flag, the CLI prints no warning, so the `Test-FactoryAgentFallbackWarning` regex is silent by
   construction and cannot be used as the success assertion here. Replace it with a positive check for
   this path: at minimum assert a parseable background ID plus an `claude agents --json --all` row for
   it; better, have the worker prove receipt of its contract. `agents\worker.md` already opens with a
   fixed protocol — assert on the session's own first emission rather than trusting the launch output.
   Do not weaken the existing warning guard for the `plugin` and `inline-fallback` paths; it stays as
   the fail-closed gate for those.
5. Agent-definition keys that cannot be expressed as a system prompt: `maxTurns: 100` and any `tools`
   restriction from the frontmatter. `model` and `effort` already travel as CLI flags from
   `config.workerModel` / `config.workerEffort`. Record the lost keys as an accepted deviation in the
   launch metadata (not silently) so `/factory doctor` can report that the machine is running on the
   system-prompt workaround **and** what that workaround does not carry.
6. Attempt accounting is unchanged: one `/factory retry` + one launch attempt is **one** `attempts`
   increment, no matter how many argv shapes the launcher tries inside it.
7. `agentResolutionCache` must be able to record `"system-prompt"` and must not strand an older cache
   value. A cache written by the current code says `inline-fallback` for `2.1.222`, which your new
   code must treat as "inline was tried and is known bad", not as "inline is preferred". Either version
   the cache shape or record per-path outcomes rather than a single preference.
8. `scripts\factory-doctor.ps1` currently reports `workerAgentDefinition: "inline fallback ready"` and
   `workerAgentResolution: "not probed; the next worker launch will try the native plugin agent first"`
   — both were reassuring while nothing could launch. Make doctor's wording reflect the real
   capability for the installed CLI version, and treat "no working resolution path" as a **required**
   failure rather than info.

### Acceptance criteria

- `/factory resume` followed by a tick launches real worker sessions for the `queued` tickets
  (respecting `config.concurrency: 3`), each with `agents\worker.md` as its system prompt, in its own
  external worktree, with the plugin's `PreToolUse` git-guard and `Stop` capture hooks active.
- `1217140309435580` launches into its retained worktree and branch rather than creating a second
  worktree, and its `FACTORY-DECISIONS.md` reaches the worker. Its `attempts: 3` is above
  `config.maxAttempts: 2`, which is **harmless: no script enforces that cap** — `maxAttempts` appears
  only in `config.default.json` and in this document. Either start enforcing it deliberately or drop
  it from the config; today it is a lie in the config file.
- An interactive-mode worker still stops on its own after emitting `FACTORY_PLAN`.
- A launch that would land on a bare default template (no worker contract) still fails closed, stops
  its stray session, verifies it is gone, and leaves the task `failed` with the exact CLI output in
  `error`.
- When the CLI regression is fixed, the native `plugin` path is taken again with no plugin change.
- `tests\run-tests.ps1` gains: (a) an agents listing containing an `interactive` row with no `id`
  (the §0 regression); (b) fake warns on native and on inline, succeeds on the system-prompt path →
  exactly one surviving session, `agentResolution: "system-prompt"`, `attempts` +1; (c) fake fails all
  three → task `failed`, no surviving session; (d) the argv (or prompt file) carries the full,
  byte-exact `agents\worker.md` body.

---

## Reproduction, end to end

```powershell
# 0. the factory is intentionally paused; the tick will do nothing until this is lifted
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\task-action.ps1 `
  -Repository "C:/laragon/www/motivehr" -Action retry -TaskId 1217140309435580

# 1. launch — reaches the inline fallback (thanks to §0) and dies on the fallback warning
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\start-worker-session.ps1 `
  -Repository "C:/laragon/www/motivehr" -TaskId "1217140309435580" -Mode "interactive"
```

Expected after the fix: a background session named
`factory-1217140309435580-job-tab-edits-are-not-propag`, running the `agents\worker.md` contract, in
`C:\laragon\www\.claude-factory-worktrees\motivehr-4893d8fb\worker-1217140309435580-a1`, which stops
on its own after emitting `FACTORY_PLAN`.

## Implementation outcome (2026-08-06)

The probes were repeated against Claude Code 2.1.223 in isolated scratch
sessions. Both `--system-prompt` and `--append-system-prompt` controlled the
background session as expected. The hidden `--append-system-prompt-file` option
was also accepted outside `--bare` and the session obeyed the file contents.
Every probe session was stopped and removed afterward; no MotiveHR runtime,
task state, or worktree was used.

The implemented third path uses `--append-system-prompt-file`. This preserves
Claude's default tool and runtime instructions and avoids transporting the
roughly 4 KB worker contract through Windows PowerShell 5.1 argv. It is not
semantically identical to the plugin agent: the worker body is additive to the
default system prompt. Agent frontmatter name, description, and `maxTurns: 100`
are not applied on this path, and a future `tools` frontmatter restriction would
not be applied either. Model and effort remain explicit CLI flags. These
accepted deviations, the prompt path and SHA-256, and all per-path outcomes are
stored in private launch metadata and the version-scoped cache.

The cache now has schema version 2 and records outcomes for plugin, inline, and
system-prompt paths. A same-version legacy `inline-fallback` preference migrates
directly to `system-prompt`; a Claude Code version change probes the native
plugin path again. The system-prompt path has no `--agent`, retains
`--plugin-dir`, and succeeds only after both a parseable background ID and the
matching `claude agents --json --all` row are observed.

Automated coverage now includes an unrelated interactive row without `id`, a
three-shape successful launch counted as one factory attempt, failure and
cleanup of all three shapes, byte-exact worker-body delivery, legacy-cache
migration, and native recovery on a newer CLI version. `maxAttempts` remains
configuration-only: `task-action.ps1` permits retrying the retained
`1217140309435580` task and `start-worker-session.ps1` would increment its
attempt counter again. This task deliberately does not introduce enforcement.
The live factory remains paused and no queued MotiveHR task was launched.

## Out of scope

- Any change to review/approval/integration gates, cleanup safeguards, or Git policy.
- Installing the factory plugin globally. Previously rejected by the owner: it would load the
  factory's hooks — including the `PreToolUse` Git guard — into every unrelated Claude session on the
  machine.
- Any Asana write.
- Launching the nine queued tickets as a side effect of testing. Use the retained reproduction tasks
  or the fake shim.
- Committing or pushing anything, in this repo or in `motivehr`.
