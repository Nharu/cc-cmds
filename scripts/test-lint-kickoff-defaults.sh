#!/usr/bin/env bash
# lint-bash-portability: self-skip
# Test scripts/lint-kickoff-defaults.sh against mutants of the real tree.
#
# There is no fixture directory: each case copies the real orchestrator, hooks
# and autopilot SKILL.md into a scratch workspace, changes one thing, and runs
# the lint against the copy. The real tree is the clean case, so a fixture can
# never be the thing that passes while the shipped files have drifted.
#
# Every failing case also names the rule it must fail on. A mutant that fails
# for some other reason — a copy that lost a file, a rule that fires on
# everything — would otherwise count as a pass.

set -uo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
LINT="$script_dir/lint-kickoff-defaults.sh"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/test-lint-kickoff-defaults.XXXXXX") || exit 2
trap 'rm -rf "$WORK"' EXIT

passed=0
failures=0

# fresh <name> — a scratch copy of the three roots the lint reads.
fresh() {
  local d="$WORK/$1"
  mkdir -p "$d/skills/autopilot"
  cp -R "$repo_root/plugins/cc-cmds/orchestrator" "$d/orchestrator"
  cp -R "$repo_root/plugins/cc-cmds/hooks" "$d/hooks"
  cp "$repo_root/plugins/cc-cmds/skills/autopilot/SKILL.md" "$d/skills/autopilot/SKILL.md"
  printf '%s' "$d"
}

# case_run <name> <dir> <want exit> [<text stderr must carry>]
case_run() {
  local name="$1" d="$2" want="$3" needle="${4:-}" ec
  ORCH_ROOT="$d/orchestrator" HOOKS_ROOT="$d/hooks" SKILLS_ROOT="$d/skills" \
    bash "$LINT" >"$d.out" 2>"$d.err"
  ec=$?
  if [[ "$ec" != "$want" ]]; then
    failures=$((failures + 1))
    echo "FAIL: $name (exit=$ec, expected=$want)" >&2
    sed 's/^/       /' "$d.err" >&2
    return 0
  fi
  if [[ -n "$needle" ]] && ! grep -qF "$needle" "$d.err"; then
    failures=$((failures + 1))
    echo "FAIL: $name — 다른 이유로 실패했다 (기대 문면: $needle)" >&2
    sed 's/^/       /' "$d.err" >&2
    return 0
  fi
  passed=$((passed + 1))
  echo "PASS: $name (exit=$ec, expected=$want)"
}

R1='킥오프 보조 밖에서 킥오프 기본값을 가리키는 파일이 있다'
R2='키 집합이 보조 스크립트와 SKILL.md 5o 사이에서 갈렸다'
R3='드라이버 어휘 상수를 대입한다'
R4='재킥오프 보조 밖에서 rekick.sh 를 가리키는 파일이 있다'

# 1. the real tree passes
d=$(fresh clean)
case_run "실제 트리 그대로" "$d" 0

# 2. the driver names the data file, in a comment
d=$(fresh driver-names-file)
printf '# reads ~/.config/cc-cmds/autopilot-defaults\n' >> "$d/orchestrator/run.sh"
case_run "run.sh 가 autopilot-defaults 를 담는다" "$d" 1 "$R1"

# 3. a rule the gate calls reads a defaults variable
d=$(fresh rule-reads-env)
mkdir -p "$d/orchestrator/rules"
printf 'v="${CC_CMDS_AUTOPILOT_DEFAULT_X:-}"\n' > "$d/orchestrator/rules/x.sh"
case_run "rules/ 파일이 CC_CMDS_AUTOPILOT_DEFAULT_X 를 담는다" "$d" 1 "$R1"

# 4. a hook calls the helper
d=$(fresh hook-calls-helper)
printf 'bash "$root/orchestrator/kickoff-defaults.sh" --target a/b\n' > "$d/hooks/x.sh"
case_run "hooks 파일이 kickoff-defaults.sh 를 부른다" "$d" 1 "$R1"

# 5. a key row goes missing from the 5o table
d=$(fresh table-missing-key)
awk '!/^\| `terminal-cap` \|/' "$repo_root/plugins/cc-cmds/skills/autopilot/SKILL.md" > "$d/skills/autopilot/SKILL.md"
case_run "5o 표에서 terminal-cap 행이 빠졌다" "$d" 1 "$R2"

# 6. the helper reads a key the 5o table does not name
d=$(fresh helper-extra-key)
awk '/^KD_REPO_KEYS=/{sub(/'"'"'$/, " extra-key'"'"'")} {print}' \
  "$repo_root/plugins/cc-cmds/orchestrator/kickoff-defaults.sh" > "$d/orchestrator/kickoff-defaults.sh"
case_run "보조 키 표에만 있는 키가 있다" "$d" 1 "$R2"

# 7. the helper carries its own copy of the cutpoint vocabulary
d=$(fresh helper-copies-vocab)
printf "CUTPOINTS='커밋 브랜치'\n" >> "$d/orchestrator/kickoff-defaults.sh"
case_run "보조가 CUTPOINTS= 를 대입한다" "$d" 1 "$R3"

# 8. a comment in the helper naming the constant is not an assignment
d=$(fresh helper-comment-vocab)
printf "# CUTPOINTS= comes from the driver\n" >> "$d/orchestrator/kickoff-defaults.sh"
case_run "보조 주석의 CUTPOINTS= 는 대입이 아니다" "$d" 0

# 9. the driver calls the re-kickoff helper
d=$(fresh driver-calls-rekick)
printf 'bash "$ORCH_DIR/rekick.sh" detect --base "$BASE"\n' >> "$d/orchestrator/run.sh"
case_run "run.sh 가 rekick.sh 를 부른다" "$d" 1 "$R4"

# 10. a hook names it in a comment only
d=$(fresh hook-comment-rekick)
printf '# see orchestrator/rekick.sh\n' > "$d/hooks/x.sh"
case_run "hooks 파일 주석에만 rekick.sh 가 있다" "$d" 1 "$R4"

# 11. the re-kickoff helper naming itself is not a caller
d=$(fresh rekick-names-self)
printf '# usage: rekick.sh detect\n' >> "$d/orchestrator/rekick.sh"
case_run "rekick.sh 자신이 rekick.sh 를 적는다" "$d" 0

# 12. a skill document names both helpers — the kickoff is where they are called
d=$(fresh skill-names-both)
printf '\nrekick.sh 와 kickoff-defaults.sh 를 킥오프가 부른다.\n' >> "$d/skills/autopilot/SKILL.md"
case_run "skills/ 문서가 두 보조를 함께 적는다" "$d" 0

# 13. the re-kickoff helper reading the defaults falls under rule 1
d=$(fresh rekick-reads-defaults)
printf 'bash "$RK_DIR/kickoff-defaults.sh" --carry "$m"\n' >> "$d/orchestrator/rekick.sh"
case_run "rekick.sh 가 kickoff-defaults.sh 를 부른다" "$d" 1 "$R1"

echo "test-lint-kickoff-defaults: $passed passed, $failures failed"

if (( failures > 0 )); then
  exit 1
fi
exit 0
