#!/usr/bin/env bash
#
# cc-team-witness-publish.sh — publish one team member's witness, as ONE act.
#
# A member writes its whole round product, ending in the sentinel line
# `<!-- cc-witness: {role-slug} {round/phase} complete {nonce} -->`, with the
# file edit tool into a hidden draft beside the witness, then runs this once as
# its final action. The draft and the witness are names in the same witness
# directory, so they are on the same file system.
#
# Usage:  <plugin root>/orchestrator/cc-team-witness-publish.sh <draft> <witness>
#
#   <witness>  `${scratchDir}/{role-slug}.{round/phase}.md`
#   <draft>    `${scratchDir}/.{role-slug}.{round/phase}.<16 hex>` — the same
#              directory string, a leading dot and no `.md`, so the witness key
#              listing never picks it up
#
# INVOKED DIRECTLY, NEVER AS `bash <this script>`, for the reason
# `cc-team-witness-init.sh` gives: the gate grades this name as argv0
# (`트리밖쓰기`), and an interpreter in front puts `bash` there instead. The file
# ships mode 755 with the shebang above.
#
# WHAT IT DOES, in this order, and the first matching line of the table below
# decides how it ends:
#
#   1. The witness name is `{role-slug}.{round/phase}.md`, the draft is
#      `.{role-slug}.{round/phase}.<16 hex>` in the same directory string, and
#      that directory's name begins with `cc-team-witness-`. Then the directory
#      is folded to its physical path (`cd -P` and `pwd -P`); that physical name
#      also begins with `cc-team-witness-`, and its parent equals one of the two
#      witness roots folded the same way — `CC_PIPELINE_RUN_DIR` when it is set,
#      or `${XDG_STATE_HOME:-$HOME/.local/state}/cc-cmds/design`. Those are the
#      two places `cc-team-witness-init.sh` makes a witness directory, and the
#      gate's grade for this name (`트리밖쓰기`, a write inside a witness
#      directory) rests on that location, so the helper that takes the grade
#      checks it. A second root that is not absolute is not compared, as the
#      initializer refuses a relative root. A directory that cannot be folded
#      matches no root.
#   2. The draft name exists, and 3. it is a regular file and not a symbolic
#      link — `ln` with no option follows a symlinked source and links its
#      target, so this is what ties the published content to the draft itself.
#   4. The draft's last non-empty line is the sentinel of the witness's role
#      and round, and its nonce is `<round/phase>:<16 hex>`.
#   5. `ln <draft> <witness>`. Making a link fails when the target exists, so an
#      already published witness is never overwritten. On success the draft
#      name is removed; the content stays under the witness name.
#
#   | line | state                                              | exit | line printed                  |
#   | ---- | -------------------------------------------------- | ---- | ----------------------------- |
#   | 1    | a name is not of the shape in 1, or the directory  | 2    | 어긋난 이름                   |
#   |      | is not under a witness root (not foldable too)     |      |                               |
#   | 2    | the draft name does not exist                      | 2    | 초안 없음                     |
#   | 3    | the draft is a symlink or not a regular file       | 2    | 초안이 일반 파일이 아님       |
#   | 4    | the sentinel or the nonce does not match           | 2    | 센티널 어긋남 — <what>        |
#   | 5    | `ln` succeeds and removing the draft name succeeds | 0    | 게시됨                        |
#   | 6    | `ln` succeeds and removing the draft name fails    | 0    | 게시됨, 초안 이름 남음        |
#   | 7    | `ln` fails; the witness is a regular file whose    | 0    | 이미 게시됨(같은 nonce)       |
#   |      | last non-empty line is the draft's own sentinel    |      |                               |
#   | 8    | `ln` fails; the witness exists but is not line 7   | 3    | 이미 게시됨(다른 nonce)       |
#   | 9    | `ln` fails and there is no witness name            | 4    | ln 실패 — <cause>             |
#
# A line for exit 0 goes to standard output, any other to standard error, and
# every line is followed by ` — <path>` or the cause. Line 9 does not fall back
# to `mv`: a file system that cannot make a hard link is reported, not worked
# around with a rename that could overwrite. Lines 7 and 8 leave the draft in
# place, and the cleanup step removes the witness directory whole.
#
# A WITNESS NAME THAT IS A DIRECTORY OR A SYMBOLIC LINK IS LINE 8 WITHOUT RUNNING
# `ln`, because `ln <src> <dir>` does not fail — it makes the link inside that
# directory (and through a symlink to one), which would report a publish that
# never reached the witness name.
#
# `.attempt` is not read: `cc-team-witness-init.sh` writes it only when a stage
# id is set, so an interactive team's witness directory has none.
#
# Environment:
#   CC_PIPELINE_RUN_DIR  — the first witness root, when set and not empty.
#   XDG_STATE_HOME       — the second witness root is
#                          <XDG_STATE_HOME>/cc-cmds/design, defaulting to
#                          $HOME/.local/state; not compared when not absolute.

set -uo pipefail

ME='cc-team-witness-publish.sh'
say_ok()  { printf '%s\n' "$1"; exit 0; }
say_bad() { printf '%s: %s\n' "$ME" "$1" >&2; exit "$2"; }

last_nonempty() {
  # The file's last line holding a non-blank character, printed without its
  # newline. Trailing blank lines and newlines are stripped before comparing,
  # as the protocol's witness predicate does.
  awk 'NF { l = $0 } END { printf "%s", l }' "$1" 2>/dev/null
}

[ "$#" -eq 2 ] || say_bad "어긋난 이름 — 사용법: $ME <초안> <증인>" 2
draft=$1
witness=$2

