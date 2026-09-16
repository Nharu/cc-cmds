#!/usr/bin/env bash
# Fixture: `date -r` handed an EPOCH should be detected. BSD reads -r as
# seconds and GNU reads it only as a file name, so one line means two things.
set -euo pipefail

stamp=$(date -u -r "$(( $(date +%s) + 7200 ))" +%Y-%m-%dT%H:%M:%SZ)
later=$(date -r 1767225600 +%Y-%m-%d)
echo "$stamp $later"
