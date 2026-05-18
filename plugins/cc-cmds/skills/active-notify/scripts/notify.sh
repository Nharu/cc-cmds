#!/usr/bin/env bash
# notify.sh {arm|fire|cancel} [args]
# arm  <request_text> <context_hint> [mode]   mode: "single"|"repeat", default "single"
# fire <workflow> <summary>                    branches on mode field in state flag
# cancel                                       deletes flag regardless of mode
set -euo pipefail
# Prepend brew install paths so terminal-notifier is discoverable in fire branch
# regardless of caller PATH (Apple Silicon /opt/homebrew/bin, Intel /usr/local/bin).
# Tests that need to exercise the "binary missing" branch on a host that has
# terminal-notifier installed can set CC_CMDS_NOTIFY_PATH_DISABLE_PREPEND=1
# to skip the prepend and fully control PATH from the fixture.
if [[ -z "${CC_CMDS_NOTIFY_PATH_DISABLE_PREPEND:-}" ]]; then
  export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
fi

subcommand="${1:-}"; shift || true

flag_dir="${TMPDIR:-/tmp}/cc-cmds-active-notify"
# Session ID — empirically PPID is stable across Bash tool calls (= claude process PID),
# host-environment invariant — Bash tool subshells share claude process as parent across calls.
session_id="${CLAUDE_CODE_SESSION_ID:-${CLAUDE_SESSION_ID:-claude-pid-$PPID}}"
# Filesystem-safe sanitizer — strip everything outside [A-Za-z0-9_.-].
safe_sid="${session_id//[^A-Za-z0-9_.-]/_}"
flag_file="${flag_dir}/pending-${safe_sid}.flag"

# JSON string-value escape (BSD sed compatible) — handles \ and " in user phrases.
_json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

# Shared dispatcher invoked by both `fire` (Stop-hook driven) and `fire-now`
# (model driven). Caller branches own the preamble: declaring consuming/tmp/
# lockdir in enclosing scope, registering the EXIT trap, and running their
# pre-checks (ARM-existence guard for both; milestone non-empty check for
# fire-now). Inside this function only `workflow`/`summary` are `local` —
# trap-target variables MUST stay in branch scope.
dispatch_fire() {
  local workflow="$1" summary="$2"

  # === Acquire fire-branch lock (POSIX-atomic mkdir, no external dep) ===
  # Covers schema/mode check + read-modify-write + mv. Prevents chain-reaction
  # race where one process's corrupt-flag cleanup makes other processes see
  # flag absent and silent-skip. Concurrent fires (β fallback / multi-session /
  # Stop-hook fire racing with fire-now invocation) are serialized here.
  lock_wait=0
  while ! mkdir "$lockdir" 2>/dev/null; do
    sleep 0.001
    lock_wait=$(( lock_wait + 1 ))
    # 10s timeout — dogfood scope race is rare; longer wait suggests stuck lock.
    # No force-clean: it caused chain-reaction by stealing another process's
    # lock under contention. Silent skip is acceptable trade-off.
    [[ $lock_wait -gt 10000 ]] && exit 0
  done

  # Re-check flag presence after lock acquisition (predecessor may have consumed)
  [[ -f "$flag_file" ]] || exit 0

  # Schema guard — strict equality (schema≠2 rejects both stale v1 and future v3+).
  schema=$(grep -oE '"schema":[0-9]+' "$flag_file" | head -1 | sed 's/.*:\([0-9][0-9]*\)/\1/' || true)
  if [[ "${schema:-0}" != "2" ]]; then
    printf '[cc-cmds] active-notify: cleared stale flag (schema=%s).\n' "${schema:-?}" >&2
    rm -f "$flag_file"; exit 0
  fi

  # Mode extraction is broad ([^"]*) so corrupt values surface in stderr audit;
  # validation pins to canonical lowercase set.
  flag_mode=$(grep -oE '"mode":"[^"]*"' "$flag_file" | head -1 | sed 's/.*"\([^"]*\)"$/\1/' || true)
  if [[ "$flag_mode" != "single" && "$flag_mode" != "repeat" ]]; then
    printf '[cc-cmds] active-notify: cleared flag with invalid mode (%s).\n' "${flag_mode:-<missing>}" >&2
    rm -f "$flag_file"; exit 0
  fi

  # === State mutation + mode-specific contracts (lock-protected) ===
  # single-mode contract: mv -n ALWAYS consumes the flag (1-shot intent),
  #                       even if terminal-notifier later missing (hint sentinel only).
  # repeat-mode contract: terminal-notifier missing → preserve flag (no mutation)
  #                       so subsequent turns can fire once binary is installed.
  if [[ "$flag_mode" == "single" ]]; then
    consuming="${flag_file}.consuming-$$"
    mv -n "$flag_file" "$consuming" 2>/dev/null || exit 0
  else
    if [[ "$(uname -s)" != "Darwin" ]]; then
      exit 0   # preserve flag (non-macOS host)
    fi
    if ! command -v terminal-notifier >/dev/null 2>&1; then
      hint="${TMPDIR:-/tmp}/cc-cmds-notify-hint"
      [[ -f "$hint" ]] || { printf '[cc-cmds] install terminal-notifier for desktop notifications\n' >&2; touch "$hint"; }
      exit 0   # preserve flag for next turn
    fi
    raw_count=$(grep -oE '"fire_count":[0-9]+' "$flag_file" | head -1 || true)
    raw_last=$(grep -oE '"last_fire_at":(null|[0-9]+)' "$flag_file" | head -1 || true)
    if [[ -z "$raw_count" || -z "$raw_last" ]]; then
      printf '[cc-cmds] active-notify: cleared corrupt flag (fire_count/last_fire_at missing or malformed).\n' >&2
      rm -f "$flag_file"; exit 0
    fi
    fire_count=$(printf '%s' "$raw_count" | sed 's/.*:\([0-9][0-9]*\)/\1/')
    fire_count=$(( fire_count + 1 ))
    ts=$(date -u +%s)
    tmp="${flag_file}.tmp-$$"
    sed -E -e "s/\"fire_count\":[0-9]+/\"fire_count\":${fire_count}/" \
           -e "s/\"last_fire_at\":(null|[0-9]+)/\"last_fire_at\":${ts}/" \
           "$flag_file" > "$tmp"
    mv "$tmp" "$flag_file"
    tmp=""
  fi

  # === Release lock BEFORE terminal-notifier (minimize hold time) ===
  rmdir "$lockdir" 2>/dev/null || :

  if [[ "$flag_mode" == "single" ]]; then
    if [[ "$(uname -s)" != "Darwin" ]]; then
      rm -f "$consuming"
      exit 0
    fi
    if ! command -v terminal-notifier >/dev/null 2>&1; then
      hint="${TMPDIR:-/tmp}/cc-cmds-notify-hint"
      [[ -f "$hint" ]] || { printf '[cc-cmds] install terminal-notifier for desktop notifications\n' >&2; touch "$hint"; }
      rm -f "$consuming"
      exit 0
    fi
    terminal-notifier \
      -title "[cc-cmds] ${workflow}" \
      -message "${summary}" \
      -group "cc-cmds-active-notify" \
      -execute ':' \
      2>/dev/null || true
    rm -f "$consuming"
  else
    terminal-notifier \
      -title "[cc-cmds] ${workflow}" \
      -message "${summary}" \
      -execute ':' \
      2>/dev/null || true
  fi
}

