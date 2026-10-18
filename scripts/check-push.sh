#!/usr/bin/env bash
# Check the committed tree once before push, and stamp it when it passes.
#
# WHAT IS CHECKED IS THE COMMIT, NOT THE WORKING TREE. `run` clones the
# repository's own object store into a temporary directory, checks the HEAD
# commit out detached there and runs the repository-wide local checks in that
# copy: `make lint`, `make readme` followed by a README freshness diff, and
# `make check-cheap`. An uncommitted edit in the working tree is neither checked
# nor pushed, so it can neither rescue nor sink the result; `run` only warns
# about it.
#
# THE STAMP IS KEYED ON THE TREE, NOT THE COMMIT. A commit that only rewrites
# the message (an amend, a rebase that changes nothing) keeps the tree, and the
# same tree has already passed. A commit that changes any file has a new tree
# and no stamp. Stamps live under the common git directory, so every worktree of
# the repository sees the same ones, and nothing is committed.
#
# Usage:
#   bash scripts/check-push.sh run         check HEAD in a clean clone, stamp on pass
#   bash scripts/check-push.sh verify      0 when HEAD's tree carries a stamp
#   bash scripts/check-push.sh --self-test
#
#   CC_CHECK_PUSH_MAKE   the make to run in the clone (default: make); the
#                        self-test swaps in doubles through it
#
# Exit codes: 0 passed / stamped, 1 a check failed or no stamp, 2 usage.

set -uo pipefail

check_push_usage() {
  printf 'check-push: 사용법 — run / verify / --self-test 중 하나\n' >&2
  exit 2
}

# The common git directory as an absolute path, read from the current directory.
check_push_common_dir() {
  local d
  d=$(git rev-parse --git-common-dir 2>/dev/null) || return 1
  (cd "$d" && pwd)
}

check_push_run() {
  local make_bin commit tree gdir work stamp_dir tmp_stamp
  make_bin="${CC_CHECK_PUSH_MAKE:-make}"
  commit=$(git rev-parse --verify --quiet HEAD) || {
    printf 'check-push: HEAD 커밋을 읽지 못했다 — git 저장소 안에서 커밋 뒤에 돌린다\n' >&2
    return 1
  }
  tree=$(git rev-parse --verify --quiet 'HEAD^{tree}') || {
    printf 'check-push: HEAD 트리를 읽지 못했다\n' >&2
    return 1
  }
  gdir=$(check_push_common_dir) || {
    printf 'check-push: 공통 git 디렉터리를 읽지 못했다\n' >&2
    return 1
  }
  if ! git diff --quiet HEAD -- 2>/dev/null; then
    printf 'check-push: 경고 — 작업 트리에 커밋되지 않은 추적 변경이 있다. 그 변경은 검사되지도 push 되지도 않는다\n' >&2
  fi

  work=$(mktemp -d "${TMPDIR:-/tmp}/cc-check-push.XXXXXX") || return 1
  # shellcheck disable=SC2064
  trap "rm -rf '$work'" EXIT
  if ! git clone --quiet --shared --no-checkout "$gdir" "$work/tree"; then
    printf 'check-push: 임시 복제에 실패했다\n' >&2
    return 1
  fi
  if ! (cd "$work/tree" && git checkout --quiet --detach "$commit"); then
    printf 'check-push: 커밋 %s 을 임시 복제본에 꺼내지 못했다\n' "$commit" >&2
    return 1
  fi

  if ! (
    cd "$work/tree" || exit 1
    "$make_bin" lint || { printf 'check-push: 실패 — make lint\n' >&2; exit 1; }
    "$make_bin" readme || { printf 'check-push: 실패 — make readme\n' >&2; exit 1; }
    git diff --exit-code -- README.md || { printf 'check-push: 실패 — README.md 가 생성 결과와 다르다 (make readme 뒤 커밋한다)\n' >&2; exit 1; }
    "$make_bin" check-cheap || { printf 'check-push: 실패 — make check-cheap\n' >&2; exit 1; }
  ); then
    printf 'check-push: 커밋 %s 검사 실패 — 도장을 찍지 않는다\n' "$commit" >&2
    return 1
  fi

  stamp_dir="$gdir/cc-cmds-check-push"
  mkdir -p "$stamp_dir" || return 1
  tmp_stamp=$(mktemp "$stamp_dir/.stamp.XXXXXX") || return 1
  printf 'commit=%s\nat=%s\n' "$commit" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$tmp_stamp" || return 1
  mv -f "$tmp_stamp" "$stamp_dir/$tree" || return 1
  printf 'check-push: 통과 — 커밋 %s (트리 %s) 에 도장을 찍었다\n' "$commit" "$tree"
}

check_push_verify() {
  local tree gdir stamp
  tree=$(git rev-parse --verify --quiet 'HEAD^{tree}') || {
    printf 'check-push: HEAD 트리를 읽지 못했다\n' >&2
    return 1
  }
  gdir=$(check_push_common_dir) || {
    printf 'check-push: 공통 git 디렉터리를 읽지 못했다\n' >&2
    return 1
  }
  stamp="$gdir/cc-cmds-check-push/$tree"
  if [ -f "$stamp" ]; then
    printf 'check-push: 도장 있음 — 트리 %s\n' "$tree"
    return 0
  fi
  printf 'check-push: 현재 HEAD 트리 %s 의 도장이 없다 — make check-push 를 먼저 돌린다\n' "$tree" >&2
  return 1
}

