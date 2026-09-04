#!/usr/bin/env bash
# The ledger chain's two controls, in one entry point.
#
#   Phase 1 — GOLDEN VECTORS. Frozen (exit code, broken row) tuples, computed
#             outside the implementation, asserted against the live verifier.
#   Phase 2 — DIFFERENTIAL EQUIVALENCE. The live verifier against a vendored
#             frozen reference over a mutation corpus, so a rewrite has to prove
#             it did not move the verdict.
#
# WHY BOTH. They fail on different things and neither subsumes the other. Every
# change in this area moves the writing path and the verifying path together, so
# the two agree with each other afterwards and the suite's existing chain check —
# which asserts a `prev=` has the SHAPE of 64 hex characters, never the value —
# stays green. The golden vectors catch that. But a golden vector only pins the
# cases someone thought to write down; a rewrite that changes an unlisted case
# passes it. The differential corpus catches that instead, and it does so without
# freezing absolute verdicts, which matters because two of the mutation classes
# are decided by the bash version and no single expectation is right on both CI
# legs.
#
# Three properties keep this from certifying itself:
#
#   1. The `prev=` chains in the fixtures are computed with openssl, not with the
#      shasum the verifier calls. The implementation cannot regenerate its own
#      expectations.
#   2. There is NO refresh mode. A `--refresh-golden` flag is the same hole with
#      a convenience label: the first red run gets "fixed" by rewriting the
#      expectation, and the vector stops being evidence.
#   3. Every fixture and the vendored reference are pinned by digest. Editing one
#      to make a case pass fails the pin before the case runs — including the
#      reference itself, which is the specific attack of a slice fixing its own
#      divergence by moving what it is compared against.
#
# Usage:
#   bash scripts/test-gate-chain-equiv.sh
#   FIXTURE_ROOT=<dir> bash scripts/test-gate-chain-equiv.sh
#
# Exit codes:
#   0 — golden vectors matched and the live verifier is equivalent to v1
#   1 — a divergence: a real finding about the verifier
#   2 — harness defect: pins broken, wrong fixture count, a guard unsatisfied,
#       or nothing ran
#
# 1 and 2 are separated on purpose. Folded together, a harness that fails to run
# reads as a verifier defect and — worse — a harness that ran zero cases reads as
# success. Every suite in this repository terminates on a failure count, so an
# empty glob exits 0; that is what the guards below exist to refuse.

set -uo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
FIX="${FIXTURE_ROOT:-$repo_root/tests/fixtures/gate-chain-equiv}"
GOLDEN="$FIX/golden"
CORPUS="$FIX/corpus"
REFERENCE="$FIX/reference-v1.sh"
MUTANT="$FIX/reference-v1-mutant.sh"
DIVERGENCES="$FIX/expected-divergences.tsv"
GATE="${GATE_SH:-$repo_root/plugins/cc-cmds/orchestrator/gate.sh}"

# Committed counts. `> 0` is not enough — losing a fixture has to be a failure,
# not a quieter suite.
EXPECT_GOLDEN=9
EXPECT_EQUIV=60          # 51 corpus mutations + the 9 golden ledgers

# The vendored reference's digest. Pinned HERE rather than in a data file so
# that moving the reference and moving its pin are two edits in two files.
REFERENCE_SHA256=d1172e7dd3664281aa2c56aa435c47ef33047e1e85dcabaedda05b09fa98105e
MUTANT_SHA256=78148d29919d2ccd6ad3fa07f25a116ba02ca04f10ee7415361073229ba724f4

GOLDEN_RUN_ID=GOLDEN
CORPUS_RUN_ID=CORPUS

die2() { printf 'test-gate-chain-equiv: %s\n' "$1" >&2; exit 2; }

for p in "$GOLDEN" "$CORPUS"; do
  [ -d "$p" ] || die2 "fixture directory missing: $p"
