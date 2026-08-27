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
#   run.sh --doc <abs-path> [--run-id <id>]
#
# THERE IS NO `--detach`. The run is driven by the main session's model — the
# router — and detaching would put the deciding turn somewhere nobody can see.
# Visible progress and an interruptible terminal are the reason for that shape,
# and a detach flag is the one thing that would silently undo it.
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
# This file's own directory. Defined here rather than beside its first consumer
# because two consumers now sit hundreds of lines apart, and a path variable
# defined after its first use is set to the empty string on that path — which
# resolves to the filesystem root and fails somewhere else entirely.
ORCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

# Normalize the LOCALE for the same reason, and split it across two categories
# rather than setting one value, because the two categories want opposite things.
#
#   LC_CTYPE  — must be UTF-8. Every vocabulary this driver compares is Korean:
#               park reasons, ledger keys, manifest field names, cutpoint tokens.
#               A detached run inherits no LANG at all, and an interpreter that
#               classifies those bytes as invalid characters does not fail
#               loudly — it fails by not matching, which is this driver's worst
#               failure shape. Measured on a CI runner: a `case` arm lookup
#               reported five arms for every Korean token and one for each ASCII
#               token, and a heading regex stopped matching its own heading.
#   LC_COLLATE — must be C. The target-map digest sorts rows and then hashes
#               them, and a locale-dependent sort makes that digest depend on
#               who computed it. The kickoff computes it interactively and the
#               driver compares it detached, so a collation difference between
#               those two environments would reject a manifest nobody tampered with.
#
# `LC_ALL` is cleared first because it overrides both. The UTF-8 locale is
# CHOSEN from what the host actually has rather than pinned: a name the host does
# not carry falls back to C silently, which is the very state being escaped.
# `LC_ALL` first, and on the measured runner this line was the whole of the fix:
# that host already had `LC_CTYPE=en_US.UTF-8` and an `LC_ALL` overriding it.
unset LC_ALL
ORCH_UTF8_LOCALE=""
ORCH_LOCALE_SOURCE=""
# `locale -a` is read ONCE into a variable, and the match below does not use
# `grep -q`. Under `set -o pipefail` a `-q` grep exits on its first match, the
# writer on the left takes SIGPIPE, and the PIPELINE reports failure even though
# the match succeeded — so the `if` is false exactly when the answer is yes.
# Measured: standalone the driver selected `en_US.UTF-8`; sourced into a harness
# that had already turned on `pipefail` the same loop selected nothing, and the
# fallback below quietly covered for it.
_locales=$(locale -a 2>/dev/null || printf '')
for _loc in en_US.UTF-8 C.UTF-8 en_US.utf8 C.utf8; do
  if printf '%s\n' "$_locales" | grep -xF "$_loc" >/dev/null; then
    ORCH_UTF8_LOCALE="$_loc"; ORCH_LOCALE_SOURCE="선택"
    break
  fi
done
unset _loc _locales
if [ -z "$ORCH_UTF8_LOCALE" ]; then
  # Nothing offered by `locale -a`. That happened on a real runner whose
  # `LC_CTYPE` was nevertheless a UTF-8 locale, so an inherited value that
  # already ends in UTF-8 is accepted rather than overwritten with a name the
  # host may not carry. Recorded as INHERITED so the two cases stay
  # distinguishable in the diagnostic — a selection that silently did nothing
  # reads identically to one that worked.
  case "${LC_CTYPE:-${LANG:-}}" in
    *UTF-8|*utf-8|*UTF8|*utf8)
      ORCH_UTF8_LOCALE="${LC_CTYPE:-$LANG}"; ORCH_LOCALE_SOURCE="상속" ;;
  esac
fi
if [ -n "$ORCH_UTF8_LOCALE" ]; then
  LANG="$ORCH_UTF8_LOCALE"
  LC_CTYPE="$ORCH_UTF8_LOCALE"
  export LANG LC_CTYPE
fi
LC_COLLATE="C"
export LC_COLLATE

# Host-OS injection seam — tests inject CC_CMDS_ORCH_HOST_OS to drive the
# Darwin-vs-non-Darwin branches uniformly across CI legs (positive injection
# rather than a negative-framed skip). Default = uname -s for normal use.
# Same spelling convention as the notification helper's seam, deliberately.
ORCH_HOST_OS="${CC_CMDS_ORCH_HOST_OS:-$(uname -s)}"

set -euo pipefail

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
# Rungs per identity. Two caps carry weight on this number — the per-segment
# cycle budget `K*F + 1` and the run-level budget that sums it — and they used to
# be unrelated literals sitting in two functions. Naming it once is what makes
# "the same value" true rather than merely intended.
readonly LADDER_RUNGS=4
# Generations. A re-plan is allowed to happen; a run that keeps re-planning is a
# run that never lands anything, and the second generation is where that becomes
# visible rather than the tenth.
readonly GENERATION_MAX=2
readonly BACKOFF_START_SECONDS=60
readonly BACKOFF_FACTOR=2
readonly BACKOFF_MAX_SLEEP_SECONDS=1800  # per-sleep ceiling
# The wall-clock cap on the whole backoff ladder. The design's residual item on
# limit-exhaustion envelope shape was waived unverified, and its stated failure
# impact is that an envelope-less stall makes an unbounded backoff mandatory to
# bound. Adopting the cap up front covers both branches of that item, so the
# ladder terminates whichever way the envelope turns out to behave.
readonly BACKOFF_WALLCLOCK_CAP_SECONDS=21600   # 6h, then park
# Consecutive silent polls before a live stage is classed as the limit shape.
#
# Measured (90,584 inter-entry gaps across 40 transcripts): p50 1.4s, p90 26s,
# p95 46s, p99 366s, max 3581s. The tail is heavy and the two populations —
# healthy-but-quiet and actually-stalled — OVERLAP, so no count separates them.
# The corpus is also the wrong population by construction: those are interactive
# sessions where a long gap is human think-time, which makes the tail an upper
# bound on the headless case rather than a measurement of it. One headless
# observation sat silent for 45s while healthy.
#
# So this is a cheap early filter, NOT a classifier, and it is affordable to be
# wrong: a misclassified healthy stage does not get killed, it gets backed off —
# the driver waits in escalating intervals and still collects the stage when it
# finishes. A signal is only sent at the backoff cap, and never at all to a
# stage that is not boundary-idempotent.
#
# 6 × the 10s poll = 60s, covering ~96% of that inflated corpus. The real bound
# on a stage that grows without producing is the wall-clock deadline and the run
# cycle budget, not this number.
readonly STALL_SILENT_POLLS=6
readonly WORKTREE_INFIX="-run-"          # reserved; also the boundary gate's exception pattern
readonly LOCK_BUSY_EXIT=75               # EX_TEMPFAIL from lockf -t 0

# Terminal literals. These are fixed bytes inside skill text, which is what
# makes them safe as wire format — unlike the next-step lines those skills also
# emit, which are model-authored prose.
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
# Platform contract — darwin only, expressed as a seam rather than as a skip.
#
# Every environment measurement this driver rests on was taken on darwin: the
# advisory lock, the process-group behaviour of `set -m`, the boot-time source,
# and the very notion of a machine sleeping. Nothing was measured on Linux, so
# a portability layer today would import a bundle of environment claims about a
# second platform that nobody has checked — which is precisely the defect class
# the environment-measurement step exists to prevent.
#
# The refusal is at ENTRY, not a degraded path. A driver that silently does
# less is the failure mode this whole design is built to prevent, and a run
# that lost its detachment or its lock while reporting success would be exactly
# that.
#
# What the seam buys is that "darwin only" costs no coverage. Selection logic —
# which lock, which clock, which resume row, and the refusal itself — is driven
# by the seam and is therefore verifiable on any runner by injection. Only the
# claims that need a real kernel (reparenting under `set -m`, contention on the
# lock, a boot clock across a sleep) require the darwin leg.
#
# Linux is NOT closed; it is unmeasured. Opening it means re-running the
# environment-measurement step there and recording observations matching the
# darwin ones — until then, the non-darwin arm of this seam stays a refusal.
# ---------------------------------------------------------------------------
platform_supported() { [ "$ORCH_HOST_OS" = "Darwin" ]; }

platform_refuse() {
  cat >&2 <<EOF
run.sh: 이 드라이버는 darwin 전용입니다 (관측된 호스트: ${ORCH_HOST_OS}).

리눅스 지원은 닫힌 것이 아니라 **재지 않은 것**입니다. 이 드라이버가 기대는
환경 사실 — 권고 잠금의 경합 거동, \`set -m\`의 프로세스 그룹 재부모화,
부팅 시각 소스, 절전이라는 개념 자체 — 은 전부 darwin에서만 실측됐습니다.
잰 적 없는 플랫폼에서 조용히 덜 동작하는 것보다 진입에서 거부하는 편이 낫습니다.

여는 조건: 그 플랫폼에서 환경 실측 선행 단계를 다시 돌리고 대응 관측을 남길 것.
테스트는 CC_CMDS_ORCH_HOST_OS 로 분기를 주입해 어느 러너에서도 검증합니다.
EOF
  return 4
}

# Source selection is seam-driven, so it is exercised under injection on any
# runner. Whether the selected binary EXISTS is a separate question, and it is
# one only the darwin leg can answer.
lock_tool()  { platform_supported && printf '/usr/bin/lockf' || printf ''; }
boot_source() { platform_supported && printf 'kern.boottime' || printf ''; }
wake_source() { platform_supported && printf 'kern.waketime' || printf ''; }

# ---------------------------------------------------------------------------
# Path and slug derivation (sidecar.md §1.1), keyed on the DOCUMENT's own
# location and never on the cwd.
# ---------------------------------------------------------------------------
# SLUG is RUN identity — worktree paths, segment branch names, review report
# names. DOC_SLUG is DOCUMENT identity, and it exists because exactly one path
# the shared contract owns stays document-keyed: the audit sidecar the artifact
# predicate reads. One variable carrying both meanings is unsatisfiable — the
# document entry set it document-derived and the manifest entry set it to the
# run id, so whichever value went in, the other consumer read the wrong path.
DOC=""; DOC_DIR=""; DOC_KEY=""; SLUG=""; DOC_SLUG=""; BASE=""; RUN_ID=""; RUN_DIR=""
LEDGER=""; GRANT=""; REPORT=""

derive_paths() {
  # Document-derived paths. Retained for the degenerate case — a run that names
  # only a document — and for the ONE path the shared contract deliberately
  # keeps document-keyed: the audit sidecar an artifact predicate reads.
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
  DOC_SLUG="$SLUG"
  GRANT="$BASE/docs/pipeline-grant/$SLUG.md"
  LEDGER="$BASE/docs/pipeline-run/$SLUG.md"
}

# ---------------------------------------------------------------------------
# Manifest — the run's own contract, and the thing a run is ABOUT
#
# Everything below used to be derived from a design document, which is why a run
# that starts from a pull request or from a bare intent could not start at all:
# the identifier, the authorization path, the ledger, the report and every
# remediation target had nothing to derive from. The manifest supplies them, and
# a document becomes one optional element inside it.
# ---------------------------------------------------------------------------
MANIFEST=""; ANCHOR_KIND=""; ANCHOR_KEY=""

manifest_header() { sed -n '2,8p' "$MANIFEST" | tr '\n' ' '; }

manifest_hdr_field() {
  manifest_header | sed -n "s/.*[; ]$1=\([^;]*\).*/\1/p" | sed 's/[[:space:]]*$//'
}

manifest_field() {
  # manifest_field <section> <key> — CANON rendering inside one `## <section>`.
  awk -v want="## $1" -v key="$2" '
    $0 == want { inb=1; next }
    inb && /^## / { exit }
    inb { pat = "^\\*\\*" key "\\*\\*: "; if ($0 ~ pat) { sub(pat, "", $0); print; exit } }
  ' "$MANIFEST"
}

manifest_targets() { grep -E '^- `target`' "$MANIFEST" 2>/dev/null || true; }

target_field() {
  # target_field <alias> <key>
  manifest_targets | while IFS= read -r row; do
    case "$row" in *"별칭=$1 "*|*"별칭=$1|"*|*"별칭=$1") ;; *) continue ;; esac
    printf '%s' "$row" | tr '|' '\n' | sed -n "s/^ *$2=//p" | sed 's/[[:space:]]*$//'
    break
  done
}

target_aliases() {
  manifest_targets | tr '|' '\n' | sed -n 's/^ *별칭=//p' | sed 's/[[:space:]]*$//'
}

canonical_targets() { manifest_targets | sed 's/[[:space:]]\{1,\}/ /g' | sort; }

binding_set_bytes() {
  # The frozen set, canonically serialized. NOT the plan — the router decides
  # the step graph one act at a time now, so a frozen plan would be a value that
  # is recorded and never compared, which is the exact defect class this
  # contract exists to remove.
  {
    printf 'goal\t%s\n' "$(manifest_field '인가' '종료 지점')"
    manifest_clauses | sed 's/^/clause\t/'
    canonical_targets | sed 's/^/target\t/'
    grep -E '^\*\*[^*]+\*\*: (켬|끔)$' "$MANIFEST" 2>/dev/null | sed 's/^/rule\t/' || true
    grep -E '^- `사전 인가`' "$MANIFEST" 2>/dev/null | sed 's/[[:space:]]\{1,\}/ /g;s/^/preauth\t/' || true
    printf 'deadline\t%s\n' "$(manifest_field '인가' '벽시계 마감')"
  } | sort
}

manifest_clauses() {
  # The termination point decomposed into checkable clauses, frozen at kickoff.
  # A run is measured against these, so they are part of what may not move.
  grep -E '^- `종료 절`' "$MANIFEST" 2>/dev/null | sed 's/[[:space:]]\{1,\}/ /g' || true
}

# The conjunction. Order matters: the ownership proof comes before anything that
# would act on the file's contents.
check_manifest() {
  [ -f "$MANIFEST" ] || die "매니페스트가 없습니다: $MANIFEST"

  # 1 — kind token, strict equality.
  grep -q 'cc-run-manifest v1' "$MANIFEST" || die "매니페스트 kind 토큰 불일치 — cc-run-manifest v1 이 아니다"

  # 10 — ownership proof, FAIL-CLOSED, and before the tie-break.
  # This kind is about a RUN, not a document, so `owner-doc=` cannot be the
  # proof: a run may have no document at all. The pair below replaces it, and
  # replacing the proof is not the same as dropping it.
  local h_run h_anchor
  h_run=$(manifest_hdr_field 'run-id'); h_anchor=$(manifest_hdr_field 'anchor-key')
  [ -n "$h_run" ]    || die "매니페스트 헤더에 run-id= 이 없습니다 — fail-closed"
  [ -n "$h_anchor" ] || die "매니페스트 헤더에 anchor-key= 가 없습니다 — fail-closed"
  [ "$h_run" = "$(manifest_field '런 정체' '런 id')" ] \
    || die "헤더 run-id= 와 본문 「런 id」가 다릅니다"
  [ "$h_anchor" = "$(manifest_field '런 정체' '앵커 키')" ] \
    || die "헤더 anchor-key= 와 본문 「앵커 키」가 다릅니다"
  RUN_ID="$h_run"; ANCHOR_KEY="$h_anchor"
  ANCHOR_KIND=$(manifest_field '런 정체' '앵커 종류')

  # 2 — exactly one authorization block. No append form exists, so a second is
  # not residue from a normal path; it is tampering.
  local n
  n=$(grep -cE '^## 인가$' "$MANIFEST" || true)
  [ "$n" = "1" ] || die "매니페스트에 「## 인가」 절이 ${n}개 — 정확히 하나여야 합니다"

  # 3 — origin-worktree tie-break, FAIL-OPEN by design (see the note above).
  local ow
  ow=$(manifest_hdr_field 'origin-worktree')
  if [ -n "$ow" ] && [ "$ow" != "$(git rev-parse --show-toplevel 2>/dev/null)" ]; then
    die "매니페스트 origin-worktree= 가 현재 워크트리와 다릅니다: $ow"
  fi

  # 4 — target preflight. A declared repo set with no verification leaves the
  # silent-`.` fallback alive, so this is a hard stop BEFORE the driver starts.
  local a wt cg
  for a in $(target_aliases); do
    wt=$(target_field "$a" '메인 워크트리')
    cg=$(target_field "$a" '공통 git 디렉터리')
    [ -d "$wt" ] || die "대상 '$a' 의 메인 워크트리가 없습니다: $wt"
    [ "$(cd "$wt" && git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" = "$cg" ] \
      || die "대상 '$a' 의 공통 git 디렉터리가 선언값과 다릅니다: $cg"
    # 7 — every cutpoint token is in the vocabulary.
    cutpoint_index "$(target_field "$a" '절단점')" >/dev/null \
      || die "대상 '$a' 의 절단점 토큰이 어휘에 없습니다"
  done

  # 5·6 — the two digests that are computed, recorded, AND compared. Without
  # this the fields ship in the state the binding-surface digest was in.
  [ "$(canonical_targets | shasum -a 256 | cut -d' ' -f1)" = "$(manifest_field '대상' '대상 맵 다이제스트')" ] \
    || die "대상 맵 다이제스트가 대상 행과 일치하지 않습니다"
  # `구속 다이제스트` is optional ONLY while a manifest written before this field
  # existed can still be read; when present it is compared, and a present-but-
  # wrong value is a hard stop. An absent one is reported rather than passed
  # over in silence, because "not checked" and "checked and fine" must not look
  # the same in the log.
  local bd
  bd=$(manifest_field '인가' '구속 다이제스트')
  if [ -n "$bd" ]; then
    [ "$(binding_set_bytes | shasum -a 256 | cut -d' ' -f1)" = "$bd" ] \
      || die "구속 다이제스트가 얼린 집합과 일치하지 않습니다 — 목표·종료 절·대상·룰 설정·사전 인가·마감 중 하나가 움직였습니다"
  else
    warn "매니페스트에 구속 다이제스트가 없습니다 — 얼린 집합을 대조하지 않고 진행합니다"
  fi

  # 8 — absolute deadline. `없음` is refused: a comment saying "required" means
  # nothing while a validator accepts the absent value.
  local dl
  dl=$(manifest_field '인가' '벽시계 마감')
  [ -n "$dl" ] && [ "$dl" != "없음" ] || die "벽시계 마감이 없습니다 — 「없음」은 받지 않습니다"
  printf '%s' "$dl" | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}' >/dev/null \
    || die "벽시계 마감이 절대 타임스탬프로 파싱되지 않습니다: $dl"

  # 9 — an apply with no probe is refused at kickoff.
  if [ "$(manifest_field '요소' '적용 주체')" = "파이프라인" ]; then
    [ -n "$(manifest_field '요소' '적용 지점')" ] || die "적용 주체가 파이프라인인데 적용 지점이 없습니다"
    [ -n "$(manifest_field '요소' '적용 프로브')" ] || die "적용 주체가 파이프라인인데 적용 프로브가 없습니다"
  fi

  log "매니페스트 검사 통과 — run-id=$RUN_ID anchor=$ANCHOR_KIND:$ANCHOR_KEY 대상 $(target_aliases | grep -c .)개"
}

