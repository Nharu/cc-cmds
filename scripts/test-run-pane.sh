#!/usr/bin/env bash
# Test `run-pane.sh`, the helper behind the autopilot status pane.
#
# THE HELPER IS WHERE EVERY JUDGEMENT THE PANE SHOWS IS MADE — the run, its
# class, the wording, the order, the tone and the refresh — and the plugin test
# harness cannot start a process, so the mod's own tests feed it canned output.
# This suite is therefore the only place the real helper meets a real run
# directory, and it holds the helper to the unchanged `statusline.sh` rather
# than to a copy of its rules.
#
# THE HEAD LINE IS COMPARED BY GLYPH AND SECOND TOKEN, NEVER BY BYTES. The
# helper's run of the status line and this suite's run happen at different
# instants, and two slots — the ledger age `원장 N초 전` and the `ps -o etime=`
# elapsed of a running stage — move every second, so a byte compare would be red
# whenever a second boundary fell between the two. Those two tokens are the ones
# the helper's contract rests on and neither of them moves with the clock.
#
# Usage: bash scripts/test-run-pane.sh

set -uo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
PANE="$repo_root/plugins/cc-cmds/orchestrator/run-pane.sh"
SL="$repo_root/plugins/cc-cmds/orchestrator/statusline.sh"
LIVENESS="$repo_root/plugins/cc-cmds/orchestrator/liveness.sh"
. "$repo_root/scripts/run-fixture.sh"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/cc-run-pane-test.XXXXXX")
XDG_STATE_HOME="$WORK/state"
export XDG_STATE_HOME
mkdir -p "$XDG_STATE_HOME"
# The borrow segment of the status line keys on the session's config directory;
# unset, no case here sees one.
unset CLAUDE_CONFIG_DIR
trap 'fx_reap; chmod -R u+rwX "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT
fx_require_isolated_state

passed=0; failed=0; skipped=0
ok()   { passed=$((passed + 1)); printf 'PASS: %s\n' "$1"; }
bad()  { failed=$((failed + 1)); printf 'FAIL: %s — %s\n' "$1" "${2:-}" >&2; }
skip() { skipped=$((skipped + 1)); printf 'SKIP: %s — %s\n' "$1" "${2:-}"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got '$2', want '$3'"; fi; }
has()  { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "'$2' 에 '$3' 없음" ;; esac; }
hasnt(){ case "$2" in *"$3"*) bad "$1" "'$2' 에 '$3' 가 있음" ;; *) ok "$1" ;; esac; }

TAB=$(printf '\t')
SESSION_DIR="$XDG_STATE_HOME/cc-cmds/session"
OUTS="$WORK/outs"
mkdir -p "$OUTS"

# pane <sid> — run the helper; every output is also kept for the contract pass.
# Each call runs inside a command substitution, so a counter here would never
# leave its subshell; the file name comes from `mktemp` instead.
pane() {
  local out
  out=$(bash "$PANE" "$@")
  printf '%s\n' "$out" > "$(mktemp "$OUTS/o.XXXXXX")"
  printf '%s' "$out"
}
head_row()   { printf '%s\n' "$1" | head -1; }
hfield()     { head_row "$1" | cut -f"$2"; }
body()       { printf '%s\n' "$1" | sed '1d'; }
body_n()     { body "$1" | grep -c . || true; }
first_line() { body "$1" | head -1 | cut -f2-; }
# The status line as the helper calls it: the session id on stdin, nothing else.
sl_line()    { printf '{"session_id":"%s"}' "$1" | bash "$SL" 2>/dev/null; }
tok()        { printf '%s' "$1" | cut -d' ' -f"$2"; }

