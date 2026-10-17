---
name: design-discuss-unattended
---

# Fixture discuss lead

## Control-Flow Invariants

These rules stay near the top. After any compaction, re-Read `## Lead read set`, then its `재진입` rows, then the rows of the phase you are in.

## Lead read set

Rows are Read on entering their phase, never before.

**파견전 상한**: 20000 바이트

| 단계 | 디스패치 | 파일 | 부분 | 범위 |
|---|---|---|---|---|
| 파견전 | 공통 | `design/SKILL.md` | `### Step 3: Discussion` | 절 |
| 파견전 | 공통 | `_common/agent-team-protocol.md` | `## Spawn` | 본문만 |
| 파견전 | 드라이버 | `_common/sidecar.md` | `### 1.1 Path` | 절 |
| 파견전 | 드라이버 | `입력:인터뷰기록` | — | 전체 |
| 재진입 | 공통 | `_common/agent-team-protocol.md` | `## Reconcile` | 절 |
| 합성 | 공통 | `design/SKILL.md` | `### Step 4: Synthesis` | 절 |

## Workflow

### Step 1: Read the brief

Read `${CLAUDE_SKILL_DIR}/../_common/sidecar.md` `### 1.1 Path` and derive the slug.

### Step 3 · Step 4: Interim body

**Read Step 3 and Step 4 of `${CLAUDE_SKILL_DIR}/../design/SKILL.md`** and follow it.

`design/SKILL.md`'s instruction to Read `_common/agent-team-protocol.md` is served by the parts of `_common/agent-team-protocol.md` in `## Lead read set`; do not Read `_common/agent-team-protocol.md` whole.

### Step 5: `presentation.md` (seat dispatch only)

Write the presentation.
