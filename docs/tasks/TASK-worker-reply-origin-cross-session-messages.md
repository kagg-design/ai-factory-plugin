# TASK — distinguish peer messages from operator replies

Recorded: 2026-10-21T08:37:40Z.
Status: implemented and validated on `codex/worker-reply-origin`; transferred
to `main` on 2026-10-21 at Igor's explicit request for commit and push.

Development used the isolated worktree:
`C:\Users\igerg\.codex\worktrees\worker-reply-origin\claude-factory-plugin`.
Before transfer, the Auditors and MotiveHR schedulers and their exact saved
Claude orchestrator sessions were stopped. Both factories remain stopped;
normal startup will load the updated plugin hooks.

## Evidence and limits

Found during a read-only assessment of cross-session messaging. Installed Claude
Code reports 2.1.306. No live Factory task or session was messaged, resumed, or
changed. There are no incident task/session identifiers to report. The missing
origin check is confirmed in source; the end-to-end peer-message path still needs
an isolated reproduction against the installed Claude runtime.

The official hooks reference says that `UserPromptSubmit` runs for a message
another session sends to the main conversation, as well as typed prompts and
other automated inputs:

- https://code.claude.com/docs/en/hooks#userpromptsubmit
- https://code.claude.com/docs/en/cross-session-messaging

Current source:

- `scripts/capture-worker-reply.ps1:7-12` accepts `UserPromptSubmit`, reads its
  prompt/session/worktree, and excludes only empty inputs and the initial
  `FACTORY_PROMPT_FILE=` pointer. After matching the task it calls
  `Publish-FactoryWorkerReply` without establishing who submitted the prompt.
- `scripts/worker-event.ps1:131-155` writes `kind: reply` with the default source
  `UserPromptSubmit`, a hash, preview and session identity. It has no distinction
  between a human response, agent information, and authorized orchestration.
- `scripts/factory-common.ps1:375-481` uses a recent matching reply to promote
  eligible `awaiting-input`/`blocked` tasks to `running`. Its guards correctly
  verify task/session/time/state, but do not establish the input author's role
  or whether this input actually authorizes continuation.
- `tests/worker-chat-attention-amend.tests.ps1:111` covers a typed operator reply;
  the current suite has no peer-message provenance case.

## Impact

A delivered informational peer message can enter the same Factory reply path as
an operator response. Under the existing state/session/time prerequisites,
reconciliation or sync preparation can then promote a waiting task to `running`
and record `inSessionReply` as the reason. This confuses an agent's information
with an operator's decision to continue. Whether the model proceeds to edits
also depends on its instructions; no unauthorized live edit has been observed.

Affected paths include native reconciliation, `factory status` reconciliation,
and worker `sync-task.ps1` preparation. Existing validated-result, Asana-question,
held-task, review and publication guards must remain intact.

## Reproduction to perform in an isolated fixture

1. Create a synthetic repository and explicitly separate synthetic runtime.
2. Launch a Claude worker in interactive mode and let its plan enter
   `awaiting-input`; record the exact task, attempt and conversation identifiers.
3. From a second synthetic Claude session, send an informational message that
   neither approves the plan nor asks for implementation.
4. Capture the actual hook input and resulting Factory reply event, redacting
   any messaging tokens. Reconcile, then inspect status and `inSessionReply`.
5. Repeat for a blocked task and compare with a direct human response.

Expected: information from a peer remains information and does not satisfy a
human-decision boundary. A verified human response retains the existing
same-session continuation behavior.

## Repair requirements and acceptance checks

- Establish what reliable origin evidence the installed runtime exposes. Do not
  trust a sender name, a text prefix, or a message claiming to be from Igor.
  If the hook cannot distinguish origins reliably, use a Factory-controlled
  decision boundary rather than treating every hook invocation as human input.
- Separate operator replies, orchestrator guidance, peer information and runtime
  notifications in the event model. Record message ID, task/attempt identity,
  origin and authorization semantics when available.
