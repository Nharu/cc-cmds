#!/usr/bin/env bash
# run-leftovers.sh — what a run could not confirm and what is left for a person,
# derived from what the run already recorded.
#
#   run-leftovers.sh <manifest> <ledger> --run-dir <run-dir>
#
# WHAT THIS FILE IS. A termination clause whose evidence exists only after the
# run ends is settled `이관`: the run hands its material over to the morning
# report instead of meeting it. That material is this program's output. The
# gate runs it when it settles such a clause and keeps a copy of the output at
# `<run-dir>/clause-handover/<id>.md` with its digest on the ledger row; the
# morning report runs it again and copies its output verbatim into the section
# 「확인하지 못한 항목과 사람이 할 일」. One program for both, so the morning can
# hold what it reads against what the settlement recorded.
#
# THE SOURCES ARE CLOSED, five classes and nothing else, in this order:
#   1. 리뷰 P2       — per segment, the `## 🟡 P2 (차후 이슈 등록 권장)` section
#                      of the report its last `cycle` row names, one item per
#                      unindented `- ` line. When that row's `모드` is not
#                      `델타` (a full or a resolution review does not carry the
#                      earlier cycles' P2 over), every earlier report of the
#                      segment is read too, and a line seen before is printed
#                      once. A report without that heading holds no P2 item
#                      when its unindented `발견 요약` line counts zero P2;
#                      a count of one or more, or no line of that shape (the
#                      `발견 요약(부분 복구)` form included), is `[판독 실패]`.
#   2. 리뷰 미검토   — the `## 미검토 영역` section of that last report, one item
#                      per unindented `- ` line, or its first non-empty line
#                      when the section holds no such line. A report without
#                      that heading holds no item.
#   3. 미검증 잔여   — the `### R<n>.` blocks of the design document's
#                      `## 구현 시 검증 항목` whose grade still reads
#                      `구현 시 검증`.
#   4. 종료 절 답 첨부 — ledger `종료 절` rows whose `근거` names `첨부 <경로>`.
#   5. 정산된 종료 절 — clauses whose last `종료 절` row reads `불가능`, `보류`
#                      or `이관`.
# A source that cannot be read is an item (`[판독 실패]`), not a failure: only
# an unreadable manifest or ledger ends the program with a non-zero code, its
# reason on the first line of stderr.
#
# THE PERSON'S PART IS A FIXED SENTENCE per source class, never a judgment read
# off the finding.
#
# Relative paths resolve against `<manifest directory>/../..`, the root the
# morning report resolves them against. Headings are compared byte for byte
# (LC_ALL=C), never through the locale.
#
# It writes nothing — not to the ledger, not to the run directory.
#
# Exit codes: 0 printed; 2 usage error, or the manifest or the ledger
# unreadable — the reason on the first line of stderr, stdout empty. The gate
# keeps that line on an `이관` refusal and the morning report prints it.
#
# Compatibility: bash 3.2 — no associative arrays, no `mapfile`.

set -uo pipefail
export LC_ALL=C

RL_P2_HEAD='## 🟡 P2 (차후 이슈 등록 권장)'
RL_UNREVIEWED_HEAD='## 미검토 영역'
RL_SUMMARY_RE='^- \*\*발견 요약\*\*: 🔴 P0 [0-9]+건 \| 🟠 P1 [0-9]+건 \| 🟡 P2 ([0-9]+)건 \| 🟢 P3 [0-9]+건'
RL_TAIL='이 밖의 사람 몫은 「기다리는 결정」·「보류 큐」·「남은 외부 상태」·「사람 대조 필요」 절에 있습니다'
RL_EMPTY='확인하지 못한 항목이 원장과 디스크에 없습니다'
RL_HANDOVER_RE='^종단 재료 (.+) · sha256 ([0-9a-f]{64}) · 항목 ([0-9]+)건 · 판별 (표지|문면 런 보고서에서 읽|문면 아침 보고서에서 읽)$'

rl_fail() { printf 'run-leftovers: %s\n' "$1" >&2; exit 2; }

