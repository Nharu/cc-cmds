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
#   expected-claim.txt       the exact B5 `청구:` lines that fixture must print,
#                            compared as a SET. Absent means the empty set, and
#                            that is the assertion that catches the claim line
#                            being emitted ABOVE the B1-B4 gate: a rejected
#                            subject tree that starts billing turns its fixture
#                            red instead of passing unnoticed.
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
#
#      That derivation has to be TOTAL over the source, and it is not total for
#      free. The extraction wants three quoted arguments, and a `viol` call
#      written across two physical lines with a trailing backslash used to match
#      the loose `grep` and then be refused by the strict `sed` — a refusal
#      indistinguishable from a line that was never named at all, so the site
#      carried no obligation and the sweep stayed green. The 26 call sites run to
#      a median of 126 columns, so wrapping the next one is an ordinary edit
#      rather than an exotic one. Two things close it: the reader consumes
#      LOGICAL lines (continuations joined, the first physical line number kept
#      for the message), and the loose count and the parsed count are asserted
#      EQUAL so any future extraction miss is a named failure.
#
#      The obligation list is a checked-in INVENTORY compared by set equality,
#      not a cardinality floor. A floor is satisfied again by a deletion paired
#      with a decoy that reuses an already-observed template, since the emission
#      set is keyed by `(rule id, template)` and pooled across the sweep — so an
#      unreachable site is exempted by a real one it shares wording with. Set
#      equality makes a deleted branch show up in review as a deleted line, and
#      a duplicate `(id, template)` pair is a hard failure because two sites with
#      identical wording are indistinguishable by construction.

set -uo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
fixtures="$repo_root/tests/fixtures/lint-ci-scope-binding"
lint_src="$script_dir/lint-ci-scope-binding.sh"
viol_inventory="$fixtures/expected-viol-sites.txt"

ASSERTION_FLOOR=60

if [[ ! -d "$fixtures" ]]; then
  echo "FAIL: fixtures root missing: $fixtures" >&2
  exit 2
fi

