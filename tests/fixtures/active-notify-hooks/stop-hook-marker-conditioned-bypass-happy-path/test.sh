#!/usr/bin/env bash
# milestone non-empty + marker emitted + AskUserQuestion terminal + mode
# != "repeat" → Rule 3 marker-conditioned bypass triggers → fires with
# marker copy. Verifies §3.5 PROP-R2-3 Rule 3 happy path.
set -euo pipefail

flag_file="$FLAG_DIR/pending-test-bypass-happy-path.flag"
printf '{"schema":2,"armed_at":1700000000,"session_id":"test-bypass-happy-path","request_text":"빌드 끝나면 알림","context_hint":"build","mode":"single","milestone":"빌드","fire_count":0,"last_fire_at":null}\n' > "$flag_file"

"$STOP_HOOK_SH" < "$HOOK_INPUT" > "$HOOK_STDOUT" 2> "$HOOK_STDERR"

[[ -s "$NOTIFIER_LOG" ]] || {
  echo "FAIL: bypass should fire (milestone + marker + non-repeat mode all satisfied)"
  cat "$HOOK_STDERR" >&2
  exit 1
}

grep -q -- '-title \[cc-cmds\] 빌드' "$NOTIFIER_LOG" || { echo "FAIL: workflow should be marker '빌드'"; cat "$NOTIFIER_LOG" >&2; exit 1; }
grep -q -- '-message 빌드 실패: lib.rs type mismatch' "$NOTIFIER_LOG" || { echo "FAIL: summary should be marker copy"; cat "$NOTIFIER_LOG" >&2; exit 1; }

# Happy path → no bypass-skip audit entry
if [[ -f "$FLAG_DIR/audit.log" ]] && grep -q 'bypass skipped' "$FLAG_DIR/audit.log"; then
  echo "FAIL: bypass-skip audit entry should NOT exist when bypass triggers"
  cat "$FLAG_DIR/audit.log" >&2
  exit 1
fi

exit 0
