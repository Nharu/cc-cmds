# Sidecar File Contract (fixture)

No H2 names an artifact path, so the file declares no payload schema at all.
A pin that iterated only over the sections it found would report success over
an empty set. Expected: exit 1.

## 1. Generic sidecar mechanics

Generic wiring. Names no `docs/<kind>/{slug}.md` artifact path.

### 1.3 Atomic write (fixture excerpt — the guard order is pinned)

```
  [ ! -e "$SNAP" ] || guard_version   "$SNAP" || { rm -f "$SNAP"; exit 1; }
  # Truncation check — the INCOMING bytes.
  [ ! -e "$SNAP" ] || intact_terminator "$SNAP" || { rm -f "$SNAP"; exit 1; }
```
