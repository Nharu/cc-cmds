#!/usr/bin/env bash
#
# stage-values-sessionstart.sh — hand an unattended stage its pipeline values
# at session start, so the lead does not spend a request per value reading
# them back through the gate.
#
# WHAT IT IS FOR. Every Bash call of an unattended stage goes through
# `gate.sh exec`, and a value read with `printenv CC_PIPELINE_<NAME>` costs one
# model request and one ledger row each. The values are fixed for the life of
# a stage attempt, so this `SessionStart` hook prints them once as
# `additionalContext`, and the stage policy tells the lead to take them from
# the last such block before falling back to `printenv`.
#
# THE CONTRACT THIS FILE IMPLEMENTS IS WRITTEN DOWN NEXT DOOR, in README.md.
#
# OUTSIDE A PIPELINE IT IS SILENT. With `CC_PIPELINE_RUN_ID` unset or empty it
# writes nothing and exits 0: a general session has no pipeline values.
#
# THE NAMES ARE A FIXED ALLOW-LIST, NEVER A SCAN OF THE ENVIRONMENT. The stage
# environment also holds the pipeline token and the grant path, and a block
# that walked the environment would copy them into the model's context. Only
# the twelve names below and the three values derived from them are printed;
# `CC_PIPELINE_GRANT`, the token and every other variable never are.
#
# IT IS REGISTERED FOR `startup|resume|compact`. A resume starts the session
# again with a new attempt's environment, so the stage id changes; a compaction
# drops the earlier block from the context. The block therefore says the last
# one is the current one.
#
# STDOUT IS THE CONTEXT CHANNEL, AND ONLY FOR THE ONE JSON OBJECT. Nothing
# reaches stderr, and every path exits 0 — a hook that failed a session start
# would cost the stage more than the requests it saves.
set -uo pipefail

[ -n "${CC_PIPELINE_RUN_ID:-}" ] || exit 0

# Prepend the Homebrew paths so `jq` is discoverable whatever PATH the harness
# hands down, spelled as the sibling hooks spell it so a test can shadow it.
if [ -z "${CC_CMDS_NOTIFY_PATH_DISABLE_PREPEND:-}" ]; then
  PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
fi
command -v jq >/dev/null 2>&1 || exit 0

# The event payload carries nothing this hook needs; it is read and dropped so
# the harness never sees a closed pipe.
cat >/dev/null 2>&1 || true

none='(없음)'
names="CC_PIPELINE_RUN_ID CC_PIPELINE_RUN_DIR CC_PIPELINE_MANIFEST CC_PIPELINE_LEDGER CC_PIPELINE_GATE CC_PIPELINE_TARGET CC_PIPELINE_SEGMENT CC_PIPELINE_STAGE_ID CC_PIPELINE_SHIFT_ID CC_PIPELINE_HALT_ANSWER CC_PIPELINE_REENTRY_CARD CC_PIPELINE_AUDIT_PASS"

stage_id="${CC_PIPELINE_STAGE_ID:-}"
who="$stage_id"
[ -n "$who" ] || who="${CC_PIPELINE_SHIFT_ID:-}"
[ -n "$who" ] || who="$none"

# The working-copy prefix is spelled the way the gate's run-local proof
# accepts it: the temporary directory with its trailing slashes taken off,
# then `cc-proto-<run id>-<stage key>.`. A routing shift has no stage id and
# makes no working copy, so both derived values read `(없음)` there.
plugin_root="${CLAUDE_PLUGIN_ROOT:-}"
[ -n "$plugin_root" ] || plugin_root="$none"
stage_key="$none"
proto_prefix="$none"
if [ -n "$stage_id" ]; then
  stage_key="${stage_id//#/-}"
  tdir="${TMPDIR:-/tmp}"
  while [ "${tdir%/}" != "$tdir" ]; do
    tdir="${tdir%/}"
  done
  proto_prefix="$tdir/cc-proto-$CC_PIPELINE_RUN_ID-$stage_key."
fi

block="[cc-stage-values] 파이프라인 값($who, 세션 시작 시점) — 이 값을 printenv 대신 쓴다. 블록이 여럿이면 마지막 블록을 쓴다"
for n in $names; do
  v="${!n:-}"
  [ -n "$v" ] || v="$none"
  block="$block
$n=$v"
done
block="$block
CLAUDE_PLUGIN_ROOT=$plugin_root
stage key=$stage_key
working-copy prefix=$proto_prefix"

jq -cn --arg c "$block" \
  '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $c}}' 2>/dev/null
exit 0