# --- self-test ---------------------------------------------------------------

check_push_self_test() {
  local passed=0 failed=0 T self rc out
  ok()  { passed=$((passed + 1)); printf 'PASS: %s\n' "$1"; }
  bad() { failed=$((failed + 1)); printf 'FAIL: %s — %s\n' "$1" "${2:-}" >&2; }
  self="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
  T=$(mktemp -d "${TMPDIR:-/tmp}/check-push-selftest.XXXXXX")

  # Two make doubles: one passes every target and logs it, one fails.
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$1" >> "%s/make.log"\nexit 0\n' "$T" > "$T/make-ok"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$T/make-bad"
  chmod +x "$T/make-ok" "$T/make-bad"

  # A scratch repository that no global git setting can reach.
  sgit() { GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false "$@"; }
  mkdir -p "$T/repo"
  (cd "$T/repo" && sgit init -q && printf 'one\n' > f && sgit add f && sgit commit -q -m first) || {
    bad "임시 저장소 준비" "git init/commit 실패"
    rm -rf "$T"; return 1
  }
  vrun() { (cd "$T/repo" && GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 CC_CHECK_PUSH_MAKE="$1" bash "$self" "$2" > /dev/null 2>&1); }
  stamp_count() { find "$T/repo/.git/cc-cmds-check-push" -type f ! -name '.stamp.*' 2>/dev/null | grep -c .; }

  # (1) no stamp yet -> verify fails
  vrun "$T/make-ok" verify; rc=$?
  if [ "$rc" = "1" ]; then ok "(1) 도장이 없으면 verify 는 1"; else bad "(1) 도장이 없으면 verify 는 1" "rc=$rc"; fi

  # (2) a failing make leaves no stamp
  vrun "$T/make-bad" run; rc=$?
  if [ "$rc" != "0" ] && [ "$(stamp_count)" = "0" ]; then ok "(2) 대역이 실패하면 run 은 0 아닌 값이고 도장이 없다"; else bad "(2) 대역이 실패하면 run 은 0 아닌 값이고 도장이 없다" "rc=$rc stamps=$(stamp_count)"; fi

  # (3) a passing make stamps the tree, and verify passes
  vrun "$T/make-ok" run; rc=$?
  if [ "$rc" = "0" ] && [ "$(stamp_count)" = "1" ]; then ok "(3) 통과하면 도장이 하나 생긴다"; else bad "(3) 통과하면 도장이 하나 생긴다" "rc=$rc stamps=$(stamp_count)"; fi
  vrun "$T/make-ok" verify; rc=$?
  if [ "$rc" = "0" ]; then ok "(3) 도장 뒤 verify 는 0"; else bad "(3) 도장 뒤 verify 는 0" "rc=$rc"; fi
  out=$(tr '\n' ' ' < "$T/make.log" 2>/dev/null)
  if [ "$out" = "lint readme check-cheap " ]; then ok "(3) 임시 복제본에서 lint, readme, check-cheap 을 차례로 부른다"; else bad "(3) 임시 복제본에서 lint, readme, check-cheap 을 차례로 부른다" "「${out}」"; fi

  # (4) a message-only commit keeps the tree, so the stamp still holds
  (cd "$T/repo" && sgit commit -q --amend -m 'first, reworded')
  vrun "$T/make-ok" verify; rc=$?
  if [ "$rc" = "0" ]; then ok "(4) 메시지만 고친 같은 트리 커밋은 verify 통과"; else bad "(4) 메시지만 고친 같은 트리 커밋은 verify 통과" "rc=$rc"; fi

  # (5) a commit that changes the tree has no stamp
  (cd "$T/repo" && printf 'two\n' > f && sgit commit -q -am second)
  vrun "$T/make-ok" verify; rc=$?
  if [ "$rc" = "1" ]; then ok "(5) 트리를 바꾼 새 커밋은 verify 실패"; else bad "(5) 트리를 바꾼 새 커밋은 verify 실패" "rc=$rc"; fi

  # The clone is a throwaway: run leaves no temporary directory behind.
  out=$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'cc-check-push.*' -newer "$T/make-bad" 2>/dev/null | grep -c .)
  if [ "$out" = "0" ]; then ok "run 은 임시 복제 디렉터리를 남기지 않는다"; else bad "run 은 임시 복제 디렉터리를 남기지 않는다" "$out 개 남음"; fi

  rm -rf "$T"
  printf 'check-push self-test: %d passed, %d failed\n' "$passed" "$failed"
  # A floor on the count, so a refactor that silently skips cases cannot pass.
  if [ "$passed" -lt 8 ]; then
    printf 'check-push self-test: 통과 수 %d 가 하한 8 에 못 미칩니다\n' "$passed" >&2
    return 1
  fi
  [ "$failed" = "0" ]
}

# --- main --------------------------------------------------------------------

[ "$#" -eq 1 ] || check_push_usage
case "$1" in
  run)         check_push_run ;;
  verify)      check_push_verify ;;
  --self-test) check_push_self_test ;;
  *)           check_push_usage ;;
esac
