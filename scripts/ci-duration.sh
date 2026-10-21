#!/usr/bin/env bash
# The duration signal of the three test workflows — gate, lint's rest-tests and
# notify-macos. Each one measures its own test step and calls `check` with the
# seconds it took.
#
# A PULL REQUEST FAILS ONLY FOR WHAT IT ADDED. The comparison is the measurement
# against the master baseline, less whatever the same pull request raised that
# key's budget by in `scripts/ci-duration-budget.tsv`; past the tolerance the
# job fails, and the message says how far the budget would have to go up for
# the pull request to pass. Raising it is the approval, and the reviewer sees it
# as a one-line diff saying how many seconds this change costs CI. Growth that
# comes in steps too small to cross the tolerance is the absolute check's: any
# run whose measurement exceeds the budget plus the tolerance gets a warning
# annotation and a summary row, never a failure, so a master already over budget
# does not block an unrelated change.
#
# THE BASELINE IS THE MEDIAN OF THE LAST FIVE MASTER MEASUREMENTS. A push to
# master writes the window it was compared against, plus its own measurement,
# trimmed to five, as a file for the workflow to upload as `ci-duration-<key>`.
# `fetch-base` finds the newest master push run of the key's workflow — this
# repository's own, `event=push`, `branch=master` — that still has the artifact,
# the rule the gate plan job uses for its timing source. A fork's pull request
# can upload an artifact of the same name and never becomes a source, because
# only push runs are read.
#
# NOTHING MISSING FAILS A JOB. No baseline, no base budget, no budget row: the
# increment check is skipped with a warning saying which one was missing, and
# the absolute check still runs where the budget row exists.
#
# Usage:
#   bash scripts/ci-duration.sh check --key K --seconds S [--base-sha SHA]
#                                     [--window-out DIR] [--root DIR]
#   bash scripts/ci-duration.sh fetch-base (--key K | --name N --workflow W) --out DIR
#                                          [--count K]
#       prints `<run id> <created_at>` of the run it downloaded from; exit 1
#       when no master push run has the artifact. With --count K it takes up
#       to K such runs, newest first, each into DIR/<run id>/ so artifacts of
#       one name do not overwrite each other, and prints one line per run;
#       exit 0 when it got at least one
#   bash scripts/ci-duration.sh wall --slots S --runners N --lanes L
#                                    --timing-dir D [--out F]
#       the wall clock of this run attempt, as one `gate-wall:` line on stdout
#       and in F (see dur_wall)
#   bash scripts/ci-duration.sh --self-test
#
# The event comes from GITHUB_EVENT_NAME and GITHUB_REF; the pull request's base
# sha from --base-sha, or else from GITHUB_EVENT_PATH. The repository is
# GITHUB_REPOSITORY. Exit codes: 0 pass (warnings included), 1 the increment is
# over the tolerance, 2 usage.

set -uo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)

dur_usage() {
  printf 'ci-duration: 사용법 — check --key K --seconds S [--base-sha SHA] [--window-out DIR] [--root DIR] / fetch-base (--key K | --name N --workflow W) --out DIR [--count K] / wall --slots S --runners N --lanes L --timing-dir D [--out F] / --self-test\n' >&2
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
# started before it ends or not started, and not finished or finished after it
# began. This run itself (by id) and the runs of its own head sha (lint, notify)
# are not counted — the head sha is the attempt's, which on a pull request is
# the head and not the merge commit in GITHUB_SHA — and neither is a run that
# started after the window, which could not have made this one wait. Jobs of
# other repositories on the same account are not visible through this API, and
# the line says so. `rows` is the number of row timing
# files in D that reached their `@end` line, over S: a shard that died uploads
# a partial file, and the count is never filled in from the runner and lane
# numbers it was given. Nothing here fails the job: past 900 s raw it warns,
# and a value an API did not give is written `-` with a notice.
dur_wall() {
  local slots="" runners="" lanes="" tdir="" out=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --slots)      [ "$#" -ge 2 ] || dur_usage; slots="$2"; shift 2 ;;
      --runners)    [ "$#" -ge 2 ] || dur_usage; runners="$2"; shift 2 ;;
      --lanes)      [ "$#" -ge 2 ] || dur_usage; lanes="$2"; shift 2 ;;
      --timing-dir) [ "$#" -ge 2 ] || dur_usage; tdir="$2"; shift 2 ;;
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
  local pd sm rs ls wend f executed=0
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
    read -r pd sm rs ls <<EOF
