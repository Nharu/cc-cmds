#!/usr/bin/env bash
# Test the successor verdict and the deriver (orchestrator/successor.sh).
#
# WHAT THIS SUITE IS FOR. The deriver writes a run's authorization without a
# person present, so what it may change is the whole of its safety: a byte it
# changes that the admission check does not expect is a run refused at its first
# gate entry, and a byte it changes that the check does not look at is a widened
# authorization nobody agreed to. So the copy is compared line by line against
# the predecessor, and every line that differs is named.
#
# The verdict's order is the contract — an integer terminal-act cap before any
# cause, a park row before the token, the earliest end row over a later one —
# so each branch is driven from a ledger the real writers produced: the gate's
# rows through the gate's own `gate_append` and `gate_end_row`, the driver's
# through run.sh's `ledger_row`. A fixture that hand-wrote rows would test the
# reader against this file's idea of the rows.
#
# Every program call goes through `rk`, which strips `CC_PIPELINE_RUN_ID`: this
# suite runs inside implementation stages that inherit the pipeline variables,
# and the program refuses outright there. Exactly one case calls it with the
# variable set, to assert that refusal.
#
# Usage: bash scripts/test-successor.sh

set -uo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
ORCH="$repo_root/plugins/cc-cmds/orchestrator"
REKICK="$ORCH/successor.sh"
GATE_SH="$ORCH/gate.sh"

# Physical, because the target row's common git directory is compared with what
# git prints, and git prints the resolved path (`/private/var` for `/var`).
W=$(mktemp -d "${TMPDIR:-/tmp}/cc-rekick-test.XXXXXX")
# Section 6e starts real runs, and each leaves a watcher and a CI poller behind.
trap 'for f in "$W"/e2e/home/.local/state/cc-cmds/run/*/watch.pid "$W"/e2e/home/.local/state/cc-cmds/run/*/checks.pid; do
        [ -f "$f" ] && kill -TERM "$(sed -n 1p "$f")" 2>/dev/null; done; rm -rf "$W"' EXIT
W=$(cd "$W" && pwd -P)

passed=0
failed=0
ok()    { passed=$((passed + 1)); printf 'PASS: %s\n' "$1"; }
bad()   { failed=$((failed + 1)); printf 'FAIL: %s — %s\n' "$1" "${2:-}" >&2; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got '$2', want '$3'"; fi; }

for v in $(compgen -e | grep -E '^(CC_PIPELINE_|CC_CMDS_AUTOPILOT_DEFAULT)' || true); do
  unset "$v"
done
CC_CMDS_AUTOPILOT_NOTIFY=0
export CC_CMDS_AUTOPILOT_NOTIFY
# The gate starts a dashboard server for a run that holds a pending approval,
# and a server started under this suite's run root outlives the suite.
CC_CMDS_DASHBOARD=off
export CC_CMDS_DASHBOARD
HOME="$W/home"; mkdir -p "$HOME"
export HOME
unset XDG_CONFIG_HOME XDG_STATE_HOME
RUN_PACE_ROOT="$W/pace"; mkdir -p "$RUN_PACE_ROOT"
export RUN_PACE_ROOT
TZ=Asia/Seoul
export TZ

rk() { env -u CC_PIPELINE_RUN_ID "$BASH" "$REKICK" "$@"; }

# hx <shell body> — the body runs in a fresh bash that sourced the gate (and
# through it the driver and this program's functions).
cat > "$W/hx.sh" <<'HXEOF'
GATE="$1"; BODY="$2"
HP="$PATH"
CC_GATE_SOURCE_ONLY=1
export CC_GATE_SOURCE_ONLY
# shellcheck disable=SC1090
. "$GATE" >/dev/null 2>&1 || exit 9
PATH="$HP"
unset CC_GATE_SOURCE_ONLY CC_ORCH_SOURCE_ONLY
set +e
eval "$BODY"
HXEOF
hx() { "$BASH" "$W/hx.sh" "$GATE_SH" "$1"; }

# ---------------------------------------------------------------------------
# Fixture: one origin repository, its run directory beside it, and runs in it.
# ---------------------------------------------------------------------------
REPO="$W/repo"
mkdir -p "$REPO/docs/pipeline-run" "$REPO/docs/pipeline-grant"
( cd "$REPO" && git init -q -b master . && git -c user.name=t -c user.email=t@invalid \
    -c commit.gpgsign=false commit -q --allow-empty -m base ) || { echo "repo init failed" >&2; exit 1; }
PR="$REPO/docs/pipeline-run"
PG="$REPO/docs/pipeline-grant"
printf '# 픽스처 설계\n\n**상태**: 동결됨\n' > "$REPO/docs/x.md"
DOC_SHA=$(shasum -a 256 "$REPO/docs/x.md" | cut -d' ' -f1)

# mk_root <id> [<연쇄 상한>] [<말단 행위 상한>] [<마지막 킥오프 단계>] [<절단점>]
mk_root() {
  local id="$1" ccap="${2:-3}" tcap="${3:-없음}" last="${4:-기동 직전}" cut="${5:-PR}" dsha="${6:-(해당 없음)}" m
  m="$PR/$id.plan.md"
  cat > "$m" <<EOF
# 파이프라인 런 매니페스트 — $id
<!-- cc-run-manifest v1; writer=autopilot; reader=orchestrator; run-id=$id; anchor-kind=intent; anchor-key=rk-fixture; owner-doc=docs/x.md; origin-worktree=$REPO; NOT a design doc; mechanism-local, never staged by a skill -->

## 런 정체
**킥오프 일시**: 2026-10-01T00:00:00Z
**런 id**: $id
**앵커 종류**: intent
**앵커 키**: rk-fixture
**사용자 확인 문면**: 승인 / 이대로

## 의도
\`\`\`text
픽스처 의도
\`\`\`

## 대상
**대상 맵 다이제스트**: 0000000000000000000000000000000000000000000000000000000000000000
- \`target\` | 별칭=home | 메인 워크트리=$REPO | 공통 git 디렉터리=$REPO/.git | 베이스 브랜치=master | 홈=예 | 원격 슬러그=Nharu/cc-cmds | 절단점=$cut | 말단 행위 상한=$tcap

## 요소
**설계 문서**: docs/x.md
**설계 문서 전체 sha256**: $dsha

## 인가
**구속 다이제스트**: @@B@@
**런 최대 절단점**: $cut
**종료 지점**: 픽스처 종료 지점
- \`종료 절\` | id=C1 | 문면=픽스처 절
**벽시계 마감**: 2026-10-02T09:00:00+09:00
**비용 천장**: 없음
**무진전 상한**: 없음
- \`재킥오프\` | 연쇄 상한=$ccap | 길이=PT8H | 사유=픽스처 동의
- \`사전 인가\` | 인터뷰 기록=docs/pipeline-run/$id.interview.md | sha256=1111111111111111111111111111111111111111111111111111111111111111
EOF
  local bd td
  td=$(hx "MANIFEST='$m'; canonical_targets | shasum -a 256 | cut -d' ' -f1")
  sed "s/^\*\*대상 맵 다이제스트\*\*: .*/**대상 맵 다이제스트**: $td/" "$m" > "$m.t" && mv "$m.t" "$m"
  bd=$(hx "rekick_binding_digest '$m'")
  sed "s/@@B@@/$bd/" "$m" > "$m.t" && mv "$m.t" "$m"
  cat > "$PG/$id.md" <<EOF
# 파이프라인 인가 기록 — $id
<!-- cc-pipeline-grant v1; writer=autopilot; reader=orchestrator; owner-doc=docs/x.md; origin-worktree=$REPO; NOT a design doc; mechanism-local, never staged by a skill -->

## 인가 $id
**인가 일시**: 2026-10-01T00:00:30Z
**종료 지점**: 픽스처 종료 지점
**권한 절단점**: $cut
**말단 행위 상한**: $tcap
**직렬 웨이브 고지**: 해당 없음
**시각 정합 마커**: 없음
**사용자 확인 문면**: 승인 / 이대로
**설계 문서 전체 sha256**: $dsha
**보고서**: $PR/$id.md
EOF
  {
    printf '<!-- cc-run-kickoff v1; writer=autopilot (kickoff); reader=autopilot (kickoff resume, next kickoff Step 2, --report); run-id=%s; NOT a design doc; mechanism-local, never staged by a skill -->\n' "$id"
    printf -- '- 2026-10-01T00:00:10Z | 단계=승인\n'
    printf -- '- 2026-10-01T00:00:20Z | 단계=%s\n' "$last"
  } > "$PR/$id.kickoff.md"
}

# led_open <id> — a ledger with the gate's `run` row carrying the document digest.
led_open() {
  local id="$1"
  mkdir -p "$W/rd/$id"
  printf '## 실행 %s\n' "$id" > "$PR/$id.md"
  hx "RUN_DIR='$W/rd/$id'; LEDGER='$PR/$id.md'; RUN_ID='$id'
      gate_append 'run' 'run-id=$id' '시작=2026-10-01T00:01:00Z' '설계 문서=docs/x.md' \
        '전체 sha256=$DOC_SHA' '구속면 다이제스트=s' 'RUN_DIR=$W/rd/$id' '보고서=$PR/$id.md'" >/dev/null 2>&1
}
# g <id> <gate body> — a gate call against that run's ledger.
g() { hx "RUN_DIR='$W/rd/$1'; LEDGER='$PR/$1.md'; RUN_ID='$1'; $2" >/dev/null 2>&1; }
end_row() { g "$1" "gate_end_row 픽스처 '픽스처 종료' '$2' '${3:-}' '${4:-}'"; }
progress() { g "$1" "gate_append 'cycle' '세그먼트=A' '사이클=1' 'P0=0' 'P1=0'"; }
verdict() { rk verdict "$PR/$1.plan.md" --lane present --pin none; }
vcol() { printf '%s' "$1" | cut -f"$2"; }

R0=20261001-0000aaa0

# ---------------------------------------------------------------------------
# 1. The successor id.
# ---------------------------------------------------------------------------
ID1=$(rk id 2026-10-03T00:00:00Z "$R0" 1)
ID1b=$(rk id 2026-10-03T00:00:00Z "$R0" 1)
WANT1="20261003-$(printf 'rekick|%s|1' "$R0" | shasum -a 256 | cut -c1-8)"
check "후속 id 는 산식대로다" "$ID1" "$WANT1"
check "같은 입력의 후속 id 는 같다" "$ID1b" "$ID1"
ID2=$(rk id 2026-10-03T00:00:00Z "$R0" 2)
[ "$ID2" != "$ID1" ] && ok "순번이 다르면 id 가 다르다" || bad "순번이 다르면 id 가 다르다" "$ID2"
rk id 2026-10-03T09:00:00+09:00 "$R0" 1 >/dev/null 2>&1
check "Z 가 아닌 재킥오프 시각은 id 를 내지 않는다" "$?" "2"

# ---------------------------------------------------------------------------
# 2. Refused inside a pipeline stage, and no kickoff defaults anywhere.
# ---------------------------------------------------------------------------
out=$(CC_PIPELINE_RUN_ID=x "$BASH" "$REKICK" id 2026-10-03T00:00:00Z "$R0" 1 2>&1)
check "CC_PIPELINE_RUN_ID 가 있으면 거부한다" "$?" "2"
case "$out" in *CC_PIPELINE_RUN_ID*) ok "거부 문면이 변수를 부른다" ;; *) bad "거부 문면이 변수를 부른다" "$out" ;; esac
check "파생기 소스가 기본값 파일과 그 도구를 이름 부르지 않는다" \
  "$(grep -cE 'kickoff-defaults|autopilot-defaults|DEFAULTS_FILE' "$REKICK" || true)" "0"

# ---------------------------------------------------------------------------
# 3. Derivation from a root that ended on its deadline.
# ---------------------------------------------------------------------------
mk_root "$R0"
led_open "$R0"
end_row "$R0" 마감
mkdir -p "$W/claim1"; printf '2026-10-03T00:00:00Z\n' > "$W/claim1/at"

v=$(verdict "$R0")
check "마감으로 끝난 뿌리는 자동이다" "$(vcol "$v" 1)/$(vcol "$v" 2)" "자동/마감"

# The defaults file present under HOME must change nothing — the output and the
# files are the same as without it.
mkdir -p "$HOME/.config/cc-cmds"; printf 'deadline=+1h\n' > "$HOME/.config/cc-cmds/autopilot-defaults"
out=$(rk derive --predecessor "$PR/$R0.plan.md" --claim "$W/claim1" --verdict 자동)
rc=$?
check "파생은 열림으로 끝난다" "$rc/$(vcol "$out" 1)/$(vcol "$out" 2)" "0/열림/$ID1"
check "파생기가 낸 문서 해시는 앞 런 원장에 기록된 값이다" "$(vcol "$out" 4)" "$DOC_SHA"
S1="$PR/$ID1.plan.md"
for f in "$S1" "$PG/$ID1.md" "$PR/$ID1.kickoff.md"; do
  [ -f "$f" ] && ok "후속 파일이 생겼다: $(basename "$f")" || bad "후속 파일이 생겼다" "$f"
done

# The manifest differs from the root's in exactly the allowed lines.
dm=$(diff "$PR/$R0.plan.md" "$S1" | grep -E '^[<>] ' | sed -E 's/^([<>]) (\*\*[^*]+\*\*|- `[^`]+`|#|<!--).*/\1 \2/' | sort | tr '\n' ';')
check "후속 매니페스트는 허용 변경분만 다르다" "$dm" \
  "$(printf '%s\n' '< #' '< <!--' '< **킥오프 일시**' '< **런 id**' '< **구속 다이제스트**' '< **벽시계 마감**' \
     '> #' '> <!--' '> **킥오프 일시**' '> **런 id**' '> **구속 다이제스트**' '> **벽시계 마감**' '> - `연쇄`' | sort | tr '\n' ';')"
check "후속 매니페스트의 런 id 세 자리" \
  "$(sed -n 1p "$S1" | sed 's/.*— //')/$(sed -n 2p "$S1" | sed -E 's/.*run-id=([^;]*);.*/\1/')/$(sed -n 's/^\*\*런 id\*\*: //p' "$S1")" \
  "$ID1/$ID1/$ID1"
check "후속 킥오프 일시는 클레임 시각이다" "$(sed -n 's/^\*\*킥오프 일시\*\*: //p' "$S1")" "2026-10-03T00:00:00Z"
check "후속 마감은 클레임 시각 + 길이를 뿌리의 오프셋 표기로 쓴다" \
  "$(sed -n 's/^\*\*벽시계 마감\*\*: //p' "$S1")" "2026-10-03T17:00:00+09:00"
RD0=$(sed -n 's/^\*\*구속 다이제스트\*\*: //p' "$PR/$R0.plan.md")
check "연쇄 행은 첫 고리의 위치·선행 다이제스트·원인을 싣는다" "$(grep '^- `연쇄`' "$S1")" \
  "- \`연쇄\` | 뿌리 런=$R0 | 선행 런=$R0 | 순번=1 | 선행 구속 다이제스트=$RD0 | 재킥오프 시각=2026-10-03T00:00:00Z | 원인=마감"
check "연쇄 행은 재킥오프 행 바로 뒤에 온다" \
  "$(grep -A1 '^- `재킥오프`' "$S1" | sed -n 2p | grep -c '^- `연쇄` ' || true)" "1"
check "후속 구속 다이제스트는 후속 매니페스트의 바이트로 다시 계산한 값이다" \
  "$(sed -n 's/^\*\*구속 다이제스트\*\*: //p' "$S1")" "$(hx "rekick_binding_digest '$S1'")"
# Recomputed in a child that rebinds the manifest, the stored digest of the
# predecessor still holds, and the current manifest's memo does not leak in.
check "앞 런 매니페스트로 다시 계산한 다이제스트가 저장값과 같다 (메모가 새지 않는다)" \
  "$(hx "MANIFEST='$S1'; manifest_snapshot_take >/dev/null 2>&1; rekick_binding_digest '$PR/$R0.plan.md'")" "$RD0"

dg=$(diff "$PG/$R0.md" "$PG/$ID1.md" | grep -E '^[<>] ' | sed -E 's/^([<>]) (\*\*[^*]+\*\*|#+|<!--).*/\1 \2/' | sort | tr '\n' ';')
check "후속 인가 기록은 제목·헤더·블록 표제·보고서 경로만 다르다" "$dg" \
  "$(printf '%s\n' '< #' '< <!--' '< ##' '< **보고서**' '> #' '> <!--' '> ##' '> **보고서**' | sort | tr '\n' ';')"
check "후속 인가 기록 헤더는 파생을 적는다" \
  "$(sed -n 2p "$PG/$ID1.md" | grep -oE 'writer=rekick; derived-from=[^;]*; root=[^;]*;')" \
  "writer=rekick; derived-from=$R0; root=$R0;"
check "사용자 확인 문면은 뿌리 바이트 그대로다" \
  "$(grep '^\*\*사용자 확인 문면\*\*' "$PG/$ID1.md")" "$(grep '^\*\*사용자 확인 문면\*\*' "$PG/$R0.md")"
check "면담 기록 행은 뿌리 바이트 그대로다" \
  "$(grep '인터뷰 기록=' "$S1")" "$(grep '인터뷰 기록=' "$PR/$R0.plan.md")"
check "후속 킥오프 기록의 마지막 단계는 연기다" \
  "$(tail -1 "$PR/$ID1.kickoff.md")" "- 2026-10-03T00:00:00Z | 단계=연기"

# Resume: the same derivation again passes and changes nothing.
sum_before=$(cat "$S1" "$PG/$ID1.md" "$PR/$ID1.kickoff.md" | shasum -a 256)
rm -f "$HOME/.config/cc-cmds/autopilot-defaults"
out2=$(rk derive --predecessor "$PR/$R0.plan.md" --claim "$W/claim1" --verdict 자동)
check "같은 파생을 다시 돌리면 같은 결과로 통과한다 (기본값 파일 유무와 무관)" "$?/$out2" "0/$out"
check "재개는 파일을 바꾸지 않는다" "$(cat "$S1" "$PG/$ID1.md" "$PR/$ID1.kickoff.md" | shasum -a 256)" "$sum_before"

# A different file already there is refused and left as it is.
cp "$S1" "$W/s1.keep"
printf '\n' >> "$S1"
rk derive --predecessor "$PR/$R0.plan.md" --claim "$W/claim1" --verdict 자동 > "$W/inv.out"
check "다른 바이트의 파일이 있으면 invalid 로 끝난다" "$?/$(cut -f1 "$W/inv.out")" "3/invalid"
check "invalid 는 있던 파일을 덮지 않는다" "$(tail -c 2 "$S1" | od -An -c | tr -d ' ')" '\n\n'
cp "$W/s1.keep" "$S1"

# ---------------------------------------------------------------------------
# 4. Root provenance and the recorded document digest.
# ---------------------------------------------------------------------------
RP=20261001-0000aaa1
mk_root "$RP" 3 없음 승인
led_open "$RP"; end_row "$RP" 마감
rk derive --predecessor "$PR/$RP.plan.md" --claim "$W/claim1" --verdict 자동 > "$W/p.out"
check "킥오프 기록의 마지막 단계가 기동 쪽이 아닌 뿌리는 파생하지 않는다" "$?/$(cut -f1 "$W/p.out")" "4/사람"
check "출처 실패는 아무 파일도 쓰지 않는다" \
  "$(ls "$PR" | grep -c "^$(rk id 2026-10-03T00:00:00Z "$RP" 1)" || true)" "0"

RQ=20261001-0000aaa2
mk_root "$RQ"
printf '## 실행 %s\n' "$RQ" > "$PR/$RQ.md"; mkdir -p "$W/rd/$RQ"
end_row "$RQ" 마감
rk derive --predecessor "$PR/$RQ.plan.md" --claim "$W/claim1" --verdict 자동 > "$W/q.out"
check "게이트가 쓴 run 행이 없는 원장의 뿌리는 파생하지 않는다" "$?/$(cut -f1 "$W/q.out")" "4/사람"

RH=20261001-0000aaa3
mk_root "$RH"
printf '## 실행 %s\n' "$RH" > "$PR/$RH.md"; mkdir -p "$W/rd/$RH"
g "$RH" "gate_append 'run' 'run-id=$RH' '시작=2026-10-01T00:01:00Z' '설계 문서=docs/x.md' '전체 sha256=(해당 없음)' '구속면 다이제스트=s'"
end_row "$RH" 마감
rk derive --predecessor "$PR/$RH.plan.md" --claim "$W/claim1" --verdict 자동 > "$W/h.out"
check "기록된 문서 해시가 없으면 사람으로 끝난다" "$?/$(cat "$W/h.out")" "4/사람	기록된 문서 해시 없음"
g "$RH" "gate_append '문서 해시' '스테이지=S2 이후' 'sha256=$DOC_SHA'"
rk derive --predecessor "$PR/$RH.plan.md" --claim "$W/claim1" --verdict 자동 > "$W/h2.out"
check "게이트의 문서 해시 행만 있어도 그 값을 옮긴다" "$?/$(cut -f1,4 "$W/h2.out")" "0/열림	$DOC_SHA"

# ---------------------------------------------------------------------------
# 5. The verdict table, branch by branch.
# ---------------------------------------------------------------------------
vr() {  # vr <label> <id> <want 판정/원인> [<setup body run before>]
  local v
  v=$(verdict "$2")
  check "$1" "$(vcol "$v" 1)/$(vcol "$v" 2)" "$3"
}

RN=20261001-0000aab0; mk_root "$RN"; sed -i.bak '/^- `재킥오프`/d' "$PR/$RN.plan.md"; rm -f "$PR/$RN.plan.md.bak"
check "재킥오프 행이 없는 매니페스트는 대상이 아니다" "$(vcol "$(verdict "$RN")" 1)" "없음"

RG=20261001-0000aab1; mk_root "$RG"; led_open "$RG"
vr "종료 토큰이 없으면 진행이다" "$RG" "진행/-"
end_row "$RG" 해당없음 완료
vr "종료 부류=완료 인 해당없음은 없음이다" "$RG" "없음/-"

RU=20261001-0000aab2; mk_root "$RU"; led_open "$RU"
g "$RU" "gate_append 'blocked' '대상=other' '스코프=act' '원인=막힘' '사유=대상 미선언' '재킥 원인=대상미선언'"
end_row "$RU" 해당없음
v=$(verdict "$RU")
check "분류 없는 해당없음은 park 행이 있어도 사람이다" "$(vcol "$v" 1)/$(vcol "$v" 2)" "사람/해당없음"
case "$(vcol "$v" 3)" in *대상미선언*) ok "사람 사유에 park 행 변경분을 싣는다" ;; *) bad "사람 사유에 park 행 변경분을 싣는다" "$v" ;; esac

RK=20261001-0000aab3; mk_root "$RK"; led_open "$RK"
g "$RK" "gate_append 'blocked' '대상=other' '스코프=act' '원인=막힘' '사유=대상 미선언' '재킥 원인=대상미선언'"
end_row "$RK" 마감
vr "종료 토큰만의 판정이 자동이면 park 행이 승인으로 바꾼다" "$RK" "승인/대상미선언"

# The end token is judged first: a park row turns only `자동` and `없음` into
# `승인`, and a verdict that needs a person stays a person's.
PARK="gate_append 'blocked' '대상=other' '스코프=act' '원인=막힘' '사유=대상 미선언' '재킥 원인=대상미선언'"
PK1=20261001-0000aa90; mk_root "$PK1"; led_open "$PK1"; g "$PK1" "$PARK"; end_row "$PK1" 해당없음 완료
vr "park 행이 있으면 정상 완료도 승인이다" "$PK1" "승인/대상미선언"
PK2=20261001-0000aa91; mk_root "$PK2"; led_open "$PK2"; g "$PK2" "$PARK"; end_row "$PK2" 판단정지
vr "park 행이 있어도 판단정지는 사람이다" "$PK2" "사람/판단정지"
PK3=20261001-0000aa92; mk_root "$PK3"; led_open "$PK3"; g "$PK3" "$PARK"; end_row "$PK3" 무진전
v=$(verdict "$PK3")
check "park 행이 있어도 정지 술어가 선 고리는 사람이다" "$(vcol "$v" 1)/$(vcol "$v" 2)" "사람/무진전"
case "$(vcol "$v" 3)" in
  *"진전 없이"*대상미선언*) ok "그 사유는 종료 토큰만의 판정과 park 행 변경분을 함께 싣는다" ;;
  *) bad "그 사유는 종료 토큰만의 판정과 park 행 변경분을 함께 싣는다" "$v" ;;
