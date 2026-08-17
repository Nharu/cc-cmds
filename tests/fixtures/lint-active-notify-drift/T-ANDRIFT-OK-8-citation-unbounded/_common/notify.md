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

Each shape below is bounded so the extractor sees it as its own citation; a
run that is not bounded swallows the next one and the fixture then passes on
a shape it never tested.

Trailing clause: SKILL.md §7 Permission test bypass, which carries its own
narration contract;

backticks: `SKILL.md §4.6 Self-cancel` is where the model ends the cycle;

em dash: SKILL.md §4.5 Defensive fire-now — the call fires regardless when
unsure;

table cell: | SKILL.md §4.4 Fire-now ordering within the turn | fire first |;

sentence period inside a parenthesis (SKILL.md §7 Permission test bypass.)
