#!/usr/bin/env bash
# A scheduled tick always says why it produced no banner.
#
# The tick runs with nobody watching and its precondition check happened back
# when the job was queued, so the stderr line is the only trace it can leave.
# Any sentinel silences it, and the two sentinel shapes fail differently — hence
# two assertions rather than one:
#
#   - sharing the ARM cycle's sentinel silences every tick that runs after some
#     earlier call has already left one behind;
#   - giving the tick its own sentinel silences every tick after the first.
#
# The first assertion is what the earlier separation fix bought. The second is
# what it did not: the failure moved from "always silent" to "silent after the
# first tick" and this fixture is what keeps it from moving back.
set -euo pipefail

if command -v terminal-notifier >/dev/null 2>&1; then
  echo "fixture setup error: terminal-notifier still on PATH ($(command -v terminal-notifier))" >&2
  exit 1
fi

# Drive the cycle path first so the ARM cycle's sentinel exists.
bash "$NOTIFY_SH" arm "커밋마다 알림" "refactor" "repeat"
[[ -f "$FLAG_FILE" ]] || { echo "ARM: flag missing" >&2; exit 1; }

cycle_err=$(bash "$NOTIFY_SH" fire-now "refactor" "커밋 1" 2>&1 1>/dev/null)
echo "$cycle_err" | grep -q 'install terminal-notifier' || {
  echo "setup: the cycle path did not emit its missing-notifier hint" >&2
  printf '%s\n' "$cycle_err" >&2
  exit 1
}
[[ -f "$NOTIFIER_HINT" ]] || { echo "setup: the cycle sentinel was not created" >&2; exit 1; }

# 1. A tick after the cycle sentinel exists must still speak.
tick1=$(bash "$NOTIFY_SH" fire-oneshot "scheduled" "틱 1" 2>&1 1>/dev/null)
echo "$tick1" | grep -q 'install terminal-notifier' || {
  echo "tick 1 was silenced by the ARM cycle's sentinel" >&2
  exit 1
}

# 2. The next tick must speak too.
tick2=$(bash "$NOTIFY_SH" fire-oneshot "scheduled" "틱 2" 2>&1 1>/dev/null)
echo "$tick2" | grep -q 'install terminal-notifier' || {
  echo "tick 2 was silenced by a sentinel of the tick path's own" >&2
  exit 1
}

# The tick path reads and writes no cycle state, so the flag is untouched.
[[ -f "$FLAG_FILE" ]] || { echo "a tick consumed the ARM flag" >&2; exit 1; }