esac
PK4=20261001-0000aa93; mk_root "$PK4"; led_open "$PK4"; g "$PK4" "$PARK"
g "$PK4" "gate_append 'blocked' '대상=-' '스코프=run' '원인=표면 이동' '사유=표면' '재킥 원인=표면이동'"
end_row "$PK4" 마감
vr "park 행이 있어도 자동 조건을 못 채운 표면이동은 사람이다" "$PK4" "사람/표면이동"
PK5=20261001-0000aa94; mk_root "$PK5" 1; led_open "$PK5"; end_row "$PK5" 마감
mkdir -p "$W/claim-$PK5"; printf '2026-10-03T00:00:00Z\n' > "$W/claim-$PK5/at"
P5=$(vcol "$(rk derive --predecessor "$PR/$PK5.plan.md" --claim "$W/claim-$PK5" --verdict 자동)" 2)
led_open "$P5"; g "$P5" "$PARK"; end_row "$P5" 마감
vr "park 행이 있어도 연쇄 상한에 닿은 고리는 사람이다" "$P5" "사람/마감"

RS=20261001-0000aab4; mk_root "$RS"; led_open "$RS"
g "$RS" "gate_append 'blocked' '대상=-' '스코프=run' '원인=표면 이동' '사유=표면' '재킥 원인=표면이동'"
end_row "$RS" 마감
check "표면 이동 blocked 행 뒤에 마감 종료 행이 붙어도 종료 토큰은 먼저 쓴 표면이동이다" \
  "$(hx "rekick_end_token '$PR/$RS.md'")" "표면이동"
v=$(verdict "$RS")
check "표면이동 판정은 파일별 목록이 없으면 사람이다" "$(vcol "$v" 1)/$(vcol "$v" 2)" "사람/표면이동"
# The run-scope slicing invalidation does not end the run.
RV=20261001-0000aab5; mk_root "$RV"; led_open "$RV"
g "$RV" "gate_append 'blocked' '대상=-' '스코프=run' '원인=무효화' '사유=선언' '재킥 원인=슬라이싱'"
vr "run 범위 슬라이싱 무효화 행은 종료 토큰이 아니다" "$RV" "진행/-"

RT=20261001-0000aab6; mk_root "$RT" 3 2; led_open "$RT"; end_row "$RT" 마감
vr "정수 말단 행위 상한을 가진 뿌리는 마감이어도 사람이다" "$RT" "사람/-"

v=$(rk verdict "$PR/$R0.plan.md")
check "레인을 받지 못한 판정은 사람이다" "$(vcol "$v" 1)" "사람"
v=$(rk verdict "$PR/$R0.plan.md" --lane present --pin unusable)
check "쓸 수 없는 플러그인 핀은 사람이다" "$(vcol "$v" 1)" "사람"

RJ=20261001-0000aab7; mk_root "$RJ"; led_open "$RJ"; end_row "$RJ" 판단정지
vr "판단정지는 사람이다 (재인가 승인을 올리지 않는다)" "$RJ" "사람/판단정지"
RM=20261001-0000aab8; mk_root "$RM"; led_open "$RM"; end_row "$RM" 말단상한
vr "말단상한은 사람이다" "$RM" "사람/말단상한"
RW=20261001-0000aab9; mk_root "$RW"; led_open "$RW"; end_row "$RW" 무진전
vr "진전 없이 끝난 무진전 고리는 사람이다 (정지 술어는 상한이 아니다)" "$RW" "사람/무진전"
RX=20261001-0000aaba; mk_root "$RX"; led_open "$RX"; progress "$RX"; end_row "$RX" 무진전
vr "진전한 무진전 고리는 자동이다" "$RX" "자동/무진전"
RY=20261001-0000aabb; mk_root "$RY"; led_open "$RY"; end_row "$RY" 사이클예산
vr "진전 없는 사이클예산은 사람이다" "$RY" "사람/사이클예산"
RZ=20261001-0000aabc; mk_root "$RZ"; led_open "$RZ"; end_row "$RZ" 결함 '' 'implement/S4/pin1'
vr "연쇄 안의 첫 결함은 자동이다" "$RZ" "자동/결함"

# Imported rows are the predecessor's work and do not count as progress.
RI=20261001-0000aabd; mk_root "$RI"; led_open "$RI"
g "$RI" "gate_append 'cycle' '세그먼트=A' '사이클=1' 'P0=0' 'P1=0' '출처=$R0'"
end_row "$RI" 천장
vr "들여온 행만 있는 천장 고리는 진전이 아니다" "$RI" "사람/천장"

RF=20261001-0000aabe; mk_root "$RF"
sed -i.bak 's/^\*\*상태\*\*: 동결됨$/**상태**: 초안/' "$REPO/docs/x.md"
led_open "$RF"; end_row "$RF" 마감
vr "동결되지 않은 설계 문서는 사람이다" "$RF" "사람/-"
mv "$REPO/docs/x.md.bak" "$REPO/docs/x.md"

