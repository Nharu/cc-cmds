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
back to it, `session-title.sh` names a session after the slash command it is
running, and `stage-rules-edit.sh` shows the stage rules status after an
edit of the user-scope `CLAUDE.md`; the last three have their contracts in later sections
of this file. `autopilot-status.tsx` is not a command hook at all but a plugin
module, listed under `"modules"`; its section is the last one. None of the five
raises a session banner, and the
rules below are written for the two seats alone. The question form under
`question-form/` is a sub-mod: `autopilot-status.tsx` is the one entry listed
under `"modules"`, and its `register` hands `register(on, options)` on to the
form as well. The form raises no banner of its own and reaches seat 1 instead,
as the next section says.

`gate-pretool.sh` belongs to the unattended pipeline: a run installs it through
its own settings, never through `hooks.json`. `enforcement-surfaces.sh` beside
it is the classifier of the enforcement surfaces that hook refuses to edit
(project settings, transcripts, the rule catalog, instruction files). The hook
only picks a refusal message per class it returns, and the gate, the driver and
the screening tool classify a path with the same file, so they cannot disagree
with the hook. A hook copy whose directory lacks the classifier refuses every
edit, because a path it cannot classify is not one it may allow. Neither file
raises a banner.

## The two seats, and there are only two

| Seat | Event | Matcher | What it reads | Token |
|---|---|---|---|---|
| 1 | `PreToolUse` | literal `AskUserQuestion` | all of `.tool_input.questions[]` | `session-ask` |
| 2 | `Stop` | (none) | the marker line in `.last_assistant_message` | `session-turn` |

Seat 1 has a second caller that is not a hook entry. The question form's mod
(`question-form/`) runs the same `session-ask-notify.sh` through `$.process.run`
when it opens a new form, with a stdin it builds in the `PreToolUse` shape —
`session_id`, `tool_name` set to `mcp__cc-cmds__question_form`, and
`tool_input.questions[]` holding each question's `header` and `question`. The
script never reads `tool_name`, so the body, the group and the gate are the ones
written below. The mod sends no `agent_id`, because it registers its tool only in
the main session, and it does not register at all where a pipeline marker is set.

Seat 1 is structurally irreplaceable for `AskUserQuestion`: the hook fires at the
moment the dialog opens and it is the only event that carries the question text.
Two alternatives were measured and rejected — a permission notice arrives 6.03 s
late with a fixed message and no body, and an idle notice does not fire at all
while a dialog is on the screen. The question form needs no event for this: the
mod holds the questions itself at the moment it opens the pane.

The two seats cannot erase each other. `Stop` does not fire while a dialog is
open; it arrives after the person has answered and the turn has genuinely ended,
and the last message at that point carries no marker. The question form is
different: the turn that opens it ends at once while the form stays up, so a
seat-1 banner from the form and a seat-2 banner from that turn's marker can both
be waiting. Both land in the same session group, so the later one replaces the
earlier rather than stacking.

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
indistinguishable from nobody having marked a turn. The question form's banner
does not depend on this string: it is raised through seat 1 when the form opens,
so drift here silences seat 2 alone.

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
`.tool_input.questions[]` out of the `PreToolUse` payload — for the question
form, the payload the mod built from the tool input the harness handed it;
seat 2 reads `.last_assistant_message` out of the `Stop` payload. Neither re-reads the
conversation to reconstruct it — there is no path in either seat that opens a
transcript file. **The only change that can break this property is adding a
transcript fallback**, and it is named here so that a later finding about how
often the message field is absent does not become a reason to add one. That
fallback also re-fires markers that already fired, because a turn whose last
message has no text block makes the walk pick up the message before it.

