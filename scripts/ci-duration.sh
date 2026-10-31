#!/usr/bin/env bash
# The duration signal of the three test workflows — gate, lint's rest-tests and
# notify-macos. Each one measures its own test step and calls `check` with the
# seconds it took.
#
# A PULL REQUEST FAILS ONLY FOR WHAT IT ADDED. Y is the measurement S less
# whatever the same pull request raised that key's budget by in
# `scripts/ci-duration-budget.tsv`. Y at or under the common upper bound
# C1 = max(B + T, W + tol_s) passes, for every key (B the window median, W its
# largest value, T the tolerance below). Past C1, lint-rest-tests and
# notify-macos fail; gate first separates the runner from the change (below)
# and fails only past the bound that separation gives, warning when the
# separation explains the excess or cannot be made. A failure says the bound it
# crossed and how far the budget would have to go up for the pull request to
# pass. Raising it is the approval, and the reviewer sees it as a one-line diff
# saying how many seconds this change costs CI. Growth that comes in steps too
# small to cross the bound is the absolute check's: any run whose measurement
# exceeds the budget plus the tolerance gets a warning annotation and a summary
# row, never a failure, so a master already over budget does not block an
# unrelated change.
#
# THE LIMITING FACTORS ARE NAMED, AND THE ONES THAT ARE NOT THE CHANGE'S ARE
# TAKEN OUT. The master level moves: the window follows it, and its largest
# value is in C1 because the median stays at the old level for three pushes
# after a step. The runner moves: on gate the sections this pull request did
# not change are a control group inside the same run — F is their summed time
# in this run over the same sections' summed master median, and the baseline
# becomes B' = ceil(B × max(1, F)), the bound C2 = B' + T. Changed and new
# sections stay out of F, so what they added is never covered by the factor it
# would itself raise. Runner queueing is not in any sum (`wall` measures it
# separately) and isolation time is not in gate's. The shard and lane counts
# are the change's: every row carries a head time, so a pull request that
# changes GATE_SHARDS or GATE_LANES owns the growth it causes.
#
# THE COMPARISON IS WITH THIS REPOSITORY'S MASTER, ON THE SAME WORKFLOW AND
# RUNNER LABEL. A push to master writes the window it was compared against,
# plus its own measurement, trimmed to five, as a file for the workflow to
# upload as `ci-duration-<key>`. `fetch-base` finds the newest master push run
# of the key's workflow — this repository's own, `event=push`,
# `branch=master` — that still has the artifact, the rule the gate plan job
# uses for its timing source. A fork's pull request can upload an artifact of
# the same name and never becomes a source, because only push runs are read.
# The per-section master times are the plan job's median of the last three
# master runs, and count only when that is where they came from (`source`
# starting with `artifact`): the seed and the census are not measurements.
#
# EACH KEY MEASURES ONE THING. gate: the sum of the row times, each row from
# its @start to its @end, without the isolation intervals and without runner
# queueing. lint-rest-tests: the sum of the rest shards' test times, without
# queueing. notify-macos: the elapsed time of the macOS test step, without
# queueing. None of them is a wall clock, and no job of another repository is
# measured.
#
# THE ERROR IS THE SPREAD MASTER ITSELF SHOWED. Five master measurements give
# the median B and the largest W; T = max(tol_s, ceil(B × tol_pct / 100)), and
# a measurement inside what master already produced, W + tol_s, cannot be told
# apart from master without another run. On gate the factor is floored at 1,
# so a fast runner never lowers the bar under an unrelated change, and it is
# trusted only when the unchanged sections cover at least half of the master
# sections' summed time. NOTHING MISSING FAILS A JOB: no baseline, no base
# budget, no budget row skips the increment check with a warning saying which
# one was missing, and the absolute check still runs where the budget row
# exists; a gate separation without its inputs warns with the reason.
#
# EVERY NUMBER CAN BE RECOMPUTED. Each increment message states what the key
# measures and its inputs — the master run the window came from, the window's
# values, and on gate the factor, the number of unchanged sections and their
# two sums — so anyone can redo the arithmetic, and `--self-test` replays
# observed runs.
#
# THE SIGNAL EXISTS SO CI COST IS APPROVED, NOT DRIFTED INTO. A pull request
# that makes CI slower and makes everyone wait longer shows it in the pull
# request, and passes only by raising the budget where a reviewer sees it.
#
# THIS IS WHAT HAPPENED. On 2026-10-28 master and pull request runs alike got
# about 1.2 times slower across the sections — a runner environment step, not
# a code change — and until the five-measurement window caught up, six pull
# requests unrelated to it failed this check (#1528).
#
# Usage:
#   bash scripts/ci-duration.sh check --key K --seconds S [--base-sha SHA]
#                                     [--window-out DIR] [--root DIR]
#                                     [--plan-dir D] [--sections F]
#       --plan-dir is the directory the gate-plan artifact was downloaded to
#       (gate-timing.tsv, changed, source) and --sections this run's merged
#       section times; gate only, any other key exits 2
#   bash scripts/ci-duration.sh fetch-base (--key K | --name N --workflow W) --out DIR
#                                          [--count K]
#       prints `<run id> <created_at>` of the run it downloaded from; exit 1
#       when no master push run has the artifact. With --count K it takes up
#       to K such runs, newest first, each into DIR/<run id>/ so artifacts of
#       one name do not overwrite each other, and prints one line per run;
#       exit 0 when it got at least one
#   bash scripts/ci-duration.sh wall --slots S --runners N --lanes L
#                                    --timing-dir D [--result-dir R] [--out F]
#       the wall clock of this run attempt, as one `gate-wall:` line on stdout
#       and in F (see dur_wall)
#   bash scripts/ci-duration.sh --self-test
#
# The event comes from GITHUB_EVENT_NAME and GITHUB_REF; the pull request's base
# sha from --base-sha, or else from GITHUB_EVENT_PATH. The repository is
# GITHUB_REPOSITORY; this run's id, which the merged section times carry, from
# GITHUB_RUN_ID. Exit codes: 0 pass (warnings included), 1 the increment is
# over the bound — C1, or on gate the larger of C1 and C2 — 2 usage.

set -uo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)

dur_usage() {
  printf 'ci-duration: 사용법 — check --key K --seconds S [--base-sha SHA] [--window-out DIR] [--root DIR] [--plan-dir D] [--sections F] / fetch-base (--key K | --name N --workflow W) --out DIR [--count K] / wall --slots S --runners N --lanes L --timing-dir D [--result-dir R] [--out F] / --self-test\n' >&2
  exit 2
}

dur_workflow_of() {
  case "$1" in
    gate)            printf 'gate.yml' ;;
    lint-rest-tests) printf 'lint.yml' ;;
    notify-macos)    printf 'notify-macos.yml' ;;
    *) return 1 ;;
  esac
}

# The keys whose measurement is a sum of per-section times, and so the keys
# `check` separates the runner from the change for. Only these take
# --plan-dir and --sections.
dur_separates() {
  case "$1" in
    gate) return 0 ;;
    *) return 1 ;;
  esac
}

# What the key's seconds cover, as the messages state it.
dur_scope_of() {
  case "$1" in
    gate)            printf '행 시간의 합 — 행마다 @start~@end, 격리 구간과 러너 대기 제외' ;;
    lint-rest-tests) printf 'rest 샤드들의 시험 시간 합 — 러너 대기 제외' ;;
    notify-macos)    printf 'macOS 시험 단계의 경과 시간 — 러너 대기 제외' ;;
    *)               printf '미상' ;;
  esac
}

# Prints `<budget_s> <tol_s> <tol_pct>` of the key's row, nothing when absent.
dur_budget_row() {
  awk -F '\t' -v k="$1" '!/^#/ && $1 == k && $2 ~ /^[0-9]+$/ { print $2, $3, $4; exit }'
}

dur_fetch_base() {
  local key="" name="" wf="" out="" count="" got=0 repo ids id created n
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --key)      [ "$#" -ge 2 ] || dur_usage; key="$2"; shift 2 ;;
      --name)     [ "$#" -ge 2 ] || dur_usage; name="$2"; shift 2 ;;
      --workflow) [ "$#" -ge 2 ] || dur_usage; wf="$2"; shift 2 ;;
      --out)      [ "$#" -ge 2 ] || dur_usage; out="$2"; shift 2 ;;
      --count)    [ "$#" -ge 2 ] || dur_usage; count="$2"; shift 2 ;;
      *) printf 'ci-duration: 모르는 인자입니다: %s\n' "$1" >&2; dur_usage ;;
    esac
  done
  if [ -n "$count" ]; then
    case "$count" in *[!0-9]*) dur_usage ;; esac
    [ "$count" -ge 1 ] || dur_usage
  fi
  if [ -n "$key" ]; then
    [ -n "$name" ] || name="ci-duration-$key"
    [ -n "$wf" ] || wf=$(dur_workflow_of "$key") || { printf 'ci-duration: 모르는 키입니다: %s\n' "$key" >&2; return 2; }
  fi
  [ -n "$name" ] && [ -n "$wf" ] && [ -n "$out" ] || dur_usage
  repo="${GITHUB_REPOSITORY:-}"
  if [ -z "$repo" ]; then printf 'ci-duration: GITHUB_REPOSITORY 가 없어 기준 실행을 찾지 않습니다\n' >&2; return 1; fi
  ids=$(gh api "repos/$repo/actions/workflows/$wf/runs?branch=master&event=push&per_page=20" \
    --jq ".workflow_runs[] | select(.head_repository.full_name == \"$repo\") | \"\\(.id) \\(.created_at)\"" 2>/dev/null) || ids=""
  while read -r id created; do
    [ -n "$id" ] || continue
    n=$(gh api "repos/$repo/actions/runs/$id/artifacts?name=$name" \
      --jq '[.artifacts[] | select(.expired == false)] | length' 2>/dev/null) || n=0
    [ "${n:-0}" -ge 1 ] 2>/dev/null || continue
    if [ -z "$count" ]; then
      mkdir -p "$out"
      if gh run download "$id" -R "$repo" -n "$name" -D "$out" >/dev/null 2>&1; then
        printf '%s %s\n' "$id" "$created"
        return 0
      fi
      continue
    fi
    mkdir -p "$out/$id"
    if gh run download "$id" -R "$repo" -n "$name" -D "$out/$id" >/dev/null 2>&1; then
      printf '%s %s\n' "$id" "$created"
      got=$((got + 1))
      [ "$got" -lt "$count" ] || return 0
    fi
  done <<EOF
