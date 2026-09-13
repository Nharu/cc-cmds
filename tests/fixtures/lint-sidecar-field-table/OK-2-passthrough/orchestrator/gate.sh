#!/usr/bin/env bash
# fixture — a pass-through call site: the table may list fields the literal keys do not show
gate_append '자율 승인' "kind=judgment" "결정=채택" "세그먼트=${seg:--}" \
  "해소 승인=${GATE_RESOLVED_APPROVAL:--}" "$@"
gate_append '자율 승인' "kind=$kind" "결정=$verb" "대상=$alias" "근거=$rationale"
