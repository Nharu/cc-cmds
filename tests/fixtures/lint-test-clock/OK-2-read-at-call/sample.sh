#!/usr/bin/env bash
# Fixture: test-snapshot after it was fixed. The wake is read off the clock at
# the call that judges it, so no anchor carries a margin.
w_now=$(date -u +%s)
w_stall=600
check "갱신이 STALL 보다 오래돼도 깨어남이 그 뒤면 구성원이고 신선하다" "$(w_fresh "$(date -u +%s)")" "[1,true]"
echo "$w_now $w_stall"
