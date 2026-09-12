#!/usr/bin/env bash
# lint-bash-portability: self-skip
#
# lint-reap-retention.sh — the state-directory retention floor has one value.
#
# The reaper deletes run directories on a schedule, and the number that decides
# WHICH ones is the only one of its four constants that gets restated outside
# its declaration: once in the reaper's own prose, and again in the gate suite's
# fixtures, which have to place a run on each side of the threshold. The other
# three (the per-cycle cap, the wall-clock budget, the minimum interval) correct
# themselves when wrong — too low a cap leaves work for the next cycle, too
# tight a budget ends the pass early, too long an interval only delays it. This
# one does not: set it wrong and state is deleted early, with nothing to read
# afterwards that would say so.
#
# So this lint does not pin a literal. It EXTRACTS the value from the gate — the
# single source of truth, the code that actually refuses to delete — and checks
# the two places that could disagree with it. That is the shape
# `lint-ledger-row-length.sh` uses for the row cap, and it is used here for the
# same reason.
#
# Rules:
#   1. [exit 2] `gate.sh` declares `readonly GATE_REAP_RETENTION=<n>` exactly
#      once. Zero declarations and two declarations are both "there is no single
#      source of truth", which is not a verdict about the consumers.
#   2. [fail] The gate suite does not re-type `<n>` as a bare integer. A fixture
#      that needs the threshold extracts it from `gate.sh` with the same idiom
#      this lint uses; a hand-typed copy is exactly the second spelling the
#      declaration exists to prevent.
#   3. [fail] The reaper's prose restates the floor in DAYS, and that day count
#      equals `<n> / 86400`. The restatement is required rather than merely
#      checked: deleting the sentence would otherwise be a way to pass.
#
# Usage: bash scripts/lint-reap-retention.sh
#
# Env override:
#   ORCH_ROOT     orchestrator directory (default plugins/cc-cmds/orchestrator)
#   SCRIPTS_ROOT  scripts directory (default the directory holding this file)
#
# Exit codes:
#   0  pass, or a silent skip because the mechanism is not present
#   1  at least one violation
#   2  the gate is present and declares no single retention floor
#
# Compatibility: bash 3.2 (macOS) — no associative arrays, no mapfile.

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
orch_root="${ORCH_ROOT:-$repo_root/plugins/cc-cmds/orchestrator}"
scripts_root="${SCRIPTS_ROOT:-$script_dir}"

GATE="$orch_root/gate.sh"

if [[ ! -f "$GATE" ]]; then
  echo "SKIP: gate.sh not found under $orch_root — reap mechanism not present"
  exit 0
fi

fail=0

# --- Rule 1: extract the SOT ------------------------------------------------
#
# The anchor is the WHOLE LINE. A trailing comment or a second statement on that
# line would not match, which is deliberate: the declaration has to stay in the
# one shape this extraction can read, and a silent non-match here surfaces as
# "no source of truth" rather than as a wrong number.
retention=$(sed -n 's/^readonly GATE_REAP_RETENTION=\([0-9][0-9]*\)$/\1/p' "$GATE")
count=$(printf '%s\n' "$retention" | grep -c . || true)

if [[ -z "$retention" ]]; then
  echo "FAIL: gate.sh — readonly GATE_REAP_RETENTION=<n> 를 찾지 못했다 (보존 기준 SOT 부재)" >&2
  exit 2
fi
if [[ "$count" != "1" ]]; then
  echo "FAIL: gate.sh — GATE_REAP_RETENTION 선언이 ${count}개다 ; 정확히 하나여야 SOT 가 성립한다" >&2
  exit 2
fi
echo "OK:   gate.sh — 회수 보존 기준 SOT = ${retention}초"

# --- Rule 2: the suite does not re-type the number ---------------------------
SUITE="$scripts_root/test-gate.sh"

if [[ ! -f "$SUITE" ]]; then
  echo "SKIP: test-gate.sh — not present"
elif grep -qE "(^|[^0-9])${retention}([^0-9]|$)" "$SUITE"; then
  echo "FAIL: $SUITE — 보존 기준 ${retention} 이 맨 정수로 다시 적혀 있다 ; 픽스처는 gate.sh 선언에서 뽑아 써야 한다" >&2
  fail=1
else
  echo "OK:   test-gate.sh — 보존 기준을 손으로 다시 적지 않는다"
fi

# --- Rule 3: the prose restatement agrees ------------------------------------
want_days=$((retention / 86400))
if [[ $((want_days * 86400)) != "$retention" ]]; then
  echo "FAIL: gate.sh — 보존 기준 ${retention}초가 온전한 일수가 아니라 산문 재진술과 대조할 수 없다" >&2
  fail=1
else
  said=$(sed -n 's/.*보존 기준 \([0-9][0-9]*\)일.*/\1/p' "$GATE")
  if [[ -z "$said" ]]; then
    echo "FAIL: gate.sh — 「보존 기준 <n>일」 재진술이 없다 ; 재진술을 지우는 것으로 이 검사를 피할 수 없다" >&2
    fail=1
  else
    bad=0
    while IFS= read -r n; do
      [[ -n "$n" ]] || continue
      if [[ "$n" != "$want_days" ]]; then
        echo "FAIL: gate.sh — 산문이 보존 기준을 ${n}일이라 적었으나 선언은 ${want_days}일(${retention}초)이다" >&2
        bad=1
      fi
    done <<< "$said"
    if [[ "$bad" = "0" ]]; then
      echo "OK:   gate.sh — 산문 재진술 ${want_days}일이 선언과 일치한다"
    else
      fail=1
    fi
  fi
fi

if [[ "$fail" != "0" ]]; then
  echo "lint-reap-retention: violations found" >&2
  exit 1
fi
exit 0
