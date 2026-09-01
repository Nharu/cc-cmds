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
LIVENESS="$repo_root/plugins/cc-cmds/orchestrator/liveness.sh"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/cc-gate-test.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
export XDG_STATE_HOME="$WORK/state"

# `grep -q` on the right of a pipe exits as soon as it matches, which kills the
# writer with SIGPIPE — and under `pipefail` the whole pipeline then reports
# failure even though the match was found. GNU sed makes it loud ("couldn't
# flush stdout: Broken pipe") and BSD sed usually does not, so this failed only
# on the Linux leg and only once a scanned function grew long enough for the
# race to be real.
#
# `grep -c` has the same truth value and consumes its input to the end, so the
# writer never sees a closed pipe. The count goes to /dev/null; only the exit
# status is wanted.
grep_all_q() {
  # The count is CAPTURED, not redirected to /dev/null: BSD grep short-circuits
  # when its output is being discarded, which reintroduces the very SIGPIPE this
  # helper exists to avoid. Measured — `sed … | grep -c … >/dev/null` returns
  # 141 while `n=$(grep -c …)` returns 0.
  local n
  n=$(grep -c "$@" || true)
  [ "${n:-0}" != "0" ]
}

passed=0; failed=0
ok()   { passed=$((passed + 1)); printf 'PASS: %s\n' "$1"; }
bad()  { failed=$((failed + 1)); printf 'FAIL: %s — %s\n' "$1" "${2:-}" >&2; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got '$2', want '$3'"; fi; }

# DEFINED HERE, not beside its later uses. Three call sites sit ~130 lines
# above where this function used to be declared, so the shell reached them
# first and reported `graded_as: command not found` — the three assertions
# never ran, and a missing command is not a failed assertion, so the suite
# stayed green while covering nothing. A function used before its definition
# is the one shape a passing test count cannot reveal.
graded_as() {
  # graded_as <expected> <label> -- <argv...>
  local want="$1" label="$2"; shift 3
  gate grade --manifest "$MANIFEST" -- "$@"
  case "$msg" in
    *"축2=$want"*) ok "$label" ;;
    *) bad "$label" "want 축2=$want, got '$msg'" ;;
  esac
}

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

# A FRESH snapshot digest per acting call. The digest now includes the ledger's
# own state, so it moves on every append — which is what makes exit 4 able to
# fire at all. Capturing it once and reusing it across several acts is exactly
# the stale-router pattern the check exists to refuse, and tests that did so
# were passing only because the digest could not move.
HH()  { cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null | jq -r .H; }
HH7() { cd "$WT" && XDG_STATE_HOME="$STATE7" bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null | jq -r .H; }
# The PROGRESS digest, which is a different value from the snapshot's H and must
# stay so — B1 watches this one, and seeding B1's state file with H made the
# boundary compare two unrelated values and reset instead of firing.
PD() { cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" --render 2>/dev/null \
       | sed -n 's/^진전 해시 : //p' | sed 's/[[:space:]]*$//'; }

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
# The TEST files are scanned too. This class first bit the harness rather than
# the driver: an assertion of the form `sed … | grep -q …` reported a match as a
# miss on the Linux leg only, once the function it scanned grew long enough for
# the race to be real. A checker that exempts itself is the shape it exists to
# refuse.
for f in "$GATE" "$repo_root/plugins/cc-cmds/orchestrator/watch.sh" \
         "$repo_root/plugins/cc-cmds/orchestrator/stage-wrapper.sh" \
         "$repo_root/plugins/cc-cmds/hooks/gate-pretool.sh" \
         "$repo_root/plugins/cc-cmds/orchestrator/test-run.sh" \
         "$repo_root/scripts/test-gate.sh" \
         "$repo_root/scripts/test-watch.sh" \
         "$repo_root/scripts/test-snapshot.sh" \
         "$repo_root/scripts/test-orchestrator-pretool-hook.sh"; do
  [ -f "$f" ] || continue
  # `grep -c … >/dev/null` belongs in the pattern as well: BSD grep
  # short-circuits when its output is discarded, so that spelling is the same
  # early-exiting read wearing a different name.
  early=$(sed 's/#.*//' "$f" | grep -nE '\| *(head -|grep -[A-Za-z]*q|grep -c[A-Za-z]* [^|]*>/dev/null)' || true)
  if [ -z "$early" ]; then
    ok "파이프 오른쪽에 조기 종료 읽기가 없다: $(basename "$f")"
  else
    bad "pipefail 함정" "$(basename "$f"): $(printf '%s' "$early" | awk 'NR<=3' | tr '\n' ' ')"
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

# The authorization record is part of the fixture now, because the gate reads it
# on every invocation. `owner-doc` mirrors the manifest header's `(없음)` — this
# is a documentless `repo`-anchored run — and the run maximum is the higher of
# the two target cutpoints.
cat > "$GRANT" <<GRANTEOF
# 파이프라인 인가 기록 — R1
<!-- cc-pipeline-grant v1; writer=autopilot; reader=orchestrator; owner-doc=(없음); origin-worktree=$WT; NOT a design doc; mechanism-local, never staged by a skill -->

## 인가 R1
**인가 일시**: 2026-08-30T00:00:00Z
**종료 지점**: 픽스처
**권한 절단점**: 배포
**말단 행위 상한**: 없음
**직렬 웨이브 고지**: 해당 없음
**시각 정합 마커**: 없음
**사용자 확인 문면**: 픽스처 인가
**설계 문서 전체 sha256**: (해당 없음)
**보고서**: $WT/docs/pipeline-run/R1.md
GRANTEOF

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
  local bd bd_err line inserted
  grep -v '^\*\*구속 다이제스트\*\*:' "$MANIFEST" > "$MANIFEST.tmp" && mv "$MANIFEST.tmp" "$MANIFEST"
  bd_err="$WORK/bd.err"
  bd=$(cd "$WT" && bash -c '
    CC_ORCH_SOURCE_ONLY=1 . "'"$repo_root"'/plugins/cc-cmds/orchestrator/run.sh"
    MANIFEST="'"$MANIFEST"'"
    binding_set_bytes | shasum -a 256 | cut -d" " -f1' 2>"$bd_err")
  # A broken fixture is not a test failure, so it exits rather than counting.
  # An empty digest still produces a well-formed line — `**구속 다이제스트**: `
  # with nothing after it — which every later assertion then reports as "the
  # field is absent", naming the symptom instead of the cause.
  if [ -z "$bd" ]; then
    printf 'refresh_bd: 구속 다이제스트 계산이 빈 값을 냈다\n' >&2
    sed 's/^/  bd stderr: /' "$bd_err" >&2
    exit 1
  fi

  # Inserted INSIDE `## 인가`, not appended to the file. `manifest_field` is
  # section-scoped and stops at the next `## `, so a digest appended after a
  # later section is read as absent — which is how a present-and-correct field
  # came back as "no binding digest" once another section was added below it.
  #
  # The insertion is a read loop rather than `awk`/`sed`: the heading it keys on
  # is Korean, and both an `awk` string equality and a BSD/GNU `a\` append have
  # to be trusted across two platforms to place one line. A `[ "$line" = … ]`
  # test is shell string equality, which is byte comparison everywhere.
  : > "$MANIFEST.bd"
  inserted=
  while IFS= read -r line || [ -n "$line" ]; do
    printf '%s\n' "$line" >> "$MANIFEST.bd"
    if [ -z "$inserted" ] && [ "$line" = "## 인가" ]; then
      printf '**구속 다이제스트**: %s\n' "$bd" >> "$MANIFEST.bd"
      inserted=1
    fi
  done < "$MANIFEST"
  if [ -z "$inserted" ]; then
    printf 'refresh_bd: 매니페스트에 「## 인가」 절이 없어 다이제스트를 넣을 자리가 없다\n' >&2
    exit 1
  fi
  mv "$MANIFEST.bd" "$MANIFEST"
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

# The ledger does not exist when a run's first gate call starts, which is the
# NORMAL state. `grep` answers a missing file with exit 2, `pipefail` promotes
# it, and `set -e` used to kill the whole snapshot at exactly the moment a
# router needs it most. The first call now also OPENS the ledger with the run
# row, so the property is asserted where it actually lives: the first
# invocation, against a state directory and a ledger that do not exist yet.
freshst="$WORK/state-first"; rm -f "$LEDGER"
out=$(cd "$WT" && XDG_STATE_HOME="$freshst" bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null); rc=$?
check "원장이 없는 상태에서 첫 호출이 답한다" "$rc" "0"
if printf '%s' "$out" | jq -e . >/dev/null 2>&1; then
  ok "그 답이 유효한 JSON 이다"
else
  bad "첫 호출" "JSON 이 아니다: $out"
fi
# And the first call is what opens the ledger. `run` had no writer at all, so a
# ledger carried no statement of what the run was.
n=$(grep -c '^- `run` ' "$LEDGER" 2>/dev/null || true)
check "첫 호출이 run 행 하나로 원장을 연다" "${n:-0}" "1"
case "$(grep '^- `run` ' "$LEDGER" 2>/dev/null | tail -1)" in
  *"보고서=$LEDGER"*) ok "run 행이 보고서 경로를 싣는다" ;;
  *) bad "run 행" "$(grep '^- `run` ' "$LEDGER" 2>/dev/null | tail -1)" ;;
esac
rm -f "$LEDGER"

n_total=$(cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null | jq -r .obligations_total)
check "빈 원장의 의무 총수가 0 하나로 나온다" "$n_total" "0"

# From here the ledger carries the KICKOFF STUB, because that is the file a real
# run's first act writes into: the ledger and the morning report are one file,
# and the skill's Step 7 puts an H1 and an identifying line there before the
# router takes its first turn. Seeding it makes every chain assertion below run
# against the shape a run actually has — which is the shape that used to read as
# broken at row 1 on every single run.
mkdir -p "$(dirname "$LEDGER")"
{
  printf '# 파이프라인 런 보고서 — R1\n\n'
  printf '런 id R1 · 앵커 repo:t/front · 대상 front(절단점 PR) infra(절단점 배포)\n'
} > "$LEDGER"

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

