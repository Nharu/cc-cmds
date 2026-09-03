#!/usr/bin/env bash
# The command and its flag are separated by U+00A0, which a UTF-8 ctype counts
# as space and the C ctype does not. The judgement grep for this table runs
# under the ambient locale, so the candidate pass has to run there too:
# pinning the candidate pass to C alone would let this line through.
date -j -f "%Y-%m-%d" 2000-01-01 +%s
