---
name: active-notify
description: 사용자가 (a) 1인칭 알림 요청 어휘 ("끝나면 알려줘"/"매번 알려줘" 등) 또는 (b) 권한 테스트 어휘 ("알림 테스트"/"test alert"/"permission test" 등 — 알림 동사 + "테스트"/"test" 결합)를 발화했을 때 호출되는 macOS 데스크탑 알림 헬퍼. (a)는 작업 완료 시점에 ARM 후 fire (단발/반복 모드 lifecycle), (b)는 §7 inline bypass를 정해진 형식 그대로 호출하여 권한 다이얼로그 1회 트리거. 트리거 어휘 부재 시 호출 금지 — 모델 자체 판단으로 ARM/bypass 절대 금지.
when_to_use: |
    **사전 분기 — PERMISSION TEST 예외 (1순위)**: 사용자 발화가 "테스트"/"test" 키워드 + 알림 동사("알림"/"노티"/"notif"/"alert" 등)를 결합한 형태("알림 테스트", "노티 테스트 한 번", "test the alert", "permission test")이면 ARM 대신 §7 inline bypass의 multi-line shell expression을 **변경 없이 그대로** Bash로 호출. `-group 'cc-cmds-active-notify'` 토큰 보존 필수 (다른 group 이름·다른 message·다른 title로 자체 합성 금지). notify.sh 우회. 일반 1인칭 알림 발화로 오인 분기 금지.

    **ARM 분기 (사전 분기 미해당 시)**: 사용자가 1인칭 알림 요청 어휘를 명시적으로 발화한 직후 ARM. 발화에 매·마다·매번·각·반복·every·each 키워드가 1개라도 등장하면 repeat 모드 (매 turn 종료 시 fire), 부재 시 single 모드 (1회 fire 후 만료). ARM 직후 즉시 fire는 금지 — fire는 ARM과 별개의 task-completion rule 평가 (single 4-rule, repeat 3-rule)를 받으며, 같은 turn에 user-task tool call이 ≥1 발생해야 fire 가능 (notify.sh 자체 호출은 카운트 제외). 모델 자체 판단 ("이 작업이 길어 보이니 알림이 좋겠다", "사용자가 각 step별 진행을 보고 싶어할 듯") ARM은 절대 금지. canonical lexicon · worked example · 4-rule variant · anti-pattern · permission test bypass는 SKILL.md body 참조.
disable-model-invocation: false
usage: "(자동 호출 — 슬래시 커맨드 없음. 사용자가 1인칭 알림 요청 어휘 발화 후 모델이 ARM, 단발 모드는 1회 fire 후 만료, 반복 모드는 매 turn 종료 시 fire(CANCEL까지).)"
options: []
notes: |
    cc-cmds 최초의 model-invoked 헬퍼이며 슬래시 커맨드 surface가 없다. 모델은 frontmatter
    `description` + `when_to_use`로 호출 결정을 내리고, SKILL.md body의 ARM/FIRE/CANCEL contract +
    canonical lexicon (단발·반복·취소)에 따라 모드를 선택한다. macOS 외 / `terminal-notifier`
    미설치 환경은 silent no-op. 최초 사용 전 macOS 알림 권한 승인 필요 — "알림 테스트 한 번 해줘"
    발화로 권한 다이얼로그 트리거.
---

# active-notify

Read `_common/notify.md` once per session to load the shared procedure
(preconditions, fire copy synthesis, failure handling, Control-Flow
Invariants). The model is responsible for ARM and CANCEL only — FIRE
is dispatched by the plugin's Stop hook at every assistant-turn end.
The plugin's PreToolUse hook self-approves the dispatcher's Bash
invocations so the Bash permission dialog never surfaces.

## 1. Calling convention

The model directly invokes two subcommands of
`active-notify/scripts/notify.sh`. FIRE is **not model-callable** —
the Stop hook (`hooks/active-notify-stop.sh`) owns FIRE dispatch at
turn end. All paths are absolute; the shell working directory does
not matter; both subcommands are local-disk file ops and complete
instantly.

