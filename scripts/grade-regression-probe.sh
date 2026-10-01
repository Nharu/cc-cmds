#!/usr/bin/env bash
# Compare the gate's axis-2 grades before and after a merge.
#
# The gate calls this at its own merge verdict: `before` is the base branch's
# tree and `after` is the tree `git merge-tree --write-tree` says the merge
# would land. Each tree's `gate.sh grade` is asked about the same argv list,
# and an argv whose grade was known before the merge and is empty or
# `등급 미상` after it is a regression — the two shapes that refuse an act
# without authorizing it while writing a false record (an empty grade on
# `축2=`), so a table broken that way lands silently unless something asks
# the merged gate before it lands.
#
# EACH CHILD IS ITS OWN THROWAWAY RUN, UNDER `env -i`, CALLED WITH `grade`.
#
#   - `grade` and nothing else. `plan`, `act` and `exec` all enter the act
#     path, which is where the gate calls this script, so any of them would
#     recurse. `grade` asks the table and returns.
#   - A throwaway run, because even `grade` walks the gate's whole prelude:
#     the manifest and authorization checks, the run directory, and on a first
#     entry the run opening itself, which writes a `run` row, renders settings
#     and settles lost dispatches. Pointed at the calling run's manifest a
#     child would write into that run's ledger and hop into that run's pinned
#     copy — grading the pinned version rather than the merged one, which no
#     comparison could notice. So each tree gets its own repository, manifest,
#     authorization record and state home under this script's scratch
#     directory, and nothing a child can reach belongs to the caller.
#   - `env -i`, because the calling gate exports its own state — its working
#     directory, the pipeline seat, `CC_GATE_SOURCE_ONLY` — and a child that
#     inherited them either grades differently (a working directory inherited
#     from an outer gate has already turned a worktree write into `트리밖쓰기`
#     once) or returns at its first line having graded nothing. The child sees
#     `PATH` and the scratch paths, and nothing else.
#
# THE POSITIVE CONTROL COMES FIRST. `true` must be graded `읽기` by the tree
# before the merge; a child that did nothing would otherwise produce no
# regression, no ledger write and a clean exit — green on every count while
# measuring nothing. When the control fails the answer is "undecidable", never
# "no regression".
#
# A change between two known grades is reported and is not a regression: what
# the merge refuses is the forged-record shape, and a table edit that moves an
# argv from one real grade to another is the ordinary work of a slice.
#
# Usage:
#   bash scripts/grade-regression-probe.sh --repo <repository root> \
#     --before <tree-ish> --after <tree-ish> [--argv-file <file>]
#
#   --argv-file  one argv per line, split on blanks; blank lines and lines
#                starting with `#` are skipped. The first argv must be `true`
#                (the positive control). Without it the built-in list is used.
#
# Env overrides:
#   GRADE_PROBE_CHILD_TIMEOUT=<seconds>   per-child bound (default 60)
#
# Output: one line per finding (`회귀:` / `변화:`), the control line, and a
# final `판정:` line. Nothing is written outside this script's own scratch
# directory, which is removed on exit.
#
# Exit codes:
#   0  — no regression
#   1  — regression
#   2  — undecidable (extraction, sandbox setup, positive control, timeout)
#   64 — usage error
#
# Compatibility: bash 3.2 (macOS) — no associative arrays, no `mapfile`, no
# `timeout(1)`.

# No `-e`: a child gate that fails is an input to the verdict, not a failure of
# this script, and every step that can fail is checked where it runs.
set -uo pipefail

repo=""; before=""; after=""; argv_file=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo) repo="${2-}"; shift 2 || shift $# ;;
    --before) before="${2-}"; shift 2 || shift $# ;;
    --after) after="${2-}"; shift 2 || shift $# ;;
    --argv-file) argv_file="${2-}"; shift 2 || shift $# ;;
    *) printf 'grade-regression-probe: 모르는 인자: %s\n' "$1" >&2; exit 64 ;;
  esac
done
if [ -z "$repo" ] || [ -z "$before" ] || [ -z "$after" ]; then
  printf 'grade-regression-probe: --repo, --before, --after 가 모두 필요합니다\n' >&2
  exit 64