# ---------------------------------------------------------------------------
# 1. The head line, arm by arm.
#
# Each arm is pinned to its glyph as well as compared, because a helper and a
# status line that both printed the fallback would agree with each other and
# say nothing about the arm.
# ---------------------------------------------------------------------------
branch_case() {
  # branch_case <label> <sid> <glyph> <class>
  local label="$1" sid="$2" want_g="$3" want_c="$4" out sl first
  out=$(pane "$sid"); sl=$(sl_line "$sid")
  first=$(first_line "$out")
  check "1 $label — 상태 표시줄이 그 갈래 글리프를 낸다 (전제)" "$(tok "$sl" 1)" "$want_g"
  check "1 $label — 머리 줄 글리프가 상태 표시줄과 같다" "$(tok "$first" 1)" "$(tok "$sl" 1)"
  check "1 $label — 머리 줄 둘째 토큰이 상태 표시줄과 같다" "$(tok "$first" 2)" "$(tok "$sl" 2)"
  check "1 $label — 머리 행의 런 id 가 그 둘째 토큰이다" "$(hfield "$out" 4)" "$(tok "$sl" 2)"
  check "1 $label — 머리 줄의 tone 은 normal 이다" "$(body "$out" | head -1 | cut -f1)" "normal"
  check "1 $label — 부류" "$(hfield "$out" 3)" "$want_c"
}

fx_mkrun pr-run1; fx_ledger_path; fx_segment S1 실행중; fx_stage_live S1; fx_heartbeat 0 5
fx_session_index s-run1 pr-run1
branch_case "도는중 (스테이지 칸)" s-run1 "⟳" live
has "1 도는중 (스테이지 칸) — 머리 줄에 그 세그먼트가 실린다" "$(first_line "$(pane s-run1)")" "pr-run1 S1"

# The only live pid is the watcher's: the count takes it and the slot does not,
# which is the one way to reach `⟳ <rid> · 원장 …`.
fx_mkrun pr-run0; fx_ledger_path; fx_segment S1 실행중; fx_stage_live watch; fx_heartbeat 0 5
fx_session_index s-run0 pr-run0
branch_case "도는중 (스테이지 칸 없음)" s-run0 "⟳" live
has "1 도는중 (스테이지 칸 없음) — 머리 줄이 원장 칸으로 이어진다" "$(first_line "$(pane s-run0)")" "pr-run0 · 원장"

fx_mkrun pr-prog; fx_ledger_path; fx_segment S1 실행중; fx_heartbeat 0 5
fx_session_index s-prog pr-prog
branch_case "진행중" s-prog "⟳" live
has "1 진행중 — 스테이지 0 줄이다" "$(first_line "$(pane s-prog)")" "스테이지 0"

fx_mkrun pr-appr; fx_ledger_path; fx_segment S1 실행중; fx_approval A1 대기; fx_heartbeat 0 5
fx_session_index s-appr pr-appr
branch_case "승인대기" s-appr "⏸" live

fx_mkrun pr-stall; fx_ledger_path; fx_segment S1 실행중; fx_heartbeat 0 200
fx_session_index s-stall pr-stall
branch_case "정지경고" s-stall "⚠" live

fx_mkrun pr-done; fx_ledger_path; fx_segment S1 머지됨; fx_heartbeat 0 5
fx_session_index s-done pr-done
branch_case "종단" s-done "✓" ended

fx_mkrun pr-aband; fx_ledger_path; fx_segment S1 실행중; fx_heartbeat 0 4000
fx_session_index s-aband pr-aband
branch_case "버려짐" s-aband "⊘" ended
has "1 버려짐 — 방치로 읽힌다" "$(first_line "$(pane s-aband)")" "방치"

fx_mkrun pr-block; fx_ledger_path; fx_segment S1 실행중; fx_blocked "픽스처 차단" 불명; fx_heartbeat 0 4000
fx_session_index s-block pr-block
branch_case "차단" s-block "⊘" ended
has "1 차단 — 차단으로 읽힌다" "$(first_line "$(pane s-block)")" "차단"

# ---------------------------------------------------------------------------
# 2. The glyph table covers every render arm of the status line.
#
# Read from both files, so neither side is a copy kept here. `$` is excluded
# from the glyph so that `line="$line …"`, which extends a line rather than
# starting one, is not taken for an arm.
# ---------------------------------------------------------------------------
sl_glyphs=$(grep -o 'line="[^ "$]* ' "$SL" | sed -e 's/^line="//' -e 's/ $//' \
              | LC_ALL=C sort -u | tr '\n' ' ')
