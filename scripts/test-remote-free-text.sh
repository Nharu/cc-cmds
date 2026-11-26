#!/usr/bin/env bash
# Test the remote text reply on the session seam's shell side — the text kind of
# plugins/cc-cmds/hooks/remote-reply/seam.sh (acceptance, the turn-pick,
# turn-record and mark-take subcommands) and the PostToolUse seat
# plugins/cc-cmds/hooks/remote-reply/posttool.sh, with the turn seat
# plugins/cc-cmds/hooks/session-turn-notify.sh making the event a new
# instruction answers.
#
# Each subcommand is driven the way the mode and the harness drive it — JSON on
# stdin, arguments on the command line — and stdout and the files under the
# scratch spool and state roots are read back. Nothing is sent anywhere: the
# mailbox fixtures under tests/fixtures/remote-free-text/ stand in for the relay.
#
# EVERY CASE GETS ITS OWN SCRATCH ROOT (`fresh`): `HOME`, `XDG_STATE_HOME` and
# the spool root (`CC_CMDS_ATTENTION_ROOT`) live under it, and
# `CLAUDE_PLUGIN_ROOT` is this tree's plugin. The fixtures are only read: an
# envelope is copied into the scratch mailbox with its expiry moved after the
# present, because the seam reads the real clock.
#
# WHAT THE MODE DOES IS NOT HERE. The submit text, `asUser`, the remote-input
# line in the form answer and the rule that a person's input after the event
# keeps a new instruction out are asserted by the mode suites
# (remote-reply/index.test.ts, question-form/index.test.ts). This suite asserts
# the bytes the seam records for those submits, and that a handled event takes
# no new instruction.
#
# THE PIPELINE MARKERS ARE UNSET FOR EVERY RUN, so the suite means the same
# inside an unattended stage.
#
# THE POSITIVE CONTROLS COME FIRST. A suite that only measures rejections is
# green against a seam that never writes.

set -uo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
PLUGIN="$repo_root/plugins/cc-cmds"
SEAM="$PLUGIN/hooks/remote-reply/seam.sh"
POSTTOOL="$PLUGIN/hooks/remote-reply/posttool.sh"
TURN_HOOK="$PLUGIN/hooks/session-turn-notify.sh"
HOOKS_JSON="$PLUGIN/hooks/hooks.json"
FX="$repo_root/tests/fixtures/remote-free-text"
FX_OPTION="$repo_root/tests/fixtures/remote-reply"

passed=0
failed=0
ok()   { passed=$((passed + 1)); printf 'PASS: %s\n' "$1"; }
bad()  { failed=$((failed + 1)); printf 'FAIL: %s — %s\n' "$1" "${2:-}" >&2; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got '$2', want '$3'"; fi; }

JQ=$(command -v jq 2>/dev/null || true)
if [ -z "$JQ" ]; then
  echo "SKIP: jq not installed — the seam parses JSON and nothing can be driven without it"
  echo "test-remote-free-text: 0 passed, 0 failed"
  exit 0
fi

for v in $(compgen -v CC_PIPELINE_); do unset "$v"; done

WORK=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/cc-remote-free-text.XXXXXX")" && pwd)
trap 'chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

OUTF="$WORK/seam.out"
ERR="$WORK/seam.err"
LOUD=0

SID1='5f0c2d4e-1111-4a2b-9c3d-000000000001'
SID2='5f0c2d4e-1111-4a2b-9c3d-000000000002'
SAFE1="s-$SID1"
RUN='20261101-a5df83a0'
SENDER='app:dk-7f3a91'
MARK_LINE="[cc-cmds 원격 입력] 발신=$SENDER"

now_ms() { perl -MTime::HiRes=time -e 'printf "%d", time() * 1000'; }

# fresh — a new scratch root for one case; sets s, ROOT, STATE. The sender file
# is the fixture's: the app sender holds option and text, the chat sender option
# only.
fresh() {
  s=$(mktemp -d "$WORK/case.XXXXXX")
  mkdir -p "$s/home/.config/cc-cmds" "$s/state" "$s/root" "$s/tmp"
  ROOT="$s/root"
  STATE="$s/state/cc-cmds"
  printf 'host-a1\n' > "$s/home/.config/cc-cmds/host-id"
  cp "$FX/senders.json" "$s/home/.config/cc-cmds/remote-senders.json"
}

# seam <stdin> <args>... — run seam.sh; sets RC, output in OUTF / ERR.
seam() {
  local input="$1"; shift
  printf '%s' "$input" | env HOME="$s/home" XDG_STATE_HOME="$s/state" \
    CC_CMDS_ATTENTION_ROOT="$ROOT" CLAUDE_PLUGIN_ROOT="$PLUGIN" \
    bash "$SEAM" "$@" > "$OUTF" 2> "$ERR"
  RC=$?
  loud
}

