#!/usr/bin/env bash
# Test scripts/lint-terminal-literals.sh.
#
# THE FIXTURES ARE BUILT UNDER `mktemp -d`, NOT COMMITTED. The slice that adds
# this lint declared its files and no fixture tree, so the roots are written at
# run time and removed on exit. `ORCH_ROOT` and `SKILLS_ROOT` are the overrides
# that make that possible.
#
# The literal values are read from the real `run.sh` declarations, the same way
# the lint reads them, and never typed here. A test that restated them would be
# the second spelling the lint exists to catch.
#
# The fixture consumers copy the real placement: the sidecar quotes the design
# literal twice and the audit literal once and does not quote the
# re-convergence literal, the router shift carries two design copies on one
# line and the re-convergence literal on another, and the autopilot skill
# carries two design copies on one line. `FAIL-consumer-second-copy-same-line`
# is the case that earns the per-occurrence count its keep: a per-line count
# stays green when only the second copy on a line changes.

set -uo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
LINT="$script_dir/lint-terminal-literals.sh"
REAL_RUN_SH="$repo_root/plugins/cc-cmds/orchestrator/run.sh"

if [[ ! -f "$LINT" ]]; then
  echo "FAIL: lint not found: $LINT" >&2
  exit 2
fi

real_value() {
  sed -n "s/^readonly $1='\\(.*\\)'\$/\\1/p" "$REAL_RUN_SH"
}

D=$(real_value LIT_DESIGN_TERMINAL)
A=$(real_value LIT_AUDIT_TERMINAL)
R=$(real_value LIT_RECONVERGE_TERMINAL)
if [[ -z "$D" || -z "$A" || -z "$R" ]]; then
  echo "FAIL: $REAL_RUN_SH 에서 종단 리터럴 세 값을 읽지 못했다" >&2
  exit 2
fi

