#!/usr/bin/env bash
#
# plugin-isolation.sh — the user-plugin keys an unattended session must turn
# off or on, as pure functions.
#
# A session launched with `--settings` still loads every plugin the account's
# own `settings.json` enables, so the run's settings file has to name each of
# them in `enabledPlugins`. The gate renders that object for every settings
# variant; the kickoff helper lists the same keys as candidates and, in its main
# and carry modes, judges each plugin default and each carried row by them; the
# re-kickoff helper judges the rows it carries by them. So the derivation lives
# here and all of them source it.
#
# SOURCE ONLY. Sourcing defines functions and assigns one constant, `PI_KEY_RE`;
# no file is read until a function is called.
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
# The kickoff side's judgment. These read the account directories a kickoff
# proposes and judges from — NOT the run side's set the gate turns plugins off
# in, which comes from the directory the run opened in and the run's own
# inventory. They decide only whether a row is made or carried.
#
#   pi_kickoff_account_dirs
#       → `${CLAUDE_CONFIG_DIR:-$HOME/.claude}`, then every line the lane
#         inventory `${XDG_CONFIG_HOME:-$HOME/.config}/cc-lane/accounts.json`
#         yields for `.accounts[]? | .config_dir // empty` when that file is a
#         regular file and not a symlink. The lines are printed as jq gives
#         them, an empty one included.
#   pi_kickoff_read_fail
#       → the one path that keeps the account set from being read in full, or
#         nothing. See THE READ FAILURES below.
#   pi_kickoff_user_keys
#       → `pi_user_keys` over `pi_kickoff_account_dirs`, its warnings dropped:
#         `pi_kickoff_read_fail` is what reports a broken file here.
#   pi_judge <seed keys> <user keys> <fail path> <key>
#       → `시드`, `켬`, `미설치`, or `판정 불가<TAB><fail path>`. <seed keys> and
#         <user keys> are newline-separated lists, <fail path> is the output of
#         `pi_kickoff_read_fail`. A seed key is `시드` whatever was read; a key
#         that was read is `켬`; any other key is `판정 불가` when a read failed
#         and `미설치` when nothing did.
#   pi_key_state <seed file> <key>
#       → `pi_judge` with every input read now. A caller judging several keys
#         reads the three inputs once and calls `pi_judge` instead.
#
# THE READ FAILURES. A key that was not read is `미설치` only when the whole
# account set was read without one of these; the path printed is the first one
# found, in this order:
#   - the inventory is a symlink, whether or not it points anywhere;
#   - the inventory is present and does not parse as JSON (a directory there
#     does not);
#   - its `.accounts` is not an array (absent included), or an element of it
#     has no non-empty string `config_dir` (an empty array is fine);
#   - an account directory is not a directory (an empty line included) — the
#     path is that directory;
#   - its `plugins/installed_plugins.json` or `settings.json` is present and does
#     not parse as JSON — the path is that file;
#   - its `installed_plugins.json` is present and empty, or its top level or its
#     `.plugins` is not an object (`.plugins` absent or `null` included); its
#     `settings.json` is present and its top level is not an object, or it has
#     an `.enabledPlugins` key whose value is not an object (`null` included) —
#     the path is that file;
#   - every directory read gave zero keys — the path is the first directory.
# A directory holding neither file reads as zero keys, not as a failure. The
# shapes are checked here and not inferred from `pi_json_keys`, whose quiet
# zero-key reads the gate relies on and which this does not change.
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

pi_kickoff_inventory() {
  printf '%s' "${XDG_CONFIG_HOME:-$HOME/.config}/cc-lane/accounts.json"
}

pi_kickoff_account_dirs() {
  local inv
  inv=$(pi_kickoff_inventory)
  printf '%s\n' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  if [ -f "$inv" ] && [ ! -L "$inv" ]; then
    jq -r '.accounts[]? | .config_dir // empty' "$inv" 2>/dev/null || true
  fi
}

pi_json_shape() {
  # pi_json_shape <file> <jq test over the slurped file> — 0 when the file
  # parses as JSON and the test is true, 1 when it does not parse, 2 when it
  # parses and the test is not true.
  jq empty "$1" >/dev/null 2>&1 || return 1
  jq -s -e "$2" "$1" >/dev/null 2>&1 || return 2
  return 0
}

pi_kickoff_read_fail() {
  local inv dirs d f
  inv=$(pi_kickoff_inventory)
  if [ -L "$inv" ]; then printf '%s\n' "$inv"; return 0; fi
  if [ -e "$inv" ]; then
    pi_json_shape "$inv" 'length == 1 and (.[0] | type == "object")
      and (.[0].accounts | type == "array")
      and all(.[0].accounts[]; type == "object" and (.config_dir | type == "string") and .config_dir != "")' \
      || { printf '%s\n' "$inv"; return 0; }
  fi
  dirs=$(pi_kickoff_account_dirs)
  while IFS= read -r d; do
    # Only the inventory yields an empty line, and its shape check above
    # already named it; the inventory is still the path to report.
    if [ -z "$d" ]; then printf '%s\n' "$inv"; return 0; fi
    if [ ! -d "$d" ]; then printf '%s\n' "$d"; return 0; fi
    f="$d/plugins/installed_plugins.json"
    if [ -e "$f" ]; then
      pi_json_shape "$f" 'length == 1 and (.[0] | type == "object")
        and (.[0] | has("plugins")) and (.[0].plugins | type == "object")' \
        || { printf '%s\n' "$f"; return 0; }
    fi
    f="$d/settings.json"
    if [ -e "$f" ]; then
      pi_json_shape "$f" 'length == 1 and (.[0] | type == "object")
        and ((.[0] | has("enabledPlugins") | not) or (.[0].enabledPlugins | type == "object"))' \
        || { printf '%s\n' "$f"; return 0; }
    fi
  done <<EOF
$dirs
EOF
  if [ -z "$(pi_kickoff_user_keys)" ]; then
    printf '%s\n' "$dirs" | head -n 1
  fi
}

pi_kickoff_user_keys() {
  local dirs d
  dirs=$(pi_kickoff_account_dirs)
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    pi_user_keys "$d" 2>/dev/null
  done <<EOF | pi_filter_keys
$dirs
EOF
}

pi_judge() {
  local seed="$1" user="$2" fail="$3" key="$4"
  if printf '%s\n' "$seed" | grep -qxF -- "$key"; then printf '시드\n'
  elif printf '%s\n' "$user" | grep -qxF -- "$key"; then printf '켬\n'
  elif [ -n "$fail" ]; then printf '판정 불가\t%s\n' "$fail"
  else printf '미설치\n'
  fi
}

pi_key_state() {
  pi_judge "$(pi_seed_keys "$1")" "$(pi_kickoff_user_keys)" "$(pi_kickoff_read_fail)" "$2"
}
