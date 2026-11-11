#!/usr/bin/env bash
# Measure whether host-wide test slots (scripts/test-slots.sh) make a burst of
# concurrent runs finish sooner, and say which unattended default that favours.
#
# WHAT IS MEASURED IS THE WHOLE BURST, NOT ONE RUN. K mock runs start two
# seconds apart and the reading is the makespan: from the first start to the
# last end. Slots only reorder work, so a slower single run is no loss when the
# burst as a whole ends earlier, and a faster single run is no gain when it does
# not.
#
# ONE MOCK RUN does what an unattended stage does around a commit: in a clone of
# its own (`git clone --shared` of the measured commit, under the work
# directory) it runs a narrowed `scripts/test-gate.sh --sections <direct>` —
# the run a stage makes while it fixes — and then `scripts/check-push.sh run`
# with CHECK_PUSH_REUSE=0 and the sections and goals given. CC_PIPELINE_RUN_ID
# and the rest of CC_PIPELINE_* are cleared, so check-push runs in head mode
# rather than the merge mode of a real unattended run; the base merge that mode
# adds is the same for every form and does not change which form wins, and the
# results say so in their head. CC_TEST_SLOTS is set per form: off (`0`),
# `auto`, and 1.5 times the CPU count rounded up. Every form has a slot store
# of its own under the work directory, kept across repetitions so the weights
# build up, and the host's real store is never used.
#
# THE SCHEDULE. Levels 8 and 24, three repetitions. The two forms that turn
# slots on first run one uncounted warm-up trial each at the lowest level. Each
# repetition turns the order of the forms (off·auto·x15, auto·x15·off,
# x15·off·auto) so a drift in the host's background load does not land on one
# form. Before each trial the script waits up to 120 seconds for the 1-minute
# load average to fall to the CPU count or below, and records the load it
# started at and whether the wait hit its cap; a trial whose wait hit the cap is
# still valid.
#
# ONE LINE PER TRIAL is appended to <work>/results.tsv, so `run` can be cut at
# any point and started again: a (form, level, repetition) that already has a
# valid line is skipped. A trial in which any run failed is invalid and runs
# once more; failing again ends `run` with 1, because slots never change a
# verdict and a failure is a defect of the host or of this apparatus. Once the
# trials recorded under one work directory have spent six hours of wall clock
# between them, `run` starts no more and records that it stopped at the cap.
#
# THE VERDICT (`report`). M(form, K) is the median makespan of the valid
# repetitions. Any (form, K) with fewer than two valid repetitions, or a cap
# line, is `판정: 판정불가`. Otherwise a is the on form with the smaller M at the
# highest level, auto when the two are within 2% of the smaller, and the verdict
# is `판정: 켬 <a's value>` when all three hold, else `판정: 끔`:
#   1. at the highest level M(a) <= 0.95 * M(off)
#   2. at the lowest level  M(a) <= 1.05 * M(off)
#   3. at the highest level at least two valid repetitions of a are shorter
#      than M(off)
#
# Usage:
#   bash scripts/measure-test-slots.sh run --work <dir> [--levels 8,24]
#        [--reps 3] [--direct <sections>] [--sections <sections>]
#        [--goals <goals>]
#   bash scripts/measure-test-slots.sh report --work <dir>
#
# The doubles the self-test swaps in:
#   MTS_REPO          the repository whose HEAD is measured (default: this
#                     script's repository)
#   MTS_TASK          a script run with bash in each mock run's clone instead of
#                     the two steps above; it reads MTS_DIRECT, MTS_SECTIONS
#                     and MTS_GOALS
#   MTS_LOAD_CMD      a command printing the 1-minute load average
#   MTS_CPUS          the CPU count (default: getconf _NPROCESSORS_ONLN)
#   MTS_GAP_SECS      seconds between two starts (default 2)
#   MTS_SAMPLE_SECS   seconds between two load samples (default 5)
#   MTS_LOAD_WAIT_MAX seconds a trial waits for the load (default 120)
#   MTS_CAP_SECS      wall clock the trials of one work directory may spend
#                     (default 21600)
#
# Exit codes: 0 measured (or stopped at the cap) / reported, 1 a trial failed
# twice, 2 usage, an uncommitted change, or a work directory recorded for
# another commit or configuration.

set -uo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
REPO="${MTS_REPO:-$(cd "$script_dir/.." && pwd)}"
GAP="${MTS_GAP_SECS:-2}"
SAMPLE="${MTS_SAMPLE_SECS:-5}"
LOAD_WAIT_MAX="${MTS_LOAD_WAIT_MAX:-120}"
CAP_SECS="${MTS_CAP_SECS:-21600}"
TAB=$(printf '\t')

