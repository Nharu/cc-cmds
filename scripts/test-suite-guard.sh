#!/usr/bin/env bash
# Test scripts/suite-guard.sh (the per-suite wrapper) and scripts/ci-step-guard.sh
# (the CI step's arming line).
#
# DARWIN ONLY. This suite is on the macOS leg's short list: what it checks —
# Apple make 3.81 waiting for every holder of its jobserver pipe, the arming
# line under the real bash 3.2, macOS `lsof` listing the marker — is only there.
#
# THIS SUITE ITSELF RUNS UNDER A STRICT WRAPPER AND AN ARMED STEP. Whatever it
# plants must not become the outer wrapper's leftover or hold the outer make, so:
#   - every wrapper under test is started with the outer jobserver fds and the
#     outer step marker closed (`3>&- 4>&- 5>&- 8<&-`), and its own fd 9 replaces
#     the outer marker — what a planted suite leaves holds only the inner marker;
#   - every inner make is started as a top-level make (`MAKEFLAGS= MFLAGS=
#     MAKELEVEL=`, outer fds closed), so it makes its own jobserver pipe;
#   - decoys the harness starts close every outer fd and are signalled only
#     through the harness's own `$!`;
#   - every planted `sleep` lasts a few seconds and expires by itself.
#
# Every planted process is told apart by its pid, written to a file by the
# suite that planted it; nothing is matched by name.

set -uo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
SG="$repo_root/scripts/suite-guard.sh"
CSG="$repo_root/scripts/ci-step-guard.sh"
DETACH="$repo_root/plugins/cc-cmds/orchestrator/detach.sh"
WF="$repo_root/.github/workflows/notify-macos.yml"

for f in "$SG" "$CSG" "$DETACH" "$WF"; do
  if [ ! -f "$f" ]; then
    echo "FAIL: 시험 대상이 없다: $f" >&2
    exit 2
  fi
done

W=$(mktemp -d "${TMPDIR:-/tmp}/cc-test-suite-guard.XXXXXX")
trap 'rm -rf "$W"' EXIT

passed=0
failures=0

ok()  { passed=$((passed + 1)); printf 'PASS: %s\n' "$1"; }
bad() { failures=$((failures + 1)); printf 'FAIL: %s\n' "$1" >&2; }

check() {
  # check <label> <got> <want>
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got=[$2] want=[$3])"; fi
}

show() { sed 's/^/    /' "$1" >&2; }

has() {
  # has <label> <file> <ERE>
  if grep -qE -- "$3" "$2"; then ok "$1"; else bad "$1 — /$3/ 가 출력에 없다"; show "$2"; fi
}

hasnt() {
  # hasnt <label> <file> <ERE>
  if grep -qE -- "$3" "$2"; then bad "$1 — /$3/ 가 출력에 있다"; show "$2"; else ok "$1"; fi
}

gone() {
  # gone <pid> — true once the pid is gone, waiting up to 3s.
  local i=0
  while kill -0 "$1" 2>/dev/null && [ "$i" -lt 30 ]; do sleep 0.1; i=$((i + 1)); done
  ! kill -0 "$1" 2>/dev/null
}

check_gone() {
  # check_gone <label> <pid>
  if [ -z "$2" ]; then bad "$1 — pid 를 읽지 못했다"; return; fi
  if gone "$2"; then ok "$1"; else bad "$1 — pid $2 가 아직 살아 있다"; fi
}

now() { perl -MTime::HiRes=time -e 'printf "%.2f\n", time'; }

elapsed_lt() {
  # elapsed_lt <label> <t0> <t1> <limit-s>
  if awk -v a="$2" -v b="$3" -v l="$4" 'BEGIN { exit !(b - a < l) }'; then
    ok "$1"
  else
    bad "$1 — 경과 $(awk -v a="$2" -v b="$3" 'BEGIN { printf "%.2f", b - a }')s 가 ${4}s 이상"
  fi
}

