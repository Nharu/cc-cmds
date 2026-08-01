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

Re-convergence can recur on the same design document, so blocks **accumulate in one file** — one file per design document, never one per cycle. Each block is `## 회차 <N>`, where `N` is `max(existing) + 1` **re-derived from the bytes just read**, never from memory. `max(existing)` is taken over the headings the fence-aware tokenizer of §2.5 recognises: a `## 회차` line inside an open fence is payload, not a heading, and never enters the maximum.

Re-derivation guarantees exactly one thing — this writer's counter is fresh with respect to *its own* read. It is not a uniqueness guarantee across concurrent writers (§1.3 owns that), and it is redone from the new bytes on every retry.

A block carries its own `상태`, so the file-level "is there work here" predicate is a disjunction over blocks (§2.7), not a file-level flag.

### 2.2 Field schema — 19 fields, fixed order

| # | Field | Required | Mutability |
| --- | --- | --- | --- |
| 1 | `상태` | always | seeded `대기` by **append**; changed by **design only**, once |
| 2 | `처리 기록` | iff `처리됨` | **design only**, inserted once |
| 3 | `사용자 라우팅` | always | **implement only**, emitted at append, never rewritten |
| 4 | `관측 일시` | always | frozen |
| 5 | `정지 지점` | always | frozen |
| 6 | `대상 항목` — `§구현 시 검증 항목 R<n> — <title>` | always | frozen |
| 7 | `검증 등급` | always | frozen |
| 8 | `분류` | always | frozen |
| 9 | `트리 위생` | always | frozen |
| 10 | `주장` | always | frozen |
| 11 | `기대 결과` | always | frozen |
| 12 | `관측 요지` | always | frozen |
| 13 | `관측 결과` — fenced when it carries a payload | always | frozen |
| 14 | `관측 절단` — value grammar in §2.4 | iff the payload was truncated | frozen |
| 15 | `실행된 레시피` — fenced when it carries a payload; the recipe **exactly as executed** | always | frozen |
| 16 | `치환 맵` — `없음` when the drift ladder's re-derivation rung did not fire | always | frozen |
| 17 | `실패 시 영향` | always | frozen |
| 18 | `완료 작업` | iff `정지 지점` is `구현 중(<phase>)` | frozen |
| 19 | `블록된 작업` | iff `정지 지점` is `구현 중(<phase>)` | frozen |

Field lines use the same CANON rendering as the verification contract (`_common/verification.md`): bold key, no leading bullet, one ASCII space after the colon. The one exception is the key line of a payload-bearing field (§2.5).

**Every document-sourced field is re-read from the design document at write time and copied verbatim** (`주장`, `기대 결과`, `실패 시 영향`, `분류`, and the `R<n>` heading text rendered into the `대상 항목` anchor form of the field table above) — with exactly one departure from verbatim, which lives in this same rule so that no reader meets the two duties apart: where the recipe as run embeds a session-local path, field 15 carries that path in the parametric form the verification contract's recipe rule already mandates, never the expanded one. Never restated from context.

The recipe is deliberately **not** in the verbatim list. Field 15 carries the form actually executed, and every difference from the document's `검증 레시피` is accounted for by field 16.

**No reconstruction, and a closed set of unavailability tokens.** Three fields admit the unavailability token `미확인` (§2.4): `관측 요지`, `관측 결과`, `실행된 레시피`. `치환 맵` admits `없음` (the rung did not fire — a positive observation) and `미확인`, the latter only when `실행된 레시피` is `미확인`, since an unobserved recipe cannot warrant the positive claim. `트리 위생` keeps its own `미확인` with the rendering of §2.4. **For every other required field there is no token: an absent value makes the block malformed**, and a malformed block is surfaced rather than consumed. One reused literal rather than a per-field one is deliberate — the reader's unavailability branch is then a single equality test, and two skills authored separately cannot drift into two token sets. A field carrying `미확인` takes the ordinary CANON rendering with no fence (§2.5). This is what makes a reader's "observation unavailable" branch reachable by contract — without it that branch is dead code, and a full-trust reader then has no defense against a fabricated observation.

**Session handles are never recorded** — no agent identifiers, scratch directories, transcript paths, nonces, generation counters, ledger fragments, or session-local `${TMPDIR}` paths. A sidecar transports findings, not handles. The concrete exposure is `실행된 레시피`: a recipe run inside a temporary worktree naturally embeds a session-local path, and a `/tmp` literal is itself a malformedness axis in the verification contract, so the field table alone does not block it.

### 2.3 Frozen-tail invariant

> **Fields 1–2 are the block's mutable region and both belong to the reader. Fields 3–19 are emitted by the writer in a single append and are frozen from that instant — never touched by any writer again, and never by the reader.**

