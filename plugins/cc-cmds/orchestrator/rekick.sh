#!/usr/bin/env bash
#
# rekick.sh — the autopilot kickoff's reader of a previous run, for a re-kickoff.
#
# When the same session calls the kickoff again after a run it opened has
# stopped, the kickoff may carry that run's answers into a new run instead of
# asking them again. This program finds that run, decides whether it may be
# carried, checks that its frozen files are intact, removes the steps the
# ledger proves finished, and renders the new manifest draft and the checks the
# draft must pass. It decides nothing a person has to answer: every value it
# renders is either byte-identical to the previous run, re-derived here, or an
# answer the kickoff passes in.
#
# IT WRITES NOTHING. Not into the previous run's directory, not into its ledger,
# not under `<base>`. The only files it makes are private copies in `TMPDIR`
# (mode 600, removed on exit), and every read of a previous run's manifest,
# authorization record and interview record is of such a copy — so the bytes it
# measured are the bytes it reads.
#
# ONLY THE KICKOFF CALLS THIS. Inside a pipeline run (`CC_PIPELINE_RUN_ID`,
# `CC_PIPELINE_STAGE_ID` or `CC_PIPELINE_SHIFT_ID` set) it refuses with exit 3
# before it reads anything.
#
# THE GATE IS NEVER SOURCED INTO THIS SHELL. `gate.sh` sources `run.sh` again,
# and `run.sh`'s top-level `readonly` lines die on a second source in a shell
# that already has them; a `( )` subshell inherits the attribute and does not
# help. The two gate functions this program asks — whether the gate ended the
# run, and whether the authorization record passes the gate's own check — run in
# a separate `bash` that sources only the gate through its definitions-only
# seam, the shape `run_gate_call` uses. That child compares the return with the
# gate's own `GATE_EXIT_RULE`, so the number is not written here. A child that
# cannot source the gate, or a return that is neither 0 nor that value, is "not
# decidable" and the run is reported `열림`.
#
# Usage
#
#   rekick.sh detect --arg <인자>
#   rekick.sh verify --prev <id> --base <base>
#   rekick.sh graph --prev <id> --base <base> [--expect-sha256 <hex>] [--accepted <별칭,…>]
#   rekick.sh render-manifest --prev <id> --base <base> --run-id <new> --kickoff-at <ISO8601>
#                             --deadline <ISO8601> --expect-sha256 <hex> --expect-grant-sha256 <hex>
#                             [--arg <인자>] [--asked <TSV>] [--visual-marker <값>]
#                             [--targets <파일>] [--rows <파일>] [--rule <키>=<켬|끔>]…
#                             [--bind-base <hex>] [--set <범위>:<키>=<값>]…
#   rekick.sh render-interview --prev <id> --base <base> [--expect-sha256 <hex>]
#   rekick.sh verify-subset <초안> <이전 매니페스트> --expect-sha256 <hex>
#                           --expect-grant-sha256 <hex> --asked <TSV> [--grant <블록 파일>]
#                           [--set <범위>:<키>=<값>]…
#
# `--set` carries a value 5o confirmed for a `빈칸` row of `--carry`: `<범위>`
# is that row's scope (`런`, or a target alias) and `<키>` its key, one of
# ladder-rungs · stagnation-bound · cost-ceiling · apply-probe · apply-actor
# (scope `런`) or cutpoint · review-ceiling · terminal-cap · dev-ids ·
# deploy-triggers (a target alias). The previous manifest must hold no value
# there; anything else is refused. `render-manifest` writes the value into the
# draft and `verify-subset` takes the same `--set` list, so the draft's value is
# compared with the confirmed one rather than exempted.
#
# `detect` takes no `<base>`: the kickoff resolves its own `<base>` only after
# the targets are settled, and this step runs before that. Each candidate's
# `<base>` comes from its run directory's `ledger-path`, and the `재킥오프`
# verdict carries it for the modes that follow.
#
# Output is TAB-separated and starts with the line `cc-rekick v1`, except
# `render-manifest` (the draft's bytes) and `render-interview` (the record's
# bytes), which print nothing else.
#
#   detect         판정  재킥오프|새 런|없음|열림|완료  [<id>  [<base>]]
#                  갈래  게이트 종료|강제 표면 이동 무효화
#                  킥오프  <이전 킥오프 일시>
#                  종료 표시  <게이트가 남긴 종료 표시>
#                  고지  <한 줄>          굵게  <굵게 보일 한 줄>
#   verify         검사  다이제스트|인터뷰|인가|머리  통과|실패  <사유>
#                  해시  매니페스트|인가 기록|인터뷰  <hex|->
#                  베이스설계  <문서>  <행 sha256>  <지금 sha256|->
#                  질문  베이스설계  <문서>  <행 sha256>  <지금 sha256>
#                  값  <이름>  <값>        대상  <대상 행>
#                  판정  통과|실패  [<실패한 검사, …>]
#   graph          범위  single|base       설계|감사  뺌|남음|없음  <근거>
#                  건너뜀  <id>  <skill>  <근거>     남음  <id>  <skill>  <depends_on|->
#                  계획  <JSON 한 줄>      문서해시  <hex|->
#                  대상추가  <별칭>  <원격 슬러그>  <메인 워크트리>  <공통 git 디렉터리>  <베이스 브랜치>
#                  그래프  순수 | 바뀜  <사유>
#   verify-subset  검사  <이름>  통과|실패  <사유>
#                  판정  통과|실패  [<실패한 검사, …>]
#
# The `--asked` file lists the questions this re-kickoff actually asked, one
# `<키><TAB><답 축자>` per line. The keys the checks read: `대상확인 <별칭>`,
# `대상추가 <별칭>`, `5p`, `5q`, `5e`, `5e 값`, `5l`, `5o <키>`,
# `7.7 절단점 <별칭>`, `7.7 룰 <키>`, `7.7 자동채택`, `7.8`. Any other key covers
# nothing, and every answer, whatever its key, must stand verbatim in the
# draft's `사용자 확인 문면`. `5e` is the person's answer as given — a relative
# form such as `+8h` included — and `5e 값` the absolute instant the kickoff
# resolved it to once; the deadline check compares the draft with the latter as
# an instant. A key asked twice counts by its last line.
#
# Exit codes: 0 read (a `verify` or `verify-subset` that passed) · 1 a check
# failed (`verify`, `verify-subset`, `render-interview`, a hash that does not
# match) · 2 usage · 3 refused (inside a run) or the driver's vocabulary could
# not be read. On 2 and 3, and on 1 from `render-manifest`, `render-interview`
# and `graph`, stdout is empty and stderr carries one line.
#
# Compatibility: bash 3.2 — no associative arrays, no `mapfile`. Time is
# computed with jq only.

set -uo pipefail

RK_PROG='rekick.sh'
RK_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)

rk_refuse() { printf '%s: %s\n' "$RK_PROG" "$1" >&2; exit 3; }
rk_usage()  { printf '%s: %s\n' "$RK_PROG" "$1" >&2; exit 2; }
rk_fail()   { printf '%s: %s\n' "$RK_PROG" "$1" >&2; exit 1; }

for rk_v in CC_PIPELINE_RUN_ID CC_PIPELINE_STAGE_ID CC_PIPELINE_SHIFT_ID; do
  eval "rk_val=\${$rk_v:-}"
  if [ -n "$rk_val" ]; then
    rk_refuse "파이프라인 런 안에서는 읽지 않습니다 — 재킥오프는 킥오프만 읽습니다 ($rk_v 가 설정돼 있습니다)"
  fi
done

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------
RK_MODE="${1:-}"
[ $# -gt 0 ] && shift
RK_ARG=""; RK_ARG_GIVEN=0; RK_PREV=""; RK_BASE=""; RK_XSHA=""; RK_XGSHA=""
RK_ACCEPTED=""; RK_NEWID=""; RK_KAT=""; RK_DEADLINE=""; RK_ASKED=""
RK_VISUAL=""; RK_TARGETS=""; RK_ROWS=""; RK_RULES=""; RK_BIND=""; RK_GRANT_BLOCK=""
RK_POS1=""; RK_POS2=""; RK_SETS=""

rk_need() { [ $# -ge 2 ] || rk_usage "$1 에 값이 없습니다"; }
while [ $# -gt 0 ]; do
  case "$1" in
    --arg)                 rk_need "$@"; RK_ARG="$2"; RK_ARG_GIVEN=1; shift 2 ;;
    --prev)                rk_need "$@"; RK_PREV="$2"; shift 2 ;;
    --base)                rk_need "$@"; RK_BASE="$2"; shift 2 ;;
    --expect-sha256)       rk_need "$@"; RK_XSHA="$2"; shift 2 ;;
    --expect-grant-sha256) rk_need "$@"; RK_XGSHA="$2"; shift 2 ;;
    --accepted)            rk_need "$@"; RK_ACCEPTED="$2"; shift 2 ;;
    --run-id)              rk_need "$@"; RK_NEWID="$2"; shift 2 ;;
    --kickoff-at)          rk_need "$@"; RK_KAT="$2"; shift 2 ;;
    --deadline)            rk_need "$@"; RK_DEADLINE="$2"; shift 2 ;;
    --asked)               rk_need "$@"; RK_ASKED="$2"; shift 2 ;;
    --visual-marker)       rk_need "$@"; RK_VISUAL="$2"; shift 2 ;;
    --targets)             rk_need "$@"; RK_TARGETS="$2"; shift 2 ;;
    --rows)                rk_need "$@"; RK_ROWS="$2"; shift 2 ;;
    --rule)                rk_need "$@"
                           case "$2" in
                             *=켬|*=끔) ;;
                             *) rk_usage "--rule 은 <키>=<켬|끔> 입니다: '$2'" ;;
                           esac
                           RK_RULES="${RK_RULES}${2}
"; shift 2 ;;
    --bind-base)           rk_need "$@"; RK_BIND="$2"; shift 2 ;;
    --grant)               rk_need "$@"; RK_GRANT_BLOCK="$2"; shift 2 ;;
    --set)                 rk_need "$@"
                           case "$2" in
                             *"$(printf '\t')"*|*'
'*) rk_usage "--set 값에 탭이나 줄바꿈이 있습니다" ;;
                             ?*:?*=?*) ;;
                             *) rk_usage "--set 은 <범위>:<키>=<값> 입니다: '$2'" ;;
                           esac
                           RK_SETS="${RK_SETS}${2}
"; shift 2 ;;
    --*)                  rk_usage "알 수 없는 인자입니다: $1" ;;
    *)
      if [ -z "$RK_POS1" ]; then RK_POS1="$1"
      elif [ -z "$RK_POS2" ]; then RK_POS2="$1"
      else rk_usage "위치 인자가 너무 많습니다: $1"; fi
      shift ;;
  esac
done

