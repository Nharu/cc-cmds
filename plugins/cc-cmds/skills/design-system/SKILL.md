---
name: design-system
description: Claude Design (claude.ai/design) DS 생성 프롬프트 emit + DS 번들 ingest로 docs/design-system/ 워크스페이스 구축 (2-phase)
when_to_use: FE 파이프라인 시작 전 프로젝트 전역 design system을 claude.ai/design으로 생성·도입할 때 (1회성 또는 재ingest)
disable-model-invocation: true
usage: "/cc-cmds:design-system [<intent>]"
options:
    - name: "[<intent>]"
      kind: positional
      required: false
      summary: "DS 생성 의도/스코프 서술용 자유형 토큰 (생략 시 base 설계·코드베이스에서 추론)"
---

Build the project-wide design system workspace at `docs/design-system/` by orchestrating a two-phase handoff with Claude Design (claude.ai/design). Phase 1 emits the DS-generation prompt the user pastes into Claude Design; phase 2 ingests the returned bundle and synthesizes `tokens.css`, `tokens.md`, `components.md`, and `manifest.json`. The two phases are separate slash invocations bridged by an external manual step — the user runs Claude Design, downloads the bundle, drops it under `docs/design-system/incoming/`.

This skill **distinguishes the skill name `design-system` from the workspace directory `docs/design-system/`**. They share a token but live in different namespaces (skill directory vs docs directory). When recovering a fresh session, always qualify the workspace explicitly ("workspace `docs/design-system/`" vs "skill `design-system`") so the two are not conflated.

User-facing strings (interviews, escalation, next-step emit) are Korean; internal control prose below is English.

## Phase auto-detection

On entry, inspect `docs/design-system/incoming/`:

- Directory does not exist OR contains zero sub-directories → **phase 1 (prompt emit)**.
- Directory contains at least one sub-directory → **phase 2 (ingest)**.

Phase selection is read purely from disk state. There is no in-session phase flag; re-invoking after a successful phase 2 (which empties `incoming/`) cleanly returns to phase 1 behavior for the next intent. This file-recovery posture is why the skill is EXEMPT from `lint-skill-invariants.sh` rule (A): there is no in-session termination contract that post-conversation compaction could erase.

## Phase 1 — DS-generation prompt emit

### Step 1.1: Extract directional pre-answers as flexible Q&A pairs (Korean)

Claude Design opens DS generation with an interactive directional-question form. **The form's categories, order, and wording are a variable artifact of the external tool** — a single point-in-time observation must not be hardcoded as a frozen contract (same doctrine as `parse-handoff.md`: don't bake one observation into the schema).

Instead, **extract directional information abstractly** as a flexible list of `(topic, answer)` pairs. The shape:

```
- Topic: <human-readable label naturally derived from base design or codebase>
  Answer: <concrete value or short prose>
```

The number of pairs and their order are variable. There is no required category list. Topics typically arise from base-design analysis (e.g., "브랜드 톤", "타이포 가족", "한국어 폰트", "컴포넌트 범위", "레퍼런스 URL", "테마 모드", "UI 밀도") but none of these are mandatory — extract only what the base design and codebase make concrete.

Sources to mine, in priority order:

1. The optional `<intent>` argument (free-form user text describing scope and direction).
2. The project's base design document if one exists (any `docs/*.md` that touches visual direction, branding, design tokens, or component scope).
3. The codebase itself (existing color tokens, font stacks, component naming, layout conventions — infer current direction from what is already there).

Run a focused `AskUserQuestion` for any topic that none of these sources resolves and that you judge load-bearing for the DS. Ask one or two questions per topic; **do NOT enumerate a fixed category list to the user** — that would reproduce the frozen-contract anti-pattern. Stop the interview when no additional topic seems load-bearing; emit-time backfill via the relay loop covers the rest.

