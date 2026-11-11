#!/usr/bin/env bash
# run-stops.sh — the stop events of one settled run, derived from what the run
# already recorded.
#
#   run-stops.sh <ledger> <run-dir> [--manifest <path>] [--by-fix-site]
#   run-stops.sh --vocab <table>
#   run-stops.sh --predicate target-stop <ledger> <alias>
#   run-stops.sh --predicate external-hold <ledger> <segment>
#   run-stops.sh --predicate remeasure-refused <ledger> <segment> <R number>
#
# One line per event on stdout, tab-separated:
#
#   <서명> <TAB> <의도|비의도> <TAB> <제외 사유|-> <TAB> <표지|->
#
# With `--by-fix-site` the intended events are left out and every other event
# is one line of five columns, deduplicated on all five:
#
#   <고칠 곳> <TAB> <판정 주체|-> <TAB> <서명> <TAB> <신원|-> <TAB> <신호 또는 근거|->
#
# The fix site is read, in this order, from the segment's park rows since its
# last row in any other state (the last one carrying `고칠 곳`), the stop's
# `blocked` row, the last `중단 답` row whose `중단 기록` names the stop's halt
# record, and that halt record's `**관측 상세**`; found nowhere, it is
# `판정 불가`. A stop whose identity is `-` skips the segment and the record.
# Tabs and newlines in every column are written as one space.
#
# `--predicate` reads the ledger and writes nothing. It exits 0 and prints what
# holds the stop when the predicate is true, and exits 1 when it is false:
#   target-stop        the segment whose `park 적용=불명` row carries the target
#                      defect signal for <alias> and is not yet settled
#   external-hold      the line of the `라우팅=외부-보류` or `라우팅=원인-보류`
#                      answer whose segment park still holds
#   remeasure-refused  that line, when the answer's `측정 등급` names <R number>
#
# `서명` is `<부류>/<사유>[/<종류>]` and every slot comes from a closed table
# below; a value outside its table folds to `미분류` rather than being copied.
# `제외 사유` names which of the five intended waits an `의도` line is
# (`비용 천장` · `사전 인가 밖` · `설계 판단` · `자유 입력` · `외부 대기`, the
# last a `precondition-failed` halt whose `**스텝**` starts with
# `Step 1 외부 선행 미충족`: a wait on another pull request or release). `표지` is
# `원인 셀 미결합` on a gate-unanswerable halt no reach park binds to, and
# `열린 대기 아님` on an intended event that was a decision rather than a wait,
# for which no skip row is written. Resolved events are not printed at all.
#
# WHAT THIS DOES NOT DO, and each is a boundary rather than a gap. It never
# calls `gh` and holds no credential: the gate is the only writer of an issue.
# It writes nothing — not to the ledger, not to the run directory. And it reads
# no free text: a reason or a question is never parsed, because a
# classification read off prose changes when the prose does. Of a halt record's
# `**관측 상세**` only one part is read: it is split on ` / `, and the first
# part starting `고칠 곳=` that comes before the first part starting
# `고칠 곳 근거=` gives the fix site. From that `고칠 곳 근거=` part to the end
# is an excerpt, shown in the fifth column and never classified, so a
# ` / 고칠 곳=<값>` inside it changes nothing; a value outside the closed set
# reads `판정 불가`. The inputs are tokens the gate, the watcher and the driver
# wrote.
#
# WHY A SEPARATE FILE. Every event class here can be pinned against a fixture
# ledger without starting a gate, which is how `scripts/test-run-stops.sh`
# covers the whole table.
#
# Compatibility: bash 3.2 — no associative arrays, no `mapfile`.

set -uo pipefail

RUN_STOPS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)

# THE CLOSED TABLES. Each is one token per line so a test can read
# it with `--vocab` and hold it against the literals the writers use.
RUN_STOPS_RUN_BLOCKED='라이브니스 침묵
스테이지 종단 후 라우터 무응답
세그먼트 미개시
강제 표면 이동
인벤토리 기준선 루트 불일치
인벤토리 스냅숏 손상
살아 있는 인벤토리 손상
인벤토리 검사 불가
인벤토리 스냅숏 게시 실패
게이트 park'
RUN_STOPS_STAGE='크래시
공허한 성공
산출물 없는 정지
적용 불명
외부 종료
한도-형상 회수
한도 종료'
RUN_STOPS_HALT='tool-unavailable
gate-unanswerable
freeze-mismatch
precondition-failed'
RUN_STOPS_KINDS='design
implement
review
audit
reconverge
generic
shift
split
visual
visual-publish'
RUN_STOPS_BOUNDARY='B1
B2
B3
B4
SHIFT-FLOOR'
# The four reach cells a person alone can open; a park on one of them is the
# intended wait "사전 인가 밖", not a defect.
RUN_STOPS_INTENDED_CELLS='prod인가없음
배포트리거인가없음
파괴형태미명시
dev대조불가'
# The reportable park cells: the reach vocabulary minus the four cells above.
# `등급회귀`·`등급회귀판정불가` are absent on purpose and fold to `미분류`.
RUN_STOPS_PARK='비밀출력
신고등급한도
도달미상
기기전역
push원격불일치
도달모순
dev파괴
dev식별자불일치
dev식별자부재
CI실패
대상 미선언
행값충돌'
RUN_STOPS_CUTPOINTS='커밋
브랜치
push
PR
머지
배포
머지후착수'
# The prefix of an act-scope block the apply act writes for a target whose
# apply is stopped. The alias follows it, so it is matched as a prefix.
RUN_STOPS_ACT_STOP='대상 적용 정지'
# The closed set of `고칠 곳`. `판정 불가` is also what a stop with no
# judgment anywhere reads.
RUN_STOPS_FIX_SITE='런
대상 레포
외부 서비스
판정 불가'
# The signal the apply supervisor stamps on a `park 적용=불명` row when the
# command exited 0 and the probe still reads 「필요」.
RUN_STOPS_TARGET_SIGNAL='종료 코드·사후 프로브 불일치'

