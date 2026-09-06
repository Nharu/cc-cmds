#!/usr/bin/env bash
# An argument opening with a variable is not judged — its value is not in the
# source. The dynamic argv assertions in the banner suites cover this half.
workflow="빌드"
summary="${1:-}"
terminal-notifier -title "cc-cmds ${workflow}" -message "${summary}" -execute ':'
