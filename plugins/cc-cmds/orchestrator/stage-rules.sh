#!/usr/bin/env bash
#
# stage-rules.sh — which of a person's own instruction bullets reach an
# unattended stage?
#
# The person marks each top-level bullet of their global instruction file
# (`${CLAUDE_CONFIG_DIR:-$HOME/.claude}/CLAUDE.md`) with a tag right after the
# `- `: `[무인] ` sends the bullet to every unattended stage, `[대화형] ` keeps it
# for interactive sessions only. A bullet with no tag, or with any other
# bracketed word in that place, reaches no stage and is listed instead — the
# default is to refuse. The tag is the whole disposition record: nothing in the
# repository and nothing in a host store has to change when a bullet does.
#
# The gate calls `extract` once at run open and freezes the `[무인]` block of
# the run's seat into the run directory; every stage instruction file of the
# run is synthesized from that one snapshot, after the plugin policy. A source
# with no tag at all is the legacy state: the stages get the frozen v6 policy
# and no personal block.
#
# Usage:
#   bash stage-rules.sh extract --source <file> [--out-dir <dir>]
#   bash stage-rules.sh status [--source <file>]
#   bash stage-rules.sh migrate --source <file> --legacy-table <tsv>
#                               --ack-store <dir> --out <file>
#
#   extract   With `--out-dir`, writes the block to `<dir>/<sha256>.md`, then
#             publishes the pointer `<dir>/current` with `mv -n` (an existing
#             pointer is never replaced), and prints one status line. Without
#             it, prints the block bytes; an untagged source prints the legacy
#             status line instead, so an untagged source and a tagged one whose
#             `[무인]` block is empty differ in bytes.
#   status    Counts, bytes and a token estimate per tag, the untagged and
#             malformed bullets by their first 40 characters, an alert past
#             24576 bytes, a warning for a credential-shaped string inside the
#             `[무인]` block (never the match itself), the host map, the legacy
#             state and what to do next. The source defaults to the global
#             instruction file.
#   migrate   Writes a tagged proposal of the source to `--out` from the frozen
#             v6 sources table and the host acknowledgement store, reports
#             every bullet, and recommends `[대화형]` for the notification
#             banner bullet. The source is never written. Refused while
#             `CC_PIPELINE_RUN_ID` is set: the disposition is the person's.
#
# Tag grammar. A top-level bullet is a line starting `- ` at column 0 together
# with every following line up to the next such line, the end of the file, or
# a line that is neither blank nor indented (that line is outside every
# bullet and never extracted). The tag is the first token after `- `: exactly
# `[무인]` or `[대화형]` followed by one space. Extraction removes the tag and
# that space and keeps every other byte of the bullet, continuation lines and
# sub-bullets included.
#
# Status line grammar (the gate logs it only when it matches one of the two):
#   stage rules: ok unattended=<n> bytes=<b> tokens~<t> interactive=<n> untagged=<n> malformed=<n>
#   stage rules: untagged — legacy v6 policy
# The pointer `current` holds `<sha256> <source path>` or `legacy untagged`;
# the gate itself writes `failed rc=<n>` when this script does not succeed.
#
# Exit codes: 0 — done; 2 — usage error, an unreadable input, or `migrate`
# refused under a run.
#
# Compatibility: bash 3.2, no python, no perl. `LC_ALL=C` so that every byte
# count is a byte count.

set -euo pipefail
export LC_ALL=C

TAG_U='[무인]'
TAG_I='[대화형]'
ALERT_BYTES=24576
# Measured Korean density of the personal rules, tokens per byte.
TOKEN_RATE=0.460
BANNER_ANCHOR='이 파일이 사용자에게 알림 배너를'
LEGACY_LINE='stage rules: untagged — legacy v6 policy'
MIGRATE_AFTER='ClickUp 발행 슬라이스가 머지된 플러그인에서 이관'

die_usage() { printf 'stage-rules: %s\n' "$1" >&2; exit 2; }

sha_stdin() { shasum -a 256 | cut -d' ' -f1; }

tokens_of() { awk -v b="$1" -v r="$TOKEN_RATE" 'BEGIN { printf "%d", b * r + 0.5 }'; }

# prefix40 <text> — the first 40 characters of UTF-8 text, counted by lead
# bytes so that the C locale does not cut a character in half.
prefix40() {
  local s="$1" out="" i=0 n=0 c
  while [ "$i" -lt "${#s}" ]; do
    c="${s:$i:1}"
    case "$c" in
      [$'\x80'-$'\xbf']) : ;;
      *) n=$((n + 1)); [ "$n" -le 40 ] || break ;;
    esac
    out="$out$c"
    i=$((i + 1))
  done
  printf '%s' "$out"
}

