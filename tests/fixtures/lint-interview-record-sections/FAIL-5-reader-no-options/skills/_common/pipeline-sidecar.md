# Pipeline Sidecar Contract (fixture)

| Artifact | Kind token | Writer | Location |
| --- | --- | --- | --- |
| Interview record | `cc-run-interview v2` | `autopilot` (kickoff) **only** | `<base>/docs/pipeline-run/<run-id>.interview.md` |
| Kickoff trace | `cc-run-kickoff v1` | `autopilot` (kickoff) **only** | `<base>/docs/pipeline-run/<run-id>.kickoff.md` |

### 2b.5 The interview record

````
# 파이프라인 런 인터뷰 기록 — <run-id>
<!-- cc-run-interview v2; writer=autopilot; reader=design-discuss-unattended (driver dispatch); run-id=<run-id>;
     NOT a design doc; mechanism-local, never staged by a skill -->

## 과제
<과제 문면, 축자>

## 요구사항 문답
### 문 1
<질문, 축자>
**선택지**:
- 라벨: <라벨, 축자>
  설명: <설명, 축자>
### 답 1
<답, 축자>

## 확인된 요구
**확인 문항**: 문 <n>
**해야 할 것**:
<읽어 드린 문면, 축자> | 없음
**바꾸지 않는 것**:
<읽어 드린 문면, 축자> | 없음
**완료 기준**:
<읽어 드린 문면, 축자> | 없음

## 배포 형상
**레포**: <답의 실질> | 없음
**적용 주체**: <답의 실질> | 없음

## 로스터
매니페스트의 설계 로스터 행을 따른다 | 없음(기본 로스터)
````

**Not read by the design stage**: `## 로스터` — the roster comes from the manifest.

**Previous version** `cc-run-interview v1`: `## 과제` · `## 요구사항 문답` · `## 배포 형상` · `## 로스터`.

### 2b.6 The kickoff trace

````
<!-- cc-run-kickoff v1; writer=autopilot (kickoff); run-id=<run-id> -->
- <ISO8601> | 단계=<토큰>
````

**The stage vocabulary is closed**: `대상 확인` · `대상 변경` · `계획 제시` · `기동 직전` · `연기` · `중단`.

## 3. The run ledger

Rows.