$ids
EOF
  [ "$got" -ge 1 ] && return 0
  return 1
}

# THE WALL CLOCK OF ONE RUN ATTEMPT, AND WHAT IT WAS MADE OF. Three numbers in
# seconds, all measured at the moment this runs inside the report job:
#   raw     now minus the attempt's `run_started_at` — what a pull request waits
#   path    the plan job's duration, plus the longest `gate-shards` job, plus
#           the time since the report job started — the critical path with no
#           queueing in it
#   queued  raw minus path
# `overlap` counts the runs of this repository with a different head sha that
# were alive in the assignment window [attempt start, start of the last
# `gate-shards` job, or now when none started]: created before the window ends,
# and not finished or finished after it began. The run list describes a run by
# its latest attempt: `run_started_at`, `status` and `updated_at` are that
# attempt's. So a neighbour whose latest attempt began after the window is
# judged by its earlier attempts, read one by one from the attempt endpoint —
# counted when one of them began before the window ended (the first from the
# run's `created_at`, so a run queued in the window counts) and had not finished
# or finished after the window began. A neighbour that ran in the window and was
# rerun before this report counts; one that had finished before the window and
# was rerun after it does not. A failed read of such an earlier attempt writes
# overlap `-` with a notice. This run itself (by id) and the runs of its own head
# sha (lint, notify) are not counted — the head sha is the attempt's, which on a
# pull request is the head and not the merge commit in GITHUB_SHA — and neither
# is a run created after the window, which could not have made this one wait.
# Jobs of other repositories on the same account are not visible through this
# API, and the line says so. An attempt that reran only the failed jobs lists
# the jobs it carried over with their earlier start times; its raw would cover
# the rerun shards alone, so raw, path, queued and overlap are written `-` with
# a notice, and the line is never read as the wall of the whole gate. `rows` is
# the number of distinct row ids whose `result-<K>.tsv` in the result directory
# carries a suite total line (`test-gate: <n> passed, <n> failed`) or, for an
# extra row that runs isolation work only, `격리 전용 행`, over S. The
# rule follows the artifact, not the lane count: when the result directory holds
# no result file at all — a run from before the lanes carried one — it is the
# number of row timing files in D that reached their `@end` line instead. A row
# that died uploads a partial file in either form, and the count is never filled
# in from the runner and lane numbers it was given. Nothing here fails the job: past
# 900 s raw it warns, and a value an API did not give is written `-` with a
# notice.
dur_wall() {
  local slots="" runners="" lanes="" tdir="" rdir="" out=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --slots)      [ "$#" -ge 2 ] || dur_usage; slots="$2"; shift 2 ;;
      --runners)    [ "$#" -ge 2 ] || dur_usage; runners="$2"; shift 2 ;;
      --lanes)      [ "$#" -ge 2 ] || dur_usage; lanes="$2"; shift 2 ;;
      --timing-dir) [ "$#" -ge 2 ] || dur_usage; tdir="$2"; shift 2 ;;
      --result-dir) [ "$#" -ge 2 ] || dur_usage; rdir="$2"; shift 2 ;;
      --out)        [ "$#" -ge 2 ] || dur_usage; out="$2"; shift 2 ;;
      *) printf 'ci-duration: 모르는 인자입니다: %s\n' "$1" >&2; dur_usage ;;
    esac
  done
  local v
  for v in "$slots" "$runners" "$lanes"; do
    case "$v" in ''|*[!0-9]*) dur_usage ;; esac
  done
  [ "$slots" -ge 1 ] && [ -n "$tdir" ] || dur_usage
  local repo="${GITHUB_REPOSITORY:-}" rid="${GITHUB_RUN_ID:-}" att="${GITHUB_RUN_ATTEMPT:-}"
  local now="${CI_DURATION_NOW:-$(date +%s)}"
  local start="" sha="" jobs="" jobs_ok=0 raw="-" path="-" queued="-" overlap="-" notes=""
  local pd sm rs ls carried wend f executed=0 cands cid catt ccr k alive why
  case "$rid" in *[!0-9]*) rid="" ;; esac
  if [ -z "$repo" ] || [ -z "$rid" ] || [ -z "$att" ]; then
    notes="GITHUB_REPOSITORY·GITHUB_RUN_ID·GITHUB_RUN_ATTEMPT 가운데 빈 값이 있어 API 를 읽지 않았습니다"
  else
    # The run's own head sha comes from the attempt, not from GITHUB_SHA: on a
    # pull request GITHUB_SHA is the merge commit, while every run of that push
    # (this one, its lint and notify runs) carries the pull request head.
    read -r start sha <<EOF
$(gh api "repos/$repo/actions/runs/$rid/attempts/$att" --jq '[(.run_started_at | fromdate), (.head_sha // "")] | @tsv' 2>/dev/null)
EOF
    case "$start" in ''|*[!0-9]*) start=""; notes="시도 API 를 읽지 못했습니다" ;; esac
    case "$sha" in ''|*[!0-9A-Za-z]*) sha="" ;; esac
    if jobs=$(gh api "repos/$repo/actions/runs/$rid/attempts/$att/jobs?per_page=100" \
        --jq '.jobs[] | [.name, (if .started_at then (.started_at | fromdate) else "-" end), (if .completed_at then (.completed_at | fromdate) else "-" end)] | @tsv' 2>/dev/null); then
      jobs_ok=1
    else
      notes="${notes:+$notes · }jobs API 를 읽지 못했습니다"
    fi
  fi
  [ -z "$start" ] || raw=$(( now - start ))
  if [ "$jobs_ok" = "1" ]; then
    read -r pd sm rs ls carried <<EOF
$(printf '%s\n' "$jobs" | awk -F '\t' -v st="$start" '
  st != "" && $2 != "-" && $2 < st { carried = 1 }
  $1 == "gate-plan" && $2 != "-" && $3 != "-" { pd = $3 - $2 }
  $1 ~ /^gate-shards/ && $2 != "-" { if (ls == "" || $2 > ls) ls = $2; if ($3 != "-" && (sm == "" || $3 - $2 > sm)) sm = $3 - $2 }
  $1 == "gate-report" && $2 != "-" { rs = $2 }
  END { print (pd == "" ? "-" : pd), (sm == "" ? "-" : sm), (rs == "" ? "-" : rs), (ls == "" ? "-" : ls), (carried ? 1 : 0) }')
EOF
    if [ "$pd" != "-" ] && [ "$sm" != "-" ] && [ "$rs" != "-" ]; then path=$(( pd + sm + now - rs )); fi
    if [ "$carried" = "1" ]; then
      raw="-"; path="-"
      notes="${notes:+$notes · }실패한 잡만 다시 돌린 시도라(앞 시도에서 넘어온 잡이 있음) raw·path·queued·overlap 을 적지 않았습니다"
    elif [ -n "$start" ] && [ -z "$sha" ]; then
      notes="${notes:+$notes · }시도 API 가 head_sha 를 주지 않아 overlap 을 세지 않았습니다"
    elif [ -n "$start" ]; then
      wend="$now"; [ "$ls" = "-" ] || wend="$ls"
      # One line per candidate: `live` when the listed (latest) attempt decides
      # it, `<id> <attempts> <created>` when that attempt began after the window
      # and only the earlier attempts can say whether the run was alive in it.
      if cands=$(gh api "repos/$repo/actions/runs?per_page=100" \
          --jq ".workflow_runs[] | select(.id != $rid) | select(.head_sha != \"$sha\") | select((.created_at | fromdate) < $wend) | if ((.run_attempt // 1) > 1 and (((.run_started_at // .created_at) | fromdate) >= $wend)) then \"\\(.id) \\(.run_attempt) \\(.created_at | fromdate)\" elif (.status != \"completed\" or ((.updated_at | fromdate) > $start)) then \"live\" else empty end" 2>/dev/null); then
        overlap=0; why="다시 돈 실행의 앞 시도 API 를 읽지 못했습니다"
        while read -r cid catt ccr; do
          [ -n "$cid" ] || continue
          if [ "$cid" = "live" ]; then overlap=$((overlap + 1)); continue; fi
          case "$cid$catt$ccr" in *[!0-9]*) overlap=""; why="실행 목록 API 가 숫자가 아닌 실행 id·시도 번호·생성 시각을 주었습니다"; break ;; esac
          k=1; alive=0
          while [ "$k" -lt "$catt" ]; do
            alive=$(gh api "repos/$repo/actions/runs/$cid/attempts/$k" \
              --jq "if ((if $k == 1 then $ccr else (.run_started_at | fromdate) end) < $wend) and (.status != \"completed\" or ((.updated_at | fromdate) > $start)) then 1 else 0 end" 2>/dev/null) || alive=""
            [ "$alive" = "0" ] || break
            k=$((k + 1))
          done
          case "$alive" in
            1) overlap=$((overlap + 1)) ;;
            0) ;;
            *) overlap=""; break ;;
          esac
        done <<EOF
