#!/usr/bin/env bash
# Fixture: `wait -n` is a bash 4+ builtin option. Under a sanitized PATH the
# shebang resolves to macOS's stock bash 3.2, where it exits rc=2. It passes
# every other lint, so this row is the only thing that catches it.
set -euo pipefail

sleep 1 &
sleep 2 &
wait -n