die2() { printf 'measure-test-slots: %s\n' "$1" >&2; exit 2; }
msg() { printf 'measure-test-slots: %s\n' "$1" >&2; }

mts_cpus() {
  local c="${MTS_CPUS:-}"
  [ -n "$c" ] || c=$(getconf _NPROCESSORS_ONLN 2>/dev/null)
  case "$c" in ''|*[!0-9]*) c=4 ;; esac
  printf '%s' "$c"
}

# The 1-minute load average, as printed (a decimal number).
mts_load1() {
  if [ -n "${MTS_LOAD_CMD:-}" ]; then
    bash -c "$MTS_LOAD_CMD"
  elif [ -r /proc/loadavg ]; then
    cut -d' ' -f1 /proc/loadavg
  else
    sysctl -n vm.loadavg 2>/dev/null | tr -d '{}' | awk '{print $1}'
  fi
}

# 0 when load $1 is at most $2.
mts_le() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a + 0 <= b + 0) }'; }

mts_now() { date +%s; }

# test-gate.sh and check-push.sh processes of this host, wrappers left out: the
# command line of a `test-slots.sh --run` wrapper carries the wrapped script's
# name too, and counting it would count one run twice.
mts_gate_procs() {
  ps -axww -o command= 2>/dev/null \
    | grep -E 'test-gate\.sh|check-push\.sh' \
    | grep -v -F 'test-slots.sh --run' \
    | grep -v -E 'grep|measure-test-slots' \
    | wc -l | tr -d ' '
}

# --- arguments ------------------------------------------------------------------

[ $# -ge 1 ] || die2 "사용법 — run --work <디렉터리> … / report --work <디렉터리>"
VERB="$1"; shift
WORK=""; LEVELS="8,24"; REPS=3; DIRECT=""; SECTIONS=""; GOALS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --work)     WORK="${2:-}"; shift 2 || die2 "--work 에 값이 없다" ;;
    --levels)   LEVELS="${2:-}"; shift 2 || die2 "--levels 에 값이 없다" ;;
    --reps)     REPS="${2:-}"; shift 2 || die2 "--reps 에 값이 없다" ;;
    --direct)   DIRECT="${2:-}"; shift 2 || die2 "--direct 에 값이 없다" ;;
    --sections) SECTIONS="${2:-}"; shift 2 || die2 "--sections 에 값이 없다" ;;
    --goals)    GOALS="${2:-}"; shift 2 || die2 "--goals 에 값이 없다" ;;
    *) die2 "모르는 인자: $1" ;;
  esac
done
[ -n "$WORK" ] || die2 "--work 가 없다"
case "$VERB" in run|report) ;; *) die2 "모르는 동사: $VERB (run / report)" ;; esac
RESULTS="$WORK/results.tsv"

# --- report ---------------------------------------------------------------------

