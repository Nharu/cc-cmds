#!/usr/bin/env bash
# Fixture: `mapfile` / `readarray` are bash 4+ builtins. bash 3.2 does not
# have them at all (rc=127, "command not found") — the failure looks like a
# missing external tool rather than a version problem.
set -euo pipefail

mapfile -t lines < /etc/hosts
echo "${#lines[@]}"