# Manifest-derived paths. `BASE` from the declared worktree, everything else
# from the run id — which is what closes the aliasing of two runs of one
# document onto one ledger, one report, one worktree path and one session uuid.
derive_paths_from_manifest() {
  BASE=$(manifest_hdr_field 'origin-worktree')
  [ -n "$BASE" ] || BASE=$(git rev-parse --show-toplevel)
  BASE=$(dirname "$(cd "$BASE" && git rev-parse --path-format=absolute --git-common-dir)")
  GRANT="$BASE/docs/pipeline-grant/$RUN_ID.md"
  LEDGER="$BASE/docs/pipeline-run/$RUN_ID.md"
  DOC=$(manifest_field '요소' '설계 문서')
  case "$DOC" in ''|'(없음)') DOC=""; DOC_KEY="$ANCHOR_KEY"; DOC_DIR="$BASE" ;;
    *) DOC="$BASE/$DOC"; DOC_KEY=$(manifest_field '요소' '설계 문서'); DOC_DIR=$(dirname "$DOC") ;;
  esac
  SLUG="$RUN_ID"
  # Document identity, derived by the SAME rule the document entry uses, so the
  # audit sidecar resolves to one location no matter which entry started the
  # run. Empty when the run names no document — the audit stage has nothing to
  # read then, and its predicate refuses rather than globbing a bare directory.
  case "$DOC_KEY" in
    ''|'(없음)') DOC_SLUG="" ;;
    *)           DOC_SLUG=$(printf '%s' "${DOC_KEY%.md}" | tr '/' '-') ;;
  esac
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
# NORMALIZED before hashing. Unnormalized, this digest moved on whitespace alone,
# which disqualified it as a comparison predicate — a re-convergence that only
# re-wrapped a paragraph would read as a moved binding surface. The three
# normalizations below were measured against five cases: the three no-op edits
# stay invariant, a binding-tier edit still moves it (with a non-empty diff, so
# the invariance is not vacuous), and a moved section still moves it.
binding_digest() {
  awk '
    /^## / { insec = ($0 ~ /^## 구현 시 검증 항목[[:space:]]*$/) ? 1 : 0 }
    insec && /^(- )?(\*\*검증 등급\*\*|검증 등급): / { next }
    insec && /^(- )?(\*\*구현 시 검증 기록\*\*|구현 시 검증 기록): / { next }
    { print }
  ' "$DOC" \
    | tr -d '\r' \
    | sed 's/[[:space:]]*$//' \
    | awk '{ if ($0 == "") { blank = 1; next } if (blank && seen) print ""; blank = 0; seen = 1; print }' \
    | shasum -a 256 | cut -d' ' -f1
}

whole_digest() { shasum -a 256 "$DOC" | cut -d' ' -f1; }

# ---------------------------------------------------------------------------
# Workflow declaration — `## 구현 슬라이싱`
#
# The heading is not new: it is already a trigger of the planner's author-
# grouping rule and it already exists in the corpus. What was missing was
# FIELDS, and the measured consequence of that absence was stark — two
# documents differing by exactly one heading line produced 1 segment and 10.
#
# The declaration is parsed by the SHELL, not judged by the model. The planner
# was observed recognising an author grouping and then overriding it on safety
# grounds, so a field-complete declaration bypasses the planning dispatch
# entirely; only the paths that still rely on judgement carry a gate.
#
# ONE SCANNER, TWO CONSUMERS. Existence and body extraction must come from the
# same pass. Deciding existence with a bare grep and extracting the body with a
# fence-aware pass puts a document that merely EXPLAINS the grammar into
# "exists: true, body: empty" — which routes to the ungoverned branch and parks
# a document that never declared a slicing at all. The files that will carry
# this explanation include this driver's own contract docs, so it is not
# hypothetical.
# ---------------------------------------------------------------------------

# Emit the document with every fenced span blanked out, preserving line numbers.
#
# Three rules, and each of them is load-bearing:
#   1. lines inside a fence are invisible to the parse — HEADINGS AND FIELD
#      LINES ALIKE. Skipping only headings leaves "exists but empty".
#   2. a fence closes per CommonMark: same character, at least as long, and no
#      info string. So ``` does not close a ```` span, and ```text does not
#      close a ``` span. A parser that toggles on every fence marker falls out
#      of the span at a nested one — and the line that lands in that window is
#      the user's verbatim free text, the least trustworthy content in the
#      system and the only place an unauthorised heading could appear.
#   3. an UNCLOSED fence is a hard error, never a silent demotion. Everything
#      after it would read as "inside", so a declaration would quietly become
#      an ungoverned document — the exact failure this grammar exists to close.
defenced() {
  awk '
    function fence_char(l,   c) { c = substr(l, 1, 1); return (c == "`" || c == "~") ? c : "" }
    function fence_len(l, c,   n) { n = 0; while (substr(l, n + 1, 1) == c) n++; return n }
    {
      line = $0
      probe = line; sub(/^[ \t]+/, "", probe)
      ch = fence_char(probe)
      if (ch != "") {
        n = fence_len(probe, ch)
        if (n >= 3) {
          info = substr(probe, n + 1); gsub(/[ \t]/, "", info)
          if (!inf) { inf = 1; fch = ch; flen = n; print ""; next }
          else if (ch == fch && n >= flen && info == "") { inf = 0; print ""; next }
        }
      }
      if (inf) { print "" } else { print line }
    }
  ' "$1"
}

# Unclosed-fence detection is its OWN pass, not a status smuggled out of the
# scanner. A pipeline's exit status is the rightmost command's, so an `awk`
# that exited 3 behind a `grep` reports grep's status and the hard error is
# silently downgraded to "no declaration" — which is precisely the quiet
# demotion this rule exists to prevent. Measured: it downgraded on the first
# try.
fence_unclosed() {
  awk '
    function fence_char(l,   c) { c = substr(l, 1, 1); return (c == "`" || c == "~") ? c : "" }
    function fence_len(l, c,   n) { n = 0; while (substr(l, n + 1, 1) == c) n++; return n }
    {
      probe = $0; sub(/^[ \t]+/, "", probe)
      ch = fence_char(probe)
      if (ch == "") next
      n = fence_len(probe, ch); if (n < 3) next
      info = substr(probe, n + 1); gsub(/[ \t]/, "", info)
      if (!inf) { inf = 1; fch = ch; flen = n }
      else if (ch == fch && n >= flen && info == "") { inf = 0 }
    }
    END { exit (inf ? 0 : 1) }
  ' "$1"
}

# Existence, via the same scanner.
slicing_present() {
  local doc="$1" n
  fence_unclosed "$doc" && return 3
  n=$(defenced "$doc" | grep -cE '^## 구현 슬라이싱$' || true)
  [ "$n" -le 1 ] || return 2   # ambiguous: two declarations, hard error
  [ "$n" = "1" ]
}

# Body of the declaration, via the same scanner.
slicing_body() {
  defenced "$1" | awk '/^## 구현 슬라이싱$/{inb=1; next} inb && /^## /{exit} inb {print}'
}

slice_ids() { slicing_body "$1" | sed -n 's/^### 슬라이스 \([A-Za-z0-9][A-Za-z0-9]*\).*/\1/p'; }

slice_field() {
  # slice_field <doc> <id> <key>
  slicing_body "$1" | awk -v id="### 슬라이스 $2" -v key="$3" '
    index($0, id) == 1 { inb = 1; next }
    inb && /^### /     { exit }
    inb { pat = "^\\*\\*" key "\\*\\*: "; if ($0 ~ pat) { sub(pat, "", $0); print; exit } }
  '
}

# `슬라이스 수` is a CHECKSUM, not an input: it is derived from the count of
# blocks whose cutpoint index is at or above `PR`, so the two cannot disagree.
# A mismatch means the declaration was truncated or misnumbered, which is worth
# stopping for.
slicing_pr_count() {
  local doc="$1" id c n=0
  for id in $(slice_ids "$doc"); do
    c=$(cutpoint_index "$(slice_field "$doc" "$id" '절단점')" 2>/dev/null) || continue
    [ "$c" -ge "$(cutpoint_index PR)" ] && n=$((n + 1))
  done
  printf '%s' "$n"
}

# Field completeness. Six are required of every block; three more are required
# only when the block declares an apply.
#
# The required-ness of the apply trio keys on the APPLY DECLARATION, not on the
# cutpoint. Keying it on the cutpoint put `적용 주체: 사람` — whose own meaning
# is "the pipeline stops at merge and hands the command to a person" — outside
# its own domain, so the handover the grammar exists to express became
# inexpressible. The two axes answer different questions: the cutpoint says how
# far the PIPELINE may go, the apply command says whether this slice HAS an
# apply at all.
slicing_fields_ok() {
  local doc="$1" id v f
  for id in $(slice_ids "$doc"); do
    for f in 스킬 레포 '선언 파일' 선행 절단점; do
      [ -n "$(slice_field "$doc" "$id" "$f")" ] || { warn "슬라이스 $id: 필수 필드 '$f' 없음"; return 1; }
    done
    cutpoint_index "$(slice_field "$doc" "$id" '절단점')" >/dev/null \
      || { warn "슬라이스 $id: 절단점 토큰이 어휘에 없음"; return 1; }
    # `리뷰 정책` is OPTIONAL and defaults to `선리뷰후머지`. The cutpoint says
    # how far a slice may go and cannot say when review happens, which is a
    # different axis entirely — a slice may be authorized to merge and still owe
    # its review afterwards.
    v=$(slice_field "$doc" "$id" '리뷰 정책')
    case "$v" in
      ''|선리뷰후머지|선머지후리뷰|리뷰없음) : ;;
      *) warn "슬라이스 $id: 리뷰 정책 토큰이 어휘에 없음: '$v'"; return 1 ;;
    esac
    # `리뷰없음` is expressible only against a matching pre-authorization entry,
    # which is what stops a router from choosing it for itself. `선머지후리뷰`
    # does not remove the obligation, it defers it — the gate leaves a
    # `리뷰 의무` row and the run cannot terminate while one is `미이행`.
    if [ "$v" = "리뷰없음" ]; then
      [ -n "${MANIFEST:-}" ] && grep -q '`사전 인가`' "$MANIFEST" 2>/dev/null \
        || { warn "슬라이스 $id: 리뷰없음 은 대응하는 사전 인가 항목이 있을 때만 표현 가능"; return 1; }
    fi
    v=$(slice_field "$doc" "$id" '적용 명령')
    if [ -n "$v" ]; then
      [ -n "$(slice_field "$doc" "$id" '적용 주체')" ] || { warn "슬라이스 $id: 적용 명령이 있는데 적용 주체가 없음"; return 1; }
      [ "$(slice_field "$doc" "$id" '적용 주체')" != "파이프라인" ] \
        || [ -n "$(slice_field "$doc" "$id" '폭발 반경')" ] \
        || { warn "슬라이스 $id: 적용 주체가 파이프라인인데 폭발 반경이 없음"; return 1; }
    fi
    # The composition rule the planner used to own and the shell must now
    # enforce: README is generated from skill frontmatter and gated for
    # staleness, so the sharing is real but invisible in prose.
    case "$(slice_field "$doc" "$id" '선언 파일')" in
      *SKILL.md*) case "$(slice_field "$doc" "$id" '선언 파일')" in
                    *README.md*) : ;;
                    *) warn "슬라이스 $id: SKILL.md 를 선언하면서 README.md 를 선언하지 않음"; return 1 ;;
                  esac ;;
    esac
  done
  return 0
}

# The three branches.
#   미통치   — no declaration. Today's path: dispatch the planner, no gate.
#   선언통치 — declaration complete. The shell builds the plan and the planner
#              is NOT dispatched, so there is no judgement to gate.
#   선언불완전 — a real author-grouping signal that is mechanically incomplete.
#              Dispatch the planner and park on a false adoption flag.
slicing_branch() {
  local doc="$1" rc
  slicing_present "$doc"; rc=$?
  case "$rc" in
    3) die "선언 파스: 닫히지 않은 펜스 — 이후 전부가 「안」으로 읽혀 선언이 조용히 강등된다" ;;
    2) die "선언 파스: 펜스 밖 「## 구현 슬라이싱」 매치가 둘 이상 — 모호한 문서를 조용히 하나로 고르지 않는다" ;;
    1) printf '미통치'; return 0 ;;
  esac
  if slicing_fields_ok "$doc"; then printf '선언통치'; else printf '선언불완전'; fi
}

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

# Display form vs stored token. These are NOT the same string and the difference
# is load-bearing: the human-facing ladder reads `머지 후 후속 착수` with spaces
# while the stored token is `머지후착수`. A grant written from the display form
# therefore matched nothing, `cutpoint_index` answered 0, and `authorized()`
# silently denied EVERY act — the most permissive grant authorized nothing.
# The mapping is explicit so the two forms can never drift apart again.
cutpoint_display() {
  case "$1" in
    커밋)       printf '커밋' ;;
    브랜치)     printf '브랜치' ;;
    push)       printf 'push' ;;
    PR)         printf 'PR' ;;
    머지)       printf '머지' ;;
    배포)       printf '배포' ;;
    머지후착수) printf '머지 후 후속 착수' ;;
    *)          return 1 ;;
  esac
}

# Accepts either form and returns the stored token; non-zero on anything else.
cutpoint_token() {
  local want="$1" c
  for c in $CUTPOINTS; do
    [ "$c" = "$want" ] && { printf '%s' "$c"; return 0; }
    [ "$(cutpoint_display "$c")" = "$want" ] && { printf '%s' "$c"; return 0; }
  done
  return 1
}

