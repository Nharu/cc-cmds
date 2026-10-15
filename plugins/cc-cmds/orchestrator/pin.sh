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
  # SPELLING IS A FAST REFUSAL; THE PHYSICAL CHECK IS UNCONDITIONAL. A pin whose
  # text differs from the expected literal is answered by the spelling comparison
  # and, failing that, by resolving both sides. But a pin whose text is RIGHT
  # still has to be confined, because the path it names can be diverted by a
  # symlink under the run directory — so the target is resolved and required to
  # sit at the run directory's own physical path in every branch. The physical
  # comparison needs the target to exist, and "the copy is gone" is the state rc 2
  # already names; that state is therefore left to rc 2 rather than folded in
  # here, which would change what the refusal tells the reader to do.
  #
  # THE LOOP GUARD IS rc 1 AND NOT AN ERROR. The copy's own gate re-enters this
  # function on every call, and a target equal to where we already are would be
  # an `exec` into ourselves forever. Compared physically: the run directory sits
  # under `/var` on this platform, which is a symlink, so the two spellings of
  # one directory are different strings.
  local rd="$1" here="$2" pd tp hp ep pp epp rdp
  [ -f "$(pin_file "$rd")" ] || return 1
  pd=$(pin_plugin_dir "$rd")
  [ -n "$pd" ] || return 1
  ep="$rd/plugin/cc-cmds"
  if [ "$pd" != "$ep" ]; then
    pp=$(cd "$pd" 2>/dev/null && pwd -P) || pp=""
    epp=$(cd "$ep" 2>/dev/null && pwd -P) || epp=""
    if [ -z "$pp" ] || [ -z "$epp" ] || [ "$pp" != "$epp" ]; then return 3; fi
  fi
  # THE CONFINEMENT ALSO HOLDS WHEN THE SPELLING IS RIGHT, and that is the branch
  # it was missing. The block above runs only when the pin's text already DIFFERS
  # from the expected literal, so a pin that writes `<run-dir>/plugin/cc-cmds`
  # exactly asked the filesystem nothing — and `<run-dir>/plugin` being a symlink
  # to an outside tree was enough to make the `cd` below follow it, find a
  # `gate.sh` beyond the link, and return rc 0 for bytes that live nowhere near
  # this run. The check was weakest against the attacker it exists to stop: the
  # one who spells the pin correctly.
  #
  # RESOLVING BOTH SIDES WOULD NOT CATCH IT — `pd` and `ep` are the SAME STRING
  # there, so resolving each gives the same answer whatever the link does. The
  # property that actually has to hold is CONTAINMENT: the pin's target must
  # resolve to the run directory's own physical path plus the literal tail. That
  # is derived from `$rd` here rather than from `$ep`, because `$ep` is exactly
  # the path the link diverts.
  #
  # AN ABSENT COPY IS LEFT TO rc 2. `pp` is empty when the target does not exist,
  # and that state is the distinct, recoverable one rc 2 already names below —
  # folding it in here would change what the refusal tells the reader to do.
  rdp=$(cd "$rd" 2>/dev/null && pwd -P) || rdp=""
  [ -n "$rdp" ] || rdp="$rd"
  pp=$(cd "$pd" 2>/dev/null && pwd -P) || pp=""
  if [ -n "$pp" ] && [ "$pp" != "$rdp/plugin/cc-cmds" ]; then return 3; fi
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