$(printf '%s\n' "$jobs" | awk -F '\t' '
  $1 == "gate-plan" && $2 != "-" && $3 != "-" { pd = $3 - $2 }
  $1 ~ /^gate-shards/ && $2 != "-" { if (ls == "" || $2 > ls) ls = $2; if ($3 != "-" && (sm == "" || $3 - $2 > sm)) sm = $3 - $2 }
  $1 == "gate-report" && $2 != "-" { rs = $2 }
  END { print (pd == "" ? "-" : pd), (sm == "" ? "-" : sm), (rs == "" ? "-" : rs), (ls == "" ? "-" : ls) }')
EOF
    if [ "$pd" != "-" ] && [ "$sm" != "-" ] && [ "$rs" != "-" ]; then path=$(( pd + sm + now - rs )); fi
    if [ -n "$start" ] && [ -z "$sha" ]; then
      notes="${notes:+$notes · }시도 API 가 head_sha 를 주지 않아 overlap 을 세지 않았습니다"
    elif [ -n "$start" ]; then
      wend="$now"; [ "$ls" = "-" ] || wend="$ls"
      overlap=$(gh api "repos/$repo/actions/runs?per_page=100" \
        --jq "[.workflow_runs[] | select(.id != $rid) | select(.head_sha != \"$sha\") | select((.created_at | fromdate) < $wend) | select(.run_started_at == null or ((.run_started_at | fromdate) < $wend)) | select(.status != \"completed\" or ((.updated_at | fromdate) > $start))] | length" 2>/dev/null) || overlap=""
      case "$overlap" in ''|*[!0-9]*) overlap="-"; notes="${notes:+$notes · }실행 목록 API 를 읽지 못했습니다" ;; esac
    fi
  fi
  if [ "$raw" != "-" ] && [ "$path" != "-" ]; then queued=$(( raw - path )); fi
  for f in "$tdir"/timing-*.tsv; do
    [ -f "$f" ] || continue
    grep -q '^@end	' "$f" && executed=$((executed + 1))
  done
  local line
  line="gate-wall: raw=$raw path=$path queued=$queued overlap=$overlap rows=$executed/$slots attempt=${att:--} slots=$slots runners=$runners lanes=$lanes (overlap 은 이 저장소의 실행만 셉니다 — 다른 저장소의 잡은 이 API 로 보이지 않습니다)"
  printf '%s\n' "$line"
  if [ -n "$out" ]; then
    mkdir -p "$(dirname "$out")"
    printf '%s\n' "$line" > "$out"
  fi
  [ -z "$notes" ] || printf '::notice::ci-duration wall: %s — 읽지 못한 값은 - 로 적었습니다\n' "$notes"
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

