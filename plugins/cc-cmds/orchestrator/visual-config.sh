#!/usr/bin/env bash
# Host settings of the visual design skills: the pinned Claude Design account,
# the per-phase model table, and the ban list the reviewers and the machine
# check read.
#
# Three host files live in the host settings directory, all mode 644 and none
# named `*.env`:
#
#   claude-design   `account = <address>` and `lane = <lane id>` — written by a
#                   person, never seeded, never copied into a run
#   visual-models   `key = value` lines overriding the skill defaults
#   visual-bans     `<id> | <kind> | <description> | <pattern or ->` lines,
#                   seeded from visual-bans.seed beside this script
#
# The directory is `${XDG_CONFIG_HOME:-$HOME/.config}/cc-cmds` and nothing else:
# there is deliberately no environment variable that points this script at a
# different file, because a path a run could re-point is the very risk the
# account pin exists to close. Tests move XDG_CONFIG_HOME instead.
#
# Subcommands:
#   account            read `command claude auth status --json` in THIS
#                      process's own config directory, compare its `email`
#                      with `account` in claude-design, append one line to the
#                      host log, print the verdict. 일치 exits 0; 불일치, 미설정
#                      and 판독실패 exit 1. Refused inside a run, except in the
#                      visual publish stage (below).
#   lane               print the `lane` value of claude-design — the lane id
#                      the gate pins a visual publish stage to. No value (no
#                      file, no line, an empty value) prints nothing and exits
#                      1. Read-only, and allowed inside a run.
#   models            print the resolved model table, `<key> = <value> |
#                      <기본값|호스트 설정>`, one line per key in a fixed order.
#                      An unknown key or a value outside the vocabulary keeps
#                      that key at its default and is reported on stderr.
#   bans               print the host ban list verbatim; when the host file is
#                      absent print the plugin seed instead, read-only, under
#                      the header line `# 호스트 파일 없음 — 씨앗 사용`.
#                      Writes nothing.
#   seed               copy the plugin seed to the host file only when the host
#                      file is absent (file 644, a new directory 700). Refused
#                      inside a run.
#   append <line>      append one approved ban line after checking its form.
#                      Takes the ban line itself or a sidecar candidate line
#                      (`- \`<id>\` | ... — <n>회 <screen id>`). Refused inside
#                      a run, except in the visual publish stage (below).
#   snapshot [--part models|bans]
#                      the unattended copy: find the run's interview record by
#                      path convention, check it against the manifest's
#                      `사전 인가` row (same file AND same sha256), then print
#                      the model and ban sub-blocks of its `## 시각 방향`. Any
#                      mismatch exits 1 with the reason.
#
# Inside a run, `account` and `append` run only when the gate launched this
# process as a visual publish stage, which it marks with
# `CC_PIPELINE_VISUAL_PUBLISH=1` and sets for that kind alone. The gate grades
# both of them per act besides (`append` only against a person's approval of
# that very candidate). `seed` is refused inside every run, that stage included.
#
# The log `${XDG_STATE_HOME:-$HOME/.local/state}/cc-cmds/claude-design-account.log`
# gets one line per account read: time, verdict, the local part read and the
# local part expected. Never the domain, and nothing reads it for control.
#
# Exit codes:
#   0 — success (account: 일치)
#   1 — a verdict other than 일치, a refused append, a snapshot mismatch
#   2 — usage error, or a subcommand refused because it runs inside a run
#
# Compatibility: bash 3.2 (macOS) — no associative arrays, no `mapfile`; BSD
# and GNU userland alike; `grep -E` only.

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd -P)
SEED="$script_dir/visual-bans.seed"
CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/cc-cmds"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/cc-cmds"
ACCOUNT_FILE="$CONF_DIR/claude-design"
MODELS_FILE="$CONF_DIR/visual-models"
BANS_FILE="$CONF_DIR/visual-bans"
ACCOUNT_LOG="$STATE_DIR/claude-design-account.log"

