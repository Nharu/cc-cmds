# design-audit-unattended

## Control-Flow Invariants

### CFI-0 — Fixed constants
```
READER_COUNT = 3
```

### CFI-1 — The freeze window
The worktree half is the gate's three scoped assertions — `2a`, `2b`, and
assertion `1` within the surface it declares, all as the contract defines them.
Do not re-derive them here, and do not gloss them.

## Workflow
Custody: the creation record and the two boundary baselines live out-of-tree.
