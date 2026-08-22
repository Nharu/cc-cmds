#!/usr/bin/env bash
# Autonomous pipeline driver.
#
# Owns the stage state machine so that the resource that runs out (the model
# budget) is not also the resource that has to notice it ran out and retry. A
# shell loop's control flow costs zero tokens, so it survives an exhausted
# model budget and can back off, wait, and re-dispatch. A model-owned loop
# cannot: its self-resume path is the very thing that is unavailable.
#
# Contracts this file consumes read-only:
#   plugins/cc-cmds/skills/_common/pipeline-sidecar.md   grant/ledger/halt schemas,
#                                                        the closed row series,
#                                                        artifact predicates,
#                                                        the four termination classes
#   plugins/cc-cmds/skills/_common/sidecar.md  §1         path/slug derivation,
#                                                        provenance guard, atomic write
#   plugins/cc-cmds/skills/_common/verification.md §6     two-command boundary gate
#
# Two rules govern everything below:
#
#   1. The driver's input from a stage is exactly two things — that the process
#      ended, and what it left on disk. Stage prose is NEVER parsed for control
#      flow. Not the report body, not the Korean summary, not the next-step line.
#   2. The driver writes the run ledger; nothing else does. Stages emit
#      structured output and halt records; the driver transcribes.
#
# Usage:
#   run.sh --doc <abs-path> [--run-id <id>] [--detach]
#   run.sh --self-check
#
# Exit codes:
#   0 — run reached DONE, or --self-check passed
#   1 — hard stop (foreign grant, unreadable contract state)
#   2 — invalid invocation
#   3 — interpreter floor not met

# ---------------------------------------------------------------------------
# Interpreter floor. This block is deliberately the first executable code and
# is written in bash-3.2 syntax, because its whole job is to evaluate correctly
# on the interpreter it may have to reject. `#!/usr/bin/env bash` resolves to
# 5.x on an interactive PATH and to macOS's stock 3.2.57 under a sanitized one,
# so the floor is 3.2 and every construct below stays inside it: no `wait -n`,
# no `declare -A`, no `mapfile`, no `${x^^}`.
# ---------------------------------------------------------------------------
if [ -z "${BASH_VERSINFO+set}" ]; then
  echo "run.sh: requires bash (BASH_VERSINFO unset — not a bash interpreter)" >&2
  exit 3
fi
if [ "${BASH_VERSINFO[0]}" -lt 3 ] || { [ "${BASH_VERSINFO[0]}" -eq 3 ] && [ "${BASH_VERSINFO[1]}" -lt 2 ]; }; then
  echo "run.sh: requires bash >= 3.2, found ${BASH_VERSION}" >&2
  exit 3
fi

# The CLI binary is resolved from the INHERITED PATH, before normalization —
# it does not live in a system directory. `cc` and `claude` are shell functions
# in the user's interactive rc, so a non-interactive `bash -c claude` resolves
# to something else entirely (`cc` resolves to the C compiler); the driver must
# hold an absolute path and call it directly.
CLI_BIN="${CC_CLAUDE_BIN:-}"
if [ -z "$CLI_BIN" ]; then
  CLI_BIN=$(command -v claude 2>/dev/null || true)
fi

# Normalize PATH so every utility below resolves the same way whether the run
# was started from an interactive shell or from a detached one. /sbin and
# /usr/sbin are included because `sysctl` — the sleep discriminator's only
# input — lives there.
PATH="/usr/bin:/bin:/usr/sbin:/sbin"
export PATH

set -euo pipefail

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
readonly STAGE_IDS="S0 S1 S2 S3 S4 S5 S6 S7 S8 S9"
readonly HOLLOW_SUCCESS_RETRIES=1        # one retry, then a distinct park reason
readonly CRASH_RETRIES=3
readonly BACKOFF_START_SECONDS=60
readonly BACKOFF_FACTOR=2
readonly BACKOFF_MAX_SLEEP_SECONDS=1800  # per-sleep ceiling
# The wall-clock cap on the whole backoff ladder. The design's residual item on
# limit-exhaustion envelope shape was waived unverified, and its stated failure
# impact is that an envelope-less stall makes an unbounded backoff mandatory to
# bound. Adopting the cap up front covers both branches of that item, so the
# ladder terminates whichever way the envelope turns out to behave.
readonly BACKOFF_WALLCLOCK_CAP_SECONDS=21600   # 6h, then park
readonly WORKTREE_INFIX="-run-"          # reserved; also the boundary gate's exception pattern
readonly LOCK_BUSY_EXIT=75               # EX_TEMPFAIL from lockf -t 0

# Terminal literals. These are fixed bytes inside skill text, which is what
# makes them safe as wire format — unlike the next-step lines those skills also
# emit, which are model-authored prose.
readonly LIT_DESIGN_FREEZE='설계 문서를 동결했습니다. 이후 이 세션에서는 문서를 수정하지 않습니다.'
readonly LIT_AUDIT_TERMINAL='이 명령은 여기서 종료합니다. 추가 리뷰 라운드는 없습니다.'
readonly LIT_RECONVERGE_TERMINAL='재수렴을 종료합니다. 판정은 여기까지이며 추가 패스는 없습니다.'

# ---------------------------------------------------------------------------
# Logging. Redirection is not about survival — a driver without it survives a
# hangup and then goes blind, because every write to the revoked tty fails. On
# a recovery model built on log evidence that is worse than dying.
# ---------------------------------------------------------------------------
LOG_FILE=""