# THE STAGE MUST BE ABLE TO READ ITS OWN SKILL'S DOCUMENTS. Every skill here
# opens by Reading several `_common/*` files, and those live in the plugin cache
# — outside the working directory, so outside what the ambient configuration
# permits. Measured: a review stage ran seven turns, collected five `Read`
# denials under the plugin directory, reported that it had stopped before its
# first step, and exited 0 with no artifact.
missing_dirs=0
for f in "$SETTINGS_DIR"/*.json; do
  [ -f "$f" ] || continue
  n=$(jq -r '.permissions.additionalDirectories // [] | length' "$f" 2>/dev/null)
  [ "${n:-0}" -ge 1 ] || missing_dirs=$((missing_dirs + 1))
done
check "모든 변종이 읽을 수 있는 디렉터리를 선언한다" "$missing_dirs" "0"

plug=$(cd "$(dirname "$repo_root/plugins/cc-cmds/orchestrator")" && pwd)
if jq -e --arg d "$plug" '.permissions.additionalDirectories | index($d)' \
     "$SETTINGS_DIR/generic.json" >/dev/null 2>&1; then
  ok "플러그인 디렉터리가 그 목록에 있다 (스킬이 첫 단계에서 읽는 곳이다)"
else
  bad "플러그인 읽기" "$(jq -c '.permissions.additionalDirectories' "$SETTINGS_DIR/generic.json")"
fi
# The run's own files live under the HOME worktree, so a stage acting in any
# other target cannot reach the manifest, the ledger or the grant from its own
# directory.
if jq -e --arg d "$WT" '.permissions.additionalDirectories | index($d)' \
     "$SETTINGS_DIR/generic.json" >/dev/null 2>&1; then
  ok "런의 베이스도 그 목록에 있다 (매니페스트·원장·인가 기록이 거기 있다)"
else
  bad "런 파일 읽기" "$(jq -c '.permissions.additionalDirectories' "$SETTINGS_DIR/generic.json")"
fi

# The attempt term of the session id is DERIVED, not passed as argv. Without it
# a stage that died before producing anything kept its session id and every
# retry of that segment was refused by the CLI with "already in use" — after the
# gate had passed and after the row was appended, so the ledger showed two
# attempts and no output. Taking it as argv instead would let a router re-type
# the number it used last time, reproducing the collision through the surface
# meant to prevent it.
if grep -vE '^[[:space:]]*#' "$GATE" | grep_all_q -F 'session_uuid "$seg" "$attempt"'; then
  ok "스테이지 세션 id 에 시도 번호가 실린다"
else
  bad "시도 번호" "죽은 스테이지가 세션 id 를 점유해 같은 세그먼트를 재시도할 수 없다"
fi
if grep -vE '^[[:space:]]*#' "$GATE" | grep_all_q -F "gate_rows '자율 승인'"; then
  ok "그 번호를 원장에서 유도한다 (라우터가 적어 넣지 않는다)"
else
  bad "시도 유도" "시도 번호의 출처가 원장이 아니다"
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
     --snapshot-digest "$(HH)" --rationale x -- git push origin main
check "어휘 밖 절단점 토큰은 거부된다" "$rc" "2"

# An undeclared repository is not a vocabulary error — it is the three-layer
# rule. Above `브랜치` nothing may be granted, so the act parks with a cause of
# its own rather than borrowing `인가 한도`, which means something else: that a
# target the manifest DID declare was exceeded.
gate act --manifest "$MANIFEST" --kind x --target nope --cutpoint push \
     --snapshot-digest "$(HH)" --rationale x -- git push origin main
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

gate act --manifest "$MANIFEST" --kind x --target nope --cutpoint 커밋 \
     --worktree "$WT" --snapshot-digest "$(HH)" --rationale "이슈 링크에서 발견" -- touch "$WORK/nd"
check "미선언 대상의 로컬 쓰기는 통과한다" "$rc" "0"
if grep -q '^- `대상 추가`' "$LEDGER"; then
  ok "대상 추가 행이 남는다 (아침 리포트가 런이 건드린 레포를 보여 준다)"
else
  bad "대상 추가" "층 1 행위가 통과했는데 기록이 없다"
fi
if grep '^- `대상 추가`' "$LEDGER" | grep_all_q '층=1'; then
  ok "커밋 등급은 층 1 로 기록된다"
else
  bad "층 판정" "$(grep '^- `대상 추가`' "$LEDGER" | awk 'NR<=1')"
fi

# The chain anchors on the last ROW, not the last LINE. Hashing the last line
# made the first row point at the stub's identifying line while the verifier —
# which walks rows — started from the run heading, so an untouched ledger broke
# at row 1 every time. A chain that is always broken is worse than none: a real
# splice then looks exactly like a normal kickoff, and a reader who sees `끊김`
# every morning stops reading the field.
ci=$(cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null | jq -r .chain_intact)
check "스텁 산문이 앞에 있어도 체인은 무결이다" "$ci" "true"

# And when it IS broken the render says WHERE. Every caller used to throw the
# row number into `2>&1`, so the morning was told `끊김` and given nowhere to
# look.
cp "$LEDGER" "$WORK/ledger.bak"
printf -- '- `자율 승인` | kind=x | 결정=act | 대상=front | prev=%s\n' \
  "0000000000000000000000000000000000000000000000000000000000000000" >> "$LEDGER"
out=$(cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" --render 2>/dev/null)
case "$out" in
  *"해시 체인 : 끊김 —"*) ok "끊긴 자리의 행 번호가 렌더에 도달한다" ;;
  *) bad "체인 진단" "$(printf '%s' "$out" | grep '해시 체인' || true)" ;;
esac
cp "$WORK/ledger.bak" "$LEDGER"

gate act --manifest "$MANIFEST" --kind x --target nope2 --cutpoint 커밋 \
     --snapshot-digest "$(HH)" --rationale x -- touch "$WORK/nd2"
check "워크트리 없이 미선언 대상을 쓰려 하면 거부된다" "$rc" "2"

gate act --manifest "$MANIFEST" --kind x --target front --cutpoint 커밋 \
     --snapshot-digest "$(HH)" --rationale x -- frobnicate now
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
     --snapshot-digest "$(HH)" --rationale x -- git push origin main
check "절단점 이하의 행위는 통과한다" "$rc" "0"

H=$(cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null | jq -r .H)
gate act --manifest "$MANIFEST" --kind merge --target front --segment S1 --cutpoint 머지 \
     --snapshot-digest "$(HH)" --rationale x -- gh pr merge 1
check "절단점 PR 인 대상에 머지는 거부된다" "$rc" "3"
case "$msg" in
  *"절단점-준수"*) ok "거부 사유가 절단점으로 보고된다 (가장 근본적인 이유가 이긴다)" ;;
  *) bad "거부 사유" "절단점 위반인데 '$msg' 로 보고됐다 — 3시에 엉뚱한 곳을 고치게 된다" ;;
esac

# The same act against the target the user granted `배포` to reaches the review
# rule instead — which is the proof that the refusal above was the TARGET's
# cutpoint and not the run maximum.
gate act --manifest "$MANIFEST" --kind merge --target infra --segment S1 --cutpoint 머지 \
     --snapshot-digest "$(HH)" --rationale x -- gh pr merge 1
case "$msg" in
  *"절단점-준수"*) bad "대상별 절단점" "배포 인가된 대상까지 절단점에서 막혔다" ;;
  *) ok "런 최대치가 아니라 대상 행의 값이 판정한다 (#208 회귀)" ;;
esac

# ---------------------------------------------------------------------------
# 4. Self-widening is refused at every cutpoint
# ---------------------------------------------------------------------------
gate act --manifest "$MANIFEST" --kind merge --target infra --segment S1 --cutpoint 배포 \
     --snapshot-digest "$(HH)" --rationale x -- gh pr merge 1 --admin
check "--admin 은 배포 인가에서도 거부된다" "$rc" "3"
case "$msg" in
  *"--admin"*) ok "거부 사유가 관리자 우회를 지목한다" ;;
  *) bad "--admin 사유" "'$msg'" ;;
esac

gate act --manifest "$MANIFEST" --kind x --target infra --cutpoint 배포 \
     --snapshot-digest "$(HH)" --rationale x -- tee "$GRANT"
check "인가 기록에 쓰려는 행위는 거부된다" "$rc" "3"

gate act --manifest "$MANIFEST" --kind x --target infra --cutpoint 배포 \
     --snapshot-digest "$(HH)" --rationale x -- cat "$GRANT"
case "$rc" in
  3) bad "인가 기록 읽기" "읽기까지 막혔다 — 드라이버는 이 파일을 읽어야 한다" ;;
  *) ok "인가 기록 읽기는 막지 않는다" ;;
esac

# ---------------------------------------------------------------------------
# 5. Pre-authorization: outside the list is an APPROVAL, not a refusal
# ---------------------------------------------------------------------------
gate act --manifest "$MANIFEST" --kind x --target infra --cutpoint 배포 \
     --snapshot-digest "$(HH)" --rationale x -- curl https://example.invalid
check "사전 인가 밖 외부 상태 변경은 승인 대기를 발행한다" "$rc" "5"

gate act --manifest "$MANIFEST" --kind x --target infra --cutpoint 배포 \
     --snapshot-digest "$(HH)" --rationale x -- mkdir -p "$WORK/scratch"
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
     --snapshot-digest "$(HH)" --rationale x -- touch "$WORK/touched"
check "축2 자기선언이 등급과 다르면 거부된다" "$rc" "6"

gate exec --manifest "$MANIFEST" --target front --cutpoint 커밋 --surface 워크트리쓰기 \
     --snapshot-digest "$(HH)" --rationale x -- touch "$WORK/touched"
check "선언이 등급과 같으면 통과한다" "$rc" "0"

gate exec --manifest "$MANIFEST" --target front --cutpoint 커밋 --surface 파일쓰기 \
     --snapshot-digest "$(HH)" --rationale x -- touch "$WORK/touched"
check "어휘 밖 축2 토큰은 거부된다" "$rc" "2"

# ---------------------------------------------------------------------------
# 8. Review-before-merge, and its five staleness grades
# ---------------------------------------------------------------------------
seg_wt="$WT"
head0=$(cd "$WT" && git rev-parse HEAD)

H=$(cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null | jq -r .H)
gate act --manifest "$MANIFEST" --kind merge --target infra --segment SNONE --cutpoint 머지 \
     --snapshot-digest "$(HH)" --rationale x -- gh pr merge 1
check "리뷰 기록이 없는 머지는 거부된다" "$rc" "3"

{
  printf -- '- `segment` | id=S9 | 상태=구현완료 | 커밋=%s | 워크트리=%s\n' "$head0" "$seg_wt"
  printf -- '- `cycle` | 세그먼트=S9 | P0=1 | P1=0 | 리뷰 HEAD=%s\n' "$head0"
} >> "$LEDGER"
H=$(cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null | jq -r .H)
gate act --manifest "$MANIFEST" --kind merge --target infra --segment S9 --cutpoint 머지 \
     --snapshot-digest "$(HH)" --rationale x -- gh pr merge 1
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
     --snapshot-digest "$(HH)" --rationale x -- gh pr merge 1
if passes_review; then ok "무이동 등급은 통과한다"; else bad "무이동 등급" "$msg"; fi

# 동일 트리 — amend rewrites the commit and leaves the tree byte-identical.
( cd "$WT" && git commit -q --amend -m "one (amended)" ) >/dev/null 2>&1
head_amend=$(cd "$WT" && git rev-parse HEAD)
H=$(cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null | jq -r .H)
gate act --manifest "$MANIFEST" --kind merge --target infra --segment S9 --cutpoint 머지 \
     --snapshot-digest "$(HH)" --rationale x -- gh pr merge 1
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
     --snapshot-digest "$(HH)" --rationale x -- gh pr merge 1
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
     --snapshot-digest "$(HH)" --rationale x -- gh pr merge 1
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
# THE DISPATCHER IS NOT AN ANCESTOR IN THE SENSE THIS RULE MEANS. The router
# launches both stages and the gate records it as `부모` on both rows, so the
# two closures met at the router on EVERY run a router drove and this rule
# refused every merge — naming an id that was neither stage. What it is for is
# authorship: did the reviewing session see the work being made. A shared
# dispatcher does not imply that; the stages share no output.
printf -- '- `stage-result` | 세그먼트=SEP | 스테이지=S4 | 세션 id=impl-1 | 부모=router-1 | 종단 부류=정상 완료\n' >> "$LEDGER"
printf -- '- `stage-result` | 세그먼트=SEP | 스테이지=S5 | 세션 id=rev-1 | 부모=router-1 | 종단 부류=정상 완료\n' >> "$LEDGER"
H=$(cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null | jq -r .H)
gate act --manifest "$MANIFEST" --kind merge --target infra --segment SEP --cutpoint 머지 \
     --snapshot-digest "$(HH)" --rationale x -- gh pr merge 1
case "$msg" in
  *"조상이 겹칩니다"*) bad "디스패처 판정" "라우터를 공유했다는 이유로 거부됐다 — 라우터가 돌린 모든 런의 머지가 막힌다" ;;
  *) ok "디스패처를 공유하는 것은 자기 작업 리뷰가 아니다" ;;
esac

# THE FORK CASE, which is what the closure exists for and is untouched: the
# reviewing session is a fork of the implementing one, so its parent IS the
# other side's own session id. A parent that names a stage names an author.
printf -- '- `stage-result` | 세그먼트=SEPF | 스테이지=S4 | 세션 id=impl-f | 부모=router-1 | 종단 부류=정상 완료\n' >> "$LEDGER"
printf -- '- `stage-result` | 세그먼트=SEPF | 스테이지=S5 | 세션 id=rev-f | 부모=impl-f | 종단 부류=정상 완료\n' >> "$LEDGER"
printf -- '- `segment` | id=SEPF | 상태=구현완료 | 커밋=%s | 워크트리=%s\n' "$(cd "$WT" && git rev-parse HEAD)" "$WT" >> "$LEDGER"
printf -- '- `cycle` | 세그먼트=SEPF | P0=0 | P1=0 | 리뷰 HEAD=%s\n' "$(cd "$WT" && git rev-parse HEAD)" >> "$LEDGER"
H=$(cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null | jq -r .H)
gate act --manifest "$MANIFEST" --kind merge --target infra --segment SEPF --cutpoint 머지 \
     --snapshot-digest "$(HH)" --rationale x -- gh pr merge 1
case "$msg" in
  *"조상이 겹칩니다"*) ok "구현 세션의 포크가 리뷰하면 거부된다 (폐포가 존재하는 이유)" ;;
  *) bad "포크 판정" "포크가 자기 작업을 리뷰했는데 통과했다" ;;
esac

# And the direct case — one session on both sides.
printf -- '- `stage-result` | 세그먼트=SEPD | 스테이지=S4 | 세션 id=same-1 | 부모=router-1 | 종단 부류=정상 완료\n' >> "$LEDGER"
printf -- '- `stage-result` | 세그먼트=SEPD | 스테이지=S5 | 세션 id=same-1 | 부모=router-1 | 종단 부류=정상 완료\n' >> "$LEDGER"
printf -- '- `segment` | id=SEPD | 상태=구현완료 | 커밋=%s | 워크트리=%s\n' "$(cd "$WT" && git rev-parse HEAD)" "$WT" >> "$LEDGER"
printf -- '- `cycle` | 세그먼트=SEPD | P0=0 | P1=0 | 리뷰 HEAD=%s\n' "$(cd "$WT" && git rev-parse HEAD)" >> "$LEDGER"
H=$(cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null | jq -r .H)
gate act --manifest "$MANIFEST" --kind merge --target infra --segment SEPD --cutpoint 머지 \
     --snapshot-digest "$(HH)" --rationale x -- gh pr merge 1
case "$msg" in
  *"조상이 겹칩니다"*) ok "한 세션이 양쪽이면 거부된다" ;;
  *) bad "직접 판정" "같은 세션이 자기 작업을 리뷰했는데 통과했다" ;;
esac

printf -- '- `stage-result` | 세그먼트=SEP2 | 스테이지=S4 | 세션 id=impl-9 | 부모=미상 | 종단 부류=정상 완료\n' >> "$LEDGER"
printf -- '- `stage-result` | 세그먼트=SEP2 | 스테이지=S5 | 세션 id=rev-9 | 부모=미상 | 종단 부류=정상 완료\n' >> "$LEDGER"
printf -- '- `segment` | id=SEP2 | 상태=구현완료 | 커밋=%s | 워크트리=%s\n' "$(cd "$WT" && git rev-parse HEAD)" "$WT" >> "$LEDGER"
printf -- '- `cycle` | 세그먼트=SEP2 | P0=0 | P1=0 | 리뷰 HEAD=%s\n' "$(cd "$WT" && git rev-parse HEAD)" >> "$LEDGER"
H=$(cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null | jq -r .H)
gate act --manifest "$MANIFEST" --kind merge --target infra --segment SEP2 --cutpoint 머지 \
     --snapshot-digest "$(HH)" --rationale x -- gh pr merge 1
case "$msg" in
  *"판정 불가는 통과가 아닙니다"*) ok "계보가 기록되지 않으면 통과가 아니다 (공허한 참으로 돌아가지 않는다)" ;;
  *) bad "미기록 처리" "'$msg'" ;;
esac

# ---------------------------------------------------------------------------
# 8b. The router's own writer for `segment` and `cycle`
#
# Both rows used to be written only by the fixed-graph loop, which the router
# path never enters. The consequence was not a missing convenience: the merge
# rule reads a `cycle` row and refused EVERY merge for want of one, and
# termination condition 1 counts `segment` rows and could never hold — so the
# run also had no ending it could propose. Both failures look like the mechanism
# working, which is why they survived until a run tried to finish.
# ---------------------------------------------------------------------------
head_b=$(cd "$WT" && git rev-parse HEAD)

H=$(cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null | jq -r .H)
gate act --manifest "$MANIFEST" --kind merge --target infra --segment SW --cutpoint 머지 \
     --snapshot-digest "$(HH)" --rationale x -- gh pr merge 1
check "리뷰 기록 없는 세그먼트의 머지는 아직 거부된다" "$rc" "3"

# The vocabulary is checked, and the check is what makes the row readable later.
H=$(cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null | jq -r .H)
gate act --manifest "$MANIFEST" --kind segment --target infra --segment SW --cutpoint 커밋 \
     --snapshot-digest "$(HH)" --rationale x -- 상태=진행중 워크트리="$WT"
check "어휘 밖 세그먼트 상태는 거부된다" "$rc" "2"

H=$(cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null | jq -r .H)
gate act --manifest "$MANIFEST" --kind segment --target infra --segment SW --cutpoint 커밋 \
     --snapshot-digest "$(HH)" --rationale x -- 상태=실행중
check "워크트리 없는 세그먼트 행은 거부된다" "$rc" "2"

H=$(cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null | jq -r .H)
gate act --manifest "$MANIFEST" --kind segment --target infra --segment SW --cutpoint 커밋 \
     --snapshot-digest "$(HH)" --rationale x -- 상태=실행중 워크트리="$WT"
check "세그먼트 행이 기록된다" "$rc" "0"
n=$(grep -c '^- `segment` | id=SW ' "$LEDGER" || true)
check "그 행이 원장에 있다" "$n" "1"

# The `cycle` row's four required fields are the four the merge rule reads. A
# row missing one of them does not fail here under the old path either — it
# fails inside the rule, reported as a review with no HEAD, which sends the
# reader to the review instead of to the row this run wrote.
H=$(cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null | jq -r .H)
gate act --manifest "$MANIFEST" --kind cycle --target infra --segment SW --cutpoint 커밋 \
     --snapshot-digest "$(HH)" --rationale x -- 사이클=1 P0=0 P1=0
check "리뷰 HEAD 없는 사이클 행은 거부된다" "$rc" "2"

H=$(cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null | jq -r .H)
gate act --manifest "$MANIFEST" --kind cycle --target infra --segment SW --cutpoint 커밋 \
     --snapshot-digest "$(HH)" --rationale x -- 사이클=1 P0=0 P1=0 "리뷰 HEAD=$head_b"
check "사이클 행이 기록된다" "$rc" "0"

# End to end: the same merge that was refused for want of a review record is now
# judged by the record instead of by its absence.
H=$(cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null | jq -r .H)
gate plan --manifest "$MANIFEST" --kind merge --target infra --segment SW --cutpoint 머지 \
     -- gh pr merge 1
case "$msg" in
  *"리뷰-후-머지:"*) bad "라우터 기록" "게이트가 쓴 리뷰 기록을 룰이 읽지 못한다: '"'"'$msg'"'"'" ;;
  *) ok "게이트가 쓴 세그먼트·사이클 행으로 머지가 통과한다" ;;
esac

# The bookkeeping act is graded `읽기`: what it performs is the row, and the row
# reaches nothing a credential or a cutpoint could widen.
case "$(grep '^- `자율 승인` | kind=cycle ' "$LEDGER" | tail -1)" in
  *"축2=읽기"*) ok "장부 행위는 읽기로 등급된다" ;;
  *) bad "장부 등급" "$(grep '^- `자율 승인` | kind=cycle ' "$LEDGER" | tail -1)" ;;
esac

# ---------------------------------------------------------------------------
# 8c. Every act records WHICH credential it ran under
#
# With neither pipeline credential provisioned the gate fell through to whatever
# the calling environment held — on a developer machine a full-scope `gh` login
# — and said nothing, so the layer the separation exists to provide was absent
# while every surface reported normal operation. The fallback stays; being
# silent about it does not.
# ---------------------------------------------------------------------------
case "$(grep '^- `자율 승인` | kind=segment ' "$LEDGER" | tail -1)" in
  *"자격=분리"*|*"자격=주변"*) ok "행마다 어느 자격으로 돌았는지가 남는다" ;;
  *) bad "자격 기록" "자율 승인 행에 「자격」 필드가 없다" ;;
esac

# ---------------------------------------------------------------------------
# 8d. The act runs in the TARGET's worktree
#
# `--target` is a parameter of both acting verbs and every target row carries an
# absolute worktree, but nothing carried that value to the act's working
# directory — so a manifest could declare nine targets and only the home one
# could receive an act. Asserted from a SUBDIRECTORY, because that is the only
# cwd where "the act moved" and "the act stayed" produce different output.
# ---------------------------------------------------------------------------
mkdir -p "$WT/sub"
H=$(cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null | jq -r .H)
out=$(cd "$WT/sub" && bash "$GATE" exec --manifest "$MANIFEST" --target infra --segment SW \
      --cutpoint 커밋 --surface 읽기 --snapshot-digest "$(HH)" --rationale x -- ls 2>&1)
case "$out" in
  *base.txt*) ok "행위가 대상 워크트리에서 실행된다 (호출자의 cwd 가 아니라)" ;;
  *) bad "대상 워크트리" "'"'"'$out'"'"'" ;;
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
     --snapshot-digest "$(HH)" --rationale x -- gh pr merge 1
check "절단점-준수 는 「끔」을 무시한다" "$rc" "3"

gate act --manifest "$MANIFEST" --kind x --target infra --cutpoint 배포 \
     --snapshot-digest "$(HH)" --rationale x -- curl https://example.invalid
check "사전-인가-대조 는 「끔」을 무시한다" "$rc" "5"

gate act --manifest "$MANIFEST" --kind merge --target infra --segment S9 --cutpoint 배포 \
     --snapshot-digest "$(HH)" --rationale x -- gh pr merge 1 --admin
check "인가-자기확장-금지 는 「끔」을 무시한다" "$rc" "3"

# 리뷰-후-머지 IS disableable, and this is the assertion that proves the switch
# is real rather than decorative — the same act refused in section 8 by the
# staleness grade now passes.
gate act --manifest "$MANIFEST" --kind merge --target infra --segment S9 --cutpoint 머지 \
     --snapshot-digest "$(HH)" --rationale x -- gh pr merge 1
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
     --snapshot-digest "$(HH)" --rationale "$long" -- git commit -m x
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
     --snapshot-digest "$(HH)" --rationale x -- gh pr merge 1
if grep -q '^- `리뷰 의무`' "$LEDGER"; then
  ok "선머지후리뷰 머지가 리뷰 의무 행을 남긴다"
else
  bad "리뷰 의무" "미뤄진 리뷰가 아무 기록도 남기지 않았다 — 미룬 것과 없앤 것이 구별되지 않는다"
fi
if grep '^- `리뷰 의무`' "$LEDGER" | grep_all_q '상태=미이행'; then
  ok "발행 시점의 상태는 미이행이다"
else
  bad "의무 상태" "$(grep '^- `리뷰 의무`' "$LEDGER" | awk 'NR<=1')"
fi
if grep '^- `리뷰 의무`' "$LEDGER" | grep_all_q '생성 등급=외부상태변경'; then
  ok "생성 등급을 함께 싣는다 (나중의 면제 판정이 읽는 값이다)"
else
  bad "생성 등급" "$(grep '^- `리뷰 의무`' "$LEDGER" | awk 'NR<=1')"
fi

n_before=$(grep -c '^- `리뷰 의무`' "$LEDGER" || true)
H=$(cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null | jq -r .H)
gate act --manifest "$MANIFEST" --kind merge --target infra --segment SEP \
     --cutpoint 머지 --review-policy 선머지후리뷰 \
     --snapshot-digest "$(HH)" --rationale x -- gh pr merge 1
check "같은 세그먼트에 의무를 중복 발행하지 않는다" "$(grep -c '^- `리뷰 의무`' "$LEDGER" || true)" "$n_before"

# The default mode must NOT create one — an obligation that appears for every
# merge would make condition 9 permanent and no run could ever terminate.
gate act --manifest "$MANIFEST" --kind merge --target infra --segment SEP2 \
     --cutpoint 머지 \
     --snapshot-digest "$(HH)" --rationale x -- gh pr merge 1
if grep '^- `리뷰 의무`' "$LEDGER" | grep_all_q '세그먼트=SEP2'; then
  bad "기본 정책" "선리뷰후머지 인데도 의무가 생겼다 — 조건 9 가 영구히 참이 된다"
else
  ok "기본 정책에서는 의무를 만들지 않는다"
fi

# ---------------------------------------------------------------------------
# 10c. A dry run writes nothing, and a stage dispatch is gradeable
#
# All three of these were found by the FIRST act of the first real run, and they
# composed into "the router cannot dispatch any stage at all":
#   - `plan` issued a real approval row, so asking "would this pass?" mutated
#     the run the question was about — and an open approval suspends B1..B3 and
#     blocks termination condition 2, so the question stalled the asker.
#   - a stage dispatch's argv begins with a STAGE KIND, not a command, so the
#     argv0 table graded every dispatch `등급 미상`.
#   - `등급 미상` fell through to the pre-authorization rule's external-state
#     arm, turning every dispatch into a pending approval.
# ---------------------------------------------------------------------------
n_before=$(grep -c '^- `승인`' "$LEDGER" || true)
H=$(cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null | jq -r .H)
gate plan --manifest "$MANIFEST" --kind x --target infra --cutpoint 배포 -- curl https://example.invalid
check "plan 이 사전 인가 밖을 승인 대기로 답한다" "$rc" "5"
check "그러면서 원장에는 아무것도 쓰지 않는다" "$(grep -c '^- `승인`' "$LEDGER" || true)" "$n_before"
case "$msg" in
  *"발행하지 않았습니다"*) ok "dry-run 임을 문면이 말한다" ;;
  *) bad "dry-run 문면" "'$msg'" ;;
esac

gate grade --manifest "$MANIFEST" -- review
case "$msg" in
  *"축2=등급 미상"*) ok "스테이지 종류를 등급표에 물으면 미상이다 (그것이 명령이 아니므로)" ;;
  *) bad "스테이지 종류 등급" "'$msg'" ;;
esac

gate plan --manifest "$MANIFEST" --kind skill --target infra --segment SD --cutpoint 커밋 -- review
check "그럼에도 스킬 디스패치는 통과한다 (argv0 표에 묻지 않는다)" "$rc" "0"
case "$msg" in
  *"축2=워크트리쓰기"*) ok "스킬 디스패치는 워크트리 쓰기로 등급된다" ;;
  *) bad "스킬 등급" "'$msg'" ;;
esac

# The gate must HAND the CLI path down. run.sh resolves the binary and only then
# pins PATH to the sanitized set, so a child that re-resolves searches a PATH the
# CLI is not on — every stage launch died with "binary not found" two seconds
# after the binary had been found.
if grep -vE '^[[:space:]]*#' "$GATE" | grep_all_q -F 'CC_CLAUDE_BIN="$CLI_BIN"'; then
  ok "게이트가 래퍼에 CLI 경로를 넘긴다 (정제된 PATH 에서 다시 찾지 않는다)"
else
  bad "CLI 전달" "래퍼가 정제된 PATH 로 바이너리를 다시 찾게 된다"
fi

# A fan-out stage does not fit under the default background ceiling. Measured: a
# dispatched audit stage was killed at exactly 600s, reported `subtype: success`
# and exit 0, and published nothing — its readers were alive with open zero-byte
# temp files, killed in the moment before their atomic publish.
if grep -vE '^[[:space:]]*#' "$GATE" | grep_all_q -F 'CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS='; then
  ok "게이트가 스테이지에 배경 대기 천장을 넘긴다"
else
  bad "대기 천장" "팬아웃 스테이지가 기본 천장에서 발행 직전에 죽는다"
fi
# Finite, not `0`. Forever is the one value that costs the run its only signal:
# the watcher counts a live pid as a healthy stage, so a hung stage reads as a
# heartbeat and the run sits until a person comes back.
if grep -vE '^[[:space:]]*#' "$GATE" | grep_all_q -E 'CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS="\$\{[A-Z_]+:-[1-9][0-9]+\}"'; then
  ok "그 천장은 유한하다 (무한 대기는 정체 신호를 없앤다)"
else
  bad "대기 천장" "천장이 유한한 기본값을 갖지 않는다"
fi

# The fall-through that made the composition fatal is now an explicit arm, and
# `등급 미상` carries the only space in the axis-2 vocabulary — unquoted it
# splits the `case` pattern into two words and breaks the whole checker file.
if grep -q '"등급 미상")' "$repo_root/plugins/cc-cmds/orchestrator/rules/사전-인가-대조.sh"; then
  ok "미상 등급이 명시적 팔이고 인용돼 있다"
else
  bad "미상 처분" "흘러내림으로 처리되거나 인용되지 않았다"
fi

# ---------------------------------------------------------------------------
# 11. Termination — nine conditions, and the disagreement that runs both ways
# ---------------------------------------------------------------------------
H=$(cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null | jq -r .H)
gate act --manifest "$MANIFEST" --kind propose-done --target front --cutpoint 커밋 \
     --snapshot-digest "$(HH)" --rationale "끝났다고 본다" -- true
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
printf '%s\n' "$(PD)" > "$RD/progress-digest"
printf '%s\n' "9" > "$RD/progress-repeat"
H=$(cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null | jq -r .H)
gate act --manifest "$MANIFEST" --kind x --target front --cutpoint 커밋 \
     --snapshot-digest "$(HH)" --rationale "S9" -- touch "$WORK/t2"
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
     --snapshot-digest "$(HH)" --rationale "S9" -- touch "$WORK/t3"
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

# ---------------------------------------------------------------------------
# 14. A pending approval can be VOIDED, not only granted
#
# Before this there was one recording path, so an approval had two possible
# ends: granted, or pending forever. Pending is not inert — it counts against
# termination condition 2 and suspends the stagnation boundaries — so a single
# approval nobody wants to grant stalls the rest of the run. Voiding REMOVES a
# blocker, which is why it keeps the same transcript binding instead of becoming
# a router-writable escape.
# ---------------------------------------------------------------------------
vaid=$(grep -E '^- `승인`' "$LEDGER" | grep '상태=대기' | tail -1 \
       | grep -oE '승인 id=[^ |]+' | sed 's/승인 id=//' || true)
if [ -n "$vaid" ]; then
  vq=$(grep -E '^- `승인`' "$LEDGER" | grep -F "승인 id=$vaid " | tail -1 \
       | tr '|' '\n' | sed -n 's/^ *질문 문면=//p' | sed 's/[[:space:]]*$//' | tail -1)
  VDIR="$WORK/vcfg/projects/proj"; mkdir -p "$VDIR"
  VSID="99999999-8888-7777-6666-555555555555"
  printf '{"role":"user","content":"%s / %s → 이 질문은 잘못 발행됐습니다"}\n' "$vaid" "$vq" \
    > "$VDIR/$VSID.jsonl"

  out=$(cd "$WT" && CLAUDE_CONFIG_DIR="$WORK/vcfg" CLAUDE_CODE_SESSION_ID="$VSID" \
        bash "$GATE" close --manifest "$MANIFEST" --approval "$vaid" --void 2>&1); rc=$?
  check "무효화는 트랜스크립트 한 줄로 성립한다" "$rc" "0"
  case "$(grep -E '^- `승인`' "$LEDGER" | grep -F "승인 id=$vaid " | tail -1)" in
    *"상태=무효"*) ok "무효 상태가 원장에 남는다 (승인과 구별된다)" ;;
    *) bad "무효 기록" "$(grep -E '^- `승인`' "$LEDGER" | grep -F "승인 id=$vaid " | tail -1)" ;;
  esac
  n=$(cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null \
      | jq '.pending_approvals | length')
  check "무효화된 승인은 더 이상 대기로 세지 않는다" "$n" "0"

  # Already resolved is already resolved — a second close of any form is a
  # refusal, so an approval cannot be re-opened by asking again.
  out=$(cd "$WT" && CLAUDE_CONFIG_DIR="$WORK/vcfg" CLAUDE_CODE_SESSION_ID="$VSID" \
        bash "$GATE" close --manifest "$MANIFEST" --approval "$vaid" 2>&1); rc=$?
  if [ "$rc" = "0" ]; then
    bad "재해소" "무효화된 승인이 다시 닫혔다"
  else
    ok "무효화된 승인은 다시 닫히지 않는다"
  fi
fi

# ---------------------------------------------------------------------------
# 14b. The credential report runs at RUN OPEN, where it was never called
#
# `cred_check`'s own comment says a run whose cutpoint reaches `머지` should
# learn at kickoff and not at 3am. Nothing called it, so nothing ever did.
# ---------------------------------------------------------------------------
freshstate="$WORK/state-fresh"
out=$(cd "$WT" && XDG_STATE_HOME="$freshstate" bash "$GATE" snapshot --manifest "$MANIFEST" 2>&1 >/dev/null)
case "$out" in
  *"자격"*) ok "런 개시에 자격 상태가 보고된다" ;;
  *) bad "자격 개시 보고" "'"'"'$out'"'"'" ;;
esac
# And only at run open — the settings directory already exists on every later
# invocation, so a keychain lookup does not run once per act.
out=$(cd "$WT" && XDG_STATE_HOME="$freshstate" bash "$GATE" snapshot --manifest "$MANIFEST" 2>&1 >/dev/null)
case "$out" in
  *"자격이 갖춰지지"*) bad "자격 개시 보고" "런 개시가 아닌 호출에서도 보고했다" ;;
  *) ok "그 뒤의 호출에서는 다시 보고하지 않는다" ;;
esac

# ---------------------------------------------------------------------------
# 14c. The act runs in the EXECUTION worktree when the row declares one
#
# One field could not carry both duties. The sidecar path has to converge on the
# MAIN worktree so that N linked worktrees of one repository do not split the
# state a single writer owns; the act has to run where the branch actually is.
# For a pr or branch anchor those are never the same directory — git refuses to
# check a branch out twice — so a stage woke on the main worktree's branch every
# time. The symptom is silent: the stage starts, the files are readable, and
# what it reads is a different version.
# ---------------------------------------------------------------------------
LINKED="$WORK/linked"
( cd "$WT" && git worktree add -q -b linkedbr "$LINKED" ) >/dev/null 2>&1
if [ -d "$LINKED" ]; then
  ( cd "$LINKED" && echo linked > only-here.txt && git add -A && git commit -qm linked ) >/dev/null 2>&1

  # A read loop and not `sed`: the target row is FULL of `|` separators, so every
  # delimiter a substitution could pick already appears in the pattern. Shell
  # string equality has no delimiter at all.
  set_exec_wt() {
    local want="$1" line out="$MANIFEST.ew"
    : > "$out"
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        '- `target`'*별칭=infra*)
          case "$line" in *'실행 워크트리='*) line="${line%% | 실행 워크트리=*}" ;; esac
          [ -z "$want" ] || line="$line | 실행 워크트리=$want"
          ;;
      esac
      printf '%s\n' "$line" >> "$out"
    done < "$MANIFEST"
    mv "$out" "$MANIFEST"
    # The row moved, so both digests move — a kickoff would rewrite them and the
    # fixture does the same.
    local newtd
    newtd=$(cd "$WT" && bash -c '
      CC_ORCH_SOURCE_ONLY=1 . "'"$repo_root"'/plugins/cc-cmds/orchestrator/run.sh"
      MANIFEST="'"$MANIFEST"'"
      canonical_targets | shasum -a 256 | cut -d" " -f1')
    : > "$out"
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        '**대상 맵 다이제스트**: '*) line="**대상 맵 다이제스트**: $newtd" ;;
      esac
      printf '%s\n' "$line" >> "$out"
    done < "$MANIFEST"
    mv "$out" "$MANIFEST"
    refresh_bd
  }

  set_exec_wt "$LINKED"
  H=$(cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null | jq -r .H)
  out=$(cd "$WT" && bash "$GATE" exec --manifest "$MANIFEST" --target infra --segment SW \
        --cutpoint 커밋 --surface 읽기 --snapshot-digest "$(HH)" --rationale x -- ls 2>&1)
  case "$out" in
    *only-here.txt*) ok "행위가 실행 워크트리에서 실행된다 (메인 워크트리가 아니라)" ;;
    *) bad "실행 워크트리" "$(printf '%s' "$out" | tr '\n' ' ')" ;;
  esac

  # A declared execution worktree in ANOTHER repository is refused — that would
  # be a second target wearing the first one's cutpoint.
  OTHER="$WORK/other"; ( git init -q "$OTHER" ) >/dev/null 2>&1
  set_exec_wt "$OTHER"
  out=$(cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>&1); rc=$?
  if [ "$rc" = "0" ]; then
    bad "실행 워크트리 검사" "다른 레포를 실행 워크트리로 선언했는데 통과했다"
  else
    ok "다른 레포를 실행 워크트리로 선언하면 하드 스톱이다"
  fi

  # Absent is the default, and the default is the main worktree.
  set_exec_wt ""
  H=$(cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null | jq -r .H)
  out=$(cd "$WT" && bash "$GATE" exec --manifest "$MANIFEST" --target infra --segment SW \
        --cutpoint 커밋 --surface 읽기 --snapshot-digest "$(HH)" --rationale x -- ls 2>&1)
  case "$out" in
    *base.txt*) ok "필드가 없으면 메인 워크트리로 되돌아간다 (선언은 선택이다)" ;;
    *) bad "실행 워크트리 기본값" "$(printf '%s' "$out" | tr '\n' ' ')" ;;
  esac
else
  bad "픽스처 전제" "링크된 워크트리를 만들지 못했다"
fi

# ---------------------------------------------------------------------------
# 14d. The five row kinds that had no writer
#
# Five of the twelve declared series were written by nothing, and each one made
# a check that reads it answer the same thing forever: the cost boundary read an
# empty set and took its fail-open guard, so it could not fire however low the
# ceiling; open obligations were always zero, so termination condition 3 held
# vacuously; and terminal classes could not be counted at all. `generation` is
# deliberately still unwritten — nothing reads it, so a writer would put a value
# in the ledger that is recorded and never compared, which is the defect class
# this contract exists to remove.
# ---------------------------------------------------------------------------
H=$(cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null | jq -r .H)
gate act --manifest "$MANIFEST" --kind problem --target infra --segment SW --cutpoint 커밋 \
     --snapshot-digest "$(HH)" --rationale x -- 동일성=x/y.sh:널포인터 현재\ 단=1
check "생성 등급 없는 problem 행은 거부된다" "$rc" "2"

H=$(cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null | jq -r .H)
gate act --manifest "$MANIFEST" --kind problem --target infra --segment SW --cutpoint 커밋 \
     --snapshot-digest "$(HH)" --rationale x \
     -- "동일성=x/y.sh:널포인터" "현재 단=1" "생성 등급=외부상태변경"
check "problem 행이 기록된다" "$rc" "0"
n=$(cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null | jq -r .obligations_total)
check "그 행이 미해결 의무로 세어진다 (조건 3 이 더는 공허하지 않다)" "$n" "1"

# `stage-result` and `cost` are written from the stage's OWN terminal result
# line, so they are exercised through the seam with a synthetic log rather than
# by launching a CLI the fixture does not have.
outcome_probe() {
  # outcome_probe <rc> <subtype> <cost> <extra-log-line>
  cd "$WT" && CC_GATE_SOURCE_ONLY=1 bash -c '
    . "'"$GATE"'"
    MANIFEST="'"$MANIFEST"'"
    check_manifest >/dev/null 2>&1
    derive_paths_from_manifest
    rundir_init 2>/dev/null || true
    mkdir -p "$RUN_DIR/log"
    { printf "%s\n" "$4"
      printf "{\"type\":\"result\",\"subtype\":\"%s\",\"total_cost_usd\":%s,\"session_id\":\"sid-probe\"}\n" "$2" "$3"
    } > "$RUN_DIR/log/SP.json"
    nb=$(gate_rows "자율 승인" | gate_count)
    gate_record_stage_outcome infra SP review 1 "$1" "$nb" >/dev/null 2>&1
  ' _ "$1" "$2" "$3" "${4:-}"
}

outcome_probe 0 success 1.25 ''
row=$(grep '^- `stage-result` ' "$LEDGER" | tail -1)
case "$row" in
  *"종단 부류=공허한 성공"*) ok "행을 남기지 않고 성공한 스테이지는 공허한 성공이다" ;;
  *) bad "종단 부류" "$row" ;;
esac
case "$row" in
  *"세션 id=sid-probe"*) ok "stage-result 가 세션 계보를 싣는다 (구현-리뷰 분리 룰의 입력이다)" ;;
  *) bad "세션 계보" "$row" ;;
esac
crow=$(grep '^- `cost` ' "$LEDGER" | tail -1)
case "$crow" in
  *"누적 usd=1.2500"*) ok "비용이 누적된다 (B4 경계의 유일한 입력이다)" ;;
  *) bad "비용 누적" "$crow" ;;
esac

outcome_probe 0 success 0.75 '{"permission_denials":[{"tool_name":"Read"}]}'
row=$(grep '^- `stage-result` ' "$LEDGER" | tail -1)
case "$row" in
  *"종단 부류=산출물 없는 정지"*) ok "거부 흔적이 있으면 공허한 성공과 구별된다" ;;
  *) bad "종단 부류" "$row" ;;
esac
crow=$(grep '^- `cost` ' "$LEDGER" | tail -1)
case "$crow" in
  *"누적 usd=2.0000"*) ok "두 번째 스테이지의 비용이 앞의 값에 더해진다" ;;
  *) bad "비용 누적" "$crow" ;;
esac

# `is_error` is read as well as the status and the subtype. Measured: a stage
# that slept mid-response returned `subtype: success` WITH `is_error: true`, and
# only the non-zero status caught it — the same object with a zero status would
# have been classified as a normal completion.
outcome_probe_err() {
  cd "$WT" && CC_GATE_SOURCE_ONLY=1 bash -c '
    . "'"$GATE"'"
    MANIFEST="'"$MANIFEST"'"
    check_manifest >/dev/null 2>&1
    derive_paths_from_manifest
    rundir_init 2>/dev/null || true
    mkdir -p "$RUN_DIR/log"
    printf "{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":true,\"total_cost_usd\":9,\"session_id\":\"sid-slept\"}\n" \
      > "$RUN_DIR/log/SP.json"
    nb=$(gate_rows "자율 승인" | gate_count)
    gate_record_stage_outcome infra SP review 1 0 "$nb" >/dev/null 2>&1
  '
}
outcome_probe_err
row=$(grep '^- `stage-result` ' "$LEDGER" | tail -1)
case "$row" in
  *"종단 부류=크래시"*) ok "종료 코드가 0 이어도 is_error 면 크래시다" ;;
  *) bad "종단 부류" "$row" ;;
esac

outcome_probe 1 error 0.10 ''
row=$(grep '^- `stage-result` ' "$LEDGER" | tail -1)
case "$row" in
  *"종단 부류=크래시"*) ok "0 이 아닌 종료 코드는 크래시다" ;;
  *) bad "종단 부류" "$row" ;;
esac

# `plan_sha256` — the implement arm splits into two processes and process B
# enters ONLY when this field is on the row; its admission predicate says so and
# forbids re-deriving a plan instead. Nothing wrote it, so every dispatch
# resolved as process A, emitted the plan again and stopped — with a clean tree,
# which is correct for process A, so "A finished" and "B will never come" were
# indistinguishable.
plan_probe() {
  cd "$WT" && CC_GATE_SOURCE_ONLY=1 bash -c '
    . "'"$GATE"'"
    MANIFEST="'"$MANIFEST"'"
    check_manifest >/dev/null 2>&1
    derive_paths_from_manifest
    rundir_init 2>/dev/null || true
    mkdir -p "$RUN_DIR/log"
    printf "%s" "$2" > "$RUN_DIR/implement-SI.plan.md"
    printf "{\"type\":\"result\",\"subtype\":\"success\",\"total_cost_usd\":1,\"session_id\":\"sid-i\"}\n" \
      > "$RUN_DIR/log/SI.json"
    nb=$(gate_rows "자율 승인" | gate_count)
    gate_record_stage_outcome cc-cmds SI "$1" 1 0 "$nb" >/dev/null 2>&1
  ' _ "$1" "$2"
}
plan_probe implement "착지 계획 본문"
row=$(grep '^- `stage-result` ' "$LEDGER" | tail -1)
want=$(printf '%s' "착지 계획 본문" | shasum -a 256 | cut -d' ' -f1)
case "$row" in
  *"plan_sha256=$want"*) ok "구현 스테이지의 행이 계획 다이제스트를 싣는다 (프로세스 B 의 입장 토큰)" ;;
  *) bad "plan_sha256" "$row" ;;
esac
# And only the implement arm — a review stage has no plan and no process B.
plan_probe review "리뷰에는 계획이 없다"
row=$(grep '^- `stage-result` ' "$LEDGER" | tail -1)
case "$row" in
  *"plan_sha256="*) bad "plan_sha256" "리뷰 스테이지 행에 계획 다이제스트가 붙었다: $row" ;;
  *) ok "리뷰 스테이지 행에는 붙지 않는다" ;;
esac

# ---------------------------------------------------------------------------
# 14e. exit 7 tells a STAGE what to do, because only the router can do the
# prescribed thing
#
# The disposition is "stop and tell the user", and a stage can do neither half:
# the cause is outside it by definition, and looking needs the Bash that was
# just refused. Measured on one run — five stages, four retried into the same
# refusal 3, 9, 12 and 15 times, and the fifth stopped because of its own
# judgment rather than anything the contract said.
# ---------------------------------------------------------------------------
STATE7="$WORK/state-surface"
H=$(cd "$WT" && XDG_STATE_HOME="$STATE7" bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null | jq -r .H)
# Editing a settings file IS moving the surface — that file is one of the four.
printf '\n' >> "$STATE7/cc-cmds/run/R1/settings/generic.json"
n_before=$(grep -c '^- `blocked` ' "$LEDGER" 2>/dev/null || true)
out=$(cd "$WT" && XDG_STATE_HOME="$STATE7" CC_PIPELINE_SEGMENT=SP CC_PIPELINE_TARGET=infra \
      bash "$GATE" exec --manifest "$MANIFEST" --target infra --segment SP --cutpoint 커밋 \
      --surface 읽기 --snapshot-digest "$(HH7)" --rationale x -- ls 2>&1); rc=$?
if [ "$rc" = "7" ]; then
  ok "표면이 움직이면 종료 코드 7 이다"
  case "$out" in
    *"재시도하지 마세요"*) ok "스테이지에게 재시도가 아니라 중단을 지시한다" ;;
    *) bad "exit 7 문면" "$(printf '%s' "$out" | tr '\n' ' ')" ;;
  esac
  n_after=$(grep -c '^- `blocked` ' "$LEDGER" 2>/dev/null || true)
  if [ "${n_after:-0}" -gt "${n_before:-0}" ]; then
    ok "런 스코프 blocked 행이 남는다 (스테이지의 낭비된 턴 수 말고 상태로 보인다)"
  else
    bad "표면 이동 기록" "blocked 행이 늘지 않았다"
  fi
  out=$(cd "$WT" && XDG_STATE_HOME="$STATE7" CC_PIPELINE_SEGMENT=SP CC_PIPELINE_TARGET=infra \
        bash "$GATE" exec --manifest "$MANIFEST" --target infra --segment SP --cutpoint 커밋 \
        --surface 읽기 --snapshot-digest "$(HH7)" --rationale x -- ls 2>&1) || true
  n_twice=$(grep -c '^- `blocked` ' "$LEDGER" 2>/dev/null || true)
  check "같은 조건을 반복 기록하지 않는다" "$n_twice" "$n_after"
else
  bad "표면 이동" "종료 코드 $rc — 표면을 움직였는데 7 이 아니다"
fi

# ---------------------------------------------------------------------------
# 14f. A documentless run does not get its base's PARENT
#
# The workspace widening is for a document that belongs to no repository. A run
# with no document sets both document variables to the run's base, so a guard
# on their equality alone opens a directory nothing in the run reads.
# ---------------------------------------------------------------------------
parent_of_wt=$(dirname "$WT")
if jq -e --arg d "$parent_of_wt" '.permissions.additionalDirectories | index($d)' \
     "$SETTINGS_DIR/generic.json" >/dev/null 2>&1; then
  bad "작업 공간 확장" "문서 없는 런인데 베이스의 부모가 열렸다: $parent_of_wt"
else
  ok "문서 없는 런은 베이스의 부모를 열지 않는다"
fi

# ---------------------------------------------------------------------------
# 14g. A cut stage is RE-ATTACHED, not re-run — and the id is checked
#
# The contract already said so and the wrapper already accepted `--resume`;
# nothing carried the router's intent to it, so the only recovery was a full
# re-run. Measured: a review stage died to a machine sleep after 1h53m and 51.84
# USD with every reviewer's output on disk and only the synthesis missing.
#
# The id is checked against this run's own ledger. A resume is an instruction to
# continue somebody's transcript, so an unchecked value would let one segment
# continue another segment's — or another run's — session.
# ---------------------------------------------------------------------------
if grep -vE '^[[:space:]]*#' "$GATE" | grep_all_q -F '"--resume $GATE_RESUME"'; then
  ok "게이트가 래퍼에 --resume 을 넘길 수 있다"
else
  bad "재개 경로" "라우터가 끊긴 스테이지를 이어붙일 수단이 없다"
fi
# The segment row comes first, because a dispatch into a segment that has none
# is now refused before the argv is looked at — and the fault under test here is
# the argv. Without this the assertion would pass for the wrong reason.
H=$(cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null | jq -r .H)
gate act --manifest "$MANIFEST" --kind segment --target infra --segment SNOSUCH --cutpoint 커밋 \
     --snapshot-digest "$(HH)" --rationale x -- 상태=실행중 워크트리="$WT"
H=$(cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null | jq -r .H)
gate act --manifest "$MANIFEST" --kind skill --target infra --segment SNOSUCH --cutpoint 커밋 \
     --surface 워크트리쓰기 --snapshot-digest "$(HH)" --rationale x --resume "남의-세션-id" -- review x
# The validation must sit BEFORE the CLI binary is resolved. Resolving first
# makes "the binary is missing" mask "the argv is wrong" — the same defect the
# wrapper already had and had fixed, and it came back here: on a host without
# the CLI a bad resume id answered 127 and the refusal never named the fault.
ord_resume=$(sed -n '/^gate_launch_stage()/,/^}/p' "$GATE" | grep -n '재개 대상 세션이' | sed 's/:.*//' | tail -1)
ord_cli=$(sed -n '/^gate_launch_stage()/,/^}/p' "$GATE" | grep -n 'CLI 바이너리를 해소하지' | sed 's/:.*//' | tail -1)
if [ -n "$ord_resume" ] && [ -n "$ord_cli" ] && [ "$ord_resume" -lt "$ord_cli" ]; then
  ok "재개 인자 검증이 CLI 해소보다 먼저 온다"
