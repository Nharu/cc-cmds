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
#   bash stage-rules.sh enforcement [--source <file>]
#   bash stage-rules.sh enforcement --source <file> --notice-for -
#                                   [--notice-line <n>]...
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
#             banner bullet. The proposal is the source with a tag added to
#             the first line of some untagged bullets and no other byte
#             changed, so copying it over the source loses nothing. The
#             source is never written, and an `--out` that is the source
#             itself is refused. Refused while `CC_PIPELINE_RUN_ID` is set:
#             the disposition is the person's.
#   enforcement
#             Pairs every top-level bullet with the enforcement means its
#             markers name (below) and prints the table: a verdict per bullet,
#             the prose-only bullets, the uncovered paths of the partial ones
#             and every dead means. The source defaults to the global
#             instruction file. Read-only: a marker is the person's to write.
#             With `--notice-for -` it prints only the target bullets (the
#             notice table below) among the bullets this edit touched: a bullet
#             whose first line or marker line equals, byte for byte, a line read
#             from standard input, and a bullet holding a source line given by
#             `--notice-line` (the edit hook passes the lines of a deleted
#             marker that way), each once, in source order. Runs under
#             `CC_PIPELINE_RUN_ID` as well; prose bullets never make it fail.
#
# Marker grammar. A marker is a continuation line of a top-level bullet whose
# content, leading spaces and tabs removed, starts with `강제:` or `산문:`; the
# blank after the colon is optional, and a sub-bullet line is never one (a
# marker indented under a sub-bullet still belongs to the top-level bullet).
#   강제: <kind> <location>[#<anchor>][ @무인|@대화형][; ...]
#   산문: <reason>
# Items are split at `;` and trimmed; the items of every `강제:` line add up.
# The kind is one of 훅 게이트 린트 시험 구조. The location starts with
# `plugin:` (the plugin root, the parent of this script's directory with links
# resolved; a `..` component is malformed), `config:` (`${CLAUDE_CONFIG_DIR:-
# $HOME/.claude}`), `~/` (`HOME`; malformed when `HOME` is empty) or `/`. The
# anchor runs from the first `#` and is looked up as a fixed string. An empty
# item, a `강제:` line with no item, an unknown kind, a missing location, an
# unknown prefix, an empty anchor, an unknown or second path mark and any word
# left over make the item malformed. A `산문:` line with a blank reason is no
# marker; with several, the first reason counts.
#
# Verdict. An item is dead when it is malformed, when its file is not a
# readable file (`missing file`) or when its anchor is not in that file
# (`anchor not found`). A live item covers the path its mark names; with no
# mark a 게이트 item covers 무인 and every other kind covers both. A bullet
# needs 대화형 and 무인 when the source is another file than the default
# (`scope: other`) or when it is tagged `[무인]`; any other bullet of the
# default source needs 대화형 alone. All needed paths covered — enforced; some
# — partial (`partial, uncovered <paths>`); none — prose, read as
# `uncovered <paths>` when a live item exists, else `means lost` when an item
# exists, else `marked prose: <reason>`, else `no marker`. Paths are listed
# 대화형 first, joined by `,`.
#
# Notice table. A target is an enforced bullet with a dead item (the reason is
# `dead <item> <reason>` per dead item, joined by `; `), and a partial or
# prose bullet that has no `산문:` marker or has a dead item (the prose-only
# reason, then `; dead <item> <reason>` per dead item).
#
# Enforcement output:
#   source: <path>[ (absent, read as empty)]
#   scope: <user|other>
#   rules: total=<n> enforced=<n> partial=<n> prose=<n>
#   line <n><TAB><verdict><TAB><first 40 chars><TAB><live items joined by `; `, or ->
#   prose-only:   then `  line <n><TAB><first 40><TAB><reason>` per bullet
#   partial gaps: then `  line <n><TAB><first 40><TAB>covered <p> by <items>; uncovered <p>[ — <prose reason>]`
#   dead means:   then `  line <n><TAB><item><TAB><reason>` per dead item
# An empty group is the line `  (none)`. A notice line is
# `line <n><TAB><first 40 chars><TAB><reason>`.
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
# refused under a run. An absent source reads as empty and exits 0.
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
  local n_u=0 n_i=0 n_n=0 b_u=0 b_i=0 tmp banner="" line eol open outside
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
  if [ -e "$out" ] && [ "$source" -ef "$out" ]; then
    die_usage "migrate: --out is the source itself: $out — the source is never written"
  fi
  acks="$store/acks.tsv"
  parse "$source"
  tmp=$(mktemp "$(dirname "$out")/.stage-rules-proposed.XXXXXX") \
    || die_usage "migrate: cannot write beside $out"
  NEW_TAG=()
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
    # Only a bullet that had no tag gets one written; every other bullet stays
    # as written.
    case "${B_TAG[$k]}" in
      n) NEW_TAG[$k]="$tag" ;;
      *) NEW_TAG[$k]="" ;;
    esac
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
  # The proposal is the source byte for byte except the first line of each
  # bullet tagged above: headings, paragraphs and every other line outside a
  # bullet are copied in place, and so is a last line without a newline.
  k=-1; open=0; outside=0
  while :; do
    if IFS= read -r line; then eol=$'\n'
    elif [ -n "$line" ]; then eol=''
    else break
    fi
    case "$line" in
      "- "*)
        k=$((k + 1)); open=1
        if [ -n "${NEW_TAG[$k]}" ]; then line="- ${NEW_TAG[$k]} ${line#- }"; fi ;;
      ''|[[:space:]]*) [ "$open" = 1 ] || [ -z "$line" ] || outside=$((outside + 1)) ;;
      *) open=0; outside=$((outside + 1)) ;;
    esac
    printf '%s%s' "$line" "$eol" >> "$tmp"
  done < "$source"
  if [ "$outside" -gt 0 ]; then
    printf 'outside: %s line(s) outside every bullet, kept in the proposal as written and never extracted\n' "$outside"
  fi
  if [ -n "$banner" ]; then
    printf 'recommend line %s: %s — the plugin policy already bans every notification, and the stages do not need this bullet\n' "$banner" "$TAG_I"
  fi
  printf 'total: unattended=%s bytes=%s interactive=%s bytes=%s untagged=%s\n' "$n_u" "$b_u" "$n_i" "$b_i" "$n_n"
  mv -f "$tmp" "$out"
  printf 'proposal: %s (the source is unchanged)\n' "$out"
}

