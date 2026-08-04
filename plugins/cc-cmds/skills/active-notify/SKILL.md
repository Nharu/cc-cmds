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
task — e.g. "build", "design audit"), optional `mode` third,
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
| `repeat (--count ignored)` | unbounded fire-now per observed event-class instance, until self-cancel or CANCEL | none | intentional pile-up |

`-group` decision is dispatcher-internal — the model never specifies it.
For `single --count=N>1`, `-group` is intentionally omitted so each
sub-event banner persists in Notification Center; this preserves the
user's explicit "N distinct events" intent. Event-scoped repeat mode
never uses `-group` — each observed event instance gets its own
persistent banner (per-commit, per-test-pass, etc.); pile-up is bounded
by the model's own self-cancel when the event series ends, and user
CANCEL remains a standing backstop.

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

### 2.2 ARM (event-scoped repeat mode)

Same shape as ARM single PLUS at least one recurrence quantifier of
`매`/`마다`/`매번`/`각`/`반복`/`every`/`each` modifying a noun or event
phrase (the "event class"). Examples:

- 한국어: `"각 커밋마다 알림 줘"`, `"매 빌드 끝날 때마다 알려줘"`,
  `"테스트 통과할 때마다 노티 줘"`.
- 영어: `"ping me on every commit"`, `"each time a test passes, ping
  me"`.

The model captures the event class at ARM time (§2.4) — the noun or
phrase the quantifier modifies, normalized to a short label (e.g.
`"commit"`, `"test pass"`, `"deploy"`). At each observed instance of
that class, the model invokes `notify.sh fire-now` (§4.3); when the
work that produced the recurring events is done, the model self-cancels
via `notify.sh cancel` (§4.6).

**Event-class reliability spectrum.** Classes named in the user
utterance differ in how precisely the model can pin down when an
instance has occurred:

- Tool-observable events the model itself dispatches (`git commit` via
  Bash, `npm test` exit) are highest fidelity — completion is a literal
  exit code in context.
- Named semantic milestones (`"기능 완성"`, `"deploy"`) are mid-fidelity
  — the model judges completion against the work it's doing, similar to
  the milestone judgment a single ARM already makes.
- Generic work-units (`"단계"`, bare `"매번"` without an event noun)
  are lowest fidelity — the model has no salient instance boundary and
  fire-now timing approaches the looser end of the spectrum.

All three route to event-scoped repeat. The class reliability affects
*fire-now timing precision*, not the ARM decision or the mode choice —
ARM stays 100% lexical-gated (§6.1). For bare-noun utterances with no
event class to capture, §2.9 routes through a clarifying cascade.

Recurrence keywords absent → use single mode (§2.1) instead.

Apparent recurrence that is actually an enumeration of named sub-events
(`"lint 끝날 때, 빌드 끝날 때, 배포 완료 시 각각 알림"`) is NOT this
mode — see §2.5 for the enumeration-first parse order that resolves it
to `single --count=N`.

### 2.3 CANCEL (mode-agnostic)

Two triggers, both calling `notify.sh cancel` — the dispatcher does not
distinguish them.

**Explicit user revocation.** Examples:

- 한국어: `"알림 취소"`, `"알림 그만"`, `"노티 그만"`, `"알림 멈춰"`,
  `"반복 알림 그만"`.
- 영어: `"cancel notification"`, `"stop the alerts"`,
  `"nevermind on the ping"`.

**Model self-cancel (event-scoped repeat only).** When the model
observes that the work generating the recurring events has finished and
no further event-class instances are expected, it cancels the cycle
itself — without waiting for the user. Self-cancel is asymmetric with
ARM: ARM is forbidden on self-judgment (§6.1) because a false positive
creates an unrequested obligation, while a self-cancel false positive
costs at most one missed banner (recoverable — the user can re-ARM or
re-request). The model may end a cycle on judgment; it may not start
one. Ordering rule when the last instance is the cycle terminator:
`notify.sh fire-now` for that final instance FIRST, then
`notify.sh cancel` (§4.6, §6.4).

### 2.4 armCount + event-class extraction at ARM time

Two parallel extractions, both performed when the ARM call is dispatched
— the moment of highest classification accuracy (fresh user utterance,
cold model context). fire-now call sites are hot context + temporally
distant, so locking intent at ARM time prevents drift.

