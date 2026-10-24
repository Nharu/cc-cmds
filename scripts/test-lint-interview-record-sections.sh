#!/usr/bin/env bash
# Test scripts/lint-interview-record-sections.sh against
# tests/fixtures/lint-interview-record-sections/.
#
# Each fixture is a `skills/` root holding the five files the lint compares —
# the sidecar contract, the shared interview convention, autopilot's resident
# body and its boundaries reference, and the unattended design stage — and a
# sixth, the visual sidecar reference, when the contract carries the visual
# direction section. The directory name encodes the expectation:
#   OK-*       → exit 0
#   FAIL-<n>-* → exit 1, and the output names `[단언 <n>]`
#
# Naming the assertion is what keeps a FAIL fixture honest: a tree broken in
# the wrong place would still exit 1, and only the number shows that the
# assertion the fixture was built for is the one that fired.
#
# The real tree is run as well, and the lint and this test must be registered
# in `make lint` and LINT_TESTS.

set -uo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
LINT="$script_dir/lint-interview-record-sections.sh"
fixtures="$repo_root/tests/fixtures/lint-interview-record-sections"

if [[ ! -d "$fixtures" ]]; then
  echo "FAIL: fixtures root missing: $fixtures" >&2
  exit 2
fi

passed=0
failures=0

run_case() {
  # run_case <name> <want-exit> <skills-root|""> [<needle>]
  local name="$1" want="$2" root="$3" needle="${4:-}" out ec ok=1
  if [[ -z "$root" ]]; then
    out=$(SKILLS_ROOT= bash "$LINT" 2>&1)
  else
    out=$(SKILLS_ROOT="$root" bash "$LINT" 2>&1)
  fi
  ec=$?
  [[ "$ec" == "$want" ]] || ok=0
  if [[ -n "$needle" ]] && ! grep -qF -- "$needle" <<EOF
$out
EOF
  then
    ok=0
    echo "  missing in output: $needle" >&2
  fi
  if [[ "$ok" == "1" ]]; then
    passed=$((passed + 1))
    echo "PASS: $name (exit=$ec, expected=$want)"
  else
    failures=$((failures + 1))
    echo "FAIL: $name (exit=$ec, expected=$want)" >&2
    printf '%s\n' "$out" | sed 's/^/  | /' >&2
  fi
}

run_case "OK-real-tree" 0 "" "OK:"

for fixture in "$fixtures"/*/; do
  name=$(basename "$fixture")
  case "$name" in
    OK-*)
      run_case "$name" 0 "$fixture/skills" "OK:"
      ;;
    FAIL-*)
      n=${name#FAIL-}
      n=${n%%-*}
      run_case "$name" 1 "$fixture/skills" "[단언 $n]"
      ;;
    *)
      echo "test-lint-interview-record-sections: fixture '$name' has unrecognized prefix" >&2
      failures=$((failures + 1))
      ;;
  esac
done

# Bridge — the lint holds the contract's visual sub-block headings to the visual
# sidecar reference's record example; this holds that example to the reader.
# The example is frozen as a record under a scratch manifest, and
# `visual-config.sh snapshot` must hand back each sub-block line for line.
bridge_case() {
  local vsc="$repo_root/plugins/cc-cmds/skills/visual/references/sidecar.md"
  local helper="$repo_root/plugins/cc-cmds/orchestrator/visual-config.sh"
  local tmp ex rid=bridge-run part want got ok=1
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/lint-irs-bridge.XXXXXX")
  ex=$(awk '/^## 6\. / { s = 1; next } s && /^## / && !f { exit }
            s && /^````/ { f = !f; if (!f) exit; next } s && f { print }' "$vsc")
  if [[ -z "$ex" ]]; then
    failures=$((failures + 1))
    echo "FAIL: bridge-visual-subblocks — 시각 사이드카 참조의 기록 예시를 찾지 못했다" >&2
    rm -rf "$tmp"
    return
  fi
  git init -q "$tmp/base"
  mkdir -p "$tmp/base/docs/pipeline-run"
  printf '%s\n' "$ex" > "$tmp/base/docs/pipeline-run/$rid.interview.md"
  printf -- '- `사전 인가` | 인터뷰 기록=docs/pipeline-run/%s.interview.md | sha256=%s\n' \
    "$rid" "$(shasum -a 256 "$tmp/base/docs/pipeline-run/$rid.interview.md" | cut -d' ' -f1)" \
    > "$tmp/base/docs/pipeline-run/$rid.md"
  for part in 모델값 '금지 목록'; do
    want=$(printf '%s\n' "$ex" | awk -v h="### $part" '
      $0 == h { s = 1; next } s && /^```/ { if (f) exit; f = 1; next } s && f { print }')
    case "$part" in 모델값) p=models ;; *) p=bans ;; esac
    got=$(CC_PIPELINE_MANIFEST="$tmp/base/docs/pipeline-run/$rid.md" CC_PIPELINE_RUN_ID="$rid" \
      bash "$helper" snapshot --part "$p" 2>&1) || ok=0
    [[ -n "$want" && "$got" == "$want" ]] || ok=0
  done
  rm -rf "$tmp"
  if [[ "$ok" == "1" ]]; then
    passed=$((passed + 1))
    echo "PASS: bridge-visual-subblocks"
  else
    failures=$((failures + 1))
    echo "FAIL: bridge-visual-subblocks — visual-config.sh snapshot 이 기록 예시의 하위 블록을 그대로 돌려주지 않는다" >&2
  fi
}
bridge_case

# Registration — asked of make itself, the same way the sibling lint tests do.
lint_recipe=$(MAKEFLAGS= MAKELEVEL= make -n -C "$repo_root" --no-print-directory lint 2>/dev/null)
lint_tests=$(awk '/^LINT_TESTS :=/ { f = 1 } f { print; if ($0 !~ /\\$/) exit }' "$repo_root/Makefile" \
  | sed -e 's/^LINT_TESTS :=//' -e 's/\\$//')
if grep -qxF 'bash scripts/lint-interview-record-sections.sh' <<EOF
$lint_recipe
EOF
then
  passed=$((passed + 1))
  echo "PASS: registered-in-make-lint"
else
  failures=$((failures + 1))
  echo "FAIL: registered-in-make-lint — make lint 레시피에 bash scripts/lint-interview-record-sections.sh 가 없다" >&2
fi
lint_test_words=$(printf '%s\n' "$lint_tests" | tr ' \t' '\n\n')
if grep -qxF 'scripts/test-lint-interview-record-sections.sh' <<EOF
$lint_test_words
EOF
then
  passed=$((passed + 1))
  echo "PASS: registered-in-LINT_TESTS"
else
  failures=$((failures + 1))
  echo "FAIL: registered-in-LINT_TESTS — LINT_TESTS 에 scripts/test-lint-interview-record-sections.sh 가 없다" >&2
fi

echo "test-lint-interview-record-sections: $passed passed, $failures failed"

if (( failures > 0 )); then
  exit 1
fi
exit 0
