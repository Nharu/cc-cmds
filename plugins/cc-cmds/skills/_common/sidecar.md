# Sidecar File Contract (Shared SOT)

Single source of truth for **out-of-document sidecar files** — the `docs/<kind>/{slug}.md` artifacts a skill writes *beside* a design document rather than into it. `## 1` owns the mechanics every sidecar shares regardless of payload (slug derivation, the provenance guard, atomic write, lifetime, versioning). `## 2` owns the block schema of the **re-convergence sidecar**, the artifact that carries an `implement`-time refutation across a session boundary to a `design` re-convergence.

**Why a sidecar rather than an in-document section.** A design document has a one-writer-per-section invariant, and each writer's byte surface is enumerated so a sweep can prove no other byte moved. A second writer wanting durable state therefore cannot take a new in-document section without enlarging that surface — and an enumerated write surface is the machinery of a *permanent* ledger, not of every feature that needs to remember something. A sidecar keeps the document's surface unchanged, survives a full re-synthesis of the document (which today has no carry-forward for non-enumerated sections), and costs nothing in durability: `docs/` is gitignored in this repo, so an in-document write is no more permanent than a sidecar.

**What this file owns vs. what each SKILL.md owns.** This file is *contracts-only*: paths, grammars, schemas, predicates, and write mechanics. It deliberately excludes *workflow prose* — when a writer decides to write, what it reports to the user, and how a reader routes what it finds all live in the owning SKILL.md. A skill that writes or reads a sidecar Reads this file; it never re-authors the grammar.

**Consumption matrix.** `implement` Reads `## 1` + `## 2` at a verification failure branch, conditionally (writer of the re-convergence sidecar) — **not yet landed**. `design` Reads `## 1` + `## 2` at its re-convergence sidecar check (reader) — **not yet landed**. `implement`'s temporary visual-fidelity gate carries its own copy of the `## 1` mechanics inline and is **deliberately not retargeted** to cite this file: that section is scheduled for wholesale deletion, so rewriting a live path for zero permanent gain would only widen the blast radius. Two slug rules addressing two different directories, each internally deterministic, is a harmless duplicate for that section's remaining life.

---

## 1. Generic sidecar mechanics

### 1.1 Path and slug derivation

A sidecar lives at `<base>/docs/<kind>/{slug}.md`, where `<kind>` names the mechanism (`design-reconverge`, `visual-drift`, …) and `{slug}` identifies the design document the sidecar belongs to.

**Deriving `{slug}`.** Take the design document's path relative to the repo root, strip the `.md` extension, and replace every path separator `/` with `-`. So `docs/a/login.md` yields `docs-a-login`.

**Resolving `<base>` and the relative path — keyed on the document's own location, never on the cwd.** Run `git rev-parse --show-toplevel` **from the design document's own directory**. If the document sits under the returned root, that root is `<base>` and the relative path is taken against it. If it does not — or if no repo root can be resolved at all — fall back to the document's absolute path with only the leading `/` removed, and `<base>` is the document's own directory. Keying on the document rather than the cwd makes the derivation deterministic even when the cwd is inside a repo but the document is outside it.

**The slug is deterministic but NOT injective.** Because `/` folds to `-`, a literal `-` in one path can collide with a directory boundary in another: `docs/visual-drift.md` and `docs/visual/drift.md` both yield `docs-visual-drift`. **Collisions are not prevented by the slug — they are caught by the provenance guard of §1.2**, which compares the full relative path rather than the folded slug and therefore catches *every* collision regardless of how rare they are.

**No pointer is needed.** A reader re-derives the slug from the same rule and finds the file. Nothing in the design document references the sidecar.

### 1.2 Header grammar and the `owner-doc=` provenance guard

Line 1 is a human-readable H1. Line 2 is the machine header, a single HTML comment:

```
<!-- cc-<kind> v<N>; writer=<skill>; reader=<skill>; owner-doc=<repo-root-relative design document path>; NOT a design doc; not committed (docs/ gitignored) -->
```

`writer=` and `reader=` name the roles rather than a single `owner=`, because a sidecar whose writer and reader are different skills has two distinct byte surfaces (see §2.6).

**The guard is symmetric — a read guard and a write guard with the same predicate.**

