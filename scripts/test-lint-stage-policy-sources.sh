#!/usr/bin/env bash
# Test the two halves of the stage-policy drift contract against
# tests/fixtures/lint-stage-policy-sources/.
#
# Repository half — `scripts/lint-stage-policy-sources.sh`. Each fixture is a
# POLICY_ROOT-shaped directory (a `stage-policy.md` beside a
# `stage-policy.sources.tsv`); the directory name encodes the expected exit.
#   T-POLICY-OK-*   → expected exit 0
#   T-POLICY-FAIL-* → expected exit 1
# Every FAIL fixture is the OK pair with exactly one defect: a non-ASCII line,
# a volatile token, an oversize policy, a pin sentence absent or doubled, a
# policy heading no row names, a `policy:` row naming a heading that does not
# exist, a disposition outside the closed vocabulary, a duplicated user-scope
# anchor, a four-column row, a memory row carrying a hash.
#
# Source half — `plugins/cc-cmds/orchestrator/stage-policy-drift.sh`. Each
# case under `drift/` carries the manifest and the fake sources it is compared
# with. The checker's contract says the manifest sits NEXT TO the script and
# the user-scope source is `${CLAUDE_CONFIG_DIR}/CLAUDE.md`, so the test copies
# the checker into a scratch directory beside the case's manifest and points
# `CLAUDE_CONFIG_DIR` at a `cfg/` it builds there. The workspace source is
# reached only through a host map, which must hold an ABSOLUTE path; the map is
# therefore written at run time into the scratch directory, naming the staged
# workspace file when the case has one. A case carrying `map.malformed` gets
# that file as its map instead. A case with neither gets a map path that does
# not exist. The person's real global files are never read.
#
# THE FIXTURE SOURCES ARE STORED AS `source.md` AND STAGED UNDER THE NAME THE
# CHECKER LOOKS FOR. They used to be stored as `cfg/CLAUDE.md` and `ws/CLAUDE.md`
# and read in place, and this repository's own `.gitignore` carries a bare-name
# `CLAUDE.md` line — so all thirteen of them were silently left out of the
# commit while staying on the author's disk. Ten of the twelve cases then passed
# locally and failed on a clean checkout, and the committed manifests collapsed
# to four distinct blobs because every byte that told the cases apart lived in
# the ignored files. Storing them under a name no ignore rule matches is what
# makes the committed tree self-sufficient; copying them into the scratch
# directory as `CLAUDE.md` is what keeps the checker's real filename resolution
# under test.
#
# Expected per case: the exit code, the verdict on the last line, and — where
# a finding is the point — the finding line itself, asserted verbatim.

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
fixtures="$repo_root/tests/fixtures/lint-stage-policy-sources"
checker="$repo_root/plugins/cc-cmds/orchestrator/stage-policy-drift.sh"

failures=0
passed=0

# ---------- repository half --------------------------------------------------

for fixture in "$fixtures"/T-POLICY-*/; do
  fixture_name=$(basename "$fixture")
  case "$fixture_name" in
    T-POLICY-OK-*)   want=0 ;;
    T-POLICY-FAIL-*) want=1 ;;
    *)
      echo "test-lint-stage-policy-sources: fixture '$fixture_name' has unrecognized prefix" >&2
      failures=$((failures + 1))
      continue
      ;;
  esac

  set +e
  POLICY_ROOT="$fixture" bash "$script_dir/lint-stage-policy-sources.sh" >/dev/null 2>&1
  ec=$?
  set -e

  if [[ "$ec" == "$want" ]]; then
    passed=$((passed + 1))
    echo "PASS: $fixture_name (exit=$ec, expected=$want)"
  else
    failures=$((failures + 1))
    echo "FAIL: $fixture_name (exit=$ec, expected=$want)" >&2
  fi
done

# ---------- source half ------------------------------------------------------

