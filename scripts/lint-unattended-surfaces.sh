#!/usr/bin/env bash
# lint-bash-portability: self-skip
# Lint the unattended pipeline skills for two absence invariants and one
# parity invariant.
#
#   Rule 1 (no human-question surface) — an unattended arm must not load or
#     call AskUserQuestion / EnterPlanMode / ExitPlanMode. Every point that
#     would have asked resolves to a halt record instead.
#   Rule 2 (no notification surface) — an unattended arm must not reach
#     PushNotification / notify.sh / terminal-notifier. Reaching a sleeping
#     user is the driver's exclusive job; a stage that works AND notifies is
#     forbidden without exception.
#   Rule 3 (forked-spine constant parity) — where an unattended arm forks a
#     base skill that pins fixed constants under `### CFI-0`, the fork's
#     fenced block must be byte-identical to the base's. A forked spine's one
#     real drift risk is a budget that quietly diverges, so it is pinned
#     rather than trusted.
#   Rule 4 (inherited question points are dispositioned) — an arm does not
#     copy its `references/`, it SHARES the base skill's tree, and the two
#     shipped question points in this repo are in exactly that tree. The arm
#     cannot delete them, because the interactive arm needs them, so what it
#     owes is a statement of what it does instead, naming the file. Checked in
#     both directions: an undispositioned question point is a surface the arm
#     claims not to have, and a disposition for a file carrying none is a
#     clause pointing at nothing.
#   Rule 5 (CFI-U0 sentence pin) — an arm that Reads its base skill's step
#     bodies at runtime instead of carrying them applies one substitution
#     sentence to every question terminus it meets there. That sentence is
#     the whole of the arm's park mechanism, so its deletion is a silent
#     regression Rules 1 and 2 cannot see: the file still contains no call
#     form, and the question points live in the base file the arm Reads. The
#     sentence is therefore pinned as a fixed literal. It is pinned HERE and
#     not in `lint-skill-invariants.sh` because that script's rule (B) is a
#     base<->lite phrase-sync over a pair and is dormant; asserting one
#     sentence's presence in one file is this script's shape, not that one's.
#   Rule 6 (the two enumerations agree) — this script's allowlist and the
#     sibling `lint-judgment-grade.sh`'s `PAIRS` are BOTH explicit lists, and
#     their membership rules differ: this one is "every skill the pipeline
#     dispatches headlessly", that one is "every attended/unattended pair".
#     An arm registered in one and not the other is not a failure anywhere —
#     it is a false all-clear from the lint that never saw it. So the
#     unattended half of every `PAIRS` entry must appear in `UNATTENDED_SKILLS`.
#     The inclusion is one-directional on purpose: an arm with no attended
#     counterpart (`autopilot-router-shift`) is rightly absent from `PAIRS`,
#     so the reverse containment does not hold and is not asserted.
#   Rule 7 (assertion-label parity, extracted) — the boundary-gate assertion
#     labels are EXTRACTED from the contract's own bullets, never retyped
#     here, and asserted in both directions: every extracted label is
#     referenced by both arms of the pair, and every label-shaped token in
#     either arm is in the extracted set. Catches a label added to the
#     contract and wired into one arm only, and a stale reference to a label
#     the contract no longer defines. Writing the label set into this file
#     would make it a third copy of the vocabulary, which is the thing the
#     rule exists to prevent.
#   Rule 8 (no assertion gloss in an arm) — an arm names an assertion and
#     never explains it. Two fences, and the first is why this is not a
#     denylist of today's wording: a SHAPE fence forbids the ACT of glossing
#     (a label immediately followed by a parenthetical or an em-dash), so a
#     gloss nobody has written yet is already covered; a literal list is the
#     cheaper second tripwire for a gloss carrying no adjacent label. The
#     rule is region-scoped to the '## Control-Flow Invariants' body, which
#     is what lets a custody sentence in a Step use the same words freely.
#
#     WHY THIS IS NOT A PARITY RULE. Parity is the wrong invariant for
#     definitional content: two arms can be IDENTICALLY wrong, and measured,
#     they were — the same three glosses sat once in each arm, so every
#     parity-shaped check passed them while all three were about to become
#     false in both arms at once. Forbidding the gloss catches that; comparing
#     the arms cannot.
#
#     WHAT IT DOES NOT CATCH, said here because the header is where this file
#     admits its own limits: a one-sided FACTUAL claim about the mechanism
#     that carries no gloss literal and no label adjacency. One was measured
#     (an arm claiming a hook reads a constant that no hook reads) and fixed
#     as an instance rather than fenced, because the device that catches a
#     false claim is checking the claim, not comparing or forbidding text.
#
# Why these are checkable here and not in general: each unattended arm lives
# in its OWN file and carries exactly one arm, so a whole-file predicate is
# an arm-level predicate. The same predicate over a two-arm file proves
# nothing about either arm, which is why the arms were split into files in
# the first place.
#
# Rule 4 exists because Rules 1 and 2 could not reach those two points twice
# over, and repairing either layer alone leaves them still passing. The scan
# set opened one file per arm — `<skill>/SKILL.md` — and the shared tree is
# not under the arm's directory at all. The pattern then required an opening
# parenthesis, while both occurrences are a backticked bare name inside a
# sentence. A contract that asserts an absence, measured by a device that
# cannot reach the place the absence is claimed about, is green forever.
#
# What Rules 1 and 2 do NOT prove: that the model never asks. A model can ask
# in prose and answer itself, and no text or tool roster removes that. These
# rules prove the file contains no instruction to ask and no reachable
# notification call — a necessary condition, not a sufficient one.
#
# Patterns anchor on CALL FORM, not on a bare token mention. Every one of
# these files legitimately discusses the tools it must not use ("AskUserQuestion
# is deliberately NOT loaded"), so a token-level denylist would flag exactly
# the sentences that document the invariant.
#
# Rule 4 is the deliberate asymmetry: inside a reference tree the pattern
# matches the BARE NAME. That is sound exactly where the call-form rule is not,
# because a reference file carries instructions and no meta-discussion of this
# invariant — nothing there is documenting what must not be reached. It is also
# necessary, since a question point written as prose ("surface it with at most
# one `AskUserQuestion`") is a real routing instruction wearing no parenthesis.
#
# Usage:
#   bash scripts/lint-unattended-surfaces.sh
#
# Env override:
#   SKILLS_ROOT=<dir> bash scripts/lint-unattended-surfaces.sh   # fixture test
#
# Posture: a skill absent from disk is a silent skip, so this script stays
# green during an incremental rollout and activates as each arm lands.
#
# Exit codes:
#   0 — all present targets pass
#   1 — at least one violation
#
# Compatibility: bash 3.2 (macOS) — no associative arrays, no `mapfile`.

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
skills_root="${SKILLS_ROOT:-$repo_root/plugins/cc-cmds/skills}"

