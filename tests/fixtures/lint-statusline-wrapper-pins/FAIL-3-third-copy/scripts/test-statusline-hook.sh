#!/usr/bin/env bash
# The failure this check exists for: a third file that writes the grammar out by
# hand instead of sourcing it, which is a second answer waiting to happen.
value="[ -x \"$SL\" ] && exec bash \"$SL\" || true"
