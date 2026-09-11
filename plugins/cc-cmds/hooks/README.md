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
`-execute ':'` on every banner this tree raises — a firing point that assembles
its own argv is how that argument was dropped once already.

**Both `hooks.json` entries pin `"timeout": 5`.** Both events block, and the
default is long, so an emitter that stalls for any reason would stall the session
with it. Nothing in the design depends on the number: the measured worst case for
a hook body is 84 ms synchronous and 23 ms detached, and a stubbed notifier
measured 62.6 ms — five seconds is two orders of magnitude of headroom either
way.

**Seat 1 is a sibling entry under `PreToolUse`, seat 2 opens a new top-level
`Stop` key.** The existing `Bash` entry is left alone and the matchers are not
merged into `"Bash|AskUserQuestion"`: merging would make the sibling hook's
`non-Bash matcher slip → noop` line a permanently active path instead of the
defence it is. Putting the `Stop` entry into the `PreToolUse` array instead of
its own key is a silent failure — the harness passes it over on a matcher miss
and seat 2 simply never runs.

## Switching the banners off

The session seats have their own switch, independent of the unattended pipeline's
`CC_CMDS_AUTOPILOT_NOTIFY`. Wanting one of the two kinds of banner without the
other is a real state and one variable cannot express it. The value grammar is
the same for both — `0`, `off`, `false` and `no` switch them off, case
insensitively, and an unrecognized value reads as ON.

- 「이 머신의 일반 세션 배너를 끄시려면 세션을 띄우기 전에 `CC_CMDS_SESSION_NOTIFY=0` 을 걸어 주세요 — `off`·`false`·`no` 도 대소문자 구분 없이 같게 읽습니다.」

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
