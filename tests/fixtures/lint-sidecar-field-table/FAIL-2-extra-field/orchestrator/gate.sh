#!/usr/bin/env bash
# fixture — every call site is literal, and the table lists a field none of them writes
gate_append 'cost' "누적 usd=$usd" "스테이지 수=$n" "관측 시각=$(now_iso)"