# posttool <stdin> — run posttool.sh the way the harness does.
posttool() {
  printf '%s' "$1" | env HOME="$s/home" XDG_STATE_HOME="$s/state" \
    CC_CMDS_ATTENTION_ROOT="$ROOT" CLAUDE_PLUGIN_ROOT="$PLUGIN" \
    bash "$POSTTOOL" > "$OUTF" 2> "$ERR"
  RC=$?
  loud
}

loud() {
  if [ "$RC" -ne 0 ] || [ -s "$ERR" ]; then
    LOUD=$((LOUD + 1))
    printf 'loud run: rc=%s stderr=%s\n' "$RC" "$(head -c 200 "$ERR")" >&2
  fi
}

# The turn seat runs from a clean environment, like the harness's hook: the
# notifier is a stub that only logs, the host is pinned to Darwin so the banner
# branch is reached, and every pipeline marker is absent.
BIN="$WORK/bin"
mkdir -p "$BIN"
cat > "$BIN/terminal-notifier" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CC_TEST_NOTIFY_LOG"
STUB
chmod +x "$BIN/terminal-notifier"
ln -s "$JQ" "$BIN/jq"

# turn_hook <permission mode> — one marked turn of SID1 in the current case.
turn_hook() {
  jq -cn --arg sid "$SID1" --arg mode "$1" \
    '{hook_event_name: "Stop", session_id: $sid, permission_mode: $mode,
      last_assistant_message: "본문 한 줄.\n**cc-cmds 차례 넘김**: 다음 지시를 기다립니다"}' > "$s/turn.json"
  env -i HOME="$s/home" PATH="$BIN:/usr/bin:/bin" TMPDIR="$s/tmp" \
    CC_CMDS_ATTENTION_ROOT="$ROOT" CLAUDE_PLUGIN_ROOT="$PLUGIN" \
    CC_CMDS_NOTIFY_PATH_DISABLE_PREPEND=1 CC_CMDS_NOTIFY_HOST_OS=Darwin \
    CC_CMDS_AUTOPILOT_NOTIFY=0 CC_CMDS_DASHBOARD=off \
    CC_TEST_NOTIFY_LOG="$s/notifier.log" XDG_STATE_HOME="$s/state" \
    bash "$TURN_HOOK" < "$s/turn.json" > "$OUTF" 2> "$ERR"
  RC=$?
  loud
}

listing() { ( cd "$s" && find . ! -path './tmp*' ! -name 'notifier.log' -print | LC_ALL=C sort ); }
out() { cat "$OUTF"; }

# put_env <envelope file> [<jq filter>] — copy an envelope into its mailbox with
# the expiry moved after now; prints the copy's path.
put_env() {
  local src="$1" filter="${2:-.}" now addr rid dst
  now=$(now_ms)
  addr=$(jq -r 'if .target.surface == "approval" then "r-" + .target.run_id
                else "s-" + (.target.session_id | gsub("[^A-Za-z0-9_.-]"; "_")) end' "$src")
  rid=$(jq -r '.reply_id' "$src")
  mkdir -p "$ROOT/inbox/$addr"
  dst="$ROOT/inbox/$addr/$rid.json"
  jq --argjson now "$now" '.expires_at_ms = ($now + 600000)' "$src" | jq "$filter" > "$dst"
  printf '%s' "$dst"
}

# put_event_fx <event fixture> [<jq filter>] — the event record as the fixture
# has it, under its own id.
put_event_fx() {
  local id
  id=$(jq -r '.id' "$1")
  mkdir -p "$ROOT/events"
  jq "${2:-.}" "$1" > "$ROOT/events/$id.json"
}

# put_event_for <envelope> [<jq filter>] — an answerable event of the envelope's
# surface under the envelope's event id, accepting option and text.
put_event_for() {
  local ev kind
  ev=$(jq -r '.event_id' "$1")
  kind=$(jq -r '.target.surface' "$1")
  mkdir -p "$ROOT/events"
  jq -n --arg id "$ev" --arg kind "$kind" --arg sid "$SID1" \
    '{schema: 1, id: $id, host: "host-a1", created_at_ms: 1000, kind: $kind,
      token: "session-ask", slot: ("cc-cmds-session-" + $sid), title: "t", body: "b",
      actionable: true, accepts: ["option", "text"], origin: {}, reply: null}' \
    | jq "${2:-.}" > "$ROOT/events/$ev.json"
}