run_stops_vocab() {
  case "$1" in
    act-stop)    printf '%s\n' "$RUN_STOPS_ACT_STOP" ;;
    fix-site)    printf '%s\n' "$RUN_STOPS_FIX_SITE" ;;
    run-blocked) printf '%s\n' "$RUN_STOPS_RUN_BLOCKED" ;;
    stage)       printf '%s\n' "$RUN_STOPS_STAGE" ;;
    halt)        printf '%s\n' "$RUN_STOPS_HALT" ;;
    kinds)       printf '%s\n' "$RUN_STOPS_KINDS" ;;
    boundary)    printf '%s\n' "$RUN_STOPS_BOUNDARY" ;;
    cells)       printf '%s\n' "$RUN_STOPS_INTENDED_CELLS" ;;
    park)        printf '%s\n' "$RUN_STOPS_PARK" ;;
    cutpoints)   printf '%s\n' "$RUN_STOPS_CUTPOINTS" ;;
    *) printf 'run-stops.sh: unknown table %s\n' "$1" >&2; return 2 ;;
  esac
}

run_stops_ceiling() {
  # The declared cost ceiling of the manifest, or nothing when it is absent or
  # does not read as a plain figure — the same reading `gate_b4_percent` gives.
  local m="$1" v
  [ -n "$m" ] && [ -f "$m" ] || return 0
  v=$(awk '
    $0 == "## 인가" { inb=1; next }
    inb && /^## / { exit }
    inb && /^\*\*비용 천장\*\*: / { sub(/^\*\*비용 천장\*\*: /, ""); print; exit }
  ' "$m" 2>/dev/null || true)
  case "$v" in ''|없음|'(없음)'|*[!0-9.]*|*.*.*|*.) return 0 ;; esac
  printf '%s' "$v"
}

