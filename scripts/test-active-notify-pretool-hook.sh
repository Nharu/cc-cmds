#!/usr/bin/env bash
# Test driver for plugins/cc-cmds/hooks/active-notify-pretool.sh.
#
# Fixture contract (tests/fixtures/active-notify-hooks/pretool-*/):
#   test.sh — required. Available env vars: PRETOOL_HOOK_SH, HOOK_STDOUT,
#             HOOK_STDERR, CC_CMDS_NOTIFY_INJECT_SID (driver env-loops 0,1).
#
# Driver runs each fixture twice — once with CC_CMDS_NOTIFY_INJECT_SID=0
# (α-path) and once with =1 (γ-path) — so fixtures can branch on the env.

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
fixtures_root="$repo_root/tests/fixtures/active-notify-hooks"
pretool_hook_sh="$repo_root/plugins/cc-cmds/hooks/active-notify-pretool.sh"

if [[ ! -x "$pretool_hook_sh" ]]; then
  echo "FAIL: pretool hook not executable: $pretool_hook_sh" >&2
  exit 2
fi
if [[ ! -d "$fixtures_root" ]]; then
  echo "FAIL: fixtures root missing: $fixtures_root" >&2
  exit 2
fi

passed=0
failures=0
fixtures=()
while IFS= read -r d; do
  fixtures+=("$d")
done < <(find "$fixtures_root" -mindepth 1 -maxdepth 1 -type d -name 'pretool-*' | sort)

if [[ ${#fixtures[@]} -eq 0 ]]; then
  echo "FAIL: no pretool-* fixtures found under $fixtures_root" >&2
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

  for inject_sid in 0 1; do
    tmpdir=$(mktemp -d)
    hook_stdout="$tmpdir/hook.stdout"
    hook_stderr="$tmpdir/hook.stderr"
    : > "$hook_stdout"
    : > "$hook_stderr"

    if (
      set -e
      export TMPDIR="$tmpdir"
      export PRETOOL_HOOK_SH="$pretool_hook_sh"
      export HOOK_STDOUT="$hook_stdout"
      export HOOK_STDERR="$hook_stderr"
      export CC_CMDS_NOTIFY_INJECT_SID="$inject_sid"
      bash "$test_sh"
    ); then
      passed=$((passed + 1))
      echo "PASS: $fixture_name (inject_sid=$inject_sid)"
    else
      failures=$((failures + 1))
      echo "FAIL: $fixture_name (inject_sid=$inject_sid)" >&2
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
done

echo "test-active-notify-pretool-hook: $passed passed, $failures failed"
if (( failures > 0 )); then
  exit 1
fi
exit 0
