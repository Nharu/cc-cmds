#!/usr/bin/env bash
#
# notify-run.sh — the one place an autopilot banner's title, group and sound are
# chosen, sourced by BOTH the liveness watcher and the adjudication gate.
#
# WHY A SHARED FILE AND NOT A CONVENTION. Two processes raise banners for this
# pipeline, and they have to agree on the group string, because a group is a
# SLOT: the notifier replaces whatever occupies it. The last time two callers
# spelled a group differently, two concurrent runs erased each other's notices
# and the erased one's condition reached nobody at all. One file makes "they
# cannot disagree" structural instead of a habit two maintainers keep.
#
# ONE TOKEN CHOOSES TITLE AND GROUP; THE SOUND IS A CONSTANT. A caller passes a
# class token and a body; this file decides the title and the group, and every
# banner carries a sound. Handing title and group separately opens exactly one
# typo per call site — a "직접 손대세요" notice landing in the replace slot arrives
# with well-formed arguments and silently erases another summons, which is the
# same class of defect this seat exists to remove.
#
# THE SOUND STOPPED BEING AN AXIS once re-firing was counted across every status
# firing point: none of them repeats, because each is held by a once-marker or by
# a ledger row and speaks a single time. "Re-firing into a replace slot is free,
# so a sound there would repeat the same fact all night" was a precaution rather
# than an observation, and the count refuted it.
#
# FIVE RESPONSIBILITIES, each a measured failure if dropped:
#   1  never change the caller's exit status. The gate runs under an exit-on-
#      error shell option and a banner sits on the critical path of an act, so
#      every path here returns 0 AND every call site swallows. Either one alone
#      is not enough.
#   2  never write a byte to stdout. The gate's snapshot emits one JSON object
#      and that object is the router's entire declared input, so a single stray
#      line breaks it. Diagnostics go to stderr without exception.
#   3  never block. The notifier is launched detached and its status is not
#      asked — it was never an observable value, since a zero return says
#      nothing about whether anything appeared on a screen.
#   4  stay testable. The Homebrew PATH prepend is skippable and the host check
#      is seamed. Without both, a stub placed first on PATH is shadowed by the
#      real binary and no assertion about these arguments can stand.
#   5  record first, raise second. This seat has no delivery confirmation, so a
#      banner written before the report can end up the only trace of an event
#      nobody ever saw.
#
# Compatibility: bash 3.2 (macOS stock) — no associative arrays, no `mapfile`,
# no case-modification expansions.

# The kill switch, named once so the lint that compares this name against the
# kickoff's own prose has a single place to read it.
#
# NEITHER EXISTING FAMILY WOULD HAVE TOLD THE TRUTH. `CC_PIPELINE_*` is what the
# gate exports INTO a stage, so a name there would claim a scope this variable
# does not have; `CC_CMDS_NOTIFY_*` is the notification helper's family of test
# seams, and this is not one of those. A public variable a user is told to type
# has to say what it governs.
CC_NOTIFY_ENV_NAME=CC_CMDS_AUTOPILOT_NOTIFY

# The session seats' switch, named here for the same reason and read by
# `cc_notify_session_enabled` below.
#
# WHY A SECOND SWITCH AND NOT A SECOND MEANING FOR THE FIRST. Wanting the
# session banners while wanting an unattended run's banners silenced — or the
# reverse — is a real state, and one variable cannot express it.
#
# IT IS A SECOND SWITCH, NOT A SECOND GRAMMAR. The value vocabulary is the
# autopilot one exactly, because otherwise the way a user learned to switch one
# of these off would quietly not work on the other.
CC_NOTIFY_SESSION_ENV_NAME=CC_CMDS_SESSION_NOTIFY

# The stacking cap. Above it, individual notices collapse into one slot carrying
# a count — see `cc_notify_stack_admit`.
CC_NOTIFY_STACK_CAP=8

cc_notify_host_os() {
  # Seamed so the non-Darwin leg can still drive the Darwin branch. Without the
  # seam every banner assertion is unreachable there, and an unreachable path
  # that is skipped rather than run is how a platform-specific hole stays
  # invisible for as long as nobody is looking at the other platform.
  if [ -n "${CC_CMDS_NOTIFY_HOST_OS:-}" ]; then
    printf '%s' "$CC_CMDS_NOTIFY_HOST_OS"
    return 0
  fi
  uname -s 2>/dev/null || printf 'unknown'
}

