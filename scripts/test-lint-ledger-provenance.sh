#!/usr/bin/env bash
# Test scripts/lint-ledger-provenance.sh against scratch ledgers.
#
# The fixtures are built here under `mktemp -d` rather than kept under
# tests/fixtures/, because the property under test is a path PREFIX relative to
# the lint's own state root — a committed fixture would have to spell an
# absolute path that exists on no other machine.
#
# One ledger carries four shapes, and each is there to catch one regression:
#
#   (a) a `run` row whose `RUN_DIR=` is under the lint environment's state root
#       — caught if the lint stops honouring `XDG_STATE_HOME`;
#   (b) a `run` row whose `RUN_DIR=` is under a fixture's hook home — the one
#       row that must be reported;
#   (c) a `run` row and a `blocked` row carrying the string `RUN_DIR=/var/…`
#       inside another field's value — caught if the field split degrades to a
#       substring match;
#   (d) a `blocked` row whose whole field is `RUN_DIR=<outside>` — caught if the
#       `run` family filter is dropped.
#
# `XDG_STATE_HOME` is deliberately NOT `$HOME/.local/state`, so a lint that
# ignored it and fell back to `$HOME` would reject (a).

set -uo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
LINT="$script_dir/lint-ledger-provenance.sh"

W=$(mktemp -d "${TMPDIR:-/tmp}/test-lint-ledger-provenance.XXXXXX")
trap 'rm -rf "$W"' EXIT
mkdir -p "$W/home" "$W/state"
STATE_ROOT="$W/state/cc-cmds/run"

passed=0
failures=0

# lint <ledger root> — runs the lint in the scratch environment; leaves the
# exit code in `ec` and stderr in `err`.
lint() {
  err=$(LEDGER_ROOT="$1" XDG_STATE_HOME="$W/state" HOME="$W/home" \
    bash "$LINT" 2>&1 >/dev/null); ec=$?
}

check() {
  if [[ "$2" == "$3" ]]; then
    passed=$((passed + 1)); echo "PASS: $1"
  else
    failures=$((failures + 1)); echo "FAIL: $1 (got '$2', want '$3')" >&2
  fi
}

row_a="- \`run\` | 교대=0 | run-id=20260101-0000000a | 시작=2026-01-01T00:00:00Z | RUN_DIR=$STATE_ROOT/20260101-0000000a | prev=aa"
row_b="- \`run\` | 교대=0 | run-id=20260101-000000bb | 시작=2026-01-01T00:00:01Z | RUN_DIR=/var/folders/zz/T/cc-orch-test.X1/hookhome/.local/state/cc-cmds/run/20260101-000000bb | prev=bb"
row_c_run="- \`run\` | 교대=0 | run-id=20260101-000000cc | 근거=RUN_DIR=/var/folders/zz/T/elsewhere | prev=cc"
row_c_blocked="- \`blocked\` | 교대=0 | 사유=RUN_DIR=/var/folders/zz/T/elsewhere | prev=cd"
row_d="- \`blocked\` | 교대=0 | RUN_DIR=/var/folders/zz/T/outside | prev=dd"

# --- the four shapes together: exactly (b) is reported ----------------------
L1="$W/l1"; mkdir -p "$L1"
printf '%s\n' "# 파이프라인 런 보고서" "$row_a" "$row_b" "$row_c_run" "$row_c_blocked" "$row_d" \
  > "$L1/20260101-0000000a.md"
lint "$L1"
check "네 형태가 섞인 원장은 실패한다" "$ec" "1"
check "FAIL 줄은 정확히 하나다" "$(printf '%s\n' "$err" | grep -c '^FAIL:')" "1"
check "FAIL 줄이 파일명을 싣는다" "$(printf '%s\n' "$err" | grep '^FAIL:' | grep -c '20260101-0000000a\.md')" "1"
check "FAIL 줄이 (b) 의 run-id 를 싣는다" "$(printf '%s\n' "$err" | grep '^FAIL:' | grep -c 'run-id=20260101-000000bb ')" "1"

# --- without (b): clean -----------------------------------------------------
L2="$W/l2"; mkdir -p "$L2"
printf '%s\n' "$row_a" "$row_c_run" "$row_c_blocked" "$row_d" > "$L2/20260101-0000000a.md"
lint "$L2"
check "(a)·(c)·(d) 만 있는 원장은 통과한다" "$ec" "0"

# --- no ledger directory: skip, not failure ---------------------------------
lint "$W/absent"
check "원장 디렉터리가 없으면 통과한다" "$ec" "0"

# --- a file whose name is not a run id is not a ledger ----------------------
L3="$W/l3"; mkdir -p "$L3"
printf '%s\n' "$row_b" > "$L3/notes.md"
printf '%s\n' "$row_b" > "$L3/20260101-0000000a.plan.md"
lint "$L3"
check "런 id 이름이 아닌 파일의 (b) 행은 보지 않는다" "$ec" "0"

echo "test-lint-ledger-provenance: $passed passed, $failures failed"

if (( failures > 0 )); then
  exit 1
fi
exit 0