elapsed_ge() {
  # elapsed_ge <label> <t0> <t1> <floor-s>
  if awk -v a="$2" -v b="$3" -v l="$4" 'BEGIN { exit !(b - a >= l) }'; then
    ok "$1"
  else
    bad "$1 — 경과 $(awk -v a="$2" -v b="$3" 'BEGIN { printf "%.2f", b - a }')s 가 ${4}s 미만"
  fi
}

# The dump lines with the wrapper's prefix removed, so `ps` and `lsof` rows
# read as their own columns.
dump_rows() {
  sed -E 's/^(suite|step)-guard(\[[^]]*\])?:     //' "$1"
}

# ps_row <file> <pid> — "pid ppid pgid" from the dump's `ps` row for that pid.
ps_row() {
  dump_rows "$1" | awk -v p="$2" '$1 == p && $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/ { print $1, $2, $3; exit }'
}

wait_file() {
  # wait_file <path> — up to 5s for a non-empty file.
  local i=0
  while [ ! -s "$1" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
  [ -s "$1" ]
}

RC=0
run_sg() {
  # run_sg <tag> <strict 0|1> <suite> [args…] — the wrapper under test, in the
  # foreground, outer fds closed (see the header).
  local tag="$1" strict="$2"; shift 2
  CC_SUITE_GUARD_STRICT="$strict" CC_SUITE_GUARD_GRACE_S=1 \
  CC_SUITE_GUARD_LIMIT_S="${SG_LIMIT:-0}" CC_STEP_DEADLINE_EPOCH= \
  CC_SUITE_GUARD_LSOF=lsof \
    bash "$SG" "$@" >"$W/$tag.out" 2>"$W/$tag.err" 3>&- 4>&- 5>&- 8<&-
  RC=$?
}

# --- T1: a plain background leftover ----------------------------------------
cat >"$W/t1.sh" <<'EOF'
sleep 6 &
echo "$!" > "$1"
exit 0
EOF
run_sg t1s 1 "$W/t1.sh" "$W/t1s.pid"
p=$(cat "$W/t1s.pid" 2>/dev/null)
check "T1 엄격: 잔존이 있으면 exit 3" "$RC" "3"
has "T1 엄격: 덤프에 심은 sleep" "$W/t1s.err" "보유자 pid=${p}\$"
has "T1 엄격: 심은 sleep 에 TERM" "$W/t1s.err" "TERM → pid=${p}\$"
check_gone "T1 엄격: 스윕 뒤 심은 sleep 이 없다" "$p"

run_sg t1n 0 "$W/t1.sh" "$W/t1n.pid"
p=$(cat "$W/t1n.pid" 2>/dev/null)
check "T1 비엄격: rc 는 묶음의 rc 그대로" "$RC" "0"
has "T1 비엄격: 거두며 출력한다" "$W/t1n.err" "보유자 pid=${p}\$"
check_gone "T1 비엄격: 스윕 뒤 심은 sleep 이 없다" "$p"

# --- T2: a leftover in a new process group ----------------------------------
cat >"$W/t2.sh" <<'EOF'
( set -m; sleep 6 & echo "$!" > "$1" )
exit 0
EOF
run_sg t2 1 "$W/t2.sh" "$W/t2.pid"
p=$(cat "$W/t2.pid" 2>/dev/null)
check "T2: 새 pgid 잔존도 exit 3" "$RC" "3"
has "T2: 표지로 잡힌다" "$W/t2.err" "보유자 pid=${p}\$"
hasnt "T2: 그룹 교차 확인에는 없다" "$W/t2.err" "그룹 구성원 pid=${p}\$"
check_gone "T2: 스윕 뒤 없다" "$p"

# --- T3: the foreground sleep of a loop that was TERMed ---------------------
cat >"$W/t3.sh" <<'EOF'
( while :; do sleep 6; done ) &
lp=$!
sp=""
i=0
while [ -z "$sp" ] && [ "$i" -lt 50 ]; do
  sleep 0.1
  i=$((i + 1))
  sp=$(ps -A -o pid=,ppid=,comm= | awk -v p="$lp" '$2 == p && $3 ~ /sleep$/ { print $1; exit }')
done
kill -TERM "$lp"
wait "$lp" 2>/dev/null
echo "$sp" > "$1"
exit 0
EOF
run_sg t3 1 "$W/t3.sh" "$W/t3.pid"
p=$(cat "$W/t3.pid" 2>/dev/null)
check "T3: 고아가 된 전경 sleep 도 exit 3" "$RC" "3"
has "T3: 표지로 잡힌다" "$W/t3.err" "보유자 pid=${p}\$"
check "T3: 덤프의 ppid 가 1" "$(ps_row "$W/t3.err" "$p" | awk '{ print $2 }')" "1"
check_gone "T3: 스윕 뒤 없다" "$p"

# --- T4: a grandchild detached by the tree's own cc_detach_exec -------------
printf '%s\n' ". \"$DETACH\"" \
  'cc_detach_exec /dev/null /dev/null sleep 6 > "$1"' \
  'exit 0' >"$W/t4.sh"
run_sg t4 1 "$W/t4.sh" "$W/t4.pid"
p=$(cat "$W/t4.pid" 2>/dev/null)
check "T4: 떼어 낸 손자도 exit 3" "$RC" "3"
has "T4: 표지로 잡힌다" "$W/t4.err" "보유자 pid=${p}\$"
check "T4: 덤프에 ppid 1, pgid 가 자기" "$(ps_row "$W/t4.err" "$p")" "$p 1 $p"
check "T4: 덤프에 fd 0·1·2 가 /dev/null" \
  "$(dump_rows "$W/t4.err" | awk -v p="$p" '$2 == p && $4 ~ /^[012][rwu]?$/ && $NF == "/dev/null" { n++ } END { print n + 0 }')" "3"
check_gone "T4: 스윕 뒤 없다" "$p"

# --- T5: a suite stopped in the foreground after its summary ----------------
cat >"$W/t5.sh" <<'EOF'
echo "summary: 1 passed"
sleep 30 &
c=$!
echo "$$ $c" > "$1"
wait "$c"
EOF
t0=$(now)
SG_LIMIT=3 run_sg t5 1 "$W/t5.sh" "$W/t5.pid"
t1=$(now)
read -r sb sc < "$W/t5.pid" 2>/dev/null || { sb=""; sc=""; }
check "T5: 마감을 넘기면 엄격 exit 124" "$RC" "124"
has "T5: ::error:: 로 끝난다" "$W/t5.err" "::error::suite-guard: 마감을 넘겨"
has "T5: 덤프에 묶음 bash" "$W/t5.err" "그룹 구성원 pid=${sb}\$"
has "T5: 덤프에 그 자식" "$W/t5.err" "그룹 구성원 pid=${sc}\$"
check_gone "T5: 묶음 bash 가 없다" "$sb"
check_gone "T5: 그 자식이 없다" "$sc"
elapsed_lt "T5: 한도 3초 + 유예 안에 끝난다" "$t0" "$t1" 10

# --- T6: a jobserver holder under make -j3 ----------------------------------
printf '%s\n' ". \"$DETACH\"" \
  'cc_detach_exec /dev/null /dev/null sleep 8 > "$1"' \
  'exit 0' >"$W/t6-leave.sh"
printf 'all: a b c\na:\n\tbash "%s" "%s" "%s"\nb:\n\t@sleep 0.2\nc:\n\t@sleep 0.2\n' \
  "$SG" "$W/t6-leave.sh" "$W/t6a.pid" >"$W/t6a.mk"
printf 'all: a b c\na:\n\tbash "%s" "%s"\nb:\n\t@sleep 0.2\nc:\n\t@sleep 0.2\n' \
  "$W/t6-leave.sh" "$W/t6b.pid" >"$W/t6b.mk"

# (a) with the wrapper, strict.
t0=$(now)
MAKEFLAGS= MFLAGS= MAKELEVEL= CC_SUITE_GUARD_STRICT=1 CC_SUITE_GUARD_GRACE_S=1 \
CC_SUITE_GUARD_LIMIT_S=0 CC_STEP_DEADLINE_EPOCH= CC_SUITE_GUARD_LSOF=lsof \
  make -j3 -f "$W/t6a.mk" >"$W/t6a.out" 2>&1 3>&- 4>&- 5>&- 8<&- 9<&-
rc=$?
t1=$(now)
p=$(cat "$W/t6a.pid" 2>/dev/null)
if [ "$rc" != 0 ]; then ok "T6(a): 엄격이면 make 가 실패한다"; else bad "T6(a): 엄격인데 make 가 0 으로 끝났다"; show "$W/t6a.out"; fi
has "T6(a): 래퍼가 보유자를 거둔다" "$W/t6a.out" "TERM → pid=${p}\$"
elapsed_lt "T6(a): make 가 유예 + δ 안에 반환한다(보유자 수명 8초)" "$t0" "$t1" 6
check_gone "T6(a): 보유자가 없다" "$p"

# (b) the control: the same Makefile without the wrapper waits for the holder.
t0=$(now)
MAKEFLAGS= MFLAGS= MAKELEVEL= \
  make -j3 -f "$W/t6b.mk" >"$W/t6b.out" 2>&1 3>&- 4>&- 5>&- 8<&- 9<&-
t1=$(now)
elapsed_ge "T6(b) 대조: 래퍼 없는 make 는 보유자 수명만큼 기다린다" "$t0" "$t1" 7

# --- T7: safety — decoys are never signalled --------------------------------
cat >"$W/t7.sh" <<'EOF'
lsof -w -a -p "$$" -d 9 -F n > "$1.lsof"
sed -n 's/^n//p' "$1.lsof" > "$1.tmp" && mv "$1.tmp" "$1"
sleep 6 &
sleep 2
exit 0
EOF
sleep 20 3>&- 4>&- 5>&- 8<&- 9<&- &
d1=$!
sleep 1
CC_SUITE_GUARD_STRICT=1 CC_SUITE_GUARD_GRACE_S=1 CC_SUITE_GUARD_LIMIT_S=0 \
CC_STEP_DEADLINE_EPOCH= CC_SUITE_GUARD_LSOF=lsof \
  bash "$SG" "$W/t7.sh" "$W/t7.path" >"$W/t7.out" 2>"$W/t7.err" 3>&- 4>&- 5>&- 8<&- &
w=$!
d2=""
if wait_file "$W/t7.path"; then
  sleep 20 3>&- 4>&- 5>&- 8<&- 9<&- 5<"$(cat "$W/t7.path")" &
  d2=$!
else
  bad "T7: 묶음이 표지 경로를 적지 않았다"
fi
wait "$w"
rc=$?
check "T7: 묶음의 진짜 잔존은 거둔다(exit 3)" "$rc" "3"
if kill -0 "$d1" 2>/dev/null; then ok "T7: 래퍼 시작 전 미끼는 신호받지 않는다"; else bad "T7: 래퍼 시작 전 미끼가 죽었다"; fi
if [ -n "$d2" ] && kill -0 "$d2" 2>/dev/null; then
  ok "T7: 표지를 다른 fd 로 연 미끼는 신호받지 않는다"
else
  bad "T7: 표지를 다른 fd 로 연 미끼가 죽었다"
fi
hasnt "T7: 미끼 1 이 보유자로 나열되지 않는다" "$W/t7.err" "보유자 pid=${d1}\$"
[ -n "$d2" ] && hasnt "T7: 미끼 2 가 보유자로 나열되지 않는다" "$W/t7.err" "보유자 pid=${d2}\$"
kill "$d1" 2>/dev/null; wait "$d1" 2>/dev/null
if [ -n "$d2" ]; then kill "$d2" 2>/dev/null; wait "$d2" 2>/dev/null; fi

# --- T8: no leftover, the suite's rc is passed through ----------------------
for want in 0 1 7; do
  printf 'exit %s\n' "$want" >"$W/t8-$want.sh"
  run_sg "t8-$want" 1 "$W/t8-$want.sh"
  check "T8: 잔존 없는 묶음 rc $want 가 그대로" "$RC" "$want"
done

# --- T10: lsof hidden from PATH ---------------------------------------------
# macOS keeps lsof in /usr/sbin, so a PATH of /usr/bin:/bin hides it while
# leaving perl, ps, awk and make in place.
HIDE_PATH=/usr/bin:/bin
if PATH="$HIDE_PATH" command -v lsof >/dev/null 2>&1; then
  bad "T10: $HIDE_PATH 에서도 lsof 가 보여 가릴 수 없다"
else
  cat >"$W/t10.sh" <<'EOF'
echo ran > "$1"
sleep 6 &
echo "$!" > "$2"
exit 0
EOF
  PATH="$HIDE_PATH" CC_SUITE_GUARD_STRICT=1 CC_SUITE_GUARD_GRACE_S=1 CC_STEP_DEADLINE_EPOCH= \
    bash "$SG" "$W/t10.sh" "$W/t10s.ran" "$W/t10s.pid" >"$W/t10s.out" 2>"$W/t10s.err" 3>&- 4>&- 5>&- 8<&-
  check "T10 래퍼 엄격: 판정 실패 exit 4" "$?" "4"
  has "T10 래퍼 엄격: ::error:: 로 실패" "$W/t10s.err" "::error::suite-guard: 양성 대조 실패"
  if [ -e "$W/t10s.ran" ]; then bad "T10 래퍼 엄격: 묶음이 돌았다"; else ok "T10 래퍼 엄격: 묶음을 돌리지 않는다"; fi

  PATH="$HIDE_PATH" CC_SUITE_GUARD_STRICT=0 CC_SUITE_GUARD_GRACE_S=1 CC_STEP_DEADLINE_EPOCH= \
    bash "$SG" "$W/t10.sh" "$W/t10n.ran" "$W/t10n.pid" >"$W/t10n.out" 2>"$W/t10n.err" 3>&- 4>&- 5>&- 8<&-
  check "T10 래퍼 비엄격: rc 는 묶음의 rc" "$?" "0"
  has "T10 래퍼 비엄격: NOTE: 한 줄" "$W/t10n.err" "NOTE: 양성 대조 실패"
  p=$(cat "$W/t10n.pid" 2>/dev/null)
  has "T10 래퍼 비엄격: 그룹 스윕으로 대신 거둔다" "$W/t10n.err" "TERM → pid=${p}\$"
  check_gone "T10 래퍼 비엄격: 그룹 잔존이 없다" "$p"

  PATH="$HIDE_PATH" CC_SUITE_GUARD_STRICT=1 CC_JOB_T0="$(date +%s)" CC_JOB_BUDGET_S=600 \
    bash -c '. "$1" && echo ARMED || echo "REFUSED rc=$?"' _ "$CSG" >"$W/t10a.out" 2>&1 3>&- 4>&- 5>&- 8<&- 9<&-
  has "T10 무장 줄 엄격: 무장이 실패한다" "$W/t10a.out" "^REFUSED rc=1\$"
  has "T10 무장 줄 엄격: ::error::" "$W/t10a.out" "::error::ci-step-guard: 양성 대조 실패"

  PATH="$HIDE_PATH" CC_SUITE_GUARD_STRICT=0 \
    bash -c '. "$1" && echo ARMED || echo "REFUSED rc=$?"' _ "$CSG" >"$W/t10b.out" 2>&1 3>&- 4>&- 5>&- 8<&- 9<&-
  has "T10 무장 줄 비엄격: 계속 간다" "$W/t10b.out" "^ARMED\$"
  has "T10 무장 줄 비엄격: NOTE: 한 줄" "$W/t10b.out" "NOTE: ci-step-guard: 양성 대조 실패"
fi

# --- T11: the sweep never lists itself --------------------------------------
printf 'exit 0\n' >"$W/t11.sh"
n3=0
nh=0
i=0
while [ "$i" -lt 50 ]; do
  run_sg t11 1 "$W/t11.sh"
  [ "$RC" = 3 ] && n3=$((n3 + 1))
  grep -qE '보유자 pid=' "$W/t11.err" && nh=$((nh + 1))
  i=$((i + 1))
done
check "T11: 깨끗한 묶음 50회에서 exit 3 이 0회" "$n3" "0"
check "T11: 깨끗한 묶음 50회에서 보유자 나열이 0회" "$nh" "0"

# --- T12: the arming line's deadline ----------------------------------------
printf '%s\n' ". \"$DETACH\"" \
  "cc_detach_exec /dev/null /dev/null sleep 20 > \"$W/t12.pid\"" >"$W/t12-leave.sh"
printf 'all: a\na:\n\tbash "%s"\n' "$W/t12-leave.sh" >"$W/t12.mk"
t0=$(now)
MAKEFLAGS= MFLAGS= MAKELEVEL= CC_SUITE_GUARD_STRICT=1 CC_JOB_T0="$(date +%s)" \
CC_JOB_BUDGET_S=4 CC_STEP_DUMP_MARGIN_S=0 CC_SUITE_GUARD_GRACE_S=1 CC_SUITE_GUARD_LSOF=lsof \
  bash -e -c '. "$1"; make -j3 -f "$2"' _ "$CSG" "$W/t12.mk" >"$W/t12.out" 2>&1 3>&- 4>&- 5>&- 8<&- 9<&-
rc=$?
t1=$(now)
p=$(cat "$W/t12.pid" 2>/dev/null)
if [ "$rc" != 0 ]; then ok "T12: 마감에서 거둔 뒤 0 아닌 값으로 끝난다 (rc=$rc)"; else bad "T12: 마감을 넘겼는데 0 으로 끝났다"; show "$W/t12.out"; fi
has "T12: 마감 도달을 알린다" "$W/t12.out" "::error::ci-step-guard: 단계 마감에 이르렀다"
has "T12: 대기자를 W2'·W1·W3 로 분류한다" "$W/t12.out" "분류: (W2'|W1|W3) "
has "T12: 떼어 낸 보유자를 덤프한다" "$W/t12.out" "보유자 pid=${p}\$"
check_gone "T12: 보유자가 없다" "$p"
elapsed_lt "T12: 보유자 수명(20초) 전에 끝난다" "$t0" "$t1" 15

# --- T13: a descendant that closed the marker fd ----------------------------
cat >"$W/t13.sh" <<'EOF'
sleep 8 3>&- 4>&- 5>&- 9>&- &
echo "$!" > "$1"
exit 0
EOF
run_sg t13 1 "$W/t13.sh" "$W/t13.pid"
p=$(cat "$W/t13.pid" 2>/dev/null)
hasnt "T13: 표지로 잡히지 않는다(알려진 사각)" "$W/t13.err" "보유자 pid=${p}\$"
has "T13: 그룹 교차 확인 줄로 기록된다" "$W/t13.err" "그룹 구성원 pid=${p}\$"
has "T13: 교차 확인 머리 줄" "$W/t13.err" "그룹 교차 확인 — 묶음 그룹"

# --- T14: the marker removed before the sweep -------------------------------
cat >"$W/t14.sh" <<'EOF'
lsof -w -a -p "$$" -d 9 -F n > "$1"
rm -f "$(sed -n 's/^n//p' "$1")"
exit 0
EOF
run_sg t14 1 "$W/t14.sh" "$W/t14.lsof"
check "T14: 지워진 표지는 판정 실패 exit 4" "$RC" "4"
has "T14: 「잔존 없음」이 아니라 판정 실패로 적힌다" "$W/t14.err" "판정 실패 — 표지 파일이 없다"
hasnt "T14: 보유자 0 으로 적지 않는다" "$W/t14.err" "표지 보유자 0"

# --- T16: CC_JOB_BUDGET_S equals the job's timeout-minutes x 60 -------------
# `timeout-minutes` cannot read `env`, so the two are tied here. The arming line
# (scripts/ci-step-guard.sh) reads the budget; the ceiling is the job's own.
budget_ok() {
  # budget_ok <workflow> — 0 equal, 1 different, 2 unreadable.
  local tm b
  tm=$(yq '.jobs."lint-and-test-macos"."timeout-minutes"' "$1" 2>/dev/null) || return 2
  b=$(yq '.jobs."lint-and-test-macos".env.CC_JOB_BUDGET_S' "$1" 2>/dev/null) || return 2
  case "$tm" in ''|*[!0-9]*) return 2 ;; esac
  case "$b" in ''|*[!0-9]*) return 2 ;; esac
  [ "$b" -eq $((tm * 60)) ]
}
if ! command -v yq >/dev/null 2>&1; then
  bad "T16: yq 가 없어 워크플로를 읽을 수 없다"