```bash
# Arm a new notification cycle. mode argument is optional (default "single").
bash active-notify/scripts/notify.sh arm "<request_text>" "<context_hint>" [single|repeat]

# Cancel — mode-agnostic flag delete.
bash active-notify/scripts/notify.sh cancel
```

Argument order for `arm`: `request_text` first (verbatim user phrase that
triggered ARM), `context_hint` second (short summary of the user-asked
task — e.g. "build", "design-review iteration"), optional `mode` third.
Invalid mode values (anything other than `single`/`repeat`) silent
normalize to `single`.

**FIRE is harness-driven.** At every assistant-turn end Claude Code
invokes the registered Stop hook, which:

1. Verifies session isolation via the hook stdin `session_id` field
   (β safety-net: newest-flag fallback with file-based audit log at
   `${flag_dir}/audit.log` — not stderr).
2. Evaluates the task-completion rules (§4) by scanning the
   transcript JSONL for user-task tool calls and the turn-terminal
   tool block.
3. Shells out to `notify.sh fire <workflow> <summary>` if the rules
   pass, where `<workflow>` is the first non-cd token of the last
   Bash command (fallback `task` for non-Bash terminal turns) and
   `<summary>` is a binary derived from the last tool_result's
   `is_error` field — `성공` (is_error=false), `실패` (is_error=true),
   or `완료` (non-Bash terminal turn).

The model **does not** participate in workflow/summary synthesis under
v1.5.0. A v1.5.x roadmap introduces an opt-in marker
(`<!--notify-summary: ... -->` in the response body) that the hook
scrapes for richer banner copy.

Banner title is always `[cc-cmds] ${workflow}` (English task ID) and
body is `${summary}` (Korean user message).

## 2. Trigger lexicon (canonical)

The model decides ARM/FIRE/CANCEL based on user phrasing. Only the
canonical patterns below trigger; everything else is anti-pattern (see
§6).

**ARM (single mode)** — first-person + imperative + notification noun
+ action verb + (optional) timing marker. No `매`/`마다`/`매번`/`각`/
`반복`/`every`/`each` keyword. Examples:
- 한국어: `"끝나면 알려줘"`, `"알림 줘"`, `"노티 한 번 쏴줘 끝나면"`,
  `"이거 끝날 때 알림 보내줘"`
- 영어: `"ping me when this finishes"`, `"let me know when done"`,
  `"notify me when the build completes"`

**ARM (repeat mode)** — same shape as ARM single PLUS at least one of
`매`/`마다`/`매번`/`각`/`반복`/`every`/`each`. Examples:
- 한국어: `"매 커맨드 끝날 때마다 알려줘"`, `"각 단계마다 알림 줘"`,
  `"매번 작업 끝나면 노티 줘"`
- 영어: `"every time a command finishes ping me"`, `"each time a step
  finishes, ping me"`

**CANCEL (mode-agnostic)** — explicit revocation. Examples:
- 한국어: `"알림 취소"`, `"알림 그만"`, `"노티 그만"`,
  `"알림 멈춰"`, `"반복 알림 그만"`
- 영어: `"cancel notification"`, `"stop the alerts"`,
  `"nevermind on the ping"`

**PERMISSION TEST (special — bypass path, NOT an ARM lexicon)** — the
word `"테스트"`/`"test"` combined with a notification verb fences ARM
entirely. Examples that trigger the bypass:
- 한국어: `"알림 테스트"`, `"노티 테스트"`, `"알림 테스트 한 번 해줘"`
- 영어: `"test the alert"`, `"permission test"`

The bypass invokes `terminal-notifier` directly via Bash (see §7) —
**no `notify.sh arm` call**, **no state file mutation**.

**Disambiguator**: `"끝날 때"` is a single-mode timing marker;
`"끝날 때마다"` switches to repeat because `마다` is present.
`"매 커밋 후 알려"` → `매` keyword present → repeat (regardless of
whether the timing marker is `후` or `끝나면`). Hybrid utterances
like `"매번 알림 테스트"` route to the bypass path because the
`"테스트"`/`"test"` fence dominates.

