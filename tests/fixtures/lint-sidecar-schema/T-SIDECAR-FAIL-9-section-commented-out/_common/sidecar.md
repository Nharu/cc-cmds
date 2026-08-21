# Sidecar File Contract (fixture)

Fixture for `scripts/lint-sidecar-schema.sh`. Minimal by design: it carries the
structure the pin reads and nothing else.

## 1. Generic sidecar mechanics

Generic wiring. This section names no `docs/<kind>/{slug}.md` artifact path, so
it is not a payload schema and the pin must not demand a terminator of it.

<!--
## 2. The re-convergence sidecar — `<base>/docs/design-reconverge/{slug}.md`

Header:

```
<!-- cc-design-reconverge v1; writer=implement; reader=design; owner-doc=<document key>; NOT a design doc; mechanism-local, never staged by a skill -->
```

### 2.5 Verbatim observation payloads

- **File terminator.** The last **non-empty** line of the file is the fixed sentinel `<!-- cc-design-reconverge: end -->`, emitted by every write form, the creation write included.
  Where the pre-write bytes already carry `<!-- cc-design-reconverge: end -->` it is byte-identical before and after, so it never reaches a diff gate.

-->
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
