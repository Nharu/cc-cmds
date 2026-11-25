#!/usr/bin/env bash
# Test the decision helper — plugins/cc-cmds/hooks/session-permission-decide.sh.
#
# WHAT THIS SUITE DRIVES. The permission seat (`session-permission-notify.sh`)
# runs with `CC_CMDS_NOTIFY_PERMISSION_SYNC=1` and leaves real events and real
# seat markers; the suite places a sender file and decision envelopes in the
# spool and calls the helper's `wait`, `commit`, `note` and `key` the way the
# remote-reply mod does — a subcommand and one JSON input on stdin.
#
# EVERYTHING IS CONFINED TO ONE WORK DIRECTORY: HOME (host id, sender file),
# TMPDIR (the seat state), XDG_STATE_HOME (target cell claims) and
# CC_CMDS_ATTENTION_ROOT (the spool). The pipeline markers are unset for every
# run: inside an unattended stage `cc_caller_is_router` is false, and every
# negative assertion below would then pass for the wrong reason.
#
# THE POSITIVE CONTROL COMES FIRST: an allow envelope that applies. A suite that
# only measures refusals is green against a helper that writes nothing at all.

set -uo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
# shellcheck source=wait-fixture.sh
. "$repo_root/scripts/wait-fixture.sh"
PLUGIN_ROOT="$repo_root/plugins/cc-cmds"
SEAT="$PLUGIN_ROOT/hooks/session-permission-notify.sh"
DP="$PLUGIN_ROOT/hooks/session-permission-decide.sh"
SEAM="$PLUGIN_ROOT/hooks/remote-reply/seam.sh"

