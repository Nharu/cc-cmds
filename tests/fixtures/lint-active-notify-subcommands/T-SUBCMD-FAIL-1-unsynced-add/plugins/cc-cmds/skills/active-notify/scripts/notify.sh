#!/usr/bin/env bash
# notify.sh {arm|fire-now|cancel} [args]
set -euo pipefail
subcommand="${1:-}"; shift || true

case "$subcommand" in
  arm)
    exit 0
    ;;

  fire-now)
    exit 0
    ;;

  snooze)
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