## 3. ARM / FIRE / CANCEL semantics

**ARM is always idempotent overwrite (model-driven).** Each
`notify.sh arm` invocation performs a `schema:2` fresh JSON write
that replaces any prior flag. Consequences:
- **Mode switch** (single ↔ repeat) — the new ARM discards the prior
  cycle's `fire_count` and `last_fire_at`.
- **Re-ARM after CANCEL** — opens a new cycle from `fire_count: 0`.
- **Same-mode re-ARM** — JSON regenerated; `fire_count` reset to 0.
- **Invalid mode argument** (e.g. `continuous`, `REPEAT`) silently
  normalizes to `single`. This ARM-side leniency is intentionally
  asymmetric with the FIRE-side strict-reject policy: ARM input
  originates from the model (canonicalization drift is forgiving),
  while FIRE input originates from disk (treated as untrusted state).

**FIRE is dispatcher behavior, triggered by the Stop hook.** The
Stop hook evaluates §4 rules at turn end and shells out to
`notify.sh fire <workflow> <summary>`. The dispatcher then branches
on the stored `mode` field. Single-mode consumes the flag (atomic
`mv -n` rename to `*.consuming-$$`, then optional notifier call,
then `rm`). Repeat-mode preserves the flag and performs an atomic
`temp → mv` rename to bump `fire_count` and refresh `last_fire_at`.
The model **never** invokes FIRE directly; even an erroneous fire
invocation would have its Bash dialog auto-approved by the
PreToolUse hook but would still be redundant and is not a part of
this contract.

**CANCEL is mode-agnostic (model-driven).** `rm -f flag`. No mode
check. Lexicon covers both generic (`"알림 취소"`) and repeat-specific
(`"반복 알림 그만"`) phrasings — same effect.

## 4. Task-completion rules (hook-evaluated)

The Stop hook evaluates these rules at every turn end and invokes
`notify.sh fire` if all conditions hold. The model does NOT
evaluate these rules — they are documented here so the model-side
ARM decision is informed and so the contract is transparent to
humans reading SKILL.md.

### Single mode (3 effective conditions, all must hold)

1. ARM flag is alive and `mode=single`.
2. The current turn's assistant block has executed ≥1 user-task
   tool call from the 11-tool whitelist (Bash, Read, Edit, Write,
   Grep, Glob, WebFetch, WebSearch, Task, MultiEdit, NotebookEdit)
   that is NOT an `active-notify/scripts/notify.sh` invocation.
   Meta-tools (TodoWrite, ExitPlanMode, AskUserQuestion) are
   excluded — they signal planning or user-input suspension, not
   task work.
3. The turn-terminal tool block is NOT `AskUserQuestion`. (Stop
   hook will not fire after an `AskUserQuestion` because the
   harness suspends the turn waiting for user input — natural
   belt-and-braces guard on top of the explicit check.)

When all three hold, the hook shells `notify.sh fire`. The
single-mode flag is consumed atomically inside the existing
`notify.sh` fire branch (unchanged from v1.4.x semantics).

### Repeat mode (3 effective conditions)

Identical conditions 1–3, but condition 1 requires `mode=repeat`.
Repeat-mode FIRE preserves the flag and increments `fire_count`;
cycle terminates only on user-issued CANCEL.

### Helper-script exclusion (hook-side)

Rule 2 is enforced by the hook's transcript-scan regex anchor:

```
test("active-notify/scripts/notify\\.sh\\s+(arm|fire|cancel)\\b") | not
```

This excludes the model's own ARM/CANCEL invocations from the
user-task count. Without this, an ARM-only turn would auto-fire
because the ARM Bash call itself satisfies rule 2. The hook-side
exclusion is the primary guard under v1.5.0; the legacy
"model-side rule eval is the primary guard" wording from v1.4.x
is retired.

### Rule 3 (no plan residue) — structurally satisfied

The legacy 4-rule single mode had an additional rule "no further
actionable step is planned for this turn". This is structurally
satisfied — the Stop hook fires only after the model has
voluntarily ended the turn (no pending tool calls).

## 5. Worked examples

