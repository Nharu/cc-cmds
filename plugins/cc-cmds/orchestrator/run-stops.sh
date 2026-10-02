#!/usr/bin/env bash
# run-stops.sh — the stop events of one settled run, derived from what the run
# already recorded.
#
#   run-stops.sh <ledger> <run-dir> [--manifest <path>]
#   run-stops.sh --vocab <table>
#
# One line per event on stdout, tab-separated:
#
#   <서명> <TAB> <의도|비의도> <TAB> <제외 사유|-> <TAB> <표지|->
#
# `서명` is `<부류>/<사유>[/<종류>]` and every slot comes from a closed table
# below; a value outside its table folds to `미분류` rather than being copied.
# `제외 사유` names which of the four intended waits an `의도` line is
# (`비용 천장` · `사전 인가 밖` · `설계 판단` · `자유 입력`). `표지` is
# `원인 셀 미결합` on a gate-unanswerable halt no reach park binds to, and
# `열린 대기 아님` on an intended event that was a decision rather than a wait,
# for which no skip row is written. Resolved events are not printed at all.
#
# WHAT THIS DOES NOT DO, and each is a boundary rather than a gap. It never
# calls `gh` and holds no credential: the gate is the only writer of an issue.
# It writes nothing — not to the ledger, not to the run directory. And it reads
# no free text: a reason, a question, a halt record's observation body are
# never parsed, because a classification read off prose changes when the prose
# does. The inputs are tokens the gate, the watcher and the driver wrote.
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
shift'
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
대상 미선언'
RUN_STOPS_CUTPOINTS='커밋
브랜치
push
PR
머지
배포
머지후착수'

run_stops_vocab() {
  case "$1" in
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

run_stops_main() {
  local ledger="" run_dir="" manifest="" halts ceiling blocked
  if [ "${1:-}" = "--vocab" ]; then
    run_stops_vocab "${2:-}"; return $?
  fi
  ledger="${1:-}"; run_dir="${2:-}"; shift 2 2>/dev/null || true
  while [ $# -gt 0 ]; do
    case "$1" in
      --manifest) manifest="${2:-}"; shift 2 ;;
      *) printf 'run-stops.sh: unknown argument %s\n' "$1" >&2; return 2 ;;
    esac
  done
  if [ -z "$ledger" ] || [ ! -f "$ledger" ]; then
    printf 'run-stops.sh: usage: run-stops.sh <ledger> <run-dir> [--manifest <path>]\n' >&2
    return 2
  fi

  # shellcheck source=liveness.sh
  . "$RUN_STOPS_DIR/liveness.sh"

  # HALT RECORDS: only the file name and the `**분류**` line are read.
  halts=""
  if [ -n "$run_dir" ] && [ -d "$run_dir/halt" ]; then
    local f id cls
    for f in "$run_dir"/halt/*.md; do
      [ -f "$f" ] || continue
      id=${f##*/}; id=${id%.md}
      cls=$( { grep -m1 -E '^\*\*분류\*\*: ' "$f" 2>/dev/null || true; } \
             | sed 's/^\*\*분류\*\*: //; s/[[:space:]]*$//')
      [ -n "$cls" ] || continue
      halts="${halts}$(printf '%s\t%s' "$id" "$cls")
"
    done
  fi

  # RUN-SCOPE BLOCKS: the ledger's unresolved ones, by the same fold every other
  # reader uses, plus the watcher observations not yet transcribed.
  blocked=$(cc_unresolved_blocked "$ledger" | cut -f2-)
  if [ -n "$run_dir" ] && [ -s "$run_dir/stall" ]; then
    blocked="$blocked
