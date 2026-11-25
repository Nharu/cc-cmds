#!/usr/bin/env bash
# Fixture: a baseline entry whose path only begins with the word "scripts" is
# outside scripts/ and answers its hit.
NOW=$(date -u +%s)
out=$(txn --boot-epoch "$((NOW - 10))")
echo "$out"