# parse <file> — fills the bullet arrays. An absent file reads as empty.
#   B_LINE[i]  the 1-based line of the bullet's first line
#   B_TAG[i]   u (unattended), i (interactive), n (none) or m (malformed)
#   B_TEXT[i]  the first line without `- ` and without its tag
#   B_BODY[i]  every byte of the bullet with the tag and its space removed
#   B_RAW[i]   every byte of the bullet as written
B_LINE=(); B_TAG=(); B_TEXT=(); B_BODY=(); B_RAW=()
parse() {
  local file="$1" line n=0 open=0 k=-1 rest
  B_LINE=(); B_TAG=(); B_TEXT=(); B_BODY=(); B_RAW=()
  [ -f "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    case "$line" in
      "- "*)
        k=$((k + 1)); open=1
        rest="${line#- }"
        B_LINE[$k]=$n
        B_RAW[$k]="$line"$'\n'
        case "$rest" in
          "$TAG_U "*) B_TAG[$k]=u; rest="${rest#"$TAG_U "}" ;;
          "$TAG_I "*) B_TAG[$k]=i; rest="${rest#"$TAG_I "}" ;;
          "["*"]"*) B_TAG[$k]=m ;;
          *) B_TAG[$k]=n ;;
        esac
        B_TEXT[$k]="$rest"
        B_BODY[$k]="- $rest"$'\n' ;;
      ''|[[:space:]]*)
        [ "$open" = 1 ] || continue
        B_RAW[$k]="${B_RAW[$k]}$line"$'\n'
        B_BODY[$k]="${B_BODY[$k]}$line"$'\n' ;;
      *) open=0 ;;
    esac
  done < "$file"
}

