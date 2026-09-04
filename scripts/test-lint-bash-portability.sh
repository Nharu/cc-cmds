#!/usr/bin/env bash
# lint-bash-portability: self-skip
# Test scripts/lint-bash-portability.sh against tests/fixtures/lint-bash-portability/.
#
# Each fixture is a directory containing one or more `*.sh` files. The fixture
# directory name encodes the expected exit code:
#   OK-*   → expected exit 0 (lint passes — clean / escape-suppressed / self-skip)
#   FAIL-* → expected exit 1 (lint detects at least one violation)
#
# Exit-code 2 (no scannable files) is not covered — every fixture ships at
# least one `*.sh` file, so the empty branch is tested by prevention.
#
# Hit assertions. A fixture may also ship an `expected-hits.txt` listing the
# exact violations it should produce, one per line as
#
#   <file basename>:<line number>:<idiom id>
#
# in any order. When that file is present the reported violations must match it
# as a set. The exit code alone cannot see a violation reported against the
# wrong line, and line numbers are precisely what a change to how the lint walks
# a file can shift — a candidate line carrying its number from a separate pass
# has to agree with what a straight line-by-line read would have counted,
# including on a final line with no terminating newline. `expected-hits.txt` is
# not scanned by the lint itself, which only picks up `*.sh`.

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
fixtures="$repo_root/tests/fixtures/lint-bash-portability"

# The lint nominates candidate lines under the ambient locale as well as under
# `LC_ALL=C`, and a fixture can only hold the ambient half in place while the
# ambient locale actually decodes UTF-8: on a host that leaves LANG unset the two
# passes are one pass, a multibyte space stops being a space, and the fixture
# that guards the ambient half reports a clean file. So pin the locale for every
# fixture run instead of inheriting whatever the runner happens to export. The
# probe asks for the property itself rather than trusting a name, and the
# candidates span Apple libc (which has no C.UTF-8) and glibc (where en_US is not
# always generated).
utf8_locale=""
for candidate in "${LC_ALL:-}" "${LANG:-}" en_US.UTF-8 C.UTF-8; do
  [[ -n "$candidate" ]] || continue
  if printf 'a\302\240b\n' | LC_ALL="$candidate" grep -qE 'a[[:space:]]b' 2>/dev/null; then
    utf8_locale="$candidate"
    break
  fi
done

# Where the probe comes up empty the suite skips the fixtures that turn on the
# ambient pass rather than standing the whole run down. glibc dropped U+00A0
# from the space class, so on such a host no locale can make the ambient pass
# differ from the C-pinned one and the lint reports the multibyte-space file
# clean whatever it is given — the property those fixtures guard is not a
# property that host has. Failing them would redden a leg for something
# unreachable there, and passing them would let a real regression hide behind an
# assertion that never ran. Every other fixture is ASCII and its verdict does
# not move with the locale, so the rest of the suite runs as usual.
locale_dependent_fixtures="FAIL-16-multibyte-space"
skip_reason=""
if [[ -z "$utf8_locale" ]]; then
  skip_reason="no locale on this host classifies U+00A0 as space, so the lint's ambient pre-filter pass cannot be told from its C-pinned one"
fi

if [[ ! -d "$fixtures" ]]; then
  echo "FAIL: fixtures root missing: $fixtures" >&2
  exit 2
fi

stderr_capture=$(mktemp "${TMPDIR:-/tmp}/test-lint-bash-portability.XXXXXX")
trap 'rm -f "$stderr_capture"' EXIT

passed=0
failures=0
skipped=0

for fixture in "$fixtures"/*/; do
  fixture_name=$(basename "$fixture")
  case "$fixture_name" in
    OK-*)   want=0 ;;
    FAIL-*) want=1 ;;
    *)
      echo "test-lint-bash-portability: fixture '$fixture_name' has unrecognized prefix" >&2
      failures=$((failures + 1))
      continue
      ;;
  esac

  if [[ -n "$skip_reason" ]] && [[ " $locale_dependent_fixtures " == *" $fixture_name "* ]]; then
    skipped=$((skipped + 1))
    printf 'SKIP: %s — %s\n' "$fixture_name" "$skip_reason"
    continue
  fi

  set +e
  if [[ -n "$utf8_locale" ]]; then
    LC_ALL="$utf8_locale" SCAN_ROOT="$fixture" bash "$script_dir/lint-bash-portability.sh" \
      >/dev/null 2>"$stderr_capture"
  else
    SCAN_ROOT="$fixture" bash "$script_dir/lint-bash-portability.sh" \
      >/dev/null 2>"$stderr_capture"
  fi
  ec=$?
  set -e

  fixture_ok=1

  if [[ "$ec" != "$want" ]]; then
    fixture_ok=0
    echo "FAIL: $fixture_name (exit=$ec, expected=$want)" >&2
  fi

  expected_hits="$fixture/expected-hits.txt"
  if [[ -f "$expected_hits" ]]; then
    # Reduce each violation report to `<basename>:<line>:<idiom id>`. The idiom
    # id is captured greedily so an id that itself contains quotes — `sed -i ''`
    # is one — still stops at the closing quote before ` detected in`.
    actual_hits=$(
      sed -n \
        "s|^FAIL: BSD/GNU divergent idiom '\(.*\)' detected in .*/\([^/:]*\):\([0-9][0-9]*\)$|\2:\3:\1|p" \
        "$stderr_capture" | sort
    )
    want_hits=$(sort "$expected_hits")
    if [[ "$actual_hits" != "$want_hits" ]]; then
      fixture_ok=0
      echo "FAIL: $fixture_name (hits differ from expected-hits.txt)" >&2
      echo "  expected:" >&2
      printf '%s\n' "$want_hits" | sed 's/^/    /' >&2
      echo "  actual:" >&2
      printf '%s\n' "$actual_hits" | sed 's/^/    /' >&2
    fi
  fi

  if (( fixture_ok == 1 )); then
    passed=$((passed + 1))
    echo "PASS: $fixture_name (exit=$ec, expected=$want)"
  else
    failures=$((failures + 1))
  fi
done

printf 'test-lint-bash-portability: %d passed, %d failed, %d skipped\n' \
  "$passed" "$failures" "$skipped"

if (( failures > 0 )); then
  exit 1
fi
exit 0
