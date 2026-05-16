#!/usr/bin/env bash
# Test driver for plugins/cc-cmds/hooks/active-notify-stop.sh.
#
# Fixture contract (tests/fixtures/active-notify-hooks/stop-hook-*/):
#   test.sh           — required. Runs the scenario; exits 0 pass, non-zero fail.
#                       Available env vars: STOP_HOOK_SH, NOTIFY_SH,
#                                           FLAG_DIR, NOTIFIER_LOG,
#                                           HOOK_INPUT, HOOK_STDOUT, HOOK_STDERR.
#   transcript.jsonl  — required. JSONL transcript fixture.
#   hook-input.json   — required. Stop hook stdin payload template;
#                       contains the placeholder string "__TRANSCRIPT_PATH__"
#                       which the driver substitutes with the actual path.
#
# Each fixture runs in its own isolated TMPDIR; driver cleans up afterward.

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
fixtures_root="$repo_root/tests/fixtures/active-notify-hooks"
stop_hook_sh="$repo_root/plugins/cc-cmds/hooks/active-notify-stop.sh"
notify_sh="$repo_root/plugins/cc-cmds/skills/active-notify/scripts/notify.sh"

if [[ ! -x "$stop_hook_sh" ]]; then
  echo "FAIL: stop hook not executable: $stop_hook_sh" >&2
  exit 2
fi
if [[ ! -x "$notify_sh" ]]; then
  echo "FAIL: notify.sh not executable: $notify_sh" >&2
  exit 2
fi
if [[ ! -d "$fixtures_root" ]]; then
  echo "FAIL: fixtures root missing: $fixtures_root" >&2
  exit 2
fi

# Stub terminal-notifier: logs argv to NOTIFIER_LOG.
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
done < <(find "$fixtures_root" -mindepth 1 -maxdepth 1 -type d -name 'stop-hook-*' | sort)

if [[ ${#fixtures[@]} -eq 0 ]]; then
  echo "FAIL: no stop-hook-* fixtures found under $fixtures_root" >&2
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

  tmpdir=$(mktemp -d)
  flag_dir="$tmpdir/cc-cmds-active-notify"
  notifier_log="$tmpdir/notifier.log"
  hook_stdout="$tmpdir/hook.stdout"
  hook_stderr="$tmpdir/hook.stderr"
  stub_dir="$tmpdir/stubs"

  mkdir -p "$flag_dir" "$stub_dir"
  : > "$notifier_log"
  : > "$hook_stdout"
  : > "$hook_stderr"
  printf '%s\n' "$stub_source" > "$stub_dir/terminal-notifier"
  chmod -R +x "$stub_dir"

  # Materialize transcript and hook-input with TRANSCRIPT_PATH substitution
  transcript_dst="$tmpdir/transcript.jsonl"
  if [[ -f "$fixture_dir/transcript.jsonl" ]]; then
    cp "$fixture_dir/transcript.jsonl" "$transcript_dst"
  else
    : > "$transcript_dst"
  fi
  hook_input_dst="$tmpdir/hook-input.json"
  if [[ -f "$fixture_dir/hook-input.json" ]]; then
    sed "s|__TRANSCRIPT_PATH__|${transcript_dst}|g" "$fixture_dir/hook-input.json" > "$hook_input_dst"
  else
    printf '{"session_id":"test","transcript_path":"%s"}\n' "$transcript_dst" > "$hook_input_dst"
  fi

  # CLAUDE_PLUGIN_ROOT must point to the in-repo plugin so the stop hook
  # can shell out to its own notify.sh.
  plugin_root="$repo_root/plugins/cc-cmds"

  if (
    set -e
    export TMPDIR="$tmpdir"
    export STOP_HOOK_SH="$stop_hook_sh"
    export PRETOOL_HOOK_SH="$repo_root/plugins/cc-cmds/hooks/active-notify-pretool.sh"
    export NOTIFY_SH="$notify_sh"
    export FLAG_DIR="$flag_dir"
    export NOTIFIER_LOG="$notifier_log"
    export HOOK_INPUT="$hook_input_dst"
    export HOOK_STDOUT="$hook_stdout"
    export HOOK_STDERR="$hook_stderr"
    export CLAUDE_PLUGIN_ROOT="$plugin_root"
    # Stub PATH puts our terminal-notifier first; disable notify.sh's
    # PATH prepend so it doesn't shadow the stub with system binary.
    export PATH="$stub_dir:$PATH"
    export CC_CMDS_NOTIFY_PATH_DISABLE_PREPEND=1
    bash "$test_sh"
  ); then
    passed=$((passed + 1))
    echo "PASS: $fixture_name"
  else
    failures=$((failures + 1))
    echo "FAIL: $fixture_name" >&2
    if [[ -s "$hook_stderr" ]]; then
      echo "  --- hook stderr ---" >&2
      sed 's/^/  /' "$hook_stderr" >&2
    fi
    if [[ -s "$hook_stdout" ]]; then
      echo "  --- hook stdout ---" >&2
      sed 's/^/  /' "$hook_stdout" >&2
    fi
  fi

  rm -rf "$tmpdir"
done

echo "test-active-notify-stop-hook: $passed passed, $failures failed"
if (( failures > 0 )); then
  exit 1
fi
exit 0
