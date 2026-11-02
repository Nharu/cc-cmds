#!/usr/bin/env bash
# active-notify PreToolUse hook — self-approves dispatcher invocations
# (active-notify/scripts/notify.sh) and the permission-test bypass
# (terminal-notifier -group cc-cmds-active-notify), suppressing the
# Bash tool permission dialog.
#
# Bypass branch (terminal-notifier only): applyPermissionRules emit, no rewrite.
#
# Dispatcher branch (arm | fire-now | cancel): `permissionDecision: "allow"` on
# every call and no applyPermissionRules. A PreToolUse hook runs before every
# tool call, so no rule is needed to keep the dialog away, and a rule matching
# `notify.sh` would also match the `fire-now` calls that need this hook to run.
# The command may be rewritten with prefixes in front of the command whose
# leading whitespace is stripped:
#   - `fire-now` gets the seat prefix `CC_CMDS_ACTIVE_NOTIFY_SEAT_TICKET=<name> `.
#     With an empty `agent_id` (the main session) the name is a one-shot ticket
#     this hook writes under $HOME/.local/state/cc-cmds/active-notify-seat/; the
#     dispatcher claims and removes it, and only a claimed ticket lets that fire
#     leave a remote attention event. With an `agent_id` (a spawned agent) or a
#     failed issue the value is empty. The hook's assignment comes first, so a
#     value inherited from the environment is overridden, and a value the model
#     wrote later in the command names no live ticket.
#   - CC_CMDS_NOTIFY_INJECT_SID=1 (γ path) adds `CLAUDE_CODE_SESSION_ID=<sid> `
#     after the seat prefix, for every dispatcher subcommand.
# A prefix is attached only when the command starts with a simple command that
# can take an assignment prefix, and only when the rewritten command passes a
# syntax check by the shell `$SHELL` names (zsh or bash). Otherwise the call is
# allowed unchanged and any ticket issued for it is removed: that fire loses its
# remote event and keeps its local banner. When a prefix is attached,
# `updatedInput` carries the whole `tool_input` with only `command` replaced.
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

notify_re='active-notify/scripts/notify\.sh[[:space:]]+(arm|fire-now|cancel)\b'
fire_re='active-notify/scripts/notify\.sh[[:space:]]+fire-now\b'
bypass_re="terminal-notifier[[:space:]].*-group[[:space:]]['\"]cc-cmds-active-notify['\"]"

is_notify=0; is_bypass=0
printf '%s' "$cmd" | grep -qE "$notify_re" && is_notify=1
printf '%s' "$cmd" | grep -qE "$bypass_re" && is_bypass=1
[[ $is_notify -eq 1 || $is_bypass -eq 1 ]] || exit 0   # not ours → default gate

if [[ $is_notify -eq 0 ]]; then
  # Permission-test bypass: session-persistent allow via applyPermissionRules.
  rule="Bash(terminal-notifier *-group *cc-cmds-active-notify*)"
  jq -nc --arg r "$rule" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "allow",
      permissionDecisionReason: "active-notify self-approve",
      applyPermissionRules: [$r]
    }
  }'
  exit 0
fi

inject_sid="${CC_CMDS_NOTIFY_INJECT_SID:-0}"
ws=$' \t\n'
seat_dir="${HOME:-}/.local/state/cc-cmds/active-notify-seat"

# an_prefixable <stripped> — true when the command's first word can take an
# assignment prefix. The judgment errs toward "no": a shape outside these lists
# only loses its remote event, while a prefix in front of `(`, `{`, a reserved
# word or a function definition is a syntax error that stops the whole command.
an_prefixable() {
  local s="$1" first after
  first="${s%%[$ws]*}"
  [[ -n "$first" ]] || return 1
  # The class is spelled out letter by letter: a range such as `a-z` follows
  # the collation order in some locales.
  case "${first:0:1}" in
    [abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_./~\"\'\$-]) ;;
    *) return 1 ;;
  esac
  case "$first" in
    if|then|elif|else|fi|case|esac|for|select|while|until|do|done|in|function|time|coproc) return 1 ;;
  esac
  case "$first" in
    *[\(\)\{\}\;\&\|\<\>]*) return 1 ;;
  esac
  after="${s:${#first}}"
  after="${after#"${after%%[!$ws]*}"}"
  case "$after" in
    \(*) return 1 ;;
  esac
  return 0
}