passed=0
failed=0
ok()   { passed=$((passed + 1)); printf 'PASS: %s\n' "$1"; }
bad()  { failed=$((failed + 1)); printf 'FAIL: %s — %s\n' "$1" "${2:-}" >&2; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got '$2', want '$3'"; fi; }
finish() {
  printf 'test-session-permission-decide: %s passed, %s failed\n' "$passed" "$failed"
  [ "$failed" -eq 0 ]
  exit $?
}

for f in "$SEAT" "$DP" "$SEAM"; do
  if [ ! -f "$f" ]; then
    bad "스크립트" "$f 가 없다"
    finish
  fi
done

JQ=$(command -v jq 2>/dev/null || true)
if [ -z "$JQ" ]; then
  echo "SKIP: jq not installed — the helper parses JSON and nothing can be driven without it"
  echo "test-session-permission-decide: 0 passed, 0 failed"
  exit 0
fi
if command -v shasum >/dev/null 2>&1; then
  SHA() { shasum -a 256; }
else
  SHA() { sha256sum; }
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/cc-perm-decide.XXXXXX")
BG_PIDS=""
cleanup() {
  local p
  for p in $BG_PIDS; do kill "$p" 2>/dev/null; done
  rm -rf "$WORK"
}
trap cleanup EXIT

BIN="$WORK/bin"
mkdir -p "$BIN"
cat > "$BIN/terminal-notifier" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$BIN/terminal-notifier"
ln -s "$JQ" "$BIN/jq"
PATH_FULL="$BIN:/usr/bin:/bin"

T="$WORK/tmp"
T2="$WORK/tmp-other"
SPOOL="$WORK/spool"
STATE="$WORK/state"
HOMEDIR="$WORK/home"
BASE="$T/cc-cmds-permission"
mkdir -p "$T" "$T2" "$SPOOL" "$STATE/cc-cmds/session-title-now" "$HOMEDIR/.config/cc-cmds"
printf 'host-a1\n' > "$HOMEDIR/.config/cc-cmds/host-id"
SENDERS="$HOMEDIR/.config/cc-cmds/remote-senders.json"
SENDERS_OK='{"schema":1,"senders":[{"id":"app:dev-7f3a","capabilities":["option","permission-decision"]},{"id":"app:opt","capabilities":["option"]},{"id":"tg:4242","capabilities":["option"]}]}'
printf '%s\n' "$SENDERS_OK" > "$SENDERS"
CLAIMS="$STATE/cc-cmds/remote-reply/target"

P="$WORK/payload.json"
DIN="$WORK/decide-in.json"
OUT="$WORK/out"
ERR="$WORK/err"

now_ms() { /usr/bin/perl -MTime::HiRes=time -e 'printf "%d\n", time() * 1000'; }

ON="CC_CMDS_REMOTE_PERMISSION_DECISION=1 CLAUDE_CODE_ENTRYPOINT=cli"

# Every run of the seat, the helper and the seam is checked for exit 0 and an
# empty standard error; the failures are collected and reported once.
noisy=""
# The environment of every run, as `env` arguments: a background run started
# with `env "${ENV_ARGS[@]}" … &` is the helper itself, not a shell around it.
ENV_ARGS=(
  -u CC_PIPELINE_SEGMENT -u CC_PIPELINE_STAGE_ID -u CC_PIPELINE_SHIFT_ID
  -u CC_PIPELINE_REENTRY -u CC_PIPELINE_RUN_ID -u RUN_ID -u RUN_DIR
  -u CC_CMDS_SESSION_NOTIFY -u CC_CMDS_AUTOPILOT_NOTIFY -u TMUX -u TMUX_PANE
  -u CC_CMDS_REMOTE_PERMISSION_DECISION -u CLAUDE_CODE_ENTRYPOINT
  -u CC_CMDS_DECIDE_NO_MARKER_MS
  PATH="$PATH_FULL"
  HOME="$HOMEDIR"
  TMPDIR="$T"
  XDG_STATE_HOME="$STATE"
  CC_CMDS_ATTENTION_ROOT="$SPOOL"
  CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
  CC_CMDS_NOTIFY_PATH_DISABLE_PREPEND=1
  CC_CMDS_NOTIFY_PERMISSION_SYNC=1
)
run_env() { env "${ENV_ARGS[@]}" "$@"; }
note_noise() {
  local label="$1" rc="$2"
  if [ "$rc" -ne 0 ] || [ -s "$ERR" ]; then
    noisy="$noisy [$label rc=$rc err=$(head -c 200 "$ERR")]"
  fi
}
seat() { # seat <role> [env...]
  local role="$1"; shift
  : > "$ERR"
  run_env $ON "$@" bash "$SEAT" "$role" < "$P" > /dev/null 2> "$ERR"
  note_noise "seat $role" $?
}
dp() { # dp <subcommand> [args...] — stdin $DIN, stdout $OUT
  : > "$ERR"; : > "$OUT"
  run_env $DP_ENV bash "$DP" "$@" < "$DIN" > "$OUT" 2> "$ERR"
  note_noise "dp $1" $?
}
DP_ENV=""
seam() { # seam <subcommand> [args...] <stdin file>
  local in="${*: -1}" n=$(($# - 1))
  : > "$ERR"; : > "$OUT"
  run_env bash "$SEAM" "${@:1:$n}" < "$in" > "$OUT" 2> "$ERR"
  note_noise "seam $1" $?
}

perm() { # perm <sid> <tool> <tool_input json> [extra jq object]
  local x="${4:-}"
  [ -n "$x" ] || x='{}'
  jq -cn --arg s "$1" --arg t "$2" --argjson i "$3" --argjson x "$x" \
    '{session_id: $s, hook_event_name: "PermissionRequest", tool_name: $t, tool_input: $i, permission_mode: "default"} + $x' > "$P"
}
post() { # post <sid> <event> <tool> <tool_input json>
  jq -cn --arg s "$1" --arg e "$2" --arg t "$3" --argjson i "$4" \
    '{session_id: $s, hook_event_name: $e, tool_name: $t, tool_input: $i, tool_response: {ok: true}}' > "$P"
}
plain() { # plain <sid> <event> [extra]
  local x="${3:-}"
  [ -n "$x" ] || x='{}'
  jq -cn --arg s "$1" --arg e "$2" --argjson x "$x" '{session_id: $s, hook_event_name: $e} + $x' > "$P"
}
din() { # din <sid> <tool> <tool_input json> [tmpdir] — the mod's helper input
  jq -cn --arg s "$1" --arg t "$2" --argjson i "$3" --arg d "${4:-$T}" \
    '{session_id: $s, tool_name: $t, tool_input: $i, rejected: [], tmpdir: $d}' > "$DIN"
}

fp_of() { jq -cS '{tool_name, tool_input}' "$1" | SHA | cut -c1-16; }

events_json() { if [ -d "$SPOOL/events" ]; then find "$SPOOL/events" -name '*.json' -type f -exec cat {} + | jq -s -c 'sort_by(.created_at_ms, .id)'; else echo '[]'; fi; }
latest_of() { events_json | jq -r --arg s "$1" '[.[] | select(.slot == $s)] | last | .id // empty'; }
count() { find "$1" -name "$2" -type f 2>/dev/null | wc -l | tr -d ' '; }
n_applied() { count "$SPOOL/applied" '*.json'; }
n_handled() { count "$SPOOL/handled" '*.json'; }
n_picked()  { count "$SPOOL/inbox" '*.picked'; }
n_claims()  { count "$CLAIMS" '*'; }
spool_sig() { printf '%s/%s/%s/%s' "$(n_applied)" "$(n_handled)" "$(n_picked)" "$(n_claims)"; }
handled_causes() { if [ -d "$SPOOL/handled" ]; then find "$SPOOL/handled" -name '*.json' -type f -exec cat {} + | jq -r --arg s "$1" 'select(.slot == $s) | .cause'; fi; }

RN=0
# next_rid — set RID to a fresh reply id. It sets a variable rather than
# printing, so the counter is not lost in a command substitution's subshell.
RID=""
next_rid() { RN=$((RN + 1)); RID=$(printf 'host-a1.%s.%08x' "$((1793500000000 + RN))" "$RN"); }

# mkenv <sid> <rid> <event id> <decision> <sender> [jq filter] — a decision
# envelope whose target is the event's reply, in the session address.
mkenv() {
  local sid="$1" rid="$2" ev="$3" dec="$4" sender="$5" f="${6:-.}" reply='{}' now
  if [ -f "$SPOOL/events/$ev.json" ]; then reply=$(jq -c '.reply' "$SPOOL/events/$ev.json"); fi
  now=$(now_ms)
  mkdir -p "$SPOOL/inbox/s-$sid"
  jq -n --arg rid "$rid" --arg ev "$ev" --arg d "$dec" --arg se "$sender" \
    --argjson t "$reply" --argjson now "$now" \
    '{schema: 1, reply_id: $rid, event_id: $ev, host: "host-a1", kind: "permission-decision",
      target: $t, decision: $d,
      provenance: {transport: "app", sender: $se, received_at_ms: $now, transport_ref: "test"},
      expires_at_ms: ($now + 600000)}' | jq "$f" > "$SPOOL/inbox/s-$sid/$rid.json"
}
dlog() { cat "$BASE/$1/decide.log" 2>/dev/null; }
has_reason() { if dlog "$1" | grep -q " $2\$"; then echo yes; else echo no; fi; }

IN='{"command":"make check","description":"run the checks"}'

# ---------------------------------------------------------------------------
# 1. The positive control: an allow envelope from a permission sender applies.
# ---------------------------------------------------------------------------
S=sess-allow
perm "$S" Bash "$IN"
FP=$(fp_of "$P")
seat request
SLOT="cc-cmds-permission-$S@$FP"
EV=$(latest_of "$SLOT")
check "사건이 생기고 결정 봉투를 받는다" "$(jq -c '.accepts' "$SPOOL/events/$EV.json" 2>/dev/null)" '["permission-decision"]'
din "$S" Bash "$IN"
dp key
check "도우미 지문이 좌석 훅 지문과 같다" "$(cut -d' ' -f1 < "$OUT")" "$FP"
check "도우미가 좌석 표지를 찾는다" "$(cut -d' ' -f4 < "$OUT")" "$FP"
check "도우미 상태 디렉터리" "$(cut -d' ' -f3 < "$OUT")" "$BASE/$S"
next_rid; R1=$RID
mkenv "$S" "$R1" "$EV" allow app:dev-7f3a
dp wait
check "wait 가 후보를 찍는다" "$(cat "$OUT")" "s-$S $R1"
dp commit "s-$S" "$R1"
check "허용 확정 출력" "$(cat "$OUT")" '{"behavior":"allow","sender":"app:dev-7f3a"}'
check "적용 기록 하나" "$(n_applied)" "1"
check "적용 기록의 대상 칸은 사건 id" "$(jq -r '.tool_use_id' "$SPOOL/applied/$R1.json")" "$EV"
check "적용 기록의 사건 id" "$(jq -r '.event_id' "$SPOOL/applied/$R1.json")" "$EV"
check "답 해시는 결정 문자열 바이트" "$(jq -r '.answers_sha256' "$SPOOL/applied/$R1.json")" "$(printf 'allow' | SHA | cut -d' ' -f1)"
check "적용 기록 키 순서" "$(jq -c 'keys_unsorted' "$SPOOL/applied/$R1.json")" \
  '["schema","tool_use_id","session_id","reply_id","event_id","answers_sha256","transport","sender","applied_at_ms"]'
check "reply-applied 처리 표지 하나" "$(handled_causes "$SLOT")" "reply-applied"
check "수령 표지는 이 세션의 것" "$(jq -r '.session_id' "$SPOOL/inbox/s-$S/$R1.picked")" "$S"
check "대상 칸 파일 하나에 reply_id" "$(cat "$CLAIMS"/* 2>/dev/null)" "$R1"
check "허용 뒤 좌석 표지는 남는다" "$([ -e "$BASE/$S/open.$FP" ] && echo yes || echo no)" "yes"
SIG=$(spool_sig)

# The same envelope again, and a second envelope on the same event.
dp commit "s-$S" "$R1"
check "같은 봉투로 다시 확정 — 출력 없음" "$(cat "$OUT")" ""
check "같은 봉투로 다시 확정 — 스풀 그대로" "$(spool_sig)" "$SIG"
next_rid; R2=$RID
mkenv "$S" "$R2" "$EV" deny app:dev-7f3a
dp commit "s-$S" "$R2"
check "같은 사건의 둘째 봉투 — 출력 없음" "$(cat "$OUT")" ""
check "같은 사건의 둘째 봉투 — 스풀 그대로" "$(spool_sig)" "$SIG"
check "같은 사건의 둘째 봉투 — 처리됨 사유" "$(has_reason "$S" 사건처리됨)" "yes"
dp wait
check "처리된 사건에서 wait 는 출력 없이 끝난다" "$(cat "$OUT")" ""

# The seam never accepts a decision envelope.
next_rid; R3=$RID
S3=sess-seam
perm "$S3" Bash "$IN"
seat request
EV3=$(latest_of "cc-cmds-permission-$S3@$FP")
mkenv "$S3" "$R3" "$EV3" allow app:dev-7f3a
jq -cn --arg s "$S3" --arg t "$EV3" '{session_id: $s, tool_use_id: $t, questions: [{question: "q", options: [{label: "a"}]}]}' > "$WORK/seam-in.json"
SIG=$(spool_sig)
seam commit "s-$S3" "$R3" "$WORK/seam-in.json"
check "이음매는 결정 봉투를 수락하지 않는다 — 출력 없음" "$(cat "$OUT")" ""
check "이음매는 결정 봉투를 수락하지 않는다 — 스풀 그대로" "$(spool_sig)" "$SIG"

# After the envelope leaves the inbox, the seam's cleanup removes the helper's files.
rm -f "$SPOOL/inbox/s-$S/$R1.json" "$SPOOL/inbox/s-$S/$R2.json"
jq -cn --arg s "$S" '{session_id: $s}' > "$WORK/clean-in.json"
seam cleanup "$WORK/clean-in.json"
check "정리 — 수령 표지 없음" "$([ -e "$SPOOL/inbox/s-$S/$R1.picked" ] && echo yes || echo no)" "no"
check "정리 — 적용 기록 없음" "$([ -e "$SPOOL/applied/$R1.json" ] && echo yes || echo no)" "no"
check "정리 — 대상 칸 파일 없음" "$(n_claims)" "0"

# ---------------------------------------------------------------------------
# 2. A deny envelope applies and takes the call's seat markers away.
# ---------------------------------------------------------------------------
S=sess-deny
perm "$S" Write '{"file_path":"/tmp/x","content":"y"}'
FPD=$(fp_of "$P")
seat request
EVD=$(latest_of "cc-cmds-permission-$S@$FPD")
din "$S" Write '{"file_path":"/tmp/x","content":"y"}'
next_rid; RD=$RID
mkenv "$S" "$RD" "$EVD" deny app:dev-7f3a
A0=$(n_applied); H0=$(n_handled)
dp commit "s-$S" "$RD"
check "거부 확정 출력" "$(cat "$OUT")" '{"behavior":"deny","sender":"app:dev-7f3a"}'
check "거부 — 적용 기록 하나" "$(( $(n_applied) - A0 ))" "1"
check "거부 — 처리 표지 하나" "$(( $(n_handled) - H0 ))" "1"
check "거부 — 답 해시" "$(jq -r '.answers_sha256' "$SPOOL/applied/$RD.json")" "$(printf 'deny' | SHA | cut -d' ' -f1)"
check "거부 뒤 pending·open 없음" \
  "$([ -e "$BASE/$S/open.$FPD" ] || [ -e "$BASE/$S/pending.$FPD" ] && echo yes || echo no)" "no"

# ---------------------------------------------------------------------------
# 3. Refusals: each writes nothing and leaves one diagnostic line.
# ---------------------------------------------------------------------------
refuse() { # refuse <label> <sid> <rid> <reason> — commit and expect nothing
  local label="$1" sid="$2" rid="$3" reason="$4" sig
  sig=$(spool_sig)
  : > "$BASE/$sid/decide.log"
  dp commit "s-$sid" "$rid"
  check "$label — 출력 없음" "$(cat "$OUT")" ""
  check "$label — 스풀 그대로" "$(spool_sig)" "$sig"
  check "$label — 사유 $reason" "$(has_reason "$sid" "$reason")" "yes"
}
S=sess-ref
perm "$S" Bash "$IN"
seat request
SLOTR="cc-cmds-permission-$S@$FP"
EVR=$(latest_of "$SLOTR")
din "$S" Bash "$IN"
next_rid; r=$RID; mkenv "$S" "$r" "$EVR" allow app:opt;   refuse "선택지만 가진 발신자" "$S" "$r" 발신자불허
next_rid; r=$RID; mkenv "$S" "$r" "$EVR" allow tg:4242;   refuse "선택지만 가진 tg 발신자" "$S" "$r" 발신자불허
next_rid; r=$RID; mkenv "$S" "$r" "$EVR" allow app:nobody; refuse "등록되지 않은 발신자" "$S" "$r" 발신자불허
next_rid; r=$RID; mkenv "$S" "$r" "$EVR" allow app:dev-7f3a '.expires_at_ms = 1'; refuse "만료된 봉투" "$S" "$r" 만료
next_rid; r=$RID; mkenv "$S" "$r" "$EVR" allow app:dev-7f3a '. + {text: "x"}'; refuse "키가 더 있는 봉투" "$S" "$r" 꼴위반
next_rid; r=$RID; mkenv "$S" "$r" "$EVR" maybe app:dev-7f3a; refuse "decision 값이 다른 봉투" "$S" "$r" 꼴위반
next_rid; r=$RID; mkenv "$S" "$r" "$EVR" allow app:dev-7f3a '.host = "host-b2"'; refuse "다른 호스트 봉투" "$S" "$r" 호스트불일치
next_rid; r=$RID; mkenv "$S" "$r" "$EVR" allow app:dev-7f3a '.target.tool_name = "Write"'; refuse "대상이 사건 답 대상과 다름" "$S" "$r" 대상불일치
next_rid; r=$RID; mkenv "$S" "$r" "$EVR" allow app:dev-7f3a '.event_id = "../events/x.1.00000000"'; refuse "event_id 에 ../" "$S" "$r" 꼴위반
r="Bad.1.00000000"; mkenv "$S" "$r" "$EVR" allow app:dev-7f3a; refuse "reply_id 가 문법 밖" "$S" "$r" 꼴위반
next_rid
dp commit "s-other" "$RID"
check "주소가 이 세션이 아님 — 출력 없음" "$(cat "$OUT")" ""

# Another call's event (a different fingerprint) in the same session.
perm "$S" Bash '{"command":"make lint"}'
seat request
EVO=$(latest_of "cc-cmds-permission-$S@$(fp_of "$P")")
next_rid; r=$RID; mkenv "$S" "$r" "$EVO" allow app:dev-7f3a; refuse "다른 호출의 사건" "$S" "$r" 슬롯불일치

# An event that does not accept a decision: the switch was off, and the fallback signal.
perm "$S" Bash '{"command":"make off"}'
: > "$ERR"
run_env bash "$SEAT" request < "$P" > /dev/null 2> "$ERR"; note_noise "seat request off" $?
EVF=$(latest_of "cc-cmds-permission-$S@$(fp_of "$P")")
check "스위치 꺼짐 — actionable 거짓" "$(jq -r '.actionable' "$SPOOL/events/$EVF.json")" "false"
check "스위치 꺼짐 — accepts 비어 있음" "$(jq -c '.accepts' "$SPOOL/events/$EVF.json")" "[]"
din "$S" Bash '{"command":"make off"}'
next_rid; r=$RID; mkenv "$S" "$r" "$EVF" allow app:dev-7f3a; refuse "accepts 가 빈 사건" "$S" "$r" 꼴위반
plain "$S" Notification '{"notification_type":"permission_prompt","message":"m"}'
rm -f "$BASE/$S/seen"
seat notification
EVN=$(latest_of "cc-cmds-permission-$S@notification")
check "보조 신호 사건이 생긴다" "$([ -n "$EVN" ] && echo yes || echo no)" "yes"
din "$S" Bash "$IN"
next_rid; r=$RID; mkenv "$S" "$r" "$EVN" allow app:dev-7f3a; refuse "보조 신호 사건" "$S" "$r" 꼴위반

# A sender file without schema.
next_rid; r=$RID; mkenv "$S" "$r" "$EVR" allow app:dev-7f3a
printf '%s\n' "$SENDERS_OK" | jq -c 'del(.schema)' > "$SENDERS"
refuse "schema 없는 발신자 파일" "$S" "$r" 발신자불허
printf '%s\n' "$SENDERS_OK" > "$SENDERS"

# The diagnostic lines carry neither the envelope nor the command.
check "진단 기록 꼴" "$(dlog "$S" | grep -cvE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z [^ ]+ [^ ]+$')" "0"
check "진단 기록에 명령·발신자 없음" "$(cat "$BASE"/*/decide.log | grep -cE 'make|app:|tg:|\{')" "0"

# ---------------------------------------------------------------------------
# 4. A marker that went away: the local answer won.
# ---------------------------------------------------------------------------
S=sess-gone
perm "$S" Bash "$IN"
seat request
EVG=$(latest_of "cc-cmds-permission-$S@$FP")
din "$S" Bash "$IN"
: > "$WORK/bg.out"
# A `sleep` in front of the PATH marks the end of the helper's first check, so
# the marker is taken away only after `wait` has seen it.
BIN_SLEEP="$WORK/bin-sleep"
mkdir -p "$BIN_SLEEP"
cat > "$BIN_SLEEP/sleep" <<STUB
#!/usr/bin/env bash
: > "$WORK/slept"
exec /bin/sleep "\$@"
STUB
chmod +x "$BIN_SLEEP/sleep"
rm -f "$WORK/slept"
env "${ENV_ARGS[@]}" PATH="$BIN_SLEEP:$PATH_FULL" bash "$DP" wait < "$DIN" > "$WORK/bg.out" 2>&1 &
BGP=$!; BG_PIDS="$BG_PIDS $BGP"
wait_until test -e "$WORK/slept"
post "$S" PostToolUse Bash "$IN"
seat settle
wait_pid_gone "$BGP"
check "표지가 사라지면 wait 가 출력 없이 끝난다" "$(cat "$WORK/bg.out")" ""
# The settle role removes the marker and then writes the handled marker, so a
# check that falls between the two ends on the handled event instead.
got=$(dlog "$S" | cut -d' ' -f3 | tr '\n' ' ')
case "$got" in
  "표지사라짐 "|"사건처리됨 ") ok "표지사라짐 또는 처리됨 사유" ;;
  *) bad "표지사라짐 또는 처리됨 사유" "got '$got'" ;;
