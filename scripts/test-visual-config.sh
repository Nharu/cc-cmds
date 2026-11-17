#!/usr/bin/env bash
# Executable specification of plugins/cc-cmds/orchestrator/visual-config.sh.
#
# Every case runs with XDG_CONFIG_HOME and XDG_STATE_HOME pointed into a
# scratch directory and a fake `claude` first on PATH, so no host file is read
# or written.
#
# Cases:
#   account    the verdicts of a new document against the allow list (same
#              address, another address, no claude-design, the fake claude
#              exiting 1 or printing broken JSON); the log line carries no
#              domain; a missing document argument or one that does not resolve
#              is a usage error
#   run guard  account, record, seed, assign and append refuse while
#              CC_PIPELINE_RUN_ID is set; the publish stage's marker
#              CC_PIPELINE_VISUAL_PUBLISH=1 lifts it for account, record and
#              append, never for seed or assign, and only for the copy beside
#              CC_PIPELINE_GATE
#   rule       the five rows of the expected-account rule in order: the
#              run-local record first, the account record (and its three broken
#              forms, and a disagreement with the migration record), the
#              document-level migration record, a published sidecar with no
#              record (미지정), a new document (허용 / 미설정); `expect` prints
#              each kind
#   allowed    the union of `allow` lines and the last `account`, case-folded
#              duplicates and bad values dropped, an empty list exits 1
#   record     each branch, the link race lost to an equal or a different
#              record
#   assign     outside the allow list, an equal record writes nothing, a
#              different record needs --replace, a migration record's account
#              cannot be replaced
#   lane       the pinned lane from claude-design, read inside a run too; no
#              key or no file is an empty output and exit 1
#   run record the run-local migration record `${CC_PIPELINE_RUN_DIR}/visual-lane`
#              replaces the host `lane` and the allow list (an inheriting
#              `**승계**` record included); a broken record is 판독실패 for
#              account and exit 1 for lane, never the host file
#   expect     the expected account by the rule `account` uses: the allow
#              list, a record's `**계정**`, `손상` for a broken record, `미설정`
#              with no value; allowed inside a run with no marker
#   share      the `share` address from claude-design, read inside a run too;
#              no key, an empty value or no file is an empty output and exit 1
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
    -u CC_PIPELINE_RUN_DIR \
    PATH="$T/bin:$PATH" \
    XDG_CONFIG_HOME="$home/config" XDG_STATE_HOME="$home/state" ${envs[@]+"${envs[@]}"} \
    bash "${VC_HELPER:-$CONFIG}" "$@" > "$T/out" 2> "$T/err" || RC=$?
}

# A design document in a scratch repository: the account record, the
# document-level migration record and the sidecar sit under its base.
DR="$T/drepo"
mkdir -p "$DR/docs"
(cd "$DR" && git init -q)
DOC="$DR/docs/feature.md"
printf '%s\n' '# 기능 설계' > "$DOC"
DRP=$(cd "$DR" && pwd -P)
ACCT="$DRP/docs/visual-account/docs-feature.md"
DLANE="$DRP/docs/visual-lane/docs-feature.md"
SIDE="$DRP/docs/visual/docs-feature.md"
acct_head() { # <owner-doc>
  printf '<!-- cc-visual-account v1; writer=visual-config.sh|gate; reader=visual-config.sh,gate.sh,visual,visual-publish-unattended; owner-doc=%s -->\n' "$1"
}
write_acct() { # <address> [owner-doc]
  mkdir -p "$(dirname "$ACCT")"
  { acct_head "${2:-docs/feature.md}"; printf '**계정**: %s\n' "$1"; printf '**출처**: 지정 · 2026-11-17T00:00:00Z\n'; } > "$ACCT"
}
write_dlane() { # <address>
  mkdir -p "$(dirname "$DLANE")"
  printf '%s\n' '<!-- cc-visual-lane-doc v1; writer=gate; reader=run.sh,visual-config.sh -->' \
    '**레인**: u3' "**계정**: $1" '**출처**: 20261101-00000000 · 이관 1 · 2026-11-07T00:00:00Z' > "$DLANE"
}
write_side() { # <artifact value> [owner-doc]
  mkdir -p "$(dirname "$SIDE")"
  printf '%s\n' '# 시각 사이드카' "<!-- cc-visual v1; writer=visual; owner-doc=${2:-docs/feature.md}; reader=implement -->" \
    '**상태**: 발행됨' '' '### 화면 home' "**아티팩트**: $1" > "$SIDE"
}
clear_doc_state() { rm -rf "$DRP/docs/visual-account" "$DRP/docs/visual-lane" "$DRP/docs/visual"; }

# --- account ------------------------------------------------------------------
H="$T/h-account"
mkdir -p "$H/config/cc-cmds"
printf '%s\n' '# 고정 좌석' 'account = Design.Owner@example.com' > "$H/config/cc-cmds/claude-design"
LOG="$H/state/cc-cmds/claude-design-account.log"