$cands
EOF
        case "$overlap" in ''|*[!0-9]*) overlap="-"; notes="${notes:+$notes · }$why" ;; esac
      else
        overlap="-"; notes="${notes:+$notes · }실행 목록 API 를 읽지 못했습니다"
      fi
    fi
  fi
  if [ "$raw" != "-" ] && [ "$path" != "-" ]; then queued=$(( raw - path )); fi
  local results=()
  if [ -n "$rdir" ]; then
    for f in "$rdir"/result-*.tsv; do [ -f "$f" ] && results+=("$f"); done
  fi
  if [ "${#results[@]}" -ge 1 ]; then
    executed=$(awk -F '\t' '($3 ~ /^test-gate: [0-9]+ passed, [0-9]+ failed$/ || $3 == "격리 전용 행") && !($1 in seen) { seen[$1] = 1; n++ } END { print n + 0 }' "${results[@]}")
  else
    for f in "$tdir"/timing-*.tsv; do
      [ -f "$f" ] || continue
      grep -q '^@end	' "$f" && executed=$((executed + 1))
    done
  fi
  local line
  line="gate-wall: raw=$raw path=$path queued=$queued overlap=$overlap rows=$executed/$slots attempt=${att:--} slots=$slots runners=$runners lanes=$lanes (overlap 은 이 저장소의 실행만 셉니다 — 다른 저장소의 잡은 이 API 로 보이지 않습니다)"
  printf '%s\n' "$line"
  if [ -n "$out" ]; then
    mkdir -p "$(dirname "$out")"
    printf '%s\n' "$line" > "$out"
  fi
  [ -z "$notes" ] || printf '::notice::ci-duration wall: %s — 적지 않은 값은 - 로 적었습니다\n' "$notes"
  if [ "$raw" != "-" ] && [ "$raw" -gt 900 ]; then
    printf '::warning::gate 벽시계 raw %s초가 900초를 넘습니다 (path %s초, queued %s초, overlap %s)\n' "$raw" "$path" "$queued" "$overlap"
  fi
  return 0
}

# The median of the last five numbers of a window file, nothing when empty.
dur_window_median() {
  awk '!/^#/ && $1 ~ /^[0-9]+$/ { v[++n] = $1 } END {
    if (n == 0) exit 0
    s = (n > 5) ? n - 4 : 1; m = 0
    for (i = s; i <= n; i++) { x = v[i]; j = m; while (j >= 1 && w[j] > x) { w[j + 1] = w[j]; j-- } w[j + 1] = x; m++ }
    print (m % 2) ? w[(m + 1) / 2] : int((w[m / 2] + w[m / 2 + 1]) / 2 + 0.5)
  }' "$1"
}

# The largest of the last five numbers of a window file, nothing when empty.
dur_window_max() {
  awk '!/^#/ && $1 ~ /^[0-9]+$/ { v[++n] = $1 } END {
    if (n == 0) exit 0
    s = (n > 5) ? n - 4 : 1; m = v[s]
    for (i = s + 1; i <= n; i++) if (v[i] > m) m = v[i]
    print m
  }' "$1"
}

# The last five numbers of a window file on one line, space-separated.
dur_window_values() {
  awk '!/^#/ && $1 ~ /^[0-9]+$/ { print $1 }' "$1" | tail -n 5 | tr '\n' ' ' | sed 's/ $//'
}

# The separation of the gate measurement. Prints one line:
#   ok <unchanged count> <master ms> <this run ms>
#   no <reason>
# The unchanged sections are the ids not starting with `@` that this run
# measured (the `run` column of the merged file equals the run id), that the
# master median has, and that `D/changed` does not list. Both files skip `#`
# lines, the `id` header and rows whose ms is not an integer.
dur_separation() {
  local pdir="$1" sfile="$2" rid="$3" f src changed res
  if [ -z "$pdir" ] || [ -z "$sfile" ]; then
    printf 'no --plan-dir 와 --sections 가 함께 주어지지 않았습니다\n'; return 0
  fi
  for f in "$pdir/gate-timing.tsv" "$pdir/changed" "$pdir/source" "$sfile"; do
    if [ ! -f "$f" ]; then printf 'no %s 가 없습니다\n' "$f"; return 0; fi
  done
  src=$(head -n 1 "$pdir/source")
  case "$src" in
    artifact*) ;;
    *) printf 'no 타이밍 출처가 master 실측이 아닙니다(%s)\n' "${src:-빈 값}"; return 0 ;;
  esac
  if [ -z "$rid" ]; then printf 'no GITHUB_RUN_ID 가 비어 이 실행의 실측을 가를 수 없습니다\n'; return 0; fi
  changed=$(tr -d '\n' < "$pdir/changed")
  res=$(awk -F '\t' -v MF="$pdir/gate-timing.tsv" -v RUN="$rid" -v CH="$changed" '
    BEGIN { n = split(CH, c, ","); for (i = 1; i <= n; i++) if (c[i] != "") ch[c[i]] = 1 }
    /^#/ || $1 == "id" || $1 ~ /^@/ || $2 !~ /^[0-9]+$/ { next }
    FILENAME == MF { m[$1] = $2; tot += $2; next }
    $3 == RUN && ($1 in m) && !($1 in ch) && !($1 in seen) { seen[$1] = 1; um += m[$1]; ub += $2; nu++ }
    END { printf "%d %.0f %.0f %.0f\n", nu, um, ub, tot }' "$pdir/gate-timing.tsv" "$sfile")
  local nu um ub tot
  read -r nu um ub tot <<EOF
$res
EOF
  if [ "${um:-0}" = "0" ]; then printf 'no 바뀌지 않은 절 가운데 이 실행이 잰 것이 없습니다\n'; return 0; fi
  if [ $(( 2 * um )) -lt "$tot" ]; then
    printf 'no 바뀌지 않은 절의 master 합 %s초가 master 전체 절 합 %s초의 절반에 못 미쳐 배율을 믿을 수 없습니다\n' \
      "$(( (um + 500) / 1000 ))" "$(( (tot + 500) / 1000 ))"
    return 0
  fi
  printf 'ok %s %s %s\n' "$nu" "$um" "$ub"
}

dur_check() {
  local key="" secs="" base_sha="" wout="" root pdir="" sfile="" pdir_set=0
  root=$(cd "$script_dir/.." && pwd)
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --key)        [ "$#" -ge 2 ] || dur_usage; key="$2"; shift 2 ;;
      --seconds)    [ "$#" -ge 2 ] || dur_usage; secs="$2"; shift 2 ;;
      --base-sha)   [ "$#" -ge 2 ] || dur_usage; base_sha="$2"; shift 2 ;;
      --window-out) [ "$#" -ge 2 ] || dur_usage; wout="$2"; shift 2 ;;
      --root)       [ "$#" -ge 2 ] || dur_usage; root="$2"; shift 2 ;;
      --plan-dir)   [ "$#" -ge 2 ] || dur_usage; pdir="$2"; pdir_set=1; shift 2 ;;
      --sections)   [ "$#" -ge 2 ] || dur_usage; sfile="$2"; pdir_set=1; shift 2 ;;
      *) printf 'ci-duration: 모르는 인자입니다: %s\n' "$1" >&2; dur_usage ;;
    esac
  done
  [ -n "$key" ] || dur_usage
  if [ "$pdir_set" = "1" ] && ! dur_separates "$key"; then
    printf 'ci-duration: --plan-dir·--sections 는 절 시간의 합을 재는 키(gate)에만 줍니다: %s\n' "$key" >&2
    dur_usage
  fi
  case "$secs" in ''|*[!0-9]*) printf 'ci-duration: --seconds 는 0 이상의 정수 초입니다: %s\n' "$secs" >&2; dur_usage ;; esac
  local event="${GITHUB_EVENT_NAME:-}" ref="${GITHUB_REF:-}" pr=0 push=0
  [ "$event" = "pull_request" ] && pr=1
  [ "$event" = "push" ] && [ "$ref" = "refs/heads/master" ] && push=1
  if [ "$pr" = "1" ] && [ -z "$base_sha" ] && [ -n "${GITHUB_EVENT_PATH:-}" ] && [ -f "${GITHUB_EVENT_PATH}" ]; then
    base_sha=$(jq -r '.pull_request.base.sha // empty' "$GITHUB_EVENT_PATH" 2>/dev/null) || base_sha=""
  fi

  local tmp row budget tol_s tol_pct base="" base_budget="" tol="" verdict="통과" rc=0 notes="" cap="" factor=""
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/ci-duration.XXXXXX")
  row=$(dur_budget_row "$key" < "$root/scripts/ci-duration-budget.tsv" 2>/dev/null) || row=""
  read -r budget tol_s tol_pct <<EOF