MODEL_KEYS='ds-generate screen-generate polish implement-large implement-large-threshold'
MODEL_VOCAB='opus sonnet haiku fable'

usage() {
  echo "사용법: visual-config.sh account | lane | models | bans | seed | append <줄> | snapshot [--part models|bans]" >&2
  exit 2
}

refuse_in_run() {
  if [ -n "${CC_PIPELINE_RUN_ID:-}" ]; then
    echo "visual-config.sh $1: 런 안에서는 거절한다 — 사람 좌석에서만 돈다 (CC_PIPELINE_RUN_ID 가 있다)" >&2
    exit 2
  fi
}

refuse_in_run_unless_publish() {
  # The visual publish stage's marker lifts the refusal for `account` and
  # `append` alone; every other caller inside a run is refused as before.
  [ "${CC_PIPELINE_VISUAL_PUBLISH:-}" = "1" ] && return 0
  refuse_in_run "$1"
}

trim() {
  printf '%s' "$1" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

sha256_of() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

local_part() {
  case "$1" in
    '') printf '%s' '-' ;;
    *@*) printf '%s' "${1%%@*}" ;;
    *) printf '%s' "$1" ;;
  esac
}

model_default() {
  case "$1" in
    ds-generate) echo fable ;;
    screen-generate) echo opus ;;
    polish) echo fable ;;
    implement-large) echo fable ;;
    implement-large-threshold) echo 300 ;;
  esac
}

model_value_ok() {
  local key=$1 val=$2 v
  if [ "$key" = implement-large-threshold ]; then
    printf '%s' "$val" | grep -qE '^[1-9][0-9]*$'
    return
  fi
  for v in $MODEL_VOCAB; do
    [ "$v" = "$val" ] && return 0
  done
  return 1
}

is_model_key() {
  local k
  for k in $MODEL_KEYS; do
    [ "$k" = "$1" ] && return 0
  done
  return 1
}

# --- account ------------------------------------------------------------------
cmd_account() {
  refuse_in_run_unless_publish account
  local expected='' read_email='' verdict out rc line
  if [ -f "$ACCOUNT_FILE" ]; then
    line=$(grep -E '^[[:space:]]*account[[:space:]]*=' "$ACCOUNT_FILE" | tail -n 1 || true)
    if [ -n "$line" ]; then
      expected=$(trim "${line#*=}")
    fi
  fi

  rc=0
  out=$(command claude auth status --json 2>/dev/null) || rc=$?
  if [ "$rc" = 0 ]; then
    local body
    body=$(printf '%s' "$out" | tr -d '\n' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    case "$body" in
      '{'*'}')
        read_email=$(printf '%s' "$body" \
          | grep -oE '"email"[[:space:]]*:[[:space:]]*"[^"]*"' | head -n 1 \
          | sed -E 's/^"email"[[:space:]]*:[[:space:]]*"([^"]*)"$/\1/' || true)
        ;;
    esac
  fi

  if [ -z "$expected" ]; then
    verdict=미설정
  elif [ -z "$read_email" ]; then
    verdict=판독실패
  elif [ "$(printf '%s' "$read_email" | tr '[:upper:]' '[:lower:]')" = "$(printf '%s' "$expected" | tr '[:upper:]' '[:lower:]')" ]; then
    verdict=일치
  else
    verdict=불일치
  fi

  local lr le
  lr=$(local_part "$read_email")
  le=$(local_part "$expected")
  mkdir -p "$STATE_DIR"
  printf '%s %s 판독=%s 기대=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$verdict" "$lr" "$le" >> "$ACCOUNT_LOG"

  echo "계정 판정: ${verdict} (판독 ${lr}, 기대 ${le})"
  if [ "$verdict" != 일치 ]; then
    case "$verdict" in
      미설정) echo "멈춤 — ${ACCOUNT_FILE} 에 'account = <주소>' 줄이 없다" ;;
      판독실패) echo "멈춤 — 'command claude auth status --json' 에서 email 을 읽지 못했다" ;;
      불일치) echo "멈춤 — 이 설정 디렉터리의 로그인 계정이 고정 계정이 아니다" ;;
    esac
    echo "로그: ${ACCOUNT_LOG}"
    echo "고칠 길: 고정 계정으로 로그인한 좌석에서 같은 국면을 다시 실행한다"
    exit 1
  fi
}

