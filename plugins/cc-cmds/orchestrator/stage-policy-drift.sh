#!/usr/bin/env bash
#
# stage-policy-drift.sh — does the stage policy still say what its sources say?
#
# `stage-policy.md` is a distillation: every rule in it comes from a bullet of
# the user-scope CLAUDE.md, a section of the workspace instruction file the
# host map points at, a promoted memory item, or one line of a plugin file (the
# `plugin` source: a rule the plugin itself owns, such as how a stage's turn
# ends). The distillation is bytes the gate injects into every unattended
# stage, and the sources are files edited by hand, so the two drift apart in
# silence. `stage-policy.sources.tsv`
# is the only link between them: one row per source item, carrying the verbatim
# anchor that finds the item in its source and the sha256 of the item's body
# at the time the policy was written.
#
# This checker re-reads the sources, resolves every anchor, and reports what
# moved. It lives in the plugin rather than under `scripts/` because the
# installed plugin ships only `./plugins/cc-cmds`, and both the gate (at run
# open) and the autopilot kickoff pre-check call it from there. The repository
# half of the drift check — that the policy names every source row and that the
# TSV itself is well formed — is `scripts/lint-stage-policy-sources.sh`, which
# runs under `make lint`. This half is deliberately NOT under `make lint`: a
# person editing their global CLAUDE.md would otherwise turn an unrelated
# unattended implementation stage's `make check` red.
#
# Usage:
#   bash stage-policy-drift.sh [--sources-map <file>] [--plugin-root <dir>]
#
#   The manifest is `stage-policy.sources.tsv` next to this script. The
#   user-scope source is `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/CLAUDE.md` — the
#   same derivation the gate uses for the user-scope settings directory. The
#   workspace source is the path the host map's `workspace` line names; the
#   map defaults to `~/.config/cc-cmds/stage-policy-sources` and holds
#   `<source-id><TAB><absolute path>` lines. One map line therefore does two
#   jobs: it excludes the file from stage synthesis and it tells this checker
#   where the source is. A host that keeps the workspace file in the chain has
#   no such line, so its `workspace` rows are always `SKIP` — accepted, because
#   that host injects the source verbatim and loses nothing when the
#   distillation goes stale.
#
#   A `plugin` row locates its source in the manifest itself: the anchor is
#   `<path>:<line prefix>`, split at the first `:`, and <path> is relative to
#   the plugin root — the directory above this script, overridable with
#   `--plugin-root`. The item is the one line of that file that begins with the
#   prefix, and the hashed body is that line with its newline. The rest of a
#   plugin file is not policy material, so a plugin source never reports
#   `added`.
#
# Output — one finding per line, then a verdict on the last line:
#   added <source> <candidate text>   an item in the source no anchor resolves to
#                                     (user-scope and workspace only)
#   removed <source> <anchor>         an anchor that resolves to no item
#   changed <source> <anchor>         resolved to one item whose body hash differs
#   non-unique <source> <anchor>      resolved to more than one item (never
#                                     folded into `removed`)
#   SKIP <source> <reason>            a source that could not be compared
#   match | mismatch <n> | skipped    `mismatch` when any finding line was
#                                     printed (n = their count), `match` when
#                                     none and at least one source was compared,
#                                     `skipped` when no source was compared.
#
#   `memory` rows carry hash `-`: memory files are written automatically and
#   are not a drift source, so those rows print nothing and take no part in the
#   verdict.
#
# Anchor resolution is a byte-prefix match of the stored anchor against each
# candidate item's first line (user-scope: the bullet text after `- `;
# workspace: the heading line verbatim; plugin: every line of the named file,
# against the part of the anchor after its first `:`, and a missing file is
# `removed`). Exactly one match resolves; zero is
# `removed`; two or more is `non-unique`, reported as its own kind because
# collapsing it into either neighbour would let an anchor that matches several
# places pass as resolved or be discarded as missing.
#
# Exit codes: 0 — `match` or `skipped`; 1 — `mismatch`; 2 — the manifest or the
# map is malformed (the check could not be carried out; never a drift verdict).
#
# Compatibility: bash 3.2, no python, no perl. Hashes use the gate's idiom
# `shasum -a 256 | cut -d' ' -f1`. `LC_ALL=C` so that `${#s}` and `${s:0:n}`
# count bytes — the anchor contract is a BYTE prefix.