# ---------- enforcement ----------------------------------------------------------

SPTAB=$' \t'
NL=$'\n'

# trim <text> — sets T to the text without leading and trailing spaces and tabs.
trim() {
  T="$1"
  T="${T#"${T%%[!$SPTAB]*}"}"
  T="${T%"${T##*[!$SPTAB]}"}"
}

# enf_markers <k> — reads the marker lines of bullet k: every line after the
# first whose content, leading spaces and tabs removed, starts with `강제:` or
# `산문:`. Sub-bullet lines never start that way, so a sub-bullet is never a
# marker, and a marker line indented under a sub-bullet belongs to the
# top-level bullet like every other continuation line.
#   M_ITEMS[]  every `강제:` item, trimmed, in marker order
#   M_HASP     1 when a `산문:` line with a reason exists; M_PROSE its reason
#   M_LINES    every marker line as written, each ending in a newline
M_ITEMS=(); M_HASP=0; M_PROSE=""; M_LINES=""
enf_markers() {
  local rest="${B_RAW[$1]}" line body item more
  M_ITEMS=(); M_HASP=0; M_PROSE=""; M_LINES=""
  rest="${rest#*$NL}"
  while [ -n "$rest" ]; do
    line="${rest%%$NL*}"
    rest="${rest#*$NL}"
    trim "$line"
    case "$T" in
      "강제:"*)
        M_LINES="$M_LINES$line$NL"
        trim "${T#강제:}"
        body="$T"
        # A `강제:` line with no item is one malformed item.
        while :; do
          case "$body" in
            *";"*) item="${body%%;*}"; body="${body#*;}"; more=1 ;;
            *) item="$body"; more=0 ;;
          esac
          trim "$item"
          M_ITEMS[${#M_ITEMS[@]}]="$T"
          [ "$more" = 1 ] || break
        done ;;
      "산문:"*)
        trim "${T#산문:}"
        # A reason that is empty or blank leaves the line no marker at all.
        [ -n "$T" ] || continue
        M_LINES="$M_LINES$line$NL"
        if [ "$M_HASP" = 0 ]; then M_HASP=1; M_PROSE="$T"; fi ;;
    esac
  done
}