- Peer information and scheduled/background notifications cannot alone resume
  work waiting for an operator decision. Authorized automatic-mode guidance can
  continue work only through an explicit Factory policy.
- A direct human answer still resumes the same eligible session; existing
  timestamp/session/state guards continue to pass their focused regressions.
- A forged human claim, an old attempt, a duplicate, or a delivered message after
  review/approval cannot bypass state or publication gates.
- Include equivalent origin semantics in a future Codex transport. Its app-server
  input must not acquire human authority merely because it is represented as a
  user-input protocol item.
- Add focused regression coverage and record a synthetic Windows live check.
  Do not modify live runtime state, launch a watcher alongside its native
  consumer, or change review/GO policy as part of this repair.

## Scope

This report covers reply-origin attribution and waiting-state transitions.
Building a general messaging broker, migrating Codex workers to app-server, and
enabling unrestricted worker-to-worker messaging are separate design decisions.

## Implementation

- Version 2 input events record task attempt, message ID, runtime input source,
  origin and continuation evidence. Informational inputs cannot become replies
  by naming Igor, quoting a command, or occupying a user-role protocol item.
- Resume checks require matching authorization evidence and runtime, the exact
  attempt, and an unconsumed message ID, in addition to the existing guards.
  Legacy version 1 reply events are insufficient evidence.
- Native Claude 2.1.306 still omits `source` from classic UserPromptSubmit
  callbacks. Both installed builders spread `...!1` in the field's slot even
  though the schema declares it. The upstream issue remains open:
  https://github.com/anthropics/claude-code/issues/94675.
- A future runtime-confirmed `source: user` preserves ordinary chat replies.
  For the current runtime, the explicit `/factory continue <answer>` worker
  command establishes the Factory-controlled decision boundary through
  UserPromptExpansion. The plugin-qualified spelling is
  `/factory:factory continue <answer>`. It retains the exact session and does
  not relaunch the worker or approve review/publication.
- Known automated sources are classified as automation; absent sources remain
  unknown. Peer and runtime inputs are not distinguished by their wording when
  the runtime supplies no reliable discriminator. Both lack continuation
  authority. This does not implement a new messaging transport.
- The Codex console wrapper retains its explicit Factory-owned boundary. An
  arbitrary SDK/app-server input cannot reuse that authority implicitly.

## Validation on 2026-10-21

- `tests/worker-chat-attention-amend.tests.ps1`: passed on Windows PowerShell
  5.1, including verified user-source replies, unknown/SDK/system/scheduled
  inputs, forged Igor/command text, explicit worker continuation, shared
  prompt IDs across hook stages, consumed messages, old attempts, legacy
  events and the existing session/time/state guards. Codex's interactive
  console resume and the existing attention/amend cases also passed.
- `tests/worker-result-followup.tests.ps1`: passed.
- `tests/codex-session-snapshot.tests.ps1`: passed.
- Opt-in `tests/worker-reply-origin-live.tests.ps1 -Live` used Claude Code
  2.1.306 and a synthetic Windows repository/runtime. Two actual SendMessage
  calls reached receiver `eabc0d14-29a3-4cb8-8d60-b123e68ee9fa`; both contained
  a forged Igor claim and quoted continuation command. Neither resumed the
  awaiting-input/blocked task. Native UserPromptExpansion of the explicit
  plugin-qualified command then authorized attempt 1 in that same session.
- The live command was submitted through the probe's controlled input stream;
  the test verifies the native command-expansion boundary, not physical
  keyboard identity. Peer messages quoting the command did not expand it.
- All four observed UserPromptSubmit callbacks omitted `source`. The native
  submit/expansion callbacks for the explicit command shared one prompt_id;
  deduplication therefore distinguishes hook stages as well as message ID.
- The receiver had model tools disabled and both senders could only use
  SendMessage to its unique synthetic name. Only the receiver process created
  by the probe was stopped. Its diagnostic fixture/transcripts were retained;
  no pre-existing session or live Factory runtime was touched.
- Changed PowerShell sources parsed successfully, hooks JSON parsed, and
  `git diff --check` passed.