else
  budget_ok "$WF"
  check "T16: CC_JOB_BUDGET_S 가 잡 수준 timeout-minutes x 60 과 같다" "$?" "0"

  sed -E "s/^(      CC_JOB_BUDGET_S: *'?)[0-9]+/\\19999/" "$WF" >"$W/t16-budget.yml"
  if cmp -s "$WF" "$W/t16-budget.yml"; then
    bad "T16: 예산만 바꾼 사본을 만들지 못했다"
  else
    budget_ok "$W/t16-budget.yml"
    check "T16: 예산만 바꾼 사본은 실패한다" "$?" "1"
  fi

  sed -E 's/^(    timeout-minutes: *)[0-9]+/\1999/' "$WF" >"$W/t16-ceiling.yml"
  if cmp -s "$WF" "$W/t16-ceiling.yml"; then
    bad "T16: 상한만 바꾼 사본을 만들지 못했다"
  else
    budget_ok "$W/t16-ceiling.yml"
    check "T16: 상한만 바꾼 사본은 실패한다" "$?" "1"
  fi

  check "T16: darwin 단계의 첫 줄이 무장 줄이다" \
    "$(yq '.jobs."lint-and-test-macos".steps[] | select(.name == "Run darwin-only tests") | .run' "$WF" | sed -n 1p)" \
    ". scripts/ci-step-guard.sh"