The invariant is what makes the verbatim copies of §2.2 safe from divergence: a reader can say *everything below the mutable region was true at `관측 일시`, and nothing in it claims to be true now.*

The reader obtains `상태` and `사용자 라우팅` — the two fields the predicates of §2.7 key on — from the fence-aware tokenizer of §2.5, keyed on **field name within the block**, never on a line offset from the heading. No offset-based idiom is sound here: field 2 is conditional, so a `처리됨` block moves field 3 down by one, and this file fixes field *order* and field-line *rendering* but never fixes blank-line placement, so one blank line after the heading moves it again. Such an idiom is additionally blind to fences and would read a forged `## 회차` line out of a payload as a real block — exactly the forgery §2.5 declares inert.

### 2.4 Closed vocabularies

| Field | Values |
| --- | --- |
| `상태` | `대기` \| `처리됨` |
| `사용자 라우팅` | `설계 재수렴` \| `위험 수용하고 계속` \| `중단` \| `미응답` |
| `정지 지점` | `구현 전` \| `구현 중(<phase>)` |
| `검증 등급` | `반증됨(실패)` \| `검증불가(드리프트)` |
| `트리 위생` | the five values of the table below |
| `관측 절단` | `줄 수(<N>줄)` \| `줄 길이(<M>자)` \| `줄 수(<N>줄)·줄 길이(<M>자)` |
| unavailability token | `미확인` — admitted **only** by `관측 요지`, `관측 결과`, `실행된 레시피`, `치환 맵`, `트리 위생` |

**`상태` has exactly two values.** There is deliberately no in-progress value: with no intermediate state, a reader never has to reconcile a half-transitioned block. Atomicity itself comes from the whole-file `rename(2)` of §1.3, not from the size of this vocabulary — the two-value rule removes the **reconcilable** state, the atomic write removes the **torn** one. It admits no unavailability token for the same reason a third value is excluded. `사용자 라우팅`, `정지 지점`, `검증 등급`, `관측 일시`, `대상 항목`, and the document-sourced fields likewise admit none: for those, absence is malformedness (§2.2).

**`사용자 라우팅` values are frozen to the writer's own prompt labels.** Transport fidelity is the point; translating a value inserts precisely the layer where a byte slips. A reader that needs to disambiguate does so on **its own** option labels, never by rewriting the transported value.

`미응답` is the one exception to that freeze, because it is not a prompt label: it records the **observation that no answer was given** — a prompt dismissed, or a non-interactive run — where the writer nonetheless chose to persist the finding. It is a positive observation, not an unavailability token, which is why `사용자 라우팅` admits no `미확인`.

**`트리 위생` records what actually held at observation time, and maps 1:1 onto the tree-hygiene note the reader writes.**

| `트리 위생` value | What the reader writes |
| --- | --- |
| `워크트리 격리 확인` | `워크트리 격리 확인` — no validity note |
| `진입 시 clean · 진입 대비 무변경 확인` | `tracked-source 무변경 확인` — no validity note, and it is **true** |
| `진입 시 dirty(<N>건) · 진입 대비 무변경 확인` | validity note: (i) sidecar path + `관측 일시`, (ii) this predicate verbatim |
| `구현 중 — 진입 기준선 없음` | validity note: (i) + (ii) no entry baseline exists at this branch |
| `미확인` | validity note: (i) + (ii) unknown |

The second row is the load-bearing one: an implementation-time observation does **not** automatically weaken the tree-hygiene claim. If the entry baseline was empty and the boundary gate passed, the clean note is a true statement. The field carries that distinction, so the reader renders the note with zero judgment.

**`정지 지점` is keyed on which failure branch fired**, not on the emitter's `검증 시점` plan — the two vocabularies share two token spellings only because `implement`'s two failure branches happen to align with two of that field's partitions. The third `검증 시점` value never appears here: a `구현 후` residual executes no recipe, so it produces no verdict and reaches no failure branch, and no block is ever written for it.

### 2.5 Verbatim observation payloads

`관측 결과` and `실행된 레시피` are fenced **whenever they carry a payload**, with a bare-colon key line above the fence. When any of `관측 요지`, `관측 결과`, `실행된 레시피` carries `미확인` (§2.2) it takes the ordinary CANON rendering — `**관측 결과**: 미확인` — and there is no fence.

- **The bare-colon key line is the sole exception to §2.2's CANON rendering.** Its exact form is `**<key>**:` — bold key, one colon, nothing after it, no trailing space. It is therefore **not** matched by the verification contract's sanctioned detection idiom `^(- )?(\*\*<key>\*\*|<key>): <value>$`, whose `<value>` arm cannot be empty. A payload-bearing field is located positionally by the tokenizer — a bare-colon key line whose next line opens a fence — never by that value-bearing grammar. The same field in its `미확인` rendering *is* matched by the grammar, because it then has a value.

