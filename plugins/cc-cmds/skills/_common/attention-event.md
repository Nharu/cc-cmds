# Attention events — the record every remote-notification stage reads

Every banner a seat raises can leave one **event** record in a machine-wide
spool, and every banner slot a seat clears can leave one **handled** marker.
The relay, the session seam and the phone app all read these two records, so
their shape is fixed once, here, at schema version 1.

This file is the one source of the token and kind table, the kind list and the
cause list. `scripts/lint-attention-schema.sh` reads those three tables from
this file and compares them with its own, and `scripts/test-attention.sh`
drives the library row by row from the token table. The tables keep a fixed
shape for that reason: one row per entry, the first column a backticked value.

The writer library is `plugins/cc-cmds/orchestrator/attention.sh`.

## Spool

The spool root is fixed under the account's home directory:

```
$HOME/.local/state/cc-cmds/attention/
```

It depends on neither the Claude configuration directory nor any XDG value, so
a lane session and a borrowed session write to the same spool.

| Path under the root | The one writer |
| --- | --- |
| `events/<id>.json` | the producer (the attention tap); created once, never changed afterwards |
| `handled/<id>.json` | the handled tap |
| `inbox/<addr>/<reply_id>.json` | the relay; `<addr>` is `s-<safe_sid>` or `r-<run_id>` |
| `inbox/<addr>/<reply_id>.picked` | the session seam (the pick-up marker) |
| `applied/<tool_use_id>.json` | the session seam |
| `status/<safe_sid>.json` | the session snapshot seat |
| `relay/` | the relay only (its state, lifetime ledger and manual presence) |

**One writer per path.** Nothing else creates, edits or removes a file in a
path another writer owns.

**Modes.** Directories are `0700` and files `0600`. Nobody creates the root:
it is created by installing the feature, and **when the root is not a
directory, no writer writes anything**. Each writer creates the subdirectory it
writes into on its first write — with `umask 077`, and `mkdir -m 700` only when
the subdirectory is missing; a `mkdir` that fails because another writer just
created it is not a failure. The taps create `events/` and `handled/`; the
relay, the seam and the snapshot seat create their own subdirectories the same
way.

**Creating a file.** A writer writes the JSON to the dot file
`.<id>.<pid>.tmp` in the same directory, moves it to `<id>.json` with `mv -n`,
and removes the temporary file on every path. The exit status of `mv -n` is
not read. A second creation of the same id leaves the first file unchanged.

**Test seat.** When `CC_CMDS_ATTENTION_ROOT` is non-empty, its value is the
spool root. Only the test suites set it; it is not a user setting and no setup
guide mentions it. Only the tap library reads it, and the banner function
files never contain it.

## Ids

```
<id> := <host_id> "." <epoch_ms> "." <8 hex>              ordinary record
      | <host_id> ".appr." <run_id> "." <approval_id>     approval event (deterministic)
```

- `<epoch_ms>` is the creation time in epoch milliseconds and `<8 hex>` eight
  random lowercase hex digits.
- `<run_id>` matches `[A-Za-z0-9-]{1,64}`.
- `<approval_id>` matches `[A-Za-z0-9_-]{1,55}-[0-9a-f]{8}`: a name, a hyphen
  and eight lowercase hex digits. The gate's judgment (`J-`), act (`A-`) and
  boundary (`<boundary name>-`) approval ids all have this shape.
- Handled markers always use the ordinary form, newly made for each marker.

## Host id

The host id is the first line of `$HOME/.config/cc-cmds/host-id` when that line
matches `[a-z0-9-]{1,32}`. A line that ends without a newline is still the
first line; a trailing carriage return is outside the alphabet. When the file
is missing, empty, unreadable or its first line does not match, the host id is
`local` — a bad file never drops a record. Every event, handled marker and
envelope carries the host id; the first version routes nothing by it.

## Event record

```
event = { schema: 1, id, host, created_at_ms,
  kind, token, slot,
  title, body,
  actionable, accepts,
  origin: { session_id, run_id, config_dir, cwd, repo, tmux_pane },
  reply }
```

| Key | Type | Value |
| --- | --- | --- |
| `schema` | number | `1` |
| `id` | string | the event id; starts with `host` |
| `host` | string | the host id |
| `created_at_ms` | number | positive integer, epoch milliseconds |
| `kind` | string | one of the kinds below |
| `token` | string | the banner token the seat called with |
| `slot` | string | non-empty; byte-equal to the local banner group (see Slots) |
| `title` | string | the banner title |
| `body` | string | the whole, untruncated text |
| `actionable` | boolean | whether the event can be answered remotely |
| `accepts` | array | `["option"]` when `actionable` is true, `[]` otherwise |
| `origin` | object | the six keys below |
| `reply` | object or null | the reply target, or null |

