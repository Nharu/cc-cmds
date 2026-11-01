#!/usr/bin/env bash
#
# session-permission-notify.sh — the permission prompt seat.
#
# WHAT IT IS FOR. A permission dialog stops the session until a person answers,
# and today it raises no banner. This seat leaves a `permission` attention
# event — the tool name and a readable summary of its input, uncut — so the
# remote side can show what is waiting. It raises NO local banner and calls no
# notifier: what the person sees at the machine stays exactly as it was.
#
# ONE SCRIPT, SEVEN ROLES, NINE hooks.json ENTRIES. The role is the first
# argument, so the cheap path is chosen before any payload is parsed:
#   request      PermissionRequest            — the main seat
#   notification Notification(permission_prompt) — the fallback signal
#   settle       PostToolUse / PostToolUseFailure / PermissionDenied (`*`)
#   agent-start  SubagentStart
#   agent-stop   SubagentStop
#   stop         Stop                         — the turn ended
#   prompt       UserPromptSubmit             — the person came back
# The writer and the reader of the state files live in this one file so that
# the paths and the fingerprint move together. The contract is the
# "The permission prompt seat" section of README.md next door.
#
# ONE SLOT PER DIALOG. The slot is `cc-cmds-permission-<sid>@<fingerprint>`,
# the fingerprint being the first 16 hex digits of the sha256 of
# `{tool_name, tool_input}` as key-sorted compact JSON. A handled marker matches
# by slot and time alone, so one slot per session would let the result of one
# parallel call close another dialog that is still open. The fallback signal's
# event uses `…@notification`, and the turn end and the return close the whole
# session with the prefix marker `cc-cmds-permission-<sid>@`.
#
# THE EVENT IS WRITTEN DETACHED. The dialog appears only once this hook has
# returned, so the synchronous part does the seat checks, records the time,
# computes the fingerprint and creates `pending.<fp>`; the summary, the
# redaction and the event go to a detached job. `CC_CMDS_NOTIFY_PERMISSION_SYNC=1`
# runs that job in the foreground, for tests only.
#
# PENDING, THEN OPEN, SO A MARKER NEVER PRECEDES ITS EVENT. A settle signal can
# arrive before the detached job wrote the event. A marker written then would
# carry an earlier time than the event and close nothing. So a settle that
# finds `pending.<fp>` only removes it, and the detached job, whose move to
# `open.<fp>` then fails, writes the exact marker itself after the event. The
# move happens once, so every interleaving leaves exactly one marker.
#
# WHY `set -uo pipefail` AND NOT `-e`: the same reasons as the banner seats
# (see session-ask-notify.sh). `cc_notify_session_enabled` and
# `cc_caller_is_router` answer a normal false with status 1, and both are
# called inside `if !`. Every path exits 0 with nothing on stdout or stderr: a
# PermissionRequest hook's stdout is a decision channel, so a stray byte could
# change the permission flow, and this seat never answers the dialog.
#
# WHY THE SUBAGENT GATE READS `agent_id` AND NOT `agent_type`: `agent_type` is
# also present on a main thread started with `--agent`; only `agent_id` marks a
# spawned agent. Every `jq` call drops its stderr.
set -uo pipefail

role="${1:-}"
case "$role" in
  request|notification|settle|agent-start|agent-stop|stop|prompt) ;;
  *) exit 0 ;;
esac

base="${TMPDIR:-/tmp}"
base="${base%/}/cc-cmds-permission"

# The cheap path. Every tool call of every session reaches `settle`, so when no
# dialog is open anywhere one glob is the whole cost: no jq, no sourcing, and
# stdin is left unread.
any_exists() {
  local f
  for f in "$@"; do
    if [ -e "$f" ]; then return 0; fi
  done
  return 1
}
case "$role" in
  settle|stop|prompt)
    if ! any_exists "$base"/*/open.* "$base"/*/pending.*; then exit 0; fi
    ;;
esac

# Same PATH prepend and seam as the banner seats, so `jq` is found whatever
# PATH the harness hands down and a test can shadow the binaries.
if [ -z "${CC_CMDS_NOTIFY_PATH_DISABLE_PREPEND:-}" ]; then
  PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
fi
command -v jq >/dev/null 2>&1 || exit 0

input=$(cat)

plugin_root="${CLAUDE_PLUGIN_ROOT:-}"
if [ -z "$plugin_root" ]; then
  plugin_root=$(cd "$(dirname "$0")/.." 2>/dev/null && pwd) || exit 0
fi
emitter="$plugin_root/orchestrator/notify-run.sh"
tap="$plugin_root/orchestrator/attention.sh"
[ -f "$emitter" ] || exit 0
[ -f "$tap" ] || exit 0
# shellcheck source=/dev/null
. "$emitter" >/dev/null 2>&1 || exit 0

