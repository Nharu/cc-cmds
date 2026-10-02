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
#
# A contaminated row is history only when its own `시작=` is strictly earlier
# than the lint's `history_cutoff`, so every row that must fail is stamped at or
# after the cutoff — read from the lint itself, so moving the constant does not
# silently turn these rows into history. The cutoff cases catch a comparison
# relaxed from `<` to `<=`, a missing or malformed `시작=` let through, and a
# verdict taken per ledger instead of per row.

set -uo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
LINT="$script_dir/lint-ledger-provenance.sh"

W=$(mktemp -d "${TMPDIR:-/tmp}/test-lint-ledger-provenance.XXXXXX")
trap 'rm -rf "$W"' EXIT
mkdir -p "$W/home" "$W/state"
STATE_ROOT="$W/state/cc-cmds/run"

passed=0
failures=0

CUTOFF=$(sed -n 's/^history_cutoff="\(.*\)"$/\1/p' "$LINT")
if [[ ! "$CUTOFF" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
  echo "FAIL: 린트에서 history_cutoff 를 읽지 못했다 (got '$CUTOFF')" >&2
  exit 1
fi
EARLY="2026-01-01T00:00:00Z"
LATE="2099-12-31T23:59:59Z"
if [[ ! "$EARLY" < "$CUTOFF" || ! "$CUTOFF" < "$LATE" ]]; then
  echo "FAIL: 픽스처 시각이 절단 시각($CUTOFF)을 사이에 두지 않는다" >&2
  exit 1
fi

# lint <ledger root> — runs the lint in the scratch environment; leaves the
# exit code in `ec`, stdout in `out` and stderr in `err`.
lint() {
  err=$(LEDGER_ROOT="$1" XDG_STATE_HOME="$W/state" HOME="$W/home" \
    bash "$LINT" 2>&1 >"$W/stdout"); ec=$?
  out=$(cat "$W/stdout")
}

check() {
  if [[ "$2" == "$3" ]]; then
    passed=$((passed + 1)); echo "PASS: $1"
  else
    failures=$((failures + 1)); echo "FAIL: $1 (got '$2', want '$3')" >&2
  fi
}

row_a="- \`run\` | 교대=0 | run-id=20260101-0000000a | 시작=2026-01-01T00:00:00Z | RUN_DIR=$STATE_ROOT/20260101-0000000a | prev=aa"
row_b="- \`run\` | 교대=0 | run-id=20260101-000000bb | 시작=$LATE | RUN_DIR=/var/folders/zz/T/cc-orch-test.X1/hookhome/.local/state/cc-cmds/run/20260101-000000bb | prev=bb"
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

# --- history cutoff: judged per row by its own 시작= ------------------------
OUTSIDE="/var/folders/zz/T/cc-orch-test.X2/hookhome/.local/state/cc-cmds/run"
# contaminated <run-id> <시작 field or empty> — a `run` row outside the state root
contaminated() {
  if [[ -n "$2" ]]; then
    printf -- '- `run` | 교대=0 | run-id=%s | %s | RUN_DIR=%s/%s | prev=ee\n' "$1" "$2" "$OUTSIDE" "$1"
  else
    printf -- '- `run` | 교대=0 | run-id=%s | RUN_DIR=%s/%s | prev=ee\n' "$1" "$OUTSIDE" "$1"
  fi
}

L4="$W/l4"; mkdir -p "$L4"
contaminated 20260101-000000e1 "시작=$EARLY" > "$L4/20260101-000000e1.md"
lint "$L4"
check "절단 전 오염 행은 통과한다" "$ec" "0"
check "절단 전 오염 행은 FAIL 줄을 내지 않는다" "$(printf '%s\n' "$err" | grep -c '^FAIL:')" "0"
check "절단 전 오염 행은 파일명·run-id 를 실은 INFO 로 보고된다" \
  "$(printf '%s\n' "$out" | grep '^INFO:' | grep '20260101-000000e1\.md' | grep -c 'run-id=20260101-000000e1 ')" "1"

L5="$W/l5"; mkdir -p "$L5"
{ contaminated 20260101-000000e1 "시작=$EARLY"; contaminated 20260101-000000e1 "시작=$LATE"; } \
  > "$L5/20260101-000000e1.md"
lint "$L5"
check "이력 원장에 붙은 절단 이후 오염 행은 실패한다" "$ec" "1"
check "이력 원장에서 FAIL 은 절단 이후 행 하나뿐이다" "$(printf '%s\n' "$err" | grep -c '^FAIL:')" "1"
check "이력 원장의 FAIL 줄이 절단 이후 행의 시작= 을 싣는다" \
  "$(printf '%s\n' "$err" | grep '^FAIL:' | grep -c "시작=$LATE ")" "1"
check "이력 원장의 절단 전 행은 여전히 INFO 다" "$(printf '%s\n' "$out" | grep -c '^INFO:')" "1"

# each case below is alone in its ledger, so `ec` belongs to that one row
cutoff_case() {
  local name="$1" field="$2" dir="$W/$3"
  mkdir -p "$dir"
  contaminated 20260101-000000e2 "$field" > "$dir/20260101-000000e2.md"
  lint "$dir"
  check "$name — 실패한다" "$ec" "1"
  check "$name — FAIL 줄이 파일명·run-id 를 싣는다" \
    "$(printf '%s\n' "$err" | grep '^FAIL:' | grep '20260101-000000e2\.md' | grep -c 'run-id=20260101-000000e2 ')" "1"
  check "$name — 이력으로 보고하지 않는다" "$(printf '%s\n' "$out" | grep -c '^INFO:')" "0"
}
cutoff_case "시작= 이 절단 시각과 같은 오염 행" "시작=$CUTOFF" l6
cutoff_case "시작= 이 없는 오염 행" "" l7
cutoff_case "시작= 모양이 틀린 오염 행" "시작=2026-01-01 00:00:00" l8

echo "test-lint-ledger-provenance: $passed passed, $failures failed"

if (( failures > 0 )); then
  exit 1
fi
exit 0
