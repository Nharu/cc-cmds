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

# THE RUN NOTIFIER IS OFF FOR THIS WHOLE PROCESS. The gate, the driver and the
# watcher all raise real banners, and their fire path prepends the Homebrew
# directories to PATH itself — so a stub this suite puts on PATH is shadowed by
# whatever is really installed, and an ordinary `make test` reaches the user.
# Measured on this tree: two banners arrived from a test run, one with sound.
#
# Exported rather than set per call, because the call sites cannot be made
# exhaustive — a new invocation is a normal thing to write and would silently
# not carry the guard. This suite asserts nothing about banner content, so
# turning the channel off costs it nothing.
CC_CMDS_AUTOPILOT_NOTIFY=0
export CC_CMDS_AUTOPILOT_NOTIFY
# Auto-resolution is off except in the section that tests it, so the approval
# fixtures above it stay pending the way they are written.
CC_CMDS_AUTOPILOT_AUTO_RESOLVE=0
export CC_CMDS_AUTOPILOT_AUTO_RESOLVE


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
# THE BRANCH IS PINNED, NOT ASSUMED. The target row below declares `main`, and
# the manifest preflight resolves that name against this repository — so the
# fixture only holds together if the branch really is called `main`. What
# `git init` names the first branch is a property of the git build and its
# system config, not of this suite: the Apple build ships
# `init.defaultBranch=main`, other builds still fall back to `master`. With the
# name left to the ambient git, every gate invocation below died in the
# preflight on a host whose git defaults to `master`, and since those calls are
# read through `2>/dev/null` the whole suite saw empty output rather than an
# error. The sibling gate fixture pins the same way.
( cd "$REPO" \
  && git init -q . \
  && git config user.email t@example.invalid \
  && git config user.name  T \
  && mkdir -p docs/pipeline-run docs/pipeline-grant \
  && echo one > a.txt && git add -A && git commit -qm one \
  && git branch -M main ) >/dev/null 2>&1

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

# `종단 부류=` and not `결과=`. The gate writes the former and nothing writes the
# latter, so the row as it stood exercised "an unrecognized field is ignored" and
# never touched the selector — it would have passed against an implementation
# that counted every `stage-result` row there is.
printf -- '- `stage-result` | 세그먼트=S1 | 종단 부류=크래시 | 시각=2026-01-01T00:00:00Z\n' >> "$LEDGER"
check "크래시로 끝난 스테이지 결과 행은 진전이 아니다" "$(digest)" "$d0"

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

# The total and the array are two derivations of one number, and a consumer that
# reads only the total — the emitted digest does exactly that — has no way to
# notice if they part company. So the agreement is the assertion, not the value.
n_pending_total=$(cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null | jq -r '.pending_approvals_total')
check "대기 승인 총계가 배열 길이와 같다" "$n_pending_total" "$n_pending"

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

# A STAGE FINISHING NORMALLY IS PROGRESS, and the vector could not see it.
# Segment rows move this digest only when the STATE changes, so a segment that
# runs several stages under one state contributes a constant — and an implement
# stage's plan-emission process and its editing process are BOTH `실행중`, so not
# even that transition is expressible as a segment row. Measured before this
# counter existed: a stage terminated normally, the ledger grew by a
# `stage-result` row and a `cost` row, the chain stayed intact, and both this
# digest and the act-budget window key came back byte-identical.
sn0=$(digest)
printf -- '- `stage-result` | 세그먼트=SN1 | 스테이지=SN1 | 종류=implement | 종료 코드=0 | 종단 부류=정상 완료\n' >> "$LEDGER"
sn1=$(digest)
if [ "$sn1" = "$sn0" ]; then
  bad "스테이지 정상 종단" "정상 완료 행이 들어왔는데 해시가 그대로다 — 스테이지가 끝나도 벡터가 보지 못한다"
else
  ok "첫 정상 완료 행이 다이제스트를 움직인다"
fi

# The pair that keeps the assertion above from being satisfied by "hash the
# whole ledger". A crashed stage built nothing to go on, and counting it would
# reset the stagnation counter on the very failure the counter exists to notice.
printf -- '- `stage-result` | 세그먼트=SN1 | 스테이지=SN1 | 종류=implement | 종료 코드=1 | 종단 부류=크래시\n' >> "$LEDGER"
check "크래시 종단은 다이제스트를 움직이지 않는다" "$(digest)" "$sn1"

# Refutes a boolean implementation. "Has any stage finished at all" satisfies the
# first assertion and stops moving here.
printf -- '- `stage-result` | 세그먼트=SN2 | 스테이지=SN2 | 종류=review | 종료 코드=0 | 종단 부류=정상 완료\n' >> "$LEDGER"
sn2=$(digest)
if [ "$sn2" = "$sn1" ]; then
  bad "다른 세그먼트의 정상 종단" "두 번째 세그먼트가 정상 종단했는데 해시가 그대로다"
else
  ok "다른 세그먼트의 정상 완료가 다시 움직인다"
fi

# THE DISCRIMINATOR, and the reason it is written this way rather than as another
# copy of the assertion above. The withdrawn design keyed a SET on
# `(세그먼트, 스테이지)`, and the gate writes both of those fields from one
# variable — so that set degenerates to the segment and this row does not move
# it. That design passes every assertion above and fails only here. Written to
# match it instead, this assertion would have pinned the standstill as the
# correct answer.
printf -- '- `stage-result` | 세그먼트=SN1 | 스테이지=SN1 | 종류=review | 종료 코드=0 | 종단 부류=정상 완료\n' >> "$LEDGER"
sn3=$(digest)
if [ "$sn3" = "$sn2" ]; then
  bad "같은 세그먼트의 두 번째 정상 종단" "같은 세그먼트가 또 정상 종단했는데 해시가 그대로다 — 집합 설계는 정확히 여기서만 갈린다"
else
  ok "같은 세그먼트의 두 번째 정상 완료가 움직인다 (집합 설계 판별자)"
fi

# The selection is POSITIVE, and the four rows below are what pins that. An
# exclusion-based selector passes the crash assertion above and fails on the
# first of them.
printf -- '- `stage-result` | 세그먼트=SN3 | 스테이지=SN3 | 종류=implement | 종료 코드=0 | 종단 부류=공허한 성공\n' >> "$LEDGER"
check "공허한 성공은 진전이 아니다 (제외 기반 구현이 여기서 실패한다)" "$(digest)" "$sn3"

printf -- '- `stage-result` | 세그먼트=SN4 | 스테이지=SN4 | 종류=implement | 종료 코드=0 | 종단 부류=아직 이름 없는 부류\n' >> "$LEDGER"
check "정의되지 않은 종단 부류는 진전이 아니다" "$(digest)" "$sn3"

printf -- '- `stage-result` | 세그먼트=SN5 | 스테이지=SN5 | 종류=implement | 종료 코드=0\n' >> "$LEDGER"
check "종단 부류 필드가 없는 행은 진전이 아니다" "$(digest)" "$sn3"

# The one that breaks the moment somebody simplifies the field parse into a
# substring match. The driver really does write a prose `관측=` field on these
# rows, so this shape is a live surface rather than a contrivance: the literal
# sits inside another field's value and the row's actual class is `크래시`.
printf -- '- `stage-result` | 세그먼트=SN6 | 스테이지=SN6 | 관측=앞 스테이지가 종단 부류=정상 완료 로 끝났다고 적혀 있었다 | 종단 부류=크래시\n' >> "$LEDGER"
check "다른 필드에 박힌 리터럴은 진전이 아니다 (부분 문자열 매치가 여기서 깨진다)" "$(digest)" "$sn3"

# THE SHAPE EVERY REAL ROW HAS, and every row above is the other one. The field
# read cuts the value at the next ` | ` when one follows and takes the rest of
# the line when none does — two branches — and the writer appends a `시각=` field
# after the class on every row it emits, so the ledger only ever contains the
# first shape while the rows above only ever exercise the second. An off-by-one
# in the boundary arithmetic of the branch that real rows take would leave this
# whole counter dead and every assertion above still green.
printf -- '- `stage-result` | 세그먼트=SN7 | 스테이지=SN7 | 종류=implement | 종료 코드=0 | 종단 부류=정상 완료 | 시각=2026-01-01T00:00:00Z\n' >> "$LEDGER"
sn4=$(digest)
if [ "$sn4" = "$sn3" ]; then
  bad "뒤에 필드가 붙은 정상 종단" "실제 원장 행의 모양(종단 부류 뒤에 시각 필드)이 들어왔는데 해시가 그대로다 — 이 카운터는 실제 런에서 죽어 있다"
else
  ok "종단 부류 뒤에 필드가 붙은 정상 완료가 움직인다 (실제 원장 행의 모양)"
fi

# The same shape on the refusing side. Without it the assertion above is also
# satisfied by a branch that counts whatever it finds once a field follows.
printf -- '- `stage-result` | 세그먼트=SN8 | 스테이지=SN8 | 종류=implement | 종료 코드=1 | 종단 부류=크래시 | 시각=2026-01-01T00:00:01Z\n' >> "$LEDGER"
check "뒤에 필드가 붙은 크래시는 진전이 아니다" "$(digest)" "$sn4"

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