$row
EOF
  if dur_fetch_base --key "$key" --out "$tmp/base" > "$tmp/base.run" 2>/dev/null; then
    local wf
    wf=$(find "$tmp/base" -type f -name "ci-duration-$key.tsv" | head -n 1)
    [ -n "$wf" ] && base=$(dur_window_median "$wf") && [ -n "$base" ] && cp "$wf" "$tmp/window"
  fi
  [ -f "$tmp/window" ] || : > "$tmp/window"

  if [ -z "$budget" ]; then
    notes="예산 행 없음"
    printf '::warning::ci-duration: %s 의 예산 행이 scripts/ci-duration-budget.tsv 에 없어 판정하지 않습니다\n' "$key"
  else
    if [ -n "$base" ]; then
      tol=$(awk -v t="$tol_s" -v p="$tol_pct" -v b="$base" 'BEGIN { x = b * p / 100; x = (x == int(x)) ? x : int(x) + 1; print (t > x) ? t : x }')
    else
      tol="$tol_s"
    fi
    if [ "$pr" = "1" ]; then
      if [ -z "$base" ]; then
        notes="기준값 없음"
        printf '::warning::ci-duration: %s 의 master 기준값(ci-duration-%s 아티팩트)을 얻지 못해 증분 판정을 건너뜁니다\n' "$key" "$key"
      else
        if [ -n "$base_sha" ]; then
          ( cd "$root" && git cat-file -e "$base_sha^{commit}" 2>/dev/null ) \
            || ( cd "$root" && git fetch --no-tags --quiet --depth=1 origin "$base_sha" ) >/dev/null 2>&1 || true
          base_budget=$( cd "$root" && git show "$base_sha:scripts/ci-duration-budget.tsv" 2>/dev/null | dur_budget_row "$key" | awk '{ print $1 }' ) || base_budget=""
        fi
        if [ -z "$base_budget" ]; then
          notes="베이스 예산 없음"
          printf '::warning::ci-duration: %s 의 베이스 예산(베이스 %s 의 scripts/ci-duration-budget.tsv)을 읽지 못해 증분 판정을 건너뜁니다\n' "$key" "${base_sha:-미상}"
        else
          local raise y wmax c1 why need sep nu um ub bp c2 scope repro
          raise=$(( budget - base_budget )); [ "$raise" -gt 0 ] || raise=0
          y=$(( secs - raise ))
          wmax=$(dur_window_max "$tmp/window"); [ -n "$wmax" ] || wmax="$base"
          c1=$(( base + tol )); [ $(( wmax + tol_s )) -le "$c1" ] || c1=$(( wmax + tol_s ))
          cap="$c1"
          why="공통 상한 ${c1}초 = max(기준 ${base} + 오차 ${tol}, 창 최댓값 ${wmax} + tol_s ${tol_s})"
          scope=$(dur_scope_of "$key")
          repro="기준 창 master 실행 $(awk '{ print $1; exit }' "$tmp/base.run") 의 $(dur_window_values "$tmp/window")"
          if [ "$y" -gt "$c1" ] && dur_separates "$key"; then
            sep=$(dur_separation "$pdir" "$sfile" "${GITHUB_RUN_ID:-}")
            if [ "${sep%% *}" = "ok" ]; then
              read -r _ nu um ub <<EOF
$sep
EOF
              factor=$(awk -v a="$ub" -v b="$um" 'BEGIN { printf "%.3f", a / b }')
              if [ "$ub" -gt "$um" ]; then bp=$(( (base * ub + um - 1) / um )); else bp="$base"; fi
              c2=$(( bp + tol ))
              [ "$c2" -le "$cap" ] || cap="$c2"
              why="$why, 보정 상한 ${c2}초 = 보정 기준 ${bp}(기준 ${base} × max(1, 환경 배율 ${factor})) + 오차 ${tol}"
              repro="$repro, 바뀌지 않은 절 ${nu}개의 합 master $(( (um + 500) / 1000 ))초·이 실행 $(( (ub + 500) / 1000 ))초, 환경 배율 ${factor}"
              if [ "$y" -le "$c2" ]; then
                verdict="경고"
                printf '::warning::ci-duration: %s 의 소요 %s초(예산 상향 %s초를 빼면 %s초)가 공통 상한 %s초를 넘었지만 바뀌지 않은 절의 환경 배율 %s 로 보정한 상한 %s초 안입니다 — 원인은 러너 환경 또는 이 PR 의 공용 경로 변경이며 추가 실행 없이는 둘을 가를 수 없어 실패시키지 않습니다. %s. 측정 범위: %s. 재현 입력: %s\n' \
                  "$key" "$secs" "$raise" "$y" "$c1" "$factor" "$c2" "$why" "$scope" "$repro"
              fi
            else
              verdict="경고"
              printf '::warning::ci-duration: %s 의 소요 %s초(예산 상향 %s초를 빼면 %s초)가 공통 상한 %s초를 넘었지만 제한 요인을 분리할 수 없어 실패시키지 않습니다 — %s. %s. 측정 범위: %s. 재현 입력: %s\n' \
                "$key" "$secs" "$raise" "$y" "$c1" "${sep#no }" "$why" "$scope" "$repro"
            fi
          fi
          if [ "$y" -gt "$cap" ] && [ "$verdict" != "경고" ]; then
            need=$(( base_budget + secs - cap ))
            verdict="실패"; rc=1
            printf '::error::ci-duration: %s 의 소요가 master 기준 %s초보다 %s초 늘었습니다(예산 상향 %s초를 빼면 %s초) — 상한 %s초를 넘습니다(%s). 측정 범위: %s. 재현 입력: %s — 늘어난 것이 정당하면 이 PR 에서 scripts/ci-duration-budget.tsv 의 %s budget_s 를 %s 이상으로 올리세요\n' \
              "$key" "$base" "$(( secs - base ))" "$raise" "$(( y - base ))" "$cap" "$why" "$scope" "$repro" "$key" "$need"
          fi
        fi
      fi
    fi
    if [ "$secs" -gt $(( budget + tol )) ]; then
      [ "$verdict" = "실패" ] || verdict="경고"
      printf '::warning::ci-duration: %s 의 소요 %s초가 예산 %s초와 허용 오차 %s초의 합을 넘습니다\n' "$key" "$secs" "$budget" "$tol"
    fi
  fi

  {
    printf '### 소요 신호 — %s\n\n' "$key"
    printf '| 키 | 측정(초) | 기준(초) | 상한(초) | 배율 | 예산(초) | 오차(초) | 판정 |\n| --- | --- | --- | --- | --- | --- | --- | --- |\n'
    printf '| %s | %s | %s | %s | %s | %s | %s | %s%s |\n' "$key" "$secs" "${base:--}" "${cap:--}" "${factor:--}" "${budget:--}" "${tol:--}" "$verdict" "${notes:+ (${notes})}"
  } >> "${GITHUB_STEP_SUMMARY:-/dev/stdout}"

  if [ "$push" = "1" ]; then
    local dir="${wout:-${RUNNER_TEMP:-$tmp}/ci-duration-$key}"
    mkdir -p "$dir"
    { printf '# ci-duration window v1 — %s\n' "$key"
      { awk '!/^#/ && $1 ~ /^[0-9]+$/ { print $1 }' "$tmp/window"; printf '%s\n' "$secs"; } | tail -n 5
    } > "$dir/ci-duration-$key.tsv"
    printf 'ci-duration: 창을 %s 에 썼습니다\n' "$dir/ci-duration-$key.tsv"
  fi
  rm -rf "$tmp"
  return "$rc"
}

# --- self-test ---------------------------------------------------------------

