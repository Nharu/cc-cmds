#!/usr/bin/env bash
# Test the session seam's shell side — plugins/cc-cmds/hooks/remote-reply/seam.sh
# and the PreToolUse seat plugins/cc-cmds/hooks/remote-reply/pretool.sh.
#
# Each subcommand is driven the way the mode and the harness drive it — JSON on
# stdin, arguments on the command line — and stdout and the files under the
# scratch spool and state roots are read back.
#
# EVERY CASE GETS ITS OWN SCRATCH ROOT (`fresh`): `HOME`, `XDG_STATE_HOME` and
# the spool root (`CC_CMDS_ATTENTION_ROOT`) live under it, and
# `CLAUDE_PLUGIN_ROOT` is this tree's plugin. The fixtures under
# tests/fixtures/remote-reply/ are only read: an envelope is copied into the
# scratch mailbox with its expiry moved after the present, because the seam
# reads the real clock. Events, handled markers, the sender file, the forward
# index and the lineage are made by the cases.
#
# THE PIPELINE MARKERS ARE UNSET FOR EVERY RUN except the cases that set them,
# so the suite means the same inside an unattended stage.
#
# THE POSITIVE CONTROLS COME FIRST. A suite that only measures rejections is
# green against a seam that never writes.

set -uo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
PLUGIN="$repo_root/plugins/cc-cmds"
SEAM="$PLUGIN/hooks/remote-reply/seam.sh"
PRETOOL="$PLUGIN/hooks/remote-reply/pretool.sh"
HOOKS_JSON="$PLUGIN/hooks/hooks.json"
DISMISS="$PLUGIN/hooks/session-return-dismiss.sh"
FX="$repo_root/tests/fixtures/remote-reply"

passed=0
failed=0
ok()   { passed=$((passed + 1)); printf 'PASS: %s\n' "$1"; }
bad()  { failed=$((failed + 1)); printf 'FAIL: %s — %s\n' "$1" "${2:-}" >&2; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got '$2', want '$3'"; fi; }

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not installed — the seam parses JSON and nothing can be driven without it"
  echo "test-remote-reply: 0 passed, 0 failed"
  exit 0
fi

for v in $(compgen -v CC_PIPELINE_); do unset "$v"; done

WORK=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/cc-remote-reply.XXXXXX")" && pwd)
trap 'chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

OUTF="$WORK/seam.out"
ERR="$WORK/seam.err"
LOUD=0
# One `NAME=value` the next runs add to the environment (a pipeline marker).
EXTRA_ENV=""

SID1='5f0c2d4e-1111-4a2b-9c3d-000000000001'
SID2='5f0c2d4e-1111-4a2b-9c3d-000000000002'
SID3='5f0c2d4e-1111-4a2b-9c3d-000000000003'
RUN='20261101-a5df83a0'
APPR_SLOT="cc-cmds-autopilot-$RUN-judg-0001-1a2b3c4d"

now_ms() { perl -MTime::HiRes=time -e 'printf "%d", time() * 1000'; }

# fresh — a new scratch root for one case; sets s, ROOT, STATE.
fresh() {
  s=$(mktemp -d "$WORK/case.XXXXXX")
  mkdir -p "$s/home/.config/cc-cmds" "$s/state" "$s/root"
  ROOT="$s/root"
  STATE="$s/state/cc-cmds"
  printf 'host-a1\n' > "$s/home/.config/cc-cmds/host-id"
  jq -n '{schema: 1, senders: [{id: "tg:123456789", capabilities: ["option"]},
                               {id: "app:dk-7f3a91", capabilities: ["option"]}]}' \
    > "$s/home/.config/cc-cmds/remote-senders.json"
}

# seam <stdin> <args>... — run seam.sh; sets RC, output in OUTF / ERR.
seam() {
  local input="$1"; shift
  printf '%s' "$input" | env HOME="$s/home" XDG_STATE_HOME="$s/state" \
    CC_CMDS_ATTENTION_ROOT="$ROOT" CLAUDE_PLUGIN_ROOT="$PLUGIN" \
    ${EXTRA_ENV:+$EXTRA_ENV} bash "$SEAM" "$@" > "$OUTF" 2> "$ERR"
  RC=$?
  if [ "$RC" -ne 0 ] || [ -s "$ERR" ]; then
    LOUD=$((LOUD + 1))
    printf 'loud run: rc=%s stderr=%s\n' "$RC" "$(head -c 200 "$ERR")" >&2
  fi
}

# pretool <stdin> — run pretool.sh the way the harness does.
pretool() {
  printf '%s' "$1" | env HOME="$s/home" XDG_STATE_HOME="$s/state" \
    CC_CMDS_ATTENTION_ROOT="$ROOT" CLAUDE_PLUGIN_ROOT="$PLUGIN" \
    ${EXTRA_ENV:+$EXTRA_ENV} bash "$PRETOOL" > "$OUTF" 2> "$ERR"
  RC=$?
  if [ "$RC" -ne 0 ] || [ -s "$ERR" ]; then
    LOUD=$((LOUD + 1))
    printf 'loud run: rc=%s stderr=%s\n' "$RC" "$(head -c 200 "$ERR")" >&2
  fi
}

listing() { ( cd "$s" && find . -print | LC_ALL=C sort ); }
out() { cat "$OUTF"; }

