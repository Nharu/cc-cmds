---
name: active-notify
description: 사용자가 (a) 1인칭 알림 요청 어휘 ("끝나면 알려줘"/"매번 알려줘"/"시작할 때랑 끝날 때 알림"), (b) 권한 테스트 어휘 ("알림 테스트"/"test alert"/"permission test"), 또는 (c) 취소 어휘 ("알림 취소"/"stop the alerts") 발화 시 호출되는 macOS 데스크탑 알림 헬퍼 (model-invoked, 슬래시 커맨드 없음). 어휘 부재 → 호출 금지·모델 자체 판단 ARM/bypass 절대 금지. 어휘 발현 → mode·armCount·sub-event ambiguity가 회피 사유 아님 — best-fit으로 ARM 후 sub-event 시점마다 fire-now 호출.
when_to_use: |
    **PERMISSION TEST 제외 (1순위)**: "테스트"/"test" + 알림 동사 → §7 inline bypass. 단 3절 중 ANY ONE 발현 시 ARM으로 재라우팅: (a) 별도 작업 컨텍스트 (b) noun-form (c) ARM-eligible companion. 상세는 body §2.0.

    **ARM · 모드 선택**: 1인칭 알림 요청 어휘 발화 직후 ARM. 열거된 named sub-event ≥2 → single + `--count=N` — 단 재발 한정사(`매`/`마다`/`매번`/`각`/`반복`/`every`/`each`)+반복 클래스 항목이면 아래 repeat으로. 열거가 아니고 한정사가 있으면 event-scoped repeat. **repeat 라벨**은 한정사가 수식하는 명사(없으면 body §2.9), 명명된 것 전부의 합집합으로 한 사이클. 부재 → single. **벽시계 요청은 ARM하지 않는다** — 반복 cadence("5분마다")도 일회성 지연("30분 후")도 body §2.6의 스케줄러 위임으로 보낸다.

    **발화 트리거**: 관측된 이벤트 클래스 인스턴스마다 `fire-now` 1회. **턴 종료 자동 발화는 없다.** 인스턴스 경계가 없는 제네릭 클래스에 한해 user-task 도구 호출이 1회 이상 있었던 턴의 종료를 인스턴스 1회로 본다(외부 스케줄러가 연 턴은 인스턴스가 아니다).

    **종료**: 사용자 CANCEL 어휘 → `notify.sh cancel`. **self-cancel은 repeat 전용**, 그리고 **전 인스턴스가 모델이 디스패치한 것의 완료**일 때만 허가 — 아니면 금지하고 CANCEL 대기. **마지막 인스턴스가 종료 지점이면 그 인스턴스의 fire-now를 먼저 호출하고 그다음 cancel** — 뒤집으면 마지막 배너를 잃는다.

    armCount · fire-first · self-cancel · anti-pattern은 body §1.1/§2/§4/§6.
disable-model-invocation: false
usage: "(자동 호출 — 슬래시 커맨드 없음. 사용자가 1인칭 알림 요청 어휘 발화 후 모델이 ARM, single 모드는 armCount회 fire-now 후 만료, event-scoped repeat 모드는 관측된 인스턴스마다 fire-now 후 사용자 CANCEL 또는 모델 self-cancel로 종료.)"
options: []
notes: |
    cc-cmds 유일의 model-invoked 헬퍼이며 슬래시 커맨드 surface가 없다. 모델은 frontmatter
    `description` + `when_to_use`로 호출 결정을 내리고, SKILL.md body의 ARM/FIRE-NOW/CANCEL
    contract + canonical lexicon에 따라 모드와 armCount를 선택한다. macOS 외 / `terminal-notifier`
    미설치 환경은 silent no-op. 최초 사용 전 macOS 알림 권한 승인 필요 — "알림 테스트 한 번 해줘"
    발화로 권한 다이얼로그 트리거.
---

# active-notify

Read `${CLAUDE_SKILL_DIR}/../_common/notify.md` once per session to load the shared procedure
(preconditions, fire copy synthesis, failure handling, dispatcher
invariants). The model owns the entire ARM / FIRE-NOW / CANCEL lifecycle —
there is no turn-end auto-fire. The plugin's PreToolUse hook
self-approves the dispatcher's Bash invocations when they are written
as §1 shows — each plain and on a command line of its own — so the
Bash permission dialog does not surface for them.

## 1. Calling convention

The model directly invokes four subcommands of this skill's
`scripts/notify.sh`. **Invoke it by absolute path** — the skill
directory's absolute path followed by `/scripts/notify.sh` — so the
shell working directory does not matter. The examples below abbreviate
that path to its final three segments,
`active-notify/scripts/notify.sh`. The plugin's PreToolUse hook
self-approves the call only when the whole command line is one plain
invocation of that path — optionally preceded by the bare word `bash`
and nothing else — with one of its subcommands, written bare rather
than quoted, and **the path absolute**, as the examples below now write
it: a relative path, a `..` climb, a glob or a tilde is rejected even
though it ends in those same segments. `/absolute/path/to/` there stands
for the installed skill directory; what is load-bearing is the leading
slash, not those words.
Anything else falls through to the Bash permission dialog — chained with
`;` or `&&`, piped, redirected, wrapped in a subshell or a substitution,
or split across lines — including a compound line that contains a
perfectly good call, so each invocation goes in a Bash call of its own
(§4.6). The subcommands are local-disk file ops and complete
instantly.