- **Read guard.** Before applying anything a sidecar says, compare its `owner-doc=` against the current design document's repo-root-relative path. On a mismatch the file belongs to a different document (a slug collision): **do not apply its content**, and treat the subject as un-processed so the owning mechanism re-runs. Never silent-skip.
- **Write guard.** If the target file already exists, compare its `owner-doc=` the same way *before* writing. On a match the file is ours — proceed. On a mismatch, or when the `owner-doc=` field is **absent**, do not write: preserve the existing file, report the cause on the user-facing surface, and let the caller's own failure path take over.

**Absence is treated as mismatch.** A missing `owner-doc=` does not prove ownership, so it fails closed in both directions. This is the whole guard: it is what makes the non-injective slug safe.

### 1.3 Atomic write

Write the whole intended file content to a temp file **in the same directory as the target**, then rename:

```
T=$(mktemp "$(dirname "$TARGET")/.$(basename "$TARGET").XXXXXX")
# … build the complete content in "$T" …
mv "$T" "$TARGET"
```

- **Same directory is mandatory.** A temp under `${TMPDIR:-/tmp}` may sit on another filesystem, where `rename(2)` is not atomic and `mv` degrades to copy-then-unlink.
- **Plain `mv`, never `mv -n`.** The no-clobber form is correct for a witness file that must never be overwritten, and copying that idiom here is a silent data-loss bug: every write after the first would be skipped, so an accumulating sidecar would keep exactly its first block forever.
- **No lock.** After the `mv`, read the file back and confirm the intended content landed; on a mismatch, retry once. The hazard class is what justifies this — a lock is warranted when the failure mode is an unbounded repeat, whereas here the worst case is one lost block. The read-back is load-bearing precisely because it converts a **silent** loss into a **detected** one, which is the entire basis for declining the lock. Omit it and two concurrent writers can drop a block with no error anywhere.

### 1.4 Lifetime — never delete, never truncate, never `git add`

- A skill **never deletes** a sidecar and never removes a block from one. State transitions happen in place; cleanup is the user's, by hand.
- A skill **never truncates** an existing file to write a shorter one. Whole-file atomic write means *read, extend in memory, write the whole thing back* — not overwrite-from-empty.
- A skill **never `git add`s** a sidecar. Under this repo's `.gitignore` these files are user-local by construction; staging one would defeat that.

### 1.5 Version token and migration

The header carries `cc-<kind> v<N>`. A reader matches it by **strict equality** against the version it understands. On a mismatch: skip the file, report it, and **do not delete or rewrite it**.

**No automatic in-place migration.** Because `docs/` is gitignored, a botched migration has no `git` undo — the bytes are simply gone. Migration, if it is ever needed, is a deliberate user-driven step, never a side effect of a reader noticing an old version.

### 1.6 Artifacts stay out of tree; the sidecar carries the recipe

Binary or bulky products of the mechanism (screenshots, captures, extracted corpora) go to an out-of-tree scratch directory such as `mktemp -d "${TMPDIR:-/tmp}/cc-<kind>-{slug}.XXXXXX"`, and the sidecar does **not** cite those paths — they are session-local and will not exist later. What the sidecar records instead is the **one-line reproducible recipe** plus durable pointers (a prototype path, a document anchor). The duty is to leave behind what regenerates the artifact, not the artifact.

---

## 2. The re-convergence sidecar — `docs/design-reconverge/{slug}.md`

Carries a refuted or undecidable verification claim from an `implement` failure branch to a later `design` re-convergence, across a session boundary. Header:

```
# 설계 재수렴 요청 — {slug}
<!-- cc-design-reconverge v1; writer=implement; reader=design; owner-doc=<repo-root-relative design document path>; NOT a design doc; not committed (docs/ gitignored) -->
```

### 2.1 Cycle blocks

Re-convergence can recur on the same design document, so blocks **accumulate in one file** — one file per design document, never one per cycle. Each block is `## 회차 <N>`, where `N` is `max(existing) + 1` **re-derived from the bytes just read**, never from memory.

A block carries its own `상태`, so the file-level "is there work here" predicate is a disjunction over blocks (§2.7), not a file-level flag.

### 2.2 Field schema — 18 fields, fixed order

