#!/usr/bin/env bash
# The whole-suite gate run on master: whether a scheduled run is due, and the
# failure issue it keeps.
#
# THE WHOLE SUITE RUNS ON A SCHEDULE, NOT ON EVERY PUSH. `gate.yml` wakes every
# four hours on master and can be started by hand (`workflow_dispatch`). A pull
# request runs only the sections `scripts/gate-select.sh` picks, so this run is
# the one that measures the merged master tree as a whole: the regressions a
# narrowed run did not see, and the paths outside the gate filter the suite
# reads.
#
# A SCHEDULED RUN IS DUE WHEN MASTER MOVED SINCE THE LAST WHOLE RUN. The last
# whole run is the newest master run of this workflow whose event is schedule
# or workflow_dispatch and whose conclusion is success or failure; its head sha
# is the last whole commit. A run that was cancelled never finished measuring,
# so it is passed over. When that commit differs from the current one, master
# took at least one merge (or a direct push) since, and the run is due: which
# paths the merge changed is not looked at, because the suite reads paths the
# filter does not name. Two shas are compared and nothing is fetched, so the
# depth-1 checkout of the plan job is enough. With no earlier run it is due. A
# skipped round ends in success and becomes the next round's reference, which
# moves nothing: it was skipped because the two commits were the same. A run
# started by hand is always due.
#
# A ROUND THAT CANNOT DECIDE RUNS THE WHOLE SUITE. When the run list cannot be
# read, `due` says `run=1` and exits 0. Reading the failure as a skip would end
# the run in success with nothing measured, make it the next round's reference
# and keep the failure report from running at all.
#
# Usage:
#   bash scripts/gate-full.sh due [--sha SHA] [--event NAME]
#       prints `run=<0|1>` on stdout for the workflow to add to $GITHUB_OUTPUT,
#       and one `gate-full: 판정 …` line with the reason on stderr. The sha
#       defaults to GITHUB_SHA, the event to GITHUB_EVENT_NAME; the repository
#       is GITHUB_REPOSITORY and this run's id GITHUB_RUN_ID. An event other
#       than schedule is always due
#   bash scripts/gate-full.sh --self-test
#
# GATE_FULL_RUNS_JSON names a file holding the run list answer
# (`{"workflow_runs":[...]}`) to read instead of asking the API — what the
# self-test hands it; an empty or missing file is a read that failed.
#
# Exit codes: 0 done (a round that could not decide included), 2 usage.

set -uo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)

full_usage() {
  printf 'gate-full: 사용법 — due [--sha SHA] [--event NAME] / --self-test\n' >&2
  exit 2
}

# The master run list of this workflow, newest first, as the API answers it.
# Fails when it cannot be read.
full_runs_json() {
  if [ -n "${GATE_FULL_RUNS_JSON:-}" ]; then
    [ -s "$GATE_FULL_RUNS_JSON" ] || return 1
    cat "$GATE_FULL_RUNS_JSON"
    return 0
  fi
  [ -n "${GITHUB_REPOSITORY:-}" ] || return 1
  gh api "repos/$GITHUB_REPOSITORY/actions/workflows/gate.yml/runs?branch=master&per_page=100" 2>/dev/null
}

