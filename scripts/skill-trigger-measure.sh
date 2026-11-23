#!/usr/bin/env bash
# Measure whether the scenario utterances of tests/fixtures/skill-triggers/
# reach the skill each line expects in a real headless session.
#
# Every utterance is sent RUNS times to `claude -p` with only the Skill tool
# allowed. A run's observation is the `input.skill` of the first Skill
# tool_use the session emits, or `비발동` when it emits none; the session is
# not cut at that call, it ends on its own because no other tool is allowed.
# A line is `일치` when all RUNS valid runs match, `어긋남` when none does,
# `불안정` otherwise, and `미측정` when fewer than RUNS runs are valid.
#
# The plugin directories are passed through as given, so the session loads
# the same plugins the caller's own sessions load. The account follows the
# caller's environment (CLAUDE_CONFIG_DIR and the like are inherited).
#
# Protocol: scripts/prompt-change-protocol.md
#   1 candidate surface  — met: no clone is made; the working directory, each
#                          plugin directory and the variables this script
#                          sets are checked before the first call, and the
#                          SKILL_TRIGGER_* variables are unset after they are
#                          read
#   2 blind judge        — not applicable: no judge; the first Skill call is
#                          read deterministically
#   3 compliance scoring — met: the verdict reads only the Skill tool calls
#                          of the stream-json output, never the session's text
#   4 fixed rule         — met: RUNS, the per-call cap and the verdict order
#                          are constants pinned by golden tests
#   5 noise              — met: every utterance runs RUNS times and a line
#                          that is not RUNS of RUNS is reported `불안정`
#                          instead of judged
#   6 budget             — met: --budget-usd is required, checked before
#                          each call, exit 4
#
# Usage:
#   scripts/skill-trigger-measure.sh --model <name> --budget-usd <N>
#       [--plugin-dir <dir>]... [--skill <name>]... [--workdir <dir>]
#       [--id <id>] [--dry-run]
#
#   --model       the session model; no default
#   --budget-usd  no default: before each call, spent + the per-call cap must
#                 not exceed it
#   --plugin-dir  passed to every session as given, once per occurrence
#   --skill       measure that skill's scenario file only (repeatable); all
#                 files when absent
#   --workdir     the sessions' working directory (default: the current one)
#   --id          the state directory's name; an existing one is resumed, and
#                 only the runs not done yet are called. Created from the date
#                 and random digits when absent
#   --dry-run     lint, check and plan (calls and their cap sum), no call
#
# Environment:
#   SKILL_TRIGGER_CLAUDE_BIN   the CLI (default: claude on PATH)
#   SKILL_TRIGGER_STATE_ROOT   state root
#                              (default ${XDG_STATE_HOME:-$HOME/.local/state}/cc-cmds/skill-triggers)
#   SKILLS_ROOT, SCENARIO_ROOT the roots handed to the scenario lint, and the
#                              scenario files measured
#   Each is read at start and then unset, so no session inherits one.
#
# State (<state root>/<id>/):
#   meta.tsv     model, CLI version, plugin directories, working directory,
#                scenario set sha256, start time, money spent
#   <skill>/<line id>.<k>.{jsonl,err,obs,cost,rc}  one run; `.rc` marks it done
#   discarded/   the runs of a session that loaded no cc-cmds skill
#   report.tsv   파일 id 기대 관측1 관측2 관측3 일치 판정
#
# Exit codes:
#   0 — every line is `일치`
#   1 — failure: the scenario lint, the surface check (the word and where it
#       stands are printed), a changed scenario set on resume, or a session
#       that loaded no cc-cmds skill
#   2 — usage error
#   3 — measured, and some line is not `일치`
#   4 — budget guard: the next call would exceed --budget-usd; the runs left
#       are `미측정(예산)`, and the same --id with a larger budget carries on
#
# Compatibility: bash 3.2 (macOS) — no associative arrays, no mapfile.

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
LINT="$script_dir/lint-skill-trigger-scenarios.sh"

