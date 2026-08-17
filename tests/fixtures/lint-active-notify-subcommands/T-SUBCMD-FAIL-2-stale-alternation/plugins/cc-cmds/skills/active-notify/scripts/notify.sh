#!/usr/bin/env bash
# notify.sh {arm|cancel|fire-now} [args]
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
    printf 'notify.sh: unknown subcommand "%s" (arm|cancel|fire-now)\n' "$subcommand" >&2
    exit 1
    ;;
esac
