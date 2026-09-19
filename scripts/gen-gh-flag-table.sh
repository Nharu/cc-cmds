#!/bin/bash
# gen-gh-flag-table.sh — build the gh flag table the gate's argv parser carries.
#
# WHY A GENERATOR AND NOT A HAND-WRITTEN LIST. `-R/--repo` is not a root flag in
# gh: it is attached per command, so `gh repo delete`, `gh api`, `gh auth token`
# and a handful of others do not accept it while their siblings do. A hand-kept
# enumeration answers confidently about the arms nobody checked, and the parser
# built on it would call a spelling real gh rejects a well-formed one. Reading
# every leaf's own `--help` is the only way the table is complete by
# construction.
#
# `gh help reference` IS NOT USED. It omits the inherited `-R` in most groups,
# which is exactly the flag the table exists to place correctly.
#
# The output is the BODY of the heredoc inside gate.sh's `gp_gh_flag_table`, not
# a file the gate reads at runtime. A runtime file would let an already-running
# gate — this repository's install is its own worktree — read a new table with
# its old parser, which is the mixed-version failure the embedded heredoc avoids:
# bash reads a function's body, heredoc included, at definition time.
#
# NETWORK. Every call runs against an invalid host with an empty token and a
# throwaway config directory, so `--help` renders from the binary alone and no
# request leaves the machine.
set -uo pipefail

# `sort -u` orders each row's flags, and a locale-aware collation would make the
# same gh produce a different table on a machine with a different LANG.
export LC_ALL=C

GH_PIN='2.100.0'

self_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$self_dir/.." && pwd)
GATE="$repo_root/plugins/cc-cmds/orchestrator/gate.sh"

usage() {
  cat <<'USAGE'
usage: gen-gh-flag-table.sh [--check]

  (no flag)  print the table body to stdout, for pasting into gate.sh's
             `gp_gh_flag_table` heredoc
  --check    regenerate with the installed gh and diff against the table
             gate.sh carries; a gh other than the pinned version prints a skip
             notice and exits 0
USAGE
}

mode=emit
case "${1:-}" in
  '') ;;
  --check) mode=check ;;
  -h|--help) usage; exit 0 ;;
  *) printf 'gen-gh-flag-table: 모르는 인자입니다: %s\n' "$1" >&2; usage >&2; exit 2 ;;
esac

command -v gh >/dev/null 2>&1 || {
  printf 'gen-gh-flag-table: gh 가 PATH 에 없습니다\n' >&2
  exit 2
}

gh_version=$(gh --version 2>/dev/null | sed -n '1s/^gh version \([^ ]*\).*/\1/p')

# THE VERSION GUARD IS A SKIP, NOT A FAILURE, AND ONLY UNDER `--check`. The
# table is pinned to one gh; a machine carrying a different one can say nothing
# about whether the pinned table is right, and failing there would turn every
# unrelated test run on an upgraded box red. Emitting, by contrast, is the
# caller asking for THIS gh's table and is not guarded.
if [ "$mode" = check ] && [ "$gh_version" != "$GH_PIN" ]; then
  printf 'gen-gh-flag-table: 건너뜁니다 — 표는 gh %s 에 고정돼 있고 설치된 것은 %s 입니다\n' \
    "$GH_PIN" "${gh_version:-알 수 없음}"
  exit 0
fi

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/cc-gh-flag-table.XXXXXX") || exit 2
trap 'rm -rf "$SCRATCH"' EXIT
mkdir -p "$SCRATCH/ghconfig"

# `gh_help <path words...>` — the help text of one node, rendered offline.
gh_help() {
  GH_CONFIG_DIR="$SCRATCH/ghconfig" \
  GH_TOKEN='' GITHUB_TOKEN='' GH_ENTERPRISE_TOKEN='' GITHUB_ENTERPRISE_TOKEN='' \
  GH_HOST='invalid.invalid' \
  GH_NO_UPDATE_NOTIFIER=1 GH_PROMPT_DISABLED=1 GH_PAGER='' PAGER='' \
  NO_COLOR=1 CLICOLOR=0 \
    gh "$@" --help 2>&1
}