rk_hex64() { case "$1" in *[!0-9a-f]*|'') return 1 ;; esac; [ "${#1}" = "64" ]; }
rk_id_ok() {
  case "$1" in ''|.|..|*/*|*[!A-Za-z0-9._-]*) return 1 ;; esac
  return 0
}
rk_need_prev() {
  rk_id_ok "$RK_PREV" || rk_usage "--prev 는 런 id 하나여야 합니다: '$RK_PREV'"
  case "$RK_BASE" in /*) ;; *) rk_usage "--base 는 절대 경로여야 합니다: '$RK_BASE'" ;; esac
}

case "$RK_MODE" in
  detect)
    [ "$RK_ARG_GIVEN" = "1" ] || rk_usage "detect 에는 --arg 가 필요합니다 (빈 인자는 --arg '')" ;;
  verify|render-interview)
    rk_need_prev ;;
  graph)
    rk_need_prev
    [ -z "$RK_XSHA" ] || rk_hex64 "$RK_XSHA" || rk_usage "--expect-sha256 은 64자리 소문자 16진수입니다" ;;
  render-manifest)
    rk_need_prev
    rk_id_ok "$RK_NEWID" || rk_usage "--run-id 는 런 id 하나여야 합니다: '$RK_NEWID'"
    [ "$RK_NEWID" != "$RK_PREV" ] || rk_usage "--run-id 가 --prev 와 같습니다"
    [ -n "$RK_KAT" ] || rk_usage "render-manifest 에는 --kickoff-at 이 필요합니다"
    [ -n "$RK_DEADLINE" ] || rk_usage "render-manifest 에는 --deadline 이 필요합니다"
    rk_hex64 "$RK_XSHA" || rk_usage "--expect-sha256 은 64자리 소문자 16진수입니다"
    rk_hex64 "$RK_XGSHA" || rk_usage "--expect-grant-sha256 은 64자리 소문자 16진수입니다"
    [ -z "$RK_BIND" ] || rk_hex64 "$RK_BIND" || rk_usage "--bind-base 는 64자리 소문자 16진수입니다" ;;
  verify-subset)
    [ -n "$RK_POS1" ] && [ -n "$RK_POS2" ] || rk_usage "verify-subset 에는 <초안> 과 <이전 매니페스트> 가 필요합니다"
    rk_hex64 "$RK_XSHA" || rk_usage "--expect-sha256 은 64자리 소문자 16진수입니다"
    rk_hex64 "$RK_XGSHA" || rk_usage "--expect-grant-sha256 은 64자리 소문자 16진수입니다"
    [ -n "$RK_ASKED" ] || rk_usage "verify-subset 에는 --asked 가 필요합니다 (물은 것이 없으면 빈 파일)" ;;
  '') rk_usage "모드가 없습니다 — detect | verify | graph | render-manifest | render-interview | verify-subset" ;;
  *)  rk_usage "알 수 없는 모드입니다: $RK_MODE" ;;
esac
[ -z "$RK_ASKED" ] || [ -r "$RK_ASKED" ] || rk_usage "--asked 파일을 읽을 수 없습니다: $RK_ASKED"
[ -z "$RK_TARGETS" ] || [ -r "$RK_TARGETS" ] || rk_usage "--targets 파일을 읽을 수 없습니다: $RK_TARGETS"
[ -z "$RK_ROWS" ] || [ -r "$RK_ROWS" ] || rk_usage "--rows 파일을 읽을 수 없습니다: $RK_ROWS"
[ -z "$RK_GRANT_BLOCK" ] || [ -r "$RK_GRANT_BLOCK" ] || rk_usage "--grant 파일을 읽을 수 없습니다: $RK_GRANT_BLOCK"

# ---------------------------------------------------------------------------
# Vocabulary and readers — sourced from the driver, never copied.
# ---------------------------------------------------------------------------
[ -r "$RK_DIR/run.sh" ] || rk_refuse "run.sh 를 읽을 수 없습니다: $RK_DIR/run.sh"
# shellcheck disable=SC1091
CC_ORCH_SOURCE_ONLY=1 . "$RK_DIR/run.sh" >/dev/null 2>&1 || rk_refuse "run.sh 를 들여오지 못했습니다"
set +e +u
set +o pipefail
[ -n "${CUTPOINTS:-}" ] || rk_refuse "run.sh 에서 절단점 어휘를 읽지 못했습니다"
for rk_f in manifest_field manifest_hdr_field manifest_row_fields manifest_plan_json manifest_plan_field \
            manifest_targets manifest_rule_lines manifest_preauth_rows manifest_autoadopt_rows_anywhere \
            manifest_design_roster_rows_anywhere manifest_clause_rows_raw manifest_base_design_rows \
            manifest_design_scope target_field target_aliases canonical_targets binding_set_bytes \
            check_manifest rundir_of_run_id deadline_instant cutpoint_index \
            judgment_class_ok judgment_class_forbidden \
            cc_live_stages cc_shift_is_live cc_unresolved_blocked cc_open_approval_rows cc_segment_states; do
  command -v "$rk_f" >/dev/null 2>&1 || rk_refuse "run.sh 에 $rk_f 가 없습니다"
done

RK_TMP=$(mktemp -d "${TMPDIR:-/tmp}/cc-rekick.XXXXXX" 2>/dev/null) || rk_refuse "개인 임시 디렉터리를 만들지 못했습니다"
chmod 700 "$RK_TMP" 2>/dev/null || rk_refuse "개인 임시 디렉터리의 권한을 700 으로 두지 못했습니다"
trap 'rm -rf "$RK_TMP"' EXIT

TAB=$(printf '\t')

rk_sha() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" 2>/dev/null | awk '{ print $1 }'
  else
    sha256sum "$1" 2>/dev/null | awk '{ print $1 }'
  fi
}
rk_sha_stdin() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 | awk '{ print $1 }'
  else sha256sum | awk '{ print $1 }'; fi
}

# rk_copy <source> <name> — the private copy's path, or nothing. Mode 600.
rk_copy() {
  local dst="$RK_TMP/$2"
  [ -f "$1" ] && [ -r "$1" ] || return 1
  ( umask 077; cat -- "$1" > "$dst" ) 2>/dev/null || return 1
  chmod 600 "$dst" 2>/dev/null || return 1
  printf '%s' "$dst"
}

# rk_wide_instant <value> — epoch seconds, or nothing. A trailing `Z` and a
# trailing `±HHMM` are rewritten to `±HH:MM` first, and the driver's own reader
# decides the rest: it renders the value back to itself and refuses an offset
# beyond ±14:00, so no instant the gate would refuse is read here.
rk_wide_instant() {
  local s
  s=$(jq -rn --arg s "$1" '$s | sub("Z$"; "+00:00") | sub("(?<g>[+-])(?<h>[0-9]{2})(?<m>[0-9]{2})$"; "\(.g)\(.h):\(.m)")' 2>/dev/null) || s=''
  [ -n "$s" ] || return 0
  deadline_instant "$s"
}

rk_trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# rk_intent — the fenced text under `## 의도`, whole, of the current MANIFEST.
rk_intent() {
  awk '
    $0 == "## 의도" { inb = 1; next }
    inb && /^## / { exit }
    inb && /^```/ { if (fence) exit; fence = 1; next }
    inb && fence { print }
  ' "$MANIFEST"
}

# rk_prev_paths — the previous run's files, from its id and `<base>`.
rk_prev_paths() {
  RK_PM="$RK_BASE/docs/pipeline-run/$RK_PREV.plan.md"
  RK_PG="$RK_BASE/docs/pipeline-grant/$RK_PREV.md"
  RK_PL="$RK_BASE/docs/pipeline-run/$RK_PREV.md"
  RK_PRD=$(rundir_of_run_id "$RK_PREV" 2>/dev/null) || RK_PRD=""
}

# rk_interview_rows — the interview rows of the current MANIFEST.
rk_interview_rows() { manifest_preauth_rows | grep -E '^- `사전 인가` \| 인터뷰 기록=' || true; }
# rk_carry_rows — the provenance rows (first field `이어받은 런=`).
rk_carry_rows() { manifest_preauth_rows | grep -E '^- `사전 인가` \| 이어받은 런=' || true; }
# rk_shape_rows — the `사전 인가` rows that carry a shape.
rk_shape_rows() { manifest_preauth_rows | grep -E '^- `사전 인가` \| 형태=' || true; }

# rk_cut_max <rows…> — the highest cutpoint token over the given target rows,
# or nothing when none of them carries a token in the vocabulary.
rk_cut_max() {
  local row tok i best=0 besttok=""
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    tok=$(manifest_row_fields "$row" '절단점')
    i=$(cutpoint_index "$tok" 2>/dev/null) || continue
    if [ "$i" -gt "$best" ]; then best=$i; besttok=$tok; fi
  done <<EOF
$1
EOF
  printf '%s' "$besttok"
}

# ---------------------------------------------------------------------------
# The gate child. rk_gate <ended|grant> <manifest> <run id> <run dir> <ledger>
# <grant> <stderr file> — prints one fixed token.
# ---------------------------------------------------------------------------
rk_gate() {
  local g="$RK_DIR/gate.sh" out
  [ -r "$g" ] || { printf '판정불가'; return 0; }
  out=$(CC_GATE_SOURCE_ONLY=1 bash -c '
    g=$1; mode=$2; mf=$3; rid=$4; rd=$5; led=$6; gr=$7; err=$8
    set --
    . "$g" >/dev/null 2>&1 || { printf "판정불가"; exit 0; }
    set +e
    unset CC_GATE_SOURCE_ONLY CC_ORCH_SOURCE_ONLY
    MANIFEST=$mf; RUN_ID=$rid; RUN_DIR=$rd; LEDGER=$led; GRANT=$gr
    case "${GATE_EXIT_RULE:-}" in ""|*[!0-9]*) printf "판정불가"; exit 0 ;; esac
    rc=0
    case "$mode" in
      ended)
        gate_run_ended_ok skill - 2>"$err" || rc=$?
        if [ "$rc" = "0" ]; then printf "안끝남"
        elif [ "$rc" = "$GATE_EXIT_RULE" ]; then printf "끝남"
        else printf "판정불가"; fi ;;
      grant)
        gate_check_grant 2>"$err" || rc=$?
        if [ "$rc" = "0" ]; then printf "통과"; else printf "실패"; fi ;;
    esac
  ' _ "$g" "$1" "$2" "$3" "$4" "$5" "$6" "$7" 2>/dev/null)
  case "$out" in
    끝남|안끝남|통과|실패) printf '%s' "$out" ;;
    *) printf '판정불가' ;;
  esac
}

# rk_end_mark <stderr file> — the mark between the gate's fixed prefix and fixed
# suffix. The mark itself carries parentheses, so it is never cut at a bracket;
# a mark of several lines yields its first line.
rk_end_mark() {
  local line m pre='the run has already terminated (' suf=') — no new stage is launched'
  line=$(grep -F "$pre" "$1" 2>/dev/null | head -n 1)
  [ -n "$line" ] || return 0
  m=${line#*"$pre"}
  case "$m" in *"$suf"*) m=${m%"$suf"*} ;; esac
  printf '%s' "$m"
}

# rk_ledger_last <ledger> <series> <field> <value> — the last row of that
# series whose field is exactly that value.
rk_ledger_last() {
  local row hit=""
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    [ "$(manifest_row_fields "$row" "$3" | head -n 1)" = "$4" ] && hit=$row
  done <<EOF
$(grep -E "^- \`$2\`" "$1" 2>/dev/null || true)
EOF
  printf '%s' "$hit"
}

# rk_clause_states <ledger> — `<id><TAB><상태|-><TAB><근거>` for each `종료 절`
# id of the current MANIFEST, from the last ledger row of that id.
rk_clause_states() {
  local row cid last st ev
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    cid=$(manifest_row_fields "$row" 'id' | head -n 1)
    [ -n "$cid" ] || continue
    last=$(rk_ledger_last "$1" '종료 절' 'id' "$cid")
    st=$(manifest_row_fields "$last" '상태' | head -n 1)
    ev=$(manifest_row_fields "$last" '근거' | head -n 1)
    printf '%s\t%s\t%s\n' "$cid" "${st:--}" "$ev"
  done <<EOF
$(manifest_clause_rows_raw)
EOF
}

# ---------------------------------------------------------------------------
# detect
# ---------------------------------------------------------------------------
rk_detect() {
  local sid="${CLAUDE_CODE_SESSION_ID:-}" idx id rd lp b kat e best_id="" best_e="" best_base=""
  printf 'cc-rekick v1\n'
  case "$sid" in ''|.|..|*/*) rk_detect_none ;; esac
  idx="${XDG_STATE_HOME:-$HOME/.local/state}/cc-cmds/session/$sid"
  [ -f "$idx" ] || rk_detect_none
  while IFS= read -r id; do
    rk_id_ok "$id" || continue
    rd=$(rundir_of_run_id "$id" 2>/dev/null) || continue
    [ -d "$rd" ] || continue
    grep -qxF -- "$sid" "$rd/session-lineage" 2>/dev/null || continue
    # The candidate's `<base>` is its ledger path's, and nothing else: a path of
    # any other shape, or none, leaves the latest run undecidable.
    lp=$(head -n 1 "$rd/ledger-path" 2>/dev/null) || lp=""
    case "$lp" in
      /*/docs/pipeline-run/"$id".md) b=${lp%/docs/pipeline-run/"$id".md} ;;
      *) rk_detect_none ;;
    esac
    [ -f "$b/docs/pipeline-run/$id.plan.md" ] || continue
    kat=$(MANIFEST="$b/docs/pipeline-run/$id.plan.md" manifest_field '런 정체' '킥오프 일시')
    e=$(rk_wide_instant "$kat")
    case "$e" in ''|*[!0-9-]*) rk_detect_none ;; esac
    if [ -z "$best_e" ] || [ "$e" -ge "$best_e" ]; then
      best_id=$id; best_e=$e; best_base=$b
    fi
  done <<EOF
$(awk '!seen[$0]++' "$idx" 2>/dev/null)
EOF
  [ -n "$best_id" ] || rk_detect_none
  RK_PREV=$best_id; RK_BASE=$best_base
  rk_prev_paths
  MANIFEST=$(rk_copy "$RK_PM" prev.plan.md) || rk_detect_none

  # The argument.
  local raw n t intent
  raw=$(rk_trim "$RK_ARG")
  n=$(printf '%s' "$raw" | LC_ALL=C tr 'A-Z' 'a-z' | LC_ALL=C tr -d '[:punct:]')
  for t in '해 주세요' '해줘' '하자' 'please'; do
    case "$n" in *"$t") n=${n%"$t"}; break ;; esac
  done
  n=$(rk_trim "$n")
  intent=$(rk_trim "$(rk_intent)")
  case "$n" in
    ''|다시|재킥오프|'다시 킥오프'|이어서|재개|계속|rekick|resume|again|retry) ;;
    *)
      if [ -z "$intent" ] || [ "$raw" != "$intent" ]; then
        printf '판정\t새 런\t%s\n' "$RK_PREV"
        printf '고지\t이 세션이 연 런(%s)과 다른 의도로 보고 새 런으로 시작합니다 — 이어받으려면 인자 없이 다시 부르세요\n' "$RK_PREV"
        exit 0
      fi ;;
  esac

  # Eligibility, in order; the first branch that applies decides.
  local live=0 nlive st ub inv=0 gate_tok mark err
  nlive=$(cc_live_stages "$RK_PRD" 2>/dev/null)
  case "$nlive" in ''|*[!0-9]*) live=1 ;; 0) ;; *) live=1 ;; esac
  if cc_shift_is_live "$RK_PRD" 2>/dev/null; then live=1; fi
  if [ "$live" = "1" ]; then rk_detect_open running; fi

  local states nclause=0 nmet=0 cid cst cev
  states=$(rk_clause_states "$RK_PL")
  while IFS="$TAB" read -r cid cst cev; do
    [ -n "$cid" ] || continue
    nclause=$((nclause + 1))
    [ "$cst" = "충족" ] && nmet=$((nmet + 1))
  done <<EOF
$states
EOF
  if [ "$nclause" -ge 1 ] && [ "$nclause" = "$nmet" ]; then
    printf '판정\t완료\t%s\n' "$RK_PREV"
    printf '고지\t이전 런 %s 은 완료 기준을 모두 채웠습니다 — 이어받을 남은 단계가 없습니다\n' "$RK_PREV"
    printf '고지\t이어받지 않고 처음부터 묻게 하려면 의도를 적어 다시 부르세요\n'
    exit 0
  fi

  ub=$(cc_unresolved_blocked "$RK_PL" 2>/dev/null) || ub=""
  if printf '%s\n' "$ub" | awk -F '\t' '$1 == "무효화" && $2 == "강제 표면 이동" { f = 1 } END { exit !f }'; then
    inv=1
  fi
  err="$RK_TMP/gate.err"
  if [ "$inv" = "0" ]; then
    gate_tok=$(rk_gate ended "$MANIFEST" "$RK_PREV" "$RK_PRD" "$RK_PL" "$RK_PG" "$err")
    [ "$gate_tok" = "끝남" ] || rk_detect_open stopped
    mark=$(rk_end_mark "$err")
  fi

  printf '판정\t재킥오프\t%s\t%s\n' "$RK_PREV" "$RK_BASE"
  if [ "$inv" = "1" ]; then printf '갈래\t강제 표면 이동 무효화\n'; else printf '갈래\t게이트 종료\n'; fi
  printf '킥오프\t%s\n' "$(manifest_field '런 정체' '킥오프 일시')"
  if [ "$inv" = "1" ]; then
    printf '굵게\t이전 런 %s 은 집행 표면이 옮겨져 무효화됐습니다 — 그 런은 재개하지 않습니다\n' "$RK_PREV"
  else
    printf '종료 표시\t%s\n' "$mark"
    printf '굵게\t이전 런 %s 을 끝낸 경계는 같은 값으로 다시 주어집니다 (%s) — 같은 한도가 다시 바닥날 수 있습니다\n' "$RK_PREV" "$mark"
    local parks np=0 why reasons=""
    parks=$(printf '%s\n' "$ub" | awk -F '\t' 'NF >= 2 && $2 != "" { print $2 }')
    while IFS= read -r why; do
      [ -n "$why" ] || continue
      np=$((np + 1)); reasons="${reasons:+$reasons, }$why"
    done <<EOF
$parks
EOF
    if [ "$np" -gt 0 ]; then
      printf '굵게\t이전 런 %s 은 시스템이 끝냈습니다 (%s) — 남은 정박 %s건(%s)은 넘어오지 않고, 이 새 런이 해당 단계를 처음부터 다시 만납니다\n' \
        "$RK_PREV" "$mark" "$np" "$reasons"
    fi
  fi
  local imp_ids="" imp_ev="" hold_ids=""
  while IFS="$TAB" read -r cid cst cev; do
    [ -n "$cid" ] || continue
    case "$cst" in
      불가능) imp_ids="${imp_ids:+$imp_ids, }$cid"; imp_ev="${imp_ev:+$imp_ev; }${cev%%\\n*}" ;;
      보류)   hold_ids="${hold_ids:+$hold_ids, }$cid" ;;
    esac
  done <<EOF
$states
EOF
  [ -z "$imp_ids" ] || printf '굵게\t이전 런 %s 은 종료 절 %s 를 불가능으로 끝냈습니다(%s) — 같은 조건이면 이 새 런도 같은 곳에서 멈출 수 있습니다\n' \
    "$RK_PREV" "$imp_ids" "$imp_ev"
  [ -z "$hold_ids" ] || printf '굵게\t이전 런 %s 의 종료 절 %s 는 보류(사람의 답 대기)로 끝났습니다 — 그 답은 이어받지 않으며 이 새 런이 다시 묻습니다\n' \
    "$RK_PREV" "$hold_ids"
  # Segments that did not land are done again by the new run.
  local seg segst segv pr unl=""
  while IFS="$TAB" read -r seg segst segv; do
    [ -n "$seg" ] || continue
    case "$segst" in 머지됨|완료) continue ;; esac
    pr=$(manifest_row_fields "$(rk_ledger_last "$RK_PL" segment id "$seg")" 'PR' | head -n 1)
    unl="${unl:+$unl, }$seg${pr:+ PR $pr}"
  done <<EOF
$(cc_segment_states "$RK_PL" 2>/dev/null)
EOF
  [ -z "$unl" ] || printf '고지\t이전 런의 머지되지 않은 작업(%s)은 이어받지 않습니다 — 새 런이 그 세그먼트를 다시 합니다\n' "$unl"
  printf '고지\t이어받지 않고 처음부터 묻게 하려면 의도를 적어 다시 부르세요\n'
  exit 0
}

rk_detect_none() {
  printf '판정\t없음\n'
  printf '고지\t이 세션이 연 런을 찾지 못했습니다 — 처음 킥오프처럼 묻습니다\n'
  exit 0
}

# rk_detect_open <running|stopped> — the `열림` verdict and its sentences.
rk_detect_open() {
  local ap n=0 aid acut q reasons="" ub cmds cmd why last
  printf '판정\t열림\t%s\n' "$RK_PREV"
  ap=$(cc_open_approval_rows "$RK_PL" 2>/dev/null) || ap=""
  while IFS="$TAB" read -r aid acut; do
    [ -n "$aid" ] || continue
    n=$((n + 1))
    last=$( { grep -E '^- `승인`' "$RK_PL" 2>/dev/null | grep -F "| 승인 id=$aid |" || true; } | tail -n 1)
    q=$(manifest_row_fields "$last" '질문 문면' | tail -n 1)
    reasons="${reasons:+$reasons, }${q:-$aid}"
  done <<EOF
$ap
EOF
  if [ "$1" = "running" ]; then
    printf '고지\t이전 런 %s 은 아직 돌고 있습니다\n' "$RK_PREV"
  elif [ "$n" -gt 0 ]; then
    printf '고지\t이전 런 %s 은 아직 열려 있습니다 — 승인 대기 %s건(%s). 그 승인에 답하면 그 런이 이어집니다(「Resuming after a break」); 새 런을 열 이유가 아닙니다\n' \
      "$RK_PREV" "$n" "$reasons"
  else
    printf '고지\t이전 런 %s 은 멈춰 있지만 게이트에 종료가 기록되지 않았습니다 — 그 런을 재개해 끝내면 다음 호출에서 이어받습니다. 지금 처음부터 시작하려면 의도를 적어 부르세요\n' "$RK_PREV"
  fi
  # A resume command a still-open block left is quoted verbatim, after the
  # sentence that names both ways out.
  ub=$(cc_unresolved_blocked "$RK_PL" 2>/dev/null) || ub=""
  cmds=""
  while IFS="$TAB" read -r _ why; do
    [ -n "$why" ] || continue
    last=$(rk_ledger_last "$RK_PL" blocked '사유' "$why")
    cmd=$(manifest_row_fields "$last" '재개 명령' | tail -n 1)
    case "$cmd" in ''|'(없음)') continue ;; esac
    case "$cmds" in *"$TAB$cmd$TAB"*) continue ;; esac
    cmds="$cmds$TAB$cmd$TAB"
    printf '고지\t(이전 런이 남긴 재개 명령: %s)\n' "$cmd"
  done <<EOF
$ub
EOF
  # The approval form names only the way back, so a quoted command that says to
  # start over is followed by the way forward.
  if [ -n "$cmds" ] && [ "$1" = "stopped" ] && [ "$n" -gt 0 ]; then
    printf '고지\t지금 처음부터 시작하려면 의도를 적어 부르세요\n'
  fi
  exit 0
}

# ---------------------------------------------------------------------------
# verify
# ---------------------------------------------------------------------------
rk_verify() {
  local failed="" pm_sha pg_sha iv_sha="-" why
  rk_prev_paths
  printf 'cc-rekick v1\n'
  MANIFEST=$(rk_copy "$RK_PM" prev.plan.md) || {
    printf '검사\t다이제스트\t실패\t원천 매니페스트를 읽을 수 없습니다\n판정\t실패\t다이제스트\n'; exit 1; }
  pm_sha=$(rk_sha "$MANIFEST")

  # (a) the two digests, re-derived.
  local tdig bdig td bd
  td=$(manifest_field '대상' '대상 맵 다이제스트'); bd=$(manifest_field '인가' '구속 다이제스트')
  tdig=$(canonical_targets | rk_sha_stdin); bdig=$(binding_set_bytes | rk_sha_stdin)
  if [ -z "$td" ] || [ "$td" != "$tdig" ]; then why="대상 맵 다이제스트가 대상 행과 다릅니다"
  elif [ -z "$bd" ]; then why="구속 다이제스트가 없습니다"
  elif [ "$bd" != "$bdig" ]; then why="구속 다이제스트가 얼린 집합과 다릅니다"
  else why=""; fi
  if [ -z "$why" ]; then printf '검사\t다이제스트\t통과\t-\n'
  else printf '검사\t다이제스트\t실패\t%s\n' "$why"; failed="${failed:+$failed, }다이제스트"; fi

  # (b) the interview record against its row.
  local irows nir ipath isha icopy
  irows=$(rk_interview_rows); nir=$(printf '%s' "$irows" | grep -c . || true)
  why=""
  if [ "${nir:-0}" -gt 1 ]; then why="인터뷰 행이 ${nir}개입니다"
  elif [ "${nir:-0}" = "1" ]; then
    ipath=$(manifest_row_fields "$irows" '인터뷰 기록' | head -n 1)
    isha=$(manifest_row_fields "$irows" 'sha256' | head -n 1)
    case "$ipath" in /*|*..*|'') why="인터뷰 행의 경로가 base 기준 경로가 아닙니다: $ipath" ;; esac
    if [ -z "$why" ]; then
      if icopy=$(rk_copy "$RK_BASE/$ipath" prev.interview.md); then
        iv_sha=$(rk_sha "$icopy")
        [ "$iv_sha" = "$isha" ] || why="인터뷰 기록의 sha256 이 행과 다릅니다"
      else
        why="인터뷰 행은 있는데 기록 파일이 없습니다: $ipath"
      fi
    fi
  else
    [ ! -e "$RK_BASE/docs/pipeline-run/$RK_PREV.interview.md" ] \
      || why="인터뷰 기록 파일은 있는데 매니페스트에 인터뷰 행이 없습니다"
  fi
  if [ -z "$why" ]; then printf '검사\t인터뷰\t통과\t-\n'
  else printf '검사\t인터뷰\t실패\t%s\n' "$why"; failed="${failed:+$failed, }인터뷰"; fi

  # (c) the authorization record, through the gate's own check.
  local gcopy tok
  if gcopy=$(rk_copy "$RK_PG" prev.grant.md); then
    pg_sha=$(rk_sha "$gcopy")
    tok=$(rk_gate grant "$MANIFEST" "$RK_PREV" "${RK_PRD:-$RK_TMP/no-run-dir}" "$RK_PL" "$gcopy" "$RK_TMP/grant.err")
    if [ "$tok" = "통과" ]; then printf '검사\t인가\t통과\t-\n'
    else
      why=$(sed -n 's/.*\[warn\] //p' "$RK_TMP/grant.err" 2>/dev/null | head -n 1)
      printf '검사\t인가\t실패\t%s\n' "${why:-게이트의 인가 검사가 통과하지 않았습니다 ($tok)}"
      failed="${failed:+$failed, }인가"
    fi
  else
    pg_sha="-"
    printf '검사\t인가\t실패\t원천 인가 기록이 없습니다\n'; failed="${failed:+$failed, }인가"
  fi

  # (d) the header's run id against the body's, and against the id asked for.
  local hr br
  hr=$(manifest_hdr_field 'run-id'); br=$(manifest_field '런 정체' '런 id')
  if [ -n "$hr" ] && [ "$hr" = "$br" ] && [ "$hr" = "$RK_PREV" ]; then printf '검사\t머리\t통과\t-\n'
  else printf '검사\t머리\t실패\t머리 run-id=%s · 본문 런 id=%s · 요청 %s\n' "$hr" "$br" "$RK_PREV"; failed="${failed:+$failed, }머리"; fi

  printf '해시\t매니페스트\t%s\n해시\t인가 기록\t%s\n해시\t인터뷰\t%s\n' "$pm_sha" "$pg_sha" "$iv_sha"

  # A base binding whose document moved is a question, not a failure.
  local bdrow bdoc bsha bnow
  bdrow=$(manifest_base_design_rows | head -n 1)
  if [ -n "$bdrow" ]; then
    bdoc=$(manifest_row_fields "$bdrow" '문서' | head -n 1)
    bsha=$(manifest_row_fields "$bdrow" 'sha256' | head -n 1)
    bnow=$(rk_sha "$RK_BASE/$bdoc"); [ -n "$bnow" ] || bnow="-"
    printf '베이스설계\t%s\t%s\t%s\n' "$bdoc" "$bsha" "$bnow"
    [ "$bnow" = "$bsha" ] || printf '질문\t베이스설계\t%s\t%s\t%s\n' "$bdoc" "$bsha" "$bnow"
  fi

  # An auto-adoption row whose class the driver no longer accepts is neither
  # carried nor dropped: the manifest check would refuse it at freeze time, and
  # dropping it silently would narrow what the person answered. It is a question.
  local cls row
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    cls=$(manifest_row_fields "$row" '판단 부류' | head -n 1)
    if judgment_class_forbidden "$cls" || ! judgment_class_ok "$cls"; then
      printf '질문\t자동채택\t%s\n' "$row"
    fi
  done <<EOF
$(manifest_autoadopt_rows_anywhere)
EOF

  # The values the one screen shows, so the kickoff never reads them itself.
  local ncl
  ncl=$(manifest_clause_rows_raw | grep -c . || true)
  printf '값\t의도\t%s\n' "$(rk_intent | awk 'NF { print; exit }')"
  printf '값\t킥오프 일시\t%s\n' "$(manifest_field '런 정체' '킥오프 일시')"
  printf '값\t종료 지점\t%s\n' "$(manifest_field '인가' '종료 지점')"
  printf '값\t종료 절 수\t%s\n' "${ncl:-0}"
  printf '값\t벽시계 마감\t%s\n' "$(manifest_field '인가' '벽시계 마감')"
  printf '값\t미선언 상황 처분\t%s\n' "$(manifest_field '인가' '미선언 상황 처분')"
  printf '값\t시각 정합 마커\t%s\n' "$(manifest_field '인가' '시각 정합 마커')"
  printf '값\t설계 문서\t%s\n' "$(manifest_field '요소' '설계 문서')"
  while IFS= read -r row; do
    [ -n "$row" ] && printf '대상\t%s\n' "$row"
  done <<EOF
$(manifest_targets)
EOF
  while IFS= read -r row; do
    [ -n "$row" ] && printf '로스터\t%s\n' "$row"
  done <<EOF
$(manifest_design_roster_rows_anywhere)
EOF

  if [ -z "$failed" ]; then printf '판정\t통과\n'; exit 0; fi
  printf '판정\t실패\t%s\n' "$failed"
  exit 1
}

# ---------------------------------------------------------------------------
# graph — which steps the ledger proves finished, and the plan without them.
# Sets G_PLAN (compact JSON), G_REMOVED, G_SKIPS, G_DESIGN_OUT, G_DOC_SHA,
# G_DESIGN_NOTE, G_AUDIT_NOTE, G_SCOPE. Reads the current MANIFEST (a copy).
# ---------------------------------------------------------------------------
rk_graph_compute() {
  local plan doc docf docsha did aid lastn hashrow hsha frozen
  plan=$(manifest_plan_json)
  G_SCOPE=$(manifest_design_scope)
  G_REMOVED=""; G_SKIPS=""; G_DESIGN_OUT=0; G_DOC_SHA="-"
  G_DESIGN_NOTE="없음${TAB}계획에 설계 단계가 없습니다"; G_AUDIT_NOTE="없음${TAB}계획에 감사 단계가 없습니다"
  doc=$(manifest_field '요소' '설계 문서')
  case "$doc" in ''|'(없음)') docf="" ;; *) docf="$RK_BASE/$doc" ;; esac
  docsha=""; [ -n "$docf" ] && docsha=$(rk_sha "$docf")
  did=$(printf '%s' "$plan" | jq -r '[.steps[]? | select(type == "object" and .skill == "design") | .id // empty] | if length == 1 then .[0] else empty end' 2>/dev/null)
  aid=$(printf '%s' "$plan" | jq -r '[.steps[]? | select(type == "object" and .skill == "design-audit") | .id // empty] | if length == 1 then .[0] else empty end' 2>/dev/null)

  if [ "$G_SCOPE" = "base" ]; then
    [ -z "$did" ] || G_DESIGN_NOTE="남음${TAB}base 범위 런의 그래프는 빼지 않습니다"
    [ -z "$aid" ] || G_AUDIT_NOTE="남음${TAB}base 범위 런의 그래프는 빼지 않습니다"
    G_PLAN=$(printf '%s' "$plan" | jq -c . 2>/dev/null)
    return 0
  fi

  # The design: the frozen line, exactly once.
  if [ -n "$did" ]; then
    if [ -n "$docf" ] && [ -f "$docf" ]; then
      frozen=$(grep -cxF '**상태**: 동결됨' "$docf" 2>/dev/null || true)
    else
      frozen=0
    fi
    if [ "${frozen:-0}" = "1" ]; then
      G_REMOVED="$did"; G_DESIGN_OUT=1; G_DOC_SHA="$docsha"
      G_DESIGN_NOTE="뺌${TAB}설계 문서에 **상태**: 동결됨 줄이 정확히 하나입니다"
      G_SKIPS="${G_SKIPS}${did}${TAB}design${TAB}설계 문서 $doc 에 **상태**: 동결됨 줄이 정확히 하나입니다
"
    else
      G_DESIGN_NOTE="남음${TAB}설계 문서에 동결 줄이 정확히 하나가 아닙니다 (${frozen:-0}개)"
    fi
  fi

  # The audit: a normal completion of that step, and the latest document hash
  # recorded before the last such completion equal to the document now. Only
  # after the design is out — an audit of a design that runs again proves
  # nothing about the document that design will write.
  if [ -n "$aid" ]; then
    if [ -n "$did" ] && [ "$G_DESIGN_OUT" != "1" ]; then
      G_AUDIT_NOTE="남음${TAB}설계 단계가 남아 감사도 다시 돕니다"
    elif [ -z "$docsha" ]; then
      G_AUDIT_NOTE="남음${TAB}설계 문서를 읽을 수 없습니다"
    else
      lastn=$(awk -v aid="$aid" '
        function fld(line, name,   n, i, a, s, v) {
          n = split(line, a, /\|/); v = ""
          for (i = 2; i <= n; i++) {
            s = a[i]; sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s)
            if (index(s, name "=") == 1) { v = substr(s, length(name) + 2) }
          }
          return v
        }
        /^- `stage-result`/ && fld($0, "스테이지") == aid && fld($0, "종류") == "audit" && fld($0, "종단 부류") == "정상 완료" { last = NR }
        END { if (last) print last }' "$RK_PL" 2>/dev/null)
      if [ -z "$lastn" ]; then
        G_AUDIT_NOTE="남음${TAB}감사 단계 $aid 의 정상 완료 행이 없습니다"
      else
        hashrow=$(awk -v aid="$aid 이후" -v lim="$lastn" '
          function fld(line, name,   n, i, a, s, v) {
            n = split(line, a, /\|/); v = ""
            for (i = 2; i <= n; i++) {
              s = a[i]; sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s)
              if (index(s, name "=") == 1) { v = substr(s, length(name) + 2) }
            }
            return v
          }
          NR >= lim { exit }
          /^- `문서 해시`/ && fld($0, "스테이지") == aid { h = fld($0, "sha256") }
          END { print h }' "$RK_PL" 2>/dev/null)
        hsha=$hashrow
        if [ -n "$hsha" ] && [ "$hsha" = "$docsha" ]; then
          G_REMOVED="${G_REMOVED:+$G_REMOVED }$aid"
          G_AUDIT_NOTE="뺌${TAB}감사 정상 완료 앞의 문서 해시가 지금 문서와 같습니다"
          G_SKIPS="${G_SKIPS}${aid}${TAB}design-audit${TAB}정상 완료 앞의 문서 해시 ${hsha%"${hsha#????????????}"} 가 지금 문서와 같습니다
"
        else
          G_AUDIT_NOTE="남음${TAB}감사가 본 문서 해시와 지금 문서 해시가 다릅니다"
        fi
      fi
    fi
  fi

  G_PLAN=$(printf '%s' "$plan" | jq -c --arg rm "$G_REMOVED" --arg dout "$G_DESIGN_OUT" '
    ($rm | split(" ") | map(select(. != ""))) as $r
    | if ($r | length) == 0 then . else
        .steps = [ .steps[]?
                   | select(((type == "object") and ((.id // "") as $i | ([$r[] | select(. == $i)] | length) > 0)) | not)
                   | if type == "object" then .depends_on = ([(.depends_on // [])[] | select(. as $d | ([$r[] | select(. == $d)] | length) == 0)]) else . end ]
        | (if (.steps | length) > 0 then .entry_skill = (.steps[0] | if type == "object" then .skill else . end) else . end)
        | (if $dout == "1" then .design_required = false else . end)
      end' 2>/dev/null)
}

# rk_plan_shape <json> — the step-graph shape the kickoff checks before it
# writes: ids present and unique, every dependency names a step that is there,
# at most one design step, and a `split` step only in a base run.
rk_plan_shape() {
  printf '%s' "$1" | jq -e --arg scope "$2" '
    [.steps[]? | select(type == "object")] as $s
    | ([$s[].id // ""] | map(select(. == "")) | length) == 0
    and ([$s[].id] | unique | length) == ($s | length)
    and ([$s[] | (.depends_on // [])[]] - [$s[].id] | length) == 0
    and ([$s[] | select(.skill == "design")] | length) <= 1
    and ($scope == "base" or ([$s[] | select(.skill == "split")] | length) == 0)
  ' >/dev/null 2>&1
}

rk_added_targets() {
  # The ledger's `대상 추가` rows, one per alias, as the fields a question needs.
  local row al rows
  rows=$(grep -F -- '- `대상 추가`' "$RK_PL" 2>/dev/null | awk '!seen[$0]++')
  while IFS= read -r row; do
    case "$row" in '- `대상 추가`'*) ;; *) continue ;; esac
    al=$(manifest_row_fields "$row" '별칭' | head -n 1)
    [ -n "$al" ] || continue
    printf '대상추가\t%s\t%s\t%s\t%s\t%s\n' "$al" \
      "$(manifest_row_fields "$row" '원격 슬러그' | head -n 1)" \
      "$(manifest_row_fields "$row" '메인 워크트리' | head -n 1)" \
      "$(manifest_row_fields "$row" '공통 git 디렉터리' | head -n 1)" \
      "$(manifest_row_fields "$row" '베이스 브랜치' | head -n 1)"
  done <<EOF
$rows
EOF
}

rk_graph() {
  rk_prev_paths
  MANIFEST=$(rk_copy "$RK_PM" prev.plan.md) || rk_fail "원천 매니페스트를 읽을 수 없습니다: $RK_PM"
  if [ -n "$RK_XSHA" ] && [ "$(rk_sha "$MANIFEST")" != "$RK_XSHA" ]; then
    rk_fail "원천 매니페스트가 검증한 해시와 다릅니다 — 검증 뒤에 바뀐 파일은 이어받지 않습니다"
  fi
  rk_graph_compute
  [ -n "$G_PLAN" ] || rk_fail "원천 매니페스트의 실행 계획을 읽지 못했습니다"
  local line id sk deps why shape_ok=1
  {
    printf 'cc-rekick v1\n'
    printf '범위\t%s\n' "$G_SCOPE"
    printf '설계\t%s\n감사\t%s\n' "$G_DESIGN_NOTE" "$G_AUDIT_NOTE"
    printf '%s' "$G_SKIPS" | while IFS= read -r line; do [ -n "$line" ] && printf '건너뜀\t%s\n' "$line"; done
    printf '%s' "$G_PLAN" | jq -r '.steps[]? | select(type == "object") | "남음\t\(.id)\t\(.skill)\t\(if ((.depends_on // []) | length) == 0 then "-" else ((.depends_on // []) | join(",")) end)"' 2>/dev/null
    printf '계획\t%s\n' "$G_PLAN"
    printf '문서해시\t%s\n' "$G_DOC_SHA"
    rk_added_targets
  } > "$RK_TMP/graph.out"

  why=""
  rk_plan_shape "$G_PLAN" "$G_SCOPE" || why="빼고 난 그래프가 모양 검사를 통과하지 않습니다"
  if [ -z "$why" ] && [ -n "$G_REMOVED" ]; then
    # The manifest the removal would freeze, with this run's own identity, put
    # through the driver's own manifest check.
    rk_render "$RK_TMP/graph-draft.md" "$RK_PREV" \
      "$(manifest_field '런 정체' '킥오프 일시')" "$(manifest_field '인가' '벽시계 마감')" \
      "$(manifest_field '런 정체' '사용자 확인 문면')" "$(manifest_field '실행 계획' '승인 문면')" \
      "$(rk_sha "$MANIFEST")" "-" \
      || why="빼고 난 매니페스트를 그리지 못했습니다"
    if [ -z "$why" ]; then rk_check_manifest "$RK_TMP/graph-draft.md" || why="빼고 난 매니페스트가 매니페스트 검사를 통과하지 않습니다"; fi
  fi
  if [ -z "$why" ] && [ -n "$RK_ACCEPTED" ]; then why="받아들인 대상 추가가 있습니다 ($RK_ACCEPTED)"; fi
  cat "$RK_TMP/graph.out"
  if [ -z "$why" ]; then printf '그래프\t순수\n'; else printf '그래프\t바뀜\t%s\n' "$why"; fi
  exit 0
}

# rk_check_manifest <file> — the driver's `check_manifest`, in a subshell, from
# the worktree the manifest names as its origin.
rk_check_manifest() {
  local m="$1" ow
  ow=$(MANIFEST="$m" manifest_hdr_field 'origin-worktree')
  ( [ -n "$ow" ] && cd "$ow" 2>/dev/null; MANIFEST="$m"; check_manifest ) >/dev/null 2>"$RK_TMP/check.err"
}

# ---------------------------------------------------------------------------
# The draft. rk_render <out> <new id> <kickoff at> <deadline> <confirmation>
# <approval> <previous manifest sha256> <previous grant sha256> — reads the
# current MANIFEST (the previous run's copy) and the G_* graph values, and the
# RK_TARGETS / RK_ROWS / RK_RULES / RK_BIND / RK_VISUAL options. The two
# digests are derived last, by the driver's own serializers, over the draft.
# ---------------------------------------------------------------------------
rk_render() {
  local out="$1" newid="$2" kat="$3" dl="$4" confirm="$5" approval="$6" pmsha="$7" pgsha="$8"
  local trows maxcut planf="" prov tdig bdig
  if [ -n "$RK_TARGETS" ]; then trows=$(grep -E '^- `target`' "$RK_TARGETS" 2>/dev/null || true); else trows=$(manifest_targets); fi
  maxcut=$(rk_cut_max "$trows")
  [ -n "$maxcut" ] || maxcut=$(manifest_field '인가' '런 최대 절단점')
  if [ -n "$G_REMOVED" ]; then
    planf="$RK_TMP/plan.json"
    printf '%s' "$G_PLAN" | jq . > "$planf" 2>/dev/null || return 1
  fi
  prov="- \`사전 인가\` | 이어받은 런=$RK_PREV | 매니페스트 sha256=$pmsha | 인가 기록 sha256=$pgsha"
  printf '%s' "$trows" > "$RK_TMP/targets.rows"
  if [ -n "$RK_ROWS" ]; then
    grep -E '^- `(사전 인가` \| 형태=|자동 채택`)' "$RK_ROWS" > "$RK_TMP/shape.rows" 2>/dev/null || : > "$RK_TMP/shape.rows"
  fi
  printf '%s' "$RK_RULES" > "$RK_TMP/rules.kv"
  [ -f "$RK_TMP/sets.tsv" ] || : > "$RK_TMP/sets.tsv"
  R_SETS="$RK_TMP/sets.tsv" R_NEWID="$newid" R_KAT="$kat" R_DL="$dl" R_CONFIRM="$confirm" R_APPROVAL="$approval" \
  R_MAXCUT="$maxcut" R_VISUAL="$RK_VISUAL" R_DOUT="$G_DESIGN_OUT" R_DOCSHA="$G_DOC_SHA" \
  R_PLANF="$planf" R_PROV="$prov" R_TFILE="$( [ -n "$RK_TARGETS" ] && printf '%s' "$RK_TMP/targets.rows")" \
  R_RFILE="$( [ -n "$RK_ROWS" ] && printf '%s' "$RK_TMP/shape.rows")" R_RULES="$RK_TMP/rules.kv" \
  R_BIND="$RK_BIND" R_IVPATH="docs/pipeline-run/$newid.interview.md" \
  awk '
    function field(line,   p) { p = index(line, "**: "); return substr(line, 3, p - 3) }
    # What a section must still carry is written when it closes, before the
    # blank lines that separate it from the next one.
    function close_sec(   key, a) {
      # A confirmed blank whose line the previous manifest did not carry at all.
      for (key in rset) {
        split(key, a, SUBSEP)
        if (("## " a[1]) == sec && !(key in rdone)) { print "**" a[2] "**: " rset[key]; rdone[key] = 1 }
      }
      if (sec == "## 인가") {
        if (!rows_done && rfile != "") { while ((getline l < rfile) > 0) print l; close(rfile); rows_done = 1 }
        if (!prov_done) { print ENVIRON["R_PROV"]; prov_done = 1 }
      }
      if (sec == "## 요소" && ENVIRON["R_DOUT"] == "1" && !docsha_done) {
        print "**설계 문서 전체 sha256**: " ENVIRON["R_DOCSHA"]; docsha_done = 1
      }
    }
    function flush_blank() { for (i = 1; i <= nblank; i++) print ""; nblank = 0 }
    # A target row with the confirmed blanks of its alias written in: an empty
    # field takes the value, an absent one is appended.
    function tapply(line,   al, key, a, pat, p) {
      if (!match(line, /별칭=[^ |]*/)) return line
      al = substr(line, RSTART + length("별칭="), RLENGTH - length("별칭="))
      for (key in tset) {
        split(key, a, SUBSEP)
        if (a[1] != al) continue
        pat = "| " a[2] "="
        if ((p = index(line, pat " |")) > 0) { line = substr(line, 1, p + length(pat) - 1) tset[key] substr(line, p + length(pat)) }
        else if (substr(line, length(line) - length(pat) + 1) == pat) { line = line tset[key] }
        else line = line " | " a[2] "=" tset[key]
      }
      return line
    }
    BEGIN {
      newid = ENVIRON["R_NEWID"]; tfile = ENVIRON["R_TFILE"]; rfile = ENVIRON["R_RFILE"]
      planf = ENVIRON["R_PLANF"]; hdr = 1
      while ((getline l < ENVIRON["R_RULES"]) > 0) { p = index(l, "="); if (p) rule[substr(l, 1, p - 1)] = substr(l, p + 1) }
      close(ENVIRON["R_RULES"])
      while ((getline l < ENVIRON["R_SETS"]) > 0) {
        n = split(l, s, "\t"); if (n < 4) continue
        if (s[2] == "대상") tset[s[1], s[3]] = s[4]; else rset[s[2], s[3]] = s[4]
      }
      close(ENVIRON["R_SETS"])
    }
    NR == 1 { print "# 파이프라인 런 매니페스트 — " newid; next }
    hdr {
      line = $0
      if (match(line, /run-id=[^;]*;/)) line = substr(line, 1, RSTART - 1) "run-id=" newid ";" substr(line, RSTART + RLENGTH)
      print line
      if (index($0, "-->")) hdr = 0
      next
    }
    fence {
      if (/^```/) { fence = 0; if (skipjson) { skipjson = 0 } ; print; next }
      if (!skipjson) print
      next
    }
    /^```/ {
      fence = 1
      if (sec == "## 실행 계획" && planf != "" && /^```json/) {
        print; while ((getline l < planf) > 0) print l; close(planf); skipjson = 1; next
      }
      print; next
    }
    /^## / { close_sec(); flush_blank(); sec = $0; print; next }
    /^$/ { nblank++; next }
    nblank > 0 { flush_blank() }
    /^- `사전 인가` \| 이어받은 런=/ { next }
    /^- `사전 인가` \| 인터뷰 기록=/ {
      if (ENVIRON["R_DOUT"] == "1") next
      line = $0; sub(/인터뷰 기록=[^|]*\|/, "인터뷰 기록=" ENVIRON["R_IVPATH"] " |", line); print line; next
    }
    /^- `설계 로스터`/ { if (ENVIRON["R_DOUT"] == "1") next; print; next }
    /^- `(사전 인가` \| 형태=|자동 채택`)/ {
      if (rfile == "") { print; next }
      if (!rows_done) { while ((getline l < rfile) > 0) print l; close(rfile); rows_done = 1 }
      next
    }
    /^- `베이스 설계`/ {
      line = $0
      if (ENVIRON["R_BIND"] != "") sub(/sha256=[0-9a-f]+/, "sha256=" ENVIRON["R_BIND"], line)
      print line; next
    }
    /^- `target`/ {
      if (tfile == "") { print tapply($0); next }
      if (!targets_done) { while ((getline l < tfile) > 0) print tapply(l); close(tfile); targets_done = 1 }
      next
    }
    /^\*\*[^*]+\*\*: / {
      f = field($0)
      if (sec == "## 런 정체" && f == "킥오프 일시") { print "**킥오프 일시**: " ENVIRON["R_KAT"]; next }
      if (sec == "## 런 정체" && f == "런 id") { print "**런 id**: " newid; next }
      if (sec == "## 런 정체" && f == "사용자 확인 문면") { print "**사용자 확인 문면**: " ENVIRON["R_CONFIRM"]; next }
      if (sec == "## 대상" && f == "대상 맵 다이제스트") { print "**대상 맵 다이제스트**: @RK_TDIG@"; next }
      if (sec == "## 요소" && f == "설계 문서 전체 sha256" && ENVIRON["R_DOUT"] == "1") { print "**설계 문서 전체 sha256**: " ENVIRON["R_DOCSHA"]; docsha_done = 1; next }
      if (sec == "## 실행 계획" && f == "승인 문면") { print "**승인 문면**: " ENVIRON["R_APPROVAL"]; next }
      if (sec == "## 인가" && f == "구속 다이제스트") { print "**구속 다이제스트**: @RK_BDIG@"; next }
      if (sec == "## 인가" && f == "런 최대 절단점") { print "**런 최대 절단점**: " ENVIRON["R_MAXCUT"]; next }
      if (sec == "## 인가" && f == "벽시계 마감") { print "**벽시계 마감**: " ENVIRON["R_DL"]; next }
      if (sec == "## 인가" && f == "시각 정합 마커" && ENVIRON["R_VISUAL"] != "") { print "**시각 정합 마커**: " ENVIRON["R_VISUAL"]; next }
      if ((f in rule) && $0 ~ /\*\*: (켬|끔)$/) { print "**" f "**: " rule[f]; next }
      if ((substr(sec, 4), f) in rset) { print "**" f "**: " rset[substr(sec, 4), f]; rdone[substr(sec, 4), f] = 1; next }
      print; next
    }
    { print }
    END { close_sec(); flush_blank() }
  ' "$MANIFEST" > "$out.tmp" || return 1
  local saved="$MANIFEST"
  MANIFEST="$out.tmp"
  tdig=$(canonical_targets | rk_sha_stdin)
  bdig=$(binding_set_bytes | rk_sha_stdin)
  MANIFEST="$saved"
  sed -e "s/@RK_TDIG@/$tdig/" -e "s/@RK_BDIG@/$bdig/" "$out.tmp" > "$out" || return 1
  rm -f "$out.tmp"
}

# rk_confirm_text — the new `사용자 확인 문면`: this call's argument verbatim
# (`/cc-cmds:autopilot` when it was empty), then each answer this re-kickoff
# asked, then each `--set` entry as given, joined with ` / `. The 5o answer
# itself is 「이대로」, so the confirmed values are written beside it.
rk_confirm_text() {
  local s k a e
  s=$(rk_trim "$RK_ARG"); [ -n "$s" ] || s='/cc-cmds:autopilot'
  if [ -n "$RK_ASKED" ]; then
    while IFS="$TAB" read -r k a; do
      [ -n "$k" ] || continue
      s="$s / $a"
    done < "$RK_ASKED"
  fi
  while IFS= read -r e; do
    [ -n "$e" ] || continue
    s="$s / $e"
  done <<EOF
$RK_SETS
EOF
  printf '%s' "$s"
}

rk_asked_answer() {
  # rk_asked_answer <key> — the answer recorded for that key, the last one.
  [ -n "$RK_ASKED" ] || return 0
  awk -F '\t' -v k="$1" '$1 == k { a = substr($0, length($1) + 2) } END { if (a != "") print a }' "$RK_ASKED"
}

# rk_set_field <key> — where a `--set` key lands: `<section><TAB><field>`.
rk_set_field() {
  case "$1" in
    ladder-rungs)     printf '인가\t사다리 가용 단 수' ;;
    stagnation-bound) printf '인가\t무진전 상한' ;;
    cost-ceiling)     printf '인가\t비용 천장' ;;
    apply-probe)      printf '요소\t적용 프로브' ;;
    apply-actor)      printf '요소\t적용 주체' ;;
    cutpoint)         printf '대상\t절단점' ;;
    review-ceiling)   printf '대상\t리뷰 정책 상한' ;;
    terminal-cap)     printf '대상\t말단 행위 상한' ;;
    dev-ids)          printf '대상\tdev 식별자' ;;
    deploy-triggers)  printf '대상\t배포트리거 식별자' ;;
    *) return 1 ;;
  esac
}

