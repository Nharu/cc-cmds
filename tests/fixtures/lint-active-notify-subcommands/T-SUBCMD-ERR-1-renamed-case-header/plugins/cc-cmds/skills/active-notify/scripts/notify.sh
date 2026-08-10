#!/usr/bin/env bash
# notify.sh {arm|fire-now|cancel} [args]
#
# The dispatch variable is renamed, so the reader never enters the block and
# extracts nothing. This is the half of the shape guard that the empty-set test
# already caught; it is fixtured so the half stays caught once the guard stops
# being an empty-set test.
set -euo pipefail
sub_cmd="${1:-}"; shift || true

case "$sub_cmd" in
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
    printf 'notify.sh: unknown subcommand "%s" (arm|fire-now|cancel)\n' "$sub_cmd" >&2
    exit 1
    ;;
esac
