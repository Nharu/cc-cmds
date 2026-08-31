#!/usr/bin/env bash
# lint-bash-portability: self-skip
# Test the progress digest and the snapshot object it is reported inside.
#
# THE DIGEST IS A TERMINATION INPUT, and that is the whole reason this file
# exists as a separate suite. The run's only automatic stop is "the progress
# vector has not moved for N cycles", so anything that moves the digest without
# the run having progressed makes the bound unreachable — silently, because a
# run that never terminates looks exactly like a run that is still working.
#
# The draft this replaced had that defect three times over: cost accumulated
# monotonically, recurrence counts accumulated monotonically, and the no-progress
# counter was itself inside the hashed input. Each one alone is enough to keep
# the digest moving forever.
#
# The fourth instance survived the repair and was caught by an audit reader: the
# vector still contained `pending_approvals[]`, and EVERY boundary that fires
# issues an approval — so a boundary's own remedy mutated the input to the
# counter that fired it. That is the regression section 3 pins, and it is the
# reason the read snapshot and the hashed vector are two different things rather
# than one object used twice.
#
# Usage: bash scripts/test-snapshot.sh

set -uo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
GATE="$repo_root/plugins/cc-cmds/orchestrator/gate.sh"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/cc-snapshot-test.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
export XDG_STATE_HOME="$WORK/state"