vc "$H" FAKE_CLAUDE_EMAIL=design.owner@example.com -- account
[ "$RC" = 2 ] && [ ! -e "$LOG" ] && pass "account: 문서 인자가 없으면 사용법 오류 (종료 2)" || fail "account 인자 없음 = ${RC}"
vc "$H" FAKE_CLAUDE_EMAIL=design.owner@example.com -- account "$T/no-such.md"
[ "$RC" = 2 ] && [ ! -e "$LOG" ] && pass "account: 없는 문서는 사용법 오류 (종료 2)" || fail "account 없는 문서 = ${RC}"
printf '%s\n' '# 밖' > "$T/outside.md"
vc "$H" FAKE_CLAUDE_EMAIL=design.owner@example.com -- expect "$T/outside.md"
[ "$RC" = 2 ] && [ ! -s "$T/out" ] && pass "expect: git 밖 문서는 사용법 오류 (종료 2)" || fail "expect git 밖 = ${RC} $(cat "$T/out")"
vc "$H" FAKE_CLAUDE_EMAIL=design.owner@EXAMPLE.com -- account "$DOC"
[ "$RC" = 0 ] && grep -q '계정 판정: 일치 (판독 design.owner, 기대 허용 목록)' "$T/out" && grep -qxF "기준: 허용 목록 $H/config/cc-cmds/claude-design" "$T/out" \
  && pass "account: 새 문서는 허용 목록 판정, 같은 주소(대소문자 무시)는 일치, 종료 0" || fail "account 일치 = ${RC} $(cat "$T/out")"
vc "$H" FAKE_CLAUDE_EMAIL=someone.else@example.com -- account "$DOC"
[ "$RC" = 1 ] && grep -q '계정 판정: 불일치' "$T/out" && grep -q '로그인 계정이 허용 목록에 없다' "$T/out" \
  && pass "account: 목록 밖 주소는 불일치, 종료 1" || fail "account 불일치 = ${RC} $(cat "$T/out")"
grep -q '고칠 길' "$T/out" && grep -qF "$LOG" "$T/out" && pass "account: 멈춤 문면에 로그 경로와 고칠 길이 있다" || fail "account 멈춤 문면에 로그 경로·고칠 길이 없다"
vc "$H" FAKE_CLAUDE_MODE=fail FAKE_CLAUDE_EMAIL=design.owner@example.com -- account "$DOC"
[ "$RC" = 1 ] && grep -q '계정 판정: 판독실패' "$T/out" && pass "account: 가짜 claude 종료 1 은 판독실패" || fail "account 종료 1 = ${RC} $(cat "$T/out")"
vc "$H" FAKE_CLAUDE_MODE=broken FAKE_CLAUDE_EMAIL=design.owner@example.com -- account "$DOC"
[ "$RC" = 1 ] && grep -q '계정 판정: 판독실패' "$T/out" && pass "account: 깨진 JSON 은 판독실패" || fail "account 깨진 JSON = ${RC} $(cat "$T/out")"
H2="$T/h-unset"
mkdir -p "$H2/config"
vc "$H2" FAKE_CLAUDE_EMAIL=design.owner@example.com -- account "$DOC"
[ "$RC" = 1 ] && grep -q '계정 판정: 미설정' "$T/out" && grep -q "'allow = <주소>'" "$T/out" \
  && pass "account: claude-design 없음은 미설정이고 allow 줄을 말한다" || fail "account 미설정 = ${RC} $(cat "$T/out")"
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
grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z 불일치 판독=someone\.else 기대=허용목록$' "$LOG" \
  && pass "account: 로그 줄은 시각·판정·로컬 부분" || fail "account 로그 줄 꼴이 틀렸다: $(sed -n 2p "$LOG")"

# --- run guard ----------------------------------------------------------------
for sub in "account $DOC" "record $DOC" seed "assign $DOC design.owner@example.com" "append x"; do
  # shellcheck disable=SC2086
  vc "$H" CC_PIPELINE_RUN_ID=20261012-deadbeef -- $sub
  [ "$RC" = 2 ] && grep -q '런 안에서는 거절한다' "$T/err" && pass "런 안에서 ${sub%% *} 는 거절 (종료 2)" || fail "런 안 ${sub%% *} = ${RC}"
done
[ ! -e "$ACCT" ] && pass "런 안에서 거절된 record·assign 은 계정 기록을 만들지 않는다" || fail "런 안 거절이 계정 기록을 만들었다"
# The publish stage's marker lifts the guard for account, record and append
# only, and only for the copy beside the gate the stage was launched with.
GATE_BESIDE="$(dirname "$CONFIG")/gate.sh"
vc "$H" CC_PIPELINE_RUN_ID=20261012-deadbeef CC_PIPELINE_VISUAL_PUBLISH=1 CC_PIPELINE_GATE="$GATE_BESIDE" FAKE_CLAUDE_EMAIL=design.owner@example.com -- account "$DOC"
[ "$RC" = 0 ] && grep -q '계정 판정: 일치' "$T/out" && pass "발행 표지가 있으면 런 안에서도 account 를 판독한다" || fail "발행 표지 account = ${RC} $(cat "$T/err")"
vc "$H" CC_PIPELINE_RUN_ID=20261012-deadbeef CC_PIPELINE_VISUAL_PUBLISH=1 CC_PIPELINE_GATE="$GATE_BESIDE" -- append x
[ "$RC" != 2 ] && ! grep -q '런 안에서는 거절한다' "$T/err" && pass "발행 표지가 있으면 런 안에서도 append 가 줄 검사까지 간다" || fail "발행 표지 append = ${RC} $(cat "$T/err")"
vc "$H" CC_PIPELINE_RUN_ID=20261012-deadbeef CC_PIPELINE_VISUAL_PUBLISH=1 CC_PIPELINE_GATE="$GATE_BESIDE" -- assign "$DOC" design.owner@example.com
[ "$RC" = 2 ] && grep -q '런 안에서는 거절한다' "$T/err" && [ ! -e "$ACCT" ] \
  && pass "발행 표지가 있어도 assign 은 런 안에서 거절 (종료 2)" || fail "발행 표지 assign = ${RC}"
