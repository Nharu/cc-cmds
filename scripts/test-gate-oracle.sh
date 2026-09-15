#!/usr/bin/env bash
# Test the three-signal oracle that wraps `scripts/test-gate.sh`.
#
# The oracle exists because the suite's exit status is not an honest report of
# whether it ran, so this file's whole job is to hold the oracle to the six
# shapes it was built against — and to do it WITHOUT running the suite, which
# takes forty minutes and could not produce four of the six on demand anyway.
#
# Three kinds of case, and each kind is here because the other two cannot cover
# it:
#
#   FIXTURES    a captured transcript is replayed through `--oracle-judge`. The
#               fixture directory IS the live capture layout — `out`, `err`,
#               `rc`, `map`, `script`, `scope` — so the judge under test is the
#               same code path the wrapper runs, not a re-implementation of it.
#               `expect` holds `<exit code> <verdict token>`, and BOTH are
#               asserted: a judge that returned the right number for the wrong
#               reason would pass a code-only check.
#
#   PROBE       the message-catalogue self-test. Its failure case is made
#               deterministic with a fake `bash` on PATH rather than with a
#               locale, because the ubuntu runner has no Korean catalogue and a
#               case that cannot fire on CI is a case that tests nothing there.
#
#   PLUMBING    `--oracle-wrap` runs a small fake suite end to end, which is the
#               only way to see the parts no fixture reaches: that the child's
#               streams really pass through, that a REAL `command not found`
#               from bash is attributed to the section whose lines it fell in,
#               that `CC_TEST_GATE_ORACLE_INNER` reaches the child, that a
#               host's `LC_ALL` is moved into the other categories instead of
#               being dropped, and that the pre-run cleaning takes the stale
#               directories and leaves the live ones.
#
# Usage: bash scripts/test-gate-oracle.sh

set -uo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
TG="$repo_root/scripts/test-gate.sh"
FIX="$repo_root/tests/fixtures/gate-oracle"

if [ ! -f "$TG" ]; then
  printf 'ERR: 래퍼를 담은 파일이 없다: %s\n' "$TG" >&2
  exit 2
fi
if [ ! -d "$FIX" ]; then
  printf 'ERR: 픽스처 디렉터리가 없다: %s\n' "$FIX" >&2
  exit 2
fi