# AN ABOVE-READ EXEC IS NOT PROGRESS EITHER. It used to be (`acts=`), and under
# the judgment definition that made the judgment count a component of the very
# digest the stagnation counter compares — the counter inside its own hash.
pd_before=$(digest)
printf -- '- `자율 승인` | kind= | 결정=exec | 대상=repo | 세그먼트=- | 절단점=커밋 | 축2=외부상태변경 | 자격=주변 | 행위자=리드 | 근거=x | prev=z\n' >> "$FIX_LEDGER"
check "읽기 초과 exec 행은 진전 다이제스트를 움직이지 않는다" "$(digest)" "$pd_before"

# A DISPATCH IS PROGRESS ONCE IT HAS AN OBSERVED OUTCOME, and not before. The
# authorisation row is appended BEFORE the launch, so a component that counted
# it moved on a dispatch that died at launch — and the failure row that follows
# does not take the authorisation row back. The component reads `stage-result`
# instead, for a segment the ROUTER dispatched: the seat comes from the
# segment's `kind=skill | 결정=act` row, selected on the actor field POSITIVELY,
# so the row a stage could forge (`행위자=스테이지`) and the row written before
# the field existed both make their segment's outcome count for nothing.
#
# The outcome classes used here are the two that `stage-normal=` does NOT
# count, so every movement below is this component's alone.
pd_before=$(digest)
printf -- '- `자율 승인` | kind=skill | 결정=act | 대상=repo | 세그먼트=SD1 | 절단점=배포 | 유도 절단점=- | 축2=워크트리쓰기 | 자격=주변 | 행위자=교대 | 근거=파견 | prev=z\n' >> "$FIX_LEDGER"
check "파견 인가 행만으로는 진전이 아니다 (기동보다 먼저 쓰이는 행이다)" "$(digest)" "$pd_before"
printf -- '- `자율 승인` | kind=skill | 결정=act | 대상=repo | 세그먼트=SD2 | 절단점=배포 | 유도 절단점=- | 축2=워크트리쓰기 | 자격=주변 | 행위자=리드 | 근거=파견 | prev=z\n' >> "$FIX_LEDGER"
check "리드의 파견 인가 행도 그 자체로는 진전이 아니다" "$(digest)" "$pd_before"
# THE FAILED DISPATCH, WHOLE: authorisation, the crash the gate records, and the
# failure row. The digest must sit where it was BEFORE the dispatch — compared
# against the pre-dispatch value, not the post-authorisation one, so a
# component that counts the authorisation row fails here rather than passing
# on a value it had already moved.
printf -- '- `stage-result` | 세그먼트=SD1 | 스테이지=SD1 | 종류=implement | 종료 코드=1 | 실행 버전=1 | 종단 부류=크래시 | 시각=2026-01-01T06:00:00Z\n' >> "$FIX_LEDGER"
printf -- '- `자율 승인` | kind=skill | 결정=결과 | 대상=repo | 세그먼트=SD1 | 절단점=배포 | 유도 절단점=- | 축2=워크트리쓰기 | 행위자=교대 | 근거=rc=1 | prev=z\n' >> "$FIX_LEDGER"
check "기동에서 죽은 파견은 인가·크래시·결과 행을 다 합쳐도 진전이 아니다 (파견 직전 값 그대로)" "$(digest)" "$pd_before"
printf -- '- `stage-result` | 세그먼트=SD1 | 스테이지=SD1 | 종류=implement | 종료 코드=0 | 실행 버전=2 | 종단 부류=의도된 park | 시각=2026-01-01T06:10:00Z\n' >> "$FIX_LEDGER"
pd_disp=$(digest)
if [ "$pd_disp" != "$pd_before" ]; then
  ok "교대가 파견한 스테이지가 관측 가능한 결과(의도된 park)를 남기면 진전이다"
else
  bad "파견 진전" "재파견이 park 로 끝났는데 해시가 그대로다"
fi
printf -- '- `stage-result` | 세그먼트=SD2 | 스테이지=SD2 | 종류=review | 종료 코드=0 | 실행 버전=1 | 종단 부류=산출물 없는 정지 | 시각=2026-01-01T06:20:00Z\n' >> "$FIX_LEDGER"
pd_lead=$(digest)
if [ "$pd_lead" != "$pd_disp" ]; then
  ok "리드가 파견한 스테이지의 결과(산출물 없는 정지)도 움직인다"
else
  bad "파견 진전" "리드 파견의 결과 행이 들어왔는데 해시가 그대로다"
fi
printf -- '- `stage-result` | 세그먼트=SD2 | 스테이지=SD2 | 종류=review | 종료 코드=0 | 실행 버전=2 | 종단 부류=공허한 성공 | 시각=2026-01-01T06:30:00Z\n' >> "$FIX_LEDGER"
check "라우터가 파견했어도 공허한 성공은 진전이 아니다 (아무것도 만들지 않은 파견)" "$(digest)" "$pd_lead"
printf -- '- `자율 승인` | kind=skill | 결정=act | 대상=repo | 세그먼트=SD3 | 절단점=배포 | 유도 절단점=- | 축2=워크트리쓰기 | 자격=주변 | 행위자=스테이지 | 근거=파견 | prev=z\n' >> "$FIX_LEDGER"
printf -- '- `stage-result` | 세그먼트=SD3 | 스테이지=SD3 | 종류=implement | 종료 코드=0 | 실행 버전=1 | 종단 부류=의도된 park | 시각=2026-01-01T06:40:00Z\n' >> "$FIX_LEDGER"
check "스테이지가 파견한 세그먼트의 결과는 진전이 아니다 (구속되는 쪽은 자기 진전을 쓸 수 없다)" "$(digest)" "$pd_lead"
printf -- '- `자율 승인` | kind=skill | 결정=act | 대상=repo | 세그먼트=SD4 | 절단점=배포 | 유도 절단점=- | 축2=워크트리쓰기 | 자격=주변 | 근거=옛 행 | prev=z\n' >> "$FIX_LEDGER"
printf -- '- `stage-result` | 세그먼트=SD4 | 스테이지=SD4 | 종류=implement | 종료 코드=0 | 실행 버전=1 | 종단 부류=의도된 park | 시각=2026-01-01T06:50:00Z\n' >> "$FIX_LEDGER"
check "행위자 필드 이전의 옛 파견 행이 낸 세그먼트의 결과는 아무것도 기여하지 않는다" "$(digest)" "$pd_lead"
printf -- '- `stage-result` | 세그먼트=SD5 | 스테이지=SD5 | 종류=implement | 종료 코드=0 | 실행 버전=1 | 종단 부류=의도된 park | 시각=2026-01-01T07:00:00Z\n' >> "$FIX_LEDGER"
check "게이트를 통해 파견된 적 없는 세그먼트의 결과는 진전이 아니다" "$(digest)" "$pd_lead"

n_ob=$(jq -r '.obligations_total' "$WORK/s1.json")
check "의무 총수가 중복 제거된 값으로 보고된다" "$n_ob" "1"

# A1 was issued and then resolved, A2 is still open — so the count the digest
# carries is 1, and it counts STATE rather than rows.
n_pa=$(jq -r '.pending_approvals_total' "$WORK/s1.json")
check "대기 승인 총수가 해소된 승인을 빼고 보고된다" "$n_pa" "1"

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
# 6b. What is holding the run — in the JSON and in the render
#
# The snapshot's top-level keys carried the goal, the targets, the obligations,
# the approvals, the damage count and the two digests, and nothing at all about
# the termination conditions — so a router obeying the contract and reading only
# this object could learn what blocked the end only by proposing it and reading
# the refusal. The render was worse: it printed `원장 손상`, `해시 체인` and
# `미해결 의무` in a row while a pending approval held the run, and the word
# `승인` appeared nowhere in the whole output.
# ---------------------------------------------------------------------------
SNAP_U="$WORK/unmet.json"
( cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null ) > "$SNAP_U"

if jq -e . "$SNAP_U" >/dev/null 2>&1; then
  ok "종료 조건 집합이 실린 스냅숏도 유효한 JSON 이다"
else
  bad "스냅숏 JSON" "종료 조건 키가 붙자 파싱이 깨졌다"
fi

# BOTH CLAUSES. The first alone passes on an implementation that always emits an
# empty array, and this fixture has non-terminal segments and a damaged row, so
# the conditions genuinely do not hold.
u_total=$(jq -r '.unmet_conditions_total' "$SNAP_U")
u_len=$(jq -r '.unmet_conditions | length' "$SNAP_U")
if [ "$u_total" -gt 0 ] 2>/dev/null && [ "$u_len" -gt 0 ] 2>/dev/null; then
  ok "JSON 이 종료 조건 집합을 싣고 미충족 픽스처에서 비어 있지 않다 (${u_total}건)"
else
  bad "종료 조건 집합" "총수 '$u_total' · 배열 길이 '$u_len' — 미충족이 있는 픽스처인데 비어 있다"
fi

