#!/usr/bin/env bash
# Fixture: an assertion that takes local time for UTC — the local hour is
# compared with the UTC hour of the same instant. It holds on a UTC host, which
# is what CI's runners were, and fails under the pinned zone. One clock read
# keeps an hour boundary out of the comparison.
set -- $(date '+%s %H')
[ $(( $1 / 3600 % 24 )) -eq $(( 10#$2 )) ]
