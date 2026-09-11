#!/usr/bin/env bash
# fixture — six tokens, but `철회` was renamed: the count is right and the token wrong
readonly APPROVAL_STATES="대기 승인 거부 무효 기각 취소"
gate_append '승인' "승인 id=$id" "상태=대기" "질문 문면=$q"
