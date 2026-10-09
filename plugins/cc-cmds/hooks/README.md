# The general-session banner seats

Two hooks in this directory raise a desktop banner when a general Claude Code
session needs the person back. They are a different system from the unattended
pipeline's banners, they are switched independently, and this file is the
contract both of them are written against.

It lives here, beside the scripts, for three reasons: an implementer looking for
the seats finds it without being told where to look; it ships with the plugin,
which `docs/` does not, because that directory is gitignored in this repo; and a
lint can scan it, which is what makes the kill-switch sentence at the bottom an
anchor rather than a good intention.

The two banner seats are not the only hooks in this directory.
`active-notify-pretool.sh` belongs to the `active-notify` skill,
`session-return-dismiss.sh` closes a session's banners when the person comes
back to it, and `stage-policy-edit-drift.sh` is the edit-time seat of the
stage-policy drift check; the last two have their contracts in later sections
of this file. `autopilot-status.tsx` is not a command hook at all but a plugin
module, and it is currently not listed under `"modules"`, so it does not load;
its section is the last one. None of the four raises a session banner, and the
rules below are written for the two seats alone.

## The two seats, and there are only two

| Seat | Event | Matcher | What it reads | Token |
|---|---|---|---|---|
| 1 | `PreToolUse` | literal `AskUserQuestion` | all of `.tool_input.questions[]` | `session-ask` |
| 2 | `Stop` | (none) | the marker line in `.last_assistant_message` | `session-turn` |

Seat 1 is structurally irreplaceable: it fires at the moment the dialog opens and
it is the only event that carries the question text. Two alternatives were
measured and rejected — a permission notice arrives 6.03 s late with a fixed
message and no body, and an idle notice does not fire at all while a dialog is on
the screen.

The two seats cannot erase each other. `Stop` does not fire while a question is
open; it arrives after the person has answered and the turn has genuinely ended,
and the last message at that point carries no marker. So at most one banner is
waiting at any time.

**Seat 1's body is split by question count.** One observed payload carried three
questions, every `header` was ten characters or fewer, and the first `question`
was 120. The body is cut, so carrying only the first question would leave no
trace that the others exist.

| Count | Body |
|---|---|
| 1 | `<header> — <question>` |
| 2 or more | `질문 N건 — <header1> · <header2> · …` — the `question` text is dropped |
| 0 | `답을 기다리는 질문이 있습니다` |

## The marker syntax — this file is the canonical copy

Seat 2 fires on a line the model writes. The syntax is exactly this:

```
**cc-cmds 차례 넘김**: <한 줄 이유>
```

It is anchored at the **start of the last non-empty line** of the assistant's
message. Six false-positive shapes fall out of that definition without needing
rules of their own — no marker, a marker inside a `> ` quote, a marker on a `- `
bullet, an indented marker, a marker inside a fenced block (the closing fence is
then the last non-empty line), and a marker spliced into the middle of a line.
A marker followed by one or more blank lines **does** fire, which also follows
from the definition; implementing the opposite loses a large share of the true
positives and loses them silently.

**Three copies of this string exist and one of them cannot be linted.** The
canonical copy is the block above. The hook script `session-turn-notify.sh`
carries an anchor string that is a copy of it. The third copy is the line a user
puts into their own global `CLAUDE.md`, which is what actually causes a model to
write the marker at all — nothing in this repo writes that file, so if the
canonical copy is ever edited the user has to be told again. One character of
drift in any copy makes seat 2 permanently silent, and that silence is
indistinguishable from nobody having marked a turn.

## The firing gate

Written as a firing predicate, not as a suppression:

```
.agent_id is absent      AND      cc_caller_is_router is true
```

| Conjunct | What it separates | Why it is needed |
|---|---|---|
| `.agent_id` absent | subagent vs. main thread | only an unspawned seat may raise a banner |
| `cc_caller_is_router` true | router session vs. stage session | the unattended run raises its own banners |

The two do different jobs, so neither can stand in for the other and dropping
either lets one of the two cases through. Stating the pair as a suppression
inverts the first conjunct, after which a subagent is not filtered at all.

`agent_id` is present **only inside a subagent**. The gate reads it and not
`agent_type`, and the schema says so in as many words: *Use this field (not
agent_type) to distinguish subagent calls from main-thread calls.* `agent_type`
is also present on a main thread started with `--agent`, so gating on it kills
both seats in an ordinary session with a person in front of it — and it fails in
the direction where no banner appears, which cannot be told apart from an absent
marker.

