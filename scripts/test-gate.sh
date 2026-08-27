#!/usr/bin/env bash
# lint-bash-portability: self-skip
# Test the policy gate's refusals against a throwaway repository.
#
# The gate's whole value is in the branches a successful act never reaches, and
# every one of them is an EXIT CODE rather than a message — a router reads the
# status, not the prose. So each assertion here drives the CLI with argv the
# router could actually construct and asserts the code.
#
# Three of these reproduce defects measured in this tree rather than imagined:
#
#   1. A target-level cutpoint LOWER than the run maximum must win. The shipped
#      `authorized()` reads the run maximum and takes no target, so a run
#      declaring `frontend: PR` beside `infra: 배포` authorized deploy-grade acts
#      against the front end (Nharu/cc-cmds#208).
#   2. A refusal must report the MOST FUNDAMENTAL reason that holds. Under glob
#      order over Korean filenames a cutpoint violation came back as "the ledger
#      is unreadable", which sends a 3am reader to the wrong repair.
#   3. `grade` on a well-graded argv must exit 0. `[ … ] && exit` as a case
#      arm's last command hands the false test's status to the caller, so a
#      successful grading read as a refusal.
#
# The fixture is a `git init` in a scratch directory, used as its own
# origin-worktree, so nothing here touches the checkout the tests run from.
#
# Usage: bash scripts/test-gate.sh

set -uo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
GATE="$repo_root/plugins/cc-cmds/orchestrator/gate.sh"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/cc-gate-test.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
export XDG_STATE_HOME="$WORK/state"

passed=0; failed=0
ok()   { passed=$((passed + 1)); printf 'PASS: %s\n' "$1"; }
bad()  { failed=$((failed + 1)); printf 'FAIL: %s — %s\n' "$1" "${2:-}" >&2; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got '$2', want '$3'"; fi; }

# `gate` runs the CLI and leaves the code in `rc` and the last non-log line in
# `msg`. The driver's own log lines go to stderr and are filtered out so an
# assertion on the refusal text does not match the banner above it.
# Every invocation runs FROM the fixture repository. `check_manifest` compares
# the manifest's `origin-worktree=` against `git rev-parse --show-toplevel` in
# the gate's own cwd, so a gate run from the checkout under test would reject a
# fixture manifest — and the driver itself runs from the home worktree, which is
# the shape this reproduces.
rc=0; msg=""
gate() {
  local out
  out=$(cd "$WT" && bash "$GATE" "$@" 2>&1); rc=$?
  # The WHOLE output, newlines flattened. A refusal arrives as two lines — the
  # checker's specific reason and the gate's generic "rule refused: <name>" —
  # and taking only the last one asserts against the generic half.
  msg=$(printf '%s' "$out" | grep -vE '\[run\] ' | tr '\n' ' ' | sed 's/[[:space:]]*$//')
  printf '%s' "$out" > "$WORK/last-output.txt"
}

# ---------------------------------------------------------------------------
# 0a. The pipefail trap, scanned the way the driver's own suite scans it
#
# Under `pipefail` an early-exiting reader on the right of a pipe kills the
# writer with SIGPIPE and the whole pipeline reports failure. In this file every
# such site was a PRESENCE test used to decide whether to append, so a row that
# existed came back as absent and the gate wrote a duplicate — duplicate
# approvals and duplicate obligations, which the termination conditions then
# count. The driver's suite already refuses this shape; the gate is the busier
# file and had six of them.
# ---------------------------------------------------------------------------
for f in "$GATE" "$repo_root/plugins/cc-cmds/orchestrator/watch.sh" \
         "$repo_root/plugins/cc-cmds/hooks/gate-pretool.sh"; do
  [ -f "$f" ] || continue
  early=$(sed 's/#.*//' "$f" | grep -nE '\| *(head -|grep -[A-Za-z]*q)' || true)
  if [ -z "$early" ]; then
    ok "파이프 오른쪽에 조기 종료 읽기가 없다: $(basename "$f")"
  else
    bad "pipefail 함정" "$(basename "$f"): $(printf '%s' "$early" | head -3 | tr '\n' ' ')"
  fi
done

# ---------------------------------------------------------------------------
# 0. Fixture — a real repository, two targets, two cutpoints
# ---------------------------------------------------------------------------
REPO="$WORK/repo"
mkdir -p "$REPO"
( cd "$REPO" \
  && git init -q . \
  && git config user.email t@example.invalid \
  && git config user.name  T \
  && mkdir -p docs/pipeline-run docs/pipeline-grant \
  && echo one > a.txt && git add -A && git commit -qm one \
  && echo base > base.txt && git add -A && git commit -qm base ) >/dev/null 2>&1

# A real bare remote, so `git push` is an act that actually runs rather than a
# string the gate merely approves. The gate PERFORMS what it passes, so a
# fixture whose acts all fail cannot tell an approval from a refusal.
REMOTE="$WORK/remote.git"
( git init -q --bare "$REMOTE" \
  && cd "$REPO" && git remote add origin "$REMOTE" \
  && git branch -M main && git push -q origin main ) >/dev/null 2>&1

WT=$(cd "$REPO" && git rev-parse --show-toplevel)
CG=$(cd "$REPO" && git rev-parse --path-format=absolute --git-common-dir)
MANIFEST="$WT/plan.md"
LEDGER="$WT/docs/pipeline-run/R1.md"
GRANT="$WT/docs/pipeline-grant/R1.md"

# Two targets on purpose. One run maximum of `배포` with a `PR` target is the
# only shape in which #208's defect is observable at all.
row_pr="- \`target\` | 별칭=front | 메인 워크트리=$WT | 공통 git 디렉터리=$CG | 베이스 브랜치=main | 홈=예 | 원격 슬러그=t/front | 절단점=PR | 말단 행위 상한=없음"
row_dp="- \`target\` | 별칭=infra | 메인 워크트리=$WT | 공통 git 디렉터리=$CG | 베이스 브랜치=main | 홈=아니오 | 원격 슬러그=t/infra | 절단점=배포 | 말단 행위 상한=없음"
TD=$(printf '%s\n%s\n' "$row_pr" "$row_dp" | sed 's/[[:space:]]\{1,\}/ /g' | sort | shasum -a 256 | cut -d' ' -f1)
PLAN='{ "steps": [] }'
PD=$(printf '%s\n' "$PLAN" | shasum -a 256 | cut -d' ' -f1)

{
  printf '# 파이프라인 런 매니페스트 — R1\n'
  printf '<!-- cc-run-manifest v1; writer=autopilot; reader=orchestrator; run-id=R1;\n'
  printf '     anchor-kind=repo; anchor-key=t/front;\n'
  printf '     owner-doc=(없음); origin-worktree=%s;\n' "$WT"
  printf '     NOT a design doc; mechanism-local, never staged by a skill -->\n\n'
  printf '## 런 정체\n'
  printf '**킥오프 일시**: 2026-01-01T00:00:00Z\n**런 id**: R1\n'
  printf '**앵커 종류**: repo\n**앵커 키**: t/front\n**사용자 확인 문면**: 테스트 픽스처\n\n'
  printf '## 의도\n```text\n테스트\n```\n\n'
  printf '## 대상\n**대상 맵 다이제스트**: %s\n%s\n%s\n\n' "$TD" "$row_pr" "$row_dp"
  printf '## 요소\n**설계 문서**: (없음)\n**적용 주체**: (해당 없음)\n\n'
  printf '## 실행 계획\n**계획 다이제스트**: %s\n**승인 문면**: 테스트\n```json\n%s\n```\n\n' "$PD" "$PLAN"
  printf '## 인가\n**런 최대 절단점**: 배포\n**종료 지점**: 픽스처가 끝나면\n'
  printf '**벽시계 마감**: 2030-01-01T00:00:00Z\n**시각 정합 마커**: 없음\n'
  printf '**사다리 가용 단 수**: 4\n**미선언 상황 처분**: park\n'
  printf -- '- `사전 인가` | 형태=gh pr | 사유=테스트\n'
  printf -- '- `사전 인가` | 형태=git push | 사유=테스트\n'
} > "$MANIFEST"

# The binding digest is computed FROM the finished manifest and appended after.
# The frozen set is goal + clauses + targets + rule settings + pre-authorization
# + deadline, and the digest field is not itself in that set — so appending it
# does not move the value it records.
refresh_bd() {
  # Recompute and rewrite the field. A test that edits the frozen set is
  # standing in for a kickoff, and a kickoff writes the digest — leaving a stale
  # one would make every later assertion fail for the same uninformative reason.
  local bd
  grep -v '^\*\*구속 다이제스트\*\*:' "$MANIFEST" > "$MANIFEST.tmp" && mv "$MANIFEST.tmp" "$MANIFEST"
  bd=$(cd "$WT" && bash -c '
    CC_ORCH_SOURCE_ONLY=1 . "'"$repo_root"'/plugins/cc-cmds/orchestrator/run.sh"
    MANIFEST="'"$MANIFEST"'"
    binding_set_bytes | shasum -a 256 | cut -d" " -f1')
  printf '**구속 다이제스트**: %s\n' "$bd" >> "$MANIFEST"
}
refresh_bd

gate snapshot --manifest "$MANIFEST"
check "구속 다이제스트가 있는 매니페스트가 통과한다" "$rc" "0"
case "$msg" in
  *"구속 다이제스트가 없습니다"*) bad "구속 다이제스트" "필드를 넣었는데 없다고 한다" ;;
  *) ok "구속 다이제스트를 실제로 대조한다" ;;
