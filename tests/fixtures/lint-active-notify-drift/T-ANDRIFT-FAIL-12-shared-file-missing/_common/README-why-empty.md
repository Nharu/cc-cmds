# Deliberately no notify.md

The owner table declares `_common/notify.md`, and this fixture omits it. A
declared-but-absent shared file must be a violation, not a silent skip — and
it must outrank the empty-collection exit, or the finding becomes exit 2.