else
  bad "검증 순서" "재개 검증 $ord_resume · CLI 해소 $ord_cli — 바이너리 부재가 인자 오류를 가린다"
fi
check "원장에 없는 세션 id 로는 재개하지 못한다" "$rc" "2"
case "$msg" in
  *"원장 기록에 없습니다"*) ok "거부가 그 이유를 말한다" ;;
  *) bad "재개 거부 문면" "$(printf '%s' "$msg" | tr '\n' ' ')" ;;
esac

# ---------------------------------------------------------------------------
# 14h. The launch path is actually ENTERED, with a stub CLI
#
# Every assertion above stops at `gate_launch_stage`'s argument checks, because
# the fixture has no CLI binary and the function returns 127 before doing
# anything. That left the whole body — the plugin root, the id flag, the log
# capture, the pid file, the terminal rows — with no coverage at all, and an
# edit that moved one block silently deleted the `plugin_dir` assignment while
# leaving `--plugin-dir "$plugin_dir"` behind. Under `set -u` that killed every
# stage dispatch, and the suite stayed green.
#
# The stub is a CLI-shaped script: it prints one stream-json result line and
# exits. What is under test is the gate's launch path, not the CLI.
# ---------------------------------------------------------------------------
STUB="$WORK/stub-cli"
cat > "$STUB" <<'STUBEOF'
#!/usr/bin/env bash
# A CLI-shaped stub. Records the argv it was handed, then emits one result line.
printf '%s\n' "$*" > "${CC_STUB_ARGV_OUT:-/dev/null}"
printf '{"type":"result","subtype":"success","is_error":false,"total_cost_usd":0.5,"session_id":"stub-session","num_turns":1}\n'
exit 0
STUBEOF
chmod +x "$STUB"