```bash
# Arm a new notification cycle. mode argument is optional (default "single").
# --count=N is optional parse-anywhere flag for single-mode multi-sub-event
# ("시작할 때랑 끝날 때" → --count=2). default 1, normalize to 1 if not in [1..16].
bash /absolute/path/to/active-notify/scripts/notify.sh arm "<request_text>" "<context_hint>" [single|repeat] [--count=N]

# Event-instance fire — model-driven, the ONLY dispatch surface of an
# ARM cycle. Called at each observed instance of the armed event class
# (a named sub-event in single --count=N, a class instance in repeat).
bash /absolute/path/to/active-notify/scripts/notify.sh fire-now <workflow> <summary>

# State-independent banner — belongs to NO ARM cycle. Reads and writes no
# flag and takes no lock, so it cannot disturb a live cycle. Uses its own
# banner group so it never replaces a cycle's completion banner. This is
# what the §2.6 scheduler delegation emits.
bash /absolute/path/to/active-notify/scripts/notify.sh fire-oneshot <workflow> <summary>

# Cancel — mode-agnostic flag delete.
bash /absolute/path/to/active-notify/scripts/notify.sh cancel
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

**Scope of this table: ARM-cycle banners only.** `fire-oneshot` banners
are not rows here and no line above governs them. The dividing line is
not "does it go through the dispatcher" — `fire-oneshot` does — but
"does it belong to an ARM cycle". It does not: it has no mode, no
armCount, and no flag to consume, and it carries its own banner group
precisely so it never lands in the group semantics described above.

## Control-Flow Invariants

These five rules govern when a banner is owed, in what order it is
dispatched, and when a cycle ends. They are gathered here — after §1
defines the calling convention and the mode vocabulary they reference,
before the lexicon that routes into them — so that the whole termination
contract is one contiguous block rather than five rules scattered across
§2, §4 and §6. Each rule states its consequence, because an ordering
sentence without its consequence reads as style and invites reordering.

### CFI-1 — No turn-end auto-fire; the instance floor
Firing is cued by **observed instances of the armed event class**, never
by the turn boundary. There is no hook-driven and no model-driven
turn-end auto-fire; a turn in which no instance occurred owes no
banner. The one floor: for a **generic class with no observable
instance boundary** (`"단계"`, a degenerate `"작업 단위 완료"` label from
the §2.9 cascade), treat the end of a turn that contained **at least one
user-task tool call** as one instance. **A turn opened by an external
scheduler is not one of those**; the axis is *who opened the turn*, not
which mechanism did it.

### CFI-2 — Fire-first within the turn
The moment an owed instance is observed, `notify.sh fire-now` is the
**next tool call** — ahead of any verification, formatting, or summary
step. Anything placed in front of it can suspend the turn on a
permission dialog and strand the banner, which is the exact failure the
whole skill exists to prevent.

### CFI-3 — Fire when unsure; never re-read the flag
When it is unclear whether an ARM is live, **fire anyway**. The
dispatcher silently no-ops an absent flag, so a spurious `fire-now`
costs nothing, while a skipped one is invisible to an absent user. Do
NOT read the flag file to decide — the flag is dispatcher-private
state, and a read-then-decide detour reintroduces a race the lock
closes.

### CFI-4 — Self-cancel scope and ordering
Self-cancel applies **only** to event-scoped repeat; single mode
terminates structurally when armCount is consumed. It is permitted only
when **both** hold: (a) every instance this cycle fired was the
completion of something the model itself dispatched, and (b) the user's
task finishes this turn with no step left in the model's own plan that
would produce another instance. If (a) fails, **self-cancel is
forbidden** and the cycle waits for user CANCEL. **When the
cycle-terminating event is itself an instance, call `fire-now` for it
FIRST and `cancel` second**; the reverse order makes the final
`fire-now` a no-op and loses that banner permanently.

### CFI-5 — Clock-keyed requests are never ARMed
A request keyed to wall-clock time — a recurring cadence (`"5분마다"`)
or a one-shot delay (`"30분 후"`) — must NOT reach `notify.sh arm`. The
ARM/fire-now lifecycle is event-cued, so arming on a clock-keyed
request produces a flag that never fires. Route both branches to the
scheduler delegation in §2.6, and never substitute a turn-counting or
work-step-counting proxy for a real interval. Progress markers
(`"70% 정도 끝나면"`) are **not** clock-keyed and ARM normally.

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

**Worked counter-example** — `"테스트 시작할 때랑 끝날 때 알림 줘"`
(Issue #12 reproducer):

- (b) ✓ "테스트" = 실행할 작업 (noun-form).
- (c) ✓ "시작할 때랑 끝날 때" = 2개 sub-event boundary + "알림 줘" = ARM
  request.
- → ARM 분기 (single, `--count=2`). bypass 절대 금지.

**Worked hybrid example** — `"매번 알림 테스트"`:

- `매번` is ARM lexicon; `알림 테스트` looks like PERMISSION TEST. This
  section owns the routing, so it is resolved here rather than in the
  disambiguator.
- (c) ✓ ARM-eligible companion present (`매번` is recurrence lexicon).
- → ARM branch, event-scoped repeat. Bypass routing requires the
  **absence** of ARM companions; one clause is enough to lose it.

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
  are lowest fidelity — the utterance supplies no observable instance
  boundary at all. For exactly this band, **CFI-1's instance floor
  defines one**: the end of a turn that contained at least one
  user-task tool call counts as one instance. The floor is what keeps
  this band from degenerating into a cycle that never fires, and it
  applies to this band only — the two above it have real boundaries and
  must not borrow it.

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
creates an unrequested obligation. The model may end a cycle on
judgment; it may not start one. The permitting conditions and the cost
of getting it wrong are both in §4.6 — do not re-derive them here.
Ordering rule when the last instance is the cycle terminator:
`notify.sh fire-now` for that final instance FIRST, then
`notify.sh cancel` (§4.6, §6.4).

**When a scheduled job is also live, cancel BOTH.** An explicit
revocation turns off everything that is running: delete the scheduled
job (§2.6) *and*, if an ARM cycle is live, call `notify.sh cancel` too.
**Never turn off one of them and report that it is cancelled** — the
user then believes they are done while banners keep arriving. This
state is one the design actively produces: §2.6's event-anchor offer
invites the very user who made a clock request to open an event cycle,
so both can be live at once from a single conversation.

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
- An enumeration that overlaps a recurrence quantifier (`"몇 단계 끝날
  때마다"`, `"각 커밋마다, 각 배포마다"`) is not decided here. §2.5 Gate
  1's exclusion clause owns that parse, and its outcome is what selects
  which of this section's two extractions applies.
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

