#!/usr/bin/env bash
# Executable specification of plugins/cc-cmds/orchestrator/visual-config.sh.
#
# Every case runs with XDG_CONFIG_HOME and XDG_STATE_HOME pointed into a
# scratch directory and a fake `claude` first on PATH, so no host file is read
# or written.
#
# Cases:
#   account    the four verdicts (same address, another address, no
#              claude-design, the fake claude exiting 1 or printing broken
#              JSON); the log line carries no domain
#   run guard  account, seed and append refuse while CC_PIPELINE_RUN_ID is set;
#              the publish stage's marker CC_PIPELINE_VISUAL_PUBLISH=1 lifts it
#              for account and append, never for seed, and only for the copy
#              beside CC_PIPELINE_GATE
#   lane       the pinned lane from claude-design, read inside a run too; no
#              key or no file is an empty output and exit 1
#   models     defaults, overrides, an out-of-vocabulary value and an unknown
#              key reported
#   seed       copies only when the host file is absent; writes nothing when
#              it exists
#   bans       without a host file prints the seed verbatim under
#              `# 호스트 파일 없음 — 씨앗 사용` and creates no file
#   append     a ban line and a sidecar candidate line are accepted; a
#              duplicate id, a bad kind and a missing host file are refused
#   snapshot   hash match, hash mismatch, no row, no section, and a row whose
#              `인터뷰 기록=` names another file (whose hash does match)
#
# Usage:
#   bash scripts/test-visual-config.sh
#
# Exit codes:
#   0 — every case passed
#   1 — at least one case failed
#   2 — the suite could not run (missing helper or seed)
#
# Compatibility: bash 3.2 (macOS) — no associative arrays, no `mapfile`; BSD
# and GNU userland alike.

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
CONFIG="$repo_root/plugins/cc-cmds/orchestrator/visual-config.sh"
SEED="$repo_root/plugins/cc-cmds/orchestrator/visual-bans.seed"

for need in "$CONFIG" "$SEED"; do
  if [[ ! -f "$need" ]]; then
    echo "test-visual-config: missing $need" >&2
    exit 2
  fi
done

passed=0
failures=0
pass() { passed=$((passed + 1)); echo "PASS: $1"; }
fail() { failures=$((failures + 1)); echo "FAIL: $1" >&2; }

T=$(mktemp -d "${TMPDIR:-/tmp}/test-visual-config.XXXXXX")
trap 'rm -rf "$T"' EXIT

mkdir -p "$T/bin"
cat > "$T/bin/claude" <<'STUB'
#!/usr/bin/env bash
case "${FAKE_CLAUDE_MODE:-ok}" in
  ok) printf '{\n  "loggedIn": true,\n  "email": "%s",\n  "subscriptionType": "max"\n}\n' "${FAKE_CLAUDE_EMAIL:-}" ;;
  fail) echo "not logged in" >&2; exit 1 ;;
  broken) printf '{ "email": "%s", \n' "${FAKE_CLAUDE_EMAIL:-}" ;;
esac
STUB
chmod +x "$T/bin/claude"

# vc <home> [VAR=value...] -- <args...> — run the helper under a scratch home;
# stdout and stderr land in $T/out and $T/err, the exit status in $RC.
RC=0
vc() {
  local home=$1
  shift
  local -a envs=()
  while [ "$1" != -- ]; do envs+=("$1"); shift; done
  shift
  RC=0
  env -u CC_PIPELINE_RUN_ID -u CC_PIPELINE_MANIFEST -u CC_PIPELINE_GATE -u CC_PIPELINE_VISUAL_PUBLISH \
    PATH="$T/bin:$PATH" \
    XDG_CONFIG_HOME="$home/config" XDG_STATE_HOME="$home/state" ${envs[@]+"${envs[@]}"} \
    bash "${VC_HELPER:-$CONFIG}" "$@" > "$T/out" 2> "$T/err" || RC=$?
}

# --- account ------------------------------------------------------------------
H="$T/h-account"
mkdir -p "$H/config/cc-cmds"
printf '%s\n' '# 고정 좌석' 'account = Design.Owner@example.com' > "$H/config/cc-cmds/claude-design"
LOG="$H/state/cc-cmds/claude-design-account.log"