# `0` is no longer a sentinel for "unknown" — an unrecognized cutpoint is a HARD
# ERROR, not a silent denial. A typo in a grant used to cost the whole night's
# output while reporting nothing; now it stops at the point of the typo.
#
# The error is signalled by the RETURN STATUS, not by calling `die` here. This
# function is always invoked inside `$( )`, and `exit` from a command
# substitution kills only that subshell — the caller would carry on with an
# empty string and fall straight back into the silent denial this replaces.
# Callers turn the non-zero status into the hard stop.
cutpoint_index() {
  local want="$1" tok i=0 c
  tok=$(cutpoint_token "$want") || {
    warn "미인식 절단점 토큰: '${want}' — 허용 토큰: ${CUTPOINTS}"
    return 1
  }
  for c in $CUTPOINTS; do
    i=$((i + 1))
    [ "$c" = "$tok" ] && { printf '%s' "$i"; return 0; }
  done
  return 1
}
authorized() {
  # authorized <act> — true when the act is at or below the granted cutpoint.
  # Both lookups hard-stop on an unrecognized token rather than returning 0, so
  # this comparison never runs on a silently-denied value. `die` sits HERE, in
  # the parent shell, because that is the only place it can actually stop the
  # run — see the note on `cutpoint_index`.
  local act_i grant_i granted
  act_i=$(cutpoint_index "$1") || die "인가 판정 불가 — 행위 토큰 '$1'이 절단점 어휘에 없다"
  granted=$(grant_field "$RUN_ID" '권한 절단점')
  grant_i=$(cutpoint_index "$granted") \
    || die "인가 판정 불가 — 인가 기록의 절단점 '${granted}'이 어휘에 없다 (표시 문면과 저장 토큰을 확인할 것)"
  [ "$act_i" -le "$grant_i" ]
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
  # The driver has no tool inventory, so a push adapter would be reachable only
  # by dispatching a stage whose ENTIRE delegated purpose is the notification
  # and whose payload the driver wrote. A working stage that also notifies is
  # forbidden without exception.
  #
  # THAT ADAPTER IS NOT SEATED, and the reason is recorded rather than deferred:
  # the shared operating rules forbid a spawned agent from deciding whether a
  # banner reaches the user, and a notification-only stage is a spawned agent.
  # The seat is real and a future in-process implementation drops into it; what
  # is NOT claimed is that the current run can wake a sleeping user.
  #
  # The consequence is stated plainly so nothing downstream assumes otherwise:
  # **the push path may not reach a sleeping user at all.** That is survivable
  # only because delivery confirmation was never in this seat's contract — the
  # morning report is the source of truth, and every notify_send below writes
  # there FIRST and treats the banner as a courtesy.
  NOTIFY_ADAPTER="report-only"
  log "알림 어댑터: $NOTIFY_ADAPTER (푸시 좌석 미착석 — 아침 보고서가 진실의 출처)"
}

notify_send() {
  # Report FIRST, banner second — including for the immediate-call events. The
  # ordering is the contract, not a convenience: this seat provides no delivery
  # confirmation, so a banner that is written before the report can be the only
  # record of an event nobody ever saw.
  #
  # fail-open, always: a missed banner is acceptable, a halted workflow is not.
  local title="$1" body="$2"
  report_append "알림" "$title — $body"
  case "$NOTIFY_ADAPTER" in
    report-only|none) return 0 ;;
  esac
  warn "알림 어댑터 '$NOTIFY_ADAPTER' 가 배선돼 있지 않습니다 — 보고서에만 남기고 계속합니다"
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
# The falsifiability clause, made mechanical. Every park NAMES its scope and its
# cause, and a park that cannot name both is not a decision — it is a bug. So an
# unrecognised value is a hard error rather than a quiet default: these arguments
# are literals written by this driver, which makes a bad one a code defect a test
# catches, never a runtime input.
#
#   act  — a terminal act is blocked (unauthorized, a failed check, a protection
#          rule, an act budget). Stops THAT ACT and nothing else; the segment's
#          artifacts survive and it is reported as 완성-미착지.
#   cone — a premise downstream work stands on has been refuted (no artifact, a
#          crash, an invalid review, the cycle budget, a file-set escape, an
#          identity's park rung). Stops what depends on that premise; siblings
#          not derived from it keep running.
#   run  — the run cannot judge the state a later irreversible act would
#          transform, or its own anchor is invalid (audit failure, plan failure,
#          an apply of unknown outcome). Stops the DECLARED blast radius.
#
# The anti-rule is what makes this bite: A BLOCKED ACT NEVER ESCALATES to a cone
# or a run stop, and the absence of an answer is not a cause. Without it one
# cutpoint typo parks every segment and the night produces nothing; with it every
# segment reaches PR and N blocked merges pile up in the morning report next to
# the commands that finish them.
readonly PARK_SCOPES="act cone run"
readonly PARK_CAUSES="막힘 무효화 불명"

park() {
  local target="$1" scope="$2" cause="$3" reason="$4" observed="$5" recmd="${6:-(없음)}"
  case " $PARK_SCOPES " in *" $scope "*) : ;; *) die "park 스코프를 지명하지 못했다: '$scope' (대상 $target)" ;; esac
  case " $PARK_CAUSES " in *" $cause "*) : ;; *) die "park 원인을 지명하지 못했다: '$cause' (대상 $target)" ;; esac
  ledger_row 'blocked' "대상=$target" "스코프=$scope" "원인=$cause" \
    "사유=$reason" "관측=$observed" "재개 명령=$recmd"
  report_append "보류" "$target — [$scope/$cause] $reason — $observed"
  log "park: $target ($scope/$cause · $reason)"
}

# ---------------------------------------------------------------------------
# Design-document lock. Advisory and DETECTING, not preventing: correctness
# still rests on the composition rule that puts every residual verification item
# in ONE segment. What this buys is a loud failure instead of a silent lost
# update.
# ---------------------------------------------------------------------------
with_doc_lock() {
  local rc=0 tool
  tool=$(lock_tool)
  [ -n "$tool" ] || { warn "이 플랫폼에는 선택된 잠금 도구가 없습니다"; return 1; }
  "$tool" -k -t 0 "$RUN_DIR/designdoc.lock" "$@" || rc=$?
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

# ---------------------------------------------------------------------------
# The repo SET. `main_root()` above derives ONE repository from where the design
# document happens to sit; a run may span several, and the set is DECLARED and
# VERIFIED rather than derived. The grounds are not planner capability, they are
# three facts: a design document contains no absolute path, the single inference
# available is the very convention this replaces, and a worktree-vs-repository
# confusion is invisible to inference while being present in this tree today.
#
# Every lookup below is keyed by ALIAS, and the alias is what survives a
# re-plan: slugs and paths are attributes of a target, the alias is its name.
#
# With no manifest the set is a singleton and the home alias resolves through
# `main_root()`. That is the legacy single-repo run, and it is the ONLY case
# where an undeclared repository is tolerated — under a manifest, a segment
# naming a repository the manifest does not declare gets no worktree at all.
# ---------------------------------------------------------------------------
home_alias() {
  local a
  [ -n "$MANIFEST" ] || { printf '.'; return 0; }
  for a in $(target_aliases); do
    [ "$(target_field "$a" '홈')" = "예" ] && { printf '%s' "$a"; return 0; }
  done
  target_aliases | sed -n '1p'
}

alias_root() {
  local a="$1" wt
  { [ -z "$MANIFEST" ] || [ "$a" = "." ]; } && { main_root; return 0; }
  wt=$(target_field "$a" '메인 워크트리')
  [ -n "$wt" ] || return 1
  dirname "$(cd "$wt" && git rev-parse --path-format=absolute --git-common-dir)"
}

# The `-R` argument. Deriving it from the origin URL is the fallback, not the
# contract: under a manifest the slug is declared, and `gh` inheriting the cwd
# is the defect this replaces — measured, `-R B` from inside repo A returns B's
# pull requests while the same call without it returns A's.
alias_slug() {
  local a="$1" s root
  if [ -n "$MANIFEST" ] && [ "$a" != "." ]; then
    s=$(target_field "$a" '원격 슬러그')
    [ -n "$s" ] && { printf '%s' "$s"; return 0; }
  fi
  root=$(alias_root "$a") || return 1
  ( cd "$root" && git config --get remote.origin.url 2>/dev/null ) \
    | sed -E 's#^git@[^:]*:##; s#^https?://[^/]*/##; s#\.git$##'
}

alias_for_slug() {
  local want="$1" a
  [ -n "$want" ] || { home_alias; return 0; }
  for a in $(target_aliases); do
    [ "$(target_field "$a" '원격 슬러그')" = "$want" ] && { printf '%s' "$a"; return 0; }
  done
  return 1
}

# The declared repository of a planned segment. Shell-built plans carry the
# declaration's `**레포**` slug; planner-built plans leave it empty and inherit
# the home alias, which is what keeps a single-repo run byte-identical to before.
plan_repo() {
  local v
  v=$(awk -F'\t' -v s="$1" '$1 == s { print $2; exit }' "$RUN_DIR/plan.tsv" 2>/dev/null \
    | tr -d '`' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
  plan_uncell "$v"
}

seg_alias() {
  local slug
  slug=$(plan_repo "$1")
  [ -n "$slug" ] || { home_alias; return 0; }
  [ -n "$MANIFEST" ] || { home_alias; return 0; }
  alias_for_slug "$slug"
}

seg_root() { alias_root "$(seg_alias "$1")"; }
seg_slug() { alias_slug "$(seg_alias "$1")"; }

# Every `gh` call goes through here, and it does two things the bare calls did
# not. It passes `-R`, which beats cwd inheritance (measured: from inside repo A,
# `-R B` returns B's pull requests and the same call without it returns A's), and
# it CAPTURES stderr instead of sending it to /dev/null. The old form turned a
# not-a-repository error into an empty pull-request number, so the driver parked
# with "PR을 찾지 못함" and the actual cause was gone.
GH_STDERR=""
gh_q() {
  local slug="$1"; shift
  local errf out rc
  errf="${RUN_DIR:-${TMPDIR:-/tmp}}/gh.err"
  out=$(gh -R "$slug" "$@" 2>"$errf"); rc=$?
  GH_STDERR=$(cat "$errf" 2>/dev/null || printf '')
  [ -z "$GH_STDERR" ] || warn "gh -R $slug $*: $GH_STDERR"
  printf '%s' "$out"
  return "$rc"
}

wt_path() {
  local seg="$1" root repo
  root=$(seg_root "$seg") || return 1
  repo=$(basename "$root")
  printf '%s/%s%s%s-%s' "$(dirname "$root")" "$repo" "$WORKTREE_INFIX" "$SLUG" "$seg"
}

# Explicit cwd, always. Run from a non-repository directory `git rev-parse`
# fails and this returned `none` BOTH times, so the before/after comparison
# matched and the attribution guard passed VACUOUSLY — the guard reported
# success in exactly the situation it exists to catch.
stash_ref() {
  local root="$1"
  ( cd "$root" 2>/dev/null && git -c core.pager=cat rev-parse --verify refs/stash 2>/dev/null ) \
    || printf 'none'
}

wt_create() {
  local seg="$1" branch="$2" p base al
  al=$(seg_alias "$seg") || al=""
  # Refusing an undeclared alias is what makes the declared set mean anything.
  # Without it the failure shows up as a QUIET WORKTREE LEAK: a tree created
  # under some other repository's parent, never recorded against a target, and
  # therefore never torn down.
  [ -n "$al" ] || {
    warn "$seg: 매니페스트에 선언되지 않은 레포 '$(plan_repo "$seg")' — 워크트리를 만들지 않는다"
    return 1
  }
  p=$(wt_path "$seg") || return 1
  [ -d "$p" ] && { printf '%s' "$p"; return 0; }
  # Branch from the RESOLVED BASE, never from the literal `HEAD`.
  #
  # This is the actual branch point and not a consequence of the two fixes
  # above: `HEAD` is the main worktree's checkout tip, and since this driver
  # deliberately does not fast-forward that tree, the tip does not move for the
  # whole run. Fixing only the fetch and the ref resolution would still leave
  # segment k+1 branching from a commit without k's merge in it.
  base_fetch "$al"
  base=$(base_sha "$al") || { warn "베이스 sha 해소 실패 — 워크트리를 만들지 않는다"; return 1; }
  local root; root=$(alias_root "$al")
  ( cd "$root" && git worktree add -b "$branch" "$p" "$base" >/dev/null 2>&1 ) \
    || ( cd "$root" && git worktree add "$p" "$branch" >/dev/null 2>&1 ) \
    || { warn "워크트리 생성 실패: $p"; return 1; }
  printf '%s' "$p"
}

wt_remove() {
  # THREE conditions, all required. (1) is the substantive guarantee; (2) is
  # defence in depth against a corrupted ledger; (3) is the failure mode that
  # only exists at N>1 — a ledger row written for a DIFFERENT alias passes the
  # first two, because both of them are properties of the string rather than of
  # the repository it belongs to. Never --force: the tree may hold the only
  # copy of an uncommitted change.
  local seg="$1" p recorded root
  p=$(wt_path "$seg") || { warn "철거 거부 — 세그먼트의 레포를 해소할 수 없습니다: $seg"; return 1; }
  recorded=$(grep -E "^- \`segment\`" "$LEDGER" 2>/dev/null | grep -F "id=$seg" | tr '|' '\n' | sed -n 's/^ *워크트리=//p' | tail -1)
  if [ -z "$recorded" ] || [ "$recorded" != "$p" ]; then
    warn "철거 거부 — 이 런의 원장에 생성 시점 값으로 없습니다: $p"; return 1
  fi
  case "$p" in *"$WORKTREE_INFIX"*) : ;; *) warn "철거 거부 — 예약 인픽스 부재: $p"; return 1 ;; esac
  root=$(seg_root "$seg") || { warn "철거 거부 — 레포 루트 해소 실패: $seg"; return 1; }
  case "$p" in
    "$(dirname "$root")"/*) : ;;
    *) warn "철거 거부 — 해당 별칭의 레포 루트 아래가 아닙니다: $p"; return 1 ;;
  esac
  ( cd "$root" && git worktree remove "$p" >/dev/null 2>&1 && git worktree prune >/dev/null 2>&1 ) \
    || { warn "철거 실패(보고만, 강제 삭제하지 않음): $p"; return 1; }
  return 0
}

stash_attribution_check() {
  # An absent refs/stash is a normal "no stash" value, not a violation — this
  # repository has carried one since before the pipeline existed, so a
  # "there must be no stash" check would fail on day one, forever.
  local before="$1" seg_branch="$2" root="$3" after
  after=$(stash_ref "$root")
  [ "$before" = "$after" ] && return 0
  local top
  top=$( cd "$root" 2>/dev/null && git stash list 2>/dev/null | sed -n '1p' )
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
  # session_uuid <stage-id> [attempt] — derived, never stored.
  #
  # Shaped as a real UUID because `--session-id` rejects anything else: a bare
  # 32-hex digest is refused with "Must be a valid UUID" (measured). Shaping the
  # digest keeps the value derivable — which is the whole point, since nothing
  # records it and the transcript has to be findable again from the stage id
  # alone.
  local h
  h=$(printf '%s|%s|%s' "$DOC_KEY" "$1" "${2:-1}" | shasum -a 256 | cut -c1-32)
  printf '%s-%s-%s-%s-%s' "${h:0:8}" "${h:8:4}" "${h:12:4}" "${h:16:4}" "${h:20:12}"
}

# The progress oracle's file. The session transcript GROWS while a stage runs;
# the `--output-format json` envelope does not — it is written once, at exit.
# Polling the envelope therefore reported "silent" for every healthy stage from
# its very first poll, which is what refuted the consecutive-poll item: no count
# can separate a normal resume from a stall when the signal never moves at all.
transcript_path() {
  # The assignments are on separate lines ON PURPOSE. `local a="$1" b="$a"` is a
  # trap: the builtin's words are all expanded before `local` runs, so `$a` is
  # read from the OUTER scope — unset here, which under `set -u` aborts the
  # function. It aborted quietly through a caller's `|| printf ''`, and the
  # visible symptom was that every healthy stage looked permanently silent.
  local stage="$1"
  local cachef uuid p
  cachef="$RUN_DIR/$stage.transcript"
  if [ -f "$cachef" ]; then p=$(cat "$cachef"); [ -f "$p" ] && { printf '%s' "$p"; return 0; }; fi
  uuid=$(session_uuid "$stage")
  p=$(find "$(resolve_account)/projects" -name "$uuid.jsonl" 2>/dev/null | sed -n '1p')
  [ -n "$p" ] || return 1
  printf '%s\n' "$p" > "$cachef"
  printf '%s' "$p"
}

stage_spawn() {
  # stage_spawn <stage-id> <cwd> <prompt> [extra-cli-args...] — returns at once.
  # Spawn and collect are separate so the driver can hold a stage open while it
  # does something else with it — the stall path polls a live stage rather than
  # blocking on it. The
  # liveness oracle for those is `kill -0` on the recorded pid, not `wait -n`:
  # that builtin does not exist on the interpreter floor, and the polling form
  # is the oracle the resume table already specifies, so using it here avoids a
  # second, divergent liveness path.
  local stage="$1" cwd="$2" prompt="$3"; shift 3
  local cfg out pid pgid
  cfg=$(resolve_account)
  out="$RUN_DIR/log/$stage.json"

  [ -n "$CLI_BIN" ] || { warn "CLI 바이너리를 찾지 못했습니다"; return 127; }
  rm -f "$RUN_DIR/$stage.rc"

  # The settings variant is chosen by stage KIND, and an unrecognized stage id
  # falls to `generic` rather than to "no settings" — the whole point of the
  # wrapper's hard stop is that there is no such thing as a stage launched
  # without them.
  local plugin_dir stage_settings kind
  plugin_dir=$(cd "$ORCH_DIR/.." && pwd)
  case "$stage" in
    *design-audit*|*audit*) kind=audit ;;
    *reconverge*)           kind=reconverge ;;
    *design*)               kind=design ;;
    *implement*)            kind=implement ;;
    *review*)               kind=review ;;
    *)                      kind=generic ;;
  esac
  stage_settings="$RUN_DIR/settings/$kind.json"
  if [ ! -f "$stage_settings" ]; then
    warn "스테이지 설정이 없습니다: $stage_settings — 게이트가 런 개시 시 만듭니다"
    return 78
  fi

  # `set -m` makes the child the leader of its own process group, so the whole
  # tree is reclaimable with `kill -- -$pgid`. Without it the "group" silently
  # becomes the CALLER's, which is why the pgid is read back before it is
  # recorded rather than assumed.
  # `--session-id` is passed so the transcript is FINDABLE — that file is the
  # progress oracle, and without a caller-chosen id there is no way to locate
  # it. The value is derived rather than stored, so a restarted driver
  # re-derives the same one.
  set -m
  # The run id and the two sidecar paths are HANDED to the stage rather than
  # left for it to re-derive. Every unattended arm re-derived them from the
  # design document's key, which resolves only when the run was started from a
  # document — a manifest run put the grant at the run id and the arm looked at
  # the document slug, so the two never met and no arm could reach the file it
  # needs to write a halt record. Handing the values down removes the derivation
  # instead of duplicating it; the arms keep their re-derivation as the fallback
  # for a driver that predates these variables.
  # `--plugin-dir` and `--settings` are what close the measured hole: without the
  # first, a slash command resolves to nothing and the stage still exits 0 with
  # `subtype: "success"` and `num_turns: 0`, so the driver reads a hollow success
  # and parks for "no artifact" while the real cause goes unrecorded. Without the
  # second, the stage's hook coverage is not conditional but unconditionally
  # zero. The two hook sources COMPOSE rather than overwrite — measured — so
  # passing both keeps the plugin's existing hooks alive.
  #
  # The wrapper is what carries them, and it is the same wrapper the gate uses
  # for a skill act; a second spawn shape here would be a second place for the
  # injection to go missing.
  ( cd "$cwd" && CLAUDE_CONFIG_DIR="$cfg" CC_PIPELINE_STAGE_ID="$stage" \
      CC_PIPELINE_RUN_ID="$RUN_ID" CC_PIPELINE_GRANT="$GRANT" \
      CC_PIPELINE_LEDGER="$LEDGER" CC_PIPELINE_RUN_DIR="$RUN_DIR" \
      exec nohup /bin/sh "$ORCH_DIR/stage-wrapper.sh" \
        --settings "$stage_settings" \
        --plugin-dir "$plugin_dir" \
        --session-id "$(session_uuid "$stage")" \
        -- -p "$prompt" "$@" \
        > "$out" 2> "$RUN_DIR/log/$stage.err" < /dev/null ) &
  pid=$!
  set +m

  pgid=$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')
  # Recorded BEFORE any wait, so a driver that dies mid-stage leaves a handle
  # its successor can find. Both go to the volatile directory only.
  printf '%s\n' "$pid"  > "$RUN_DIR/$stage.pid"
  printf '%s\n' "$pgid" > "$RUN_DIR/$stage.pgid"
  return 0
}

stage_alive() {
  local f="$RUN_DIR/$1.pid"
  [ -f "$f" ] || return 1
  kill -0 "$(cat "$f")" 2>/dev/null
}

stage_collect() {
  # Reap one finished stage and record its exit status.
  local stage="$1" pid rc=0
  [ -f "$RUN_DIR/$stage.pid" ] || return 0
  pid=$(cat "$RUN_DIR/$stage.pid")
  wait "$pid" || rc=$?
  rm -f "$RUN_DIR/$stage.pid" "$RUN_DIR/$stage.pgid"
  printf '%s' "$rc" > "$RUN_DIR/$stage.rc"
  return 0
}

stage_wait_all() {
  # stage_wait_all <stage-id>... — poll until every stage has ended, applying
  # the resume verdict to each so a stall is classified rather than waited out.
  local remaining="$*" s still
  while [ -n "$remaining" ]; do
    still=""
    for s in $remaining; do
      if stage_alive "$s"; then
        case "$(resume_verdict "$s")" in
          '진행중')    backoff_reset "$s" ;;
          '침묵중')    : ;;   # quiet, not yet stalled — no decision to make
          '기계가-잠') log "$s: 절전 구간 — 죽이지 않고 재관측" ;;
          '한도-형상')
            # BOTH kill paths carry the guard, and that is the whole point.
            #
            # The allowlist alone protects only the first branch. The second
            # one — the backoff cap — reaches `reap_orphan` without consulting
            # anything, and `reap_orphan` kills a process group on the strength
            # of a COMMENT ("`implement` is re-invocation idempotent"), which is
            # a comment and not a check. Guarding one branch and shipping is
            # strictly worse than shipping neither: today the backoff bug
            # accidentally protects a long apply, and repairing the backoff
            # alone would hand a live SIGKILL to the first stage that goes
            # quiet for a few minutes.
            if kill_permitted "$s" && account_has_headroom; then
              log "$s: 한도 형상 + 여유 계정 — 경계에서 재실행"
              reap_orphan "$s"; backoff_reset "$s"
              continue
            fi
            if backoff_wait "$s"; then still="$still $s"; continue; fi
            if kill_permitted "$s"; then
              warn "$s: 백오프 벽시계 상한 — 경계 멱등이므로 회수 후 경계에서 재실행"
              reap_orphan "$s"; backoff_reset "$s"
            else
              # No signal, at all. The stage keeps running; the run stops
              # depending on it and says so. Sending anything here is the one
              # move that can leave the outside world half-changed with nobody
              # able to say how.
              warn "$s: 백오프 벽시계 상한 — 비멱등 스테이지라 어떤 신호도 보내지 않는다"
              park "$s" act 불명 "외부 상태 불확정" "정체 상한 초과, 스테이지는 계속 돌게 두었다"
              human_reconcile "$s"
            fi
            continue
            ;;
        esac
        still="$still $s"
      else
        stage_collect "$s"; backoff_reset "$s"
      fi
    done
    remaining="$still"
    [ -n "$remaining" ] && sleep 10
  done
}

# Spawn-and-wait in one call, for the stages that have nothing to overlap with.
dispatch_stage() {
  local stage="$1"
  stage_spawn "$@" || return $?
  stage_wait_all "$stage"
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
  # No key selected (non-darwin) means no reading, not a reading of zero. The
  # pipeline is guarded so a missing key cannot abort a caller running under
  # `set -e`.
  [ -n "$1" ] || return 0
  { sysctl -n "$1" 2>/dev/null || true; } \
    | awk -F'[ ,]+' '{for(i=1;i<=NF;i++) if($i=="sec"){print $(i+2); exit}}'
}
boot_epoch() { sysctl_sec "$(boot_source)"; }
wake_epoch() { sysctl_sec "$(wake_source)"; }

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
predicate_audit()       { [ -n "$DOC_SLUG" ] && grep -qF "$LIT_AUDIT_TERMINAL" "$RUN_DIR/log/$1.json" 2>/dev/null && ls "$BASE/docs/design-audit/$DOC_SLUG".reader-*.md >/dev/null 2>&1; }
predicate_review()      { local rp="$1"; [ -f "$rp" ] && grep -qE '^- \*\*발견 요약\*\*: 🔴 P0 [0-9]+건 \| 🟠 P1 [0-9]+건 \| 🟡 P2 [0-9]+건 \| 🟢 P3 [0-9]+건' "$rp"; }
predicate_reconverge()  { grep -qF "$LIT_RECONVERGE_TERMINAL" "$RUN_DIR/log/$1.json" 2>/dev/null; }

predicate_implement() {
  # The git-state ladder, evaluated in the MAIN tree, in cutpoint order. A run
  # that answered in prose and moved on makes no commit, so the ladder is false
  # and the driver never consults the stage's self-report.
  # The root and the slug are the SEGMENT's, not the run's. Evaluating this in
  # the home repository at N>1 asks git about a branch that was never created
  # there, so every segment outside the home repo fails the ladder and parks as
  # a hollow success — a correct implementation reported as having produced
  # nothing.
  local branch="$1" pre_head="$2" seg="$3" root slug
  root=$(seg_root "$seg") || return 1
  slug=$(seg_slug "$seg")
  ( cd "$root" || exit 1
    git rev-parse --verify "$branch" >/dev/null 2>&1 || exit 1
    [ "$(git rev-parse "$branch")" != "$pre_head" ] || exit 1
    authorized push || exit 0
    git rev-parse --verify "refs/remotes/origin/$branch" >/dev/null 2>&1 || exit 1
    authorized PR || exit 0
    [ -n "$(gh_q "$slug" pr list --head "$branch" --json number --jq '.[0].number')" ] || exit 1
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

stage_session_id() {
  # The id the HARNESS assigned, read back from the stage's own stream, with the
  # derived value as the fallback. This is what makes the implementation/review
  # separation rule mean anything: while ids are DERIVED from
  # `run|doc|stage|attempt` they differ by construction, so comparing them is a
  # tautology that passes on every run — including the ones the rule exists to
  # catch.
  local stage="$1" out="$RUN_DIR/log/$stage.json" sid=""
  if [ -f "$out" ]; then
    # `sed -n … ; q` rather than `| head -1`: under `pipefail` an early-exiting
    # reader on the right of a pipe kills the writer with SIGPIPE and the whole
    # pipeline reports failure. The driver has been bitten by that shape before,
    # and its own self-test refuses it.
    sid=$(sed -n '/"session_id":"/{s/.*"session_id":"\([^"]*\)".*/\1/p;q;}' "$out")
  fi
  [ -n "$sid" ] || sid=$(session_uuid "$stage")
  printf '%s' "$sid"
}

