#!/usr/bin/env bash
# fixture — every metasyntactic shape a real tree writes next to `승인 id=`
readonly APPROVAL_STATES="대기 승인 거부 무효 기각 철회"
gate_append '승인' "승인 id=$id" "상태=$label" "질문 문면=$q"
printf -- '- `승인` | 승인 id=%s | 상태=%s | prev=x\n' "$a" "$st"
row=$(printf '%s' "$row" | grep -F "승인 id=$1 " | sed -n 's/^ *상태=//p')
printf -- '- `승인` | 승인 id=X | 상태=- | 질문 문면=<질문> | prev=x\n'