**The session title in the title line comes only from the current title file
the session title hook writes.** Both seats read
`${XDG_STATE_HOME:-$HOME/.local/state}/cc-cmds/session-title-now/<session_id>`
through `cc_notify_session_title_read` in `notify-run.sh`, after every gate, and
the title table then reads `cc-cmds · <title> · 답하세요` and
`cc-cmds · <title> · 차례가 넘어왔습니다`, the title cut to 24 display columns
with the hook's own `cw`/`cut` definitions so the action at the end survives.
This value does not open a transcript either. When the file is missing,
unreadable, has a different first line or an empty second line, or when the id,
`jq` or the state root is missing, the title line is today's wording. Neither
the seats nor the emitter read the title switch `CC_CMDS_SESSION_TITLE`: a file
written before that switch was set is still read.

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
that answers the Accessibility API in time. With that grant, when iTerm2 hands
the key window back to the window the person left within a few seconds of the
switch, the click sets the target window as the key window again. The grant is
the app's, so it applies to the click command of every banner the notifier
raises, not only to the ones these hooks raise.

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

**Six `hooks.json` entries pin `"timeout": 5`: the two seats' entries, the
return hook's three** (`UserPromptSubmit`, `PostToolUse` with the matcher
`AskUserQuestion`, and `Stop`), **and the session title hook's
`UserPromptSubmit` entry**. The `Bash` entry under `PreToolUse` has no
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

**The return hook adds three entries.** A new top-level `UserPromptSubmit` key
(the session title hook's entry is a sibling in that same array, after this
one, with no matcher); a
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

## The session title hook

`session-title.sh` names a session after the slash command it is running. It
is the second entry of the `UserPromptSubmit` array, a sibling after the return
hook's, with no matcher and `"timeout": 5`; `SessionStart` is not used, because
a session is not named when it starts. It raises no banner, sources nothing
from `../orchestrator/`, and reads no `CC_PIPELINE_*` variable,
`.transcript_path` or `.agent_type`.

**What it emits.** On the one path that titles the session it writes exactly
one line to stdout,
`{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","sessionTitle":"…"}}`,
and nothing on any other path. The harness stores that title where `/rename`
stores a name, so it shows in the `cc -r` picker, the prompt box and the
terminal title. The title is `<label>·<summary>`:

- The label is the command name without its namespace: `/cc-cmds:review 1085`
  gives `review`. Only the first line of the prompt is read, and it must start
  with `/`. A namespaced name always counts; a bare name counts only when it
  resolves in one of five places — the plugin's `skills/<name>/SKILL.md`, the
  configuration home's `skills/<name>/SKILL.md` or `commands/<name>.md`, or the
  same two under `<cwd>/.claude/`, `<cwd>` being the payload's `.cwd`. A plain prompt, a pasted path
  and a built-in command are not titled.
- The summary is built from the arguments: quoted arguments stay one piece and
  lose their quotes, `--flag value` and `--flag=value` are dropped, a
  pull or issue URL becomes `#N`, a path or `.md` file becomes its base name
  without `.md`, a `YYYYMMDD-<8 hex>` run id becomes the hex part, and a leading
  bare number becomes `#N`. `/cc-cmds:review 1085` gives `review·#1085`; with
  no summary the title is the label alone.
- **The width is 38 display cells**, measured and cut inside the one `jq`
  program by the same `cw`/`cut` definitions the banner emitter carries (a test
  compares the copies byte for byte). A label wider than 38 is cut alone.
- **Normalisation follows the harness's.** C0 and C1 controls, the line and
  paragraph separators, every Unicode 17.0 `Cf` code point and the spaces
  JavaScript `trim` removes are compared by code point, so the hook's idea of
  "the same title" is the one the harness applies when it stores it.

**It never overwrites a name a person gave.** The harness does not protect a
`/rename` name from a hook title, and the payload carries no field saying who
set the current title. So the hook remembers what it emitted, per session, and
acts only when the current `.session_title` is empty or one of its own — equal
to a remembered title, or one with the harness's uniqueness suffix
`-<adjective>-<noun>[-N]` (lowercase only). The first time it sees a title it
did not emit, it marks the session released and never titles that session
again. After `/clear` — a new session id carrying the old title — the title is
adopted when it is the last title another session's file recorded. The same
title again, with or without that suffix, is not emitted: the harness skips
the first itself, and the second may come back without the suffix after a
resume.