# The session banner switch: a person who switched the session banners off gets
# no remote copy of a prompt either.
if ! cc_notify_session_enabled; then exit 0; fi
# A pipeline stage session has nobody at the dialog's other end.
if ! cc_caller_is_router; then exit 0; fi

# The session id goes into the slot and the state path as is, so it must
# already be in the `safe_sid` alphabet; `.` and `..` would name another path.
sid=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)
[[ $sid =~ ^[A-Za-z0-9_.-]+$ ]] || exit 0
case "$sid" in
  .|..) exit 0 ;;
esac

umask 077
dir="$base/$sid"
slot_prefix="cc-cmds-permission-$sid@"

agent_id=$(printf '%s' "$input" | jq -r '.agent_id // empty' 2>/dev/null)

now_ms() {
  local ms
  ms=$(/usr/bin/perl -MTime::HiRes=time -e 'printf "%d\n", time() * 1000' 2>/dev/null) || ms=""
  case "$ms" in
    ''|*[!0123456789]*) ms="$(date +%s 2>/dev/null)000" ;;
  esac
  printf '%s' "$ms"
}

# The first 16 hex digits of the sha256 of `{tool_name, tool_input}` as
# key-sorted compact JSON. `request` and `settle` call this one function, so the
# two sides cannot disagree on the bytes hashed.
fingerprint() {
  local canon sum
  canon=$(printf '%s' "$input" | jq -cS '{tool_name, tool_input}' 2>/dev/null) || return 1
  [ -n "$canon" ] || return 1
  if command -v shasum >/dev/null 2>&1; then
    sum=$(printf '%s\n' "$canon" | shasum -a 256 2>/dev/null) || return 1
  elif command -v sha256sum >/dev/null 2>&1; then
    sum=$(printf '%s\n' "$canon" | sha256sum 2>/dev/null) || return 1
  else
    return 1
  fi
  sum="${sum%% *}"
  sum="${sum:0:16}"
  case "$sum" in
    *[!0123456789abcdef]*) return 1 ;;
  esac
  [ "${#sum}" -eq 16 ] || return 1
  printf '%s' "$sum"
}

title_for() {
  local t
  t=$(cc_notify_session_title_read "$sid" 2>/dev/null) || t=""
  if [ -n "$t" ]; then
    printf 'cc-cmds · %s · 권한 확인을 기다립니다' "$t"
  else
    printf 'cc-cmds · 권한 확인을 기다립니다'
  fi
}

