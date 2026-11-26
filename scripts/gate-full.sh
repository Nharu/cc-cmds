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
# A WHOLE RUN THAT FAILS KEEPS ONE ISSUE OPEN. `report` runs last in a whole
# master run, whatever the jobs before it ended in. When any of gate-plan,
# gate-shards, shard-coverage and gate-report did not succeed it writes the
# observed facts — the run, the commit, the rows that failed and their
# sections, the last whole commit that succeeded, the first-parent merges
# since and which of them are candidates — into the one open issue labelled
# `gate-full-failure`, opening it (and the label) when there is none. A
# candidate is a merge the selector, run on that merge, answers with the whole
# suite or with a list holding a failed section; with no candidate the report
# says the failure lies outside the narrowed selection. When every job
# succeeded and such an issue is open, the run is written into it and it is
# closed. A run that is not a schedule or workflow_dispatch run on master
# writes nothing: a branch's trial run must never open or close master's issue.
#
# A ROUND THAT RAN NOTHING STILL LOOKS FOR A GAP. Every scheduled or manual
# master round runs `report`, a skipped one (`--run 0`) included. It finds the
# last whole success; when master took first-parent merges after that commit
# and the success is older than three intervals (twelve hours), the gap — the
# success's run, commit and time, the merges since and this round's run and
# `run` value — is written into the same issue, whatever the round ended in. A
# round that is a whole success has no gap. Not finding a whole success at all
# is written as a gap too. A gap never closes the issue: the next whole
# success does. This measures the outcome rather than each way the failure
# report could drop out, so a way nobody has named yet still reaches a person.
#
# THE CANDIDATES ARE COUNTED UP TO A CAP. The selector runs once per merge, so
# a long failing streak, or no successful whole run at all, would leave the
# job unbounded and the issue unwritten. Only the newest CAP merges (30 unless
# --cap says) are computed and the rest is reported as `후보 계산 생략 N건`;
# with no last successful whole commit the span is the newest CAP merges.
#
# Usage:
#   bash scripts/gate-full.sh due [--sha SHA] [--event NAME]
#       prints `run=<0|1>` on stdout for the workflow to add to $GITHUB_OUTPUT,
#       and one `gate-full: 판정 …` line with the reason on stderr. The sha
#       defaults to GITHUB_SHA, the event to GITHUB_EVENT_NAME; the repository
#       is GITHUB_REPOSITORY and this run's id GITHUB_RUN_ID. An event other
#       than schedule is always due
#   bash scripts/gate-full.sh report --plan R --shards R --coverage R --report R
#                                    [--run V] [--plan-dir DIR] [--results-dir DIR]
#                                    [--select PATH] [--cap N]
#       R is each job's result (success, failure, cancelled, skipped). V is the
#       plan's `run` output: `0` reports a gap only, anything else (an empty
#       value from a plan that failed before deciding included) is a whole
#       run. DIR holds the plan's table.tsv and the shards' result-<row>.tsv
#       files. Run from the repository with its full history; the ref is
#       GITHUB_REF, the commit GITHUB_SHA. GATE_FULL_NOW, in epoch seconds,
#       stands in for the clock
#   bash scripts/gate-full.sh --self-test
#
# GATE_FULL_RUNS_JSON names a file holding the run list answer
# (`{"workflow_runs":[...]}`) to read instead of asking the API — what the
# self-test hands it; an empty or missing file is a read that failed.
# GATE_FULL_GH names the program called in place of `gh`.
#
# Exit codes: 0 done (a round that could not decide included), 1 the issue
# could not be written, 2 usage.

set -uo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)

full_usage() {
  printf 'gate-full: 사용법 — due [--sha SHA] [--event NAME] / report --plan R --shards R --coverage R --report R [--run V] [--plan-dir DIR] [--results-dir DIR] [--select PATH] [--cap N] / --self-test\n' >&2
  exit 2
}

full_gh() { "${GATE_FULL_GH:-gh}" "$@"; }