| # | Field | Required | Mutability |
| --- | --- | --- | --- |
| 1 | `상태` | always | **design only**, once |
| 2 | `처리 기록` | iff `처리됨` | **design only**, inserted once |
| 3 | `사용자 라우팅` | always | **implement only**, once, same invocation, only while `대기` |
| 4 | `관측 일시` | always | frozen |
| 5 | `정지 지점` | always | frozen |
| 6 | `대상 항목` — `§구현 시 검증 항목 R<n> — <title>` | always | frozen |
| 7 | `검증 등급` | always | frozen |
| 8 | `분류` | always | frozen |
| 9 | `트리 위생` | always | frozen |
| 10 | `주장` | always | frozen |
| 11 | `기대 결과` | always | frozen |
| 12 | `관측 요지` | always | frozen |
| 13 | `관측 결과` — fenced | always | frozen |
| 14 | `관측 절단` | iff truncated | frozen |
| 15 | `실행된 레시피` — fenced | always | frozen |
| 16 | `치환 맵` — `없음` when the drift ladder's re-derivation rung did not fire | always | frozen |
| 17 | `실패 시 영향` | always | frozen |
| 18 | `완료 작업` / `블록된 작업` | iff `정지 지점` is the mid-implementation value | frozen |

Field lines use the same CANON rendering as the verification contract: bold key, no leading bullet, one ASCII space after the colon.

