#!/usr/bin/env bash
# Proven-input reuse of test passes for the job pool of scripts/test-tree.sh
# (its goals and its test-gate lanes) and the serial check-cheap of
# scripts/check-push.sh.
#
# A PASS IS REUSED ONLY WHEN ITS INPUTS ARE PROVEN THE SAME. An item (a make
# goal or check-cheap) that ran in a checkout of its own, on a volume where a
# read moves the access time, leaves a record of the tracked files it read: every
# tracked file and the four files .git/index, .git/HEAD, .git/config and
# .git/objects/info/alternates get an access time of 2000-01-01 before it
# starts, and after it ends a file whose access time moved, whose modification
# time changed or that is gone was read. A tracked symbolic link always counts
# as read. When one of the four .git files moved, or a watch shim saw a git
# call or a cloning cp aimed at the checkout, the item read the whole tree; a
# git call whose calling directory alone is inside the checkout is not such a
# call. A later tree reuses the pass when the record's doubles and tool
# fingerprint are today's, the record is under 24 hours old, the tracked paths
# match by (path, mode, empty or not), and every path it read has the same
# blob; a whole-tree record also needs the same tree object, the same input
# commit and the same base.
#
# A RELEASE COMMIT DOES NOT VOID A PASS. A record that fails the conditions
# above is still reused when every path whose blob differs between its listing
# and today's is CHANGELOG.md or plugins/cc-cmds/.claude-plugin/plugin.json,
# there is at least one, and the record and today's run stand in the release
# relation: the same base; the record's input commit an ancestor of today's;
# the diff between those two commits naming only those two paths, at least
# one, with unchanged modes; plugin.json, when it differs, the same number of
# lines with exactly one line changed and that line the version line on both
# sides (the shape gate.sh's gate_meta_version_of reads); CHANGELOG.md, when it
# differs, the old bytes up to the old first `## [` line, then a non-empty
# inserted block that starts with `## [` and ends in a newline, then the old
# bytes from that line on. The relation is read from the two input commits in
# the repository's own objects (the common git directory the records live
# under), never from the tested trees, whose merged commits live only in a
# thrown-away clone. A missing object, a failing git call or a byte the check
# cannot place makes the item run again. git is called only for a record whose
# differing paths are all release paths; the reuse line says `릴리스 차이`.
#
# Sourced by scripts/test-tree.sh. Run, it has only its self-test:
#   bash scripts/test-reuse.sh --self-test
#
# Variables:
#   TR_EXCLUDE   item keys (`make:<goal>`, `make:check-cheap`) separated by
#                spaces that are never recorded or reused; empty by default
#
# The store: <common git directory>/cc-cmds-check-push-items/<item key with
# `/` spelled `%2F`>/<tested tree>, one record per tree, written under a
# temporary name and moved into place. Writing a record removes every record of
# the store last modified over 24 hours ago, and the key directories it empties.
#
# A TEST-GATE LANE KEEPS A RECORD OF ITS OWN SHAPE, version 2, under `lane/` of
# the same store, named `<sha256 of the key>.<tested tree>`: the key holds the
# lane's section ids, which can be longer than a file name may be. Beside the
# fields of a goal record it carries `절`, the ids sorted and comma-joined, and
# `컷증명`, the digest of the cut those ids make (`test-gate.sh --cut-digest`):
# the lane ran a copy of test-gate.sh kept outside its checkout, so the bytes of
# the suite it ran are proven by the digest, not by the read set. A lane record
# is reused only for the same sections and the same digest, on top of every
# condition a goal record meets; the goal judge refuses a lane record.

TR_EXCLUDE=""
# Records older than this many seconds are not reused.
TR_MAX_AGE=86400
# An access time above this epoch (2000-01-02 UTC) moved since the baseline,
# whatever the time zone `touch -t 200001010000` was read in.
TR_BASE_MAX=946771200
TR_OS=""
TR_FP=""
# A file holding the epoch the self-tests read instead of the clock; empty in
# every real run.
TR_CLOCK=""

tr_now() {
  if [ -n "$TR_CLOCK" ]; then cat "$TR_CLOCK"; else date +%s; fi
}

tr_os_init() {
  [ -z "$TR_OS" ] || return 0
  case "$(uname -s)" in Darwin) TR_OS=bsd ;; *) TR_OS=gnu ;; esac
}

# The one-cell name of item key $1: `/` spelled `%2F`, the rule of the weight
# files of scripts/test-slots.sh.
tr_key_name() {
  printf '%s' "${1//\//%2F}"
}

# 0 when item key $1 is on TR_EXCLUDE.
tr_excluded() {
  case " $TR_EXCLUDE " in *" $1 "*) return 0 ;; esac
  return 1
}

tr_store() {
  printf '%s/cc-cmds-check-push-items' "$1"
}

# The sha256 of standard input, in hex.
tr_sha256() {
  local s
  if command -v sha256sum > /dev/null 2>&1; then s=$(sha256sum) || return 1; else s=$(shasum -a 256) || return 1; fi
  printf '%s' "${s%% *}"
}

# Section ids $1 (comma-separated, any order) sorted and comma-joined.
tr_lane_ids() {
  printf '%s\n' "$1" | tr ',' '\n' | awk 'NF' | LC_ALL=C sort -u | awk '{ printf "%s%s", (NR > 1 ? "," : ""), $0 }'
}

# The record path of the lane over ids $2 on tree $3 in common git directory $1.
tr_lane_path() {
  local key
  key="lane:$(tr_lane_ids "$2")"
  printf '%s/lane/%s.%s' "$(tr_store "$1")" "$(printf '%s' "$key" | tr_sha256)" "$3"
}

# "<atime> <mtime> <path>" for each path given: the access time in whole epoch
# seconds, the modification time with its fraction, so a write in the second of
# the baseline still shows.
tr_stat_am() {
  tr_os_init
  if [ "$TR_OS" = bsd ]; then
    stat -f '%a %Fm %N' "$@"   # lint-bash-portability: disable=stat -f
  else
    stat -c '%X %.9Y %n' "$@"   # lint-bash-portability: disable=stat -c
  fi
}

# The same for the NUL-separated paths on standard input; a path that is gone
# prints nothing.
tr_stat_am_list() {
  tr_os_init
  if [ "$TR_OS" = bsd ]; then
    xargs -0 stat -f '%a %Fm %N' 2>/dev/null   # lint-bash-portability: disable=stat -f
  else
    xargs -0 stat -c '%X %.9Y %n' 2>/dev/null   # lint-bash-portability: disable=stat -c
  fi
  return 0
}

# The access time of path $1 in epoch seconds.
tr_atime() {
  local l
  l=$(tr_stat_am "$1" 2>/dev/null) || return 1
  printf '%s' "${l%% *}"
}

# Sets the access time of the NUL-separated paths on standard input to the
# baseline.
tr_reset_list() {
  xargs -0 touch -a -h -t 200001010000
}

# Writes the tracked listing of commit $2 in repository $1 to $3, one
# `git ls-tree -r -l` line per entry with the path unquoted. 1 when the listing
# fails or a path holds a newline.
tr_list() {
  local work="$1" c="$2" out="$3" n
  ( unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR
    cd "$work" && git ls-tree -r -l -z "$c" ) > "$out.z" 2>/dev/null || { rm -f "$out.z"; return 1; }
  n=$(LC_ALL=C tr -d -c '\n' < "$out.z" | wc -c)
  if [ "$n" -ne 0 ]; then rm -f "$out.z"; return 1; fi
  LC_ALL=C tr '\0' '\n' < "$out.z" > "$out" || { rm -f "$out.z"; return 1; }
  rm -f "$out.z"
  return 0
}

# Sets TR_FP to the tool fingerprint: the version lines of bash, git, make, yq
# and jq, `uname -sr` and the PATH, hashed. Called before the watch shims go on
# the front of any PATH.
tr_fp_init() {
  local s
  [ -z "$TR_FP" ] || return 0
  s=$( {
    bash --version 2>/dev/null | awk 'NR == 1'
    git --version 2>/dev/null
    make --version 2>/dev/null | awk 'NR == 1'
    yq --version 2>/dev/null || echo 'yq 없음'
    jq --version 2>/dev/null || echo 'jq 없음'
    uname -sr
    printf 'PATH %s\n' "$PATH"
  } 2>/dev/null )
  TR_FP=$(printf '%s\n' "$s" | git hash-object --stdin 2>/dev/null)
  [ -n "$TR_FP" ]
}

# --- one item's run ------------------------------------------------------------------
#
# $1 is the item checkout, $2 the prefix of its side files outside the checkout
# (<prefix>.paths, .links, .base, .after, .mark, .canary, .shim/), $3 the
# tracked listing of its tree.