vc "$H" CC_PIPELINE_RUN_ID=20261012-deadbeef CC_PIPELINE_VISUAL_PUBLISH=1 CC_PIPELINE_GATE="$GATE_BESIDE" FAKE_CLAUDE_EMAIL=design.owner@example.com -- record "$DOC"
[ "$RC" = 0 ] && [ -f "$ACCT" ] && grep -qxF '**계정**: design.owner@example.com' "$ACCT" \
  && pass "발행 표지가 있으면 런 안에서도 record 가 로그인 계정을 쓴다" || fail "발행 표지 record = ${RC} $(cat "$T/err")"
clear_doc_state
# A copy of the helper that is not beside the stage's gate stays refused under
# the marker: the run's source checkout or a worktree copy, and a marker with no
# gate at all.
mkdir -p "$T/other-copy"
cp "$CONFIG" "$SEED" "$T/other-copy/"
for sub in "account $DOC" "record $DOC" "append x"; do
  # shellcheck disable=SC2086
  VC_HELPER="$T/other-copy/visual-config.sh" vc "$H" CC_PIPELINE_RUN_ID=20261012-deadbeef CC_PIPELINE_VISUAL_PUBLISH=1 CC_PIPELINE_GATE="$GATE_BESIDE" FAKE_CLAUDE_EMAIL=design.owner@example.com -- $sub
  [ "$RC" = 2 ] && grep -q '런 안에서는 거절한다' "$T/err" && pass "게이트 옆이 아닌 사본은 발행 표지가 있어도 ${sub%% *} 를 거절 (종료 2)" || fail "다른 사본 ${sub%% *} = ${RC}"
  # shellcheck disable=SC2086
  vc "$H" CC_PIPELINE_RUN_ID=20261012-deadbeef CC_PIPELINE_VISUAL_PUBLISH=1 FAKE_CLAUDE_EMAIL=design.owner@example.com -- $sub
  [ "$RC" = 2 ] && grep -q '런 안에서는 거절한다' "$T/err" && pass "스테이지 게이트 경로 없이 발행 표지만 있으면 ${sub%% *} 를 거절 (종료 2)" || fail "게이트 경로 없는 표지 ${sub%% *} = ${RC}"
done
vc "$H" CC_PIPELINE_RUN_ID=20261012-deadbeef CC_PIPELINE_VISUAL_PUBLISH=1 CC_PIPELINE_GATE="$GATE_BESIDE" -- seed
[ "$RC" = 2 ] && grep -q '런 안에서는 거절한다' "$T/err" && pass "발행 표지가 있어도 seed 는 런 안에서 거절 (종료 2)" || fail "발행 표지 seed = ${RC}"
vc "$H" CC_PIPELINE_RUN_ID=20261012-deadbeef CC_PIPELINE_VISUAL_PUBLISH=0 -- account "$DOC"
[ "$RC" = 2 ] && pass "표지 값이 1 이 아니면 account 는 그대로 거절" || fail "표지 0 account = ${RC}"
[ ! -e "$ACCT" ] && pass "다른 사본·표지 없는 record 는 계정 기록을 만들지 않는다" || fail "거절된 record 가 계정 기록을 만들었다"

# --- the expected-account rule ------------------------------------------------
# Rows in order: run-local record, account record, document-level migration
# record, a published sidecar (미지정), a new document (허용 / 미설정).
HD="$T/h-rule"
mkdir -p "$HD/config/cc-cmds" "$HD/run"
printf '%s\n' 'allow = first@example.com' 'account = second@example.com' > "$HD/config/cc-cmds/claude-design"
clear_doc_state
vc "$HD" -- expect "$DOC"
[ "$RC" = 0 ] && [ "$(cat "$T/out")" = '허용 first@example.com second@example.com' ] \
  && pass "rule 5: 새 문서는 허용 목록 (expect: 허용 …)" || fail "rule 5 허용 = ${RC} $(cat "$T/out")"
vc "$T/h-unset" -- expect "$DOC"
[ "$RC" = 0 ] && [ "$(cat "$T/out")" = '미설정' ] && pass "rule 5: 목록이 비면 미설정" || fail "rule 5 미설정 = ${RC} $(cat "$T/out")"
write_side '(미발행)'
vc "$HD" -- expect "$DOC"
[ "$(cat "$T/out")" = '허용 first@example.com second@example.com' ] && pass "rule 4: 아티팩트가 (미발행) 뿐이면 새 문서" || fail "rule 4 미발행 = $(cat "$T/out")"
write_side 'https://claude.ai/design/p/0000-home' 'docs/other.md'
vc "$HD" -- expect "$DOC"
[ "$(cat "$T/out")" = '허용 first@example.com second@example.com' ] && pass "rule 4: 다른 문서의 사이드카는 이 문서의 발행이 아니다" || fail "rule 4 다른 owner = $(cat "$T/out")"
write_side 'https://claude.ai/design/p/0000-home'
vc "$HD" -- expect "$DOC"
[ "$RC" = 0 ] && [ "$(cat "$T/out")" = "미지정 $SIDE" ] && pass "rule 4: 발행된 사이드카에 기록이 없으면 미지정" || fail "rule 4 미지정 = ${RC} $(cat "$T/out")"
vc "$HD" FAKE_CLAUDE_EMAIL=first@example.com -- account "$DOC"
[ "$RC" = 1 ] && grep -q '계정 판정: 미지정' "$T/out" && grep -qF "visual-config.sh assign $DOC <주소>" "$T/out" && grep -q "allow' 줄을 먼저 더한다" "$T/out" \
  && pass "account: 미지정은 assign 과 allow 줄을 밝히고 멈춘다" || fail "account 미지정 = ${RC} $(cat "$T/out")"
