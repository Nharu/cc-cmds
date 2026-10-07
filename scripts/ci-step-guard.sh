# ci-step-guard.sh — the arming line of a CI step that runs make. SOURCE it,
# on the line before the make line, from the step's own shell:
#
#   run: |
#     . scripts/ci-step-guard.sh
#     make -j"$(sysctl -n hw.ncpu)" test-darwin-narrow
#
# WHY A SOURCED LINE. The per-suite wrapper (scripts/suite-guard.sh) reaps what
# a suite leaves when the suite ends. When make itself stalls, nothing after the
# make line ever runs, and a stalled foreground make also keeps the step shell's
# own traps from running until it returns. So the step needs a deadline that is
# armed before make starts and acts on its own. Only the step shell lives for
# all of make's life, can hold a marker that make and every recipe inherit, and
# can trap its own exit, which is why this is sourced rather than run.
#
# WHAT IT ARMS.
#   - A marker file on the literal fd 8, after recording the epoch. make and
#     everything under it inherit it, so the step's holders are the processes
#     `lsof` lists on that file at fd 8 (the same membership rule as the
#     wrapper's fd 9).
#   - A positive control: `lsof` must list this shell holding the marker. In
#     strict mode a missing `lsof`, a non-zero `lsof` or a listing without this
#     shell fails the step here, before make starts — an empty listing is never
#     read as "nothing left", because `lsof -t` exits 1 both for no holder and
#     for several errors.
#   - The step deadline CC_JOB_T0 + CC_JOB_BUDGET_S - CC_STEP_DUMP_MARGIN_S,
#     exported as an absolute epoch so a suite that starts late in the `-j`
#     queue still falls before it. CC_JOB_T0 is written to $GITHUB_ENV by the
#     job's first step; in strict mode its absence fails the arming. Local runs
#     have no deadline.
#   - One watcher process, started before the traps and before make, holding
#     neither the marker nor the jobserver pipe, so it can never hold make. It
#     wakes every second without forking, ends as soon as this shell is gone,
#     and at the deadline dumps and reaps the marker's holders other than this
#     shell — make among them — and exits 1. make then returns non-zero, `-e`
#     takes the shell to its EXIT trap, and the trap ends the step.
#   - The EXIT trap: stop the watcher, release this shell's own copy of the
#     marker, sweep what still holds it, remove it, and end with make's rc, or
#     1 in strict mode when the sweep found something, or 0.
#
# The step shell is `bash -e` with no `pipefail` and this file keeps it that
# way, so every command here is guarded with `|| …` and no pipeline is used.
#
# Environment: CC_SUITE_GUARD_STRICT (1 = strict), CC_JOB_T0, CC_JOB_BUDGET_S,
# CC_STEP_DUMP_MARGIN_S (default 60), CC_SUITE_GUARD_LSOF (default `lsof`).
#
# Compatibility: bash 3.2 (macOS).

cc_step_strict=0
[ "${CC_SUITE_GUARD_STRICT:-}" = "1" ] && cc_step_strict=1
cc_step_lsof="${CC_SUITE_GUARD_LSOF:-lsof}"
cc_step_sg="$(dirname "${BASH_SOURCE[0]}")/suite-guard.sh"

cc_step_now() { perl -MTime::HiRes=time -e 'printf "%.3f\n", time' 8<&- || echo 0; }

cc_step_fail() {
  if [ "$cc_step_strict" = 1 ]; then
    printf '::error::ci-step-guard: %s — make 를 시작하지 않는다\n' "$1"
    return 1
  fi
  printf 'NOTE: ci-step-guard: %s — 단계 표지 없이 진행한다\n' "$1"
  return 0
}