log()  { printf '%s [run] %s\n' "$(now_iso)" "$*" >&2; }
warn() { printf '%s [run][warn] %s\n' "$(now_iso)" "$*" >&2; }
die()  { printf '%s [run][stop] %s\n' "$(now_iso)" "$*" >&2; exit 1; }

now_iso()  { date -u +%Y-%m-%dT%H:%M:%SZ; }
now_epoch() { date -u +%s; }

# ---------------------------------------------------------------------------
# Path and slug derivation (sidecar.md §1.1), keyed on the DOCUMENT's own
# location and never on the cwd.
# ---------------------------------------------------------------------------
DOC=""; DOC_DIR=""; DOC_KEY=""; SLUG=""; BASE=""; RUN_ID=""; RUN_DIR=""
LEDGER=""; GRANT=""; REPORT=""

derive_paths() {
  DOC_DIR=$(cd "$(dirname "$DOC")" && pwd)
  local top
  top=$(cd "$DOC_DIR" && git rev-parse --show-toplevel 2>/dev/null || true)
  if [ -n "$top" ] && [ "${DOC_DIR#"$top"}" != "$DOC_DIR" ]; then
    # Branch A. The document key keeps the per-worktree root; <base> is the
    # repository's MAIN worktree root, so every linked worktree of one repo
    # resolves to one sidecar location instead of N.
    DOC_KEY="${DOC#"$top"/}"
    BASE=$(dirname "$(cd "$DOC_DIR" && git rev-parse --path-format=absolute --git-common-dir)")
  else
    # Branch B. No repository resolves; nothing to collapse.
    DOC_KEY="${DOC#/}"
    BASE="$DOC_DIR"
  fi
  SLUG=$(printf '%s' "${DOC_KEY%.md}" | tr '/' '-')
  GRANT="$BASE/docs/pipeline-grant/$SLUG.md"
  LEDGER="$BASE/docs/pipeline-run/$SLUG.md"
}

# ---------------------------------------------------------------------------
# Document digests. "The design document is byte-invariant" is FALSE — two
# places legitimately change it: the audit's reconciliation pass, and the
# implementation arm's two reserved write forms. So there are two digests.
#
#   whole    — what the audit hashes into its own freeze window. Not ours.
#   binding  — the surface a segment plan was derived from, computed with the
#              verification-grade and verification-record lines filtered out.
#              Invariant to the implementation arm's writes BY CONSTRUCTION.
#
# Two properties of the filter are load-bearing. It is SECTION-SCOPED, not
# file-wide: a `검증 등급:` string elsewhere in the document is ordinary prose
# and dropping it would make the digest blind to a real edit. And it is
# TOLERANT of every legacy rendering — bullet or not, bold or not — because a
# filter strict on only the canonical form misses a legacy line at exactly the
# flip it exists to hide, and the digest then moves for the one reason it must
# not.
#
# What this digest does NOT promise: invariance from kickoff to merge. The
# audit's reconciliation edits are not filtered out, so they DO move it — and
# that is the intent, because those edits invalidate the plan.
# ---------------------------------------------------------------------------
binding_digest() {
  awk '
    /^## / { insec = ($0 ~ /^## 구현 시 검증 항목[[:space:]]*$/) ? 1 : 0 }
    insec && /^(- )?(\*\*검증 등급\*\*|검증 등급): / { next }
    insec && /^(- )?(\*\*구현 시 검증 기록\*\*|구현 시 검증 기록): / { next }
    { print }
  ' "$DOC" | shasum -a 256 | cut -d' ' -f1
}

whole_digest() { shasum -a 256 "$DOC" | cut -d' ' -f1; }

# ---------------------------------------------------------------------------
# Grant. The driver is READ-ONLY here, by construction and not by discipline:
# an all-night process with no write path to its own authorization cannot widen
# it however it fails.
# ---------------------------------------------------------------------------
grant_field() {
  # $1 = run-id block, $2 = field name. Reads the CANON rendering.
  awk -v want="## 인가 $1" -v key="$2" '
    $0 == want { inblock=1; next }
    inblock && /^## / { exit }
    inblock {
      pat = "^\\*\\*" key "\\*\\*: "
      if ($0 ~ pat) { sub(pat, "", $0); print; exit }
    }
  ' "$GRANT"
}

grant_blocks() { grep -E '^## 인가 ' "$GRANT" 2>/dev/null | sed -E 's/^## 인가 //' || true; }

check_grant() {
  [ -f "$GRANT" ] || die "인가 기록이 없습니다: $GRANT (킥오프 스킬이 먼저 돌아야 합니다)"

  # Provenance guard (sidecar.md §1.2). Absence of owner-doc= is a mismatch.
  local owner
  owner=$(sed -n '2p' "$GRANT" | sed -n 's/.*owner-doc=\([^;]*\).*/\1/p')
  [ -n "$owner" ] || die "인가 기록에 owner-doc= 이 없습니다 — fail-closed"
  [ "$owner" = "$DOC_KEY" ] || die "인가 기록의 owner-doc= 불일치 (문서 키 충돌): '$owner' vs '$DOC_KEY'"

  # Foreign grant. §1.4 forbids deletion and {slug} folds every run of one
  # document onto one path, so run N+1 finds a grant it did not write. Silently
  # inheriting a previous run's merge permission is the one failure here that is
  # both invisible and irreversible.
  local found=0 b
  while IFS= read -r b; do
    [ -n "$b" ] || continue
    if [ "$b" = "$RUN_ID" ]; then found=1; else
      warn "외래 인가 블록 발견: $b"
      FOREIGN_GRANTS="${FOREIGN_GRANTS:-}$b "
    fi
  done <<EOF
$(grant_blocks)
EOF
  if [ -n "${FOREIGN_GRANTS:-}" ]; then
    notify_send "외래 인가 발견 — 런 정지" "이 문서의 인가 기록에 이 런의 것이 아닌 블록이 있습니다: ${FOREIGN_GRANTS}"
    die "외래 인가 — 하드 스톱. 사람이 확인해야 계속됩니다."
  fi
  [ "$found" = "1" ] || die "이 런($RUN_ID)의 인가 블록이 없습니다"
}

