#!/usr/bin/env bash
# 리뷰 사이클 원인 측정 — 레포마다 세그먼트당 사이클을 세고, 2번째 이후 사이클을 연
# 계기와 그 사이클 리뷰가 낸 발견의 성격으로 나눈다.
#
# This is NOT a gate. Nothing here passes or fails; the output is the input to
# a human reading — 게이트·라우터·스테이지 어디에서도 부르지 않고, 사람이 필요할 때
# 부른다. 어떤 원장 디렉터리나 그 레포에도 쓰지 않는다. 표는 표준 출력에, JSON 은
# `--json` 으로 준 경로에만 쓰고, 실행 중의 임시 파일은 mktemp 디렉터리에 두었다가
# 끝에 지운다. `make test` 는 이 스크립트를 픽스처에만 돌린다.
#
# 입력: `--ledger-dir [<이름>=]<dir>` 하나 이상. <dir> 은 `<레포>/docs/pipeline-run`
# 꼴의 원장 디렉터리이고, 준 순서가 표의 열 순서다. 이름을 주지 않으면 `<dir>/../..`
# (레포 뿌리)의 basename 이 이름이다. 세그먼트는 그 행이 적힌 원장 디렉터리에 귀속하며,
# 세그먼트 행의 `레포`·마지막 `워크트리` 값은 세그먼트별 JSON 에 그대로 싣는다.
#
# `--repo <owner/name>=<경로>` (반복 가능) 는 세그먼트 행의 `레포` 를 git 조회 위치로
# 잇는 지도다. 세그먼트의 `레포` 가 없거나 그 이름 부분(`/` 뒤)이 원장 이름과 같으면
# 원장 레포 뿌리, 지도에 있으면 그 경로, 그 밖이면 원장 레포 뿌리에서 찾되 객체를 찾지
# 못한 사유를 `HEAD 없음` 이 아니라 `레포 미지정` 으로 낸다.
#
# `cycle` 행에 `계기`·`수정 경로`·`앞 HEAD`·`리뷰 HEAD 고정`·`리포트 형식`·`항목` 이
# 있으면 그 값을 정본으로 읽고, 없으면 아래의 옛 추론 규칙 그대로 읽는다. 사이클마다
# `trigger_source`·`fix_path_source` 가 어느 쪽인지(`recorded`·`inferred`)를 싣는다.
#
# 모집단: 각 원장 디렉터리 바로 아래 이름이 `<8자리>-<8hex>.md` 인 파일
# (`^[0-9]{8}-[0-9a-f]{8}\.md$`). `.plan.md`·`.interview.md`·`metrics*` 는 걸리지
# 않는다. `--since`/`--until YYYY-MM-DD` 는 파일 이름의 날짜와 비교하며 두 끝을 포함하고,
# 주지 않은 쪽은 경계가 없다. 선택자와 기간은 표 머리에 인쇄한다.
#
# 출력:
#   1 사이클 표      티켓 정의(머지됨 행 · cycle 행 · 비)와 보정 정의(머지된 세그먼트
#                    자신의 서로 다른 사이클), park·그 밖 열, 그리고 정확히 성립하는
#                    분해 두 줄.
#   2 계기           2번째 이후 사이클마다 하나 — 행의 `계기` 가 있으면 그 토큰, 없으면
#                    고정 우선순위로 리뷰 P0 · 리뷰 P1 · CI 실패 · 베이스 병합 해소 ·
#                    중단·재시도 · 미상 — 와 수정 경로, 그리고 둘의 기록·추론 건수와
#                    `해소 리뷰` 를 `앞 HEAD` 로 나눈 줄. 게이트가 patch-id 동일로
#                    해소 리뷰를 건너뛴 판정(`베이스 판정` 행의 `판정 근거=패치동일`,
#                    런·세그먼트·판정 HEAD 의 서로 다른 짝)이 있으면 그 수를
#                    `<머지된 세그먼트> / <전체>` 로 적은 줄.
#   2c 라우터 판단   `라우터 판단` 으로 연 사이클마다 파견 행 `근거` 머리의 사유.
#   3 발견 성격      리포트의 상속 표지와 두 리뷰 HEAD 사이 git diff 덩어리로 가른 버킷,
#                    읽지 못한 몫(리포트 판독 불가 · 판독 차이)은 버킷이 아닌 칸으로.
#   4 분포           버킷별 부류 태그, 첫 사이클 부류 태그, 심각도.
#   5 리포트 상태    없음 · 요약 없음 · 행과 불일치 · 항목 수 불일치 · 경로 재사용 ·
#                    형식 불일치(기록) · gate·도구 판독 차이.
# 리포트는 정해진 줄 형태만 읽고 산문 대체 판독은 없다. 형식이 바뀌면 판독 불가 칸과
# 리포트 상태 목록이 커지는 것으로 드러나고, 틀린 수가 측정처럼 보이지는 않는다.
# P0·P1 절에 `### P[01]-<n>` 머리가 하나라도 있으면 그 절의 항목은 머리이고, 없으면
# 0열 `- **[` 줄이 항목이다.
#
# Usage:
#   measure-cycle-causes.sh --ledger-dir [<이름>=]<dir> [--ledger-dir …]… \
#       [--repo <owner/name>=<경로> …] [--since YYYY-MM-DD] [--until YYYY-MM-DD] \
#       [--json <경로>]
#
# Exit codes:
#   0 — 출력함 (모집단이 0 이어도 표 머리는 낸다)
#   2 — 인자 오류 (--ledger-dir 없음 · 같은 이름 둘 · 틀린 날짜 · 모르는 인자 ·
#       --repo 의 키가 `owner/name` 이 아니거나 값이 비었거나 같은 키 둘)
#   3 — 원장 디렉터리 없음 · --repo 경로가 디렉터리가 아님
#
# Compatibility: bash 3.2 (macOS) — no associative arrays, no mapfile.
# Non-ASCII literals follow a `${var}` brace, never a bare `$var`. awk 는 POSIX 범위,
# 수치 집계는 전부 jq 가 하고, git 은 발견 성격 판정에서 `cd <세그먼트의 레포 뿌리>`
# 뒤 `cat-file -e`·`ls-tree`·`diff` 읽기 명령만 부른다.

set -euo pipefail

SELECTOR='<8자리>-<8hex>.md'
SCHEMA='cc-cycle-causes v3'

mc_diag() { printf 'measure-cycle-causes: %s\n' "$1" >&2; }

LD_NAMES=(); LD_DIRS=(); LD_COUNT=0
RM_KEYS=(); RM_PATHS=(); RM_COUNT=0
SINCE=""; UNTIL=""; JSON_OUT=""