stage_parent_id() {
  # The session that spawned it. A FORK inherits its parent, which is what stops
  # a forked session from reviewing its own work by taking a fresh id.
  printf '%s' "${CLAUDE_CODE_SESSION_ID:-${CC_PIPELINE_PARENT_SESSION:-미상}}"
}

classify_termination() {
  # classify_termination <stage> <exit-rc> <predicate-rc>
  local stage="$1" exit_rc="$2" pred_rc="$3"
  if halt_record_present "$stage"; then printf '의도된 park'; return 0; fi
  if [ "$exit_rc" = "0" ] && [ "$pred_rc" = "0" ]; then printf '정상 완료'; return 0; fi
  # A stage that REACHED a decision point and declined to decide for the user is
  # not a stage that attempted nothing, and until this class existed the two
  # were indistinguishable — exit 0, no artifact, no halt record. The measured
  # behaviour is that the correct refusal was punished exactly like a failure:
  # classified hollow, retried once, parked for "no artifact", with the real
  # cause recorded nowhere. Its disposition is a pending approval on that point,
  # never a retry.
  if [ "$exit_rc" = "0" ] && decision_point_reached "$stage"; then
    printf '산출물 없는 정지'; return 0
  fi
  if [ "$exit_rc" = "0" ]; then printf '공허한 성공'; return 0; fi
  printf '크래시'
}

decision_point_reached() {
  # The stage's own ndjson is the evidence. Two traces count, and both are
  # things a stage does only when it has arrived somewhere it cannot proceed
  # from: a ToolSearch naming the question tool, or the tool named in a tool_use
  # the harness could not satisfy.
  #
  # The same signal has a second use the design calls out: a ToolSearch naming
  # `AskUserQuestion` with NO halt record is high-precision evidence that the
  # stage improvised instead. That branch lands as `정상 완료` and is otherwise
  # unobservable, so the detector is worth having even where it does not change
  # the classification.
  # Split, not combined: `local a="$1" b="$a"` expands every word BEFORE the
  # builtin assigns any of them, so `$a` is still unset there. It only appeared
  # to work because the sole caller happened to have a local of the same name in
  # scope, and bash's dynamic scoping made it visible.
  local stage="$1"
  local out="$RUN_DIR/log/$stage.json"
  [ -f "$out" ] || return 1
  grep -q 'AskUserQuestion' "$out" 2>/dev/null
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

  # Progress mark and silence counter are PER STAGE, held on disk.
  #
  # A single shared global was latent under serial traversal and an outright
  # misclassification bug the moment two stages overlap — stage B's byte count
  # would read as "progress" for stage A. Making the counter per-stage requires
  # the mark to be per-stage too: consecutive silence cannot be counted for one
  # stage against a mark another stage moved.
  local tr mt age markf silf sil
  # The TRANSCRIPT, not the result envelope. What this buys and what it does
  # not: transcript bytes separate "running" from "stalled", but they cannot
  # separate "slow but progressing" from "growing without producing" — the
  # shared team protocol hangs an ask rather than a kill on this same signal for
  # exactly that reason. The orchestrator's backstop against the second case is
  # not the oracle but the wall-clock deadline and the run cycle budget.
  tr=$(transcript_path "$stage" 2>/dev/null || printf '')
  # An absent transcript early in a stage is normal — the file appears a few
  # seconds in. An absent transcript on a stage that has been alive for a while
  # is the oracle failing to locate its own signal, which reads exactly like a
  # stall and is how a wiring bug once made every healthy stage look stuck. Say
  # it once rather than letting it masquerade.
  if [ -z "$tr" ] && [ $(( $(now_epoch) - started )) -gt 60 ] \
     && [ ! -f "$RUN_DIR/$stage.notranscript" ]; then
    : > "$RUN_DIR/$stage.notranscript"
    warn "$stage: 60초가 지나도 트랜스크립트를 찾지 못했다 — 진행성 오라클이 신호를 잃었을 수 있다"
  fi
  markf="$RUN_DIR/$stage.mark"; silf="$RUN_DIR/$stage.silent"
  mt=$( [ -n "$tr" ] && [ -f "$tr" ] && wc -c < "$tr" | tr -d ' ' || printf '0' )
  age=$(( $(now_epoch) - started ))

  if [ "$mt" != "$(cat "$markf" 2>/dev/null || printf 'x')" ]; then
    printf '%s\n' "$mt" > "$markf"; printf '0' > "$silf"
    printf '진행중'; return 0
  fi
  if machine_slept_since "$(( $(now_epoch) - age ))"; then printf '기계가-잠'; return 0; fi

  # N CONSECUTIVE silent polls, not one.
  #
  # A single comparison classified any stage that had not written for ten
  # seconds as the limit-exhaustion shape. A `terraform apply` waiting on cloud
  # provisioning is quiet for minutes, so it landed in that classification not
  # as a race but as the DEFAULT, every time, within ten seconds. Requiring a
  # run of silences is what separates "quiet" from "stalled".
  sil=$(cat "$silf" 2>/dev/null || printf '0')
  sil=$((sil + 1)); printf '%s' "$sil" > "$silf"
  if [ "$sil" -lt "$STALL_SILENT_POLLS" ]; then printf '침묵중'; return 0; fi
  printf '한도-형상'
}

# ---------------------------------------------------------------------------
# Limit ladder: rotate at a stage boundary, then wait, then a CAPPED backoff,
# then park. No model downgrade — design and review quality must not drift
# overnight, and the rotation removes most of the incentive anyway.
# ---------------------------------------------------------------------------
backoff_wait() {
  # backoff_wait <stage-id> — sleep one interval, non-zero when the cap is hit.
  #
  # The accumulator is CALLER-OWNED and per-stage, held in the volatile run
  # directory. The previous shape declared `local elapsed=0` on every call and
  # returned unconditionally from inside its own loop, so the accumulator was
  # discarded before it could ever grow and the cap was unreachable: the driver
  # polled at the starting interval forever. **A wait whose accumulator resets
  # is not a wait, it is a hang.**
  #
  # `sleep_s` has to persist for the same reason `elapsed` does, and this is
  # the part that is easy to miss. Fixing only `elapsed` leaves the interval
  # pinned at its starting value, so reaching a six-hour cap takes 360 polls —
  # turning one intended kill decision into 360 of them.
  local stage="$1" f elapsed sleep_s
  f="$RUN_DIR/$stage.backoff"
  if [ -f "$f" ]; then
    read -r elapsed sleep_s < "$f"
  else
    elapsed=0; sleep_s="$BACKOFF_START_SECONDS"
  fi
  [ "$elapsed" -ge "$BACKOFF_WALLCLOCK_CAP_SECONDS" ] && return 1

  log "$stage: 한도 대기 ${sleep_s}s (누적 ${elapsed}s / 상한 ${BACKOFF_WALLCLOCK_CAP_SECONDS}s)"
  sleep "$sleep_s"
  elapsed=$((elapsed + sleep_s))
  sleep_s=$((sleep_s * BACKOFF_FACTOR))
  [ "$sleep_s" -gt "$BACKOFF_MAX_SLEEP_SECONDS" ] && sleep_s="$BACKOFF_MAX_SLEEP_SECONDS"
  printf '%s %s\n' "$elapsed" "$sleep_s" > "$f"

  [ "$elapsed" -ge "$BACKOFF_WALLCLOCK_CAP_SECONDS" ] && return 1
  return 0
}