# The ordered permission cutpoint. Index comparison decides autonomy.
readonly CUTPOINTS="커밋 브랜치 push PR 머지 배포 머지후착수"
cutpoint_index() {
  local want="$1" i=0 c
  for c in $CUTPOINTS; do
    i=$((i + 1))
    [ "$c" = "$want" ] && { printf '%s' "$i"; return 0; }
  done
  printf '0'
}
authorized() {
  # authorized <act> — true when the act is at or below the granted cutpoint.
  local act_i grant_i
  act_i=$(cutpoint_index "$1")
  grant_i=$(cutpoint_index "$(grant_field "$RUN_ID" '권한 절단점')")
  [ "$act_i" -ne 0 ] && [ "$grant_i" -ne 0 ] && [ "$act_i" -le "$grant_i" ]
}

# ---------------------------------------------------------------------------
# Ledger. Single writer, main worktree, append-only.
# ---------------------------------------------------------------------------
ledger_init() {
  mkdir -p "$(dirname "$LEDGER")"
  if [ ! -f "$LEDGER" ]; then
    {
      printf '# 파이프라인 런 원장 — %s\n' "$SLUG"
      printf '<!-- cc-pipeline-run v1; writer=orchestrator; reader=orchestrator; owner-doc=%s; origin-worktree=%s; NOT a design doc; mechanism-local, never staged by a skill -->\n' \
        "$DOC_KEY" "$(cd "$DOC_DIR" && git rev-parse --show-toplevel 2>/dev/null || printf '%s' "$DOC_DIR")"
      printf '\n## 계획 %s\n' "$RUN_ID"
    } > "$LEDGER"
  fi
  grep -qE "^## 실행 $RUN_ID$" "$LEDGER" || printf '\n## 실행 %s\n' "$RUN_ID" >> "$LEDGER"
}

ledger_row() {
  # ledger_row <계열> <field=value> ...
  local series="$1"; shift
  local line="- \`$series\`"
  local f
  for f in "$@"; do line="$line | $f"; done
  printf '%s\n' "$line" >> "$LEDGER"
}

ledger_last() {
  # ledger_last <계열> <key> — last value for a key in the newest matching row.
  local series="$1" key="$2"
  grep -E "^- \`$series\`" "$LEDGER" 2>/dev/null | tail -1 \
    | tr '|' '\n' | sed -n "s/^ *$key=//p" | tail -1
}

# ---------------------------------------------------------------------------
# Volatile run directory. Process handles live here and NOWHERE else: a stale
# record and a stale process then die together, so pid reuse can never make the
# driver kill an unrelated live process. It is under XDG_STATE_HOME rather than
# TMPDIR because /var/folders is swept without a reboot, and "no record implies
# no process" must not be falsified by a sweep.
# ---------------------------------------------------------------------------
rundir_init() {
  RUN_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/cc-cmds/run/$RUN_ID"
  mkdir -p "$RUN_DIR/halt" "$RUN_DIR/log"
  LOG_FILE="$RUN_DIR/log/driver.log"
  printf '%s\n' "$(now_epoch)" > "$RUN_DIR/started-at"
}

# ---------------------------------------------------------------------------
# Account resolver seam. Today a trivial single-account resolver; the planned
# multi-account router drops in here. Every re-dispatch goes through it — which
# has to be explicit, because a limit hit that arrives as a CLEAN terminal
# envelope lands on the "dead + predicate false" row, and that row would
# otherwise throw the work straight back at the account that just ran out.
# ---------------------------------------------------------------------------
resolve_account() {
  printf '%s' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
}
account_has_headroom() { return 1; }   # trivial resolver: no alternate account

# ---------------------------------------------------------------------------
# Notification seat. Three operations. `can_send` is a ONE-TIME adapter choice
# at run start, never a per-call gate: a per-call probe is exactly where
# fail-open dies, because an ambiguous probe reads as "cannot send" and that
# silence is indistinguishable from a channel failure.
# ---------------------------------------------------------------------------
NOTIFY_ADAPTER=""

notify_probe() {
  # The driver has no tool inventory, so the push adapter is reachable only by
  # dispatching a stage whose ENTIRE delegated purpose is the notification and
  # whose payload the driver wrote. A working stage that also notifies is
  # forbidden without exception.
  if [ -n "$CLI_BIN" ] && [ -x "$CLI_BIN" ]; then
    NOTIFY_ADAPTER="push-stage"
  else
    NOTIFY_ADAPTER="none"
  fi
  log "알림 어댑터: $NOTIFY_ADAPTER"
}

notify_send() {
  # fail-open, always: a missed banner is acceptable, a halted workflow is not.
  local title="$1" body="$2"
  report_append "알림" "$title — $body"
  [ "$NOTIFY_ADAPTER" = "push-stage" ] || return 0
  local prompt
  prompt="이 스테이지의 유일한 위임 목적은 알림 1회 전달이다. 다음 payload를 그대로 PushNotification 으로 보내고 종료하라. 제목: ${title} / 본문: ${body}"
  "$CLI_BIN" -p "$prompt" --output-format json --strict-mcp-config >/dev/null 2>&1 || \
    warn "알림 전달 실패 — 진행은 계속합니다 (fail-open)"
  return 0
}