write_dlane third@example.com
vc "$HD" -- expect "$DOC"
[ "$(cat "$T/out")" = '기록 third@example.com 문서이관' ] && pass "rule 3: 문서 이관 기록이 사이드카보다 앞선다" || fail "rule 3 = $(cat "$T/out")"
printf '%s\n' '<!-- other -->' '**계정**: third@example.com' > "$DLANE"
vc "$HD" -- expect "$DOC"
[ "$(cat "$T/out")" = "미지정 $SIDE" ] && pass "rule 3: 읽히지 않는 이관 기록은 없는 것" || fail "rule 3 손상 = $(cat "$T/out")"
write_dlane third@example.com
write_acct Third@Example.com
vc "$HD" -- expect "$DOC"
[ "$(cat "$T/out")" = '기록 Third@Example.com 문서기록' ] && pass "rule 2: 계정 기록이 이관 기록보다 앞서고 대소문자만 다르면 같은 계정" || fail "rule 2 = $(cat "$T/out")"
vc "$HD" FAKE_CLAUDE_EMAIL=someone@example.com -- account "$DOC"
[ "$RC" = 1 ] && grep -q '계정 판정: 불일치 (판독 someone, 기대 Third)' "$T/out" && grep -qxF "기준: 문서 계정 기록 $ACCT" "$T/out" \
  && grep -qF "멈춤 — 이 문서는 Third 의 캔버스다 (기록 $ACCT) — 그 계정으로 로그인해 다시 실행한다" "$T/out" \
  && pass "account: 기록 불일치는 기록 계정의 로컬부와 경로를 밝힌다" || fail "account 기록 불일치 = ${RC} $(cat "$T/out")"
grep -q 'example\.com' "$T/out" && fail "account 기록 불일치 문면에 도메인이 있다" || pass "account: 기록 불일치 문면에 도메인이 없다"
vc "$HD" FAKE_CLAUDE_EMAIL=third@example.com -- account "$DOC"
[ "$RC" = 0 ] && grep -q '계정 판정: 일치' "$T/out" && pass "account: 기록과 같은 로그인은 일치" || fail "account 기록 일치 = ${RC} $(cat "$T/out")"
write_acct fourth@example.com
vc "$HD" -- expect "$DOC"
[ "$(cat "$T/out")" = "손상 $ACCT" ] && pass "rule 2: 계정 기록과 이관 기록의 계정이 다르면 손상" || fail "rule 2 어긋남 = $(cat "$T/out")"
rm -f "$DLANE"
for broken in head owner empty; do
  case "$broken" in
    head) printf '%s\n' '<!-- other v1 -->' '**계정**: fourth@example.com' > "$ACCT" ;;
    owner) write_acct fourth@example.com docs/other.md ;;
    empty) { acct_head docs/feature.md; printf '**계정**: \n'; } > "$ACCT" ;;
  esac
  vc "$HD" -- expect "$DOC"
  [ "$RC" = 0 ] && [ "$(cat "$T/out")" = "손상 $ACCT" ] && pass "rule 2: 계정 기록 손상(${broken}) 은 손상이고 다음 줄로 넘어가지 않는다" || fail "rule 2 손상(${broken}) = ${RC} $(cat "$T/out")"
  vc "$HD" FAKE_CLAUDE_EMAIL=first@example.com -- account "$DOC"
  [ "$RC" = 1 ] && grep -q '계정 판정: 판독실패' "$T/out" && grep -qF "$ACCT" "$T/out" \
    && pass "account: 계정 기록 손상(${broken}) 은 판독실패이고 기록 경로를 싣는다" || fail "account 손상(${broken}) = ${RC} $(cat "$T/out")"
done
write_acct fourth@example.com
printf '%s\n' '<!-- cc-visual-lane v1; writer=gate -->' '**레인**: u9' '**계정**: nine@example.com' > "$HD/run/visual-lane"
vc "$HD" CC_PIPELINE_RUN_DIR="$HD/run" -- expect "$DOC"
[ "$(cat "$T/out")" = '기록 nine@example.com 런이관' ] && pass "rule 1: 런 지역 이관 기록이 맨 앞" || fail "rule 1 = $(cat "$T/out")"
vc "$HD" CC_PIPELINE_RUN_DIR="$HD/run" FAKE_CLAUDE_EMAIL=nine@example.com -- account "$DOC"
[ "$RC" = 0 ] && grep -qxF "기준: 런 이관 기록 $HD/run/visual-lane" "$T/out" && pass "account: 런 이관 기록 기준 일치" || fail "account 런이관 = ${RC} $(cat "$T/out")"
vc "$HD" CC_PIPELINE_RUN_DIR="$HD/run" CC_PIPELINE_RUN_ID=20261012-deadbeef -- expect "$DOC"
[ "$RC" = 0 ] && [ "$(cat "$T/out")" = '기록 nine@example.com 런이관' ] && pass "expect <문서>: 런 안에서도 허용" || fail "expect 런 안 = ${RC} $(cat "$T/err")"
rm -f "$HD/run/visual-lane"

# --- allowed ------------------------------------------------------------------
HA="$T/h-allowed"
mkdir -p "$HA/config/cc-cmds"
printf '%s\n' 'account = old@example.com' 'allow =  One@example.com ' 'allow = one@EXAMPLE.com' 'allow = ' \
  'allow = two words@example.com' 'allow = a,b@example.com' 'account = Last@example.com' 'allow = three@example.com' 'lane = u1' \
  > "$HA/config/cc-cmds/claude-design"
