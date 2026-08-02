# TASK — worker launch is dead: `--bg --agent` no longer resolves plugin agents, and `Get-FileHash` is missing under 5.1

Author: orchestrator session, 2026-08-01. Everything below was observed on live runs of this
plugin against the `motivehr` repository today. Every claim is backed by a command and its real
**Status: implemented locally on 2026-08-02; not committed or pushed.** The implementation uses
version-scoped capability caching rather than repeating a known-bad native launch for every worker.
It preserves the native plugin path when available, verifies termination of every fallback session,
passes the inline definition with PowerShell 5.1-safe Windows argument quoting, and records the
resolution path in session metadata and factory state. The test harness verifies byte-exact agent
prompt transport, cached fallback, double failure, and attempt accounting.

P2 was resolved without globally rewriting `PSModulePath`: prompt hashing now uses .NET SHA-256,
doctor reports the effective runtime and required cmdlets, and the Git guard fails closed on malformed
safety input. The live MotiveHR runtime and retained reproduction worktree were not changed.

output; anything unverified is marked **(unverified)**.

**Net effect: the factory cannot launch any worker at all right now.** Both defects are in the
launcher's environment, not in the factory's logic, and the launcher fails closed (good), which is
why the queue simply stops instead of producing garbage.

## Context you need before touching anything

- Plugin root: `C:\laragon\www\Projects\claude-factory-plugin`. Scripts in `scripts\`, command
  surface in `skills\factory\SKILL.md` (+ the public copy under `standalone\`), worker agent in
  `agents\worker.md`, hooks in `hooks\hooks.json`.
- Private runtime state: `runtime\projects\<projectKey>\state.json` (+ `sessions\`, `events\`).
  Project in play: `motivehr-4893d8fb`.
- Worker worktrees live OUTSIDE the target repo:
  `C:\laragon\www\.claude-factory-worktrees\<projectKey>\`.
- Every script is launched as **Windows PowerShell 5.1**
  (`powershell -NoProfile -ExecutionPolicy Bypass -File ...`), not `pwsh` 7. Fixes must be correct
  under 5.1.
- Test harness: `tests\run-tests.ps1`. It builds a temp repo, a temp runtime and a **fake `claude`
  shim** (`claude-fake.cmd`), so launcher behaviour is testable without spawning real sessions.
  Add regressions there.
- Versions at the time of observation: `claude --version` → **2.1.220 (Claude Code)**; plugin
  manifest **factory v3.0.0**; `$PSVersionTable.PSVersion` → **5.1.26100.8875**.
- In this project commits happen only on the owner's explicit "go". **Do not commit or push.**

### Live state you must not disturb

| Task | State | Why it matters |
|---|---|---|
| `1217066872630122` | `failed`, `attempts: 4`, no commit, no session, worktree `worker-1217066872630122-a1` and branch `factory-worker/1217066872630122-a1` retained | This is the reproduction case. Leave the worktree and branch in place — `retry` needs them. Do not hand-edit its row. |
| `1216795216668137`, `1216836795830520` | `held` (manual, operator) | Awaiting an owner decision. Never retryable through `task-action.ps1 -Action retry`. |
| `1216606487211903`, `1216644215490259`, `1216729457342566` | `rejected` (`reject --keep`) | Kept deliberately for inspection. |

At the end of the session that produced this document the factory was left `active: false`,
`paused: false`, `cronJobId: ""` — correct quiet-idle, since nothing is runnable.

---

## P1 — `claude --bg --agent factory:worker` silently falls back to the default template

**Symptom.** Every worker launch fails. `scripts\start-worker-session.ps1` refuses the session and
throws, and the task ends as `failed` with this recorded in `state.json`:

```text
Claude did not resolve the required factory:worker agent: warning: no agent named 'factory:worker'
 — spawning with default template