# Line 1 — the names. `{role-slug}` and `{round/phase}` are one token each, of
# the character set `cc-team-nonce.sh` accepts, so the key splits at its one dot.
wbase=${witness##*/}
dbase=${draft##*/}
case "$witness" in */*) wdir=${witness%/*} ;; *) wdir=. ;; esac
case "$draft" in */*) ddir=${draft%/*} ;; *) ddir=. ;; esac
key=${wbase%.md}
role=${key%%.*}
round=${key#*.}
valid_tok() {
  case "$1" in ''|*[!A-Za-z0-9_-]*) return 1 ;; esac
  return 0
}
if [ "$wbase" = "$key" ] || [ "$role" = "$key" ] \
   || ! valid_tok "$role" || ! valid_tok "$round"; then
  say_bad "어긋난 이름 — 증인 이름이 {role-slug}.{round/phase}.md 꼴이 아니다: $witness" 2
fi
dtok=${dbase#".$key."}
if [ "$dtok" = "$dbase" ] || [ "${#dtok}" -ne 16 ]; then
  say_bad "어긋난 이름 — 초안 이름이 .$key.<16자 16진수> 꼴이 아니다: $draft" 2
fi
case "$dtok" in *[!0-9a-f]*)
  say_bad "어긋난 이름 — 초안 이름이 .$key.<16자 16진수> 꼴이 아니다: $draft" 2 ;;
esac
[ "$ddir" = "$wdir" ] \
  || say_bad "어긋난 이름 — 초안과 증인이 같은 디렉터리가 아니다: $ddir / $wdir" 2
case "${wdir##*/}" in
  cc-team-witness-*) ;;
  *) say_bad "어긋난 이름 — 디렉터리 이름이 cc-team-witness- 로 시작하지 않는다: $wdir" 2 ;;
esac

# Line 1, the location. Every path is folded to its physical form before it is
# compared, so a root reached through a symbolic link still matches and a
# witness directory that is itself a link to somewhere else does not.
phys_dir() {
  # The physical path of an existing directory; fails for anything else.
  [ -n "$1" ] || return 1
  (CDPATH='' cd -P -- "$1" 2>/dev/null && pwd -P)
}
not_under_root() {
  say_bad "어긋난 이름 — 증인 디렉터리가 증인 루트 아래가 아니다: $wdir" 2
}
pwdir=$(phys_dir "$wdir") || not_under_root
case "${pwdir##*/}" in cc-team-witness-*) ;; *) not_under_root ;; esac
pparent=${pwdir%/*}
[ -n "$pparent" ] || pparent=/
under_root=no
if [ -n "${CC_PIPELINE_RUN_DIR:-}" ] && proot=$(phys_dir "$CC_PIPELINE_RUN_DIR") \
   && [ "$proot" = "$pparent" ]; then
  under_root=yes
fi
if [ -n "${XDG_STATE_HOME:-}" ]; then
  xbase=$XDG_STATE_HOME
elif [ -n "${HOME:-}" ]; then
  xbase=$HOME/.local/state
else
  xbase=
fi
case "$xbase" in
  /*)
    if proot=$(phys_dir "$xbase/cc-cmds/design") && [ "$proot" = "$pparent" ]; then
      under_root=yes
    fi ;;
esac
[ "$under_root" = yes ] || not_under_root

# Lines 2 and 3 — the draft itself. `-e` is false for a dangling link, so the
# link test comes first in the order that reports a link as a link.
if [ ! -e "$draft" ] && [ ! -L "$draft" ]; then
  say_bad "초안 없음 — $draft" 2
fi
if [ -L "$draft" ] || [ ! -f "$draft" ]; then
  say_bad "초안이 일반 파일이 아님 — $draft" 2
fi

# Line 4 — the sentinel. The nonce's tag is the witness's round token.
sentinel=$(last_nonempty "$draft")
nonce=${sentinel#"<!-- cc-witness: $role $round complete "}
if [ "$nonce" = "$sentinel" ] || [ "${nonce% -->}" = "$nonce" ]; then
  say_bad "센티널 어긋남 — 마지막 비지 않은 줄이 <!-- cc-witness: $role $round complete <nonce> --> 가 아니다: $draft" 2
fi
nonce=${nonce% -->}
nhex=${nonce#"$round:"}
if [ "$nhex" = "$nonce" ] || [ "${#nhex}" -ne 16 ]; then
  say_bad "센티널 어긋남 — nonce 가 $round:<16자 16진수> 꼴이 아니다: $nonce" 2
fi
case "$nhex" in *[!0-9a-f]*)
  say_bad "센티널 어긋남 — nonce 가 $round:<16자 16진수> 꼴이 아니다: $nonce" 2 ;;
esac

already_published() {
  # Lines 7 and 8, read off the witness name as it stands.
  if [ -f "$witness" ] && [ ! -L "$witness" ] \
     && [ "$(last_nonempty "$witness")" = "$sentinel" ]; then
    say_ok "이미 게시됨(같은 nonce) — $witness"
  fi
  say_bad "이미 게시됨(다른 nonce) — $witness" 3
}

if [ -L "$witness" ] || [ -d "$witness" ]; then
  already_published
fi

# Line 5 onward — the link is the publish.
if err=$(ln "$draft" "$witness" 2>&1); then
  if rm "$draft" 2>/dev/null; then
    say_ok "게시됨 — $witness"
  fi
  say_ok "게시됨, 초안 이름 남음 — $witness"
fi
if [ -e "$witness" ] || [ -L "$witness" ]; then
  already_published
fi
err=${err%%$'\n'*}
say_bad "ln 실패 — ${err:-원인 미상}" 4