# The subcommand names of one node. A section header is a bare capitalised line
# ending in `COMMANDS`, and its entries are `  <name>: <description>`.
#
# `HELP TOPICS` IS EXCLUDED because its entries are not commands — `gh
# reference` is not a thing to run, and walking into one costs an error page
# that parses as an empty node. `ALIAS COMMANDS` is excluded for the opposite
# reason: `co` IS runnable, but it is a spelling of `pr checkout` rather than a
# node of its own, and the parser expands it before the table is consulted.
subcommands_of() {
  awk '
    /^[A-Z][A-Z ]*COMMANDS$/ { insec = ($0 != "ALIAS COMMANDS"); next }
    /^[A-Z]/                 { insec = 0 }
    insec == 0               { next }
    /^  [a-z0-9][a-z0-9-]*:/ {
      name = $0
      sub(/^  /, "", name)
      sub(/:.*$/, "", name)
      print name
    }
  '
}

# THE ALIAS SECTION IS READ BACK SEPARATELY so the parser's expansion is checked
# against the binary rather than remembered. `co: Alias for "pr checkout"`.
alias_rows_of() {
  sed -n '/^ALIAS COMMANDS$/,/^$/p' \
    | sed -n 's/^  \([a-z0-9][a-z0-9-]*\): *Alias for "\([^"]*\)".*$/\1 \2/p'
}