vc "$H" FAKE_CLAUDE_EMAIL=design.owner@EXAMPLE.com -- account
[ "$RC" = 0 ] && grep -q '계정 판정: 일치' "$T/out" && pass "account: 같은 주소(대소문자 무시)는 일치, 종료 0" || fail "account 일치 = ${RC} $(cat "$T/out")"
vc "$H" FAKE_CLAUDE_EMAIL=someone.else@example.com -- account
[ "$RC" = 1 ] && grep -q '계정 판정: 불일치' "$T/out" && pass "account: 다른 주소는 불일치, 종료 1" || fail "account 불일치 = ${RC} $(cat "$T/out")"
grep -q '고칠 길' "$T/out" && grep -qF "$LOG" "$T/out" && pass "account: 멈춤 문면에 로그 경로와 고칠 길이 있다" || fail "account 멈춤 문면에 로그 경로·고칠 길이 없다"
vc "$H" FAKE_CLAUDE_MODE=fail FAKE_CLAUDE_EMAIL=design.owner@example.com -- account
[ "$RC" = 1 ] && grep -q '계정 판정: 판독실패' "$T/out" && pass "account: 가짜 claude 종료 1 은 판독실패" || fail "account 종료 1 = ${RC} $(cat "$T/out")"
vc "$H" FAKE_CLAUDE_MODE=broken FAKE_CLAUDE_EMAIL=design.owner@example.com -- account
[ "$RC" = 1 ] && grep -q '계정 판정: 판독실패' "$T/out" && pass "account: 깨진 JSON 은 판독실패" || fail "account 깨진 JSON = ${RC} $(cat "$T/out")"
H2="$T/h-unset"
mkdir -p "$H2/config"
vc "$H2" FAKE_CLAUDE_EMAIL=design.owner@example.com -- account
[ "$RC" = 1 ] && grep -q '계정 판정: 미설정' "$T/out" && pass "account: claude-design 없음은 미설정" || fail "account 미설정 = ${RC} $(cat "$T/out")"
if [ -f "$LOG" ] && [ "$(grep -c . "$LOG")" = 4 ]; then
  pass "account: 판독마다 로그 한 줄"
else
  fail "account 로그 줄 수가 4 가 아니다"
fi
if grep -q '@' "$LOG" || grep -qi 'example\.com' "$LOG" || grep -q '@' "$T/out"; then
  fail "account 로그나 출력에 도메인이 남았다"
else
  pass "account: 로그와 출력에 @ 뒤 도메인이 없다"
fi
grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z 불일치 판독=someone\.else 기대=Design\.Owner$' "$LOG" \
  && pass "account: 로그 줄은 시각·판정·두 로컬 부분" || fail "account 로그 줄 꼴이 틀렸다: $(sed -n 2p "$LOG")"

# --- run guard ----------------------------------------------------------------
for sub in account seed "append x"; do
  # shellcheck disable=SC2086
  vc "$H" CC_PIPELINE_RUN_ID=20261012-deadbeef -- $sub
  [ "$RC" = 2 ] && grep -q '런 안에서는 거절한다' "$T/err" && pass "런 안에서 ${sub%% *} 는 거절 (종료 2)" || fail "런 안 ${sub%% *} = ${RC}"
done
# The publish stage's marker lifts the guard for account and append only, and
# only for the copy beside the gate the stage was launched with.
GATE_BESIDE="$(dirname "$CONFIG")/gate.sh"
vc "$H" CC_PIPELINE_RUN_ID=20261012-deadbeef CC_PIPELINE_VISUAL_PUBLISH=1 CC_PIPELINE_GATE="$GATE_BESIDE" FAKE_CLAUDE_EMAIL=design.owner@example.com -- account
[ "$RC" = 0 ] && grep -q '계정 판정: 일치' "$T/out" && pass "발행 표지가 있으면 런 안에서도 account 를 판독한다" || fail "발행 표지 account = ${RC} $(cat "$T/err")"
vc "$H" CC_PIPELINE_RUN_ID=20261012-deadbeef CC_PIPELINE_VISUAL_PUBLISH=1 CC_PIPELINE_GATE="$GATE_BESIDE" -- append x
[ "$RC" != 2 ] && ! grep -q '런 안에서는 거절한다' "$T/err" && pass "발행 표지가 있으면 런 안에서도 append 가 줄 검사까지 간다" || fail "발행 표지 append = ${RC} $(cat "$T/err")"
# A copy of the helper that is not beside the stage's gate stays refused under
# the marker: the run's source checkout or a worktree copy, and a marker with no
# gate at all.
mkdir -p "$T/other-copy"
cp "$CONFIG" "$SEED" "$T/other-copy/"
for sub in account "append x"; do
  # shellcheck disable=SC2086
  VC_HELPER="$T/other-copy/visual-config.sh" vc "$H" CC_PIPELINE_RUN_ID=20261012-deadbeef CC_PIPELINE_VISUAL_PUBLISH=1 CC_PIPELINE_GATE="$GATE_BESIDE" FAKE_CLAUDE_EMAIL=design.owner@example.com -- $sub
  [ "$RC" = 2 ] && grep -q '런 안에서는 거절한다' "$T/err" && pass "게이트 옆이 아닌 사본은 발행 표지가 있어도 ${sub%% *} 를 거절 (종료 2)" || fail "다른 사본 ${sub%% *} = ${RC}"
  # shellcheck disable=SC2086
  vc "$H" CC_PIPELINE_RUN_ID=20261012-deadbeef CC_PIPELINE_VISUAL_PUBLISH=1 FAKE_CLAUDE_EMAIL=design.owner@example.com -- $sub
  [ "$RC" = 2 ] && grep -q '런 안에서는 거절한다' "$T/err" && pass "스테이지 게이트 경로 없이 발행 표지만 있으면 ${sub%% *} 를 거절 (종료 2)" || fail "게이트 경로 없는 표지 ${sub%% *} = ${RC}"
