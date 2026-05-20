# Active Notify (Shared Procedure)

Model-invoked best-effort macOS notification helper.
Single (mode=single) or per-turn repeat (mode=repeat) lifecycle.
ARM → FIRE-NOW(s) → CANCEL/consume.

## §1 Preconditions (guard chain — all checked before fire)
  1. ARM flag absent → silent no-op (fire-now without prior ARM blocked).
  2. Corrupt-flag cleanup: schema≠3 strict equality (stale v1.x schema:1
     or schema:2 OR any future schema≥4 — clean break, no mid-version
     compat) OR mode field empty/invalid (`mode` not in {single, repeat})
     OR mode-specific field-shape mismatch (single: `fire_count` /
     `arm_count` missing or non-numeric; repeat: `fire_count` /
     `last_fire_at` missing or malformed) → stderr hint + flag delete +
     exit 0. User re-arms naturally via the next first-person notification
     request.
  3. Host OS ≠ Darwin → silent skip. Single armCount=1 / single final
     fire (intermediate threshold reached): consume flag (1-shot intent —
     cycle terminates even when notifier did not fire). Single
     intermediate fire (armCount>1, fire_count < arm_count): preserve
     intermediate-incremented flag so the next fire-now finds it. Repeat-
     mode: preserve flag (user may retry from a Darwin host on a
     subsequent turn).
     Implementation: `host_os="${CC_CMDS_NOTIFY_HOST_OS:-$(uname -s)}"` —
     `CC_CMDS_NOTIFY_HOST_OS` is the test-injection seam (positive
     injection: `=Darwin` or `=Linux`); default `uname -s` covers normal
     use.
  4. `terminal-notifier` missing → once-per-TMPDIR-lifetime stderr hint
     via `${TMPDIR}/cc-cmds-notify-hint` sentinel, then silent skip.
     Same fire-position-aware flag-handling as guard 3 (final fire
     consumes; intermediate / repeat preserve).
     # Rationale: single's consume-on-skip asymmetry for final fire is
     # intentional — "ARM → one final FIRE → cycle ends" is the lifecycle
     # contract. On setup error the user notices via missing banner and
     # re-ARMs to resume. Repeat is inherently multi-turn so preserve is
     # the natural fit. Intermediate fires also preserve so multi-event
     # cycles survive transient non-Darwin / missing-notifier states.

## §2 Notification fire
  fire-now is the **only** dispatch surface — model-driven, called at
  each sub-event observation point. Banner copy is supplied verbatim
  via the `<workflow>` and `<summary>` positional arguments — no
  transcript scrape, no marker mechanism, no Bash-tool-result fallback.

    Banner title is `[cc-cmds] ${workflow}` and body is `${summary}`.

  mode=single, armCount=1: terminal-notifier invoked with
    `-group "cc-cmds-active-notify"` (banner replaces previous; visual
    parity with the §7 permission-test bypass path) and `-execute ':'`
    (shell true-builtin no-op click target — see §4 invariant 2). Flag
    is consumed atomically via `mv -n` on the (only) fire.
  mode=single, armCount=N (N>1): terminal-notifier invoked WITHOUT
    `-group` (each named sub-event banner persists independently in
    Notification Center; armCount>1 expresses N distinct events that
    must not replace each other). Intermediate fires increment
    `fire_count` and update `last_fire_at` via temp-write → mv rename;
    final fire (fire_count + 1 == arm_count) atomically consumes via
    `mv -n`.
  mode=repeat: terminal-notifier invoked WITHOUT `-group` (intentional
    pile-up; dynamic-trust anti-spam — user perceives spam → CANCEL).
    `fire_count` is incremented and `last_fire_at` updated atomically
    via temp-write → mv rename; the flag is preserved until explicit
    CANCEL. `arm_count` field is stored verbatim at ARM time but
    ignored at runtime (mode-asymmetric semantics).

## §3 Failure handling
  All notify.sh surfaces (`arm`, `fire-now`, `cancel`) are model-side
  Bash dispatches. Silent skip with respect to the user-visible response
  stream is the default contract — `AskUserQuestion` is never called,
  no user-addressed narration, no assistant response stream logging.

  Stderr-only diagnostic hints follow two distinct dedup policies:

  - **terminal-notifier missing** → sentinel-guarded once-per-TMPDIR-
    lifetime via `${TMPDIR}/cc-cmds-notify-hint`.
  - **Corrupt-flag** (schema/mode/field-shape mismatch) → once-per-
    corrupt-event, self-healed via `rm -f flag` so the trigger condition
    never repeats for the same flag (no sentinel needed). Four mutually
    exclusive messages per the guard pipeline: `stale flag (schema=N;
    v2.0.0+ requires schema=3 — re-ARM to resume)` / `invalid mode (X)`
    / `corrupt flag (fire_count/arm_count missing or malformed)` /
    `corrupt flag (fire_count/last_fire_at missing or malformed)`.

  Neither stderr hint is ever surfaced to the user.

  Permission-test bypass path (model-direct `terminal-notifier`
  invocation per SKILL.md body §7) is governed by a separate user-
  narration contract — this §3 scope does not extend to the bypass
  path. Bypass path contract: precondition fail → user-visible Korean
  guidance message via combined-Bash stdout (first-run UX immediate-
  feedback requirement).

## §4 Control-Flow Invariants
  1. **Preconditions fail-open.** ARM flag absent, corrupt-flag
     (schema≠3 strict equality / mode invalid / mode-specific field-
     shape mismatch), Host OS ≠ Darwin, and `terminal-notifier` missing
     all silent-skip. terminal-notifier-missing emits a once-per-TMPDIR-
     lifetime stderr install hint via the TMPDIR sentinel; the path
     never transitions to silent failure. Corrupt-flag emits an stderr
     audit hint + flag `rm` + exit 0 (auto-cleanup; self-heals on the
     first hit so no sentinel is needed). The schema check is strict
     equality — stale `schema:1`/`schema:2` and future `schema:4+` flags
     all fall through to the cleanup branch (clean break, no mid-version
     syntax compatibility). v1.x users with live ARM at upgrade time
     experience silent flag loss on first fire-now and re-ARM naturally
     on the next notification request (documented in CHANGELOG).
     PATH prepend (`/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:
     $PATH`) precedes this invariant chain as an implicit prerequisite
     so `terminal-notifier` discovery is consistent across Apple Silicon
     and Intel Homebrew layouts.
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
  3. **Single dispatch surface — model-driven, no Stop hook.** All
     notify.sh invocations originate from the model: ARM, fire-now, and
     CANCEL. There is no hook-driven turn-end auto-fire. fire-now is
     called at each sub-event observation point as the model evaluates
     §4 of SKILL.md (when-to-invoke criteria). Single mode is armCount-
     aware: intermediate fires (fire_count + 1 < arm_count) increment
     and preserve; final fire (fire_count + 1 == arm_count) atomically
     consumes via `mv -n`. `-group "cc-cmds-active-notify"` is applied
     only when single + arm_count == 1 (banner replace semantics for
     visual parity with §7 bypass). Repeat is unbounded — preserves
     flag and increments `fire_count` on every fire-now, terminates
     only on user-issued CANCEL (no anti-spam guard — dynamic-trust
     model). ARM and CANCEL are local-disk file ops only and naturally
     non-blocking. The permission-test bypass path invokes
     `terminal-notifier` directly (not via `notify.sh`); the same
     fire-and-forget contract applies, with user-visible Korean
     guidance via combined-Bash stdout as a deliberate exception per
     SKILL.md §7.