# Prints `<head sha>` of the last whole run, nothing when there is none; fails
# when the list cannot be read. The current run itself is left out by id.
full_last_whole() {
  local js
  js=$(full_runs_json) || return 1
  printf '%s' "$js" | jq -r --arg repo "${GITHUB_REPOSITORY:-}" --arg self "${GITHUB_RUN_ID:-}" '
    [.workflow_runs[]
      | select(($repo == "") or (.head_repository.full_name == $repo))
      | select(.event == "schedule" or .event == "workflow_dispatch")
      | select(.conclusion == "success" or .conclusion == "failure")
      | select((.id | tostring) != $self)]
    | sort_by(.created_at) | reverse | (.[0].head_sha // "")' 2>/dev/null
}

full_due() {
  local sha="${GITHUB_SHA:-}" event="${GITHUB_EVENT_NAME:-}" last
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --sha)   [ "$#" -ge 2 ] || full_usage; sha="$2"; shift 2 ;;
      --event) [ "$#" -ge 2 ] || full_usage; event="$2"; shift 2 ;;
      *) printf 'gate-full: 모르는 인자입니다: %s\n' "$1" >&2; full_usage ;;
    esac
  done
  if [ "$event" != "schedule" ]; then
    printf 'run=1\n'
    printf 'gate-full: 판정 전량 — 이벤트 %s 는 판정 없이 전량입니다\n' "${event:-없음}" >&2
    return 0
  fi
  if [ -z "$sha" ]; then
    printf 'run=1\n'
    printf 'gate-full: 판정 전량 — 현재 커밋을 알 수 없어 판정하지 못했습니다\n' >&2
    return 0
  fi
  if ! last=$(full_last_whole); then
    printf 'run=1\n'
    printf 'gate-full: 판정 전량 — 실행 목록을 읽지 못해 판정하지 못했습니다\n' >&2
    return 0
  fi
  if [ -z "$last" ]; then
    printf 'run=1\n'
    printf 'gate-full: 판정 전량 — 앞선 전량 실행이 없습니다\n' >&2
  elif [ "$last" = "$sha" ]; then
    printf 'run=0\n'
    printf 'gate-full: 판정 건너뜀 — 앞선 전량 커밋 %s 뒤로 master 가 움직이지 않았습니다\n' "$last" >&2
  else
    printf 'run=1\n'
    printf 'gate-full: 판정 전량 — 앞선 전량 커밋 %s 와 현재 커밋 %s 가 다릅니다\n' "$last" "$sha" >&2
  fi
  return 0
}

# --- self-test ---------------------------------------------------------------