**Gate 0 — separate the clauses, then exclude wall-clock alerts.**

*(A) Gate the ALERT clause only.* An utterance can carry a work clause
and an alert clause. A work clause that happens to name an interval
(`"5분마다 체크해서"`) is how the model does the work it was given; it
is not an alert request, and this skill neither owns it nor routes it
anywhere. In particular do **not** hand it to §2.6 — that section is a
notification-only procedure whose emit step is fixed to a banner
command, so a polling requirement arriving there finds no procedure
that fits and, at worst, gets a scheduled banner in place of the
polling that was actually asked for. The point of (A) is that a
non-alert clause is not this cascade's business, not that some other
section handles it.

- `"5분마다 체크해서 끝나면 알려줘"` → the alert clause is `"끝나면
  알려줘"`, a single terminal moment; it falls through to Gate 3 →
  single `--count=1`. The polling stays with the model.

*(B) Exclude wall-clock alert clauses.* If the ALERT clause itself is
keyed to wall-clock time — a recurring cadence (`"5분마다 알림 줘"`) or
a one-shot delay (`"30분 후 알림 줘"`) — do NOT ARM; route to §2.6
(CFI-5). **Both branches are excluded, not just the recurring one.**

**Gate 1 — explicit enumeration.** Does the alert clause enumerate **≥2
named sub-events**? Before answering yes, check whether a recurrence
quantifier (`매`/`마다`/`매번`/`각`/`반복`/`every`/`each`) appears
anywhere in the alert clause. **If none does, the enumeration is finite
by default — apply Gate 1**, even where an item names a noun that could
recur: the user listed the occasions and asked for nothing beyond them,
and every gate downstream of this one keys on a recurrence quantifier,
so an utterance carrying none cannot be caught by any of them. That
dependency is why this guard is stated here rather than left implicit —
widening a downstream gate to fire without a quantifier removes the
ground this default stands on. If a
quantifier is present, take the enumerated items one at a time and ask
of each: is this a **finite moment that passes once**, or a **class
that recurs**? If even one item is a recurring class, the enumeration
is not closed — do NOT apply Gate 1; send the utterance down to Gate
2a. Otherwise → single mode with `--count=N`, N = the number of
enumerated items. The distributive reading of `각`/`각각`/`each` — a
quantifier over a finite list, not a repeat trigger — holds **only when
every item is a finite moment**; where it does not, the quantifier
keeps its recurrence meaning and the parse belongs to Gate 2a.

Connectives seen in practice: `,`/`랑`/`이랑`/`와`/`과`/`하고`/`및`/
`그리고`/`and`. **This list is illustrative, not closed** — decide by
whether two or more named moments are being listed, not by whether the
joining word appears above. A connective missing from the list is a gap
in the list, not evidence of a single moment.

- `"시작할 때랑 끝날 때 알림 줘"` → single `--count=2`.
- `"시작할 때와 끝날 때 알림 줘"` → single `--count=2`.
- `"lint 끝날 때, 빌드 끝날 때, 배포 완료 시 각각 알림"` → single
  `--count=3`. `각각` is distributive over the 3-item list.
- `"각 커밋마다, 각 배포마다 알림 줘"` → **not** Gate 1. Both items are
  recurring classes and a quantifier is present, so the enumeration is
  not closed and it falls through to Gate 2a.
- `"커밋할 때랑 배포할 때 알림 줘"` → single `--count=2`. Both nouns
  name classes that could recur, but no quantifier appears anywhere, so
  the enumeration is finite by default and Gate 1 applies.

**Gate 2a — recurrence quantifier modifying a NAMED noun or event
phrase.** Otherwise, if `매`/`마다`/`매번`/`각`/`반복`/`every`/`each`
modifies a noun or event phrase → event-scoped repeat (§2.2), and that
noun is the event class.

**When Gate 1 sent the utterance here, or when more than one class is
named, ARM one cycle whose class label is the union of everything the
user named by name** (`commit or deploy`, `start or commit`) — never
one cycle per class.
`arm` is an unconditional idempotent overwrite (§3), so a second ARM
would erase the first with nothing said; and narrowing to a single
representative class is the mirror image of §6.1's Event-class
inflation — that anti-pattern stretches the class past the noun the
user gave, this one drops a noun the user did give, and it silently
costs every banner of the dropped class. Fire for an observed instance
of **any** member class, and end the cycle only when no member class
has another instance coming (§4.6). A finite moment that arrived here
inside a mixed enumeration (Gate 1) joins the same label as a member —
`start or commit` — on the same principle: nothing the user named by
name is dropped, and in repeat mode a member that occurs once simply
fires once.