vc "$HA" CC_PIPELINE_RUN_ID=20261012-deadbeef -- allowed
printf '%s\n' 'One@example.com' 'Last@example.com' 'three@example.com' > "$T/allowed.want"
[ "$RC" = 0 ] && cmp -s "$T/out" "$T/allowed.want" \
  && pass "allowed: allow 줄과 마지막 account 의 합집합, 중복·잘못된 값 제외, 런 안에서도" || fail "allowed = ${RC} $(cat "$T/out")"
vc "$T/h-unset" -- allowed
[ "$RC" = 1 ] && [ ! -s "$T/out" ] && pass "allowed: 목록이 비면 종료 1" || fail "allowed 빈 목록 = ${RC}"
vc "$H" -- allowed
[ "$RC" = 0 ] && [ "$(cat "$T/out")" = 'Design.Owner@example.com' ] && pass "allowed: account 한 줄 파일은 그 계정 하나" || fail "allowed account 한 줄 = $(cat "$T/out")"
vc "$HA" -- allowed extra
[ "$RC" = 2 ] && pass "allowed: 인자가 있으면 사용법 오류" || fail "allowed 인자 = ${RC}"

# --- record -------------------------------------------------------------------
clear_doc_state
vc "$HD" FAKE_CLAUDE_EMAIL=Second@Example.com -- record "$DOC"
[ "$RC" = 0 ] && [ "$(sed -n 1p "$ACCT")" = "$(acct_head docs/feature.md)" ] && grep -qxF '**계정**: Second@Example.com' "$ACCT" \
  && grep -qE '^\*\*출처\*\*: 발행 · [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$' "$ACCT" \
  && pass "record: 새 문서의 목록 안 로그인을 출처 발행으로 쓴다(표기는 로그인 값)" || fail "record 허용 = ${RC} $(cat "$T/err")"
perm=$(ls -l "$ACCT" | cut -c1-10)
[ "$perm" = -rw-r--r-- ] && pass "record: 기록 파일은 644" || fail "record 권한 = ${perm}"
listing=$(ls -A "$(dirname "$ACCT")")
case "$listing" in .visual-account.*|*"
".visual-account.*) fail "record 임시 파일이 남았다" ;; *) pass "record: 임시 파일을 남기지 않는다" ;; esac
grep -qE ' 기록 판독=Second 기대=허용목록$' "$HD/state/cc-cmds/claude-design-account.log" && pass "record: 로그에 판정 기록 한 줄" || fail "record 로그 = $(cat "$HD/state/cc-cmds/claude-design-account.log" 2>/dev/null)"
before=$(cat "$ACCT")
vc "$HD" FAKE_CLAUDE_EMAIL=second@example.com -- record "$DOC"
[ "$RC" = 0 ] && [ "$(cat "$ACCT")" = "$before" ] && pass "record: 같은 계정의 기록이 있으면 쓰지 않고 종료 0" || fail "record 같은 기록 = ${RC}"
vc "$HD" FAKE_CLAUDE_EMAIL=first@example.com -- record "$DOC"
[ "$RC" = 1 ] && [ "$(cat "$ACCT")" = "$before" ] && pass "record: 다른 계정의 기록은 덮지 않고 종료 1" || fail "record 다른 기록 = ${RC}"
clear_doc_state
vc "$HD" FAKE_CLAUDE_EMAIL=outsider@example.com -- record "$DOC"
[ "$RC" = 1 ] && [ ! -e "$ACCT" ] && pass "record: 목록 밖 로그인은 쓰지 않고 종료 1" || fail "record 목록 밖 = ${RC}"
vc "$HD" FAKE_CLAUDE_MODE=fail -- record "$DOC"
[ "$RC" = 1 ] && [ ! -e "$ACCT" ] && pass "record: 로그인을 읽지 못하면 종료 1" || fail "record 판독 실패 = ${RC}"
vc "$T/h-unset" FAKE_CLAUDE_EMAIL=first@example.com -- record "$DOC"
[ "$RC" = 1 ] && [ ! -e "$ACCT" ] && pass "record: 미설정이면 쓰지 않고 종료 1" || fail "record 미설정 = ${RC}"
write_side 'https://claude.ai/design/p/0000-home'
vc "$HD" FAKE_CLAUDE_EMAIL=first@example.com -- record "$DOC"
[ "$RC" = 1 ] && [ ! -e "$ACCT" ] && pass "record: 미지정(발행된 문서)이면 쓰지 않고 종료 1" || fail "record 미지정 = ${RC}"
write_dlane third@example.com
vc "$HD" FAKE_CLAUDE_EMAIL=Third@example.com -- record "$DOC"
[ "$RC" = 0 ] && [ ! -e "$ACCT" ] && pass "record: 문서 이관 기록과 같은 로그인은 종료 0" || fail "record 문서이관 같음 = ${RC}"
vc "$HD" FAKE_CLAUDE_EMAIL=first@example.com -- record "$DOC"
[ "$RC" = 1 ] && [ ! -e "$ACCT" ] && pass "record: 문서 이관 기록과 다른 로그인은 종료 1" || fail "record 문서이관 다름 = ${RC}"
write_acct fourth@example.com
vc "$HD" FAKE_CLAUDE_EMAIL=first@example.com -- record "$DOC"
[ "$RC" = 1 ] && grep -qxF '**계정**: fourth@example.com' "$ACCT" && pass "record: 손상(두 기록 어긋남)이면 쓰지 않고 종료 1" || fail "record 손상 = ${RC}"
clear_doc_state
printf '%s\n' '<!-- cc-visual-lane v1; writer=gate -->' '**레인**: u9' '**계정**: nine@example.com' > "$HD/run/visual-lane"
vc "$HD" CC_PIPELINE_RUN_DIR="$HD/run" FAKE_CLAUDE_EMAIL=first@example.com -- record "$DOC"
[ "$RC" = 0 ] && [ ! -e "$ACCT" ] && grep -q '런 이관 기록' "$T/out" && pass "record: 런 지역 이관 기록이면 쓰지 않고 종료 0" || fail "record 런이관 = ${RC} $(cat "$T/out")"
rm -f "$HD/run/visual-lane"
# The link race: another writer's record appears between the rule and the link.
# A fake `ln` that writes the winner first stands in for that writer.
mkdir -p "$T/race-bin"
cat > "$T/race-bin/ln" <<STUB
#!/usr/bin/env bash
mkdir -p "$(dirname "$ACCT")"
{ printf '%s\n' '$(acct_head docs/feature.md)'; printf '**계정**: %s\n' "\${RACE_WINNER}"; printf '**출처**: 발행 · 2026-11-17T00:00:00Z\n'; } > "$ACCT"
exec /bin/ln "\$@"
STUB
chmod +x "$T/race-bin/ln"
for winner in First@example.com second@example.com; do
  clear_doc_state
  RC=0
  env -u CC_PIPELINE_RUN_ID -u CC_PIPELINE_RUN_DIR PATH="$T/race-bin:$T/bin:$PATH" RACE_WINNER="$winner" \
    XDG_CONFIG_HOME="$HD/config" XDG_STATE_HOME="$HD/state" FAKE_CLAUDE_EMAIL=first@example.com \
    bash "$CONFIG" record "$DOC" > "$T/out" 2> "$T/err" || RC=$?
  case "$winner" in
    First*) [ "$RC" = 0 ] && grep -qxF "**계정**: $winner" "$ACCT" && pass "record: 경쟁에서 져도 같은 계정이면 종료 0" || fail "record 경쟁 같음 = ${RC} $(cat "$T/err")" ;;
    *) [ "$RC" = 1 ] && grep -qxF "**계정**: $winner" "$ACCT" && pass "record: 경쟁에서 진 다른 계정은 덮지 않고 종료 1" || fail "record 경쟁 다름 = ${RC} $(cat "$T/err")" ;;
  esac
  listing=$(ls -A "$(dirname "$ACCT")")
  case "$listing" in .visual-account.*|*"