# THE AWK FIELD READER the predicates share with the event pass: a field of a
# `|`-separated ledger row, by key, trimmed.
RUN_STOPS_AWK_FLD='
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    function fld(k,   i, p) {
      for (i = 2; i <= NF; i++) {
        p = trim($i)
        if (index(p, k "=") == 1) return substr(p, length(k) + 2)
      }
      return ""
    }
    function series_of(   r) {
      if (!match($0, /^- `[^`]*`/)) return ""
      return substr($0, 4, RLENGTH - 4)
    }
'

run_stops_target_stop() {
  # run_stops_target_stop <ledger> <alias> — the apply of <alias> is stopped.
  # A `park 적용=불명` segment row naming the alias and carrying the target
  # defect signal sets the stop for that segment. A later `완료` row of the
  # same segment — the settlement's `완료 적용=정산`, or the completion after a
  # rerun or a person's settlement — releases it, and so does a person's
  # `세그먼트 park` answer for that segment, whether it picked an option of the
  # record or the fixed label a record without options is answered with. Prints
  # the segments still holding
  # it, in the order they were stopped; 0 when there is one, 1 when none.
  local ledger="$1" alias="$2"
  [ -n "$ledger" ] && [ -f "$ledger" ] && [ -n "$alias" ] || return 1
  RS_ALIAS="$alias" RS_SIG="$RUN_STOPS_TARGET_SIGNAL" awk -F'|' "$RUN_STOPS_AWK_FLD"'
    BEGIN { a = ENVIRON["RS_ALIAS"]; sig = ENVIRON["RS_SIG"] }
    {
      sr = series_of()
      if (sr == "segment") {
        s = fld("id"); st = fld("상태")
        if (st == "park" && fld("적용") == "불명" && fld("판정 신호") == sig && fld("대상") == a) {
          if (!(s in ORD)) { n++; ORD[s] = n; ID[n] = s }
          HOLD[s] = 1
        } else if (st == "완료" && (s in HOLD)) delete HOLD[s]
      } else if (sr == "중단 답") {
        s = fld("세그먼트")
        if ((s in HOLD) && fld("선택지") == "세그먼트 park" && fld("답한 주체") == "사람") delete HOLD[s]
      }
    }
    END {
      for (i = 1; i <= n; i++) if (ID[i] in HOLD) { print ID[i]; hit = 1 }
      exit hit ? 0 : 1
    }
  ' "$ledger"
}

run_stops_external_hold() {
  # run_stops_external_hold <ledger> <segment> [<R number>] — the segment is
  # parked on an answer the gate routed `외부-보류`, or `원인-보류` — the fixed
  # `세그먼트 park` answer to a halt record that offers no options, which holds
  # the segment until its cause outside the run is gone. The hold is set by the
  # segment's `park` row after such an answer, and released by a person's
  # answer to the same halt record, by the seat's answer to it that a matching
  # confirmation admitted (`해소 확인=일치`), or by a `한도 해제` row after that
  # park.
  # Prints the ledger line of the answer and exits 0 while it holds. With an R
  # number it holds only when that answer's `측정 등급` names the item.
  local ledger="$1" seg="$2" rn="${3:-}"
  [ -n "$ledger" ] && [ -f "$ledger" ] && [ -n "$seg" ] || return 1
  RS_SEG="$seg" RS_RN="$rn" awk -F'|' "$RUN_STOPS_AWK_FLD"'
    BEGIN { seg = ENVIRON["RS_SEG"]; rn = ENVIRON["RS_RN"] }
    {
      sr = series_of()
      if (sr == "중단 답") {
        if (fld("세그먼트") != seg) next
        if (fld("라우팅") == "외부-보류" || fld("라우팅") == "원인-보류") {
          al = NR; arec = fld("중단 기록"); agr = fld("측정 등급"); held = 0
        } else if (al && fld("중단 기록") == arec && (fld("답한 주체") == "사람" || fld("해소 확인") == "일치")) {
          al = 0; held = 0
        }
      } else if (sr == "segment") {
        if (fld("id") == seg && al && fld("상태") == "park") held = 1
      } else if (sr == "한도 해제") {
        if (held) { al = 0; held = 0 }
      }
    }
    END {
      if (!(al && held)) exit 1
      if (rn != "") {
        n = split(agr, G, ",")
        for (i = 1; i <= n; i++) { g = G[i]; gsub(/^[ \t]+|[ \t]+$/, "", g); sub(/:.*/, "", g); if (g == rn) found = 1 }
        if (!found) exit 1
      }
      print al
      exit 0
    }
  ' "$ledger"
}

run_stops_predicate() {
  # run_stops_predicate <kind> <args>... — the read-only predicate mode.
  case "${1:-}" in
    target-stop)       [ $# -eq 3 ] || { printf 'run-stops.sh: usage: --predicate target-stop <ledger> <alias>\n' >&2; return 2; }
                       run_stops_target_stop "$2" "$3" ;;
    external-hold)     [ $# -eq 3 ] || { printf 'run-stops.sh: usage: --predicate external-hold <ledger> <segment>\n' >&2; return 2; }
                       run_stops_external_hold "$2" "$3" ;;
    remeasure-refused) [ $# -eq 4 ] || { printf 'run-stops.sh: usage: --predicate remeasure-refused <ledger> <segment> <R number>\n' >&2; return 2; }
                       [ -n "$4" ] || return 1
                       run_stops_external_hold "$2" "$3" "$4" ;;
    *) printf 'run-stops.sh: unknown predicate %s\n' "${1:-}" >&2; return 2 ;;
  esac
}

run_stops_detail_fix() {
  # run_stops_detail_fix <halt record> — `<고칠 곳>\t<발췌>` from the record's
  # `**관측 상세**`, read by the boundary the header states; empty columns
  # when it carries neither.
  awk '
    index($0, "**관측 상세**: ") == 1 {
      rest = substr($0, length("**관측 상세**: ") + 1); fix = ""; ex = ""
      while (rest != "") {
        i = index(rest, " / ")
        if (i) { part = substr(rest, 1, i - 1); nxt = substr(rest, i + 3) } else { part = rest; nxt = "" }
        if (index(part, "고칠 곳 근거=") == 1) { ex = substr(rest, length("고칠 곳 근거=") + 1); break }
        if (fix == "" && index(part, "고칠 곳=") == 1) fix = substr(part, length("고칠 곳=") + 1)
        rest = nxt
      }
      sub(/^[ \t]+/, "", fix); sub(/[ \t]+$/, "", fix)
      gsub(/\t/, " ", ex); gsub(/\t/, " ", fix)
      printf "%s\t%s", fix, ex
      exit
    }
  ' "$1" 2>/dev/null || true
}

run_stops_main() {
  local ledger="" run_dir="" manifest="" halts shalts ceiling blocked f id cls ext tail byfix="" tstop="" a
  if [ "${1:-}" = "--vocab" ]; then
    run_stops_vocab "${2:-}"; return $?
  fi
  if [ "${1:-}" = "--predicate" ]; then
    shift; run_stops_predicate "$@"; return $?
  fi
  ledger="${1:-}"; run_dir="${2:-}"; shift 2 2>/dev/null || true
  while [ $# -gt 0 ]; do
    case "$1" in
      --manifest) manifest="${2:-}"; shift 2 ;;
      --by-fix-site) byfix=1; shift ;;
      *) printf 'run-stops.sh: unknown argument %s\n' "$1" >&2; return 2 ;;
    esac
  done
  if [ -z "$ledger" ] || [ ! -f "$ledger" ]; then
    printf 'run-stops.sh: usage: run-stops.sh <ledger> <run-dir> [--manifest <path>]\n' >&2
    return 2
  fi

  # shellcheck source=liveness.sh
  . "$RUN_STOPS_DIR/liveness.sh"

  # HALT RECORDS: only the file name, the `**분류**` line and the head of the
  # `**스텝**` line are read, so a record that offers no options is a stop like
  # any other. A `precondition-failed` record whose step starts with
  # `Step 1 외부 선행 미충족` carries `외부` in the third column, every other
  # record `-`. Two names
  # in that directory are not this run's halt records: the copy an adopted
  # segment carries over from the run that wrote it (`<seg>#adopted-<run>.md`),
  # which that run reports under its own kind, and an attachment — the answer
  # a seat wrote beside a record (`*.answer.md`) or the attachment an adopted
  # copy carries (`*.attach.md`) — which is no halt record at all.
  halts=""
  if [ -n "$run_dir" ] && [ -d "$run_dir/halt" ]; then
    for f in "$run_dir"/halt/*.md; do
      [ -f "$f" ] || continue
      case "${f##*/}" in *'#adopted-'*|*.answer.md|*.attach.md) continue ;; esac
      id=${f##*/}; id=${id%.md}
      cls=$( { grep -m1 -E '^\*\*분류\*\*: ' "$f" 2>/dev/null || true; } \
             | sed 's/^\*\*분류\*\*: //; s/[[:space:]]*$//')
      [ -n "$cls" ] || continue
      ext=-
      if [ "$cls" = "precondition-failed" ]; then
        case "$( { grep -m1 -E '^\*\*스텝\*\*: ' "$f" 2>/dev/null || true; } | sed 's/^\*\*스텝\*\*: //')" in
          'Step 1 외부 선행 미충족'*) ext=외부 ;;
        esac
      fi
      halts="${halts}$(printf '%s\t%s\t%s\t%s' "$id" "$cls" "$ext" "$(run_stops_detail_fix "$f")")
"
    done
  fi

  # SHIFT HALT RECORDS: a routing shift's stop writes its question one level
  # down, `halt/shift/<seg>#<n>.md`, and leaves behind no stage-result, no
  # approval and no segment park — only a cone row anchored on the segment,
  # which the fold drops, and at `도달 거부` the reach park row of the act that
  # was refused, which binds the record below. The record is the one trace of
  # that wait, so it is read here,
  # and it is unresolved until a `중단 답` row answers it, judged by the same
  # helper `cc_unanswered_halts` uses: the two readers of "does a person still
  # owe this run an answer" cannot disagree.
  shalts=""
  if [ -n "$run_dir" ] && [ -d "$run_dir/halt/shift" ]; then
    for f in "$run_dir"/halt/shift/*.md; do
      [ -f "$f" ] || continue
      case "${f##*/}" in *.answer.md) continue ;; esac
      tail="${run_dir%/}"; tail="/${tail##*/}/halt/shift/${f##*/}"
      cc_halt_answered "$ledger" "$tail" && continue
      id=${f##*/}; id=${id%.md}
      cls=$( { grep -m1 -E '^\*\*분류\*\*: ' "$f" 2>/dev/null || true; } \
             | sed 's/^\*\*분류\*\*: //; s/[[:space:]]*$//')
      [ -n "$cls" ] || continue
      shalts="${shalts}$(printf '%s\t%s\t%s' "$id" "$cls" "$(run_stops_detail_fix "$f")")
"
    done
  fi

  # TARGET STOPS STILL HOLDING: the act-scope `대상 적용 정지 <별칭>` blocks are
  # read by alias, and an alias whose stop the predicate no longer reads as
  # holding has its blocks left out.
  while IFS= read -r a; do
    [ -n "$a" ] || continue
    run_stops_target_stop "$ledger" "$a" >/dev/null && tstop="${tstop}${a}
"
  done <<EOF
$(RS_P="$RUN_STOPS_ACT_STOP " awk -F'|' "$RUN_STOPS_AWK_FLD"'
    series_of() == "blocked" && fld("스코프") == "act" && index(fld("사유"), ENVIRON["RS_P"]) == 1 { print fld("대상") }
  ' "$ledger" | sort -u)
EOF

  # RUN-SCOPE BLOCKS: the ledger's unresolved ones, by the same fold every other
  # reader uses, plus the watcher observations not yet transcribed. The fold
  # also keeps cone rows anchored on a run-scope step — a deadline park on the
  # design step, a carried answer deferred to the next run — because those hold
  # the run; they are not run-scope rows, and a deadline end is no event, so
  # only the rows of `스코프=run` are kept here.
  blocked=$(cc_unresolved_blocked_where "$ledger" | LC_ALL=C awk -F '\t' '$2 == "run" { print $1 }')
  if [ -n "$run_dir" ] && [ -s "$run_dir/stall" ]; then
    blocked="$blocked
$(cut -f2 "$run_dir/stall" 2>/dev/null || true)"
  fi

  ceiling=$(run_stops_ceiling "$manifest")

  # THROUGH THE ENVIRONMENT, NOT `-v`. The BSD awk this runs under on macOS
  # refuses a `-v` value carrying a newline, and every table here is one.
  RS_HALTS="$halts" RS_SHALTS="$shalts" RS_BLOCKED="$blocked" RS_CEILING="$ceiling" \
  RS_V_RB="$RUN_STOPS_RUN_BLOCKED" RS_V_ST="$RUN_STOPS_STAGE" \
  RS_V_HA="$RUN_STOPS_HALT" RS_V_KI="$RUN_STOPS_KINDS" \
  RS_V_BO="$RUN_STOPS_BOUNDARY" RS_V_CE="$RUN_STOPS_INTENDED_CELLS" \
  RS_V_PA="$RUN_STOPS_PARK" RS_V_CU="$RUN_STOPS_CUTPOINTS" \
  RS_V_FX="$RUN_STOPS_FIX_SITE" RS_V_AS="$RUN_STOPS_ACT_STOP " \
  RS_BYFIX="$byfix" RS_TSTOP="$tstop" \
  awk -F'|' "$RUN_STOPS_AWK_FLD"'
    function settab(name, src,   n, a, i) {
      n = split(src, a, "\n")
      for (i = 1; i <= n; i++) if (a[i] != "") T[name, a[i]] = 1
    }
    function inv(name, v) { return ((name, v) in T) }
    function kindof(k) { return inv("KI", k) ? k : "미분류" }
    # The halt record a `중단 기록` path names: its file name without `.md`,
    # with `shift/` before it for a routing shift record, whose names can
    # repeat a stage record name.
    function reckey(p,   pre) {
      pre = (index(p, "/halt/shift/") ? "shift/" : "")
      sub(/.*\//, "", p); sub(/\.md$/, "", p)
      return pre p
    }
    # The judgment a `blocked` row carries, kept under <k>; the last row wins.
    function keepb(k) { BF[k] = fld("고칠 곳"); BJ[k] = fld("판정 주체"); BG[k] = fld("판정 신호"); BX[k] = fld("판정 근거") }
    function pick(f, j, g, x) {
      if (f == "") return 0
      if (!inv("FX", f)) { FX = "판정 불가"; FJ = "-"; FV = "-"; return 1 }
      FX = f; FJ = (j == "" ? "-" : j); FV = (x != "" ? x : (g != "" ? g : "-"))
      return 1
    }
    # The fix site of one stop, in the four places the header names.
    function fixsite(id, seg, rec, bk) {
      if (id != "-" && seg != "" && (seg in PF) && pick(PF[seg], PJ[seg], PG[seg], PX[seg])) return
      if (bk != "" && (bk in BF) && pick(BF[bk], BJ[bk], BG[bk], BX[bk])) return
      if (rec != "" && (rec in QF) && pick(QF[rec], QJ[rec], QG[rec], QX[rec])) return
      if (id != "-" && rec != "" && (rec in RF) && pick(RF[rec], "스테이지", "", RX[rec])) return
      FX = "판정 불가"; FJ = "-"; FV = "-"
    }
    function tabless(s) { gsub(/[\t\n]/, " ", s); return s }
    # emit(<서명>, <의도|비의도>, <제외 사유>, <표지>, <신원>, <세그먼트>,
    # <중단 기록 키>, <blocked 키>) — the last four are read by --by-fix-site.
    function emit(sig, judged, why, mark, id, seg, rec, bk,   line) {
      if (byfix) {
        if (judged == "의도") return
        if (id == "") id = "-"
        if (seg == "-" || !(seg in SEGST)) seg = ""
        fixsite(id, seg, rec, bk)
        line = tabless(FX) "\t" tabless(FJ) "\t" tabless(sig) "\t" tabless(id) "\t" tabless(FV)
        if (!(line in OUT)) { OUT[line] = 1; print line }
        return
      }
      if (!((sig, judged, why, mark) in OUT)) {
        OUT[sig, judged, why, mark] = 1
        printf "%s\t%s\t%s\t%s\n", sig, judged, (why == "" ? "-" : why), (mark == "" ? "-" : mark)
      }
    }
    BEGIN {
      settab("RB", ENVIRON["RS_V_RB"]); settab("ST", ENVIRON["RS_V_ST"])
      settab("HA", ENVIRON["RS_V_HA"]); settab("KI", ENVIRON["RS_V_KI"])
      settab("BO", ENVIRON["RS_V_BO"]); settab("CE", ENVIRON["RS_V_CE"])
      settab("PA", ENVIRON["RS_V_PA"]); settab("CU", ENVIRON["RS_V_CU"])
      settab("FX", ENVIRON["RS_V_FX"]); settab("TS", ENVIRON["RS_TSTOP"])
      asp = ENVIRON["RS_V_AS"]; byfix = (ENVIRON["RS_BYFIX"] != "")
      halts = ENVIRON["RS_HALTS"]; shalts = ENVIRON["RS_SHALTS"]; blocked = ENVIRON["RS_BLOCKED"]; ceiling = ENVIRON["RS_CEILING"]
      nrc = 0; nsk = 0; lastshift = 0; b4end = 0; lastcost = ""
    }
    {
      if (!match($0, /^- `[^`]*`/)) next
      series = substr($0, 4, RLENGTH - 4)
      if (series == "stage-result") {
        seg = fld("세그먼트"); stg = fld("스테이지"); k = fld("종류"); cl = fld("종단 부류"); ver = fld("실행 버전") + 0
        key = seg SUBSEP stg
        if (!(key in SR)) { SRN++; SRK[SRN] = key }
        SR[key] = cl; SRKIND[key] = k; SRSEG[key] = seg
        if (stg != "") { STGKIND[stg] = k; STGSEG[stg] = seg }
        if (seg != "") SEGKIND[seg] = k
        if (cl == "정상 완료" && ver > OKVER[stg]) OKVER[stg] = ver
      } else if (series == "자율 승인") {
        kd = fld("kind"); dc = fld("결정"); why = fld("근거"); std = fld("기준")
        if (kd == "router-shift" && dc == "결과" && why ~ /^rc=[0-9]+$/) {
          nrc++; RCN[nrc] = NR; RCV[nrc] = substr(why, 4) + 0
        } else if (kd == "skill" && dc == "결과" && why == "rc=127") {
          nsk++; SKN[nsk] = NR; SKS[nsk] = fld("세그먼트")
        } else if (kd == "skill" && dc == "act") {
          LAUNCH[fld("세그먼트")] = NR
        }
        if (std == "무효화 종료") RUNEND["무효화 종료"] = 1
        if (kd == "boundary" && dc == "종료" && std == "B5") RUNEND["B5"] = 1
        if (kd == "boundary" && dc == "종료" && std == "B4") b4end = 1
      } else if (series == "교대 기동") {
        lastshift = NR
      } else if (series == "승인") {
        id = fld("승인 id"); if (id == "") next
        if (!(id in AST)) { AN++; AID[AN] = id }
        AST[id] = fld("상태"); ADISP[id] = fld("처분 사유")
        c = fld("절단점"); if (c != "") ACUT[id] = c
        o = fld("연 자리"); if (o != "") AOPEN[id] = o
      } else if (series == "중단 답") {
        k = reckey(fld("중단 기록"))
        QF[k] = fld("고칠 곳"); QJ[k] = fld("판정 주체"); QG[k] = fld("판정 신호"); QX[k] = fld("판정 근거")
      } else if (series == "blocked") {
        sc = fld("스코프"); rs = fld("사유")
        if (sc == "run") keepb("R" SUBSEP rs)
        if (sc == "act") {
          s = fld("세그먼트"); if (s != "" && s != "-") { ACTR[s] = rs; ACTC[s] = fld("도달 판정"); keepb("A" SUBSEP s) }
          # A target whose apply is stopped: the last such block per segment
          # is one stop, whatever state the segment row is in.
          if (index(rs, asp) == 1 && s != "" && s != "-") {
            if (!(s in ASAL)) { ASN++; ASID[ASN] = s }
            ASAL[s] = fld("대상"); keepb("T" SUBSEP s)
          }
          st2 = fld("스테이지")
          if (rs == "도달 park" && st2 != "" && st2 != "-") PARKCELL[st2] = fld("도달 판정")
          # A routing shift runs with no stage id, so its reach park carries
          # `스테이지=-` and the segment it acted on.
          if (rs == "도달 park" && (st2 == "" || st2 == "-") && s != "" && s != "-") SHREACH[s] = fld("도달 판정")
        } else if (sc == "cone" && rs != "") {
          # A shift stop at `도달 거부` follows the reach park that refused an
          # act of that shift: the last such park of the anchor segment above
          # this row binds the record the row names.
          sr = fld("중단 기록"); sa = fld("앵커 세그먼트")
          if (sr != "" && fld("자리") == "도달 거부" && (sa in SHREACH)) {
            sub(/.*\//, "", sr); sub(/\.md$/, "", sr)
            SHCELL[sr] = SHREACH[sa]
          }
          # The last row per 사유 decides, as in every other fold: a later
          # `원인=해소` row of the same 사유 resolves it. An undecidable ancestry
          # row has no anchor; it names the two segments it could not measure.
          if (fld("중단 기록") != "") keepb("S" SUBSEP reckey(fld("중단 기록")))
          keepb("C" SUBSEP rs)
          if (!(rs in CONE)) { CN++; CID[CN] = rs }
          CONE[rs] = fld("원인"); CA[rs] = fld("앵커 세그먼트")
          CM[rs] = fld("구성원 세그먼트"); CS[rs] = fld("후보 세그먼트")
        }
      } else if (series == "segment") {
        s = fld("id"); if (s == "") next
        if (!(s in SEGST)) { SN++; SID[SN] = s }
        st = fld("상태"); if (st != "") SEGST[s] = st
        # The judgment of the current park run: a row in any other state ends
        # the run and its judgment, and a park row without `고칠 곳` keeps the
        # judgment an earlier row of the same run carried.
        if (st != "" && st != "park") { PF[s] = ""; PJ[s] = ""; PG[s] = ""; PX[s] = "" }
        else if (st == "park" && fld("고칠 곳") != "") {
          PF[s] = fld("고칠 곳"); PJ[s] = fld("판정 주체"); PG[s] = fld("판정 신호"); PX[s] = fld("판정 근거")
        }
      } else if (series == "cost") {
        v = fld("누적 usd"); if (v != "") lastcost = v
      }
    }
    END {
      # run-blocked
      n = split(blocked, B, "\n")
      for (i = 1; i <= n; i++) {
        r = trim(B[i]); if (r == "") continue
        emit("run-blocked/" (inv("RB", r) ? r : "미분류"), "비의도", "", "", "-", "", "", "R" SUBSEP r)
      }
      # stage: the last attempt of each segment·stage. Every end class but the
      # two that are no event is one; a class outside the table folds to 미분류.
      for (i = 1; i <= SRN; i++) {
        key = SRK[i]; cl = SR[key]
        if (cl == "" || cl == "정상 완료" || cl == "의도된 park") continue
        split(key, kp, SUBSEP)
        # A stage of no segment is named by its stage id.
        sid = (SRSEG[key] != "" && SRSEG[key] != "-") ? SRSEG[key] : kp[2]
        emit("stage/" (inv("ST", cl) ? cl : "미분류") "/" kindof(SRKIND[key]), "비의도", "", "", sid, SRSEG[key])
        EV[SRSEG[key]] = 1; EV[kp[2]] = 1
      }
      # halt: a record, unless a later attempt of the same stage completed
      n = split(halts, H, "\n")
      for (i = 1; i <= n; i++) {
        if (H[i] == "") continue
        split(H[i], hp, "\t"); hid = hp[1]; cls = hp[2]
        base = hid; att = 0
        if (match(hid, /#[0-9]+$/)) { base = substr(hid, 1, RSTART - 1); att = substr(hid, RSTART + 1) + 0 }
        if ((base in OKVER) && OKVER[base] > att) continue
        k = (base in STGKIND) ? kindof(STGKIND[base]) : "미분류"
        sig = "halt/" (inv("HA", cls) ? cls : "미분류") "/" k
        seg = (base in STGSEG) ? STGSEG[base] : base
        EV[seg] = 1; EV[base] = 1
        RF[hid] = hp[4]; RX[hid] = hp[5]
        # A wait on something outside the run — the merge of another pull
        # request, a release of another repository — is not a plugin defect.
        if (cls == "precondition-failed" && hp[3] == "외부") emit(sig, "의도", "외부 대기")
        else if (cls == "gate-unanswerable") {
          if (!(hid in PARKCELL)) emit(sig, "비의도", "", "원인 셀 미결합", hid, seg, hid)
          else if (inv("CE", PARKCELL[hid])) emit(sig, "의도", "사전 인가 밖")
          else emit(sig, "비의도", "", "", hid, seg, hid)
        } else emit(sig, "비의도", "", "", hid, seg, hid)
      }
      # shift halt: an unanswered one, of the segment it names. A record the
      # gate wrote at `도달 거부` is bound to the shift reach park before it,
      # and judged by that cell as a stage halt is; every other one is unbound.
      n = split(shalts, H, "\n")
      for (i = 1; i <= n; i++) {
        if (H[i] == "") continue
        split(H[i], hp, "\t"); hid = hp[1]; cls = hp[2]
        seg = hid; sub(/#[0-9]+$/, "", seg)
        sig = "halt/" (inv("HA", cls) ? cls : "미분류") "/" ((seg in SEGKIND) ? kindof(SEGKIND[seg]) : "미분류")
        EV[seg] = 1
        rk = "shift/" hid; RF[rk] = hp[3]; RX[rk] = hp[4]
        if (cls == "gate-unanswerable") {
          if (!(hid in SHCELL)) emit(sig, "비의도", "", "원인 셀 미결합", seg, seg, rk, "S" SUBSEP rk)
          else if (inv("CE", SHCELL[hid])) emit(sig, "의도", "사전 인가 밖")
          else emit(sig, "비의도", "", "", seg, seg, rk, "S" SUBSEP rk)
        } else emit(sig, "비의도", "", "", seg, seg, rk, "S" SUBSEP rk)
      }
      # cone: only where no stage or halt event of a segment it names explains it
      for (i = 1; i <= CN; i++) {
        rs = CID[i]
        if (CONE[rs] != "판정 불가") continue
        if ((CA[rs] != "" && (CA[rs] in EV)) || (CM[rs] != "" && (CM[rs] in EV)) \
            || (CS[rs] != "" && (CS[rs] in EV))) continue
        emit("cone/판정 불가", "비의도", "", "", (CA[rs] != "" ? CA[rs] : "-"), CA[rs], "", "C" SUBSEP rs)
      }
      # run-end
      if ("무효화 종료" in RUNEND) emit("run-end/무효화 종료", "비의도")
      if ("B5" in RUNEND) emit("run-end/B5", "비의도")
      if (b4end) emit("run-end/B4", "의도", "비용 천장", "열린 대기 아님")
      # shift: a non-zero, non-5 launch result with no later shift launch
      for (i = 1; i <= nrc; i++) {
        v = RCV[i]
        if (v == 0 || v == 5) continue
        if (lastshift > RCN[i]) continue
        emit("shift/" (v == 127 ? "기동 전제 실패" : "handoff 없는 사망"), "비의도")
      }
      # stage-launch: rc 127 with no later launch of the same segment
      for (i = 1; i <= nsk; i++) {
        s = SKS[i]
        if ((s in LAUNCH) && LAUNCH[s] > SKN[i]) continue
        emit("stage-launch/기동 전제 실패/" ((s in SEGKIND) ? kindof(SEGKIND[s]) : "미분류"), "비의도", "", "", s, s)
      }
      # approval: the ones still waiting
      for (i = 1; i <= AN; i++) {
        id = AID[i]
        if (AST[id] != "대기") continue
        c = ACUT[id]
        if (c == "판단") sig = "approval/판단"
        else if (c == "경계") {
          nm = id; sub(/-[0-9a-f]+$/, "", nm)
          sig = "approval/경계/" (inv("BO", nm) ? nm : "미분류")
        } else sig = "approval/미분류"
        if (ADISP[id] == "자유 입력" || ADISP[id] == "슬롯 부재") { emit(sig, "의도", "자유 입력"); continue }
        if (c == "판단") {
          if (AOPEN[id] == "design") emit(sig, "의도", "설계 판단"); else emit(sig, "비의도")
        } else if (c == "경계" && nm == "B4") {
          pct = -1
          if (ceiling != "" && lastcost != "") pct = (ceiling + 0 == 0) ? 0 : int((lastcost / ceiling) * 100)
          if (b4end || pct >= 100) emit(sig, "의도", "비용 천장"); else emit(sig, "비의도")
        } else if (inv("CU", c)) emit(sig, "의도", "사전 인가 밖")
        else emit(sig, "비의도")
      }
      # act: a target whose apply is stopped, one stop per segment whatever
      # the segment row says, while the stop of its alias still holds. The
      # alias tail is not carried into the signature.
      for (i = 1; i <= ASN; i++) {
        s = ASID[i]
        if (!inv("TS", ASAL[s])) continue
        emit("act/대상 적용 정지", "비의도", "", "", s, s, "", "T" SUBSEP s)
      }
      # park: a parked segment no stage or halt event explains. A segment
      # whose last act-scope block is a target stop belongs to the branch
      # above.
      for (i = 1; i <= SN; i++) {
        s = SID[i]
        if (SEGST[s] != "park" || (s in EV)) continue
        if (!(s in ACTR)) { emit("segment/park", "비의도", "", "", s, s); continue }
        rs = ACTR[s]; cell = ACTC[s]
        if (index(rs, asp) == 1) continue
        if (rs == "도달 park") {
          if (inv("CE", cell)) emit("park/" cell, "의도", "사전 인가 밖")
          else emit("park/" (inv("PA", cell) ? cell : "미분류"), "비의도", "", "", s, s, "", "A" SUBSEP s)
        } else if (rs == "대상 미선언") emit("park/대상 미선언", "비의도", "", "", s, s, "", "A" SUBSEP s)
        else emit("park/미분류", "비의도", "", "", s, s, "", "A" SUBSEP s)
      }
    }
  ' "$ledger"
}

run_stops_main "$@"