pin__fetch_bounded() {
  # pin__fetch_bounded <top> <branch> — fetch one branch of `origin` into its
  # remote-tracking ref, killed after 20 seconds. rc 0 only when the fetch itself
  # succeeded in time.
  #
  # A SHELL WATCHDOG, NOT `timeout(1)`: stock macOS does not ship it. The fetch
  # runs in the background as an `exec`ed subshell, so `$!` is git's own pid; the
  # watchdog sleeps, then sends TERM to git's direct children (the transport
  # helper or ssh a hanging remote is stuck in) and to git. A fetch that ends
  # first has its watchdog taken down with the watchdog's own sleep, so no
  # sleeper outlives the call.
  local top="$1" b="$2" fpid wpid rc limit=20
  ( cd "$top" 2>/dev/null || exit 1
    GIT_TERMINAL_PROMPT=0 exec git fetch --quiet --no-tags origin "+refs/heads/$b:refs/remotes/origin/$b" ) </dev/null >/dev/null 2>&1 &
  fpid=$!
  ( s=""
    trap 'if [ -n "$s" ]; then kill "$s" 2>/dev/null; fi; exit 0' TERM
    sleep "$limit" &
    s=$!
    wait "$s"
    pkill -TERM -P "$fpid" 2>/dev/null
    kill -TERM "$fpid" 2>/dev/null
    exit 0 ) </dev/null >/dev/null 2>&1 &
  wpid=$!
  rc=0
  wait "$fpid" 2>/dev/null || rc=$?
  kill -TERM "$wpid" 2>/dev/null
  wait "$wpid" 2>/dev/null
  return "$rc"
}

pin__overlap() {
  # pin__overlap <top> <branch> — rc 0 when a local change of the working tree
  # (tracked or untracked, anywhere in the repository) is a path the fast-forward
  # to `origin/<branch>` would write. Both sides of a rename are compared, on the
  # status side and on the diff side, so a moved file cannot slip between them.
  local top="$1" b="$2" mine theirs
  mine=$(cd "$top" 2>/dev/null && git --no-optional-locks status --porcelain -z --untracked-files=all 2>/dev/null \
    | tr '\0' '\n' \
    | awk 'skip { print; skip = 0; next } { xy = substr($0, 1, 2); print substr($0, 4); if (xy ~ /[RC]/) skip = 1 }') || mine=""
  [ -n "$mine" ] || return 1
  theirs=$(cd "$top" 2>/dev/null && git --no-optional-locks diff --no-renames --name-only -z HEAD "refs/remotes/origin/$b" 2>/dev/null \
    | tr '\0' '\n') || theirs=""
  [ -n "$theirs" ] || return 1
  # One stream, the merge's paths first and then a separator no path can be,
  # so the comparison needs neither a temporary file nor a second descriptor.
  { printf '%s\n' "$theirs"; printf '\001\n'; printf '%s\n' "$mine"; } \
    | awk 'sep { if ($0 in t) hit = 1; next } $0 == "\001" { sep = 1; next } { t[$0] = 1 } END { exit hit ? 0 : 1 }'
}

