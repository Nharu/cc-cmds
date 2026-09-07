#!/usr/bin/env bash
# Test scripts/lint-ci-scope-binding.sh against
# tests/fixtures/lint-ci-scope-binding/.
#
# Each fixture is a MINIATURE REPOSITORY — a workflow, a Makefile, and the
# scripts those two point at. The unit has to be that large because what is
# under test is the relation between the three; anything smaller cannot hold it.
# The directory name encodes the expected exit code:
#   OK-*   → expected exit 0 (compared, no violation)
#   FAIL-* → expected exit 1 (compared, at least one violation)
#   ERR-*  → expected exit 2 (the comparison could not be carried out)
#
# Expected-value files, because an exit code alone is satisfied by a lint that
# failed for some entirely different reason — which is how a detector stops
# detecting without anyone noticing:
#
#   expected-violations.txt  `<rule id><TAB><target>`, compared as a SET. Every
#                            FAIL-*/ERR-* fixture carries one; an OK-* fixture
#                            carries none and is asserted to produce the empty
#                            set.
#   expected-missing.txt     the files rule 1 must name. `FAIL-1-issue-586` is
#                            where detection has to be visible in review, so the
#                            names are committed rather than described.
#
# Three checks keep the suite from passing vacuously, and none of them measures
# the filesystem. A count taken with `ls` is green against an empty fixture root,
# which is the failure the first two refuse.
#
#   1. an assertion-count floor, incremented by the assertions that actually
#      ran. Its job is collapse — an empty or unreadable fixture root — and not
#      one-fixture drift, which the expected-value files above already catch.
#   2. class coverage derived from this runner's own dispatch `case`. The table
#      that dispatches is the table that measures, so a class that stops being
#      exercised is caught by the same statement that would have run it.
#   3. emission coverage derived from the LINT's own `viol` call sites. Neither
#      of the first two measures WHICH violation a fixture pinned, and mutation
#      testing found what that costs: neutralizing 12 of 25 `viol` sites left the
#      suite fully green, because no expected-violations.txt asserted those rules
#      at all. Rule identity alone is still too coarse — two branches of one rule
#      reported against one target collapse into one `<id>|<target>` key, so
#      killing either branch leaves the key behind. So each site is identified by
#      its own message TEMPLATE, read out of the lint's source and turned into a
#      pattern, and every site has to have been observed at least once across the
#      sweep. A site that no fixture reaches is named.

set -uo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
fixtures="$repo_root/tests/fixtures/lint-ci-scope-binding"

ASSERTION_FLOOR=60
VIOL_SITE_FLOOR=26

if [[ ! -d "$fixtures" ]]; then
  echo "FAIL: fixtures root missing: $fixtures" >&2
  exit 2
fi

stderr_capture=$(mktemp "${TMPDIR:-/tmp}/test-lint-ci-scope-binding.XXXXXX")
stdout_capture=$(mktemp "${TMPDIR:-/tmp}/test-lint-ci-scope-binding.XXXXXX")
observed=$(mktemp "${TMPDIR:-/tmp}/test-lint-ci-scope-binding.XXXXXX")
observed_out=$(mktemp "${TMPDIR:-/tmp}/test-lint-ci-scope-binding.XXXXXX")
trap 'rm -f "$stderr_capture" "$stdout_capture" "$observed" "$observed_out"' EXIT

passed=0
failures=0
assertions=0
seen_ok=0
seen_fail=0
seen_err=0

# `<rule id>|<target>` per reported violation, sorted. The trailing summary line
# carries no `[rule]` bracket and so does not enter the set.
actual_violations() {
  sed -n 's#^FAIL: \[\([^]]*\)\] \([^ ]*\) — .*$#\1|\2#p' "$1" 2>/dev/null | sort -u
}

# `<rule id><TAB><message>` per reported violation, appended across the whole
# sweep. The message is what tells two branches of one rule apart.
observed_messages() {
  sed -n 's#^FAIL: \[\([^]]*\)\] [^ ]* — \(.*\)$#\1	\2#p' "$1" 2>/dev/null
}

