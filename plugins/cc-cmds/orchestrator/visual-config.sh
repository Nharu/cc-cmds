#!/usr/bin/env bash
# Host settings of the visual design skills: the Claude Design account each
# design document's canvases belong to, the per-phase model table, and the ban
# list the reviewers and the machine check read.
#
# Three host files live in the host settings directory, all mode 644 and none
# named `*.env`:
#
#   claude-design   `allow = <address>` (zero or more lines), `account =
#                   <address>` and `lane = <lane id>` — written by a person, never seeded, never copied into a run.
#                   The allow list is every `allow` value together with the
#                   last `account` value, compared case-insensitively; a file
#                   with one `account` line alone allows that one account
#   visual-models   `key = value` lines overriding the skill defaults
#   visual-bans     `<id> | <kind> | <description> | <pattern or ->` lines,
#                   seeded from visual-bans.seed beside this script
#
# The directory is `${XDG_CONFIG_HOME:-$HOME/.config}/cc-cmds` and nothing else:
# there is deliberately no environment variable that points this script at a
# different file, because a path a run could re-point is the very risk the
# account pin exists to close. Tests move XDG_CONFIG_HOME instead.
#
# Each design document has one account record,
# `<base>/docs/visual-account/<slug>.md` — `<base>` and `<slug>` derived as the
# sidecar's are. Its head is `<!-- cc-visual-account v1; writer=…; reader=…;
# owner-doc=<document key> -->` and its lines are `**계정**` and `**출처**`
# (`발행 · <UTC ISO>`, `지정 · <UTC ISO>` or `이관 · <run id> · 이관 <s> · <UTC
# ISO>`). Only `record`, `assign` and the gate write it.
#
# The expected account of a document comes from one rule, `doc_expected`, and
# the first row that applies answers:
#   1. the run-local migration record `${CC_PIPELINE_RUN_DIR}/visual-lane`
#      exists → its `**계정**` (기록, 런이관), or 손상 when it does not parse;
#   2. the account record exists → its `**계정**` (기록, 문서기록), or 손상
#      when its head is not v1, its `owner-doc` is not this document, its
#      `**계정**` is empty, or the document-level migration record also parses
#      and names a different account. A 손상 here never falls to row 3;
#   3. the document-level migration record `<base>/docs/visual-lane/<slug>.md`
#      parses as `cc-visual-lane-doc v1` → its `**계정**` (기록, 문서이관);
#      a file that does not parse counts as absent;
#   4. this document's sidecar (same `owner-doc`) holds an `**아티팩트**`
#      value other than `(미발행)` → 미지정: published, no record, no guess;
#   5. otherwise (a new document) → 허용 with the allow list, or 미설정 when
#      the list is empty.
# `account`, `expect` and `record` all read it, so the stage's K0, the gate's
# pre-launch check and the interactive seat cannot expect different accounts.
# A document argument that is not a file or sits outside git is a usage error
# (exit 2) for all four document subcommands, which then write nothing.
#
# Subcommands:
#   account <doc>      read `command claude auth status --json` in THIS
#                      process's own config directory, compare its `email`
#                      with the document's expected account, append one line
#                      to the host log, print the verdict: 일치, 불일치,
#                      미지정, 미설정 or 판독실패 (손상 and an unreadable login).
#                      The first line is `계정 판정: <verdict> (판독 <local
#                      part>, 기대 <local part|허용 목록|->)`, the second
#                      `기준: <런 이관 기록|문서 계정 기록|문서 이관 기록|허용
#                      목록> <path>` when one of those decided. 일치 exits 0,
#                      every other verdict 1. Refused inside a run, except in
#                      the visual publish stage (below).
#   expect <doc>       print the document's expected account kind and value on
#                      one line and exit 0: `기록 <address> <런이관|문서기록|
#                      문서이관>`, `허용 <address> <address>…`, `미지정
#                      <sidecar path>`, `미설정` or `손상 <path>`. Read-only,
#                      and allowed inside a run: the gate calls its own copy
#                      before it launches a visual publish stage in a run with
#                      routing off and compares the login itself. The gate's
#                      grading table has no row for it, so a stage that calls
#                      it is refused there.
#   record <doc>       the first publish's account record, written right after
#                      K2 passes. The value is this process's login, never an
#                      argument. A run-local migration record → nothing
#                      written, exit 0 (the gate writes the record when it
#                      closes a migrating stage). A 문서기록 or 문서이관 record →
#                      exit 0 when the login equals it, else 1. 허용 → written
#                      (`출처: 발행`) only when the login is in the list, else 1.
#                      미지정, 미설정, 손상 and an unreadable login → 1. The
#                      write links a temporary file onto the record name, so it
#                      never replaces an existing record; losing that race
#                      reads the winner and exits 0 only when it equals the
#                      login. Refused inside a run, except in the visual
#                      publish stage (below).
#   assign <doc> <address> [--replace]
#                      a person's assignment (`출처: 지정`). Only an address in
#                      the allow list; an equal existing record writes nothing
#                      and succeeds; a different (or 손상) record is replaced
#                      only with `--replace`; an address other than the
#                      document-level migration record's is refused even with
#                      `--replace`. Refused inside every run.
#   allowed            print the allow list, one address per line; an empty
#                      list exits 1. Read-only, and allowed inside a run.
#   lane             print the lane id the gate pins a visual publish stage
#                      to: the record's `**레인**` when the record exists, else
#                      the `lane` value of claude-design. No value (no file, no
#                      line, an empty value) or a record that does not parse
#                      prints nothing and exits 1. Read-only, and allowed
#                      inside a run.
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
# Inside a run, `account`, `append` and `record` run only when the gate
# launched this process as a visual publish stage, which it marks with
# `CC_PIPELINE_VISUAL_PUBLISH=1` and sets for that kind alone, and only from
# the copy of this script beside that gate (`CC_PIPELINE_GATE`). The gate grades
# all three per act besides (`account` and `record` only on the run's own design
# document, `append` only against a person's approval of that very candidate).
# `seed` and `assign` are refused inside every run, that stage included.
#
# The log `${XDG_STATE_HOME:-$HOME/.local/state}/cc-cmds/claude-design-account.log`
# gets one line per account read: time, verdict, the local part read and the
# local part expected. Never the domain, and nothing reads it for control.
#
# Exit codes:
#   0 — success (account: 일치)
#   1 — a verdict other than 일치, a refused record, assign or append, an empty
#       allow list, a snapshot mismatch
#   2 — usage error (a document argument that does not resolve included), or a
#       subcommand refused because it runs inside a run
#
# Compatibility: bash 3.2 (macOS) — no associative arrays, no `mapfile`; BSD
# and GNU userland alike; `grep -E` only.

