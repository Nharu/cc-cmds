---
name: active-notify
description: 사용자가 명시적으로 1인칭 알림 요청 어휘를 발화했을 때 그 작업의 완료 시점에 macOS 데스크탑 알림을 발송하는 model-invoked 헬퍼. 단발 모드("끝나면 알려줘")와 매-턴 반복 모드("매번 알려줘")의 두 lifecycle을 지원. 트리거 어휘 부재 시 호출 금지 — 모델 자체 판단으로 ARM 절대 금지.
when_to_use: |
    사용자가 1인칭 알림 요청 어휘를 명시적으로 발화한 직후 ARM. 발화에 매·마다·매번·각·반복·every·each 키워드가 1개라도 등장하면 repeat 모드 (매 turn 종료 시 fire), 부재 시 single 모드 (1회 fire 후 만료). ARM 직후 즉시 fire는 금지 — fire는 ARM과 별개의 task-completion rule 평가 (single 4-rule, repeat 3-rule)를 받으며, 같은 turn에 user-task tool call이 ≥1 발생해야 fire 가능 (notify.sh 자체 호출은 카운트 제외). 모델 자체 판단 ("이 작업이 길어 보이니 알림이 좋겠다", "사용자가 각 step별 진행을 보고 싶어할 듯") ARM은 절대 금지. **PERMISSION TEST 예외**: 사용자 발화에 "테스트"/"test" 키워드가 알림 어휘와 결합 ("알림 테스트", "test the alert") 시 ARM이 아닌 `Bash(terminal-notifier -message ... -title ... -group ...)` 직접 호출 — notify.sh 우회. canonical lexicon · worked example · 4-rule variant · anti-pattern · permission test bypass는 SKILL.md body 참조.
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
Invariants). The sections below give the model-side calling convention
and the lexicon / rule variants that drive ARM/FIRE decisions.

## 1. Calling convention

The dispatcher script is `active-notify/scripts/notify.sh` with three
subcommands. The shell working directory does not matter — paths are
absolute. All three are local-disk file ops and complete instantly.

```bash
# Arm a new notification cycle. mode argument is optional (default "single").
bash active-notify/scripts/notify.sh arm "<request_text>" "<context_hint>" [single|repeat]

# Fire — branches on the mode field stored in the state flag. Workflow is a
# short English task identifier (≤30 chars, internal ID); summary is a
# Korean 1-line user-facing message that the user actually reads in the banner.
bash active-notify/scripts/notify.sh fire "<workflow>" "<summary>"

# Cancel — mode-agnostic flag delete.
bash active-notify/scripts/notify.sh cancel
```

Argument order for `arm`: `request_text` first (verbatim user phrase that
triggered ARM), `context_hint` second (short summary of the user-asked
task — e.g. "build", "design-review iteration"), optional `mode` third.
Invalid mode values (anything other than `single`/`repeat`) silent
normalize to `single`.

Banner copy synthesis on `fire`:
- `workflow` is a short English task identifier kept in English so log
  pipelines and future tooling stay stable (examples: `build`, `test`,
  `design-review`, `lint`).
- `summary` is a Korean 1-line message because the banner body is read
  by the user. Examples: `"성공 (exit 0)"`, `"테스트 3건 실패"`,
  `"수렴 완료"`, `"파일 업데이트 완료"`, `"리뷰 마침"`,
  `"컨텍스트 로드 완료"`.
- Multi-stage turns (build → test → lint) report the terminal-stage
  outcome rather than aggregate wording.
- If the terminal stage is a Bash command with an exit code, compress
  that exit-code result into one Korean sentence; if the terminal
  stage is a Read/Edit/Grep tool (no exit code), describe turn
  intent semantically.
- Never empty. Minimum fallback is `"완료"`.
- Consistent Korean wording helps the user judge spam frequency and
  trigger CANCEL when appropriate.

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

**ARM is always idempotent overwrite.** Each `notify.sh arm` invocation
performs a `schema:2` fresh JSON write that replaces any prior flag.
Consequences:
- **Mode switch** (single ↔ repeat) — the new ARM discards the prior
  cycle's `fire_count` and `last_fire_at`.
- **Re-ARM after CANCEL** — opens a new cycle from `fire_count: 0`.
- **Same-mode re-ARM** — JSON regenerated; `fire_count` reset to 0.
- **Invalid mode argument** (e.g. `continuous`, `REPEAT`) silently
  normalizes to `single`. This ARM-side leniency is intentionally
  asymmetric with the FIRE-side strict-reject policy: ARM input
  originates from the model (canonicalization drift is forgiving),
  while FIRE input originates from disk (treated as untrusted state).

**FIRE branches on the stored `mode` field.** Single-mode consumes the
flag (atomic `mv -n` rename to `*.consuming-$$`, then optional
notifier call, then `rm`). Repeat-mode preserves the flag and
performs an atomic `temp → mv` rename to bump `fire_count` and refresh
`last_fire_at`.

**CANCEL is mode-agnostic.** `rm -f flag`. No mode check. Lexicon
covers both generic (`"알림 취소"`) and repeat-specific
(`"반복 알림 그만"`) phrasings — same effect.

## 4. Task-completion rules

