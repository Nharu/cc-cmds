#!/usr/bin/env bash
# Fixture: the baseline still lists a line that was fixed. The listed hit that
# remains is taken by its entry; the entry for the fixed line is what fails.
now=$(date -u +%s)
soon=$((now + 5))
echo "$soon $(date -u +%s)"