backoff_reset() { rm -f "$RUN_DIR/$1.backoff"; }

# The single predicate every signalling path must consult.
#
# It exists as its own name rather than as a repeated `boundary_idempotent`
# call because the two kill paths were written by different concerns and
# neither author had a reason to look at the other. A named guard is what makes
# "did you check?" answerable by grep.
kill_permitted() { boundary_idempotent "${1%%:*}"; }

# Surfaced in the morning report, and durable in the ledger, because the state
# it names is one only a human can settle.
human_reconcile() {
  ledger_row 'blocked' "대상=$1" "스코프=act" "원인=불명" \
    "사유=외부 상태 불확정" "관측=사람 대조 필요" "재개 명령=(없음)"
  report_append "사람 대조 필요" "$1 — 정체 상한을 넘겼고 신호를 보내지 않았다. 외부 상태를 사람이 확인해야 한다"
}

boundary_idempotent() {
  case "$1" in
    S2|S4|S5|S8) return 0 ;;   # audit / implement / review / merge
    # S9 is NEVER added here, and the reason is not that it happens to be
    # missing today. An apply is irreversible; "safe to kill at a boundary"
    # would license the driver to interrupt it, and a half-applied state is
    # exactly the outcome this whole stage is built to avoid.
    *)           return 1 ;;   # design, re-convergence and apply are NOT
  esac
}

# ---------------------------------------------------------------------------
# Merge gate (S8).
# ---------------------------------------------------------------------------
merge_gate() {
  local seg="$1" branch="$2" pr slug al
  al=$(seg_alias "$seg") || al=""
  [ -n "$al" ] || { park "$seg" cone 무효화 "게이트 park" "세그먼트의 레포가 매니페스트에 선언되지 않음"; return 1; }
  slug=$(alias_slug "$al")
  if ! authorized 머지; then
    park "$seg" act 막힘 "인가 한도" "권한 절단점이 머지를 인가하지 않음" "gh -R $slug pr merge $branch"
    return 2
  fi
  pr=$(gh_q "$slug" pr list --head "$branch" --json number --jq '.[0].number' || printf '')
  [ -n "$pr" ] || {
    park "$seg" act 막힘 "게이트 park" "PR을 찾지 못함${GH_STDERR:+ — $GH_STDERR}" "gh -R $slug pr list --head $branch"
    return 2
  }

  # A merge grant does NOT come with an --admin exception. A driver blocked by
  # branch protection that issued itself that exception would be widening the
  # authorization silently.
  local required_rows
  required_rows=$(gh_q "$slug" pr checks "$pr" --required | grep -c . || printf '0')
  if [ "$required_rows" = "0" ]; then
    if ! gh_q "$slug" pr checks "$pr" >/dev/null; then
      # Interactively this branch enumerates the failed non-required checks and
      # asks. Unattended the answer never comes, so it IS the park branch.
      park "$seg" act 막힘 "게이트 park" "필수 지정이 없고 비필수 체크가 실패 — 무응답이면 머지 금지" "gh -R $slug pr merge $pr"
      return 2
    fi
  elif ! gh_q "$slug" pr checks "$pr" --required >/dev/null; then
    park "$seg" act 막힘 "게이트 park" "필수 체크 실패${GH_STDERR:+ — $GH_STDERR}" "gh -R $slug pr checks $pr --required"
    return 2
  fi

  local head_sha
  head_sha=$(gh_q "$slug" pr view "$pr" --json headRefOid --jq '.headRefOid' || printf '')
  gh_q "$slug" pr merge "$pr" --merge --match-head-commit "$head_sha" --delete-branch >/dev/null || {
    park "$seg" act 막힘 "게이트 park" "머지 실패(보호 규칙 가능성) — --admin 은 사용하지 않음${GH_STDERR:+ — $GH_STDERR}" "gh -R $slug pr merge $pr"
    return 2
  }
  # Refresh immediately after the server-side merge so the next segment's
  # `wt_create` branches from a base that actually contains this merge. Without
  # this the sequential-base premise is false from the very first merge.
  base_fetch "$al"
  # The apply worktree pins THIS merge, so the sha is captured here where it is
  # unambiguous rather than re-derived later from a base tip that a concurrent
  # merge may already have moved.
  MERGE_COMMIT=$(gh_q "$slug" pr view "$pr" --json mergeCommit --jq '.mergeCommit.oid' || printf '')
  [ -n "$MERGE_COMMIT" ] || MERGE_COMMIT=$(base_sha "$al")
  ledger_row 'segment' "id=$seg" "상태=머지됨" "브랜치=$branch" "PR=$pr" \
    "레포=$slug" "머지 커밋=$MERGE_COMMIT" "베이스 sha=$(base_sha "$al")"
  return 0
}

# ---------------------------------------------------------------------------
# The four run-level caps. Each of them answers "when does this night end?" for a
# different reason, and each records what it stopped.
# ---------------------------------------------------------------------------

# 1 — WALL-CLOCK DEADLINE. A dispatch gate and NEVER a kill signal: a stage in
# flight runs to completion and is classified normally, because killing it would
# manufacture exactly the ambiguous half-done state the rest of this driver
# exists to avoid. But no merge happens after the deadline either — `merge_gate`
# is executed inline by the driver rather than spawned, so "stages in flight
# finish" does not cover it, and a merge landing an hour after the deadline is a
# terminal act nobody authorized for that hour.
deadline_epoch() {
  local dl
  [ -n "$MANIFEST" ] || { printf ''; return 0; }
  dl=$(manifest_field '인가' '벽시계 마감')
  [ -n "$dl" ] && [ "$dl" != "없음" ] || { printf ''; return 0; }
  # BSD `date -j` is the parse form, and it is correct here rather than merely
  # convenient: this driver refuses to start on any non-darwin host at entry, so
  # the portable shim would be dead code guarding a branch that cannot run.
  date -j -f '%Y-%m-%dT%H:%M:%SZ' "${dl%%+*}" '+%s' 2>/dev/null || printf ''  # lint-bash-portability: disable=date -j
}

past_deadline() {
  local d; d=$(deadline_epoch)
  [ -n "$d" ] || return 1
  [ "$(now_epoch)" -ge "$d" ]
}

# 2 — RUN CYCLE BUDGET, the sum of the per-segment budgets. Both use LADDER_RUNGS
# so the two cannot drift apart; they used to be unrelated literals in two
# functions, which is how "the same K" became a comment rather than a fact.
segment_cap() { local f="$1"; [ "$f" -ge 1 ] || f=1; printf '%s' $(( LADDER_RUNGS * f + 1 )); }

run_cycle_budget() {
  local total=0 seg repo files deps n
  while IFS="$(printf '\t')" read -r seg repo files deps; do
    [ -n "$seg" ] || continue
    n=$(printf '%s' "$(plan_uncell "$files")" | tr ',' '\n' | grep -c . || printf '1')
    total=$(( total + $(segment_cap "$n") ))
  done < "$RUN_DIR/plan.tsv"
  printf '%s' "$total"
}

RUN_CYCLES=0
RUN_CYCLE_BUDGET=0
run_cycles_spend() { RUN_CYCLES=$(( RUN_CYCLES + ${1:-1} )); printf '%s' "$RUN_CYCLES"; }

# 3 — GENERATIONS. A re-plan is allowed; a run that keeps re-planning never lands
# anything, and this is where that stops being invisible. The `세대` field was a
# hardcoded 1, so the row said "generation" while measuring nothing.
generation_now() { cat "$RUN_DIR/generation" 2>/dev/null || printf '1'; }
generation_bump() {
  local g; g=$(( $(generation_now) + 1 ))
  printf '%s' "$g" > "$RUN_DIR/generation"
  printf '%s' "$g"
}

# 4 — FILE-SET ESCAPE. Two arms, not one. Inside a repository an escape refutes
# the premise the plan rests on, which is a CONE stop. ACROSS repositories it is
# something else entirely: a stage reached into a repository nobody authorized
# for it, so the run stops and the reach itself is recorded as an authorization
# event. The old "wave sibling" arm is gone — overlapping declared files are the
# designed normal now, and keeping that arm would park CORRECT plans.
#
# The cross-repository arm is judged on THIS RUN's other segment worktrees, not
# on anyone's main worktree. A main worktree is where a person works, and
# attributing their edits to a stage would park a whole run on someone else's
# afternoon — a false positive with the most expensive possible consequence. A
# sibling segment worktree has no such ambiguity: this run created it, and
# nothing but this run's stages should ever be writing there.
fileset_escape() {
  # fileset_escape <seg> <declared-csv> <worktree>
  local seg="$1" declared="$2" wt="$3" actual esc="" f cross=0 other op
  for other in $(cat "$RUN_DIR/started.txt" 2>/dev/null); do
    [ "$other" = "$seg" ] && continue
    op=$(wt_path "$other" 2>/dev/null) || continue
    [ -d "$op" ] || continue
    [ -n "$( cd "$op" && git status --porcelain 2>/dev/null )" ] && { cross=1; esc="$esc [$other]$op"; }
  done
  actual=$( cd "$wt" && git diff --name-only HEAD 2>/dev/null; cd "$wt" && git diff --name-only --cached 2>/dev/null )
  [ -n "$actual" ] || { [ "$cross" = "1" ] || return 0; }
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    case ",$(printf '%s' "$declared" | tr -d ' '),"  in
      *",$(printf '%s' "$f" | tr -d ' '),"*) continue ;;
    esac
    esc="$esc $f"
  done <<EOF
$(printf '%s\n' "$actual" | sort -u)
EOF
  [ -n "$esc" ] || return 0
  # Both sets are written out. A row that names only the escape leaves the
  # reader unable to tell an over-narrow declaration from a stage that wandered.
  ledger_row 'segment' "id=$seg" "상태=park" \
    "선언 파일 집합=$declared" "실제 편집 집합=$(printf '%s' "$actual" | tr '\n' ',' | sed 's/,$//')" \
    "이탈=$(printf '%s' "$esc" | sed 's/^ //')"
  if [ "$cross" = "1" ]; then
    ledger_row '자율 승인' "kind=citation" "결정=레포 간 파일 집합 이탈로 런 정지" \
      "기각된 대안=세그먼트만 park" "근거=인가되지 않은 레포에 손이 닿았다"
    park "$seg" run 무효화 "게이트 park" "레포 간 파일 집합 이탈: $(printf '%s' "$esc" | sed 's/^ //')"
  else
    park "$seg" cone 무효화 "게이트 park" "선언 밖 파일 편집: $(printf '%s' "$esc" | sed 's/^ //')"
  fi
  return 1
}

# ---------------------------------------------------------------------------
# S9 APPLY — the driver runs it, and that is the whole design of this stage.
#
# Unforgeability is a property of the EXECUTOR, not of the command. A stage that
# improvises can run the probe and then report whatever it likes; there must be
# no improvising surface anywhere near an irreversible act. So S9 is not a model
# dispatch — it is `sh -c` under the driver, with the command copied verbatim
# from a declaration a human approved.
#
# `terraform plan -detailed-exitcode` is the shape this is built around, and its
# exit 2 means OPPOSITE things before and after an apply — "changes pending"
# beforehand, "changes still pending" afterwards. So BOTH sides are probed and
# the four outcomes map one-to-one onto four dispositions:
#
#   pre = 0            nothing to do; skip the apply entirely
#   pre = 1            the probe itself failed; refuse before touching anything
#   pre = 2 → post = 0 converged; this is the only success
#   pre = 2 → post = 2 changes still pending after an apply ran — 적용 불명
#
# The pre-probe is also the "did it even start" discriminator the retry rules
# needed. There are no retries here: an apply is a terminal act, and a second
# attempt after an unknown outcome is not a retry, it is a second apply.
# ---------------------------------------------------------------------------
MERGE_COMMIT=""

# Declaration first, manifest second. The per-slice declaration is the more
# specific statement, and a run that has one is a run whose author already
# answered this question per slice.
apply_field() {
  local seg="$1" key="$2" v id
  if [ -n "${DOC:-}" ] && [ -f "${DOC:-}" ]; then
    for id in $(slice_ids "$DOC" 2>/dev/null); do
      [ "$id" = "$seg" ] || continue
      v=$(slice_field "$DOC" "$id" "$key"); [ -n "$v" ] && { printf '%s' "$v"; return 0; }
    done
  fi
  [ -n "$MANIFEST" ] || return 0
  case "$key" in
    '적용 명령') manifest_field '요소' '적용 지점' ;;
    '적용 주체') manifest_field '요소' '적용 주체' ;;
    '폭발 반경') printf '레포' ;;
    *)           printf '' ;;
  esac
}

# Backticks are the declaration's rendering, not part of the command.
apply_unquote() { printf '%s' "$1" | sed 's/^`//; s/`$//'; }

apply_probe_cmd() {
  local seg="$1" v
  v=$(apply_field "$seg" '적용 프로브')
  [ -n "$v" ] || { [ -n "$MANIFEST" ] && v=$(manifest_field '요소' '적용 프로브'); }
  apply_unquote "$v"
}

# The apply runs in its OWN worktree pinned to the merge commit, never in the
# segment worktree: that tree holds the pre-merge branch, and applying from it
# would apply something the merge gate never approved.
apply_worktree() {
  local seg="$1" root p
  root=$(seg_root "$seg") || return 1
  p="$(dirname "$root")/$(basename "$root")${WORKTREE_INFIX}${SLUG}-${seg}-apply"
  printf '%s' "$p"
}

apply_probe() {
  # Echoes nothing; the CALLER reads the exit status, which is the whole point
  # of `-detailed-exitcode`. Swallowing it into a string would put a parser
  # between the tool and the decision.
  local wt="$1" cmd="$2"
  ( cd "$wt" && sh -c "$cmd" ) >/dev/null 2>&1
}

apply_stage() {
  local seg="$1" cmd actor radius wt root pre post rc
  cmd=$(apply_unquote "$(apply_field "$seg" '적용 명령')")
  [ -n "$cmd" ] && [ "$cmd" != "(없음)" ] || return 0     # no apply declared

  actor=$(apply_field "$seg" '적용 주체')
  radius=$(apply_field "$seg" '폭발 반경'); [ -n "$radius" ] || radius='레포'

  # A handover, not a degradation. The pipeline finished at merge and the
  # command travels to the morning report as an opaque string — reporting a
  # command is not performing it, so no new authorization vocabulary is needed.
  if [ "$actor" != "파이프라인" ]; then
    ledger_row 'stage-result' "세그먼트=$seg" "스테이지=S9" "종료 코드=0" \
      "아티팩트 술어 결과=0" "종단 부류=정상 완료" "관측=적용 주체가 사람 — 인계"
    report_append "적용 인계" "$seg — 사람이 실행할 명령: $cmd"
    return 0
  fi

  if ! authorized 배포; then
    park "$seg" act 막힘 "인가 한도" "권한 절단점이 배포를 인가하지 않음 — 명령은 보고서로 인계" "$cmd"
    report_append "적용 인계" "$seg — 미인가로 실행하지 않음, 사람이 실행할 명령: $cmd"
    return 0
  fi

  [ -n "$MERGE_COMMIT" ] || { park "$seg" act 막힘 "게이트 park" "머지 커밋을 고정할 수 없어 apply 를 시작하지 않는다"; return 2; }
  root=$(seg_root "$seg") || return 1
  wt=$(apply_worktree "$seg") || return 1
  if [ ! -d "$wt" ]; then
    ( cd "$root" && git worktree add --detach "$wt" "$MERGE_COMMIT" >/dev/null 2>&1 ) \
      || { park "$seg" act 막힘 "게이트 park" "apply 워크트리를 머지 커밋에 고정하지 못했다: $MERGE_COMMIT"; return 2; }
  fi
  ledger_row 'segment' "id=$seg" "상태=적용 준비" "워크트리=$wt" "고정 커밋=$MERGE_COMMIT" "적용 명령=$cmd"

  local probe; probe=$(apply_probe_cmd "$seg")
  if [ -z "$probe" ]; then
    park "$seg" act 막힘 "게이트 park" "적용 프로브가 없어 필요 여부를 판정할 수 없다 — apply 를 실행하지 않는다"
    return 2
  fi

  apply_probe "$wt" "$probe"; pre=$?
  case "$pre" in
    0) ledger_row 'stage-result' "세그먼트=$seg" "스테이지=S9" "종료 코드=0" \
         "아티팩트 술어 결과=0" "종단 부류=정상 완료" "관측=사전 프로브 0 — 적용할 변경 없음"
       apply_teardown "$seg" "$wt"
       return 0 ;;
    2) : ;;
    *) # Anything that is not "no changes" or "changes pending" is the probe
       # itself failing. Refuse BEFORE touching anything: an apply whose need
       # could not be established is an apply with no evidence behind it.
       park "$seg" act 막힘 "게이트 park" "사전 프로브 실패(exit $pre) — 아무것도 건드리기 전에 거부한다" "$cmd"
       return 2 ;;
  esac

  log "$seg: S9 apply 실행 (재시도 없음) — $cmd"
  ( cd "$wt" && sh -c "$cmd" ) >"$RUN_DIR/log/S9-$seg.out" 2>"$RUN_DIR/log/S9-$seg.err"; rc=$?

  apply_probe "$wt" "$probe"; post=$?
  if [ "$rc" = "0" ] && [ "$post" = "0" ]; then
    ledger_row 'stage-result' "세그먼트=$seg" "스테이지=S9" "종료 코드=0" \
      "아티팩트 술어 결과=0" "종단 부류=정상 완료" "관측=사전 2 → 사후 0, 수렴"
    apply_teardown "$seg" "$wt"
    return 0
  fi

  # 적용 불명. The state the next irreversible act would transform cannot be
  # judged, so the stop is the DECLARED blast radius — and the worktree stays.
  # A normal teardown here would delete the only reproduction of a half-applied
  # state, which is the one artifact a person will need in the morning.
  ledger_row 'stage-result' "세그먼트=$seg" "스테이지=S9" "종료 코드=$rc" \
    "아티팩트 술어 결과=1" "종단 부류=적용 불명" "관측=사전 2 → 사후 $post"
  park "$seg" run 불명 "게이트 park" "적용 불명 — 폭발 반경 '$radius' 정지, 워크트리 보존: $wt" "$cmd"
  report_append "사람 대조 필요" "$seg — apply 결과 불명, 반경 $radius. 워크트리 $wt 를 보존했다"
  APPLY_PARKED_RADIUS="$radius"
  return 1
}