RO=20261001-0000aabf; mk_root "$RO"; led_open "$RO"; end_row "$RO" 마감
printf '\n## 인가 20261001-0000ffff\n**인가 일시**: x\n' >> "$PG/$RO.md"
vr "남의 인가 블록이 있으면 사람이다" "$RO" "사람/-"
rm -f "$PG/$RO.md"
vr "인가 기록이 없으면 사람이다" "$RO" "사람/-"

# A ledger whose chain does not verify answers on the stopping side.
RB=20261001-0000aac0; mk_root "$RB"; led_open "$RB"; end_row "$RB" 마감
sed -i.bak -E '2s/ [|] prev=[0-9a-f]{64}$//' "$PR/$RB.md"; rm -f "$PR/$RB.md.bak"
vr "사슬 검증에 실패한 원장은 사람이다" "$RB" "사람/마감"

# ---------------------------------------------------------------------------
# 6. Along a chain: the second link, the chain cap, and the stop predicates.
# ---------------------------------------------------------------------------
# chain_next <pred id> <claim at> — derive and open the successor's ledger.
chain_next() {
  local pred="$1" at="$2" c="$W/claim-$1" out
  mkdir -p "$c"; printf '%s\n' "$at" > "$c/at"
  out=$(rk derive --predecessor "$PR/$pred.plan.md" --claim "$c" --verdict 자동) || { printf 'FAIL\n'; return 1; }
  vcol "$out" 2
}

# The root above ended on `마감`; its successor runs and ends on `마감` too.
led_open "$ID1"; end_row "$ID1" 마감
I2=$(chain_next "$ID1" 2026-10-04T00:00:00Z)
check "둘째 고리의 id 는 선행 런과 순번 2 로 정한다" "$I2" "$(rk id 2026-10-04T00:00:00Z "$ID1" 2)"
check "둘째 고리는 연쇄 행을 바꿔 쓴다 (하나, 순번 2, 같은 뿌리)" \
  "$(grep -c '^- `연쇄`' "$PR/$I2.plan.md")/$(grep '^- `연쇄`' "$PR/$I2.plan.md" | sed -E 's/.*뿌리 런=([^ ]*) .*순번=([0-9]+) .*/\1 \2/')" \
  "1/$R0 2"
check "둘째 고리의 인가 기록 root= 는 뿌리다" \
  "$(sed -n 2p "$PG/$I2.md" | grep -oE 'writer=rekick; derived-from=[^;]*; root=[^;]*;')" \
  "writer=rekick; derived-from=$ID1; root=$R0;"

# A chain cap of one stops the first successor.
RC=20261001-0000aac1; mk_root "$RC" 1; led_open "$RC"; end_row "$RC" 마감
C1=$(chain_next "$RC" 2026-10-03T00:00:00Z)
led_open "$C1"; end_row "$C1" 마감
vr "연쇄 상한에 닿은 고리는 상한이다" "$C1" "상한/마감"

# `무진전` twice in a row, each link having progressed.
RD=20261001-0000aac2; mk_root "$RD"; led_open "$RD"; progress "$RD"; end_row "$RD" 무진전
D1=$(chain_next "$RD" 2026-10-03T00:00:00Z)
led_open "$D1"; progress "$D1"; end_row "$D1" 무진전
vr "무진전이 연달아 두 번이면 사람이다" "$D1" "사람/무진전"
check "같은 원인 정지 술어가 그 연쇄를 멈춘다" "$(hx "rekick_same_cause_stop '$PR/$D1.plan.md' && echo stop")" "stop"

# The same defect fingerprint a second time in the chain.
RE=20261001-0000aac3; mk_root "$RE"; led_open "$RE"; end_row "$RE" 결함 '' 'implement/S4/pin1'
E1=$(chain_next "$RE" 2026-10-03T00:00:00Z)
led_open "$E1"; end_row "$E1" 결함 '' 'implement/S4/pin1'
vr "같은 지문의 결함이 연쇄 안에서 두 번째면 사람이다" "$E1" "사람/결함"
RE2=20261001-0000aac4; mk_root "$RE2"; led_open "$RE2"; end_row "$RE2" 결함 '' 'implement/S4/pin1'
E2=$(chain_next "$RE2" 2026-10-03T00:00:00Z)
led_open "$E2"; end_row "$E2" 결함 '' 'audit/S2/pin1'
vr "다른 지문의 결함은 다시 자동이다" "$E2" "자동/결함"

# ---------------------------------------------------------------------------
# 6b. Admission: what `check_manifest` asks of a successor, letter by letter.
# ---------------------------------------------------------------------------
# adm <manifest> — `ok`, or the first reason the admission check gives.
adm() { hx "rekick_admission_static '$1' && rekick_admission_history '$1' && echo ok"; }
# adm_is <label> <manifest> <reason prefix>
adm_is() {
  local out
  out=$(adm "$2")
  case "$out" in "$3"*) ok "$1" ;; *) bad "$1" "got '$out', want '$3…'" ;; esac
}
# with_edit <file> <sed expression> <label> <manifest> <prefix> — one edit,
# one admission, and the file put back.
with_edit() {
  cp "$1" "$W/edit.keep"
  sed -E "$2" "$W/edit.keep" > "$1"
  adm_is "$3" "$4" "$5"
  cp "$W/edit.keep" "$1"
}
# claim_commit <pred> <at> <successor> — the claim the dispatcher commits.
claim_commit() {
  mkdir -p "$RUN_PACE_ROOT/rekick/$1"
  printf '%s\n' "$2" > "$RUN_PACE_ROOT/rekick/$1/at"
  printf '%s\n' "$3" > "$RUN_PACE_ROOT/rekick/$1/successor"
}

RA=20261001-0000aad1; mk_root "$RA"; led_open "$RA"; end_row "$RA" 마감
A1=$(chain_next "$RA" 2026-10-03T00:00:00Z)
SA="$PR/$A1.plan.md"
claim_commit "$RA" 2026-10-03T00:00:00Z "$A1"
check "파생한 후속 매니페스트는 입장 검사를 지난다" "$(adm "$SA")" "ok"

with_edit "$SA" '/^- `연쇄` /p' "(가) 연쇄 행이 둘이면 거부한다" "$SA" "(가)"
with_edit "$SA" '/^- `재킥오프` /p' "(가) 재킥오프 행이 둘이면 거부한다" "$SA" "(가)"
with_edit "$PR/$RA.plan.md" 's/^(- `종료 절` \| id=C1 \| 문면=).*/\1고쳐 쓴 절/' \
  "(나) 다이제스트 필드를 그대로 둔 채 행을 고쳐 쓴 앞 런 매니페스트는 거부한다" "$SA" "(나)"
with_edit "$SA" 's/선행 구속 다이제스트=[0-9a-f]{64}/선행 구속 다이제스트=2222222222222222222222222222222222222222222222222222222222222222/' \
  "(나) 연쇄 행의 선행 구속 다이제스트가 다르면 거부한다" "$SA" "(나)"
with_edit "$SA" 's/^픽스처 의도$/넓힌 의도/' "(다) 허용 변경분 밖의 매니페스트 바이트가 다르면 거부한다" "$SA" "(다)"
with_edit "$PG/$A1.md" 's/^\*\*권한 절단점\*\*: PR$/**권한 절단점**: 머지/' \
  "(다) 인가 기록이 writer·derived-from·root 밖에서 다르면 거부한다" "$SA" "(다)"
with_edit "$SA" 's/ \| 순번=1 \| / | 순번=2 | /' "(라) 순번이 앞 런 순번 + 1 이 아니면 거부한다" "$SA" "(라)"
with_edit "$SA" "s/ \\| 뿌리 런=$RA \\| / | 뿌리 런=20261001-0000ffff | /" "(라) 뿌리 런이 앞 런이 아니면 거부한다" "$SA" "(라)"
with_edit "$SA" 's/ \| 재킥오프 시각=2026-10-03T00:00:00Z \| / | 재킥오프 시각=2026-10-04T00:00:00Z | /' \
  "(바) 재킥오프 시각을 바꿔 id 가 산식과 다르면 거부한다" "$SA" "(바)"
with_edit "$SA" 's/^\*\*벽시계 마감\*\*: .*/**벽시계 마감**: 2026-10-03T17:00:01+09:00/' "(마) 마감 +1 초는 거부한다" "$SA" "(마)"
with_edit "$SA" 's/^\*\*벽시계 마감\*\*: .*/**벽시계 마감**: 2026-10-03T16:59:59+09:00/' "(마) 마감 -1 초는 거부한다" "$SA" "(마)"
# The same instant in another notation is the deadline (마) wants: the deadline
# is an allowed change, and the binding digest that hashes its spelling is
# compared with the bytes by `check_manifest` itself.
with_edit "$SA" 's/^\*\*벽시계 마감\*\*: .*/**벽시계 마감**: 2026-10-03T08:00:00Z/' \
  "(마) 는 표기가 아니라 순간으로 비교한다" "$SA" "ok"

with_edit "$RUN_PACE_ROOT/rekick/$RA/successor" "s/.*/20261003-ffffffff/" \
  "(사) 클레임의 successor 가 이 런이 아니면 거부한다" "$SA" "(사) 클레임의 successor"
with_edit "$RUN_PACE_ROOT/rekick/$RA/at" "s/.*/2026-10-03T00:00:01Z/" \
  "(사) 클레임의 at 이 재킥오프 시각과 다르면 거부한다" "$SA" "(사) 클레임의 at"
cp "$SA" "$PR/20261003-ffffffff.plan.md"
adm_is "(사) 같은 선행 런을 가진 다른 매니페스트가 있으면 거부한다" "$SA" "(사) 같은 선행 런"
rm -f "$PR/20261003-ffffffff.plan.md"
with_edit "$SA" 's/ \| 원인=마감$/ | 원인=천장/' "(사) 원인이 앞 런의 종료 토큰과 다르면 거부한다" "$SA" "(사) 앞 런의 종료 토큰"
mv "$PR/$RA.md" "$W/ra.keep"; led_open "$RA"
adm_is "(사) 종료 토큰이 없는 앞 런은 끝나지 않은 것이다" "$SA" "(사) 앞 런의 종료 토큰이 없습니다"
mv "$W/ra.keep" "$PR/$RA.md"
with_edit "$PR/$RA.md" '2s/ [|] prev=[0-9a-f]{64}$//' "(사) 사슬 검증에 실패한 앞 런 원장은 거부한다" "$SA" "(사) 연쇄의 원장 사슬 검증 실패"
check "깨뜨린 것을 되돌리면 다시 지난다" "$(adm "$SA")" "ok"

# A no-progress link is refused by the same stop predicate the verdict reads.
RW2=20261001-0000aad2; mk_root "$RW2"; led_open "$RW2"; progress "$RW2"; end_row "$RW2" 무진전
W1=$(chain_next "$RW2" 2026-10-03T00:00:00Z)
claim_commit "$RW2" 2026-10-03T00:00:00Z "$W1"
check "진전한 무진전 고리의 후속은 지난다" "$(adm "$PR/$W1.plan.md")" "ok"
# The deriver trusts the verdict it is handed, so a successor of a link that
# made no progress can exist on disk; admission is what refuses it.
RW3=20261001-0000aad5; mk_root "$RW3"; led_open "$RW3"; end_row "$RW3" 무진전
W3=$(chain_next "$RW3" 2026-10-03T00:00:00Z)
claim_commit "$RW3" 2026-10-03T00:00:00Z "$W3"
adm_is "(사) 진전 없는 무진전 고리의 후속은 거부한다" "$PR/$W3.plan.md" "(사) 진전 없이 끝난 고리"

# An integer terminal-act cap anywhere: no reader on a successor's path.
RT2=20261001-0000aad3; mk_root "$RT2" 3 2; led_open "$RT2"; end_row "$RT2" 마감
T1=$(chain_next "$RT2" 2026-10-03T00:00:00Z)
claim_commit "$RT2" 2026-10-03T00:00:00Z "$T1"
adm_is "(사) 정수 말단 행위 상한을 가진 대상이 있으면 거부한다" "$PR/$T1.plan.md" "(사) 정수 말단 행위 상한"

# An approval cause needs a person's close, carrying the answer the row names.
RJ2=20261001-0000aad4; mk_root "$RJ2"; led_open "$RJ2"
g "$RJ2" "gate_append 'blocked' '대상=other' '스코프=act' '원인=막힘' '사유=대상 미선언' '재킥 원인=대상미선언'"
end_row "$RJ2" 마감
ADIG=3333333333333333333333333333333333333333333333333333333333333333
mkdir -p "$W/claim-$RJ2"; printf '2026-10-03T00:00:00Z\n' > "$W/claim-$RJ2/at"
out=$(rk derive --predecessor "$PR/$RJ2.plan.md" --claim "$W/claim-$RJ2" --verdict 승인 \
        --approval "$RJ2#a1" --answer-digest "$ADIG")
J1=$(vcol "$out" 2); SJ="$PR/$J1.plan.md"
claim_commit "$RJ2" 2026-10-03T00:00:00Z "$J1"
g "$RJ2" "gate_append '승인' '승인 id=a1' '상태=대기' '대상=-' '절단점=재인가' '종류=W' '재인가 원인=대상미선언' '변경분=-'"
adm_is "(사) 아직 대기인 재인가 승인은 거부한다" "$SJ" "(사) 재인가 승인 $RJ2#a1 이 승인으로"
g "$RJ2" "gate_append '승인' '승인 id=a1' '상태=승인' '응답 토큰=-' '답변 다이제스트=-' '처분 사유=자동 해소'"
adm_is "(사) 자동 해소로 닫힌 승인은 사람의 승인이 아니다" "$SJ" "(사) 재인가 승인 $RJ2#a1 에 사람의 응답 토큰이 없습니다"
# A token and the matching digest do not make an automatic close a person's.
g "$RJ2" "gate_append '승인' '승인 id=a1' '상태=승인' '응답 토큰=t-auto' '답변 다이제스트=$ADIG' '처분 사유=자동 해소'"
adm_is "(사) 토큰이 있어도 자동 해소로 닫힌 W 승인은 거부한다" "$SJ" "(사) 재인가 승인 $RJ2#a1 은 자동 해소로 닫혔습니다"
g "$RJ2" "gate_append '승인' '승인 id=a1' '상태=승인' '응답 토큰=t1' '답변 다이제스트=4444444444444444444444444444444444444444444444444444444444444444'"
adm_is "(사) 답변 다이제스트가 다른 승인은 거부한다" "$SJ" "(사) 연쇄 행의 답변 다이제스트"
g "$RJ2" "gate_append '승인' '승인 id=a1' '상태=승인' '응답 토큰=t1' '답변 다이제스트=$ADIG'"
check "사람이 닫은 같은 답변의 승인이면 지난다" "$(adm "$SJ")" "ok"
with_edit "$SJ" 's/ \| 재인가 승인=[^|]* \| 답변 다이제스트=[0-9a-f]{64}$//' \
  "(사) 승인 원인인데 재인가 승인이 없으면 거부한다" "$SJ" "(사) 원인 대상미선언 은 재인가 승인이"