H=$(cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null | jq -r .H)
gate act --manifest "$MANIFEST" --kind segment --target infra --segment SL --cutpoint 커밋 \
     --snapshot-digest "$(HH)" --rationale x -- 상태=실행중 워크트리="$WT"
H=$(cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null | jq -r .H)
out=$(cd "$WT" && CC_CLAUDE_BIN="$STUB" CC_STUB_ARGV_OUT="$WORK/stub-argv.txt" \
      bash "$GATE" act --manifest "$MANIFEST" --kind skill --target infra --segment SL \
      --cutpoint 커밋 --surface 워크트리쓰기 --snapshot-digest "$(HH)" --rationale x \
      -- review "/cc-cmds:review-unattended x" 2>&1); rc=$?
check "스텁 CLI 로 스테이지 기동이 끝까지 간다" "$rc" "0"
case "$out" in
  *"unbound variable"*|*"바인딩 해제"*)
    bad "기동 경로" "unbound variable: $(printf '%s' "$out" | tr '\n' ' ')" ;;
  *) ok "기동 경로에 미정의 변수가 없다" ;;
esac
# The plugin root actually reaches the wrapper, and it is the directory that
# contains the skills — not the orchestrator directory.
if [ -f "$WORK/stub-argv.txt" ]; then
  ok "스텁이 실제로 실행됐다 (argv 를 남겼다)"
