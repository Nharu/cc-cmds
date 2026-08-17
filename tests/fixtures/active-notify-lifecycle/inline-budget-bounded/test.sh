#!/usr/bin/env bash
# The inline budget is separate from, and far smaller than, the fire budget.
#
# `cancel` runs inside the model's turn, so its worst case has to stay near a
# second while the fire branch's worst case is tens of seconds. Unifying the two
# has exactly one other symptom — a suite that runs a minute longer — and
# nothing else in the repo reads the clock, so this fixture is what makes that
# collapse visible.
#
# It deliberately does NOT shim the inline budget: there is no env override for
# it, and that absence is the point. A shimmable inline budget would let this
# fixture pass while measuring nothing, which is the failure mode the seam on
# the fire budget exists to avoid rather than to spread.
set -euo pipefail

# Shim the FIRE budget only. If the two budgets were ever unified, this shim
# would also shrink the inline path and the assertion below would stop meaning
# anything — so the fixture asserts the shim did not reach it.
#
# The shim is MEASURED, not fixed. A fixed value has no defensible justification
# here: below roughly the inline budget the fixture passes while measuring
# nothing, and far above it the fixture measures the right thing but never
# finishes inside a CI job. Both edges move with the host's per-iteration cost,
# so the value is derived from that cost rather than written down.
#
# Builtins only. The macOS system bash is 3.2.57, which has no EPOCHREALTIME, so
# `SECONDS` is the clock and its resolution is one second. The loop answers that
# by GROWING THE SAMPLE until the elapsed time is big enough to divide — the
# resolution floor makes it sample more, never misjudge — and if the host outruns
# even the sample ceiling it stops loudly rather than dividing by a zero it
# quietly rounded.
calibrate_iter_ms() {
  local n=200 elapsed i
  while (( n <= 12800 )); do
    SECONDS=0
    for (( i = 0; i < n; i++ )); do sleep 0.001; done
    elapsed=$SECONDS
    if (( elapsed >= 3 )); then
      echo $(( elapsed * 1000 / n ))
      return 0
    fi
    n=$(( n * 2 ))
  done
  echo "calibration: this host ran $n lock iterations in under 3s — the sample ceiling was outrun, so no per-iteration cost can be derived" >&2
  return 1
}

iter_ms=$(calibrate_iter_ms) || exit 1
(( iter_ms > 0 )) || { echo "calibration produced ${iter_ms}ms per iteration" >&2; exit 1; }

# The separated inline path is 200 iterations. The bound has to sit clearly above
# that and clearly below what a unified path would cost, and the seam has to put
# the unified path clearly above the bound — all three derived from the one
# measured cost, so a faster or slower host moves them together.
inline_s=$(( 200 * iter_ms / 1000 ))
bound_s=$(( inline_s * 4 ))
(( bound_s < 5 )) && bound_s=5
seam=$(( 3 * bound_s * 1000 / iter_ms ))
export CC_CMDS_NOTIFY_LOCK_BUDGET_FIRE="$seam"

bash "$NOTIFY_SH" arm "커밋마다 알림" "refactor" "repeat"
[[ -f "$FLAG_FILE" ]] || { echo "ARM: flag missing" >&2; exit 1; }

lockdir="${FLAG_FILE}.lockdir"
mkdir "$lockdir" || { echo "fixture could not take the lock" >&2; exit 1; }

SECONDS=0
bash "$NOTIFY_SH" cancel
elapsed=$SECONDS

if (( elapsed >= bound_s )); then
  echo "cancel took ${elapsed}s against a derived bound of ${bound_s}s (${iter_ms}ms/iteration, seam ${seam}) — the inline budget is not bounded separately from the fire budget" >&2
  exit 1
fi

# Fail-open: the user asked to stop, so the flag goes even though the lock was
# never acquired.
[[ ! -f "$FLAG_FILE" ]] || { echo "fail-open cancel left the flag in place" >&2; exit 1; }
[[ -d "$lockdir" ]] || { echo "cancel stole the lock it never acquired" >&2; exit 1; }

rmdir "$lockdir"