".visual-account.*) fail "record 경쟁 뒤 임시 파일이 남았다(${winner})" ;; *) pass "record: 경쟁 뒤에도 임시 파일을 남기지 않는다(${winner})" ;; esac
done
vc "$HD" -- record
[ "$RC" = 2 ] && pass "record: 문서 인자가 없으면 사용법 오류" || fail "record 인자 없음 = ${RC}"

# --- assign -------------------------------------------------------------------
clear_doc_state
vc "$HD" -- assign "$DOC" outsider@example.com
[ "$RC" = 1 ] && [ ! -e "$ACCT" ] && pass "assign: 허용 목록 밖 주소는 거절" || fail "assign 목록 밖 = ${RC}"
vc "$HD" -- assign "$DOC" FIRST@example.com
[ "$RC" = 0 ] && grep -qxF '**계정**: FIRST@example.com' "$ACCT" && grep -qE '^\*\*출처\*\*: 지정 · [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$' "$ACCT" \
  && [ "$(sed -n 1p "$ACCT")" = "$(acct_head docs/feature.md)" ] \
  && pass "assign: 목록 안 주소를 인자 표기 그대로 출처 지정으로 쓴다" || fail "assign 쓰기 = ${RC} $(cat "$T/err")"
before=$(cat "$ACCT")
sleep 1
vc "$HD" -- assign "$DOC" first@example.com
[ "$RC" = 0 ] && [ "$(cat "$ACCT")" = "$before" ] && pass "assign: 같은 값이면 아무것도 쓰지 않고 성공" || fail "assign 같은 값 = ${RC}"
vc "$HD" -- assign "$DOC" second@example.com
[ "$RC" = 1 ] && [ "$(cat "$ACCT")" = "$before" ] && pass "assign: 다른 값은 --replace 없이 거절" || fail "assign 다른 값 = ${RC}"
vc "$HD" -- assign "$DOC" second@example.com --replace
[ "$RC" = 0 ] && grep -qxF '**계정**: second@example.com' "$ACCT" && pass "assign --replace: 다른 값을 덮는다" || fail "assign --replace = ${RC}"
printf '%s\n' '<!-- other -->' > "$ACCT"
vc "$HD" -- assign "$DOC" first@example.com
[ "$RC" = 1 ] && pass "assign: 손상 기록은 --replace 없이 거절" || fail "assign 손상 = ${RC}"
vc "$HD" -- assign "$DOC" first@example.com --replace
[ "$RC" = 0 ] && grep -qxF '**계정**: first@example.com' "$ACCT" && pass "assign --replace: 손상 기록을 덮는다" || fail "assign 손상 --replace = ${RC}"
printf '%s\n' 'allow = third@example.com' >> "$HD/config/cc-cmds/claude-design"
write_dlane third@example.com
vc "$HD" -- assign "$DOC" second@example.com --replace
[ "$RC" = 1 ] && grep -qxF '**계정**: first@example.com' "$ACCT" && pass "assign: 이관 기록과 다른 값은 --replace 로도 거절" || fail "assign 이관 다름 = ${RC}"
vc "$HD" -- assign "$DOC" third@example.com --replace
[ "$RC" = 0 ] && grep -qxF '**계정**: third@example.com' "$ACCT" && pass "assign --replace: 이관 기록의 계정으로 맞춘다" || fail "assign 이관 같음 = ${RC}"
vc "$HD" -- expect "$DOC"
[ "$(cat "$T/out")" = '기록 third@example.com 문서기록' ] && pass "assign 뒤 두 기록이 같아 손상이 풀린다" || fail "assign 뒤 expect = $(cat "$T/out")"
vc "$HD" -- assign "$DOC" third@example.com --force
[ "$RC" = 2 ] && pass "assign: 셋째 인자가 --replace 가 아니면 사용법 오류" || fail "assign 셋째 인자 = ${RC}"
vc "$HD" -- assign "$T/outside.md" first@example.com
[ "$RC" = 2 ] && pass "assign: git 밖 문서는 사용법 오류" || fail "assign git 밖 = ${RC}"
clear_doc_state

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

