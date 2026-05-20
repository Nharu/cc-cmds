---
name: active-notify
description: 사용자가 (a) 1인칭 알림 요청 어휘 ("끝나면 알려줘"/"매번 알려줘"/"시작할 때랑 끝날 때 알림"), (b) 권한 테스트 어휘 ("알림 테스트"/"test alert"/"permission test"), 또는 (c) 취소 어휘 ("알림 취소"/"stop the alerts") 발화 시 호출되는 macOS 데스크탑 알림 헬퍼 (model-invoked, 슬래시 커맨드 없음). 어휘 부재 → 호출 금지·모델 자체 판단 ARM/bypass 절대 금지. 어휘 발현 → mode·armCount·sub-event ambiguity가 회피 사유 아님 — best-fit으로 ARM 후 sub-event 시점마다 fire-now 호출.
when_to_use: |
    **PERMISSION TEST 제외 (1순위)**: "테스트"/"test" + 알림 동사 발화는 §7 inline bypass로 라우팅. 단, 3개 절 중 ANY ONE 발현 시 ARM 분기로 재라우팅: (a) 별도 작업 컨텍스트 (코드 수정·빌드·테스트 실행·polling 등 알림 외 작업이 발화에 포함) (b) noun-form "테스트"/"test" (Android instrumentation/unit/regression/npm test 등 알림이 아닌 별도 작업 대상) (c) ARM-eligible companion 발화 (시간 marker·작업 boundary·sub-event 지칭). 상세 절차·worked example은 body §2.

    **ARM**: 1인칭 알림 요청 어휘 발화 직후 ARM. `매`/`마다`/`매번`/`각`/`반복`/`every`/`each` 키워드 발현 → repeat 모드 (CANCEL까지 매 turn fire-now). 부재 → single 모드. 복수 named sub-event ("시작할 때랑 끝날 때") → single + `--count=N` (best-fit 정수, ambiguity 시 ARM 강행).

    **CANCEL**: "알림 취소"/"stop the alerts" 등 명시적 취소 어휘 → `notify.sh cancel` (mode-agnostic).

    **Repeat per-turn fire-now self-check**: turn 종료 직전 ARM alive + 이번 turn에 user-task tool call ≥1 발생이면 fire-now가 빚져 있음 — 모델이 자체 호출.

    armCount 추출 token-counting + tiebreak · fire-now 의무 prose · anti-pattern · 3-clause 전체 절차는 body §2/§4/§5/§6 참조.
disable-model-invocation: false
usage: "(자동 호출 — 슬래시 커맨드 없음. 사용자가 1인칭 알림 요청 어휘 발화 후 모델이 ARM, single 모드는 armCount회 fire-now 후 만료, repeat 모드는 매 turn 종료 시 fire-now 호출(CANCEL까지).)"
options: []
notes: |
    cc-cmds 유일의 model-invoked 헬퍼이며 슬래시 커맨드 surface가 없다. 모델은 frontmatter
    `description` + `when_to_use`로 호출 결정을 내리고, SKILL.md body의 ARM/FIRE-NOW/CANCEL
    contract + canonical lexicon에 따라 모드와 armCount를 선택한다. macOS 외 / `terminal-notifier`
    미설치 환경은 silent no-op. 최초 사용 전 macOS 알림 권한 승인 필요 — "알림 테스트 한 번 해줘"
    발화로 권한 다이얼로그 트리거.
---

# active-notify

Read `_common/notify.md` once per session to load the shared procedure
(preconditions, fire copy synthesis, failure handling, Control-Flow
Invariants). The model owns the entire ARM / FIRE-NOW / CANCEL lifecycle —
there is no turn-end auto-fire. The plugin's PreToolUse hook self-approves
the dispatcher's Bash invocations so the Bash permission dialog never
surfaces.

## 1. Calling convention

The model directly invokes three subcommands of
`active-notify/scripts/notify.sh`. All paths are absolute; the shell
working directory does not matter; the subcommands are local-disk file
ops and complete instantly.

```bash
# Arm a new notification cycle. mode argument is optional (default "single").
# --count=N is optional parse-anywhere flag for single-mode multi-sub-event
# ("시작할 때랑 끝날 때" → --count=2). default 1, normalize to 1 if not in [1..16].
bash active-notify/scripts/notify.sh arm "<request_text>" "<context_hint>" [single|repeat] [--count=N]

# Sub-turn fire — model-driven, the ONLY dispatch surface. Called at each
# sub-event observation point (e.g. step completion, milestone boundary).
bash active-notify/scripts/notify.sh fire-now <workflow> <summary>

# Cancel — mode-agnostic flag delete.
bash active-notify/scripts/notify.sh cancel
```