The record has exactly these thirteen keys.

| `origin` key | Type | Value |
| --- | --- | --- |
| `session_id` | string or null | the reply target's `session_id` when it has one, else `CC_NOTIFY_SESSION_ID` |
| `run_id` | string or null | the reply target's `run_id` when it has one, else `RUN_ID` |
| `config_dir` | string | `${CLAUDE_CONFIG_DIR:-$HOME/.claude}` at the time of writing |
| `cwd` | string or null | `PWD` |
| `repo` | string or null | `<owner>/<name>` from `CC_NOTIFY_REPO`, or null |
| `tmux_pane` | string or null | `TMUX_PANE` |

An empty value is written as null. `origin.repo` is set only when
`CC_NOTIFY_REPO` is, as a whole, an owner matching
`[A-Za-z0-9][A-Za-z0-9-]{0,38}`, one slash, and a name matching
`[A-Za-z0-9_.-]{1,100}` that is neither `.` nor `..`; any other value —
an absolute path, `../..`, `./x`, an empty value — writes null. The tap never
runs a repository tool to find the value: the caller passes it. No seat sets
`CC_NOTIFY_REPO` yet, so readers treat a null `repo` as the ordinary case.
`origin.config_dir` is recorded as written; the relay resolves it to a lane or
account name read-only and shows the directory name when it cannot.

## Kinds

| Kind | Reply surface | Meaning |
| --- | --- | --- |
| `auq` | `auq` | a session asks a question |
| `question-form` | `question-form` | a session shows a question form |
| `turn` | 없음 | a session's turn ended |
| `approval` | `approval` | an autopilot approval waits |
| `run-end` | 없음 | a run ended |
| `run-stop` | 없음 | a run stopped (rekick-off or resume notice) |
| `run-blocked` | 없음 | a run waits for a person's hand |
| `active-notify` | 없음 | an active-notify completion |
| `permission` | `permission` | a tool permission check |

## Tokens and kinds

The kind comes from one call: its token and the attachment's `kind`. One row
per `(token, kind)` pair; a token that raises no event has one row reading
`없음`, and a token not in this table raises no event either.

| Token | Kind |
| --- | --- |
| `session-ask` | `auq` |
| `session-ask` | `question-form` |
| `session-turn` | `turn` |
| `answer` | `approval` |
| `ended` | `run-end` |
| `rekick` | `run-stop` |
| `resume` | `run-stop` |
| `hands` | `run-blocked` |
| `active-notify` | `active-notify` |
| `permission` | `permission` |
| `answer-run` | 없음 |
| `overflow` | 없음 |
| `focus-guide` | 없음 |

- `session-ask` raises `question-form` only when the attachment's `kind` is
  `question-form`, and `auq` otherwise.
- With an attachment, its `kind` must be a kind its token can raise. An
  attachment that does not parse as a JSON object, or whose `kind` the token
  cannot raise, writes no event — and the attachment file is still removed.
- `answer-run` (the run-level approval summary, which carries no approval id)
  and `focus-guide` (the click guide) never raise an event. `overflow` only
  exists after the stack demotion, below the tap site, so the tap sees the
  original token.

## Reply targets

The reply target is the one source of what an answer acts on; an envelope
copies it verbatim and never builds a new one.

```
{surface: "auq", session_id, tool_use_id,
 questions: [{question, header, multi_select, options: [{label}]}]}
{surface: "question-form", session_id, form_id,
 questions: [{id, question, options: [{label}]}]}
{surface: "approval", run_id, approval_id, question, options}
{surface: "permission", session_id, tool_name, input_summary}
```

| Surface | Required fields |
| --- | --- |
| `auq` | `session_id`, `tool_use_id` (non-empty strings); `questions` an array whose every entry has `question` and `header` strings, a boolean `multi_select`, and `options` an array of `{label}` |
| `question-form` | `session_id`, `form_id` (non-empty strings); `questions` an array whose every entry has a non-empty string `id`, a `question` string and `options` an array of `{label}` |
| `approval` | `run_id`, `approval_id`, `question` (strings); `options` an array of strings — the gate's own labels, `["승인","거부","무효"]` for a judgment approval and `[]` for an act or boundary approval |
| `permission` | `session_id`, `tool_name` (non-empty strings), `input_summary` (string) |

