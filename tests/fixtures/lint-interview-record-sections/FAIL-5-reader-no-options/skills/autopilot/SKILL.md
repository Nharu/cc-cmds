# autopilot (fixture)

## Control-Flow Invariants

**CFI-9 — A message runs on into the next question.** A resumed turn reads the kickoff trace, whose header is `cc-run-kickoff v1`.

## Workflow

### Step 5: The interview

**5j — The requirements interview.** Ask with the question tool.

- The options each question offered go under that question's `**선택지**`.
- The delivery-shape keys are asked by name — `**레포**`, `**적용 주체**`.

**5a — Termination point.** Propose it from `완료 기준`.

**5m — Freeze the interview record.** Its sections (`cc-run-interview v2`), in this order: `## 과제` · `## 요구사항 문답` · `## 확인된 요구` · `## 배포 형상` · `## 로스터`.

- every `### 문 n` has a `**선택지**`.

**5n — Immediate or deferred kickoff.** Ask.