Argument order for `arm`: `request_text` first (verbatim user phrase that
triggered ARM), `context_hint` second (short summary of the user-asked
task — e.g. "build", "design-review iteration"), optional `mode` third,
optional `--count=N` parse-anywhere flag. Invalid mode values (anything
other than `single`/`repeat`) silent-normalize to `single`. `--count=N`
out-of-bounds inputs (non-integer, ≤0, >16) silent-normalize to 1 — same
categorical pattern as mode normalization.

Banner title is always `[cc-cmds] ${workflow}` and body is `${summary}`.

### 1.1 Single vs repeat × armCount contract

| Mode + count | Fire-now behavior | Banner -group | Banner pile-up |
| --- | --- | --- | --- |
| `single --count=1` (default) | 1 fire-now → flag consumed | `-group "cc-cmds-active-notify"` | banner replaces previous |
| `single --count=N (N>1)` | N fire-now (intermediate N-1 + final 1); final consumes | none | each sub-event banner persists |
| `repeat (--count ignored)` | unbounded fire-now until CANCEL | none | intentional pile-up |

`-group` decision is dispatcher-internal — the model never specifies it.
For `single --count=N>1`, `-group` is intentionally omitted so each
sub-event banner persists in Notification Center; this preserves the
user's explicit "N distinct events" intent. Repeat mode never uses
`-group` (dynamic-trust anti-spam: pile-up triggers user CANCEL).

## 2. Trigger lexicon (canonical)

The model decides ARM / fire-now / CANCEL based on user phrasing. Only
the canonical patterns below trigger; everything else is anti-pattern
(see §6).

### 2.0 PERMISSION TEST gatekeeper (3-clause exclusion)

"테스트"/"test" + 알림 동사 발화는 기본적으로 §7 inline bypass로 라우팅
된다. 단, 아래 3개 절 중 **ANY ONE** 발현 시 ARM 분기로 재라우팅된다
(1순위 bypass 적용 금지):

- **(a) 별도 작업 컨텍스트** — 발화에 알림 외의 다른 작업(코드 수정, 빌드,
  테스트 실행, polling 등)이 명시되거나, 직전 turn까지의 진행 작업이 있음.
- **(b) Noun-form "테스트"/"test"** — 단어가 알림이 아닌 별도 작업 대상을
  가리키는 명사로 사용 (Android instrumentation test, unit test, regression
  test, npm test 등). 동사형 "테스트하다" + 알림 자체 대상은 (b)에 해당 안 됨.
- **(c) Companion ARM-eligible expression** — 1인칭 알림 요청 어휘가 동반
  (시간 marker, 작업 boundary, sub-event 지칭).