# run_drift <case> — runs the checker for one case; sets DRIFT_OUT and DRIFT_EC.
run_drift() {
  local case_dir="$fixtures/drift/$1" scratch map
  scratch=$(mktemp -d "${TMPDIR:-/tmp}/cc-policy-drift.XXXXXX")
  cp "$checker" "$scratch/stage-policy-drift.sh"
  cp "$case_dir/stage-policy.sources.tsv" "$scratch/stage-policy.sources.tsv"
  # `cfg/` is created even when the case has no user-scope source, so that the
  # "source file not found" branch is reached through a real config directory
  # rather than through a missing one — the checker tests the file, not the
  # directory, and the case that has no source is asserting exactly that.
  mkdir -p "$scratch/cfg"
  if [[ -f "$case_dir/cfg/source.md" ]]; then
    cp "$case_dir/cfg/source.md" "$scratch/cfg/CLAUDE.md"
  fi
  if [[ -f "$case_dir/map.malformed" ]]; then
    map="$case_dir/map.malformed"
  elif [[ -f "$case_dir/ws/source.md" ]]; then
    mkdir -p "$scratch/ws"
    cp "$case_dir/ws/source.md" "$scratch/ws/CLAUDE.md"
    map="$scratch/map"
    printf 'workspace\t%s\n' "$scratch/ws/CLAUDE.md" > "$map"
  else
    map="$scratch/no-such-map"
  fi
  # a store that does not exist, so the host's own acknowledgements are never read
  set +e
  DRIFT_OUT=$(CLAUDE_CONFIG_DIR="$scratch/cfg" bash "$scratch/stage-policy-drift.sh" \
    --sources-map "$map" --ack-store "$scratch/no-such-store" 2>/dev/null)
  DRIFT_EC=$?
  set -e
  rm -rf "$scratch"
}