passed=0; failed=0
ok()   { passed=$((passed + 1)); printf 'PASS: %s\n' "$1"; }
bad()  { failed=$((failed + 1)); printf 'FAIL: %s — %s\n' "$1" "${2:-}" >&2; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got '$2', want '$3'"; fi; }

# ---------------------------------------------------------------------------
# 0. Fixture
# ---------------------------------------------------------------------------
REPO="$WORK/repo"
mkdir -p "$REPO"
( cd "$REPO" \
  && git init -q . \
  && git config user.email t@example.invalid \
  && git config user.name  T \
  && mkdir -p docs/pipeline-run docs/pipeline-grant \
  && echo one > a.txt && git add -A && git commit -qm one ) >/dev/null 2>&1

WT=$(cd "$REPO" && git rev-parse --show-toplevel)
CG=$(cd "$REPO" && git rev-parse --path-format=absolute --git-common-dir)
FIX_MANIFEST="$WT/plan.md"
FIX_LEDGER="$WT/docs/pipeline-run/R1.md"

row="- \`target\` | 별칭=repo | 메인 워크트리=$WT | 공통 git 디렉터리=$CG | 베이스 브랜치=main | 홈=예 | 원격 슬러그=t/t | 절단점=배포 | 말단 행위 상한=없음"
TD=$(printf '%s\n' "$row" | sed 's/[[:space:]]\{1,\}/ /g' | sort | shasum -a 256 | cut -d' ' -f1)
PLAN='{ "steps": [] }'
PD=$(printf '%s\n' "$PLAN" | shasum -a 256 | cut -d' ' -f1)

{
  printf '# 파이프라인 런 매니페스트 — R1\n'
  printf '<!-- cc-run-manifest v1; writer=autopilot; reader=orchestrator; run-id=R1;\n'
  printf '     anchor-kind=repo; anchor-key=t/t;\n'
  printf '     owner-doc=(없음); origin-worktree=%s;\n' "$WT"
  printf '     NOT a design doc; mechanism-local, never staged by a skill -->\n\n'
  printf '## 런 정체\n'
  printf '**킥오프 일시**: 2026-01-01T00:00:00Z\n**런 id**: R1\n'
  printf '**앵커 종류**: repo\n**앵커 키**: t/t\n**사용자 확인 문면**: 테스트 픽스처\n\n'
  printf '## 의도\n```text\n테스트\n```\n\n'
  printf '## 대상\n**대상 맵 다이제스트**: %s\n%s\n\n' "$TD" "$row"
  printf '## 요소\n**설계 문서**: (없음)\n**적용 주체**: (해당 없음)\n\n'
  printf '## 실행 계획\n**계획 다이제스트**: %s\n**승인 문면**: 테스트\n```json\n%s\n```\n\n' "$PD" "$PLAN"
  printf '## 인가\n**런 최대 절단점**: 배포\n**종료 지점**: 픽스처가 끝나면\n'
  printf '**벽시계 마감**: 2030-01-01T00:00:00Z\n**시각 정합 마커**: 없음\n'
  printf '**사다리 가용 단 수**: 4\n**미선언 상황 처분**: park\n'
} > "$FIX_MANIFEST"

# The gate reads the authorization record on every invocation, so the fixture
# carries one. `owner-doc` mirrors the manifest header — this is a documentless
# `repo`-anchored run — and the run maximum matches the single target.
cat > "$WT/docs/pipeline-grant/R1.md" <<GRANTEOF
# 파이프라인 인가 기록 — R1
<!-- cc-pipeline-grant v1; writer=autopilot; reader=orchestrator; owner-doc=(없음); origin-worktree=$WT; NOT a design doc; mechanism-local, never staged by a skill -->

## 인가 R1
**인가 일시**: 2026-01-01T00:00:00Z
**종료 지점**: 픽스처가 끝나면
**권한 절단점**: 배포
**말단 행위 상한**: 없음
**직렬 웨이브 고지**: 해당 없음
**시각 정합 마커**: 없음
**사용자 확인 문면**: 테스트 픽스처
**설계 문서 전체 sha256**: (해당 없음)
**보고서**: $WT/docs/pipeline-run/R1.md
GRANTEOF

: > "$FIX_LEDGER"

# ---------------------------------------------------------------------------
# 1. Load the definitions without a verb
# ---------------------------------------------------------------------------
CC_GATE_SOURCE_ONLY=1
export CC_GATE_SOURCE_ONLY
# The driver pins PATH to the sanitized set it wants for its own subprocesses,
# and sourcing imports that too — which takes `jq` (and anything else outside
# /usr/bin) away from the HARNESS. The gate re-sanitizes for itself on every
# invocation, so restoring the caller's PATH here changes nothing about what is
# under test and only gives the assertions their tools back.
HARNESS_PATH="$PATH"
# shellcheck disable=SC1090
. "$GATE"
PATH="$HARNESS_PATH"
# Both seam flags are EXPORTED — gate.sh exports run.sh's on the way in — so a
# child `bash gate.sh` inherits them, takes the source-only branch, and exits 0
# having printed nothing. Every CLI assertion below then compares against an
# empty string while the exit code says success, which is the quietest possible
# way for a suite to test nothing at all.
unset CC_GATE_SOURCE_ONLY CC_ORCH_SOURCE_ONLY
# AFTER the source, never before: run.sh re-initializes its own path variables
# to the empty string as part of loading, so a `MANIFEST=` set above this line
# is silently erased. What that erasure produced was not an error — `awk` with
# no file argument reads STDIN, so the digest call simply blocked forever.
MANIFEST="$FIX_MANIFEST"
LEDGER="$FIX_LEDGER"
RUN_ID="R1"
# Sourcing imports the driver's `-euo pipefail`. Every negative assertion below
# runs a command expected to fail, and under -e the first one would abort the
# whole suite instead of failing one line — the same reason test-run.sh does it.
set +e
ok "소싱 시임으로 게이트 정의만 로드된다"

digest() { gate_progress_digest; }
# The snapshot's `H` is NOT the progress digest, and the two must not be
# conflated again. The stagnation boundary needs a value blind to ordinary
# ledger appends; `--snapshot-digest` needs one that moves with them, or a
# router carrying a remembered value passes a check that was supposed to catch
# exactly that. One value cannot be both.
snapdigest() { gate_snapshot_digest; }

d0=$(digest)
case "$d0" in
  ????????????????????????????????????????????????????????????????) ok "진전 다이제스트가 64자리로 나온다" ;;
  *) bad "다이제스트 형태" "'$d0'" ;;
esac

# ---------------------------------------------------------------------------
# 2. Invariance — the same state hashes the same, twice and after noise
# ---------------------------------------------------------------------------
check "같은 상태를 두 번 재면 같다" "$(digest)" "$d0"

# Rows that carry no progress: a cost row and a repeated problem row. Both
# accumulate monotonically in any run, so if either moved the digest the
# no-progress bound could never be reached.
printf -- '- `cost` | 누적=1200 | 사이클=3\n' >> "$LEDGER"
check "비용 행은 진전이 아니다" "$(digest)" "$d0"

printf -- '- `cost` | 누적=99999 | 사이클=40\n' >> "$LEDGER"
check "비용이 40배가 되어도 진전이 아니다" "$(digest)" "$d0"

printf -- '- `stage-result` | 세그먼트=S1 | 결과=크래시 | 시각=2026-01-01T00:00:00Z\n' >> "$LEDGER"
check "스테이지 결과 행 자체는 진전이 아니다" "$(digest)" "$d0"