The library keeps the attachment's `reply` as is when its `surface` is the
event's kind and it has the required fields of that surface, and writes null
otherwise. Kinds without a reply surface (`turn`, `run-end`, `run-stop`,
`run-blocked`, `active-notify`) always carry `reply: null`.

## Slots

- The slot is the group the banner function computes from the token and item
  key **the caller asked for**, which is the group the banner clear function
  computes for the same banner. When the stack demotion moves an `answer` or
  `hands` banner to the waiting group, the event keeps the group from before
  the demotion.
- The item key of an `answer` or `hands` call with an empty key is the token
  name. The clear function substitutes it before computing the group, but the
  banner function only does so inside its demotion branch, below the tap site,
  so whoever calls the tap substitutes it before computing the slot.
- The slot of an `active-notify` event is the local group active-notify gives
  that banner.
- The slot of a `permission` event is `cc-cmds-permission-<session_id>`, with
  the session id as is (not `safe_sid`), as the session banner groups use it.
  There is no local banner; the slot is the name a handled marker matches.
- Session tokens use one slot per session whatever the item key, so one marker
  on that slot closes every open event of the session.

## Answerable events

`actionable` is true only when the producer passes `actionable: true` in the
attachment **and** the event's own shape allows an answer. The library
enforces the second half, so a producer's `true` on an unanswerable event is
written as false.

**What the library enforces:**

| Kind | `actionable` may be true when |
| --- | --- |
| `auq` | the reply surface is `auq`, it has at least one question, and every question has at least one option |
| `question-form` | the reply surface is `question-form` and every question has an `id` and at least one option |
| `approval` | the reply surface is `approval` and `options` is not empty |
| `permission` | never — the first version has no envelope for a permission decision |
| any other kind | never; `reply` is null |

`accepts` follows `actionable` alone: `["option"]` when true, `[]` when false.

**What the producer owes:** a question-form producer passes `actionable: true`
only when every question is single-select and none is shown conditionally. A
form with a multi-select, text or conditional question is passed as false, and
its reply target stays for display: the reply target has no field for the
question type or a display condition, so an option-label envelope can answer
only a form made of single-select questions.

## Approval events

- An approval event is written **only from a canonical attachment**: one that
  carries a non-empty string `body`, the gate's canonical approval question
  (the whole `승인 <id> — <question>` prompt). An `approval` reply target may
  ride in the same attachment, and then its `question` must be byte-equal to
  `body`; an attachment where it is not is not canonical.
- A call with no attachment, or with an attachment that has no string `body`
  (one carrying only a reply target included), writes no event. So the body of
  an approval event is always the canonical question, never the fourth
  argument — a watcher's banner text that carries only the approval id never
  becomes an event body.
- The id comes from the reply target's `run_id` and `approval_id` when there is
  one. From a body-only attachment, `run_id` is the shell's `RUN_ID` and
  `approval_id` is the slot with its `cc-cmds-autopilot-<run_id>-` prefix
  removed.
- Both must match their formats (see Ids), and the slot must be byte-equal to
  `cc-cmds-autopilot-<run_id>-<approval_id>`; otherwise no event is written.
  An `answer` call with an empty item key (whose approval id would be
  `answer`) therefore writes no event.
- The gate's site and the watcher's site reach the same approval with the same
  slot and the same id, so they create one event; the second creation does
  nothing.

## Handled markers

```
handled/<id>.json = { schema: 1, id, host, at_ms, slot, prefix, cause }
```

| Key | Type | Value |
| --- | --- | --- |
| `schema` | number | `1` |
| `id` | string | an ordinary id, starting with `host` |
| `host` | string | the host id |
| `at_ms` | number | positive integer, epoch milliseconds |
| `slot` | string | non-empty |
| `prefix` | boolean | true for a prefix marker; then `slot` ends with `@` |
| `cause` | string | one of the causes below |

The marker has exactly these seven keys. The caller of the handled tap chooses
the cause, because only the call site knows it; the library has no default and
writes nothing for a cause outside the list.

## Handled causes

| Cause | Meaning |
| --- | --- |
| `clear` | the local banner slot was cleared |
| `return` | the person returned to the session |
| `approval-closed` | the approval was closed |
| `dismiss` | the banner was dismissed |
| `reply-applied` | the seam applied a remote answer |
| `permission-settled` | the permission check was settled |

## Prefix markers