done
for f in "$GOLDEN/cases.tsv" "$GOLDEN/digests.txt" "$CORPUS/base.md" \
         "$CORPUS/base.digest" "$REFERENCE" "$MUTANT" "$DIVERGENCES" "$GATE"; do
  [ -f "$f" ] || die2 "fixture file missing: $f"
done
command -v openssl >/dev/null 2>&1 || die2 "openssl not found — the pins are computed with it"

sha() { openssl dgst -sha256 -r < "$1" | cut -d' ' -f1; }

# ---------- pins ------------------------------------------------------------
# Checked BEFORE anything runs, so a fixture edited to make a case pass fails
# here — where the message says so — rather than silently changing the meaning
# of the vector.
pin_fail=0
pin_seen=0
check_pin() {                     # check_pin <file> <want> <label>
  local got
  got=$(sha "$1")
  pin_seen=$((pin_seen + 1))
  if [ "$got" != "$2" ]; then
    printf 'test-gate-chain-equiv: PIN BROKEN %s\n  want %s\n  got  %s\n' \
      "$3" "$2" "$got" >&2
    pin_fail=1
  fi
}

while read -r want rel; do
  case "$want" in ''|'#'*) continue ;; esac
  if [ ! -f "$GOLDEN/$rel" ]; then
    printf 'test-gate-chain-equiv: pinned fixture missing: golden/%s\n' "$rel" >&2
    pin_fail=1; continue
  fi
  check_pin "$GOLDEN/$rel" "$want" "golden/$rel"
done < "$GOLDEN/digests.txt"

while read -r want rel; do
  case "$want" in ''|'#'*) continue ;; esac
  [ -f "$CORPUS/$rel" ] || { printf 'test-gate-chain-equiv: pinned fixture missing: corpus/%s\n' "$rel" >&2; pin_fail=1; continue; }
  check_pin "$CORPUS/$rel" "$want" "corpus/$rel"
done < "$CORPUS/base.digest"

check_pin "$REFERENCE" "$REFERENCE_SHA256" "reference-v1.sh"
check_pin "$MUTANT" "$MUTANT_SHA256" "reference-v1-mutant.sh"

[ "$pin_seen" -gt 0 ] || die2 "no pins were checked"
[ "$pin_fail" = 0 ] || die2 "pins broken — refusing to run"

# ---------- load the live verifier -----------------------------------------
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

WORK=$(mktemp -d "${TMPDIR:-/tmp}/cc-chain-equiv.XXXXXX") || die2 "mktemp failed"
trap 'rm -rf "$WORK"' EXIT

passed=0
failed=0

# ---------- phase 1: golden vectors ----------------------------------------
# What decides the invalid-byte cases is not the vendor of `sed` but what the
# `prev=` extractor returns for a row carrying an invalid byte. Measuring that
# observable directly is what lets both CI legs assert a frozen tuple instead of
# one leg skipping. The probe uses the extractor verbatim; if that expression
# changes in gate.sh this line changes with it, which is the correct coupling.
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

# Both verdict helpers echo "<rc> <broke>" and put stderr in a FILE named by the
# caller. Stderr cannot travel in a variable here: these are called from inside
# a command substitution, so an assignment made in the callee dies with that
# subshell — which silently emptied both sides of the stderr comparison and made
# the whole tier-2 check compare "" against "". Guard 5 is what surfaced it.

# live_verdict <ledger> <run-id> <errfile>
live_verdict() {
  local rc broke
  LEDGER="$1"; RUN_ID="$2"
  gate_chain_verify 2>"$3" >/dev/null
  rc=$?
  broke=$(sed -n 's/.*체인이 \([0-9][0-9]*\)번째 행에서.*/\1/p' "$3")
  [ -n "$broke" ] || broke=0
  printf '%s %s' "$rc" "$broke"
}

# ref_verdict <script> <ledger> <run-id> <errfile>
ref_verdict() {
  local rc broke
  bash "$1" "$2" "$3" 2>"$4" >/dev/null
  rc=$?
  broke=$(sed -n 's/.*체인이 \([0-9][0-9]*\)번째 행에서.*/\1/p' "$4")
  [ -n "$broke" ] || broke=0
  printf '%s %s' "$rc" "$broke"
}