pane_glyphs=$(bash "$PANE" --glyphs | cut -f1 | LC_ALL=C sort -u | tr '\n' ' ')
check "2 상태 표시줄 렌더 갈래에서 글리프를 실제로 뽑았다 (다섯)" \
  "$(printf '%s' "$sl_glyphs" | wc -w | tr -d ' ')" "5"
check "2 헬퍼 대응표의 키 집합이 렌더 갈래의 글리프 집합과 같다" "$pane_glyphs" "$sl_glyphs"
glyph_classes=$(bash "$PANE" --glyphs | LC_ALL=C sort | tr '\t\n' ':,')
check "2 대응표의 부류" "$glyph_classes" \
  "$(printf '⊘\tended\n⏸\tlive\n⚠\tlive\n⟳\tlive\n✓\tended\n' | LC_ALL=C sort | tr '\t\n' ':,')"

# ---------------------------------------------------------------------------
# 3. A waiting approval whose heartbeat went stale is demoted in RANK only. On
# its own in the session it still renders `⏸`, and it is still a live run.
# ---------------------------------------------------------------------------
fx_mkrun pr-demote; fx_ledger_path; fx_segment S1 실행중; fx_approval A1 대기; fx_heartbeat 300 4000
fx_session_index s-demote pr-demote
out=$(pane s-demote)
check "3 강등된 승인대기 — 머리 줄은 ⏸" "$(tok "$(first_line "$out")" 1)" "⏸"
check "3 강등된 승인대기 — 부류는 live" "$(hfield "$out" 3)" "live"
check "3 강등된 승인대기 — refresh 는 live 의 것" "$(hfield "$out" 6)" "10000"

# ---------------------------------------------------------------------------
# 4. No run to show.
# ---------------------------------------------------------------------------
none_case() {
  # none_case <label> <sid>
  local out
  out=$(pane "$2")
  check "4 $1 — 부류 none" "$(hfield "$out" 3)" "none"
  check "4 $1 — 런 id 칸은 -" "$(hfield "$out" 4)" "-"
  check "4 $1 — 본문은 연결된 런 없음 한 줄" "$(body "$out")" "dim${TAB}연결된 런 없음"
  check "4 $1 — 세션 목록 칸은 그 sid 의 절대 경로" "$(hfield "$out" 5)" "$SESSION_DIR/$2"
}
none_case "목록 없음" s-noindex
mkdir -p "$SESSION_DIR"; : > "$SESSION_DIR/s-empty"
none_case "빈 목록" s-empty
fx_session_index s-gone pr-gone-never-made
none_case "사라진 런 디렉터리만 든 목록" s-gone

# The older run id shape is still live on this host; a format regex would drop it.
fx_mkrun 2026-09-01-abcdef12; fx_ledger_path; fx_segment S1 실행중; fx_heartbeat 0 5
fx_session_index s-oldid 2026-09-01-abcdef12
out=$(pane s-oldid)
check "4 옛 형식 런 id 는 none 이 아니다" "$(hfield "$out" 3)" "live"
check "4 옛 형식 런 id 가 머리 행에 그대로 실린다" "$(hfield "$out" 4)" "2026-09-01-abcdef12"

# ---------------------------------------------------------------------------
# 5. A session id that cannot be a path segment.
# ---------------------------------------------------------------------------
for bad_sid in '../x' '' '.' '..'; do
  out=$(pane "$bad_sid")
  check "5 부적합 sid '$bad_sid' — none" "$(hfield "$out" 3)" "none"
  check "5 부적합 sid '$bad_sid' — 세션 목록 칸은 -" "$(hfield "$out" 5)" "-"
done
out=$(pane)
check "5 인자 없음 — none" "$(hfield "$out" 3)" "none"

