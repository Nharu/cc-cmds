#!/usr/bin/env bash
# Fixture: GNU-only `tac` should be detected (word-boundary regex).
set -euo pipefail

tac /etc/hostname
