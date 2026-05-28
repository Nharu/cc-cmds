---
name: design-prompt
description: Claude Design (claude.ai/design) 실행용 프롬프트+컨텍스트를 base 설계 문서에 authoring하고 붙여넣기 블록 emit (standalone + idempotent, HANDOFF CONTRACT 포함)
when_to_use: base 설계 작성 후, claude.ai/design 에 보낼 의도 중심 프롬프트와 DS 참조를 base 설계 문서에 추가하거나 리뷰 반영본으로 붙여넣기 블록을 재조립할 때
disable-model-invocation: true
usage: "/cc-cmds:design-prompt <base-doc-path>"
options:
    - name: "<base-doc-path>"
      kind: positional
      required: true
      summary: "base 설계 문서 경로 (`docs/{slug}.md`); 본 스킬이 그 안에 CD 프롬프트 섹션을 in-place authoring"
---

Author the "Claude Design 프롬프트 + 컨텍스트" section inside the **base design document** — the single markdown at `docs/{slug}.md` that `/cc-cmds:design` first created and that this skill now extends to carry the Claude Design prompt as well. The base design document is the durable per-feature carrier: `/cc-cmds:design` writes the base sections, `/cc-cmds:design-prompt` adds the prompt section, and `/cc-cmds:design-review --base` audits the whole file as one for consistency.

The skill also emits a derived paste block at `docs/{slug}-fe/cd-prompt.paste.md` — a self-contained file the user pastes into claude.ai/design. The base design document is the source of truth; the paste block is rebuilt from it on every invocation.

The skill is **standalone and idempotent** — re-invocations replace the prompt section in place (no append, no duplication) and rebuild the paste block from the current base-document state. This survives `design-review --base` edits and user touch-ups between rounds.

User-facing strings are Korean; internal control prose is English.

## Step 1: Parse input and verify DS workspace

- Extract `{slug}` from `<base-doc-path>`. The path must match `docs/{slug}.md`; the file stem is `{slug}`. On any other shape (no `docs/` prefix, no `.md` extension, multi-segment stem) emit Korean error: *"입력 경로는 `docs/<slug>.md` 형식이어야 합니다."* and end.
- Verify the DS workspace at `docs/design-system/manifest.json` exists. If absent, emit Korean: *"먼저 `/cc-cmds:design-system`으로 DS 워크스페이스를 구축하세요. `design-prompt`는 DS의 토큰·컴포넌트 카탈로그를 참조합니다."* and end.
- Read `docs/design-system/manifest.json` and capture the current `version`. This is the DS version `design-prompt` will pin into both outputs (the base-document section and the paste block).

(The skill `design-system` and the workspace directory `docs/design-system/` share a token but live in different namespaces. When referring to either, qualify in prose to avoid conflation.)

## Step 2: In-place author the prompt section inside the base design document

The base design document `docs/{slug}.md` carries the Claude Design prompt as one of its sections, with a stable heading anchor so re-runs replace cleanly.

- **Anchor heading**: `## Claude Design 프롬프트 + 컨텍스트` (exact string, no decoration, no version suffix).
- Read the base design document.
- If the anchor exists, replace **the section body** (everything between this heading and the next `^## ` heading or EOF). Do not append; do not duplicate; do not touch other sections — `design-review --base` and the user may have edited surrounding content between rounds and that must survive.
- If the anchor does not exist, append the entire section at the end of the document.

The section body contains three sub-blocks, separated by blank lines:

1. **의도 (Korean prose)** — A re-interpretation of the base design's core direction in 2–4 paragraphs, written by the lead. This is the source of truth that `design-review --base` audits for consistency.
2. **DS 참조 (Korean prose with file path mentions)** — Cite which DS assets this feature depends on: `docs/design-system/tokens.md` for token semantics, `docs/design-system/components.md` for component contracts, and the DS `version` from `manifest.json`. Do NOT inline token values here; the paste block carries them. Include the DS manifest version inline as: *"기준 DS 버전: `<version>`."*
3. **페이지 / 플로우 의도 (Korean prose)** — Which pages, flows, and interactions the feature requires. Page-level intent; not implementation detail.

After the section is written/replaced, the base design document is the carrier of the prompt intent; `design-review --base` audits it as one document for intent and DS-reference consistency, never inspecting the paste block.

## Step 3: Assemble the paste block `docs/{slug}-fe/cd-prompt.paste.md`

This is the file the user pastes into claude.ai/design. It must be self-contained — Claude Design has no access to the base design document on disk.

- Create `docs/{slug}-fe/` if it does not exist. Do not touch other files inside it.
- Overwrite `docs/{slug}-fe/cd-prompt.paste.md` (re-runs are intentional rebuilds).
- The file is composed of, in order:

### Line 1 (HTML comment): DS version pin

```
<!-- DS manifest version: <version> -->
```

`design-ingest` reads this comment back later to detect DS drift between prompt build time and ingest time.

### Block (a) — Korean intro (1 short line)

> "다음은 cc-cmds 파이프라인이 부과한 핸드오프 계약과 기능 프롬프트다. README frontmatter를 반드시 채워서 번들에 포함해라."

### Block (b) — HANDOFF CONTRACT (English + YAML)

