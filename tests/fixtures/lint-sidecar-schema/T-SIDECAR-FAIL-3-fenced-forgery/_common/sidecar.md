# Sidecar File Contract (fixture)

Fence forgery: the second payload schema never *declares* its sentinel — it only
*shows* one inside an example block. A fence-blind pin passes this, which is the
whole reason the pin's heading and terminator classes are fence-aware while its
machine-header class is not. Expected: exit 1.

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

### 3.4 Write form and its diff gate

A finished file looks like this:

```text
## 이탈 1

**영향 범위**: plugins/cc-cmds/skills/_common/sidecar.md

<!-- cc-design-drift: end -->
```

Nothing outside that example fixes the sentinel as this schema's terminator.
