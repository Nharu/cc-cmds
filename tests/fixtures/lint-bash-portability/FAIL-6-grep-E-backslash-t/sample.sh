#!/usr/bin/env bash
# Fixture: `\t` inside a `grep -E` pattern should be detected.
#
# BSD grep matches a tab here; GNU grep warns "stray \ before t" and matches
# nothing. The failure is silent on the platform that has the bug.
set -euo pipefail

printf '1\t2\tfoo\n' | grep -oE '[0-9]+\t[0-9]+\t[^ ]+' || true