# The master run list of this workflow, newest first, as the API answers it.
# Fails when it cannot be read.
full_runs_json() {
  if [ -n "${GATE_FULL_RUNS_JSON:-}" ]; then
    [ -s "$GATE_FULL_RUNS_JSON" ] || return 1
    cat "$GATE_FULL_RUNS_JSON"
    return 0
  fi
  [ -n "${GITHUB_REPOSITORY:-}" ] || return 1
  full_gh api "repos/$GITHUB_REPOSITORY/actions/workflows/gate.yml/runs?branch=master&per_page=100" 2>/dev/null
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

# --- report ------------------------------------------------------------------

# Prints `<run id> <head sha> <created_at>` of the newest whole run that
# succeeded, nothing when there is none; fails when the run list cannot be
# read. A run that ended in success is a whole success only when its shards ran
# and succeeded: a skipped round also ends in success and sits on the commit of
# the last whole run, which may have failed. At most twenty runs are asked for
# their jobs.
full_last_success() {
  local js ids id sha cr jobs
  js=$(full_runs_json) || return 1
  ids=$(printf '%s' "$js" | jq -r --arg repo "${GITHUB_REPOSITORY:-}" --arg self "${GITHUB_RUN_ID:-}" '
    [.workflow_runs[]
      | select(($repo == "") or (.head_repository.full_name == $repo))
      | select(.event == "schedule" or .event == "workflow_dispatch")
      | select(.conclusion == "success")
      | select((.id | tostring) != $self)]
    | sort_by(.created_at) | reverse | .[0:20][] | "\(.id) \(.head_sha) \(.created_at)"' 2>/dev/null) || return 1
  while read -r id sha cr; do
    [ -n "$id" ] || continue
    jobs=$(full_gh api "repos/${GITHUB_REPOSITORY:-}/actions/runs/$id/jobs?per_page=100" 2>/dev/null) || continue
    if printf '%s' "$jobs" | jq -e '[.jobs[] | select((.name | startswith("gate-shards")) and .conclusion == "success")] | length > 0' > /dev/null 2>&1; then
      printf '%s %s %s\n' "$id" "$sha" "$cr"
      return 0
    fi
  done <<EOF
$ids
EOF
  return 0
}

# The gap lines for the issue, printed when there is a gap and nothing
# otherwise: the last whole success (`<run id> <sha> <created_at>`, empty when
# none was found) is older than three four-hour intervals and master took
# first-parent merges after its commit. A time that cannot be read, or a
# commit not in this history, counts as a gap: the doubt is shown to a person
# rather than kept quiet.
full_gap_lines() {
  local last_line="$1" note="$2" sha="$3" url="$4" runv="$5" id lsha cr t now n age
  local base="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-}/actions/runs"
  if [ -z "$last_line" ]; then
    printf '공백 보고 — 마지막 전량 성공을 찾지 못했습니다%s\n\n' "${note:+ ($note)}"
    printf -- '- 이번 회차: %s · run=%s\n' "$url" "${runv:-비어 있음}"
    return 0
  fi
  read -r id lsha cr <<EOF
$last_line
EOF
  if git cat-file -e "$lsha^{commit}" 2>/dev/null && git merge-base --is-ancestor "$lsha" "${sha:-HEAD}" 2>/dev/null; then
    n=$(git rev-list --first-parent --merges --count "$lsha..${sha:-HEAD}")
  else
    n="알 수 없음 (커밋이 이 이력에 없습니다)"
  fi
  [ "$n" != "0" ] || return 0
  now="${GATE_FULL_NOW:-$(date -u +%s)}"
  t=$(jq -rn --arg c "$cr" '$c | fromdateiso8601' 2>/dev/null) || t=""
  case "$t" in
    ''|*[!0-9]*) age="알 수 없음" ;;
    *) [ $(( now - t )) -gt 43200 ] || return 0
       age="$(( (now - t) / 3600 ))시간" ;;
  esac
  printf '공백 보고 — 마지막 전량 성공이 12시간보다 오래되었고 그 뒤 master 에 머지가 있습니다\n\n'
  printf -- '- 마지막 전량 성공 실행: %s/%s\n' "$base" "$id"
  printf -- '- 커밋: %s · 시각: %s (%s 전)\n' "$lsha" "$cr" "$age"
  printf -- '- 그 뒤 first-parent 머지: %s건\n' "$n"
  printf -- '- 이번 회차: %s · run=%s\n' "$url" "${runv:-비어 있음}"
}

