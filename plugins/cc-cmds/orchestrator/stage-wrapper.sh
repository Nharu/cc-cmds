#!/usr/bin/env bash
#
# stage-wrapper.sh — the supervisor, and its one job.
#
# Stage hook coverage today is not conditional, it is UNCONDITIONALLY ZERO: the
# spawn line carries neither `--plugin-dir` nor `--settings`, so a stage sees no
# skill body and no hook. The measured consequence is worse than a stage that
# does less — a slash command that resolves to nothing still exits 0 with
# `subtype: "success"` and `num_turns: 0`, so the driver classifies it as a
# hollow success, retries once, and parks for "no artifact". The real cause is
# recorded nowhere.
#
# This file closes that, and deliberately does nothing else. Its whole job is to
# put `--settings` (and the plugin directory) on the command line and `exec` the
# CLI. A wrapper that also decided things would be a second policy layer beside
# the gate, and the two would disagree.
#
# `--instructions <file>` is the same kind of non-decision. The gate synthesizes
# the stage instructions (its own policy plus the target repository's instruction
# chain) and this wrapper only puts them on the command line: it turns automatic
# CLAUDE.md discovery off and appends the file to the main and subagent system
# prompts IN ONE CONDITIONAL, so a stage that is switched off but not injected —
# a stage with no rules at all, ending in `subtype: "success"` — cannot be
# expressed. The reserved-flag refusal below is not a policy judgment either: a
# repeated `--append-system-prompt-file` silently lets the later one win, so a
# caller passing one after `--` would replace the policy without a trace. Both
# checks are contract-violation stops of the same kind as the required-argument
# checks — the wrapper still decides nothing.
#
# WHY IT IS A SEPARATE FILE AND WHO MAY CALL IT. `"$CLI_BIN" "$@"` is an argv
# LAUNDERING TOOL for anyone holding an allow-list entry: whatever it is handed,
# it runs. So the set of legitimate callers is stated rather than left implied —
# **only the gate.** The router is excluded for exactly that laundering reason,
# layer 1 recognizes only `gate.sh`, and the main session holds no resident
# process. That leaves the gate as the sole candidate, and `gate.sh act --kind
# skill` is the call.
#
# `--plugin-dir` and `--settings` hooks COMPOSE rather than overwrite — measured.
# Had they overwritten, passing both would have silently removed the plugin's
# existing notification hook, and nothing would have reported it.
#
# Mode A is the default and carries no FIFO: stdin is `/dev/null`, the stage
# self-terminates, and its terminal classification is read off the `result`
# line. Mode B opens a FIFO for mid-flight steering and needs a killer, because
# a `--input-format stream-json` stage has NO observed self-exit path — closing
# the write end leaves it alive twenty seconds later.
#
# Usage:
#   stage-wrapper.sh --settings <file> --plugin-dir <dir> --session-id <uuid>
#                    [--mode A|B] [--fifo <path>] [--resume <session-id>]
#                    [--instructions <file>] [--autocompact <n>]
#                    -- <cli args...>
#
# With `--instructions`, the arguments after `--` must not contain any of the
# flags the gate owns when it injects instructions (`--append-system-prompt`,
# `--append-system-prompt-file`, `--append-subagent-system-prompt`,
# `--append-subagent-system-prompt-file`, `--system-prompt`,
# `--system-prompt-file`, `--setting-sources`, `--bare`,
# `--exclude-dynamic-system-prompt-sections`, `--autocompact`), bare or in
# `<flag>=` form. Without `--instructions` the argv is byte-identical to what it
# was before the option existed.
#
# `--autocompact <n>` is the compaction window the gate read and recorded for
# this launch; the wrapper puts it on the CLI argv and nothing else. It is on
# the reserved list because a repeated flag lets the later one win silently, so
# a caller's copy after `--` would make the recorded window and the running one
# differ without a trace.
#
# Exit codes: the CLI's own, transparently — this process `exec`s in Mode A and
# is not in the exit path at all.
#
# Compatibility: bash 3.2 — no associative arrays, no mapfile, no `wait -n`.

set -uo pipefail

SETTINGS=""; PLUGIN_DIR=""; SESSION_ID=""; MODE="A"; FIFO=""; RESUME=""; INSTRUCTIONS=""; AUTOCOMPACT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --settings)   SETTINGS="$2"; shift 2 ;;
    --plugin-dir) PLUGIN_DIR="$2"; shift 2 ;;
    --session-id) SESSION_ID="$2"; shift 2 ;;
    --mode)       MODE="$2"; shift 2 ;;
    --fifo)       FIFO="$2"; shift 2 ;;
    --resume)     RESUME="$2"; shift 2 ;;
    --instructions) INSTRUCTIONS="$2"; shift 2 ;;
    --autocompact) AUTOCOMPACT="$2"; shift 2 ;;
    --)           shift; break ;;
    *) printf 'stage-wrapper: unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

