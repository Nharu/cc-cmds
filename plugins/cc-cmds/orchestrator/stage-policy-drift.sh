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
#                              [--config-dir <dir>]... [--ack-store <dir>]
#                              [--workspace <file>]
#                              [--explain] [--ack]
#                              [--ack-added <anchor prefix> <disposition>]
#   bash stage-policy-drift.sh --identity <file> [--ack-store <dir>]
#
#   The manifest is `stage-policy.sources.tsv` next to this script. The
#   user-scope source is `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/CLAUDE.md` — the
#   same derivation the gate uses for the user-scope settings directory —
#   unless `--config-dir` names directories: then it is `<dir>/CLAUDE.md` for
#   each, compared in turn under a `config-dir <dir>` line, and a named
#   directory with no CLAUDE.md is a `missing` finding rather than a `SKIP`.
#   The last line is the verdict over every directory. The
#   workspace source is the file `--workspace` names, else the path the host
#   map's `workspace` line names; the map defaults to
#   `~/.config/cc-cmds/stage-policy-sources` and holds
#   `<source-id><TAB><absolute path>` lines. A map line with any source id but
#   `keep` excludes the file from stage synthesis outright, and its `workspace`
#   line also tells this checker where the source is. A `keep` line puts the
#   file into every stage's chain verbatim and switches the identity judgment
#   below off for it. With neither a `workspace` line nor `--workspace`, the
#   `workspace` rows are `SKIP`.
#
#   --workspace <file>
#                 compare the workspace rows against <file> without a map. In
#                 this form only, an `excluded:*` row's body is compared too,
#                 a host-local one recorded with `--ack-added` as well as a
#                 manifest row: the gate leaves such a file out of a stage by
#                 the identity judgment below, which hashes every body, so a
#                 body edit is reported `changed` under `--explain` and
#                 recorded by `--ack` at its new hash. A source found through the map, and the
#                 user-scope source, still check an `excluded:*` row by its
#                 anchor alone: a mapped file is excluded whatever it says.
#
#   --identity <file>
#                 the gate's judgment for an ancestor instruction file outside
#                 the target repository that no map line names: exit 0 means
#                 the file may be left out of a stage's chain, because the
#                 policy and the manifest already account for every section of
#                 it. All three must hold — (a) no line that is not blank
#                 stands before the first `# ` or `## ` heading, since such
#                 text is in no row's hash; (b) every section, split as the
#                 `workspace` source is split, matches one `workspace` row by
#                 its verbatim heading and is fresh: its body hashes to the
#                 manifest hash, or the store holds (workspace, anchor,
#                 sha256) — for `excluded:*` rows as for `policy:*` rows — or
#                 it resolves to a host-local disposition recorded with
#                 `--ack-added`, whose prefix matches that section alone of
#                 the file and whose body hashes to a sha256 the store holds
#                 for it (the one `--ack-added` recorded, or a later `--ack`);
#                 (c) the row's disposition is `policy:*` or `excluded:*`, or a
#                 host-local `excluded:*`. A file with at least
#                 one heading equal to a `workspace` anchor is identified as
#                 the workspace source; when an identified file fails, one line
#                 per breaking section (the heading, both hashes, or `added
#                 section`) goes to stderr. A file that is not identified
#                 fails silently with exit 1. Never a drift verdict and never
#                 a store write.
#
#   A `plugin` row locates its source in the manifest itself: the anchor is
#   `<path>:<line prefix>`, split at the first `:`, and <path> is relative to
#   the plugin root — the directory above this script, overridable with
#   `--plugin-root`. The item is the one line of that file that begins with the
#   prefix, and the hashed body is that line with its newline. The rest of a
#   plugin file is not policy material, so a plugin source never reports
#   `added`.
#
#   --explain     under each `changed` finding, print the row's disposition and
#                 a unified diff of the body this host last acknowledged against
#                 the current body; with no previous body on this host, say so
#                 and print the current body. Under each `added` finding, print
#                 the current body. Every such line is indented by two spaces;
#                 it is not a finding and is not counted in the verdict.
#   --ack         record every finding a person can acknowledge — `changed` on a
#                 `policy:*` or `skill:*` row at its current hash (and, under
#                 `--workspace`, on an `excluded:*` workspace row too, host-local
#                 or not), `removed` on
#                 an `excluded:*` row at hash `-` — then store the current body of
#                 every resolved row, then compare again and print as usual. It
#                 records every pending finding at once; there is no per-row
#                 form, so a caller confirms them all before running it.
#                 `non-unique`, `removed` on a `policy:*` or `skill:*` row, and
#                 `added` with no disposition cannot be acknowledged and stay,
#                 and so does every `plugin` finding: its source ships with the
#                 plugin, so a change there is settled in the repository.
#   --ack-added <anchor prefix> <disposition>
#                 give an added item a host-local disposition. Only
#                 `excluded:<closed reason>` and `skill:<name>` are accepted;
#                 `policy:*` and `repo:CLAUDE.md` mean the policy text or the
#                 repository instructions must change, which is a repository
#                 change, and are exit 2. The prefix must match exactly one
#                 candidate item of the sources, that item must be `added`, and
#                 the prefix must overlap no manifest anchor, else exit 2 and
#                 the store is left as it was.
#   --ack-store <dir>
#                 the acknowledgement store; defaults to
#                 `~/.config/cc-cmds/stage-policy-ack`.
#
#   An acknowledgement is a person's claim that the distillation still says
#   what the source says. This checker cannot judge that claim, so `--ack` and
#   `--ack-added` are refused (exit 2, store untouched) whenever
#   `CC_PIPELINE_RUN_ID` is set: an unattended stage has nobody to confirm.
#
# Acknowledgement store — host-local, never in the repository, because it
# holds the text of a person's own files. The directory is mode 700 and every
# file in it mode 600; a store that does not exist reads as empty.
#   acks.tsv          `source<TAB>anchor<TAB>sha256<TAB>disposition<TAB>acked-at`
#   bodies/<sha256>   the bytes of an item body as they were when acknowledged,
#                     the base of the next `--explain` diff
# Writes go to a temporary file in the same directory and are moved into place.
#
# Freshness. The manifest's sha256 column stays the shipped baseline. A
# `policy:*` or `skill:*` row is fresh when its current body hash equals the
# manifest hash or the store holds the same (source, anchor, sha256). An
# `excluded:*` row's body reaches no stage, so only its anchor is checked: it
# is fresh when the anchor resolves to exactly one item, or when it resolves to
# none and the store holds (source, anchor, `-`). Under `--workspace` a
# workspace `excluded:*` row, a host-local one included, is compared like a
# `policy:*` row as well, because
# there the gate's identity judgment is what keeps the body out of a stage, and
# that judgment hashes it. A store row whose disposition
# is `excluded:*` or `skill:*` and whose anchor is no manifest anchor is a
# host-local disposition: it is compared by the same rules and the item it
# resolves to is not `added`. When it resolves to nothing it is ignored,
# because the manifest is what the verdict answers to. When it resolves to
# several items — a bullet added later shares its prefix — it is ignored too
# and never reported `non-unique`: it resolves nothing, so each of those items
# reads as `added` again and can be given a longer prefix with `--ack-added`.
# A `plugin` row is fresh only when its line hashes to the manifest hash; the
# store is never consulted for it.
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
# Exit codes: 0 — `match` or `skipped`; 1 — `mismatch`; 2 — the manifest, the
# map or the store is malformed, or an acknowledgement was refused (the check
# or the record could not be carried out; never a drift verdict). Under
# `--identity`: 0 — leave the file out; 1 — keep it; 2 — as above.
#
# Compatibility: bash 3.2, no python, no perl. Hashes use the gate's idiom
# `shasum -a 256 | cut -d' ' -f1`. `LC_ALL=C` so that `${#s}` and `${s:0:n}`
# count bytes — the anchor contract is a BYTE prefix.

