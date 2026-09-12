#!/usr/bin/env bash
# fixture — five tokens: `철회` was dropped from the SOT
readonly APPROVAL_STATES="대기 승인 거부 무효 기각"
gate_append '승인' "승인 id=$id" "상태=대기" "질문 문면=$q"