dur_check() {
  local key="" secs="" base_sha="" wout="" root
  root=$(cd "$script_dir/.." && pwd)
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --key)        [ "$#" -ge 2 ] || dur_usage; key="$2"; shift 2 ;;
      --seconds)    [ "$#" -ge 2 ] || dur_usage; secs="$2"; shift 2 ;;
      --base-sha)   [ "$#" -ge 2 ] || dur_usage; base_sha="$2"; shift 2 ;;
      --window-out) [ "$#" -ge 2 ] || dur_usage; wout="$2"; shift 2 ;;
      --root)       [ "$#" -ge 2 ] || dur_usage; root="$2"; shift 2 ;;
      *) printf 'ci-duration: 모르는 인자입니다: %s\n' "$1" >&2; dur_usage ;;
    esac
  done
  [ -n "$key" ] || dur_usage
  case "$secs" in ''|*[!0-9]*) printf 'ci-duration: --seconds 는 0 이상의 정수 초입니다: %s\n' "$secs" >&2; dur_usage ;; esac
  local event="${GITHUB_EVENT_NAME:-}" ref="${GITHUB_REF:-}" pr=0 push=0
  [ "$event" = "pull_request" ] && pr=1
  [ "$event" = "push" ] && [ "$ref" = "refs/heads/master" ] && push=1
  if [ "$pr" = "1" ] && [ -z "$base_sha" ] && [ -n "${GITHUB_EVENT_PATH:-}" ] && [ -f "${GITHUB_EVENT_PATH}" ]; then
    base_sha=$(jq -r '.pull_request.base.sha // empty' "$GITHUB_EVENT_PATH" 2>/dev/null) || base_sha=""
  fi

  local tmp row budget tol_s tol_pct base="" base_budget="" tol="" verdict="통과" rc=0 notes=""
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
          local raise inc need
          raise=$(( budget - base_budget )); [ "$raise" -gt 0 ] || raise=0
          inc=$(( secs - base - raise ))
          if [ "$inc" -gt "$tol" ]; then
            need=$(( base_budget + secs - base - tol ))
            verdict="실패"; rc=1
            printf '::error::ci-duration: %s 의 소요가 master 기준 %s초보다 %s초 늘었습니다(예산 상향 %s초를 빼면 %s초, 허용 오차 %s초) — 늘어난 것이 정당하면 이 PR 에서 scripts/ci-duration-budget.tsv 의 %s budget_s 를 %s 이상으로 올리세요\n' \
              "$key" "$base" "$(( secs - base ))" "$raise" "$inc" "$tol" "$key" "$need"
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
    printf '| 키 | 측정(초) | 기준(초) | 예산(초) | 오차(초) | 판정 |\n| --- | --- | --- | --- | --- | --- |\n'
    printf '| %s | %s | %s | %s | %s | %s%s |\n' "$key" "$secs" "${base:--}" "${budget:--}" "${tol:--}" "$verdict" "${notes:+ (${notes})}"
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
  # missing file is an API failure.
  mkdir -p "$T/bin" "$T/stub"
  cat > "$T/bin/gh" <<'STUB'
#!/usr/bin/env bash
q=""; prev=""; for a in "$@"; do [ "$prev" = "--jq" ] && q="$a"; prev="$a"; done
emit() { [ -f "$1" ] || exit 1; if [ -n "$q" ]; then jq -r "$q" "$1"; else cat "$1"; fi; exit $?; }
case "$1 $2" in
  "api repos/"*"/workflows/"*) [ -f "$STUB_DIR/runs" ] && cat "$STUB_DIR/runs"; exit 0 ;;
  "api repos/"*"/artifacts"*) [ -f "$STUB_DIR/window" ] && echo 1 || echo 0; exit 0 ;;
  "api repos/"*"/attempts/"*"/jobs"*) emit "$STUB_DIR/jobs.json" ;;
  "api repos/"*"/attempts/"*) emit "$STUB_DIR/attempt.json" ;;
  "api repos/"*"/actions/runs?"*) emit "$STUB_DIR/allruns.json" ;;
  "run download")
    while [ "$#" -gt 0 ]; do [ "$1" = "-D" ] && d="$2"; [ "$1" = "-n" ] && n="$2"; shift; done
    mkdir -p "$d" && cp "$STUB_DIR/window" "$d/${n}.tsv"; exit 0 ;;