- **Variable-length fence**: `N = max(3, longest backtick run in the payload + 1)`, so payload backticks cannot terminate the fence early. Mandatory `text` info string.
- **Caps**: 80 lines, plus a 2000-character clamp on any single line. When either fires, declare `관측 절단` with the value grammar of §2.4, naming which cap fired and the pre-truncation size. This is *payload* truncation, a normal outcome recorded in field 14; it is unrelated to the *file* truncation check below.
- **Reduction is the recipe's job, not the model's.** The payload carries the values the recipe's own `기대 결과` is a predicate over, exactly as produced, together with the counts and inputs the recipe's own procedure names. When the raw corpus exceeds the cap, reduce it **by the recipe's own aggregation step**. An aggregation the recipe does not specify is a reconstruction, and reconstruction is forbidden. **When the recipe specifies no aggregation step**, elide the payload positionally to the cap, declare `관측 절단`, and let `관측 요지` carry the verdict-bearing numbers. Positional elision and the character clamp are the only two exceptions to the reconstruction ban, and they are narrow ones: both remove content and neither synthesises any, and the verdict survives in field 12 by construction.
- **Fence-aware tokenizing is a normative rule for every consumer of these bytes, reader and writer alike**: inside an open fence, no line is a heading or a field line. This makes block forgery from payload content inert. Every derivation in this contract runs on this tokenizer — block boundaries, field lines, `max(회차)` (§2.1), the reader predicates (§2.7), the grouping key (§2.9), **the diff gates of §2.6**, and the terminator check below.
- **File terminator.** The last line of the file is the fixed sentinel `<!-- cc-design-reconverge: end -->`, emitted by every write form. A file whose last line is not that sentinel **outside an open fence** is truncated: fail closed, surface it, and do not write to it. The sentinel is a constant, so it is byte-identical before and after every write and therefore never appears in the diff gates of §2.6. It replaces a fence-parity check, which the variable-length rule above refutes: a payload holding a fenced script — an authorised recipe shape — legitimately contributes fence-looking lines and flips parity on an intact file, and a fail-closed parity check would then reject an intact sidecar wholesale. Parity is also blind to a truncation landing between blocks. The tokenizer's own open-fence-at-EOF signal is kept as a cheap second check, never as the primary one. The truncation paths this defends against are the hand-editing §1.4 invites and a `mv` degraded to copy-then-unlink by a §1.3 violation; writer process death is not one, because `rename(2)` is the commit point.

`관측 요지` (field 12) exists because a positional elision cannot promise that the verdict-bearing numbers survive truncation. It is one line: the measured value(s) that decide the verdict, plus the threshold they are measured against. It is not new authoring — the writer is already obliged to produce that same one-line distillation elsewhere; at a pre-plan failure branch the sidecar is simply its only home.

### 2.6 Write forms and their diff gates

Two byte-enumerated forms, partitioned by owner. "Pre-write bytes" means whatever §1.3 defines it to mean at the commit point; this section cites that definition and does not restate it.

| Form | Owner | Constraint on `diff -U0` between the pre-write bytes and the bytes being written |
| --- | --- | --- |
| **append** — emit one complete new `## 회차 <N>` block: every applicable field, including `상태: 대기` and the settled `사용자 라우팅` value | writer | **0 removed lines**; exactly one new tokenizer-recognised `## 회차` heading; every added line lies **at or after** that heading and **before the terminator** |
| **close** — flip `상태` and insert one `처리 기록` line | reader | removed lines confined to `상태` lines of the blocks being closed; added lines are those plus **exactly one** `처리 기록` per closed block, each at field position 2 immediately after its block's `상태` line; **every block outside that set unchanged** |

- **append** is the writer's only write form. After that single atomic write the writer never touches any block again, including its own.
- **On creation** — the absent pre-write state of §1.3 — the append emits, in this order: the H1 of §2, the machine header of §2, one complete `## 회차 1` block, and the terminator. Nothing else. This is the only place the contract assigns emission of the file header to a writer; the table constraint above governs every later append, where the file already exists.
- **The added side is bound by position, not by count.** A count-only gate passes an edit that inserts a forged field line into an existing block's frozen tail while appending a legitimate block of its own: nothing is removed and exactly one heading is added. Position is the enforceable form of the frozen tail of §2.3, which is what §2.2's verbatim copies rest on. `at or after` is deliberate — the heading is itself an added line, so `after` alone would exclude it and make the gate unsatisfiable; `before the terminator` is equally deliberate, since a heading-only bound would admit lines appended past the terminator.
- **`처리 기록` is exactly one per closed block, not at most one.** `at most one` admits zero, and a `처리됨` block with no `처리 기록` is malformed under §2.2 — the reader's own write form would be manufacturing the state the reader must reject on its next pass.
- `sed -i ''` is forbidden — it is on this repo's bash-portability denylist, so this is lint-enforced rather than stylistic. Build the whole file and `mv` it (§1.3).