# The number array is the half that is never truncated, so it has to be there
# even when the text list is capped.
u_nums=$(jq -r '.unmet_condition_numbers | length' "$SNAP_U")
if [ "$u_nums" -gt 0 ] 2>/dev/null; then
  ok "미충족 조건 번호가 별도 배열로 실린다 (${u_nums}개)"
else
  bad "조건 번호 배열" "미충족이 ${u_total}건인데 번호 배열이 비어 있다"
fi

check "처분이 세 토큰 중 하나로 실린다" "$(jq -r '.disposition' "$SNAP_U")" "미충족"

# The approval array now says which KIND of answer each entry is waiting for.
# Termination condition 2 does not count an approval whose cutpoint is `판단`,
# and without this field the router cannot tell the two lifetimes apart.
check "대기 승인 항목이 절단점을 싣는다" \
  "$(jq -r '.pending_approvals[0].cutpoint' "$SNAP_U")" "판단"
check "대기 승인 항목이 질문 문면을 싣는다" \
  "$(jq -r '.pending_approvals[0].question' "$SNAP_U")" "q"

RENDER_U="$WORK/render.txt"
( cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" --render 2>/dev/null ) > "$RENDER_U"

# THE COUNT, not merely the line. A render that prints the label and no number
# reports the same thing whether one approval is open or twelve are.
if grep -q '^대기 승인 : 1건$' "$RENDER_U"; then
  ok "렌더가 대기 승인 줄을 내고 실제 건수를 싣는다"
else
  bad "대기 승인 줄" "got '$(grep '대기 승인' "$RENDER_U" || printf '(줄 없음)')'"
fi

if grep -q '^미충족 조건: 조건 ' "$RENDER_U"; then
  ok "렌더가 미충족 조건을 번호로 보여 준다"
else
  bad "미충족 조건 줄" "got '$(grep '미충족 조건' "$RENDER_U" || printf '(줄 없음)')'"
fi

# ---------------------------------------------------------------------------
# 6c. `cycles[]` carries what a delta basis is chosen from
#
# The router picks a segment's last FULL cycle as the basis for a delta review
# and hands its review HEAD and report path to the review stage. With only
# `세그먼트`/`사이클`/`P0`/`P1` on the row object it had to open the ledger to
# find either, and the ledger is what the snapshot exists to stand in for. An
# absent `모드` is emitted as the empty string — the reader takes it as 전체 —
# so every row written before the field existed still parses as a full cycle.
# ---------------------------------------------------------------------------
printf -- '- `cycle` | 세그먼트=S9 | 사이클=1 | P0=0 | P1=0 | 리뷰 HEAD=abc1234 | 리포트 경로=docs/reviews/s9-1.md\n' >> "$LEDGER"
printf -- '- `cycle` | 세그먼트=S9 | 사이클=2 | P0=0 | P1=0 | 리뷰 HEAD=def5678 | 리포트 경로=/abs/s9-2.md | 모드=델타 | 기준 사이클=1\n' >> "$LEDGER"
SNAP_C="$WORK/cycles.json"
( cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null ) > "$SNAP_C"
check "모드 없는 cycle 행은 빈 모드로 실린다" \
  "$(jq -r '.cycles[] | select(.["세그먼트"]=="S9" and .["사이클"]=="1") | .["모드"]' "$SNAP_C")" ""
check "cycle 행이 리뷰 HEAD 를 싣는다" \
  "$(jq -r '.cycles[] | select(.["세그먼트"]=="S9" and .["사이클"]=="1") | .["리뷰 HEAD"]' "$SNAP_C")" "abc1234"
check "cycle 행이 리포트 경로를 싣는다" \
  "$(jq -r '.cycles[] | select(.["세그먼트"]=="S9" and .["사이클"]=="1") | .["리포트 경로"]' "$SNAP_C")" "docs/reviews/s9-1.md"
check "델타 행의 모드가 실린다" \
  "$(jq -r '.cycles[] | select(.["세그먼트"]=="S9" and .["사이클"]=="2") | .["모드"]' "$SNAP_C")" "델타"

# The router's basis selection is one jq expression carried in both router
# skills. `사이클` is a JSON string here, so a string maximum picks "9" over
# "10" and offers a basis the gate refuses as stale on every re-dispatch. The
# carried expression compares integers, and the two copies are held
# byte-identical so a fix to one cannot leave the other behind.
AP_SKILL="$repo_root/plugins/cc-cmds/skills/autopilot/SKILL.md"
RS_SKILL="$repo_root/plugins/cc-cmds/skills/autopilot-router-shift/SKILL.md"
sel_ap=$(grep -oE '\[\.cycles\[\] \| select\(.*// -1\)' "$AP_SKILL" || true)
sel_rs=$(grep -oE '\[\.cycles\[\] \| select\(.*// -1\)' "$RS_SKILL" || true)
check "기반 라우터 문서에 기준 선택 식이 한 번 실린다" "$(printf '%s\n' "$sel_ap" | grep -c '^\[')" "1"
check "라우터 두 사본의 기준 선택 식이 바이트 동일하다" "$sel_rs" "$sel_ap"
printf -- '- `cycle` | 세그먼트=S8 | 사이클=9 | P0=0 | P1=1 | 리뷰 HEAD=aaa0009 | 리포트 경로=/abs/s8-9.md\n' >> "$LEDGER"
printf -- '- `cycle` | 세그먼트=S8 | 사이클=10 | P0=0 | P1=1 | 리뷰 HEAD=aaa0010 | 리포트 경로=/abs/s8-10.md | 모드=전체\n' >> "$LEDGER"
printf -- '- `cycle` | 세그먼트=S8 | 사이클=11 | P0=0 | P1=0 | 리뷰 HEAD=aaa0011 | 리포트 경로=/abs/s8-11.md | 모드=델타 | 기준 사이클=10\n' >> "$LEDGER"
SNAP_D="$WORK/cycles-basis.json"
( cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null ) > "$SNAP_D"
sel_s8=$(printf '%s' "$sel_ap" | sed 's/<세그먼트>/S8/')
sel_none=$(printf '%s' "$sel_ap" | sed 's/<세그먼트>/S-none/')
check "기준 선택 식이 문자열이 아니라 정수로 최대 전체 사이클을 고른다" \
  "$(jq -r "($sel_s8) | if . == null then \"없음\" else .[\"사이클\"] end" "$SNAP_D" 2>/dev/null)" "10"
check "전체 사이클이 없는 세그먼트에서는 그 식이 기준 없음을 낸다" \
  "$(jq -r "($sel_none) | if . == null then \"없음\" else .[\"사이클\"] end" "$SNAP_D" 2>/dev/null)" "없음"

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

# ---------------------------------------------------------------------------
# 8. The judgment predicate — who moves the stagnation counter, and B4 outside it
#
# `gate_boundaries` is driven directly through the sourcing seam. B1..B3 are
# evaluated on a JUDGMENT only: a call from a seat that is not a stage, graded
# above `읽기`, whose kind is neither a dispatch nor a shift launch. All three
# seat markers are PINNED on every call — this suite runs from inside a
# pipeline stage too, and an inherited marker would make every row below a
# stage call that judges nothing. A1 is resolved and A2 is `절단점=판단`, so no
# act-class approval suspends the boundaries here.
# ---------------------------------------------------------------------------
printf '%s\n' "$(digest)" > "$RUN_DIR/progress-digest"
printf '%s\n' "1" > "$RUN_DIR/progress-repeat"
printf '%s\n' "0" > "$RUN_DIR/obligation-repeat"
judge() {  # judge <seg> <stage> <shift> <graded> <kind>
  ( CC_PIPELINE_SEGMENT="$1" CC_PIPELINE_STAGE_ID="$2" CC_PIPELINE_SHIFT_ID="$3"
    export CC_PIPELINE_SEGMENT CC_PIPELINE_STAGE_ID CC_PIPELINE_SHIFT_ID
    gate_boundaries "$4" "$5" ) >/dev/null 2>&1
  cat "$RUN_DIR/progress-repeat"
}
check "스테이지 좌석의 읽기 초과 호출은 판정이 아니다"          "$(judge S1 'S1#1' '' 워크트리쓰기 '')" "1"
check "스테이지 마커 하나만 서 있어도 판정이 아니다"             "$(judge '' 'S1#1' '' 워크트리쓰기 '')" "1"
check "라우터의 읽기는 판정이 아니다"                            "$(judge '' '' '' 읽기 '')" "1"
check "기장 행위(읽기 등급)는 판정이 아니다"                     "$(judge '' '' '' 읽기 segment)" "1"
check "파견(kind=skill)은 판정이 아니다"                         "$(judge '' '' '' 워크트리쓰기 skill)" "1"
check "교대 기동(kind=router-shift)은 판정이 아니다"             "$(judge '' '' '' 워크트리쓰기 router-shift)" "1"
# The control rows: without them every row above passes against a boundary
# that never counts.
check "리드의 읽기 초과 행위는 판정이다 (카운터 +1)"             "$(judge '' '' '' 워크트리쓰기 x)" "2"
check "교대 샤드의 읽기 초과 행위도 판정이다 (샤드는 라우터다)"  "$(judge '' '' 'R1#1' 외부상태변경 '')" "3"
check "여기까지 경계 승인은 없다 (N=5 미만)" "$(grep -c '절단점=경계' "$LEDGER" || true)" "0"