cc_notify_warn_unrecognized() {
  # cc_notify_warn_unrecognized <value>
  #
  # ONCE PER RUN, ON STDERR. The gate is a new process for every act, so a
  # per-call warning becomes hundreds of lines overnight, interleaved with the
  # refusal text the router actually has to read. The once-guard is a file
  # because the two processes that could warn share no environment — an exported
  # variable does not survive from one gate invocation to the next.
  local m
  if [ -n "${RUN_DIR:-}" ] && [ -d "${RUN_DIR:-}" ]; then
    m="$RUN_DIR/notify.warned-killswitch"
    if [ -f "$m" ]; then
      return 0
    fi
    : > "$m" 2>/dev/null || true
  fi
  printf 'notify: %s 의 값 「%s」 을 알아보지 못했습니다 — 켜짐으로 읽습니다 (끄는 값: 0 off false no)\n' \
    "$CC_NOTIFY_ENV_NAME" "$1" >&2
  return 0
}

cc_notify_enabled() {
  # Default ON, and the off set is deliberately wide: someone who typed `false`
  # meant to turn it off, and there is no read that becomes dangerous by
  # honouring that. The original objection to a wide set — that two processes
  # would grow two grammars — died when this file became the only parser.
  #
  # A BRACKET ENUMERATION rather than a case-folding expansion or a `tr`
  # subshell. The folding forms need a newer interpreter than this repo's floor,
  # and a subshell here would run on every act of every run.
  #
  # An unrecognized value still reads as ON — but not silently, because a value
  # that was an honest attempt to switch this off would otherwise leave the user
  # believing the banners were stopped while they kept arriving.
  local v="${CC_CMDS_AUTOPILOT_NOTIFY:-}"
  case "$v" in
    '') return 0 ;;
    0|[Oo][Ff][Ff]|[Ff][Aa][Ll][Ss][Ee]|[Nn][Oo]) return 1 ;;
    1|[Oo][Nn]|[Tt][Rr][Uu][Ee]|[Yy][Ee][Ss]) return 0 ;;
  esac
  cc_notify_warn_unrecognized "$v"
  return 0
}

cc_notify_session_enabled() {
  # The session seats' half of the switch. Same value grammar as the function
  # above, deliberately — see `CC_NOTIFY_SESSION_ENV_NAME`.
  #
  # IT DOES NOT WARN ON AN UNRECOGNIZED VALUE, and that is a decision rather than
  # an omission. The warning goes to stderr, the session hooks may not put a byte
  # there, and the once-guard the autopilot warning uses is a marker file under
  # `RUN_DIR` — which a session has none of, so the guard would degenerate and
  # the warning would repeat on every firing.
  #
  # THE COST IS REAL AND REACHES THE USER: a typo here leaves the banners on
  # while the person believes they switched them off, and nothing says so. The
  # opposite polarity — reading an unrecognized value as OFF — was rejected
  # because then a typo silently removes the banners instead, which is the worse
  # of the two silences and also splits the grammar the line above keeps whole.
  local v="${CC_CMDS_SESSION_NOTIFY:-}"
  case "$v" in
    '') return 0 ;;
    0|[Oo][Ff][Ff]|[Ff][Aa][Ll][Ss][Ee]|[Nn][Oo]) return 1 ;;
    1|[Oo][Nn]|[Tt][Rr][Uu][Ee]|[Yy][Ee][Ss]) return 0 ;;
  esac
  return 0
}

cc_notify_scope_enabled() {
  # cc_notify_scope_enabled <token> — send a token to its own scope's switch.
  #
  # THE DISPATCH IS A NEW FUNCTION AND NOT AN ARGUMENT ON `cc_notify_enabled`.
  # Three call sites reach that one with no argument, so an added parameter would
  # leave whichever site was missed running on the default — the autopilot switch
  # — while every test stayed green. A separate verb cannot be half-adopted: a
  # site either calls it or does not.
  #
  # WITHOUT THIS THE AUTOPILOT SWITCH IS THE MASTER OF THE SESSION BANNERS.
  # Measured: with the session tokens added but the firing gate still calling
  # `cc_notify_enabled`, `CC_CMDS_AUTOPILOT_NOTIFY=0` and `=off` each stopped a
  # session firing. That makes the one combination the second switch exists for
  # — silence the unattended run, keep the session banners — inexpressible.
  #
  # IT ALSO KEEPS THE SESSION PATH AWAY FROM `cc_notify_warn_unrecognized`. That
  # warning's once-guard marker lives under `RUN_DIR`, which a session has none
  # of, so a typo in the AUTOPILOT switch would otherwise put bytes on the
  # session hook's stderr on every single firing — and the seat contract forbids
  # the hooks any stderr at all.
  case "$1" in
    session-ask|session-turn) cc_notify_session_enabled ;;
    *)                        cc_notify_enabled ;;
  esac
}