# ---------------------------------------------------------------------------
# 3. THE REGRESSION — issuing an approval must not move the digest
#
# Every one of the four termination boundaries answers by issuing an approval.
# With `pending_approvals[]` inside the hashed vector, that remedy re-hashes the
# input to the counter that fired it and the counter resets — so B1..B3 fire,
# reset themselves, and the run's only automatic stop becomes unreachable.
# ---------------------------------------------------------------------------
printf -- '- `승인` | 승인 id=A1 | 상태=대기 | 대상=repo | 절단점=배포 | 행위 다이제스트=abc | 구속 튜플=t | 막는 세그먼트=S1 | 질문 문면=q | 답변 문면=- | 발행 시각=2026-01-01T00:00:00Z | 해소 시각=-\n' >> "$LEDGER"
check "승인 대기를 발행해도 진전 해시는 움직이지 않는다 (치명 결함 회귀)" "$(digest)" "$d0"

printf -- '- `승인` | 승인 id=A2 | 상태=대기 | 대상=repo | 절단점=판단 | 행위 다이제스트=def | 구속 튜플=t | 막는 세그먼트=S2 | 질문 문면=q | 답변 문면=- | 발행 시각=2026-01-01T00:01:00Z | 해소 시각=-\n' >> "$LEDGER"
check "두 번째 승인 대기에도 움직이지 않는다" "$(digest)" "$d0"

printf -- '- `승인` | 승인 id=A1 | 상태=승인 | 대상=repo | 절단점=배포 | 행위 다이제스트=abc | 구속 튜플=t | 막는 세그먼트=S1 | 질문 문면=q | 답변 문면=예 | 발행 시각=2026-01-01T00:00:00Z | 해소 시각=2026-01-01T02:00:00Z\n' >> "$LEDGER"
check "승인이 해소되어도 그 자체로는 움직이지 않는다" "$(digest)" "$d0"

# The exclusion must not be vacuous: the snapshot the ROUTER reads still carries
# the pending approvals. Hiding them from the router would be a different bug
# with the same shape — a boundary nobody can see.
n_pending=$(cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null | jq -r '.pending_approvals | length')
check "그래도 스냅숏은 대기 중 승인을 라우터에게 보여 준다" "$n_pending" "1"

# ---------------------------------------------------------------------------
# 4. Sensitivity — the digest MUST move when the run actually progresses
#
# Without this section every assertion above is satisfied by a constant, and a
# constant digest stops the run immediately instead of never.
# ---------------------------------------------------------------------------
printf -- '- `segment` | id=S1 | 상태=착수 | 커밋=- | 워크트리=%s\n' "$WT" >> "$LEDGER"
d1=$(digest)
if [ "$d1" = "$d0" ]; then
  bad "세그먼트 진행" "세그먼트가 생겼는데 해시가 그대로다 — 위의 모든 불변 단언이 공허해진다"
else
  ok "세그먼트가 생기면 해시가 움직인다"
fi

printf -- '- `segment` | id=S1 | 상태=구현완료 | 커밋=deadbeef | 워크트리=%s\n' "$WT" >> "$LEDGER"
d2=$(digest)
if [ "$d2" = "$d1" ]; then
  bad "세그먼트 상태 전진" "상태와 커밋이 바뀌었는데 해시가 그대로다"
else
  ok "세그먼트 상태가 전진하면 해시가 움직인다"
fi

printf -- '- `problem` | 세그먼트=S1 | 동일성=P0-누수 | 시각=2026-01-01T03:00:00Z\n' >> "$LEDGER"
d3=$(digest)
if [ "$d3" = "$d2" ]; then
  bad "미해결 의무" "의무가 열렸는데 해시가 그대로다"
else
  ok "미해결 의무가 열리면 해시가 움직인다"
fi

# A repeat of the SAME identity is not new information — the obligation set is
# deduplicated, so a stage retrying the same failure all night cannot pass for
# progress.
printf -- '- `problem` | 세그먼트=S1 | 동일성=P0-누수 | 시각=2026-01-01T04:00:00Z\n' >> "$LEDGER"
check "같은 동일성의 재시도는 진전이 아니다" "$(digest)" "$d3"

# ---------------------------------------------------------------------------
# 5. Byte-identity of the rendered snapshot
# ---------------------------------------------------------------------------
( cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null ) > "$WORK/s1.json"
( cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null ) > "$WORK/s2.json"
if cmp -s "$WORK/s1.json" "$WORK/s2.json"; then
  ok "같은 원장에서 스냅숏은 바이트 동일하다"
else
  bad "스냅숏 결정성" "두 번 부른 결과가 다르다 — 낡음 판정이 매번 거짓 양성이 된다"