# ---------------------------------------------------------------------------
# 8b. An answered B1 stays answered until the digest moves
#
# The binding of B1 is the progress digest, an `승인` row is not in the vector,
# and nothing the router does with its own hands moves it — so after a person
# closes the approval, the judgment that brings the count back to the threshold
# computes the SAME id. An issuer that re-opened any answered id the moment its
# predicate held again put a fresh `대기` row there: "keep going" bought
# nothing, and the run a person had just released was suspended again. What an
# answer buys is one frozen state; the next question is earned by a structural
# row moving the digest to a new id.
#
# The close goes through `gate_close_settle`, the path a real close takes, so
# the count restarts from 0 as it does in a run. The count is then seeded one
# below the threshold rather than marched there, which is the state the
# intervening judgments would leave — the property under test is what the
# issuer does AT the threshold on an answered id, not the arithmetic of getting
# there.
#
# Driven through the same seam, one judgment at a time. `obligation-repeat` is
# re-seeded before every judgment: this fixture ledger carries an open
# obligation and B2 would otherwise fire on the third judgment and suspend the
# very boundary under test. B1's own row is what is counted, by its id.
# ---------------------------------------------------------------------------
judge_b1() {  # judge_b1 — one router judgment with B2 held at zero
  printf '%s\n' "0" > "$RUN_DIR/obligation-repeat"
  judge '' '' '' 워크트리쓰기 x >/dev/null
}
b1_ids() { { grep -F '`승인`' "$LEDGER" || true; } | grep -F '구속 튜플=B1/' | grep -F '상태=대기' \
           | sed -n 's/.*승인 id=\([^ |]*\).*/\1/p'; }
printf '%s\n' "$(digest)" > "$RUN_DIR/progress-digest"
printf '%s\n' "$((B1_STAGNATION_N - 1))" > "$RUN_DIR/progress-repeat"
judge_b1
check "문턱에 닿은 판정이 B1 을 발화시킨다 (대기 행 1)" "$(b1_ids | grep -c . || true)" "1"
b1_first=$(b1_ids | sed -n '1p')
# The person answers. The row shape is the one `close` writes; the seam has no
# transcript to read an answer from, so the row is appended directly.
printf -- '- `승인` | 승인 id=%s | 상태=승인 | 답변 문면=계속 | 해소 시각=2026-01-01T05:30:00Z | prev=z\n' "$b1_first" >> "$FIX_LEDGER"
check "답이 붙어도 진전 다이제스트는 그대로다 (같은 결속값, 같은 id)" "$(digest)" "$(cat "$RUN_DIR/progress-digest")"
gate_close_settle "$b1_first" 2>/dev/null
check "답을 닫으면 반복 계수가 0 으로 재기준선화된다" "$(cat "$RUN_DIR/progress-repeat")" "0"
printf '%s\n' "$((B1_STAGNATION_N - 1))" > "$RUN_DIR/progress-repeat"
judge_b1
check "재기준선화 뒤 같은 결속값에서 카운터가 문턱에 다시 닿는다" "$(cat "$RUN_DIR/progress-repeat")" "$B1_STAGNATION_N"
check "그러나 같은 id 로 새 대기 행을 붙이지 않는다 (「계속 가라」가 얼어붙은 상태 하나를 산다)" \
  "$(b1_ids | grep -c "^$b1_first\$" || true)" "1"
judge_b1
check "판정이 거듭돼도 답한 id 는 다시 묻지 않는다" "$(b1_ids | grep -c "^$b1_first\$" || true)" "1"
# A structural row moves the digest: the counter goes to 0 and the next
# stagnation is a NEW id, which does ask.
printf -- '- `종료 절` | id=C1 | 상태=충족 | 근거=픽스처 | prev=z\n' >> "$FIX_LEDGER"
judge_b1
check "구조적 행이 착지하면 카운터가 0 으로 돌아간다" "$(cat "$RUN_DIR/progress-repeat")" "0"
printf '%s\n' "$((B1_STAGNATION_N - 1))" > "$RUN_DIR/progress-repeat"
judge_b1
b1_second=$(b1_ids | grep -v "^$b1_first\$" | sed -n '1p')
if [ -n "$b1_second" ]; then
  ok "새 다이제스트에서의 정체는 새 id 로 묻는다 (답이 경계를 끈 것이 아니다)"
else
  bad "B1 재발화" "다이제스트가 움직인 뒤 다시 정체했는데 새 대기 행이 없다"
fi
# THE RECURRENCE ARM — the reason the suppression is not "any row exists". The
# same digest answered once and returning LATER is a new stagnation, not the
# state that was answered. Answer the second id, march the digest away
# (a judgment against a foreign seed resets the counter and drops the marker),
# and the same value returning to the threshold asks again under the same id.
printf -- '- `승인` | 승인 id=%s | 상태=승인 | 답변 문면=계속 | 해소 시각=2026-01-01T05:40:00Z | prev=z\n' "$b1_second" >> "$FIX_LEDGER"
gate_close_settle "$b1_second" 2>/dev/null
printf '%s\n' "$((B1_STAGNATION_N - 1))" > "$RUN_DIR/progress-repeat"
judge_b1
check "두 번째 답도 문턱의 같은 판정에서 다시 묻지 않는다" "$(b1_ids | grep -c "^$b1_second\$" || true)" "1"
printf '%s\n' "다른 곳에 있었던 다이제스트" > "$RUN_DIR/progress-digest"
judge_b1
check "결속값이 움직였던 판정은 카운터를 0 으로 놓는다" "$(cat "$RUN_DIR/progress-repeat")" "0"
printf '%s\n' "$((B1_STAGNATION_N - 1))" > "$RUN_DIR/progress-repeat"
judge_b1
check "같은 결속값이 떠났다가 돌아와 다시 정체하면 같은 id 로 다시 묻는다 (재발은 답한 상태가 아니다)" \
  "$(b1_ids | grep -c "^$b1_second\$" || true)" "2"
# Leave nothing open for the B4 rows below: an open act-class approval would
# suspend B1..B3, and B4 is asserted to run regardless, so the two must not be
# confused.
printf -- '- `승인` | 승인 id=%s | 상태=승인 | 답변 문면=계속 | 해소 시각=2026-01-01T05:50:00Z | prev=z\n' "$b1_second" >> "$FIX_LEDGER"

# B4 IS OUTSIDE THE PREDICATE: a read-only router — or a stage — still spends
# tokens, and a cost boundary inside the predicate would leave that spend unseen
# by every boundary at once. `## 인가` is the manifest's last section, so the
# ceiling lands inside it; no CLI call follows this point.
printf '**비용 천장**: 100\n' >> "$FIX_MANIFEST"
printf -- '- `cost` | 누적 usd=90 | 스테이지 수=1 | 관측 시각=2026-01-01T05:00:00Z | prev=z\n' >> "$FIX_LEDGER"
pr_before_b4=$(cat "$RUN_DIR/progress-repeat")
judge S1 'S1#1' '' 읽기 '' >/dev/null
check "스테이지의 읽기에서도 B4 는 평가된다 (술어 밖)" "$(grep -c '구속 튜플=B4' "$LEDGER" || true)" "1"
check "그 호출이 정체 카운터는 건드리지 않았다" "$(cat "$RUN_DIR/progress-repeat")" "$pr_before_b4"

# ---------------------------------------------------------------------------
# 8c. A resolved boundary approval restarts its count, and auto-resolution
#     closes the approval instead of waiting on a person
#
# The regression: the counters live in the run directory and a close left them
# where they were, so the next evaluation after a grant issued the same question
# again with the same count. Measured three seconds after a grant.
#
# The restart and the answered-id suppression of 8b hold together. So every
# step below that expects the SAME id to be issued again first makes it a real
# recurrence — the digest moves away (one evaluation against a foreign seed,
# which zeroes the count and clears the marker) and comes back — rather than
# re-seeding the count on a binding that was already answered, which 8b pins as
# staying quiet.
# ---------------------------------------------------------------------------
BLEDGER="$WORK/boundary.md"
LEDGER_SAVE="$LEDGER"
LEDGER="$BLEDGER"
: > "$BLEDGER"
RUN_DIR="$WORK/rundir-boundary"; mkdir -p "$RUN_DIR"
boundary_rows() { { grep -E '^- `승인`' "$BLEDGER" || true; } | { grep -F "| 승인 id=$1-" || true; }; }
# b1_recur — the binding moves away and comes back, one below the threshold.
b1_recur() {
  printf '%s\n' "다른 곳에 있었던 다이제스트" > "$RUN_DIR/progress-digest"
  gate_b1_stagnation 2>/dev/null
  printf '%s\n' "$((B1_STAGNATION_N - 1))" > "$RUN_DIR/progress-repeat"
}

