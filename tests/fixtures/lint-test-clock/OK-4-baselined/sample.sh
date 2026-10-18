#!/usr/bin/env bash
# Fixture: hits that were already in the tree pass while the baseline lists
# them, a text that occurs twice taking two entries.
NOW=$(date -u +%s)
out=$(txn --boot-epoch "$((NOW - 10))")
out=$(txn --boot-epoch "$((NOW - 10))")
echo "$out"
