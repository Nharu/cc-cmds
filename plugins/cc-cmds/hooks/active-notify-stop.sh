#!/usr/bin/env bash
# active-notify Stop hook — evaluates task-completion rules at turn end
# and shells out to notify.sh fire if all conditions hold. Model does
# NOT participate in workflow/summary synthesis (best-effort from
# transcript JSONL).
#
# Rules (all must hold):
#   1. Active flag for this session (or β safety-net fallback to newest)
#   2. ≥1 user-task tool_use this turn, excluding notify.sh ARM/CANCEL
#   3. Turn-terminal tool_use is NOT AskUserQuestion
#      (belt-and-braces — harness suspends turn for AskUserQuestion so
#      Stop fires only after user reply + model follow-up; transcript
#      line 57-63 evidence confirmed at design time)
set -euo pipefail
# Prepend brew install paths so jq + dispatcher PATH is consistent (Apple
# Silicon /opt/homebrew/bin, Intel /usr/local/bin). Tests that need to
# override binary resolution can set CC_CMDS_NOTIFY_PATH_DISABLE_PREPEND=1
# to skip this prepend and fully control PATH from the fixture harness.
if [[ -z "${CC_CMDS_NOTIFY_PATH_DISABLE_PREPEND:-}" ]]; then
  PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
fi
command -v jq >/dev/null 2>&1 || exit 0   # jq missing → silent fail-open

input=$(cat)
# dev/test context guard — silent fail-open if plugin root is unresolved
[[ -n "${CLAUDE_PLUGIN_ROOT:-}" && -d "$CLAUDE_PLUGIN_ROOT" ]] || exit 0
session_id=$(printf '%s' "$input" | jq -r '.session_id // empty')
transcript_path=$(printf '%s' "$input" | jq -r '.transcript_path // empty')
[[ -n "$transcript_path" && -f "$transcript_path" ]] || exit 0

flag_dir="${TMPDIR:-/tmp}/cc-cmds-active-notify"
[[ -d "$flag_dir" ]] || exit 0

# Session-id matching: scan flag dir, match against flag JSON's session_id field.
# Skip candidates with empty/corrupted session_id field — they would defeat
# the β env-prefix invariant (current sid would be injected, silently
# no-op'ing the banner).
active_flag=""
for f in "$flag_dir"/pending-*.flag; do
  [[ -f "$f" ]] || continue
  flag_sid=$(jq -r '.session_id // empty' "$f" 2>/dev/null || true)
  [[ -n "$flag_sid" ]] || continue
  if [[ "$flag_sid" == "$session_id" ]]; then
    active_flag="$f"; break
  fi
done

# β safety-net fallback: newest flag if no exact match. Re-validate
# session_id on the β-selected flag — newest-by-mtime may point to a
# corrupted flag and the env-prefix invariant requires a valid sid.
if [[ -z "$active_flag" ]]; then
  active_flag=$(ls -t "$flag_dir"/pending-*.flag 2>/dev/null | head -1 || true)
  [[ -n "$active_flag" ]] || exit 0
  beta_sid=$(jq -r '.session_id // empty' "$active_flag" 2>/dev/null || true)
  [[ -n "$beta_sid" ]] || exit 0
  # Audit-only — write to file, NOT user-visible stderr (silent-skip discipline).
  # Logged at SELECTION time (pre-rule-eval) — subsequent Rule 2 or Rule 3
  # silent exit may still cause no banner to fire; "selected" wording avoids
  # the misleading "engaged → guaranteed fire" inference during forensics.
  printf '[%s] β fallback selected (pre-rule-eval): matched newest flag %s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(basename "$active_flag")" \
    >> "$flag_dir/audit.log" 2>/dev/null || true
fi