set -euo pipefail
export LC_ALL=C

MANIFEST_HEADER=$'source\tanchor\tsha256\tdisposition\tnote'
DISPOSITION_RE='^(policy:[^	]+|skill:[^	]+|repo:CLAUDE\.md|excluded:(mcp-unavailable|interactive-only|driver-owned|superseded|host-mutation|workspace-local|no-stage-login))$'
LOCAL_DISPOSITION_RE='^(skill:[^[:space:]]+|excluded:(mcp-unavailable|interactive-only|driver-owned|superseded|host-mutation|workspace-local|no-stage-login))$'
ACK_HEADER=$'source\tanchor\tsha256\tdisposition\tacked-at'

sha_stdin() { shasum -a 256 | cut -d' ' -f1; }

# drift_entries <source> <file> [<body dir>]
# Prints one `<text><TAB><sha256>` line per item of <file> read as <source>.
#   user-scope — every top-level bullet (`- ` at column 0). <text> is the first
#                line without its `- `; the hashed body is that line plus every
#                following line that is indented and not blank (a blank line or
#                an unindented line ends the bullet), each line with its newline.
#   workspace  — every `# ` or `## ` heading. <text> is the heading line
#                verbatim; the hashed body is everything after it up to the next
#                such heading, each line with its newline.
# With <body dir>, the hashed bytes of each item are also written to
# `<body dir>/<sha256>`, so a body can be shown or stored without re-reading.
drift_entries() {
  local source="$1" file="$2" bodydir="${3:-}" line text="" body="" open=0 h
  emit() {
    [ "$open" = 1 ] || return 0
    h=$(printf '%s' "$body" | sha_stdin)
    [ -z "$bodydir" ] || printf '%s' "$body" > "$bodydir/$h"
    printf '%s\t%s\n' "$text" "$h"
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
EXPLAIN=0
STORE=""
ACK_FILE=""
# ACKS — the store's rows between newlines, so that a (source, anchor, sha256)
# key is one literal `case` pattern.
ACKS=$'\n'
BODY_TMP=""
# Filled by every comparison pass, read by the acknowledgement writers.
ACK_PENDING=""
RESOLVED=""
ADDED_ITEMS=""
# every candidate item of every compared source, `source<TAB>sha256<TAB>text`;
# the text is last so that a TAB inside it cannot shift the hash
ALL_ITEMS=""
# the directories `--config-dir` named, in order; empty means the derivation
CONFIG_DIRS=()
# the file `--workspace` named; empty means the host map locates the source
WORKSPACE_FILE=""

# load_store — reads acks.tsv into ACKS; an absent store reads as empty.
load_store() {
  local rows n row
  ACK_FILE="$STORE/acks.tsv"
  ACKS=$'\n'
  [ -f "$ACK_FILE" ] || return 0
  [ "$(head -n 1 "$ACK_FILE")" = "$ACK_HEADER" ] \
    || die_format "store header must be 'source<TAB>anchor<TAB>sha256<TAB>disposition<TAB>acked-at': $ACK_FILE"
  rows=$(awk -F'\t' 'NR > 1 { print NR "\t" NF }' "$ACK_FILE")
  if [ -n "$rows" ]; then
    while IFS=$'\t' read -r n row; do
      [ "$row" = 5 ] || die_format "store line $n has $row column(s), expected 5: $ACK_FILE"
    done < <(printf '%s\n' "$rows")
  fi
  ACKS=$'\n'"$(tail -n +2 "$ACK_FILE")"$'\n'
}

# acked <source> <anchor> <sha256> — the store holds that exact row key.
acked() {
  case "$ACKS" in
    *$'\n'"$1	$2	$3	"*) return 0 ;;
  esac
  return 1
}

# explain_changed <source> <anchor> <manifest sha256 or -> <current sha256> <disposition>
# The diff base is the body stored for the last hash this host acknowledged
# for the anchor, else for the manifest hash.
explain_changed() {
  local source="$1" anchor="$2" asha="$3" cur="$4" disp="$5" prev="" h
  printf '  disposition: %s\n' "$disp"
  if [ -f "$ACK_FILE" ]; then
    h=$(S="$source" A="$anchor" awk -F'\t' \
      'NR > 1 && $1 == ENVIRON["S"] && $2 == ENVIRON["A"] && $3 != "-" { h = $3 } END { print h }' "$ACK_FILE")
    [ -n "$h" ] && [ -f "$STORE/bodies/$h" ] && prev="$h"
  fi
  if [ -z "$prev" ] && [ "$asha" != "-" ] && [ -f "$STORE/bodies/$asha" ]; then
    prev="$asha"
  fi
  if [ -n "$prev" ]; then
    { diff -u -L acknowledged -L current "$STORE/bodies/$prev" "$BODY_TMP/$cur" || true; } | sed 's/^/  /'
  else
    printf '  no previous body on this host; current body:\n'
    sed 's/^/  /' "$BODY_TMP/$cur"
  fi
}

# compare_source <source> <file> <manifest>
compare_source() {
  local source="$1" file="$2" manifest="$3"
  local candidates anchors local_rows cand text hash anchor asha adisp akind n found_hash matched
  local live=""
  candidates=$(drift_entries "$source" "$file" "$BODY_TMP")
  if [ -n "$candidates" ]; then
    while IFS= read -r cand; do
      ALL_ITEMS="${ALL_ITEMS}${source}	${cand##*	}	${cand%	*}"$'\n'
    done < <(printf '%s\n' "$candidates")
  fi
  anchors=$(awk -F'\t' -v s="$source" 'NR > 1 && $1 == s { print $2 "\t" $3 "\t" $4 "\ttable" }' "$manifest")
  # host-local dispositions: store rows for an anchor the manifest does not carry
  if [ -f "$ACK_FILE" ]; then
    local_rows=$(awk -F'\t' -v s="$source" '
      FNR == NR { if (FNR > 1 && $1 == s) t[$2] = 1; next }
      FNR > 1 && $1 == s && !($2 in t) && $4 ~ /^(excluded|skill):/ {
        if (!($2 in d)) order[++k] = $2
        d[$2] = $4
      }
      END { for (i = 1; i <= k; i++) print order[i] "\t-\t" d[order[i]] "\tlocal" }' "$manifest" "$ACK_FILE")
    if [ -n "$local_rows" ]; then
      if [ -n "$anchors" ]; then anchors="$anchors"$'\n'"$local_rows"; else anchors="$local_rows"; fi
    fi
  fi
  compared=$((compared + 1))
  if [ -n "$anchors" ]; then
    # each anchor against every candidate: 0 → removed, 1 → compare, 2+ → non-unique
    while IFS=$'\t' read -r anchor asha adisp akind; do
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
      # a host-local row that resolves to nothing, or to several items, is
      # ignored: it resolves nothing, so the items it matches read as `added`
      # again and can each be given a longer prefix
      if [ "$akind" != table ] && [ "$n" -ne 1 ]; then
        continue
      fi
      live="${live}${anchor}	${asha}	${adisp}	${akind}"$'\n'
      if [ "$n" -eq 0 ]; then
        case "$adisp" in
          excluded:*)
            acked "$source" "$anchor" - && continue
            ACK_PENDING="${ACK_PENDING}${source}	${anchor}	-	${adisp}"$'\n' ;;
        esac
        printf 'removed %s %s\n' "$source" "$anchor"; findings=$((findings + 1))
      elif [ "$n" -gt 1 ]; then
        printf 'non-unique %s %s\n' "$source" "$anchor"; findings=$((findings + 1))
      else
        RESOLVED="$RESOLVED$found_hash"$'\n'
        # an excluded row's body reaches no stage: its anchor is all that is
        # checked — except a workspace row under `--workspace`, table or
        # host-local, whose body the gate's identity judgment hashes
        case "$adisp" in
          excluded:*)
            [ -n "$WORKSPACE_FILE" ] && [ "$source" = workspace ] || continue ;;
        esac
        [ "$akind" = table ] && [ "$found_hash" = "$asha" ] && continue
        acked "$source" "$anchor" "$found_hash" && continue
        ACK_PENDING="${ACK_PENDING}${source}	${anchor}	${found_hash}	${adisp}"$'\n'
        printf 'changed %s %s\n' "$source" "$anchor"; findings=$((findings + 1))
        [ "$EXPLAIN" = 0 ] || explain_changed "$source" "$anchor" "$asha" "$found_hash" "$adisp"
      fi
    done < <(printf '%s\n' "$anchors")
  fi
  # each candidate no anchor resolves to → added
  [ -n "$candidates" ] || return 0
  while IFS= read -r cand; do
    text="${cand%	*}"
    hash="${cand##*	}"
    matched=0
    if [ -n "$live" ]; then
      while IFS=$'\t' read -r anchor asha adisp akind; do
        [ -n "$anchor" ] || continue
        if [ "${text:0:${#anchor}}" = "$anchor" ]; then matched=1; break; fi
      done < <(printf '%s' "$live")
    fi
    if [ "$matched" -eq 0 ]; then
      printf 'added %s %s\n' "$source" "$text"; findings=$((findings + 1))
      ADDED_ITEMS="${ADDED_ITEMS}${source}	${text}	${hash}"$'\n'
      if [ "$EXPLAIN" = 1 ]; then
        printf '  body:\n'
        sed 's/^/  /' "$BODY_TMP/$hash"
      fi
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

# compare_all <manifest> <map> <plugin-root> — one full comparison pass over every source.
compare_all() {
  local manifest="$1" map="$2" plugin_root="$3" cfgdir user_file ws_file
  findings=0; compared=0; ACK_PENDING=""; RESOLVED=""; ADDED_ITEMS=""; ALL_ITEMS=""

  # user-scope — the same derivation the gate uses for the user settings directory
  if awk -F'\t' 'NR > 1 && $1 == "user-scope" { f = 1 } END { exit !f }' "$manifest"; then
    if [ "${#CONFIG_DIRS[@]}" -eq 0 ]; then
      cfgdir="${CLAUDE_CONFIG_DIR:-}"
      [ -n "$cfgdir" ] || cfgdir="${HOME:-}/.claude"
      user_file="$cfgdir/CLAUDE.md"
      if [ -f "$user_file" ]; then
        compare_source user-scope "$user_file" "$manifest"
      else
        printf 'SKIP user-scope source file not found: %s\n' "$user_file"
      fi
    else
      # named directories: each is compared on its own, and one a caller named
      # that holds no CLAUDE.md is a finding — the caller said a stage reads it
      for cfgdir in "${CONFIG_DIRS[@]}"; do
        user_file="${cfgdir%/}/CLAUDE.md"
        printf 'config-dir %s\n' "$cfgdir"
        if [ -f "$user_file" ]; then
          compare_source user-scope "$user_file" "$manifest"
        else
          compared=$((compared + 1))
          printf 'missing user-scope %s\n' "$user_file"; findings=$((findings + 1))
        fi
      done
    fi
  fi

  # workspace — the file `--workspace` names, else through the host map
  if awk -F'\t' 'NR > 1 && $1 == "workspace" { f = 1 } END { exit !f }' "$manifest"; then
    if [ -n "$WORKSPACE_FILE" ]; then
      if [ -f "$WORKSPACE_FILE" ]; then
        compare_source workspace "$WORKSPACE_FILE" "$manifest"
      else
        printf 'SKIP workspace source file not found: %s\n' "$WORKSPACE_FILE"
      fi
    elif [ ! -f "$map" ]; then
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
  return 0
}

# store_init — creates the store (directory mode 700, bodies/ too) if absent.
store_init() {
  umask 077
  mkdir -p "$STORE/bodies"
  chmod 700 "$STORE" "$STORE/bodies"
}

# store_rows <rows> — appends `source<TAB>anchor<TAB>sha256<TAB>disposition`
# rows the store does not already key, each stamped with the time of the record.
store_rows() {
  local rows="$1" tmp now source anchor sha disp
  [ -n "$rows" ] || [ ! -f "$ACK_FILE" ] || return 0
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  tmp=$(mktemp "$STORE/.acks.XXXXXX")
  if [ -f "$ACK_FILE" ]; then cp "$ACK_FILE" "$tmp"; else printf '%s\n' "$ACK_HEADER" > "$tmp"; fi
  while IFS=$'\t' read -r source anchor sha disp; do
    [ -n "$source" ] || continue
    acked "$source" "$anchor" "$sha" && continue
    printf '%s\t%s\t%s\t%s\t%s\n' "$source" "$anchor" "$sha" "$disp" "$now" >> "$tmp"
    ACKS="${ACKS}${source}	${anchor}	${sha}	${disp}	${now}"$'\n'
  done < <(printf '%s' "$rows")
  chmod 600 "$tmp"
  mv -f "$tmp" "$ACK_FILE"
}

# store_bodies <hashes> — stores each body not already in bodies/.
store_bodies() {
  local h tmp
  while IFS= read -r h; do
    [ -n "$h" ] || continue
    [ -f "$STORE/bodies/$h" ] && continue
    tmp=$(mktemp "$STORE/bodies/.body.XXXXXX")
    cp "$BODY_TMP/$h" "$tmp"
    chmod 600 "$tmp"
    mv -f "$tmp" "$STORE/bodies/$h"
  done < <(printf '%s' "$1")
}

# ack_added <manifest> <prefix> <disposition> — records one host-local disposition.
# Uniqueness is counted over every candidate item, not only the added ones: a
# prefix that also matches an item something else already resolves would be
# stored as a row that resolves to two items from its first comparison on.
ack_added() {
  local manifest="$1" prefix="$2" disp="$3" source text hash hits=0
  local hit_source="" hit_hash="" hit_text="" a
  if [ -n "$ALL_ITEMS" ]; then
    while IFS=$'\t' read -r source hash text; do
      [ -n "$source" ] || continue
      if [ "${text:0:${#prefix}}" = "$prefix" ]; then
        hits=$((hits + 1)); hit_source="$source"; hit_hash="$hash"; hit_text="$text"
      fi
    done < <(printf '%s' "$ALL_ITEMS")
  fi
  [ "$hits" -eq 1 ] \
    || die_format "--ack-added: the prefix must match exactly one item of the sources, it matches $hits: $prefix"
  case $'\n'"$ADDED_ITEMS" in
    *$'\n'"${hit_source}	${hit_text}	${hit_hash}"$'\n'*) : ;;
    *) die_format "--ack-added: the item the prefix matches is not added (an anchor already resolves it): $prefix" ;;
  esac
  while IFS= read -r a; do
    [ -n "$a" ] || continue
    if [ "${a:0:${#prefix}}" = "$prefix" ] || [ "${prefix:0:${#a}}" = "$a" ]; then
      die_format "--ack-added: the prefix overlaps the manifest anchor '$a'"
    fi
  done < <(awk -F'\t' -v s="$hit_source" 'NR > 1 && $1 == s { print $2 }' "$manifest")
  store_init
  store_rows "${hit_source}	${prefix}	${hit_hash}	${disp}"$'\n'
  store_bodies "$hit_hash"$'\n'
}