set -euo pipefail

script_dir=$(cd -P "$(dirname "$0")" && pwd -P)
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
  echo "사용법: visual-config.sh account <문서> | expect <문서> | record <문서> | assign <문서> <주소> [--replace] | allowed | lane | models | bans | seed | append <줄> | snapshot [--part models|bans]" >&2
  exit 2
}

refuse_in_run() {
  if [ -n "${CC_PIPELINE_RUN_ID:-}" ]; then
    echo "visual-config.sh $1: 런 안에서는 거절한다 — 사람 좌석에서만 돈다 (CC_PIPELINE_RUN_ID 가 있다)" >&2
    exit 2
  fi
}

refuse_in_run_unless_publish() {
  # The visual publish stage's marker lifts the refusal for `account`,
  # `append` and `record` alone, and only for the copy beside the gate the stage was
  # launched with (`CC_PIPELINE_GATE`): that is the copy the gate grades
  # against a person's answer. Any other copy — the run's source checkout, a
  # worktree — would otherwise write the host files on the marker alone, with
  # no gate check behind it. Every other caller inside a run is refused as
  # before.
  if [ "${CC_PIPELINE_VISUAL_PUBLISH:-}" = "1" ] && [ -n "${CC_PIPELINE_GATE:-}" ]; then
    local gate_dir
    gate_dir=$(cd -P "$(dirname "$CC_PIPELINE_GATE")" 2>/dev/null && pwd -P) || gate_dir=''
    [ -n "$gate_dir" ] && [ "$gate_dir" = "$script_dir" ] && return 0
  fi
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

# --- run-local migration record -----------------------------------------------
# `${CC_PIPELINE_RUN_DIR}/visual-lane` is written by the gate alone when the
# router migrates (or a next run inherits) the publish pin. When it exists it
# replaces the host file's `lane` and `account`. A record that exists but does
# not parse never falls back to the host file: `rec_state` is `없음`, `정상` or
# `손상`, and `rec_lane`/`rec_account` hold the values of a `정상` record. The
# `**이관**` and `**승계**` lines are not read here.
RUN_LANE_RECORD=''
rec_state=없음
rec_lane=''
rec_account=''

run_record_read() {
  [ -n "${CC_PIPELINE_RUN_DIR:-}" ] || return 0
  RUN_LANE_RECORD="${CC_PIPELINE_RUN_DIR}/visual-lane"
  [ -e "$RUN_LANE_RECORD" ] || return 0
  rec_state=손상
  [ -f "$RUN_LANE_RECORD" ] || return 0
  local head line
  head=$(head -n 1 "$RUN_LANE_RECORD" 2>/dev/null || true)
  case "$head" in '<!-- cc-visual-lane v1;'*) ;; *) return 0 ;; esac
  line=$(grep -E '^\*\*레인\*\*: ' "$RUN_LANE_RECORD" | tail -n 1 || true)
  rec_lane=$(trim "${line#\*\*레인\*\*: }")
  line=$(grep -E '^\*\*계정\*\*: ' "$RUN_LANE_RECORD" | tail -n 1 || true)
  rec_account=$(trim "${line#\*\*계정\*\*: }")
  if [ -z "$rec_lane" ] || [ -z "$rec_account" ]; then
    rec_lane=''
    rec_account=''
    return 0
  fi
  rec_state=정상
}