fi
if [ -n "$argv_file" ] && [ ! -f "$argv_file" ]; then
  printf 'grade-regression-probe: argv 파일이 없습니다: %s\n' "$argv_file" >&2
  exit 64
fi

child_timeout="${GRADE_PROBE_CHILD_TIMEOUT:-60}"

undecidable() {
  printf '판정: 판정 불가 — %s\n' "$1"
  exit 2
}

work=$(mktemp -d "${TMPDIR:-/tmp}/cc-grade-probe.XXXXXX") || undecidable "임시 디렉터리를 만들지 못했습니다"
trap 'rm -rf "$work"' EXIT

# The argv list. `true` is first because it is the positive control.
list="$work/argv"
if [ -n "$argv_file" ]; then
  grep -v -e '^[[:space:]]*$' -e '^[[:space:]]*#' "$argv_file" > "$list" || true
else
  cat > "$list" <<'PROBEARGV'
true
printenv HOME
git status
git merge-tree --write-tree a b
git rev-parse HEAD
git commit -m x
git push origin main
gh pr view 1
gh pr merge 1
gh pr create
gh issue create
rm -rf x
curl https://example.invalid
PROBEARGV
fi
[ "$(sed -n '1p' "$list")" = "true" ] \
  || { printf 'grade-regression-probe: argv 목록의 첫 줄은 양성 대조 true 여야 합니다\n' >&2; exit 64; }

# repo_tree <tree-ish> — the tree id, or nothing.
repo_tree() {
  ( cd "$repo" 2>/dev/null && git rev-parse --verify --quiet "$1^{tree}" 2>/dev/null ) || true
}
tree_before=$(repo_tree "$before")
tree_after=$(repo_tree "$after")
[ -n "$tree_before" ] || undecidable "머지 전 트리를 해소하지 못했습니다: $before"
[ -n "$tree_after" ] || undecidable "머지 결과 트리를 해소하지 못했습니다: $after"

# sb_env_set <sandbox> — the `env -i` prefix every command in that sandbox runs
# under, as an array so that `bounded` can start it as a plain command: a shell
# function sent to the background is a subshell, and killing the subshell leaves
# the gate it started running.
sb_env_set() {
  local sb="$1"
  SB_ENV=(env -i PATH="$PATH" HOME="$sb/home" XDG_STATE_HOME="$sb/state" TMPDIR="$sb/tmp"
    LC_ALL=C CC_GATE_PIN_DISABLE=1 GIT_CONFIG_NOSYSTEM=1)
}

# bounded <seconds> <out> <err> <cmd...> — run with a wall-clock bound. When the
# bound fires it leaves `<out>.timeout` behind, so a child that ran out of time
# is told apart from a child that exited on its own with a high code. The
# watchdog's streams go nowhere, so a caller reading this script's output
# through a pipe is not held open by it.
bounded() {
  local limit="$1" out="$2" err="$3" pid wd rc; shift 3
  "$@" > "$out" 2> "$err" &
  pid=$!
  (
    trap 'kill "$sp" 2>/dev/null; exit 0' TERM
    sleep "$limit" & sp=$!
    wait "$sp"
    : > "$out.timeout"
    kill -TERM "$pid" 2>/dev/null
  ) >/dev/null 2>&1 &
  wd=$!
  wait "$pid"; rc=$?
  kill -TERM "$wd" 2>/dev/null
  wait "$wd" 2>/dev/null
  return "$rc"
}

