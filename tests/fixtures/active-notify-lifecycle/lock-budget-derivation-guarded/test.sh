#!/usr/bin/env bash
# A cost constant that is not a valid bash integer cannot take the dispatcher
# down silently.
#
# The two lock budgets are derived arithmetically from that constant. A
# non-integer value makes both derivations fail without stopping the script
# under `set -e`, which leaves the names UNSET rather than empty; the first use
# then takes `set -u`, and bash 3.2.57 — the system bash on macOS — reports that
# through an exit status of 0. The whole dispatcher then returns success having
# written no flag and printed nothing, which is the worst available shape: the
# user is told the notification is armed and no banner ever arrives.
#
# The constant is source rather than env, deliberately, because the fixture that
# bounds the inline budget is the only thing measuring the separation between
# the two budgets and a shimmable inline budget would let it pass while
# measuring nothing. So this fixture rewrites the constant in a scratch copy
# instead of shimming it. Copying the script under test is unusual for this
# suite; the alternative is to leave the guard unpinned.
set -euo pipefail

scratch="${TMPDIR}/notify-badcost.sh"
sed 's/^LOCK_ITER_COST_MS=5$/LOCK_ITER_COST_MS=4.9/' "$NOTIFY_SH" > "$scratch"

# The rewrite has to have happened, or everything below is measuring the
# shipped constant and passes for the wrong reason.
grep -q '^LOCK_ITER_COST_MS=4\.9$' "$scratch" || {
  echo "setup: the cost constant was not rewritten in the scratch copy" >&2
  exit 1
}

rc=0
bash "$scratch" arm "빌드 끝나면 알림" "build" "single" 2>/dev/null || rc=$?

[[ -f "$FLAG_FILE" ]] || {
  echo "arm wrote no flag when the cost constant was unusable (exit $rc) — the derived budgets are not validated before first use" >&2
  exit 1
}
grep -q '"mode":"single"' "$FLAG_FILE" || {
  echo "the flag written under the fallback budget is not the requested cycle" >&2
  cat "$FLAG_FILE" >&2
  exit 1
}

# The shipped constant must still take the derivation path rather than the
# fallback, otherwise the guard could be masking a broken derivation.
bash "$NOTIFY_SH" cancel
bash "$NOTIFY_SH" arm "커밋마다 알림" "refactor" "repeat"
grep -q '"mode":"repeat"' "$FLAG_FILE" || {
  echo "the unmodified dispatcher no longer arms normally" >&2
  exit 1
}