# put_env <envelope file> [<jq filter>] — copy an envelope into its mailbox with
# the expiry (and pick-up deadline) moved after now; prints the copy's path.
put_env() {
  local src="$1" filter="${2:-.}" now addr rid dst
  now=$(now_ms)
  addr=$(jq -r 'if .target.surface == "approval" then "r-" + .target.run_id
                else "s-" + (.target.session_id | gsub("[^A-Za-z0-9_.-]"; "_")) end' "$src")
  rid=$(jq -r '.reply_id' "$src")
  mkdir -p "$ROOT/inbox/$addr"
  dst="$ROOT/inbox/$addr/$rid.json"
  jq --argjson now "$now" \
    '.expires_at_ms = ($now + 600000)
     | if has("pickup_by_ms") then .pickup_by_ms = ($now + 120000) else . end' "$src" \
    | jq "$filter" > "$dst"
  printf '%s' "$dst"
}

# put_event <envelope file> <slot> [<jq filter>] — the event record the envelope
# names, created long before now.
put_event() {
  local ev
  ev=$(jq -r '.event_id' "$1")
  mkdir -p "$ROOT/events"
  jq -n --arg id "$ev" --arg slot "$2" \
    '{schema: 1, id: $id, host: "host-a1", created_at_ms: 1000, kind: "auq",
      token: "session-ask", slot: $slot, title: "t", body: "b", actionable: true,
      accepts: ["option"], origin: {}, reply: null}' | jq "${3:-.}" > "$ROOT/events/$ev.json"
}

# auq_call <envelope file> <session id> — the open call the envelope targets.
auq_call() {
  jq -c --arg sid "$2" '{session_id: $sid, tool_use_id: .target.tool_use_id,
    questions: [ .target.questions[] | {question, header, multiSelect: .multi_select,
                 options: [ .options[] | {label, description: (.label + " 설명")} ]} ]}' "$1"
}

# index_run <session id>... — put the run in each session's forward index and
# its lineage.
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

# rejected <name> <before listing> — the last run printed nothing and changed
# no file.
rejected() {
  local after
  after=$(listing)
  if [ -s "$OUTF" ]; then bad "$1" "출력이 있다: $(head -c 120 "$OUTF")"
  elif [ "$after" != "$2" ]; then bad "$1" "파일이 바뀌었다"
  else ok "$1"; fi
}

AUQ1="$FX/envelope-auq-single.json"
AUQM="$FX/envelope-auq-multi.json"
FORM="$FX/envelope-form.json"
APPR="$FX/envelope-approval.json"
RID_AUQ1=$(jq -r '.reply_id' "$AUQ1")
RID_AUQM=$(jq -r '.reply_id' "$AUQM")
RID_FORM=$(jq -r '.reply_id' "$FORM")
RID_APPR=$(jq -r '.reply_id' "$APPR")
SAFE1="s-$SID1"

# ---------------------------------------------------------------------------
# 1. Acceptance — the single-select AskUserQuestion envelope.
# ---------------------------------------------------------------------------
fresh
env1=$(put_env "$AUQ1")
put_event "$env1" "cc-cmds-session-ask-$SID1"
call=$(auq_call "$env1" "$SID1")
seam "$call" commit "$SAFE1" "$RID_AUQ1"
check "1 답 맵" "$(out | jq -cS .)" '{"시험을 지금 돌릴까요?":"예","어느 브랜치로 진행할까요?":"새 브랜치"}'
rec=$(applied_of "$RID_AUQ1")
check "1 적용 기록의 아홉 키" "$(jq -c 'keys' "$rec" 2>/dev/null)" \
  '["answers_sha256","applied_at_ms","event_id","reply_id","schema","sender","session_id","tool_use_id","transport"]'
want_hash=$(printf '%s' "$call" | jq -j --argjson a "$(out)" '.questions[] | .question, "\u001f", $a[.question], "\u001e"' | shasum -a 256 | cut -d' ' -f1)
check "1 answers_sha256 이 원상의 해시" "$(jq -r '.answers_sha256' "$rec")" "$want_hash"
check "1 기록의 대상 칸·세션·발신" "$(jq -r '[.tool_use_id, .session_id, .transport, .sender] | join(" ")' "$rec")" \
  "toolu_01AuqSingle00000000000001 $SID1 telegram tg:123456789"
check "1 수령 표지가 이 세션 것" "$(jq -r '.session_id' "$ROOT/inbox/$SAFE1/$RID_AUQ1.picked" 2>/dev/null)" "$SID1"
check "1 수령 표지의 적용 기한" "$(jq -r '.apply_by_ms - .picked_at_ms' "$ROOT/inbox/$SAFE1/$RID_AUQ1.picked")" "120000"
hm=$(find "$ROOT/handled" -name '*.json' -print -quit 2>/dev/null)
check "1 처리 표지 — 원인·정확 일치·사건 slot" "$(jq -r '[.cause, (.prefix | tostring), .slot] | join(" ")' "$hm" 2>/dev/null)" \
  "reply-applied false cc-cmds-session-ask-$SID1"
h=$(printf '%s\037%s' "$ROOT" "toolu_01AuqSingle00000000000001" | shasum -a 256 | cut -d' ' -f1)
check "1 대상 칸 선점 파일이 reply_id 를 담음" "$(cat "$STATE/remote-reply/target/$h" 2>/dev/null)" "$RID_AUQ1"
before=$(listing)
seam "$call" commit "$SAFE1" "$RID_AUQ1"
rejected "1 같은 봉투를 다시 확정하면 거절" "$before"

# ---------------------------------------------------------------------------
# 2. Acceptance — the multi-select envelope: labels in the call's option order.
# ---------------------------------------------------------------------------
fresh
envm=$(put_env "$AUQM")
put_event "$envm" "cc-cmds-session-ask-$SID1"
seam "$(auq_call "$envm" "$SID1")" commit "$SAFE1" "$RID_AUQM"
check "2 다중 선택 답 문자열" "$(out | jq -r '."이번 판에 무엇을 함께 돌릴까요?"')" "린트, 시험"
check "2 단일 선택 답" "$(out | jq -r '."결과를 어디에 남길까요?"')" "PR 본문"