# --- document paths -----------------------------------------------------------
# The same derivation `visual-check.sh` (`locate_sidecar`) and `run.sh`
# (`visual_sidecar_path`) use: the document key is the path below the
# document's repository top, the slug is that key without `.md` with `/`
# spelled `-`, and the base is the repository's common git directory's parent,
# so a segment worktree and the main checkout name one file. Sets DOC_KEY
# SIDECAR ACCT_RECORD DOC_LANE_RECORD, or prints the reason on stderr and
# returns 1.
DOC_KEY=''
SIDECAR=''
ACCT_RECORD=''
DOC_LANE_RECORD=''

doc_locate() {
  local doc=$1 dir top docp gcd base slug
  [ -n "$doc" ] && [ -f "$doc" ] || { echo "visual-config.sh: 설계 문서가 파일이 아니다: ${doc}" >&2; return 1; }
  dir=$(cd "$(dirname "$doc")" 2>/dev/null && pwd -P) || { echo "visual-config.sh: 설계 문서 디렉터리를 풀 수 없다: ${doc}" >&2; return 1; }
  top=$(cd "$dir" && git rev-parse --show-toplevel 2>/dev/null) || { echo "visual-config.sh: 설계 문서가 git 트리 밖이다: ${doc}" >&2; return 1; }
  top=$(cd "$top" && pwd -P) || return 1
  docp="$dir/$(basename "$doc")"
  DOC_KEY=${docp#"$top"/}
  slug=$(printf '%s' "${DOC_KEY%.md}" | tr '/' '-')
  gcd=$(cd "$dir" && git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || { echo "visual-config.sh: 베이스를 풀 수 없다: ${doc}" >&2; return 1; }
  base=$(dirname "$gcd")
  SIDECAR="$base/docs/visual/${slug}.md"
  ACCT_RECORD="$base/docs/visual-account/${slug}.md"
  DOC_LANE_RECORD="$base/docs/visual-lane/${slug}.md"
}

lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

# The `**계정**` of the document-level migration record, or nothing when the
# file is absent, its head is not `cc-visual-lane-doc v1`, or the line is
# missing or empty (the same reading as `run.sh`'s `visual_lane_doc_field`).
doc_lane_account() {
  local line
  [ -f "$DOC_LANE_RECORD" ] || return 0
  case "$(head -n 1 "$DOC_LANE_RECORD" 2>/dev/null || true)" in '<!-- cc-visual-lane-doc v1;'*) ;; *) return 0 ;; esac
  line=$(grep -E '^\*\*계정\*\*: ' "$DOC_LANE_RECORD" 2>/dev/null | tail -n 1 || true)
  trim "${line#\*\*계정\*\*: }"
}

