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
# ONE TOKEN CHOOSES THREE AXES. A caller passes a class token and a body; this
# file decides the title, the group and whether a sound plays. Handing the three
# separately opens exactly one typo per call site — a "손 필요" notice landing in
# the replace slot arrives with well-formed arguments and silently erases another
# summons, which is the same class of defect this seat exists to remove.
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

cc_caller_is_router() {
  # BOTH variables must be empty. The gate is called by the router and by a
  # stage, and only the router may decide that a banner reaches the user.
  #
  # THIS FUNCTION HAS AN OWNER FOR A REASON. Two existing checks in the gate each
  # read ONE of these variables, which is exactly the shape this replaces: a
  # copy that reads a single variable passes every test written against the
  # other one, and a stage call then raises a banner while the rest of the suite
  # stays green.
  #
  # The asymmetry sets the direction. Judging a stage to be the router breaks
  # the operating rule outright; judging the router to be a stage costs one
  # watcher period of delay.
  if [ -n "${CC_PIPELINE_SEGMENT:-}" ]; then return 1; fi
  if [ -n "${CC_PIPELINE_STAGE_ID:-}" ]; then return 1; fi
  return 0
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
  # THIS VOCABULARY IS AN INTERMEDIATE FORM. Five tokens share three strings, so
  # the two pairs that demand different actions — answer a question, versus go
  # and do something by hand — still arrive wearing the same title. Removing the
  # prefix makes titles reach the screen; it does not restore the distinction.
  # Rewriting the vocabulary so a title carries the action is separate work.
  case "$1" in
    answer)       printf '답 필요' ;;
    hands)        printf '손 필요' ;;
    status)       printf '자율 런' ;;
    status-hands) printf '손 필요' ;;
    overflow)     printf '답 필요' ;;
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
  local rid="${RUN_ID:-미상}"
  case "$1" in
    answer|hands) printf 'cc-cmds-autopilot-%s-%s' "$rid" "$2" ;;
    overflow)     printf 'cc-cmds-autopilot-%s-대기' "$rid" ;;
    *)            printf 'cc-cmds-autopilot-%s' "$rid" ;;
  esac
}

cc_notify_sound() {
  # ONLY THE STACKING BUCKETS MAKE A SOUND. A banner that waits for a person is
  # worth something to someone who is awake but away from the screen; a status
  # report is not, and re-firing into a replace slot is free — so a sound there
  # would repeat the same fact all night. This is the second reason the three
  # axes come from one token: passed separately, every call site opens a
  # combination where a status notice makes noise.
  case "$1" in
    answer|hands) printf 'default' ;;
  esac
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
  # The escaping is two parameter expansions rather than a `sed` call: this sits
  # on the critical path of every act and the expansions need no subshell.
  local s
  s=$(printf '%s' "${1:-}" | tr '\n\t' '  ')
  while :; do
    case "$s" in
      ' '*) s="${s#?}" ;;
      *) break ;;
    esac
  done
  s="${s:0:200}"
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
  # The token is one of five and the set is closed: an unrecognized one raises
  # nothing and says so. Falling back to the quietest token would be the
  # characteristic failure of a table like this — an unclassified condition
  # would reach the user as a status report, or not at all.
  local token="${1:-}" body="${2:-}" key="${3:-}" title group sound n
  case "$token" in
    answer|hands|status|status-hands|overflow) : ;;
    *)
      printf 'notify: 알 수 없는 부류 토큰 「%s」 — 배너를 올리지 않습니다\n' "$token" >&2
      return 0 ;;
  esac

  # Responsibility 5: the record goes down before anything is attempted, so a
  # failure past this point still leaves the run's banner state on disk.
  cc_notify_seat_state

  if ! cc_notify_enabled; then return 0; fi
  if [ "$(cc_notify_host_os)" != "Darwin" ]; then return 0; fi

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
  if [ -n "$sound" ]; then
    { terminal-notifier -title "$title" -message "$body" -group "$group" \
        -sound "$sound" -execute ':' >/dev/null 2>&1 & } 2>/dev/null || true
  else
    { terminal-notifier -title "$title" -message "$body" -group "$group" \
        -execute ':' >/dev/null 2>&1 & } 2>/dev/null || true
  fi
  return 0
}