done
vc "$H" CC_PIPELINE_RUN_ID=20261012-deadbeef CC_PIPELINE_VISUAL_PUBLISH=1 CC_PIPELINE_GATE="$GATE_BESIDE" -- seed
[ "$RC" = 2 ] && grep -q '런 안에서는 거절한다' "$T/err" && pass "발행 표지가 있어도 seed 는 런 안에서 거절 (종료 2)" || fail "발행 표지 seed = ${RC}"
vc "$H" CC_PIPELINE_RUN_ID=20261012-deadbeef CC_PIPELINE_VISUAL_PUBLISH=0 -- account
[ "$RC" = 2 ] && pass "표지 값이 1 이 아니면 account 는 그대로 거절" || fail "표지 0 account = ${RC}"

# --- lane ---------------------------------------------------------------------
HL="$T/h-lane"
mkdir -p "$HL/config/cc-cmds"
printf '%s\n' '# 고정 좌석' 'account = design.owner@example.com' > "$HL/config/cc-cmds/claude-design"
vc "$HL" CC_PIPELINE_RUN_ID=20261012-deadbeef -- lane
[ "$RC" = 1 ] && [ ! -s "$T/out" ] && pass "lane: 키가 없으면 빈 출력과 종료 1" || fail "lane 없음 = ${RC} $(cat "$T/out")"
printf '%s\n' '  lane =  u2  ' >> "$HL/config/cc-cmds/claude-design"
vc "$HL" CC_PIPELINE_RUN_ID=20261012-deadbeef -- lane
[ "$RC" = 0 ] && [ "$(cat "$T/out")" = "u2" ] && pass "lane: 런 안에서도 읽고 앞뒤 공백을 다듬는다" || fail "lane 판독 = ${RC} $(cat "$T/out")"
printf '%s\n' 'lane = u3' >> "$HL/config/cc-cmds/claude-design"
vc "$HL" -- lane
[ "$RC" = 0 ] && [ "$(cat "$T/out")" = "u3" ] && pass "lane: 여러 줄이면 마지막 줄" || fail "lane 마지막 줄 = ${RC} $(cat "$T/out")"
vc "$T/h-unset" -- lane
[ "$RC" = 1 ] && [ ! -s "$T/out" ] && pass "lane: 호스트 파일이 없으면 종료 1" || fail "lane 파일 없음 = ${RC}"

# --- models -------------------------------------------------------------------
H="$T/h-models"
mkdir -p "$H/config"
vc "$H" -- models
cat > "$T/models.want" <<'EOF'
ds-generate = fable | 기본값
screen-generate = opus | 기본값
polish = fable | 기본값
implement-large = fable | 기본값
implement-large-threshold = 300 | 기본값
EOF
[ "$RC" = 0 ] && cmp -s "$T/out" "$T/models.want" && pass "models: 파일이 없으면 기본값 다섯 줄" || fail "models 기본값 출력이 다르다: $(cat "$T/out")"
mkdir -p "$H/config/cc-cmds"
printf '%s\n' '# 호스트' 'screen-generate = sonnet' 'polish = gpt-9' 'implement-large-threshold = 450' 'colour = red' > "$H/config/cc-cmds/visual-models"
vc "$H" -- models
grep -qxF 'screen-generate = sonnet | 호스트 설정' "$T/out" && pass "models: 어휘 안 덮어쓰기" || fail "models 덮어쓰기 = $(cat "$T/out")"
grep -qxF 'implement-large-threshold = 450 | 호스트 설정' "$T/out" && pass "models: 문턱 덮어쓰기" || fail "models 문턱 = $(cat "$T/out")"
grep -qxF 'polish = fable | 기본값' "$T/out" && grep -q "polish 의 값 'gpt-9' 는 어휘 밖" "$T/err" \
  && pass "models: 어휘 밖 값은 기본값 + 보고" || fail "models 어휘 밖 = $(cat "$T/out") / $(cat "$T/err")"
