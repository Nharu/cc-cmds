# Claude Design Handoff Bundle Parser (Shared Extraction Contract)

Shared parsing prose for claude.ai/design handoff bundles. Loaded by both ingest callers:

- `design-system` phase 2 (DS bundle → `tokens.css` / `tokens.md` / `components.md` / `manifest.json`).
- `design-ingest` (feature bundle → `iter-NNN/handoff-extract.md` + reviewing Agent).

Both callers receive the **same uniform output record** regardless of which extraction rung fired. Callers branch on record content (e.g., `tokens_absent`, `unresolved_questions`), never on "which rung succeeded." The rung ladder is an internal implementation detail of this file.

The companion file `_common/handoff-contract.md` defines the YAML frontmatter schema this parser fast-paths on Rung 1; emitters cite the same file. Load both:

```
Read ${CLAUDE_SKILL_DIR}/../_common/handoff-contract.md
Read ${CLAUDE_SKILL_DIR}/../_common/parse-handoff.md
```

## 1. Input

A single directory path `{bundle-root}`. The caller selects this root from its drop directory (typically the most-recently-modified sub-directory under `docs/design-system/incoming/` or `docs/{slug}-fe/handoff/incoming/`) before invoking the contract. This file does not own multi-bundle disambiguation.

## 2. MALFORMED structure gate (pre-ladder, caller-agnostic)

Before entering the rung ladder, check the three structural preconditions. If ANY fails, return immediately:

```
{ status: "MALFORMED", reason: <one of below> }
```

Failure conditions:

- `{bundle-root}` is not a directory, or is not readable.
- `find {bundle-root} -name 'README.md'` yields zero results (neither outer nor inner README present).
- `find {bundle-root} -name '*.html'` yields zero results (no HTML pages at all).

**Token absence is NOT a MALFORMED condition.** A bundle with a README and at least one HTML but no `:root` block proceeds through the ladder; the resulting record carries `tokens_absent: true` and the caller decides severity. (`design-system` phase 2 treats it as a blocker; `design-ingest` routes to the `var()`-reference verification path.)

The gate is intentionally narrow. Anything richer (token presence, primary-page resolution, contract validity) lives inside the ladder and surfaces as record content, not as MALFORMED.

## 3. README discovery

```
find {bundle-root} -name 'README.md'
```

For each result, scan the first ~50 lines for the literal key `handoff_schema:`.

- The README whose first ~50 lines contain `handoff_schema:` is the **inner README** — the Rung 1 fast-path source.
- All other READMEs are **outer-README candidates** — Rung 2 anchors for primary-page resolution via the ``Read `<path>` in full`` pattern.
- If no README matches, `inner_readme = null` and the ladder skips directly to Rung 2 for every field.
- If multiple READMEs match (unobserved in the field study, but defensible), prefer the one nested deepest under `project/` or its equivalent content folder.

## 4. Rung 1 — CONTRACT (frontmatter short-circuit)

**Condition:** `inner_readme` is non-null AND its `handoff_schema` equals `1`.

Parse the YAML frontmatter (everything between the first `---` and the next `---` in `inner_readme`) and extract `kind`, `primary`, `pages[]`, `tokens_file`, `theme_mode[]`, `stack`, `components[]`, plus `feature`, `fidelity`, `notes` (informational).

Then **cross-check every field against on-disk artifacts** before consuming it. Mismatched fields drop to Rung 2 *per field* — Rung 1 success or failure is not all-or-nothing:

| Field | Cross-check | On mismatch |
|-------|-------------|-------------|
| `primary` | File exists at `{bundle-root}/{primary}` | drop to Rung 2 for `primary`; add `unresolved_questions: "Rung1 primary='<value>' missing on disk"` |
| `tokens_file` | File exists AND contains at least one `:root` selector | drop to Rung 2 for tokens source; add unresolved |
| `pages[i].file` | File exists at `{bundle-root}/{file}` | drop that entry to Rung 2; keep valid entries |
| `stack` | HTML body matches the declared stack (see Rung 2 stack-detection grep) | HTML wins; log warning; do NOT mark unresolved (this is a hint, not a load-bearing field) |
| `kind` | Caller bundle-kind expectation | parser does NOT block; tag record `kind_mismatch: true` so caller can warn |
| `theme_mode`, `components`, `feature`, `fidelity`, `notes` | No automated cross-check (these are descriptors, not load-bearing) | passed through as-is |