esac
next_rid; r=$RID; mkenv "$S" "$r" "$EVG" allow app:dev-7f3a
SIG=$(spool_sig)
dp commit "s-$S" "$r"
check "로컬 답 뒤 봉투 — 출력 없음" "$(cat "$OUT")" ""
check "로컬 답 뒤 봉투 — 스풀 그대로" "$(spool_sig)" "$SIG"

# The helper reads the seat's permission-settled marker as handled.
check "좌석 훅의 permission-settled 표지" "$(handled_causes "cc-cmds-permission-$S@$FP")" "permission-settled"
printf '%s x\n' "$FP" > "$BASE/$S/open.$FP"
dp key
printf '%s %s\n' "$FP" "$(cut -d' ' -f2 < "$OUT")" > "$BASE/$S/open.$FP"
: > "$BASE/$S/decide.log"
dp wait
check "permission-settled 뒤 wait 는 출력 없이 끝난다" "$(cat "$OUT")" ""
check "permission-settled 을 처리됨으로 읽는다" "$(has_reason "$S" 사건처리됨)" "yes"
rm -f "$BASE/$S/open.$FP"

# A marker that never showed.
din sess-never Bash "$IN"
mkdir -p "$BASE/sess-never"
DP_ENV="CC_CMDS_DECIDE_NO_MARKER_MS=500"
dp wait
DP_ENV=""
check "표지가 끝내 없으면 출력 없이 끝난다" "$(cat "$OUT")" ""
check "표지없음 사유" "$(has_reason sess-never 표지없음-30초)" "yes"