# auq_call <envelope file> <session id> — the open call the envelope targets.
auq_call() {
  jq -c --arg sid "$2" '{session_id: $sid, tool_use_id: .target.tool_use_id,
    questions: [ .target.questions[] | {question, header, multiSelect: .multi_select,
                 options: [ .options[] | {label, description: (.label + " 설명")} ]} ]}' "$1"
}

# form_in <envelope file> — the mode's scan input with the envelope's form open.
form_in() {
  jq -c --arg sid "$SID1" '{session_id: $sid, form: (.target | {form_id, session_id, questions})}' "$1"
}

# attempt <envelope copy> — drive the subcommand that applies the envelope's
# surface: commit for a question, form-pick for a form, turn-pick for a turn.
attempt() {
  local env="$1" rid surface
  rid=$(jq -r '.reply_id' "$env")
  surface=$(jq -r '.target.surface' "$env")
  case "$surface" in
    auq) seam "$(auq_call "$env" "$SID1")" commit "$SAFE1" "$rid" ;;
    question-form) seam "$(form_in "$env")" form-pick "$rid" ;;
    turn) seam "{\"session_id\":\"$SID1\"}" turn-pick "$rid" ;;
    *) : > "$OUTF" ;;
  esac
}

index_run() {
  local sid
  mkdir -p "$STATE/session" "$STATE/run/$RUN"
  for sid in "$@"; do
    printf '%s\n' "$RUN" >> "$STATE/session/$sid"
    printf '%s\n' "$sid" >> "$STATE/run/$RUN/session-lineage"
  done
}

applied_of() { printf '%s' "$ROOT/applied/$1.json"; }
handled_count() { if [ -d "$ROOT/handled" ]; then find "$ROOT/handled" -name '*.json' | wc -l | tr -d ' '; else echo 0; fi; }
mark_of() { printf '%s/remote-reply/mark/%s' "$STATE" "$(printf '%s\037%s' "$ROOT" "$1" | shasum -a 256 | cut -d' ' -f1)"; }
post_in() { jq -cn --arg sid "$SID1" --arg tu "$1" \
  '{hook_event_name: "PostToolUse", session_id: $sid, tool_name: "AskUserQuestion", tool_use_id: $tu}'; }

# rejected <name> <before listing> — the last run printed nothing and changed
# no file.
rejected() {
  local after
  after=$(listing)
  if [ -s "$OUTF" ]; then bad "$1" "출력이 있다: $(head -c 120 "$OUTF")"
  elif [ "$after" != "$2" ]; then bad "$1" "파일이 바뀌었다"
  else ok "$1"; fi
}

AUQ1="$FX/envelope-auq-single-text.json"
AUQM="$FX/envelope-auq-multi-text.json"
FFREE="$FX/envelope-form-free-text.json"
FOTHER="$FX/envelope-form-other-text.json"
TURN="$FX/envelope-turn.json"
RID_AUQ1=$(jq -r '.reply_id' "$AUQ1")
RID_AUQM=$(jq -r '.reply_id' "$AUQM")
RID_FFREE=$(jq -r '.reply_id' "$FFREE")
RID_FOTHER=$(jq -r '.reply_id' "$FOTHER")
RID_TURN=$(jq -r '.reply_id' "$TURN")
TU_AUQ1=$(jq -r '.target.tool_use_id' "$AUQ1")
TU_AUQM=$(jq -r '.target.tool_use_id' "$AUQM")
TURN_SCAN="{\"session_id\":\"$SID1\",\"form\":null,\"turn\":true}"

# ---------------------------------------------------------------------------
# 1. Acceptance — the single-select AskUserQuestion answered with text, and the
#    remote-input line it leaves for the PostToolUse seat.
# ---------------------------------------------------------------------------
fresh
env1=$(put_env "$AUQ1")
put_event_fx "$FX/event-auq.json"
call=$(auq_call "$env1" "$SID1")
seam "$call" commit "$SAFE1" "$RID_AUQ1"
check "1 단일 선택 텍스트 답의 답 맵" "$(out | jq -cS .)" '{"어느 브랜치로 진행할까요?":"release-2026-12 브랜치에서 이어 주세요"}'
rec=$(applied_of "$RID_AUQ1")
want_hash=$(printf '%s' "$call" | jq -j --argjson a "$(out)" '.questions[] | .question, "\u001f", $a[.question], "\u001e"' | shasum -a 256 | cut -d' ' -f1)
check "1 적용 기록의 answers_sha256 이 원상의 해시" "$(jq -r '.answers_sha256' "$rec" 2>/dev/null)" "$want_hash"
check "1 기록의 대상 칸·세션·전송·발신" "$(jq -r '[.tool_use_id, .session_id, .transport, .sender] | join(" ")' "$rec" 2>/dev/null)" \
  "$TU_AUQ1 $SID1 app $SENDER"
