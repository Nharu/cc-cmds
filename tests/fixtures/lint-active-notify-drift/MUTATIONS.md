# Mutation list for `lint-active-notify-drift.sh`

The rows live in `tests/fixtures/lint-active-notify-drift-mutations/`, one
directory per mutation, and `scripts/test-lint-active-notify-drift-mutations.sh`
runs them. **The harness is the artifact, not the list** — a list of strings
with no runner transfers its verdict to whatever machinery the next reader
builds, and the failure that produced this file was a harness reading the wrong
stream and reporting "nothing pins this" with total confidence.

This is documentation beside a runnable harness. It is **not** a gate, it is not
wired into `make lint` or `make test`, and it does not cover the class of defect
where a statement is false from the moment it is written.

## Recording a row

Each row is one single-point literal replacement. A row is admissible only with
all four of these, and the ordering below is the ordering that matters:

1. **Unique anchor** — `count(old) == 1` against the lint at the recorded
   revision. Catches an anchor that silently hits several sites and reddens
   neighbours. It fails loudly and early, while the author's intent is still
   visible.
2. **Well-formedness, unconditional** — the mutant passes `bash -n` before the
   driver runs, and the check is **not triggered by anything**. Two measured
   malformed mutants sit on opposite sides of any plausible trigger: one
   reddened every fixture in its suite, reading as the strongest possible pin
   while inflating every killer set it touched; another reddened a third of its
   suite, reading as an ordinary partial kill. A "reddens everything ⇒ presume
   malformed" rule catches the first and misses the second, and the second is
   the one that looks normal. `bash -n` is a cheap pre-filter and nothing more —
   a quote shifted one character leaves the file syntactically valid while
   destroying tokenization.
3. **Complete application** — the replacement is verified to have changed the
   file, and the driver's **stdout and stderr** are both accounted for. A
   harness reading one stream reports the conclusion this axis exists to
   produce, with full confidence and no exit code.
4. **Same-tree provenance, as a per-fixture vector** — the row declares the set
   of fixtures it reddens, not a count, and the vector is compared against a run
   of the same fixture set. A count accepts a mutation slip as the mutation it
   was meant to be: two edits that share a line can each redden exactly one
   fixture and redden *different* ones. Detection rule for a mixed-tree row:
   **the same mutation, in two runs, reddens different fixtures while the
   mutated file's bytes are identical.** Clauses 1–3 all pass on such a row.

Clause 4 is the mutant-validity check, and it only has force when the vector is
written from the property the mutation was meant to exercise, **before** the
run. A vector written from the observation always matches and certifies whatever
happened. When a run disagrees with its vector, the mutation and the fixtures
are what get investigated — never the vector. Seven rows here came back with an
empty red set on their first run; the response was four new fixtures and two
rewritten ones, not seven edited vectors.

Two of those six fixture changes are worth naming, because both were fixtures
that passed for a reason other than the one they advertised:

- the decoy fixture used `fire-now` as its near-negator, which the *trailing*
  word boundary already blocks (a `w` follows the `no`), so it said nothing
  about the leading boundary it was written for;
- the citation fixture listed its shapes in one unbounded run, and the extractor
  merged them into a single citation whose anchor resolved from the first shape
  alone — four of the five shapes were never tested.

## What a clean run licenses

A clean run licenses **"every mutation listed here is killed."** It does not
license "this fixture is unpinned", and it does not license "this property has
no coverage." Those need the list's scope, which is not in the list: a mutation
list is scoped to whatever its author was testing, so for every property outside
that scope the run returns "no mutation reddens this fixture" — byte-identical
to a measured absence of coverage.

Stated as a shape: **"X pins Y" is mechanically falsifiable; "Y is fully pinned"
is not.** Every headline figure is a coverage floor over an authored list.

**Operational tripwire**, kept as a prompt rather than as a check: a killer set
equal to the whole fixture set, or a sole-kill count that rises after an
unrelated edit, is a question the author answers before the row is recorded.

## Re-deriving the figures

Run the harness. Do not carry numbers forward from here or from a commit
message — the fixture set moves, and a figure copied across a fixture addition
is stale on arrival.

```
bash scripts/test-lint-active-notify-drift-mutations.sh --self-check
```

`--self-check` additionally runs one row against a deliberately wrong vector and
requires the harness to reject it. A harness that has never rejected anything is
indistinguishable from one that cannot.
