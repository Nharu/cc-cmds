#!/usr/bin/env bash
# Fixture: every idiom named below appears only inside a comment — a tac here, a
# md5sum there, mapfile and setsid too. Nomination fires on all of these lines
# because it reads the raw text, and judgement has to clear every one of them.
set -euo pipefail

# We deliberately avoid tac and md5sum in the code below.
echo "portable"        # not reaching for mapfile or readarray either
printf '%s\n' "done"   # setsid is a Linux-only binary, so it stays out