**The ownership state file.**
`${XDG_STATE_HOME:-$HOME/.local/state}/cc-cmds/session-title/<sid>`, the sid
accepted only when it matches `^[A-Za-z0-9-]+$`. Line 1 is the schema line
`cc-session-title v1`; the rest is either up to the four newest titles, oldest
first, or the single line `!released`. It is written through a `mktemp`
sibling and `mv -f`. A title that could not be remembered is not emitted,
because next time it would read as a person's name and stop that session's
titling for good. The directory holds this one format only, because the
`/clear` lookup reads every file in it.

**The current title file.**
`${XDG_STATE_HOME:-$HOME/.local/state}/cc-cmds/session-title-now/<sid>` holds
the session's title as it stands, whoever set it: two lines, the schema line
`cc-session-title-now v1` and the title. Every prompt that gets past the
session id check sets it once, before the stdout line — on a plain prompt, on
a released session, on someone else's title, on a repeat, on a failed state
write and on an emitted title alike. The value is the emitted title, or else
`.session_title` with each run of control characters turned into one space. A
different value is written through a `mktemp` sibling and `mv -f`; an empty
value removes the file; an equal value leaves it alone, mtime and all. A
failure here changes neither the output nor the ownership state. It lives in
its own directory so that the ownership directory keeps one format.

What a reader of that file must do:

- Read it and nothing else: take line 1 as the schema check and line 2 as the
  title, without trimming. Never fall back to the transcript.
- Do not read the switch below. A file written before the switch was set stays
  where it is and is still read; switching the hook off stops the updates, not
  the file.
- Never write it.

**Old files go after 30 days.** When a call wrote or removed a file in either
directory, it then runs `find <dir> -type f -mtime +30 -exec rm -f {} +` over
both directories; a call that wrote nothing sweeps nothing. Reverting the
plugin removes the hook that sweeps, so whatever is in
`~/.local/state/cc-cmds/session-title/` and
`~/.local/state/cc-cmds/session-title-now/` (or the same two under
`$XDG_STATE_HOME/cc-cmds/`) is left behind until removed by hand.

**Which of the eight rules apply.** Five apply as written: every path exits 0
(rule 1; exit 2 on this event blocks the prompt), nothing reaches stderr
(rule 3), `set -uo pipefail` and never `-e` with the reason in the script
header (rule 4), the subagent gate reads `agent_id` and not `agent_type`
(rule 7; this event's payload carries no `agent_id` today, so the branch is a
defence), and a missing `jq` exits 0 silently after the same Homebrew PATH
prepend (rule 8). **Rule 2 does not apply**: this hook answers through stdout,
so it writes the one JSON object there on the titling path. A
`UserPromptSubmit` hook's plain stdout is added to the model's context, so no
diagnostic is ever written there.

**There is no pipeline-marker check, on purpose.** Unattended stage sessions
get their titles by the same rules. Copying the stage check of a sibling hook
here would make stage titles disappear without a sound.

**Switching it off.** The value grammar is the one the banner switches use, and
an off value exits before stdin is read, so neither file is written or removed.

- 「세션 제목 훅을 끄시려면 세션을 띄우기 전에 `CC_CMDS_SESSION_TITLE=0` 을 걸어 주세요 — `off`·`false`·`no` 도 대소문자 구분 없이 같게 읽습니다.」

**Where the title shows.** A user-defined title, whoever set it, is used by the
`cc -r` picker and its search, the prompt box and the terminal title. The
terminal title gets a two-cell status glyph in front (`✳ <title>` inside tmux
while the harness keeps a static glyph there, a spinning one otherwise; two
cells either way) and becomes the tmux `pane_title`. With
`terminalTitleFromRename: false` in the settings, or
`CLAUDE_CODE_DISABLE_TERMINAL_TITLE` in the environment, it does not reach the
terminal title at all. The tmux status line is drawn by tmux outside the Claude
Code screen, so it stays visible while an `AskUserQuestion` dialog covers the
prompt box. The recommended `~/.tmux.conf` block widens the title to 40 cells
and, if wanted, mirrors it to the outer terminal's tab and window title:

```tmux
set -g status-right-length 60
set -g status-right '#{?window_bigger,[#{window_offset_x}#,#{window_offset_y}] ,}"#{=40:pane_title}" %H:%M %d-%b-%y'
# optional: mirror the pane title to the iTerm2 tab/window title
set -g set-titles on
set -g set-titles-string '#{pane_title}'
```