# Every one of these is a hard stop rather than a warning, and the reason is the
# hollow success above: a stage launched without settings runs UNGATED and
# reports success, so a missing value here must stop the launch instead of
# degrading it. That is the whole failure mode this file exists to remove, and
# re-introducing it as a fallback would be the same bug with a nicer name.
[ -n "$SETTINGS" ]    || { printf 'stage-wrapper: --settings is required — launched without it, a stage with zero hook coverage terminates as a success\n' >&2; exit 2; }
[ -f "$SETTINGS" ]    || { printf 'stage-wrapper: settings file not found: %s\n' "$SETTINGS" >&2; exit 2; }
[ -n "$PLUGIN_DIR" ]  || { printf 'stage-wrapper: --plugin-dir is required — without it a slash command terminates as a success without ever resolving\n' >&2; exit 2; }
[ -d "$PLUGIN_DIR" ]  || { printf 'stage-wrapper: plugin directory not found: %s\n' "$PLUGIN_DIR" >&2; exit 2; }
[ -n "$SESSION_ID" ] || [ -n "$RESUME" ] \
  || { printf 'stage-wrapper: --session-id or --resume is required — the transcript is the progress oracle and there is no way to find it without an id the caller chose\n' >&2; exit 2; }
[ $# -ge 1 ]          || { printf 'stage-wrapper: CLI arguments are required after --\n' >&2; exit 2; }
# `--instructions` names the synthesized stage instructions. An absent or empty
# file is a stop for the same reason as a missing `--settings`: the launch would
# switch automatic CLAUDE.md discovery off and inject nothing, and that stage
# runs with no rules and ends as a success. The reserved flags are refused
# because the CLI lets a repeated `--append-system-prompt-file` win silently
# (rc 0), so one after `--` would replace the gate's policy without a trace.
if [ -n "$INSTRUCTIONS" ]; then
  [ -s "$INSTRUCTIONS" ] \
    || { printf 'stage-wrapper: --instructions file is missing or empty: %s\n' "$INSTRUCTIONS" >&2; exit 2; }
  for arg in "$@"; do
    case "$arg" in
      --append-system-prompt|--append-system-prompt=*|\
      --append-system-prompt-file|--append-system-prompt-file=*|\
      --append-subagent-system-prompt|--append-subagent-system-prompt=*|\
      --append-subagent-system-prompt-file|--append-subagent-system-prompt-file=*|\
      --system-prompt|--system-prompt=*|\
      --system-prompt-file|--system-prompt-file=*|\
      --setting-sources|--setting-sources=*|\
      --bare|--bare=*|\
      --autocompact|--autocompact=*|\
      --exclude-dynamic-system-prompt-sections|--exclude-dynamic-system-prompt-sections=*)
        printf 'stage-wrapper: reserved flag after --: %s (the gate owns the system prompt when --instructions is given)\n' "$arg" >&2
        exit 2 ;;
    esac
  done
fi
# The mode belongs HERE and not at the dispatch below. Validated late, an
# unknown mode was reported as "binary not found" on a machine with no CLI —
# the same masking the resolution order above exists to remove.
case "$MODE" in
  A|B) : ;;
  *) printf 'stage-wrapper: unknown mode: %s (A|B)\n' "$MODE" >&2; exit 2 ;;
esac
[ "$MODE" = "B" ] && [ -z "$FIFO" ] \
  && { printf 'stage-wrapper: Mode B requires --fifo\n' >&2; exit 2; }

# The CLI is resolved AFTER the arguments are validated. Resolving first meant a
# machine with no `claude` on PATH reported "binary not found" for an invocation
# whose real defect was a missing `--settings` — the environment lookup masked
# the contract violation, and the contract violation is the one that silently
# produces an ungated stage.
CLI_BIN="${CC_CLAUDE_BIN:-}"
[ -n "$CLI_BIN" ] || CLI_BIN=$(command -v claude 2>/dev/null || true)
[ -n "$CLI_BIN" ] || { printf 'stage-wrapper: CLI binary not found\n' >&2; exit 127; }