esac
exit 1
STUB
  chmod +x "$T/bin/gh"

  # A repository whose base commit carries budget 100, tolerance 20 s / 10 %.
  local R="$T/repo"
  mkdir -p "$R/scripts"
  printf '# ci-duration-budget v1\nkey\tbudget_s\ttol_s\ttol_pct\ngate\t100\t20\t10\n' > "$R/scripts/ci-duration-budget.tsv"
  ( cd "$R" && git init -q . && git -c user.name=t -c user.email=t@invalid -c commit.gpgsign=false add -A \
      && git -c user.name=t -c user.email=t@invalid -c commit.gpgsign=false commit -qm base ) || { bad "픽스처 저장소" "git 실패"; rm -rf "$T"; return 1; }
  base_sha=$(cd "$R" && git rev-parse HEAD)
  printf '1 2026-01-01T00:00:00Z\n' > "$T/stub/runs"
  printf '# ci-duration window v1 — gate\n100\n90\n110\n' > "$T/stub/window"
  run() { PATH="$T/bin:$PATH" STUB_DIR="$T/stub" GITHUB_REPOSITORY=o/r GITHUB_STEP_SUMMARY="$T/summary" \
            bash "$0" check --key gate --root "$R" "$@"; }

  out=$(GITHUB_EVENT_NAME=pull_request run --seconds 115 --base-sha "$base_sha" 2>&1); rc=$?
  if [ "$rc" = "0" ] && ! printf '%s' "$out" | grep -q '::error::'; then ok "오차 안의 증분은 통과한다"; else bad "오차 안" "rc=$rc $out"; fi

  out=$(GITHUB_EVENT_NAME=pull_request run --seconds 150 --base-sha "$base_sha" 2>&1); rc=$?
  if [ "$rc" = "1" ] && printf '%s' "$out" | grep -q '^::error::.*50초 늘었습니다.*budget_s 를 130 이상으로'; then
    ok "승인 없는 초과는 실패하고 통과에 필요한 예산을 적는다"
  else
    bad "승인 없는 초과" "rc=$rc $out"
  fi

  printf '# ci-duration-budget v1\nkey\tbudget_s\ttol_s\ttol_pct\ngate\t140\t20\t10\n' > "$R/scripts/ci-duration-budget.tsv"
  out=$(GITHUB_EVENT_NAME=pull_request run --seconds 150 --base-sha "$base_sha" 2>&1); rc=$?
  if [ "$rc" = "0" ] && ! printf '%s' "$out" | grep -q '::error::'; then ok "같은 PR 의 예산 상향이 초과를 승인한다"; else bad "예산 상향 승인" "rc=$rc $out"; fi
  printf '# ci-duration-budget v1\nkey\tbudget_s\ttol_s\ttol_pct\ngate\t100\t20\t10\n' > "$R/scripts/ci-duration-budget.tsv"

  : > "$T/summary"
  out=$(GITHUB_EVENT_NAME=push GITHUB_REF=refs/heads/master run --seconds 125 --window-out "$T/win" 2>&1); rc=$?
  if [ "$rc" = "0" ] && printf '%s' "$out" | grep -q '^::warning::.*125초가 예산 100초와 허용 오차 20초의 합을 넘습니다'; then
    ok "예산과 오차의 합을 넘으면 실패 없이 경고한다"
  else
    bad "절대 경고" "rc=$rc $out"
  fi
  if grep -q '^| gate | 125 | 100 | 100 | 20 | 경고 |$' "$T/summary"; then ok "결과 표 한 줄이 잡 요약에 남는다"; else bad "요약 표" "$(cat "$T/summary")"; fi
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
    # and has no start time. Both count.
    printf '{"workflow_runs":[%s,\n%s,\n%s]}\n' "$quiet" \
      '{"head_sha":"S3","created_at":"2026-10-21T17:00:00Z","run_started_at":"2026-10-21T17:00:05Z","status":"in_progress","updated_at":"2026-10-21T17:30:00Z"}' \
      '{"head_sha":"S4","created_at":"2026-10-21T17:03:00Z","run_started_at":null,"status":"queued","updated_at":"2026-10-21T17:03:00Z"}' > "$T/stub/allruns.json"
    out=$(wall 2>&1)
    if printf '%s\n' "$out" | grep -q ' overlap=2 '; then ok "창 안에 시작한 진행 중 실행과 시작 시각이 없는 대기 실행은 센다"; else bad "겹침 2" "$out"; fi
    rm -f "$W/t/timing-7.tsv"
    out=$(wall 2>&1)
    if printf '%s\n' "$out" | grep -q ' rows=12/13 '; then ok "행 하나의 timing 파일이 없으면 rows=12/13"; else bad "빠진 행" "$out"; fi
    printf '@start\t1\n' > "$W/t/timing-7.tsv"
    out=$(wall 2>&1)
    if printf '%s\n' "$out" | grep -q ' rows=12/13 '; then ok "@end 가 없는 행 파일은 실행된 행으로 세지 않는다"; else bad "@end 없는 행" "$out"; fi
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
  if [ "$passed" -lt 22 ]; then
    printf 'ci-duration self-test: 통과 수 %d 가 하한 22 에 못 미칩니다\n' "$passed" >&2
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