# The baseline: the access times of the tracked regular files and the four .git
# files go back to 2000-01-01, and the modification times are kept. 1 when a
# step fails.
tr_baseline() {
  local ck="$1" side="$2" list="$3" f
  rm -f "$side.links"
  awk 'BEGIN { FS = "\t" } {
    t = index($0, "\t"); split(substr($0, 1, t - 1), h, " "); p = substr($0, t + 1)
    if (h[1] == "120000") print p > links
    else if (h[2] == "blob") print "./" p
  }' links="$side.links" "$list" | LC_ALL=C tr '\n' '\0' > "$side.paths" || return 1
  [ -f "$side.links" ] || : > "$side.links"
  if [ -s "$side.paths" ]; then
    ( cd "$ck" && tr_reset_list < "$side.paths" ) || return 1
  fi
  for f in index HEAD config objects/info/alternates; do
    if [ -e "$ck/.git/$f" ]; then touch -a -h -t 200001010000 "$ck/.git/$f" || return 1; fi
  done
  if [ -s "$side.paths" ]; then
    ( cd "$ck" && tr_stat_am_list < "$side.paths" ) > "$side.base" || return 1
  else
    : > "$side.base"
  fi
  rm -f "$side.mark"
  return 0
}

# 0 when a read of a file beside the checkout moves its access time; the file
# goes back to the baseline after.
tr_canary() {
  local side="$1" c a
  c="$side.canary"
  printf 'canary\n' > "$c" || return 1
  touch -a -t 200001010000 "$c" || return 1
  cat "$c" > /dev/null
  a=$(tr_atime "$c") || return 1
  touch -a -t 200001010000 "$c"
  case "$a" in ''|*[!0-9]*) return 1 ;; esac
  [ "$a" -gt "$TR_BASE_MAX" ]
}

# The path helpers both watch shims carry.
tr_shim_common() {
  cat <<'EOF'
tr_in() { case "$1" in "$ck"|"$ck"/*) return 0 ;; esac; return 1; }
# Sets R to the physical path of $1 read against directory $2 when it exists;
# with $3 set, a path that does not exist resolves through its parent.
tr_phys() {
  local x="$1"
  R=""
  case "$x" in /*) ;; *) x="$2/$x" ;; esac
  if [ -d "$x" ]; then
    R=$(cd "$x" 2>/dev/null && pwd -P)
  elif [ -e "$x" ] || [ -L "$x" ] || [ -n "${3:-}" ]; then
    R=$(cd "${x%/*}/" 2>/dev/null && pwd -P) || R=""
    [ -z "$R" ] || R="${R%/}/${x##*/}"
  fi
}
EOF
}

# Writes the git and cp watch shims into <prefix>.shim/. Each passes the call on
# to the command PATH finds now and leaves a line in <prefix>.mark when the
# call can reach the checkout.
#
# The git shim marks a call when, resolved to a physical path, one of these is
# inside the checkout (its .git included): the directory the -C arguments reach
# when applied in order on top of the calling directory, a --git-dir or
# --work-tree argument, the value of GIT_DIR, GIT_WORK_TREE, GIT_INDEX_FILE,
# GIT_OBJECT_DIRECTORY or GIT_ALTERNATE_OBJECT_DIRECTORIES, or any other
# argument that resolves to an existing path. The calling directory itself only
# anchors relative paths and -C: a git that finds its repository from there
# reads that repository's HEAD and config, which the access times of the four
# .git files show, and a call that names a repository outside reads nothing of
# the checkout.
#
# The cp shim marks a call that carries a clone option (-c alone or inside a
# group of short options, --reflink, --reflink=<anything but never>) when one
# of its operands, read against the calling directory, is inside the checkout.
tr_shims() {
  local ck="$1" side="$2" d real_git real_cp
  ck=$(cd "$ck" && pwd -P) || return 1
  d="$side.shim"
  mkdir -p "$d" || return 1
  real_git=$(command -v git) || return 1
  real_cp=$(command -v cp) || return 1
  {
    printf '#!/usr/bin/env bash\n'
    printf '# git watch shim of one test item.\n'
    printf 'ck=%q\nmk=%q\nreal=%q\n' "$ck" "$side.mark" "$real_git"
    tr_shim_common
    cat <<'EOF'
hit=""
cwd=$(pwd -P)
for v in "${GIT_DIR:-}" "${GIT_WORK_TREE:-}" "${GIT_INDEX_FILE:-}" "${GIT_OBJECT_DIRECTORY:-}"; do
  [ -n "$v" ] || continue
  tr_phys "$v" "$cwd"
  if [ -n "$R" ] && tr_in "$R"; then hit=env; fi
done
if [ -n "${GIT_ALTERNATE_OBJECT_DIRECTORIES:-}" ]; then
  oifs=$IFS
  IFS=:
  for v in $GIT_ALTERNATE_OBJECT_DIRECTORIES; do
    [ -n "$v" ] || continue
    tr_phys "$v" "$cwd"
    if [ -n "$R" ] && tr_in "$R"; then hit=env; fi
  done
  IFS=$oifs
fi
base="$cwd"
want=""
for a in "$@"; do
  if [ -n "$want" ]; then
    tr_phys "$a" "$base"
    if [ "$want" = C ] && [ -n "$R" ] && [ -d "$R" ]; then base="$R"; fi
    if [ -n "$R" ] && tr_in "$R"; then hit=arg; fi
    want=""
    continue
  fi
  case "$a" in
    -C) want=C ;;
    --git-dir|--work-tree) want=d ;;
    --git-dir=*|--work-tree=*)
      tr_phys "${a#*=}" "$base"
      if [ -n "$R" ] && tr_in "$R"; then hit=arg; fi ;;
    *)
      tr_phys "$a" "$base"
      if [ -n "$R" ] && tr_in "$R"; then hit=arg; fi ;;
  esac
done
[ -z "$hit" ] || printf 'git %s %s\n' "$hit" "$cwd" >> "$mk"
exec "$real" "$@"
EOF
  } > "$d/git" || return 1
  {
    printf '#!/usr/bin/env bash\n'
    printf '# cp watch shim of one test item.\n'
    printf 'ck=%q\nmk=%q\nreal=%q\n' "$ck" "$side.mark" "$real_cp"
    tr_shim_common
    cat <<'EOF'
clone=""
hit=""
end=""
cwd=$(pwd -P)
for a in "$@"; do
  if [ -z "$end" ]; then
    case "$a" in
      --) end=1; continue ;;
      --reflink=never) continue ;;
      --reflink|--reflink=*) clone=1; continue ;;
      --*) continue ;;
      -?*) case "${a#-}" in *c*) clone=1 ;; esac; continue ;;
    esac
  fi
  tr_phys "$a" "$cwd" parent
  if [ -n "$R" ] && tr_in "$R"; then hit=1; fi
done
[ -z "$clone" ] || [ -z "$hit" ] || printf 'cp %s\n' "$cwd" >> "$mk"
exec "$real" "$@"
EOF
  } > "$d/cp" || return 1
  chmod +x "$d/git" "$d/cp"
}

# Writes the read set of the item to $4: the first line `예` when it read the
# whole tree and `아니오` otherwise, then the tracked paths it read. The .git
# files are read first, so the listing reads nothing of the checkout.
tr_collect() {
  local ck="$1" side="$2" out="$4" whole=아니오 f a
  for f in index HEAD config objects/info/alternates; do
    [ -e "$ck/.git/$f" ] || continue
    a=$(tr_atime "$ck/.git/$f") || return 1
    case "$a" in ''|*[!0-9]*) return 1 ;; esac
    if [ "$a" -gt "$TR_BASE_MAX" ]; then whole=예; fi
  done
  if [ -s "$side.mark" ]; then whole=예; fi
  if [ -s "$side.paths" ]; then
    ( cd "$ck" && tr_stat_am_list < "$side.paths" ) > "$side.after"
  else
    : > "$side.after"
  fi
  {
    printf '%s\n' "$whole"
    awk -v max="$TR_BASE_MAX" '
      function rest(s) { sub(/^[^ ]+ [^ ]+ /, "", s); sub(/^\.\//, "", s); return s }
      FILENAME == base { m[rest($0)] = $2; next }
      FILENAME == after { p = rest($0); seen[p] = 1
        if ($1 + 0 > max || $2 != m[p]) print p; next }
      FILENAME == links { if ($0 != "") print $0; next }
      END { for (p in m) if (!(p in seen)) print p }
    ' base="$side.base" after="$side.after" links="$side.links" \
      "$side.base" "$side.after" "$side.links" | LC_ALL=C sort -u
  } > "$4"
}

# --- records ---------------------------------------------------------------------------

# Removes the records of store $1 last modified over 24 hours ago, then the key
# directories left empty.
tr_sweep() {
  [ -d "$1" ] || return 0
  find "$1" -mindepth 2 -maxdepth 2 -type f -mmin +1440 -exec rm -f {} + 2>/dev/null
  find "$1" -mindepth 1 -maxdepth 1 -type d -empty -exec rmdir {} + 2>/dev/null
  return 0
}

# Writes the record of item $2 that passed on tree $3: $1 the common git
# directory, $4 the input commit, $5 the base (empty: none), $6 the doubles, $7
# the tracked listing of the tree, $8 the read set of tr_collect.
tr_record_write() {
  local gdir="$1" key="$2" tree="$3" commit="$4" base="${5:-없음}" doubles="$6" list="$7" rs="$8"
  local store d
  tr_excluded "$key" && return 0
  [ -n "$TR_FP" ] || tr_fp_init || return 1
  store=$(tr_store "$gdir")
  d="$store/$(tr_key_name "$key")"
  mkdir -p "$d" || return 1
  tr_record_put "$store" "$d/$tree" 1 "$key" "" "$tree" "$commit" "$base" "$doubles" "$list" "$rs"
}

# Writes the record of the lane over section ids $2 that passed on tree $3,
# with cut digest $9; the other arguments are tr_record_write's.
tr_lane_write() {
  local gdir="$1" ids tree="$3" commit="$4" base="${5:-없음}" doubles="$6" list="$7" rs="$8" dig="${9:-}"
  local store path key
  ids=$(tr_lane_ids "$2")
  key="lane:$ids"
  [ -n "$ids" ] || return 1
  case "$dig" in *[!0-9a-f]*|'') return 1 ;; esac
  tr_excluded "$key" && return 0
  [ -n "$TR_FP" ] || tr_fp_init || return 1
  store=$(tr_store "$gdir")
  path=$(tr_lane_path "$gdir" "$ids" "$tree") || return 1
  mkdir -p "$store/lane" || return 1
  tr_record_put "$store" "$path" 2 "$key" "$(printf '절\t%s\n컷증명\t%s' "$ids" "$dig")" \
    "$tree" "$commit" "$base" "$doubles" "$list" "$rs"
}