dur_self_test() {
  local passed=0 failed=0 T out rc base_sha
  ok()  { passed=$((passed + 1)); printf 'PASS: %s\n' "$1"; }
  bad() { failed=$((failed + 1)); printf 'FAIL: %s — %s\n' "$1" "${2:-}" >&2; }
  T=$(mktemp -d "${TMPDIR:-/tmp}/ci-duration-selftest.XXXXXX")

  # gh is a PATH stub: the run list and the artifact query answer from files
  # under STUB_DIR, and `run download` copies the stub's window into -D. The
  # attempt, jobs and run-list endpoints of `wall` answer from JSON files run
  # through the caller's own --jq expression, so the expressions are tested; a
  # missing file is an API failure. The attempt endpoint answers attempt.json
  # for this run (GITHUB_RUN_ID) and attempt-<id>-<k>.json for another run.
  mkdir -p "$T/bin" "$T/stub"
  cat > "$T/bin/gh" <<'STUB'
#!/usr/bin/env bash
q=""; prev=""; for a in "$@"; do [ "$prev" = "--jq" ] && q="$a"; prev="$a"; done
emit() { [ -f "$1" ] || exit 1; if [ -n "$q" ]; then jq -r "$q" "$1"; else cat "$1"; fi; exit $?; }
case "$1 $2" in
  "api repos/"*"/workflows/"*) [ -f "$STUB_DIR/runs" ] && cat "$STUB_DIR/runs"; exit 0 ;;
  "api repos/"*"/artifacts"*) [ -f "$STUB_DIR/window" ] && echo 1 || echo 0; exit 0 ;;
  "api repos/"*"/attempts/"*"/jobs"*) emit "$STUB_DIR/jobs.json" ;;
  "api repos/"*"/attempts/"*)
    r=${2#*/runs/}
    if [ "${r%%/*}" = "$GITHUB_RUN_ID" ]; then emit "$STUB_DIR/attempt.json"; fi
    emit "$STUB_DIR/attempt-${r%%/*}-${r##*/}.json" ;;
  "api repos/"*"/actions/runs?"*) emit "$STUB_DIR/allruns.json" ;;
  "run download")
    while [ "$#" -gt 0 ]; do [ "$1" = "-D" ] && d="$2"; [ "$1" = "-n" ] && n="$2"; shift; done
    mkdir -p "$d" && cp "$STUB_DIR/window" "$d/${n}.tsv"; exit 0 ;;