cc_caller_is_router() {
  # ALL THREE variables must be empty. The gate is called by the router, by a
  # launched STAGE and by a routing SHARD, and only the router may decide that a
  # banner reaches the user.
  #
  # THIS FUNCTION HAS AN OWNER FOR A REASON. Two existing checks in the gate each
  # read ONE of these variables, which is exactly the shape this replaces: a
  # copy that reads a single variable passes every test written against the
  # other one, and a stage call then raises a banner while the rest of the suite
  # stays green.
  #
  # THE SHARD'S MARKER IS OWNED HERE TOO, and it arrived late in a way that
  # proves the paragraph above rather than repeating it. It was added to the
  # gate's own wrapper instead of to this predicate, and a wrapper covers only
  # the direction that goes through it: firing does, while clearing calls this
  # predicate directly. So a shard was refused a banner and was still allowed to
  # take one down — the seat question answered two different ways in two files.
  # A fourth marker added to one file and not the other splits them again, which
  # is why all three live here and the gate holds none.
  #
  # The asymmetry sets the direction. Judging a stage to be the router breaks
  # the operating rule outright; judging the router to be a stage costs one
  # watcher period of delay.
  if [ -n "${CC_PIPELINE_SEGMENT:-}" ]; then return 1; fi
  if [ -n "${CC_PIPELINE_STAGE_ID:-}" ]; then return 1; fi
  if [ -n "${CC_PIPELINE_SHIFT_ID:-}" ]; then return 1; fi
  return 0
}

cc_caller_is_stage() {
  # A STAGE, and only a stage. `cc_caller_is_router` answers the banner question
  # — may a banner reach the user — and refuses a routing shard along with a
  # stage. The judgment predicate in the gate asks a different question: is
  # this call the ROUTER judging? A shard IS the router, so its marker is
  # deliberately not read here; either of the two markers the stage launcher
  # exports names a stage.
  #
  # OWNED HERE for the reason the predicate above gives: a copy that reads one
  # variable passes every test written against the other one. The gate's own
  # comment says the marker reads belong to this file, not to it.
  if [ -n "${CC_PIPELINE_SEGMENT:-}" ]; then return 0; fi
  if [ -n "${CC_PIPELINE_STAGE_ID:-}" ]; then return 0; fi
  return 1
}

cc_notify_title() {
  # NO TITLE MAY BEGIN WITH ONE OF SIX CHARACTERS — `[ ( { < " -`. The notifier's
  # argument parser swallows such a value whole: the banner still appears, but
  # with the application's own name where the title was. Every arm here used to
  # carry a `[cc-cmds] ` prefix, so EVERY banner this system has ever raised
  # arrived with no title at all and the distinction these tokens draw has never
  # once reached a screen. Closing brackets pass. A leading space is no shield
  # for five of the six — the value parser strips whitespace before it judges —
  # while `-` is swallowed for the other reason, that the word looks like an
  # option, so a space in front does save that one.
  #
  # There is no way to change the application name (`-sender` and `-appIcon` are
  # discontinued), so the title is the only marker of where a notice came from,
  # and it was the one thing being dropped.
  #
  # THE TITLE CARRIES THE ACTION. The previous vocabulary had five tokens sharing
  # three strings, so the pairs that demand different actions — answer a question,
  # versus go and do something by hand, versus open a fresh run — arrived wearing
  # the same words once the prefix was removed. Nine tokens is not the cost it
  # looks like: a call site's typo surface is "picked the wrong token" whatever
  # the count, and the real protection is the closed set below plus the refusal of
  # an unknown token. Collapsing them is what would hurt — three different
  # instructions under one title is a banner that cannot say what to do.
  #
  # `cc-cmds` STAYS IN FRONT because the application name is permanently
  # `Terminal`, so the title is the only marker of origin, and a value starting
  # with `c` was measured safe against the swallowing set above.
  case "$1" in
    answer)     printf 'cc-cmds · 답하세요' ;;
    answer-run) printf 'cc-cmds · 답하세요' ;;
    overflow)   printf 'cc-cmds · 답할 것이 더 있습니다' ;;
    hands)      printf 'cc-cmds · 직접 손대세요' ;;
    resume)     printf 'cc-cmds · 세션으로 돌아가세요' ;;
    rekick)     printf 'cc-cmds · 새 런을 여세요' ;;
    ended)      printf 'cc-cmds · 결과를 확인하세요' ;;
    session-ask)  printf 'cc-cmds · 답하세요' ;;
    session-turn) printf 'cc-cmds · 차례가 넘어왔습니다' ;;
  esac
}

