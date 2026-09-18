#!/usr/bin/env bash
# pin.sh — pin a run to ONE version of the orchestrator, and tell every entry
# point where that version lives.
#
# THE PROBLEM THIS SOLVES. The plugin checkout is shared and moves while runs
# are open: a deploy lands, a `git pull` fast-forwards, a sibling run's apply
# stage rewrites a rule. A run that started on one version therefore finishes on
# another, and nothing records which code actually enforced it. Pinning copies
# the whole plugin root into the run's own directory once, at run open, and
# every later gate call, watcher and feed `exec`s into that copy (the "hop").
#
# WHY INSIDE THE RUN DIRECTORY. The run directory is already a place stages may
# not write — the hook's allow-list refuses every name there but `halt/<id>.md`
# and `<segment>.plan.md`, and `gate_rundir_write_guard` refuses the same set on
# the Bash path. A copy placed anywhere else would be writable by the very
# stages it enforces. Its lifetime is the run's, so the existing reaper collects
# it with everything else.
#
# TWO WAYS TO TAKE THE COPY, AND THE CHOICE IS NOT STYLISTIC. A clean subtree is
# taken with `git archive <tree>`: a tree object is atomic, so a concurrent
# checkout in the source cannot hand back a half-updated copy. A dirty subtree
# has no tree object to name, so it is taken with `cp -R` inside a bracket that
# checks `index.lock` absence and HEAD stability on both sides and throws the
# copy away when either moved. `tar -c` IS NEVER USED: on this host it rewrites
# Korean rule file names into NFD, and rule names are compared as bytes, so a
# `tar -c` copy silently stops matching its own exemption rules. `tar -x` on the
# receiving end of `git archive` is fine — it only writes the names it was given.
#
# EVERY GIT READ CARRIES `--no-optional-locks`. A plain `git status` rewrites the
# index and holds `index.lock` for a quarter of a second, and the command this
# pinning races against is the one that applies this very design: a concurrent
# `git pull --ff-only` fails outright while that lock is held.
#
# THE PIN IS PUBLISHED ATOMICALLY because run open is not single-entry: the
# seat's `snapshot` and a hook-routed call can both find "no pin". Both build a
# copy under a private name, then race a single `link(2)` to publish
# `plugin-pin`. The loser throws its copy away and waits for the winner's copy to
# appear; exactly one copy and one pin survive.
#
# NO `set -e` AND NO TRAILING CALL. This file is sourced by `gate.sh`, `watch.sh`
# and `feed.sh` for its definitions only; the sourcing scripts own their own
# shell options.
#
# Compatibility: bash 3.2 (macOS) — no associative arrays, no `mapfile`.
# `scripts/lint-bash-portability.sh` scans this directory at maxdepth 1, so this
# file is linted on arrival.

pin_file() {
  # pin_file <run-dir> — the pin's path. One spelling, so the writer and the
  # three readers cannot disagree about where it is.
  printf '%s' "$1/plugin-pin"
}

pin_read() {
  # pin_read <run-dir> <key> — the value of that `키<TAB>값` line, or empty.
  # An absent pin, an absent key and an empty value are all the same answer at
  # rc 0: every caller here treats "no value" as "not pinned", and an error
  # status would only give them a second way to say it.
  local f v
  f=$(pin_file "$1")
  [ -f "$f" ] || return 0
  v=$(awk -v k="$2" -F'\t' '$1 == k { print $2; exit }' "$f" 2>/dev/null) || v=""
  printf '%s' "$v"
}

pin_plugin_dir() {
  # pin_plugin_dir <run-dir> — the pinned plugin root, or empty.
  pin_read "$1" 'plugin-dir'
}

pin_digest() {
  # pin_digest <dir> — a content digest over every regular file: the per-file
  # digests (which carry the names, so a rename is a change) in `LC_ALL=C` order,
  # hashed again.
  #
  # THE SAME FUNCTION IS USED BY THE WRITER AND BY ANYONE VERIFYING A RESTORE.
  # A second spelling of "hash this tree" is a value that disagrees with the one
  # recorded, and the recorded one is what a restore is checked against.
  local d="$1"
  [ -d "$d" ] || return 0
  ( cd "$d" 2>/dev/null || exit 0
    find . -type f | LC_ALL=C sort | while IFS= read -r f; do shasum -a 256 "$f"; done \
      | shasum -a 256 | cut -d' ' -f1 )
}