# Writes the body into the open issue as a comment, or opens one with the
# label (made first when the repository lacks it).
full_write_issue() {
  local repo="$1" label="$2" open="$3" body="$4" what="$5"
  if ! full_gh label list --repo "$repo" --search "$label" --json name --jq '.[].name' 2>/dev/null | grep -qx "$label"; then
    full_gh label create "$label" --repo "$repo" --color B60205 --description 'gate 정기 전량 실패' > /dev/null 2>&1 \
      || printf 'gate-full: %s 라벨을 만들지 못했습니다\n' "$label" >&2
  fi
  if [ -n "$open" ]; then
    if full_gh issue comment "$open" --repo "$repo" --body-file "$body" > /dev/null; then
      printf 'gate-full: %s — 이슈 #%s 에 코멘트를 달았습니다\n' "$what" "$open" >&2
      return 0
    fi
  elif full_gh issue create --repo "$repo" --title "gate 정기 전량 실패" --label "$label" --body-file "$body" > /dev/null; then
    printf 'gate-full: %s — %s 라벨 이슈를 열었습니다\n' "$what" "$label" >&2
    return 0
  fi
  printf 'gate-full: 보고 실패 — 이슈를 쓰지 못했습니다\n' >&2
  return 1
}

# `<row>\t<ids>\t<what>` for every row of the table that carries sections and
# did not end with exit 0 and a total line without failures. The result files
# record a row's exit code and total line, not which section failed, so the
# row and its section list are what the report can name.
full_failed_rows() {
  local table="$1" res="$2"
  [ -f "$table" ] || return 1
  awk -F '\t' -v D="$res" '
    $3 != "" {
      f = D "/result-" $1 ".tsv"; line = ""
      if ((getline line < f) <= 0) { print $1 "\t" $3 "\t결과 없음"; next }
      close(f)
      split(line, a, "\t")
      if (a[2] != "0") { print $1 "\t" $3 "\t종료 " a[2]; next }
      if (a[3] !~ /^test-gate: [0-9]+ passed, 0 failed$/) print $1 "\t" $3 "\t" a[3]
    }' "$table"
}

