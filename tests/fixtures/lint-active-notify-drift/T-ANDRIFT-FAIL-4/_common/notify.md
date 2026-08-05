# Active Notify (Shared Procedure)

Event-scoped repeat lifecycle.

fire-now is the only dispatch surface (SKILL.md §4.4 Fire-now ordering
within the turn); when unsure an ARM is live it fires regardless
(SKILL.md §4.5 Defensive fire-now).

Termination is user CANCEL only — this file never names the model-side
half of the contract, which is the omission the required-phrase check
exists to catch.
