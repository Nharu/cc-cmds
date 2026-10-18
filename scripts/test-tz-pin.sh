#!/usr/bin/env bash
# Test the time-zone pin in the repository Makefile.
#
# The Makefile exports `TZ := $(TEST_TZ)` so every check and suite make runs
# sees one zone whatever the caller's environment says. Three assertions hold
# that in place:
#
#   1. Pin watch — under an outer `TZ=UTC0`, `make print-test-tz` prints exactly
#      `Asia/Seoul +0900`. The offset is checked beside the name because glibc
#      falls back to UTC in silence when the zone data is missing, and the name
#      alone would still read right on such a runner.
#   2. Defect fixture — tests/fixtures/tz-pin/utc-confusion.sh takes local time
#      for UTC. Under the same outer `TZ=UTC0` it fails through `make tz-probe`
#      and passes when bash runs it directly; the direct run is the control that
#      shows the outer environment alone would have hidden the defect.
#      utc-correct.sh, which reads both sides in UTC, passes through make.
#   3. One entry point — no line of .github/workflows/ runs a test script or
#      suite-guard.sh outside make, since such a run would not get the pin. Path
#      filter entries (`- 'scripts/test-…'`) and comment lines are not runs.
#
# Nested make starts with MAKEFLAGS, MFLAGS and MAKELEVEL cleared, as
# run-check-gate-selftest does, so a `make -j test` around this suite does not
# hand its jobserver or flags down.

set -uo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
fixtures="$repo_root/tests/fixtures/tz-pin"
workflows="$repo_root/.github/workflows"

if [[ ! -d "$fixtures" ]]; then
  echo "FAIL: fixtures root missing: $fixtures" >&2
  exit 2
fi

unset MAKEFLAGS MFLAGS MAKELEVEL

passed=0
failures=0

pass() { passed=$((passed + 1)); echo "PASS: $1"; }
fail() { failures=$((failures + 1)); echo "FAIL: $1" >&2; }

# The outer environment is UTC on purpose: it is what CI's runners had, and it
# is the case the pin has to win against.
pinned_make() {
  env TZ=UTC0 make --no-print-directory -s -C "$repo_root" -f "$repo_root/Makefile" "$@"
}

# 1. Pin watch.
out=$(pinned_make print-test-tz 2>&1)
if [[ "$out" == "Asia/Seoul +0900" ]]; then
  pass "고정 감시: 바깥 TZ=UTC0 아래 make 레시피가 Asia/Seoul +0900 을 받는다"
else
  fail "고정 감시: make print-test-tz 가 '$out' 를 찍었다 (기대: 'Asia/Seoul +0900')"
fi

# 2. Defect fixture, its control, and the correct counterpart.
if pinned_make tz-probe TZ_PROBE="$fixtures/utc-confusion.sh" >/dev/null 2>&1; then
  fail "결함 픽스처: 로컬시를 UTC 로 여기는 단언이 make 진입점에서 통과했다"
else
  pass "결함 픽스처: 로컬시를 UTC 로 여기는 단언이 make 진입점에서 실패한다"
fi
if env TZ=UTC0 bash "$fixtures/utc-confusion.sh" >/dev/null 2>&1; then
  pass "대조군: 같은 픽스처가 바깥 TZ=UTC0 직접 실행에서는 통과한다"
else
  fail "대조군: 같은 픽스처가 바깥 TZ=UTC0 직접 실행에서 실패했다 — 결함 픽스처 단언이 무엇도 가르지 못한다"
fi
if pinned_make tz-probe TZ_PROBE="$fixtures/utc-correct.sh" >/dev/null 2>&1; then
  pass "바른 픽스처: 양쪽을 UTC 로 읽는 단언은 make 진입점에서 통과한다"
else
  fail "바른 픽스처: 양쪽을 UTC 로 읽는 단언이 make 진입점에서 실패했다"
fi

# 3. One entry point. A run line is `bash`, `sh` or `./` followed by a test
# script or suite-guard.sh; comment lines and path filter entries are dropped
# first. The counter is tried on two planted lines before it reads the
# workflows, so a pattern that matches nothing cannot pass the real count.
RUN_ERE='(^|[^A-Za-z0-9_./-])((bash|sh)[[:space:]]+(\./)?|\./)scripts/(test-|suite-guard\.sh)'
count_runs() {
  grep -vE '^[[:space:]]*#' \
    | grep -vE "^[[:space:]]*-[[:space:]]*['\"]" \
    | grep -cE "$RUN_ERE" || true
}
# The interpreter word goes in as an argument so that this source line does
# not itself read as a gate invocation to test-liveness-agreement.sh.
planted_run=$(printf '      - run: %s scripts/test-gate.sh --sections 5\n' bash | count_runs)
planted_filter=$(printf "      - 'scripts/test-gate.sh'\n      # bash scripts/test-gate.sh\n" | count_runs)
if [[ "$planted_run" == "1" && "$planted_filter" == "0" ]]; then
  pass "진입점 단일성 계수기: 심은 실행 줄은 세고 경로 필터·주석 줄은 세지 않는다"
else
  fail "진입점 단일성 계수기: 심은 실행 줄 ${planted_run}개(기대 1), 경로 필터·주석 ${planted_filter}개(기대 0)"
fi

wf_files=()
for f in "$workflows"/*.yml "$workflows"/*.yaml; do
  [[ -f "$f" ]] && wf_files+=("$f")
done
if (( ${#wf_files[@]} == 0 )); then
  fail "진입점 단일성: $workflows 에 워크플로 파일이 없다"
else
  runs=$(cat "${wf_files[@]}" | count_runs)
  if [[ "$runs" == "0" ]]; then
    pass "진입점 단일성: 워크플로 ${#wf_files[@]}개 어디도 시험을 make 밖에서 부르지 않는다"
  else
    fail "진입점 단일성: 워크플로가 시험이나 suite-guard.sh 를 make 밖에서 ${runs}번 부른다"
    for f in "${wf_files[@]}"; do
      grep -nE "$RUN_ERE" "$f" | grep -vE ":[[:space:]]*#" | sed "s|^|  ${f#"$repo_root"/}:|" >&2
    done
  fi
fi

printf 'test-tz-pin: %d passed, %d failed\n' "$passed" "$failures"
(( failures == 0 ))
