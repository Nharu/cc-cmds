#!/usr/bin/env bash
# fixture — a call site writes `처분 사유`, which the table row does not list
gate_append '승인' "승인 id=$id" "상태=대기" "절단점=$cutp" \
  "처분 사유=$reason" "응답 토큰=$tok" "관측 시각=$(now_iso)"
