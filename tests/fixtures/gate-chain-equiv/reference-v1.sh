#!/usr/bin/env bash
# FROZEN REFERENCE v1 — the ledger chain verdict, as of the commit that made an
# unreadable `prev=` a break.
#
# This is a VENDORED COPY, on purpose, and it is not maintained. Slices B and C
# rewrite `gate_chain_verify` itself, so the live function cannot be its own
# reference — a candidate compared against itself is equivalent by construction.
# What every later slice proves is "same verdict as v1", and v1 has to sit still
# for that sentence to mean anything.
#
# It is pinned by sha256 in scripts/test-gate-chain-equiv.sh. The attack the pin
# refuses is the cheap one: a slice whose diff comes out divergent, fixed by
# editing the reference until it agrees.
#
# THERE IS NO v2. B, C and anything after them all prove against this same file.
# Re-vendoring after each slice would let a regression enter in one slice and
# become the baseline for the next.
#
# Verdict protocol — stdout is unused; stderr carries the reason; the exit code
# carries intact-vs-broken. The two sentences are byte-identical to the live
# function's so a stderr comparison is meaningful after the timestamp prefix its
# `warn` adds is normalized away.
#
# Usage: bash reference-v1.sh <ledger-path> <run-id>
#   exit 0 — chain intact
#   exit 1 — chain broken, or not verifiable

LEDGER="${1:?usage: reference-v1.sh <ledger> <run-id>}"
RUN_ID="${2:?usage: reference-v1.sh <ledger> <run-id>}"

reference_v1_verify() {
  local prev line n=0 broke=0 want unreadable=0
  if [ ! -f "$LEDGER" ]; then
    printf '원장 파일이 없어 해시 체인을 검증하지 못했습니다 — 무결이 아니라 미검증입니다: %s\n' "$LEDGER" >&2
    return 1
  fi
  prev=$(printf '%s' "## 실행 $RUN_ID" | shasum -a 256 | cut -d' ' -f1)
  while IFS= read -r line; do
    case "$line" in '- `'*) ;; *) continue ;; esac
    n=$((n + 1))
    want=$(printf '%s' "$line" | sed -n 's/.*| prev=\([0-9a-f]*\)$/\1/p')
    if [ -z "$want" ]; then broke=$n; unreadable=1; break; fi
    if [ "$want" != "$prev" ]; then broke=$n; break; fi
    prev=$(printf '%s' "$line" | shasum -a 256 | cut -d' ' -f1)
  done < "$LEDGER"
  [ "$broke" = "0" ] && return 0
  if [ "$unreadable" = "1" ]; then
    printf '원장 해시 체인이 %s번째 행에서 끊겼습니다 — 그 행의 prev= 를 읽을 수 없습니다 (필드가 없거나 hex 가 아니거나 무효 바이트가 섞였습니다)\n' "$broke" >&2
  else
    printf '원장 해시 체인이 %s번째 행에서 끊겼습니다 — 스플라이스·삭제·재배열 중 하나입니다\n' "$broke" >&2
  fi
  return 1
}

reference_v1_verify
