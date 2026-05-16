#!/usr/bin/env bash
# Lifecycle test driver for plugins/cc-cmds/skills/active-notify/scripts/notify.sh
#
# Fixture contract:
#   tests/fixtures/active-notify-lifecycle/<case>/
#     test.sh           — required. Runs the scenario; exits 0 on pass, non-zero on fail.
#                          Available env vars: NOTIFY_SH, FLAG_FILE, FLAG_DIR,
#                          NOTIFIER_LOG, NOTIFIER_HINT, CLAUDE_SESSION_ID.
#     stubs/            — optional. If present, prepended to PATH so a
#                          fake `terminal-notifier` overrides system binary.
#                          A stub is auto-provided by the driver if absent.
#     env.sh            — optional. Sourced before test.sh if present.
#
# Each fixture runs in its own isolated TMPDIR; driver cleans up afterward.

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
fixtures_root="$repo_root/tests/fixtures/active-notify-lifecycle"
notify_sh="$repo_root/plugins/cc-cmds/skills/active-notify/scripts/notify.sh"

if [[ ! -x "$notify_sh" ]]; then
  echo "FAIL: notify.sh not executable: $notify_sh" >&2
  exit 2
fi

if [[ ! -d "$fixtures_root" ]]; then
  echo "FAIL: fixtures root missing: $fixtures_root" >&2
  exit 2
fi

# Stub terminal-notifier: logs each invocation's argv to NOTIFIER_LOG, exits 0.
# Each call appends one line; assertions can count fires or grep for flags.
stub_source=$(cat <<'STUB_EOF'
#!/usr/bin/env bash
log="${NOTIFIER_LOG:-/dev/null}"
{ printf '%s\n' "$*"; } >>"$log" 2>/dev/null || true
exit 0
STUB_EOF
)

passed=0
failures=0
fixtures=()
while IFS= read -r d; do
  fixtures+=("$d")
done < <(find "$fixtures_root" -mindepth 1 -maxdepth 1 -type d | sort)

if [[ ${#fixtures[@]} -eq 0 ]]; then
  echo "FAIL: no fixtures found under $fixtures_root" >&2
  exit 2
fi

for fixture_dir in "${fixtures[@]}"; do
  fixture_name=$(basename "$fixture_dir")
  test_sh="$fixture_dir/test.sh"

  if [[ ! -f "$test_sh" ]]; then
    echo "FAIL: $fixture_name — missing test.sh" >&2
    failures=$((failures + 1))
    continue
  fi

  # Isolated TMPDIR + deterministic CLAUDE_SESSION_ID (so flag path is predictable).
  tmpdir=$(mktemp -d)
  session_id="test-${fixture_name}"
  flag_dir="$tmpdir/cc-cmds-active-notify"
  flag_file="$flag_dir/pending-${session_id}.flag"
  notifier_log="$tmpdir/notifier.log"
  notifier_hint="$tmpdir/cc-cmds-notify-hint"

  # Stub path: fixture-provided wins; otherwise auto-stub from driver template.
  stub_dir="$tmpdir/stubs"
  mkdir -p "$stub_dir"
  if [[ -d "$fixture_dir/stubs" ]]; then
    cp -R "$fixture_dir/stubs/." "$stub_dir/"
  else
    printf '%s\n' "$stub_source" > "$stub_dir/terminal-notifier"
  fi
  chmod -R +x "$stub_dir"

  # Run fixture in subshell with isolated env. PATH prepend ensures the stub
  # is found before any system terminal-notifier. NOTIFIER_LOG is shared so
  # the stub records calls into a location test.sh can inspect.
  if (
    set -e
    export TMPDIR="$tmpdir"
    export CLAUDE_SESSION_ID="$session_id"
    # notify.sh L21 prefers CLAUDE_CODE_SESSION_ID — set it to the same value
    # so any leakage from the outer shell does not override the fixture's
    # deterministic session_id (fixture isolation guarantee).
    export CLAUDE_CODE_SESSION_ID="$session_id"
    export NOTIFY_SH="$notify_sh"
    export FLAG_DIR="$flag_dir"
    export FLAG_FILE="$flag_file"
    export NOTIFIER_LOG="$notifier_log"
    export NOTIFIER_HINT="$notifier_hint"
    export PATH="$stub_dir:$PATH"
    # Always disable notify.sh's PATH prepend in tests so the fixture stub
    # (or the fixture-controlled empty PATH) governs `command -v terminal-notifier`
    # rather than the host's real /opt/homebrew/bin/terminal-notifier.
    export CC_CMDS_NOTIFY_PATH_DISABLE_PREPEND=1
    if [[ -f "$fixture_dir/env.sh" ]]; then
      # shellcheck disable=SC1090
      source "$fixture_dir/env.sh"
    fi
    bash "$test_sh"
  ); then
    passed=$((passed + 1))
    echo "PASS: $fixture_name"
  else
    failures=$((failures + 1))
    echo "FAIL: $fixture_name" >&2
  fi

  rm -rf "$tmpdir"
done

echo "test-active-notify-lifecycle: $passed passed, $failures failed"
if (( failures > 0 )); then
  exit 1
fi
exit 0