CC_CMDS_AUTOPILOT_AUTO_RESOLVE=0
printf '%s\n' "$(gate_progress_digest)" > "$RUN_DIR/progress-digest"
printf '%s\n' "$((B1_STAGNATION_N - 1))" > "$RUN_DIR/progress-repeat"
gate_b1_stagnation 2>/dev/null
b1_id=$(boundary_rows B1 | tail -1 | tr '|' '\n' | sed -n 's/^ *승인 id=//p' | sed 's/[[:space:]]*$//')
check "수동 모드에서 B1 은 대기로 발행된다" "$(gate_approval_state "$b1_id")" "대기"
gate_append '승인' "승인 id=$b1_id" "상태=승인" "질문 문면=q" "답변 문면=트랜스크립트 판독" \
  "해소 시각=2026-01-01T00:00:00Z" "응답 토큰=t" "답변 다이제스트=-" "사이드카 앵커=-"
gate_close_settle "$b1_id" 2>/dev/null
check "B1 승인을 닫으면 반복 계수가 0 으로 재기준선화된다" "$(cat "$RUN_DIR/progress-repeat")" "0"
gate_b1_stagnation 2>/dev/null
check "해소 직후 다음 판정은 같은 질문을 다시 열지 않는다 (#363 회귀)" "$(gate_approval_state "$b1_id")" "승인"

CC_CMDS_AUTOPILOT_AUTO_RESOLVE=1
n_before=$(boundary_rows B1 | gate_count)
printf '%s\n' "$((B1_STAGNATION_N - 1))" > "$RUN_DIR/progress-repeat"
gate_b1_stagnation 2>/dev/null
check "자동 해소 모드에서도 답한 id 는 같은 결속값의 문턱에서 발행되지 않는다" \
  "$(boundary_rows B1 | gate_count)" "$n_before"
b1_recur
gate_b1_stagnation 2>/dev/null
check "자동 해소 모드에서 B1 은 발행 행과 닫는 행 둘을 남긴다" "$(boundary_rows B1 | gate_count)" "$((n_before + 2))"
check "자동 해소된 B1 은 대기로 남지 않는다" "$(gate_approval_state "$b1_id")" "승인"
check "자동 해소 행은 처분 사유를 싣는다" \
  "$(boundary_rows B1 | tail -1 | tr '|' '\n' | sed -n 's/^ *처분 사유=//p' | sed 's/[[:space:]]*$//')" "자동 해소"
check "자동 해소도 반복 계수를 재기준선화한다" "$(cat "$RUN_DIR/progress-repeat")" "0"

# A boundary approval left open from before is closed on the next evaluation.
CC_CMDS_AUTOPILOT_AUTO_RESOLVE=0
b1_recur
gate_b1_stagnation 2>/dev/null
check "수동 모드에서 다시 대기가 열린다" "$(gate_approval_state "$b1_id")" "대기"
CC_CMDS_AUTOPILOT_AUTO_RESOLVE=1
# The seat markers are pinned for the reason section 8 gives: this suite can run
# inside a pipeline stage, and the close under test must not depend on whether
# the predicate after it happens to hold.
( CC_PIPELINE_SEGMENT='' CC_PIPELINE_STAGE_ID='' CC_PIPELINE_SHIFT_ID=''
  export CC_PIPELINE_SEGMENT CC_PIPELINE_STAGE_ID CC_PIPELINE_SHIFT_ID
  gate_boundaries ) 2>/dev/null
check "열려 있던 경계 승인이 다음 경계 판정에서 자동 해소된다" "$(gate_approval_state "$b1_id")" "승인"
check "대기 중인 경계 승인이 남지 않는다" "$(gate_pending_approval_ids act | gate_count)" "0"

# B3 restarts from the total as of the close, not from the window start.
CC_CMDS_AUTOPILOT_AUTO_RESOLVE=0
printf '0\n' > "$RUN_DIR/act-budget-base"
# One router row and one stage row. The rebaseline measures the same total the
# boundary compares against, so it inherits the boundary's actor filter; without
# the stage row a total that ignored the filter would pass every line below.
gate_append '자율 승인' "kind=exec" "결정=exec" "축2=워크트리쓰기" "행위자=리드" "근거=x"
gate_append '자율 승인' "kind=exec" "결정=exec" "축2=워크트리쓰기" "행위자=스테이지" "근거=x"
check "B3 총계는 라우터의 읽기 초과 exec 만 센다 (스테이지 행 제외)" "$(gate_b3_exec_total)" "1"
gate_boundary_rebaseline B3
check "B3 재기준선화는 기준을 현재 총계로 옮긴다" "$(cat "$RUN_DIR/act-budget-base")" "$(gate_b3_exec_total)"
check "B3 재기준선화는 경계가 읽는 창 키(진전 다이제스트)를 쓴다" \
  "$(cat "$RUN_DIR/act-budget-digest")" "$(gate_progress_digest)"
# With a key that differs from the boundary's the next evaluation sees a moved
# window, re-bases on it and drops the answered marker — the rebaseline undone
# by the boundary it serves.
printf '%s\n' "답한 결속값" > "$RUN_DIR/boundary-B3.asked"
gate_b3_act_budget 2>/dev/null
check "재기준선화 직후의 B3 판정은 새 창을 열지 않는다 (답한 표지가 남는다)" \
  "$(cat "$RUN_DIR/boundary-B3.asked" 2>/dev/null || printf '(없음)')" "답한 결속값"

# B4 at or above the declared ceiling is NOT auto-resolved. The ceiling's own
# evaluation ends the run there instead of asking (section 8d), so no approval is
# issued at 100% — but one issued below the ceiling can still be open when
# spending crosses it, and the open-approval sweep must not close it: that would
# write an automatic "keep going" onto the one open question a shift reads, on
# the very evaluations that end the night on cost. Below the ceiling the early
# warning is still resolved.
#
# The cost rows do not move the progress digest, so every step below computes
# the SAME id: the 80% resolved automatically, then the 90% re-opened with the
# switch off. That re-open is the case the issuer's answered arm has to let
# through — an auto-resolution is not a person's "keep going", and holding it
# quiet would leave nothing open for the ceiling crossing to keep waiting.
B4_MANIFEST="$WORK/plan-b4.md"
awk '{ print } $0 == "## 인가" { print "**비용 천장**: 40" }' "$FIX_MANIFEST" > "$B4_MANIFEST"
B4_MANIFEST_SAVE="$MANIFEST"
MANIFEST="$B4_MANIFEST"
rm -f "$RUN_DIR/cost-resolved-pct"
b4_auto_rows() { boundary_rows B4 | { grep -F '처분 사유=자동 해소' || true; } | gate_count; }
CC_CMDS_AUTOPILOT_AUTO_RESOLVE=1
gate_append 'cost' "누적 usd=32"
gate_b4_cost 2>/dev/null
b4_id=$(boundary_rows B4 | tail -1 | tr '|' '\n' | sed -n 's/^ *승인 id=//p' | sed 's/[[:space:]]*$//')
check "천장의 80% 인 B4 는 자동 해소된다" "$(gate_approval_state "$b4_id")" "승인"
check "그 해소는 자동 해소 행 하나다" "$(b4_auto_rows)" "1"
CC_CMDS_AUTOPILOT_AUTO_RESOLVE=0
gate_append 'cost' "누적 usd=36"
gate_b4_cost 2>/dev/null
check "자동 해소가 꺼진 천장의 90% 에서 같은 B4 id 가 다시 발행된다" \
  "$(boundary_rows B4 | tail -1 | tr '|' '\n' | sed -n 's/^ *승인 id=//p' | sed 's/[[:space:]]*$//')" "$b4_id"
check "그 B4 는 대기로 열린다" "$(gate_approval_state "$b4_id")" "대기"
CC_CMDS_AUTOPILOT_AUTO_RESOLVE=1
for b4_usd in 40 44 48; do
  gate_append 'cost' "누적 usd=$b4_usd"
  gate_boundaries 2>/dev/null
  check "천장의 $((b4_usd * 100 / 40))% 인 B4 는 자동 해소되지 않고 대기로 남는다" "$(gate_approval_state "$b4_id")" "대기"
  check "천장의 $((b4_usd * 100 / 40))% 에서 자동 해소 행이 늘지 않는다" "$(b4_auto_rows)" "1"
done
gate_boundaries 2>/dev/null
check "경계 판정의 열린 승인 스윕도 천장 이상의 B4 를 닫지 않는다" "$(gate_approval_state "$b4_id")" "대기"
check "그 B4 는 대기 중인 승인으로 드러난다" \
  "$(gate_pending_approval_ids act | { grep -F "$b4_id" || true; } | gate_count)" "1"

# A ROW THAT QUOTES THIS ID IS NOT THIS ID'S ROW. A closed approval whose
# question names the waiting B4 is appended after it; the state reader and the
# guard inside the lock must both still take the B4's own `대기` row as its last,
# or the close below is refused on another approval's state.
gate_append '승인' "승인 id=B9-decoy" "상태=승인" "질문 문면=승인 id=$b4_id 을 인용한 질문" \
  "답변 문면=트랜스크립트 판독" "해소 시각=2026-01-01T00:00:00Z" "응답 토큰=t" "답변 다이제스트=-" \
  "사이드카 앵커=-"
check "다른 승인의 질문 문면이 이 id 를 인용해도 상태는 이 id 의 마지막 행에서 읽힌다" \
  "$(gate_approval_state "$b4_id")" "대기"

