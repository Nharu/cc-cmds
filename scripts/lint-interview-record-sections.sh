#!/usr/bin/env bash
#
# lint-interview-record-sections.sh — the interview record's section list is
# spelled once, in the contract, and its writer and its reader still agree.
#
# 스킬 문면을 비교하며 기록을 보지 않는다. The record's shape lives in three
# places: the fence of `pipeline-sidecar.md` `### 2b.5` (the contract), the
# kickoff's 5m (the writer) and the design stage's Step 1 (the reader). A section
# added to one and not the others is invisible to every test that runs a stage:
# the writer freezes a section the reader never opens, or the reader waits for
# one nobody writes, and the design quietly runs from less than the person said.
# Records on disk are not read here — they are frozen when written, and a lint
# over them would judge the past by today's contract.
#
# The truth is EXTRACTED from the contract, never restated:
#   C   the `## ` lines inside the `### 2b.5` fence, in order
#   T   the version token in that fence's header comment
#   X   the `## ` spans on the `**Not read by the design stage**` line
#   C1  the `## ` spans on the `**Previous version**` line, T1 its token
#   K   the bold keys under `## 배포 형상` inside the fence
#   B   the bold keys under `## 확인된 요구` inside the fence whose line ends
#       at the colon (the three read-back labels)
#
# Assertions (each FAIL line names its number as `[단언 N]`):
#    1. The header table's interview-record row carries T.
#    2. The `## ` spans on the one line of the autopilot 5m zone that carries T
#       equal C, in order.
#    3. In the design stage's Step 1 zone, the spans on the one line carrying T
#       equal C − X, and on the one line carrying T1 equal C1 − X, in order.
#    4. X is not empty, X ⊆ C, and C1 ⊆ C.
#    5. `**선택지**` is in the fence, in the 5j zone and in the Step 1 zone.
#    6. Every key of K is in the 5j zone as `**<key>**`.
#    7. Every label of B is in the shared interview convention.
#    8. No count word stands before `content sections` or `substitutions` in
#       the design stage — its lists are the version bullets, not a number.
#    9. The design stage carries `the record governs`.
#   10. `cc-run-kickoff v1` is in the header table, in the `### 2b.6` fence and
#       in autopilot, and `### 2b.6` names every terminal stage.
#   11. The `reader=` of the `### 2b.5` fence does not name the morning report.
#
# A zone runs from the line that opens it to the next line matching
# `^\*\*5[a-n]( |\(|—)` or `^#{1,4} ` outside a code fence.
#
# Usage: bash scripts/lint-interview-record-sections.sh
#
# Env override:
#   SKILLS_ROOT  skills directory (default plugins/cc-cmds/skills)
#
# Exit codes:
#   0  every assertion holds
#   1  at least one assertion is broken
#   2  the contract gives no single source (file, section or fence missing)
#
# Compatibility: bash 3.2 (macOS) — no associative arrays, no mapfile.

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
skills_root="${SKILLS_ROOT:-$repo_root/plugins/cc-cmds/skills}"

PS="$skills_root/_common/pipeline-sidecar.md"
RI="$skills_root/_common/requirements-interview.md"
AP="$skills_root/autopilot/SKILL.md"
DDU="$skills_root/design-discuss-unattended/SKILL.md"

KICKOFF_TOKEN='cc-run-kickoff v1'
TERMINALS='기동 직전
연기
중단
대상 변경'