MANIFEST=''
LEDGER=''
RUN_DIR=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --run-dir) [ "$#" -ge 2 ] || rl_fail '--run-dir needs a value'; RUN_DIR=$2; shift 2 ;;
    --*) rl_fail "unknown option: $1" ;;
    *)
      if [ -z "$MANIFEST" ]; then MANIFEST=$1
      elif [ -z "$LEDGER" ]; then LEDGER=$1
      else rl_fail "unexpected argument: $1"; fi
      shift ;;
  esac
done
[ -n "$MANIFEST" ] && [ -n "$LEDGER" ] \
  || rl_fail 'usage: run-leftovers.sh <manifest> <ledger> --run-dir <run-dir>'
[ -f "$MANIFEST" ] && [ -r "$MANIFEST" ] || rl_fail "the manifest cannot be read: $MANIFEST"
[ -f "$LEDGER" ] && [ -r "$LEDGER" ] || rl_fail "the ledger cannot be read: $LEDGER"

RL_ROOT=$(cd "$(dirname "$MANIFEST")/../.." 2>/dev/null && pwd) || RL_ROOT=''
if [ -n "$RUN_DIR" ]; then
  RL_RUN_ID=$(basename "$RUN_DIR")
else
  RL_RUN_ID=$(basename "$LEDGER" .md)
fi

# ---------------------------------------------------------------------------
# Helpers — pure text work.
# ---------------------------------------------------------------------------
rl_field() {
  # rl_field <row> <key> — the last value with that key in one `|`-separated
  # row, trailing spaces dropped.
  printf '%s' "$1" | tr '|' '\n' | sed -n "s/^ *$2=//p" | sed 's/[[:space:]]*$//' | tail -1
}

rl_has_field() {
  # rl_has_field <row> <key> — exit 0 when the row carries the key at all.
  printf '%s' "$1" | tr '|' '\n' | grep -q "^ *$2="
}

rl_cut() {
  # rl_cut <text> — the text cut at 160 characters (a byte outside 0x80-0xBF
  # starts a character).
  printf '%s' "$1" | awk '
    BEGIN { for (i = 128; i < 256; i++) cont[sprintf("%c", i)] = (i < 192) }
    { s = (NR > 1 ? s "\n" : "") $0 }
    END {
      n = 0; res = ""
      for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (!(c in cont) || !cont[c]) { n++; if (n > 160) break }
        res = res c
      }
      printf "%s", res
    }'
}