full_report() {
  local plan="" shards="" cov="" rep="" runv="" pdir="" rdir="" sel_script="$script_dir/gate-select.sh" cap=30
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --plan)        [ "$#" -ge 2 ] || full_usage; plan="$2"; shift 2 ;;
      --run)         [ "$#" -ge 2 ] || full_usage; runv="$2"; shift 2 ;;
      --shards)      [ "$#" -ge 2 ] || full_usage; shards="$2"; shift 2 ;;
      --coverage)    [ "$#" -ge 2 ] || full_usage; cov="$2"; shift 2 ;;
      --report)      [ "$#" -ge 2 ] || full_usage; rep="$2"; shift 2 ;;
      --plan-dir)    [ "$#" -ge 2 ] || full_usage; pdir="$2"; shift 2 ;;
      --results-dir) [ "$#" -ge 2 ] || full_usage; rdir="$2"; shift 2 ;;
      --select)      [ "$#" -ge 2 ] || full_usage; sel_script="$2"; shift 2 ;;
      --cap)         [ "$#" -ge 2 ] || full_usage; cap="$2"; shift 2 ;;
      *) printf 'gate-full: 모르는 인자입니다: %s\n' "$1" >&2; full_usage ;;
    esac
  done
  [ -n "$plan" ] && [ -n "$shards" ] && [ -n "$cov" ] && [ -n "$rep" ] || full_usage
  case "$cap" in ''|*[!0-9]*|0) printf 'gate-full: --cap 은 양의 정수입니다: %s\n' "$cap" >&2; full_usage ;; esac

  local ref="${GITHUB_REF:-}" ev="${GITHUB_EVENT_NAME:-}"
  if [ "$ref" != "refs/heads/master" ] || { [ "$ev" != "schedule" ] && [ "$ev" != "workflow_dispatch" ]; }; then
    printf 'gate-full: 보고 안 함 — ref %s · 이벤트 %s 는 master 의 정기·수동 실행이 아닙니다\n' "${ref:-없음}" "${ev:-없음}" >&2
    return 0
  fi

  local repo="${GITHUB_REPOSITORY:-}" sha="${GITHUB_SHA:-}" label="gate-full-failure" open body rc
  local url="${GITHUB_SERVER_URL:-https://github.com}/$repo/actions/runs/${GITHUB_RUN_ID:-}"
  if ! open=$(full_gh issue list --repo "$repo" --label "$label" --state open --json number --jq '.[0].number // empty' 2>/dev/null); then
    printf 'gate-full: 보고 실패 — %s 라벨의 열린 이슈를 읽지 못했습니다\n' "$label" >&2
    return 1
  fi
  open=$(printf '%s' "$open" | head -n 1)
  body=$(mktemp "${TMPDIR:-/tmp}/gate-full-report.XXXXXX") || return 1

  # The last whole success, which both the gap and the candidate span read.
  local last_line="" last="" last_note="" gap=""
  if ! last_line=$(full_last_success); then
    last_line=""; last_note="실행 목록을 읽지 못했습니다"
  fi
  last=$(printf '%s' "$last_line" | cut -d ' ' -f 2)

  # A skipped round reports a gap and nothing else, and never closes.
  if [ "$runv" = "0" ]; then
    gap=$(full_gap_lines "$last_line" "$last_note" "$sha" "$url" "$runv")
    if [ -z "$gap" ]; then
      printf 'gate-full: 건너뛴 회차 — 공백 아님 (마지막 전량 성공 %s)\n' "${last:-없음}" >&2
      rm -f "$body"
      return 0
    fi
    printf '%s\n' "$gap" > "$body"
    full_write_issue "$repo" "$label" "$open" "$body" "공백 보고"
    rc=$?; rm -f "$body"; return "$rc"
  fi

  if [ "$plan" = "success" ] && [ "$shards" = "success" ] && [ "$cov" = "success" ] && [ "$rep" = "success" ]; then
    if [ -z "$open" ]; then
      printf 'gate-full: 전량 성공 — 열린 %s 이슈가 없습니다\n' "$label" >&2
      rm -f "$body"
      return 0
    fi
    { printf '정기 전량 성공\n\n'
      printf -- '- 실행: %s\n' "$url"
      printf -- '- 커밋: %s\n' "${sha:-알 수 없음}"; } > "$body"
    if full_gh issue comment "$open" --repo "$repo" --body-file "$body" > /dev/null \
       && full_gh issue close "$open" --repo "$repo" > /dev/null; then
      printf 'gate-full: 전량 성공 — 이슈 #%s 에 성공 실행을 적고 닫았습니다\n' "$open" >&2
      rm -f "$body"
      return 0
    fi
    printf 'gate-full: 보고 실패 — 이슈 #%s 를 닫지 못했습니다\n' "$open" >&2
    rm -f "$body"
    return 1
  fi

  # The failed rows and their sections.
  local rows="" failed="" rows_note=""
  if [ -z "$pdir" ] || [ ! -f "$pdir/table.tsv" ]; then
    rows_note="실패한 절을 모으지 못했습니다 — 계획 표가 없습니다"
  else
    rows=$(full_failed_rows "$pdir/table.tsv" "${rdir:-/nonexistent}")
    if [ -z "$rows" ]; then
      rows_note="샤드 결과에서 실패한 행을 찾지 못했습니다"
    else
      failed=$(printf '%s\n' "$rows" | cut -f 2 | tr ',' '\n' | grep -v '^$' | sort -u | tr '\n' ',' | sed 's/,$//')
    fi
  fi

  # The span of first-parent merges.
  local merges span
  if [ -n "$last" ] && git cat-file -e "$last^{commit}" 2>/dev/null && git merge-base --is-ancestor "$last" "${sha:-HEAD}" 2>/dev/null; then
    merges=$(git rev-list --first-parent --merges "$last..${sha:-HEAD}")
    span="마지막 성공 전량 커밋 $last 부터"
  else
    merges=$(git rev-list --first-parent --merges -n "$cap" "${sha:-HEAD}")
    if [ -n "$last" ]; then
      span="마지막 성공 전량 커밋 $last 이 이력에 없어 최근 머지 ${cap}건으로 자릅니다"
    else
      span="마지막 성공 전량이 없어${last_note:+ ($last_note)} 최근 머지 ${cap}건으로 자릅니다"
    fi
  fi

  local m n=0 omitted=0 cands=0 subj pr out kind what hit lines=""
  while read -r m; do
    [ -n "$m" ] || continue
    n=$((n + 1))
    subj=$(git log -1 --format=%s "$m")
    pr=$(printf '%s' "$subj" | sed -n 's/^Merge pull request #\([0-9][0-9]*\).*/\1/p')
    if [ "$n" -gt "$cap" ]; then
      omitted=$((omitted + 1))
      lines="$lines- \`${m:0:12}\` PR ${pr:+#}${pr:-없음} — 후보 계산 생략"$'\n'
      continue
    fi
    rc=0
    out=$(bash "$sel_script" --base "$m^1" --head "$m" 2>/dev/null) || rc=$?
    kind=$(printf '%s\n' "$out" | head -n 1 | cut -f 1)
    if [ "$rc" != "0" ]; then
      what="후보 (선택기가 판정하지 못함 — 전량으로 읽음)"; cands=$((cands + 1))
    elif [ "$kind" = "전량" ]; then
      what="후보 (전량 판정 — $(printf '%s\n' "$out" | head -n 1 | cut -f 2-))"; cands=$((cands + 1))
    elif [ "$kind" = "절" ]; then
      hit=$(printf '%s\n' "$out" | head -n 1 | cut -f 2 | tr ',' '\n' | awk -v F="$failed" 'BEGIN { n = split(F, a, ","); for (i = 1; i <= n; i++) f[a[i]] = 1 } ($0 in f) { printf "%s%s", (k++ ? "," : ""), $0 }')
      if [ -n "$hit" ]; then
        what="후보 (실패 절 $hit 을 고름)"; cands=$((cands + 1))
      elif [ -z "$failed" ]; then
        what="판정 안 함 (실패 절을 모름)"
      else
        what="후보 아님"
      fi
    else
      what="후보 (선택기의 답을 읽지 못함 — 전량으로 읽음)"; cands=$((cands + 1))
    fi
    lines="$lines- \`${m:0:12}\` PR ${pr:+#}${pr:-없음} — $what"$'\n'
  done <<EOF
