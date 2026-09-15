#!/usr/bin/env bash
# Fixture: `date -r` handed a FILE reads that file's mtime and does the same
# thing on both hosts, so the epoch rule has to stay silent about it. Banning
# the flag outright would turn every one of these into a false positive.
set -euo pipefail

mtime=$(date -r /etc/hosts +%Y-%m-%d)
ref="$HOME/.profile"
echo "$(date -u -r "$ref" +%s) $mtime"
