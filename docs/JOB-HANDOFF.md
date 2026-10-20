# Fuego tasks in the Nook

The independent Fuego Agent module owns its Fuego connection, task review, local
history and views. NeroNook displays them through the existing generic SDK.
Fuego owns permissions, budgets, admission, provider execution and receipts.
Neither NeroNook nor this plugin builds or replaces the Fuego compute runtime.

## Use it

1. Open **Fuego Agent → Jobs → Connect Fuego**. Sign in with your own existing
   Fuego account in the plugin's window, then choose **Use this sign-in**.
   This is the plugin's own WebKit profile. It does not import any other app's
   session or read a Compute/provider key. The account menu in that window can
   sign out normally.
2. Choose an organization and an active remote agent. Configure missing agents,
   accounts or workspaces in Fuego itself. The current card lists up to 12
   configured remote agents in the selected organization.
3. Write a task and choose **Review handoff**. Inspect the exact text, server,
   organization, agent, computer, workspace, account and standing instructions.
   No screen, audio, transcripts, Nook context or local files are attached.
4. Choose **Send to Fuego**. The agent's configuration is checked again, and
   any unsettled turn in your private Fuego conversation blocks a new send.
   Fuego's supported per-user conversation API saves the exact message and
   request ID, then owns its job creation and delivery. General task creation
   is deliberately blocked by the desktop gateway and is not used for new jobs.
   Fuego may include your existing personal conversation context for this agent;
   the review says so. No other Nook data is attached.
5. Follow **Saved by Fuego → Run accepted → Computer admission → Result** in
   the card. These are observed stages, not invented percentages. A matching
   dispatch event confirms admission separately from a queued run. The final
   answer is Fuego's published assistant message for this exact request and run.
   Progress and answer text cannot trigger local actions. **View in Fuego** opens
   the original run; **Open window** gives the same controls more room.
6. **Cancel job** first rechecks the private turn and requests Fuego's normal
   per-run cancellation of that exact run once. The separate native-coordinator
   correlation option is incompatible with Fuego remote-adapter runs, so it is
   not sent. A local durable cancellation ID prevents replay. The UI
   waits for Fuego's bound remote result before declaring the remote work
   cancelled. A server cancellation row alone is not proof a process stopped.
   Cancellation does not undo completed files, messages or other effects.

## Reconnection and privacy

Closing a Nook/window/plugin does not cancel a job. Up to 20 handoffs are saved
locally, including target, task, IDs, status, a bounded final answer and recent
progress messages. Older settled local entries may be retired as new handoffs
are added; their original Fuego tasks remain. The file is private to this plugin
with 0700 directory / 0600 file permissions. Credentials stay in this plugin's WebKit profile; native requests use only that
profile's applicable cookies in memory, without a shared cookie or credential store.

Reopening reads the original request and known run. No send, invocation or
cancellation is replayed. Lost send confirmation shows **Outcome unknown** and
blocks new handoffs while its original request is unresolved. **Recheck original
handoff** reads the private conversation and requires the exact request ID,
message body, conversation owner, agent, organization and linked run. Missing,
changed or ambiguous matches remain unknown. The initial three rejected legacy
attempts retain their historical local receipts; the old read-only task/run
reconciliation remains for those records. New jobs do not use that legacy route.

The independent **Compute** view retains the signed local status monitor.
This Mac being Ready is not evidence that another selected agent can execute;
Fuego remains the admission authority. An offline progress read leaves the
original run intact and shows its last confirmed time.

## SDK and limits

Existing `actions-v1` publishes optional read-only `read_job_status` / `job_status`
metadata for the selected handoff: availability, phase, task/run IDs, admission
and original observation time. The four-second channel lifetime does not refresh
that underlying observation. New cross-plugin grants are off by default. Prompt,
standing instructions, progress text and results are not exported on this bus.
The existing `read_status` / `status` and permitted local speech remain intact.
Version 0.3.0 adds three optional actions using the same transport:

