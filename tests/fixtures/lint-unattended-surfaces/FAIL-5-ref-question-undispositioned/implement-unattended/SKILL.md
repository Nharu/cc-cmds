# implement-unattended (fixture)

`references/` is shared with the base skill, not copied — every reference path
below points into `../implement/references/`. Nothing under that directory
carries a human-question surface, which is why sharing it is safe.

This is the shipped shape of the defect: the sentence asserts an absence, the
tree it names holds a question point, and the arm says nothing about what it
does when it arrives there.

## Control-Flow Invariants

**CFI-U1 — There is no human-question surface.** Reaching a point that needs one
is a halt, never an improvised answer and never a silent default.
