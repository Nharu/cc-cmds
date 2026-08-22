#!/usr/bin/env bash
# Fixture: `${var^^}` / `${var,,}` case conversion is bash 4+. On bash 3.2 the
# expansion is not an error — it silently yields the wrong string, which is
# worse than a hard failure.
set -euo pipefail

stage=s4
echo "${stage^^}"
echo "${stage,,}"
