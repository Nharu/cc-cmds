# Sidecar File Contract (fixture)

Everything is correct AND a payload-schema-shaped heading sits inside a fenced
example block. This must pass: the example is a picture of a declaration, not
one. It is an OK fixture on purpose — the property being covered is that the
lint does NOT false-fail, and only a passing input can carry that. A FAIL
fixture cannot: the per-section check exits before the cross-check runs, so a
file that is already failing never reaches the half being tested.
Expected: exit 0.

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

And its terminator would be shown, never declared, like this:

```
<!-- cc-visual-drift: end -->
```

## 3. The design-drift sidecar — `<base>/docs/design-drift/{slug}.md`

Header:

```
<!-- cc-design-drift v2; writer=implement; reader=review; owner-doc=<document key>; NOT a design doc; mechanism-local, never staged by a skill -->
```

### 3.6 File terminator and creation emission order

The last **non-empty** line of the file is the fixed sentinel `<!-- cc-design-drift: end -->`, emitted by every write form, the creation write included.

### 1.3 Atomic write (fixture excerpt — the guard order is pinned)

```
  [ ! -e "$SNAP" ] || guard_version   "$SNAP" || { rm -f "$SNAP"; exit 1; }
  # Truncation check — the INCOMING bytes. Must follow the version guard: an
  # intact foreign-version file is foreign, never truncated.
  [ ! -e "$SNAP" ] || intact_terminator "$SNAP" || { rm -f "$SNAP"; exit 1; }
```