# ---------------------------------------------------------------------------
# 6. The cap. Inflating the segments must shrink the segments first and keep
# the block lines; inflating the tail must cut at fifteen with a count.
# ---------------------------------------------------------------------------
fx_mkrun pr-capseg; fx_ledger_path
for i in 01 02 03 04 05 06 07 08 09 10 11 12 13 14 15 16 17 18 19 20; do
  fx_segment "S$i" 실행중
done
fx_blocked "픽스처 차단" 불명
fx_cone_blocked 앵커 S01 막힘 "리뷰 크래시"
fx_heartbeat 0 5
fx_session_index s-capseg pr-capseg
out=$(pane s-capseg)
b=$(body "$out")
has   "6 세그먼트만 부풀림 — 세그먼트 줄이 개수 한 줄로 접힌다" "$b" "normal${TAB}끝나지 않은 세그먼트 20개"
hasnt "6 세그먼트만 부풀림 — 세그먼트 낱줄이 남지 않는다" "$b" "세그먼트 S01 "
has   "6 세그먼트만 부풀림 — run 막힘 줄이 남는다" "$b" "error${TAB}run 막힘 · 불명 · 픽스처 차단"
has   "6 세그먼트만 부풀림 — cone 막힘 줄이 남는다" "$b" "warn${TAB}cone 막힘 S01 · 막힘 · 리뷰 크래시"
hasnt "6 세그먼트만 부풀림 — 접힌 뒤에는 잘리지 않는다" "$b" "개 더"
check "6 세그먼트만 부풀림 — 본문 네 줄" "$(body_n "$out")" "4"

fx_mkrun pr-captail; fx_ledger_path; fx_segment S1 실행중
for i in 01 02 03 04 05 06 07 08 09 10 11 12 13 14 15 16 17 18 19 20; do
  fx_approval "A$i" 대기
done
fx_heartbeat 0 5
fx_session_index s-captail pr-captail
out=$(pane s-captail)
check "6 꼬리 부풀림 — 본문이 15줄에서 잘린다" "$(body_n "$out")" "15"
# 1 head + 1 segment + 20 approvals = 22 lines; 14 are kept and the 15th counts
# the other 8.
check "6 꼬리 부풀림 — 마지막 줄이 잘린 수를 센다" "$(body "$out" | tail -1)" "dim${TAB}+8개 더"

# ---------------------------------------------------------------------------
# 7. Total: exit 0 and a valid head row on every degraded input.
# ---------------------------------------------------------------------------
valid_head() {
  # valid_head <out> — `yes` when the head row has the contract's shape.
  local h; h=$(head_row "$1")
  case "$h" in
    "cc-pane${TAB}1${TAB}"*) ;;
    *) printf 'no'; return 0 ;;
  esac
  [ "$(printf '%s\n' "$h" | awk -F'\t' '{print NF}')" = "6" ] && printf 'yes' || printf 'no'
}

# `jq` present and poisonous: if the helper or the status line reached for it
# the output would be wrong rather than missing.
mkdir -p "$WORK/poison"
cat > "$WORK/poison/jq" <<'STUB'
#!/usr/bin/env bash
printf 'JQ-WAS-CALLED\n'; exit 1
STUB
chmod +x "$WORK/poison/jq"
out=$(PATH="$WORK/poison:$PATH" bash "$PANE" s-prog); rc=$?
check "7 jq 없음 — exit 0" "$rc" "0"
check "7 jq 없음 — 유효한 머리 행" "$(valid_head "$out")" "yes"
check "7 jq 없음 — 런을 그대로 해소한다" "$(hfield "$out" 4)" "pr-prog"
hasnt "7 jq 없음 — jq 를 부르지 않는다" "$out" "JQ-WAS-CALLED"

if [ "$(id -u)" = "0" ]; then
  skip "7 읽을 수 없는 런 디렉터리" "root 는 권한 비트를 무시한다"
