You are deriving a segment DAG from a design document's recommended implementation order. Return ONLY the structured object the schema demands.

The section you are reading has **no prescribed format** — measured across the corpus, only 7% of documents that carry it use step headings, while backticked file paths (78%) and numbered items (85%) are common. Every parse of it is therefore a heuristic by construction, and the design of this one is to **fail toward safety, not toward cleverness**.

## Derivation, in order. Stop at A if A fires.

**A. Author pre-emption.** If the document already groups the work explicitly — a `## 구현 슬라이싱` section, `### 슬라이스 X` headings, `**N단계 —**` markers — **adopt that grouping verbatim and skip B through F.** Re-deriving what a human already answered can only lose information.

**B. Items.** Top-level `^[0-9]+\. ` lines; failing that, top-level bullets; failing that, `###` sub-blocks.

**C. File sets.** For each item, every backticked path carrying an extension and every `path:line` anchor, taken from the item's prose **including indented continuation paragraphs**. An item with an empty file set inherits the previous item's set and is tagged `weak-attribution`.

**D. Edges.**
- `E_atomic` — co-landing vocabulary: `같은 커밋`, `원자적으로 함께`, `함께 착지`, `동시에`, `분리 적용이 불가능`, and the `N + M` notation.
- `E_order` — sequencing vocabulary: `먼저`, `그다음`, `보다 반드시 먼저`, `선행조건`, `마지막에`.
- `E_file` — items sharing a file are in the same segment by default.
- `E_release` — an item naming `CHANGELOG`, a `plugin.json` bump, or `chore(release)` is **forced into a single final segment**.

**E. Grouping.** Take connected components of `E_atomic ∪ E_file`, then topologically sort by `E_order`. If two components have an `E_order` cycle between them they are inseparable: merge.

**F. Split only on positive evidence.** Split along an `E_order` edge only when it cuts no `E_atomic` edge **and** the two file sets are disjoint. An explicit shippability statement in the prose ("독립 minor bump로 선행 출하 가능") is itself positive evidence for a split.

## The asymmetry that governs every uncertain call

**When in doubt, merge. Never split.** This is not an aesthetic preference. A wrongly merged segment costs a larger pull request — recoverable and visible. A wrongly split segment **merges half of a self-inconsistent state**, and in an unattended run nobody is awake to catch it.

Two consequences follow:

- If the derivation yields **more than 5 segments with no author grouping**, treat that as overfitting: fold everything into one segment and set `segmentation` to `low-confidence`. An author-numbered plan that states its dependencies inline is exempt from this fold — stating dependencies is what earns the exemption.
- Every `weak-attribution` item is force-merged into the component it inherited from.

## Two composition rules that are not heuristics

- **Residual verification items go in ONE segment, and that segment runs alone in its antichain.** The design document is a shared write target that no segment declares: the implementation arm's two reserved write forms touch it, so two segments in one wave would contend and trip a fail-loud diff gate. Assign every in-scope residual item to a single segment. If that is impossible because the items genuinely straddle file-disjoint components, mark the wave `serial`.
- **A segment that declares `SKILL.md` also declares `README.md`.** That file is generated from skill frontmatter and gated for staleness, so the sharing is real but invisible in the prose — it is the blind spot the file-set rule cannot see on its own. The trigger is creation as well as edit, so a brand-new skill file is covered too.

## Item count is not segment count

Two real documents measured: 17 items collapsed to 5–6 segments; 41 slots collapsed to 2. Mapping items straight to segments would have produced 17 and 41 pull requests.