# expect_drift <case> <exit> <last-line> [<finding line>...]
# With no finding line given, the output must consist of the last line alone
# (plus SKIP lines, which are allowed anywhere) — that is how "memory rows
# print nothing" is asserted.
expect_drift() {
  local name="$1" want_ec="$2" want_last="$3" ok=1 last line
  shift 3
  run_drift "$name"
  last=$(printf '%s\n' "$DRIFT_OUT" | tail -n 1)
  if [[ "$DRIFT_EC" != "$want_ec" ]]; then
    echo "FAIL: drift/$name — exit=$DRIFT_EC, expected=$want_ec" >&2; ok=0
  fi
  if [[ "$last" != "$want_last" ]]; then
    echo "FAIL: drift/$name — last line '$last', expected '$want_last'" >&2; ok=0
  fi
  for line in "$@"; do
    hits=$(printf '%s\n' "$DRIFT_OUT" | grep -Fxc -- "$line" || true)
    if [[ "${hits:-0}" != "1" ]]; then
      echo "FAIL: drift/$name — expected exactly one line '$line', found ${hits:-0}" >&2; ok=0
    fi
  done
  if (( $# == 0 )); then
    stray=$(printf '%s\n' "$DRIFT_OUT" | grep -vE '^(SKIP |match$|skipped$)' || true)
    if [[ -n "$stray" ]]; then
      echo "FAIL: drift/$name — unexpected output line(s): $stray" >&2; ok=0
    fi
  fi
  if (( ok == 1 )); then
    passed=$((passed + 1)); echo "PASS: drift/$name"
  else
    failures=$((failures + 1)); echo "     output was: $DRIFT_OUT" >&2
  fi
}

expect_drift match 0 match
expect_drift added 1 'mismatch 1' 'added user-scope delta rule four'
expect_drift removed 1 'mismatch 1' 'removed user-scope gamma'
expect_drift changed 1 'mismatch 1' 'changed user-scope alpha'
expect_drift non-unique 1 'mismatch 1' 'non-unique user-scope alpha'
expect_drift skipped 0 skipped
expect_drift one-compared 0 match
expect_drift memory-silent 0 match
expect_drift workspace-changed 1 'mismatch 1' 'changed workspace ## Two'
expect_drift workspace-match 0 match
expect_drift malformed-manifest 2 ''
expect_drift malformed-map 2 ''

# `non-unique` must not be folded into `removed`, and a SKIP source must be
# named as such in the one-compared case.
run_drift non-unique
hits=$(printf '%s\n' "$DRIFT_OUT" | grep -c '^removed ' || true)
if [[ "${hits:-0}" == "0" ]]; then
  passed=$((passed + 1)); echo "PASS: drift/non-unique (not folded into removed)"
else
  failures=$((failures + 1)); echo "FAIL: drift/non-unique — a non-unique anchor was reported as removed" >&2
fi
run_drift one-compared
hits=$(printf '%s\n' "$DRIFT_OUT" | grep -c '^SKIP workspace ' || true)
if [[ "${hits:-0}" == "1" ]]; then
  passed=$((passed + 1)); echo "PASS: drift/one-compared (workspace SKIP line present)"
else
  failures=$((failures + 1)); echo "FAIL: drift/one-compared — expected one 'SKIP workspace' line, found ${hits:-0}" >&2
fi

# ---------- host acknowledgement store ---------------------------------------
#
# These cases edit the source between runs, so they are built here rather than
# stored: the manifest hashes are taken from the base source with the checker's
# own item extraction, and every run points `--ack-store` at a scratch store.
# The stage running this test inherits `CC_PIPELINE_RUN_ID`, which the checker
# refuses to acknowledge under, so every run clears it unless the case sets it.

ACK_BASE='- alpha rule one
    continued alpha
- beta rule two
- gamma rule three
'

# ack_case — a fresh scratch: the checker beside a manifest of three rows, the
# base source as the user-scope file, and a store path that does not exist yet.
ack_case() {
  ACK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/cc-policy-ack.XXXXXX")
  ACK_STORE="$ACK_DIR/store"
  cp "$checker" "$ACK_DIR/stage-policy-drift.sh"
  mkdir -p "$ACK_DIR/cfg"
  printf '%s' "$ACK_BASE" > "$ACK_DIR/cfg/CLAUDE.md"
  {
    printf 'source\tanchor\tsha256\tdisposition\tnote\n'
    printf 'user-scope\talpha\t%s\tpolicy:Artifacts\t\n' "$(ack_hash alpha)"
    printf 'user-scope\tbeta\t%s\texcluded:interactive-only\t\n' "$(ack_hash beta)"
    printf 'user-scope\tgamma\t%s\tskill:autopilot\t\n' "$(ack_hash gamma)"
  } > "$ACK_DIR/stage-policy.sources.tsv"
}

# ack_hash <anchor> — the body hash of the item <anchor> resolves to now.
ack_hash() {
  ( . "$checker"; drift_entries user-scope "$ACK_DIR/cfg/CLAUDE.md" ) \
    | awk -F'\t' -v a="$1" 'index($1, a) == 1 { print $2 }'
}

# ack_source <text> — replaces the user-scope source.
ack_source() { printf '%s' "$1" > "$ACK_DIR/cfg/CLAUDE.md"; }

# ack_run [<arg>...] — sets ACK_OUT and ACK_EC.
ack_run() {
  set +e
  ACK_OUT=$(env -u CC_PIPELINE_RUN_ID CLAUDE_CONFIG_DIR="$ACK_DIR/cfg" \
    bash "$ACK_DIR/stage-policy-drift.sh" --sources-map "$ACK_DIR/no-such-map" \
    --ack-store "$ACK_STORE" "$@" 2>/dev/null)
  ACK_EC=$?
  set -e
}

# ack_expect <label> <exit> <last-line> [<line>...] — each <line> must appear
# exactly once in ACK_OUT.
ack_expect() {
  local label="$1" want_ec="$2" want_last="$3" ok=1 last line hits
  shift 3
  last=$(printf '%s\n' "$ACK_OUT" | tail -n 1)
  if [[ "$ACK_EC" != "$want_ec" ]]; then
    echo "FAIL: ack/$label — exit=$ACK_EC, expected=$want_ec" >&2; ok=0
  fi
  if [[ "$last" != "$want_last" ]]; then
    echo "FAIL: ack/$label — last line '$last', expected '$want_last'" >&2; ok=0
  fi
  for line in "$@"; do
    hits=$(printf '%s\n' "$ACK_OUT" | grep -Fxc -- "$line" || true)
    if [[ "${hits:-0}" != "1" ]]; then
      echo "FAIL: ack/$label — expected exactly one line '$line', found ${hits:-0}" >&2; ok=0
    fi
  done
  if (( ok == 1 )); then
    passed=$((passed + 1)); echo "PASS: ack/$label"
  else
    failures=$((failures + 1)); echo "     output was: $ACK_OUT" >&2
  fi
}

# ack_assert <label> <condition command...>
ack_assert() {
  local label="$1"
  shift
  if "$@"; then
    passed=$((passed + 1)); echo "PASS: ack/$label"
  else
    failures=$((failures + 1)); echo "FAIL: ack/$label" >&2
  fi
}

# store_modes_ok — the store and bodies/ are 700, every file in them is 600.
store_modes_ok() {
  local f
  [[ "$(ls -ld "$ACK_STORE" | cut -c1-10)" == drwx------ ]] || return 1
  [[ "$(ls -ld "$ACK_STORE/bodies" | cut -c1-10)" == drwx------ ]] || return 1
  [[ -f "$ACK_STORE/acks.tsv" ]] || return 1
  for f in "$ACK_STORE/acks.tsv" "$ACK_STORE"/bodies/*; do
    [[ -f "$f" ]] || return 1
    [[ "$(ls -l "$f" | cut -c1-10)" == -rw------- ]] || return 1
  done
}

no_store() { [[ ! -e "$ACK_STORE" ]]; }
out_has() { printf '%s\n' "$ACK_OUT" | grep -Fxq -- "$1"; }

# an excluded row is compared by its anchor alone
ack_case
ack_source '- alpha rule one
    continued alpha
- beta rule two, reworded
- gamma rule three
'
ack_run
ack_expect excluded-body-only 0 match
rm -rf "$ACK_DIR"

# a policy row: changed → acknowledged → changed again, with a diff
ack_case
ack_run --explain
ack_expect baseline-explain 0 match
ack_source '- alpha rule one
    continued alpha, edited
- beta rule two
- gamma rule three
'
ack_run
ack_expect policy-changed 1 'mismatch 1' 'changed user-scope alpha'
ack_run --explain
ack_expect policy-changed-first-explain 1 'mismatch 1' 'changed user-scope alpha' \
  '  disposition: policy:Artifacts' '  no previous body on this host; current body:' \
  '      continued alpha, edited'
ack_run --ack
ack_expect policy-ack 0 match
ack_assert store-modes store_modes_ok
ack_source '- alpha rule one
    continued alpha, edited twice
- beta rule two
- gamma rule three
'
ack_run
ack_expect policy-changed-after-ack 1 'mismatch 1' 'changed user-scope alpha'
ack_run --explain
ack_expect policy-explain-diff 1 'mismatch 1' 'changed user-scope alpha' \
  '  disposition: policy:Artifacts' '  -    continued alpha, edited' '  +    continued alpha, edited twice'
rm -rf "$ACK_DIR"

# --ack has no per-row form: one run records every pending changed row, which
# is why the kickoff and the edit hook ask about all of them before running it
ack_case
ack_source '- alpha rule one
    continued alpha, edited
- beta rule two
- gamma rule three
    grown a line
'
ack_run
ack_expect ack-all-before 1 'mismatch 2' 'changed user-scope alpha' 'changed user-scope gamma'
ack_run --ack
ack_expect ack-all-one-run 0 match
ack_assert ack-all-records-both test "$(awk -F'\t' 'NR > 1 && ($2 == "alpha" || $2 == "gamma")' "$ACK_STORE/acks.tsv" | wc -l | tr -d ' ')" = 2
rm -rf "$ACK_DIR"

# an added bullet: refused as policy, ambiguous prefix, then excluded locally
ack_case
ack_source "$ACK_BASE"'- delta rule four
'
ack_run
ack_expect added 1 'mismatch 1' 'added user-scope delta rule four'
ack_run --ack-added delta policy:Conduct
ack_expect added-policy-refused 2 ''
ack_assert added-policy-store-untouched no_store
ack_run --ack
ack_expect added-not-ackable 1 'mismatch 1' 'added user-scope delta rule four'
ack_run --ack-added delta excluded:interactive-only
ack_expect added-excluded 0 match
rm -rf "$ACK_DIR"

ack_case
ack_source "$ACK_BASE"'- delta one
- delta two
'
ack_run --ack-added delta excluded:interactive-only
ack_expect added-two-candidates 2 ''
ack_assert added-two-candidates-store-untouched no_store
rm -rf "$ACK_DIR"

# a bullet given skill: locally is hash-compared from then on
ack_case
ack_source "$ACK_BASE"'- epsilon rule five
'
ack_run --ack-added epsilon skill:autopilot
ack_expect local-skill 0 match
ack_source "$ACK_BASE"'- epsilon rule five
    grown a line
'
ack_run
ack_expect local-skill-changed 1 'mismatch 1' 'changed user-scope epsilon'
rm -rf "$ACK_DIR"

acks_sum() { shasum -a 256 "$ACK_STORE/acks.tsv" | cut -d' ' -f1; }
no_non_unique() { ! printf '%s\n' "$ACK_OUT" | grep -q '^non-unique '; }

# --ack-added counts every candidate item, not only the added ones: a prefix
# that also matches an item a host-local row already resolves is refused, so
# no stored row can resolve to two items from its first comparison on
ack_case
ack_source "$ACK_BASE"'- delta rule four
'
ack_run --ack-added 'delta rule four' excluded:interactive-only
ack_expect local-first 0 match
sum_before=$(acks_sum)
ack_source "$ACK_BASE"'- delta rule four
- delta rule five
'
ack_run --ack-added 'delta rule' excluded:interactive-only
ack_expect local-prefix-over-resolved-refused 2 ''
ack_assert local-prefix-over-resolved-store-untouched test "$(acks_sum)" = "$sum_before"
ack_run
ack_expect local-prefix-over-resolved-after 1 'mismatch 1' 'added user-scope delta rule five'
ack_assert local-prefix-over-resolved-no-non-unique no_non_unique
rm -rf "$ACK_DIR"

# a prefix whose only match is an item something already resolves is refused
ack_case
ack_source "$ACK_BASE"'- delta rule four
'
ack_run --ack-added delta excluded:interactive-only
ack_expect local-short 0 match
sum_before=$(acks_sum)
ack_run --ack-added 'delta rule' skill:autopilot
ack_expect local-prefix-not-added-refused 2 ''
ack_assert local-prefix-not-added-store-untouched test "$(acks_sum)" = "$sum_before"
rm -rf "$ACK_DIR"

# a host-local row that a later bullet makes match two items resolves nothing:
# no non-unique finding, both items read as added, and longer prefixes settle them
ack_case
ack_source "$ACK_BASE"'- delta rule four
'
ack_run --ack-added delta excluded:interactive-only
ack_expect local-shared-first 0 match
ack_source "$ACK_BASE"'- delta rule four
- delta rule five
'
ack_run
ack_expect local-shared-prefix 1 'mismatch 2' 'added user-scope delta rule four' \
  'added user-scope delta rule five'
ack_assert local-shared-prefix-no-non-unique no_non_unique
ack_run --ack-added 'delta rule four' excluded:interactive-only
ack_expect local-shared-longer-one 1 'mismatch 1' 'added user-scope delta rule five'
ack_run --ack-added 'delta rule five' excluded:interactive-only
ack_expect local-shared-longer-two 0 match
rm -rf "$ACK_DIR"

# removed: an excluded row can be acknowledged, a policy row cannot
ack_case
ack_source '- alpha rule one
    continued alpha
- gamma rule three
'
ack_run
ack_expect excluded-removed 1 'mismatch 1' 'removed user-scope beta'
ack_run --ack
ack_expect excluded-removed-ack 0 match
ack_source '- gamma rule three
'
ack_run --ack
ack_expect policy-removed-ack 1 'mismatch 1' 'removed user-scope alpha'
rm -rf "$ACK_DIR"

# non-unique cannot be acknowledged
ack_case
ack_source "$ACK_BASE"'- alpha again
'
ack_run --ack
ack_expect non-unique-ack 1 'mismatch 1' 'non-unique user-scope alpha'
rm -rf "$ACK_DIR"

# an unattended stage is refused and no store is created
ack_case
ack_source "$ACK_BASE"'- delta rule four
'
set +e
CC_PIPELINE_RUN_ID=x CLAUDE_CONFIG_DIR="$ACK_DIR/cfg" bash "$ACK_DIR/stage-policy-drift.sh" \
  --sources-map "$ACK_DIR/no-such-map" --ack-store "$ACK_STORE" --ack >/dev/null 2>&1
ec_ack=$?
CC_PIPELINE_RUN_ID=x CLAUDE_CONFIG_DIR="$ACK_DIR/cfg" bash "$ACK_DIR/stage-policy-drift.sh" \
  --sources-map "$ACK_DIR/no-such-map" --ack-store "$ACK_STORE" \
  --ack-added delta excluded:interactive-only >/dev/null 2>&1
ec_add=$?
set -e
ack_assert unattended-ack-refused test "$ec_ack" = 2
ack_assert unattended-ack-added-refused test "$ec_add" = 2
ack_assert unattended-store-untouched no_store
rm -rf "$ACK_DIR"

echo "test-lint-stage-policy-sources: $passed passed, $failures failed"

if (( failures > 0 )); then
  exit 1
fi
exit 0
