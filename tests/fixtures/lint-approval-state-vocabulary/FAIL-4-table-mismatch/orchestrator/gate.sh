#!/usr/bin/env bash
# fixture — the SOT is right; the contract row lost a token
readonly APPROVAL_STATES="대기 승인 거부 무효 기각 철회"
gate_append '승인' "승인 id=$id" "상태=대기" "질문 문면=$q"