case "$subcommand" in
  arm)
    request_text="${1:-}"; context_hint="${2:-}"; notify_mode="${3:-single}"
    [[ "$notify_mode" == "single" || "$notify_mode" == "repeat" ]] || notify_mode="single"
    # --milestone="<phrase>" — parse-anywhere flag so existing call shapes
    # (arm <r> <c>, arm <r> <c> single, arm <r> <c> repeat) stay backward compat.
    milestone=""
    for arg in "$@"; do
      case "$arg" in
        --milestone=*) milestone="${arg#--milestone=}" ;;
      esac
    done
    mkdir -p "$flag_dir"
    ts=$(date -u +%s)
    esc_req=$(_json_escape "$request_text")
    esc_ctx=$(_json_escape "$context_hint")
    esc_sid=$(_json_escape "$session_id")
    esc_milestone=$(_json_escape "$milestone")
    # Idempotent overwrite — schema:2 fresh write every ARM call. milestone
    # field is always written (even empty) so a prior cycle's value cannot
    # survive into the new cycle via absent-field semantics.
    printf '{"schema":2,"armed_at":%s,"session_id":"%s","request_text":"%s","context_hint":"%s","mode":"%s","milestone":"%s","fire_count":0,"last_fire_at":null}\n' \
      "$ts" "$esc_sid" "$esc_req" "$esc_ctx" "$notify_mode" "$esc_milestone" > "$flag_file"
    exit 0
    ;;

  fire)
    workflow="${1:-notify}"; summary="${2:-완료}"
    # Branch-local outer scope: trap-target variables MUST stay declared here
    # (not inside dispatch_fire) — `local` inside the function would put them
    # out of scope at trap-firing time. Trap commands suffix `|| :` to swallow
    # non-zero exits under `set -euo pipefail`.
    consuming=""; tmp=""; lockdir="${flag_file}.lockdir"
    trap 'rmdir "$lockdir" 2>/dev/null || :; rm -f "${consuming:-}" "${tmp:-}" 2>/dev/null || :' EXIT
    [[ -f "$flag_file" ]] || exit 0                     # no ARM → silent no-op
    dispatch_fire "$workflow" "$summary"
    exit 0
    ;;

  fire-now)
    workflow="${1:-notify}"; summary="${2:-완료}"
    # Same branch-local trap discipline as `fire` — see comment above.
    consuming=""; tmp=""; lockdir="${flag_file}.lockdir"
    trap 'rmdir "$lockdir" 2>/dev/null || :; rm -f "${consuming:-}" "${tmp:-}" 2>/dev/null || :' EXIT
    [[ -f "$flag_file" ]] || exit 0                     # no ARM → silent no-op
    # milestone gate — model-driven dispatch is only allowed when the user's
    # ARM-time phrase included a specific milestone. Generic ARM (empty
    # milestone) silently no-ops with an audit-log entry so misclassification
    # at the call site is absorbed structurally.
    milestone=$(jq -r '.milestone // empty' "$flag_file" 2>/dev/null || true)
    if [[ -z "$milestone" ]]; then
      printf '[%s] fire-now invoked with empty milestone (silent no-op)\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        >> "$flag_dir/audit.log" 2>/dev/null || true
      exit 0
    fi
    dispatch_fire "$workflow" "$summary"
    exit 0
    ;;

  cancel)
    rm -f "$flag_file"
    exit 0
    ;;

  *)
    printf 'notify.sh: unknown subcommand "%s" (arm|fire|fire-now|cancel)\n' "$subcommand" >&2
    exit 1
    ;;
esac