# identity <manifest> <file> — the `--identity` judgment; returns 0 when <file>
# may be left out of a stage's chain. It reads the store and writes nothing.
identity() {
  local manifest="$1" file="$2" anchors local_rows cand text hash
  local hits row anchor asha adisp akind line pre="" identified=0 broken=""
  [ -f "$file" ] || return 1
  anchors=$(awk -F'\t' 'NR > 1 && $1 == "workspace" { print $2 "\t" $3 "\t" $4 }' "$manifest")
  [ -n "$anchors" ] || return 1
  local_rows=""
  if [ -f "$ACK_FILE" ]; then
    local_rows=$(awk -F'\t' '
      FNR == NR { if (FNR > 1 && $1 == "workspace") t[$2] = 1; next }
      FNR > 1 && $1 == "workspace" && !($2 in t) && $4 ~ /^(excluded|skill):/ { d[$2] = $4; h[$2] = $3 }
      END { for (a in d) print a "\t" (h[a] == "" ? "-" : h[a]) "\t" d[a] }' "$manifest" "$ACK_FILE")
  fi
  # (a) text before the first heading is in no row's hash
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "# "*|"## "*) break ;;
    esac
    [ -z "${line//[[:space:]]/}" ] || { pre=1; break; }
  done < "$file"
  local candidates live_local="" n c
  candidates=$(drift_entries workspace "$file")
  [ -n "$candidates" ] || return 1
  # a host-local disposition resolves as the checker resolves it: its prefix is
  # counted over every section, and one that matches none or several resolves
  # nothing, so the sections it would match read as added
  if [ -n "$local_rows" ]; then
    while IFS=$'\t' read -r anchor asha adisp; do
      [ -n "$anchor" ] || continue
      n=0
      while IFS= read -r c; do
        c="${c%	*}"
        [ "${c:0:${#anchor}}" = "$anchor" ] && n=$((n + 1))
      done < <(printf '%s\n' "$candidates")
      [ "$n" -eq 1 ] && live_local="${live_local}${anchor}	${asha}	${adisp}"$'\n'
    done < <(printf '%s\n' "$local_rows")
  fi
  while IFS= read -r cand; do
    text="${cand%	*}"
    hash="${cand##*	}"
    # a manifest row matches by its verbatim heading
    row=""; hits=0
    while IFS=$'\t' read -r anchor asha adisp; do
      [ -n "$anchor" ] || continue
      if [ "$text" = "$anchor" ]; then hits=$((hits + 1)); row="${anchor}	${asha}	${adisp}	table"; fi
    done < <(printf '%s\n' "$anchors")
    if [ "$hits" -ge 1 ]; then
      identified=1
    elif [ -n "$live_local" ]; then
      while IFS=$'\t' read -r anchor asha adisp; do
        [ -n "$anchor" ] || continue
        if [ "${text:0:${#anchor}}" = "$anchor" ]; then hits=$((hits + 1)); row="${anchor}	${asha}	${adisp}	local"; fi
      done < <(printf '%s' "$live_local")
    fi
    if [ "$hits" -eq 0 ]; then
      broken="${broken}${text}: added section"$'\n'
      continue
    fi
    if [ "$hits" -gt 1 ]; then
      broken="${broken}${text}: matches $hits rows"$'\n'
      continue
    fi
    IFS=$'\t' read -r anchor asha adisp akind <<< "$row"
    # a host-local row is fresh only at a hash this host recorded for it, and
    # only an excluded one leaves the file out: a skill's body reaches a stage
    # through that skill, not through this judgment
    if [ "$akind" = local ]; then
      case "$adisp" in
        excluded:*) : ;;
        *) broken="${broken}${text}: host-local disposition $adisp is not excluded"$'\n'; continue ;;
      esac
      acked workspace "$anchor" "$hash" && continue
      broken="${broken}${text}: host-local acknowledged $asha, current $hash"$'\n'
      continue
    fi
    case "$adisp" in
      policy:*|excluded:*) : ;;
      *) broken="${broken}${text}: disposition $adisp is not policy or excluded"$'\n'; continue ;;
    esac
    [ "$hash" = "$asha" ] && continue
    acked workspace "$anchor" "$hash" && continue
    broken="${broken}${text}: manifest $asha, current $hash"$'\n'
  done < <(printf '%s\n' "$candidates")
  [ "$identified" = 1 ] || return 1
  if [ -n "$pre" ]; then
    broken="(before the first heading): text no row hashes"$'\n'"$broken"
  fi
  [ -n "$broken" ] || return 0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    printf 'stage-policy-drift: identity broken: %s: %s\n' "$file" "$line" >&2
  done < <(printf '%s' "$broken")
  return 1
}

