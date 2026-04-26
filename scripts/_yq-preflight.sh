#!/usr/bin/env bash
# Shared preflight: ensure mikefarah/yq (Go) is installed, not kislyuk/yq (Python).
#
# The two tools share the binary name `yq` but have incompatible syntax. Several
# CLI ecosystems (apt, pip, homebrew `python-yq`) ship the kislyuk variant by
# default. Calling our scripts against kislyuk/yq produces silent wrong output,
# so we bail early with a clear remediation message.
#
# Usage:
#   source scripts/_yq-preflight.sh
#   yq_preflight   # exits 1 with the design-spec error string on failure

yq_preflight() {
  local version_output
  if ! command -v yq >/dev/null 2>&1; then
    cat >&2 <<'EOF'
error: mikefarah/yq not found. macOS: brew install yq / Linux: https://github.com/mikefarah/yq/releases
Note: the apt/pip `yq` package is kislyuk/yq and is NOT compatible. Uninstall it first.
EOF
    return 1
  fi

  version_output=$(yq --version 2>&1 || true)
  if [[ "$version_output" != *mikefarah* ]]; then
    cat >&2 <<'EOF'
error: mikefarah/yq not found. macOS: brew install yq / Linux: https://github.com/mikefarah/yq/releases
Note: the apt/pip `yq` package is kislyuk/yq and is NOT compatible. Uninstall it first.
EOF
    return 1
  fi

  return 0
}
