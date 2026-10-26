#!/usr/bin/env bash
# statusline-command.sh — the wrapper grammar, and the only copy of it.
#
# WHY THIS FILE EXISTS. Two processes decide the same question about the same
# string: the SessionStart hook classifies the value it finds in the user's
# settings, and the installer re-derives that classification from its own
# snapshot before it writes. If the two recognisers disagree the hook says
# "proceed" and the installer parks — on every startup, forever, with nothing
# written anywhere to say so. The answer is not a lint holding two copies
# honest; it is one copy that both processes source. This directory already
# works that way: `liveness.sh` is sourced by the gate, the watcher and the
# status line for the same reason.
#
# WHAT LIVES HERE IS DECIDED BY A RULE, NOT BY A LIST. A function belongs in
# this file when the hook and the installer must reach the SAME ANSWER with it.
# A function only one of them calls lives in that one. So the target-settings
# derivation and the cheap front gate are the hook's own and are deliberately
# absent from here — putting them here would create a place the installer could
# call them from, which is the second derivation site the boundary contract
# exists to leave nowhere. The digests, the probe and the verify run are the
# installer's for the mirror-image reason: the hook never computes a digest and
# never runs a verify, so there is no second derivation to diverge.
#
# THE `sl_*` NAMESPACE IS THE CLOSED SET, AND A LINT HOLDS IT CLOSED.
# `scripts/lint-statusline-wrapper-pins.sh` compares the `sl_*` functions
# defined here against its own literal list in BOTH directions, so an eighth
# `sl_*` name added here without touching that list is a red lint, and so is a
# name in the list that has left this file. Private helpers carry a different
# prefix on purpose: they are implementation, not contract, and naming one
# `sl_*` would break the check that keeps the contract honest.
#
# THE RECOGNISER NEVER COMPARES AGAINST OUR OWN PATH. A wrapper aimed at a stale
# plugin cache version is still ours, so it is unwrapped and re-aimed rather
# than demoted into a fallback — which is the whole point of re-pointing after a
# marketplace update. Every predicate below therefore takes the value as an
# argument, and `$SL_PATH` is read only by the three functions that PRODUCE.
#
# Compatibility: bash 3.2 — no associative arrays, no `mapfile`, no `wait -n`.

wrapper_path_ok() {
  # wrapper_path_ok <path> <quoted|bare> — the condition BOTH production rules
  # put on P. One copy, because it is the same condition in both.
  #
  # THE SUFFIX IS TWO SEGMENTS, AND THAT IS THE ENTIRE SAFETY MARGIN of the
  # unguarded rule. The harness documents `~/.claude/statusline.sh` as the
  # conventional place for a hand-written status line, so a one-segment suffix
  # would adopt — and then overwrite — a script the user wrote themselves.
  #
  # A `$`, a backtick or a double quote inside P is expanded at the harness's
  # SECOND evaluation of this string, so a value carrying one is not a value we
  # could have written. In the unquoted alternative a space or a tab is the same
  # kind of evidence: what we once emitted without quotes could not have held
  # one and still have been the single word the guard tested.
  local p="$1" kind="$2" tab
  tab=$'\t'
  case "$p" in /*) ;; *) return 1 ;; esac
  case "$p" in */orchestrator/statusline.sh) ;; *) return 1 ;; esac
  case "$p" in *'$'*)  return 1 ;; esac
  case "$p" in *'`'*)  return 1 ;; esac
  case "$p" in *'"'*)  return 1 ;; esac
  if [ "$kind" = bare ]; then
    case "$p" in *' '*)     return 1 ;; esac
    case "$p" in *"$tab"*)  return 1 ;; esac
  fi
  return 0
}

sl_wrapper_prefix() {
  # sl_wrapper_prefix — the guard prefix that gets installed, from `$SL_PATH`.
  #
  # `exec bash <path>`, never `exec <path>`: the latter depends on the shebang,
  # and a script whose shebang is broken then produces neither output nor
  # fallback — the exact shape this defensive form exists to prevent.
  #
  # THE PATH IS QUOTED INSIDE THE INSTALLED STRING. Unquoted, a plugin directory
  # holding a space makes `[` see too many arguments and fail, which is
  # indistinguishable from "the script is not there": every render silently
  # takes the fallback and the install still looks like a success.
  printf '[ -x "%s" ] && exec bash "%s" || ' "$SL_PATH" "$SL_PATH"
}

