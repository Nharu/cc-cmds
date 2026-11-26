#!/usr/bin/env bash
#
# cc-team-nonce.sh — mint a team lead's witness nonces and draft tokens, as ONE
# read.
#
# Usage:  <plugin root>/orchestrator/cc-team-nonce.sh <role-slug>@<round/phase>...
#
# For every argument, in order, one line on standard output:
#
#   <role-slug> <round/phase> <round/phase>:<16 hex> <16 hex>
#
# the third field the compound witness nonce for that key and the fourth a draft
# token. The lead takes every key it will need for the stage in one call — each
# role of the roster, each round token of the budget and its `-rev1` key — and
# keeps the lines in context; a draft token is not tied to its key, and the lead
# spends any unused one, once, per assignment.
#
# INVOKED DIRECTLY, NEVER AS `bash <this script>`: the gate grades this name as
# argv0 (`읽기`). The file ships mode 755 with the shebang above.
#
# IT WRITES NOTHING. The values come from one `openssl rand` and are printed;
# no file is opened for writing and nothing is reached off this machine, which
# is what the read grade rests on.
#
# ALL OR NOTHING. Every argument is checked before any value is made — each
# side of the one `@` is a non-empty token of `[A-Za-z0-9_-]`, colon-free like
# every round/phase token — and a single bad argument, no argument, or a failed
# or short `openssl` prints nothing at all and exits non-zero (2 for the
# arguments, 1 for `openssl`). A partial list would let a lead hold values for
# some keys and silently none for others.

set -uo pipefail

ME='cc-team-nonce.sh'

if [ "$#" -eq 0 ]; then
  printf '%s: 인자가 없습니다 — 사용법: %s <role-slug>@<round/phase>...\n' "$ME" "$ME" >&2
  exit 2
fi
for arg in "$@"; do
  role=${arg%%@*}
  round=${arg#*@}
  case "$arg" in *@*) ;; *) role='' ;; esac
  case "$role" in ''|*[!A-Za-z0-9_-]*) role='' ;; esac
  case "$round" in ''|*[!A-Za-z0-9_-]*) role='' ;; esac
  if [ -z "$role" ]; then
    printf '%s: 인자가 <role-slug>@<round/phase> 꼴이 아닙니다: %s\n' "$ME" "$arg" >&2
    exit 2
  fi
done

# Sixteen bytes per argument: eight for the nonce, eight for the draft token.
need=$((32 * $#))
hex=$(openssl rand -hex $((16 * $#)) 2>/dev/null) || hex=''
case "$hex" in *[!0-9a-f]*) hex='' ;; esac
if [ "${#hex}" -ne "$need" ]; then
  printf '%s: openssl rand 가 값을 내지 못했습니다\n' "$ME" >&2
  exit 1
fi

out=''
i=0
for arg in "$@"; do
  role=${arg%%@*}
  round=${arg#*@}
  n=${hex:$i:16}
  t=${hex:$((i + 16)):16}
  i=$((i + 32))
  out="$out$role $round $round:$n $t"$'\n'
done
printf '%s' "$out"