# The `**계정**` of the account record when its head is `cc-visual-account v1`
# with this document's `owner-doc`; nothing otherwise (absent, wrong head,
# another document's, empty account line).
acct_record_account() {
  local head owner line
  [ -f "$ACCT_RECORD" ] || return 0
  head=$(head -n 1 "$ACCT_RECORD" 2>/dev/null || true)
  case "$head" in '<!-- cc-visual-account v1;'*) ;; *) return 0 ;; esac
  owner=$(printf '%s' "$head" | sed -nE 's/^.*owner-doc=([^;]*)-->.*$/\1/p')
  owner=$(trim "$owner")
  [ -n "$owner" ] && [ "$owner" = "$DOC_KEY" ] || return 0
  line=$(grep -E '^\*\*계정\*\*: ' "$ACCT_RECORD" 2>/dev/null | tail -n 1 || true)
  trim "${line#\*\*계정\*\*: }"
}

# 0 when this document's sidecar (same `owner-doc`) pins an `**아티팩트**`
# value other than `(미발행)`: some account's canvas already exists.
doc_published() {
  local owner
  [ -f "$SIDECAR" ] || return 1
  owner=$(sed -n '1,2p' "$SIDECAR" | { grep -E '^<!-- cc-visual v1;' || true; } | sed -n '1p' \
    | sed -nE 's/^.*owner-doc=([^;]*);.*$/\1/p')
  owner=$(trim "$owner")
  [ "$owner" = "$DOC_KEY" ] || return 1
  local vals
  vals=$(grep -E '^\*\*아티팩트\*\*: ' "$SIDECAR" 2>/dev/null \
    | sed -E 's/^\*\*아티팩트\*\*: //' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
    | grep -vE '^(\(미발행\))?$' || true)
  [ -n "$vals" ]
}

# --- allow list ---------------------------------------------------------------
# Every `allow` value and the last `account` value of claude-design, in file
# order. A value is one word with its surrounding blanks trimmed; an empty value
# or one holding a blank or a comma is left out, and of addresses that differ
# only in case the first spelling stays. Prints one address per line.
allowed_list() {
  [ -f "$ACCOUNT_FILE" ] || return 0
  local last_acct line n=0 key val seen=' ' lv
  last_acct=$(grep -nE '^[[:space:]]*account[[:space:]]*=' "$ACCOUNT_FILE" | tail -n 1 | cut -d: -f1 || true)
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    case "$line" in *=*) ;; *) continue ;; esac
    key=$(trim "${line%%=*}")
    case "$key" in
      allow) ;;
      account) [ "$n" = "${last_acct:-0}" ] || continue ;;
      *) continue ;;
    esac
    val=$(trim "${line#*=}")
    [ -n "$val" ] || continue
    case "$val" in *[[:space:],]*) continue ;; esac
    lv=$(lower "$val")
    case "$seen" in *" $lv "*) continue ;; esac
    seen="$seen$lv "
    printf '%s\n' "$val"
  done < "$ACCOUNT_FILE"
}

in_allowed() {
  local want a
  want=$(lower "$1")
  [ -n "$want" ] || return 1
  while IFS= read -r a; do
    [ -n "$a" ] || continue
    [ "$(lower "$a")" = "$want" ] && return 0
  done <<EOF
$(allowed_list)
EOF
  return 1
}

