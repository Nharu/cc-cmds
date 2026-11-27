#!/usr/bin/env bash
# Test driver for plugins/cc-cmds/hooks/witness-write-pretool.sh.
#
# Every case runs the hook on a Write payload against a witness root under its
# own temporary HOME and XDG_STATE_HOME, so nothing lands in the real state
# directory. A case passes when the hook exits 0 (never 2) and prints the allow
# decision or nothing, as the case expects.

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
hook="$repo_root/plugins/cc-cmds/hooks/witness-write-pretool.sh"
hooks_json="$repo_root/plugins/cc-cmds/hooks/hooks.json"

passed=0
failures=0
ok() { passed=$((passed + 1)); }
bad() { echo "FAIL: $1" >&2; failures=$((failures + 1)); }

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/home" "$T/xdg"
root="$T/xdg/cc-cmds/design"
wd="$root/cc-team-witness-review.B-2.Ab12Cd"
mkdir -p "$wd/partial" "$wd/prompt" "$root/elsewhere"
tok=0123456789abcdef

out=''
rc=0
# run_hook <xdg|-> <file_path> [env assignment...] — run the hook on one Write.
# `-` leaves XDG_STATE_HOME unset.
run_hook() {
  local xdg=$1 fp=$2 payload
  shift 2
  payload=$(jq -nc --arg p "$fp" '{tool_name: "Write", tool_input: {file_path: $p, content: "x"}}')
  if [[ "$xdg" == - ]]; then
    out=$(printf '%s' "$payload" | env -u CC_PIPELINE_RUN_DIR -u XDG_STATE_HOME HOME="$T/home" "$@" bash "$hook" 2>/dev/null) && rc=0 || rc=$?
  else
    out=$(printf '%s' "$payload" | env -u CC_PIPELINE_RUN_DIR HOME="$T/home" XDG_STATE_HOME="$xdg" "$@" bash "$hook" 2>/dev/null) && rc=0 || rc=$?
  fi
}

expect_allow() {
  local name=$1
  shift
  run_hook "$@"
  if [[ $rc -ne 0 ]]; then
    bad "$name — exit $rc"
    return
  fi
  if [[ "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)" == allow ]] \
    && [[ "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.hookEventName // empty' 2>/dev/null)" == PreToolUse ]]; then
    ok
  else
    bad "$name — expected an allow decision, got: $out"
  fi
}

expect_none() {
  local name=$1
  shift
  run_hook "$@"
  if [[ $rc -ne 0 ]]; then
    bad "$name — exit $rc (the hook must end 0 with no decision)"
    return
  fi
  if [[ -z "$out" ]]; then
    ok
  else
    bad "$name — expected no decision, got: $out"
  fi
}

# The two names the hook allows.
expect_allow "draft in the witness directory" "$T/xdg" "$wd/.reviewer-1.round-1.$tok"
expect_allow "checkpoint in partial" "$T/xdg" "$wd/partial/reviewer-1.round-1.seq-3.$tok.md"
expect_allow "phase-named draft" "$T/xdg" "$wd/.lead_a.synthesis-rev1.$tok"

# An existing leaf with link count 1 is still allowed; with count 2 it is not.
: > "$wd/partial/reviewer-2.round-1.seq-1.$tok.md"
expect_allow "existing checkpoint with one link" "$T/xdg" "$wd/partial/reviewer-2.round-1.seq-1.$tok.md"
: > "$wd/.reviewer-2.round-1.$tok"
ln "$wd/.reviewer-2.round-1.$tok" "$root/elsewhere/hardlink"
expect_none "existing draft with link count 2" "$T/xdg" "$wd/.reviewer-2.round-1.$tok"

# Without XDG_STATE_HOME the root is under HOME.
hwd="$T/home/.local/state/cc-cmds/design/cc-team-witness-design.xY12zZ"
mkdir -p "$hwd"
expect_allow "draft under the HOME root" - "$hwd/.critic.round-2.$tok"
expect_none "HOME root ignored while XDG_STATE_HOME is set" "$T/xdg" "$hwd/.critic.round-2.$tok"