# ---------------------------------------------------------------------------
# 2b. Handled markers that do not close the event leave it open: a later prefix
#     marker of another slot, a file that does not parse, and more markers than
#     one argument list holds. The matching prefix marker is the negative
#     control: it closes the event.
# ---------------------------------------------------------------------------
# hmark <name> <slot> <prefix> — a marker later than every event of the suite.
hmark() {
  mkdir -p "$ROOT/handled"
  jq -n --arg s "$2" --argjson p "$3" \
    '{schema: 1, id: "h", host: "host-a1", at_ms: 2000, slot: $s, prefix: $p, cause: "return"}' > "$ROOT/handled/$1.json"
}
fresh
env1=$(put_env "$AUQ1")
put_event "$env1" "cc-cmds-session-ask-$SID1"
hmark other "cc-cmds-active-notify-other@" true
seam "$(auq_call "$env1" "$SID1")" commit "$SAFE1" "$RID_AUQ1"
check "2b 다른 slot 의 나중 접두 표지가 있어도 수락" "$(out | jq -r '."어느 브랜치로 진행할까요?"' 2>/dev/null)" "새 브랜치"

fresh
env1=$(put_env "$AUQ1")
put_event "$env1" "cc-cmds-session-ask-$SID1"
mkdir -p "$ROOT/handled"
printf '{"schema":1,"slot":' > "$ROOT/handled/broken.json"
seam "$(auq_call "$env1" "$SID1")" commit "$SAFE1" "$RID_AUQ1"
check "2b 파싱되지 않는 표지 파일이 있어도 수락" "$(out | jq -r '."어느 브랜치로 진행할까요?"' 2>/dev/null)" "새 브랜치"

fresh
env1=$(put_env "$AUQ1")
put_event "$env1" "cc-cmds-session-ask-$SID1"
hmark unrelated "cc-cmds-active-notify-other" false
printf '{"schema":1,"slot":' > "$ROOT/handled/a-broken.json"
hmark z-match "cc-cmds-session-ask-$SID1" false
b=$(listing)
seam "$(auq_call "$env1" "$SID1")" commit "$SAFE1" "$RID_AUQ1"
rejected "2b 파싱되지 않는 표지 뒤의 정확 일치 표지가 사건을 닫음" "$b"

fresh
env1=$(put_env "$AUQ1")
put_event "$env1" "cc-cmds-session-ask-$SID1" '.slot = "cc-cmds-active-notify-'"$SID1"'@x"'
hmark match "cc-cmds-active-notify-$SID1@" true
b=$(listing)
seam "$(auq_call "$env1" "$SID1")" commit "$SAFE1" "$RID_AUQ1"
rejected "2b 사건 slot 의 접두인 접두 표지가 사건을 닫음" "$b"

fresh
env1=$(put_env "$AUQ1")
put_event "$env1" "cc-cmds-session-ask-$SID1"
mkdir -p "$ROOT/handled"
i=0
while [ "$i" -lt 12000 ]; do
  printf '{"schema":1,"id":"h%d","host":"host-a1","at_ms":2000,"slot":"cc-cmds-session-ask-other-%d","prefix":false,"cause":"return"}\n' \
    "$i" "$i" > "$ROOT/handled/host-a1.17934999$(printf '%05d' "$i").0a0b0c0d.json"
  i=$((i + 1))
done
seam "$(auq_call "$env1" "$SID1")" commit "$SAFE1" "$RID_AUQ1"
check "2b 표지 1만 2천 개에서도 수락" "$(out | jq -r '."어느 브랜치로 진행할까요?"' 2>/dev/null)" "새 브랜치"

# ---------------------------------------------------------------------------
# 3. S-open pair — the record and hash match applied-sopen.json for the call
#    of frame-sopen.jsonl.
# ---------------------------------------------------------------------------
fresh
fcall=$(head -n 1 "$FX/frame-sopen.jsonl" | jq -c --arg sid "$SID1" \
  '.message.content[0] | {session_id: $sid, tool_use_id: .id, questions: .input.questions}')
mkdir -p "$ROOT/inbox/$SAFE1"
sopen="$WORK/sopen-envelope.json"
jq -n --argjson c "$fcall" --arg sid "$SID1" '{
  schema: 1, reply_id: "host-a1.1793500004000.4e5f6071", event_id: "host-a1.1793499994000.44556677",
  host: "host-a1", kind: "option",
  target: {surface: "auq", session_id: $sid, tool_use_id: $c.tool_use_id,
           questions: [ $c.questions[] | {question, header, multi_select: .multiSelect,
                        options: [ .options[] | {label} ]} ]},
  answers: [{question_index: 0, labels: ["yes"]}, {question_index: 1, labels: ["later"]}],
  provenance: {transport: "app", sender: "app:dk-7f3a91", received_at_ms: 1793500004000, transport_ref: "push"},
  expires_at_ms: 1793500604000}' > "$sopen"
envs=$(put_env "$sopen")
put_event "$envs" "cc-cmds-session-ask-$SID1"
seam "$fcall" commit "$SAFE1" "host-a1.1793500004000.4e5f6071"
check "3 답 맵이 전사의 toolUseResult.answers 와 같음" "$(out | jq -cS .)" \
  "$(tail -n 1 "$FX/frame-sopen.jsonl" | jq -cS '.toolUseResult.answers')"
check "3 기록이 applied-sopen.json 과 같음(적용 시각 밖)" \
  "$(jq -cS 'del(.applied_at_ms)' "$(applied_of host-a1.1793500004000.4e5f6071)" 2>/dev/null)" \
  "$(jq -cS 'del(.applied_at_ms)' "$FX/applied-sopen.json")"