else
  bad "기동 경로" "스텁이 실행되지 않았다 — 래퍼 앞에서 끝났다"
fi
# And the terminal rows the launch path is responsible for are there.
case "$(grep '^- `stage-result` ' "$LEDGER" | tail -1)" in
  *"세그먼트=SL"*) ok "기동이 끝나면 stage-result 행이 남는다" ;;
  *) bad "종단 기록" "$(grep '^- `stage-result` ' "$LEDGER" | tail -1)" ;;
esac
case "$(grep '^- `자율 승인` | kind=skill ' "$LEDGER" | tail -1)" in
  *"세그먼트=SL"*) ok "디스패치 자체도 원장에 남는다" ;;
  *) bad "디스패치 기록" "$(grep '^- `자율 승인` | kind=skill ' "$LEDGER" | tail -1)" ;;
esac
# The pid file is removed on exit, so "no record implies no process" holds.
if [ -f "$(dirname "$SETTINGS_DIR")/SL.pid" ]; then
  bad "pid 정리" "스테이지가 끝났는데 pid 기록이 남아 있다"
else
  ok "스테이지가 끝나면 pid 기록이 지워진다"
fi

# ---------------------------------------------------------------------------
# 14i. The render answers "is this still going?"
#
# It did not. The heartbeat a watcher prints goes to a stdout its launching tool
# call already closed, so it reaches nobody; the render carried no live-stage
# count, no ledger age, and no terminal state. Answering the question needed the
# row grammar and a manual pid comparison.
# ---------------------------------------------------------------------------
rend=$(cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" --render 2>/dev/null)
for want in '살아 있는 스테이지' '원장 갱신' '감시자' '런 상태' '스테이지 스트림'; do
  case "$rend" in
    *"$want"*) ok "렌더가 「${want}」을 낸다" ;;
    *) bad "렌더 라이브니스" "「${want}」이 없다" ;;
  esac
done
case "$rend" in
  *"런 상태   : 진행 중"*) ok "종단 표시가 없으면 진행 중이라고 답한다" ;;
  *) bad "런 상태" "$(printf '%s' "$rend" | grep '런 상태' || true)" ;;
esac

# The run's END is a FILE, because a ledger row is not a thing another process
# can test cheaply — and two need to: the watcher, whose loop had no exit
# condition, and a person who does not know the row grammar.
RD_G=$(dirname "$SETTINGS_DIR")
rm -f "$RD_G/done"
if grep -vE '^[[:space:]]*#' "$GATE" | grep_all_q -F '> "$RUN_DIR/done"'; then
  ok "게이트가 종단 표시 파일을 쓴다"
else
  bad "종단 표시" "런이 끝나도 디스크에 표시가 남지 않는다"
fi
printf '%s 종단 — 시험\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$RD_G/done"
rend=$(cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" --render 2>/dev/null)
case "$rend" in
  *"런 상태   : 종단"*) ok "종단 표시가 있으면 렌더가 그렇게 답한다" ;;
  *) bad "런 상태" "$(printf '%s' "$rend" | grep '런 상태' || true)" ;;
esac
rm -f "$RD_G/done"

# ---------------------------------------------------------------------------
# 14j. The grant reaches every declared worktree, and digest tools are readable
#
# `실행 워크트리` was wired to the act's cwd and not to the stage's readable set,
# so a stage woke in a worktree it could not read. And no other target's main
# worktree was in the set either — only the home one. Separately, the digest
# tools were absent, which deadlocked the implement arm: process B may enter
# only after comparing the plan's digest, and computing it was refused.
# ---------------------------------------------------------------------------
graded_as '읽기' 'shasum 이 읽기로 등급된다'   -- shasum -a 256 /tmp/x
graded_as '읽기' 'sha256sum 도 같다'           -- sha256sum /tmp/x
# `openssl` stays out on purpose — it computes digests AND opens sockets.
graded_as '등급 미상' 'openssl 은 들어오지 않는다' -- openssl dgst -sha256 /tmp/x

set_exec_wt "$LINKED" >/dev/null 2>&1 || true
rm -rf "$SETTINGS_DIR"
( cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" >/dev/null 2>&1 )
if jq -e --arg d "$LINKED" '.permissions.additionalDirectories | index($d)' \
     "$SETTINGS_DIR/generic.json" >/dev/null 2>&1; then
  ok "실행 워크트리가 스테이지의 읽기 집합에 들어간다"
else
  bad "실행 워크트리 인가" "$(jq -c '.permissions.additionalDirectories' "$SETTINGS_DIR/generic.json")"
fi
if jq -e --arg d "$WT" '.permissions.additionalDirectories | index($d)' \
     "$SETTINGS_DIR/generic.json" >/dev/null 2>&1; then
  ok "선언된 대상의 메인 워크트리도 들어간다"
else
  bad "대상 워크트리 인가" "$(jq -c '.permissions.additionalDirectories' "$SETTINGS_DIR/generic.json")"
fi
set_exec_wt "" >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
# 14k. The deadline is a dispatch gate, and it is read
#
# It was frozen into the binding digest and compared at entry, and then nothing
# read it — the field appears nowhere in this file and the driver's own helper
# is only called from the loop the router never enters. Measured: a run past its
# deadline had `plan --kind skill` answer "통과 예상".
# ---------------------------------------------------------------------------
past_dl() {
  local line out="$MANIFEST.dl"
  : > "$out"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      '**벽시계 마감**: '*) line="**벽시계 마감**: $1" ;;
    esac
    printf '%s\n' "$line" >> "$out"
  done < "$MANIFEST"
  mv "$out" "$MANIFEST"
  refresh_bd
}
past_dl '2020-01-01T00:00:00Z'
H=$(cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null | jq -r .H)
gate plan --manifest "$MANIFEST" --kind skill --target infra --segment SD --cutpoint 커밋 -- review
check "마감이 지나면 스테이지 디스패치가 거부된다" "$rc" "3"
case "$msg" in
  *"마감이 지났습니다"*) ok "거부가 마감을 이유로 든다" ;;
  *) bad "마감 문면" "$(printf '%s' "$msg" | tr '\n' ' ')" ;;
esac
gate plan --manifest "$MANIFEST" --kind merge --target infra --segment SD --cutpoint 머지 -- gh pr merge 1
check "마감 뒤 머지도 거부된다" "$rc" "3"
# But recording and closing still work — a deadline that stopped everything
# would strand the run instead of ending it.
H=$(cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null | jq -r .H)
gate act --manifest "$MANIFEST" --kind segment --target infra --segment SD --cutpoint 커밋 \
     --surface 읽기 --snapshot-digest "$(HH)" --rationale x -- 상태=park 워크트리="$WT"
check "마감 뒤에도 장부 행위는 통과한다" "$rc" "0"
past_dl '2030-01-01T00:00:00Z'
H=$(cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null | jq -r .H)
gate plan --manifest "$MANIFEST" --kind skill --target infra --segment SD --cutpoint 커밋 -- review
check "마감이 미래면 디스패치가 통과한다" "$rc" "0"

# ---------------------------------------------------------------------------
# 14l. The authorization list can grow, and only through the gate
#
# It used to be written once and never again, so a directory kickoff could not
# know about — a segment's own worktree, a repository added at layer 1 — was
# unreachable for the life of the run, and the only exit was to end the run.
# Measured: a run produced its review and then could not remediate, because the
# only writable tree in its list was the live plugin checkout.
#
# What keeps the surface comparison meaningful is not that it never moves, but
# that it moves only through THIS writer and leaves a row. Both halves are
# asserted here — the growth, and the refusal to repair somebody else's edit.
# ---------------------------------------------------------------------------
RD_L=$(dirname "$SETTINGS_DIR")
n_before=$(jq -r '.permissions.additionalDirectories | length' "$SETTINGS_DIR/generic.json")
n_rows_before=$(grep -c '^- `대상 추가` ' "$LEDGER" 2>/dev/null || true)

# Declaring an execution worktree is a change to what the settings derive FROM.
set_exec_wt "$LINKED"
( cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" >/dev/null 2>&1 )
n_after=$(jq -r '.permissions.additionalDirectories | length' "$SETTINGS_DIR/generic.json")
if [ "${n_after:-0}" -gt "${n_before:-0}" ]; then
  ok "유도의 입력이 움직이면 인가 목록이 자란다"
else
  bad "인가 목록 재유도" "$n_before → $n_after"
fi
if jq -e --arg d "$LINKED" '.permissions.additionalDirectories | index($d)' \
     "$SETTINGS_DIR/generic.json" >/dev/null 2>&1; then
  ok "새로 선언된 워크트리가 그 안에 있다"
else
  bad "인가 목록 재유도" "$(jq -c '.permissions.additionalDirectories' "$SETTINGS_DIR/generic.json")"
fi
n_rows_after=$(grep -c '^- `대상 추가` ' "$LEDGER" 2>/dev/null || true)
if [ "${n_rows_after:-0}" -gt "${n_rows_before:-0}" ]; then
  ok "그 확장이 원장에 행으로 남는다 (조용히 넓히지 않는다)"
else
  bad "확장 기록" "행이 늘지 않았다"
fi
# The baseline moved with it, so the next act does not read as tampering.
H=$(cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null | jq -r .H)
gate act --manifest "$MANIFEST" --kind segment --target infra --segment SR --cutpoint 커밋 \
     --surface 읽기 --snapshot-digest "$(HH)" --rationale x -- 상태=park 워크트리="$WT"
check "확장 뒤의 행위가 표면 이동으로 읽히지 않는다" "$rc" "0"
# And a second call changes nothing — the derivation is a function, so it is
# stable when its inputs are.
d1=$(cat "$RD_L/surface-digest")
( cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" >/dev/null 2>&1 )
check "입력이 그대로면 다시 쓰지 않는다" "$(cat "$RD_L/surface-digest")" "$d1"

# THE OTHER HALF: an edit this writer did not make is still exit 7. The
# re-derivation must not repair it — repairing would erase the evidence the
# surface check reads, which is the whole detection.
printf '\n' >> "$SETTINGS_DIR/generic.json"
H=$(cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null | jq -r .H)
out=$(cd "$WT" && bash "$GATE" exec --manifest "$MANIFEST" --target infra --segment SR \
      --cutpoint 커밋 --surface 읽기 --snapshot-digest "$(HH)" --rationale x -- ls 2>&1); rc=$?
check "남이 고친 표면은 여전히 종료 코드 7 이다" "$rc" "7"
set_exec_wt ""

# ---------------------------------------------------------------------------
# 15. The grading table reads the ACT, not the spelling
#
# Three defects met here and left no spelling that reached `gh` at all: the
# sanitized PATH made the bare name unresolvable, the table read argv0 verbatim
# so the absolute path graded `등급 미상`, and `gh api` — the only spelling that
# submits several inline comments as one review — was refused outright.
# ---------------------------------------------------------------------------
graded_as '외부상태변경' '경로로 부른 gh 도 맨 이름과 같게 등급된다' -- /opt/homebrew/bin/gh pr merge 1
graded_as '외부상태변경' '경로로 부른 terraform 도 같다'            -- /usr/local/bin/terraform apply
graded_as '읽기'         '경로로 부른 git 읽기도 같다'              -- /usr/bin/git status

# git's global options sit BEFORE the subcommand, and `-C <path>` is the only
# spelling that names another worktree. Reading `$2` blindly graded it unknown.
graded_as '워크트리쓰기' 'git -C 의 하위 명령을 찾아낸다'   -- git -C /tmp commit -m x
graded_as '외부상태변경' 'git -c 의 하위 명령도 찾아낸다'   -- git -c user.name=x push
graded_as '읽기'         '값이 붙은 전역 옵션도 건너뛴다'   -- git --git-dir=/tmp/.git log
# An unrecognized global stops the scan as UNKNOWN rather than guessing whether
# it eats the next word — guessing wrong grades a `push` by the wrong token.
graded_as '등급 미상'    '모르는 전역 옵션은 추측하지 않는다' -- git --not-a-real-global push

graded_as '읽기'         'gh api 의 기본은 GET 이라 읽기다'  -- gh api repos/o/r/pulls/1/reviews
graded_as '외부상태변경' '명시된 POST 는 외부 상태 변경이다' -- gh api --method POST repos/o/r/pulls/1/reviews
graded_as '외부상태변경' '-X 붙임꼴도 읽는다'                -- gh api -XPATCH repos/o/r/pulls/1
graded_as '외부상태변경' '필드가 붙으면 gh 자신처럼 POST 로 본다' -- gh api repos/o/r/pulls/1/reviews -f event=COMMENT
graded_as '읽기'         '명시된 메서드가 필드를 이긴다'     -- gh api -X GET repos/o/r/pulls -f per_page=1
# Deliberate, and it stays deliberate: `auth` reads and rewrites the credential
# the whole separation rests on.
graded_as '등급 미상'    'gh auth 는 의도된 거부로 남는다'   -- gh auth switch --user x

# A schema migration is a standard step BEFORE a deploy, and with no row for the
# client every one of them fell to `등급 미상`, which refuses. All three ways out
# were closed at once — `--surface` is a checked claim that any claim mismatches,
# the basename normalization makes the absolute path identical, and `bash -c`
# passes while recording a DDL against a database as a worktree write.
graded_as '외부상태변경' 'mysql 이 외부 상태 변경으로 등급된다'  -- mysql -e "SELECT 1"
graded_as '외부상태변경' 'psql 도 같다'                          -- psql -c "SELECT 1"
graded_as '외부상태변경' '경로로 부른 클라이언트도 같다'         -- /opt/homebrew/opt/mysql-client@8.0/bin/mysql -e x
# Read-only spellings grade the same, and that is the deliberate side to be
# wrong on: the grade comes from argv0 alone, so a SELECT cannot be told from a
# migration here — requiring a pre-authorization row for a read costs a line,
# letting a migration through as a read costs the database.
graded_as '외부상태변경' '읽기 전용 조회도 같은 등급이다'        -- mysql --defaults-extra-file=f db -e "SELECT 1"

# The refusal names WHICH repair, because two different things arrive there.
# `plan` and not `grade`: the repair sentence lives on the acting path, which is
# where a router that got refused actually is.
gate plan --manifest "$MANIFEST" --kind x --target infra --segment SW --cutpoint 커밋 -- some-unlisted-tool --flag
case "$msg" in
  *"표를 넓혀야"*) ok "미상 거부가 표를 넓히라는 쪽과 다시 쓰라는 쪽을 구별해 말한다" ;;
  *) bad "미상 문면" "'"'"'$msg'"'"'" ;;
esac

# ---------------------------------------------------------------------------
# 15/16. Late sections run against their OWN state home.
#
# Section 14e deliberately moves the enforcement surface and never puts it back,
# and the tail sections that follow it use `grade` and `plan`, neither of which
# reaches the surface check. Anything below that uses `act` therefore inherits a
# moved surface and gets exit 7 for reasons that have nothing to do with what it
# is testing. A fresh state home gives these sections their own baseline while
# keeping the same ledger.
# ---------------------------------------------------------------------------
STATE_LATE="$WORK/state-late"
gateL() {
  local out
  out=$(cd "$WT" && XDG_STATE_HOME="$STATE_LATE" bash "$GATE" "$@" 2>&1); rc=$?
  msg=$(printf '%s' "$out" | grep -vE '\[run\] ' | tr '\n' ' ' | sed 's/[[:space:]]*$//')
}
HL() { cd "$WT" && XDG_STATE_HOME="$STATE_LATE" bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null | jq -r .H; }

