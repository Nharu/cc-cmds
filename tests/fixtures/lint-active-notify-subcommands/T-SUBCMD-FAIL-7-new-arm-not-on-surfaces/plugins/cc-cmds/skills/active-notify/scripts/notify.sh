#!/usr/bin/env bash
# notify.sh {arm|fire-now|cancel|ping} [args]
#
# A fourth arm at four-space indent. Indentation is not what makes an arm an
# arm, so the reader takes it — and the surfaces, which name three, are then
# genuinely out of date. That is a real finding about the surfaces, not an
# unreadable block: reporting it as unreadable would be a false positive.
set -euo pipefail
subcommand="${1:-}"; shift || true

case "$subcommand" in
  arm)
    exit 0
    ;;

  fire-now)
    exit 0
    ;;

    ping)
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
