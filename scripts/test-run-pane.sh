#!/usr/bin/env bash
# Test `run-pane.sh`, the helper behind the autopilot status pane.
#
# THE HELPER IS WHERE EVERY JUDGEMENT THE PANE SHOWS IS MADE — the run, its
# class, the wording, the order, the tone, what is dropped when the dock is
# short, and the refresh — and the plugin test harness cannot start a process,
# so the mod's own tests feed it canned output. This suite is therefore the
# only place the real helper meets a real run directory, and it holds the
# helper to the unchanged `statusline.sh` rather than to a copy of its rules.
#
# WORDS FROM THE LEDGER ARE COMPARED EXACTLY, WORDS FROM THE CLOCK BY SHAPE. A
# start time is `now − etime` and an age is `now − mtime`; the suite and the
# helper read `now` at different instants, so those are held to a pattern (or
# to the pair of instants that bracket the run), never to bytes.
#
# Usage: bash scripts/test-run-pane.sh

set -uo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
PANE="$repo_root/plugins/cc-cmds/orchestrator/run-pane.sh"
SL="$repo_root/plugins/cc-cmds/orchestrator/statusline.sh"
LIVENESS="$repo_root/plugins/cc-cmds/orchestrator/liveness.sh"
MOD_TEST="$repo_root/plugins/cc-cmds/hooks/autopilot-status.test.ts"
REPLAY="$repo_root/tests/fixtures/run-pane-replay/20261006-ef0ccf94"
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
like() { if printf '%s' "$2" | grep -qE -- "$3"; then ok "$1"; else bad "$1" "'$2' 이 /$3/ 에 맞지 않음"; fi; }

TAB=$(printf '\t')
SESSION_DIR="$XDG_STATE_HOME/cc-cmds/session"
OUTS="$WORK/outs"
mkdir -p "$OUTS"