# sandbox <label> <tree> — extract the plugin from <tree> and stand up a run
# for it. Sets SB_WT, SB_MAN, SB_GATE.
sandbox() {
  local label="$1" tree="$2" sb plug run_id cg td pd bd row line inserted
  sb="$work/$label"
  plug="$sb/plugin"
  run_id="GP$label"
  mkdir -p "$sb/home" "$sb/state" "$sb/tmp" "$sb/repo" "$plug" || return 1
  sb_env_set "$sb"
  ( cd "$repo" && git archive "$tree" plugins/cc-cmds ) | tar -x -C "$plug" 2>/dev/null || return 1
  SB_GATE="$plug/plugins/cc-cmds/orchestrator/gate.sh"
  [ -f "$SB_GATE" ] && [ -f "$plug/plugins/cc-cmds/orchestrator/run.sh" ] || return 1
  ( cd "$sb/repo" \
    && "${SB_ENV[@]}" git init -q . \
    && mkdir -p docs/pipeline-run docs/pipeline-grant \
    && echo probe > a.txt \
    && "${SB_ENV[@]}" git add -A \
    && "${SB_ENV[@]}" git -c user.email=probe@example.invalid -c user.name=probe commit -qm probe \
    && "${SB_ENV[@]}" git branch -M main ) >/dev/null 2>&1 || return 1
  SB_WT=$(cd "$sb/repo" && "${SB_ENV[@]}" git rev-parse --show-toplevel 2>/dev/null) || return 1
  cg=$(cd "$sb/repo" && "${SB_ENV[@]}" git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  SB_MAN="$SB_WT/plan.md"
  cat > "$SB_WT/docs/pipeline-grant/$run_id.md" <<PROBEGRANT
# 파이프라인 인가 기록 — $run_id
<!-- cc-pipeline-grant v1; writer=autopilot; reader=orchestrator; owner-doc=(없음); origin-worktree=$SB_WT; NOT a design doc; mechanism-local, never staged by a skill -->

## 인가 $run_id
**인가 일시**: 2026-08-30T00:00:00Z
**종료 지점**: 등급 회귀 프로브
**권한 절단점**: 배포
**말단 행위 상한**: 없음
**직렬 웨이브 고지**: 해당 없음
**시각 정합 마커**: 없음
**사용자 확인 문면**: 등급 회귀 프로브
**설계 문서 전체 sha256**: (해당 없음)
**보고서**: $SB_WT/docs/pipeline-run/$run_id.md
PROBEGRANT
  row="- \`target\` | 별칭=main | 메인 워크트리=$SB_WT | 공통 git 디렉터리=$cg | 베이스 브랜치=main | 홈=예 | 원격 슬러그=probe/$run_id | 절단점=배포 | 말단 행위 상한=없음"
  td=$(printf '%s\n' "$row" | sed 's/[[:space:]]\{1,\}/ /g' | sort | shasum -a 256 | cut -d' ' -f1)
  pd=$(printf '%s\n' '{ "steps": [] }' | shasum -a 256 | cut -d' ' -f1)
  {
    printf '# 파이프라인 런 매니페스트 — %s\n' "$run_id"
    printf '<!-- cc-run-manifest v1; writer=autopilot; reader=orchestrator; run-id=%s;\n' "$run_id"
    printf '     anchor-kind=repo; anchor-key=probe/%s;\n' "$run_id"
    printf '     owner-doc=(없음); origin-worktree=%s;\n' "$SB_WT"
    printf '     NOT a design doc; mechanism-local, never staged by a skill -->\n\n'
    printf '## 런 정체\n'
    printf '**킥오프 일시**: 2026-01-01T00:00:00Z\n**런 id**: %s\n' "$run_id"
    printf '**앵커 종류**: repo\n**앵커 키**: probe/%s\n**사용자 확인 문면**: 등급 회귀 프로브\n\n' "$run_id"
    printf '## 의도\n```text\n등급 회귀 프로브\n```\n\n'
    printf '## 대상\n**대상 맵 다이제스트**: %s\n%s\n\n' "$td" "$row"
    printf '## 요소\n**설계 문서**: (없음)\n**적용 주체**: (해당 없음)\n\n'
    printf '## 실행 계획\n**계획 다이제스트**: %s\n**승인 문면**: 프로브\n```json\n%s\n```\n\n' "$pd" '{ "steps": [] }'
    printf '## 인가\n**런 최대 절단점**: 배포\n**종료 지점**: 프로브가 끝나면\n'
    printf '**벽시계 마감**: 2099-01-01T00:00:00Z\n**시각 정합 마커**: 없음\n'
    printf '**사다리 가용 단 수**: 4\n**미선언 상황 처분**: park\n'
  } > "$SB_MAN"
  # The binding digest by THIS TREE's own serializer, so a tree that changed
  # what the digest covers still admits its own manifest.
  bd=$(cd "$SB_WT" && "${SB_ENV[@]}" bash -c \
        'CC_ORCH_SOURCE_ONLY=1 . "$1" && MANIFEST="$2" && binding_set_bytes | shasum -a 256 | cut -d" " -f1' \
        _ "$plug/plugins/cc-cmds/orchestrator/run.sh" "$SB_MAN" 2>/dev/null) || return 1
  [ -n "$bd" ] || return 1
  inserted=""
  : > "$SB_MAN.bd"
  while IFS= read -r line || [ -n "$line" ]; do
    printf '%s\n' "$line" >> "$SB_MAN.bd"
    if [ -z "$inserted" ] && [ "$line" = "## 인가" ]; then
      printf '**구속 다이제스트**: %s\n' "$bd" >> "$SB_MAN.bd"
      inserted=1
    fi
  done < "$SB_MAN"
  mv "$SB_MAN.bd" "$SB_MAN" || return 1
}

# grade_all <label> <tree> <result file> — one line per argv: the grade, or
# nothing when the child printed none. Returns 2 when a child ran out of time.
grade_all() {
  local label="$1" tree="$2" res="$3" line g n=0
  sandbox "$label" "$tree" || return 3
  : > "$res"
  set -f
  while IFS= read -r line; do
    n=$((n + 1))
    # shellcheck disable=SC2086
    set -- $line
    # The exit code is not read: `grade` answers 2 on `등급 미상` by design, and a
    # child that died with any code is judged by the grade it did or did not print.
    ( cd "$SB_WT" && bounded "$child_timeout" "$work/$label.out.$n" "$work/$label.err.$n" \
        "${SB_ENV[@]}" bash "$SB_GATE" grade --manifest "$SB_MAN" -- "$@" ) || true
    if [ -e "$work/$label.out.$n.timeout" ]; then
      set +f
      return 2
    fi
    g=$(sed -n 's/^축2=//p' "$work/$label.out.$n" 2>/dev/null | tail -1)
    printf '%s\n' "$g" >> "$res"
  done < "$list"
  set +f
  return 0
}

grade_all before "$tree_before" "$work/before.res"
case $? in
  0) : ;;
  2) undecidable "머지 전 트리의 자식이 ${child_timeout}초 안에 끝나지 않았습니다" ;;
  *) undecidable "머지 전 트리를 꺼내거나 그 모래상자 런을 세우지 못했습니다" ;;