**armCount (`--count=N`)** — applies to single mode with multiple named
sub-events. Scan the ARM utterance for explicitly named sub-event
tokens (timing markers, boundary phrases, ordinal references) combined
with an alert request. Count unique sub-events.

| User utterance | Extracted `--count` | Notes |
| --- | --- | --- |
| `"끝나면 알려줘"` | (default 1) | single terminal moment |
| `"시작할 때랑 끝날 때 알림 줘"` | `--count=2` | 2 named sub-events |
| `"단계별로 (3단계) 알림 줘"` | `--count=3` | explicit count |
| `"각 커밋마다 알림"` | (n/a; mode=event-scoped repeat) | recurrence absorbed by event class |

**Tiebreak rules**:

- Ambiguity between 2 and 3 → favor the lower count (under-fire is
  recoverable; over-fire wastes user attention).
- Vague enumeration ("몇 단계 끝날 때마다") with `매`/`마다` → demote to
  event-scoped repeat (count argument stored but ignored at runtime).
- >16 explicit count → normalized to 1 by dispatcher (sanity cap).

**Event class (event-scoped repeat mode)** — when a recurrence
quantifier (`매`/`마다`/`매번`/`각`/`반복`/`every`/`each`) modifies a
noun or event phrase, extract that noun phrase as a short class label
and hold it in conversation context for the duration of the cycle. The
class lives in the model's context, NOT in the flag JSON — the
dispatcher is class-agnostic and the model never reads the flag back
(§4.5 defensive fire-now forbids the read because a permission-gated
Read can suspend the turn). The verbatim `request_text` argument
already preserves an audit trail.

| User utterance | Event class | Mode |
| --- | --- | --- |
| `"각 커밋마다 알림 줘"` | `commit` | event-scoped repeat |
| `"테스트 통과할 때마다 알려줘"` | `test pass` | event-scoped repeat |
| `"매 배포마다 알림"` | `deploy` | event-scoped repeat |
| `"각 기능 완성마다 알림 줘"` | `feature completion` | event-scoped repeat (loose class — fire-timing precision degrades per §2.2 spectrum) |

**Bare-noun fallback (no event noun present, e.g. `"매번 알려줘"`)** —
the recurrence quantifier is present but no event class is named.
Route through §2.9's clarifying-question cascade.

**Why ARM-time extraction (both)**: fire-now call sites have lost the
freshness of the ARM utterance — extracting both armCount and event
class at ARM time anchors the intent before any drift can occur.

### 2.5 Disambiguator (enumeration-first parse order)

Apply these gates in order — the first match wins. Concrete signals
beat bare keywords.

**Gate 1 — explicit enumeration.** Does the utterance explicitly
enumerate **≥2 named sub-events** (timing markers connected by `,`/
`랑`/`및`/`그리고`/`,`/`and`)? If yes → single mode with
`--count=N`, N = count of enumerated items. `각`/`각각`/`each` in this
context is a distributive quantifier over the enumerated finite list,
NOT a repeat trigger.

- `"시작할 때랑 끝날 때 알림 줘"` → single `--count=2`.
- `"lint 끝날 때, 빌드 끝날 때, 배포 완료 시 각각 알림"` → single
  `--count=3`. `각각` is distributive over the 3-item list.

**Gate 2 — recurrence quantifier on a noun/event class.** Otherwise, if
the utterance contains `매`/`마다`/`매번`/`각`/`반복`/`every`/`each`
modifying a noun or event phrase → event-scoped repeat (§2.2). The
noun is the event class.

- `"끝날 때마다"` (no noun named — bare) → event-scoped repeat via §2.9
  cascade.
- `"매 커밋 후 알려"` → event-scoped repeat, class `commit`.
- `"각 커밋마다 알림"` → event-scoped repeat, class `commit`.
- `"매 단계마다 알림"` → event-scoped repeat, class `step` (loose
  fire-timing per §2.2 spectrum).

**Gate 3 — single terminal moment.** Otherwise → single `--count=1`.

- `"끝날 때"`, `"끝나면 알려줘"` → single.

**Hybrid utterances:**