# Explicit allowlist. Deliberately NOT a `*-unattended` glob: the scan set is
# the set of skills the pipeline dispatches headlessly — as a stage from the
# driver, or as a shard from the gate — and `design-reconverge` is one of those
# without carrying the suffix. A glob would also silently drop a renamed arm
# instead of failing.
#
# Membership was taken against the tree rather than by suffix, and the census
# is written here so the next arm is checked the same way: the driver's stage
# dispatch names `implement-unattended`, `review-unattended`,
# `design-audit-unattended`, `design-reconverge` and `design-discuss-unattended`;
# the gate's `act --kind router-shift` launches `autopilot-router-shift` as a
# headless shard. That last one carries no `-unattended` suffix and has no
# attended counterpart, which is exactly the shape a suffix rule or the sibling
# lint's pair table would miss — it was absent from this list when the census
# was first taken.
UNATTENDED_SKILLS=(
  "implement-unattended"
  "design-audit-unattended"
  "review-unattended"
  "design-reconverge"
  "design-discuss-unattended"
  "autopilot-router-shift"
)

# Fork parity pairs: "<fork>|<base>". Only pairs whose base pins constants
# under `### CFI-0` need an entry; a base with no such block is not a pair.
PARITY_PAIRS=(
  "design-audit-unattended|design-audit"
)