# Names and places the hook gives no decision for.
expect_none "role brief under prompt" "$T/xdg" "$wd/prompt/reviewer-1.md"
expect_none "draft-like name under prompt" "$T/xdg" "$wd/prompt/.reviewer-1.round-1.$tok"
expect_none "published witness name" "$T/xdg" "$wd/reviewer-1.round-1.md"
expect_none "draft with .md" "$T/xdg" "$wd/.reviewer-1.round-1.$tok.md"
expect_none "draft with a short token" "$T/xdg" "$wd/.reviewer-1.round-1.0123abcd"
expect_none "draft with upper-case hex" "$T/xdg" "$wd/.reviewer-1.round-1.0123456789ABCDEF"
expect_none "draft with a colon in the role" "$T/xdg" "$wd/.re:viewer.round-1.$tok"
expect_none "checkpoint name in the witness directory" "$T/xdg" "$wd/reviewer-1.round-1.seq-3.$tok.md"
expect_none "draft name in partial" "$T/xdg" "$wd/partial/.reviewer-1.round-1.$tok"
expect_none "checkpoint without a seq number" "$T/xdg" "$wd/partial/reviewer-1.round-1.seq-.$tok.md"
expect_none "draft in a directory that is not a witness directory" "$T/xdg" "$root/elsewhere/.reviewer-1.round-1.$tok"
expect_none "draft directly under the root" "$T/xdg" "$root/.reviewer-1.round-1.$tok"
mkdir -p "$T/outside/cc-team-witness-review.Zz99Yy"
expect_none "witness directory outside the root" "$T/xdg" "$T/outside/cc-team-witness-review.Zz99Yy/.reviewer-1.round-1.$tok"
expect_none "path with a .. component" "$T/xdg" "$wd/partial/../.reviewer-1.round-1.$tok"
expect_none "relative file_path" "$T/xdg" "cc-team-witness-review.B-2.Ab12Cd/.reviewer-1.round-1.$tok"
expect_none "relative XDG_STATE_HOME" "relative/state" "$wd/.reviewer-1.round-1.$tok"
expect_none "pipeline session" "$T/xdg" "$wd/.reviewer-1.round-1.$tok" CC_PIPELINE_RUN_DIR="$T/run"

# Symbolic links: the leaf, the witness directory and partial.
: > "$T/outside/target"
ln -s "$T/outside/target" "$wd/.reviewer-3.round-1.$tok"
expect_none "symbolic link leaf" "$T/xdg" "$wd/.reviewer-3.round-1.$tok"
ln -s "$wd" "$root/cc-team-witness-review.Link01"
expect_none "symbolic link witness directory" "$T/xdg" "$root/cc-team-witness-review.Link01/.reviewer-1.round-1.$tok"
expect_none "partial under a symbolic link witness directory" "$T/xdg" "$root/cc-team-witness-review.Link01/partial/reviewer-1.round-1.seq-1.$tok.md"
wd2="$root/cc-team-witness-review.Real02"
mkdir -p "$wd2" "$root/cc-team-witness-review.Other3/partial"
ln -s "$root/cc-team-witness-review.Other3/partial" "$wd2/partial"
expect_none "symbolic link partial" "$T/xdg" "$wd2/partial/reviewer-1.round-1.seq-1.$tok.md"

# A target whose parent cannot be resolved ends 0 with no decision, not 2.
expect_none "parent directory missing" "$T/xdg" "$root/cc-team-witness-gone.Qq11Ww/.reviewer-1.round-1.$tok"
expect_none "witness root missing" "$T/nowhere" "$T/nowhere/cc-cmds/design/cc-team-witness-x.Aa00Bb/.r.round-1.$tok"
out=$(printf 'not json' | env -u CC_PIPELINE_RUN_DIR HOME="$T/home" XDG_STATE_HOME="$T/xdg" bash "$hook" 2>/dev/null) && rc=0 || rc=$?
if [[ $rc -eq 0 && -z "$out" ]]; then ok; else bad "malformed payload — exit $rc, output: $out"; fi

# The file and its registration.
if [[ -x "$hook" ]]; then ok; else bad "hook file is not executable: $hook"; fi
reg=$(jq -c '[.hooks.PreToolUse[] | select(.matcher == "Write") | .hooks[] | select(.command == "bash \"${CLAUDE_PLUGIN_ROOT}/hooks/witness-write-pretool.sh\"")]' "$hooks_json")
if [[ "$(printf '%s' "$reg" | jq 'length')" == 1 ]]; then ok; else bad "hooks.json registers the hook under PreToolUse matcher Write exactly once (got $reg)"; fi
if [[ "$(printf '%s' "$reg" | jq -r '.[0].timeout // empty')" == 5 ]]; then ok; else bad "hooks.json gives the hook timeout 5 (got $reg)"; fi
if [[ "$(printf '%s' "$reg" | jq -r '.[0].type // empty')" == command ]]; then ok; else bad "hooks.json registers the hook as a command (got $reg)"; fi

echo "witness-write-pretool-hook: $passed passed, $failures failed"
[[ $failures -eq 0 ]]