It is acceptable for the resulting Q&A pair list to be empty (e.g., when the base design and codebase are silent on direction). Phase-1 emit still proceeds; Claude Design's own form will fill the gap at first use and the relay loop will route any escalation back through this session.

### Step 1.2: Compose `ds-prompt.paste.md` (5 blocks, in order)

- **Block (a) — Korean intro (top of file)**: A single short line: *"아래는 cc-cmds 파이프라인이 부과한 핸드오프 계약과 DS 생성 의도다. 계약 frontmatter는 그대로 inner README에 넣어달라."*
- **Block (b) — DS-generation intent (Korean)**: 2–4 paragraphs synthesizing the base design, the `<intent>` argument, and the lead's re-interpretation of the project domain. This is descriptive prose, not enumeration.
- **Block (c) — HANDOFF CONTRACT (English + YAML)**: `Read ${CLAUDE_SKILL_DIR}/../_common/handoff-contract.md` and quote its schema block verbatim. Append a one-paragraph English instruction: *"Place this YAML frontmatter at the top of the inner README of your bundle (the README inside the content folder alongside your HTML files). Set `kind: design-system`. The outer 'CODING AGENTS' README remains the human-facing document — do not touch it. Every field is cross-checked against the bundle's actual files by the downstream parser; do not lie."*
- **Block (d) — DS structural requirements (English)**: Require `:root` CSS custom properties for all design tokens; prefer a shared `.css` file (e.g., `tokens.css`) for the token block; include a component catalog page that demonstrates each component in every state; support theming via `[data-theme="dark"]` or `@media (prefers-color-scheme: dark)` wrapper — never strip the wrapper.
- **Block (e) — Directional pre-answers (variable Q&A pair list)**: Serialize the Q&A pairs from Step 1.1 in extracted order. Format each as `Topic: <topic>\nAnswer: <answer>` separated by blank lines. **Do not enumerate any required categories**; emit exactly the pairs Step 1.1 produced. Empty list is acceptable — emit a single sentinel line *"No directional pre-answers extracted; please ask all directional questions in the form, and the user will relay any unclear question to the cc-cmds session for a base-design-grounded answer."* in that case.

Save the composed file to `docs/design-system/ds-prompt.paste.md`. Overwrite without confirmation if it already exists (phase-1 re-runs are intentional regenerations of the prompt).

### Step 1.3: Emit relay-loop guidance (Korean)

After writing the file, emit:

> "DS 생성 프롬프트를 `docs/design-system/ds-prompt.paste.md`에 저장했습니다. claude.ai/design에 붙여넣어 실행해주세요.
>
> **CD가 띄우는 방향성 폼은 카테고리·순서가 가변이라 사전답변이 폼을 100% 커버하지 못할 수 있습니다.** CD가 사전답변 밖의 추가 질문을 던지면 그 질문을 이 세션에 그대로 전달해주세요 — base 설계와 코드베이스를 근거로 답안을 제시하겠습니다. 사용자가 그 답안을 CD 폼에 입력합니다. 완전 자동화는 외부 수동 단계 때문에 불가하므로, 이 relay 루프를 통해 의도가 끊기지 않게 유지합니다.
>
> DS 번들 다운로드가 끝나면 zip을 풀어 `docs/design-system/incoming/<bundle-name>/` 형태로 드롭하고, 다시 `/cc-cmds:design-system`을 실행하세요. phase 2가 자동으로 incoming/ 번들을 ingest합니다."

End phase 1.

## Phase 2 — DS bundle ingest

### Step 2.1: Load shared contracts and select bundle root

```
Read ${CLAUDE_SKILL_DIR}/../_common/handoff-contract.md
Read ${CLAUDE_SKILL_DIR}/../_common/parse-handoff.md
```