notify_cleanup() { return 0; }

# ---------------------------------------------------------------------------
# Morning report. Durable independently of any banner, because the seat's
# contract does not include delivery confirmation — so the report, not the
# banner, is the source of truth.
# ---------------------------------------------------------------------------
report_path() { printf '%s/docs/pipeline-run/%s.md' "$BASE" "$RUN_ID"; }

report_append() {
  local kind="$1" text="$2"
  REPORT=$(report_path)
  mkdir -p "$(dirname "$REPORT")"
  [ -f "$REPORT" ] || printf '# 파이프라인 아침 보고서 — %s\n\n' "$RUN_ID" > "$REPORT"
  printf -- '- **%s** (%s): %s\n' "$kind" "$(now_iso)" "$text" >> "$REPORT"
}

# ---------------------------------------------------------------------------
# Blocked queue. Nothing here wakes anyone.
# ---------------------------------------------------------------------------
park() {
  local target="$1" reason="$2" observed="$3" recmd="${4:-(없음)}"
  ledger_row 'blocked' "대상=$target" "사유=$reason" "관측=$observed" "재개 명령=$recmd"
  report_append "보류" "$target — $reason — $observed"
  log "park: $target ($reason)"
}

# ---------------------------------------------------------------------------
# Design-document lock. Advisory and DETECTING, not preventing: correctness
# still rests on the composition rule that at most one segment per wave carries
# residual verification items. What this buys is a loud failure instead of a
# silent lost update.
# ---------------------------------------------------------------------------
with_doc_lock() {
  local rc=0
  /usr/bin/lockf -k -t 0 "$RUN_DIR/designdoc.lock" "$@" || rc=$?
  if [ "$rc" = "$LOCK_BUSY_EXIT" ]; then
    # 75 is not "the lock did its job, wait your turn" — it is "the plan was
    # wrong". Blocking here would serialize two read-modify-writes that were
    # each composed against pre-conflict bytes, leaving a serialized but still
    # incorrect document.
    return "$LOCK_BUSY_EXIT"
  fi
  return "$rc"
}

# ---------------------------------------------------------------------------
# Run worktrees. Every segment runs in its own, serial or parallel alike: two
# concurrent stages in one worktree share HEAD and the index and would walk on
# each other's commits.
# ---------------------------------------------------------------------------
main_root() { dirname "$(cd "$DOC_DIR" && git rev-parse --path-format=absolute --git-common-dir)"; }

wt_path() {
  local seg="$1" root repo
  root=$(main_root); repo=$(basename "$root")
  printf '%s/%s%s%s-%s' "$(dirname "$root")" "$repo" "$WORKTREE_INFIX" "$SLUG" "$seg"
}

stash_ref() { git -c core.pager=cat rev-parse --verify refs/stash 2>/dev/null || printf 'none'; }

wt_create() {
  local seg="$1" branch="$2" p
  p=$(wt_path "$seg")
  [ -d "$p" ] && { printf '%s' "$p"; return 0; }
  ( cd "$(main_root)" && git worktree add -b "$branch" "$p" HEAD >/dev/null 2>&1 ) \
    || ( cd "$(main_root)" && git worktree add "$p" "$branch" >/dev/null 2>&1 ) \
    || { warn "워크트리 생성 실패: $p"; return 1; }
  printf '%s' "$p"
}

wt_remove() {
  # TWO conditions, both required. (1) is the substantive guarantee; (2) is
  # defence in depth against a corrupted ledger. A hand-made lookalike passes
  # (2) and is caught by (1). Never --force: the tree may hold the only copy of
  # an uncommitted change.
  local seg="$1" p recorded
  p=$(wt_path "$seg")
  recorded=$(grep -E "^- \`segment\`" "$LEDGER" 2>/dev/null | grep -F "id=$seg" | tr '|' '\n' | sed -n 's/^ *워크트리=//p' | tail -1)
  if [ -z "$recorded" ] || [ "$recorded" != "$p" ]; then
    warn "철거 거부 — 이 런의 원장에 생성 시점 값으로 없습니다: $p"; return 1
  fi
  case "$p" in *"$WORKTREE_INFIX"*) : ;; *) warn "철거 거부 — 예약 인픽스 부재: $p"; return 1 ;; esac
  ( cd "$(main_root)" && git worktree remove "$p" >/dev/null 2>&1 && git worktree prune >/dev/null 2>&1 ) \
    || { warn "철거 실패(보고만, 강제 삭제하지 않음): $p"; return 1; }
  return 0
}

stash_attribution_check() {
  # An absent refs/stash is a normal "no stash" value, not a violation — this
  # repository has carried one since before the pipeline existed, so a
  # "there must be no stash" check would fail on day one, forever.
  local before="$1" seg_branch="$2" after
  after=$(stash_ref)
  [ "$before" = "$after" ] && return 0
  local top
  top=$(git stash list 2>/dev/null | head -1)
  case "$top" in
    *"on $seg_branch:"*) warn "세그먼트 브랜치에 귀속된 stash 항목 — 위반"; return 1 ;;
    *" on "*)            log "제3자 stash 활동 기록만 하고 계속: $top"; return 0 ;;
    *)                   warn "stash 귀속 모호 — 보수적으로 위반 판정"; return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# Worktree quiet window. `git worktree list` is repository-global, so creating