# --- lane ---------------------------------------------------------------------
cmd_lane() {
  local line val=''
  if [ -f "$ACCOUNT_FILE" ]; then
    line=$(grep -E '^[[:space:]]*lane[[:space:]]*=' "$ACCOUNT_FILE" | tail -n 1 || true)
    [ -z "$line" ] || val=$(trim "${line#*=}")
  fi
  [ -n "$val" ] || exit 1
  printf '%s\n' "$val"
}

# --- models -------------------------------------------------------------------
cmd_models() {
  local key val src line k v found
  for key in $MODEL_KEYS; do
    val=$(model_default "$key")
    src=기본값
    if [ -f "$MODELS_FILE" ]; then
      found=''
      while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in ''|'#'*) continue ;; esac
        case "$line" in *=*) ;; *) continue ;; esac
        k=$(trim "${line%%=*}")
        v=$(trim "${line#*=}")
        [ "$k" = "$key" ] && found=$v
      done < "$MODELS_FILE"
      if [ -n "$found" ]; then
        if model_value_ok "$key" "$found"; then
          val=$found
          src='호스트 설정'
        else
          echo "보고: ${key} 의 값 '${found}' 는 어휘 밖이다 — 기본값 ${val} 을 쓴다" >&2
        fi
      fi
    fi
    printf '%s = %s | %s\n' "$key" "$val" "$src"
  done
  if [ -f "$MODELS_FILE" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in ''|'#'*) continue ;; esac
      case "$line" in
        *=*)
          k=$(trim "${line%%=*}")
          is_model_key "$k" || echo "보고: 모르는 키 '${k}' — 무시한다" >&2
          ;;
        *) echo "보고: 'key = value' 꼴이 아닌 줄 '$(trim "$line")' — 무시한다" >&2 ;;
      esac
    done < "$MODELS_FILE"
  fi
}

# --- bans ---------------------------------------------------------------------
cmd_bans() {
  if [ -f "$BANS_FILE" ]; then
    echo "# 출처: 호스트 파일"
    cat "$BANS_FILE"
  else
    [ -f "$SEED" ] || { echo "visual-config.sh bans: 플러그인 씨앗이 없다: $SEED" >&2; exit 2; }
    echo "# 호스트 파일 없음 — 씨앗 사용"
    cat "$SEED"
  fi
}

# --- seed ---------------------------------------------------------------------
cmd_seed() {
  refuse_in_run seed
  if [ -e "$BANS_FILE" ]; then
    echo "씨앗을 심지 않았다 — 호스트 파일이 이미 있다: ${BANS_FILE}"
    return 0
  fi
  [ -f "$SEED" ] || { echo "visual-config.sh seed: 플러그인 씨앗이 없다: $SEED" >&2; exit 2; }
  if [ ! -d "$CONF_DIR" ]; then
    mkdir -p "$(dirname "$CONF_DIR")"
    mkdir -m 700 "$CONF_DIR"
  fi
  local t
  t=$(mktemp "$CONF_DIR/.visual-bans.XXXXXX")
  cp "$SEED" "$t"
  chmod 644 "$t"
  mv "$t" "$BANS_FILE"
  echo "씨앗을 심었다 — ${BANS_FILE}"
}

