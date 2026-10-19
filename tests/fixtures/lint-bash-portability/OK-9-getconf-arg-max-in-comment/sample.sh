#!/usr/bin/env bash
# Fixture: a comment that names the idiom is not a use of it. This is how
# test-route explains its fixed bound, and the comment-line skip keeps it quiet.
set -euo pipefail

  # 기준은 고정값이다. `getconf ARG_MAX` 는 Linux 에서 스택 한도의 1/4 이라
f=${1:-/dev/null}
[ "$(wc -c < "$f")" -gt 2097152 ] && echo big || echo small
