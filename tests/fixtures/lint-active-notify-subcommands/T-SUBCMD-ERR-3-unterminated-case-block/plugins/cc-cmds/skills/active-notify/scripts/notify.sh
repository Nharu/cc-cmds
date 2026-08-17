#!/usr/bin/env bash
# notify.sh {arm|fire-now|cancel} [args]
#
# The block has no `esac` at all, so the reader reaches end of file with the
# block still open. An emptiness test sees nothing wrong — every arm was
# collected on the way — but the reader cannot tell whether anything followed
# the last arm it read.
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
