# Active Notify (Shared Procedure)

Model-invoked best-effort macOS notification helper.
Single (mode=single) or per-turn repeat (mode=repeat) lifecycle.
ARM → FIRE(s) → CANCEL/consume.

## §1 Preconditions (guard chain — all checked before fire)
  1. ARM flag absent → silent no-op (FIRE without prior ARM blocked).
  2. Corrupt-flag cleanup: schema≠2 (stale v1 from pre-v3 OR any future schema≥3
     per strict-equality policy) OR mode field empty/invalid (`mode` not in
     {single, repeat}) OR field-shape mismatch (repeat-mode fire_count /
     last_fire_at missing or non-numeric) → stderr hint + flag delete + exit 0.
     User re-arms naturally via the next first-person notification request.
  3. Host OS ≠ Darwin → silent skip. Single-mode: consume flag (1-shot
     intent — cycle terminates even when notifier did not fire). Repeat-mode:
     preserve flag (user may retry from a Darwin host on a subsequent turn).
     Implementation: `host_os="${CC_CMDS_NOTIFY_HOST_OS:-$(uname -s)}"` —
     `CC_CMDS_NOTIFY_HOST_OS` is the test-injection seam (positive
     injection: `=Darwin` or `=Linux`); default `uname -s` covers normal use.
  4. `terminal-notifier` missing → once-per-TMPDIR-lifetime stderr hint via
     `${TMPDIR}/cc-cmds-notify-hint` sentinel, then silent skip. Single-mode:
     consume flag (same 1-shot intent). Repeat-mode: preserve flag (user
     installs the binary and the next turn fires automatically).
     # Rationale: single's consume-on-skip asymmetry is intentional —
     # "ARM → one FIRE → cycle ends" is the single-mode lifecycle contract.
     # On setup error the user notices via missing banner and re-ARMs to
     # resume. Repeat is inherently multi-turn so preserve is the natural fit.

## §2 Notification fire
  Banner copy synthesis has a three-tier fallback chain under v1.5.0.
    The Stop hook scrapes the assistant text blocks of the turn slice
    for a marker `<!--cc-active-notify workflow="..." summary="..." -->`
    (last occurrence wins, multi-step bleed fence; workflow ≤ 120 bytes,
    summary ≤ 360 bytes, byte-cap for UTF-8 safety). Priority:
      1. Marker `workflow` / `summary` when present (model-declared,
         authoritative).
      2. Bash fallback — `workflow` = first non-cd token of the last
         Bash command, `summary` = binary from last tool_result's
         `is_error` (`성공` / `실패`).
      3. Generic fallback — `workflow` = `task`, `summary` = `완료`
         for non-Bash terminal turns.
    Banner title is `[cc-cmds] ${workflow}` and body is `${summary}`.

    Model-driven sub-turn fire via `notify.sh fire-now <workflow>
    <summary>` is the model's only dispatch surface; it inherits the
    same dispatcher (lockdir / schema / mode-aware mutation) and is
    gated by ARM-time `--milestone` (empty → silent no-op + audit
    log). Stop hook detects fire-now invocations in the turn slice
    and dedups. Detailed bypass mechanics (Rule 2 / Rule 3 marker-
    conditioned bypass with audit-log fail-closed) are documented in
    active-notify SKILL.md §6.2 (positive companion bullet).

  mode=single: `terminal-notifier` invoked with
    `-group "cc-cmds-active-notify"` (single banner replaces previous;
    irrelevant in practice since the lifecycle is 1-shot, but kept for
    parity with the permission-test bypass path so banner surfaces share
    visual identity in the single + bypass overlap window) and
    `-execute ':'` (shell true-builtin no-op click target — see §4
    invariant 2). Flag is consumed atomically via `mv -n` before fire.
  mode=repeat: `terminal-notifier` invoked WITHOUT `-group` and with
    `-execute ':'` — each fire produces a separate banner (pile-up is
    intentional, dynamic-trust anti-spam: user perceives spam →
    CANCEL). `fire_count` is incremented and `last_fire_at` updated
    atomically via temp-write → mv rename; the flag is preserved until
    explicit CANCEL.