- `"매 커밋 후 알려"` → event-scoped repeat, class `commit`.
- `"각 커밋마다 알림"` → event-scoped repeat, class `commit`.
- `"각 커밋마다, 각 배포마다 알림 줘"` → event-scoped repeat, one cycle,
  class `commit or deploy`.
- `"시작할 때랑 각 커밋마다 알림 줘"` → event-scoped repeat, one cycle,
  class `start or commit`. Gate 1 sent it here because one item is a
  recurring class; the finite moment joins the label as a member and
  fires once.
- `"매 단계마다 알림"` → event-scoped repeat, class `step` — a generic
  work-unit class, so the CFI-1 instance floor supplies the boundary
  the words do not.

**Gate 2b — recurrence quantifier with NO noun to modify.** Otherwise,
if the quantifier is present but names nothing (`"끝날 때마다"`,
`"매번 알려줘"`) → event-scoped repeat via the §2.9 cascade, which
resolves the class label. ARM still happens in this same turn; the
cascade only refines what the class is called.

**Gate 3 — no recurrence quantifier.** Otherwise → single `--count=1`.

- `"끝날 때"`, `"끝나면 알려줘"` → single.

**The cascade is complete.** Every alert clause exits at exactly one
gate: it is wall-clock keyed (Gate 0B) or it is not; if not, it
enumerates two or more named sub-events that Gate 1's quantifier test
leaves finite (Gate 1) or it does not; if not, it carries a recurrence
quantifier with a noun (Gate 2a), without one (Gate 2b), or not at all
(Gate 3). There is no "none of the above"
exit, and in particular no exit that quietly skips ARM — declining to
ARM is Gate 0B's outcome alone, and that branch is a delegation that
speaks, never a silent skip (§6.3).

### 2.6 Clock-keyed timing → scheduler delegation

When the user's alert request is keyed to **wall-clock cadence** — a
recurring interval (`"5분마다 알림 줘"`) or a one-shot future delay
(`"30분 후 알림 줘"`) — do NOT call `notify.sh arm` (CFI-5). The
ARM/fire-now lifecycle is event-cued, and the dispatcher owns no timer,
so arming a clock-keyed request produces a flag that will never fire.

This is a **delegation, not a refusal**, and it takes all four steps
below. Step 0 is not an optional pre-check — it is the only thing
standing between this delegation and a new silent failure of its own.

**Step 0 — precondition check, BEFORE scheduling.**

```bash
PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"; [ "$(uname -s)" = Darwin ] && command -v terminal-notifier >/dev/null
```

If it fails, **do not schedule** — say what you cannot do (see the
closing contract below). The dispatcher exits 0 in silence on a
non-Darwin host and on a missing binary, so scheduling anyway buys a
turn that opens half an hour later, produces nothing, and has no one
present to notice. The interval-skill route this replaced caught the
failure by accident — its t=0 banner was a de facto precondition check.
The scheduler has no t=0 execution, so that safety net is gone and this
check replaces it deliberately.

Two notes on the command itself. The `PATH` prefix mirrors the one the
dispatcher applies to itself — without it a host where the dispatcher
*can* fire is falsely rejected here, and the guard meant to prevent a
silent failure would instead invent a false refusal. And this command
is **not** covered by the PreToolUse hook (`uname` and `command -v`
match no hook pattern), so it goes through the normal permission gate;
the exposure is small because it runs in the same turn the user just
asked, when they are most likely still at the keyboard. The
single-command restriction that governs the SCHEDULED prompt below does
**not** apply to this one — it is never queued.

**Availability probe — a different shape from a skill probe.** The cron
tools are **deferred** tools: they appear in the deferred-tool name
list rather than among the loaded schemas, and their schemas must be
loaded with `ToolSearch` before the first call. A probe that inspects
loaded schemas answers "absent" every single time and falls through to
the fallback — a silent failure wearing a refusal's clothes. An
interval SKILL being present in the skill list implies nothing about
the cron tools; they are exposed by different paths.

**Load the schemas here, before the clock is read.** The two-minute
margin opens at the `date` call below, so a `ToolSearch` done ahead of
it costs nothing while the same call made after it spends that margin —
once `date` has run, exactly one action remains and it is `CronCreate`.
If the schemas cannot be loaded at all, that is an **absent scheduler**
and it takes the ladder's last rung; it is not a malformed expression,
so it is neither recomputed nor retried.

**schedule — call the scheduler yourself.** Do not hand the user a
command to run: someone who has walked away cannot tell an unrun
command from a refusal. Both branches go to the scheduler; the interval
SKILL route is gone entirely.

- **one-shot delay** → `CronCreate` with `recurring: false` and a
  5-field expression pinning minute, hour, day-of-month and month
  (day-of-week `*`).
- **recurring cadence** → `CronCreate` with `recurring: true` and an
  interval expression (`*/5 * * * *`).

The scheduled prompt must be **one command line** — no `&&`, no command
substitution, no redirection, **and no line break**. The hook
self-approves a single simple `notify.sh` invocation and nothing else,
so a compound line does not match it at all: the firing turn then stops
on a permission dialog that no one is present to answer. The matcher is
anchored to the whole command line, so a second line makes it no longer
lone and fails the same way and for the same reason (§4.6). A compound
line also widens the surface the creation classifier reviews, and the
session-id injection binds to its first command only.
Keep the returned job ID: it is the only handle on the reservation, and
the disclosure step promises the user you still have it.

Three rules govern scheduling.

