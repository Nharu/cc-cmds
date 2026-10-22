#!/usr/bin/env bash
#
# plugin-isolation.sh — the user-plugin keys an unattended session must turn
# off or on, as pure functions.
#
# A session launched with `--settings` still loads every plugin the account's
# own `settings.json` enables, so the run's settings file has to name each of
# them in `enabledPlugins`. The gate renders that object for every settings
# variant and the kickoff helper lists the same keys as candidates, so the
# derivation lives here and both of them source it.
#
# SOURCE ONLY. Sourcing defines functions and nothing else: no file is read and
# no variable is set until a function is called.
#
# Functions
#
#   pi_user_keys <account dir>...
#       → the keys of `plugins/installed_plugins.json` `.plugins` and of
#         `settings.json` `.enabledPlugins` in every directory, one per line,
#         sorted and unique. A missing file adds nothing; a file that does not
#         parse as JSON adds nothing and leaves one warning line on stderr.
#   pi_seed_keys <seed file>
#       → the keys of the seed file, one per line, sorted and unique; nothing
#         when the file is absent.
#   pi_allow_keys <seed file> [<key>...]
#       → the seed keys plus the given keys, sorted and unique.
#   pi_render_enabled <shift 0|1> <user keys> <allow keys>
#       → the JSON object for `enabledPlugins`, keys sorted. With shift 1 every
#         user and allow key is false; otherwise an allow key is true and a user
#         key that is not an allow key is false. <user keys> and <allow keys>
#         are newline-separated lists.
#   pi_seed_hash <seed file>
#       → the sha256 of the seed file's bytes, or `-` when it is absent.
#
# A KEY IS `<name>@<marketplace>` AND NOTHING ELSE. Every list passes through
# `pi_filter_keys`, which drops any other shape and every key ending in
# `@inline` (the `--plugin-dir` copy of cc-cmds) or `@builtin` (the harness's
# own plugins): turning those off would disable the pipeline itself or reach
# outside what this file is for. The shape also keeps every key a plain JSON
# string, so the renderer needs no escaping.
#
# Compatibility: bash 3.2 — no associative arrays, no mapfile.

PI_KEY_RE='^[A-Za-z0-9_.-]+@[A-Za-z0-9_.-]+$'

pi_filter_keys() {
  # stdin → the well-shaped keys, sorted and unique.
  { LC_ALL=C grep -E "$PI_KEY_RE" || true; } \
    | { LC_ALL=C grep -vE '@(inline|builtin)$' || true; } \
    | LC_ALL=C sort -u
}

pi_json_keys() {
  # pi_json_keys <file> <jq path> — the keys of the object at <jq path>.
  # A READ FAILURE DOES NOT STOP THE CALLER. A key that leaks because a user
  # file is broken costs tokens and widens no authority, so the render goes on
  # and the warning is the record.
  local f="$1" p="$2" out rc
  [ -f "$f" ] || return 0
  rc=0
  out=$(jq -r "($p // {}) | if type == \"object\" then keys[] else empty end" "$f" 2>/dev/null) || rc=$?
  if [ "$rc" != "0" ]; then
    printf 'plugin-isolation: JSON 으로 읽히지 않아 건너뜁니다: %s\n' "$f" >&2
    return 0
  fi
  [ -z "$out" ] || printf '%s\n' "$out"
}

pi_user_keys() {
  local d
  for d in "$@"; do
    [ -n "$d" ] || continue
    pi_json_keys "$d/plugins/installed_plugins.json" '.plugins'
    pi_json_keys "$d/settings.json" '.enabledPlugins'
  done | pi_filter_keys
}

pi_seed_keys() {
  [ -f "$1" ] || return 0
  sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$1" \
    | { grep -v '^#' || true; } \
    | pi_filter_keys
}

pi_allow_keys() {
  local seed="$1"
  shift
  {
    pi_seed_keys "$seed"
    [ "$#" = 0 ] || printf '%s\n' "$@"
  } | pi_filter_keys
}

pi_render_enabled() {
  # Allow keys are listed first, so a key in both lists keeps the allow value.
  # SORTED BY KEY, because the rendered bytes are in the enforcement-surface
  # digest: the same inputs must always give the same file.
  local shift_kind="$1" user="$2" allow="$3"
  {
    printf '%s\n' "$allow" | pi_filter_keys | awk '{ print $0 "\ttrue" }'
    printf '%s\n' "$user" | pi_filter_keys | awk '{ print $0 "\tfalse" }'
  } | awk -F'\t' -v sh="$shift_kind" '
      !($1 in seen) { seen[$1] = 1; v = $2; if (sh == "1") v = "false"; print $1 "\t" v }' \
    | LC_ALL=C sort \
    | awk -F'\t' '
      { n++; row[n] = "    \"" $1 "\": " $2 }
      END {
        if (n == 0) { printf "{}"; exit }
        printf "{\n"
        for (i = 1; i <= n; i++) printf "%s%s\n", row[i], (i < n ? "," : "")
        printf "  }"
      }'
}

pi_seed_hash() {
  if [ -f "$1" ]; then
    shasum -a 256 "$1" | cut -d' ' -f1
  else
    printf -- '-\n'
  fi
}
