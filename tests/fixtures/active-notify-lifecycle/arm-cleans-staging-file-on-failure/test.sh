#!/usr/bin/env bash
# `arm` reclaims its staging file on an exit path that is not the happy path.
#
# The happy path clears `tmp` itself before exiting, so the EXIT trap's cleanup
# half is unreachable there — a fixture that only arms normally measures
# nothing. Reaching it needs `arm` to die with the staging file already written,
# and signal timing cannot hit a window tens of microseconds wide with any
# reliability. So the fixture makes `mv` fail instead, through the driver's
# stubs/ mechanism: deterministic, no race, no signal, no timing.
#
# Disclosed weakness: this fixture also reddens when the staged write itself is
# reverted, because then `arm` never calls `mv` and the induced failure never
# fires. That double red is defence in depth rather than a confusion, provided
# the diagnostic below names the real condition instead of naming the stub.
set -euo pipefail

command -v mv >/dev/null 2>&1 || { echo "setup: no mv on PATH" >&2; exit 1; }
[[ "$(command -v mv)" == "$TMPDIR"/* ]] || {
  echo "setup: the stub mv is not first on PATH (got $(command -v mv))" >&2
  exit 1
}

# Happy path first, so there is a flag to preserve and a baseline to compare.
bash "$NOTIFY_SH" arm "커밋마다 알림" "refactor" "repeat"
[[ -f "$FLAG_FILE" ]] || { echo "ARM: flag missing" >&2; exit 1; }

before="${TMPDIR}/flag.before"
cp "$FLAG_FILE" "$before"

# Now arm with mv failing. The staging write lands, the rename dies, `set -e`
# takes the script out through its EXIT trap.
rc=0
CC_FIXTURE_MV_FAIL=1 bash "$NOTIFY_SH" arm "빌드 끝나면 알림" "build" "single" 2>/dev/null || rc=$?
if (( rc == 0 )); then
  echo "arm did not stage its write through a sibling file (mv never ran) — see arm-write-is-atomic" >&2
  exit 1
fi

leftover=$(find "$FLAG_DIR" -name '*.tmp-*' 2>/dev/null | head -1)
[[ -z "$leftover" ]] || {
  echo "arm left its staging file behind after a failed rename: $leftover" >&2
  exit 1
}

# The failed call must not have damaged the cycle that was already there.
cmp -s "$before" "$FLAG_FILE" || {
  echo "a failed arm modified the existing flag" >&2
  diff "$before" "$FLAG_FILE" >&2 || true
  exit 1
}