esac
control_before=$(sed -n '1p' "$work/before.res")
if [ "$control_before" != "읽기" ]; then
  undecidable "양성 대조 실패 — 머지 전 트리의 게이트가 true 를 「${control_before:-(빈 값)}」로 등급했습니다 (읽기 가 아니면 이 프로브는 아무것도 재지 못합니다)"
fi

grade_all after "$tree_after" "$work/after.res"
case $? in
  0) : ;;
  2) undecidable "머지 결과 트리의 자식이 ${child_timeout}초 안에 끝나지 않았습니다" ;;
  *) undecidable "머지 결과 트리를 꺼내거나 그 모래상자 런을 세우지 못했습니다" ;;
esac

total=$(grep -c . "$list" || true)
printf '대조: argv %s개 전부 — 머지 전 %s · 머지 결과 %s\n' "$total" "$tree_before" "$tree_after"
control_after=$(sed -n '1p' "$work/after.res")
printf '양성 대조: true %s → %s\n' "$control_before" "${control_after:-(빈 값)}"

regressions=0
i=0
while IFS= read -r line; do
  i=$((i + 1))
  b=$(sed -n "${i}p" "$work/before.res")
  a=$(sed -n "${i}p" "$work/after.res")
  case "$b" in ''|'등급 미상') continue ;; esac
  case "$a" in
    ''|'등급 미상')
      regressions=$((regressions + 1))
      printf '회귀: %s — %s → %s\n' "$line" "$b" "${a:-(빈 값)}" ;;
    "$b") : ;;
    *) printf '변화: %s — %s → %s\n' "$line" "$b" "$a" ;;
  esac
done < "$list"

if [ "$regressions" -gt 0 ]; then
  printf '판정: 회귀 %s건\n' "$regressions"
  exit 1
fi
printf '판정: 회귀 없음\n'
exit 0