mts_report() {
  [ -f "$RESULTS" ] || die2 "결과가 없다: $RESULTS"
  awk -F'\t' '
    function median(list,   n, a, i, j, t) {
      n = split(list, a, " ")
      for (i = 2; i <= n; i++) { t = a[i]; for (j = i - 1; j >= 1 && a[j] > t; j--) a[j + 1] = a[j]; a[j + 1] = t }
      if (n % 2) return a[(n + 1) / 2]
      return (a[n / 2] + a[n / 2 + 1]) / 2
    }
    /^# commit=/ { commit = substr($0, 10) }
    /^# cpus=/ { cpus = substr($0, 8) }
    /^# levels=/ { nl = split(substr($0, 10), lv, ",") }
    /^# forms=/ { nf = split(substr($0, 9), fp, " "); for (i = 1; i <= nf; i++) { split(fp[i], kv, ":"); fval[kv[1]] = kv[2] } }
    /^# work=/ { work = substr($0, 8) }
    /^# limit=/ { limit = substr($0, 9) }
    $1 == "cap" { cap = $2 }
    $1 == "trial" {
      ntr++; tl[ntr] = sprintf("%s\t수준 %s\t반복 %s\t시작 부하 %s\t부하 대기 상한 %s\tmakespan %s초\t%s", $2, $3, $4, $9, ($11 == 1 ? "도달" : "미도달"), $6, ($5 == 1 ? "유효" : "무효"))
      if ($5 == 1 && $4 != "w") {
        k = $2 SUBSEP $3; ms[k] = ms[k] " " $6; cnt[k]++
        if (!(k in mn) || $6 + 0 < mn[k] + 0) mn[k] = $6
        if (!(k in mx) || $6 + 0 > mx[k] + 0) mx[k] = $6
      }
    }
    END {
      printf "잰 커밋: %s\n", commit
      printf "CPU: %s\n", cpus
      printf "작업 꼴: %s\n", work
      printf "한계: %s\n", limit
      printf "꼴\t수준\t유효 반복\tM(초)\t최소\t최대\n"
      bad = ""
      for (f = 1; f <= 3; f++) {
        form = (f == 1 ? "off" : (f == 2 ? "auto" : "x15"))
        for (l = 1; l <= nl; l++) {
          k = form SUBSEP lv[l]
          if (cnt[k] + 0 >= 1) M[k] = median(ms[k])
          printf "%s(%s)\t%s\t%d\t%s\t%s\t%s\n", form, fval[form], lv[l], cnt[k], (cnt[k] ? M[k] : "-"), (cnt[k] ? mn[k] : "-"), (cnt[k] ? mx[k] : "-")
          if (cnt[k] + 0 < 2) bad = bad " " form "/" lv[l]
        }
      }
      printf "시도\n"
      for (i = 1; i <= ntr; i++) printf "  %s\n", tl[i]
      if (cap != "") { printf "6시간 상한에서 멈춤: 누적 %s초\n", cap; print "판정: 판정불가"; exit }
      if (bad != "") { printf "유효 반복 2회 미만:%s\n", bad; print "판정: 판정불가"; exit }
      hi = lv[nl]; lo = lv[1]
      for (l = 1; l <= nl; l++) { if (lv[l] + 0 > hi + 0) hi = lv[l]; if (lv[l] + 0 < lo + 0) lo = lv[l] }
      ma = M["auto", hi]; mb = M["x15", hi]
      small = (ma < mb ? ma : mb)
      d = ma - mb; if (d < 0) d = -d
      a = (d <= 0.02 * small || ma <= mb) ? "auto" : "x15"
      c1 = (M[a, hi] <= 0.95 * M["off", hi])
      c2 = (M[a, lo] <= 1.05 * M["off", lo])
      short = 0; n = split(ms[a SUBSEP hi], r, " ")
      for (i = 1; i <= n; i++) if (r[i] + 0 < M["off", hi] + 0) short++
      c3 = (short >= 2)
      printf "a=%s · 조건 1 %s · 조건 2 %s · 조건 3 %s (짧은 반복 %d)\n", a, (c1 ? "성립" : "불성립"), (c2 ? "성립" : "불성립"), (c3 ? "성립" : "불성립"), short
      if (c1 && c2 && c3) printf "판정: 켬 %s\n", fval[a]; else print "판정: 끔"
    }
  ' "$RESULTS"
}

if [ "$VERB" = report ]; then
  mts_report
  exit $?
fi

# --- run ------------------------------------------------------------------------

case "$REPS" in ''|*[!0-9]*|0) die2 "--reps 는 양의 정수다: $REPS" ;; esac
case "$LEVELS" in ''|*[!0-9,]*|,*|*,|*,,*) die2 "--levels 는 쉼표로 이은 양의 정수다: $LEVELS" ;; esac

[ -z "$(cd "$REPO" && git status --porcelain 2>/dev/null)" ] \
  || die2 "작업 트리에 커밋하지 않은 변경이 있다 — 복제는 커밋된 HEAD 만 가져가므로 커밋한 뒤 잰다 ($REPO)"
SHA=$(cd "$REPO" && git rev-parse --verify HEAD 2>/dev/null) || die2 "HEAD 를 읽지 못했다: $REPO"

CPUS=$(mts_cpus)
X15=$(( (3 * CPUS + 1) / 2 ))
FORMS="off:0 auto:auto x15:$X15"
WORKDESC="direct=${DIRECT:--} sections=${SECTIONS:--} goals=${GOALS:--}"
CONFIG="levels=$LEVELS reps=$REPS forms=$FORMS $WORKDESC"

mkdir -p "$WORK" || die2 "작업 디렉터리를 만들지 못했다: $WORK"
WORK=$(cd "$WORK" && pwd)
RESULTS="$WORK/results.tsv"
if [ -f "$RESULTS" ]; then
  had_sha=$(sed -n 's/^# commit=//p' "$RESULTS" | sed -n 1p)
  had_cfg=$(sed -n 's/^# config=//p' "$RESULTS" | sed -n 1p)
  [ "$had_sha" = "$SHA" ] || die2 "이 작업 디렉터리는 다른 커밋($had_sha)을 쟀다 — 지금 HEAD 는 $SHA"
  [ "$had_cfg" = "$CONFIG" ] || die2 "이 작업 디렉터리는 다른 설정을 쟀다: $had_cfg"