grep -q "모르는 키 'colour'" "$T/err" && pass "models: 모르는 키 보고" || fail "models 모르는 키 보고가 없다: $(cat "$T/err")"

# --- bans and seed ------------------------------------------------------------
H="$T/h-bans"
mkdir -p "$H/config"
vc "$H" -- bans
{ echo '# 호스트 파일 없음 — 씨앗 사용'; cat "$SEED"; } > "$T/bans.want"
[ "$RC" = 0 ] && cmp -s "$T/out" "$T/bans.want" && pass "bans: 호스트 파일이 없으면 씨앗 그대로 + 보고" || fail "bans 씨앗 출력이 다르다"
[ ! -e "$H/config/cc-cmds" ] && pass "bans: 설정 디렉터리에 아무것도 생기지 않는다" || fail "bans 가 설정 디렉터리를 만들었다"
vc "$H" -- seed
BF="$H/config/cc-cmds/visual-bans"
[ "$RC" = 0 ] && cmp -s "$BF" "$SEED" && pass "seed: 호스트 파일이 없으면 씨앗을 복사" || fail "seed 복사 = ${RC}"
perm=$(ls -ld "$H/config/cc-cmds" | cut -c1-10)
[ "$perm" = drwx------ ] && pass "seed: 새 디렉터리는 700" || fail "seed 디렉터리 권한 = ${perm}"
perm=$(ls -l "$BF" | cut -c1-10)
[ "$perm" = -rw-r--r-- ] && pass "seed: 파일은 644" || fail "seed 파일 권한 = ${perm}"
printf '%s\n' 'mine | 판단 | 사람이 고친 줄 | -' > "$BF"
vc "$H" -- seed
[ "$RC" = 0 ] && [ "$(cat "$BF")" = 'mine | 판단 | 사람이 고친 줄 | -' ] && pass "seed: 파일이 있으면 아무것도 쓰지 않는다" || fail "seed 가 기존 파일을 건드렸다"
vc "$H" -- bans
[ "$(head -n 1 "$T/out")" = '# 출처: 호스트 파일' ] && grep -qxF 'mine | 판단 | 사람이 고친 줄 | -' "$T/out" \
  && pass "bans: 호스트 파일이 있으면 그것을 낸다" || fail "bans 호스트 출력 = $(cat "$T/out")"

# --- append -------------------------------------------------------------------
vc "$H" -- append 'heavy-shadow | 마크업 | 큰 그림자 | box-shadow[[:space:]]*:[^;]*[4-9][0-9]px'
[ "$RC" = 0 ] && grep -qxF 'heavy-shadow | 마크업 | 큰 그림자 | box-shadow[[:space:]]*:[^;]*[4-9][0-9]px' "$BF" \
  && pass "append: 금지 줄을 덧붙인다" || fail "append 금지 줄 = ${RC} $(cat "$T/err")"
vc "$H" -- append '- `ticker-tape` | 판단 | 흐르는 띠 장식 | - — 2회 home'
[ "$RC" = 0 ] && grep -qxF 'ticker-tape | 판단 | 흐르는 띠 장식 | -' "$BF" \
  && pass "append: 사이드카 금지 후보 줄을 금지 줄로 바꿔 덧붙인다" || fail "append 후보 줄 = ${RC} $(cat "$T/err")"
vc "$H" -- append 'heavy-shadow | 판단 | 다시 | -'
[ "$RC" = 1 ] && grep -q "이미 있다" "$T/err" && pass "append: 같은 id 는 거절" || fail "append 중복 = ${RC}"
vc "$H" -- append 'x-y | 색 | 종류가 틀림 | -'
[ "$RC" = 1 ] && pass "append: 종류 밖은 거절" || fail "append 종류 밖 = ${RC}"
vc "$H" -- append 'judge | 판단 | 패턴이 붙은 판단 | foo'
[ "$RC" = 1 ] && pass "append: 판단 항목에 패턴이 있으면 거절" || fail "append 판단+패턴 = ${RC}"
vc "$H" -- append 'brk | 마크업 | 깨진 패턴 | (oops'
[ "$RC" = 1 ] && pass "append: grep -E 로 읽히지 않는 패턴은 거절" || fail "append 깨진 패턴 = ${RC}"
H3="$T/h-nohost"
mkdir -p "$H3/config"
vc "$H3" -- append 'fresh | 판단 | 새 항목 | -'
[ "$RC" = 1 ] && grep -q '먼저 visual-config.sh seed' "$T/err" && [ ! -e "$H3/config/cc-cmds" ] \
  && pass "append: 호스트 파일이 없으면 거절하고 아무것도 만들지 않는다" || fail "append 호스트 없음 = ${RC}"

