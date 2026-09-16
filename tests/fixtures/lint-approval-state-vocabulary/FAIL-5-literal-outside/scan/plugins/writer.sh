#!/usr/bin/env bash
# fixture — an approval row written with a state the vocabulary does not know
gate_append '승인' "승인 id=$id" "상태=취소" "질문 문면=$q"