fi

if jq -e . "$WORK/s1.json" >/dev/null 2>&1; then
  ok "의무·승인이 실린 상태에서도 유효한 JSON 이다"
else
  bad "스냅숏 JSON" "행이 쌓이자 파싱이 깨졌다"
fi

check "스냅숏의 H 가 직접 잰 스냅숏 다이제스트와 같다" \
  "$(jq -r .H "$WORK/s1.json")" "$(snapdigest)"

# And it is NOT the progress digest — the separation is the fix, so assert it
# rather than leaving the two free to converge again.
if [ "$(snapdigest)" = "$(digest)" ]; then
  bad "다이제스트 분리" "스냅숏 다이제스트와 진전 다이제스트가 같은 값이다"
else
  ok "스냅숏 다이제스트와 진전 다이제스트가 서로 다른 값이다"
fi

# The one that matters: appending an ordinary row must move the snapshot digest
# (so exit 4 can fire) and must NOT move the progress digest (so the stagnation
# boundary is not reset by the gate's own writes).
sd_before=$(snapdigest); pd_before=$(digest)
printf -- '- `자율 승인` | kind= | 결정=exec | 근거=x | prev=z\n' >> "$FIX_LEDGER"
if [ "$(snapdigest)" != "$sd_before" ]; then
  ok "원장이 자라면 스냅숏 다이제스트가 움직인다"
else
  bad "스냅숏 다이제스트" "행을 붙였는데 값이 그대로다 — 낡은 다이제스트가 통과한다"
fi
check "같은 행이 진전 다이제스트는 움직이지 않는다" "$(digest)" "$pd_before"

n_ob=$(jq -r '.obligations_total' "$WORK/s1.json")
check "의무 총수가 중복 제거된 값으로 보고된다" "$n_ob" "1"

# ---------------------------------------------------------------------------
# 6. Damage is reported, never silently zero
#
# A row that does not parse could be the cycle row carrying the P0 the merge
# rule reads. Skipping it quietly makes a live defect look resolved, so the
# count is surfaced in the snapshot the router reads.
# ---------------------------------------------------------------------------
before=$(cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null | jq -r .ledger_damage)
check "정상 원장의 손상 수는 0" "$before" "0"

printf -- '- `segment | id=S2 상태=착수\n' >> "$LEDGER"
after=$(cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null | jq -r .ledger_damage)
if [ "$after" -gt 0 ] 2>/dev/null; then
  ok "행 문법이 깨진 줄이 손상으로 계수된다 (${after}건)"
else
  bad "손상 계수" "깨진 행을 넣었는데 손상 수가 '$after' 이다"
fi

# ---------------------------------------------------------------------------
# 7. The chain is what covers the ledger
#
# The ledger is deliberately NOT in the enforcement-surface digest: it grows on
# every act, written by the same call that would compare it, so a digest over it
# refuses every act after the first. The chain covers it instead, and covers it
# better — it tells a splice, a deletion and a reordering apart from an ordinary
# append, which a whole-file digest cannot.
# ---------------------------------------------------------------------------
CHAIN="$WORK/chain.md"
LEDGER_SAVE="$LEDGER"
LEDGER="$CHAIN"
: > "$CHAIN"
RUN_ID="R1"
# `gate_append` serializes through a lock file under RUN_DIR, and with RUN_DIR
# empty the lock path is unwritable — which used to lose every row silently.
RUN_DIR="$WORK/rundir"; mkdir -p "$RUN_DIR"
gate_append 'cost' "누적 usd=1"
gate_append 'cost' "누적 usd=2"
gate_append 'cost' "누적 usd=3"
if gate_chain_verify >/dev/null 2>&1; then
  ok "게이트가 쓴 행들의 체인이 무결로 검증된다"
else
  bad "체인 검증" "자기가 쓴 원장을 끊긴 것으로 읽는다"
fi

# Deleting a middle row leaves the line count wrong by one and every field
# intact — the shape no row-grammar check can see.
sed '2d' "$CHAIN" > "$CHAIN.cut" && mv "$CHAIN.cut" "$CHAIN"
if gate_chain_verify >/dev/null 2>&1; then
  bad "삭제 탐지" "가운데 행을 지웠는데 체인이 무결이라고 한다"
else
  ok "가운데 행 삭제가 체인에서 드러난다"
fi

LEDGER="$LEDGER_SAVE"

printf '\ntest-snapshot: %d passed, %d failed\n' "$passed" "$failed"
[ "$failed" = "0" ]