# The lint enumerates its corpus with `git ls-files` and falls back to `find`
# when that comes back empty, and `find` does not honour `.gitignore`. So the
# verdict used to depend on WHERE the fixture tree sat: copied outside a
# repository, an ignored fixture file the lint should have reported was swept
# into the corpus and the suite went green on the very defect CI was red for.
# The lint names its enumerator on every summary line precisely so the
# transition is readable; nothing read it. Both branches below assert, so the
# pass/fail verdict no longer moves with the location — only which enumerator is
# named, and that is stated out loud.
if git -C "$fixtures" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  inside_repo=1
else
  inside_repo=0
  echo "NOTE: 픽스처 트리가 git 레포 밖이다 — 린트가 find 열거자로 떨어지며 이 런은 그 사실을 단언한다. 무시-삼킴 탐지는 이 위치에서 불가능하다"
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

  # B5's billing line, pinned PER FIXTURE against the exact expected lines. A
  # sweep-wide `grep -q '^청구: '` says only that some fixture somewhere printed
  # one, and exactly two fixtures do — so either of them discharged the whole
  # sweep's obligation while the number went wrong, the owner went wrong, or the
  # line climbed above the B1-B4 gate. All three of those mutations were green.
  # The fixtures with no expectation file assert ZERO claim lines, and that is
  # the half that catches a rejected subject tree starting to bill.
  expected_claim="$fixture/expected-claim.txt"
  if [[ -f "$expected_claim" ]]; then
    want_c=$(grep -v '^$' "$expected_claim" | sort)
  else
    want_c=""
  fi
  got_c=$(grep '^청구: ' "$stdout_capture" | sort)
  assertions=$((assertions + 1))
  if [[ "$got_c" != "$want_c" ]]; then
    fixture_ok=0
    echo "FAIL: $fixture_name (B5 청구 줄이 기대와 다르다)" >&2
    echo "  expected:" >&2
    printf '%s\n' "$want_c" | sed 's/^/    /' >&2
    echo "  actual:" >&2
    printf '%s\n' "$got_c" | sed 's/^/    /' >&2
  fi

  # The enumerator the lint actually used. Fixtures that abort before the
  # summary line — the `ERR-*` class, and any fixture whose `die2` fires — never
  # print one, so asserting on them unconditionally would redden them for a
  # reason that has nothing to do with enumeration.
  if grep -qh 'ci-scope-binding — 필터 글로브' "$stdout_capture" "$stderr_capture"; then
    assertions=$((assertions + 1))
    if (( inside_repo == 1 )); then
      if ! grep -qh '(git ls-files)' "$stdout_capture" "$stderr_capture"; then
        fixture_ok=0
        echo "FAIL: $fixture_name (레포 안인데 린트가 git ls-files 로 열거하지 않았다 — find 폴백은 무시된 파일을 코퍼스에 넣는다)" >&2
      fi
    else
      if ! grep -qh '(find)' "$stdout_capture" "$stderr_capture"; then
        fixture_ok=0
        echo "FAIL: $fixture_name (레포 밖인데 린트가 find 로 열거하지 않았다)" >&2
      fi
    fi
  fi

  # The guard the first review asked for alongside whichever fix was chosen:
  # a fixture file swallowed by the host repo's ignore rules is present to
  # `find` and absent from `git ls-files`, and that difference is the whole
  # class. Naming the files turns "CI is red and nobody knows why" into a named
  # failure. Only meaningful inside a repository — outside one there is no
  # ignore information to compare against, which is stated in the NOTE above.
  if (( inside_repo == 1 )); then
    assertions=$((assertions + 1))
    fx_tracked=$( (cd "$fixture" && git -c core.quotePath=false ls-files -z 2>/dev/null) \
      | tr '\0' '\n' | grep -v '^$' | sort )
    fx_found=$( (cd "$fixture" && find . -type f 2>/dev/null) | sed -E 's|^\./||' | sort )
    fx_swallowed=$(comm -13 <(printf '%s\n' "$fx_tracked") <(printf '%s\n' "$fx_found") | grep -v '^$')
    if [[ -n "$fx_swallowed" ]]; then
      fixture_ok=0
      echo "FAIL: $fixture_name (픽스처 파일이 tracked 가 아니다 — 호스트 레포의 무시 규칙에 삼켜졌거나 add 되지 않았다)" >&2
      printf '%s\n' "$fx_swallowed" | sed 's/^/    /' >&2
    fi
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

# Physical lines folded into logical ones: a trailing backslash continues, and
# the leading whitespace of the continued line collapses to a single space the
# way the shell's own word splitting would see it. The FIRST physical line
# number is what is carried forward, so `lint:<n>` in a message still points at
# the line a reader would go to.
logical_lines() {
  awk '
    {
      line = $0
      if (buf == "") start = NR
      if (line ~ /\\$/) {
        sub(/[ \t]*\\$/, "", line)
        if (buf == "") { buf = line } else { sub(/^[ \t]+/, " ", line); buf = buf line }
        next
      }
      if (buf != "") { sub(/^[ \t]+/, " ", line); line = buf line; buf = "" }
      printf "%d\t%s\n", start, line
    }
    END { if (buf != "") printf "%d\t%s\n", start, buf }
  ' "$1"
}

# Loose: every logical line that calls `viol`, excluding commented-out ones.
# Strict: the same lines with the three quoted arguments pulled out. The two are
# asserted equal below; that equality is what makes the derivation total.
loose_sites=$(logical_lines "$lint_src" \
  | grep -E '(^|[^#])viol "' \
  | grep -vE '^[0-9]+	[[:space:]]*#')
parsed_sites=$(printf '%s\n' "$loose_sites" \
  | sed -n 's#^\([0-9]*\)	.*viol "\([^"]*\)" "[^"]*" "\([^"]*\)".*$#\1	\2	\3#p')

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
done < <(printf '%s\n' "$parsed_sites")
if (( uncovered > 0 )); then
  failures=$((failures + 1))
fi

