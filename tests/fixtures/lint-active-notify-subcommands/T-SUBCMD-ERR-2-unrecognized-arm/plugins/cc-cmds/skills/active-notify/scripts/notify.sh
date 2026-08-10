#!/usr/bin/env bash
# notify.sh {arm|fire-now|cancel} [args]
#
# A fourth arm at four-space indent. The strict reader skips it and returns a
# non-empty list, so an emptiness test reports success while the new subcommand
# is invisible to every rule below it — the surfaces are then judged against a
# dispatcher set that is missing a member the dispatcher accepts.
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

    ping)
    exit 0
    ;;

  *)
    printf 'notify.sh: unknown subcommand "%s" (arm|fire-now|cancel|ping)\n' "$subcommand" >&2
    exit 1
    ;;
esac