else
  {
    printf '# measure-test-slots v1\n'
    printf '# commit=%s\n' "$SHA"
    printf '# cpus=%s\n' "$CPUS"
    printf '# levels=%s\n' "$LEVELS"
    printf '# reps=%s\n' "$REPS"
    printf '# forms=%s\n' "$FORMS"
    printf '# work=%s\n' "$WORKDESC"
    printf '# config=%s\n' "$CONFIG"
    printf '# limit=모의 런은 CC_PIPELINE_RUN_ID 를 비워 check-push 가 실제 무인 런의 merge 모드가 아니라 head 모드로 돈다 — 베이스 병합은 꼴마다 같게 더해져 비교 방향을 바꾸지 않는다고 본다\n'
    printf '# columns=trial form level rep valid makespan run_median run_max load_start load_max load_capped outside_procs failed_runs slot_wait spent\n'
  } > "$RESULTS"
fi

mts_spent() { awk -F'\t' '$1 == "trial" { s += $15 } END { print s + 0 }' "$RESULTS"; }
mts_valid() { awk -F'\t' -v f="$1" -v l="$2" -v r="$3" '$1 == "trial" && $2 == f && $3 == l && $4 == r && $5 == 1 { n++ } END { print n + 0 }' "$RESULTS"; }
mts_invalid() { awk -F'\t' -v f="$1" -v l="$2" -v r="$3" '$1 == "trial" && $2 == f && $3 == l && $4 == r && $5 != 1 { n++ } END { print n + 0 }' "$RESULTS"; }
mts_value() { case "$1" in off) printf '0' ;; auto) printf 'auto' ;; x15) printf '%s' "$X15" ;; esac; }

# One mock run in clone $1, slots $2, store $3; its exit status is the run's.
mts_mock_run() {
  local clone="$1" slots="$2" store="$3" v rc=0
  for v in $(compgen -e | grep -E '^(CC_PIPELINE_|CC_TEST_SLOT|CHECK_PUSH_)' || true); do unset "$v"; done
  export CC_TEST_SLOTS="$slots" CC_TEST_SLOTS_DIR="$store"
  export MTS_DIRECT="$DIRECT" MTS_SECTIONS="$SECTIONS" MTS_GOALS="$GOALS"
  cd "$clone" || return 1
  if [ -n "${MTS_TASK:-}" ]; then
    bash "$MTS_TASK" < /dev/null
    return $?
  fi
  if [ -n "$DIRECT" ]; then
    bash scripts/test-gate.sh --sections "$DIRECT" < /dev/null || rc=1
  fi
  CHECK_PUSH_REUSE=0 CHECK_PUSH_SECTIONS="$SECTIONS" CHECK_PUSH_GOALS="$GOALS" \
    bash scripts/check-push.sh run < /dev/null || rc=1
  return "$rc"
}