A prefix marker closes every open event whose slot starts with its slot. It is
written only when the slot ends with the separator `@`: `@` is outside the
`safe_sid` alphabet `[A-Za-z0-9_.-]`, so it cannot match the start of another
session's id, while `-` can occur in a session id and cannot be the separator.
Active-notify closes a session with a pair of markers: the exact marker
`cc-cmds-active-notify-<safe_sid>` and the prefix marker
`cc-cmds-active-notify-<safe_sid>@`.

## Reader rules

- An event is **handled** when a marker exists whose slot equals the event's
  slot (or, for a prefix marker, is a prefix of it) and whose `at_ms` is later
  than the event's `created_at_ms`. A marker with the same time does not
  handle the event. There is no second way for an event to become handled.
- Several markers may exist for one slot. The cause of a handled event is the
  cause of the earliest marker later than the event.
- Ignore every name that starts with a dot or does not end with `.json`: such
  files are temporary files, possibly left by a writer that was killed.
- A record with a `schema` the reader does not know is not read, and an
  `accepts` value the reader does not know is not accepted.
- Handled follows the local clear sites, so it inherits what they miss: a
  question closed with Esc on the Mac, or a return that only ran a local slash
  command, raises no hook event, and that remote message stays open until the
  next return or expiry.

## safe_sid

`<safe_sid>` is the session id with every character outside `[A-Za-z0-9_.-]`
replaced by `_`, byte-equal to active-notify's `an_safe_sid`:
`${sid//[^A-Za-z0-9_.-]/_}`. An empty session id makes no path component.

## Funnel attachment

A seat hands the whole text and the reply target to the tap without changing
the local banner's arguments, through an attachment file:

```
{kind, actionable, reply, body?}
```

- The file is a `0600` regular file the seat makes outside every repository
  with `mktemp "${TMPDIR:-/tmp}/cc-attention-detail.XXXXXX"`. The name prefix
  `cc-attention-detail.` is a condition the remover checks, so a stale value
  pointing at a user's file never removes that file.
- **Through the banner function.** The seat puts the file's path in the shell
  value `CC_NOTIFY_ATTENTION_DETAIL`, as an assignment in front of that one
  call only — `CC_NOTIFY_ATTENTION_DETAIL="$f" cc_notify_fire answer "$q" "$id"`
  — and never exports it, so the value is visible for that call alone. The
  banner function takes it into a local variable on entry and passes it as the
  tap's fifth argument at the tap site. The three paths that return before the
  tap site (the token check, the scope switch, the host check) remove the file
  themselves, and only when it is a regular file owned by the current user and
  not a symbolic link — so an attachment that enters the banner function is
  read or removed once on every path. The seat makes the attachment right
  before calling the banner function, after every guard of its own, because
  nobody removes it on a path that returns before the banner function.
- **Outside the funnel** (active-notify, the permission check), the seat calls
  the tap directly with the attachment as the fifth argument and does not use
  the shell value.
- The tap library never reads that shell value; its only attachment input is
  the fifth argument.
- `body`, when it is a non-empty string, is the event's body; otherwise the
  fourth argument is. Either way the local banner's title, group, body, sound
  and click value are byte-equal with and without an attachment.

## The two functions

```
cc_attention_emit <token> <slot> <title> <body> [<detail-json-file>]
cc_attention_handled <slot> <cause> [prefix]
```

- `notify-run.sh` and active-notify's `notify.sh` source the library; bash 3.2.
- Both always return 0, write not one byte to stdout or stderr, and do not
  wait on the relay. They do not change the caller's exit status, output,
  shell options, traps, umask, working directory or variables, also in a shell
  under `set -euo pipefail`.
- Each call creates at most one file.
- The attachment (fifth argument of `cc_attention_emit`) is read and removed
  before anything else — before the root check — when it is a regular file
  owned by the current user, not a symbolic link, whose name starts with
  `cc-attention-detail.`. An empty fifth argument means no attachment. A
  non-empty argument that fails the check is neither read nor removed, and the
  call writes nothing.
- The library uses `/usr/bin/perl -MTime::HiRes=time` for the time, `od` on
  `/dev/urandom` for the random hex and `jq` for JSON; when one is missing or
  fails, nothing is written. `jq` is the one found on `PATH` and the library
  does not change `PATH`, so **the call site guarantees a `PATH` on which `jq`
  is visible**.
- The library runs no repository tool, does not re-judge the seat, does not
  read the seat state or presence, and has no switch that turns only the
  remote copy off. An event is written only where a seat has already decided
  to raise the banner; a permission event only where the new seat applied the
  same seat rule itself.
- `cc_attention_handled` writes nothing for an empty slot, a cause outside the
  list, a third argument other than empty or `prefix`, or a prefix marker whose
  slot does not end with `@`.
