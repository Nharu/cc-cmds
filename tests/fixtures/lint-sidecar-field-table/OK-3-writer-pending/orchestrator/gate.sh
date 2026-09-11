#!/usr/bin/env bash
# fixture — every call site is literal; the table lists one field ahead of its writer and says so
gate_append '승인' "승인 id=$id" "상태=대기" "질문 문면=$q"