# ---------------------------------------------------------------------------
# 5. The parent of `wait` goes away.
# ---------------------------------------------------------------------------
S=sess-orphan
perm "$S" Bash "$IN"
seat request
din "$S" Bash "$IN"
( env "${ENV_ARGS[@]}" bash "$DP" wait < "$DIN" > "$WORK/orph.out" 2>&1 & printf '%s\n' "$!" > "$WORK/orph.pid" )
OP=$(cat "$WORK/orph.pid")
BG_PIDS="$BG_PIDS $OP"
wait_pid_gone "$OP"
check "부모가 사라지면 wait 가 출력 없이 끝난다" "$(cat "$WORK/orph.out")" ""
check "부모소멸 사유" "$(has_reason "$S" 부모소멸)" "yes"

# ---------------------------------------------------------------------------
# 6. Subagents and pipeline markers.
# ---------------------------------------------------------------------------
S=sess-agent
perm "$S" Bash "$IN"
seat request
EVA1=$(latest_of "cc-cmds-permission-$S@$FP")
plain "$S" SubagentStart '{"agent_id":"sub1","agent_type":"general-purpose"}'
seat agent-start
perm "$S" Bash '{"command":"make during"}'
FPA2=$(fp_of "$P")
seat request
EVA2=$(latest_of "cc-cmds-permission-$S@$FPA2")
check "표지 동안 오른 사건 — actionable 거짓" "$(jq -r '.actionable' "$SPOOL/events/$EVA2.json")" "false"
check "표지 동안 오른 사건 — accepts 비어 있음" "$(jq -c '.accepts' "$SPOOL/events/$EVA2.json")" "[]"
check "표지 동안 오른 사건 — 답 대상 그대로" "$(jq -r '.reply.tool_name' "$SPOOL/events/$EVA2.json")" "Bash"
din "$S" Bash "$IN"
next_rid; RA1=$RID; mkenv "$S" "$RA1" "$EVA1" allow app:dev-7f3a
dp wait
check "agent 표지가 있으면 wait 가 출력 없이 끝난다" "$(cat "$OUT")" ""
check "근거없음 사유" "$(has_reason "$S" 근거없음-agent표지)" "yes"
refuse "agent 표지가 있는 동안의 확정" "$S" "$RA1" 근거없음-agent표지
plain "$S" SubagentStop '{"agent_id":"sub1","agent_type":"general-purpose"}'
seat agent-stop
dp commit "s-$S" "$RA1"
check "표지가 지워진 뒤 앞선 사건의 봉투는 적용된다" "$(jq -r '.behavior' "$OUT" 2>/dev/null)" "allow"
din "$S" Bash '{"command":"make during"}'
next_rid; r=$RID; mkenv "$S" "$r" "$EVA2" allow app:dev-7f3a
refuse "표지 동안 오른 사건의 봉투" "$S" "$r" 꼴위반

