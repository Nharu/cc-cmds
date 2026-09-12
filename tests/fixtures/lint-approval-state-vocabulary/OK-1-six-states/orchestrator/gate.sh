#!/usr/bin/env bash
# fixture — the vocabulary SOT with six tokens
readonly APPROVAL_STATES="대기 승인 거부 무효 기각 철회"
gate_append '승인' "승인 id=$id" "상태=대기" "질문 문면=$q"
gate_append '승인' "승인 id=$id" "상태=$label" "질문 문면=$q"