pin_sync() {
  # pin_sync <src-plugin-dir> [<targets>] — bring the pin's source up to its
  # remote before the copy is taken. <targets> holds one line per declared
  # target, `<common git dir><TAB><base branch>`. Results are left in globals,
  # because `pin_take` reads several of them and a function cannot return more
  # than a status:
  #
  #   PIN_SYNC_ORIGIN    the `origin-sync` value
  #   PIN_SYNC_BASE      the base branch, or `-`
  #   PIN_SYNC_OCOMMIT   `origin/<base>` after the fetch, or `-`
  #   PIN_SYNC_REFUSED   why the checkout was not fast-forwarded, or `-`
  #   PIN_SYNC_DIFFERS   whether the subtree differed from the remote before the
  #                      fast-forward (`예` / `아니오`), or `-`
  #   PIN_SYNC_REMOTE    1 when the caller must pin the remote tip tree instead of
  #                      the checkout
  #
  # NO BRANCH OF THIS FUNCTION FAILS THE PIN AND NONE OF THEM RETRIES. A failed
  # or slow fetch falls back to pinning the local HEAD, and a fast-forward that
  # cannot be made falls back to pinning the remote tip tree; the run opens
  # either way and the record says which happened. The only ways `pin_take`
  # itself fails are still the copy bracket and the publication.
  #
  # TWO RUNS OPENING AT ONCE DO NOT QUEUE HERE. git's ref and index locks fail at
  # once instead of waiting, so the loser of a ref-lock race lands on `fetch 실패`
  # and the loser of an index-lock race on `ff-refused=ff 실패`. No lock of our
  # own is added: both fallbacks are correct pins.
  #
  # THE FAST-FORWARD NEVER DISCARDS A PERSON'S WORK. It runs only on the base
  # branch, only when HEAD is an ancestor of the remote, only with `--ff-only`,
  # and only when no local change sits on a path the merge would write; that
  # overlap is measured before the merge rather than read back from git's refusal
  # text, so an overwrite refusal (`충돌 변경`) and a lock race (`ff 실패`) are
  # told apart.
  #
  # `CC_GATE_PIN_SYNC_DISABLE=1` IS A TEST SEAM. A test harness opens runs with
  # the repository's own gate, and without the seam every such run would fetch
  # the real `origin` and might pin the remote tip — testing code that is not the
  # checkout. With it set, nothing below runs: no fetch, no fast-forward, no
  # remote pin, and the pin is taken from the checkout as before.
  local src="$1" targets="${2:-}" top prefix cg cgp line tcg tb tcgp b cur
  PIN_SYNC_ORIGIN='-'; PIN_SYNC_BASE='-'; PIN_SYNC_OCOMMIT='-'
  PIN_SYNC_REFUSED='-'; PIN_SYNC_DIFFERS='-'; PIN_SYNC_REMOTE=0
  if [ "${CC_GATE_PIN_SYNC_DISABLE:-0}" = "1" ]; then
    PIN_SYNC_ORIGIN='시험 봉합'
    return 0
  fi

  top=""
  if command -v git >/dev/null 2>&1; then
    top=$(cd "$src" 2>/dev/null && git --no-optional-locks rev-parse --show-toplevel 2>/dev/null) || top=""
  fi
  if [ -z "$top" ]; then
    PIN_SYNC_ORIGIN='비git'
    return 0
  fi
  prefix=$(cd "$src" 2>/dev/null && git --no-optional-locks rev-parse --show-prefix 2>/dev/null) || prefix=""

  # The base branch: the declared one when this repository is a declared
  # target, compared by physical path because git prints the common directory
  # as it stored it; otherwise whatever `origin/HEAD` names.
  b=""
  cg=$(cd "$src" 2>/dev/null && git --no-optional-locks rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || cg=""
  cgp=$(cd "$cg" 2>/dev/null && pwd -P) || cgp=""
  if [ -n "$cgp" ] && [ -n "$targets" ]; then
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      tcg=$(printf '%s' "$line" | cut -f1)
      tb=$(printf '%s' "$line" | cut -f2)
      case "$tb" in ''|'(없음)') continue ;; esac
      tcgp=$(cd "$tcg" 2>/dev/null && pwd -P) || tcgp=""
      if [ "$tcg" = "$cg" ] || { [ -n "$tcgp" ] && [ "$tcgp" = "$cgp" ]; }; then
        b="$tb"
        break
      fi
    done <<EOF
$targets
EOF
  fi
  if [ -z "$b" ]; then
    b=$(cd "$top" 2>/dev/null && git --no-optional-locks symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null) || b=""
    b="${b#refs/remotes/origin/}"
  fi
  if [ -z "$b" ]; then
    PIN_SYNC_ORIGIN='베이스 미상'
    return 0
  fi
  PIN_SYNC_BASE="$b"

  if ! pin__fetch_bounded "$top" "$b"; then
    PIN_SYNC_ORIGIN='fetch 실패'
    return 0
  fi
  PIN_SYNC_OCOMMIT=$(cd "$top" 2>/dev/null && git --no-optional-locks rev-parse --verify --quiet "refs/remotes/origin/$b^{commit}" 2>/dev/null) || PIN_SYNC_OCOMMIT=""
  if [ -z "$PIN_SYNC_OCOMMIT" ]; then
    PIN_SYNC_OCOMMIT='-'
    PIN_SYNC_ORIGIN='fetch 실패'
    return 0
  fi
  # The #752 measure: did the bytes this pin copies differ from the remote,
  # taken before the fast-forward can make them equal.
  if ( cd "$top" 2>/dev/null && git --no-optional-locks diff --quiet HEAD "refs/remotes/origin/$b" -- ${prefix:+"$prefix"} ) >/dev/null 2>&1; then
    PIN_SYNC_DIFFERS='아니오'
  else
    PIN_SYNC_DIFFERS='예'
  fi

  cur=$(cd "$top" 2>/dev/null && git --no-optional-locks symbolic-ref --quiet --short HEAD 2>/dev/null) || cur=""
  if [ "$cur" != "$b" ]; then
    PIN_SYNC_REFUSED='다른 브랜치'
  elif [ "$(cd "$top" 2>/dev/null && git --no-optional-locks rev-parse HEAD 2>/dev/null)" = "$PIN_SYNC_OCOMMIT" ]; then
    PIN_SYNC_ORIGIN='최신'
    return 0
  elif ! ( cd "$top" 2>/dev/null && git --no-optional-locks merge-base --is-ancestor HEAD "refs/remotes/origin/$b" ) >/dev/null 2>&1; then
    PIN_SYNC_REFUSED='로컬 커밋'
  elif pin__overlap "$top" "$b"; then
    PIN_SYNC_REFUSED='충돌 변경'
  elif ( cd "$top" 2>/dev/null && GIT_TERMINAL_PROMPT=0 git merge --ff-only --quiet "refs/remotes/origin/$b" ) </dev/null >/dev/null 2>&1; then
    PIN_SYNC_ORIGIN='ff'
    return 0
  else
    PIN_SYNC_REFUSED='ff 실패'
  fi
  PIN_SYNC_ORIGIN='원격 끝'
  PIN_SYNC_REMOTE=1
  return 0
}