# The one record writer: into path $2 of store $1, version $3, key $4, the
# version's own header lines $5 (empty: none), then tree, commit, base,
# doubles, listing and read set. Written beside the path and moved over it;
# then the store is swept.
tr_record_put() {
  local store="$1" path="$2" ver="$3" key="$4" extra="$5" tree="$6" commit="$7" base="$8" doubles="$9" list="${10}" rs="${11}"
  local tmp whole nr nl at stamp
  tmp=$(mktemp "${path%/*}/.r.XXXXXX" 2>/dev/null) || return 1
  IFS= read -r whole < "$rs"
  case "$whole" in 예|아니오) ;; *) rm -f "$tmp"; return 1 ;; esac
  nr=$(($(wc -l < "$rs") - 1))
  nl=$(wc -l < "$list")
  at=$(tr_now)
  stamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  if {
    printf 'cc-check-push-items %s\n' "$ver"
    printf '항목\t%s\n' "$key"
    [ -z "$extra" ] || printf '%s\n' "$extra"
    printf '시험트리\t%s\n커밋\t%s\n베이스\t%s\n' "$tree" "$commit" "$base"
    printf '시각\t%s\n시각표기\t%s\n대역\t%s\n도구\t%s\n' "$at" "$stamp" "$doubles" "$TR_FP"
    printf '트리전체\t%s\n읽은경로\t%s\n' "$whole" "$((nr))"
    sed -n '2,$p' "$rs"
    printf '목록\t%s\n' "$((nl))"
    cat "$list"
    printf '끝\n'
  } > "$tmp" && mv -f "$tmp" "$path"; then
    tr_sweep "$store"
    return 0
  fi
  rm -f "$tmp"
  return 1
}

# The two paths a release commit changes.
TR_REL_LOG="CHANGELOG.md"
TR_REL_PJ="plugins/cc-cmds/.claude-plugin/plugin.json"

# 0 when commits $2 (the record's input commit) and $3 (today's) in the
# repository whose common git directory is $1 stand in relations 2 to 5 of the
# release relation (the head comment; relation 1, the same base, is the
# judge's). 1 otherwise, a missing object or a failing git call included;
# nothing is printed.
tr_release_rel() {
  local gdir="$1" old="$2" new="$3" tmp rc
  [ -n "$gdir" ] && [ -d "$gdir" ] || return 1
  case "$old" in ''|*[!0-9a-f]*) return 1 ;; esac
  case "$new" in ''|*[!0-9a-f]*) return 1 ;; esac
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/tr-release.XXXXXX") || return 1
  ( unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR
    tr_release_rel_in "$gdir" "$old" "$new" "$tmp" ) < /dev/null > /dev/null 2>&1
  rc=$?
  rm -rf "$tmp"
  return "$rc"
}

# The body of tr_release_rel, run in a subshell with scratch directory $4.
tr_release_rel_in() {
  local gdir="$1" old="$2" new="$3" tmp="$4" p m1 m2 k psz osz nsz msz rsz
  local seen_log="" seen_pj=""
  trg() { git --git-dir="$gdir" "$@"; }
  trg cat-file -e "$old^{commit}" && trg cat-file -e "$new^{commit}" || return 1
  trg merge-base --is-ancestor "$old" "$new" || return 1
  trg diff --no-renames --no-ext-diff --name-only -z "$old" "$new" -- > "$tmp/names" || return 1
  [ -s "$tmp/names" ] || return 1
  while IFS= read -r -d '' p; do
    case "$p" in
      "$TR_REL_LOG") seen_log=1 ;;
      "$TR_REL_PJ") seen_pj=1 ;;
      *) return 1 ;;
    esac
    m1=$(trg ls-tree "$old" -- "$p") && m2=$(trg ls-tree "$new" -- "$p") || return 1
    [ -n "$m1" ] && [ "${m1%% *}" = "${m2%% *}" ] || return 1
  done < "$tmp/names"
  [ -n "$seen_log$seen_pj" ] || return 1
  if [ -n "$seen_pj" ]; then
    trg cat-file blob "$new:$TR_REL_PJ" > "$tmp/pn" && trg cat-file blob "$old:$TR_REL_PJ" > "$tmp/po" || return 1
    # The one changed line, when both sides have as many lines and it is the
    # version line on both; the old side rewritten with it must be the new side
    # byte for byte, and the old side rewritten as it is must be itself.
    k=$(awk '
      function ver(s) { return s ~ /^[ \t]*"version"[ \t]*:[ \t]*"[0-9]+\.[0-9]+\.[0-9]+"[ \t]*,?[ \t]*$/ }
      FNR == NR { o[FNR] = $0; no = FNR; next }
      { nn = FNR; if (FNR > no || o[FNR] != $0) { d++; at = FNR; if (!ver(o[FNR]) || !ver($0)) bad = 1 } }
      END { if (nn == no && d == 1 && !bad) print at }
    ' "$tmp/po" "$tmp/pn") || return 1
    [ -n "$k" ] || return 1
    awk -v k="$k" 'FNR == NR { if (FNR == k) l = $0; next } { print (FNR == k ? l : $0) }' "$tmp/pn" "$tmp/po" > "$tmp/pr" || return 1
    awk '{ print }' "$tmp/po" > "$tmp/ps" || return 1
    cmp -s "$tmp/pr" "$tmp/pn" && cmp -s "$tmp/ps" "$tmp/po" || return 1
  fi
  if [ -n "$seen_log" ]; then
    trg cat-file blob "$new:$TR_REL_LOG" > "$tmp/cn" && trg cat-file blob "$old:$TR_REL_LOG" > "$tmp/co" || return 1
    k=$(awk '/^## \[/ { print NR; exit }' "$tmp/co")
    [ -n "$k" ] || return 1
    # Every line before line k ends in a newline, so awk prints them back as
    # they are.
    psz=$(( $(awk -v k="$k" 'NR < k' "$tmp/co" | wc -c) ))
    osz=$(( $(wc -c < "$tmp/co") ))
    nsz=$(( $(wc -c < "$tmp/cn") ))
    rsz=$((osz - psz))
    msz=$((nsz - osz))
    [ "$msz" -gt 0 ] && [ "$rsz" -gt 0 ] || return 1
    if [ "$psz" -gt 0 ]; then
      head -c "$psz" "$tmp/co" > "$tmp/c1" && head -c "$psz" "$tmp/cn" > "$tmp/c2" || return 1
      cmp -s "$tmp/c1" "$tmp/c2" || return 1
    fi
    tail -c "$rsz" "$tmp/co" > "$tmp/c1" && tail -c "$rsz" "$tmp/cn" > "$tmp/c2" || return 1
    cmp -s "$tmp/c1" "$tmp/c2" || return 1
    tail -c "+$((psz + 1))" "$tmp/cn" > "$tmp/c3" && head -c "$msz" "$tmp/c3" > "$tmp/cm" || return 1
    [ "$(( $(wc -c < "$tmp/cm") ))" = "$msz" ] || return 1
    awk 'NR == 1 { ok = /^## \[/ } END { exit !ok }' "$tmp/cm" || return 1
    [ -z "$(tail -c 1 "$tmp/cm" | tr -d '\n')" ] || return 1
  fi
  return 0
}