cc_notify_group() {
  # cc_notify_group <token> <item-key>
  #
  # THE RUN ID COMES FIRST, ALWAYS. An approval id already hashes the run id and
  # is therefore run-unique, but a segment id is not — two concurrent runs each
  # parking `S1` would write the same key and erase each other's summons. That
  # is the measured regression which made this group per-run in the first place,
  # revived in the very channel that was added to prevent it.
  # THE RUN SLOT IS SHARED BY THE LIFECYCLE THREE AND BY NOBODY ELSE. `resume`,
  # `rekick` and `ended` are mutually exclusive states of one run — it cannot be
  # both waiting for a session and finished — so one slot is right and the later
  # notice erasing the earlier one is the correct behaviour. `answer-run` is NOT
  # in that set: a run can hold open approvals at the same time as any of the
  # three, so sharing would let "세션으로 돌아가세요" erase "답하세요" or the other
  # way round, and the person would be told whichever arrived last regardless of
  # what is actually outstanding. It gets its own suffix instead, which keeps
  # per-run replacement intact without the collision.
  #
  # The suffix must not collide with the overflow one, so it is `답` and not
  # `대기`.
  #
  # THE SESSION ARM EXISTS BECAUSE THE DEFAULT ARM IS A TRAP. `*)` catches
  # anything unlisted, so leaving the session tokens out does not fail — it
  # collapses them onto `cc-cmds-autopilot-<rid>`, and with no run in scope that
  # is the literal `cc-cmds-autopilot-미상`, which is the slot `resume`, `rekick`
  # and `ended` already write to. The title would be right, the status zero and
  # nothing would warn. That is why the tokens carry a `session-` prefix instead
  # of being bare `ask` and `turn`, and why the test asserts the ABSENCE of the
  # autopilot prefix rather than an equality — a collapse produces a well-formed
  # value, so only a negative assertion catches it.
  #
  # THE SESSION ID COMES FROM THE ENVIRONMENT AND NOT FROM `$2`. This arm ignores
  # the item key on purpose: one slot per session is the whole of the session
  # decision, and an arm that cannot read a key is an arm no call site can split
  # the slot with. Taking the id as an argument turns that structural guarantee
  # back into a promise written in prose.
  #
  # THE NAME IS `CC_NOTIFY_*` AND NOT `CC_CMDS_*` DELIBERATELY. The latter family
  # is the set of switches a user types, and the lint that guards those names
  # reads exactly that prefix; this value is an internal hand-off nobody types,
  # so registering it there would be a false entry rather than an honest one.
  #
  # An empty id is NOT defaulted here. Every session would then share one slot
  # and erase each other's banners, with a prefix correct enough to pass the
  # negative assertion above — so the hook refuses to fire before it reaches
  # this function, which is the only place that failure can be caught.
  local rid="${RUN_ID:-미상}"
  local sid="${CC_NOTIFY_SESSION_ID:-}"
  case "$1" in
    answer|hands) printf 'cc-cmds-autopilot-%s-%s' "$rid" "$2" ;;
    answer-run)   printf 'cc-cmds-autopilot-%s-답' "$rid" ;;
    overflow)     printf 'cc-cmds-autopilot-%s-대기' "$rid" ;;
    session-ask|session-turn) printf 'cc-cmds-session-%s' "$sid" ;;
    *)            printf 'cc-cmds-autopilot-%s' "$rid" ;;
  esac
}