# --- expected account ---------------------------------------------------------
# doc_expected — the one rule (rows 1-5 in the head comment). Needs doc_locate
# first. Sets EXP_KIND (기록 허용 미지정 미설정 손상), EXP_ACCOUNT (기록),
# EXP_SRC (런이관 문서기록 문서이관, 기록 and 손상) and EXP_PATH (the record
# that decided, the sidecar for 미지정, the host file for 허용 and 미설정).
EXP_KIND=''
EXP_ACCOUNT=''
EXP_SRC=''
EXP_PATH=''

doc_expected() {
  local acct lane_acct
  EXP_KIND='' EXP_ACCOUNT='' EXP_SRC='' EXP_PATH=''
  run_record_read
  case "$rec_state" in
    정상) EXP_KIND=기록; EXP_ACCOUNT=$rec_account; EXP_SRC=런이관; EXP_PATH=$RUN_LANE_RECORD; return 0 ;;
    손상) EXP_KIND=손상; EXP_SRC=런이관; EXP_PATH=$RUN_LANE_RECORD; return 0 ;;
  esac
  lane_acct=$(doc_lane_account)
  if [ -e "$ACCT_RECORD" ]; then
    acct=$(acct_record_account)
    EXP_SRC=문서기록
    EXP_PATH=$ACCT_RECORD
    if [ -z "$acct" ] || { [ -n "$lane_acct" ] && [ "$(lower "$lane_acct")" != "$(lower "$acct")" ]; }; then
      EXP_KIND=손상
    else
      EXP_KIND=기록
      EXP_ACCOUNT=$acct
    fi
    return 0
  fi
  if [ -n "$lane_acct" ]; then
    EXP_KIND=기록; EXP_ACCOUNT=$lane_acct; EXP_SRC=문서이관; EXP_PATH=$DOC_LANE_RECORD
    return 0
  fi
  if doc_published; then
    EXP_KIND=미지정; EXP_PATH=$SIDECAR
    return 0
  fi
  EXP_PATH=$ACCOUNT_FILE
  if [ -n "$(allowed_list)" ]; then EXP_KIND=허용; else EXP_KIND=미설정; fi
}

src_label() {
  case "$1" in
    런이관) printf '%s' '런 이관 기록' ;;
    문서기록) printf '%s' '문서 계정 기록' ;;
    문서이관) printf '%s' '문서 이관 기록' ;;
  esac
}

# The `email` of `command claude auth status --json` in this process's own
# config directory, or nothing when the CLI fails or prints no email.
read_login() {
  local out rc=0 body
  out=$(command claude auth status --json 2>/dev/null) || rc=$?
  [ "$rc" = 0 ] || return 0
  body=$(printf '%s' "$out" | tr -d '\n' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
  case "$body" in
    '{'*'}')
      printf '%s' "$body" \
        | grep -oE '"email"[[:space:]]*:[[:space:]]*"[^"]*"' | head -n 1 \
        | sed -E 's/^"email"[[:space:]]*:[[:space:]]*"([^"]*)"$/\1/' || true
      ;;
  esac
}

log_line() {
  mkdir -p "$STATE_DIR"
  printf '%s %s 판독=%s 기대=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" "$3" >> "$ACCOUNT_LOG"
}

# --- expect -------------------------------------------------------------------
cmd_expect() {
  doc_locate "$1" || exit 2
  doc_expected
  case "$EXP_KIND" in
    기록) printf '기록 %s %s\n' "$EXP_ACCOUNT" "$EXP_SRC" ;;
    허용) printf '허용 %s\n' "$(allowed_list | tr '\n' ' ' | sed -e 's/[[:space:]]*$//')" ;;
    미지정) printf '미지정 %s\n' "$EXP_PATH" ;;
    미설정) printf '미설정\n' ;;
    손상) printf '손상 %s\n' "$EXP_PATH" ;;
  esac
}

# --- allowed ------------------------------------------------------------------
cmd_allowed() {
  local list
  list=$(allowed_list)
  [ -n "$list" ] || exit 1
  printf '%s\n' "$list"
}