# rk_sets_resolve <out> — reads RK_SETS against the current MANIFEST (the
# previous run's copy) and writes `<범위><TAB><섹션><TAB><필드><TAB><값><TAB><키>`
# per entry. Prints the first refusal and returns 1 when an entry names an
# unknown key, a scope that does not fit it, a target the previous manifest
# does not hold, a value the previous manifest already has, a value a target
# row cannot carry, or the same place twice.
rk_sets_resolve() {
  local out="$1" e sc rest k v loc sec f pv
  : > "$out"
  while IFS= read -r e; do
    [ -n "$e" ] || continue
    sc=${e%%:*}; rest=${e#*:}; k=${rest%%=*}; v=${rest#*=}
    loc=$(rk_set_field "$k") || { printf '%s' "--set 의 키를 모릅니다: $k"; return 1; }
    sec=${loc%%"$TAB"*}; f=${loc#*"$TAB"}
    if [ "$sec" = "대상" ]; then
      [ "$sc" != "런" ] || { printf '%s' "--set $k 의 범위는 대상 별칭입니다"; return 1; }
      target_aliases | grep -qxF -- "$sc" || { printf '%s' "--set 의 대상 $sc 가 원천 매니페스트에 없습니다"; return 1; }
      case "$v" in *'|'*) printf '%s' "--set $sc:$k 값에 | 가 있습니다"; return 1 ;; esac
      pv=$(target_field "$sc" "$f")
    else
      [ "$sc" = "런" ] || { printf '%s' "--set $k 의 범위는 런입니다"; return 1; }
      pv=$(manifest_field "$sec" "$f")
    fi
    [ -z "$pv" ] || { printf '%s' "--set $sc:$k — 원천 매니페스트에 이미 값이 있어 빈칸이 아닙니다"; return 1; }
    awk -F '\t' -v s="$sc" -v f="$f" '$1 == s && $3 == f { d = 1 } END { exit !d }' "$out" \
      && { printf '%s' "--set $sc:$k 가 두 번 주어졌습니다"; return 1; }
    printf '%s\t%s\t%s\t%s\t%s\n' "$sc" "$sec" "$f" "$v" "$k" >> "$out"
  done <<EOF
$RK_SETS
EOF
  return 0
}

rk_render_manifest() {
  rk_prev_paths
  MANIFEST=$(rk_copy "$RK_PM" prev.plan.md) || rk_fail "원천 매니페스트를 읽을 수 없습니다: $RK_PM"
  [ "$(rk_sha "$MANIFEST")" = "$RK_XSHA" ] \
    || rk_fail "원천 매니페스트가 검증한 해시와 다릅니다 — 검증 뒤에 바뀐 파일은 이어받지 않습니다"
  local gcopy
  gcopy=$(rk_copy "$RK_PG" prev.grant.md) || rk_fail "원천 인가 기록을 읽을 수 없습니다: $RK_PG"
  [ "$(rk_sha "$gcopy")" = "$RK_XGSHA" ] \
    || rk_fail "원천 인가 기록이 검증한 해시와 다릅니다 — 검증 뒤에 바뀐 파일은 이어받지 않습니다"
  [ -n "$(rk_wide_instant "$RK_DEADLINE")" ] || rk_fail "--deadline 을 시각으로 읽지 못했습니다: '$RK_DEADLINE'"
  local setwhy
  setwhy=$(rk_sets_resolve "$RK_TMP/sets.tsv") || rk_fail "$setwhy"
  rk_graph_compute
  [ -n "$G_PLAN" ] || rk_fail "원천 매니페스트의 실행 계획을 읽지 못했습니다"
  local confirm approval
  confirm=$(rk_confirm_text)
  approval=$(rk_asked_answer '5l')
  if [ -z "$approval" ]; then approval=$(rk_trim "$RK_ARG"); [ -n "$approval" ] || approval='/cc-cmds:autopilot'; fi
  rk_render "$RK_TMP/draft.md" "$RK_NEWID" "$RK_KAT" "$RK_DEADLINE" "$confirm" "$approval" "$RK_XSHA" "$RK_XGSHA" \
    || rk_fail "매니페스트 초안을 그리지 못했습니다"
  cat "$RK_TMP/draft.md"
  exit 0
}

# ---------------------------------------------------------------------------
# render-interview — the previous record's bytes, after the row's hash.
# ---------------------------------------------------------------------------
rk_render_interview() {
  rk_prev_paths
  MANIFEST=$(rk_copy "$RK_PM" prev.plan.md) || rk_fail "원천 매니페스트를 읽을 수 없습니다: $RK_PM"
  if [ -n "$RK_XSHA" ] && [ "$(rk_sha "$MANIFEST")" != "$RK_XSHA" ]; then
    rk_fail "원천 매니페스트가 검증한 해시와 다릅니다 — 검증 뒤에 바뀐 파일은 이어받지 않습니다"
  fi
  local irows nir ipath isha icopy
  irows=$(rk_interview_rows); nir=$(printf '%s' "$irows" | grep -c . || true)
  [ "${nir:-0}" = "1" ] || rk_fail "원천 매니페스트의 인터뷰 행이 ${nir:-0}개입니다 — 정확히 하나여야 복사합니다"
  ipath=$(manifest_row_fields "$irows" '인터뷰 기록' | head -n 1)
  isha=$(manifest_row_fields "$irows" 'sha256' | head -n 1)
  case "$ipath" in /*|*..*|'') rk_fail "인터뷰 행의 경로가 base 기준 경로가 아닙니다: $ipath" ;; esac
  icopy=$(rk_copy "$RK_BASE/$ipath" prev.interview.md) || rk_fail "원천 인터뷰 기록을 읽을 수 없습니다: $ipath"
  [ "$(rk_sha "$icopy")" = "$isha" ] || rk_fail "원천 인터뷰 기록의 sha256 이 행과 다릅니다 — 복사하지 않습니다"
  cat "$icopy"
  exit 0
}

# ---------------------------------------------------------------------------
# verify-subset — the draft widens nothing the previous run froze.
# ---------------------------------------------------------------------------
VS_FAILED=""
vs_check() {
  # vs_check <name> <reason|empty>
  if [ -z "$2" ]; then printf '검사\t%s\t통과\t-\n' "$1"
  else printf '검사\t%s\t실패\t%s\n' "$1" "$2"; VS_FAILED="${VS_FAILED:+$VS_FAILED, }$1"; fi
}

# vs_in <needle> <haystack lines> — the needle is one whole line of the list.
vs_in() { printf '%s\n' "$2" | grep -qxF -- "$1"; }

# vs_set_is <scope> <field> <draft value> — a `--set` entry confirmed this
# place, and the draft carries exactly its value.
VS_SETS=""
vs_set_is() {
  [ -n "$VS_SETS" ] && [ -s "$VS_SETS" ] || return 1
  awk -F '\t' -v s="$1" -v f="$2" -v d="$3" '$1 == s && $3 == f { ok = ($4 == d); hit = 1 } END { exit !(hit && ok) }' "$VS_SETS"
}

rk_verify_subset() {
  local draft prev pbase pid pgrant why
  draft=$(rk_copy "$RK_POS1" draft.md) || rk_fail "초안을 읽을 수 없습니다: $RK_POS1"
  prev=$(rk_copy "$RK_POS2" prev.plan.md) || rk_fail "이전 매니페스트를 읽을 수 없습니다: $RK_POS2"
  printf 'cc-rekick v1\n'
  if [ "$(rk_sha "$prev")" != "$RK_XSHA" ]; then
    vs_check 원천해시 "이전 매니페스트가 검증한 해시와 다릅니다"
    printf '판정\t실패\t%s\n' "$VS_FAILED"; exit 1
  fi
  pid=$(MANIFEST="$prev" manifest_hdr_field 'run-id')
  pbase=$(cd "$(dirname "$RK_POS2")/../.." 2>/dev/null && pwd)
  pgrant="$pbase/docs/pipeline-grant/$pid.md"
  RK_BASE="$pbase"; RK_PREV="$pid"
  local setwhy
  VS_SETS="$RK_TMP/vsets.tsv"
  setwhy=$(MANIFEST="$prev" rk_sets_resolve "$VS_SETS") || : > "$VS_SETS"

  # Values read from both files.
  local D_ID D_KAT D_DL D_CONFIRM P_KAT P_DL
  D_ID=$(MANIFEST="$draft" manifest_field '런 정체' '런 id')
  D_KAT=$(MANIFEST="$draft" manifest_field '런 정체' '킥오프 일시')
  D_DL=$(MANIFEST="$draft" manifest_field '인가' '벽시계 마감')
  D_CONFIRM=$(MANIFEST="$draft" manifest_field '런 정체' '사용자 확인 문면')
  P_KAT=$(MANIFEST="$prev" manifest_field '런 정체' '킥오프 일시')
  P_DL=$(MANIFEST="$prev" manifest_field '인가' '벽시계 마감')

  # 1 — the target rows.
  local prow drow al dal paliases daliases f pv dv cutans
  why=""
  paliases=$(MANIFEST="$prev" target_aliases | sort)
  daliases=$(MANIFEST="$draft" target_aliases | sort)
  while IFS= read -r al; do
    [ -n "$al" ] || continue
    vs_in "$al" "$paliases" && continue
    [ -n "$(rk_asked_answer "대상추가 $al")" ] || why="${why:+$why; }대상 $al 은 원천에 없고 확인된 대상 추가가 아닙니다"
  done <<EOF
$daliases
EOF
  while IFS= read -r al; do
    [ -n "$al" ] || continue
    vs_in "$al" "$daliases" || { why="${why:+$why; }원천 대상 $al 이 초안에 없습니다"; continue; }
    prow=$(MANIFEST="$prev" manifest_targets | grep -F "별칭=$al " | head -n 1)
    drow=$(MANIFEST="$draft" manifest_targets | grep -F "별칭=$al " | head -n 1)
    [ "$prow" = "$drow" ] && continue
    cutans=$(rk_asked_answer "7.7 절단점 $al")
    for f in 별칭 홈 절단점 '리뷰 정책 상한' '말단 행위 상한' 'dev 식별자' '배포트리거 식별자'; do
      pv=$(manifest_row_fields "$prow" "$f" | head -n 1); dv=$(manifest_row_fields "$drow" "$f" | head -n 1)
      [ "$pv" = "$dv" ] && continue
      if [ "$f" = "절단점" ] && [ -n "$cutans" ] && [ "$dv" = "$cutans" ]; then continue; fi
      if [ -z "$pv" ] && vs_set_is "$al" "$f" "$dv"; then continue; fi
      why="${why:+$why; }대상 $al 의 $f 가 원천과 다릅니다"
    done
    if [ -z "$(rk_asked_answer "대상확인 $al")" ]; then
      for f in '메인 워크트리' '공통 git 디렉터리' '베이스 브랜치' '원격 슬러그' '실행 워크트리'; do
        pv=$(manifest_row_fields "$prow" "$f" | head -n 1); dv=$(manifest_row_fields "$drow" "$f" | head -n 1)
        [ "$pv" = "$dv" ] || why="${why:+$why; }대상 $al 의 $f 가 다시 확인 없이 바뀌었습니다"
      done
    fi
  done <<EOF
$paliases
EOF
  vs_check 대상 "$why"

  # 2 — values that are byte-identical to the previous run.
  local k pval dval ks
  why=""
  [ "$(MANIFEST="$prev" rk_intent)" = "$(MANIFEST="$draft" rk_intent)" ] || why="${why:+$why; }## 의도 가 다릅니다"
  [ "$(MANIFEST="$prev" manifest_field '인가' '종료 지점')" = "$(MANIFEST="$draft" manifest_field '인가' '종료 지점')" ] \
    || why="${why:+$why; }종료 지점이 다릅니다"
  [ "$(MANIFEST="$prev" manifest_clause_rows_raw)" = "$(MANIFEST="$draft" manifest_clause_rows_raw)" ] \
    || why="${why:+$why; }종료 절 행이 다릅니다"
  # A field the previous run left empty may differ only by the value 5o
  # confirmed for it (`--set`); the draft is compared with that value.
  for ks in '인가:비용 천장' '인가:무진전 상한' '인가:사다리 가용 단 수' '인가:미선언 상황 처분' \
            '요소:적용 지점' '요소:적용 프로브' '요소:적용 주체'; do
    k=${ks#*:}
    pval=$(MANIFEST="$prev" manifest_field "${ks%%:*}" "$k"); dval=$(MANIFEST="$draft" manifest_field "${ks%%:*}" "$k")
    [ "$pval" = "$dval" ] && continue
    if [ -z "$pval" ] && vs_set_is 런 "$k" "$dval"; then continue; fi
    why="${why:+$why; }$k 가 원천과 다릅니다"
  done
  local prules drules rl rk rv
  prules=$(MANIFEST="$prev" manifest_rule_lines | sort); drules=$(MANIFEST="$draft" manifest_rule_lines | sort)
  if [ "$prules" != "$drules" ]; then
    while IFS= read -r rl; do
      [ -n "$rl" ] || continue
      vs_in "$rl" "$prules" && continue
      rk=${rl#\*\*}; rk=${rk%%\*\**}; rv=${rl##*: }
      [ "$(rk_asked_answer "7.7 룰 $rk")" = "$rv" ] && continue
      why="${why:+$why; }룰 설정 줄이 원천과 다릅니다: $rl"
    done <<EOF
$drules
EOF
    while IFS= read -r rl; do
      [ -n "$rl" ] || continue
      vs_in "$rl" "$drules" && continue
      rk=${rl#\*\*}; rk=${rk%%\*\**}
      [ -n "$(rk_asked_answer "7.7 룰 $rk")" ] && continue
      why="${why:+$why; }원천 룰 설정 줄이 빠졌습니다: $rl"
    done <<EOF
$prules
EOF
  fi
  vs_check 고정값 "$why"

  # 2b — each value 5o confirmed: asked at 5o, written beside the answers, and
  # carried by the draft where the previous run had none.
  local ssc ssec sf sv sk sdv
  why="$setwhy"
  if [ -z "$why" ]; then
    while IFS="$TAB" read -r ssc ssec sf sv sk; do
      [ -n "$ssc" ] || continue
      [ -n "$(rk_asked_answer "5o $sk")" ] || why="${why:+$why; }$ssc:$sk 는 5o 에서 묻지 않은 값입니다"
      case "$D_CONFIRM" in *" / $ssc:$sk=$sv"*) ;; *) why="${why:+$why; }$ssc:$sk 의 확정값이 사용자 확인 문면에 없습니다" ;; esac
      if [ "$ssec" = "대상" ]; then sdv=$(MANIFEST="$draft" target_field "$ssc" "$sf")
      else sdv=$(MANIFEST="$draft" manifest_field "$ssec" "$sf"); fi
      [ "$sdv" = "$sv" ] || why="${why:+$why; }초안의 $ssc:$sk 가 확정값이 아닙니다"
    done < "$VS_SETS"
  fi
  vs_check 확정값 "$why"

  # 3 — exactly one provenance row, naming the previous run and its hashes.
  local crow ncr
  crow=$(MANIFEST="$draft" rk_carry_rows); ncr=$(printf '%s' "$crow" | grep -c . || true)
  why=""
  if [ "${ncr:-0}" != "1" ]; then why="출처 행이 ${ncr:-0}개입니다"
  elif [ "$crow" != "- \`사전 인가\` | 이어받은 런=$pid | 매니페스트 sha256=$RK_XSHA | 인가 기록 sha256=$RK_XGSHA" ]; then
    why="출처 행이 이전 런과 그 해시를 가리키지 않습니다"
  fi
  vs_check 출처 "$why"

  # 4 — the base binding.
  local pbd dbd bind bdoc bnow
  pbd=$(MANIFEST="$prev" manifest_base_design_rows); dbd=$(MANIFEST="$draft" manifest_base_design_rows)
  why=""
  if [ "$pbd" != "$dbd" ]; then
    bind=$(rk_asked_answer '7.8')
    bdoc=$(manifest_row_fields "$pbd" '문서' | head -n 1)
    bnow=""; [ -n "$bdoc" ] && bnow=$(rk_sha "$pbase/$bdoc")
    case "$bind" in
      묶는다*)
        [ -n "$bnow" ] && [ "$(printf '%s' "$pbd" | sed "s/sha256=[0-9a-f]*/sha256=$bnow/")" = "$dbd" ] \
          || why="베이스 설계 행이 지금 해시로 묶은 것과 다릅니다" ;;
      *) why="베이스 설계 행이 원천과 다릅니다" ;;
    esac
  fi
  vs_check 베이스설계 "$why"

  # 5 — every answer stands verbatim in the confirmation text.
  local qk qa
  why=""
  while IFS="$TAB" read -r qk qa; do
    [ -n "$qk" ] || continue
    case "$D_CONFIRM" in *"$qa"*) ;; *) why="${why:+$why; }$qk 의 답이 사용자 확인 문면에 없습니다" ;; esac
  done < "$RK_ASKED"
  vs_check 확인문면 "$why"

  # 6 — the roster is a subset of the previous one.
  local prost row
  prost=$(MANIFEST="$prev" manifest_design_roster_rows_anywhere)
  why=""
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    vs_in "$row" "$prost" || why="${why:+$why; }원천에 없는 설계 로스터 행: $row"
  done <<EOF