# The redaction, applied inside jq so the raw value never passes through a
# shell variable on its way to the attachment. Each shape is replaced by
# `[가림]`; for an assignment, a header, a flag and a URL only the value goes.
# shellcheck disable=SC2016
redact_defs='
def red:
  gsub("-----BEGIN [A-Z ]*PRIVATE KEY-----[\\s\\S]*?-----END [A-Z ]*PRIVATE KEY-----"; "[가림]")
  | gsub("(?<k>authorization[ \\t]*:[ \\t]*)[^\\n\\r\"'"'"']+"; "\(.k)[가림]"; "i")
  | gsub("\\b(?<k>bearer|basic)[ \\t]+[A-Za-z0-9._~+/=-]+"; "\(.k) [가림]"; "i")
  | gsub("(?<k>[A-Za-z][A-Za-z0-9+.-]*://[^\\s:/@]+:)[^\\s/@]+@"; "\(.k)[가림]@")
  | gsub("(?<k>--(?:token|password|secret|api-key)(?:=|[ \\t]+))(?:\"[^\"]*\"|'"'"'[^'"'"']*'"'"'|[^\\s]+)"; "\(.k)[가림]"; "i")
  | gsub("\\b(?<k>(?:token|secret|password|passwd|pwd|api_key|api-key|apikey|access_key|private_key|credential|auth)[A-Za-z0-9_.-]*[\"'"'"']?)(?<s>[ \\t]*[:=][ \\t]*)(?:\"[^\"]*\"|'"'"'[^'"'"']*'"'"'|[^\\s\"'"'"',;&]+)"; "\(.k)\(.s)[가림]"; "i")
  | gsub("\\b(?:gh[pousr]_[A-Za-z0-9]+|github_pat_[A-Za-z0-9_]+|sk-[A-Za-z0-9_-]+|xox[abprs]-[A-Za-z0-9-]+|AKIA[A-Z0-9]{16}|AIza[A-Za-z0-9_-]+|pk_[0-9]+_[A-Za-z0-9]+)"; "[가림]")
  | gsub("\\b[0-9]{8,10}:[A-Za-z0-9_-]{35}\\b"; "[가림]")
  | gsub("\\beyJ[A-Za-z0-9_-]*\\.[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+"; "[가림]");
'

# The per-tool summary and the attachment, in one jq call that writes the
# attachment file itself. A known tool shows its fields uncut, and the input
# keys it did not show follow on one `기타 입력:` line, so nothing is dropped
# silently. An unknown tool, or a known one without its key field, shows the
# whole `tool_input` as indented JSON.
# shellcheck disable=SC2016
request_prog="$redact_defs"'
def pp($i):
  if type == "object" then
    if length == 0 then "{}"
    else "{\n" + ([to_entries[] | $i + "  " + (.key | tojson) + ": " + (.value | pp($i + "  "))] | join(",\n")) + "\n" + $i + "}" end
  elif type == "array" then
    if length == 0 then "[]"
    else "[\n" + ([.[] | $i + "  " + pp($i + "  ")] | join(",\n")) + "\n" + $i + "]" end
  else tojson end;
def str: if type == "string" then . elif . == null then "" else tojson end;
def core: {Bash: ["command"], Edit: ["file_path"], MultiEdit: ["file_path", "edits"],
           Write: ["file_path"], NotebookEdit: ["notebook_path"], Read: ["file_path"],
           WebFetch: ["url"], WebSearch: ["query"], Glob: ["pattern"], Grep: ["pattern"]};
def known($t; $o):
  if $t == "Bash" then
    {used: ["command", "description"],
     lines: [($o.command | str) + (if (($o.description // "") | str) != "" then " — " + ($o.description | str) else "" end)]}
  elif $t == "Edit" then
    {used: ["file_path", "old_string", "new_string"],
     lines: ["경로: " + ($o.file_path | str), "바꿀 문자열:", ($o.old_string | str), "새 문자열:", ($o.new_string | str)]}
  elif $t == "MultiEdit" then
    {used: ["file_path", "edits"],
     lines: (["경로: " + ($o.file_path | str)]
       + [ ($o.edits | if type == "array" then to_entries[] else empty end)
           | (.key + 1 | tostring) as $n
           | .value as $e
           | if ($e | type) == "object" then
               ("편집 " + $n + " — 바꿀 문자열:"), ($e.old_string | str),
               ("편집 " + $n + " — 새 문자열:"), ($e.new_string | str),
               (($e | del(.old_string, .new_string)) as $r
                | if ($r | length) > 0 then "편집 " + $n + " — 기타 입력: " + ($r | tojson) else empty end)
             else "편집 " + $n + ": " + ($e | tojson) end ])}
  elif $t == "Write" then
    {used: ["file_path", "content"], lines: ["경로: " + ($o.file_path | str), "내용:", ($o.content | str)]}
  elif $t == "NotebookEdit" then
    {used: ["notebook_path", "new_source"], lines: ["노트북 경로: " + ($o.notebook_path | str), "새 소스:", ($o.new_source | str)]}
  elif $t == "Read" then
    {used: ["file_path"], lines: ["경로: " + ($o.file_path | str)]}
  elif $t == "WebFetch" then
    {used: ["url"], lines: ["URL: " + ($o.url | str)]}
  elif $t == "WebSearch" then
    {used: ["query"], lines: ["질의: " + ($o.query | str)]}
  else
    {used: ["pattern", "path"],
     lines: (["패턴: " + ($o.pattern | str)] + (if ($o | has("path")) then ["경로: " + ($o.path | str)] else [] end))}
  end;

((.tool_name // "") | str) as $t
| .tool_input as $in
| (if ($in | type) == "object" and (core | has($t)) and all((core | .[$t])[]; . as $k | $in | has($k)) then
     known($t; $in) as $r
     | ($in | delpaths([$r.used[] | [.]])) as $rest
     | ($r.lines + (if ($rest | length) > 0 then ["기타 입력: " + ($rest | tojson)] else [] end)) | join("\n")
   else ($in | pp("")) end) as $summary0
| ($summary0 | red) as $summary
| {kind: "permission", actionable: false,
   reply: {surface: "permission", session_id: $sid, tool_name: $t, input_summary: $summary},
   body: ($t + "\n" + $summary)}
'

# shellcheck disable=SC2016
notification_prog="$redact_defs"'
{kind: "permission", actionable: false, reply: null,
 body: ("도구를 알 수 없는 권한 확인이 열렸습니다" + "\n" + ((.message // "") | if type == "string" then . else tojson end | red))}
'

# write_event <slot> <jq program> — build the attachment with jq straight into
# a `cc-attention-detail.*` file and hand it to the tap. Returns 1 when no
# attachment could be built.
write_event() {
  local slot="$1" prog="$2" tmp title
  tmp=$(mktemp "${TMPDIR:-/tmp}/cc-attention-detail.XXXXXX" 2>/dev/null) || return 1
  if ! printf '%s' "$input" | jq -c --arg sid "$sid" "$prog" > "$tmp" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null
    return 1
  fi
  if [ ! -s "$tmp" ]; then
    rm -f "$tmp" 2>/dev/null
    return 1
  fi
  title=$(title_for)
  # shellcheck source=/dev/null
  . "$tap" >/dev/null 2>&1 || { rm -f "$tmp" 2>/dev/null; return 1; }
  CC_NOTIFY_SESSION_ID="$sid" cc_attention_emit permission "$slot" "$title" "" "$tmp"
  rm -f "$tmp" 2>/dev/null
  return 0
}

mark_exact() {
  # shellcheck source=/dev/null
  . "$tap" >/dev/null 2>&1 || return 0
  cc_attention_handled "$1" permission-settled
  return 0
}

# The detached half of `request`: the event, then pending → open. A failed move
# means a settle signal took the pending file meanwhile, so the exact marker is
# written here, after the event.
emit_request() {
  local fp="$1" slot="$slot_prefix$1"
  write_event "$slot" "$request_prog" || { rm -f "$dir/pending.$fp" 2>/dev/null; return 0; }
  if ! mv "$dir/pending.$fp" "$dir/open.$fp" 2>/dev/null; then
    mark_exact "$slot"
  fi
  return 0
}

case "$role" in
  request)
    mkdir -p "$dir" 2>/dev/null || exit 0
    # The time is recorded for a subagent's request too: the fallback signal
    # carries no `agent_id`, so it must be held back after either kind.
    now=$(now_ms)
    if printf '%s\n' "$now" > "$dir/.seen.$$" 2>/dev/null; then
      mv -f "$dir/.seen.$$" "$dir/seen" 2>/dev/null || rm -f "$dir/.seen.$$" 2>/dev/null
    else
      rm -f "$dir/.seen.$$" 2>/dev/null
    fi
    find "$base" -mindepth 2 -maxdepth 2 -type f -mmin +1440 -exec rm -f {} + >/dev/null 2>&1
    [ -z "$agent_id" ] || exit 0
    fp=$(fingerprint) || exit 0
    : > "$dir/pending.$fp" 2>/dev/null || exit 0
    if [ "${CC_CMDS_NOTIFY_PERMISSION_SYNC:-}" = "1" ]; then
      emit_request "$fp" </dev/null >/dev/null 2>&1
    else
      { emit_request "$fp"; } </dev/null >/dev/null 2>&1 &
    fi
    ;;
  settle)
    [ -z "$agent_id" ] || exit 0
    [ -d "$dir" ] || exit 0
    fp=$(fingerprint) || exit 0
    if rm "$dir/open.$fp" 2>/dev/null; then
      mark_exact "$slot_prefix$fp"
    elif rm "$dir/pending.$fp" 2>/dev/null; then
      :
    elif rm "$dir/open.$fp" 2>/dev/null; then
      mark_exact "$slot_prefix$fp"
    fi
    ;;
  stop|prompt)
    [ -z "$agent_id" ] || exit 0
    [ -d "$dir" ] || exit 0
    found=0
    for f in "$dir"/open.* "$dir"/pending.*; do
      if [ -e "$f" ]; then
        rm -f "$f" 2>/dev/null
        found=1
      fi
    done
    if [ "$found" = 1 ]; then
      if [ "$role" = stop ]; then cause=permission-settled; else cause=return; fi
      # shellcheck source=/dev/null
      if . "$tap" >/dev/null 2>&1; then
        cc_attention_handled "$slot_prefix" "$cause" prefix
      fi
    fi
    ;;
  notification)
    nt=$(printf '%s' "$input" | jq -r '.notification_type // empty' 2>/dev/null)
    [ "$nt" = permission_prompt ] || exit 0
    if [ -f "$dir/seen" ]; then
      seen=""
      IFS= read -r seen < "$dir/seen" 2>/dev/null || true
      case "$seen" in
        ''|*[!0123456789]*) ;;
        *)
          now=$(now_ms)
          if [ $((now - seen)) -lt 10000 ]; then exit 0; fi
          ;;
      esac
    fi
    if any_exists "$dir"/agent.*; then exit 0; fi
    mkdir -p "$dir" 2>/dev/null || exit 0
    write_event "${slot_prefix}notification" "$notification_prog" || exit 0
    : > "$dir/open.notification" 2>/dev/null
    ;;
  agent-start|agent-stop)
    [[ $agent_id =~ ^[A-Za-z0-9_.-]+$ ]] || exit 0
    case "$agent_id" in
      .|..) exit 0 ;;
    esac
    if [ "$role" = agent-start ]; then
      mkdir -p "$dir" 2>/dev/null || exit 0
      : > "$dir/agent.$agent_id" 2>/dev/null
    else
      rm -f "$dir/agent.$agent_id" 2>/dev/null
    fi
    ;;
esac
exit 0