# Only a CONVERGED apply gives its worktree back. Failure keeps it.
apply_teardown() {
  local seg="$1" wt="$2" root
  root=$(seg_root "$seg") || return 0
  ( cd "$root" && git worktree remove "$wt" >/dev/null 2>&1 && git worktree prune >/dev/null 2>&1 ) || true
}

APPLY_PARKED_RADIUS=""

# ---------------------------------------------------------------------------
# Judgment calls. Wired, stubbed. Each is a single foreground `-p` with a fixed
# prompt file and a `--json-schema` return contract; the schema is what makes
# the return machine-readable without parsing prose.
# ---------------------------------------------------------------------------
PROMPT_DIR="$ORCH_DIR/prompts"

readonly JUDGMENTS="segment-plan triage redesign-impact"

judgment_call() {
  # judgment_call <name> <input-file>  — prompt and schema are found by
  # convention: <name>.md and <name>.schema.json beside this script.
  local name="$1" input="$2"
  case " $JUDGMENTS " in
    *" $name "*) : ;;
    *) warn "판단 호출 이름이 어휘 밖: $name"; return 1 ;;
  esac
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
  # Two classes of fact, checked in two different ways.
  #
  #   A — seam-driven selection. Verifiable on ANY runner by injecting
  #       CC_CMDS_ORCH_HOST_OS, because what is being checked is which source
  #       the driver picks and whether the refusal fires, not whether the picked
  #       binary exists here.
  #   B — claims that need a real darwin kernel. Checked only when running
  #       NATIVELY on darwin; elsewhere they are reported as the macOS leg's
  #       job rather than silently passing or noisily failing.
  local fails=0 native
  native=$(uname -s)
  printf 'bash: %s\n' "$BASH_VERSION"
  printf 'PATH: %s\n' "$PATH"
  printf 'locale: LC_CTYPE=%s LC_COLLATE=%s (%s=%s, locale -a 후보 %s개)\n' \
    "${LC_CTYPE:-unset}" "${LC_COLLATE:-unset}" "${ORCH_LOCALE_SOURCE:-미해결}" \
    "${ORCH_UTF8_LOCALE:-없음}" "$(locale -a 2>/dev/null | grep -c . || printf 0)"
  printf 'awk: %s\n' "$(awk --version 2>&1 | sed -n '1p' || printf 'unknown')"
  # The reason this is printed rather than merely set: the failure it guards
  # against is silent non-matching, so the only way a reader learns which
  # interpreter and locale a run actually got is to see them.
  if [ -n "$(printf '한글\n' | awk '/^한글$/{print "hit"}')" ]; then
    printf 'ok   awk 멀티바이트 정규식 일치\n'
  else
    printf 'FAIL awk 가 멀티바이트 정규식을 일치시키지 못함 — 한국어 어휘 비교가 조용히 실패한다\n'
    fails=$((fails + 1))
  fi
  if [ "$(printf '한글\n' | awk -v k=한글 '$0==k{print "hit"}')" = "hit" ]; then
    printf 'ok   awk 멀티바이트 -v 대입 일치\n'
  else
    printf 'FAIL awk 가 멀티바이트 -v 대입을 잃는다 — 필드 조회가 조용히 빈 값을 낸다\n'
    fails=$((fails + 1))
  fi
  printf 'host: seam=%s native=%s\n' "$ORCH_HOST_OS" "$native"

  # --- platform-independent tooling ---------------------------------------
  for t in git awk sed grep shasum ps date; do
    if command -v "$t" >/dev/null 2>&1; then printf 'ok   %s -> %s\n' "$t" "$(command -v "$t")"
    else printf 'FAIL %s missing\n' "$t"; fails=$((fails + 1)); fi
  done

  # --- A: selection and refusal -------------------------------------------
  if platform_supported; then
    printf 'ok   플랫폼 지원 분기 선택 (darwin)\n'
    if [ -n "$(lock_tool)" ]; then printf 'ok   잠금 소스 선택 -> %s\n' "$(lock_tool)"
    else printf 'FAIL 지원 플랫폼인데 잠금 소스가 선택되지 않음\n'; fails=$((fails + 1)); fi
    if [ -n "$(boot_source)" ]; then printf 'ok   부팅 시각 소스 선택 -> %s\n' "$(boot_source)"
    else printf 'FAIL 지원 플랫폼인데 부팅 시각 소스가 선택되지 않음\n'; fails=$((fails + 1)); fi
  else
    if [ -z "$(lock_tool)" ] && [ -z "$(boot_source)" ]; then
      printf 'ok   비지원 플랫폼: 소스 미선택 (진입에서 거부됨)\n'
    else
      printf 'FAIL 비지원 플랫폼인데 소스가 선택됨 — 조용한 열화 경로\n'; fails=$((fails + 1))
    fi
  fi
  printf 'ok   cutpoint index 머지 -> %s\n' "$(cutpoint_index 머지)"

  # --- B: darwin-only claims ----------------------------------------------
  # BOTH conditions, and the conjunction is the point: class B validates the
  # source the seam SELECTED, so under a non-darwin injection there is no
  # selected source to validate and running these would check something the
  # driver would never reach.
  if [ "$native" = "Darwin" ] && platform_supported; then
    local tool b w
    tool=$(lock_tool)
    if [ -n "$tool" ] && [ -x "$tool" ]; then printf 'ok   잠금 바이너리 실재 -> %s\n' "$tool"
    else printf 'FAIL 선택된 잠금 바이너리 부재 (검출 잠금이 성립하지 않음)\n'; fails=$((fails + 1)); fi
    # The denylist row for this binary exists because a detach path built on it
    # does not run on the target platform. Probing for its ABSENCE is the one
    # legitimate mention, so both arms carry the same-line escape rather than
    # weakening the row.
    if command -v setsid >/dev/null 2>&1; then printf 'note setsid present (unused; nohup + set -m is the contract)\n'  # lint-bash-portability: disable=setsid
    else printf 'ok   setsid absent as expected on darwin\n'; fi  # lint-bash-portability: disable=setsid
    b=$(boot_epoch); w=$(wake_epoch)
    if [ -n "$b" ]; then printf 'ok   부팅 시각 판독 -> %s\n' "$b"; else printf 'FAIL 부팅 시각 판독 실패\n'; fails=$((fails + 1)); fi
    printf 'ok   wake 시각 판독 -> %s\n' "${w:-unset}"
  else
    printf 'note darwin 전용 확인(잠금 경합·프로세스 그룹 회수·부팅 시계)은 macOS 레그 담당\n'
  fi

  # --- C: declared but not wired ------------------------------------------
  # This driver has produced the same defect over and over: a thing is declared,
  # recorded, even computed — and nothing reads it. A constant with no reader, a
  # digest with no comparator, a function with no call site. Each looked like a
  # working mechanism in review and each did nothing at runtime, and the ones
  # that mattered were invisible precisely because they looked wired.
  #
  # It lives here rather than in a lint script of its own on purpose: a new
  # script would have to be registered in the Makefile to ever run, and an
  # unregistered lint IS this defect wearing the detector's clothes. The test
  # harness already runs `--self-check` under a sanitized interpreter, so this
  # costs zero new wiring.
  #
  # Conditionally-wired items are exempt by EXPLICIT registration, never by the
  # checker's silence, and the fact that the exemption list is non-empty is
  # itself recorded — an exemption nobody can see is indistinguishable from a
  # check that does not run.
  local unwired=0 self_file exempt name body sib
  self_file="${BASH_SOURCE[0]}"
  # Registered exemptions. Empty is the goal state; a non-empty list is reported.
  exempt=""
  # The scan covers this file AND the siblings that SOURCE it. Once the policy
  # gate moved into its own file, a function's only call site could legitimately
  # live there — and a checker that reads one file would report it as dead and
  # invite its deletion. Widening the scan is more honest than an exemption
  # list: those functions are wired, just not from here.
  body=$(sed 's/#.*//' "$self_file")
  for sib in "$(dirname "$self_file")/gate.sh"; do
    [ -f "$sib" ] || continue
    body="$body
$(sed 's/#.*//' "$sib")"
  done

  for name in $(grep -oE '^readonly [A-Z_][A-Z0-9_]*' "$self_file" | awk '{print $2}'); do
    case " $exempt " in *" $name "*) continue ;; esac
    if [ "$(printf '%s\n' "$body" | grep -vE '^readonly '"$name"'=' | grep -cE '(^|[^A-Za-z0-9_])'"$name"'([^A-Za-z0-9_]|$)')" -lt 1 ]; then
      printf 'FAIL 선언됐으나 독자 없음 (상수): %s\n' "$name"; unwired=$((unwired + 1))
    fi
  done

  for name in $(grep -oE '^[a-z_][a-z0-9_]*\(\)' "$self_file" | tr -d '()'); do
    case " $exempt " in *" $name "*) continue ;; esac
    # Call sites are occurrences outside the definition line. `main` never has
    # one by construction, so the file's own entry point is the one shape this
    # cannot judge and it is registered rather than special-cased silently.
    if [ "$(printf '%s\n' "$body" | grep -cE '(^|[^A-Za-z0-9_])'"$name"'([^A-Za-z0-9_(]|$)')" -lt 1 ]; then
      printf 'FAIL 정의됐으나 호출부 0 (함수): %s\n' "$name"; unwired=$((unwired + 1))
    fi
  done

  # A digest that is computed and never compared is the same defect in its most
  # expensive form: it reports a measurement nobody acts on.
  for name in $(grep -oE '^[a-z_][a-z0-9_]*_digest\(\)' "$self_file" | tr -d '()'); do
    case " $exempt " in *" $name "*) continue ;; esac
    if [ "$(printf '%s\n' "$body" | grep -cE '(=|\[ )"?\$\('"$name"'|'"$name"'.*(!=|=)')" -lt 1 ]; then
      printf 'FAIL 계산되나 비교자 없음 (다이제스트): %s\n' "$name"; unwired=$((unwired + 1))
    fi
  done

  if [ -n "$exempt" ]; then
    printf 'note 조건부 배선 예외 등재:%s\n' "$exempt"
  else
    printf 'ok   조건부 배선 예외 없음 (등재 목록 비어 있음)\n'
  fi
  if [ "$unwired" = "0" ]; then printf 'ok   선언된 것에 전부 독자·호출부·비교자가 있다\n'
  else fails=$((fails + unwired)); fi

  if [ "$fails" = "0" ]; then printf 'self-check: PASS\n'; return 0; fi
  printf 'self-check: %s FAIL\n' "$fails"; return 1
}

# ---------------------------------------------------------------------------
# Escalation ladder. Problem identity is (normalized path, category tag) and is
# deliberately SEVERITY-FREE: severity is not a property of the defect but a
# measurement re-derived every cycle, so putting it in the key splits one defect
# into two whenever the reading changes, each granted a fresh budget at rung 1.
# Neither would ever accumulate enough recurrences to reach the human rung, and
# the ladder — the only structural bound on re-fix depth — disarms itself.
# ---------------------------------------------------------------------------
LADDER=""

# The manifest declares how many rungs this run may climb (4 or 2). It is NOT a
# clamp. A clamp would silently rewrite a rung-4 transition into a rung-2 one, so
# the shipped `case "$rung" in 4) park` arm becomes unreachable and the TERMINAL
# rung disarms itself — the ladder would then have no end at all. What the
# declaration does instead is make a transition into a rung outside the available
# set park immediately, with its own reason.
ladder_available() {
  local n
  [ -n "$MANIFEST" ] && n=$(manifest_field '인가' '사다리 가용 단 수')
  case "${n:-}" in
    2) printf '2' ;;
    4|'') printf '%s' "$LADDER_RUNGS" ;;
    *) printf '%s' "$LADDER_RUNGS" ;;
  esac
}

# Problem identity carries the REPOSITORY. Without it two repositories that share
# a path — and they do, `plugins/cc-cmds/...` is the same string in every clone —
# collapse into one identity, so a defect in one spends the other's rungs and the
# ladder reaches its terminal rung for a file nobody touched twice.
identity_of() {
  local seg="$1" path="$2" cat="$3" slug
  slug=$(seg_slug "$seg" 2>/dev/null); [ -n "$slug" ] || slug='(레포 미상)'
  printf '%s::%s::%s' "$slug" "$path" "$cat"
}

ladder_init() { LADDER="$RUN_DIR/ladder.tsv"; : > "$LADDER"; }

# The rung this identity has already consumed, or 0.
#
# There used to be a file-level inheritance arm here — a new identity in a file
# that had already consumed the root-redesign rung would inherit it. It was
# measured against the arrival order that actually occurs and fired ZERO times:
# the identities of one file are all introduced while that file's maximum is
# still 1, so the threshold it guarded is never reached. Worse than useless, it
# told a reader the cycle bound came from a per-file collapse when the bound
# comes from each identity climbing its own rungs. The cap is unchanged by its
# removal, because the cap never depended on it.
ladder_rung() {
  local path="$1" cat="$2" exact
  exact=$(awk -F'\t' -v p="$path" -v c="$cat" '$1==p && $2==c {print $3}' "$LADDER" | tail -1)
  [ -n "$exact" ] && { printf '%s' "$exact"; return 0; }
  printf '0'
}

# Returns the next rung, or 99 when that rung is not in the available set. The
# caller parks on 99 with its own reason — clamping here is the failure mode
# described above.
ladder_bump() {
  local path="$1" cat="$2" cur next avail
  cur=$(ladder_rung "$path" "$cat")
  next=$((cur + 1))
  avail=$(ladder_available)
  [ "$next" -gt "$LADDER_RUNGS" ] && next="$LADDER_RUNGS"
  if [ "$next" -gt "$avail" ]; then printf '99'; return 0; fi
  printf '%s\t%s\t%s\n' "$path" "$cat" "$next" >> "$LADDER"
  printf '%s' "$next"
}

# ---------------------------------------------------------------------------
# Base drift and merge ordering
# ---------------------------------------------------------------------------
BASE_BRANCH=""

# Per-alias, and cached per alias on disk rather than in one global — a shell
# without associative arrays is the floor here, and a single global would hand
# the second repository the first one's base branch.
base_branch() {
  local al="${1:-$(home_alias)}" root f b
  if [ -n "$MANIFEST" ] && [ "$al" != "." ]; then
    b=$(target_field "$al" '베이스 브랜치')
    [ -n "$b" ] && { printf '%s' "$b"; return 0; }
  fi
  f="${RUN_DIR:-}/base-branch.$al"
  [ -n "${RUN_DIR:-}" ] && [ -f "$f" ] && { cat "$f"; return 0; }
  [ -n "$BASE_BRANCH" ] && [ -z "${RUN_DIR:-}" ] && { printf '%s' "$BASE_BRANCH"; return 0; }
  root=$(alias_root "$al") || return 1
  b=$( cd "$root" && { git rev-parse --abbrev-ref origin/HEAD 2>/dev/null | sed 's#^origin/##'; } )
  [ -n "$b" ] || b=$( cd "$root" && git rev-parse --abbrev-ref HEAD )
  BASE_BRANCH="$b"
  [ -n "${RUN_DIR:-}" ] && [ -d "$RUN_DIR" ] && printf '%s' "$b" > "$f"
  printf '%s' "$b"
}

