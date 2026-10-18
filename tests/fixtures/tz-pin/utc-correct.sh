#!/usr/bin/env bash
# Fixture: the same comparison with both sides read in UTC. It holds in every
# zone, the pinned one included. One clock read keeps an hour boundary out of
# the comparison.
set -- $(date -u '+%s %H')
[ $(( $1 / 3600 % 24 )) -eq $(( 10#$2 )) ]