# enf_item <item> — sets I_STATE (live, malformed, missing file or anchor not
# found) and I_COVER, the paths a live item covers: 1 interactive, 2
# unattended, 3 both.
I_STATE=""; I_COVER=0
enf_item() {
  local it="$1" kind w mark loc anchor="" has_anchor=0 path rel
  local IFS="$SPTAB"
  I_STATE=malformed; I_COVER=0
  [ -n "$it" ] || return 0
  set -f
  # shellcheck disable=SC2086
  set -- $it
  set +f
  [ $# -ge 2 ] && [ $# -le 3 ] || return 0
  kind="$1"; w="$2"; mark="${3:-}"
  case "$kind" in 훅|게이트|린트|시험|구조) ;; *) return 0 ;; esac
  case "$mark" in ''|@무인|@대화형) ;; *) return 0 ;; esac
  case "$w" in
    *'#'*) loc="${w%%#*}"; anchor="${w#*#}"; has_anchor=1; [ -n "$anchor" ] || return 0 ;;
    *) loc="$w" ;;
  esac
  case "$loc" in
    plugin:*)
      rel="${loc#plugin:}"
      case "/$rel/" in */../*) return 0 ;; esac
      path="$ENF_PLUGIN_ROOT/$rel" ;;
    config:*) path="${CLAUDE_CONFIG_DIR:-${HOME:-}/.claude}/${loc#config:}" ;;
    '~/'*)
      [ -n "${HOME:-}" ] || return 0
      path="$HOME/${loc#'~/'}" ;;
    /*) path="$loc" ;;
    *) return 0 ;;
  esac
  if [ ! -f "$path" ] || [ ! -r "$path" ]; then I_STATE='missing file'; return 0; fi
  if [ "$has_anchor" = 1 ] && ! grep -q -F -e "$anchor" "$path" 2>/dev/null; then
    I_STATE='anchor not found'; return 0
  fi
  I_STATE=live
  case "$mark" in
    @무인) I_COVER=2 ;;
    @대화형) I_COVER=1 ;;
    *) case "$kind" in 게이트) I_COVER=2 ;; *) I_COVER=3 ;; esac ;;
  esac
}

# path_names <bits> — sets PN to the path names, interactive first.
path_names() {
  case "$1" in 1) PN='대화형' ;; 2) PN='무인' ;; *) PN='대화형,무인' ;; esac
}

# enf_eval <k> — judges bullet k against the closed tables of the header.
#   E_VERDICT  enforced, partial or prose
#   E_REASON   the `prose-only:` reason, empty for an enforced bullet
#   E_GAP      the `partial gaps:` text, empty unless partial
#   E_LIVE     the live items joined with `; `, or `-`
#   E_DEADS    one `<item><TAB><reason>` line per dead item
#   E_TARGET   1 when the notice table makes the bullet a target; E_NOTICE its reason
E_VERDICT=""; E_REASON=""; E_GAP=""; E_LIVE=""; E_DEADS=""; E_TARGET=0; E_NOTICE=""
enf_eval() {
  local k="$1" i=0 need cov=0 live=0 unc both by="" dead="" ndead=0
  local -a covers
  enf_markers "$k"
  E_VERDICT=""; E_REASON=""; E_GAP=""; E_LIVE=""; E_DEADS=""; E_TARGET=0; E_NOTICE=""
  covers=()
  while [ "$i" -lt "${#M_ITEMS[@]}" ]; do
    enf_item "${M_ITEMS[$i]}"
    covers[$i]=0
    if [ "$I_STATE" = live ]; then
      live=1
      covers[$i]=$I_COVER
      cov=$((cov | I_COVER))
      E_LIVE="${E_LIVE:+$E_LIVE; }${M_ITEMS[$i]}"
    else
      ndead=$((ndead + 1))
      E_DEADS="$E_DEADS${M_ITEMS[$i]}	$I_STATE$NL"
      dead="$dead; dead ${M_ITEMS[$i]} $I_STATE"
    fi
    i=$((i + 1))
  done
  [ -n "$E_LIVE" ] || E_LIVE='-'
  if [ "$ENF_SCOPE" = user ] && [ "${B_TAG[$k]}" != u ]; then need=1; else need=3; fi
  unc=$((need & ~cov & 3))
  both=$((need & cov))
  if [ "$unc" = 0 ]; then
    E_VERDICT=enforced
  elif [ "$both" != 0 ]; then
    E_VERDICT=partial
    path_names "$unc"
    E_REASON="partial, uncovered $PN"
    i=0
    while [ "$i" -lt "${#M_ITEMS[@]}" ]; do
      if [ $(( ${covers[$i]} & both )) != 0 ]; then by="${by:+$by, }${M_ITEMS[$i]}"; fi
      i=$((i + 1))
    done
    path_names "$both"
    E_GAP="covered $PN by $by; "
    path_names "$unc"
    E_GAP="${E_GAP}uncovered $PN"
    if [ "$M_HASP" = 1 ]; then E_GAP="$E_GAP — $M_PROSE"; fi
  else
    E_VERDICT=prose
    if [ "$live" = 1 ]; then
      path_names "$need"
      E_REASON="uncovered $PN"
    elif [ "${#M_ITEMS[@]}" -gt 0 ]; then
      E_REASON='means lost'
    elif [ "$M_HASP" = 1 ]; then
      E_REASON="marked prose: $M_PROSE"
    else
      E_REASON='no marker'
    fi
  fi
  if [ "$E_VERDICT" = enforced ]; then
    if [ "$ndead" -gt 0 ]; then E_TARGET=1; E_NOTICE="${dead#; }"; fi
  elif [ "$M_HASP" = 0 ] || [ "$ndead" -gt 0 ]; then
    E_TARGET=1; E_NOTICE="$E_REASON$dead"
  fi
}

# bullet_end <k> — sets BE to the last source line of bullet k: its first line
# and every continuation and sub-bullet line `parse` gave it.
bullet_end() {
  local nls="${B_RAW[$1]//[!$NL]/}"
  BE=$(( ${B_LINE[$1]} + ${#nls} - 1 ))
}

cmd_enforcement() {
  local source="" notice=0 def k sel input first rest line v
  local enforced=0 partial=0 prose=0 rows="" onlys="" gaps="" deads="" p40 d
  local -a nlines
  nlines=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --source) [ $# -ge 2 ] || die_usage "--source needs a file"; source="$2"; shift 2 ;;
      --notice-for)
        [ $# -ge 2 ] && [ "$2" = - ] || die_usage "enforcement: --notice-for takes - (standard input) only"
        notice=1; shift 2 ;;
      --notice-line)
        [ $# -ge 2 ] || die_usage "--notice-line needs a line number"
        case "$2" in
          ''|0*|*[!0-9]*) die_usage "enforcement: --notice-line takes a positive decimal line number: $2" ;;
        esac
        nlines[${#nlines[@]}]="$2"; shift 2 ;;
      *) die_usage "enforcement: unknown argument: $1" ;;
    esac
  done
  if [ "$notice" = 0 ] && [ "${#nlines[@]}" -gt 0 ]; then
    die_usage "enforcement: --notice-line needs --notice-for -"
  fi
  def=$(default_source)
  ENF_SCOPE=other
  if [ -z "$source" ]; then
    source="$def"; ENF_SCOPE=user
  elif [ "$source" = "$def" ] || [ "$source" -ef "$def" ]; then
    ENF_SCOPE=user
  fi
  if [ -e "$source" ] && [ ! -r "$source" ]; then
    die_usage "enforcement: source not readable: $source"
  fi
  ENF_PLUGIN_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || ENF_PLUGIN_ROOT=""
  ENF_PLUGIN_ROOT="${ENF_PLUGIN_ROOT%/*}"
  parse "$source"

  if [ "$notice" = 1 ]; then
    input="$NL$(cat)$NL"
    k=0
    while [ "$k" -lt "${#B_LINE[@]}" ]; do
      enf_markers "$k"
      sel=0
      first="${B_RAW[$k]%%$NL*}"
      case "$input" in *"$NL$first$NL"*) sel=1 ;; esac
      rest="$M_LINES"
      while [ "$sel" = 0 ] && [ -n "$rest" ]; do
        line="${rest%%$NL*}"
        rest="${rest#*$NL}"
        case "$input" in *"$NL$line$NL"*) sel=1 ;; esac
      done
      if [ "$sel" = 0 ] && [ "${#nlines[@]}" -gt 0 ]; then
        bullet_end "$k"
        for v in "${nlines[@]}"; do
          # A number this long is past any file's last line.
          [ "${#v}" -le 9 ] || continue
          if [ "$v" -ge "${B_LINE[$k]}" ] && [ "$v" -le "$BE" ]; then sel=1; break; fi
        done
      fi
      if [ "$sel" = 1 ]; then
        enf_eval "$k"
        if [ "$E_TARGET" = 1 ]; then
          printf 'line %s\t%s\t%s\n' "${B_LINE[$k]}" "$(prefix40 "${B_TEXT[$k]}")" "$E_NOTICE"
        fi
      fi
      k=$((k + 1))
    done
    return 0
  fi

  k=0
  while [ "$k" -lt "${#B_LINE[@]}" ]; do
    enf_eval "$k"
    p40=$(prefix40 "${B_TEXT[$k]}")
    case "$E_VERDICT" in
      enforced) enforced=$((enforced + 1)) ;;
      partial) partial=$((partial + 1)) ;;
      prose) prose=$((prose + 1)) ;;
    esac
    rows="${rows}line ${B_LINE[$k]}	${E_VERDICT}	${p40}	${E_LIVE}${NL}"
    if [ -n "$E_REASON" ]; then onlys="${onlys}  line ${B_LINE[$k]}	${p40}	${E_REASON}${NL}"; fi
    if [ -n "$E_GAP" ]; then gaps="${gaps}  line ${B_LINE[$k]}	${p40}	${E_GAP}${NL}"; fi
    rest="$E_DEADS"
    while [ -n "$rest" ]; do
      d="${rest%%$NL*}"
      rest="${rest#*$NL}"
      deads="${deads}  line ${B_LINE[$k]}	$d$NL"
    done
    k=$((k + 1))
  done
  if [ -f "$source" ]; then
    printf 'source: %s\n' "$source"
  else
    printf 'source: %s (absent, read as empty)\n' "$source"
  fi
  printf 'scope: %s\n' "$ENF_SCOPE"
  printf 'rules: total=%s enforced=%s partial=%s prose=%s\n' "${#B_LINE[@]}" "$enforced" "$partial" "$prose"
  printf '%s' "$rows"
  printf 'prose-only:\n%s' "${onlys:-  (none)$NL}"
  printf 'partial gaps:\n%s' "${gaps:-  (none)$NL}"
  printf 'dead means:\n%s' "${deads:-  (none)$NL}"
}

[ $# -ge 1 ] || die_usage "usage: stage-rules.sh extract|status|migrate|enforcement ..."
mode="$1"; shift
case "$mode" in
  extract) cmd_extract "$@" ;;
  status) cmd_status "$@" ;;
  migrate) cmd_migrate "$@" ;;
  enforcement) cmd_enforcement "$@" ;;
  *) die_usage "unknown mode: $mode (extract|status|migrate|enforcement)" ;;
esac
