# 변이 코퍼스 매니페스트 — 드리프트 린트

**조항·읽기 규칙·스키마 검사는 여기 없다.** 그것들은 코퍼스 불변이므로
`tests/mutation-harness/`가 갖는다. 이 파일은 이 코퍼스에만 해당하는 것 —
공시, 측정, 행 목록 — 만 갖고 조항을 다시 쓰지 않는다. 다시 쓰는 순간
그 사본이 원본과 조용히 갈라지고, 그것이 그 거처가 존재하는 이유다.

- **변이 대상**: `scripts/lint-active-notify-drift.sh`
- **픽스처 집합**: `tests/fixtures/lint-active-notify-drift` (40개 행이 이 집합에 대해 선언된다)
- **하네스**: `scripts/test-lint-active-notify-drift-mutations.sh`
- **사전 측정 블록**: `PRE-MEASUREMENT` (픽스처 집합의 **내용** 해시. 리비전이 아니다 — 리비전 비교는 그것이 무효화할 바로 그 더러운 트리에서 통과한다)

## 공시 — 이 코퍼스가 잡지 않는 것

**양쪽 퇴화 끝은 잡히지 않는다.** 전부를 붉히거나 아무것도 붉히지 않으면서
정직하게 선언하는 유효한 변이체는 어떤 비교로도 기형 변이체와 구별되지 않는다.
대역 안에 적색 비율 임계값을 두는 안은 실측에서 분리 불가로 기각됐고(사고로 만든
기형 변이체가 15중 4, 정당한 사전 등록 행이 35중 10 — 1.9포인트 차이),
끝에 두는 안은 측정된 두 사례를 둘 다 놓친다. **공시가 처분이다.**

**행이 통과한다는 것은 그 픽스처가 그 성질을 고정한다는 뜻이고, 그 이상이 아니다.**
어떤 성질이 어느 행에도 없다는 것은 「고정되지 않았다」가 아니라 「아무도 그것을
행으로 적지 않았다」이다.

## 측정 (2026-08-17, 이 커밋의 트리에서)

`test-lint-active-notify-drift-mutations.sh --self-check` → **42 passed, 0 failed**
(행 40 + 자기 점검 통제군 2), 추적 린트 sha256 `7004b7be0017` 전후 동일.
**픽스처 39개 중 24개가 적어도 한 행의 단독 사살자다.**

그 24라는 수는 **퇴화 행과 전 픽스처 적색 행을 제외하고** 센 것이다. 둘 중 어느
것도 픽스처를 다른 픽스처와 가르지 못하므로, 세면 판별력을 광고하는 수치가 아무
픽스처도 핀을 얻지 않은 채 좋아진다.

## 행 목록

