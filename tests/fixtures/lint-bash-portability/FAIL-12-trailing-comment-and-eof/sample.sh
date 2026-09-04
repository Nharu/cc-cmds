#!/usr/bin/env bash
# Fixture: one violation shares its line with a trailing comment, and a second
# sits on the final line of the file with no terminating newline. Both probe the
# seam between nominating a candidate line and judging it — nomination reads the
# raw line while judgement reads the comment-stripped prefix, and the last line
# has to carry the same number under either way of counting it.
set -euo pipefail

tac /etc/hostname   # reverse the file, GNU-only
md5sum /etc/hostname