else
  fx_mkrun pr-unread; fx_ledger_path; fx_segment S1 실행중; fx_heartbeat 0 5
  fx_session_index s-unread pr-unread
  chmod 000 "$FX_RUN_DIR"
  out=$(bash "$PANE" s-unread); rc=$?
  chmod 755 "$FX_RUN_DIR"
  check "7 읽을 수 없는 런 디렉터리 — exit 0" "$rc" "0"
  check "7 읽을 수 없는 런 디렉터리 — 유효한 머리 행" "$(valid_head "$out")" "yes"
fi

fx_mkrun pr-nolp; fx_segment S1 실행중; fx_heartbeat 0 5
fx_session_index s-nolp pr-nolp
out=$(bash "$PANE" s-nolp); rc=$?
check "7 ledger-path 없음 — exit 0" "$rc" "0"
check "7 ledger-path 없음 — 유효한 머리 행" "$(valid_head "$out")" "yes"
check "7 ledger-path 없음 — 본문은 머리 줄뿐이다" "$(body_n "$out")" "1"

mkdir -p "$WORK/lone"
cp "$PANE" "$WORK/lone/"
out=$(bash "$WORK/lone/run-pane.sh" s-prog); rc=$?
check "7 형제 스크립트 없음 — exit 0" "$rc" "0"
check "7 형제 스크립트 없음 — 유효한 머리 행" "$(valid_head "$out")" "yes"
check "7 형제 스크립트 없음 — 상태 표시줄이 없으면 none" "$(hfield "$out" 3)" "none"

mkdir -p "$WORK/noliveness"
cp "$PANE" "$SL" "$WORK/noliveness/"
out=$(bash "$WORK/noliveness/run-pane.sh" s-prog); rc=$?
check "7 liveness.sh 없음 — exit 0" "$rc" "0"
check "7 liveness.sh 없음 — 유효한 머리 행" "$(valid_head "$out")" "yes"

# ---------------------------------------------------------------------------
# 9. Cone-scope blocks.
# ---------------------------------------------------------------------------
fx_mkrun pr-cone; fx_ledger_path
fx_segment C 실행중
fx_cone_blocked 앵커 C 막힘 "리뷰 크래시"
fx_segment D park
fx_cone_blocked 드라이버 D 무효화 "게이트 park" "종단 부류 산출물 없는 정지"
# Hidden by a later segment row that is not park.
fx_segment E park
fx_cone_blocked 앵커 E 막힘 "E 의 막힘"
fx_segment E 실행중
# cone → park → 실행중 → park with no new cone row: still hidden.
fx_segment F 실행중
fx_cone_blocked 앵커 F 막힘 "F 의 막힘"
fx_segment F park
fx_segment F 실행중
fx_segment F park
# The same (subject, 사유) twice: the last one stands.
fx_segment G park
fx_cone_blocked 앵커 G 막힘 "같은 사유"
fx_cone_blocked 앵커 G 재막힘 "같은 사유"
# Two different reasons with the same non-Hangul shape and syllable counts —
# the pair that collates equal under en_US.UTF-8.
fx_segment H park
fx_cone_blocked 앵커 H 막힘 "자동 채택 미달"
fx_cone_blocked 앵커 H 막힘 "강제 표면 이동"
# Subjects with no segment row at all.
fx_cone_blocked 드라이버 B-alias "판정 불가" "조상 관계 판정 불가 B→C"
fx_cone_blocked 드라이버 P1-3 무효화 "게이트 park" "리뷰 지적"
fx_heartbeat 0 5
fx_session_index s-cone pr-cone
out=$(LC_ALL=en_US.UTF-8 bash "$PANE" s-cone)
cone=$(body "$out" | grep -E "^(warn${TAB}cone|dim${TAB}주체 미상)" || true)
has   "9 앵커 행이 보인다" "$cone" "warn${TAB}cone 막힘 C · 막힘 · 리뷰 크래시"
has   "9 드라이버 모양 행이 관측 칸과 함께 보인다 (무효화)" "$cone" \
      "warn${TAB}cone 막힘 D · 무효화 · 게이트 park · 종단 부류 산출물 없는 정지"