sl_unwrap_once() {
  # sl_unwrap_once <value> — print the fallback of exactly ONE guarded layer and
  # return 0, or print nothing and return 1.
  #
  # BOTH `P` OCCURRENCES CARRY THE SUFFIX PIN INDEPENDENTLY, and deriving the
  # second from `p1 = p2` is not the same invariant even though it accepts the
  # same strings today. The value that equality actually protects is the one
  # nobody predicts: a wrapper whose GUARD tests our path while its `exec`
  # target is a third party's binary. Drop the equality and that value is
  # classified as ours, and the third party's exec target is overwritten.
  local v="$1" q='"' midq=' ] && exec bash "' mid=' ] && exec bash ' tail=' || '
  local p1 p2 rest fb

  case "$v" in
    '[ -x "'*)
      rest=${v#'[ -x "'}
      p1=${rest%%"$q"*}
      rest=${rest#"$p1$q"}
      case "$rest" in "$midq"*) ;; *) return 1 ;; esac
      rest=${rest#"$midq"}
      p2=${rest%%"$q"*}
      rest=${rest#"$p2$q"}
      case "$rest" in "$tail"*) ;; *) return 1 ;; esac
      fb=${rest#"$tail"}
      [ "$p1" = "$p2" ] || return 1
      wrapper_path_ok "$p1" quoted || return 1
      printf '%s' "$fb"
      return 0
      ;;
  esac

  # THE LEGACY UNQUOTED WRAPPER IS NORMALISED, NOT PARKED. Parking on it looks
  # safe and is not: it is OUR OWN older output, so parking would leave that
  # guard aimed at a dead path for the life of the machine with no route back.
  case "$v" in
    '[ -x /'*)
      rest=${v#'[ -x '}
      p1=${rest%%"$mid"*}
      [ "$p1" != "$rest" ] || return 1
      rest=${rest#"$p1$mid"}
      p2=${rest%%"$tail"*}
      [ "$p2" != "$rest" ] || return 1
      fb=${rest#"$p2$tail"}
      [ "$p1" = "$p2" ] || return 1
      wrapper_path_ok "$p1" bare || return 1
      printf '%s' "$fb"
      return 0
      ;;
  esac

  return 1
}

sl_unwrap() {
  # sl_unwrap <value> — strip up to EIGHT guarded layers and print the residue.
  #
  # THE CAP DOES NOT PARK. Unwrapping to the cap and re-wrapping once removes
  # seven layers per apply, so a twenty-deep value collapses in three applies
  # and the user's original command comes back byte for byte. Parking at the cap
  # would strand exactly the machines the nesting defect made — the deepest ones.
  local cur="$1" next i=0
  while [ "$i" -lt 8 ]; do
    next=$(sl_unwrap_once "$cur") || break
    cur="$next"
    i=$((i + 1))
  done
  printf '%s' "$cur"
}

sl_is_bare_ours() {
  # sl_is_bare_ours <value> — true when <value>, with surrounding spaces and
  # tabs removed, IS a bare call of our script and nothing else.
  #
  # A GUARDLESS CALL OF OUR SCRIPT IS STILL OURS. The park predicate exists to
  # avoid overwriting SOMEBODY ELSE'S status line, and a value that names our
  # script is not somebody else's.
  #
  # WHOLE-VALUE, NEVER SUBSTRING. This is the one sentence keeping the rule from
  # collapsing into the substring gate that was measured reporting convergence
  # on two different drifted files. A pipe, an argument, an `&&` tail or an
  # environment prefix means the value does something we do not know about, so
  # it parks.
  #
  # IT IS A TERMINAL PREDICATE, NOT A LAYER. The unwrap loop runs first and this
  # is applied to what is left, so the cap and its per-apply collapse are
  # untouched by it.
  local v="$1" q='"' tab p
  tab=$'\t'

  while :; do
    case "$v" in
      ' '*)       v=${v# } ;;
      "$tab"*)    v=${v#"$tab"} ;;
      *' ')       v=${v% } ;;
      *"$tab")    v=${v%"$tab"} ;;
      *)          break ;;
    esac
  done

  case "$v" in 'exec '*) v=${v#'exec '} ;; esac
  case "$v" in
    'bash '*) v=${v#'bash '} ;;
    'sh '*)   v=${v#'sh '} ;;
  esac

  case "$v" in
    "$q"*"$q")
      p=${v#"$q"}
      p=${p%"$q"}
      wrapper_path_ok "$p" quoted || return 1
      ;;
    *)
      wrapper_path_ok "$v" bare || return 1
      ;;
  esac
  return 0
}

