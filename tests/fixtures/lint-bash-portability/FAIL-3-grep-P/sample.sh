#!/usr/bin/env bash
# Fixture: GNU-only `grep -P` (Perl-compat regex) should be detected.
set -euo pipefail

grep -P '\d+' /dev/null || true
