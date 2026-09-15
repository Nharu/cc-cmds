#!/usr/bin/env bash
# Test scripts/lint-macos-keepset-paths.sh.
#
# THE FIXTURES ARE BUILT UNDER `mktemp -d`, NOT COMMITTED. The change that adds
# this lint declares its own two files and no fixture tree, so each case is a
# miniature repository written at run time — a workflow, a Makefile and the
# scripts those two point at — and `git add`ed so the lint enumerates it the way
# it enumerates the real tree. The unit has to be that large because what is
# under test is the relation between the three. `KEEPSET_ROOT` and
# `KEEPSET_WORKFLOW` are the overrides that make it possible.
#
# Every case asserts the exit code AND the exact set of `<rule>|<target>`
# violations. An exit code alone is satisfied by a lint that failed for some
# other reason, which is how a detector stops detecting with nobody noticing.
#
# Three sweep-wide checks keep the suite from passing vacuously: all three
# classes (OK, FAIL, ERR) are exercised; every rule id the lint can report —
# read out of the lint's own `viol` call sites, so a new rule arrives with its
# obligation — is observed in at least one case; and the number of assertions
# that actually ran is held to a floor, which catches a sweep that collapsed.

set -uo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
LINT="$script_dir/lint-macos-keepset-paths.sh"

if [[ ! -f "$LINT" ]]; then
  echo "FAIL: lint not found: $LINT" >&2
  exit 2
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/cc-lint-keepset-test.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

ASSERTION_FLOOR=20

passed=0
failures=0
assertions=0
seen_ok=0
seen_fail=0
seen_err=0
observed_ids=""