RUNS=3
PER_CALL_USD=0.5
# The value of the `**금지어**:` line of scripts/prompt-change-protocol.md,
# byte for byte; the test compares the two.
FORBIDDEN_WORDS="eval evaluation evaluate judge judging rubric grader grading benchmark experiment exp 실험 평가 심판 채점 루브릭"
# Empty: there are no arms. One environment is measured against the
# expectations written in the scenario files, so no arm name exists to leak.
ARM_WORDS=""
# The plugin's notification and status line switches, off in every session so
# a measurement neither alerts the user nor rewrites their settings.
SWITCHES="CC_CMDS_SESSION_NOTIFY=0 CC_CMDS_SESSION_DISMISS=0 CC_CMDS_STATUSLINE_AUTOINSTALL=0"
TAB=$'\t'

usage() {
  [[ -n "${1:-}" ]] && echo "skill-trigger-measure: $1" >&2
  echo "usage: scripts/skill-trigger-measure.sh --model <name> --budget-usd <N> [--plugin-dir <dir>]... [--skill <name>]... [--workdir <dir>] [--id <id>] [--dry-run]" >&2
  exit 2
}

model=""
budget=""
plugin_dirs=()
skills=()
workdir=""
run_id=""
dry_run=0
while (( $# > 0 )); do
  case "$1" in
    --model)      (( $# >= 2 )) || usage "--model needs a value"; model="$2"; shift 2 ;;
    --budget-usd) (( $# >= 2 )) || usage "--budget-usd needs a value"; budget="$2"; shift 2 ;;
    --plugin-dir) (( $# >= 2 )) || usage "--plugin-dir needs a value"; plugin_dirs+=("$2"); shift 2 ;;
    --skill)      (( $# >= 2 )) || usage "--skill needs a value"; skills+=("$2"); shift 2 ;;
    --workdir)    (( $# >= 2 )) || usage "--workdir needs a value"; workdir="$2"; shift 2 ;;
    --id)         (( $# >= 2 )) || usage "--id needs a value"; run_id="$2"; shift 2 ;;
    --dry-run)    dry_run=1; shift ;;
    -h|--help)    usage ;;
    *)            usage "unknown argument: $1" ;;
  esac
done

[[ -n "$model" ]] || usage "--model is required"
[[ -n "$budget" ]] || usage "--budget-usd is required"
[[ "$budget" =~ ^[0-9]+(\.[0-9]+)?$ ]] || usage "--budget-usd must be a number: $budget"
[[ -z "$run_id" || "$run_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || usage "--id must match ^[A-Za-z0-9][A-Za-z0-9._-]*\$: $run_id"

CLAUDE_BIN="${SKILL_TRIGGER_CLAUDE_BIN:-}"
STATE_ROOT="${SKILL_TRIGGER_STATE_ROOT:-${XDG_STATE_HOME:-$HOME/.local/state}/cc-cmds/skill-triggers}"
skills_root="${SKILLS_ROOT:-}"
scenario_root="${SCENARIO_ROOT:-$repo_root/tests/fixtures/skill-triggers}"
# The harness's own variables are read above; a session must not see that a
# harness started it, nor a pipeline stage's seat.
for v in $(compgen -e | grep -E '^(SKILL_TRIGGER_|CC_PIPELINE_)' || true); do unset "$v"; done
unset SKILLS_ROOT SCENARIO_ROOT

[[ -n "$workdir" ]] || workdir="$PWD"
[[ -d "$workdir" ]] || usage "--workdir is not a directory: $workdir"
workdir=$(cd "$workdir" && pwd -P)
for d in ${plugin_dirs[@]+"${plugin_dirs[@]}"}; do
  [[ -d "$d" ]] || usage "--plugin-dir is not a directory: $d"
done
[[ -d "$scenario_root" ]] || usage "scenario root is not a directory: $scenario_root"

files=()
if (( ${#skills[@]} > 0 )); then
  for s in "${skills[@]}"; do
    [[ -f "$scenario_root/$s.tsv" ]] || usage "no scenario file for skill: $s"
    files+=("$scenario_root/$s.tsv")
  done
else
  for f in "$scenario_root"/*.tsv; do
    [[ -f "$f" ]] && files+=("$f")
  done
fi

# ---------- the scenario lint --------------------------------------------------

lint_env=(SCENARIO_ROOT="$scenario_root")
[[ -n "$skills_root" ]] && lint_env+=(SKILLS_ROOT="$skills_root")
if ! env "${lint_env[@]}" bash "$LINT" >&2; then
  echo "skill-trigger-measure: the scenario lint failed; nothing was called" >&2
  exit 1
fi

# ---------- the candidate surface --------------------------------------------

# words_in <text> <words> — every word of the list the text holds, one per
# line. A word of letters, digits and `_` matches in any case between
# characters outside [A-Za-z0-9_]; any other word matches as a substring.
words_in() {
  local w
  for w in $2; do
    if [[ "$w" =~ ^[A-Za-z0-9_]+$ ]]; then
      LC_ALL=C grep -qiE "(^|[^A-Za-z0-9_])${w}([^A-Za-z0-9_]|\$)" <<< "$1" && printf '%s\n' "$w"
    else
      LC_ALL=C grep -qF -- "$w" <<< "$1" && printf '%s\n' "$w"
    fi
  done
  return 0
}

# surface_hit <where> <text> — end the call with 1 when the text holds a
# forbidden word or an arm name, naming each word and where it stands. Every
# string checked here is one this script chose, so stopping loses no sample.
surface_hit() {
  local hits w
  hits=$(words_in "$2" "$FORBIDDEN_WORDS $ARM_WORDS")
  [[ -n "$hits" ]] || return 0
  while IFS= read -r w; do
    echo "skill-trigger-measure: surface check: '${w}' in ${1}" >&2
  done <<< "$hits"
  exit 1
}

surface_hit "작업 디렉터리 $workdir" "$workdir"
for d in ${plugin_dirs[@]+"${plugin_dirs[@]}"}; do
  surface_hit "플러그인 디렉터리 $d" "$d"
done
for kv in $SWITCHES; do
  surface_hit "환경 변수 $kv" "$kv"
done

# ---------- the scenario rows -------------------------------------------------

# rows <file> — one `id<TAB>기대<TAB>발화` line per data line, read the way
# the lint reads it: the first line is the version token, blank and `#` lines
# are not data, and the first other line is the column header.
rows() {
  awk -F'\t' 'NR == 1 { next } /^#/ || $0 == "" { next } !h { h = 1; next } { print $1 "\t" $2 "\t" $3 }' "$1"
}

planned=0
for f in "${files[@]}"; do
  n=$(rows "$f" | grep -c . || true)
  planned=$((planned + n * RUNS))
done

if (( dry_run == 1 )); then
  echo "계획: 파일 ${#files[@]}개, 호출 ${planned}회, 호출당 상한 ${PER_CALL_USD}달러, 상한 합 $(awk -v n="$planned" -v c="$PER_CALL_USD" 'BEGIN { printf "%.2f", n * c }')달러"
  exit 0
fi

if [[ -z "$CLAUDE_BIN" ]]; then
  CLAUDE_BIN=$(command -v claude || true)
  [[ -n "$CLAUDE_BIN" ]] || { echo "skill-trigger-measure: claude is not on PATH" >&2; exit 1; }
fi

# ---------- state -------------------------------------------------------------

# sha256 of standard input, as hex.
sha256_in() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -d' ' -f1; else shasum -a 256 | cut -d' ' -f1; fi
}

# set_sha — the scenario set: every file's name and bytes, in name order.
set_sha() {
  local f
  for f in "$scenario_root"/*.tsv; do
    [[ -f "$f" ]] || continue
    printf '%s\n' "$(basename "$f")"
    cat "$f"
  done | sha256_in
}

# kv <file> <key> — the value of the first key<TAB>value line.
kv() { awk -F'\t' -v k="$2" '$1 == k { print substr($0, length(k) + 2); exit }' "$1"; }

[[ -n "$run_id" ]] || run_id="$(date -u +%Y%m%d)-$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
ST="$STATE_ROOT/$run_id"
META="$ST/meta.tsv"
sha=$(set_sha)

if [[ -f "$META" ]]; then
  was=$(kv "$META" "시나리오 sha256")
  if [[ "$was" != "$sha" ]]; then
    echo "skill-trigger-measure: the scenario set changed since $run_id started ($was → $sha); start a new --id" >&2
    exit 1
  fi
  was=$(kv "$META" "모델")
  if [[ "$was" != "$model" ]]; then
    echo "skill-trigger-measure: $run_id was measured with model '$was', not '$model'; start a new --id" >&2
    exit 1
  fi
else
  mkdir -p "$ST"
  version=$("$CLAUDE_BIN" --version 2>/dev/null </dev/null || true)
  version=${version%%$'\n'*}
  {
    printf '모델\t%s\n' "$model"
    printf 'claude --version\t%s\n' "$version"
    for d in ${plugin_dirs[@]+"${plugin_dirs[@]}"}; do printf '플러그인 디렉터리\t%s\n' "$d"; done
    printf '작업 디렉터리\t%s\n' "$workdir"
    printf '시나리오 sha256\t%s\n' "$sha"
    printf '시작 시각\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '쓴 돈\t0\n'
  } > "$META"
fi
for f in "${files[@]}"; do mkdir -p "$ST/$(basename "$f" .tsv)"; done

# spent — the money of every done run, the discarded ones included.
spent=$(find "$ST" -name '*.cost' -type f -exec cat {} + 2>/dev/null | awk '{ s += $1 } END { printf "%.6f", s + 0 }')

# ---------- one run -------------------------------------------------------------

# read_run <jsonl> <expected> — one `|`-separated line (a tab would let read
# merge an empty field into its neighbour):
#   <init has skills> <first Skill or ""> <has result> <is_error> <cost or "">
#   <expected listed> <a cc-cmds skill listed>
read_run() {
  jq -rRs --arg exp "$2" '
    [split("\n")[] | select(length > 0) | (fromjson? // empty) | select(type == "object")] as $ev
    | ($ev | map(select(.type == "system" and .subtype == "init")) | first) as $init
    | ($ev | map(select(.type == "result")) | last) as $res
    | ([$ev[] | select(.type == "assistant") | .message.content[]?
        | select(type == "object" and .type == "tool_use" and .name == "Skill") | .input.skill] | first) as $sk
    | (($init | type) == "object" and ($init.skills | type) == "array") as $listed
    | [ (if $listed then "1" else "0" end),
        ($sk // "" | tostring),
        (if $res != null then "1" else "0" end),
        (if $res != null and $res.is_error == true then "1" else "0" end),
        (if $res != null and ($res.total_cost_usd | type) == "number" then ($res.total_cost_usd | tostring) else "" end),
        (if $listed and ([$init.skills[] | select(. == $exp)] | length) > 0 then "1" else "0" end),
        (if $listed and ([$init.skills[] | select(type == "string" and startswith("cc-cmds:"))] | length) > 0 then "1" else "0" end)
      ] | join("|")' "$1"
}

# discard <base> — move one run's files under discarded/.
discard() {
  local base="$1" name ext
  mkdir -p "$ST/discarded"
  name="$(basename "$(dirname "$base")").$(basename "$base")"
  for ext in jsonl err obs cost rc; do
    [[ -f "$base.$ext" ]] && mv "$base.$ext" "$ST/discarded/$name.$ext"
  done
  return 0
}

plugin_args=()
for d in ${plugin_dirs[@]+"${plugin_dirs[@]}"}; do plugin_args+=(--plugin-dir "$d"); done
switch_env=()
for kv in $SWITCHES; do switch_env+=("$kv"); done

budget_hit=0
cc_checked=0
for f in "${files[@]}"; do
  skill=$(basename "$f" .tsv)
  while IFS="$TAB" read -r id exp utt; do
    [[ -n "$id" ]] || continue
    for (( k = 1; k <= RUNS; k++ )); do
      base="$ST/$skill/$id.$k"
      [[ -f "$base.rc" ]] && continue
      if awk -v s="$spent" -v c="$PER_CALL_USD" -v b="$budget" 'BEGIN { exit !(s + c > b) }'; then
        budget_hit=1
        break 3
      fi
      rc=0
      ( cd "$workdir" && env "${switch_env[@]}" "$CLAUDE_BIN" -p "$utt" ${plugin_args[@]+"${plugin_args[@]}"} \
          --model "$model" --output-format stream-json --verbose --tools Skill --strict-mcp-config \
          --no-session-persistence --max-budget-usd "$PER_CALL_USD" ) \
        < /dev/null > "$base.jsonl" 2> "$base.err" || rc=$?
      IFS='|' read -r listed sk has_res is_err cost exp_listed cc_listed <<< "$(read_run "$base.jsonl" "$exp")"
      [[ -n "$cost" ]] || cost="$PER_CALL_USD"
      if (( rc != 0 )); then obs="무효(종료 $rc)"
      elif [[ "$has_res" != "1" ]]; then obs="무효(result 없음)"
      elif [[ "$is_err" == "1" ]]; then obs="무효(is_error)"
      elif [[ "$listed" != "1" ]]; then obs="무효(init 목록 없음)"
      elif [[ "$exp" != "비발동" && "$exp_listed" != "1" ]]; then obs="무효(목록 없음)"
      elif [[ -n "$sk" ]]; then obs="$sk"
      else obs="비발동"
      fi
      printf '%s\n' "$obs" > "$base.obs"
      printf '%s\n' "$cost" > "$base.cost"
      printf '%s\n' "$rc" > "$base.rc"
      spent=$(awk -v s="$spent" -v c="$cost" 'BEGIN { printf "%.6f", s + c }')
      if (( cc_checked == 0 )) && [[ "$listed" == "1" ]]; then
        cc_checked=1
        if [[ "$cc_listed" != "1" ]]; then
          discard "$base"
          echo "skill-trigger-measure: the first session listed no cc-cmds skill — the plugin was not loaded; pass the directories your sessions load with --plugin-dir (run kept under $ST/discarded)" >&2
          exit 1
        fi
      fi
    done
  done <<< "$(rows "$f")"
done

# ---------- the report ------------------------------------------------------------

REPORT="$ST/report.tsv"
tmp_report="$REPORT.tmp.$$"
printf '파일\tid\t기대\t관측1\t관측2\t관측3\t일치\t판정\n' > "$tmp_report"
left="미실행"
(( budget_hit == 0 )) || left="미측정(예산)"
all_match=1
summary=""
mismatches=""
for f in "$scenario_root"/*.tsv; do
  [[ -f "$f" ]] || continue
  skill=$(basename "$f" .tsv)
  [[ -d "$ST/$skill" ]] || continue
  c_match=0; c_miss=0; c_unst=0; c_none=0
  while IFS="$TAB" read -r id exp utt; do
    [[ -n "$id" ]] || continue
    obs_list=()
    valid=0
    matched=0
    for (( k = 1; k <= RUNS; k++ )); do
      base="$ST/$skill/$id.$k"
      if [[ -f "$base.rc" && -f "$base.obs" ]]; then
        o=$(cat "$base.obs")
      else
        o="$left"
      fi
      obs_list+=("$o")
      case "$o" in
        무효\(*|미측정*|미실행) ;;
        *) valid=$((valid + 1)); [[ "$o" == "$exp" ]] && matched=$((matched + 1)) ;;
      esac
    done
    # The verdict order is fixed: not RUNS valid runs, then all, then none.
    if (( valid != RUNS )); then verdict="미측정"; c_none=$((c_none + 1))
    elif (( matched == RUNS )); then verdict="일치"; c_match=$((c_match + 1))
    elif (( matched == 0 )); then verdict="어긋남"; c_miss=$((c_miss + 1))
    else verdict="불안정"; c_unst=$((c_unst + 1))
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(basename "$f")" "$id" "$exp" "${obs_list[0]}" "${obs_list[1]}" "${obs_list[2]}" "$matched" "$verdict" >> "$tmp_report"
    if [[ "$verdict" != "일치" ]]; then
      all_match=0
      mismatches="$mismatches  $(basename "$f") ${id} — 기대 ${exp} · 관측 ${obs_list[0]}, ${obs_list[1]}, ${obs_list[2]} → ${verdict}
"
    fi
  done <<< "$(rows "$f")"
  summary="$summary$(basename "$f"): 일치 ${c_match} · 어긋남 ${c_miss} · 불안정 ${c_unst} · 미측정 ${c_none}
"
done
mv "$tmp_report" "$REPORT"

tmp_meta="$META.tmp.$$"
awk -F'\t' -v s="$spent" 'BEGIN { OFS = "\t" } $1 == "쓴 돈" { print $1, s; next } { print }' "$META" > "$tmp_meta"
mv "$tmp_meta" "$META"

printf '%s' "$summary"
if [[ -n "$mismatches" ]]; then
  echo "일치가 아닌 줄:"
  printf '%s' "$mismatches"
fi
echo "보고서: $REPORT (쓴 돈 ${spent}달러)"

if (( budget_hit == 1 )); then
  echo "skill-trigger-measure: the next call would exceed --budget-usd $budget (spent $spent); the same --id $run_id with a larger budget carries on" >&2
  exit 4
fi
(( all_match == 1 )) && exit 0
exit 3
