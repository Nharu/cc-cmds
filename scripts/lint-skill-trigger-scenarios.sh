#!/usr/bin/env bash
#
# lint-skill-trigger-scenarios.sh — every model-invoked skill has a trigger
# scenario file, and every scenario file is well formed.
#
# A model-invoked skill fires on its description and `when_to_use` alone, so a
# change to either moves the boundary between the utterances that should reach
# it and the neighbours that should not. The scenario files under
# tests/fixtures/skill-triggers/ spell that boundary out, one utterance per
# line, and scripts/skill-trigger-measure.sh measures it against a real session.
# This lint calls no model: it checks that the set is complete and that each
# file reads the same way the measuring harness reads it.
#
# Checks (each FAIL line names its number as `[검사 N]`):
#   1. The model-invoked set is every `SKILLS_ROOT/*/SKILL.md` whose frontmatter
#      has no `disable-model-invocation: true` line — a missing key counts as
#      model-invoked, which is Claude Code's default.
#   2. Every name of the set has exactly one `<name>.tsv`, and no `.tsv` is
#      named after anything else (`README.md` is allowed).
#   3. The first line is the version token and the column header line is
#      `id<TAB>기대<TAB>발화<TAB>근거`, byte for byte.
#   4. Every data line has four fields, none empty, none with leading or
#      trailing whitespace; `id` matches ^[a-z0-9][a-z0-9-]*$ and is unique in
#      its file.
#   5. Every `발화` is unique across the whole set.
#   6. `기대` is `비발동`, `cc-cmds:<a name of the set>`, or an outside skill
#      name ^[A-Za-z0-9][A-Za-z0-9._-]*(:[A-Za-z0-9][A-Za-z0-9._-]*)?$ that does
#      not start with `cc-cmds:`.
#   7. Every file has at least three trigger lines (`기대` is
#      `cc-cmds:<that file's skill>`) and at least three neighbour lines.
#   8. The set has at least one line expecting an outside skill.
#
# A file outside the set is reported under check 2 and not read further.
# Blank lines and `#` lines are not data, before or after the header.
#
# Usage: bash scripts/lint-skill-trigger-scenarios.sh
#
# Env override:
#   SKILLS_ROOT    skills directory (default plugins/cc-cmds/skills)
#   SCENARIO_ROOT  scenario directory (default tests/fixtures/skill-triggers)
#
# Exit codes:
#   0  every check holds
#   1  at least one check is broken
#   2  the lint cannot run (a root directory is missing)
#
# Compatibility: bash 3.2 (macOS) — no associative arrays, no mapfile.

set -euo pipefail
export LC_ALL=C

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
skills_root="${SKILLS_ROOT:-$repo_root/plugins/cc-cmds/skills}"
scenario_root="${SCENARIO_ROOT:-$repo_root/tests/fixtures/skill-triggers}"

VERSION_TOKEN='# cc-skill-triggers v1'
HEADER=$(printf 'id\t기대\t발화\t근거')
TRIGGER_FLOOR=3
NEIGHBOR_FLOOR=3
ID_RE='^[a-z0-9][a-z0-9-]*$'
EXT_RE='^[A-Za-z0-9][A-Za-z0-9._-]*(:[A-Za-z0-9][A-Za-z0-9._-]*)?$'
TAB=$'\t'

for d in "$skills_root" "$scenario_root"; do
  if [[ ! -d "$d" ]]; then
    echo "FAIL: $d — 디렉터리가 없다 ; 시나리오 린트를 돌릴 수 없다" >&2
    exit 2
  fi
done

fail=0
flag() {
  # flag <n> <file:line> <message>
  echo "FAIL: $2 — [검사 $1] $3" >&2
  fail=1
}

# --- 1. The model-invoked set ------------------------------------------------
# frontmatter_off <SKILL.md> — 0 when the frontmatter turns model invocation off.
frontmatter_off() {
  awk 'NR == 1 && $0 != "---" { exit 1 }
       NR > 1 && $0 == "---" { exit 1 }
       $0 == "disable-model-invocation: true" { found = 1; exit 0 }
       END { if (!found) exit 1 }' "$1"
}