- `"매번 알림 테스트"` — `매번` is ARM lexicon, `알림 테스트` looks like
  PERMISSION TEST. Apply §2.0 3-clause: clause (c) "ARM-eligible
  companion" is met (`매번` is event-scoped repeat lexicon) → ARM
  event-scoped repeat. PERMISSION TEST routing requires absence of ARM
  companions.
- `"5분마다 체크해서 끝나면 알려줘"` — two mechanisms composed. `5분마다
  체크` is `/loop` polling (§2.6 — not active-notify's responsibility);
  the alert request itself is `"끝나면 알려줘"`, a single milestone.
  Route as single ARM, not event-scoped repeat.

### 2.6 Clock-keyed timing → CC interval delegation

When the user's alert request is keyed to **wall-clock cadence** — a
recurring time interval (`"5분마다 알림 줘"`) or a one-shot future
delay (`"30분 후 알림 줘"`) — do NOT call `notify.sh arm`. active-
notify's ARM/fire-now lifecycle is event/turn-cued, not clock-cued, so
arming on a clock-keyed request produces a stranded flag that will
never fire.

This is a **delegation**, not a refusal. Wall-clock cadence is the
domain of Claude Code's interval mechanism — most representatively the
built-in `/loop` skill (e.g. `/loop 5m …` re-invokes the model every 5
minutes via the harness's `ScheduleWakeup` primitive). When the user
asks for `"5분마다 알림 줘"`, route to whatever interval mechanism the
environment provides (typically `/loop`); the model decides how each
tick emits a banner. active-notify neither owns nor blocks this path.
`/loop` is a built-in skill, not a harness primitive, so it may be
absent in some environments — when it is unavailable, the model adapts
with whatever interval-handling capability it has, including (as a
last resort) telling the user the environment can't satisfy a clock-
keyed alert.

**Distinguish from progress markers.** A request keyed to *work
progress* — `"작업이 70% 정도 끝나면"`, `"중간쯤 되면"` — is NOT clock-
keyed. The model judges progress against the work it's doing, which is
the same kind of milestone judgment a default single ARM already makes
(see the README progress-marker note). These ARM normally.

**Composite expressions** like `"5분마다 체크해서 끝나면 알려줘"` are
already handled in §2.5: the alert itself is single-milestone (`"끝나면
알려줘"`), only the *polling cadence* is clock-keyed. ARM single, let
the polling be the model's own concern.

**Anti-pattern reminder.** Do not substitute a turn-counting or
work-step-counting proxy for a real time interval (see §6.1
Clock-keyed ARM). Genuine time intervals belong to `/loop`.

### 2.9 Bare-noun clarifying-question cascade

Some utterances carry a recurrence quantifier but name no event noun
(`"매번 알려줘"`, `"반복해서 알려줘"`). §6.3 still mandates ARM —
recurrence lexicon is present — but there is no event class to capture.
A fixed degenerate class would leave the cycle stuck at the lowest end
of the §2.2 reliability spectrum. Resolve via a two-tier cascade.
Both tiers ARM in the same turn as the utterance — there is no 2-turn
durability gap where an obligation lives only in model memory.

**Tier 1 — context inference.** If the surrounding work context
implies a concrete event class as the obvious best-fit, ARM immediately
with that class. Do NOT ask. Examples:

- Mid multi-commit refactor + `"매번 알림 줘"` → class `commit`.
- Inside a test loop + `"매번 알려줘"` → class `test pass`.
- During deploy iteration + `"매번 알림"` → class `deploy`.

This is NOT self-judgment ARM. ARM is already lexically gated by the
recurrence keyword; the model only picks *which* event class best fits
the user's words, the same way §2.4 picks armCount via best-fit when
the count is ambiguous.

**Tier 2 — immediate degenerate ARM + clarifying question.** If
context yields no obvious class, the model in the SAME turn:

1. ARMs immediately with a degenerate class label like
   `"작업 단위 완료"` (`"work-unit completion"`). The flag exists from
   this turn forward — no obligation is held in model memory.
2. Emits one short clarifying question to the user (e.g.
   `"무엇마다 알림을 드릴까요? 예: 커밋마다, 테스트 통과마다"`).
3. On the user's next reply, if they name a concrete event noun, the
   model **re-ARMs** with the refined class (idempotent overwrite per
   §3 — overwrites the degenerate flag with no special mechanism).
4. If the user declines to specify or stays ambiguous, the degenerate
   ARM stays in place — tier 1 catches most cases, so degenerate
   survivors are rare.

**This is NOT §6.3 avoidance.** §6.3 forbids silent skip (refusing to
ARM and doing nothing). Tier 2 ARMs that turn — the question only
refines the class label, it does not gate the ARM itself.

**Gate — do not over-ask.** The clarifying question fires only when
BOTH conditions hold: (a) bare-noun utterance AND (b) no concrete
class inferable from context. If the utterance names an event noun
(`"각 커밋마다"`), never ask. If tier 1 best-fit succeeds, never ask.
Asking otherwise is the §6.1 Clarifying-question over-ask anti-pattern.

**Asymmetry with §2.4 armCount tiebreaks.** §2.4 favors best-fit
without asking because either count produces a working cycle. Bare-
noun without context produces a near-useless degenerate cycle — so
the question is justified when the alternative is degenerate fallback,
and ONLY then. The user is still at the keyboard at ARM time, so the
one-round exchange is cheap.

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
boundaries. If a prior turn ARMed and the current turn has not CANCELed
(neither user-explicit nor model self-cancel), the flag is still alive.
For event-scoped repeat the event class itself lives in the model's
conversation context across these turns — the flag is class-agnostic.

**FIRE-NOW is the only dispatch surface (model-driven).** Single mode
fires once per named milestone (count=1) or once per named sub-event
(count=N). Event-scoped repeat fires once per observed instance of the
armed event class — the model invokes `notify.sh fire-now <workflow>
<summary>` whenever it observes a class instance has occurred.

Dispatcher behavior:

- **Schema strict check**: schema≠3 → stderr hint + flag rm + exit 0.
- **Mode validity check**: mode ∉ {single, repeat} → stderr hint + flag
  rm + exit 0.
- **Single mode mutation**: read `fire_count` + `arm_count`. `fire_count
  + 1` reaches `arm_count` → final fire (`mv -n` atomic consume). Else
  intermediate fire (`sed -E` increment + `last_fire_at` update,
  preserve flag).
- **Event-scoped repeat mutation**: increment `fire_count` + update
  `last_fire_at` via `sed -E` rewrite, preserve flag. `arm_count`
  ignored entirely. The dispatcher is class-agnostic — it does not see
  the event class label, only that one more instance fired.
- **Banner**: `terminal-notifier -title "[cc-cmds] ${workflow}"
  -message "${summary}" -execute ':'`. `-group "cc-cmds-active-notify"`
  added only when single + `arm_count == 1` (banner replace semantics).

**CANCEL is mode-agnostic (model-driven).** `rm -f flag`. No mode check.
Three triggers (the dispatcher treats them identically):

1. Explicit user revocation (§2.3 lexicon — `"알림 취소"` etc.).
2. Model self-cancel at event-scoped repeat series end (§2.3 / §4.6 —
   model observes the recurring work is done).
3. Single mode armCount-consume (final fire's `mv -n` removes the
   flag — no separate `cancel` call needed).

## 4. When to invoke fire-now (model decision criteria)

All firing is event-cued — there is no turn-end auto-fire. The model
evaluates each observation point against the active ARM's mode.

### 4.1 Single mode (count=1, default)

Invoke `fire-now` exactly **once** when the named milestone completes.
The dispatcher consumes the flag on first fire.

### 4.2 Single mode (count=N, N>1)

Invoke `fire-now` at **each** named sub-event observation point. The
dispatcher fires N times total — intermediate N-1 (flag preserved) +
final 1 (flag consumed). Subsequent fire-now calls are silent no-op
(flag absent).

### 4.3 Event-scoped repeat mode

Invoke `fire-now` once per observed instance of the armed event class
(§2.2 / §2.4). What counts as "observed" depends on class fidelity per
§2.2 — tool-observable instances (a `git commit` exit) are
self-announcing, named semantic milestones are judged against the work
in progress, generic work-units are loosest. The dispatcher fires
unbounded times, preserving the flag, until self-cancel (§4.6) or
explicit user CANCEL. §4.4 fire-first ordering applies to each
instance.

### 4.4 Fire-now ordering within the turn (fire-first mandate)

§4.1–§4.3 decide *whether* a fire-now is owed; this subsection
decides *when within the turn* the owed call runs.

**The moment you observe that the milestone the active ARM targets has
completed — its exit code and output are in your context —
`notify.sh fire-now` MUST be your next tool call, before ANY other
tool call. This holds however you observe the completion: when it is
already in context as the turn opens (the typical background-task
re-invoke — see (s6)), fire-now is the first call of the turn; when a
call you make mid-turn surfaces it — a foreground `Bash` finishing
inline, or a `BashOutput` poll showing a background task done —
fire-now is the first call after that observation.**

Rationale: `fire-now` is auto-approved by the plugin's PreToolUse hook
— it raises no permission dialog and always runs. Any other call
placed first may hit a permission dialog and suspend the turn before
fire-now is reached, stranding the notification; the user, away from
the keyboard, then perceives an infinite hang. You cannot know which
calls the user has allowlisted, so the rule is unconditional — not
"before permission-gated calls" but before *any* call. fire-now is an
instant, fire-and-forget local-disk op; ordering it first costs
nothing.

**A failed task does not change the order.** A non-zero exit sharpens
the urge to investigate first ("let me find out why it failed") —
that urge is the §6.2 deferred-fire anti-pattern. fire-now first, the
failure in the copy; investigate after.

Mode- and count-agnostic. The trigger is a completed, unfired
milestone or event-class instance — not the mode, the fire count, or
turn position. It governs single final fires, single intermediate
fires (§4.2 count=N), and event-scoped repeat instance fires alike. If
the completion maps to one of several named sub-events and you are
unsure which, that ambiguity is not grounds to defer — fire on the
best-fit sub-event (§6.3's principle — ambiguity is not an avoidance
reason — governs ordering too).

Copy is subordinate to ordering: a banner that fires beats a perfect
banner that never fires. Build `<summary>` from the completion signal
already in context — never from a fresh verification call — using
`"성공"` / `"실패 (exit N)"` when the exit code is known (the norm; a
background shell's exit code is virtually always in hand) and `"완료"`
when there is genuinely no pass/fail signal. In single count=1 the
first fire-now CONSUMES the flag — that banner is final, so there is
no "fire a placeholder now, fire a corrected one after verifying."
Verification the user's task genuinely needs happens *after* fire-now.

### 4.5 Defensive fire-now (when an ARM may be live)

§4.4 assumes you know a fire is owed. The harder case is not knowing.
On a long task — exactly what this skill serves — earlier conversation
context, including the original ARM request, may no longer be in view;
the state flag, however, lives on disk and outlives any such loss.

**When a background task completes and you cannot positively rule out
that a notification was requested for it earlier this conversation,
fire-now first.** The dispatcher silently no-ops when no live flag
exists, so an unnecessary call is free; a skipped call when an ARM was
in fact live is the bug this skill exists to prevent. Bias hard toward
firing: a false positive is one silent no-op, a false negative is a
stranded user. Do not Read the flag file to resolve the doubt — that
Read is itself a permission-gated call that can suspend the turn;
fire-now IS the probe, dispatching if a flag is live and no-opping if
not.

This does not loosen §6.1. Defensive fire-now is *firing*, not
*arming* — it never creates a notification cycle. A banner appears only
if a flag exists, and a flag exists only because a real ARM call ran
this session; the flag, not your memory, is ground truth. What stays
forbidden is unchanged: arming on self-judgment (§6.1), and calling
fire-now when you positively know no ARM was ever placed (§6.2).

### 4.6 Self-cancel (event-scoped repeat only)

When the work that produced the recurring events has finished and no
further instances of the armed event class are expected, end the cycle
yourself via `notify.sh cancel`. Self-cancel applies ONLY to event-
scoped repeat — single mode terminates structurally (armCount consume),
and a single ARM never has a "series" to end.

**Positive criteria (when to self-cancel):**

- A multi-commit refactor armed with `commit` class has produced its
  final commit and the user's task is wrapping up.
- A test loop armed with `test pass` class has reached green and the
  user is moving on.
- A deploy iteration armed with `deploy` class has succeeded for the
  final environment.

**Ordering rule.** If the cycle-terminating event is itself an
instance of the armed class, fire-now FIRST for that final instance,
THEN call `notify.sh cancel`. Order:

```text
notify.sh fire-now <workflow> <summary>   # final instance banner
notify.sh cancel                          # close the cycle
```

The user sees the last banner and the cycle is closed. Reverse order
loses the final banner (the post-cancel fire-now is a silent no-op).
See §6.4 for the anti-pattern fence around self-cancel timing.

**Asymmetry with ARM.** ARM is forbidden on self-judgment (§6.1)
because a false-positive ARM creates an unrequested obligation —
expensive, hard to recover from. A false-positive self-cancel costs
at most one missed banner, which the user can recover by re-ARMing or
re-stating the request. Cancel is safe-directional: the model may end
on judgment; it may not start on judgment.

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

### (s3) Event-scoped repeat — `각 커밋마다` end-to-end with self-cancel

User: `"이 리팩터링 진행하면서 각 커밋마다 알림 줘"` → §2.5 Gate 2:
recurrence quantifier (`각`/`마다`) modifies event noun `커밋` → ARM
event-scoped repeat, event class `commit`. The class lives in
conversation context — the flag holds only `mode:"repeat"`.

Lifecycle:

1. Model: `notify.sh arm "각 커밋마다 알림 줘" "refactor" repeat`. Flag:
   `{"schema":3,...,"mode":"repeat","arm_count":1,"fire_count":0,...}`.
2. Model edits files, runs tests, then `git commit -m "..."` (exit 0,
   sha `abc123`). The Bash exit is an observed `commit` instance.
3. Model's NEXT tool call (§4.4 fire-first): `notify.sh fire-now
   "commit" "abc123 완료"`. Banner emitted (no `-group` — pile-up
   intentional), `fire_count` 0→1, flag preserved.
4. Model continues — more edits, `git commit -m "..."` (sha `def456`).
   Same pattern: `notify.sh fire-now "commit" "def456 완료"`,
   `fire_count` 1→2.
5. The refactor's final commit lands (sha `ghi789`, exit 0). Model
   judges the work is done — no further commits expected.
6. **Final-instance ordering (§4.6).** Model fires for the last
   instance FIRST: `notify.sh fire-now "commit" "ghi789 완료 — 최종
   커밋"`. `fire_count` 2→3, flag preserved.
7. THEN model self-cancels: `notify.sh cancel`. Flag removed. The cycle
   ends with the user seeing the last commit banner.

If the user had said `"알림 취소"` at step 4, that explicit CANCEL
would have ended the cycle without self-cancel ever firing — both
paths route to the same `notify.sh cancel`.

### (s3b) Enumeration-defuse — `각각` as distributive quantifier

User: `"lint 끝날 때, 빌드 끝날 때, 배포 완료 시 각각 끝나면 알려줘"`.

§2.5 Gate 1: explicit enumeration of 3 named sub-events (`lint 끝날
때`, `빌드 끝날 때`, `배포 완료 시`). `각각` is the distributive
quantifier over the finite list, NOT a repeat trigger. → ARM single
`--count=3`. Subsequent flow follows (s2) with 3 fires instead of 2.

### (s3c) Loose event class — `각 기능 완성마다`

User: `"각 기능 완성마다 알림 줘"`.

§2.5 Gate 2: `각`/`마다` modifies `기능 완성` → ARM event-scoped repeat,
event class `feature completion`. Per §2.2 spectrum this is a *named
semantic milestone* class — not as crisp as `commit` (no exit code
boundary), but the model judges completion against the work it's doing.
fire-now timing is the model's call; firing on each feature it
considers complete is correct. Self-cancel when the broader work
scope wraps.

### (s3d) Clock-keyed delegation — `5분마다`

User: `"5분마다 알림 줘"`.

§2.6: clock-keyed cadence. Model does NOT call `notify.sh arm`. Routes
to Claude Code's interval mechanism — most representatively `/loop 5m
…`. The model decides how each `/loop` tick emits a banner. active-
notify is uninvolved.

Contrast: `"5분마다 체크해서 끝나면 알려줘"` (§2.5 hybrid). The polling
is `/loop`'s job, but the alert request itself is `"끝나면 알려줘"` —
single ARM via active-notify, the polling separate.

### (s3e) Bare-noun cascade — `매번 알려줘`

**Tier 1 context-rich variant.** Mid-conversation the model is doing a
multi-commit refactor. User says `"매번 알려줘"`. §2.9 tier 1: context
implies `commit` as best-fit. Model: `notify.sh arm "매번 알려줘"
"refactor" repeat` with class `commit` held in context, NO question
asked. Subsequent flow = (s3).

**Tier 2 cold-context variant.** Conversation just started; user opens
with `"매번 알려줘"`. §2.9 tier 2: no class inferable from context.
Same turn, model (a) ARMs immediately with degenerate class label:
`notify.sh arm "매번 알려줘" "general" repeat`, then (b) emits one
short reply to the user:

> `"무엇마다 알림을 드릴까요? 예: 커밋마다, 테스트 통과마다, 배포마다."`

User replies `"테스트 통과마다"`. Model **re-ARMs** with refined class
`test pass` — `notify.sh arm "테스트 통과마다 알려줘" "test loop"
repeat`. The re-ARM is an idempotent overwrite (§3) — no special
mechanism.

If the user instead replies `"아무거나 알아서"` or stays vague, the
degenerate ARM stays in place. Tier 1 catches most real cases so
degenerate survivors are rare.

### (s4) PERMISSION TEST routing

User: `"알림 테스트 한 번 해줘"`.

§2.0 routing: clauses (a)/(b)/(c) all fail (no separate task, "테스트"
binds to "알림", no ARM companion) → §7 inline bypass. Model does NOT
call `notify.sh arm` — invokes the inline Bash expression in §7 instead.

### (s5) CANCEL

User: `"역시 알림 그만"` mid-cycle → `notify.sh cancel` → flag deleted
→ any subsequent `fire-now` is silent no-op (flag absent).

### (s6) Background-task completion — fire-first ordering

User: `"안드로이드 빌드 백그라운드로 돌려줘, 끝나면 알림 줘"` → ARM
single (default count=1) → model launches the build as a background
shell → turn ends (build still running → no fire-now yet).

Later: the background build completes and the harness re-invokes the
model in a fresh turn. The completion — exit code, output tail — is
already in context; the ARM flag is still alive (§3).

1. The model's FIRST tool call is `notify.sh fire-now "build" "성공"`
   — `<summary>` taken from the exit code already in hand, NOT from a
   fresh log scan.
2. ONLY THEN does the model verify results (e.g. `find ... -name
   'logcat-*.txt' | xargs grep ...`). If that call raises a permission
   dialog and suspends the turn, the banner has already fired — the
   user is not stranded.

**Failed-build variant**: the build exits non-zero. Same ordering —
`notify.sh fire-now "build" "실패 (exit 1)"` first, *then* investigate.
Diagnosing the failure before notifying is the §6.2 deferred-fire
anti-pattern.

**Mid-turn-observation variant**: rather than a re-invoke, the model
polls a running background build with `BashOutput` mid-turn and sees
it finished. fire-now is the first call *after* that `BashOutput` — not
deferred to turn end.

**Anti-pattern**: verification `find`/`grep` first → permission dialog
→ turn suspends → fire-now never reached → the user, waiting on a
banner, perceives an infinite hang. See the §6.2 deferred-fire
anti-pattern.

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
- **Clock-keyed ARM.** Arming on wall-clock cadence — recurring
  intervals (`"5분마다"`) or one-shot future delays (`"30분 후"`).
  active-notify's lifecycle is event/turn-cued, not clock-cued; route
  clock-keyed requests via §2.6 to `/loop` instead. Do NOT substitute
  a turn-counting or step-counting proxy for a real time interval —
  genuine time intervals belong to `/loop`. Progress markers
  (`"70% 정도"`) are NOT clock-keyed and ARM normally.
- **Event-class inflation.** Expanding the captured event class beyond
  the noun the user actually named. `"커밋할 때마다"` is class
  `commit`, NOT "any git operation"; `"테스트 통과할 때마다"` is
  `test pass`, NOT "any test event". Stay literal to the user's noun
  to keep fire-now timing crisp.
- **Clarifying-question over-ask.** Per §2.9 the clarifying question
  is for bare-noun + no-context only. Asking when the user named an
  event noun (`"각 커밋마다"`) or when context unambiguously implies a
  class (tier 1) is the over-ask anti-pattern. The asymmetry is:
  ask only when the alternative is a degenerate fallback cycle.

### 6.2 fire-now (call forbidden)

- **fire-now when no ARM was ever placed.** If you positively know no
  notification was requested this conversation, calling fire-now is a
  model bug — the dispatcher no-ops, but the call should not exist.
  This forbids the *known*-no-ARM call only. Not remembering an ARM is
  uncertainty, not knowledge — it routes to §4.5 (defensive fire-now),
  not here. Defensive fire-now under genuine uncertainty whether a
  live ARM exists is therefore correct, not forbidden — the
  dispatcher's no-op-on-absent-flag resolves it safely.
- **Instance-skip in event-scoped repeat.** You observed an instance of
  the armed event class but judged it "too minor" or "not significant
  enough" and skipped fire-now. Event-scoped repeat fires **every**
  observed instance of the class until self-cancel or CANCEL. Self-
  judgment about instance significance is §6.1 self-judgment ARM in
  fire-now clothing.
- **Mid-cycle re-fire after final consume.** In `single --count=N`, the
  N+1-th fire-now is silent no-op (flag consumed). Calling it does no
  harm but indicates the model lost track of cycle state.
- **fire-now deferred behind another tool call.** You have observed a
  milestone under the active ARM complete, but you run a verification
  or inspection call first — a `find`/`grep` over logs, a `Read`, an
  `Edit`. That call can raise a permission dialog and suspend the turn
  before fire-now runs; the banner never fires and the user, away from
  the keyboard, perceives an infinite hang. fire-now is auto-approved
  and never blocks — it MUST be the first tool call after you observe
  the completion (§4.4). A failed task is the strongest form of this
  trap: the urge to diagnose before notifying must yield — fire first,
  investigate after.

### 6.3 Ambiguity-avoidance (inverse boundary — call forbidden)

**Trigger 어휘가 발현된 발화에서 mode/armCount/sub-event/event-class
식별 ambiguity가 ARM 회피 사유가 될 수 없다.** 어휘가 명시적이면
best-fit mode + best-fit count + best-fit event class로 ARM 후 관찰
가능한 sub-event/event-class instance 시점마다 fire-now 호출. Issue
#12의 silent skip이 이 boundary의 negative anchor — 발화 명시성 입증
후 model self-judgment로 회피하지 말 것.

**Inverse boundary**: 본 규칙은 어휘 부재 시 ARM을 끌어오는 권한이
아님 — 어휘 부재 시 ARM은 §6.1 self-judgment 위반. 어휘 gate는
necessary AND sufficient — 양쪽 boundary 독립적. bare-noun + 무맥락
케이스는 §2.9 cascade가 tier 2 degenerate ARM + clarifying question으로
즉시 ARM을 보존하며, 이는 회피가 아니라 ARM 실행 + 클래스 refine 단계
이므로 §6.3 위반이 아니다.

### 6.4 Self-cancel (event-scoped repeat only)

Model-issued `notify.sh cancel` (self-cancel) is event-scoped repeat
only. The following are anti-patterns.

- **Single-mode self-cancel.** Single mode terminates structurally
  (armCount consume) or via explicit user CANCEL. Self-cancelling a
  single ARM cuts the cycle short and can drop a final or intermediate
  fire.
- **Mid-series self-cancel.** Cancelling before the series has
  genuinely ended erases every still-expected event banner. Self-cancel
  applies only when no further class instances are expected — a
  temporary lull or work pause is not termination.
- **Self-cancel in place of the final fire-now.** Calling `cancel`
  without first firing for the series-terminating instance loses the
  final banner (the post-cancel fire-now is a silent no-op). §4.6
  ordering is unconditional: fire-now FIRST, cancel SECOND.

Positive criteria for self-cancel — true series end, fire-first
ordering — are defined in §4.6. Anchoring rationale: the asymmetry
"end on judgment OK, start on judgment forbidden". A self-cancel
false positive costs one missed banner (recoverable); an ARM false
positive creates an unrequested obligation (hard to recover) — the
two are not symmetric.

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
