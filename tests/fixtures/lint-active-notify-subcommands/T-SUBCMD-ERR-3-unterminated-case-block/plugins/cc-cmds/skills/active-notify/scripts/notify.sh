#!/usr/bin/env bash
# notify.sh {arm|fire-now|cancel} [args]
#
# The block's `esac` is indented, so the reader's terminator never matches and
# it runs to end of file. It still collects every arm on the way, which is why
# an emptiness test sees nothing wrong: the reader reached the end of the file
# rather than the end of the block, and cannot tell whether anything followed.
set -euo pipefail
subcommand="${1:-}"; shift || true

case "$subcommand" in
  arm)
    exit 0
    ;;

  fire-now)
    exit 0
    ;;

  cancel)
    exit 0
    ;;

  *)
    printf 'notify.sh: unknown subcommand "%s" (arm|fire-now|cancel)\n' "$subcommand" >&2
    exit 1
    ;;
  esac
