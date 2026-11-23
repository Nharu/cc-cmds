#!/usr/bin/env bash
# Test scripts/skill-trigger-measure.sh against
# tests/fixtures/skill-trigger-measure/.
#
# No model is called: SKILL_TRIGGER_CLAUDE_BIN points at the fixture's
# claude-stub.sh, which records its argv and environment and answers from
# markers in each utterance. The fixture's two scenario files are the verdict
# goldens: alpha.tsv holds one line per verdict and observation kind
# (일치, 어긋남, 불안정, 비발동, a failed run, an expected skill missing from
# the session's list), beta.tsv matches everywhere, so it carries the exit 0
# branch. Every run's state goes under one `mktemp -d`.

set -uo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
H="$script_dir/skill-trigger-measure.sh"
PROTOCOL="$script_dir/prompt-change-protocol.md"
fixtures="$repo_root/tests/fixtures/skill-trigger-measure"
STUB="$fixtures/claude-stub.sh"

passed=0
failures=0
pass() { passed=$((passed + 1)); echo "PASS: $1"; }
fail() { failures=$((failures + 1)); echo "FAIL: $1" >&2; }

tmp=$(mktemp -d "${TMPDIR:-/tmp}/test-skill-trigger-measure.XXXXXX")
tmp=$(cd "$tmp" && pwd -P)
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/room" "$tmp/pd1" "$tmp/pd2" "$tmp/stub-state" "$tmp/exp-room"

# A pipeline variable and a harness variable the sessions must not inherit.
export CC_PIPELINE_TEST_MARK=1
export SKILL_TRIGGER_TEST_MARK=1
export STUB_CLI_LOG="$tmp/cli.log"
export STUB_ENV_LOG="$tmp/env.log"
export STUB_STATE="$tmp/stub-state"
unset STUB_NO_CC STUB_COST

out=""
err=""
ec=0
# measure <scenario root> <harness args...> — the harness's stdout in $out,
# stderr in $err, exit code in $ec; the call and env logs start empty.
measure() {
  local root="$1"; shift
  : > "$STUB_CLI_LOG"; : > "$STUB_ENV_LOG"
  out=$(SKILL_TRIGGER_CLAUDE_BIN="$STUB" SKILL_TRIGGER_STATE_ROOT="$tmp/state" \
        SKILLS_ROOT="$fixtures/skills" SCENARIO_ROOT="$root" \
        bash "$H" "$@" 2> "$tmp/err")
  ec=$?
  err=$(cat "$tmp/err")
}
calls() { grep -c '^call ' "$STUB_CLI_LOG" || true; }
# row <id> <state id> — the report row of one line id.
row() { awk -F'\t' -v i="$1" '$2 == i' "$tmp/state/$2/report.tsv"; }
show() { printf '%s\n%s\n' "$out" "$err" | sed 's/^/  | /' >&2; }

S="$fixtures/scenarios"
base_args=(--model test-model --workdir "$tmp/room" --plugin-dir "$tmp/pd1" --plugin-dir "$tmp/pd2")

# --- constants and the protocol block ------------------------------------------
proto_words=$(sed -n 's/^\*\*금지어\*\*: //p' "$PROTOCOL")
script_words=$(sed -n 's/^FORBIDDEN_WORDS="\(.*\)"$/\1/p' "$H")
if [[ -n "$proto_words" && "$proto_words" == "$script_words" ]]; then
  pass "FORBIDDEN_WORDS equals the protocol's 금지어 line byte for byte"
else
  fail "FORBIDDEN_WORDS differs from the protocol's 금지어 line"
fi
if grep -qx '# Protocol: scripts/prompt-change-protocol.md' "$H"; then
  pass "protocol block first line"
else
  fail "protocol block first line missing"
fi
for r in '1 candidate surface  — ' '2 blind judge        — ' '3 compliance scoring — ' '4 fixed rule         — ' '5 noise              — ' '6 budget             — '; do
  if grep -qF "#   $r" "$H"; then pass "protocol rule line: ${r%% —*}"; else fail "protocol rule line missing: $r"; fi
done
for c in '^RUNS=3$' '^PER_CALL_USD=0\.5$' '^ARM_WORDS=""$'; do
  if grep -qE "$c" "$H"; then pass "constant $c"; else fail "constant $c missing"; fi
done

# --- usage ----------------------------------------------------------------------------
measure "$S" --budget-usd 10 "${base_args[@]:2}"
[[ "$ec" == "2" ]] && pass "no --model exits 2" || { fail "no --model (exit=$ec, expected 2)"; show; }
measure "$S" --model test-model
[[ "$ec" == "2" ]] && pass "no --budget-usd exits 2" || { fail "no --budget-usd (exit=$ec, expected 2)"; show; }
measure "$S" "${base_args[@]}" --budget-usd 10 --skill nope
[[ "$ec" == "2" ]] && pass "unknown --skill exits 2" || { fail "unknown --skill (exit=$ec, expected 2)"; show; }