pin_take() {
  # pin_take <run-dir> <src-plugin-dir> [<targets>] — copy the plugin root into
  # the run directory and publish the pin. rc 0 when this run is pinned (by us or
  # by the process that won the race), rc 1 when no untorn copy could be taken.
  # <targets> is passed through to `pin_sync`, which runs once, before the copy.
  local rd="$1" src="$2" targets="${3:-}"
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
  pin_sync "$src" "$targets"
  if [ -n "$top" ] && [ "$PIN_SYNC_REMOTE" = 1 ]; then
    # THE REMOTE TIP TREE, TAKEN WITHOUT TOUCHING THE CHECKOUT. The checkout could
    # not be fast-forwarded, so the pin names the remote's commit and the
    # remote's subtree, and the bytes are exactly that tree object — the morning
    # report's `git archive <판본 트리>` reproduces them as it does for `archive`.
    # The checkout's own HEAD went into nothing, so no key carries it;
    # `ff-refused` says why.
    prefix=$(cd "$src" 2>/dev/null && git --no-optional-locks rev-parse --show-prefix 2>/dev/null) || prefix=""
    if [ -n "$prefix" ]; then ref="refs/remotes/origin/$PIN_SYNC_BASE:${prefix%/}"; else ref="refs/remotes/origin/$PIN_SYNC_BASE^{tree}"; fi
    tree=$(cd "$top" 2>/dev/null && git --no-optional-locks rev-parse --verify --quiet "$ref" 2>/dev/null) || tree=""
    if [ -n "$tree" ]; then
      mkdir -p "$dst" || return 1
      if ( cd "$top" 2>/dev/null && git --no-optional-locks archive --format=tar "$tree" ) | tar -x -C "$dst" \
         && [ -n "$(ls -A "$dst" 2>/dev/null)" ]; then
        method=archive-remote; commit="$PIN_SYNC_OCOMMIT"; dirty='아니오'; onorigin='예'
      else
        rm -rf "$dst"
        tree=""
      fi
    fi
    if [ -z "$tree" ]; then
      # The remote tip has no such subtree, or it could not be extracted: the
      # pin falls back to the local HEAD exactly as a failed fetch does, and is
      # recorded as one.
      tree='(미상)'
      PIN_SYNC_ORIGIN='fetch 실패'; PIN_SYNC_REMOTE=0
    fi
  fi
  if [ -n "$top" ] && [ "$method" != archive-remote ]; then
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
  if [ "$method" = copy ]; then
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
    printf 'origin-sync\t%s\n' "$PIN_SYNC_ORIGIN"
    printf 'base-branch\t%s\n' "$PIN_SYNC_BASE"
    printf 'origin-commit\t%s\n' "$PIN_SYNC_OCOMMIT"
    printf 'ff-refused\t%s\n' "$PIN_SYNC_REFUSED"
    printf 'subtree-differs\t%s\n' "$PIN_SYNC_DIFFERS"
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
