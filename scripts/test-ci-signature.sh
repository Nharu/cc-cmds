#!/usr/bin/env bash
# Test `ci-signature.sh`, the adapter that turns a failed CI job's log into the
# failure signatures the gate's `ci-match` act compares.
#
# THE LOGS ARE SYNTHETIC AND SHAPED LIKE THE REAL ONES. Each fixture carries what
# an Actions job log carries around a suite's output: the time stamp Actions
# puts at the head of every line, the `bash scripts/suite-guard.sh <script>` line
# make echoes before a suite, the `FAIL: <name> — <detail>` lines the `bad`
# helpers print, and the suite's `<n> passed, <m> failed` total.
#
# Usage: bash scripts/test-ci-signature.sh

set -uo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
CS="$repo_root/plugins/cc-cmds/orchestrator/ci-signature.sh"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/cc-ci-signature-test.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

passed=0; failed=0
ok()   { passed=$((passed + 1)); printf 'PASS: %s\n' "$1"; }
bad()  { failed=$((failed + 1)); printf 'FAIL: %s — %s\n' "$1" "${2:-}" >&2; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got '$2', want '$3'"; fi; }

# extract <check> <log file> [--step <name>]... — the adapter on cc-cmds.
extract() { local c="$1" f="$2"; shift 2; bash "$CS" extract --repo Nharu/cc-cmds --check "$c" "$@" < "$f"; }
# lines <text> — the number of non-empty lines.
lines() { printf '%s\n' "$1" | grep -c . || true; }

ts() { printf '2026-10-24T06:%02d:%02d.1234567Z ' "$1" "$2"; }

# ---------------------------------------------------------------------------
# 1. One suite, two failures: shard tail, detail, time stamp prefix.
# ---------------------------------------------------------------------------
{
  printf '%s%s\n' "$(ts 1 1)" 'bash scripts/suite-guard.sh scripts/test-gate.sh --sections 5,7'
  printf '%s%s\n' "$(ts 1 2)" 'PASS: 5 무엇'
  printf '%s%s\n' "$(ts 1 3)" "FAIL: 7 머지 검사 — got '3', want '0'"
  printf '%s%s\n' "$(ts 1 4)" 'FAIL: 7 인계 수락 — '
  printf '%s%s\n' "$(ts 1 5)" ''
  printf '%s%s\n' "$(ts 1 6)" 'test-gate: 1 passed, 2 failed'
} > "$WORK/a1.log"
out=$(extract 'gate-shards (3)' "$WORK/a1.log")
check "1 첫 줄은 단언 정밀도" "$(printf '%s\n' "$out" | head -n 1)" "정밀도: 단언"
check "1 서명 둘 — 샤드 꼬리·상세·시각 표지가 없다" "$(printf '%s\n' "$out" | tail -n +2)" \
  "$(printf '%s\n' 'gate-shards|test-gate.sh|7 머지 검사' 'gate-shards|test-gate.sh|7 인계 수락' | LC_ALL=C sort)"

# The same failure on another attempt: other times, another shard, other got/want.
{
  printf '%s%s\n' "$(ts 9 1)" 'bash scripts/suite-guard.sh scripts/test-gate.sh --sections 7'
  printf '%s%s\n' "$(ts 9 2)" 'FAIL: 7 인계 수락 — '
  printf '%s%s\n' "$(ts 9 3)" "FAIL: 7 머지 검사 — got '9', want '0'"
  printf '%s%s\n' "$(ts 9 4)" 'test-gate: 0 passed, 2 failed'
} > "$WORK/a2.log"
check "1 같은 실패의 두 로그는 같은 출력" "$(extract 'gate-shards (11)' "$WORK/a2.log")" "$out"

# ---------------------------------------------------------------------------
# 2. Names that carry ` — ` and names that share a head stay four signatures.
# ---------------------------------------------------------------------------
{
  printf '%s\n' 'bash scripts/suite-guard.sh scripts/test-gate.sh'
  printf '%s\n' "FAIL: 12 대조 — 부분집합 — got 'x', want 'y'"
  printf '%s\n' "FAIL: 12 대조 — 초과 — got 'x', want 'y'"
  printf '%s\n' "FAIL: 12 대조 행 — got 'x', want 'y'"
  printf '%s\n' "FAIL: 12 대조 행 수 — got 'x', want 'y'"
  printf '%s\n' 'test-gate: 0 passed, 4 failed'
} > "$WORK/b.log"
out=$(extract 'gate-shards (1)' "$WORK/b.log")
check "2 서명 넷이 모두 다르다" "$(lines "$(printf '%s\n' "$out" | tail -n +2)")" "4"
case "$out" in
  *'|12 대조 — 부분집합'*'|12 대조 — 초과'*) ok "2 이름 안의 — 는 이름에 남는다" ;;
  *) bad "2 이름 안의 — 는 이름에 남는다" "$out" ;;
