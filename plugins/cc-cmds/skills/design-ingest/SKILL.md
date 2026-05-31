---
name: design-ingest
description: Claude Design (claude.ai/design) 핸드오프 번들을 파싱·리뷰하고 ACCEPT/REFINE 판정으로 개선 루프 진행
when_to_use: claude.ai/design 에서 받은 HTML 핸드오프 번들을 검토·수용·재프롬프트할 때 (단일 호출 또는 외부 재실행 사이 반복)
disable-model-invocation: true
usage: "/cc-cmds:design-ingest <handoff-dir-path>"
options:
    - name: "<handoff-dir-path>"
      kind: positional
      required: true
      summary: "기능 핸드오프 디렉토리 (`docs/{slug}-fe/handoff`); incoming/ 하위 번들을 소비"
---

Parse a Claude Design (claude.ai/design) handoff bundle, run a single-Agent quality review against the 5-axis criteria, and emit an ACCEPT or REFINE verdict. The skill is the **suspend-resume bridge** across the external manual loop — each invocation is fresh-context, all state lives on disk, and the outer feedback loop spans multiple `/cc-cmds:design-ingest` invocations interleaved with external Claude Design re-runs.

The verdict contract: `critical` or `major` issues identified by the reviewing Agent → `REFINE`; zero such issues → `ACCEPT`. REFINE writes a `reprompt.md` the user pastes back into Claude Design for the next round. ACCEPT copies the round's `handoff-extract.md` to the stable path `docs/{slug}-fe/handoff-extract.md` so downstream `/cc-cmds:design-apply` has a deterministic input. The loop has a soft cap of 3 rounds (`ITER_CAP`); the 4th round opens an `AskUserQuestion` for continue / force-ACCEPT / abort.

**Loop state is recovered from disk on every invocation** — no in-session counter, no compaction-fragile variable. The skill enumerates `iter-NNN/` directories under the handoff path, reads the `## Verdict:` header from the latest `review.md`, and decides next action from that plus the presence of `incoming/` sub-directories. The recovery anchor is the `## Verdict: ACCEPT|REFINE` header on the first line of each `review.md`.

Two DS-usage patterns coexist in feature bundles and the skill branches on them:

- **(a) DS-copy-bundled** (common, observed 5/6): the feature bundle ships a copy of the DS `.css` alongside its own HTML. `token_blocks[]` is non-empty. The skill **byte-diffs** the bundled copy against `docs/design-system/tokens.css`; any drift becomes a REFINE-eligible issue surfaced to the reviewing Agent.
- **(b) `var()`-reference-only** (rare): the feature bundle has no `:root` declarations of its own (`tokens_absent: true`) and refers to DS tokens purely via `var(--name)`. The skill checks every entry in `referenced_undefined_vars[]` against `docs/design-system/tokens.css`; any var not present there becomes a REFINE-eligible issue.

Both are normal cases. Neither blocks parsing; both are surfaced to the reviewing Agent as 5-axis input. `MALFORMED` from the parser is a separate, structural condition (no readable root, no README, no HTML) that does block ACCEPT and routes to user escalation via `AskUserQuestion`.

User-facing strings are Korean; internal control prose is English. `web-design-guidelines` is invoked **optionally** by the reviewing Agent — absence does not halt review.

## Step 1: Parse input and load shared contracts

- Extract `{slug}` from `<handoff-dir-path>`. The path must match `docs/{slug}-fe/handoff` (the trailing component `handoff` is required; `{slug}-fe` carries the slug). On any other shape emit Korean error: *"입력 경로는 `docs/<slug>-fe/handoff` 형식이어야 합니다."* and end.
- Verify the DS workspace at `docs/design-system/manifest.json` exists. If absent emit Korean: *"DS 워크스페이스가 없습니다. 먼저 `/cc-cmds:design-system`을 실행하세요."* and end.
- Read `docs/design-system/manifest.json` and capture the current `version` as `live_ds_version`.
- Read the prior pinned version from `docs/{slug}-fe/cd-prompt.paste.md`'s first-line HTML comment (`<!-- DS manifest version: <X> -->`) as `prompt_ds_version`. If the file is absent emit Korean: *"`docs/{slug}-fe/cd-prompt.paste.md`이 없습니다. 먼저 `/cc-cmds:design-prompt docs/{slug}.md`를 실행하세요."* and end.
- Compare `live_ds_version` vs `prompt_ds_version`. If they differ, queue a Korean drift warning (emit alongside the next-step message at the end of the run):
  > "⚠️ DS 버전 변경 감지: prompt build `<prompt_ds_version>` → live `<live_ds_version>`. 이번 round의 번들은 prompt build 시점 DS 기준이라 일부 평가 결과(특히 동봉 사본 vs 정본 diff)가 그 차이를 반영합니다."