golden_ran=0
golden_intact=0
golden_broken=0
while read -r name rcA brA rcB brB rcC brC; do
  case "$name" in ''|'#'*) continue ;; esac
  case "$COL" in
    A) want="$rcA $brA" ;;
    B) want="$rcB $brB" ;;
    C) want="$rcC $brC" ;;
  esac
  [ -d "$GOLDEN/$name" ] || { printf 'FAIL: golden %s — case directory missing\n' "$name" >&2; failed=$((failed+1)); golden_ran=$((golden_ran+1)); continue; }
  got=$(live_verdict "$GOLDEN/$name/ledger.md" "$GOLDEN_RUN_ID" "$WORK/golden.err")
  golden_ran=$((golden_ran + 1))
  case "$got" in 0\ *) golden_intact=1 ;; *) golden_broken=1 ;; esac
  if [ "$got" = "$want" ]; then
    passed=$((passed + 1))
    printf 'PASS: golden %-22s (rc broke = %s)\n' "$name" "$got"
  else
    failed=$((failed + 1))
    printf 'FAIL: golden %-22s got (%s), want (%s) [column %s]\n' "$name" "$got" "$want" "$COL" >&2
  fi
done < "$GOLDEN/cases.tsv"

[ "$golden_ran" = "$EXPECT_GOLDEN" ] \
  || die2 "phase 1 ran $golden_ran golden cases, expected exactly $EXPECT_GOLDEN"
{ [ "$golden_intact" = 1 ] && [ "$golden_broken" = 1 ]; } \
  || die2 "phase 1 must exercise both verdicts (intact=$golden_intact broken=$golden_broken)"

# ---------- the mutation corpus --------------------------------------------
# 15 classes. Position-dependent classes get four instances (k = 1..4); the rest
# get one. The mutation point comes from the case NAME, not from a seed, so a
# failing case is reproducible from its name alone.
#
# Row k of the base is file line k+1 — line 1 is the `## 실행` header, which the
# verifier's loop skips and the chain's first link is computed from.
POS_DEP="broken reorder deleted badbytes nul emptyprev dupprev insert-noprev insert-hexprev nonhexprev truncate whitespace"
POS_INDEP="identity empty nonl"

WRONG_HEX=1111111111111111111111111111111111111111111111111111111111111111

# row_of <file> <k> — the text of row k (1-based over row-shaped lines).
row_of() { sed -n "$(( $2 + 1 ))p" "$1"; }