- **The two-minute floor is a correctness rule, not a courtesy.** The
  next-match search begins at the start of the NEXT minute, so the
  minute in progress can never match. A one-shot expression pins
  minute, hour, day and month, so one landing on the minute in progress
  does not fail — it matches a year later. It validates, it reports
  success, and it never fires. One minute is not enough: the clock
  moves between computing the time and the call landing, and crossing a
  single minute boundary strands it for a year. For a request under two
  minutes, do NOT refuse — schedule at +2 minutes and say that is what
  you did. The one exception is a user-named clock time less than two
  minutes away: do not schedule it — emit the banner immediately with
  `notify.sh fire-oneshot` (§1), and disclose that you fired early
  instead of scheduling. Not `arm`, which CFI-5 forbids here, and not
  `fire-now`, which no-ops in silence without a live flag. Ninety
  seconds early beats a year late.
- **Never compute the date yourself.** Month rollover, DST, and
  "tomorrow" near midnight are the failure points. Take all four fields
  from a single call — `date -v+30M '+%-M %-H %-d %-m'` — and make
  `CronCreate` your very next action, with no tool call and no output
  in between. The margin the two-minute floor buys is exactly one
  minute between reading the clock and the job landing; whatever you do
  in between spends it. A time the user named outright is the same call
  with absolute flags rather than an offset (`date -v+1d -v9H -v0M
  '+%-M %-H %-d %-m'` for `"내일 오전 9시"`), so the arithmetic stays
  with `date` in that case too.
- **Minute selection.** If the target is relative or approximate and
  the computed minute is `0` or `30`, add one minute. The reason is
  structural — those two marks carry jitter and other minutes do not —
  and not any particular magnitude, so put no figure in this text or in
  what you tell the user. If the user named the exact time, leave it.

**emit — `notify.sh fire-oneshot <workflow> <summary>`.** As a step of
this procedure it is not a command you run now: it is the single line
`schedule` puts in the queue (the sub-two-minute exception above is the
one place this command runs immediately, and that is not this step).
§1's absolute-path requirement applies to it with full force — the
firing turn has no working directory you control and the queued string
is never re-derived, so a relative path there ends that turn at exit
127 with no one present to see it. It reads and writes no flag, takes
no lock, and uses its own banner group, so a live ARM cycle is
untouched and no completion banner is replaced.

**disclose — four things, all required**: what you started, when it
will sound, how to stop it, and how it ends by itself.

- Give the firing time as a **concrete local clock time**, never the
  user's relative phrase, and keep internals out — no cron expression,
  no job ID.
- **Stopping means deleting the scheduled job**, not `notify.sh cancel`.
- How it ends differs by branch: the one-shot has no expiry and deletes
  itself once it fires; the **seven-day expiry belongs to the recurring
  branch only**. The reservation disappears when the session ends, and
  that follows from how you called the scheduler rather than from the
  environment — say it that way.
- **Do not tell the recurring branch that the first alert arrives
  immediately.** There is no t=0 execution; the first banner lands on
  the first interval boundary. What fired immediately on the old route
  was that skill's own prompt, not scheduler behavior.
- **Quote no delay figures and do not write `"정확히"`.** Tolerance is a
  runtime setting, and the numbers printed in tool documentation are
  not what the code falls back to. If a bound is genuinely needed, the
  only statically provable one is `min(period, 30 minutes)`.
- **State the delivery condition once**: scheduled jobs fire while
  Claude Code is running and between tasks, so a busy session delays
  them.

**Offer the event anchor in the same breath.** A clock cadence is
usually a stand-in for a completion the user could name, and an
event-anchored cycle carries none of the constraints above. Add one
line — *"커밋마다 / 테스트 통과마다로 바꾸시면 이 스킬이 직접
처리합니다"* — and proceed. **Deliver the delegation first and never
hold the wake waiting for an answer**: a question thrown at an absent
user is a silent failure with an extra step. This is the only path back
from a clock request to an event-scoped cycle.

**Fallback ladder — no rung ends in silence.** This branch is not
hypothetical: the scheduler gate can be switched off by environment
variable, and the tools were genuinely absent in some contexts. Every
rung ends in a line the user can see.

- **Scheduling cap exceeded** — say first, in the same reply, that you
  reserved nothing; then list the reservations with `CronList` (load
  its schema with `ToolSearch` as above) and ask which job to free.
  Never delete someone else's job to make room, and never hold the turn
  waiting for the answer — a question is all this rung produces, and a
  question thrown at an absent user is a silent failure with an extra
  step. If they name one, delete it with `CronDelete` and retry.
- **Malformed expression** — recompute once, retry once.
- **`durable` refused in a teammate context** — quietly drop to
  session-scoped and retry once.
- **Classifier or permission refusal** — do not retry with reworded text.
- **Last rung** — say plainly that you cannot do it. Never fall back to
  `notify.sh arm`; that strands a flag which cannot fire.

`durable` is omitted by default, which makes the reservation
session-scoped. That is a consequence of how you called the scheduler,
not a property of the environment, and the disclosure says so. Pass
`durable: true` only on an explicit request for persistence — and
because such a request can be **quietly downgraded**, read the result's
persistence sentence before disclosing and report **what the result
says, not what you asked for**.

**Every path that ends with no reservation ends out loud** — a failed
Step 0, an absent scheduler, and every rung of the ladder above that
stops there, without exception. (A rung that retries into a reservation
is not such a path, and the `durable` downgrade is told to make its
internal step quietly.) None of them may end at "did not schedule" —
say what you could not do and why. Declining to ARM a request the skill
cannot serve is not the ambiguity-avoidance §6.3 forbids; staying quiet
about it is.