## Where the banner text comes from

**The body comes only from what the harness handed over.** Seat 1 reads
`.tool_input.questions[]` out of the `PreToolUse` payload; seat 2 reads
`.last_assistant_message` out of the `Stop` payload. Neither re-reads the
conversation to reconstruct it — there is no path in either seat that opens a
transcript file. **The only change that can break this property is adding a
transcript fallback**, and it is named here so that a later finding about how
often the message field is absent does not become a reason to add one. That
fallback also re-fires markers that already fired, because a turn whose last
message has no text block makes the walk pick up the message before it.

## The eight rules the scripts are written against

1. **Every path exits 0.** A `Stop` hook that exits 2 stops the turn from ending;
   a banner hook that dies with 2 puts the session in a loop.
2. **Not one byte on stdout.** A hook's stdout is the harness's control channel.
3. **Not one byte on stderr either.** A non-zero exit plus stderr leaves a line
   in the interactive transcript, and a user who switched the banners OFF
   receiving an error line in their place is the worst shape this can take.
4. **`set -uo pipefail`, never `-e`, and the reason goes in the script header.**
   The two sibling hooks in this directory disagree, and the one that sorts first
   alphabetically is the dangerous one to copy.
5. **No status-answering predicate is called bare.** There are two of them —
   `cc_notify_session_enabled`, which says 1 to the user who switched the banners
   off, and `cc_caller_is_router`, which says 1 in a stage session. For both, a
   normal false is status 1, so under `-e` the hook dies exactly for the person
   or the environment that produced that false. Rule 4 prevents it and the `if !`
   wrapping handles it; **both** calls are wrapped, because wrapping only the
   kill switch leaves the failure reachable from a stage session alone, where
   every general-session test stays green and the break costs one unattended
   night to observe.
6. **An empty session id does nothing and exits 0.** An empty id makes every
   session share one group string, and the prefix is still correct, so no
   negative assertion downstream can catch it. The hook is the only place it can
   be caught.
7. **The gate reads `agent_id`, not `agent_type`** — see the firing gate above.
   The reason is repeated in each script header, because without it the next
   reader concludes that reading both fields is safer.
8. **A missing `jq` exits 0, silently.** Both seats parse JSON on stdin, so `jq`
   is a hard runtime dependency, and the PATH a hook process inherits is not a
   value this design measured. Without the guard the shell writes
   `command not found` to stderr and rule 3 breaks for users who never switched
   anything off. The sibling hook's two-line defence is transplanted unchanged:
   prepend the Homebrew paths, then `command -v jq >/dev/null 2>&1 || exit 0`.

**The scripts source the emitter rather than calling the notifier.** The title,
the group and the firing line all live in
`../orchestrator/notify-run.sh`, and keeping the firing line shared is what keeps
`-execute` on every banner this tree raises — a firing point that assembles its
own argv is how that argument was dropped once already. Its value is what
`notify-focus.sh exec-arg` built: `:`, or
`/bin/bash '<handler>' focus '<socket>' '<pid>' '<pane>'`. When no value can be
built it falls back to `:`, and there is no path that drops `-execute`. A hook
inherits the session's `TMUX`/`TMUX_PANE`, so its banner's click selects the
pane the session runs in and its iTerm2 tab and session. Bringing that window
forward, and reaching it on another Space, happens only when the click's helper
raised it; that needs the notifier app in System Settings → Privacy & Security
→ Accessibility, a Swift compiler (Command Line Tools or Xcode), and a window
that answers the Accessibility API in time. The grant is the app's, so it
applies to the click command of every banner the notifier raises, not only to
the ones these hooks raise.

**Building the value also starts a background resolution for that pane.**
`exec-arg` detaches a `prime` that finds the iTerm2 window holding the pane and
caches it, so a click a minute later goes straight there instead of walking
every window. The prime is detached the same way the click is, it writes only
under the per-user cache directory
(`$(getconf DARWIN_USER_CACHE_DIR)cc-cmds/notify-focus`), and it never raises a
banner — the hook's five-second budget is not spent on it. It asks iTerm2
nothing unless Apple events to iTerm2 are already allowed, so it cannot bring
up a permission prompt. A hook whose session switch is off starts none, because
the emitter checks the switch before it builds the value.