Fields that pass cross-check are consumed at Rung 1. Fields that fail re-enter the ladder at Rung 2.

Set `contract_used: true` and `rungs_fired_per_field.<name> = 1` for each Rung 1 success.

## 5. Rung 2 — BEST-EFFORT (SAFE anchor heuristics)

**Condition:** Rung 1 did not fire (no valid contract) OR specific Rung 1 fields failed cross-check.

For each field that still needs resolution, apply the heuristic below. The anchors come from the 6-bundle field study and are observed in 6/6 bundles unless noted.

### 5.1 Primary page

1. Scan **every** outer-README candidate for the literal pattern ``Read `<path>` in full`` (case-insensitive on `Read` / `in full`; the backtick-quoted `<path>` is the canonical match). Take the first match across READMEs. (Pattern observed in 6/6.)
2. If no match: list all `*.html` under `{bundle-root}`. If exactly one HTML, that is `primary`.
3. If multiple HTML files and no README marker: add `unresolved_questions: "PRIMARY_AMBIGUOUS: candidates=[file1, file2, ...]"`. The caller surfaces this via `AskUserQuestion`. The parser does not pick blindly.

### 5.2 Pages

`find {bundle-root} -name '*.html'` and emit each as a `pages[]` entry:

```
{ file: <relative-path>, title: <stem with hyphens→spaces, Title Case>, route: null, provenance: "rung2" }
```

Tag the `primary` entry with `is_primary: true`. The `title` heuristic is intentionally lossy — `design-apply` can refine route/title when the contract was absent.

### 5.3 Tokens source

Search for `:root` blocks in priority order:

1. If Rung 1 surfaced a valid `tokens_file`, use that file.
2. Walk `<link rel="stylesheet" href="...">` tags in every HTML file and follow each `href` to its `.css` file under `{bundle-root}`. Any `.css` file containing `:root` is a token-source candidate.
3. Scan the primary HTML's inline `<style>` blocks for `:root`.

All candidates are extracted in §7 (cross-cutting token value extraction); Rung 2 only locates the files.

### 5.4 Stack detection (HTML is authoritative)

Grep across HTML files in priority order:

- Match `react@18` OR `react-dom@18` OR `@babel/standalone` → `stack: "react"`.
- Else match `customElements.define\(` → `stack: "web-components"`.
- Else → `stack: "pure-html"`.

This grep is also used in Rung 1 to validate a Rung 1 `stack` hint.

### 5.5 Theme modes

Scan all `:root` selectors and their wrapper contexts across token-source files. Detect:

- `:root[data-theme="<name>"]` → theme `<name>`.
- `@media (prefers-color-scheme: dark) { :root { ... } }` → theme `dark`.
- `.dark :root` or `.dark { ... }` (when used as a theme switch) → theme `dark`.
- Plain `:root` with no wrapper → theme `default` (treated as `light` for catalog purposes).

`theme_modes[]` is the deduplicated list of detected themes. Single-theme bundles emit `["light"]`.

### 5.6 Component inventory (intentionally loose)

Component records are coarser than token blocks — they capture **shape**, not values, and are explicitly tagged with `provenance: "rung2"` (or `"agent-inferred"` from Rung 3) so callers know not to derive contracts from them. Scan rules by stack:

- **React** (`stack == "react"`):
    - Match `function ([A-Z][A-Za-z0-9_]*)\s*\(` and `const ([A-Z][A-Za-z0-9_]*)\s*=\s*\(` in JSX/HTML files.
    - Source file = the file containing the declaration.
- **Web Components** (`stack == "web-components"`):
    - Match `customElements\.define\(\s*["']([a-z][a-z0-9-]+)["']`.
    - Source file = the file containing the registration.
- **pure-HTML** (`stack == "pure-html"`):
    - Collect every `className=` / `class=` attribute. Cluster classes appearing in 3+ distinct elements. Each cluster is a component candidate named after its most-distinctive class (e.g., `card-header` over `card`).

Each component record:

```
{
  name: <string>,
  stack_kind: <react | web-components | pure-html>,
  anatomy: <terse prose or empty>,
  states: [<hover|focus|disabled|...>],
  a11y: [<aria-* attributes observed>],
  usage: <terse prose or empty>,
  source_file: <relative path>,
  provenance: "rung2"
}
```

