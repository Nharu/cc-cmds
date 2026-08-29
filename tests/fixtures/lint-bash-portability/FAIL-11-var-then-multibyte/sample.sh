#!/usr/bin/env bash
# A variable reference immediately followed by a multibyte character. bash reads
# that character's first byte as part of the NAME, so the lookup fails as an
# unbound variable under `set -u` — turning a message into a crash with no text.
set -u
key="P0"
printf '%s\n' "「$key」가 필요합니다"