**Five `hooks.json` entries pin `"timeout": 5`: the two seats' entries and the
return hook's three** (`UserPromptSubmit`, `PostToolUse` with the matcher
`AskUserQuestion`, and `Stop`). The `Bash` entry under `PreToolUse` has no
timeout and the `Edit|Write|MultiEdit` entry has 10, so "every entry" would be
wrong. All of these events block, and the default is long, so an emitter that
stalls for any reason would stall the session with it. Nothing in the design
depends on the number: the measured worst case for a hook body is 84 ms
synchronous and 23 ms detached, and a stubbed notifier measured 62.6 ms — five
seconds is two orders of magnitude of headroom either way.

**Seat 1 is a sibling entry under `PreToolUse`, seat 2 is an entry under the
top-level `Stop` key.** The existing `Bash` entry is left alone and the matchers
are not merged into `"Bash|AskUserQuestion"`: merging would make the sibling
hook's `non-Bash matcher slip → noop` line a permanently active path instead of
the defence it is. Putting the `Stop` entry into the `PreToolUse` array instead
of its own key is a silent failure — the harness passes it over on a matcher miss
and seat 2 simply never runs.

**The return hook adds three entries.** A new top-level `UserPromptSubmit` key; a
sibling entry under `PostToolUse` with the matcher `AskUserQuestion`, not merged
into the `Edit|Write|MultiEdit` entry; and a sibling entry under `Stop`, leaving
seat 2's entry byte for byte as it was. The `PostToolUse` entry has to keep its
matcher: without it every tool call of the session would reach the hook. The
script checks `.tool_name` itself as well, so a lost matcher or an entry placed
in the wrong array still closes nothing on an ordinary tool call — that would
turn "the person came back" into "the session did anything".

## Switching the banners off

The session seats have their own switch, independent of the unattended pipeline's
`CC_CMDS_AUTOPILOT_NOTIFY`. Wanting one of the two kinds of banner without the
other is a real state and one variable cannot express it. The value grammar is
the same for both — `0`, `off`, `false` and `no` switch them off, case
insensitively, and an unrecognized value reads as ON.

- 「이 머신의 일반 세션 배너를 끄시려면 세션을 띄우기 전에 `CC_CMDS_SESSION_NOTIFY=0` 을 걸어 주세요 — `off`·`false`·`no` 도 대소문자 구분 없이 같게 읽습니다.」

Closing the banners on return has a third switch of its own, with the same
grammar. Switching it off stops both the record the `Stop` entry keeps and the
closing; the banners themselves still appear.

- 「이 머신에서 귀환 때 배너 닫기를 끄시려면 세션을 띄우기 전에 `CC_CMDS_SESSION_DISMISS=0` 을 걸어 주세요 — `off`·`false`·`no` 도 대소문자 구분 없이 같게 읽습니다.」

**A typo in that value is silent, on purpose.** The unattended switch warns on an
unrecognized value; the session switch cannot, because the warning goes to stderr
and rule 3 forbids it, and because the once-guard that keeps that warning to one
line per run is a file under the run directory, which a session does not have.
The cost is real and reaches the user: `CC_CMDS_SESSION_NOTIFY=flase` leaves the
banners on while the person believes they are off. The opposite polarity was
rejected because a typo would then remove the banners silently, which is the
worse of the two silences.

## Reach

These hooks run only in a session that loaded this plugin, and this plugin is
loaded with `--plugin-dir` rather than from a marketplace install. The flag is
added by shell functions that are **not in this repo**, so the reach is "sessions
started on this machine through those functions" and the file that draws that
boundary is outside version control. The checkable form of the boundary is: do
those shell function definitions still carry `--plugin-dir`?

Where the reach does not extend, the seats do not exist, and their absence shows
up on no screen at all. This design does not guarantee that a banner appears. It
guarantees that a banner never blocks anything.

## The return hook

`session-return-dismiss.sh` closes the banners a session raised once the person
is back in that session: its slot under `cc-cmds-session-<sid>` and every
`active-notify` banner it raised. It raises nothing, and it calls no notifier
itself — a detached job clears the session slot through `cc_notify_clear
session-ask` first and then runs `notify.sh dismiss <sid>`, which reads
`terminal-notifier -list ALL` once and removes the rows whose group is
`cc-cmds-active-notify-<sid>` or starts with `cc-cmds-active-notify-<sid>@`.
The session id is the payload's `.session_id`, the same value the firing side
puts in the group. The session slot is cleared first so that a question raised
right after an answer has the shortest possible window to be erased by a late
clear.