$(MANIFEST="$draft" manifest_design_roster_rows_anywhere)
EOF
  vs_check 로스터 "$why"

  # 7 — `사전 인가` and `자동 채택` rows are the previous ones, or covered.
  local prows a5p a5q a77 tail
  prows=$( { MANIFEST="$prev" rk_shape_rows; MANIFEST="$prev" manifest_autoadopt_rows_anywhere; } )
  a5p=$(awk -F '\t' '$1 == "5p" { print substr($0, 4) }' "$RK_ASKED")
  a5q=$(awk -F '\t' '$1 == "5q" { print substr($0, 4) }' "$RK_ASKED")
  a77=$(awk -F '\t' '$1 == "7.7 자동채택" { print substr($0, length($1) + 2) }' "$RK_ASKED")
  why=""
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    vs_in "$row" "$prows" && continue
    tail=${row#*\` | }
    case "$row" in
      '- `사전 인가`'*) [ -n "$a5p" ] && case "$a5p" in *"$tail"*) true ;; *) false ;; esac && continue ;;
      '- `자동 채택`'*)
        { [ -n "$a5q" ] && case "$a5q" in *"$tail"*) true ;; *) false ;; esac; } && continue
        { [ -n "$a77" ] && case "$a77" in *"$tail"*) true ;; *) false ;; esac; } && continue ;;
    esac
    why="${why:+$why; }원천에 없고 답으로 덮이지 않은 행: $row"
  done <<EOF
