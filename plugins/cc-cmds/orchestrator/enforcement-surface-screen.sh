#!/usr/bin/env bash
#
# enforcement-surface-screen.sh — which of these paths would the run hook refuse
# as an enforcement surface.
#
# Usage
#
#   enforcement-surface-screen.sh [--list] [--tokens] [-z] [--] [<path>…]
#
#   <path>…   each path that is an enforcement surface is printed as
#             `<path><TAB><class>`; a path that is not one prints nothing. A
#             path is judged as written and, when it does not begin with `/`,
#             once more with `/` in front, so a repository-relative path such as
#             `.claude/settings.json` meets the same arm as the absolute one.
#   --list    print the classifier's arms first, one per glob, as
#             `<class><TAB><glob><TAB><deny|reroute>` — the data a kickoff hands
#             to the entry judgment instead of a list written into prose.
#   --tokens  read each argument (or each `-z` entry) as a command line rather
#             than a path, and print every token of it that is an enforcement
#             surface as `<token><TAB><class>` — the same token rule the gate
#             applies to a `좌석 실행` command.
#   -z        read the paths (or command lines) NUL-separated from standard
#             input instead of the argument list.
#
#   The classes are a closed set of four: 프로젝트설정, 트랜스크립트,
#   규칙카탈로그, 지침파일.
#
# Exit codes
#
#   0  judged — whether or not anything was printed
#   1  malformed invocation
#   2  the classifier beside this tool could not be loaded, so nothing was
#      judged; a caller reads this as `판정불가`, never as "no surface"
#
# READS ONLY. No manifest, no run and no repository are needed, and nothing is
# written. The arms are not here: they are in `../hooks/enforcement-surfaces.sh`,
# the same file the run hook sources, so this tool cannot disagree with the hook
# about a spelling. Inside a run a stage cannot launch a script from the pinned
# plugin copy, so it calls `gate.sh surface-screen`, which runs this file from
# beside the gate with the same arguments and the same output.
#
# Compatibility: bash 3.2.

set -uo pipefail

es_here=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd) || exit 2
# shellcheck source=/dev/null
. "$es_here/../hooks/enforcement-surfaces.sh" 2>/dev/null
if ! command -v es_class >/dev/null 2>&1; then
  printf 'enforcement-surface-screen: the classifier %s could not be loaded — nothing was judged\n' \
    "$es_here/../hooks/enforcement-surfaces.sh" >&2
  exit 2
fi

es_list=0 es_tokens=0 es_nul=0
while [ $# -gt 0 ]; do
  case "$1" in
    --list)   es_list=1; shift ;;
    --tokens) es_tokens=1; shift ;;
    -z)       es_nul=1; shift ;;
    --)       shift; break ;;
    -*)       printf 'enforcement-surface-screen: unknown option: %s\n' "$1" >&2; exit 1 ;;
    *)        break ;;
  esac
done
if [ "$es_nul" = 1 ] && [ $# -gt 0 ]; then
  printf 'enforcement-surface-screen: -z reads standard input and takes no operands\n' >&2
  exit 1
fi

[ "$es_list" = 0 ] || es_class_list

es_screen_one() {
  local c
  [ -n "$1" ] || return 0
  if [ "$es_tokens" = 1 ]; then
    es_class_command "$1" || true
    return 0
  fi
  if c=$(es_class "$1"); then
    printf '%s\t%s\n' "$1" "$c"
  else
    case "$1" in
      /*) ;;
      *) c=$(es_class "/$1") && printf '%s\t%s\n' "$1" "$c" ;;
    esac
  fi
  return 0
}

if [ "$es_nul" = 1 ]; then
  while IFS= read -r -d '' es_item || [ -n "${es_item:-}" ]; do
    es_screen_one "$es_item"
  done
else
  for es_item in "$@"; do
    es_screen_one "$es_item"
  done
fi
exit 0