- `list_handoff_targets`: a bounded JSON list of cached connected target IDs,
  names, organization and workspace. It omits account handles and instructions.
- `prepare_handoff(target_id, task)`: creates a local review draft and opens this
  plugin's window. It returns `review_id` and a clear draft-only message. No
  Fuego message or job is submitted. An existing review cannot be overwritten.
  You still inspect the full target/instructions and choose **Send to Fuego**.
- `read_handoff_status(request_id)`: inspect that exact draft or saved handoff,
  rather than whichever job the user currently selected. Missing IDs and a
  different server are unavailable. `observed_at` is the last confirmed job
  read, or zero for an unsent draft; this read does not manufacture freshness.

The draft action uses the router's normal local-change review. A workflow's
completion means its draft/status steps finished, not that the remote job ran.
The saved **Fuego — prepare a task for review** workflow binds `review_id` into
the status step. New grants remain off by default; this Mac has explicitly
enabled only these three actions for Automations. No SDK Send action is
exported; 0.4.0 adds scoped cancellation through its separately reviewed wait. See the [verified milestone](../reports/ember-recovery-2026-10-14/README.md).

Tasks are at most 2,048 UTF-8 bytes; reviews expire after two minutes. Native HTTP
uses fixed company, agent, private conversation and run routes on the selected
HTTPS origin, a 12-second abort and 512 KiB response cap. The bundled Nook page
has no networking; a separate remote sign-in WebKit view has no native message,
file or shell bridge. Fuego's existing server authentication and authorization
remain authoritative. Source tests do not establish live provider execution.

## Verified recovery (14 October 2026)

Fuego's owner Resume path now recognizes the exact acknowledged Mac stop
receipt before admitting new private owner input. Released local setup
workspaces are allowed; active resources and failed cleanup remain blocked.
It preserves the failed predecessor and unknown action outcomes, never retries
that failed job, and coalesces the original saved wake into one successor.
The previously stuck Ember message recovered, stopped from the Nook with a
matching native receipt, and remained cancelled after restart. A fresh reviewed
message then completed normally. Other runtimes and uncertain stop receipts
retain their existing holds. Recovery itself is owned by Fuego; the Nook still
does not automatically resend a message or reset a conversation.

## Workflow completion — 0.4.0

On NeroNook 0.27.0 or newer, enable **Wait for a Fuego job to finish** for
Automations, alongside the existing prepare/status actions. Add that step after
Prepare and bind `review_id` into its `request_id`. Approve each workflow action;
then inspect the complete target/instructions/task in Fuego Agent and choose
Send. The wait itself cannot Send. Its external-change review allows Stop of
only that referenced handoff. New grants start off; this Mac enables these four
Automations capabilities and retains its prior local speech connection.

The wait watches that exact ID regardless of selected job. It follows real
queue, dispatch and outcome stages with observation age, without invented
percentages. A successful linked final answer releases the next step and returns
`request_id`, `run_id`, `result` (at most 2,048 UTF-8 bytes) and
`result_truncated`. The full answer stays in this module's private saved handoff.
The Nook shows its latest workflow result in memory, not persistent host history.

Stop before Send closes the exact unsent draft. Stop after Send waits for its
run ID if necessary, requests remote cancellation once, and waits for the bound
remote stop result. A lost acknowledgement is not retried. If success wins the
race, the completed action remains a success but the workflow stops before
later steps. Missing connection/storage, an unconfirmed Stop deadline or timeout
is Interrupted/unknown, not a claim that the computer stopped. The wait has
30-second inactivity and one-hour absolute limits; Stop waits at most two
minutes. Normal progress renews inactivity but never these absolute limits.

Wait bindings are session-local. Reopening the app marks the workflow
Interrupted, keeps original handoffs/results, and never resends a job or
cancellation. Inspect/recheck the original in this module before starting a new
workflow. Older hosts omit the optional wait action and retain the existing
monitor/draft/status capabilities. No Fuego IDs or implementation were added to
the host. [Native checks and limits](../reports/workflow-wait-2026-10-14/README.md).