# --- account ------------------------------------------------------------------
cmd_account() {
  refuse_in_run_unless_publish account
  local doc=$1 read_email verdict lr le shown
  doc_locate "$doc" || exit 2
  doc_expected

  if [ "$EXP_KIND" = 손상 ]; then
    log_line 판독실패 - -
    echo "계정 판정: 판독실패 (판독 -, 기대 -)"
    echo "기준: $(src_label "$EXP_SRC") ${EXP_PATH}"
    if [ "$EXP_SRC" = 런이관 ]; then
      echo "멈춤 — 이관 기록 ${EXP_PATH} 을 읽지 못했다 (머리가 cc-visual-lane v1 이 아니거나 **레인**·**계정** 줄이 없거나 비었다)"
      echo "로그: ${ACCOUNT_LOG}"
      echo "고칠 길: 게이트가 쓴 이관 기록을 확인하고 같은 국면을 다시 실행한다"
    else
      echo "멈춤 — 계정 기록 ${EXP_PATH} 을 읽지 못했다 (머리가 cc-visual-account v1 이 아니거나 owner-doc 이 이 문서가 아니거나 **계정** 줄이 비었거나, 문서 이관 기록 ${DOC_LANE_RECORD} 의 계정과 다르다)"
      echo "로그: ${ACCOUNT_LOG}"
      echo "고칠 길: 문서 이관 기록이 있으면 그 계정으로 'visual-config.sh assign ${doc} <주소> --replace' 해 맞춘 뒤 다시 실행한다"
    fi
    exit 1
  fi

  read_email=$(read_login)
  lr=$(local_part "$read_email")
  le=-
  shown=-
  case "$EXP_KIND" in
    기록)
      le=$(local_part "$EXP_ACCOUNT"); shown=$le
      if [ -z "$read_email" ]; then verdict=판독실패
      elif [ "$(lower "$read_email")" = "$(lower "$EXP_ACCOUNT")" ]; then verdict=일치
      else verdict=불일치
      fi
      ;;
    허용)
      shown='허용 목록'; le=허용목록
      if [ -z "$read_email" ]; then verdict=판독실패
      elif in_allowed "$read_email"; then verdict=일치
      else verdict=불일치
      fi
      ;;
    미지정) verdict=미지정 ;;
    *) verdict=미설정 ;;
  esac

  log_line "$verdict" "$lr" "$le"
  echo "계정 판정: ${verdict} (판독 ${lr}, 기대 ${shown})"
  case "$EXP_KIND" in
    기록) echo "기준: $(src_label "$EXP_SRC") ${EXP_PATH}" ;;
    허용|미설정) echo "기준: 허용 목록 ${EXP_PATH}" ;;
  esac
  [ "$verdict" != 일치 ] || return 0
  case "$verdict" in
    미설정)
      echo "멈춤 — ${ACCOUNT_FILE} 에 'allow = <주소>' 나 'account = <주소>' 줄이 없다"
      echo "로그: ${ACCOUNT_LOG}"
      echo "고칠 길: 호스트 파일에 'allow = <주소>' 줄을 더한 뒤 같은 국면을 다시 실행한다"
      ;;
    미지정)
      echo "멈춤 — 발행됐지만 계정 기록이 없다 — 'visual-config.sh assign ${doc} <주소>' 로 지정한 뒤 다시 실행한다. 그 주소가 허용 목록에 없으면 호스트 파일에 'allow' 줄을 먼저 더한다(런 안이면 런 밖의 사람이) (사이드카 ${EXP_PATH})"
      echo "로그: ${ACCOUNT_LOG}"
      echo "고칠 길: 런 밖에서 'visual-config.sh assign ${doc} <주소>' 로 이 문서의 계정을 지정한다"
      ;;
    판독실패)
      echo "멈춤 — 'command claude auth status --json' 에서 email 을 읽지 못했다"
      echo "로그: ${ACCOUNT_LOG}"
      echo "고칠 길: 이 설정 디렉터리에서 로그인한 뒤 같은 국면을 다시 실행한다"
      ;;
    불일치)
      if [ "$EXP_KIND" = 기록 ]; then
        echo "멈춤 — 이 문서는 ${le} 의 캔버스다 (기록 ${EXP_PATH}) — 그 계정으로 로그인해 다시 실행한다"
        echo "로그: ${ACCOUNT_LOG}"
        echo "고칠 길: ${le} 계정으로 로그인한 좌석에서 같은 국면을 다시 실행한다"
      else
        echo "멈춤 — 로그인 계정이 허용 목록에 없다 — 'allow' 줄을 더하거나 허용 계정으로 로그인한다 (호스트 파일 ${ACCOUNT_FILE})"
        echo "로그: ${ACCOUNT_LOG}"
        echo "고칠 길: 허용 목록의 계정으로 로그인한 좌석에서 같은 국면을 다시 실행한다"
      fi
      ;;
  esac
  exit 1
}

