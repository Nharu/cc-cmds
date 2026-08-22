# Sidecar File Contract (fixture)

A heading that LOOKS like a payload schema sits inside a fenced example block,
and the second payload schema has lost its terminator. A fence-blind reader
counts the example as a third section and reports the wrong kind missing; a
fence-aware one reports the real defect. Both halves of the lint must agree on
what a section is, and this fixture is where they are made to.
Expected: exit 1, naming the design-drift terminator and nothing about visual-drift.

## 1. Generic sidecar mechanics

Generic wiring. This section names no `docs/<kind>/{slug}.md` artifact path, so
it is not a payload schema and the pin must not demand a terminator of it.

## 2. The re-convergence sidecar — `<base>/docs/design-reconverge/{slug}.md`

Header:

```
<!-- cc-design-reconverge v1; writer=implement; reader=design; owner-doc=<document key>; NOT a design doc; mechanism-local, never staged by a skill -->
```

### 2.5 Verbatim observation payloads

- **File terminator.** The last **non-empty** line of the file is the fixed sentinel `<!-- cc-design-reconverge: end -->`, emitted by every write form, the creation write included.

A future kind would be declared like this:

```
## 4. The visual-drift sidecar — `<base>/docs/visual-drift/{slug}.md`
```

## 3. The design-drift sidecar — `<base>/docs/design-drift/{slug}.md`

Header:

```
<!-- cc-design-drift v2; writer=implement; reader=review; owner-doc=<document key>; NOT a design doc; mechanism-local, never staged by a skill -->
```

### 3.6 File terminator and creation emission order

No terminator is fixed anywhere in this section.

### 1.3 Atomic write (fixture excerpt — the guard order is pinned)

```
  [ ! -e "$SNAP" ] || guard_version   "$SNAP" || { rm -f "$SNAP"; exit 1; }
  # Truncation check — the INCOMING bytes. Must follow the version guard: an
  # intact foreign-version file is foreign, never truncated.
  [ ! -e "$SNAP" ] || intact_terminator "$SNAP" || { rm -f "$SNAP"; exit 1; }
```