pin_hop_target() {
  # pin_hop_target <run-dir> <this-orchestrator-dir> — the orchestrator
  # directory to hop into, on stdout.
  #
  #   rc 0  print the target; the caller `exec`s into it
  #   rc 1  nothing to do — no pin, or this process is ALREADY the copy
  #   rc 2  the pin names a copy that is not there; the caller stops
  #   rc 3  the pin names somewhere that is not this run's copy; the caller stops
  #
  # THE PIN MAY ONLY NAME THIS RUN'S OWN COPY, AND THAT IS A CONFINEMENT AND NOT
  # A TIDINESS CHECK. This function chooses which `gate.sh` executes, and it is
  # consulted before the manifest is validated, before the paths are derived and
  # before the grant is checked — so a pin planted anywhere a caller can point a
  # run directory at would replace the very program that performs all of those
  # checks, and the ledger row, the grading and the cutpoint comparison would go
  # with it. `pin_take` always writes the literal `<run-dir>/plugin/cc-cmds`, so
  # requiring that value back is the whole of the check.
  #
  # COMPARED BY SPELLING FIRST, PHYSICALLY ONLY AS A FALLBACK. The physical
  # comparison needs both sides to exist, and "the copy is gone" is the state rc 2
  # already names; resolving first would fold that distinct, recoverable state
  # into this one and change what its refusal tells the reader to do.
  #
  # THE LOOP GUARD IS rc 1 AND NOT AN ERROR. The copy's own gate re-enters this
  # function on every call, and a target equal to where we already are would be
  # an `exec` into ourselves forever. Compared physically: the run directory sits
  # under `/var` on this platform, which is a symlink, so the two spellings of
  # one directory are different strings.
  local rd="$1" here="$2" pd tp hp ep pp epp
  [ -f "$(pin_file "$rd")" ] || return 1
  pd=$(pin_plugin_dir "$rd")
  [ -n "$pd" ] || return 1
  ep="$rd/plugin/cc-cmds"
  if [ "$pd" != "$ep" ]; then
    pp=$(cd "$pd" 2>/dev/null && pwd -P) || pp=""
    epp=$(cd "$ep" 2>/dev/null && pwd -P) || epp=""
    if [ -z "$pp" ] || [ -z "$epp" ] || [ "$pp" != "$epp" ]; then return 3; fi
  fi
  tp=$(cd "$pd/orchestrator" 2>/dev/null && pwd -P) || tp=""
  hp=$(cd "$here" 2>/dev/null && pwd -P) || hp="$here"
  if [ -n "$tp" ] && [ "$tp" = "$hp" ]; then return 1; fi
  if [ ! -f "$pd/orchestrator/gate.sh" ]; then return 2; fi
  printf '%s' "$pd/orchestrator"
  return 0
}