# Every logical line the loose match named must have been parsed. A `sed` that
# refuses a line it was handed looks exactly like a line that was never handed
# to it, so without this the extraction can go partial in silence — and going
# partial is what removes a site's obligation.
assertions=$((assertions + 1))
unparsed_sites=$(comm -13 \
  <(printf '%s\n' "$parsed_sites" | grep -v '^$' | cut -f1 | sort -u) \
  <(printf '%s\n' "$loose_sites" | grep -v '^$' | cut -f1 | sort -u))
if [[ -n "$unparsed_sites" ]]; then
  echo "FAIL: 방출 커버리지 — viol 호출로 지명됐으나 세 인자 추출에 실패한 줄이 있다 — 그 자리는 아무 의무도 지지 않는다:" >&2
  printf '%s\n' "$unparsed_sites" | sed 's/^/  lint:/' >&2
  failures=$((failures + 1))
fi

# Two sites with identical `(rule id, template)` are indistinguishable by
# construction: the emission set is pooled across the sweep, so one of them is
# discharged by the other's output and can never be asked about on its own.
# That makes the duplicate itself the error, not a thing to tolerate.
assertions=$((assertions + 1))
dup_keys=$(printf '%s\n' "$parsed_sites" | grep -v '^$' | cut -f2,3 | sort | uniq -d)
if [[ -n "$dup_keys" ]]; then
  echo "FAIL: 방출 커버리지 — (규칙 id, 템플릿) 이 같은 자리가 둘 이상이다 — 서로를 면제하므로 문면을 갈라야 한다:" >&2
  while IFS= read -r dk; do
    [[ -n "$dk" ]] || continue
    dl=$(printf '%s\n' "$parsed_sites" | awk -F'\t' -v k="$dk" '$2 "\t" $3 == k { printf "%s ", $1 }')
    echo "  [$dk] — lint:$dl" >&2
  done <<EOF
$dup_keys
EOF
  failures=$((failures + 1))
fi

# The obligations above are read out of the lint, so DELETING a `viol` call
# deletes the obligation to exercise it and the loop stays silent — measured:
# neutralizing the I3 two-field site left the sweep green, because the sibling
# I3 branch keeps the `<id>|<target>` key alive and the vanished site is no
# longer asked about. A cardinality floor does not answer that: a deletion paired
# with a decoy reusing an observed template restores the count exactly. A
# checked-in inventory compared by SET EQUALITY does — a removed branch arrives
# in review as a removed line, and drift in either direction is named.
assertions=$((assertions + 1))
derived_inventory=$(printf '%s\n' "$parsed_sites" | grep -v '^$' | cut -f2,3 | sort -u)
if [[ ! -f "$viol_inventory" ]]; then
  echo "FAIL: 방출 자리 인벤토리가 없다: $viol_inventory" >&2
  failures=$((failures + 1))
else
  want_inventory=$(grep -v '^$' "$viol_inventory" | sort -u)
  if [[ "$derived_inventory" != "$want_inventory" ]]; then
    echo "FAIL: 방출 자리 인벤토리가 린트의 실제 viol 자리와 다르다 — 갈래가 지워졌거나 새 갈래가 등록되지 않았다" >&2
    echo "  인벤토리에만 있다(지워진 갈래):" >&2
    comm -23 <(printf '%s\n' "$want_inventory") <(printf '%s\n' "$derived_inventory") | sed 's/^/    /' >&2
    echo "  린트에만 있다(등록되지 않은 갈래):" >&2
    comm -13 <(printf '%s\n' "$want_inventory") <(printf '%s\n' "$derived_inventory") | sed 's/^/    /' >&2
    failures=$((failures + 1))
  fi
fi

# B5 emits a claim line rather than a violation, so no expected-violations.txt
# can hold it and the loop above cannot see it. It is the one number this lint
# puts in a GREEN log, which is precisely why nothing else would notice it going
# quiet. The per-fixture `expected-claim.txt` assertions carry the real weight;
# this sweep-wide check stays as a COLLAPSE guard, because if the fixture root
# went empty every per-fixture assertion would pass vacuously.
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