set -euo pipefail
export LC_ALL=C

MANIFEST_HEADER=$'source\tanchor\tsha256\tdisposition\tnote'
DISPOSITION_RE='^(policy:[^	]+|skill:[^	]+|repo:CLAUDE\.md|excluded:(mcp-unavailable|interactive-only|driver-owned|superseded|host-mutation|workspace-local|no-stage-login))$'

sha_stdin() { shasum -a 256 | cut -d' ' -f1; }

# drift_entries <source> <file>
# Prints one `<text><TAB><sha256>` line per item of <file> read as <source>.
#   user-scope — every top-level bullet (`- ` at column 0). <text> is the first
#                line without its `- `; the hashed body is that line plus every
#                following line that is indented and not blank (a blank line or
#                an unindented line ends the bullet), each line with its newline.
#   workspace  — every `# ` or `## ` heading. <text> is the heading line
#                verbatim; the hashed body is everything after it up to the next
#                such heading, each line with its newline.
drift_entries() {
  local source="$1" file="$2" line text="" body="" open=0
  emit() {
    [ "$open" = 1 ] || return 0
    printf '%s\t%s\n' "$text" "$(printf '%s' "$body" | sha_stdin)"
  }
  case "$source" in
    user-scope)
      while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
          "- "*)
            emit; open=1; text="${line#- }"; body="$line"$'\n' ;;
          *)
            [ "$open" = 1 ] || continue
            case "$line" in
              [[:space:]]*)
                if [ -n "${line//[[:space:]]/}" ]; then
                  body="$body$line"$'\n'
                else
                  emit; open=0
                fi ;;
              *) emit; open=0 ;;
            esac ;;
        esac
      done < "$file"
      emit ;;
    workspace)
      while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
          "# "*|"## "*)
            emit; open=1; text="$line"; body="" ;;
          *)
            [ "$open" = 1 ] && body="$body$line"$'\n' ;;
        esac
      done < "$file"
      emit ;;
    *) return 2 ;;
  esac
}

die_format() { printf 'stage-policy-drift: %s\n' "$1" >&2; exit 2; }

