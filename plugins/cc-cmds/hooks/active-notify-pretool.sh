#!/usr/bin/env bash
# active-notify PreToolUse hook — self-approves dispatcher invocations
# (active-notify/scripts/notify.sh) and the permission-test bypass
# (terminal-notifier -group cc-cmds-active-notify), suppressing the
# Bash tool permission dialog.
#
# The notify.sh matcher is anchored to the entire command line. An allow
# decision covers everything the Bash tool runs, so only a lone simple
# invocation may match; anything chained, wrapped, substituted or redirected
# falls through to the permission dialog. The terminal-notifier matcher is
# deliberately not anchored — the documented permission-test form is a
# multi-line shell block — so that branch still allows the whole line.
#
# Branches on CC_CMDS_NOTIFY_INJECT_SID env (default 0 = α path):
#   0 → allow (α path). The notify branch allows the one call in front of
#       it and emits no applyPermissionRules; the terminal-notifier branch
#       still emits a session-persistent rule.
#   1 → updatedInput.command rewrite with CLAUDE_CODE_SESSION_ID prepend
#       (γ fallback for env-var renames; applyPermissionRules MUST NOT
#       be set so the hook fires every call to perform the injection).
set -euo pipefail
# Prepend brew install paths so jq is discoverable regardless of caller PATH.
# Tests can set CC_CMDS_NOTIFY_PATH_DISABLE_PREPEND=1 to skip the prepend.
if [[ -z "${CC_CMDS_NOTIFY_PATH_DISABLE_PREPEND:-}" ]]; then
  PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
fi
command -v jq >/dev/null 2>&1 || exit 0   # jq missing → silent fail-open, defer to default gate

input=$(cat)
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty')
[[ -n "$cmd" ]] || exit 0   # non-Bash matcher slip → noop

# The path segment's negation class is [:space:], not the [:blank:] used as a
# separator elsewhere on this line, and the difference is load-bearing: [:blank:]
# is space and tab only, so a path segment built from it swallows a newline and
# the first line of a two-line command becomes an approved command word of the
# attacker's choosing. Only [:space:] excludes the newline. Do not "make the
# classes consistent".
notify_re='^[[:blank:]]*(bash[[:blank:]]+)?([^[:space:];&|<>()`$]*active-notify/scripts/notify\.sh)[[:blank:]]+(arm|fire-now|fire-oneshot|cancel)([[:blank:]]+[^[:cntrl:];&|<>`$]*)?$'
bypass_re="terminal-notifier[[:space:]].*-group[[:space:]]['\"]cc-cmds-active-notify['\"]"

is_notify=0; is_bypass=0
if [[ "$cmd" =~ $notify_re ]]; then
  is_notify=1
  # The pattern constrains the SHAPE of the command word; this constrains its
  # CONTENT. The dispatcher lives at a fixed absolute path under the installed
  # plugin, so a word that is relative, climbs out with .., or is a glob the
  # shell expands at run time is not that file however it ends.
  notify_path="${BASH_REMATCH[2]}"
  case "$notify_path" in
    /*) ;;
    *) is_notify=0 ;;
  esac
  case "$notify_path" in
    *"/../"*|*"/..") is_notify=0 ;;
    *"*"*|*"?"*|*"["*) is_notify=0 ;;
  esac
fi
# grep, not [[ =~ ]]: bypass_re is deliberately unanchored and its '.*' must not
# cross a newline. bash's ERE lets '.' match a newline, so [[ =~ ]] would pair a
# terminal-notifier on one line with a -group on another. A here-string keeps
# grep's line semantics without putting a producer in a pipeline under pipefail.
grep -qE "$bypass_re" <<<"$cmd" && is_bypass=1
[[ $is_notify -eq 1 || $is_bypass -eq 1 ]] || exit 0   # not ours → default gate

inject_sid="${CC_CMDS_NOTIFY_INJECT_SID:-0}"

if [[ "$inject_sid" == "1" && $is_notify -eq 1 ]]; then
  # γ-path: inject CLAUDE_CODE_SESSION_ID via updatedInput.command rewrite.
  # The value is shell-quoted with @sh. It is external input, and this is the
  # one path in the plugin that rewrites a command it then reports as allowed —
  # so an unquoted `;` or `$(…)` in the session id would append a command of
  # its own choosing AND carry the auto-approval meant for notify.sh. Quoting
  # is also what keeps a session id with spaces from splitting into an
  # assignment plus a stray argument.
  new_cmd=$(printf '%s' "$input" | jq -r '"CLAUDE_CODE_SESSION_ID=" + ((.session_id // "") | tostring | @sh) + " " + .tool_input.command')
  jq -nc --arg c "$new_cmd" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "allow",
      permissionDecisionReason: "active-notify self-approve + session-id injection",
      updatedInput: { command: $c }
    }
  }'
  exit 0
fi

# α-path (or bypass match): allow, and for the notify branch allow THIS CALL ONLY.
#
# The notify branch emits no applyPermissionRules. A session-persistent rule has
# to be a wildcard pattern, and the only variable part such a pattern can have
# here is a `*` spanning the whole path prefix — so nothing in it can anchor the
# installed plugin's root, and any rule broad enough to cover the approved call
# also covers a command word this file's content check above rejects. The rule
# would therefore undo that check from the second call of a session onward. The
# hook is bound to every Bash call anyway, so it re-decides each one.
#
# The bypass branch keeps its rule. That branch already allows the whole command
# line for the call in front of it, so the rule adds no reach it does not already
# have, and narrowing that branch is tracked separately.
if [[ $is_notify -eq 1 ]]; then
  jq -nc '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "allow",
      permissionDecisionReason: "active-notify self-approve"
    }
  }'
else
  jq -nc --arg r "Bash(terminal-notifier *-group *cc-cmds-active-notify*)" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "allow",
      permissionDecisionReason: "active-notify self-approve",
      applyPermissionRules: [$r]
    }
  }'
fi
exit 0