# --- run-local migration record -----------------------------------------------
# The gate's record `${CC_PIPELINE_RUN_DIR}/visual-lane` replaces the host
# file's `lane` and `account`; a broken record never falls back to the host.
HR="$T/h-record"
mkdir -p "$HR/config/cc-cmds" "$HR/run"
printf '%s\n' 'account = design.owner@example.com' 'lane = pub' > "$HR/config/cc-cmds/claude-design"
RECF="$HR/run/visual-lane"
vc "$HR" CC_PIPELINE_RUN_DIR="$HR/run" -- lane
[ "$RC" = 0 ] && [ "$(cat "$T/out")" = pub ] && pass "이관 기록: 기록이 없으면 lane 은 호스트 파일" || fail "기록 없음 lane = ${RC} $(cat "$T/out")"
vc "$HR" CC_PIPELINE_RUN_DIR="$HR/run" FAKE_CLAUDE_EMAIL=design.owner@example.com -- account "$DOC"
[ "$RC" = 0 ] && grep -q '계정 판정: 일치' "$T/out" && pass "이관 기록: 기록이 없으면 account 는 호스트 파일" || fail "기록 없음 account = ${RC} $(cat "$T/out")"
printf '%s\n' '<!-- cc-visual-lane v1; writer=gate; reader=run.sh,visual-config.sh,visual-publish-unattended -->' \
  '**레인**: u3' '**계정**: unattended.three@example.com' \
  '**이관**: 1 · pub → u3 · reserve · 2026-11-07T00:00:00Z' > "$RECF"
vc "$HR" CC_PIPELINE_RUN_DIR="$HR/run" -- lane
[ "$RC" = 0 ] && [ "$(cat "$T/out")" = u3 ] && pass "이관 기록: lane 은 기록의 **레인**" || fail "기록 lane = ${RC} $(cat "$T/out")"
vc "$HR" CC_PIPELINE_RUN_DIR="$HR/run" FAKE_CLAUDE_EMAIL=unattended.three@example.com -- account "$DOC"
[ "$RC" = 0 ] && grep -q '계정 판정: 일치 (판독 unattended.three, 기대 unattended.three)' "$T/out" \
  && pass "이관 기록: account 의 기대 계정은 기록의 **계정**" || fail "기록 account = ${RC} $(cat "$T/out")"
vc "$HR" CC_PIPELINE_RUN_DIR="$HR/run" FAKE_CLAUDE_EMAIL=design.owner@example.com -- account "$DOC"
[ "$RC" = 1 ] && grep -q '계정 판정: 불일치' "$T/out" && pass "이관 기록: 호스트 계정은 기록이 있으면 불일치" || fail "기록 있음 호스트 계정 = ${RC} $(cat "$T/out")"
printf '%s\n' '<!-- cc-visual-lane v1; writer=gate; reader=run.sh,visual-config.sh,visual-publish-unattended -->' \
  '**레인**: u5' '**계정**: unattended.five@example.com' \
  '**승계**: /base/docs/visual-lane/doc.md · 20261101-00000000 · 2026-11-07T00:00:00Z' > "$RECF"
vc "$HR" CC_PIPELINE_RUN_DIR="$HR/run" -- lane
[ "$RC" = 0 ] && [ "$(cat "$T/out")" = u5 ] && pass "이관 기록: **승계** 줄 기록에서도 lane 은 **레인**" || fail "승계 기록 lane = ${RC} $(cat "$T/out")"
vc "$HR" CC_PIPELINE_RUN_DIR="$HR/run" FAKE_CLAUDE_EMAIL=unattended.five@example.com -- account "$DOC"
[ "$RC" = 0 ] && grep -q '계정 판정: 일치' "$T/out" && pass "이관 기록: **승계** 줄 기록에서도 account 는 **계정**" || fail "승계 기록 account = ${RC} $(cat "$T/out")"
for broken in head nolane emptyacct; do
  case "$broken" in
    head) printf '%s\n' '<!-- other v1 -->' '**레인**: u3' '**계정**: unattended.three@example.com' > "$RECF" ;;
    nolane) printf '%s\n' '<!-- cc-visual-lane v1; writer=gate -->' '**계정**: unattended.three@example.com' > "$RECF" ;;
    emptyacct) printf '%s\n' '<!-- cc-visual-lane v1; writer=gate -->' '**레인**: u3' '**계정**: ' > "$RECF" ;;
  esac
  vc "$HR" CC_PIPELINE_RUN_DIR="$HR/run" FAKE_CLAUDE_EMAIL=design.owner@example.com -- account "$DOC"
  [ "$RC" = 1 ] && grep -q '계정 판정: 판독실패' "$T/out" && grep -qF "$RECF" "$T/out" \
    && pass "이관 기록 손상(${broken}): account 는 판독실패이고 기록 경로를 싣는다(호스트로 떨어지지 않음)" \
    || fail "손상 기록(${broken}) account = ${RC} $(cat "$T/out")"
  vc "$HR" CC_PIPELINE_RUN_DIR="$HR/run" -- lane
  [ "$RC" = 1 ] && [ ! -s "$T/out" ] && pass "이관 기록 손상(${broken}): lane 은 빈 출력과 종료 1" || fail "손상 기록(${broken}) lane = ${RC} $(cat "$T/out")"