# --- account record writing ---------------------------------------------------
acct_record_head() {
  printf '<!-- cc-visual-account v1; writer=visual-config.sh|gate; reader=visual-config.sh,gate.sh,visual,visual-publish-unattended; owner-doc=%s -->\n' "$DOC_KEY"
}

# acct_record_tmp <address> <source> — a temporary file beside the record
# holding the whole record; prints its path.
acct_record_tmp() {
  local dir t
  dir=$(dirname "$ACCT_RECORD")
  mkdir -p "$dir"
  t=$(mktemp "$dir/.visual-account.XXXXXX")
  {
    acct_record_head
    printf '**계정**: %s\n' "$1"
    printf '**출처**: %s\n' "$2"
  } > "$t"
  chmod 644 "$t"
  printf '%s\n' "$t"
}

# --- record -------------------------------------------------------------------
cmd_record() {
  refuse_in_run_unless_publish record
  local doc=$1 read_email lr t winner
  doc_locate "$doc" || exit 2
  doc_expected

  if [ "$EXP_KIND" = 기록 ] && [ "$EXP_SRC" = 런이관 ]; then
    echo "계정 기록: 쓰지 않음 — 런 이관 기록 ${EXP_PATH} 이 이 런의 기대 계정이다 (계정 기록은 게이트가 이관 스테이지를 닫을 때 쓴다)"
    return 0
  fi
  case "$EXP_KIND" in
    미지정|미설정|손상)
      echo "계정 기록: 쓰지 않음 — 판정 ${EXP_KIND} (${EXP_PATH}) — 이미 발행된 문서의 계정은 'visual-config.sh assign' 만 정한다" >&2
      exit 1
      ;;
  esac

  read_email=$(read_login)
  lr=$(local_part "$read_email")
  if [ -z "$read_email" ]; then
    log_line 기록 - -
    echo "계정 기록: 쓰지 않음 — 'command claude auth status --json' 에서 email 을 읽지 못했다" >&2
    exit 1
  fi

  if [ "$EXP_KIND" = 기록 ]; then
    log_line 기록 "$lr" "$(local_part "$EXP_ACCOUNT")"
    if [ "$(lower "$read_email")" = "$(lower "$EXP_ACCOUNT")" ]; then
      echo "계정 기록: 이미 있음 — $(src_label "$EXP_SRC") ${EXP_PATH} 이 로그인 계정 ${lr} 와 같다"
      return 0
    fi
    echo "계정 기록: 쓰지 않음 — 로그인 계정 ${lr} 가 $(src_label "$EXP_SRC") ${EXP_PATH} 의 계정 $(local_part "$EXP_ACCOUNT") 가 아니다" >&2
    exit 1
  fi

  # 허용: a new document.
  log_line 기록 "$lr" 허용목록
  if ! in_allowed "$read_email"; then
    echo "계정 기록: 쓰지 않음 — 로그인 계정 ${lr} 가 허용 목록에 없다 (호스트 파일 ${ACCOUNT_FILE})" >&2
    exit 1
  fi
  t=$(acct_record_tmp "$read_email" "발행 · $(date -u +%Y-%m-%dT%H:%M:%SZ)")
  if ln "$t" "$ACCT_RECORD" 2>/dev/null; then
    rm -f "$t"
    echo "계정 기록: 썼다 — ${ACCT_RECORD} (${lr})"
    return 0
  fi
  rm -f "$t"
  winner=$(acct_record_account)
  if [ -n "$winner" ] && [ "$(lower "$winner")" = "$(lower "$read_email")" ]; then
    echo "계정 기록: 이미 있음 — ${ACCT_RECORD} 이 로그인 계정 ${lr} 와 같다"
    return 0
  fi
  echo "계정 기록: 쓰지 않음 — ${ACCT_RECORD} 이 먼저 쓰였고 로그인 계정 ${lr} 와 다르다" >&2
  exit 1
}