hasnt "9 뒤에 실행중 세그먼트 행이 있으면 숨는다" "$cone" "E 의 막힘"
hasnt "9 cone → park → 실행중 → park 이면 숨김이 유지된다" "$cone" "F 의 막힘"
check "9 같은 (주체, 사유) 두 행은 마지막만 남는다" \
  "$(printf '%s\n' "$cone" | grep -c '같은 사유' || true)" "1"
has   "9 그 남은 행이 마지막 행이다" "$cone" "cone 막힘 G · 재막힘 · 같은 사유"
has   "9 en_US 에서도 서로 다른 한글 사유가 둘 다 남는다 (하나)" "$cone" "cone 막힘 H · 막힘 · 자동 채택 미달"
has   "9 en_US 에서도 서로 다른 한글 사유가 둘 다 남는다 (둘)" "$cone" "cone 막힘 H · 막힘 · 강제 표면 이동"
check "9 세그먼트 행 없는 주체(판정 불가 별칭, 리뷰 지적 id)는 개수 한 줄이다" \
  "$(printf '%s\n' "$cone" | grep "^dim${TAB}" || true)" "dim${TAB}주체 미상 cone 막힘 2건"
hasnt "9 판정 불가 별칭은 낱줄로 나오지 않는다" "$cone" "B-alias"
hasnt "9 리뷰 지적 id 는 낱줄로 나오지 않는다" "$cone" "P1-3"
# The function's own verdict for the two, so the count above is not a count of
# something else.
unres=$(bash -c '. "$1"; cc_cone_blocked "$2"' _ "$LIVENESS" "$FX_LEDGER" \
          | awk -F'\t' '$1 == "unresolved" { print $2 }' | LC_ALL=C sort | tr '\n' ' ')
check "9 그 둘이 unresolved 다" "$unres" "B-alias P1-3 "

