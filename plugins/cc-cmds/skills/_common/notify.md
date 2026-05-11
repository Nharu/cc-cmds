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
  3. `uname -s` ≠ Darwin → silent skip. Single-mode: consume flag (1-shot
     intent — cycle terminates even when notifier did not fire). Repeat-mode:
     preserve flag (user may retry from a Darwin host on a subsequent turn).
  4. `terminal-notifier` missing → once-per-TMPDIR-lifetime stderr hint via
     `${TMPDIR}/cc-cmds-notify-hint` sentinel, then silent skip. Single-mode:
     consume flag (same 1-shot intent). Repeat-mode: preserve flag (user
     installs the binary and the next turn fires automatically).
     # Rationale: single's consume-on-skip asymmetry is intentional —
     # "ARM → one FIRE → cycle ends" is the single-mode lifecycle contract.
     # On setup error the user notices via missing banner and re-ARMs to
     # resume. Repeat is inherently multi-turn so preserve is the natural fit.

## §2 Notification fire
  No `-execute` flag (notification-only; no click-through action).
  Banner copy synthesis: `workflow` = short English task identifier
    (≤30 chars, internal ID — kept in English for log/tooling stability),
    `summary` = 1-line user-facing message in Korean (banner body is read by
    the user; Korean per primary audience). Multi-stage turns prefer the
    terminal-stage outcome (last build/test/lint result) over aggregate
    wording. Non-Bash-terminal turns (Read/Edit/Grep) use a 1-line semantic
    Korean summary of turn intent (e.g. "파일 업데이트 완료", "리뷰 마침",
    "컨텍스트 로드 완료"); never empty (minimum "완료"). This synthesis
    guidance is duplicated here intentionally — SKILL.md body may be
    truncated after context compaction, while this fresh-read surface
    persists.
  mode=single: `terminal-notifier` invoked with
    `-group "cc-cmds-active-notify"` (single banner replaces previous;
    irrelevant in practice since the lifecycle is 1-shot, but kept for
    parity with the permission-test bypass path so banner surfaces share
    visual identity in the single + bypass overlap window). Flag is
    consumed atomically via `mv -n` before fire.
  mode=repeat: `terminal-notifier` invoked WITHOUT `-group` — each fire
    produces a separate banner (pile-up is intentional, dynamic-trust
    anti-spam: user perceives spam → CANCEL). `fire_count` is incremented
    and `last_fire_at` updated atomically via temp-write → mv rename; the
    flag is preserved until explicit CANCEL.

## §3 Failure handling
  All `notify.sh` failures (ARM/FIRE/CANCEL paths) are silent skip with
  respect to the user-visible response stream. `AskUserQuestion` is never
  called. No user-addressed narration. No assistant response stream
  logging. Stderr-only diagnostic hints follow two distinct dedup policies:
  (a) terminal-notifier missing → sentinel-guarded once-per-TMPDIR-lifetime
  via `${TMPDIR}/cc-cmds-notify-hint`; (b) corrupt-flag (schema/mode/
  field-shape mismatch) → once-per-corrupt-event, self-healed via
  `rm -f flag` so the trigger condition never repeats for the same flag
  (no sentinel needed). Neither is ever surfaced to the user via
  `AskUserQuestion` or assistant message. (active-notify is a
  model-invocable helper, not a TeamCreate-based skill, so the
  agent-team-protocol Surface Discipline rule does not apply directly;
  the analogous "no failure surfaces user-visible" invariant is enforced
  locally here.)

  Permission-test bypass path (model-direct `terminal-notifier` invocation
  per SKILL.md body §7) is governed by a separate user-narration contract
  — this §3 scope does not extend to the bypass path. Bypass path
  contract: precondition fail → user-visible Korean guidance message via
  combined-Bash stdout (first-run UX immediate-feedback requirement).

## §4 Control-Flow Invariants
  1. **Preconditions fail-open.** ARM flag absent, corrupt-flag (schema≠2
     strict equality / mode invalid / field-shape mismatch), `uname -s` ≠
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
     not. Click-through is unsupported (notification-only; `-execute`
     option unused).
  3. **Model invocation is strictly additive.** Whether the model invokes
     ARM, FIRE, or CANCEL, the procedure completes with success or
     silent skip — never blocks or modifies the caller workflow. The
     model never retries on failure. Single-mode FIRE consumes the flag
     after one fire; repeat-mode FIRE preserves the flag and increments
     `fire_count` per turn end, relying on user-issued CANCEL (no
     anti-spam guard — dynamic-trust model). ARM and CANCEL are
     local-disk file ops only and naturally non-blocking.
