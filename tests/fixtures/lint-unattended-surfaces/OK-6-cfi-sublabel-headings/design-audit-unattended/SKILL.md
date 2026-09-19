# design-audit-unattended

## Control-Flow Invariants

### CFI-0 — Fixed constants
```
READER_COUNT = 3
```

### CFI-1 — The freeze window
The worktree half is the gate's three scoped assertions — `2a`, `2b`, `2c`, and
assertion `1` within the surface it declares, all as the contract defines them.
Do not re-derive them here, and do not gloss them.

### CFI-2b — The paired second half
A sub-item heading whose number happens to look like an assertion label.

### CFI-2d — A later sub-item
Numbered past the last label the contract defines.

## Workflow
Custody: the creation record and the two boundary baselines live out-of-tree.