# --- append -------------------------------------------------------------------
# A ban line: `<id> | <kind> | <description> | <pattern or ->`. The separator
# is ` | ` and everything after the third one is the pattern.
ban_line_check() {
  local line=$1 id kind desc pat rest
  case "$line" in *' | '*' | '*' | '*) ;; *) echo "구분자 ' | ' 셋이 없다"; return 1 ;; esac
  id=${line%%' | '*}; rest=${line#*' | '}
  kind=${rest%%' | '*}; rest=${rest#*' | '}
  desc=${rest%%' | '*}; pat=${rest#*' | '}
  printf '%s' "$id" | grep -qE '^[a-z0-9][a-z0-9-]*$' || { echo "id '${id}' 가 [a-z0-9-] 꼴이 아니다"; return 1; }
  [ -n "$(trim "$desc")" ] || { echo "설명이 비었다"; return 1; }
  case "$kind" in
    판단) [ "$pat" = - ] || { echo "판단 항목의 패턴은 - 여야 한다"; return 1; } ;;
    마크업|스크립트)
      [ -n "$pat" ] && [ "$pat" != - ] || { echo "${kind} 항목에는 패턴이 있어야 한다"; return 1; }
      local grc=0
      grep -E -- "$pat" </dev/null >/dev/null 2>&1 || grc=$?
      [ "$grc" != 2 ] || { echo "패턴이 grep -E 로 읽히지 않는다"; return 1; }
      ;;
    *) echo "종류 '${kind}' 는 마크업·스크립트·판단 밖이다"; return 1 ;;
  esac
  printf '%s\n' "$id"
}