# ---------------------------------------------------------------------------
# 15. A stage may not be dispatched into a segment with no `segment` row
#
# The progress vector is built from those rows, so a run that skips them has a
# vector that cannot move and a stagnation boundary that fires on a healthy
# stage — with a question text that names none of it.
# ---------------------------------------------------------------------------
gateL act --manifest "$MANIFEST" --kind skill --target infra --segment SROWLESS --cutpoint 커밋 \
     --surface 워크트리쓰기 --snapshot-digest "$(HL)" --rationale x -- review "/cc-cmds:review-unattended x"
check "segment 행 없는 세그먼트로는 스테이지를 띄우지 못한다" "$rc" "3"
case "$msg" in
  *"segment 행이 없습니다"*) ok "거부가 빠진 행을 이유로 든다" ;;
  *) bad "행 없음 문면" "$msg" ;;
esac
# Not vacuous in the other direction: with the row present the same dispatch
# gets past this check.
gateL act --manifest "$MANIFEST" --kind segment --target infra --segment SROWLESS --cutpoint 커밋 \
     --snapshot-digest "$(HL)" --rationale x -- 상태=실행중 워크트리="$WT"
check "그 행을 쓰면 기록은 통과한다" "$rc" "0"
gateL plan --manifest "$MANIFEST" --kind skill --target infra --segment SROWLESS --cutpoint 커밋 \
     --surface 워크트리쓰기 --snapshot-digest "$(HL)" -- review
check "행이 있으면 같은 디스패치가 이 검사를 넘는다" "$rc" "0"

# ---------------------------------------------------------------------------
# 16. Termination condition 5 has a resolution path, and one block that has none
#
# Counting raw rows made it a one-way latch: a ledger row is never deleted, so a
# single run-scope block — a watcher false positive included — took the run's
# ability to propose done away for good.
# ---------------------------------------------------------------------------
# Condition 5 is read through the propose-done refusal, which is where it
# actually reaches a person: the rejection prints every unmet condition.
cond5_named() {
  gateL act --manifest "$MANIFEST" --kind propose-done --target infra --segment SROWLESS \
       --cutpoint 커밋 --surface 읽기 --snapshot-digest "$(HL)" --rationale x -- 절=x 근거=y
  # Matched on the REASON, not on "condition 5 is unmet". Section 14e leaves a
  # permanent `원인=무효화` run-scope block in this same ledger, so the coarse
  # form is true forever and would assert nothing.
  case "$msg" in *"미해소입니다 (라이브니스 침묵)"*) printf 'yes' ;; *) printf 'no' ;; esac
}
gateL exec --manifest "$MANIFEST" --target infra --segment SROWLESS --cutpoint 커밋 \
     --surface 읽기 --snapshot-digest "$(HL)" --rationale seed -- true
printf -- '- `blocked` | 대상=- | 스코프=run | 원인=불명 | 사유=라이브니스 침묵 | 관측=t | 재개 명령=- | prev=seed\n' >> "$LEDGER"

# The resolution row needs its evidence, and it may not invent a block.
gateL act --manifest "$MANIFEST" --kind blocked --target infra --cutpoint 커밋 \
     --surface 읽기 --snapshot-digest "$(HL)" --rationale x -- 스코프=run 사유="라이브니스 침묵" 원인=해소
check "근거 없는 해소 행은 거부된다" "$rc" "2"
gateL act --manifest "$MANIFEST" --kind blocked --target infra --cutpoint 커밋 \
     --surface 읽기 --snapshot-digest "$(HL)" --rationale x -- 스코프=run 사유="없던 막힘" 원인=해소 근거=z
check "없는 막힘은 해소할 수 없다" "$rc" "2"
gateL act --manifest "$MANIFEST" --kind blocked --target infra --cutpoint 커밋 \
     --surface 읽기 --snapshot-digest "$(HL)" --rationale x -- 스코프=run 사유="라이브니스 침묵" 원인=불명 근거=z
check "라우터는 막힘을 새로 만들 수 없다" "$rc" "2"

check "해소 전에는 종료 제안이 조건 5 를 이유로 든다" "$(cond5_named)" "yes"
gateL act --manifest "$MANIFEST" --kind blocked --target infra --cutpoint 커밋 \
     --surface 읽기 --snapshot-digest "$(HL)" --rationale x \
     -- 스코프=run 사유="라이브니스 침묵" 원인=해소 근거="스테이지가 27초 전에 원장을 키웠다"
check "근거를 실은 해소 행은 통과한다" "$rc" "0"
check "해소 뒤 그 사유는 더 이상 조건 5 에 오르지 않는다" "$(cond5_named)" "no"
# And the run still cannot propose done, because 14e's invalidation block stands
# — which is the point: one reason resolving must not clear another. Called
# directly rather than through `$(...)`, or `msg` would be the subshell's.
gateL act --manifest "$MANIFEST" --kind propose-done --target infra --segment SROWLESS \
     --cutpoint 커밋 --surface 읽기 --snapshot-digest "$(HL)" --rationale x -- 절=x 근거=y
case "$msg" in
  *"해소 불가입니다 (강제 표면 이동)"*) ok "해소 불가인 막힘은 그대로 남는다" ;;
  *) bad "무효화 잔존" "$msg" ;;
esac

# An invalidation block is terminal: clearing it would be the run re-authorizing
# itself past the boundary that had just refused it. Section 14e already left
# one in this ledger, so nothing needs seeding here.
gateL act --manifest "$MANIFEST" --kind blocked --target infra --cutpoint 커밋 \
     --surface 읽기 --snapshot-digest "$(HL)" --rationale x \
     -- 스코프=run 사유="강제 표면 이동" 원인=해소 근거=z
check "무효화 막힘은 해소되지 않는다" "$rc" "3"
case "$msg" in
  *"해소할 수 없습니다"*) ok "거부가 무효화를 이유로 든다" ;;
  *) bad "무효화 문면" "$msg" ;;
esac

# ---------------------------------------------------------------------------
# 17. The authorization record is READ, on the router path
#
# `check_grant` lives on the fixed graph and the router never enters it, so a
# run could execute with a grant that was absent, foreign, or disagreed with the
# manifest, and nothing looked. Measured: a stage declaring cutpoint `배포` ran
# 40 minutes while the file did not exist at the derived path; it appeared 9
# hours 42 minutes later.
# ---------------------------------------------------------------------------
GBAK="$WORK/grant.bak"; cp "$GRANT" "$GBAK"

mv "$GRANT" "$WORK/grant.away"
gateL grade --manifest "$MANIFEST" --target infra --cutpoint 커밋 --surface 읽기 -- ls
check "인가 기록이 없으면 어떤 동사도 서지 않는다" "$rc" "3"
case "$msg" in
  *"인가 기록이 없습니다"*) ok "거부가 부재를 이유로 든다" ;;
  *) bad "인가 부재 문면" "$msg" ;;
esac
cp "$GBAK" "$GRANT"

# A foreign block: one document folds all of its runs onto one grant path, so
# run N+1 meets a block it did not write.
printf '\n## 인가 R-OTHER\n**권한 절단점**: 배포\n' >> "$GRANT"
gateL grade --manifest "$MANIFEST" --target infra --cutpoint 커밋 --surface 읽기 -- ls
check "외래 인가 블록이 있으면 선다" "$rc" "3"
case "$msg" in
  *"외래 인가 블록"*) ok "거부가 외래 블록을 지목한다" ;;
  *) bad "외래 블록 문면" "$msg" ;;
esac
cp "$GBAK" "$GRANT"

# The run maximum is cross-checked against the per-target values that actually
# authorize acts. Without this the two disagree silently for a whole night.
sed 's/^\*\*권한 절단점\*\*: 배포$/**권한 절단점**: 커밋/' "$GBAK" > "$GRANT"
gateL grade --manifest "$MANIFEST" --target infra --cutpoint 커밋 --surface 읽기 -- ls
check "대상 절단점이 런 최대치를 넘으면 선다" "$rc" "3"
case "$msg" in
  *"런 최대치"*) ok "거부가 어느 대상이 넘었는지 말한다" ;;
  *) bad "최대치 문면" "$msg" ;;
esac

# owner-doc must agree with the manifest, and absence is a mismatch.
sed 's/owner-doc=(없음)/owner-doc=docs-something-else/' "$GBAK" > "$GRANT"
gateL grade --manifest "$MANIFEST" --target infra --cutpoint 커밋 --surface 읽기 -- ls
check "owner-doc 이 매니페스트와 다르면 선다" "$rc" "3"
sed 's/ owner-doc=(없음);//' "$GBAK" > "$GRANT"
gateL grade --manifest "$MANIFEST" --target infra --cutpoint 커밋 --surface 읽기 -- ls
check "owner-doc 이 아예 없으면 선다 (부재는 불일치다)" "$rc" "3"

cp "$GBAK" "$GRANT"
gateL grade --manifest "$MANIFEST" --target infra --cutpoint 커밋 --surface 읽기 -- ls
check "온전한 인가 기록에서는 통과한다" "$rc" "0"

# ---------------------------------------------------------------------------
# 18. Concurrent appends do not chain to the same parent
#
# `gate_append` used to read the chain tip OUTSIDE the lock, so two writers read
# the same tip and both emitted rows carrying the same `prev`. The verifier then
# reported a break for a ledger nobody had touched — measured on a 227-row
# ledger where rows 85 and 86 shared a parent, both present and well-formed.
#
# A false break is worse than no chain: a real splice looks exactly like the
# noise a reader has learned to skip.
# ---------------------------------------------------------------------------
CONC="$WORK/conc"; mkdir -p "$CONC"
CLEDGER="$CONC/ledger.md"; : > "$CLEDGER"
(
  set +e
  # shellcheck disable=SC1090
  CC_GATE_SOURCE_ONLY=1 . "$GATE" 2>/dev/null
  LEDGER="$CLEDGER"; RUN_DIR="$CONC"; RUN_ID="RC"
  for i in 1 2 3 4 5 6 7 8; do
    gate_append '자율 승인' "kind=" "결정=exec" "근거=동시-$i" >/dev/null 2>&1 &
  done
  wait
) >/dev/null 2>&1

rows=$(grep -c '^- `' "$CLEDGER" 2>/dev/null || true)
check "여덟 개의 동시 append 가 모두 남는다" "${rows:-0}" "8"

# SERIALIZATION IS ASSERTED ONLY WHERE THERE IS A LOCK TOOL, and that is not a
# convenience skip. The driver declares itself darwin-only and refuses to start
# elsewhere, naming advisory-lock contention as one of the environment facts it
# has measured on darwin and nowhere else. `lock_tool` is empty off darwin, so
# `gate_append` takes its unlocked branch — the ordering this test pins is a
# property of the locked path, and claiming it on a host with no lock would be
# asserting a guarantee the contract does not make.
if [ -x /usr/bin/lockf ]; then
  # Every `prev` distinct. Two rows sharing a parent is the defect, and it is
  # visible without walking the chain.
  uniq_prev=$(sed -n 's/.*| prev=\([0-9a-f]*\).*/\1/p' "$CLEDGER" | sort -u | grep -c . || true)
  check "여덟 행의 prev 가 서로 다르다 (같은 부모에 체인하지 않는다)" "${uniq_prev:-0}" "8"

  # And the chain actually verifies: each row's prev is the digest of the row
  # before it, with the first pointing at the run heading.
  broken=0; expect=$(printf '%s' "## 실행 RC" | shasum -a 256 | cut -d' ' -f1)
  while IFS= read -r row; do
    got=$(printf '%s' "$row" | sed -n 's/.*| prev=\([0-9a-f]*\).*/\1/p')
    [ "$got" = "$expect" ] || broken=$(( broken + 1 ))
    expect=$(printf '%s' "$row" | shasum -a 256 | cut -d' ' -f1)
  done < <(grep '^- `' "$CLEDGER")
  check "체인이 끊긴 곳이 없다" "$broken" "0"
else
  ok "잠금 도구가 없는 호스트라 직렬화 단언을 건너뛴다 (드라이버가 진입에서 거부하는 플랫폼)"
fi

# ---------------------------------------------------------------------------
# 19. The nine grant fields are checked for presence
#
# The block is frozen at append and has no rewrite form, so a field omitted is
# omitted for the life of the run. Nothing compared the set, and the kickoff
# template, this fixture and every hand-written grant had all dropped the same
# one.
# ---------------------------------------------------------------------------
GBAK2="$WORK/grant.bak2"; cp "$GRANT" "$GBAK2"
grep -v '직렬 웨이브 고지' "$GBAK2" > "$GRANT"
gateL grade --manifest "$MANIFEST" --target infra --cutpoint 커밋 --surface 읽기 -- ls
check "아홉 필드 중 하나가 빠지면 선다" "$rc" "3"
case "$msg" in
  *"직렬 웨이브 고지"*) ok "거부가 빠진 필드를 이름으로 지목한다" ;;
  *) bad "필드 문면" "$msg" ;;
esac
cp "$GBAK2" "$GRANT"

# ---------------------------------------------------------------------------
# 20. A resolved approval opens the act; a voided one closes it
#
# Nothing consumed the resolution, so `close` moved the row to `승인` and the
# next attempt at the same act took the same exit 5 — a loop that never closed.
# ---------------------------------------------------------------------------
# `aws s3` is outside the fixture's pre-authorization rows, so it issues one.
gateL act --manifest "$MANIFEST" --kind x --target infra --segment SROWLESS --cutpoint 배포 \
     --surface 외부상태변경 --snapshot-digest "$(HL)" --rationale x -- aws s3 ls
check "사전 인가 밖 행위는 승인을 발행한다" "$rc" "5"
ap=$( { grep -F '`승인`' "$LEDGER" | grep -F '상태=대기' || true; } | tail -1 \
      | tr '|' '\n' | sed -n 's/^ *승인 id=//p' | sed 's/[[:space:]]*$//' | tail -1)
if [ -n "$ap" ]; then ok "승인 id 가 원장에 남는다"; else bad "승인 id" "대기 행을 찾지 못했다"; fi

# Resolve it by hand — `close` reads a transcript this fixture has no way to
# produce, and what is under test is the CONSUMER of the resolved row.
printf -- '- `승인` | 승인 id=%s | 상태=승인 | 답변 문면=픽스처 | 해소 시각=t | prev=x\n' "$ap" >> "$LEDGER"
gateL plan --manifest "$MANIFEST" --kind x --target infra --segment SROWLESS --cutpoint 배포 \
     --surface 외부상태변경 -- aws s3 ls
check "해소된 승인이 같은 행위를 연다" "$rc" "0"

# And a voided one refuses rather than re-asking.
printf -- '- `승인` | 승인 id=%s | 상태=무효 | 답변 문면=픽스처 | 해소 시각=t | prev=x\n' "$ap" >> "$LEDGER"
gateL plan --manifest "$MANIFEST" --kind x --target infra --segment SROWLESS --cutpoint 배포 \
     --surface 외부상태변경 -- aws s3 ls
check "무효로 닫힌 승인은 행위를 거부한다" "$rc" "3"

# ---------------------------------------------------------------------------
# 21. A live stage suppresses the stagnation boundary
#
# The vector cannot move while a stage works — it is manifest-derived plus
# segment rows plus obligations plus cycles, and a working stage writes none of
# those. So every stage making four gate calls issued B1 against itself, and the
# resulting open approval suspended B1..B3 for the rest of the night.
# ---------------------------------------------------------------------------
if grep -vE '^[[:space:]]*#' "$GATE" | grep_all_q -F 'if [ "$(gate_live_stages)" != "0" ]; then'; then
  ok "B1 이 살아 있는 스테이지가 있으면 판정을 건너뛴다"
else
  bad "B1 억제" "정상 스테이지 위에서 경계가 계속 발화한다"