**Recovering a lost job ID.** The disclosure promises the user you can
stop it, yet the ID lives only in context and micro-compaction empties
tool results wholesale, newest-first. If a cancel request arrives after
the ID is gone, load the cron schemas with `ToolSearch` as above and
list the reservations with `CronList`. Each row opens with the job's own
id, untruncated — that id is what `CronDelete` takes, so recovery does
not depend on your having kept anything. `CronList` and `CronDelete`
share `CronCreate`'s gate, so in any session where scheduling succeeded
they are there too.

**Pick the row by its schedule, not by its prompt.** The listing shows
each prompt truncated, and what this section reserves is a `notify.sh`
call written out by absolute path — long enough that the `fire-oneshot`
token sits past the cut, and the full prompt reaches you in no other
form. So read the human-readable schedule and the one-shot/recurring
marker as the key, and treat the surviving prompt prefix as a family
filter only: it answers "is this one of ours", never "which one of
ours".

Two one-shots of this skill are identical for as far as the listing
shows them, so if the schedule does not separate the candidates, **ask
which one** and say why you are asking. That question is not politeness
here — it is the only discriminator left. The rule against questions in
this section is about a user who has walked away, and a user who just
said `"알림 취소"` is at the keyboard by definition.

**`"알림 취소"` turns off everything that is live.** Delete the
scheduled job with `CronDelete`, and if an ARM cycle is also live call
`notify.sh cancel` as well. **Never turn off one of them and report
that it is cancelled.** This state is not a hypothetical the design
tolerates — it is one this section actively creates, because the
event-anchor offer above invites the very user who made a clock request
to open an event cycle. §2.3 owns the same utterance and carries the
same obligation.

**Distinguish from progress markers.** A request keyed to *work
progress* — `"작업이 70% 정도 끝나면"`, `"중간쯤 되면"` — is NOT
clock-keyed and ARMs normally. Judge it by how much of the work is
done, not by how much time has passed: it is the same milestone
judgment a default single ARM already makes.

**Composite expressions** like `"5분마다 체크해서 끝나면 알려줘"` are
already handled in §2.5: the alert itself is single-milestone (`"끝나면
알려줘"`), only the *polling cadence* is clock-keyed. ARM single, let
the polling be the model's own concern.

**Anti-pattern reminder.** Do not substitute a turn-counting or
work-step-counting proxy for a real time interval (see §6.1
Clock-keyed ARM). Genuine time intervals belong to the scheduler.

(§2.7 and §2.8 are deliberately unused. Renumbering would break the
live references to §2.9 in this file, so the gap stands until a
renumber is done on purpose — it is a gap, not a lost section.)

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
5. If no reply comes at all, the degenerate class stays and two things
   follow. The moment your own work produces a first concrete instance
   — a commit, a test run — **re-ARM with that class**, which ends the
   degeneracy without the user having answered. And if the task you
   were given finishes with neither a reply nor a concrete instance,
   close the cycle there — but the end of that turn is itself an
   instance under the CFI-1 floor whenever the turn carried a user-task
   tool call, so **fire-now first, then `cancel`, then say so in your
   reply** (§4.6's ordering rule). §4.6 (a) is satisfied by construction
   in this branch
   — a degenerate cycle can only ever fire on the CFI-1 floor, and
   that floor counts your own turns.
6. A surviving degenerate class is not a dead cycle: it sits at the
   bottom of the §2.2 spectrum, where CFI-1's instance floor supplies
   the boundary the label lacks — the end of a turn carrying at least
   one user-task tool call. That floor is why tier 2 can ARM first and
   ask second without leaving the user with a cycle that never fires.

**This is NOT §6.3 avoidance.** §6.3 forbids silent skip (refusing to
ARM and doing nothing). Tier 2 ARMs that turn — the question only
refines the class label, it does not gate the ARM itself.

**Gate — do not over-ask.** The clarifying question fires only when
BOTH conditions hold: (a) bare-noun utterance AND (b) no concrete
class inferable from context. If the utterance names an event noun
(`"각 커밋마다"`), never ask. If tier 1 best-fit succeeds, never ask.
Asking otherwise is the §6.1 Clarifying-question over-ask anti-pattern.

**Asymmetry with §2.4 armCount tiebreaks.** §2.4 favors best-fit
without asking because either count produces a working cycle. A
bare-noun utterance with no context produces a much weaker cycle — so
the question is justified when the alternative is the degenerate
fallback, and ONLY then.

What makes the exchange cheap is **not** that the user is present. They
may well have walked away the moment they asked; that is the case this
skill is built for. It is cheap because the ARM already happened in
step 1 and the floor in step 5 keeps the cycle firing meanwhile, so an
answer that never comes costs nothing. The question is an upgrade path,
never a precondition — which is also why it is asked once and not
repeated.

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

**FIRE-NOW is the only dispatch surface of an ARM cycle (model-driven).**
`fire-oneshot` also emits a banner but belongs to no cycle — it touches
neither the flag nor the lock, so nothing below applies to it. Single mode
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
   the model's own plan has no step left that would produce an
   instance).
3. Single mode armCount-consume (final fire's `mv -n` removes the
   flag — no separate `cancel` call needed).

The dispatcher cannot distinguish 1 from 2 — both are the same `rm -f`,
and it stores no event class to reason about. So the obligation to fire
for a series-terminating instance BEFORE cancelling is the model's
alone (CFI-4); nothing in the dispatcher will hold that banner for it.

A fourth surface exists but is **not** a CANCEL trigger and does not
appear above: `fire-oneshot` belongs to no cycle, so there is no flag
for it to remove. Deleting a scheduled job (§2.6) likewise does not
touch the flag — and that is precisely why an explicit revocation while
both are live requires two separate actions (§2.3).

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