# an_issue_ticket — write one seat ticket and print its name, or print nothing.
# Every failure ends with an empty name, so the allow decision is still printed.
an_issue_ticket() {
  local name ts tmp
  [[ -n "${HOME:-}" ]] || return 0
  ( umask 077 && mkdir -p "$seat_dir" ) >/dev/null 2>&1 || return 0
  # Tickets nobody claimed (the command never reached the dispatcher) and
  # leftovers of an interrupted claim expire here.
  find "$seat_dir" -maxdepth 1 -type f -mmin +10 -delete >/dev/null 2>&1 || true
  name=$(od -An -N16 -tx1 /dev/urandom 2>/dev/null) || return 0
  name=$(printf '%s' "$name" | tr -d ' \n') || return 0
  case "$name" in
    *[!0123456789abcdef]*) return 0 ;;
  esac
  [[ ${#name} -eq 32 ]] || return 0
  ts=$(date +%s 2>/dev/null) || return 0
  tmp="$seat_dir/.$name.$$.tmp"
  if ! ( umask 077 && printf '%s\n' "$ts" > "$tmp" ) >/dev/null 2>&1; then
    rm -f "$tmp" >/dev/null 2>&1 || true
    return 0
  fi
  if ! mv "$tmp" "$seat_dir/$name" >/dev/null 2>&1; then
    rm -f "$tmp" >/dev/null 2>&1 || true
    return 0
  fi
  printf '%s' "$name"
}

# an_syntax_ok <command> — parse the rewritten command, without running it,
# with the shell the Bash tool runs it in. An unusable or unknown shell fails.
an_syntax_ok() {
  local sh="${SHELL:-}"
  [[ -n "$sh" && -f "$sh" && -x "$sh" ]] || return 1
  case "${sh##*/}" in
    zsh) "$sh" -f -n -c "$1" </dev/null >/dev/null 2>&1 ;;
    bash) BASH_ENV= "$sh" -n -c "$1" </dev/null >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

stripped="${cmd#"${cmd%%[!$ws]*}"}"
prefix=''
ticket=''
sid_injected=0
if an_prefixable "$stripped"; then
  if printf '%s' "$cmd" | grep -qE "$fire_re"; then
    agent_id=$(printf '%s' "$input" | jq -r '.agent_id // empty' 2>/dev/null) || agent_id=''
    if [[ -z "$agent_id" ]]; then
      ticket=$(an_issue_ticket) || ticket=''
    fi
    prefix="CC_CMDS_ACTIVE_NOTIFY_SEAT_TICKET=${ticket} "
  fi
  if [[ "$inject_sid" == "1" ]]; then
    session_id=$(printf '%s' "$input" | jq -r '.session_id // empty')
    prefix="${prefix}CLAUDE_CODE_SESSION_ID=${session_id} "
    sid_injected=1
  fi
fi

new_cmd=''
if [[ -n "$prefix" ]]; then
  new_cmd="${prefix}${stripped}"
  if an_syntax_ok "$new_cmd"; then
    :
  else
    new_cmd=''
    sid_injected=0
    if [[ -n "$ticket" ]]; then
      rm -f "$seat_dir/$ticket" >/dev/null 2>&1 || true
    fi
  fi
fi

reason='active-notify self-approve'
[[ $sid_injected -eq 0 ]] || reason='active-notify self-approve + session-id injection'

if [[ -n "$new_cmd" ]]; then
  printf '%s' "$input" | jq -c --arg c "$new_cmd" --arg why "$reason" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "allow",
      permissionDecisionReason: $why,
      updatedInput: (.tool_input | .command = $c)
    }
  }'
else
  jq -nc --arg why "$reason" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "allow",
      permissionDecisionReason: $why
    }
  }'
fi
exit 0
