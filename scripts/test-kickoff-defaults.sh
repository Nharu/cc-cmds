#!/usr/bin/env bash
# lint-autoadopt-vocabulary: self-skip
# Test the autopilot kickoff's defaults reader (orchestrator/kickoff-defaults.sh).
#
# WHAT THIS SUITE IS FOR. The helper sits between a file a person wrote weeks
# ago and a manifest the run cannot change once frozen, and it fails silently in
# both directions: a value it lets through that the manifest check refuses is a
# hard stop at freeze time, and a value it refuses that the check accepts is a
# question the person answers again for nothing. So beyond each key's grammar
# this suite holds the helper to the driver's own vocabulary and checks — it
# sources run.sh for the cutpoint, review-policy and judgment-class literals and
# for `check_manifest`, and gate.sh for the cost-figure grammar — rather than to
# a copy of them written here.
#
# This file carries forbidden auto-adoption class literals on purpose (they are
# the refusal cases), hence the self-skip line above.
#
# Every helper call goes through `kd`, which strips `CC_PIPELINE_RUN_ID`: this
# suite runs inside implementation stages that inherit the pipeline variables,
# and the helper refuses outright there. Exactly one case calls it with the
# variable set, to assert that refusal.
#
# The helper runs under the same interpreter as this file (`$BASH`), so running
# the suite with another bash runs the helper with it too.
#
# Usage: bash scripts/test-kickoff-defaults.sh

set -uo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
ORCH="$repo_root/plugins/cc-cmds/orchestrator"
HELPER="$ORCH/kickoff-defaults.sh"
DRIVER="$ORCH/run.sh"
GATE_SH="$ORCH/gate.sh"
SKILL="$repo_root/plugins/cc-cmds/skills/autopilot/SKILL.md"
# 5a–5p 의 경계 문단은 상주 본문이 아니라 이 참조 파일에 있다.
BOUNDARIES="$repo_root/plugins/cc-cmds/skills/autopilot/references/boundaries.md"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/cc-kickoff-defaults-test.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

