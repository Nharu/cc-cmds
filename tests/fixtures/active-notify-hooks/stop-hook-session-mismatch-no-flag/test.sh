#!/usr/bin/env bash
# Verify two sub-cases for no-flag exit guards:
#   (a) flag dir absent → entry guard `[[ -d $flag_dir ]] || exit 0`
#   (b) flag dir exists + glob 0 matches → β fallback exit before audit
# Both must be: no terminal-notifier, no audit.log line, no stdout.
set -euo pipefail

# Sub-case (a): no FLAG_DIR. Driver pre-creates FLAG_DIR by default, so remove it.
rm -rf "$FLAG_DIR"

"$STOP_HOOK_SH" < "$HOOK_INPUT" > "$HOOK_STDOUT" 2> "$HOOK_STDERR"

if [[ -s "$NOTIFIER_LOG" ]]; then
  echo "FAIL (a): terminal-notifier invoked when flag dir absent" >&2
  exit 1
fi
if [[ -f "$FLAG_DIR/audit.log" ]]; then
  echo "FAIL (a): audit.log created when flag dir absent" >&2
  exit 1
fi
if [[ -s "$HOOK_STDOUT" ]]; then
  echo "FAIL (a): hook produced stdout" >&2
  exit 1
fi

# Sub-case (b): empty flag dir
mkdir -p "$FLAG_DIR"
: > "$HOOK_STDOUT"  # reset
: > "$HOOK_STDERR"
: > "$NOTIFIER_LOG"

"$STOP_HOOK_SH" < "$HOOK_INPUT" > "$HOOK_STDOUT" 2> "$HOOK_STDERR"

if [[ -s "$NOTIFIER_LOG" ]]; then
  echo "FAIL (b): terminal-notifier invoked when no flags in dir" >&2
  exit 1
fi
if [[ -f "$FLAG_DIR/audit.log" ]]; then
  echo "FAIL (b): audit.log created when no flags in dir" >&2
  exit 1
fi
if [[ -s "$HOOK_STDOUT" ]]; then
  echo "FAIL (b): hook produced stdout" >&2
  exit 1
fi

exit 0