S=sess-subcall
perm "$S" Bash "$IN" '{"agent_id":"sub2","agent_type":"general-purpose"}'
seat request
check "agent_id 가 있는 입력 — 사건 없음" "$(latest_of "cc-cmds-permission-$S@$FP")" ""
check "agent_id 가 있는 입력 — 좌석 표지 없음" "$(ls "$BASE/$S" 2>/dev/null | grep -c -E '^(pending|open)\.')" "0"

S=sess-pipe
perm "$S" Bash "$IN"
seat request
EVP=$(latest_of "cc-cmds-permission-$S@$FP")
din "$S" Bash "$IN"
next_rid; r=$RID; mkenv "$S" "$r" "$EVP" allow app:dev-7f3a
SIG=$(spool_sig)
: > "$OUT"
run_env CC_PIPELINE_STAGE_ID=A#1 bash "$DP" commit "s-$S" "$r" < "$DIN" > "$OUT" 2> "$ERR"
check "파이프라인 표지가 있으면 결정이 없다 — 출력 없음" "$(cat "$OUT")" ""
check "파이프라인 표지가 있으면 결정이 없다 — 스풀 그대로" "$(spool_sig)" "$SIG"
run_env CC_PIPELINE_SEGMENT=A bash "$DP" wait < "$DIN" > "$OUT" 2> "$ERR"
check "파이프라인 표지가 있으면 wait 가 출력 없이 끝난다" "$(cat "$OUT")" ""
perm sess-pipe2 Bash "$IN"
: > "$ERR"
run_env $ON CC_PIPELINE_STAGE_ID=A#1 bash "$SEAT" request < "$P" > /dev/null 2> "$ERR"
check "파이프라인 표지가 있으면 사건이 없다" "$(latest_of "cc-cmds-permission-sess-pipe2@$FP")" ""

