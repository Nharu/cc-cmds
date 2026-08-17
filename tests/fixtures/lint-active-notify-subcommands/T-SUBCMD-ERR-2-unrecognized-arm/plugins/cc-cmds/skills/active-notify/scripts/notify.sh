#!/usr/bin/env bash
# notify.sh {arm|fire-now|cancel} [args]
#
# A multi-pattern arm. The reader sees the arm position but cannot classify the
# pattern as a single subcommand name, and reporting that is the whole point:
# skipping it would drop a live subcommand from the derived set, and the rules
# would then blame the SURFACES for a name the dispatcher still accepts.
set -euo pipefail
subcommand="${1:-}"; shift || true

case "$subcommand" in
  arm)
    exit 0
    ;;

  fire-now)
    exit 0
    ;;

  cancel|stop)
    exit 0
    ;;

  *)
    printf 'notify.sh: unknown subcommand "%s" (arm|fire-now|cancel|ping)\n' "$subcommand" >&2
    exit 1
    ;;
esac
