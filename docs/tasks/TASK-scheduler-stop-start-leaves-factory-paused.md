# TASK — `stop` + `start` leaves the factory paused and silent about it

Author: orchestrator session, 2026-08-20, observed on a live run against `motivehr` right after
`b192241` landed. Small and self-contained; it is the one rough edge left in the scheduler surface
after that commit.

## Symptom

Restarting the scheduler the obvious way — `stop`, then `start` — leaves a process that ticks
forever and does nothing. Queued and approved tasks are not picked up. Nothing in the `start` output
says so.

## Evidence

```
factory-scheduler.ps1 -Action stop   → { status: stopped, pid: null, activity: idle }
factory-scheduler.ps1 -Action start  → { status: running, pid: 85116, activity: idle, heartbeatAt: 2026-08-20T13:43:18Z }

factory scheduler
  Native scheduler: running
  Factory: paused            ← the part that matters, and the part nobody looks at
  Process: PID 85116; interval 15s
  Heartbeat: 08/20/2026 13:43:37
  Last tick: 08/20/2026 13:43:21
```

`state.json` after that pair: `paused: true`. One explicit `-Action resume` fixed it
(`resumed: true`, `paused: false`), and the same process then behaved normally.

## Root cause

Three actions in `scripts\factory-scheduler.ps1` disagree about what they own:

- `:556` — `"stop" { Stop-NativeScheduler -PauseFactory $true }`. Stop kills the process **and**
  sets `paused = true`.
- `:~554` — `"start" { Start-NativeScheduler }`. Start only spawns the process. It never touches
  `paused`, so it silently inherits the pause that `stop` set.
- `:562-564` — `"resume"` sets `active = true`, `paused = false` **and** starts.

The tick loop honours the flag correctly (`:317` and `:342` both bail on `paused`), so the result is
a live, heartbeating, log-writing scheduler that is deliberately doing nothing — the one state that
looks healthiest in every readout except the single line that says `Factory: paused`.

`resume` is effectively "start and mean it", and `start` is a trap for anybody who reads the verb
pair `stop`/`start` as symmetric. I hit it myself minutes after reviewing the new code.

## Required fix

Pick one of the first two and make the surface consistent, then do the third:

1. **`stop` stops only the process** and leaves `paused` alone, with a separate `pause` for
   suspending the factory — which already exists. Then `stop`/`start` is a true pair and the flag
   means what it says. My preference: the two concerns (is a worker-launcher process alive; is the
   factory allowed to act) are genuinely different, and today's coupling exists only so that a
   `stop` cannot be undone by a stray tick.
2. **Or `start` clears the pause that `stop` set** — distinguish an operator's explicit `pause` from
   the implicit one, e.g. record `pauseReason` (`operator` / `scheduler-stop`) and let `start` clear
   only the latter.
3. Either way, **`start` must report the outcome**: if it returns with `paused = true`, say in the
   output that the factory will not launch anything and name `resume`. An action whose result is
   "running, and inert" has to say the second half.

Also worth one line each, in the same pass:

- `factory scheduler` and `factory status` should render "process running + factory paused" as a
  problem rather than as two neutral lines, at least while any task is `queued` or `approved`. The
  data is already there (`Get-SchedulerStatusResult` returns both `running` and `paused` at
  `:207-210`).
- Document the verb triple in both `SKILL.md` copies: `stop`/`start` for the process, `pause`/`resume`
  for the factory, and which of them touches the other.

## Acceptance

In `tests\run-tests.ps1`: with one `queued` task, `stop` followed by `start` either leaves the task
launchable within a tick, or the `start` result carries an explicit paused warning naming `resume` —
and the status readout for that combination is distinguishable from a plain healthy scheduler. Assert
on the returned objects, not on the printed text.

## Do not

- Do not make `stop` leave a process running, and do not make `start` clear a pause the operator set
  deliberately with `pause`.
- Do not change the tick loop's own respect for `paused`: a paused factory must keep launching
  nothing.
- Do not commit or push in this repository — the owner does that on an explicit "go".