# ---------------------------------------------------------------------------
# 3b. wait — prints the first candidate of the open call, skips a rejected
#     reply id, and finds an approval envelope by the question's approval id.
# ---------------------------------------------------------------------------
# wait_for <stdin> — run `seam.sh wait` for at most five seconds; prints its line.
wait_for() {
  local pid i
  printf '%s' "$1" | env HOME="$s/home" XDG_STATE_HOME="$s/state" CC_CMDS_ATTENTION_ROOT="$ROOT" \
    CLAUDE_PLUGIN_ROOT="$PLUGIN" bash "$SEAM" wait > "$WORK/wait.out" 2>/dev/null &
  pid=$!
  for i in 1 2 3 4 5 6 7 8 9 10; do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.5
  done
  kill "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  cat "$WORK/wait.out"
}
fresh
env1=$(put_env "$AUQ1")
win=$(auq_call "$env1" "$SID1" | jq -c '. + {rejected: []}')
check "3b wait 가 열린 호출의 봉투를 냄" "$(wait_for "$win")" "$SAFE1 $RID_AUQ1"
check "3b wait 가 거절한 reply_id 를 건너뜀" "$(wait_for "$(printf '%s' "$win" | jq -c --arg r "$RID_AUQ1" '.rejected = [$r]')")" ""
enva=$(put_env "$APPR")
index_run "$SID2"
awin=$(head -n 1 "$FX/frame-sat.jsonl" | jq -c --arg sid "$SID2" '.message.content[0] | {session_id: $sid, tool_use_id: .id, questions: .input.questions, rejected: []}')
check "3b wait 가 승인 id 로 런 주소 봉투를 냄" "$(wait_for "$awin")" "r-$RUN $RID_APPR"

# ---------------------------------------------------------------------------
# 4. Run address — pick-up by scan, then S-at answers at once; the record and
#    hash match applied-sat.json for the call of frame-sat.jsonl.
# ---------------------------------------------------------------------------
fresh
enva=$(put_env "$APPR")
put_event "$enva" "$APPR_SLOT"
index_run "$SID2"
seam "{\"session_id\":\"$SID2\",\"form\":null}" scan
check "4 scan 이 깨우기 후보를 냄" "$(out | jq -c '.wake')" \
  "[{\"run_id\":\"$RUN\",\"approval_id\":\"judg-0001-1a2b3c4d\",\"reply_id\":\"$RID_APPR\"}]"
check "4 수령 표지가 이 세션 것" "$(jq -r '.session_id' "$ROOT/inbox/r-$RUN/$RID_APPR.picked" 2>/dev/null)" "$SID2"
hin=$(head -n 1 "$FX/frame-sat.jsonl" | jq -c --arg sid "$SID2" \
  '.message.content[0] | {hook_event_name: "PreToolUse", session_id: $sid, tool_name: "AskUserQuestion",
                          tool_use_id: .id, tool_input: .input}')
t0=$(now_ms)
pretool "$hin"
t1=$(now_ms)
check "4 S-at 출력" "$(out | jq -cS .)" \
  "$(jq -cnS --argjson a "$(tail -n 1 "$FX/frame-sat.jsonl" | jq -c '.toolUseResult.answers')" \
     '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "allow", updatedInput: {answers: $a}}}')"
check "4 출력이 한 줄" "$(wc -l < "$OUTF" | tr -d ' ')" "1"
check "4 기록이 applied-sat.json 과 같음(적용 시각 밖)" \
  "$(jq -cS 'del(.applied_at_ms)' "$(applied_of "$RID_APPR")" 2>/dev/null)" \
  "$(jq -cS 'del(.applied_at_ms)' "$FX/applied-sat.json")"
if [ $((t1 - t0)) -lt 3000 ]; then ok "4 S-at 이 기다리지 않음"; else bad "4 S-at 이 기다리지 않음" "$((t1 - t0)) ms"; fi
check "4 처리 표지 slot 이 승인 사건 slot" "$(jq -r '.slot' "$(find "$ROOT/handled" -name '*.json' -print -quit)")" "$APPR_SLOT"

# ---------------------------------------------------------------------------
# 5. Question form — scan, form-pick, form-record with the submitted bytes.
# ---------------------------------------------------------------------------
fresh
envf=$(put_env "$FORM")
put_event "$envf" "cc-cmds-session-ask-$SID1"
ftarget=$(jq -c '.target | {form_id, session_id, questions}' "$envf")
fin=$(jq -cn --arg sid "$SID1" --argjson f "$ftarget" '{session_id: $sid, form: $f}')
seam "$fin" scan
check "5 scan 이 질문지 봉투와 고른 라벨을 냄" "$(out | jq -c '.form')" \
  "{\"reply_id\":\"$RID_FORM\",\"picks\":[{\"id\":\"q1\",\"label\":\"내일 아침\"},{\"id\":\"q2\",\"label\":\"당번\"}]}"
check "5 scan 은 질문지 봉투에 아무것도 쓰지 않음" "$(ls "$ROOT/inbox/$SAFE1" | wc -l | tr -d ' ')" "1"
seam "$fin" form-pick "$RID_FORM"
check "5 form-pick 이 reply_id 를 냄" "$(out)" "$RID_FORM"
seam "$(cat "$FX/submit-form.txt")" form-record "$SID1" "$RID_FORM"
check "5 기록이 applied-form.json 과 같음(적용 시각 밖)" \
  "$(jq -cS 'del(.applied_at_ms)' "$(applied_of "$RID_FORM")" 2>/dev/null)" \
  "$(jq -cS 'del(.applied_at_ms)' "$FX/applied-form.json")"
check "5 처리 표지 하나" "$(handled_count)" "1"