# validate_manifest <file> — exit 2 on the first malformed row.
validate_manifest() {
  local file="$1" header n rows row source anchor sha disp
  [ -f "$file" ] || die_format "manifest not found: $file"
  header=$(head -n 1 "$file")
  [ "$header" = "$MANIFEST_HEADER" ] \
    || die_format "manifest header must be 'source<TAB>anchor<TAB>sha256<TAB>disposition<TAB>note': $file"
  rows=$(awk -F'\t' 'NR > 1 { print NR "\t" NF }' "$file")
  [ -n "$rows" ] || return 0
  while IFS=$'\t' read -r n row; do
    [ "$row" = 5 ] || die_format "manifest line $n has $row column(s), expected 5: $file"
  done < <(printf '%s\n' "$rows")
  n=0
  while IFS= read -r row || [ -n "$row" ]; do
    n=$((n + 1))
    [ "$n" -gt 1 ] || continue
    source=$(printf '%s\n' "$row" | awk -F'\t' '{ print $1 }')
    anchor=$(printf '%s\n' "$row" | awk -F'\t' '{ print $2 }')
    sha=$(printf '%s\n' "$row" | awk -F'\t' '{ print $3 }')
    disp=$(printf '%s\n' "$row" | awk -F'\t' '{ print $4 }')
    case "$source" in
      user-scope|workspace|memory|plugin) : ;;
      *) die_format "manifest line $n: unknown source '$source' (user-scope|workspace|memory|plugin)" ;;
    esac
    [ -n "$anchor" ] || die_format "manifest line $n: empty anchor"
    if [ "$source" = plugin ]; then
      case "$anchor" in
        ?*:?*) : ;;
        *) die_format "manifest line $n: a plugin anchor is '<path>:<line prefix>', found '$anchor'" ;;
      esac
      case "${anchor%%:*}" in
        /*|..|../*|*/..|*/../*) die_format "manifest line $n: a plugin anchor's path is relative to the plugin root and stays inside it: '$anchor'" ;;
      esac
    fi
    if [ "$source" = memory ]; then
      [ "$sha" = "-" ] || die_format "manifest line $n: a memory row carries hash '-', found '$sha'"
    else
      [[ "$sha" =~ ^[0-9a-f]{64}$ ]] \
        || die_format "manifest line $n: sha256 must be 64 hex characters, found '$sha'"
    fi
    [[ "$disp" =~ $DISPOSITION_RE ]] \
      || die_format "manifest line $n: disposition outside the closed vocabulary: '$disp'"
  done < "$file"
}

# map_lookup <map-file> <source-id> — prints the path the map names for the id.
# A malformed line (no TAB, or a path that is not absolute) is exit 2: a typo
# must not switch an exclusion off silently.
map_lookup() {
  local map="$1" want="$2" line n=0 id path
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    case "$line" in
      ''|'#'*) continue ;;
    esac
    case "$line" in
      *"	"*) : ;;
      *) die_format "map line $n has no TAB: $map" ;;
    esac
    id="${line%%	*}"
    path="${line#*	}"
    case "$path" in
      /*) : ;;
      *) die_format "map line $n: path is not absolute: $map" ;;
    esac
    [ "$id" = "$want" ] && printf '%s\n' "$path" && return 0
  done < "$map"
  return 0
}

findings=0
compared=0

# compare_source <source> <file> <manifest>
compare_source() {
  local source="$1" file="$2" manifest="$3"
  local candidates anchors cand text hash a anchor asha n found_hash matched
  candidates=$(drift_entries "$source" "$file")
  anchors=$(awk -F'\t' -v s="$source" 'NR > 1 && $1 == s { print $2 "\t" $3 }' "$manifest")
  compared=$((compared + 1))
  [ -n "$anchors" ] || return 0
  # each anchor against every candidate: 0 → removed, 1 → hash compare, 2+ → non-unique
  while IFS= read -r a; do
    anchor="${a%	*}"
    asha="${a##*	}"
    n=0; found_hash=""
    if [ -n "$candidates" ]; then
      while IFS= read -r cand; do
        text="${cand%	*}"
        hash="${cand##*	}"
        if [ "${text:0:${#anchor}}" = "$anchor" ]; then
          n=$((n + 1)); found_hash="$hash"
        fi
      done < <(printf '%s\n' "$candidates")
    fi
    if [ "$n" -eq 0 ]; then
      printf 'removed %s %s\n' "$source" "$anchor"; findings=$((findings + 1))
    elif [ "$n" -gt 1 ]; then
      printf 'non-unique %s %s\n' "$source" "$anchor"; findings=$((findings + 1))
    elif [ "$found_hash" != "$asha" ]; then
      printf 'changed %s %s\n' "$source" "$anchor"; findings=$((findings + 1))
    fi
  done < <(printf '%s\n' "$anchors")
  # each candidate no anchor resolves to → added
  [ -n "$candidates" ] || return 0
  while IFS= read -r cand; do
    text="${cand%	*}"
    matched=0
    while IFS= read -r a; do
      anchor="${a%	*}"
      if [ "${text:0:${#anchor}}" = "$anchor" ]; then matched=1; break; fi
    done < <(printf '%s\n' "$anchors")
    if [ "$matched" -eq 0 ]; then
      printf 'added %s %s\n' "$source" "$text"; findings=$((findings + 1))
    fi
  done < <(printf '%s\n' "$candidates")
}

# compare_plugin <plugin-root> <manifest>
# Each plugin row names its own file, so there is no candidate set to report
# `added` from: only removed, non-unique and changed.
compare_plugin() {
  local root="$1" manifest="$2" a anchor asha rel prefix file line n found_hash
  compared=$((compared + 1))
  while IFS= read -r a; do
    [ -n "$a" ] || continue
    anchor="${a%	*}"
    asha="${a##*	}"
    rel="${anchor%%:*}"
    prefix="${anchor#*:}"
    file="$root/$rel"
    n=0; found_hash=""
    if [ -f "$file" ]; then
      while IFS= read -r line || [ -n "$line" ]; do
        if [ "${line:0:${#prefix}}" = "$prefix" ]; then
          n=$((n + 1)); found_hash=$(printf '%s\n' "$line" | sha_stdin)
        fi
      done < "$file"
    fi
    if [ "$n" -eq 0 ]; then
      printf 'removed plugin %s\n' "$anchor"; findings=$((findings + 1))
    elif [ "$n" -gt 1 ]; then
      printf 'non-unique plugin %s\n' "$anchor"; findings=$((findings + 1))
    elif [ "$found_hash" != "$asha" ]; then
      printf 'changed plugin %s\n' "$anchor"; findings=$((findings + 1))
    fi
  done < <(awk -F'\t' 'NR > 1 && $1 == "plugin" { print $2 "\t" $3 }' "$manifest")
}

main() {
  local script_dir manifest map cfgdir user_file ws_file plugin_root
  script_dir=$(cd "$(dirname "$0")" && pwd)
  manifest="$script_dir/stage-policy.sources.tsv"
  map="${HOME:-}/.config/cc-cmds/stage-policy-sources"
  plugin_root=$(cd "$script_dir/.." && pwd)
  while [ $# -gt 0 ]; do
    case "$1" in
      --sources-map) [ $# -ge 2 ] || die_format "--sources-map needs a file"; map="$2"; shift 2 ;;
      --plugin-root) [ $# -ge 2 ] || die_format "--plugin-root needs a directory"; plugin_root="$2"; shift 2 ;;
      -h|--help) sed -n '2,80p' "$0"; exit 0 ;;
      *) die_format "unknown argument: $1" ;;
    esac
  done
  validate_manifest "$manifest"

  # user-scope — the same derivation the gate uses for the user settings directory
  cfgdir="${CLAUDE_CONFIG_DIR:-}"
  [ -n "$cfgdir" ] || cfgdir="${HOME:-}/.claude"
  user_file="$cfgdir/CLAUDE.md"
  if awk -F'\t' 'NR > 1 && $1 == "user-scope" { f = 1 } END { exit !f }' "$manifest"; then
    if [ -f "$user_file" ]; then
      compare_source user-scope "$user_file" "$manifest"
    else
      printf 'SKIP user-scope source file not found: %s\n' "$user_file"
    fi
  fi

  # workspace — located only through the host map
  if awk -F'\t' 'NR > 1 && $1 == "workspace" { f = 1 } END { exit !f }' "$manifest"; then
    if [ ! -f "$map" ]; then
      printf 'SKIP workspace host map not found: %s\n' "$map"
    else
      ws_file=$(map_lookup "$map" workspace)
      if [ -z "$ws_file" ]; then
        printf 'SKIP workspace host map has no workspace line: %s\n' "$map"
      elif [ ! -f "$ws_file" ]; then
        printf 'SKIP workspace source file not found: %s\n' "$ws_file"
      else
        compare_source workspace "$ws_file" "$manifest"
      fi
    fi
  fi

  # plugin — each row names its file relative to the plugin root
  if awk -F'\t' 'NR > 1 && $1 == "plugin" { f = 1 } END { exit !f }' "$manifest"; then
    if [ -d "$plugin_root" ]; then
      compare_plugin "$plugin_root" "$manifest"
    else
      printf 'SKIP plugin root not found: %s\n' "$plugin_root"
    fi
  fi

  # memory rows: not a drift source, no output, no part in the verdict
  if [ "$findings" -gt 0 ]; then
    printf 'mismatch %d\n' "$findings"; exit 1
  elif [ "$compared" -gt 0 ]; then
    printf 'match\n'; exit 0
  else
    printf 'skipped\n'; exit 0
  fi
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