# Judges record $1 against tree $3 (listing $7) for item $2, input commit $4,
# base $5 (empty: none), doubles $6 and common git directory $8 (empty: the
# release relation is never tried). Prints
# "<tree><TAB><record time><TAB><같음|릴리스 차이>" and 0 when the pass may be
# reused — `같음` when the record's own conditions hold, `릴리스 차이` when it
# passed through the release relation; 1 for any other record, unreadable or
# malformed ones included.
tr_judge() {
  tr_judge_ver 1 "" "" "$@"
}

# Judges lane record $1 against tree $3 (listing $7) for section ids $2, input
# commit $4, base $5 (empty: none), doubles $6, cut digest $8 and common git
# directory $9. Every condition of tr_judge holds, the record is version 2, its
# `절` are the ids and its `컷증명` is the digest; an empty $8 leaves the
# digest unchecked, so a caller can compute it only for a record that met
# everything else. Prints
# "<tree><TAB><record time><TAB><같음|릴리스 차이><TAB><record digest>" and 0
# when the pass may be reused.
tr_lane_judge() {
  local ids
  ids=$(tr_lane_ids "$2")
  [ -n "$ids" ] || return 1
  tr_judge_ver 2 "$ids" "${8:-}" "$1" "lane:$ids" "$3" "$4" "$5" "$6" "$7" "${9:-}"
}

# The judge of both versions: $1 the version, $2 the ids and $3 the digest a
# version-2 record must carry, then tr_judge's arguments. The awk judge prints
# its verdict for the record's own conditions, or `후보` with the record's
# input commit when only release paths differ under the same base; only then
# is git asked about the release relation.
tr_judge_ver() {
  local ver="$1" ids="$2" cut="$3" rec="$4" key="$5" tree="$6" commit="$7" base="${8:-없음}" doubles="$9" list="${10}" gdir="${11:-}" now out rest rc_commit
  [ -r "$rec" ] && [ -r "$list" ] || return 1
  now=$(tr_now)
  out=$(tr_judge_awk "$ver" "$ids" "$cut" "$rec" "$key" "$tree" "$commit" "$base" "$doubles" "$list" "$now" "$gdir") || return 1
  case "$out" in
    후보$'\t'*)
      rest="${out#*$'\t'}"
      rc_commit="${rest%%$'\t'*}"
      rest="${rest#*$'\t'}"
      tr_release_rel "$gdir" "$rc_commit" "$commit" || return 1
      if [ "$ver" = 2 ]; then
        printf '%s\t릴리스 차이\t%s\n' "${rest%$'\t'*}" "${rest##*$'\t'}"
      else
        printf '%s\t릴리스 차이\n' "$rest"
      fi ;;
    *) printf '%s\n' "$out" ;;
  esac
  return 0
}

# The awk part of tr_judge_ver: its ten arguments, then the clock and the
# common git directory (empty: no `후보` is printed).
tr_judge_awk() {
  local ver="$1" ids="$2" cut="$3" rec="$4" key="$5" tree="$6" commit="$7" base="$8" doubles="$9" list="${10}" now="${11}" gdir="${12}"
  awk -v ver="$ver" -v ids="$ids" -v cut="$cut" \
      -v key="$key" -v tree="$tree" -v commit="$commit" -v base="$base" \
      -v doubles="$doubles" -v fp="$TR_FP" -v now="$now" -v maxage="$TR_MAX_AGE" \
      -v rel="$gdir" -v rlog="$TR_REL_LOG" -v rpj="$TR_REL_PJ" '
    function entry(s, which,   t, h, p, e) {
      t = index(s, "\t"); if (!t) return 0
      split(substr(s, 1, t - 1), h, " "); p = substr(s, t + 1)
      if (h[3] == "") return 0
      e = (h[4] == "-") ? "-" : ((h[4] + 0 == 0) ? "0" : "1")
      if (which == 2) { k2[p] = h[1] SUBSEP e; b2[p] = h[3]; n2++ }
      else { k1[p] = h[1] SUBSEP e; b1[p] = h[3]; n1++ }
      return 1
    }
    FNR == NR { if (!entry($0, 2)) bad = 1; next }
    FNR == 1 { if ($0 != "cc-check-push-items " ver) exit; st = "head"; next }
    st == "head" {
      t = index($0, "\t"); if (!t) exit
      f = substr($0, 1, t - 1); v = substr($0, t + 1); H[f] = v
      if (f == "읽은경로") { if (v !~ /^[0-9]+$/) exit; nr = v + 0; st = (nr > 0) ? "read" : "listh" }
      next
    }
    st == "read" { rd[++ri] = $0; if (ri == nr) st = "listh"; next }
    st == "listh" {
      t = index($0, "\t"); if (!t || substr($0, 1, t - 1) != "목록") exit
      v = substr($0, t + 1); if (v !~ /^[0-9]+$/) exit
      nl = v + 0; st = (nl > 0) ? "list" : "end"; next
    }
    st == "list" { if (!entry($0, 1)) exit; if (++li == nl) st = "end"; next }
    st == "end" { if ($0 == "끝") done = 1; exit }
    END {
      if (!done || bad) exit 1
      if (H["항목"] != key || H["대역"] != doubles || H["도구"] != fp || fp == "") exit 1
      if (H["시각"] !~ /^[0-9]+$/) exit 1
      age = now - H["시각"]; if (age < 0 || age > maxage) exit 1
      if (n1 != n2) exit 1
      for (p in k1) if (!(p in k2) || k1[p] != k2[p]) exit 1
      if (H["트리전체"] != "예" && H["트리전체"] != "아니오") exit 1
      for (i = 1; i <= nr; i++) if (!(rd[i] in b1)) exit 1
      tail = ""
      if (ver == 2) {
        if (H["절"] != ids || H["컷증명"] !~ /^[0-9a-f]+$/) exit 1
        if (cut != "" && H["컷증명"] != cut) exit 1
        tail = "\t" H["컷증명"]
      }
      same = 1
      if (H["트리전체"] == "예" && (H["시험트리"] != tree || H["커밋"] != commit || H["베이스"] != base)) same = 0
      for (i = 1; i <= nr; i++) if (b1[rd[i]] != b2[rd[i]]) same = 0
      if (same) {
        printf "%s\t%s\t같음%s\n", H["시험트리"], H["시각표기"], tail
        exit 0
      }
      # The release branch: the same base, and every differing path, at least
      # one, a release path.
      if (rel == "" || H["베이스"] != base || H["커밋"] !~ /^[0-9a-f]+$/) exit 1
      nd = 0
      for (p in b1) if (b1[p] != b2[p]) { if (p != rlog && p != rpj) exit 1; nd++ }
      if (nd == 0) exit 1
      printf "후보\t%s\t%s\t%s%s\n", H["커밋"], H["시험트리"], H["시각표기"], tail
      exit 0
    }
  ' "$list" "$rec"
}

# Looks for a record that lets item $2 skip on tree $3: $1 the common git
# directory, $4 the input commit, $5 the base (empty: none), $6 the doubles, $7
# the tracked listing of the tree (empty or missing: the listing failed, so
# nothing is reused). Prints what tr_judge prints for the first record that
# passes, "<tree><TAB><record time><TAB><같음|릴리스 차이>"; the release
# relation is read in $1.
tr_reuse_find() {
  local gdir="$1" key="$2" tree="$3" list="$7" d rec
  tr_excluded "$key" && return 1
  [ -n "$list" ] && [ -s "$list" ] || return 1
  [ -n "$TR_FP" ] || tr_fp_init || return 1
  d="$(tr_store "$gdir")/$(tr_key_name "$key")"
  [ -d "$d" ] || return 1
  for rec in "$d"/*; do
    [ -f "$rec" ] || continue
    case "${rec##*/}" in .*) continue ;; esac
    if tr_judge "$rec" "$key" "$tree" "$4" "$5" "$6" "$list" "$gdir"; then return 0; fi
  done
  return 1
}

# Picks the lane records that let sections of the requested ids $2 (comma-
# separated) skip on tree $3: $1 the common git directory, $4 the input commit,
# $5 the base (empty: none), $6 the doubles, $7 the tracked listing of the tree
# (empty or missing: nothing is reused), and the rest the command that prints
# the cut digest of the ids it is given as its last argument. Records are read
# newest first, and one is taken only when its sections all lie in the part of
# the request no taken record covers yet, so a record with a section outside
# the request, or one an earlier record already covers, is left. The digest is
# computed only for a record that met every other condition, and once per set
# of sections. Prints "<ids><TAB><tree><TAB><record time><TAB><같음|릴리스
# 차이>" per record taken; the release relation is read in $1.
tr_lane_pick() {
  local gdir="$1" want="$2" tree="$3" commit="$4" base="$5" doubles="$6" list="$7"
  local d rec name ids left hit dig seen="" digs="" id ok
  shift 7
  [ -n "$list" ] && [ -s "$list" ] || return 0
  [ -n "$TR_FP" ] || tr_fp_init || return 0
  d="$(tr_store "$gdir")/lane"
  [ -d "$d" ] || return 0
  left=",$(tr_lane_ids "$want"),"
  while IFS= read -r name; do
    [ "$left" != "," ] || break
    case "$name" in ''|.*) continue ;; esac
    rec="$d/$name"
    [ -f "$rec" ] || continue
    ids=$(awk -F '\t' 'NR == 1 && $0 != "cc-check-push-items 2" { exit } $1 == "절" { print $2; exit }' "$rec" 2>/dev/null)
    [ -n "$ids" ] || continue
    tr_excluded "lane:$ids" && continue
    ok=1
    for id in $(printf '%s' "$ids" | tr ',' ' '); do
      case "$left" in *",$id,"*) ;; *) ok=0; break ;; esac
    done
    [ "$ok" = 1 ] || continue
    hit=$(tr_lane_judge "$rec" "$ids" "$tree" "$commit" "$base" "$doubles" "$list" "" "$gdir") || continue
    case "$seen" in
      *"|$ids|"*)
        dig=$(printf '%s\n' "$digs" | awk -F '\t' -v k="$ids" '$1 == k { print $2; exit }') ;;
      *)
        dig=$("$@" "$ids" 2>/dev/null) || dig=""
        case "$dig" in *[!0-9a-f]*) dig="" ;; esac
        seen="$seen|$ids|"
        digs="$digs${ids}	$dig
