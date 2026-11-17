#!/usr/bin/env bash
# Test plugins/cc-cmds/orchestrator/interview-check.sh — the check the kickoff
# runs on an interview record before it freezes it.
#
# Every case writes a record into a temporary directory and calls the real
# checker, so the convention hash it compares against is the one of this tree's
# `_common/verification.md`. Cases:
#   - a record whose `**검증 규약**` line is right passes, and the hash it
#     prints equals the record's own whole-file hash;
#   - a record without that line fails;
#   - a hash that is not the convention's fails;
#   - an item with `시험:` and no `관측:` fails;
#   - `동의: 문 9` naming a question the record does not have fails;
#   - a `판정:` value outside the three fails;
#   - a record holding the visual direction alone passes;
#   - no argument exits 2.

set -uo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
CHECK="$repo_root/plugins/cc-cmds/orchestrator/interview-check.sh"
CONV="$repo_root/plugins/cc-cmds/skills/_common/verification.md"

sha256_of() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

tmp=$(mktemp -d "${TMPDIR:-/tmp}/test-interview-check.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

conv_hash=$(sha256_of "$CONV")

passed=0
failures=0

pass() { passed=$((passed + 1)); echo "PASS: $1"; }
fail() {
  failures=$((failures + 1))
  echo "FAIL: $1" >&2
  [[ -n "${2:-}" ]] && printf '%s\n' "$2" | sed 's/^/  | /' >&2
  return 0
}

# record <file> <verification section body> — a record with an interview whose
# `## 요구사항 문답` holds 문 1 and 문 2.
record() {
  {
    printf '%s\n' '# 파이프라인 런 인터뷰 기록 — 20990101-test' \
      '<!-- cc-run-interview v3; writer=autopilot; reader=design-discuss-unattended (driver dispatch); run-id=20990101-test;' \
      '     NOT a design doc; mechanism-local, never staged by a skill -->' \
      '' '## 과제' '시험용 과제' '' \
      '## 요구사항 문답' '### 문 1' '외부 서비스 시험을 지금 돌릴까요?' '**선택지**:' \
      '- 라벨: 돌린다' '  설명: 표본 하나를 보낸다' '- 라벨: 돌리지 않는다' '  설명: 미확인으로 남긴다' \
      '### 답 1' '돌린다' '### 문 2' '맞습니까?' '**선택지**: 없음(자유 입력)' '### 답 2' '네' '' \
      '## 확인된 요구' '**확인 문항**: 문 2' '**해야 할 것**:' '없음' '**바꾸지 않는 것**:' '없음' '**완료 기준**:' '없음' '' \
      '## 배포 형상' '**레포**: 없음' '**슬라이스 수**: 없음' '**적용 위치**: 없음' '**적용 주체**: 없음' '**실패 시 파킹**: 없음' '' \
      '## 탐색 결과' '| 없음 — 탐색하지 않음' '' \
      '## 재현 근거' '| 해당 없음 — 새 기능' '' \
      '## 검증 선결'
    printf '%s\n' "$2"
    printf '%s\n' '' '## 골격 사전 판정' '없음' '' '## 시각 방향' '없음 — 시각 단계 없음' '' \
      '## 로스터' '매니페스트 `## 인가` 의 `설계 로스터` 행을 따른다'
  } > "$1"
}

# expect <name> <file|""> <want-exit> <needle in stderr|"">
expect() {
  local name="$1" file="$2" want="$3" needle="$4" out err ec
  if [[ -z "$file" ]]; then
    out=$(bash "$CHECK" 2>"$tmp/err"); ec=$?
  else
    out=$(bash "$CHECK" "$file" 2>"$tmp/err"); ec=$?
  fi
  err=$(cat "$tmp/err")
  if [[ "$ec" != "$want" ]]; then
    fail "$name (exit=$ec, expected=$want)" "$out
$err"
    return
  fi
  if [[ -n "$needle" ]] && ! grep -qF -- "$needle" <<< "$err"; then
    fail "$name — 표준 오류에 「${needle}」 이 없다" "$err"
    return
  fi
  if [[ "$want" == "0" ]]; then
    if [[ "$out" != "sha256=$(sha256_of "$file")" ]]; then
      fail "$name — 출력 「${out}」 이 기록의 실제 해시와 다르다"
      return
    fi
  elif [[ -n "$out" ]]; then
    fail "$name — 실패했는데 표준 출력이 있다: $out"
    return
  fi
  pass "$name (exit=$ec)"
}

KEYLINE="**검증 규약**: _common/verification.md sha256=$conv_hash"
GOOD_ITEMS="- 전제: 외부 서비스가 표본을 받는다
  판정: 반증됨 — 표본을 거절했다
  시험: curl -X POST https://example.invalid/sample
  동의: 문 1
  관측: 403 Forbidden @2099-01-01T00:00:00Z
- 전제: 로컬 도구가 있다
  판정: 확인됨 — --version 이 1.2 를 냈다"

record "$tmp/ok.md" "$KEYLINE
$GOOD_ITEMS"
expect "맞는 기록은 통과하고 기록 해시를 낸다" "$tmp/ok.md" 0 ""

record "$tmp/ok-none.md" "$KEYLINE
| 없음 — 설계가 기대는 전제가 없다"
expect "검증 규약 줄 뒤 없음 기록은 통과한다" "$tmp/ok-none.md" 0 ""

record "$tmp/no-key.md" "$GOOD_ITEMS"
expect "흔적 줄이 없으면 실패한다" "$tmp/no-key.md" 1 "첫 줄이 **검증 규약**"

record "$tmp/bad-hash.md" "**검증 규약**: _common/verification.md sha256=$(printf '0%.0s' $(seq 1 64))
$GOOD_ITEMS"
expect "해시가 기준 판과 다르면 실패한다" "$tmp/bad-hash.md" 1 "와 다르다"

record "$tmp/no-obs.md" "$KEYLINE
- 전제: 외부 서비스가 표본을 받는다
  판정: 미확인 — 시험이 끝나지 않았다
  시험: curl -X POST https://example.invalid/sample
  동의: 문 1"
expect "시험: 만 있고 관측: 이 없으면 실패한다" "$tmp/no-obs.md" 1 "함께 있지 않다"

record "$tmp/no-question.md" "$KEYLINE
- 전제: 외부 서비스가 표본을 받는다
  판정: 확인됨 — 표본을 받았다
  시험: curl -X POST https://example.invalid/sample
  동의: 문 9
  관측: 201 Created @2099-01-01T00:00:00Z"
expect "동의: 문 9 가 없는 질문을 가리키면 실패한다" "$tmp/no-question.md" 1 "### 문 9"

record "$tmp/bad-verdict.md" "$KEYLINE
- 전제: 외부 서비스가 표본을 받는다
  판정: 아마도 — 그럴 것이다"
expect "판정 값이 셋 밖이면 실패한다" "$tmp/bad-verdict.md" 1 "판정 값이"

printf '%s\n' '# 파이프라인 런 인터뷰 기록 — 20990101-test' \
  '<!-- cc-run-interview v3; writer=autopilot; reader=design-discuss-unattended (driver dispatch); run-id=20990101-test;' \
  '     NOT a design doc; mechanism-local, never staged by a skill -->' \
  '' '## 시각 방향' '**브랜드**: 없음' > "$tmp/visual.md"
expect "시각 방향만 담은 기록은 통과한다" "$tmp/visual.md" 0 ""

expect "인자가 없으면 2 로 끝난다" "" 2 "usage"

echo "test-interview-check: $passed passed, $failures failed"
if (( failures > 0 )); then
  exit 1
fi
exit 0