- `Read ${CLAUDE_SKILL_DIR}/../_common/handoff-contract.md` and `Read ${CLAUDE_SKILL_DIR}/../_common/parse-handoff.md`. The parser contract is shared with `design-system` phase 2.

## Step 2: Recover loop state from disk

Enumerate `<handoff-dir-path>/iter-*/` directories. Each directory name follows the zero-padded form `iter-NNN` (`iter-001`, `iter-002`, ...). Compute:

- `last_iter` = max `NNN` among existing `iter-NNN/` dirs, or `0` if none exist.
- `last_verdict` = read the first line of `iter-{last_iter}/review.md` (if `last_iter > 0` and the file exists). Match `^## Verdict: (ACCEPT|REFINE)` (case-sensitive). If `last_iter == 0` or the file is absent, `last_verdict = null`.
- `has_new_bundle` = `find <handoff-dir-path>/incoming -mindepth 1 -maxdepth 1 -type d` yields at least one directory.

Branch on `(has_new_bundle, last_verdict)`:

- **`has_new_bundle == true`** → proceed to **Step 3 (new round)** with `next_N = last_iter + 1` (or `1` if `last_iter == 0`).
- **`has_new_bundle == false` AND `last_verdict == REFINE`** → emit Korean: *"이전 round verdict가 REFINE입니다. `<handoff-dir-path>/iter-{last_iter:03d}/reprompt.md`를 claude.ai/design에 다시 붙여넣어 실행한 뒤, 새 번들을 `<handoff-dir-path>/incoming/`에 드롭하고 다시 `/cc-cmds:design-ingest`를 실행하세요."* (+ queued drift warning, if any.) End.
- **`has_new_bundle == false` AND `last_verdict == ACCEPT`** → emit Korean: *"이미 ACCEPT 상태입니다. 안정 사본: `docs/{slug}-fe/handoff-extract.md`. 다음 단계: `/cc-cmds:design-apply docs/{slug}-fe/handoff-extract.md`."* End.
- **`has_new_bundle == false` AND `last_verdict == null`** → emit Korean: *"먼저 claude.ai/design에서 번들을 다운로드해 `<handoff-dir-path>/incoming/`에 드롭하세요."* End.

Substitute `{last_iter:03d}` with zero-padded 3-digit form.

## Step 3: New-round processing

### Step 3.1: ITER_CAP gate

If `next_N > 3`, open `AskUserQuestion` with three options before doing any work:

- label "계속 진행 ← 추천" (position 1) — description: proceed with this round normally; the cap is a soft cap and the user is overriding it.
- label "현재 상태로 ACCEPT 강제" — description: skip parsing/review, copy the most recent `iter-{last_iter}/handoff-extract.md` to the stable path, emit ACCEPT next-step. Suitable when the user has decided iteration has converged "enough".
- label "중단" — description: leave `incoming/` untouched and end.

`ITER_CAP = 3` is the default. The user can always proceed past it; this prompt exists to break runaway loops.

### Step 3.2: Bundle root selection and archival