# The flags of one node: its own `FLAGS` and its `INHERITED FLAGS`, together.
#
# EACH ROW IS SELF-CONTAINED — it lists everything the node accepts, not only
# what it declares. A reader that had to union a row with its ancestors' would
# have to know which ancestors are real, and the whole point of the table is
# that the path hierarchy does not predict the flag set: `gh pr view` takes
# `-R`, `gh repo delete` does not, and both sit one word under a group.
#
# ARITY COMES FROM THE PLACEHOLDER, which is the only thing the help text says
# about it: `-w, --web` takes none and is a bool; `-q, --jq expression` names
# one and takes a value; a cobra optional-value flag renders `--flag[=default]`.
# A PLACEHOLDER THAT BEGINS WITH `-` IS NOT ONE: cobra lifts the first
# backquoted word of a usage string into the placeholder slot whatever the
# flag's type, so the bool `-f, --force` of `auth setup-git` renders as
# `--force --hostname` because its usage mentions `--hostname`. No value
# placeholder in gh starts with a dash, so such a flag is read as a bool.
# The differential oracle in the test suite does not trust this classification —
# it probes real gh with a value in the flag's own position and fails when the
# binary disagrees.
#
# One awk pass rather than a sed pipeline because the arity decision needs the
# text BETWEEN the flag name and the description, and that is a field problem.
flag_specs() {
  awk '
    /^FLAGS$/            { inflags = 1; next }
    /^INHERITED FLAGS$/  { inflags = 1; next }
    /^[A-Z]/             { inflags = 0 }
    inflags == 0         { next }
    {
      line = $0
      # Only a flag line: optional short form, then the long name.
      if (line !~ /^ +(-[A-Za-z0-9], )?--[a-z0-9][a-z0-9-]*/) next
      sub(/^ +/, "", line)
      short = ""
      if (line ~ /^-[A-Za-z0-9], /) {
        short = substr(line, 2, 1)
        sub(/^-[A-Za-z0-9], /, "", line)
      }
      # The description begins at the first run of two or more spaces.
      spec = line
      if (match(spec, /   */)) spec = substr(spec, 1, RSTART - 1)
      long = spec
      sub(/^--/, "", long)
      rest = ""
      if (match(long, /[ \[=]/)) {
        rest = substr(long, RSTART)
        long = substr(long, 1, RSTART - 1)
      }
      arity = "b"
      if (rest ~ /^\[=/) {
        dflt = rest
        sub(/^\[=/, "", dflt)
        sub(/\].*$/, "", dflt)
        arity = "o=" dflt
      } else if (rest ~ /^ [^-]/) {
        arity = "v"
      }
      print short ":" long ":" arity
    }
  ' | sort -u | tr '\n' ' ' | sed 's/ *$//'
}

# ---------------------------------------------------------------------------
# The walk. Breadth first from the root, one `--help` per node, every node
# emitted — groups included, because a group is a path the parser must be able
# to recognise as incomplete rather than unknown.
# ---------------------------------------------------------------------------
emit_table() {
  printf 'gh-version=%s\n' "$GH_PIN"

  local root_help
  root_help=$(gh_help)
  printf -- '-|%s\n' "$(printf '%s\n' "$root_help" | flag_specs)"

  # THE ALIAS ROWS RIDE IN THE TABLE so the expansion the parser applies is
  # pinned by the same `--check` diff as the flags are. The `!` prefix is not
  # decoration: `alias` is itself a gh command group, so a row keyed `alias co`
  # would sit in the same namespace as `alias set` and a path lookup could not
  # tell the built-in alias from a subcommand. No gh command name may contain
  # `!`, which is what makes the reserved key safe.
  printf '%s\n' "$root_help" | alias_rows_of | while read -r a_name a_target; do
    [ -n "$a_name" ] || continue
    printf '!alias %s|%s\n' "$a_name" "$a_target"
  done

  # `queue` holds one path per line. Tabs never occur in a gh command name, so
  # the path words stay space-joined and the read below splits them back.
  local queue next path help subs w
  queue=$(printf '%s\n' "$root_help" | subcommands_of)
  while [ -n "$queue" ]; do
    next=''
    while IFS= read -r path; do
      [ -n "$path" ] || continue
      # Unquoted on purpose: the path is a space-joined list of command words
      # and `set --` is how it becomes an argument vector again. The words are
      # `[a-z0-9-]+` by the extractor above, so no field can carry a glob.
      # shellcheck disable=SC2086
      set -- $path
      help=$(gh_help "$@")
      printf '%s|%s\n' "$path" "$(printf '%s\n' "$help" | flag_specs)"
      subs=$(printf '%s\n' "$help" | subcommands_of)
      for w in $subs; do
        next="${next}${path} ${w}
"
      done
    done <<QEOF
$queue
QEOF
    queue="$next"
  done
}

case "$mode" in
  emit)
    emit_table
    ;;
  check)
    [ -f "$GATE" ] || {
      printf 'gen-gh-flag-table: gate.sh 를 찾지 못했습니다: %s\n' "$GATE" >&2
      exit 2
    }
    # The embedded table is read by SOURCING the gate and calling the function,
    # which is the same path the parser takes. Reading the file's text instead
    # would compare against the heredoc's source rather than against what a
    # running gate holds, and those two differ exactly when this check matters.
    # The source runs in a subshell because the gate brings run.sh's shell
    # options and traps with it, and this script's own EXIT trap is what removes
    # the scratch directory.
    embedded="$SCRATCH/embedded"
    fresh="$SCRATCH/fresh"
    if ! ( CC_GATE_SOURCE_ONLY=1 . "$GATE" </dev/null && gp_gh_flag_table ) > "$embedded"; then
      printf 'gen-gh-flag-table: gate.sh 의 내장 표를 읽지 못했습니다\n' >&2
      exit 2
    fi
    emit_table > "$fresh"
    if diff -u "$embedded" "$fresh" > "$SCRATCH/diff"; then
      printf 'OK:   gen-gh-flag-table — gh %s, 내장 표와 재생성 결과가 같습니다 (%d행)\n' \
        "$GH_PIN" "$(wc -l < "$embedded" | tr -d ' ')"
      exit 0
    fi
    printf 'FAIL: gen-gh-flag-table — 내장 표가 gh %s 의 재생성 결과와 다릅니다\n' "$GH_PIN" >&2
    cat "$SCRATCH/diff" >&2
    exit 1
    ;;
esac