# The submit runs the prompt hooks before form-record, and the return hook may
# mark the event handled first — by the event's own slot or by a session prefix
# marker. The applied record is written all the same.
for kind in exact prefix; do
  fresh
  envf=$(put_env "$FORM")
  put_event "$envf" "cc-cmds-session-ask-$SID1"
  fin=$(jq -cn --arg sid "$SID1" --argjson f "$(jq -c '.target | {form_id, session_id, questions}' "$envf")" '{session_id: $sid, form: $f}')
  seam "$fin" form-pick "$RID_FORM"
  if [ "$kind" = exact ]; then hmark ret "cc-cmds-session-ask-$SID1" false
  else hmark ret "cc-cmds-session-ask-" true; fi
  seam "$(cat "$FX/submit-form.txt")" form-record "$SID1" "$RID_FORM"
  check "5 제출 뒤 귀환 표지($kind)가 있어도 적용 기록을 씀" \
    "$(jq -cS 'del(.applied_at_ms)' "$(applied_of "$RID_FORM")" 2>/dev/null)" \
    "$(jq -cS 'del(.applied_at_ms)' "$FX/applied-form.json")"
  check "5 제출 뒤 귀환 표지($kind)가 있어도 reply-applied 표지를 씀" \
    "$(find "$ROOT/handled" -name '*.json' ! -name 'ret.json' -exec jq -r '.cause' {} + 2>/dev/null)" "reply-applied"
done

fresh
envf=$(put_env "$FORM")
put_event "$envf" "cc-cmds-session-ask-$SID1"
fin=$(jq -cn --arg sid "$SID1" --argjson f "$(jq -c '.target | {form_id, session_id, questions}' "$envf")" '{session_id: $sid, form: $f}')
seam "$fin" form-pick "$RID_FORM"
seam "{\"session_id\":\"$SID1\"}" form-unpick "$RID_FORM"
if [ -e "$ROOT/inbox/$SAFE1/$RID_FORM.picked" ]; then bad "5 거두기 뒤 수령 표지가 남지 않음" "남아 있다"; else ok "5 거두기 뒤 수령 표지가 남지 않음"; fi
before=$(listing)
seam "$fin" form-pick "$RID_FORM"
seam "{\"session_id\":\"$SID2\"}" form-unpick "$RID_FORM"
check "5 다른 세션의 거두기는 표지를 지우지 않음" "$(jq -r '.session_id' "$ROOT/inbox/$SAFE1/$RID_FORM.picked" 2>/dev/null)" "$SID1"
fother=$(jq -cn --arg sid "$SID1" --argjson f "$(jq -c '.target | {form_id: "f-00000000", session_id, questions}' "$envf")" '{session_id: $sid, form: $f}')
seam "$fother" scan
check "5 다른 form_id 의 열린 질문지에는 후보 없음" "$(out | jq -c '.form')" "null"

# ---------------------------------------------------------------------------
# 6. Rejections — each violation writes nothing, prints nothing, rc 0.
# ---------------------------------------------------------------------------
# reject_auq <name> <envelope filter> <call filter> [<event filter>] [<setup>]
reject_auq() {
  local name="$1" ef="$2" cf="$3" evf="${4:-.}" setup="${5:-}" e c b
  fresh
  e=$(put_env "$AUQ1" "$ef")
  put_event "$e" "cc-cmds-session-ask-$SID1" "$evf"
  c=$(auq_call "$AUQ1" "$SID1" | jq -c "$cf")
  [ -z "$setup" ] || eval "$setup"
  b=$(listing)
  seam "$c" commit "$SAFE1" "$RID_AUQ1"
  rejected "6 거절 — $name" "$b"
}
reject_auq "호스트가 다름" '.host = "host-b2" | .event_id = "host-b2.1793499990000.11223344"' '.'
reject_auq "봉투 host 와 이 기계 host-id 가 다름" '.' '.' '.' 'printf "host-zz\n" > "$s/home/.config/cc-cmds/host-id"'
reject_auq "사건이 없음" '.' '.' '.' 'rm -f "$ROOT/events/"*.json'
reject_auq "사건 schema 가 1 이 아님" '.' '.' '.schema = 2'
reject_auq "사건 accepts 에 option 없음" '.' '.' '.accepts = []'
reject_auq "사건이 처리됨(정확 일치 표지)" '.' '.' '.' \
  'mkdir -p "$ROOT/handled"; jq -n --arg s "cc-cmds-session-ask-$SID1" "{schema:1,id:\"h\",host:\"host-a1\",at_ms:2000,slot:\$s,prefix:false,cause:\"return\"}" > "$ROOT/handled/h.json"'
reject_auq "사건이 처리됨(접두 표지)" '.' '.' ".slot = \"cc-cmds-session-ask-$SID1@x\"" \
  'mkdir -p "$ROOT/handled"; jq -n --arg s "cc-cmds-session-ask-$SID1@" "{schema:1,id:\"h\",host:\"host-a1\",at_ms:2000,slot:\$s,prefix:true,cause:\"return\"}" > "$ROOT/handled/h.json"'
reject_auq "대상 tool_use_id 가 열린 호출과 다름" '.' '.tool_use_id = "toolu_other"'
reject_auq "질문 문면이 다름" '.' '.questions[0].question = "다른 질문"'
reject_auq "header 가 다름" '.' '.questions[0].header = "다름"'
reject_auq "multiSelect 가 다름" '.' '.questions[1].multiSelect = true'
reject_auq "선택지 라벨 목록이 다름" '.' '.questions[0].options |= reverse'
reject_auq "라벨이 선택지에 없음" '.answers[0].labels = ["없는 라벨"]' '.'
reject_auq "단일 선택에 라벨 둘" '.answers[0].labels = ["master", "새 브랜치"]' '.'
reject_auq "답이 질문을 다 덮지 않음" '.answers = [.answers[0]]' '.'
reject_auq "question_index 순서가 어긋남" '.answers |= reverse' '.'
reject_auq "같은 라벨의 선택지 둘" \
  '.target.questions[1].options = [{"label":"예"},{"label":"예"}]' \
  '.questions[1].options = [{"label":"예","description":"a"},{"label":"예","description":"b"}]'
reject_auq "다중 선택 선택지에 쉼표와 공백" \
  '.target.questions[1].multi_select = true | .target.questions[1].options = [{"label":"예, 지금"},{"label":"아니요"}] | .answers[1].labels = ["아니요"]' \
  '.questions[1].multiSelect = true | .questions[1].options = [{"label":"예, 지금","description":"a"},{"label":"아니요","description":"b"}]'