# A `viol` message template as written in the lint's source, turned into an ERE:
# every interpolation becomes `.*` and every other character is matched
# literally. Matching the literal remainder is the point — `선언이 죽었다 — '$item'
# 가 tracked 파일이 아니다` and `… 가 tracked 파일을 하나도 담지 않는다` are two
# sites of one rule that a prefix comparison would merge.
viol_regex() {
  printf '%s\n' "$1" | awk '
    {
      s = $0; out = ""; n = length(s); i = 1
      while (i <= n) {
        c = substr(s, i, 1)
        if (c == "$") {
          # A braced expansion is consumed to its closing brace rather than to
          # the end of the name: `${item%/}` carries a modifier, and stopping at
          # the name would leave `%/}` in the pattern as literal text that the
          # expanded output never contains.
          if (substr(s, i + 1, 1) == "{") {
            k = index(substr(s, i + 2), "}")
            if (k > 0) { out = out ".*"; i = i + 2 + k; continue }
          } else {
            k = i + 1
            while (k <= n && substr(s, k, 1) ~ /[A-Za-z_0-9]/) k++
            if (k > i + 1) { out = out ".*"; i = k; continue }
          }
        }
        if (index(".^$*+?()[]{}|\\", c) > 0) out = out "\\" c
        else out = out c
        i++
      }
      print out
    }
  '
}