$merges
EOF

  {
    printf '정기 전량 실패\n\n'
    printf -- '- 실행: %s\n' "$url"
    printf -- '- 커밋: %s\n' "${sha:-알 수 없음}"
    printf -- '- 잡 결론: gate-plan %s · gate-shards %s · shard-coverage %s · gate-report %s\n' "$plan" "$shards" "$cov" "$rep"
    if [ -n "$rows" ]; then
      printf '%s\n' "$rows" | awk -F '\t' '{ print "- 실패한 행 " $1 " (" $3 "): " $2 }'
    else
      printf -- '- %s\n' "$rows_note"
    fi
    printf -- '- 마지막 성공 전량 커밋: %s\n' "${last:-없음}"
    printf '\n그 사이 first-parent 머지 %s건 (%s)\n\n' "$n" "$span"
    printf '%s' "$lines"
    [ "$cands" -gt 0 ] || printf -- '- 좁힌 선택 밖의 실패 — 후보 머지가 없습니다\n'
    [ "$omitted" -eq 0 ] || printf -- '- 후보 계산 생략 %s건 (상한 %s건)\n' "$omitted" "$cap"
    gap=$(full_gap_lines "$last_line" "$last_note" "$sha" "$url" "$runv")
    [ -z "$gap" ] || printf '\n%s\n' "$gap"
  } > "$body"
  [ "$cands" -gt 0 ] || printf 'gate-full: 좁힌 선택 밖의 실패 — 후보 머지가 없습니다\n' >&2
  [ "$omitted" -eq 0 ] || printf 'gate-full: 후보 계산 생략 %s건 (상한 %s건)\n' "$omitted" "$cap" >&2

  full_write_issue "$repo" "$label" "$open" "$body" "전량 실패"
  rc=$?; rm -f "$body"; return "$rc"
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

  # --- report: a repository with four first-parent merges, a gh stand-in that
  # logs every call and answers from files, and a selector stand-in.
  local self base head i
  self="$script_dir/$(basename "$0")"
  mkdir -p "$T/repo" "$T/plan" "$T/res"
  ( cd "$T/repo" \
    && git init -q -b master . \
    && git -c user.name=t -c user.email=t@t commit -q --allow-empty -m base \
    && for i in 1 2 3 4; do
         git checkout -q -b "b$i" \
         && git -c user.name=t -c user.email=t@t commit -q --allow-empty -m "c$i" \
         && git checkout -q master \
         && git -c user.name=t -c user.email=t@t merge -q --no-ff -m "Merge pull request #$((40 + i)) from o/b$i" "b$i" \
         || exit 1
       done ) > /dev/null 2>&1 || bad "(g) 시험 레포 만들기" "git 실패"
  base=$(cd "$T/repo" && git rev-list --max-parents=0 HEAD)
  head=$(cd "$T/repo" && git rev-parse HEAD)
  cat > "$T/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