# Totals over the parsed bullets.
N_U=0; N_I=0; N_N=0; N_M=0; BYTES_U=0; BYTES_I=0; BLOCK=""
tally() {
  local k=0
  N_U=0; N_I=0; N_N=0; N_M=0; BYTES_U=0; BYTES_I=0; BLOCK=""
  while [ "$k" -lt "${#B_LINE[@]}" ]; do
    case "${B_TAG[$k]}" in
      u) N_U=$((N_U + 1)); BLOCK="$BLOCK${B_BODY[$k]}" ;;
      i) N_I=$((N_I + 1)); BYTES_I=$((BYTES_I + ${#B_BODY[$k]})) ;;
      n) N_N=$((N_N + 1)) ;;
      m) N_M=$((N_M + 1)) ;;
    esac
    k=$((k + 1))
  done
  BYTES_U=${#BLOCK}
}

tagged() { [ $((N_U + N_I)) -gt 0 ]; }

status_line() {
  if tagged; then
    printf 'stage rules: ok unattended=%s bytes=%s tokens~%s interactive=%s untagged=%s malformed=%s\n' \
      "$N_U" "$BYTES_U" "$(tokens_of "$BYTES_U")" "$N_I" "$N_N" "$N_M"
  else
    printf '%s\n' "$LEGACY_LINE"
  fi
}

default_source() { printf '%s/CLAUDE.md' "${CLAUDE_CONFIG_DIR:-${HOME:-}/.claude}"; }

cmd_extract() {
  local source="" outdir="" sha tmp ptmp
  while [ $# -gt 0 ]; do
    case "$1" in
      --source) [ $# -ge 2 ] || die_usage "--source needs a file"; source="$2"; shift 2 ;;
      --out-dir) [ $# -ge 2 ] || die_usage "--out-dir needs a directory"; outdir="$2"; shift 2 ;;
      *) die_usage "extract: unknown argument: $1" ;;
    esac
  done
  [ -n "$source" ] || die_usage "extract: --source is required"
  if [ -e "$source" ] && [ ! -r "$source" ]; then
    die_usage "extract: source not readable: $source"
  fi
  parse "$source"
  tally
  if [ -z "$outdir" ]; then
    if tagged; then printf '%s' "$BLOCK"; else printf '%s\n' "$LEGACY_LINE"; fi
    return 0
  fi
  umask 077
  mkdir -p "$outdir" || die_usage "extract: cannot create $outdir"
  ptmp=$(mktemp "$outdir/.current.XXXXXX") || die_usage "extract: cannot write in $outdir"
  if tagged; then
    sha=$(printf '%s' "$BLOCK" | sha_stdin)
    # The snapshot before the pointer: a pointer never names a missing file.
    tmp=$(mktemp "$outdir/.block.XXXXXX") || { rm -f "$ptmp"; die_usage "extract: cannot write in $outdir"; }
    printf '%s' "$BLOCK" > "$tmp"
    mv -f "$tmp" "$outdir/$sha.md"
    printf '%s %s\n' "$sha" "$source" > "$ptmp"
  else
    printf 'legacy untagged\n' > "$ptmp"
  fi
  # An existing pointer is the run's snapshot already; a second extract that
  # lost the race leaves it as it is.
  mv -n "$ptmp" "$outdir/current" 2>/dev/null || true
  [ ! -e "$ptmp" ] || rm -f "$ptmp"
  status_line
}

# credential_hits — the 1-based source lines of `[무인]` bullets carrying a
# credential-shaped string. Only line numbers leave this function.
credential_hits() {
  local k=0
  while [ "$k" -lt "${#B_LINE[@]}" ]; do
    # A here-string, not a pipe: `grep -q` exits on the first match and
    # `pipefail` would then read the writer's SIGPIPE as no match.
    if [ "${B_TAG[$k]}" = u ] && grep -q -E \
      'AKIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9_-]{20,}|xox[abprs]-[A-Za-z0-9-]{10,}|-----BEGIN [A-Z ]*PRIVATE KEY|([Pp]assword|[Pp]asswd|[Tt]oken|[Ss]ecret|[Aa][Pp][Ii][_-]?[Kk]ey)[[:space:]]*[:=][[:space:]]*[^[:space:]]{8,}' \
      <<< "${B_BODY[$k]}" 2>/dev/null; then
      printf '%s\n' "${B_LINE[$k]}"
    fi
    k=$((k + 1))
  done
}

cmd_status() {
  local source="" map line k hits ws=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --source) [ $# -ge 2 ] || die_usage "--source needs a file"; source="$2"; shift 2 ;;
      *) die_usage "status: unknown argument: $1" ;;
    esac
  done
  [ -n "$source" ] || source=$(default_source)
  if [ -e "$source" ] && [ ! -r "$source" ]; then
    die_usage "status: source not readable: $source"
  fi
  parse "$source"
  tally
  if [ -f "$source" ]; then
    printf 'source: %s\n' "$source"
  else
    printf 'source: %s (absent, read as empty)\n' "$source"
  fi
  status_line
  if tagged; then
    printf 'mode: tagged — the stages get the plugin policy and the [무인] block\n'
  else
    printf 'mode: legacy untagged — the stages get the frozen v6 policy and no personal block\n'
  fi
  printf 'unattended: %s bullet(s), %s bytes, about %s tokens\n' "$N_U" "$BYTES_U" "$(tokens_of "$BYTES_U")"
  printf 'interactive: %s bullet(s), %s bytes\n' "$N_I" "$BYTES_I"
  if [ "$BYTES_U" -gt "$ALERT_BYTES" ]; then
    printf 'alert: the [무인] block is %s bytes, past %s — every stage carries it\n' "$BYTES_U" "$ALERT_BYTES"
  fi
  k=0
  while [ "$k" -lt "${#B_LINE[@]}" ]; do
    case "${B_TAG[$k]}" in
      n) printf 'untagged line %s: %s\n' "${B_LINE[$k]}" "$(prefix40 "${B_TEXT[$k]}")" ;;
      m) printf 'malformed tag line %s: %s\n' "${B_LINE[$k]}" "$(prefix40 "${B_TEXT[$k]}")" ;;
    esac
    k=$((k + 1))
  done
  hits=$(credential_hits)
  if [ -n "$hits" ]; then
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      printf 'warning: line %s — a [무인] bullet carries a credential-shaped string; it reaches every stage\n' "$line"
    done <<< "$hits"
  fi
  map="${CC_GATE_STAGE_POLICY_SOURCES:-${HOME:-}/.config/cc-cmds/stage-policy-sources}"
  if [ -f "$map" ]; then
    printf 'host map: %s\n' "$map"
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in ''|'#'*) continue ;; esac
      printf '  %s\n' "$line"
      case "$line" in "workspace	"*) ws=1 ;; esac
    done < "$map"
  else
    printf 'host map: %s (absent)\n' "$map"
  fi
  printf 'next:\n'
  if ! tagged; then
    printf '  - %s\n' "$MIGRATE_AFTER"
    printf '  - bash <plugin root>/orchestrator/stage-rules.sh migrate --source %s --legacy-table <plugin root>/orchestrator/legacy/stage-policy.sources.v6.tsv --ack-store ~/.config/cc-cmds/stage-policy-ack --out ~/.config/cc-cmds/stage-rules.proposed.md\n' "$source"
  fi
  if [ $((N_N + N_M)) -gt 0 ]; then
    printf '  - tag each listed bullet [무인] or [대화형]; untagged bullets reach no stage\n'
  fi
  if [ "$ws" = 0 ]; then
    printf '  - add a line `workspace<TAB><absolute path>` to the host map to keep a workspace instruction file out of the stages\n'
  fi
  return 0
}