# zone <file> <opening prefix> — the lines of the zone the prefix opens.
zone() {
  awk -v p="$2" '
    started == 0 { if (index($0, p) == 1) { started = 1; print } ; next }
    /^```/ { fence = !fence; print; next }
    fence == 0 && ($0 ~ /^\*\*5[a-n]( |\(|—)/ || $0 ~ /^(#|##|###|####) /) { exit }
    { print }
  ' "$1"
}

# The stdin filters below read to the end instead of exiting at their last
# line: under pipefail a reader that exits early can SIGPIPE the writer, and the
# assignment that holds the pipeline then fails the script.

# fence_of — the lines inside the first four-backtick fence of stdin.
fence_of() {
  awk '/^````/ { n++; next } n == 1 { print }'
}

# spans — the backticked `## …` spans of stdin, one per line, backticks off.
spans() {
  { grep -o '`## [^`]*`' || true; } | sed 's/^`//; s/`$//'
}

# block <heading> — the lines under a `## ` heading of stdin up to the next one.
block() {
  awk -v h="$1" '$0 == h { f = 1; next } /^## / { f = 0 } f { print }'
}

# minus <set> <remove> — lines of the first not in the second, order kept.
minus() {
  if [[ -z "$2" ]]; then printf '%s\n' "$1"; return; fi
  printf '%s\n' "$1" | grep -vxF -f <(printf '%s\n' "$2") || true
}

join_list() { printf '%s\n' "$1" | paste -sd '|' -; }

# has <needle> <text> — a fixed string in a text. A here-string rather than a
# pipe: under pipefail an early-exiting `grep -q` can SIGPIPE the writer and
# turn a match into a failure.
has() { grep -qF -- "$1" <<< "$2"; }

fail=0
flag() {
  # flag <n> <file> <message>
  echo "FAIL: [단언 $1] $2 — $3" >&2
  fail=1
}

# --- The source -----------------------------------------------------------
if [[ ! -f "$PS" ]]; then
  echo "FAIL: $PS — 없다 ; 인터뷰 기록 계약을 읽을 수 없다" >&2
  exit 2
fi
sec5=$(zone "$PS" '### 2b.5 ')
sec6=$(zone "$PS" '### 2b.6 ')
if [[ -z "$sec5" ]]; then
  echo "FAIL: $PS — ### 2b.5 절이 없다 ; 절 목록의 원천이 없다" >&2
  exit 2
fi
fence5=$(printf '%s\n' "$sec5" | fence_of)
C=$(printf '%s\n' "$fence5" | { grep '^## ' || true; })
T=$(printf '%s\n' "$fence5" | { grep -o 'cc-run-interview v[0-9][0-9]*' || true; } | sed -n 1p)
if [[ -z "$C" || -z "$T" ]]; then
  echo "FAIL: $PS — ### 2b.5 울타리에서 절 목록이나 버전 토큰을 뽑지 못했다 ; 원천이 없다" >&2
  exit 2
fi
X=$(printf '%s\n' "$sec5" | { grep '^\*\*Not read by the design stage\*\*' || true; } | spans)
prev_line=$(printf '%s\n' "$sec5" | { grep '^\*\*Previous version\*\*' || true; })
C1=$(printf '%s\n' "$prev_line" | spans)
T1=$(printf '%s\n' "$prev_line" | { grep -o 'cc-run-interview v[0-9][0-9]*' || true; } | sed -n 1p)
K=$(printf '%s\n' "$fence5" | block '## 배포 형상' | sed -n 's/^\*\*\([^*]*\)\*\*:.*/\1/p')
B=$(printf '%s\n' "$fence5" | block '## 확인된 요구' | sed -n 's/^\*\*\([^*]*\)\*\*:$/\1/p')

for f in "$AP" "$DDU" "$RI"; do
  [[ -f "$f" ]] || { echo "FAIL: $f — 없다 ; 절 목록을 대조할 쪽이 사라졌다" >&2; fail=1; }
done
if [[ "$fail" != "0" ]]; then
  echo "lint-interview-record-sections: violations found" >&2
  exit 1
fi

z5j=$(zone "$AP" '**5j — ')
z5m=$(zone "$AP" '**5m — ')
zs1=$(zone "$DDU" '### Step 1: ')

# --- 1. The header table carries T ------------------------------------------
row=$(grep '^| Interview record |' "$PS" || true)
case "$row" in
  *"\`$T\`"*) ;;
  *) flag 1 "$PS" "머리 표의 Interview record 행이 \`$T\` 를 담지 않는다" ;;
esac

# --- 2. The writer's list equals C ------------------------------------------
w_lines=$(printf '%s\n' "$z5m" | grep -F -- "$T" || true)
n=$(printf '%s\n' "$w_lines" | grep -c . || true)
if [[ "$n" != "1" ]]; then
  flag 2 "$AP" "5m 구역에 \`$T\` 를 담은 줄이 ${n}개다 ; 정확히 하나여야 쓰는 쪽 목록이 정해진다"
else
  W=$(printf '%s\n' "$w_lines" | spans)
  [[ "$W" == "$C" ]] || flag 2 "$AP" "5m 의 절 목록 「$(join_list "$W")」 이 계약 「$(join_list "$C")」 과 다르다"
fi