$( { MANIFEST="$draft" rk_shape_rows; MANIFEST="$draft" manifest_autoadopt_rows_anywhere; } )
EOF
  vs_check 행 "$why"

  # 8 — the interview row: exactly one when the design step stays, none when it
  # is out, and the previous row with only its path renamed.
  local dplan hasd piv div want niv
  dplan=$(MANIFEST="$draft" manifest_plan_json)
  hasd=$(printf '%s' "$dplan" | jq -r '[.steps[]? | select(type == "object" and .skill == "design")] | length' 2>/dev/null)
  piv=$(MANIFEST="$prev" rk_interview_rows); div=$(MANIFEST="$draft" rk_interview_rows)
  niv=$(printf '%s' "$div" | grep -c . || true)
  why=""
  if [ "${hasd:-0}" -ge 1 ]; then
    if [ "${niv:-0}" != "1" ]; then why="설계 단계가 남는데 인터뷰 행이 ${niv:-0}개입니다"
    else
      want=$(printf '%s' "$piv" | awk -v p="docs/pipeline-run/$D_ID.interview.md" '{ sub(/인터뷰 기록=[^|]*\|/, "인터뷰 기록=" p " |"); print }')
      [ -n "$piv" ] && [ "$div" = "$want" ] || why="인터뷰 행이 원천 행에서 경로만 새 런으로 바꾼 것이 아닙니다"
    fi
  else
    [ "${niv:-0}" = "0" ] || why="설계 단계가 빠졌는데 인터뷰 행이 남았습니다"
  fi
  vs_check 인터뷰 "$why"

  # 9 — re-asked pre-authorization belongs to a confirmed added target.
  why=""
  if [ -n "$a5p$a5q" ] && ! awk -F '\t' '$1 ~ /^대상추가 / { f = 1 } END { exit !f }' "$RK_ASKED"; then
    why="5p·5q 답이 있는데 확인된 대상 추가가 없습니다"
  fi
  vs_check 대상추가 "$why"

  # 10 — the deadline keeps the interval, unless 5e was asked. Then the draft's
  # deadline is the instant the answer was resolved to (`5e 값`), compared as an
  # instant: the answer itself may be a relative form no draft can equal.
  local a5e v5e pe pk de dk ve
  a5e=$(rk_asked_answer '5e'); v5e=$(rk_asked_answer '5e 값')
  why=""
  if [ -n "$a5e" ] || [ -n "$v5e" ]; then
    de=$(rk_wide_instant "$D_DL"); ve=$(rk_wide_instant "$v5e")
    if [ -z "$a5e" ]; then why="5e 값은 있는데 5e 답이 없습니다"
    elif [ -z "$v5e" ]; then why="5e 를 물었는데 해석한 마감(5e 값)이 없습니다"
    elif [ -z "$de" ] || [ -z "$ve" ]; then why="마감이나 5e 값을 시각으로 읽지 못했습니다"
    elif [ "$de" != "$ve" ]; then why="5e 를 물었는데 마감이 그 답을 해석한 시각이 아닙니다"
    fi
  else
    pe=$(rk_wide_instant "$P_DL"); pk=$(rk_wide_instant "$P_KAT")
    de=$(rk_wide_instant "$D_DL"); dk=$(rk_wide_instant "$D_KAT")
    if [ -z "$pe" ] || [ -z "$pk" ] || [ -z "$de" ] || [ -z "$dk" ]; then why="마감이나 킥오프 일시를 시각으로 읽지 못했습니다"
    elif [ $((de - dk)) != $((pe - pk)) ]; then why="마감 간격이 원천과 다릅니다 ($((de - dk)) ≠ $((pe - pk)))"
    fi
  fi
  vs_check 마감 "$why"

  # 11·12 — no design step means no design required; no broken dependency.
  why=""
  if [ "${hasd:-0}" = "0" ] && [ "$(printf '%s' "$dplan" | jq -r '.design_required' 2>/dev/null)" = "true" ]; then
    why="설계 단계가 없는데 design_required 가 true 입니다"
  fi
  vs_check 설계 "$why"
  why=""
  printf '%s' "$dplan" | jq -e '[.steps[]? | select(type == "object")] as $s | ([$s[] | (.depends_on // [])[]] - [$s[].id] | length) == 0' >/dev/null 2>&1 \
    || why="지운 단계를 가리키는 depends_on 이 있습니다"
  vs_check 의존 "$why"

  # The new authorization block, when given.
  if [ -n "$RK_GRANT_BLOCK" ]; then
    local gid gcut dmax gf gv
    gid=$(sed -n 's/^## 인가 //p' "$RK_GRANT_BLOCK" | head -n 1 | sed 's/[[:space:]]*$//')
    why=""
    [ "$gid" = "$D_ID" ] || why="${why:+$why; }블록 id($gid)가 새 런 id($D_ID)가 아닙니다"
    for gf in '인가 일시' '종료 지점' '권한 절단점' '말단 행위 상한' '직렬 웨이브 고지' \
              '시각 정합 마커' '사용자 확인 문면' '설계 문서 전체 sha256' '보고서'; do
      gv=$(awk -v k="$gf" 'index($0, "**" k "**: ") == 1 { print substr($0, length(k) + 7); exit }' "$RK_GRANT_BLOCK")
      [ -n "$gv" ] || why="${why:+$why; }블록에 $gf 가 없습니다"
    done
    gcut=$(awk 'index($0, "**권한 절단점**: ") == 1 { print substr($0, length("권한 절단점") + 7); exit }' "$RK_GRANT_BLOCK")
    dmax=$(rk_cut_max "$(MANIFEST="$draft" manifest_targets)")
    [ -n "$gcut" ] && [ "$gcut" = "$(MANIFEST="$draft" manifest_field '인가' '런 최대 절단점')" ] && [ "$gcut" = "$dmax" ] \
      || why="${why:+$why; }권한 절단점이 초안의 런 최대 절단점·대상 절단점의 최댓값과 다릅니다"
    for gf in '종료 지점:인가' '사용자 확인 문면:런 정체' '설계 문서 전체 sha256:요소'; do
      gv=$(awk -v k="${gf%%:*}" 'index($0, "**" k "**: ") == 1 { print substr($0, length(k) + 7); exit }' "$RK_GRANT_BLOCK")
      [ "$gv" = "$(MANIFEST="$draft" manifest_field "${gf#*:}" "${gf%%:*}")" ] \
        || why="${why:+$why; }${gf%%:*} 가 초안과 다릅니다"
    done
    vs_check 인가블록 "$why"
  fi

  # Last — the previous files measured again, against the provenance row.
  why=""
  [ "$(rk_sha "$RK_POS2")" = "$RK_XSHA" ] || why="${why:+$why; }이전 매니페스트가 바뀌었습니다"
  [ "$(rk_sha "$pgrant")" = "$RK_XGSHA" ] || why="${why:+$why; }이전 인가 기록이 바뀌었습니다"
  vs_check 원천해시 "$why"

  if [ -z "$VS_FAILED" ]; then printf '판정\t통과\n'; exit 0; fi
  printf '판정\t실패\t%s\n' "$VS_FAILED"
  exit 1
}

case "$RK_MODE" in
  detect)           rk_detect ;;
  verify)           rk_verify ;;
  graph)            rk_graph ;;
  render-manifest)  rk_render_manifest ;;
  render-interview) rk_render_interview ;;
  verify-subset)    rk_verify_subset ;;
esac
