#!/usr/bin/env bash
#
# kickoff-defaults.sh — the autopilot kickoff's reader for its boundary-question
# defaults.
#
# A person may write the answers to the kickoff's boundary questions ahead of
# time, in one host file, and override the run-wide ones for a single run with
# environment variables. This program reads, validates and cross-checks those
# values and prints what the kickoff should show the person at 5o. It decides
# nothing on its own: every value it marks `적용` is still read to the person and
# confirmed once before Step 6 freezes it into the manifest.
#
# ONLY THE KICKOFF CALLS THIS. The gate, the driver, the fleet and the watcher
# never read the file or the variables, so a running run is not changed by
# editing the file. Inside a pipeline run (`CC_PIPELINE_RUN_ID`,
# `CC_PIPELINE_STAGE_ID` or `CC_PIPELINE_SHIFT_ID` set) this program refuses
# with exit 3 before it reads anything.
#
# The file
#
#   ${XDG_CONFIG_HOME:-$HOME/.config}/cc-cmds/autopilot-defaults
#   CC_CMDS_AUTOPILOT_DEFAULTS_FILE=<absolute path>   replaces the path for a run
#   CC_CMDS_AUTOPILOT_DEFAULTS_FILE=off               reads no file
#
# NO CREDENTIAL VALUE GOES INTO THIS FILE. It sits beside the credential store
# and is not one: it is not mode-restricted, and its whole-file sha256 is shown
# to the person on every kickoff.
#
# Grammar, one line at a time — anything else is ignored as `문법 오류`:
#
#   (empty line)
#   # a whole-line comment
#   [<owner>/<name>]            a repository section; lines before the first one
#                               are run-wide
#   <key> = <value>             split at the first `=`, both ends trimmed; no
#                               end-of-line comment, no quoting, a trailing CR is
#                               dropped, a TAB or other control byte in the value
#                               is a syntax error
#
# The file is NEVER sourced: it is read with `read -r` and the values are only
# ever compared, so a value such as `$(…)` is a string and runs nothing.
#
# The run-wide keys can also come from the environment, and a valid variable
# beats the file: CC_CMDS_AUTOPILOT_DEFAULT_{LADDER_RUNGS,STAGNATION_BOUND,
# COST_CEILING,DEADLINE,ROSTER_MODEL}. An invalid variable is ignored together
# with the file's value for the same key; an empty one is unset.
#
# Usage
#
#   kickoff-defaults.sh --target <owner/name> [--target …]
#                       [--apply-actor 파이프라인|사람|없음] [--now <epoch>]
#   kickoff-defaults.sh --check-deadline <ISO8601> [--now <epoch>]
#   kickoff-defaults.sh --carry <previous manifest> --kickoff-at <ISO8601>
#                       --expect-sha256 <hex> [--now <epoch>]
#
# Output (main mode) is TAB-separated, the first line `cc-kickoff-defaults v1`:
#
#   원천  <path|off|없음|해석불가>  <sha256|->  <run-wide variables read>
#   적용  <범위>  <키>  <값>  <출처>  <확대 0|1>  <효과 한 줄>
#   무시  <범위>  <키|변수>  <날값>  <출처>  <사유 토큰>  <사유 문면>
#
# `--check-deadline` prints one line, `지남` or `남음`, and no header.
#
# `--carry` reads a previous run's frozen manifest as the answers and the file
# only as the thing it is compared with. The same header and `원천` row, then:
#
#   적용          <범위>  <키>  <이전 값>  이전 매니페스트  <확대 0|1>  <효과 한 줄>
#   차이          <범위>  <키>  <이전 값>  <파일 값>  <출처>
#   빈칸          <범위>  <키>  <파일 값>  <출처>  <확대 0|1>  <효과 한 줄>
#   권한          <범위>  <키>  <이어받는 값 축자>  <확대 0|1>  <효과 한 줄>
#   마감          ok  <새 절대 마감>  <간격 초>
#   마감          <사유 토큰>  <사유 문면>
#   이어받지 않음  <범위>  <키>  <사유 토큰>  <사유 문면>
#
# Every key of the key table yields, per scope it lives in, an `적용` row, a
# `빈칸` row or an `이어받지 않음` row. The previous manifest is copied once to a
# private file whose whole sha256 must equal `--expect-sha256` — the hash the
# kickoff verified — and every read after that is of the copy.
#
# Exit codes: 0 read (zero rows included) · 2 usage, or a `--check-deadline`
# value that is not the absolute form · 3 refused (inside a run), the
# vocabulary could not be read, or the `--carry` copy does not hash to
# `--expect-sha256`. On 2 and 3 stdout is empty and stderr carries one line.
#
# Compatibility: bash 3.2 — no associative arrays, no `declare -A`. Time is
# computed with jq only; `date` is not used, `%z` is not used.

set -uo pipefail

KD_PROG='kickoff-defaults.sh'
KD_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)

kd_refuse() { printf '%s: %s\n' "$KD_PROG" "$1" >&2; exit 3; }
kd_usage()  { printf '%s: %s\n' "$KD_PROG" "$1" >&2; exit 2; }

for kd_v in CC_PIPELINE_RUN_ID CC_PIPELINE_STAGE_ID CC_PIPELINE_SHIFT_ID; do
  eval "kd_val=\${$kd_v:-}"
  if [ -n "$kd_val" ]; then
    kd_refuse "파이프라인 런 안에서는 읽지 않습니다 — 킥오프 기본값은 킥오프만 읽습니다 ($kd_v 가 설정돼 있습니다)"
  fi
done

# The key table — a closed set. These two lines are the code side of the key
# table SKILL.md 5o carries, and a lint compares the two sets.
KD_RUN_KEYS='ladder-rungs stagnation-bound cost-ceiling deadline roster-model roster-model.<역할> auto-adopt'
KD_REPO_KEYS='cutpoint review-ceiling terminal-cap dev-ids deploy-triggers act-allow apply-probe apply-actor'
# Where `--carry` finds each key in a frozen manifest. Not compared by the lint
# that compares the two lines above with 5o, so the test asserts that every key
# there yields a row. `<인가>` and `<요소>` are `**<필드>**: ` lines of that
# section, `<대상>` a `<필드>=` field of each `target` row, `<행>` the rows of
# that kind anywhere in the file.
kd_carry_field() {
  case "$1" in
    ladder-rungs)       printf '인가\t사다리 가용 단 수' ;;
    stagnation-bound)   printf '인가\t무진전 상한' ;;
    cost-ceiling)       printf '인가\t비용 천장' ;;
    deadline)           printf '인가\t벽시계 마감' ;;
    roster-model|roster-model.*) printf '행\t설계 로스터' ;;
    auto-adopt)         printf '행\t자동 채택' ;;
    cutpoint)           printf '대상\t절단점' ;;
    review-ceiling)     printf '대상\t리뷰 정책 상한' ;;
    terminal-cap)       printf '대상\t말단 행위 상한' ;;
    dev-ids)            printf '대상\tdev 식별자' ;;
    deploy-triggers)    printf '대상\t배포트리거 식별자' ;;
    act-allow)          printf '행\t사전 인가' ;;
    apply-probe)        printf '요소\t적용 프로브' ;;
    apply-actor)        printf '요소\t적용 주체' ;;
    *) return 1 ;;
  esac
}
# Keys refused by name, so that whoever tried one reads why rather than a typo.
KD_NAMED_REFUSED='termination launch defer notify apply-command apply-radius'

KD_ENV_PREFIX='CC_CMDS_AUTOPILOT_DEFAULT'
KD_ENV_FILE_VAR='CC_CMDS_AUTOPILOT_DEFAULTS_FILE'
KD_ENV_RUN_VARS='CC_CMDS_AUTOPILOT_DEFAULT_COST_CEILING CC_CMDS_AUTOPILOT_DEFAULT_DEADLINE CC_CMDS_AUTOPILOT_DEFAULT_LADDER_RUNGS CC_CMDS_AUTOPILOT_DEFAULT_ROSTER_MODEL CC_CMDS_AUTOPILOT_DEFAULT_STAGNATION_BOUND'