# The base filter. `pkg/**` is the entry that name equality would get wrong:
# the kept suite under it is named by no glob, only matched by one.
BASE_GLOBS="scripts/test-a.sh
scripts/lib.sh
pkg/**
tests/fixtures/a/**
tests/fixtures/b/**
.github/workflows/w.yml
Makefile"

RUN_LINE='make -j"$(sysctl -n hw.ncpu)" narrow'

mk_repo() {
  # mk_repo <dir> <globs> <push: alias|none> <run-line> <extra-recipe> <extra-suite>
  #
  # <run-line> empty writes no `make` step. <extra-recipe> is appended to the
  # section-selecting recipe. <extra-suite> joins the suite list.
  local dir="$1" globs="$2" push="$3" runline="$4" extra_recipe="$5" extra_suite="$6" g
  mkdir -p "$dir/scripts" "$dir/pkg/sub" "$dir/tests/fixtures/a" "$dir/tests/fixtures/b" \
    "$dir/.github/workflows" "$dir/docs-x"

  printf '%s\n' '#!/usr/bin/env bash' \
    'repo_root=$(cd "$(dirname "$0")/.." && pwd)' \
    '. "$repo_root/scripts/lib.sh"' \
    'cat "$repo_root/tests/fixtures/a/one.txt"' > "$dir/scripts/test-a.sh"
  printf '%s\n' 'lib_noop() { :; }' > "$dir/scripts/lib.sh"
  printf '%s\n' '#!/usr/bin/env bash' \
    'repo_root=$(cd "$(dirname "$0")/../.." && pwd)' \
    'ls "$repo_root/tests/fixtures/b"' > "$dir/pkg/sub/test-b.sh"
  printf 'one\n' > "$dir/tests/fixtures/a/one.txt"
  printf 'two\n' > "$dir/tests/fixtures/b/two.txt"
  printf '%s\n' 'echo unused' > "$dir/docs-x/unused.sh"

  {
    printf 'SUITES := scripts/test-a.sh pkg/sub/test-b.sh%s\n' "$extra_suite"
    printf 'GOALS := $(SUITES:%%=run/%%)\n'
    printf '.PHONY: narrow run-sel $(GOALS)\n'
    printf '$(GOALS): run/%%:\n\tbash $*\n'
    printf 'narrow: $(GOALS) run-sel\n'
    printf 'run-sel:\n\tbash scripts/test-a.sh --sections 1\n'
    if [[ -n "$extra_recipe" ]]; then printf '\t%s\n' "$extra_recipe"; fi
  } > "$dir/Makefile"

  {
    printf 'name: w\n\non:\n  pull_request:\n    paths: &p\n'
    while IFS= read -r g; do
      [[ -n "$g" ]] || continue
      printf "      - '%s'\n" "$g"
    done <<EOF
$globs
EOF
    printf '  push:\n    branches:\n      - master\n'
    if [[ "$push" == "alias" ]]; then printf '    paths: *p\n'; fi
    printf '\njobs:\n  j:\n    runs-on: macos-latest\n    steps:\n'
    printf '      - uses: actions/checkout@v4\n'
    printf '      - run: brew install yq\n'
    if [[ -n "$runline" ]]; then printf '      - run: %s\n' "$runline"; fi
  } > "$dir/.github/workflows/w.yml"

  (cd "$dir" && git init -q && git add -A) || {
    echo "FAIL: 픽스처 레포를 만들지 못했다: $dir" >&2
    exit 2
  }
}

run_case() {
  # run_case <name> <want-exit> <dir> <expected violations, one `rule|target` per line>
  local name="$1" want="$2" dir="$3" want_v got_v ec case_ok=1
  KEEPSET_ROOT="$dir" KEEPSET_WORKFLOW=.github/workflows/w.yml bash "$LINT" \
    >"$WORK/out" 2>"$WORK/err"
  ec=$?

  case "$name" in
    OK-*)   seen_ok=1 ;;
    FAIL-*) seen_fail=1 ;;
    ERR-*)  seen_err=1 ;;
  esac

  want_v=$(printf '%s\n' "$4" | grep -v '^$' | sort -u)
  got_v=$(sed -n 's#^FAIL: \[\([^]]*\)\] \([^ ]*\) — .*$#\1|\2#p' "$WORK/err" | sort -u)
  observed_ids=$(printf '%s\n%s\n' "$observed_ids" "$(printf '%s\n' "$got_v" | cut -d'|' -f1)")

  assertions=$((assertions + 1))
  if [[ "$ec" != "$want" ]]; then
    case_ok=0
    echo "FAIL: $name (exit=$ec, expected=$want)" >&2
    sed 's/^/    /' "$WORK/err" >&2
  fi

  assertions=$((assertions + 1))
  if [[ "$got_v" != "$want_v" ]]; then
    case_ok=0
    echo "FAIL: $name (위반 집합이 기대와 다르다)" >&2
    echo "  expected:" >&2
    printf '%s\n' "$want_v" | sed 's/^/    /' >&2
    echo "  actual:" >&2
    printf '%s\n' "$got_v" | sed 's/^/    /' >&2
  fi

  if (( case_ok == 1 )); then
    passed=$((passed + 1))
    echo "PASS: $name (exit=$ec, expected=$want)"
  else
    failures=$((failures + 1))
  fi
}

without() {
  # without <glob> — BASE_GLOBS minus one line.
  printf '%s\n' "$BASE_GLOBS" | grep -vFx "$1"
}

# OK — a kept suite matched only by a directory glob, a sourced file behind a
# `$var/` prefix, a file literal and a directory literal that justify their
# globs, and the push trigger reusing the pull_request anchor.
mk_repo "$WORK/ok" "$BASE_GLOBS" alias "$RUN_LINE" "" ""
run_case "OK-glob-match-closure-and-anchor" 0 "$WORK/ok" ""

# FAIL — the kept suite under `pkg/` is no longer matched by anything.
mk_repo "$WORK/deficit-suite" "$(without 'pkg/**')" alias "$RUN_LINE" "" ""
run_case "FAIL-deficit-kept-suite" 1 "$WORK/deficit-suite" "부족|pkg/sub/test-b.sh"

# FAIL — the file a kept suite sources is not matched. The suite itself still is,
# which is exactly why the closure has to be followed.
mk_repo "$WORK/deficit-closure" "$(without 'scripts/lib.sh')" alias "$RUN_LINE" "" ""
run_case "FAIL-deficit-sourced-file" 1 "$WORK/deficit-closure" "부족|scripts/lib.sh"

# FAIL — a glob whose only match nothing on the leg runs, sources or names.
mk_repo "$WORK/surplus" "$BASE_GLOBS
docs-x/unused.sh" alias "$RUN_LINE" "" ""
run_case "FAIL-surplus-unreferenced" 1 "$WORK/surplus" "잉여|docs-x/unused.sh"

# FAIL — a glob that matches no tracked file at all.
mk_repo "$WORK/dead" "$BASE_GLOBS
nowhere/**" alias "$RUN_LINE" "" ""
run_case "FAIL-dead-glob" 1 "$WORK/dead" "죽은 글로브|nowhere/**"

# FAIL — `*` does not cross `/`, so `pkg/*` covers nothing under `pkg/sub/`.
# A matcher that let it cross would report this tree clean.
mk_repo "$WORK/star" "$(without 'pkg/**')
pkg/*" alias "$RUN_LINE" "" ""
run_case "FAIL-star-stays-in-segment" 1 "$WORK/star" "부족|pkg/sub/test-b.sh
죽은 글로브|pkg/*"

# FAIL — a recipe runs a path that is not a tracked file.
mk_repo "$WORK/untracked" "$BASE_GLOBS" alias "$RUN_LINE" "" " scripts/missing.sh"
run_case "FAIL-untracked-recipe-path" 1 "$WORK/untracked" "실행 집합|scripts/missing.sh"

# ERR — no `run: make` line, so there is no execution side to compare.
mk_repo "$WORK/nomake" "$BASE_GLOBS" alias "" "" ""
run_case "ERR-no-make-line" 2 "$WORK/nomake" ""

# ERR — a recipe line that is not `bash <path>`; the lint cannot say what it runs.
mk_repo "$WORK/shape" "$BASE_GLOBS" alias "$RUN_LINE" "echo not-a-suite" ""
run_case "ERR-unreadable-recipe-line" 2 "$WORK/shape" ""

# ERR — the push event carries no `paths`, so the job starts on every push.
mk_repo "$WORK/nopaths" "$BASE_GLOBS" none "$RUN_LINE" "" ""
run_case "ERR-event-without-paths" 2 "$WORK/nopaths" ""

# ERR — the last word of the `make` line is a flag, not a target.
mk_repo "$WORK/notarget" "$BASE_GLOBS" alias 'make -k' "" ""
run_case "ERR-make-line-without-target" 2 "$WORK/notarget" ""

# --- sweep-wide checks ------------------------------------------------------

if (( seen_ok == 0 )) || (( seen_fail == 0 )) || (( seen_err == 0 )); then
  echo "FAIL: 클래스 커버리지 — OK=$seen_ok FAIL=$seen_fail ERR=$seen_err, 세 팔이 전부 취해져야 한다" >&2
  failures=$((failures + 1))
fi

declared_ids=$(grep -oE 'viol "[^"]+"' "$LINT" | sed -E 's/^viol "//; s/"$//' | sort -u)
observed_ids=$(printf '%s\n' "$observed_ids" | grep -v '^$' | sort -u)
assertions=$((assertions + 1))
if [[ -z "$declared_ids" ]]; then
  echo "FAIL: 방출 커버리지 — 린트에서 viol 호출을 하나도 읽지 못했다" >&2
  failures=$((failures + 1))
else
  unobserved=$(comm -23 <(printf '%s\n' "$declared_ids") <(printf '%s\n' "$observed_ids"))
  if [[ -n "$unobserved" ]]; then
    echo "FAIL: 방출 커버리지 — 어느 사례에서도 관측되지 않은 규칙이 있다:" >&2
    printf '%s\n' "$unobserved" | sed 's/^/  /' >&2
    failures=$((failures + 1))
  fi
fi

if (( assertions < ASSERTION_FLOOR )); then
  echo "FAIL: 실행된 단언이 $assertions 개로 하한 $ASSERTION_FLOOR 미만이다 — 사례 순회가 무너졌다" >&2
  failures=$((failures + 1))
fi

printf 'test-lint-macos-keepset-paths: %d passed, %d failed, %d assertions\n' \
  "$passed" "$failures" "$assertions"

if (( failures > 0 )); then
  exit 1
fi
exit 0