# ---------------------------------------------------------------------------
# 7. The same slot from re-serialized input and another TMPDIR.
# ---------------------------------------------------------------------------
S=sess-norm
printf '%s\n' '{"session_id":"sess-norm","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"café","timeout":1.0,"big":12345678901234567890},"permission_mode":"default"}' > "$P"
FPN=$(fp_of "$P")
seat request
EVNM=$(latest_of "cc-cmds-permission-$S@$FPN")
printf '%s\n' "{\"session_id\":\"sess-norm\",\"tool_name\":\"Bash\",\"tool_input\":{\"big\":1.2345678901234567e19,\"timeout\":1,\"command\":\"café\"},\"rejected\":[],\"tmpdir\":\"$T/\"}" > "$DIN"
: > "$ERR"; : > "$OUT"
run_env TMPDIR="$T2" bash "$DP" key < "$DIN" > "$OUT" 2> "$ERR"
check "다시 직렬화된 입력과 다른 TMPDIR — 같은 좌석 표지" "$(cut -d' ' -f4 < "$OUT")" "$FPN"
check "다른 TMPDIR — 입력의 tmpdir 를 따른다" "$(cut -d' ' -f3 < "$OUT")" "$BASE/$S"
next_rid; r=$RID; mkenv "$S" "$r" "$EVNM" allow app:dev-7f3a
run_env TMPDIR="$T2" bash "$DP" commit "s-$S" "$r" < "$DIN" > "$OUT" 2> "$ERR"
check "다시 직렬화된 입력의 확정이 적용된다" "$(jq -r '.behavior' "$OUT" 2>/dev/null)" "allow"