# --- 3. The reader's lists equal C − X and C1 − X ---------------------------
check_reader() {
  # check_reader <token> <expected>
  local lines cnt got
  lines=$(printf '%s\n' "$zs1" | grep -F -- "$1" || true)
  cnt=$(printf '%s\n' "$lines" | grep -c . || true)
  if [[ "$cnt" != "1" ]]; then
    flag 3 "$DDU" "Step 1 구역에 \`$1\` 을 담은 줄이 ${cnt}개다 ; 정확히 하나여야 읽는 쪽 목록이 정해진다"
    return
  fi
  got=$(printf '%s\n' "$lines" | spans)
  [[ "$got" == "$2" ]] || flag 3 "$DDU" "\`$1\` 목록 「$(join_list "$got")」 이 기대 「$(join_list "$2")」 과 다르다"
}
check_reader "$T" "$(minus "$C" "$X")"
if [[ -z "$T1" ]]; then
  flag 3 "$PS" "**Previous version** 줄에 옛 버전 토큰이 없다 ; 읽는 쪽 v1 목록을 대조할 수 없다"
else
  check_reader "$T1" "$(minus "$C1" "$X")"
fi

# --- 4. X and C1 sit inside C -----------------------------------------------
if [[ -z "$X" ]]; then
  flag 4 "$PS" "**Not read by the design stage** 줄에 \`## \` 절이 없다"
else
  extra=$(minus "$X" "$C")
  [[ -z "$extra" ]] || flag 4 "$PS" "읽지 않는 절 「$(join_list "$extra")」 이 계약의 절 목록에 없다"
fi
extra=$(minus "$C1" "$C")
[[ -z "$extra" ]] || flag 4 "$PS" "옛 버전의 절 「$(join_list "$extra")」 이 계약의 절 목록에 없다"

# --- 5. The options key is in all three -------------------------------------
has '**선택지**' "$fence5" || flag 5 "$PS" "### 2b.5 울타리에 **선택지** 가 없다"
has '**선택지**' "$z5j" || flag 5 "$AP" "5j 구역에 **선택지** 가 없다"
has '**선택지**' "$zs1" || flag 5 "$DDU" "Step 1 구역에 **선택지** 가 없다"

# --- 6. 5j asks every delivery-shape key ------------------------------------
while IFS= read -r k; do
  [[ -n "$k" ]] || continue
  has "**$k**" "$z5j" || flag 6 "$AP" "5j 구역이 배포 형상 키 **$k** 를 부르지 않는다"
done <<< "$K"

# --- 7. The read-back labels are the convention's ---------------------------
while IFS= read -r b; do
  [[ -n "$b" ]] || continue
  grep -qF -- "$b" "$RI" || flag 7 "$RI" "끝 되읽기 라벨 「${b}」 이 공유 규약에 없다"
done <<< "$B"

# --- 8. No count word in the design stage's list sentences ------------------
counted=$(grep -n -i -E '(one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|[0-9]+) (content sections|substitutions)' "$DDU" || true)
[[ -z "$counted" ]] || flag 8 "$DDU" "수 단어가 목록을 센다: $(printf '%s\n' "$counted" | sed -n 1p | cut -c1-120)"

# --- 9. The record governs ---------------------------------------------------
grep -qF 'the record governs' "$DDU" || flag 9 "$DDU" "「the record governs」 가 없다"

# --- 10. The kickoff trace token and its terminal set -----------------------
has "\`$KICKOFF_TOKEN\`" "$(grep '^| ' "$PS" || true)" || flag 10 "$PS" "머리 표에 \`$KICKOFF_TOKEN\` 이 없다"
has "$KICKOFF_TOKEN" "$(printf '%s\n' "$sec6" | fence_of)" || flag 10 "$PS" "### 2b.6 울타리에 $KICKOFF_TOKEN 이 없다"
grep -qF -- "$KICKOFF_TOKEN" "$AP" || flag 10 "$AP" "$KICKOFF_TOKEN 이 없다"
while IFS= read -r t; do
  has "\`$t\`" "$sec6" || flag 10 "$PS" "### 2b.6 이 끝남 단계 \`$t\` 를 담지 않는다"
done <<< "$TERMINALS"

# --- 11. The morning report is not a reader ---------------------------------
has 'morning report' "$(grep 'reader=' <<< "$fence5" || true)" \
  && flag 11 "$PS" "### 2b.5 울타리의 reader= 가 morning report 를 읽는 쪽으로 적는다"

if [[ "$fail" != "0" ]]; then
  echo "lint-interview-record-sections: violations found" >&2
  exit 1
fi
echo "OK:   interview record sections — 계약 $(printf '%s\n' "$C" | grep -c .)절, 쓰는 쪽·읽는 쪽 v2·v1 목록이 계약과 같다"
exit 0
