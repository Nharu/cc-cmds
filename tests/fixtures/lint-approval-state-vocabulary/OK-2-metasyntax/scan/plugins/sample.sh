#!/usr/bin/env bash
# fixture — a schema placeholder and a printf slot in an approval-row context
printf -- '- `승인` | 승인 id=<id> | 상태=<대기|승인> | prev=x\n'
printf -- '- `승인` | 승인 id=%s | 상태=%s | prev=x\n' "$a" "대기"