The two quotes, 40 title cells, the time and the date come to 58 cells, inside
60; only while `window_bigger` adds its prefix can the end of the date be cut.
The two `set-titles` lines are optional: with them a tab that is asking shows
it in its tab title while another tab is in front. `window-status-format` and
`automatic-rename` are not recommended, because each Claude Code instance has
its own tmux session and the window name is tied to the version number.
Whether tmux redraws the status line as soon as the title changes or waits for
`status-interval` has not been measured; only the delay depends on it. The
block is applied by a person, not by this plugin.

## The stage rules edit hook

`stage-rules-edit.sh` is registered under a top-level `PostToolUse` key with
the matcher `Edit|Write|MultiEdit` and `"timeout": 10`. It does not raise a
banner. It exists because the bullets of the user-scope `CLAUDE.md` tagged
`[무인]` become, at each run's open, the `# Personal rules` block every
unattended stage reads, and the session that just edited that file is the one
that can show the person what the edit did to the block.

**When it acts.** Only when `.tool_input.file_path` is the user-scope
`CLAUDE.md` (`${CLAUDE_CONFIG_DIR:-$HOME/.claude}/CLAUDE.md`). Both sides are
compared with their directory resolved by `pwd -P`, so a path that came in
through a linked settings directory is the same file. Any other `CLAUDE.md` —
a repository's, the workspace file — and every other edit ends after one `jq`
call: the stages read those through the instruction chain, not through tags.

**What it does.** It runs `../orchestrator/stage-rules.sh status --source
<file>` and writes one object to stdout:
`{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"…"}}`.
The context, cut at 6000 bytes, says the file is the source of the personal
rules block and that the next run picks the edit up, tells the session to show
the person the status and leave tagging to them, and carries the status
itself: counts and bytes per tag, the untagged and malformed bullets, the
24576-byte alert, the host map, and the next steps. Past the cap the status is
cut at a line boundary and ends in
`[truncated: run bash "<helper>" status for the full status]`.

**The enforcement notice.** After the status comes a block starting
`Rule enforcement check:` when the edit left a rule uncovered. For an `Edit`
or `MultiEdit`, the lines the edit brought in, and the line of any enforcement
marker it deleted, go to `../orchestrator/stage-rules.sh enforcement
--notice-for -`; the rules it prints — not covered on every path they need by a
live enforcement means, or carrying a dead one — are listed one per line with
the reason, and the block asks the session to put to the person whether a
higher layer could block each one. The marker (`강제: ...` or `산문: <reason>`)
is the person's to add, never the session's. A `Write` replaces the whole file,
so its block carries only the number of such rules in the file. An edit that
leaves no such rule adds nothing: the context is byte for byte the status
alone. Nothing is ever blocked.

The block is held to 2000 bytes: target lines are taken whole from the front,
and the rest is replaced by `[and <n> more: run bash "<helper>" enforcement]`.
Inside the 6000-byte budget the status gets what the block leaves, so the
status is cut first and the block never is. `make rule-enforcement` prints the
full table for the user-scope file by hand.

**Why stdout is used here.** The banner seats keep stdout empty because it is
the harness's control channel. For a `PostToolUse` hook that channel is exactly
how text reaches the model, so this hook writes to it on the one path that has
something to say and on no other.

**Unattended runs are left alone.** With `CC_PIPELINE_RUN_ID` set the hook does
nothing: nobody reads the status there, and a run's block was fixed when it
opened.

**Every path exits 0 and nothing reaches stderr.** It runs under
`set -uo pipefail`, never `-e`. The helper's stderr goes to `/dev/null`, and a
missing `jq` exits 0 after the same Homebrew PATH prepend the banner seats use.

## The run-status pane module

`autopilot-status.tsx` is a plugin module (`"modules"` in `hooks.json`), not a
command hook. It is the plugin's only module entry, and its `register` also
hands `register(on, options)` on to the question form under `question-form/`. In an interactive fullscreen session it docks, in a pane titled
`autopilot`, the state of the one run the status line picked for this session:
a title, the run's head line and its details, every segment with a detail line,
the gate group (approvals, run-scope and cone-scope blocks with their full
reason, cone blocks with no owner, orphaned stages), and the most recent events.

