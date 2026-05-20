#!/usr/bin/env bash
# --count=N parse-anywhere + normalize-to-1 for invalid values (non-integer,
# zero, over-cap >16). Mirror of the mode normalize-to-single policy.
set -euo pipefail

# Typical position: --count after mode.
bash "$NOTIFY_SH" arm "req" "ctx" "single" --count=3
[[ -f "$FLAG_FILE" ]] || { echo "ARM failed" >&2; exit 1; }
grep -q '"schema":3' "$FLAG_FILE" || { echo "schema not 3" >&2; exit 1; }
grep -q '"arm_count":3' "$FLAG_FILE" || { echo "arm_count not 3" >&2; cat "$FLAG_FILE" >&2; exit 1; }

# Default (no --count) → 1.
bash "$NOTIFY_SH" arm "req" "ctx" "single"
grep -q '"arm_count":1' "$FLAG_FILE" || { echo "default arm_count not 1" >&2; exit 1; }

# Non-integer → 1.
bash "$NOTIFY_SH" arm "req" "ctx" "single" --count=abc
grep -q '"arm_count":1' "$FLAG_FILE" || { echo "non-integer should normalize to 1" >&2; cat "$FLAG_FILE" >&2; exit 1; }

# Zero → 1.
bash "$NOTIFY_SH" arm "req" "ctx" "single" --count=0
grep -q '"arm_count":1' "$FLAG_FILE" || { echo "zero should normalize to 1" >&2; exit 1; }

# Negative-looking ("-1") → not [0-9]+ → 1.
bash "$NOTIFY_SH" arm "req" "ctx" "single" --count=-1
grep -q '"arm_count":1' "$FLAG_FILE" || { echo "negative should normalize to 1" >&2; exit 1; }

# Over-cap (17) → 1.
bash "$NOTIFY_SH" arm "req" "ctx" "single" --count=17
grep -q '"arm_count":1' "$FLAG_FILE" || { echo "over-cap should normalize to 1" >&2; exit 1; }

# Boundary: 16 (max valid).
bash "$NOTIFY_SH" arm "req" "ctx" "single" --count=16
grep -q '"arm_count":16' "$FLAG_FILE" || { echo "16 (boundary) should be accepted" >&2; exit 1; }

# Boundary: 1 (min valid).
bash "$NOTIFY_SH" arm "req" "ctx" "single" --count=1
grep -q '"arm_count":1' "$FLAG_FILE" || { echo "1 should be accepted" >&2; exit 1; }

# milestone field must not appear in v2 schema:3.
grep -qv '"milestone"' "$FLAG_FILE" || { echo "milestone field should not exist" >&2; exit 1; }

[[ ! -f "$NOTIFIER_LOG" ]] || { echo "ARM should not call notifier" >&2; exit 1; }