mc_date_ok() { [[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; }

while (( $# > 0 )); do
  case "$1" in
    --ledger-dir)
      [ $# -ge 2 ] || { mc_diag "--ledger-dir 에 값이 없다"; exit 2; }
      v="$2"; name=""; dir="$v"
      # `<이름>=` 접두는 첫 `=` 앞에 `/` 가 없을 때만 이름이다 — 경로 안의 `=` 는 경로다.
      case "$v" in
        *=*) pre="${v%%=*}"
             case "$pre" in */*|'') ;; *) name="$pre"; dir="${v#*=}" ;; esac ;;
      esac
      LD_NAMES[LD_COUNT]="$name"; LD_DIRS[LD_COUNT]="$dir"; LD_COUNT=$((LD_COUNT + 1))
      shift 2 ;;
    --repo)
      [ $# -ge 2 ] || { mc_diag "--repo 에 값이 없다"; exit 2; }
      v="$2"; pre="${v%%=*}"; dir="${v#*=}"
      if [ "$pre" = "$v" ] || [[ ! "$pre" =~ ^[^/]+/[^/]+$ ]] || [ -z "$dir" ]; then
        mc_diag "--repo 는 <owner/name>=<경로> 이다: $v"; exit 2
      fi
      k=0
      while [ "$k" -lt "$RM_COUNT" ]; do
        [ "${RM_KEYS[k]}" != "$pre" ] || { mc_diag "--repo 에 같은 레포 「${pre}」 가 둘이다"; exit 2; }
        k=$((k + 1))
      done
      RM_KEYS[RM_COUNT]="$pre"; RM_PATHS[RM_COUNT]="$dir"; RM_COUNT=$((RM_COUNT + 1))
      shift 2 ;;
    --since) [ $# -ge 2 ] || { mc_diag "--since 에 값이 없다"; exit 2; }; SINCE="$2"; shift 2 ;;
    --until) [ $# -ge 2 ] || { mc_diag "--until 에 값이 없다"; exit 2; }; UNTIL="$2"; shift 2 ;;
    --json)  [ $# -ge 2 ] || { mc_diag "--json 에 값이 없다"; exit 2; }; JSON_OUT="$2"; shift 2 ;;
    -h|--help) grep -E '^# ' "$0" | cut -c3-; exit 0 ;;
    *) mc_diag "모르는 인자: $1"; exit 2 ;;
  esac
done

[ "$LD_COUNT" -gt 0 ] || { mc_diag "--ledger-dir 가 하나 이상 필요하다"; exit 2; }
if [ -n "$SINCE" ] && ! mc_date_ok "$SINCE"; then mc_diag "--since 는 YYYY-MM-DD 이다: $SINCE"; exit 2; fi
if [ -n "$UNTIL" ] && ! mc_date_ok "$UNTIL"; then mc_diag "--until 는 YYYY-MM-DD 이다: $UNTIL"; exit 2; fi
SINCE_N=$(printf '%s' "$SINCE" | tr -d '-'); UNTIL_N=$(printf '%s' "$UNTIL" | tr -d '-')

LD_ROOTS=()
i=0
while [ "$i" -lt "$LD_COUNT" ]; do
  d="${LD_DIRS[i]}"
  [ -d "$d" ] || { mc_diag "원장 디렉터리가 없다: $d"; exit 3; }
  LD_DIRS[i]=$(cd "$d" && pwd)
  LD_ROOTS[i]=$(cd "$d/../.." && pwd)
  [ -n "${LD_NAMES[i]}" ] || LD_NAMES[i]=$(basename "${LD_ROOTS[i]}")
  i=$((i + 1))
done
i=0
while [ "$i" -lt "$RM_COUNT" ]; do
  d="${RM_PATHS[i]}"
  [ -d "$d" ] || { mc_diag "--repo 경로가 디렉터리가 아니다: $d"; exit 3; }
  RM_PATHS[i]=$(cd "$d" && pwd)
  i=$((i + 1))
done
i=0
while [ "$i" -lt "$LD_COUNT" ]; do
  j=$((i + 1))
  while [ "$j" -lt "$LD_COUNT" ]; do
    if [ "${LD_NAMES[i]}" = "${LD_NAMES[j]}" ]; then
      mc_diag "두 --ledger-dir 가 같은 이름 「${LD_NAMES[i]}」 이 된다 — <이름>=<dir> 로 이름을 붙여라"
      exit 2
    fi
    j=$((j + 1))
  done
  i=$((i + 1))
done

WORK=$(mktemp -d "${TMPDIR:-/tmp}/cc-cycle-causes.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
ROWS="$WORK/rows.tsv"
: > "$ROWS"

# --- 원장 판독 --------------------------------------------------------------
#
# 행 선택과 칸 읽기는 collect-run-metrics.sh 의 cm_ledger_rows(`- \`<계열>\` | ` 로
# 시작하는 줄만 행)와 cm_field(`|` 로 나눈 조각의 앞 공백을 지우고, 같은 키의 마지막
# 등장, 끝 공백 제거)를 옮긴 것이다. 그 수집기는 소싱하지 않는다.

mc_ledger_files() {
  # mc_ledger_files <dir> — 모집단 원장 파일, 이름 순.
  local f b day
  for f in "$1"/*.md; do
    [ -f "$f" ] || continue
    b=$(basename "$f")
    [[ "$b" =~ ^[0-9]{8}-[0-9a-f]{8}\.md$ ]] || continue
    day="${b%%-*}"
    if [ -n "$SINCE_N" ] && [ "$day" -lt "$SINCE_N" ]; then continue; fi
    if [ -n "$UNTIL_N" ] && [ "$day" -gt "$UNTIL_N" ]; then continue; fi
    printf '%s\n' "$f"
  done
}

mc_parse_ledger() {
  # mc_parse_ledger <label> <run> <ledger> <repo root> — 파일 순서로 한 번 읽어 cycle 행마다
  # C 레코드, 끝에 세그먼트마다 S 레코드를 낸다. 계기와 수정 경로는 행에 그 필드가 있으면
  # 그 값이고, 없으면 앞 사이클 행(c 보다 앞선 가장 늦은 번호의 마지막 cycle 행) 뒤에 그
  # 세그먼트의 사건이 있었는지로 정한다 — 사건마다 마지막 줄 번호를 들고 있다가 앞 사이클
  # 행의 줄 번호와 비교한다. `리포트 형식` 이 없는 옛 행끼리 한 세그먼트의 두 cycle 행이
  # 같은 리포트 경로에 다른 리뷰 HEAD 를 가리키면 앞 행마다 U 레코드를 낸다.
  awk -v label="$1" -v run="$2" -v root="$4" '
    function fld(k,   n, i, a, x, p, v) {
      v = ""; p = k "="
      n = split($0, a, "|")
      for (i = 1; i <= n; i++) { x = a[i]; sub(/^ +/, "", x); if (index(x, p) == 1) v = substr(x, length(p) + 1) }
      sub(/[ \t]+$/, "", v)
      return v
    }
    function nt(v) { gsub(/\t/, " ", v); return v }
    function cl(v) { v = nt(v); return (v == "") ? "-" : v }
    function reg(s) { if (!(s in known)) { known[s] = 1; order[++nseg] = s } }
    function ab(p) { return (substr(p, 1, 1) == "/") ? p : root "/" p }
    function sameh(a, b) { return a == b || (a != "" && b != "" && (index(a, b) == 1 || index(b, a) == 1)) }
    /^- `[^`]+` \| / {
      kind = $0; sub(/^- `/, "", kind); sub(/`.*/, "", kind)
      if (kind == "segment") {
        s = fld("id"); if (s == "") next
        reg(s); hasrow[s] = 1; lstate[s] = fld("상태")
        if (lstate[s] == "머지됨") mrows[s]++
        v = fld("레포"); if (v != "") repo[s] = v
        v = fld("워크트리"); if (v != "") wtv[s] = v
        next
      }
      if (kind == "checks")   { if (fld("상태") == "실패") ci_at[fld("세그먼트")] = NR; next }
      if (kind == "blocked")  { if (fld("도달 판정") == "CI실패") ci_at[fld("세그먼트")] = NR; next }
      if (kind == "중단 답")  { halt_at[fld("세그먼트")] = NR; next }
      if (kind == "stage-result") {
        s = fld("세그먼트"); k = fld("종류"); t = fld("종단 부류")
        if (k == "lead-fix") lf_at[s] = NR
        else if (k == "reconverge") rc_at[s] = NR
        else if (k == "implement") im_at[s] = NR
        if (k == "review" && (t == "크래시" || t == "한도 종료" || t == "외부 종료" || t == "산출물 없는 정지")) rv_at[s] = NR
        next
      }
      if (kind == "자율 승인") {
        # 리뷰 파견 행 — `라우터 판단` 의 사유는 `근거` 머리의 `계기 사유: <사유>;` 다.
        v = fld("리포트 경로"); t = fld("계기")
        if (v != "" && t != "") {
          x = ""; g = fld("근거"); p = "계기 사유: "
          if (t == "라우터 판단" && index(g, p) == 1) { x = substr(g, length(p) + 1); i = index(x, ";"); if (i > 0) x = substr(x, 1, i - 1) }
          rreason[ab(v)] = x
        }
        next
      }
      if (kind == "베이스 판정") {
        # 리뷰 없이 넘어간 해소는 cycle 행을 만들지 않는다 — 판정이 일어난 행으로 센다.
        if (fld("판정 근거") == "패치동일") printf "B\t%s\t%s\t%s\t%s\n", label, run, cl(fld("세그먼트")), cl(fld("판정 HEAD"))
        next
      }
      if (kind != "cycle") next
      s = fld("세그먼트"); reg(s); c = fld("사이클") + 0
      key = s SUBSEP c; dup = (key in seen) ? 1 : 0
      mode = fld("모드"); p0 = fld("P0") + 0; p1 = fld("P1") + 0
      head = fld("리뷰 HEAD"); rp = fld("리포트 경로"); if (rp == "") rp = fld("리포트")
      bc = fld("기준 사이클")
      pc = -1; m = split(nums[s], ns, " ")
      for (i = 1; i <= m; i++) if (ns[i] + 0 < c && ns[i] + 0 > pc) pc = ns[i] + 0
      L = 0; pk = ""
      if (pc >= 0) { pk = s SUBSEP pc; L = lastline[pk] }
      ci = 0; ha = 0; cr = 0; ba = (mode == "해소") ? 1 : 0; fix = "-"
      if (dup) trig = "중복 행"
      else if (c <= 1) trig = "첫 사이클"
      else {
        ci = (ci_at[s] + 0 > L) ? 1 : 0; ha = (halt_at[s] + 0 > L) ? 1 : 0; cr = (rv_at[s] + 0 > L) ? 1 : 0
        if (pc < 0) trig = "앞 사이클 행 없음"
        else if (lp0[pk] > 0) trig = "리뷰 P0"
        else if (lp1[pk] > 0) trig = "리뷰 P1"
        else if (ci) trig = "CI 실패"
        else if (ba) trig = "베이스 병합 해소"
        else if (ha || cr) trig = "중단·재시도"
        else trig = "미상"
        if (lf_at[s] + 0 > L || (pc >= 0 && lclose[pk] == "리드 수정")) fix = "리드 수정"
        else if (rc_at[s] + 0 > L) fix = "재수렴"
        else if (im_at[s] + 0 > L) fix = "구현"
        else fix = "기록 없음"
      }
      # 행에 기록된 값이 있으면 그것이 정본이다. 중복 행은 계기를 기록값으로 덮지 않는다.
      ts = "inferred"; v = fld("계기")
      if (!dup && v != "" && v != "-") { trig = v; ts = "recorded" }
      fs = "inferred"; fps = fix; v = fld("수정 경로")
      if (v != "") { fs = "recorded"; fps = v; i = index(v, ","); fix = (i > 0) ? substr(v, 1, i - 1) : v }
      rfm = fld("리포트 형식")
      rr = (rp != "") ? rreason[ab(rp)] : ""
      if (rp != "" && rfm == "") {
        uk = s SUBSEP ab(rp)
        if ((uk in unr) && !sameh(uh[uk], head)) printf "U\t%s\t%d\n", run, unr[uk]
        unr[uk] = NR; uh[uk] = head
      }
      ph = (pc >= 0) ? lh[pk] : ""
      dh = ""; bk = s SUBSEP (bc + 0)
      if (bc != "" && (bk in seen)) dh = lh[bk]
      printf "C\t%s\t%s\t%d\t%s\t%d\t%d\t%s\t%d\t%d\t%s\t%s\t%d\t%d\t%d\t%d\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", label, run, NR, cl(s), c, dup, cl(mode), p0, p1, cl(trig), cl(fix), ci, ha, cr, ba, cl(rp), cl(head), cl(ph), cl(dh), ts, cl(fps), fs, cl(fld("앞 HEAD")), cl(fld("리뷰 HEAD 고정")), cl(rfm), cl(fld("항목")), cl(rr)
      seen[key] = 1; lastline[key] = NR; lp0[key] = p0; lp1[key] = p1; lh[key] = head; lclose[key] = fld("리뷰 종결")
      if (!dup) nums[s] = nums[s] " " c
    }
    END {
      for (i = 1; i <= nseg; i++) {
        s = order[i]
        if (mrows[s] + 0 > 0) { cat = "merged"; st = "머지됨" }
        else if (!(s in hasrow)) { cat = "none"; st = "세그먼트 행 없음" }
        else if (lstate[s] == "park") { cat = "park"; st = "park" }
        else { cat = "other"; st = lstate[s] }
        printf "S\t%s\t%s\t%s\t%s\t%s\t%d\t%s\t%s\n", label, run, cl(s), cat, cl(st), mrows[s] + 0, nt(repo[s]), nt(wtv[s])
      }
    }' "$3"
}

