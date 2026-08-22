#!/usr/bin/env bash
# A scanned file that carries no call site at all. It must not move a reported
# number: the file count used to rise with it while the run stayed at exit 0.
set -euo pipefail
echo "no call sites here"
