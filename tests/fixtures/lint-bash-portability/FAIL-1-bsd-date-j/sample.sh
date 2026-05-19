#!/usr/bin/env bash
# Fixture: BSD-only `date -j` should be detected.
set -euo pipefail

epoch=$(date -j -f "%Y-%m-%d" "2026-01-01" +%s)
echo "$epoch"
