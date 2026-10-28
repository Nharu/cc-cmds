#!/usr/bin/env bash
# Test the attention tap library — plugins/cc-cmds/orchestrator/attention.sh —
# and the static pins that keep the test suites off the account spool.
#
# EVERY CALL RUNS IN A STRICT CALLER. Each case writes a `/bin/bash` script that
# turns on `set -euo pipefail`, `set -E` and an ERR trap that prints to stderr,
# sources the library, records the umask, PWD, `$-` and `trap -p ERR`, makes
# its calls, compares the four values again, prints `end` and exits 3. A call
# that changed its caller shows as another exit status, another stdout or a
# non-empty stderr, so every case below also proves the library leaves the
# caller alone. On macOS `/bin/bash` is 3.2; elsewhere it is whatever the host
# ships, so the 3.2 behaviour is seen on a Mac run only.
#
# EVERY CASE GETS ITS OWN SCRATCH ROOT (`fresh`): HOME, the spool root, the
# attachments and the caller's working directory live under it, and the caller
# starts from `env -i` so nothing of this shell leaks in. Every case except the
# default-root one pins CC_CMDS_ATTENTION_ROOT inside it.
#
# File modes are read with perl — the portability lint keeps `stat -f` and
# `stat -c` out of the tree.

set -uo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
LIB="$repo_root/plugins/cc-cmds/orchestrator/attention.sh"
LINT="$script_dir/lint-attention-schema.sh"
DOC="$repo_root/plugins/cc-cmds/skills/_common/attention-event.md"
FIXTURES="$repo_root/tests/fixtures/attention"