# THE TRANSITION GUARD, positive half: a close on an approval that is still
# `대기` is written. This also takes the B4 above out of the pending set.
b4_n=$(boundary_rows B4 | gate_count)
b4_rc=0
gate_append '승인' --transition "$b4_id" '대기 철회' 0 "승인 id=$b4_id" "상태=거부" "질문 문면=q" \
  "답변 문면=트랜스크립트 판독" "해소 시각=2026-01-01T00:00:00Z" "응답 토큰=t" "답변 다이제스트=-" \
  "사이드카 앵커=-" || b4_rc=$?
check "대기인 승인에 대한 전이 가드 닫기는 쓰인다" "$b4_rc" "0"
check "그 닫기가 행 하나를 더한다" "$(boundary_rows B4 | gate_count)" "$((b4_n + 1))"
MANIFEST="$B4_MANIFEST_SAVE"
CC_CMDS_AUTOPILOT_AUTO_RESOLVE=0

# A `대기` a person already answered is not auto-resolved. Free input leaves the
# approval `대기` with `처분 사유` on its last row; closing it with the
# recommendation replaced the person's words and then refused their real answer.
# The stagnation is made a real recurrence first (the digest moves away and
# comes back), so the id it fires under is not held quiet by an earlier answer.
b1_recur
gate_b1_stagnation 2>/dev/null
b1_id=$(boundary_rows B1 | tail -1 | tr '|' '\n' | sed -n 's/^ *승인 id=//p' | sed 's/[[:space:]]*$//')
check "수동 모드에서 B1 대기가 다시 열린다 (자유 입력 픽스처)" "$(gate_approval_state "$b1_id")" "대기"
gate_append '승인' "승인 id=$b1_id" "상태=대기" "대상=-" "절단점=경계" "막는 세그먼트=-" \
  "질문 문면=q" "처분 사유=자유 입력" "응답 토큰=t-free" "사이드카 앵커=-" "관측 시각=2026-01-01T00:00:00Z"
b1_auto_n=$(boundary_rows B1 | { grep -F '처분 사유=자동 해소' || true; } | gate_count)
b1_n=$(boundary_rows B1 | gate_count)
CC_CMDS_AUTOPILOT_AUTO_RESOLVE=1
gate_boundaries 2>/dev/null
check "자유 입력으로 답한 대기 B1 은 경계 스윕이 닫지 않는다" "$(gate_approval_state "$b1_id")" "대기"
gate_issue_boundary_approval B1 "q" "$(gate_progress_digest)" 2>/dev/null
check "같은 B1 이 다시 발동해도 자유 입력 대기는 자동 해소되지 않는다" "$(gate_approval_state "$b1_id")" "대기"
check "자유 입력 대기에 자동 해소 행이 붙지 않는다" \
  "$(boundary_rows B1 | { grep -F '처분 사유=자동 해소' || true; } | gate_count)" "$b1_auto_n"
b1_rc=0
gate_auto_close_approval "$b1_id" 승인 "q" "계속" 2>/dev/null || b1_rc=$?
check "자동 마감을 직접 불러도 사람이 답한 대기는 가드가 거부한다" "$([ "$b1_rc" != "0" ] && printf refused || printf written)" "refused"
check "거부된 자동 마감은 행을 더하지 않는다" "$(boundary_rows B1 | gate_count)" "$b1_n"
CC_CMDS_AUTOPILOT_AUTO_RESOLVE=0

# THE TRANSITION GUARD, refusing half: once the last row is no longer `대기`,
# neither an auto-close nor a person's close may append another closing row —
# the last row would otherwise win and a `거부` could land under a `승인`.
gate_append '승인' "승인 id=$b1_id" "상태=승인" "질문 문면=q" "답변 문면=트랜스크립트 판독" \
  "해소 시각=2026-01-01T00:00:00Z" "응답 토큰=t" "답변 다이제스트=-" "사이드카 앵커=-"
b1_n=$(boundary_rows B1 | gate_count)
b1_rc=0
gate_auto_close_approval "$b1_id" 승인 "q" "계속" 2>/dev/null || b1_rc=$?
check "이미 승인인 id 에 자동 마감을 부르면 비영으로 돌아온다" "$([ "$b1_rc" != "0" ] && printf refused || printf written)" "refused"
check "그 자동 마감은 행을 더하지 않는다" "$(boundary_rows B1 | gate_count)" "$b1_n"
b1_rc=0
( gate_append '승인' --transition "$b1_id" '대기 철회' 0 "승인 id=$b1_id" "상태=거부" "질문 문면=q" \
    "답변 문면=트랜스크립트 판독" "해소 시각=2026-01-01T00:00:00Z" "응답 토큰=t2" \
    "답변 다이제스트=-" "사이드카 앵커=-" || gate_close_lost "$b1_id" ) 2>/dev/null || b1_rc=$?
check "그 사이 닫힌 승인에 사람의 닫기가 쓰려 하면 실패로 드러난다" "$([ "$b1_rc" != "0" ] && printf died || printf written)" "died"
check "사람의 닫기가 먼저 닫힌 승인을 덮어쓰지 않는다" "$(gate_approval_state "$b1_id")" "승인"
check "실패한 사람의 닫기도 행을 더하지 않는다" "$(boundary_rows B1 | gate_count)" "$b1_n"

LEDGER="$LEDGER_SAVE"

# ---------------------------------------------------------------------------
# 8d. The cost ceiling's second threshold ENDS the run, and an unreadable
#     ceiling is not a ceiling
#
# 80% opens a boundary approval — a person, if there is one, decides. 100% ends
# the run, and it has to: an approval nobody answers is not a bound, and the
# state this targets is the one where nobody is awake to be asked.
#
# The figure check is asserted as a table rather than through the boundary,
# because the boundary's silence on a bad value is exactly what it used to do
# and a run cannot tell that silence from "not yet at the threshold".
# ---------------------------------------------------------------------------
check "숫자만 있는 천장은 값으로 읽힌다" "$(gate_cost_figure_ok 100 && printf yes || printf no)" "yes"
check "소수점 하나는 값으로 읽힌다" "$(gate_cost_figure_ok 12.5 && printf yes || printf no)" "yes"
check "통화 기호가 붙으면 값이 아니다" "$(gate_cost_figure_ok '$50' && printf yes || printf no)" "no"
check "단위가 뒤에 붙으면 값이 아니다 (앞자리가 숫자여도)" "$(gate_cost_figure_ok '50 USD' && printf yes || printf no)" "no"
check "한글이 섞이면 값이 아니다" "$(gate_cost_figure_ok '약 50' && printf yes || printf no)" "no"
check "소수점이 둘이면 값이 아니다" "$(gate_cost_figure_ok '1.2.3' && printf yes || printf no)" "no"
check "소수점으로 끝나면 값이 아니다" "$(gate_cost_figure_ok '50.' && printf yes || printf no)" "no"
check "빈 값은 값이 아니다" "$(gate_cost_figure_ok '' && printf yes || printf no)" "no"

ELEDGER="$WORK/endrun.md"
LEDGER_SAVE="$LEDGER"
LEDGER="$ELEDGER"
: > "$ELEDGER"
RUN_DIR="$WORK/rundir-endrun"; mkdir -p "$RUN_DIR"
end_rows() { { grep -F '`자율 승인`' "$ELEDGER" || true; } | { grep -cF '결정=종료' || true; }; }
# The ceiling is 100 — appended to `## 인가` above, which is the manifest's last
# section — so the spend in each row below IS the percentage.
printf -- '- `cost` | 누적 usd=95 | 스테이지 수=1 | 관측 시각=2026-01-01T06:00:00Z | prev=z\n' >> "$ELEDGER"
gate_b4_cost >/dev/null 2>&1
check "95% 는 런을 끝내지 않는다 (아래 단언이 공허하지 않다)" "$(end_rows)" "0"
check "95% 에서는 종단 표시도 없다" "$([ -s "$RUN_DIR/done" ] && printf yes || printf no)" "no"
printf -- '- `cost` | 누적 usd=100 | 스테이지 수=1 | 관측 시각=2026-01-01T06:10:00Z | prev=z\n' >> "$ELEDGER"
gate_b4_cost >/dev/null 2>&1
check "천장에 닿으면 런이 끝난다 (종료 행 하나)" "$(end_rows)" "1"
check "그때 종단 표시가 남는다" "$([ -s "$RUN_DIR/done" ] && printf yes || printf no)" "yes"
check "종료 행이 어느 경계였는지 이름으로 말한다" \
  "$({ grep -F '결정=종료' "$ELEDGER" || true; } | { grep -c '기준=B4' || true; })" "1"
# IDEMPOTENT BY THE MARK. A second evaluation past the ceiling must not write a
# second ending row: the first reason is the morning's account of why the night
# stopped, and a run does not end twice.
gate_b4_cost >/dev/null 2>&1
check "천장을 넘긴 두 번째 판정은 종료 행을 다시 쓰지 않는다" "$(end_rows)" "1"