# or removing a sibling worktree inside a stage's freeze window fails that
# stage for something it did not do. Removals may be deferred (off the critical
# path); creations may NOT (deferring one is a dispatch barrier).
# ---------------------------------------------------------------------------
QUIET_WINDOW=0
PENDING_REMOVALS=""

quiet_window_begin() { QUIET_WINDOW=1; }
quiet_window_end() {
  QUIET_WINDOW=0
  local seg
  for seg in ${PENDING_REMOVALS:-}; do wt_remove "$seg" || true; done
  PENDING_REMOVALS=""
}
wt_remove_or_defer() {
  if [ "$QUIET_WINDOW" = "1" ]; then PENDING_REMOVALS="$PENDING_REMOVALS $1"; else wt_remove "$1" || true; fi
}

# ---------------------------------------------------------------------------
# Dispatch. Foreground `-p`, one mode. The driver detaches ONCE (itself); a
# stage that outlives its controller is a hazard, not a benefit, because the
# driver cannot reclaim a tree it does not own.
# ---------------------------------------------------------------------------
session_uuid() {
  # Derived, never stored: owner-doc | segment | stage | attempt.
  printf '%s|%s|%s|%s' "$DOC_KEY" "$1" "$2" "$3" | shasum -a 256 | cut -c1-32
}

dispatch_stage() {
  # dispatch_stage <stage-id> <cwd> <prompt> [extra-cli-args...]
  local stage="$1" cwd="$2" prompt="$3"; shift 3
  local cfg out pid pgid
  cfg=$(resolve_account)
  out="$RUN_DIR/log/$stage.json"

  [ -n "$CLI_BIN" ] || { warn "CLI 바이너리를 찾지 못했습니다"; return 127; }

  # `set -m` makes the child the leader of its own process group, so the whole
  # tree is reclaimable with `kill -- -$pgid`. Without it the "group" silently
  # becomes the CALLER's, which is why the pgid is read back before it is
  # recorded rather than assumed.
  set -m
  CLAUDE_CONFIG_DIR="$cfg" CC_PIPELINE_STAGE_ID="$stage" \
    nohup "$CLI_BIN" -p "$prompt" \
      --output-format json --strict-mcp-config "$@" \
      > "$out" 2> "$RUN_DIR/log/$stage.err" < /dev/null &
  pid=$!
  set +m

  pgid=$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')
  # Recorded BEFORE waiting, so a driver that dies mid-stage leaves a handle
  # its successor can find. Both go to the volatile directory only.
  printf '%s\n' "$pid"  > "$RUN_DIR/$stage.pid"
  printf '%s\n' "$pgid" > "$RUN_DIR/$stage.pgid"

  local rc=0
  wait "$pid" || rc=$?
  rm -f "$RUN_DIR/$stage.pid" "$RUN_DIR/$stage.pgid"
  printf '%s' "$rc" > "$RUN_DIR/$stage.rc"
  return 0
}

reap_orphan() {
  # A driver that died mid-stage leaves a stage still running — and still able
  # to commit and push. `implement` is re-invocation idempotent, so killing and
  # re-dispatching is safe.
  local stage="$1" pid pgid
  [ -f "$RUN_DIR/$stage.pid" ] || return 0
  pid=$(cat "$RUN_DIR/$stage.pid")
  pgid=$(cat "$RUN_DIR/$stage.pgid" 2>/dev/null || printf '')
  if kill -0 "$pid" 2>/dev/null; then
    log "고아 스테이지 회수: $stage pid=$pid pgid=$pgid"
    [ -n "$pgid" ] && kill -- "-$pgid" 2>/dev/null || kill "$pid" 2>/dev/null || true
  fi
  rm -f "$RUN_DIR/$stage.pid" "$RUN_DIR/$stage.pgid"
}

# ---------------------------------------------------------------------------
# Sleep discriminator. Closing the lid leaves a stage alive with a stalled
# transcript, which the resume table would otherwise read as the limit-exhaustion
# shape and act on — killing and re-running on false evidence. Wall-clock moves
# across a sleep; the wake timestamp records that it happened.
# ---------------------------------------------------------------------------
sysctl_sec() {
  sysctl -n "$1" 2>/dev/null | awk -F'[ ,]+' '{for(i=1;i<=NF;i++) if($i=="sec"){print $(i+2); exit}}'
}
boot_epoch() { sysctl_sec kern.boottime; }
wake_epoch() { sysctl_sec kern.waketime; }

machine_slept_since() {
  local since="$1" w
  w=$(wake_epoch)
  [ -n "$w" ] || return 1
  [ "$w" = "0" ] && return 1
  [ "$w" -gt "$since" ]
}

# ---------------------------------------------------------------------------
# Artifact predicates. Not all of equal strength, and saying so is part of the
# contract: a predicate over state a stage CANNOT fabricate (a git ref, a
# remote ref, a PR number) is immune to a hollow success; a predicate over an
# artifact the stage authors is not. For a stage whose only output is a
# document, no un-fabricable predicate exists.
# ---------------------------------------------------------------------------
predicate_design()      { grep -qF "$LIT_DESIGN_FREEZE" "$RUN_DIR/log/$1.err" 2>/dev/null || grep -qF "$LIT_DESIGN_FREEZE" "$RUN_DIR/log/$1.json" 2>/dev/null; }
predicate_audit()       { grep -qF "$LIT_AUDIT_TERMINAL" "$RUN_DIR/log/$1.json" 2>/dev/null && ls "$BASE/docs/design-audit/$SLUG".reader-*.md >/dev/null 2>&1; }
predicate_review()      { local rp="$1"; [ -f "$rp" ] && grep -qE '^- \*\*발견 요약\*\*: 🔴 P0 [0-9]+건 \| 🟠 P1 [0-9]+건 \| 🟡 P2 [0-9]+건 \| 🟢 P3 [0-9]+건' "$rp"; }
predicate_reconverge()  { grep -qF "$LIT_RECONVERGE_TERMINAL" "$RUN_DIR/log/$1.json" 2>/dev/null; }