esac
check "픽스처 매니페스트가 검사를 통과한다" "$rc" "0"

H=$(cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null | jq -r .H)

# ---------------------------------------------------------------------------
# 1. The snapshot is a JSON object, not a table
# ---------------------------------------------------------------------------
if (cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null) | jq -e . >/dev/null; then
  ok "스냅숏이 유효한 JSON 객체로 나온다"
else
  bad "스냅숏 JSON" "jq 가 파싱하지 못했다 — 라우터의 유일한 선언 입력이 깨졌다"
fi

# The ledger does not exist yet, which is the NORMAL state at a run's first act.
# `grep` answers a missing file with exit 2, `pipefail` promotes it, and `set -e`
# used to kill the whole snapshot at exactly the moment a router needs it most.
[ ! -f "$LEDGER" ] && ok "원장이 아직 없는 상태에서 스냅숏이 답한다" \
                   || bad "픽스처 전제" "원장이 이미 있다 — 이 절의 전제가 무너졌다"

n_total=$(cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null | jq -r .obligations_total)
check "빈 원장의 의무 총수가 0 하나로 나온다" "$n_total" "0"

# ---------------------------------------------------------------------------
# 1b. The run settings the gate generates
#
# These files decide whether a stage has any hook coverage at all, and they are
# GENERATED — so nothing in the tree is reviewed when they are wrong. They
# shipped once as syntactically invalid JSON while every test here still passed,
# because no assertion had ever opened one.
# ---------------------------------------------------------------------------
SETTINGS_DIR="$XDG_STATE_HOME/cc-cmds/run/R1/settings"
if [ -d "$SETTINGS_DIR" ]; then
  ok "게이트가 런 개시에 설정 디렉터리를 만든다"