**The module decides when, the shell decides what.** Every line, its order, its
tone, the run's class (`live`, `ended`, `none`), the line budget and the refresh
period come from `../orchestrator/run-pane.sh <session id> [--cols N] [--rows N]`.
The helper calls `statusline.sh` with `CC_SL_PANE_FIELDS=1`, which adds one
field row after the human line, so the pane and the status line name the same
run, state word and watcher verdict from one evaluation. The helper reads the
ledger, the run directory, the run manifest and the session's current title
file only, never calls `jq`, always exits 0, and writes nothing.

**The rows.** The first row is
`cc-pane<TAB>2<TAB><class><TAB><run id|-><TAB><session index path|-><TAB><refresh ms>`.
Every row after it is
`<bundle><TAB><cut|wrap><TAB><tone><TAB><text>[<TAB><tone><TAB><text>]…`:

- The bundle is one of a closed set — `none`, `title`, `session-title`, `head`,
  `head-detail`, `gap`, `seg-heading`, `seg`, `seg-detail`, `seg-folded`,
  `gate-none`, `approval`, `block-heading`, `block-reason`, `cone-unresolved`,
  `orphan`, `event-heading`, `event`. The module drops a row whose bundle it
  does not know.
- `cut` draws the line truncated at its end; `wrap` lets the engine wrap it and
  is used only by `block-reason`, so a block's reason is shown in full.
- A line is one or more tone/text parts drawn in one outer `Text`, so the parts
  wrap or truncate together. A tone is `normal`, `dim`, `ok`, `warn`, `error`
  or `accent`, optionally with `.b` for bold; they map to theme keys (`ok`
  success, `warn` warning, `error` error, `accent` suggestion, `dim` dim), and
  any other tone is drawn plain.

The module checks `cc-pane` and the schema `2` exactly (`1` and `3` are both
refused); on a mismatch, a non-zero exit or a failed run it keeps the last good
lines, adds one warning line, and opens nothing. The lines live in the session
state key `paneLines`.

**The session title line.** When the session has a current title (see the
current title file under the session title hook), the pane shows it as one
`session-title` line, `세션 ` dimmed and then the title, right under the first
line: under `autopilot <run id>` when there is a run, and under `연결된 런 없음`
when there is none. The helper reads the file only for a session id of
`^[A-Za-z0-9-]+$` — narrower than its own id check, which takes dots and
underscores — takes the first two lines untrimmed with the shell's `read` (a
title line without its newline counts, later lines are ignored), and turns a
TAB in the title into a space. A missing or unreadable file, another schema
line or an empty title gives no line, and the output is then byte for byte what
it is without the file. A `/rename` reaches the file only with the next prompt,
so the pane shows it on the first refresh after that prompt.

