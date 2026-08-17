#!/usr/bin/env bash
# fire-oneshot is state-independent: it emits a banner with no ARM present,
# leaves a live ARM flag byte-identical, and uses its own banner group so it
# never replaces the cycle's completion banner.
#
# This is the property the scheduler delegation depends on — that path has no
# ARM cycle of its own and must not disturb one that happens to be live.
set -euo pipefail

# --- 1. No ARM at all: the banner still goes out and no flag is created. ---
[[ ! -f "$FLAG_FILE" ]] || { echo "precondition: flag should not exist yet" >&2; exit 1; }

bash "$NOTIFY_SH" fire-oneshot "scheduled" "30분 경과"

[[ ! -f "$FLAG_FILE" ]] || { echo "fire-oneshot must not create a flag" >&2; exit 1; }
[[ -f "$NOTIFIER_LOG" ]] || { echo "fire-oneshot: notifier not called without ARM" >&2; exit 1; }

# --- 2. Live ARM cycle: the flag must come through byte-identical. ---
bash "$NOTIFY_SH" arm "빌드 끝나면 알림" "build" "single" --count=1
[[ -f "$FLAG_FILE" ]] || { echo "ARM: flag missing" >&2; exit 1; }

before="${TMPDIR}/flag.before"
cp "$FLAG_FILE" "$before"

bash "$NOTIFY_SH" fire-oneshot "scheduled" "틱 1"
bash "$NOTIFY_SH" fire-oneshot "scheduled" "틱 2"

[[ -f "$FLAG_FILE" ]] || { echo "fire-oneshot consumed the ARM flag" >&2; exit 1; }
cmp -s "$before" "$FLAG_FILE" || {
  echo "fire-oneshot mutated the ARM flag" >&2
  diff "$before" "$FLAG_FILE" >&2 || true
  exit 1
}

# --- 3. The cycle still fires and consumes normally afterwards. ---
bash "$NOTIFY_SH" fire-now "build" "성공"
[[ ! -f "$FLAG_FILE" ]] || { echo "fire-now: flag should be consumed (final fire)" >&2; exit 1; }

# --- 4. Banner groups are disjoint. ---
# The tick group is a suffix of the cycle group, so the cycle assertion is
# anchored at end-of-line; a plain substring match would count tick lines too.
tick_lines=$(grep -c -- '-group cc-cmds-active-notify-tick' "$NOTIFIER_LOG" || true)
[[ "$tick_lines" == "3" ]] || {
  echo "expected 3 tick banners, got $tick_lines" >&2; cat "$NOTIFIER_LOG" >&2; exit 1
}
cycle_lines=$(grep -cE -- '-group cc-cmds-active-notify$' "$NOTIFIER_LOG" || true)
[[ "$cycle_lines" == "1" ]] || {
  echo "expected 1 cycle banner, got $cycle_lines" >&2; cat "$NOTIFIER_LOG" >&2; exit 1
}

total=$(wc -l < "$NOTIFIER_LOG" | tr -d ' ')
[[ "$total" == "4" ]] || { echo "expected 4 notifier calls total, got $total" >&2; exit 1; }

grep -q -- '-title \[cc-cmds\] scheduled' "$NOTIFIER_LOG" || { echo "tick title missing" >&2; exit 1; }
grep -q -- '-execute :' "$NOTIFIER_LOG" || { echo "-execute ':' no-op missing" >&2; exit 1; }