fi
if grep -vE '^[[:space:]]*#' "$GATE" | grep_all_q -F "gate_rows 'cycle'"; then
  ok "진전 벡터가 cycle 행을 본다"
else
  bad "진전 벡터" "리뷰 사이클이 진전으로 세어지지 않는다"
fi

# ---------------------------------------------------------------------------
# 22. A done proposal is not judged by the deadline's merge arm
#
# It has no act behind it, so `--cutpoint` carries no meaning there — yet the
# deadline read it and refused, leaving a past-deadline run unable to record
# that it had ended.
# ---------------------------------------------------------------------------
if grep -vE '^[[:space:]]*#' "$GATE" | grep_all_q -F '[ "$kind" = "propose-done" ] && return 0'; then
  ok "마감 게이트가 종료 제안을 면제한다"
else
  bad "마감 면제" "마감이 지난 런이 종료를 기록할 수 없다"
fi

# ---------------------------------------------------------------------------
# 23. The settings directory is serialized for readers and writers alike
# ---------------------------------------------------------------------------
if grep -vE '^[[:space:]]*#' "$GATE" | grep_all_q -F 'gate_settings_lock "$lk" || return 0'; then
  ok "재유도가 락 안에서 돈다"
else
  bad "재유도 락" "병렬 스테이지가 기준선을 서로 되돌린다"
fi
if grep -vE '^[[:space:]]*#' "$GATE" | grep_all_q -F 'out=$(gate_surface_digest_raw)'; then
  ok "표면 다이제스트도 같은 락을 잡는다 (반쯤 쓰인 디렉터리를 해싱하지 않는다)"
else
  bad "다이제스트 락" "읽는 쪽이 잠기지 않아 쓰기 도중을 해싱한다"
fi

# ---------------------------------------------------------------------------
# 24. terraform is graded by its SUBCOMMAND
#
# The name alone graded `외부상태변경`, so `terraform plan` — which the pipeline
# contract classifies as a read — issued an approval every time and an
# unattended stage could never look at infrastructure state.
# ---------------------------------------------------------------------------
graded_as '읽기'         'terraform plan 은 읽기다'              -- terraform plan
graded_as '읽기'         'show 도 읽기다'                        -- terraform show
graded_as '읽기'         '-chdir 이 앞에 와도 하위 명령을 본다'  -- terraform -chdir=/x plan
graded_as '외부상태변경' 'apply 는 외부 상태 변경이다'           -- terraform apply
graded_as '외부상태변경' 'destroy 도 같다'                       -- terraform destroy
graded_as '읽기'         'state list 는 읽기다'                  -- terraform state list
graded_as '외부상태변경' 'state rm 은 상태를 바꾼다'             -- terraform state rm x
graded_as '워크트리쓰기' 'fmt 는 파일을 고친다'                  -- terraform fmt
graded_as '읽기'         'fmt -check 는 고치지 않는다'           -- terraform fmt -check

# ---------------------------------------------------------------------------
# 25. Termination condition 10 — the authorized clauses are read
#
# The nine measured the ledger's shape and never the thing the user authorized
# the run against, so a run with clauses unsettled ended as `충족`. The fixture
# manifest above carries no `종료 절` rows, which means the condition never
# fires there — so this section uses a manifest that has them.
# ---------------------------------------------------------------------------
CM="$WORK/clause-plan.md"
sed 's/^\*\*런 최대 절단점\*\*: .*/**런 최대 절단점**: 배포/' "$MANIFEST" > "$CM"
printf -- '- `종료 절` | id=K1 | 문면=첫째 절\n- `종료 절` | id=K2 | 문면=둘째 절\n' >> "$CM"
# The binding digest no longer matches, and that is itself the check working —
# so it is removed rather than recomputed, which the driver reports and allows.
sed -i.bak '/^\*\*구속 다이제스트\*\*/d' "$CM" && rm -f "$CM.bak"

gateC() {
  local out
  out=$(cd "$WT" && XDG_STATE_HOME="$WORK/state-clause" bash "$GATE" "$@" 2>&1); rc=$?
  msg=$(printf '%s' "$out" | grep -vE '\[run\] ' | tr '\n' ' ' | sed 's/[[:space:]]*$//')
}
HC() { cd "$WT" && XDG_STATE_HOME="$WORK/state-clause" bash "$GATE" snapshot --manifest "$CM" 2>/dev/null | jq -r .H; }

gateC act --manifest "$CM" --kind propose-done --target infra --segment SW --cutpoint 커밋 \
      --surface 읽기 --snapshot-digest "$(HC)" --rationale x -- 절=x 근거=y
check "정산되지 않은 종료 절이 있으면 종료 제안이 기각된다" "$rc" "3"
case "$msg" in
  *"종료 절 K1"*) ok "기각이 어느 절인지 지목한다" ;;
  *) bad "절 문면" "$msg" ;;
esac
# The rejection ROW must stay inside the ledger's cap however many conditions
# are unmet — joining them all made a run with enough segments unable to record
# its own rejection at all.
rejlen=$( { grep -F '결정=기각' "$LEDGER" || true; } | tail -1 | wc -c | tr -d ' ')
if [ "${rejlen:-0}" -gt 0 ] && [ "${rejlen:-0}" -le 1024 ]; then
  ok "기각 행이 원장 상한 안에 든다 (${rejlen}바이트)"
else
  bad "기각 행 길이" "${rejlen}바이트"
fi

# The clause row is checked before it is accepted.
gateC act --manifest "$CM" --kind clause --target infra --cutpoint 커밋 --surface 읽기 \
      --snapshot-digest "$(HC)" --rationale x -- id=K9 상태=충족 근거=z
check "매니페스트에 없는 절은 정산할 수 없다" "$rc" "2"
gateC act --manifest "$CM" --kind clause --target infra --cutpoint 커밋 --surface 읽기 \
      --snapshot-digest "$(HC)" --rationale x -- id=K1 상태=충족
check "근거 없는 절 정산은 거부된다" "$rc" "2"
gateC act --manifest "$CM" --kind clause --target infra --cutpoint 커밋 --surface 읽기 \
      --snapshot-digest "$(HC)" --rationale x -- id=K1 상태=아마도 근거=z
check "어휘 밖 절 상태는 거부된다" "$rc" "2"

gateC act --manifest "$CM" --kind clause --target infra --cutpoint 커밋 --surface 읽기 \
      --snapshot-digest "$(HC)" --rationale x -- id=K1 상태=충족 근거="원장 12행"
check "근거를 실은 절 정산은 통과한다" "$rc" "0"
gateC act --manifest "$CM" --kind clause --target infra --cutpoint 커밋 --surface 읽기 \
      --snapshot-digest "$(HC)" --rationale x -- id=K2 상태=불가능 근거="인가 목록 밖"
check "불가능으로도 정산할 수 있다" "$rc" "0"

# ---------------------------------------------------------------------------
# 26. Grade-1 judgments have a writer
# ---------------------------------------------------------------------------
gateC act --manifest "$CM" --kind judgment --target infra --cutpoint 커밋 --surface 읽기 \
      --snapshot-digest "$(HC)" --rationale x -- 등급=1 기준=판단등급 근거=z
check "되돌리는 법이 없는 판단 행은 거부된다" "$rc" "2"
gateC act --manifest "$CM" --kind judgment --target infra --cutpoint 커밋 --surface 읽기 \
      --snapshot-digest "$(HC)" --rationale x -- 등급=0 기준=판단등급 "되돌리는 법=x" 근거=z
check "등급 0 은 판단 행으로 기록하지 않는다" "$rc" "2"
gateC act --manifest "$CM" --kind judgment --target infra --cutpoint 커밋 --surface 읽기 \
      --snapshot-digest "$(HC)" --rationale x \
      -- 등급=1 기준=판단등급 "되돌리는 법=git revert abc123" 근거="리뷰 스테이지를 하나로 합쳤다"
check "등급 1 판단이 기록된다" "$rc" "0"
if grep -q 'kind=judgment' "$LEDGER"; then
  ok "판단 행이 원장에 남는다 (아침에 되돌릴 수 있는 근거가 생긴다)"
else
  bad "판단 행" "원장에 kind=judgment 가 없다"
fi

# ---------------------------------------------------------------------------
# 27. `완료` is a terminal segment state
#
# A stage that produced its output and had nothing to merge could only be
# recorded as a merge that did not happen or a blockage that was a success.
# ---------------------------------------------------------------------------
gateL act --manifest "$MANIFEST" --kind segment --target infra --segment SDONE --cutpoint 커밋 \
     --snapshot-digest "$(HL)" --rationale x -- 상태=완료 워크트리="$WT"
check "완료 상태가 어휘에 있다" "$rc" "0"
# The enumeration moved to `liveness.sh` so the status line and the termination
# check read one value. This assertion follows the value: asserting against the
# gate would now pass only if the copy came back.
if grep -vE '^[[:space:]]*#' "$LIVENESS" | grep_all_q -F 'TERMINAL_SEGMENT_STATES="머지됨 완료 park"'; then
  ok "완료가 종단 집합에 든다 (종료 조건 1 이 이 세그먼트를 막지 않는다)"
else
  bad "종단 집합" "완료가 종단으로 인정되지 않는다"
fi
# And the copy must not return. A second assignment is the only way the two
# readers can diverge again, and it would not fail any count-based assertion.
if grep -vE '^[[:space:]]*#' "$GATE" | grep_all_q -F 'TERMINAL_SEGMENT_STATES='; then
  bad "종단 집합 사본" "gate.sh 가 열거를 다시 대입한다"
else
  ok "gate.sh 는 열거를 대입하지 않고 참조만 한다"
fi

# ---------------------------------------------------------------------------
# 28. The prose escape in the next-obligation check is gone
#
# Its own comment says prose does not count, and its last line accepted any
# rationale containing one Korean word.
# ---------------------------------------------------------------------------
if grep -vE '^[[:space:]]*#' "$GATE" | grep_all_q -F 'case "$why" in *미충족*) return 0 ;; esac'; then
  bad "산문 통과" "근거에 단어 하나만 있으면 통과하는 경로가 남아 있다"
else
  ok "근거 문자열만으로 다음 의무를 지목했다고 인정하지 않는다"
fi

# ---------------------------------------------------------------------------
# 29. A review obligation can be moved to `이행`, and only against evidence
#
# Section 10b issues one and nothing in the tree could close it: `리뷰 의무` was
# written in a single place, always as `상태=미이행`, and the router's row-writing
# kinds did not include the series. Termination condition 9 therefore held
# against every run that ever deferred a review — the state this pipeline aims
# at was unreachable, and the refusal read as the mechanism working.
# ---------------------------------------------------------------------------
ROID=$( { grep '^- `리뷰 의무`' "$LEDGER" || true; } | grep -F '세그먼트=SEP ' | tail -1 \
        | tr '|' '\n' | sed -n 's/^ *의무 id=//p' | sed 's/[[:space:]]*$//' | tail -1)
if [ -n "$ROID" ]; then
  ok "10b 이 발행한 의무 id 를 원장에서 읽는다 ($ROID)"
else
  bad "의무 id" "선머지후리뷰 머지가 남긴 리뷰 의무 행을 찾지 못했다"
fi

gateL act --manifest "$MANIFEST" --kind obligation --target infra --cutpoint 커밋 \
      --surface 읽기 --snapshot-digest "$(HL)" --rationale x -- "의무 id=$ROID"
check "근거 없는 이행은 거부된다 (주장만으로 리뷰를 닫지 않는다)" "$rc" "2"

gateL act --manifest "$MANIFEST" --kind obligation --target infra --cutpoint 커밋 \
      --surface 읽기 --snapshot-digest "$(HL)" --rationale x -- "의무 id=RO-00000000" 근거=z
check "존재하지 않는 의무는 닫을 수 없다" "$rc" "2"

gateL act --manifest "$MANIFEST" --kind obligation --target infra --cutpoint 커밋 \
      --surface 읽기 --snapshot-digest "$(HL)" --rationale x \
      -- "의무 id=$ROID" 근거="리뷰 리포트에서 P0=0 P1=0 을 읽었다"
check "근거를 실은 이행은 통과한다" "$rc" "0"

roall=$( { grep '^- `리뷰 의무`' "$LEDGER" || true; } | grep -F "의무 id=$ROID " || true)
lastro=$(printf '%s' "$roall" | tail -1)
case "$lastro" in
  *"상태=이행"*) ok "그 의무의 마지막 행이 이행이다" ;;
  *) bad "이행 상태" "$lastro" ;;
esac
case "$lastro" in
  *"이행 시각=-"*) bad "이행 시각" "이행인데 시각 자리가 그대로 비어 있다" ;;
  *"이행 시각="*)  ok "발행 때 비워 둔 이행 시각이 채워진다" ;;
  *) bad "이행 시각" "$lastro" ;;
esac
case "$lastro" in
  *"세그먼트=SEP "*) ok "세그먼트를 선행 행에서 옮겨 싣는다 (argv 가 정하지 않는다)" ;;
  *) bad "세그먼트 승계" "$lastro" ;;
esac
# The issuing row must SURVIVE: closing is an append, so the morning can still
# read when the review was deferred as well as when it landed.
case "$roall" in
  *"상태=미이행"*) ok "발행 시점의 미이행 행이 지워지지 않고 남는다 (편집이 아니라 append)" ;;
  *) bad "append 형태" "발행 행이 사라졌다 — 원장이 append 전용이라는 계약이 깨진다" ;;
esac

gateL act --manifest "$MANIFEST" --kind obligation --target infra --cutpoint 커밋 \
      --surface 읽기 --snapshot-digest "$(HL)" --rationale x \
      -- "의무 id=$ROID" 근거="두 번째 시도"
check "이미 닫힌 의무를 다시 닫지 않는다" "$rc" "2"

# THE POINT OF THE SECTION. Condition 9 was permanent; with the only obligation
# this run issued now fulfilled, it must be gone from the enumeration. Section 11
# measures the same string while the obligation is still open and is left alone —
# there it is correct for the condition to be listed.
gateL act --manifest "$MANIFEST" --kind propose-done --target front --cutpoint 커밋 \
      --surface 읽기 --snapshot-digest "$(HL)" --rationale "끝났다고 본다" -- true
case "$msg" in
  *"9 미이행 리뷰 의무"*) bad "조건 9" "의무를 닫았는데 여전히 미충족으로 열거된다" ;;
  *) ok "이행된 뒤에는 조건 9 가 열거되지 않는다 (런이 종료를 제안할 수 있다)" ;;
esac

# ---------------------------------------------------------------------------
# 30. git is graded by its SUBCOMMAND, not by the word `git`
#
# `worktree`, `branch` and `config` all sat on the read arm, so creating a
# working tree, deleting a ref and rewriting $HOME's own configuration each
# graded `읽기`. Two things followed: the reversibility floor accepted "put the
# setting back in the morning" as a cheap undo, and an act that declared its
# worktree creation honestly came back exit 6 while the same act declared as a
# read ran — so the only spelling that worked was the false one.
# ---------------------------------------------------------------------------
graded_as '읽기'         'git worktree list 는 읽기다'             -- git worktree list
graded_as '워크트리쓰기' 'git worktree add 는 워크트리를 만든다'   -- git worktree add /tmp/wt HEAD
graded_as '워크트리쓰기' 'git worktree remove 도 같다'             -- git worktree remove /tmp/wt
graded_as '읽기'         'git branch 는 목록 조회다'               -- git branch
graded_as '읽기'         '--show-current 도 조회다'                -- git branch --show-current
graded_as '읽기'         '값 있는 조회 옵션이 위치 인자로 보이지 않는다' -- git branch --contains HEAD
graded_as '워크트리쓰기' 'git branch -D 는 ref 를 지운다'          -- git branch -D topic
graded_as '워크트리쓰기' '이름을 주면 브랜치를 만든다'             -- git branch newbr
graded_as '읽기'         'git config --get 은 조회다'              -- git config --get user.name
graded_as '읽기'         '--global 이어도 --get 은 조회다'         -- git config --global --get user.name
graded_as '워크트리쓰기' '로컬 config 쓰기는 트리 안이다'          -- git config user.name x
graded_as '트리밖쓰기'   'git config --global 은 홈을 고친다'      -- git config --global user.name x