reject_auq "다중 선택 라벨이 겹침" \
  '.target.questions[1].multi_select = true | .answers[1].labels = ["예", "예"]' \
  '.questions[1].multiSelect = true'
reject_auq "질문 문면에 0x1F" \
  '.target.questions[0].question = "어느\u001f브랜치"' '.questions[0].question = "어느\u001f브랜치"'
reject_auq "같은 문면의 질문 둘" \
  '.target.questions[1].question = .target.questions[0].question' '.questions[1].question = .questions[0].question'
reject_auq "만료" '.expires_at_ms = 1000' '.'
reject_auq "이미 적용됨" '.' '.' '.' \
  'mkdir -p "$ROOT/applied"; printf "{}\n" > "$ROOT/applied/$RID_AUQ1.json"'
reject_auq "다른 세션의 수령 표지" '.' '.' '.' \
  'jq -n --arg r "$RID_AUQ1" --arg s "$SID2" "{schema:1,reply_id:\$r,session_id:\$s,picked_at_ms:1,apply_by_ms:120001}" > "$ROOT/inbox/$SAFE1/$RID_AUQ1.picked"'
reject_auq "대상 칸을 다른 봉투가 선점" '.' '.' '.' \
  'h=$(printf "%s\037%s" "$ROOT" "toolu_01AuqSingle00000000000001" | shasum -a 256 | cut -d" " -f1); mkdir -p "$STATE/remote-reply/target"; printf "host-a1.1.00000000\n" > "$STATE/remote-reply/target/$h"'
reject_auq "등록되지 않은 발신자" '.provenance.sender = "tg:999"' '.'
reject_auq "종류 없는 발신자" '.' '.' '.' \
  'jq -n "{schema:1,senders:[{id:\"tg:123456789\",capabilities:[]}]}" > "$s/home/.config/cc-cmds/remote-senders.json"'
reject_auq "발신자 인가 파일 없음" '.' '.' '.' 'rm -f "$s/home/.config/cc-cmds/remote-senders.json"'
reject_auq "세션 주소가 다른 세션의 것" ".target.session_id = \"$SID2\"" '.'

# The form-specific rejection: a different question id.
fresh
envf=$(put_env "$FORM")
put_event "$envf" "cc-cmds-session-ask-$SID1"
fin=$(jq -cn --arg sid "$SID1" --argjson f "$(jq -c '.target | {form_id, session_id, questions} | .questions[0].id = "qx"' "$envf")" '{session_id: $sid, form: $f}')
b=$(listing)
seam "$fin" form-pick "$RID_FORM"
rejected "6 거절 — 질문지 질문 id 가 다름" "$b"

# Approval call: a two-question call, and a normalized label set that differs.
fresh
enva=$(put_env "$APPR")
put_event "$enva" "$APPR_SLOT"
index_run "$SID2"
seam "{\"session_id\":\"$SID2\",\"form\":null}" scan
b=$(listing)
seam "$(head -n 1 "$FX/frame-sat.jsonl" | jq -c --arg sid "$SID2" '.message.content[0] | {session_id: $sid, tool_use_id: .id, questions: (.input.questions + .input.questions)}')" commit "r-$RUN" "$RID_APPR"
rejected "6 거절 — 질문이 둘인 승인 호출" "$b"
seam "$(head -n 1 "$FX/frame-sat.jsonl" | jq -c --arg sid "$SID2" '.message.content[0] | {session_id: $sid, tool_use_id: .id, questions: (.input.questions | .[0].options |= .[0:2])}')" commit "r-$RUN" "$RID_APPR"
rejected "6 거절 — 정규화한 라벨 집합이 다른 승인 호출" "$b"

# ---------------------------------------------------------------------------
# 7. Target cell — one record per cell; one of two concurrent commits passes.
# ---------------------------------------------------------------------------
fresh
e1=$(put_env "$AUQ1")
put_event "$e1" "cc-cmds-session-ask-$SID1"
twin="$WORK/twin.json"
jq '.reply_id = "host-a1.1793500000500.99887766" | .event_id = "host-a1.1793499990500.99887766"' "$AUQ1" > "$twin"
e2=$(put_env "$twin")
put_event "$e2" "cc-cmds-session-ask-$SID1"
call=$(auq_call "$e1" "$SID1")
seam "$call" commit "$SAFE1" "$RID_AUQ1"
first=$(out)
seam "$call" commit "$SAFE1" "host-a1.1793500000500.99887766"
check "7 같은 칸의 둘째 봉투는 기록되지 않음" "$( [ -n "$first" ] && [ ! -s "$OUTF" ] && [ ! -e "$(applied_of host-a1.1793500000500.99887766)" ] && echo yes)" "yes"

fresh
enva=$(put_env "$APPR")
put_event "$enva" "$APPR_SLOT"
index_run "$SID1" "$SID2"
seam "{\"session_id\":\"$SID1\",\"form\":null}" scan
c1=$(head -n 1 "$FX/frame-sat.jsonl" | jq -c --arg sid "$SID1" '.message.content[0] | {session_id: $sid, tool_use_id: "toolu_concurrent_a", questions: .input.questions}')
c2=$(head -n 1 "$FX/frame-sat.jsonl" | jq -c --arg sid "$SID2" '.message.content[0] | {session_id: $sid, tool_use_id: "toolu_concurrent_b", questions: .input.questions}')
runenv() { env HOME="$s/home" XDG_STATE_HOME="$s/state" CC_CMDS_ATTENTION_ROOT="$ROOT" CLAUDE_PLUGIN_ROOT="$PLUGIN" bash "$SEAM" "$@"; }
printf '%s' "$c1" | runenv commit "r-$RUN" "$RID_APPR" > "$WORK/c1.out" 2>/dev/null &
p1=$!
printf '%s' "$c2" | runenv commit "r-$RUN" "$RID_APPR" > "$WORK/c2.out" 2>/dev/null &
p2=$!
wait "$p1" "$p2"
n=0
[ -s "$WORK/c1.out" ] && n=$((n + 1))
[ -s "$WORK/c2.out" ] && n=$((n + 1))
check "7 같은 reply_id 의 동시 확정은 하나만 통과" "$n" "1"
winner=$(jq -r '.session_id' "$(applied_of "$RID_APPR")" 2>/dev/null)
if [ -s "$WORK/c1.out" ]; then want=$SID1; else want=$SID2; fi
check "7 기록이 통과한 쪽의 것" "$winner" "$want"

