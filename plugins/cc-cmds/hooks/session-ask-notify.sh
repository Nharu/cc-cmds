#!/usr/bin/env bash
#
# session-ask-notify.sh — seat 1 of the general-session banner.
#
# WHAT IT IS FOR. `AskUserQuestion` opens a dialog and the session then waits for
# a person who may be looking at a different window. This hook fires at the
# moment the dialog opens — the only moment that carries the question text — and
# puts a banner on the screen. `PreToolUse` with a literal `AskUserQuestion`
# matcher is the only event with both properties; the two alternatives were
# measured and rejected, because a permission notice arrives 6.03 s later with no
# body and the idle notice does not fire at all while a dialog is up.
#
# THE CONTRACT THIS FILE IMPLEMENTS IS WRITTEN DOWN NEXT DOOR, in README.md, and
# that file is also where the marker syntax the sibling seat anchors on lives.
#
# WHY `set -uo pipefail` AND NOT `-e`. The two sibling hooks disagree and the one
# that sorts first alphabetically uses `-euo`, so leaving this unexplained means
# the next reader copies the neighbour and reverts it. Two of the predicates
# below answer with an exit status, and for BOTH of them a normal false is status
# 1: `cc_notify_session_enabled` says 1 to the user who switched the banners off,
# and `cc_caller_is_router` says 1 inside an autopilot stage session. Under `-e`
# a bare call to either kills the hook, and it kills it only for the person or
# the environment that produced that false — so a general session's tests all
# stay green while an unattended run breaks in the middle of the night. Both
# calls are ALSO wrapped in `if !` below. That is deliberate duplication: either
# guard alone is one edit away from being undone, and wrapping only one of the
# two leaves the failure reachable exclusively from a stage session.
#
# WHY THE GATE READS `agent_id` AND NOT `agent_type`. The payload schema says so
# in as many words — "Use this field (not agent_type) to distinguish subagent
# calls from main-thread calls" — and the reason matters here. `agent_type` is
# ALSO present on a main thread started with `--agent`, so gating on it would
# kill both seats in an ordinary session with a person sitting in front of it,
# and it would fail in the direction where NO banner appears, which cannot be
# told apart from the marker simply being absent. Without this note the next
# reader concludes that reading both fields is the safer choice.
#
# EVERY PATH EXITS 0 AND NOTHING IS WRITTEN TO stdout OR stderr. A `Stop` hook
# that exits 2 stops the turn from ending at all, so the sibling seat cannot
# afford a non-zero path and this one matches it rather than growing a second
# rule. stdout is the hooks' control channel. stderr on a non-zero exit lands in
# the interactive transcript, and a user who switched the banners OFF receiving
# an error line in place of them is the worst shape this seat can take.
set -uo pipefail

# Prepend the Homebrew paths so `jq` is discoverable whatever PATH the harness
# hands down. The seam is spelled exactly as the sibling hook spells it, so a
# test can shadow the binaries. The emitter carries a prepend of its own, but it
# sits inside `cc_notify_fire` immediately before the notifier is looked up, so
# it does not reach the `jq` calls here.
if [ -z "${CC_CMDS_NOTIFY_PATH_DISABLE_PREPEND:-}" ]; then
  PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
fi

# `jq` is a hard runtime dependency — both seats parse a JSON payload on stdin —
# and a missing one makes the shell write `command not found` to STDERR, which
# the contract above forbids. Silent fail-open, the sibling hook's own two-line
# defence transplanted unchanged.
command -v jq >/dev/null 2>&1 || exit 0

input=$(cat)

# THE EMITTER IS SOURCED RATHER THAN REIMPLEMENTED. It owns the title, the group
# and the firing line, and keeping the firing line shared is what keeps
# `-execute ':'` on every banner this tree raises — a new firing point that
# assembles its own argv is how that argument was dropped once already.
#
# The path follows the existing hooks' convention, `${CLAUDE_PLUGIN_ROOT}`, with
# this file's own parent as the fallback: the variable is not set when the script
# is driven directly, and under `set -u` a bare reference would put a line on
# stderr, which is the one thing this seat may never do.
plugin_root="${CLAUDE_PLUGIN_ROOT:-}"
if [ -z "$plugin_root" ]; then
  plugin_root=$(cd "$(dirname "$0")/.." 2>/dev/null && pwd) || exit 0
fi
emitter="$plugin_root/orchestrator/notify-run.sh"
[ -f "$emitter" ] || exit 0
# shellcheck source=/dev/null
. "$emitter" >/dev/null 2>&1 || exit 0

if ! cc_notify_session_enabled; then exit 0; fi
if ! cc_caller_is_router; then exit 0; fi

# THE FIRING GATE IS TWO CONJUNCTS AND IT IS WRITTEN AS "FIRE WHEN", not as a
# suppression. The two do different jobs — this one separates a subagent from a
# main thread, the `cc_caller_is_router` call above separates a stage session
# from a router session — and stating the pair as a suppression inverts this one,
# after which a subagent is no longer filtered at all.
agent_id=$(printf '%s' "$input" | jq -r '.agent_id // empty' 2>/dev/null)
[ -z "$agent_id" ] || exit 0

# AN EMPTY SESSION ID IS REFUSED HERE BECAUSE NOTHING DOWNSTREAM CAN REFUSE IT.
# The emitter would build one group string for every session, and the prefix
# would be right, so the negative assertion that guards against a collapse into
# the autopilot slot passes on it. This is the only place it can be caught.
sid=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)
[ -n "$sid" ] || exit 0

# THE BODY IS SPLIT BY QUESTION COUNT AND THE TWO-OR-MORE ARM DROPS THE QUESTION
# TEXT. One observed payload carried three questions; every `header` was ten
# characters or fewer while the first `question` was 120, and the banner body is
# cut — so carrying only the first question would leave not one character of
# evidence that the others exist. Counting them and listing the headers fits.
body=$(printf '%s' "$input" | jq -r '
  (.tool_input.questions // []) as $q
  | ($q | length) as $n
  | if $n == 0 then "답을 기다리는 질문이 있습니다"
    elif $n == 1 then "\($q[0].header // "질문") — \($q[0].question // "")"
    else "질문 \($n)건 — " + ([$q[] | (.header // "질문")] | join(" · "))
    end' 2>/dev/null)
[ -n "$body" ] || exit 0

CC_NOTIFY_SESSION_ID="$sid"
export CC_NOTIFY_SESSION_ID
cc_notify_fire session-ask "$body" >/dev/null 2>&1
exit 0