rl_resolve() {
  # rl_resolve <path> — an absolute path as it is, a relative one under the
  # root.
  case "$1" in
    /*) printf '%s' "$1" ;;
    *) printf '%s/%s' "$RL_ROOT" "$1" ;;
  esac
}

rl_section_lines() {
  # rl_section_lines <file> <heading> — `<line>\t<text>` for every line inside
  # the section the heading opens, up to the next `## ` heading; exit 1 when
  # the heading line is not in the file.
  awk -v h="$2" '
    found && /^## / { exit }
    found { printf "%d\t%s\n", NR, $0 }
    !found && $0 == h { found = 1 }
    END { exit (found ? 0 : 1) }' "$1"
}

ITEMS=''
rl_item() { ITEMS="${ITEMS}${1}
"; }
rl_unreadable() { rl_item "- [판독 실패] $1 · $2 · $3"; }

LEDGER_ROWS=$(grep -n -E '^- `(cycle|종료 절)` \|' "$LEDGER" 2>/dev/null || true)
CYCLE_ROWS=$(printf '%s\n' "$LEDGER_ROWS" | grep -E '^[0-9]+:- `cycle` \|' || true)
CLAUSE_ROWS=$(printf '%s\n' "$LEDGER_ROWS" | grep -E '^[0-9]+:- `종료 절` \|' || true)
SEGMENTS=$(printf '%s\n' "$CYCLE_ROWS" | while IFS= read -r r; do
  [ -n "$r" ] || continue
  rl_field "${r#*:}" '세그먼트'; printf '\n'
done | awk 'NF && !seen[$0]++')

# ---------------------------------------------------------------------------
# 1. 리뷰 P2 and 2. 리뷰 미검토
# ---------------------------------------------------------------------------
rl_segment_reports() {
  # rl_segment_reports <segment> — the report paths whose P2 this segment
  # still owes, one per line: the last row's report alone when that row is a
  # delta review (it carries its basis's P2 over), else every report of the
  # segment in ledger order, the last one included.
  local seg="$1" r last='' mode
  last=$(printf '%s\n' "$CYCLE_ROWS" | while IFS= read -r r; do
    [ -n "$r" ] || continue
    [ "$(rl_field "${r#*:}" '세그먼트')" = "$seg" ] && printf '%s\n' "${r#*:}"
  done | tail -1)
  mode=$(rl_field "$last" '모드')
  if [ "$mode" = "델타" ]; then
    rl_field "$last" '리포트 경로'; printf '\n'
    return 0
  fi
  printf '%s\n' "$CYCLE_ROWS" | while IFS= read -r r; do
    [ -n "$r" ] || continue
    [ "$(rl_field "${r#*:}" '세그먼트')" = "$seg" ] || continue
    rl_field "${r#*:}" '리포트 경로'; printf '\n'
  done | awk '!seen[$0]++'
}

rl_last_report() {
  # rl_last_report <segment> — the report path of the segment's last cycle row.
  local seg="$1" r
  printf '%s\n' "$CYCLE_ROWS" | while IFS= read -r r; do
    [ -n "$r" ] || continue
    [ "$(rl_field "${r#*:}" '세그먼트')" = "$seg" ] && rl_field "${r#*:}" '리포트 경로' && printf '\n'
  done | sed '/^$/d' | tail -1
}

seen_p2=''
for seg in $SEGMENTS; do
  seen_p2=''
  while IFS= read -r rp; do
    if [ -z "$rp" ] || [ "$rp" = "-" ]; then
      rl_unreadable '리뷰 P2' "세그먼트 $seg" '마지막 cycle 행에 리포트 경로가 없습니다'
      continue
    fi
    f=$(rl_resolve "$rp")
    if [ ! -f "$f" ] || [ ! -r "$f" ]; then
      rl_unreadable '리뷰 P2' "$f" '리뷰 보고서를 읽지 못했습니다'
      continue
    fi
    sec=$(rl_section_lines "$f" "$RL_P2_HEAD") || {
      # A report with no P2 finding writes no P2 section, so a missing heading
      # is read against the report's own count: zero P2 is zero items.
      p2n=$(grep -E "$RL_SUMMARY_RE" "$f" 2>/dev/null | sed -n '1p' | sed -E "s/$RL_SUMMARY_RE.*/\\1/")
      case "$p2n" in
        0) ;;
        '') rl_unreadable '리뷰 P2' "$f" "표제 「${RL_P2_HEAD}」 이 없고 발견 요약 줄의 P2 수를 읽지 못했습니다" ;;
        *) rl_unreadable '리뷰 P2' "$f" "표제 「${RL_P2_HEAD}」 이 없는데 발견 요약의 P2 가 ${p2n}건입니다" ;;
      esac
      continue; }
    while IFS= read -r ln; do
      [ -n "$ln" ] || continue
      n=${ln%%	*}; t=${ln#*	}
      case "$t" in '- '*) ;; *) continue ;; esac
      t=${t#- }
      case "$seen_p2" in *"
$t
"*) continue ;; esac
      seen_p2="${seen_p2:-
}$t
"
      rl_item "- [리뷰 P2] 세그먼트 $seg · $(rl_cut "$t") · 사람 몫: 후속 이슈로 올릴지 정한다 · 출처 $f:$n"
    done <<EOF
$sec
EOF
  done <<EOF
$(rl_segment_reports "$seg")
EOF
done