# --- assign -------------------------------------------------------------------
cmd_assign() {
  refuse_in_run assign
  local doc=$1 addr replace=$3 cur lane_acct t
  addr=$(trim "$2")
  doc_locate "$doc" || exit 2
  case "$addr" in ''|*[[:space:],]*)
    echo "지정하지 않았다 — 주소 '${addr}' 가 한 낱말이 아니다" >&2; exit 1 ;;
  esac
  if ! in_allowed "$addr"; then
    echo "지정하지 않았다 — '${addr}' 는 허용 목록에 없다 (호스트 파일 ${ACCOUNT_FILE} 에 'allow = <주소>' 줄을 먼저 더한다)" >&2
    exit 1
  fi
  lane_acct=$(doc_lane_account)
  if [ -n "$lane_acct" ] && [ "$(lower "$lane_acct")" != "$(lower "$addr")" ]; then
    echo "지정하지 않았다 — 문서 이관 기록 ${DOC_LANE_RECORD} 의 계정 $(local_part "$lane_acct") 와 다르다 (--replace 로도 덮지 않는다 — 그 이관 기록을 사람이 지운 뒤 지정한다)" >&2
    exit 1
  fi
  if [ -e "$ACCT_RECORD" ]; then
    cur=$(acct_record_account)
    if [ -n "$cur" ] && [ "$(lower "$cur")" = "$(lower "$addr")" ]; then
      echo "지정할 것 없음 — ${ACCT_RECORD} 이 이미 $(local_part "$cur") 이다"
      return 0
    fi
    if [ "$replace" != --replace ]; then
      if [ -n "$cur" ]; then
        echo "지정하지 않았다 — ${ACCT_RECORD} 이 이미 $(local_part "$cur") 이다 (바꾸려면 --replace)" >&2
      else
        echo "지정하지 않았다 — ${ACCT_RECORD} 을 읽지 못했다 (덮으려면 --replace)" >&2
      fi
      exit 1
    fi
  fi
  t=$(acct_record_tmp "$addr" "지정 · $(date -u +%Y-%m-%dT%H:%M:%SZ)")
  mv "$t" "$ACCT_RECORD"
  echo "지정했다 — ${ACCT_RECORD} ($(local_part "$addr"))"
}

# --- lane ---------------------------------------------------------------------
cmd_lane() {
  local line val=''
  run_record_read
  case "$rec_state" in
    정상) printf '%s\n' "$rec_lane"; return 0 ;;
    손상) exit 1 ;;
  esac
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
  account) [ $# -eq 1 ] || usage; cmd_account "$1" ;;
  expect) [ $# -eq 1 ] || usage; cmd_expect "$1" ;;
  record) [ $# -eq 1 ] || usage; cmd_record "$1" ;;
  assign)
    case $# in
      2) cmd_assign "$1" "$2" '' ;;
      3) [ "$3" = --replace ] || usage; cmd_assign "$1" "$2" "$3" ;;
      *) usage ;;
    esac
    ;;
  allowed) [ $# -eq 0 ] || usage; cmd_allowed ;;
  lane) [ $# -eq 0 ] || usage; cmd_lane ;;
  models) [ $# -eq 0 ] || usage; cmd_models ;;
  bans) [ $# -eq 0 ] || usage; cmd_bans ;;
  seed) [ $# -eq 0 ] || usage; cmd_seed ;;
  append) cmd_append "$@" ;;
  snapshot) cmd_snapshot "$@" ;;
  *) usage ;;
esac