main() {
  local script_dir manifest map plugin_root do_ack=0 identity_file="" add_prefix="" add_disp="" do_add=0 explain=0
  script_dir=$(cd "$(dirname "$0")" && pwd)
  manifest="$script_dir/stage-policy.sources.tsv"
  map="${HOME:-}/.config/cc-cmds/stage-policy-sources"
  plugin_root=$(cd "$script_dir/.." && pwd)
  STORE="${HOME:-}/.config/cc-cmds/stage-policy-ack"
  while [ $# -gt 0 ]; do
    case "$1" in
      --sources-map) [ $# -ge 2 ] || die_format "--sources-map needs a file"; map="$2"; shift 2 ;;
      --plugin-root) [ $# -ge 2 ] || die_format "--plugin-root needs a directory"; plugin_root="$2"; shift 2 ;;
      --config-dir) [ $# -ge 2 ] && [ -n "$2" ] || die_format "--config-dir needs a directory"; CONFIG_DIRS+=("$2"); shift 2 ;;
      --ack-store) [ $# -ge 2 ] || die_format "--ack-store needs a directory"; STORE="$2"; shift 2 ;;
      --workspace) [ $# -ge 2 ] && [ -n "$2" ] || die_format "--workspace needs a file"; WORKSPACE_FILE="$2"; shift 2 ;;
      --identity) [ $# -ge 2 ] && [ -n "$2" ] || die_format "--identity needs a file"; identity_file="$2"; shift 2 ;;
      --explain) explain=1; shift ;;
      --ack) do_ack=1; shift ;;
      --ack-added)
        [ $# -ge 3 ] || die_format "--ack-added needs an anchor prefix and a disposition"
        do_add=1; add_prefix="$2"; add_disp="$3"; shift 3 ;;
      -h|--help) awk 'NR > 1 && /^#/ { print; next } NR > 1 { exit }' "$0"; exit 0 ;;
      *) die_format "unknown argument: $1" ;;
    esac
  done
  # an acknowledgement is a person's claim; an unattended stage has nobody to make it
  if { [ "$do_ack" = 1 ] || [ "$do_add" = 1 ]; } && [ -n "${CC_PIPELINE_RUN_ID:-}" ]; then
    die_format "refusing to record an acknowledgement: CC_PIPELINE_RUN_ID is set, and an unattended stage has nobody to confirm the distillation"
  fi
  if [ "$do_add" = 1 ]; then
    [ -n "$add_prefix" ] || die_format "--ack-added: empty anchor prefix"
    case "$add_disp" in
      policy:*|repo:CLAUDE.md)
        die_format "--ack-added: '$add_disp' means the policy text or the repository instructions must change, which is a repository change; edit stage-policy.md and stage-policy.sources.tsv in the repository instead" ;;
    esac
    [[ "$add_disp" =~ $LOCAL_DISPOSITION_RE ]] \
      || die_format "--ack-added: disposition must be excluded:<closed reason> or skill:<name>: '$add_disp'"
  fi
  if [ -n "$identity_file" ]; then
    { [ "$explain" = 0 ] && [ "$do_ack" = 0 ] && [ "$do_add" = 0 ] && [ -z "$WORKSPACE_FILE" ]; } \
      || die_format "--identity takes no other mode"
    validate_manifest "$manifest"
    load_store
    identity "$manifest" "$identity_file" && exit 0
    exit 1
  fi
  validate_manifest "$manifest"
  load_store
  if [ "$explain" = 1 ] || [ "$do_ack" = 1 ] || [ "$do_add" = 1 ]; then
    BODY_TMP=$(mktemp -d "${TMPDIR:-/tmp}/stage-policy-drift.XXXXXX")
    trap 'rm -rf "$BODY_TMP"' EXIT
  fi

  # recording passes are silent; the pass after them prints as usual
  if [ "$do_add" = 1 ]; then
    compare_all "$manifest" "$map" "$plugin_root" > /dev/null
    ack_added "$manifest" "$add_prefix" "$add_disp"
    load_store
  fi
  if [ "$do_ack" = 1 ]; then
    compare_all "$manifest" "$map" "$plugin_root" > /dev/null
    store_init
    store_rows "$ACK_PENDING"
    store_bodies "$RESOLVED"
    load_store
  fi
  EXPLAIN="$explain"
  compare_all "$manifest" "$map" "$plugin_root"

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
