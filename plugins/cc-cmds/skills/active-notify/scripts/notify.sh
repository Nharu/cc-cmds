#!/usr/bin/env bash
# notify.sh {arm|fire-now|cancel} [args]
# arm       <request_text> <context_hint> [mode] [--count=N]   mode: "single"|"repeat" (default "single"); --count default 1, normalize to 1 if invalid or >16
# fire-now  <workflow> <summary>                                model-driven dispatch — sub-event observation point
# cancel                                                        deletes flag regardless of mode
set -euo pipefail
# Prepend brew install paths so terminal-notifier is discoverable in fire branch
# regardless of caller PATH (Apple Silicon /opt/homebrew/bin, Intel /usr/local/bin).
# Tests that need to exercise the "binary missing" branch on a host that has
# terminal-notifier installed can set CC_CMDS_NOTIFY_PATH_DISABLE_PREPEND=1
# to skip the prepend and fully control PATH from the fixture.
if [[ -z "${CC_CMDS_NOTIFY_PATH_DISABLE_PREPEND:-}" ]]; then
  export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
fi

# Host-OS injection seam — tests inject CC_CMDS_NOTIFY_HOST_OS to drive the
# Darwin-vs-non-Darwin branches uniformly across CI legs (positive injection
# rather than a negative-framed bypass). Default = uname -s for normal use.
host_os="${CC_CMDS_NOTIFY_HOST_OS:-$(uname -s)}"

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