# ---------------------------------------------------------------------------
# 8. Two calls with the same input share one slot; one decision applies once.
# ---------------------------------------------------------------------------
S=sess-twin
perm "$S" Bash "$IN"
seat request
seat request
EVT=$(latest_of "cc-cmds-permission-$S@$FP")
din "$S" Bash "$IN"
next_rid; r=$RID; mkenv "$S" "$r" "$EVT" allow app:dev-7f3a
dp commit "s-$S" "$r"
check "쌍둥이 호출 — 첫 확정이 적용된다" "$(jq -r '.behavior' "$OUT" 2>/dev/null)" "allow"
SIG=$(spool_sig)
dp commit "s-$S" "$r"
check "쌍둥이 호출 — 다른 호출의 확정은 출력 없음" "$(cat "$OUT")" ""
check "쌍둥이 호출 — 다른 호출의 확정은 스풀 그대로" "$(spool_sig)" "$SIG"

# ---------------------------------------------------------------------------
# 9. A local deny, then the same input again: only the new event applies.
# ---------------------------------------------------------------------------
S=sess-again
perm "$S" Bash "$IN"
seat request
EVX1=$(latest_of "cc-cmds-permission-$S@$FP")
post "$S" PermissionDenied Bash "$IN"
seat settle
perm "$S" Bash "$IN"
seat request
EVX2=$(latest_of "cc-cmds-permission-$S@$FP")
check "다시 부른 호출은 새 사건" "$([ -n "$EVX2" ] && [ "$EVX2" != "$EVX1" ] && echo yes || echo no)" "yes"
din "$S" Bash "$IN"
next_rid; r=$RID; mkenv "$S" "$r" "$EVX1" allow app:dev-7f3a
refuse "앞선 사건을 가리키는 봉투" "$S" "$r" 늦은사건
next_rid; r=$RID; mkenv "$S" "$r" "$EVX2" deny app:dev-7f3a
dp commit "s-$S" "$r"
check "새 사건을 가리키는 봉투가 적용된다" "$(jq -r '.behavior' "$OUT" 2>/dev/null)" "deny"