**What counts as a return.** Two events close: answering an `AskUserQuestion`
(`PostToolUse`, always a return) and submitting a message (`UserPromptSubmit`,
after the classifier below). `Stop` closes nothing; it only keeps the record the
classifier reads. A permission prompt answer is not a return — no hook event can
tell it apart from an ordinary tool call.

**The classifier, in this order.** A `UserPromptSubmit` also fires when no person
is there, and its payload carries no field that tells the two apart.

1. **A recorded scheduled task is not a return.** If the prompt is byte for byte
   one of the texts the last `Stop` recorded, or a recorded text ends in the
   truncation mark (`… [+N chars]` or `... [+N chars]`) and the prompt starts
   with its head, a `/loop` repeat or a `ScheduleWakeup` wake-up is arriving.
2. **A prompt that opens with an XML-shaped element is not a return.** Leading
   whitespace is allowed; the pattern is tested with `[[ =~ ]]` on the whole
   prompt, so `^` binds to the very start and a tag on the second line does not
   count. A background agent's `<task-notification>` arrives in this form.
   `<pasted_content …>` is the exception and is a return, because it is the
   wrapper around text the person pasted.
3. **Everything else is a return**, including a message typed while the model is
   still working. No time window is used.

The scheduled-task check comes before the envelope check, so a scheduled text
that itself starts with `<` is still recognised as a scheduled task.

**The state file and its life.** `${TMPDIR:-/tmp}/cc-cmds-session-return/<sid>.crons`,
the sid sanitised by the same expression as `notify.sh` uses, in a sibling of
the `active-notify` flag directory rather than inside it. It holds one compact
JSON array, `[.session_crons[]?.prompt | strings]`, because a scheduled text may
contain newlines. Every `Stop` that carries `session_crons` rewrites it whole
(`umask 077`, a `mktemp` sibling, `mv -f`), and an empty array removes it. A
`Stop` without the key leaves it alone: the key is documented as present when
the task registry is reachable, so its absence means "could not read", not
"nothing pending". The reader never writes it. A session that ends with a task
still pending leaves one small file behind, read only by that sid.

**Why there is no `agent_id` gate.** A successful `PostToolUse(AskUserQuestion)`
means a person answered, whoever asked; a subagent's tool events carry the
parent's `session_id`, and `UserPromptSubmit` has no subagent form. The seats'
gate exists because only the main thread may raise a banner; closing on a
person's answer has no such reason. The other gates are kept, in this order:
`jq`, sourcing the emitter, the switch below, `cc_caller_is_router`, and a
non-empty session id. A stage session therefore neither records nor closes.

**The misses it accepts.** Each fails in the direction where a banner stays up:

- A question closed with Esc raises no hook event, so its banner stays until the
  person's next message or answer.
- A return that only runs a local slash command such as `/context` raises no
  `UserPromptSubmit` and closes nothing. A slash command that invokes a skill
  does, and closes like any message.
- Typing a message byte for byte equal to a pending scheduled task's text closes
  nothing; the two payloads are identical.
- Typed text that opens with markup (`<div>…`, `<br/>`) reads as an envelope and
  closes nothing. Missing a machine envelope would close banners nobody saw, so
  the broad rule was chosen.

It touches nothing else: no `active-notify` flag or lock, no `cc-cmds-autopilot-*`
banner, no banner without a group, and not the permission-test bypass banner
under the global `cc-cmds-active-notify`. Banners raised before the upgrade —
under that global group, or without a group — are not reached either and stay
until removed by hand. Of the eight rules above, every one but the seventh
applies to it unchanged, and rule 5 covers its own switch the same way.

## The edit-time drift hook

`stage-policy-edit-drift.sh` is registered under a top-level `PostToolUse` key
with the matcher `Edit|Write|MultiEdit` and `"timeout": 10`. It does not raise a
banner. It exists because `../orchestrator/stage-policy.md` is a distillation of
two files a person edits by hand, and the session that just made the edit is the
one that knows what the edit meant.

**When it acts.** Only when `.tool_input.file_path` is the user-scope
`CLAUDE.md` (`${CLAUDE_CONFIG_DIR:-$HOME/.claude}/CLAUDE.md`) or the file the
host map's `workspace` line names (`~/.config/cc-cmds/stage-policy-sources`).
Both sides are compared with their directory resolved by `pwd -P`, so a path
that came in through a linked settings directory is the same file. Every other
edit ends after one `jq` call.