# --- 리포트 판독 ------------------------------------------------------------

mc_parse_report() {
  # mc_parse_report <report> — 항목마다 I 레코드(심각도·부류 태그·앵커·앵커 경로·앵커 줄·
  # 상속 표지), 끝에 M 레코드(정규 요약 유무와 P0~P3 · 리뷰 모드 · 재판정 해결됨·미해결 ·
  # P0·P1 항목 수). 정규 요약 줄은 run.sh predicate_review 와 같은 정규식이다.
  # P0·P1 절은 절 끝에서 한 번에 낸다 — 그 절에 `### P[01]-<n>` 머리가 하나라도 있으면
  # 머리마다(다음 `### ` 머리나 절 끝까지가 그 블록) 한 항목이고 블록 안의 불릿은 항목이
  # 아니다. 머리가 없으면 0열 `- **[` 줄마다 한 항목이다.
  awk '
    function num(t,   r) { if (match($0, t " [0-9]+")) { r = substr($0, RSTART + length(t) + 1, RLENGTH - length(t) - 1); return r + 0 } return 0 }
    function anchor(line,   r, sp, mm, j) {
      r = line
      while (match(r, /`[^`]+`/)) {
        sp = substr(r, RSTART + 1, RLENGTH - 2); r = substr(r, RSTART + RLENGTH)
        if (match(sp, /^[^ ]+:[0-9]+/)) {
          a = sp; mm = substr(sp, 1, RLENGTH)
          for (j = 1; j < length(mm); j++) if (substr(mm, j, 1) == ":" && substr(mm, j + 1, 1) ~ /[0-9]/) break
          ap = substr(mm, 1, j - 1); al = substr(mm, j + 1); sub(/[^0-9].*$/, "", al)
          return 1
        }
      }
      return 0
    }
    function item(tag, inh) {
      items++
      gsub(/\t/, " ", tag); gsub(/\t/, " ", a); gsub(/\t/, " ", ap)
      printf "I\t%s\t%s\t%s\t%s\t%s\t%d\n", sec, tag, a, ap, al, inh
    }
    function flush(   i, j, n, t, ln, tag) {
      if (nh > 0) {
        for (i = 1; i <= nh; i++) {
          n = split(hb[i], ln, "\n"); a = "-"; ap = "-"; al = "-"; tag = "-"
          for (j = 1; j <= n; j++) if (anchor(ln[j])) break
          for (j = 1; j <= n; j++) if (match(ln[j], /\[[a-z][a-z-]*\]/)) { tag = substr(ln[j], RSTART + 1, RLENGTH - 2); break }
          item(tag, (index(hb[i], "에서 상속, 미해결)") || index(hb[i], "재확인 미해결)")) ? 1 : 0)
        }
      } else {
        for (i = 1; i <= nb; i++) {
          t = substr(bl[i], 6); j = index(t, "]"); tag = (j > 1) ? substr(t, 1, j - 1) : "-"
          a = "-"; ap = "-"; al = "-"; anchor(bl[i])
          item(tag, (index(bl[i], "에서 상속, 미해결)") || index(bl[i], "재확인 미해결)")) ? 1 : 0)
        }
      }
      nh = 0; nb = 0; inb = 0
    }
    BEGIN { sec = ""; has = 0; mode = "-"; res = 0; unres = 0; items = 0; nh = 0; nb = 0; inb = 0 }
    /^- \*\*발견 요약\*\*: 🔴 P0 [0-9]+건 \| 🟠 P1 [0-9]+건 \| 🟡 P2 [0-9]+건 \| 🟢 P3 [0-9]+건/ && !has {
      has = 1; s0 = num("P0"); s1 = num("P1"); s2 = num("P2"); s3 = num("P3")
    }
    /^- \*\*리뷰 모드\*\*: / && mode == "-" {
      x = $0; sub(/^- \*\*리뷰 모드\*\*: */, "", x); split(x, w, " "); if (w[1] != "") mode = w[1]
    }
    /^## / {
      if (sec == "P0" || sec == "P1") flush()
      sec = ""
      if (index($0, "## 🔴 P0") == 1) sec = "P0"
      else if (index($0, "## 🟠 P1") == 1) sec = "P1"
      else if (index($0, "## 기준 사이클 재판정") == 1) sec = "RJ"
      next
    }
    sec == "RJ" && /^    - \*\*판정\*\*: 해결됨/ { res++; next }
    sec == "RJ" && /^    - \*\*판정\*\*: 미해결/ { unres++; next }
    (sec == "P0" || sec == "P1") && /^### P[01]-[0-9]+([^0-9]|$)/ { hb[++nh] = $0; inb = 1; next }
    (sec == "P0" || sec == "P1") && /^### / { inb = 0; next }
    sec == "P0" || sec == "P1" {
      if (inb) hb[nh] = hb[nh] "\n" $0
      if (index($0, "- **[") == 1) bl[++nb] = $0
    }
    END {
      if (sec == "P0" || sec == "P1") flush()
      printf "M\t%d\t%d\t%d\t%d\t%d\t%s\t%d\t%d\t%d\n", has, s0, s1, s2, s3, mode, res, unres, items
    }' "$1"
}

# --- git 판정 ---------------------------------------------------------------
#
# 같은 질의는 실행 임시 디렉터리에 한 번만 받는다. 캐시 파일 이름은 질의 문자열의 cksum.

mc_key() { printf '%s' "$*" | cksum | cut -d' ' -f1; }

mc_commit_ok() {
  # mc_commit_ok <root> <sha>
  local f
  f="$WORK/commit.$(mc_key "$1" "$2")"
  if [ ! -f "$f" ]; then
    if (cd "$1" && git cat-file -e "$2^{commit}") >/dev/null 2>&1; then echo 1 > "$f"; else echo 0 > "$f"; fi
  fi
  [ "$(cat "$f")" = 1 ]
}

mc_resolve_path() {
  # mc_resolve_path <root> <head> <anchor path> — 그대로 있으면 그것, 없으면 `/<앵커 경로>` 로
  # 끝나는 파일이 정확히 하나일 때 그것. 풀지 못하면 빈 출력에 후보 수를 stderr 대신 반환값으로.
  local root="$1" head="$2" p="$3" lt n
  if (cd "$root" && git cat-file -e "$head:$p") >/dev/null 2>&1; then printf '%s' "$p"; return 0; fi
  lt="$WORK/tree.$(mc_key "$root" "$head")"
  [ -f "$lt" ] || (cd "$root" && git ls-tree -r --name-only "$head") > "$lt" 2>/dev/null || : > "$lt"
  n=$(awk -v s="/$p" 'length($0) >= length(s) && substr($0, length($0) - length(s) + 1) == s' "$lt" | wc -l | tr -d ' ')
  [ "$n" = 1 ] || return 1
  awk -v s="/$p" 'length($0) >= length(s) && substr($0, length($0) - length(s) + 1) == s' "$lt"
}

mc_diff_file() {
  # mc_diff_file <root> <base> <head> <path> — `git diff -U0` 결과를 담은 캐시 파일 경로.
  local f
  f="$WORK/diff.$(mc_key "$1" "$2" "$3" "$4")"
  [ -f "$f" ] || (cd "$1" && git diff -U0 "$2" "$3" -- "$4") > "$f" 2>/dev/null || : > "$f"
  printf '%s' "$f"
}

mc_in_hunk() {
  # mc_in_hunk <diff file> <line> — 새 쪽 덩어리 범위 [시작, 시작+수) 안인가.
  awk -v L="$2" '
    /^@@ / {
      x = $0; sub(/^@@ -[0-9,]+ \+/, "", x); sub(/ .*/, "", x)
      n = split(x, q, ","); st = q[1] + 0; cnt = (n > 1) ? q[2] + 0 : 1
      if (L + 0 >= st && L + 0 < st + cnt) { found = 1; exit }
    }
    END { exit found ? 0 : 1 }' "$1"
}

BUCKET=""; REASON=""; INDIFF=""

mc_classify() {
  # mc_classify <root> <is git> <mode> <base> <head> <anchor> <anchor path> <anchor line> <inherited>
  #             <unmapped> <head pin>
  # 객체를 찾지 못한 사유는 세그먼트의 레포가 지도에 없으면 `레포 미지정`, 이 행의 리뷰
  # HEAD 를 고정했다고 기록됐는데 그 HEAD 가 없으면 `고정 ref 삭제`, 그 밖은 `HEAD 없음`.
  local root="$1" isgit="$2" mode="$3" base="$4" head="$5" anc="$6" ap="$7" al="$8" inh="$9"
  local unmap="${10}" pin="${11}" rp df
  BUCKET="판정 불가"; REASON=""; INDIFF="-"
  if [ "$inh" = 1 ]; then BUCKET="기준 미해결"; REASON="-"; return 0; fi
  if [ "$anc" = "-" ] || [ "$al" = "-" ] || [ -z "$al" ]; then REASON="앵커 없음"; return 0; fi
  if [ "$isgit" != 1 ]; then REASON="git 작업 트리 아님"; return 0; fi
  case "$mode" in 델타|전체|해소) ;; *) REASON="리뷰 모드 미상"; return 0 ;; esac
  if [ "$base" = "-" ] || [ "$head" = "-" ] || ! mc_commit_ok "$root" "$base" || ! mc_commit_ok "$root" "$head"; then
    if [ "$unmap" = 1 ]; then REASON="레포 미지정"
    elif [ "$pin" = "예" ] && { [ "$head" = "-" ] || ! mc_commit_ok "$root" "$head"; }; then REASON="고정 ref 삭제"
    else REASON="HEAD 없음"
    fi
    return 0
  fi
  if ! rp=$(mc_resolve_path "$root" "$head" "$ap"); then REASON="경로 해석 불가"; return 0; fi
  df=$(mc_diff_file "$root" "$base" "$head" "$rp")
  REASON="-"
  if [ -s "$df" ]; then INDIFF=true; else INDIFF=false; fi
  if mc_in_hunk "$df" "$al"; then BUCKET="수정이 만든 발견"; INDIFF=true; return 0; fi
  if [ "$mode" = "델타" ]; then BUCKET="델타에서 처음 나온 발견"; else BUCKET="전체 재리뷰 — 기존 코드"; INDIFF="-"; fi
}

# --- 원장마다 판독 ----------------------------------------------------------

SROOT=""; SUNMAP=0

mc_seg_root() {
  # mc_seg_root <원장 이름> <원장 레포 뿌리> <세그먼트 레포> — git 조회 뿌리를 SROOT 에,
  # 지도에 없는 다른 레포면 SUNMAP=1.
  local k=0
  SROOT="$2"; SUNMAP=0
  case "$3" in -|'') return 0 ;; esac
  [ "${3##*/}" != "$1" ] || return 0
  while [ "$k" -lt "$RM_COUNT" ]; do
    if [ "${RM_KEYS[k]}" = "$3" ]; then SROOT="${RM_PATHS[k]}"; return 0; fi
    k=$((k + 1))
  done
  SUNMAP=1
}

mc_item_sum() {
  # mc_item_sum <항목 값> — `<n>` 또는 `<P0>/<P1>` 의 합, 숫자가 아니면 빈 출력.
  local a="${1%%/*}" b=0
  case "$1" in */*) b="${1#*/}" ;; esac
  [[ "$a" =~ ^[0-9]+$ && "$b" =~ ^[0-9]+$ ]] || return 0
  printf '%d' $((a + b))
}

i=0
while [ "$i" -lt "$LD_COUNT" ]; do
  label="${LD_NAMES[i]}"; root="${LD_ROOTS[i]}"
  printf 'R\t%s\t%s\t%s\n' "$label" "${LD_DIRS[i]}" "$root" >> "$ROWS"
  CF="$WORK/c.$i.tsv"; SU="$WORK/su.$i.tsv"; CJ="$WORK/cj.$i.tsv"; : > "$CF"; : > "$SU"
  while IFS= read -r f; do
    run=$(basename "$f" .md)
    mc_parse_ledger "$label" "$run" "$f" "$root" > "$WORK/one.tsv"
    grep '^S' "$WORK/one.tsv" >> "$ROWS" || true
    grep '^B' "$WORK/one.tsv" >> "$ROWS" || true
    grep -E '^(S|U)' "$WORK/one.tsv" >> "$SU" || true
    grep '^C' "$WORK/one.tsv" >> "$CF" || true
  done < <(mc_ledger_files "${LD_DIRS[i]}")
  cat "$CF" >> "$ROWS"
  # cycle 행마다 그 세그먼트의 `레포` 와 경로 재사용 표지를 덧붙인다.
  awk -F'\t' -v OFS='\t' '
    FILENAME == ARGV[1] { if ($1 == "S") r[$3 FS $4] = ($8 == "") ? "-" : $8; else u[$2 FS $3] = 1; next }
    { k = $3 FS $5; print $0, ((k in r) ? r[k] : "-"), ((($3 FS $4) in u) ? 1 : 0) }' "$SU" "$CF" > "$CJ"

  while IFS=$'\t' read -r _c _l run nr seg n dup mode p0 p1 _trig _fix _ci _ha _cr _ba rp head ph dh \
                          _ts _fps _fs _pvh pin rfmt irec _rr srepo reuse <&3; do
    [ "$dup" = 1 ] && continue
    if [ "$reuse" = 1 ]; then
      printf 'P\t%s\t%s\t%s\tpath_reuse\t0\t0\t0\t0\t0\t0\t0\t0\t0\t0\t0\n' "$label" "$run" "$nr" >> "$ROWS"
      continue
    fi
    case "$rp" in -) path="" ;; /*) path="$rp" ;; *) path="$root/$rp" ;; esac
    if [ -z "$path" ] || [ ! -f "$path" ]; then
      printf 'P\t%s\t%s\t%s\tmissing\t0\t0\t0\t0\t0\t0\t0\t0\t0\t0\t0\n' "$label" "$run" "$nr" >> "$ROWS"
      continue
    fi
    mc_parse_report "$path" > "$WORK/rep.tsv"
    IFS=$'\t' read -r _m has s0 s1 s2 s3 rmode res unres items < <(tail -n 1 "$WORK/rep.tsv")
    # 게이트가 `정합` 이라 적은 행인데 그 `항목` 과 도구의 셈이 다르면 판독 차이다.
    gap=0
    if [ "$rfmt" = "정합" ]; then
      isum=$(mc_item_sum "$irec")
      if [ -n "$isum" ] && [ "$isum" != "$items" ]; then gap=1; fi
    fi
    if [ "$has" != 1 ]; then
      printf 'P\t%s\t%s\t%s\tno_summary\t0\t0\t0\t0\t0\t%s\t%s\t%s\t0\t0\t%s\n' "$label" "$run" "$nr" "$res" "$unres" "$items" "$gap" >> "$ROWS"
      continue
    fi
    rm_=0; im_=0
    if [ "$s0" != "$p0" ] || [ "$s1" != "$p1" ]; then rm_=1; fi
    if [ "$items" != $((s0 + s1)) ]; then im_=1; fi
    state=ok; [ "$im_" = 1 ] && state=item_mismatch; [ "$rm_" = 1 ] && state=row_mismatch
    printf 'P\t%s\t%s\t%s\t%s\t1\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$label" "$run" "$nr" "$state" "$s0" "$s1" "$s2" "$s3" "$res" "$unres" "$items" "$rm_" "$im_" "$gap" >> "$ROWS"
    case "$rmode" in 델타|전체|해소) ;; *) rmode="$mode" ;; esac
    # 비교 기준 HEAD — 델타면 기준 사이클의 리뷰 HEAD, 전체·해소면 앞 사이클 행의 리뷰 HEAD.
    if [ "$rmode" = "델타" ]; then base="$dh"; else base="$ph"; fi
    mc_seg_root "$label" "$root" "$srepo"
    isgit=0; [ -e "$SROOT/.git" ] && isgit=1
    while IFS=$'\t' read -r _i sev tag anc ap al inh <&4; do
      [ "$_i" = I ] || continue
      if [ "$n" -le 1 ]; then
        printf 'F\t%s\t%s\t%s\t%s\t%s\t%s\t-\t-\t-\t%s\t%s\n' "$label" "$run" "$nr" "$sev" "$tag" "$anc" "$seg" "$srepo" >> "$ROWS"
        continue
      fi
      mc_classify "$SROOT" "$isgit" "$rmode" "$base" "$head" "$anc" "$ap" "$al" "$inh" "$SUNMAP" "$pin"
      printf 'F\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$label" "$run" "$nr" "$sev" "$tag" "$anc" "$BUCKET" "$REASON" "$INDIFF" "$seg" "$srepo" >> "$ROWS"
    done 4< "$WORK/rep.tsv"
  done 3< "$CJ"
  i=$((i + 1))
done

# --- 집계 (jq) --------------------------------------------------------------

TRIG='["첫 사이클","리뷰 P0","리뷰 P1","CI 실패","베이스 병합 해소","중단·재시도","미상","앞 사이클 행 없음","중복 행"]'
FIX='["리드 수정","재수렴","구현","기록 없음"]'
BUCK='["기준 미해결","수정이 만든 발견","델타에서 처음 나온 발견","전체 재리뷰 — 기존 코드","판정 불가"]'

AGG="$WORK/agg.json"
jq -R -s --arg schema "$SCHEMA" --arg selector "$SELECTOR" --arg since "$SINCE" --arg until "$UNTIL" \
   --argjson TRIG "$TRIG" --argjson FIX "$FIX" --argjson BUCK "$BUCK" '
  def num: if . == "" or . == "-" then 0 else (try tonumber catch 0) end;
  def nul: if . == "" or . == "-" then null else . end;
  def r2(a; b): if b == 0 then null else (((a * 100 / b) | round) / 100) end;
  def med: sort | length as $l | if $l == 0 then null elif $l % 2 == 1 then .[($l - 1) / 2] else ((.[$l / 2 - 1] + .[$l / 2]) / 2) end;
  def zero($ks): reduce $ks[] as $k ({}; .[$k] = 0);
  def sumof(f): map(f) | add // 0;
  def sev4: reduce .[] as $s ({"P0": 0, "P1": 0, "P2": 0, "P3": 0};
              .P0 += $s[0] | .P1 += $s[1] | .P2 += $s[2] | .P3 += $s[3]);
  ["첫 사이클", "중복 행", "첫 리뷰"] as $FIRSTS
  | ($TRIG - $FIRSTS) as $LATER_TRIG
  | (split("\n") | map(select(length > 0) | split("\t"))) as $rows
  | [ $rows[] | select(.[0] == "R") | {label: .[1], ledger_dir: .[2], repo_root: .[3]} ] as $R
  | ( reduce ($rows[] | select(.[0] == "P")) as $p ({};
        .[$p[1] + "\t" + $p[2] + "\t" + $p[3]] = {state: $p[4], has: ($p[5] == "1"),
          s: ([$p[6], $p[7], $p[8], $p[9]] | map(num)), res: ($p[10] | num), unres: ($p[11] | num),
          items: ($p[12] | num), rm: ($p[13] == "1"), im: ($p[14] == "1"), gap: ($p[15] == "1")}) ) as $P
  | ( reduce ($rows[] | select(.[0] == "F")) as $f ({};
        .[$f[1] + "\t" + $f[2] + "\t" + $f[3]] += [{run: $f[2], segment: $f[10], repo: ($f[11] | nul),
          severity: $f[4], tag: ($f[5] | nul), anchor: ($f[6] | nul),
          bucket: ($f[7] | nul), reason: ($f[8] | nul),
          in_diff: (if $f[9] == "true" then true elif $f[9] == "false" then false else null end)}]) ) as $F
  | ( reduce ($rows[] | select(.[0] == "C")) as $c ({};
        ($c[1] + "\t" + $c[2] + "\t" + $c[3]) as $k
        | .[$c[1] + "\t" + $c[2] + "\t" + $c[4]] += [{
            run: $c[2], seg: $c[4], n: ($c[5] | num), dup: ($c[6] == "1"), mode: ($c[7] | nul),
            p0: ($c[8] | num), p1: ($c[9] | num), trigger: $c[10], fix_path: ($c[11] | nul),
            flags: {ci_failed: ($c[12] == "1"), halted: ($c[13] == "1"), review_crash: ($c[14] == "1"), base_resolve: ($c[15] == "1")},
            report: ($c[16] | nul), trigger_source: $c[20],
            fix_paths: (if $c[21] == "-" then [] else ($c[21] | split(",")) end), fix_path_source: $c[22],
            prev_head: ($c[23] | nul), head_pin: ($c[24] | nul), report_format: ($c[25] | nul),
            router_reason: ($c[27] | nul),
            _p: ($P[$k] // null), findings: ($F[$k] // [])}]) ) as $CY
  | [ $rows[] | select(.[0] == "S") | {label: .[1], run: .[2], id: .[3], cat: .[4], state: .[5],
        mrows: (.[6] | num), repo: (.[7] | nul), worktree: (.[8] | nul)}
      | . + {cyc: ($CY[.label + "\t" + .run + "\t" + .id] // [])} ] as $SG
  | [ $rows[] | select(.[0] == "B") | {label: .[1], run: .[2], seg: .[3], head: .[4]} ] as $B
  | {
      schema: $schema,
      population: {selector: $selector, since: ($since | nul), until: ($until | nul)},
      repos: [ $R[] | . as $r
        | [ $SG[] | select(.label == $r.label) | . + {dc: ([.cyc[] | select(.dup | not)] | length)} ] as $ss
        | ($ss | map(select(.cat == "merged"))) as $mg
        | ($ss | map(select(.cat == "park"))) as $pk
        | ($ss | map(select(.cat == "other"))) as $ot
        | ($ss | map(select(.cat == "none"))) as $no
        | [ $ss[].cyc[] ] as $all
        | [ $mg[].cyc[] ] as $mall
        | ($all | map(select((.dup | not) and .n > 1))) as $later
        | ($all | map(select((.dup | not) and .n <= 1))) as $first
        | ($all | map(select(.dup | not))) as $nd
        | ($mall | map(select(.dup | not))) as $mnd
        | ([ $B[] | select(.label == $r.label) ] | unique_by([.run, .seg, .head])) as $bp
        | [ $mg[] | .run + "\t" + .id ] as $mkeys
        | def trig: reduce .[] as $c (zero($TRIG); .[$c.trigger] += 1);
          def tfp: reduce (.[] | select(.trigger as $t | $FIRSTS | index([$t]) | not)) as $c
                     (reduce $LATER_TRIG[] as $t ({}; .[$t] = zero($FIX)); .[$c.trigger][$c.fix_path // "-"] += 1);
          def src(f): {recorded: (map(select(f == "recorded")) | length), inferred: (map(select(f == "inferred")) | length)};
          def rlist(f): map(select(f) | {run, segment: .seg, n, report});
        $r + {
          ticket: {merged_rows: ($ss | sumof(.mrows)), cycle_rows: ($all | length),
                   per_segment: r2(($all | length); ($ss | sumof(.mrows)))},
          segments: {
            merged: {count: ($mg | length), cycles: ($mg | sumof(.dc)), mean: r2(($mg | sumof(.dc)); ($mg | length)),
                     median: ($mg | map(.dc) | med), max: ($mg | map(.dc) | max)},
            park: {count: ($pk | length), cycles: ($pk | sumof(.dc))},
            other: {count: ($ot | length), cycles: ($ot | sumof(.dc)),
                    by_state: (reduce $ot[] as $s ({}; .[$s.state] += 1))},
            no_segment_row: {count: ($no | length), cycles: ($no | sumof(.dc))}},
          decomposition: {
            cycle_rows: {merged: ($mg | sumof(.dc)), park: ($pk | sumof(.dc)), other: ($ot | sumof(.dc)),
                         no_segment_row: ($no | sumof(.dc)), duplicate: ($all | map(select(.dup)) | length)},
            merged_rows: {segments: ($mg | length), duplicate: ($mg | sumof(.mrows - 1))}},
          triggers: {merged: ($mall | trig), all: ($all | trig)},
          trigger_by_fix_path: {merged: ($mall | tfp), all: ($all | tfp)},
          sources: {trigger: ($mnd | src(.trigger_source)), fix_path: ($mnd | src(.fix_path_source))},
          resolve_by_prev_head: (reduce ($mnd[] | select(.trigger == "해소 리뷰")) as $c ({}; .[$c.prev_head // "(없음)"] += 1)),
          resolve_skipped_by_patch_id: {
            merged: ($bp | map(select((.run + "\t" + .seg) as $k | $mkeys | index([$k]))) | length),
            all: ($bp | length)},
          router_reasons: ($nd | map(select(.router_reason != null) | {run, segment: .seg, n, reason: .router_reason})),
          findings: {
            buckets: (reduce ($later[].findings[]) as $x (zero($BUCK); .[$x.bucket] += 1)),
            unread: ($later | map(select(._p.state == "missing" or ._p.state == "no_summary" or ._p.state == "path_reuse")) | sumof(.p0 + .p1)),
            read_gap: ($later | map(select(._p.has)) | sumof(.p0 + .p1 - ._p.items)),
            by_tag: (reduce ($later[].findings[]) as $x ({}; .[$x.bucket][$x.tag // "(없음)"] += 1)),
            first_cycle_by_tag: (reduce ($first[].findings[]) as $x ({}; .[$x.tag // "(없음)"] += 1)),
            severity: {first: ($first | map(select(._p.has) | ._p.s) | sev4),
                       later: ($later | map(select(._p.has) | ._p.s) | sev4)},
            rejudge: {"해결됨": ($later | sumof(._p.res // 0)), "미해결": ($later | sumof(._p.unres // 0))}},
          reports: {missing: ($nd | rlist(._p.state == "missing")), no_summary: ($nd | rlist(._p.state == "no_summary")),
                    row_mismatch: ($nd | rlist(._p.rm)), item_mismatch: ($nd | rlist(._p.im)),
                    path_reuse: ($nd | rlist(._p.state == "path_reuse")),
                    format_mismatch_recorded: ($nd | rlist(.report_format == "불일치")),
                    gate_tool_gap: ($nd | rlist(._p.gap // false))}
        } ],
      segments: [ $SG[] | {label, run, id, state, repo, worktree,
        cycles: [ .cyc[] | {n, mode, p0, p1, trigger, trigger_source, fix_path, fix_paths, fix_path_source,
                            prev_head, head_pin, report_format, router_reason, flags, report,
                            report_state: (._p.state // null), findings} ]} ]
    }' "$ROWS" > "$AGG"

# --- 출력 -------------------------------------------------------------------

jq -r --argjson TRIG "$TRIG" --argjson FIX "$FIX" --argjson BUCK "$BUCK" '
  def v: if . == null then "-" else tostring end;
  def row($name; f): ([$name] + [.repos[] | f | v]) | join("\t");
  def pct(a; b): if b == 0 then "-" else (((a * 1000 / b) | round) / 10 | tostring) + "%" end;
  ["첫 사이클", "중복 행", "첫 리뷰"] as $FIRSTS
  | def later_sum($t): [$t | to_entries[] | .key as $k | select($FIRSTS | index([$k]) | not) | .value] | add // 0;
  def top3: to_entries | sort_by(-.value, .key) | .[:3] | map("\(.key) \(.value)") | join(", ") | if . == "" then "-" else . end;
  def kv: to_entries | map("\(.key) \(.value)") | join(", ") | if . == "" then "-" else . end;
  . as $d
  # 행에 기록된 토큰 가운데 옛 어휘에 없는 것은 어느 레포에든 나왔을 때만 행이 된다.
  | ($TRIG + (([.repos[].triggers.merged | keys[]] | unique) - $TRIG)) as $TROWS
  | (($TROWS - $FIRSTS)) as $XTRIG
  | ($FIX + (([.repos[].trigger_by_fix_path.merged[] | keys[]] | unique) - $FIX)) as $XFIX
  | {"path_reuse": "판독 불가(경로 재사용)", "format_mismatch_recorded": "형식 불일치(기록)",
     "gate_tool_gap": "gate·도구 판독 차이"} as $RNAME
  | "# 리뷰 사이클 원인 측정",
    "# 모집단: 원장 디렉터리 바로 아래 \(.population.selector) · 기간 \(.population.since // "처음") ~ \(.population.until // "끝") (런 id 날짜, 양 끝 포함)",
    (.repos[] | "# 원장 \(.label) = \(.ledger_dir)"),
    "",
    "## 1. 사이클 표",
    row("항목"; .label),
    row("티켓 정의 — 머지됨 행"; .ticket.merged_rows),
    row("티켓 정의 — cycle 행"; .ticket.cycle_rows),
    row("티켓 정의 — 세그먼트당"; .ticket.per_segment),
    row("보정 정의 — 머지된 세그먼트"; .segments.merged.count),
    row("보정 정의 — 그 사이클"; .segments.merged.cycles),
    row("보정 정의 — 평균"; .segments.merged.mean),
    row("보정 정의 — 중앙값"; .segments.merged.median),
    row("보정 정의 — 최대"; .segments.merged.max),
    row("park 세그먼트 / 사이클"; "\(.segments.park.count) / \(.segments.park.cycles)"),
    row("그 밖 세그먼트 / 사이클"; "\(.segments.other.count) / \(.segments.other.cycles)"),
    row("세그먼트 행 없음 / 사이클"; "\(.segments.no_segment_row.count) / \(.segments.no_segment_row.cycles)"),
    row("분해 — cycle 행 = 머지 + park + 그 밖 + 세그먼트 행 없음 + 중복";
        .decomposition.cycle_rows as $c | "\(.ticket.cycle_rows) = \($c.merged) + \($c.park) + \($c.other) + \($c.no_segment_row) + \($c.duplicate)"),
    row("분해 — 머지됨 행 = 머지된 세그먼트 + 중복 머지됨 행";
        .decomposition.merged_rows as $m | "\(.ticket.merged_rows) = \($m.segments) + \($m.duplicate)"),
    "",
    "## 2. 계기 (머지된 세그먼트, 비율은 2번째 이후 사이클 기준)",
    row("계기"; .label),
    row("기록 / 추론 (cycle 행)"; "\(.sources.trigger.recorded) / \(.sources.trigger.inferred)"),
    ($TROWS[] as $t | $d | row($t; .triggers.merged as $m | ($m[$t] // 0) as $x
        | if ($FIRSTS | index([$t])) then $x else "\($x) (\(pct($x; later_sum($m))))" end)),
    ( if ([.repos[].resolve_by_prev_head | length] | add // 0) > 0
      then row("해소 리뷰 × 앞 HEAD"; .resolve_by_prev_head | kv) else empty end ),
    ( if ([.repos[].resolve_skipped_by_patch_id.all] | add // 0) > 0
      then row("해소 리뷰 생략(패치 동일)"; .resolve_skipped_by_patch_id | "\(.merged) / \(.all)") else empty end ),
    "",
    "## 2b. 계기 × 수정 경로 (머지된 세그먼트)",
    row("계기 × 수정 경로"; .label),
    row("기록 / 추론 (cycle 행)"; "\(.sources.fix_path.recorded) / \(.sources.fix_path.inferred)"),
    ( [ $XTRIG[] as $t | $XFIX[] as $f
        | select([$d.repos[] | .trigger_by_fix_path.merged[$t][$f] // 0] | add > 0) | [$t, $f] ][]
      | . as [$t, $f] | $d | row("\($t) × \($f)"; .trigger_by_fix_path.merged[$t][$f] // 0) ),
    "",
    "## 2c. 라우터 판단 사유",
    ( .repos[] | . as $r | $r.router_reasons[]
      | "\($r.label)\t\(.run)\t\(.segment)\t사이클 \(.n)\t\(.reason)" ),
    "",
    "## 3. 발견 성격 (2번째 이후 사이클의 P0·P1)",
    row("버킷"; .label),
    ($BUCK[] as $b | $d | row($b; .findings as $f
        | ([$f.buckets[]] | add) as $s | "\($f.buckets[$b]) (\(pct($f.buckets[$b]; $s)))")),
    row("리포트 판독 불가"; .findings.unread),
    row("판독 차이"; .findings.read_gap),
    row("재판정 — 해결됨"; .findings.rejudge["해결됨"]),
    row("재판정 — 미해결"; .findings.rejudge["미해결"]),
    "",
    "## 4. 분포",
    row("분포"; .label),
    ($BUCK[] as $b | $d | row("부류 태그 상위 — \($b)"; (.findings.by_tag[$b] // {}) | top3)),
    row("부류 태그 상위 — 첫 사이클"; .findings.first_cycle_by_tag | top3),
    row("심각도 — 첫 사이클 P0/P1/P2/P3"; .findings.severity.first | "\(.P0)/\(.P1)/\(.P2)/\(.P3)"),
    row("심각도 — 이후 사이클 P0/P1/P2/P3"; .findings.severity.later | "\(.P0)/\(.P1)/\(.P2)/\(.P3)"),
    "",
    "## 5. 리포트 상태 목록",
    ( .repos[] | . as $r | (["missing", "no_summary", "row_mismatch", "item_mismatch",
                             "path_reuse", "format_mismatch_recorded", "gate_tool_gap"][]) as $k
      | $r.reports[$k][] | "\($r.label)\t\($RNAME[$k] // $k)\t\(.run)\t\(.segment)\t사이클 \(.n)\t\(.report // "-")" )
' "$AGG"

if [ -n "$JSON_OUT" ]; then
  # 키는 정렬하되 schema 를 첫 키로 둔다 — 같은 입력이면 같은 바이트다.
  jq -S . "$AGG" | jq '{schema} + del(.schema)' > "$JSON_OUT"
else
  echo "# JSON: --json <경로> 를 주면 같은 집계를 그 경로에 JSON 으로 쓴다"
fi