# WHAT THE ENDING GATES. Dispatch and merge and nothing else — a stage in
# flight runs to completion and is classified normally, and the run may still
# record rows, close approvals and propose that it is done. An ending that
# stopped everything would strand the run instead of ending it, and the run
# could not record that it had ended: the snapshot would render it in flight
# forever and the watcher would never reap itself.
er_rc=0; gate_run_ended_ok skill 커밋 >/dev/null 2>&1 || er_rc=$?
check "종단한 런은 새 스테이지 파견을 거절한다" "$er_rc" "$GATE_EXIT_RULE"
er_rc=0; gate_run_ended_ok act 머지 >/dev/null 2>&1 || er_rc=$?
check "종단한 런은 머지를 거절한다" "$er_rc" "$GATE_EXIT_RULE"
er_rc=0; gate_run_ended_ok act 커밋 >/dev/null 2>&1 || er_rc=$?
check "종단한 런도 머지 아래 행위는 지나간다" "$er_rc" "0"
er_rc=0; gate_run_ended_ok propose-done 머지 >/dev/null 2>&1 || er_rc=$?
check "종단한 런도 종료 제안은 지나간다 (제안 뒤에 행위가 없다)" "$er_rc" "0"
# THE MARK IS A CACHE AND THE LEDGER ROW IS THE AUTHORITY. The run directory is
# volatile — a reaper, a temp sweep or a hand `rm -rf` takes it — so a predicate
# that read only the mark would answer "not ended" for a run that had ended, and
# the end would not be a refusal but a state the next gate call silently
# repaired.
rm -f "$RUN_DIR/done"
er_rc=0; er_out=$(gate_run_ended_ok skill 커밋 2>&1) || er_rc=$?
check "종단 표시가 수거돼도 원장 종료 행이 그 런을 막는다" "$er_rc" "$GATE_EXIT_RULE"
case "$er_out" in
  *B4*) ok "그 거절이 어느 경계였는지 원장에서 되살린다" ;;
  *) bad "종단 사유 복원" "원장 행에서 경계 이름을 되살리지 못했다: $er_out" ;;
esac
# THE 100% ARM SITS BEFORE THE RE-ASK SUPPRESSION. A granted B4 records the
# share it was answered at and suppresses the question for the next ten points;
# if ending were downstream of that, one grant at 95% would switch the bound off
# through 105% and beyond.
rm -f "$RUN_DIR/done"
: > "$ELEDGER"
printf '95\n' > "$RUN_DIR/cost-resolved-pct"
printf -- '- `cost` | 누적 usd=101 | 스테이지 수=1 | 관측 시각=2026-01-01T06:20:00Z | prev=z\n' >> "$ELEDGER"
gate_b4_cost >/dev/null 2>&1
check "95% 에서 답을 받아 둔 런도 천장에 닿으면 끝난다 (억제가 종료를 가리지 않는다)" "$(end_rows)" "1"
rm -f "$RUN_DIR/cost-resolved-pct"
LEDGER="$LEDGER_SAVE"

# ---------------------------------------------------------------------------
# 9. With auto-resolution on, a judgment approval does not wait
#
# Driven through the CLI, on a run of its own: the R1 ledger above carries a
# deliberately broken row, and an act on it would test the damage handling
# rather than the approval. An unattended run has nobody to answer, so the
# router's own recommendation is adopted and the ledger says so — the issue row
# stays, and the close row carries `처분 사유=자동 해소`.
#
# Adoption needs a class that may be adopted: inside the judgment vocabulary and
# not one of the two that hand risk to the user. A judgment with no class, a
# class outside the vocabulary, or one of those two does not wait either — it
# ends as a refusal.
# ---------------------------------------------------------------------------
J_MANIFEST="$WT/plan-r2.md"
J_LEDGER="$WT/docs/pipeline-run/R2.md"
sed 's/R1/R2/g' "$FIX_MANIFEST" > "$J_MANIFEST"
sed 's/R1/R2/g' "$WT/docs/pipeline-grant/R1.md" > "$WT/docs/pipeline-grant/R2.md"
jH() { ( cd "$WT" && bash "$GATE" snapshot --manifest "$J_MANIFEST" 2>/dev/null ) | jq -r .H; }
jact() {
  ( cd "$WT" && bash "$GATE" act --manifest "$J_MANIFEST" --kind judgment --target repo \
      --cutpoint 커밋 --surface 읽기 --snapshot-digest "$(jH)" --rationale x -- "$@" ) \
    >/dev/null 2>&1
}
j_rows() { { grep -E "^- \`$1\`" "$J_LEDGER" || true; } | { grep -F "$2" || true; }; }
j_field() { printf '%s\n' "$1" | tr '|' '\n' | sed -n "s/^ *$2=//p" | sed 's/[[:space:]]*$//' | tail -1; }

CC_CMDS_AUTOPILOT_AUTO_RESOLVE=0
jact 등급=2 기준="리뷰 스테이지를 몇 개로 나눌지" 근거="비용과 커버리지가 상충한다"
check "수동 모드에서 등급 2 판단은 승인 대기로 응답한다" "$?" "5"

CC_CMDS_AUTOPILOT_AUTO_RESOLVE=1
jact 등급=2 "판단 부류=감사-발견" 기준="밤사이 리뷰 라운드를 줄일지" 근거="사람 없이 끝까지 가야 한다"
check "자동 해소가 켜지면 채택 가능 부류의 등급 2 판단이 승인 대기 없이 채택된다" "$?" "0"
auto_row=$(j_rows '승인' '처분 사유=자동 해소' | tail -1)
check "자동 해소 행은 상태=승인 이다" "$(j_field "$auto_row" '상태')" "승인"
check "자동 해소 행은 응답 토큰이 없다 (사람의 답과 구별된다)" "$(j_field "$auto_row" '응답 토큰')" "-"
auto_ap=$(j_field "$auto_row" '승인 id')
check "채택 행이 자동 해소한 승인 id 를 해소 승인으로 싣는다" \
  "$(j_rows '자율 승인' "| 해소 승인=$auto_ap |" | gate_count)" "1"

# A grade-2 judgment with no class names nothing to adopt, so auto-resolution
# closes it as a refusal — the floor does not demand the class at grade 2, and
# this is the only place that keeps a classless judgment from being adopted.
jact 등급=2 기준="검증 라운드를 건너뛸지" 근거="시간이 부족하다"
check "부류 없는 등급 2 판단은 자동 해소가 채택하지 않고 거절로 끝난다" "$?" "3"
noclass_row=$(j_rows '승인' '처분 사유=자동 해소' | tail -1)
check "그 자동 해소 행은 상태=거부 이다" "$(j_field "$noclass_row" '상태')" "거부"
check "부류 없는 판단의 승인 id 로 채택 행이 쓰이지 않는다" \
  "$(j_rows '자율 승인' "| 해소 승인=$(j_field "$noclass_row" '승인 id') |" | gate_count)" "0"

# The floor does not read the class vocabulary at grade 2 either, so an
# out-of-vocabulary class is closed by the same allow list. The value has to be
# outside the vocabulary for this to mean anything, and the vocabulary lint
# requires every literal class in the tree to be inside it — so the value goes
# through a variable, which that lint reads as a shell expansion. A file-wide
# self-skip would also switch off the check on this file's real class literals.
bad_cls=없는-부류
jact 등급=2 "판단 부류=$bad_cls" 기준="커밋을 합칠지" 근거="이력이 길다"
check "어휘 밖 부류의 등급 2 판단은 자동 해소가 거절로 닫는다" "$?" "3"

# The judgment left pending above, resubmitted with a class that may be adopted,
# is resolved the same way — a run already carrying an open question picks the
# auto-resolution up. The approval id derives from the standard and rationale
# alone, so this is the same question.
jact 등급=2 "판단 부류=감사-발견" 기준="리뷰 스테이지를 몇 개로 나눌지" 근거="비용과 커버리지가 상충한다"
check "이미 대기 중이던 판단 승인도 재제출 때 자동 해소되어 채택된다" "$?" "0"

# A pending judgment resubmitted still without a class is refused on that
# resubmission, not adopted.
CC_CMDS_AUTOPILOT_AUTO_RESOLVE=0
jact 등급=2 기준="픽스처를 다시 만들지" 근거="오래된 픽스처가 있다"
check "수동 모드에서 부류 없는 판단이 대기로 열린다" "$?" "5"
CC_CMDS_AUTOPILOT_AUTO_RESOLVE=1
jact 등급=2 기준="픽스처를 다시 만들지" 근거="오래된 픽스처가 있다"
check "대기 중이던 부류 없는 판단은 재제출 때 자동 해소가 거절로 닫는다" "$?" "3"

# The two classes that hand risk to the user are resolved as a refusal: the run
# still does not wait, and it does not take the risk on anyone's behalf.
jact 등급=2 "판단 부류=팀-구성" 기준="팀을 소집할지" 근거="발견이 많다"
check "사용자에게 위험을 넘기는 부류는 대기 대신 거절로 끝난다" "$?" "3"
check "그 자동 해소 행은 상태=거부 이다" \
  "$(j_field "$(j_rows '승인' '처분 사유=자동 해소' | tail -1)" '상태')" "거부"
