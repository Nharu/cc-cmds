# implement (fixture — no SOT present → lint skips before any consumer check)

This fixture deliberately omits `_common/verification.md`, so the lint hits the
SOT-absent silent-skip path and returns exit 0 (incremental-rollout posture).

The consumer file is present on purpose: the skip must happen BEFORE the
consumer check, so a fixture that carried no consumer at all could not tell the
skip path apart from "there was nothing to check anyway".
