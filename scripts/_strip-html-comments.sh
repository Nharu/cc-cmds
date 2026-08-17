#!/usr/bin/env bash
# Shared HTML-comment blanker, and the pre-stripped copy that region-scoped pins
# have to read instead of the original file.
#
# WHY A PRE-STRIPPED COPY AND NOT A STRIP INSIDE THE EXTRACTOR.
#   An editor removing a section usually comments it out rather than deleting it.
#   Those two acts are byte-different and reader-identical, so a pin over raw
#   bytes reports the shipped contract intact while the shipped contract is gone.
#   Blanking the comments before asserting is what closes that.
#
#   Doing it on the extractor's OUTPUT does not close it, and the reason is
#   structural rather than a coverage gap: `extract_between` excludes the start
#   line by construction, so a `<!--` opened ABOVE a region's start anchor is cut
#   away from the returned text. A state machine that enters comment state on
#   seeing `<!--` therefore never enters it, and the whole region reads as
#   ordinary prose while sitting inside a comment. Measured at two call sites,
#   one of which reverted the very contract its fence exists to protect and still
#   exited 0. Comment state does not survive excision — only stripping the file
#   FIRST closes the class, and enumerating more literals never does.
#
#   The strip is deliberately NOT inside `extract_between`. Two ANCHOR PAIRS are
#   themselves HTML comments — the disclosure block's two fences, and the
#   reference file-end sentinel that terminates a last section — and a blanked
#   copy leaves those anchors with nothing to match. The unit is the anchor pair
#   rather than the call site, and the difference is not pedantry: one of the two
#   is a single entry of a loop that carries three, so an exception taken at
#   call-site granularity would have made the other two entries comment-blind for
#   no reason. Those pairs read the raw file and stay comment-blind; that is a
#   forced exception, not a preference, and each is visible where it is taken as
#   a raw path argument rather than being counted somewhere else. A bare "there
#   are two exceptions" is how two missing sites survived two rounds.
#
#   WHAT THIS DOES NOT REACH. A lint that never calls the extractor is untouched
#   by any of this: it reads whole files, so its own assertions have to strip for
#   themselves. Landing the extractor fix and reporting the class closed would
#   therefore be wrong, and it would be green.
#
# LINE COUNT IS PRESERVED. A commented line becomes empty rather than
# disappearing, so a span floor still counts what a reader would see and a
# diagnostic still points at the right place.
#
# Usage:
#   source scripts/_strip-html-comments.sh
#   strip_html_comments < file          # stdin -> stdout
#   path=$(stripped_copy "$file")       # path to a comment-blanked copy

# The scratch directory is created ONCE, here, at source time. `stripped_copy`
# is called from inside command substitutions — it supplies `extract_between`'s
# file argument — so anything it caches in a shell variable dies with that
# subshell. The filesystem is the only cache that crosses the boundary, and the
# directory it writes into therefore has to exist before the first subshell runs.
CC_STRIP_DIR="${CC_STRIP_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/cc-strip.XXXXXX")}"
trap 'rm -rf "$CC_STRIP_DIR"' EXIT

strip_html_comments() {
  awk '
    {
      line = $0
      out = ""
      while (1) {
        if (incmt) {
          p = index(line, "-->")
          if (p == 0) { line = ""; break }
          incmt = 0
          line = substr(line, p + 3)
          continue
        }
        p = index(line, "<!--")
        if (p == 0) { out = out line; line = "" ; break }
        out = out substr(line, 1, p - 1)
        line = substr(line, p + 4)
        incmt = 1
      }
      print out
    }
  '
}

# stripped_copy <file> — print the path of a comment-blanked copy of <file>.
#
# A file that does not exist is echoed back unchanged so the caller's own
# not-found diagnostic still names the path the caller asked for. Materializing
# an empty stand-in would turn "file missing" into "anchor missing", which is a
# worse diagnostic for the same failure.
stripped_copy() {
  local file="$1" out
  if [[ ! -f "$file" ]]; then
    printf '%s\n' "$file"
    return 0
  fi
  out="$CC_STRIP_DIR/$(printf '%s' "$file" | tr '/' '%')"
  if [[ ! -f "$out" ]]; then
    strip_html_comments < "$file" > "$out"
  fi
  printf '%s\n' "$out"
}