# ---------------------------------------------------------------------------
# 8. Pick-up — one of two sessions picks; outside the lineage nothing; the
#    inheriting session keeps the marker's session id.
# ---------------------------------------------------------------------------
fresh
enva=$(put_env "$APPR")
put_event "$enva" "$APPR_SLOT"
index_run "$SID1" "$SID2"
printf '%s' "{\"session_id\":\"$SID1\",\"form\":null}" | runenv scan > "$WORK/p1.out" 2>/dev/null &
p1=$!
printf '%s' "{\"session_id\":\"$SID2\",\"form\":null}" | runenv scan > "$WORK/p2.out" 2>/dev/null &
p2=$!
wait "$p1" "$p2"
picker=$(jq -r '.session_id' "$ROOT/inbox/r-$RUN/$RID_APPR.picked" 2>/dev/null)
case "$picker" in "$SID1"|"$SID2") ok "8 두 세션 중 하나만 수령" ;; *) bad "8 두 세션 중 하나만 수령" "$picker" ;; esac
check "8 수령 표지 하나" "$(ls "$ROOT/inbox/r-$RUN" | grep -c '\.picked$')" "1"
other=$SID2; [ "$picker" = "$SID2" ] && other=$SID1
seam "{\"session_id\":\"$other\",\"form\":null}" scan
check "8 계보로 이어받은 세션에 깨우기 후보" "$(out | jq -r '.wake[0].reply_id')" "$RID_APPR"
check "8 이어받은 세션은 표지의 session_id 를 고치지 않음" "$(jq -r '.session_id' "$ROOT/inbox/r-$RUN/$RID_APPR.picked")" "$picker"

fresh
enva=$(put_env "$APPR")
put_event "$enva" "$APPR_SLOT"
index_run "$SID1"
mkdir -p "$STATE/session"
printf '%s\n' "$RUN" > "$STATE/session/$SID3"
b=$(listing)
seam "{\"session_id\":\"$SID3\",\"form\":null}" scan
check "8 계보 밖 세션은 후보 없음" "$(out | jq -c '.wake')" "[]"
if [ "$(listing)" = "$b" ]; then ok "8 계보 밖 세션은 수령하지 않음"; else bad "8 계보 밖 세션은 수령하지 않음" "파일이 바뀌었다"; fi

# ---------------------------------------------------------------------------
# 9. Wake — once per envelope; the literal's shape; the return hook does not
#    read it as a return.
# ---------------------------------------------------------------------------
fresh
enva=$(put_env "$APPR")
put_event "$enva" "$APPR_SLOT"
index_run "$SID2"
seam "{\"session_id\":\"$SID2\",\"form\":null}" scan
seam "{\"session_id\":\"$SID2\"}" wake-mark "$RUN" "$RID_APPR"
lit=$(out)
check "9 깨우기 리터럴이 고정 예제와 같음" "$lit" "$(head -n 1 "$FX/wake-approval.txt")"
if grep -Eq <<<"$lit" '^<cc-remote-approval run=[A-Za-z0-9-]{1,64} id=[A-Za-z0-9_-]{1,55}-[0-9a-f]{8}/>$'; then
  ok "9 리터럴이 정본 정규식에 맞음"; else bad "9 리터럴이 정본 정규식에 맞음" "$lit"; fi
check "9 표지에 woken_at_ms" "$(jq -r 'has("woken_at_ms")' "$ROOT/inbox/r-$RUN/$RID_APPR.picked")" "true"
check "9 덧쓰기가 다른 키를 바꾸지 않음" "$(jq -c 'del(.woken_at_ms) | keys' "$ROOT/inbox/r-$RUN/$RID_APPR.picked")" \
  '["apply_by_ms","picked_at_ms","reply_id","schema","session_id"]'
seam "{\"session_id\":\"$SID2\"}" wake-mark "$RUN" "$RID_APPR"
check "9 두 번째 wake-mark 는 아무것도 내지 않음" "$(out)" ""
seam "{\"session_id\":\"$SID2\",\"form\":null}" scan
check "9 깨운 봉투는 후보가 아님" "$(out | jq -c '.wake')" "[]"
envelope_re=$(grep -m 1 -E '^envelope_re=' "$DISMISS")
pasted_re=$(grep -m 1 -E '^pasted_re=' "$DISMISS")
eval "$envelope_re"
eval "$pasted_re"
if [[ hi =~ $envelope_re ]]; then bad "9 귀환 훅 정규식의 양성 대조" "hi 가 봉투로 읽힘"; else ok "9 귀환 훅 정규식의 양성 대조"; fi
if [[ $lit =~ $envelope_re ]] && ! [[ $lit =~ $pasted_re ]]; then
  ok "9 리터럴은 귀환 훅이 귀환으로 읽지 않음"; else bad "9 리터럴은 귀환 훅이 귀환으로 읽지 않음" "$lit"; fi

# ---------------------------------------------------------------------------
# 10. S-at negatives — no output, no file, no wait.
# ---------------------------------------------------------------------------
fresh
enva=$(put_env "$APPR")
put_event "$enva" "$APPR_SLOT"
index_run "$SID2"
hin=$(head -n 1 "$FX/frame-sat.jsonl" | jq -c --arg sid "$SID2" \
  '.message.content[0] | {hook_event_name: "PreToolUse", session_id: $sid, tool_name: "AskUserQuestion", tool_use_id: .id, tool_input: .input}')