The model evaluates these rules at the **end of every assistant
response block** (turn end) and decides whether to call
`notify.sh fire` as the final action of that block.

### Single mode (4-rule, all must hold)

1. ARM flag is alive and `mode=single`.
2. The current response block has executed **≥1 user-task tool call
   after the ARM** (Bash, Read, Edit, Grep, etc.). **`notify.sh arm`/
   `fire`/`cancel` invocations do NOT count toward this rule.**
3. No further actionable step is planned for this turn.
4. The response block does NOT end with `AskUserQuestion`. Only
   turn-terminal `AskUserQuestion` blocks fire; mid-turn
   `AskUserQuestion` followed by further work is fine.

When all four hold, call `notify.sh fire` as the closing action of
the same block, then yield.

### Repeat mode (3 effective rules)

1. ARM flag is alive and `mode=repeat`.
2. The current response block has executed **≥1 user-task tool call
   after the ARM** (same exclusion rule as single).
3. _(no plan-residue check — repeat is turn-end-based, not workflow-
   completion-based)_
4. The response block does NOT end with `AskUserQuestion`.

Rule 1 + 2 + 4 satisfied → fire once at turn end. `fire_count` is
incremented; the flag is preserved for the next turn.

### Helper-script exclusion (both modes — verbatim contract)

> Rule 2 ("≥1 user-task tool call this turn") refers to tool
> invocations made on behalf of the user-asked task (Bash, Read,
> Edit, Grep, etc.). **Calls to `active-notify/scripts/notify.sh`
> (`arm`, `fire`, `cancel`) are excluded from this count.**
> Without this exclusion, an ARM-only turn — where the user only
> uttered the trigger lexicon and asked for no work — would
> auto-fire because the ARM call itself is a Bash tool call. The
> model-side rule evaluation is the primary guard; this
> helper-exclusion is the secondary regression guard.

## 5. Worked examples

### Single-mode examples

**(s1) Single long Bash.** User: `"npm run build, ping me when done"`
→ ARM single → Bash(build) → 5 minutes → exit 0 → 4-rule satisfied
→ FIRE(`workflow="build"`, `summary="빌드 완료 (exit 0)"`) → flag
consumed → yield.

**(s2) Multi-stage explicit chain.** User: `"Run build then test
then lint, then ping"` → ARM single → Bash(build) → Bash(test) →
Bash(lint) → all green → FIRE once at the terminal stage
(`workflow="lint"`, `summary="성공 (exit 0)"`) → flag consumed →
yield. **No mid-chain fires** — single is one-shot, and the summary
reflects the terminal stage only. If the user wants a per-stage
recap, the model narrates it in the assistant response body; the
banner stays terminal-stage-only.

**(s3) Mid-turn AskUserQuestion (rule 4 protects).** User: `"Build
and ping"` → ARM single → Bash(build) → fail →
AskUserQuestion(`"스택 트레이스 분석할까요?"`) → user attention
returns immediately → **no fire** (rule 4 violated). User says
`"예"` → analyze → fix → Bash(build retry) → green → FIRE → yield.

### Repeat-mode examples

**(r-a) Multi-stage work turn.** ARM repeat → Bash(build) →
Bash(test) → no AskUserQuestion → turn end → 3-rule satisfied → fire
once (`workflow="test"`, `summary="테스트 통과 (exit 0)"`),
`fire_count=1`. A turn with 5 Bash calls still fires only once — fire
unit is the turn end.

**(r-b) Empty turn — rule 2 protects.** Turn N: user says
`"고마워"` → no user-task tool call → model evaluates the 3-rule and
**does not call `notify.sh fire`** because rule 2 fails (primary
contract: model-side rule eval). Even if the model erroneously
called fire, the helper-exclusion would not let the fire itself
satisfy rule 2 (backup contract). `fire_count` unchanged. **The
model must not call fire reflexively at every turn boundary.**

**(r-c) AskUserQuestion mid-cycle.** Test fail mid-turn →
AskUserQuestion → rule 4 fails → no fire this turn. User answers
`"예, 분석해줘"` → next turn analyzes / fixes / re-tests → no
AskUserQuestion at end → fire (this cycle's first fire — the prior
AskUserQuestion turn was suppressed).

**(r-d) Same-turn CANCEL.** Turn opens with ARM repeat → Bash(build)
→ user appends `"역시 알림 그만"` → CANCEL within the same turn →
flag deleted → at turn end rule 1 fails → no fire. CANCEL is
destructive-immediate.

**(r-e) Long cycle.** ARM repeat → 20 turns of code editing → each
turn satisfies the 3-rule → 20 fires → user finally CANCELs.
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
  { terminal-notifier -message 'cc-cmds permission test' -title '[cc-cmds] test' -group 'cc-cmds-active-notify' 2>/dev/null || true; }
  echo "권한 테스트 명령을 실행했습니다. macOS 권한 다이얼로그가 표시되면 허용을 클릭하세요. 다이얼로그/배너가 안 보이면 시스템 설정 → 알림 → terminal-notifier에서 허용 상태를 확인 또는 수동 활성화."
fi
```

Run this as a single `Bash(...)` call so stdout becomes one
contiguous Korean message the model can echo back to the user.

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