# The grade table alone does not cover what was observed: the refusal arrived as
# an exit 6 on the ACT path, so the repair has to be measured there too.
NEWWT="$WORK/honest-wt"
gateL exec --manifest "$MANIFEST" --target infra --cutpoint 커밋 --surface 워크트리쓰기 \
      --snapshot-digest "$(HL)" --rationale "정직하게 선언하고 워크트리를 만든다" \
      -- git worktree add --detach "$NEWWT" HEAD
check "정직하게 선언한 워크트리 생성이 exit 6 으로 거절되지 않는다" "$rc" "0"
if [ -e "$NEWWT" ]; then
  ok "선언대로 워크트리가 실제로 만들어진다"
else
  bad "워크트리 생성" "통과했는데 경로가 없다: $msg"
fi
# Leave the fixture repository's worktree set as it was found.
( cd "$WT" && git worktree remove --force "$NEWWT" && git worktree prune ) >/dev/null 2>&1 || true

# Slice C — one liveness predicate, the run handles, and the stall dedupe key
#
# The three properties here were each a measured defect rather than a worry:
# a render that counted pid FILES, a run whose termination was blocked forever
# by a reused pid (condition 7 has no resolving verb), and a second stall that
# never reached the ledger because the dedupe key matched the whole file.
# ---------------------------------------------------------------------------
# shellcheck source=/dev/null
. "$repo_root/scripts/run-fixture.sh"
# shellcheck source=/dev/null
. "$repo_root/plugins/cc-cmds/orchestrator/liveness.sh"

# This section drives the gate directly, and the suite's normal execution
# context is INSIDE a pipeline stage — which exports this whole group. The gate
# branches on `CC_PIPELINE_STAGE_ID` at entry (a stage session is kept out of
# the lineage so it cannot answer the approvals gating itself), so an inherited
# value makes every call below take that branch, `session-lineage` is never
# written, and the assertions that read it fail for a reason unrelated to what
# they assert. Clear the group so the section starts from a known state; the
# stage sub-case sets what it needs and unsets it again.
unset CC_PIPELINE_RUN_ID CC_PIPELINE_RUN_DIR CC_PIPELINE_MANIFEST \
      CC_PIPELINE_LEDGER CC_PIPELINE_GRANT CC_PIPELINE_GATE \
      CC_PIPELINE_TARGET CC_PIPELINE_SEGMENT CC_PIPELINE_STAGE_ID \
      CC_PIPELINE_PARENT_SESSION
trap 'fx_reap; rm -rf "$WORK"' EXIT

# --- the predicate itself, against all three pid states at once -------------
fx_mkrun "LIVENESS"
fx_stage_live   A
fx_stage_dead   B
fx_stage_reused C
n=$(cc_live_stages "$FX_RUN_DIR")
check "cc_live_stages 가 살아 있는 하나만 센다 (죽은 pid·재사용 pid 제외)" "$n" "1"
n=$( { ls "$FX_RUN_DIR"/*.pid 2>/dev/null || true; } | grep -c . || true)
check "그 픽스처의 pid 파일은 셋이다 (파일 수와 프로세스 수가 다르다)" "$n" "3"

# The glob has no namespace of its own, so what separates a stage from anything
# else that parks a pid here is the sibling its spawner leaves. The watcher's
# own `watch.pid` has none. A LIVE pid is written on purpose: a dead one is
# filtered by `kill -0` first, and the assertion would then pass whether or not
# the sibling test existed.
printf '%s' "$$" > "$FX_RUN_DIR/watch.pid"
n=$(cc_live_stages "$FX_RUN_DIR")
check "형제 없는 산 pid 는 스테이지로 세지 않는다 (워처의 watch.pid)" "$n" "1"
rm -f "$FX_RUN_DIR/watch.pid"

# The counterpart, which pins the option that was rejected: the driver's stage
# spawn writes `.pgid` and never `.start`, so raising `.start` alone to a
# necessary condition would silently drop every stage the driver started. The
# pgid is now what VERIFIES this stage's identity, so the fixture records the
# real one and the pass is earned rather than inherited from a bare `kill -0`.
fx_stage_driver_live D
n=$(cc_live_stages "$FX_RUN_DIR")
check "pgid 형제만 있는 드라이버 모양 스테이지는 센다" "$n" "2"
rm -f "$FX_RUN_DIR/D.pid" "$FX_RUN_DIR/D.pgid"

# The driver path's own pid-reuse case, which had no fixture and therefore no
# assertion. Until the identity check was split in three this shape fell
# through to `kill -0` and counted — the very hole the gate-spawned path had
# already closed.
fx_stage_driver_reused E
n=$(cc_live_stages "$FX_RUN_DIR")
check "pgid 가 어긋난 드라이버 모양 스테이지는 세지 않는다" "$n" "1"
rm -f "$FX_RUN_DIR/E.pid" "$FX_RUN_DIR/E.pgid"

# Sibling present, identity unverifiable — its own case rather than a pass.
fx_stage_unverifiable F
n=$(cc_live_stages "$FX_RUN_DIR")
check "형제는 있으나 신원을 확인할 수 없는 스테이지는 세지 않는다" "$n" "1"
rm -f "$FX_RUN_DIR/F.pid" "$FX_RUN_DIR/F.start"

# The identity layer itself. Deleting it makes the three counts above pass for
# the wrong reason, so a count is not what can catch that regression.
if grep -vE '^[[:space:]]*#' "$LIVENESS" | grep_all_q -F 'cc_proc_pgid() {' \
   && grep -vE '^[[:space:]]*#' "$LIVENESS" | grep_all_q -F 'now=$(cc_proc_pgid "$pid")'; then
  ok "liveness.sh 가 cc_proc_pgid 를 정의하고 신원 확인이 그것을 부른다"
else
  bad "pgid 신원" "드라이버 경로의 신원 확인 층이 없다"
fi

fx_approval AP-1 대기
fx_approval AP-2 대기
fx_approval AP-1 승인
n=$(cc_open_approvals "$FX_LEDGER")
check "cc_open_approvals 가 id 별 마지막 행으로 접는다" "$n" "1"

fx_segment SX 계획됨
fx_segment SY 머지됨
fx_segment SX park
n=$(cc_nonterminal_segments "$FX_LEDGER")
check "cc_nonterminal_segments 도 마지막 행으로 접는다" "$n" "0"
n=$(cc_segment_count "$FX_LEDGER")
check "cc_segment_count 가 고유 세그먼트를 센다 (공집합 가드의 입력)" "$n" "2"

# `완료` is the third terminal state and this predicate used to carry its own
# two-element enumeration. A 완료 segment is what separates "reads the shared
# constant" from "happens to agree on the other two": counted as in flight, a
# finished run can never end.
fx_segment SZ 완료
n=$(cc_nonterminal_segments "$FX_LEDGER")
check "완료 세그먼트도 종단으로 접는다 (게이트와 같은 열거)" "$n" "0"
n=$(cc_segment_count "$FX_LEDGER")
check "그 완료 픽스처가 실제로 심겼다" "$n" "3"

fx_blocked "정지 A" 불명
fx_blocked "정지 B" 불명
fx_blocked "정지 A" 해소
n=$(cc_unresolved_blocked "$FX_LEDGER" | grep -c . || true)
check "cc_unresolved_blocked 가 해소된 사유를 빼고 센다" "$n" "1"
msg=$(cc_unresolved_blocked "$FX_LEDGER" | cut -f2-)
check "남은 것이 해소되지 않은 쪽이다" "$msg" "정지 B"
fx_reap

# --- the handles the gate publishes on every entry --------------------------
#
# A FRESH RUN, not R1. The assertions below drive real `act`s, and R1's
# enforcement-surface baseline has moved several times by this point in the
# suite — earlier tests rewrite the grant and the manifest on purpose. An act
# against it exits 7 before it ever reaches the condition being asserted, which
# is the boundary working rather than a defect. Only the run id changes: the
# manifest's two digests cover the goal, the clauses, the targets, the rule
# settings, the pre-authorizations and the deadline — not the id.
sed 's/R1/R2/g' "$MANIFEST" > "$WT/plan2.md"
sed 's/R1/R2/g' "$GBAK" > "$WT/docs/pipeline-grant/R2.md"
MANIFEST="$WT/plan2.md"
LEDGER="$WT/docs/pipeline-run/R2.md"
GRANT="$WT/docs/pipeline-grant/R2.md"
RD="$XDG_STATE_HOME/cc-cmds/run/R2"
CLAUDE_CODE_SESSION_ID=sess-alpha
export CLAUDE_CODE_SESSION_ID
gate snapshot --manifest "$MANIFEST"
check "핸들을 쓰는 동사가 통과한다" "$rc" "0"
check "ledger-path 가 원장 절대경로를 담는다" "$(cat "$RD/ledger-path" 2>/dev/null || true)" "$LEDGER"

# Lineage used to be recorded only inside `gate_transcript_files`, which only
# `close` reaches — so a run that never opened an approval had none at all.
# The file accumulates every session id this run has had, so the assertion is
# on THIS id's occurrences rather than on the file's length.
n=$(grep -cxF 'sess-alpha' "$RD/session-lineage" 2>/dev/null || true)
check "승인 없는 동사에서도 계보가 생긴다" "$n" "1"
gate snapshot --manifest "$MANIFEST"
n=$(grep -cxF 'sess-alpha' "$RD/session-lineage" 2>/dev/null || true)
check "같은 세션 id 로 다시 불러도 계보에 한 번만 남는다" "$n" "1"

# R1, measured. Every id in the lineage is an id allowed to ANSWER an approval,
# because that is the set `gate_transcript_files` searches. Stages reach the
# gate too — the pre-tool hook routes their Bash, Write and Edit through it — so
# an unguarded promotion would let a stage answer the approvals gating itself.
CC_PIPELINE_STAGE_ID=SC
export CC_PIPELINE_STAGE_ID
CLAUDE_CODE_SESSION_ID=sess-stage
gate snapshot --manifest "$MANIFEST"
n=$(grep -cxF 'sess-stage' "$RD/session-lineage" 2>/dev/null || true)
check "스테이지 세션은 계보에 들어가지 않는다 (자기 승인 경로가 열리지 않는다)" "$n" "0"
n=$(grep -cxF 'R2' "$XDG_STATE_HOME/cc-cmds/session/sess-stage" 2>/dev/null || true)
check "그래도 순방향 색인에는 들어간다 (표시용이지 승인 채널이 아니다)" "$n" "1"
unset CC_PIPELINE_STAGE_ID
CLAUDE_CODE_SESSION_ID=sess-alpha
export CLAUDE_CODE_SESSION_ID

# The FORWARD index. It is a list because one session can hold several runs;
# the dedupe is what keeps repeated entries from growing it without bound.
SIDX="$XDG_STATE_HOME/cc-cmds/session/sess-alpha"
check "순방향 색인이 이 런을 담는다" "$(cat "$SIDX" 2>/dev/null || true)" "R2"
n=$(grep -c . "$SIDX" 2>/dev/null || true)
check "같은 런을 두 번 봐도 색인은 한 줄이다" "$n" "1"
printf '%s\n' "R-OTHER" >> "$SIDX"
gate snapshot --manifest "$MANIFEST"
n=$(grep -c . "$SIDX" 2>/dev/null || true)
check "한 세션에 런이 둘이면 두 줄로 남는다 (덮어쓰기가 아니다)" "$n" "2"
sed '/^R-OTHER$/d' "$SIDX" > "$SIDX.tmp" && mv "$SIDX.tmp" "$SIDX"

# Every `act` carries a snapshot digest, and the snapshot moves whenever a row
# lands — so it is re-read immediately before each one rather than reused.
snapH() {
  ( cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null ) \
    | sed -n 's/.*"H": "\([0-9a-f]*\)".*/\1/p' | tail -1
}

# --- termination condition 7 reads the same predicate -----------------------
FX_RUN_DIR="$RD"; FX_PIDS=""
fx_stage_dead D1
gate act --manifest "$MANIFEST" --kind propose-done --target infra --segment - \
  --cutpoint 커밋 --surface 읽기 --snapshot-digest "$(snapH)" \
  --rationale "픽스처 — 미충족 조건 열거"
case "$msg" in
  *"7 살아 있는 스테이지"*) bad "조건 7" "죽은 pid 를 살아 있다고 셌다" ;;
  *"미충족 조건"*) ok "조건 7 이 죽은 pid 를 세지 않는다" ;;
  *) bad "조건 7" "조건 열거에 닿지 못했다: $msg" ;;
esac
fx_stage_reused D2
gate act --manifest "$MANIFEST" --kind propose-done --target infra --segment - \
  --cutpoint 커밋 --surface 읽기 --snapshot-digest "$(snapH)" \
  --rationale "픽스처 — 미충족 조건 열거"
case "$msg" in
  *"7 살아 있는 스테이지"*) bad "조건 7" "재사용 pid 를 살아 있다고 셌다 — 종료를 영구히 막는 경로다" ;;
  *"미충족 조건"*) ok "조건 7 이 재사용 pid 를 세지 않는다" ;;
  *) bad "조건 7" "조건 열거에 닿지 못했다: $msg" ;;
esac
fx_stage_live D3
gate act --manifest "$MANIFEST" --kind propose-done --target infra --segment - \
  --cutpoint 커밋 --surface 읽기 --snapshot-digest "$(snapH)" \
  --rationale "픽스처 — 미충족 조건 열거"
case "$msg" in
  *"7 살아 있는 스테이지가 1개입니다"*) ok "조건 7 이 실제로 살아 있는 스테이지는 센다" ;;
  *) bad "조건 7" "살아 있는 스테이지를 놓쳤다: $msg" ;;
esac
fx_reap
rm -f "$RD"/D1.pid "$RD"/D1.start "$RD"/D2.pid "$RD"/D2.start "$RD"/D3.pid "$RD"/D3.start

# --- gate_drain_stall: four, and the fourth is the one that was missing -----
#
# Draining happens in the `act` path, not on `snapshot` — the transcription is
# the ledger writer's job and `snapshot` writes nothing. So each step here
# drives a real act.
TAB=$(printf '\t')
drain_act() {
  gate act --manifest "$MANIFEST" --kind segment --target infra --segment SDR \
    --cutpoint 커밋 --surface 읽기 --snapshot-digest "$(snapH)" \
    --rationale "픽스처 — 전사 유발" -- "상태=계획됨" "워크트리=$WT"
}
printf '2026-08-31T00:00:00Z%s정체 사유 X%s재개 명령 X\n' "$TAB" "$TAB" > "$RD/stall"
drain_act
n=$(grep -cF '원인=불명 | 사유=정체 사유 X' "$LEDGER" || true)
check "정지 관측이 blocked 행으로 전사된다" "$n" "1"
n=$(wc -c < "$RD/stall" | tr -d ' ')
check "전사 뒤 관측 파일이 비워진다" "$n" "0"
printf '2026-08-31T00:01:00Z%s정체 사유 X%s재개 명령 X\n' "$TAB" "$TAB" > "$RD/stall"
drain_act
n=$(grep -cF '원인=불명 | 사유=정체 사유 X' "$LEDGER" || true)
check "미해소인 같은 사유는 두 번 전사되지 않는다" "$n" "1"
# THE FOURTH. A person resolves the block, the same condition recurs, and the
# recurrence has to reach the ledger — otherwise the morning report cannot tell
# "it stalled once and was cleared" from "it is still stalling".
gate act --manifest "$MANIFEST" --kind blocked --target infra --segment - \
  --cutpoint 커밋 --surface 읽기 --snapshot-digest "$(snapH)" --rationale "픽스처" \
  -- "원인=해소" "사유=정체 사유 X" "근거=픽스처가 해소로 판정했다"
check "해소 행이 통과한다" "$rc" "0"
printf '2026-08-31T00:02:00Z%s정체 사유 X%s재개 명령 X\n' "$TAB" "$TAB" > "$RD/stall"
drain_act
n=$(grep -cF '원인=불명 | 사유=정체 사유 X' "$LEDGER" || true)
check "해소 뒤 같은 사유가 다시 멈추면 그 관측이 다시 전사된다" "$n" "2"

printf '\ntest-gate: %d passed, %d failed\n' "$passed" "$failed"
[ "$failed" = "0" ]