check "1 처리 표지 하나(reply-applied)" "$(find "$ROOT/handled" -name '*.json' -exec jq -r '.cause' {} + 2>/dev/null)" "reply-applied"
mark=$(mark_of "$TU_AUQ1")
check "1 표지 파일이 발신자 id 를 담음" "$(cat "$mark" 2>/dev/null)" "$SENDER"
case "$mark" in
  "$ROOT"/*) bad "1 표지 파일은 스풀 경로가 아님" "$mark" ;;
  *) ok "1 표지 파일은 스풀 경로가 아님" ;;
esac
posttool "$(post_in "$TU_AUQ1")"
check "1 사후 도구 훅이 표지 줄을 추가 맥락으로 냄" "$(out | jq -c .)" \
  "{\"hookSpecificOutput\":{\"hookEventName\":\"PostToolUse\",\"additionalContext\":\"$MARK_LINE\"}}"
if [ -e "$mark" ]; then bad "1 표지 파일을 낸 뒤 지움" "남아 있다"; else ok "1 표지 파일을 낸 뒤 지움"; fi
posttool "$(post_in "$TU_AUQ1")"
check "1 둘째 사후 도구 훅은 아무것도 내지 않음" "$(out)" ""

# The seat of a spawned agent leaves the mark alone; a mark whose sender is
# outside the sender grammar prints nothing and is removed.
fresh
env1=$(put_env "$AUQ1")
put_event_fx "$FX/event-auq.json"
seam "$(auq_call "$env1" "$SID1")" commit "$SAFE1" "$RID_AUQ1"
mark=$(mark_of "$TU_AUQ1")
posttool "$(post_in "$TU_AUQ1" | jq -c '.agent_id = "agent-1"')"
check "1 띄운 에이전트의 사후 도구 훅은 내지 않음" "$(out)" ""
check "1 띄운 에이전트의 사후 도구 훅은 표지를 남김" "$(cat "$mark" 2>/dev/null)" "$SENDER"
printf 'bad sender!\n' > "$mark"
posttool "$(post_in "$TU_AUQ1")"
check "1 문법 밖 발신자의 표지는 내지 않음" "$(out)" ""
if [ -e "$mark" ]; then bad "1 문법 밖 발신자의 표지도 지움" "남아 있다"; else ok "1 문법 밖 발신자의 표지도 지움"; fi

# ---------------------------------------------------------------------------
# 2. Acceptance — multi-select: the chosen labels in the call's option order,
#    then the text, joined with ", ".
# ---------------------------------------------------------------------------
fresh
envm=$(put_env "$AUQM")
put_event_for "$envm" '.kind = "auq"'
seam "$(auq_call "$envm" "$SID1")" commit "$SAFE1" "$RID_AUQM"
check "2 다중 선택 텍스트 답의 답 맵" "$(out | jq -cS .)" \
  '{"결과를 어디에 남길까요?":"PR 본문","이번 판에 무엇을 함께 돌릴까요?":"린트, 시험, 보안 검사"}'
check "2 다중 선택 텍스트 답도 표지 파일" "$(cat "$(mark_of "$TU_AUQM")" 2>/dev/null)" "$SENDER"

# The option envelope is applied as before and leaves no mark file.
fresh
jq -n '{schema: 1, senders: [{id: "tg:123456789", capabilities: ["option"]}]}' > "$s/home/.config/cc-cmds/remote-senders.json"
envo=$(put_env "$FX_OPTION/envelope-auq-single.json")
put_event_for "$envo" '.kind = "auq" | .accepts = ["option"]'
seam "$(auq_call "$envo" "$SID1")" commit "$SAFE1" "$(jq -r '.reply_id' "$envo")"
check "2 선택지 봉투는 그대로 받아짐" "$(out | jq -cS .)" '{"시험을 지금 돌릴까요?":"예","어느 브랜치로 진행할까요?":"새 브랜치"}'
if [ -d "$STATE/remote-reply/mark" ] && [ -n "$(ls -A "$STATE/remote-reply/mark")" ]; then
  bad "2 선택지 봉투는 표지 파일을 남기지 않음" "있다"
else ok "2 선택지 봉투는 표지 파일을 남기지 않음"; fi

# ---------------------------------------------------------------------------
# 3. Question form — a free-text question and an other-input answer.
# ---------------------------------------------------------------------------
fresh
envf=$(put_env "$FFREE")
put_event_fx "$FX/event-form-text.json"
fin=$(form_in "$envf")
seam "$fin" scan
check "3 scan 이 자유 입력 답의 picks 를 냄" "$(out | jq -c '.form')" \
  "{\"reply_id\":\"$RID_FFREE\",\"picks\":[{\"id\":\"scope\",\"label\":\"일부\"},{\"id\":\"why\",\"text\":\"릴리스 일정이 이번 주라서입니다\"}],\"kind\":\"text\",\"sender\":\"$SENDER\"}"
seam "$fin" form-pick "$RID_FFREE"
check "3 form-pick 이 reply_id 를 냄" "$(out)" "$RID_FFREE"
seam "$(cat "$FX/submit-form-text.txt")" form-record "$SID1" "$RID_FFREE"
check "3 기록이 applied-form-text.json 과 같음(적용 시각 밖)" \
  "$(jq -cS 'del(.applied_at_ms)' "$(applied_of "$RID_FFREE")" 2>/dev/null)" \
  "$(jq -cS 'del(.applied_at_ms)' "$FX/applied-form-text.json")"
check "3 제출 문면의 마지막 줄이 표지 줄" "$(tail -n 1 "$FX/submit-form-text.txt")" "$MARK_LINE"
check "3 처리 표지 하나" "$(handled_count)" "1"

fresh
envf=$(put_env "$FOTHER")
put_event_fx "$FX/event-form-other.json"
seam "$(form_in "$envf")" scan
check "3 scan 이 기타 입력 답의 picks 를 냄" "$(out | jq -c '.form.picks')" '[{"id":"owner","text":"배포 검토자"}]'
seam "$(form_in "$envf")" form-pick "$RID_FOTHER"
check "3 기타 입력 답의 form-pick" "$(out)" "$RID_FOTHER"
seam "$(printf 'bundle\n%s' "$MARK_LINE")" form-record "$SID1" "$RID_FOTHER"
check "3 기타 입력 답의 적용 기록" "$(jq -r '[.tool_use_id, .sender] | join(" ")' "$(applied_of "$RID_FOTHER")" 2>/dev/null)" "f-8e3f5b21 $SENDER"

# ---------------------------------------------------------------------------
# 4. The turn — scan offers the new instruction only when asked; turn-pick,
#    turn-record with the submitted bytes.
# ---------------------------------------------------------------------------
fresh
envt=$(put_env "$TURN")
put_event_fx "$FX/event-turn.json"
seam "{\"session_id\":\"$SID1\",\"form\":null}" scan
check "4 turn 을 묻지 않은 scan 은 후보 없음" "$(out | jq -c '.turn')" "null"
seam "$TURN_SCAN" scan
check "4 scan 이 새 지시 후보를 냄" "$(out | jq -c '.turn | {reply_id, text, sender, created_at_ms}')" \
  "$(jq -cn --arg rid "$RID_TURN" --arg s "$SENDER" '{reply_id: $rid, text: "시험을 다시 돌리고\n실패한 절만 고쳐 주세요.", sender: $s, created_at_ms: 1793599995000}')"
check "4 scan 은 아무것도 쓰지 않음" "$(ls "$ROOT/inbox/$SAFE1" | wc -l | tr -d ' ')" "1"
seam "{\"session_id\":\"$SID1\"}" turn-pick "$RID_TURN"
check "4 turn-pick 이 reply_id 를 냄" "$(out)" "$RID_TURN"
check "4 수령 표지가 이 세션 것" "$(jq -r '.session_id' "$ROOT/inbox/$SAFE1/$RID_TURN.picked" 2>/dev/null)" "$SID1"
before=$(listing)
seam "$(printf '%s\n\n%s' "$MARK_LINE" "다른 문면")" turn-record "$SID1" "$RID_TURN"
rejected "4 제출 문면이 봉투와 다르면 기록하지 않음" "$before"
seam "$(cat "$FX/submit-turn.txt")" turn-record "$SID1" "$RID_TURN"
check "4 turn-record 가 reply_id 를 냄" "$(out)" "$RID_TURN"
check "4 기록이 applied-turn.json 과 같음(적용 시각 밖)" \
  "$(jq -cS 'del(.applied_at_ms)' "$(applied_of "$RID_TURN")" 2>/dev/null)" \
  "$(jq -cS 'del(.applied_at_ms)' "$FX/applied-turn.json")"
check "4 answers_sha256 이 제출 문면의 바이트" "$(jq -r '.answers_sha256' "$(applied_of "$RID_TURN")" 2>/dev/null)" \
  "$(shasum -a 256 < "$FX/submit-turn.txt" | cut -d' ' -f1)"
check "4 제출 문면의 첫 줄이 표지 줄" "$(head -n 1 "$FX/submit-turn.txt")" "$MARK_LINE"
check "4 처리 표지 — 원인·사건 slot" "$(find "$ROOT/handled" -name '*.json' -exec jq -r '"\(.cause) \(.slot)"' {} + 2>/dev/null)" \
  "reply-applied cc-cmds-session-$SID1"
before=$(listing)
seam "$(cat "$FX/submit-turn.txt")" turn-record "$SID1" "$RID_TURN"
rejected "4 둘째 turn-record 는 쓰지 않음" "$before"
seam "$TURN_SCAN" scan
check "4 적용 뒤 scan 은 후보 없음" "$(out | jq -c '.turn')" "null"

# turn-unpick takes the session's own marker back.
fresh
envt=$(put_env "$TURN")
put_event_fx "$FX/event-turn.json"
seam "{\"session_id\":\"$SID1\"}" turn-pick "$RID_TURN"
seam "{\"session_id\":\"$SID2\"}" turn-unpick "$RID_TURN"
check "4 다른 세션의 turn-unpick 은 표지를 지우지 않음" "$(jq -r '.session_id' "$ROOT/inbox/$SAFE1/$RID_TURN.picked" 2>/dev/null)" "$SID1"
seam "{\"session_id\":\"$SID1\"}" turn-unpick "$RID_TURN"
if [ -e "$ROOT/inbox/$SAFE1/$RID_TURN.picked" ]; then bad "4 turn-unpick 뒤 수령 표지가 없음" "남아 있다"; else ok "4 turn-unpick 뒤 수령 표지가 없음"; fi

# ---------------------------------------------------------------------------
# 5. A sender registered for option only takes no text envelope.
# ---------------------------------------------------------------------------
for f in "$AUQ1" "$FFREE" "$TURN"; do
  fresh
  e=$(put_env "$f" '.provenance.sender = "tg:123456789" | .provenance.transport = "telegram"')
  put_event_for "$e"
  before=$(listing)
  attempt "$e"
  rejected "5 선택지만 가진 발신자의 텍스트 봉투($(jq -r '.target.surface' "$e"))" "$before"
done
fresh
jq -n '{schema: 1, senders: [{id: "app:dk-7f3a91", capabilities: ["option"]}]}' > "$s/home/.config/cc-cmds/remote-senders.json"
e=$(put_env "$TURN")
put_event_fx "$FX/event-turn.json"
before=$(listing)
attempt "$e"
rejected "5 같은 발신자라도 text 능력이 없으면 받지 않음" "$before"

# ---------------------------------------------------------------------------
# 6. Events that take no text: an approval, a router seat's turn, a turn
#    without the attachment.
# ---------------------------------------------------------------------------
fresh
e=$(put_env "$TURN" '.event_id = "host-a1.1793599996000.f6f6f6f6"')
put_event_fx "$FX/event-approval.json"
before=$(listing)
attempt "$e"
rejected "6 승인 사건에 온 텍스트 봉투" "$before"

fresh
index_run "$SID2"
e=$(put_env "$FX_OPTION/envelope-approval.json" '.kind = "text"')
put_event_for "$e" '.kind = "approval" | .accepts = ["option", "text"] | .slot = "cc-cmds-autopilot-x"'
before=$(listing)
seam "{\"session_id\":\"$SID2\",\"form\":null,\"turn\":true}" scan
check "6 승인 대상 텍스트 봉투는 깨우기 후보가 아님" "$(out | jq -c '.wake')" "[]"
if [ "$(listing)" = "$before" ]; then ok "6 승인 대상 텍스트 봉투에는 수령 표지가 없음"; else bad "6 승인 대상 텍스트 봉투에는 수령 표지가 없음" "파일이 바뀌었다"; fi

fresh
e=$(put_env "$TURN")
put_event_fx "$FX/event-turn-router.json"
before=$(listing)
attempt "$e"
rejected "6 첨부 없는 차례 넘김(accepts 비어 있음)" "$before"
seam "$TURN_SCAN" scan
check "6 첨부 없는 차례 넘김에는 scan 후보 없음" "$(out | jq -c '.turn')" "null"

fresh
e=$(put_env "$TURN")
put_event_fx "$FX/event-turn.json"
index_run "$SID1"
before=$(listing)
attempt "$e"
rejected "6 정방향 색인에 런이 있는 라우터 좌석" "$before"
seam "$TURN_SCAN" scan
check "6 라우터 좌석에는 scan 후보 없음" "$(out | jq -c '.turn')" "null"

# ---------------------------------------------------------------------------
# 7. The permission mode changes neither the event nor the acceptance, and no
#    file of the apply path names a permission mode.
# ---------------------------------------------------------------------------
# Both modes run under the same HOME, so the origin's configuration directory is
# the same; only the spool and state roots are made anew.
declare -a perm_event perm_scan perm_pick
fresh
for mode in default bypassPermissions; do
  rm -rf "$s/root" "$s/state"
  mkdir -p "$s/root" "$s/state"
  turn_hook "$mode"
  evf=$(find "$ROOT/events" -name '*.json' 2>/dev/null | head -n 1)
  if [ -z "$evf" ]; then
    perm_event+=("사건 없음"); perm_scan+=(""); perm_pick+=("")
    continue
  fi
  perm_event+=("$(jq -cS 'del(.id, .created_at_ms)' "$evf")")
  e=$(put_env "$TURN" ".event_id = \"$(jq -r '.id' "$evf")\"")
  seam "$TURN_SCAN" scan
  perm_scan+=("$(out | jq -c '.turn | if . == null then null else del(.created_at_ms) end')")
  seam "{\"session_id\":\"$SID1\"}" turn-pick "$RID_TURN"
  perm_pick+=("$(out)")
done
check "7 기본 모드의 차례 넘김 사건이 새 지시를 받음" "$(printf '%s' "${perm_event[0]}" | jq -cS '{actionable, accepts, reply}' 2>/dev/null)" \
  "{\"accepts\":[\"text\"],\"actionable\":true,\"reply\":{\"session_id\":\"$SID1\",\"surface\":\"turn\"}}"
check "7 권한 모드와 무관하게 사건 레코드가 같음(시각·id 밖)" "${perm_event[1]}" "${perm_event[0]}"
check "7 기본 모드에서 scan 이 후보를 냄" "$(printf '%s' "${perm_scan[0]}" | jq -r '.reply_id' 2>/dev/null)" "$RID_TURN"
check "7 권한 모드와 무관하게 scan 결과가 같음" "${perm_scan[1]}" "${perm_scan[0]}"
check "7 권한 모드와 무관하게 turn-pick 결과가 같음" "${perm_pick[1]}" "${perm_pick[0]}"
check "7 기본 모드의 turn-pick 이 받음" "${perm_pick[0]}" "$RID_TURN"
check "7 적용 경로 파일에 권한 모드 이름이 없음" \
  "$(cat "$SEAM" "$POSTTOOL" "$PLUGIN/hooks/remote-reply/pretool.sh" "$PLUGIN/hooks/remote-reply/index.tsx" \
        "$PLUGIN/hooks/question-form/index.tsx" "$TURN_HOOK" \
      | grep -cE 'bypassPermissions|acceptEdits|dontAsk|permission_mode|permissionMode')" "0"

# ---------------------------------------------------------------------------
# 8. A handled event takes no new instruction: the person came back.
# ---------------------------------------------------------------------------
fresh
e=$(put_env "$TURN")
put_event_fx "$FX/event-turn.json"
mkdir -p "$ROOT/handled"
jq -n --arg s "cc-cmds-session-$SID1" --argjson at "$(now_ms)" \
  '{schema: 1, id: "h", host: "host-a1", at_ms: $at, slot: $s, prefix: false, cause: "return"}' > "$ROOT/handled/ret.json"
before=$(listing)
attempt "$e"
rejected "8 처리 표지가 있는 사건에는 새 지시를 받지 않음" "$before"
seam "$TURN_SCAN" scan
check "8 처리된 사건에는 scan 후보 없음" "$(out | jq -c '.turn')" "null"

fresh
e=$(put_env "$TURN")
put_event_fx "$FX/event-turn.json"
mkdir -p "$ROOT/handled"
jq -n --arg s "cc-cmds-session-" --argjson at "$(now_ms)" \
  '{schema: 1, id: "h", host: "host-a1", at_ms: $at, slot: $s, prefix: true, cause: "return"}' > "$ROOT/handled/ret.json"
before=$(listing)
attempt "$e"
rejected "8 세션 접두 처리 표지도 새 지시를 막음" "$before"

# ---------------------------------------------------------------------------
# 9. Length and control-character rules, and the fixed rejection fixtures.
# ---------------------------------------------------------------------------
# positive <name> <envelope> [<filter>] / negative <name> <envelope> <filter> —
# one envelope through its surface's subcommand.
positive() {
  fresh
  local e
  e=$(put_env "$2" "${3:-.}")
  put_event_for "$e"
  attempt "$e"
  if [ -s "$OUTF" ]; then ok "$1"; else bad "$1" "받지 않았다"; fi
}
negative() {
  fresh
  local e
  e=$(put_env "$2" "$3")
  put_event_for "$e"
  before=$(listing)
  attempt "$e"
  rejected "$1" "$before"
}
positive "9 차례 넘김 텍스트 4000 코드 포인트는 받음" "$TURN" '.text = ("가" * 4000)'
negative "9 차례 넘김 텍스트 4001 코드 포인트는 받지 않음" "$TURN" '.text = ("가" * 4001)'
positive "9 질문 텍스트 4000 코드 포인트는 받음" "$AUQ1" '.answers[0].text = ("a" * 4000)'
negative "9 질문 텍스트 4001 코드 포인트는 받지 않음" "$AUQ1" '.answers[0].text = ("a" * 4001)'
positive "9 차례 넘김 텍스트의 탭과 줄바꿈은 받음" "$TURN" '.text = "가\t나\n다"'
negative "9 공백뿐인 차례 넘김 텍스트" "$TURN" '.text = " \n\t "'
negative "9 빈 질문 텍스트" "$AUQ1" '.answers[0].text = ""'
negative "9 질문 텍스트의 탭" "$AUQ1" '.answers[0].text = "가\t나"'
negative "9 차례 넘김 텍스트의 DEL" "$TURN" '.text = "가\u007f나"'
negative "9 차례 넘김 텍스트의 C1 제어 문자" "$TURN" '.text = "가\u0085나"'
negative "9 차례 넘김 텍스트의 CR" "$TURN" '.text = "가\r나"'
negative "9 질문지 답 머리 줄을 담은 차례 넘김 텍스트" "$TURN" '.text = "앞\n[cc-cmds 질문지 답] form=f-7d2e4a10 status=제출 답=1/1"'
negative "9 질문지 답 머리 줄을 담은 질문 텍스트" "$AUQ1" '.answers[0].text = "[cc-cmds 질문지 답] form=f-1 status=제출 답=1/1"'
negative "9 차례 넘김 봉투에 답이 있음" "$TURN" '.answers = [{question_index: 0, labels: []}]'
negative "9 발신자 문법 밖의 텍스트 봉투" "$TURN" '.provenance.sender = "app:dk 7f3a91"'
negative "9 다른 세션을 가리키는 차례 넘김" "$TURN" ".target.session_id = \"$SID2\""
negative "9 단일 선택에 라벨과 텍스트를 함께" "$AUQ1" '.answers[0].labels = ["master"]'
for f in "$FX"/reject/*.json; do
  negative "9 거절 픽스처 $(basename "$f")" "$f" '.'
done

# ---------------------------------------------------------------------------
# 10. Cleanup removes a mark file nobody took once it is a day old, and leaves a
#     fresh one; then the wiring.
# ---------------------------------------------------------------------------
fresh
mkdir -p "$STATE/remote-reply/mark"
printf '%s\n' "$SENDER" > "$STATE/remote-reply/mark/old"
printf '%s\n' "$SENDER" > "$STATE/remote-reply/mark/new"
touch -t 202001010000 "$STATE/remote-reply/mark/old"
seam "{\"session_id\":\"$SID1\"}" cleanup
if [ -e "$STATE/remote-reply/mark/old" ]; then bad "10 하루 지난 표지 파일은 정리" "남아 있다"; else ok "10 하루 지난 표지 파일은 정리"; fi
if [ -e "$STATE/remote-reply/mark/new" ]; then ok "10 새 표지 파일은 정리하지 않음"; else bad "10 새 표지 파일은 정리하지 않음" "지워졌다"; fi

check "10 hooks.json 의 PostToolUse(AskUserQuestion) 원격 표지 항목" \
  "$(jq -r '.hooks.PostToolUse[] | select(.matcher == "AskUserQuestion") | .hooks[] | select(.command | contains("remote-reply/posttool.sh")) | "\(.command)|\(.timeout)"' "$HOOKS_JSON")" \
  'bash "${CLAUDE_PLUGIN_ROOT}/hooks/remote-reply/posttool.sh"|5'
if [ -x "$POSTTOOL" ]; then ok "10 posttool.sh 가 실행 가능"; else bad "10 posttool.sh 가 실행 가능" "실행 권한 없음"; fi
check "10 posttool.sh 에 시험 자리 이름 없음" "$(grep -c 'CC_CMDS_ATTENTION_ROOT' "$POSTTOOL")" "0"

check "11 모든 실행이 rc 0 이고 stderr 가 비어 있음" "$LOUD" "0"

echo "test-remote-free-text: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
