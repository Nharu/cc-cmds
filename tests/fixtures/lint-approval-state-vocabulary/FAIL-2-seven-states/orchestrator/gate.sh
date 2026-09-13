#!/usr/bin/env bash
# fixture — seven tokens: a state arrived without this lint being told
readonly APPROVAL_STATES="대기 승인 거부 무효 기각 철회 만료"
gate_append '승인' "승인 id=$id" "상태=대기" "질문 문면=$q"