passed=0
failed=0
ok()    { passed=$((passed + 1)); printf 'PASS: %s\n' "$1"; }
bad()   { failed=$((failed + 1)); printf 'FAIL: %s — %s\n' "$1" "${2:-}" >&2; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got '$2', want '$3'"; fi; }

# The host's own defaults and the pipeline's variables must not leak in: the
# first would make results depend on the machine, the second would make every
# call a refusal. The banner channel is off for the whole process.
for v in $(compgen -e | grep -E '^(CC_CMDS_AUTOPILOT_DEFAULT|CC_PIPELINE_)' || true); do
  unset "$v"
done
# The pipeline names again, in the one spelling the meta suite's leak census
# looks for in every suite that runs or sources the gate family — this one
# sources the gate and the driver in child shells.
for v in $(compgen -e | grep '^CC_PIPELINE_' || true); do unset "$v"; done
CC_CMDS_AUTOPILOT_NOTIFY=0
export CC_CMDS_AUTOPILOT_NOTIFY
# The gate's run-open branch starts the dashboard server; nothing here stops it.
CC_CMDS_DASHBOARD=off
export CC_CMDS_DASHBOARD
HOME="$WORK/home"; mkdir -p "$HOME"
export HOME
unset XDG_CONFIG_HOME
# The helper judges `plugin-allow` against the session's account directory, so
# that directory is a fixture too: without this every case would read the host
# account's plugins.
CLAUDE_CONFIG_DIR="$WORK/claude"; mkdir -p "$CLAUDE_CONFIG_DIR"
export CLAUDE_CONFIG_DIR
TZ=Asia/Seoul
export TZ

NOW=1790000000   # 2026-09-21T23:13:20+09:00
F="$WORK/defaults"

kd() { env -u CC_PIPELINE_RUN_ID "$BASH" "$HELPER" "$@"; }
# kf <file content> [helper args…] — run against a fixture file.
kf() {
  local content="$1"; shift
  printf '%s\n' "$content" > "$F"
  CC_CMDS_AUTOPILOT_DEFAULTS_FILE="$F" kd --now "$NOW" "$@"
}
# st <output> <key> [nth] — `적용`, or the reason token of a `무시` row, or `없음`.
st() {
  printf '%s\n' "$1" | awk -F'\t' -v k="$2" -v n="${3:-1}" '
    ($1 == "적용" || $1 == "무시") && $3 == k { c++; if (c == n) { print ($1 == "적용" ? "적용" : $6); f = 1; exit } }
    END { if (!f) print "없음" }'
}
# col <output> <key> <column> — that column of the first row for the key.
col() { printf '%s\n' "$1" | awk -F'\t' -v k="$2" -v c="$3" '($1 == "적용" || $1 == "무시") && $3 == k { print $c; exit }'; }
rows() { printf '%s\n' "$1" | awk -F'\t' '$1 == "적용" || $1 == "무시"' | grep -c . || true; }
T='--target Nharu/cc-cmds'

# ---------------------------------------------------------------------------
# 종료 코드와 출력 모양
# ---------------------------------------------------------------------------
out=$(CC_PIPELINE_RUN_ID=x "$BASH" "$HELPER" $T 2>/dev/null); rc=$?
check "파이프라인 런 안에서는 3 으로 거부한다" "$rc" "3"
check "거부할 때 stdout 은 비어 있다" "$out" ""
out=$(kd --now "$NOW" 2>/dev/null); rc=$?
check "--target 이 없으면 2" "$rc" "2"
check "용법 오류일 때 stdout 은 비어 있다" "$out" ""
check "모르는 인자는 2" "$(kd $T --bogus >/dev/null 2>&1; echo $?)" "2"

out=$(kf 'ladder-rungs = 4
nope = 1' $T)
check "첫 줄이 머리 줄이다" "$(printf '%s\n' "$out" | sed -n 1p)" "cc-kickoff-defaults v1"
check "원천 행은 네 칸" "$(printf '%s\n' "$out" | awk -F'\t' '$1=="원천"{print NF}')" "4"
check "적용 행은 일곱 칸" "$(printf '%s\n' "$out" | awk -F'\t' '$1=="적용"{print NF; exit}')" "7"
check "무시 행은 일곱 칸" "$(printf '%s\n' "$out" | awk -F'\t' '$1=="무시"{print NF; exit}')" "7"

# ---------------------------------------------------------------------------
# 원천 행
# ---------------------------------------------------------------------------
want_sha=$(shasum -a 256 "$F" 2>/dev/null | awk '{print $1}')
[ -n "$want_sha" ] || want_sha=$(sha256sum "$F" | awk '{print $1}')
check "원천 행의 sha256 이 파일 전체 해시다" "$(printf '%s\n' "$out" | awk -F'\t' '$1=="원천"{print $3}')" "$want_sha"
out=$(CC_CMDS_AUTOPILOT_DEFAULT_LADDER_RUNGS=2 CC_CMDS_AUTOPILOT_DEFAULT_COST_CEILING=bogus \
      CC_CMDS_AUTOPILOT_DEFAULT_TYPO=1 CC_CMDS_AUTOPILOT_DEFAULTS_FILE=off kd --now "$NOW" $T)
check "읽은 환경변수 수는 런 단위 키 변수(유효·무효)만 센다" \
  "$(printf '%s\n' "$out" | awk -F'\t' '$1=="원천"{print $4}')" "2"
out=$(CC_CMDS_AUTOPILOT_DEFAULTS_FILE="$WORK/absent" kd --now "$NOW" $T)
check "파일이 없으면 원천 없음" "$(printf '%s\n' "$out" | awk -F'\t' '$1=="원천"{print $2"|"$3}')" "없음|-"
check "파일이 없으면 행 0" "$(rows "$out")" "0"

# ---------------------------------------------------------------------------
# 경로
# ---------------------------------------------------------------------------
mkdir -p "$HOME/.config/cc-cmds" "$WORK/xdg/cc-cmds"
printf 'ladder-rungs = 4\n' > "$HOME/.config/cc-cmds/autopilot-defaults"
printf 'ladder-rungs = 2\n' > "$WORK/xdg/cc-cmds/autopilot-defaults"
out=$(kd --now "$NOW" $T)
check "XDG_CONFIG_HOME 이 없으면 \$HOME/.config 아래" "$(col "$out" ladder-rungs 4)" "4"
out=$(XDG_CONFIG_HOME="$WORK/xdg" kd --now "$NOW" $T)
check "XDG_CONFIG_HOME 이 있으면 그 아래" "$(col "$out" ladder-rungs 4)" "2"
out=$(XDG_CONFIG_HOME="rel/xdg" kd --now "$NOW" $T)
check "상대 XDG_CONFIG_HOME 은 원천 해석불가" "$(printf '%s\n' "$out" | awk -F'\t' '$1=="원천"{print $2}')" "해석불가"
check "해석불가면 행 0" "$(rows "$out")" "0"
rm -f "$HOME/.config/cc-cmds/autopilot-defaults"

# ---------------------------------------------------------------------------
# 문법
# ---------------------------------------------------------------------------
out=$(kf '
# 주석
  ladder-rungs   =   4
[Nharu/cc-cmds]
act-allow = 형태=gh pr | 사유=a=b
no equals here' $T)
check "빈 줄·주석·양끝 공백" "$(st "$out" ladder-rungs)" "적용"
check "첫 = 에서만 가르고 값 안의 = 는 보존한다" "$(col "$out" act-allow 4)" "형태=gh pr | 사유=a=b"
check "= 없는 줄은 그 줄만 문법 오류" "$(st "$out" -)" "문법 오류"
check "문법 오류 행의 출처가 줄 번호다" "$(col "$out" - 5)" "파일:6"
printf 'ladder-rungs = 2\r\n[Nharu/cc-cmds]\r\ncutpoint = 머지\r\n' > "$F"
out=$(CC_CMDS_AUTOPILOT_DEFAULTS_FILE="$F" kd --now "$NOW" $T)
check "CRLF 의 CR 을 떼고 읽는다" "$(st "$out" ladder-rungs)|$(st "$out" cutpoint)" "적용|적용"
out=$(kf "$(printf 'cost-ceiling = 5\t0')" $T)
check "값의 TAB 은 문법 오류" "$(st "$out" cost-ceiling)" "문법 오류"
MARK="$WORK/marker"
out=$(kf "roster-model = \$(touch $MARK)
[Nharu/cc-cmds]
cutpoint = \`touch $MARK\`" $T)
if [ -e "$MARK" ]; then bad "파일은 셸로 실행되지 않는다" "표지 파일이 생겼다"; else ok "파일의 \$(…) 값이 실행되지 않는다"; fi
check "그 값은 어휘 밖으로 무시된다" "$(st "$out" roster-model)" "어휘 밖"

# ---------------------------------------------------------------------------
# 범위
# ---------------------------------------------------------------------------
out=$(kf 'cutpoint = 머지
bogus-key = 1
[Nharu/cc-cmds]
ladder-rungs = 4
[Other/repo]
garbage line
cutpoint = 엉터리' $T)
check "레포 키가 구획 앞이면 자리 틀림" "$(st "$out" cutpoint)" "자리 틀림"
check "런 키가 구획 안이면 자리 틀림" "$(st "$out" ladder-rungs)" "자리 틀림"
check "모르는 키" "$(st "$out" bogus-key)" "모르는 키"
check "대상이 아닌 구획은 행이 없다" "$(printf '%s\n' "$out" | grep -c 'Other/repo\|garbage\|엉터리' || true)" "0"

# ---------------------------------------------------------------------------
# 이름 지은 거부
# ---------------------------------------------------------------------------
out=$(kf 'termination = 커밋
launch = 지금
defer = 1
notify = 0
[Nharu/cc-cmds]
apply-command = make deploy
apply-radius = 레포' $T)
for k in termination launch defer notify apply-command apply-radius; do
  check "이름 지은 거부: $k" "$(st "$out" "$k")" "이름 지은 거부"
done
check "termination 의 문면" "$(col "$out" termination 7)" "종료 지점은 런마다 묻습니다"
check "notify 의 문면" "$(col "$out" notify 7)" "배너는 CC_CMDS_AUTOPILOT_NOTIFY 로만 끕니다"

# ---------------------------------------------------------------------------
# 중복
# ---------------------------------------------------------------------------
out=$(kf 'ladder-rungs = 4
ladder-rungs = 2
auto-adopt = 판단 부류=문서-신선도 | 상한=3 | 심각도 상한=minor | 사유=a
auto-adopt = 판단 부류=문서-신선도 | 상한=1 | 심각도 상한=trivial | 사유=b
[Nharu/cc-cmds]
act-allow = 형태=gh pr | 사유=a
act-allow = 형태=gh pr | 사유=b' $T)
check "스칼라 두 번: 앞엣것 중복" "$(st "$out" ladder-rungs 1)" "중복"
check "스칼라 두 번: 뒤엣것 중복" "$(st "$out" ladder-rungs 2)" "중복"
check "같은 판단 부류 두 번: 앞엣것 적용" "$(st "$out" auto-adopt 1)" "적용"
check "같은 판단 부류 두 번: 뒤엣것만 중복" "$(st "$out" auto-adopt 2)" "중복"
check "같은 형태 두 번: 앞엣것 적용" "$(st "$out" act-allow 1)" "적용"
check "같은 형태 두 번: 뒤엣것만 중복" "$(st "$out" act-allow 2)" "중복"

# 슬러그 대조 — Step 2 가 쓰는 `<owner>/<name>` 철자와 구획 머리의 흔한 변형.
out=$(kf '[nharu/CC-CMDS]
cutpoint = 머지' $T)
check "대소문자만 다른 구획 머리가 대상과 맞는다" "$(st "$out" cutpoint)" "적용"
check "적용 범위는 --target 철자다" "$(col "$out" cutpoint 2)" "Nharu/cc-cmds"
out=$(kf '[Nharu/cc-cmds.git]
cutpoint = 머지' $T)
check "끝 .git 이 붙은 구획 머리가 대상과 맞는다" "$(st "$out" cutpoint)" "적용"
out=$(kf '[Nharu/cc-cmds]
cutpoint = 머지
[NHARU/cc-cmds]
terminal-cap = 3' $T)
check "대소문자만 다른 구획 둘: 앞 구획 중복" "$(st "$out" cutpoint)" "중복"
check "대소문자만 다른 구획 둘: 뒤 구획 중복" "$(st "$out" terminal-cap)" "중복"

# ---------------------------------------------------------------------------
# 키별 검증
# ---------------------------------------------------------------------------
# kv <scope run|repo> <key> <value> → the status token
kv() {
  local body
  if [ "$1" = "run" ]; then body="$2 = $3"; else body="[Nharu/cc-cmds]
cutpoint = 머지
$2 = $3"; fi
  st "$(kf "$body" $T)" "$2"
}
expect() {   # expect <scope> <key> <want> <values…>
  local sc="$1" k="$2" want="$3" v; shift 3
  for v in "$@"; do check "$k '$v' → $want" "$(kv "$sc" "$k" "$v")" "$want"; done
}
expect run ladder-rungs 적용 4 2
expect run ladder-rungs '어휘 밖' 3
expect run stagnation-bound 적용 6 없음
expect run stagnation-bound '형식 오류' 0 -1 06
expect run cost-ceiling 적용 120 .5 50.5 없음
expect run cost-ceiling '형식 오류' 0 00 5. '$50' 1e3
expect run roster-model 적용 opus
expect run roster-model '어휘 밖' gpt
expect run roster-model.verification 적용 sonnet
expect run roster-model.Verification '모르는 키' sonnet
expect run roster-model.a_b '모르는 키' sonnet
check "cutpoint 머지 수락" "$(st "$(kf '[Nharu/cc-cmds]
cutpoint = 머지' $T)" cutpoint)" "적용"
check "cutpoint 표시형은 표시형" "$(st "$(kf '[Nharu/cc-cmds]
cutpoint = 머지 후 후속 착수' $T)" cutpoint)" "표시형"
check "cutpoint bogus 는 어휘 밖" "$(st "$(kf '[Nharu/cc-cmds]
cutpoint = bogus' $T)" cutpoint)" "어휘 밖"
expect repo review-ceiling 적용 선리뷰후머지 선머지후리뷰
expect repo review-ceiling '어휘 밖' 아무거나
expect repo terminal-cap 적용 3 없음
expect repo terminal-cap '형식 오류' 0 x
expect repo dev-ids 적용 'aws-profile:dev' 'aws-account:123456789012, dir:/srv/x' 'kube-context:k,host:h,domain:d' 없음
expect repo dev-ids '형식 오류' 'aws-account:12345' 'aws-account:1234567890ab' 'dir:relative/path' 'aws-acct:dev' 'aws-profile' 'host:' 'host:a,' \
  'host:a | 리뷰 정책 상한=리뷰없음' 'host:`a`' 'host: a'
expect repo deploy-triggers 적용 'workflow:deploy.yml' 'jenkins-job:x, argv:bash scripts/deploy.sh' 없음
expect repo deploy-triggers '형식 오류' 'release' 'deploy:release' 'workflow:' 'argv:x | 실행 워크트리=/tmp/other'
# 대상 행은 | 로 갈리므로 원소 안의 | 는 확정 뒤 별개 필드가 된다 — 거부 문면이 매니페스트
# 검사와 같은 사유인지까지 본다.
check "| 를 품은 식별자 원소의 거부 사유는 매니페스트 검사의 사유 꼬리와 같다" \
  "$(col "$(kf '[Nharu/cc-cmds]
dev-ids = host:a | 리뷰 정책 상한=리뷰없음' $T)" dev-ids 7)" \
  "dev 식별자 원소 'host:a | 리뷰 정책 상한=리뷰없음' 에 | 나 백틱이 있습니다 — 대상 행의 필드 구분자라 다른 필드로 읽힙니다"
out=$(kf '[Nharu/cc-cmds]
cutpoint = 머지
dev-ids = aws-profile:dev ,  host:h' $T)
check "식별자 목록의 적용 값은 다듬은 원소를 쉼표로 잇는다" "$(col "$out" dev-ids 4)" "aws-profile:dev,host:h"
check "식별자 거부 사유는 매니페스트 검사의 사유 꼬리와 같다" \
  "$(col "$(kf '[Nharu/cc-cmds]
dev-ids = aws-account:1234' $T)" dev-ids 7)" "aws-account '1234' 가 12자리가 아닙니다"
expect repo act-allow 적용 '형태=gh pr | 사유=리뷰'
expect repo act-allow '형식 오류' '형태=gh pr | 사유=a | 인터뷰 기록=x' '형태=bash | 사유=a' '형태=a|b | 사유=c' '사유=a | 형태=gh pr' '형태=gh pr | 사유='
expect run auto-adopt 적용 '판단 부류=감사-발견 | 상한=없음 | 심각도 상한=major | 사유=a'
expect run auto-adopt '금지 부류' '판단 부류=팀-구성 | 상한=1 | 심각도 상한=minor | 사유=a'
# 사람만 답하는 부류도 금지 목록 소속이라 같은 사유로 무시된다 — 어휘 루프가 아니라
# 이 줄이 그 이름을 직접 부른다(부류가 목록에서 빠지면 루프는 조용히 적용으로 바뀐다).
expect run auto-adopt '금지 부류' '판단 부류=사람-결정 | 상한=1 | 심각도 상한=minor | 사유=a'
expect run auto-adopt '어휘 밖' '판단 부류=없는부류 | 상한=1 | 심각도 상한=minor | 사유=a' '판단 부류=감사-발견 | 상한=1 | 심각도 상한=huge | 사유=a'
expect run auto-adopt '형식 오류' '상한=1 | 판단 부류=감사-발견 | 심각도 상한=minor | 사유=a' '판단 부류=감사-발견 | 상한=1 | 심각도 상한=minor'

# 공백 변형 — 목록 키는 바이트 그대로 얼려지므로, 매니페스트 검사·게이트·대조기가
# 그 철자로 읽지 못할 값은 사람 앞에서 거부된다. 필드 끝 공백은 셋 다 깎으므로 받는다.
expect repo act-allow '형식 오류' '형태= gh pr | 사유=a' '형태=gh  pr view | 사유=a' '형태=  | 사유=a'
expect repo act-allow 적용 '형태=gh pr  | 사유=a' ' 형태=gh pr | 사유=a'
expect run auto-adopt '형식 오류' '판단 부류= 감사-발견 | 상한=1 | 심각도 상한=minor | 사유=a' \
  '판단 부류=감사-발견 | 상한= 1 | 심각도 상한=minor | 사유=a' \
  '판단 부류=감사-발견 | 상한=1 | 심각도 상한= minor | 사유=a' \
  '판단 부류=감사-발견 | 상한=1 | 심각도 상한=minor | 사유= a'
expect run auto-adopt 적용 '판단 부류=감사-발견  | 상한=1 | 심각도 상한=minor | 사유=a'
check "공백 변형 형태 거부 사유" "$(col "$(kf '[Nharu/cc-cmds]
act-allow = 형태= gh pr | 사유=a' $T)" act-allow 7)" "형태 는 = 바로 뒤에 공백 없이 낱말 사이를 한 칸으로 씁니다 — 대조기가 이 철자 그대로 비교합니다"

# 적용된 사전 인가 행을 대조기의 탐침 모드에 그대로 넣으면 그 형태의 행위와 맞는다.
MATCHER="$ORCH/rules/사전-인가-대조.sh"
probe_row() {   # probe_row <applied tail> <argv> → the probe's P= field
  printf -- '- `사전 인가` | %s\n' "$1" > "$WORK/preauth.md"
  GATE_PREAUTH_PROBE=1 GATE_MANIFEST="$WORK/preauth.md" GATE_ARGV="$2" sh "$MATCHER" 2>/dev/null \
    | sed -n 's/^P=\([01]\).*/\1/p'
}
for v in '형태=gh pr | 사유=a' '형태=gh pr  | 사유=a' ' 형태=gh pr | 사유=a'; do
  o=$(kf "[Nharu/cc-cmds]
act-allow = $v" $T)
  check "적용된 사전 인가 '$v' 가 대조기에서 gh pr view 와 맞는다" "$(probe_row "$(col "$o" act-allow 4)" 'gh pr view 1')" "1"
done
check "거부된 공백 변형은 대조기에서도 맞지 않는다 (거부 근거)" "$(probe_row '형태= gh pr | 사유=a' 'gh pr view 1')" "0"

# 대조기는 행위 argv 만 정규화한다(argv0 basename, 뒤의 `-x=y` 낱말 버림). 그 정규화가
# 바꿀 형태는 같은 철자의 행위와도 맞지 않으므로 사람 앞에서 거부한다.
expect repo act-allow '형식 오류' '형태=terraform -chdir=infra apply | 사유=a' '형태=/usr/bin/gh pr | 사유=a' \
  '형태=gh pr --repo=x | 사유=a' '형태=/usr/bin/npm run | 사유=a'
expect repo act-allow 적용 '형태=terraform apply | 사유=a' '형태=git -C dir | 사유=a'
check "정규화가 바꿀 형태의 거부 사유는 대조기가 보는 철자와 그 철자가 여는 범위, 행이 없을 때의 결과를 적는다" "$(col "$(kf '[Nharu/cc-cmds]
act-allow = 형태=terraform -chdir=infra apply | 사유=a' $T)" act-allow 7)" \
  "형태 는 대조기가 보는 철자로 씁니다 — 명령 경로 없이, -x=y 낱말 없이 (대조기가 보는 철자: \`terraform apply\`). 이 철자는 뗀 경로의 모든 값을 열고, 이 철자의 마지막 낱말 앞에 -x=y 낱말이 끼어든 행위는 열지 않으며, 이 낱말들로 시작하는 비파괴 행위는 마지막 낱말 뒤에 무엇이 오든 전부 엽니다. 기기전역 칸은 다릅니다 — 행위를 명령 경로 없이 낱말 그대로 다 적은 행만 판단 없이 열고, 그 밖의 행위는 판단 호출이 행의 형태와 사유에 비추어 열지 정합니다 — 행을 두지 않으면 그 행위는 승인 대기로 갑니다"
check "거부 근거: 형태=terraform -chdir=infra apply 는 같은 철자의 행위와도 맞지 않는다" \
  "$(probe_row '형태=terraform -chdir=infra apply | 사유=a' 'terraform -chdir=infra apply -auto-approve')" "0"
check "거부 근거: 형태=/usr/bin/gh pr 는 같은 철자의 행위와도 맞지 않는다" \
  "$(probe_row '형태=/usr/bin/gh pr | 사유=a' '/usr/bin/gh pr view 1')" "0"
# 안내된 철자는 뗀 경로를 열고, 러너가 아닌 명령이면 그 마지막 낱말 뒤의 `-x=y` 낱말도
# 열지만, 그 앞에 끼어든 `-x=y` 낱말이 있는 행위는 열지 않는다(대조기가 범위 안에서
# 떨어진 낱말을 불일치로 본다). 아래 셋은 모두 러너가 아닌 명령이다.
for p in 'gh pr|/usr/bin/gh pr view 1|1' 'gh pr|gh pr view 1 --repo=o/r|1' \
         'terraform apply|terraform -chdir=infra apply -auto-approve|0'; do
  pf=${p%%|*}; pa=${p#*|}; pw=${pa##*|}; pa=${pa%|*}
  o=$(kf "[Nharu/cc-cmds]
act-allow = 형태=$pf | 사유=a" $T)
  check "안내된 철자 '$pf' 는 적용되고 대조기에서 '$pa' 와 일치 $pw" \
    "$(st "$o" act-allow)|$(probe_row "$(col "$o" act-allow 4)" "$pa")" "적용|$pw"
done

# ---------------------------------------------------------------------------
# 어휘 원천 — 수락·거부가 run.sh 의 리터럴과 맞는다
# ---------------------------------------------------------------------------
lit() { sed -n "s/^readonly $1=\"\\(.*\\)\"\$/\\1/p" "$DRIVER" | sed -n 1p; }
L_CUT=$(lit CUTPOINTS); L_REV=$(lit REVIEW_POLICIES)
L_JC=$(lit JUDGMENT_CLASSES); L_JF=$(lit JUDGMENT_CLASSES_FORBIDDEN)
if [ -z "$L_CUT" ] || [ -z "$L_REV" ] || [ -z "$L_JC" ] || [ -z "$L_JF" ]; then
  bad "어휘 원천" "run.sh 에서 네 리터럴을 읽지 못했다 — 아래가 공허해진다"
else
  ok "run.sh 에서 네 어휘 리터럴을 읽었다"
fi
for c in $L_CUT; do check "어휘 원천: 절단점 $c 수락" "$(st "$(kf "[Nharu/cc-cmds]
cutpoint = $c" $T)" cutpoint)" "적용"; done
for c in $L_REV; do check "어휘 원천: 리뷰 정책 $c 수락" "$(st "$(kf "[Nharu/cc-cmds]
cutpoint = 머지
review-ceiling = $c" $T)" review-ceiling)" "적용"; done
for c in $L_JC; do
  want=적용
  case " $L_JF " in *" $c "*) want='금지 부류' ;; esac
  check "어휘 원천: 판단 부류 $c → $want" "$(kv run auto-adopt "판단 부류=$c | 상한=1 | 심각도 상한=minor | 사유=a")" "$want"
done
out=$(CC_CMDS_AUTOPILOT_DEFAULTS_FILE=off CC_CMDS_AUTOPILOT_DEFAULT_LADDER=4 kd --now "$NOW" $T)
check "모르는 접두 환경변수는 모르는 환경변수" "$(st "$out" CC_CMDS_AUTOPILOT_DEFAULT_LADDER)" "모르는 환경변수"
check "모르는 환경변수의 값은 읽지 않는다" "$(col "$out" CC_CMDS_AUTOPILOT_DEFAULT_LADDER 4)" ""

# ---------------------------------------------------------------------------
# 비용 문법 표류 — 보조가 받는 값 ⊆ 게이트가 받는 값, 0 은 보조만 거부
# ---------------------------------------------------------------------------
SAMPLES='120 .5 50.5 0 00 0.0 5. $50 1e3 1.2.3 abc 007 -5 1,000 100.25'
gate_accepts=$(CC_ORCH_SOURCE_ONLY=1 CC_GATE_SOURCE_ONLY=1 \
  bash -c 'g="$1"; s="$2"; set --; . "$g" >/dev/null 2>&1; set +e
    command -v gate_cost_figure_ok >/dev/null 2>&1 || { echo NOFN; exit 0; }
    for x in $s; do gate_cost_figure_ok "$x" && printf "%s " "$x"; done' _ "$GATE_SH" "$SAMPLES" 2>/dev/null)
if [ "$gate_accepts" = "NOFN" ] || [ -z "$gate_accepts" ]; then
  bad "비용 문법 표류" "게이트에서 gate_cost_figure_ok 를 들이지 못했다"
else
  drift=''
  for x in $SAMPLES; do
    s=$(kv run cost-ceiling "$x")
    in_gate=0; case " $gate_accepts " in *" $x "*) in_gate=1 ;; esac
    if [ "$s" = "적용" ] && [ "$in_gate" = "0" ]; then drift="$drift $x(보조만 수락)"; fi
    if [ "$s" != "적용" ] && [ "$in_gate" = "1" ]; then
      case "$x" in *[1-9]*) drift="$drift $x(게이트만 수락)" ;; esac
    fi
  done
  check "보조가 받는 비용 값은 게이트도 받고, 갈리는 것은 0 값뿐이다" "$drift" ""
  case " $gate_accepts " in
    *" 0 "*) check "0 은 게이트가 받고 보조는 거부한다" "$(kv run cost-ceiling 0)" "형식 오류" ;;
    *) bad "비용 문법 표류" "게이트가 0 을 거부한다 — 보조의 0 거부 근거가 바뀌었다" ;;
  esac
fi

# ---------------------------------------------------------------------------
# 교차 판정
# ---------------------------------------------------------------------------
out=$(kf '[Nharu/cc-cmds]
cutpoint = PR
review-ceiling = 선리뷰후머지
deploy-triggers = branch:main' $T)
check "절단점 PR + 리뷰 상한 → 불활성" "$(st "$out" review-ceiling)" "불활성"
out=$(kf '[Nharu/cc-cmds]
cutpoint = 커밋
deploy-triggers = branch:main' $T)
check "branch: + 절단점 커밋 → 불활성" "$(st "$out" deploy-triggers)" "불활성"
out=$(kf '[Nharu/cc-cmds]
review-ceiling = 선리뷰후머지
terminal-cap = 3
deploy-triggers = branch:main
apply-probe = make probe' $T)
check "절단점 없음 + 리뷰 상한 → 절단점 미정" "$(st "$out" review-ceiling)" "절단점 미정"
check "절단점 없음 + 말단 상한 → 절단점 미정" "$(st "$out" terminal-cap)" "절단점 미정"
check "절단점 없음 + branch 트리거 → 절단점 미정" "$(st "$out" deploy-triggers)" "절단점 미정"
check "절단점 없음 + 적용 프로브 → 절단점 미정" "$(st "$out" apply-probe)" "절단점 미정"
DEP='[Nharu/cc-cmds]
cutpoint = 배포
review-ceiling = 리뷰없음
apply-probe = make probe
apply-actor = 사람'
out=$(kf "$DEP" $T --apply-actor 파이프라인)
check "리뷰없음 + --apply-actor 파이프라인 → 충돌" "$(st "$out" review-ceiling)" "충돌"
check "apply-actor ≠ --apply-actor → 인터뷰 답과 다름" "$(st "$out" apply-actor)" "인터뷰 답과 다름"
check "그때 apply-probe 는 적용" "$(st "$out" apply-probe)" "적용"
out=$(kf "$DEP" $T --apply-actor 없음)
check "--apply-actor 없음 → apply-probe 인터뷰 답과 다름" "$(st "$out" apply-probe)" "인터뷰 답과 다름"
check "--apply-actor 없음 → apply-actor 인터뷰 답과 다름" "$(st "$out" apply-actor)" "인터뷰 답과 다름"
out=$(kf "$DEP" $T)
check "--apply-actor 인자 없음(5j 미실행) → apply-actor 적용" "$(st "$out" apply-actor)" "적용"
check "--apply-actor 인자 없음 → apply-probe 적용" "$(st "$out" apply-probe)" "적용"
check "--apply-actor 인자 없음 + 사람 → 리뷰없음 적용" "$(st "$out" review-ceiling)" "적용"
out=$(kf '[Nharu/cc-cmds]
cutpoint = 머지
apply-probe = make probe' $T)
check "절단점이 배포가 아니면 적용 키 불활성" "$(st "$out" apply-probe)" "불활성"
out=$(kf '[a/one]
cutpoint = 배포
apply-actor = 사람
[b/two]
cutpoint = 배포' --target a/one --target b/two)
check "배포 대상 둘 → 배포 대상 수" "$(st "$out" apply-actor)" "배포 대상 수"
# apply-probe-codes — `<불필요>/<필요>`, held to the manifest check's own value rule.
for pc in '0/21:적용' '0/2:적용' '3/0:적용' '125/0:적용' '0/1:형식 오류' '1/0:형식 오류' '0/126:형식 오류' \
          '0/128:형식 오류' '2/2:형식 오류' '0/021:형식 오류' '0:형식 오류' '0/2/3:형식 오류' '/2:형식 오류' 'x/2:형식 오류'; do
  out=$(kf "[Nharu/cc-cmds]
cutpoint = 배포
apply-probe = make probe
apply-probe-codes = ${pc%%:*}" $T)
  check "apply-probe-codes '${pc%%:*}' → ${pc#*:}" "$(st "$out" apply-probe-codes)" "${pc#*:}"
done
out=$(kf '[Nharu/cc-cmds]
cutpoint = 머지
apply-probe-codes = 0/21' $T)
check "절단점이 배포가 아니면 apply-probe-codes 도 불활성" "$(st "$out" apply-probe-codes)" "불활성"
out=$(kf '[Nharu/cc-cmds]
cutpoint = 배포
apply-probe-codes = 0/21' $T --apply-actor 없음)
check "--apply-actor 없음 → apply-probe-codes 인터뷰 답과 다름" "$(st "$out" apply-probe-codes)" "인터뷰 답과 다름"

# ---------------------------------------------------------------------------
# 다중 대상
# ---------------------------------------------------------------------------
out=$(kf '[a/one]
act-allow = 형태=gh pr | 사유=첫째
act-allow = 형태=make lint | 사유=x
[b/two]
act-allow = 형태=gh pr | 사유=둘째' --target a/one --target b/two)
check "두 대상 공통 형태는 한 행으로 적용" "$(printf '%s\n' "$out" | awk -F'\t' '$1=="적용" && $3=="act-allow"' | grep -c . || true)" "1"
check "그 행은 첫 대상의 사유를 싣는다" "$(col "$out" act-allow 4)" "형태=gh pr | 사유=첫째"
case "$(col "$out" act-allow 7)" in
  *'사유가 대상마다 다릅니다'*) ok "사유가 다르면 고지가 붙는다" ;;
  *) bad "사유가 다르면 고지가 붙는다" "$(col "$out" act-allow 7)" ;;
esac
check "한쪽에만 있는 형태는 일부 대상만" "$(st "$out" act-allow 2)" "일부 대상만"

# ---------------------------------------------------------------------------
# 환경변수
# ---------------------------------------------------------------------------
out=$(CC_CMDS_AUTOPILOT_DEFAULT_LADDER_RUNGS=2 kf 'ladder-rungs = 4' $T)
check "유효 환경변수가 파일을 이긴다 (한 행)" "$(printf '%s\n' "$out" | awk -F'\t' '$3=="ladder-rungs"' | grep -c . || true)" "1"
check "그 행은 환경변수 값이다" "$(col "$out" ladder-rungs 4)|$(col "$out" ladder-rungs 5)" "2|환경:CC_CMDS_AUTOPILOT_DEFAULT_LADDER_RUNGS"
out=$(CC_CMDS_AUTOPILOT_DEFAULT_LADDER_RUNGS=3 kf 'ladder-rungs = 4' $T)
check "무효 환경변수는 변수 행이 무시" "$(st "$out" ladder-rungs 2)" "어휘 밖"
check "무효 환경변수면 파일 값도 환경변수 무효" "$(st "$out" ladder-rungs 1)" "환경변수 무효"
out=$(CC_CMDS_AUTOPILOT_DEFAULT_LADDER_RUNGS= kf 'ladder-rungs = 4' $T)
check "빈 문자열은 미설정" "$(col "$out" ladder-rungs 5)" "파일:1"
out=$(CC_CMDS_AUTOPILOT_DEFAULTS_FILE=off kd --now "$NOW" $T)
check "DEFAULTS_FILE=off → 원천 off" "$(printf '%s\n' "$out" | awk -F'\t' '$1=="원천"{print $2}')" "off"
printf 'ladder-rungs = 4\n' > "$HOME/.config/cc-cmds/autopilot-defaults"
out=$(CC_CMDS_AUTOPILOT_DEFAULTS_FILE=rel/path kd --now "$NOW" $T)
check "상대 경로 DEFAULTS_FILE → 원천 해석불가" "$(printf '%s\n' "$out" | awk -F'\t' '$1=="원천"{print $2}')" "해석불가"
check "그 변수는 형식 오류" "$(st "$out" CC_CMDS_AUTOPILOT_DEFAULTS_FILE)" "형식 오류"
check "기본 경로로 물러서지 않는다" "$(st "$out" ladder-rungs)" "없음"
rm -f "$HOME/.config/cc-cmds/autopilot-defaults"

# ---------------------------------------------------------------------------
# 마감 — 문법 갈래, 서울·UTC·뉴욕, 일광절약
# ---------------------------------------------------------------------------
DL_RE='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(Z|[+-][0-9]{2}:[0-9]{2})$'
# `dl` runs inside $(…), so the applied values are collected in a file.
ALL_DL_F="$WORK/applied-deadlines"; : > "$ALL_DL_F"
dl() {   # dl <TZ> <now> <value> → applied value or reason token
  local o
  o=$(TZ="$1" CC_CMDS_AUTOPILOT_DEFAULTS_FILE=off CC_CMDS_AUTOPILOT_DEFAULT_DEADLINE="$3" kd --now "$2" $T)
  if [ "$(st "$o" deadline)" = "적용" ]; then
    col "$o" deadline 4 >> "$ALL_DL_F"
    col "$o" deadline 4
  else
    st "$o" deadline
  fi
}
check "+Nh"            "$(dl Asia/Seoul "$NOW" '+8h')"          "2026-09-22T07:13:20+09:00"
check "+NhMm"          "$(dl Asia/Seoul "$NOW" '+2h30m')"       "2026-09-22T01:43:20+09:00"
check "+Mm"            "$(dl Asia/Seoul "$NOW" '+90m')"         "2026-09-22T00:43:20+09:00"
check "HH:MM 은 다음 도래"  "$(dl Asia/Seoul "$NOW" '07:00')"   "2026-09-22T07:00:00+09:00"
check "+Dd HH:MM"      "$(dl Asia/Seoul "$NOW" '+1d 09:00')"    "2026-09-22T09:00:00+09:00"
check "다음 날 HH:MM"  "$(dl Asia/Seoul "$NOW" '다음 날 09:00')" "2026-09-22T09:00:00+09:00"
check "다음날 HH:MM"   "$(dl Asia/Seoul "$NOW" '다음날 09:00')"  "2026-09-22T09:00:00+09:00"
check "절대값"          "$(dl Asia/Seoul "$NOW" '2026-09-23T09:00:00+09:00')" "2026-09-23T09:00:00+09:00"
check "UTC 의 HH:MM"   "$(dl UTC "$NOW" '10:00')"               "2026-09-22T10:00:00+00:00"
# 2026-10-30T12:00:00-04:00 — 지금은 EDT, 목표는 일광절약이 끝난 뒤의 EST.
NY_NOW=1793376000
check "뉴욕: 지금 EDT·목표 EST 는 -05:00" "$(dl America/New_York "$NY_NOW" '+3d 09:00')" "2026-11-02T09:00:00-05:00"
check "뉴욕: 같은 날은 -04:00" "$(dl America/New_York "$NY_NOW" '18:00')" "2026-10-30T18:00:00-04:00"
# 2027-03-13T12:00:00-05:00 — 다음 날 02:30 은 일광절약 공백 안이다.
GAP_NOW=1804957200
check "공백 시각 → 시각 없음 (다음 날)" "$(dl America/New_York "$GAP_NOW" '다음 날 02:30')" "시각 없음"
check "공백 시각 → 시각 없음 (HH:MM)" "$(dl America/New_York "$GAP_NOW" '02:30')" "시각 없음"
check "과거 절대값 → 과거 시각" "$(dl Asia/Seoul "$NOW" '2020-01-01T00:00:00+09:00')" "과거 시각"
check "오늘 지난 시각 → 과거 시각" "$(dl Asia/Seoul "$NOW" '+0d 09:00')" "과거 시각"
check "+30d 09:00 → 범위 초과" "$(dl Asia/Seoul "$NOW" '+30d 09:00')" "범위 초과"
check "+169h → 범위 초과" "$(dl Asia/Seoul "$NOW" '+169h')" "범위 초과"
check "절대값 Z → 형식 오류" "$(dl Asia/Seoul "$NOW" '2026-09-23T09:00:00Z')" "형식 오류"
check "모르는 형태 → 형식 오류" "$(dl Asia/Seoul "$NOW" 'tomorrow')" "형식 오류"
nonconf=''
ALL_DL=$(cat "$ALL_DL_F")
for v in $ALL_DL; do printf '%s\n' "$v" | grep -E "$DL_RE" >/dev/null || nonconf="$nonconf $v"; done
if [ "$(printf '%s\n' "$ALL_DL" | grep -c . || true)" -lt 10 ]; then bad "마감 정규식" "적용된 마감이 하나도 없다"; else check "모든 적용 마감이 매니페스트 검사의 정규식에 맞는다" "$nonconf" ""; fi
check "--check-deadline 지남" "$(kd --check-deadline 2026-09-21T23:00:00+09:00 --now "$NOW")" "지남"
check "--check-deadline 남음" "$(kd --check-deadline 2026-09-21T23:30:00+09:00 --now "$NOW")" "남음"
check "--check-deadline 은 머리 줄 없이 한 줄" "$(kd --check-deadline 2026-09-21T23:30:00+09:00 --now "$NOW" | grep -c . || true)" "1"
check "--check-deadline 형식이 틀리면 2" "$(kd --check-deadline 2026-09-21T23:30:00Z >/dev/null 2>&1; echo $?)" "2"
check "--check-deadline 도 런 안에서는 3" "$(CC_PIPELINE_RUN_ID=x "$BASH" "$HELPER" --check-deadline 2026-09-21T23:30:00+09:00 >/dev/null 2>&1; echo $?)" "3"

# ---------------------------------------------------------------------------
# 상대 마감 해석기 — deadline-resolve.sh 로 뽑아낸 뒤에도 같은 절대값을 내고, 길이는
# 「풀린 마감 − 푼 순간」이다. 매니페스트 검사가 같은 산식으로 얼린 길이를 읽는다.
# ---------------------------------------------------------------------------
RESOLVER="$ORCH/deadline-resolve.sh"
rd() { TZ="${2:-Asia/Seoul}" kd --resolve-deadline "$1" --now "${3:-$NOW}"; }
check "--resolve-deadline +8h 는 절대값·종류·길이 네 칸" "$(rd '+8h')" "ok	2026-09-22T07:13:20+09:00	상대	PT8H0M0S"
check "--resolve-deadline 절대값의 길이는 그 시각 − 지금" "$(rd '2026-09-23T09:00:00+09:00')" "ok	2026-09-23T09:00:00+09:00	절대	PT33H46M40S"
check "--resolve-deadline +1d 09:00 의 길이" "$(rd '+1d 09:00' | cut -f4)" "PT9H46M40S"
check "--resolve-deadline 오류는 사유 토큰" "$(rd 'tomorrow' | cut -f1)" "형식 오류"
check "--resolve-deadline 도 런 안에서는 3" "$(CC_PIPELINE_RUN_ID=x "$BASH" "$HELPER" --resolve-deadline '+8h' >/dev/null 2>&1; echo $?)" "3"
check "--resolve-deadline 은 --target 과 함께 쓰지 않는다" "$(kd --resolve-deadline '+8h' $T >/dev/null 2>&1; echo $?)" "2"
# 뽑아내기 전과 같은 값 — 기본값 화면의 적용 값과 해석기의 둘째 칸이 형태마다 같다.
same_dl=''
for v in '+8h' '+2h30m' '+90m' '07:00' '+1d 09:00' '다음 날 09:00' '2026-09-23T09:00:00+09:00'; do
  a=$(dl Asia/Seoul "$NOW" "$v"); b=$(rd "$v" | cut -f2)
  [ "$a" = "$b" ] || same_dl="$same_dl [$v: ${a}≠$b]"
done
check "해석기가 기본값 화면과 같은 절대값을 낸다" "$same_dl" ""
a=$(dl America/New_York "$NY_NOW" '+3d 09:00'); b=$(rd '+3d 09:00' America/New_York "$NY_NOW" | cut -f2)
check "해석기: 뉴욕 일광절약 경계도 같다" "$b" "$a"
check "해석기: 공백 시각은 시각 없음" "$(rd '02:30' America/New_York "$GAP_NOW" | cut -f1)" "시각 없음"
# 길이 = 풀린 마감 − 푼 순간 — 해석기 자신의 두 함수로 되짚는다.
len_ok=''
for v in '+8h' '07:00' '+1d 09:00' '2026-09-23T09:00:00+09:00'; do
  line=$(rd "$v")
  e=$(bash -c '. "$1"; dr_abs_epoch "$2"' _ "$RESOLVER" "$(printf '%s' "$line" | cut -f2)")
  n=$(bash -c '. "$1"; dr_duration_seconds "$2"' _ "$RESOLVER" "$(printf '%s' "$line" | cut -f4)")
  [ -n "$e" ] && [ -n "$n" ] && [ "$((e - NOW))" = "$n" ] || len_ok="$len_ok [$v]"
done
check "길이가 풀린 마감 − 푼 순간이다" "$len_ok" ""
dr() { bash -c '. "$1"; shift; "$@"' _ "$RESOLVER" "$@"; }
check "dr_abs_epoch 는 Z 를 받는다" "$(dr dr_abs_epoch 2026-09-21T14:13:20Z)" "$NOW"
check "dr_abs_epoch 는 오프셋을 받는다" "$(dr dr_abs_epoch 2026-09-21T23:13:20+09:00)" "$NOW"
check "dr_abs_epoch 는 음의 오프셋을 받는다" "$(dr dr_abs_epoch 2026-09-21T10:13:20-04:00)" "$NOW"
check "dr_abs_epoch 는 형태가 틀리면 1" "$(dr dr_abs_epoch 2026-09-21 >/dev/null 2>&1; echo $?)" "1"
check "dr_duration_seconds PT8H0M0S" "$(dr dr_duration_seconds PT8H0M0S)" "28800"
check "dr_duration_seconds P1DT2H" "$(dr dr_duration_seconds P1DT2H)" "93600"
check "dr_duration_seconds 는 빈 기간을 받지 않는다" "$(dr dr_duration_seconds PT >/dev/null 2>&1; echo $?)" "1"
check "dr_duration_seconds 는 8h 를 받지 않는다" "$(dr dr_duration_seconds 8h >/dev/null 2>&1; echo $?)" "1"
check "dr_add_duration 은 그 오프셋 표기로 되돌린다" "$(dr dr_add_duration 2026-09-21T14:13:20Z PT8H0M0S +09:00)" "2026-09-22T07:13:20+09:00"
check "dr_add_duration 은 TZ 와 무관하다" "$(TZ=America/New_York dr dr_add_duration 2026-09-21T14:13:20Z PT8H0M0S +09:00)" "2026-09-22T07:13:20+09:00"
check "dr_add_duration 음의 오프셋" "$(dr dr_add_duration 2026-10-30T16:00:00Z PT1H0M0S -04:00)" "2026-10-30T13:00:00-04:00"
check "dr_add_duration 은 오프셋 형태가 틀리면 1" "$(dr dr_add_duration 2026-09-21T14:13:20Z PT8H0M0S Z >/dev/null 2>&1; echo $?)" "1"
# 해석기는 기본값을 열지 않는다 — run.sh 가 이 파일을 소싱해도 린트 규칙 1 에 걸리지 않는다.
check "해석기가 기본값 이름을 담지 않는다" "$(grep -cE 'autopilot-defaults|kickoff-defaults\.sh|CC_CMDS_AUTOPILOT_DEFAULT' "$RESOLVER" || true)" "0"
check "해석기를 소싱해도 아무것도 출력하지 않는다" "$(bash -c '. "$1"' _ "$RESOLVER" 2>&1)" ""

# TZ 배관 — 설정되지 않은 TZ 는 설정되지 않은 채 jq 에 닿아야 한다. libc 는 빈 TZ 를
# UTC 로 읽으므로, 빈 값으로 바꿔 넘기면 시스템 zone 이 UTC 가 아닌 호스트에서
# 벽시계 마감이 그만큼 어긋난다. 시스템 zone 이 UTC 인 CI 에서는 두 경우의 시각이
# 같으므로, 시각이 아니라 jq 가 받은 환경을 jq 대역으로 기록해 단언한다. 대역은
# PATH 의 파일이 아니라 내보낸 셸 함수다 — 보조가 들이는 run.sh 가 PATH 앞에
# /usr/bin 을 붙여, 파일 대역은 시스템 jq 에 가려진다. 함수는 PATH 조회보다 먼저다.
JQ_LOG="$WORK/jq-tz.log"
jq_tz_probe() {   # jq_tz_probe <TZ 미설정이면 -> → TZ as jq saw it, one line per call
  : > "$JQ_LOG"
  (
    if [ "$1" = "-" ]; then unset TZ; else TZ="$1"; export TZ; fi
    jq() { printf '%s\n' "${TZ+set:$TZ}" >> "$JQ_LOG"; command jq "$@"; }
    export -f jq
    export JQ_LOG
    CC_CMDS_AUTOPILOT_DEFAULTS_FILE=off CC_CMDS_AUTOPILOT_DEFAULT_DEADLINE='07:00' kd --now "$NOW" $T
  ) > "$WORK/jq-tz.out"
}
jq_tz_probe -
check "TZ 미설정: 마감은 적용된다" "$(st "$(cat "$WORK/jq-tz.out")" deadline)" "적용"
check "TZ 미설정: jq 대역이 한 번 이상 불렸다" "$([ -s "$JQ_LOG" ] && echo 예 || echo 아니오)" "예"
check "TZ 미설정: jq 에 TZ 가 설정되지 않은 채 닿는다" "$(grep -c '^set:' "$JQ_LOG" || true)" "0"
jq_tz_probe America/New_York
check "TZ 설정: jq 에 그 값이 그대로 닿는다" "$(sort -u "$JQ_LOG")" "set:America/New_York"

# ---------------------------------------------------------------------------
# 권한 확대
# ---------------------------------------------------------------------------
wide() { col "$(kf "$1" $T ${3:-})" "$2" 6; }
check "auto-adopt → 1" "$(wide 'auto-adopt = 판단 부류=감사-발견 | 상한=1 | 심각도 상한=minor | 사유=a' auto-adopt)" "1"
check "act-allow → 1" "$(wide '[Nharu/cc-cmds]
act-allow = 형태=gh pr | 사유=a' act-allow)" "1"
check "절단점 push → 1" "$(wide '[Nharu/cc-cmds]
cutpoint = push' cutpoint)" "1"
check "절단점 브랜치 → 0" "$(wide '[Nharu/cc-cmds]
cutpoint = 브랜치' cutpoint)" "0"
check "리뷰 상한 선머지후리뷰 → 1" "$(wide '[Nharu/cc-cmds]
cutpoint = 머지
review-ceiling = 선머지후리뷰' review-ceiling)" "1"
check "리뷰 상한 리뷰없음 → 1" "$(wide '[Nharu/cc-cmds]
cutpoint = 머지
review-ceiling = 리뷰없음' review-ceiling)" "1"
check "리뷰 상한 선리뷰후머지 → 0" "$(wide '[Nharu/cc-cmds]
cutpoint = 머지
review-ceiling = 선리뷰후머지' review-ceiling)" "0"
check "말단 상한 없음 + 절단점 머지 → 1" "$(wide '[Nharu/cc-cmds]
cutpoint = 머지
terminal-cap = 없음' terminal-cap)" "1"
check "말단 상한 없음 + 절단점 PR → 0" "$(wide '[Nharu/cc-cmds]
cutpoint = PR
terminal-cap = 없음' terminal-cap)" "0"
check "말단 상한 3 → 0" "$(wide '[Nharu/cc-cmds]
cutpoint = 머지
terminal-cap = 3' terminal-cap)" "0"
check "apply-actor 파이프라인 → 1" "$(wide '[Nharu/cc-cmds]
cutpoint = 배포
apply-actor = 파이프라인' apply-actor)" "1"
check "apply-actor 사람 → 0" "$(wide '[Nharu/cc-cmds]
cutpoint = 배포
apply-actor = 사람' apply-actor)" "0"
check "ladder-rungs → 0" "$(wide 'ladder-rungs = 4' ladder-rungs)" "0"
check "cost-ceiling → 0" "$(wide 'cost-ceiling = 120' cost-ceiling)" "0"
runner() { case "$(col "$(kf "[Nharu/cc-cmds]
act-allow = 형태=$1 | 사유=a" $T)" act-allow 7)" in *'러너 형태'*) echo 예 ;; *) echo 아니오 ;; esac; }
check "형태=npm run 은 러너 형태" "$(runner 'npm run')" "예"
check "형태=go run 은 러너 형태" "$(runner 'go run')" "예"
check "형태=gh pr 은 러너 형태가 아니다" "$(runner 'gh pr')" "아니오"
# 인터프리터 형태는 스크립트 낱말이 실재하고 그 앞이 모두 닫힌 플래그일 때만 완전하다.
# 코드 문자열·모듈·표준 입력, 값을 받는 옵션 뒤의 코드 플래그는 길이와 상관없이 러너다.
for p in 'bash scripts/x.sh|아니오' 'bash -x scripts/x.sh|아니오' 'bash -c x y|예' \
         'python3 -m pip install|예' 'bash /dev/stdin|예' 'sh -s|예' 'node -e|예' \
         'bash -o pipefail -c echo|예' 'python3 -W ignore -c x|예' 'node -r x -e y|예' \
         'bash --norc scripts/x.sh a|예' 'bash scripts/x.sh -c|아니오' \
         'bash +e scripts/x.sh|예' 'bash +e -c x|예'; do
  check "형태=${p%|*} 의 러너 판정" "$(runner "${p%|*}")" "${p#*|}"
done
# 거부 사유가 말하는 대로, 완전한 형태는 기기전역 칸 밖에서 마지막 낱말 뒤에 무엇이
# 오든 그 낱말들로 시작하는 행위를 연다 — 러너의 꼬리도 대조기가 막지 않는다.
match_rc() {   # match_rc <shape> <argv> → the matcher's exit status outside the probe
  printf -- '- `사전 인가` | 형태=%s | 사유=a\n' "$1" > "$WORK/preauth.md"
  env GATE_MARK= GATE_MARK_TRIGGER= GATE_DESTRUCTIVE=0 GATE_REACH_EFF= GATE_PREAUTH_PROBE=0 \
    GATE_KIND=exec GATE_SURFACE=외부상태변경 GATE_ARGV="$2" GATE_MANIFEST="$WORK/preauth.md" \
    sh "$MATCHER" >/dev/null 2>&1
  echo $?
}
for p in 'npm run deploy|npm run deploy --script-shell x' 'make deploy ENV=dev|make deploy ENV=dev ENV=prod' \
         'make deploy ENV=dev|make deploy ENV=dev -- ENV=prod' 'make deploy ENV=prod|make deploy ENV=prod -f x.mk'; do
  check "형태=${p%%|*} 는 '${p#*|}' 를 연다" "$(match_rc "${p%%|*}" "${p#*|}")" "0"
done
# 러너 판정은 대조기의 판정과 같아야 한다 — 같은 형태를 행으로 두고 그 형태 자체를
# 행위로 탐침했을 때, 러너라고 말한 형태만 `형태=완전` 이 아니다.
probe_form() {   # probe_form <shape> → the probe's 형태= field
  printf -- '- `사전 인가` | 형태=%s | 사유=a\n' "$1" > "$WORK/preauth.md"
  GATE_PREAUTH_PROBE=1 GATE_MANIFEST="$WORK/preauth.md" GATE_ARGV="$1" sh "$MATCHER" 2>/dev/null \
    | sed -n 's/^.*형태=\([^ ]*\).*$/\1/p'
}
for s in 'npm run' 'go run' 'gh pr' 'bash scripts/x.sh' 'bash -x scripts/x.sh' 'bash -c x y' \
         'python3 -m pip install' 'bash /dev/stdin' 'sh -s' 'node -e' 'bash -o pipefail -c echo' \
         'python3 -W ignore -c x' 'node -r x -e y' 'bash --norc scripts/x.sh a' 'bash scripts/x.sh -c' \
         'bash +e' 'bash +e -c x' 'bash +e scripts/x.sh'; do
  f=$(probe_form "$s")
  case "$(runner "$s"):$f" in
    예:완전|아니오:러너|아니오:없음|*:) bad "형태=$s 의 러너 판정이 대조기의 형태 판정과 같다" "러너=$(runner "$s") 형태=$f" ;;
    *) ok "형태=$s 의 러너 판정이 대조기의 형태 판정과 같다" ;;
  esac
done
# 판정의 사본은 규칙 함수와 본문 바이트가 같다(함수 이름 줄 다음부터 닫는 중괄호까지).
fn_body() { awk -v n="$2" '$0 ~ "^"n"\\(\\) \\{" { on = 1; next } on && /^}/ { exit } on' "$1"; }
kd_body=$(fn_body "$HELPER" kd_closed_flags_only)
rule_body=$(fn_body "$MATCHER" closed_flags_only)
if [ -n "$kd_body" ] && [ "$kd_body" = "$rule_body" ]; then
  ok "kd_closed_flags_only 의 본문이 규칙의 closed_flags_only 와 바이트로 같다"
else
  bad "kd_closed_flags_only 의 본문이 규칙의 closed_flags_only 와 바이트로 같다" "사본 ${#kd_body}바이트, 규칙 ${#rule_body}바이트"
fi
# 두 낱말을 넘는 러너 형태는 대조기의 러너 갈래가 앞 한두 낱말만 맞추므로 어떤 행위와도
# 맞지 않는다 — 효과 줄이 그렇게 말한다.
for s in 'bash -c x y' 'python3 -m pip install'; do
  case "$(col "$(kf "[Nharu/cc-cmds]
act-allow = 형태=$s | 사유=a" $T)" act-allow 7)" in
    *'러너 형태 — 이 행은 어떤 행위와도 일치하지 않는다'*) ok "형태=$s 의 효과 줄은 어떤 행위와도 맞지 않는다고 말한다" ;;
    *) bad "형태=$s 의 효과 줄은 어떤 행위와도 맞지 않는다고 말한다" "" ;;
  esac
done
eff=$(col "$(kf 'cost-ceiling = 120' $T)" cost-ceiling 7)
check "비용 천장 효과 줄" "$eff" "96 USD 에서 승인을 열고 기다리며, 120 USD 에서 묻지 않고 런을 끝냅니다"
# 게이트는 자동 채택 행을 부류로만 맞추고 두 상한 칸을 읽지 않는다 — 효과 줄이
# 상한을 한도처럼 보이면, 확인 화면에서 좁혀진 답이 집행에서 넓어진다.
eff=$(col "$(kf 'auto-adopt = 판단 부류=감사-발견 | 상한=1 | 심각도 상한=minor | 사유=a' $T)" auto-adopt 7)
check "자동 채택 효과 줄은 상한이 집행되지 않는다고 말한다" "$eff" \
  "감사-발견 부류의 판단을 개수·심각도 제한 없이 사람 없이 채택합니다 — 상한=1 · 심각도 상한=minor 는 매니페스트에 기록만 되고 게이트가 집행하지 않습니다"

# ---------------------------------------------------------------------------
# 매니페스트 성질 — 「적용」 값으로 만든 매니페스트가 check_manifest 를 통과하고,
# 고정 오류 벡터는 보조와 check_manifest·gate_cost_figure_ok 가 모두 거부한다.
# ---------------------------------------------------------------------------
MFW="$WORK/mf"; mkdir -p "$MFW"
MF_REPO="$MFW/repo"; mkdir -p "$MF_REPO"
( cd "$MF_REPO" \
  && git init -q . \
  && git config user.email t@example.invalid \
  && git config user.name T \
  && git commit -q --allow-empty --no-gpg-sign -m init \
  && git branch -M main \
  && git update-ref refs/remotes/origin/main HEAD ) >/dev/null 2>&1
MF_CG=$(cd "$MF_REPO" && git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
HERE=$(cd "$repo_root" && git rev-parse --show-toplevel 2>/dev/null)

out=$(kf 'ladder-rungs = 2
stagnation-bound = 6
cost-ceiling = 50.5
deadline = +8h
auto-adopt = 판단 부류=감사-발견  | 상한=없음 | 심각도 상한=major | 사유=a
[Nharu/cc-cmds]
cutpoint = 머지
terminal-cap = 없음
dev-ids = aws-profile:dev, aws-account:123456789012, dir:/srv/x
deploy-triggers = branch:release, argv:bash scripts/deploy.sh
act-allow = 형태=gh pr  | 사유=리뷰' $T)
A_AA=$(col "$out" auto-adopt 4); A_PA=$(col "$out" act-allow 4)
[ "$(st "$out" auto-adopt)|$(st "$out" act-allow)" = "적용|적용" ] \
  || bad "매니페스트 성질" "픽스처의 auto-adopt·act-allow 가 적용되지 않았다"
# Every applied list row is frozen as the row Step 6 writes, byte for byte.
MF_ROWS=$(printf -- '- `자동 채택` | %s\n- `사전 인가` | %s' "$A_AA" "$A_PA")
A_CUT=$(col "$out" cutpoint 4); A_CAP=$(col "$out" terminal-cap 4)
A_DEV=$(col "$out" dev-ids 4); A_DEP=$(col "$out" deploy-triggers 4)
A_DL=$(col "$out" deadline 4); A_LAD=$(col "$out" ladder-rungs 4)
A_CC=$(col "$out" cost-ceiling 4); A_SB=$(col "$out" stagnation-bound 4)
if [ -z "$A_CUT$A_DEV$A_DEP$A_DL" ] || [ -z "$MF_CG" ] || [ -z "$HERE" ]; then
  bad "매니페스트 성질" "픽스처를 세우지 못했다 (적용 값 또는 픽스처 레포가 비었다)"
fi

# mf_write <out> <extra target fields> <deadline> <cost ceiling> <binding digest>
mf_write() {
  local trow="- \`target\` | 별칭=home | 메인 워크트리=$MF_REPO | 공통 git 디렉터리=$MF_CG | 베이스 브랜치=main | 홈=예 | 원격 슬러그=Nharu/cc-cmds | 절단점=$A_CUT | 말단 행위 상한=$A_CAP$2"
  local tdig
  tdig=$(printf '%s\n' "$trow" | sed 's/[[:space:]]\{1,\}/ /g' | sort | shasum -a 256 | cut -d' ' -f1)
  {
    printf '# 파이프라인 런 매니페스트 — 20261001-feedbeef\n'
    printf '<!-- cc-run-manifest v1; writer=autopilot; reader=orchestrator; run-id=20261001-feedbeef;\n'
    printf '     anchor-kind=repo; anchor-key=Nharu/cc-cmds;\n'
    printf '     owner-doc=(없음); origin-worktree=%s;\n' "$HERE"
    printf '     NOT a design doc; mechanism-local, never staged by a skill -->\n\n'
    printf '## 런 정체\n**킥오프 일시**: 2026-10-01T00:00:00Z\n**런 id**: 20261001-feedbeef\n'
    printf '**앵커 종류**: repo\n**앵커 키**: Nharu/cc-cmds\n**사용자 확인 문면**: 돌려라\n\n'
    printf '## 대상\n**대상 맵 다이제스트**: %s\n%s\n\n' "$tdig" "$trow"
    printf '## 요소\n**설계 문서**: (없음)\n**적용 주체**: (해당 없음)\n\n'
    printf '## 실행 계획\n**승인 문면**: 진행\n'
    printf '```json\n{ "steps": ["audit", "implement"] }\n```\n\n'
    printf '## 인가\n**런 최대 절단점**: %s\n**종료 지점**: 전부 머지\n' "$A_CUT"
    printf '**벽시계 마감**: %s\n**시각 정합 마커**: 없음\n' "$3"
    [ -n "$4" ] && printf '**비용 천장**: %s\n' "$4"
    printf '**무진전 상한**: %s\n' "$A_SB"
    printf '**사다리 가용 단 수**: %s\n**미선언 상황 처분**: park\n' "$A_LAD"
    [ -n "$5" ] && printf '**구속 다이제스트**: %s\n' "$5"
    printf -- '- `종료 절` | id=C1 | 문면=슬라이스가 전부 머지됐다\n'
    [ -n "$MF_ROWS" ] && printf '%s\n' "$MF_ROWS"
  } > "$1"
}
# mf_run <extra> <deadline> <cost> → check_manifest's exit status (binding digest included)
mf_run() {
  local m="$MFW/manifest.md" bd
  mf_write "$m" "$1" "$2" "$3" ""
  # The driver initializes MANIFEST while it is sourced, so it is set afterwards.
  bd=$(cd "$repo_root" && CC_ORCH_SOURCE_ONLY=1 \
       bash -c 'd="$1"; m="$2"; set --; . "$d" >/dev/null 2>&1; set +e; MANIFEST="$m"; binding_set_bytes' _ "$DRIVER" "$m" 2>/dev/null \
       | shasum -a 256 | cut -d' ' -f1)
  mf_write "$m" "$1" "$2" "$3" "$bd"
  ( cd "$repo_root" && CC_ORCH_SOURCE_ONLY=1 \
    bash -c 'd="$1"; m="$2"; e="$3"; set --; . "$d" >/dev/null 2>&1; set +e; MANIFEST="$m"; ( check_manifest ) >/dev/null 2>"$e"' \
      _ "$DRIVER" "$m" "$MFW/check.err" )
}
mf_run " | dev 식별자=$A_DEV | 배포트리거 식별자=$A_DEP" "$A_DL" "$A_CC"; rc=$?
if [ "$rc" = "0" ]; then
  ok "적용 값만으로 만든 매니페스트가 check_manifest 를 통과한다"
else
  bad "적용 값만으로 만든 매니페스트가 check_manifest 를 통과한다" "rc=$rc: $(tail -1 "$MFW/check.err")"
fi
# 오류 벡터 — 보조가 무시하고 check_manifest 도 거부한다.
for vec in 'dev 식별자=aws-account:12345' 'dev 식별자=dir:relative/path'; do
  k=dev-ids; v="${vec#*=}"
  check "오류 벡터 '$v' 를 보조가 무시한다" "$(st "$(kf "[Nharu/cc-cmds]
$k = $v" $T)" "$k")" "형식 오류"
  mf_run " | $vec" "$A_DL" "$A_CC"; rc=$?
  if [ "$rc" != "0" ]; then ok "오류 벡터 '$v' 를 check_manifest 가 거부한다"; else bad "오류 벡터 '$v'" "check_manifest 가 통과시켰다"; fi
done
# 공백 변형 자동 채택 — 보조가 무시하는 철자를 그대로 얼리면 check_manifest 가 거부한다.
v='판단 부류= 감사-발견 | 상한=없음 | 심각도 상한=major | 사유=a'
check "오류 벡터 자동 채택 '$v' 를 보조가 무시한다" "$(kv run auto-adopt "$v")" "형식 오류"
MF_ROWS_SAVE="$MF_ROWS"; MF_ROWS="- \`자동 채택\` | $v"
mf_run " | dev 식별자=$A_DEV" "$A_DL" "$A_CC"; rc=$?
if [ "$rc" != "0" ]; then ok "오류 벡터 자동 채택 '$v' 를 check_manifest 가 거부한다"; else bad "오류 벡터 자동 채택 '$v'" "check_manifest 가 통과시켰다"; fi
MF_ROWS="$MF_ROWS_SAVE"
# The cost vectors pair with the gate, not with check_manifest: the manifest check
# does not read `비용 천장` at all, and the gate's consumer warns and declines to
# enforce a value that is not a number — so an unreadable ceiling silently
# becomes "no ceiling", and the helper is the one place it is refused in front of
# a person. The applied value is held to the same reader.
cost_gate() {
  CC_ORCH_SOURCE_ONLY=1 CC_GATE_SOURCE_ONLY=1 \
    bash -c 'g="$1"; x="$2"; set --; . "$g" >/dev/null 2>&1; set +e; gate_cost_figure_ok "$x" && echo 수락 || echo 거부' _ "$GATE_SH" "$1" 2>/dev/null
}
check "적용된 비용 천장 '$A_CC' 를 gate_cost_figure_ok 가 받는다" "$(cost_gate "$A_CC")" "수락"
for v in '$5' '5.'; do
  check "오류 벡터 비용 '$v' 를 보조가 무시한다" "$(kv run cost-ceiling "$v")" "형식 오류"
  check "오류 벡터 비용 '$v' 를 gate_cost_figure_ok 가 거부한다" "$(cost_gate "$v")" "거부"
done

# ---------------------------------------------------------------------------
# --carry — 이전 매니페스트를 답으로, 기본값 파일을 비교 대상으로만 읽는다
# ---------------------------------------------------------------------------
sha_of() { { shasum -a 256 "$1" 2>/dev/null || sha256sum "$1"; } | awk '{ print $1; exit }'; }
# cw_write <file> — 이전 런 매니페스트 픽스처. CW_* 변수가 칸을 정한다.
CW_KO='2026-10-09T03:00:00Z'; CW_DL='2026-10-09T12:00:00Z'; CW_CC=''; CW_SB='6'; CW_LAD='4'
CW_AUTH=1; CW_AP='(없음)'; CW_AA='(해당 없음)'
CW_TF=' | 리뷰 정책 상한=선리뷰후머지 | dev 식별자=aws-profile:dev | 배포트리거 식별자=branch:release'
CW_ROWS='- `사전 인가` | 형태=gh pr | 사유=리뷰
- `사전 인가` | 형태=git push | 사유=세그먼트 브랜치
- `사전 인가` | 인터뷰 기록=docs/pipeline-run/20261001-feedbeef.interview.md | sha256=0000000000000000000000000000000000000000000000000000000000000000
- `자동 채택` | 판단 부류=스테이지-재시도 | 상한=없음 | 심각도 상한=minor | 사유=크래시
- `설계 로스터` | 역할=architecture | 범위=구조 | 모델=opus'
cw_write() {
  {
    printf '# 파이프라인 런 매니페스트 — 20261001-feedbeef\n'
    printf '<!-- cc-run-manifest v1; writer=autopilot; reader=orchestrator; run-id=20261001-feedbeef;\n'
    printf '     anchor-kind=repo; anchor-key=Nharu/cc-cmds;\n'
    printf '     owner-doc=(없음); origin-worktree=%s;\n' "$HERE"
    printf '     NOT a design doc; mechanism-local, never staged by a skill -->\n\n'
    printf '## 런 정체\n**킥오프 일시**: %s\n**런 id**: 20261001-feedbeef\n\n' "$CW_KO"
    printf '## 대상\n**대상 맵 다이제스트**: -\n'
    printf -- '- `target` | 별칭=home | 메인 워크트리=%s | 공통 git 디렉터리=%s | 베이스 브랜치=main | 홈=예 | 원격 슬러그=Nharu/cc-cmds | 절단점=머지 | 말단 행위 상한=없음%s\n\n' "$MF_REPO" "$MF_CG" "$CW_TF"
    printf '## 요소\n**설계 문서**: (없음)\n**적용 프로브**: %s\n**적용 주체**: %s\n\n' "$CW_AP" "$CW_AA"
    if [ "$CW_AUTH" = "1" ]; then
      printf '## 인가\n**런 최대 절단점**: 머지\n**종료 지점**: 전부 머지\n'
      printf '**벽시계 마감**: %s\n' "$CW_DL"
      [ -n "$CW_CC" ] && printf '**비용 천장**: %s\n' "$CW_CC"
      [ -n "$CW_SB" ] && printf '**무진전 상한**: %s\n' "$CW_SB"
      printf '**사다리 가용 단 수**: %s\n**미선언 상황 처분**: park\n' "$CW_LAD"
      [ -n "$CW_ROWS" ] && printf '%s\n' "$CW_ROWS"
    fi
  } > "$1"
}
CW="$WORK/carry.md"
KAT='2026-10-10T00:00:00Z'   # 1791590400
KAT_E=1791590400
# kc <file content> [extra args…] — --carry against $CW with its own hash.
kc() {
  local content="$1"; shift
  printf '%s\n' "$content" > "$F"
  CC_CMDS_AUTOPILOT_DEFAULTS_FILE="$F" kd --now "$NOW" --carry "$CW" --kickoff-at "$KAT" --expect-sha256 "$(sha_of "$CW")" "$@"
}
kinds() { printf '%s\n' "$1" | awk -F'\t' -v t="$2" '$1 == t { print $3 }' | sort | paste -sd' ' -; }
cnt() { printf '%s\n' "$1" | awk -F'\t' -v t="$2" -v k="$3" '$1 == t && (k == "" || $3 == k)' | grep -c . || true; }

cw_write "$CW"
out=$(kc 'ladder-rungs = 2
deadline = +3h
cost-ceiling = 40
auto-adopt = 판단 부류=인용-갱신 | 상한=없음 | 심각도 상한=minor | 사유=a
[Nharu/cc-cmds]
cutpoint = PR'); rc=$?
check "--carry 는 0 으로 끝난다" "$rc" "0"
check "--carry 첫 줄이 머리 줄이다" "$(printf '%s\n' "$out" | sed -n 1p)" "cc-kickoff-defaults v1"
for t in 적용 차이 빈칸 권한 마감; do
  [ "$(cnt "$out" "$t" '')" -gt 0 ] && ok "--carry 가 $t 행을 낸다" || bad "--carry 행 종류" "$t 행이 없다"
done
check "차이 행은 파일 값이 다른 키만 (deadline 은 빠진다)" "$(kinds "$out" 차이)" "auto-adopt cutpoint ladder-rungs"
check "빈칸 행은 원천에 없는 키만" "$(kinds "$out" 빈칸)" "cost-ceiling"
check "적용 행은 이전 값을 싣는다 — 사다리" "$(printf '%s\n' "$out" | awk -F'\t' '$1=="적용" && $3=="ladder-rungs" { print $4 }')" "4"
check "적용 행은 이전 값을 싣는다 — 절단점" "$(printf '%s\n' "$out" | awk -F'\t' '$1=="적용" && $3=="cutpoint" { print $2"|"$4 }')" "Nharu/cc-cmds|머지"
check "차이 행은 이전 값과 파일 값을 함께 싣는다" "$(printf '%s\n' "$out" | awk -F'\t' '$1=="차이" && $3=="ladder-rungs" { print $4"|"$5 }')" "4|2"
miss=''
for k in $(grep -E "^KD_(RUN|REPO)_KEYS='" "$HELPER" | sed -E "s/^KD_(RUN|REPO)_KEYS='([^']*)'.*/\2/"); do
  n=$(printf '%s\n' "$out" | awk -F'\t' -v k="$k" '($1 == "적용" || $1 == "빈칸" || $1 == "이어받지 않음") && $3 == k' | grep -c . || true)
  [ "$n" = "1" ] || miss="$miss $k($n)"
done
check "키 표의 모든 키가 적용·빈칸·이어받지 않음 중 정확히 한 행을 낸다" "${miss:-없음}" "없음"
check "이어받지 않음 행은 이름 붙은 사유 토큰을 갖는다" \
  "$(printf '%s\n' "$out" | awk -F'\t' '$1=="이어받지 않음" && ($4 == "" || NF != 5)' | grep -c . || true)" "0"
check "자동 채택 행마다 권한 행이 하나" "$(cnt "$out" 권한 auto-adopt)" "1"
check "사전 인가 형태 행마다 권한 행이 하나 (인터뷰 행은 빠진다)" "$(cnt "$out" 권한 act-allow)" "2"
check "대상별 권한 필드와 적용 주체가 권한 행을 낸다" \
  "$(cnt "$out" 권한 cutpoint)$(cnt "$out" 권한 review-ceiling)$(cnt "$out" 권한 terminal-cap)$(cnt "$out" 권한 apply-actor)" "1111"
check "권한 행은 이어받는 행을 축자로 싣는다" \
  "$(printf '%s\n' "$out" | awk -F'\t' '$1=="권한" && $3=="act-allow" { print $4; exit }')" '- `사전 인가` | 형태=gh pr | 사유=리뷰'
widen() { printf '%s\n' "$out" | awk -F'\t' -v k="$1" '$1=="권한" && $3==k { print $5; exit }'; }
check "권한 넓힘 표식 — 절단점 머지 1 · 리뷰 상한 선리뷰후머지 0 · 말단 상한 없음 1 · 사전 인가 1 · 자동 채택 1 · 적용 주체 없음 0" \
  "$(widen cutpoint)$(widen review-ceiling)$(widen terminal-cap)$(widen act-allow)$(widen auto-adopt)$(widen apply-actor)" "101110"
check "권한 행 수가 원천 자동 채택+사전 인가 형태 행 수와 대상별 권한 필드 수의 합" "$(cnt "$out" 권한 '')" "7"
check "적용 프로브 코드 행 없는 원천 → 이어받지 않음 행 없음" \
  "$(printf '%s\n' "$out" | awk -F'\t' '$1=="이어받지 않음" && $3=="apply-probe-codes" { print $4 }')" "행 없음"

# 적용 프로브 코드 행은 `<불필요>/<필요>` 로 이어받는다. 원천 절단점이 머지라
# 파일의 적용 키는 불활성이고, 차이 행도 빈칸 행도 생기지 않는다.
CW_ROWS_SAVE="$CW_ROWS"; CW_AP_SAVE="$CW_AP"
CW_AP='`make probe`'
CW_ROWS="$CW_ROWS
- \`적용 프로브 코드\` | 불필요=0 | 필요=21 | 프로브 sha256=$(printf '%s' 'make probe' | shasum -a 256 | awk '{ print $1 }')"
cw_write "$CW"
out=$(kc '[Nharu/cc-cmds]
apply-probe-codes = 0/2')
check "원천의 적용 프로브 코드 행을 0/21 로 이어받는다" \
  "$(printf '%s\n' "$out" | awk -F'\t' '$1=="적용" && $3=="apply-probe-codes" { print $4 }')" "0/21"
check "적용 프로브 코드는 차이·빈칸 행이 되지 않는다" "$(cnt "$out" 차이 apply-probe-codes)$(cnt "$out" 빈칸 apply-probe-codes)" "00"
CW_ROWS="$CW_ROWS_SAVE"; CW_AP="$CW_AP_SAVE"
cw_write "$CW"
out=$(kc '[Nharu/cc-cmds]
apply-probe-codes = 0/21')
check "원천에 행이 없으면 파일 값이 있어도 빈칸이 아니다" "$(cnt "$out" 빈칸 apply-probe-codes)" "0"

# ---------------------------------------------------------------------------
# --apply-probe-sha — 초안의 프로브 해시를 드라이버 함수로 재고, 적용 프로브
# 코드 행을 매니페스트 검사의 그 절반으로 판정한다. 작은따옴표가 든 프로브는
# `printf '%s' '<프로브>'` 로 재면 셸이 따옴표를 벗겨 다른 해시가 나오므로,
# 그 해시로 얼린 행은 여기서 거부돼야 한다.
# ---------------------------------------------------------------------------
aps() { kd --apply-probe-sha "$1"; }
aps_row() { printf '%s\n' "$1" | awk -F'\t' '$1=="행" { print $2 }'; }
APS_PROBE="grep -q 'needle' f || exit 3"
APS_SHA=$(printf '%s' "$APS_PROBE" | shasum -a 256 | awk '{ print $1 }')
APS_BAD=$(printf '%s' "grep -q needle f || exit 3" | shasum -a 256 | awk '{ print $1 }')
[ "$APS_SHA" != "$APS_BAD" ] && ok "전제: 따옴표를 벗긴 해시는 원래 바이트의 해시와 다르다" \
  || bad "전제" "두 해시가 같다"
CW_ROWS_SAVE="$CW_ROWS"; CW_AP_SAVE="$CW_AP"
CW_AP="\`$APS_PROBE\`"
cw_write "$CW"
out=$(aps "$CW"); rc=$?
check "--apply-probe-sha 는 0 으로 끝난다" "$rc" "0"
check "--apply-probe-sha 는 백틱을 벗긴 원래 바이트를 잰다" \
  "$(printf '%s\n' "$out" | awk -F'\t' '$1=="프로브" { print $2 }')" "$APS_SHA"
check "--apply-probe-sha 행 없는 초안 → 행 없음" "$(aps_row "$out")" "없음"
CW_ROWS="$CW_ROWS
- \`적용 프로브 코드\` | 불필요=2 | 필요=0 | 프로브 sha256=$APS_SHA"
cw_write "$CW"
check "--apply-probe-sha 원래 바이트로 얼린 행 → 맞음" "$(aps_row "$(aps "$CW")")" "맞음"
CW_ROWS="$CW_ROWS_SAVE
- \`적용 프로브 코드\` | 불필요=2 | 필요=0 | 프로브 sha256=$APS_BAD"
cw_write "$CW"
out=$(aps "$CW")
check "--apply-probe-sha 따옴표를 벗겨 잰 행 → 거부" "$(aps_row "$out")" "거부"
case "$(printf '%s\n' "$out" | awk -F'\t' '$1=="행" { print $3 }')" in
  *"행 $APS_BAD, 프로브 $APS_SHA"*) ok "--apply-probe-sha 거부 문면은 매니페스트 검사의 두 해시를 싣는다" ;;
  *) bad "--apply-probe-sha 거부 문면" "$out" ;;
esac
CW_ROWS="$CW_ROWS_SAVE
- \`적용 프로브 코드\` | 불필요=2 | 필요=2 | 프로브 sha256=$APS_SHA"
cw_write "$CW"
check "--apply-probe-sha 깨진 행 → 거부" "$(aps_row "$(aps "$CW")")" "거부"
check "--apply-probe-sha 는 원본을 바꾸지 않는다" "$(grep -c '필요=2 | 프로브' "$CW")" "1"
CW_ROWS="$CW_ROWS_SAVE"; CW_AP="$CW_AP_SAVE"
cw_write "$CW"
check "--apply-probe-sha 도 런 안에서는 3" "$(CC_PIPELINE_RUN_ID=x "$BASH" "$HELPER" --apply-probe-sha "$CW" >/dev/null 2>&1; echo $?)" "3"
check "--apply-probe-sha 는 --target 과 함께 쓰지 않는다" "$(kd --apply-probe-sha "$CW" $T >/dev/null 2>&1; echo $?)" "2"
check "--apply-probe-sha 에 없는 파일 → 3" "$(kd --apply-probe-sha "$WORK/none.md" >/dev/null 2>&1; echo $?)" "3"

# 행 0개 원천 + 파일의 auto-adopt — 「없음으로 답함」 은 적용이지 빈칸이 아니다.
CW_ROWS_SAVE="$CW_ROWS"; CW_ROWS=''
cw_write "$CW"
out=$(kc 'auto-adopt = 판단 부류=인용-갱신 | 상한=없음 | 심각도 상한=minor | 사유=a
[Nharu/cc-cmds]
act-allow = 형태=gh pr | 사유=a')
check "자동 채택·사전 인가 행 0개 원천 + 파일 값 → 빈칸 0" "$(cnt "$out" 빈칸 '')" "0"
check "행 0개 원천의 자동 채택은 적용 없음" "$(printf '%s\n' "$out" | awk -F'\t' '$1=="적용" && $3=="auto-adopt" { print $4 }')" "없음"
check "행 0개 원천의 권한 행은 대상별 필드뿐" "$(cnt "$out" 권한 auto-adopt)$(cnt "$out" 권한 act-allow)" "00"
CW_ROWS="$CW_ROWS_SAVE"

# 금지 부류로 표류한 원천 행은 권한으로 싣지 않고 이름 붙여 묻는다.
CW_ROWS_SAVE="$CW_ROWS"
CW_ROWS='- `자동 채택` | 판단 부류=팀-구성 | 상한=없음 | 심각도 상한=minor | 사유=x'
cw_write "$CW"
out=$(kc '')
check "금지 부류 원천 행은 권한 행이 없다" "$(cnt "$out" 권한 auto-adopt)" "0"
check "금지 부류 원천 행은 이어받지 않음 금지 부류" \
  "$(printf '%s\n' "$out" | awk -F'\t' '$1=="이어받지 않음" && $3=="auto-adopt" { print $4 }')" "금지 부류"
CW_ROWS="$CW_ROWS_SAVE"

# 거절 — 세 변수 각각.
cw_write "$CW"
for v in CC_PIPELINE_RUN_ID CC_PIPELINE_STAGE_ID CC_PIPELINE_SHIFT_ID; do
  out=$(env "$v=x" "$BASH" "$HELPER" --carry "$CW" --kickoff-at "$KAT" --expect-sha256 "$(sha_of "$CW")" 2>/dev/null); rc=$?
  check "--carry 는 $v 가 있으면 비영으로 거절한다" "$([ "$rc" != "0" ] && echo 비영 || echo 0)" "비영"
  check "--carry 거절 때 $v 에서 stdout 은 비어 있다" "$out" ""
done
check "--carry 는 --target 과 함께 쓰지 않는다" "$(kd --carry "$CW" --kickoff-at "$KAT" --expect-sha256 "$(sha_of "$CW")" $T >/dev/null 2>&1; echo $?)" "2"
check "--kickoff-at 만 따로 쓰면 용법 오류" "$(kd $T --kickoff-at "$KAT" >/dev/null 2>&1; echo $?)" "2"

# 마감 — 세 표기가 고쳐 쓴 뒤 같은 간격, 그리고 run.sh 의 판독기와 같은 순간.
dl_inst() {
  CC_ORCH_SOURCE_ONLY=1 bash -c 'd="$1"; x="$2"; set --; . "$d" >/dev/null 2>&1; set +e; deadline_instant "$x"' _ "$DRIVER" "$1" 2>/dev/null
}
dl_row() { cw_write "$CW"; kc '' | awk -F'\t' '$1=="마감" { print $2"|"$3"|"$4 }'; }
ivs=''
for d in '2026-10-09T12:00:00Z' '2026-10-09T21:00:00+09:00' '2026-10-09T21:00:00+0900'; do
  CW_DL="$d"; r=$(dl_row)
  case "$r" in ok\|*) ;; *) bad "마감 '$d'" "ok 가 아니다: $r" ;; esac
  ivs="$ivs ${r##*|}"
  abs=$(printf '%s' "$r" | cut -d'|' -f2)
  check "마감 '$d' 의 새 절대값을 deadline_instant 가 킥오프+간격으로 읽는다" "$(dl_inst "$abs")" "$((KAT_E + 32400))"
done
check "Z·±HH:MM·±HHMM 세 표기가 같은 간격을 낸다" "$ivs" " 32400 32400 32400"
CW_KO='2026-10-09T12:00:00+0900'; CW_DL='2026-10-09T21:00:00+09:00'; r=$(dl_row)
check "±HHMM 킥오프 일시도 넓게 읽는다" "${r##*|}" "32400"
# 다시 잡은 마감은 deadline-resolve.sh 의 렌더로 쓴다 — 지워진 시간 프로그램 변수를 부르면
# jq 가 실패해 이어받은 마감마다 형식 오류가 된다.
CW_KO='2026-10-09T03:00:00Z'; CW_DL='2026-10-09T12:00:00Z'; r=$(dl_row)
check "--carry 는 이어받은 마감을 형식 오류 없이 낸다" "${r%%|*}" "ok"
check "오케스트레이터에 KD_JQ_TIME 참조가 없다" "$(cat "$ORCH"/*.sh | grep -c 'KD_JQ_TIME')" "0"
CW_KO='2026-10-09T03:00:00Z'
for d in '2026-10-09T21:00:00+99:99' '2026-10-09T21:00:00+1500' '2026-13-09T21:00:00+09:00'; do
  CW_DL="$d"
  check "범위 밖 마감 '$d' 는 사유 토큰" "$(dl_row | cut -d'|' -f1)" "범위 밖"
done
CW_DL='2026-10-09T21:00:00'
check "영역 없는 마감은 사유 토큰" "$(dl_row | cut -d'|' -f1)" "영역 없음"
CW_DL='2026-10-09T02:00:00Z'
check "0 이하의 간격은 사유 토큰" "$(dl_row | cut -d'|' -f1)" "간격 없음"
CW_DL='2026-10-09T12:00:00Z'
cw_write "$CW"
r=$(CC_CMDS_AUTOPILOT_DEFAULTS_FILE=off kd --now "$NOW" --carry "$CW" --kickoff-at '2026-09-01T00:00:00Z' --expect-sha256 "$(sha_of "$CW")" \
    | awk -F'\t' '$1=="마감" { print $2 }')
check "다시 잡은 마감이 지났으면 사유 토큰" "$r" "과거 시각"
CW_DL='없음'
check "이전 마감 없음은 사유 토큰" "$(dl_row | cut -d'|' -f1)" "마감 없음"
CW_DL='2026-10-09T12:00:00Z'

# --carry --auto — 이전 간격을 옮길 수 없으면 재킥오프 행의 길이로 물러선다.
dl_auto() { cw_write "$CW"; kc '' "$@" | awk -F'\t' '$1=="마감" { print $2"|"$3"|"$4"|"$5 }'; }
CW_ROWS_SAVE="$CW_ROWS"
CW_ROWS="$CW_ROWS
- \`재킥오프\` | 연쇄 상한=3 | 길이=PT48H0M0S | 사유=밤새 이어 간다"
CW_DL='2026-10-09T21:00:00'
r=$(dl_auto --auto)
check "--carry --auto: 간격을 못 옮기면 길이로 물러서 ok 를 낸다" "${r%%|*}" "ok"
check "--carry --auto: 물러선 줄은 출처=길이 를 싣는다" "${r##*|}" "출처=길이"
check "--carry --auto: 물러선 마감은 킥오프 일시 + 길이의 순간이다" "$(dl_inst "$(printf '%s' "$r" | cut -d'|' -f2)")" "$((KAT_E + 172800))"
check "--carry --auto: 물러선 줄의 간격 칸은 길이의 초다" "$(printf '%s' "$r" | cut -d'|' -f3)" "172800"
check "--carry --auto: 물러선 마감은 ±HH:MM 오프셋으로 쓴다" \
  "$(printf '%s' "$r" | cut -d'|' -f2 | grep -cE '[+-][0-9]{2}:[0-9]{2}$')" "1"
check "--auto 없는 --carry 는 같은 원천에서 기존 사유 토큰을 낸다" "$(dl_auto | cut -d'|' -f1)" "영역 없음"
CW_DL='2026-10-09T12:00:00Z'
r=$(dl_auto --auto)
check "--carry --auto: 간격을 옮길 수 있으면 이전 간격이고 출처 칸이 없다" "$(printf '%s' "$r" | cut -d'|' -f3)|$(printf '%s' "$r" | cut -d'|' -f4)" "32400|"
CW_ROWS="$CW_ROWS_SAVE"
CW_DL='2026-10-09T21:00:00'
check "--carry --auto: 재킥오프 행이 없는 원천은 물러서지 않는다" "$(dl_auto --auto | cut -d'|' -f1)" "영역 없음"
CW_DL='2026-10-09T12:00:00Z'
check "--auto 는 --carry 와 함께만 쓴다" "$(kd $T --auto >/dev/null 2>&1; echo $?)" "2"

# 해시 — 틀린 해시는 아무것도 내지 않고, 사본을 뜬 뒤 원천이 바뀌어도 사본의 값을 낸다.
cw_write "$CW"
out=$(CC_CMDS_AUTOPILOT_DEFAULTS_FILE=off kd --now "$NOW" --carry "$CW" --kickoff-at "$KAT" \
      --expect-sha256 "$(printf '%064d' 0)" 2>"$WORK/carry.err"); rc=$?
check "틀린 --expect-sha256 은 비영" "$([ "$rc" != "0" ] && echo 비영 || echo 0)" "비영"
check "틀린 --expect-sha256 에서 stdout 은 비어 있다" "$out" ""
check "틀린 --expect-sha256 에서 stderr 는 한 줄" "$(grep -c . "$WORK/carry.err")" "1"
# 원천을 FIFO 로 두면 처음 연 쪽은 원래 바이트를, 다시 연 쪽은 바뀐 바이트를 읽는다.
# 도우미가 사본만 읽으면 둘째 쓰기는 끝내 읽히지 않는다.
FIFO="$WORK/carry.fifo"; rm -f "$FIFO"
if mkfifo "$FIFO" 2>/dev/null; then
  ORIG=$(cat "$CW"); want=$(sha_of "$CW")
  CHANGED=$(printf '%s\n' "$ORIG" | sed 's/^\*\*사다리 가용 단 수\*\*: 4$/**사다리 가용 단 수**: 2/')
  ( printf '%s\n' "$ORIG" > "$FIFO"; sleep 1; printf '%s\n' "$CHANGED" > "$FIFO" ) &
  wpid=$!
  out=$(CC_CMDS_AUTOPILOT_DEFAULTS_FILE=off kd --now "$NOW" --carry "$FIFO" --kickoff-at "$KAT" --expect-sha256 "$want" 2>/dev/null)
  kill "$wpid" 2>/dev/null; wait "$wpid" 2>/dev/null
  check "사본을 뜬 뒤 원천이 바뀌어도 적용 행은 사본의 값이다" \
    "$(printf '%s\n' "$out" | awk -F'\t' '$1=="적용" && $3=="ladder-rungs" { print $4 }')" "4"
  rm -f "$FIFO"
else
  bad "사본 갈고리" "mkfifo 를 쓸 수 없다"
fi
# 사본은 도우미가 끝나면 남지 않는다.
check "개인 사본은 끝나면 지워진다" "$(ls "${TMPDIR:-/tmp}" 2>/dev/null | grep -c '^cc-kickoff-carry\.' || true)" "0"

# ---------------------------------------------------------------------------
# --plugin-candidates — 세션 계정과 레인 인벤토리 계정의 사용자 키를 허용·후보로
# 나누고, 후보에는 설치된 플러그인의 설명 첫 줄을 붙인다
# ---------------------------------------------------------------------------
PC_A="$WORK/pc-acct-a"; PC_B="$WORK/pc-acct-b"; PC_X="$WORK/pc-xdg"
mkdir -p "$PC_A/plugins" "$PC_B" "$PC_X/cc-lane" "$WORK/pc-inst/figma/.claude-plugin"
printf '{"description":"Figma 디자인 도구\\n둘째 줄"}\n' > "$WORK/pc-inst/figma/.claude-plugin/plugin.json"
printf '{"version":2,"plugins":{"figma@claude-plugins-official":[{"scope":"user","installPath":"%s"}],"typesafe@typesafe-ai":[{"scope":"user","installPath":"%s/none"}]}}\n' \
  "$WORK/pc-inst/figma" "$WORK" > "$PC_A/plugins/installed_plugins.json"
printf '{"enabledPlugins":{"swift-lsp@claude-plugins-official":true,"cc-cmds@inline":true,"x@builtin":true}}\n' > "$PC_A/settings.json"
printf '{"enabledPlugins":{"slack@claude-plugins-official":true}}\n' > "$PC_B/settings.json"
printf '{"accounts":[{"config_dir":"%s"}]}\n' "$PC_B" > "$PC_X/cc-lane/accounts.json"
pc() { CLAUDE_CONFIG_DIR="$PC_A" XDG_CONFIG_HOME="$PC_X" kd --plugin-candidates "$@"; }
out=$(pc); rc=$?
check "--plugin-candidates 는 0 으로 끝난다" "$rc" "0"
check "--plugin-candidates 의 허용 줄은 seed 키다" \
  "$(printf '%s\n' "$out" | awk -F'\t' '$1=="허용" { print $2 }' | paste -sd' ' -)" "typesafe@typesafe-ai"
check "--plugin-candidates 의 후보는 허용 키·@inline·@builtin 을 뺀 두 계정의 사용자 키다" \
  "$(printf '%s\n' "$out" | awk -F'\t' '$1=="후보" { print $2 }' | paste -sd' ' -)" \
  "figma@claude-plugins-official slack@claude-plugins-official swift-lsp@claude-plugins-official"
check "--plugin-candidates 의 설명은 설치 경로 plugin.json 의 첫 줄이다" \
  "$(printf '%s\n' "$out" | awk -F'\t' '$1=="후보" && $2=="figma@claude-plugins-official" { print $3 }')" "Figma 디자인 도구"
check "--plugin-candidates 의 설명이 없으면 - 다" \
  "$(printf '%s\n' "$out" | awk -F'\t' '$1=="후보" && $2=="slack@claude-plugins-official" { print $3 }')" "-"
check "--plugin-candidates 는 --target 과 함께 쓰지 않는다" "$(pc $T >/dev/null 2>&1; echo $?)" "2"
check "--plugin-candidates 는 --now 와 함께 쓰지 않는다" "$(pc --now "$NOW" >/dev/null 2>&1; echo $?)" "2"
check "--plugin-candidates 도 런 안에서는 3" "$(CC_PIPELINE_RUN_ID=x "$BASH" "$HELPER" --plugin-candidates >/dev/null 2>&1; echo $?)" "3"
# 인벤토리가 심볼릭 링크면 그 계정은 후보에 더하지 않는다 — 판정 불가 조건이 후보
# 목록을 바꾸지 않는다.
PC_XL="$WORK/pc-xdg-link"; mkdir -p "$PC_XL/cc-lane"
ln -s "$PC_X/cc-lane/accounts.json" "$PC_XL/cc-lane/accounts.json"
check "--plugin-candidates: 심볼릭 링크 인벤토리의 계정은 읽지 않는다" \
  "$(CLAUDE_CONFIG_DIR="$PC_A" XDG_CONFIG_HOME="$PC_XL" kd --plugin-candidates | awk -F'\t' '$1=="후보" { print $2 }' | paste -sd' ' -)" \
  "figma@claude-plugins-official swift-lsp@claude-plugins-official"
printf '{"plugins":[]}\n' > "$PC_B/plugins.json.unused"
mkdir -p "$PC_B/plugins"; printf '[]\n' > "$PC_B/plugins/installed_plugins.json"
check "--plugin-candidates: 모양이 틀린 설치 기록은 키를 더하지 않고 후보는 그대로다" \
  "$(pc | awk -F'\t' '$1=="후보" { print $2 }' | paste -sd' ' -)" \
  "figma@claude-plugins-official slack@claude-plugins-official swift-lsp@claude-plugins-official"
rm -f "$PC_B/plugins/installed_plugins.json" "$PC_B/plugins.json.unused"
out=$(pc --confirmed slack@claude-plugins-official --released ghost@m --released figma@claude-plugins-official); rc=$?
check "--plugin-candidates --confirmed·--released 는 0 으로 끝난다" "$rc" "0"
check "--confirmed 키는 후보에서 빠지고 --released 키는 계정에 없어도 후보다" \
  "$(printf '%s\n' "$out" | awk -F'\t' '$1=="후보" { print $2 }' | paste -sd' ' -)" \
  "figma@claude-plugins-official ghost@m swift-lsp@claude-plugins-official"
check "--released 후보의 설명은 킥오프 기본값이다" \
  "$(printf '%s\n' "$out" | awk -F'\t' '$1=="후보" && ($2=="ghost@m" || $2=="figma@claude-plugins-official") { print $3 }' | paste -sd'|' -)" \
  "킥오프 기본값|킥오프 기본값"
check "--released 는 시드 키를 후보로 만들지 않는다" \
  "$(pc --released typesafe@typesafe-ai | awk -F'\t' '$1=="후보" && $2=="typesafe@typesafe-ai"' | grep -c . || true)" "0"
check "--confirmed 의 키 모양이 틀리면 2" "$(pc --confirmed notakey >/dev/null 2>&1; echo $?)" "2"
check "--released 는 --plugin-candidates 와 함께만 쓴다" "$(kd $T --released ghost@m >/dev/null 2>&1; echo $?)" "2"

# ---------------------------------------------------------------------------
# plugin-allow — 킥오프가 읽는 계정 디렉터리로 키마다 시드·켬·미설치·판정 불가를
# 가린다. 계정은 파일 머리에서 고정한 CLAUDE_CONFIG_DIR 와, XDG_CONFIG_HOME 아래
# 레인 인벤토리가 더하는 디렉터리다.
# ---------------------------------------------------------------------------
PA="$CLAUDE_CONFIG_DIR"
PA_N='notion@claude-plugins-official'; PA_F='figma@claude-plugins-official'
PA_SEED=$(grep -E '^[A-Za-z0-9_.-]+@[A-Za-z0-9_.-]+$' "$ORCH/plugin-allow.seed" | sed -n 1p)
PA_X="$WORK/pa-xdg"   # 인벤토리 없는 XDG — 파일이 정하는 사례만 이 아래에 만든다
pa_reset() {
  rm -rf "$PA" "$PA_X"; mkdir -p "$PA/plugins" "$PA_X/cc-lane"
  printf '{"version":2,"plugins":{"%s":[{"scope":"user"}]}}\n' "$PA_N" > "$PA/plugins/installed_plugins.json"
  printf '{"enabledPlugins":{"%s":false}}\n' "$PA_F" > "$PA/settings.json"
}
# pk <file content> [helper args…] — the main mode against the account fixture.
pk() { XDG_CONFIG_HOME="$PA_X" kf "$@" $T; }
# pr <output> — `<적용|사유 토큰>|<범위>|<값>|<출처>` for each plugin-allow row.
pr() { printf '%s\n' "$1" | awk -F'\t' '($1=="적용" || $1=="무시") && $3=="plugin-allow" { print ($1=="적용" ? "적용" : $6) "|" $2 "|" $4 "|" $5 }'; }
# pst <file content> <key> — the token of the run-wide line `plugin-allow = <key>`.
pst() { st "$(pk "plugin-allow = $1")" plugin-allow; }
# pmsg <key> — the reason text of that row.
pmsg() { printf '%s\n' "$(pk "plugin-allow = $1")" | awk -F'\t' '$1=="무시" && $3=="plugin-allow" { print $7; exit }'; }
[ -n "$PA_SEED" ] && ok "전제: 시드에 키가 있다" || bad "전제" "plugin-allow.seed 에 키가 없다"

pa_reset
out=$(pk "plugin-allow = $PA_N")
check "plugin-allow: 런 전역의 설치된 키는 적용" "$(pr "$out")" "적용|런|$PA_N|파일:1"
check "plugin-allow: 적용 행은 권한 확대 표지를 단다" "$(col "$out" plugin-allow 6)" "1"
check "plugin-allow: 효과 줄" "$(col "$out" plugin-allow 7)" \
  "이 플러그인을 이 런의 모든 대상·모든 스테이지 세션에서 켭니다 — 라우터 교대는 끈 채로 둡니다"
check "plugin-allow: settings.json 에 false 로만 있는 키도 켬이다" "$(pst "$PA_F")" "적용"
out=$(pk "[Nharu/cc-cmds]
plugin-allow = $PA_F")
check "plugin-allow: 레포 구획에만 적은 키는 자리 틀림 없이 적용" "$(pr "$out")" "적용|Nharu/cc-cmds|$PA_F|파일:2"
out=$(pk "plugin-allow = $PA_N
plugin-allow = $PA_F")
check "plugin-allow: 같은 범위의 다른 두 키는 둘 다 적용" "$(pr "$out" | cut -d'|' -f1,3 | paste -sd' ' -)" "적용|$PA_N 적용|$PA_F"
out=$(pk "plugin-allow = $PA_N
plugin-allow = $PA_N")
check "plugin-allow: 같은 범위의 같은 키는 뒤엣것이 중복" "$(pr "$out" | cut -d'|' -f1 | paste -sd' ' -)" "적용 중복"
for v in notion cc-cmds@inline x@builtin 'a b@m' 'a@m@n'; do
  check "plugin-allow '$v' → 형식 오류" "$(pst "$v")" "형식 오류"
done
check "plugin-allow: 값 앞뒤 공백은 뗀다" "$(pr "$(pk "plugin-allow =   $PA_N  ")" | cut -d'|' -f1,3)" "적용|$PA_N"
check "plugin-allow: 시드 키는 시드" "$(pst "$PA_SEED")" "시드"
check "plugin-allow: 어느 계정에도 없는 키는 미설치" "$(pst ghost@m)" "미설치"
out=$(pk "plugin-allow = $PA_N
[Nharu/cc-cmds]
plugin-allow = $PA_N
plugin-allow = $PA_F")
check "plugin-allow: 범위가 다른 같은 키는 런 전역 하나로 접힌다" \
  "$(pr "$out" | cut -d'|' -f1-3 | paste -sd' ' -)" "적용|런|$PA_N 적용|Nharu/cc-cmds|$PA_F"
out=$(pk "[Nharu/other]
plugin-allow = $PA_N")
check "plugin-allow: 대상이 아닌 구획의 키는 행이 없다" "$(pr "$out" | grep -c . || true)" "0"

# 환경변수 — 쉼표 목록이 파일의 런 전역 줄을 통째로 갈아 끼운다.
PE=CC_CMDS_AUTOPILOT_DEFAULT_PLUGIN_ALLOW
# pe <value> — the main mode with the variable set, against the fixture file $F.
pe() { env -u CC_PIPELINE_RUN_ID "$PE=$1" XDG_CONFIG_HOME="$PA_X" CC_CMDS_AUTOPILOT_DEFAULTS_FILE="$F" "$BASH" "$HELPER" --now "$NOW" $T; }
printf 'plugin-allow = %s\n[Nharu/cc-cmds]\nplugin-allow = %s\n' "$PA_F" "$PA_N" > "$F"
out=$(pe "$PA_N , $PA_F")
check "PLUGIN_ALLOW: 원소마다 적용, 파일의 런 전역 줄은 숨고 레포 구획의 같은 키는 접힌다" \
  "$(pr "$out" | paste -sd' ' -)" "적용|런|$PA_N|환경:$PE 적용|런|$PA_F|환경:$PE"
printf 'plugin-allow = %s\n[Nharu/cc-cmds]\nplugin-allow = %s\n' "$PA_N" "$PA_F" > "$F"
out=$(pe '없음')
check "PLUGIN_ALLOW=없음: 런 전역 줄을 모두 숨기고 레포 구획은 덮지 않는다" \
  "$(pr "$out" | paste -sd' ' -)" "적용|Nharu/cc-cmds|$PA_F|파일:3"
for v in "${PA_N}," "${PA_N},,${PA_F}" ",${PA_N}" "${PA_N}, ,${PA_F}" "${PA_N},없음" 'notion' "${PA_N},x@builtin" "${PA_N}	${PA_F}" "${PA_N}
${PA_F}"; do
  out=$(pe "$v")
  check "PLUGIN_ALLOW '$(printf '%s' "$v" | tr '\t\n' '~~')' → 변수 형식 오류, 파일 런 전역 줄은 환경변수 무효" \
    "$(pr "$out" | awk -F'|' '$2=="런" { print $1 }' | sort | paste -sd' ' -)" "형식 오류 환경변수 무효"
done
check "PLUGIN_ALLOW 무효 행은 값 전체를 싣는다" \
  "$(pr "$(pe "$PA_N,")" | awk -F'|' '$1=="형식 오류" { print $3 }')" "$PA_N,"
check "PLUGIN_ALLOW 무효 문면은 파일 줄도 쓰지 않는다고 말한다" \
  "$(pe "$PA_N," | awk -F'\t' '$1=="무시" && $6=="형식 오류" { print $7 }' | grep -c '파일의 런 전역 plugin-allow 줄을 쓰지 않습니다' || true)" "1"
out=$(pe "$PA_N,$PA_N")
check "PLUGIN_ALLOW: 같은 원소의 재등장은 뒤엣것이 중복" \
  "$(pr "$out" | awk -F'|' '$2=="런" { print $1 }' | paste -sd' ' -)" "적용 중복"
check "PLUGIN_ALLOW: 원소도 하나씩 판정한다 — 미설치·시드" \
  "$(pr "$(pe "ghost@m,$PA_SEED")" | awk -F'|' '$2=="런" { print $1 }' | paste -sd' ' -)" "미설치 시드"
check "PLUGIN_ALLOW 는 읽은 환경변수 수에 든다" \
  "$(pe "$PA_N" | awk -F'\t' '$1=="원천" { print $4 }')" "1"

# 판정 불가 — 계정 집합을 다 읽지 못하면, 읽힌 키는 켬이고 읽히지 않은 키는
# 미설치가 아니라 판정 불가다. 문면은 읽지 못한 경로를 싣는다.
# pj <expected path> <case> — ghost 키가 판정 불가이고 문면에 그 경로가 있는지.
pj() {
  local got msg
  got=$(pst ghost@m); msg=$(pmsg ghost@m)
  check "판정 불가: $2" "$got" "판정 불가"
  case "$msg" in *"읽지 못한 경로: $1") ok "판정 불가 문면의 경로: $2" ;; *) bad "판정 불가 문면의 경로: $2" "$msg" ;; esac
}
inv="$PA_X/cc-lane/accounts.json"
pa_reset; printf '{' > "$PA/plugins/installed_plugins.json"
pj "$PA/plugins/installed_plugins.json" "깨진 installed_plugins.json"
check "판정 불가: 다른 파일에서 읽힌 키는 여전히 적용" "$(pst "$PA_F")" "적용"
pa_reset; printf '{"accounts":[{"config_dir":"%s"}]}\n' "$WORK/pa-none" > "$inv"
pj "$WORK/pa-none" "인벤토리가 가리키는 없는 디렉터리"
pa_reset; rm -f "$PA/plugins/installed_plugins.json"; printf '{}\n' > "$PA/settings.json"
pj "$PA" "모든 계정의 키가 0개"
pa_reset; mkdir -p "$WORK/pa-empty"; printf '{"accounts":[{"config_dir":"%s"}]}\n' "$WORK/pa-empty" > "$inv"
check "두 파일이 없는 계정을 더해도 다른 계정의 키는 적용" "$(pst "$PA_N")" "적용"
check "두 파일이 없는 계정을 더해도 없는 키는 미설치" "$(pst ghost@m)" "미설치"
pa_reset; printf '{"accounts":[]}\n' > "$WORK/pa-inv-real"; ln -s "$WORK/pa-inv-real" "$inv"
pj "$inv" "심볼릭 링크 인벤토리"
pa_reset; ln -s "$WORK/pa-inv-dangling" "$inv"
pj "$inv" "가리키는 곳 없는 심볼릭 링크 인벤토리"
for body in '{}' '{"accounts":"x"}' '{"accounts":3}' '[]' '{"accounts":[{}]}' '{"accounts":[{"config_dir":""}]}' \
            '{"accounts":[{"config_dir":5}]}' '{"accounts":["x"]}' 'not json'; do
  pa_reset; printf '%s\n' "$body" > "$inv"
  pj "$inv" "인벤토리 $body"
done
pa_reset; printf '{"accounts":[]}\n' > "$inv"
check "인벤토리의 빈 배열은 미설치" "$(pst ghost@m)" "미설치"
pa_reset; mkdir -p "$WORK/pa-obj"; printf '{"enabledPlugins":{"objonly@m":true}}\n' > "$WORK/pa-obj/settings.json"
printf '{"accounts":{"a":{"config_dir":"%s"}}}\n' "$WORK/pa-obj" > "$inv"
check "객체형 .accounts 가 가리키는 계정의 키는 적용" "$(pst objonly@m)" "적용"
pj "$inv" "객체형 .accounts 에서 없는 키"
pa_reset; mkdir -p "$inv"
pj "$inv" "인벤토리 자리의 디렉터리"
# 일곱째 조건 — 파싱되지만 모양이 틀린 계정 파일.
IP="$PA/plugins/installed_plugins.json"; SJ="$PA/settings.json"
for body in '' ' ' '[]' 'null' '{}' '{"plugins":[]}' '{"plugins":null}'; do
  pa_reset; printf '%s' "$body" > "$IP"
  pj "$IP" "installed_plugins.json '$body'"
done
for body in '[]' 'null' '{"enabledPlugins":"x"}' '{"enabledPlugins":null}' '{"enabledPlugins":false}'; do
  pa_reset; printf '%s' "$body" > "$SJ"
  pj "$SJ" "settings.json '$body'"
done
pa_reset; printf '{}\n' > "$SJ"
check "settings.json 에 .enabledPlugins 가 없으면 미설치" "$(pst ghost@m)" "미설치"
pa_reset; printf '{' > "$IP"
out=$(pe "ghost@m")
check "PLUGIN_ALLOW: 판정 불가 원소" "$(pr "$out" | awk -F'|' '$2=="런" && $4 ~ /^환경:/ { print $1 }')" "판정 불가"

# --carry — 플러그인 허용 행은 키마다 권한·이어받지 않음·빈칸이고 차이 행은 없다.
pa_reset
CW_ROWS_SAVE="$CW_ROWS"
PA_ROW_N="- \`플러그인 허용\` | 플러그인=$PA_N | 사유=노션 문서"
PA_ROW_S="- \`플러그인 허용\` | 플러그인=$PA_SEED | 사유=시드"
PA_ROW_G="- \`플러그인 허용\` | 플러그인=ghost@m | 사유=없어짐"
CW_ROWS="$CW_ROWS
$PA_ROW_N
$PA_ROW_S
$PA_ROW_G"
cw_write "$CW"
pc_carry() { XDG_CONFIG_HOME="$PA_X" kc "$@"; }
# prc <output> <kind> — `<칸3>|<칸4>` of the plugin-allow rows of that kind.
prc() { printf '%s\n' "$1" | awk -F'\t' -v t="$2" '$1==t && $3=="plugin-allow" { print $2 "|" $4 }'; }
out=$(pc_carry "plugin-allow = $PA_F
plugin-allow = gone@m
[Nharu/cc-cmds]
plugin-allow = $PA_F
plugin-allow = $PA_N")
check "--carry plugin-allow: 켬 행은 권한 행이고 행을 축자로 싣는다" "$(prc "$out" 권한)" "런|$PA_ROW_N"
check "--carry plugin-allow: 권한 행은 넓힘 표식을 단다" \
  "$(printf '%s\n' "$out" | awk -F'\t' '$1=="권한" && $3=="plugin-allow" { print $5 }')" "1"
check "--carry plugin-allow: 적용 요약 한 줄이 이어받는 키를 싣는다" "$(prc "$out" 적용)" "런|$PA_N"
check "--carry plugin-allow: 시드·미설치 행과 미설치 파일 키는 이어받지 않음" \
  "$(prc "$out" '이어받지 않음' | cut -d'|' -f2 | paste -sd' ' -)" "시드 미설치 미설치"
check "--carry plugin-allow: 이어받지 않은 행은 그 행을 축자로 싣는다" \
  "$(printf '%s\n' "$out" | awk -F'\t' '$1=="이어받지 않음" && $3=="plugin-allow" && $4=="시드" { print $5 }')" "$PA_ROW_S"
check "--carry plugin-allow: 앞선 행이 없는 파일 키는 범위가 둘이어도 빈칸 한 줄" "$(prc "$out" 빈칸)" "런|$PA_F"
check "--carry plugin-allow: 앞선 행이 있는 파일 키는 빈칸이 아니다" \
  "$(printf '%s\n' "$out" | awk -F'\t' '$1=="빈칸" && $3=="plugin-allow" && $4=="'"$PA_N"'"' | grep -c . || true)" "0"
check "--carry plugin-allow: 차이 행은 없다" "$(cnt "$out" 차이 plugin-allow)" "0"
check "--carry plugin-allow: 원천 없음 행은 없다" \
  "$(printf '%s\n' "$out" | awk -F'\t' '$1=="이어받지 않음" && $3=="plugin-allow" && $4=="원천 없음"' | grep -c . || true)" "0"
printf '{' > "$PA/plugins/installed_plugins.json"
out=$(pc_carry '')
check "--carry plugin-allow: 계정 파일이 깨지면 읽히지 않은 앞선 행도 권한 행" \
  "$(printf '%s\n' "$out" | awk -F'\t' '$1=="권한" && $3=="plugin-allow" { print $4 }' | sort | paste -sd'~' -)" "$PA_ROW_G~$PA_ROW_N"
case "$(printf '%s\n' "$out" | awk -F'\t' '$1=="권한" && $3=="plugin-allow" && $4=="'"$PA_ROW_G"'" { print $6 }')" in
  *"판정하지 못했습니다"*"$PA/plugins/installed_plugins.json"*) ok "--carry plugin-allow: 판정 불가 권한 행의 효과는 읽지 못한 경로를 싣는다" ;;
  *) bad "--carry plugin-allow 판정 불가 효과" "$out" ;;
esac
check "--carry plugin-allow: 깨진 계정 파일에서도 시드 행은 이어받지 않음" "$(prc "$out" '이어받지 않음' | cut -d'|' -f2)" "시드"
pa_reset
CW_ROWS="$CW_ROWS_SAVE"; cw_write "$CW"
out=$(pc_carry "[Nharu/cc-cmds]
plugin-allow = $PA_F")
check "--carry plugin-allow: 인가 절이 있고 플러그인 행이 없는 원천에서 파일 키는 빈칸" "$(prc "$out" 빈칸)" "Nharu/cc-cmds|$PA_F"
out=$(pc_carry "plugin-allow = $PA_SEED
plugin-allow = ghost@m
plugin-allow = bad")
check "--carry plugin-allow: 시드·미설치·형식 오류 파일 키는 각각 이어받지 않음 한 줄" \
  "$(prc "$out" '이어받지 않음' | cut -d'|' -f2 | paste -sd' ' -)" "시드 미설치 형식 오류"
printf '{' > "$PA/plugins/installed_plugins.json"
out=$(pc_carry "plugin-allow = ghost@m")
check "--carry plugin-allow: 판정 불가 파일 키는 이어받지 않음 판정 불가" "$(prc "$out" '이어받지 않음' | cut -d'|' -f2)" "판정 불가"
pa_reset
out=$(pc_carry '')
check "--carry plugin-allow: 행도 파일 키도 없으면 원천 없음 한 줄" "$(prc "$out" '이어받지 않음')" "런|원천 없음"
rm -rf "$PA" "$PA_X"; mkdir -p "$PA"

# ---------------------------------------------------------------------------
# SKILL.md 문면 — 호출 철자와 5n 고지
# ---------------------------------------------------------------------------
if grep -F 'bash <plugin root>/orchestrator/kickoff-defaults.sh' "$SKILL" >/dev/null; then
  ok "SKILL.md 가 보조의 호출 철자를 담는다"
else
  bad "호출 철자" "SKILL.md 에 'bash <plugin root>/orchestrator/kickoff-defaults.sh' 가 없다"
fi
p5n=$(awk '/^\*\*5n — /{f=1; print; next} f&&(/^\*\*5[a-z] — /||/^#/){exit} f' "$BOUNDARIES")
case "$p5n" in *deadline-passed*) ok "5n 문단이 deadline-passed 를 담는다" ;; *) bad "5n 문단" "deadline-passed 가 없다" ;; esac
case "$p5n" in *'no environment variable selects it'*) ok "5n 문단이 「no environment variable selects it」 을 그대로 담는다" ;;
  *) bad "5n 문단" "「no environment variable selects it」 문장이 없다" ;; esac

# 5p 의 손 입력 재질문은 대조기 철자가 한 낱말이 되면 그 철자를 내놓지 않는다 — 보조는
# 같은 입력과 그 한 낱말 철자를 모두 거부하므로, 두 입구가 같은 입력에 같게 답한다.
expect repo act-allow '형식 오류' '형태=kubectl --context=prod | 사유=a' '형태=gh -R=org/repo | 사유=a' '형태=kubectl | 사유=a'
p5p=$(awk '/^\*\*5p — /{f=1; print; next} f&&(/^\*\*5[a-z] — /||/^#/){exit} f' "$BOUNDARIES")
case "$p5p" in *"When the matcher's spelling comes to fewer than two words, do not offer it"*) ok "5p 문단이 한 낱말 대조기 철자를 제안하지 않는다고 적는다" ;;
  *) bad "5p 문단" "한 낱말 대조기 철자를 제안하지 않는다는 문장이 없다" ;; esac

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
