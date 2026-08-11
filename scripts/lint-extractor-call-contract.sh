#!/usr/bin/env bash
# Assert the SHAPE of every `extract_between` call site.
#
# WHY A LINT AND NOT FIXTURES. The call contract in `_extract-between.sh` binds
# each call site individually, but the fixtures that were supposed to enforce it
# only reach some of them: removing the guard from ONE call site was measured to
# turn a fixture red at 5 of 11 sites, and the six blind ones include the largest
# region in the tree. The recorded verification reverted all eleven at once,
# which is not how a regression arrives — it arrives at one site. Worse, the four
# call sites added most recently had coverage 0/4: the count of call sites grew
# 57% and guard-regression coverage did not grow at all.
#
# A shape lint is uniform where fixtures are incidental. It reads the call site
# rather than the consequence, so it covers all eleven identically and covers
# every call site added after it, which is the half fixtures can never do.
#
# WHAT IT DOES NOT COVER, stated because the gap is load-bearing. This checks
# contract item (1) — the `if` guard — and nothing else. Item (2), the sentinel
# assignment on the failure path, has no mechanical check here: a call site that
# is guarded but omits the sentinel passes this lint and then reports untouched
# literals as missing. That is exactly the shape a caller would copy out of the
# helper's own canonical example, which is why that example carries the sentinel
# and why keeping it correct is not cosmetic.
#
# Usage:
#   bash scripts/lint-extractor-call-contract.sh
#   SCRIPTS_ROOT=<dir> bash scripts/lint-extractor-call-contract.sh   # fixture test
#
# Exit codes:
#   0 — every call site is guarded (or there are no call sites → skip)
#   1 — at least one call site is unguarded

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
scripts_root="${SCRIPTS_ROOT:-$script_dir}"
# Normalize: a caller passing a fixture path with a trailing slash would
# otherwise defeat the prefix strip below and emit an absolute path, which no
# fixture declaration can reproduce across machines.
scripts_root="${scripts_root%/}"

HELPER='_extract-between.sh'

fail=0
sites=0
files=0

while IFS= read -r f; do
  case "$(basename "$f")" in
    "$HELPER") continue ;;
  esac
  files=$((files + 1))
  # A call site is a line that substitutes the helper. Comment lines are prose
  # about the contract, not uses of it, so they are skipped — otherwise the
  # contract's own documentation would be its first violation.
  while IFS=: read -r n line; do
    case "${line#"${line%%[![:space:]]*}"}" in
      '#'*) continue ;;
    esac
    sites=$((sites + 1))
    if [[ "${line#"${line%%[![:space:]]*}"}" != if\ * ]]; then
      echo "FAIL: ${f#"$scripts_root/"}:$n — extract_between call site is not guarded by \`if\` on its own line; a bare assignment aborts the script at that line under \`set -euo pipefail\` and loses every later diagnostic" >&2
      fail=1
    fi
  done < <(grep -nE '=\$\(extract_between' "$f" || true)
done < <(find "$scripts_root" -maxdepth 1 -type f -name '*.sh' | sort)

if (( fail == 0 )); then
  if (( sites == 0 )); then
    echo "SKIP: no extract_between call sites under $scripts_root"
    exit 0
  fi
  echo "OK:   extractor call contract — $sites call site(s) across $files file(s), all guarded by \`if\` (item (1) only; the sentinel assignment of item (2) is prose-enforced)"
fi

exit "$fail"
