# Claude Design Handoff Frontmatter Contract (Shared Schema)

Single source of truth for the YAML frontmatter we ask Claude Design (claude.ai/design) to embed in handoff bundles. Both the **emitters** (`design-system` phase 1 and `design-prompt`) and the **parser** (`_common/parse-handoff.md` Rung 1) cite this file:

- Emitters quote the schema block below verbatim inside a "HANDOFF CONTRACT" section of the prompt they send to Claude Design.
- The parser uses the same schema as its Rung 1 fast-path source of bundle structure metadata.

Keeping both sides citing one file means schema drift fixes happen in one place.

## Purpose and posture

We do not control the Claude Design output format — the 6-bundle field study (`docs/fe-claude-design-pipeline.md` §0.1) confirmed it is a free-form artifact behind a thin set of stable anchors (outer README, `project/` folder, ≥1 HTML, `:root` for tokens). To make parsing predictable on the common path, we ask Claude Design to **prepend a YAML frontmatter to the inner README** describing the bundle structure we just received. This is an opportunistic accelerator, not a load-bearing contract: the parser degrades gracefully through Rung 2 (SAFE anchors) and Rung 3 (agent-direct-read) when frontmatter is absent, malformed, or stale.

Three properties follow from that posture:

1. **Stale-safe.** Every field is cross-checked against the underlying source artifacts. If `primary` names a file that does not exist, the parser drops that field to Rung 2; it does not silently trust the declaration.
2. **Structure-only.** The contract describes **where to look** (paths, page list, token source file). It never carries token *values* — those are always read from the actual `:root` blocks on disk, regardless of which rung fired.
3. **Versioned by integer.** A strict-equality `handoff_schema` integer lets the parser detect skew. Any mismatch degrades to Rung 2 rather than silently partially trusting an unknown schema.

## Schema (`handoff_schema: 1`)

The exact block the emitter pastes into the "HANDOFF CONTRACT" section:

```yaml
---
handoff_schema: 1                       # int (strict-equality version key; skew → degrade to Rung 2)
kind: feature                           # feature | design-system (caller bundle-kind assertion)
feature: profile-settings               # kebab slug (need not match project folder name)
fidelity: high                          # high | mid | low
primary: "Profile Settings.html"        # bundle-root relative path to the primary page
pages:                                  # every HTML page the bundle ships, in display order
    - { file: "Profile Settings.html", title: "Profile Settings", route: "/" }
tokens_file: "colors_and_type.css"      # :root truth-source path (often shared .css; may be the primary HTML for inline-only)
theme_mode: ["light", "dark"]           # ["light"] for non-themed bundles
stack: react                            # opportunistic: react | web-components | pure-html (HTML detection is authoritative)
components: ["Button", "Toggle"]        # opportunistic hint list
notes: ""                               # free-form caveats / TODOs from CD; informational
---
```

## Field semantics

- **`handoff_schema`** — Integer, strict equality with the parser's expected version. The parser refuses to interpret any other value and falls back to Rung 2 for every field. There is no "partial trust" of an unknown schema.
- **`kind`** — Bundle classification. Each caller asserts the expected kind:
    - `design-system` phase 2 expects `kind: design-system`.
    - `design-ingest` expects `kind: feature`.
    Mismatch is a **caller-level warning**, not a parser MALFORMED — callers may choose to proceed (e.g., the user intentionally ingests a page bundle as DS source).
- **`feature`** — Kebab-case slug identifying the feature the bundle implements. Need not equal the project folder name (Claude Design's `<project-name>/` slug varies independently). Informational; not used for path resolution.
- **`fidelity`** — `high` | `mid` | `low`. Self-declared by Claude Design. Informational only; the reviewing Agent in `design-ingest` may compare against the requested fidelity but the parser does not act on it.
- **`primary`** — Bundle-root relative path to the page the coding agent should treat as the canonical entry point. **Cross-checked**: if the file does not exist, the parser drops `primary` to Rung 2 (outer README "Read `<path>` in full" pattern → single-HTML fallback → AskUserQuestion).
- **`pages[]`** — Every HTML page in the bundle, in display order. Each entry: `file` (bundle-root relative path), `title` (display label), `route` (intended path in the rendered app, useful for routing decisions in `design-apply`). **Cross-checked**: each `file` must exist; missing entries drop to Rung 2 per-entry.
- **`tokens_file`** — Path to the file that holds the authoritative `:root` block(s). Observed in the 6-bundle study to land most often in a shared `.css` (e.g., `colors_and_type.css`, `tokens.css`, `styles.css`), occasionally in the primary HTML's inline `<style>`. **Structure short-circuit only — this field never supplies token values.** Values are always read from the actual `:root` blocks at parse time. Cross-checked: file must exist and contain at least one `:root` selector; otherwise drop to Rung 2 for tokens.
- **`theme_mode[]`** — Declared theme variants. `["light"]` for non-themed bundles; `["light", "dark"]` (or more) when the bundle ships a themed token set. Used by the parser to anticipate wrapper selectors (`[data-theme="dark"]`, `@media (prefers-color-scheme: dark)`, `.dark`) when scanning `:root` blocks.
- **`stack`** — `react` | `web-components` | `pure-html`. **Opportunistic hint only.** Stack detection from the HTML body is authoritative — the parser greps for the React 18 CDN signature first, then `customElements.define`, then defaults to `pure-html`. If `stack` disagrees with the HTML, the HTML wins and the hint is logged as a warning.
- **`components[]`** — Opportunistic name hints for the component inventory. The parser builds its component records by scanning the HTML/JSX directly; this list is used as a hint to disambiguate or label inferred components but never as the source of truth.
- **`notes`** — Free-form caveats from Claude Design (TODOs, known gaps, fidelity notes). Informational; the reviewing Agent in `design-ingest` may surface this verbatim in `handoff-extract.md`.

## Where the frontmatter lands (observed)

In the 6-bundle field study, Claude Design places the contract frontmatter in the **inner README** — the `README.md` co-located with the HTML files inside the content folder — and leaves the **outer README** (the one starting with "CODING AGENTS: READ THIS FIRST") untouched as a human-facing document.

Practical consequences for the parser:

- Do **not** assume a fixed path. Discover the inner README by walking every `README.md` under `{bundle-root}` and selecting the one whose first ~50 lines contain `handoff_schema:`.
- The outer "CODING AGENTS" README is still a valuable Rung 2 anchor (it carries the ``Read `<path>` in full`` primary-page marker that worked in 6/6 observed bundles), but it is not the contract source. Both READMEs coexist; the parser treats them as separate inputs.

## Non-load-bearing contract

The parser must not silently trust frontmatter values that disagree with the on-disk artifacts. The discipline is:

- **Validate every field against the source** before consuming it (see Rung 1 cross-check rules in `parse-handoff.md`).
- **Degrade per-field**, not per-document. A bundle whose `primary` is stale but whose `pages[]` is intact uses Rung 1 for `pages[]` and Rung 2 for `primary`.
- **Never derive token values from the contract.** `tokens_file` is a path hint; the actual `--token: value;` declarations come from reading that file's `:root` blocks at parse time, with `provenance: authored-css` only when the bytes are present on disk.
- **Surface mismatches** as `unresolved_questions[]` entries in the parser's output record so the calling skill (or its reviewing Agent) can react.

## File format note

This file is markdown prose with one embedded YAML schema block. It is loaded via `Read ${CLAUDE_SKILL_DIR}/../_common/handoff-contract.md` by every emitter and by the parser. It contains no bash, no path resolution, and no executable instructions — its only job is to be the single canonical schema definition that all sides cite.