`Read ${CLAUDE_SKILL_DIR}/../_common/handoff-contract.md` and quote its schema block **verbatim**. Append a one-paragraph English instruction:

> "Place this YAML frontmatter at the top of the **inner** README of your bundle — the README inside the content folder alongside your HTML files. The outer 'CODING AGENTS' README must remain the human-facing document; do not modify it. Set `kind: feature` and `feature: {slug}`. Fill `primary`, `pages[]`, `tokens_file`, and `theme_mode[]` based on the pages you actually generate. Every field is cross-checked against the bundle's real files by the downstream parser; do not lie."

Substitute `{slug}` with the actual slug.

### Block (c) — DS reference (English instruction + verbatim CSS + components excerpt)

- One-line English instruction: *"Use only the tokens and component contracts below. Do not invent new tokens or component patterns. Reference tokens via `var(--token-name)` in your HTML; do not re-declare `:root` blocks in your feature bundle."*
- A fenced code block (` ```css `) containing the **full byte-verbatim contents of `docs/design-system/tokens.css`**. The `design-system` phase 2 synthesized this file with wrappers preserved and provenance comments inline; quote it as-is. Do not strip comments, do not re-order, do not normalize values.
- An English heading `### Component contracts` followed by an excerpt of `docs/design-system/components.md` covering the components this feature is likely to need (lead's judgment based on Step 2's page/flow intent). If unsure, quote the entire `components.md`. Preserve the source file's markdown formatting.

### Block (d) — Feature intent (Korean prose, quoted from the base document section)

Quote the **의도** and **페이지 / 플로우 의도** sub-blocks from the Step 2 section verbatim (the lead-authored Korean prose). Do not re-summarize — the base design document is the source of truth.

### Block (e) — Output guidelines (English instruction list)

A bulleted list:

- "Do NOT place `:root { ... }` blocks in feature HTML pages. Reference DS tokens via `var(--token-name)`."
- "If you create additional pages beyond the primary, list every page in the frontmatter `pages[]` array with `file`, `title`, `route`."
- "Set `theme_mode: ["light", "dark"]` if your feature supports both themes; `["light"]` otherwise."
- "Wrap dark-theme overrides in either `:root[data-theme="dark"]` or `@media (prefers-color-scheme: dark) { ... }`. Never strip the wrapper around a `:root` block."
- "Use the same stack family as the DS (`react` if the DS used React 18 CDN, etc.); the downstream parser detects stack from HTML signatures and warns on mismatch."

## Step 4: DS drift detection on re-runs

If this is a re-run (the section anchor existed before Step 2 ran), compare the **previously pinned DS version** (extract from the section's "기준 DS 버전:" line before overwriting) with the **current** `manifest.json.version`.

If they differ:

- Emit a Korean warning prose just before the next-step message:
  > "⚠️ DS 버전 변경 감지: 직전 빌드 `<old>` → 현재 `<new>`. 재조립된 `cd-prompt.paste.md`는 현재 DS를 인용합니다. 이미 claude.ai/design에서 외부 실행 중인 라운드가 있다면 그 산출물은 직전 DS 기준이므로, `design-ingest`가 drift를 감지하면 그때 의사결정하세요."
- Do not block; the user decides whether to regenerate or proceed.

## Step 5: Korean next-step emit

> "CD 프롬프트 섹션을 `docs/{slug}.md`에 in-place authoring하고 붙여넣기 블록을 `docs/{slug}-fe/cd-prompt.paste.md`에 작성했습니다.
>
> 다음 단계: `/cc-cmds:design-review --base docs/{slug}.md`로 base 설계 문서 전체 일관성을 검증하세요. 리뷰가 반영되면 `/cc-cmds:design-prompt`를 다시 실행해 붙여넣기 블록을 재조립한 뒤, `docs/{slug}-fe/cd-prompt.paste.md`를 claude.ai/design에 붙여넣어 실행하세요."

Substitute `{slug}` with the actual slug.

## Idempotency contract

- The section anchor is `## Claude Design 프롬프트 + 컨텍스트`. Two re-runs from identical inputs produce identical section content (deterministic) and an identical paste block.
- Re-runs **never append** under any condition. They replace the section body in place and overwrite the paste block.
- The paste block is a **derived artifact**; the base design document section is the **source of truth**. `design-review --base` audits the base document; it never audits the paste block.

## EXEMPT rationale (no `## Control-Flow Invariants` heading)

Linear authoring with idempotent in-place replacement. No loop, no termination counter, no in-session variable. Exempt from `lint-skill-invariants.sh` rule (A) on the same grounds as `design-system`.

## Constraints

- NO code modifications outside `docs/{slug}.md` (in-place section edit) and `docs/{slug}-fe/cd-prompt.paste.md` (overwrite).
- User-facing strings in Korean; internal control prose in English; the paste block mixes English (instructions for Claude Design) and Korean (feature intent quoted from the base document section).
- Quote `tokens.css` byte-verbatim — never re-order, normalize, or strip wrappers from `:root` blocks.
- DS `manifest.json` is read-only here; `design-prompt` never writes to the DS workspace.
- This skill is fully deterministic from disk inputs and does NOT call `AskUserQuestion`. No deferred-tool loading required.

Base design document: $ARGUMENTS
