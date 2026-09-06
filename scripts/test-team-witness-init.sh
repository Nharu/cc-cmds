#!/usr/bin/env bash
# Test the team witness initializer.
#
# WHAT THIS SUITE IS FOR, given that `scripts/test-gate.sh` already asserts the
# script's grade. That assertion says the gate reads this name as an out-of-tree
# write; it says nothing about whether the name is reachable as argv0 at all, or
# whether the directory it prints is the one the ledger is about to record. Both
# of those are how this fix fails silently:
#
#   - drop the executable bit and every caller falls back to `bash <script>`,
#     which puts `bash` in argv0 and restores the exact grade the script exists
#     to avoid — with the gate's own suite still green, because the row is still
#     there and still correct.
#   - print anything besides the path and the caller records a `scratchDir` that
#     no member ever writes into, which surfaces later as an empty witness rather
#     than as an error here.
#
# So the assertions below are about the two things the grade cannot cover: the
# file is directly executable, and stdout is exactly the directory.
#
# Usage: bash scripts/test-team-witness-init.sh

set -uo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
INIT="$repo_root/plugins/cc-cmds/orchestrator/cc-team-witness-init.sh"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/cc-witness-init-test.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

passed=0
failed=0
ok()    { passed=$((passed + 1)); printf 'PASS: %s\n' "$1"; }
bad()   { failed=$((failed + 1)); printf 'FAIL: %s — %s\n' "$1" "${2:-}" >&2; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got '$2', want '$3'"; fi; }

# ---------------------------------------------------------------------------
# Directly executable — the pairing the gate row depends on
# ---------------------------------------------------------------------------
if [ -x "$INIT" ]; then
  ok "스크립트에 실행 비트가 있다"
else
  bad "스크립트에 실행 비트가 있다" "bash 로 감싸 부르게 되면 argv0 이 bash 가 되어 등급 행이 무력해진다"
fi
check "셔뱅이 있다" "$(head -1 "$INIT")" "#!/usr/bin/env bash"

# Invoked as itself, never through an interpreter — this is the shape every
# caller uses, and the only shape the gate row grades.
run_init() {
  # run_init <run-dir-or-empty> <stage-id-or-empty> <slug...>
  local rd="$1" sid="$2"; shift 2
  if [ -n "$rd" ]; then CC_PIPELINE_RUN_DIR="$rd"; export CC_PIPELINE_RUN_DIR
  else unset CC_PIPELINE_RUN_DIR; fi
  if [ -n "$sid" ]; then CC_PIPELINE_STAGE_ID="$sid"; export CC_PIPELINE_STAGE_ID
  else unset CC_PIPELINE_STAGE_ID; fi
  "$INIT" "$@"
}

# ---------------------------------------------------------------------------
# Root selection
# ---------------------------------------------------------------------------
TMPDIR="$WORK/tmp"; export TMPDIR
mkdir -p "$TMPDIR"
RUNDIR="$WORK/rundir"
mkdir -p "$RUNDIR"

d=$(run_init '' '' review-alpha)
check "실행 디렉터리가 없으면 임시 디렉터리 아래에 만든다" "$(dirname "$d")" "$TMPDIR"
if [ -d "$d" ]; then ok "만들어진 디렉터리가 실재한다"; else bad "만들어진 디렉터리가 실재한다" "$d"; fi

d=$(run_init "$RUNDIR" '' review-alpha)
check "실행 디렉터리가 있으면 그 아래에 만든다" "$(dirname "$d")" "$RUNDIR"

# ---------------------------------------------------------------------------
# stdout is exactly the path — nothing else may ride on it
# ---------------------------------------------------------------------------
out=$(run_init "$RUNDIR" 'SB-1#2' review-alpha)
check "표준출력은 정확히 한 줄이다" "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "1"
if [ -d "$out" ]; then ok "표준출력 한 줄이 곧 그 디렉터리다"; else bad "표준출력 한 줄이 곧 그 디렉터리다" "$out"; fi

# ---------------------------------------------------------------------------
# The attempt discriminator — sanitized in the name, raw in the file
# ---------------------------------------------------------------------------
base=$(basename "$out")
case "$base" in
  cc-team-witness-review-alpha.SB-1-2.*) ok "이름이 정제된 스테이지 태그를 단다" ;;
  *) bad "이름이 정제된 스테이지 태그를 단다" "$base" ;;
esac
case "$base" in
  *'#'*) bad "이름에 # 이 남지 않는다" "$base" ;;
  *) ok "이름에 # 이 남지 않는다" ;;
esac
check "attempt 파일은 정제되지 않은 원본 id 를 담는다" "$(cat "$out/.attempt")" "SB-1#2"

# ---------------------------------------------------------------------------
# No stage id — nothing to discriminate, so no tag and no stamp
# ---------------------------------------------------------------------------
d=$(run_init "$RUNDIR" '' review-alpha)
if [ -e "$d/.attempt" ]; then
  bad "스테이지 id 가 없으면 attempt 를 쓰지 않는다" "$d/.attempt 가 생겼다"
else
  ok "스테이지 id 가 없으면 attempt 를 쓰지 않는다"
fi
# `cc-team-witness-<slug>.XXXXXX` — one dot before the mktemp suffix, none for
# a tag. Asserted on the dot count so an empty tag leaving `..` is caught.
check "태그가 없으면 이름에 점이 하나뿐이다" \
  "$(basename "$d" | tr -cd '.' | wc -c | tr -d ' ')" "1"

# ---------------------------------------------------------------------------
# The slug reaches an mktemp template, so it is sanitized too
# ---------------------------------------------------------------------------
d=$(run_init "$RUNDIR" '' 'a/../../escape me')
check "슬러그의 경로 구분자가 디렉터리를 옮기지 못한다" "$(dirname "$d")" "$RUNDIR"
case "$(basename "$d")" in
  *' '*) bad "슬러그의 공백이 이름에 남지 않는다" "$(basename "$d")" ;;
  *) ok "슬러그의 공백이 이름에 남지 않는다" ;;
esac

# ---------------------------------------------------------------------------
# Uniqueness — two teams in one stage must not collide
# ---------------------------------------------------------------------------
d1=$(run_init "$RUNDIR" 'SB-1#2' review-alpha)
d2=$(run_init "$RUNDIR" 'SB-1#2' review-alpha)
if [ "$d1" = "$d2" ]; then
  bad "같은 슬러그·같은 스테이지라도 디렉터리는 갈린다" "둘 다 $d1"
else
  ok "같은 슬러그·같은 스테이지라도 디렉터리는 갈린다"
fi

# ---------------------------------------------------------------------------
# A missing slug is refused, and refused without printing a path
# ---------------------------------------------------------------------------
out=$(run_init "$RUNDIR" '' 2>/dev/null)
rc=$?
check "슬러그가 없으면 2 로 거부한다" "$rc" "2"
check "거부할 때는 표준출력에 아무것도 내지 않는다" "$out" ""

printf '\n통과 %s · 실패 %s\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