predicate_implement() {
  # The git-state ladder, evaluated in the MAIN tree, in cutpoint order. A run
  # that answered in prose and moved on makes no commit, so the ladder is false
  # and the driver never consults the stage's self-report.
  local branch="$1" pre_head="$2" root
  root=$(main_root)
  ( cd "$root" || exit 1
    git rev-parse --verify "$branch" >/dev/null 2>&1 || exit 1
    [ "$(git rev-parse "$branch")" != "$pre_head" ] || exit 1
    authorized push || exit 0
    git rev-parse --verify "refs/remotes/origin/$branch" >/dev/null 2>&1 || exit 1
    authorized PR || exit 0
    [ -n "$(gh pr list --head "$branch" --json number --jq '.[0].number' 2>/dev/null)" ] || exit 1
  )
}

# ---------------------------------------------------------------------------
# Termination classification. Exit status and the artifact predicate are
# independent axes; the halt record is the third. Crossing all three separates
# "it died" from "it believed it was finished".
# ---------------------------------------------------------------------------
halt_record_present() {
  local stage="$1" f="$RUN_DIR/halt/$1.md"
  [ -f "$f" ] || return 1
  # The closing fence is the terminator. A record whose last non-empty line is
  # not the fence is a crash mid-write, not a halt.
  [ "$(grep -v '^[[:space:]]*$' "$f" | tail -1)" = "<!-- /cc-pipeline-halt v1 -->" ]
}

classify_termination() {
  # classify_termination <stage> <exit-rc> <predicate-rc>
  local stage="$1" exit_rc="$2" pred_rc="$3"
  if halt_record_present "$stage"; then printf '의도된 park'; return 0; fi
  if [ "$exit_rc" = "0" ] && [ "$pred_rc" = "0" ]; then printf '정상 완료'; return 0; fi
  if [ "$exit_rc" = "0" ]; then printf '공허한 성공'; return 0; fi
  printf '크래시'
}

# ---------------------------------------------------------------------------
# Resume decision table (five rows). Row 5 is the only reachable state after a
# reboot — the absence of the record IS the evidence the process is gone — and
# without it the other four are unreachable in the most common overnight
# interruption. But absence must be corroborated: /var/folders is swept without
# a reboot, so the boot time is compared against the run's start.
# ---------------------------------------------------------------------------
resume_verdict() {
  local stage="$1" pid started b
  started=$(cat "$RUN_DIR/started-at" 2>/dev/null || printf '0')

  if [ ! -f "$RUN_DIR/$stage.pid" ]; then
    b=$(boot_epoch)
    if [ -n "$b" ] && [ "$b" -gt "$started" ]; then printf '재부팅-사망'; else printf '기록부재-탐색필요'; fi
    return 0
  fi
  pid=$(cat "$RUN_DIR/$stage.pid")
  if ! kill -0 "$pid" 2>/dev/null; then printf '사망'; return 0; fi

  local tr mt age
  tr="$RUN_DIR/log/$stage.json"
  mt=$( [ -f "$tr" ] && wc -c < "$tr" | tr -d ' ' || printf '0' )
  age=$(( $(now_epoch) - started ))
  if [ "$mt" != "${LAST_PROGRESS_MARK:-x}" ]; then LAST_PROGRESS_MARK="$mt"; printf '진행중'; return 0; fi
  if machine_slept_since "$(( $(now_epoch) - age ))"; then printf '기계가-잠'; return 0; fi
  printf '한도-형상'
}

# ---------------------------------------------------------------------------
# Limit ladder: rotate at a stage boundary, then wait, then a CAPPED backoff,
# then park. No model downgrade — design and review quality must not drift
# overnight, and the rotation removes most of the incentive anyway.
# ---------------------------------------------------------------------------
backoff_wait() {
  local elapsed=0 sleep_s="$BACKOFF_START_SECONDS"
  while [ "$elapsed" -lt "$BACKOFF_WALLCLOCK_CAP_SECONDS" ]; do
    log "한도 대기 ${sleep_s}s (누적 ${elapsed}s / 상한 ${BACKOFF_WALLCLOCK_CAP_SECONDS}s)"
    sleep "$sleep_s"
    elapsed=$((elapsed + sleep_s))
    sleep_s=$((sleep_s * BACKOFF_FACTOR))
    [ "$sleep_s" -gt "$BACKOFF_MAX_SLEEP_SECONDS" ] && sleep_s="$BACKOFF_MAX_SLEEP_SECONDS"
    return 0   # one interval per call; the caller re-observes between sleeps
  done
  return 1     # cap reached -> park
}

boundary_idempotent() {
  case "$1" in
    S2|S4|S5|S8) return 0 ;;   # audit / implement / review / merge
    *)           return 1 ;;   # design and re-convergence are NOT
  esac
}