**Instance floor for generic work-unit classes.** A class at the bottom
of the §2.2 spectrum (`"단계"`, a degenerate `"작업 단위 완료"` label
from the §2.9 cascade) gives the model no boundary to observe, so one
is supplied: **the end of a turn that contained at least one user-task
tool call counts as one instance.** This defines "instance" where the
utterance defines none. It is not a turn-end auto-fire returning by
another name, and it does **not** extend to precise classes — a turn in
which no `commit` occurred owes no `commit` banner, floor or no floor.

**A turn opened by an external scheduler is not an instance.** Such a
turn — one executing a prompt written for a scheduled job rather than
for this cycle's user task — does not count toward a generic work-unit
class. The axis is *who opened the turn*, not which mechanism did it.
Without this exclusion the three parts compose into a cycle that cannot
end: a degenerate class fires on any turn with a tool call, a live
scheduled job keeps opening such turns, and CFI-4 forbids self-cancel
while instances are still arriving.

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

End the cycle yourself via `notify.sh cancel` when the conditions below
hold. Self-cancel applies ONLY to event-scoped repeat — single mode
terminates structurally (armCount consume), and a single ARM never has
a "series" to end.

**Permitting conditions — judge the actor, not the future.** "No
further instances are expected" is a prediction, and the model has no
standing to make it about events it does not produce. Self-cancel is
permitted only when **both** hold:

- **(a) Every instance this cycle fired was the completion of something
  the model itself dispatched.** A `git commit` the model ran, a test
  suite the model invoked, a deploy the model drove.
- **(b) The user's task finishes this turn, and no step remains in the
  model's own plan that would produce another instance.**

**If (a) fails, self-cancel is forbidden.** When the instances come
from the user's own commits, a CI pipeline, or a deploy the model does
not drive, the model cannot see the series at all — it only sees the
part that happened to pass through its context. Leave the cycle to user
CANCEL. This is the whole difference between ending a series you are
writing and guessing at one you are only watching.

Worked cases where both hold: a multi-commit refactor the model is
performing has produced its final commit and the task is wrapping up; a
test loop the model is running has reached green with nothing left to
run; a deploy iteration the model is driving has succeeded for the last
environment.

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

**Issue the two as separate Bash calls — do not chain them with `&&`.**
A chained pair is not a lone invocation, so the hook does not approve it
and the turn stops on a permission dialog — at the exact moment the
cycle was closing, with the final banner still unsent and no one present
to answer. Splitting them across two lines of one Bash call fails the
same way and for the same reason: the matcher is anchored to the whole
command line, and a second line makes it no longer lone. And were a
chained pair to run, the session-id injection path binds its environment
prefix to the first command only, so the chained `cancel` would read a
different flag path than the `fire-now` before it and cancel nothing.
Two calls, in the order above.

**Asymmetry with ARM — and what the error actually costs.** ARM is
forbidden on self-judgment (§6.1) because a false-positive ARM creates
an unrequested obligation, which is expensive and hard to recover from.
Cancel is the safer direction: the model may end a cycle on judgment,
never start one.

That asymmetry does **not** make a wrong self-cancel cheap. It does not
cost "one banner" — it costs **every remaining banner in the series**,
because the cycle is gone rather than delayed. And the user this skill
exists for is the one who walked away, so they do not observe the loss
at all; there is nothing for them to notice and re-ARM in response to.
The only recovery is a line in the model's own response text saying the
cycle was closed and why. That is why the conditions above are written
against what the model is doing rather than against what it predicts.

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

1. Model: `notify.sh arm "테스트 시작할 때랑 끝날 때 알림 줘" "test" single --count=2`.
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

User: `"이 리팩터링 진행하면서 각 커밋마다 알림 줘"` → §2.5 Gate 2a:
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

User: `"lint 끝날 때, 빌드 끝날 때, 배포 완료 시 각각 알림"`.

§2.5 Gate 1: explicit enumeration of 3 named sub-events (`lint 끝날
때`, `빌드 끝날 때`, `배포 완료 시`). Each of the three is a finite
moment that passes once, so Gate 1's exclusion does not fire and the
distributive reading holds: `각각` quantifies over the finite list and
is NOT a repeat trigger. → ARM single `--count=3`. Subsequent flow
follows (s2) with 3 fires instead of 2.

### (s3c) Loose event class — `각 기능 완성마다`

User: `"각 기능 완성마다 알림 줘"`.

§2.5 Gate 2a: `각`/`마다` modifies `기능 완성` → ARM event-scoped
repeat, event class `feature completion`. Per §2.2 spectrum this is a
*named semantic milestone* class — not as crisp as `commit` (no exit
code boundary), but the model judges completion against the work it's
doing.
fire-now timing is the model's call; firing on each feature it
considers complete is correct. Self-cancel when the broader work
scope wraps.

### (s3d) Clock-keyed delegation — `5분마다`

User: `"5분마다 알림 줘"`.

§2.6: clock-keyed cadence. The model does NOT call `notify.sh arm`, and
runs all four steps.

1. **Step 0.** Runs the precondition check. Darwin, `terminal-notifier`
   present → proceed. (Had it failed, the model would schedule nothing
   and say so — never schedule and hope.) Loads the cron schemas with
   `ToolSearch` before it reads the clock.
2. **schedule.** `CronCreate` with `recurring: true` and an interval
   expression, its prompt a single
   `<skill dir absolute path>/scripts/notify.sh fire-oneshot …`
   command line. Keeps the returned job ID.
3. **emit.** Each firing turn runs that one command; `fire-oneshot`
   touches no flag and no lock, so any ARM cycle running alongside is
   unaffected.