`anatomy` / `usage` may be empty strings on Rung 2 — the reviewing Agent in `design-ingest` fills them via Rung 3 when the field study's looseness leaves the record under-specified. **Do not retrofit token-level rigor** (verbatim slice, divergence grouping) to components; the field study confirmed components are inferential prose, not byte-anchored bytes.

## 6. Rung 3 — AGENT direct-read (terminal fallback)

**Condition:** Rung 2 anchors were indecisive (multiple primary candidates, ambiguous token source, component inventory too sparse to be useful), AND the resulting record's `unresolved_questions[]` is large enough that callers cannot proceed productively.

Spawn an `Agent()` (this parser's calling skill is responsible for the call) with the bundle's primary HTML and any imported files as input, and ask it to extract `primary`, `pages[]`, `components[]`, and structural prose. Tag every Rung 3 output with `provenance: "agent-inferred"`.

**Hard constraint — Rung 3 cannot generate token values.** Token *values* always come from §7 (reading `:root` bytes). Rung 3 may correct a Rung 2 token-source *location* (e.g., "the canonical token file is `theme/colors.css`, not the inline `<style>`"), but the actual bytes still flow through `provenance: "authored-css"`. This keeps `design-system` phase 2's `tokens.css` synthesis byte-verbatim.

Note: this Agent is a **structural-extraction Agent**, distinct from `design-ingest`'s separate **quality-review Agent** (the 5-axis review described in `design-ingest/SKILL.md`). The two run at different lifecycle points with different inputs.

## 7. Token value extraction (cross-cutting; runs regardless of rung)

Token values are always read from actual `:root` blocks on disk. This step runs once the token-source files have been located (by Rung 1 contract, Rung 2 heuristic, or Rung 3 correction).

For each candidate file:

1. Find every CSS selector matching `:root`, `:root[<attribute>]`, `.dark :root`, or `:root` nested inside `@media (prefers-color-scheme: ...) { ... }` or `@media (...) { ... }`.
2. For each match, capture the **wrapper-inclusive raw block text** — for example, the full `@media (prefers-color-scheme: dark) { :root { --bg: #111; --fg: #eee; } }` block, not just the inner `:root { ... }` portion. Stripping wrappers would make dark tokens apply unconditionally when the block is re-emitted.
3. Determine `theme_key`:
    - Bare `:root` → `default`.
    - `:root[data-theme="dark"]` → `dark` (and so on for other values).
    - `@media (prefers-color-scheme: dark)` wrapper → `dark`.
    - `.dark` switch → `dark`.
4. Record `provenance: "authored-css"`; record `origin: "inline-style"` if the source file is an HTML file's inline `<style>`, else `origin: "shared-file"`.
5. Emit a `token_blocks[]` entry:
    ```
    {
      source_file: <relative path>,
      selector: <e.g., ":root[data-theme=\"dark\"]">,
      theme_key: <default | dark | light | ...>,
      raw_block_text: <wrapper-inclusive verbatim bytes>,
      provenance: "authored-css",
      origin: "inline-style" | "shared-file",
      divergent: false
    }
    ```
6. After collecting all blocks, **derive `token_groups`** by grouping `token_blocks[]` on `(selector, theme_key)`:
    - If a group's blocks have identical `raw_block_text`, dedupe to a single entry (the parser caller may emit "N sources identical" as a comment).
    - If a group's blocks differ in `raw_block_text` (same `:root[data-theme="dark"]` but different declarations across files), set `divergent: true` on every member block and add `unresolved_questions: "DIVERGENT_TOKENS: theme=<theme_key>, sources=[file1, file2]"`. Do NOT auto-collapse — divergence is meaningful (see caller branching below).
7. **Token values are never normalized.** Preserve `oklch(0.7 0.2 240)` vs `#3b82f6` vs `rgb(59 130 246)` exactly as written. Any color-space conversion happens later in `design-apply`, not in the parser.

Finally, scan every HTML/JSX file under `{bundle-root}` for `var(--<name>)` references. Any `--<name>` that appears in a `var()` call but is not declared in any `:root` block goes into `referenced_undefined_vars[]`. `design-ingest` uses this list to verify against the canonical DS for `var()`-only feature bundles.

If `token_blocks[]` is empty after this step, set `tokens_absent: true`.

## 8. Uniform output record

Both callers receive the same shape. Happy-path and fallback differ only in `provenance` tags, `rungs_fired_per_field`, and `unresolved_questions[]` content — never in record structure.

```
{
  status: "OK" | "MALFORMED",
  reason: <string when MALFORMED>,

  // Structural metadata
  primary: <bundle-root relative path | null>,
  pages: [ { file, title, route?, provenance, is_primary?: bool } ],
  stack: "react" | "web-components" | "pure-html",
  theme_modes: [ "light", "dark", ... ],

  // Tokens — values always from on-disk :root bytes
  token_blocks: [
    { source_file, selector, theme_key, raw_block_text, provenance, origin?, divergent }
  ],
  token_groups: [
    { selector, theme_key, blocks: [ /* indices into token_blocks */ ], divergent }
  ],
  tokens_absent: <bool>,                        // true iff token_blocks is empty
  referenced_undefined_vars: [ "--token-name", ... ],

  // Components — lossy by design
  components: [
    { name, stack_kind, anatomy, states, a11y, usage, source_file, provenance }
  ],

  // Contract metadata
  kind: "feature" | "design-system" | null,     // from Rung 1 contract; null if no contract
  kind_mismatch: <bool>,                        // caller assertion failure flag
  feature: <slug | null>,                       // from Rung 1
  fidelity: "high" | "mid" | "low" | null,      // from Rung 1
  notes: <string>,                              // from Rung 1

  // Telemetry for caller branching
  contract_used: <bool>,                        // true iff Rung 1 fired for at least one field
  rungs_fired_per_field: {                      // tracks which rung produced each field
    primary: 1 | 2 | 3,
    pages: 1 | 2 | 3,
    tokens: 1 | 2 | 3,
    stack: 1 | 2,
    theme_modes: 1 | 2,
    components: 2 | 3
  },
  unresolved_questions: [ <human-readable string>, ... ]
}
```

### Caller branching examples (informational)

- `status == "MALFORMED"` → caller surfaces via `AskUserQuestion` (edit-bundle-and-retry / re-download / abort).
- `kind_mismatch == true` → caller emits a warning prose but typically proceeds.
- `tokens_absent == true`:
    - `design-system` phase 2: **block** — DS workspace cannot be built without `:root` bytes; escalate to user.
    - `design-ingest`: this is the `var()`-only feature-bundle path; verify each `referenced_undefined_vars[]` entry against the canonical `docs/design-system/tokens.css`; any miss = REFINE.
- Any `token_groups[i].divergent == true`:
    - `design-system` phase 2: escalate — the DS must be uniform.
    - `design-ingest`: pass to the reviewing Agent as REFINE-eligible (the divergence may be intentional per-screen, not a hard block).
- `unresolved_questions[]` non-empty → caller decides per-question (some surface via `AskUserQuestion`, some go into `handoff-extract.md` as open notes for the reviewing Agent).

## 9. Idempotency

The bundle is immutable input. Re-invoking the parser on the same `{bundle-root}` MUST yield an identical record (same field values, same `rungs_fired_per_field`, same `unresolved_questions[]` ordering). Callers may rely on this for retry-on-error or restart-after-interruption.

## 10. Bash portability note

This file is markdown prose, and the repo's `lint-bash-portability.sh` scans only `*.sh` files. Bash idioms embedded here are therefore **manually disciplined** for BSD (macOS) ↔ GNU (Linux) coreutils compatibility. Calling skills should mirror these conventions when shelling out:

- `find "$dir" -mindepth 1 -maxdepth 1 -type d` — portable directory enumeration.
- `find "$dir" -maxdepth 1 -type f -name '*.html'` — portable file glob with single-quoted pattern.
- `mv -n` — portable atomic non-overwrite move.
- Avoid GNU-only `find -printf`, GNU-only `sed -i` without backup arg, BSD-only `readlink -f` without `-e`.

## 11. Calling convention recap

The calling SKILL.md performs all write/output operations inline; this prose owns extraction only. The minimal call pattern in a caller skill is:

```
Read ${CLAUDE_SKILL_DIR}/../_common/handoff-contract.md
Read ${CLAUDE_SKILL_DIR}/../_common/parse-handoff.md
# ... apply MALFORMED gate, ladder, token extraction ...
# ... emit uniform record ...
# Caller now branches on record content, NOT on which rung fired.
```

The handoff-contract is loaded first so emitter and parser both quote the same schema definition; the parse-handoff prose builds on that schema for Rung 1.