# Rule 1 — human-question call forms.
QUESTION_RE='ToolSearch\("select:[^"]*AskUserQuestion|AskUserQuestion\(|EnterPlanMode\(|ExitPlanMode\('

# Rule 2 — notification call forms. Byte-identical to the predicate the
# design's residual verification item fixed, and for its stated reasons:
# `grep -q` inside an `if` so the 0-hit case does not trip `set -e`, and
# call-form anchoring so a prose mention in a README sentence is not a hit.
NOTIFY_RE='PushNotification\(|notify\.sh[[:space:]]+(arm|fire-now|cancel)|terminal-notifier[[:space:]]+-'

# Rule 4 — "<arm>|<skill whose references/ tree the arm reads>". Explicit for
# the same reason the skill list is: the sharing is stated in prose inside each
# arm and nothing derives it, so a glob would silently drop a renamed arm
# instead of failing. An arm that shares nobody's tree names itself.
REFERENCE_TREES=(
  "implement-unattended|implement"
  "design-audit-unattended|design-audit"
  "review-unattended|review"
  "design-reconverge|design-reconverge"
  # The discuss leg Reads `design/SKILL.md`'s own step bodies, not a
  # references/ tree; `design/references/` does not exist today, so this entry
  # is a SKIP until one appears, and Rule 5 below is what covers the leg.
  "design-discuss-unattended|design"
  # The router shard shares nobody's tree and has none of its own.
  "autopilot-router-shift|autopilot-router-shift"
)

# Rule 6 — the sibling lint whose `PAIRS` line is read back. The line is parsed
# rather than duplicated here so the two lists cannot drift apart silently.
SIBLING_PAIRS_LINT="$script_dir/lint-judgment-grade.sh"

# Rule 4 — the question-surface pattern used INSIDE a reference tree. Bare name,
# no call form required; see the asymmetry note in the header.
REF_QUESTION_RE='AskUserQuestion|EnterPlanMode|ExitPlanMode'

# The clause an arm owes for each shared reference file that holds a question
# point. Fixed prefix plus the file's own name in backticks, so the check is a
# byte comparison rather than a guess at how the disposition was worded.
DISPOSITION_PREFIX='**Inherited question point** — '

# Rule 5 — the substitution sentence, byte-exact, and the arms that owe it. An
# arm on this list that is present on disk must carry the sentence on at least
# one line; an absent arm is the same silent skip as everywhere else here.
U0_PIN='this arm resolves that terminus to `park`'
U0_PINNED_SKILLS=(
  "design-discuss-unattended"
)

fail=0
checked=0
skipped=0
refs_checked=0
gloss_checked=0
label_count=0

for skill in "${UNATTENDED_SKILLS[@]}"; do
  file="$skills_root/$skill/SKILL.md"
  if [[ ! -f "$file" ]]; then
    echo "SKIP: $skill — not present"
    skipped=$((skipped + 1))
    continue
  fi
  checked=$((checked + 1))

  if grep -qE "$QUESTION_RE" "$file"; then
    echo "FAIL: $skill — reaches a human-question surface" >&2
    grep -nE "$QUESTION_RE" "$file" >&2
    fail=1
  fi

  if grep -qE "$NOTIFY_RE" "$file"; then
    echo "FAIL: $skill — reaches a notification surface" >&2
    grep -nE "$NOTIFY_RE" "$file" >&2
    fail=1
  fi

  if [[ "$fail" -eq 0 ]]; then
    echo "OK:   $skill — no question surface, no notification surface"
  fi
done