passed=0
failed=0
ok()   { passed=$((passed + 1)); printf 'PASS: %s\n' "$1"; }
bad()  { failed=$((failed + 1)); printf 'FAIL: %s — %s\n' "$1" "${2:-}" >&2; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got '$2', want '$3'"; fi; }

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not installed — the library writes nothing without it and the records cannot be read"
  echo "test-attention: 0 passed, 0 failed"
  exit 0
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/cc-attention.XXXXXX")
trap 'chmod -R u+rwx "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

# Tool directories. The base PATH is the host's with jq in front; the two
# narrowed ones hold links to the tools the library runs, one without jq and
# one without git.
mk_tools() {
  local d="$1" t p
  shift
  mkdir -p "$d"
  for t in "$@"; do
    p=$(command -v "$t") || continue
    ln -s "$p" "$d/$t"
  done
}
mk_tools "$WORK/bin-full" jq
mk_tools "$WORK/bin-nogit" jq cat od tr mv rm mkdir
mk_tools "$WORK/bin-nojq" cat od tr mv rm mkdir
BASE_PATH="$WORK/bin-full:/usr/bin:/bin"
COLLECT="$WORK/collected"
mkdir -p "$COLLECT"
collected=0

q() { printf '%q' "$1"; }

# fresh — a new scratch root for one case; sets s and ROOT (not created).
fresh() {
  s=$(mktemp -d "$WORK/case.XXXXXX")
  mkdir -p "$s/home" "$s/run" "$s/att" "$s/cwd"
  ROOT="$s/root"
}
fresh_root() { fresh; mkdir -m 700 "$ROOT"; }

# run_lib <code> [<VAR=value>...] — run <code> in the strict caller under a
# clean environment; sets RUN_RC, output in $s/run/out and $s/run/err.
run_lib() {
  local code="$1"
  shift
  cat > "$s/run/call.sh" <<EOF
set -euo pipefail
set -E
trap 'echo ERR-trap >&2' ERR
. $(q "$LIB")
__u=\$(umask); __p=\$PWD; __f=\$-; __t=\$(trap -p ERR)
$code
if [ "\$(umask)" != "\$__u" ] || [ "\$PWD" != "\$__p" ] || [ "\$-" != "\$__f" ] || [ "\$(trap -p ERR)" != "\$__t" ]; then
  echo changed
fi
echo end
exit 3
EOF
  ( cd "$s/cwd" && env -i HOME="$s/home" PATH="$BASE_PATH" CC_CMDS_ATTENTION_ROOT="$ROOT" "$@" \
      /bin/bash "$s/run/call.sh" > "$s/run/out" 2> "$s/run/err" )
  RUN_RC=$?
}

# strict <label> — the caller ended as it would have without the calls.
strict() {
  check "$1: 호출자 종료 상태 3" "$RUN_RC" "3"
  check "$1: 표준 출력은 호출자의 줄뿐" "$(cat "$s/run/out")" "end"
  check "$1: 표준 오류 0 바이트" "$(wc -c < "$s/run/err" | tr -d ' ')" "0"
}

# nfiles <dir> — regular files under <dir>, 0 when it is absent.
nfiles() {
  if [ -d "$1" ]; then find "$1" -type f | wc -l | tr -d ' '; else echo 0; fi
}
# ndot <dir> — dot files directly in <dir>.
ndot() {
  local n=0 f
  for f in "$1"/.[!.]*; do
    [ -e "$f" ] && n=$((n + 1))
  done
  echo "$n"
}
# one_file <dir> — the path of the first .json in <dir>, or nothing.
one_file() {
  local f
  for f in "$1"/*.json; do
    if [ -f "$f" ]; then printf '%s' "$f"; return 0; fi
  done
  return 0
}
field() { jq -r "$2" "$1" 2>/dev/null; }
mode() { perl -e 'printf "%o\n", (lstat $ARGV[0])[2] & 07777' "$1"; }

# collect — copy every record of this case for the schema-lint pass.
collect() {
  local f
  for f in "$ROOT"/events/*.json "$ROOT"/handled/*.json; do
    [ -f "$f" ] || continue
    collected=$((collected + 1))
    cp "$f" "$COLLECT/r$collected.json"
  done
}

# att <json> — make an attachment file the way a seat does; print its path.
att() {
  local f
  f=$(mktemp "$s/att/cc-attention-detail.XXXXXX")
  printf '%s' "$1" > "$f"
  chmod 600 "$f"
  printf '%s' "$f"
}

RID="20261026-f33cba74"
AID="J-0000abcd"
ASLOT="cc-cmds-autopilot-$RID-$AID"
AQ="승인 $AID — 리뷰 발견을 고치지 않고 넘겨도 될까요?"
AWATCH="승인 $AID 이 답을 기다립니다"
SID="5f0c9a2e-4b1d-4e7a-9c3f-2a8d6e1b0c47"
SSLOT="cc-cmds-session-$SID"

body_only() { jq -cn --arg b "$AQ" '{kind: "approval", actionable: false, reply: null, body: $b}'; }
with_reply() {
  jq -cn --arg b "$AQ" --arg r "$RID" --arg a "$AID" \
    '{kind: "approval", actionable: true, body: $b,
      reply: {surface: "approval", run_id: $r, approval_id: $a, question: $b, options: ["승인", "거부", "무효"]}}'
}
reply_only() {
  jq -cn --arg b "$AQ" --arg r "$RID" --arg a "$AID" \
    '{kind: "approval", actionable: true,
      reply: {surface: "approval", run_id: $r, approval_id: $a, question: $b, options: ["승인", "거부", "무효"]}}'
}
auq_detail() {
  # auq_detail <actionable> <options-json>
  jq -cn --arg s "$SID" --argjson act "$1" --argjson o "$2" \
    '{kind: "auq", actionable: $act, body: "어느 쪽으로 할까요?",
      reply: {surface: "auq", session_id: $s, tool_use_id: "toolu_01", questions:
        [{question: "어느 쪽으로 할까요?", header: "방향", multi_select: false, options: $o}]}}'
}

# --------------------------------------------------------------------------
# 1. Strict caller, root absent and root present, no session/run/pane/config
#    values in the environment.
# --------------------------------------------------------------------------
case1_code="cc_attention_emit session-turn $(q "$SSLOT") 제목 본문
r=\$?; [ \"\$r\" = 0 ] || echo nonzero
cc_attention_handled $(q "$SSLOT") return
r=\$?; [ \"\$r\" = 0 ] || echo nonzero"

fresh
run_lib "$case1_code"
strict "1 루트 없음"
check "1 루트 없음: 루트를 만들지 않음" "$([ -e "$ROOT" ] && echo yes || echo no)" "no"
check "1 루트 없음: HOME 아래 파일 없음" "$(nfiles "$s/home")" "0"

fresh_root
run_lib "$case1_code"
strict "1 루트 있음"
check "1 루트 있음: 사건 하나" "$(nfiles "$ROOT/events")" "1"
check "1 루트 있음: 처리 표지 하나" "$(nfiles "$ROOT/handled")" "1"
f=$(one_file "$ROOT/events")
check "1 루트 있음: origin.session_id null" "$(field "$f" '.origin.session_id')" "null"
check "1 루트 있음: origin.run_id null" "$(field "$f" '.origin.run_id')" "null"
check "1 루트 있음: origin.tmux_pane null" "$(field "$f" '.origin.tmux_pane')" "null"
check "1 루트 있음: origin.config_dir 기본값" "$(field "$f" '.origin.config_dir')" "$s/home/.claude"
collect

# --------------------------------------------------------------------------
# 2. Broken input writes nothing and the caller stays as it was.
# --------------------------------------------------------------------------
fresh_root
run_lib "cc_attention_emit session-turn $(q "$SSLOT") t b
cc_attention_handled $(q "$SSLOT") clear" PATH="$WORK/bin-nojq"
strict "2 jq 없는 PATH"
check "2 jq 없는 PATH: 파일 없음" "$(nfiles "$ROOT")" "0"

fresh_root
a=$(att 'not json {')
run_lib "cc_attention_emit session-turn $(q "$SSLOT") t b $(q "$a")"
strict "2 JSON 이 아닌 첨부"
check "2 JSON 이 아닌 첨부: 파일 없음" "$(nfiles "$ROOT")" "0"
check "2 JSON 이 아닌 첨부: 첨부 지워짐" "$([ -e "$a" ] && echo yes || echo no)" "no"

fresh_root
a=$(att '{"kind":"turn","actionable":false,"reply":null}')
chmod 000 "$a"
run_lib "cc_attention_emit session-turn $(q "$SSLOT") t b $(q "$a")"
strict "2 읽을 수 없는 첨부"
check "2 읽을 수 없는 첨부: 파일 없음" "$(nfiles "$ROOT")" "0"

fresh_root
a=$(att '{"kind":"turn","actionable":false,"reply":null}')
link="$s/att/cc-attention-detail.link"
ln -s "$a" "$link"
run_lib "cc_attention_emit session-turn $(q "$SSLOT") t b $(q "$link")"
strict "2 심볼릭 링크 첨부"
check "2 심볼릭 링크 첨부: 파일 없음" "$(nfiles "$ROOT")" "0"
check "2 심볼릭 링크 첨부: 링크 남음" "$([ -L "$link" ] && echo yes || echo no)" "yes"
check "2 심볼릭 링크 첨부: 대상 남음" "$([ -f "$a" ] && echo yes || echo no)" "yes"

fresh_root
plain="$s/att/detail.json"
printf '%s' '{"kind":"turn","actionable":false,"reply":null}' > "$plain"
run_lib "cc_attention_emit session-turn $(q "$SSLOT") t b $(q "$plain")"
strict "2 접두가 다른 소유 파일"
check "2 접두가 다른 소유 파일: 파일 없음" "$(nfiles "$ROOT")" "0"
check "2 접두가 다른 소유 파일: 그대로 남음" "$([ -f "$plain" ] && echo yes || echo no)" "yes"

fresh_root
a=$(att '{"kind":"question-form","actionable":false,"reply":null}')
run_lib "cc_attention_emit session-turn $(q "$SSLOT") t b $(q "$a")"
strict "2 토큰이 낼 수 없는 kind"
check "2 토큰이 낼 수 없는 kind: 파일 없음" "$(nfiles "$ROOT")" "0"
check "2 토큰이 낼 수 없는 kind: 첨부 지워짐" "$([ -e "$a" ] && echo yes || echo no)" "no"

fresh_root
run_lib "cc_attention_emit bogus-token $(q "$SSLOT") t b
cc_attention_emit session-turn '' t b"
strict "2 표에 없는 토큰과 빈 slot"
check "2 표에 없는 토큰과 빈 slot: 파일 없음" "$(nfiles "$ROOT")" "0"

fresh_root
run_lib "cc_attention_handled $(q "$SSLOT") forgotten
cc_attention_handled $(q "$SSLOT") clear yes
cc_attention_handled $(q "$SSLOT") clear prefix
cc_attention_handled '' clear"
strict "2 잘못된 cause·prefix 인자"
check "2 잘못된 cause·prefix 인자: 파일 없음" "$(nfiles "$ROOT")" "0"

fresh_root
run_lib "cc_attention_emit session-turn $(q "$SSLOT") 제목 본문 ''"
mv "$(one_file "$ROOT/events")" "$s/empty-arg.json"
run_lib "cc_attention_emit session-turn $(q "$SSLOT") 제목 본문"
strict "2 빈 다섯째 인자"
check "2 빈 다섯째 인자: 네 인자 호출과 같은 사건" \
  "$(jq -cS 'del(.id, .created_at_ms)' "$s/empty-arg.json")" \
  "$(jq -cS 'del(.id, .created_at_ms)' "$(one_file "$ROOT/events")")"
collect

fresh_root
a=$(att '{"kind":"turn","actionable":false,"reply":null,"body":""}')
b=$(att '{"kind":"turn","actionable":false,"reply":null,"body":42}')
run_lib "cc_attention_emit session-turn $(q "$SSLOT") 제목 넷째인자본문 $(q "$a")
cc_attention_emit session-turn $(q "$SSLOT") 제목 넷째인자본문 $(q "$b")"
strict "2 빈 body·문자열 아닌 body"
bodies=""
for f in "$ROOT"/events/*.json; do bodies="$bodies$(field "$f" '.body')|"; done
check "2 빈 body·문자열 아닌 body: 넷째 인자가 body" "$bodies" "넷째인자본문|넷째인자본문|"
collect

# --------------------------------------------------------------------------
# 3. Root absent: nothing is created, and the attachment is still removed.
# --------------------------------------------------------------------------
fresh
a=$(att '{"kind":"turn","actionable":false,"reply":null}')
run_lib "cc_attention_emit session-turn $(q "$SSLOT") t b $(q "$a")"
strict "3 루트 없음"
check "3 루트 없음: HOME 아래 파일 없음" "$(nfiles "$s/home")" "0"
check "3 루트 없음: 루트 없음" "$([ -e "$ROOT" ] && echo yes || echo no)" "no"
check "3 루트 없음: 첨부 지워짐" "$([ -e "$a" ] && echo yes || echo no)" "no"

# --------------------------------------------------------------------------
# 4. Root present: modes, one file per call, no dot file left.
# --------------------------------------------------------------------------
for pre in no yes; do
  fresh_root
  if [ "$pre" = yes ]; then mkdir -m 700 "$ROOT/events" "$ROOT/handled"; fi
  run_lib "cc_attention_emit session-turn $(q "$SSLOT") t b"
  check "4 하위 미리 만듦=$pre: 사건 한 번에 파일 하나" "$(nfiles "$ROOT")" "1"
  run_lib "cc_attention_handled $(q "$SSLOT") clear"
  strict "4 하위 미리 만듦=$pre"
  check "4 하위 미리 만듦=$pre: 표지 한 번에 파일 하나" "$(nfiles "$ROOT")" "2"
  check "4 하위 미리 만듦=$pre: events 0700" "$(mode "$ROOT/events")" "700"
  check "4 하위 미리 만듦=$pre: handled 0700" "$(mode "$ROOT/handled")" "700"
  check "4 하위 미리 만듦=$pre: 사건 파일 0600" "$(mode "$(one_file "$ROOT/events")")" "600"
  check "4 하위 미리 만듦=$pre: 표지 파일 0600" "$(mode "$(one_file "$ROOT/handled")")" "600"
  check "4 하위 미리 만듦=$pre: 점 파일 없음" "$(ndot "$ROOT/events")$(ndot "$ROOT/handled")" "00"
  collect
done

# --------------------------------------------------------------------------
# 5. Approvals: only a canonical attachment writes, in either order.
# --------------------------------------------------------------------------
fresh_root
a1=$(att '{"kind":"approval","actionable":false,"reply":null}')
a2=$(att "$(reply_only)")
a3=$(att "$(body_only)")
mism=$(jq -cn --arg b "$AQ" \
  '{kind: "approval", actionable: true, body: $b,
    reply: {surface: "approval", run_id: "other-run", approval_id: "J-1111aaaa", question: $b, options: ["승인"]}}')
a4=$(att "$mism")
run_lib "cc_attention_emit answer $(q "$ASLOT") t $(q "$AWATCH")
cc_attention_emit answer $(q "$ASLOT") t $(q "$AWATCH") $(q "$a1")
cc_attention_emit answer $(q "$ASLOT") t $(q "$AWATCH") $(q "$a2")
cc_attention_emit answer $(q "cc-cmds-autopilot-$RID-answer") t $(q "$AWATCH") $(q "$a3")
cc_attention_emit answer $(q "$ASLOT") t $(q "$AWATCH") $(q "$a4")" RUN_ID="$RID"
strict "5 정규 첨부가 아닌 승인 호출"
check "5 첨부 없음·body 없음·답 대상만·빈 항목 키·어긋난 답 대상: 파일 없음" "$(nfiles "$ROOT")" "0"

# Order A: no attachment, then body only, then reply and body.
fresh_root
a1=$(att "$(body_only)")
run_lib "cc_attention_emit answer $(q "$ASLOT") t $(q "$AWATCH")
cc_attention_emit answer $(q "$ASLOT") t $(q "$AWATCH") $(q "$a1")" RUN_ID="$RID"
strict "5 순서 가"
f=$(one_file "$ROOT/events")
check "5 순서 가: 파일 하나" "$(nfiles "$ROOT")" "1"
check "5 순서 가: 결정적 id" "${f##*/}" "local.appr.$RID.$AID.json"
check "5 순서 가: body 는 정규 질문" "$(field "$f" '.body')" "$AQ"
check "5 순서 가: reply null" "$(field "$f" '.reply')" "null"
cp "$f" "$s/first.json"
a2=$(att "$(with_reply)")
run_lib "cc_attention_emit answer $(q "$ASLOT") t $(q "$AWATCH") $(q "$a2")" RUN_ID="$RID"
check "5 순서 가: 다시 불러도 파일 하나" "$(nfiles "$ROOT")" "1"
check "5 순서 가: 첫 내용 그대로" "$(cmp -s "$f" "$s/first.json" && echo same || echo changed)" "same"
check "5 순서 가: 다시 부른 첨부 지워짐" "$([ -e "$a2" ] && echo yes || echo no)" "no"
collect

# Order B: reply and body first, then body only.
fresh_root
a1=$(att "$(with_reply)")
run_lib "cc_attention_emit answer $(q "$ASLOT") t $(q "$AWATCH") $(q "$a1")" RUN_ID="$RID"
strict "5 순서 나"
f=$(one_file "$ROOT/events")
check "5 순서 나: 파일 하나" "$(nfiles "$ROOT")" "1"
check "5 순서 나: body 는 정규 질문" "$(field "$f" '.body')" "$AQ"
check "5 순서 나: actionable 참" "$(field "$f" '.actionable')" "true"
check "5 순서 나: accepts" "$(jq -c '.accepts' "$f")" '["option"]'
cp "$f" "$s/first.json"
a2=$(att "$(body_only)")
run_lib "cc_attention_emit answer $(q "$ASLOT") t $(q "$AWATCH") $(q "$a2")" RUN_ID="$RID"
check "5 순서 나: 다시 불러도 파일 하나" "$(nfiles "$ROOT")" "1"
check "5 순서 나: 첫 내용 그대로" "$(cmp -s "$f" "$s/first.json" && echo same || echo changed)" "same"
collect

# Order C: reply only first writes nothing; body only then writes the event.
fresh_root
a1=$(att "$(reply_only)")
run_lib "cc_attention_emit answer $(q "$ASLOT") t $(q "$AWATCH") $(q "$a1")" RUN_ID="$RID"
check "5 순서 다: 답 대상만 실린 첨부는 파일 없음" "$(nfiles "$ROOT")" "0"
a2=$(att "$(body_only)")
run_lib "cc_attention_emit answer $(q "$ASLOT") t $(q "$AWATCH") $(q "$a2")" RUN_ID="$RID"
strict "5 순서 다"
f=$(one_file "$ROOT/events")
check "5 순서 다: 파일 하나" "$(nfiles "$ROOT")" "1"
check "5 순서 다: body 는 정규 질문" "$(field "$f" '.body')" "$AQ"
collect

# --------------------------------------------------------------------------
# 6. Host id.
# --------------------------------------------------------------------------
host_case() {
  # host_case <label> <want> [<file content>|-unreadable]
  local label="$1" want="$2" f
  fresh_root
  if [ "$#" -ge 3 ]; then
    mkdir -p "$s/home/.config/cc-cmds"
    if [ "$3" = "-unreadable" ]; then
      printf 'mbp-9\n' > "$s/home/.config/cc-cmds/host-id"
      chmod 000 "$s/home/.config/cc-cmds/host-id"
    else
      printf '%s' "$3" > "$s/home/.config/cc-cmds/host-id"
    fi
  fi
  run_lib "cc_attention_emit session-turn $(q "$SSLOT") t b
cc_attention_handled $(q "$SSLOT") return"
  strict "6 $label"
  f=$(one_file "$ROOT/events")
  check "6 $label: 사건이 생김" "$(nfiles "$ROOT/events")" "1"
  check "6 $label: host" "$(field "$f" '.host')" "$want"
  check "6 $label: id 가 host 로 시작" "$(field "$f" '.host as $h | .id | startswith($h + ".")')" "true"
  check "6 $label: 표지 host" "$(field "$(one_file "$ROOT/handled")" '.host')" "$want"
  collect
}
host_case "파일 없음" "local"
host_case "형식에 맞음" "mbp-1" $'mbp-1\n'
host_case "대문자" "local" $'MBP-1\n'
host_case "33자" "local" "$(printf 'a%.0s' 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33)"
host_case "개행 없는 한 줄" "mbp-2" "mbp-2"
host_case "끝의 CR" "local" $'mbp-3\r\n'
host_case "빈 파일" "local" ""
host_case "읽을 수 없는 파일" "local" "-unreadable"

# --------------------------------------------------------------------------
# 7. Lane independence.
# --------------------------------------------------------------------------
fresh_root
run_lib "cc_attention_emit session-turn $(q "$SSLOT") t b" CLAUDE_CONFIG_DIR="$s/lane-one"
run_lib "cc_attention_emit session-turn $(q "$SSLOT") t b" CLAUDE_CONFIG_DIR="$s/lane-two"
strict "7 레인 독립"
check "7 레인 독립: 같은 events/ 에 둘" "$(nfiles "$ROOT/events")" "2"
dirs=""
for f in "$ROOT"/events/*.json; do dirs="$dirs$(field "$f" '.origin.config_dir')|"; done
check "7 레인 독립: config_dir 가 둘" "$(printf '%s' "$dirs" | tr '|' '\n' | LC_ALL=C sort | tr '\n' '|')" "$s/lane-one|$s/lane-two|"
rest=""
for f in "$ROOT"/events/*.json; do
  rest="$rest$(jq -cS 'del(.id, .created_at_ms, .origin.config_dir)' "$f")"$'\n'
done
check "7 레인 독립: 그 밖은 같음" "$(printf '%s' "$rest" | LC_ALL=C sort -u | wc -l | tr -d ' ')" "1"
collect

# --------------------------------------------------------------------------
# 8. The token table, row by row, as the schema document writes it.
# --------------------------------------------------------------------------
doc_pairs() {
  awk -v h="## Tokens and kinds" '
    $0 == h { inside = 1; next }
    inside && /^## / { exit }
    inside && /^\| `/ {
      split($0, c, "|")
      a = c[2]; b = c[3]
      gsub(/`/, "", a); gsub(/`/, "", b)
      gsub(/^[ \t]+|[ \t]+$/, "", a); gsub(/^[ \t]+|[ \t]+$/, "", b)
      print a " " b
    }
  ' "$DOC"
}
rows=0
while read -r token kind; do
  [ -n "$token" ] || continue
  rows=$((rows + 1))
  fresh_root
  case "$kind" in
    question-form)
      a=$(att '{"kind":"question-form","actionable":false,"reply":null}')
      run_lib "cc_attention_emit $(q "$token") $(q "$SSLOT") t b $(q "$a")"
      ;;
    approval)
      a=$(att "$(body_only)")
      run_lib "cc_attention_emit $(q "$token") $(q "$ASLOT") t b $(q "$a")" RUN_ID="$RID"
      ;;
    *)
      run_lib "cc_attention_emit $(q "$token") $(q "$SSLOT") t b"
      ;;
  esac
  strict "8 ${token}→$kind"
  if [ "$kind" = "없음" ]; then
    check "8 ${token}→없음: 파일 없음" "$(nfiles "$ROOT")" "0"
  else
    f=$(one_file "$ROOT/events")
    check "8 ${token}→$kind: 파일 하나" "$(nfiles "$ROOT")" "1"
    check "8 ${token}→$kind: kind" "$(field "$f" '.kind')" "$kind"
    check "8 ${token}→$kind: token" "$(field "$f" '.token')" "$token"
    collect
  fi
done < <(doc_pairs)
check "8 문서의 토큰 표를 읽음" "$([ "$rows" -ge 13 ] && echo yes || echo "rows=$rows")" "yes"

# --------------------------------------------------------------------------
# 9. Normalisation, origin.run_id from the reply, origin.repo.
# --------------------------------------------------------------------------
norm_case() {
  # norm_case <label> <token> <slot> <detail-json> <want actionable> [<VAR=value>...]
  local label="$1" token="$2" slot="$3" detail="$4" want="$5" f a
  shift 5
  fresh_root
  a=$(att "$detail")
  run_lib "cc_attention_emit $(q "$token") $(q "$slot") t b $(q "$a")" "$@"
  strict "9 $label"
  f=$(one_file "$ROOT/events")
  check "9 $label: 사건이 생김" "$(nfiles "$ROOT/events")" "1"
  check "9 $label: actionable" "$(field "$f" '.actionable')" "$want"
  if [ "$want" = true ]; then
    check "9 $label: accepts" "$(jq -c '.accepts' "$f")" '["option"]'
  else
    check "9 $label: accepts" "$(jq -c '.accepts' "$f")" '[]'
  fi
  collect
}
norm_case "답할 수 있는 auq (대조군)" session-ask "$SSLOT" "$(auq_detail true '[{"label":"왼쪽"},{"label":"오른쪽"}]')" true
norm_case "선택지 없는 질문의 auq" session-ask "$SSLOT" "$(auq_detail true '[]')" false
norm_case "선택지가 빈 승인" answer "$ASLOT" "$(jq -cn --arg b "$AQ" --arg r "$RID" --arg a "$AID" \
  '{kind: "approval", actionable: true, body: $b,
    reply: {surface: "approval", run_id: $r, approval_id: $a, question: $b, options: []}}')" false RUN_ID="$RID"
norm_case "표면이 다른 reply" session-ask "$SSLOT" "$(jq -cn --arg s "$SID" \
  '{kind: "auq", actionable: true,
    reply: {surface: "question-form", session_id: $s, form_id: "f1",
            questions: [{id: "q1", question: "?", options: [{label: "a"}]}]}}')" false
f=$(one_file "$ROOT/events")
check "9 표면이 다른 reply: reply null" "$(field "$f" '.reply')" "null"
norm_case "선택지 없는 질문의 질문지" session-ask "$SSLOT" "$(jq -cn --arg s "$SID" \
  '{kind: "question-form", actionable: true,
    reply: {surface: "question-form", session_id: $s, form_id: "f1",
            questions: [{id: "q1", question: "?", options: [{label: "a"}]},
                        {id: "q2", question: "?", options: []}]}}')" false
norm_case "actionable 참을 넘긴 permission" permission "cc-cmds-permission-$SID" "$(jq -cn --arg s "$SID" \
  '{kind: "permission", actionable: true,
    reply: {surface: "permission", session_id: $s, tool_name: "Bash", input_summary: "ls"}}')" false
norm_case "RUN_ID 와 다른 reply run_id" answer "$ASLOT" "$(with_reply)" true RUN_ID="other-run"
f=$(one_file "$ROOT/events")
check "9 RUN_ID 와 다른 reply run_id: origin.run_id" "$(field "$f" '.origin.run_id')" "$RID"
check "9 RUN_ID 와 다른 reply run_id: id" "$(field "$f" '.id')" "local.appr.$RID.$AID"

repo_case() {
  # repo_case <label> <CC_NOTIFY_REPO value> <want> [<VAR=value>...]
  local label="$1" val="$2" want="$3" f
  shift 3
  fresh_root
  run_lib "cc_attention_emit session-turn $(q "$SSLOT") t b" CC_NOTIFY_REPO="$val" "$@"
  strict "9 repo $label"
  f=$(one_file "$ROOT/events")
  check "9 repo $label" "$(field "$f" '.origin.repo')" "$want"
  collect
}
repo_case "owner/name" "Nharu/cc-cmds" "Nharu/cc-cmds"
repo_case "절대경로" "/Users/me/dev/cc-cmds" "null"
repo_case "빈 값" "" "null"
repo_case "../.." "../.." "null"
repo_case "./x" "./x" "null"
repo_case "점 둘 이름" "Nharu/.." "null"
repo_case "형식 밖 owner" "-bad/cc-cmds" "null"
repo_case "git 없는 PATH" "Nharu/cc-cmds" "Nharu/cc-cmds" PATH="$WORK/bin-nogit"
check "9 저장소 밖 작업 디렉터리" "$(cd "$s/cwd" && { git rev-parse --is-inside-work-tree 2>/dev/null || echo outside; })" "outside"

# --------------------------------------------------------------------------
# 10. Every record the cases wrote passes the schema lint; broken copies fail.
# --------------------------------------------------------------------------
check "10 모은 레코드가 있음" "$([ "$collected" -ge 20 ] && echo yes || echo "collected=$collected")" "yes"
bash "$LINT" "$COLLECT"/*.json > "$WORK/lint.out" 2>&1
check "10 생성 레코드 전부 스키마 린트 통과" "$?" "0"
bash "$LINT" > "$WORK/lint.out" 2>&1
check "10 고정 예제 전부 스키마 린트 통과" "$?" "0"

neg_case() {
  # neg_case <label> <fixture> <jq filter>
  local out="$WORK/neg-$RANDOM.json"
  jq "$3" "$FIXTURES/$2" > "$out"
  bash "$LINT" "$out" > "$WORK/lint.out" 2>&1
  check "10 부정 예 $1: 린트 1" "$?" "1"
}
neg_case "키 누락" event-turn.json 'del(.title)'
neg_case "모르는 종류" event-turn.json '.kind = "banner"'
neg_case "accepts 와 actionable 어긋남" event-turn.json '.accepts = ["option"]'
neg_case "잘못된 id" event-turn.json '.id = "mbp-1.123.xyz"'
neg_case "승인 slot 어긋남" event-approval.json '.slot = "cc-cmds-autopilot-x-J-0000abcd"'
neg_case "승인 body 와 질문 어긋남" event-approval.json '.body = "승인 J-0000abcd"'
neg_case "repo 절대경로" event-auq.json '.origin.repo = "/home/me/dev/cc-cmds"'
neg_case "actionable permission" event-permission.json '.actionable = true | .accepts = ["option"]'
neg_case "표지 원인 밖" handled-clear.json '.cause = "expired"'
neg_case "접두 표지 @ 없음" handled-dismiss-prefix.json '.slot = "cc-cmds-active-notify-x"'

# --------------------------------------------------------------------------
# 11. Static pins.
# --------------------------------------------------------------------------
names=$(grep -oE 'CC_CMDS_[A-Z0-9_]+' "$LIB" | LC_ALL=C sort -u | tr '\n' ' ')
check "11 라이브러리의 CC_CMDS_ 이름은 시험 자리 하나" "$names" "CC_CMDS_ATTENTION_ROOT "
check "11 라이브러리가 배너 깔때기 함수를 부르지 않음" \
  "$(grep -cE 'cc_notify_|notify-run|watch\.sh|gate\.sh' "$LIB")" "0"
check "11 라이브러리가 다른 파일을 source 하지 않음" \
  "$(grep -cE '^[[:space:]]*(\.|source)[[:space:]]' "$LIB")" "0"
check "11 라이브러리가 저장소 도구를 부르지 않음" "$(grep -cwE 'git' "$LIB")" "0"
check "11 라이브러리가 깔때기 통로 값을 읽지 않음" "$(grep -c 'CC_NOTIFY_ATTENTION_DETAIL' "$LIB")" "0"
for f in plugins/cc-cmds/orchestrator/notify-run.sh plugins/cc-cmds/skills/active-notify/scripts/notify.sh; do
  check "11 $f 에 시험 자리 이름 없음" "$(grep -c 'CC_CMDS_ATTENTION_ROOT' "$repo_root/$f")" "0"
done
check "11 공용 픽스처가 시험 자리를 덮어씀" \
  "$(grep -cxF 'CC_CMDS_ATTENTION_ROOT=/dev/null/cc-cmds-attention' "$repo_root/scripts/run-fixture.sh")" "1"
check "11 공용 픽스처가 시험 자리를 내보냄" \
  "$(grep -cxF 'export CC_CMDS_ATTENTION_ROOT' "$repo_root/scripts/run-fixture.sh")" "1"
for f in scripts/test-notify-focus.sh scripts/test-active-notify-lifecycle.sh scripts/test-active-notify-dismiss.sh; do
  check "11 $f 가 시험 자리를 정함" \
    "$([ "$(grep -cE 'export CC_CMDS_ATTENTION_ROOT=' "$repo_root/$f")" -ge 1 ] && echo yes || echo no)" "yes"
done
# Every `env -i` command of the click suite, read as one unit with its
# backslash-continued lines, carries the value itself or CLICK_ENV. Comment
# lines are not commands and are skipped.
missing=$(awk '
  !cont && /^[[:space:]]*#/ { next }
  { line = $0 }
  cont { unit = unit " " line } !cont { unit = line }
  { cont = (line ~ /\\$/) }
  !cont {
    if (unit ~ /env -i/ && unit !~ /CC_CMDS_ATTENTION_ROOT/ && unit !~ /CLICK_ENV/) print NR
  }
' "$repo_root/scripts/test-notify-focus.sh" | tr '\n' ' ')
check "11 클릭 처리기 묶음의 env -i 마다 시험 자리" "$missing" ""
units=$(awk '
  !cont && /^[[:space:]]*#/ { next }
  { line = $0 }
  cont { unit = unit " " line } !cont { unit = line }
  { cont = (line ~ /\\$/) }
  !cont && unit ~ /env -i/ { n++ }
  END { print n + 0 }
' "$repo_root/scripts/test-notify-focus.sh")
check "11 클릭 처리기 묶음의 env -i 명령을 읽음" "$([ "$units" -ge 8 ] && echo yes || echo "units=$units")" "yes"
token=$(grep -oF '`${sid//[^A-Za-z0-9_.-]/_}`' "$DOC" | tr -d '`' | LC_ALL=C sort -u)
check "11 스키마 문서가 safe_sid 치환식을 한 토큰으로 적음" "$token" '${sid//[^A-Za-z0-9_.-]/_}'
for f in plugins/cc-cmds/skills/active-notify/scripts/notify.sh plugins/cc-cmds/hooks/session-return-dismiss.sh; do
  check "11 $f 의 safe_sid 치환식이 같은 바이트" \
    "$([ "$(grep -cF "$token" "$repo_root/$f")" -ge 1 ] && echo yes || echo no)" "yes"
done

# --------------------------------------------------------------------------
# 12. The default root: $HOME, never XDG_STATE_HOME or CLAUDE_CONFIG_DIR.
# --------------------------------------------------------------------------
fresh
mkdir -p "$s/xdg" "$s/cfg" "$s/home/.local/state/cc-cmds/attention"
run_lib "cc_attention_emit session-turn $(q "$SSLOT") t b" \
  CC_CMDS_ATTENTION_ROOT= XDG_STATE_HOME="$s/xdg" CLAUDE_CONFIG_DIR="$s/cfg"
strict "12 기본 루트 있음"
check "12 기본 루트 있음: HOME 아래 스풀에 사건" "$(nfiles "$s/home/.local/state/cc-cmds/attention/events")" "1"
check "12 기본 루트 있음: XDG 아래 없음" "$(nfiles "$s/xdg")" "0"
check "12 기본 루트 있음: 설정 디렉터리 아래 없음" "$(nfiles "$s/cfg")" "0"

fresh
mkdir -p "$s/xdg" "$s/cfg"
run_lib "cc_attention_emit session-turn $(q "$SSLOT") t b
cc_attention_handled $(q "$SSLOT") clear" \
  CC_CMDS_ATTENTION_ROOT= XDG_STATE_HOME="$s/xdg" CLAUDE_CONFIG_DIR="$s/cfg"
strict "12 기본 루트 없음"
check "12 기본 루트 없음: HOME 아래 파일 없음" "$(nfiles "$s/home")" "0"
check "12 기본 루트 없음: XDG 아래 없음" "$(nfiles "$s/xdg")" "0"
check "12 기본 루트 없음: 설정 디렉터리 아래 없음" "$(nfiles "$s/cfg")" "0"

echo "test-attention: $passed passed, $failed failed"
if [ "$failed" -gt 0 ]; then
  exit 1
fi
exit 0
