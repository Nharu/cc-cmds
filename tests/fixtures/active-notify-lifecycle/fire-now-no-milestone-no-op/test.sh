#!/usr/bin/env bash
# fire-now invoked against a generic ARM (milestone empty) MUST silently
# no-op and append an audit-log entry. The notifier stub must NOT be
# invoked, and the flag MUST be preserved (no dispatcher consumption).
set -euo pipefail

# Generic ARM — no --milestone flag
bash "$NOTIFY_SH" arm "끝나면 알려줘" "task" single
[[ -f "$FLAG_FILE" ]] || { echo "ARM: flag missing"; exit 1; }

# Sanity — milestone field is empty
milestone=$(jq -r '.milestone // empty' "$FLAG_FILE")
[[ -z "$milestone" ]] || { echo "ARM: milestone should be empty, got '$milestone'"; exit 1; }

bash "$NOTIFY_SH" fire-now "task" "completed"

# Notifier MUST NOT be invoked
[[ ! -s "$NOTIFIER_LOG" ]] || { echo "FAIL: notifier invoked despite empty-milestone fire-now"; cat "$NOTIFIER_LOG" >&2; exit 1; }

# Flag MUST be preserved (no consumption)
[[ -f "$FLAG_FILE" ]] || { echo "FAIL: flag was consumed (fire-now should silent no-op)"; exit 1; }

# Audit log MUST contain the silent-no-op entry
audit_log="$FLAG_DIR/audit.log"
[[ -f "$audit_log" ]] || { echo "FAIL: audit.log not written"; exit 1; }
grep -q 'fire-now invoked with empty milestone (silent no-op)' "$audit_log" || {
  echo "FAIL: audit entry missing"
  cat "$audit_log" >&2
  exit 1
}

exit 0
