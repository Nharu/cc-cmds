#!/usr/bin/env bash
# statusline-pre-apply-command.sh — the status line command this design
# REPLACES, kept in the repository so the byte-identity claim has a referent on
# every machine that runs the suite.
#
# WHY THE INSTALL TARGET CANNOT BE THE PRIMARY REFERENCE. It lives in a
# developer's home directory and is absent on the CI runner. A suite that read
# its reference only from there degrades on CI to comparing the status line
# against its own output — and the one defect the reference exists to catch, the
# colour escapes going missing from `emit_fallback`, then passes green on the
# very commit that fixed it. The reading from the install target is still made,
# on top of this one, wherever that file is there to read.
#
# THIS IS NOT THE TRANSCRIPTION THAT FAILED BEFORE. That one was a constant
# typed inline in a test, invisible in review and drifting silently. This is a
# committed file whose only content is the command, so changing it is a diff
# somebody has to justify, and the case that compares it against what is
# actually installed is what would notice it drifting away from the machine it
# describes.
#
# THE BYTES ARE THE CONTRACT. `emit_fallback` in `statusline.sh` must produce
# exactly what this line produces — the escapes, the emoji, and the `%s` the
# format string ends at, with no trailing newline. The wrapper the apply
# installs keeps the original command as its `||` fallback, so on a machine where
# THIS was the original command a session with no run renders the same bytes
# whichever branch it takes.
#
# THAT IS A CLAIM ABOUT ONE POPULATION, NOT ABOUT EVERY MACHINE. Where the apply
# finds no status line at all there is no original command to keep, the fallback
# becomes `true`, and the two branches then differ by this whole line — which is
# what gives the installer's pre-commit verify run something to read on a first
# install. This file is the referent the identity claim needs; it is not evidence
# that the claim holds everywhere.
printf '\033[36m[cc🎨]\033[0m %s' "${PWD##*/}"