# ---------------------------------------------------------------------------
# 10. Line order: head, segments, approvals, run blocks, cone, orphans, and the
# overflow count last.
# ---------------------------------------------------------------------------
fx_mkrun pr-order; fx_ledger_path
fx_segment S1 실행중
fx_segment S2 머지됨
fx_approval A1 대기
fx_blocked "픽스처 차단" 불명
fx_cone_blocked 앵커 S1 막힘 "리뷰 크래시"
fx_cone_blocked 드라이버 P2-1 무효화 "게이트 park" "리뷰 지적"
fx_stage_dead S3
fx_heartbeat 0 5
fx_session_index s-order pr-order
out=$(pane s-order)
groups=$(body "$out" | awk -F'\t' '
  NR == 1                                        { print 0; next }
  $2 ~ /^(세그먼트 |끝나지 않은 세그먼트|끝난 세그먼트)/ { print 1; next }
  $2 ~ /^승인 대기/                                { print 2; next }
  $2 ~ /^run 막힘/                                 { print 3; next }
  $2 ~ /^(cone 막힘|주체 미상 cone)/               { print 4; next }
  $2 ~ /^고아 스테이지/                            { print 5; next }
  $2 ~ /^\+[0-9]+개 더$/                           { print 6; next }
                                                 { print "?" }
' | uniq | tr '\n' ' ')
check "10 줄 순서 — 머리, 세그먼트, 승인, run 막힘, cone, 고아 스테이지" "$groups" "0 1 2 3 4 5 "
check "10 세그먼트 묶음은 열린 줄 다음 끝난 개수 줄이다" \
  "$(body "$out" | sed -n '2,3p' | tr '\t\n' '::')" "normal:세그먼트 S1 실행중:dim:끝난 세그먼트 1개:"
has "10 승인 줄은 id 와 절단점을 싣는다" "$(body "$out")" "accent${TAB}승인 대기 A1 · 절단점 경계"
has "10 고아 스테이지 줄" "$(body "$out")" "warn${TAB}고아 스테이지 S3"
# And the overflow count goes after everything, cutting the tail.
groups=$(body "$(pane s-captail)" | awk -F'\t' '
  NR == 1 { print 0; next } $2 ~ /^\+[0-9]+개 더$/ { print 6; next } { print "x" }' \
  | uniq | tr '\n' ' ')
check "10 +N개 더 는 맨 끝이다" "$groups" "0 x 6 "

# ---------------------------------------------------------------------------
# 6. The contract, over every output this suite produced above.
# ---------------------------------------------------------------------------
# Each property is one assertion over the whole set; a breach names the output
# that broke it.
n_outs=0; e_head=""; e_refresh=""; e_idx=""; e_len=""; e_tone=""; classes=""
for f in "$OUTS"/*; do
  [ -f "$f" ] || continue
  n_outs=$((n_outs + 1))
  o=$(cat "$f"); name=$(basename "$f")
  [ "$(valid_head "$o")" = "yes" ] || e_head="$e_head $name"
  cls=$(hfield "$o" 3); idxf=$(hfield "$o" 5); rf=$(hfield "$o" 6)
  classes="$classes $cls"
  case "$cls:$rf" in
    live:10000|ended:60000|none:60000) ;;
    *) e_refresh="$e_refresh $name($cls:$rf)" ;;
  esac
  case "$idxf" in -|/*) ;; *) e_idx="$e_idx $name($idxf)" ;; esac
  nb=$(body_n "$o")
  { [ "$nb" -ge 1 ] && [ "$nb" -le 15 ]; } || e_len="$e_len $name($nb)"
  nt=$(body "$o" | grep -cvE "^(normal|dim|ok|warn|error|accent)${TAB}" || true)
  [ "$nt" = "0" ] || e_tone="$e_tone $name"
done
check "6 머리 행이 여섯 칸이고 스키마가 1 이다" "$e_head" ""
check "6 refresh_ms 는 live 에서 10000, 그 밖에서 60000 이다" "$e_refresh" ""
check "6 세션 목록 칸은 - 이거나 절대 경로다" "$e_idx" ""
check "6 본문은 1–15줄이다" "$e_len" ""
check "6 본문 줄은 모두 <tone><TAB><text> 이고 tone 이 집합 안이다" "$e_tone" ""
# The set has to have held all three classes, or the refresh rule was checked
# against only some of them.
for c in live ended none; do
  case "$classes " in
    *" $c "*) ok "6 규약 검사가 $c 출력을 읽었다" ;;
    *)        bad "6 규약 검사" "$c 출력이 하나도 없다" ;;
  esac
done
[ "$n_outs" -ge 20 ] && ok "6 규약 검사가 실제로 출력 ${n_outs}개를 읽었다" \
  || bad "6 규약 검사" "읽은 출력이 ${n_outs}개뿐이다"

# ---------------------------------------------------------------------------
# 8. Nothing is written: the state tree's file list and mtimes are unchanged
# across a pass over every session above. Sub-second mtimes, so a rewrite of
# the same bytes inside one second is still seen.
# ---------------------------------------------------------------------------
tree_snap() {
  find "$XDG_STATE_HOME" -print 2>/dev/null | LC_ALL=C sort \
    | perl -MTime::HiRes=lstat -ne 'chomp; my @s = lstat($_); printf "%s %s\n", $_, (@s ? $s[9] : "gone");'
}
before=$(tree_snap)
for s in s-run1 s-run0 s-prog s-appr s-stall s-done s-aband s-block s-demote \
         s-noindex s-empty s-gone s-oldid s-capseg s-captail s-nolp s-cone s-order; do
  bash "$PANE" "$s" >/dev/null 2>&1
done
after=$(tree_snap)
check "8 쓰기 없음 — 실행 전후 상태 트리의 파일 목록과 mtime 이 같다" "$after" "$before"
[ "$(printf '%s\n' "$before" | grep -c .)" -gt 20 ] \
  && ok "8 비교한 트리가 비어 있지 않다" || bad "8 쓰기 없음" "스냅숏이 비었다"

printf '\n통과 %s · 실패 %s · 건너뜀 %s\n' "$passed" "$failed" "$skipped"
[ "$failed" -eq 0 ]
