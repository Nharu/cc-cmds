#!/usr/bin/env bash
# POSITIVE CONTROL — a copy of reference-v1.sh that is WRONG on purpose.
#
# The harness runs this against the same corpus and requires the comparator to
# report it as divergent. If it comes back equivalent, the comparator is not
# comparing and the harness fails with a defect code rather than a green run.
#
# This is the only guard that tests the comparator itself. The other five all
# pass unchanged against a comparison function whose body is `return 0` — they
# check that cases were built, that classes are covered, that both verdicts
# occur and that rules fired, none of which touches the question of whether the
# comparison can detect a difference at all.
#
# THE MUTATION IS THE REVERTED FIX, not an arbitrary character. `continue`
# instead of a break on an unreadable `prev=` is exactly the defect the chain
# work closed: the row updates no `prev`, the chain re-joins across it, and a
# forged approval row splices in as intact. Choosing this mutation makes the
# control prove the specific thing worth proving — that a regression in this
# direction would be caught — where a one-character arithmetic change would only
# prove that some difference somewhere is visible.
#
# It is pinned by sha256 alongside the reference. Keeping it correct would be
# the quiet way to disable the control.
#
# Usage: bash reference-v1-mutant.sh <ledger-path> <run-id>

LEDGER="${1:?usage: reference-v1-mutant.sh <ledger> <run-id>}"
RUN_ID="${2:?usage: reference-v1-mutant.sh <ledger> <run-id>}"

reference_v1_mutant_verify() {
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
    [ -n "$want" ] || continue          # <-- THE MUTATION
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

reference_v1_mutant_verify