**What it does.** It runs `../orchestrator/stage-policy-drift.sh --explain`, and
when the last line is `mismatch` it writes one object to stdout:
`{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"…"}}`.
The context, cut at 6000 bytes, carries the findings and their diffs, the policy
section to compare each one with, the instruction to run `--ack` once and only
after the user confirms every pending finding — `--ack` has no per-row form and
records them all, so a single rejection means it is not run — the rule that an `added` item
is recorded with `--ack-added` when it is excluded or belongs to a skill and
needs a repository change when it belongs in the policy, and the prohibition on
recording anything without that confirmation. The instructions come before the
findings, so the cap cuts findings and never the prohibition. They also state
the checker's finding count (from the `mismatch <n>` line) and tell the session
to run `--explain` itself before any `--ack`. When the findings do not fit, they
are cut at a line boundary and end in
`[truncated: the checker reported <n> finding(s); run bash "<checker>" --explain for the full list]`,
so a partial list never reads as the whole one.

**Why stdout is used here.** The banner seats keep stdout empty because it is
the harness's control channel. For a `PostToolUse` hook that channel is exactly
how text reaches the model, so this hook writes to it on the one path that has
something to say and on no other.

**Unattended runs are left alone.** With `CC_PIPELINE_RUN_ID` set the hook does
nothing: an acknowledgement is a person's claim, an unattended stage has nobody
to make it, and the checker refuses `--ack` and `--ack-added` there as well.

**Every path exits 0 and nothing reaches stderr.** It runs under
`set -uo pipefail`, never `-e`, because the checker answers `mismatch` with exit
1 and that is the case the hook exists for. The checker's stderr goes to
`/dev/null`, and a missing `jq` exits 0 after the same Homebrew PATH prepend the
banner seats use.

## The run-status pane module

**The module is withdrawn for now.** `hooks.json` does not list it under
`"modules"`, so no session loads it and `/autopilot-status` is not registered.
What it shows is too thin to be worth a pane, and it is held back until the
pane is rebuilt with more of the run in it. The module, its tests and the
helper stay in the tree, and the rest of this section describes them as they
will run once the module is listed again.

`autopilot-status.tsx` is a plugin module (`"modules"` in `hooks.json`), not a
command hook. In an interactive session it shows, in a pane titled `autopilot`,
the state of the one run the status line picked for this session: the status
line's own head line, the segments that have not finished, open approvals,
run-scope and cone-scope blocks, and orphaned stages.

**The module decides when, the shell decides what.** Every line, its order, its
tone, the run's class (`live`, `ended`, `none`) and the refresh period come from
`../orchestrator/run-pane.sh <session id>`. The helper calls the unchanged
`statusline.sh` for the head line, so the pane and the status line always name
the same run, and it always exits 0 and writes nothing. Its first row is
`cc-pane<TAB>1<TAB><class><TAB><run id|-><TAB><session index path|-><TAB><refresh ms>`,
and every row after it is `<tone><TAB><text>`, at most 15. The module checks
`cc-pane` and the schema `1` exactly; on a mismatch, a non-zero exit or a failed
run it keeps the last good lines, adds one warning line, and opens nothing. Tones
map to theme keys (`ok` success, `warn` warning, `error` error and bold, `accent`
suggestion, `dim` dim); any other tone is drawn plain.

**When the helper runs.** A ten-second clock checks the session id, the module's
panes and the session index file's mtime without starting a process, and runs
the helper only when the session id changed, the index changed or appeared, the
pane is placed and the helper's refresh period passed, or the pane is not placed
and sixty seconds passed. One run at a time, eight seconds at most.

**Opening and closing.** The pane opens by itself once per live run: only when
the run is `live`, the module has not opened it for that run before, nobody
closed it for that run, and the pane is not already open (placed or waiting for
width). It never closes by itself; a finished run leaves its last lines up.
`/autopilot-status` toggles it: a placed pane is closed and the run is recorded
as dismissed, otherwise the pane is opened and the helper runs once. A pane the
person closes records its run as dismissed; a pane dropped by an unload records
nothing. These records live in the session's `$.state`, declared in
`../types/index.d.ts`, so a module reload does not forget them.

**Nothing happens outside an interactive session.** The first statement of the
`session.start` hook returns when the session is not interactive, and the next
returns when any of `CC_PIPELINE_RUN_ID`, `CC_PIPELINE_STAGE_ID` or
`CC_PIPELINE_SHIFT_ID` is non-empty. Only after both does the module register the
command or start its clock, so a stage, a shift or a `-p` run gets no command,
no process and no pane.