# `--resume` CONTINUES a turn rather than restarting one, and the two are not
# interchangeable: a stage that stopped to ask has already done its work up to
# that point, and re-running it would redo that work and arrive at the same
# question. It is also the relay mechanism itself — the supervisor's termination
# rule (close the holder on `result`) is incompatible with a stage that ends its
# turn in order to ask, so the answer goes back by re-dispatch rather than
# through a FIFO. That keeps the relay off the transport layer's critical path
# and makes it a feature of Mode A.
#
# `--session-id` and `--resume` are mutually exclusive: the first names a NEW
# session, the second names an existing one.
#
# The instruction injection and the discovery switch-off live in ONE
# conditional on both branches. `CLAUDE_CODE_DISABLE_CLAUDE_MDS=1` reaches every
# agent the stage spawns, so a stage that is switched off without being injected
# would leave its team with no rules either; keeping the two in one `if` makes
# that state unexpressible. `--append-system-prompt-file` reaches only the main
# session and `--append-subagent-system-prompt-file` reaches the Agent-tool
# members, so both carry the same file. `--exclude-dynamic-system-prompt-sections`
# moves the per-machine sections (cwd, git status) out of the system prompt so
# the injected block stays cacheable across stages. Automatic memory is left on:
# only CLAUDE.md discovery is switched off here.
#
# The two NON-injecting branches `unset` the switch instead of letting it be
# inherited, and that is what keeps the unexpressible state unexpressible on the
# other channel. The injecting branches `export` it and `exec` the CLI, which
# hands its own environment to everything it spawns; a seat launched that way
# passes the variable down to an old-style resume it dispatches, and that resume
# expands no `--append-...` flag at all. Without the unset it would run with
# discovery off and nothing appended — the measured "neither one visible" state,
# arriving through the environment rather than through argv.
#
# It is unset INSIDE the two branches rather than at the head of this file on
# purpose. `stage-policy.md` says an agent started some other way (a `claude -p`
# from a script, a Workflow) receives neither the policy nor the target's
# CLAUDE.md, and part of why that is true today is this very inheritance. A
# head-of-file unset would make that sentence false in one direction by letting
# such a child silently read the target's CLAUDE.md instead.
#
# The window rides on every branch the same way: `${AUTOCOMPACT:+…}` expands to
# the flag and its value when the gate passed one and to no word at all when it
# did not, so a launch without a window is byte-identical to one before the
# option existed.
if [ -n "$RESUME" ]; then
  if [ -n "$INSTRUCTIONS" ]; then
    export CLAUDE_CODE_DISABLE_CLAUDE_MDS=1
    set -- --settings "$SETTINGS" --plugin-dir "$PLUGIN_DIR" \
           -r "$RESUME" --strict-mcp-config \
           ${AUTOCOMPACT:+--autocompact "$AUTOCOMPACT"} \
           --append-system-prompt-file "$INSTRUCTIONS" \
           --append-subagent-system-prompt-file "$INSTRUCTIONS" \
           --exclude-dynamic-system-prompt-sections "$@"
  else
    unset CLAUDE_CODE_DISABLE_CLAUDE_MDS
    set -- --settings "$SETTINGS" --plugin-dir "$PLUGIN_DIR" \
           -r "$RESUME" --strict-mcp-config \
           ${AUTOCOMPACT:+--autocompact "$AUTOCOMPACT"} "$@"
  fi
else
  if [ -n "$INSTRUCTIONS" ]; then
    export CLAUDE_CODE_DISABLE_CLAUDE_MDS=1
    set -- --settings "$SETTINGS" --plugin-dir "$PLUGIN_DIR" \
           --session-id "$SESSION_ID" --strict-mcp-config \
           ${AUTOCOMPACT:+--autocompact "$AUTOCOMPACT"} \
           --append-system-prompt-file "$INSTRUCTIONS" \
           --append-subagent-system-prompt-file "$INSTRUCTIONS" \
           --exclude-dynamic-system-prompt-sections "$@"
  else
    unset CLAUDE_CODE_DISABLE_CLAUDE_MDS
    set -- --settings "$SETTINGS" --plugin-dir "$PLUGIN_DIR" \
           --session-id "$SESSION_ID" --strict-mcp-config \
           ${AUTOCOMPACT:+--autocompact "$AUTOCOMPACT"} "$@"
  fi
fi

case "$MODE" in
  A)
    # `exec` so the CLI inherits this pid and process group. A shell that stayed
    # in the middle would give the driver a handle on the wrapper rather than on
    # the thing it needs to reclaim.
    #
    # `--include-partial-messages` is deliberately absent: it multiplies the
    # stream volume for a stage nobody is watching character by character, and
    # the terminal classification is read off the `result` line either way.
    exec "$CLI_BIN" --output-format stream-json --verbose "$@" < /dev/null
    ;;
  B)
    [ -p "$FIFO" ] || mkfifo "$FIFO" || { printf 'stage-wrapper: could not create FIFO: %s\n' "$FIFO" >&2; exit 2; }
    # NOT `exec`. Mode B has no observed self-exit path — closing the write end
    # leaves the stage alive twenty seconds later — so a killer has to remain in
    # the exit path. `--replay-user-messages` echoes an injected frame back, and
    # that echo is the only evidence a mid-flight instruction was received.
    "$CLI_BIN" --output-format stream-json --verbose \
               --input-format stream-json --replay-user-messages "$@" \
               < "$FIFO" &
    cli_pid=$!
    trap 'kill -TERM "$cli_pid" 2>/dev/null' TERM INT
    wait "$cli_pid"
    rc=$?
    # A stage that has stopped producing is killed rather than waited on: the
    # driver's stall oracle is `kill -0` on a recorded pid, and leaving a
    # never-exiting process behind makes that oracle answer "alive" forever.
    kill -0 "$cli_pid" 2>/dev/null && kill -TERM "$cli_pid" 2>/dev/null
    exit "$rc"
    ;;
esac