- `find <handoff-dir-path>/incoming -mindepth 1 -maxdepth 1 -type d` and pick the most-recently-modified directory as `{bundle-root}`. If multiple sub-directories are present, `AskUserQuestion` confirms ("`incoming/`에 N개 번들이 있습니다. 가장 최근(`<name>`)을 처리할까요?") with options (most-recent / pick-one / abort).
- `mkdir -p <handoff-dir-path>/iter-{next_N:03d}/bundle` and `mv {bundle-root}/* <handoff-dir-path>/iter-{next_N:03d}/bundle/`. Then remove the now-empty `{bundle-root}` directory and confirm `<handoff-dir-path>/incoming/` has zero sub-directories (consumed signal).
- Refer to the archived bundle path as `<handoff-dir-path>/iter-{next_N:03d}/bundle` for the rest of the round.

### Step 3.3: Run the parser

Follow the `parse-handoff.md` extraction contract on `<handoff-dir-path>/iter-{next_N:03d}/bundle`. The parser returns the uniform output record described in §8 of that file.

If `status == "MALFORMED"`:

- `AskUserQuestion` with options (edit-bundle-and-retry / re-download / abort). On any choice except "edit-and-retry", leave the archived bundle in place but do NOT write `review.md` or `handoff-extract.md` for this round — the round did not produce a verdict.
- "edit-and-retry" prompts the user to fix the bundle in place under `iter-{next_N:03d}/bundle/` and re-run `/cc-cmds:design-ingest`; the skill will re-parse on next invocation.
- End.

If `record.kind_mismatch == true` (the bundle declares `kind: design-system` instead of `feature`), emit a Korean warning and confirm via `AskUserQuestion` whether the user intentionally wants to treat a DS bundle as a feature bundle. On decline, abort the round (leave files as-is, end). On confirm, proceed.

### Step 3.4: DS-usage pattern detection (NOT rung-based)

Branch on uniform-record content:

- **Case (a) DS-copy-bundled** — `tokens_absent == false`. Run a byte-diff of every `token_blocks[i].raw_block_text` (filtered to `provenance == "authored-css"`) against the corresponding block in `docs/design-system/tokens.css` (matched by `(selector, theme_key)`). Any block that differs, plus any DS block missing entirely from the bundle, becomes a REFINE-eligible drift issue carried into Step 3.6.
- **Case (b) `var()`-reference-only** — `tokens_absent == true`. For each entry in `record.referenced_undefined_vars[]`, check whether `--<name>` is declared anywhere in `docs/design-system/tokens.css`. Each missing var becomes a REFINE-eligible "undefined token" issue carried into Step 3.6.

Both cases are normal; neither blocks. The skill records the case in `handoff-extract.md` so the reviewing Agent knows which pattern applies.

### Step 3.5: Write `iter-{next_N}/handoff-extract.md`

Emit a Korean markdown summary of the parser record + DS-usage analysis. Required sections:

```
<!-- DS manifest version (prompt build): <prompt_ds_version> -->
<!-- DS manifest version (live at ingest): <live_ds_version> -->

# Handoff extract — iter-{next_N:03d}

## Parser status
- status, contract_used, rungs_fired_per_field 요약

## Bundle structure
- primary, pages[] 요약 (file / title / route / provenance)
- stack, theme_modes

## Tokens (DS-usage pattern: <a | b>)
- token_blocks 개수와 provenance 분포
- (Case a) DS-copy-bundled — 동봉 사본 vs 정본 byte-diff 결과 (drift 블록 enumerate)
- (Case b) var()-reference-only — referenced_undefined_vars 검증 결과 (DS에 없는 var enumerate)
- token_groups divergent 표기 (있으면)

## Components
- components[] 요약 (name / stack_kind / source_file / provenance)

## Unresolved questions (from parser)
- record.unresolved_questions[] 그대로 인용

## DS drift warning (있으면)
- prompt_ds_version != live_ds_version 일 때만
```

The reviewing Agent in Step 3.6 reads this file as its primary input alongside the bundle itself.

### Step 3.6: Single-pass reviewing Agent

Spawn one fresh `Agent()` (subagent_type=`Explore` or `general-purpose`, single pass — NOT a team). Pass the following context:

- The handoff-extract markdown just written (`iter-{next_N:03d}/handoff-extract.md`).
- The bundle archive path (`iter-{next_N:03d}/bundle/`) — the Agent reads the primary HTML and any imports directly from disk.
- The base design document `docs/{slug}.md` — for intent-fidelity assessment.
- The DS workspace files `docs/design-system/{tokens.md, components.md, tokens.css}` — for the canonical token/component reference.

Instruct the Agent to assess across **5 axes** and report `critical` / `major` / `minor` / `info` findings on each:

1. **DS fidelity**: (Case a) bundled `tokens.css` vs canonical `docs/design-system/tokens.css` byte-diff outcomes — any drift; (Case b) `referenced_undefined_vars[]` resolution — any missing var. Component patterns match `components.md` contracts.
2. **Accessibility — contrast ratios**: compute WCAG AA 4.5:1 for body text and 3:1 for large text using the actual token values (the Agent reads `:root` blocks and resolves `var()` references). Report any color pair that fails for an interactive element.
3. **Responsive / touch targets**: minimum touch target 44px square (WCAG 2.5.5); responsive breakpoints make sense for the page's role; no horizontal scroll at common widths.
4. **Base intent fidelity**: the prototype's pages and flows match the intent in the base design document's "Claude Design 프롬프트 + 컨텍스트" section (특히 의도 + 페이지/플로우 의도 sub-blocks).
5. **General visual quality**: rendering looks plausible; no obvious broken layouts, missing states, or placeholder content; component states (hover/focus/disabled) are demonstrated.

**Optional dependency — `web-design-guidelines`**: If the skill `web-design-guidelines` is available in the environment, instruct the Agent to invoke it for axes 2, 3, 5 as a structured checklist source. If it is not available, the Agent performs axes 2, 3, 5 from its own judgment using the 5-axis criteria above. **Absence does NOT halt review.** The Agent should not error or stall on `web-design-guidelines` unavailability; it proceeds with the local criteria. This optional dependency is also declared in the README "Prerequisites" section.

`divergent` token groups from the parser are passed as a REFINE-eligible signal but **not** auto-rejected. Per-screen divergence is sometimes intentional in feature bundles (unlike DS bundles where divergence is structural error). The Agent decides whether divergence is intentional or a defect and reports accordingly.

`unresolved_questions[]` from the parser are passed for the Agent to either integrate into a REFINE message or surface as informational notes alongside an ACCEPT.

The Agent's deliverable is a structured report grouping findings by axis and severity, plus an overall verdict line.

### Step 3.7: Verdict computation

The verdict is decided by structural rule, not the Agent's overall opinion:

- If the Agent reports at least one `critical` or `major` finding → **REFINE**.
- Otherwise → **ACCEPT**. `minor` and `info` are non-blocking; they may be carried into `handoff-extract.md` or `review.md` as notes but do not flip the verdict.

This rule is the load-bearing contract of the skill — see also the "EXEMPT rationale" below for why it stays in body prose rather than under a `## Control-Flow Invariants` heading.

### Step 3.8: Write `iter-{next_N:03d}/review.md`

The first line is the verdict header in the exact form the disk-recovery logic in Step 2 matches:

```
## Verdict: ACCEPT
```

or

```
## Verdict: REFINE
```

Below the header, write the Agent's structured report verbatim (or lightly reformatted as Korean prose with English finding labels — the Agent may write in either; what matters is the verdict header).

### Step 3.9: REFINE branch

If verdict is REFINE:

- Write `iter-{next_N:03d}/reprompt.md`. This file is what the user pastes into claude.ai/design for the next round. Compose it from:
    - Line 1: `<!-- DS manifest version: <live_ds_version> -->` (re-pin to live, since this is what the next round should target).
    - A 1-line Korean intro: *"이전 round 번들에 must-fix 이슈가 발견되어 재실행한다. 동일 HANDOFF CONTRACT와 DS 참조를 유지하되, 아래 must-fix 이슈를 모두 해결해라."*
    - The full byte-verbatim contents of `docs/{slug}-fe/cd-prompt.paste.md` (the original prompt — re-quoted to make `reprompt.md` self-contained for the external paste).
    - A new English section `### Must-fix issues from previous round` listing every `critical`/`major` finding from the Agent's report, grouped by axis, with brief one-line explanations.
    - Optional `### Carry-over informational notes` listing `minor`/`info` findings if any seem relevant for the next round.
