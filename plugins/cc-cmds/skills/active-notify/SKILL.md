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

The model directly invokes three subcommands of
`active-notify/scripts/notify.sh`. FIRE (turn-end, hook-driven) is
**not model-callable**; FIRE-NOW (sub-turn, model-driven) is the
opt-in surface for specific milestone moments. All paths are
absolute; the shell working directory does not matter; the
subcommands are local-disk file ops and complete instantly.

```bash
# Arm a new notification cycle. mode argument is optional (default "single").
# --milestone is optional; supply only when the user named a specific
# step ("b 작업 끝나면 알림" → --milestone="b 작업"). Generic terminal
# phrases ("끝나면 알려줘") MUST leave it empty. See §2 extraction rules.
bash active-notify/scripts/notify.sh arm "<request_text>" "<context_hint>" [single|repeat] [--milestone="<phrase>"]

# Sub-turn fire — model-driven, only invokable when ARM-time milestone
# is non-empty AND the assistant just observed completion of the
# corresponding step in the current turn. See §6 amendment.
bash active-notify/scripts/notify.sh fire-now <workflow> <summary>

# Cancel — mode-agnostic flag delete.
bash active-notify/scripts/notify.sh cancel
```

Argument order for `arm`: `request_text` first (verbatim user phrase that
triggered ARM), `context_hint` second (short summary of the user-asked
task — e.g. "build", "design-review iteration"), optional `mode` third,
optional `--milestone="<phrase>"` parse-anywhere flag. Invalid mode
values (anything other than `single`/`repeat`) silent normalize to
`single`. The `milestone` field is always written to the flag JSON
(even when empty) so a prior cycle's milestone cannot survive into a
fresh ARM via absent-field semantics.

**FIRE (turn-end, hook-driven).** At every assistant-turn end Claude
Code invokes the registered Stop hook, which:

1. Verifies session isolation via the hook stdin `session_id` field
   (β safety-net: newest-flag fallback with file-based audit log at
   `${flag_dir}/audit.log` — not stderr).
2. Scans the assistant text blocks of the current turn slice for a
   single-line HTML-comment marker:
   `<!--cc-active-notify workflow="..." summary="..." -->`. The last
   marker occurrence wins (multi-step turn bleed fence). When
   present, marker values become the banner copy (length-capped:
   `workflow` ≤ 120 bytes, `summary` ≤ 360 bytes, byte semantics for
   UTF-8 safety). Attribute values MUST NOT contain interior `"` or
   `>` — both terminate the scrape regex silently.
3. Evaluates the task-completion rules (§4) by scanning the
   transcript JSONL for user-task tool calls and the turn-terminal
   tool block. Rule 2 and Rule 3 silent-exits are conditionally
   bypassed when the flag carries a non-empty `milestone`, `mode !=
   "repeat"`, AND the marker was emitted with a non-empty `workflow`
   (symmetric guard, fail-closed when marker absent).
4. Shells out to `notify.sh fire <workflow> <summary>` if the rules
   pass. When the marker is present, `<workflow>` / `<summary>` are
   the marker values; otherwise the fallback is the first non-cd
   token of the last Bash command (workflow; fallback `task`) and
   the binary derived from the last tool_result's `is_error` field
   (summary; `성공` / `실패` / `완료`).

**FIRE-NOW (sub-turn, model-driven).** When the model observes
completion of the specific ARM-time milestone mid-turn, it invokes
`notify.sh fire-now <workflow> <summary>` directly. The dispatcher
checks the stored `milestone` field — non-empty → fire; empty (generic
ARM) → silent no-op + audit log. The Stop hook detects fire-now
invocations in the turn slice and dedups (no double banner).

Banner title is always `[cc-cmds] ${workflow}` and body is
`${summary}`.

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

### 2.1 ARM-time milestone extraction (`--milestone` parameter)

When the user names a specific step in the ARM utterance, extract
that phrase and pass it via `--milestone="<phrase>"`. The phrase
unlocks the model-driven `fire-now` surface for sub-turn dispatch
(see §1, §6). When the user only names a generic terminal moment,
leave `--milestone` unset (or empty) — the `fire-now` path stays
structurally closed.

**Bilingual lexicon** (Korean entries are canonical; English glosses
shown for translation reference):

| User utterance | English gloss | Extracted `milestone` |
| --- | --- | --- |
| `"끝나면 알려줘"` | `"ping me when done"` | _(empty — generic)_ |
| `"b 작업 끝나면 알려줘"` | `"ping me when task b finishes"` | `"b 작업"` |
| `"테스트 끝나면 알림"` | `"ping me when tests finish"` | `"테스트"` |
| `"7단계 끝나면 알림"` | `"step 7 done, ping me"` | `"7단계"` / `"step 7"` |
| `"70% 되면 알림"` | `"hit 70% ping me"` | `"70%"` |
| `"백그라운드 b 끝나면"` | `"when background b finishes"` | `"백그라운드 b"` |

**Extraction rules**:

- The completion marker tokens are `끝나면` / `완료` / `done` /
  `finishes` / `되면` / `hits`. Extract the noun-phrase token(s)
  immediately preceding the marker (specific job / step / file /
  percentage / condition).
- A bare completion marker with no preceding noun-phrase (e.g.
  `"끝나면 알려줘"` alone) yields an empty `milestone` — generic
  terminal moment, hook-driven turn-end fire is sufficient.
- **Repeat mode (`매`/`마다`/`every`/`each`) always yields empty
  `milestone`**. Every turn-end is itself the milestone in repeat
  mode; a sub-turn fire-now is meaningless.