**Worked counter-example** — `"테스트 시작할때랑 끝날때 알림 줘"` (Issue #12 reproducer):

- (b) ✓ "테스트" = 실행할 작업 (noun-form).
- (c) ✓ "시작할때랑 끝날때" = 2개 sub-event boundary + "알림 줘" = ARM
  request.
- → ARM 분기 (single, `--count=2`). bypass 절대 금지.

**Worked positive example** — `"알림 테스트 한 번"`:

- (a) ✗ 별도 작업 없음.
- (b) ✗ "테스트"가 "알림"에 직접 결합 (verb-form on 알림).
- (c) ✗ ARM-eligible companion 없음.
- → §7 inline bypass.

### 2.1 ARM (single mode)

First-person + imperative + notification noun + action verb + (optional)
timing marker. No `매`/`마다`/`매번`/`각`/`반복`/`every`/`each` keyword.
Examples:

- 한국어: `"끝나면 알려줘"`, `"알림 줘"`, `"노티 한 번 쏴줘 끝나면"`,
  `"이거 끝날 때 알림 보내줘"`.
- 영어: `"ping me when this finishes"`, `"let me know when done"`,
  `"notify me when the build completes"`.

### 2.2 ARM (repeat mode)

Same shape as ARM single PLUS at least one of `매`/`마다`/`매번`/`각`/
`반복`/`every`/`each`. Examples:

- 한국어: `"매 커맨드 끝날 때마다 알려줘"`, `"각 단계마다 알림 줘"`,
  `"매번 작업 끝나면 노티 줘"`.
- 영어: `"every time a command finishes ping me"`, `"each time a step
  finishes, ping me"`.

### 2.3 CANCEL (mode-agnostic)

Explicit revocation. Examples:

- 한국어: `"알림 취소"`, `"알림 그만"`, `"노티 그만"`, `"알림 멈춰"`,
  `"반복 알림 그만"`.
- 영어: `"cancel notification"`, `"stop the alerts"`,
  `"nevermind on the ping"`.

### 2.4 armCount extraction (`--count=N`)

When the user names **multiple distinct sub-events** in a single ARM
utterance, count them and pass via `--count=N`.

**Token-counting rule**: scan the ARM utterance for explicitly named
sub-event tokens (timing markers, boundary phrases, ordinal references)
combined with an alert request. Count unique sub-events.

| User utterance | Extracted `--count` | Notes |
| --- | --- | --- |
| `"끝나면 알려줘"` | (default 1) | single terminal moment |
| `"시작할 때랑 끝날 때 알림 줘"` | `--count=2` | 2 named sub-events |
| `"단계별로 (3단계) 알림 줘"` | `--count=3` | explicit count |
| `"매번 끝나면 알림"` | (default 1; mode=repeat) | repeat absorbs the recurrence |

**Tiebreak rules**:

- Ambiguity between 2 and 3 → favor the lower count (under-fire is
  recoverable; over-fire wastes user attention).
- Vague enumeration ("몇 단계 끝날 때마다") with `매`/`마다` → demote to
  repeat (count argument stored but ignored at runtime).
- >16 explicit count → normalized to 1 by dispatcher (sanity cap).

**Why ARM-time extraction**: ARM is the moment of highest classification
accuracy (fresh user utterance + cold model context). fire-now call
sites are hot context + temporally distant — extracting at ARM time
locks the intent before drift sets in.

### 2.5 Disambiguator

- `"끝날 때"` → single timing marker.
- `"끝날 때마다"` → repeat (because `마다` is present).
- `"매 커밋 후 알려"` → `매` keyword → repeat (regardless of `후` or
  `끝나면` marker).
- Hybrid utterances like `"매번 알림 테스트"` — `매번` is ARM lexicon,
  `알림 테스트` looks like PERMISSION TEST. Apply §2.0 3-clause: clause
  (c) "ARM-eligible companion" is met (`매번` is repeat lexicon) → ARM
  repeat. PERMISSION TEST routing requires absence of ARM companions.

## 3. ARM / FIRE-NOW / CANCEL semantics

**ARM is idempotent overwrite (model-driven).** Each `notify.sh arm`
invocation performs a `schema:3` fresh JSON write that replaces any
prior flag. Consequences:

- **Mode switch** (single ↔ repeat) — new ARM discards prior cycle's
  `fire_count` and `last_fire_at`.
- **armCount reset** — new ARM's `--count=N` (default 1) overwrites any
  prior `arm_count`. Storage shape is mode-uniform (both single and
  repeat store the field verbatim); runtime semantics are mode-asymmetric
  (single applies the cap, repeat ignores it).
- **Re-ARM after CANCEL** — opens a new cycle from `fire_count: 0`.
- **Same-mode re-ARM** — JSON regenerated; `fire_count` reset to 0.
- **Invalid mode argument** (e.g. `continuous`, `REPEAT`) silently
  normalizes to `single`. Symmetric: invalid `--count=N` silently
  normalizes to 1.
- **Stale schema self-heal** — first `fire-now` against a v1.x
  (schema:1/schema:2) flag emits a stderr hint, removes the flag, and
  exits 0. User re-arms naturally via the next ARM utterance.

**Cross-turn ARM persistence (mental check)**: the flag survives turn
boundaries. If a prior turn ARMed and the current turn has not CANCELed,
the flag is still alive. fire-now obligations carry across turns.

**FIRE-NOW is the only dispatch surface (model-driven).** Whenever the
model observes completion of a sub-event corresponding to the active
ARM, it invokes `notify.sh fire-now <workflow> <summary>` directly.

Dispatcher behavior:

- **Schema strict check**: schema≠3 → stderr hint + flag rm + exit 0.
- **Mode validity check**: mode ∉ {single, repeat} → stderr hint + flag
  rm + exit 0.
- **Single mode mutation**: read `fire_count` + `arm_count`. `fire_count
  + 1` reaches `arm_count` → final fire (`mv -n` atomic consume). Else
  intermediate fire (`sed -E` increment + `last_fire_at` update,
  preserve flag).
- **Repeat mode mutation**: increment `fire_count` + update
  `last_fire_at` via `sed -E` rewrite, preserve flag. `arm_count`
  ignored entirely.
- **Banner**: `terminal-notifier -title "[cc-cmds] ${workflow}"
  -message "${summary}" -execute ':'`. `-group "cc-cmds-active-notify"`
  added only when single + `arm_count == 1` (banner replace semantics).

**CANCEL is mode-agnostic (model-driven).** `rm -f flag`. No mode check.
Lexicon covers both generic (`"알림 취소"`) and repeat-specific
(`"반복 알림 그만"`) phrasings — same effect.

## 4. When to invoke fire-now (model decision criteria)

The model evaluates these conditions at every observation point —
turn-end is no longer the only fire site, but it remains the natural
checkpoint.

### 4.1 Single mode (count=1, default)

Invoke `fire-now` exactly **once** when the named milestone completes.
The dispatcher consumes the flag on first fire.

### 4.2 Single mode (count=N, N>1)

Invoke `fire-now` at **each** named sub-event observation point. The
dispatcher fires N times total — intermediate N-1 (flag preserved) +
final 1 (flag consumed). Subsequent fire-now calls are silent no-op
(flag absent).

### 4.3 Repeat mode

Invoke `fire-now` at **every turn end** where:

1. ARM flag is alive (cross-turn persistence — survives until CANCEL).
2. ≥1 user-task tool call was made this turn (Bash/Read/Edit/Write/Grep/
   Glob/WebFetch/WebSearch/Task/MultiEdit/NotebookEdit). `notify.sh`
   self-calls don't count.

**Turn-end self-check**: ARM alive? user-task tool call ≥1 this turn?
→ fire-now obligation. Skipping a borderline turn is the §6.2 anti-pattern.

### 4.4 Empty turn / AskUserQuestion-terminal turn

- Pure conversational turn (no user-task tools) → no fire-now needed.
- Turn ending with `AskUserQuestion` → harness suspends turn; no
  fire-now until the user reply turn (which will be a fresh observation
  point).

## 5. Worked examples

### (s1) Single armCount=1 happy path

User: `"npm run build, ping me when done"` → ARM single (default
count=1) → Bash(build) → 5 minutes → exit 0 → model observes
completion → `fire-now "npm" "성공"` → banner with `-group` → flag
consumed → yield.

### (s2) Issue #12 reproducer — single armCount=2 end-to-end

User: `"테스트 시작할 때랑 끝날 때 알림 줘"`.

§2.0 routing:

- (b) ✓ "테스트" = noun-form (작업 대상).
- (c) ✓ "시작할 때랑 끝날 때 알림 줘" = ARM request with 2 sub-events.
- → ARM 분기 (single, `--count=2`). NOT §7 bypass.

§2.4 extraction: "시작할 때" + "끝날 때" = 2 named sub-events → `--count=2`.

Lifecycle:

1. Model: `notify.sh arm "테스트 시작할때랑 끝날때 알림 줘" "test" single --count=2`.
   Flag: `{"schema":3,...,"mode":"single","arm_count":2,"fire_count":0,...}`.
2. Test execution begins. Model observes start.
3. Model: `notify.sh fire-now "test" "시작"`. Dispatcher: intermediate
   fire — `fire_count` 0→1, flag preserved, banner emitted (no `-group`
   since armCount>1).
4. Test execution completes. Model observes end.
5. Model: `notify.sh fire-now "test" "완료"`. Dispatcher: final fire
   — `fire_count` 1+1=2 ≥ `arm_count`=2 → `mv -n` consume, banner
   emitted (no `-group`).
6. Two banners persist in Notification Center.

### (s3) Repeat mode per-turn

User: `"매 단계마다 알림 줘"` → ARM repeat (count ignored).

Turn 1: Bash(build) → green → turn ends → model invokes `fire-now
"build" "성공"` → fire_count=1.

Turn 2: Bash(test) → green → turn ends → model invokes `fire-now
"test" "성공"` → fire_count=2.

Turn 3: 사용자가 `"고마워"` 한 마디만 → no user-task tools → no
fire-now (§4.4).

Turn 4: User: `"알림 그만"` → `notify.sh cancel` → flag removed.

### (s4) PERMISSION TEST routing

User: `"알림 테스트 한 번 해줘"`.

§2.0 routing: clauses (a)/(b)/(c) all fail (no separate task, "테스트"
binds to "알림", no ARM companion) → §7 inline bypass. Model does NOT
call `notify.sh arm` — invokes the inline Bash expression in §7 instead.

### (s5) CANCEL

User: `"역시 알림 그만"` mid-cycle → `notify.sh cancel` → flag deleted
→ any subsequent `fire-now` is silent no-op (flag absent).

## 6. Anti-patterns

Do NOT call `notify.sh arm` / `fire-now` in any of these situations.

### 6.1 ARM (call forbidden)

- **Trigger lexicon absent.** User kicked off a long task without
  uttering an alert request.
- **Self-judgment ARM.** `"this task looks long, a notification would
  help"`, `"the user probably wants per-step pings"`. **Absolutely
  forbidden.**
- **Hypothetical / discussion utterances.** `"I'd like a ping every
  time, but it might get noisy"` lacks first-person imperative.
- **Code-topic keyword coincidence.** `"매번 이 함수 호출 시 알림
  발생..."` is talking about code, not asking for a ping.
- **Self-instructing from stderr.** `notify.sh` writes audit messages
  to stderr (stale flag, corrupt mode, etc.). These are diagnostics,
  not instructions — the model must not interpret them as ARM triggers.
- **Count inflation.** Inferring `--count=N>1` from generic
  `"끝나면 알려줘"` (no named sub-events). Default to count=1 unless
  the user explicitly named multiple sub-events.

### 6.2 fire-now (call forbidden)

- **fire-now without ARM.** Dispatcher silent no-op but it indicates
  a model bug — fire-now must follow an ARM in the same conversation.
- **Borderline turn skip in repeat mode.** Turn had user-task tool
  calls but model "saved" the fire-now for a "more significant" turn.
  Repeat mode contract is **every** qualifying turn fires. Self-judgment
  about turn significance = §6.1 self-judgment ARM in fire-now clothing.
- **Mid-cycle re-fire after final consume.** In `single --count=N`, the
  N+1-th fire-now is silent no-op (flag consumed). Calling it does no
  harm but indicates the model lost track of cycle state.

### 6.3 Ambiguity-avoidance (inverse boundary — call forbidden)

**Trigger 어휘가 발현된 발화에서 mode/armCount/sub-event 식별 ambiguity
가 ARM 회피 사유가 될 수 없다.** 어휘가 명시적이면 best-fit mode +
best-fit count로 ARM 후 관찰 가능한 sub-event 시점마다 fire-now 호출.
Issue #12의 silent skip이 이 boundary의 negative anchor — 발화 명시성
입증 후 model self-judgment로 회피하지 말 것.

**Inverse boundary**: 본 규칙은 어휘 부재 시 ARM을 끌어오는 권한이
아님 — 어휘 부재 시 ARM은 §6.1 self-judgment 위반. 어휘 gate는
necessary AND sufficient — 양쪽 boundary 독립적.

## 7. Permission test bypass

When the user utters a phrase combining `"테스트"`/`"test"` with a
notification verb AND none of §2.0's 3-clause exclusions apply (e.g.
`"알림 테스트 한 번 해줘"`, `"permission test"`, `"test the alert"`),
do NOT call `notify.sh arm`. Instead, invoke `terminal-notifier`
directly via a single combined Bash expression that performs
precondition checks and either runs the notifier or reports a Korean
fallback message to the user. Required form:

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