set_names=""
for f in "$skills_root"/*/SKILL.md; do
  [[ -f "$f" ]] || continue
  name=$(basename "$(dirname "$f")")
  if frontmatter_off "$f"; then continue; fi
  set_names="$set_names$name
"
done
set_names=$(printf '%s' "$set_names" | LC_ALL=C sort)

# Here-strings rather than pipes: under pipefail an early-exiting `grep -q` can
# SIGPIPE the writer and turn a match into a failure.
in_set() { [[ -n "$1" ]] && grep -qxF -- "$1" <<< "$set_names"; }

# --- 2. One file per name, none beside the set ------------------------------
while IFS= read -r name; do
  [[ -n "$name" ]] || continue
  if [[ ! -f "$scenario_root/$name.tsv" ]]; then
    flag 2 "$scenario_root/$name.tsv:0" "모델 발동 스킬 ${name} 의 시나리오 파일이 없다 ; 시나리오 파일 ${name}.tsv 를 더하고 측정 하네스(scripts/skill-trigger-measure.sh --skill ${name})로 잰다"
  fi
done <<< "$set_names"

files=""
for f in "$scenario_root"/*.tsv; do
  [[ -f "$f" ]] || continue
  name=$(basename "$f" .tsv)
  if ! in_set "$name"; then
    flag 2 "$f:0" "모델 발동 스킬이 아닌 이름 ${name} 의 시나리오 파일이다 ; 그 스킬이 모델 발동이 아니거나 없다"
    continue
  fi
  files="$files$f
"
done

# --- 3 to 7, file by file ----------------------------------------------------
utts=$(mktemp "${TMPDIR:-/tmp}/lint-skill-triggers.XXXXXX")
trap 'rm -f "$utts"' EXIT
external=0
lines_total=0

# trimmed <s> — 0 when the field has no leading or trailing whitespace.
trimmed() { [[ ! "$1" =~ ^[[:space:]] && ! "$1" =~ [[:space:]]$ ]]; }

while IFS= read -r f; do
  [[ -n "$f" ]] || continue
  name=$(basename "$f" .tsv)
  n=0
  header_seen=0
  ids=""
  trig=0
  neigh=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    n=$((n + 1))
    if (( n == 1 )); then
      [[ "$line" == "$VERSION_TOKEN" ]] || flag 3 "$f:1" "첫 줄이 판 토큰 「${VERSION_TOKEN}」 이 아니다"
      continue
    fi
    [[ -z "$line" || "$line" == \#* ]] && continue
    if (( header_seen == 0 )); then
      header_seen=1
      [[ "$line" == "$HEADER" ]] || flag 3 "$f:$n" "열 머리 줄이 「id<TAB>기대<TAB>발화<TAB>근거」 가 아니다"
      continue
    fi
    tabs=${line//[^$TAB]/}
    if (( ${#tabs} != 3 )); then
      flag 4 "$f:$n" "데이터 줄이 탭으로 나뉜 네 칸이 아니다 (칸 $(( ${#tabs} + 1 ))개)"
      continue
    fi
    id=${line%%"$TAB"*}; rest=${line#*"$TAB"}
    exp=${rest%%"$TAB"*}; rest=${rest#*"$TAB"}
    utt=${rest%%"$TAB"*}; why=${rest#*"$TAB"}
    bad=0
    for v in "$id" "$exp" "$utt" "$why"; do
      if [[ -z "$v" ]]; then flag 4 "$f:$n" "빈 칸이 있다"; bad=1; break; fi
      if ! trimmed "$v"; then flag 4 "$f:$n" "칸 「${v}」 에 앞뒤 공백이 있다"; bad=1; break; fi
    done
    (( bad == 0 )) || continue
    lines_total=$((lines_total + 1))
    if [[ ! "$id" =~ $ID_RE ]]; then
      flag 4 "$f:$n" "id 문법 위반 「${id}」 — ^[a-z0-9][a-z0-9-]*\$ 이어야 한다"
    elif grep -qxF -- "$id" <<< "$ids"; then
      flag 4 "$f:$n" "id 가 파일 안에서 겹친다 「${id}」"
    fi
    ids="$ids$id
"
    printf '%s\t%s:%s\n' "$utt" "$f" "$n" >> "$utts"
    case "$exp" in
      비발동) neigh=$((neigh + 1)) ;;
      cc-cmds:*)
        target=${exp#cc-cmds:}
        if ! in_set "$target"; then
          flag 6 "$f:$n" "알 수 없는 cc-cmds 스킬 「${exp}」 — 모델 발동 집합에 없다"
        elif [[ "$target" == "$name" ]]; then
          trig=$((trig + 1))
        else
          neigh=$((neigh + 1))
        fi
        ;;
      *)
        if [[ "$exp" =~ $EXT_RE ]]; then
          neigh=$((neigh + 1)); external=$((external + 1))
        else
          flag 6 "$f:$n" "기대 문법 위반 「${exp}」 — 비발동, cc-cmds:<이름>, 외부 스킬 이름 중 하나여야 한다"
        fi
        ;;
    esac
  done < "$f"
  (( header_seen == 1 )) || flag 3 "$f:1" "열 머리 줄이 없다"
  (( trig >= TRIGGER_FLOOR )) || flag 7 "$f:1" "발동 발화가 ${trig}개다 ; ${TRIGGER_FLOOR}개 이상이어야 한다"
  (( neigh >= NEIGHBOR_FLOOR )) || flag 7 "$f:1" "이웃 발화가 ${neigh}개다 ; ${NEIGHBOR_FLOOR}개 이상이어야 한다"
done <<< "$files"

# --- 5. Utterances are unique across the set ---------------------------------
dups=$(awk -F'\t' '($1 in first) { print $2 "\t" first[$1] "\t" $1; next } { first[$1] = $2 }' "$utts")
while IFS="$TAB" read -r here there utt; do
  [[ -n "$here" ]] || continue
  flag 5 "$here" "발화가 집합 안에서 겹친다 「${utt}」 — 먼저 나온 자리 ${there}"
done <<< "$dups"

# --- 8. At least one outside skill -------------------------------------------
if [[ -n "$files" ]] && (( external == 0 )); then
  flag 8 "$scenario_root:0" "외부 스킬을 기대하는 줄이 없다 ; 다른 플러그인 스킬로 가야 할 이웃 발화가 하나 이상 있어야 한다"
fi

if [[ "$fail" != "0" ]]; then
  echo "lint-skill-trigger-scenarios: violations found" >&2
  exit 1
fi
echo "OK:   skill trigger scenarios — 모델 발동 스킬 $(printf '%s\n' "$set_names" | grep -c .)개, 발화 ${lines_total}줄, 외부 기대 ${external}줄"
exit 0
