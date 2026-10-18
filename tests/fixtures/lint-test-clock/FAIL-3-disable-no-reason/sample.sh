#!/usr/bin/env bash
# Fixture: a disable comment that gives no reason suppresses nothing and is a
# failure of its own, on the same line and on the line above.
now=$(date -u +%s)
later=$((now + 5)) # lint-test-clock: disable=clock-margin
# lint-test-clock: disable=clock-margin
sooner=$((now - 5))
echo "$later $sooner"
