# Active Notify (Shared Procedure)

Single (mode=single) or event-scoped repeat (mode=repeat) lifecycle.

The permission-test bypass path (per SKILL.md §7 Permission test bypass)
carries its own user-narration contract.

Termination: the cycle ends when the flag is deleted, and cancel performs
the same removal whether the user issued it or the model self-cancelled.

The dispatcher never performs a hook-driven
turn-end auto-fire; the model owns every dispatch.
