# implement-unattended (fixture)

`references/` is shared with the base skill, not copied — every reference path
below points into `../implement/references/`. That tree is written for the
interactive arm and one file in it does route to a question, so what makes
sharing safe is a disposition, not an absence.

**Inherited question point** — `visual-fidelity-gate.md`: its Tier C fallback
routes to a question when neither recipe source is available. This arm never
arrives there, so the disposition is a halt.

The second reference file asks through the question form by bare name, and this
arm says nothing about it. A pattern that knows only AskUserQuestion walks past.

## Control-Flow Invariants

**CFI-U1 — There is no human-question surface.** Reaching a point that needs one
is a halt, never an improvised answer and never a silent default.