" ;;
    esac
    [ -n "$dig" ] || continue
    [ "${hit##*$'\t'}" = "$dig" ] || continue
    hit="${hit%$'\t'*}"
    printf '%s\t%s\n' "$ids" "$hit"
    for id in $(printf '%s' "$ids" | tr ',' ' '); do left="${left/,$id,/,}"; done
  done <<EOF
$(ls -t "$d" 2>/dev/null)
EOF
  return 0
}

# --- self-test ---------------------------------------------------------------------------

tr_self_test() {
  local passed=0 failed=0 T W G CK S L L2 rs out rc v c1 tree1 rec moved n i
  ok()  { passed=$((passed + 1)); printf 'PASS: %s\n' "$1"; }
  bad() { failed=$((failed + 1)); printf 'FAIL: %s — %s\n' "$1" "${2:-}" >&2; }
  check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got「$2」 want「$3」"; fi; }
  has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "「$3」 없음: $2" ;; esac; }
  hasnt() { case "$2" in *"$3"*) bad "$1" "「$3」 있음: $2" ;; *) ok "$1" ;; esac; }
  for v in $(compgen -e); do
    case "$v" in CC_TEST_SLOT*|CHECK_PUSH_*) unset "$v" ;; esac
  done
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR
  T=$(mktemp -d "${TMPDIR:-/tmp}/test-reuse-selftest.XXXXXX") || return 1
  T=$(cd "$T" && pwd -P)
  TR_CLOCK="$T/clock"
  printf '1000000\n' > "$TR_CLOCK"
  TR_EXCLUDE=""
  sg() { git -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }

  # --- key names and the exclusion list ---
  check "키 이름: / 는 %2F" "$(tr_key_name make:run/scripts/test-rekick.sh)" "make:run%2Fscripts%2Ftest-rekick.sh"
  check "키 이름: / 없는 키는 그대로" "$(tr_key_name make:check-cheap)" "make:check-cheap"
  TR_EXCLUDE="make:a make:b"
  if tr_excluded make:b; then ok "제외 목록: 든 키"; else bad "제외 목록: 든 키"; fi
  if tr_excluded make:c; then bad "제외 목록: 없는 키"; else ok "제외 목록: 없는 키"; fi
  TR_EXCLUDE=""

  # --- a fixture repository ---
  W="$T/work"
  G="$T/gdir"
  mkdir -p "$W" "$G"
  ( cd "$W" && git init -q . && printf 'read me\n' > a && printf 'unread\n' > b && : > e \
      && printf '#!/bin/sh\n' > x.sh && chmod +x x.sh && ln -s a lnk && mkdir sub && printf 's\n' > sub/s \
      && sg add -A && sg commit -q -m one ) || { bad "픽스처" "git"; return 1; }
  c1=$(cd "$W" && git rev-parse HEAD)
  tree1=$(cd "$W" && git rev-parse "HEAD^{tree}")
  L="$T/list1"
  tr_list "$W" "$c1" "$L"
  check "목록: 추적 항목 여섯" "$(wc -l < "$L" | tr -d ' ')" "6"
  if tr_list "$W" 0000000000000000000000000000000000000000 "$T/badlist"; then bad "목록: 없는 커밋은 실패"; else ok "목록: 없는 커밋은 실패"; fi
  TR_FP=""
  tr_fp_init
  if [ -n "$TR_FP" ]; then ok "도구 지문이 선다"; else bad "도구 지문이 선다"; fi

  # A record of tree one that read `a`.
  rs="$T/rs1"
  printf '아니오\na\n' > "$rs"
  tr_record_write "$G" make:t "$tree1" "$c1" "" 없음 "$L" "$rs"
  rec="$(tr_store "$G")/make:t/$tree1"
  check "기록: 파일이 생긴다" "$([ -f "$rec" ] && echo 있음)" "있음"
  has "기록: 읽은 경로" "$(cat "$rec")" $'읽은경로\t1\na\n목록\t6'
  has "기록: 베이스 없음" "$(cat "$rec")" $'베이스\t없음'
  # Judges a commit of the work tree, made by the commands in $2, against the
  # record; prints 재사용 or 재실행 and resets the tree.
  judge_after() {
    local what="$1" c t
    ( cd "$W" && eval "$2" && sg add -A && sg commit -q --allow-empty -m change ) >/dev/null 2>&1
    c=$(cd "$W" && git rev-parse HEAD)
    t=$(cd "$W" && git rev-parse "HEAD^{tree}")
    tr_list "$W" "$c" "$T/l2"
    if tr_reuse_find "$G" make:t "$t" "${3:-$c}" "${4:-}" 없음 "$T/l2" >/dev/null; then echo 재사용; else echo 재실행; fi
    ( cd "$W" && git reset -q --hard "$c1" ) >/dev/null 2>&1
    : "$what"
  }
  check "판정: 같은 트리는 재사용" "$(judge_after same ':')" "재사용"
  check "판정: 읽지 않은 파일이 비지 않은 채 크기만 바뀌면 재사용" "$(judge_after size 'printf "unread, longer\n" > b')" "재사용"
  check "판정: 읽은 파일이 바뀌면 재실행" "$(judge_after read 'printf "changed\n" > a')" "재실행"
  check "판정: 경로가 늘면 재실행" "$(judge_after add 'printf n > new')" "재실행"
  check "판정: 경로가 줄면 재실행" "$(judge_after del 'git rm -q sub/s')" "재실행"
  check "판정: 모드가 바뀌면 재실행" "$(judge_after mode 'chmod -x x.sh')" "재실행"
  check "판정: 빈 파일에 내용이 생기면 재실행" "$(judge_after fill 'printf x > e')" "재실행"
  check "판정: 파일이 비면 재실행" "$(judge_after empty ': > b')" "재실행"
  out=$(tr_list "$W" "$c1" "$T/l2"; if tr_reuse_find "$G" make:t "$tree1" "$c1" "" 다른대역 "$T/l2" >/dev/null; then echo 재사용; else echo 재실행; fi)
  check "판정: 대역이 다르면 재실행" "$out" "재실행"
  out=$(TR_FP=other; if tr_reuse_find "$G" make:t "$tree1" "$c1" "" 없음 "$L" >/dev/null; then echo 재사용; else echo 재실행; fi)
  check "판정: 도구 지문이 다르면 재실행" "$out" "재실행"
  printf '%s\n' $((1000000 + 86400)) > "$TR_CLOCK"
  out=$(if tr_reuse_find "$G" make:t "$tree1" "$c1" "" 없음 "$L" >/dev/null; then echo 재사용; else echo 재실행; fi)
  check "판정: 24시간 째는 재사용" "$out" "재사용"
  printf '%s\n' $((1000000 + 86401)) > "$TR_CLOCK"
  out=$(if tr_reuse_find "$G" make:t "$tree1" "$c1" "" 없음 "$L" >/dev/null; then echo 재사용; else echo 재실행; fi)
  check "판정: 24시간이 지나면 재실행" "$out" "재실행"
  printf '1000000\n' > "$TR_CLOCK"
  out=$(if tr_reuse_find "$G" make:t "$tree1" "$c1" "" 없음 "" >/dev/null; then echo 재사용; else echo 재실행; fi)
  check "판정: 지금 트리의 목록이 실패하면 재실행" "$out" "재실행"
  out=$(tr_reuse_find "$G" make:t "$tree1" "$c1" "" 없음 "$L")
  has "판정: 기록의 트리를 돌려준다" "$out" "$tree1"
  TR_EXCLUDE="make:t"
  out=$(if tr_reuse_find "$G" make:t "$tree1" "$c1" "" 없음 "$L" >/dev/null; then echo 재사용; else echo 재실행; fi)
  check "판정: 제외 목록의 키는 재사용하지 않는다" "$out" "재실행"
  tr_record_write "$G" make:t "deadbeef" "$c1" "" 없음 "$L" "$rs"
  check "기록: 제외 목록의 키는 쓰지 않는다" "$([ -e "$(tr_store "$G")/make:t/deadbeef" ] && echo 있음 || echo 없음)" "없음"
  TR_EXCLUDE=""

  # A broken record next to a good one: the broken one counts as absent.
  cp "$rec" "$T/rec.good"
  head -n 5 "$T/rec.good" > "$rec"
  out=$(if tr_reuse_find "$G" make:t "$tree1" "$c1" "" 없음 "$L" 2>&1 >/dev/null; then echo 재사용; else echo 재실행; fi)
  check "깨진 기록: 없는 것으로 친다" "$out" "재실행"
  printf 'not a record\n' > "$rec"
  out=$(tr_reuse_find "$G" make:t "$tree1" "$c1" "" 없음 "$L" 2>&1; echo "rc=$?")
  check "깨진 기록: 오류 없이 재실행" "$out" "rc=1"
  cp "$T/rec.good" "$(tr_store "$G")/make:t/other"
  out=$(if tr_reuse_find "$G" make:t "$tree1" "$c1" "" 없음 "$L" >/dev/null; then echo 재사용; else echo 재실행; fi)
  check "기록 여럿: 하나라도 맞으면 재사용" "$out" "재사용"
  rm -f "$(tr_store "$G")/make:t/other"
  cp "$T/rec.good" "$rec"

  # A whole-tree record: the tree, the input commit and the base must match.
  printf '예\n' > "$T/rsw"
  tr_record_write "$G" make:w "$tree1" "$c1" "b1" 없음 "$L" "$T/rsw"
  w_judge() { if tr_reuse_find "$G" make:w "$1" "$2" "$3" 없음 "$4" >/dev/null; then echo 재사용; else echo 재실행; fi; }
  check "트리 전체: 트리·커밋·베이스가 같으면 재사용" "$(w_judge "$tree1" "$c1" b1 "$L")" "재사용"
  check "트리 전체: 커밋이 다르면 재실행" "$(w_judge "$tree1" other b1 "$L")" "재실행"
  check "트리 전체: 베이스가 다르면 재실행" "$(w_judge "$tree1" "$c1" b2 "$L")" "재실행"
  check "트리 전체: 베이스가 없으면 재실행" "$(w_judge "$tree1" "$c1" "" "$L")" "재실행"
  ( cd "$W" && printf 'unread, longer\n' > b && sg add -A && sg commit -q -m size ) >/dev/null 2>&1
  tr_list "$W" "$(cd "$W" && git rev-parse HEAD)" "$T/l3"
  check "트리 전체: 트리가 다르면 재실행" "$(w_judge "$(cd "$W" && git rev-parse 'HEAD^{tree}')" "$c1" b1 "$T/l3")" "재실행"
  ( cd "$W" && git reset -q --hard "$c1" ) >/dev/null 2>&1
  printf '예\n' > "$T/rsn"
  tr_record_write "$G" make:n "$tree1" "$c1" "" 없음 "$L" "$T/rsn"
  out=$(if tr_reuse_find "$G" make:n "$tree1" "$c1" "" 없음 "$L" >/dev/null; then echo 재사용; else echo 재실행; fi)
  check "트리 전체: 베이스가 둘 다 없음이면 재사용" "$out" "재사용"

  # --- the sweep ---
  mkdir -p "$(tr_store "$G")/make:old"
  printf 'x\n' > "$(tr_store "$G")/make:old/t"
  touch -t 200001010000 "$(tr_store "$G")/make:old/t"
  tr_record_write "$G" make:t "$tree1" "$c1" "" 없음 "$L" "$rs"
  check "정리: 24시간 지난 기록과 빈 키 디렉터리를 지운다" "$([ -e "$(tr_store "$G")/make:old" ] && echo 있음 || echo 없음)" "없음"
  check "정리: 새 기록은 남긴다" "$([ -f "$rec" ] && echo 있음 || echo 없음)" "있음"

  # --- one item's run in a checkout of its own ---
  CK="$T/items/1"
  S="$T/items/1"
  mkdir -p "$T/items"
  git clone -q --shared --no-checkout "$W" "$CK" 2>/dev/null
  ( cd "$CK" && git checkout -q "$c1" 2>/dev/null && git config core.trustctime false && git config core.checkStat minimal )
  check "체크아웃: --shared 복제의 alternates" "$([ -f "$CK/.git/objects/info/alternates" ] && echo 있음)" "있음"
  if tr_baseline "$CK" "$S" "$L"; then ok "기준선이 선다"; else bad "기준선이 선다"; fi
  v=$(tr_atime "$CK/a")
  if [ "$v" -le "$TR_BASE_MAX" ]; then ok "기준선: atime 이 2000-01-01 로"; else bad "기준선: atime 이 2000-01-01 로" "$v"; fi
  check "기준선: 심볼릭 링크는 늘 읽은 목록에" "$(cat "$S.links")" "lnk"
  moved=0
  if tr_canary "$S"; then moved=1; fi
  v=$(tr_atime "$S.canary")
  if [ "$v" -le "$TR_BASE_MAX" ]; then ok "카나리아: 본 뒤 기준선으로 되돌린다"; else bad "카나리아: 본 뒤 기준선으로 되돌린다" "$v"; fi
  ( cd "$CK" && cat a > /dev/null && printf 'more\n' >> sub/s )
  tr_collect "$CK" "$S" "$L" "$T/rsc"
  out=$(tr "\n" " " < "$T/rsc")
  # The read set rests on the access time, which a volume where reads do not
  # move it cannot show; such a volume records nothing, so both branches check
  # the same number of things.
  if [ "$moved" = 1 ]; then
    check "읽은 집합: 읽은 파일·바뀐 파일·링크만" "$out" "아니오 a lnk sub/s "
    ( cd "$CK" && git status --porcelain > /dev/null )
    tr_collect "$CK" "$S" "$L" "$T/rsc"
    check "읽은 집합: 체크아웃의 git 은 트리 전체" "$(head -n 1 "$T/rsc")" "예"
  else
    check "카나리아 정지 볼륨: 카나리아가 움직이지 않는다" "$moved" "0"
    check "카나리아 정지 볼륨: 기록하지 않는 쪽" "$moved" "0"
  fi
  rm "$CK/b"
  tr_collect "$CK" "$S" "$L" "$T/rsc"
  check "읽은 집합: 사라진 파일은 읽은 것" "$(grep -cx b "$T/rsc")" "1"

  # --- the watch shims ---
  ( cd "$CK" && git checkout -q -- b )
  if tr_shims "$CK" "$S"; then ok "감시 꼴이 선다"; else bad "감시 꼴이 선다"; fi
  FX="$T/fixture"
  mkdir -p "$FX"
  ( cd "$FX" && git init -q . )
  # Runs the git shim with the arguments given from directory $1 and prints
  # 표지 when it left a mark; the mark goes away after.
  gmark() {
    local dir="$1"
    shift
    rm -f "$S.mark"
    ( cd "$dir" && "$S.shim/git" "$@" ) > /dev/null 2>&1
    if [ -s "$S.mark" ]; then echo 표지; else echo 없음; fi
    rm -f "$S.mark"
  }
  check "git 감시 꼴: 작업 디렉터리만 체크아웃 안이면 표지 없음" "$(gmark "$CK/sub" status)" "없음"
  check "git 감시 꼴: 작업 디렉터리만 체크아웃 안이고 밖을 복제하면 표지 없음" "$(gmark "$CK" clone -q "$FX" "$T/clone-out")" "없음"
  check "git 감시 꼴: -C 가 체크아웃" "$(gmark "$FX" -C "$CK" status)" "표지"
  check "git 감시 꼴: 앞에서부터 적용한 -C" "$(gmark "$T" -C items -C 1 status)" "표지"
  out=$(rm -f "$S.mark"; cd "$FX" && GIT_DIR="$CK/.git" "$S.shim/git" status >/dev/null 2>&1; if [ -s "$S.mark" ]; then echo 표지; else echo 없음; fi)
  check "git 감시 꼴: GIT_DIR 이 체크아웃" "$out" "표지"
  check "git 감시 꼴: 경로 인자가 체크아웃 안" "$(gmark "$T" clone -q "$CK" "$T/clone2")" "표지"
  check "git 감시 꼴: --git-dir= 이 체크아웃" "$(gmark "$FX" "--git-dir=$CK/.git" status)" "표지"
  check "git 감시 꼴: 픽스처 저장소만 향하면 표지 없음" "$(gmark "$FX" status)" "없음"
  check "git 감시 꼴: 픽스처를 -C 로 향해도 표지 없음" "$(gmark "$T" -C fixture log --oneline)" "없음"
  out=$(cd "$FX" && "$S.shim/git" rev-parse --is-inside-work-tree 2>&1)
  check "git 감시 꼴: 진짜 git 으로 넘긴다" "$out" "true"
  # Runs the cp shim from directory $1; prints "<rc> <표지|없음>".
  cmark() {
    local dir="$1" r
    shift
    rm -f "$S.mark"
    ( cd "$dir" && "$S.shim/cp" "$@" ) > /dev/null 2>&1
    r=$?
    if [ -s "$S.mark" ]; then echo "$r 표지"; else echo "$r 없음"; fi
    rm -f "$S.mark"
  }
  # The clone option of this host's cp; the other spellings only check the mark.
  tr_os_init
  if [ "$TR_OS" = bsd ]; then
    check "cp 감시 꼴: 이 OS 의 복제 선택지(-c)로 체크아웃 파일 복사" "$(cmark "$T" -c "$CK/a" "$T/copy1")" "0 표지"
  else
    check "cp 감시 꼴: 이 OS 의 복제 선택지(--reflink=auto)로 체크아웃 파일 복사" "$(cmark "$T" --reflink=auto "$CK/a" "$T/copy1")" "0 표지"
  fi
  check "cp 감시 꼴: 묶인 짧은 선택지 안의 c" "$(cmark "$CK" -pc a "$T/copy2" | cut -d' ' -f2)" "표지"
  check "cp 감시 꼴: --reflink" "$(cmark "$T" --reflink "$CK/a" "$T/copy3" | cut -d' ' -f2)" "표지"
  check "cp 감시 꼴: --reflink=never 는 표지 없음" "$(cmark "$T" --reflink=never "$CK/a" "$T/copy4" | cut -d' ' -f2)" "없음"
  check "cp 감시 꼴: 복제 선택지 없는 복사는 표지 없음" "$(cmark "$T" "$CK/a" "$T/copy5")" "0 없음"
  printf 'out\n' > "$T/outside"
  check "cp 감시 꼴: 체크아웃 밖 파일만 복제하면 표지 없음" "$(cmark "$T" -pc "$T/outside" "$T/copy6" | cut -d' ' -f2)" "없음"
  check "cp 감시 꼴: 체크아웃 안으로의 복제도 표지" "$(cmark "$T" -pc "$T/outside" "$CK/new" | cut -d' ' -f2)" "표지"
  # The shim calls above ran the real git in the checkout; a fresh baseline
  # leaves only the mark to tell.
  rm -f "$CK/new"
  if tr_baseline "$CK" "$S" "$L"; then ok "기준선을 다시 세운다"; else bad "기준선을 다시 세운다"; fi
  tr_collect "$CK" "$S" "$L" "$T/rsc"
  check "감시 꼴 표지가 없으면 트리 전체가 아니다" "$(head -n 1 "$T/rsc")" "아니오"
  printf 'git arg x\n' > "$S.mark"
  tr_collect "$CK" "$S" "$L" "$T/rsc"
  check "감시 꼴 표지가 있으면 트리 전체" "$(head -n 1 "$T/rsc")" "예"

  # --- lane records (version 2) ---
  local D1 D2 LD lrec lj lp n1 n2 longids
  D1=$(printf 'one' | tr_sha256)
  D2=$(printf 'two' | tr_sha256)
  check "레인: 절 id 는 정렬해 쉼표로 잇는다" "$(tr_lane_ids 's2,s10,,s1,s2')" "s1,s10,s2"
  tr_lane_write "$G" s2,s1 "$tree1" "$c1" "" 없음 "$L" "$rs" "$D1"
  lrec=$(tr_lane_path "$G" s1,s2 "$tree1")
  check "레인 기록: lane/<키의 sha256>.<트리> 에 생긴다" \
    "$([ -f "$lrec" ] && echo 있음)|${lrec#"$(tr_store "$G")/lane/"}" "있음|$(printf 'lane:s1,s2' | tr_sha256).$tree1"
  has "레인 기록: 판 2 머리와 정렬한 절·컷증명" "$(cat "$lrec")" "cc-check-push-items 2