# Refresh the remote-tracking refs. This does NOT touch the working tree — it
# reads the remote and moves `refs/remotes/origin/*` only — so it is compatible
# with the decision never to fast-forward the tree a human is working in.
base_fetch() { local al="${1:-$(home_alias)}"; ( cd "$(alias_root "$al")" && git fetch --quiet origin 2>/dev/null ) || true; }

# Resolve from the REMOTE-TRACKING ref, not the stripped local name.
#
# This is the sequential-base premise, and without it the premise is false. The
# merges happen on the server (`gh pr merge`), so a local branch ref never
# advances; segment k+1 would then branch from a base that does not contain k's
# merge and the overlapping declared files become CONCURRENT edits — exactly the
# case the design excludes by assuming sequentiality. Two more things break from
# the same root: external-drift detection compares against this value and would
# never fire, and the apply worktree pins a merge commit that exists only on the
# remote.
base_sha() {
  local al="${1:-$(home_alias)}"
  ( cd "$(alias_root "$al")" && git rev-parse "refs/remotes/origin/$(base_branch "$al")" )
}

# Rebase onto the segment's own base after external drift. There is exactly one
# kind of conflict left to handle: SOMEONE ELSE moved the base. The sibling arm
# that used to sit here answered a conflict between two segments of one parallel
# wave, and there are no parallel waves — `segment_cycle` has one call site and no
# `&`, so that arm was unreachable and the flag it set could never be read true.
rebase_onto_base() {
  local seg="$1" wt="$2" al="${3:-}"
  ( cd "$wt" && git rebase "$(base_branch "${al:-$(seg_alias "$seg")}")" >/dev/null 2>&1 ) && return 0
  ( cd "$wt" && git rebase --abort >/dev/null 2>&1 || true )
  # Never auto-resolve and never wake anyone: route this one segment up the
  # ladder and let the rest of the run keep going.
  warn "$seg: 외부 드리프트와 충돌 — 이 세그먼트만 사다리로"
  return 1
}

# ---------------------------------------------------------------------------
# One segment's S4..S8 cycle
# ---------------------------------------------------------------------------
segment_cycle() {
  local seg="$1" files="$2"
  local branch="seg/$SLUG-$seg" wt pre_head f_count cap cycle=0 al seg_repo
  # Resolved ONCE, at the top, and threaded through everything below. Every
  # git and `gh` call in this cycle belongs to this segment's repository, not
  # to whichever one the document happened to live in.
  al=$(seg_alias "$seg") || al=""
  [ -n "$al" ] || { park "$seg" cone 무효화 "게이트 park" "선언되지 않은 레포: $(plan_repo "$seg")"; return 1; }
  seg_repo=$(alias_root "$al")
  files=$(plan_uncell "$files")
  f_count=$(printf '%s' "$files" | tr ',' '\n' | grep -c . || printf '1')
  # Width x depth: the ladder is monotone in LADDER_RUNGS rungs per identity and
  # per-file rung inheritance collapses a file's total to that same number, so
  # the cycle count is bounded by K*F + 1 with F the segment's DECLARED file-set
  # size — a measured quantity, recorded at plan time and watched by the file-set
  # escape predicate. The run-level budget sums this same function.
  cap=$(segment_cap "$f_count")
  printf '%s\n' "$seg" >> "$RUN_DIR/started.txt"

  wt=$(wt_create "$seg" "$branch") || { park "$seg" cone 무효화 "게이트 park" "워크트리 생성 실패"; return 1; }
  pre_head=$( cd "$wt" && git rev-parse HEAD )
  local stash_before; stash_before=$(stash_ref "$seg_repo")
  local plan_digest; plan_digest=$(binding_digest)
  ledger_row 'segment' "id=$seg" "상태=실행중" "브랜치=$branch" "사전 HEAD=$pre_head" \
    "레포=$(alias_slug "$al")" "베이스 sha=$(base_sha "$al")" "워크트리=$wt" \
    "plan-binding-digest=$plan_digest"

  while [ "$cycle" -lt "$cap" ]; do
    cycle=$((cycle + 1))
    # Loop head, one of the two places the deadline is read. A gate, not a kill:
    # nothing in flight is touched, the next dispatch simply does not happen.
    if past_deadline; then
      park "$seg" cone 무효화 "예산·벽시계" "벽시계 마감 경과 — 다음 사이클을 디스패치하지 않는다"
      return 1
    fi
    if [ "$(run_cycles_spend 1)" -gt "$RUN_CYCLE_BUDGET" ]; then
      park "$seg" cone 무효화 "예산·벽시계" "런 사이클 예산 ${RUN_CYCLE_BUDGET} 소진"
      return 1
    fi

    # --- S4 IMPLEMENT ------------------------------------------------------
    local sid="S4:$seg:$cycle"
    quiet_window_begin
    # `declared_files` travels ON the dispatch line. The set bounds the cycle
    # budget and the escape check judges against it, so a stage that never sees
    # it is being measured against a contract it was not told.
    # Under the document lock. The implementation arm's two reserved write
    # forms touch the design document, and the lock is DETECTING rather than
    # preventing — a busy lock means the plan was wrong, so it refuses instead
    # of queueing two read-modify-writes that were each composed against
    # pre-conflict bytes.
    with_doc_lock true || {
      park "$seg" cone 무효화 "게이트 park" "설계 문서 잠금 경합 — 두 세그먼트가 같은 문서를 쓰려 한다"
      return 1
    }
    stage_spawn "$sid" "$wt" "/cc-cmds:implement-unattended $DOC \"세그먼트 $seg (사이클 $cycle) · 선언 파일: $files\""
    stage_wait_all "$sid"
    quiet_window_end
    local rc pred class
    rc=$(cat "$RUN_DIR/$sid.rc" 2>/dev/null || printf '1')
    if predicate_implement "$branch" "$pre_head" "$seg"; then pred=0; else pred=1; fi
    class=$(classify_termination "$sid" "$rc" "$pred")
    ledger_row 'stage-result' "세그먼트=$seg" "스테이지=S4" "종료 코드=$rc" \
      "아티팩트 술어 결과=$pred" "실행 버전=$("$CLI_BIN" --version 2>/dev/null | sed -n '1p')" \
      "세션 id=$(stage_session_id "$sid")" "부모=$(stage_parent_id)" "종단 부류=$class"

    fileset_escape "$seg" "$files" "$wt" || return 1
    stash_attribution_check "$stash_before" "$branch" "$seg_repo" || { park "$seg" cone 무효화 "게이트 park" "세그먼트 브랜치 귀속 stash 항목"; return 1; }

    case "$class" in
      '정상 완료') : ;;
      '의도된 park')
        park "$seg" cone 무효화 "게이트 park" "중단 기록" "$(sed -n 's/^\*\*재호출 명령\*\*: //p' "$RUN_DIR/halt/$sid.md" 2>/dev/null)"
        return 1 ;;
      '공허한 성공')
        # One retry, then a DISTINCT park reason. Not zero, because one
        # observation cannot rule out a transient cause; not the whole budget,
        # because a clean exit with no artifact is itself evidence the next
        # attempt does the same — improvisation is deterministic.
        log "$seg: 공허한 성공 — 1회만 재시도"
        stage_spawn "$sid.retry" "$wt" "/cc-cmds:implement-unattended $DOC \"세그먼트 $seg (사이클 $cycle 재시도) · 선언 파일: $files\""
        stage_wait_all "$sid.retry"
        if predicate_implement "$branch" "$pre_head" "$seg"; then : ; else
          park "$seg" cone 무효화 "게이트 park" "공허한 성공 2회 — 산출물 없음"; return 1
        fi ;;
      *) park "$seg" cone 무효화 "게이트 park" "크래시"; return 1 ;;
    esac

    # --- S5 REVIEW ---------------------------------------------------------
    local rp="$BASE/docs/reviews/review-$SLUG-$seg-c$cycle.md"
    mkdir -p "$(dirname "$rp")"
    sid="S5:$seg:$cycle"
    stage_spawn "$sid" "$seg_repo" "/cc-cmds:review-unattended $branch --report-path $rp \"설계는 $DOC\""
    stage_wait_all "$sid"
    if predicate_review "$rp"; then pred=0; else pred=1; fi
    rc=$(cat "$RUN_DIR/$sid.rc" 2>/dev/null || printf '1')
    class=$(classify_termination "$sid" "$rc" "$pred")
    ledger_row 'stage-result' "세그먼트=$seg" "스테이지=S5" "종료 코드=$rc" \
      "아티팩트 술어 결과=$pred" "종단 부류=$class"
    [ "$class" = "정상 완료" ] || { park "$seg" cone 무효화 "게이트 park" "리뷰 종단 부류 $class"; return 1; }

    # --- S6 TRIAGE ---------------------------------------------------------
    local tri_out tri
    tri_out=$(judgment_call triage "$rp") || { park "$seg" cone 무효화 "게이트 park" "트리아지 판단 호출 실패"; return 1; }
    tri=$(judgment_result "$tri_out")
    local p0 p1
    p0=$(printf '%s' "$tri" | jq -r '.p0_count // 0')
    p1=$(printf '%s' "$tri" | jq -r '.p1_count // 0')
    ledger_row 'cycle' "세그먼트=$seg" "사이클=$cycle" "리포트 경로=$rp" "P0=$p0" "P1=$p1" \
      "lane 결정=$(printf '%s' "$tri" | jq -c '[.findings[] | {id:.finding_id, lane:.lane}]')"

    # Severity adjudications are transcribed by the driver — the stage records
    # them in its report and never writes the ledger.
    printf '%s' "$tri" | jq -c '.findings[] | select(.severity_conflict)' 2>/dev/null | while IFS= read -r fx; do
      [ -n "$fx" ] || continue
      ledger_row '자율 승인' "kind=severity" \
        "finding-id=$(printf '%s' "$fx" | jq -r '.finding_id')" \
        "결정=$(printf '%s' "$fx" | jq -r '.severity')" \
        "기각된 대안=$(printf '%s' "$fx" | jq -r '.severity_rejected_alternative')" \
        "근거=$(printf '%s' "$fx" | jq -r '.severity_rationales')"
    done

    # --- Stop predicate ----------------------------------------------------
    if [ "$p0" = "0" ] && [ "$p1" = "0" ]; then
      log "$seg: P0+P1 == 0 — 사이클 종료"
      break
    fi

    # --- S7 REMEDIATE via the ladder --------------------------------------
    local any_park=0 fx
    while IFS= read -r fx; do
      [ -n "$fx" ] || continue
      local fpath fcat flane rung fid
      fpath=$(printf '%s' "$fx" | jq -r '.identity_path')
      fcat=$(printf '%s' "$fx" | jq -r '.identity_category')
      flane=$(printf '%s' "$fx" | jq -r '.lane')
      fid=$(identity_of "$seg" "$fpath" "$fcat")
      rung=$(ladder_bump "$fpath" "$fcat")
      ledger_row 'problem' "동일성=$fid" "현재 단=R$rung" \
        "payload=$(printf '%s' "$fx" | jq -r '.root_cause_payload')"
      ledger_row '자율 승인' "kind=lane" "결정=$flane" \
        "기각된 대안=$(printf '%s' "$fx" | jq -r '.lane_rationale')" "근거=R$rung"
      case "$rung" in
        99) park "$fid" cone 무효화 "사다리 단 부재" \
              "다음 단이 이 런의 가용 집합($(ladder_available)단) 밖 — 클램프하지 않고 여기서 멈춘다"
            any_park=1 ;;
        4) park "$fid" cone 무효화 "사다리 R4" "재발이 근본 재설계를 소비한 뒤 다시 나타남"; any_park=1 ;;
        2|3)
          sid="S1':$seg:$cycle:$(printf '%s' "$fpath" | tr '/' '-')"
          stage_spawn "$sid" "$(alias_root "$(home_alias)")" "/cc-cmds:design-reconverge $DOC \"$fpath, $fcat\""
          stage_wait_all "$sid"
          if predicate_reconverge "$sid"; then
            # The impact payload is an AUDIT record now, not a control signal.
            # What decides whether the plan is stale is a MEASUREMENT of the
            # document, not the model's self-report about it: a self-report
            # cannot be checked against what actually changed, and the field
            # that carried it had no reader at all.
            judgment_call redesign-impact "$RUN_DIR/log/$sid.json" >/dev/null || true
          else
            park "$fid" cone 무효화 "게이트 park" "재수렴 종단 술어 거짓"; any_park=1
          fi ;;
        *) : ;;   # R1 is the next S4 pass with the finding as its scope directive
      esac
    done <<EOF
$(printf '%s' "$tri" | jq -c '.findings[] | select(.severity=="P0" or .severity=="P1")')
EOF
    [ "$any_park" = "1" ] && { ledger_row 'segment' "id=$seg" "상태=park"; return 1; }
    # Digest comparison, in the place the latch used to be. The old global was
    # set unconditionally and never cleared, so ONE re-convergence anywhere
    # parked every later segment for the rest of the run — it failed safe, but
    # it failed on every run that reached this line.
    local now_digest; now_digest=$(binding_digest)
    if [ -n "$plan_digest" ] && [ "$now_digest" != "$plan_digest" ]; then
      log "$seg: 구속면 다이제스트 이동 ($plan_digest -> $now_digest) — 재계획 필요"
      return 2
    fi
  done

  if [ "$cycle" -ge "$cap" ]; then
    park "$seg" cone 무효화 "사이클 예산 소진" "사이클 상한 ${cap}(${LADDER_RUNGS}F+1, F=$f_count) 도달"
    return 1
  fi

  # --- S8 MERGE GATE -------------------------------------------------------
  local recorded_base; recorded_base=$(ledger_last 'segment' '베이스 sha')
  if [ -n "$recorded_base" ] && [ "$recorded_base" != "$(base_sha "$al")" ]; then
    log "$seg: 외부 드리프트 감지 — rebase 후 리뷰 재실행 필요"
    rebase_onto_base "$seg" "$wt" "$al" || { park "$seg" cone 무효화 "게이트 park" "외부 드리프트 rebase 충돌"; return 1; }
  fi
  if past_deadline; then
    park "$seg" act 막힘 "예산·벽시계" "벽시계 마감 경과 — 머지하지 않는다. 세그먼트는 완성-미착지" \
      "gh -R $(seg_slug "$seg") pr merge $branch"
    return 4
  fi
  local mrc=0; merge_gate "$seg" "$branch" || mrc=$?
  # 2 is the ACT arm: the merge is blocked, everything the segment produced
  # survives, and the run keeps going. Collapsing it into 1 is the eight-site
  # defect this slice exists to fix — one cutpoint typo used to park every
  # segment even though each had reached PR.
  [ "$mrc" = "2" ] && return 4
  [ "$mrc" = "0" ] || return 1

  # --- S9 APPLY ------------------------------------------------------------
  # Runs only when the segment declares one. It consumes NO ladder rung: an
  # apply failure is not a defect recurring, it is a terminal act that did not
  # complete, and feeding it to the ladder would spend rungs meant for defects.
  local arc=0; apply_stage "$seg" || arc=$?
  # 2 is the ACT arm here too — refused before touching anything, so nothing is
  # in an unknown state and no radius is stopped. 1 is 적용 불명, the only RUN
  # scope this driver reaches from a segment.
  [ "$arc" = "2" ] && return 4
  [ "$arc" = "0" ] || return 3

  wt_remove_or_defer "$seg"
  return 0
}