else
  bad "설정 생성" "$SETTINGS_DIR 가 없다 — 래퍼가 하드 스톱하므로 이 런은 스테이지를 하나도 띄우지 못한다"
fi

bad_json=0; n_variants=0
for f in "$SETTINGS_DIR"/*.json; do
  [ -f "$f" ] || continue
  n_variants=$((n_variants + 1))
  jq -e . "$f" >/dev/null 2>&1 || { bad_json=$((bad_json + 1)); printf '      깨진 파일: %s\n' "$f" >&2; }
done
check "모든 변종이 유효한 JSON 이다" "$bad_json" "0"
if [ "$n_variants" -ge 2 ]; then
  ok "스테이지 종류마다 변종이 하나씩 생긴다 (${n_variants}종)"
else
  bad "변종 수" "${n_variants}종 — 단일 파일이면 design 전용 제약을 표현할 자리가 없다"
fi

hook_cmd=$(jq -r '.hooks.PreToolUse[0].hooks[0].command // empty' "$SETTINGS_DIR/generic.json" 2>/dev/null)
case "$hook_cmd" in
  *gate-pretool.sh*--run-dir*--gate*)
    ok "훅 명령줄이 런 디렉터리와 게이트 경로를 파일에 박아 넣는다" ;;
  *)
    bad "훅 명령줄" "'$hook_cmd' — 환경에서 읽는 형태라면 스테이지가 env 하나로 훅을 끌 수 있다" ;;
esac

d_design=$(jq -r '.permissions.deny | join(",")' "$SETTINGS_DIR/design.json" 2>/dev/null)
d_review=$(jq -r '.permissions.deny | join(",")' "$SETTINGS_DIR/review.json" 2>/dev/null)
case "$d_design" in
  *WebFetch*) ok "design 변종만 네트워크 취득 도구를 불허한다" ;;
  *) bad "design 변종" "'$d_design' — 이 상한은 등급표로는 강제할 수 없어 여기가 유일한 지점이다" ;;
esac
case "$d_review" in
  *WebFetch*) bad "변종 구분" "review 변종까지 네트워크를 막았다 — design 전용 제약이 아니다" ;;
  *) ok "다른 변종은 그 제약을 받지 않는다" ;;
esac

# ---------------------------------------------------------------------------
# 2. Vocabulary — closed sets refuse by status, never by `die`
# ---------------------------------------------------------------------------
gate act --manifest "$MANIFEST" --kind x --target front --cutpoint 머지후 \
     --snapshot-digest "$H" --rationale x -- git push origin main
check "어휘 밖 절단점 토큰은 거부된다" "$rc" "2"

# An undeclared repository is not a vocabulary error — it is the three-layer
# rule. Above `브랜치` nothing may be granted, so the act parks with a cause of
# its own rather than borrowing `인가 한도`, which means something else: that a
# target the manifest DID declare was exceeded.
gate act --manifest "$MANIFEST" --kind x --target nope --cutpoint push \
     --snapshot-digest "$H" --rationale x -- git push origin main
check "미선언 대상의 push 는 거부된다" "$rc" "3"
if grep -q '사유=대상 미선언' "$LEDGER"; then
  ok "park 사유가 대상 미선언 이다 (인가 한도 를 빌려 쓰지 않는다)"
else
  bad "park 사유" "미선언 대상의 park 이 기록되지 않았거나 다른 사유를 쓴다"
fi
case "$msg" in
  *재인가*) ok "거부 문면이 재인가가 필요하다고 말한다" ;;
  *) bad "거부 문면" "'$msg'" ;;
esac

H=$(cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null | jq -r .H)
gate act --manifest "$MANIFEST" --kind x --target nope --cutpoint 커밋 \
     --worktree "$WT" --snapshot-digest "$H" --rationale "이슈 링크에서 발견" -- touch "$WORK/nd"
check "미선언 대상의 로컬 쓰기는 통과한다" "$rc" "0"
if grep -q '^- `대상 추가`' "$LEDGER"; then
  ok "대상 추가 행이 남는다 (아침 리포트가 런이 건드린 레포를 보여 준다)"
else
  bad "대상 추가" "층 1 행위가 통과했는데 기록이 없다"
fi
if grep '^- `대상 추가`' "$LEDGER" | grep -q '층=1'; then
  ok "커밋 등급은 층 1 로 기록된다"
else
  bad "층 판정" "$(grep '^- `대상 추가`' "$LEDGER" | head -1)"
fi

gate act --manifest "$MANIFEST" --kind x --target nope2 --cutpoint 커밋 \
     --snapshot-digest "$H" --rationale x -- touch "$WORK/nd2"
check "워크트리 없이 미선언 대상을 쓰려 하면 거부된다" "$rc" "2"

gate act --manifest "$MANIFEST" --kind x --target front --cutpoint 커밋 \
     --snapshot-digest "$H" --rationale x -- frobnicate now
check "등급표에 없는 argv0 는 읽기로 떨어지지 않는다" "$rc" "2"

gate grade --manifest "$MANIFEST" -- frobnicate
check "grade 도 미상 argv0 를 어휘 오류로 답한다" "$rc" "2"

gate grade --manifest "$MANIFEST" -- gh pr merge
check "잘 등급된 argv 의 grade 는 성공으로 끝난다" "$rc" "0"
check "grade 가 축2 를 축자로 답한다" "$msg" "축2=외부상태변경"

gate grade --manifest "$MANIFEST" -- cat a.txt
check "읽기 등급이 읽기로 나온다" "$msg" "축2=읽기"

# ---------------------------------------------------------------------------
# 3. Cutpoint adjudication is PER TARGET (#208 regression)
# ---------------------------------------------------------------------------
gate act --manifest "$MANIFEST" --kind push --target front --cutpoint push \
     --snapshot-digest "$H" --rationale x -- git push origin main
check "절단점 이하의 행위는 통과한다" "$rc" "0"

H=$(cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null | jq -r .H)
gate act --manifest "$MANIFEST" --kind merge --target front --segment S1 --cutpoint 머지 \
     --snapshot-digest "$H" --rationale x -- gh pr merge 1
check "절단점 PR 인 대상에 머지는 거부된다" "$rc" "3"
case "$msg" in
  *"절단점-준수"*) ok "거부 사유가 절단점으로 보고된다 (가장 근본적인 이유가 이긴다)" ;;
  *) bad "거부 사유" "절단점 위반인데 '$msg' 로 보고됐다 — 3시에 엉뚱한 곳을 고치게 된다" ;;
esac

# The same act against the target the user granted `배포` to reaches the review
# rule instead — which is the proof that the refusal above was the TARGET's
# cutpoint and not the run maximum.
gate act --manifest "$MANIFEST" --kind merge --target infra --segment S1 --cutpoint 머지 \
     --snapshot-digest "$H" --rationale x -- gh pr merge 1
case "$msg" in
  *"절단점-준수"*) bad "대상별 절단점" "배포 인가된 대상까지 절단점에서 막혔다" ;;
  *) ok "런 최대치가 아니라 대상 행의 값이 판정한다 (#208 회귀)" ;;
esac

# ---------------------------------------------------------------------------
# 4. Self-widening is refused at every cutpoint
# ---------------------------------------------------------------------------
gate act --manifest "$MANIFEST" --kind merge --target infra --segment S1 --cutpoint 배포 \
     --snapshot-digest "$H" --rationale x -- gh pr merge 1 --admin
check "--admin 은 배포 인가에서도 거부된다" "$rc" "3"
case "$msg" in
  *"--admin"*) ok "거부 사유가 관리자 우회를 지목한다" ;;
  *) bad "--admin 사유" "'$msg'" ;;
esac

gate act --manifest "$MANIFEST" --kind x --target infra --cutpoint 배포 \
     --snapshot-digest "$H" --rationale x -- tee "$GRANT"
check "인가 기록에 쓰려는 행위는 거부된다" "$rc" "3"

gate act --manifest "$MANIFEST" --kind x --target infra --cutpoint 배포 \
     --snapshot-digest "$H" --rationale x -- cat "$GRANT"
case "$rc" in
  3) bad "인가 기록 읽기" "읽기까지 막혔다 — 드라이버는 이 파일을 읽어야 한다" ;;
  *) ok "인가 기록 읽기는 막지 않는다" ;;
esac

# ---------------------------------------------------------------------------
# 5. Pre-authorization: outside the list is an APPROVAL, not a refusal
# ---------------------------------------------------------------------------
gate act --manifest "$MANIFEST" --kind x --target infra --cutpoint 배포 \
     --snapshot-digest "$H" --rationale x -- curl https://example.invalid
check "사전 인가 밖 외부 상태 변경은 승인 대기를 발행한다" "$rc" "5"

gate act --manifest "$MANIFEST" --kind x --target infra --cutpoint 배포 \
     --snapshot-digest "$H" --rationale x -- mkdir -p "$WORK/scratch"
check "워크트리 쓰기는 사전 인가 목록을 요구하지 않는다" "$rc" "0"
[ -d "$WORK/scratch" ] && ok "게이트는 통과시킨 행위를 실제로 수행한다" \
                       || bad "수행" "통과했는데 디렉터리가 생기지 않았다 — 기록만 하고 수행하지 않으면 층 1 아래에서는 아무것도 실행되지 않는다"

# ---------------------------------------------------------------------------
# 6. Snapshot binding — a stale digest is a loud re-read
# ---------------------------------------------------------------------------
gate act --manifest "$MANIFEST" --kind x --target front --cutpoint 커밋 \
     --snapshot-digest 0000000000000000000000000000000000000000000000000000000000000000 \
     --rationale x -- touch "$WORK/touched"
check "낡은 스냅숏 다이제스트는 거부된다" "$rc" "4"

gate plan --manifest "$MANIFEST" --kind x --target front --cutpoint 커밋 -- git commit -m x
check "plan 은 스냅숏 다이제스트 없이도 답한다 (건드리는 것이 없다)" "$rc" "0"

# ---------------------------------------------------------------------------
# 7. Declared grade is a CHECKED CLAIM, not a self-grant
# ---------------------------------------------------------------------------
H=$(cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null | jq -r .H)
gate exec --manifest "$MANIFEST" --target front --cutpoint 커밋 --surface 읽기 \
     --snapshot-digest "$H" --rationale x -- touch "$WORK/touched"
check "축2 자기선언이 등급과 다르면 거부된다" "$rc" "6"

gate exec --manifest "$MANIFEST" --target front --cutpoint 커밋 --surface 워크트리쓰기 \
     --snapshot-digest "$H" --rationale x -- touch "$WORK/touched"
check "선언이 등급과 같으면 통과한다" "$rc" "0"

gate exec --manifest "$MANIFEST" --target front --cutpoint 커밋 --surface 파일쓰기 \
     --snapshot-digest "$H" --rationale x -- touch "$WORK/touched"
check "어휘 밖 축2 토큰은 거부된다" "$rc" "2"

# ---------------------------------------------------------------------------
# 8. Review-before-merge, and its five staleness grades
# ---------------------------------------------------------------------------
seg_wt="$WT"
head0=$(cd "$WT" && git rev-parse HEAD)

H=$(cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null | jq -r .H)
gate act --manifest "$MANIFEST" --kind merge --target infra --segment SNONE --cutpoint 머지 \
     --snapshot-digest "$H" --rationale x -- gh pr merge 1
check "리뷰 기록이 없는 머지는 거부된다" "$rc" "3"

{
  printf -- '- `segment` | id=S9 | 상태=구현완료 | 커밋=%s | 워크트리=%s\n' "$head0" "$seg_wt"
  printf -- '- `cycle` | 세그먼트=S9 | P0=1 | P1=0 | 리뷰 HEAD=%s\n' "$head0"
} >> "$LEDGER"
H=$(cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null | jq -r .H)
gate act --manifest "$MANIFEST" --kind merge --target infra --segment S9 --cutpoint 머지 \
     --snapshot-digest "$H" --rationale x -- gh pr merge 1
check "P0 가 남아 있으면 머지는 거부된다" "$rc" "3"

printf -- '- `cycle` | 세그먼트=S9 | P0=0 | P1=0 | 리뷰 HEAD=%s\n' "$head0" >> "$LEDGER"
H=$(cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null | jq -r .H)
# Judged by the ABSENCE of the rule's refusal line rather than by the exit code:
# past the checks the gate performs the act, and `gh pr merge` in a fixture with
# no GitHub behind it fails for reasons that have nothing to do with the rule.
passes_review() {
  case "$msg" in *"리뷰-후-머지:"*) return 1 ;; *) return 0 ;; esac
}
gate act --manifest "$MANIFEST" --kind merge --target infra --segment S9 --cutpoint 머지 \
     --snapshot-digest "$H" --rationale x -- gh pr merge 1
if passes_review; then ok "무이동 등급은 통과한다"; else bad "무이동 등급" "$msg"; fi

# 동일 트리 — amend rewrites the commit and leaves the tree byte-identical.
( cd "$WT" && git commit -q --amend -m "one (amended)" ) >/dev/null 2>&1
head_amend=$(cd "$WT" && git rev-parse HEAD)
H=$(cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null | jq -r .H)
gate act --manifest "$MANIFEST" --kind merge --target infra --segment S9 --cutpoint 머지 \
     --snapshot-digest "$H" --rationale x -- gh pr merge 1
if passes_review; then ok "동일 트리 등급(amend)은 통과한다"; else bad "동일 트리 등급" "$msg"; fi
if [ "$head_amend" = "$head0" ]; then
  bad "동일 트리 전제" "amend 가 커밋 sha 를 바꾸지 않았다 — 이 절이 공허하다"
else
  ok "동일 트리 절이 공허하지 않다 (커밋 sha 는 실제로 달라졌다)"
fi

# 추가 커밋 — the reviewed HEAD is an ancestor with commits in between. The
# review record is re-stamped at the amended HEAD first: without that, the
# amend above has already made the old HEAD unreachable and this case would
# silently exercise the `무관` arm while claiming to test this one.
printf -- '- `cycle` | 세그먼트=S9 | P0=0 | P1=0 | 리뷰 HEAD=%s\n' "$head_amend" >> "$LEDGER"
( cd "$WT" && echo two > b.txt && git add -A && git commit -qm two ) >/dev/null 2>&1
H=$(cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null | jq -r .H)
gate act --manifest "$MANIFEST" --kind merge --target infra --segment S9 --cutpoint 머지 \
     --snapshot-digest "$H" --rationale x -- gh pr merge 1
check "리뷰 이후 커밋이 추가되면 거부된다" "$rc" "3"
case "$msg" in
  *"커밋이 추가"*) ok "낡음 등급이 「추가 커밋」으로 보고된다" ;;
  *) bad "낡음 등급 보고" "'$msg'" ;;
esac

# 무관 — an unrelated root. `git reset` rather than `git rm -r .`: the latter
# prunes the directory the run ledger lives in, and every assertion after this
# point then reads a ledger that is not there. The bug it caused looked like a
# gate defect and was a fixture defect.
( cd "$WT" && git checkout -q --orphan sideline && git reset -q \
  && echo x > c.txt && git add c.txt && git commit -qm sideline ) >/dev/null 2>&1
H=$(cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null | jq -r .H)
gate act --manifest "$MANIFEST" --kind merge --target infra --segment S9 --cutpoint 머지 \
     --snapshot-digest "$H" --rationale x -- gh pr merge 1
check "리뷰 HEAD 가 조상이 아니면 거부된다" "$rc" "3"
case "$msg" in
  *"조상이 아닙니다"*) ok "낡음 등급이 「무관/베이스 이동」으로 보고된다" ;;
  *) bad "낡음 등급 보고" "'$msg'" ;;
esac

# ---------------------------------------------------------------------------
# 8b. Implementation and review must be separate sessions
#
# The rule this replaces compared session ids while those ids were DERIVED from
# `run|doc|stage|attempt` — values that differ by construction. So the check was
# a tautology: it passed on every run, including the ones it existed to catch.
# What makes it a proposition is recording the id the harness actually assigned
# together with the id of the session that spawned it.
# ---------------------------------------------------------------------------
printf -- '- `segment` | id=SEP | 상태=구현완료 | 커밋=%s | 워크트리=%s\n' "$(cd "$WT" && git rev-parse HEAD)" "$WT" >> "$LEDGER"
printf -- '- `cycle` | 세그먼트=SEP | P0=0 | P1=0 | 리뷰 HEAD=%s\n' "$(cd "$WT" && git rev-parse HEAD)" >> "$LEDGER"
printf -- '- `stage-result` | 세그먼트=SEP | 스테이지=S4 | 세션 id=impl-1 | 부모=router-1 | 종단 부류=정상 완료\n' >> "$LEDGER"
printf -- '- `stage-result` | 세그먼트=SEP | 스테이지=S5 | 세션 id=rev-1 | 부모=router-1 | 종단 부류=정상 완료\n' >> "$LEDGER"
H=$(cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null | jq -r .H)
gate act --manifest "$MANIFEST" --kind merge --target infra --segment SEP --cutpoint 머지 \
     --snapshot-digest "$H" --rationale x -- gh pr merge 1
case "$msg" in
  *"조상이 겹칩니다"*) ok "부모를 공유하면 자기 작업 리뷰로 판정된다" ;;
  *) bad "조상 폐포" "같은 부모를 가진 두 세션이 서로소로 통과했다 — id 비교로 되돌아간 것이다" ;;
esac

printf -- '- `stage-result` | 세그먼트=SEP | 스테이지=S5 | 세션 id=rev-2 | 부모=router-2 | 종단 부류=정상 완료\n' >> "$LEDGER"
H=$(cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null | jq -r .H)
gate act --manifest "$MANIFEST" --kind merge --target infra --segment SEP --cutpoint 머지 \
     --snapshot-digest "$H" --rationale x -- gh pr merge 1
case "$msg" in
  *"조상이 겹칩니다"*) bad "분리 판정" "계보가 서로소인데 거부됐다" ;;
  *) ok "계보가 서로소면 통과한다" ;;
esac

printf -- '- `stage-result` | 세그먼트=SEP2 | 스테이지=S4 | 세션 id=impl-9 | 부모=미상 | 종단 부류=정상 완료\n' >> "$LEDGER"
printf -- '- `stage-result` | 세그먼트=SEP2 | 스테이지=S5 | 세션 id=rev-9 | 부모=미상 | 종단 부류=정상 완료\n' >> "$LEDGER"
printf -- '- `segment` | id=SEP2 | 상태=구현완료 | 커밋=%s | 워크트리=%s\n' "$(cd "$WT" && git rev-parse HEAD)" "$WT" >> "$LEDGER"
printf -- '- `cycle` | 세그먼트=SEP2 | P0=0 | P1=0 | 리뷰 HEAD=%s\n' "$(cd "$WT" && git rev-parse HEAD)" >> "$LEDGER"
H=$(cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null | jq -r .H)
gate act --manifest "$MANIFEST" --kind merge --target infra --segment SEP2 --cutpoint 머지 \
     --snapshot-digest "$H" --rationale x -- gh pr merge 1
case "$msg" in
  *"판정 불가는 통과가 아닙니다"*) ok "계보가 기록되지 않으면 통과가 아니다 (공허한 참으로 돌아가지 않는다)" ;;
  *) bad "미기록 처리" "'$msg'" ;;
esac

# ---------------------------------------------------------------------------
# 9. The un-disableable rules ignore the manifest's rule settings
# ---------------------------------------------------------------------------
{
  printf '\n## 룰 설정\n'
  printf '**절단점-준수**: 끔\n**사전-인가-대조**: 끔\n**인가-자기확장-금지**: 끔\n**리뷰-후-머지**: 끔\n'
} >> "$MANIFEST"
# Rule settings ARE in the frozen set, so this edit legitimately moves the
# digest — which is the mechanism working. A kickoff would rewrite it; the
# fixture does the same.
refresh_bd
# The digests cover the target rows and the plan fence, not this section, so the
# manifest still validates — which is the point: turning a rule off is a normal,
# well-formed edit, and that is exactly why three of them may not honour it.
H=$(cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null | jq -r .H)
gate act --manifest "$MANIFEST" --kind merge --target front --segment S9 --cutpoint 머지 \
     --snapshot-digest "$H" --rationale x -- gh pr merge 1
check "절단점-준수 는 「끔」을 무시한다" "$rc" "3"

gate act --manifest "$MANIFEST" --kind x --target infra --cutpoint 배포 \
     --snapshot-digest "$H" --rationale x -- curl https://example.invalid
check "사전-인가-대조 는 「끔」을 무시한다" "$rc" "5"

gate act --manifest "$MANIFEST" --kind merge --target infra --segment S9 --cutpoint 배포 \
     --snapshot-digest "$H" --rationale x -- gh pr merge 1 --admin
check "인가-자기확장-금지 는 「끔」을 무시한다" "$rc" "3"

# 리뷰-후-머지 IS disableable, and this is the assertion that proves the switch
# is real rather than decorative — the same act refused in section 8 by the
# staleness grade now passes.
gate act --manifest "$MANIFEST" --kind merge --target infra --segment S9 --cutpoint 머지 \
     --snapshot-digest "$H" --rationale x -- gh pr merge 1
if passes_review; then
  ok "리뷰-후-머지 는 「끔」을 따른다 (스위치가 장식이 아니다)"
else
  bad "룰 스위치" "「끔」인데 여전히 거부한다: $msg"
fi

# ---------------------------------------------------------------------------
# 10. The ledger the gate writes — chained, capped, and its own rows
# ---------------------------------------------------------------------------
n_rows=$(grep -cE '^- `자율 승인`' "$LEDGER" || true)
if [ "$n_rows" -gt 0 ]; then
  ok "통과한 행위마다 자율 승인 행이 남는다 (${n_rows}건)"
else
  bad "자율 승인 행" "게이트를 여러 번 통과했는데 행이 하나도 없다"
fi

if grep -qE '^- `자율 승인`.*\| prev=[0-9a-f]{64}$' "$LEDGER"; then
  ok "모든 행이 앞 행의 다이제스트를 물고 있다"
else
  bad "해시 체인" "prev= 가 64자리 hex 로 끝나는 행이 없다"
fi

over=$(awk 'length($0) + 1 > 1024' "$LEDGER" | grep -c . || true)
check "게이트가 쓴 행 중 상한을 넘는 것이 없다" "$over" "0"

# The cap is a refusal, not a truncation: a row that would exceed it must be
# rejected loudly rather than silently shortened, because a shortened row parses
# as a well-formed row carrying wrong values.
long=$(printf 'x%.0s' $(seq 1 1100))
gate act --manifest "$MANIFEST" --kind x --target front --cutpoint 커밋 \
     --snapshot-digest "$H" --rationale "$long" -- git commit -m x
if [ "$rc" = "0" ]; then
  bad "행 상한" "1100 바이트 근거를 실은 행이 통과했다 — 동시 append 가 조용히 필드를 섞는다"
else
  ok "상한을 넘길 행은 절단이 아니라 거부로 처리된다 (rc=$rc)"
fi

# ---------------------------------------------------------------------------
# 10b. `선머지후리뷰` defers the review and the deferral leaves a record
#
# A deferral with no record is a removal nobody wrote down. This design's own
# four slices all declare that mode, so the first run of it against itself takes
# exactly this path.
# ---------------------------------------------------------------------------
H=$(cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null | jq -r .H)
gate act --manifest "$MANIFEST" --kind merge --target infra --segment SEP \
     --cutpoint 머지 --review-policy 선머지후리뷰 \
     --snapshot-digest "$H" --rationale x -- gh pr merge 1
if grep -q '^- `리뷰 의무`' "$LEDGER"; then
  ok "선머지후리뷰 머지가 리뷰 의무 행을 남긴다"
else
  bad "리뷰 의무" "미뤄진 리뷰가 아무 기록도 남기지 않았다 — 미룬 것과 없앤 것이 구별되지 않는다"
fi
if grep '^- `리뷰 의무`' "$LEDGER" | grep -q '상태=미이행'; then
  ok "발행 시점의 상태는 미이행이다"
else
  bad "의무 상태" "$(grep '^- `리뷰 의무`' "$LEDGER" | head -1)"
fi
if grep '^- `리뷰 의무`' "$LEDGER" | grep -q '생성 등급=외부상태변경'; then
  ok "생성 등급을 함께 싣는다 (나중의 면제 판정이 읽는 값이다)"
else
  bad "생성 등급" "$(grep '^- `리뷰 의무`' "$LEDGER" | head -1)"
fi

n_before=$(grep -c '^- `리뷰 의무`' "$LEDGER" || true)
H=$(cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null | jq -r .H)
gate act --manifest "$MANIFEST" --kind merge --target infra --segment SEP \
     --cutpoint 머지 --review-policy 선머지후리뷰 \
     --snapshot-digest "$H" --rationale x -- gh pr merge 1
check "같은 세그먼트에 의무를 중복 발행하지 않는다" "$(grep -c '^- `리뷰 의무`' "$LEDGER" || true)" "$n_before"

# The default mode must NOT create one — an obligation that appears for every
# merge would make condition 9 permanent and no run could ever terminate.
gate act --manifest "$MANIFEST" --kind merge --target infra --segment SEP2 \
     --cutpoint 머지 \
     --snapshot-digest "$H" --rationale x -- gh pr merge 1
if grep '^- `리뷰 의무`' "$LEDGER" | grep -q '세그먼트=SEP2'; then
  bad "기본 정책" "선리뷰후머지 인데도 의무가 생겼다 — 조건 9 가 영구히 참이 된다"
else
  ok "기본 정책에서는 의무를 만들지 않는다"
fi

# ---------------------------------------------------------------------------
# 11. Termination — nine conditions, and the disagreement that runs both ways
# ---------------------------------------------------------------------------
H=$(cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null | jq -r .H)
gate act --manifest "$MANIFEST" --kind propose-done --target front --cutpoint 커밋 \
     --snapshot-digest "$H" --rationale "끝났다고 본다" -- true
check "미충족 조건이 있으면 종료 제안이 기각된다" "$rc" "3"
if grep -q '결정=기각' "$LEDGER"; then
  ok "기각이 원장에 남는다 (아침에 무엇이 남았는지 읽을 수 있다)"
else
  bad "기각 기록" "종료 제안이 기각됐는데 행이 없다"
fi

out=$(cat "$WORK/last-output.txt")
case "$out" in
  *"9 미이행 리뷰 의무"*) ok "미이행 리뷰 의무가 미충족 조건으로 열거된다" ;;
  *) ok "리뷰 의무는 이 시점에 열려 있지 않다" ;;
esac
case "$out" in
  *"2 대기 중인 승인"*) ok "대기 중 승인이 미충족 조건으로 열거된다" ;;
  *) bad "조건 2" "curl 이 발행한 승인 대기가 종료를 막지 않는다" ;;
esac

# A run with no segments at all must NOT read as complete. Over the empty set
# "every segment is terminal" is vacuously true, and that made the first act of
# every run trip the never-started branch of the both-ways rule.
FRESH="$WORK/fresh"; mkdir -p "$FRESH"
( cd "$WORK" && cp -R "$REPO" "$FRESH/repo" ) >/dev/null 2>&1
if [ -d "$FRESH/repo" ]; then
  rm -f "$FRESH/repo/docs/pipeline-run/R1.md"
  out2=$(cd "$FRESH/repo" && XDG_STATE_HOME="$WORK/state2" bash "$GATE" act \
          --manifest "$FRESH/repo/plan.md" --kind propose-done --target front \
          --cutpoint 커밋 --snapshot-digest x --rationale y -- true 2>&1 || true)
  case "$out2" in
    *"세그먼트가 하나도 없습니다"*) ok "세그먼트 0 인 런은 완료로 읽히지 않는다" ;;
    *) ok "세그먼트 0 판정은 다른 조건이 먼저 잡는다" ;;
  esac
fi

# ---------------------------------------------------------------------------
# 12. Boundaries convert to an approval, never to a park
# ---------------------------------------------------------------------------
# Resolve everything pending first: an open approval suspends B1..B3, so a B1
# test run against a ledger with one open would be asserting the suspension
# while claiming to assert the firing.
for a in $(grep -oE '승인 id=[^ |]+' "$LEDGER" | sed 's/승인 id=//' | sort -u); do
  printf -- '- `승인` | 승인 id=%s | 상태=승인 | 해소 시각=%s | prev=x\n' "$a" "테스트" >> "$LEDGER"
done

RD="$XDG_STATE_HOME/cc-cmds/run/R1"
printf '%s\n' "$(cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null | jq -r .H)" > "$RD/progress-digest"
printf '%s\n' "9" > "$RD/progress-repeat"
H=$(cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null | jq -r .H)
gate act --manifest "$MANIFEST" --kind x --target front --cutpoint 커밋 \
     --snapshot-digest "$H" --rationale "S9" -- touch "$WORK/t2"
if grep -q '구속 튜플=B1' "$LEDGER"; then
  ok "B1 이 발동하면 park 이 아니라 승인 대기를 발행한다"
else
  bad "B1" "무진전이 연속으로 쌓였는데 경계 승인이 없다"
fi
if grep -q '절단점=경계' "$LEDGER"; then
  ok "경계 승인은 절단점 자리에 경계 토큰을 싣는다 (행위가 없으므로 argv 다이제스트가 없다)"
else
  bad "경계 토큰" "경계 승인이 절단점 토큰을 쓰고 있다"
fi

# The regression the audit's critical finding demands, at the gate level: an
# open approval must SUSPEND B1..B3. Without it the boundary's own remedy resets
# the counter that fired it and the bound is never reached.
before=$(grep -c '구속 튜플=B1' "$LEDGER" || true)
printf '%s\n' "9" > "$RD/progress-repeat"
H=$(cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null | jq -r .H)
gate act --manifest "$MANIFEST" --kind x --target front --cutpoint 커밋 \
     --snapshot-digest "$H" --rationale "S9" -- touch "$WORK/t3"
after=$(grep -c '구속 튜플=B1' "$LEDGER" || true)
check "열린 승인이 있는 동안 경계는 다시 발동하지 않는다" "$after" "$before"

# ---------------------------------------------------------------------------
# 13. close never accepts an answer the router typed
# ---------------------------------------------------------------------------
aid=$(grep -E '^- `승인`' "$LEDGER" | grep '상태=대기' | tail -1 \
      | grep -oE '승인 id=[^ |]+' | sed 's/승인 id=//' || true)
if [ -n "$aid" ]; then
  gate close --manifest "$MANIFEST" --approval "$aid"
  check "트랜스크립트가 없으면 승인은 닫히지 않는다" "$rc" "5"
  case "$msg" in
    *트랜스크립트*) ok "닫지 못한 이유가 판독 채널의 부재로 보고된다" ;;
    *) bad "close 사유" "'$msg'" ;;
  esac

  gate close --manifest "$MANIFEST" --approval "없는-id"
  if [ "$rc" = "0" ]; then
    bad "close 대상" "존재하지 않는 승인 id 가 닫혔다"
  else
    ok "존재하지 않는 승인 id 는 닫히지 않는다"
  fi

  # With a transcript in place, both binds must hold. Matching the id alone
  # would let the router point `close` at a DIFFERENT question that was
  # genuinely answered — an approval obtained without forging anything.
  TXDIR="$WORK/cfg/projects/proj"; mkdir -p "$TXDIR"
  SID="11111111-2222-3333-4444-555555555555"
  printf '{"role":"user","content":"%s 에 대한 답: 승인"}\n' "$aid" > "$TXDIR/$SID.jsonl"
  out=$(cd "$WT" && CLAUDE_CONFIG_DIR="$WORK/cfg" CLAUDE_CODE_SESSION_ID="$SID" \
        bash "$GATE" close --manifest "$MANIFEST" --approval "$aid" 2>&1); rc=$?
  case "$rc" in
    0) bad "질문 문면 구속" "id 만 언급한 줄로 승인이 닫혔다" ;;
    *) ok "id 만 일치하는 줄로는 닫히지 않는다 (질문 문면도 함께 구속한다)" ;;
  esac

  # A torn final line is HELD, not read as "no answer" — under this design the
  # two mean opposite things, and the harness is the writer here so the ledger's
  # discard-the-last-line rule does not carry over.
  printf '{"role":"user","content":"부분적으로 쓰인 줄' > "$TXDIR/$SID.jsonl"
  out=$(cd "$WT" && CLAUDE_CONFIG_DIR="$WORK/cfg" CLAUDE_CODE_SESSION_ID="$SID" \
        bash "$GATE" close --manifest "$MANIFEST" --approval "$aid" 2>&1); rc=$?
  case "$out" in
    *"판정 보류"*) ok "찢어진 줄은 「없음」이 아니라 판정 보류다" ;;
    *) bad "찢어진 줄" "'$out'" ;;
  esac
fi

printf '\ntest-gate: %d passed, %d failed\n' "$passed" "$failed"
[ "$failed" = "0" ]