full_self_test() {
  local passed=0 failed=0 T out err rc
  ok()  { passed=$((passed + 1)); printf 'PASS: %s\n' "$1"; }
  bad() { failed=$((failed + 1)); printf 'FAIL: %s — %s\n' "$1" "${2:-}" >&2; }
  if ! command -v jq >/dev/null 2>&1; then
    bad "gate-full 자기 시험" "jq 가 없어 실행 목록을 읽지 못합니다"
    printf 'gate-full self-test: %d passed, %d failed\n' "$passed" "$failed"
    return 1
  fi
  T=$(mktemp -d "${TMPDIR:-/tmp}/gate-full-selftest.XXXXXX")

  # One run list entry: `<id> <event> <conclusion> <head sha> <created_at>`.
  mk_runs() {
    local f="$1" sep="" id ev co sh cr; shift
    { printf '{"workflow_runs":['
      for e in "$@"; do
        read -r id ev co sh cr <<EOF
$e
EOF
        printf '%s{"id":%s,"event":"%s","conclusion":%s,"head_sha":"%s","created_at":"%s","head_repository":{"full_name":"o/r"}}' \
          "$sep" "$id" "$ev" "$( [ "$co" = "-" ] && printf 'null' || printf '"%s"' "$co")" "$sh" "$cr"
        sep=","
      done
      printf ']}\n'; } > "$f"
  }
  due() { GATE_FULL_RUNS_JSON="$1" GITHUB_REPOSITORY=o/r GITHUB_RUN_ID=99 bash "$0" due "${@:2}"; }

  # (a) the last whole run's commit is the current one: skip.
  mk_runs "$T/same.json" '99 schedule - CUR 2026-01-03T00:00:00Z' '11 pull_request success CUR 2026-01-02T12:00:00Z' \
    '10 schedule success CUR 2026-01-02T00:00:00Z' '9 schedule success OLD 2026-01-01T00:00:00Z'
  out=$(due "$T/same.json" --event schedule --sha CUR 2>"$T/err"); rc=$?
  if [ "$rc" = "0" ] && [ "$out" = "run=0" ] && grep -q '^gate-full: 판정 건너뜀 — 앞선 전량 커밋 CUR ' "$T/err"; then
    ok "(a) 앞선 전량 커밋이 현재 커밋과 같으면 run=0"
  else
    bad "(a) 앞선 전량 커밋이 현재 커밋과 같으면 run=0" "rc=$rc 「${out}」 $(cat "$T/err")"
  fi

  # (b) master moved: due. A failure is a reference as well.
  mk_runs "$T/diff.json" '10 schedule failure OLD 2026-01-02T00:00:00Z' '9 schedule success OLDER 2026-01-01T00:00:00Z'
  out=$(due "$T/diff.json" --event schedule --sha CUR 2>"$T/err"); rc=$?
  if [ "$rc" = "0" ] && [ "$out" = "run=1" ] && grep -q '^gate-full: 판정 전량 — 앞선 전량 커밋 OLD 와 현재 커밋 CUR 가 다릅니다$' "$T/err"; then
    ok "(b) 앞선 전량 커밋(실패 실행 포함)이 현재 커밋과 다르면 run=1"
  else
    bad "(b) 앞선 전량 커밋(실패 실행 포함)이 현재 커밋과 다르면 run=1" "rc=$rc 「${out}」 $(cat "$T/err")"
  fi

  # (c) no earlier whole run at all: due.
  mk_runs "$T/none.json" '11 pull_request success CUR 2026-01-02T12:00:00Z'
  out=$(due "$T/none.json" --event schedule --sha CUR 2>"$T/err"); rc=$?
  if [ "$rc" = "0" ] && [ "$out" = "run=1" ] && grep -q '앞선 전량 실행이 없습니다' "$T/err"; then
    ok "(c) 앞선 전량 실행이 없으면 run=1"
  else
    bad "(c) 앞선 전량 실행이 없으면 run=1" "rc=$rc 「${out}」 $(cat "$T/err")"
  fi

  # (d) only cancelled runs, even on the current commit: none is a reference.
  mk_runs "$T/cancel.json" '10 schedule cancelled CUR 2026-01-02T00:00:00Z' '9 workflow_dispatch cancelled CUR 2026-01-01T00:00:00Z'
  out=$(due "$T/cancel.json" --event schedule --sha CUR 2>"$T/err"); rc=$?
  if [ "$rc" = "0" ] && [ "$out" = "run=1" ]; then
    ok "(d) cancelled 실행만 있으면 기준이 없어 run=1"
  else
    bad "(d) cancelled 실행만 있으면 기준이 없어 run=1" "rc=$rc 「${out}」 $(cat "$T/err")"
  fi

  # (e) a run started by hand is always due, even with nothing moved.
  out=$(due "$T/same.json" --event workflow_dispatch --sha CUR 2>"$T/err"); rc=$?
  if [ "$rc" = "0" ] && [ "$out" = "run=1" ] && grep -q '이벤트 workflow_dispatch 는 판정 없이 전량' "$T/err"; then
    ok "(e) workflow_dispatch 는 판정 없이 run=1"
  else
    bad "(e) workflow_dispatch 는 판정 없이 run=1" "rc=$rc 「${out}」 $(cat "$T/err")"
  fi

  # (f) the run list cannot be read: run=1 and exit 0, never a skip.
  : > "$T/empty.json"
  out=$(due "$T/empty.json" --event schedule --sha CUR 2>"$T/err"); rc=$?
  if [ "$rc" = "0" ] && [ "$out" = "run=1" ] && grep -q '실행 목록을 읽지 못해 판정하지 못했습니다' "$T/err"; then
    ok "(f) 실행 목록을 읽지 못하면 run=1 이고 종료 0"
  else
    bad "(f) 실행 목록을 읽지 못하면 run=1 이고 종료 0" "rc=$rc 「${out}」 $(cat "$T/err")"
  fi
  printf 'not json' > "$T/broken.json"
  out=$(due "$T/broken.json" --event schedule --sha CUR 2>"$T/err"); rc=$?
  if [ "$rc" = "0" ] && [ "$out" = "run=1" ]; then
    ok "(f) 읽은 실행 목록이 JSON 이 아니어도 run=1 이고 종료 0"
  else
    bad "(f) 읽은 실행 목록이 JSON 이 아니어도 run=1 이고 종료 0" "rc=$rc 「${out}」 $(cat "$T/err")"
  fi

  rm -rf "$T"
  printf 'gate-full self-test: %d passed, %d failed\n' "$passed" "$failed"
  # A floor on the count, so a refactor that silently skips cases cannot pass.
  if [ "$passed" -lt 7 ]; then
    printf 'gate-full self-test: 통과 수 %d 가 하한 7 에 못 미칩니다\n' "$passed" >&2
    return 1
  fi
  [ "$failed" = "0" ]
}

# --- main --------------------------------------------------------------------

[ "$#" -ge 1 ] || full_usage
cmd="$1"; shift
case "$cmd" in
  due)         full_due "$@"; exit $? ;;
  --self-test) full_self_test; exit $? ;;
  *) printf 'gate-full: 모르는 하위명령입니다: %s\n' "$cmd" >&2; full_usage ;;
esac