done

# --- expect -------------------------------------------------------------------
# The expected account by the rule `account` uses, printed for the gate's
# pre-launch check: the allow list, else a `정상` record's `**계정**`; a broken
# record never falls back to the host value.
vc "$H" -- expect
[ "$RC" = 2 ] && [ ! -s "$T/out" ] && pass "expect: 문서 인자가 없으면 사용법 오류 (종료 2)" || fail "expect 인자 없음 = ${RC} $(cat "$T/out")"
vc "$H" -- expect "$DOC"
[ "$RC" = 0 ] && [ "$(cat "$T/out")" = "허용 Design.Owner@example.com" ] \
  && pass "expect: 기록이 없으면 허용 목록을 한 줄로, 종료 0" || fail "expect 호스트 = ${RC} $(cat "$T/out")"
vc "$HR" CC_PIPELINE_RUN_DIR="$HR/run" -- expect "$DOC"
[ "$RC" = 0 ] && [ "$(cat "$T/out")" = "손상 $RECF" ] \
  && pass "expect: 손상된 이관 기록은 손상과 그 경로 (호스트로 떨어지지 않음)" || fail "expect 손상 기록 = ${RC} $(cat "$T/out")"
printf '%s\n' '<!-- cc-visual-lane v1; writer=gate; reader=run.sh,visual-config.sh,visual-publish-unattended -->' \
  '**레인**: u3' '**계정**: unattended.three@example.com' \
  '**이관**: 1 · pub → u3 · reserve · 2026-11-07T00:00:00Z' > "$RECF"
vc "$HR" CC_PIPELINE_RUN_DIR="$HR/run" -- expect "$DOC"
[ "$RC" = 0 ] && [ "$(cat "$T/out")" = "기록 unattended.three@example.com 런이관" ] \
  && pass "expect: 정상 이관 기록이 있으면 기록의 **계정**" || fail "expect 기록 = ${RC} $(cat "$T/out")"
vc "$T/h-unset" -- expect "$DOC"
[ "$RC" = 0 ] && [ "$(cat "$T/out")" = 미설정 ] && pass "expect: 호스트 파일도 기록도 없으면 미설정" || fail "expect 없음 = ${RC} $(cat "$T/out")"
HE="$T/h-expect-noacct"
mkdir -p "$HE/config/cc-cmds"
printf '%s\n' 'lane = pub' > "$HE/config/cc-cmds/claude-design"
vc "$HE" -- expect "$DOC"
[ "$RC" = 0 ] && [ "$(cat "$T/out")" = 미설정 ] && pass "expect: 호스트 파일에 allow·account 줄이 없으면 미설정" || fail "expect account 없음 = ${RC} $(cat "$T/out")"
vc "$H" CC_PIPELINE_RUN_ID=20261012-deadbeef -- expect "$DOC"
[ "$RC" = 0 ] && [ "$(cat "$T/out")" = "허용 Design.Owner@example.com" ] && ! grep -q '런 안에서는 거절한다' "$T/err" \
  && pass "expect: 발행 표지 없이 런 안에서도 허용" || fail "expect 런 안 = ${RC} $(cat "$T/err")"

# --- share --------------------------------------------------------------------
HS="$T/h-share"
mkdir -p "$HS/config/cc-cmds"
printf '%s\n' 'account = design.owner@example.com' > "$HS/config/cc-cmds/claude-design"
vc "$HS" CC_PIPELINE_RUN_ID=20261012-deadbeef -- share
[ "$RC" = 1 ] && [ ! -s "$T/out" ] && pass "share: 키가 없으면 빈 출력과 종료 1" || fail "share 없음 = ${RC} $(cat "$T/out")"
printf '%s\n' 'share =   ' >> "$HS/config/cc-cmds/claude-design"
vc "$HS" -- share
[ "$RC" = 1 ] && [ ! -s "$T/out" ] && pass "share: 값이 비면 빈 출력과 종료 1" || fail "share 빈 값 = ${RC} $(cat "$T/out")"
printf '%s\n' ' share = human.cc@example.com ' >> "$HS/config/cc-cmds/claude-design"
vc "$HS" CC_PIPELINE_RUN_ID=20261012-deadbeef -- share
[ "$RC" = 0 ] && [ "$(cat "$T/out")" = human.cc@example.com ] && pass "share: 런 안에서도 마지막 줄 값을 다듬어 낸다" || fail "share 판독 = ${RC} $(cat "$T/out")"
vc "$T/h-unset" -- share
[ "$RC" = 1 ] && [ ! -s "$T/out" ] && pass "share: 호스트 파일이 없으면 종료 1" || fail "share 파일 없음 = ${RC}"

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