pin__copy_bracket() {
  # pin__copy_bracket <src> <dst> — `cp -R` between two checks that the source
  # did not move: `index.lock` absent and HEAD unchanged, before and after.
  #
  # Three attempts, then failure. A torn copy is never accepted — measured over
  # 800 concurrent-checkout trials, the bracket admitted 169 copies and none of
  # them were torn — but a fast enough checkout loop can burn all three
  # attempts, and the caller treats that as a hard stop rather than taking the
  # third copy on faith.
  local src="$1" dst="$2" i=0 lock h1 h2 ok
  lock=$(cd "$src" 2>/dev/null && git --no-optional-locks rev-parse --git-path index.lock 2>/dev/null) || lock=""
  if [ -n "$lock" ]; then
    case "$lock" in
      /*) ;;
      *) lock="$src/$lock" ;;
    esac
  fi
  while [ "$i" -lt 3 ]; do
    i=$((i + 1))
    if [ -n "$lock" ] && [ -e "$lock" ]; then
      sleep 1
      continue
    fi
    h1=$(cd "$src" 2>/dev/null && git --no-optional-locks rev-parse HEAD 2>/dev/null) || h1=""
    rm -rf "$dst"
    mkdir -p "$dst" || return 1
    ok=1
    cp -R "$src/." "$dst/" 2>/dev/null || ok=0
    if [ "$ok" = 1 ] && [ -n "$lock" ] && [ -e "$lock" ]; then ok=0; fi
    if [ "$ok" = 1 ]; then
      h2=$(cd "$src" 2>/dev/null && git --no-optional-locks rev-parse HEAD 2>/dev/null) || h2=""
      [ "$h1" = "$h2" ] || ok=0
    fi
    if [ "$ok" = 1 ]; then return 0; fi
    rm -rf "$dst"
  done
  return 1
}

pin_take() {
  # pin_take <run-dir> <src-plugin-dir> — copy the plugin root into the run
  # directory and publish the pin. rc 0 when this run is pinned (by us or by the
  # process that won the race), rc 1 when no untorn copy could be taken.
  local rd="$1" src="$2"
  local tmpdir="$rd/plugin.$$" tmppin="$rd/plugin-pin.$$" dst
  local method commit tree dirty digest ver onorigin top prefix ref waited
  dst="$tmpdir/cc-cmds"

  mkdir -p "$rd" || return 1
  rm -rf "$tmpdir" "$tmppin"

  method=copy; commit='(미상)'; tree='(미상)'; dirty='미상'; onorigin='미상'
  top=""; prefix=""
  if command -v git >/dev/null 2>&1; then
    top=$(cd "$src" 2>/dev/null && git --no-optional-locks rev-parse --show-toplevel 2>/dev/null) || top=""
  fi
  if [ -n "$top" ]; then
    prefix=$(cd "$src" 2>/dev/null && git --no-optional-locks rev-parse --show-prefix 2>/dev/null) || prefix=""
    commit=$(cd "$src" 2>/dev/null && git --no-optional-locks rev-parse HEAD 2>/dev/null) || commit=""
    [ -n "$commit" ] || commit='(미상)'
    # `-- .` SCOPES THE QUESTION TO THE SUBTREE BEING COPIED. A dirty file
    # elsewhere in the repository says nothing about the bytes going into the
    # copy, and treating it as dirty would push every pin onto the slower path.
    if [ -z "$(cd "$src" 2>/dev/null && git --no-optional-locks status --porcelain -- . 2>/dev/null)" ]; then
      dirty='아니오'
    else
      dirty='예'
    fi
    if [ "$commit" != '(미상)' ]; then
      if [ -n "$(cd "$src" 2>/dev/null && git --no-optional-locks branch -r --contains HEAD 2>/dev/null)" ]; then
        onorigin='예'
      else
        onorigin='아니오'
      fi
    fi
    if [ "$dirty" = '아니오' ] && [ "$commit" != '(미상)' ]; then
      if [ -n "$prefix" ]; then ref="HEAD:${prefix%/}"; else ref="HEAD^{tree}"; fi
      tree=$(cd "$src" 2>/dev/null && git --no-optional-locks rev-parse "$ref" 2>/dev/null) || tree=""
      if [ -n "$tree" ]; then
        mkdir -p "$dst" || return 1
        # RUN FROM THE TOP LEVEL, NOT FROM THE SUBTREE. `git archive` applies the
        # current directory's path prefix to whatever tree it is given, so the
        # same command run from `plugins/cc-cmds` looks for `plugins/cc-cmds/`
        # INSIDE that subtree's own tree object and matches nothing. The result
        # was an empty archive, an empty copy, and a pin whose digest agreed with
        # it — a self-consistent record of nothing, which no comparison catches.
        # The emptiness check below is the second half of that repair.
        if ( cd "$top" 2>/dev/null && git --no-optional-locks archive --format=tar "$tree" ) | tar -x -C "$dst" \
           && [ -n "$(ls -A "$dst" 2>/dev/null)" ]; then
          method=archive
        else
          rm -rf "$dst"
          tree='(미상)'
        fi
      else
        tree='(미상)'
      fi
    fi
  fi
  if [ "$method" != archive ]; then
    # A dirty subtree has no tree object naming the bytes we copied, so the
    # field stays `(미상)` rather than pointing at a HEAD the copy is not.
    tree='(미상)'
    if ! pin__copy_bracket "$src" "$dst"; then
      rm -rf "$tmpdir"
      return 1
    fi
  fi

  digest=$(pin_digest "$dst")
  ver=$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$dst/.claude-plugin/plugin.json" 2>/dev/null | sed -n '1p') || ver=""
  [ -n "$ver" ] || ver='(미상)'

  {
    printf 'schema\t1\n'
    printf 'plugin-dir\t%s\n' "$rd/plugin/cc-cmds"
    printf 'source\t%s\n' "$( (cd "$src" 2>/dev/null && pwd -P) || printf '%s' "$src" )"
    printf 'method\t%s\n' "$method"
    printf 'commit\t%s\n' "$commit"
    printf 'tree\t%s\n' "$tree"
    printf 'dirty\t%s\n' "$dirty"
    printf 'digest\t%s\n' "$digest"
    printf 'version\t%s\n' "$ver"
    printf 'pinned-at\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'commit-on-origin\t%s\n' "$onorigin"
  } > "$tmppin" || { rm -rf "$tmpdir" "$tmppin"; return 1; }

  # THE PUBLICATION. A single `link(2)` — the same idiom `gate_end_run` uses to
  # publish `done` — so exactly one of any number of simultaneous openers wins.
  if ln "$tmppin" "$(pin_file "$rd")" 2>/dev/null; then
    # A `plugin/` left by an interrupted open is unreferenced by construction:
    # we just published the only pin, so nothing was hopping into it.
    if [ -e "$rd/plugin" ]; then rm -rf "$rd/plugin"; fi
    mv "$tmpdir" "$rd/plugin" || { rm -rf "$tmpdir"; rm -f "$tmppin"; return 1; }
    rm -f "$tmppin"
    return 0
  fi

  # The losing side. Its copy is complete and correct but unreferenced, so it
  # goes; then it waits for the winner to finish its rename. The wait is what
  # keeps the loser from reporting "pinned, copy missing" during the winner's
  # publish-then-rename window.
  rm -rf "$tmpdir"
  rm -f "$tmppin"
  waited=0
  while [ "$waited" -lt 100 ]; do
    if [ -f "$(pin_plugin_dir "$rd")/orchestrator/gate.sh" ]; then return 0; fi
    sleep 0.1
    waited=$((waited + 1))
  done
  return 1
}
