#!/usr/bin/env bash
# Fixture: a wake pinned five seconds inside the window at the time `w_now` was
# read — test-snapshot before it was fixed. The snapshots that run between the
# read and the judgement eat the margin on a slow runner.
w_now=$(date -u +%s)
w_stall=600
check "갱신이 STALL 보다 오래돼도 깨어남이 그 뒤면 구성원이고 신선하다" "$(w_fresh "$((w_now - w_stall + 5))")" "[1,true]"