- Korean next-step emit: *"Verdict: REFINE. must-fix 이슈가 `iter-{next_N:03d}/review.md`에, 재프롬프트가 `iter-{next_N:03d}/reprompt.md`에 작성됐습니다. `reprompt.md`를 claude.ai/design에 붙여넣어 재실행한 뒤, 새 번들을 `<handoff-dir-path>/incoming/`에 드롭하고 다시 `/cc-cmds:design-ingest`를 실행하세요."* (+ queued drift warning, if any.) End.

### Step 3.10: ACCEPT branch

If verdict is ACCEPT:

- `cp iter-{next_N:03d}/handoff-extract.md docs/{slug}-fe/handoff-extract.md` (this is the stable anchor `design-apply` reads).
- Korean next-step emit: *"Verdict: ACCEPT. 안정 사본: `docs/{slug}-fe/handoff-extract.md`. 다음 단계: `/cc-cmds:design-apply docs/{slug}-fe/handoff-extract.md`."* (+ queued drift warning, if any.) End.

## ITER_CAP recap (prominent body prose)

The default `ITER_CAP` is **3**. The cap is enforced in Step 3.1, before any parsing or review work, by checking `next_N > 3`. The user always has the option to override and proceed; the cap exists to interrupt runaway loops, not to enforce a hard rule. The disk recovery in Step 2 naturally handles re-runs after a cap override — the verdict header from `iter-003/review.md` (or higher) remains the recovery anchor.

## Verdict-recovery contract (prominent body prose)

The first line of every `iter-NNN/review.md` matches the regex `^## Verdict: (ACCEPT|REFINE)$` exactly. This is the only recovery anchor; the skill never relies on in-session state to know "where we are in the loop." Compaction-fragile in-session variables (counters, flags) are intentionally absent. The verdict header + the iter-directory enumeration is sufficient to recover.

## EXEMPT rationale (no `## Control-Flow Invariants` heading needed)

This skill is a single-pass verdict emitter (the `review` family), and its loop state lives entirely on disk (the `## Verdict:` header on the first line of each `iter-NNN/review.md`, plus directory enumeration). Every invocation is fresh-context; there is no in-session bash variable that compaction could erase. The ACCEPT/REFINE rule, `ITER_CAP`, and user-gated exit are all kept in prominent body prose (Steps 3.1, 3.7, "ITER_CAP recap", "Verdict-recovery contract" sections above) rather than under a `## Control-Flow Invariants` heading — the same pattern `/design` Step 5/6 uses for file-recovery state. The skill is therefore EXEMPT from `lint-skill-invariants.sh` rule (A).

## Constraints

- NO code modifications outside `docs/{slug}-fe/handoff/` and `docs/{slug}-fe/handoff-extract.md`.
- User-facing strings in Korean; internal control prose in English; the reviewing Agent's report language follows what the Agent itself chooses (commonly English findings with brief Korean prose at the top).
- `web-design-guidelines` is OPTIONAL. The skill must not hard-invoke it; absence triggers fallback to the local 5-axis criteria. Declared in README "Prerequisites" alongside `terminal-notifier` (the precedent for optional skills in cc-cmds).
- The verdict computation is structural (count of `critical`/`major` findings ≥ 1 → REFINE), not the Agent's own ACCEPT/REFINE opinion. The Agent reports findings; the skill computes the verdict.
- DS workspace files are read-only here; `design-ingest` never modifies `docs/design-system/`.
- **Deferred tool loading**: Before using `AskUserQuestion`, you MUST load it via `ToolSearch("select:AskUserQuestion")`. The skill assumes no other deferred tool beyond that. Before calling `AskUserQuestion`, Read `${CLAUDE_SKILL_DIR}/../_common/askuserquestion.md` and apply its hard constraints to every AskUserQuestion call in this skill.

Handoff directory: $ARGUMENTS
