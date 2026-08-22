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
#   WHICH LINTS MAY STRIP AT ALL — the direction of the assertion decides, and
#   getting this backwards is a live way to open an escape while believing you
#   closed one.
#     * A lint asserting PRESENCE ("this contract still says X") must strip.
#       Without it, a section commented out reads as present and the lint reports
#       the thing it guards intact while the thing it guards is gone.
#     * A lint asserting ABSENCE ("no skill tells a user to touch this path")
#       must NOT strip. Blanking can only ever remove evidence of a violation, so
#       stripping hands every banned string a hiding place. Measured directly: a
#       banned path inside an HTML comment is caught today and stops being caught
#       the moment that lint is given a blanked copy. And the file the model
#       reads includes the comments, so a violation there is a real violation.
#     * The sidecar schema lint is neither, and shows why the rule is stated by
#       assertion direction rather than by lint: the literals it pins ARE
#       comments, so it strips for SECTION RECOGNITION and reads raw for
#       everything else.
#   A measurement that wraps a region holding none of the thing under test is
#   vacuous and must not be read as "defeated" — that is how this rule was
#   nearly written the wrong way round.
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
  local file="$1" key out src
  if [[ ! -f "$file" ]]; then
    printf '%s\n' "$file"
    return 0
  fi

  # THE CACHE KEY IS FIXED-LENGTH, and it was not. Spelling the key as the full
  # path with separators substituted made the file name grow with the checkout
  # root: past roughly 118 bytes of root the name exceeds NAME_MAX, the write
  # fails, and every consumer then greps a file that does not exist — producing
  # false content-deletion diagnostics that name innocent literals. Reproduced
  # directly. A checksum of the path is constant width, and the basename is kept
  # only so a human looking in the scratch directory can tell the files apart.
  key=$(printf '%s' "$file" | cksum | awk '{print $1}')
  out="$CC_STRIP_DIR/${key}-$(basename "$file")"
  src="$out.src"

  # A checksum can collide, and a collision would silently hand back another
  # file's contents — the one failure mode worse than the one just fixed. The
  # source path is recorded beside the copy and verified on every cache hit, so
  # a collision fails loudly instead.
  if [[ -f "$out" && -f "$src" ]]; then
    if [[ "$(cat "$src")" == "$file" ]]; then
      printf '%s\n' "$out"
      return 0
    fi
    echo "FAIL: strip cache key collision between '$(cat "$src")' and '$file'; the blanked copy would have been the wrong file's" >&2
    return 1
  fi

  # THE WRITE IS CHECKED. An unchecked redirection that fails leaves the caller
  # holding a path to nothing, and the diagnostics that follow blame the content
  # rather than the write.
  if ! strip_html_comments < "$file" > "$out"; then
    echo "FAIL: could not write the comment-blanked copy of '$file' to '$out'" >&2
    return 1
  fi
  printf '%s' "$file" > "$src"
  printf '%s\n' "$out"
}
