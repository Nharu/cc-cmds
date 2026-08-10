#!/usr/bin/env bash
# Verify: the bypass matcher's NON-anchoring, which is a stated invariant with
# nothing else covering it.
#
# `bypass_re` is deliberately unanchored because the permission-test form the
# skill documents is a multi-line shell block whose notifier line is indented and
# brace-wrapped — it does not start its line, and grep anchors per line. Anchoring
# the matcher leaves every other hook fixture green: the existing bypass fixture
# writes its command by hand as a single line, which matches the anchored variant
# just as well and therefore scores identically whether the invariant holds or not.
#
# The design point of this file is that it EXTRACTS the block from SKILL.md at
# run time instead of copying it. A hand-copied block would have to be kept in
# step with the file it claims to quote, and the thing being asserted is precisely
# that what SKILL.md tells the model to write is what the hook approves — a copy
# defeats that.
#
# This fixture asserts reach, not safety. The branch allows the entire command
# line and this fixture does not claim otherwise.
set -euo pipefail

repo_root=$(cd "$(dirname "$PRETOOL_HOOK_SH")/../../.." && pwd)
skill_md="$repo_root/plugins/cc-cmds/skills/active-notify/SKILL.md"
if [[ ! -f "$skill_md" ]]; then
  echo "FAIL: SKILL.md not found at $skill_md" >&2
  exit 1
fi

# Assertion 1 — exactly one ```bash block in SKILL.md carries the bypass group.
# A real constraint rather than a tautology: the file has several bash blocks and
# only one is this form. It is also how the fixture knows it quotes the right
# block, so a second such block must fail here rather than be picked silently.
hits=$(awk '
  /^```bash$/ { in_block = 1; buf = ""; next }
  in_block && /^```$/ { if (buf ~ /cc-cmds-active-notify/) n++; in_block = 0; next }
  in_block { buf = buf $0 "\n" }
  END { print n + 0 }
' "$skill_md")
if [[ "$hits" != "1" ]]; then
  echo "FAIL: expected exactly one bash block carrying the bypass group, found $hits" >&2
  exit 1
fi

block=$(awk '
  /^```bash$/ { in_block = 1; buf = ""; next }
  in_block && /^```$/ { if (buf ~ /cc-cmds-active-notify/) { printf "%s", buf; exit } ; in_block = 0; next }
  in_block { buf = buf $0 "\n" }
' "$skill_md")

# Assertion 2 — the extracted block is multi-line. If the documented form ever
# collapses to a single line the invariant this file protects stops being
# load-bearing, and a later reader must be told that rather than have the fixture
# keep passing on a case that no longer exercises anything.
line_count=$(printf '%s' "$block" | grep -c '' || true)
if (( line_count < 2 )); then
  echo "FAIL: the documented permission-test form is no longer multi-line ($line_count line)" >&2
  echo "  block: $block" >&2
  exit 1
fi

# Assertion 3 — the hook approves what SKILL.md tells the model to write.
jq -nc --arg c "$block" --arg sid "test-bypass-skill-block" \
  '{tool_input:{command:$c}, session_id:$sid}' \
  | "$PRETOOL_HOOK_SH" > "$HOOK_STDOUT" 2> "$HOOK_STDERR"

decision=$(jq -r '.hookSpecificOutput.permissionDecision // empty' "$HOOK_STDOUT")
if [[ "$decision" != "allow" ]]; then
  echo "FAIL: the documented permission-test block is not approved (got: ${decision:-DEFER})" >&2
  echo "  block: $block" >&2
  exit 1
fi
if jq -e '.hookSpecificOutput.updatedInput' "$HOOK_STDOUT" >/dev/null 2>&1; then
  echo "FAIL: the bypass branch must not rewrite the command" >&2
  cat "$HOOK_STDOUT" >&2
  exit 1
fi

exit 0
