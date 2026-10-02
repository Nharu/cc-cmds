#!/usr/bin/env bash
#
# lint-ledger-provenance.sh — every `run` row of a run ledger names a run
# directory under the state root of the machine that reads it.
#
# A regression suite started inside a pipeline stage inherited the stage's
# `CC_PIPELINE_MANIFEST`, and the pre-tool hook its fixtures drive opened the
# REAL manifest's ledger with it. The fixture's `run` rows landed in the live
# run's ledger, and every later reader took them for the run's own. The suites
# now clear the pipeline environment at the top of the file; this lint is the
# detector for the day that guard is bypassed.
#
# THE CHECK RUNS IN THE LINT'S ENVIRONMENT, NOT THE WRITER'S. A check at write
# time cannot fire: the fixture process writes a `RUN_DIR` under its OWN sandbox
# state root, which is exactly where that process believes it should be. Read
# back in a real environment, the same value is a path under a scratch
# directory, not under `${XDG_STATE_HOME:-$HOME/.local/state}/cc-cmds/run/`.
#
# The match is a whole-field prefix test, not a fixture-name pattern: a fixture
# renamed tomorrow is still caught, and a `RUN_DIR=` string carried inside
# another field's value is not a field and is not read.
#
# Rules:
#   1. In every ledger `<8 digits>-<8 hex>.md` directly under the ledger root,
#      every `run` row whose ` | `-split fields include one beginning `RUN_DIR=`
#      has a value beginning `<state root>/`. A `run` row with no such field has
#      nothing to judge and is skipped. Rows of any other family are not read —
#      a `blocked` row carries no `RUN_DIR`, so its origin cannot be told from
#      its content.
#   2. A row that breaks rule 1 is judged by its own `시작=` field, the wall
#      clock the gate stamped when it wrote the row:
#        [info] strictly earlier than `history_cutoff` — history, reported on
#               stdout with file name and run-id, and passed;
#        [fail] equal to or later than the cutoff, no `시작=` field, or a value
#               not shaped `YYYY-MM-DDTHH:MM:SSZ`.
#      The unit is the row, not the ledger: a contaminated row appended today to
#      a ledger that already holds history still fails.
#
# Existing contaminated rows are NOT rewritten: a ledger is an append-only hash
# chain, and editing one row breaks every `prev=` after it. Without the cutoff,
# a checkout whose `docs/pipeline-run/` holds such rows would fail `make check`
# forever. The cutoff is the instant the main checkout's ledgers were measured:
# at 2026-10-02T01:25:06Z, 246 ledgers held 708 contaminated rows, across 51 of
# them, and the latest was stamped 2026-10-02T01:19:44Z. A run still driving the
# unrepaired suites keeps adding rows after that instant, and those fail.
#
# Usage: bash scripts/lint-ledger-provenance.sh
#
# Env override:
#   LEDGER_ROOT     directory scanned for run ledgers (default docs/pipeline-run)
#   XDG_STATE_HOME  state root base, as the gate resolves it
#                   (default $HOME/.local/state)
#
# Exit codes:
#   0  pass, or a silent skip because no ledger directory is present
#   1  at least one violation
#
# Compatibility: bash 3.2 (macOS) — no associative arrays, no mapfile.

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
ledger_root="${LEDGER_ROOT:-$repo_root/docs/pipeline-run}"
state_root="${XDG_STATE_HOME:-$HOME/.local/state}/cc-cmds/run"

# UTC, compared as a string: the fixed-width shape makes lexical order time order.
history_cutoff="2026-10-02T01:25:06Z"

# `docs/` is untracked, so CI and a segment worktree have no ledgers at all.
if [[ ! -d "$ledger_root" ]]; then
  echo "SKIP: $ledger_root — 원장 없음"
  exit 0
fi

# field_value <row> <key> — the value of the first ` | `-separated field that
# begins with `<key>=`, or nothing. A whole-field test: `<key>=` inside another
# field's value does not match.
field_value() {
  local rest="$1" key="$2" f
  while :; do
    case "$rest" in
      *' | '*) f="${rest%% | *}"; rest="${rest#* | }" ;;
      *) f="$rest"; rest="" ;;
    esac
    case "$f" in
      "$key="*) printf '%s' "${f#"$key="}"; return 0 ;;
    esac
    [[ -n "$rest" ]] || return 1
  done
}

fail=0
scanned=0
history=0
while IFS= read -r ledger; do
  [[ -n "$ledger" ]] || continue
  case "${ledger##*/}" in
    [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f].md) ;;
    *) continue ;;
  esac
  scanned=$((scanned + 1))
  while IFS= read -r row; do
    case "$row" in
      '- `run` | '*) ;;
      *) continue ;;
    esac
    rd=$(field_value "$row" RUN_DIR) || continue
    case "$rd" in
      "$state_root"/*) continue ;;
    esac
    rid=$(field_value "$row" run-id) || rid='(없음)'
    if ! started=$(field_value "$row" 시작); then
      echo "FAIL: $ledger — run-id=$rid RUN_DIR=$rd ; 상태 뿌리($state_root) 밖이고 시작= 이 없어 이력인지 가릴 수 없다" >&2
      fail=1
      continue
    fi
    if [[ ! "$started" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
      echo "FAIL: $ledger — run-id=$rid 시작=$started RUN_DIR=$rd ; 상태 뿌리($state_root) 밖이고 시작= 모양이 틀려 이력인지 가릴 수 없다" >&2
      fail=1
      continue
    fi
    if [[ "$started" < "$history_cutoff" ]]; then
      echo "INFO: $ledger — run-id=$rid 시작=$started ; 절단 시각($history_cutoff) 전의 오염 행 — 이력으로 통과"
      history=$((history + 1))
      continue
    fi
    echo "FAIL: $ledger — run-id=$rid 시작=$started RUN_DIR=$rd ; 린트 환경의 상태 뿌리($state_root) 아래가 아니다" >&2
    fail=1
  done < "$ledger"
done < <(find "$ledger_root" -maxdepth 1 -type f -name '*.md' | sort)

if [[ "$fail" != "0" ]]; then
  echo "lint-ledger-provenance: violations found" >&2
  exit 1
fi
echo "OK:   lint-ledger-provenance — 원장 ${scanned}개의 run 행 출처가 상태 뿌리 아래다 (이력 ${history}행)"
exit 0