case "$1" in
  api)   case "$2" in */jobs*) cat "$GH_JOBS" 2>/dev/null ;; esac ;;
  label) [ "$2" = "list" ] && cat "$GH_LABELS" 2>/dev/null ;;
  issue)
    case "$2" in
      list) cat "$GH_OPEN" 2>/dev/null ;;
      create|comment)
        while [ "$#" -gt 0 ]; do
          [ "$1" = "--body-file" ] && cat "$2" >> "$GH_BODY"
          shift
        done ;;
    esac ;;
esac
exit 0
EOF
  printf '#!/usr/bin/env bash\nprintf "절\\t%%s\\n" "${STUB_SEL:-x}"\n' > "$T/select.sh"
  printf '1\t10\tx\t\t\t\n2\t10\tz\t\t\t\n' > "$T/plan/table.tsv"
  printf '1\t1\ttest-gate: 3 passed, 1 failed\n' > "$T/res/result-1.tsv"
  printf '2\t0\ttest-gate: 2 passed, 0 failed\n' > "$T/res/result-2.tsv"
  printf '{"jobs":[{"name":"gate-shards (1)","conclusion":"success"}]}\n' > "$T/jobs.json"
  mk_runs "$T/ok.json" "50 schedule success $base 2026-01-01T00:00:00Z"
  : > "$T/labels"; : > "$T/open"
  # rep <ref> <event> <shards result> [extra args] — runs report in the repo.
  rep() {
    local r="$1" e="$2" s="$3"; shift 3
    : > "$T/gh.log"; : > "$T/body"
    ( cd "$T/repo" && GATE_FULL_GH="$T/gh" GH_LOG="$T/gh.log" GH_JOBS="$T/jobs.json" GH_LABELS="$T/labels" \
        GH_OPEN="$T/open" GH_BODY="$T/body" GATE_FULL_RUNS_JSON="$T/ok.json" GITHUB_REPOSITORY=o/r GITHUB_RUN_ID=99 \
        GITHUB_SHA="$head" GITHUB_REF="$r" GITHUB_EVENT_NAME="$e" GATE_FULL_NOW="${GATE_FULL_NOW:-1767398400}" \
        bash "$self" report --plan success --shards "$s" --coverage success --report success \
          --plan-dir "$T/plan" --results-dir "$T/res" --select "$T/select.sh" "$@" )
  }
  chmod +x "$T/gh"

  # (g) a workflow_dispatch on a branch writes nothing, failed or not.
  rep refs/heads/feature workflow_dispatch failure 2>"$T/err"; rc=$?
  if [ "$rc" = "0" ] && [ ! -s "$T/gh.log" ] && grep -q '^gate-full: 보고 안 함 — ref refs/heads/feature' "$T/err"; then
    ok "(g) master 가 아닌 ref 의 workflow_dispatch 는 이슈를 쓰지도 닫지도 않는다"
  else
    bad "(g) master 가 아닌 ref 의 workflow_dispatch 는 이슈를 쓰지도 닫지도 않는다" "rc=$rc $(cat "$T/gh.log") $(cat "$T/err")"
  fi
  rep refs/heads/master pull_request failure 2>"$T/err"; rc=$?
  if [ "$rc" = "0" ] && [ ! -s "$T/gh.log" ]; then
    ok "(g) pull request 실행은 이슈를 쓰지 않는다"
  else
    bad "(g) pull request 실행은 이슈를 쓰지 않는다" "rc=$rc $(cat "$T/gh.log")"
  fi

  # (h) four merges past the last whole success, a cap of 2: two computed, two
  # reported as omitted; the label is made and a new issue opened.
  rep refs/heads/master schedule failure --cap 2 2>"$T/err"; rc=$?
  if [ "$rc" = "0" ] && grep -q '^gate-full: 후보 계산 생략 2건 (상한 2건)$' "$T/err" \
     && grep -q '^- 후보 계산 생략 2건 (상한 2건)$' "$T/body" \
     && [ "$(grep -c '후보 (실패 절 x 을 고름)' "$T/body")" = "2" ] \
     && grep -q '^- 실패한 행 1 (종료 1): x$' "$T/body" \
     && grep -q "^- 마지막 성공 전량 커밋: $base$" "$T/body" \
     && grep -q '^label create gate-full-failure' "$T/gh.log" \
     && grep -q '^issue create ' "$T/gh.log"; then
    ok "(h) 상한을 넘는 구간은 최근 머지만 계산하고 생략 줄을 적는다"
  else
    bad "(h) 상한을 넘는 구간은 최근 머지만 계산하고 생략 줄을 적는다" "rc=$rc $(cat "$T/err") / $(cat "$T/body") / $(cat "$T/gh.log")"
  fi
  if grep -q 'PR #44 — 후보' "$T/body" && grep -q 'PR #41 — 후보 계산 생략' "$T/body"; then
    ok "(h) 최근 머지부터 계산하고 PR 번호를 적는다"
  else
    bad "(h) 최근 머지부터 계산하고 PR 번호를 적는다" "$(cat "$T/body")"
  fi

  # (i) no merge selects the failed section: outside the narrowed selection;
  # an open issue gets a comment, not a second issue.
  printf 'gate-full-failure\n' > "$T/labels"; printf '7\n' > "$T/open"
  STUB_SEL=y rep refs/heads/master schedule failure 2>"$T/err"; rc=$?
  if [ "$rc" = "0" ] && grep -q '^- 좁힌 선택 밖의 실패 — 후보 머지가 없습니다$' "$T/body" \
     && grep -q '^issue comment 7 ' "$T/gh.log" && ! grep -q '^issue create' "$T/gh.log" \
     && ! grep -q '^label create' "$T/gh.log"; then
    ok "(i) 후보가 없으면 좁힌 선택 밖의 실패로 적고 열린 이슈에 코멘트한다"
  else
    bad "(i) 후보가 없으면 좁힌 선택 밖의 실패로 적고 열린 이슈에 코멘트한다" "rc=$rc $(cat "$T/body") / $(cat "$T/gh.log")"
  fi

  # (j) a whole success closes the open issue after writing the run into it.
  rep refs/heads/master schedule success 2>"$T/err"; rc=$?
  if [ "$rc" = "0" ] && grep -q '^issue comment 7 ' "$T/gh.log" && grep -q '^issue close 7 ' "$T/gh.log" \
     && grep -q '^정기 전량 성공' "$T/body"; then
    ok "(j) 전량 성공은 열린 이슈에 성공 실행을 적고 닫는다"
  else
    bad "(j) 전량 성공은 열린 이슈에 성공 실행을 적고 닫는다" "rc=$rc $(cat "$T/gh.log")"
  fi

  # (k) with no successful whole run, the span is cut to the cap.
  mk_runs "$T/ok.json" "50 schedule failure $base 2026-01-01T00:00:00Z"
  : > "$T/open"
  rep refs/heads/master schedule failure --cap 3 2>"$T/err"; rc=$?
  if [ "$rc" = "0" ] && grep -q '^그 사이 first-parent 머지 3건 (마지막 성공 전량이 없어 최근 머지 3건으로 자릅니다)$' "$T/body" \
     && grep -q '^- 마지막 성공 전량 커밋: 없음$' "$T/body" && ! grep -q '후보 계산 생략' "$T/body"; then
    ok "(k) 마지막 성공 전량이 없으면 구간을 상한으로 자른다"
  else
    bad "(k) 마지막 성공 전량이 없으면 구간을 상한으로 자른다" "rc=$rc $(cat "$T/body")"
  fi

  # --- the gap: the clock stands two days after the success at 2026-01-01.
  # (l) a skipped round whose last whole success is old, with four merges
  # after it: the gap goes into the open issue, which stays open.
  mk_runs "$T/ok.json" "50 schedule success $base 2026-01-01T00:00:00Z"
  printf '7\n' > "$T/open"
  rep refs/heads/master schedule skipped --run 0 2>"$T/err"; rc=$?
  if [ "$rc" = "0" ] && grep -q '^공백 보고 — 마지막 전량 성공이 12시간보다 오래되었고' "$T/body" \
     && grep -q '^- 마지막 전량 성공 실행: https://github.com/o/r/actions/runs/50$' "$T/body" \
     && grep -q "^- 커밋: $base · 시각: 2026-01-01T00:00:00Z (48시간 전)$" "$T/body" \
     && grep -q '^- 그 뒤 first-parent 머지: 4건$' "$T/body" \
     && grep -q '^- 이번 회차: https://github.com/o/r/actions/runs/99 · run=0$' "$T/body" \
     && grep -q '^issue comment 7 ' "$T/gh.log"; then
    ok "(l) 오래된 마지막 전량 성공 뒤 머지가 있으면 건너뛴 회차가 공백을 적는다"
  else
    bad "(l) 오래된 마지막 전량 성공 뒤 머지가 있으면 건너뛴 회차가 공백을 적는다" "rc=$rc $(cat "$T/body") / $(cat "$T/gh.log")"
  fi
  if ! grep -q '^issue close' "$T/gh.log" && ! grep -qE '정기 전량 (실패|성공)' "$T/body"; then
    ok "(l) 건너뛴 회차는 공백만 적고 이슈를 닫지 않는다"
  else
    bad "(l) 건너뛴 회차는 공백만 적고 이슈를 닫지 않는다" "$(cat "$T/gh.log") / $(cat "$T/body")"
  fi

  # (m) the same old success, but this round is a whole success: no gap, the
  # issue is closed.
  rep refs/heads/master schedule success --run 1 2>"$T/err"; rc=$?
  if [ "$rc" = "0" ] && ! grep -q '공백 보고' "$T/body" && grep -q '^issue close 7 ' "$T/gh.log"; then
    ok "(m) 이번 회차가 전량 성공이면 공백이 아니다"
  else
    bad "(m) 이번 회차가 전량 성공이면 공백이 아니다" "rc=$rc $(cat "$T/body") / $(cat "$T/gh.log")"
  fi

  # (n) no whole success to be found: written as a gap, a new issue opened.
  mk_runs "$T/ok.json" "50 schedule failure $base 2026-01-01T00:00:00Z"
  : > "$T/open"
  rep refs/heads/master schedule skipped --run 0 2>"$T/err"; rc=$?
  if [ "$rc" = "0" ] && grep -q '^공백 보고 — 마지막 전량 성공을 찾지 못했습니다$' "$T/body" \
     && grep -q '^issue create ' "$T/gh.log" && ! grep -q '^issue close' "$T/gh.log"; then
    ok "(n) 마지막 전량 성공을 찾지 못하면 공백으로 적는다"
  else
    bad "(n) 마지막 전량 성공을 찾지 못하면 공백으로 적는다" "rc=$rc $(cat "$T/body") / $(cat "$T/gh.log")"
  fi

  # (o) a success an hour old is no gap: a skipped round writes nothing.
  mk_runs "$T/ok.json" "50 schedule success $base 2026-01-01T00:00:00Z"
  printf '7\n' > "$T/open"
  GATE_FULL_NOW=1767229200 rep refs/heads/master schedule skipped --run 0 2>"$T/err"; rc=$?
  if [ "$rc" = "0" ] && [ ! -s "$T/body" ] && ! grep -qE '^issue (comment|create|close)' "$T/gh.log" \
     && grep -q '^gate-full: 건너뛴 회차 — 공백 아님' "$T/err"; then
    ok "(o) 12시간 안의 전량 성공이면 건너뛴 회차는 아무것도 쓰지 않는다"
  else
    bad "(o) 12시간 안의 전량 성공이면 건너뛴 회차는 아무것도 쓰지 않는다" "rc=$rc $(cat "$T/body") / $(cat "$T/gh.log") / $(cat "$T/err")"
  fi

  # (p) a failed whole round past an old success carries the gap under the
  # failure.
  rep refs/heads/master schedule failure --run 1 2>"$T/err"; rc=$?
  if [ "$rc" = "0" ] && grep -q '^정기 전량 실패$' "$T/body" && grep -q '^공백 보고 — 마지막 전량 성공이 12시간보다' "$T/body"; then
    ok "(p) 실패한 전량 회차도 공백을 함께 적는다"
  else
    bad "(p) 실패한 전량 회차도 공백을 함께 적는다" "rc=$rc $(cat "$T/body")"
  fi

  rm -rf "$T"
  printf 'gate-full self-test: %d passed, %d failed\n' "$passed" "$failed"
  # A floor on the count, so a refactor that silently skips cases cannot pass.
  if [ "$passed" -lt 20 ]; then
    printf 'gate-full self-test: 통과 수 %d 가 하한 20 에 못 미칩니다\n' "$passed" >&2
    return 1
  fi
  [ "$failed" = "0" ]
}

# --- main --------------------------------------------------------------------

[ "$#" -ge 1 ] || full_usage
cmd="$1"; shift
case "$cmd" in
  due)         full_due "$@"; exit $? ;;
  report)      full_report "$@"; exit $? ;;
  --self-test) full_self_test; exit $? ;;
  *) printf 'gate-full: 모르는 하위명령입니다: %s\n' "$cmd" >&2; full_usage ;;
esac
