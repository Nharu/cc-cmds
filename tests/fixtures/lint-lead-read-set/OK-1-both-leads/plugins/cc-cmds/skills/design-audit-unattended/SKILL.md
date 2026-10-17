---
name: design-audit-unattended
---

# Fixture audit lead

## Control-Flow Invariants

These rules stay near the top. After any compaction, re-Read `## Lead read set`, then its `재진입` rows, then the rows of the phase you are in.

## Lead read set

Rows are Read on entering their phase, never before.

**파견전 상한**: 20000 바이트

| 단계 | 디스패치 | 파일 | 부분 | 범위 |
|---|---|---|---|---|
| 파견전 | 공통 | `입력:문서` | — | 전체 |
| 파견전 | 공통 | `_common/sidecar.md` | `### 1.1 Path` | 절 |
| 파견전 | 공통 | `design-audit/references/02-deterministic-checks.md` | — | 전체 |
| 파견전 | 공통 | `_common/verification.md` | `## 3. Vocabulary` | 절 |
| 파견전 | 공통 | `_common/agent-team-protocol.md` | `## Spawn` | 본문만 |
| 재진입 | 공통 | `_common/agent-team-protocol.md` | `## Reconcile` | 절 |

## Workflow

### Step 1: Resolve, validate, FREEZE

1. Parse the arguments.
2. **Read the whole document.** An unparseable or empty document is a **halt** (nothing to freeze).
3. Read `${CLAUDE_SKILL_DIR}/../_common/sidecar.md` `### 1.1 Path` and derive the slug.

### Step 2: Deterministic checks

**Read `${CLAUDE_SKILL_DIR}/../design-audit/references/02-deterministic-checks.md`** and run it once. `02-deterministic-checks.md`'s instruction to Read `_common/verification.md` is served by the rows of `## Lead read set`; that file is not Read whole.

### Step 3: Fan-out spawn

**Before spawning, Read `${CLAUDE_SKILL_DIR}/../_common/agent-team-protocol.md`** — the parts listed in `## Lead read set` — for the spawn contract.

### Step 4: Witness collection (no resume)

Collect by witness.