esac

# A detail that quotes a refusal carries ` — ` of its own; the `rc=` and `got '`
# openings drop it whole, and a free-text detail is cut at the last ` — `.
{
  printf '%s\n' 'bash scripts/suite-guard.sh scripts/test-gate.sh'
  printf '%s\n' 'FAIL: 83c: A — 칸 x 에서 park 한다 — rc=0 게이트 통과 — exec 커밋 — 줄 44290'
  printf '%s\n' 'FAIL: 83c: B — 칸 x 에서 park 한다 — rc=0 게이트 통과 — exec 커밋 — 줄 44279'
  printf '%s\n' "FAIL: 7 문면 — got 'a — b — c', want 'd'"
  printf '%s\n' 'FAIL: 60b: park — 라벨 — 행이 없다'
  printf '%s\n' 'test-gate: 0 passed, 4 failed'
} > "$WORK/b2.log"
check "2 상세의 — 는 이름에 남지 않는다" "$(extract 'gate-shards (1)' "$WORK/b2.log" | tail -n +2)" \
  "$(printf '%s\n' 'gate-shards|test-gate.sh|60b: park — 라벨' \
    'gate-shards|test-gate.sh|7 문면' \
    'gate-shards|test-gate.sh|83c: A — 칸 x 에서 park 한다' \
    'gate-shards|test-gate.sh|83c: B — 칸 x 에서 park 한다' | LC_ALL=C sort)"

# ---------------------------------------------------------------------------
# 3. The variable parts of a name are normalised.
# ---------------------------------------------------------------------------
{
  printf '%s\n' 'bash scripts/suite-guard.sh scripts/test-x.sh'
  printf '%s\n' 'FAIL: gate.sh:1234 에서 /var/folders/ab/T/cc.abc123/run 의 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa 2026-10-24T06:18:54Z — d'
  printf '%s\n' 'x: 0 passed, 1 failed'
} > "$WORK/c1.log"
{
  printf '%s\n' 'bash scripts/suite-guard.sh scripts/test-x.sh'
  printf '%s\n' 'FAIL: gate.sh:1290 에서 /tmp/cc.zz9/run 의 bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb 2026-10-25T01:02:03Z — e'
  printf '%s\n' 'x: 0 passed, 1 failed'
} > "$WORK/c2.log"
o1=$(extract 'rest-tests (2)' "$WORK/c1.log"); o2=$(extract 'rest-tests (3)' "$WORK/c2.log")
check "3 줄 번호·임시 경로·16진·시각이 달라도 같은 서명" "$o1" "$o2"
check "3 정규화된 서명" "$(printf '%s\n' "$o1" | tail -n 1)" \
  'rest-tests|test-x.sh|gate.sh:<줄> 에서 <임시> 의 <sha> <시각>'

# ---------------------------------------------------------------------------
# 4. rest-tests: two scripts with the same assertion name stay apart.
# ---------------------------------------------------------------------------
{
  printf '%s\n' 'bash scripts/suite-guard.sh scripts/test-a.sh'
  printf '%s\n' 'bash scripts/suite-guard.sh scripts/test-b.sh'
  printf '%s\n' 'FAIL: 1 같은 이름 — x'
  printf '%s\n' 'test-b: 0 passed, 1 failed'
  printf '%s\n' 'bash scripts/suite-guard.sh scripts/test-c.sh'
  printf '%s\n' 'FAIL: 1 같은 이름 — y'
  printf '%s\n' 'test-c: 0 passed, 1 failed'
} > "$WORK/d.log"
out=$(extract 'rest-tests (1)' "$WORK/d.log")
check "4 스크립트가 서명을 가른다" "$(printf '%s\n' "$out" | tail -n +2)" \
  "$(printf '%s\n' 'rest-tests|test-b.sh|1 같은 이름' 'rest-tests|test-c.sh|1 같은 이름')"

