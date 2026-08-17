#!/usr/bin/env bash
# The fire branch releases its lock BEFORE the banner stage and does not take it
# back on the way out.
#
# The early `rmdir` exists to keep hold time short: `terminal-notifier` is the
# slow part and nothing after the flag mutation needs the lock. That release is
# paired with `lock_held=0`, and the pairing is what this fixture pins — drop
# the assignment and the EXIT trap removes a lockdir that, by then, belongs to
# whoever took it during the banner stage.
#
# The window is opened deterministically rather than by timing: a stub
# `terminal-notifier` blocks until this fixture releases it, so the fixture is
# guaranteed to be inside the banner stage when it claims the lock.
set -euo pipefail

gate="${TMPDIR}/banner-gate"
mkdir -p "${TMPDIR}/stubs"
cat > "${TMPDIR}/stubs/terminal-notifier" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "\$NOTIFIER_LOG"
# Hold the banner stage open until the fixture says go.
while [ ! -e "$gate" ]; do sleep 0.01; done
exit 0
STUB
chmod +x "${TMPDIR}/stubs/terminal-notifier"
export PATH="${TMPDIR}/stubs:$PATH"

bash "$NOTIFY_SH" arm "커밋마다 알림" "refactor" "repeat"
[[ -f "$FLAG_FILE" ]] || { echo "ARM: flag missing" >&2; exit 1; }

lockdir="${FLAG_FILE}.lockdir"

bash "$NOTIFY_SH" fire-now "build" "성공" &
fire_pid=$!

# Wait for the banner stage, which is entered only after the early release.
for _ in $(seq 500); do
  [[ -s "${NOTIFIER_LOG:-/dev/null}" ]] && break
  sleep 0.01
done
[[ -s "${NOTIFIER_LOG:-/dev/null}" ]] || {
  echo "fire-now never reached the banner stage" >&2
  touch "$gate"; wait "$fire_pid" 2>/dev/null || true
  exit 1
}

# The lock must already be free at this point.
mkdir "$lockdir" || {
  echo "fire-now still held the lock during the banner stage" >&2
  touch "$gate"; wait "$fire_pid" 2>/dev/null || true
  exit 1
}

touch "$gate"
wait "$fire_pid"

[[ -d "$lockdir" ]] || { echo "fire-now's exit removed a lock it had already released" >&2; exit 1; }

rmdir "$lockdir"
