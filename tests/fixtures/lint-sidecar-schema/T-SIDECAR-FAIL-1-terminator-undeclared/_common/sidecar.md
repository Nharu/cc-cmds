# Sidecar File Contract (fixture)

The pre-fix state: the second payload schema fixes no file terminator, which is
what made an empty `$SC_TERM` contract-conforming and let the carry-forward rule
strip a required field line. Expected: `1 of 2` sections covered, exit 1.

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
<!-- cc-design-drift v1; writer=implement; reader=review; owner-doc=<document key>; NOT a design doc; mechanism-local, never staged by a skill -->
```

### 3.4 Write form and its diff gate

One write form: **append**. The writer emits a whole new `## 이탈 <N>` block with
all 8 fields through the compare-and-swap of §1.3. No terminator is fixed
anywhere in this section.

### 1.3 Atomic write (fixture excerpt — the guard order is pinned)

```
  [ ! -e "$SNAP" ] || guard_version   "$SNAP" || { rm -f "$SNAP"; exit 1; }
  # Truncation check — the INCOMING bytes. Must follow the version guard: an
  # intact foreign-version file is foreign, never truncated.
  [ ! -e "$SNAP" ] || intact_terminator "$SNAP" || { rm -f "$SNAP"; exit 1; }
```