항목	lane:s1,s2
절	s1,s2
컷증명	$D1"
  lj() { if tr_lane_judge "$lrec" "$1" "$tree1" "$c1" "" 없음 "$L" "$2" > /dev/null; then echo 재사용; else echo 재실행; fi; }
  check "레인 판정: 같은 절·같은 컷증명이면 재사용" "$(lj s2,s1 "$D1")" "재사용"
  check "레인 판정: 컷증명이 다르면 재실행" "$(lj s1,s2 "$D2")" "재실행"
  check "레인 판정: 절이 다르면 재실행" "$(lj s1 "$D1")" "재실행"
  out=$(TR_FP=other; if tr_lane_judge "$lrec" s1,s2 "$tree1" "$c1" "" 없음 "$L" "$D1" > /dev/null; then echo 재사용; else echo 재실행; fi)
  check "레인 판정: 목표 기록의 조건(도구 지문)도 그대로 건다" "$out" "재실행"
  out=$(if tr_judge "$lrec" lane:s1,s2 "$tree1" "$c1" "" 없음 "$L" > /dev/null; then echo 재사용; else echo 재실행; fi)
  check "목표 판정기는 레인 기록(판 2)을 거절한다" "$out" "재실행"
  out=$(if tr_lane_judge "$rec" make:t "$tree1" "$c1" "" 없음 "$L" "$D1" > /dev/null; then echo 재사용; else echo 재실행; fi)
  check "레인 판정기는 목표 기록(판 1)을 거절한다" "$out" "재실행"
  if tr_lane_write "$G" s1 "$tree1" "$c1" "" 없음 "$L" "$rs" ""; then bad "레인 기록: 컷증명 없이는 쓰지 않는다"; else ok "레인 기록: 컷증명 없이는 쓰지 않는다"; fi
  longids=$(i=0; while [ "$i" -lt 120 ]; do printf 'long-section-id-%03d,' "$i"; i=$((i + 1)); done)
  tr_lane_write "$G" "$longids" "$tree1" "$c1" "" 없음 "$L" "$rs" "$D1"
  lp=$(tr_lane_path "$G" "$longids" "$tree1")
  check "레인 기록: 긴 ids 도 키 해시 이름으로 쓰인다" "$([ -f "$lp" ] && echo 있음)|${#longids}" "있음|2400"
  rm -f "$lp"
  tr_lane_write "$G" s1,s2 deadbeef "$c1" "" 없음 "$L" "$rs" "$D1"
  check "레인 기록: 같은 절·다른 트리의 두 기록이 함께 남는다" \
    "$([ -f "$lrec" ] && [ -f "$(tr_lane_path "$G" s1,s2 deadbeef)" ] && echo 둘)" "둘"
  rm -f "$(tr_lane_path "$G" s1,s2 deadbeef)"

  # Picking: the digest double logs each set of sections it is asked about.
  LD="$(tr_store "$G")/lane"
  rm -f "$LD"/*
  DIGV="$D1"
  fake_dig() { printf '%s\n' "$1" >> "$T/digcalls"; printf '%s' "$DIGV"; }
  # The order of the records is set by their modification times, seconds
  # apart within the current minute, so the sweep keeps them all.
  local mnow
  mnow=$(date +%Y%m%d%H%M)
  lw() {  # <ids> <seconds into the minute>
    tr_lane_write "$G" "$1" "$tree1" "$c1" "" 없음 "$L" "$rs" "$D1"
    touch -t "$mnow.$2" "$(tr_lane_path "$G" "$1" "$tree1")"
  }
  lp() { : > "$T/digcalls"; tr_lane_pick "$G" "$1" "$tree1" "$c1" "" 없음 "$L" fake_dig | cut -f1 | tr '\n' ' '; }
  lw s1 01
  lw s3 02
  check "고르기: 서로소 두 기록을 함께 받는다" "$(lp s1,s2,s3)" "s3 s1 "
  check "고르기: 같은 절 묶음마다 다이제스트를 한 번 계산한다" "$(LC_ALL=C sort "$T/digcalls" | tr '\n' ' ')" "s1 s3 "
  lw s1,s2,s3,s4 03
  check "고르기: 요청 밖 절을 담은 상위 집합 기록은 쓰지 않는다" "$(lp s1,s2,s3)" "s3 s1 "
  lw s1,s2 04
  check "고르기: 겹치는 두 기록 가운데 새것만 받는다" "$(lp s1,s2,s3)" "s1,s2 s3 "
  check "고르기: 다른 조건이 어긋난 기록은 다이제스트를 계산하지 않는다" \
    "$(: > "$T/digcalls"; tr_lane_pick "$G" s1,s2 "$tree1" "$c1" "" 다른대역 "$L" fake_dig; grep -c . "$T/digcalls")" "0"
  DIGV="$D2"
  tr_lane_write "$G" s1,s2 deadbeef "$c1" "" 없음 "$L" "$rs" "$D1"
  touch -t "$mnow.05" "$(tr_lane_path "$G" s1,s2 deadbeef)"
  check "고르기: 컷증명이 다르면 받지 않는다" "$(lp s1,s2,s3)" ""
  check "고르기: 같은 절의 두 기록에도 다이제스트는 한 번이다" "$(grep -cx s1,s2 "$T/digcalls")" "1"
  rm -f "$(tr_lane_path "$G" s1,s2 deadbeef)"
  DIGV="$D1"
  check "고르기: 지금 트리의 목록이 없으면 받지 않는다" "$(: > "$T/digcalls"; tr_lane_pick "$G" s1 "$tree1" "$c1" "" 없음 "" fake_dig | grep -c .)" "0"
  n1=$(find "$LD" -type f | grep -c .)
  touch -t 200001010000 "$(tr_lane_path "$G" s3 "$tree1")"
  tr_lane_write "$G" s9 "$tree1" "$c1" "" 없음 "$L" "$rs" "$D1"
  n2=$(find "$LD" -type f | grep -c .)
  check "정리: 24시간 지난 레인 기록도 지운다" "$n1 $n2 $([ -e "$(tr_lane_path "$G" s3 "$tree1")" ] && echo 있음 || echo 없음)" "4 4 없음"

  # --- the release relation ---
  # A repository of its own whose .git is the store's common git directory:
  # the relation is read from its objects. Each record was written on commit
  # c0 under base b1; `w` keys are whole-tree records, `r` keys read
  # plugin.json only.
  local R RG r0 c0 cs PJ BUMP
  R="$T/rel"
  RG="$R/.git"
  PJ="plugins/cc-cmds/.claude-plugin/plugin.json"
  mkdir -p "$R/plugins/cc-cmds/.claude-plugin"
  pj_ver() { printf '{\n  "name": "%s",\n  "version": "%s",\n  "description": "d"\n}\n' "${2:-x}" "$1" > "$PJ"; }
  log_top() { printf '# Changelog\n\nintro\n\n%b## [1.0.0] - 2026-01-01\n- %s\n' "$1" "${2:-a}" > CHANGELOG.md; }
  ( cd "$R" && git init -q . && pj_ver 1.0.0 && log_top '' && printf 'o\n' > o.txt \
      && sg add -A && sg commit -q -m c0 ) > /dev/null 2>&1 || { bad "릴리스 픽스처" "git"; return 1; }
  c0=$(cd "$R" && git rev-parse HEAD)
  r0=$(cd "$R" && git rev-parse 'HEAD^{tree}')
  cs=$(cd "$R" && sg commit-tree "$r0" -m sibling)
  tr_list "$R" "$c0" "$T/lr0"
  printf '아니오\n%s\n' "$PJ" > "$T/rsr"
  tr_record_write "$RG" make:rw "$r0" "$c0" b1 없음 "$T/lr0" "$T/rsw"
  tr_record_write "$RG" make:rr "$r0" "$c0" b1 없음 "$T/lr0" "$T/rsr"
  tr_record_write "$RG" make:sw "$r0" "$cs" b1 없음 "$T/lr0" "$T/rsw"
  tr_record_write "$RG" make:sr "$r0" "$cs" b1 없음 "$T/lr0" "$T/rsr"
  tr_record_write "$RG" make:mw "$r0" 0123456789abcdef0123456789abcdef01234567 b1 없음 "$T/lr0" "$T/rsw"
  tr_record_write "$RG" make:mr "$r0" 0123456789abcdef0123456789abcdef01234567 b1 없음 "$T/lr0" "$T/rsr"
  # Prints the last field of the verdict for key $1, or 재실행.
  rj() {  # <key> <tree> <commit> <base> <listing>
    local o
    if o=$(tr_reuse_find "$RG" "$1" "$2" "$3" "$4" 없음 "$5"); then printf '%s' "${o##*$'\t'}"; else printf '재실행'; fi
  }
  # Commits the commands of $1 on top of c0 and prints "<w key>|<r key>" for
  # the key letter $2 (default the c0 records) under base $3 (default b1);
  # the repository goes back to c0 after.
  rel_after() {
    local c t p="${2:-r}"
    ( cd "$R" && eval "$1" && sg add -A && sg commit -q --allow-empty -m rel ) > /dev/null 2>&1
    c=$(cd "$R" && git rev-parse HEAD)
    t=$(cd "$R" && git rev-parse 'HEAD^{tree}')
    tr_list "$R" "$c" "$T/lr"
    printf '%s|%s' "$(rj "make:${p}w" "$t" "$c" "${3:-b1}" "$T/lr")" "$(rj "make:${p}r" "$t" "$c" "${3:-b1}" "$T/lr")"
    ( cd "$R" && git reset -q --hard "$c0" ) > /dev/null 2>&1
  }
  BUMP="pj_ver 1.0.1 && log_top '## [1.0.1] - 2026-01-02\n- b\n\n'"
  check "릴리스: 같은 커밋은 지금 조건으로 재사용하고 같음" "$(rj make:rw "$r0" "$c0" b1 "$T/lr0")|$(rj make:rr "$r0" "$c0" b1 "$T/lr0")" "같음|같음"
  check "릴리스: 버전 줄과 CHANGELOG 맨 위 끼우기만 바꾼 커밋은 둘 다 재사용" "$(rel_after "$BUMP")" "릴리스 차이|릴리스 차이"
  check "릴리스: 버전 줄만 바꾼 커밋도 재사용" "$(rel_after 'pj_ver 1.0.1')" "릴리스 차이|릴리스 차이"
  check "릴리스: CHANGELOG 끼우기만 한 커밋은 트리 전체 기록을 재사용" "$(rel_after "log_top '## [1.0.1] - 2026-01-02\n- b\n\n'")" "릴리스 차이|같음"
  check "릴리스: plugin.json 의 다른 줄도 바꾸면 재실행" "$(rel_after "pj_ver 1.0.1 y && log_top '## [1.0.1] - 2026-01-02\n- b\n\n'")" "재실행|재실행"
  check "릴리스: CHANGELOG 기존 항목 본문을 고치면 재실행" "$(rel_after "pj_ver 1.0.1 && log_top '' 'a fixed'")" "재실행|재실행"
  check "릴리스: 끼운 묶음이 ## [ 로 시작하지 않으면 재실행" "$(rel_after "pj_ver 1.0.1 && log_top 'note\n\n'")" "재실행|재실행"
  check "릴리스: 릴리스 밖 파일도 바꾸면 재실행" "$(rel_after "$BUMP && printf 'o2\n' > o.txt")" "재실행|재실행"
  check "릴리스: 베이스가 다르면 재실행" "$(rel_after "$BUMP" r b2)" "재실행|재실행"
  check "릴리스: 기록 커밋이 같은 트리의 형제(조상 아님)면 재실행" "$(rel_after "$BUMP" s)" "재실행|재실행"
  out=$( ( cd "$R" && eval "$BUMP" && sg add -A && sg commit -q -m rel ) > /dev/null 2>&1
    c=$(cd "$R" && git rev-parse HEAD); t=$(cd "$R" && git rev-parse 'HEAD^{tree}'); tr_list "$R" "$c" "$T/lr"
    tr_reuse_find "$RG" make:mw "$t" "$c" b1 없음 "$T/lr" 2>&1; printf 'rc=%s|' "$?"
    tr_reuse_find "$RG" make:mr "$t" "$c" b1 없음 "$T/lr" 2>&1; printf 'rc=%s' "$?"
    ( cd "$R" && git reset -q --hard "$c0" ) > /dev/null 2>&1 )
  check "릴리스: 기록 커밋 객체가 없으면 오류 출력 없이 재실행" "$out" "rc=1|rc=1"
  tr_lane_write "$RG" s1 "$r0" "$c0" b1 없음 "$T/lr0" "$T/rsw" "$D1"
  DIGV="$D1"
  out=$( ( cd "$R" && eval "$BUMP" && sg add -A && sg commit -q -m rel ) > /dev/null 2>&1
    c=$(cd "$R" && git rev-parse HEAD); t=$(cd "$R" && git rev-parse 'HEAD^{tree}'); tr_list "$R" "$c" "$T/lr"
    tr_lane_pick "$RG" s1 "$t" "$c" b1 없음 "$T/lr" fake_dig | cut -f1,4
    ( cd "$R" && git reset -q --hard "$c0" ) > /dev/null 2>&1 )
  check "릴리스: 레인 기록도 같은 릴리스 커밋에서 재사용하고 넷째 필드가 릴리스 차이" "$out" "s1	릴리스 차이"

  rm -rf "$T"
  printf 'test-reuse self-test: %d passed, %d failed\n' "$passed" "$failed"
  # A floor on the count, so a refactor that silently skips cases cannot pass.
  if [ "$passed" -lt 99 ]; then
    printf 'test-reuse self-test: 통과 수 %d 가 하한 %d 에 못 미칩니다\n' "$passed" 99 >&2
    return 1
  fi
  [ "$failed" = "0" ]
}

# --- main ------------------------------------------------------------------------------

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -uo pipefail
  case "${1:-}" in
    --self-test) tr_self_test; exit $? ;;
    *) printf 'test-reuse: 사용법 — --self-test\n' >&2; exit 2 ;;
  esac
fi