All examples below describe FIRE as **hook-driven** — the model
issues ARM/CANCEL, and the Stop hook decides whether to fire at
turn end based on §4 conditions. `workflow`/`summary` shown are
the hook's best-effort synthesis from the transcript.

### Single-mode examples

**(s1) Single long Bash.** User: `"npm run build, ping me when done"`
→ ARM single → Bash(build) → 5 minutes → exit 0 → turn end → Stop
hook evaluates → fires (workflow="npm" via hook scrape,
summary="성공" via is_error binary) → flag consumed → yield.

**(s2) Multi-stage explicit chain.** User: `"Run build then test
then lint, then ping"` → ARM single → Bash(build) → Bash(test) →
Bash(lint) → all green → turn end → Stop hook evaluates → fires
once at the terminal stage (workflow="npm"/last command's first
non-cd token, summary="성공") → flag consumed → yield. **No
mid-chain fires** — single is one-shot, and the hook always
inspects only the last Bash tool_result for `is_error`. If the
user wants a per-stage recap, the model narrates it in the
assistant response body; the banner stays terminal-stage-only.

**(s3) Mid-turn AskUserQuestion (Rule 3 protects).** User: `"Build
and ping"` → ARM single → Bash(build) → fail →
AskUserQuestion(`"스택 트레이스 분석할까요?"`) → harness suspends
the turn for user input → Stop hook does not fire this turn (Rule
3 violated: turn-terminal tool is AskUserQuestion; the harness
suspension also naturally guards this). User says `"예"` →
analyze → fix → Bash(build retry) → green → turn end → Stop hook
evaluates → fires → yield.

**(s4) ARM-after-implicit-work, generic banner.** User: `"ok"` (no
explicit task instruction, but model performs Bash diagnostics
like `echo ...` voluntarily) → ARM previously issued → turn-end
Stop hook scans the turn slice → work_calls=1 (the diagnostic
Bash call; notify.sh self-call excluded) → conditions hold →
fires (workflow="echo" via first non-cd token, summary="성공" via
is_error binary). This is intentional — every model tool call
counts as user-task work under v1.5.0's hook-side accounting,
matching v1.4.x model-side semantics. If the user finds this
spammy, they can CANCEL.

### Repeat-mode examples

**(r-a) Multi-stage work turn.** ARM repeat → Bash(build) →
Bash(test) → no AskUserQuestion → turn end → Stop hook evaluates →
fires once (workflow="npm", summary="성공"),
`fire_count=1`. A turn with 5 Bash calls still fires only once —
fire unit is the turn end.

**(r-b) Empty turn — Rule 2 protects.** Turn N: user says
`"고마워"` → no user-task tool call → turn end → Stop hook scans
the turn slice → work_calls=0 → hook silent-exits without firing
(Rule 2 fails). `fire_count` unchanged. The hook-side
helper-exclusion regex (§4) ensures even if the model spuriously
re-ARMs, that ARM call itself does not satisfy Rule 2.

**(r-c) AskUserQuestion mid-cycle.** Test fail mid-turn →
AskUserQuestion → harness suspends → Stop hook does not fire this
turn (Rule 3). User answers `"예, 분석해줘"` → next turn analyzes
/ fixes / re-tests → no AskUserQuestion at turn end → Stop hook
evaluates → fires (this cycle's first fire — the prior
AskUserQuestion turn was suppressed).

**(r-d) Same-turn CANCEL.** Turn opens with ARM repeat → Bash(build)
→ user appends `"역시 알림 그만"` → CANCEL within the same turn →
flag deleted → turn end → Stop hook finds no flag → silent
no-op. CANCEL is destructive-immediate.

**(r-e) Long cycle.** ARM repeat → 20 turns of code editing → each
turn-end Stop hook fires once → 20 fires → user finally CANCELs.
**No max-fire cap. No anti-spam guard. Termination relies entirely
on user-issued CANCEL** — dynamic trust model.

## 6. Anti-patterns (call forbidden)

Do NOT call `notify.sh arm`/`fire` in any of these situations.