# pane <sid> [args] — run the helper; every output is also kept for the
# contract pass, with the cap and width it was asked for beside it. Each call
# runs inside a command substitution, so a counter here would never leave its
# subshell; the file name comes from `mktemp` instead.
pane() {
  local out f cap=24 cols=44 a prev=""
  for a in "$@"; do
    case "$prev" in
      --rows) case "$a" in ""|*[!0-9]*) ;; *) [ "$a" -gt 0 ] && [ "$a" -lt 24 ] && cap=$a ;; esac ;;
      --cols) case "$a" in ""|*[!0-9]*) ;; *) [ "$a" -gt 0 ] && cols=$a ;; esac ;;
    esac
    prev=$a
  done
  out=$(bash "$PANE" "$@")
  f=$(mktemp "$OUTS/o.XXXXXX")
  printf '%s\n' "$out" > "$f"
  printf '%s %s\n' "$cap" "$cols" > "$f.dim"
  printf '%s' "$out"
}
head_row() { printf '%s\n' "$1" | head -1; }
hfield()   { head_row "$1" | cut -f"$2"; }
body()     { printf '%s\n' "$1" | awk 'NR > 1'; }
body_n()   { body "$1" | grep -c . || true; }
bundles()  { body "$1" | cut -f1 | tr '\n' ' '; }
# brow <out> <bundle> — the first row of that bundle; brows — all of them.
brow()     { body "$1" | awk -F'\t' -v b="$2" '$1 == b { print; exit }'; }
brows()    { body "$1" | awk -F'\t' -v b="$2" '$1 == b'; }
# rtext <row> — the row's text with its fragments joined, tones dropped.
rtext()    { printf '%s' "$1" | awk -F'\t' '{ s = ""; for (i = 4; i <= NF; i += 2) s = s $i; printf "%s", s }'; }
# segrow <out> <id> — the `seg` row of that segment; segdetail — the detail
# row right after it, or empty.
segrow()   { body "$1" | awk -F'\t' -v s="$2" '$1 == "seg" && $NF ~ (" " s " ") { print; exit }'; }
segdetail(){ body "$1" | awk -F'\t' -v s="$2" '
               hit { if ($1 == "seg-detail") print; exit }
               $1 == "seg" && $NF ~ (" " s " ") { hit = 1 }'; }
# The status line as the helper calls it: the session id on stdin, nothing else.
sl_line()  { printf '{"session_id":"%s"}' "$1" | bash "$SL" 2>/dev/null; }
tok()      { printf '%s' "$1" | cut -d' ' -f"$2"; }
gm_hhmm()  { perl -e 'my @t = gmtime($ARGV[0]); printf "%02d:%02d", $t[2], $t[1];' "$1"; }

# ---------------------------------------------------------------------------
# 1. The head, arm by arm.
#
# The glyph is the status line's own first token and the word is the arm word
# its fields row carries. Each arm is pinned to its glyph as well as compared,
# because a helper and a status line that both printed the fallback would agree
# with each other and say nothing about the arm.
# ---------------------------------------------------------------------------
branch_case() {
  # branch_case <label> <sid> <glyph> <class> <word>
  local label="$1" sid="$2" want_g="$3" want_c="$4" want_w="$5" out sl h
  out=$(pane "$sid"); sl=$(sl_line "$sid")
  h=$(rtext "$(brow "$out" head)")
  check "1 $label — 상태 표시줄이 그 갈래 글리프를 낸다 (전제)" "$(tok "$sl" 1)" "$want_g"
  check "1 $label — head 글리프가 상태 표시줄과 같다" "$(tok "$h" 1)" "$(tok "$sl" 1)"
  check "1 $label — head 단어가 갈래 단어다" "$(tok "$h" 2)" "$want_w"
  check "1 $label — 머리 행의 런 id 가 상태 표시줄의 둘째 토큰이다" "$(hfield "$out" 4)" "$(tok "$sl" 2)"
  check "1 $label — title 이 그 런 id 다" "$(rtext "$(brow "$out" title)")" "autopilot $(tok "$sl" 2)"
  like  "1 $label — title 은 굵은 색조다" "$(brow "$out" title | cut -f3)" '\.b$'
  check "1 $label — 부류" "$(hfield "$out" 3)" "$want_c"
}

fx_mkrun pr-run1; fx_ledger_path; fx_segment S1 실행중; fx_stage_live S1; fx_heartbeat 0 5
fx_session_index s-run1 pr-run1
branch_case "도는중 (스테이지 칸)" s-run1 "⟳" live 도는중
out=$(pane s-run1)
check "1 도는중 (스테이지 칸) — 그 세그먼트가 실행중이다" "$(segrow "$out" S1)" \
  "seg${TAB}cut${TAB}accent${TAB}⟳${TAB}normal${TAB} S1 실행중"
# The first attempt with no `.kind`, no `.attempt` and no earlier stage-result:
# no empty slot and no `회차` without a number.
like "15 첫 회차 — 실행중 세부는 시작 시각뿐이다" "$(segdetail "$out" S1)" \
  "^seg-detail${TAB}cut${TAB}dim${TAB}   [0-9][0-9]:[0-9][0-9]Z 시작\$"

# The only live pid is the watcher's: the count takes it and the slot does not.
fx_mkrun pr-run0; fx_ledger_path; fx_segment S1 실행중; fx_stage_live watch; fx_heartbeat 0 5
fx_session_index s-run0 pr-run0
branch_case "도는중 (스테이지 칸 없음)" s-run0 "⟳" live 도는중
has "1 도는중 (스테이지 칸 없음) — head-detail 에 원장 칸이 있다" \
  "$(rtext "$(brow "$(pane s-run0)" head-detail)")" "원장 "

fx_mkrun pr-prog; fx_ledger_path; fx_segment S1 실행중; fx_heartbeat 0 5
fx_session_index s-prog pr-prog
branch_case "진행중" s-prog "⟳" live 진행중

fx_mkrun pr-appr; fx_ledger_path; fx_segment S1 실행중; fx_approval A1 대기; fx_heartbeat 0 5
fx_session_index s-appr pr-appr
branch_case "승인대기" s-appr "⏸" live 승인대기

fx_mkrun pr-stall; fx_ledger_path; fx_segment S1 실행중; fx_heartbeat 0 200
fx_session_index s-stall pr-stall
branch_case "정지경고" s-stall "⚠" live 정지경고

fx_mkrun pr-done; fx_ledger_path; fx_segment S1 머지됨; fx_heartbeat 0 5
fx_session_index s-done pr-done
branch_case "종단" s-done "✓" ended 종료

# The same merged segment on a run that ends on `done`: the settlement window,
# which keeps the run on the live glyph instead of the finished one.
fx_mkrun pr-settle; fx_ledger_path; fx_segment S1 머지됨; fx_heartbeat 0 5
printf '1\n' > "$FX_RUN_DIR/ends-on-done"
fx_session_index s-settle pr-settle
branch_case "정산중" s-settle "⟳" live 정산중

fx_mkrun pr-aband; fx_ledger_path; fx_segment S1 실행중; fx_heartbeat 0 4000
fx_session_index s-aband pr-aband
branch_case "버려짐 (방치)" s-aband "⊘" ended 방치

fx_mkrun pr-block; fx_ledger_path; fx_segment S1 실행중; fx_blocked "픽스처 차단" 불명; fx_heartbeat 0 4000
fx_session_index s-block pr-block
branch_case "버려짐 (차단)" s-block "⊘" ended 차단

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
check "3 강등된 승인대기 — head 는 ⏸" "$(tok "$(rtext "$(brow "$out" head)")" 1)" "⏸"
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
  check "4 $1 — 본문은 연결된 런 없음 한 줄" "$(body "$out")" "none${TAB}cut${TAB}dim${TAB}연결된 런 없음"
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
# 6. The cap and the reduction. Inflating the segments folds the open ones and
# keeps the block rows and the segment that holds a block; inflating the
# approvals keeps every approval past the cap; nothing anywhere counts what it
# dropped.
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
has   "6 세그먼트만 부풀림 — 열린 세그먼트가 개수 한 줄로 접힌다" "$b" \
      "seg-folded${TAB}cut${TAB}normal${TAB}끝나지 않은 세그먼트 19개"
check "6 세그먼트만 부풀림 — 막힘을 붙잡은 S01 의 seg 행은 남는다" "$(segrow "$out" S01)" \
      "seg${TAB}cut${TAB}error${TAB}▲${TAB}normal${TAB} S01 실행중"
check "6 세그먼트만 부풀림 — 그 밖의 세그먼트 낱줄은 남지 않는다" "$(brows "$out" seg | grep -c . || true)" "1"
has   "6 세그먼트만 부풀림 — run 막힘 제목이 남는다" "$b" "block-heading${TAB}cut${TAB}error.b${TAB}▲ 막힘 · run · 불명"
has   "6 세그먼트만 부풀림 — run 막힘 사유가 남는다" "$b" "block-reason${TAB}wrap${TAB}normal${TAB}픽스처 차단"
has   "6 세그먼트만 부풀림 — cone 막힘 제목이 남는다" "$b" \
      "block-heading${TAB}cut${TAB}error.b${TAB}▲ 막힘 · cone S01 · 사람 결정 필요"
has   "6 세그먼트만 부풀림 — cone 막힘 사유가 남는다" "$b" "block-reason${TAB}wrap${TAB}normal${TAB}리뷰 크래시"
hasnt "6 세그먼트만 부풀림 — 잘린 수를 세는 꼬리가 없다" "$b" "개 더"
check "6 세그먼트만 부풀림 — 본문 열 줄" "$(body_n "$out")" "10"
check "6 세그먼트만 부풀림 — 이벤트와 빈 줄이 먼저 빠졌다" "$(bundles "$out")" \
      "title head head-detail seg-heading seg seg-folded block-heading block-reason block-heading block-reason "

fx_mkrun pr-captail; fx_ledger_path; fx_segment S1 실행중
for i in 01 02 03 04 05 06 07 08 09 10 11 12 13 14 15 16 17 18 19 20; do
  fx_approval "A$i" 대기
done
fx_heartbeat 0 5
fx_session_index s-captail pr-captail
out=$(pane s-captail)
check "6 승인 부풀림 — 승인 스무 줄이 모두 남는다" "$(brows "$out" approval | grep -c . || true)" "20"
hasnt "6 승인 부풀림 — 잘린 수를 세는 꼬리가 없다" "$(body "$out")" "개 더"
check "6 승인 부풀림 — 보호 줄과 고정 줄만 남는다 (25)" "$(body_n "$out")" "25"

# Finished segments fold first; a park segment and a merged segment that still
# owes its apply are not finished and stay out of that fold.
fx_mkrun pr-fold; fx_ledger_path
for i in 01 02 03 04 05 06 07 08 09 10; do fx_segment "D$i" 머지됨; done
fx_segment P park
fx_row 'segment' "id=M" "상태=머지됨" "적용=대기" "워크트리=$FX_RUN_DIR"
fx_segment O 실행중
fx_heartbeat 0 5
fx_session_index s-fold pr-fold
out=$(pane s-fold --rows 12)
has   "6 끝난 세그먼트 접기 — 개수 한 줄" "$(body "$out")" "seg-folded${TAB}cut${TAB}dim${TAB}끝난 세그먼트 10개"
check "6 끝난 세그먼트 접기 — park 세그먼트는 접히지 않는다" "$(segrow "$out" P)" \
      "seg${TAB}cut${TAB}dim${TAB}⊘${TAB}normal${TAB} P park"
check "6 끝난 세그먼트 접기 — 적용=대기 인 머지됨은 열림이다" "$(segrow "$out" M)" \
      "seg${TAB}cut${TAB}dim${TAB}·${TAB}normal${TAB} M 머지됨"
check "6 끝난 세그먼트 접기 — 상한 안이다" "$(body_n "$out")" "11"
out=$(pane s-fold)
check "6 상한 안에서는 끝난 세그먼트가 접히지 않는다" "$(brows "$out" seg-folded | grep -c . || true)" "0"

# ---------------------------------------------------------------------------
# 7. Total: exit 0 and a valid head row on every degraded input.
# ---------------------------------------------------------------------------
valid_head() {
  # valid_head <out> — `yes` when the head row has the contract's shape.
  local h; h=$(head_row "$1")
  case "$h" in
    "cc-pane${TAB}2${TAB}"*) ;;
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
check "7 jq 독 — exit 0" "$rc" "0"
check "7 jq 독 — 유효한 머리 행" "$(valid_head "$out")" "yes"
check "7 jq 독 — 런을 그대로 해소한다" "$(hfield "$out" 4)" "pr-prog"
check "7 jq 독 — v2 본문을 온전히 낸다" "$(bundles "$out")" "$(bundles "$(bash "$PANE" s-prog)")"
hasnt "7 jq 독 — jq 를 부르지 않는다" "$out" "JQ-WAS-CALLED"

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
check "7 ledger-path 없음 — 본문은 title 과 head 뿐이다" "$(bundles "$out")" "title head "

mkdir -p "$WORK/lone"
cp "$PANE" "$WORK/lone/"
out=$(bash "$WORK/lone/run-pane.sh" s-prog); rc=$?
check "7 형제 스크립트 없음 — exit 0" "$rc" "0"
check "7 형제 스크립트 없음 — 유효한 머리 행" "$(valid_head "$out")" "yes"
check "7 형제 스크립트 없음 — 상태 표시줄이 없으면 none" "$(hfield "$out" 3)" "none"

# The status line cannot pick a run without its own `liveness.sh`, so the one
# beside this copy hands over to the real one; only the helper's sibling is
# missing.
mkdir -p "$WORK/noliveness"
cp "$PANE" "$WORK/noliveness/"
printf '#!/usr/bin/env bash\nexec bash %s\n' "'$SL'" > "$WORK/noliveness/statusline.sh"
out=$(bash "$WORK/noliveness/run-pane.sh" s-prog); rc=$?
check "7 liveness.sh 없음 — exit 0" "$rc" "0"
check "7 liveness.sh 없음 — 유효한 머리 행" "$(valid_head "$out")" "yes"
check "7 liveness.sh 없음 — 본문은 title 과 head 뿐이다" "$(bundles "$out")" "title head "

# A status line that prints no fields row: the run id comes from the human
# line's second token, the head carries that line as it is, and nothing that
# needs the fields row's clock is filled from another one.
mkdir -p "$WORK/nofields"
cp "$PANE" "$LIVENESS" "$WORK/nofields/"
printf '#!/usr/bin/env bash\nunset CC_SL_PANE_FIELDS\nexec bash %s\n' "'$SL'" > "$WORK/nofields/statusline.sh"
fx_mkrun pr-nof; fx_ledger_path; fx_segment S1 실행중; fx_stage_live S1; fx_stage_meta S1 implement 2
fx_row 'cost' "누적 usd=1.5" "스테이지 수=0" "관측 시각=2026-10-06T07:00:00Z"
fx_heartbeat 0 5
fx_session_index s-nof pr-nof
out=$(bash "$WORK/nofields/run-pane.sh" s-nof); rc=$?
check "7 필드 행 없음 — exit 0" "$rc" "0"
check "7 필드 행 없음 — 런 id 는 사람용 줄의 둘째 토큰이다" "$(hfield "$out" 4)" "pr-nof"
check "7 필드 행 없음 — title" "$(brow "$out" title)" "title${TAB}cut${TAB}accent.b${TAB}autopilot pr-nof"
like  "7 필드 행 없음 — head 는 사람용 줄 그대로다" "$(brow "$out" head)" \
      "^head${TAB}cut${TAB}normal${TAB}⟳ pr-nof S1 implement [0-9:]+"
check "7 필드 행 없음 — head-detail 은 비용 칸뿐이다" "$(brow "$out" head-detail)" \
      "head-detail${TAB}cut${TAB}dim${TAB}\$1.50"
check "7 필드 행 없음 — 실행중 세부에 시작 시각이 없다" "$(segdetail "$out" S1)" \
      "seg-detail${TAB}cut${TAB}dim${TAB}   implement 2회차"

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
cone=$(body "$out" | awk -F'\t' '$1 == "block-heading" || $1 == "block-reason" || $1 == "cone-unresolved"')
has   "9 앵커 행의 제목" "$cone" "block-heading${TAB}cut${TAB}error.b${TAB}▲ 막힘 · cone C · 사람 결정 필요"
has   "9 앵커 행의 사유" "$cone" "block-reason${TAB}wrap${TAB}normal${TAB}리뷰 크래시"
has   "9 드라이버 모양 행의 제목 (무효화)" "$cone" "block-heading${TAB}cut${TAB}error.b${TAB}▲ 막힘 · cone D · 무효화"
has   "9 드라이버 모양 행의 사유는 관측 칸과 함께다" "$cone" \
      "block-reason${TAB}wrap${TAB}normal${TAB}게이트 park · 종단 부류 산출물 없는 정지"
hasnt "9 뒤에 실행중 세그먼트 행이 있으면 숨는다" "$cone" "E 의 막힘"
hasnt "9 cone → park → 실행중 → park 이면 숨김이 유지된다" "$cone" "F 의 막힘"
check "9 같은 (주체, 사유) 두 행은 마지막만 남는다" \
  "$(printf '%s\n' "$cone" | grep -c '같은 사유' || true)" "1"
has   "9 그 남은 행이 마지막 행이다" "$cone" "▲ 막힘 · cone G · 재막힘"
has   "9 en_US 에서도 서로 다른 한글 사유가 둘 다 남는다 (하나)" "$cone" "${TAB}자동 채택 미달"
has   "9 en_US 에서도 서로 다른 한글 사유가 둘 다 남는다 (둘)" "$cone" "${TAB}강제 표면 이동"
check "9 세그먼트 행 없는 주체(판정 불가 별칭, 리뷰 지적 id)는 개수 한 줄이다" \
  "$(printf '%s\n' "$cone" | awk -F'\t' '$1 == "cone-unresolved"')" \
  "cone-unresolved${TAB}cut${TAB}dim${TAB}주체 미상 cone 막힘 2건"
hasnt "9 판정 불가 별칭은 낱줄로 나오지 않는다" "$cone" "B-alias"
hasnt "9 리뷰 지적 id 는 낱줄로 나오지 않는다" "$cone" "P1-3"
check "9 막힘이 서 있으면 막힘 없음 요약이 없다" "$(brow "$out" gate-none)" ""
# The function's own verdict for the two, so the count above is not a count of
# something else.
unres=$(bash -c '. "$1"; cc_cone_blocked "$2"' _ "$LIVENESS" "$FX_LEDGER" \
          | awk -F'\t' '$1 == "unresolved" { print $2 }' | LC_ALL=C sort | tr '\n' ' ')
check "9 그 둘이 unresolved 다" "$unres" "B-alias P1-3 "

# ---------------------------------------------------------------------------
# 10. Row order: title, head, segments, then the gate in its own order —
# approvals, run blocks, cone blocks, the unresolved count, orphans — then the
# events.
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
check "10 묶음 순서" "$(bundles "$out" | tr ' ' '\n' | uniq | tr '\n' ' ')" \
  "title head head-detail gap seg-heading seg gap approval block-heading block-reason block-heading block-reason cone-unresolved orphan gap event-heading event "
check "10 세그먼트 묶음 — 막힘을 붙잡은 S1 이 먼저, 끝난 S2 가 다음" \
  "$(brows "$out" seg | cut -f4,6 | tr '\t\n' '::')" "▲: S1 실행중:✓: S2 머지됨:"
check "10 승인 줄은 id 와 절단점을 싣는다" "$(brow "$out" approval)" \
  "approval${TAB}cut${TAB}accent${TAB}승인 대기 A1 · 절단점 경계"
check "10 run 막힘 제목이 cone 막힘 제목과 같은 꼴이다" \
  "$(brows "$out" block-heading | cut -f4 | tr '\n' '|')" \
  "▲ 막힘 · run · 불명|▲ 막힘 · cone S1 · 사람 결정 필요|"
check "10 고아 스테이지 줄" "$(brow "$out" orphan)" "orphan${TAB}cut${TAB}warn${TAB}고아 스테이지 S3"
check "10 막힘이 서 있으면 막힘 없음 요약이 없다" "$(brow "$out" gate-none)" ""

# The protected rows survive a cap far below them.
out=$(pane s-order --rows 8)
check "6 --rows 8 — 보호 줄이 모두 남는다" \
  "$(body "$out" | awk -F'\t' '$1 ~ /^(title|head|head-detail|approval|block-heading|block-reason|cone-unresolved|orphan)$/' | cut -f1 | tr '\n' ' ')" \
  "title head head-detail approval block-heading block-reason block-heading block-reason cone-unresolved orphan "
check "6 --rows 8 — 막힘을 붙잡은 세그먼트 줄이 남는다" "$(segrow "$out" S1 | cut -f4)" "▲"
check "6 --rows 8 — 이벤트가 먼저 빠졌다" "$(brows "$out" event | grep -c . || true)" "0"
has   "6 --rows 8 — 끝난 세그먼트가 접혔다" "$(body "$out")" "seg-folded${TAB}cut${TAB}dim${TAB}끝난 세그먼트 1개"

# ---------------------------------------------------------------------------
# 11. Replay of the 20261006-ef0ccf94 ledger, cut at two ledger times.
#
# The cut is the last row whose first ISO time is at or before the instant,
# computed here, so the excerpt can be thinned without moving the cut. The
# words that come from the ledger are compared exactly; the start time and the
# ages by shape.
# ---------------------------------------------------------------------------
replay_cut() {
  # replay_cut <file> <ISO> — the line number of that last row.
  LC_ALL=C awk -v th="$2" '
    match($0, /[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z/) {
      if (substr($0, RSTART, RLENGTH) <= th) last = NR
    }
    END { print last + 0 }' "$1"
}
replay_run() {
  # replay_run <lines> — a fresh run directory holding that prefix. The last
  # cut's stage is stopped and reaped here, so the shell has no job left to
  # announce.
  local p
  for p in ${FX_PIDS:-}; do kill "$p" 2>/dev/null; wait "$p" 2>/dev/null; done
  FX_PIDS=""
  rm -rf "$XDG_STATE_HOME/cc-cmds/run/20261006-ef0ccf94"
  fx_mkrun 20261006-ef0ccf94
  head -n "$1" "$REPLAY.md" > "$FX_LEDGER"
  fx_ledger_path
  fx_manifest_target cc-cmds 머지
  fx_session_index s-replay 20261006-ef0ccf94
}

c1=$(replay_cut "$REPLAY.md" 2026-10-06T07:51:30Z)
c2=$(replay_cut "$REPLAY.md" 2026-10-06T08:07:00Z)
check "11 절단 1 은 관측 시각 07:37:52Z 행이다" "$(awk -v n="$c1" 'NR == n' "$REPLAY.md" | grep -c 'cost.*관측 시각=2026-10-06T07:37:52Z' || true)" "1"
check "11 절단 2 는 기록 시각 08:04:35Z 행이다" "$(awk -v n="$c2" 'NR == n' "$REPLAY.md" | grep -c 'handoff.*기록 시각=2026-10-06T08:04:35Z' || true)" "1"
for c in "$c1" "$c2"; do
  n_auto=$(head -n "$c" "$REPLAY.md" | grep -c '^- `자율 승인`' || true)
  [ "$n_auto" -ge 1 ] && ok "11 절단 ${c}행에 남긴 자율 승인 행이 있다 ($n_auto)" \
    || bad "11 절단 ${c}행" "자율 승인 행이 없다"
done

replay_run "$c1"
fx_heartbeat 41 9; fx_stage_live B; fx_stage_meta B implement 2
r1=$(pane s-replay --cols 44 --rows 24)
check "11 절단 1 — 묶음 순서 (19줄)" "$(bundles "$r1")" \
  "title head head-detail gap seg-heading seg seg-detail seg seg-detail gap gate-none gap event-heading event event event event event event "
check "11 절단 1 — title" "$(brow "$r1" title)" "title${TAB}cut${TAB}accent.b${TAB}autopilot 20261006-ef0ccf94"
check "11 절단 1 — head" "$(brow "$r1" head)" \
  "head${TAB}cut${TAB}accent.b${TAB}⟳ 도는중${TAB}normal${TAB}  교대 3 · cc-cmds · 절단점 머지"
check "11 절단 1 — head-detail" "$(brow "$r1" head-detail)" \
  "head-detail${TAB}cut${TAB}dim${TAB}원장 1분 안 · 워처 ♥ 1분 안 · \$56.38"
check "11 절단 1 — A 세그먼트" "$(segrow "$r1" A)" "seg${TAB}cut${TAB}ok${TAB}✓${TAB}normal${TAB} A 머지됨"
check "11 절단 1 — 머지된 A 의 세부" "$(segdetail "$r1" A)" \
  "seg-detail${TAB}cut${TAB}dim${TAB}   리뷰 3회차 P0 0 · P1 0 · PR #1115 통과"
check "11 절단 1 — B 세그먼트" "$(segrow "$r1" B)" "seg${TAB}cut${TAB}accent${TAB}⟳${TAB}normal${TAB} B 실행중"
like  "11 절단 1 — B 의 실행중 세부" "$(segdetail "$r1" B)" \
  "^seg-detail${TAB}cut${TAB}dim${TAB}   implement 2회차 · [0-2][0-9]:[0-5][0-9]Z 시작 · 선행 A\$"
check "11 절단 1 — 관문" "$(brow "$r1" gate-none)" "gate-none${TAB}cut${TAB}dim${TAB}승인 대기 없음 · 막힘 없음"
check "11 절단 1 — 이벤트" "$(brows "$r1" event | cut -f4,6 | tr '\t' ' ')" \
"07:37  비용 누적 \$56.38 · 스테이지 6
07:37  B implement 1회차 · rc 0
07:31  체크 PR #1115 통과
07:22  체크 PR #1115 대기
07:18  A 리뷰 3회차 · P0 0 · P1 0
07:18  A review 5회차 · rc 0"
hasnt "11 절단 1 — 자율 승인은 이벤트가 아니다" "$(brows "$r1" event)" "자율"
r1_bundles=$(body "$r1" | cut -f1)

# The committed manifest says the same thing as the fixture helper's.
cp "$REPLAY.plan.md" "$(dirname "$FX_LEDGER")/20261006-ef0ccf94.plan.md"
check "11 커밋한 매니페스트로도 head 가 같다" "$(brow "$(bash "$PANE" s-replay)" head)" "$(brow "$r1" head)"

replay_run "$c2"
fx_heartbeat 38 240
r2=$(pane s-replay --cols 44 --rows 24)
check "11 절단 2 — 묶음 순서" "$(bundles "$r2")" \
  "title head head-detail gap seg-heading seg seg-detail seg seg-detail gap block-heading block-reason gap event-heading event event event "
check "11 절단 2 — head" "$(brow "$r2" head)" \
  "head${TAB}cut${TAB}warn.b${TAB}⚠ 정지경고${TAB}normal${TAB}  교대 3 · cc-cmds · 절단점 머지"
check "11 절단 2 — head-detail" "$(brow "$r2" head-detail)" \
  "head-detail${TAB}cut${TAB}dim${TAB}원장 4분 전 · 워처 ♥ 1분 안 · \$66.42"
check "11 절단 2 — 머지된 A 의 세부" "$(segdetail "$r2" A)" \
  "seg-detail${TAB}cut${TAB}dim${TAB}   리뷰 3회차 P0 0 · P1 0 · PR #1115 통과"
check "11 절단 2 — 막힘을 붙잡은 B" "$(segrow "$r2" B)" "seg${TAB}cut${TAB}error${TAB}▲${TAB}normal${TAB} B 계획됨"
check "11 절단 2 — B 의 세부" "$(segdetail "$r2" B)" "seg-detail${TAB}cut${TAB}dim${TAB}   implement 2회차 · 의도된 park"
check "11 절단 2 — 막힘 제목" "$(brow "$r2" block-heading)" \
  "block-heading${TAB}cut${TAB}error.b${TAB}▲ 막힘 · cone B · 사람 결정 필요"
reason=$(awk -v n="$c2" 'NR <= n && /^- `blocked`/ && /앵커 세그먼트=B/' "$REPLAY.md" | tail -1 \
           | tr '|' '\n' | awk '/^ 사유=/ { sub(/^ 사유=/, ""); sub(/ +$/, ""); print }')
check "11 절단 2 — 막힘 사유는 원장 원문 그대로 한 wrap 행이다" "$(brow "$r2" block-reason)" \
  "block-reason${TAB}wrap${TAB}normal${TAB}$reason"
est=$(printf '%s' "$reason" | bash "$PANE" --estimate 44)
check "11 절단 2 — 사유의 추정 줄 수는 8 이다" "$est" "8"
check "11 절단 2 — 고정 13줄과 사유가 이벤트 $((24 - 13 - est))개를 남긴다" \
  "$(brows "$r2" event | grep -c . || true)" "$((24 - 13 - est))"
check "11 절단 2 — 이벤트" "$(brows "$r2" event | cut -f4,6 | tr '\t' ' ')" \
"08:03  막힘 cone B 기록
08:03  비용 누적 \$66.42 · 스테이지 7
08:03  B implement 2회차 · rc 0 · park"
has "11 --cols 30 은 같은 사유를 더 많은 줄로 센다" \
  "$([ "$(printf '%s' "$reason" | bash "$PANE" --estimate 30)" -gt "$est" ] && echo yes || echo no)" "yes"

# ---------------------------------------------------------------------------
# 12. The mod's recorded sample holds the same bundles as the replay. The mod
# test cannot run here and CI does not run it, so this is where a stale sample
# shows.
# ---------------------------------------------------------------------------
sample=$(awk -v q="'" '
  /\/\/ cc-pane-replay-cut-1:begin/ { on = 1; next }
  /\/\/ cc-pane-replay-cut-1:end/   { on = 0 }
  on {
    p = index($0, q); if (p == 0) next
    r = substr($0, p + 1); e = index(r, "\\t"); if (e == 0) next
    b = substr(r, 1, e - 1); if (b != "cc-pane") print b
  }' "$MOD_TEST" 2>/dev/null || true)
if [ -n "$sample" ]; then
  check "12 mod 시험의 재생 표본 묶음 열이 절단 1 출력과 같다" "$sample" "$r1_bundles"
else
  bad "12 mod 시험의 재생 표본" "$MOD_TEST 에 cc-pane-replay-cut-1 표본이 없다"
fi

# ---------------------------------------------------------------------------
# 13. Event times and words on synthetic ledgers.
# ---------------------------------------------------------------------------
sr() {
  # sr <version> [field...] — a gate-shaped stage-result for segment X.
  local v="$1"; shift
  fx_row 'stage-result' "세그먼트=X" "스테이지=X" "종류=implement" "종료 코드=0" "실행 버전=$v" "$@"
}

# Pairs: two stages ending together, a stage that ended with no cost and a
# later cost that names it, and a lost dispatch settlement with its own time.
fx_mkrun pr-ev2; fx_ledger_path; fx_segment X 실행중
fx_row 'blocked' "대상=-" "스코프=run" "원인=불명" "사유=t" "관측=2026-10-06T01:00:00Z"
sr 1 "종단 부류=정상 완료"
sr 2 "종단 부류=정상 완료"
fx_row 'cost' "누적 usd=2" "스테이지 수=2" "관측 시각=2026-10-06T02:00:00Z"
fx_row 'cost' "누적 usd=2.5" "스테이지 수=2" "관측 시각=2026-10-06T02:01:00Z"
sr 3 "종단 부류=정상 완료"
sr 4 "종단 부류=정상 완료"
fx_row 'cost' "누적 usd=3" "스테이지 수=3" "관측 시각=2026-10-06T03:00:00Z"
fx_row 'stage-result' "세그먼트=X" "스테이지=X" "종류=implement" "종료 코드=-" "실행 버전=5" \
  "종단 부류=외부 종료" "관측=파견 기록이 프로세스보다 오래 살았고 종단 result 줄이 없다 — 정산 시각 2026-10-06T04:00:00Z"
fx_heartbeat 0 5
fx_session_index s-ev2 pr-ev2
out=$(pane s-ev2)
check "13 짝 규칙 — 최신부터 여섯, 가장 새 비용 하나만" "$(brows "$out" event | cut -f4,6 | tr '\t' ' ')" \
"04:00  X implement 5회차 · 외부 종료
03:00  비용 누적 \$3.00 · 스테이지 3
02:01  X implement 4회차 · rc 0
03:00  X implement 3회차 · rc 0
02:00  X implement 2회차 · rc 0
01:00  X implement 1회차 · rc 0"

# The driver's cost has no stage count, approvals open and settle, a run block
# resolves, a `자율 승인` row is never an event, and the oldest event falls
# past the six.
fx_mkrun pr-ev1; fx_ledger_path; fx_segment X 실행중
sr 1
fx_row 'blocked' "대상=-" "스코프=run" "원인=불명" "사유=t" "관측=2026-10-06T01:00:00Z"
sr 2
fx_row 'cost' "누적 usd=1" "관측 시각=2026-10-06T01:05:00Z"
fx_approval A1 대기
fx_approval A1 승인
fx_row 'blocked' "대상=-" "스코프=run" "원인=해소" "사유=t"
fx_row '자율 승인' "kind=cycle" "결정=act" "세그먼트=X" "argv=- \`stage-result\` | 세그먼트=X "
fx_heartbeat 0 5
fx_session_index s-ev1 pr-ev1
out=$(pane s-ev1)
check "13 드라이버 비용·승인·해소·자율 승인 제외·여섯 상한" "$(brows "$out" event | cut -f4,6 | tr '\t' ' ')" \
"01:05  막힘 해소
01:05  승인 A1 승인
01:05  승인 대기 A1
01:05  비용 누적 \$1.00
01:00  X implement 2회차 · rc 0
01:00  막힘 run 기록"

fx_mkrun pr-ev0; fx_ledger_path; fx_segment X 실행중
sr 1
fx_heartbeat 0 5
fx_session_index s-ev0 pr-ev0
check "13 앞에 시각 있는 행이 없으면 --:--" "$(brows "$(pane s-ev0)" event | cut -f4,6 | tr '\t' ' ')" \
  "--:--  X implement 1회차 · rc 0"

# ---------------------------------------------------------------------------
# 14. The head: targets from the manifest, the shift ordinal, the watcher.
# ---------------------------------------------------------------------------
fx_mkrun pr-h1; fx_ledger_path; fx_segment S1 실행중
fx_row '교대 기동' "서수=1"; fx_row '교대 기동' "서수=2"
fx_manifest_target cc-x 커밋
fx_heartbeat 0 5; fx_session_index s-h1 pr-h1
check "14 대상 하나와 교대 서수" "$(brow "$(pane s-h1)" head)" \
  "head${TAB}cut${TAB}accent.b${TAB}⟳ 진행중${TAB}normal${TAB}  교대 2 · cc-x · 절단점 커밋"
fx_mkrun pr-h2; fx_ledger_path; fx_segment S1 실행중
fx_manifest_target a1 커밋 a2 머지
fx_heartbeat 0 5; fx_session_index s-h2 pr-h2
check "14 대상 여럿은 개수와 런 최대 절단점" "$(brow "$(pane s-h2)" head)" \
  "head${TAB}cut${TAB}accent.b${TAB}⟳ 진행중${TAB}normal${TAB}  대상 2개 · 절단점 머지"
check "14 매니페스트도 교대도 없으면 상태 단어뿐" "$(brow "$(pane s-prog)" head)" \
  "head${TAB}cut${TAB}accent.b${TAB}⟳ 진행중"

check "14 워처 ok" "$(brow "$(pane s-prog)" head-detail)" \
  "head-detail${TAB}cut${TAB}dim${TAB}원장 1분 안 · 워처 ♥ 1분 안"
fx_mkrun pr-w1; fx_ledger_path; fx_segment S1 실행중; fx_heartbeat 300 5; fx_watch_pid dead
fx_session_index s-w1 pr-w1
check "14 워처 stale — 경고 색조의 없음과 하트비트 나이" "$(brow "$(pane s-w1)" head-detail)" \
  "head-detail${TAB}cut${TAB}dim${TAB}원장 1분 안 · ${TAB}warn${TAB}워처 없음 5분 전"
fx_mkrun pr-w2; fx_ledger_path; fx_segment S1 실행중
fx_session_index s-w2 pr-w2
has "14 워처 unstarted — 미기동" "$(rtext "$(brow "$(pane s-w2)" head-detail)")" "워처 미기동"
hasnt "14 워처 none — 종단 런에는 워처 칸이 없다" "$(rtext "$(brow "$(pane s-done)" head-detail)")" "워처"
fx_mkrun pr-w3; fx_ledger_path; fx_segment S1 실행중; fx_heartbeat -120 -120
fx_session_index s-w3 pr-w3
check "14 지금보다 늦은 시각은 나이 0" "$(rtext "$(brow "$(pane s-w3)" head-detail)")" "원장 1분 안 · 워처 ♥ 1분 안"
for g in "600 10분 전" "7300 2시간 전"; do
  set -- $g
  fx_mkrun "pr-age$1"; fx_ledger_path; fx_segment S1 실행중; fx_heartbeat 0 "$1"
  fx_session_index "s-age$1" "pr-age$1"
  has "14 나이 구간 $1초" "$(rtext "$(brow "$(pane "s-age$1")" head-detail)")" "원장 $2 $3"
done

# ---------------------------------------------------------------------------
# 15. Segment details: the predecessor, the driver's dispatch-id records.
# ---------------------------------------------------------------------------
fx_mkrun pr-pre; fx_ledger_path
fx_row 'segment' "id=W" "상태=계획됨" "선행=Q" "워크트리=$FX_RUN_DIR"
fx_row 'segment' "id=W" "id=W" "상태=계획됨" "선행=A" "선행=R" "워크트리=$FX_RUN_DIR"
fx_row 'segment' "id=V" "상태=계획됨" "선행=없음" "워크트리=$FX_RUN_DIR"
fx_heartbeat 0 5; fx_session_index s-pre pr-pre
out=$(pane s-pre)
check "15 선행은 마지막 세그먼트 행의 마지막 값이다" "$(segdetail "$out" W)" "seg-detail${TAB}cut${TAB}dim${TAB}   선행 R"
check "15 선행이 없음이면 세부 줄이 없다" "$(segdetail "$out" V)" ""

fx_mkrun pr-drv; fx_ledger_path; fx_segment B 실행중
fx_stage_live "S4:B:0"; fx_stage_meta "S4:B:0" "" 3
fx_heartbeat 0 5; fx_session_index s-drv pr-drv
out=$(pane s-drv)
check "15 드라이버 꼴 기록 — 세그먼트 B 가 실행중이다" "$(segrow "$out" B)" \
  "seg${TAB}cut${TAB}accent${TAB}⟳${TAB}normal${TAB} B 실행중"
like  "15 드라이버 꼴 기록 — 종류 없이 회차와 시작" "$(segdetail "$out" B)" \
  "^seg-detail${TAB}cut${TAB}dim${TAB}   3회차 · [0-9][0-9]:[0-9][0-9]Z 시작\$"

# ---------------------------------------------------------------------------
# 16. The start time from `ps -o etime=` in its three shapes and with leading
# zeros. The double answers only the `etime=` query and passes every other one
# to the real `ps`, so the liveness check's `lstart=` still holds.
# ---------------------------------------------------------------------------
REAL_PS=$(command -v ps)
mkdir -p "$WORK/fakeps"
cat > "$WORK/fakeps/ps" <<STUB
#!/usr/bin/env bash
case " \$* " in *"etime="*) printf '%s\n' "\$FAKE_ETIME"; exit 0 ;; esac
exec "$REAL_PS" "\$@"
STUB
chmod +x "$WORK/fakeps/ps"
fx_mkrun pr-time; fx_ledger_path; fx_segment T 실행중; fx_stage_live T; fx_stage_meta T implement 1
fx_heartbeat 0 5; fx_session_index s-time pr-time
for g in "13:38 818" "01:13:38 4418" "2-01:13:38 177218" "08:09 489" "09:08:09 32889"; do
  set -- $g
  t0=$(date -u +%s)
  out=$(FAKE_ETIME=$1 PATH="$WORK/fakeps:$PATH" bash "$PANE" s-time)
  t1=$(date -u +%s)
  check "16 etime $1 — 세그먼트가 실행중이다 (전제)" "$(segrow "$out" T | cut -f4)" "⟳"
  d=$(segdetail "$out" T)
  a="seg-detail${TAB}cut${TAB}dim${TAB}   implement 1회차 · $(gm_hhmm $((t0 - $2)))Z 시작"
  z="seg-detail${TAB}cut${TAB}dim${TAB}   implement 1회차 · $(gm_hhmm $((t1 - $2)))Z 시작"
  if [ "$d" = "$a" ] || [ "$d" = "$z" ]; then ok "16 etime $1 — 시작 시각"; else bad "16 etime $1 — 시작 시각" "got '$d', want '$a'"; fi
done
hasnt "16 헬퍼는 date -r 을 쓰지 않는다" "$(cat "$PANE")" "date -r"
hasnt "16 헬퍼는 date -d 를 쓰지 않는다" "$(cat "$PANE")" "date -d" # lint-bash-portability: disable=date -d

# ---------------------------------------------------------------------------
# 17. Arguments.
# ---------------------------------------------------------------------------
base=$(bash "$PANE" s-capseg)
for a in "--rows abc" "--rows 0" "--rows -3" "--cols x" "--cols 0" "--rows" "--cols"; do
  # shellcheck disable=SC2086
  check "17 잘못된 인자 '$a' 는 기본값이다" "$(bash "$PANE" s-capseg $a)" "$base"
done
check "17 기본값은 --cols 44 --rows 24 다" "$(bash "$PANE" s-capseg --cols 44 --rows 24)" "$base"
has "17 --rows 가 상한을 낮춘다" \
  "$([ "$(body_n "$(pane s-fold --rows 12)")" -lt "$(body_n "$(pane s-fold)")" ] && echo yes || echo no)" "yes"

# ---------------------------------------------------------------------------
# 6. The contract, over every output this suite produced above.
# ---------------------------------------------------------------------------
# Each property is one assertion over the whole set; a breach names the output
# that broke it. The length bound is max(cap, floor): the floor is what the
# reduction never removes — the protected rows, the segment heading, the fold
# rows, the empty-gate summary — and a `seg` row past the reduction is one that
# holds a block.
BUNDLES=" none title head head-detail gap seg-heading seg seg-detail seg-folded gate-none approval block-heading block-reason cone-unresolved orphan event-heading event "
n_outs=0; e_head=""; e_refresh=""; e_idx=""; e_len=""; e_row=""; classes=""
for f in "$OUTS"/o.*; do
  case "$f" in *.dim) continue ;; esac
  [ -f "$f" ] || continue
  n_outs=$((n_outs + 1))
  o=$(cat "$f"); name=$(basename "$f")
  read -r cap cols < "$f.dim"
  [ "$(valid_head "$o")" = "yes" ] || e_head="$e_head $name"
  cls=$(hfield "$o" 3); idxf=$(hfield "$o" 5); rf=$(hfield "$o" 6)
  classes="$classes $cls"
  case "$cls:$rf" in
    live:10000|ended:60000|none:60000) ;;
    *) e_refresh="$e_refresh $name($cls:$rf)" ;;
  esac
  case "$idxf" in -|/*) ;; *) e_idx="$e_idx $name($idxf)" ;; esac
  bad_rows=$(body "$o" | awk -F'\t' -v set="$BUNDLES" '
    {
      okr = (index(set, " " $1 " ") > 0) && ($2 == "cut" || $2 == "wrap") && NF >= 4 && NF % 2 == 0
      if ($2 == "wrap" && $1 != "block-reason") okr = 0
      for (i = 3; i < NF; i += 2) if ($i !~ /^(normal|dim|ok|warn|error|accent)(\.b)?$/) okr = 0
      if (!okr) n++
    }
    END { print n + 0 }')
  [ "$bad_rows" = "0" ] || e_row="$e_row $name($bad_rows)"
  total=0; floor=0
  while IFS="$TAB" read -r rb rm rest; do
    [ -n "$rb" ] || continue
    if [ "$rm" = "wrap" ]; then
      ln=$(rtext "$rb${TAB}$rm${TAB}$rest" | bash "$PANE" --estimate "$cols")
    else
      ln=1
    fi
    total=$((total + ln))
    case " $rb " in
      " title "|" head "|" head-detail "|" approval "|" block-heading "|" block-reason "|\
      " cone-unresolved "|" orphan "|" seg "|" seg-heading "|" seg-folded "|" gate-none "|" none ")
        floor=$((floor + ln)) ;;
    esac
  done <<EOF
$(body "$o")
EOF
  bound=$cap; [ "$floor" -gt "$bound" ] && bound=$floor
  { [ "$total" -ge 1 ] && [ "$total" -le "$bound" ]; } || e_len="$e_len $name($total>$bound)"
done
check "6 머리 행이 여섯 칸이고 스키마가 2 다" "$e_head" ""
check "6 refresh_ms 는 live 에서 10000, 그 밖에서 60000 이다" "$e_refresh" ""
check "6 세션 목록 칸은 - 이거나 절대 경로다" "$e_idx" ""
check "6 본문 줄 수 추정이 max(상한, 바닥) 이하다" "$e_len" ""
check "6 본문 행은 모두 <묶음><TAB><cut|wrap>(<TAB><색조><TAB><글>)+ 이고 묶음·색조가 집합 안, wrap 은 block-reason 뿐이다" "$e_row" ""
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
         s-noindex s-empty s-gone s-oldid s-capseg s-captail s-fold s-nolp s-cone s-order \
         s-replay s-ev2 s-ev1 s-ev0 s-h1 s-h2 s-w1 s-w2 s-w3 s-pre s-drv s-time; do
  bash "$PANE" "$s" >/dev/null 2>&1
done
after=$(tree_snap)
check "8 쓰기 없음 — 실행 전후 상태 트리의 파일 목록과 mtime 이 같다" "$after" "$before"
[ "$(printf '%s\n' "$before" | grep -c .)" -gt 20 ] \
  && ok "8 비교한 트리가 비어 있지 않다" || bad "8 쓰기 없음" "스냅숏이 비었다"

printf '\n통과 %s · 실패 %s · 건너뜀 %s\n' "$passed" "$failed" "$skipped"
[ "$failed" -eq 0 ]