cmd_append() {
  refuse_in_run_unless_publish append
  [ $# -eq 1 ] || usage
  local line=$1 id why t
  # A sidecar candidate line: - `<id>` | ... — <n>회 <screen id>
  case "$line" in
    '- `'*)
      line=${line#'- `'}
      line=${line/\`/}
      line=$(printf '%s' "$line" | sed -E 's/ — [0-9]+회 [a-z0-9-]+$//')
      ;;
  esac
  if ! why=$(ban_line_check "$line"); then
    echo "덧붙이지 않았다 — ${why}" >&2
    exit 1
  fi
  id=$why
  if [ ! -f "$BANS_FILE" ]; then
    echo "덧붙이지 않았다 — 호스트 파일이 없다 (먼저 visual-config.sh seed)" >&2
    exit 1
  fi
  if grep -qE "^${id} \\| " "$BANS_FILE"; then
    echo "덧붙이지 않았다 — id '${id}' 가 이미 있다" >&2
    exit 1
  fi
  t=$(mktemp "$CONF_DIR/.visual-bans.XXXXXX")
  cat "$BANS_FILE" > "$t"
  if [ -s "$t" ] && [ -n "$(tail -c 1 "$t")" ]; then
    printf '\n' >> "$t"
  fi
  printf '%s\n' "$line" >> "$t"
  chmod 644 "$t"
  mv "$t" "$BANS_FILE"
  echo "덧붙였다 — ${id}"
}

# --- snapshot -----------------------------------------------------------------
mismatch() {
  echo "시각 설정 사본 불일치 — $1"
  exit 1
}

phys_path() {
  local d
  d=$(cd "$(dirname "$1")" 2>/dev/null && pwd -P) || return 1
  printf '%s/%s\n' "$d" "$(basename "$1")"
}

# Print the body of the first fenced block under `### <name>` inside
# `## 시각 방향`. A heading inside a fence is not a heading.
sub_block() {
  awk -v want="### $2" '
    /^```/ { if (infence) { infence = 0; if (grab) { done = 1; exit } ; next }
             infence = 1; if (sub_ok && !grab) { grab = 1; next } ; next }
    infence { if (grab) print; next }
    /^## / { insec = ($0 == "## 시각 방향"); sub_ok = 0; next }
    /^### / { sub_ok = (insec && $0 == want); next }
    END { if (!done) exit 3 }
  ' "$1"
}

cmd_snapshot() {
  local part=''
  while [ $# -gt 0 ]; do
    case "$1" in
      --part) [ $# -ge 2 ] || usage; part=$2; shift 2 ;;
      *) usage ;;
    esac
  done
  case "$part" in ''|models|bans) ;; *) usage ;; esac
  [ -n "${CC_PIPELINE_MANIFEST:-}" ] && [ -n "${CC_PIPELINE_RUN_ID:-}" ] || {
    echo "visual-config.sh snapshot: CC_PIPELINE_MANIFEST 와 CC_PIPELINE_RUN_ID 가 있어야 한다" >&2
    exit 2
  }
  local manifest=$CC_PIPELINE_MANIFEST
  [ -f "$manifest" ] || mismatch "매니페스트가 없다"
  local mdir record
  mdir=$(cd "$(dirname "$manifest")" && pwd -P)
  record="$mdir/${CC_PIPELINE_RUN_ID}.interview.md"
  [ -f "$record" ] || mismatch "경로 관례의 기록이 없다 (${record})"

  local rows n row rel want
  rows=$(grep -E '^- `사전 인가` \| 인터뷰 기록=' "$manifest" || true)
  n=$(printf '%s' "$rows" | grep -c . || true)
  [ "$n" != 0 ] || mismatch "매니페스트에 인터뷰 기록의 사전 인가 행이 없다"
  [ "$n" = 1 ] || mismatch "매니페스트에 인터뷰 기록의 사전 인가 행이 ${n}개다"
  row=$rows
  rel=$(printf '%s' "$row" | sed -E 's/^.*인터뷰 기록=([^|]*[^| ]).*$/\1/')
  want=$(printf '%s' "$row" | sed -nE 's/^.* sha256=([0-9a-f]{64})([[:space:]].*)?$/\1/p')
  [ -n "$want" ] || mismatch "사전 인가 행에 sha256= 값이 없다"

  local base gcd row_path row_phys rec_phys
  gcd=$(cd "$mdir" && git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) \
    || mismatch "매니페스트 자리에서 베이스를 풀 수 없다"
  base=$(dirname "$gcd")
  case "$rel" in
    /*) row_path=$rel ;;
    *) row_path="$base/$rel" ;;
  esac
  row_phys=$(phys_path "$row_path") || mismatch "행의 인터뷰 기록= 이 가리키는 자리가 없다 (${rel})"
  rec_phys=$(phys_path "$record")
  [ "$row_phys" = "$rec_phys" ] \
    || mismatch "행의 인터뷰 기록= 이 경로 관례의 기록과 다른 파일을 가리킨다 (${rel})"
  [ "$(sha256_of "$record")" = "$want" ] || mismatch "기록의 sha256 이 사전 인가 행과 다르다"

  grep -qxF '## 시각 방향' "$record" || mismatch "기록에 ## 시각 방향 절이 없다"
  local models bans
  models=$(sub_block "$record" 모델값) || mismatch "## 시각 방향 에 ### 모델값 하위 블록이 없다"
  bans=$(sub_block "$record" '금지 목록') || mismatch "## 시각 방향 에 ### 금지 목록 하위 블록이 없다"

  case "$part" in
    models) printf '%s\n' "$models" ;;
    bans) printf '%s\n' "$bans" ;;
    *)
      echo "### 모델값"
      printf '%s\n' "$models"
      echo "### 금지 목록"
      printf '%s\n' "$bans"
      ;;
  esac
}

[ $# -ge 1 ] || usage
sub=$1
shift
case "$sub" in
  account) [ $# -eq 0 ] || usage; cmd_account ;;
  lane) [ $# -eq 0 ] || usage; cmd_lane ;;
  models) [ $# -eq 0 ] || usage; cmd_models ;;
  bans) [ $# -eq 0 ] || usage; cmd_bans ;;
  seed) [ $# -eq 0 ] || usage; cmd_seed ;;
  append) cmd_append "$@" ;;
  snapshot) cmd_snapshot "$@" ;;
  *) usage ;;
esac
