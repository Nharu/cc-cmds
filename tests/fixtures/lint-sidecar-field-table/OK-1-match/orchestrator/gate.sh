#!/usr/bin/env bash
# fixture — call sites whose literal keys match the table, one of them multi-line
gate_append 'run' "run-id=$RUN_ID" "시작=$(now_iso)" "보고서=$LEDGER"
gate_append '승인' "승인 id=$id" "상태=대기" "대상=$alias" "절단점=판단" \
  "행위 다이제스트=-" "구속 튜플=${seg:--}/$qdig/$GATE_MENU_VERSION/$(gate_tuple_snap)" \
  "막는 세그먼트=${seg:--}" "질문 문면=$q" "답변 문면=-" \
  "사이드카 앵커=$(gate_approval_sidecar_anchor "$id")" \
  "발행 시각=$(now_iso)" "해소 시각=-"
gate_append '승인' "승인 id=$id" "상태=$label" "질문 문면=$q" \
  "답변 문면=$aex" "해소 시각=$(now_iso)" \
  "응답 토큰=$tok" "답변 다이제스트=$adig" "사이드카 앵커=$anchor"