cmd_migrate() {
  local source="" table="" store="" out="" acks k rule tag text anchor disp
  local n_u=0 n_i=0 n_n=0 b_u=0 b_i=0 tmp banner=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --source) [ $# -ge 2 ] || die_usage "--source needs a file"; source="$2"; shift 2 ;;
      --legacy-table) [ $# -ge 2 ] || die_usage "--legacy-table needs a file"; table="$2"; shift 2 ;;
      --ack-store) [ $# -ge 2 ] || die_usage "--ack-store needs a directory"; store="$2"; shift 2 ;;
      --out) [ $# -ge 2 ] || die_usage "--out needs a file"; out="$2"; shift 2 ;;
      *) die_usage "migrate: unknown argument: $1" ;;
    esac
  done
  if [ -n "${CC_PIPELINE_RUN_ID:-}" ]; then
    die_usage "migrate: refusing under CC_PIPELINE_RUN_ID — tagging the global instruction file is the person's disposition, not a run's"
  fi
  [ -n "$source" ] && [ -n "$table" ] && [ -n "$store" ] && [ -n "$out" ] \
    || die_usage "migrate: --source, --legacy-table, --ack-store and --out are all required"
  [ -f "$source" ] || die_usage "migrate: source not found: $source"
  [ -f "$table" ] || die_usage "migrate: legacy table not found: $table"
  acks="$store/acks.tsv"
  parse "$source"
  tmp=$(mktemp "$(dirname "$out")/.stage-rules-proposed.XXXXXX") \
    || die_usage "migrate: cannot write beside $out"
  k=0
  while [ "$k" -lt "${#B_LINE[@]}" ]; do
    text="${B_TEXT[$k]}"
    tag=""; rule=""
    case "${B_TAG[$k]}" in
      u) tag="$TAG_U"; rule="already tagged" ;;
      i) tag="$TAG_I"; rule="already tagged" ;;
      m) rule="malformed tag left as written" ;;
    esac
    if [ -z "$rule" ]; then
      # The table first: for a table anchor the host row's disposition was
      # never read by the checker either.
      disp=$(T="$text" awk -F'\t' 'NR > 1 && $1 == "user-scope" && $2 != "" && index(ENVIRON["T"], $2) == 1 { print $4; exit }' "$table")
      if [ -n "$disp" ]; then
        case "$disp" in
          policy:*|skill:*) tag="$TAG_U"; rule="table $disp" ;;
          excluded:*) tag="$TAG_I"; rule="table $disp" ;;
          *) rule="table $disp, no tag" ;;
        esac
      elif [ -f "$acks" ]; then
        # The last host row for a matching anchor wins, as it did in the checker.
        disp=$(T="$text" awk -F'\t' 'NR > 1 && $1 == "user-scope" && $2 != "" && index(ENVIRON["T"], $2) == 1 { d = $4 } END { print d }' "$acks")
        case "$disp" in
          skill:*) tag="$TAG_U"; rule="host $disp" ;;
          excluded:*) tag="$TAG_I"; rule="host $disp" ;;
          '') rule="no row" ;;
          *) rule="host $disp, no tag" ;;
        esac
      else
        rule="no row"
      fi
    fi
    if [ -n "$tag" ]; then
      printf '%s' "- $tag ${B_BODY[$k]#- }" >> "$tmp"
    else
      printf '%s' "${B_RAW[$k]}" >> "$tmp"
    fi
    case "$tag" in
      "$TAG_U") n_u=$((n_u + 1)); b_u=$((b_u + ${#B_BODY[$k]})) ;;
      "$TAG_I") n_i=$((n_i + 1)); b_i=$((b_i + ${#B_BODY[$k]})) ;;
      *) n_n=$((n_n + 1)) ;;
    esac
    printf 'line %s\t%s\t%s\t%s bytes\n' "${B_LINE[$k]}" "${tag:-(none)}" "$rule" "${#B_BODY[$k]}"
    if [ -z "$banner" ] && [ "${text:0:${#BANNER_ANCHOR}}" = "$BANNER_ANCHOR" ]; then
      banner="${B_LINE[$k]}"
    fi
    k=$((k + 1))
  done
  if [ -n "$banner" ]; then
    printf 'recommend line %s: %s — the plugin policy already bans every notification, and the stages do not need this bullet\n' "$banner" "$TAG_I"
  fi
  printf 'total: unattended=%s bytes=%s interactive=%s bytes=%s untagged=%s\n' "$n_u" "$b_u" "$n_i" "$b_i" "$n_n"
  mv -f "$tmp" "$out"
  printf 'proposal: %s (the source is unchanged)\n' "$out"
}

[ $# -ge 1 ] || die_usage "usage: stage-rules.sh extract|status|migrate ..."
mode="$1"; shift
case "$mode" in
  extract) cmd_extract "$@" ;;
  status) cmd_status "$@" ;;
  migrate) cmd_migrate "$@" ;;
  *) die_usage "unknown mode: $mode (extract|status|migrate)" ;;
esac
