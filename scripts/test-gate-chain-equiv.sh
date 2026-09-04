#!/usr/bin/env bash
# Golden vectors for the ledger hash chain — assert gate_chain_verify's verdict
# against frozen, hand-derived (exit code, broken row) tuples.
#
# WHY A GOLDEN VECTOR AT ALL. Every change in this area moves the writing path
# and the verifying path together, and the two then agree with each other. The
# existing controls do not catch that: the suite's chain assertion checks that a
# `prev=` field has the SHAPE of 64 hex characters, never that it has the right
# value, so a verifier that computes a different digest and a writer that stores
# it stay green forever. A frozen expectation computed outside the implementation
# is the only thing that fails when both sides move.
#
# Three properties keep this file from certifying itself:
#
#   1. The `prev=` chains in the fixtures are computed with openssl, not with the
#      shasum the verifier calls. The implementation cannot regenerate its own
#      expectations.
#   2. There is NO refresh mode. A `--refresh-golden` flag is the same hole with
#      a convenience label on it: the first red run gets "fixed" by rewriting the
#      expectation, and the vector stops being evidence.
#   3. The fixture bytes are pinned by digest (digests.txt). Editing a ledger to
#      make a case pass fails the pin before the case runs.
#
# Assertions are on the exit code and the reported row number, never on the
# message text — the wording is a diagnostic and is allowed to change.
#
# Usage:
#   bash scripts/test-gate-chain-equiv.sh
#   GOLDEN_ROOT=<dir> bash scripts/test-gate-chain-equiv.sh   # fixture test
#
# Exit codes:
#   0 — every case matched its frozen tuple
#   1 — at least one case diverged (a real finding about the verifier)
#   2 — harness defect: pins broken, fixture count wrong, or nothing ran
#
# 1 and 2 are separated on purpose. Folded together, a harness that fails to run
# reads as a verifier defect, and — worse in the other direction — a harness that
# ran zero cases reads as success.

set -uo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
GOLDEN="${GOLDEN_ROOT:-$repo_root/tests/fixtures/gate-chain-equiv/golden}"
GATE="${GATE_SH:-$repo_root/plugins/cc-cmds/orchestrator/gate.sh}"

# The committed case count. `> 0` is not enough: this suite's sibling suites all
# terminate on a failure count, so a glob that matches nothing exits 0 and reads
# as a pass. The number is exact so that losing a fixture is a failure and not a
# quieter suite.
EXPECT_CASES=9

# The run id the fixture chains were seeded from. It is part of the frozen input
# — the chain's first link is the digest of "## 실행 <RUN_ID>" — so it belongs
# here beside the vectors, not in the environment.
FIXTURE_RUN_ID=GOLDEN

die2() { printf 'test-gate-chain-equiv: %s\n' "$1" >&2; exit 2; }

[ -d "$GOLDEN" ] || die2 "fixture root missing: $GOLDEN"
[ -f "$GOLDEN/cases.tsv" ] || die2 "cases.tsv missing under $GOLDEN"
[ -f "$GOLDEN/digests.txt" ] || die2 "digests.txt missing under $GOLDEN"
[ -f "$GATE" ] || die2 "gate.sh not found: $GATE"
command -v openssl >/dev/null 2>&1 || die2 "openssl not found — the pins are computed with it"

# ---------- pins ------------------------------------------------------------
# Checked BEFORE anything runs. A fixture edited to make a case pass must fail
# here, where the message says so, rather than silently changing what the vector
# means.
pin_fail=0
pin_seen=0
while read -r want rel; do
  case "$want" in ''|'#'*) continue ;; esac
  f="$GOLDEN/$rel"
  pin_seen=$((pin_seen + 1))
  if [ ! -f "$f" ]; then
    printf 'test-gate-chain-equiv: pinned fixture missing: %s\n' "$rel" >&2
    pin_fail=1
    continue
  fi
  got=$(openssl dgst -sha256 -r < "$f" | cut -d' ' -f1)
  if [ "$got" != "$want" ]; then
    printf 'test-gate-chain-equiv: PIN BROKEN %s\n  want %s\n  got  %s\n' \
      "$rel" "$want" "$got" >&2
    pin_fail=1
  fi
done < "$GOLDEN/digests.txt"
[ "$pin_seen" -gt 0 ] || die2 "digests.txt listed no fixtures"
[ "$pin_fail" = 0 ] || die2 "fixture pins broken — refusing to run the vectors"