# ---------------------------------------------------------------------------
# Merge gate (S8).
# ---------------------------------------------------------------------------
merge_gate() {
  local seg="$1" branch="$2" pr
  if ! authorized 머지; then
    park "$seg" "인가 한도" "권한 절단점이 머지를 인가하지 않음" "gh pr merge $branch"
    return 1
  fi
  pr=$(gh pr list --head "$branch" --json number --jq '.[0].number' 2>/dev/null || printf '')
  [ -n "$pr" ] || { park "$seg" "게이트 park" "PR을 찾지 못함" "gh pr list --head $branch"; return 1; }

  # A merge grant does NOT come with an --admin exception. A driver blocked by
  # branch protection that issued itself that exception would be widening the
  # authorization silently.
  local required_rows
  required_rows=$(gh pr checks "$pr" --required 2>/dev/null | grep -c . || printf '0')
  if [ "$required_rows" = "0" ]; then
    if ! gh pr checks "$pr" >/dev/null 2>&1; then
      # Interactively this branch enumerates the failed non-required checks and
      # asks. Unattended the answer never comes, so it IS the park branch.
      park "$seg" "게이트 park" "필수 지정이 없고 비필수 체크가 실패 — 무응답이면 머지 금지" "gh pr merge $pr"
      return 1
    fi
  elif ! gh pr checks "$pr" --required >/dev/null 2>&1; then
    park "$seg" "게이트 park" "필수 체크 실패" "gh pr checks $pr --required"
    return 1
  fi

  local head_sha
  head_sha=$(gh pr view "$pr" --json headRefOid --jq '.headRefOid' 2>/dev/null || printf '')
  gh pr merge "$pr" --merge --match-head-commit "$head_sha" --delete-branch >/dev/null 2>&1 || {
    park "$seg" "게이트 park" "머지 실패(보호 규칙 가능성) — --admin 은 사용하지 않음" "gh pr merge $pr"
    return 1
  }
  ledger_row 'segment' "id=$seg" "상태=머지됨" "브랜치=$branch" "PR=$pr"
  return 0
}

# ---------------------------------------------------------------------------
# Judgment calls. Wired, stubbed. Each is a single foreground `-p` with a fixed
# prompt file and a `--json-schema` return contract; the schema is what makes
# the return machine-readable without parsing prose.
# ---------------------------------------------------------------------------
PROMPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/prompts"

readonly JUDGMENTS="segment-plan triage redesign-impact"

judgment_call() {
  # judgment_call <name> <input-file>  — prompt and schema are found by
  # convention: <name>.md and <name>.schema.json beside this script.
  local name="$1" input="$2"
  local prompt="$PROMPT_DIR/$name.md" schema="$PROMPT_DIR/$name.schema.json"
  local out="$RUN_DIR/log/judge-$name.json"

  [ -f "$prompt" ] || { warn "판단 호출 프롬프트 부재: $prompt"; return 1; }
  [ -f "$schema" ] || { warn "판단 호출 스키마 부재: $schema"; return 1; }

  "$CLI_BIN" -p "$(cat "$prompt")

--- INPUT ---
$(cat "$input")" \
    --json-schema "$(cat "$schema")" --output-format json --strict-mcp-config \
    > "$out" 2>/dev/null || { warn "판단 호출 실패: $name"; return 1; }

  # The schema is enforced only on a SUCCESSFUL termination — a turn-exhausted
  # run carries a null result and says nothing about the judgment. Classify the
  # termination before reading the payload, and read the already-parsed object
  # rather than re-decoding the string form of the same thing.
  local subtype
  subtype=$(jq -r '.subtype // "unknown"' "$out" 2>/dev/null || printf 'unknown')
  if [ "$subtype" != "success" ]; then
    warn "판단 호출 비성공 종단: $name subtype=$subtype — 스키마가 단언되지 않음"
    return 1
  fi
  jq -e '.structured_output' "$out" >/dev/null 2>&1 || { warn "판단 호출 구조화 출력 부재: $name"; return 1; }
  printf '%s' "$out"
}

judgment_result() { jq -c '.structured_output' "$1"; }

# ---------------------------------------------------------------------------
# Self-check — the mode the test harness and a sanitized-PATH CI leg run.
# ---------------------------------------------------------------------------
self_check() {
  local fails=0
  printf 'bash: %s\n' "$BASH_VERSION"
  printf 'PATH: %s\n' "$PATH"
  for t in git awk sed grep shasum ps sysctl date; do
    if command -v "$t" >/dev/null 2>&1; then printf 'ok   %s -> %s\n' "$t" "$(command -v "$t")"
    else printf 'FAIL %s missing\n' "$t"; fails=$((fails + 1)); fi
  done
  if [ -x /usr/bin/lockf ]; then printf 'ok   lockf -> /usr/bin/lockf\n'
  else printf 'FAIL lockf missing (detection lock unavailable)\n'; fails=$((fails + 1)); fi
  # The denylist row for this binary exists because a detach path built on it
  # does not run on the target platform. Probing for its ABSENCE is the one
  # legitimate mention, so both arms carry the same-line escape rather than
  # weakening the row.
  if command -v setsid >/dev/null 2>&1; then printf 'note setsid present (unused; nohup + set -m is the contract)\n'  # lint-bash-portability: disable=setsid
  else printf 'ok   setsid absent as expected on darwin\n'; fi  # lint-bash-portability: disable=setsid
  local b w
  b=$(boot_epoch); w=$(wake_epoch)
  if [ -n "$b" ]; then printf 'ok   kern.boottime -> %s\n' "$b"; else printf 'FAIL kern.boottime unreadable\n'; fails=$((fails + 1)); fi
  printf 'ok   kern.waketime -> %s\n' "${w:-unset}"
  printf 'ok   cutpoint index 머지 -> %s\n' "$(cutpoint_index 머지)"
  if [ "$fails" = "0" ]; then printf 'self-check: PASS\n'; return 0; fi
  printf 'self-check: %s FAIL\n' "$fails"; return 1
}