# mutate <class> <k> <out> — write the mutated ledger to <out>.
mutate() {
  local cls="$1" k="$2" out="$3" ln body hex row
  ln=$(( k + 1 ))
  case "$cls" in
    identity) cp "$CORPUS/base.md" "$out" ;;
    empty)    cp "$CORPUS/base.md" "$out"; printf '\n' >> "$out" ;;
    nonl)     printf '%s' "$(cat "$CORPUS/base.md")" > "$out" ;;
    deleted)  sed "${ln}d" "$CORPUS/base.md" > "$out" ;;
    truncate) sed -n "1,${ln}p" "$CORPUS/base.md" > "$out" ;;
    reorder)
      awk -v a="$ln" -v b="$(( ln + 1 ))" '
        NR==a { first=$0; next }
        NR==b { print $0; print first; next }
        { print }' "$CORPUS/base.md" > "$out" ;;
    broken)
      # Flip the final hex digit of row k's prev — the smallest edit that keeps
      # the field well-formed and makes the value wrong.
      awk -v n="$ln" '
        NR==n { s=$0; c=substr(s,length(s),1)
                sub(/.$/, (c=="0" ? "1" : "0"), s); print s; next }
        { print }' "$CORPUS/base.md" > "$out" ;;
    whitespace)
      awk -v n="$ln" 'NR==n { print $0 " "; next } { print }' "$CORPUS/base.md" > "$out" ;;
    emptyprev)
      awk -v n="$ln" 'NR==n { sub(/prev=[0-9a-f]*$/, "prev="); print; next } { print }' \
        "$CORPUS/base.md" > "$out" ;;
    nonhexprev)
      awk -v n="$ln" 'NR==n { sub(/prev=[0-9a-f]*$/, "prev=zzzz"); print; next } { print }' \
        "$CORPUS/base.md" > "$out" ;;
    dupprev)
      awk -v n="$ln" '{ if (NR==n) { match($0, /prev=[0-9a-f]*$/)
                          print $0 " | " substr($0, RSTART, RLENGTH) } else print }' \
        "$CORPUS/base.md" > "$out" ;;
    badbytes|nul)
      # Splice a byte into the row's TEXT, leaving `prev=` syntactically intact,
      # so what is being measured is the byte and not a malformed field.
      row=$(row_of "$CORPUS/base.md" "$k")
      body=${row% | prev=*}
      hex=${row##* | prev=}
      { sed -n "1,$(( ln - 1 ))p" "$CORPUS/base.md"
        if [ "$cls" = badbytes ]; then
          printf '%s\377 | prev=%s\n' "$body" "$hex"
        else
          printf '%s\000 | prev=%s\n' "$body" "$hex"
        fi
        sed -n "$(( ln + 1 )),\$p" "$CORPUS/base.md"
      } > "$out" ;;
    insert-noprev)
      { sed -n "1,$(( ln - 1 ))p" "$CORPUS/base.md"
        printf -- '- `승인` | 승인 id=FORGED | 상태=승인 | 사유=자기승인\n'
        sed -n "${ln},\$p" "$CORPUS/base.md"
      } > "$out" ;;
    insert-hexprev)
      { sed -n "1,$(( ln - 1 ))p" "$CORPUS/base.md"
        printf -- '- `승인` | 승인 id=FORGED | 상태=승인 | prev=%s\n' "$WRONG_HEX"
        sed -n "${ln},\$p" "$CORPUS/base.md"
      } > "$out" ;;
    *) die2 "unknown mutation class: $cls" ;;
  esac
}

# ---------- stderr normalization -------------------------------------------
# Tier 2. Compared after normalization because the raw text over-reports: BSD
# `sed` writes a diagnostic of its own on the invalid-byte rows, and the live
# function's `warn` stamps a timestamp that the vendored script does not.
#
# EVERY RULE MUST FIRE at least once over the corpus (guard 5). A rule that
# never fires is either dead or was written to launder a divergence, and the two
# are indistinguishable from the outside.
# Rule firings are recorded as FILES, not shell variables. The comparison runs
# inside a command substitution, so a variable set there dies with the subshell
# and guard 5 would report every rule dead no matter what fired.
RULE_NAMES="timestamp sed-illegal-byte ledger-path"
RULEDIR="$WORK/rules"
mkdir -p "$RULEDIR"

normalize_err() {                 # normalize_err <text>
  local t="$1"
  case "$t" in
    *'[run][warn] '*) : > "$RULEDIR/timestamp" ;;
  esac
  case "$t" in
    *'illegal byte sequence'*) : > "$RULEDIR/sed-illegal-byte" ;;
  esac
  case "$t" in
    */*) : > "$RULEDIR/ledger-path" ;;
  esac
  printf '%s' "$t" \
    | sed -e 's/^[0-9][0-9-]*T[0-9:]*Z \[run\]\[warn\] //' \
          -e '/illegal byte sequence/d' \
          -e 's#/[^ ]*/#<PATH>/#g'
}

# ---------- phase 2: differential equivalence -------------------------------
# Build the corpus once and reuse it for the live/reference/mutant passes so all
# three see byte-identical inputs.
CASES="$WORK/cases"
mkdir -p "$CASES"
class_seen=""
equiv_names=""