# ---------- probe: which column applies here --------------------------------
# What decides the invalid-byte cases is not the vendor of `sed` but what the
# extractor returns for a row carrying an invalid byte. Measuring the observable
# directly means both CI legs assert a frozen tuple instead of one leg skipping.
#
# The probe uses the extractor verbatim. If it is ever changed in gate.sh, this
# line has to change with it — which is the correct coupling: the probe is
# asking what THAT expression does.
PROBE_HEX=00000000000000000000000000000000000000000000000000000000000000ff
probe_out=$(printf 'x\377x | prev=%s\n' "$PROBE_HEX" \
  | sed -n 's/.*| prev=\([0-9a-f]*\)$/\1/p' 2>/dev/null)
probe_rc=$?
if [ "$probe_rc" != 0 ] || [ -z "$probe_out" ]; then
  COL=A
elif [ "$probe_out" = "$PROBE_HEX" ]; then
  COL=B
else
  COL=C
fi
printf 'test-gate-chain-equiv: invalid-byte extractor column = %s\n' "$COL"

# ---------- load the verifier ----------------------------------------------
# Sourced, not spawned: the verdict depends on the locale gate.sh actually runs
# under (run.sh clears LC_ALL and picks a UTF-8 LC_CTYPE), and a fresh shell
# would measure the caller's locale instead of production's.
export CC_GATE_SOURCE_ONLY=1
# shellcheck disable=SC1090
. "$GATE" || die2 "could not source $GATE"
# gate.sh enables errexit for its own run. Here, failing verdicts are the data.
set +e

command -v gate_chain_verify >/dev/null 2>&1 \
  || die2 "gate_chain_verify not defined after sourcing $GATE"

passed=0
failed=0
ran=0
saw_intact=0
saw_broken=0

# ---------- run -------------------------------------------------------------
while read -r name rcA brA rcB brB rcC brC; do
  case "$name" in ''|'#'*) continue ;; esac

  case "$COL" in
    A) want_rc=$rcA; want_broke=$brA ;;
    B) want_rc=$rcB; want_broke=$brB ;;
    C) want_rc=$rcC; want_broke=$brC ;;
  esac

  [ -d "$GOLDEN/$name" ] || {
    printf 'test-gate-chain-equiv: case directory missing: %s\n' "$name" >&2
    failed=$((failed + 1)); ran=$((ran + 1)); continue
  }

  # `missing-ledger` is a case whose fixture is the ABSENCE of the file. It is
  # here because the verifier reports a ledger it cannot open as intact, which
  # is the same class of silent pass as a skipped row.
  RUN_ID="$FIXTURE_RUN_ID"
  LEDGER="$GOLDEN/$name/ledger.md"

  err=$(gate_chain_verify 2>&1 >/dev/null)
  got_rc=$?
  got_broke=$(printf '%s' "$err" | sed -n 's/.*체인이 \([0-9][0-9]*\)번째 행에서.*/\1/p')
  [ -n "$got_broke" ] || got_broke=0

  ran=$((ran + 1))
  if [ "$got_rc" = 0 ]; then saw_intact=1; else saw_broken=1; fi

  if [ "$got_rc" = "$want_rc" ] && [ "$got_broke" = "$want_broke" ]; then
    passed=$((passed + 1))
    printf 'PASS: %-22s (rc=%s broke=%s)\n' "$name" "$got_rc" "$got_broke"
  else
    failed=$((failed + 1))
    printf 'FAIL: %-22s got (rc=%s broke=%s), want (rc=%s broke=%s) [column %s]\n' \
      "$name" "$got_rc" "$got_broke" "$want_rc" "$want_broke" "$COL" >&2
  fi
done < "$GOLDEN/cases.tsv"

# ---------- non-vacuity guards ----------------------------------------------
# These are exit-2, not exit-1: a vector that did not run is a broken harness,
# not evidence about the verifier.
if [ "$ran" != "$EXPECT_CASES" ]; then
  die2 "ran $ran cases, expected exactly $EXPECT_CASES (fixture set changed without updating the count)"
fi
if [ "$saw_intact" = 0 ] || [ "$saw_broken" = 0 ]; then
  die2 "both verdicts must occur in the corpus (intact=$saw_intact broken=$saw_broken) — a corpus that only ever breaks is blind to the accepting direction"
fi

printf 'test-gate-chain-equiv: %d passed, %d failed (%d cases, column %s)\n' \
  "$passed" "$failed" "$ran" "$COL"

[ "$failed" = 0 ] || exit 1
exit 0