cc_step_arm() {
  local t0 t1 out err ver
  printf 'ci-step-guard: make=%s\n' "$(command -v make || echo 없음)"
  ver=$(mktemp "${TMPDIR:-/tmp}/cc-step-ver.XXXXXX") || ver=""
  if [ -n "$ver" ]; then
    make --version >"$ver" 2>&1 || true
    printf 'ci-step-guard: %s\n' "$(sed -n 1p "$ver" || true)"
    rm -f "$ver" || true
  fi

  CC_STEP_MARKER_EPOCH=$(date +%s) || CC_STEP_MARKER_EPOCH=0
  CC_STEP_MARKER=$(mktemp "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/cc-step.XXXXXX") || CC_STEP_MARKER=""
  if [ -z "$CC_STEP_MARKER" ]; then
    cc_step_fail "표지 파일을 만들지 못했다"
    return $?
  fi
  exec 8<"$CC_STEP_MARKER" || { cc_step_fail "표지를 fd 8 로 열지 못했다"; return $?; }

  out="$CC_STEP_MARKER.pc"
  err="$CC_STEP_MARKER.pc.err"
  if ! command -v "$cc_step_lsof" >/dev/null 2>&1; then
    rm -f "$CC_STEP_MARKER" || true
    exec 8<&- || true
    cc_step_fail "양성 대조 실패: lsof 가 없다"
    return $?
  fi
  printf 'ci-step-guard: lsof=%s\n' "$(command -v "$cc_step_lsof")"
  t0=$(cc_step_now)
  "$cc_step_lsof" -w -t -- "$CC_STEP_MARKER" >"$out" 2>"$err" 8<&- || {
    rm -f "$out" "$err" "$CC_STEP_MARKER" || true
    exec 8<&- || true
    cc_step_fail "양성 대조 실패: lsof 가 0 이 아닌 값으로 끝났다"
    return $?
  }
  t1=$(cc_step_now)
  if ! grep -qx "$$" "$out"; then
    rm -f "$out" "$err" "$CC_STEP_MARKER" || true
    exec 8<&- || true
    cc_step_fail "양성 대조 실패: lsof 가 표지를 쥔 단계 셸(pid $$)을 나열하지 않았다"
    return $?
  fi
  rm -f "$out" "$err" || true
  printf 'ci-step-guard: 양성 대조 통과 (%ss)\n' "$(perl -e 'printf "%.2f", $ARGV[1] - $ARGV[0]' "$t0" "$t1" 8<&- || echo '?')"

  CC_STEP_DEADLINE_EPOCH=0
  case "${CC_JOB_T0:-}${CC_JOB_BUDGET_S:-0}${CC_STEP_DUMP_MARGIN_S:-60}" in
    *[!0-9]*)
      rm -f "$CC_STEP_MARKER" || true
      exec 8<&- || true
      cc_step_fail "CC_JOB_T0·CC_JOB_BUDGET_S·CC_STEP_DUMP_MARGIN_S 중 숫자가 아닌 값이 있다"
      return $? ;;
  esac
  if [ -n "${CC_JOB_T0:-}" ]; then
    CC_STEP_DEADLINE_EPOCH=$(( CC_JOB_T0 + ${CC_JOB_BUDGET_S:-0} - ${CC_STEP_DUMP_MARGIN_S:-60} ))
    printf 'ci-step-guard: 단계 마감 epoch=%s (잡 시작 %s + 예산 %s - 덤프 여유 %s)\n' \
      "$CC_STEP_DEADLINE_EPOCH" "$CC_JOB_T0" "${CC_JOB_BUDGET_S:-0}" "${CC_STEP_DUMP_MARGIN_S:-60}"
  elif [ "$cc_step_strict" = 1 ]; then
    rm -f "$CC_STEP_MARKER" || true
    exec 8<&- || true
    cc_step_fail "CC_JOB_T0 이 없어 단계 마감을 정할 수 없다"
    return $?
  fi
  export CC_STEP_MARKER CC_STEP_MARKER_EPOCH CC_STEP_DEADLINE_EPOCH

  perl -e '
    my ($pp, $dl, $marker, $epoch, $sg) = @ARGV;
    while (1) {
      sleep 1;
      exit 0 if getppid() != $pp;
      if ($dl > 0 && time >= $dl) {
        print "::error::ci-step-guard: 단계 마감에 이르렀다 — 표지 보유자를 덤프하고 거둔다\n";
        system("bash", $sg, "--sweep", "--fd", "8", "--marker", $marker,
               "--epoch", $epoch, "--exclude", $pp, "--classify");
        exit 1;
      }
    }' "$$" "$CC_STEP_DEADLINE_EPOCH" "$CC_STEP_MARKER" "$CC_STEP_MARKER_EPOCH" "$cc_step_sg" 8<&- &
  CC_STEP_WD=$!
  trap cc_step_exit EXIT
  trap 'exit 143' TERM
  trap 'exit 130' INT
  return 0
}

cc_step_exit() {
  cc_step_rc=$?
  set +e
  kill -TERM "$CC_STEP_WD" 2>/dev/null; wait "$CC_STEP_WD" 2>/dev/null
  exec 8<&-
  bash "$cc_step_sg" --sweep --fd 8 --marker "$CC_STEP_MARKER" --epoch "$CC_STEP_MARKER_EPOCH" --exclude "$$"
  cc_step_src=$?
  rm -f "$CC_STEP_MARKER"
  if [ "$cc_step_rc" != 0 ]; then
    exit "$cc_step_rc"
  fi
  if [ "$cc_step_strict" = 1 ] && [ "$cc_step_src" != 0 ]; then
    printf '::error::ci-step-guard: make 가 끝난 뒤 단계 표지를 쥔 프로세스가 있었다(위 덤프)\n'
    exit 1
  fi
  exit 0
}

cc_step_arm || return 1
return 0