for cls in $POS_INDEP; do
  mutate "$cls" 1 "$CASES/$cls.md"
  equiv_names="$equiv_names $cls|$CASES/$cls.md|$CORPUS_RUN_ID"
  class_seen="$class_seen $cls"
done
for cls in $POS_DEP; do
  for k in 1 2 3 4; do
    mutate "$cls" "$k" "$CASES/$cls-k$k.md"
    equiv_names="$equiv_names $cls-k$k|$CASES/$cls-k$k.md|$CORPUS_RUN_ID"
  done
  class_seen="$class_seen $cls"
done
# The golden ledgers join the differential corpus too. They are ordinary ledgers,
# and `missing-ledger` is the only case that exercises the not-verifiable path —
# which is what makes the ledger-path normalization rule fire.
while read -r gname _rest; do
  case "$gname" in ''|'#'*) continue ;; esac
  equiv_names="$equiv_names golden:$gname|$GOLDEN/$gname/ledger.md|$GOLDEN_RUN_ID"
done < "$GOLDEN/cases.tsv"

# compare_impl <script-or-live> — runs the whole corpus, echoes the divergence
# names it found, one per line. Used for the real comparison AND for the
# positive control, so the control tests the comparator itself and not a copy.
compare_impl() {
  local impl="$1" entry name ledger rid lv rv lerr rerr
  for entry in $equiv_names; do
    name=${entry%%|*}
    ledger=${entry#*|}; rid=${ledger#*|}; ledger=${ledger%%|*}
    lv=$(ref_verdict "$REFERENCE" "$ledger" "$rid" "$WORK/ref.err")
    rerr=$(cat "$WORK/ref.err")
    # Recorded on the live pass only, so the positive control's second pass does
    # not double the counts guard 6a reads.
    [ "$impl" = "live" ] && printf '%s\n' "$lv" >> "$WORK/refverdicts"
    if [ "$impl" = "live" ]; then
      rv=$(live_verdict "$ledger" "$rid" "$WORK/cand.err")
    else
      rv=$(ref_verdict "$impl" "$ledger" "$rid" "$WORK/cand.err")
    fi
    lerr=$(cat "$WORK/cand.err")
    if [ "$lv" != "$rv" ]; then
      printf '%s\ttuple\t%s\t%s\n' "$name" "$lv" "$rv"
      continue
    fi
    if [ "$(normalize_err "$rerr")" != "$(normalize_err "$lerr")" ]; then
      printf '%s\tstderr\t-\t-\n' "$name"
    fi
  done
}

equiv_ran=0
for entry in $equiv_names; do equiv_ran=$((equiv_ran + 1)); done
[ "$equiv_ran" = "$EXPECT_EQUIV" ] \
  || die2 "phase 2 built $equiv_ran comparisons, expected exactly $EXPECT_EQUIV"

observed=$(compare_impl live)

# ---------- guards ----------------------------------------------------------
# guard 2 — every mutation class contributes at least one case
for cls in $POS_INDEP $POS_DEP; do
  case " $class_seen " in *" $cls "*) ;; *) die2 "guard 2: class '$cls' contributed no case" ;; esac
done

# guard 6a — the corpus must contain a mutation the REFERENCE accepts. A corpus
# in which everything is rejected is blind to the accepting direction, which is
# the direction a detection loss travels in. Which classes these are is re-read
# from the reference's own behaviour every run rather than named in prose, so it
# stays correct as later slices close classes.
[ -s "$WORK/refverdicts" ] || die2 "guard 6a: the comparison recorded no reference verdicts"
ref_accepts=$(grep -c '^0 ' "$WORK/refverdicts")
ref_rejects=$(grep -vc '^0 ' "$WORK/refverdicts")
[ "$ref_accepts" -gt 0 ] \
  || die2 "guard 6a: the reference accepts nothing in this corpus — it cannot detect a loss of detection"
[ "$ref_rejects" -gt 0 ] \
  || die2 "guard 3: the reference rejects nothing in this corpus"

