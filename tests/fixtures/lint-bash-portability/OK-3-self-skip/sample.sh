#!/usr/bin/env bash
# lint-bash-portability: self-skip
# Fixture: file has the self-skip sentinel within the first 5 lines, so the
# lint should skip it entirely even though it contains denylisted idioms.
set -euo pipefail

# These would normally trigger violations:
tac /etc/hostname >/dev/null 2>&1 || true
yesterday=$(date -d "yesterday")
grep -P 'foo' /dev/null || true
