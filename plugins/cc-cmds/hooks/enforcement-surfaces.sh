#!/usr/bin/env bash
#
# enforcement-surfaces.sh — the one classifier of the target tree's
# enforcement surfaces.
#
# The run hook refuses four suffix arms on an edit tool's path — project-scope
# settings, session transcripts, the rule catalog and the CLAUDE.md family —
# and those arms used to live only inside the hook's own `case`. Nothing else
# could ask the same question: kickoff, the design freeze and the segment plan
# never compared a goal or a declared file set with the arms, so a slice that
# needed one of those edits ran straight into the refusal at implementation
# time. This file is where the arms live now, and every reader sources it —
# the hook from its own directory, the gate and the driver from their pinned
# copy, the screening tool from the installation. Two copies of a glob list
# are two lists that drift, and a screen that judges differently from the
# hook that enforces misleads the person reading it.
#
# THE HOOK IS THE REFERENCE, NOT THIS FILE'S READERS. A differential test
# drives the real hook as a black box over a path corpus and compares its
# verdict with `es_class`; the arms below keep the hook's order and spelling,
# case-sensitive matching and the two exact settings names included.
#
# NO OVERRIDE INPUT. No environment variable, argument list or file read
# changes what is classified: a classifier a caller can steer is one a stage
# can steer. A reader that cannot source this file refuses rather than
# assuming "no surface".
#
# Compatibility: bash 3.2, no external process (and so no git) — the hook
# sources this on every edit call.

# es_class <spelling> — print the class token of one spelling, or nothing.
# Returns 0 when classified, 1 otherwise. The arms are matched against the
# spelling as given: callers holding a repository-relative path pass "/$p" so
# that the `*/…` globs see a leading separator, exactly as the hook sees an
# absolute path.
es_class() {
  case "$1" in
    */.claude/settings.json|*/.claude/settings.local.json)
      printf '%s\n' '프로젝트설정' ;;
    */.claude/projects/*|*/transcripts/*)
      printf '%s\n' '트랜스크립트' ;;
    */orchestrator/rules/*)
      printf '%s\n' '규칙카탈로그' ;;
    */CLAUDE.md|CLAUDE.md|*/CLAUDE.local.md|CLAUDE.local.md)
      printf '%s\n' '지침파일' ;;
    *) return 1 ;;
  esac
  return 0
}

# es_class_list — one line per glob: `<token>\t<glob>\t<deny|reroute>`, in the
# order `es_class` tries them. This is the data a kickoff prompt reads instead
# of a closed list written into its prose.
es_class_list() {
  printf '%s\t%s\t%s\n' \
    '프로젝트설정' '*/.claude/settings.json' deny \
    '프로젝트설정' '*/.claude/settings.local.json' deny \
    '트랜스크립트' '*/.claude/projects/*' deny \
    '트랜스크립트' '*/transcripts/*' deny \
    '규칙카탈로그' '*/orchestrator/rules/*' deny \
    '지침파일' '*/CLAUDE.md' reroute \
    '지침파일' 'CLAUDE.md' reroute \
    '지침파일' '*/CLAUDE.local.md' reroute \
    '지침파일' 'CLAUDE.local.md' reroute
}

# es_seat_applicable_class <token> — true for the classes the seat may commit
# to a segment branch: a file a review can see as a commit. Whether a given
# path of that class is tracked and not ignored is the gate's to judge per path.
es_seat_applicable_class() {
  case "$1" in
    '규칙카탈로그'|'지침파일') return 0 ;;
  esac
  return 1
}

# es_class_command <command line> — print `<token>\t<class>` for every token of
# the line that classifies, and return 0 when at least one did. A token is a
# blank-separated word with its quotes removed; when it carries `=`, the value
# after the first `=` is tried as well. Each candidate is tried as written and
# with a leading `/`, so a relative `plugins/cc-cmds/orchestrator/rules/x.sh` or
# a bare `CLAUDE.md` meets the `*/…` arms. This is a string check: a command
# that runs a script whose body writes a classified path passes it.
es_class_command() {
  local line="$1" tok cand c found=1 had_f=0 oldifs="$IFS"
  case "$-" in *f*) had_f=1 ;; esac
  set -f
  IFS=$' \t\n'
  for tok in $line; do
    tok="${tok//\"/}"
    tok="${tok//\'/}"
    [ -n "$tok" ] || continue
    for cand in "$tok" "${tok#*=}"; do
      [ -n "$cand" ] || continue
      if c=$(es_class "$cand") || c=$(es_class "/$cand"); then
        printf '%s\t%s\n' "$tok" "$c"
        found=0
        break
      fi
    done
  done
  IFS="$oldifs"
  [ "$had_f" = 1 ] || set +f
  return "$found"
}