for fixture in "$fixtures"/*/; do
  fixture_name=$(basename "$fixture")
  case "$fixture_name" in
    OK-*)   want=0 ; seen_ok=1 ;;
    FAIL-*) want=1 ; seen_fail=1 ;;
    ERR-*)  want=2 ; seen_err=1 ;;
    *)
      echo "test-lint-ci-scope-binding: fixture '$fixture_name' has unrecognized prefix" >&2
      failures=$((failures + 1))
      continue
      ;;
  esac

  CI_SCOPE_ROOT="$fixture" bash "$script_dir/lint-ci-scope-binding.sh" \
    >"$stdout_capture" 2>"$stderr_capture"
  ec=$?

  observed_messages "$stderr_capture" >> "$observed"
  cat "$stdout_capture" >> "$observed_out"

  fixture_ok=1

  assertions=$((assertions + 1))
  if [[ "$ec" != "$want" ]]; then
    fixture_ok=0
    echo "FAIL: $fixture_name (exit=$ec, expected=$want)" >&2
    sed 's/^/    /' "$stderr_capture" >&2
  fi

  # Violation set. Absent expectation file means the empty set, which is what an
  # OK-* fixture asserts.
  expected_file="$fixture/expected-violations.txt"
  if [[ -f "$expected_file" ]]; then
    want_v=$(grep -v '^$' "$expected_file" | tr '\t' '|' | sort -u)
  else
    want_v=""
  fi
  got_v=$(actual_violations "$stderr_capture")
  assertions=$((assertions + 1))
  if [[ "$got_v" != "$want_v" ]]; then
    fixture_ok=0
    echo "FAIL: $fixture_name (위반 집합이 기대와 다르다)" >&2
    echo "  expected:" >&2
    printf '%s\n' "$want_v" | sed 's/^/    /' >&2
    echo "  actual:" >&2
    printf '%s\n' "$got_v" | sed 's/^/    /' >&2
  fi

  # Rule 1 must NAME the files. This is the assertion that makes the shipped
  # shape's detection visible in a diff.
  expected_missing="$fixture/expected-missing.txt"
  if [[ -f "$expected_missing" ]]; then
    while IFS= read -r m; do
      [[ -n "$m" ]] || continue
      assertions=$((assertions + 1))
      if ! grep -qF "FAIL: [규칙 1] $m " "$stderr_capture"; then
        fixture_ok=0
        echo "FAIL: $fixture_name (규칙 1 이 '$m' 를 이름으로 대지 않았다)" >&2
      fi
    done < "$expected_missing"
  fi

  # R11's negative control, kept in the suite rather than left as a one-off
  # observation: rules 8 and 9 must be silent on an input that does not violate
  # them. A rule that reports on everything is not a detector either.
  if [[ "$fixture_name" == "OK-1-bound" ]]; then
    for quiet_rule in "규칙 8" "규칙 9"; do
      assertions=$((assertions + 1))
      if grep -qF "[$quiet_rule]" "$stderr_capture"; then
        fixture_ok=0
        echo "FAIL: $fixture_name ($quiet_rule 이 위반 없는 입력에 대해 발화했다)" >&2
      fi
    done
  fi

  if (( fixture_ok == 1 )); then
    passed=$((passed + 1))
    echo "PASS: $fixture_name (exit=$ec, expected=$want)"
  else
    failures=$((failures + 1))
  fi
done

if (( seen_ok == 0 )) || (( seen_fail == 0 )) || (( seen_err == 0 )); then
  echo "FAIL: 클래스 커버리지 — OK=$seen_ok FAIL=$seen_fail ERR=$seen_err, 세 팔이 전부 취해져야 한다" >&2
  failures=$((failures + 1))
fi

# Emission coverage. The site list is read out of the lint rather than kept here,
# so adding a `viol` call adds an obligation in the same commit that adds the
# branch — a hand-maintained list would go stale exactly when a new branch shows
# up unasserted, which is the failure being guarded against.
uncovered=0
sites=0
while IFS=$'\t' read -r vline vid vmsg; do
  [[ -n "$vid" ]] || continue
  sites=$((sites + 1))
  vre=$(viol_regex "$vmsg")
  assertions=$((assertions + 1))
  if ! VIOL_RE="$vre" awk -F'\t' -v id="$vid" '
        BEGIN { re = "^" ENVIRON["VIOL_RE"] "$" }
        $1 == id && $2 ~ re { found = 1 }
        END { exit found ? 0 : 1 }
      ' "$observed"; then
    uncovered=$((uncovered + 1))
    echo "FAIL: 방출 커버리지 — lint:$vline 의 [$vid] 가 어느 픽스처에서도 관측되지 않았다: $vmsg" >&2
  fi
done < <(
  grep -nE '(^|[^#])viol "' "$script_dir/lint-ci-scope-binding.sh" \
    | grep -v '^[0-9]*:[[:space:]]*#' \
    | sed -n 's#^\([0-9]*\):.*viol "\([^"]*\)" "[^"]*" "\([^"]*\)".*$#\1\t\2\t\3#p'
)
if (( uncovered > 0 )); then
  failures=$((failures + 1))
fi

# The obligations above are read out of the lint, so DELETING a `viol` call
# deletes the obligation to exercise it and the loop stays silent — measured:
# neutralizing the I3 two-field site left the sweep green, because the sibling
# I3 branch keeps the `<id>|<target>` key alive and the vanished site is no
# longer asked about. A floor is what a self-derived list cannot supply itself:
# adding a site clears it, removing one has to be a deliberate edit here.
assertions=$((assertions + 1))
if (( sites < VIOL_SITE_FLOOR )); then
  echo "FAIL: 방출 자리가 $sites 개로 하한 $VIOL_SITE_FLOOR 미만이다 — viol 호출이 지워졌거나 추출식이 낡았다" >&2
  failures=$((failures + 1))
fi

# B5 emits a claim line rather than a violation, so no expected-violations.txt
# can hold it and the loop above cannot see it. It is the one number this lint
# puts in a GREEN log, which is precisely why nothing else would notice it going
# quiet.
assertions=$((assertions + 1))
if ! grep -q '^청구: ' "$observed_out"; then
  echo "FAIL: 방출 커버리지 — B5 의 청구 줄이 어느 픽스처에서도 관측되지 않았다" >&2
  failures=$((failures + 1))
fi

# Last, so that it counts every assertion the run actually made — including the
# emission-coverage ones above, which is where most of them now are.
if (( assertions < ASSERTION_FLOOR )); then
  echo "FAIL: 실행된 단언이 $assertions 개로 하한 $ASSERTION_FLOOR 미만이다 — 픽스처 루트가 비었거나 순회가 무너졌다" >&2
  failures=$((failures + 1))
fi

printf 'test-lint-ci-scope-binding: %d passed, %d failed, %d assertions\n' \
  "$passed" "$failures" "$assertions"

if (( failures > 0 )); then
  exit 1
fi
exit 0
