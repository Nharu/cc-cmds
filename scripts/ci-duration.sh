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
#       prints `<run id> <created_at>` of the run it downloaded from; exit 1
#       when no master push run has the artifact
#   bash scripts/ci-duration.sh --self-test
#
# The event comes from GITHUB_EVENT_NAME and GITHUB_REF; the pull request's base
# sha from --base-sha, or else from GITHUB_EVENT_PATH. The repository is
# GITHUB_REPOSITORY. Exit codes: 0 pass (warnings included), 1 the increment is
# over the tolerance, 2 usage.

set -uo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)

dur_usage() {
  printf 'ci-duration: 사용법 — check --key K --seconds S [--base-sha SHA] [--window-out DIR] [--root DIR] / fetch-base (--key K | --name N --workflow W) --out DIR / --self-test\n' >&2
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
  local key="" name="" wf="" out="" repo ids id created n
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --key)      [ "$#" -ge 2 ] || dur_usage; key="$2"; shift 2 ;;
      --name)     [ "$#" -ge 2 ] || dur_usage; name="$2"; shift 2 ;;
      --workflow) [ "$#" -ge 2 ] || dur_usage; wf="$2"; shift 2 ;;
      --out)      [ "$#" -ge 2 ] || dur_usage; out="$2"; shift 2 ;;
      *) printf 'ci-duration: 모르는 인자입니다: %s\n' "$1" >&2; dur_usage ;;
    esac
  done
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
    mkdir -p "$out"
    if gh run download "$id" -R "$repo" -n "$name" -D "$out" >/dev/null 2>&1; then
      printf '%s %s\n' "$id" "$created"
      return 0
    fi
  done <<EOF
$ids
EOF
  return 1
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
  # under STUB_DIR, and `run download` copies the stub's window into -D.
  mkdir -p "$T/bin" "$T/stub"
  cat > "$T/bin/gh" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "api repos/"*"/workflows/"*) [ -f "$STUB_DIR/runs" ] && cat "$STUB_DIR/runs"; exit 0 ;;
  "api repos/"*"/artifacts"*) [ -f "$STUB_DIR/window" ] && echo 1 || echo 0; exit 0 ;;
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

  rm -rf "$T"
  printf 'ci-duration self-test: %d passed, %d failed\n' "$passed" "$failed"
  # A floor on the count, so a refactor that silently skips cases cannot pass.
  if [ "$passed" -lt 9 ]; then
    printf 'ci-duration self-test: 통과 수 %d 가 하한 9 에 못 미칩니다\n' "$passed" >&2
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
  --self-test) dur_self_test; exit $? ;;
  *) printf 'ci-duration: 모르는 하위명령입니다: %s\n' "$cmd" >&2; dur_usage ;;
esac