for seg in $SEGMENTS; do
  rp=$(rl_last_report "$seg")
  if [ -z "$rp" ] || [ "$rp" = "-" ]; then
    rl_unreadable '리뷰 미검토' "세그먼트 $seg" '마지막 cycle 행에 리포트 경로가 없습니다'
    continue
  fi
  f=$(rl_resolve "$rp")
  if [ ! -f "$f" ] || [ ! -r "$f" ]; then
    rl_unreadable '리뷰 미검토' "$f" '리뷰 보고서를 읽지 못했습니다'
    continue
  fi
  # A report with nothing unreviewed skips this heading, and there is no count
  # to hold it against, so a missing heading is zero items.
  sec=$(rl_section_lines "$f" "$RL_UNREVIEWED_HEAD") || continue
  listed=$(printf '%s\n' "$sec" | awk -F'\t' 'NF && substr($2, 1, 2) == "- "')
  if [ -z "$listed" ]; then
    listed=$(printf '%s\n' "$sec" | awk -F'\t' 'NF { t = $2; sub(/^[[:space:]]+/, "", t); if (t != "") { print; exit } }')
  fi
  while IFS= read -r ln; do
    [ -n "$ln" ] || continue
    n=${ln%%	*}; t=${ln#*	}
    t=${t#- }
    t=$(printf '%s' "$t" | sed 's/^[[:space:]]*//')
    rl_item "- [리뷰 미검토] 세그먼트 $seg · $(rl_cut "$t") · 사람 몫: 이 범위를 따로 볼지 정한다 · 출처 $f:$n"
  done <<EOF
$listed
EOF
done

# ---------------------------------------------------------------------------
# 3. 미검증 잔여
# ---------------------------------------------------------------------------
# A VALUE THAT POINTS AT NO FILE IS NOT A READ FAILURE. `(없음)`, no
# `**설계 문서**` line at all, and a path found at neither place all mean a run
# whose design document does not exist yet — the design stage stopped before
# writing it — so the class holds no item. `[판독 실패]` is kept for a file
# that exists and cannot be read.
dv=$(sed -n 's/^\*\*설계 문서\*\*: *//p' "$MANIFEST" | sed -n '1p' | sed 's/[[:space:]]*$//')
doc=''
if [ -n "$dv" ] && [ "$dv" != "(없음)" ]; then
  if [ -f "$RL_ROOT/$dv" ]; then doc="$RL_ROOT/$dv"
  elif [ -f "/$dv" ]; then doc="/$dv"
  fi
fi
if [ -n "$doc" ]; then
  if [ ! -r "$doc" ]; then
    rl_unreadable '미검증 잔여' "$doc" '설계 문서를 읽지 못했습니다'
  else
    # One line per open item: `<line>\t<id>\t<title>\t<class>`. The grade, the
    # blocker class and the residual reason are read by the detection grammar
    # `^(- )?(\*\*<key>\*\*|<key>): <value>$`; the pairing rule is the
    # verification contract's: no class line on `구현 필요` reads `코드-부재`,
    # `코드-부재` pairs with `구현 필요`, `사람-환경` and `외부-준비` with
    # `검증 차단`, and anything else reads `미분류`.
    res=$(awk '
      function flush() {
        if (id != "" && open) {
          cls = "미분류"
          if (!hascls) { if (reason == "구현 필요") cls = "코드-부재" }
          else if (blk == "코드-부재" && reason == "구현 필요") cls = "코드-부재"
          else if ((blk == "사람-환경" || blk == "외부-준비") && reason == "검증 차단") cls = blk
          printf "%d\t%s\t%s\t%s\n", hl, id, title, cls
        }
        id = ""; open = 0; hascls = 0; blk = ""; reason = ""
      }
      function val(line, key,   re) {
        re = "^(- )?(\\*\\*" key "\\*\\*|" key "): "
        if (match(line, re)) return substr(line, RLENGTH + 1)
        return "\001"
      }
      /^```/ { fence = !fence; next }
      fence { next }
      /^## / { flush(); insec = ($0 == "## 구현 시 검증 항목"); next }
      !insec { next }
      /^### R[0-9]+\./ {
        flush()
        hl = NR
        h = substr($0, 5)
        id = h; sub(/\..*/, "", id)
        title = substr(h, length(id) + 2); sub(/^ +/, "", title)
        next
      }
      /^### / { flush(); next }
      id != "" {
        v = val($0, "검증 등급"); if (v != "\001" && v == "구현 시 검증") open = 1
        v = val($0, "차단 부류"); if (v != "\001") { hascls = 1; blk = v }
        v = val($0, "잔여 사유"); if (v != "\001") reason = v
      }
      END { flush() }' "$doc")
    while IFS= read -r ln; do
      [ -n "$ln" ] || continue
      n=$(printf '%s' "$ln" | cut -f1)
      rid=$(printf '%s' "$ln" | cut -f2)
      title=$(printf '%s' "$ln" | cut -f3)
      cls=$(printf '%s' "$ln" | cut -f4)
      case "$cls" in
        사람-환경|외부-준비) who='머지 뒤 사람이 레시피로 확인한다' ;;
        *) who='다음 런이나 사람이 레시피로 확인한다' ;;
      esac
      rl_item "- [미검증 잔여] $rid${title:+ $title} · 차단 부류 $cls · 사람 몫: $who · 출처 $doc:$n"
    done <<EOF
$res
EOF
  fi
fi

# ---------------------------------------------------------------------------
# 4. 종료 절 답 첨부
# ---------------------------------------------------------------------------
while IFS= read -r r; do
  [ -n "$r" ] || continue
  row=${r#*:}
  why=$(rl_field "$row" '근거')
  case "$why" in *'첨부 '*) ;; *) continue ;; esac
  att=${why#*첨부 }
  att=${att%% · *}
  rl_item "- [종료 절 답 첨부] 절 $(rl_field "$row" 'id') · 사람 몫: 첨부가 적은 확인하지 못한 것을 본다 · 출처 $att"
done <<EOF
$CLAUSE_ROWS
EOF

# ---------------------------------------------------------------------------
# 5. 정산된 종료 절 — in the ledger order of each clause's last row.
# ---------------------------------------------------------------------------
lasts=$(printf '%s\n' "$CLAUSE_ROWS" | while IFS= read -r r; do
  [ -n "$r" ] || continue
  printf '%s\t%s\n' "$(rl_field "${r#*:}" 'id')" "$r"
done | awk -F'\t' 'NF { last[$1] = $2; if (!($1 in seen)) { seen[$1] = 1; order[++k] = $1 } }
  END { for (i = 1; i <= k; i++) print last[order[i]] }' | sort -t: -k1,1n)
while IFS= read -r r; do
  [ -n "$r" ] || continue
  ln=${r%%:*}; row=${r#*:}
  cid=$(rl_field "$row" 'id')
  st=$(rl_field "$row" '상태')
  case "$st" in
    불가능) who='이 런에서 얻지 못한 결과를 다음 런이나 사람이 얻는다' ;;
    보류) who='걸린 질문에 답한다' ;;
    이관) who='' ;;
    *) continue ;;
  esac
  mrow=$(grep -E '^- `종료 절` \|' "$MANIFEST" 2>/dev/null | grep -F "id=$cid " | sed -n '1p')
  wd=$(rl_field "$mrow" '문면')
  tail=''
  if [ "$st" = "이관" ]; then
    why=$(rl_field "$row" '근거')
    hp=$(printf '%s' "$why" | sed -E -n "s/$RL_HANDOVER_RE/\\1/p")
    if [ -z "$hp" ]; then
      rl_item "- [종료 절] $cid $st · $wd · 사람 몫: 이 목록의 다른 항목으로 확인한다 · 출처 원장 $ln"
      rl_unreadable '정산된 종료 절' "원장 $ln" '이관 근거가 정해진 꼴이 아닙니다'
      continue
    fi
    hs=$(printf '%s' "$why" | sed -E -n "s/$RL_HANDOVER_RE/\\2/p")
    hn=$(printf '%s' "$why" | sed -E -n "s/$RL_HANDOVER_RE/\\3/p")
    hb=$(printf '%s' "$why" | sed -E -n "s/$RL_HANDOVER_RE/\\4/p")
    if [ -f "$hp" ]; then
      if [ "$(shasum -a 256 "$hp" 2>/dev/null | cut -d' ' -f1)" = "$hs" ]; then cmp=일치; else cmp=바뀜; fi
    else
      cmp=없음
    fi
    who="이 목록의 다른 항목으로 확인한다 — 정산 때 항목 ${hn}건"
    tail=" · 정산 재료 $hp ($cmp) · 판별 $hb"
  fi
  rl_item "- [종료 절] $cid $st · $wd · 사람 몫: $who · 출처 원장 $ln$tail"
done <<EOF
$lasts
EOF

# ---------------------------------------------------------------------------
# Output. The count is the number of `- [` lines, `[판독 실패]` included.
# ---------------------------------------------------------------------------
count=$(printf '%s' "$ITEMS" | grep -c '^- \[' || true)
count=${count:-0}
printf '남김 목록 — 런 %s · 항목 %s건\n' "$RL_RUN_ID" "$count"
if [ "$count" = "0" ]; then
  printf '%s\n' "$RL_EMPTY"
else
  printf '%s' "$ITEMS"
fi
printf '%s\n' "$RL_TAIL"
exit 0