# --- the scenario lint fails -----------------------------------------------------------
mkdir -p "$tmp/bad"
cp "$S"/*.tsv "$tmp/bad/"
printf '# cc-skill-triggers v0\n' > "$tmp/bad/beta.tsv"
measure "$tmp/bad" "${base_args[@]}" --budget-usd 10
if [[ "$ec" == "1" && "$(calls)" == "0" ]]; then
  pass "lint failure exits 1 with no call"
else
  fail "lint failure (exit=$ec, calls=$(calls), expected 1 and 0)"; show
fi

# --- the surface check ---------------------------------------------------------------
measure "$S" --model test-model --workdir "$tmp/exp-room" --budget-usd 10
if [[ "$ec" == "1" && "$(calls)" == "0" ]] && grep -qF "surface check: 'exp' in 작업 디렉터리 $tmp/exp-room" <<< "$err"; then
  pass "a forbidden word in the working directory exits 1 naming the word and place"
else
  fail "surface check (exit=$ec, calls=$(calls))"; show
fi

# --- dry run -------------------------------------------------------------------------------
measure "$S" "${base_args[@]}" --budget-usd 10 --dry-run
if [[ "$ec" == "0" && "$(calls)" == "0" ]] && grep -qF '호출 36회' <<< "$out" && [[ ! -d "$tmp/state" ]]; then
  pass "dry run plans 36 calls and calls nothing"
else
  fail "dry run (exit=$ec, calls=$(calls))"; show
fi

# --- the first session loads no cc-cmds skill -----------------------------------------
export STUB_NO_CC=1
measure "$S" "${base_args[@]}" --budget-usd 10 --id nocc
unset STUB_NO_CC
if [[ "$ec" == "1" && "$(calls)" == "1" ]] && grep -qF -- '--plugin-dir' <<< "$err" && [[ -n "$(ls "$tmp/state/nocc/discarded" 2>/dev/null)" ]]; then
  pass "no cc-cmds skill in the first session exits 1 after one call"
else
  fail "no cc-cmds skill (exit=$ec, calls=$(calls), expected 1 and 1)"; show
fi

# --- budget, then resume --------------------------------------------------------------------
rm -rf "$STUB_STATE"; mkdir -p "$STUB_STATE"
measure "$S" "${base_args[@]}" --budget-usd 2 --id run1
first_calls=$(calls)
if [[ "$ec" == "4" ]] && (( first_calls > 0 && first_calls < 36 )) && grep -qF '미측정(예산)' "$tmp/state/run1/report.tsv"; then
  pass "budget guard exits 4 with 미측정(예산) after $first_calls calls"
else
  fail "budget guard (exit=$ec, calls=$first_calls)"; show
fi
spent=$(awk -F'\t' '$1 == "쓴 돈" { print $2 }' "$tmp/state/run1/meta.tsv")
if awk -v s="$spent" 'BEGIN { exit !(s + 0.5 > 2 && s <= 2) }'; then
  pass "the budget stop leaves spent + one cap above the budget ($spent)"
else
  fail "budget stop spent=$spent"
fi
cp "$STUB_CLI_LOG" "$tmp/cli.first"

measure "$S" "${base_args[@]}" --budget-usd 100 --id run1
second_calls=$(calls)
if (( first_calls + second_calls == 36 )); then
  pass "resume calls only the runs not done ($first_calls + $second_calls = 36)"
else
  fail "resume (first=$first_calls, second=$second_calls, expected a sum of 36)"; show
fi
dup=$(cat "$tmp/cli.first" "$STUB_CLI_LOG" | grep '^call ' | sort | uniq -c | awk '$1 > 3')
[[ -z "$dup" ]] && pass "no utterance ran more than three times across the two calls" || fail "an utterance ran more than three times: $dup"
[[ "$ec" == "3" ]] && pass "measured with lines not 일치 exits 3" || { fail "full run exit=$ec, expected 3"; show; }

# --- the verdict goldens ---------------------------------------------------------------------
golden() {
  # golden <id> <obs1> <obs2> <obs3> <matched> <verdict>
  local want got
  want=$(printf 'alpha.tsv\t%s\t%s\t%s\t%s\t%s\t%s\t%s' "$1" "$(awk -F'\t' -v i="$1" '$1 == i { print $2 }' "$S/alpha.tsv")" "$2" "$3" "$4" "$5" "$6")
  got=$(row "$1" run1)
  if [[ "$got" == "$want" ]]; then pass "golden $1 → $6"; else fail "golden $1: got [$got], want [$want]"; fi
}
golden a1 cc-cmds:alpha cc-cmds:alpha cc-cmds:alpha 3 일치
golden a2 cc-cmds:beta cc-cmds:beta cc-cmds:beta 0 어긋남
golden a3 cc-cmds:alpha 비발동 cc-cmds:alpha 2 불안정
golden n1 비발동 비발동 비발동 3 일치
golden n2 비발동 비발동 '무효(종료 1)' 2 미측정
golden n3 '무효(목록 없음)' '무효(목록 없음)' '무효(목록 없음)' 0 미측정
if [[ "$(head -1 "$tmp/state/run1/report.tsv")" == "$(printf '파일\tid\t기대\t관측1\t관측2\t관측3\t일치\t판정')" ]]; then
  pass "report header"
else
  fail "report header: $(head -1 "$tmp/state/run1/report.tsv")"
fi
for k in '모델	test-model' 'claude --version	9.9.9 (stub)' "플러그인 디렉터리	$tmp/pd1" "플러그인 디렉터리	$tmp/pd2" "작업 디렉터리	$tmp/room"; do
  grep -qxF "$k" "$tmp/state/run1/meta.tsv" && pass "meta row: ${k%%	*}" || fail "meta row missing: $k"
done
for k in '시나리오 sha256' '시작 시각' '쓴 돈'; do
  grep -q "^${k}	." "$tmp/state/run1/meta.tsv" && pass "meta row: ${k}" || fail "meta row missing: ${k}"
done
grep -qF 'alpha.tsv a2' <<< "$out" && pass "stdout lists a line that is not 일치" || { fail "stdout does not list a2"; show; }

# --- argv, working directory and environment of a session -------------------------------
call1=$(grep -m1 '^call ' "$STUB_CLI_LOG")
for a in '--tools Skill --strict-mcp-config --no-session-persistence --max-budget-usd 0.5' \
         '--model test-model' '--output-format stream-json --verbose' \
         "--plugin-dir $tmp/pd1 --plugin-dir $tmp/pd2"; do
  grep -qF -- "$a" <<< "$call1" && pass "argv carries: $a" || fail "argv lacks: $a ($call1)"
done
if [[ "$(grep '^cwd ' "$STUB_CLI_LOG" | sort -u)" == "cwd $tmp/room" ]]; then
  pass "every session runs in the working directory"
else
  fail "session cwd: $(grep '^cwd ' "$STUB_CLI_LOG" | sort -u | tr '\n' ' ')"
fi
if grep -q '^env ' "$STUB_ENV_LOG"; then
  fail "a session inherited: $(grep '^env ' "$STUB_ENV_LOG" | sort -u | tr '\n' ' ')"
else
  pass "no SKILL_TRIGGER_, CC_PIPELINE_, SKILLS_ROOT or SCENARIO_ROOT variable reaches a session"
fi
for s in CC_CMDS_SESSION_NOTIFY CC_CMDS_SESSION_DISMISS CC_CMDS_STATUSLINE_AUTOINSTALL; do
  if [[ "$(grep "^switch $s=" "$STUB_ENV_LOG" | sort -u)" == "switch $s=0" ]]; then
    pass "switch $s is 0 in every session"
  else
    fail "switch $s: $(grep "^switch $s=" "$STUB_ENV_LOG" | sort -u | tr '\n' ' ')"
  fi
done

# --- a changed scenario set refuses to resume ---------------------------------------------
mkdir -p "$tmp/moving"
cp "$S"/*.tsv "$tmp/moving/"
measure "$tmp/moving" "${base_args[@]}" --budget-usd 2 --id run2
[[ "$ec" == "4" ]] || { fail "run2 setup (exit=$ec, expected 4)"; show; }
printf 'm4\t비발동\t베타 이웃 넷\t바뀐 집합\n' >> "$tmp/moving/beta.tsv"
measure "$tmp/moving" "${base_args[@]}" --budget-usd 100 --id run2
if [[ "$ec" == "1" && "$(calls)" == "0" ]] && grep -qF 'scenario set changed' <<< "$err"; then
  pass "resume after the scenario set changed exits 1 with no call"
else
  fail "changed set resume (exit=$ec, calls=$(calls))"; show
fi

# --- --skill measures that file only; all 일치 exits 0 --------------------------------------
measure "$S" "${base_args[@]}" --budget-usd 100 --id only-beta --skill beta
if [[ "$ec" == "0" && "$(calls)" == "18" ]] && ! grep -qF '알파' "$STUB_CLI_LOG" && [[ ! -d "$tmp/state/only-beta/alpha" ]]; then
  pass "--skill beta calls beta's 18 runs only and exits 0"
else
  fail "--skill beta (exit=$ec, calls=$(calls))"; show
fi
if [[ "$(awk -F'\t' 'NR > 1 { print $8 }' "$tmp/state/only-beta/report.tsv" | sort -u)" == "일치" ]]; then
  pass "beta's report is 일치 throughout"
else
  fail "beta's report: $(cat "$tmp/state/only-beta/report.tsv")"
fi

echo "test-skill-trigger-measure: $passed passed, $failures failed"
(( failures == 0 ))