sl_classify() {
  # sl_classify <settings-file> — print `empty`, `ours` or `foreign`; return 1
  # when the file exists but cannot be read or parsed.
  #
  # THE THREE TOKENS ARE THE VALUE VOCABULARY THAT CROSSES THE PROCESS BOUNDARY,
  # and this function is their only source. The hook puts what this returns
  # straight onto the installer's `--require-state`, and the installer compares
  # against what this same function returns for its own snapshot — so neither
  # side ever types one of these spellings, and there is nowhere for the two to
  # drift apart. `foreign` never crosses: the hook that sees it does not call the
  # installer at all.
  #
  # AN UNREADABLE FILE IS NOT AN EMPTY ONE. Folded together, a settings file the
  # process cannot read classifies as `empty` and becomes an install target.
  local f="$1" kind cmd

  if [ ! -e "$f" ]; then
    printf 'empty'
    return 0
  fi
  [ -r "$f" ] || return 1

  # A DECLARED TYPE THAT IS NOT `command` IS SOMEBODY ELSE'S STATUS LINE, and an
  # ABSENT type is not a declaration at all — `{}` and `{"type":"command"}` are
  # both the empty shape. Reading absence as "not command" would park the very
  # object this design installs into.
  kind=$(jq -r '
    if (.statusLine // null) == null then "empty"
    elif (.statusLine | type) != "object" then "foreign"
    elif (.statusLine | has("type")) and ((.statusLine.type | tostring) != "command") then "foreign"
    elif (.statusLine | has("command") | not) then "empty"
    elif .statusLine.command == null then "empty"
    elif ((.statusLine.command | type) == "string") and (.statusLine.command | test("^\\s*$")) then "empty"
    else "cmd" end' "$f" 2>/dev/null) || return 1

  case "$kind" in
    empty)   printf 'empty';   return 0 ;;
    foreign) printf 'foreign'; return 0 ;;
    cmd)     ;;
    *)       return 1 ;;
  esac

  cmd=$(jq -r '.statusLine.command' "$f" 2>/dev/null) || return 1

  # One stripped layer is enough to say it is ours, whatever the residue turns
  # out to be; with nothing to strip, the whole value has to be a bare call.
  if sl_unwrap_once "$cmd" >/dev/null 2>&1; then
    printf 'ours'
  elif sl_is_bare_ours "$cmd"; then
    printf 'ours'
  else
    printf 'foreign'
  fi
  return 0
}

sl_desired_command() {
  # sl_desired_command <current-command> — the command line to install.
  #
  # THIS IS THE INVERSE OF THE RECOGNISER, and that is why it sits in the same
  # file. A producer that emitted a shape the recogniser rejects would re-point
  # on one startup and park on the next, forever — the loop this whole file
  # exists to close, reproduced one level up in the grammar.
  local cur="$1" fallback
  fallback=$(sl_unwrap "$cur")

  # A RESIDUE THAT IS ITSELF A BARE CALL OF OURS EMPTIES THE FALLBACK. Left in
  # place it is a dead pointer at an old plugin version riding along forever
  # behind a guard that is true, so nobody ever sees it.
  if sl_is_bare_ours "$fallback"; then
    fallback=""
  fi

  # A RESIDUE HOLDING NOTHING BUT WHITESPACE EMPTIES IT TOO, and this is the one
  # place the producer has to be told what the recogniser already knows: a
  # blank-only command classifies as `empty` above, so carrying those blanks
  # through as a fallback makes the two halves of this file disagree about the
  # same string. What it would emit is `… || ` with only spaces after it, which
  # is not a degraded status line but a parse error — every render on that
  # machine fails, and the install that produced it reported success.
  case "$fallback" in
    *[![:space:]]*) ;;
    *)              fallback="" ;;
  esac

  # AN EMPTY FALLBACK IS A SYNTAX ERROR, not an empty output — `cmd || ` does not
  # parse, so the whole line would fail rather than degrade. `true` is what
  # "print nothing, successfully" spells, which is exactly the nothing that was
  # there before on a machine with no status line.
  [ -n "$fallback" ] || fallback="true"

  printf '%s%s' "$(sl_wrapper_prefix)" "$fallback"
}

sl_render_desired() {
  # sl_render_desired <settings-file> <out-file> — write the settings as they
  # would be after the apply. Used by both modes, which is what lets the probe
  # recognise convergence without guessing at what the apply would produce.
  #
  # `refreshInterval` IS INSERTED HERE AND NOWHERE ELSE. Done outside this
  # function the `.statusLine` subobject the probe hashes would not carry it, so
  # the probe would answer "converged" and the key would never reach a machine
  # that is already installed.
  #
  # `has()` IS A KEY-EXISTENCE TEST, NOT TRUTHINESS. `//=` and `// 10` both
  # overwrite an explicit `null` and an explicit `0`, and `0` is a value a user
  # can legitimately have chosen.
  local src="$1" out="$2" cur cmd
  if [ -f "$src" ]; then
    cur=$(jq -r '.statusLine.command // ""' "$src" 2>/dev/null) || return 1
  else
    # ABSENT FILE MEANS CREATE. The seed is an empty object, so what lands is a
    # file holding the single key this design declares.
    cur=""
    printf '{}\n' > "$out.src" || return 1
    src="$out.src"
  fi
  cmd=$(sl_desired_command "$cur")
  jq --arg c "$cmd" \
     '.statusLine = ((.statusLine // {}) + {type: "command", command: $c})
      | if (.statusLine | has("refreshInterval")) then . else .statusLine.refreshInterval = 10 end' \
     "$src" > "$out" 2>/dev/null || return 1
  [ -s "$out" ] || return 1
  return 0
}