# ---------------------------------------------------------------------------
# 10. The note subcommand, and its guard on reasons and event ids.
# ---------------------------------------------------------------------------
S=sess-note
mkdir -p "$BASE/$S"
din "$S" Bash "$IN"
dp note 로컬먼저 "host-a1.1.0000000a"
dp note 아무사유
dp note 중단신호 "../x"
check "note 는 아는 사유만 한 줄씩" "$(dlog "$S" | cut -d' ' -f2-)" "host-a1.1.0000000a 로컬먼저
- 중단신호"

# ---------------------------------------------------------------------------
# 11. The cost of one check: the scan of every event and every handled marker.
#     Reported, not judged — the number goes to the change's description.
# ---------------------------------------------------------------------------
S=sess-cost
perm "$S" Bash "$IN"
seat request
EVC=$(latest_of "cc-cmds-permission-$S@$FP")
TPL="$SPOOL/events/$EVC.json"
i=0
while [ "$i" -lt 60 ]; do
  i=$((i + 1))
  id=$(printf 'host-a1.%s.%08x' "$((1793600000000 + i))" "$i")
  jq -c --arg id "$id" --arg s "cc-cmds-permission-other-$i@0000000000000000" '.id = $id | .slot = $s' "$TPL" > "$SPOOL/events/$id.json"
  printf '{"schema":1,"id":"host-a1.%s.%08x","slot":"cc-cmds-permission-other-%s@","prefix":true,"cause":"return","at_ms":%s}\n' \
    "$((1793700000000 + i))" "$i" "$i" "$((1793700000000 + i))" > "$SPOOL/handled/host-a1.$((1793700000000 + i)).$(printf '%08x' "$i").json"
done
# The cost slot's own event is closed by a marker written last, so the check
# reads every event and every marker before it ends; `key` alone reads the
# input and the seat markers, and the difference is the scan.
printf '{"schema":1,"id":"host-a1.1793800000000.0000ffff","slot":"cc-cmds-permission-%s@%s","prefix":false,"cause":"clear","at_ms":9999999999999}\n' \
  "$S" "$FP" > "$SPOOL/handled/host-a1.1793800000000.0000ffff.json"
ne=$(count "$SPOOL/events" '*.json'); nh=$(n_handled)
din "$S" Bash "$IN"
rm -f "$BASE/$S/decide.log"
t0=$(now_ms); dp key; t1=$(now_ms)
tk=$((t1 - t0))
t0=$(now_ms); dp wait; t1=$(now_ms)
tw=$((t1 - t0))
check "훑기 비용 측정의 점검이 처리됨으로 끝난다" "$(has_reason "$S" 사건처리됨)" "yes"
printf 'INFO: 1초 점검 한 번 %s ms(입력 판독만 %s ms, 훑기 약 %s ms) — 사건 %s개, 처리 표지 %s개\n' \
  "$tw" "$tk" "$((tw - tk))" "$ne" "$nh"

# ---------------------------------------------------------------------------
# 12. The seam's own bytes: the copied rules are the seam's functions verbatim.
# ---------------------------------------------------------------------------
fn_body() { awk -v n="$2() {" '$0 == n { on = 1 } on { print } on && $0 == "}" { exit }' "$1"; }
for fn in seam_is_rid seam_sha256 seam_mkdir seam_create seam_handled_state seam_pick seam_record; do
  a=$(fn_body "$SEAM" "$fn")
  b=$(fn_body "$DP" "$fn")
  if [ -n "$a" ] && [ "$a" = "$b" ]; then ok "이음매와 같은 바이트 — $fn"; else bad "이음매와 같은 바이트 — $fn" "본문이 다르다"; fi
done
check "발신자 인가 판독은 이음매의 조건에 능력 이름만 다르다" \
  "$(grep -c 'select(.schema == 1 and (.senders | type) == "array")' "$SEAM" "$DP" | cut -d: -f2 | tr '\n' ' ')" "1 1 "

check "모든 실행이 rc 0 이고 표준 오류가 비어 있다" "$noisy" ""
finish