# Shared dispatcher invoked by the `fire-now` case branch. Caller branch
# owns the preamble: declaring consuming/tmp/lockdir in enclosing scope,
# registering the EXIT trap, and running the ARM-existence pre-check
# ([[ -f "$flag_file" ]]). Inside this function only `workflow`/`summary`
# are `local` — trap-target variables MUST stay in branch scope so the EXIT
# trap can clean them up on any exit path.
dispatch_fire() {
  local workflow="$1" summary="$2"

  # === Acquire fire-branch lock (POSIX-atomic mkdir, no external dep) ===
  # Covers schema/mode check + read-modify-write + mv. Prevents chain-reaction
  # race where one process's corrupt-flag cleanup makes other processes see
  # flag absent and silent-skip. Concurrent fires (multi-session, parallel
  # fire-now calls for armCount>1 sub-events) are serialized here.
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

  # Schema strict-equality — rejects v1.x (schema=1/2) AND future (schema>=4).
  # schema=2 was the v1.5 shape; v2.0.0+ uses schema=3 with the arm_count field.
  schema=$(grep -oE '"schema":[0-9]+' "$flag_file" | head -1 | sed 's/.*:\([0-9][0-9]*\)/\1/' || true)
  if [[ "${schema:-0}" != "3" ]]; then
    printf '[cc-cmds] active-notify: cleared stale flag (schema=%s; v2.0.0+ requires schema=3 — re-ARM to resume).\n' "${schema:-?}" >&2
    rm -f "$flag_file"; exit 0
  fi

  # Mode-validity guard — corrupt mode values (uppercase REPEAT, garbage) must
  # fail-closed at this gate to prevent fall-through into the repeat branch
  # via the != "single" comparison (would otherwise yield unbounded fire).
  # Extraction is broad ([^"]*) so corrupt values surface in stderr audit.
  flag_mode=$(grep -oE '"mode":"[^"]*"' "$flag_file" | head -1 | sed 's/.*"\([^"]*\)"$/\1/' || true)
  if [[ "$flag_mode" != "single" && "$flag_mode" != "repeat" ]]; then
    printf '[cc-cmds] active-notify: cleared flag with invalid mode (%s).\n' "${flag_mode:-<missing>}" >&2
    rm -f "$flag_file"; exit 0
  fi

  # === Mode-specific state mutation (lock-protected) ===
  # single contract: armCount-aware — intermediate fires increment fire_count
  #                  and preserve the flag (sed update); final fire (when
  #                  new_count reaches arm_count) consumes the flag (mv -n).
  # repeat contract: terminal-notifier missing → preserve flag (no mutation)
  #                  so subsequent turns can fire once binary is installed.
  if [[ "$flag_mode" == "single" ]]; then
    raw_count=$(grep -oE '"fire_count":[0-9]+' "$flag_file" | head -1 || true)
    raw_armcount=$(grep -oE '"arm_count":[0-9]+' "$flag_file" | head -1 || true)
    if [[ -z "$raw_count" || -z "$raw_armcount" ]]; then
      printf '[cc-cmds] active-notify: cleared corrupt flag (fire_count/arm_count missing or malformed).\n' >&2
      rm -f "$flag_file"; exit 0
    fi
    fire_count=$(printf '%s' "$raw_count" | sed 's/.*:\([0-9][0-9]*\)/\1/')
    arm_count=$(printf '%s' "$raw_armcount" | sed 's/.*:\([0-9][0-9]*\)/\1/')
    new_count=$(( fire_count + 1 ))
    ts=$(date -u +%s)

    if [[ "$new_count" -ge "$arm_count" ]]; then
      # Final fire — atomic consume (mv -n) ends the lifecycle.
      consuming="${flag_file}.consuming-$$"
      mv -n "$flag_file" "$consuming" 2>/dev/null || exit 0
    else
      # Intermediate fire — increment fire_count + last_fire_at, preserve flag.
      tmp="${flag_file}.tmp-$$"
      sed -E -e "s/\"fire_count\":[0-9]+/\"fire_count\":${new_count}/" \
             -e "s/\"last_fire_at\":(null|[0-9]+)/\"last_fire_at\":${ts}/" \
             "$flag_file" > "$tmp"
      mv "$tmp" "$flag_file"
      tmp=""
    fi
  else
    # repeat — preserves the flag indefinitely (until CANCEL). arm_count is
    # stored verbatim but ignored at runtime (storage shape mode-uniform,
    # runtime semantics mode-asymmetric).
    if [[ "$host_os" != "Darwin" ]]; then
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

  # === terminal-notifier dispatch ===
  if [[ "$flag_mode" == "single" ]]; then
    if [[ "$host_os" != "Darwin" ]]; then
      # Final-fire path has $consuming set; intermediate path has $consuming=""
      # (declared in outer case branch). `rm -f ""` is a safe no-op so the
      # intermediate flag mutation persists for the next fire-now call.
      rm -f "$consuming"
      exit 0
    fi
    if ! command -v terminal-notifier >/dev/null 2>&1; then
      hint="${TMPDIR:-/tmp}/cc-cmds-notify-hint"
      [[ -f "$hint" ]] || { printf '[cc-cmds] install terminal-notifier for desktop notifications\n' >&2; touch "$hint"; }
      rm -f "$consuming"
      exit 0
    fi
    notifier_args=( -title "[cc-cmds] ${workflow}" -message "${summary}" -execute ':' )
    # arm_count == 1 ↔ classic 1-shot ARM; -group "cc-cmds-active-notify" gives
    # banner replace semantics for visual parity with §7 bypass. armCount > 1
    # omits -group so each sub-event banner persists in Notification Center.
    [[ "$arm_count" -eq 1 ]] && notifier_args+=( -group "cc-cmds-active-notify" )
    terminal-notifier "${notifier_args[@]}" 2>/dev/null || true
  else
    # repeat — never -group (intentional pile-up; dynamic-trust anti-spam).
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
    # --count=N — parse-anywhere flag so existing call shapes
    # (arm <r> <c>, arm <r> <c> single, arm <r> <c> repeat) stay backward compat.
    # Out-of-bounds normalization mirrors mode normalize-to-single: invalid
    # input → default (1), no error surfaced. >16 cap stops accidental spray.
    arm_count=1
    for arg in "$@"; do
      case "$arg" in
        --count=*) arm_count="${arg#--count=}" ;;
      esac
    done
    if ! [[ "$arm_count" =~ ^[0-9]+$ ]] || [[ "$arm_count" -lt 1 || "$arm_count" -gt 16 ]]; then
      arm_count=1
    fi
    mkdir -p "$flag_dir"
    ts=$(date -u +%s)
    esc_req=$(_json_escape "$request_text")
    esc_ctx=$(_json_escape "$context_hint")
    esc_sid=$(_json_escape "$session_id")
    # Idempotent overwrite — schema:3 fresh write every ARM call. Compact JSON
    # (no whitespace after `:` or `,`) is the dispatcher's grep -oE field-read
    # assumption — hand-baked fixture flags MUST follow the same shape.
    printf '{"schema":3,"armed_at":%s,"session_id":"%s","request_text":"%s","context_hint":"%s","mode":"%s","arm_count":%s,"fire_count":0,"last_fire_at":null}\n' \
      "$ts" "$esc_sid" "$esc_req" "$esc_ctx" "$notify_mode" "$arm_count" > "$flag_file"
    exit 0
    ;;

  fire-now)
    workflow="${1:-notify}"; summary="${2:-완료}"
    # Branch-local outer scope: trap-target variables MUST stay declared here
    # (not inside dispatch_fire) — `local` inside the function would put them
    # out of scope at trap-firing time. Trap commands suffix `|| :` to swallow
    # non-zero exits under `set -euo pipefail`.
    consuming=""; tmp=""; lockdir="${flag_file}.lockdir"
    trap 'rmdir "$lockdir" 2>/dev/null || :; rm -f "${consuming:-}" "${tmp:-}" 2>/dev/null || :' EXIT
    [[ -f "$flag_file" ]] || exit 0
    dispatch_fire "$workflow" "$summary"
    exit 0
    ;;

  cancel)
    rm -f "$flag_file"
    exit 0
    ;;

  *)
    printf 'notify.sh: unknown subcommand "%s" (arm|fire-now|cancel)\n' "$subcommand" >&2
    exit 1
    ;;
esac
