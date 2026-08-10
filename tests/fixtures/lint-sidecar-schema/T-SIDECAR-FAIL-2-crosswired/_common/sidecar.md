# Sidecar File Contract (fixture)

Crosswired: the second payload schema declares the *other* schema's sentinel.
A pin that only asked "does a terminator literal appear in this section" would
pass this. Expected: exit 1, naming the foreign terminator.

## 1. Generic sidecar mechanics

Generic wiring. Not a payload schema.

## 2. The re-convergence sidecar — `docs/design-reconverge/{slug}.md`

Header:

```
<!-- cc-design-reconverge v1; writer=implement; reader=design; owner-doc=<document key>; NOT a design doc; mechanism-local, never staged by a skill -->
```

### 2.5 Verbatim observation payloads

- **File terminator.** The last **non-empty** line of the file is the fixed sentinel `<!-- cc-design-reconverge: end -->`, emitted by every write form, the creation write included.

## 3. The design-drift sidecar — `docs/design-drift/{slug}.md`

Header:

```
<!-- cc-design-drift v2; writer=implement; reader=review; owner-doc=<document key>; NOT a design doc; mechanism-local, never staged by a skill -->
```

### 3.6 File terminator and creation emission order

The last **non-empty** line of the file is the fixed sentinel `<!-- cc-design-reconverge: end -->`, emitted by every write form, the creation write included.

### 1.3 Atomic write (fixture excerpt — the guard order is pinned)

```
  [ ! -e "$SNAP" ] || guard_version   "$SNAP" || { rm -f "$SNAP"; exit 1; }
  # Truncation check — the INCOMING bytes. Must follow the version guard: an
  # intact foreign-version file is foreign, never truncated.
  [ ! -e "$SNAP" ] || intact_terminator "$SNAP" || { rm -f "$SNAP"; exit 1; }
```