# ---------------------------------------------------------------------------
# State machine
# ---------------------------------------------------------------------------
main_loop() {
  log "런 시작 run-id=$RUN_ID doc=$DOC slug=$SLUG base=$BASE"
  ledger_row 'run' "run-id=$RUN_ID" "시작=$(now_iso)" "설계 문서=$DOC_KEY" \
    "전체 sha256=$(shasum -a 256 "$DOC" | cut -d' ' -f1)" "RUN_DIR=$RUN_DIR" "보고서=$(report_path)"
  report_append "개시" "run-id=$RUN_ID · 문서 $DOC_KEY · 권한 절단점 $(grant_field "$RUN_ID" '권한 절단점')"

  # S2 AUDIT — headless, one pass. Runs before any wave, so the freeze window
  # never overlaps a sibling worktree creation on the first pass; only a
  # RE-audit can, and the quiet window covers that.
  quiet_window_begin
  dispatch_stage S2 "$(main_root)" "/cc-cmds:design-audit-unattended $DOC"
  quiet_window_end
  local rc2 pred2 class2
  rc2=$(cat "$RUN_DIR/S2.rc" 2>/dev/null || printf '1')
  if predicate_audit S2; then pred2=0; else pred2=1; fi
  class2=$(classify_termination S2 "$rc2" "$pred2")
  ledger_row 'stage-result' "세그먼트=-" "스테이지=S2" "종료 코드=$rc2" \
    "아티팩트 술어 결과=$pred2" "실행 버전=$("$CLI_BIN" --version 2>/dev/null | head -1)" "종단 부류=$class2"
  case "$class2" in
    '정상 완료') : ;;
    '의도된 park') park "S2" "게이트 park" "중단 기록 존재" "$(sed -n 's/^\*\*재호출 명령\*\*: //p' "$RUN_DIR/halt/S2.md" 2>/dev/null)"; return 0 ;;
    *) park "S2" "게이트 park" "종단 부류 $class2"; return 0 ;;
  esac

  # S3 SEGMENT-PLAN — one judgment call per design generation.
  local plan_out plan seg_mode
  if plan_out=$(judgment_call segment-plan "$DOC"); then
    plan=$(judgment_result "$plan_out")
    seg_mode=$(printf '%s' "$plan" | jq -r '.segmentation // "low-confidence"')
    ledger_row 'generation' "세대=1" "전체 sha256=$(shasum -a 256 "$DOC" | cut -d' ' -f1)" \
      "세그먼트 계획=$(printf '%s' "$plan" | jq -c '.segments | map(.id)')" "segmentation=$seg_mode"
    local seg
    for seg in $(printf '%s' "$plan" | jq -r '.segments[].id'); do
      ledger_row 'segment' "id=$seg" "상태=계획됨" \
        "선언 파일 집합=$(printf '%s' "$plan" | jq -c --arg s "$seg" '.segments[] | select(.id==$s) | .declared_files')" \
        "plan-binding-digest=$(binding_digest)" "워크트리=$(wt_path "$seg")"
    done
  else
    park "S3" "게이트 park" "세그먼트 계획 판단 호출 실패"
    return 0
  fi

  report_append "종료" "드라이버 골격 — S4~S9 세그먼트 사이클은 후속 단계에서 활성화됩니다."
  log "런 종료"
}

# ---------------------------------------------------------------------------
# Entry
#
# `CC_ORCH_SOURCE_ONLY=1` loads the definitions above and stops. It exists for
# the test harness, which exercises the predicates and guards directly: a
# driver whose only entry point is "run a whole pipeline" can be tested only by
# running one, and the parts most worth testing — the teardown guard, the
# termination table, the backoff cap — are exactly the ones a full run does not
# reach on the happy path.
# ---------------------------------------------------------------------------
if [ "${CC_ORCH_SOURCE_ONLY:-0}" = "1" ]; then
  return 0 2>/dev/null || exit 0
fi

DETACH=0
while [ $# -gt 0 ]; do
  case "$1" in
    --doc)        DOC="$2"; shift 2 ;;
    --run-id)     RUN_ID="$2"; shift 2 ;;
    --detach)     DETACH=1; shift ;;
    --self-check) self_check; exit $? ;;
    *) echo "run.sh: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

[ -n "$DOC" ] || { echo "run.sh: --doc <abs-path> is required" >&2; exit 2; }
[ -f "$DOC" ] || { echo "run.sh: design document not found: $DOC" >&2; exit 2; }

derive_paths
[ -n "$RUN_ID" ] || RUN_ID=$(grant_blocks | tail -1)
[ -n "$RUN_ID" ] || { echo "run.sh: --run-id is required when the grant has no block" >&2; exit 2; }

rundir_init

if [ "$DETACH" = "1" ]; then
  # The driver detaches exactly ONCE — itself. Stages stay in the foreground so
  # the driver owns their process groups and can reclaim the whole tree on
  # restart. The right invariant is `driver lifetime >= stage lifetime`, and it
  # is bought by detaching the driver once rather than each stage N times.
  set -m
  nohup "$0" --doc "$DOC" --run-id "$RUN_ID" >> "$LOG_FILE" 2>&1 < /dev/null &
  printf '%s\n' "$!" > "$RUN_DIR/driver.pid"
  ps -o pgid= -p "$!" 2>/dev/null | tr -d ' ' > "$RUN_DIR/driver.pgid"
  set +m
  echo "driver detached: pid=$(cat "$RUN_DIR/driver.pid") log=$LOG_FILE"
  exit 0
fi

check_grant
ledger_init
notify_probe
main_loop
notify_cleanup