cc_notify_sound() {
  # EVERY BANNER MAKES A SOUND. The token is taken and ignored: this is a
  # constant, and it stays a function so the one place that names it is still one
  # place — a caller reading a literal out of this file would be the drift the
  # shared emitter exists to prevent.
  #
  # WHY IT IS NO LONGER AN AXIS. The old split gave sound only to the stacking
  # buckets, on the ground that re-firing into a replace slot is free and a sound
  # there would repeat the same fact all night. Counting every status firing point
  # refuted it: all of them are held by a once-marker or by a ledger row and speak
  # exactly once, including the stall arm, whose window closes because the gate
  # empties the stall file only after transcribing it.
  #
  # THE CONSTANT MAY NOT SHIP WITHOUT SLOT RECLAMATION, and that ordering is why
  # this line is safe to write today: without reclamation the cap is a lifetime
  # rather than a concurrency, and the overflow body would count items answered
  # hours ago — a sound announcing a wait that is not happening. Reclamation
  # landed first.
  printf 'default'
}

cc_notify_body() {
  # Strings pulled from the ledger — a stall reason, a boundary approval's
  # question — are generated sentences and can be long, so they are cut.
  #
  # THE SWALLOWING SET IS SIX CHARACTERS — `[ ( { < " -` — AND STRIPPING IS THE
  # WRONG CURE. A value beginning with any of them is dropped by the notifier's
  # argument parser. The previous form stripped a leading `[` and stated the rule
  # as "must not begin with a bracket", which is half of the truth; that same
  # asymmetry is why the title carried a bracketed prefix for as long as it did.
  #
  # Widening the strip to all six would trade a lost body for a distorted one:
  # `-p 를 빠뜨렸습니다` loses its subject the moment the `-` goes. The body is the
  # only channel a caller's specifics travel on — a stage's halt question, a
  # stall reason — so it is QUOTED instead, losslessly: escape the inner `\` and
  # `"`, then wrap both ends in `"`.
  #
  # Leading WHITESPACE is still dropped: it carries no meaning, and for five of
  # the six the parser strips it before judging anyway. Dropping it loses nothing
  # on the sixth either — a leading space is the one thing that saves a `-`, and
  # once the space is gone the value is quoted like any other, so the set that
  # survives is the same either way.
  #
  # THE CUT COMES BEFORE THE QUOTING. Cutting afterwards would take the closing
  # quote off the end and hand the parser an unterminated string.
  #
  # Bash substring expansion rather than `cut -c` or an `awk` substr: those two
  # differ across the BSD and GNU builds this repo runs on, and the exact
  # boundary is not a property anything asserts — what matters is that the value
  # is bounded and survives the parser intact.
  #
  # THE CUT'S UNIT WAS THE CALLER'S LOCALE, AND THAT IS THE DEFECT BEING FIXED.
  # `${s:0:200}` counts characters under a UTF-8 locale and bytes under
  # `LC_ALL=C`, and the second one lands inside a multi-byte sequence. Measured
  # on this file before the pin below: 66 Korean characters came out at 198 bytes
  # and valid, and 67, 120 and 200 all came out at 200 bytes and INVALID UTF-8,
  # while the same inputs under `ko_KR.UTF-8` were valid at 198, 201, 360 and 600
  # bytes. So the old form was neither bounded in bytes nor safe — it was one or
  # the other depending on who called it. This is not a defence against an
  # imagined environment: 120 characters is a length already observed in a real
  # payload, and this repo's own CI has a leg with no locale set.
  #
  # PINNING TO `C` MAKES THE UNIT THE SAME EVERYWHERE and the trim below is what
  # makes the result valid. The pin is a local, so it is undone on return and no
  # caller's locale is disturbed.
  #
  # The escaping is two parameter expansions rather than a `sed` call: this sits
  # on the critical path of every act and the expansions need no subshell.
  local s
  local LC_ALL=C
  s=$(printf '%s' "${1:-}" | tr '\n\t' '  ')
  while :; do
    case "$s" in
      ' '*) s="${s#?}" ;;
      *) break ;;
    esac
  done
  s="${s:0:200}"
  # DROP A TRAILING PARTIAL UTF-8 SEQUENCE. A lead byte announces how many
  # continuation bytes follow it, and a byte cut can land inside that run. The
  # three arms are the only shapes a cut can leave behind — a lead byte with
  # nothing after it, a three- or four-byte lead holding one continuation, and a
  # four-byte lead holding two. Every other tail the cut can produce was already
  # a whole character.
  #
  # BYTE RANGES RATHER THAN CHARACTER CLASSES, which is what the `C` above buys:
  # under it a bracket range is a range of byte values and means the same thing
  # on every host. The patterns are held in variables because a `case` pattern is
  # expanded before it is matched, so this is the way to write a byte range once
  # and use it in three arms.
  local u_lead=$'[\xC0-\xF7]' u_lead34=$'[\xE0-\xF7]' u_lead4=$'[\xF0-\xF7]'
  local u_cont=$'[\x80-\xBF]'
  case "$s" in
    *$u_lead)                s="${s%?}" ;;
    *$u_lead34$u_cont)       s="${s%??}" ;;
    *$u_lead4$u_cont$u_cont) s="${s%???}" ;;
  esac
  case "$s" in
    '['*|'('*|'{'*|'<'*|'"'*|'-'*)
      s="${s//\\/\\\\}"
      s="${s//\"/\\\"}"
      s="\"${s}\""
      ;;
  esac
  printf '%s' "$s"
}