# One trial of form $1 at level $2, repetition $3 (`w`: warm-up); appends its
# line. 0 when it was valid.
mts_trial() {
  local form="$1" level="$2" rep="$3" slots store tdir t0 tstart waited capped=0 load0
  local i pids="" sampler mk med mxr loadmax failed outside slotw tend spent valid
  slots=$(mts_value "$form")
  store="$WORK/store-$form"
  mkdir -p "$store"
  tdir="$WORK/trial-$form-$level-$rep"
  rm -rf "$tdir"; mkdir -p "$tdir/tmp" "$tdir/xdg"

  t0=$(mts_now)
  waited=0
  load0=$(mts_load1)
  while ! mts_le "$load0" "$CPUS"; do
    if [ "$waited" -ge "$LOAD_WAIT_MAX" ]; then capped=1; break; fi
    sleep 5; waited=$((waited + 5))
    load0=$(mts_load1)
  done
  outside=$(mts_gate_procs)

  printf '%s\n' "$load0" > "$tdir/loadmax"
  (
    m="$load0"
    while :; do
      sleep "$SAMPLE"
      l=$(mts_load1)
      mts_le "$l" "$m" || { m="$l"; printf '%s\n' "$m" > "$tdir/loadmax"; }
    done
  ) &
  sampler=$!

  msg "시도 $form($slots) 수준 $level 반복 $rep — 시작 부하 $load0$( [ "$capped" = 1 ] && printf ' (대기 상한 도달)')"
  i=1
  while [ "$i" -le "$level" ]; do
    (
      c="$tdir/run-$i"
      cloned=0
      git clone --quiet --shared --no-checkout "$REPO" "$c" > "$tdir/log-$i" 2>&1 \
        && (cd "$c" && git checkout --quiet --detach "$SHA") >> "$tdir/log-$i" 2>&1 \
        && cloned=1
      s=$(mts_now)
      if [ "$cloned" = 1 ]; then
        ( TMPDIR="$tdir/tmp" XDG_STATE_HOME="$tdir/xdg" mts_mock_run "$c" "$slots" "$store" ) >> "$tdir/log-$i" 2>&1
        rc=$?
      else
        rc=1
      fi
      e=$(mts_now)
      w=$(cat "$c"/.git/cc-cmds-check-push/* 2>/dev/null | sed -n 's/^자리대기=//p' | awk '{ s += $1 } END { print s + 0 }')
      printf '%s %s %s %s\n' "$rc" "$s" "$e" "$w" > "$tdir/end-$i"
    ) &
    pids="$pids $!"
    [ "$i" -lt "$level" ] && sleep "$GAP"
    i=$((i + 1))
  done
  for i in $pids; do wait "$i"; done
  kill "$sampler" 2>/dev/null; wait "$sampler" 2>/dev/null
  tend=$(mts_now)

  read -r mk med mxr failed slotw <<EOF
$(cat "$tdir"/end-* | awk '
  { n++; if ($1 != 0) f++; if (n == 1 || $2 < s0) s0 = $2; if (n == 1 || $3 > e1) e1 = $3; d[n] = $3 - $2; w += $4 }
  END {
    for (i = 2; i <= n; i++) { t = d[i]; for (j = i - 1; j >= 1 && d[j] > t; j--) d[j + 1] = d[j]; d[j + 1] = t }
    med = (n % 2) ? d[(n + 1) / 2] : (d[n / 2] + d[n / 2 + 1]) / 2
    print e1 - s0, med, d[n], f + 0, w + 0
  }')
EOF
  loadmax=$(cat "$tdir/loadmax")
  spent=$((tend - t0))
  valid=1; [ "$failed" -eq 0 ] || valid=0
  printf 'trial\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$form" "$level" "$rep" "$valid" "$mk" "$med" "$mxr" "$load0" "$loadmax" "$capped" "$outside" "$failed" "$slotw" "$spent" >> "$RESULTS"
  if [ "$valid" = 1 ]; then
    rm -rf "$tdir"
  else
    mkdir -p "$WORK/failed"
    for i in "$tdir"/log-*; do
      n=${i##*/log-}
      [ "$(cut -d' ' -f1 "$tdir/end-$n" 2>/dev/null)" = 0 ] || cp "$i" "$WORK/failed/$form-$level-$rep-$n.log"
    done
    rm -rf "$tdir"
    msg "시도 $form 수준 $level 반복 $rep 무효 — 실패한 런 $failed 개, 기록 $WORK/failed/"
  fi
  [ "$valid" = 1 ]
}

# Runs (form, level, rep) unless it already has a valid line: once more after
# an invalid one, and never a third time.
mts_due() {
  local form="$1" level="$2" rep="$3" spent
  [ "$(mts_valid "$form" "$level" "$rep")" -eq 0 ] || return 0
  while :; do
    if [ "$(mts_invalid "$form" "$level" "$rep")" -ge 2 ]; then
      msg "시도 $form 수준 $level 반복 $rep 이 두 번 실패했다 — 자리는 판정을 바꾸지 않으므로 환경이나 장치의 결함이다"
      exit 1
    fi
    spent=$(mts_spent)
    if [ "$spent" -ge "$CAP_SECS" ]; then
      printf 'cap\t%s\n' "$spent" >> "$RESULTS"
      msg "누적 ${spent}초로 상한 ${CAP_SECS}초에 닿아 남은 시도를 돌리지 않는다"
      exit 0
    fi
    mts_trial "$form" "$level" "$rep" && return 0
  done
}

if grep -q '^cap' "$RESULTS"; then
  msg "이 작업 디렉터리는 이미 상한에서 멈췄다"
  exit 0
fi

lowest=$(printf '%s\n' "$LEVELS" | tr ',' '\n' | sort -n | sed -n 1p)
mts_due auto "$lowest" w
mts_due x15 "$lowest" w
for level in $(printf '%s\n' "$LEVELS" | tr ',' '\n' | sort -n); do
  r=1
  while [ "$r" -le "$REPS" ]; do
    case $(( (r - 1) % 3 )) in
      0) order="off auto x15" ;;
      1) order="auto x15 off" ;;
      *) order="x15 off auto" ;;
    esac
    for form in $order; do mts_due "$form" "$level" "$r"; done
    r=$((r + 1))
  done
done
msg "모든 시도를 기록했다: $RESULTS"
exit 0