$(cut -f2 "$run_dir/stall" 2>/dev/null || true)"
  fi

  ceiling=$(run_stops_ceiling "$manifest")

  # THROUGH THE ENVIRONMENT, NOT `-v`. The BSD awk this runs under on macOS
  # refuses a `-v` value carrying a newline, and every table here is one.
  RS_HALTS="$halts" RS_BLOCKED="$blocked" RS_CEILING="$ceiling" \
  RS_V_RB="$RUN_STOPS_RUN_BLOCKED" RS_V_ST="$RUN_STOPS_STAGE" \
  RS_V_HA="$RUN_STOPS_HALT" RS_V_KI="$RUN_STOPS_KINDS" \
  RS_V_BO="$RUN_STOPS_BOUNDARY" RS_V_CE="$RUN_STOPS_INTENDED_CELLS" \
  RS_V_PA="$RUN_STOPS_PARK" RS_V_CU="$RUN_STOPS_CUTPOINTS" \
  awk -F'|' '
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    function fld(k,   i, p) {
      for (i = 2; i <= NF; i++) {
        p = trim($i)
        if (index(p, k "=") == 1) return substr(p, length(k) + 2)
      }
      return ""
    }
    function settab(name, src,   n, a, i) {
      n = split(src, a, "\n")
      for (i = 1; i <= n; i++) if (a[i] != "") T[name, a[i]] = 1
    }
    function inv(name, v) { return ((name, v) in T) }
    function kindof(k) { return inv("KI", k) ? k : "미분류" }
    function emit(sig, judged, why, mark) {
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
      halts = ENVIRON["RS_HALTS"]; blocked = ENVIRON["RS_BLOCKED"]; ceiling = ENVIRON["RS_CEILING"]
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
      } else if (series == "blocked") {
        sc = fld("스코프"); rs = fld("사유")
        if (sc == "act") {
          s = fld("세그먼트"); if (s != "" && s != "-") { ACTR[s] = rs; ACTC[s] = fld("도달 판정") }
          st2 = fld("스테이지")
          if (rs == "도달 park" && st2 != "" && st2 != "-") PARKCELL[st2] = fld("도달 판정")
        } else if (sc == "cone") {
          a = fld("앵커 세그먼트"); if (a != "") { if (!(a in CONE)) { CN++; CID[CN] = a }; CONE[a] = fld("원인") }
        }
      } else if (series == "segment") {
        s = fld("id"); if (s == "") next
        if (!(s in SEGST)) { SN++; SID[SN] = s }
        st = fld("상태"); if (st != "") SEGST[s] = st
      } else if (series == "cost") {
        v = fld("누적 usd"); if (v != "") lastcost = v
      }
    }
    END {
      # run-blocked
      n = split(blocked, B, "\n")
      for (i = 1; i <= n; i++) {
        r = trim(B[i]); if (r == "") continue
        emit("run-blocked/" (inv("RB", r) ? r : "미분류"), "비의도")
      }
      # stage: the last attempt of each segment·stage
      for (i = 1; i <= SRN; i++) {
        key = SRK[i]; cl = SR[key]
        if (inv("ST", cl)) { emit("stage/" cl "/" kindof(SRKIND[key]), "비의도"); EV[SRSEG[key]] = 1 }
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
        EV[seg] = 1
        if (cls == "gate-unanswerable") {
          if (!(hid in PARKCELL)) emit(sig, "비의도", "", "원인 셀 미결합")
          else if (inv("CE", PARKCELL[hid])) emit(sig, "의도", "사전 인가 밖")
          else emit(sig, "비의도")
        } else emit(sig, "비의도")
      }
      # cone: only where no stage or halt event explains it
      for (i = 1; i <= CN; i++) {
        a = CID[i]
        if (CONE[a] == "판정 불가" && !(a in EV)) emit("cone/판정 불가", "비의도")
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
        emit("stage-launch/기동 전제 실패/" ((s in SEGKIND) ? kindof(SEGKIND[s]) : "미분류"), "비의도")
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
      # park: a parked segment no stage or halt event explains
      for (i = 1; i <= SN; i++) {
        s = SID[i]
        if (SEGST[s] != "park" || (s in EV)) continue
        if (!(s in ACTR)) { emit("segment/park", "비의도"); continue }
        rs = ACTR[s]; cell = ACTC[s]
        if (rs == "도달 park") {
          if (inv("CE", cell)) emit("park/" cell, "의도", "사전 인가 밖")
          else emit("park/" (inv("PA", cell) ? cell : "미분류"), "비의도")
        } else if (rs == "대상 미선언") emit("park/대상 미선언", "비의도")
        else emit("park/미분류", "비의도")
      }
    }
  ' "$ledger"
}

run_stops_main "$@"