cc_notify_stack_admit() {
  # cc_notify_stack_admit <item-key> — 0 to keep its own slot, 1 to overflow.
  #
  # THE CAP IS ON THE STACKING BUCKET ALONE. The replace bucket re-fires into one
  # slot, so its volume never grows however often it is raised; only the stacking
  # side can pile up, and only it needs a bound.
  #
  # A key that already holds a slot is re-admitted rather than counted twice: it
  # is the same item being raised again, and the group is what makes that a
  # replacement rather than a duplicate.
  local key="$1" f o n
  if [ -z "${RUN_DIR:-}" ] || [ ! -d "${RUN_DIR:-}" ]; then
    return 0
  fi
  f="$RUN_DIR/notify.stack"
  o="$RUN_DIR/notify.overflow"
  # No `-f` guard before the membership test: `grep` against a file that is not
  # there already answers "not a member", and the extra test would only add an
  # `||` right in front of a `grep -q` — the shape the early-exit scanner reads.
  if grep -qxF "$key" "$f" 2>/dev/null; then
    return 0
  fi
  n=$(grep -c . "$f" 2>/dev/null || true)
  if [ "${n:-0}" -lt "$CC_NOTIFY_STACK_CAP" ]; then
    printf '%s\n' "$key" >> "$f" 2>/dev/null || true
    return 0
  fi
  if ! grep -qxF "$key" "$o" 2>/dev/null; then
    printf '%s\n' "$key" >> "$o" 2>/dev/null || true
  fi
  return 1
}

cc_notify_stack_release() {
  # cc_notify_stack_release <item-key>
  #
  # WITHOUT THIS THE CAP IS A LIFETIME RATHER THAN A CONCURRENCY. Nothing in the
  # run removed a line from the stack file, so the eight individual slots were
  # spent over the whole night instead of being held by the eight items actually
  # waiting — and the ninth arrival collapsed into the overflow slot while eight
  # keys answered hours earlier still occupied their seats.
  #
  # WHY NO CALLER GUARD HERE, WHEN CLEARING A BANNER WOULD NEED ONE. The
  # discriminator is whether the act itself calls the notifier at that moment.
  # This one erases a line in a file and calls nothing: it can neither raise a
  # banner nor suppress one, because a shorter stack moves admission only TOWARD
  # the individual slot. It is idempotent, it converges, and the decision to fire
  # stays exactly where it already is — at the call sites the router guard
  # covers. Clearing a banner is the opposite: it changes what is on a person's
  # screen right now, so the guard is a genuine precondition there.
  #
  # Putting the same guard on a site that delivers nothing would cost more than
  # the two lines it saves. Every guarded site today shares one property — it
  # hands an event to a person — and a guard on a site that hands over nothing
  # kills that property as a MARKER. Whoever comes next could no longer tell the
  # two kinds apart by whether a guard is present, and a banner clear added later
  # without one would not stand out.
  local key="$1" f t
  if [ -z "${RUN_DIR:-}" ] || [ ! -d "${RUN_DIR:-}" ]; then
    return 0
  fi
  f="$RUN_DIR/notify.stack"
  [ -f "$f" ] || return 0
  # Same directory, so the rename stays inside one filesystem and is atomic.
  t="$f.$$"
  # `grep -v` exits 1 when it filters everything away, and an empty stack is a
  # normal state rather than a failure — so the status is swallowed and the
  # emptiness is written through. Responsibility 1: every path returns 0.
  { grep -vxF "$key" "$f" || true; } > "$t" 2>/dev/null \
    || { rm -f "$t" 2>/dev/null || true; return 0; }
  mv "$t" "$f" 2>/dev/null || rm -f "$t" 2>/dev/null || true
  return 0
}