List sub-directories under `docs/design-system/incoming/` and select the most-recently-modified as `{bundle-root}`. If multiple sub-directories are present (user dropped several rounds), confirm via `AskUserQuestion`: *"`incoming/`에 번들이 N개 있습니다. 가장 최근(`<name>`, mtime: `<ts>`)을 ingest할까요?"* with options (most-recent / pick-one / abort).

### Step 2.2: Apply the parser

Follow the `parse-handoff.md` extraction contract end-to-end on `{bundle-root}`. The parser returns the uniform output record described in §8 of that file.

### Step 2.3: Caller-side branching (uniform-record-based, NOT rung-based)

Branch on record content. Never branch on which rung fired.

- **`status == "MALFORMED"`** → `AskUserQuestion` with options (edit-bundle-and-retry / re-download / abort). Do NOT touch the workspace. Do NOT empty `incoming/`.
- **`kind_mismatch == true`** (record's `kind` is `feature` or null instead of `design-system`) → emit Korean warning prose and confirm via `AskUserQuestion` whether the user intentionally wants to treat a non-DS bundle as DS source. On confirm proceed; on decline abort.
- **`tokens_absent == true`** → **caller-level block.** A DS without `:root` token bytes has no substance to commit. Emit Korean escalation: *"번들에 `:root` 토큰 블록이 없어 DS 워크스페이스를 구축할 수 없습니다. Claude Design에 토큰을 명시적으로 요구하는 프롬프트로 재실행하거나, 다른 번들을 사용하세요."* Do NOT write `tokens.css`. Do NOT empty `incoming/`. End phase 2.
- **Any `token_groups[i].divergent == true`** → **escalate.** A DS must be uniform per theme; divergent same-theme blocks mean the bundle contains contradictory token definitions across files. Emit Korean escalation listing the divergent theme keys and their source files; offer (retry-with-cleaner-prompt / pick-one-source-and-proceed / abort). Do NOT silently auto-collapse.

If none of the blocking conditions fired, proceed to synthesis.

### Step 2.4: Synthesize `tokens.css` (authored-css blocks only, wrapper-preserved)

Produce a byte-verbatim valid CSS file that downstream skills (notably `design-prompt`) can quote without re-encoding.

1. Filter `token_blocks[]` to entries with `provenance == "authored-css"`. Exclude `readme-derived` and `agent-inferred` — `tokens.css` is the verbatim-quote-safe surface.
2. Sort: default theme first, then other themes in alphabetical order of `theme_key`. Within a theme, preserve the parser's source-file ordering.
3. Deduplicate using `token_groups[]`: emit only the first block of each identical-bytes group; append `/* identical block also present in: <other source files> */` when N > 1.
4. Above each emitted block, write a provenance header comment:
   ```
   /* source: <source_file> (origin: <inline-style | shared-file>, theme_key: <default | dark | ...>) */
   ```
5. Emit the **wrapper-inclusive `raw_block_text`** verbatim. Never strip `@media (prefers-color-scheme: dark)` or `:root[data-theme="dark"]` envelopes — stripping makes dark tokens apply unconditionally and breaks theme switching.
6. Save the assembled content to `docs/design-system/tokens.css`. By construction the result is valid CSS (the parser's wrapper-inclusive captures guarantee this).

### Step 2.5: Synthesize `tokens.md` (semantic catalog)

Write `docs/design-system/tokens.md` as a Korean prose catalog. Group tokens by category headings (`### Colors`, `### Spacing`, `### Shadows`, `### Typography`, `### Radius`, ... — only the categories the bundle actually defines). For each token write a one-line row: `--token-name` → value → role. Inference-based rows are acceptable; non-`authored-css` derived tokens (e.g., picked up from a `readme-derived` table) may also appear here even though they were excluded from `tokens.css`.

### Step 2.6: Synthesize `components.md` (component contracts)

Write `docs/design-system/components.md` from `record.components[]`. For each component emit a section: name, stack kind, anatomy (composition prose), states (interaction states observed), a11y (ARIA attributes / focus management), usage (when to use, conventions). The records are lossy by design — fill anatomy and usage from the lead's reading of the bundle's HTML when the parser left them empty.

### Step 2.7: Write `manifest.json`

```json
{
  "version": "<YYYYMMDD-HHMMSS at ingest time>",
  "source_bundle": "<bundle-root directory name>",
  "ingested_at": "<ISO 8601 timestamp>",
  "kind": "design-system",
  "contract_used": <bool from record>,
  "rungs_fired_per_field": <object copied from record>,
  "theme_modes": ["light", "dark"],
  "token_block_count": <int>,
  "component_count": <int>,
  "unresolved_questions": [<copied from record, informational>]
}
```

The `version` field is the anchor `design-prompt` and `design-apply` pin via `<!-- DS manifest version: ... -->` comments and use for drift detection. It is monotonic per ingest by using the current timestamp.

### Step 2.8: Archive the bundle and clear `incoming/`

- `mv "{bundle-root}" "docs/design-system/bundles/<version>/"` (creating `bundles/` if needed). The version-named directory preserves the original Claude Design output for re-ingest and diff.
- Empty `docs/design-system/incoming/` (the consumed signal — phase auto-detection on the next invocation must see no remaining sub-directories).

### Step 2.9: Emit next-step (Korean)

> "DS 워크스페이스 구축 완료: `docs/design-system/{tokens.css, tokens.md, components.md, manifest.json}` (version: `<version>`).
>
> 다음 단계: `/cc-cmds:design <slug>`로 base 우산 설계를 작성하세요. 이후 `/cc-cmds:design-prompt`가 이 DS를 자동으로 참조합니다."

If the record contained non-blocking `unresolved_questions[]` (e.g., a missing `components` list in the contract, primary-page disambiguation note), append them as bullet points after the next-step line so the user can decide whether to act on them now or later. Non-blocking surfacing only — do not gate the next step on them.

## Re-ingest safety

Phase-2 re-runs overwrite `tokens.css`, `tokens.md`, `components.md`, `manifest.json` with the new bundle's contents. The `bundles/<old-version>/` archive is preserved as a sibling of the new archive. This is intentional — the user opts into a re-ingest by dropping a new bundle into `incoming/`.

`design-prompt` and `design-apply` record the manifest `version` they consumed at their build time; if the live `version` differs at their next invocation, they emit a drift warning so the user can decide whether to regenerate downstream artifacts or proceed.

## EXEMPT rationale (no `## Control-Flow Invariants` heading needed)

This skill is linear in both phases. Phase auto-detection reads disk state on entry; there is no in-session loop variable, no termination counter, no compaction-fragile contract. Phase 1 emits a file and ends; phase 2 reads the parser record, branches once on its content, writes the workspace, and ends. The skill therefore belongs to the majority of skills exempted from `lint-skill-invariants.sh` rule (A), which targets only the `design-review ↔ design-review-lite` pair's inline bash-variable termination contract.

## Constraints

- NO code modifications outside `docs/design-system/`.
- User-facing strings (interviews, escalation, next-step emit) in Korean; internal prose in English.
- Token values are NEVER normalized. Preserve `oklch(...)`, `#rrggbb`, `rgb(...)`, `hsl(...)` exactly as Claude Design wrote them. Any color-space conversion belongs to `design-apply` at consumption time.
- **No fixed-category enumeration in directional pre-answers.** The Q&A pair list is variable in count and order. Hardcoding a category list reproduces the stale-frozen-contract anti-pattern that `parse-handoff.md` already addresses for bundle structure.
- `web-design-guidelines` is NOT invoked from this skill — it is `design-ingest`'s optional dependency, not the DS workspace's.
- **Deferred tool loading**: Before using `AskUserQuestion`, you MUST load it via `ToolSearch("select:AskUserQuestion")`. This skill assumes no other deferred tool beyond that.

Intent: $ARGUMENTS
