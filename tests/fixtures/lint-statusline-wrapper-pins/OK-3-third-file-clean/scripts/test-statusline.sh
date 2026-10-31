#!/usr/bin/env bash
# Fixture stand-in for the suite's hand-written copies of the wrapper grammar.
# This is one of exactly two files licensed to hold one; the lint's third check
# is what keeps that set from growing.
f1_cmd="[ -x \"$SL\" ] && exec bash \"$SL\" || printf 'PRE-APPLY-LITERAL'"
for v in "\"$OLDSL\"" "bash \"$OLDSL\"" "sh $OLDSL" "exec bash $OLDSL" "$OLDSL"; do :; done