# Find turn boundary: last GENUINE human-user line.
# A genuine user turn is type=="user" with a non-tool_result first content
# block and not an isMeta slash-command marker. tool_result entries also
# carry role:"user" at the message level, so a substring match would
# mis-slice the turn and undercount work_calls.
last_user_idx=$(jq -s '
  [ range(0; length) as $i
    | select(.[$i].type == "user"
             and (.[$i].isMeta // false) != true
             and (try (.[$i].message.content[0].type) catch "text") != "tool_result")
    | $i ] | last // -1
' "$transcript_path")
[[ "$last_user_idx" -ge 0 ]] || exit 0

# Slice JSONL lines after the last genuine user message
# (0-indexed jq result → +2 for the 1-indexed next line)
turn_slice=$(tail -n +"$(( last_user_idx + 2 ))" "$transcript_path")

# Rule 2: count user-task tool_use entries, exclude notify.sh ARM/CANCEL.
# Whitelist scope: 11 production tools that signal user-task progress
# (Bash/Read/Edit/Write/Grep/Glob = core; WebFetch/WebSearch = research;
# Task = subagent delegation; MultiEdit/NotebookEdit = file mutation variants).
# Excluded: notify.sh self-call (regex below), AskUserQuestion (Rule 3),
# TodoWrite + ExitPlanMode (meta tools that signal planning, not task work).
work_calls=$(printf '%s' "$turn_slice" | jq -rs '
  [ .[]
    | select(.message.role == "assistant")
    | .message.content[]?
    | select(.type == "tool_use")
    | select(.name as $n
             | ["Bash","Read","Edit","Write","Grep","Glob",
                "WebFetch","WebSearch","Task","MultiEdit","NotebookEdit"]
             | index($n) != null)
    | select(.name != "Bash"
             or (.input.command | test("active-notify/scripts/notify\\.sh\\s+(arm|fire|cancel)\\b") | not))
  ] | length
')
[[ "$work_calls" -ge 1 ]] || exit 0

# Rule 3 (turn-terminal AskUserQuestion suppression — belt-and-braces)
last_tool=$(printf '%s' "$turn_slice" | jq -rs '
  [ .[] | select(.message.role == "assistant")
    | .message.content[]? | select(.type == "tool_use") | .name ] | last // empty
')
[[ "$last_tool" == "AskUserQuestion" ]] && exit 0

# Best-effort summary synthesis: match the last Bash tool_use to its tool_result.
last_bash_id=$(printf '%s' "$turn_slice" | jq -rs '
  [ .[] | select(.message.role == "assistant")
    | .message.content[]?
    | select(.type == "tool_use" and .name == "Bash") | .id ] | last // empty
')
summary="완료"   # default — non-Bash terminal turn
if [[ -n "$last_bash_id" ]]; then
  result=$(printf '%s' "$turn_slice" | jq -rs --arg id "$last_bash_id" '
    [ .[] | select(.message.role == "user")
      | .message.content[]?
      | select(.type == "tool_result" and .tool_use_id == $id) ] | last
  ')
  if [[ "$result" != "null" && -n "$result" ]]; then
    # is_error binary only — exit-code scrape removed to eliminate
    # semantic-contradictory banners (e.g., "성공 (exit 5)" when stdout
    # incidentally contained "exit N" substring). Banner copy stays
    # coarse-grained but never lies about success/failure.
    is_err=$(printf '%s' "$result" | jq -r '.is_error // false')
    if [[ "$is_err" == "true" ]]; then
      summary="실패"
    else
      summary="성공"
    fi
  fi
fi

# Workflow ID: first non-cd token from the last Bash command
last_bash_cmd=$(printf '%s' "$turn_slice" | jq -rs '
  [ .[] | select(.message.role == "assistant")
    | .message.content[]?
    | select(.type == "tool_use" and .name == "Bash")
    | .input.command ] | last // empty
')
workflow=$(printf '%s' "$last_bash_cmd" | awk '{
  for (i=1; i<=NF; i++) {
    if ($i != "cd" && $i !~ /^&&$/ && $i !~ /=/) { print $i; exit }
  }
}')
workflow="${workflow:-task}"

# Env-prefix the fire call with the matched flag's session_id — under β
# fallback (active_flag is a foreign-session flag), notify.sh's fallback
# expression would otherwise re-derive a DIFFERENT session_id from the
# current shell's $CLAUDE_CODE_SESSION_ID and look up a non-existent
# flag, silently no-op'ing the banner.
flag_session_id=$(jq -r '.session_id // empty' "$active_flag" 2>/dev/null || true)
CLAUDE_CODE_SESSION_ID="${flag_session_id:-${session_id}}" \
  bash "${CLAUDE_PLUGIN_ROOT}/skills/active-notify/scripts/notify.sh" \
  fire "$workflow" "$summary"
exit 0