**Every document-sourced field is re-read from the design document at write time and copied verbatim** (`주장`, `기대 결과`, `실패 시 영향`, `분류`, the `R<n>` heading, the recipe's original text). Never restated from context.

**No reconstruction.** Each always-required field has one defined unavailability token; a value that is absent with no token makes the block **malformed**, and a malformed block is surfaced rather than consumed. This rule is what makes a reader's "observation unavailable" branch reachable by contract — without it that branch is dead code, and a full-trust reader then has no defense against a fabricated observation.

**Session handles are never recorded** — no agent identifiers, scratch directories, transcript paths, nonces, generation counters, ledger fragments, or session-local `${TMPDIR}` paths. A sidecar transports findings, not handles. The concrete exposure is `실행된 레시피`: a recipe run inside a temporary worktree naturally embeds a session-local path, and a `/tmp` literal is itself a malformedness axis in the verification contract, so the field table alone does not block it.

### 2.3 Frozen-tail invariant

> **Field lines 1–3 are the block's mutable region, partitioned by owner: 1–2 belong to the reader, 3 to the writer. Line 4 onward is frozen from the instant of the first write and is never touched by any writer, ever.**

The invariant is what makes the verbatim copies of §2.2 safe from divergence: a reader can say *everything below line 3 was true at `관측 일시`, and nothing in it claims to be true now.* `grep -A3 '^## 회차'` therefore yields state and routing for every block in one command — exactly the two fields the predicates of §2.7 key on.

### 2.4 Closed vocabularies

| Field | Values |
| --- | --- |
| `상태` | `대기` \| `처리됨` |
| `사용자 라우팅` | `설계 재수렴` \| `위험 수용하고 계속` \| `중단` \| `미응답` |
| `정지 지점` | `구현 전` \| `구현 중(<phase>)` |
| `검증 등급` | `반증됨(실패)` \| `검증불가(드리프트)` |
| `트리 위생` | the five values of the table below |

**`상태` has exactly two values.** There is deliberately no in-progress value: with no intermediate state there is no intermediate state to recover, which is the whole crash-safety argument.

**`사용자 라우팅` values are frozen to the writer's own prompt labels.** Transport fidelity is the point; translating a value inserts precisely the layer where a byte slips. A reader that needs to disambiguate does so on **its own** option labels, never by rewriting the transported value.

**`트리 위생` records what actually held at observation time, and maps 1:1 onto the tree-hygiene note the reader writes.**

| `트리 위생` value | What the reader writes |
| --- | --- |
| `워크트리 격리 확인` | `워크트리 격리 확인` — no validity note |
| `진입 시 clean · 진입 대비 무변경 확인` | `tracked-source 무변경 확인` — no validity note, and it is **true** |
| `진입 시 dirty(<N>건) · 진입 대비 무변경 확인` | validity note: (i) sidecar path + `관측 일시`, (ii) this predicate verbatim |
| `구현 중 — 진입 기준선 없음` | validity note: (i) + (ii) no entry baseline exists at this branch |
| `미확인` | validity note: (i) + (ii) unknown |

The second row is the load-bearing one: an implementation-time observation does **not** automatically weaken the tree-hygiene claim. If the entry baseline was empty and the boundary gate passed, the clean note is a true statement. The field carries that distinction, so the reader renders the note with zero judgment.

### 2.5 Verbatim observation payloads

`관측 결과` and `실행된 레시피` are always fenced, with a bare-colon key line above the fence.

- **Variable-length fence**: `N = max(3, longest backtick run in the payload + 1)`, so payload backticks cannot terminate the fence early. Mandatory `text` info string.
- **Caps**: 80 lines, plus a 2000-character clamp on any single line. When either fires, declare `관측 절단`.
- **Reduction is the recipe's job, not the model's.** The payload carries the values the recipe's own `기대 결과` is a predicate over, exactly as produced, together with the counts and inputs the recipe's own procedure names. When the raw corpus exceeds the cap, reduce it **by the recipe's own aggregation step**. An aggregation the recipe does not specify is a reconstruction, and reconstruction is forbidden.
- **Fence-aware tokenizing is a normative reader rule**: inside an open fence, no line is a heading or a field line. This makes block forgery from payload content inert.
- **An odd total fence count means a truncated file** — fail closed and surface it.

`관측 요지` (field 12) exists because a positional elision cannot promise that the verdict-bearing numbers survive truncation. It is one line: the measured value(s) that decide the verdict, plus the threshold they are measured against. It is not new authoring — the writer is already obliged to produce that same one-line distillation elsewhere; at a pre-plan failure branch the sidecar is simply its only home.

### 2.6 Write forms and their diff gates

Three byte-enumerated forms, partitioned by owner.

| Form | Owner | Constraint on `diff -U0` against the pre-write snapshot |
| --- | --- | --- |
| **append** — add one new `## 회차 <N>` block | writer | **0 removed lines, always**; exactly one new `## 회차` heading |
| **route** — rewrite the one `사용자 라우팅` line of the block just appended | writer | exactly one removed line: that `사용자 라우팅` line |
| **close** — flip `상태` and insert one `처리 기록` line | reader | removed lines confined to `상태` lines of the blocks being closed; added lines are those plus at most one `처리 기록` per closed block; **every block outside that set unchanged** |

- The **route** form is bounded to the same invocation that appended the block, and is a no-op once that block is no longer `대기`.
- The writer **never** writes `상태`, on any branch, and never touches a block it did not append in this invocation.
- `sed -i ''` is forbidden — it is on this repo's bash-portability denylist, so this is lint-enforced rather than stylistic. Build the whole file and `mv` it (§1.3).

### 2.7 Reader predicates

- `unprocessed(sidecar)` — holds iff at least one block has `상태: 대기`.
- `surfaceable(block)` — a **further** filter on `사용자 라우팅`, applied only to un-processed blocks. It exists so that a block can be un-processed and still never be shown to the user.

The two are not interchangeable, and the distinction matters: `surfaceable` decides *whether to ask*; the closing rule (§2.6 **close**, driven by the owning SKILL.md's routing policy) decides *whether it comes back*. Attributing repeat-prompt prevention to the filter is a misreading — a block that is filtered but never closed returns forever.

### 2.8 Read-time derivation of the design document's state

**A sidecar never asserts the current state of the design document.** The reader determines it directly, with two greps over the targeted `### R<n>` range (from `^### R<n>\.` to the next `^### ` or `^## `):

1. **Is the item flipped?** Match the verification contract's detection grammar with the key `검증 등급` and the value pinned to the terminal-token set. A hit means the document carries the flip; no hit means it is still at the save-time residual token.
2. **How many note lines?** Count lines matching the same grammar with the key `구현 시 검증 기록`. `0` means nothing to remove; `1` is the normal flipped state; **`≥2` is a compounded duplicate**, which no other check in the system detects.
3. **Empty range** (no such heading at all) means the item was migrated or removed by an earlier re-convergence — route to the already-resolved disposition, not to the reset path.

Grep 2 is therefore both the state derivation and the duplicate-note detector: one mechanism, two jobs.

### 2.9 Read-time grouping

Group blocks by `대상 항목` **alone**. Take the charter from the **newest** block in the group, and inject **every** block in the group as evidence strength. Keying on the item alone is what keeps a history like *drift first, refutation later* as one group with one owner — grouping on the item *and* the verdict would split it into two, and the second group would have no knowledge of the first.

**Do not rewrite a block's `대상 항목` anchor** after the underlying item is migrated or renumbered. The anchor is a historical reference, and the frozen-tail invariant covers it; anchor-repair duties apply to the design document, never to the sidecar.

### 2.10 The field-warrant test

> **A sidecar field is warranted iff the fact it carries cannot be recovered from disk at read time.**

Tree state at observation time is unrecoverable — the tree keeps changing — so it is a field. The design document's state is one grep away, so it is **not** a field. The observation payload, the substitution map, and the recipe as actually run are unrecoverable, so they are fields. Apply the test to any newly proposed field rather than re-litigating a rejected one: a stored snapshot of another mutating file is the shape this test exists to exclude.