check "대기 중인 판단 승인이 남지 않는다" \
  "$( ( cd "$WT" && bash "$GATE" snapshot --manifest "$J_MANIFEST" 2>/dev/null ) | jq -r .pending_approvals_total)" "0"

# THE FORBIDDEN CHECK IS AN ALLOW LIST, so spellings that merely resemble a
# forbidden class are refused too: no separator, another separator, and a value
# carrying a space. Through variables for the same vocabulary-lint reason as
# `bad_cls` above.
var_cls_a=팀구성
var_cls_b=팀_구성
var_cls_c="스테이지-재시도 팀-구성"
var_n=0
for var_cls in "$var_cls_a" "$var_cls_b" "$var_cls_c"; do
  var_n=$((var_n + 1))
  jact 등급=2 "판단 부류=$var_cls" 기준="철자 변형 $var_n 을 채택할지" 근거="부류 문면이 어휘와 다르다"
  check "부류 철자 변형 $var_n 의 등급 2 판단은 자동 해소가 거절로 닫는다" "$?" "3"
  var_row=$(j_rows '승인' '처분 사유=자동 해소' | tail -1)
  check "철자 변형 $var_n 의 자동 해소 행은 상태=거부 이다" "$(j_field "$var_row" '상태')" "거부"
  check "철자 변형 $var_n 의 승인 id 로 채택 행이 쓰이지 않는다" \
    "$(j_rows '자율 승인' "| 해소 승인=$(j_field "$var_row" '승인 id') |" | gate_count)" "0"
done

# A `대기` judgment a person answered with free input is not closed by a
# resubmission. The free-input row is appended in-process against this run's
# ledger, in the shape `close` writes it.
CC_CMDS_AUTOPILOT_AUTO_RESOLVE=0
jact 등급=2 기준="자유 입력으로 답한 물음" 근거="사람이 라벨 밖의 말로 답했다"
check "수동 모드에서 자유 입력 픽스처 판단이 대기로 열린다" "$?" "5"
free_id=$(j_field "$(j_rows '승인' '자유 입력으로 답한 물음' | tail -1)" '승인 id')
J_LEDGER_SAVE="$LEDGER"
LEDGER="$J_LEDGER"
gate_append '승인' "승인 id=$free_id" "상태=대기" "대상=repo" "절단점=판단" "막는 세그먼트=-" \
  "질문 문면=q" "처분 사유=자유 입력" "응답 토큰=t-free" "사이드카 앵커=-" "관측 시각=2026-01-01T00:00:00Z"
LEDGER="$J_LEDGER_SAVE"
CC_CMDS_AUTOPILOT_AUTO_RESOLVE=1
jact 등급=2 "판단 부류=감사-발견" 기준="자유 입력으로 답한 물음" 근거="사람이 라벨 밖의 말로 답했다"
check "자유 입력으로 답한 대기 판단은 재제출해도 자동 해소되지 않는다 (승인 대기 유지)" "$?" "5"
check "그 승인의 마지막 행은 여전히 대기다" \
  "$(j_field "$(j_rows '승인' "| 승인 id=$free_id |" | tail -1)" '상태')" "대기"
check "그 승인에 자동 해소 행이 붙지 않는다" \
  "$(j_rows '승인' "| 승인 id=$free_id |" | { grep -F '처분 사유=자동 해소' || true; } | gate_count)" "0"

# AN ID QUOTED IN ANOTHER JUDGMENT'S TEXT DOES NOT SPEAK FOR THAT ID. A router
# citing its own earlier decision puts `승인 id=<id>` into `기준`, and the gate
# carries it into the question on both the issue row and the closing row. Read
# as a substring, the adoptable judgment's `승인` close became the last row of
# the refused judgment it quoted, and resubmitting that refused judgment adopted
# a class that hands risk to the user with nobody asked.
jact 등급=2 "판단 부류=팀-구성" 기준="위장 대상이 되는 판단" 근거="사용자에게 넘길 위험이다"
check "인용될 판단(위험을 넘기는 부류)은 자동 해소가 거절로 닫는다" "$?" "3"
cite_id=$(j_field "$(j_rows '승인' '위장 대상이 되는 판단' | tail -1)" '승인 id')
check "인용될 판단의 승인 id 가 원장에 있다" "$([ -n "$cite_id" ] && printf yes || printf no)" "yes"
jact 등급=2 "판단 부류=감사-발견" 기준="승인 id=$cite_id 참고" 근거="앞선 결정을 인용한다"
check "다른 판단의 id 를 기준에 담은 채택 가능 부류의 판단은 채택된다" "$?" "0"
check "그 판단의 발행 행과 닫는 행이 인용된 id 를 질문 문면에 싣는다 (시험이 공허하지 않다)" \
  "$(j_rows '승인' "승인 id=$cite_id 참고" | gate_count)" "2"
jact 등급=2 "판단 부류=팀-구성" 기준="위장 대상이 되는 판단" 근거="사용자에게 넘길 위험이다"
check "인용된 판단을 재제출해도 채택되지 않는다 (남의 닫는 행을 제 마지막 행으로 읽지 않는다)" "$?" "3"
check "인용된 id 를 해소 승인으로 싣는 자율 승인 행이 없다" \
  "$(j_rows '자율 승인' "| 해소 승인=$cite_id |" | gate_count)" "0"
check "인용된 판단의 마지막 행은 거부 그대로다" \
  "$(j_field "$(j_rows '승인' "| 승인 id=$cite_id |" | tail -1)" '상태')" "거부"
CC_CMDS_AUTOPILOT_AUTO_RESOLVE=0

# ---------------------------------------------------------------------------
# 10. The two counters, over two different sets — and they are no longer even
#     the same quantity
#
# They were never the same question. The terminal-act budget asks "how much has
# this run spent", and an act the grading table could not read spends exactly as
# much as a readable one, so `등급 미상` is inside that set. Progress asks "did
# anything MOVE", and an above-read exec is not movement at all — the vector
# counts dispatches that left an observed outcome, so NO exec row moves it,
# whatever its grade. That is why only the budget still has a `축2` selector for
# an excerpt to fool, and it is anchored on ` | 축2=… | ` rather than on a
# substring: the exec row now carries an `argv=` excerpt, and an excerpt holding
# the text `축2=읽기` used to drop a row whose own grade is a write out of the
# budget.
#
# THE ROWS CARRY A SEAT. The budget is the ROUTER's, so a row with no `행위자`
# contributes nothing and one seated at `스테이지` is filtered out — both are
# asserted on their own elsewhere. Here the seat is present and unconstrained so
# that the grade axis is the only thing being measured.
# ---------------------------------------------------------------------------
CNT_DIR=$(mktemp -d "${TMPDIR:-/tmp}/cc-snap-counters.XXXXXX")
CNT_LEDGER="$CNT_DIR/ledger.md"
: > "$CNT_LEDGER"
cnt_row() {   # cnt_row <축2 값> [추가 필드]
  printf -- '- `자율 승인` | 교대=0 | kind= | 결정=exec | 대상=t | 세그먼트=S | 절단점=커밋 | 유도 절단점=- | 축2=%s | 자격=주변 | 행위자=리드 | %s근거=x | prev=0\n' \
    "$1" "${2:+$2 | }" >> "$CNT_LEDGER"
}
cnt_read() {  # cnt_read <dispatches|b3>
  CC_GATE_SOURCE_ONLY=1 bash -c '
    . "$1" >/dev/null 2>&1; set +e +u
    LEDGER="$2"; MANIFEST=/nonexistent; RUN_ID=R; RUN_DIR="$3"
    if [ "$4" = "dispatches" ]; then
      gate_progress_vector 2>/dev/null | sed -n "s/^dispatches=//p"
    else
      gate_b3_exec_total 2>/dev/null
    fi' _ "$GATE" "$CNT_LEDGER" "$CNT_DIR" "$1"
}
check "빈 원장의 진전 계수는 0 이다" "$(cnt_read dispatches)" "0"
cnt_row '등급 미상'
check "등급 미상 행은 진전으로 세지 않는다" "$(cnt_read dispatches)" "0"
check "등급 미상 행도 행위 예산은 쓴다"     "$(cnt_read b3)"         "1"
cnt_row '읽기'
check "읽기 행은 둘 다 세지 않는다 (진전)"  "$(cnt_read dispatches)" "0"
check "읽기 행은 둘 다 세지 않는다 (예산)"  "$(cnt_read b3)"         "1"
cnt_row '워크트리쓰기' 'argv=echo 축2=읽기'
check "발췌에 축2=읽기 가 있어도 쓰기 행은 예산을 쓴다" "$(cnt_read b3)"         "2"
check "그래도 그 쓰기 행은 진전이 아니다"               "$(cnt_read dispatches)" "0"
cnt_row '외부상태변경'
check "외부 상태 변경도 예산을 쓴다"   "$(cnt_read b3)"         "3"
check "외부 상태 변경도 진전이 아니다" "$(cnt_read dispatches)" "0"
rm -rf "$CNT_DIR"

printf '\ntest-snapshot: %d passed, %d failed\n' "$passed" "$failed"
[ "$failed" = "0" ]