## §3 Failure handling
  Failure handling differs across the two invocation surfaces.

  **Model-side ARM/CANCEL** (Bash dispatch via `notify.sh arm` /
  `notify.sh cancel`): silent skip with respect to the user-visible
  response stream. `AskUserQuestion` is never called. No user-addressed
  narration. No assistant response stream logging. Stderr-only diagnostic
  hints follow two distinct dedup policies: (a) terminal-notifier missing
  → sentinel-guarded once-per-TMPDIR-lifetime via
  `${TMPDIR}/cc-cmds-notify-hint`; (b) corrupt-flag (schema/mode/
  field-shape mismatch) → once-per-corrupt-event, self-healed via
  `rm -f flag` so the trigger condition never repeats for the same flag
  (no sentinel needed). Neither is ever surfaced to the user.

  **Hook-side FIRE** (Stop hook shells out to `notify.sh fire`): any
  internal hook error (missing `jq`, unset `CLAUDE_PLUGIN_ROOT`,
  malformed transcript JSON, etc.) results in silent fail-open — the
  hook exits 0 with empty stdout, deferring to the default permission
  gate behavior. No stderr noise is surfaced to the user; the file-based
  `${flag_dir}/audit.log` captures β safety-net selections for forensic
  inspection. Once inside `notify.sh fire`, the same model-side stderr
  hint policy applies for terminal-notifier-missing / corrupt-flag.

  Permission-test bypass path (model-direct `terminal-notifier` invocation
  per SKILL.md body §7) is governed by a separate user-narration contract
  — this §3 scope does not extend to the bypass path. Bypass path
  contract: precondition fail → user-visible Korean guidance message via
  combined-Bash stdout (first-run UX immediate-feedback requirement).

## §4 Control-Flow Invariants
  1. **Preconditions fail-open.** ARM flag absent, corrupt-flag (schema≠2
     strict equality / mode invalid / field-shape mismatch), Host OS ≠
     Darwin, and `terminal-notifier` missing all silent-skip.
     terminal-notifier-missing emits a once-per-TMPDIR-lifetime stderr
     install hint via the TMPDIR sentinel; the path never transitions to
     silent failure. Corrupt-flag emits an stderr audit hint + flag `rm`
     + exit 0 (auto-cleanup; self-heals on the first hit so no sentinel
     is needed). The schema check is strict equality — both stale
     `schema:1` and future `schema:3+` flags fall through to the
     cleanup branch (clean break, no mid-version syntax compatibility).
     PATH prepend (`/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:
     $PATH`) precedes this invariant chain as an implicit prerequisite
     so `terminal-notifier` discovery is consistent across Apple Silicon
     and Intel Homebrew layouts; the prepend is process-global within
     `notify.sh` but has zero functional impact on standard utilities
     (`grep`/`sed`/`mv`/`rm` still resolve from `/usr/bin/`).
  2. **terminal-notifier invocation is fire-and-forget.** The shell call
     is wrapped in `2>/dev/null || true`. The caller does not inspect
     exit code, does not await OS-level delivery, does not retry on
     failure. Missed notification is acceptable; a halted workflow is
     not. Click-through is intentionally functionless: the
     `terminal-notifier -execute ':'` shell true-builtin no-op is
     supplied so that macOS Notification Center's auto-attached action
     button (which cannot be suppressed via terminal-notifier 2.0.0 CLI
     flags) clicks through to nothing observable. The fundamental "no
     button" path is tracked as a roadmap item (custom UN-API binary).
  3. **Invocation is strictly additive across both surfaces.** Two
     surfaces invoke `notify.sh`: the model invokes ARM and CANCEL via
     Bash tool calls, and the Stop hook invokes FIRE at turn end. Both
     surfaces' invocations complete with success or silent skip — they
     never block or modify the caller workflow, and neither retries on
     failure. Single-mode FIRE consumes the flag after one fire;
     repeat-mode FIRE preserves the flag and increments `fire_count`
     per turn end, relying on user-issued CANCEL (no anti-spam guard
     — dynamic-trust model). ARM and CANCEL are local-disk file ops
     only and naturally non-blocking. The permission-test bypass path
     invokes `terminal-notifier` directly (not via `notify.sh`); the
     same fire-and-forget contract applies, with user-visible Korean
     guidance via combined-Bash stdout as a deliberate exception per
     SKILL.md §7.
