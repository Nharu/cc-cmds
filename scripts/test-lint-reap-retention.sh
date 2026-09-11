#!/usr/bin/env bash
# lint-bash-portability: self-skip
# Test scripts/lint-reap-retention.sh.
#
# THE FIXTURES ARE BUILT UNDER `mktemp -d`, NOT COMMITTED. The slice that adds
# this lint declared its files and no fixture tree, and the declared file set is
# what the authorization rests on — so the roots are written at run time and
# removed on exit. `ORCH_ROOT` and `SCRIPTS_ROOT` are the overrides that make
# that possible, which is why the lint carries both.
#
# Nothing here sources or runs the fixture `gate.sh`: the lint reads it as bytes,
# so a fixture only needs the two shapes it matches — the `readonly` declaration
# and the prose restatement in days.
#
# `FAIL-retyped-in-suite` is the fixture that earns rule 2 its keep. A fixture
# that hand-types the threshold stays green forever while the declaration moves
# underneath it, and the test it anchors then asserts a boundary the code no
# longer has.
#
# `FAIL-no-restatement` is rule 3's own case, and it is the one that stops the
# check from being avoidable: without it, deleting the sentence would pass.

set -uo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
LINT="$script_dir/lint-reap-retention.sh"

if [[ ! -f "$LINT" ]]; then
  echo "FAIL: lint not found: $LINT" >&2
  exit 2
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/cc-lint-reap-test.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

passed=0
failures=0

RETENTION=2592000

mk_gate() {
  # mk_gate <root> <declaration-lines> <prose-days>
  #
  # <declaration-lines> is written verbatim so a case can supply none, one or
  # two. <prose-days> is empty for the root that carries no restatement at all.
  local root="$1" decl="$2" days="$3"
  mkdir -p "$root"
  {
    printf '#!/usr/bin/env bash\n'
    printf '# ---------------------------------------------------------------\n'
    if [[ -n "$days" ]]; then
      printf '# 보존 기준 %s일 — the retention floor, in seconds.\n' "$days"
    else
      printf '# The retention floor, in seconds.\n'
    fi
    [[ -z "$decl" ]] || printf '%s\n' "$decl"
    printf 'readonly GATE_REAP_MAX=20\n'
    printf 'gate_reap_cycle() { return 0; }\n'
  } > "$root/gate.sh"
}

mk_suite() {
  # mk_suite <root> <mode> — a stand-in `test-gate.sh`. `extract` uses the same
  # idiom the real suite is required to use; `retype` hand-types the number.
  local root="$1" mode="$2"
  mkdir -p "$root"
  {
    printf '#!/usr/bin/env bash\n'
    if [[ "$mode" == "retype" ]]; then
      printf 'REAP_RET=%s\n' "$RETENTION"
    else
      printf "REAP_RET=\$(sed -n 's/^readonly GATE_REAP_RETENTION=\\\\([0-9][0-9]*\\\\)\$/\\\\1/p' \"\$GATE\")\n"
    fi
  } > "$root/test-gate.sh"
}

run_case() {
  # run_case <name> <want-exit> <orch-root> <scripts-root>
  local name="$1" want="$2" orch="$3" scripts="$4" ec
  ORCH_ROOT="$orch" SCRIPTS_ROOT="$scripts" bash "$LINT" >/dev/null 2>&1
  ec=$?
  if [[ "$ec" == "$want" ]]; then
    passed=$((passed + 1))
    echo "PASS: $name (exit=$ec, expected=$want)"
  else
    failures=$((failures + 1))
    echo "FAIL: $name (exit=$ec, expected=$want)" >&2
  fi
}

DECL="readonly GATE_REAP_RETENTION=$RETENTION"

# OK — one declaration, a restatement that agrees, and a suite that extracts.
mk_gate  "$WORK/ok" "$DECL" 30
mk_suite "$WORK/ok" extract
run_case "OK-single-sot" 0 "$WORK/ok" "$WORK/ok"

# Exit 2 — the reaper is there and the floor is not declared. Separated from
# exit 1 because "there is no source of truth" is not a verdict about consumers.
mk_gate  "$WORK/nodecl" "" 30
mk_suite "$WORK/nodecl" extract
run_case "FAIL-2-no-declaration" 2 "$WORK/nodecl" "$WORK/nodecl"

# Exit 2 — two declarations. Two sources of truth is the same condition as none:
# the extraction cannot say which one the code obeys.
mk_gate  "$WORK/twodecl" "$DECL
readonly GATE_REAP_RETENTION=$((RETENTION * 2))" 30
mk_suite "$WORK/twodecl" extract
run_case "FAIL-2-two-declarations" 2 "$WORK/twodecl" "$WORK/twodecl"

# FAIL — the suite hand-types the number. This is the whole point of rule 2.
mk_gate  "$WORK/retype" "$DECL" 30
mk_suite "$WORK/retype" retype
run_case "FAIL-retyped-in-suite" 1 "$WORK/retype" "$WORK/retype"

# FAIL — the prose says a different number of days than the declaration.
mk_gate  "$WORK/skew" "$DECL" 60
mk_suite "$WORK/skew" extract
run_case "FAIL-day-restatement-skew" 1 "$WORK/skew" "$WORK/skew"

# FAIL — no restatement at all. Removing the sentence must not be a way to pass.
mk_gate  "$WORK/noprose" "$DECL" ""
mk_suite "$WORK/noprose" extract
run_case "FAIL-no-restatement" 1 "$WORK/noprose" "$WORK/noprose"

# SKIP — the mechanism is not present. Green, matching the sibling lints'
# incremental-rollout posture.
mkdir -p "$WORK/skip"
mk_suite "$WORK/skip" extract
run_case "SKIP-gate-absent" 0 "$WORK/skip" "$WORK/skip"

echo "test-lint-reap-retention: $passed passed, $failures failed"

if (( failures > 0 )); then
  exit 1
fi
exit 0