Run this as a single `Bash(...)` call so stdout becomes one contiguous
Korean message the model can echo back to the user. The plugin's
PreToolUse hook recognizes this `terminal-notifier ... -group
'cc-cmds-active-notify'` argv shape and auto-approves the Bash
invocation, so the user does not see a permission dialog.

Design notes:

- **PATH prepend is intentional** — Claude Code's Bash tool may inherit
  a minimal `PATH` without `/opt/homebrew/bin` or `/usr/local/bin`. The
  prepend matches `notify.sh`'s fire path so binary discovery is
  consistent (avoids a false-negative "not installed" report).
- **POSIX `[` form** — the bypass is an inline Bash-tool expression;
  no `#!/usr/bin/env bash` shebang to force Bash. `[` works under
  `sh`/`dash` too, avoiding a silent syntax error on hosts where
  Claude Code dispatches to a non-Bash shell.
- **`{ terminal-notifier ... 2>/dev/null || true; }; echo` pattern**
  mirrors the fire path — `terminal-notifier`'s exit code is unreliable
  (especially under denied-permission state). The group + `|| true`
  neutralizes the exit code, `2>/dev/null` swallows stderr leak, and
  the `echo` runs unconditionally so the user always receives the
  guidance line.
- **`-group "cc-cmds-active-notify"`** — same group identifier as the
  single armCount=1 fire. Repeated bypass invocations replace each
  other so banner noise stays bounded. A repeat-mode or single
  armCount>1 ARM cycle is unaffected (those use no `-group`, so the
  visual identities coexist).
- **Bypass is NOT subject to §3's silent-skip contract.** The bypass
  path's contract is the inverse: precondition fail → user-visible
  Korean guidance via the combined-Bash stdout (first-run UX
  immediate-feedback requirement).

The bypass leaves the state flag untouched. Even when no prior ARM is
active, the bypass invocation is safe and does not create one.
