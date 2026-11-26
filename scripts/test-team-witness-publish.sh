#!/usr/bin/env bash
# Test the team witness publisher and the team nonce minter.
#
# `scripts/test-gate.sh` asserts the grade of both names and that one gated
# publish leaves one exec row. This suite asserts what a grade cannot: both
# files run as argv0, and the publisher ends in exactly one line of its ending
# table for every state that table names — exit value, the line it prints, and
# the two names afterwards, the link count included.
#
# Usage: bash scripts/test-team-witness-publish.sh

set -uo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
ORCH="$repo_root/plugins/cc-cmds/orchestrator"
PUB="$ORCH/cc-team-witness-publish.sh"
NONCE="$ORCH/cc-team-nonce.sh"
INIT="$ORCH/cc-team-witness-init.sh"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/cc-witness-publish-test.XXXXXX")
trap 'chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

passed=0
failed=0
ok()    { passed=$((passed + 1)); printf 'PASS: %s\n' "$1"; }
bad()   { failed=$((failed + 1)); printf 'FAIL: %s — %s\n' "$1" "${2:-}" >&2; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got '$2', want '$3'"; fi; }
has()   { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "'$2' 에 '$3' 이 없다" ;; esac; }
absent(){ if [ -e "$2" ] || [ -L "$2" ]; then bad "$1" "$2 가 있다"; else ok "$1"; fi; }
present(){ if [ -f "$2" ]; then ok "$1"; else bad "$1" "$2 가 없다"; fi; }
links() { ls -ld "$1" | awk '{ print $2 }'; }

# ---------------------------------------------------------------------------
# Both helpers run as themselves
# ---------------------------------------------------------------------------
for f in "$PUB" "$NONCE"; do
  if [ -x "$f" ]; then ok "$(basename "$f") 에 실행 비트가 있다"
  else bad "$(basename "$f") 에 실행 비트가 있다" "bash 로 감싸 부르면 argv0 이 bash 가 되어 등급 행이 무력해진다"; fi
  check "$(basename "$f") 셔뱅" "$(head -1 "$f")" "#!/usr/bin/env bash"
done

# Witness directories come from the initializer, with and without a stage id,
# so the publisher is tested against the directories it will really meet.
RUNDIR="$WORK/run"; mkdir -p "$RUNDIR"
WD=$(CC_PIPELINE_RUN_DIR="$RUNDIR" CC_PIPELINE_STAGE_ID='S-1#1' "$INIT" review-t)
WD_NOSTAGE=$(env -u CC_PIPELINE_STAGE_ID CC_PIPELINE_RUN_DIR="$RUNDIR" "$INIT" review-t)

TOKS=(0123456789abcdef 1111111111111111 2222222222222222 3333333333333333
      4444444444444444 5555555555555555 6666666666666666 7777777777777777)
NONCE_A='round-1:aaaaaaaaaaaaaaaa'
NONCE_B='round-1:bbbbbbbbbbbbbbbb'

mk_draft() {
  # mk_draft <dir> <role> <round> <token> <nonce> <body> — prints the draft path
  local p="$1/.$2.$3.$4"
  printf '%s\n\n<!-- cc-witness: %s %s complete %s -->\n\n' "$6" "$2" "$3" "$5" > "$p"
  printf '%s' "$p"
}

pub() {
  # pub <draft> <witness> — sets RC, OUT, ERR
  local o e
  o="$WORK/out.$$"; e="$WORK/err.$$"
  "$PUB" "$@" >"$o" 2>"$e"; RC=$?
  OUT=$(cat "$o"); ERR=$(cat "$e"); rm -f "$o" "$e"
}

# ---------------------------------------------------------------------------
# Line 5 — published, the draft name removed, one link
# ---------------------------------------------------------------------------
W="$WD/rev-a.round-1.md"
D=$(mk_draft "$WD" rev-a round-1 "${TOKS[0]}" "$NONCE_A" 'body A')
before=$(cat "$D")
pub "$D" "$W"
check "줄 5: 종료 값 0" "$RC" "0"
has "줄 5: 게시됨 한 줄" "$OUT" "게시됨 — $W"
check "줄 5: 표준 오류는 비어 있다" "$ERR" ""
absent "줄 5: 초안 이름이 지워졌다" "$D"
check "줄 5: 증인 내용이 초안 그대로다" "$(cat "$W")" "$before"
check "줄 5: 링크 수 1" "$(links "$W")" "1"

# ---------------------------------------------------------------------------
# Line 7 — the same nonce lost a race: the draft stays, the witness is untouched
# ---------------------------------------------------------------------------
D2=$(mk_draft "$WD" rev-a round-1 "${TOKS[1]}" "$NONCE_A" 'body A2')
pub "$D2" "$W"
check "줄 7: 종료 값 0" "$RC" "0"
has "줄 7: 이미 게시됨(같은 nonce)" "$OUT" "이미 게시됨(같은 nonce)"
check "줄 7: 증인 내용이 그대로다" "$(cat "$W")" "$before"
present "줄 7: 초안이 남는다" "$D2"

# ---------------------------------------------------------------------------
# Line 8 — another nonce, no sentinel, a symlink, a directory: refused, unchanged
# ---------------------------------------------------------------------------
D3=$(mk_draft "$WD" rev-a round-1 "${TOKS[2]}" "$NONCE_B" 'body B')
pub "$D3" "$W"
check "줄 8(다른 nonce): 종료 값 3" "$RC" "3"
has "줄 8(다른 nonce): 한 줄" "$ERR" "이미 게시됨(다른 nonce)"
check "줄 8(다른 nonce): 표준 출력은 비어 있다" "$OUT" ""
check "줄 8(다른 nonce): 증인 내용이 그대로다" "$(cat "$W")" "$before"
present "줄 8(다른 nonce): 초안이 남는다" "$D3"

W8="$WD/rev-b.round-1.md"
printf 'no sentinel here\n' > "$W8"
D8=$(mk_draft "$WD" rev-b round-1 "${TOKS[0]}" "$NONCE_A" 'body')
pub "$D8" "$W8"
check "줄 8(센티널 없는 증인): 종료 값 3" "$RC" "3"
check "줄 8(센티널 없는 증인): 증인 내용이 그대로다" "$(cat "$W8")" "no sentinel here"

W8L="$WD/rev-c.round-1.md"
printf 'elsewhere\n' > "$WORK/elsewhere"
ln -s "$WORK/elsewhere" "$W8L"
D8L=$(mk_draft "$WD" rev-c round-1 "${TOKS[0]}" "$NONCE_A" 'body')
pub "$D8L" "$W8L"
check "줄 8(심볼릭 링크 증인): 종료 값 3" "$RC" "3"
check "줄 8(심볼릭 링크 증인): 링크 대상이 그대로다" "$(cat "$WORK/elsewhere")" "elsewhere"

W8D="$WD/rev-d.round-1.md"
mkdir "$W8D"
D8D=$(mk_draft "$WD" rev-d round-1 "${TOKS[0]}" "$NONCE_A" 'body')
pub "$D8D" "$W8D"
check "줄 8(디렉터리 증인): 종료 값 3" "$RC" "3"
check "줄 8(디렉터리 증인): 디렉터리 안에 링크를 만들지 않는다" "$(ls -A "$W8D" | wc -l | tr -d ' ')" "0"

# ---------------------------------------------------------------------------
# Line 1 — names
# ---------------------------------------------------------------------------
D1=$(mk_draft "$WD" rev-e round-1 "${TOKS[0]}" "$NONCE_A" 'body')
for wrong in "$WD/rev-e.round-1.txt" "$WD/rev-e.md" "$WD/rev-e.round.1.md" "$WD/re v.round-1.md"; do
  pub "$D1" "$wrong"
  check "줄 1: 어긋난 증인 이름 $(basename "$wrong") → 2" "$RC" "2"
  has "줄 1: 어긋난 이름 한 줄 ($(basename "$wrong"))" "$ERR" "어긋난 이름"
  absent "줄 1: 증인을 만들지 않는다 ($(basename "$wrong"))" "$wrong"
done
# The upper-case token is not a case variant of D1's: on a case-insensitive file
# system that name would be D1 itself.
for wrongd in "$WD/.rev-e.round-1.0123" "$WD/.rev-e.round-1.ABCDEF0123456789" "$WD/.rev-e.round-1.zzzzzzzzzzzzzzzz" "$WD/.rev-x.round-1.${TOKS[0]}" "$WD/rev-e.round-1.${TOKS[0]}"; do
  printf 'x\n' > "$wrongd"
  pub "$wrongd" "$WD/rev-e.round-1.md"
  check "줄 1: 어긋난 초안 이름 $(basename "$wrongd") → 2" "$RC" "2"
  rm -f "$wrongd"
done
absent "줄 1: 어긋난 초안 이름에도 증인이 생기지 않는다" "$WD/rev-e.round-1.md"
mkdir -p "$WORK/other"
pub "$D1" "$WORK/other/rev-e.round-1.md"
check "줄 1: 다른 디렉터리 → 2" "$RC" "2"
mkdir -p "$WORK/not-witness"
DN=$(mk_draft "$WORK/not-witness" rev-e round-1 "${TOKS[0]}" "$NONCE_A" 'body')
pub "$DN" "$WORK/not-witness/rev-e.round-1.md"
check "줄 1: cc-team-witness- 가 아닌 디렉터리 → 2" "$RC" "2"
absent "줄 1: 그 디렉터리에 증인을 만들지 않는다" "$WORK/not-witness/rev-e.round-1.md"
pub "$D1"
check "줄 1: 인자 수가 둘이 아니면 2" "$RC" "2"
present "줄 1: 초안이 그대로 남는다" "$D1"

# ---------------------------------------------------------------------------
# Lines 2 and 3 — the draft itself
# ---------------------------------------------------------------------------
pub "$WD/.rev-f.round-1.${TOKS[0]}" "$WD/rev-f.round-1.md"
check "줄 2: 초안 없음 → 2" "$RC" "2"
has "줄 2: 초안 없음 한 줄" "$ERR" "초안 없음"
absent "줄 2: 증인을 만들지 않는다" "$WD/rev-f.round-1.md"

printf 'secret\n\n<!-- cc-witness: rev-g round-1 complete %s -->\n' "$NONCE_A" > "$WORK/target"
ln -s "$WORK/target" "$WD/.rev-g.round-1.${TOKS[0]}"
pub "$WD/.rev-g.round-1.${TOKS[0]}" "$WD/rev-g.round-1.md"
check "줄 3: 심볼릭 링크 초안 → 2" "$RC" "2"
has "줄 3: 일반 파일이 아님 한 줄" "$ERR" "초안이 일반 파일이 아님"
absent "줄 3: 증인을 만들지 않는다" "$WD/rev-g.round-1.md"
check "줄 3: 링크 대상의 링크 수가 그대로다" "$(links "$WORK/target")" "1"
ln -s "$WORK/nowhere" "$WD/.rev-h.round-1.${TOKS[0]}"
pub "$WD/.rev-h.round-1.${TOKS[0]}" "$WD/rev-h.round-1.md"
check "줄 3: 끊긴 심볼릭 링크 초안도 일반 파일이 아님 → 2" "$RC" "2"
has "줄 3: 끊긴 링크는 초안 없음이 아니다" "$ERR" "초안이 일반 파일이 아님"
mkdir "$WD/.rev-i.round-1.${TOKS[0]}"
pub "$WD/.rev-i.round-1.${TOKS[0]}" "$WD/rev-i.round-1.md"
check "줄 3: 디렉터리 초안 → 2" "$RC" "2"

# ---------------------------------------------------------------------------
# Line 4 — the sentinel
# ---------------------------------------------------------------------------
sent_case() {
  # sent_case <label> <role> <content>
  local p="$WD/.$2.round-1.${TOKS[3]}"
  printf '%s' "$3" > "$p"
  pub "$p" "$WD/$2.round-1.md"
  check "줄 4: $1 → 2" "$RC" "2"
  has "줄 4: $1 — 센티널 어긋남 한 줄" "$ERR" "센티널 어긋남"
  absent "줄 4: $1 — 증인을 만들지 않는다" "$WD/$2.round-1.md"
  present "줄 4: $1 — 초안이 남는다" "$p"
}
sent_case "다른 역할의 센티널" rev-j "body
<!-- cc-witness: rev-z round-1 complete $NONCE_A -->
"
sent_case "다른 라운드의 센티널" rev-k "body
<!-- cc-witness: rev-k round-2 complete $NONCE_A -->
"
sent_case "센티널이 마지막 줄이 아님" rev-l "<!-- cc-witness: rev-l round-1 complete $NONCE_A -->
more text
"
sent_case "nonce 태그가 라운드와 다름" rev-m "body
<!-- cc-witness: rev-m round-1 complete round-2:aaaaaaaaaaaaaaaa -->
"
sent_case "nonce 16진수가 짧음" rev-n "body
<!-- cc-witness: rev-n round-1 complete round-1:aaaa -->
"
sent_case "nonce 에 16진수 아닌 글자" rev-o "body
<!-- cc-witness: rev-o round-1 complete round-1:aaaaaaaaaaaaaaaz -->
"
sent_case "빈 초안" rev-p ""

# ---------------------------------------------------------------------------
# Line 6 — linked, the draft name could not be removed (PATH stub for rm)
# ---------------------------------------------------------------------------
STUB="$WORK/stub-rm"; mkdir -p "$STUB"
printf '#!/bin/sh\nexit 1\n' > "$STUB/rm"; chmod 755 "$STUB/rm"
W6="$WD/rev-q.round-1.md"
D6=$(mk_draft "$WD" rev-q round-1 "${TOKS[4]}" "$NONCE_A" 'body Q')
before6=$(cat "$D6")
o=$(PATH="$STUB:$PATH" "$PUB" "$D6" "$W6" 2>"$WORK/err6"); RC=$?
check "줄 6: 종료 값 0" "$RC" "0"
has "줄 6: 게시됨, 초안 이름 남음 한 줄" "$o" "게시됨, 초안 이름 남음"
present "줄 6: 초안 이름이 남는다" "$D6"
check "줄 6: 두 이름이 같은 파일이다(링크 수 2)" "$(links "$W6")" "2"
# Called again on the same draft, the state of line 6 is line 7.
pub "$D6" "$W6"
check "줄 6 뒤 다시 부르면 줄 7: 종료 값 0" "$RC" "0"
has "줄 6 뒤 다시 부르면 줄 7: 한 줄" "$OUT" "이미 게시됨(같은 nonce)"
check "초안 이름이 남은 채 게시된 증인의 내용이 그대로다" "$(cat "$W6")" "$before6"

# ---------------------------------------------------------------------------
# Line 9 — ln fails and there is no witness name: no mv fallback
# ---------------------------------------------------------------------------
STUBLN="$WORK/stub-ln"; mkdir -p "$STUBLN"
printf '#!/bin/sh\necho "ln: hard links not supported" >&2\nexit 1\n' > "$STUBLN/ln"
printf '#!/bin/sh\necho "mv was called" >> "%s/mv-called"\nexit 1\n' "$WORK" > "$STUBLN/mv"
chmod 755 "$STUBLN/ln" "$STUBLN/mv"
W9="$WD/rev-r.round-1.md"
D9=$(mk_draft "$WD" rev-r round-1 "${TOKS[5]}" "$NONCE_A" 'body R')
e=$(PATH="$STUBLN:$PATH" "$PUB" "$D9" "$W9" 2>&1 >/dev/null); RC=$?
check "줄 9: 종료 값 4" "$RC" "4"
has "줄 9: 원인 한 줄" "$e" "ln 실패 — ln: hard links not supported"
absent "줄 9: 증인 이름이 없다" "$W9"
present "줄 9: 초안이 남는다" "$D9"
absent "줄 9: mv 로 물러서지 않는다" "$WORK/mv-called"
# The same line from a real refusal: a directory this user cannot write.
if [ "$(id -u)" != "0" ]; then
  WDRO=$(CC_PIPELINE_RUN_DIR="$RUNDIR" "$INIT" review-ro)
  D9b=$(mk_draft "$WDRO" rev-s round-1 "${TOKS[6]}" "$NONCE_A" 'body S')
  chmod a-w "$WDRO"
  pub "$D9b" "$WDRO/rev-s.round-1.md"
  chmod u+w "$WDRO"
  check "줄 9(쓰기 금지 디렉터리): 종료 값 4" "$RC" "4"
  has "줄 9(쓰기 금지 디렉터리): 원인 한 줄" "$ERR" "ln 실패 — "
  absent "줄 9(쓰기 금지 디렉터리): 증인 이름이 없다" "$WDRO/rev-s.round-1.md"
fi

# ---------------------------------------------------------------------------
# A witness directory made without a stage id has no `.attempt`, and publishes
# ---------------------------------------------------------------------------
absent "스테이지 id 없이 만든 디렉터리에는 .attempt 가 없다" "$WD_NOSTAGE/.attempt"
WN="$WD_NOSTAGE/reader-1.fanout.md"
DNS=$(mk_draft "$WD_NOSTAGE" reader-1 fanout "${TOKS[7]}" 'fanout:cccccccccccccccc' 'reader body')
pub "$DNS" "$WN"
check "스테이지 id 없는 디렉터리에서 게시: 종료 값 0" "$RC" "0"
present "스테이지 id 없는 디렉터리에서 게시: 증인이 있다" "$WN"
absent "스테이지 id 없는 디렉터리에서 게시: 초안 이름이 지워졌다" "$DNS"

# ---------------------------------------------------------------------------
# The nonce minter
# ---------------------------------------------------------------------------
EMPTY="$WORK/nonce-cwd"; mkdir -p "$EMPTY"
out=$(cd "$EMPTY" && "$NONCE" rev-a@round-1 rev-a@round-1-rev1 reader-2@fanout); RC=$?
check "nonce: 종료 값 0" "$RC" "0"
check "nonce: 인자 수만큼의 줄" "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "3"
i=0
for key in 'rev-a round-1' 'rev-a round-1-rev1' 'reader-2 fanout'; do
  i=$((i + 1))
  line=$(printf '%s\n' "$out" | sed -n "${i}p")
  round=${key#* }
  if grep -Eq "^${key} ${round}:[0-9a-f]{16} [0-9a-f]{16}\$" <<<"$line"; then
    ok "nonce: 줄 $i 꼴 (${key})"
  else
    bad "nonce: 줄 $i 꼴 (${key})" "$line"
  fi
done
check "nonce: 값이 모두 서로 다르다" \
  "$(printf '%s\n' "$out" | awk '{ sub(/^[^:]*:/, "", $3); print $3; print $4 }' | sort -u | wc -l | tr -d ' ')" "6"
check "nonce: 아무것도 쓰지 않는다" "$(ls -A "$EMPTY" | wc -l | tr -d ' ')" "0"
for badarg in 'rev-a' 'rev-a@' '@round-1' 'rev a@round-1' 'rev-a@round:1' 'rev-a@round-1@x' 'rev-a@round/1'; do
  out=$(cd "$EMPTY" && "$NONCE" rev-b@round-1 "$badarg" 2>/dev/null); RC=$?
  check "nonce: 어긋난 인자 '$badarg' → 2" "$RC" "2"
  check "nonce: 어긋난 인자 '$badarg' 에는 아무것도 내지 않는다" "$out" ""
done
out=$("$NONCE" 2>/dev/null); RC=$?
check "nonce: 인자가 없으면 2" "$RC" "2"
check "nonce: 인자가 없으면 아무것도 내지 않는다" "$out" ""
STUBSSL="$WORK/stub-ssl"; mkdir -p "$STUBSSL"
printf '#!/bin/sh\nexit 1\n' > "$STUBSSL/openssl"; chmod 755 "$STUBSSL/openssl"
out=$(PATH="$STUBSSL:$PATH" "$NONCE" rev-a@round-1 2>/dev/null); RC=$?
check "nonce: openssl 실패 → 1" "$RC" "1"
check "nonce: openssl 실패에는 아무것도 내지 않는다" "$out" ""
printf '#!/bin/sh\necho abcd\n' > "$STUBSSL/openssl"
out=$(PATH="$STUBSSL:$PATH" "$NONCE" rev-a@round-1 2>/dev/null); RC=$?
check "nonce: 짧은 openssl 출력 → 1" "$RC" "1"
check "nonce: 짧은 출력에는 아무것도 내지 않는다" "$out" ""
check "nonce: 아무 경우에도 작업 디렉터리에 쓰지 않는다" "$(ls -A "$EMPTY" | wc -l | tr -d ' ')" "0"

printf '\n통과 %s · 실패 %s\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