fi

# --- T17: INT and TERM to the wrapper ---------------------------------------
cat >"$W/t17.sh" <<'EOF'
sleep 6 &
echo "$$ $!" > "$1"
sleep 6
EOF
for sig in INT TERM; do
  case "$sig" in INT) want=130 ;; TERM) want=143 ;; esac
  # Job control on for the launch only: a background job of a non-interactive
  # shell starts with INT ignored, and an ignored signal cannot be trapped.
  set -m
  CC_SUITE_GUARD_STRICT=1 CC_SUITE_GUARD_GRACE_S=1 CC_SUITE_GUARD_LIMIT_S=0 \
  CC_STEP_DEADLINE_EPOCH= CC_SUITE_GUARD_LSOF=lsof \
    bash "$SG" "$W/t17.sh" "$W/t17-$sig.pid" >"$W/t17-$sig.out" 2>"$W/t17-$sig.err" 3>&- 4>&- 5>&- 8<&- &
  w=$!
  set +m
  sb=""; sc=""
  if wait_file "$W/t17-$sig.pid"; then
    read -r sb sc < "$W/t17-$sig.pid"
  else
    bad "T17 $sig: 묶음이 시작을 적지 않았다"
  fi
  kill -"$sig" "$w"
  wait "$w"
  check "T17 $sig: 래퍼 rc" "$?" "$want"
  check_gone "T17 $sig: 묶음 bash 가 남지 않는다" "$sb"
  check_gone "T17 $sig: 그 자손이 남지 않는다" "$sc"
done

printf 'test-suite-guard: %d passed, %d failed\n' "$passed" "$failures"
[ "$failures" -eq 0 ]
