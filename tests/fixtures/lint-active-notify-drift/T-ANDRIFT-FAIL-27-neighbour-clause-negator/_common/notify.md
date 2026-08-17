# Active Notify (Shared Procedure)

Single (mode=single) or event-scoped repeat (mode=repeat) lifecycle.

fire-now is the only dispatch surface, called ahead of any verification
that could strand the banner (SKILL.md §4.4 Fire-now ordering within the
turn); when unsure an ARM is live it fires regardless (SKILL.md §4.5
Defensive fire-now).

The permission-test bypass path (per SKILL.md §7 Permission test bypass)
carries its own user-narration contract.

Termination: the cycle ends when the flag is deleted, and cancel performs
the same removal whether the user issued it or the model self-cancelled.

Narration after the bypass is specified at SKILL.md §7.2 Narration after
the bypass.

The dispatcher performs turn-end auto-fire, and it owns no timer of its own.