# A judgment stop opens no successor: a row naming it is refused with a
# person's close attached and without one. The deriver trusts the verdict it is
# handed, so both manifests can exist on disk; admission is what refuses them.
RJ3=20261001-0000aad6; mk_root "$RJ3"; led_open "$RJ3"; end_row "$RJ3" 판단정지
mkdir -p "$W/claim-$RJ3"; printf '2026-10-03T00:00:00Z\n' > "$W/claim-$RJ3/at"
out=$(rk derive --predecessor "$PR/$RJ3.plan.md" --claim "$W/claim-$RJ3" --verdict 승인 \
        --approval "$RJ3#a1" --answer-digest "$ADIG")
J3=$(vcol "$out" 2); SJ3="$PR/$J3.plan.md"
check "판단정지 원인의 후속 매니페스트가 픽스처로 생겼다" "$(grep -c ' | 원인=판단정지 | 재인가 승인=' "$SJ3" 2>/dev/null || true)" "1"
claim_commit "$RJ3" 2026-10-03T00:00:00Z "$J3"
g "$RJ3" "gate_append '승인' '승인 id=a1' '상태=대기' '대상=-' '절단점=재인가' '종류=W' '재인가 원인=판단정지' '변경분=-'"
g "$RJ3" "gate_append '승인' '승인 id=a1' '상태=승인' '응답 토큰=t1' '답변 다이제스트=$ADIG'"
adm_is "(사) 사람이 닫은 재인가 승인이 있어도 원인 판단정지 는 거부한다" "$SJ3" "(사) 원인 판단정지 는 후속 런을 열지 않습니다"
with_edit "$SJ3" 's/ \| 재인가 승인=[^|]* \| 답변 다이제스트=[0-9a-f]{64}$//' \
  "(사) 재인가 승인이 없는 원인 판단정지 도 거부한다" "$SJ3" "(사) 원인 판단정지 는 후속 런을 열지 않습니다"

# The approval binds by its own rows: the kind, the cause and the run. The
# close row carries none of them, so the last value any row of it gave counts.
g "$RJ2" "gate_append '승인' '승인 id=a1' '상태=승인' '종류=V' '응답 토큰=t1' '답변 다이제스트=$ADIG'"
adm_is "(사) 종류 W 가 아닌 승인은 거부한다" "$SJ" "(사) 재인가 승인 $RJ2#a1 이 종류 W 가 아닙니다"
g "$RJ2" "gate_append '승인' '승인 id=a1' '상태=승인' '종류=W' '재인가 원인=슬라이싱' '응답 토큰=t1' '답변 다이제스트=$ADIG'"
adm_is "(사) 원인이 다른 재인가 승인은 거부한다" "$SJ" "(사) 재인가 승인의 원인 슬라이싱 이"
g "$RJ2" "gate_append '승인' '승인 id=a1' '상태=승인' '재인가 원인=대상미선언' '응답 토큰=t1' '답변 다이제스트=$ADIG'"
check "원인을 되돌린 승인이면 다시 지난다" "$(adm "$SJ")" "ok"
# adm_park <pred> <end token> [<progress>] — a park-cause successor of a link
# that ended on that token, with a person's W approval closed.
adm_park() {
  local p="$1" o
  mk_root "$p"; led_open "$p"; g "$p" "$PARK"
  [ -n "${3:-}" ] && progress "$p"
  end_row "$p" "$2"
  mkdir -p "$W/claim-$p"; printf '2026-10-03T00:00:00Z\n' > "$W/claim-$p/at"
  o=$(rk derive --predecessor "$PR/$p.plan.md" --claim "$W/claim-$p" --verdict 승인 \
        --approval "${4:-$p#a1}" --answer-digest "$ADIG")
  claim_commit "$p" 2026-10-03T00:00:00Z "$(vcol "$o" 2)"
  g "$p" "gate_append '승인' '승인 id=a1' '상태=대기' '대상=-' '절단점=재인가' '종류=W' '재인가 원인=대상미선언' '변경분=-'"
  g "$p" "gate_append '승인' '승인 id=a1' '상태=승인' '응답 토큰=t1' '답변 다이제스트=$ADIG'"
  printf '%s' "$PR/$(vcol "$o" 2).plan.md"
}
SP=$(adm_park 20261001-0000aa95 마감)
check "park 원인의 후속은 종료 토큰만의 판정이 자동이면 지난다" "$(adm "$SP")" "ok"
SP=$(adm_park 20261001-0000aa96 무진전)
adm_is "(사) park 원인이어도 정지 술어가 선 앞 런의 후속은 거부한다" "$SP" "(사) 진전 없이 끝난 고리"
SP=$(adm_park 20261001-0000aa97 말단상한)
adm_is "(사) park 원인이어도 종료 토큰만의 판정이 사람이면 거부한다" "$SP" "(사) 종료 토큰 말단상한 만의 판정이 사람"
SP=$(adm_park 20261001-0000aa98 마감 '' "$RJ2#a1")
adm_is "(사) 다른 런의 재인가 승인은 거부한다" "$SP" "(사) 재인가 승인 $RJ2#a1 은 선행 런"

# The memo: read by key, written only by the caller that prepared the run
# directory.
mkdir -p "$W/xdg"
MK=$(shasum -a 256 < "$SA" | cut -d' ' -f1)
check "기억 파일이 없으면 적중하지 않는다" \
  "$(XDG_STATE_HOME="$W/xdg" hx "rekick_memo_hit '$A1' '$MK' && echo hit || echo miss")" "miss"
mkdir -p "$W/xdg/cc-cmds/run/$A1"
XDG_STATE_HOME="$W/xdg" hx "rekick_memo_write '$A1' '$MK'"
check "쓴 키로는 적중한다" "$(XDG_STATE_HOME="$W/xdg" hx "rekick_memo_hit '$A1' '$MK' && echo hit")" "hit"
check "매니페스트가 바뀌어 키가 다르면 적중하지 않는다" \
  "$(XDG_STATE_HOME="$W/xdg" hx "rekick_memo_hit '$A1' 5555555555555555555555555555555555555555555555555555555555555555 && echo hit || echo miss")" "miss"
XDG_STATE_HOME="$W/xdg" hx "REKICK_MEMO_PENDING=''; RUN_ID='$A1'; rekick_memo_settle"
check "부탁받지 않은 정리는 기억 파일을 건드리지 않는다" "$(cat "$W/xdg/cc-cmds/run/$A1/lineage-admitted")" "$MK"

# Through `check_manifest` itself, from the origin repository: the gate's shell
# (the readers are here) and the driver's (they are asked in a child that
# sources the gate) give the same answer in the same words.
cm_gate() { XDG_STATE_HOME="$2" hx "cd '$REPO' && MANIFEST='$1' && check_manifest >/dev/null 2>&1 && printf 'pass:%s' \"\$REKICK_MEMO_PENDING\"" 2>&1; }
cm_gate_err() { XDG_STATE_HOME="$2" hx "cd '$REPO' && MANIFEST='$1' && check_manifest" 2>&1; }
cm_driver_err() {
  XDG_STATE_HOME="$2" "$BASH" -c 'cd "$1" && CC_ORCH_SOURCE_ONLY=1 . "$2" >/dev/null 2>&1; set +e; MANIFEST="$3"; check_manifest' \
    _ "$REPO" "$ORCH/run.sh" "$1" 2>&1
}
mkdir -p "$W/xdg2"
check "후속 매니페스트는 check_manifest 를 지나고 기억 파일 쓰기를 부탁한다" "$(cm_gate "$SA" "$W/xdg2")" "pass:$MK"
check "기억 파일이 맞는 키를 가지면 (사) 를 다시 계산하지 않는다" "$(cm_gate "$SA" "$W/xdg")" "pass:"
cp "$RUN_PACE_ROOT/rekick/$RA/at" "$W/at.keep"; printf '2026-10-03T00:00:01Z\n' > "$RUN_PACE_ROOT/rekick/$RA/at"
check "기억된 동안에는 (사) 가 읽는 클레임이 바뀌어도 다시 묻지 않는다" "$(cm_gate "$SA" "$W/xdg")" "pass:"
case "$(cm_gate_err "$SA" "$W/xdg2")" in
  *"lineage-invalid — (사) 클레임의 at"*) ok "기억이 없으면 (사) 를 계산해 lineage-invalid 로 거부한다" ;;
  *) bad "기억이 없으면 (사) 를 계산해 lineage-invalid 로 거부한다" "$(cm_gate_err "$SA" "$W/xdg2")" ;;
esac
cp "$W/at.keep" "$RUN_PACE_ROOT/rekick/$RA/at"
cp "$PR/$RA.plan.md" "$W/ra.plan.keep"
sed -E 's/^(- `종료 절` \| id=C1 \| 문면=).*/\1고쳐 쓴 절/' "$W/ra.plan.keep" > "$PR/$RA.plan.md"
case "$(cm_gate_err "$SA" "$W/xdg")" in
  *"lineage-invalid — (나)"*) ok "기억이 있어도 (가)~(바) 는 진입마다 돈다" ;;
  *) bad "기억이 있어도 (가)~(바) 는 진입마다 돈다" "$(cm_gate_err "$SA" "$W/xdg")" ;;
esac
case "$(cm_driver_err "$SA" "$W/xdg")" in
  *"lineage-invalid — (나)"*) ok "드라이버 셸도 자식 셸의 게이트 독자로 같은 문면을 낸다" ;;
  *) bad "드라이버 셸도 자식 셸의 게이트 독자로 같은 문면을 낸다" "$(cm_driver_err "$SA" "$W/xdg")" ;;
esac
cp "$W/ra.plan.keep" "$PR/$RA.plan.md"
case "$(cm_driver_err "$SA" "$W/xdg2")" in
  *"매니페스트 검사 통과"*) ok "드라이버 셸에서도 후속 매니페스트가 지난다" ;;
  *) bad "드라이버 셸에서도 후속 매니페스트가 지난다" "$(cm_driver_err "$SA" "$W/xdg2")" ;;
esac
check "연쇄 행이 없는 매니페스트는 기억 파일을 부탁하지 않는다" "$(cm_gate "$PR/$RA.plan.md" "$W/xdg2")" "pass:"

# ---------------------------------------------------------------------------
# 6c. The sweep: candidates from the run root, claims, records and outcomes.
# ---------------------------------------------------------------------------
# The run root the sweep reads is the real one under HOME; the ledgers keep
# their `RUN_DIR` under `$W/rd`, so the marker directory holds only the marker.
RRUN="$HOME/.local/state/cc-cmds/run"
BASE=$(cd "$REPO" && git rev-parse HEAD)
# mark <id> [<기록 시각>] — the end site's candidate marker.
mark() {
  mkdir -p "$RRUN/$1"
  printf '매니페스트=%s\n원장=%s\n런 id=%s\n토큰=마감\n기록 시각=%s\n' \
    "$PR/$1.plan.md" "$PR/$1.md" "$1" "${2:-2026-10-01T09:00:00Z}" > "$RRUN/$1/rekick-candidate"
}
# hush <id> — the run's last trace twenty minutes and more in the past.
hush() {
  local f
  touch -t 202610010900 "$PR/$1.md"
  for f in "$RRUN/$1"/* "$RRUN/$1"/digest/*; do [ -f "$f" ] && touch -t 202610010900 "$f"; done
  return 0
}
# ended <id> — a root with a segment carrying the base commit, ended on `마감`.
ended() {
  mk_root "$1"; led_open "$1"
  g "$1" "gate_append 'segment' 'id=A' '상태=완료' '레포=home' '베이스 sha=$BASE'"
  end_row "$1" 마감
}
sw() { rk sweep --pace-root "$RUN_PACE_ROOT" "$@" 2>/dev/null; }
outcome() { sed -n '1p' "$RUN_PACE_ROOT/rekick/$1/outcome" 2>/dev/null; }
records() { if [ -f "$RUN_PACE_ROOT/backlog.jsonl" ]; then grep -c . "$RUN_PACE_ROOT/backlog.jsonl"; else echo 0; fi; }
TAB=$(printf '\t')

SW1=20261001-0000aae1; ended "$SW1"; mark "$SW1"
out=$(sw --dry-run --lane present)
check "멈춘 지 얼마 안 된 런은 정지 대기다" "$out" "$SW1$TAB$PR/$SW1.plan.md$TAB$PR/$SW1.md${TAB}정지 대기"
hush "$SW1"
out=$(sw --dry-run --lane present)
check "dry-run 은 후보마다 선행 런·매니페스트·원장·판정을 찍는다" "$out" "$SW1$TAB$PR/$SW1.plan.md$TAB$PR/$SW1.md${TAB}자동"
check "dry-run 은 클레임도 레코드도 쓰지 않는다" "$([ -e "$RUN_PACE_ROOT/rekick/$SW1" ] && echo 있음 || echo 없음)/$(records)" "없음/0"

# The watcher fleet starts outlives the run and keeps rewriting its files, and
# so do the feed, the CI poller and the notifier: none of them is a gate entry.
SWQ=20261001-0000aaeb; ended "$SWQ"; mark "$SWQ"; hush "$SWQ"
for f in watch.heartbeat watch.pid watch.stall watch.state watch.log watch.announced-rekick \
         feed.heartbeat checks.observed checks.log notify.state stall; do
  : > "$RRUN/$SWQ/$f"
done
check "감시자·관찰자가 방금 쓴 파일은 정지 창을 다시 열지 않는다" \
  "$(sw --dry-run --lane present | grep -F "$SWQ$TAB" | cut -f4)" "자동"
mkdir -p "$RRUN/$SWQ/digest"; : > "$RRUN/$SWQ/digest/gate-digest-x.json"
check "게이트가 방금 남긴 흔적은 정지 창을 다시 연다" \
  "$(sw --dry-run --lane present | grep -F "$SWQ$TAB" | cut -f4)" "정지 대기"
rm -f "$RRUN/$SWQ/digest/gate-digest-x.json"; hush "$SWQ"; touch "$RRUN/$SWQ/rekick-candidate"
check "끝 자리 후보 표지도 게이트의 흔적이다" \
  "$(sw --dry-run --lane present | grep -F "$SWQ$TAB" | cut -f4)" "정지 대기"
rm -rf "$RRUN/$SWQ"

sw --lane present
oc=$(outcome "$SW1"); N1=${oc#*"$TAB"}
check "자동 판정의 후보는 열림으로 끝난다" "${oc%%"$TAB"*}" "열림"
check "후속 id 는 클레임 시각과 선행 런으로 정한다" "$N1" "$(rk id "$(cat "$RUN_PACE_ROOT/rekick/$SW1/at")" "$SW1" 1)"
check "클레임의 successor 는 그 후속이다" "$(cat "$RUN_PACE_ROOT/rekick/$SW1/successor")" "$N1"
rec=$(tail -1 "$RUN_PACE_ROOT/backlog.jsonl")
check "레코드의 정체 필드" \
  "$(printf '%s' "$rec" | jq -r '[.schema, .id, .manifest_path, .status, .authorized_at, .base_commit, .doc_sha256, .lane] | join("|")')" \
  "cc-pace-backlog v1|$N1|$PR/$N1.plan.md|pending|2026-10-01T00:00:00Z|$BASE|$DOC_SHA|"
check "레코드의 마감은 후속 매니페스트의 마감이다" "$(printf '%s' "$rec" | jq -r .deadline)" \
  "$(sed -n 's/^\*\*벽시계 마감\*\*: //p' "$PR/$N1.plan.md")"
# What the dispatcher's park check reads: the clocks in order, the deadline
# ahead, the base an ancestor of the origin's head.
e_auth=$(hx "dr_abs_epoch '$(printf '%s' "$rec" | jq -r .authorized_at)'")
e_enq=$(hx "dr_abs_epoch '$(printf '%s' "$rec" | jq -r .enqueued_at)'")
e_dl=$(hx "dr_abs_epoch '$(printf '%s' "$rec" | jq -r .deadline)'")
now=$(date -u +%s)
check "인가 ≤ 적재 ≤ 지금 < 마감" \
  "$([ "$e_auth" -le "$e_enq" ] && [ "$e_enq" -le "$now" ] && [ "$now" -lt "$e_dl" ] && echo 순서 || echo "$e_auth/$e_enq/$now/$e_dl")" "순서"
check "베이스 커밋은 원본의 HEAD 조상이다" \
  "$(cd "$REPO" && git merge-base --is-ancestor "$BASE" HEAD && echo 조상)" "조상"
sw --lane present
check "열림으로 끝난 후보는 다시 열지 않는다" "$(records)/$(outcome "$SW1")" "1/$oc"

# A claim whose successor is already written is not committed twice.
SW7=20261001-0000aae7; ended "$SW7"; mark "$SW7"; hush "$SW7"
mkdir -p "$RUN_PACE_ROOT/rekick/$SW7"
printf '2026-10-05T00:00:00Z\n' > "$RUN_PACE_ROOT/rekick/$SW7/at"
printf '20261005-00000000\n' > "$RUN_PACE_ROOT/rekick/$SW7/successor"
sw --lane present
check "successor 가 이미 있는 클레임은 레코드를 더하지 않는다" "$(records)/$(outcome "$SW7")" "1/"
rm -rf "$RRUN/$SW7"

# A person's kickoff on the same document wins over the chain.
SW2=20261001-0000aae2; ended "$SW2"; mark "$SW2"; hush "$SW2"
PK=20261005-0000aaf0
sed -E "s/run-id=$SW2;/run-id=$PK;/; s/^\*\*킥오프 일시\*\*: .*/**킥오프 일시**: 2026-10-05T00:00:00Z/" \
  "$PR/$SW2.plan.md" > "$PR/$PK.plan.md"
sw --lane present
check "사람이 같은 문서로 연 런이 있으면 후속을 만들지 않는다" \
  "$(outcome "$SW2" | cut -f1)/$(records)" "사람/1"
case "$(outcome "$SW2")" in *"$PK"*) ok "그 결과가 사람의 런을 이름 부른다" ;; *) bad "그 결과가 사람의 런을 이름 부른다" "$(outcome "$SW2")" ;; esac
rm -f "$PR/$PK.plan.md"

