#!/usr/bin/env bash
# notify.sh {arm|fire-now|cancel} [args]
#
# The block's `esac` is indented. Bash accepts that, so the reader must too —
# treating it as an unterminated block was a false positive.
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
