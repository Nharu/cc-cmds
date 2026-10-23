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
# The dashboard server is off for the same reason: the gate's run-open branch
# starts one, and nothing in this suite stops it.
CC_CMDS_DASHBOARD=off
export CC_CMDS_DASHBOARD
# Auto-resolution is off except in the section that tests it, so the approval
# fixtures above it stay pending the way they are written.
CC_CMDS_AUTOPILOT_AUTO_RESOLVE=0
export CC_CMDS_AUTOPILOT_AUTO_RESOLVE
# The fixture runs open with this repository's gate and take a version pin.
# Without the sync seam that pin fetches the real `origin` and, on any branch
# but the base, pins the remote tip — so every snapshot assertion would test
# the base branch's gate instead of the checkout under test.
CC_GATE_PIN_SYNC_DISABLE=1
export CC_GATE_PIN_SYNC_DISABLE


script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
GATE="$repo_root/plugins/cc-cmds/orchestrator/gate.sh"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/cc-snapshot-test.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
export XDG_STATE_HOME="$WORK/state"
# The config root the account inventory is read under is moved off the host's,
# so the fixture run opens unrouted whatever this machine has.
export XDG_CONFIG_HOME="$WORK/config"

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

# A run with no stage waiting for an account carries the key with an empty list,
# and the key adds nothing to `H` beyond the ledger it already hashes.
w0=$(cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null)
check "대기자가 없는 런의 스냅숏은 빈 waiting_stages 를 싣는다" "$(printf '%s' "$w0" | jq -c .waiting_stages)" "[]"
check "빈 waiting_stages 가 있어도 H 는 직접 잰 스냅숏 다이제스트다" "$(printf '%s' "$w0" | jq -r .H)" "$(snapdigest)"

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

# `answered_by` says who chose the option, and a row written before `답한 주체`
# existed is read by its `근거`: the shift's pre-adopted prefix is `교대`, any
# other row a person's. An answer is not progress, whoever gave it.
printf -- '- `중단 답` | 세그먼트=S2 | 중단 기록=/x/halt/S2.md | 스킬=design-reconverge | 선택지=reject | 답한 주체=좌석 | 근거=기록의 추천 | 근거 종류=상시 지침\n' >> "$LEDGER"
printf -- '- `중단 답` | 세그먼트=S3 | 중단 기록=/x/halt/S3.md | 스킬=implement-unattended | 선택지=재수렴 | 근거=자동 채택(구속-이탈) — 매니페스트가 미리 정한 답\n' >> "$LEDGER"
printf -- '- `중단 답` | 세그먼트=S4 | 중단 기록=/x/halt/S4.md | 스킬=design-audit-unattended | 선택지=reject | 근거=사람이 기각\n' >> "$LEDGER"
ah=$(cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null | jq -c '[.answered_halts[] | [.segment, .answered_by]]')
check "스냅숏의 answered_by 는 답한 주체를 읽고, 옛 행은 근거의 접두로 가른다" "$ah" '[["S2","좌석"],["S3","교대"],["S4","사람"]]'
check "중단 답 행은 진전이 아니다" "$(digest)" "$d0"

# `route` and `route_refusal` are the gate's verdict on the answer as it reads
# the record now, and they stay out of `H`: the record appearing turns the
# element from no verdict into a refusal while the digest a router carries
# still matches.
RT_REC="$WORK/halt/S9#1.md"
printf -- '- `중단 답` | 세그먼트=S9 | 중단 기록=%s | 스킬=implement-unattended | 선택지=보류 | 답한 주체=사람 | 근거=사람이 보류\n' "$RT_REC" >> "$LEDGER"
rt_el() {  # rt_el — S9's answered_halts element as route|route_refusal
  (cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null) \
    | jq -r '[.answered_halts[] | select(.segment == "S9") | "\(.route)|\(.route_refusal)"] | last // "없음"'
}
rt_h1=$(snapdigest)
check "기록 파일이 없는 답의 route 와 route_refusal 은 비어 있다" "$(rt_el)" "|"
mkdir -p "$WORK/halt"
printf '%s\n' '<!-- cc-pipeline-halt v1; writer=implement-unattended; reader=orchestrator; stage=S9#1; run=R1 -->' \
  '**스킬**: implement-unattended' '**스텝**: Step 3 — 픽스처' '**선택지**:' '- `보류` — 사람이 정한다' \
  '<!-- /cc-pipeline-halt v1 -->' > "$RT_REC"
check "세션 없는 키의 답은 route_refusal 이 재부착할 세션이 없다고 말한다" "$(rt_el)" \
  "|S9 의 마지막 정산 stage-result 행에 세션 id 가 없어(세션 id=빈 값) 교대가 재부착할 세션이 없습니다"
check "route 판정이 바뀌어도 H 는 움직이지 않는다" "$(snapdigest)" "$rt_h1"
check "그 H 는 스냅숏이 내는 H 와 같다" \
  "$(cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null | jq -r .H)" "$rt_h1"
# `carry_prompt` is the carry act's `-p` text the gate builds from the ledger
# the attempt halted in. The element always carries the field; with no parked
# attempt of the key to build it from it is empty, and it stays out of `H`.
check "answered_halts 원소는 carry_prompt 를 싣고, 멈춘 시도가 없으면 비어 있다" \
  "$( (cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null) \
      | jq -r '[.answered_halts[] | select(.segment == "S9") | (has("carry_prompt") | tostring) + "|" + .carry_prompt] | last // "없음"')" \
  "true|"
check "carry_prompt 를 실어도 H 는 움직이지 않는다" "$(snapdigest)" "$rt_h1"

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

# OPENING AN OBLIGATION IS NOT PROGRESS, and it used to be. The vector carried
# the open set, so a new problem row moved this digest — and once obligations
# could be closed, opening one and closing it again reset the stagnation count
# for two `읽기` rows while another obligation stayed blocked. Obligation progress
# is B2's to judge; the two sensitivity assertions above are what keep this one
# from passing on a constant.
printf -- '- `problem` | 세그먼트=S1 | 동일성=P0-누수 | 시각=2026-01-01T03:00:00Z\n' >> "$LEDGER"
d3=$(digest)
check "새 동일성의 문제 행은 진전이 아니다 (여닫이로 정체 계수를 되돌리지 못한다)" "$d3" "$d2"

# A repeat of the SAME identity is not new information either, so a stage
# retrying the same failure all night cannot pass for progress.
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

# `외부 종료` IS ITS OWN CASE, not a reading of the one above. It comes from a
# different writer — the gate's prelude settling a lost dispatch — and it
# carries `종료 코드=-` rather than a number, so a selector that took "not a
# crash" or "no failing code" as progress would move on exactly this row.
printf -- '- `stage-result` | 세그먼트=SN7 | 스테이지=SN7 | 종류=implement | 종료 코드=- | 부모=- | 종단 부류=외부 종료 | 관측=픽스처\n' >> "$LEDGER"
check "외부 종료는 진전이 아니다 (정산 행은 다이제스트를 움직이지 않는다)" "$(digest)" "$sn3"

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

# THE PACE BLOCK SITS BESIDE `shift`, AND `H` STAYS LAST. It is read from the
# pacing sensor's state file and never computed here, so on a host with no
# sensor under this suite's state root it is `null` with the reason beside it.
# The key order is a contract: the router reads the object positionally through
# `--fields`, and the default projection below is the list the hook prescribes.
check "pace 블록이 shift 바로 뒤에 온다" \
  "$(jq -r 'keys_unsorted | (index("pace") - index("shift"))' "$WORK/s1.json")" "1"
check "H 는 스냅숏의 마지막 키다" "$(jq -r 'keys_unsorted | last' "$WORK/s1.json")" "H"
check "센서가 없는 상태 루트에서 pace 는 null 이다" "$(jq -c .pace "$WORK/s1.json")" "null"
check "그 부재의 사유가 곁에 실린다" "$(jq -r .pace_absent_reason "$WORK/s1.json")" "센서 미등록"
check "--fields 의 기본 목록은 라우터가 읽는 여덟 필드를 그 순서로 낸다" \
  "$(cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" --fields 2>/dev/null | jq -r 'keys_unsorted | join(",")')" \
  "H,disposition,unmet_conditions_total,pending_approvals_total,live_stages,waiting_stages,shift,pace"
check "대기자가 없으면 waiting_stages 는 행이 쌓여도 빈 배열이다" "$(jq -c .waiting_stages "$WORK/s1.json")" "[]"
# The target-hook refusals the router reads before a remote act: an array even
# when no target hook ever refused, so `length` never meets a null.
check "대상 훅 거절이 없으면 guard_refusals 는 빈 배열이다" "$(jq -c .guard_refusals "$WORK/s1.json")" "[]"
check "segments[] 의 원소는 원격 상태 필드를 싣는다" \
  "$(jq -r '[.segments[] | has("브랜치") and has("HEAD") and has("원격 팁") and has("PR") and has("원격 단계") and has("리뷰 줄")] | if length == 0 then "원소 없음" else all | tostring end' "$WORK/s1.json")" "true"
# `적용` is always one of three words, never null: the router branches on it
# right after a merge, and an absent key would read as neither.
check "segments[] 의 원소는 적용 을 세 값 중 하나로 싣는다" \
  "$(jq -r '[.segments[] | (.["적용"] // "null") | IN("대기", "인계", "없음")] | if length == 0 then "원소 없음" else all | tostring end' "$WORK/s1.json")" "true"
# THE CONE AND REPLAN ARRAYS ARE ALWAYS PRESENT, right after `blocked`, and stay
# out of the default projection: the router asks for them by name, and a key that
# appeared only when it had elements would read as absent on the ordinary night.
check "cone_blocks 와 replan_due 가 blocked 바로 뒤에 그 순서로 온다" \
  "$(jq -r 'keys_unsorted | "\(index("cone_blocks") - index("blocked")),\(index("replan_due") - index("blocked"))"' "$WORK/s1.json")" "1,2"
check "막힘·재계획이 없으면 둘 다 빈 배열이다" \
  "$(jq -c '[.cone_blocks, .replan_due]' "$WORK/s1.json")" "[[],[]]"
check "--fields H 는 스냅숏의 H 를 날값 한 줄로 낸다" \
  "$(cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" --fields H 2>/dev/null)" \
  "$(jq -r .H "$WORK/s1.json")"

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

# A WAIT STARTS WITH A ROW. The first `stage-wait` row is written before the
# dispatch returns, so it changes the ledger's end and a router holding the
# earlier `H` is told its view is stale — and a heartbeat is not progress.
sd_before=$(snapdigest); pd_before=$(digest)
printf -- '- `stage-wait` | 계보=B:S1#2 | 그룹=org:h1 | 계정=- | 까지=- | 근거=concurrency-cap\n' >> "$FIX_LEDGER"
if [ "$(snapdigest)" != "$sd_before" ]; then
  ok "첫 stage-wait 행이 원장 끝을 바꿔 H 를 움직인다"
else
  bad "stage-wait 행" "대기가 시작됐는데 스냅숏 다이제스트가 그대로다"
fi
check "stage-wait 행은 진전 다이제스트를 움직이지 않는다" "$(digest)" "$pd_before"

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
# The class is what tells the router a 사람-결정 wait from an ordinary one, and a
# question raised without one still carries the key, as `-`.
check "대기 승인 항목이 판단 부류를 싣고, 부류 없는 질문은 - 다" \
  "$(jq -r '.pending_approvals[0].class' "$SNAP_U")" "-"

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
check "대기자가 없으면 렌더에 대기 줄이 없다" "$(grep -c '^대기 중인 스테이지:' "$RENDER_U")" "0"

# A STAGE WAITING FOR AN ACCOUNT, in the JSON and in the render. The marker's
# holder is a live process of this suite, so the key is a member; freshness is
# then read from the later of the refresh and the machine's wake, and the wake
# reading is replaced in a subshell so all three cases are this suite's.
RD_R1="$XDG_STATE_HOME/cc-cmds/run/R1"
sleep 600 & W_HOLD=$!
w_now=$(date -u +%s)
w_stall=$(cc_effective_stall "$RD_R1")
# A driver-written marker: the gate's settlement leaves those alone, so killing
# the holder below adds no row to this shared fixture ledger.
printf '%s\n' "보유자=$W_HOLD" "지문=$(cc_proc_fingerprint "$W_HOLD")" "기록자=드라이버" "계보=S9" \
  "그룹=org:h1" "까지=-" "갱신=$((w_now - w_stall - 1))" "종류=review" "논스=-" > "$RD_R1/S9.waiting"
SNAP_W="$WORK/waiting.json"
( cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null ) > "$SNAP_W"
check "살아 있는 보유자의 표지는 waiting_stages 원소 하나다" "$(jq -r '.waiting_stages | length' "$SNAP_W")" "1"
check "그 원소가 키·계보·그룹·보유자·기록자를 싣는다" \
  "$(jq -c '.waiting_stages[0] | [.segment, .lineage, .group, .until, .holder, .writer]' "$SNAP_W")" \
  "[\"S9\",\"S9\",\"org:h1\",null,$W_HOLD,\"드라이버\"]"
( cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" --render 2>/dev/null ) > "$WORK/render-w.txt"
check "렌더가 대기 원소를 키와 보유자로 보인다" \
  "$(grep -c "^대기 중인 스테이지: S9(그룹 org:h1, 까지 -, 보유자 $W_HOLD" "$WORK/render-w.txt")" "1"
w_fresh() {  # w_fresh <wake epoch or empty> — the one element's `fresh`
  ( RUN_DIR="$RD_R1"; LEDGER="$FIX_LEDGER"; W_WAKE="$1"
    wake_epoch() { printf '%s' "$W_WAKE"; }
    printf '[%s]' "$(gate_snapshot_waiting_stages_json)" ) | jq -c '[length, .[0].fresh]'
}
# The wake is read off the clock at the call, not off `w_now`: the snapshots
# above run between the two, and a wake pinned a few seconds inside the window
# at `w_now` falls out of it on a slow runner.
check "갱신이 STALL 보다 오래돼도 깨어남이 그 뒤면 구성원이고 신선하다" "$(w_fresh "$(date -u +%s)")" "[1,true]"
check "깨어남이 그보다 이르면 구성원이고 신선하지 않다" "$(w_fresh "$((w_now - w_stall - 100))")" "[1,false]"
check "깨어남 기록이 없으면 구성원이고 신선하지 않다" "$(w_fresh "")" "[1,false]"
kill -TERM "$W_HOLD" 2>/dev/null; wait "$W_HOLD" 2>/dev/null
check "보유자가 죽으면 표지가 남아도 원소가 빠진다" \
  "$(cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null | jq -r '.waiting_stages | length')" "0"
rm -f "$RD_R1/S9.waiting"

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
#
# The lead's copy of the router loop lives in the autopilot skill's
# references/router-lead-copy.md.
AP_REFS="$repo_root/plugins/cc-cmds/skills/autopilot/references"
AP_ROUTER="$AP_REFS/router-lead-copy.md"
# The shift's copy keeps its rare branch procedures in its own `references/`,
# so it is read as one corpus: the body followed by every reference in glob
# order.
RS_SKILL="$repo_root/plugins/cc-cmds/skills/autopilot-router-shift/SKILL.md"
RS_REFS="$repo_root/plugins/cc-cmds/skills/autopilot-router-shift/references"
RS_CORPUS="$WORK/router-shift-corpus.md"
cat "$RS_SKILL" "$RS_REFS"/*.md > "$RS_CORPUS"
sel_ap=$(grep -oE '\[\.cycles\[\] \| select\(.*// -1\)' "$AP_ROUTER" || true)
sel_rs=$(grep -oE '\[\.cycles\[\] \| select\(.*// -1\)' "$RS_CORPUS" || true)
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
# 6c-2. `review_next[]` carries each unmerged segment's next disposition
#
# The routers branch on `다음` and nothing else, so the snapshot hands it over
# together with what a carry-over act names — the last cycle's number, review
# HEAD and report path. A segment without a `segment` row is not in the run's
# segment set and gets no element; `review_carry` carries the re-implementation
# cycle cap and the re-check round cap for display only. The element has no streak or trigger field: the
# repeated-P0 guard is gone, and a field nothing writes is one a router reads.
# ---------------------------------------------------------------------------
printf -- '- `segment` | id=S8 | 상태=실행중 | 워크트리=/nonexistent/S8\n' >> "$LEDGER"
SNAP_N="$WORK/review-next.json"
( cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null ) > "$SNAP_N"
check "review_next 가 세그먼트의 다음 과 마지막 사이클을 싣는다" \
  "$(jq -r '.review_next[] | select(.["세그먼트"]=="S8") | [.["다음"], .["사이클"], .["리뷰 HEAD"], .["리포트 경로"]] | join("|")' "$SNAP_N")" \
  "머지|11|aaa0011|/abs/s8-11.md"
check "review_next 원소에 가드 필드가 없다" \
  "$(jq -c '.review_next[] | select(.["세그먼트"]=="S8") | keys' "$SNAP_N")" '["다음","리뷰 HEAD","리포트 경로","사이클","세그먼트"]'
check "segment 행이 없는 세그먼트는 review_next 에 오르지 않는다" \
  "$(jq -r '[.review_next[] | select(.["세그먼트"]=="S9")] | length' "$SNAP_N")" "0"
check "review_carry 가 재구현 사이클 상한과 확인 리뷰 회차 상한을 싣는다" \
  "$(jq -c '.review_carry' "$SNAP_N")" '{"REIMPL_CYCLE_CAP":2,"RECHECK_ROUND_CAP":2}'

# 6c-3. Both router copies branch on the six CI values of `다음`
#
# A value one copy does not name is a value its router meets with no branch, and
# a rerun spelled by hand is one the gate refuses in every form. The values the
# CI layer writes, and their element keys, are measured by test-gate.sh's 60b and
# 88d against the gate itself; what is pinned here is that each copy carries the
# branch, the dispatch line and the act, and forbids the hand spelling.
for pair in "리드:$AP_ROUTER" "교대:$RS_CORPUS"; do
  who=${pair%%:*}; f=${pair#*:}
  for lit in \
    '**`CI 재실행`**' \
    '**`CI 대기`**' \
    '**`CI 수정`**' \
    '**`CI 리뷰`**' \
    '**`CI 기존 실패`**' \
    '**`CI 수정 한도`**' \
    'CI 수정: <head sha>' \
    'act --kind ci-rerun' \
    '--kind ci-rerun' \
    '-- 재실행 <head sha>' \
    '**Every other exit 3 is one disposition**' \
    '**Never send `gh run rerun`, a rerun or re-request REST path, or the `rerequestCheckSuite` mutation**'; do
    if grep -qF -- "$lit" "$f"; then
      ok "$who 사본이 CI 갈래 리터럴을 싣는다: $lit"
    else
      bad "$who 사본의 CI 갈래 리터럴" "없다: $lit"
    fi
  done
done

# Both router copies read the design skill from the snapshot as it stands and
# name the `solo-audit` branch of the selection function. A copy that kept the
# two-branch sentence would tell its router a team-4 plan always takes the
# discussion skill, which the gate now refuses on a `solo-audit` plan.
sel_new='`design-solo-unattended` when `design_tier` is `team-4` and `design_path` is `solo-audit`, `design-discuss-unattended` otherwise. Do not pick it again from `design_scope`, `design_tier` or `design_path`:'
sel_old='Do not pick it again from `design_scope` or `design_tier`:'
for pair in "리드:$AP_ROUTER" "교대:$RS_CORPUS"; do
  who=${pair%%:*}; f=${pair#*:}
  check "$who 사본이 solo-audit 갈래의 선택 문장을 한 번 싣는다" "$(grep -cF -- "$sel_new" "$f" || true)" "1"
  check "$who 사본에 두 갈래 옛 선택 문장이 없다" "$(grep -cF -- "$sel_old" "$f" || true)" "0"
done
check "라우터 두 사본의 설계 스킬 선택 줄이 바이트 동일하다" \
  "$(grep -F -- "$sel_new" "$RS_CORPUS")" "$(grep -F -- "$sel_new" "$AP_ROUTER")"

# ---------------------------------------------------------------------------
# 6c-3. `implement_next[]` tells a plan emission from a plan execution
#
# A process A that emits its plan and a process B that carries it out both end
# `정상 완료`, so a router reading only the last stage sent a review onto a
# branch with no commit in it. The element carries what tells them apart: the
# phase (a digest's first appearance after the void boundary is an emission),
# the commits the segment worktree's HEAD has over the base refs, and how many
# implement runs after the boundary left no commit. The worktrees are real, so
# `앞선 커밋` is measured the way the gate measures it on a run.
# ---------------------------------------------------------------------------
( cd "$REPO" \
  && git worktree add -q -b in-zero "$WORK/in-zero" main \
  && git worktree add -q -b in-one "$WORK/in-one" main \
  && git worktree add -q -b in-base "$WORK/in-base" main ) >/dev/null 2>&1
( cd "$WORK/in-one" && echo seg > seg.txt && git add -A && git commit -qm seg ) >/dev/null 2>&1
# The base moves on after `in-base` was cut: that branch is behind, not ahead.
( cd "$REPO" && echo two > b.txt && git add -A && git commit -qm two ) >/dev/null 2>&1
ir() { # ir <segment> <kind> <digest or -> <class>
  if [ "$3" = - ]; then
    printf -- '- `stage-result` | 세그먼트=%s | 스테이지=%s | 종류=%s | 종료 코드=0 | 실행 버전=1 | 종단 부류=%s\n' "$1" "$1" "$2" "$4"
  else
    printf -- '- `stage-result` | 세그먼트=%s | 스테이지=%s | 종류=%s | 종료 코드=0 | 실행 버전=1 | plan_sha256=%s | 종단 부류=%s\n' "$1" "$1" "$2" "$3" "$4"
  fi >> "$LEDGER"
}
iseg() { printf -- '- `segment` | id=%s | 상태=실행중 | 레포=t/t | 워크트리=%s\n' "$1" "$2" >> "$LEDGER"; }
iseg I1 "$WORK/in-zero"; ir I1 implement d1 '정상 완료'
iseg I2 "$WORK/in-zero"; ir I2 implement d2 '정상 완료'; ir I2 implement d2 '정상 완료'
iseg I3 "$WORK/in-zero"; ir I3 implement d3 '정상 완료'; ir I3 implement d3 '정상 완료'; ir I3 implement d3 '정상 완료'
iseg I4 "$WORK/in-one";  ir I4 implement d4 '정상 완료'; ir I4 implement d4 '정상 완료'
iseg I5 "$WORK/in-zero"; ir I5 implement d5 '정상 완료'; ir I5 implement d5 '정상 완료'
ir I5 reconverge - '정상 완료'; ir I5 implement d5b '정상 완료'
iseg I6 "$WORK/in-one";  ir I6 implement d6 '정상 완료'; ir I6 implement d6 '정상 완료'
ir I6 reconverge - '정상 완료'; ir I6 implement d6b '정상 완료'
iseg I7 "$WORK/in-base"; ir I7 implement d7 '정상 완료'
iseg I8 "$WORK/in-gone"; ir I8 implement d8 '정상 완료'
iseg I9 "$WORK/in-zero"; ir I9 implement d9 '정상 완료'; ir I9 review - '정상 완료'
iseg I10 "$WORK/in-zero"; ir I10 implement d10 '의도된 park'
SNAP_I="$WORK/implement-next.json"
( cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null ) > "$SNAP_I"
inx() { jq -r --arg s "$1" '.implement_next[] | select(.["세그먼트"]==$s) | [.["다음"], .["단계"], (.["앞선 커밋"]|tostring), (.["무커밋 구현"]|tostring)] | join("|")' "$SNAP_I"; }
check "계획 방출만 한 구현 뒤에는 구현을 다시 보낸다" "$(inx I1)" "구현|A|0|1"
check "같은 다이제스트로 커밋 없이 끝난 B 뒤에도 구현이다" "$(inx I2)" "구현|B|0|2"
check "커밋 없는 구현 셋째에서 사람에 닿는다" "$(inx I3)" "사람|B|0|3"
check "B 가 커밋을 냈으면 리뷰다" "$(inx I4)" "리뷰|B|1|1"
check "재수렴 행이 무효 경계가 되어 수를 되돌린다" "$(inx I5)" "구현|A|0|1"
check "커밋이 있는 브랜치에서도 재수렴 뒤 새 계획 방출은 구현이다" "$(inx I6)" "구현|A|1|1"
check "베이스만 앞으로 움직인 브랜치는 앞선 커밋 0 으로 읽힌다" "$(inx I7)" "구현|A|0|1"
check "워크트리가 없으면 판정 불가다" "$(inx I8)" "판정 불가|A|미상|1"
check "마지막 행이 리뷰이거나 의도된 park 인 세그먼트는 원소가 없다" \
  "$(jq -r '[.implement_next[] | select(.["세그먼트"]=="I9" or .["세그먼트"]=="I10")] | length' "$SNAP_I")" "0"
check "implement_next 원소가 여섯 필드를 싣는다" \
  "$(jq -c '.implement_next[] | select(.["세그먼트"]=="I1") | keys' "$SNAP_I")" '["plan_sha256","다음","단계","무커밋 구현","세그먼트","앞선 커밋"]'
check "implement_next 원소가 마지막 구현 행의 다이제스트를 싣는다" \
  "$(jq -r '.implement_next[] | select(.["세그먼트"]=="I5") | .plan_sha256' "$SNAP_I")" "d5b"
check "implement_next 는 기본 --fields 투영 밖이다" \
  "$( ( cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" --fields "$GATE_SNAPSHOT_FIELDS_DEFAULT" 2>/dev/null ) | jq -r 'has("implement_next")')" "false"
# THE ELEMENT MOVES, `H` DOES NOT: a commit in a segment worktree turns I1 from
# `구현` into `리뷰` without a ledger row, and the digest stays where it was.
hi0=$( ( cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" --fields H 2>/dev/null ) )
( cd "$WORK/in-zero" && echo more > more.txt && git add -A && git commit -qm more ) >/dev/null 2>&1
( cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null ) > "$SNAP_I"
check "세그먼트 워크트리에 커밋이 생기면 원소가 움직인다" "$(inx I2)" "리뷰|B|1|1"
check "implement_next 의 값이 움직여도 H 는 그대로다" \
  "$( ( cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" --fields H 2>/dev/null ) )" "$hi0"

# ---------------------------------------------------------------------------
# 6e-2. `audit_skeleton_due` — the audit that asked for its skeletal re-convergence
#
# An audit that ended `정상 완료` and counted skeleton-grade items is not done:
# the gate names it in `audit_skeleton_due`, and both router copies read that
# key before planning past the audit. A plan without an audit step has nothing
# to wait on, so the key is `null` there. The gate's own section 15e-4 drives the
# object form on a live run; what is pinned here is the key, and the text each
# reader carries.
# ---------------------------------------------------------------------------
SNAP_K="$WORK/skeleton-due.json"
( cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null ) > "$SNAP_K"
check "스냅숏이 audit_skeleton_due 키를 싣는다" "$(jq -r 'has("audit_skeleton_due")' "$SNAP_K")" "true"
check "감사 단계 없는 계획의 audit_skeleton_due 는 null 이다" "$(jq -c '.audit_skeleton_due' "$SNAP_K")" "null"
for pair in "리드:$AP_ROUTER" "교대:$RS_CORPUS"; do
  who=${pair%%:*}; f=${pair#*:}
  for lit in \
    '#### Routing a skeleton-grade audit to re-convergence' \
    "and that the snapshot's \`audit_skeleton_due\` is \`null\`" \
    '`audit_skeleton_due` not `null` → 「Routing a skeleton-grade audit to re-convergence」 below.' \
    '{"step": "<audit step id>", "skeletal": <n>}' \
    "--rationale '감사 골격급 재수렴'" \
    '-- reconverge -p "/cc-cmds:design-reconverge <스냅숏 design_doc> 감사 골격급"' \
    '`사유=골격급 재수렴 종단 술어 거짓`'; do
    if grep -qF -- "$lit" "$f"; then
      ok "$who 사본이 골격급 재수렴 리터럴을 싣는다: $lit"
    else
      bad "$who 사본의 골격급 재수렴 리터럴" "없다: $lit"
    fi
  done
done
for lit in \
  '| `골격급-재수렴` | 10 |' \
  '감사 골격급 <record>"' \
  "Item 4's 'After it ends' names this same act for this shape; there is one act."; do
  if grep -qF -- "$lit" "$RS_CORPUS"; then
    ok "교대 스킬이 골격급 재발 답의 갈래를 싣는다: $lit"
  else
    bad "교대 스킬의 골격급 재발 갈래" "없다: $lit"
  fi
done
AU_SKILL="$repo_root/plugins/cc-cmds/skills/design-audit-unattended/SKILL.md"
check "감사 스킬이 합성 요구를 사람 판단 보류로 적는다" \
  "$(grep -cF '사유: 감사 합성 요구 — 사람 판단' "$AU_SKILL" || true)" "1"
check "감사 스킬에 합성 요구에서 무조건 멈춘다는 문장이 없다" \
  "$(grep -cF 'halts, unconditionally' "$AU_SKILL" || true)" "0"
if grep -qF 'Step 7 / 골격급 재발' "$AU_SKILL"; then
  ok "감사 스킬이 골격급 재발 멈춤의 스텝 문자열을 싣는다"
else
  bad "감사 스킬이 골격급 재발 멈춤의 스텝 문자열을 싣는다" "없다"
fi

# ---------------------------------------------------------------------------
# 6f. The stall classifier — `stall-class.awk` and the `stalls` key
#
# Every ledger here is synthetic and written to its own file under $WORK; the
# fixture ledger is never touched, so no later section sees these rows. The
# classifier is called directly for the row rules, and the sourced snapshot is
# called with `LEDGER` swapped in a subshell where the key itself is the claim.
# Rows carrying a `발견 지문` are planted by hand: the gate refuses that field
# from a caller, which guards `act`, not a direct write.
#
# Expected values are compared as `세그먼트/부류/사이클` words read through jq,
# never by grepping the JSON text, and a `처분` other than `지시` is appended to
# the word so it cannot pass unseen.
# ---------------------------------------------------------------------------
SC_AWK="$repo_root/plugins/cc-cmds/orchestrator/stall-class.awk"
SC_N=0
sc_rep() {
  # A bare name is a report path of the usual shape; `-`, a path and any other
  # literal value pass through as written.
  case "$1" in
    -|*/*|'('*) printf '%s' "$1" ;;
    *) printf 'docs/reviews/%s.md' "$1" ;;
  esac
}
sc_c() {
  # sc_c <segment> <cycle> <P0> <P1> <HEAD> <report> [<fingerprint>] [<extra fields>]
  local fp=""
  [ -n "${7:-}" ] && fp=" | 발견 지문=$7"
  printf -- '- `cycle` | 세그먼트=%s | 사이클=%s | P0=%s | P1=%s | 리뷰 HEAD=%s | 리포트 경로=%s%s%s\n' \
    "$1" "$2" "$3" "$4" "$5" "$(sc_rep "$6")" "$fp" "${8:-}"
}
sc_i() {
  # sc_i <segment> <digest or -> [<terminal class>] — an implement stage-result.
  local d=""
  [ "$2" = "-" ] || d=" | plan_sha256=$2"
  printf -- '- `stage-result` | 세그먼트=%s | 스테이지=%s-impl | 종류=implement | 종료 코드=0%s | 종단 부류=%s\n' \
    "$1" "$1" "$d" "${3:-정상 완료}"
}
sc_x() {
  printf -- '- `stage-result` | 세그먼트=%s | 스테이지=%s-impl | 종류=implement | 종료 코드=143 | 종단 부류=외부 종료\n' "$1" "$1"
}
sc_led() {
  # sc_led <row>... — writes a fresh ledger and prints its path.
  SC_N=$((SC_N + 1))
  local f="$WORK/stall-$SC_N.md"
  printf '%s\n' "$@" > "$f"
  printf '%s' "$f"
}
sc_words() {
  # The `stalls` items on stdin (an array body or a whole array) as words.
  jq -r 'if type == "array" then . else [.] end
         | [.[] | "\(.["세그먼트"])/\(.["부류"])/\(.["사이클"])" + (if .["처분"] == "지시" then "" else "/처분=\(.["처분"])" end)]
         | join(" ")'
}
sc_last() {
  { printf '[\n'; LC_ALL=C awk -v mode=last -v root=/r -f "$SC_AWK" "$1"; printf ']\n'; } | sc_words
}
sc_all() { LC_ALL=C awk -v mode=all -v root=/r -f "$SC_AWK" "$1"; }
sc_case() {
  # sc_case <title> <want> <row>...
  local t=$1 w=$2 f
  shift 2
  f=$(sc_led "$@")
  check "$t" "$(sc_last "$f")" "$w"
}
sc_snap() {
  # The whole snapshot object of ledger $1, from the sourced gate.
  ( LEDGER="$1"; gate_snapshot )
}
P_NEW=$(printf 'a%.0s' $(seq 64))
P_OLD=$(printf 'b%.0s' $(seq 64))
P_UP=$(printf 'C%.0s' $(seq 64))
P_63=$(printf 'c%.0s' $(seq 63))
H1=1111111; H2=2222222; H3=3333333; H4=4444444; HH=abcdef0

f=$(sc_led "$(sc_c S7 1 0 1 abc1234 r1)" "$(sc_c S7 2 0 1 abc1234ef r2)")
check "같은 커밋의 두 리뷰는 NO_DRIFT 다" "$(sc_last "$f")" "S7/NO_DRIFT/2"
check "stalls 항목의 키는 정확히 넷이다" \
  "$({ printf '[\n'; LC_ALL=C awk -v mode=last -v root=/r -f "$SC_AWK" "$f"; printf ']\n'; } | jq -r '.[0] | keys | length')" "4"
sc_case "리포트 키 없는 앞 행은 같은 커밋의 뒤 행에 흡수된다" "" \
  "$(printf -- '- `cycle` | 세그먼트=S3 | 사이클=3 | P0=0 | P1=0 | 리뷰 HEAD=%s' "$HH")" "$(sc_c S3 4 0 1 "$HH" r3)"
sc_case "같은 번호는 한 리뷰다" "" "$(sc_c S3 4 0 1 "$HH" r4)" "$(sc_c S3 4 0 1 "$HH" r4b)"
sc_case "거꾸로 가는 번호는 NO_DRIFT 가 아니다" "" "$(sc_c S3 5 0 1 "$HH" r5)" "$(sc_c S3 4 0 1 "$HH" r4)"
sc_case "접두가 아닌 HEAD 는 같은 커밋이 아니다" "" "$(sc_c S3 1 0 1 abc1234 r1)" "$(sc_c S3 2 0 1 abd1234 r2)"
sc_case "64자 HEAD 는 단절 행이다" "" "$(sc_c S7 1 0 1 abc1234 r1)" "$(sc_c S7 2 0 1 "abc1234$(printf 'e%.0s' $(seq 57))" r2)"

DR_1=$(sc_c S6 1 0 3 "$H1" r1); DR_2=$(sc_c S6 2 0 2 "$H2" r2); DR_3=$(sc_c S6 3 0 3 "$H3" r3)
sc_case "P1 이 다시 오르면 DIMINISHING_RETURNS 다" "S6/DIMINISHING_RETURNS/3" "$DR_1" "$DR_2" "$DR_3"
sc_case "음성 — P1 이 3·2·1 로 줄면 라벨이 없다" "" "$DR_1" "$DR_2" "$(sc_c S6 3 0 1 "$H3" r3)"
sc_case "음성 — 창 안의 P0=1 이 막는다" "" "$DR_1" "$(sc_c S6 2 1 2 "$H2" r2)" "$DR_3"
sc_case "리포트 없는 가운데 행(-)이 창을 끊는다" "" "$DR_1" "$(sc_c S6 2 0 2 "$H2" -)" "$DR_3"
sc_case "리포트 없는 가운데 행((없음))이 창을 끊는다" "" "$DR_1" "$(sc_c S6 2 0 2 "$H2" '(없음)')" "$DR_3"
for v in "P1=08:S6/DIMINISHING_RETURNS/3" "P1=abc:" "사이클=x:"; do
  kv=${v%%:*}; want=${v#*:}
  case "$kv" in
    P1=*) mid=$(sc_c S6 2 0 "${kv#P1=}" "$H2" r2) ;;
    *)    mid=$(sc_c S6 "${kv#사이클=}" 0 2 "$H2" r2) ;;
  esac
  f=$(sc_led "$DR_1" "$mid" "$DR_3")
  check "가운데 행 ${kv} 의 라벨" "$(sc_last "$f")" "$want"
  ( LEDGER="$f"; gate_snapshot_digest >/dev/null 2>&1 )
  check "가운데 행 ${kv} 에서도 스냅숏 다이제스트가 rc 0 이다" "$?" "0"
done

sc_case "같은 지문이 세 리뷰 연속이면 SPINNING 이다" "S2/SPINNING/3" \
  "$(sc_c S2 1 1 1 "$H1" r1 X)" "$(sc_c S2 2 1 1 "$H2" r2 X)" "$(sc_c S2 3 1 1 "$H3" r3 X)"
sc_case "음성 — 지문이 없으면 라벨이 없다" "" \
  "$(sc_c S2 1 1 1 "$H1" r1)" "$(sc_c S2 2 1 1 "$H2" r2)" "$(sc_c S2 3 1 1 "$H3" r3)"
sc_case "음성 — 셋째 행이 0/0 이면 라벨이 없다" "" \
  "$(sc_c S2 1 1 1 "$H1" r1 X)" "$(sc_c S2 2 1 1 "$H2" r2 X)" "$(sc_c S2 3 0 0 "$H3" r3 X)"
sc_case "같은 HEAD 접기는 SPINNING 창에만 걸린다" "S1/NO_DRIFT/4" \
  "$(sc_c S1 2 1 1 "$H1" r2 X)" "$(sc_c S1 3 1 1 "$H2" r3 X)" "$(sc_c S1 4 1 1 "$H2" r4 X)"
sc_case "지문 A,B,A,B 는 OSCILLATION 이다" "S/OSCILLATION/4" \
  "$(sc_c S 1 1 1 "$H1" r1 A)" "$(sc_c S 2 1 1 "$H2" r2 B)" "$(sc_c S 3 1 1 "$H3" r3 A)" "$(sc_c S 4 1 1 "$H4" r4 B)"
sc_case "음성 — 지문 A,B,A,A 는 라벨이 없다" "" \
  "$(sc_c S 1 1 1 "$H1" r1 A)" "$(sc_c S 2 1 1 "$H2" r2 B)" "$(sc_c S 3 1 1 "$H3" r3 A)" "$(sc_c S 4 1 1 "$H4" r4 A)"
sc_case "지문 A,A,A,A 는 SPINNING 만이다" "S/SPINNING/4" \
  "$(sc_c S 1 1 1 "$H1" r1 A)" "$(sc_c S 2 1 1 "$H2" r2 A)" "$(sc_c S 3 1 1 "$H3" r3 A)" "$(sc_c S 4 1 1 "$H4" r4 A)"
MIXED=("$(sc_c S1 1 0 2 "$H1" r1)" "$(sc_c S2 1 1 1 a111111 e1 X)" "$(sc_c S1 2 0 2 "$H2" r2)" \
  "$(sc_c S2 2 1 1 a222222 e2 X)" "$(sc_c S1 3 0 2 "$H3" r3)" "$(sc_c S2 3 1 1 a333333 e3 X)" "$(sc_c S1 4 0 2 "$H3" r4)")
sc_case "우선순위 없이 세그먼트 순서와 부류 순서로 낸다" \
  "S1/NO_DRIFT/4 S1/DIMINISHING_RETURNS/4 S2/SPINNING/3" "${MIXED[@]}"
sc_case "SPINNING 과 DIMINISHING_RETURNS 가 함께 선다" "S/SPINNING/3 S/DIMINISHING_RETURNS/3" \
  "$(sc_c S 1 0 2 "$H1" r1 X)" "$(sc_c S 2 0 1 "$H2" r2 X)" "$(sc_c S 3 0 2 "$H3" r3 X)"
sc_case "머지된 세그먼트의 라벨도 남는다(결과 필터 없음)" "S6/DIMINISHING_RETURNS/3" \
  "$DR_1" "$DR_2" "$DR_3" '- `segment` | 세그먼트=S6 | 상태=머지됨'
f=$(sc_led "$DR_1" "$DR_2" "$DR_3" "$(sc_i S6 "$P_NEW")")
check "뒤따른 새 계획이 라벨을 소비한다" "$(sc_last "$f")" ""
check "mode=all 이 소비 줄로 그 구현 행의 줄을 낸다" "$(sc_all "$f" | cut -f2,4,5,6)" \
  "$(printf '3\tDIMINISHING_RETURNS\t4\t-')"
sc_case "다시 실은 다이제스트는 소비하지 않는다" "S6/DIMINISHING_RETURNS/3" \
  "$(sc_i S6 "$P_OLD")" "$DR_1" "$DR_2" "$DR_3" "$(sc_i S6 "$P_OLD")"
sc_case "다이제스트 없는 구현 행은 소비하지 않는다" "S6/DIMINISHING_RETURNS/3" \
  "$DR_1" "$DR_2" "$DR_3" "$(sc_i S6 -)"
sc_case "외부 종료 정산 행은 소비하지 않는다" "S6/DIMINISHING_RETURNS/3" \
  "$DR_1" "$DR_2" "$DR_3" "$(sc_x S6)"
sc_case "다른 세그먼트의 계획은 소비하지 않는다" "S6/DIMINISHING_RETURNS/3" \
  "$DR_1" "$DR_2" "$DR_3" "$(sc_i S9 "$P_NEW")"
sc_case "대문자 다이제스트는 소비하지 않는다" "S6/DIMINISHING_RETURNS/3" \
  "$DR_1" "$DR_2" "$DR_3" "$(sc_i S6 "$P_UP")"
sc_case "63자 다이제스트는 소비하지 않는다" "S6/DIMINISHING_RETURNS/3" \
  "$DR_1" "$DR_2" "$DR_3" "$(sc_i S6 "$P_63")"
sc_case "라벨 행 앞의 계획은 소비하지 않는다" "S6/DIMINISHING_RETURNS/3" \
  "$DR_1" "$DR_2" "$(sc_i S6 "$P_NEW")" "$DR_3"
sc_case "새 리뷰가 라벨을 다시 켠다" "S6/DIMINISHING_RETURNS/4" \
  "$DR_1" "$DR_2" "$DR_3" "$(sc_i S6 "$P_NEW")" "$(sc_c S6 4 0 3 "$H4" r4)"
sc_case "크래시로 끝난 process A 의 계획도 소비한다" "" \
  "$DR_1" "$DR_2" "$DR_3" "$(sc_i S6 "$P_NEW" 크래시)"
sc_case "같은 번호 정정이 거짓 DIMINISHING_RETURNS 를 만들지 않는다" "" \
  "$(sc_c S6 1 0 1 "$H1" r1)" "$(sc_c S6 2 0 2 "$H2" r2)" "$(sc_c S6 2 0 2 "$H2" r2b)"
CORR_B=("$(sc_c S6 1 0 2 "$H1" r1)" "$(sc_c S6 2 0 2 "$H2" r2)" "$(sc_c S6 3 0 2 "$H3" r3)" \
  "$(sc_i S6 "$P_NEW")" "$(sc_c S6 3 0 3 "$H3" r3b)")
sc_case "이미 라벨을 지닌 행에서 창이 열려 사이의 계획이 소비한다" "" "${CORR_B[@]}"
sc_case "리뷰 id 와 수리 id 가 다르면 소비되지 않는다" "S2C2/DIMINISHING_RETURNS/3" \
  "$(sc_c S2C2 1 0 3 "$H1" r1)" "$(sc_c S2C2 2 0 2 "$H2" r2)" "$(sc_c S2C2 3 0 3 "$H3" r3)" "$(sc_i S2R1 "$P_NEW")"

f=$(sc_led "$(sc_c 'a"b\c' 1 0 1 "$HH" r1)" "$(sc_c 'a"b\c' 2 0 1 "$HH" r2)")
check "따옴표와 역슬래시를 품은 세그먼트가 이스케이프되어 되돌아온다" "$(sc_last "$f")" 'a"b\c/NO_DRIFT/2'
f=$(sc_led "$(sc_c "$(printf 'S\377')" 1 0 1 "$HH" r1)" "$(sc_c "$(printf 'S\377')" 2 0 1 "$HH" r2)")
n_ff=$({ printf '[\n'; LC_ALL=C awk -v mode=last -v root=/r -f "$SC_AWK" "$f"; printf ']\n'; } | jq -r 'length' 2>/dev/null)
check "0xff 바이트의 세그먼트도 항목이 나오고 jq 가 읽는다" "$n_ff" "1"
f=$(sc_led "$(sc_c "$(printf 'S\001')" 1 0 1 "$HH" r1)" "$(sc_c "$(printf 'S\001')" 2 0 1 "$HH" r2)")
check "0x01 바이트의 세그먼트는 단절 행이다" "$(sc_last "$f")" ""
sc_snap "$f" > "$WORK/stall-ctl.json" 2>/dev/null
check "그 원장에서도 스냅숏이 rc 0 이다" "$?" "0"

# The classifier missing, then a stand-in that prints an item and fails.
f=$(sc_led "$(sc_c S7 1 0 1 abc1234 r1)" "$(sc_c S7 2 0 1 abc1234ef r2)")
sc_snap "$f" > "$WORK/stall-ok.json" 2>/dev/null
check "대조 — 분류기가 있으면 stalls 에 항목이 있다" "$(jq -r '.stalls | length' "$WORK/stall-ok.json")" "1"
( GATE_DIR="$WORK/no-such-dir"; LEDGER="$f"; gate_snapshot ) > "$WORK/stall-miss.json" 2> "$WORK/stall-miss.err"
check "분류기가 없어도 스냅숏은 rc 0 이다" "$?" "0"
check "분류기가 없으면 stalls 는 빈 배열이다" "$(jq -c '.stalls' "$WORK/stall-miss.json")" "[]"
check "분류기가 없으면 stderr 에 경고가 한 줄 있다" "$(grep -c '정체 라벨 계산 실패' "$WORK/stall-miss.err")" "1"
check "분류기가 없어도 stalls 밖의 키는 H 를 포함해 바이트로 같다" \
  "$(jq -S 'del(.stalls)' "$WORK/stall-miss.json")" "$(jq -S 'del(.stalls)' "$WORK/stall-ok.json")"
mkdir -p "$WORK/fake-gate"
printf '%s\n' 'BEGIN { printf "    {\"세그먼트\": \"Z\", \"부류\": \"NO_DRIFT\", \"사이클\": \"1\", \"처분\": \"지시\"}\n"; exit 1 }' \
  > "$WORK/fake-gate/stall-class.awk"
( GATE_DIR="$WORK/fake-gate"; LEDGER="$f"; gate_snapshot ) > "$WORK/stall-fake.json" 2>/dev/null
check "항목을 찍고 실패한 분류기의 출력은 버려진다" "$(jq -c '.stalls' "$WORK/stall-fake.json" 2>/dev/null)" "[]"
if jq -e . "$WORK/stall-fake.json" >/dev/null 2>&1; then
  ok "실패한 분류기 뒤에도 스냅숏 전체가 유효한 JSON 이다"
else
  bad "실패한 분류기 뒤의 스냅숏 JSON" "실패한 분류기의 반쪽 출력이 새어 들었다"
fi

f=$(sc_led "${MIXED[@]}" "$DR_1" "$DR_2" "$DR_3" "$(sc_i S6 "$P_NEW")")
cur_all=$(sc_all "$f" | awk -F'\t' '$6 == "현재" { printf "%s%s/%s/%s", (n++ ? " " : ""), $1, $4, $3 }')
cur_last=$(sc_last "$f")
check "mode=all 의 현재 줄 투영이 mode=last 와 같다" "$cur_all" "$cur_last"
check "mode=last 가 스냅숏의 stalls 와 같다" "$(sc_snap "$f" 2>/dev/null | jq '.stalls' | sc_words)" "$cur_last"
check "분류기에 정규식 구간 반복이 없다" "$(grep -cE '\{[0-9]' "$SC_AWK")" "0"
check "분류기에 GNU 전용 함수가 없다" "$(grep -cE 'gensub|asort|strftime|systime' "$SC_AWK")" "0"
check "분류기에 단어 경계 이스케이프가 없다" "$(grep -cF -e '\<' -e '\b' "$SC_AWK")" "0"

sc_case "경로 모양이 아닌 리포트 값은 단절 행이다" "" \
  "$(sc_c S 1 0 2 aaaaaa1 r1)" "$(sc_c S 2 0 2 aaaaaa2 '(선머지후리뷰 — 리뷰는 머지 뒤 S2)')" "$(sc_c S 3 0 2 aaaaaa2 r3)"
sc_case "경로 아닌 앞 행은 같은 HEAD 의 뒤 리뷰와 NO_DRIFT 를 이루지 않는다" "" \
  "$(sc_c S 1 0 1 "$HH" '(선머지후리뷰 — 리뷰는 머지 뒤 S2)')" "$(sc_c S 2 0 1 "$HH" r2)"
sc_case "대조 — 경로 모양 앞 행이면 NO_DRIFT 가 선다" "S/NO_DRIFT/2" \
  "$(sc_c S 1 0 1 "$HH" docs/reviews/x.md)" "$(sc_c S 2 0 1 "$HH" r2)"
sc_case "흡수된 단절 행은 NO_DRIFT 를 만들지 않는다" "" "$(sc_c S 4 0 0 "$HH" -)" "$(sc_c S 5 0 1 "$HH" r5)"
sc_case "흡수된 단절 행은 창을 끊지 않는다" "S/DIMINISHING_RETURNS/4" \
  "$(sc_c S 1 0 2 "$H1" r1)" "$(sc_c S 2 0 0 "$H2" -)" "$(sc_c S 3 0 2 "$H2" r3)" "$(sc_c S 4 0 2 "$H3" r4)"
sc_case "같은 리포트는 한 리뷰다" "" "$(sc_c S 4 0 1 "$HH" r)" "$(sc_c S 5 0 1 "$HH" r)"
sc_case "첫 행의 P1 이 0 이면 DIMINISHING_RETURNS 가 아니다" "" \
  "$(sc_c S 1 0 0 "$H1" r1)" "$(sc_c S 2 0 0 "$H2" r2)" "$(sc_c S 3 0 1 "$H3" r3)"
sc_case "2·1·2 는 DIMINISHING_RETURNS 다" "S/DIMINISHING_RETURNS/3" \
  "$(sc_c S 1 0 2 "$H1" r1)" "$(sc_c S 2 0 1 "$H2" r2)" "$(sc_c S 3 0 2 "$H3" r3)"
sc_case "DIMINISHING_RETURNS 도 같은 HEAD 를 접는다" "S/NO_DRIFT/4" \
  "$(sc_c S 1 0 3 "$H1" r1)" "$(sc_c S 2 0 1 "$H2" r2)" "$(sc_c S 3 0 1 "$H3" r3)" "$(sc_c S 4 0 1 "$H3" r4)"
sc_case "P0 가 남는 루프에는 라벨이 없다" "" \
  "$(sc_c S 1 1 5 "$H1" r1)" "$(sc_c S 2 1 6 "$H2" r2)" "$(sc_c S 3 1 7 "$H3" r3)"
f=$(sc_led "$(sc_c S 1 0 2 "$H1" r1)" "$(sc_c S 2 0 2 "$H2" r2)" "$(sc_c S 3 0 1 "$H3" r3)" \
  "$(sc_i S "$P_NEW")" "$(sc_c S 3 0 3 "$H3" r3b)")
check "정정이 새로 세운 라벨은 정정 전 계획이 소비하지 않는다" "$(sc_last "$f")" "S/DIMINISHING_RETURNS/3"
check "그 라벨의 mode=all 소비 줄은 - 다" "$(sc_all "$f" | cut -f2,4,5,6)" "$(printf '5\tDIMINISHING_RETURNS\t-\t현재')"
f=$(sc_led "${CORR_B[@]}")
check "라벨 있는 c3 는 사이의 계획이 소비한다" "$(sc_last "$f")" ""
f=$(sc_led "$(sc_c S 1 0 2 "$H1" r1)" "$(sc_c S 2 0 2 "$H2" r2)" "$(sc_c S 3 0 2 "$H3" r3)" \
  "$(sc_i S "$P_NEW")" "$(sc_c S 3 0 1 "$H3" r3b)")
check "라벨을 지운 정정 뒤에는 라벨이 없다" "$(sc_last "$f")" ""
check "라벨을 지운 정정 뒤 mode=all 은 소비된 c3 의 라벨 한 줄을 낸다" "$(sc_all "$f" | cut -f2,4,5,6)" \
  "$(printf '3\tDIMINISHING_RETURNS\t4\t-')"
sc_case "분류기는 모드를 읽지 않는다 — 같은 HEAD 의 델타 행도 NO_DRIFT 를 세운다" "S/NO_DRIFT/4" \
  "$(sc_c S 3 0 2 "$HH" r3)" "$(sc_c S 4 0 2 "$HH" r4 '' ' | 모드=델타 | 기준 사이클=3')"
LC_ALL=C awk -v mode=last -f "$SC_AWK" "$f" "$f" >/dev/null 2>&1
check "원장 피연산자 둘은 exit 2 다" "$?" "2"

# The builder's root and the morning report's root read one ledger alike.
rt_d=${MANIFEST%/*}; rt_r=${rt_d%/*}; rt_r=${rt_r%/*}
rt_p=$(cd "$rt_d/../.." && pwd)
f=$(sc_led "$(sc_c S3 4 0 3 "$HH" docs/reviews/v4.md)" "$(sc_c S3 5 0 3 "$HH" "$rt_r/docs/reviews/v4.md")")
rt_a=$(LC_ALL=C awk -v mode=all -v root="$rt_r" -f "$SC_AWK" "$f")
rt_b=$(LC_ALL=C awk -v mode=all -v root="$rt_p" -f "$SC_AWK" "$f")
check "빌더의 루트와 아침 보고의 루트가 같은 출력을 낸다" "$rt_a" "$rt_b"
check "같은 리포트의 두 철자에는 라벨이 없다" "$rt_a" ""
sc_case "사이클은 수치로 견준다" "S/NO_DRIFT/10" "$(sc_c S 9 0 1 "$HH" r9)" "$(sc_c S 10 0 1 "$HH" r10)"
sc_case "P1 은 수치로 견준다" "S/DIMINISHING_RETURNS/3" \
  "$(sc_c S 1 0 9 "$H1" r1)" "$(sc_c S 2 0 5 "$H2" r2)" "$(sc_c S 3 0 10 "$H3" r3)"

# The four directive texts process A copies into its plan, each carried once.
IU_SKILL="$repo_root/plugins/cc-cmds/skills/implement-unattended/SKILL.md"
for lit in \
  '같은 커밋이 두 번 리뷰됐다 — 고치기로 한 발견은 새 커밋으로 끝내고, 고치지 않기로 한 발견은 그 판단을 계획에 적는다' \
  '같은 파일 집합이 세 리뷰 연속 P0/P1 발견을 지녔다 — 같은 수정을 반복하지 말고 접근을 바꾼다' \
  '발견의 파일 집합이 네 리뷰에 걸쳐 번갈아 나왔다 — 둘을 함께 만족하는 수정을 찾는다' \
  '발견의 사례가 아니라 그 부류를 고친다'
do
  check "지시 문면 「${lit}」이 구현 스킬에 한 번 실린다" "$(grep -c -F -- "$lit" "$IU_SKILL")" "1"
done

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
# 7b. Obligation disposition — the excusal's two quantifiers, the latch, and the
#     two boundaries that read them
#
# DRIVEN AGAINST THE SOURCED DEFINITIONS rather than through the CLI, and that is
# not a convenience. Every property here is about a PREDICATE re-evaluated on
# state the run can rewrite — which segment a problem row names, and the highest
# creation grade recorded for its identity — and about a counter kept in the run
# directory. Reaching those through acts means every fixture step also evaluates
# the boundaries, so the fixture becomes part of what is being measured.
# ---------------------------------------------------------------------------
o_problem() {
  # o_problem <세그먼트> <동일성> <생성 등급> — one problem row.
  # The identity is NOT the last field on the line: every reader selects it with
  # `grep -F "동일성=<값> "`, so a row ending on the identity would be invisible
  # to all of them and the fixture would measure nothing.
  printf -- '- `problem` | 세그먼트=%s | 동일성=%s | 생성 등급=%s | 시각=t | prev=x\n' \
    "$1" "$2" "$3" >> "$LEDGER"
}
o_segment() {
  # o_segment <id> <상태> — a segment row. The LAST row for an id decides, so
  # appending another one is how a fixture moves a segment in or out of terminal.
  printf -- '- `segment` | id=%s | 상태=%s | 워크트리=%s | prev=x\n' "$1" "$2" "$WT" >> "$LEDGER"
}

LEDGER="$WORK/oblig.md"; : > "$LEDGER"
RUN_DIR="$WORK/oblig-run"; mkdir -p "$RUN_DIR"
RUN_ID="R1"

# --- 7b-a. The grade axis: the HIGHEST grade wins, so a later row cannot lower it
#
# The amnesty this whole slice removes: writing one more problem row for the same
# identity, naming a low creation grade, excused an obligation opened at a higher
# one. The chain stayed intact, the row was well formed, and the act was itself
# graded `읽기` so it spent no budget.
o_segment SP1 park
o_problem SP1 P0-회귀 외부상태변경
if gate_obligation_excused "P0-회귀"; then
  bad "면제 등급 축" "외부 상태를 바꾼 행위가 연 의무가 면제됐다 — 효과가 기계 밖으로 나간 바로 그 의무다"
else
  ok "높은 생성 등급의 의무는 park 세그먼트 위에서도 면제되지 않는다 (기준선)"
fi
o_problem SP1 P0-회귀 읽기
if gate_obligation_excused "P0-회귀"; then
  bad "사면 회귀" "더 낮은 생성 등급을 실은 둘째 문제 행이 면제를 열었다 — 뒤에 붙은 행이 이긴다"
else
  ok "더 낮은 등급의 둘째 문제 행이 면제를 열지 못한다 (최고등급-승)"
fi
check "그 동일성이 열린 의무로 남는다 (조건 3 이 남는다)" \
  "$( { gate_open_obligations | grep -cxF 'obligation=P0-회귀' || true; } )" "1"

# --- 7b-b. `등급 미상` is an absorbing element, not a low grade -----------------
#
# A REFUSED act structurally carries it, and refusal is the dominant way problem
# rows come to exist — so treating it as though it sat below the ceiling would
# excuse exactly the obligations nobody established anything about.
o_segment SP2 park
o_problem SP2 P0-미상 "등급 미상"
check "최고 생성 등급이 등급 미상으로 읽힌다" "$(gate_obligation_top_grade 'P0-미상')" "등급 미상"
if gate_obligation_excused "P0-미상"; then
  bad "흡수원소" "등급 미상이 알려진 등급 아래로 다뤄져 면제됐다"
else
  ok "등급 미상은 알려진 모든 등급 위로 다뤄져 면제되지 않는다"
fi

# --- 7b-c. The segment axis, and its pair --------------------------------------
#
# The design fixed the grade axis first and the segment axis was still carrying
# the same defect, so the regression assertion above pins only half of it. The
# bundle crosses segments: reading one row's segment lets a later row naming a
# parked segment decide for rows that are not parked at all.
#
# THE ROW ORDER IS THE DISCRIMINATOR. The removed implementation read the LAST
# problem row's segment, so the rows go running-segment first and parked-segment
# LAST: that is the order in which the last row answers "excused" for a bundle
# that is not parked. The other order passes against the removed code too.
o_segment SP3 park
o_segment SP4 실행중
o_problem SP4 P0-세그먼트축 읽기
if gate_obligation_excused "P0-세그먼트축"; then
  bad "면제 기준선" "실행중 세그먼트 위의 의무가 면제됐다"
else
  ok "실행중 세그먼트 위의 의무는 면제되지 않는다 (기준선)"
fi
o_problem SP3 P0-세그먼트축 읽기
if gate_obligation_excused "P0-세그먼트축"; then
  bad "면제 세그먼트 축" "park 세그먼트를 지목하는 행이 뒤에 붙자 면제됐다 — 마지막 행이 이긴다"
else
  ok "뒤에 붙은 park 행이 앞선 실행중 행을 대신 결정하지 못한다 (전칭 규칙)"
fi
# The pair. Terminal is re-read at call time rather than carried, so moving the
# segment must move the answer back — without this the assertion above is also
# satisfied by an implementation that never excuses a two-segment bundle.
o_segment SP4 park
if gate_obligation_excused "P0-세그먼트축"; then
  ok "그 세그먼트가 park 로 옮겨 가면 다시 면제된다 (판정 시점에 다시 읽는다)"
else
  bad "면제 세그먼트 축 짝" "모든 행이 park 인데도 면제되지 않는다"
fi

# The same shape for `포기`, whose terminal requirement is the same universal
# over the bundle's segments.
o_segment SP5 park
o_segment SP6 실행중
o_problem SP6 P0-포기축 외부상태변경
o_problem SP5 P0-포기축 외부상태변경
if gate_obligation_segments_terminal "P0-포기축"; then
  bad "포기 세그먼트 축" "park 세그먼트를 지목하는 행이 뒤에 붙자 묶음 전체가 종단으로 읽혔다"
else
  ok "포기의 종단 요구도 뒤에 붙은 park 행 하나로 채워지지 않는다"
fi
o_segment SP6 park
if gate_obligation_segments_terminal "P0-포기축"; then
  ok "모든 세그먼트가 종단이 되면 포기의 종단 요구가 채워진다 (짝)"
else
  bad "포기 세그먼트 축 짝" "모든 행이 park 인데도 종단으로 읽히지 않는다"
fi

# --- 7b-d. The latch — the exemption count cannot be walked back --------------
#
# `종결` and `포기` are rows and only accumulate; `면제` is a predicate over
# reversible state, so its count can FALL. Unlatched, the boundary below is
# evaded by walking a parked segment back to `실행중` one row before the
# threshold and parking it again.
#
# THROUGH `gate_boundaries`, NOT THE UPDATE FUNCTION. The update used to be
# called only from the terminal report, and a fixture calling it directly passed
# all the same — so the render's counts read `0 · 0 · 0` for the whole run and an
# excusal walked back before the end was never latched. One ordinary `읽기` act
# from the router's seat is what latches here; every seat marker is pinned
# because this suite also runs from inside a stage.
o_act() {
  ( CC_PIPELINE_SEGMENT='' CC_PIPELINE_STAGE_ID='' CC_PIPELINE_SHIFT_ID=''
    export CC_PIPELINE_SEGMENT CC_PIPELINE_STAGE_ID CC_PIPELINE_SHIFT_ID
    gate_boundaries 읽기 segment ) >/dev/null 2>&1
}
o_act
check "면제된 동일성이 행위 하나로 래치에 적재된다 (종단 전)" \
  "$( { gate_disposition_latch | grep -cF 'P0-세그먼트축' || true; } )" "1"
check "아침 렌더의 처분별 집계가 런 도중에도 그 처분을 센다" \
  "$(gate_disposition_counts)" "종결 0 · 포기 0 · 면제 1"
o_segment SP3 실행중
check "면제가 풀려도 래치는 그 처분을 잊지 않는다" \
  "$( { gate_disposition_latch | grep -cF 'P0-세그먼트축' || true; } )" "1"
check "그 되돌림으로 현재 처분이 실제로 비었다 (위 단언이 공허하지 않다)" \
  "$(gate_obligation_disposition 'P0-세그먼트축')" ""

# MEMBERSHIP IS THE WHOLE IDENTITY. With a start-anchored `grep -F` the shorter
# identity read as already latched once the longer one was, and its disposition
# vanished from the counts and the terminal enumeration.
o_segment SP7 park
o_problem SP7 P0-접두긴것 읽기
o_act
o_problem SP7 P0-접두 읽기
o_act
check "긴 동일성이 먼저 래치돼도 그 접두인 짧은 동일성이 따로 래치된다" \
  "$( { gate_disposition_latch | cut -f2- | grep -cxF 'P0-접두' || true; } )" "1"
# The writer's check-then-append takes no lock, so two seats can append the
# same identity; the reader keeps the first line per identity.
printf '종결\tP0-접두\n' >> "$RUN_DIR/obligation-latch"
check "같은 동일성의 중복 줄은 첫 처분 하나로 읽힌다" \
  "$( { gate_disposition_latch | cut -f2- | grep -cxF 'P0-접두' || true; } )" "1"

# --- 7b-e. B2 — what restarts the obligation count ---------------------------
#
# The count used to restart on ANY change of the open set's digest. The closing
# verbs made that set cheap to move both ways: a parked segment walked to
# `실행중` and back makes an excusal lapse and return, and a new identity can be
# opened and closed again — each resetting the count while another obligation
# stayed blocked for good. Both are driven for more than `B2_OBLIGATION_M`
# evaluations, and the boundary must still fire.
b2_eval() { gate_disposition_latch_update; gate_b2_obligations >/dev/null 2>&1; }
n_b2()    { { grep -c '승인 id=B2-' "$LEDGER" 2>/dev/null || true; } ; }
b2_rep()  { cat "$RUN_DIR/obligation-repeat" 2>/dev/null || true; }

LEDGER="$WORK/b2a.md"; : > "$LEDGER"
RUN_DIR="$WORK/b2a-run"; mkdir -p "$RUN_DIR"
o_segment SQ1 실행중
o_problem SQ1 P0-막힘 외부상태변경
o_segment SQ2 park
o_problem SQ2 P0-토글 읽기
b2_eval
i=0
while [ "$i" -le "$B2_OBLIGATION_M" ]; do
  if [ $((i % 2)) -eq 0 ]; then o_segment SQ2 실행중; else o_segment SQ2 park; fi
  b2_eval
  i=$((i + 1))
done
if [ "$(n_b2)" != "0" ]; then
  ok "면제 가능한 의무의 세그먼트를 토글해도 막힌 의무 앞에서 B2 가 발화한다"
else
  bad "B2 토글 리셋" "세그먼트 토글 $((B2_OBLIGATION_M + 1))회 동안 B2 가 침묵했다 (계수=$(b2_rep))"
fi

LEDGER="$WORK/b2b.md"; : > "$LEDGER"
RUN_DIR="$WORK/b2b-run"; mkdir -p "$RUN_DIR"
o_segment SQ1 실행중
o_problem SQ1 P0-막힘 외부상태변경
b2_eval
b2_bind0=$(gate_boundary_binding B2)
i=0
while [ "$i" -le "$B2_OBLIGATION_M" ]; do
  o_problem SQ1 "P0-여닫이-$i" 외부상태변경
  b2_eval
  printf -- '- `의무 종결` | 의무 id=%s | 표시 동일성=P0-여닫이-%s | 처분=종결 | 세그먼트=SQ1 | 근거=A-deadbeef | 처분 시각=t | prev=x\n' \
    "$(gate_obligation_id "P0-여닫이-$i")" "$i" >> "$LEDGER"
  b2_eval
  i=$((i + 1))
done
if [ "$(n_b2)" != "0" ]; then
  ok "새 동일성을 열고 닫는 쌍을 되풀이해도 막힌 의무 앞에서 B2 가 발화한다"
else
  bad "B2 여닫이 리셋" "여닫이 $((B2_OBLIGATION_M + 1))쌍 동안 B2 가 침묵했다 (계수=$(b2_rep))"
fi
# THE BINDING DOES NOT MOVE ON THOSE PAIRS EITHER. A standing B2 question is
# withdrawn when its binding moves, and the withdrawal restarts the count — so a
# binding the pairs could move would hand the reset back one step later. Bound
# to the whole latch it moved on every pair, because each closed identity
# latches.
gate_b2_window_observe
check "여닫이 쌍은 B2 의 결속값을 움직이지 않는다 (대기 중인 B2 질문이 철회되지 않는다)" \
  "$(gate_boundary_binding B2)" "$b2_bind0"
# The positive control: closing the obligation the count was waiting on IS
# progress. Without it the two assertions above also pass against a counter
# that never restarts.
printf -- '- `의무 종결` | 의무 id=%s | 표시 동일성=P0-막힘 | 처분=종결 | 세그먼트=SQ1 | 근거=A-deadbeef | 처분 시각=t | prev=x\n' \
  "$(gate_obligation_id 'P0-막힘')" >> "$LEDGER"
# Read where the withdrawal reads it: after the latch update and the window
# record, before the count.
gate_disposition_latch_update
gate_b2_window_observe
if [ "$(gate_boundary_binding B2)" = "$b2_bind0" ]; then
  bad "B2 결속값 대조" "기다리던 의무가 닫혔는데 결속값이 그대로다 — 위 단언이 상수 위에서 통과했다"
else
  ok "기다리던 의무가 닫히면 B2 의 결속값이 움직인다 (위 단언이 공허하지 않다)"
fi
b2_eval
check "기다리던 의무가 닫히면 B2 계수가 다시 시작한다 (위 두 단언이 멈춘 계수 위에서 통과한 것이 아니다)" \
  "$(b2_rep)" "0"

o_close() {
  # o_close <동일성> — one `의무 종결` row for it, with an anchor no check reads.
  printf -- '- `의무 종결` | 의무 id=%s | 표시 동일성=%s | 처분=종결 | 세그먼트=SQ1 | 근거=A-deadbeef | 처분 시각=t | prev=x\n' \
    "$(gate_obligation_id "$1")" "$1" >> "$LEDGER"
}
b2_ids() {
  # Distinct B2 approval ids — an issue and its auto-resolution are two rows of
  # one question.
  { grep -o '승인 id=B2-[0-9a-f]*' "$LEDGER" 2>/dev/null || true; } | LC_ALL=C sort -u | gate_count
}

# A PAIR OUT OF STEP BY ONE JUDGMENT. The pairs above open and close inside one
# judgment, so the new identity is never open when the count restarts. Here each
# judgment closes the identity the PREVIOUS one opened: when the window was
# retaken from the open set on progress, the identity opened just before went
# into it, and the next judgment closing that one was progress again — the count
# went back to 0 on every judgment while `P0-막힘` stayed blocked.
LEDGER="$WORK/b2c.md"; : > "$LEDGER"
RUN_DIR="$WORK/b2c-run"; mkdir -p "$RUN_DIR"
o_segment SQ1 실행중
o_problem SQ1 P0-막힘 외부상태변경
o_problem SQ1 P0-어긋남-0 외부상태변경
b2_eval
i=0; b2c_reset=""; b2c_bind=""
while [ "$i" -le "$B2_OBLIGATION_M" ]; do
  o_problem SQ1 "P0-어긋남-$((i + 1))" 외부상태변경
  o_close "P0-어긋남-$i"
  if [ "$i" -ge 1 ]; then
    gate_disposition_latch_update; gate_b2_window_observe
    [ "$(gate_boundary_binding B2)" = "$b2c_bind" ] || b2c_reset="${b2c_reset}결속@$i "
  fi
  b2_eval
  [ "$i" -ge 1 ] && [ "$(b2_rep)" = "0" ] && b2c_reset="${b2c_reset}계수@$i "
  [ "$i" -eq 0 ] && b2c_bind=$(gate_boundary_binding B2)
  i=$((i + 1))
done
check "한 판정씩 어긋난 여닫이 쌍이 첫 쌍 뒤로 계수도 결속값도 되돌리지 못한다" "$b2c_reset" ""
if [ "$(n_b2)" != "0" ]; then
  ok "어긋난 여닫이 쌍을 되풀이해도 막힌 의무 앞에서 B2 가 발화한다"
else
  bad "B2 어긋난 쌍 리셋" "어긋난 쌍 $((B2_OBLIGATION_M + 1))회 동안 B2 가 침묵했다 (계수=$(b2_rep))"
fi
check "창이 막힌 의무만 기다린다 (새로 연 동일성이 창에 들어가지 않는다)" \
  "$(gate_b2_waiting | tr '\n' ' ')" "P0-막힘 "

# A WINDOW MADE ONLY OF AN IDENTITY THE RUN LATCH ALREADY HOLDS. An excusal
# latches, and the segment resuming reopens the obligation with its latch line
# still there. Progress read off "newly latched" could never come from it again,
# so a window taken at that moment froze: closing the obligation with `종결` was
# not progress, the binding (window less the latch) was the empty set for good,
# and after one answer every later B2 question carried that same value.
LEDGER="$WORK/b2d.md"; : > "$LEDGER"
RUN_DIR="$WORK/b2d-run"; mkdir -p "$RUN_DIR"
o_segment SQ3 park
o_problem SQ3 P0-풀린면제 읽기
b2_eval
o_segment SQ3 실행중
b2_eval
check "창에 든 의무가 이미 런 래치에 들어 있다 (이 사례가 잴 모양이다)" \
  "$( { gate_disposition_latch | cut -f2- | grep -cxF 'P0-풀린면제' || true; } )" "1"
check "그 창의 결속값이 빈 집합이 아니라 기다리는 의무다" \
  "$(gate_b2_waiting | tr '\n' ' ')" "P0-풀린면제 "
o_segment SQ4 실행중
o_problem SQ4 P0-새의무 외부상태변경
i=0
while [ "$i" -le "$B2_OBLIGATION_M" ]; do b2_eval; i=$((i + 1)); done
check "래치된 의무의 창 위에서 B2 가 한 번 발행된다 (기준선)" "$(b2_ids)" "1"
o_close P0-풀린면제
b2_eval
check "래치된 창 구성원을 종결로 닫으면 B2 계수가 다시 시작한다" "$(b2_rep)" "0"
check "창이 다 비워지면 지금 열린 의무로 다시 잡힌다" \
  "$(gate_b2_waiting | tr '\n' ' ')" "P0-새의무 "
i=0
while [ "$i" -le "$B2_OBLIGATION_M" ]; do b2_eval; i=$((i + 1)); done
check "새 창 위에서 B2 가 다시 묻는다 (한 번 답한 결속값이 뒤의 질문을 막지 않는다)" "$(b2_ids)" "2"

# A review-obligation id has the issuer's shape, `RO-` and eight hex digits. With
# no shape check a bare `RO-`, or any extension of a real id, was admitted as an
# anchor and then resolved by a substring search.
check "근거 앵커의 RO- 형태는 8자리 16진만 인정한다 (맨 RO- 와 연장 철자는 앵커가 아니다)" \
  "$(gate_obligation_evidence_anchors 'RO- 와 RO-deadbeefx 와 RO-deadbeef' | tr '\n' ' ')" "RO-deadbeef "

# --- 7b-f. The terminal enumeration names each disposed obligation -------------
#
# The morning received a COUNT of unresolved obligations and nothing else, and
# the terminal marker said not one word about them. The exemption is the one
# disposition that writes no row, so it is the only one the morning had no path
# to see at all — enumerating the two new verbs while leaving it hidden would
# make the least inspected path the most attractive one.
LEDGER="$WORK/enum.md"; : > "$LEDGER"
RUN_DIR="$WORK/enum-run"; mkdir -p "$RUN_DIR"
o_segment SE park
o_problem SE P0-열거면제 읽기
o_problem SE P0-열거종결 외부상태변경
printf -- '- `의무 종결` | 의무 id=%s | 표시 동일성=P0-열거종결 | 처분=종결 | 세그먼트=SE | 근거=A-deadbeef 에서 고쳤다 | 처분 시각=t | prev=x\n' \
  "$(gate_obligation_id 'P0-열거종결')" >> "$LEDGER"
gate_write_disposition_report
ENUM="$RUN_DIR/done-obligations"
if [ -f "$ENUM" ]; then
  ok "종단 열거가 파일로 남는다"
else
  bad "종단 열거" "$ENUM 이 없다 — 아래 단언이 전부 공허하다"
fi
case "$(cat "$ENUM" 2>/dev/null)" in
  *"처분=종결 | 근거=A-deadbeef 에서 고쳤다"*) ok "종결된 의무를 처분과 근거 앵커와 함께 이름 짓는다" ;;
  *) bad "종단 열거 종결" "$(cat "$ENUM" 2>/dev/null | tr '\n' ' ')" ;;
esac
case "$(cat "$ENUM" 2>/dev/null)" in
  *"처분=면제 | 근거=세그먼트 SE · 최고 생성 등급 읽기"*)
    ok "면제분도 열거하고, 그 근거는 면제가 실제로 읽은 두 값이다" ;;
  *) bad "종단 열거 면제" "$(cat "$ENUM" 2>/dev/null | tr '\n' ' ')" ;;
esac
# THE ONE-LINE CONTRACT IS UNTOUCHED. `done` has four consumers — the morning
# status render, the report which inserts the file whole, the watcher's banner
# body and the status line's mtime — and widening it would break the first and
# make the third vomit the list into a notification.
if [ -f "$RUN_DIR/done" ]; then
  bad "종단 한 줄 계약" "열거가 done 파일을 건드렸다 — 배너가 목록 전체를 토해낸다"
else
  ok "열거가 done 이 아니라 형제 파일로 간다 (한 줄 계약이 그대로 남는다)"
fi
check "아침 렌더용 처분별 집계가 세 처분을 갈라 센다" \
  "$(gate_disposition_counts)" "종결 1 · 포기 0 · 면제 1"

# --- 7b-g. B3 — the count stop, its window, and what it is fail-closed on ------
#
# THE BASELINE ADVANCES AND THE WINDOW KEY DOES NOT. That pair is what tells this
# design apart from B1's guard, and the two diverge at exactly one moment: the
# first evaluation after live falls to zero. A guard leaves the total unadvanced,
# so everything the stage piled up is billed to the ROUTER in one lump.
LEDGER="$WORK/b3.md"; : > "$LEDGER"
RUN_DIR="$WORK/b3-run"; mkdir -p "$RUN_DIR"
b3_act() {
  # One `exec` act graded above `읽기` FROM THE ROUTER'S SEAT — the only shape
  # the budget counts. The row carries `행위자=리드` because the total selects
  # positively on that field: a row without it is one written before the field
  # existed and contributes nothing, so a fixture row that omits it measures a
  # budget that never moves.
  printf -- '- `자율 승인` | 교대=0 | kind= | 결정=exec | 대상=repo | 세그먼트=- | 절단점=커밋 | 유도 절단점=- | 축2=워크트리쓰기 | 자격=주변 | 행위자=리드 | 근거=예산 픽스처 | prev=x\n' >> "$LEDGER"
}
b3_base() { cat "$RUN_DIR/act-budget-base" 2>/dev/null || true; }
b3_key()  { cat "$RUN_DIR/act-budget-digest" 2>/dev/null || true; }
n_b3()    { { grep -c '승인 id=B3-' "$LEDGER" 2>/dev/null || true; } ; }
# The definition is CAPTURED rather than re-typed, so restoring it below cannot
# quietly install a second copy of the real body that drifts from the original.
b3_live_real=$(declare -f gate_live_stages)

o_segment SB 실행중
b3_act
gate_b3_act_budget
check "첫 평가가 창을 열고 기준선을 지금 총수로 잡는다" "$(b3_base)" "1"
b3_key0=$(b3_key)
if [ -n "$b3_key0" ]; then
  ok "그 창의 키가 기록된다"
else
  bad "예산 창" "act-budget-digest 가 비어 있다 — 아래 단언이 잴 것이 없다"
fi

# The window key must NOT move on budget spending alone, or the counter sits
# inside its own hash input and can never fire.
i=0
while [ "$i" -lt 45 ]; do b3_act; i=$((i + 1)); done
gate_b3_act_budget
check "예산을 쓰는 것만으로는 창이 새로 열리지 않는다" "$(b3_base)" "1"
if [ "$(n_b3)" != "0" ]; then
  ok "라이브 스테이지가 없으면 예산 초과에서 경계가 발화한다 (기준선)"
else
  bad "예산 경계" "읽기 초과 exec 46회에 기준선 1 인데 침묵한다"
fi

# --- the count stop, and the moment it differs from a guard ------------------
LEDGER="$WORK/b3b.md"; : > "$LEDGER"
RUN_DIR="$WORK/b3b-run"; mkdir -p "$RUN_DIR"
o_segment SB 실행중
b3_act
gate_b3_act_budget
b3_base_pre=$(b3_base)
b3_key_pre=$(b3_key)
gate_live_stages() { printf '1'; }
i=0
while [ "$i" -lt 45 ]; do b3_act; i=$((i + 1)); done
gate_b3_act_budget
check "라이브 동안에는 경계가 발화하지 않는다" "$(n_b3)" "0"
if [ "$(b3_base)" != "$b3_base_pre" ]; then
  ok "라이브 동안 기준선이 전진한다 (스테이지가 쌓은 것을 청구하지 않는다)"
else
  bad "카운트 정지" "기준선이 그대로다 — 라이브가 끝나면 스테이지의 작업이 라우터에게 한꺼번에 청구된다"
fi
# 창 유지 대 창 리셋. The live branch writes the baseline and must not touch the
# window key: resetting the window would make launching a stage a budget-reset
# button — spend to the edge, dispatch a stage, start over. The pair is what
# makes it a discriminator, since the baseline DID move on the same call.
check "그 사이 창 키는 그대로다 (창 유지)" "$(b3_key)" "$b3_key_pre"
# THE DISCRIMINATOR ITSELF: the first evaluation after live falls to zero.
eval "$b3_live_real"
gate_b3_act_budget
if [ "$(n_b3)" = "0" ]; then
  ok "라이브가 0 으로 떨어진 직후 첫 평가에서 청구가 없다 (가드였다면 여기서 발화한다)"
else
  bad "카운트 정지 대 가드" "스테이지가 쌓은 46회를 라우터에게 청구했다 — 이것이 가드의 거동이다"
fi

# --- fail-closed on the live reading -----------------------------------------
#
# `[ "$(gate_live_stages)" != "0" ]` reads TRUE for an empty value, so losing the
# signal would STOP the count — a boundary that switches itself off when it
# cannot see is the same class of defect this slice removes.
LEDGER="$WORK/b3c.md"; : > "$LEDGER"
RUN_DIR="$WORK/b3c-run"; mkdir -p "$RUN_DIR"
o_segment SB 실행중
b3_act
gate_b3_act_budget
i=0
while [ "$i" -lt 45 ]; do b3_act; i=$((i + 1)); done
gate_live_stages() { printf ''; }
gate_b3_act_budget
if [ "$(n_b3)" != "0" ]; then
  ok "라이브 판정이 빈 값을 내도 카운트가 계속되고 경계가 발화한다"
else
  bad "fail-closed" "라이브 판정이 빈 값일 때 경계가 조용히 꺼졌다"
fi
LEDGER="$WORK/b3d.md"; : > "$LEDGER"
RUN_DIR="$WORK/b3d-run"; mkdir -p "$RUN_DIR"
o_segment SB 실행중
b3_act
gate_b3_act_budget
i=0
while [ "$i" -lt 45 ]; do b3_act; i=$((i + 1)); done
gate_live_stages() { printf 'ps: 프로세스를 읽을 수 없습니다\n'; return 1; }
gate_b3_act_budget
if [ "$(n_b3)" != "0" ]; then
  ok "라이브 판정이 오류 문자열을 내도 카운트가 계속된다 (양의 정수일 때만 멈춘다)"
else
  bad "fail-closed" "숫자가 아닌 값을 정지 신호로 읽었다"
fi
eval "$b3_live_real"

# --- the obligation component does not open a window -------------------------
#
# Not this counter's own input, but the component a run can move for free:
# opening a problem row under a new identity changes the open set, and the act
# that opens it grades `읽기` so it spends no budget at all.
LEDGER="$WORK/b3e.md"; : > "$LEDGER"
RUN_DIR="$WORK/b3e-run"; mkdir -p "$RUN_DIR"
o_segment SB 실행중
b3_act
gate_b3_act_budget
b3_base_e=$(b3_base)
o_problem SB P0-창열기 읽기
b3_act
gate_b3_act_budget
check "새 동일성의 문제 행이 예산 창을 새로 열지 않는다" "$(b3_base)" "$b3_base_e"
# The positive control. Without it the assertion above is also satisfied by a key
# that never moves at all, and then the budget would be a lifetime cap.
o_segment SB 머지됨
b3_act
gate_b3_act_budget
if [ "$(b3_base)" != "$b3_base_e" ]; then
  ok "실제 진전은 창을 새로 연다 (위 단언이 움직이지 않는 키 위에서 통과한 것이 아니다)"
else
  bad "예산 창" "세그먼트 상태가 종단으로 옮겨 갔는데 창이 그대로다"
fi

# The fixtures above pointed both at their own files; the sections below start
# from the chain section's run directory and ledger, so they are restored here
# rather than left wherever the last fixture stopped.
LEDGER="$LEDGER_SAVE"
RUN_DIR="$WORK/rundir"

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

# ---------------------------------------------------------------------------
# 8c-2. 비용 누적은 읽기와 쓰기가 한 임계구역 안에 있다
#
# 누적 행을 맞게 만드는 값은 앞 행의 총계다. 그 읽기가 잠금 밖에 있으면 read-then-act
# 이고, 동시에 종단한 두 스테이지가 같은 총계를 읽어 둘 다 `앞 총계 + 자기 것` 을
# 쓴다. 두 번째가 첫 번째를 지운다 — 깨진 행이 아니라 조용한 행이다. 런의 유일한
# 비용 수치가 아무도 그렇다고 말해 주지 않는 하한이 되고, 그 수치로 밤이 언제
# 끝나는지를 정하는 경계가 판정한다.
# ---------------------------------------------------------------------------
CLEDGER2="$WORK/cost-accum.md"
LEDGER_SAVE="$LEDGER"
LEDGER="$CLEDGER2"
: > "$CLEDGER2"
cost_total() { { grep -F '`cost`' "$CLEDGER2" || true; } | tail -1 | tr '|' '\n' \
                 | sed -n 's/^ *누적 usd=//p' | tr -d ' ' | tail -1; }
gate_append_cost 1.5 1 2026-01-01T00:00:00Z
check "첫 비용 행은 자기 값만 싣는다" "$(cost_total)" "1.5000"
gate_append_cost 2.25 2 2026-01-01T00:01:00Z
check "다음 행이 앞 총계에 더한다" "$(cost_total)" "3.7500"
gate_append_cost 0.001 3 2026-01-01T00:02:00Z
check "소수 넷째 자리까지 누적한다" "$(cost_total)" "3.7510"
check "행 셋이 남는다 (덮어쓰지 않는다)" "$( { grep -cF '`cost`' "$CLEDGER2" || true; } )" "3"
# 그리고 누적 계산이 그 함수 밖에 남아 있지 않다. 경계가 총계를 비교하려고 읽는
# 자리는 잠금이 필요 없다 — 낡은 값을 읽어도 판정이 한 행위 늦어질 뿐이다. 잠금이
# 덮어야 하는 것은 앞 총계를 읽어 거기에 더하는 자리이고, 그것이 밖에 하나라도
# 남으면 그만큼 read-then-act 가 남는다.
cost_gate="$repo_root/plugins/cc-cmds/orchestrator/gate.sh"
cost_add_all=$( { grep -cF '%.4f' "$cost_gate" || true; } )
cost_add_fn=$(awk '/^gate_append_cost\(\) \{/{on=1} on{print} on && /^}$/{exit}' "$cost_gate" \
              | { grep -cF '%.4f' || true; } )
check "누적 계산이 게이트에 두 자리뿐이다 (잠긴 갈래와 잠기지 않은 갈래)" "$cost_add_all" "2"
check "그 두 자리가 모두 누적 함수 안이다" "$cost_add_fn" "$cost_add_all"
LEDGER="$LEDGER_SAVE"

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
check "천장이 끝낸 런의 종료 행은 재킥 원인=천장 을 싣는다" \
  "$({ grep -F '결정=종료' "$ELEDGER" || true; } | { grep -cF '| 재킥 원인=천장 |' || true; })" "1"
check "종료 토큰이 천장 이다" "$(gate_end_token 2>/dev/null)" "천장"
# IDEMPOTENT BY THE MARK. A second evaluation past the ceiling must not write a
# second ending row: the first reason is the morning's account of why the night
# stopped, and a run does not end twice.
gate_b4_cost >/dev/null 2>&1
check "천장을 넘긴 두 번째 판정은 종료 행을 다시 쓰지 않는다" "$(end_rows)" "1"
# 표시는 하드 링크로 발행되고 원장 행은 경합을 이긴 쪽만 쓴다. 앞 판본은 모든
# 호출자가 행을 먼저 쓴 뒤 발행을 시도해, 한 번 끝난 런에 종료 행이 둘 남고 아침에
# 표시가 어느 쪽 것인지 말할 수 없었다.
end_mark_first=$(cat "$RUN_DIR/done")
gate_end_run B9 "다른 경계가 뒤늦게 발화했다" >/dev/null 2>&1
check "이미 끝난 런에 다른 경계가 발화해도 종료 행은 하나다" "$(end_rows)" "1"
check "표시의 첫 사유가 그대로다 (첫 사유가 참인 사유다)" "$(head -1 "$RUN_DIR/done")" "$end_mark_first"
# 종료 토큰도 첫 행의 것이다. 뒤에 같은 런에 종료 행이 더 붙어도(종료 제안 갈래는
# 표시와 무관하게 자기 행을 쓴다) 가장 이른 행이 토큰을 정한다.
gate_end_row "종료 조건 성립" "뒤늦은 제안" 해당없음 완료 >/dev/null 2>&1
check "뒤의 종료 행이 종료 토큰을 바꾸지 않는다 (가장 이른 행)" "$(gate_end_token 2>/dev/null)" "천장"
check "정상 완료 행은 재킥 원인=해당없음 과 종료 부류=완료 를 함께 싣는다" \
  "$({ grep -F '기준=종료 조건 성립' "$ELEDGER" || true; } | { grep -F '| 재킥 원인=해당없음 |' || true; } \
     | { grep -cF '| 종료 부류=완료 |' || true; })" "1"
# 지문은 결함과만 간다. 다른 토큰에 지문을 넘기면 버려지고, 닫힌 집합 밖의 토큰은
# 행을 쓰지 않고 실패한다 — 그것은 게이트의 결함이지 사람이 볼 런이 아니다.
gate_end_row "시험 결함" "x" 결함 "" "implement/S2/abc" >/dev/null 2>&1
check "결함 행은 재킥 지문을 싣는다" \
  "$({ grep -F '기준=시험 결함' "$ELEDGER" || true; } | { grep -cF '| 재킥 지문=implement/S2/abc |' || true; })" "1"
gate_end_row "시험 지문 버림" "x" 판단정지 "" "implement/S2/abc" >/dev/null 2>&1
check "결함이 아닌 행은 지문을 버린다" \
  "$({ grep -F '기준=시험 지문 버림' "$ELEDGER" || true; } | { grep -cF '재킥 지문=' || true; })" "0"
eb_rc=0; gate_end_row "시험 오타" "x" 마감됨 >/dev/null 2>&1 || eb_rc=$?
check "닫힌 집합 밖의 토큰은 실패하고 행을 쓰지 않는다" \
  "$eb_rc/$({ grep -cF '기준=시험 오타' "$ELEDGER" || true; })" "1/0"
# 이 블록이 더한 행들을 걷어 낸다 — 아래 단언들은 종료 행이 하나뿐인 원장을 센다.
grep -vF -e '기준=종료 조건 성립' -e '기준=시험 결함' -e '기준=시험 지문 버림' "$ELEDGER" > "$ELEDGER.k" \
  && mv "$ELEDGER.k" "$ELEDGER"
# 그리고 뒤에 오는 종료 제안이 그 사유를 지우지 않는다. 종단 게이트는 종료 제안을
# 면제하므로 두 기록자가 같은 파일에 닿는다 — 앞 판본의 절단 `>` 는 「종료 조건
# 성립」으로 덮어써, 사실은 비용 천장이 멈춘 밤을 아침이 그렇게 읽었다.
gate_done_note "$(printf '%s 종단 — 종료 조건 성립 · 근거 시험' "$(now_iso)")"
check "종료 제안이 경계의 사유를 지우지 않는다" "$(head -1 "$RUN_DIR/done")" "$end_mark_first"
check "그 제안도 함께 남는다" "$( { grep -cF '종료 조건 성립' "$RUN_DIR/done" || true; } )" "1"

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

# ---------------------------------------------------------------------------
# 8e. 두 번째 진전 축 — 선언된 무진전 상한이 런을 끝낸다
#
# B1 은 같은 수를 세고 묻는다. 묻는 순간 열리는 승인이 B1 자신을 억제하므로, 답이
# 오지 않는 밤에는 그 카운터가 질문을 연 값에서 얼어붙는다. 이 경계는 같은 수를
# 억제 밖에서 세고 끝낸다.
# ---------------------------------------------------------------------------
: > "$ELEDGER"
rm -f "$RUN_DIR/done" "$RUN_DIR/stagnation-digest" "$RUN_DIR/stagnation-repeat"
# 선언이 없으면 이 축은 무제한이다 — 지금까지 쓰인 모든 매니페스트의 거동이다.
sb_n=3
gate_b5_stagnation_bound >/dev/null 2>&1
check "상한이 선언되지 않으면 아무것도 세지 않는다" \
  "$(cat "$RUN_DIR/stagnation-repeat" 2>/dev/null || printf '(없음)')" "(없음)"
check "그때 런도 끝나지 않는다" "$(end_rows)" "0"
printf '**무진전 상한**: %s\n' "$sb_n" >> "$FIX_MANIFEST"
check "픽스처가 실제로 상한 줄을 얻었다 (아래가 공허하지 않다)" \
  "$( { grep -c "^\*\*무진전 상한\*\*: $sb_n\$" "$FIX_MANIFEST" || true; } )" "1"
# 같은 원장에 대고 연속으로 판정한다 — 진전 해시가 움직이지 않는 상태다.
i=0
while [ "$i" -lt "$sb_n" ]; do
  gate_b5_stagnation_bound >/dev/null 2>&1
  i=$((i + 1))
done
check "상한에 닿기 전까지는 끝내지 않는다" "$(end_rows)" "0"
check "그동안 카운터는 올라간다" "$(cat "$RUN_DIR/stagnation-repeat")" "$((sb_n - 1))"
gate_b5_stagnation_bound >/dev/null 2>&1
check "상한에 닿으면 런이 끝난다" "$(end_rows)" "1"
# 스테이지 좌석의 호출은 라우터 판정이 아니므로 이 경계를 움직이지 않는다. 그 판별이
# 없으면 구속되는 쪽의 통행량이 라우터의 상한을 채운다 — 그리고 이 경계는 묻는 것이
# 아니라 끝내므로, 잘못 세면 건강한 런이 스테이지가 도는 동안 끝난다.
#
# 쓰기 등급으로 잰다. 읽기 호출은 등급만으로도 판정에서 빠지므로 읽기로만 시험하면
# 좌석 판별을 지워도 통과한다.
rm -f "$RUN_DIR/done"; : > "$ELEDGER"
rm -f "$RUN_DIR/stagnation-digest" "$RUN_DIR/stagnation-repeat"
i=0
while [ "$i" -le "$sb_n" ]; do
  judge S9 'S9#1' '' 워크트리쓰기 x >/dev/null
  i=$((i + 1))
done
check "스테이지 좌석의 쓰기 판정은 정체 카운터를 움직이지 않는다" \
  "$(cat "$RUN_DIR/stagnation-repeat" 2>/dev/null || printf '(없음)')" "(없음)"
check "그래서 스테이지가 도는 동안 런이 끝나지 않는다" "$(end_rows)" "0"
# 대조군 — 같은 횟수를 라우터 좌석에서 부르면 끝난다. 위 둘이 「아무것도 세지 않는
# 구현」을 재고 있지 않다.
i=0
while [ "$i" -le "$sb_n" ]; do
  judge '' '' '' 워크트리쓰기 x >/dev/null
  i=$((i + 1))
done
check "대조군: 라우터 좌석의 같은 호출은 상한에 닿아 끝낸다" "$(end_rows)" "1"
rm -f "$RUN_DIR/done"; : > "$ELEDGER"
rm -f "$RUN_DIR/stagnation-digest" "$RUN_DIR/stagnation-repeat"
i=0
while [ "$i" -lt "$sb_n" ]; do
  gate_b5_stagnation_bound >/dev/null 2>&1
  i=$((i + 1))
done
gate_b5_stagnation_bound >/dev/null 2>&1
check "종료 행이 B5 를 이름으로 싣는다" \
  "$({ grep -F '결정=종료' "$ELEDGER" || true; } | { grep -c '기준=B5' || true; })" "1"
check "무진전 상한이 끝낸 런의 종료 행은 재킥 원인=무진전 을 싣는다" \
  "$({ grep -F '기준=B5' "$ELEDGER" || true; } | { grep -cF '| 재킥 원인=무진전 |' || true; })" "1"
# 진전이 있으면 카운터가 0 으로 돌아간다. 이것이 없으면 이 경계는 「판정 N회면
# 끝낸다」가 되어 건강한 런을 끝낸다.
rm -f "$RUN_DIR/done"; : > "$ELEDGER"
printf 'x\n' > "$RUN_DIR/stagnation-digest"
gate_b5_stagnation_bound >/dev/null 2>&1
check "진전이 있으면 카운터가 0 으로 돌아간다" "$(cat "$RUN_DIR/stagnation-repeat")" "0"
check "그때 런도 끝나지 않는다" "$(end_rows)" "0"
# 정수로 읽히지 않는 값은 경고하고 강제하지 않는다 — 비용 천장과 같은 처분이다.
grep -v '^\*\*무진전 상한\*\*: ' "$FIX_MANIFEST" > "$FIX_MANIFEST.s" && mv "$FIX_MANIFEST.s" "$FIX_MANIFEST"
printf '**무진전 상한**: 세 번\n' >> "$FIX_MANIFEST"
rm -f "$RUN_DIR/stagnation-digest" "$RUN_DIR/stagnation-repeat"
i=0
while [ "$i" -le "$sb_n" ]; do
  gate_b5_stagnation_bound >/dev/null 2>&1
  i=$((i + 1))
done
check "정수로 읽히지 않는 상한은 강제하지 않는다" "$(end_rows)" "0"
grep -v '^\*\*무진전 상한\*\*: ' "$FIX_MANIFEST" > "$FIX_MANIFEST.s" && mv "$FIX_MANIFEST.s" "$FIX_MANIFEST"

# ---------------------------------------------------------------------------
# 8f. 두 축이 모두 미선언인 런은 그 사실을 듣는다
#
# 매니페스트 검사는 마감이 없으면 하드 실패하고 이 두 필드에는 아무 말도 하지
# 않는다. 각각은 옳지만 겹치면, 검사를 통과한 매니페스트가 「경계가 검증됐다」로
# 읽히면서 라우터 런을 묶는 두 필드가 둘 다 비어 있을 수 있다. 필수 검사로는 고칠
# 수 없다 — 그 연언은 모든 동사에서 돌고 블록은 얼려 있어, 진행 중인 런이 다음
# 동사에서 죽는다. 할 수 있는 것은 말해 주는 것이다.
# ---------------------------------------------------------------------------
MANIFEST_SAVE="$MANIFEST"
UB="$WORK/unbounded-plan.md"
grep -v '^\*\*비용 천장\*\*: ' "$FIX_MANIFEST" > "$UB"
MANIFEST="$UB"
RUN_DIR="$WORK/rundir-unbounded"; mkdir -p "$RUN_DIR"
ub_out=$(gate_unbounded_notice 2>&1)
case "$ub_out" in
  *"declares neither"*) ok "두 축이 모두 미선언이면 그 사실을 말한다" ;;
  *) bad "미선언 고지" "아무 말도 하지 않았다: ${ub_out:-(빈 출력)}" ;;
esac
check "그때 표지가 남는다" "$([ -e "$RUN_DIR/unbounded-notice" ] && printf yes || printf no)" "yes"
ub_out2=$(gate_unbounded_notice 2>&1)
check "두 번째 호출은 아무 말도 하지 않는다 (행위마다 경고하면 읽히지 않는다)" "$ub_out2" ""
# 숫자로 읽히지 않는 값은 미선언으로 센다. 이것이 없으면 `$50` 짜리 천장이 고지를
# 억누르면서 경계는 하나도 서지 않는다 — 고지가 존재하는 이유인 바로 그 조합이다.
rm -f "$RUN_DIR/unbounded-notice"
printf '**비용 천장**: $50\n' >> "$UB"
ub_out3=$(gate_unbounded_notice 2>&1)
case "$ub_out3" in
  *"declares neither"*) ok "숫자로 읽히지 않는 천장은 미선언으로 센다" ;;
  *) bad "미선언 고지" "강제되지 않는 값을 선언으로 셌다: ${ub_out3:-(빈 출력)}" ;;
esac
# 대조군 — 하나라도 유효하게 선언되면 침묵한다. 이것이 없으면 위 셋은 「항상
# 경고하는 구현」과 구별되지 않는다.
rm -f "$RUN_DIR/unbounded-notice"
grep -v '^\*\*비용 천장\*\*: ' "$UB" > "$UB.c" && mv "$UB.c" "$UB"
printf '**무진전 상한**: 9\n' >> "$UB"
ub_out4=$(gate_unbounded_notice 2>&1)
check "한 축이라도 유효하게 선언되면 침묵한다" "$ub_out4" ""
check "그때 표지도 남기지 않는다" "$([ -e "$RUN_DIR/unbounded-notice" ] && printf yes || printf no)" "no"
MANIFEST="$MANIFEST_SAVE"
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
# not one of the classes that hand risk to the user. A judgment with no class, a
# class outside the vocabulary, or one of those classes does not wait either — it
# ends as a refusal.
# ---------------------------------------------------------------------------
J_MANIFEST="$WT/plan-r2.md"
J_LEDGER="$WT/docs/pipeline-run/R2.md"
# Only the run-id tokens move — the id before `;` or `.` and the id that ends a
# line. The records also carry `$WT`, which sits under a `mktemp` name whose
# random suffix can hold `R1`; a bare `s/R1/R2/g` would rewrite that path too.
sed -e 's/R1\([;.]\)/R2\1/g' -e 's/R1$/R2/' "$FIX_MANIFEST" > "$J_MANIFEST"
sed -e 's/R1\([;.]\)/R2\1/g' -e 's/R1$/R2/' "$WT/docs/pipeline-grant/R1.md" > "$WT/docs/pipeline-grant/R2.md"
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

# The classes that hand risk to the user are resolved as a refusal: the run
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
# 9b. A quoted id does not answer for that id either
#
# The readers that list ANSWERED judgments — the snapshot array, the answer
# door and the driver's re-dispatch pick — ask three things of the ledger: the
# approval's last row is `승인`, its issuing row is `절단점=판단`, and no
# `자율 승인` row spends it. Each of the three was a substring match, so a
# judgment that cites another's id in its `기준` spoke for the cited id on all
# three. Both polarities are pinned, on a ledger of their own, with the rows in
# the shape the issuer and `close` write them:
#
#   - a REFUSED judgment cited by a later judgment that closed `승인` must not
#     become an answered candidate;
#   - an ANSWERED judgment cited by a later judgment that closed `거부`, and by
#     a spent row whose free text quotes `해소 승인=<id>`, must stay one.
# ---------------------------------------------------------------------------
QLEDGER="$WORK/quoted-answers.md"
LEDGER_SAVE="$LEDGER"
RUN_DIR_SAVE="${RUN_DIR:-}"
LEDGER="$QLEDGER"
: > "$QLEDGER"
RUN_DIR="$WORK/rundir-quoted"; mkdir -p "$RUN_DIR/answer" "$RUN_DIR/log"
qj_issue() {
  # qj_issue <승인 id> <막는 세그먼트> <질문 문면>
  gate_append '승인' "승인 id=$1" "상태=대기" "대상=repo" "절단점=판단" "막는 세그먼트=$2" \
    "질문 문면=$3"
}
qj_close() {
  # qj_close <승인 id> <상태> <질문 문면> <답> — `close` writes the answer file
  # before it branches on the disposition, so a refusal leaves one too.
  printf '%s\n' "$4" > "$RUN_DIR/answer/$1.md"
  gate_append '승인' "승인 id=$1" "상태=$2" "질문 문면=$3" "답변 문면=$4" \
    "해소 시각=2026-01-01T00:00:00Z" "응답 토큰=t-$1" \
    "답변 다이제스트=$(printf '%s' "$4" | shasum -a 256 | cut -d' ' -f1)" "사이드카 앵커=-"
}
qj_ids() { printf '[%s]' "$(gate_answered_judgments_json)" | jq -r '.[].id' 2>/dev/null; }

qj_issue QJ-REFUSED "S4:QS:1" "거부될 물음"
qj_close QJ-REFUSED 거부 "거부될 물음" "하지 않는다"
qj_issue QJ-CITING "S4:QT:1" "승인 id=QJ-REFUSED 참고"
qj_close QJ-CITING 승인 "승인 id=QJ-REFUSED 참고" "진행한다"
qj_issue QJ-ANSWERED "S4:QU:1" "답이 올 물음"
qj_close QJ-ANSWERED 승인 "답이 올 물음" "그렇게 한다"
qj_issue QJ-QUOTER "S4:QV:1" "승인 id=QJ-ANSWERED 참고"
qj_close QJ-QUOTER 거부 "승인 id=QJ-ANSWERED 참고" "하지 않는다"
# The citing judgment's answer is spent, by a row whose free text quotes the
# answered id's spend field — so neither citing judgment is itself a candidate,
# and the only candidates left are the ones the quoting decides.
gate_append '자율 승인' "기준=해소 승인=QJ-ANSWERED 참고" "해소 승인=QJ-CITING"
: > "$RUN_DIR/log/S4:QT:1.json"
: > "$RUN_DIR/log/S4:QU:1.json"

check "인용하는 판단의 두 행이 인용된 id 를 문면에 싣는다 (시험이 공허하지 않다)" \
  "$( { grep -F '질문 문면=승인 id=QJ-REFUSED 참고' "$QLEDGER" || true; } | gate_count)" "2"
check "소진 행의 자유 문면이 답한 판단의 소진 필드를 인용한다 (시험이 공허하지 않다)" \
  "$( { grep -F '기준=해소 승인=QJ-ANSWERED 참고' "$QLEDGER" || true; } | gate_count)" "1"

# Polarity one: a refusal is not an answer because a later judgment quoted it.
check "거부된 판단은 그것을 인용한 판단이 승인으로 닫혀도 답이 온 판단 배열에 오르지 않는다" \
  "$(qj_ids | { grep -xF QJ-REFUSED || true; } | gate_count)" "0"
if declare -F answered_judgment_stage >/dev/null; then
  ok "드라이버의 재파견 선택 함수가 소싱으로 로드됐다"
else
  bad "재파견 선택" "answered_judgment_stage 가 정의되지 않았다 — 아래 행들은 잴 것이 없다"
fi
check "드라이버도 인용한 판단의 스테이지에 거부된 판단을 답으로 다시 붙이지 않는다" \
  "$(answered_judgment_stage QT S4 2>/dev/null)" ""

# Polarity two: an answer is not hidden because a later judgment quoted it.
check "답한 판단은 그것을 인용한 판단이 거부로 닫혀도 답이 온 판단 배열에 남는다" \
  "$(qj_ids | { grep -xF QJ-ANSWERED || true; } | gate_count)" "1"
qj_rc=0
gate_answer_servable QJ-ANSWERED 2>/dev/null || qj_rc=$?
check "답 문도 인용한 판단의 거부를 그 답의 상태로 읽지 않는다" "$qj_rc" "0"
check "드라이버도 답한 판단을 그 스테이지에 다시 붙인다" \
  "$(answered_judgment_stage QU S4 2>/dev/null)" "QJ-ANSWERED S4:QU:1"
# Spent-ness is still read — the whole-field pin did not turn the test off.
check "실제로 소진된 판단은 여전히 배열에 오르지 않는다" \
  "$(qj_ids | { grep -xF QJ-CITING || true; } | gate_count)" "0"

# A 사람-결정 refusal IS listed, with its state beside it, because the router
# parks the segment on it; the driver's re-dispatch pick still takes only `승인`,
# so the refusal is never handed back to the stage as an answer to carry out.
gate_append '승인' "승인 id=QJ-PERSON" "상태=대기" "대상=repo" "절단점=판단" "막는 세그먼트=S4:QW:1" \
  "질문 문면=사람이 정할 물음" "판단 부류=사람-결정"
qj_close QJ-PERSON 거부 "사람이 정할 물음" "하지 않는다"
: > "$RUN_DIR/log/S4:QW:1.json"
check "사람-결정 판단의 거부는 답이 온 판단 배열에 state 거부로 오른다" \
  "$(printf '[%s]' "$(gate_answered_judgments_json)" | jq -r '.[] | select(.id == "QJ-PERSON") | .state' 2>/dev/null)" "거부"
check "답한 판단의 원소는 state 승인을 싣는다" \
  "$(printf '[%s]' "$(gate_answered_judgments_json)" | jq -r '.[] | select(.id == "QJ-ANSWERED") | .state' 2>/dev/null)" "승인"
check "부류 없는 판단의 거부는 여전히 배열에 오르지 않는다" \
  "$(qj_ids | { grep -xF QJ-REFUSED || true; } | gate_count)" "0"
check "드라이버는 사람-결정 거부를 그 스테이지에 답으로 다시 붙이지 않는다" \
  "$(answered_judgment_stage QW S4 2>/dev/null)" ""

LEDGER="$LEDGER_SAVE"
RUN_DIR="$RUN_DIR_SAVE"

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

# ---------------------------------------------------------------------------
# 11. An answer to a shift's halt record is listed, and the next shift spends it
#
# NO STAGE TAKES IT UP. A shift's record names a site table option the next
# shift carries out itself, so waiting for a `stage-result` of the key would
# list the answer forever once the shift parked the segment or retried an act
# that dispatches nothing. What spends it is the first later row that carries
# the option out: the key's `segment` row, an act a shift took on the key, or a
# resolution of a block anchored on it. A stage's record keeps its one consumer.
# ---------------------------------------------------------------------------
SHR_DIR=$(mktemp -d "${TMPDIR:-/tmp}/cc-snap-shifthalt.XXXXXX")
SHR_LEDGER="$SHR_DIR/ledger.md"
SHR_REC="$SHR_DIR/halt/shift/S5#1.md"
SHR_STAGE="$SHR_DIR/halt/S6#1.md"
mkdir -p "$SHR_DIR/halt/shift"
printf '%s\n' '교대 기록' > "$SHR_REC"
printf '%s\n' '스테이지 기록' > "$SHR_STAGE"
shr_fresh() {  # shr_fresh — the ledger with the shift's row and the two answers
  {
    printf -- '- `blocked` | 교대=1 | 대상=t | 스코프=cone | 원인=막힘 | 앵커 세그먼트=S5 | 사유=교대 정지 — 병합 거절 | 근거=x | 중단 기록=%s | 기록 다이제스트=abc | 자리=병합 거절 | prev=0\n' "$SHR_REC"
    printf -- '- `중단 답` | 교대=0 | 세그먼트=S5 | 중단 기록=%s | 스킬=autopilot-router-shift | 선택지=재시도 | 답한 주체=사람 | 근거=사람이 재시도를 고름 | prev=0\n' "$SHR_REC"
    printf -- '- `중단 답` | 교대=0 | 세그먼트=S6 | 중단 기록=%s | 스킬=implement-unattended | 선택지=reject | 답한 주체=사람 | 근거=사람이 기각 | prev=0\n' "$SHR_STAGE"
  } > "$SHR_LEDGER"
}
shr_read() {  # shr_read — `[[segment, option], …]` of answered_halts on that ledger
  local frag
  frag=$(CC_GATE_SOURCE_ONLY=1 bash -c '
    . "$1" >/dev/null 2>&1; set +e +u
    LEDGER="$2"; MANIFEST=/nonexistent; RUN_ID=R; RUN_DIR="$3"
    gate_answered_halts_json 2>/dev/null' _ "$GATE" "$SHR_LEDGER" "$SHR_DIR")
  printf '[%s]' "$frag" | jq -c '[.[] | [.segment, .option]]'
}
shr_fresh
check "교대 기록의 중단 답이 answered_halts 에 오른다" "$(shr_read)" '[["S5","재시도"],["S6","reject"]]'
printf -- '- `stage-result` | 교대=1 | 세그먼트=S7 | 스테이지=S7 | 종류=implement | 실행 버전=1 | 종단 부류=정상 완료 | prev=0\n' >> "$SHR_LEDGER"
printf -- '- `자율 승인` | 교대=1 | kind=segment | 결정=act | 대상=t | 세그먼트=S5 | 절단점=커밋 | 행위자=스테이지 | 근거=x | prev=0\n' >> "$SHR_LEDGER"
check "다른 키의 행과 스테이지의 행위는 교대 기록의 답을 소비하지 않는다" "$(shr_read)" '[["S5","재시도"],["S6","reject"]]'
printf -- '- `segment` | 교대=2 | id=S6 | 워크트리=/x | 상태=park | prev=0\n' >> "$SHR_LEDGER"
check "스테이지 기록의 답은 세그먼트 행으로 소비되지 않는다" "$(shr_read)" '[["S5","재시도"],["S6","reject"]]'
printf -- '- `segment` | 교대=2 | id=S5 | 워크트리=/x | 상태=park | prev=0\n' >> "$SHR_LEDGER"
check "다음 교대의 세그먼트 행이 교대 기록의 답을 소비한다" "$(shr_read)" '[["S6","reject"]]'
shr_fresh
printf -- '- `자율 승인` | 교대=2 | kind=merge | 결정=act | 대상=t | 세그먼트=S5 | 절단점=커밋 | 행위자=교대 | 근거=x | prev=0\n' >> "$SHR_LEDGER"
check "교대가 그 키에 한 행위가 교대 기록의 답을 소비한다" "$(shr_read)" '[["S6","reject"]]'
shr_fresh
printf -- '- `blocked` | 교대=2 | 대상=t | 스코프=cone | 원인=해소 | 앵커 세그먼트=S5 | 사유=재시도 | prev=0\n' >> "$SHR_LEDGER"
check "그 키에 앵커를 둔 막힘의 해소가 교대 기록의 답을 소비한다" "$(shr_read)" '[["S6","reject"]]'
shr_fresh
printf -- '- `stage-result` | 교대=2 | 세그먼트=S5 | 스테이지=S5 | 종류=implement | 실행 버전=1 | 종단 부류=정상 완료 | prev=0\n' >> "$SHR_LEDGER"
check "그 키의 stage-result 도 교대 기록의 답을 소비한다" "$(shr_read)" '[["S6","reject"]]'
rm -rf "$SHR_DIR"

# ---------------------------------------------------------------------------
# 12. A carried halt answer — the sentences no fixture can execute
#
# A stand-in CLI cannot recompute a halt's question, so what a re-entered
# skill does when the question it computes differs from the card's is held
# here as text, and its behaviour is left to the deployed run. The same holds
# for the routing copies that tell a shift which exit of the carry act sends
# it where, and for the seat and lead copies that keep an answer carried over
# to the next run from being asked again: each sentence is the only carrier of
# its rule, and a rewrite that drops one leaves nothing failing.
# ---------------------------------------------------------------------------
RC_SKILL="$repo_root/plugins/cc-cmds/skills/design-reconverge/SKILL.md"
AU_SKILL="$repo_root/plugins/cc-cmds/skills/design-audit-unattended/SKILL.md"
# The audit's answer handling lives in the sidecar's §4.1: the skill's own
# bytes count toward its lead's pre-dispatch read ceiling.
AU_ANS="$repo_root/plugins/cc-cmds/skills/_common/pipeline-sidecar.md"
SEAT_REF="$AP_REFS/act2-seat.md"
has(){ if grep -qF -- "$2" "$1"; then echo 예; else echo 아니오; fi; }
check "design-audit-unattended: 재개와 운반 재진입은 사이드카 4.1 을 읽는다" \
  "$(has "$AU_SKILL" "or started with \`CC_PIPELINE_HALT_ANSWER\` set (a fresh session carrying a person's answer to an earlier attempt's synthesis halt), Reads \`\${CLAUDE_SKILL_DIR}/../_common/pipeline-sidecar.md\` §4.1 before anything else")" 예
check "design-audit-unattended: 종합 정지 전에 사이드카 4.1 의 조정 처분을 쓴다" \
  "$(has "$AU_SKILL" "Read \`\${CLAUDE_SKILL_DIR}/../_common/pipeline-sidecar.md\` §4.1 and write its \`## 조정 처분\` block into the report")" 예
for f in "$RC_SKILL" "$AU_ANS"; do
  b=$(basename "$(dirname "$f")")
  check "$b: 재진입 때 계산한 질문이 다르면 새 정지 기록을 쓴다" \
    "$(has "$f" "do not apply the answer: write a new halt record for the question computed now, with the card's path in its \`관측 상세\`.")" 예
  check "$b: 운반된 기록은 다시 쓰지 않는다" \
    "$(has "$f" "**Never rewrite the carried record**")" 예
  check "$b: 카드의 기록 다이제스트를 대조한다" \
    "$(has "$f" "**Read the card and check the digest.**")" 예
done
check "design-reconverge: 기준선은 디스크가 아니라 기록에서 읽는다" \
  "$(has "$RC_SKILL" "**Take the baselines from the record, never from the disk.**")" 예
check "design-reconverge: 정지 기록이 범위와 두 기준선을 싣는다" \
  "$(has "$RC_SKILL" "- \`범위=<the scope as handed>\` — for an \`R<n>\` scope exactly \`범위=R<n>\`.")" 예
# 사전 구속 표면 다이제스트는 스테이지가 손으로 거르는 값이 아니라 게이트가 드라이버의 계산으로
# 내는 값이다 — 1단계가 쓰기 전에 그 명령으로 재고, 4단계의 사후 쪽도 같은 명령으로 잰다.
check "design-reconverge: 1단계가 쓰기 전에 게이트 binding-digest 로 사전 다이제스트를 잰다" \
  "$(has "$RC_SKILL" "record \`사전 sha256\` (\`shasum -a 256\`) and \`사전 구속 표면 다이제스트\` — the one line \`<gate absolute path> binding-digest --manifest \"\$CC_PIPELINE_MANIFEST\" -- <document path>\` prints")" 예
check "design-reconverge: 4단계 사후 다이제스트도 같은 명령이다" \
  "$(has "$RC_SKILL" "and the after side is what \`<gate absolute path> binding-digest --manifest \"\$CC_PIPELINE_MANIFEST\" -- <document path>\` prints after the last edit")" 예
check "design-reconverge: 정지 기록의 사전 다이제스트는 1단계 값이다" \
  "$(has "$RC_SKILL" "- \`사전 구속 표면 다이제스트=<64 hex>\` — Step 1's \`사전 구속 표면 다이제스트\`: the gate's \`binding-digest\` output")" 예
check "design-audit-unattended: 1–5단계 건너뛰기는 문서 sha256 에 묶인 처분에서만" \
  "$(has "$AU_ANS" "**Skip Steps 1–5 only on a disposition bound to the document's bytes.**")" 예
check "design-audit-unattended: 종합 정지 전에 조정 처분과 조정 뒤 sha256 을 쓴다" \
  "$(has "$AU_ANS" "then \`**조정 뒤 문서 sha256**: <64 hex>\`")" 예
check "교대 계약: 정지 답은 운반 act 로 낸다" \
  "$(has "$RS_CORPUS" "--carry-answer <line> \\")" 예
check "교대 계약: --resume 재부착은 19 뒤와 좌석 실행 정지의 답에만" \
  "$(has "$RS_CORPUS" "**Re-attach with \`--resume\` only after exit 19 on an answer of this run, or for an answer to a \`좌석 실행\` stop item 2 sent here.**")" 예
# 게이트는 좌석 실행 정지의 운반을 스텝 문면만으로 거절하므로, 계약도 답한 주체나
# 선택지가 아닌 스텝으로 갈라야 사람이 한 답이 exit 3 으로 빠지지 않는다.
check "교대 계약: 좌석 실행 정지의 답은 답한 주체와 무관하게 운반 act 없이 --resume 으로 간다" \
  "$(has "$RS_CORPUS" "When the step begins with \`Step 3 잔여 검증 좌석 실행\` or \`Step 3 게이트 도달 좌석 실행\`, whoever answered and whatever the option, the halted session is the one that reads the answer")" 예
check "교대 계약: 좌석 실행 정지 갈래가 게이트가 거절하는 두 스텝 접두와 같다" \
  "$(has "$GATE" "'Step 3 잔여 검증 좌석 실행'*|'Step 3 게이트 도달 좌석 실행'*)")" 예
check "교대 계약: 좌석 실행 답 갈래가 운반 act 로 넘기는 문장보다 앞선다" \
  "$(awk '/When the step begins with `Step 3 잔여 검증 좌석 실행`/{a=NR} /Every other `재부착` answer goes to item 3\./{b=NR} END{print (a && b && a<=b) ? "예" : "아니오"}' "$RS_CORPUS")" 예
check "사이드카: 좌석 실행 정지는 사람이 답해도 --resume 으로 재부착한다" \
  "$(has "$AU_ANS" "whether the seat ran the record or a person answered it: the carry act refuses an answer to it on its step alone")" 예
check "교대 계약: 운반 act 의 16 은 답이 이월일 때 이월이고 종료 행이 있으면 종단" \
  "$(has "$RS_CORPUS" "\`이월\`: when the run has no run-scope end row, end with \`handoff 사유=이월\` once nothing else is dispatchable; when it has one (the carry came after the deadline closed the run), end with \`handoff 사유=종단\`")" 예
# 게이트는 이월 행 없이도 운반 act 를 16 으로 돌려준다 — 설정 park, stage-wait 행 기록 거부,
# 마감 아닌 새 PARK, 어긋난 라우팅 가드 기록, 정체 임계를 못 읽는 대기. 그래서 세 사본 모두 16 을 답의 state 로 가른다.
check "교대 계약: 운반 act 의 16 은 답이 열림이면 이월 행 없는 park 이고 중단으로 끝낸다" \
  "$(has "$RS_CORPUS" "\`열림\`: dispatch nothing on the key and do not carry the answer again in this shift; end with \`handoff 사유=중단\` once nothing else is dispatchable, naming the record and the park row's \`사유\` in \`막힌 지점\`")" 예
check "교대 계약: 열림 답은 뒤 교대가 다시 운반한다" \
  "$(has "$RS_CORPUS" "The element stays \`열림\` in \`answered_halts[]\`, so a later shift carries it again")" 예
check "교대 계약: 운반 시도의 대기 감독자가 낸 16 도 답의 state 로 가른다" \
  "$(has "$RS_CORPUS" "when the attempt carried a halt answer, tell it apart by the answer's \`state\` as a carry act's \`16\` is")" 예
check "교대 계약: 열림 답의 중단 인계는 재질문 가드에 걸리지 않는다" \
  "$(has "$RS_CORPUS" "do not refuse it, because this answer is \`열림\`, not carried over")" 예
check "교대 계약: 종료 코드 표의 16 행도 운반 act 의 16 을 답의 state 로 가른다" \
  "$(has "$RS_CORPUS" "**A \`16\` from a carry act (\`--carry-answer\`) is told apart by the answer's state**: read the snapshot again and take the \`answered_halts[]\` element by its \`line\`.")" 예
check "좌석 사본: 운반 act 의 16 을 답의 state 로 가른다" \
  "$(has "$SEAT_REF" "**A 16 from a carry act (\`--carry-answer\`) is told apart by the answer's state** in the snapshot's \`answered_halts[]\`.")" 예
check "좌석 사본: 열림 답의 16 은 이월 행 없는 park 이다" \
  "$(has "$SEAT_REF" "\`state\` \`열림\` → it is that park: the gate wrote no \`이월\` row")" 예
# 운반 상한(18)에 걸린 기록은 답이 있어 좌석의 질문 목록에 들지 않고, 다시 물어 받은 새 답도
# 같은 런에서는 다시 18 이다 — 사람에게 상한을 알리는 것은 이 문단뿐이다. 상한 행과 park 행은
# act 범위라 스냅숏 blocked[] 에 실리지 않으므로, 좌석은 교대가 막힌 지점에 적은 사유로 읽는다.
check "좌석 사본: 18 행은 상한을 묻지 않고 알린다" \
  "$(has "$SEAT_REF" "do not carry that answer again; the seat neither asks the record again nor answers it with the seat, and tells the person of the cap")" 예
check "좌석 사본: 열림 16 도 사람에게 알린다" \
  "$(has "$SEAT_REF" "and tells the person of the park as 「A carry the gate parked or capped」 below says")" 예
check "좌석 사본: 운반 park·상한은 사람에게 알리고 묻지 않는다" \
  "$(has "$SEAT_REF" "**A carry the gate parked or capped is told to the person, not asked.**")" 예
check "좌석 사본: 고지는 스냅숏 blocked[] 가 아니라 막힌 지점에서 사유를 읽는다" \
  "$(has "$SEAT_REF" "the seat reads it there, because the snapshot's \`blocked[]\` carries no act-scope row")" 예
check "교대 계약: 18 은 상한 행의 사유를 막힌 지점에 적는다" \
  "$(has "$RS_CORPUS" "naming the record and the cap row's \`사유\` in \`막힌 지점\` — the seat reads the cap from that field")/$(has "$RS_CORPUS" "naming the halt record and the cap row's \`사유\` in \`막힌 지점\`")" "예/예"
# 결과가 정해진 재수렴 정지의 답은 세션 없이 게이트가 정산한다. 교대는 정산을 먼저 내고 거절될
# 때만 운반하며, 정산 행은 스트림이 없으므로 4·5번의 뒷부분이 그 행을 재수렴 행으로 읽어야 한다.
check "교대 계약: 기계 정산 줄의 답은 정산 act 를 먼저 낸다" \
  "$(has "$RS_CORPUS" "3. **Settle the answer first when its record already fixed the outcome.**")/$(has "$RS_CORPUS" "-- '중단 답 줄=<line>'")" "예/예"
check "교대 계약: 정산이 3 이면 운반하고 0 이면 운반하지 않는다" \
  "$(has "$RS_CORPUS" "Exit \`3\` → the gate found one of its checks unmet and wrote nothing; the answer is still open, so carry it below.")/$(has "$RS_CORPUS" "and that row took the answer up: no session runs, so carry nothing")" "예/예"
check "교대 계약: 정산 문단이 운반 act 문단보다 앞선다" \
  "$(awk '/Settle the answer first when its record already fixed the outcome/{a=NR} /Otherwise carry the answer, and let the gate decide whether the halted session takes it/{b=NR} END{print (a && b && a<b) ? "예" : "아니오"}' "$RS_CORPUS")" 예
check "교대 계약: 4·5번 뒷부분이 정산= 행을 종단 술어 참인 재수렴 행으로 읽는다" \
  "$( { grep -cF "**A row carrying \`정산=\` is the gate's settlement of item 3**: it has no stream, its terminal predicate reads as present, and its verdict is the row's \`재수렴 판정\`." "$RS_CORPUS" || true; } | tr -d ' ')" 2
check "교대 계약: 5번의 마지막 중단 답 걷기는 재수렴에 건넨 답을 지난다" \
  "$(has "$RS_CORPUS" "and whose last \`중단 답\` row, walking back past the answers whose \`스킬\` is \`design-reconverge\`, names a record matched by item 2 for this item")" 예
check "좌석 사본: 정산 먼저, 정산 행이 없으면 어느 거절이든 운반한다" \
  "$(has "$SEAT_REF" "(\`act --kind halt-settle --segment <key>\`, the same \`<key>\` as above and never \`-\`: settle first, and carry the answer whenever the gate writes no settlement row — a refused argument as well as an unmet check;")" 예
# 런 범위 단계의 답 행은 세그먼트 칸에 스텝 id 를 싣고, 게이트는 `--segment -` 를 행을 읽기 전에
# exit 2 로 거절한다 — 정산 명령 틀이 `-` 를 허용하면 감사 키의 답은 한 번도 정산되지 않는다.
check "교대 계약: 정산의 --segment 는 원소의 segment 이고 - 가 아니다" \
  "$(has "$RS_CORPUS" "--kind halt-settle --target <alias> --segment <segment> \\")/$(has "$RS_CORPUS" "\`<segment>\` is the element's \`segment\` verbatim — the segment id, or for a run-scope step the step id, never \`-\`")" "예/예"
check "교대 계약: 정산의 0·3·4 밖 exit 은 3 처럼 운반한다" \
  "$(has "$RS_CORPUS" "Any other exit — a refused argument (\`2\`) included — wrote no row either, so read it as \`3\` and carry the answer below.")" 예
check "design-reconverge: 기계 정산 줄은 기록을 가진 두 범위에서만 쓴다" \
  "$(has "$RC_SKILL" "- the scope is \`감사 종합 요구 <record>\` or \`구속 티어 이탈 <record>\`. Never for an \`R<n>\` scope")" 예
check "스냅숏: blocked[] 접기는 act 범위 행을 싣지 않는다" \
  "$(has "$(dirname "$GATE")/liveness.sh" 'else if (bscope[b] == "cone" && banchor[b] != "" && !(banchor[b] in seg)) step = 1')" 예
check "좌석 사본: 상한 고지는 세 상한 사유로 고른다" \
  "$(has "$SEAT_REF" "When that \`사유\` begins \`중단 답 라우팅 — 세션 전에 세 번 죽었다\`, \`중단 답 라우팅 — 새 파견이 같은 질문에 다시 멈췄다\` or \`중단 답 라우팅 — 들인 답을 이 런에서 운반할 수 없다\`, it is the carry's cap")" 예
check "좌석 사본: 상한 고지는 새 답도 같은 상한에 걸린다고 말한다" \
  "$(has "$SEAT_REF" "asking again and taking a new answer meets the same cap")" 예
check "좌석 사본: 상한 사유는 게이트가 쓰는 두 문면과 같다" \
  "$(has "$GATE" "\"중단 답 라우팅 — 세션 전에 세 번 죽었다\"")/$(has "$GATE" "\"중단 답 라우팅 — 새 파견이 같은 질문에 다시 멈췄다\"")" "예/예"
# 마감 뒤의 이월 인계는 그 act 에서 런을 끝낼 때만 받아지고, 받아지지 않으면 교대가 붙드는 것을
# 이름 짓는 사유로 인계한다 — 그 갈래를 싣는 것은 이 문장뿐이다.
check "교대 계약: 마감 뒤 이월은 끝맺을 때만 받고 그 act 에서 끝낸다" \
  "$(has "$RS_CORPUS" "**Past the deadline it takes \`이월\` only when nothing but those answers holds the run, and ends the run with \`마감\` in the same act**")" 예
check "교대 계약: 마감 뒤 이월이 거절되면 붙드는 것을 이름 짓는 사유로 인계한다" \
  "$(has "$RS_CORPUS" "hand off with the reason that names it: \`대기\` for a live stage or supervisor or a CI wait, \`중단\` for anything else, and the gate does not refuse that \`중단\`.")" 예
check "교대 계약: 재질문 가드 1 은 끝맺음과 같은 판정이다" \
  "$(has "$RS_CORPUS" "the gate refuses \`중단\` when those answers are all that holds the run — the same judgment the ending past the deadline reads —")" 예
check "교대 계약: 종료 코드 표에 18 행이 있다" "$(grep -c '^| `18` | a carry act' "$RS_CORPUS")" 1
check "교대 계약: 종료 코드 표에 19 행이 있다" "$(grep -c '^| `19` | only for an answer of this run' "$RS_CORPUS")" 1
check "좌석 사본: 종료 코드 표에 18 행이 있다" "$(grep -c '^| 18 | a carry act' "$SEAT_REF")" 1
check "좌석 사본: 종료 코드 표에 19 행이 있다" "$(grep -c '^| 19 | only for an answer of this run' "$SEAT_REF")" 1
check "좌석 사본: 이월된 답은 다시 묻지 않는다" \
  "$(has "$SEAT_REF" "**A record already answered is not asked again because its answer was carried over**")" 예
for pair in "autopilot-router-shift:$RS_CORPUS" "references:$AP_ROUTER"; do
  f=${pair#*:}
  check "${pair%%:*}: 설계 단계 정지에서 이월 답은 다시 묻지 않는다" \
    "$(has "$f" "**An answer already carried over is not asked again**: when the element naming the step reads \`state\` \`이월\`")" 예
done
# 구현·설계 토론·리드 단독 설계·베이스 분할의 정지도 새 세션에 카드로 닿는다. 카드를 받은 세션이
# 디스크에서 멈춘 자리로 들어가는 규칙과, 저장 뒤 정지의 새 파견을 막는 문서 존재 가드의 면제는
# 대역 CLI 가 실행할 수 없어 문면으로만 남는다.
IM_SKILL="$repo_root/plugins/cc-cmds/skills/implement-unattended/SKILL.md"
DD_SKILL="$repo_root/plugins/cc-cmds/skills/design-discuss-unattended/SKILL.md"
DS_SKILL="$repo_root/plugins/cc-cmds/skills/design-solo-unattended/SKILL.md"
DB_SKILL="$repo_root/plugins/cc-cmds/skills/design-base-unattended/SKILL.md"
for f in "$IM_SKILL" "$DD_SKILL" "$DS_SKILL" "$DB_SKILL"; do
  b=$(basename "$(dirname "$f")")
  check "$b: 운반 재진입 문단이 있다" "$(has "$f" "**Re-entered with a carried answer")" 예
  check "$b: 카드의 기록 다이제스트를 대조한다" "$(has "$f" "**Read the card and check the digest.**")" 예
  check "$b: 운반된 기록은 다시 쓰지 않는다" "$(has "$f" "**Never rewrite the carried record**")" 예
done
for f in "$IM_SKILL" "$DS_SKILL"; do
  b=$(basename "$(dirname "$f")")
  check "$b: 재진입 때 계산한 질문이 다르면 새 정지 기록을 쓴다" \
    "$(has "$f" "do not apply the answer: write a new halt record for the question computed now, with the card's path in its \`관측 상세\`.")" 예
done
check "design-discuss-unattended: 재진입 때 계산한 질문이 다르면 카드를 적은 새 정지 기록을 쓴다" \
  "$(has "$DD_SKILL" "a different computed question gets a new halt record naming the card")" 예
check "design-base-unattended: 분할 재진입은 처음 실패한 자리가 다르면 새 정지 기록을 쓴다" \
  "$(has "$DB_SKILL" "do not apply the answer: write a new halt record for the site reached now, with the card's path in its \`관측 상세\`.")" 예
check "implement-unattended: 재진입은 디스크의 계획 행·워크트리·설계 문서에서 멈춘 스텝으로 들어간다" \
  "$(has "$IM_SKILL" "from what is on disk — the ledger's plan row that decided the phase above, the segment worktree and the design document — and apply the card's option there")" 예
check "implement-unattended: 구속 티어 재수렴 답과 좌석 실행 정지는 카드로 오지 않는다" \
  "$(has "$IM_SKILL" "Two halts of this stage never come back as a card: a \`CFI-U3 BT-STOP\` halt answered \`재수렴\` goes to re-convergence, and a \`좌석 실행\` halt re-attaches the halted session after the seat's run.")" 예
check "implement-unattended: diff 게이트 단언은 스냅숏에서 아직 구현 시 검증 인 표 행에만" \
  "$(has "$IM_SKILL" "every R-item the verdict table marked as a flip target, and whose grade line in the snapshot \`\$SNAP\` still reads \`구현 시 검증\`, must appear as a changed line")" 예
check "design-solo-unattended: 문서 존재 가드는 카드의 문서 사전 sha256 이 같을 때만 면제한다" \
  "$(has "$DS_SKILL" "**A re-entry is exempt**: when \`CC_PIPELINE_HALT_ANSWER\` names a card and the \`문서 사전 sha256\` in the \`관측 상세\` of the record the card names equals the \`shasum -a 256\` of the document now")" 예
check "design-discuss-unattended: 문서 존재 가드는 카드의 문서 사전 sha256 이 같을 때만 면제한다" \
  "$(has "$DD_SKILL" "**A re-entry is exempt**: a card whose record's \`문서 사전 sha256\` equals the document's \`shasum -a 256\` now")" 예
for f in "$DD_SKILL" "$DS_SKILL"; do
  b=$(basename "$(dirname "$f")")
  check "$b: 정지 기록이 문서 사전 sha256 을 싣는다" \
    "$(has "$f" "writes \`문서 사전 sha256=<값>\` in its \`관측 상세\`**")" 예
done
check "design-discuss-unattended: 런 안에서 돌아오지 않는 정지는 고정 그래프 드라이버 한정이다" \
  "$(has "$DD_SKILL" "**Under the fixed-graph driver a halt does not come back within a run**")" 예
check "design-base-unattended: 베이스 설계 흐름은 토론 갈래의 면제와 재진입을 받지 않는다" \
  "$(has "$DB_SKILL" "Its re-entry exemption of the document-present guard and its **Re-entered with a carried answer** do not apply here")" 예
check "design-base-unattended: 분할 재진입에는 문서 존재 면제가 없다" \
  "$(has "$DB_SKILL" "There is no document-present exemption: this mode saves no document and has no such guard.")" 예
check "교대 계약: 재진입 표는 여섯 행이다" "$(has "$RS_CORPUS" "The table holds six halts.")" 예
check "교대 계약: 표 행은 멈춘 시도의 종류로 고른다" \
  "$(has "$RS_CORPUS" "on the halted attempt's own stage kind — the \`종류\` of its \`stage-result\` row, never the kind you are about to dispatch")" 예
check "교대 계약: 구현·토론·단독·분할 행은 종류로 운반한다" \
  "$(has "$RS_CORPUS" "any step) is carried as \`implement\`.")/$(has "$RS_CORPUS" "any step, are carried as \`design\`.")/$(has "$RS_CORPUS" "any step) is carried as \`split\`.")" "예/예/예"
check "교대 계약: 네 행은 원소의 carry_prompt 를 바이트 그대로 낸다" \
  "$(has "$RS_CORPUS" "**In these last four rows send the element's \`carry_prompt\` as \`-p\`, byte for byte.**")/$(has "$RS_CORPUS" "Never build those slots from other snapshot fields.")" "예/예"
check "교대 계약: 베이스 설계 정지는 표 밖이다" "$(has "$RS_CORPUS" "**The same skill's base-design stop is not in the table**")" 예
check "교대 계약 사본 일치: halt-answer-1 의 19 행은 이 런의 답 한정이다" \
  "$(has "$RS_CORPUS" "| \`19\` | for an answer of this run only (\`origin_run\` empty):")" 예
check "교대 계약 사본 일치: halt-answer-1 의 18 행은 들인 답의 상한을 싣는다" \
  "$(has "$RS_CORPUS" "or an answer brought over from an earlier run (\`origin_run\` not empty) this run cannot carry, wherever an answer of this run would get \`19\` (\`사유\` \`중단 답 라우팅 — 들인 답을 이 런에서 운반할 수 없다\`)")" 예
check "교대 계약 사본 일치: SKILL 의 19 행은 이 런의 답 한정이고 들인 답은 18 이다" \
  "$(has "$RS_CORPUS" "| \`19\` | only for an answer of this run (\`origin_run\` empty):")/$(has "$RS_CORPUS" "An element whose \`origin_run\` is not empty never gets \`19\`")" "예/예"
check "교대 계약: 들인 답의 19 로 교대를 끝내는 옛 문장이 남지 않는다" \
  "$(has "$RS_CORPUS" "so do not \`--resume\`: end the shift with \`사유=중단\`")" 아니오
check "좌석 사본 일치: act2-seat 의 19 행은 이 런의 답 한정이다" \
  "$(has "$SEAT_REF" "| 19 | only for an answer of this run (\`origin_run\` empty):")" 예
check "보고: 운반 상한으로 닫힌 들인 답을 근거와 함께 싣는다" \
  "$(has "$AP_REFS/act3-report.md" "**An answer this run brought over and could not carry lands here too**")" 예
check "사이드카: 출처 런에서 들인 답의 원장 값 칸은 출처 원장에서 짓는다" \
  "$(has "$AU_ANS" "For an answer a later run brought in (\`출처 런\`) the ledger is the earlier run's, where its attempt halted")" 예
check "사이드카: 들인 답은 재부착하지 않고 상한 행과 18 로 닫는다" \
  "$(has "$AU_ANS" "**such an answer is never re-attached**")" 예
check "사이드카: answered_halts 원소가 carry_prompt 를 싣는다" \
  "$(has "$AU_ANS" "and \`carry_prompt\`, the \`-p\` text of the carry act for an implement, design or split halt the re-entry table holds")" 예
check "사이드카: 재진입 표의 여섯 행" \
  "$(has "$AU_ANS" "an audit's synthesis halt, a re-convergence's Step 3 halt, an implement stage's halt, a design discussion's halt, a lead solo design's halt, a base split's halt")" 예
# 앞선 런이 이월한 답은 다음 런(입양·재킥오프 후속)이 운반 act 로 이어받는다 — 사람에게 다시
# 묻지 않는다는 약속은 이 문장들이 싣고, 아침 보고의 새 절이 그 답을 사람에게 보인다.
for pair in "autopilot-router-shift:$RS_CORPUS" "references:$AP_ROUTER"; do
  f=${pair#*:}
  check "${pair%%:*}: 입양은 이월 행이 이름 짓는 답도 들인다" \
    "$(has "$f" "or one an \`이월\` row of that ledger names (a carry act of that run found no account with room before its deadline and kept the answer for the next run)")" 예
done
check "교대 계약: 이월된 답은 거절된 첫 파견으로 도착하고 운반 act 로 넘긴다" \
  "$(has "$RS_CORPUS" "**An answer the earlier run carried over arrives through a refused first dispatch.**")" 예
check "교대 계약: 그 3 은 표의 것이 아니고 평범한 파견을 다시 내지 않는다" \
  "$(has "$RS_CORPUS" "That \`3\` is not the table's")/$(has "$RS_CORPUS" "never retry the plain dispatch")" "예/예"
check "좌석 사본: 재킥오프 후속 런도 이월 답을 운반으로 이어받는다" \
  "$(has "$SEAT_REF" "a re-kickoff's follow-up run carries such an \`이월\` answer of a run-scope step")" 예
check "아침 보고: 답했으나 전달하지 못한 중단 답 절이 있다" \
  "$(has "$AP_REFS/act3-report.md" "**답했으나 전달하지 못한 중단 답**")/$(has "$AP_REFS/act3-report.md" "a carry issued after the deadline, whose \`관측\` reads \`마감 경과\`")" "예/예"
check "아침 보고: 이월 절은 게이트가 쓰는 사유 머리와 같다" \
  "$(has "$GATE" "'중단 답 이월 — 마감 안에 자리 없음'")" 예

# ---------------------------------------------------------------------------
# 13. An answer a routing block stamped leaves answered_halts for returned_halts
#
# The shift could not carry the answer out and wrote a cone row the gate
# stamped with the answer's line. The answer is spent, so the shift does not
# route it again, and the record is a question again until a person's new
# answer names it — which is the next element of answered_halts.
# ---------------------------------------------------------------------------
RET_DIR=$(mktemp -d "${TMPDIR:-/tmp}/cc-snap-returned.XXXXXX")
RET_LEDGER="$RET_DIR/ledger.md"
RET_REC="$RET_DIR/halt/S8#1.md"
mkdir -p "$RET_DIR/halt"
printf '%s\n' '스테이지 기록' > "$RET_REC"
{
  printf -- '- `stage-result` | 교대=0 | 세그먼트=S8 | 스테이지=S8 | 종류=implement | 실행 버전=1 | 세션 id=s-8 | 종단 부류=의도된 park | prev=0\n'
  printf -- '- `중단 답` | 교대=0 | 세그먼트=S8 | 중단 기록=%s | 스킬=implement-unattended | 선택지=보류 | 답한 주체=사람 | 근거=사람이 보류 | prev=0\n' "$RET_REC"
} > "$RET_LEDGER"
ret_read() {  # ret_read <함수> <jq> — that snapshot fragment on the fixture ledger, through jq
  local frag
  frag=$(CC_GATE_SOURCE_ONLY=1 bash -c '
    . "$1" >/dev/null 2>&1; set +e +u
    LEDGER="$2"; MANIFEST=/nonexistent; RUN_ID=R; RUN_DIR="$3"
    "$4" 2>/dev/null' _ "$GATE" "$RET_LEDGER" "$RET_DIR" "$1")
  printf '[%s]' "$frag" | jq -c "$2"
}
check "막힘 전의 답은 answered_halts 에 있고 returned_halts 는 비어 있다" \
  "$(ret_read gate_answered_halts_json '[.[] | .option]')/$(ret_read gate_returned_halts_json 'length')" '["보류"]/0'
printf -- '- `blocked` | 교대=1 | 대상=t | 스코프=cone | 원인=막힘 | 앵커 세그먼트=S8 | 사유=중단 답 라우팅 — S8#1.md — 스트림이 세션 시작을 보이지 않는다 | 근거=중단 답 줄 2 | 막힌 답 줄=2 | prev=0\n' >> "$RET_LEDGER"
check "도장 찍힌 막힘이 그 답을 answered_halts 에서 뺀다" "$(ret_read gate_answered_halts_json 'length')" "0"
check "returned_halts 가 기록·선택지·답한 주체·답 줄·이유·막힘 줄을 낸다" \
  "$(ret_read gate_returned_halts_json '[.[] | [.segment, .record == "'"$RET_REC"'", .option, .answered_by, .answer_line, .reason, .line]]')" \
  '[["S8",true,"보류","사람",2,"스트림이 세션 시작을 보이지 않는다",3]]'
printf -- '- `중단 답` | 교대=1 | 세그먼트=S8 | 중단 기록=%s | 스킬=implement-unattended | 선택지=재시도 | 답한 주체=사람 | 근거=사람이 다시 고름 | prev=0\n' "$RET_REC" >> "$RET_LEDGER"
check "사람의 새 답이 서면 returned_halts 는 비고 새 답이 answered_halts 에 오른다" \
  "$(ret_read gate_returned_halts_json 'length')/$(ret_read gate_answered_halts_json '[.[] | .option]')" '0/["재시도"]'
rm -rf "$RET_DIR"

printf '\ntest-snapshot: %d passed, %d failed\n' "$passed" "$failed"
[ "$failed" = "0" ]