# --- snapshot -----------------------------------------------------------------
R="$T/repo"
mkdir -p "$R/docs/pipeline-run"
(cd "$R" && git init -q)
RUN=20261012-0badc0de
MAN="$R/docs/pipeline-run/${RUN}.md"
REC="$R/docs/pipeline-run/${RUN}.interview.md"
cat > "$REC" <<'EOF'
# 인터뷰 기록

## 시각 방향

방향 문면.

### 모델값

```
screen-generate = opus
polish = fable
```

### 금지 목록

```
pill-button | 마크업 | 알약 버튼 | border-radius[[:space:]]*:[^;}]*9999px
cream-background | 판단 | 크림 바탕 | -
```

## 다른 절

```
### 모델값
가짜
```
EOF
cp "$REC" "$R/docs/pipeline-run/other.interview.md"
write_manifest() { # <rel path> <sha>
  printf '%s\n' '# 매니페스트' '' '## 인가' '' "- \`사전 인가\` | 인터뷰 기록=$1 | sha256=$2" > "$MAN"
}
snap() {
  RC=0
  env -u CC_PIPELINE_RUN_ID PATH="$T/bin:$PATH" XDG_CONFIG_HOME="$T/none/config" \
    CC_PIPELINE_MANIFEST="$MAN" CC_PIPELINE_RUN_ID="$RUN" bash "$CONFIG" snapshot "$@" > "$T/out" 2> "$T/err" || RC=$?
}
SHA=$(shasum -a 256 "$REC" | awk '{print $1}')
write_manifest "docs/pipeline-run/${RUN}.interview.md" "$SHA"
snap
cat > "$T/snap.want" <<'EOF'
### 모델값
screen-generate = opus
polish = fable
### 금지 목록
pill-button | 마크업 | 알약 버튼 | border-radius[[:space:]]*:[^;}]*9999px
cream-background | 판단 | 크림 바탕 | -
EOF
[ "$RC" = 0 ] && cmp -s "$T/out" "$T/snap.want" && pass "snapshot: 해시가 맞으면 두 하위 블록 사본" || fail "snapshot 일치 = ${RC} $(cat "$T/out")"
snap --part bans
[ "$RC" = 0 ] && [ "$(head -n 1 "$T/out")" = 'pill-button | 마크업 | 알약 버튼 | border-radius[[:space:]]*:[^;}]*9999px' ] \
  && pass "snapshot --part bans 는 금지 목록만" || fail "snapshot --part bans = $(cat "$T/out")"
write_manifest "docs/pipeline-run/${RUN}.interview.md" "$(printf '%064d' 0)"
snap
[ "$RC" = 1 ] && grep -q '^시각 설정 사본 불일치 — 기록의 sha256' "$T/out" && pass "snapshot: 해시 불일치" || fail "snapshot 해시 불일치 = ${RC} $(cat "$T/out")"
printf '%s\n' '# 매니페스트' '' '## 인가' > "$MAN"
snap
[ "$RC" = 1 ] && grep -q '사전 인가 행이 없다' "$T/out" && pass "snapshot: 행 없음" || fail "snapshot 행 없음 = ${RC} $(cat "$T/out")"
write_manifest "docs/pipeline-run/other.interview.md" "$SHA"
snap
[ "$RC" = 1 ] && grep -q '경로 관례의 기록과 다른 파일' "$T/out" && pass "snapshot: 다른 파일을 가리키는 행은 해시가 맞아도 불일치" || fail "snapshot 다른 파일 = ${RC} $(cat "$T/out")"
printf '%s\n' '# 인터뷰 기록' '' '## 다른 절' > "$REC"
write_manifest "docs/pipeline-run/${RUN}.interview.md" "$(shasum -a 256 "$REC" | awk '{print $1}')"
snap
[ "$RC" = 1 ] && grep -q '## 시각 방향 절이 없다' "$T/out" && pass "snapshot: 절 없음" || fail "snapshot 절 없음 = ${RC} $(cat "$T/out")"

echo
echo "passed=${passed} failures=${failures}"
[ "$failures" = 0 ] || exit 1