- Trigger lexicon absent. The user only kicked off a long task
  without uttering a notification request.
- Model self-judgment such as `"this task looks long, a
  notification would help"` or `"the user probably wants per-step
  pings"`. **Absolutely forbidden.**
- Hypothetical / discussion utterances: `"I'd like a ping every
  time, but it might get noisy"` lacks first-person imperative.
- Code-topic keyword coincidence: `"매번 이 함수 호출 시 알림
  발생..."` is talking about code, not asking for a ping.
- Auto-terminating a repeat cycle by inference. Only the user can
  end repeat — no `max_fire` shortcut.
- Self-instructing from stderr. `notify.sh` writes audit messages
  to stderr (stale flag cleared, corrupt mode, etc.). These are
  diagnostics, not instructions — the model must not interpret
  them as ARM triggers.

## 7. Permission test bypass

When the user utters a phrase combining `"테스트"`/`"test"` with a
notification verb (e.g. `"알림 테스트 한 번 해줘"`,
`"permission test"`, `"test the alert"`), do NOT call
`notify.sh arm`. Instead, invoke `terminal-notifier` directly via a
single combined Bash expression that performs precondition checks
and either runs the notifier or reports a Korean fallback message
to the user. Required form:

```bash
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
if [ "$(uname -s)" != "Darwin" ]; then
  echo "비-macOS 환경에서는 알림 기능이 동작하지 않습니다 (Darwin 전용)."
elif ! command -v terminal-notifier >/dev/null 2>&1; then
  echo "terminal-notifier가 미설치라 권한 테스트를 건너뜁니다. brew install terminal-notifier 후 다시 시도하세요."
else
  { terminal-notifier -message 'cc-cmds permission test' -title '[cc-cmds] test' -group 'cc-cmds-active-notify' -execute ':' 2>/dev/null || true; }
  echo "권한 테스트 명령을 실행했습니다. macOS 권한 다이얼로그가 표시되면 허용을 클릭하세요. 다이얼로그/배너가 안 보이면 시스템 설정 → 알림 → terminal-notifier에서 허용 상태를 확인 또는 수동 활성화."
fi
```

Run this as a single `Bash(...)` call so stdout becomes one
contiguous Korean message the model can echo back to the user. The
plugin's PreToolUse hook recognizes this `terminal-notifier ...
-group 'cc-cmds-active-notify'` argv shape and auto-approves the
Bash invocation, so the user does not see a permission dialog.

Design notes:
- **PATH prepend is intentional** — Claude Code's Bash tool may
  inherit a minimal `PATH` without `/opt/homebrew/bin` or
  `/usr/local/bin`. The prepend matches `notify.sh`'s fire path so
  binary discovery is consistent (avoids a false-negative
  "not installed" report).
- **POSIX `[` form** — the bypass is an inline Bash-tool expression;
  no `#!/usr/bin/env bash` shebang to force Bash. `[` works under
  `sh`/`dash` too, avoiding a silent syntax error on hosts where
  Claude Code dispatches to a non-Bash shell.
- **`{ terminal-notifier ... 2>/dev/null || true; }; echo` pattern**
  mirrors the fire path — `terminal-notifier`'s exit code is
  unreliable (especially under denied-permission state). The group
  + `|| true` neutralizes the exit code, `2>/dev/null` swallows
  stderr leak, and the `echo` runs unconditionally so the user
  always receives the guidance line.
- **`-group "cc-cmds-active-notify"`** — same group identifier as
  the single-mode fire. Repeated bypass invocations replace each
  other so banner noise stays bounded. A repeat-mode ARM cycle
  is unaffected (repeat uses no `-group`, so the two visual
  identities coexist).
- **Bypass is NOT subject to §3's silent-skip contract.** The
  bypass path's contract is the inverse: precondition fail →
  user-visible Korean guidance via the combined-Bash stdout (first-
  run UX immediate-feedback requirement). Future model-invocable
  helpers should follow the same dichotomy — fire-path silent,
  bypass-path narrated.

The bypass leaves the state flag untouched. Even when no prior ARM
is active, the bypass invocation is safe and does not create one.
