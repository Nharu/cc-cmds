#!/usr/bin/env bash
# Fixture: `getconf ARG_MAX` used as a bound should be detected. Linux reports a
# quarter of the stack limit, so a fixture that is big on one runner is small on
# another. The check line below is test-route's before it was fixed.
set -euo pipefail

check() { [ "$2" = "$3" ] || echo "FAIL: $1" >&2; }
f=$1
rc=0
check "ARG_MAX 를 넘는 저장소로도 수집은 rc 0" "$rc/$( [ "$(wc -c < "$f")" -gt "$(getconf ARG_MAX)" ] && printf big || printf small)" "0/big"