passed=0; failed=0
ok()    { passed=$((passed + 1)); printf 'PASS: %s\n' "$1"; }
bad()   { failed=$((failed + 1)); printf 'FAIL: %s — %s\n' "$1" "${2:-}" >&2; }
skip()  { printf 'SKIP: %s — %s\n' "$1" "${2:-}"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got '$2', want '$3'"; fi; }
# The fixture text is Korean and so are the wrapper's messages, so a substring
# test is spelled once here rather than as a `case` at every site.
has()   { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "문면에 「$3」 이 없다: $(printf '%s' "$2" | tr '\n' ' ')" ;; esac; }

# NOT named `cc-gate-*`: the wrapper's own pre-run cleaning walks that glob, and
# a scratch directory that the code under test may delete is a flake waiting for
# a slow machine.
WORK=$(mktemp -d "${TMPDIR:-/tmp}/cc-oracle-test.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

# --- fixtures ---------------------------------------------------------------

seen=0
for d in "$FIX"/*/; do
  [ -d "$d" ] || continue
  seen=$((seen + 1))
  name=$(basename "$d")
  if [ ! -f "$d/expect" ]; then
    bad "픽스처 $name" "expect 파일이 없다"
    continue
  fi
  want=$(cat "$d/expect")
  want_code=${want%% *}
  want_tok=${want##* }

  # THE FIXTURE DIRECTORY MUST COME BACK UNCHANGED. The judge needs a scratch
  # file and the obvious place to put it is beside the capture it is reading —
  # which for a checked-in fixture means writing into the tree.
  before=$(ls -A "$d" | sort)
  err=$(bash "$TG" --oracle-judge "$d" 2>&1 >/dev/null); code=$?
  after=$(ls -A "$d" | sort)

  check "픽스처 $name: 종료 코드" "$code" "$want_code"
  has "픽스처 $name: 판정 토큰 $want_tok" "$err" "판정=$want_tok "
  check "픽스처 $name: 판정이 픽스처를 바꾸지 않는다" "$after" "$before"
done

# An empty or gutted directory would run every loop above zero times and report
# 0 passed, 0 failed — which is the shape of green this whole file is about.
if [ "$seen" -lt 10 ]; then
  bad "픽스처 수" "찾은 디렉터리 $seen 개 — 여섯 형태와 경계를 덮지 못한다 (10개 이상이어야 한다)"
else
  ok "픽스처 수: $seen 개"
fi

# A judge pointed at something that is not a capture directory must refuse
# rather than judge an empty transcript as a crash.
bash "$TG" --oracle-judge "$WORK/does-not-exist" >/dev/null 2>&1; code=$?
check "--oracle-judge: 없는 디렉터리는 거절(2)" "$code" "2"

# --- probe ------------------------------------------------------------------

bash "$TG" --oracle-probe >/dev/null 2>&1; code=$?
check "탐침: 정규화된 환경에서 통과" "$code" "0"

stub="$WORK/stub"
mkdir -p "$stub"
cat > "$stub/bash" <<'STUBEOF'
#!/bin/sh
# 탐침이 기대하는 영문 카탈로그 대신 한국어를 내는 가짜 bash.
# 카탈로그 어긋남을 호스트의 로케일 설치 여부와 무관하게 재현한다.
printf '%s\n' "sh: 1: cc_gate_probe_missing_xyz: 명령을 찾을 수 없음" >&2
exit 127
STUBEOF
chmod +x "$stub/bash"
out=$(PATH="$stub:$PATH" "$BASH" "$TG" --oracle-probe 2>&1); code=$?
check "탐침: 카탈로그가 어긋나면 비영으로 끝난다" "$code" "1"
has "탐침: 어긋남을 판정=probe 로 말한다" "$out" "판정=probe"

# The design's table asks for this row as "set LC_MESSAGES to something else".
# Taken literally it asserts the opposite of what the wrapper correctly does:
# `oracle_locale` runs BEFORE the probe, so an outside `LC_MESSAGES` is
# normalised away and the probe passes. The row is kept as the same scenario
# with the expectation the code earns — the catalogue really differs, and the
# normalisation really wins — and the deterministic mismatch case is the PATH
# stub above.
ko_raw=$(LC_ALL= LC_MESSAGES=ko_KR.UTF-8 bash -c 'cc_gate_probe_missing_xyz' 2>&1 || true)
case "$ko_raw" in
  *'command not found'*)
    skip "탐침: 실제 한국어 카탈로그" "이 호스트에는 ko_KR bash 카탈로그가 없어 정규화 없이도 영문이 난다" ;;
  *)
    ok "탐침: 대조군 — 정규화 없이는 영문 패턴이 매치되지 않는다"
    LC_ALL= LC_MESSAGES=ko_KR.UTF-8 "$BASH" "$TG" --oracle-probe >/dev/null 2>&1; code=$?
    check "탐침: 한국어 로케일 아래에서도 정규화가 이긴다" "$code" "0" ;;
esac

# --- plumbing ---------------------------------------------------------------

fake="$WORK/fake-suite.sh"
cat > "$fake" <<'FAKEEOF'
#!/usr/bin/env bash
set -uo pipefail
printf 'INNER=%s\n' "${CC_TEST_GATE_ORACLE_INNER:-unset}"
printf 'LOCALE LC_ALL=%s LC_CTYPE=%s LC_MESSAGES=%s\n' \
  "${LC_ALL:-unset}" "${LC_CTYPE:-unset}" "${LC_MESSAGES:-unset}"
printf 'PASS: 가짜 1\n'
cc_gate_fake_missing_cmd_xyz
printf 'PASS: 가짜 2\n'
printf '\ntest-gate: 2 passed, 0 failed\n'
exit 0
FAKEEOF
noise_line=$(grep -n 'cc_gate_fake_missing_cmd_xyz' "$fake" | sed -n '1s/:.*$//p')
if [ -z "$noise_line" ]; then
  bad "배관: 가짜 스위트의 노이즈 줄 번호" "찾지 못했다"
  noise_line=0
fi
map_warn="$WORK/map-warned"
map_enf="$WORK/map-enforced"
printf '%s %s 12b base\n' "$noise_line" "$noise_line" > "$map_warn"
printf '%s %s 5 sa\n' "$noise_line" "$noise_line" > "$map_enf"

out=$(bash "$TG" --oracle-wrap "$fake" "$map_warn" 2>&1); code=$?
check "배관: 경고 대상 절의 노이즈는 초록으로 끝난다" "$code" "0"
has "배관: 자식 stdout 이 그대로 흘러나온다" "$out" "PASS: 가짜 1"
has "배관: 중첩 표지가 자식에 도달한다" "$out" "INNER=1"
has "배관: 노이즈가 절에 귀속된다" "$out" "노이즈 경고 — id=12b group=base"
has "배관: 판정 줄이 범위를 싣는다" "$out" "판정=pass 범위=래퍼 시험"

out=$(bash "$TG" --oracle-wrap "$fake" "$map_enf" 2>&1); code=$?
check "배관: 강제 대상 절의 노이즈는 비영(3)으로 끝난다" "$code" "3"
has "배관: 강제된 노이즈가 절 id 와 그룹을 싣는다" "$out" "노이즈 — id=5 group=sa"

# Same transcript, no map: an unattributable line takes the strict side.
out=$(bash "$TG" --oracle-wrap "$fake" "$WORK/no-such-map" 2>&1); code=$?
check "배관: 맵이 없으면 귀속 불가 노이즈가 강제된다" "$code" "3"
has "배관: 귀속 불가를 그렇게 말한다" "$out" "절에 귀속되지 않음"

# `LC_ALL` wins over every category, so dropping it would take CTYPE and COLLATE
# to C with it. The child is where that is visible.
out=$(LC_ALL=ko_KR.UTF-8 bash "$TG" --oracle-wrap "$fake" "$map_warn" 2>&1)
has "배관: LC_ALL 은 버려지지 않고 각 카테고리로 옮겨진다" \
  "$out" "LOCALE LC_ALL=unset LC_CTYPE=ko_KR.UTF-8 LC_MESSAGES=C"

fake_nototals="$WORK/fake-no-totals.sh"
cat > "$fake_nototals" <<'FAKEEOF'
#!/usr/bin/env bash
printf 'PASS: 가짜 1\n'
printf 'PASS: 가짜 2\n'
exit 0
FAKEEOF
out=$(bash "$TG" --oracle-wrap "$fake_nototals" "$map_warn" 2>&1); code=$?
check "배관: 총계 줄 없이 rc 0 이면 crash(5)" "$code" "5"
has "배관: 총계 부재를 그렇게 말한다" "$out" "판정=crash"

# --- pre-run cleaning -------------------------------------------------------

tdir="$WORK/tmproot"
mkdir -p "$tdir/cc-gate-old" "$tdir/cc-gate-fresh" "$tdir/keepme"
: > "$tdir/cc-gate-old/inside"
touch -t 202001010000 "$tdir/cc-gate-old"
TMPDIR="$tdir" bash "$TG" --oracle-wrap "$fake" "$map_warn" >/dev/null 2>&1
if [ -d "$tdir/cc-gate-old" ]; then
  bad "청소: 늙은 cc-gate-* 는 실행 전에 지워진다" "남아 있다"
else
  ok "청소: 늙은 cc-gate-* 는 실행 전에 지워진다"
fi
if [ -d "$tdir/cc-gate-fresh" ]; then
  ok "청소: 방금 만든 cc-gate-* 는 남는다 — 형제 실행의 작업 디렉터리를 지우지 않는다"
else
  bad "청소: 방금 만든 cc-gate-* 는 남는다 — 형제 실행의 작업 디렉터리를 지우지 않는다" "지워졌다"
fi
if [ -d "$tdir/keepme" ]; then
  ok "청소: 이름이 다른 디렉터리는 건드리지 않는다"
else
  bad "청소: 이름이 다른 디렉터리는 건드리지 않는다" "지워졌다"
fi

printf '\ntest-gate-oracle: %d passed, %d failed\n' "$passed" "$failed"
[ "$failed" = "0" ]