### 2.7 Reader predicates

- `unprocessed(sidecar)` — holds iff at least one block has `상태: 대기`.
- `surfaceable(block)` — a **further** filter on `사용자 라우팅`, applied only to un-processed blocks. It exists so that a block can be un-processed and still never be shown to the user.

The two are not interchangeable, and the distinction matters: `surfaceable` decides *whether to ask*; the closing rule (§2.6 **close**, driven by the owning SKILL.md's routing policy) decides *whether it comes back*. Attributing repeat-prompt prevention to the filter is a misreading — a block that is filtered but never closed returns forever.

### 2.8 Read-time derivation of the design document's state

**A sidecar never asserts the current state of the design document.** The reader determines it directly, with **two greps plus an empty-range check** over the targeted `### R<n>` range (from `^### R<n>\.` to the next `^### ` or `^## `):

1. **Is the item flipped?** Match the verification contract's detection grammar with the key `검증 등급` and the value pinned to the terminal-token set. A hit means the document carries the flip; no hit means it is still at the save-time residual token.
2. **How many note lines?** Count lines matching the same grammar with the key `구현 시 검증 기록`. `0` means nothing to remove; `1` is the normal flipped state; **`≥2` is a compounded duplicate**, which no other check in the system detects.
3. **Empty range** (no such heading at all) means the item was migrated or removed by an earlier re-convergence — route to the already-resolved disposition, not to the reset path.

Grep 1 derives the state; grep 2 counts the notes and is the only duplicate detector in the system. Both are needed because **their disagreement is itself a malformedness signal**: a grep-1 hit with a grep-2 count of `0` is precisely the verification contract's malformed R-item — a terminal token with no adjacent `구현 시 검증 기록` line. Surface it and route to neither the flipped nor the un-flipped path; do **not** read that `0` as "nothing to remove".

Field 7 `검증 등급` is not in tension with the opening sentence. It records the verdict `implement` **reached at `관측 일시`**, which may never have been written to the document — finding out is what grep 1 is for. Where the stored token and grep 1 disagree, **grep 1 wins**: the block's verdict is evidence of what was observed, never of what the document says.

### 2.9 Read-time grouping

Group blocks by `대상 항목` **verbatim** — the whole composite anchor, unparsed. Run the empty-range check of §2.8 on a group **before** taking its charter, so a migrated or renumbered item is disposed of without judgment. Then take the charter from the **newest** block in the group, and inject **every** block in the group as evidence strength. Keying on the item alone is what keeps a history like *drift first, refutation later* as one group with one owner — grouping on the item *and* the verdict would split it into two, and the second group would have no knowledge of the first.

**Do not rewrite a block's `대상 항목` anchor** after the underlying item is migrated or renumbered. The anchor is a historical reference, and the frozen-tail invariant covers it; anchor-repair duties apply to the design document, never to the sidecar.

The key is therefore **nominal and deliberately unstable**: a renumbered or retitled item produces a *new* group, and the old group's blocks are disposed of by the empty-range route above rather than being expected to follow the item. Do not derive a key by parsing `R<n>` out of the anchor: it would survive a retitling but would silently **merge** two different items' histories across a renumbering, and a merged charter taken from a block about another claim is worse than a split. The residual — an old anchor pointing at a range some other item has since taken — is accepted; the frozen anchor already accepts it, and no key derived from the anchor can detect it.

### 2.10 The field-warrant test

> **A sidecar field is warranted iff the fact it carries — as that fact held at `관측 일시` — cannot be recovered from disk at read time.**

Tree state at observation time is unrecoverable — the tree keeps changing — so it is a field. The design document's **current** state is one grep away (§2.8), so it is **not** a field. What the document said at `관측 일시` is a different fact and is not recoverable at all, which is what warrants the verbatim copies of §2.2 (`주장`, `기대 결과`, `실패 시 영향`, `분류`, the `R<n>` heading); §2.3 already fixes their semantics — true at `관측 일시`, claiming nothing about now. The observation payload, the substitution map, and the recipe **as actually run** are unrecoverable, so they are fields. The recipe's text as the document carries it is **not** a field: it is current, recoverable, and in any case determined by field 15 together with field 16. Apply the test to any newly proposed field rather than re-litigating a rejected one: **a stored snapshot of another mutating file presented as that file's current state** is the shape this test exists to exclude.