# ---------------------------------------------------------------------------
# State machine
# ---------------------------------------------------------------------------
main_loop() {
  log "런 시작 run-id=$RUN_ID doc=$DOC slug=$SLUG base=$BASE"
  ledger_row 'run' "run-id=$RUN_ID" "시작=$(now_iso)" "설계 문서=$DOC_KEY" \
    "전체 sha256=$(shasum -a 256 "$DOC" | cut -d' ' -f1)" "RUN_DIR=$RUN_DIR" "보고서=$(report_path)"
  report_append "개시" "run-id=$RUN_ID · 문서 $DOC_KEY · 권한 절단점 $(grant_field "$RUN_ID" '권한 절단점')"

  # S2 AUDIT — headless, one pass. Runs before any segment, so the freeze window
  # never overlaps a sibling worktree creation on the first pass; only a
  # RE-audit can, and the quiet window covers that.
  quiet_window_begin
  dispatch_stage S2 "$(alias_root "$(home_alias)")" "/cc-cmds:design-audit-unattended $DOC"
  quiet_window_end
  local rc2 pred2 class2
  rc2=$(cat "$RUN_DIR/S2.rc" 2>/dev/null || printf '1')
  if predicate_audit S2; then pred2=0; else pred2=1; fi
  class2=$(classify_termination S2 "$rc2" "$pred2")
  ledger_row 'stage-result' "세그먼트=-" "스테이지=S2" "종료 코드=$rc2" \
    "아티팩트 술어 결과=$pred2" "실행 버전=$("$CLI_BIN" --version 2>/dev/null | sed -n '1p')" \
      "세션 id=$(stage_session_id "$sid")" "부모=$(stage_parent_id)" "종단 부류=$class2"
  case "$class2" in
    '정상 완료') : ;;
    '의도된 park') park "S2" run 무효화 "게이트 park" "중단 기록 존재" "$(sed -n 's/^\*\*재호출 명령\*\*: //p' "$RUN_DIR/halt/S2.md" 2>/dev/null)"; return 0 ;;
    *) park "S2" run 무효화 "게이트 park" "종단 부류 $class2"; return 0 ;;
  esac

  # S3 SEGMENT-PLAN — routed by the three-branch predicate.
  #
  # A field-complete declaration means the SHELL builds the plan and the planner
  # is never dispatched: there is no judgement, so there is nothing to gate. The
  # gate exists only on the branch that still relies on one.
  local branch
  branch=$(slicing_branch "$DOC")
  log "선언 분기: $branch"
  case "$branch" in
    '선언통치')
      plan_from_declaration "$DOC"
      report_append "계획" "선언된 슬라이싱을 축자로 채택 — 계획기 미디스패치"
      ;;
    '선언불완전')
      # A real author-grouping signal that is mechanically incomplete. Dispatch
      # the planner, and park on a false adoption flag rather than proceeding.
      SLICING_GATED=1
      plan_via_planner "$DOC" || return 0
      ;;
    *)
      plan_via_planner "$DOC" || return 0
      ;;
  esac

  # S4..S9 — a topological walk over the declared dependency graph. Both plan
  # builders emit the SAME shell-readable form, so this loop does not care which
  # branch produced it; that is what lets the declaration bypass the planner
  # without forking the execution path.
  ladder_init
  local merged=0 parked=0 landed=0 total=0 seg files rc
  total=$(grep -c . "$RUN_DIR/plan.tsv" 2>/dev/null || printf '0')
  RUN_CYCLE_BUDGET=$(run_cycle_budget)
  ledger_row 'generation' "세대=$(generation_now)" "전체 sha256=$(whole_digest)" \
    "런 사이클 예산=$RUN_CYCLE_BUDGET" "세대 상한=$GENERATION_MAX" \
    "벽시계 마감=$( [ -n "$MANIFEST" ] && manifest_field '인가' '벽시계 마감' || printf '(없음)' )"
  while IFS="$(printf '\t')" read -r seg repo files deps; do
    [ -n "$seg" ] || continue
    # The other of the two loop heads that read the deadline.
    if past_deadline; then
      park "$seg" cone 무효화 "예산·벽시계" "벽시계 마감 경과 — 디스패치하지 않는다"
      parked=$((parked + 1)); continue
    fi
    if in_halted_radius "$seg"; then
      park "$seg" cone 무효화 "게이트 park" "앞선 적용 불명의 폭발 반경 안 — 디스패치하지 않는다"
      parked=$((parked + 1)); continue
    fi
    # Dependency guard on a serial traversal. A serial walk of a topological
    # order IS a complete DAG implementation — layers are not parallelism.
    if ! deps_satisfied "$deps"; then
      park "$seg" cone 무효화 "게이트 park" "선행 슬라이스가 완료되지 않음: $deps"
      parked=$((parked + 1)); continue
    fi
    cross_repo_deps "$seg" "$deps"
    rc=0
    segment_cycle "$seg" "$files" || rc=$?
    case "$rc" in
      0) merged=$((merged + 1)); printf '%s\n' "$seg" >> "$RUN_DIR/done.txt" ;;
      2) local g; g=$(generation_bump)
         ledger_row 'generation' "세대=$g" "전체 sha256=$(whole_digest)" "사유=구속면 다이제스트 이동"
         if [ "$g" -gt "$GENERATION_MAX" ]; then
           log "세대 상한 $GENERATION_MAX 초과 — 런을 멈추고 아침 배치로 넘긴다"
           park "$seg" run 무효화 "예산·벽시계" "세대 상한 ${GENERATION_MAX} 초과 — 재계획을 반복하지 않는다"
           RUN_HALTED=1
         else
           log "재계획 필요(세대 $g) — 남은 세그먼트를 park 하고 아침에 넘긴다"
           park "$seg" run 무효화 "자동 채택 미달" "재수렴이 구속면을 움직여 세그먼트 계획이 낡음"
         fi
         parked=$((parked + 1)) ;;
      3) # An apply of unknown outcome. The stop is the DECLARED radius and
         # nothing wider — widening it would turn one unjudgeable state into a
         # night that produced nothing, and narrowing it would let later
         # segments build on a state nobody can describe.
         radius_park "$seg" "$APPLY_PARKED_RADIUS"
         parked=$((parked + 1)) ;;
      4) # 완성-미착지. A terminal act was blocked and NOTHING else was. The
         # segment's branch, commits, review and pull request all survive, and
         # the morning report carries the command that finishes it. This arm is
         # the whole point of the anti-rule: without it these became segment
         # parks and a single cutpoint typo emptied the night.
         landed=$((landed + 1))
         report_append "완성-미착지" "$seg — 산출물은 전부 보존됐고 말단 행위 하나만 막혔다" ;;
      *) parked=$((parked + 1)) ;;
    esac
  done < "$RUN_DIR/plan.tsv"

  ledger_row 'cost' "누적 usd=$(cat "$RUN_DIR"/log/*.json 2>/dev/null | jq -s 'map(.total_cost_usd // 0) | add // 0' 2>/dev/null || printf '0')" \
    "관측 시각=$(now_iso)"
  report_append "종료" "머지 ${merged}건 · 완성-미착지 ${landed}건 · 보류 ${parked}건 · 슬라이스 ${total}개 · 사이클 ${RUN_CYCLES}/${RUN_CYCLE_BUDGET}"
  log "런 종료 (머지 $merged · 완성-미착지 $landed · 보류 $parked)"
}

# Record the radius an unknown apply outcome stops, and hold it so the walk can
# refuse the segments inside it. The radius is DECLARED — the driver cannot
# verify that it is the right one, which is exactly why it is a field a human
# fills rather than something inferred here.
RUN_HALTED=0
radius_park() {
  local seg="$1" radius="$2" d
  case "$radius" in
    '런')
      RUN_HALTED=1
      log "적용 불명 — 폭발 반경 '런', 이후 디스패치 중단" ;;
    '레포')
      seg_alias "$seg" > "$RUN_DIR/halted-repo.txt" 2>/dev/null || : > "$RUN_DIR/halted-repo.txt"
      log "적용 불명 — 폭발 반경 '레포', 같은 레포의 남은 세그먼트를 park" ;;
    *)
      printf '%s\n' "$radius" | tr ',' '\n' | while IFS= read -r d; do
        d=$(printf '%s' "$d" | sed 's/^[[:space:]]*슬라이스[[:space:]]*//; s/[[:space:]]*$//')
        [ -n "$d" ] && printf '%s\n' "$d" >> "$RUN_DIR/halted-segments.txt"
      done
      log "적용 불명 — 폭발 반경 '$radius'" ;;
  esac
}

# Is this segment inside a radius an earlier apply stopped?
in_halted_radius() {
  local seg="$1" hr
  [ "$RUN_HALTED" = "1" ] && return 0
  grep -qxF "$seg" "$RUN_DIR/halted-segments.txt" 2>/dev/null && return 0
  hr=$(cat "$RUN_DIR/halted-repo.txt" 2>/dev/null || printf '')
  [ -n "$hr" ] && [ "$hr" = "$(seg_alias "$seg" 2>/dev/null)" ] && return 0
  return 1
}

# Stacking happens only INSIDE one repository. A segment whose predecessor lives
# in another repo cannot branch from that predecessor's merge — there is no such
# commit in its repository — so the dependency buys ORDER and nothing more. The
# distinction is invisible in the plan (both are just `선행`) and it is the most
# likely place a first multi-repo run diverges from what the author pictured, so
# it is recorded rather than assumed understood.
cross_repo_deps() {
  local seg="$1" deps="$2" mine d other
  case "$deps" in ''|'-'|'없음') return 0 ;; esac
  mine=$(seg_alias "$seg") || return 0
  printf '%s\n' "$deps" | tr ',' '\n' | while IFS= read -r d; do
    d=$(printf '%s' "$d" | sed 's/^[[:space:]]*슬라이스[[:space:]]*//; s/[[:space:]]*$//')
    [ -n "$d" ] || continue
    other=$(seg_alias "$d") || continue
    [ "$other" = "$mine" ] && continue
    log "$seg: 선행 $d 는 레포가 달라 쌓기가 아니라 순서만 보장된다 ($other -> $mine)"
    report_append "레포 간 선행" "$seg ← $d — 레포가 달라 커밋을 쌓지 않고 순서만 보장한다"
  done
  return 0
}

# An empty plan cell is written as `-`; see the note at the writer.
plan_cell() { local v="$1"; [ -n "$v" ] && printf '%s' "$v" || printf '-'; }
plan_uncell() { local v="$1"; [ "$v" = "-" ] && printf '' || printf '%s' "$v"; }

# `선행` is satisfied when every named slice is in this run's done list. The
# literal `없음` is a POSITIVE statement of independence; a missing line is not,
# which is why the field is required rather than optional.
deps_satisfied() {
  local deps="$1" d
  case "$deps" in ''|'-'|'없음') return 0 ;; esac
  # The trailing newline is required, not cosmetic: `read` returns non-zero on a
  # final line that has none, so the loop body never runs for the LAST item and
  # a one-element `선행` list is satisfied vacuously — every dependency guard
  # passes and the topological walk degenerates into arbitrary order.
  printf '%s\n' "$deps" | tr ',' '\n' | while IFS= read -r d; do
    d=$(printf '%s' "$d" | sed 's/^[[:space:]]*슬라이스[[:space:]]*//; s/[[:space:]]*$//')
    [ -n "$d" ] || continue
    grep -qxF "$d" "$RUN_DIR/done.txt" 2>/dev/null || exit 1
  done
}

# Shell-built plan from the declaration. No model in this path at all.
plan_from_declaration() {
  local doc="$1" declared derived id
  declared=$(slicing_body "$doc" | sed -n 's/^\*\*슬라이스 수\*\*: //p')
  derived=$(slicing_pr_count "$doc")
  # `슬라이스 수` is a checksum, so a mismatch means the declaration was
  # truncated or misnumbered — worth stopping for rather than guessing which
  # number was meant.
  if [ -n "$declared" ] && [ "$declared" != "$derived" ]; then
    park "S3" run 무효화 "게이트 park" "슬라이스 수 체크섬 불일치: 선언 ${declared} vs 파생 ${derived}"
    return 1
  fi
  ledger_row 'generation' "세대=$(generation_now)" "전체 sha256=$(whole_digest)" \
    "세그먼트 계획=$(slice_ids "$doc" | tr '\n' ',' | sed 's/,$//')" "segmentation=선언"
  : > "$RUN_DIR/plan.tsv"; : > "$RUN_DIR/done.txt"
  for id in $(slice_ids "$doc"); do
    # `-` for an absent value, never an empty column. Tab is an IFS WHITESPACE
    # character, so `IFS=tab read a b c d` collapses a run of tabs and every
    # field after an empty one shifts left by one — the declared files would be
    # read as the repo and the dependencies as the files. Measured: a two-file
    # segment came back with F=1 and its budget silently halved.
    printf '%s\t%s\t%s\t%s\n' "$id" \
      "$(plan_cell "$(slice_field "$doc" "$id" '레포')")" \
      "$(plan_cell "$(slice_field "$doc" "$id" '선언 파일')")" \
      "$(plan_cell "$(slice_field "$doc" "$id" '선행')")" >> "$RUN_DIR/plan.tsv"
    ledger_row 'segment' "id=$id" "상태=계획됨" \
      "선언 파일 집합=$(slice_field "$doc" "$id" '선언 파일')" \
      "레포=$(slice_field "$doc" "$id" '레포')" \
      "선행=$(slice_field "$doc" "$id" '선행')" \
      "절단점=$(slice_field "$doc" "$id" '절단점')" \
      "plan-binding-digest=$(binding_digest)" "워크트리=$(wt_path "$id")"
  done
  return 0
}

# Planner-built plan. This is the only path where the adoption flag has a job.
plan_via_planner() {
  local doc="$1" plan_out plan seg_mode adopted seg
  if ! plan_out=$(judgment_call segment-plan "$doc"); then
    park "S3" run 무효화 "게이트 park" "세그먼트 계획 판단 호출 실패"
    return 1
  fi
  plan=$(judgment_result "$plan_out")
  adopted=$(printf '%s' "$plan" | jq -r '.author_grouping_adopted // false')
  # THE GATE. It keys on the adoption flag, never on `segmentation` — that field
  # reported `ok` twice during a total-loss run, so it is uncorrelated with
  # failure, while the adoption flag is already a required boolean in the
  # shipped schema and refused an adversarial prose instruction to lie.
  if [ "${SLICING_GATED:-0}" = "1" ] && [ "$adopted" != "true" ]; then
    park "S3" run 무효화 "게이트 park" "선언은 있으나 필드가 불완전하고 계획기가 그것을 채택하지 않았다 (author_grouping_adopted=$adopted)"
    return 1
  fi
  if [ "${SLICING_GATED:-0}" = "1" ]; then
    # Adopted despite the incomplete fields: the two detectors disagree. Not a
    # silent proceed — it is recorded as an autonomous decision so the morning
    # audit sees which detector won and on what.
    ledger_row '자율 승인' "kind=citation" "결정=계획기의 채택을 수용" \
      "기각된 대안=선언 불완전을 이유로 park" "근거=author_grouping_adopted=true"
    report_append "탐지기 불일치" "선언 필드는 불완전한데 계획기가 채택했다 — 계획기 판정을 따르고 기록한다"
  fi
  seg_mode=$(printf '%s' "$plan" | jq -r '.segmentation // "low-confidence"')
  ledger_row 'generation' "세대=$(generation_now)" "전체 sha256=$(whole_digest)" \
    "세그먼트 계획=$(printf '%s' "$plan" | jq -c '.segments | map(.id)')" "segmentation=$seg_mode"
  : > "$RUN_DIR/plan.tsv"; : > "$RUN_DIR/done.txt"
  for seg in $(printf '%s' "$plan" | jq -r '.segments[].id'); do
    printf '%s\t%s\t%s\t%s\n' "$seg" "-" \
      "$(plan_cell "$(printf '%s' "$plan" | jq -r --arg s "$seg" '.segments[] | select(.id==$s) | .declared_files | join(", ")')")" \
      "$(plan_cell "$(printf '%s' "$plan" | jq -r --arg s "$seg" '.segments[] | select(.id==$s) | .depends_on | join(", ")')")" >> "$RUN_DIR/plan.tsv"
    ledger_row 'segment' "id=$seg" "상태=계획됨" \
      "선언 파일 집합=$(printf '%s' "$plan" | jq -c --arg s "$seg" '.segments[] | select(.id==$s) | .declared_files')" \
      "plan-binding-digest=$(binding_digest)" "워크트리=$(wt_path "$seg")"
  done
  return 0
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

while [ $# -gt 0 ]; do
  case "$1" in
    --manifest)   MANIFEST="$2"; shift 2 ;;
    --doc)        DOC="$2"; shift 2 ;;
    --run-id)     RUN_ID="$2"; shift 2 ;;
    --self-check) self_check; exit $? ;;
    *) echo "run.sh: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

# Entry-time platform gate. It sits BEFORE any argument is honoured and before
# any state is touched, because the point of refusing is that nothing partial
# happens. `--self-check` is deliberately upstream of this line: it is the
# diagnostic that reports which branch the seam picked, so it has to run on the
# arm that is being refused.
platform_supported || platform_refuse || exit $?

# A run is about a MANIFEST. `--doc` remains accepted as the degenerate case —
# one document, one target — because absorbing it costs one branch here and
# keeps a document-only invocation working without a second schema anywhere
# else. What is no longer true is that a document is REQUIRED: a run anchored on
# a pull request, a branch, or a bare intent has no document to name.
if [ -n "$MANIFEST" ]; then
  [ -f "$MANIFEST" ] || { echo "run.sh: manifest not found: $MANIFEST" >&2; exit 2; }
  check_manifest
  derive_paths_from_manifest
elif [ -n "$DOC" ]; then
  [ -f "$DOC" ] || { echo "run.sh: design document not found: $DOC" >&2; exit 2; }
  derive_paths
  [ -n "$RUN_ID" ] || RUN_ID=$(grant_blocks | tail -1)
  [ -n "$RUN_ID" ] || { echo "run.sh: --run-id is required when the grant has no block" >&2; exit 2; }
else
  echo "run.sh: --manifest <abs-path> (or --doc <abs-path> for the degenerate case) is required" >&2
  exit 2
fi

rundir_init

check_grant
ledger_init
notify_probe
main_loop
notify_cleanup
