#!/usr/bin/env bash
# Test driver for plugins/cc-cmds/hooks/test-gate-full-pretool.sh.
#
# Each case feeds the hook one Bash tool payload built with jq and checks its
# exit code and standard output: an `ask` decision for a command that runs
# test-gate with `--full`, nothing for any other command, and nothing at all
# when CC_PIPELINE_RUN_ID is set. The cases are inline; there is no fixture
# directory.

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
hook_sh="$repo_root/plugins/cc-cmds/hooks/test-gate-full-pretool.sh"

if [[ ! -x "$hook_sh" ]]; then
  echo "FAIL: hook not executable: $hook_sh" >&2
  exit 2
fi
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required" >&2; exit 2; }

passed=0
failures=0
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# run_case <name> <want: ask|empty> <run id or empty> <command>
run_case() {
  local name=$1 want=$2 run_id=$3 cmd=$4 rc=0 out decision
  jq -nc --arg c "$cmd" '{tool_name:"Bash",tool_input:{command:$c}}' > "$tmp/in.json"
  if [[ -n "$run_id" ]]; then
    env CC_PIPELINE_RUN_ID="$run_id" bash "$hook_sh" < "$tmp/in.json" > "$tmp/out" 2>"$tmp/err" || rc=$?
  else
    env -u CC_PIPELINE_RUN_ID bash "$hook_sh" < "$tmp/in.json" > "$tmp/out" 2>"$tmp/err" || rc=$?
  fi
  out=$(cat "$tmp/out")
  if [[ $rc -ne 0 ]]; then
    echo "FAIL: $name — exit $rc (want 0)"
    failures=$((failures + 1)); return
  fi
  if [[ $want == ask ]]; then
    decision=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null || true)
    if [[ $decision == ask && $(printf '%s\n' "$out" | wc -l | tr -d ' ') == 1 ]]; then
      echo "PASS: $name"; passed=$((passed + 1))
    else
      echo "FAIL: $name — want one ask line, got: $out"; failures=$((failures + 1))
    fi
  else
    if [[ -z "$out" ]]; then
      echo "PASS: $name"; passed=$((passed + 1))
    else
      echo "FAIL: $name — want empty output, got: $out"; failures=$((failures + 1))
    fi
  fi
}

# The commands are data fed to the hook, never run. The wrapped forms are built
# from `tg` so that no line of this file reads as a call of the script.
tg="bash scripts/test-gate.sh"
run_case "직접 --full 은 묻는다" ask "" "bash scripts/test-gate.sh --full"
run_case "make 로 감싼 --full 은 묻는다" ask "" "make check GATE_SUITE_CMD='$tg --full'"
run_case "하위 셸 안의 --full 은 묻는다" ask "" "($tg --full)"
run_case "좁힌 실행은 묻지 않는다" empty "" "bash scripts/test-gate.sh --sections 0a"
run_case "--full 이 경로보다 앞인 읽기는 묻지 않는다" empty "" "grep -n -- '--full' scripts/test-gate.sh"
run_case "관계없는 명령은 묻지 않는다" empty "" "ls"
run_case "무인 런 안에서는 --full 에도 비킨다" empty "x" "bash scripts/test-gate.sh --full"

echo "test-test-gate-full-pretool-hook: $passed passed, $failures failed"
[[ $failures -eq 0 ]]