| 행 | 이 행이 되돌리는 성질 | 기대 적색 집합 |
| --- | --- | --- |
| `M01-banned-korean-alternation-dropped` | BANNED_RE loses its Korean `매 턴` alternation | FAIL-16-banned-korean |
| `M02-banned-marida-alternation-dropped` | BANNED_RE loses its `턴마다` alternation | FAIL-22-banned-korean-marida |
| `M03-banned-english-alternation-dropped` | BANNED_RE loses its `per/every/each turn` alternation | FAIL-15-banned-capitalized, FAIL-8-banned-restated, FAIL-9-banned-wrapped |
| `M04-banned-case-sensitive-again` | BANNED_RE folded back to lowercase-only classes | FAIL-15-banned-capitalized |
| `M05-banned-negation-exception-removed` | the banned family loses its negation exception | OK-7-banned-negated-korean |
| `M06-negator-leading-boundary-dropped` | NEGATION_RE_BEFORE loses its leading word boundary | FAIL-23-negator-substring-decoy |
| `M07-negator-trailing-hyphen-restored` | the trailing negator boundary admits a hyphen again | FAIL-18-no-op-decoy |
| `M08-negator-korean-half-dropped` | NEGATION_RE_BEFORE loses its Korean negative endings | OK-10-korean-negation-in-window, OK-11-korean-conditional-denied, OK-5-korean-negation, OK-7-banned-negated-korean |
| `M09-trailing-negation-korean-only` | NEGATION_RE_AFTER goes back to the Korean-only literal | OK-6-post-negation-english |
| `M10-trailing-window-collapsed-to-48` | the trailing window narrows to the leading width | OK-10-korean-negation-in-window |
| `M11-trailing-window-unwindowed` | the trailing window stops being a window | FAIL-17-korean-negation-out-of-window |
| `M12-leading-window-unwindowed` | the leading window stops being a window | FAIL-28-leading-window-within-one-clause |
| `M13-negation-window-locale-unpinned` | phrase_is_negated stops pinning the window to bytes | FAIL-17-korean-negation-out-of-window |
| `M14-conditional-case-fold-removed` | the conditional rule stops folding case | FAIL-19-conditional-capitalized |
| `M15-required-phrase-line-wise` | the required phrase goes back to a line-wise literal grep | OK-9-required-phrase-rewrapped |
| `M16-required-phrase-whitespace-intolerant` | the required phrase stops tolerating a hyphen split | OK-9-required-phrase-rewrapped |
| `M17-required-phrase-case-sensitive` | the required phrase stops tolerating a sentence-cased spelling | OK-9-required-phrase-rewrapped |
| `M18-anchor-min-len-1` | a one-character title anchor becomes usable | FAIL-11-degenerate-anchor |
| `M19-anchor-sentence-cut-removed` | the anchor stops being cut at a sentence break | OK-1, OK-11-korean-conditional-denied, OK-2 |
| `M20-anchor-punctuation-cut-removed` | the anchor stops being cut at comma, em dash, backtick or pipe | OK-8-citation-unbounded |
| `M21-anchor-trailing-punctuation-kept` | the anchor keeps its trailing punctuation | OK-8-citation-unbounded |
| `M22-anchor-match-case-sensitive` | the title match stops folding case | OK-3-anchor-case |
| `M23-citation-grep-unbounded` | the citation extractor stops bounding at `)` and `;` | OK-1, OK-10-korean-negation-in-window, OK-11-korean-conditional-denied, OK-2, OK-3-anchor-case, OK-4-negation-wrapped, OK-5-korean-negation, OK-6-post-negation-english, OK-7-banned-negated-korean, OK-8-citation-unbounded, OK-9-required-phrase-rewrapped |
| `M24-citations-not-flattened` | normalize_citations stops flattening newlines | OK-1, OK-10-korean-negation-in-window, OK-11-korean-conditional-denied, OK-6-post-negation-english, OK-7-banned-negated-korean, OK-8-citation-unbounded, OK-9-required-phrase-rewrapped |
| `M25-fold-reversed-word-order-dropped` | the reversed word-order fold is dropped | FAIL-6-unmapped-shared, FAIL-7-notation-variant |
| `M26-fold-connective-dropped` | the connective fold is dropped | FAIL-20-connective-notation |
| `M27-fold-section-no-marker-dropped` | the §-less `section N` fold is dropped | FAIL-21-section-no-marker |
| `M28-sweep-reads-raw-file` | the rule-4 sweep reads the raw file instead of the same recognizer | FAIL-6-unmapped-shared |
| `M29-sweep-removed` | the rule-4 sweep is removed | FAIL-6-unmapped-shared |
| `M30-heading-extractor-narrowed` | the heading extractor stops seeing h4 headings | OK-1, OK-11-korean-conditional-denied |
| `M31-blocks-joined-without-space` | blocks_of joins wrapped lines with no separator | FAIL-9-banned-wrapped |
| `M32-frontmatter-surface-dropped` | the always-loaded frontmatter stops being scanned | FAIL-16-banned-korean, FAIL-8-banned-restated |
| `M33-shared-file-missing-silent` | a declared-but-absent shared file stops being a violation | FAIL-12-shared-file-missing |
| `M34-owner-missing-silent` | a declared-but-absent owner stops being a violation | FAIL-25-owner-file-missing |
| `M35-empty-collection-outranks-violations` | exit 2 is decided before violations are reported | FAIL-12-shared-file-missing, FAIL-25-owner-file-missing |
| `M36-citation-number-not-checked` | a citation naming no heading stops being a violation | FAIL-24-citation-names-no-heading |
| `M37-conditional-family-korean-half-dropped` | the conditional family loses its Korean half | FAIL-26-korean-conditional-asserted |
| `M38-conditional-family-back-to-single-glob` | the family iteration falls back to the single English literal | FAIL-26-korean-conditional-asserted |
| `M39-clause-intersection-dropped` | the clause boundary is dropped, leaving the window alone | FAIL-27-neighbour-clause-negator |
| `M40-clause-sep-narrowed-to-sentence` | the clause separator narrows to sentence terminators only | FAIL-27-neighbour-clause-negator |
