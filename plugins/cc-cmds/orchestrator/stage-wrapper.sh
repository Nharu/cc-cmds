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
#                    -- <cli args...>
#
# Exit codes: the CLI's own, transparently — this process `exec`s in Mode A and
# is not in the exit path at all.
#
# Compatibility: bash 3.2 — no associative arrays, no mapfile, no `wait -n`.

set -uo pipefail

SETTINGS=""; PLUGIN_DIR=""; SESSION_ID=""; MODE="A"; FIFO=""; RESUME=""
while [ $# -gt 0 ]; do
  case "$1" in
    --settings)   SETTINGS="$2"; shift 2 ;;
    --plugin-dir) PLUGIN_DIR="$2"; shift 2 ;;
    --session-id) SESSION_ID="$2"; shift 2 ;;
    --mode)       MODE="$2"; shift 2 ;;
    --fifo)       FIFO="$2"; shift 2 ;;
    --resume)     RESUME="$2"; shift 2 ;;
    --)           shift; break ;;
    *) printf 'stage-wrapper: 알 수 없는 인자: %s\n' "$1" >&2; exit 2 ;;
  esac
done

# Every one of these is a hard stop rather than a warning, and the reason is the
# hollow success above: a stage launched without settings runs UNGATED and
# reports success, so a missing value here must stop the launch instead of
# degrading it. That is the whole failure mode this file exists to remove, and
# re-introducing it as a fallback would be the same bug with a nicer name.
[ -n "$SETTINGS" ]    || { printf 'stage-wrapper: --settings 는 필수입니다 — 없이 띄우면 훅 커버리지가 0 인 스테이지가 성공으로 종단합니다\n' >&2; exit 2; }
[ -f "$SETTINGS" ]    || { printf 'stage-wrapper: 설정 파일이 없습니다: %s\n' "$SETTINGS" >&2; exit 2; }
[ -n "$PLUGIN_DIR" ]  || { printf 'stage-wrapper: --plugin-dir 는 필수입니다 — 없으면 슬래시 커맨드가 해소되지 않은 채 성공으로 종단합니다\n' >&2; exit 2; }
[ -d "$PLUGIN_DIR" ]  || { printf 'stage-wrapper: 플러그인 디렉터리가 없습니다: %s\n' "$PLUGIN_DIR" >&2; exit 2; }
[ -n "$SESSION_ID" ] || [ -n "$RESUME" ] \
  || { printf 'stage-wrapper: --session-id 또는 --resume 이 필요합니다 — 트랜스크립트가 진행 오라클이고, 호출자가 고른 id 없이는 찾을 방법이 없습니다\n' >&2; exit 2; }
[ $# -ge 1 ]          || { printf 'stage-wrapper: -- 뒤에 CLI 인자가 필요합니다\n' >&2; exit 2; }
# The mode belongs HERE and not at the dispatch below. Validated late, an
# unknown mode was reported as "binary not found" on a machine with no CLI —
# the same masking the resolution order above exists to remove.
case "$MODE" in
  A|B) : ;;
  *) printf 'stage-wrapper: 알 수 없는 모드: %s (A|B)\n' "$MODE" >&2; exit 2 ;;
esac
[ "$MODE" = "B" ] && [ -z "$FIFO" ] \
  && { printf 'stage-wrapper: Mode B 는 --fifo 가 필요합니다\n' >&2; exit 2; }

# The CLI is resolved AFTER the arguments are validated. Resolving first meant a
# machine with no `claude` on PATH reported "binary not found" for an invocation
# whose real defect was a missing `--settings` — the environment lookup masked
# the contract violation, and the contract violation is the one that silently
# produces an ungated stage.
CLI_BIN="${CC_CLAUDE_BIN:-}"
[ -n "$CLI_BIN" ] || CLI_BIN=$(command -v claude 2>/dev/null || true)
[ -n "$CLI_BIN" ] || { printf 'stage-wrapper: CLI 바이너리를 찾지 못했습니다\n' >&2; exit 127; }

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
if [ -n "$RESUME" ]; then
  set -- --settings "$SETTINGS" --plugin-dir "$PLUGIN_DIR" \
         -r "$RESUME" --strict-mcp-config "$@"
else
  set -- --settings "$SETTINGS" --plugin-dir "$PLUGIN_DIR" \
         --session-id "$SESSION_ID" --strict-mcp-config "$@"
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
    [ -p "$FIFO" ] || mkfifo "$FIFO" || { printf 'stage-wrapper: FIFO 를 만들지 못했습니다: %s\n' "$FIFO" >&2; exit 2; }
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