backgrounded · f2c665e9 · factory-1217066872630122-enable-file-upload-on-reques
```

The guard doing this is `scripts\start-worker-session.ps1:278-285`: it regex-matches the fallback
warning, stops the stray background session (line 282), then throws. **That behaviour is correct and
must be preserved** — a default-template session has no worker system prompt, so it has no
`FACTORY_PLAN`/`FACTORY_RESULT` contract and none of the Git boundaries. Do not weaken it.

**The exact argv the launcher builds** (`scripts\start-worker-session.ps1:234-258`):

```text
claude --plugin-dir <pluginRoot> --agent factory:worker --bg --name <sessionName>
       --permission-mode auto --effort high "FACTORY_PROMPT_FILE=<promptPath>"
```

### Evidence — three probes, run today

1. **Same flags, no `--bg`, resolves fine.**

   ```text
   claude --plugin-dir "C:/laragon/www/Projects/claude-factory-plugin" \
          --agent factory:worker -p "Reply with the single word OK and nothing else."
   → OK          (no warning on stderr)
   ```

2. **A `--bg` session with `--plugin-dir` but WITHOUT `--agent` does load the plugin.** Probe
   session `7ebc0c32`, prompt: *"In one short line: list the agent type names available to you that
   start with 'factory'. If none, say NONE."* Its transcript
   (`~/.claude/projects/C--laragon-www-motivehr/7ebc0c32-*.jsonl`) contains exactly one assistant
   text block:

   ```text
   factory:worker
   ```

   So the spawned background session *does* receive `--plugin-dir`, *does* load plugin `factory`,
   and *does* register the agent under the namespaced name `factory:worker`.

3. **`--bg --agent` works for an INSTALLED plugin's agent.**

   ```text
   claude --bg --name factory-agent-probe2 --agent claude-security:explore "..."
   → backgrounded · 92270864 · factory-agent-probe2      (no warning)
   ```

   `claude-security@claude-plugins-official` is installed at user scope
   (`~/.claude/plugins/installed_plugins.json`). The factory plugin is **not** installed anywhere —
   it exists only as a session-only `--plugin-dir`.

Both probe sessions were stopped (`claude stop 7ebc0c32`, `claude stop 92270864`), as was the stray
`f2c665e9`.

**Root cause.** The registry the CLI consults to validate the `--agent` flag at **background-spawn**
time does not include agents from plugins supplied via session-only `--plugin-dir`; it does include
agents from installed plugins. Non-`--bg` startup resolves the same name correctly. This is a
Claude Code regression (it worked on 2026-07-28 — tasks `1216632072822682` and `1216643944203164`
launched with this exact argv shape), and we cannot fix it from inside the plugin. **(unverified:
the precise CLI version that introduced it.)**

**Non-options — do not implement these.**

- Dropping `--agent` and relying on the prompt alone. The worker's whole contract lives in
  `agents\worker.md`; a default-template session is not a worker.
- Installing the plugin globally (junction into `~/.claude/skills/factory`, or a marketplace
  manifest + `claude plugin install`). It would fix resolution, but it loads the factory's skills,
  agents **and hooks — including the `PreToolUse` Git guard — into every unrelated Claude session on
  the machine**. The owner rejected this.
- Keeping `--plugin-dir` optional. It must stay: `hooks\hooks.json` registers `PreToolUse`
  (`worker-git-guard.ps1`) and `Stop` (`capture-worker-stop.ps1`) via `${CLAUDE_PLUGIN_ROOT}`, and
  those hooks are how the worker is fenced and how reconcile learns a session stopped. Probe 2 proves
  they are still delivered to `--bg` sessions.

### Required fix

Keep `--plugin-dir` and try the native `--agent factory:worker` first when the current Claude Code
version has no recorded capability result. Cache the successful resolution path by exact CLI version;
after a native fallback, use the inline path directly for later workers on that version. A version
change probes native resolution again, so the launcher self-heals without creating a known-bad stray
session for every task. Add exactly one automatic fallback that materialises the same agent inline:

1. Attempt the native launch when no current-version cache selects inline fallback.
2. If the existing fallback-warning regex matches:
   - stop the stray background session (already done at line 282), then **verify it is actually
     gone** — poll `claude agents --json --all` for that ID until its `state`/`status` is stopped or
     the row disappears, bounded by a short timeout. Never leave two sessions alive for one task, and
     never let reconcile see two rows for one task ID.
   - relaunch **once** with the agent defined inline, then treat any second failure as terminal
     exactly as today.
3. Inline definition: parse `agents\worker.md`, strip the YAML frontmatter, and pass the body as the
   agent prompt:

   ```text
   claude --plugin-dir <pluginRoot> --agents '{"worker":{"description":"<frontmatter description>","prompt":"<worker.md body>"}}' \
          --agent worker --bg --name <sessionName> --permission-mode auto --effort high \
          "FACTORY_PROMPT_FILE=<promptPath>"
   ```

   `agents\worker.md` is ~4 KB, so the JSON stays far below the Windows command-line limit. Build the
   JSON with `ConvertTo-Json -Compress` (never by hand), and reuse the existing safety check that
   refuses a launch when an argument contains CR/LF or quote characters it cannot carry — see the
   `$shortPrompt` guard at line 257 and the payload-truncation lesson in
   `TASK-worker-launch-and-reconcile-integrity.md` (the prompt is passed by *file pointer* precisely
   because long argv values were being mangled; do not regress that).
4. Read the frontmatter rather than hardcoding it. Today it is:

   ```yaml
   name: worker
   description: Runs one persistent, conversational Claude Factory task in its pre-created isolated worktree.
   model: inherit
   effort: high
   maxTurns: 100
   ```

   `model` and `effort` are already passed as CLI flags from `config.workerModel` /
   `config.workerEffort` (lines 242-255), so they survive. **Verify which keys `--agents` accepts**
   (`description`, `prompt`, and whether `model`/`tools`/`maxTurns` are honoured). If `maxTurns`
   cannot be expressed inline, that is an accepted deviation — but record it, see point 6.
5. Assert the fallback actually took effect. At minimum: no fallback warning in the launch output.
   Additionally check whether the `claude agents --json --all` row for the new background ID exposes
   the resolved agent name (the row is already parsed at lines 303-326 for `sessionId`, `name`,
   `transcriptPath`, `state`) and, if it does, assert it — a silent second fallback must never be
   accepted as success.
6. Record which path was used, for auditability: add a field such as
   `agentResolution: "plugin" | "inline-fallback"` to the launch metadata written by
   `Write-FactoryJsonAtomic` (lines 214-227 / 328-332) and surface it in the task's
   `backgroundSession` row. `scripts\factory-doctor.ps1` should report it too, so `/factory doctor`
   shows that the machine is running on the workaround.
7. Do not touch attempt accounting: one `/factory retry` + one launch attempt must still be one
   `attempts` increment. The two launch invocations of a single attempt are one attempt.

### Acceptance criteria

- `/factory retry 1217066872630122` followed by a tick launches a real worker session whose system
  prompt is `agents\worker.md`, in the existing worktree, with the plugin's hooks active.
- A launch that would land on the default template still fails closed, with the stray session stopped
  and the task left `failed` with the exact CLI output in `error`.
- When the CLI regression is fixed, the native path is taken again with no plugin change.
- `tests\run-tests.ps1` gains cases driven by `claude-fake.cmd`: (a) fake emits the fallback warning
  once, then succeeds → exactly one surviving session, `agentResolution: "inline-fallback"`,
  `attempts` +1; (b) fake emits the warning on both invocations → task `failed`, no surviving
  session; (c) fake succeeds immediately → `agentResolution: "plugin"`, no `--agents` in argv;
  (d) the argv passed to the fake carries the full, byte-exact agent prompt (guard against the
  truncation class of bug).

---

## P2 — `Get-FileHash` does not exist in the launcher's PowerShell 5.1

**Symptom.** Before P1 could even be reached, the first launch of the retried task died here:

```text
Get-FileHash : The term 'Get-FileHash' is not recognized as the name of a cmdlet, function,
script file, or operable program.
At C:\laragon\www\Projects\claude-factory-plugin\scripts\start-worker-session.ps1:212 char:22
```

**Root cause — confirmed.** The factory session is started from PowerShell 7, so child
`powershell.exe` (5.1) processes inherit a `PSModulePath` in which the **PowerShell 7 module
directories come first**:

```text
C:\Users\igerg\Documents\PowerShell\Modules;C:\Program Files\PowerShell\Modules;
c:\program files\powershell\7\Modules;C:\Program Files\WindowsPowerShell\Modules;
C:\Windows\system32\WindowsPowerShell\v1.0\Modules
```

5.1 then binds `Microsoft.PowerShell.Utility` from the 7 tree, which is not compatible, and the
module exports only a subset — `ConvertFrom-Json`/`ConvertTo-Json` survive, `Get-FileHash` does not:

```text
powershell -NoProfile -Command "(Get-Command Get-FileHash -EA SilentlyContinue) -ne $null"
→ False
powershell -NoProfile -Command "$env:PSModulePath='C:\Windows\system32\WindowsPowerShell\v1.0\Modules'; (Get-Command Get-FileHash -EA SilentlyContinue) -ne $null"
→ True
# with the 5.1 path merely moved to the front, Get-FileHash resolves from
# C:\Windows\system32\WindowsPowerShell\v1.0\Modules\Microsoft.PowerShell.Utility\Microsoft.PowerShell.Utility.psd1
```

This is ambient-environment dependent: it can break when a `pwsh`-originated module path is inherited
unchanged, but a normal nested Windows PowerShell launch may rebuild a correct path. It remains
invisible until a script happens to call an affected cmdlet.

### Required fix — belt and braces

1. **Do not propagate a Windows PowerShell module path into Claude workers.** Global normalisation in
   `factory-common.ps1` would be inherited by the long-lived Claude process and could invert the same
   incompatibility for child `pwsh` commands. Keep module-path diagnostics read-only and eliminate
   optional module dependencies from the launch path instead.
2. **Remove the dependency entirely at the call site.** Replace
   `scripts\start-worker-session.ps1:212` with a .NET hash that cannot be shadowed by a broken
   module, e.g. `[Security.Cryptography.SHA256]::Create()` over the bytes just written, keeping the
   existing lowercase-hex shape of `promptSha256`. Do the same at
   `tests\run-tests.ps1:230-231`, or the test suite fails for the same reason.
3. **Audit for the same class of failure.** Grep the scripts for cmdlets outside the always-loaded
   core (`Microsoft.PowerShell.Archive`, `Microsoft.PowerShell.Utility` extras, CIM cmdlets) and
   either replace them with .NET equivalents or cover them with fix 1.
4. **Make `/factory doctor` catch this.** Add a required check that the cmdlets the scripts actually
   rely on resolve, and report the effective `PSModulePath` when one does not. This defect cost a
   full launch cycle to identify; doctor reported `healthy: true` throughout.

Related hardening worth noting while you are in there: `scripts\worker-git-guard.ps1:4` does
`try { $payload = $raw | ConvertFrom-Json } catch { exit 0 }` — the `PreToolUse` Git guard **fails
open**. Combined with a cmdlet-resolution failure of the P2 kind, the guard would silently stop
guarding. Consider failing closed (non-zero / explicit deny) when the payload cannot be parsed,
rather than treating an internal error as approval.

---

## Reproduction, end to end

```powershell
# 1. queue the task again (retry is legal: worktree present, no commit, no validated result)
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\task-action.ps1 `
  -Repository "C:/laragon/www/motivehr" -Action retry -TaskId 1217066872630122

# 2. launch — fails at Get-FileHash unless PSModulePath is sanitised (P2),
#    then fails on the agent fallback guard (P1)
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\start-worker-session.ps1 `
  -Repository "C:/laragon/www/motivehr" -TaskId "1217066872630122" -Mode "interactive"
```

Expected after both fixes: a background session named
`factory-1217066872630122-enable-file-upload-on-reques`, running `agents\worker.md`, in
`C:\laragon\www\.claude-factory-worktrees\motivehr-4893d8fb\worker-1217066872630122-a1`, which stops
on its own after emitting `FACTORY_PLAN` (the task's `startMode` is `interactive`).

## Out of scope

- Any change to review/approval/integration gates, cleanup safeguards, or Git policy.
- Any Asana write.
- Committing or pushing anything, in this repo or in `motivehr`.
