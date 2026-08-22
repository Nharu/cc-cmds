# Verification contract (fixture placeholder)

This fixture exists to exercise the skip posture: `_common/` is present but
`_common/sidecar.md` is not, so the sidecar contract is absent from this tree
and the pin must skip silently rather than fail.

A directory needs at least one tracked file to survive a clone, which is the
only reason this file has content.
