#!/usr/bin/env bash
# Test the successor verdict and the deriver (orchestrator/rekick.sh).
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
# Usage: bash scripts/test-rekick.sh

set -uo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
ORCH="$repo_root/plugins/cc-cmds/orchestrator"
REKICK="$ORCH/rekick.sh"
GATE_SH="$ORCH/gate.sh"

# Physical, because the target row's common git directory is compared with what
# git prints, and git prints the resolved path (`/private/var` for `/var`).
W=$(mktemp -d "${TMPDIR:-/tmp}/cc-rekick-test.XXXXXX")
trap 'rm -rf "$W"' EXIT
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

# mk_root <id> [<연쇄 상한>] [<말단 행위 상한>] [<마지막 킥오프 단계>]
mk_root() {
  local id="$1" ccap="${2:-3}" tcap="${3:-없음}" last="${4:-기동 직전}" m
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
- \`target\` | 별칭=home | 메인 워크트리=$REPO | 공통 git 디렉터리=$REPO/.git | 베이스 브랜치=master | 홈=예 | 원격 슬러그=Nharu/cc-cmds | 절단점=PR | 말단 행위 상한=$tcap

## 요소
**설계 문서**: docs/x.md
**설계 문서 전체 sha256**: (해당 없음)

## 인가
**구속 다이제스트**: @@B@@
**런 최대 절단점**: PR
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
**권한 절단점**: PR
**말단 행위 상한**: $tcap
**직렬 웨이브 고지**: 해당 없음
**시각 정합 마커**: 없음
**사용자 확인 문면**: 승인 / 이대로
**설계 문서 전체 sha256**: (해당 없음)
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
vr "park 행이 있으면 런을 끝낸 토큰보다 먼저 보고 승인한다" "$RK" "승인/대상미선언"

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
vr "판단정지는 승인이다" "$RJ" "승인/판단정지"
RM=20261001-0000aab8; mk_root "$RM"; led_open "$RM"; end_row "$RM" 말단상한
vr "말단상한은 사람이다" "$RM" "사람/말단상한"
RW=20261001-0000aab9; mk_root "$RW"; led_open "$RW"; end_row "$RW" 무진전
vr "진전 없이 끝난 무진전 고리는 상한이다" "$RW" "상한/무진전"
RX=20261001-0000aaba; mk_root "$RX"; led_open "$RX"; progress "$RX"; end_row "$RX" 무진전
vr "진전한 무진전 고리는 자동이다" "$RX" "자동/무진전"
RY=20261001-0000aabb; mk_root "$RY"; led_open "$RY"; end_row "$RY" 사이클예산
vr "진전 없는 사이클예산은 상한이다" "$RY" "상한/사이클예산"
RZ=20261001-0000aabc; mk_root "$RZ"; led_open "$RZ"; end_row "$RZ" 결함 '' 'implement/S4/pin1'
vr "연쇄 안의 첫 결함은 자동이다" "$RZ" "자동/결함"

# Imported rows are the predecessor's work and do not count as progress.
RI=20261001-0000aabd; mk_root "$RI"; led_open "$RI"
g "$RI" "gate_append 'cycle' '세그먼트=A' '사이클=1' 'P0=0' 'P1=0' '출처=$R0'"
end_row "$RI" 천장
vr "들여온 행만 있는 천장 고리는 진전이 아니다" "$RI" "상한/천장"

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
vr "사슬 검증에 실패한 원장은 상한이다" "$RB" "상한/마감"

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
vr "무진전이 연달아 두 번이면 상한이다" "$D1" "상한/무진전"
check "같은 원인 정지 술어가 그 연쇄를 멈춘다" "$(hx "rekick_same_cause_stop '$PR/$D1.plan.md' && echo stop")" "stop"

# The same defect fingerprint a second time in the chain.
RE=20261001-0000aac3; mk_root "$RE"; led_open "$RE"; end_row "$RE" 결함 '' 'implement/S4/pin1'
E1=$(chain_next "$RE" 2026-10-03T00:00:00Z)
led_open "$E1"; end_row "$E1" 결함 '' 'implement/S4/pin1'
vr "같은 지문의 결함이 연쇄 안에서 두 번째면 상한이다" "$E1" "상한/결함"
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
RJ2=20261001-0000aad4; mk_root "$RJ2"; led_open "$RJ2"; end_row "$RJ2" 판단정지
ADIG=3333333333333333333333333333333333333333333333333333333333333333
mkdir -p "$W/claim-$RJ2"; printf '2026-10-03T00:00:00Z\n' > "$W/claim-$RJ2/at"
out=$(rk derive --predecessor "$PR/$RJ2.plan.md" --claim "$W/claim-$RJ2" --verdict 승인 \
        --approval "$RJ2#a1" --answer-digest "$ADIG")
J1=$(vcol "$out" 2); SJ="$PR/$J1.plan.md"
claim_commit "$RJ2" 2026-10-03T00:00:00Z "$J1"
g "$RJ2" "gate_append '승인' '승인 id=a1' '상태=대기' '대상=home' '절단점=판단'"
adm_is "(사) 아직 대기인 재인가 승인은 거부한다" "$SJ" "(사) 재인가 승인 $RJ2#a1 이 승인으로"
g "$RJ2" "gate_append '승인' '승인 id=a1' '상태=승인' '응답 토큰=-' '답변 다이제스트=-' '처분 사유=자동 해소'"
adm_is "(사) 자동 해소로 닫힌 승인은 사람의 승인이 아니다" "$SJ" "(사) 재인가 승인 $RJ2#a1 에 사람의 응답 토큰이 없습니다"
g "$RJ2" "gate_append '승인' '승인 id=a1' '상태=승인' '응답 토큰=t1' '답변 다이제스트=4444444444444444444444444444444444444444444444444444444444444444'"
adm_is "(사) 답변 다이제스트가 다른 승인은 거부한다" "$SJ" "(사) 연쇄 행의 답변 다이제스트"
g "$RJ2" "gate_append '승인' '승인 id=a1' '상태=승인' '응답 토큰=t1' '답변 다이제스트=$ADIG'"
check "사람이 닫은 같은 답변의 승인이면 지난다" "$(adm "$SJ")" "ok"
with_edit "$SJ" 's/ \| 재인가 승인=[^|]* \| 답변 다이제스트=[0-9a-f]{64}$//' \
  "(사) 승인 원인인데 재인가 승인이 없으면 거부한다" "$SJ" "(사) 원인 판단정지 은 재인가 승인이"

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