cc_notify_overflow_count() {
  local o n
  o="${RUN_DIR:-}/notify.overflow"
  n=$(grep -c . "$o" 2>/dev/null || true)
  printf '%s' "${n:-0}"
}

cc_notify_seat_state() {
  # THE DURABLE HALF, and the reason it is a file rather than a direct append.
  #
  # Days later, a person reading the report cannot tell "nothing happened" from
  # "the banners were switched off" — the kickoff says the resolved state out
  # loud, and that utterance scrolls away with the session. So the emitter
  # records its own active state once per run, where the morning already looks.
  #
  # BOTH SEATS WRITE HERE AND NEITHER APPENDS TO THE REPORT. The prose line
  # itself is invisible to the ledger's hash chain, which hashes only rows — but
  # that is not the reason for the indirection. The gate takes a lock for its
  # writes and the watcher takes none, so two unlocked appends to one file
  # interleave, and what breaks is the ledger ROW beside the prose. The gate
  # transcribes this file on its next call, exactly as the watcher's stall
  # observations already travel.
  local f state
  if [ -z "${RUN_DIR:-}" ] || [ ! -d "${RUN_DIR:-}" ]; then
    return 0
  fi
  # THE KILL SWITCH IS READ BEFORE THE ONCE-GUARD BELOW, and the order is the
  # whole point. The near-miss warning carries its own marker, so making it wait
  # behind this file's existence silences it on every run that had already raised
  # one banner — and a value typed to switch the banners off, on a run where one
  # has already gone out, is precisely the case that warning exists for.
  if cc_notify_enabled; then state='켬'; else state='끔'; fi
  f="$RUN_DIR/notify.state"
  if [ -f "$f" ]; then
    return 0
  fi
  printf '배너 %s (%s)\n' "$state" "$CC_NOTIFY_ENV_NAME" > "$f" 2>/dev/null || true
  return 0
}

cc_notify_fire() {
  # cc_notify_fire <token> <message> [item-key]
  #
  # The token is one of nine and the set is closed: an unrecognized one raises
  # nothing and says so. Falling back to the quietest token would be the
  # characteristic failure of a table like this — an unclassified condition
  # would reach the user as a status report, or not at all.
  local token="${1:-}" body="${2:-}" key="${3:-}" title group sound n
  case "$token" in
    answer|answer-run|overflow|hands|resume|rekick|ended) : ;;
    session-ask|session-turn) : ;;
    *)
      printf 'notify: 알 수 없는 부류 토큰 「%s」 — 배너를 올리지 않습니다\n' "$token" >&2
      return 0 ;;
  esac

  # Responsibility 5: the record goes down before anything is attempted, so a
  # failure past this point still leaves the run's banner state on disk.
  #
  # THIS IS THE ONLY L3 FUNCTION A SESSION SEAT REACHES, and it is harmless
  # there: with no `RUN_DIR` it returns before it consults a switch or writes a
  # byte. `cc_notify_stack_admit` is harmless for a different reason — the arm
  # that calls it is `answer|hands`, and the session tokens are deliberately not
  # in it. Recording those two as one fact would say the session tokens pass
  # through that arm, which is the arrangement this file forbids just below.
  cc_notify_seat_state

  # THE SWITCH IS CHOSEN BY THE TOKEN, and this call sits ABOVE the overflow
  # demotion below, so `$token` here is still the one the caller passed.
  if ! cc_notify_scope_enabled "$token"; then return 0; fi
  if [ "$(cc_notify_host_os)" != "Darwin" ]; then return 0; fi

  # ONLY THE STACKING TOKENS ARE ADMITTED AGAINST THE CAP. `answer-run` says the
  # whole run is waiting and occupies a per-run replace slot, so counting it
  # against the eight individual seats would let one run-level banner eat a seat
  # an individually identified approval needs.
  #
  # THE SESSION TOKENS ARE DELIBERATELY OUTSIDE THIS ARM. Putting them in passes
  # today — `cc_notify_stack_admit` returns before it touches anything when there
  # is no `RUN_DIR`, measured as `fire rc=0` with zero files created — and that
  # is the reason to keep them out rather than a reason to relax. The right
  # outcome would be coming from a fallback that exists for a different purpose
  # entirely, so an implementer who tries it, sees nothing happen and drops the
  # constraint would be reading a coincidence as a guarantee.
  case "$token" in
    answer|hands)
      if [ -z "$key" ]; then key="$token"; fi
      if ! cc_notify_stack_admit "$key"; then
        n=$(cc_notify_overflow_count)
        token=overflow
        body="답을 기다리는 항목이 ${n}건 더 있습니다 — 빠짐없는 목록은 아침 보고서에 있습니다"
      fi
      ;;
  esac

  title=$(cc_notify_title "$token")
  group=$(cc_notify_group "$token" "$key")
  sound=$(cc_notify_sound "$token")
  body=$(cc_notify_body "$body")

  # Responsibility 4. The prepend is what makes this path untestable otherwise:
  # a stub placed first on PATH is shadowed by whatever is really installed in
  # the Homebrew directories, so no assertion about these arguments could stand.
  if [ -z "${CC_CMDS_NOTIFY_PATH_DISABLE_PREPEND:-}" ]; then
    PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
  fi
  if ! command -v terminal-notifier >/dev/null 2>&1; then
    return 0
  fi

  # THE CLICK IS NEUTRALIZED AT EVERY CALL SITE. Without it, clicking the notice
  # pulls focus to whatever the notifier decides to activate — behaviour this
  # tree has already fixed once, and a new firing point that omits the argument
  # brings it straight back.
  #
  # Responsibility 3: launched detached, status never asked.
  #
  # ONE ARM, NOT TWO. The pair used to be split on whether a sound was chosen;
  # the sound is a constant now, so the silent arm was unreachable code that read
  # like a live branch.
  { terminal-notifier -title "$title" -message "$body" -group "$group" \
      -sound "$sound" -execute ':' >/dev/null 2>&1 & } 2>/dev/null || true
  return 0
}

