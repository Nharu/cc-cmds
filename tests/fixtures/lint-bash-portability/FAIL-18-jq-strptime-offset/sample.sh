#!/usr/bin/env bash
# Fixture: jq `strptime` handed `%z` should be detected. glibc reads the offset
# and discards it while macOS keeps it, so the same interval came out nine hours
# apart on the two hosts. The line below is test-rekick's before it was fixed.
set -euo pipefail

iv() { jq -rn --arg d "$1" --arg k "$2" 'def e(s): s | sub("Z$"; "+00:00") | sub("(?<g>[+-])(?<h>[0-9]{2}):(?<m>[0-9]{2})$"; "\(.g)\(.h)\(.m)") | strptime("%Y-%m-%dT%H:%M:%S%z") | mktime; e($d) - e($k)' 2>/dev/null; }
iv 2030-01-01T00:00:00+09:00 2026-10-01T00:00:00Z
