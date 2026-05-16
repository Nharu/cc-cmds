#!/usr/bin/env bash
# Verify: no flag → Stop hook silent no-op + no fire.
set -euo pipefail

# Run the hook (no flag in FLAG_DIR — driver does not pre-create flag)
"$STOP_HOOK_SH" < "$HOOK_INPUT" > "$HOOK_STDOUT" 2> "$HOOK_STDERR"

# Hook should exit 0 (silent fail-open)
# (The driver's || handler captures non-zero exits as test failure.)

# No terminal-notifier invocation
if [[ -s "$NOTIFIER_LOG" ]]; then
  echo "FAIL: terminal-notifier was invoked (no ARM should mean no fire)" >&2
  cat "$NOTIFIER_LOG" >&2
  exit 1
fi

# Hook stdout should be empty (silent skip discipline)
if [[ -s "$HOOK_STDOUT" ]]; then
  echo "FAIL: hook produced stdout when no flag present" >&2
  cat "$HOOK_STDOUT" >&2
  exit 1
fi

exit 0
