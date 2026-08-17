# Active Notify (Shared Procedure)

Event-scoped repeat lifecycle.

There is no hook-driven turn-end auto-fire — this negated statement is the
correct contract and MUST NOT be flagged.

fire-now is the only dispatch surface (SKILL.md
  §4.4 Fire-now ordering within the turn); when unsure an ARM is live it
fires regardless (SKILL.md §4.5 Defensive fire-now). The citation above is
deliberately wrapped across a line break — a line-wise scan misses it.

Bypass path per SKILL.md §7 Permission test bypass.

Termination is user CANCEL or model self-cancel.