**The line budget.** The budget is `min(24, dock rows)`, computed and kept by
the helper. The title, the session title line, the head line and its details,
every approval, every block heading and reason line, the cone-without-owner
line, the orphan lines and the line of a segment holding a cone block are
protected and stay even over the budget. Over it, the helper removes, in order, until its estimate fits:
the oldest events (then the event heading and its gap), the details of finished
segments, the finished segments themselves (folded into one
`끝난 세그먼트 N개` line), the remaining segment details (the running
segment's last), the gaps, and finally the open segments without a block
(folded into one `끝나지 않은 세그먼트 N개` line). A `cut` line counts as one
line; a `wrap` line is estimated from its bytes against the dock width. The
dock scrolls whatever does not fit, so the budget decides what is seen first,
not what is lost.

**No value changes every second.** A running stage shows its start time
`<HH:MM> 시작` (now minus the process's `etime`), and ledger and watcher ages
are minutes (`1분 안`, `N분 전`, `N시간 전`), all made by the shell. Events
show their `HH:MM` under a `최근 이벤트 <zone>` heading. Both clocks are in the
display zone; ages do not depend on it. The status line keeps its `mm:ss`
elapsed, and the two cannot disagree because the start time is defined from it.

**Display zone.** `CC_CMDS_AUTOPILOT_TZ` picks the zone of every clock a person
reads; the records on disk stay UTC `Z`. Unset or empty means KST (UTC+09:00).
`UTC` or `Z` (any case) means UTC, and `+HH:MM` / `-HH:MM` within -12:00..+14:00
means that offset, labelled `KST` at `+09:00`, `UTC` at `+00:00` and
`UTC±HH:MM` otherwise. Any other value, including a zone name such as
`Asia/Seoul`, falls back to KST without a warning. The progress feed
(`feed.sh`) and the status line's borrowed segment clock follow the same
variable through the same helper, `orchestrator/display-tz.sh`; an install that
lacks the helper keeps the pane on UTC and leaves the status line clock empty.

**When the helper runs.** A ten-second clock checks the session id, the module's
panes and the session index file's mtime without starting a process. A tick
records the time it read first as the helper's start, and runs the helper when
the session id changed, the index changed or appeared, the pane has just become
placed, or the period passed with half a tick of slack
(`now - lastRunAt >= period - 5 s`). The period is the helper's: ten seconds
for a placed pane on a live run, sixty for an ended run or a pane that is not
placed. So a placed live pane refreshes every tick even when the helper takes
seconds. One run at a time, eight seconds at most. Once a dock has been drawn,
the next run passes its body width and rows as `--cols` and `--rows`; before
that the helper's defaults (44, 24) apply. If the command or a pane close finds
that no tick has run for more than three ticks, it cancels and re-arms the
clock — only in a session whose `session.start` armed it.

**Layout.** A hook on the band above the prompt draws nothing and records the
viewport's `isFullscreen`; the command records the same from its own
presentation. The pane never opens by itself until a band render has shown the
session is fullscreen. A pane that was docked and is now drawn inline, because
the terminal narrowed, shows one dim line instead of its body:
`autopilot 패널은 전체 화면(110칸 이상)에서만 보입니다`.

**Opening and closing.** The pane opens by itself once per live run: only when
the session is known to be fullscreen, the run is `live`, the module has not
opened it for that run before, nobody closed it for that run, and the pane is
not already open (placed or waiting for width). It asks for 44 columns. It never
closes by itself; a finished run leaves its last lines up. `/autopilot-status`
works in this order: a placed pane is closed and its run recorded as dismissed,
whatever the layout; otherwise, if the session is not fullscreen or narrower
than 110 columns, it shows a toast
`autopilot 패널은 전체 화면(110칸 이상)에서만 보입니다 — plugins/cc-cmds/hooks/README.md`
and opens nothing (the toast touches neither the transcript nor the model's
context); otherwise it opens the pane and runs the helper once. A pane the
person closes records its run as dismissed; a pane dropped by an unload records
nothing. These records live in the session's `$.state`, declared in
`../types/index.d.ts`, so a module reload does not forget them; the layout, the
dock size and the clock bookkeeping are module variables and start over.

**Getting a fullscreen session.** The pane is only seen docked, and docking
needs fullscreen:

- Inside tmux control mode (`tmux -CC`) the session is
  fullscreen only with `CLAUDE_CODE_NO_FLICKER=1` in the environment. The
  setting `tui: "fullscreen"` and `/tui fullscreen` do not override the `-CC`
  detection — observed on engine 2.1.295.
- `CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN`, or `CLAUDE_CODE_NO_FLICKER=0`, pins
  the session to the main screen, and the pane does not dock.
- The pane docks from 110 columns. Opened without being asked, it is placed
  from 144 columns; once opened by hand it is placed from 110.
- A changed setting or variable applies from a new session.

**Nothing happens outside an interactive session.** The first statement of the
`session.start` hook returns when the session is not interactive, and the next
returns when any of `CC_PIPELINE_SEGMENT`, `CC_PIPELINE_RUN_ID`,
`CC_PIPELINE_STAGE_ID`, `CC_PIPELINE_SHIFT_ID` or `CC_PIPELINE_REENTRY` is non-empty. Only after both does the module register the
command or start its clock, so a stage, a shift or a `-p` run gets no command,
no process and no pane.