# guard 5 — normalization rule liveness
for r in $RULE_NAMES; do
  [ -f "$RULEDIR/$r" ] || die2 "guard 5: normalization rule '$r' never fired over the corpus — it is dead, or it was written to launder a divergence"
done

# guard 4 — POSITIVE CONTROL. Guards 1-3 all pass with a comparator that returns
# "equivalent" unconditionally; this is the only one that tests the comparator.
control=$(compare_impl "$MUTANT")
if [ -z "$control" ]; then
  die2 "guard 4: the positive control was reported EQUIVALENT to the reference — the comparator is not comparing"
fi
printf 'test-gate-chain-equiv: positive control diverged on %d case(s) — comparator is live\n' \
  "$(printf '%s\n' "$control" | grep -c .)"

# ---------- expected divergences (guards 6b / 6c) ---------------------------
# Enumerated by NAME, never by a threshold. An unlisted divergence fails, and a
# listed one that no longer occurs fails too — a stale exception is a lie about
# the code.
strengthening=$(sed -n 's/^# 강화 방향: //p' "$DIVERGENCES" | sed -n 1p)
listed=$(grep -v '^#' "$DIVERGENCES" | grep -v '^[[:space:]]*$')

accept_to_reject=0
for_each_listed_ok=1
if [ -n "$listed" ]; then
  while read -r lname ldir _reason; do
    [ -n "$lname" ] || continue
    case "$ldir" in
      수용→거부) accept_to_reject=$((accept_to_reject + 1)) ;;
      거부→수용)
        # guard 6c — a loss of detection cannot be listed without saying so.
        case "$_reason" in
          *DETECTION-LOSS*) ;;
          *) printf 'FAIL: %s is listed as 거부→수용 without a DETECTION-LOSS marker\n' "$lname" >&2
             for_each_listed_ok=0 ;;
        esac ;;
      *) printf 'FAIL: %s has an unrecognized direction: %s\n' "$lname" "$ldir" >&2
         for_each_listed_ok=0 ;;
    esac
    if ! printf '%s\n' "$observed" | grep -q "^${lname}	"; then
      printf 'FAIL: %s is listed as an expected divergence but no longer diverges (stale exception)\n' "$lname" >&2
      for_each_listed_ok=0
    fi
  done <<EOF
$listed
EOF
fi

# guard 6b — a slice that strengthens detection must name at least one
# accept→reject divergence. Declared in the file's header rather than inferred,
# because which slice this is is a property of the commit, not of the tree.
if [ "$strengthening" = "예" ] && [ "$accept_to_reject" = 0 ]; then
  die2 "guard 6b: the divergence list declares 강화 방향: 예 but enumerates no 수용→거부 case"
fi

if [ -n "$observed" ]; then
  while IFS="	" read -r oname okind a b; do
    [ -n "$oname" ] || continue
    if printf '%s\n' "$listed" | grep -q "^$oname[[:space:]]"; then
      passed=$((passed + 1))
      printf 'PASS: divergence %s (%s) is enumerated\n' "$oname" "$okind"
    else
      failed=$((failed + 1))
      printf 'FAIL: UNLISTED divergence %s (%s): reference=%s candidate=%s\n' \
        "$oname" "$okind" "$a" "$b" >&2
    fi
  done <<EOF
$observed
EOF
else
  passed=$((passed + 1))
  printf 'PASS: live verifier is equivalent to reference v1 over %d comparisons\n' "$equiv_ran"
fi
[ "$for_each_listed_ok" = 1 ] || failed=$((failed + 1))

printf 'test-gate-chain-equiv: %d passed, %d failed (golden %d, equivalence %d, column %s, reference accepts %d / rejects %d)\n' \
  "$passed" "$failed" "$golden_ran" "$equiv_ran" "$COL" "$ref_accepts" "$ref_rejects"

[ "$failed" = 0 ] || exit 1
exit 0