b=$(listing)
pretool "$hin"
rejected "10 수령 표지가 없으면 S-at 출력 없음" "$b"
seam "{\"session_id\":\"$SID2\",\"form\":null}" scan
b=$(listing)
pretool "$(printf '%s' "$hin" | jq -c '.tool_input.questions += .tool_input.questions')"
rejected "10 질문이 둘이면 출력 없음" "$b"
pretool "$(printf '%s' "$hin" | jq -c '.tool_input.questions[0].question = "다른 질문"')"
rejected "10 승인 문면이 아니면 출력 없음" "$b"
pretool "$(printf '%s' "$hin" | jq -c '. + {agent_id: "a1"}')"
rejected "10 agent_id 가 있으면 출력 없음" "$b"
for m in CC_PIPELINE_SEGMENT CC_PIPELINE_STAGE_ID CC_PIPELINE_SHIFT_ID CC_PIPELINE_REENTRY; do
  EXTRA_ENV="$m=x"
  t0=$(now_ms)
  pretool "$hin"
  t1=$(now_ms)
  EXTRA_ENV=""
  rejected "10 표지 $m 이 있으면 출력 없음" "$b"
done
if [ $((t1 - t0)) -lt 3000 ]; then ok "10 출력 없는 S-at 이 곧바로 끝남"; else bad "10 출력 없는 S-at 이 곧바로 끝남" "$((t1 - t0)) ms"; fi

# ---------------------------------------------------------------------------
# 11. Cleanup — only after the envelope is gone; envelopes are never removed.
# ---------------------------------------------------------------------------
fresh
env1=$(put_env "$AUQ1")
put_event "$env1" "cc-cmds-session-ask-$SID1"
seam "$(auq_call "$env1" "$SID1")" commit "$SAFE1" "$RID_AUQ1"
b=$(listing)
seam "{\"session_id\":\"$SID1\"}" cleanup
if [ "$(listing)" = "$b" ]; then ok "11 봉투가 있으면 아무것도 지우지 않음"; else bad "11 봉투가 있으면 아무것도 지우지 않음" "파일이 바뀌었다"; fi
rm -f "$env1"
seam "{\"session_id\":\"$SID1\"}" cleanup
h=$(printf '%s\037%s' "$ROOT" "toolu_01AuqSingle00000000000001" | shasum -a 256 | cut -d' ' -f1)
left=0
[ -e "$ROOT/inbox/$SAFE1/$RID_AUQ1.picked" ] && left=$((left + 1))
[ -e "$(applied_of "$RID_AUQ1")" ] && left=$((left + 1))
[ -e "$STATE/remote-reply/target/$h" ] && left=$((left + 1))
check "11 봉투가 사라진 뒤 표지·기록·선점 파일을 지움" "$left" "0"
check "11 사건과 처리 표지는 지우지 않음" "$(ls "$ROOT/events" | wc -l | tr -d ' ') $(handled_count)" "1 1"

# ---------------------------------------------------------------------------
# 12. Activation — each router marker silences every subcommand; neither shell
#     names the test seat of the spool root; the hooks.json entry.
# ---------------------------------------------------------------------------
for m in CC_PIPELINE_SEGMENT CC_PIPELINE_STAGE_ID CC_PIPELINE_SHIFT_ID CC_PIPELINE_REENTRY; do
  fresh
  env1=$(put_env "$AUQ1")
  put_event "$env1" "cc-cmds-session-ask-$SID1"
  enva=$(put_env "$APPR")
  put_event "$enva" "$APPR_SLOT"
  index_run "$SID1"
  envf=$(put_env "$FORM")
  fin=$(jq -cn --arg sid "$SID1" --argjson f "$(jq -c '.target | {form_id, session_id, questions}' "$envf")" '{session_id: $sid, form: $f}')
  b=$(listing)
  EXTRA_ENV="$m=x"
  seam "$(auq_call "$env1" "$SID1")" commit "$SAFE1" "$RID_AUQ1"; o1=$(out)
  seam "{\"session_id\":\"$SID1\",\"form\":null}" scan; o2=$(out)
  seam "$fin" form-pick "$RID_FORM"; o3=$(out)
  seam "{\"session_id\":\"$SID1\"}" cleanup; o4=$(out)
  EXTRA_ENV=""
  if [ -z "$o1$o2$o3$o4" ] && [ "$(listing)" = "$b" ]; then ok "12 표지 $m — 모든 하위 명령이 아무것도 쓰지 않음"
  else bad "12 표지 $m — 모든 하위 명령이 아무것도 쓰지 않음" "출력 또는 파일 변화"; fi
done
check "12 seam.sh·pretool.sh 에 시험 자리 이름 없음" "$(cat "$SEAM" "$PRETOOL" | grep -c 'CC_CMDS_ATTENTION_ROOT')" "0"
check "12 hooks.json 의 PreToolUse(AskUserQuestion) S-at 항목" \
  "$(jq -r '.hooks.PreToolUse[] | select(.matcher == "AskUserQuestion") | .hooks[] | select(.command | contains("remote-reply/pretool.sh")) | "\(.command)|\(.timeout)"' "$HOOKS_JSON")" \
  'bash "${CLAUDE_PLUGIN_ROOT}/hooks/remote-reply/pretool.sh"|5'
if [ -x "$SEAM" ] && [ -x "$PRETOOL" ]; then ok "12 두 셸이 실행 가능"; else bad "12 두 셸이 실행 가능" "실행 권한 없음"; fi

check "13 모든 실행이 rc 0 이고 stderr 가 비어 있음" "$LOUD" "0"

echo "test-remote-reply: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