# Without a suite line the signature is check and name alone.
{
  printf '%s\n' 'FAIL: 1 같은 이름 — x'
  printf '%s\n' '0 passed, 1 failed'
} > "$WORK/d2.log"
check "4 스위트 줄이 없으면 체크와 이름만" "$(extract 'rest-tests (1)' "$WORK/d2.log" | tail -n +2)" \
  'rest-tests|1 같은 이름'

# ---------------------------------------------------------------------------
# 5. A log without a total line is not read at assertion precision.
# ---------------------------------------------------------------------------
{
  printf '%s\n' 'bash scripts/suite-guard.sh scripts/test-gate.sh'
  printf '%s\n' 'FAIL: 3 무엇 — x'
} > "$WORK/e.log"
out=$(extract 'gate-shards (2)' "$WORK/e.log" --step 'Run gate shard')
check "5 합계 줄이 없으면 단계 정밀도" "$(printf '%s\n' "$out" | head -n 1)" "정밀도: 단계"
check "5 단계 정밀도의 서명은 단계 이름" "$(printf '%s\n' "$out" | tail -n +2)" 'gate-shards|Run gate shard'
out=$(extract 'gate-shards (2)' "$WORK/e.log")
check "5 단계도 없으면 정밀도 줄만" "$out" "정밀도: 단계"

# A lint that prints FAIL lines with no total.
{
  printf '%s\n' 'FAIL: fleet.sh — FLEET_X 이 핀되지 않았다'
  printf '%s\n' 'FAIL: fleet.sh — FLEET_Y 이 핀되지 않았다'
} > "$WORK/e2.log"
check "5 합계 없는 린트는 단계 정밀도" "$(extract 'lint' "$WORK/e2.log" --step 'make lint')" \
  "$(printf '%s\n' '정밀도: 단계' 'lint|make lint')"

# ---------------------------------------------------------------------------
# 6. --step: a check with no FAIL line, and the generic adapter.
# ---------------------------------------------------------------------------
printf '%s\n' 'npm ERR! something' 'Error: Process completed with exit code 1.' > "$WORK/f.log"
out=$(extract 'build (1)' "$WORK/f.log" --step 'Compile' --step 'Compile' --step 'Bundle')
check "6 FAIL 줄 없는 체크는 단계 서명" "$out" \
  "$(printf '%s\n' '정밀도: 단계' 'build|Bundle' 'build|Compile')"
out=$(bash "$CS" extract --repo other/repo --check 'test (ubuntu)' --step 'Run tests' < "$WORK/a1.log")
check "6 일반 어댑터는 FAIL 줄을 읽지 않는다" "$out" \
  "$(printf '%s\n' '정밀도: 단계' 'test (ubuntu)|Run tests')"
out=$(bash "$CS" extract --repo NHARU/CC-CMDS --check 'gate-shards (1)' < "$WORK/a1.log" | head -n 1)
check "6 slug 는 대소문자를 가리지 않는다" "$out" "정밀도: 단언"

# ---------------------------------------------------------------------------
# 7. Empty input, fingerprint, arguments.
# ---------------------------------------------------------------------------
out=$(extract 'gate-shards (1)' /dev/null); rc=$?
check "7 빈 로그는 정밀도 줄만" "$out" "정밀도: 단계"
check "7 빈 로그도 종료 코드 0" "$rc" "0"
f1=$(printf '%s\n' '정밀도: 단언' 'a|x' 'b|y' | bash "$CS" fingerprint)
f2=$(printf '%s\n' 'b|y' 'a|x' 'a|x' | bash "$CS" fingerprint)
check "7 지문은 순서·중복·정밀도 줄과 무관" "$f1" "$f2"
case "$f1" in
  [0-9a-f]*) check "7 지문은 64자리" "${#f1}" "64" ;;
  *) bad "7 지문은 64자리" "$f1" ;;
esac
f3=$(printf '%s\n' 'a|x' | bash "$CS" fingerprint)
[ "$f3" != "$f1" ] && ok "7 다른 목록은 다른 지문" || bad "7 다른 목록은 다른 지문" "$f3"
bash "$CS" extract --check x < /dev/null >/dev/null 2>&1; rc=$?
check "7 --repo 없으면 2" "$rc" "2"
bash "$CS" nope >/dev/null 2>&1; rc=$?
check "7 모르는 하위 명령은 2" "$rc" "2"

printf '\ntest-ci-signature: %d passed, %d failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