4. **disclose.** *"5분 간격 알림을 예약했습니다. 다음 알림은 15:50에
   도착하고 이후 5분 간격으로 울립니다. 예약은 7일 뒤 만료되며 이
   세션이 끝나면 사라집니다. 멈추시려면 말씀해 주세요 — 예약 작업을
   삭제하겠습니다. 처리 중에는 조금 늦을 수 있습니다. 커밋마다 /
   테스트 통과마다로 바꾸시면 이 스킬이 직접 처리합니다."* Then
   proceeds — it does not wait for an answer.

Note what the disclosure does NOT say: that the first alert arrives
immediately (there is no t=0 execution), and any figure for the delay.
Note also what it does say: a concrete wall-clock time for the first
banner, read off the same `date` call the expression came from — never
a restatement of the user's own `"5분마다"`.

Contrast: `"5분마다 체크해서 끝나면 알려줘"` (§2.5 hybrid). The polling
cadence is the model's own concern, but the alert request itself is
`"끝나면 알려줘"` — a single ARM via active-notify, with no delegation
at all.

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
`test pass` — `notify.sh arm "테스트 통과마다" "test loop" repeat`. The
first argument is the reply verbatim; nothing is added to make it read
like a request (§1). The re-ARM is an idempotent overwrite (§3) — no
special mechanism.

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

Each subsection fences a different failure: `arm` calls that must not
happen, plus requests an ARM is the wrong answer to and shape errors in
the ARMs that do happen (§6.1); `fire-now` calls that must not happen,
plus the obligations around the ones that must (§6.2); ambiguity used
as a reason not to act at all (§6.3); and self-cancel judgments that
end a cycle wrongly (§6.4). Not every bullet below forbids a call.
§6.1's second group holds one ARM that must not happen — the
clock-keyed one, which §2.6 answers instead — and three constraints on
ARMs that do; §6.2 holds one forbidden call, two obligations (fire
every observed instance; fire before any other tool call), and one call
it calls harmless; §6.3 mandates ARM; §6.4 governs `cancel`.

### 6.1 ARM — when not to call, and how not to call it

Two kinds sit here and they fail differently. **(A) No request exists**
— ARM would invent an obligation the user never asked for, so the
correct action is to do nothing and say nothing. **(B) A request
exists, but ARM is the wrong response to it** — doing nothing is then
also wrong; something must happen and the user must hear about it. Do
not collapse the two: applying (A)'s silence to a (B) case produces the
silent skip §6.3 forbids.

**(A) No alert request was made — do NOT ARM, and say nothing.**

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

**(B) A request exists — ARM is either the wrong response or the wrong
shape; never end here in silence.**

- **Clock-keyed ARM.** Arming on wall-clock cadence — recurring
  intervals (`"5분마다"`) or one-shot future delays (`"30분 후"`).
  active-notify's lifecycle is event-cued, not clock-cued; route
  clock-keyed requests through §2.6 to the scheduler instead. Do NOT
  substitute a turn-counting or step-counting proxy for a real time
  interval — genuine time intervals belong to the scheduler. Progress
  markers (`"70% 정도"`) are NOT clock-keyed and ARM normally. **This
  bullet forbids the ARM, not the response**: the user asked for
  something, so §2.6 either schedules it or says why it cannot.
- **Count inflation.** Inferring `--count=N>1` from generic
  `"끝나면 알려줘"` (no named sub-events). Default to count=1 unless
  the user explicitly named multiple sub-events.
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

These govern `fire-now`, the ARM cycle's dispatch surface — one call
they forbid, and obligations around calls that must happen. None of
them reach `fire-oneshot`, which belongs to no cycle: it is
state-independent by construction, so "no ARM was ever placed" is its
normal condition
rather than a violation. The §2.6 delegation calls it with no ARM
anywhere in the conversation and that is correct.

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
- **Mid-series self-cancel.** Cancelling while the model's own plan
  still contains a step that would produce an instance — §4.6
  condition (b) unmet. A temporary lull or a work pause is not
  termination.
- **Self-cancel on a series the model does not produce.** §4.6
  condition (a) unmet: the instances come from the user's own commits,
  a CI pipeline, or a deploy the model does not drive. The model sees
  only the fragment that passed through its context and cannot tell an
  ended series from a quiet one. Leave it to user CANCEL.
- **Self-cancel in place of the final fire-now.** Calling `cancel`
  without first firing for the series-terminating instance loses the
  final banner (the post-cancel fire-now is a silent no-op). §4.6's
  ordering rule governs whenever the cycle-terminating event is itself
  an instance of the armed class: fire-now FIRST, cancel SECOND.

Two of these are §4.6's permitting conditions failing — a mid-series
cancel is (b) unmet, and a series the model does not produce is (a)
unmet — so that judgment is made once, there, and not re-derived here.
The other two fail differently: single-mode self-cancel breaches the
scope limit, and cancelling ahead of the final fire-now breaches the
ordering rule. The cost of getting it wrong is stated once as
well, in §4.6.

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
- **The bypass does not inherit the dispatcher's silent-skip default.**
  Everywhere else a precondition failure is invisible to the user: the
  dispatcher exits 0, writes at most an stderr hint, and puts nothing
  in the response stream. The bypass is the inverse — on a precondition
  failure it emits user-visible Korean guidance through the
  combined-Bash stdout. The reason is that this path exists to *be* a
  first run: the user just asked for a test alert and is watching for
  it, so silence here reads as a broken skill rather than a missing
  binary.

The bypass leaves the state flag untouched. Even when no prior ARM is
active, the bypass invocation is safe and does not create one.