KD_ABS_RE='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}[+-][0-9]{2}:[0-9]{2}$'

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------
KD_NT=0
KD_AA_GIVEN=0; KD_AA=''
KD_NOW=''
KD_CHECK_GIVEN=0; KD_CHECK=''
KD_CARRY_GIVEN=0; KD_CARRY=''; KD_KAT=''; KD_XSHA=''
while [ $# -gt 0 ]; do
  case "$1" in
    --target)
      [ $# -ge 2 ] && [ -n "$2" ] || kd_usage "--target 에 값이 없습니다"
      case "$2" in
        */*/*|/*|*/|*[[:space:]]*) kd_usage "--target 은 <owner>/<name> 이어야 합니다: '$2'" ;;
        */*) ;;
        *) kd_usage "--target 은 <owner>/<name> 이어야 합니다: '$2'" ;;
      esac
      KD_TARGET[KD_NT]="$2"; KD_NT=$((KD_NT + 1)); shift 2 ;;
    --apply-actor)
      [ $# -ge 2 ] || kd_usage "--apply-actor 에 값이 없습니다"
      case "$2" in
        파이프라인|사람|없음) ;;
        *) kd_usage "--apply-actor 는 파이프라인·사람·없음 중 하나여야 합니다: '$2'" ;;
      esac
      KD_AA_GIVEN=1; KD_AA="$2"; shift 2 ;;
    --now)
      [ $# -ge 2 ] || kd_usage "--now 에 값이 없습니다"
      case "$2" in
        ''|*[!0-9]*) kd_usage "--now 는 epoch 초 정수여야 합니다: '$2'" ;;
      esac
      KD_NOW="$2"; shift 2 ;;
    --check-deadline)
      [ $# -ge 2 ] || kd_usage "--check-deadline 에 값이 없습니다"
      KD_CHECK_GIVEN=1; KD_CHECK="$2"; shift 2 ;;
    --carry)
      [ $# -ge 2 ] && [ -n "$2" ] || kd_usage "--carry 에 값이 없습니다"
      KD_CARRY_GIVEN=1; KD_CARRY="$2"; shift 2 ;;
    --kickoff-at)
      [ $# -ge 2 ] && [ -n "$2" ] || kd_usage "--kickoff-at 에 값이 없습니다"
      KD_KAT="$2"; shift 2 ;;
    --expect-sha256)
      [ $# -ge 2 ] || kd_usage "--expect-sha256 에 값이 없습니다"
      printf '%s\n' "$2" | grep -E '^[0-9a-f]{64}$' >/dev/null \
        || kd_usage "--expect-sha256 은 소문자 16진 64자여야 합니다"
      KD_XSHA="$2"; shift 2 ;;
    *) kd_usage "모르는 인자: '$1'" ;;
  esac
done

if [ "$KD_CARRY_GIVEN" = "1" ]; then
  [ "$KD_NT" -eq 0 ] && [ "$KD_AA_GIVEN" = "0" ] && [ "$KD_CHECK_GIVEN" = "0" ] \
    || kd_usage "--carry 는 --target·--apply-actor·--check-deadline 과 함께 쓰지 않습니다 — 대상과 적용 주체는 이전 매니페스트에서 읽습니다"
  [ -n "$KD_KAT" ] || kd_usage "--carry 에는 --kickoff-at 이 필요합니다"
  [ -n "$KD_XSHA" ] || kd_usage "--carry 에는 --expect-sha256 이 필요합니다"
elif [ -n "$KD_KAT$KD_XSHA" ]; then
  kd_usage "--kickoff-at·--expect-sha256 은 --carry 와 함께만 씁니다"
elif [ "$KD_CHECK_GIVEN" = "1" ]; then
  [ "$KD_NT" -eq 0 ] && [ "$KD_AA_GIVEN" = "0" ] \
    || kd_usage "--check-deadline 은 --target·--apply-actor 와 함께 쓰지 않습니다"
else
  [ "$KD_NT" -gt 0 ] || kd_usage "--target 이 하나 이상 필요합니다"
fi

command -v jq >/dev/null 2>&1 || kd_refuse "jq 가 없어 시각을 계산할 수 없습니다"
if [ -z "$KD_NOW" ]; then
  KD_NOW=$(jq -n 'now | floor' 2>/dev/null) || KD_NOW=''
  case "$KD_NOW" in
    ''|*[!0-9]*) kd_refuse "지금 시각을 읽지 못했습니다" ;;
  esac
fi

# ---------------------------------------------------------------------------
# Time — jq only. The UTC offset of an instant is measured, never formatted:
# `(e|localtime|mktime) - e`, rounded to the minute. `%z` reports the offset of
# a different instant in a daylight-saving zone, and `date` differs between BSD
# and GNU.
# ---------------------------------------------------------------------------
KD_JQ_TIME='
def pad2: if . < 10 then "0" + tostring else tostring end;
def off($e): ((((($e | localtime | mktime) - ($e | floor)) + 30) / 60) | floor) * 60;
def fmtoff($o): (if $o < 0 then "-" else "+" end) as $sg
  | (if $o < 0 then -$o else $o end) as $a
  | $sg + (($a / 3600 | floor) | pad2) + ":" + ((($a % 3600) / 60 | floor) | pad2);
def wall($e): ($e + off($e)) | strftime("%Y-%m-%dT%H:%M:%S");
def render($e): wall($e) + fmtoff(off($e));
def wallepoch($w): $w | strptime("%Y-%m-%dT%H:%M:%S") | mktime;
def resolve($w): wallepoch($w) as $L | ($L - off($now)) as $g | ($L - off($g)) as $e
  | if wall($e) == $w then {e: $e} else {err: "시각 없음", msg: ("벽시계 " + $w + " 는 일광절약 전환으로 이 시간대에 존재하지 않습니다")} end;
def localdate($d): (($now + off($now)) + ($d * 86400)) | strftime("%Y-%m-%d");
def hm_ok($h; $m): ($h >= 0 and $h <= 23 and $m >= 0 and $m <= 59);
def abs_epoch($s): ($s[0:19] | strptime("%Y-%m-%dT%H:%M:%S") | mktime) as $L
  | ((($s[20:22] | tonumber) * 3600) + (($s[23:25] | tonumber) * 60)) as $o
  | if $s[19:20] == "-" then $L + $o else $L - $o end;
def future($r): if $r.err then $r
  elif $r.e <= $now then {err: "과거 시각", msg: ("풀린 시각 " + render($r.e) + " 이 지금 이후가 아닙니다")}
  else $r end;
def at($d; $h; $m): resolve(localdate($d) + "T" + ($h | pad2) + ":" + ($m | pad2) + ":00");
def kind_rel: {kind: "상대"};
def solve($s):
  if ($s | test("Z$")) then {err: "형식 오류", msg: "Z 표기는 받지 않습니다 — ±HH:MM 오프셋을 붙여 쓰십시오"}
  elif ($s | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}[+-][0-9]{2}:[0-9]{2}$")) then
    ((try abs_epoch($s) catch null) as $e
     | if $e == null then {err: "형식 오류", msg: "절대 시각으로 읽히지 않습니다"}
       elif $e <= $now then {err: "과거 시각", msg: ("절대 시각 " + $s + " 이 지금 이후가 아닙니다")}
       else {e: $e, abs: $s, kind: "절대"} end)
  elif ($s | test("^\\+[0-9]+h([0-9]+m)?$")) then
    ($s | capture("^\\+(?<h>[0-9]+)h((?<m>[0-9]+)m)?$")) as $c
    | ($c.h | tonumber) as $h | (($c.m // "0") | tonumber) as $m
    | if $h < 1 or $h > 168 or $m > 59 then {err: "범위 초과", msg: "+Nh[Mm] 의 N 은 1..168, M 은 0..59 입니다"}
      else future({e: ($now + $h * 3600 + $m * 60)}) + kind_rel end
  elif ($s | test("^\\+[0-9]+m$")) then
    ($s | capture("^\\+(?<m>[0-9]+)m$") | .m | tonumber) as $m
    | if $m < 1 or $m > 10080 then {err: "범위 초과", msg: "+Mm 의 M 은 1..10080 입니다"}
      else future({e: ($now + $m * 60)}) + kind_rel end
  elif ($s | test("^[0-9]{2}:[0-9]{2}$")) then
    ($s[0:2] | tonumber) as $h | ($s[3:5] | tonumber) as $m
    | if (hm_ok($h; $m) | not) then {err: "형식 오류", msg: "HH:MM 의 시는 00..23, 분은 00..59 입니다"}
      else
        ((wallepoch(localdate(0) + "T" + $s + ":00") - off($now)) <= $now) as $passed
        | future(at(if $passed then 1 else 0 end; $h; $m)) + kind_rel
      end
  elif ($s | test("^(\\+[0-9]+d|다음 ?날) [0-9]{2}:[0-9]{2}$")) then
    ($s | capture("^(\\+(?<d>[0-9]+)d|다음 ?날) (?<hh>[0-9]{2}):(?<mm>[0-9]{2})$")) as $c
    | (($c.d // "1") | tonumber) as $d | ($c.hh | tonumber) as $h | ($c.mm | tonumber) as $m
    | if (hm_ok($h; $m) | not) then {err: "형식 오류", msg: "HH:MM 의 시는 00..23, 분은 00..59 입니다"}
      elif $d > 7 then {err: "범위 초과", msg: "+Dd 의 D 는 0..7 입니다"}
      else future(at($d; $h; $m)) + kind_rel end
  else {err: "형식 오류", msg: "받는 형태: +Nh[Mm] · +Mm · HH:MM · +Dd HH:MM · 다음 날 HH:MM · YYYY-MM-DDTHH:MM:SS±HH:MM"}
  end;
'

# kd_deadline <value> — prints `ok<TAB><absolute><TAB><상대|절대>` or
# `<사유 토큰><TAB><사유 문면>`. jq inherits TZ exactly as it is: an unset TZ
# means the system zone, while an empty one means UTC to libc, so the variable
# is never re-exported here.
kd_deadline() {
  local out
  out=$(jq -nr --arg s "$1" --argjson now "$KD_NOW" "$KD_JQ_TIME"'
    solve($s) | if .err then "\(.err)\t\(.msg)"
                else "ok\t\(.abs // render(.e))\t\(.kind)" end' 2>/dev/null) || out=''
  [ -n "$out" ] || out="형식 오류	마감을 해석하지 못했습니다"
  printf '%s' "$out"
}

if [ "$KD_CHECK_GIVEN" = "1" ]; then
  printf '%s\n' "$KD_CHECK" | grep -E "$KD_ABS_RE" >/dev/null \
    || kd_usage "절대 마감 형태(YYYY-MM-DDTHH:MM:SS±HH:MM)가 아닙니다: '$KD_CHECK'"
  KD_E=$(jq -nr --arg s "$KD_CHECK" "$KD_JQ_TIME"' abs_epoch($s) | floor' 2>/dev/null) || KD_E=''
  case "$KD_E" in
    ''|*[!0-9-]*) kd_usage "절대 마감을 시각으로 읽지 못했습니다: '$KD_CHECK'" ;;
  esac
  if [ "$KD_E" -le "$KD_NOW" ]; then printf '지남\n'; else printf '남음\n'; fi
  exit 0
fi

# ---------------------------------------------------------------------------
# Vocabulary — sourced from the driver, never copied. The definitions-only seam
# loads the constants and functions and returns before any pipeline runs; the
# strict modes it imports are dropped right after.
# ---------------------------------------------------------------------------
[ -r "$KD_DIR/run.sh" ] || kd_refuse "run.sh 를 읽을 수 없습니다: $KD_DIR/run.sh"
# shellcheck disable=SC1091
CC_ORCH_SOURCE_ONLY=1 . "$KD_DIR/run.sh" >/dev/null 2>&1 || kd_refuse "run.sh 를 들여오지 못했습니다"
set +e +u
set +o pipefail
if [ -z "${CUTPOINTS:-}" ] || [ -z "${REVIEW_POLICIES:-}" ] \
   || [ -z "${JUDGMENT_CLASSES:-}" ] || [ -z "${JUDGMENT_CLASSES_FORBIDDEN:-}" ]; then
  kd_refuse "run.sh 에서 어휘를 읽지 못했습니다"
fi
for kd_f in cutpoint_index cutpoint_token manifest_id_element_reason; do
  command -v "$kd_f" >/dev/null 2>&1 || kd_refuse "run.sh 에 $kd_f 가 없습니다"
done
# The runner names come from the one line the pre-authorization matcher reads.
KD_RUNNERS=$(awk -F'"' '/^runners="/ { print $2; exit }' "$KD_DIR/rules/사전-인가-대조.sh" 2>/dev/null)
[ -n "$(printf '%s' "$KD_RUNNERS" | tr -d ' ')" ] || kd_refuse "사전 인가 대조기에서 러너 목록을 읽지 못했습니다"

# ---------------------------------------------------------------------------
# `--carry` — the previous manifest, copied once and read only as the copy.
#
# The driver's accessors take a path and read the file again on every call, so
# hashing the original and then reading it would measure one set of bytes and
# use another. The copy is made first, hashed, and becomes `MANIFEST`; nothing
# after this block opens the original path.
# ---------------------------------------------------------------------------
# kd_wide_instant <value> — epoch seconds, or nothing. A trailing `Z` and a
# trailing `±HHMM` are first rewritten to the `±HH:MM` the driver's reader
# takes, and the driver's own reader then decides: it renders the value back to
# itself and refuses an offset beyond ±14:00, so this reads no instant the gate
# would not.
kd_wide_instant() {
  local s
  s=$(jq -rn --arg s "$1" '$s | sub("Z$"; "+00:00") | sub("(?<g>[+-])(?<h>[0-9]{2})(?<m>[0-9]{2})$"; "\(.g)\(.h):\(.m)")' 2>/dev/null) || s=''
  [ -n "$s" ] || return 0
  deadline_instant "$s"
}
if [ "$KD_CARRY_GIVEN" = "1" ]; then
  for kd_f in deadline_instant manifest_field target_field target_aliases manifest_preauth_rows manifest_autoadopt_rows_anywhere manifest_design_roster_rows_anywhere; do
    command -v "$kd_f" >/dev/null 2>&1 || kd_refuse "run.sh 에 $kd_f 가 없습니다"
  done
  KD_KAT_E=$(kd_wide_instant "$KD_KAT")
  case "$KD_KAT_E" in
    ''|*[!0-9]*) kd_usage "--kickoff-at 을 시각으로 읽지 못했습니다: '$KD_KAT'" ;;
  esac
  [ -r "$KD_CARRY" ] && [ ! -d "$KD_CARRY" ] || kd_refuse "이전 매니페스트를 읽을 수 없습니다: $KD_CARRY"
  KD_COPY=$(mktemp "${TMPDIR:-/tmp}/cc-kickoff-carry.XXXXXX" 2>/dev/null) || kd_refuse "개인 사본을 만들지 못했습니다"
  trap 'rm -f "$KD_COPY"' EXIT
  chmod 600 "$KD_COPY" 2>/dev/null || kd_refuse "개인 사본의 권한을 600 으로 두지 못했습니다"
  cat -- "$KD_CARRY" > "$KD_COPY" 2>/dev/null || kd_refuse "이전 매니페스트를 개인 사본으로 옮기지 못했습니다"
  if command -v shasum >/dev/null 2>&1; then
    kd_csha=$(shasum -a 256 "$KD_COPY" | awk '{ print $1 }')
  else
    kd_csha=$(sha256sum "$KD_COPY" | awk '{ print $1 }')
  fi
  [ "$kd_csha" = "$KD_XSHA" ] \
    || kd_refuse "이전 매니페스트가 킥오프가 검증한 해시와 다릅니다 — 검증 뒤에 바뀐 파일은 이어받지 않습니다"
  MANIFEST="$KD_COPY"
  # The targets are the copy's `target` rows; the file's sections are matched
  # to them by remote slug.
  KD_NT=0
  while IFS= read -r kd_al; do
    [ -n "$kd_al" ] || continue
    kd_sl=$(target_field "$kd_al" '원격 슬러그')
    KD_TALIAS[KD_NT]="$kd_al"
    KD_TARGET[KD_NT]="${kd_sl:-$kd_al}"
    KD_NT=$((KD_NT + 1))
  done <<EOF
$(target_aliases)
EOF
  # The interview's apply-actor answer is the one the previous run froze.
  case "$(manifest_field '요소' '적용 주체')" in
    파이프라인) KD_AA_GIVEN=1; KD_AA='파이프라인' ;;
    사람) KD_AA_GIVEN=1; KD_AA='사람' ;;
    *) KD_AA_GIVEN=1; KD_AA='없음' ;;
  esac
fi

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------
kd_trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}
# One field of a TSV row: no TAB, no newline, no control byte.
kd_cell() { printf '%s' "$1" | LC_ALL=C tr '\001-\037\177' ' '; }
kd_in() {   # kd_in <word> <space-separated list>
  case "$1" in ''|*[[:space:]]*) return 1 ;; esac
  case " $2 " in *" $1 "*) return 0 ;; esac
  return 1
}
kd_norm_slug() {
  local s
  s=$(printf '%s' "$1" | LC_ALL=C tr 'A-Z' 'a-z')
  printf '%s' "${s%.git}"
}
kd_words() { printf '%s' "$1" | awk '{ print NF }'; }
kd_cut_i() { cutpoint_index "$1" 2>/dev/null; }

# Cost ceiling: the gate's figure grammar (`gate_cost_figure_ok`, two `case`
# arms, copied because the gate is not sourced here — a test samples both), and
# a value of zero is refused besides: the gate accepts it, and it never fires.
kd_cost_ok() {
  case "$1" in ''|*[!0-9.]*) return 1 ;; esac
  case "$1" in *.*.*|*.) return 1 ;; esac
  case "$1" in *[1-9]*) return 0 ;; esac
  return 2
}

# A `형태` is a runner form when the pre-authorization matcher would match it by
# prefix: its first word is a runner and it has no more words than the first
# non-option operand position, measured on the form itself (2 when none). The
# matcher measures that position on the act's argv, so this leans toward
# marking: a form with an option in it is marked rather than missed.
kd_is_runner_form() {
  local first nwords pos
  first=$(printf '%s' "$1" | awk '{ print $1; exit }')
  case "$KD_RUNNERS" in *" $first "*) ;; *) return 1 ;; esac
  nwords=$(kd_words "$1")
  pos=$(printf '%s' "$1" | awk '{ for (i = 2; i <= NF; i++) { if ($i ~ /^-/) continue; print i; exit } }')
  [ -n "$pos" ] || pos=2
  [ "$nwords" -gt "$pos" ] && return 1
  return 0
}

# ---------------------------------------------------------------------------
# Entries. bash 3.2 has no associative arrays, so an entry is one index across
# parallel arrays:
#   E_SCOPE  run | <target index> | other (a section that is not a target)
#   E_KEY E_RAW E_SRC     what was written and where
#   E_ST     ok | ign | hide
#   E_RT E_RM            reason token and text when ign
#   E_NORM E_ID E_X      normalized value, list identity, extra (deadline form)
#   E_PLACED             1 when the key is known and in the right scope
#   E_SECDUP             1 when its section header is duplicated
# ---------------------------------------------------------------------------
KD_N=0
kd_add() {   # kd_add <scope> <key> <raw> <src>
  E_SCOPE[KD_N]="$1"; E_KEY[KD_N]="$2"; E_RAW[KD_N]="$3"; E_SRC[KD_N]="$4"
  E_ST[KD_N]='ok'; E_RT[KD_N]=''; E_RM[KD_N]=''; E_NORM[KD_N]="$3"; E_ID[KD_N]=''; E_X[KD_N]=''
  E_PLACED[KD_N]=0; E_SECDUP[KD_N]=0
  KD_I=$KD_N
  KD_N=$((KD_N + 1))
}
kd_ign() { E_ST[$1]='ign'; E_RT[$1]="$2"; E_RM[$1]="$3"; }

# kd_validate <index> — the per-key rule for a placed key. Leaves E_ST ok with
# E_NORM set, or marks the entry ignored.
kd_validate() {
  local i="$1" k="${E_KEY[$1]}" v="${E_RAW[$1]}" r tok rest f1 f2 f3 f4 e reason nf
  if [ -z "$v" ]; then kd_ign "$i" '형식 오류' '값이 비어 있습니다'; return; fi
  case "$k" in
    ladder-rungs)
      case "$v" in 4|2) ;; *) kd_ign "$i" '어휘 밖' '허용: 4 2' ;; esac ;;
    stagnation-bound)
      case "$v" in
        없음) ;;
        *) printf '%s\n' "$v" | grep -E '^[1-9][0-9]*$' >/dev/null \
             || kd_ign "$i" '형식 오류' '0 으로 시작하지 않는 양의 정수 또는 없음' ;;
      esac ;;
    cost-ceiling)
      [ "$v" = "없음" ] && return
      kd_cost_ok "$v"; r=$?
      case "$r" in
        0) ;;
        2) kd_ign "$i" '형식 오류' '0 은 한도가 아닙니다 — 게이트가 받지만 그 천장은 발동하지 않습니다' ;;
        *) kd_ign "$i" '형식 오류' '통화 기호·단위 없이 숫자와 점 하나 이하로 쓰고 점으로 끝내지 않습니다, 또는 없음' ;;
      esac ;;
    deadline)
      r=$(kd_deadline "$v")
      tok="${r%%	*}"; rest="${r#*	}"
      if [ "$tok" = "ok" ]; then
        E_NORM[$i]="${rest%%	*}"; E_X[$i]="${rest#*	}"
      else
        kd_ign "$i" "$tok" "$rest"
      fi ;;
    roster-model|roster-model.*)
      case "$v" in opus|sonnet|haiku) ;; *) kd_ign "$i" '어휘 밖' '허용: opus sonnet haiku' ;; esac ;;
    cutpoint)
      if kd_in "$v" "$CUTPOINTS"; then :
      elif tok=$(cutpoint_token "$v" 2>/dev/null); then
        kd_ign "$i" '표시형' "토큰 \`$tok\` 로 쓰십시오"
      else
        kd_ign "$i" '어휘 밖' "허용: $CUTPOINTS"
      fi ;;
    review-ceiling)
      kd_in "$v" "$REVIEW_POLICIES" || kd_ign "$i" '어휘 밖' "허용: $REVIEW_POLICIES" ;;
    terminal-cap)
      case "$v" in
        없음) ;;
        *) printf '%s\n' "$v" | grep -E '^[1-9][0-9]*$' >/dev/null \
             || kd_ign "$i" '형식 오류' '없음 또는 양의 정수' ;;
      esac ;;
    dev-ids|deploy-triggers)
      [ "$v" = "없음" ] && return
      # The manifest check splits on `,` and trims nothing, so the applied value is
      # the trimmed elements joined by a bare `,` — the spelling it accepts.
      local side=dev IFS_SAVE="$IFS" joined=''
      [ "$k" = "deploy-triggers" ] && side=deploy
      IFS=','
      for e in $v; do
        IFS="$IFS_SAVE"
        e=$(kd_trim "$e")
        if ! reason=$(manifest_id_element_reason "$side" "$e"); then
          IFS="$IFS_SAVE"
          kd_ign "$i" '형식 오류' "$reason"
          return
        fi
        joined="${joined:+$joined,}$e"
        IFS=','
      done
      IFS="$IFS_SAVE"
      case "$v" in *,) kd_ign "$i" '형식 오류' '목록이 쉼표로 끝납니다 — 빈 원소입니다'; return ;; esac
      E_NORM[$i]="$joined" ;;
    act-allow)
      nf=$(printf '%s' "$v" | awk -F'|' '{ print NF }')
      f1=$(kd_trim "${v%%|*}"); f2=$(kd_trim "${v#*|}")
      if [ "$nf" != "2" ]; then
        kd_ign "$i" '형식 오류' '필드는 정확히 형태=·사유= 둘이고 이 순서입니다'; return
      fi
      case "$f1" in 형태=*) ;; *) kd_ign "$i" '형식 오류' '필드는 정확히 형태=·사유= 둘이고 이 순서입니다'; return ;; esac
      case "$f2" in 사유=*) ;; *) kd_ign "$i" '형식 오류' '필드는 정확히 형태=·사유= 둘이고 이 순서입니다'; return ;; esac
      # The row goes out byte for byte, and the matcher compares the text after
      # `형태=` with the argv head joined by single spaces, so any other spacing
      # in the form would be confirmed here and then never match.
      f1="${f1#형태=}"; f2=$(kd_trim "${f2#사유=}")
      if [ -z "$(kd_trim "$f1")" ] || [ -z "$f2" ]; then kd_ign "$i" '형식 오류' '형태 와 사유 는 비지 않습니다'; return; fi
      if [ "$f1" != "$(printf '%s' "$f1" | awk '{ $1 = $1; print }')" ]; then
        kd_ign "$i" '형식 오류' '형태 는 = 바로 뒤에 공백 없이 낱말 사이를 한 칸으로 씁니다 — 대조기가 이 철자 그대로 비교합니다'; return
      fi
      # The matcher normalizes the act's argv — argv0 to its basename, every later
      # `-x=y` word dropped — and not the form, so a form that this normalization
      # would change matches no act at all, not even the one spelled like it. The
      # awk is the matcher's own; the form is refused rather than normalized here,
      # because dropping `-chdir=infra` would freeze a wider grant than was written.
      r=$(printf '%s' "$f1" | awk '
        {
          for (i = 1; i <= NF; i++) {
            w = $i
            if (i == 1) { n = split(w, parts, "/"); w = parts[n] }
            else if (w ~ /^-.*=/) continue
            printf "%s%s", (out++ ? " " : ""), w
          }
          print ""
        }')
      if [ "$f1" != "$r" ]; then
        kd_ign "$i" '형식 오류' "형태 는 대조기가 보는 철자로 씁니다 — 명령 경로 없이, -x=y 낱말 없이 (대조기가 보는 철자: \`$r\`). 이 철자는 뗀 경로와 낱말의 모든 값을 엽니다 — 행을 두지 않으면 그 행위는 승인 대기로 갑니다"; return
      fi
      if [ "$(kd_words "$f1")" -lt 2 ]; then
        kd_ign "$i" '형식 오류' '형태 는 <명령> <하위 명령> 처럼 두 낱말 이상의 접두입니다 — 한 낱말은 그 명령 전부를 엽니다'; return
      fi
      E_ID[$i]="$f1"; E_X[$i]="$f2" ;;
    auto-adopt)
      nf=$(printf '%s' "$v" | awk -F'|' '{ print NF }')
      if [ "$nf" != "4" ]; then
        kd_ign "$i" '형식 오류' '필드는 정확히 판단 부류=<값> | 상한=<값> | 심각도 상한=<값> | 사유=<값> 넷이고 이 순서입니다'; return
      fi
      f1=$(kd_trim "$(printf '%s' "$v" | awk -F'|' '{ print $1 }')")
      f2=$(kd_trim "$(printf '%s' "$v" | awk -F'|' '{ print $2 }')")
      f3=$(kd_trim "$(printf '%s' "$v" | awk -F'|' '{ print $3 }')")
      f4=$(kd_trim "$(printf '%s' "$v" | awk -F'|' '{ print $4 }')")
      case "$f1|$f2|$f3|$f4" in
        '판단 부류='*'|상한='*'|심각도 상한='*'|사유='*) ;;
        *) kd_ign "$i" '형식 오류' '필드는 정확히 판단 부류=<값> | 상한=<값> | 심각도 상한=<값> | 사유=<값> 넷이고 이 순서입니다'; return ;;
      esac
      # The class field's name is stripped up to its `=` (the case above fixed
      # the prefix), so the literal is not spelled here with nothing after it.
      f1="${f1#*=}"; f2="${f2#상한=}"; f3="${f3#심각도 상한=}"; f4="${f4#사유=}"
      # The row goes out byte for byte, and the manifest check and the gate take
      # the class from right after its `=` without trimming the front, so a
      # space there would be confirmed here and then stop the run.
      for e in "$f1" "$f2" "$f3" "$f4"; do
        case "$e" in
          [[:space:]]*) kd_ign "$i" '형식 오류' '각 필드의 값은 = 바로 뒤에 공백 없이 씁니다 — 매니페스트 검사가 이 철자 그대로 읽습니다'; return ;;
        esac
      done
      f1=$(kd_trim "$f1"); f2=$(kd_trim "$f2"); f3=$(kd_trim "$f3"); f4=$(kd_trim "$f4")
      if ! kd_in "$f1" "$JUDGMENT_CLASSES"; then
        kd_ign "$i" '어휘 밖' "판단 부류 허용: $JUDGMENT_CLASSES"; return
      fi
      if kd_in "$f1" "$JUDGMENT_CLASSES_FORBIDDEN"; then
        kd_ign "$i" '금지 부류' "게이트가 스스로 채택하지 않는 부류입니다: $JUDGMENT_CLASSES_FORBIDDEN"; return
      fi
      case "$f2" in
        없음) ;;
        *) printf '%s\n' "$f2" | grep -E '^[0-9]+$' >/dev/null \
             || { kd_ign "$i" '형식 오류' '상한 은 없음 또는 정수입니다'; return; } ;;
      esac
      case "$f3" in
        critical|major|minor|trivial) ;;
        *) kd_ign "$i" '어휘 밖' '심각도 상한 허용: critical major minor trivial'; return ;;
      esac
      [ -n "$f4" ] || { kd_ign "$i" '형식 오류' '사유 는 비지 않습니다'; return; }
      E_ID[$i]="$f1"; E_X[$i]="상한=$f2 · 심각도 상한=$f3" ;;
    apply-probe) ;;
    apply-actor)
      case "$v" in 파이프라인|사람) ;; *) kd_ign "$i" '어휘 밖' '허용: 파이프라인 사람' ;; esac ;;
  esac
}

kd_named_reason() {
  case "$1" in
    termination) printf '종료 지점은 런마다 묻습니다' ;;
    launch|defer) printf '기동 시점은 5n 에서만 고릅니다' ;;
    notify) printf '배너는 CC_CMDS_AUTOPILOT_NOTIFY 로만 끕니다' ;;
    apply-command|apply-radius) printf '적용 명령·파급 범위는 런마다 묻습니다 — 매니페스트에 자리가 없습니다' ;;
  esac
}

# kd_place <index> <scope kind run|repo> — classify a key line by key and scope.
kd_place() {
  local i="$1" where="$2" k="${E_KEY[$1]}" want=''
  if kd_in "$k" "$KD_NAMED_REFUSED"; then
    kd_ign "$i" '이름 지은 거부' "$(kd_named_reason "$k")"; return
  fi
  case "$k" in
    roster-model.*)
      if printf '%s\n' "${k#roster-model.}" | grep -E '^[a-z0-9-]+$' >/dev/null; then want=run; fi ;;
    *)
      if [ "$k" != "roster-model.<역할>" ] && kd_in "$k" "$KD_RUN_KEYS"; then want=run
      elif kd_in "$k" "$KD_REPO_KEYS"; then want=repo
      fi ;;
  esac
  if [ -z "$want" ]; then kd_ign "$i" '모르는 키' '닫힌 키 집합에 없는 키입니다'; return; fi
  if [ "$want" != "$where" ]; then
    if [ "$want" = "run" ]; then
      kd_ign "$i" '자리 틀림' '런 단위 키는 첫 구획 머리 앞에 둡니다'
    else
      kd_ign "$i" '자리 틀림' '레포 키는 [<owner>/<name>] 구획 안에 둡니다'
    fi
    return
  fi
  E_PLACED[$i]=1
  kd_validate "$i"
}

# ---------------------------------------------------------------------------
# Targets
# ---------------------------------------------------------------------------
kd_t=0
while [ "$kd_t" -lt "$KD_NT" ]; do
  T_NORM[kd_t]=$(kd_norm_slug "${KD_TARGET[kd_t]}")
  T_CUT[kd_t]=''
  # Carried, the cutpoint is the previous run's, and every cross check below
  # that leans on it leans on that value rather than on the file's.
  if [ "$KD_CARRY_GIVEN" = "1" ]; then
    kd_c=$(target_field "${KD_TALIAS[kd_t]}" '절단점')
    kd_in "$kd_c" "$CUTPOINTS" && T_CUT[kd_t]="$kd_c"
  fi
  kd_t=$((kd_t + 1))
done
kd_target_of() {   # kd_target_of <normalized slug> → target index, or nothing
  local j=0
  while [ "$j" -lt "$KD_NT" ]; do
    [ "${T_NORM[j]}" = "$1" ] && { printf '%s' "$j"; return 0; }
    j=$((j + 1))
  done
  return 1
}

# ---------------------------------------------------------------------------
# Source
# ---------------------------------------------------------------------------
KD_SRC=''; KD_FILE=''
KD_FILE_VAR_BAD=0
kd_base=''
if [ -n "${XDG_CONFIG_HOME:-}" ]; then kd_base="$XDG_CONFIG_HOME"
elif [ -n "${HOME:-}" ]; then kd_base="$HOME/.config"
fi
case "$kd_base" in /*) KD_FILE="$kd_base/cc-cmds/autopilot-defaults" ;; *) KD_SRC='해석불가' ;; esac
kd_fv="${CC_CMDS_AUTOPILOT_DEFAULTS_FILE:-}"
if [ -n "$kd_fv" ]; then
  case "$kd_fv" in
    off) KD_SRC='off'; KD_FILE='' ;;
    /*) KD_SRC=''; KD_FILE="$kd_fv" ;;
    *) KD_SRC='해석불가'; KD_FILE=''; KD_FILE_VAR_BAD=1 ;;
  esac
fi
KD_SHA='-'
if [ -z "$KD_SRC" ]; then
  if [ ! -e "$KD_FILE" ]; then
    KD_SRC='없음'; KD_FILE=''
  elif [ ! -f "$KD_FILE" ] || [ ! -r "$KD_FILE" ]; then
    KD_SRC='해석불가'; KD_FILE=''
  else
    KD_SRC="$KD_FILE"
    if command -v shasum >/dev/null 2>&1; then
      KD_SHA=$(shasum -a 256 "$KD_FILE" | awk '{ print $1 }')
    else
      KD_SHA=$(sha256sum "$KD_FILE" | awk '{ print $1 }')
    fi
    [ -n "$KD_SHA" ] || KD_SHA='-'
  fi
fi

# ---------------------------------------------------------------------------
# The file — read once, two passes: the section headers first, so a duplicated
# header is known before either of its sections is read.
# ---------------------------------------------------------------------------
KD_NL=0
if [ -n "$KD_FILE" ]; then
  while IFS= read -r kd_line || [ -n "$kd_line" ]; do
    L_TEXT[KD_NL]="${kd_line%$'\r'}"
    KD_NL=$((KD_NL + 1))
  done < "$KD_FILE"
fi

kd_header_inner() {   # prints the slug of a well-formed header line, else fails
  case "$1" in \[*\]) ;; *) return 1 ;; esac
  local in="${1#\[}"; in="${in%\]}"
  printf '%s\n' "$in" | grep -E '^[^/[:space:]]+/[^/[:space:]]+$' >/dev/null || return 1
  printf '%s' "$in"
}

KD_HNORMS=''
kd_l=0
while [ "$kd_l" -lt "$KD_NL" ]; do
  kd_t=$(kd_trim "${L_TEXT[kd_l]}")
  if kd_in_h=$(kd_header_inner "$kd_t"); then
    KD_HNORMS="$KD_HNORMS$(kd_norm_slug "$kd_in_h")
"
  fi
  kd_l=$((kd_l + 1))
done

kd_cur='run'; kd_cur_dup=0
kd_l=0
while [ "$kd_l" -lt "$KD_NL" ]; do
  kd_ln=$((kd_l + 1))
  kd_t=$(kd_trim "${L_TEXT[kd_l]}")
  kd_l=$((kd_l + 1))
  case "$kd_t" in ''|'#'*) continue ;; esac
  case "$kd_t" in
    \[*)
      if kd_in_h=$(kd_header_inner "$kd_t"); then
        kd_hn=$(kd_norm_slug "$kd_in_h")
        kd_cnt=$(printf '%s' "$KD_HNORMS" | grep -cxF -- "$kd_hn")
        kd_cur_dup=0; [ "${kd_cnt:-0}" -gt 1 ] && kd_cur_dup=1
        if kd_ti=$(kd_target_of "$kd_hn"); then kd_cur="$kd_ti"; else kd_cur='other'; fi
      else
        kd_add "$kd_cur" '-' "$kd_t" "파일:$kd_ln"
        [ "$kd_cur" = "other" ] && E_ST[KD_I]='hide' || kd_ign "$KD_I" '문법 오류' '구획 머리는 [<owner>/<name>] 입니다'
        kd_cur='bad'; kd_cur_dup=0
      fi
      continue ;;
  esac
  case "$kd_t" in
    *=*)
      kd_k=$(kd_trim "${kd_t%%=*}"); kd_v=$(kd_trim "${kd_t#*=}")
      kd_add "$kd_cur" "${kd_k:--}" "$kd_v" "파일:$kd_ln"
      if [ "$kd_cur" = "other" ]; then E_ST[KD_I]='hide'; continue; fi
      E_SECDUP[KD_I]=$kd_cur_dup
      case "$kd_k$kd_v" in
        *[[:cntrl:]]*) kd_ign "$KD_I" '문법 오류' '키나 값에 TAB 이나 제어 문자가 있습니다'; continue ;;
      esac
      if [ -z "$kd_k" ]; then kd_ign "$KD_I" '문법 오류' '= 앞에 키가 없습니다'; continue; fi
      if [ "$kd_cur" = "bad" ]; then
        kd_ign "$KD_I" '자리 틀림' '문법 오류인 구획 머리 아래의 줄입니다'; continue
      fi
      if [ "$kd_cur" = "run" ]; then kd_place "$KD_I" run; else kd_place "$KD_I" repo; fi ;;
    *)
      kd_add "$kd_cur" '-' "$kd_t" "파일:$kd_ln"
      if [ "$kd_cur" = "other" ]; then E_ST[KD_I]='hide'
      else kd_ign "$KD_I" '문법 오류' '빈 줄·# 주석·[<owner>/<name>]·<키> = <값> 중 어느 것도 아닙니다'
      fi ;;
  esac
done

# A section header seen twice (after normalization) voids both sections.
kd_i=0
while [ "$kd_i" -lt "$KD_N" ]; do
  if [ "${E_SECDUP[kd_i]}" = "1" ] && [ "${E_ST[kd_i]}" != "hide" ]; then
    kd_ign "$kd_i" '중복' '같은 레포 구획이 두 번 나옵니다 (대소문자·끝 .git 무시) — 두 구획을 모두 쓰지 않습니다'
    E_PLACED[kd_i]=0
  fi
  kd_i=$((kd_i + 1))
done

# A scalar key twice in one scope: both are ignored, so neither silently wins.
kd_i=0
while [ "$kd_i" -lt "$KD_N" ]; do
  if [ "${E_PLACED[kd_i]}" = "1" ]; then
    case "${E_KEY[kd_i]}" in
      act-allow|auto-adopt) ;;
      *)
        kd_j=$((kd_i + 1))
        while [ "$kd_j" -lt "$KD_N" ]; do
          if [ "${E_PLACED[kd_j]}" = "1" ] && [ "${E_SCOPE[kd_j]}" = "${E_SCOPE[kd_i]}" ] \
             && [ "${E_KEY[kd_j]}" = "${E_KEY[kd_i]}" ]; then
            kd_ign "$kd_i" '중복' '한 범위에 같은 키가 두 번 있습니다 — 둘 다 쓰지 않습니다'
            kd_ign "$kd_j" '중복' '한 범위에 같은 키가 두 번 있습니다 — 둘 다 쓰지 않습니다'
          fi
          kd_j=$((kd_j + 1))
        done ;;
    esac
  fi
  kd_i=$((kd_i + 1))
done

# The same `형태` or the same `판단 부류` again in one scope: the later one goes.
kd_i=0
while [ "$kd_i" -lt "$KD_N" ]; do
  case "${E_KEY[kd_i]}" in
    act-allow|auto-adopt)
      if [ "${E_ST[kd_i]}" = "ok" ]; then
        kd_j=$((kd_i + 1))
        while [ "$kd_j" -lt "$KD_N" ]; do
          if [ "${E_ST[kd_j]}" = "ok" ] && [ "${E_KEY[kd_j]}" = "${E_KEY[kd_i]}" ] \
             && [ "${E_SCOPE[kd_j]}" = "${E_SCOPE[kd_i]}" ] && [ "${E_ID[kd_j]}" = "${E_ID[kd_i]}" ]; then
            kd_ign "$kd_j" '중복' "같은 항목이 앞(${E_SRC[kd_i]})에 이미 있습니다 — 뒤엣것을 쓰지 않습니다"
          fi
          kd_j=$((kd_j + 1))
        done
      fi ;;
  esac
  kd_i=$((kd_i + 1))
done

# ---------------------------------------------------------------------------
# Environment — run-wide keys only, named after the key. Names are enumerated
# (never values) to catch a misspelled variable; rows go out in name order.
# ---------------------------------------------------------------------------
KD_ENVN=0
for kd_v in $KD_ENV_RUN_VARS; do
  eval "kd_val=\${$kd_v:-}"
  [ -n "$kd_val" ] && KD_ENVN=$((KD_ENVN + 1))
done
kd_env_names=$(
  {
    compgen -e | grep "^$KD_ENV_PREFIX" || true
  } | sort -u
)
kd_key_of_var() {
  case "$1" in
    CC_CMDS_AUTOPILOT_DEFAULT_LADDER_RUNGS) printf 'ladder-rungs' ;;
    CC_CMDS_AUTOPILOT_DEFAULT_STAGNATION_BOUND) printf 'stagnation-bound' ;;
    CC_CMDS_AUTOPILOT_DEFAULT_COST_CEILING) printf 'cost-ceiling' ;;
    CC_CMDS_AUTOPILOT_DEFAULT_DEADLINE) printf 'deadline' ;;
    CC_CMDS_AUTOPILOT_DEFAULT_ROSTER_MODEL) printf 'roster-model' ;;
    *) return 1 ;;
  esac
}
for kd_v in $kd_env_names; do
  if [ "$kd_v" = "$KD_ENV_FILE_VAR" ]; then
    if [ "$KD_FILE_VAR_BAD" = "1" ]; then
      kd_add run "$kd_v" "$kd_fv" "환경:$kd_v"
      kd_ign "$KD_I" '형식 오류' '절대 경로 또는 off 여야 합니다 — 기본 경로로 물러서지 않고 파일을 읽지 않습니다'
    fi
    continue
  fi
  if ! kd_k=$(kd_key_of_var "$kd_v"); then
    kd_add run "$kd_v" '' "환경:$kd_v"
    kd_ign "$KD_I" '모르는 환경변수' "알려진 이름: $KD_ENV_RUN_VARS $KD_ENV_FILE_VAR"
    continue
  fi
  eval "kd_val=\${$kd_v:-}"
  [ -n "$kd_val" ] || continue
  kd_add run "$kd_k" "$kd_val" "환경:$kd_v"
  kd_ei=$KD_I
  case "$kd_val" in
    *[[:cntrl:]]*) kd_ign "$kd_ei" '형식 오류' '값에 TAB 이나 제어 문자가 있습니다' ;;
    *) kd_validate "$kd_ei" ;;
  esac
  kd_i=0
  while [ "$kd_i" -lt "$kd_ei" ]; do
    if [ "${E_SCOPE[kd_i]}" = "run" ] && [ "${E_KEY[kd_i]}" = "$kd_k" ] && [ "${E_ST[kd_i]}" = "ok" ]; then
      case "${E_SRC[kd_i]}" in
        파일:*)
          if [ "${E_ST[kd_ei]}" = "ok" ]; then
            E_ST[kd_i]='hide'
          else
            kd_ign "$kd_i" '환경변수 무효' "같은 키의 환경변수 $kd_v 가 무효라 파일 값도 쓰지 않습니다"
          fi ;;
      esac
    fi
    kd_i=$((kd_i + 1))
  done
done

# ---------------------------------------------------------------------------
# Cross checks — the values that lean on another answer.
# ---------------------------------------------------------------------------
kd_i=0
while [ "$kd_i" -lt "$KD_N" ]; do
  if [ "$KD_CARRY_GIVEN" = "0" ] && [ "${E_ST[kd_i]}" = "ok" ] && [ "${E_KEY[kd_i]}" = "cutpoint" ]; then
    case "${E_SCOPE[kd_i]}" in run|other|bad) ;; *) T_CUT[${E_SCOPE[kd_i]}]="${E_RAW[kd_i]}" ;; esac
  fi
  kd_i=$((kd_i + 1))
done
KD_DEPLOY_N=0
kd_t=0
while [ "$kd_t" -lt "$KD_NT" ]; do
  [ "${T_CUT[kd_t]}" = "배포" ] && KD_DEPLOY_N=$((KD_DEPLOY_N + 1))
  kd_t=$((kd_t + 1))
done
KD_I_MERGE=$(kd_cut_i '머지'); KD_I_PUSH=$(kd_cut_i 'push')

# apply-probe / apply-actor first: the review ceiling's conflict reads them.
KD_PIPE_APPLY=0
[ "$KD_AA" = "파이프라인" ] && KD_PIPE_APPLY=1
kd_i=0
while [ "$kd_i" -lt "$KD_N" ]; do
  if [ "${E_ST[kd_i]}" = "ok" ]; then
    case "${E_KEY[kd_i]}" in
      apply-probe|apply-actor)
        kd_c="${T_CUT[${E_SCOPE[kd_i]}]}"
        if [ -z "$kd_c" ]; then
          kd_ign "$kd_i" '절단점 미정' '이 레포의 절단점이 기본값으로 정해질 때만 판정합니다'
        elif [ "$kd_c" != "배포" ]; then
          kd_ign "$kd_i" '불활성' "절단점이 배포가 아니면 적용이 없습니다 (절단점: $kd_c)"
        elif [ "$KD_DEPLOY_N" -gt 1 ]; then
          kd_ign "$kd_i" '배포 대상 수' '절단점이 배포인 대상이 둘 이상이라 적용 필드를 채울 자리가 하나뿐입니다'
        elif [ "$KD_AA_GIVEN" = "1" ] && [ "$KD_AA" = "없음" ]; then
          kd_ign "$kd_i" '인터뷰 답과 다름' '요구사항 인터뷰가 적용이 없다고 답했습니다'
        elif [ "${E_KEY[kd_i]}" = "apply-actor" ] && [ "$KD_AA_GIVEN" = "1" ] && [ "$KD_AA" != "${E_RAW[kd_i]}" ]; then
          kd_ign "$kd_i" '인터뷰 답과 다름' "요구사항 인터뷰의 적용 주체는 $KD_AA 입니다"
        fi
        if [ "${E_ST[kd_i]}" = "ok" ] && [ "${E_KEY[kd_i]}" = "apply-actor" ] && [ "${E_RAW[kd_i]}" = "파이프라인" ]; then
          KD_PIPE_APPLY=1
        fi ;;
    esac
  fi
  kd_i=$((kd_i + 1))
done

kd_i=0
while [ "$kd_i" -lt "$KD_N" ]; do
  if [ "${E_ST[kd_i]}" = "ok" ]; then
    case "${E_SCOPE[kd_i]}" in run) kd_c='' ;; *) kd_c="${T_CUT[${E_SCOPE[kd_i]}]}" ;; esac
    case "${E_KEY[kd_i]}" in
      review-ceiling)
        if [ -z "$kd_c" ]; then
          kd_ign "$kd_i" '절단점 미정' '이 레포의 절단점이 기본값으로 정해질 때만 판정합니다'
        elif [ "$(kd_cut_i "$kd_c")" -lt "$KD_I_MERGE" ]; then
          kd_ign "$kd_i" '불활성' "절단점이 머지 미만이라 묶을 머지가 없습니다 (절단점: $kd_c)"
        elif [ "${E_RAW[kd_i]}" = "리뷰없음" ] && [ "$KD_PIPE_APPLY" = "1" ]; then
          kd_ign "$kd_i" '충돌' '적용 주체가 파이프라인인 런에서 리뷰없음은 매니페스트 검사가 멈추는 조합입니다'
        fi ;;
      terminal-cap)
        [ -n "$kd_c" ] || kd_ign "$kd_i" '절단점 미정' '이 레포의 절단점이 기본값으로 정해질 때만 판정합니다' ;;
      deploy-triggers)
        case ",${E_NORM[kd_i]}" in
          *,branch:*)
            if [ -z "$kd_c" ]; then
              kd_ign "$kd_i" '절단점 미정' 'branch 원소는 이 레포의 절단점이 기본값으로 정해질 때만 판정합니다'
            elif [ "$(kd_cut_i "$kd_c")" -lt "$KD_I_PUSH" ]; then
              kd_ign "$kd_i" '불활성' "절단점이 push 미만이라 branch 트리거가 불활성입니다 (절단점: $kd_c)"
            fi ;;
        esac ;;
    esac
  fi
  kd_i=$((kd_i + 1))
done

# A pre-authorization row reaches every target of the run, because the matcher
# does not look at the target. With two or more targets only a `형태` written in
# every target's section is applied; the rest are offered again at 5p.
kd_i=0
while [ "$kd_i" -lt "$KD_N" ]; do
  if [ "$KD_NT" -gt 1 ] && [ "${E_ST[kd_i]}" = "ok" ] && [ "${E_KEY[kd_i]}" = "act-allow" ]; then
    kd_all=1; kd_diff=0; kd_t=0
    while [ "$kd_t" -lt "$KD_NT" ]; do
      kd_found=0; kd_j=0
      while [ "$kd_j" -lt "$KD_N" ]; do
        if [ "${E_ST[kd_j]}" = "ok" ] && [ "${E_KEY[kd_j]}" = "act-allow" ] \
           && [ "${E_SCOPE[kd_j]}" = "$kd_t" ] && [ "${E_ID[kd_j]}" = "${E_ID[kd_i]}" ]; then
          kd_found=1
          [ "${E_X[kd_j]}" = "${E_X[kd_i]}" ] || kd_diff=1
          break
        fi
        kd_j=$((kd_j + 1))
      done
      [ "$kd_found" = "1" ] || kd_all=0
      kd_t=$((kd_t + 1))
    done
    E_ALL[kd_i]=$kd_all; E_DIFF[kd_i]=$kd_diff
  fi
  kd_i=$((kd_i + 1))
done
kd_i=0
while [ "$kd_i" -lt "$KD_N" ]; do
  if [ "$KD_NT" -gt 1 ] && [ "${E_ST[kd_i]}" = "ok" ] && [ "${E_KEY[kd_i]}" = "act-allow" ]; then
    if [ "${E_ALL[kd_i]}" != "1" ]; then
      kd_ign "$kd_i" '일부 대상만' '이 런의 일부 대상에만 있는 형태입니다 — 5p 에서 「이 런의 모든 대상에 적용」 과 함께 다시 묻습니다'
    elif [ "${E_SCOPE[kd_i]}" != "0" ]; then
      # Folded into the first target's row: the manifest carries one row.
      E_ST[kd_i]='hide'
    fi
  fi
  kd_i=$((kd_i + 1))
done

# ---------------------------------------------------------------------------
# Effect lines and the `[권한 확대]` mark — a fixed table, not prose a model writes.
# ---------------------------------------------------------------------------
kd_effect() {   # kd_effect <index>; sets KD_WIDE and KD_EFF
  local i="$1" k="${E_KEY[$1]}" v="${E_NORM[$1]}" c ci
  KD_WIDE=0; KD_EFF=''
  case "${E_SCOPE[$i]}" in run) c='' ;; *) c="${T_CUT[${E_SCOPE[$i]}]}" ;; esac
  case "$k" in
    ladder-rungs)
      if [ "$v" = "4" ]; then KD_EFF='국소 수정·범위 재수렴·근본 재설계까지 스스로 내려간 뒤 사람에게 옵니다'
      else KD_EFF='범위 재수렴 뒤에 멈춥니다 — 스스로 재설계하지 않는 대신 아침에 park 가 늘어납니다'; fi ;;
    stagnation-bound)
      if [ "$v" = "없음" ]; then KD_EFF='무진전 상한이 없습니다 — 비용 천장도 없으면 벽시계 마감이 유일한 경계입니다'
      else KD_EFF="진행이 멈춘 라우터 판정이 연속 $v 번에 이르면 묻지 않고 런을 끝냅니다"; fi ;;
    cost-ceiling)
      if [ "$v" = "없음" ]; then KD_EFF='비용 축에 한도가 없습니다'
      else KD_EFF="$(awk -v x="$v" 'BEGIN { printf "%g", x * 0.8 }') USD 에서 승인을 열고 기다리며, $v USD 에서 묻지 않고 런을 끝냅니다"; fi ;;
    deadline)
      if [ "${E_X[$i]}" = "상대" ]; then
        KD_EFF="${E_RAW[$i]} → $v — 이 시각 뒤로 디스패치·머지가 없습니다(킥오프 시각 기준으로 풀었습니다)"
      else
        KD_EFF="이 시각 뒤로 디스패치·머지가 없습니다"
      fi ;;
    roster-model)
      KD_EFF="기본 로스터의 모델 칸만 $v 로 바꿔 제안합니다 — 로스터 승인은 그대로 묻습니다" ;;
    roster-model.*)
      KD_EFF="기본 로스터 ${k#roster-model.} 행의 모델 칸만 $v 로 바꿔 제안합니다 — 로스터 승인은 그대로 묻습니다" ;;
    auto-adopt)
      KD_WIDE=1
      # The gate matches an adoption row on its class alone; the two cap fields
      # are frozen into the manifest and read by nothing, so the line says so
      # instead of presenting them as a limit.
      KD_EFF="${E_ID[$i]} 부류의 판단을 개수·심각도 제한 없이 사람 없이 채택합니다 — ${E_X[$i]} 는 매니페스트에 기록만 되고 게이트가 집행하지 않습니다" ;;
    cutpoint)
      ci=$(kd_cut_i "$v")
      [ "$ci" -ge "$KD_I_PUSH" ] && KD_WIDE=1
      if [ "$ci" -ge "$KD_I_MERGE" ]; then
        KD_EFF="${v}까지 스스로 합니다 — 머지에 --admin 예외가 없고, 비필수 체크 실패는 park 합니다"
      else
        KD_EFF="${v}까지 스스로 하고, 그 위의 첫 행위는 묻지 않고 보류 큐로 보냅니다"
      fi ;;
    review-ceiling)
      case "$v" in 선머지후리뷰|리뷰없음) KD_WIDE=1 ;; esac
      KD_EFF='슬라이스는 이 값 이하로만 리뷰 정책을 선언합니다'
      [ "$v" = "선머지후리뷰" ] && KD_EFF="$KD_EFF — 첫 머지가 의무 하나를 남기고, 그 의무가 풀리기 전 같은 세그먼트의 두 번째 머지는 거부됩니다" ;;
    terminal-cap)
      if [ "$v" = "없음" ]; then
        if [ -n "$c" ] && [ "$(kd_cut_i "$c")" -ge "$KD_I_MERGE" ]; then KD_WIDE=1; fi
        KD_EFF='말단 행위 수에 상한이 없습니다'
      else
        KD_EFF="말단 행위 $v 건을 넘는 몫은 보류 큐로 갑니다"
      fi ;;
    dev-ids)
      if [ "$v" = "없음" ]; then KD_EFF='dev 식별자를 선언하지 않습니다 — 스테이지의 dev 주장을 대조 없이 믿고 기록합니다'
      else KD_EFF='스테이지의 dev 주장을 이 식별자와 argv 로 대조하고, 어긋나거나 대조할 것이 없으면 park 합니다'; fi ;;
    deploy-triggers)
      if [ "$v" = "없음" ]; then KD_EFF='배포 트리거를 선언하지 않습니다'
      else KD_EFF='이 트리거에 닿는 행위는 사전 인가 행이 없으면 park 합니다'; fi ;;
    act-allow)
      KD_WIDE=1
      KD_EFF='이 접두의 행위를 승인 없이 수행합니다(이 런의 모든 대상에 적용)'
      kd_is_runner_form "${E_ID[$i]}" && KD_EFF="$KD_EFF. 러너 형태 — 이 접두로 시작하는 비파괴 행위 전부(접두 일치)"
      [ "${E_DIFF[$i]:-0}" = "1" ] && KD_EFF="$KD_EFF. 사유가 대상마다 다릅니다 — 첫 대상(${KD_TARGET[0]})의 사유를 씁니다" ;;
    apply-probe)
      KD_EFF='5c 에 적용 프로브로 미리 채우는 제안입니다 — 적용 명령과 파급 범위는 새로 묻습니다' ;;
    apply-actor)
      [ "$v" = "파이프라인" ] && KD_WIDE=1
      KD_EFF='5c 에 적용 주체로 미리 채우는 제안입니다 — 적용 명령과 파급 범위는 새로 묻습니다'
      [ "$v" = "파이프라인" ] && KD_EFF="$KD_EFF. 드라이버가 적용을 재시도 없이 스스로 실행합니다" ;;
  esac
}

# ---------------------------------------------------------------------------
# `--carry` output. The previous run's values are added as entries past the
# file's, so their `[권한 확대]` mark comes from the same `kd_effect` table the
# file's values meet.
# ---------------------------------------------------------------------------
if [ "$KD_CARRY_GIVEN" = "1" ]; then
  KD_FILE_N=$KD_N
  kd_label() { case "$1" in run) printf '런' ;; *) printf '%s' "${KD_TARGET[$1]}" ;; esac; }
  # kd_file_ok <scope> <key> — the file's applied entry for the key, or nothing.
  # `any` matches every scope.
  kd_file_ok() {
    local j=0
    while [ "$j" -lt "$KD_FILE_N" ]; do
      if [ "${E_ST[j]}" = "ok" ] && [ "${E_KEY[j]}" = "$2" ] \
         && { [ "$1" = "any" ] || [ "${E_SCOPE[j]}" = "$1" ]; }; then
        printf '%s' "$j"; return 0
      fi
      j=$((j + 1))
    done
    return 1
  }
  # kd_file_ign <scope> <key> — the file's ignored entry for the key, or nothing.
  kd_file_ign() {
    local j=0
    while [ "$j" -lt "$KD_FILE_N" ]; do
      if [ "${E_ST[j]}" = "ign" ] && [ "${E_KEY[j]}" = "$2" ] && [ "${E_SCOPE[j]}" = "$1" ]; then
        printf '%s' "$j"; return 0
      fi
      j=$((j + 1))
    done
    return 1
  }
  kd_carry_effect() {   # kd_carry_effect <index> — kd_effect, with the two apply keys read as answers
    case "${E_KEY[$1]}" in
      apply-actor)
        KD_WIDE=0
        case "${E_NORM[$1]}" in
          파이프라인) KD_WIDE=1; KD_EFF='드라이버가 적용을 재시도 없이 스스로 실행합니다' ;;
          사람) KD_EFF='적용은 사람이 합니다' ;;
          *) KD_EFF='적용이 없습니다' ;;
        esac ;;
      apply-probe) KD_WIDE=0; KD_EFF='이전 런의 적용 프로브를 그대로 씁니다' ;;
      *) kd_effect "$1" ;;
    esac
  }
  kd_out_apply() {   # kd_out_apply <index>
    kd_carry_effect "$1"
    printf '적용\t%s\t%s\t%s\t이전 매니페스트\t%s\t%s\n' "$(kd_cell "$(kd_label "${E_SCOPE[$1]}")")" \
      "${E_KEY[$1]}" "$(kd_cell "${E_NORM[$1]}")" "$KD_WIDE" "$(kd_cell "$KD_EFF")"
  }
  kd_out_auth() {    # kd_out_auth <index> <verbatim value>
    kd_carry_effect "$1"
    printf '권한\t%s\t%s\t%s\t%s\t%s\n' "$(kd_cell "$(kd_label "${E_SCOPE[$1]}")")" \
      "${E_KEY[$1]}" "$(kd_cell "$2")" "$KD_WIDE" "$(kd_cell "$KD_EFF")"
  }
  kd_out_blank() {   # kd_out_blank <file index>
    kd_effect "$1"
    printf '빈칸\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(kd_cell "$(kd_label "${E_SCOPE[$1]}")")" \
      "${E_KEY[$1]}" "$(kd_cell "${E_NORM[$1]}")" "${E_SRC[$1]}" "$KD_WIDE" "$(kd_cell "$KD_EFF")"
  }
  kd_out_diff() {    # kd_out_diff <scope> <key> <previous> <file value> <file source>
    printf '차이\t%s\t%s\t%s\t%s\t%s\n' "$(kd_cell "$(kd_label "$1")")" "$2" \
      "$(kd_cell "$3")" "$(kd_cell "$4")" "$5"
  }
  kd_out_not() {     # kd_out_not <scope> <key> <token> <text>
    printf '이어받지 않음\t%s\t%s\t%s\t%s\n' "$(kd_cell "$(kd_label "$1")")" "$2" "$3" "$(kd_cell "$4")"
  }
  # kd_carry_absent <scope> <key> — the previous manifest holds no value: the
  # file fills it (`빈칸`), or the key is named as not carried.
  kd_carry_absent() {
    local xi
    if xi=$(kd_file_ok "$1" "$2"); then
      kd_out_blank "$xi"
    elif xi=$(kd_file_ign "$1" "$2"); then
      kd_out_not "$1" "$2" "${E_RT[xi]}" "이전 매니페스트에 값이 없고 기본값 파일의 값은 쓰지 않습니다 — ${E_RM[xi]}"
    else
      kd_out_not "$1" "$2" '원천 없음' '이전 매니페스트에 값이 없고 기본값 파일도 채우지 않습니다'
    fi
  }
  # kd_carry_scalar <scope> <key> <previous value> [auth] — one scalar value.
  kd_carry_scalar() {
    local sc="$1" k="$2" pv="$3" auth="${4:-}" ci xi xs="$1"
    if [ -z "$pv" ]; then kd_carry_absent "$sc" "$k"; return; fi
    kd_add "$sc" "$k" "$pv" '이전 매니페스트'
    ci=$KD_I
    case "$k" in apply-probe|apply-actor) ;; *) kd_validate "$ci" ;; esac
    if [ "${E_ST[ci]}" = "ign" ]; then
      kd_out_not "$sc" "$k" "${E_RT[ci]}" "이전 값 '$pv' 를 지금 어휘로 읽지 못해 이어받지 않습니다 — ${E_RM[ci]}"
      return
    fi
    kd_out_apply "$ci"
    [ -n "$auth" ] && kd_out_auth "$ci" "$pv"
    # The two apply keys sit in each repository's section of the file and in
    # one run-wide field of the manifest, so any section's value compares.
    case "$k" in apply-probe|apply-actor) xs=any ;; esac
    if xi=$(kd_file_ok "$xs" "$k"); then
      [ "${E_NORM[xi]}" = "${E_NORM[ci]}" ] || kd_out_diff "$sc" "$k" "${E_NORM[ci]}" "${E_NORM[xi]}" "${E_SRC[xi]}"
    fi
  }
  # kd_file_ids <key> — the file's applied list identities, sorted, `,`-joined.
  kd_file_ids() {
    local j=0
    while [ "$j" -lt "$KD_FILE_N" ]; do
      [ "${E_ST[j]}" = "ok" ] && [ "${E_KEY[j]}" = "$1" ] && printf '%s\n' "${E_ID[j]}"
      j=$((j + 1))
    done | sort -u | paste -sd, -
  }

  printf 'cc-kickoff-defaults v1\n'
  printf '원천\t%s\t%s\t%s\n' "$(kd_cell "$KD_SRC")" "$KD_SHA" "$KD_ENVN"

  for kd_k in ladder-rungs stagnation-bound cost-ceiling; do
    kd_f=$(kd_carry_field "$kd_k")
    kd_carry_scalar run "$kd_k" "$(manifest_field '인가' "${kd_f#*	}")"
  done
  kd_out_not run deadline '간격으로 이어받음' '벽시계 마감은 값이 아니라 이전 런의 간격으로 다시 잡습니다 — 마감 행이 새 값입니다'
  for kd_k in roster-model 'roster-model.<역할>'; do
    kd_out_not run "$kd_k" '로스터 행' '설계 로스터 행은 행 그대로 이어받습니다 — 모델 칸 기본값은 쓰지 않습니다'
  done

  # The list keys. A `## 인가` section holding zero rows of the kind is the
  # answer "none", not an empty value: that is how a run whose person answered
  # 「없음」 reads, because the row grammar has no "none" row.
  kd_has_auth=0
  grep -qx '## 인가' "$MANIFEST" 2>/dev/null && kd_has_auth=1
  for kd_k in auto-adopt act-allow; do
    if [ "$kd_k" = "auto-adopt" ]; then
      kd_rows=$(manifest_autoadopt_rows_anywhere)
    else
      kd_rows=$(manifest_preauth_rows | while IFS= read -r kd_r; do
        [ -n "$(manifest_row_fields "$kd_r" '형태')" ] && printf '%s\n' "$kd_r"
      done)
    fi
    kd_n=$(printf '%s' "$kd_rows" | grep -c . || true)
    if [ "$kd_has_auth" = "0" ] && [ "${kd_n:-0}" -eq 0 ]; then
      kd_j=0; kd_any=0
      while [ "$kd_j" -lt "$KD_FILE_N" ]; do
        if [ "${E_ST[kd_j]}" = "ok" ] && [ "${E_KEY[kd_j]}" = "$kd_k" ]; then kd_out_blank "$kd_j"; kd_any=1; fi
        kd_j=$((kd_j + 1))
      done
      [ "$kd_any" = "1" ] || kd_out_not run "$kd_k" '원천 없음' '이전 매니페스트에 인가 절이 없고 기본값 파일도 채우지 않습니다'
      continue
    fi
    kd_prev_ids=''
    kd_auth_lines=''
    while IFS= read -r kd_r; do
      [ -n "$kd_r" ] || continue
      kd_add run "$kd_k" "$kd_r" '이전 매니페스트'
      kd_ci=$KD_I
      if [ "$kd_k" = "auto-adopt" ]; then
        kd_cls=$(manifest_row_fields "$kd_r" '판단 부류')
        E_ID[kd_ci]="$kd_cls"
        E_X[kd_ci]="상한=$(manifest_row_fields "$kd_r" '상한') · 심각도 상한=$(manifest_row_fields "$kd_r" '심각도 상한')"
        if ! kd_in "$kd_cls" "$JUDGMENT_CLASSES" || kd_in "$kd_cls" "$JUDGMENT_CLASSES_FORBIDDEN"; then
          kd_out_not run "$kd_k" '금지 부류' "이전 행 '$kd_r' 의 부류는 지금 게이트가 스스로 채택하지 않는 부류입니다 — 이어받지 않고 묻습니다"
          continue
        fi
      else
        E_ID[kd_ci]=$(manifest_row_fields "$kd_r" '형태')
        E_X[kd_ci]=$(manifest_row_fields "$kd_r" '사유')
      fi
      E_DIFF[kd_ci]=0
      kd_prev_ids="$kd_prev_ids${E_ID[kd_ci]}
"
      kd_auth_lines="$kd_auth_lines$kd_ci
"
    done <<EOF
$kd_rows
EOF
    kd_prev_sum=$(printf '%s' "$kd_prev_ids" | grep . | sort -u | paste -sd, -)
    [ -n "$kd_prev_sum" ] || kd_prev_sum='없음'
    kd_fsum=$(kd_file_ids "$kd_k")
    if [ "$kd_prev_sum" = "없음" ]; then
      kd_eff='이전 런은 이 권한을 없음으로 답했습니다'
      kd_w=0
    else
      kd_eff='이전 런의 행을 그대로 이어받습니다 — 행마다 권한 행이 있습니다'
      kd_w=1
    fi
    printf '적용\t런\t%s\t%s\t이전 매니페스트\t%s\t%s\n' "$kd_k" "$(kd_cell "$kd_prev_sum")" "$kd_w" "$kd_eff"
    while IFS= read -r kd_ci; do
      [ -n "$kd_ci" ] || continue
      kd_out_auth "$kd_ci" "${E_RAW[kd_ci]}"
    done <<EOF
$kd_auth_lines
EOF
    if [ -n "$kd_fsum" ] && [ "$kd_fsum" != "$kd_prev_sum" ]; then
      kd_fi=$(kd_file_ok any "$kd_k")
      kd_out_diff run "$kd_k" "$kd_prev_sum" "$kd_fsum" "${E_SRC[kd_fi]}"
    fi
  done

  kd_t=0
  while [ "$kd_t" -lt "$KD_NT" ]; do
    kd_al="${KD_TALIAS[kd_t]}"
    kd_carry_scalar "$kd_t" cutpoint "$(target_field "$kd_al" '절단점')" auth
    kd_carry_scalar "$kd_t" review-ceiling "$(target_field "$kd_al" '리뷰 정책 상한')" auth
    kd_carry_scalar "$kd_t" terminal-cap "$(target_field "$kd_al" '말단 행위 상한')" auth
    kd_carry_scalar "$kd_t" dev-ids "$(target_field "$kd_al" 'dev 식별자')"
    kd_carry_scalar "$kd_t" deploy-triggers "$(target_field "$kd_al" '배포트리거 식별자')"
    kd_t=$((kd_t + 1))
  done
  kd_carry_scalar run apply-probe "$(manifest_field '요소' '적용 프로브')"
  kd_carry_scalar run apply-actor "$(manifest_field '요소' '적용 주체')" auth

  # The deadline: the previous interval, started again from this kickoff.
  kd_pd=$(manifest_field '인가' '벽시계 마감')
  kd_pk=$(manifest_field '런 정체' '킥오프 일시')
  kd_dl=''
  if [ -z "$kd_pd" ]; then
    kd_dl="빈 값	이전 매니페스트에 벽시계 마감이 없습니다"
  elif [ "$kd_pd" = "없음" ]; then
    kd_dl="마감 없음	이전 런에 벽시계 마감이 없었습니다"
  else
    kd_pde=$(kd_wide_instant "$kd_pd")
    if [ -z "$kd_pde" ]; then
      if printf '%s\n' "$kd_pd" | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}$' >/dev/null; then
        kd_dl="영역 없음	이전 마감 $kd_pd 에 시간대가 없어 순간으로 읽지 못합니다"
      elif printf '%s\n' "$kd_pd" | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(Z|[+-][0-9]{2}:?[0-9]{2})$' >/dev/null; then
        kd_dl="범위 밖	이전 마감 $kd_pd 의 날짜·시각이나 오프셋이 범위 밖입니다 — 오프셋은 ±14:00 까지입니다"
      else
        kd_dl="형식 오류	이전 마감 $kd_pd 를 시각으로 읽지 못했습니다"
      fi
    fi
  fi
  if [ -z "$kd_dl" ]; then
    kd_pke=$(kd_wide_instant "$kd_pk")
    if [ -z "$kd_pke" ]; then
      kd_dl="킥오프 일시 불명	이전 킥오프 일시 '$kd_pk' 를 시각으로 읽지 못해 간격을 잴 수 없습니다"
    else
      kd_iv=$((kd_pde - kd_pke))
      kd_ne=$((KD_KAT_E + kd_iv))
      if [ "$kd_iv" -le 0 ]; then
        kd_dl="간격 없음	이전 마감이 이전 킥오프 일시보다 뒤가 아닙니다 (간격 ${kd_iv}초)"
      elif [ "$kd_ne" -le "$KD_NOW" ]; then
        kd_dl="과거 시각	다시 잡은 마감이 지금 이후가 아닙니다"
      else
        kd_abs=$(jq -nr --argjson e "$kd_ne" --argjson now "$KD_NOW" "$KD_JQ_TIME"' render($e)' 2>/dev/null) || kd_abs=''
        if [ -n "$kd_abs" ] && [ "$(deadline_instant "$kd_abs")" = "$kd_ne" ]; then
          kd_dl="ok	${kd_abs}	${kd_iv}"
        else
          kd_dl="형식 오류	다시 잡은 마감을 이 호스트의 ±HH:MM 표기로 쓰지 못했습니다"
        fi
      fi
    fi
  fi
  printf '마감\t%s\n' "$(printf '%s' "$kd_dl" | LC_ALL=C tr '\001-\010\012-\037\177' ' ')"
  exit 0
fi

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
printf 'cc-kickoff-defaults v1\n'
printf '원천\t%s\t%s\t%s\n' "$(kd_cell "$KD_SRC")" "$KD_SHA" "$KD_ENVN"
kd_i=0
while [ "$kd_i" -lt "$KD_N" ]; do
  case "${E_SCOPE[kd_i]}" in
    run|bad) kd_scope='런' ;;
    other) kd_scope='' ;;
    *) kd_scope="${KD_TARGET[${E_SCOPE[kd_i]}]}" ;;
  esac
  if [ "${E_SCOPE[kd_i]}" = "bad" ]; then kd_scope='런'; fi
  case "${E_ST[kd_i]}" in
    ok)
      kd_effect "$kd_i"
      printf '적용\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(kd_cell "$kd_scope")" "$(kd_cell "${E_KEY[kd_i]}")" \
        "$(kd_cell "${E_NORM[kd_i]}")" "${E_SRC[kd_i]}" "$KD_WIDE" "$(kd_cell "$KD_EFF")" ;;
    ign)
      printf '무시\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(kd_cell "$kd_scope")" "$(kd_cell "${E_KEY[kd_i]}")" \
        "$(kd_cell "${E_RAW[kd_i]}")" "${E_SRC[kd_i]}" "${E_RT[kd_i]}" "$(kd_cell "${E_RM[kd_i]}")" ;;
  esac
  kd_i=$((kd_i + 1))
done
exit 0