esac
exit 1
STUB
  chmod +x "$T/bin/gh"

  # A repository whose base commit carries budget 100, tolerance 20 s / 10 %,
  # for gate and for lint-rest-tests.
  local R="$T/repo" bud='# ci-duration-budget v1\nkey\tbudget_s\ttol_s\ttol_pct\ngate\t100\t20\t10\nlint-rest-tests\t100\t20\t10\n'
  mkdir -p "$R/scripts"
  # shellcheck disable=SC2059
  printf "$bud" > "$R/scripts/ci-duration-budget.tsv"
  ( cd "$R" && git init -q . && git -c user.name=t -c user.email=t@invalid -c commit.gpgsign=false add -A \
      && git -c user.name=t -c user.email=t@invalid -c commit.gpgsign=false commit -qm base ) || { bad "픽스처 저장소" "git 실패"; rm -rf "$T"; return 1; }
  base_sha=$(cd "$R" && git rev-parse HEAD)
  printf '1 2026-01-01T00:00:00Z\n' > "$T/stub/runs"
  printf '# ci-duration window v1 — gate\n100\n90\n110\n' > "$T/stub/window"
  chk() { local key="$1" root="$2"; shift 2
          PATH="$T/bin:$PATH" STUB_DIR="$T/stub" GITHUB_REPOSITORY=o/r GITHUB_STEP_SUMMARY="$T/summary" \
            bash "$0" check --key "$key" --root "$root" "$@"; }
  run() { chk gate "$R" "$@"; }

  # Window 100 90 110: B 100, W 110, T max(20, 10) = 20, so C1 = max(120, 130) = 130.
  out=$(GITHUB_EVENT_NAME=pull_request chk lint-rest-tests "$R" --seconds 115 --base-sha "$base_sha" 2>&1); rc=$?
  if [ "$rc" = "0" ] && ! printf '%s' "$out" | grep -q '::error::'; then ok "오차 안의 증분은 통과한다"; else bad "오차 안" "rc=$rc $out"; fi

  out=$(GITHUB_EVENT_NAME=pull_request chk lint-rest-tests "$R" --seconds 150 --base-sha "$base_sha" 2>&1); rc=$?
  if [ "$rc" = "1" ] && printf '%s' "$out" | grep -q '^::error::.*50초 늘었습니다.*상한 130초.*측정 범위: rest 샤드들의 시험 시간 합.*재현 입력: 기준 창 master 실행 1 의 100 90 110.*budget_s 를 120 이상으로'; then
    ok "공통 상한을 넘은 분리 없는 키는 실패하고 상한·측정 범위·재현 입력·통과에 필요한 예산을 적는다"
  else
    bad "승인 없는 초과" "rc=$rc $out"
  fi

  out=$(GITHUB_EVENT_NAME=pull_request chk lint-rest-tests "$R" --seconds 125 --base-sha "$base_sha" 2>&1); rc=$?
  if [ "$rc" = "0" ] && ! printf '%s' "$out" | grep -q '::error::'; then
    ok "기준+오차 120 은 넘어도 창 최댓값+tol_s 130 안이면 통과한다"
  else
    bad "공통 상한 창 최댓값" "rc=$rc $out"
  fi

  out=$(GITHUB_EVENT_NAME=pull_request chk lint-rest-tests "$R" --seconds 150 --base-sha "$base_sha" --plan-dir "$T" 2>&1); rc=$?
  if [ "$rc" = "2" ]; then ok "gate 가 아닌 키에 --plan-dir 를 주면 사용법 오류다"; else bad "분리 인자 키 제한" "rc=$rc $out"; fi

  printf '# ci-duration-budget v1\nkey\tbudget_s\ttol_s\ttol_pct\ngate\t140\t20\t10\n' > "$R/scripts/ci-duration-budget.tsv"
  out=$(GITHUB_EVENT_NAME=pull_request run --seconds 150 --base-sha "$base_sha" 2>&1); rc=$?
  if [ "$rc" = "0" ] && ! printf '%s' "$out" | grep -q '::error::'; then ok "같은 PR 의 예산 상향이 초과를 승인한다"; else bad "예산 상향 승인" "rc=$rc $out"; fi
  # shellcheck disable=SC2059
  printf "$bud" > "$R/scripts/ci-duration-budget.tsv"

  : > "$T/summary"
  out=$(GITHUB_EVENT_NAME=push GITHUB_REF=refs/heads/master run --seconds 125 --window-out "$T/win" 2>&1); rc=$?
  if [ "$rc" = "0" ] && printf '%s' "$out" | grep -q '^::warning::.*125초가 예산 100초와 허용 오차 20초의 합을 넘습니다'; then
    ok "예산과 오차의 합을 넘으면 실패 없이 경고한다"
  else
    bad "절대 경고" "rc=$rc $out"
  fi
  if grep -q '^| gate | 125 | 100 | - | - | 100 | 20 | 경고 |$' "$T/summary"; then ok "결과 표 한 줄이 잡 요약에 남는다"; else bad "요약 표" "$(cat "$T/summary")"; fi
  if [ "$(grep -v '^#' "$T/win/ci-duration-gate.tsv" | tr '\n' ' ')" = "100 90 110 125 " ]; then ok "push to master 는 창에 측정을 더한다"; else bad "push 창" "$(cat "$T/win/ci-duration-gate.tsv" 2>/dev/null)"; fi
  printf '10\n20\n30\n40\n50\n' > "$T/stub/window"
  GITHUB_EVENT_NAME=push GITHUB_REF=refs/heads/master run --seconds 60 --window-out "$T/win2" >/dev/null 2>&1
  if [ "$(grep -v '^#' "$T/win2/ci-duration-gate.tsv" | tr '\n' ' ')" = "20 30 40 50 60 " ]; then ok "창은 최근 다섯 개만 남는다"; else bad "창 다섯" "$(cat "$T/win2/ci-duration-gate.tsv" 2>/dev/null)"; fi

  rm -f "$T/stub/runs"
  out=$(GITHUB_EVENT_NAME=pull_request run --seconds 500 --base-sha "$base_sha" 2>&1); rc=$?
  if [ "$rc" = "0" ] && printf '%s' "$out" | grep -q '^::warning::.*기준값.*얻지 못해 증분 판정을 건너뜁니다'; then
    ok "기준값이 없으면 증분 판정을 건너뛰고 실패시키지 않는다"
  else
    bad "기준값 없음" "rc=$rc $out"
  fi
  printf '1 2026-01-01T00:00:00Z\n' > "$T/stub/runs"
  out=$(GITHUB_EVENT_NAME=pull_request run --seconds 500 --base-sha 0000000000000000000000000000000000000000 2>&1); rc=$?
  if [ "$rc" = "0" ] && printf '%s' "$out" | grep -q '^::warning::.*베이스 예산.*건너뜁니다'; then
    ok "베이스 예산을 읽지 못하면 증분 판정을 건너뛴다"
  else
    bad "베이스 예산 없음" "rc=$rc $out"
  fi

  # gate: base and head budget 20000, tolerance 900 s / 12 %. The plan
  # directory and the merged section file are made the way gate-plan and
  # gate-report make them. Each `id:seconds` becomes three synthetic sections
  # id1..id3 whose ms add up to it. Both files also carry an `@head` row and a
  # section c01 that this run did not measure (its run column is the source's,
  # 9): either one counted would move the factor the assertions read.
  local R2="$T/repo2" P="$T/plan" SF="$T/sections.tsv" base2
  mkdir -p "$R2/scripts"
  printf '# ci-duration-budget v1\nkey\tbudget_s\ttol_s\ttol_pct\ngate\t20000\t900\t12\n' > "$R2/scripts/ci-duration-budget.tsv"
  ( cd "$R2" && git init -q . && git -c user.name=t -c user.email=t@invalid -c commit.gpgsign=false add -A \
      && git -c user.name=t -c user.email=t@invalid -c commit.gpgsign=false commit -qm base ) || { bad "gate 픽스처 저장소" "git 실패"; rm -rf "$T"; return 1; }
  base2=$(cd "$R2" && git rev-parse HEAD)
  gwin() { { printf '# ci-duration window v1 — gate\n'; printf '%s\n' "$@"; } > "$T/stub/window"; }
  tsec() { local run="$1" e id s ms a; shift
           for e in "$@"; do
             id=${e%%:*}; s=${e#*:}; ms=$((s * 1000)); a=$((ms / 3))
             printf '%s1\t%s\t%s\n%s2\t%s\t%s\n%s3\t%s\t%s\n' "$id" "$a" "$run" "$id" "$a" "$run" "$id" "$((ms - 2 * a))" "$run"
           done; }
  mkplan() { local src="$1" changed="$2"; shift 2
             rm -rf "$P"; mkdir -p "$P"
             printf '%s\n' "$src" > "$P/source"; printf '%s' "$changed" > "$P/changed"
             { printf '# gate-timing v1 — source: median of 9 generated: 2026-01-01T00:00:00Z\nid\tms\trun\n'
               printf '@head\t99999000\t9\nc01\t10000000\t9\n'; tsec 9 "$@"; } > "$P/gate-timing.tsv"; }
  mksec() { { printf '# gate-timing v1 — source: 777 m generated: 2026-01-01T00:00:00Z\nid\tms\trun\n'
              printf '@head\t5\t777\nc01\t10000000\t9\n'; tsec 777 "$@"; } > "$SF"; }
  grun() { GITHUB_EVENT_NAME=pull_request GITHUB_RUN_ID=777 chk gate "$R2" --base-sha "$base2" "$@"; }
  gsep() { grun --plan-dir "$P" --sections "$SF" "$@"; }
  quiet_ok() { [ "$1" = "0" ] && ! printf '%s' "$2" | grep -q -E '::error::|환경 배율|분리할 수 없어'; }

  # Observed failing runs of 2026-10-28 and 2026-10-31, replayed. The first
  # four are inside the common upper bound: B 25248 W 29879 T 3030 gives
  # C1 30779, B 25483 W 31752 T 3058 gives C1 32652.
  gwin 24743 25483 25248 25226 29879
  out=$(grun --seconds 29856 2>&1); rc=$?
  if quiet_ok "$rc" "$out"; then ok "41157701772(29856초)은 공통 상한 30779초 안이라 증분 경고 없이 통과한다"; else bad "41157701772" "rc=$rc $out"; fi
  out=$(grun --seconds 30271 2>&1); rc=$?
  if quiet_ok "$rc" "$out"; then ok "40738671993(30271초)은 공통 상한 안이라 통과한다"; else bad "40738671993" "rc=$rc $out"; fi
  out=$(grun --seconds 28947 2>&1); rc=$?
  if quiet_ok "$rc" "$out"; then ok "40740534934(28947초)은 공통 상한 안이라 통과한다"; else bad "40740534934" "rc=$rc $out"; fi
  gwin 25483 25248 25226 29879 31752
  out=$(grun --seconds 29452 2>&1); rc=$?
  if quiet_ok "$rc" "$out"; then ok "41161500842(29452초)은 공통 상한 32652초 안이라 통과한다"; else bad "41161500842" "rc=$rc $out"; fi
  # B 25226 W 25483 T 3028: C1 28254, crossed; the unchanged sections were
  # 24365 s on master and 29279 / 28995 / 28145 s in the run.
  gwin 24383 24743 25483 25248 25226
  mkplan artifact '' u:24365
  warned() { [ "$1" = "0" ] && ! printf '%s' "$2" | grep -q '::error::' \
             && printf '%s' "$2" | grep -q "^::warning::.*환경 배율 $3 .*러너 환경 또는 이 PR 의 공용 경로 변경.*측정 범위: 행 시간의 합.*재현 입력: 기준 창 master 실행 1 의 24383 24743 25483 25248 25226, 바뀌지 않은 절 3개"; }
  mksec u:29279
  out=$(gsep --seconds 30115 2>&1); rc=$?
  if warned "$rc" "$out" 1.202; then ok "40721275111(30115초)은 환경 배율 1.202 로 설명되어 경고로 끝난다"; else bad "40721275111" "rc=$rc $out"; fi
  mksec u:28995
  out=$(gsep --seconds 29839 2>&1); rc=$?
  if warned "$rc" "$out" 1.190; then ok "40736325599(29839초)은 환경 배율 1.190 으로 경고로 끝난다"; else bad "40736325599" "rc=$rc $out"; fi
  mksec u:28145
  out=$(gsep --seconds 31272 2>&1); rc=$?
  if warned "$rc" "$out" 1.155; then ok "관측 최댓값 31272초도 관측된 가장 낮은 배율 1.155 에서 경고로 끝난다"; else bad "31272" "rc=$rc $out"; fi

  # A pull request that did add time. B 25200 W 25400 T 3024: C1 28224.
  gwin 25000 25100 25200 25300 25400
  mkplan artifact 'ch1,ch2,ch3' u:24000 ch:200
  mksec u:24000 ch:4200
  out=$(gsep --seconds 29400 2>&1); rc=$?
  if [ "$rc" = "1" ] && printf '%s' "$out" | grep -q '^::error::.*상한 28224초.*budget_s 를 21176 이상으로'; then
    ok "배율 1.0 에서 바뀐 절이 늘면 실패하고 필요한 예산 21176 을 적는다"
  else
    bad "바뀐 절 증가 배율 1.0" "rc=$rc $out"
  fi
  mksec u:28800 ch:5200
  : > "$T/summary"
  out=$(gsep --seconds 35240 2>&1); rc=$?
  if [ "$rc" = "1" ] && printf '%s' "$out" | grep -q '^::error::.*상한 33264초.*환경 배율 1.200.*budget_s 를 21976 이상으로'; then
    ok "배율 1.2 로 보정해도 바뀐 절의 증가가 남으면 실패하고 필요한 예산 21976 을 적는다"
  else
    bad "바뀐 절 증가 배율 1.2" "rc=$rc $out"
  fi
  if grep -q '^| gate | 35240 | 25200 | 33264 | 1.200 | 20000 | 3024 | 실패 |$' "$T/summary"; then ok "요약 표는 판정에 쓴 상한과 배율을 적는다"; else bad "요약 표 상한·배율" "$(cat "$T/summary")"; fi
  mkplan artifact '' u:24000
  mksec u:24000 nw:4000
  out=$(gsep --seconds 29400 2>&1); rc=$?
  if [ "$rc" = "1" ] && printf '%s' "$out" | grep -q '^::error::.*budget_s 를 21176 이상으로'; then
    ok "master 에 없는 새 절의 시간은 배율에 들지 않아 실패한다"
  else
    bad "새 절" "rc=$rc $out"
  fi

  # Past C1 with no usable separation: a warning naming the reason.
  sepless() { [ "$1" = "0" ] && ! printf '%s' "$2" | grep -q '::error::' \
              && printf '%s' "$2" | grep -q "^::warning::.*분리할 수 없어.*$3"; }
  out=$(grun --seconds 29400 2>&1); rc=$?
  if sepless "$rc" "$out" '--plan-dir 와 --sections'; then ok "분리 입력이 없으면 경고로 끝나고 사유를 적는다"; else bad "분리 입력 없음" "rc=$rc $out"; fi
  mkplan seed '' u:24000
  out=$(gsep --seconds 29400 2>&1); rc=$?
  if sepless "$rc" "$out" 'master 실측이 아닙니다(seed)'; then ok "타이밍 출처가 시드면 분리하지 않고 경고한다"; else bad "시드 출처" "rc=$rc $out"; fi
  mkplan artifact 'ch1,ch2,ch3' u:5000 ch:20000
  mksec u:5000 ch:20000
  out=$(gsep --seconds 29400 2>&1); rc=$?
  if sepless "$rc" "$out" '절반에 못 미쳐'; then ok "바뀌지 않은 절이 master 합의 절반을 덮지 못하면 분리하지 않고 경고한다"; else bad "덮는 범위 절반" "rc=$rc $out"; fi
  gwin 100 90 110

  # fetch-base --count: four master push runs, three taken, each into its own
  # directory — the stub writes `<name>.tsv` into -D the way the real download
  # does, so one shared directory would keep only the last one.
  printf '13 2026-01-03T00:00:00Z\n12 2026-01-02T00:00:00Z\n11 2026-01-01T00:00:00Z\n10 2025-12-31T00:00:00Z\n' > "$T/stub/runs"
  printf 'id\tms\trun\nx\t1\t1\n' > "$T/stub/window"
  fb() { PATH="$T/bin:$PATH" STUB_DIR="$T/stub" GITHUB_REPOSITORY=o/r bash "$0" fetch-base --name gate-timing --workflow gate.yml "$@"; }
  out=$(fb --count 3 --out "$T/fb3" 2>&1); rc=$?
  if [ "$rc" = "0" ] && [ "$(printf '%s\n' "$out" | cut -d' ' -f1 | tr '\n' ' ')" = "13 12 11 " ] \
     && [ -f "$T/fb3/13/gate-timing.tsv" ] && [ -f "$T/fb3/12/gate-timing.tsv" ] && [ -f "$T/fb3/11/gate-timing.tsv" ] && [ ! -e "$T/fb3/10" ]; then
    ok "fetch-base --count 3 은 최신 순 셋을 실행마다 하위 디렉터리에 받고 한 줄씩 낸다"
  else
    bad "fetch-base --count 3" "rc=$rc out=$out $(find "$T/fb3" -type f 2>/dev/null | tr '\n' ' ')"
  fi
  out=$(fb --out "$T/fb1" 2>&1); rc=$?
  if [ "$rc" = "0" ] && [ "$out" = "13 2026-01-03T00:00:00Z" ] && [ -f "$T/fb1/gate-timing.tsv" ]; then
    ok "개수 인자가 없으면 한 실행을 --out 에 바로 받고 한 줄을 낸다"
  else
    bad "fetch-base 개수 없음" "rc=$rc out=$out"
  fi

  # wall: the shape of run 39640545294 — the attempt started 17:04:45, the
  # plan job took 8 s, the longest shard 2499 s, and the report job started
  # 11 s before now (17:46:54), so raw 2529, path 2518, queued 11.
  if command -v jq >/dev/null 2>&1; then
    local now W="$T/wall"
    now=$(jq -n '"2026-10-21T17:46:54Z" | fromdate')
    mkdir -p "$W/t"
    printf '{"id":39640545294,"head_sha":"S0","run_started_at":"2026-10-21T17:04:45Z"}\n' > "$T/stub/attempt.json"
    printf '%s\n' '{"jobs":[' \
      '{"name":"gate-plan","started_at":"2026-10-21T17:04:50Z","completed_at":"2026-10-21T17:04:58Z"},' \
      '{"name":"shard-coverage","started_at":"2026-10-21T17:05:00Z","completed_at":"2026-10-21T17:05:30Z"},' \
      '{"name":"gate-shards (1)","started_at":"2026-10-21T17:05:05Z","completed_at":"2026-10-21T17:46:44Z"},' \
      '{"name":"gate-shards (2)","started_at":"2026-10-21T17:05:06Z","completed_at":"2026-10-21T17:20:00Z"},' \
      '{"name":"gate-report","started_at":"2026-10-21T17:46:43Z","completed_at":null}]}' > "$T/stub/jobs.json"
    # The run itself and its lint run share sha S0; S1 started after the window
    # [17:04:45, 17:05:06] closed; S2 finished before it opened.
    local quiet='{"id":39640545294,"head_sha":"S0","created_at":"2026-10-21T17:04:40Z","run_started_at":"2026-10-21T17:04:45Z","status":"in_progress","updated_at":"2026-10-21T17:46:00Z"},
{"id":39640545131,"head_sha":"S0","created_at":"2026-10-21T17:04:40Z","run_started_at":"2026-10-21T17:04:46Z","status":"completed","updated_at":"2026-10-21T17:10:00Z"},
{"id":39646172838,"head_sha":"S1","created_at":"2026-10-21T17:42:20Z","run_started_at":"2026-10-21T17:42:25Z","status":"in_progress","updated_at":"2026-10-21T17:43:00Z"},
{"id":39628514969,"head_sha":"S2","created_at":"2026-10-21T16:00:00Z","run_started_at":"2026-10-21T16:00:05Z","status":"completed","updated_at":"2026-10-21T16:30:00Z"}'
    printf '{"workflow_runs":[%s]}\n' "$quiet" > "$T/stub/allruns.json"
    local k=1; while [ "$k" -le 13 ]; do printf '@start\t1\n@end\t2\n' > "$W/t/timing-$k.tsv"; k=$((k + 1)); done
    wall() { PATH="$T/bin:$PATH" STUB_DIR="$T/stub" GITHUB_REPOSITORY=o/r GITHUB_RUN_ID=39640545294 GITHUB_RUN_ATTEMPT=1 GITHUB_SHA="${WALL_SHA:-S0}" \
               CI_DURATION_NOW="${WALL_NOW:-$now}" bash "$0" wall --slots 13 --runners 13 --lanes 1 --timing-dir "$W/t" "$@"; }
    out=$(wall --out "$W/out/gate-wall.txt" 2>&1); rc=$?
    if [ "$rc" = "0" ] && printf '%s\n' "$out" | grep -q '^gate-wall: raw=2529 path=2518 queued=11 overlap=[0-9-]* rows=13/13 attempt=1 slots=13 runners=13 lanes=1 ' \
       && [ "$(cat "$W/out/gate-wall.txt")" = "$(printf '%s\n' "$out" | grep '^gate-wall: ')" ]; then
      ok "wall 은 39640545294 모양에서 raw 2529, path 2518, queued 11 을 내고 --out 에도 쓴다"
    else
      bad "wall 값" "rc=$rc $out"
    fi
    if printf '%s\n' "$out" | grep -q ' overlap=0 '; then ok "같은 sha 의 실행과 배정 창 밖의 다른 sha 실행은 겹침으로 세지 않는다"; else bad "겹침 0" "$out"; fi
    if [ "$rc" = "0" ] && printf '%s\n' "$out" | grep -q '^::warning::gate 벽시계 raw 2529초가 900초를 넘습니다'; then ok "raw 가 900 을 넘으면 경고만 내고 종료 0"; else bad "900 초과 경고" "rc=$rc $out"; fi
    out=$(WALL_NOW=$((now - 2000)) wall 2>&1)
    if printf '%s\n' "$out" | grep -q '^gate-wall: raw=529 ' && ! printf '%s\n' "$out" | grep -q '::warning::'; then ok "raw 가 900 이하면 경고하지 않는다"; else bad "900 이하 경고 오발" "$out"; fi
    # A pull request run: GITHUB_SHA is the merge commit M0, while the run, its
    # lint run and the attempt all carry the head S0.
    out=$(WALL_SHA=M0 wall 2>&1)
    if printf '%s\n' "$out" | grep -q ' overlap=0 '; then ok "pull request 실행은 GITHUB_SHA 가 병합 커밋이어도 자기 push 의 실행을 세지 않는다"; else bad "PR 겹침 0" "$out"; fi
    # The run itself is left out by id even where its listed sha differs.
    printf '{"workflow_runs":[%s,\n%s]}\n' "$quiet" \
      '{"id":39640545294,"head_sha":"SX","created_at":"2026-10-21T17:04:40Z","run_started_at":"2026-10-21T17:04:45Z","status":"in_progress","updated_at":"2026-10-21T17:46:00Z"}' > "$T/stub/allruns.json"
    out=$(wall 2>&1)
    if printf '%s\n' "$out" | grep -q ' overlap=0 '; then ok "자기 실행은 id 로 빠진다"; else bad "자기 실행 id" "$out"; fi
    printf '{"id":39640545294,"run_started_at":"2026-10-21T17:04:45Z"}\n' > "$T/stub/attempt.json"
    out=$(wall 2>&1); rc=$?
    if [ "$rc" = "0" ] && printf '%s\n' "$out" | grep -q '^gate-wall: raw=2529 path=2518 queued=11 overlap=- ' && printf '%s\n' "$out" | grep -q '^::notice::.*head_sha'; then
      ok "시도 응답에 head_sha 가 없으면 overlap 을 - 로 적고 종료 0"
    else
      bad "head_sha 없음" "rc=$rc $out"
    fi
    printf '{"id":39640545294,"head_sha":"S0","run_started_at":"2026-10-21T17:04:45Z"}\n' > "$T/stub/attempt.json"
    # S3 started before the window closed and is still running; S4 is queued
    # and has not started; S5 ran in the window and was rerun afterwards, so
    # the list gives its latest attempt's start, 17:40:00, and its attempt 1
    # says it ran 17:02:05 to 17:20:00. All three count.
    local live3
    live3='{"head_sha":"S3","created_at":"2026-10-21T17:00:00Z","run_started_at":"2026-10-21T17:00:05Z","status":"in_progress","updated_at":"2026-10-21T17:30:00Z"},
{"head_sha":"S4","created_at":"2026-10-21T17:03:00Z","run_started_at":"2026-10-21T17:03:00Z","status":"queued","updated_at":"2026-10-21T17:03:00Z"},
{"id":39650000005,"run_attempt":2,"head_sha":"S5","created_at":"2026-10-21T17:02:00Z","run_started_at":"2026-10-21T17:40:00Z","status":"in_progress","updated_at":"2026-10-21T17:41:00Z"}'
    printf '{"id":39650000005,"run_attempt":1,"created_at":"2026-10-21T17:02:00Z","run_started_at":"2026-10-21T17:02:05Z","status":"completed","updated_at":"2026-10-21T17:20:00Z"}\n' > "$T/stub/attempt-39650000005-1.json"
    printf '{"workflow_runs":[%s,\n%s]}\n' "$quiet" "$live3" > "$T/stub/allruns.json"
    out=$(wall 2>&1)
    if printf '%s\n' "$out" | grep -q ' overlap=3 '; then ok "창 안에 시작한 진행 중 실행, 아직 시작하지 않은 대기 실행, 창 뒤에 다시 돌린 실행은 센다"; else bad "겹침 3" "$out"; fi
    # S6 is the shape of lint 39632423148 against gate 39628514969 attempt 2:
    # its attempt 1 finished at 16:50:00, before the window opened, and its
    # attempt 2 began at 17:40:00, after the window closed. The list alone
    # shows it created before the window and still running.
    printf '{"id":39650000006,"run_attempt":1,"created_at":"2026-10-21T16:30:00Z","run_started_at":"2026-10-21T16:30:00Z","status":"completed","updated_at":"2026-10-21T16:50:00Z"}\n' > "$T/stub/attempt-39650000006-1.json"
    printf '{"workflow_runs":[%s,\n%s,\n%s]}\n' "$quiet" "$live3" \
      '{"id":39650000006,"run_attempt":2,"head_sha":"S6","created_at":"2026-10-21T16:30:00Z","run_started_at":"2026-10-21T17:40:00Z","status":"in_progress","updated_at":"2026-10-21T17:41:00Z"}' > "$T/stub/allruns.json"
    out=$(wall 2>&1)
    if printf '%s\n' "$out" | grep -q ' overlap=3 '; then ok "창 전에 끝났다가 창 뒤에 다시 돈 실행은 세지 않는다"; else bad "창 전 종료 후 재실행" "$out"; fi
    rm -f "$T/stub/attempt-39650000006-1.json"
    out=$(wall 2>&1); rc=$?
    if [ "$rc" = "0" ] && printf '%s\n' "$out" | grep -q ' overlap=- ' && printf '%s\n' "$out" | grep -q '^::notice::.*앞 시도 API'; then
      ok "다시 돈 실행의 앞 시도를 읽지 못하면 overlap 을 - 로 적고 종료 0"
    else
      bad "앞 시도 API 실패" "rc=$rc $out"
    fi
    # S7 has three attempts: attempt 1 finished before the window, attempt 2
    # began at 17:05:00, inside it, and attempt 3 began after it. S8's attempt
    # 1 was created at 17:03:00, queued through the window and started at
    # 17:30:00, then was rerun at 17:40:00. Both count, through attempt 2's own
    # start and through the run's creation.
    printf '{"id":39650000007,"run_attempt":1,"created_at":"2026-10-21T16:00:00Z","run_started_at":"2026-10-21T16:00:00Z","status":"completed","updated_at":"2026-10-21T16:20:00Z"}\n' > "$T/stub/attempt-39650000007-1.json"
    printf '{"id":39650000007,"run_attempt":2,"created_at":"2026-10-21T16:00:00Z","run_started_at":"2026-10-21T17:05:00Z","status":"completed","updated_at":"2026-10-21T17:25:00Z"}\n' > "$T/stub/attempt-39650000007-2.json"
    printf '{"id":39650000008,"run_attempt":1,"created_at":"2026-10-21T17:03:00Z","run_started_at":"2026-10-21T17:30:00Z","status":"completed","updated_at":"2026-10-21T17:35:00Z"}\n' > "$T/stub/attempt-39650000008-1.json"
    printf '{"workflow_runs":[%s,\n%s,\n%s,\n%s]}\n' "$quiet" "$live3" \
      '{"id":39650000007,"run_attempt":3,"head_sha":"S7","created_at":"2026-10-21T16:00:00Z","run_started_at":"2026-10-21T17:40:00Z","status":"in_progress","updated_at":"2026-10-21T17:41:00Z"}' \
      '{"id":39650000008,"run_attempt":2,"head_sha":"S8","created_at":"2026-10-21T17:03:00Z","run_started_at":"2026-10-21T17:40:00Z","status":"in_progress","updated_at":"2026-10-21T17:41:00Z"}' > "$T/stub/allruns.json"
    out=$(wall 2>&1)
    if printf '%s\n' "$out" | grep -q ' overlap=5 '; then ok "두 번째 시도가 창 안에 시작한 실행과 첫 시도가 창 안에 대기한 실행은 센다"; else bad "앞 시도 여럿·대기 첫 시도" "$out"; fi
    printf '{"workflow_runs":[%s,\n%s]}\n' "$quiet" "$live3" > "$T/stub/allruns.json"
    rm -f "$W/t/timing-7.tsv"
    out=$(wall 2>&1)
    if printf '%s\n' "$out" | grep -q ' rows=12/13 '; then ok "행 하나의 timing 파일이 없으면 rows=12/13"; else bad "빠진 행" "$out"; fi
    printf '@start\t1\n' > "$W/t/timing-7.tsv"
    out=$(wall 2>&1)
    if printf '%s\n' "$out" | grep -q ' rows=12/13 '; then ok "@end 가 없는 행 파일은 실행된 행으로 세지 않는다"; else bad "@end 없는 행" "$out"; fi
    # With the lanes' result files the count is theirs, not the timing files'
    # (still 12/13 above): 26 rows, row 9 without its total line.
    mkdir -p "$W/r"
    for k in $(seq 1 26); do printf '%s\t0\ttest-gate: 3 passed, 0 failed\n' "$k" > "$W/r/result-$k.tsv"; done
    out=$(wall --slots 26 --lanes 2 --result-dir "$W/r" 2>&1)
    if printf '%s\n' "$out" | grep -q ' rows=26/26 .* lanes=2 '; then ok "결과 파일이 있으면 rows 는 합계 줄을 낸 행 수다"; else bad "결과 파일 rows" "$out"; fi
    printf '9\t1\t-\n' > "$W/r/result-9.tsv"
    out=$(wall --slots 26 --lanes 2 --result-dir "$W/r" 2>&1)
    if printf '%s\n' "$out" | grep -q ' rows=25/26 '; then ok "합계 줄이 없는 결과 파일의 행은 세지 않는다"; else bad "합계 줄 없는 결과" "$out"; fi
    # An extra isolation row 27 has no total; its `격리 전용 행` result counts.
    printf '27\t0\t격리 전용 행\n' > "$W/r/result-27.tsv"
    out=$(wall --slots 27 --lanes 2 --result-dir "$W/r" 2>&1)
    if printf '%s\n' "$out" | grep -q ' rows=26/27 '; then ok "격리 전용 행 결과를 낸 추가 행도 실행한 행으로 센다"; else bad "격리 전용 행 rows" "$out"; fi
    # Attempt 2 reran shard 2 alone at 17:30:00: the plan job and shard 1 carry
    # attempt 1's times, before the attempt's own start.
    printf '{"id":39640545294,"head_sha":"S0","run_started_at":"2026-10-21T17:30:00Z"}\n' > "$T/stub/attempt.json"
    printf '%s\n' '{"jobs":[' \
      '{"name":"gate-plan","started_at":"2026-10-21T17:04:50Z","completed_at":"2026-10-21T17:04:58Z"},' \
      '{"name":"gate-shards (1)","started_at":"2026-10-21T17:05:05Z","completed_at":"2026-10-21T17:40:00Z"},' \
      '{"name":"gate-shards (2)","started_at":"2026-10-21T17:30:05Z","completed_at":"2026-10-21T17:46:00Z"},' \
      '{"name":"gate-report","started_at":"2026-10-21T17:46:43Z","completed_at":null}]}' > "$T/stub/jobs.json"
    out=$(GITHUB_RUN_ATTEMPT=2 wall 2>&1); rc=$?
    if [ "$rc" = "0" ] && printf '%s\n' "$out" | grep -q '^gate-wall: raw=- path=- queued=- overlap=- ' \
       && printf '%s\n' "$out" | grep -q '^::notice::.*실패한 잡만 다시 돌린 시도' && ! printf '%s\n' "$out" | grep -q '::warning::'; then
      ok "앞 시도에서 넘어온 잡이 있는 시도는 raw·path·queued·overlap 을 - 로 적고 종료 0"
    else
      bad "부분 재실행 시도" "rc=$rc $out"
    fi
    printf '{"id":39640545294,"head_sha":"S0","run_started_at":"2026-10-21T17:04:45Z"}\n' > "$T/stub/attempt.json"
    rm -f "$T/stub/jobs.json"
    out=$(wall 2>&1); rc=$?
    if [ "$rc" = "0" ] && printf '%s\n' "$out" | grep -q '^gate-wall: raw=2529 path=- queued=- overlap=- ' && printf '%s\n' "$out" | grep -q '^::notice::.*jobs API'; then
      ok "jobs API 가 실패하면 메모와 함께 - 로 적고 종료 0"
    else
      bad "jobs API 실패" "rc=$rc $out"
    fi
  else
    bad "wall 시험" "jq 가 없어 흉내가 --jq 식을 돌리지 못합니다"
  fi

  rm -rf "$T"
  printf 'ci-duration self-test: %d passed, %d failed\n' "$passed" "$failed"
  # A floor on the count, so a refactor that silently skips cases cannot pass.
  if [ "$passed" -lt 45 ]; then
    printf 'ci-duration self-test: 통과 수 %d 가 하한 45 에 못 미칩니다\n' "$passed" >&2
    return 1
  fi
  [ "$failed" = "0" ]
}

# --- main --------------------------------------------------------------------

[ "$#" -ge 1 ] || dur_usage
cmd="$1"; shift
case "$cmd" in
  check)       dur_check "$@"; exit $? ;;
  fetch-base)  dur_fetch_base "$@"; exit $? ;;
  wall)        dur_wall "$@"; exit $? ;;
  --self-test) dur_self_test; exit $? ;;
  *) printf 'ci-duration: 모르는 하위명령입니다: %s\n' "$cmd" >&2; dur_usage ;;
esac
