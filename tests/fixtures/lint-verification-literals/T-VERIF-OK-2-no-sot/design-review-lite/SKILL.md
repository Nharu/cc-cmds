# design-review-lite (fixture — no SOT present → lint skips)

This fixture deliberately omits `_common/verification.md`, so the lint hits the
SOT-absent silent-skip path and returns exit 0 (incremental-rollout posture).