cc_notify_clear() {
  # cc_notify_clear <token> [item-key]
  #
  # Take a banner off the screen by addressing its group. A group is a SLOT and
  # also an ADDRESS: without one a notice can never be removed, counted or
  # queried, so in the morning an approval that was answered and one that was not
  # look identical. Keys landed first because a banner that already went out
  # without one is unaddressable forever; removal is the half that could wait, and
  # this is it arriving.
  #
  # THE SEAT GUARD IS INSIDE THIS VERB, NOT AT ITS CALL SITES. Every firing point
  # in the gate carries its own copy of the guard, and that copy is exactly the
  # shape the shared emitter was created to end — a guard that does not inherit is
  # a guard one new call site can be written without. Clearing changes what is on
  # a person's screen right now, which is the property the guard is a genuine
  # precondition for, so it lives where it cannot be forgotten.
  #
  # THE CONTRAST WITH RECLAIMING A SLOT IS THE POINT, and it is the reason
  # `cc_notify_stack_release` deliberately carries no guard: that one erases a
  # line in a file and calls nothing, so it can neither raise a banner nor
  # suppress one. Guarded sites all share the property of handing an event to a
  # person; putting a guard on one that hands over nothing would kill that
  # property as a marker, and then a clear added later without a guard would not
  # stand out.
  #
  # Same four gates as firing — kill switch, host, PATH prepend, exit status
  # untouched — because this reaches the same binary and sits on the same
  # critical path.
  local token="${1:-}" key="${2:-}" group
  case "$token" in
    answer|answer-run|overflow|hands|resume|rekick|ended) : ;;
    session-ask|session-turn) : ;;
    *)
      printf 'notify: 알 수 없는 부류 토큰 「%s」 — 배너를 지우지 않습니다\n' "$token" >&2
      return 0 ;;
  esac
  if ! cc_caller_is_router; then return 0; fi
  if ! cc_notify_scope_enabled "$token"; then return 0; fi
  if [ "$(cc_notify_host_os)" != "Darwin" ]; then return 0; fi

  if [ -z "$key" ]; then key="$token"; fi
  group=$(cc_notify_group "$token" "$key")

  if [ -z "${CC_CMDS_NOTIFY_PATH_DISABLE_PREPEND:-}" ]; then
    PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
  fi
  if ! command -v terminal-notifier >/dev/null 2>&1; then
    return 0
  fi
  { terminal-notifier -remove "$group" >/dev/null 2>&1 & } 2>/dev/null || true
  return 0
}