# Extract the fenced block that immediately follows the `### CFI-0` heading.
# Fence-delimited by the first ``` after the heading through the next ```.
extract_cfi0_block() {
  awk '
    /^### CFI-0/ { seen=1; next }
    seen && /^```/ { if (infence) { exit } ; infence=1; next }
    seen && infence { print }
  ' "$1"
}

for pair in ${PARITY_PAIRS[@]+"${PARITY_PAIRS[@]}"}; do
  fork="${pair%%|*}"
  base="${pair##*|}"
  fork_file="$skills_root/$fork/SKILL.md"
  base_file="$skills_root/$base/SKILL.md"

  if [[ ! -f "$fork_file" || ! -f "$base_file" ]]; then
    echo "SKIP: $fork <- $base — parity pair incomplete on disk"
    continue
  fi

  fork_block=$(extract_cfi0_block "$fork_file")
  base_block=$(extract_cfi0_block "$base_file")

  if [[ -z "$base_block" ]]; then
    echo "FAIL: $base — no fenced block under '### CFI-0'; the parity pair names a base that no longer pins constants" >&2
    fail=1
    continue
  fi

  if [[ "$fork_block" != "$base_block" ]]; then
    echo "FAIL: $fork — CFI-0 constants diverge from $base" >&2
    echo "--- $base" >&2
    printf '%s\n' "$base_block" >&2
    echo "--- $fork" >&2
    printf '%s\n' "$fork_block" >&2
    fail=1
  else
    echo "OK:   $fork — CFI-0 constants byte-identical to $base"
  fi
done

for pair in ${REFERENCE_TREES[@]+"${REFERENCE_TREES[@]}"}; do
  arm="${pair%%|*}"
  base="${pair##*|}"
  arm_file="$skills_root/$arm/SKILL.md"
  ref_dir="$skills_root/$base/references"

  [[ -f "$arm_file" ]] || continue
  if [[ ! -d "$ref_dir" ]]; then
    echo "SKIP: $arm — $base/references/ not present"
    continue
  fi
  refs_checked=$((refs_checked + 1))

  # Both sides collected whole, as basenames, and neither written down here.
  # `LC_ALL=C` on the sort is load-bearing wherever `-u` is used as a set
  # operation: `-u` drops "duplicates" by collation, and a locale with no
  # ordering for a script compares every element equal to every other.
  hit_files=$(LC_ALL=C grep -rlE "$REF_QUESTION_RE" "$ref_dir" 2>/dev/null \
    | sed 's|.*/||' | LC_ALL=C sort -u || true)
  disp_files=$(LC_ALL=C grep -F -- "$DISPOSITION_PREFIX" "$arm_file" 2>/dev/null \
    | sed -n 's/.*\*\*Inherited question point\*\* — `\([^`]*\)`.*/\1/p' \
    | LC_ALL=C sort -u || true)

  while IFS= read -r bn; do
    [[ -n "$bn" ]] || continue
    # CAPTURED, NOT `grep -qxF`. An early-exiting reader on the right of a pipe
    # kills the writer with SIGPIPE, and under `pipefail` the pipeline then
    # reports failure even though the match was found.
    hit=$(printf '%s\n' "$disp_files" | grep -xF -- "$bn" || true)
    if [[ -z "$hit" ]]; then
      echo "FAIL: $arm — $base/references/$bn 가 질문 지점을 갖는데 이 갈래가 그 처분을 적지 않았다" >&2
      echo "       공유하는 트리라 지울 수 없다 — 대신 무엇을 하는지를 파일 이름과 함께 적어야 한다" >&2
      LC_ALL=C grep -nE "$REF_QUESTION_RE" "$ref_dir/$bn" >&2 || true
      fail=1
    fi
  done <<EOF
$hit_files
EOF

  while IFS= read -r bn; do
    [[ -n "$bn" ]] || continue
    hit=$(printf '%s\n' "$hit_files" | grep -xF -- "$bn" || true)
    if [[ -z "$hit" ]]; then
      echo "FAIL: $arm — $base/references/$bn 의 처분을 적었는데 그 파일에는 질문 지점이 없다" >&2
      echo "       가리키는 것이 없는 절은 다음 독자에게 아직 상속받는 중이라고 읽힌다" >&2
      fail=1
    fi
  done <<EOF
$disp_files
EOF
done

pins_checked=0
for skill in ${U0_PINNED_SKILLS[@]+"${U0_PINNED_SKILLS[@]}"}; do
  file="$skills_root/$skill/SKILL.md"
  [[ -f "$file" ]] || continue
  pins_checked=$((pins_checked + 1))
  # CAPTURED, NOT `grep -qF` — same SIGPIPE-under-pipefail reasoning as Rule 4.
  n_pin=$(grep -cF -- "$U0_PIN" "$file" || true)
  if [[ "${n_pin:-0}" = "0" ]]; then
    echo "FAIL: $skill — CFI-U0 치환 문장이 없다: $U0_PIN" >&2
    echo "       이 팔은 base 의 스텝 본문을 Read 해 따르므로 이 한 문장이 park 기전의 전부다" >&2
    fail=1
  else
    echo "OK:   $skill — CFI-U0 substitution sentence present"
  fi
done

# Rule 6 — every unattended half of the sibling lint's `PAIRS` is in this
# allowlist. Read from the sibling's source line, not re-typed: the whole point
# is that the two enumerations are maintained in two files by two rules, and a
# copy here would be a third.
pairs_checked=0
if [[ -f "$SIBLING_PAIRS_LINT" ]]; then
  sibling_pairs=$(sed -n 's/^PAIRS="\(.*\)"$/\1/p' "$SIBLING_PAIRS_LINT" | sed -n '1p')
  if [[ -z "$sibling_pairs" ]]; then
    echo "FAIL: $SIBLING_PAIRS_LINT — PAIRS=\"…\" 줄을 찾지 못했다 — 두 열거의 교차 검사가 읽을 것이 없다" >&2
    fail=1
  fi
  for pair in $sibling_pairs; do
    una="${pair##*|}"
    pairs_checked=$((pairs_checked + 1))
    found=0
    for skill in "${UNATTENDED_SKILLS[@]}"; do
      [[ "$skill" == "$una" ]] && { found=1; break; }
    done
    if [[ "$found" -eq 0 ]]; then
      echo "FAIL: $una — lint-judgment-grade.sh 의 PAIRS 에는 있는데 이 파일의 UNATTENDED_SKILLS 에는 없다" >&2
      echo "       한쪽에만 등록된 팔은 실패가 아니라 거짓 all-clear 로 나타난다 — 두 열거에 함께 더해야 한다" >&2
      fail=1
    fi
  done
else
  echo "SKIP: Rule 6 — $SIBLING_PAIRS_LINT 가 없다"
fi

# --- Rules 7 and 8 — the assertion labels and the absence of their glosses ----
#
# THE LABEL SET IS EXTRACTED, NEVER RETYPED. It comes from the contract's own
# one-bullet-per-assertion shape, which is why that shape is load-bearing and
# not cosmetic: converting the three bullets to a paragraph, a table or a
# blockquote removes the extraction source and this rule degrades to a hand
# list — the third copy the header says it exists to prevent.
CONTRACT="$skills_root/_common/verification.md"

extract_assertion_labels() {
  # The bullets live between '## 6.' and the first '### 6.' subsection.
  awk '/^### 6\./ { exit } /^## 6\./ { c = 1 } c' "$1" \
    | sed -n 's/^- \*\*\(2[a-z]\) — [^.]*\.\*\*.*/\1/p'
}

cfi_body() {
  # The '## Control-Flow Invariants' body, up to the next '## ' heading.
  awk '
    /^## Control-Flow Invariants[[:space:]]*$/ { inb = 1; next }
    inb && /^## / { exit }
    inb { print }
  ' "$1"
}

# Rule 8's literal tripwire. These are glosses, not vocabulary: each one is a
# thing the CONTRACT may say and an ARM may not, which is the partition the
# three-slot rule draws. `own entry` is deliberately here even though it is a
# live short name in the contract — the domain of this list is the arm.
GLOSS_LITERALS=(
  'path set'
  'own entry'
  'count is 0'
  'exception pattern'
  'creation record'
  'owner token'
  'tree sha'
  'HEAD^{tree}'
)

if [[ ! -f "$CONTRACT" ]]; then
  echo "SKIP: assertion labels — $CONTRACT not present" >&2
else
  labels=$(extract_assertion_labels "$CONTRACT")

  if [[ -z "$labels" ]]; then
    echo "FAIL: _common/verification.md — no assertion bullets matched '- **2x — <short name>.**' under '## 6.'" >&2
    echo "       Rule 7 extracts its label set from that shape; without it the set would have to be retyped here" >&2
    fail=1
  else
    for pair in ${PARITY_PAIRS[@]+"${PARITY_PAIRS[@]}"}; do
      fork="${pair%%|*}"
      base="${pair##*|}"

      for arm in "$fork" "$base"; do
        arm_skill="$skills_root/$arm/SKILL.md"
        [[ -f "$arm_skill" ]] || continue
        body=$(cfi_body "$arm_skill")

        if [[ -z "$body" ]]; then
          echo "FAIL: $arm — no '## Control-Flow Invariants' body; Rules 7 and 8 are region-scoped to it" >&2
          fail=1
          continue
        fi

        # Rule 7, forward: every extracted label is referenced by this arm.
        #
        # The containment tests here and below are bash string matches rather
        # than pipes into `grep -q`. An early-exiting reader on the right of a
        # pipe leaves the writer on the left with a SIGPIPE, and under
        # `set -o pipefail` that failure becomes the pipeline's status — so the
        # `if !` would invert on a MATCH, which is the direction that reads as
        # green. `$body` is multiline, and the `[^0-9A-Za-z]` classes carry the
        # newlines: a label at the start of a line is preceded by one and a
        # label at the end of a line is followed by one, so the anchors only
        # have to cover the ends of the whole string.
        missing=""
        while IFS= read -r label; do
          [[ -n "$label" ]] || continue
          label_re="(^|[^0-9A-Za-z])${label}([^0-9A-Za-z]|\$)"
          if ! [[ $body =~ $label_re ]]; then
            missing="$missing $label"
          fi
        done <<EOF
$labels
EOF
        if [[ -n "$missing" ]]; then
          echo "FAIL: $arm — the contract defines assertion(s)${missing} that this arm never references" >&2
          echo "       a label wired into one arm only is the divergence this rule exists to catch" >&2
          fail=1
        fi

        # Rule 7, reverse: every label-shaped token in this arm is defined.
        # The label set is newline-delimited on both sides of the comparison so
        # the match is whole-line, the way `grep -x` was: `2a` must not be found
        # inside a longer label.
        labels_nl=$'\n'"$labels"$'\n'
        stale=$(printf '%s\n' "$body" | grep -oE '(^|[^0-9A-Za-z])2[a-z]([^0-9A-Za-z]|$)' \
                  | grep -oE '2[a-z]' | sort -u | while IFS= read -r tok; do
                    [[ $labels_nl == *$'\n'"$tok"$'\n'* ]] || printf '%s ' "$tok"
                  done)
        if [[ -n "$stale" ]]; then
          echo "FAIL: $arm — references assertion label(s) the contract does not define: $stale" >&2
          fail=1
        fi

        # Rule 8, shape fence: a label immediately followed by a gloss.
        shaped=$(printf '%s\n' "$body" | grep -nE '2[a-z][[:space:]]*(\(|—)' || true)
        if [[ -n "$shaped" ]]; then
          echo "FAIL: $arm — assertion label followed by a gloss inside the invariants body" >&2
          printf '%s\n' "$shaped" | sed 's/^/       /' >&2
          echo "       an arm names an assertion and never explains it — the definition lives in the contract" >&2
          fail=1
        fi

        # Rule 8, literal tripwire: a gloss carrying no adjacent label.
        for lit in "${GLOSS_LITERALS[@]}"; do
          hits=$(printf '%s\n' "$body" | grep -nF -- "$lit" || true)
          if [[ -n "$hits" ]]; then
            echo "FAIL: $arm — gloss literal '$lit' inside the invariants body" >&2
            printf '%s\n' "$hits" | sed 's/^/       /' >&2
            fail=1
          fi
        done

        gloss_checked=$((gloss_checked + 1))
      done
    done

    label_count=$(printf '%s\n' "$labels" | grep -c . || true)
  fi
fi

if [[ "$fail" -ne 0 ]]; then
  echo "lint-unattended-surfaces: violations found" >&2
  exit 1
fi

echo "lint-unattended-surfaces: ${checked} skill(s) checked, ${skipped} absent, ${refs_checked} shared reference tree(s) checked, ${pins_checked} CFI-U0 pin(s) checked, ${pairs_checked} sibling pair(s) cross-checked, ${gloss_checked:-0} arm(s) checked against ${label_count:-0} extracted assertion label(s)"
exit 0
