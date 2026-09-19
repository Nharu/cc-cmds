# Runtime Classification Default (Shared Predicate)

Single source of truth for the runtime-classification default: when a runtime point in the product being designed defaults to a type-decision-only classification model, the two exits that route away from it, and where the resulting decision sentence, `Category: UR` entry, and `### R<n>` residual item land. `design` and `design-lite` cite this file from Step 4; `autopilot`'s `lead-solo` tier cites it from item (f) of its "What a `lead-solo` document owes" paragraph.

**What this file owns vs. what each SKILL.md owns.** This file is contracts-only: the predicate, the exclusion, the two exits, and the placement rules. It does not own workflow prose — when during the session to check the predicate, how to phrase any interview question, and the UR walkthrough / refinement mechanics all stay in each owning SKILL.md's own Step 4 / Step 5.

**Consumption matrix.** `design` Reads this file in full from Step 4, when a candidate runtime point is noticed. `design-lite` Reads it the same way — a conditional Read, not an unconditional one, since this predicate does not fire on most designs, unlike `_common/verification.md`. `autopilot`'s `lead-solo` tier Reads it from item (f) of its own document-contract paragraph, the same point in the interview that produces the document.

## 1. The predicate

A runtime point in the product being designed defaults to a type-decision-only classification model when all three hold:

(i) the input is not already typed/structured ahead of time — free text or mixed signals, not fields that already passed validation, and not a fixed vocabulary of tokens a parser already recognizes;

(ii) the output is a closed, enumerable set of outcomes fixed at design time — not free text, and not a constructed artifact (a file list, a dependency graph, an argv call, a multi-field object);

(iii) no rule author can state the input-to-outcome boundary as a finite, enumerable condition.

## 2. Self-design exclusion

**The test is topology, not actor identity.** A runtime point qualifies only on the software being designed's own deployed request-serving path — a discrete call that software's running code makes at serving time, independent of any authoring or orchestrating agent's conversation. It never includes a judgment an agent makes by reading instruction prose as part of designing, reviewing, or operating a pipeline (a grade or verb the same session assigns to its own work), however classification-shaped that judgment looks.

**Worked example.** `_common/judgment-grade.md`'s grade assignment satisfies clauses (i)-(iii) on the surface — free-form input, a closed three-token output, and its own text says the top grade catches "cases nobody anticipated" — and is excluded anyway, because the assignment happens inside the same session that is designing, reviewing, or operating the pipeline, not on a separately deployed serving path. The exclusion is topology-based rather than keyed to any one repository: the same reasoning excludes an analogous grade-assignment mechanism in a different pipeline product being designed, as long as the assignment happens in the authoring or orchestrating session rather than on that product's own deployed runtime.

**What the exclusion does not reach.** A product being designed that is itself an LLM application is not excluded: if that product's own deployed code maps free text to a closed set of outcomes at its own serving time, the predicate fires for that point same as any other runtime classification point.

## 3. The two exits (check first)

**Rules/validators.** The boundary is statable as a finite condition — can a person write it in one sentence of code? If yes, this is a validator, not a classification model.

**Free-form / LLM.** The downstream consumer reads a rationale sentence, or any variable-length or constructed output, not a single label from a closed set. If yes, this is an LLM prompt-and-parse step, not a type-decision-only classification model.

## 4. When it fires

Write the decision sentence into the design document's `## 주요 결정사항과 근거` without asking the user. Name only the technique category — "타입 결정 전용 분류 모델" — never a vendor or product name.

**Vendor-transcription fence.** Do not transcribe a vendor name, price, or advocacy copy any auto-invoked skill surfaces this session into the document; restate in the vendor-neutral phrase above, or omit.

Record vendor dependency, availability, and a fallback path as a standalone `Category: UR` tradeoff entry in `## 미해결 이슈 / 트레이드오프` (`상태: 대기`) — the user accepts the vendor *risk*, not the technique decision. This entry is not a UR escalation pointer: it carries the risk and the fallback path in its own body rather than only an `R<n>` reference. Encode it in that section's existing form; a fresh section defaults to the sub-section form below.

Record the classifier's real-corpus accuracy claim as an `### R<n>` residual item per `_common/verification.md` §5. It is always required when the predicate fires, except when the product's corpus already exists and the accuracy measurement was actually run this session and recorded as a settled `### V<n>` in `## 검증 기록` — that ledger entry substitutes for the residual item.

## 5. Korean output templates

Decision sentence — the first paragraph is the binding decision sentence, the paragraph after the blank line is rationale prose (Reference tier). No vendor, model, or product name in the binding sentence.

```
### <번호>. <런타임 지점 이름>
<지점 설명>의 <출력 판단>은(는) 규칙이 아니라 타입 결정 전용 분류 모델이 수행하며,
출력은 <N>개 카테고리(<카테고리 목록>) 중 하나로 고정된다.

<근거 산문 — 입력이 왜 비정형인지, 경계를 규칙으로 못 쓰는 이유, 인입량·지연 요구 등>
```

UR entry — sub-section form, with the field order `상태` → `Category` → `Surfaced-at` that `design` uses for its unresolved-issue entries.

```
### <N>.<x> <런타임 지점 이름> — 외부 분류 모델 벤더 의존
**상태**: 대기
**Category**: UR
**Surfaced-at**: Step 4 synthesis
<지점 설명>은(는) 타입 결정 전용 분류 모델에 의존한다. 이 벤더가 서비스를 중단하거나
가격 정책을 바꾸거나 API를 폐기하면 이 구간은 대체 수단(<대체 경로>)으로 교체돼야
한다.
```

Residual item — this file fixes only the item's content. The field keys, their order, their rendering, and every enumerated value (classification, residual reason, grade, timing) come from the CANON rendering in `_common/verification.md` §5 at the time of writing, never from this file. Render the item there, pick each enumerated value by that file's definitions, and fill these slots:

```
title:           R<n>. <런타임 지점 이름> 분류 정확도 — 자사 코퍼스 기준
claim:           <입력 설명>에 대해 분류 모델이 <N>개 카테고리(<카테고리 목록>) 중
                 하나를 목표 정확도 이상으로 맞힌다.
blocking reason: 실제 제품 코퍼스와 분류 모델 연동이 구현되기 전에는 측정할 표본이 없음
recipe:          <실행 가능한 인라인 명령 또는 펜스 스크립트 — 최근 <N>건의 실사용
                 인입에 대한 모델 출력과 사람 라벨의 일치율을 계산한다>
expected result: 일치율 ≥ <목표치>%
failure impact:  the number of the decision sentence above
```
