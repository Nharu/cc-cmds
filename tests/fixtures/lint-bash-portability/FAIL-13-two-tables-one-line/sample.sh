#!/usr/bin/env bash
# Fixture: a single line that both denylist tables nominate — a GNU-only command
# and an unbraced variable followed by a multibyte character. The two tables are
# scanned separately, so this line is nominated twice and de-duplicated by line
# number; it must still report both idioms rather than collapsing to one.
set -u
name="hosts"
tac "/etc/$name「보관」"