**Repeat lexicon priority over hybrid utterances**: When `매`/`마다`/
`every`/`each` co-occurs with a specific milestone phrase (e.g.
`"매번 b 작업 끝나면 알림"`), the utterance silently demotes to
repeat mode + empty milestone. Per-cycle specific-trigger tracking
is outside the schema:2 single-`milestone` field's expressive range
— if this pattern surfaces frequently in practice, a future
schema:3 expansion (array-valued milestone) would be the natural
evolution. For now, the user can split the request: ARM repeat for
the recurring stream + ARM single + `--milestone` for the specific
step.

**Why ARM-time extraction (not fire-now call-site inference)**:
ARM is fresh user-utterance + cold model context, the moment of
highest classification accuracy. fire-now call sites are hot
context + temporally distant from the user's phrasing —
misclassification risk ("npm 테스트 끝나면" generic-vs-specific
ambiguity) compounds across the cycle. ARM-time extraction plus a
flag-field check means a generic ARM + a fire-now call is
*structurally* unable to fire (silent no-op + audit log), without
relying on prose-only model discipline.

## 3. ARM / FIRE / CANCEL semantics

**ARM is always idempotent overwrite (model-driven).** Each
`notify.sh arm` invocation performs a `schema:2` fresh JSON write
that replaces any prior flag. Consequences:
- **Mode switch** (single ↔ repeat) — the new ARM discards the prior
  cycle's `fire_count` and `last_fire_at`.
- **Milestone reset** — the new ARM's `milestone` value (empty if
  `--milestone` is omitted) overwrites any prior value. A prior
  cycle's milestone cannot survive into a fresh ARM.
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
The model **never** invokes the `fire` subcommand directly; even an
erroneous fire invocation would have its Bash dialog auto-approved
by the PreToolUse hook but would still be redundant and is not part
of this contract.

**FIRE-NOW is the only model-callable dispatch surface.** When the
ARM-time `milestone` field is non-empty AND the assistant just
observed completion (success or failure) of the corresponding step
in the current turn, the model directly invokes
`notify.sh fire-now <workflow> <summary>`. The dispatcher inherits
the same lockdir / schema-guard / mode-aware mutation logic as
`fire`, gated by two pre-checks: (a) ARM flag existence (silent
no-op if absent), (b) `milestone` non-empty (silent no-op + audit
log if generic ARM). The Stop hook scans the turn slice for fire-
now invocations and silently exits if any are present — no double
banner. fire-now invocations are also excluded from the Rule 2
work-call count via the helper-script regex.

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
test("active-notify/scripts/notify\\.sh\\s+(arm|fire|fire-now|cancel)\\b") | not
```

This excludes the model's own ARM/FIRE-NOW/CANCEL invocations from
the user-task count. Without this, an ARM-only turn would auto-fire
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

Do NOT call `notify.sh arm`/`fire-now` in any of these situations.

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

### 6.1 `fire-now` discipline (negative — call forbidden)

> _`notify.sh fire-now` is invokable only when the active ARM flag
> carries a non-empty `milestone` field whose phrase matches the
> step the assistant just completed in the current turn — invoking
> fire-now against a generic ARM (empty milestone), against a
> different milestone than the one stored at ARM time, or based on
> the assistant's own judgment of step significance is forbidden,
> same class as self-judgment ARM._

Three clauses, three layers of enforcement:

- **(a) Non-empty milestone required** — structural. The dispatcher
  reads `flag.milestone` via jq; empty → silent no-op + audit-log
  entry. Misclassification at the call site cannot produce a
  banner.
- **(b) Phrase-match against stored milestone** — policy fence. The
  dispatcher does not currently compare the fire-now `<workflow>` /
  `<summary>` arguments against the stored `milestone` text. Drift
  here is interpretable mis-banner (the user reads the banner copy
  and sees the wrong step name) — recoverable, but the model MUST
  echo the stored milestone phrase in `<workflow>` or use it as the
  primary semantic anchor.
- **(c) Self-judgment equivalence** — same forbidden class as
  self-judgment ARM. The model judges *which user-named milestone
  this current step corresponds to*, NOT *whether this step is
  significant enough to ping*. The latter is the §6 ARM anti-
  pattern in fire-now clothing.

### 6.2 `fire-now` discipline (positive — emit marker on observed completion)

> _Conversely, when the active ARM flag carries a non-empty
> `milestone` field AND the assistant just observed completion
> (success or failure) of the corresponding step in the current
> turn, the assistant MUST emit a valid
> `<!--cc-active-notify workflow="..." summary="..." -->` marker in
> any assistant text block within the current turn (regardless of
> which sub-message or whether positioned before/after subsequent
> tool_use blocks like AskUserQuestion) — with `workflow` set to
> (or echoing) the milestone phrase and `summary` describing the
> observed outcome. The hook scans the entire turn slice for the
> last marker occurrence; intra-message ordering does not matter.
> Emitting the marker is a textual side-effect aligned with normal
> narration mode; skipping it to dive into failure analysis is the
> same class of error as self-judgment ARM._

The marker is the Rule 2 / Rule 3 bypass gate (see §4.6
lifecycle-matrix amendment in `docs/active-notify-fire-channel.md`).
Two dogfood-surfaced failure modes motivated the positive
obligation: (i) Rule 3 path — "background build failed → analysis
prose → AskUserQuestion → marker omitted → Rule 3 silent-exit →
silent miss"; (ii) Rule 2 path — "BashOutput-only turn (work_calls
= 0 because BashOutput isn't in the 11-tool whitelist) → marker
omitted → Rule 2 silent-exit → silent miss". Marker emission is
same-modality (text → text, inline in narration); fire-now is
modality-switch (text → tool dispatch, requires plan-reordering).
The positive obligation is enforced as prose-level discipline, with
audit log forensic anchors when the bypass guard fails closed.

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
