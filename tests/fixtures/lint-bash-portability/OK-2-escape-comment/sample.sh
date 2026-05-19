#!/usr/bin/env bash
# Fixture: BSD/GNU divergent idioms suppressed via same-line escape comments.
# Lint should report no violations because each idiom hit is paired with a
# matching `disable=<id>` comment on the same line.
set -euo pipefail

# Intentional GNU-only use (we are on Linux runner here, BSD path covered elsewhere).
yesterday=$(date -d "yesterday" +%Y-%m-%d)  # lint-bash-portability: disable=date -d
echo "$yesterday"

# Intentional reverse-iteration via GNU tac (Linux-only context).
tac /etc/hostname >/dev/null 2>&1 || true   # lint-bash-portability: disable=tac