# A host with no lane is a person's.
SW4=20261001-0000aae4; ended "$SW4"; mark "$SW4"; hush "$SW4"
sw
check "레인이 없는 호스트의 후보는 사람이다" "$(outcome "$SW4" | cut -f1)/$(records)" "사람/1"

# A manifest with no consent row is no candidate: no outcome at all.
SW6=20261001-0000aae6; ended "$SW6"
sed '/^- `재킥오프` /d' "$PR/$SW6.plan.md" > "$W/sw6" && mv "$W/sw6" "$PR/$SW6.plan.md"
mark "$SW6"; hush "$SW6"
sw --lane present
check "재킥오프 행이 없는 매니페스트는 거르고 아무것도 남기지 않는다" \
  "$([ -e "$RUN_PACE_ROOT/rekick/$SW6" ] && echo 있음 || echo 없음)" "없음"
rm -rf "$RRUN/$SW6"

# An approval cause: one re-authorization approval raised, then a successor
# once a person closed it.
SW3=20261001-0000aae3; mk_root "$SW3"; led_open "$SW3"
g "$SW3" "gate_append 'segment' 'id=A' '상태=완료' '레포=home' '베이스 sha=$BASE'"
g "$SW3" "gate_append 'blocked' '대상=other' '스코프=act' '원인=막힘' '사유=대상 미선언' '재킥 원인=대상미선언'"
end_row "$SW3" 마감; mark "$SW3"; hush "$SW3"
( cd "$REPO" && rk sweep --pace-root "$RUN_PACE_ROOT" --lane present 2>"$W/sw3.err" )
oc=$(outcome "$SW3")
check "승인 판정의 후보는 재인가 승인을 올리고 기다린다" "${oc%%"$TAB"*}" "승인 대기"
[ "${oc%%"$TAB"*}" = "승인 대기" ] || sed 's/^/  sw3: /' "$W/sw3.err" >&2
AID=${oc#*"$TAB"}; AID=${AID#*#}
check "올린 승인은 종류 W 대기 행 하나다" \
  "$(grep "^- \`승인\` | " "$PR/$SW3.md" | grep -F " 승인 id=$AID " | grep -F ' 상태=대기 ' | grep -cF ' 종류=W ')" "1" \
  || grep '^- `승인`' "$PR/$SW3.md" | sed "s/^/  sw3 ($AID): /" >&2
hush "$SW3"
( cd "$REPO" && rk sweep --pace-root "$RUN_PACE_ROOT" --lane present 2>/dev/null )
check "다시 훑어도 승인 행이 늘지 않는다" \
  "$(grep "^- \`승인\` | " "$PR/$SW3.md" | grep -cF " 승인 id=$AID ")/$(outcome "$SW3" | cut -f1)" "1/승인 대기"
g "$SW3" "gate_append '승인' '승인 id=$AID' '상태=승인' '응답 토큰=t1' '답변 다이제스트=$ADIG'"
hush "$SW3"
( cd "$REPO" && rk sweep --pace-root "$RUN_PACE_ROOT" --lane present 2>/dev/null )
oc=$(outcome "$SW3"); N3=${oc#*"$TAB"}
check "사람이 닫은 재인가 승인 뒤에는 후속을 연다" "${oc%%"$TAB"*}/$(records)" "열림/2"
check "그 후속의 연쇄 행이 승인과 답변 다이제스트를 싣는다" \
  "$(grep -c " | 재인가 승인=$SW3#$AID | 답변 다이제스트=$ADIG\$" "$PR/$N3.plan.md")" "1"

# A stop predicate is a person's: no re-authorization approval is raised.
SN=20261001-0000aa9a; mk_root "$SN"; led_open "$SN"; end_row "$SN" 무진전; mark "$SN"; hush "$SN"
( cd "$REPO" && rk sweep --pace-root "$RUN_PACE_ROOT" --lane present 2>/dev/null )
check "정지 술어가 선 고리는 사람이고 재인가 승인을 올리지 않는다" \
  "$(outcome "$SN" | cut -f1)/$(grep -c '^- `승인` | ' "$PR/$SN.md" || true)" "사람/0"

# Only reaching the chain cap is `상한`: the sweep raises a W carrying the next
# cap, and a person's close opens a successor with that cap.
SC=20261001-0000aa9b; mk_root "$SC" 1; led_open "$SC"; end_row "$SC" 마감
mkdir -p "$W/claim-$SC"; printf '2026-10-03T00:00:00Z\n' > "$W/claim-$SC/at"
SC1=$(vcol "$(rk derive --predecessor "$PR/$SC.plan.md" --claim "$W/claim-$SC" --verdict 자동)" 2)
claim_commit "$SC" 2026-10-03T00:00:00Z "$SC1"
led_open "$SC1"
g "$SC1" "gate_append 'segment' 'id=A' '상태=완료' '레포=home' '베이스 sha=$BASE'"
end_row "$SC1" 마감; mark "$SC1"; hush "$SC1"
( cd "$REPO" && rk sweep --pace-root "$RUN_PACE_ROOT" --lane present 2>/dev/null )
oc=$(outcome "$SC1")
check "연쇄 상한에만 닿은 고리는 재인가 승인을 올리고 기다린다" "${oc%%"$TAB"*}" "승인 대기"
CAID=${oc#*"$TAB"}; CAID=${CAID#*#}
check "그 승인은 상한 원인과 새 연쇄 상한 2 를 싣는다" \
  "$(grep "^- \`승인\` | " "$PR/$SC1.md" | grep -F " 승인 id=$CAID " | grep -cF ' | 재인가 원인=상한 | 변경분=새 연쇄 상한 2 | ')" "1"
g "$SC1" "gate_append '승인' '승인 id=$CAID' '상태=승인' '응답 토큰=t1' '답변 다이제스트=$ADIG'"
hush "$SC1"
( cd "$REPO" && rk sweep --pace-root "$RUN_PACE_ROOT" --lane present 2>"$W/sc1.err" )
oc=$(outcome "$SC1"); NC=${oc#*"$TAB"}; SNC="$PR/$NC.plan.md"
check "사람이 닫은 상한 승인 뒤에는 후속을 연다" "${oc%%"$TAB"*}" "열림"
[ "${oc%%"$TAB"*}" = "열림" ] || sed 's/^/  sc1: /' "$W/sc1.err" >&2
check "그 후속은 동의 행의 연쇄 상한만 새 상한으로 바꾼다" \
  "$(grep -c '^- `재킥오프` | 연쇄 상한=2 | ' "$SNC" 2>/dev/null || true)/$(grep -c " | 순번=2 | .* | 원인=마감 | 재인가 승인=$SC1#$CAID | " "$SNC" 2>/dev/null || true)" "1/1"
check "새 상한을 담은 후속은 입장 검사를 지난다" "$(adm "$SNC")" "ok"
with_edit "$SNC" 's/^(- `재킥오프` \| 연쇄 상한=)2 /\11 /' \
  "상한을 바꾸지 않은 후속은 거부한다" "$SNC" "(라)"
with_edit "$SNC" 's/^(- `재킥오프` \| 연쇄 상한=)2 /\13 /' \
  "(사) 승인과 다른 상한을 단 후속은 거부한다" "$SNC" "(사) 상한 재인가 승인의 변경분"
g "$SC1" "gate_append '승인' '승인 id=$CAID' '상태=승인' '재인가 원인=대상미선언' '응답 토큰=t1' '답변 다이제스트=$ADIG'"
adm_is "(사) 상한이 아닌 원인의 승인으로 상한을 바꾼 후속은 거부한다" "$SNC" "(사) 연쇄 상한 2 이 앞 런의 1 과 다른데"
g "$SC1" "gate_append '승인' '승인 id=$CAID' '상태=승인' '재인가 원인=상한' '응답 토큰=t1' '답변 다이제스트=$ADIG'"
check "원인을 되돌리면 다시 지난다" "$(adm "$SNC")" "ok"

# The commit wait: one length after the run ended, it is a person's.
CW="$W/cw"; mkdir -p "$CW"
printf '기록 시각=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$CW/rekick-candidate"
hx "REKICK_PACE='$W/pace-cw'; rekick_sweep_commit_wait p1 '$PR/$SW1.plan.md' '$CW' '$PR/$SW1.md' '커밋 대기 — 설정'" 2>/dev/null
check "길이 안의 커밋 대기는 커밋 대기로 남는다" "$(sed -n 1p "$W/pace-cw/rekick/p1/outcome")" "커밋 대기${TAB}설정"
printf '기록 시각=2026-10-01T00:00:00Z\n' > "$CW/rekick-candidate"
hx "REKICK_PACE='$W/pace-cw'; rekick_sweep_commit_wait p1 '$PR/$SW1.plan.md' '$CW' '$PR/$SW1.md' '커밋 대기 — 설정'" 2>/dev/null
check "길이 하나가 지난 커밋 대기는 사람이다" "$(sed -n 1p "$W/pace-cw/rekick/p1/outcome" | cut -f1)" "사람"

# A deferred root the dispatcher parked for its deadline before it ever
# started: no ledger and no run directory, a kickoff trace ending on `연기`,
# and the backlog record carrying what the ledger would have. With no link
# that ran, the document digest comes from the root manifest's own field, so
# this root's document existed at kickoff.
SW8=20261001-0000aae8; mk_root "$SW8" 3 없음 연기 PR "$DOC_SHA"
jq -cn --arg id "$SW8" --arg mp "$PR/$SW8.plan.md" --arg base "$BASE" --arg doc "$DOC_SHA" \
  '{schema: "cc-pace-backlog v1", id: $id, manifest_path: $mp, status: "parked", park_reason: "deadline-passed",
    authorized_at: "2026-10-01T00:00:30Z", enqueued_at: "2026-10-01T00:01:00Z", deadline: "2026-10-02T09:00:00+09:00",
    base_commit: $base, doc_sha256: $doc, lane: "l1"}' >> "$RUN_PACE_ROOT/backlog.jsonl"
n8=$(records)
check "dry-run 은 기동 전 마감 park 뿌리도 후보로 찍는다" \
  "$(sw --dry-run --lane present | grep -F "$SW8$TAB" | cut -f1,3)" "$SW8$TAB-"
sw --lane present 2>"$W/sw8.err"
oc=$(outcome "$SW8"); N8=${oc#*"$TAB"}
check "기동 전 마감으로 park 된 연기 뿌리는 후속을 연다" "${oc%%"$TAB"*}" "열림"
[ "${oc%%"$TAB"*}" = "열림" ] || sed 's/^/  sw8: /' "$W/sw8.err" >&2
check "그 후속 레코드는 하나이고 앞 레코드의 인가 시각·베이스·문서 해시·레인을 옮긴다" \
  "$(($(records) - n8))/$(tail -1 "$RUN_PACE_ROOT/backlog.jsonl" | jq -r '[.id, .authorized_at, .base_commit, .doc_sha256, .lane] | join("|")')" \
  "1/$N8|2026-10-01T00:00:30Z|$BASE|$DOC_SHA|l1"
check "그 후속 매니페스트는 연쇄의 뿌리를 그 연기 런으로 적는다" \
  "$(grep -c " | 뿌리 런=$SW8 | " "$PR/$N8.plan.md" 2>/dev/null || true)" "1"
check "park 된 연기 레코드는 그대로 park 로 남는다" \
  "$(jq -R -r --arg id "$SW8" 'fromjson? | select(.id == $id) | .status' "$RUN_PACE_ROOT/backlog.jsonl" | tail -1)" "parked"

# ---------------------------------------------------------------------------
# 6d. Self-hosting: a run that may merge into the plugin's own repository keeps
#     the plugin it started on, and renders its settings afresh.
# ---------------------------------------------------------------------------
# The predecessor's copy comes from a checkout of this plugin whose origin is
# the plugin repository, so the slug is read the way it is on a real host. The
# copy is the real plugin, because the successor's first gate entry hops into
# the copy it is pinned to.
PLUG="$W/plug"
mkdir -p "$PLUG/plugins"
cp -R "$repo_root/plugins/cc-cmds" "$PLUG/plugins/cc-cmds"
( cd "$PLUG" && git init -q -b master . && git remote add origin git@github.com:Nharu/cc-cmds.git \
    && git add -A && git -c user.name=t -c user.email=t@invalid -c commit.gpgsign=false commit -q -m plug ) \
  || bad "플러그인 원본 체크아웃을 만들지 못했다"
# si_commit <path> — a commit on top of the base touching that path, left off
# every branch so the origin repository's HEAD does not move.
si_commit() {
  ( cd "$REPO" || exit 1
    GIT_INDEX_FILE="$W/si.idx"; export GIT_INDEX_FILE
    b=$(printf '%s\n' "$1" | git hash-object -w --stdin) || exit 1
    git read-tree "$BASE" && git update-index --add --cacheinfo "100644,$b,$1" || exit 1
    git -c user.name=t -c user.email=t@invalid commit-tree "$(git write-tree)" -p "$BASE" -m "$1" )
}
SI_TOUCH=$(si_commit plugins/cc-cmds/x)
SI_OTHER=$(si_commit docs/y)
# si_root <id> <merge commit> [<절단점>] — a root that merged that commit, with
# a plugin pin taken from the checkout, ended on `마감` and quiet.
si_root() {
  mk_root "$1" 3 없음 '기동 직전' "${3:-머지}"; led_open "$1"
  g "$1" "gate_append 'segment' 'id=A' '상태=머지됨' '레포=Nharu/cc-cmds' '머지 커밋=$2' '베이스 sha=$BASE'"
  end_row "$1" 마감
  hx "pin_take '$RRUN/$1' '$PLUG/plugins/cc-cmds'" >/dev/null 2>&1
  mark "$1"; hush "$1"; touch -t 202610010900 "$RRUN/$1/plugin"
}
pin_of() { awk -v k="$2" -F'\t' '$1 == k { print $2; exit }' "$RRUN/$1/plugin-pin" 2>/dev/null; }

SI1=20261001-0000aab1; si_root "$SI1" "$SI_TOUCH"
check "앞 런의 핀은 원본 체크아웃에서 왔다" "$(pin_of "$SI1" source)" "$PLUG/plugins/cc-cmds"
check "플러그인 레포 슬러그는 핀 원본의 origin 에서 읽는다" "$(hx "rekick_plugin_slug '$RRUN/$SI1'")" "Nharu/cc-cmds"
check "플러그인을 건드린 머지가 있는 머지 절단점 런의 핀은 쓸 수 있다" \
  "$(hx "rekick_pin_state '$PR/$SI1.plan.md'")" "usable$TAB$RRUN/$SI1/plugin/cc-cmds"
sw --lane present
oc=$(outcome "$SI1"); NS1=${oc#*"$TAB"}
check "핀을 물려받는 후보도 열림으로 끝난다" "${oc%%"$TAB"*}" "열림"
check "후속 런의 핀은 앞 런의 사본을 원본으로 한다" "$(pin_of "$NS1" source)" "$RRUN/$SI1/plugin/cc-cmds"
check "후속 런의 플러그인 사본은 앞 런 것과 바이트가 같다" "$(pin_of "$NS1" digest)" "$(pin_of "$SI1" digest)"
check "후속 런의 핀은 자기 런 디렉터리의 사본을 가리킨다" "$(pin_of "$NS1" plugin-dir)" "$RRUN/$NS1/plugin/cc-cmds"
check "물려받은 핀에서도 슬러그는 원본 체크아웃까지 따라간다" "$(hx "rekick_plugin_slug '$RRUN/$NS1'")" "Nharu/cc-cmds"

# What does not fire: a merge that left the plugin alone, a run that may not
# merge, and a target that is not the plugin repository.
SI2=20261001-0000aab2; si_root "$SI2" "$SI_OTHER"
check "플러그인을 건드리지 않은 머지면 핀을 물려주지 않는다" "$(hx "rekick_pin_state '$PR/$SI2.plan.md'" | cut -f1)" "none"
SI3=20261001-0000aab3; si_root "$SI3" "$SI_TOUCH" PR
check "PR 절단점 런은 핀을 물려주지 않는다" "$(hx "rekick_pin_state '$PR/$SI3.plan.md'" | cut -f1)" "none"
sw --lane present
check "핀을 물려주지 않는 후속은 핀 없이 열린다" \
  "$(outcome "$SI2" | cut -f1)/$([ -f "$RRUN/$(outcome "$SI2" | cut -f2)/plugin-pin" ] && echo 핀 || echo 없음)" "열림/없음"
SI4=20261001-0000aab4; si_root "$SI4" "$SI_TOUCH"
( cd "$PLUG" && git remote set-url origin git@github.com:someone/else.git )
check "대상이 플러그인 원본 레포가 아니면 핀을 물려주지 않는다" "$(hx "rekick_pin_state '$PR/$SI4.plan.md'" | cut -f1)" "none"
( cd "$PLUG" && git remote remove origin )
check "원본 체크아웃의 origin 을 읽지 못하면 쓸 수 없다" "$(hx "rekick_pin_state '$PR/$SI4.plan.md'" | cut -f1)" "unusable"
( cd "$PLUG" && git remote add origin git@github.com:Nharu/cc-cmds.git )
mv "$RRUN/$SI4/plugin" "$W/si4.plugin"
check "앞 런의 사본이 없으면 쓸 수 없다" "$(hx "rekick_pin_state '$PR/$SI4.plan.md'" | cut -f1)" "unusable"
mv "$W/si4.plugin" "$RRUN/$SI4/plugin"
rm -rf "${RRUN:?}/$SI4"

# The successor's settings: the predecessor's settings directory is tampered
# with, the successor is started the way the dispatcher starts it, and what it
# renders is compared with the tampered bytes and with a render of its own
# manifest from its own pinned copy.
mkdir -p "$RRUN/$SI1/settings"
printf '{"permissions":{"allow":["Bash(*)"]},"tampered":"앞 런"}\n' > "$RRUN/$SI1/settings/implement.json"
cp "$RRUN/$SI1/settings/implement.json" "$RRUN/$SI1/settings/generic.json"
printf '#!/bin/sh\nexit 0\n' > "$W/claude-noop"; chmod +x "$W/claude-noop"
# The two calls the dispatcher launches a run with, in its order: the gate's
# snapshot opens the run (the settings are rendered there), then the driver.
r16_launch() {
  ( cd "$REPO" || exit 1
    for v in CC_PIPELINE_RUN_ID CC_ORCH_SOURCE_ONLY CC_GATE_SOURCE_ONLY CC_REKICK_SOURCE_ONLY; do unset "$v"; done
    CC_CLAUDE_BIN="$W/claude-noop"; export CC_CLAUDE_BIN
    CLAUDE_CONFIG_DIR="$HOME/.claude" "$BASH" "$GATE_SH" snapshot --manifest "$PR/$NS1.plan.md" >/dev/null
    printf 'r16: snapshot rc=%s\n' "$?"
    CLAUDE_CONFIG_DIR="$HOME/.claude" "$BASH" "$ORCH/run.sh" --manifest "$PR/$NS1.plan.md" ) > "$W/r16.out" 2>&1 &
  local p=$! n=0
  while kill -0 "$p" 2>/dev/null && [ "$n" -lt 120 ]; do sleep 1; n=$((n + 1)); done
  kill -0 "$p" 2>/dev/null && { kill -TERM "$p" 2>/dev/null; printf 'r16: run.sh 가 120 초 안에 돌아오지 않아 끊었다\n' >> "$W/r16.out"; }
  wait "$p" 2>/dev/null
  printf 'r16: run.sh rc=%s\n' "$?" >> "$W/r16.out"
  return 0
}
# The driver resolves each target's base branch on its origin, so the origin
# repository gets a remote of its own for this launch only.
git init -q --bare "$W/origin.git"
( cd "$REPO" && git remote add origin "$W/origin.git" && git push -q origin master && git fetch -q origin ) \
  || bad "픽스처 원격을 붙이지 못했다"
r16_launch
( cd "$REPO" && git remote remove origin )
if [ -d "$RRUN/$NS1/settings" ]; then
  ok "후속 런을 기동하면 자기 설정 디렉터리를 렌더한다"
else
  bad "후속 런을 기동하면 자기 설정 디렉터리를 렌더한다" "settings 없음"
  sed 's/^/  r16: /' "$W/r16.out" | tail -60 >&2
fi
check "후속 런의 설정에 앞 런의 변조가 없다" \
  "$(grep -rlF '"tampered"' "$RRUN/$NS1/settings" 2>/dev/null | grep -c . || true)" "0"
check "후속 런의 설정은 앞 런의 바뀐 설정과 바이트가 다르다" \
  "$(diff -r -q "$RRUN/$SI1/settings" "$RRUN/$NS1/settings" >/dev/null 2>&1 && echo 같음 || echo 다름)" "다름"
# The expected render runs in the successor's own pinned copy, under the same
# configuration directory the launch used, into a directory beside the run.
CLAUDE_CONFIG_DIR="$HOME/.claude" "$BASH" "$W/hx.sh" "$RRUN/$NS1/plugin/cc-cmds/orchestrator/gate.sh" \
  "cd '$REPO' && MANIFEST='$PR/$NS1.plan.md' && manifest_snapshot_take && check_manifest >/dev/null 2>&1 \
   && derive_paths_from_manifest && RUN_DIR='$RRUN/$NS1' \
   && CC_GATE_SETTINGS_OVERRIDE='$W/r16-expect' && export CC_GATE_SETTINGS_OVERRIDE \
   && gate_write_settings" > "$W/r16-expect.out" 2>&1
if diff -r "$W/r16-expect" "$RRUN/$NS1/settings" > "$W/r16.diff" 2>&1; then
  ok "후속 런의 설정은 자기 매니페스트와 고정 사본으로 렌더한 기대값과 같다"
else
  bad "후속 런의 설정은 자기 매니페스트와 고정 사본으로 렌더한 기대값과 같다" "diff 가 있다"
  sed 's/^/  r16 diff: /' "$W/r16.diff" "$W/r16-expect.out" | head -30 >&2
fi

# ---------------------------------------------------------------------------
# 6e. End to end: runs the real dispatcher starts, that end, and the successors
#     they open — the driver, the gate, the dispatcher and the sweep all real,
#     with `claude` and `gh` as stubs.
# ---------------------------------------------------------------------------
# The driver refuses to start off macOS, so there is no run to end there.
if [ "$(uname -s)" != Darwin ]; then
  printf 'SKIP: 6e — 드라이버가 macOS 밖에서는 기동하지 않는다\n'
else
X="$W/e2e"; mkdir -p "$X/bin" "$X/gh"
XHOME="$X/home"; XLANE="$XHOME/.claude-l1"; mkdir -p "$XLANE/projects"
XRUN="$XHOME/.local/state/cc-cmds/run"; XPACE="$X/pace"; mkdir -p "$XPACE"
XREPO="$X/repo"; XPR="$XREPO/docs/pipeline-run"; XPG="$XREPO/docs/pipeline-grant"
XLOG="$X/claude.log"; : > "$XLOG"; : > "$X/gh/prs"

# The stage CLI. A stage's whole effect is what it leaves in git, the report
# file and the ledger, so the stub leaves exactly that: the implementation
# commits the slice's one declared file, pushes the branch and opens the PR;
# the review writes its summary line; a judgment call answers with no finding.
# `R12_MODE` makes the implementation of slice A do one thing more, the way a
# real stage's next tool call would meet it.
cat > "$X/bin/claude" <<'STUB'
#!/usr/bin/env bash
sid=""; prompt=""; schema=0
while [ $# -gt 0 ]; do
  case "$1" in
    --session-id|--resume) sid="$2"; shift 2 ;;
    -p) prompt="$2"; shift 2 ;;
    --json-schema) schema=1; shift 2 ;;
    *) shift ;;
  esac
done
first=${prompt%%$'\n'*}
printf '%s\t%s\t%s\n' "${CC_PIPELINE_RUN_ID:--}" "${CC_PIPELINE_STAGE_ID:--}" "$first" >> "$R12_LOG"
if [ "$schema" = 1 ]; then
  printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"num_turns":1,"structured_output":{"findings":[],"p0_count":0,"p1_count":0,"stop_predicate_met":true}}'
  exit 0
fi
[ -n "$sid" ] || sid=$(uuidgen | tr 'A-Z' 'a-z')
printf '{"type":"system","subtype":"init","session_id":"%s","model":"stub"}\n' "$sid"
case "$first" in
  /cc-cmds:implement-unattended*)
    br=$(git rev-parse --abbrev-ref HEAD); seg=${br##*-}
    if [ "$R12_MODE" != hollow ]; then
      f=$(printf '%s' "$seg" | tr 'A-Z' 'a-z').txt
      printf '%s\n' "$br" > "$f"
      git add "$f" && git -c user.name=t -c user.email=t@invalid -c commit.gpgsign=false commit -q -m "slice $seg"
      git push -q origin "HEAD:refs/heads/$br" 2>/dev/null
      n=$(( $(grep -c . "$R12_GH/prs") + 1 ))
      printf '%s\t%s\t%s\tOPEN\n' "$n" "$br" "$(git rev-parse HEAD)" >> "$R12_GH/prs"
    fi
    if [ "$seg" = A ]; then
      moved=""
      case "$R12_MODE" in
        commit)
          ( cd "$R12_REPO" && printf '{"moved":"commit"}\n' > .claude/settings.json \
            && git add .claude/settings.json \
            && git -c user.name=t -c user.email=t@invalid -c commit.gpgsign=false commit -q -m "settings" \
            && git push -q origin master 2>/dev/null ); moved=1 ;;
        runset) printf ' ' >> "$CC_PIPELINE_RUN_DIR/settings/implement.json"; moved=1 ;;
        dirty) printf '{"moved":"dirty"}\n' > "$R12_REPO/.claude/settings.json"; moved=1 ;;
      esac
      if [ -n "$moved" ]; then
        h=$(bash "$R12_GATE" snapshot --manifest "$CC_PIPELINE_MANIFEST" --fields H 2>/dev/null)
        bash "$R12_GATE" exec --manifest "$CC_PIPELINE_MANIFEST" --target "$CC_PIPELINE_TARGET" \
          --segment "$CC_PIPELINE_SEGMENT" --cutpoint 커밋 --surface 읽기 --snapshot-digest "$h" \
          --rationale 'stub' -- true >/dev/null 2>&1
        printf '%s\tgate-exec-rc=%s\n' "${CC_PIPELINE_RUN_ID:--}" "$?" >> "$R12_LOG"
      fi
    fi ;;
  /cc-cmds:review-unattended*)
    rp=$(printf '%s' "$first" | sed -n 's/.*--report-path \([^ ]*\).*/\1/p')
    case "$first" in
      *-A\ *) [ -z "${R12_REVIEW_UNTIL:-}" ] || while [ "$(date -u +%s)" -lt "$R12_REVIEW_UNTIL" ]; do sleep 1; done ;;
    esac
    mkdir -p "$(dirname "$rp")"
    printf '# 리뷰\n\n- **발견 요약**: 🔴 P0 0건 | 🟠 P1 0건 | 🟡 P2 0건 | 🟢 P3 0건\n' > "$rp" ;;
esac
printf '{"type":"result","subtype":"success","is_error":false,"num_turns":1,"session_id":"%s","result":"ok"}\n' "$sid"
exit 0
STUB
# `gh`: PRs live in one table; every read answers through real jq so a `--jq`
# the caller passes is applied to the same JSON the real CLI would print.
cat > "$X/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$R12_GH/log"
[ "${1:-}" = -R ] && shift 2
db="$R12_GH/prs"
obj() { awk -F'\t' '{printf "{\"number\":%s,\"headRefName\":\"%s\",\"headRefOid\":\"%s\",\"state\":\"%s\",\"mergeCommit\":null,\"baseRefName\":\"master\",\"url\":\"https://example.invalid/pr/%s\"}\n", $1,$2,$3,$4,$1}'; }
out() { if [ -n "$jqf" ]; then jq -r "$jqf"; else cat; fi; }
case "${1:-} ${2:-}" in
  "pr list")
    shift 2; head=""; jqf=""
    while [ $# -gt 0 ]; do case "$1" in --head) head="$2"; shift 2 ;; --jq|-q) jqf="$2"; shift 2 ;; *) shift ;; esac; done
    awk -F'\t' -v b="$head" '$2 == b' "$db" | tail -1 | obj | jq -s . | out ;;
  "pr view")
    key="$3"; shift 3; jqf=""
    while [ $# -gt 0 ]; do case "$1" in --jq|-q) jqf="$2"; shift 2 ;; *) shift ;; esac; done
    row=$(awk -F'\t' -v k="$key" '$1 == k || $2 == k' "$db" | tail -1)
    [ -n "$row" ] || { echo "no pull requests found" >&2; exit 1; }
    printf '%s\n' "$row" | obj | out ;;
esac
exit 0
STUB
printf '#!/usr/bin/env bash\nexit 0\n' > "$X/bin/lane-probe.sh"
chmod +x "$X/bin"/*

# The target: a repository with a committed project settings file, and its
# origin. `docs/` is the run's own and stays untracked, as on a real host.
git init -q --bare "$X/origin.git"
mkdir -p "$XREPO/.claude" "$XPR" "$XPG" "$XREPO/docs/design-audit"
( cd "$XREPO" && git init -q -b master . && printf '{}\n' > .claude/settings.json && printf 'r\n' > README \
    && git add .claude/settings.json README \
    && git -c user.name=t -c user.email=t@invalid -c commit.gpgsign=false commit -q -m base \
    && git remote add origin "$X/origin.git" && git push -q origin master && git fetch -q origin ) \
  || bad "6e: 픽스처 대상 레포를 만들지 못했다"

# One lane, its inventory and a fresh usage reading.
mkdir -p "$XHOME/.config/cc-lane"
jq -n --arg d "$XLANE" '{schema: "cc-lane-accounts v1",
  accounts: [{id: "l1", config_dir: $d, unattended: "enabled", interactive_reserved: false}]}' \
  > "$XHOME/.config/cc-lane/accounts.json"
x_usage() {
  local now; now=$(date -u +%s)
  mkdir -p "$XHOME/.local/state/cc-lane"
  jq -n --argjson now "$now" --arg d "$XLANE" '
    def win($u; $r): {utilization: $u, resets_at_epoch: ($now + $r), observed_at_epoch: ($now - 10), source: "tracker"};
    {schema: "cc-lane-usage v1", written_at_epoch: ($now - 10), publish_interval_s: 60,
     accounts: [{id: "l1", config_dir: $d, org_hash: "org-l1", login: "ok", status: "ok",
                 windows: {five_hour: win(0.10; 7200), seven_day: win(0.50; 86400)}}]}' \
    > "$XHOME/.local/state/cc-lane/usage.json"
}
x_iso() { date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ; }

# x_doc <name> <slices> — a frozen design document declaring those slices,
# each with one declared file and no predecessor, and its audit reader report.
x_doc() {
  local f="$XREPO/docs/r12-$1.md" s
  {
    printf '# R12 픽스처 — %s\n\n**상태**: 동결됨\n\n## 구현 슬라이싱\n\n**슬라이스 수**: %s\n' "$1" "${#2}"
    for s in $(printf '%s' "$2" | sed 's/./& /g'); do
      printf '\n### 슬라이스 %s\n\n**스킬**: implement\n**레포**: `Nharu/cc-cmds`\n**선언 파일**: `%s.txt`\n**선행**: 없음\n**절단점**: PR\n' \
        "$s" "$(printf '%s' "$s" | tr 'A-Z' 'a-z')"
    done
  } > "$f"
  : > "$XREPO/docs/design-audit/docs-r12-$1.reader-1.md"
}

# x_root <id> <name> <deadline epoch> [<길이>] — a root run of that document as
# kickoff leaves it: manifest, authorization, kickoff trace and the pending
# backlog record the dispatcher takes.
x_root() {
  local id="$1" doc="docs/r12-$2.md" dl now m dsha kick auth td bd
  now=$(date -u +%s); kick=$(x_iso $((now - 60))); auth=$(x_iso $((now - 30)))
  dl=$(date -r "$3" +%Y-%m-%dT%H:%M:%S+09:00)
  dsha=$(shasum -a 256 "$XREPO/$doc" | cut -d' ' -f1)
  m="$XPR/$id.plan.md"
  cat > "$m" <<EOF
# 파이프라인 런 매니페스트 — $id
<!-- cc-run-manifest v1; writer=autopilot; reader=orchestrator; run-id=$id; anchor-kind=doc; anchor-key=$doc; owner-doc=$doc; origin-worktree=$XREPO; NOT a design doc; mechanism-local, never staged by a skill -->

## 런 정체
**킥오프 일시**: $kick
**런 id**: $id
**앵커 종류**: doc
**앵커 키**: $doc
**사용자 확인 문면**: 승인 / 이대로

## 의도
\`\`\`text
픽스처 의도
\`\`\`

## 대상
**대상 맵 다이제스트**: 0000000000000000000000000000000000000000000000000000000000000000
- \`target\` | 별칭=home | 메인 워크트리=$XREPO | 공통 git 디렉터리=$XREPO/.git | 베이스 브랜치=master | 홈=예 | 원격 슬러그=Nharu/cc-cmds | 절단점=PR | 말단 행위 상한=없음

## 요소
**설계 문서**: $doc
**설계 문서 전체 sha256**: $dsha
**리뷰 대상**: (없음)
**적용 지점**: (없음)
**적용 프로브**: (없음)
**적용 주체**: (해당 없음)

## 실행 계획
**승인 문면**: 이 계획으로 승인
\`\`\`json
{
  "anchor_kind": "doc",
  "anchor_key": "$doc",
  "entry_skill": "implement",
  "entry_rationale": "픽스처",
  "design_required": false,
  "design_rationale": "픽스처",
  "design_tier": "solo",
  "design_tier_rationale": "픽스처",
  "design_scope": "single",
  "design_scope_rationale": "픽스처",
  "work_class": "feat",
  "work_class_rationale": "픽스처",
  "targets": [{"alias": "home", "remote_slug": "Nharu/cc-cmds", "home": true, "why": "픽스처"}],
  "steps": [{"id": "I1", "skill": "implement", "summary": "구현", "depends_on": []}],
  "unresolved": [],
  "notes": ""
}
\`\`\`

## 인가
**구속 다이제스트**: @@B@@
**런 최대 절단점**: PR
**종료 지점**: 픽스처 종료 지점
- \`종료 절\` | id=C1 | 문면=픽스처 절
**벽시계 마감**: $dl
**비용 천장**: 없음
**무진전 상한**: 없음
**시각 정합 마커**: 없음
**사다리 가용 단 수**: 4
**미선언 상황 처분**: park
- \`사전 인가\` | 형태=git push | 사유=세그먼트 브랜치를 올린다
- \`사전 인가\` | 형태=gh pr | 사유=PR 을 연다
- \`재킥오프\` | 연쇄 상한=3 | 길이=${4:-PT8H} | 사유=픽스처 동의
EOF
  td=$(hx "MANIFEST='$m'; canonical_targets | shasum -a 256 | cut -d' ' -f1")
  sed "s/^\*\*대상 맵 다이제스트\*\*: .*/**대상 맵 다이제스트**: $td/" "$m" > "$m.t" && mv "$m.t" "$m"
  bd=$(hx "rekick_binding_digest '$m'")
  sed "s/@@B@@/$bd/" "$m" > "$m.t" && mv "$m.t" "$m"
  cat > "$XPG/$id.md" <<EOF
# 파이프라인 인가 기록 — $id
<!-- cc-pipeline-grant v1; writer=autopilot; reader=orchestrator; owner-doc=$doc; origin-worktree=$XREPO; NOT a design doc; mechanism-local, never staged by a skill -->

## 인가 $id
**인가 일시**: $auth
**종료 지점**: 픽스처 종료 지점
**권한 절단점**: PR
**말단 행위 상한**: 없음
**직렬 웨이브 고지**: 해당 없음
**시각 정합 마커**: 없음
**사용자 확인 문면**: 승인 / 이대로
**설계 문서 전체 sha256**: $dsha
**보고서**: $XPR/$id.md
EOF
  {
    printf '<!-- cc-run-kickoff v1; writer=autopilot (kickoff); reader=autopilot (kickoff resume, next kickoff Step 2, --report); run-id=%s; NOT a design doc; mechanism-local, never staged by a skill -->\n' "$id"
    printf -- '- %s | 단계=승인\n- %s | 단계=기동 직전\n' "$kick" "$auth"
  } > "$XPR/$id.kickoff.md"
  jq -cn --arg id "$id" --arg mp "$m" --arg auth "$kick" --arg enq "$(x_iso $((now - 10)))" --arg dl "$dl" \
     --arg base "$(cd "$XREPO" && git rev-parse HEAD)" --arg doc "$dsha" \
    '{schema: "cc-pace-backlog v1", id: $id, manifest_path: $mp, status: "pending", authorized_at: $auth,
      enqueued_at: $enq, deadline: $dl, base_commit: $base, doc_sha256: $doc, lane: ""}' >> "$XPACE/backlog.jsonl"
}

# x_env <command...> — the environment every actor of this fixture runs under.
x_env() {
  env -u TMUX_PANE -u CLAUDE_CONFIG_DIR -u CC_ORCH_SOURCE_ONLY -u CC_GATE_SOURCE_ONLY -u CC_REKICK_SOURCE_ONLY HOME="$XHOME" RUN_PACE_ROOT="$XPACE" FLEET_PACE_ROOT="$XPACE" \
    FLEET_LANE_PROBE="$X/bin/lane-probe.sh" CC_CLAUDE_BIN="$X/bin/claude" PATH="$X/bin:$PATH" \
    WATCH_REKICK_WAIT_SECONDS=5 R12_LOG="$XLOG" R12_GH="$X/gh" R12_REPO="$XREPO" R12_GATE="$GATE_SH" \
    R12_MODE="${R12_MODE:-}" R12_REVIEW_UNTIL="${R12_REVIEW_UNTIL:-}" "$@"
}
# x_dispatch <tag> — one dispatch tick of lane l1, bounded.
x_dispatch() {
  x_usage
  ( cd "$XREPO" && x_env "$BASH" "$ORCH/fleet.sh" dispatch l1 ) > "$X/$1.fleet.out" 2>&1 &
  local p=$! n=0
  while kill -0 "$p" 2>/dev/null && [ "$n" -lt 300 ]; do sleep 1; n=$((n + 1)); done
  kill -0 "$p" 2>/dev/null && { kill -TERM "$p" 2>/dev/null; printf 'x: 300 초 안에 돌아오지 않아 끊었다\n' >> "$X/$1.fleet.out"; }
  wait "$p" 2>/dev/null
  printf 'x: dispatch rc=%s after %ss\n' "$?" "$n" >> "$X/$1.fleet.out"
}
x_sweep() { ( cd "$XREPO" && x_env env REKICK_SWEEP_QUIET_SECONDS=0 "$BASH" "$REKICK" sweep --pace-root "$XPACE" --lane present ) >> "$X/sweep.out" 2>&1; }
x_outcome() { sed -n '1p' "$XPACE/rekick/$1/outcome" 2>/dev/null; }
x_reap() {
  # The watcher and the CI poller the dispatcher left behind for that run.
  local f
  for f in "$XRUN/$1/watch.pid" "$XRUN/$1/checks.pid"; do
    [ -f "$f" ] && kill -TERM "$(sed -n '1p' "$f")" 2>/dev/null
  done
  return 0
}
# xcheck — `check`, and its verdict as the status, so a failure can show why.
xcheck() { check "$@"; [ "$2" = "$3" ]; }
x_show() { printf -- '--- %s\n' "$1" >&2; tail -40 "$2" 2>/dev/null | sed 's/^/  /' >&2; }
# x_retire <id> — a successor this fixture only admits, taken off the head of
# the backlog so the next dispatch tick takes the next case's root.
x_retire() {
  jq -c --arg id "$1" 'if .id == $id then .status = "parked" | .park_reason = "fixture" else . end' \
    "$XPACE/backlog.jsonl" > "$X/backlog.t" && mv "$X/backlog.t" "$XPACE/backlog.jsonl"
}
# x_admit <id> — the admission the dispatcher runs before it starts a run.
x_admit() {
  ( cd "$XREPO" && x_env env CLAUDE_CONFIG_DIR="$XLANE" "$BASH" "$GATE_SH" snapshot --manifest "$XPR/$1.plan.md" ) \
    > "$X/$1.admit.out" 2>&1
  local rc=$?
  if [ "$rc" = 0 ] && ! grep -qF 'lineage-invalid' "$X/$1.admit.out"; then printf 통과; else printf '거부(rc=%s)' "$rc"; fi
}
x_ran() { grep -cE "^- \`run\` \| (교대=0 \| )?run-id=$1 " "$XPR/$1.md" 2>/dev/null || true; }
x_s4() { awk -F'\t' -v r="$1" '$1 == r && $2 ~ /^S4:/ { split($2, a, ":"); print a[2] }' "$XLOG" | sort -u | tr '\n' ' ' | sed 's/ $//'; }

# --- The deadline: slice A stops at its PR, then the deadline passes. ---------
# The review of A outlasts the deadline, so A ends at its PR with the merge
# refused and B is never started.
D1="$(date -u +%Y%m%d)-0000e2d1"
x_doc dl AB
now=$(date -u +%s)
x_root "$D1" dl $((now + 40))
R12_MODE="" R12_REVIEW_UNTIL=$((now + 45)) x_dispatch d1
xcheck "6e: 마감 런의 A 는 PR 에서 멈춘 종단 행을 남긴다" \
  "$(grep -F '`segment` | id=A | 상태=완료 | PR=1 ' "$XPR/$D1.md" | grep -c . || true)" "1" || x_show "d1 fleet" "$X/d1.fleet.out"
xcheck "6e: 마감 런은 A 만 구현하고 B 를 디스패치하지 않는다" "$(x_s4 "$D1")" "A"
xcheck "6e: 마감 런의 끝 자리 후보 표지는 마감이다" "$(sed -n 's/^토큰=//p' "$XRUN/$D1/rekick-candidate" 2>/dev/null)" "마감"
x_reap "$D1"
x_sweep
oc=$(x_outcome "$D1"); N1=${oc#*"$TAB"}
xcheck "6e: 사람의 재호출 없이 마감 런의 후속이 열린다" "${oc%%"$TAB"*}" "열림" || x_show sweep "$X/sweep.out"
R12_MODE="" R12_REVIEW_UNTIL="" x_dispatch n1
xcheck "6e: 후속 매니페스트가 입장 검사를 지나 후속 런이 기동된다" \
  "$(grep -cF 'lineage-invalid' "$X/n1.fleet.out" || true)/$([ "$(x_ran "$N1")" -gt 0 ] && echo 기동 || echo 없음)" "0/기동" \
  || x_show "n1 fleet" "$X/n1.fleet.out"
xcheck "6e: 후속 런 원장에 A 의 들인 종단 행이 있다" \
  "$(grep -E '^- `segment` \| (교대=0 \| )?id=A \| ' "$XPR/$N1.md" 2>/dev/null | grep -F " 출처=$D1" | grep -c . || true)" "1" \
  || x_show "n1 ledger" "$XPR/$N1.md"
xcheck "6e: 후속 런은 B 만 디스패치한다" "$(x_s4 "$N1")" "B"
x_reap "$N1"

# --- Forced surface moves: the stage's next gate call meets a moved surface. -
# x_surface <id> <name> <mode> [<길이>] — a one-slice root whose stage moves
# the surface that way, run to its end.
x_surface() {
  x_doc "$2" A
  x_root "$1" "$2" $(( $(date -u +%s) + 3600 )) "${4:-}"
  R12_MODE="$3" R12_REVIEW_UNTIL="" x_dispatch "$1"
  x_reap "$1"
}
S1="$(date -u +%Y%m%d)-0000e2e1"
x_surface "$S1" sc commit
xcheck "6e: 표면 이동 런의 단계가 게이트에서 표면 거부를 받는다" \
  "$(grep -F "$S1${TAB}gate-exec-rc=" "$XLOG" | cut -f2)" "gate-exec-rc=7" || x_show "s1 fleet" "$X/$S1.fleet.out"
xcheck "6e: 그 런의 끝 자리 후보 표지는 표면이동이다" "$(sed -n 's/^토큰=//p' "$XRUN/$S1/rekick-candidate" 2>/dev/null)" "표면이동"
x_sweep
oc=$(x_outcome "$S1"); NS1=${oc#*"$TAB"}
xcheck "6e: 베이스 브랜치에 커밋된 설정 변경은 후속을 자동으로 연다" "${oc%%"$TAB"*}" "열림" || x_show sweep "$X/sweep.out"
xcheck "6e: 그 후속 매니페스트는 입장 검사를 지난다" "$(x_admit "$NS1")" "통과" || x_show admit "$X/$NS1.admit.out"
x_retire "$NS1"
# The driver rebased the segment branch over that commit, so the branch
# contains it; what keeps it the base's is that it sits on the base branch's
# first-parent line. A settings change a merge brought in from a segment
# branch of the chain stays the chain's own.
( cd "$XREPO" && git checkout -q -b "seg/$S1-X" && printf '{"moved":"chain"}\n' > .claude/settings.json \
    && git add .claude/settings.json \
    && git -c user.name=t -c user.email=t@invalid -c commit.gpgsign=false commit -q -m "chain settings" \
    && git checkout -q master \
    && git -c user.name=t -c user.email=t@invalid -c commit.gpgsign=false merge -q --no-ff -m merge "seg/$S1-X" ) \
  || bad "6e: 연쇄 브랜치의 설정 머지를 만들지 못했다"
xcheck "6e: 연쇄의 세그먼트 브랜치가 머지로 들여온 설정 변경은 승인 갈래다" \
  "$(HOME="$XHOME" hx "rekick_surface_verdict '$XPR/$S1.plan.md' '$XPR/$S1.md'" | cut -f1)" "승인"

S2="$(date -u +%Y%m%d)-0000e2e2"
x_surface "$S2" sr runset
xcheck "6e: 런 설정만 바꾼 런도 표면이동으로 끝난다" "$(sed -n 's/^토큰=//p' "$XRUN/$S2/rekick-candidate" 2>/dev/null)" "표면이동"
x_sweep
oc=$(x_outcome "$S2"); NS2=${oc#*"$TAB"}
xcheck "6e: 런 설정만 움직인 런은 후속을 자동으로 연다" "${oc%%"$TAB"*}" "열림" || x_show sweep "$X/sweep.out"
xcheck "6e: 그 후속 매니페스트도 입장 검사를 지난다" "$(x_admit "$NS2")" "통과" || x_show admit "$X/$NS2.admit.out"
x_retire "$NS2"

S3="$(date -u +%Y%m%d)-0000e2e3"
x_surface "$S3" sd dirty
x_sweep
xcheck "6e: 커밋하지 않은 설정 편집은 후속을 만들지 않고 커밋 대기를 남긴다" \
  "$(x_outcome "$S3" | cut -f1)/$([ -e "$XPACE/rekick/$S3/successor" ] && echo 후속 || echo 없음)" "커밋 대기/없음" \
  || x_show sweep "$X/sweep.out"
( cd "$XREPO" && git checkout -q -- .claude/settings.json )
x_sweep
oc=$(x_outcome "$S3"); NS3=${oc#*"$TAB"}
xcheck "6e: 그 편집을 되돌리면 다음 sweep 이 후속을 연다" "${oc%%"$TAB"*}" "열림" || x_show sweep "$X/sweep.out"
xcheck "6e: 되돌린 뒤 연 후속 매니페스트도 입장 검사를 지난다" "$(x_admit "$NS3")" "통과" || x_show admit "$X/$NS3.admit.out"
x_retire "$NS3"

# The same edit left in place past a length — the fixture's length is short.
S4="$(date -u +%Y%m%d)-0000e2e4"
x_surface "$S4" sd2 dirty PT5S
sleep 6
x_sweep
xcheck "6e: 되돌리지 않은 채 길이가 지나면 결과가 사람이 된다" "$(x_outcome "$S4" | cut -f1)" "사람" || x_show sweep "$X/sweep.out"
( cd "$XREPO" && git checkout -q -- .claude/settings.json )

# --- A run that ends with only a cone park: its watcher. ---------------------
# The stage commits nothing, so the slice parks on its whole cone and nothing
# else is left. The watcher the dispatcher started for it is waited on.
C1="$(date -u +%Y%m%d)-0000e2f1"
x_doc cn A
x_root "$C1" cn $(( $(date -u +%s) + 3600 ))
R12_MODE=hollow R12_REVIEW_UNTIL="" x_dispatch "$C1"
xcheck "6e: 산출물 없는 단계의 런은 cone 범위 park 만 남긴다" \
  "$(grep -E '^- `blocked` \| ' "$XPR/$C1.md" | grep -vcF ' 스코프=cone ' || true)/$(grep -E '^- `blocked` \| ' "$XPR/$C1.md" | grep -cF ' 스코프=cone ' || true)" "0/1" \
  || x_show "c1 ledger" "$XPR/$C1.md"
wp=$(sed -n '1p' "$XRUN/$C1/watch.pid" 2>/dev/null)
n=0
while [ -n "$wp" ] && kill -0 "$wp" 2>/dev/null && [ "$n" -lt 150 ]; do sleep 1; n=$((n + 1)); done
xcheck "6e: cone park 만 남은 런의 감시자는 끝난다" \
  "$( [ -n "$wp" ] && ! kill -0 "$wp" 2>/dev/null && echo 끝남 || echo "남음(pid=${wp:-없음})")" "끝남" \
  || x_show "c1 watch" "$XRUN/$C1/watch.log"

for d in "$XRUN"/*; do x_reap "$(basename "$d")"; done
rm -f "$XHOME/.config/cc-lane/accounts.json"
fi

# ---------------------------------------------------------------------------
# 7. The driver's rows are on the chain (the run.sh ledger, measured).
# ---------------------------------------------------------------------------
# One slice's ledger as the real writers leave it: the driver's rows through
# run.sh's `ledger_row`, the gate's through `gate_append`, alternating, and the
# end row through the driver's own end site. Then: rows without a readable
# `prev=`, the chain verifier's return code on that run's id, and the rows the
# progress predicate read.
R14=20261001-0000aad0
mk_root "$R14"
mkdir -p "$W/rd/$R14"
printf '## 실행 %s\n' "$R14" > "$PR/$R14.md"
hx "MANIFEST='$PR/$R14.plan.md'; MANIFEST_MEMO_PATH=''; MANIFEST_MEMO=''
    RUN_DIR='$W/rd/$R14'; LEDGER='$PR/$R14.md'; LEDGER_SCOPE=파일; RUN_ID='$R14'; GRANT='$PG/$R14.md'
    ledger_row 'run' 'run-id=$R14' '시작=2026-10-01T00:01:00Z' '설계 문서=docs/x.md' '전체 sha256=$DOC_SHA' \
      'RUN_DIR=$W/rd/$R14' '보고서=$PR/$R14.md'
    gate_append 'run' 'run-id=$R14' '시작=2026-10-01T00:01:01Z' '설계 문서=docs/x.md' '전체 sha256=$DOC_SHA' \
      '구속면 다이제스트=s' 'RUN_DIR=$W/rd/$R14'
    ledger_row 'generation' '세대=1' '전체 sha256=$DOC_SHA' '사유=개시'
    ledger_row 'segment' 'id=A' '상태=계획됨' '레포=home'
    gate_append '문서 해시' '스테이지=A 이후' 'sha256=$DOC_SHA' '동결값=$DOC_SHA' '관측=같음'
    ledger_row 'stage-result' '세그먼트=A' '스테이지=S4' '파견 id=d1' '종료 코드=0'
    gate_append 'cycle' '세그먼트=A' '사이클=1' 'P0=0' 'P1=0'
    ledger_row 'segment' 'id=A' '상태=완료' '레포=home'
    ledger_row 'blocked' '대상=home' '세그먼트=B' '스코프=act' '원인=막힘' '사유=픽스처'
    ledger_row '자율 승인' 'kind=judgment' '결정=채택' '근거=픽스처'
    RUN_END_ARMED=1; RUN_END_HALT_STAGE=''; RUN_END_ALL_LANDED=1; RUN_END_LOOP_DONE=1
    run_end_record" > "$W/r14.out" 2>&1
r14_rows=$(grep -cE '^[- `]' "$PR/$R14.md" | tr -d ' ')
r14_noprev=$(grep -E '^[- `]' "$PR/$R14.md" | grep -cvE '[|] prev=[0-9a-f]{64}$' || true)
hx "gate_chain_verify '$PR/$R14.md' '$R14'" >/dev/null 2>&1; r14_rc=$?
r14_prog=$(hx "rekick_progress_rows '$PR/$R14.md'")
r14_series=$(grep -E '^- `' "$PR/$R14.md" | sed -E 's/^- `([^`]*)`.*/\1/' | tr '\n' ',')
printf 'R14 측정: 행 %s · prev 없는 행 %s · gate_chain_verify 반환 %s\n' "$r14_rows" "$r14_noprev" "$r14_rc"
printf 'R14 측정: 계열 순서 %s\n' "$r14_series"
grep -E 'warn|stop' "$W/r14.out" | sed 's/^/  r14: /' >&2 || true
printf 'R14 측정: 진전 판정이 읽은 행\n%s\n' "$r14_prog" | sed 's/^/  /'
check "run.sh 로 쓴 원장의 모든 행이 prev= 를 갖는다" "$r14_noprev" "0"
check "그 원장이 그 런 id 로 사슬 검증을 지난다" "$r14_rc" "0"
check "두 쓰기 자리의 행이 부른 순서대로 모두 들어갔다 (측정이 비지 않았다)" "$r14_series" \
  "run,run,generation,segment,문서 해시,stage-result,cycle,segment,blocked,자율 승인,자율 승인,"
check "행 수는 계열 순서와 같다" "$r14_rows" "11"
check "진전 판정은 사이클·완료 세그먼트 행을 읽는다" \
  "$(printf '%s\n' "$r14_prog" | sed -E 's/^- `([^`]*)`.*/\1/' | sort | tr '\n' ' ')" "cycle segment "
check "종료 행은 드라이버의 종료 자리가 쓴 정상 완료다" \
  "$(hx "rekick_completed '$PR/$R14.md' && echo 완료")" "완료"

printf '\n%s passed, %s failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
