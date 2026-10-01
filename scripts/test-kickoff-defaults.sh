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
CC_CMDS_AUTOPILOT_NOTIFY=0
export CC_CMDS_AUTOPILOT_NOTIFY
HOME="$WORK/home"; mkdir -p "$HOME"
export HOME
unset XDG_CONFIG_HOME
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
expect repo dev-ids '형식 오류' 'aws-account:12345' 'aws-account:1234567890ab' 'dir:relative/path' 'aws-acct:dev' 'aws-profile' 'host:' 'host:a,'
expect repo deploy-triggers 적용 'workflow:deploy.yml' 'jenkins-job:x, argv:bash scripts/deploy.sh' 없음
expect repo deploy-triggers '형식 오류' 'release' 'deploy:release' 'workflow:'
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
# SKILL.md 문면 — 호출 철자와 5n 고지
# ---------------------------------------------------------------------------
if grep -F 'bash <plugin root>/orchestrator/kickoff-defaults.sh' "$SKILL" >/dev/null; then
  ok "SKILL.md 가 보조의 호출 철자를 담는다"
else
  bad "호출 철자" "SKILL.md 에 'bash <plugin root>/orchestrator/kickoff-defaults.sh' 가 없다"
fi
p5n=$(awk '/^\*\*5n — /{f=1; print; next} f&&(/^\*\*5[a-z] — /||/^#/){exit} f' "$SKILL")
case "$p5n" in *deadline-passed*) ok "5n 문단이 deadline-passed 를 담는다" ;; *) bad "5n 문단" "deadline-passed 가 없다" ;; esac
case "$p5n" in *'no environment variable selects it'*) ok "5n 문단이 「no environment variable selects it」 을 그대로 담는다" ;;
  *) bad "5n 문단" "「no environment variable selects it」 문장이 없다" ;; esac

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
