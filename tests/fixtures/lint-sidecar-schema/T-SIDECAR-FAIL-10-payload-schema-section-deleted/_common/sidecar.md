# Sidecar File Contract (fixture)

Fixture for `scripts/lint-sidecar-schema.sh`. Minimal by design: it carries the
structure the pin reads and nothing else.

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
  Where the pre-write bytes already carry `<!-- cc-design-reconverge: end -->` it is byte-identical before and after, so it never reaches a diff gate.