# A copy changed by one character: the last character is replaced, so the
# changed copy no longer contains the original as a substring.
one_char() { printf '%s!' "${1%?}"; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/cc-lint-terminal-test.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

passed=0
failures=0

write_source() {
  # write_source <root> <design> <audit> <reconverge>
  local root="$1"
  mkdir -p "$root/orch"
  {
    printf '#!/usr/bin/env bash\n'
    printf "readonly LIT_AUDIT_TERMINAL='%s'\n" "$3"
    printf "readonly LIT_RECONVERGE_TERMINAL='%s'\n" "$4"
    printf "readonly LIT_DESIGN_TERMINAL='%s'\n" "$2"
  } > "$root/orch/run.sh"
}

write_emitter() {
  # write_emitter <root> <skill> <literal>
  mkdir -p "$1/skills/$2"
  printf '# %s\n\nstop with the literal statement *"%s"*\n' "$2" "$3" > "$1/skills/$2/SKILL.md"
}

write_emitters() {
  # write_emitters <root> <design> <audit> <reconverge>
  write_emitter "$1" design "$2"
  write_emitter "$1" design-audit "$3"
  write_emitter "$1" design-discuss-unattended "$2"
  write_emitter "$1" design-reconverge "$4"
  write_emitter "$1" design-audit-unattended "$3"
}

write_sidecar() {
  # write_sidecar <root> <design-1> <audit> <design-2>
  mkdir -p "$1/skills/_common"
  {
    printf '| `design` | the freeze literal *"%s"* |\n' "$2"
    printf '| `design-audit` | the terminal literal *"%s"* |\n' "$3"
    printf '| `design-discuss-unattended` | the fixed literal *"%s"* |\n' "$4"
  } > "$1/skills/_common/pipeline-sidecar.md"
}

write_router_shift() {
  # write_router_shift <root> <design-1> <design-2> <reconverge>
  mkdir -p "$1/skills/autopilot-router-shift"
  {
    printf "5. the freeze literal \`%s\` in the stream (\`grep -rlF '%s' log\`)\n" "$2" "$3"
    printf "6. its terminal literal (\`grep -cF '%s' log\`)\n" "$4"
  } > "$1/skills/autopilot-router-shift/SKILL.md"
}

write_autopilot() {
  # write_autopilot <root> <design-1> <design-2>
  mkdir -p "$1/skills/autopilot"
  printf "5. the freeze literal \`%s\` in the stream (\`grep -rlF '%s' log\`)\n" "$2" "$3" \
    > "$1/skills/autopilot/SKILL.md"
}

write_consumers() {
  # write_consumers <root> <design> <audit> <reconverge>
  write_sidecar "$1" "$2" "$3" "$2"
  write_router_shift "$1" "$2" "$2" "$4"
  write_autopilot "$1" "$2" "$2"
}

mk_root() {
  # mk_root <root> — every file intact, carrying the real values.
  write_source "$1" "$D" "$A" "$R"
  write_emitters "$1" "$D" "$A" "$R"
  write_consumers "$1" "$D" "$A" "$R"
}

run_case() {
  # run_case <name> <want-exit> <root|""> [<needle> ...]
  #
  # An empty root runs the lint against the real tree. Every needle must appear
  # in the lint's combined output, as a fixed string.
  local name="$1" want="$2" root="$3" out ec needle ok=1
  shift 3
  if [[ -z "$root" ]]; then
    out=$(ORCH_ROOT= SKILLS_ROOT= bash "$LINT" 2>&1)
  else
    out=$(ORCH_ROOT="$root/orch" SKILLS_ROOT="$root/skills" bash "$LINT" 2>&1)
  fi
  ec=$?
  [[ "$ec" == "$want" ]] || ok=0
  for needle in "$@"; do
    printf '%s\n' "$out" | grep -qF -- "$needle" || { ok=0; echo "  missing in output: $needle" >&2; }
  done
  if [[ "$ok" == "1" ]]; then
    passed=$((passed + 1))
    echo "PASS: $name (exit=$ec, expected=$want)"
  else
    failures=$((failures + 1))
    echo "FAIL: $name (exit=$ec, expected=$want)" >&2
    printf '%s\n' "$out" | sed 's/^/  | /' >&2
  fi
}

# OK — the real tree.
run_case "OK-real-tree" 0 "" "OK:"

# OK — a synthetic root with every copy intact. The sidecar carries no
# re-convergence literal and still passes: the expectation is per file.
mk_root "$WORK/ok"
run_case "OK-fixture" 0 "$WORK/ok" "OK:"

# FAIL — an emitter lost its literal. The file and the literal are both named.
mk_root "$WORK/emit-lost"
printf '# design-reconverge\n\nstop.\n' > "$WORK/emit-lost/skills/design-reconverge/SKILL.md"
run_case "FAIL-emitter-literal-missing" 1 "$WORK/emit-lost" \
  "design-reconverge/SKILL.md" "LIT_RECONVERGE_TERMINAL"

# FAIL — an emitter file is gone. Closed failure, not a skip.
mk_root "$WORK/emit-absent"
rm -f "$WORK/emit-absent/skills/design-audit-unattended/SKILL.md"
run_case "FAIL-emitter-absent" 1 "$WORK/emit-absent" \
  "design-audit-unattended/SKILL.md" "LIT_AUDIT_TERMINAL"

# FAIL — one consumer copy changed by one character.
mk_root "$WORK/cons-char"
write_sidecar "$WORK/cons-char" "$D" "$(one_char "$A")" "$D"
run_case "FAIL-consumer-one-char" 1 "$WORK/cons-char" \
  "_common/pipeline-sidecar.md" "LIT_AUDIT_TERMINAL"

# FAIL — only the second of two copies on one line changed.
mk_root "$WORK/cons-second"
write_autopilot "$WORK/cons-second" "$D" "$(one_char "$D")"
run_case "FAIL-consumer-second-copy-same-line" 1 "$WORK/cons-second" \
  "autopilot/SKILL.md" "LIT_DESIGN_TERMINAL"

# FAIL — a consumer file is gone.
mk_root "$WORK/cons-absent"
rm -f "$WORK/cons-absent/skills/autopilot-router-shift/SKILL.md"
run_case "FAIL-consumer-absent" 1 "$WORK/cons-absent" \
  "autopilot-router-shift/SKILL.md"

# FAIL — the source moved and the emitters kept the old text. The consumers
# follow the new value, so only the emitters are stale: the value the lint
# checks against is the one `run.sh` declares, not one of its own.
D2=$(one_char "$D")
mk_root "$WORK/src-moved"
write_source "$WORK/src-moved" "$D2" "$A" "$R"
write_consumers "$WORK/src-moved" "$D2" "$A" "$R"
run_case "FAIL-source-changed" 1 "$WORK/src-moved" \
  "design/SKILL.md" "design-discuss-unattended/SKILL.md" "LIT_DESIGN_TERMINAL"

# Exit 2 — a declaration is missing from run.sh.
mk_root "$WORK/src-missing"
grep -v '^readonly LIT_RECONVERGE_TERMINAL=' "$WORK/src-missing/orch/run.sh" > "$WORK/src-missing/run.sh.new"
mv "$WORK/src-missing/run.sh.new" "$WORK/src-missing/orch/run.sh"
run_case "FAIL-2-source-missing" 2 "$WORK/src-missing" "LIT_RECONVERGE_TERMINAL"

# Exit 2 — a declaration appears twice. Two sources are the same condition as
# none: the extraction cannot say which one the driver obeys.
mk_root "$WORK/src-twice"
printf "readonly LIT_AUDIT_TERMINAL='%s'\n" "$A" >> "$WORK/src-twice/orch/run.sh"
run_case "FAIL-2-source-twice" 2 "$WORK/src-twice" "LIT_AUDIT_TERMINAL"

# Exit 2 — no run.sh at all.
mk_root "$WORK/src-absent"
rm -f "$WORK/src-absent/orch/run.sh"
run_case "FAIL-2-run-sh-absent" 2 "$WORK/src-absent" "run.sh"

# Registration — the lint is a recipe line of `make lint`, and the test is a
# member of LINT_TESTS. The recipe is asked of make itself (`make -n` prints it
# without running it), so a line make would not take as part of the recipe
# does not pass. The list is read from the Makefile following make's own
# continuation rule — the definition line and every line after it while the
# previous one ends in a backslash — because the make that ships with macOS
# has no `--eval` to print a variable with.
lint_recipe=$(MAKEFLAGS= MAKELEVEL= make -n -C "$repo_root" --no-print-directory lint 2>/dev/null)
lint_tests=$(awk '/^LINT_TESTS :=/ { f = 1 } f { print; if ($0 !~ /\\$/) exit }' "$repo_root/Makefile" \
  | sed -e 's/^LINT_TESTS :=//' -e 's/\\$//')
if printf '%s\n' "$lint_recipe" | grep -qxF 'bash scripts/lint-terminal-literals.sh'; then
  passed=$((passed + 1))
  echo "PASS: registered-in-make-lint"
else
  failures=$((failures + 1))
  echo "FAIL: registered-in-make-lint — make lint 레시피에 bash scripts/lint-terminal-literals.sh 가 없다" >&2
fi
if printf '%s\n' "$lint_tests" | tr ' \t' '\n\n' | grep -qxF 'scripts/test-lint-terminal-literals.sh'; then
  passed=$((passed + 1))
  echo "PASS: registered-in-LINT_TESTS"
else
  failures=$((failures + 1))
  echo "FAIL: registered-in-LINT_TESTS — LINT_TESTS 에 scripts/test-lint-terminal-literals.sh 가 없다" >&2
fi

echo "test-lint-terminal-literals: $passed passed, $failures failed"

if (( failures > 0 )); then
  exit 1
fi
exit 0
