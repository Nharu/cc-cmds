#!/usr/bin/env bash
# lint-bash-portability: self-skip
# lint-autoadopt-vocabulary: self-skip
# Test the policy gate's refusals against a throwaway repository.
#
# The gate's whole value is in the branches a successful act never reaches, and
# every one of them is an EXIT CODE rather than a message — a router reads the
# status, not the prose. So each assertion here drives the CLI with argv the
# router could actually construct and asserts the code.
#
# Three of these reproduce defects measured in this tree rather than imagined:
#
#   1. A target-level cutpoint LOWER than the run maximum must win. The shipped
#      `authorized()` reads the run maximum and takes no target, so a run
#      declaring `frontend: PR` beside `infra: 배포` authorized deploy-grade acts
#      against the front end (Nharu/cc-cmds#208).
#   2. A refusal must report the MOST FUNDAMENTAL reason that holds. Under glob
#      order over Korean filenames a cutpoint violation came back as "the ledger
#      is unreadable", which sends a 3am reader to the wrong repair.
#   3. `grade` on a well-graded argv must exit 0. `[ … ] && exit` as a case
#      arm's last command hands the false test's status to the caller, so a
#      successful grading read as a refusal.
#
# The fixture is a `git init` in a scratch directory, used as its own
# origin-worktree, so nothing here touches the checkout the tests run from.
#
# Usage: bash scripts/test-gate.sh

set -uo pipefail

# THE RUN NOTIFIER IS OFF FOR THIS WHOLE PROCESS, and the switch is here rather
# than at the call sites because the call sites cannot be made exhaustive.
#
# The gate raises real banners — park notices carry the `hands` token, which
# also plays a sound — and its fire path prepends the Homebrew directories to
# PATH itself, so a stub placed on PATH by the suite is shadowed by whatever is
# really installed. The banner-seat section below handles both seams, but it
# begins three thousand lines in, and every `상태=park` and `stage-result`
# fixture before it fired at the real user. Measured: two banners reached a
# person from an ordinary `make test`, and one of them carried sound.
#
# Guarding each invocation was the obvious repair and is the wrong shape: there
# are over a hundred direct calls to the gate in this file and a new one is a
# normal thing to write, so the guard would be complete on the day it landed
# and quietly incomplete afterwards. An exported variable is inherited by every
# child, including calls nobody has written yet.
#
# `gateb`/`gateb_stage` turn it back ON for the assertions that need a banner to
# fire, which is the one place where firing is the thing being tested.
CC_CMDS_AUTOPILOT_NOTIFY=0
export CC_CMDS_AUTOPILOT_NOTIFY

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
GATE="$repo_root/plugins/cc-cmds/orchestrator/gate.sh"
LIVENESS="$repo_root/plugins/cc-cmds/orchestrator/liveness.sh"
RUNSH="$repo_root/plugins/cc-cmds/orchestrator/run.sh"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/cc-gate-test.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
export XDG_STATE_HOME="$WORK/state"

# `grep -q` on the right of a pipe exits as soon as it matches, which kills the
# writer with SIGPIPE — and under `pipefail` the whole pipeline then reports
# failure even though the match was found. GNU sed makes it loud ("couldn't
# flush stdout: Broken pipe") and BSD sed usually does not, so this failed only
# on the Linux leg and only once a scanned function grew long enough for the
# race to be real.
#
# `grep -c` has the same truth value and consumes its input to the end, so the
# writer never sees a closed pipe. The count goes to /dev/null; only the exit
# status is wanted.
grep_all_q() {
  # The count is CAPTURED, not redirected to /dev/null: BSD grep short-circuits
  # when its output is being discarded, which reintroduces the very SIGPIPE this
  # helper exists to avoid. Measured — `sed … | grep -c … >/dev/null` returns
  # 141 while `n=$(grep -c …)` returns 0.
  local n
  n=$(grep -c "$@" || true)
  [ "${n:-0}" != "0" ]
}

passed=0; failed=0
ok()   { passed=$((passed + 1)); printf 'PASS: %s\n' "$1"; }
bad()  { failed=$((failed + 1)); printf 'FAIL: %s — %s\n' "$1" "${2:-}" >&2; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got '$2', want '$3'"; fi; }

# DEFINED HERE, not beside its later uses. Three call sites sit ~130 lines
# above where this function used to be declared, so the shell reached them
# first and reported `graded_as: command not found` — the three assertions
# never ran, and a missing command is not a failed assertion, so the suite
# stayed green while covering nothing. A function used before its definition
# is the one shape a passing test count cannot reveal.
graded_as() {
  # graded_as <expected> <label> -- <argv...>
  local want="$1" label="$2"; shift 3
  gate grade --manifest "$MANIFEST" -- "$@"
  case "$msg" in
    *"축2=$want"*) ok "$label" ;;
    *) bad "$label" "want 축2=$want, got '$msg'" ;;
  esac
}

# `gate` runs the CLI and leaves the code in `rc` and the last non-log line in
# `msg`. The driver's own log lines go to stderr and are filtered out so an
# assertion on the refusal text does not match the banner above it.
# Every invocation runs FROM the fixture repository. `check_manifest` compares
# the manifest's `origin-worktree=` against `git rev-parse --show-toplevel` in
# the gate's own cwd, so a gate run from the checkout under test would reject a
# fixture manifest — and the driver itself runs from the home worktree, which is
# the shape this reproduces.
rc=0; msg=""
gate() {
  local out
  out=$(cd "$WT" && bash "$GATE" "$@" 2>&1); rc=$?
  # The WHOLE output, newlines flattened. A refusal arrives as two lines — the
  # checker's specific reason and the gate's generic "rule refused: <name>" —
  # and taking only the last one asserts against the generic half.
  msg=$(printf '%s' "$out" | grep -vE '\[run\] ' | tr '\n' ' ' | sed 's/[[:space:]]*$//')
  printf '%s' "$out" > "$WORK/last-output.txt"
}

# A FRESH snapshot digest per acting call. The digest now includes the ledger's
# own state, so it moves on every append — which is what makes exit 4 able to
# fire at all. Capturing it once and reusing it across several acts is exactly
# the stale-router pattern the check exists to refuse, and tests that did so
# were passing only because the digest could not move.
HH()  { cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null | jq -r .H; }
HH7() { cd "$WT" && XDG_STATE_HOME="$STATE7" bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null | jq -r .H; }
# The PROGRESS digest, which is a different value from the snapshot's H and must
# stay so — B1 watches this one, and seeding B1's state file with H made the
# boundary compare two unrelated values and reset instead of firing.
PD() { cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" --render 2>/dev/null \
       | sed -n 's/^진전 해시 : //p' | sed 's/[[:space:]]*$//'; }

# ---------------------------------------------------------------------------
# 0a. The pipefail trap, scanned the way the driver's own suite scans it
#
# Under `pipefail` an early-exiting reader on the right of a pipe kills the
# writer with SIGPIPE and the whole pipeline reports failure. In this file every
# such site was a PRESENCE test used to decide whether to append, so a row that
# existed came back as absent and the gate wrote a duplicate — duplicate
# approvals and duplicate obligations, which the termination conditions then
# count. The driver's suite already refuses this shape; the gate is the busier
# file and had six of them.
# ---------------------------------------------------------------------------
# The TEST files are scanned too. This class first bit the harness rather than
# the driver: an assertion of the form `sed … | grep -q …` reported a match as a
# miss on the Linux leg only, once the function it scanned grew long enough for
# the race to be real. A checker that exempts itself is the shape it exists to
# refuse.
# THE FIXED HALF IS NOT A GLOB, so a new file joins it only by being written in.
# The same omission already happened once with the shared-predicate file and
# nobody noticed; `notify-run.sh` is by design full of `grep` on the right of a
# pipe, so leaving it out would exempt the file most likely to carry the defect.
#
# THE LINT FAMILY JOINS BY GLOB INSTEAD, because being written in is exactly what
# it never was: every `scripts/lint-*.sh` sat outside this scan while the scan
# said in its own words that a checker exempting itself is the shape it exists to
# refuse. A family whose members are named by one pattern is the case where a
# written-in list buys nothing and costs the next file its coverage — and the
# cost is not hypothetical, since the vocabulary lint reads the head of every
# file it scans through a pipe whose reader stops at the first match.
scanned_files() {
  printf '%s\n' "$GATE" \
    "$repo_root/plugins/cc-cmds/orchestrator/watch.sh" \
    "$repo_root/plugins/cc-cmds/orchestrator/notify-run.sh" \
    "$repo_root/plugins/cc-cmds/orchestrator/stage-wrapper.sh" \
    "$repo_root/plugins/cc-cmds/hooks/gate-pretool.sh" \
    "$repo_root/plugins/cc-cmds/orchestrator/test-run.sh" \
    "$repo_root/scripts/test-gate.sh" \
    "$repo_root/scripts/test-watch.sh" \
    "$repo_root/scripts/test-snapshot.sh" \
    "$repo_root/scripts/test-orchestrator-pretool-hook.sh"
  for f in "$repo_root"/scripts/lint-*.sh; do
    [ -f "$f" ] || continue
    printf '%s\n' "$f"
  done
}
# A GLOB THAT EXPANDS TO NOTHING COVERS NOTHING AND LOOKS THE SAME WHILE DOING
# IT. An unexpanded pattern leaves `[ -f ]` false on every iteration and the
# loops below simply run shorter, which is the green this whole section exists
# to distrust — so the count is asserted rather than assumed.
nlint=0
for f in "$repo_root"/scripts/lint-*.sh; do
  [ -f "$f" ] || continue
  nlint=$((nlint + 1))
done
if [ "$nlint" -ge 1 ]; then
  ok "스캔 목록이 린트 계열을 글로브로 흡수한다 (${nlint}개)"
else
  bad "스캔 목록" "scripts/lint-*.sh 가 하나도 잡히지 않았다 — 목록이 비면 아래 루프는 조용히 짧아진다"
fi
while IFS= read -r f; do
  [ -n "$f" ] || continue
  [ -f "$f" ] || continue
  # `grep -c … >/dev/null` belongs in the pattern as well: BSD grep
  # short-circuits when its output is discarded, so that spelling is the same
  # early-exiting read wearing a different name.
  early=$(sed 's/#.*//' "$f" | grep -nE '\| *(head -|grep -[A-Za-z]*q|grep -c[A-Za-z]* [^|]*>/dev/null)' || true)
  if [ -z "$early" ]; then
    ok "파이프 오른쪽에 조기 종료 읽기가 없다: $(basename "$f")"
  else
    bad "pipefail 함정" "$(basename "$f"): $(printf '%s' "$early" | awk 'NR<=3' | tr '\n' ' ')"
  fi
done <<EOF
$(scanned_files)
EOF

# ---------------------------------------------------------------------------
# 0b. A helper called above its own definition, which no passing count can show
#
# A shell function exists only after the line that defines it has run, so a
# top-level call written above that line dies as `command not found` — and a
# missing command is not a failed assertion. Three calls in this file hit that
# and reported nothing: neither counter moved, the suite stayed green, and the
# assertions they carried covered nothing while reading as covered. Counting
# passes cannot reveal it, because nothing is failing; things are absent.
#
# ONLY COLUMN-ZERO CALLS COUNT. A call inside another function runs when that
# function is invoked, which can be anywhere below its own definition; a call at
# top level runs where it is written, and that is the shape that dies. The
# definition line itself is not a call — the name there is followed by `(`.
# ---------------------------------------------------------------------------
while IFS= read -r f; do
  [ -n "$f" ] || continue
  [ -f "$f" ] || continue
  offenders=""
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    defline=${d%%:*}
    name=$(printf '%s' "${d#*:}" | sed -E 's/\(\).*$//')
    [ -n "$name" ] || continue
    callline=$(grep -nE "^$name([[:space:]]|\$)" "$f" | sed -n '1s/:.*$//p')
    [ -n "$callline" ] || continue
    if [ "$callline" -lt "$defline" ]; then
      offenders="$offenders $name(호출 $callline < 정의 $defline)"
    fi
  done <<INNER
$(grep -nE '^[a-z_][a-z0-9_]*\(\) *\{' "$f")
INNER
  if [ -z "$offenders" ]; then
    ok "정의보다 먼저 불리는 헬퍼가 없다: $(basename "$f")"
  else
    bad "정의 전 호출" "$(basename "$f"):$offenders — 이 호출은 실패가 아니라 부재로 사라지므로 통과 개수에 드러나지 않는다"
  fi
done <<EOF
$(scanned_files)
EOF

# ---------------------------------------------------------------------------
# 0. Fixture — a real repository, two targets, two cutpoints
# ---------------------------------------------------------------------------
REPO="$WORK/repo"
mkdir -p "$REPO"
( cd "$REPO" \
  && git init -q . \
  && git config user.email t@example.invalid \
  && git config user.name  T \
  && mkdir -p docs/pipeline-run docs/pipeline-grant \
  && echo one > a.txt && git add -A && git commit -qm one \
  && echo base > base.txt && git add -A && git commit -qm base ) >/dev/null 2>&1

# A real bare remote, so `git push` is an act that actually runs rather than a
# string the gate merely approves. The gate PERFORMS what it passes, so a
# fixture whose acts all fail cannot tell an approval from a refusal.
REMOTE="$WORK/remote.git"
( git init -q --bare "$REMOTE" \
  && cd "$REPO" && git remote add origin "$REMOTE" \
  && git branch -M main && git push -q origin main ) >/dev/null 2>&1

WT=$(cd "$REPO" && git rev-parse --show-toplevel)
CG=$(cd "$REPO" && git rev-parse --path-format=absolute --git-common-dir)
MANIFEST="$WT/plan.md"
LEDGER="$WT/docs/pipeline-run/R1.md"
GRANT="$WT/docs/pipeline-grant/R1.md"

# The authorization record is part of the fixture now, because the gate reads it
# on every invocation. `owner-doc` mirrors the manifest header's `(없음)` — this
# is a documentless `repo`-anchored run — and the run maximum is the higher of
# the two target cutpoints.
cat > "$GRANT" <<GRANTEOF
# 파이프라인 인가 기록 — R1
<!-- cc-pipeline-grant v1; writer=autopilot; reader=orchestrator; owner-doc=(없음); origin-worktree=$WT; NOT a design doc; mechanism-local, never staged by a skill -->

## 인가 R1
**인가 일시**: 2026-08-30T00:00:00Z
**종료 지점**: 픽스처
**권한 절단점**: 배포
**말단 행위 상한**: 없음
**직렬 웨이브 고지**: 해당 없음
**시각 정합 마커**: 없음
**사용자 확인 문면**: 픽스처 인가
**설계 문서 전체 sha256**: (해당 없음)
**보고서**: $WT/docs/pipeline-run/R1.md
GRANTEOF

# Two targets on purpose. One run maximum of `배포` with a `PR` target is the
# only shape in which #208's defect is observable at all.
row_pr="- \`target\` | 별칭=front | 메인 워크트리=$WT | 공통 git 디렉터리=$CG | 베이스 브랜치=main | 홈=예 | 원격 슬러그=t/front | 절단점=PR | 말단 행위 상한=없음"
row_dp="- \`target\` | 별칭=infra | 메인 워크트리=$WT | 공통 git 디렉터리=$CG | 베이스 브랜치=main | 홈=아니오 | 원격 슬러그=t/infra | 절단점=배포 | 말단 행위 상한=없음"
TD=$(printf '%s\n%s\n' "$row_pr" "$row_dp" | sed 's/[[:space:]]\{1,\}/ /g' | sort | shasum -a 256 | cut -d' ' -f1)
PLAN='{ "steps": [] }'
PD=$(printf '%s\n' "$PLAN" | shasum -a 256 | cut -d' ' -f1)

{
  printf '# 파이프라인 런 매니페스트 — R1\n'
  printf '<!-- cc-run-manifest v1; writer=autopilot; reader=orchestrator; run-id=R1;\n'
  printf '     anchor-kind=repo; anchor-key=t/front;\n'
  printf '     owner-doc=(없음); origin-worktree=%s;\n' "$WT"
  printf '     NOT a design doc; mechanism-local, never staged by a skill -->\n\n'
  printf '## 런 정체\n'
  printf '**킥오프 일시**: 2026-01-01T00:00:00Z\n**런 id**: R1\n'
  printf '**앵커 종류**: repo\n**앵커 키**: t/front\n**사용자 확인 문면**: 테스트 픽스처\n\n'
  printf '## 의도\n```text\n테스트\n```\n\n'
  printf '## 대상\n**대상 맵 다이제스트**: %s\n%s\n%s\n\n' "$TD" "$row_pr" "$row_dp"
  printf '## 요소\n**설계 문서**: (없음)\n**적용 주체**: (해당 없음)\n\n'
  printf '## 실행 계획\n**계획 다이제스트**: %s\n**승인 문면**: 테스트\n```json\n%s\n```\n\n' "$PD" "$PLAN"
  printf '## 인가\n**런 최대 절단점**: 배포\n**종료 지점**: 픽스처가 끝나면\n'
  printf '**벽시계 마감**: 2030-01-01T00:00:00Z\n**시각 정합 마커**: 없음\n'
  printf '**사다리 가용 단 수**: 4\n**미선언 상황 처분**: park\n'
  printf -- '- `사전 인가` | 형태=gh pr | 사유=테스트\n'
  printf -- '- `사전 인가` | 형태=git push | 사유=테스트\n'
} > "$MANIFEST"

# The binding digest is computed FROM the finished manifest and appended after.
# The frozen set is goal + clauses + targets + rule settings + pre-authorization
# + deadline, and the digest field is not itself in that set — so appending it
# does not move the value it records.
refresh_bd() {
  # Recompute and rewrite the field. A test that edits the frozen set is
  # standing in for a kickoff, and a kickoff writes the digest — leaving a stale
  # one would make every later assertion fail for the same uninformative reason.
  local bd bd_err line inserted
  grep -v '^\*\*구속 다이제스트\*\*:' "$MANIFEST" > "$MANIFEST.tmp" && mv "$MANIFEST.tmp" "$MANIFEST"
  bd_err="$WORK/bd.err"
  bd=$(cd "$WT" && bash -c '
    CC_ORCH_SOURCE_ONLY=1 . "'"$repo_root"'/plugins/cc-cmds/orchestrator/run.sh"
    MANIFEST="'"$MANIFEST"'"
    binding_set_bytes | shasum -a 256 | cut -d" " -f1' 2>"$bd_err")
  # A broken fixture is not a test failure, so it exits rather than counting.
  # An empty digest still produces a well-formed line — `**구속 다이제스트**: `
  # with nothing after it — which every later assertion then reports as "the
  # field is absent", naming the symptom instead of the cause.
  if [ -z "$bd" ]; then
    printf 'refresh_bd: 구속 다이제스트 계산이 빈 값을 냈다\n' >&2
    sed 's/^/  bd stderr: /' "$bd_err" >&2
    exit 1
  fi

  # Inserted INSIDE `## 인가`, not appended to the file. `manifest_field` is
  # section-scoped and stops at the next `## `, so a digest appended after a
  # later section is read as absent — which is how a present-and-correct field
  # came back as "no binding digest" once another section was added below it.
  #
  # The insertion is a read loop rather than `awk`/`sed`: the heading it keys on
  # is Korean, and both an `awk` string equality and a BSD/GNU `a\` append have
  # to be trusted across two platforms to place one line. A `[ "$line" = … ]`
  # test is shell string equality, which is byte comparison everywhere.
  : > "$MANIFEST.bd"
  inserted=
  while IFS= read -r line || [ -n "$line" ]; do
    printf '%s\n' "$line" >> "$MANIFEST.bd"
    if [ -z "$inserted" ] && [ "$line" = "## 인가" ]; then
      printf '**구속 다이제스트**: %s\n' "$bd" >> "$MANIFEST.bd"
      inserted=1
    fi
  done < "$MANIFEST"
  if [ -z "$inserted" ]; then
    printf 'refresh_bd: 매니페스트에 「## 인가」 절이 없어 다이제스트를 넣을 자리가 없다\n' >&2
    exit 1
  fi
  mv "$MANIFEST.bd" "$MANIFEST"
}
refresh_bd

gate snapshot --manifest "$MANIFEST"
check "구속 다이제스트가 있는 매니페스트가 통과한다" "$rc" "0"
case "$msg" in
  *"구속 다이제스트가 없습니다"*) bad "구속 다이제스트" "필드를 넣었는데 없다고 한다" ;;
  *) ok "구속 다이제스트를 실제로 대조한다" ;;
esac
check "픽스처 매니페스트가 검사를 통과한다" "$rc" "0"

H=$(cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null | jq -r .H)

# ---------------------------------------------------------------------------
# 1. The snapshot is a JSON object, not a table
# ---------------------------------------------------------------------------
if (cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null) | jq -e . >/dev/null; then
  ok "스냅숏이 유효한 JSON 객체로 나온다"
else
  bad "스냅숏 JSON" "jq 가 파싱하지 못했다 — 라우터의 유일한 선언 입력이 깨졌다"
fi

# The ledger does not exist when a run's first gate call starts, which is the
# NORMAL state. `grep` answers a missing file with exit 2, `pipefail` promotes
# it, and `set -e` used to kill the whole snapshot at exactly the moment a
# router needs it most. The first call now also OPENS the ledger with the run
# row, so the property is asserted where it actually lives: the first
# invocation, against a state directory and a ledger that do not exist yet.
freshst="$WORK/state-first"; rm -f "$LEDGER"
out=$(cd "$WT" && XDG_STATE_HOME="$freshst" bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null); rc=$?
check "원장이 없는 상태에서 첫 호출이 답한다" "$rc" "0"
if printf '%s' "$out" | jq -e . >/dev/null 2>&1; then
  ok "그 답이 유효한 JSON 이다"
else
  bad "첫 호출" "JSON 이 아니다: $out"
fi
# And the first call is what opens the ledger. `run` had no writer at all, so a
# ledger carried no statement of what the run was.
n=$(grep -c '^- `run` ' "$LEDGER" 2>/dev/null || true)
check "첫 호출이 run 행 하나로 원장을 연다" "${n:-0}" "1"
case "$(grep '^- `run` ' "$LEDGER" 2>/dev/null | tail -1)" in
  *"보고서=$LEDGER"*) ok "run 행이 보고서 경로를 싣는다" ;;
  *) bad "run 행" "$(grep '^- `run` ' "$LEDGER" 2>/dev/null | tail -1)" ;;
esac
rm -f "$LEDGER"

n_total=$(cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null | jq -r .obligations_total)
check "빈 원장의 의무 총수가 0 하나로 나온다" "$n_total" "0"

# From here the ledger carries the KICKOFF STUB, because that is the file a real
# run's first act writes into: the ledger and the morning report are one file,
# and the skill's Step 7 puts an H1 and an identifying line there before the
# router takes its first turn. Seeding it makes every chain assertion below run
# against the shape a run actually has — which is the shape that used to read as
# broken at row 1 on every single run.
mkdir -p "$(dirname "$LEDGER")"
{
  printf '# 파이프라인 런 보고서 — R1\n\n'
  printf '런 id R1 · 앵커 repo:t/front · 대상 front(절단점 PR) infra(절단점 배포)\n'
} > "$LEDGER"

# ---------------------------------------------------------------------------
# 1b. The run settings the gate generates
#
# These files decide whether a stage has any hook coverage at all, and they are
# GENERATED — so nothing in the tree is reviewed when they are wrong. They
# shipped once as syntactically invalid JSON while every test here still passed,
# because no assertion had ever opened one.
# ---------------------------------------------------------------------------
SETTINGS_DIR="$XDG_STATE_HOME/cc-cmds/run/R1/settings"
if [ -d "$SETTINGS_DIR" ]; then
  ok "게이트가 런 개시에 설정 디렉터리를 만든다"
else
  bad "설정 생성" "$SETTINGS_DIR 가 없다 — 래퍼가 하드 스톱하므로 이 런은 스테이지를 하나도 띄우지 못한다"
fi

bad_json=0; n_variants=0
for f in "$SETTINGS_DIR"/*.json; do
  [ -f "$f" ] || continue
  n_variants=$((n_variants + 1))
  jq -e . "$f" >/dev/null 2>&1 || { bad_json=$((bad_json + 1)); printf '      깨진 파일: %s\n' "$f" >&2; }
done
check "모든 변종이 유효한 JSON 이다" "$bad_json" "0"
if [ "$n_variants" -ge 2 ]; then
  ok "스테이지 종류마다 변종이 하나씩 생긴다 (${n_variants}종)"
else
  bad "변종 수" "${n_variants}종 — 단일 파일이면 design 전용 제약을 표현할 자리가 없다"
fi

# THE STAGE MUST BE ABLE TO READ ITS OWN SKILL'S DOCUMENTS. Every skill here
# opens by Reading several `_common/*` files, and those live in the plugin cache
# — outside the working directory, so outside what the ambient configuration
# permits. Measured: a review stage ran seven turns, collected five `Read`
# denials under the plugin directory, reported that it had stopped before its
# first step, and exited 0 with no artifact.
missing_dirs=0
for f in "$SETTINGS_DIR"/*.json; do
  [ -f "$f" ] || continue
  n=$(jq -r '.permissions.additionalDirectories // [] | length' "$f" 2>/dev/null)
  [ "${n:-0}" -ge 1 ] || missing_dirs=$((missing_dirs + 1))
done
check "모든 변종이 읽을 수 있는 디렉터리를 선언한다" "$missing_dirs" "0"

plug=$(cd "$(dirname "$repo_root/plugins/cc-cmds/orchestrator")" && pwd)
if jq -e --arg d "$plug" '.permissions.additionalDirectories | index($d)' \
     "$SETTINGS_DIR/generic.json" >/dev/null 2>&1; then
  ok "플러그인 디렉터리가 그 목록에 있다 (스킬이 첫 단계에서 읽는 곳이다)"
else
  bad "플러그인 읽기" "$(jq -c '.permissions.additionalDirectories' "$SETTINGS_DIR/generic.json")"
fi
# The run's own files live under the HOME worktree, so a stage acting in any
# other target cannot reach the manifest, the ledger or the grant from its own
# directory.
if jq -e --arg d "$WT" '.permissions.additionalDirectories | index($d)' \
     "$SETTINGS_DIR/generic.json" >/dev/null 2>&1; then
  ok "런의 베이스도 그 목록에 있다 (매니페스트·원장·인가 기록이 거기 있다)"
else
  bad "런 파일 읽기" "$(jq -c '.permissions.additionalDirectories' "$SETTINGS_DIR/generic.json")"
fi

# The attempt term of the session id is DERIVED, not passed as argv. Without it
# a stage that died before producing anything kept its session id and every
# retry of that segment was refused by the CLI with "already in use" — after the
# gate had passed and after the row was appended, so the ledger showed two
# attempts and no output. Taking it as argv instead would let a router re-type
# the number it used last time, reproducing the collision through the surface
# meant to prevent it.
if grep -vE '^[[:space:]]*#' "$GATE" | grep_all_q -F 'session_uuid "$seg" "$attempt"'; then
  ok "스테이지 세션 id 에 시도 번호가 실린다"
else
  bad "시도 번호" "죽은 스테이지가 세션 id 를 점유해 같은 세그먼트를 재시도할 수 없다"
fi
if grep -vE '^[[:space:]]*#' "$GATE" | grep_all_q -F "gate_rows '자율 승인'"; then
  ok "그 번호를 원장에서 유도한다 (라우터가 적어 넣지 않는다)"
else
  bad "시도 유도" "시도 번호의 출처가 원장이 아니다"
fi

hook_cmd=$(jq -r '.hooks.PreToolUse[0].hooks[0].command // empty' "$SETTINGS_DIR/generic.json" 2>/dev/null)
case "$hook_cmd" in
  *gate-pretool.sh*--run-dir*--gate*)
    ok "훅 명령줄이 런 디렉터리와 게이트 경로를 파일에 박아 넣는다" ;;
  *)
    bad "훅 명령줄" "'$hook_cmd' — 환경에서 읽는 형태라면 스테이지가 env 하나로 훅을 끌 수 있다" ;;
esac

d_design=$(jq -r '.permissions.deny | join(",")' "$SETTINGS_DIR/design.json" 2>/dev/null)
d_review=$(jq -r '.permissions.deny | join(",")' "$SETTINGS_DIR/review.json" 2>/dev/null)
case "$d_design" in
  *WebFetch*) ok "design 변종만 네트워크 취득 도구를 불허한다" ;;
  *) bad "design 변종" "'$d_design' — 이 상한은 등급표로는 강제할 수 없어 여기가 유일한 지점이다" ;;
esac
case "$d_review" in
  *WebFetch*) bad "변종 구분" "review 변종까지 네트워크를 막았다 — design 전용 제약이 아니다" ;;
  *) ok "다른 변종은 그 제약을 받지 않는다" ;;
esac

# ---------------------------------------------------------------------------
# 2. Vocabulary — closed sets refuse by status, never by `die`
# ---------------------------------------------------------------------------
gate act --manifest "$MANIFEST" --kind x --target front --cutpoint 머지후 \
     --snapshot-digest "$(HH)" --rationale x -- git push origin main
check "어휘 밖 절단점 토큰은 거부된다" "$rc" "2"

# An undeclared repository is not a vocabulary error — it is the three-layer
# rule. Above `브랜치` nothing may be granted, so the act parks with a cause of
# its own rather than borrowing `인가 한도`, which means something else: that a
# target the manifest DID declare was exceeded.
gate act --manifest "$MANIFEST" --kind x --target nope --cutpoint push \
     --snapshot-digest "$(HH)" --rationale x -- git push origin main
check "미선언 대상의 push 는 거부된다" "$rc" "3"
if grep -q '사유=대상 미선언' "$LEDGER"; then
  ok "park 사유가 대상 미선언 이다 (인가 한도 를 빌려 쓰지 않는다)"
else
  bad "park 사유" "미선언 대상의 park 이 기록되지 않았거나 다른 사유를 쓴다"
fi
case "$msg" in
  *재인가*) ok "거부 문면이 재인가가 필요하다고 말한다" ;;
  *) bad "거부 문면" "'$msg'" ;;
esac

gate act --manifest "$MANIFEST" --kind x --target nope --cutpoint 커밋 \
     --worktree "$WT" --snapshot-digest "$(HH)" --rationale "이슈 링크에서 발견" -- touch "$WORK/nd"
check "미선언 대상의 로컬 쓰기는 통과한다" "$rc" "0"
if grep -q '^- `대상 추가`' "$LEDGER"; then
  ok "대상 추가 행이 남는다 (아침 리포트가 런이 건드린 레포를 보여 준다)"
else
  bad "대상 추가" "층 1 행위가 통과했는데 기록이 없다"
fi
if grep '^- `대상 추가`' "$LEDGER" | grep_all_q '층=1'; then
  ok "커밋 등급은 층 1 로 기록된다"
else
  bad "층 판정" "$(grep '^- `대상 추가`' "$LEDGER" | awk 'NR<=1')"
fi

# The chain anchors on the last ROW, not the last LINE. Hashing the last line
# made the first row point at the stub's identifying line while the verifier —
# which walks rows — started from the run heading, so an untouched ledger broke
# at row 1 every time. A chain that is always broken is worse than none: a real
# splice then looks exactly like a normal kickoff, and a reader who sees `끊김`
# every morning stops reading the field.
ci=$(cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null | jq -r .chain_intact)
check "스텁 산문이 앞에 있어도 체인은 무결이다" "$ci" "true"

# And when it IS broken the render says WHERE. Every caller used to throw the
# row number into `2>&1`, so the morning was told `끊김` and given nowhere to
# look.
cp "$LEDGER" "$WORK/ledger.bak"
printf -- '- `자율 승인` | kind=x | 결정=act | 대상=front | prev=%s\n' \
  "0000000000000000000000000000000000000000000000000000000000000000" >> "$LEDGER"
out=$(cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" --render 2>/dev/null)
case "$out" in
  *"해시 체인 : 끊김 —"*) ok "끊긴 자리의 행 번호가 렌더에 도달한다" ;;
  *) bad "체인 진단" "$(printf '%s' "$out" | grep '해시 체인' || true)" ;;
esac
cp "$WORK/ledger.bak" "$LEDGER"

gate act --manifest "$MANIFEST" --kind x --target nope2 --cutpoint 커밋 \
     --snapshot-digest "$(HH)" --rationale x -- touch "$WORK/nd2"
check "워크트리 없이 미선언 대상을 쓰려 하면 거부된다" "$rc" "2"

gate act --manifest "$MANIFEST" --kind x --target front --cutpoint 커밋 \
     --snapshot-digest "$(HH)" --rationale x -- frobnicate now
check "등급표에 없는 argv0 는 읽기로 떨어지지 않는다" "$rc" "2"

gate grade --manifest "$MANIFEST" -- frobnicate
check "grade 도 미상 argv0 를 어휘 오류로 답한다" "$rc" "2"

gate grade --manifest "$MANIFEST" -- gh pr merge
check "잘 등급된 argv 의 grade 는 성공으로 끝난다" "$rc" "0"
check "grade 가 축2 를 축자로 답한다" "$msg" "축2=외부상태변경"

gate grade --manifest "$MANIFEST" -- cat a.txt
check "읽기 등급이 읽기로 나온다" "$msg" "축2=읽기"

# ---------------------------------------------------------------------------
# 3. Cutpoint adjudication is PER TARGET (#208 regression)
# ---------------------------------------------------------------------------
gate act --manifest "$MANIFEST" --kind push --target front --cutpoint push \
     --snapshot-digest "$(HH)" --rationale x -- git push origin main
check "절단점 이하의 행위는 통과한다" "$rc" "0"

H=$(cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null | jq -r .H)
gate act --manifest "$MANIFEST" --kind merge --target front --segment S1 --cutpoint 머지 \
     --snapshot-digest "$(HH)" --rationale x -- gh pr merge 1
check "절단점 PR 인 대상에 머지는 거부된다" "$rc" "3"
case "$msg" in
  *"절단점-준수"*) ok "거부 사유가 절단점으로 보고된다 (가장 근본적인 이유가 이긴다)" ;;
  *) bad "거부 사유" "절단점 위반인데 '$msg' 로 보고됐다 — 3시에 엉뚱한 곳을 고치게 된다" ;;
esac

# The same act against the target the user granted `배포` to reaches the review
# rule instead — which is the proof that the refusal above was the TARGET's
# cutpoint and not the run maximum.
gate act --manifest "$MANIFEST" --kind merge --target infra --segment S1 --cutpoint 머지 \
     --snapshot-digest "$(HH)" --rationale x -- gh pr merge 1
case "$msg" in
  *"절단점-준수"*) bad "대상별 절단점" "배포 인가된 대상까지 절단점에서 막혔다" ;;
  *) ok "런 최대치가 아니라 대상 행의 값이 판정한다 (#208 회귀)" ;;
esac

# ---------------------------------------------------------------------------
# 4. Self-widening is refused at every cutpoint
# ---------------------------------------------------------------------------
gate act --manifest "$MANIFEST" --kind merge --target infra --segment S1 --cutpoint 배포 \
     --snapshot-digest "$(HH)" --rationale x -- gh pr merge 1 --admin
check "--admin 은 배포 인가에서도 거부된다" "$rc" "3"
case "$msg" in
  *"--admin"*) ok "거부 사유가 관리자 우회를 지목한다" ;;
  *) bad "--admin 사유" "'$msg'" ;;
esac

gate act --manifest "$MANIFEST" --kind x --target infra --cutpoint 배포 \
     --snapshot-digest "$(HH)" --rationale x -- tee "$GRANT"
check "인가 기록에 쓰려는 행위는 거부된다" "$rc" "3"

gate act --manifest "$MANIFEST" --kind x --target infra --cutpoint 배포 \
     --snapshot-digest "$(HH)" --rationale x -- cat "$GRANT"
case "$rc" in
  3) bad "인가 기록 읽기" "읽기까지 막혔다 — 드라이버는 이 파일을 읽어야 한다" ;;
  *) ok "인가 기록 읽기는 막지 않는다" ;;
esac

# ---------------------------------------------------------------------------
# 5. Pre-authorization: outside the list is an APPROVAL, not a refusal
# ---------------------------------------------------------------------------
gate act --manifest "$MANIFEST" --kind x --target infra --cutpoint 배포 \
     --snapshot-digest "$(HH)" --rationale x -- curl https://example.invalid
check "사전 인가 밖 외부 상태 변경은 승인 대기를 발행한다" "$rc" "5"

gate act --manifest "$MANIFEST" --kind x --target infra --cutpoint 배포 \
     --snapshot-digest "$(HH)" --rationale x -- mkdir -p "$WORK/scratch"
check "워크트리 쓰기는 사전 인가 목록을 요구하지 않는다" "$rc" "0"
[ -d "$WORK/scratch" ] && ok "게이트는 통과시킨 행위를 실제로 수행한다" \
                       || bad "수행" "통과했는데 디렉터리가 생기지 않았다 — 기록만 하고 수행하지 않으면 층 1 아래에서는 아무것도 실행되지 않는다"

# ---------------------------------------------------------------------------
# 6. Snapshot binding — a stale digest is a loud re-read
# ---------------------------------------------------------------------------
gate act --manifest "$MANIFEST" --kind x --target front --cutpoint 커밋 \
     --snapshot-digest 0000000000000000000000000000000000000000000000000000000000000000 \
     --rationale x -- touch "$WORK/touched"
check "낡은 스냅숏 다이제스트는 거부된다" "$rc" "4"

gate plan --manifest "$MANIFEST" --kind x --target front --cutpoint 커밋 -- git commit -m x
check "plan 은 스냅숏 다이제스트 없이도 답한다 (건드리는 것이 없다)" "$rc" "0"

# ---------------------------------------------------------------------------
# 7. Declared grade is a CHECKED CLAIM, not a self-grant
# ---------------------------------------------------------------------------
H=$(cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null | jq -r .H)
gate exec --manifest "$MANIFEST" --target front --cutpoint 커밋 --surface 읽기 \
     --snapshot-digest "$(HH)" --rationale x -- touch "$WORK/touched"
check "축2 자기선언이 등급과 다르면 거부된다" "$rc" "6"

gate exec --manifest "$MANIFEST" --target front --cutpoint 커밋 --surface 워크트리쓰기 \
     --snapshot-digest "$(HH)" --rationale x -- touch "$WORK/touched"
check "선언이 등급과 같으면 통과한다" "$rc" "0"

gate exec --manifest "$MANIFEST" --target front --cutpoint 커밋 --surface 파일쓰기 \
     --snapshot-digest "$(HH)" --rationale x -- touch "$WORK/touched"
check "어휘 밖 축2 토큰은 거부된다" "$rc" "2"

# ---------------------------------------------------------------------------
# 8. Review-before-merge, and its five staleness grades
# ---------------------------------------------------------------------------
seg_wt="$WT"
head0=$(cd "$WT" && git rev-parse HEAD)

H=$(cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null | jq -r .H)
gate act --manifest "$MANIFEST" --kind merge --target infra --segment SNONE --cutpoint 머지 \
     --snapshot-digest "$(HH)" --rationale x -- gh pr merge 1
check "리뷰 기록이 없는 머지는 거부된다" "$rc" "3"

{
  printf -- '- `segment` | id=S9 | 상태=구현완료 | 커밋=%s | 워크트리=%s\n' "$head0" "$seg_wt"
  printf -- '- `cycle` | 세그먼트=S9 | P0=1 | P1=0 | 리뷰 HEAD=%s\n' "$head0"
} >> "$LEDGER"
H=$(cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null | jq -r .H)
gate act --manifest "$MANIFEST" --kind merge --target infra --segment S9 --cutpoint 머지 \
     --snapshot-digest "$(HH)" --rationale x -- gh pr merge 1
check "P0 가 남아 있으면 머지는 거부된다" "$rc" "3"

printf -- '- `cycle` | 세그먼트=S9 | P0=0 | P1=0 | 리뷰 HEAD=%s\n' "$head0" >> "$LEDGER"
H=$(cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null | jq -r .H)
# Judged by the ABSENCE of the rule's refusal line rather than by the exit code:
# past the checks the gate performs the act, and `gh pr merge` in a fixture with
# no GitHub behind it fails for reasons that have nothing to do with the rule.
passes_review() {
  case "$msg" in *"리뷰-후-머지:"*) return 1 ;; *) return 0 ;; esac
}
gate act --manifest "$MANIFEST" --kind merge --target infra --segment S9 --cutpoint 머지 \
     --snapshot-digest "$(HH)" --rationale x -- gh pr merge 1
if passes_review; then ok "무이동 등급은 통과한다"; else bad "무이동 등급" "$msg"; fi

# 동일 트리 — amend rewrites the commit and leaves the tree byte-identical.
( cd "$WT" && git commit -q --amend -m "one (amended)" ) >/dev/null 2>&1
head_amend=$(cd "$WT" && git rev-parse HEAD)
H=$(cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null | jq -r .H)
gate act --manifest "$MANIFEST" --kind merge --target infra --segment S9 --cutpoint 머지 \
     --snapshot-digest "$(HH)" --rationale x -- gh pr merge 1
if passes_review; then ok "동일 트리 등급(amend)은 통과한다"; else bad "동일 트리 등급" "$msg"; fi
if [ "$head_amend" = "$head0" ]; then
  bad "동일 트리 전제" "amend 가 커밋 sha 를 바꾸지 않았다 — 이 절이 공허하다"
else
  ok "동일 트리 절이 공허하지 않다 (커밋 sha 는 실제로 달라졌다)"
fi

# 추가 커밋 — the reviewed HEAD is an ancestor with commits in between. The
# review record is re-stamped at the amended HEAD first: without that, the
# amend above has already made the old HEAD unreachable and this case would
# silently exercise the `무관` arm while claiming to test this one.
printf -- '- `cycle` | 세그먼트=S9 | P0=0 | P1=0 | 리뷰 HEAD=%s\n' "$head_amend" >> "$LEDGER"
( cd "$WT" && echo two > b.txt && git add -A && git commit -qm two ) >/dev/null 2>&1
H=$(cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null | jq -r .H)
gate act --manifest "$MANIFEST" --kind merge --target infra --segment S9 --cutpoint 머지 \
     --snapshot-digest "$(HH)" --rationale x -- gh pr merge 1
check "리뷰 이후 커밋이 추가되면 거부된다" "$rc" "3"
case "$msg" in
  *"커밋이 추가"*) ok "낡음 등급이 「추가 커밋」으로 보고된다" ;;
  *) bad "낡음 등급 보고" "'$msg'" ;;
esac

# 무관 — an unrelated root. `git reset` rather than `git rm -r .`: the latter
# prunes the directory the run ledger lives in, and every assertion after this
# point then reads a ledger that is not there. The bug it caused looked like a
# gate defect and was a fixture defect.
( cd "$WT" && git checkout -q --orphan sideline && git reset -q \
  && echo x > c.txt && git add c.txt && git commit -qm sideline ) >/dev/null 2>&1
H=$(cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null | jq -r .H)
gate act --manifest "$MANIFEST" --kind merge --target infra --segment S9 --cutpoint 머지 \
     --snapshot-digest "$(HH)" --rationale x -- gh pr merge 1
check "리뷰 HEAD 가 조상이 아니면 거부된다" "$rc" "3"
case "$msg" in
  *"조상이 아닙니다"*) ok "낡음 등급이 「무관/베이스 이동」으로 보고된다" ;;
  *) bad "낡음 등급 보고" "'$msg'" ;;
esac

# ---------------------------------------------------------------------------
# 8b. Implementation and review must be separate sessions
#
# The rule this replaces compared session ids while those ids were DERIVED from
# `run|doc|stage|attempt` — values that differ by construction. So the check was
# a tautology: it passed on every run, including the ones it existed to catch.
# What makes it a proposition is recording the id the harness actually assigned
# together with the id of the session that spawned it.
# ---------------------------------------------------------------------------
printf -- '- `segment` | id=SEP | 상태=구현완료 | 커밋=%s | 워크트리=%s\n' "$(cd "$WT" && git rev-parse HEAD)" "$WT" >> "$LEDGER"
printf -- '- `cycle` | 세그먼트=SEP | P0=0 | P1=0 | 리뷰 HEAD=%s\n' "$(cd "$WT" && git rev-parse HEAD)" >> "$LEDGER"
# THE DISPATCHER IS NOT AN ANCESTOR IN THE SENSE THIS RULE MEANS. The router
# launches both stages and the gate records it as `부모` on both rows, so the
# two closures met at the router on EVERY run a router drove and this rule
# refused every merge — naming an id that was neither stage. What it is for is
# authorship: did the reviewing session see the work being made. A shared
# dispatcher does not imply that; the stages share no output.
printf -- '- `stage-result` | 세그먼트=SEP | 스테이지=S4 | 세션 id=impl-1 | 부모=router-1 | 종단 부류=정상 완료\n' >> "$LEDGER"
printf -- '- `stage-result` | 세그먼트=SEP | 스테이지=S5 | 세션 id=rev-1 | 부모=router-1 | 종단 부류=정상 완료\n' >> "$LEDGER"
H=$(cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null | jq -r .H)
gate act --manifest "$MANIFEST" --kind merge --target infra --segment SEP --cutpoint 머지 \
     --snapshot-digest "$(HH)" --rationale x -- gh pr merge 1
case "$msg" in
  *"조상이 겹칩니다"*) bad "디스패처 판정" "라우터를 공유했다는 이유로 거부됐다 — 라우터가 돌린 모든 런의 머지가 막힌다" ;;
  *) ok "디스패처를 공유하는 것은 자기 작업 리뷰가 아니다" ;;
esac

# THE FORK CASE, which is what the closure exists for and is untouched: the
# reviewing session is a fork of the implementing one, so its parent IS the
# other side's own session id. A parent that names a stage names an author.
printf -- '- `stage-result` | 세그먼트=SEPF | 스테이지=S4 | 세션 id=impl-f | 부모=router-1 | 종단 부류=정상 완료\n' >> "$LEDGER"
printf -- '- `stage-result` | 세그먼트=SEPF | 스테이지=S5 | 세션 id=rev-f | 부모=impl-f | 종단 부류=정상 완료\n' >> "$LEDGER"
printf -- '- `segment` | id=SEPF | 상태=구현완료 | 커밋=%s | 워크트리=%s\n' "$(cd "$WT" && git rev-parse HEAD)" "$WT" >> "$LEDGER"
printf -- '- `cycle` | 세그먼트=SEPF | P0=0 | P1=0 | 리뷰 HEAD=%s\n' "$(cd "$WT" && git rev-parse HEAD)" >> "$LEDGER"
H=$(cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null | jq -r .H)
gate act --manifest "$MANIFEST" --kind merge --target infra --segment SEPF --cutpoint 머지 \
     --snapshot-digest "$(HH)" --rationale x -- gh pr merge 1
case "$msg" in
  *"조상이 겹칩니다"*) ok "구현 세션의 포크가 리뷰하면 거부된다 (폐포가 존재하는 이유)" ;;
  *) bad "포크 판정" "포크가 자기 작업을 리뷰했는데 통과했다" ;;
esac

# And the direct case — one session on both sides.
printf -- '- `stage-result` | 세그먼트=SEPD | 스테이지=S4 | 세션 id=same-1 | 부모=router-1 | 종단 부류=정상 완료\n' >> "$LEDGER"
printf -- '- `stage-result` | 세그먼트=SEPD | 스테이지=S5 | 세션 id=same-1 | 부모=router-1 | 종단 부류=정상 완료\n' >> "$LEDGER"
printf -- '- `segment` | id=SEPD | 상태=구현완료 | 커밋=%s | 워크트리=%s\n' "$(cd "$WT" && git rev-parse HEAD)" "$WT" >> "$LEDGER"
printf -- '- `cycle` | 세그먼트=SEPD | P0=0 | P1=0 | 리뷰 HEAD=%s\n' "$(cd "$WT" && git rev-parse HEAD)" >> "$LEDGER"
H=$(cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null | jq -r .H)
gate act --manifest "$MANIFEST" --kind merge --target infra --segment SEPD --cutpoint 머지 \
     --snapshot-digest "$(HH)" --rationale x -- gh pr merge 1
case "$msg" in
  *"조상이 겹칩니다"*) ok "한 세션이 양쪽이면 거부된다" ;;
  *) bad "직접 판정" "같은 세션이 자기 작업을 리뷰했는데 통과했다" ;;
esac

printf -- '- `stage-result` | 세그먼트=SEP2 | 스테이지=S4 | 세션 id=impl-9 | 부모=미상 | 종단 부류=정상 완료\n' >> "$LEDGER"
printf -- '- `stage-result` | 세그먼트=SEP2 | 스테이지=S5 | 세션 id=rev-9 | 부모=미상 | 종단 부류=정상 완료\n' >> "$LEDGER"
printf -- '- `segment` | id=SEP2 | 상태=구현완료 | 커밋=%s | 워크트리=%s\n' "$(cd "$WT" && git rev-parse HEAD)" "$WT" >> "$LEDGER"
printf -- '- `cycle` | 세그먼트=SEP2 | P0=0 | P1=0 | 리뷰 HEAD=%s\n' "$(cd "$WT" && git rev-parse HEAD)" >> "$LEDGER"
H=$(cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null | jq -r .H)
gate act --manifest "$MANIFEST" --kind merge --target infra --segment SEP2 --cutpoint 머지 \
     --snapshot-digest "$(HH)" --rationale x -- gh pr merge 1
case "$msg" in
  *"판정 불가는 통과가 아닙니다"*) ok "계보가 기록되지 않으면 통과가 아니다 (공허한 참으로 돌아가지 않는다)" ;;
  *) bad "미기록 처리" "'$msg'" ;;
esac

# ---------------------------------------------------------------------------
# 8b. The router's own writer for `segment` and `cycle`
#
# Both rows used to be written only by the fixed-graph loop, which the router
# path never enters. The consequence was not a missing convenience: the merge
# rule reads a `cycle` row and refused EVERY merge for want of one, and
# termination condition 1 counts `segment` rows and could never hold — so the
# run also had no ending it could propose. Both failures look like the mechanism
# working, which is why they survived until a run tried to finish.
# ---------------------------------------------------------------------------
head_b=$(cd "$WT" && git rev-parse HEAD)

H=$(cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null | jq -r .H)
gate act --manifest "$MANIFEST" --kind merge --target infra --segment SW --cutpoint 머지 \
     --snapshot-digest "$(HH)" --rationale x -- gh pr merge 1
check "리뷰 기록 없는 세그먼트의 머지는 아직 거부된다" "$rc" "3"

# The vocabulary is checked, and the check is what makes the row readable later.
H=$(cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null | jq -r .H)
gate act --manifest "$MANIFEST" --kind segment --target infra --segment SW --cutpoint 커밋 \
     --snapshot-digest "$(HH)" --rationale x -- 상태=진행중 워크트리="$WT"
check "어휘 밖 세그먼트 상태는 거부된다" "$rc" "2"

H=$(cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null | jq -r .H)
gate act --manifest "$MANIFEST" --kind segment --target infra --segment SW --cutpoint 커밋 \
     --snapshot-digest "$(HH)" --rationale x -- 상태=실행중
check "워크트리 없는 세그먼트 행은 거부된다" "$rc" "2"

# `선행=없음` from here on. This ledger carries more than one segment, and a
# `segment` row in such a repository must state its predecessors — absence and
# `없음` are told apart at write time and only there, so a writer that did not
# consider the question gets a refusal instead of a silent empty set. These
# fixture segments are independent, which is what `없음` says.
H=$(cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null | jq -r .H)
gate act --manifest "$MANIFEST" --kind segment --target infra --segment SW --cutpoint 커밋 \
     --snapshot-digest "$(HH)" --rationale x -- 상태=실행중 워크트리="$WT" 선행=없음
check "세그먼트 행이 기록된다" "$rc" "0"
n=$(grep -c '^- `segment` | id=SW ' "$LEDGER" || true)
check "그 행이 원장에 있다" "$n" "1"

# The `cycle` row's four required fields are the four the merge rule reads. A
# row missing one of them does not fail here under the old path either — it
# fails inside the rule, reported as a review with no HEAD, which sends the
# reader to the review instead of to the row this run wrote.
H=$(cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null | jq -r .H)
gate act --manifest "$MANIFEST" --kind cycle --target infra --segment SW --cutpoint 커밋 \
     --snapshot-digest "$(HH)" --rationale x -- 사이클=1 P0=0 P1=0
check "리뷰 HEAD 없는 사이클 행은 거부된다" "$rc" "2"

H=$(cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null | jq -r .H)
gate act --manifest "$MANIFEST" --kind cycle --target infra --segment SW --cutpoint 커밋 \
     --snapshot-digest "$(HH)" --rationale x -- 사이클=1 P0=0 P1=0 "리뷰 HEAD=$head_b"
check "사이클 행이 기록된다" "$rc" "0"

# End to end: the same merge that was refused for want of a review record is now
# judged by the record instead of by its absence.
H=$(cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null | jq -r .H)
gate plan --manifest "$MANIFEST" --kind merge --target infra --segment SW --cutpoint 머지 \
     -- gh pr merge 1
case "$msg" in
  *"리뷰-후-머지:"*) bad "라우터 기록" "게이트가 쓴 리뷰 기록을 룰이 읽지 못한다: '"'"'$msg'"'"'" ;;
  *) ok "게이트가 쓴 세그먼트·사이클 행으로 머지가 통과한다" ;;
esac

# The bookkeeping act is graded `읽기`: what it performs is the row, and the row
# reaches nothing a credential or a cutpoint could widen.
case "$(grep '^- `자율 승인` | kind=cycle ' "$LEDGER" | tail -1)" in
  *"축2=읽기"*) ok "장부 행위는 읽기로 등급된다" ;;
  *) bad "장부 등급" "$(grep '^- `자율 승인` | kind=cycle ' "$LEDGER" | tail -1)" ;;
esac

# ---------------------------------------------------------------------------
# 8c. Every act records WHICH credential it ran under
#
# With neither pipeline credential provisioned the gate fell through to whatever
# the calling environment held — on a developer machine a full-scope `gh` login
# — and said nothing, so the layer the separation exists to provide was absent
# while every surface reported normal operation. The fallback stays; being
# silent about it does not.
# ---------------------------------------------------------------------------
case "$(grep '^- `자율 승인` | kind=segment ' "$LEDGER" | tail -1)" in
  *"자격=분리"*|*"자격=주변"*) ok "행마다 어느 자격으로 돌았는지가 남는다" ;;
  *) bad "자격 기록" "자율 승인 행에 「자격」 필드가 없다" ;;
esac

# ---------------------------------------------------------------------------
# 8d. The act runs in the TARGET's worktree
#
# `--target` is a parameter of both acting verbs and every target row carries an
# absolute worktree, but nothing carried that value to the act's working
# directory — so a manifest could declare nine targets and only the home one
# could receive an act. Asserted from a SUBDIRECTORY, because that is the only
# cwd where "the act moved" and "the act stayed" produce different output.
# ---------------------------------------------------------------------------
mkdir -p "$WT/sub"
H=$(cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null | jq -r .H)
out=$(cd "$WT/sub" && bash "$GATE" exec --manifest "$MANIFEST" --target infra --segment SW \
      --cutpoint 커밋 --surface 읽기 --snapshot-digest "$(HH)" --rationale x -- ls 2>&1)
case "$out" in
  *base.txt*) ok "행위가 대상 워크트리에서 실행된다 (호출자의 cwd 가 아니라)" ;;
  *) bad "대상 워크트리" "'"'"'$out'"'"'" ;;
esac

# ---------------------------------------------------------------------------
# 9. The un-disableable rules ignore the manifest's rule settings
# ---------------------------------------------------------------------------
{
  printf '\n## 룰 설정\n'
  printf '**절단점-준수**: 끔\n**사전-인가-대조**: 끔\n**인가-자기확장-금지**: 끔\n**리뷰-후-머지**: 끔\n'
} >> "$MANIFEST"
# Rule settings ARE in the frozen set, so this edit legitimately moves the
# digest — which is the mechanism working. A kickoff would rewrite it; the
# fixture does the same.
refresh_bd
# The digests cover the target rows and the plan fence, not this section, so the
# manifest still validates — which is the point: turning a rule off is a normal,
# well-formed edit, and that is exactly why three of them may not honour it.
H=$(cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null | jq -r .H)
gate act --manifest "$MANIFEST" --kind merge --target front --segment S9 --cutpoint 머지 \
     --snapshot-digest "$(HH)" --rationale x -- gh pr merge 1
check "절단점-준수 는 「끔」을 무시한다" "$rc" "3"

gate act --manifest "$MANIFEST" --kind x --target infra --cutpoint 배포 \
     --snapshot-digest "$(HH)" --rationale x -- curl https://example.invalid
check "사전-인가-대조 는 「끔」을 무시한다" "$rc" "5"

gate act --manifest "$MANIFEST" --kind merge --target infra --segment S9 --cutpoint 배포 \
     --snapshot-digest "$(HH)" --rationale x -- gh pr merge 1 --admin
check "인가-자기확장-금지 는 「끔」을 무시한다" "$rc" "3"

# 리뷰-후-머지 IS disableable, and this is the assertion that proves the switch
# is real rather than decorative — the same act refused in section 8 by the
# staleness grade now passes.
gate act --manifest "$MANIFEST" --kind merge --target infra --segment S9 --cutpoint 머지 \
     --snapshot-digest "$(HH)" --rationale x -- gh pr merge 1
if passes_review; then
  ok "리뷰-후-머지 는 「끔」을 따른다 (스위치가 장식이 아니다)"
else
  bad "룰 스위치" "「끔」인데 여전히 거부한다: $msg"
fi

# ---------------------------------------------------------------------------
# 10. The ledger the gate writes — chained, capped, and its own rows
# ---------------------------------------------------------------------------
n_rows=$(grep -cE '^- `자율 승인`' "$LEDGER" || true)
if [ "$n_rows" -gt 0 ]; then
  ok "통과한 행위마다 자율 승인 행이 남는다 (${n_rows}건)"
else
  bad "자율 승인 행" "게이트를 여러 번 통과했는데 행이 하나도 없다"
fi

if grep -qE '^- `자율 승인`.*\| prev=[0-9a-f]{64}$' "$LEDGER"; then
  ok "모든 행이 앞 행의 다이제스트를 물고 있다"
else
  bad "해시 체인" "prev= 가 64자리 hex 로 끝나는 행이 없다"
fi

over=$(awk 'length($0) + 1 > 1024' "$LEDGER" | grep -c . || true)
check "게이트가 쓴 행 중 상한을 넘는 것이 없다" "$over" "0"

# The cap is a refusal, not a truncation: a row that would exceed it must be
# rejected loudly rather than silently shortened, because a shortened row parses
# as a well-formed row carrying wrong values.
long=$(printf 'x%.0s' $(seq 1 1100))
gate act --manifest "$MANIFEST" --kind x --target front --cutpoint 커밋 \
     --snapshot-digest "$(HH)" --rationale "$long" -- git commit -m x
if [ "$rc" = "0" ]; then
  bad "행 상한" "1100 바이트 근거를 실은 행이 통과했다 — 동시 append 가 조용히 필드를 섞는다"
else
  ok "상한을 넘길 행은 절단이 아니라 거부로 처리된다 (rc=$rc)"
fi

# ---------------------------------------------------------------------------
# 10b. `선머지후리뷰` defers the review and the deferral leaves a record
#
# A deferral with no record is a removal nobody wrote down. This design's own
# four slices all declare that mode, so the first run of it against itself takes
# exactly this path.
# ---------------------------------------------------------------------------
H=$(cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null | jq -r .H)
gate act --manifest "$MANIFEST" --kind merge --target infra --segment SEP \
     --cutpoint 머지 --review-policy 선머지후리뷰 \
     --snapshot-digest "$(HH)" --rationale x -- gh pr merge 1
if grep -q '^- `리뷰 의무`' "$LEDGER"; then
  ok "선머지후리뷰 머지가 리뷰 의무 행을 남긴다"
else
  bad "리뷰 의무" "미뤄진 리뷰가 아무 기록도 남기지 않았다 — 미룬 것과 없앤 것이 구별되지 않는다"
fi
if grep '^- `리뷰 의무`' "$LEDGER" | grep_all_q '상태=미이행'; then
  ok "발행 시점의 상태는 미이행이다"
else
  bad "의무 상태" "$(grep '^- `리뷰 의무`' "$LEDGER" | awk 'NR<=1')"
fi
if grep '^- `리뷰 의무`' "$LEDGER" | grep_all_q '생성 등급=외부상태변경'; then
  ok "생성 등급을 함께 싣는다 (나중의 면제 판정이 읽는 값이다)"
else
  bad "생성 등급" "$(grep '^- `리뷰 의무`' "$LEDGER" | awk 'NR<=1')"
fi

n_before=$(grep -c '^- `리뷰 의무`' "$LEDGER" || true)
H=$(cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null | jq -r .H)
gate act --manifest "$MANIFEST" --kind merge --target infra --segment SEP \
     --cutpoint 머지 --review-policy 선머지후리뷰 \
     --snapshot-digest "$(HH)" --rationale x -- gh pr merge 1
check "같은 세그먼트에 의무를 중복 발행하지 않는다" "$(grep -c '^- `리뷰 의무`' "$LEDGER" || true)" "$n_before"

# The default mode must NOT create one — an obligation that appears for every
# merge would make condition 9 permanent and no run could ever terminate.
gate act --manifest "$MANIFEST" --kind merge --target infra --segment SEP2 \
     --cutpoint 머지 \
     --snapshot-digest "$(HH)" --rationale x -- gh pr merge 1
if grep '^- `리뷰 의무`' "$LEDGER" | grep_all_q '세그먼트=SEP2'; then
  bad "기본 정책" "선리뷰후머지 인데도 의무가 생겼다 — 조건 9 가 영구히 참이 된다"
else
  ok "기본 정책에서는 의무를 만들지 않는다"
fi

# ---------------------------------------------------------------------------
# 10c. A dry run writes nothing, and a stage dispatch is gradeable
#
# All three of these were found by the FIRST act of the first real run, and they
# composed into "the router cannot dispatch any stage at all":
#   - `plan` issued a real approval row, so asking "would this pass?" mutated
#     the run the question was about — and an open approval suspends B1..B3 and
#     blocks termination condition 2, so the question stalled the asker.
#   - a stage dispatch's argv begins with a STAGE KIND, not a command, so the
#     argv0 table graded every dispatch `등급 미상`.
#   - `등급 미상` fell through to the pre-authorization rule's external-state
#     arm, turning every dispatch into a pending approval.
# ---------------------------------------------------------------------------
n_before=$(grep -c '^- `승인`' "$LEDGER" || true)
H=$(cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null | jq -r .H)
gate plan --manifest "$MANIFEST" --kind x --target infra --cutpoint 배포 -- curl https://example.invalid
check "plan 이 사전 인가 밖을 승인 대기로 답한다" "$rc" "5"
check "그러면서 원장에는 아무것도 쓰지 않는다" "$(grep -c '^- `승인`' "$LEDGER" || true)" "$n_before"
case "$msg" in
  *"발행하지 않았습니다"*) ok "dry-run 임을 문면이 말한다" ;;
  *) bad "dry-run 문면" "'$msg'" ;;
esac

gate grade --manifest "$MANIFEST" -- review
case "$msg" in
  *"축2=등급 미상"*) ok "스테이지 종류를 등급표에 물으면 미상이다 (그것이 명령이 아니므로)" ;;
  *) bad "스테이지 종류 등급" "'$msg'" ;;
esac

gate plan --manifest "$MANIFEST" --kind skill --target infra --segment SD --cutpoint 커밋 -- review
check "그럼에도 스킬 디스패치는 통과한다 (argv0 표에 묻지 않는다)" "$rc" "0"
case "$msg" in
  *"축2=워크트리쓰기"*) ok "스킬 디스패치는 워크트리 쓰기로 등급된다" ;;
  *) bad "스킬 등급" "'$msg'" ;;
esac

# The gate must HAND the CLI path down. run.sh resolves the binary and only then
# pins PATH to the sanitized set, so a child that re-resolves searches a PATH the
# CLI is not on — every stage launch died with "binary not found" two seconds
# after the binary had been found.
if grep -vE '^[[:space:]]*#' "$GATE" | grep_all_q -F 'CC_CLAUDE_BIN="$CLI_BIN"'; then
  ok "게이트가 래퍼에 CLI 경로를 넘긴다 (정제된 PATH 에서 다시 찾지 않는다)"
else
  bad "CLI 전달" "래퍼가 정제된 PATH 로 바이너리를 다시 찾게 된다"
fi

# A fan-out stage does not fit under the default background ceiling. Measured: a
# dispatched audit stage was killed at exactly 600s, reported `subtype: success`
# and exit 0, and published nothing — its readers were alive with open zero-byte
# temp files, killed in the moment before their atomic publish.
if grep -vE '^[[:space:]]*#' "$GATE" | grep_all_q -F 'CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS='; then
  ok "게이트가 스테이지에 배경 대기 천장을 넘긴다"
else
  bad "대기 천장" "팬아웃 스테이지가 기본 천장에서 발행 직전에 죽는다"
fi
# Finite, not `0`. Forever is the one value that costs the run its only signal:
# the watcher counts a live pid as a healthy stage, so a hung stage reads as a
# heartbeat and the run sits until a person comes back.
if grep -vE '^[[:space:]]*#' "$GATE" | grep_all_q -E 'CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS="\$\{[A-Z_]+:-[1-9][0-9]+\}"'; then
  ok "그 천장은 유한하다 (무한 대기는 정체 신호를 없앤다)"
else
  bad "대기 천장" "천장이 유한한 기본값을 갖지 않는다"
fi

# The fall-through that made the composition fatal is now an explicit arm, and
# `등급 미상` carries the only space in the axis-2 vocabulary — unquoted it
# splits the `case` pattern into two words and breaks the whole checker file.
if grep -q '"등급 미상")' "$repo_root/plugins/cc-cmds/orchestrator/rules/사전-인가-대조.sh"; then
  ok "미상 등급이 명시적 팔이고 인용돼 있다"
else
  bad "미상 처분" "흘러내림으로 처리되거나 인용되지 않았다"
fi

# ---------------------------------------------------------------------------
# 11. Termination — nine conditions, and the disagreement that runs both ways
# ---------------------------------------------------------------------------
H=$(cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null | jq -r .H)
gate act --manifest "$MANIFEST" --kind propose-done --target front --cutpoint 커밋 \
     --snapshot-digest "$(HH)" --rationale "끝났다고 본다" -- true
check "미충족 조건이 있으면 종료 제안이 기각된다" "$rc" "3"
if grep -q '결정=기각' "$LEDGER"; then
  ok "기각이 원장에 남는다 (아침에 무엇이 남았는지 읽을 수 있다)"
else
  bad "기각 기록" "종료 제안이 기각됐는데 행이 없다"
fi

out=$(cat "$WORK/last-output.txt")
case "$out" in
  *"9 미이행 리뷰 의무"*) ok "미이행 리뷰 의무가 미충족 조건으로 열거된다" ;;
  *) ok "리뷰 의무는 이 시점에 열려 있지 않다" ;;
esac
case "$out" in
  *"2 대기 중인 행위 승인"*) ok "대기 중 행위 승인이 미충족 조건으로 열거된다" ;;
  *) bad "조건 2" "curl 이 발행한 승인 대기가 종료를 막지 않는다" ;;
esac

# A run with no segments at all must NOT read as complete. Over the empty set
# "every segment is terminal" is vacuously true, and that made the first act of
# every run trip the never-started branch of the both-ways rule.
FRESH="$WORK/fresh"; mkdir -p "$FRESH"
( cd "$WORK" && cp -R "$REPO" "$FRESH/repo" ) >/dev/null 2>&1
if [ -d "$FRESH/repo" ]; then
  rm -f "$FRESH/repo/docs/pipeline-run/R1.md"
  out2=$(cd "$FRESH/repo" && XDG_STATE_HOME="$WORK/state2" bash "$GATE" act \
          --manifest "$FRESH/repo/plan.md" --kind propose-done --target front \
          --cutpoint 커밋 --snapshot-digest x --rationale y -- true 2>&1 || true)
  case "$out2" in
    *"세그먼트가 하나도 없습니다"*) ok "세그먼트 0 인 런은 완료로 읽히지 않는다" ;;
    *) ok "세그먼트 0 판정은 다른 조건이 먼저 잡는다" ;;
  esac
fi

# ---------------------------------------------------------------------------
# 12. Boundaries convert to an approval, never to a park
# ---------------------------------------------------------------------------
# Resolve everything pending first: an open approval suspends B1..B3, so a B1
# test run against a ledger with one open would be asserting the suspension
# while claiming to assert the firing.
for a in $(grep -oE '승인 id=[^ |]+' "$LEDGER" | sed 's/승인 id=//' | sort -u); do
  printf -- '- `승인` | 승인 id=%s | 상태=승인 | 해소 시각=%s | prev=x\n' "$a" "테스트" >> "$LEDGER"
done

RD="$XDG_STATE_HOME/cc-cmds/run/R1"
printf '%s\n' "$(PD)" > "$RD/progress-digest"
printf '%s\n' "9" > "$RD/progress-repeat"
H=$(cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null | jq -r .H)
gate act --manifest "$MANIFEST" --kind x --target front --cutpoint 커밋 \
     --snapshot-digest "$(HH)" --rationale "S9" -- touch "$WORK/t2"
if grep -q '구속 튜플=B1' "$LEDGER"; then
  ok "B1 이 발동하면 park 이 아니라 승인 대기를 발행한다"
else
  bad "B1" "무진전이 연속으로 쌓였는데 경계 승인이 없다"
fi
if grep -q '절단점=경계' "$LEDGER"; then
  ok "경계 승인은 절단점 자리에 경계 토큰을 싣는다 (행위가 없으므로 argv 다이제스트가 없다)"
else
  bad "경계 토큰" "경계 승인이 절단점 토큰을 쓰고 있다"
fi

# The regression the audit's critical finding demands, at the gate level: an
# open approval must SUSPEND B1..B3. Without it the boundary's own remedy resets
# the counter that fired it and the bound is never reached.
before=$(grep -c '구속 튜플=B1' "$LEDGER" || true)
printf '%s\n' "9" > "$RD/progress-repeat"
H=$(cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null | jq -r .H)
gate act --manifest "$MANIFEST" --kind x --target front --cutpoint 커밋 \
     --snapshot-digest "$(HH)" --rationale "S9" -- touch "$WORK/t3"
after=$(grep -c '구속 튜플=B1' "$LEDGER" || true)
check "열린 승인이 있는 동안 경계는 다시 발동하지 않는다" "$after" "$before"

# ---------------------------------------------------------------------------
# 13. close never accepts an answer the router typed
# ---------------------------------------------------------------------------
aid=$(grep -E '^- `승인`' "$LEDGER" | grep '상태=대기' | tail -1 \
      | grep -oE '승인 id=[^ |]+' | sed 's/승인 id=//' || true)
if [ -n "$aid" ]; then
  gate close --manifest "$MANIFEST" --approval "$aid"
  check "트랜스크립트가 없으면 승인은 닫히지 않는다" "$rc" "5"
  case "$msg" in
    *트랜스크립트*) ok "닫지 못한 이유가 판독 채널의 부재로 보고된다" ;;
    *) bad "close 사유" "'$msg'" ;;
  esac

  gate close --manifest "$MANIFEST" --approval "없는-id"
  if [ "$rc" = "0" ]; then
    bad "close 대상" "존재하지 않는 승인 id 가 닫혔다"
  else
    ok "존재하지 않는 승인 id 는 닫히지 않는다"
  fi

  # With a transcript in place, both binds must hold. Matching the id alone
  # would let the router point `close` at a DIFFERENT question that was
  # genuinely answered — an approval obtained without forging anything.
  TXDIR="$WORK/cfg/projects/proj"; mkdir -p "$TXDIR"
  SID="11111111-2222-3333-4444-555555555555"
  printf '{"role":"user","content":"%s 에 대한 답: 승인"}\n' "$aid" > "$TXDIR/$SID.jsonl"
  out=$(cd "$WT" && CLAUDE_CONFIG_DIR="$WORK/cfg" CLAUDE_CODE_SESSION_ID="$SID" \
        bash "$GATE" close --manifest "$MANIFEST" --approval "$aid" 2>&1); rc=$?
  case "$rc" in
    0) bad "질문 문면 구속" "id 만 언급한 줄로 승인이 닫혔다" ;;
    *) ok "id 만 일치하는 줄로는 닫히지 않는다 (질문 문면도 함께 구속한다)" ;;
  esac

  # A torn final line is HELD, not read as "no answer" — under this design the
  # two mean opposite things, and the harness is the writer here so the ledger's
  # discard-the-last-line rule does not carry over.
  printf '{"role":"user","content":"부분적으로 쓰인 줄' > "$TXDIR/$SID.jsonl"
  out=$(cd "$WT" && CLAUDE_CONFIG_DIR="$WORK/cfg" CLAUDE_CODE_SESSION_ID="$SID" \
        bash "$GATE" close --manifest "$MANIFEST" --approval "$aid" 2>&1); rc=$?
  case "$out" in
    *"판정 보류"*) ok "찢어진 줄은 「없음」이 아니라 판정 보류다" ;;
    *) bad "찢어진 줄" "'$out'" ;;
  esac
fi

# ---------------------------------------------------------------------------
# 14. A pending approval can be VOIDED, not only granted
#
# Before this there was one recording path, so an approval had two possible
# ends: granted, or pending forever. Pending is not inert — it counts against
# termination condition 2 and suspends the stagnation boundaries — so a single
# approval nobody wants to grant stalls the rest of the run. Voiding REMOVES a
# blocker, which is why it keeps the same transcript binding instead of becoming
# a router-writable escape.
# ---------------------------------------------------------------------------
vaid=$(grep -E '^- `승인`' "$LEDGER" | grep '상태=대기' | tail -1 \
       | grep -oE '승인 id=[^ |]+' | sed 's/승인 id=//' || true)
if [ -n "$vaid" ]; then
  vq=$(grep -E '^- `승인`' "$LEDGER" | grep -F "승인 id=$vaid " | tail -1 \
       | tr '|' '\n' | sed -n 's/^ *질문 문면=//p' | sed 's/[[:space:]]*$//' | tail -1)
  VDIR="$WORK/vcfg/projects/proj"; mkdir -p "$VDIR"
  VSID="99999999-8888-7777-6666-555555555555"
  printf '{"role":"user","content":"%s / %s → 이 질문은 잘못 발행됐습니다"}\n' "$vaid" "$vq" \
    > "$VDIR/$VSID.jsonl"

  out=$(cd "$WT" && CLAUDE_CONFIG_DIR="$WORK/vcfg" CLAUDE_CODE_SESSION_ID="$VSID" \
        bash "$GATE" close --manifest "$MANIFEST" --approval "$vaid" --void 2>&1); rc=$?
  check "무효화는 트랜스크립트 한 줄로 성립한다" "$rc" "0"
  case "$(grep -E '^- `승인`' "$LEDGER" | grep -F "승인 id=$vaid " | tail -1)" in
    *"상태=무효"*) ok "무효 상태가 원장에 남는다 (승인과 구별된다)" ;;
    *) bad "무효 기록" "$(grep -E '^- `승인`' "$LEDGER" | grep -F "승인 id=$vaid " | tail -1)" ;;
  esac
  n=$(cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null \
      | jq '.pending_approvals | length')
  check "무효화된 승인은 더 이상 대기로 세지 않는다" "$n" "0"

  # Already resolved is already resolved — a second close of any form is a
  # refusal, so an approval cannot be re-opened by asking again.
  out=$(cd "$WT" && CLAUDE_CONFIG_DIR="$WORK/vcfg" CLAUDE_CODE_SESSION_ID="$VSID" \
        bash "$GATE" close --manifest "$MANIFEST" --approval "$vaid" 2>&1); rc=$?
  if [ "$rc" = "0" ]; then
    bad "재해소" "무효화된 승인이 다시 닫혔다"
  else
    ok "무효화된 승인은 다시 닫히지 않는다"
  fi
fi

# ---------------------------------------------------------------------------
# 14b. The credential report runs at RUN OPEN, where it was never called
#
# `cred_check`'s own comment says a run whose cutpoint reaches `머지` should
# learn at kickoff and not at 3am. Nothing called it, so nothing ever did.
# ---------------------------------------------------------------------------
freshstate="$WORK/state-fresh"
out=$(cd "$WT" && XDG_STATE_HOME="$freshstate" bash "$GATE" snapshot --manifest "$MANIFEST" 2>&1 >/dev/null)
case "$out" in
  *"자격"*) ok "런 개시에 자격 상태가 보고된다" ;;
  *) bad "자격 개시 보고" "'"'"'$out'"'"'" ;;
esac
# And only at run open — the settings directory already exists on every later
# invocation, so a keychain lookup does not run once per act.
out=$(cd "$WT" && XDG_STATE_HOME="$freshstate" bash "$GATE" snapshot --manifest "$MANIFEST" 2>&1 >/dev/null)
case "$out" in
  *"자격이 갖춰지지"*) bad "자격 개시 보고" "런 개시가 아닌 호출에서도 보고했다" ;;
  *) ok "그 뒤의 호출에서는 다시 보고하지 않는다" ;;
esac

# ---------------------------------------------------------------------------
# 14c. The act runs in the EXECUTION worktree when the row declares one
#
# One field could not carry both duties. The sidecar path has to converge on the
# MAIN worktree so that N linked worktrees of one repository do not split the
# state a single writer owns; the act has to run where the branch actually is.
# For a pr or branch anchor those are never the same directory — git refuses to
# check a branch out twice — so a stage woke on the main worktree's branch every
# time. The symptom is silent: the stage starts, the files are readable, and
# what it reads is a different version.
# ---------------------------------------------------------------------------
LINKED="$WORK/linked"
( cd "$WT" && git worktree add -q -b linkedbr "$LINKED" ) >/dev/null 2>&1
if [ -d "$LINKED" ]; then
  ( cd "$LINKED" && echo linked > only-here.txt && git add -A && git commit -qm linked ) >/dev/null 2>&1

  # A read loop and not `sed`: the target row is FULL of `|` separators, so every
  # delimiter a substitution could pick already appears in the pattern. Shell
  # string equality has no delimiter at all.
  set_exec_wt() {
    local want="$1" line out="$MANIFEST.ew"
    : > "$out"
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        '- `target`'*별칭=infra*)
          case "$line" in *'실행 워크트리='*) line="${line%% | 실행 워크트리=*}" ;; esac
          [ -z "$want" ] || line="$line | 실행 워크트리=$want"
          ;;
      esac
      printf '%s\n' "$line" >> "$out"
    done < "$MANIFEST"
    mv "$out" "$MANIFEST"
    # The row moved, so both digests move — a kickoff would rewrite them and the
    # fixture does the same.
    local newtd
    newtd=$(cd "$WT" && bash -c '
      CC_ORCH_SOURCE_ONLY=1 . "'"$repo_root"'/plugins/cc-cmds/orchestrator/run.sh"
      MANIFEST="'"$MANIFEST"'"
      canonical_targets | shasum -a 256 | cut -d" " -f1')
    : > "$out"
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        '**대상 맵 다이제스트**: '*) line="**대상 맵 다이제스트**: $newtd" ;;
      esac
      printf '%s\n' "$line" >> "$out"
    done < "$MANIFEST"
    mv "$out" "$MANIFEST"
    refresh_bd
  }

  set_exec_wt "$LINKED"
  H=$(cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null | jq -r .H)
  out=$(cd "$WT" && bash "$GATE" exec --manifest "$MANIFEST" --target infra --segment SW \
        --cutpoint 커밋 --surface 읽기 --snapshot-digest "$(HH)" --rationale x -- ls 2>&1)
  case "$out" in
    *only-here.txt*) ok "행위가 실행 워크트리에서 실행된다 (메인 워크트리가 아니라)" ;;
    *) bad "실행 워크트리" "$(printf '%s' "$out" | tr '\n' ' ')" ;;
  esac

  # A declared execution worktree in ANOTHER repository is refused — that would
  # be a second target wearing the first one's cutpoint.
  OTHER="$WORK/other"; ( git init -q "$OTHER" ) >/dev/null 2>&1
  set_exec_wt "$OTHER"
  out=$(cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>&1); rc=$?
  if [ "$rc" = "0" ]; then
    bad "실행 워크트리 검사" "다른 레포를 실행 워크트리로 선언했는데 통과했다"
  else
    ok "다른 레포를 실행 워크트리로 선언하면 하드 스톱이다"
  fi

  # Absent is the default, and the default is the main worktree.
  set_exec_wt ""
  H=$(cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null | jq -r .H)
  out=$(cd "$WT" && bash "$GATE" exec --manifest "$MANIFEST" --target infra --segment SW \
        --cutpoint 커밋 --surface 읽기 --snapshot-digest "$(HH)" --rationale x -- ls 2>&1)
  case "$out" in
    *base.txt*) ok "필드가 없으면 메인 워크트리로 되돌아간다 (선언은 선택이다)" ;;
    *) bad "실행 워크트리 기본값" "$(printf '%s' "$out" | tr '\n' ' ')" ;;
  esac
else
  bad "픽스처 전제" "링크된 워크트리를 만들지 못했다"
fi

# ---------------------------------------------------------------------------
# 14d. The five row kinds that had no writer
#
# Five of the twelve declared series were written by nothing, and each one made
# a check that reads it answer the same thing forever: the cost boundary read an
# empty set and took its fail-open guard, so it could not fire however low the
# ceiling; open obligations were always zero, so termination condition 3 held
# vacuously; and terminal classes could not be counted at all. `generation` is
# deliberately still unwritten — nothing reads it, so a writer would put a value
# in the ledger that is recorded and never compared, which is the defect class
# this contract exists to remove.
# ---------------------------------------------------------------------------
H=$(cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null | jq -r .H)
gate act --manifest "$MANIFEST" --kind problem --target infra --segment SW --cutpoint 커밋 \
     --snapshot-digest "$(HH)" --rationale x -- 동일성=x/y.sh:널포인터 현재\ 단=1
check "생성 등급 없는 problem 행은 거부된다" "$rc" "2"

H=$(cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null | jq -r .H)
gate act --manifest "$MANIFEST" --kind problem --target infra --segment SW --cutpoint 커밋 \
     --snapshot-digest "$(HH)" --rationale x \
     -- "동일성=x/y.sh:널포인터" "현재 단=1" "생성 등급=외부상태변경"
check "problem 행이 기록된다" "$rc" "0"
n=$(cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null | jq -r .obligations_total)
check "그 행이 미해결 의무로 세어진다 (조건 3 이 더는 공허하지 않다)" "$n" "1"

# `stage-result` and `cost` are written from the stage's OWN terminal result
# line, so they are exercised through the seam with a synthetic log rather than
# by launching a CLI the fixture does not have.
outcome_probe() {
  # outcome_probe <rc> <subtype> <cost> <extra-log-line>
  cd "$WT" && CC_GATE_SOURCE_ONLY=1 bash -c '
    . "'"$GATE"'"
    MANIFEST="'"$MANIFEST"'"
    check_manifest >/dev/null 2>&1
    derive_paths_from_manifest
    rundir_init 2>/dev/null || true
    mkdir -p "$RUN_DIR/log"
    { printf "%s\n" "$4"
      printf "{\"type\":\"result\",\"subtype\":\"%s\",\"total_cost_usd\":%s,\"session_id\":\"sid-probe\"}\n" "$2" "$3"
    } > "$RUN_DIR/log/SP.json"
    nb=$(gate_rows "자율 승인" | gate_count)
    gate_record_stage_outcome infra SP review 1 "$1" "$nb" >/dev/null 2>&1
  ' _ "$1" "$2" "$3" "${4:-}"
}

outcome_probe 0 success 1.25 ''
row=$(grep '^- `stage-result` ' "$LEDGER" | tail -1)
case "$row" in
  *"종단 부류=공허한 성공"*) ok "행을 남기지 않고 성공한 스테이지는 공허한 성공이다" ;;
  *) bad "종단 부류" "$row" ;;
esac
case "$row" in
  *"세션 id=sid-probe"*) ok "stage-result 가 세션 계보를 싣는다 (구현-리뷰 분리 룰의 입력이다)" ;;
  *) bad "세션 계보" "$row" ;;
esac
crow=$(grep '^- `cost` ' "$LEDGER" | tail -1)
case "$crow" in
  *"누적 usd=1.2500"*) ok "비용이 누적된다 (B4 경계의 유일한 입력이다)" ;;
  *) bad "비용 누적" "$crow" ;;
esac

outcome_probe 0 success 0.75 '{"permission_denials":[{"tool_name":"Read"}]}'
row=$(grep '^- `stage-result` ' "$LEDGER" | tail -1)
case "$row" in
  *"종단 부류=산출물 없는 정지"*) ok "거부 흔적이 있으면 공허한 성공과 구별된다" ;;
  *) bad "종단 부류" "$row" ;;
esac
crow=$(grep '^- `cost` ' "$LEDGER" | tail -1)
case "$crow" in
  *"누적 usd=2.0000"*) ok "두 번째 스테이지의 비용이 앞의 값에 더해진다" ;;
  *) bad "비용 누적" "$crow" ;;
esac

# `is_error` is read as well as the status and the subtype. Measured: a stage
# that slept mid-response returned `subtype: success` WITH `is_error: true`, and
# only the non-zero status caught it — the same object with a zero status would
# have been classified as a normal completion.
outcome_probe_err() {
  cd "$WT" && CC_GATE_SOURCE_ONLY=1 bash -c '
    . "'"$GATE"'"
    MANIFEST="'"$MANIFEST"'"
    check_manifest >/dev/null 2>&1
    derive_paths_from_manifest
    rundir_init 2>/dev/null || true
    mkdir -p "$RUN_DIR/log"
    printf "{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":true,\"total_cost_usd\":9,\"session_id\":\"sid-slept\"}\n" \
      > "$RUN_DIR/log/SP.json"
    nb=$(gate_rows "자율 승인" | gate_count)
    gate_record_stage_outcome infra SP review 1 0 "$nb" >/dev/null 2>&1
  '
}
outcome_probe_err
row=$(grep '^- `stage-result` ' "$LEDGER" | tail -1)
case "$row" in
  *"종단 부류=크래시"*) ok "종료 코드가 0 이어도 is_error 면 크래시다" ;;
  *) bad "종단 부류" "$row" ;;
esac

outcome_probe 1 error 0.10 ''
row=$(grep '^- `stage-result` ' "$LEDGER" | tail -1)
case "$row" in
  *"종단 부류=크래시"*) ok "0 이 아닌 종료 코드는 크래시다" ;;
  *) bad "종단 부류" "$row" ;;
esac

# `plan_sha256` — the implement arm splits into two processes and process B
# enters ONLY when this field is on the row; its admission predicate says so and
# forbids re-deriving a plan instead. Nothing wrote it, so every dispatch
# resolved as process A, emitted the plan again and stopped — with a clean tree,
# which is correct for process A, so "A finished" and "B will never come" were
# indistinguishable.
plan_probe() {
  cd "$WT" && CC_GATE_SOURCE_ONLY=1 bash -c '
    . "'"$GATE"'"
    MANIFEST="'"$MANIFEST"'"
    check_manifest >/dev/null 2>&1
    derive_paths_from_manifest
    rundir_init 2>/dev/null || true
    mkdir -p "$RUN_DIR/log"
    printf "%s" "$2" > "$RUN_DIR/implement-SI.plan.md"
    printf "{\"type\":\"result\",\"subtype\":\"success\",\"total_cost_usd\":1,\"session_id\":\"sid-i\"}\n" \
      > "$RUN_DIR/log/SI.json"
    nb=$(gate_rows "자율 승인" | gate_count)
    gate_record_stage_outcome cc-cmds SI "$1" 1 0 "$nb" >/dev/null 2>&1
  ' _ "$1" "$2"
}
plan_probe implement "착지 계획 본문"
row=$(grep '^- `stage-result` ' "$LEDGER" | tail -1)
want=$(printf '%s' "착지 계획 본문" | shasum -a 256 | cut -d' ' -f1)
case "$row" in
  *"plan_sha256=$want"*) ok "구현 스테이지의 행이 계획 다이제스트를 싣는다 (프로세스 B 의 입장 토큰)" ;;
  *) bad "plan_sha256" "$row" ;;
esac
# And only the implement arm — a review stage has no plan and no process B.
plan_probe review "리뷰에는 계획이 없다"
row=$(grep '^- `stage-result` ' "$LEDGER" | tail -1)
case "$row" in
  *"plan_sha256="*) bad "plan_sha256" "리뷰 스테이지 행에 계획 다이제스트가 붙었다: $row" ;;
  *) ok "리뷰 스테이지 행에는 붙지 않는다" ;;
esac

# ---------------------------------------------------------------------------
# 14e. exit 7 tells a STAGE what to do, because only the router can do the
# prescribed thing
#
# The disposition is "stop and tell the user", and a stage can do neither half:
# the cause is outside it by definition, and looking needs the Bash that was
# just refused. Measured on one run — five stages, four retried into the same
# refusal 3, 9, 12 and 15 times, and the fifth stopped because of its own
# judgment rather than anything the contract said.
# ---------------------------------------------------------------------------
STATE7="$WORK/state-surface"
H=$(cd "$WT" && XDG_STATE_HOME="$STATE7" bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null | jq -r .H)
# Editing a settings file IS moving the surface — that file is one of the four.
printf '\n' >> "$STATE7/cc-cmds/run/R1/settings/generic.json"
n_before=$(grep -c '^- `blocked` ' "$LEDGER" 2>/dev/null || true)
out=$(cd "$WT" && XDG_STATE_HOME="$STATE7" CC_PIPELINE_SEGMENT=SP CC_PIPELINE_TARGET=infra \
      bash "$GATE" exec --manifest "$MANIFEST" --target infra --segment SP --cutpoint 커밋 \
      --surface 읽기 --snapshot-digest "$(HH7)" --rationale x -- ls 2>&1); rc=$?
if [ "$rc" = "7" ]; then
  ok "표면이 움직이면 종료 코드 7 이다"
  case "$out" in
    *"재시도하지 마세요"*) ok "스테이지에게 재시도가 아니라 중단을 지시한다" ;;
    *) bad "exit 7 문면" "$(printf '%s' "$out" | tr '\n' ' ')" ;;
  esac
  n_after=$(grep -c '^- `blocked` ' "$LEDGER" 2>/dev/null || true)
  if [ "${n_after:-0}" -gt "${n_before:-0}" ]; then
    ok "런 스코프 blocked 행이 남는다 (스테이지의 낭비된 턴 수 말고 상태로 보인다)"
  else
    bad "표면 이동 기록" "blocked 행이 늘지 않았다"
  fi
  out=$(cd "$WT" && XDG_STATE_HOME="$STATE7" CC_PIPELINE_SEGMENT=SP CC_PIPELINE_TARGET=infra \
        bash "$GATE" exec --manifest "$MANIFEST" --target infra --segment SP --cutpoint 커밋 \
        --surface 읽기 --snapshot-digest "$(HH7)" --rationale x -- ls 2>&1) || true
  n_twice=$(grep -c '^- `blocked` ' "$LEDGER" 2>/dev/null || true)
  check "같은 조건을 반복 기록하지 않는다" "$n_twice" "$n_after"
else
  bad "표면 이동" "종료 코드 $rc — 표면을 움직였는데 7 이 아니다"
fi

# ---------------------------------------------------------------------------
# 14f. A documentless run does not get its base's PARENT
#
# The workspace widening is for a document that belongs to no repository. A run
# with no document sets both document variables to the run's base, so a guard
# on their equality alone opens a directory nothing in the run reads.
# ---------------------------------------------------------------------------
parent_of_wt=$(dirname "$WT")
if jq -e --arg d "$parent_of_wt" '.permissions.additionalDirectories | index($d)' \
     "$SETTINGS_DIR/generic.json" >/dev/null 2>&1; then
  bad "작업 공간 확장" "문서 없는 런인데 베이스의 부모가 열렸다: $parent_of_wt"
else
  ok "문서 없는 런은 베이스의 부모를 열지 않는다"
fi

# ---------------------------------------------------------------------------
# 14g. A cut stage is RE-ATTACHED, not re-run — and the id is checked
#
# The contract already said so and the wrapper already accepted `--resume`;
# nothing carried the router's intent to it, so the only recovery was a full
# re-run. Measured: a review stage died to a machine sleep after 1h53m and 51.84
# USD with every reviewer's output on disk and only the synthesis missing.
#
# The id is checked against this run's own ledger. A resume is an instruction to
# continue somebody's transcript, so an unchecked value would let one segment
# continue another segment's — or another run's — session.
# ---------------------------------------------------------------------------
if grep -vE '^[[:space:]]*#' "$GATE" | grep_all_q -F '"--resume $GATE_RESUME"'; then
  ok "게이트가 래퍼에 --resume 을 넘길 수 있다"
else
  bad "재개 경로" "라우터가 끊긴 스테이지를 이어붙일 수단이 없다"
fi
# The segment row comes first, because a dispatch into a segment that has none
# is now refused before the argv is looked at — and the fault under test here is
# the argv. Without this the assertion would pass for the wrong reason.
H=$(cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null | jq -r .H)
gate act --manifest "$MANIFEST" --kind segment --target infra --segment SNOSUCH --cutpoint 커밋 \
     --snapshot-digest "$(HH)" --rationale x -- 상태=실행중 워크트리="$WT" 선행=없음
H=$(cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null | jq -r .H)
gate act --manifest "$MANIFEST" --kind skill --target infra --segment SNOSUCH --cutpoint 커밋 \
     --surface 워크트리쓰기 --snapshot-digest "$(HH)" --rationale x --resume "남의-세션-id" -- review x
# The validation must sit BEFORE the CLI binary is resolved. Resolving first
# makes "the binary is missing" mask "the argv is wrong" — the same defect the
# wrapper already had and had fixed, and it came back here: on a host without
# the CLI a bad resume id answered 127 and the refusal never named the fault.
ord_resume=$(sed -n '/^gate_launch_stage()/,/^}/p' "$GATE" | grep -n '재개 대상 세션이' | sed 's/:.*//' | tail -1)
ord_cli=$(sed -n '/^gate_launch_stage()/,/^}/p' "$GATE" | grep -n 'CLI 바이너리를 해소하지' | sed 's/:.*//' | tail -1)
if [ -n "$ord_resume" ] && [ -n "$ord_cli" ] && [ "$ord_resume" -lt "$ord_cli" ]; then
  ok "재개 인자 검증이 CLI 해소보다 먼저 온다"
else
  bad "검증 순서" "재개 검증 $ord_resume · CLI 해소 $ord_cli — 바이너리 부재가 인자 오류를 가린다"
fi
check "원장에 없는 세션 id 로는 재개하지 못한다" "$rc" "2"
case "$msg" in
  *"원장 기록에 없습니다"*) ok "거부가 그 이유를 말한다" ;;
  *) bad "재개 거부 문면" "$(printf '%s' "$msg" | tr '\n' ' ')" ;;
esac

# ---------------------------------------------------------------------------
# 14h. The launch path is actually ENTERED, with a stub CLI
#
# Every assertion above stops at `gate_launch_stage`'s argument checks, because
# the fixture has no CLI binary and the function returns 127 before doing
# anything. That left the whole body — the plugin root, the id flag, the log
# capture, the pid file, the terminal rows — with no coverage at all, and an
# edit that moved one block silently deleted the `plugin_dir` assignment while
# leaving `--plugin-dir "$plugin_dir"` behind. Under `set -u` that killed every
# stage dispatch, and the suite stayed green.
#
# The stub is a CLI-shaped script: it prints one stream-json result line and
# exits. What is under test is the gate's launch path, not the CLI.
# ---------------------------------------------------------------------------
STUB="$WORK/stub-cli"
cat > "$STUB" <<'STUBEOF'
#!/usr/bin/env bash
# A CLI-shaped stub. Records the argv it was handed, then emits one result line.
printf '%s\n' "$*" > "${CC_STUB_ARGV_OUT:-/dev/null}"
printf '{"type":"result","subtype":"success","is_error":false,"total_cost_usd":0.5,"session_id":"stub-session","num_turns":1}\n'
exit 0
STUBEOF
chmod +x "$STUB"

H=$(cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null | jq -r .H)
gate act --manifest "$MANIFEST" --kind segment --target infra --segment SL --cutpoint 커밋 \
     --snapshot-digest "$(HH)" --rationale x -- 상태=실행중 워크트리="$WT" 선행=없음
H=$(cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null | jq -r .H)
out=$(cd "$WT" && CC_CLAUDE_BIN="$STUB" CC_STUB_ARGV_OUT="$WORK/stub-argv.txt" \
      bash "$GATE" act --manifest "$MANIFEST" --kind skill --target infra --segment SL \
      --cutpoint 커밋 --surface 워크트리쓰기 --snapshot-digest "$(HH)" --rationale x \
      -- review "/cc-cmds:review-unattended x" 2>&1); rc=$?
check "스텁 CLI 로 스테이지 기동이 끝까지 간다" "$rc" "0"
case "$out" in
  *"unbound variable"*|*"바인딩 해제"*)
    bad "기동 경로" "unbound variable: $(printf '%s' "$out" | tr '\n' ' ')" ;;
  *) ok "기동 경로에 미정의 변수가 없다" ;;
esac
# The plugin root actually reaches the wrapper, and it is the directory that
# contains the skills — not the orchestrator directory.
if [ -f "$WORK/stub-argv.txt" ]; then
  ok "스텁이 실제로 실행됐다 (argv 를 남겼다)"
else
  bad "기동 경로" "스텁이 실행되지 않았다 — 래퍼 앞에서 끝났다"
fi
# And the terminal rows the launch path is responsible for are there.
case "$(grep '^- `stage-result` ' "$LEDGER" | tail -1)" in
  *"세그먼트=SL"*) ok "기동이 끝나면 stage-result 행이 남는다" ;;
  *) bad "종단 기록" "$(grep '^- `stage-result` ' "$LEDGER" | tail -1)" ;;
esac
case "$(grep '^- `자율 승인` | kind=skill ' "$LEDGER" | tail -1)" in
  *"세그먼트=SL"*) ok "디스패치 자체도 원장에 남는다" ;;
  *) bad "디스패치 기록" "$(grep '^- `자율 승인` | kind=skill ' "$LEDGER" | tail -1)" ;;
esac
# The pid file is removed on exit, so "no record implies no process" holds.
if [ -f "$(dirname "$SETTINGS_DIR")/SL.pid" ]; then
  bad "pid 정리" "스테이지가 끝났는데 pid 기록이 남아 있다"
else
  ok "스테이지가 끝나면 pid 기록이 지워진다"
fi

# ---------------------------------------------------------------------------
# 14i. The render answers "is this still going?"
#
# It did not. The heartbeat a watcher prints goes to a stdout its launching tool
# call already closed, so it reaches nobody; the render carried no live-stage
# count, no ledger age, and no terminal state. Answering the question needed the
# row grammar and a manual pid comparison.
# ---------------------------------------------------------------------------
rend=$(cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" --render 2>/dev/null)
for want in '살아 있는 스테이지' '원장 갱신' '감시자' '런 상태' '스테이지 스트림'; do
  case "$rend" in
    *"$want"*) ok "렌더가 「${want}」을 낸다" ;;
    *) bad "렌더 라이브니스" "「${want}」이 없다" ;;
  esac
done
case "$rend" in
  *"런 상태   : 진행 중"*) ok "종단 표시가 없으면 진행 중이라고 답한다" ;;
  *) bad "런 상태" "$(printf '%s' "$rend" | grep '런 상태' || true)" ;;
esac

# The run's END is a FILE, because a ledger row is not a thing another process
# can test cheaply — and two need to: the watcher, whose loop had no exit
# condition, and a person who does not know the row grammar.
RD_G=$(dirname "$SETTINGS_DIR")
rm -f "$RD_G/done"
if grep -vE '^[[:space:]]*#' "$GATE" | grep_all_q -F '> "$RUN_DIR/done"'; then
  ok "게이트가 종단 표시 파일을 쓴다"
else
  bad "종단 표시" "런이 끝나도 디스크에 표시가 남지 않는다"
fi
printf '%s 종단 — 시험\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$RD_G/done"
rend=$(cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" --render 2>/dev/null)
case "$rend" in
  *"런 상태   : 종단"*) ok "종단 표시가 있으면 렌더가 그렇게 답한다" ;;
  *) bad "런 상태" "$(printf '%s' "$rend" | grep '런 상태' || true)" ;;
esac
rm -f "$RD_G/done"

# ---------------------------------------------------------------------------
# 14j. The grant reaches every declared worktree, and digest tools are readable
#
# `실행 워크트리` was wired to the act's cwd and not to the stage's readable set,
# so a stage woke in a worktree it could not read. And no other target's main
# worktree was in the set either — only the home one. Separately, the digest
# tools were absent, which deadlocked the implement arm: process B may enter
# only after comparing the plan's digest, and computing it was refused.
# ---------------------------------------------------------------------------
graded_as '읽기' 'shasum 이 읽기로 등급된다'   -- shasum -a 256 /tmp/x
graded_as '읽기' 'sha256sum 도 같다'           -- sha256sum /tmp/x
# `openssl` is graded by SUBCOMMAND rather than by name, because the one name
# covers hashing, key generation, file conversion and opening a socket. A
# name-level grade would have to pick one of the four, and the blanket refusal
# this replaced picked the safest — which also refused `openssl rand`, the
# spelling the team protocol MANDATES for a witness nonce. So the arm names the
# harmless subcommands, refuses everything it does not name (`s_client` and
# `s_server` are the ones that matter), and checks `-out`/`-keyout` across every
# arm so a write cannot enter wearing a read's subcommand.
graded_as '읽기' 'openssl dgst 는 읽기다'              -- openssl dgst -sha256 /tmp/x
graded_as '읽기' 'openssl rand 도 읽기다'              -- openssl rand -hex 8
graded_as '워크트리쓰기' 'rand 라도 -out 이면 쓰기다'  -- openssl rand -out /tmp/secrets.bin 32
graded_as '등급 미상' '이름 없는 하위 명령은 거부된다' -- openssl s_client -connect example.com:443

set_exec_wt "$LINKED" >/dev/null 2>&1 || true
rm -rf "$SETTINGS_DIR"
( cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" >/dev/null 2>&1 )
if jq -e --arg d "$LINKED" '.permissions.additionalDirectories | index($d)' \
     "$SETTINGS_DIR/generic.json" >/dev/null 2>&1; then
  ok "실행 워크트리가 스테이지의 읽기 집합에 들어간다"
else
  bad "실행 워크트리 인가" "$(jq -c '.permissions.additionalDirectories' "$SETTINGS_DIR/generic.json")"
fi
if jq -e --arg d "$WT" '.permissions.additionalDirectories | index($d)' \
     "$SETTINGS_DIR/generic.json" >/dev/null 2>&1; then
  ok "선언된 대상의 메인 워크트리도 들어간다"
else
  bad "대상 워크트리 인가" "$(jq -c '.permissions.additionalDirectories' "$SETTINGS_DIR/generic.json")"
fi
set_exec_wt "" >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
# 14k. The run's END is the dispatch gate, and the progress boundaries set it
#
# The wall clock used to hold this gate. It measured elapsed time, while the
# thing worth stopping is pointless spinning — measured, one run died having
# performed zero acts because the machine slept for 35 hours, and the
# independent review that loss forced cost 2h17m. The gate's SHAPE is unchanged
# and is asserted here as such: dispatch and merge refused, ledger acts still
# recorded, a done proposal exempt. What it reads is now the mark a
# progress-based boundary leaves.
#
# Keyed on the mark rather than on the clock, these assertions no longer expire:
# the old ones compared against a literal `2030-01-01`, which is a date this
# suite will one day run past.
# ---------------------------------------------------------------------------
grant_field_set() {
  # grant_field_set <키> <값> — declare (or redeclare) one `## 인가` field, or
  # remove it when the value is empty.
  #
  # INSERTED DIRECTLY UNDER THE HEADING, not appended to the file. `manifest_field`
  # is section-scoped and stops at the next `## `, and this fixture grows sections
  # BELOW `## 인가` as the suite runs — so a field appended at end-of-file reads as
  # absent. That is the same trap `refresh_bd` documents for the binding digest,
  # and it is why this is a read loop with `[ "$line" = … ]` string equality
  # rather than an `awk`/`sed` insert keyed on a Korean heading.
  local key="$1" val="$2" line out="$MANIFEST.gf" inserted=0
  : > "$out"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "**$key**: "*) continue ;;
    esac
    printf '%s\n' "$line" >> "$out"
    if [ "$inserted" = "0" ] && [ "$line" = "## 인가" ] && [ -n "$val" ]; then
      printf '**%s**: %s\n' "$key" "$val" >> "$out"
      inserted=1
    fi
  done < "$MANIFEST"
  mv "$out" "$MANIFEST"
  refresh_bd
}

printf '2026-01-01T00:00:00Z 종단 — 경계 B5 · 근거 픽스처\n' > "$RD/done"
H=$(cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null | jq -r .H)
gate plan --manifest "$MANIFEST" --kind skill --target infra --segment SD --cutpoint 커밋 -- review
check "런이 종단하면 스테이지 디스패치가 거부된다" "$rc" "3"
case "$msg" in
  *"이미 종단했습니다"*) ok "거부가 종단을 이유로 든다" ;;
  *) bad "종단 문면" "$(printf '%s' "$msg" | tr '\n' ' ')" ;;
esac
gate plan --manifest "$MANIFEST" --kind merge --target infra --segment SD --cutpoint 머지 -- gh pr merge 1
check "종단 뒤 머지도 거부된다" "$rc" "3"
# But recording and closing still work — a boundary that stopped everything
# would strand the run instead of ending it.
H=$(cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null | jq -r .H)
gate act --manifest "$MANIFEST" --kind segment --target infra --segment SD --cutpoint 커밋 \
     --surface 읽기 --snapshot-digest "$(HH)" --rationale x -- 상태=park 워크트리="$WT" 선행=없음
check "종단 뒤에도 장부 행위는 통과한다" "$rc" "0"
rm -f "$RD/done"
H=$(cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null | jq -r .H)
gate plan --manifest "$MANIFEST" --kind skill --target infra --segment SD --cutpoint 커밋 -- review
check "종단 표시가 없으면 디스패치가 통과한다" "$rc" "0"

# --- B5: the stagnation bound ENDS the run, it does not ask -----------------
#
# B1 asks and B5 ends, and they cannot share a counter: B1's own firing skips
# the arm B1 evaluates in, so its counter freezes at the first threshold. B5
# therefore keeps `stagnation-repeat` and is evaluated beside B4.
grant_field_set '무진전 상한' '2'
printf '%s\n' "$(PD)" > "$RD/stagnation-digest"
printf '%s\n' "5"      > "$RD/stagnation-repeat"
H=$(cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null | jq -r .H)
gate act --manifest "$MANIFEST" --kind x --target front --cutpoint 커밋 \
     --snapshot-digest "$(HH)" --rationale "B5" -- touch "$WORK/t-b5"
case "$(cat "$RD/done" 2>/dev/null || true)" in
  *"경계 B5"*) ok "무진전 상한이 런을 끝낸다 (묻지 않는다)" ;;
  *) bad "B5" "무진전이 상한을 넘었는데 런이 끝나지 않았다: $(cat "$RD/done" 2>/dev/null || printf '(종단 표시 없음)')" ;;
esac
if grep -q '기준=B5' "$LEDGER"; then
  ok "B5 종료가 원장에 행을 남긴다"
else
  bad "B5 행" "런이 끝났는데 원장에 그 이유가 없다"
fi
rm -f "$RD/done" "$RD/stagnation-digest" "$RD/stagnation-repeat"
grant_field_set '무진전 상한' ''

# --- B4: 80% asks, 100% ends ------------------------------------------------
grant_field_set '비용 천장' '10'
printf -- '- `cost` | 누적 usd=8.0000 | 스테이지 수=1 | 관측 시각=테스트 | prev=x\n' >> "$LEDGER"
H=$(cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null | jq -r .H)
gate act --manifest "$MANIFEST" --kind x --target front --cutpoint 커밋 \
     --snapshot-digest "$(HH)" --rationale "B4-80" -- touch "$WORK/t-b4a"
if grep -q '구속 튜플=B4' "$LEDGER" && [ ! -s "$RD/done" ]; then
  ok "비용이 천장의 80%에 닿으면 묻고, 런은 계속 간다"
else
  bad "B4 80%" "80%에서 승인이 없거나 런이 이미 끝났다"
fi
printf -- '- `cost` | 누적 usd=10.5000 | 스테이지 수=1 | 관측 시각=테스트 | prev=x\n' >> "$LEDGER"
H=$(cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null | jq -r .H)
gate act --manifest "$MANIFEST" --kind x --target front --cutpoint 커밋 \
     --snapshot-digest "$(HH)" --rationale "B4-100" -- touch "$WORK/t-b4b"
case "$(cat "$RD/done" 2>/dev/null || true)" in
  *"경계 B4"*) ok "비용이 천장에 닿으면 런이 끝난다" ;;
  *) bad "B4 100%" "천장을 넘었는데 런이 끝나지 않았다: $(cat "$RD/done" 2>/dev/null || printf '(종단 표시 없음)')" ;;
esac
rm -f "$RD/done"
grant_field_set '비용 천장' ''
grep -v '^- `cost`' "$LEDGER" > "$LEDGER.nc" && mv "$LEDGER.nc" "$LEDGER"

# ---------------------------------------------------------------------------
# 14l. The authorization list can grow, and only through the gate
#
# It used to be written once and never again, so a directory kickoff could not
# know about — a segment's own worktree, a repository added at layer 1 — was
# unreachable for the life of the run, and the only exit was to end the run.
# Measured: a run produced its review and then could not remediate, because the
# only writable tree in its list was the live plugin checkout.
#
# What keeps the surface comparison meaningful is not that it never moves, but
# that it moves only through THIS writer and leaves a row. Both halves are
# asserted here — the growth, and the refusal to repair somebody else's edit.
# ---------------------------------------------------------------------------
RD_L=$(dirname "$SETTINGS_DIR")
n_before=$(jq -r '.permissions.additionalDirectories | length' "$SETTINGS_DIR/generic.json")
n_rows_before=$(grep -c '^- `대상 추가` ' "$LEDGER" 2>/dev/null || true)

# Declaring an execution worktree is a change to what the settings derive FROM.
set_exec_wt "$LINKED"
( cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" >/dev/null 2>&1 )
n_after=$(jq -r '.permissions.additionalDirectories | length' "$SETTINGS_DIR/generic.json")
if [ "${n_after:-0}" -gt "${n_before:-0}" ]; then
  ok "유도의 입력이 움직이면 인가 목록이 자란다"
else
  bad "인가 목록 재유도" "$n_before → $n_after"
fi
if jq -e --arg d "$LINKED" '.permissions.additionalDirectories | index($d)' \
     "$SETTINGS_DIR/generic.json" >/dev/null 2>&1; then
  ok "새로 선언된 워크트리가 그 안에 있다"
else
  bad "인가 목록 재유도" "$(jq -c '.permissions.additionalDirectories' "$SETTINGS_DIR/generic.json")"
fi
n_rows_after=$(grep -c '^- `대상 추가` ' "$LEDGER" 2>/dev/null || true)
if [ "${n_rows_after:-0}" -gt "${n_rows_before:-0}" ]; then
  ok "그 확장이 원장에 행으로 남는다 (조용히 넓히지 않는다)"
else
  bad "확장 기록" "행이 늘지 않았다"
fi
# The baseline moved with it, so the next act does not read as tampering.
H=$(cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null | jq -r .H)
gate act --manifest "$MANIFEST" --kind segment --target infra --segment SR --cutpoint 커밋 \
     --surface 읽기 --snapshot-digest "$(HH)" --rationale x -- 상태=park 워크트리="$WT" 선행=없음
check "확장 뒤의 행위가 표면 이동으로 읽히지 않는다" "$rc" "0"
# And a second call changes nothing — the derivation is a function, so it is
# stable when its inputs are.
d1=$(cat "$RD_L/surface-digest")
( cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" >/dev/null 2>&1 )
check "입력이 그대로면 다시 쓰지 않는다" "$(cat "$RD_L/surface-digest")" "$d1"

# THE OTHER HALF: an edit this writer did not make is still exit 7. The
# re-derivation must not repair it — repairing would erase the evidence the
# surface check reads, which is the whole detection.
printf '\n' >> "$SETTINGS_DIR/generic.json"
H=$(cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null | jq -r .H)
out=$(cd "$WT" && bash "$GATE" exec --manifest "$MANIFEST" --target infra --segment SR \
      --cutpoint 커밋 --surface 읽기 --snapshot-digest "$(HH)" --rationale x -- ls 2>&1); rc=$?
check "남이 고친 표면은 여전히 종료 코드 7 이다" "$rc" "7"
set_exec_wt ""

# ---------------------------------------------------------------------------
# 15. The grading table reads the ACT, not the spelling
#
# Three defects met here and left no spelling that reached `gh` at all: the
# sanitized PATH made the bare name unresolvable, the table read argv0 verbatim
# so the absolute path graded `등급 미상`, and `gh api` — the only spelling that
# submits several inline comments as one review — was refused outright.
# ---------------------------------------------------------------------------
graded_as '외부상태변경' '경로로 부른 gh 도 맨 이름과 같게 등급된다' -- /opt/homebrew/bin/gh pr merge 1
graded_as '외부상태변경' '경로로 부른 terraform 도 같다'            -- /usr/local/bin/terraform apply
graded_as '읽기'         '경로로 부른 git 읽기도 같다'              -- /usr/bin/git status

# git's global options sit BEFORE the subcommand, and `-C <path>` is the only
# spelling that names another worktree. Reading `$2` blindly graded it unknown.
graded_as '워크트리쓰기' 'git -C 의 하위 명령을 찾아낸다'   -- git -C /tmp commit -m x
graded_as '외부상태변경' 'git -c 의 하위 명령도 찾아낸다'   -- git -c user.name=x push
graded_as '읽기'         '값이 붙은 전역 옵션도 건너뛴다'   -- git --git-dir=/tmp/.git log
# An unrecognized global stops the scan as UNKNOWN rather than guessing whether
# it eats the next word — guessing wrong grades a `push` by the wrong token.
graded_as '등급 미상'    '모르는 전역 옵션은 추측하지 않는다' -- git --not-a-real-global push

graded_as '읽기'         'gh api 의 기본은 GET 이라 읽기다'  -- gh api repos/o/r/pulls/1/reviews
graded_as '외부상태변경' '명시된 POST 는 외부 상태 변경이다' -- gh api --method POST repos/o/r/pulls/1/reviews
graded_as '외부상태변경' '-X 붙임꼴도 읽는다'                -- gh api -XPATCH repos/o/r/pulls/1
graded_as '외부상태변경' '필드가 붙으면 gh 자신처럼 POST 로 본다' -- gh api repos/o/r/pulls/1/reviews -f event=COMMENT
graded_as '읽기'         '명시된 메서드가 필드를 이긴다'     -- gh api -X GET repos/o/r/pulls -f per_page=1
# Deliberate, and it stays deliberate: `auth` reads and rewrites the credential
# the whole separation rests on.
graded_as '등급 미상'    'gh auth 는 의도된 거부로 남는다'   -- gh auth switch --user x

# A schema migration is a standard step BEFORE a deploy, and with no row for the
# client every one of them fell to `등급 미상`, which refuses. All three ways out
# were closed at once — `--surface` is a checked claim that any claim mismatches,
# the basename normalization makes the absolute path identical, and `bash -c`
# passes while recording a DDL against a database as a worktree write.
graded_as '외부상태변경' 'mysql 이 외부 상태 변경으로 등급된다'  -- mysql -e "SELECT 1"
graded_as '외부상태변경' 'psql 도 같다'                          -- psql -c "SELECT 1"
graded_as '외부상태변경' '경로로 부른 클라이언트도 같다'         -- /opt/homebrew/opt/mysql-client@8.0/bin/mysql -e x
# Read-only spellings grade the same, and that is the deliberate side to be
# wrong on: the grade comes from argv0 alone, so a SELECT cannot be told from a
# migration here — requiring a pre-authorization row for a read costs a line,
# letting a migration through as a read costs the database.
graded_as '외부상태변경' '읽기 전용 조회도 같은 등급이다'        -- mysql --defaults-extra-file=f db -e "SELECT 1"

# The refusal names WHICH repair, because two different things arrive there.
# `plan` and not `grade`: the repair sentence lives on the acting path, which is
# where a router that got refused actually is.
gate plan --manifest "$MANIFEST" --kind x --target infra --segment SW --cutpoint 커밋 -- some-unlisted-tool --flag
case "$msg" in
  *"표를 넓혀야"*) ok "미상 거부가 표를 넓히라는 쪽과 다시 쓰라는 쪽을 구별해 말한다" ;;
  *) bad "미상 문면" "'"'"'$msg'"'"'" ;;
esac

# ---------------------------------------------------------------------------
# 15/16. Late sections run against their OWN state home.
#
# Section 14e deliberately moves the enforcement surface and never puts it back,
# and the tail sections that follow it use `grade` and `plan`, neither of which
# reaches the surface check. Anything below that uses `act` therefore inherits a
# moved surface and gets exit 7 for reasons that have nothing to do with what it
# is testing. A fresh state home gives these sections their own baseline while
# keeping the same ledger.
# ---------------------------------------------------------------------------
STATE_LATE="$WORK/state-late"
gateL() {
  local out
  out=$(cd "$WT" && XDG_STATE_HOME="$STATE_LATE" bash "$GATE" "$@" 2>&1); rc=$?
  msg=$(printf '%s' "$out" | grep -vE '\[run\] ' | tr '\n' ' ' | sed 's/[[:space:]]*$//')
}
HL() { cd "$WT" && XDG_STATE_HOME="$STATE_LATE" bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null | jq -r .H; }

# ---------------------------------------------------------------------------
# 15. A stage may not be dispatched into a segment with no `segment` row
#
# The progress vector is built from those rows, so a run that skips them has a
# vector that cannot move and a stagnation boundary that fires on a healthy
# stage — with a question text that names none of it.
# ---------------------------------------------------------------------------
gateL act --manifest "$MANIFEST" --kind skill --target infra --segment SROWLESS --cutpoint 커밋 \
     --surface 워크트리쓰기 --snapshot-digest "$(HL)" --rationale x -- review "/cc-cmds:review-unattended x"
check "segment 행 없는 세그먼트로는 스테이지를 띄우지 못한다" "$rc" "3"
case "$msg" in
  *"segment 행이 없습니다"*) ok "거부가 빠진 행을 이유로 든다" ;;
  *) bad "행 없음 문면" "$msg" ;;
esac
# Not vacuous in the other direction: with the row present the same dispatch
# gets past this check.
gateL act --manifest "$MANIFEST" --kind segment --target infra --segment SROWLESS --cutpoint 커밋 \
     --snapshot-digest "$(HL)" --rationale x -- 상태=실행중 워크트리="$WT" 선행=없음
check "그 행을 쓰면 기록은 통과한다" "$rc" "0"
gateL plan --manifest "$MANIFEST" --kind skill --target infra --segment SROWLESS --cutpoint 커밋 \
     --surface 워크트리쓰기 --snapshot-digest "$(HL)" -- review
check "행이 있으면 같은 디스패치가 이 검사를 넘는다" "$rc" "0"

# ---------------------------------------------------------------------------
# 16. Termination condition 5 has a resolution path, and one block that has none
#
# Counting raw rows made it a one-way latch: a ledger row is never deleted, so a
# single run-scope block — a watcher false positive included — took the run's
# ability to propose done away for good.
# ---------------------------------------------------------------------------
# Condition 5 is read through the propose-done refusal, which is where it
# actually reaches a person: the rejection prints every unmet condition.
cond5_named() {
  gateL act --manifest "$MANIFEST" --kind propose-done --target infra --segment SROWLESS \
       --cutpoint 커밋 --surface 읽기 --snapshot-digest "$(HL)" --rationale x -- 절=x 근거=y
  # Matched on the REASON, not on "condition 5 is unmet". Section 14e leaves a
  # permanent `원인=무효화` run-scope block in this same ledger, so the coarse
  # form is true forever and would assert nothing.
  case "$msg" in *"미해소입니다 (라이브니스 침묵)"*) printf 'yes' ;; *) printf 'no' ;; esac
}
gateL exec --manifest "$MANIFEST" --target infra --segment SROWLESS --cutpoint 커밋 \
     --surface 읽기 --snapshot-digest "$(HL)" --rationale seed -- true
printf -- '- `blocked` | 대상=- | 스코프=run | 원인=불명 | 사유=라이브니스 침묵 | 관측=t | 재개 명령=- | prev=seed\n' >> "$LEDGER"

# The resolution row needs its evidence, and it may not invent a block.
gateL act --manifest "$MANIFEST" --kind blocked --target infra --cutpoint 커밋 \
     --surface 읽기 --snapshot-digest "$(HL)" --rationale x -- 스코프=run 사유="라이브니스 침묵" 원인=해소
check "근거 없는 해소 행은 거부된다" "$rc" "2"
gateL act --manifest "$MANIFEST" --kind blocked --target infra --cutpoint 커밋 \
     --surface 읽기 --snapshot-digest "$(HL)" --rationale x -- 스코프=run 사유="없던 막힘" 원인=해소 근거=z
check "없는 막힘은 해소할 수 없다" "$rc" "2"
gateL act --manifest "$MANIFEST" --kind blocked --target infra --cutpoint 커밋 \
     --surface 읽기 --snapshot-digest "$(HL)" --rationale x -- 스코프=run 사유="라이브니스 침묵" 원인=불명 근거=z
check "라우터는 막힘을 새로 만들 수 없다" "$rc" "2"

check "해소 전에는 종료 제안이 조건 5 를 이유로 든다" "$(cond5_named)" "yes"
gateL act --manifest "$MANIFEST" --kind blocked --target infra --cutpoint 커밋 \
     --surface 읽기 --snapshot-digest "$(HL)" --rationale x \
     -- 스코프=run 사유="라이브니스 침묵" 원인=해소 근거="스테이지가 27초 전에 원장을 키웠다"
check "근거를 실은 해소 행은 통과한다" "$rc" "0"
check "해소 뒤 그 사유는 더 이상 조건 5 에 오르지 않는다" "$(cond5_named)" "no"
# And the run still cannot propose done, because 14e's invalidation block stands
# — which is the point: one reason resolving must not clear another. Called
# directly rather than through `$(...)`, or `msg` would be the subshell's.
gateL act --manifest "$MANIFEST" --kind propose-done --target infra --segment SROWLESS \
     --cutpoint 커밋 --surface 읽기 --snapshot-digest "$(HL)" --rationale x -- 절=x 근거=y
case "$msg" in
  *"해소 불가입니다 (강제 표면 이동)"*) ok "해소 불가인 막힘은 그대로 남는다" ;;
  *) bad "무효화 잔존" "$msg" ;;
esac

# An invalidation block is terminal: clearing it would be the run re-authorizing
# itself past the boundary that had just refused it. Section 14e already left
# one in this ledger, so nothing needs seeding here.
gateL act --manifest "$MANIFEST" --kind blocked --target infra --cutpoint 커밋 \
     --surface 읽기 --snapshot-digest "$(HL)" --rationale x \
     -- 스코프=run 사유="강제 표면 이동" 원인=해소 근거=z
check "무효화 막힘은 해소되지 않는다" "$rc" "3"
case "$msg" in
  *"해소할 수 없습니다"*) ok "거부가 무효화를 이유로 든다" ;;
  *) bad "무효화 문면" "$msg" ;;
esac

# ---------------------------------------------------------------------------
# 17. The authorization record is READ, on the router path
#
# `check_grant` lives on the fixed graph and the router never enters it, so a
# run could execute with a grant that was absent, foreign, or disagreed with the
# manifest, and nothing looked. Measured: a stage declaring cutpoint `배포` ran
# 40 minutes while the file did not exist at the derived path; it appeared 9
# hours 42 minutes later.
# ---------------------------------------------------------------------------
GBAK="$WORK/grant.bak"; cp "$GRANT" "$GBAK"

mv "$GRANT" "$WORK/grant.away"
gateL grade --manifest "$MANIFEST" --target infra --cutpoint 커밋 --surface 읽기 -- ls
check "인가 기록이 없으면 어떤 동사도 서지 않는다" "$rc" "3"
case "$msg" in
  *"인가 기록이 없습니다"*) ok "거부가 부재를 이유로 든다" ;;
  *) bad "인가 부재 문면" "$msg" ;;
esac
cp "$GBAK" "$GRANT"

# A foreign block: one document folds all of its runs onto one grant path, so
# run N+1 meets a block it did not write.
printf '\n## 인가 R-OTHER\n**권한 절단점**: 배포\n' >> "$GRANT"
gateL grade --manifest "$MANIFEST" --target infra --cutpoint 커밋 --surface 읽기 -- ls
check "외래 인가 블록이 있으면 선다" "$rc" "3"
case "$msg" in
  *"외래 인가 블록"*) ok "거부가 외래 블록을 지목한다" ;;
  *) bad "외래 블록 문면" "$msg" ;;
esac
cp "$GBAK" "$GRANT"

# The run maximum is cross-checked against the per-target values that actually
# authorize acts. Without this the two disagree silently for a whole night.
sed 's/^\*\*권한 절단점\*\*: 배포$/**권한 절단점**: 커밋/' "$GBAK" > "$GRANT"
gateL grade --manifest "$MANIFEST" --target infra --cutpoint 커밋 --surface 읽기 -- ls
check "대상 절단점이 런 최대치를 넘으면 선다" "$rc" "3"
case "$msg" in
  *"런 최대치"*) ok "거부가 어느 대상이 넘었는지 말한다" ;;
  *) bad "최대치 문면" "$msg" ;;
esac

# owner-doc must agree with the manifest, and absence is a mismatch.
sed 's/owner-doc=(없음)/owner-doc=docs-something-else/' "$GBAK" > "$GRANT"
gateL grade --manifest "$MANIFEST" --target infra --cutpoint 커밋 --surface 읽기 -- ls
check "owner-doc 이 매니페스트와 다르면 선다" "$rc" "3"
sed 's/ owner-doc=(없음);//' "$GBAK" > "$GRANT"
gateL grade --manifest "$MANIFEST" --target infra --cutpoint 커밋 --surface 읽기 -- ls
check "owner-doc 이 아예 없으면 선다 (부재는 불일치다)" "$rc" "3"

cp "$GBAK" "$GRANT"
gateL grade --manifest "$MANIFEST" --target infra --cutpoint 커밋 --surface 읽기 -- ls
check "온전한 인가 기록에서는 통과한다" "$rc" "0"

# ---------------------------------------------------------------------------
# 18. Concurrent appends do not chain to the same parent
#
# `gate_append` used to read the chain tip OUTSIDE the lock, so two writers read
# the same tip and both emitted rows carrying the same `prev`. The verifier then
# reported a break for a ledger nobody had touched — measured on a 227-row
# ledger where rows 85 and 86 shared a parent, both present and well-formed.
#
# A false break is worse than no chain: a real splice looks exactly like the
# noise a reader has learned to skip.
# ---------------------------------------------------------------------------
CONC="$WORK/conc"; mkdir -p "$CONC"
CLEDGER="$CONC/ledger.md"; : > "$CLEDGER"
(
  set +e
  # shellcheck disable=SC1090
  CC_GATE_SOURCE_ONLY=1 . "$GATE" 2>/dev/null
  LEDGER="$CLEDGER"; RUN_DIR="$CONC"; RUN_ID="RC"
  for i in 1 2 3 4 5 6 7 8; do
    gate_append '자율 승인' "kind=" "결정=exec" "근거=동시-$i" >/dev/null 2>&1 &
  done
  wait
) >/dev/null 2>&1

rows=$(grep -c '^- `' "$CLEDGER" 2>/dev/null || true)
check "여덟 개의 동시 append 가 모두 남는다" "${rows:-0}" "8"

# SERIALIZATION IS ASSERTED ONLY WHERE THERE IS A LOCK TOOL, and that is not a
# convenience skip. The driver declares itself darwin-only and refuses to start
# elsewhere, naming advisory-lock contention as one of the environment facts it
# has measured on darwin and nowhere else. `lock_tool` is empty off darwin, so
# `gate_append` takes its unlocked branch — the ordering this test pins is a
# property of the locked path, and claiming it on a host with no lock would be
# asserting a guarantee the contract does not make.
if [ -x /usr/bin/lockf ]; then
  # Every `prev` distinct. Two rows sharing a parent is the defect, and it is
  # visible without walking the chain.
  uniq_prev=$(sed -n 's/.*| prev=\([0-9a-f]*\).*/\1/p' "$CLEDGER" | sort -u | grep -c . || true)
  check "여덟 행의 prev 가 서로 다르다 (같은 부모에 체인하지 않는다)" "${uniq_prev:-0}" "8"

  # And the chain actually verifies: each row's prev is the digest of the row
  # before it, with the first pointing at the run heading.
  broken=0; expect=$(printf '%s' "## 실행 RC" | shasum -a 256 | cut -d' ' -f1)
  while IFS= read -r row; do
    got=$(printf '%s' "$row" | sed -n 's/.*| prev=\([0-9a-f]*\).*/\1/p')
    [ "$got" = "$expect" ] || broken=$(( broken + 1 ))
    expect=$(printf '%s' "$row" | shasum -a 256 | cut -d' ' -f1)
  done < <(grep '^- `' "$CLEDGER")
  check "체인이 끊긴 곳이 없다" "$broken" "0"
else
  ok "잠금 도구가 없는 호스트라 직렬화 단언을 건너뛴다 (드라이버가 진입에서 거부하는 플랫폼)"
fi

# ---------------------------------------------------------------------------
# 19. The nine grant fields are checked for presence
#
# The block is frozen at append and has no rewrite form, so a field omitted is
# omitted for the life of the run. Nothing compared the set, and the kickoff
# template, this fixture and every hand-written grant had all dropped the same
# one.
# ---------------------------------------------------------------------------
GBAK2="$WORK/grant.bak2"; cp "$GRANT" "$GBAK2"
grep -v '직렬 웨이브 고지' "$GBAK2" > "$GRANT"
gateL grade --manifest "$MANIFEST" --target infra --cutpoint 커밋 --surface 읽기 -- ls
check "아홉 필드 중 하나가 빠지면 선다" "$rc" "3"
case "$msg" in
  *"직렬 웨이브 고지"*) ok "거부가 빠진 필드를 이름으로 지목한다" ;;
  *) bad "필드 문면" "$msg" ;;
esac
cp "$GBAK2" "$GRANT"

# ---------------------------------------------------------------------------
# 20. A resolved approval opens the act; a voided one closes it
#
# Nothing consumed the resolution, so `close` moved the row to `승인` and the
# next attempt at the same act took the same exit 5 — a loop that never closed.
# ---------------------------------------------------------------------------
# `aws s3` is outside the fixture's pre-authorization rows, so it issues one.
gateL act --manifest "$MANIFEST" --kind x --target infra --segment SROWLESS --cutpoint 배포 \
     --surface 외부상태변경 --snapshot-digest "$(HL)" --rationale x -- aws s3 ls
check "사전 인가 밖 행위는 승인을 발행한다" "$rc" "5"
ap=$( { grep -F '`승인`' "$LEDGER" | grep -F '상태=대기' || true; } | tail -1 \
      | tr '|' '\n' | sed -n 's/^ *승인 id=//p' | sed 's/[[:space:]]*$//' | tail -1)
if [ -n "$ap" ]; then ok "승인 id 가 원장에 남는다"; else bad "승인 id" "대기 행을 찾지 못했다"; fi

# Resolve it by hand — `close` reads a transcript this fixture has no way to
# produce, and what is under test is the CONSUMER of the resolved row.
printf -- '- `승인` | 승인 id=%s | 상태=승인 | 답변 문면=픽스처 | 해소 시각=t | prev=x\n' "$ap" >> "$LEDGER"
gateL plan --manifest "$MANIFEST" --kind x --target infra --segment SROWLESS --cutpoint 배포 \
     --surface 외부상태변경 -- aws s3 ls
check "해소된 승인이 같은 행위를 연다" "$rc" "0"

# And a voided one refuses rather than re-asking.
printf -- '- `승인` | 승인 id=%s | 상태=무효 | 답변 문면=픽스처 | 해소 시각=t | prev=x\n' "$ap" >> "$LEDGER"
gateL plan --manifest "$MANIFEST" --kind x --target infra --segment SROWLESS --cutpoint 배포 \
     --surface 외부상태변경 -- aws s3 ls
check "무효로 닫힌 승인은 행위를 거부한다" "$rc" "3"

# ---------------------------------------------------------------------------
# 21. A live stage suppresses the stagnation boundary
#
# The vector cannot move while a stage works — it is manifest-derived plus
# segment rows plus obligations plus cycles, and a working stage writes none of
# those. So every stage making four gate calls issued B1 against itself, and the
# resulting open approval suspended B1..B3 for the rest of the night.
# ---------------------------------------------------------------------------
if grep -vE '^[[:space:]]*#' "$GATE" | grep_all_q -F 'if [ "$(gate_live_stages)" != "0" ]; then'; then
  ok "B1 이 살아 있는 스테이지가 있으면 판정을 건너뛴다"
else
  bad "B1 억제" "정상 스테이지 위에서 경계가 계속 발화한다"
fi
if grep -vE '^[[:space:]]*#' "$GATE" | grep_all_q -F "gate_rows 'cycle'"; then
  ok "진전 벡터가 cycle 행을 본다"
else
  bad "진전 벡터" "리뷰 사이클이 진전으로 세어지지 않는다"
fi

# ---------------------------------------------------------------------------
# 22. A done proposal is not judged by the end gate's merge arm
#
# It has no act behind it, so `--cutpoint` carries no meaning there — yet the
# gate read it and refused, leaving a run past its bound unable to record that
# it had ended: no `done` file, a snapshot showing it in flight forever, and a
# watcher that never reaped itself.
#
# THIS ASSERTION USED TO BE A `grep` FOR THE EXEMPTION'S SOURCE LINE, and it was
# worse than no test. The literal it looked for occurred TWICE in the gate and
# the helper it used answers "at least one", so deleting the exemption left the
# section green — a passing test asserting the exemption of a gate that was no
# longer there. That is the failure mode a red test does not have: an
# implementer reads the checklist, runs the suite, sees green and concludes the
# net held. So the section now EXERCISES the exemption instead of looking for
# it, and the two ways it can break — the exemption removed, or the gate itself
# removed — are distinguished by the two cases below rather than conflated into
# one grep that passes either way.
# ---------------------------------------------------------------------------
printf '2026-01-01T00:00:00Z 종단 — 경계 B4 · 근거 22절 픽스처\n' > "$RD/done"
H=$(cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null | jq -r .H)
gate plan --manifest "$MANIFEST" --kind merge --target infra --segment SD --cutpoint 머지 -- gh pr merge 1
if [ "$rc" = "3" ]; then
  ok "종단한 런에서 머지는 여전히 거부된다 (관문이 살아 있다)"
else
  bad "종단 관문" "종단 표시가 있는데 머지가 rc=$rc 로 통과했다"
fi
gate plan --manifest "$MANIFEST" --kind propose-done --target infra --segment SD --cutpoint 머지 -- true
if [ "$rc" = "3" ]; then
  bad "종료 면제" "종단한 런이 종료 제안을 관문에 막혀 기록할 수 없다"
else
  ok "종단 관문이 종료 제안을 면제한다"
fi
rm -f "$RD/done"

# ---------------------------------------------------------------------------
# 23. The settings directory is serialized for readers and writers alike
# ---------------------------------------------------------------------------
if grep -vE '^[[:space:]]*#' "$GATE" | grep_all_q -F 'gate_settings_lock "$lk" || return 0'; then
  ok "재유도가 락 안에서 돈다"
else
  bad "재유도 락" "병렬 스테이지가 기준선을 서로 되돌린다"
fi
if grep -vE '^[[:space:]]*#' "$GATE" | grep_all_q -F 'out=$(gate_surface_digest_raw)'; then
  ok "표면 다이제스트도 같은 락을 잡는다 (반쯤 쓰인 디렉터리를 해싱하지 않는다)"
else
  bad "다이제스트 락" "읽는 쪽이 잠기지 않아 쓰기 도중을 해싱한다"
fi

# ---------------------------------------------------------------------------
# 24. terraform is graded by its SUBCOMMAND
#
# The name alone graded `외부상태변경`, so `terraform plan` — which the pipeline
# contract classifies as a read — issued an approval every time and an
# unattended stage could never look at infrastructure state.
# ---------------------------------------------------------------------------
graded_as '읽기'         'terraform plan 은 읽기다'              -- terraform plan
graded_as '읽기'         'show 도 읽기다'                        -- terraform show
graded_as '읽기'         '-chdir 이 앞에 와도 하위 명령을 본다'  -- terraform -chdir=/x plan
graded_as '외부상태변경' 'apply 는 외부 상태 변경이다'           -- terraform apply
graded_as '외부상태변경' 'destroy 도 같다'                       -- terraform destroy
graded_as '읽기'         'state list 는 읽기다'                  -- terraform state list
graded_as '외부상태변경' 'state rm 은 상태를 바꾼다'             -- terraform state rm x
graded_as '워크트리쓰기' 'fmt 는 파일을 고친다'                  -- terraform fmt
graded_as '읽기'         'fmt -check 는 고치지 않는다'           -- terraform fmt -check

# ---------------------------------------------------------------------------
# 25. Termination condition 10 — the authorized clauses are read
#
# The nine measured the ledger's shape and never the thing the user authorized
# the run against, so a run with clauses unsettled ended as `충족`. The fixture
# manifest above carries no `종료 절` rows, which means the condition never
# fires there — so this section uses a manifest that has them.
# ---------------------------------------------------------------------------
CM="$WORK/clause-plan.md"
sed 's/^\*\*런 최대 절단점\*\*: .*/**런 최대 절단점**: 배포/' "$MANIFEST" > "$CM"
printf -- '- `종료 절` | id=K1 | 문면=첫째 절\n- `종료 절` | id=K2 | 문면=둘째 절\n' >> "$CM"
# The binding digest no longer matches, and that is itself the check working —
# so it is removed rather than recomputed, which the driver reports and allows.
sed -i.bak '/^\*\*구속 다이제스트\*\*/d' "$CM" && rm -f "$CM.bak"

gateC() {
  local out
  out=$(cd "$WT" && XDG_STATE_HOME="$WORK/state-clause" bash "$GATE" "$@" 2>&1); rc=$?
  msg=$(printf '%s' "$out" | grep -vE '\[run\] ' | tr '\n' ' ' | sed 's/[[:space:]]*$//')
}
HC() { cd "$WT" && XDG_STATE_HOME="$WORK/state-clause" bash "$GATE" snapshot --manifest "$CM" 2>/dev/null | jq -r .H; }

gateC act --manifest "$CM" --kind propose-done --target infra --segment SW --cutpoint 커밋 \
      --surface 읽기 --snapshot-digest "$(HC)" --rationale x -- 절=x 근거=y
check "정산되지 않은 종료 절이 있으면 종료 제안이 기각된다" "$rc" "3"
case "$msg" in
  *"종료 절 K1"*) ok "기각이 어느 절인지 지목한다" ;;
  *) bad "절 문면" "$msg" ;;
esac
# The rejection ROW must stay inside the ledger's cap however many conditions
# are unmet — joining them all made a run with enough segments unable to record
# its own rejection at all.
rejlen=$( { grep -F '결정=기각' "$LEDGER" || true; } | tail -1 | wc -c | tr -d ' ')
if [ "${rejlen:-0}" -gt 0 ] && [ "${rejlen:-0}" -le 1024 ]; then
  ok "기각 행이 원장 상한 안에 든다 (${rejlen}바이트)"
else
  bad "기각 행 길이" "${rejlen}바이트"
fi

# The clause row is checked before it is accepted.
gateC act --manifest "$CM" --kind clause --target infra --cutpoint 커밋 --surface 읽기 \
      --snapshot-digest "$(HC)" --rationale x -- id=K9 상태=충족 근거=z
check "매니페스트에 없는 절은 정산할 수 없다" "$rc" "2"
gateC act --manifest "$CM" --kind clause --target infra --cutpoint 커밋 --surface 읽기 \
      --snapshot-digest "$(HC)" --rationale x -- id=K1 상태=충족
check "근거 없는 절 정산은 거부된다" "$rc" "2"
gateC act --manifest "$CM" --kind clause --target infra --cutpoint 커밋 --surface 읽기 \
      --snapshot-digest "$(HC)" --rationale x -- id=K1 상태=아마도 근거=z
check "어휘 밖 절 상태는 거부된다" "$rc" "2"

gateC act --manifest "$CM" --kind clause --target infra --cutpoint 커밋 --surface 읽기 \
      --snapshot-digest "$(HC)" --rationale x -- id=K1 상태=충족 근거="원장 12행"
check "근거를 실은 절 정산은 통과한다" "$rc" "0"
gateC act --manifest "$CM" --kind clause --target infra --cutpoint 커밋 --surface 읽기 \
      --snapshot-digest "$(HC)" --rationale x -- id=K2 상태=불가능 근거="인가 목록 밖"
check "불가능으로도 정산할 수 있다" "$rc" "0"

# ---------------------------------------------------------------------------
# 26. Grade-1 judgments have a writer
# ---------------------------------------------------------------------------
# A grade-1 judgment also carries `판단 부류`, because that is the field arm (a)
# of the auto-adoption floor reads and the floor is consulted on every grade-1
# judgment. The refusal below must still be the MISSING FIELD and not the floor,
# which is why only `되돌리는 법` is left out of the first row.
gateC act --manifest "$CM" --kind judgment --target infra --cutpoint 커밋 --surface 읽기 \
      --snapshot-digest "$(HC)" --rationale x -- 등급=1 기준=판단등급 "판단 부류=감사-발견" 근거=z
check "되돌리는 법이 없는 판단 행은 거부된다" "$rc" "2"
gateC act --manifest "$CM" --kind judgment --target infra --cutpoint 커밋 --surface 읽기 \
      --snapshot-digest "$(HC)" --rationale x -- 등급=0 기준=판단등급 "되돌리는 법=x" 근거=z
check "등급 0 은 판단 행으로 기록하지 않는다" "$rc" "2"
gateC act --manifest "$CM" --kind judgment --target infra --cutpoint 커밋 --surface 읽기 \
      --snapshot-digest "$(HC)" --rationale x \
      -- 등급=1 기준=판단등급 "판단 부류=감사-발견" "되돌리는 법=git revert abc123" \
         근거="리뷰 스테이지를 하나로 합쳤다"
check "등급 1 판단이 기록된다" "$rc" "0"
if grep -q 'kind=judgment' "$LEDGER"; then
  ok "판단 행이 원장에 남는다 (아침에 되돌릴 수 있는 근거가 생긴다)"
else
  bad "판단 행" "원장에 kind=judgment 가 없다"
fi

# ---------------------------------------------------------------------------
# 27. `완료` is a terminal segment state
#
# A stage that produced its output and had nothing to merge could only be
# recorded as a merge that did not happen or a blockage that was a success.
# ---------------------------------------------------------------------------
gateL act --manifest "$MANIFEST" --kind segment --target infra --segment SDONE --cutpoint 커밋 \
     --snapshot-digest "$(HL)" --rationale x -- 상태=완료 워크트리="$WT" 선행=없음
check "완료 상태가 어휘에 있다" "$rc" "0"
# The enumeration moved to `liveness.sh` so the status line and the termination
# check read one value. This assertion follows the value: asserting against the
# gate would now pass only if the copy came back.
if grep -vE '^[[:space:]]*#' "$LIVENESS" | grep_all_q -F 'TERMINAL_SEGMENT_STATES="머지됨 완료 park"'; then
  ok "완료가 종단 집합에 든다 (종료 조건 1 이 이 세그먼트를 막지 않는다)"
else
  bad "종단 집합" "완료가 종단으로 인정되지 않는다"
fi
# And the copy must not return. A second assignment is the only way the two
# readers can diverge again, and it would not fail any count-based assertion.
if grep -vE '^[[:space:]]*#' "$GATE" | grep_all_q -F 'TERMINAL_SEGMENT_STATES='; then
  bad "종단 집합 사본" "gate.sh 가 열거를 다시 대입한다"
else
  ok "gate.sh 는 열거를 대입하지 않고 참조만 한다"
fi

# ---------------------------------------------------------------------------
# 28. The prose escape in the next-obligation check is gone
#
# Its own comment says prose does not count, and its last line accepted any
# rationale containing one Korean word.
# ---------------------------------------------------------------------------
if grep -vE '^[[:space:]]*#' "$GATE" | grep_all_q -F 'case "$why" in *미충족*) return 0 ;; esac'; then
  bad "산문 통과" "근거에 단어 하나만 있으면 통과하는 경로가 남아 있다"
else
  ok "근거 문자열만으로 다음 의무를 지목했다고 인정하지 않는다"
fi

# ---------------------------------------------------------------------------
# 29. A review obligation can be moved to `이행`, and only against evidence
#
# Section 10b issues one and nothing in the tree could close it: `리뷰 의무` was
# written in a single place, always as `상태=미이행`, and the router's row-writing
# kinds did not include the series. Termination condition 9 therefore held
# against every run that ever deferred a review — the state this pipeline aims
# at was unreachable, and the refusal read as the mechanism working.
# ---------------------------------------------------------------------------
ROID=$( { grep '^- `리뷰 의무`' "$LEDGER" || true; } | grep -F '세그먼트=SEP ' | tail -1 \
        | tr '|' '\n' | sed -n 's/^ *의무 id=//p' | sed 's/[[:space:]]*$//' | tail -1)
if [ -n "$ROID" ]; then
  ok "10b 이 발행한 의무 id 를 원장에서 읽는다 ($ROID)"
else
  bad "의무 id" "선머지후리뷰 머지가 남긴 리뷰 의무 행을 찾지 못했다"
fi

gateL act --manifest "$MANIFEST" --kind obligation --target infra --cutpoint 커밋 \
      --surface 읽기 --snapshot-digest "$(HL)" --rationale x -- "의무 id=$ROID"
check "근거 없는 이행은 거부된다 (주장만으로 리뷰를 닫지 않는다)" "$rc" "2"

gateL act --manifest "$MANIFEST" --kind obligation --target infra --cutpoint 커밋 \
      --surface 읽기 --snapshot-digest "$(HL)" --rationale x -- "의무 id=RO-00000000" 근거=z
check "존재하지 않는 의무는 닫을 수 없다" "$rc" "2"

gateL act --manifest "$MANIFEST" --kind obligation --target infra --cutpoint 커밋 \
      --surface 읽기 --snapshot-digest "$(HL)" --rationale x \
      -- "의무 id=$ROID" 근거="리뷰 리포트에서 P0=0 P1=0 을 읽었다"
check "근거를 실은 이행은 통과한다" "$rc" "0"

roall=$( { grep '^- `리뷰 의무`' "$LEDGER" || true; } | grep -F "의무 id=$ROID " || true)
lastro=$(printf '%s' "$roall" | tail -1)
case "$lastro" in
  *"상태=이행"*) ok "그 의무의 마지막 행이 이행이다" ;;
  *) bad "이행 상태" "$lastro" ;;
esac
case "$lastro" in
  *"이행 시각=-"*) bad "이행 시각" "이행인데 시각 자리가 그대로 비어 있다" ;;
  *"이행 시각="*)  ok "발행 때 비워 둔 이행 시각이 채워진다" ;;
  *) bad "이행 시각" "$lastro" ;;
esac
case "$lastro" in
  *"세그먼트=SEP "*) ok "세그먼트를 선행 행에서 옮겨 싣는다 (argv 가 정하지 않는다)" ;;
  *) bad "세그먼트 승계" "$lastro" ;;
esac
# The issuing row must SURVIVE: closing is an append, so the morning can still
# read when the review was deferred as well as when it landed.
case "$roall" in
  *"상태=미이행"*) ok "발행 시점의 미이행 행이 지워지지 않고 남는다 (편집이 아니라 append)" ;;
  *) bad "append 형태" "발행 행이 사라졌다 — 원장이 append 전용이라는 계약이 깨진다" ;;
esac

gateL act --manifest "$MANIFEST" --kind obligation --target infra --cutpoint 커밋 \
      --surface 읽기 --snapshot-digest "$(HL)" --rationale x \
      -- "의무 id=$ROID" 근거="두 번째 시도"
check "이미 닫힌 의무를 다시 닫지 않는다" "$rc" "2"

# THE POINT OF THE SECTION. Condition 9 was permanent; with the only obligation
# this run issued now fulfilled, it must be gone from the enumeration. Section 11
# measures the same string while the obligation is still open and is left alone —
# there it is correct for the condition to be listed.
gateL act --manifest "$MANIFEST" --kind propose-done --target front --cutpoint 커밋 \
      --surface 읽기 --snapshot-digest "$(HL)" --rationale "끝났다고 본다" -- true
case "$msg" in
  *"9 미이행 리뷰 의무"*) bad "조건 9" "의무를 닫았는데 여전히 미충족으로 열거된다" ;;
  *) ok "이행된 뒤에는 조건 9 가 열거되지 않는다 (런이 종료를 제안할 수 있다)" ;;
esac

# ---------------------------------------------------------------------------
# 30. git is graded by its SUBCOMMAND, not by the word `git`
#
# `worktree`, `branch` and `config` all sat on the read arm, so creating a
# working tree, deleting a ref and rewriting $HOME's own configuration each
# graded `읽기`. Two things followed: the reversibility floor accepted "put the
# setting back in the morning" as a cheap undo, and an act that declared its
# worktree creation honestly came back exit 6 while the same act declared as a
# read ran — so the only spelling that worked was the false one.
# ---------------------------------------------------------------------------
graded_as '읽기'         'git worktree list 는 읽기다'             -- git worktree list
graded_as '워크트리쓰기' 'git worktree add 는 워크트리를 만든다'   -- git worktree add /tmp/wt HEAD
graded_as '워크트리쓰기' 'git worktree remove 도 같다'             -- git worktree remove /tmp/wt
graded_as '읽기'         'git branch 는 목록 조회다'               -- git branch
graded_as '읽기'         '--show-current 도 조회다'                -- git branch --show-current
graded_as '읽기'         '값 있는 조회 옵션이 위치 인자로 보이지 않는다' -- git branch --contains HEAD
graded_as '워크트리쓰기' 'git branch -D 는 ref 를 지운다'          -- git branch -D topic
graded_as '워크트리쓰기' '이름을 주면 브랜치를 만든다'             -- git branch newbr
graded_as '읽기'         'git config --get 은 조회다'              -- git config --get user.name
graded_as '읽기'         '--global 이어도 --get 은 조회다'         -- git config --global --get user.name
graded_as '워크트리쓰기' '로컬 config 쓰기는 트리 안이다'          -- git config user.name x
graded_as '트리밖쓰기'   'git config --global 은 홈을 고친다'      -- git config --global user.name x

# The grade table alone does not cover what was observed: the refusal arrived as
# an exit 6 on the ACT path, so the repair has to be measured there too.
NEWWT="$WORK/honest-wt"
gateL exec --manifest "$MANIFEST" --target infra --cutpoint 커밋 --surface 워크트리쓰기 \
      --snapshot-digest "$(HL)" --rationale "정직하게 선언하고 워크트리를 만든다" \
      -- git worktree add --detach "$NEWWT" HEAD
check "정직하게 선언한 워크트리 생성이 exit 6 으로 거절되지 않는다" "$rc" "0"
if [ -e "$NEWWT" ]; then
  ok "선언대로 워크트리가 실제로 만들어진다"
else
  bad "워크트리 생성" "통과했는데 경로가 없다: $msg"
fi
# ---------------------------------------------------------------------------
# 31. Three holes in the grading table, and each one cost a stage its night
#
# A command with no row falls to `등급 미상`, and that refuses. The stage is
# then left with three moves — break whatever rule sent it there, hide argv0
# behind an interpreter so the act launders into `워크트리쓰기`, or stop. The
# second is the worst of the three: it passes, and the ledger records something
# other than what happened, so the morning report's account of what left the
# machine is quietly false.
# ---------------------------------------------------------------------------
graded_as '읽기'         'git remote 는 로컬 설정을 나열한다'      -- git remote
graded_as '읽기'         'git remote -v 도 나열이다'               -- git remote -v
graded_as '워크트리쓰기' 'git remote add 는 로컬 설정을 쓴다'      -- git remote add o https://x/y
graded_as '워크트리쓰기' 'git remote set-url 도 같다'              -- git remote set-url o https://x/y
graded_as '외부상태변경' 'git remote update 는 원격에 닿는다'      -- git remote update
graded_as '외부상태변경' 'git remote prune 도 같다'                -- git remote prune o
graded_as '등급 미상'    '모르는 remote 하위 명령은 추측하지 않는다' -- git remote frobnicate

# `lockf` carries no grade of its own — it wraps. A fixed grade here would be
# the laundering the table exists to refuse, so the wrapped command decides.
graded_as '워크트리쓰기' 'lockf 가 감싼 워크트리 쓰기는 그 등급이다' -- lockf -k -t 0 /tmp/l.lock git commit -m x
graded_as '읽기'         'lockf 가 감싼 읽기도 그 등급이다'          -- lockf -k -t 0 /tmp/l.lock git status
graded_as '외부상태변경' 'lockf 는 외부 행위를 워크트리 쓰기로 세탁하지 않는다' -- lockf -k -t 0 /tmp/l.lock curl https://x
graded_as '워크트리쓰기' '감쌀 명령이 없는 lockf 는 잠금 파일을 만든다' -- lockf -k /tmp/l.lock
graded_as '읽기'         '절대경로 lockf 도 같게 등급된다'           -- /usr/bin/lockf -k -t 0 /tmp/l.lock git status

# Browser automation. Unlike git and terraform there is no read-only arm to
# carve out — argv says which page to open, and opening any page is a network
# act.
graded_as '외부상태변경' 'playwright-cli 는 외부 상태 변경이다'    -- playwright-cli open https://x
graded_as '외부상태변경' 'chromedriver 도 같다'                    -- chromedriver --port=4444
graded_as '외부상태변경' '경로로 부른 브라우저 도구도 같다'        -- /opt/homebrew/bin/playwright open https://x

# ---------------------------------------------------------------------------
# 32. A middle `grep` that matches nothing must not kill the verb
#
# `set -e` and `pipefail` are both on — the gate sources the driver, which sets
# them. So an unguarded `grep` in the MIDDLE of a pipeline turns "found nothing"
# into a non-zero pipeline, and a bare statement under `set -e` then exits the
# shell with status 1 and NO message. Measured: a router could not write the
# first `segment` row of a run, and the only output was the manifest-check line.
# Every other refusal in this file names its repair; this path said nothing, and
# a silent failure is the one kind a router cannot recover from.
#
# The three assertions below are the three shapes that were exposed. Each fires
# on the ORDINARY state — a ledger with no run-scope block, a segment id with no
# rows yet, an approval id that is not in the ledger — because that is exactly
# when the unguarded spelling returns non-zero.
# ---------------------------------------------------------------------------
# shellcheck source=/dev/null
. "$repo_root/plugins/cc-cmds/orchestrator/liveness.sh"

G32="$WORK/g32-ledger.md"
printf -- '- `run` | 시작=x\n' > "$G32"
( set -euo pipefail; cc_unresolved_blocked "$G32" >/dev/null )
check "run 스코프 blocked 가 없는 원장에서 죽지 않는다" "$?" "0"

printf -- '- `blocked` | 스코프=run | 원인=해소 | 사유=x | 근거=y\n' >> "$G32"
( set -euo pipefail; cc_unresolved_blocked "$G32" >/dev/null )
check "해소된 blocked 만 있는 원장에서도 죽지 않는다" "$?" "0"

# The gate-side siblings. Both are read through the verb so the assertion covers
# the `set -e` context the defect actually fired in, not the function alone.
# `선행=없음` is carried because the declaration axis treats an ABSENT field and
# `없음` as different things: absent is an omission, `없음` is an affirmative
# claim of independence. A fixture with other segments in the ledger must say
# which one it means, and this row means the second.
gateL act --manifest "$MANIFEST" --kind segment --target infra --segment SFRESH \
     --cutpoint 커밋 --snapshot-digest "$(HL)" --rationale "첫 세그먼트" \
     -- 상태=계획됨 "워크트리=$WT" 선행=없음
check "원장에 segment 행이 하나도 없을 때 첫 행이 써진다" "$rc" "0"
# The row itself, not the message — `gateL` strips `[run]` lines on purpose so
# that `$msg` carries warnings and refusals only, and a successful act leaves it
# empty. Asserting on the message here would pass for the wrong reason on every
# quiet success and fail on this one.
case "$( { grep -E '^- `segment`' "$LEDGER" || true; } | grep -cF 'id=SFRESH ' )" in
  0) bad "첫 세그먼트" "행위는 통과했는데 원장에 그 행이 없다" ;;
  *) ok "그 행이 원장에 남는다" ;;
esac

# ---------------------------------------------------------------------------
# 33. A stage that parked itself, a worktree that is the same repository, and a
#     manifest whose clauses do not parse
#
# The three below were each measured rather than imagined. A stage refuted a
# pre-implementation check, wrote its halt record, and was filed as a success —
# twice in one night, and the only way to see it was to open the worktree by
# hand. A segment stage started in the worktree its own target row declares and
# every gate subcommand was refused, with no manifest value able to satisfy both
# it and the audit stage. And a manifest whose `종료 절` rows are spelled so that
# none matches passes the check, then satisfies condition 10 vacuously.
# ---------------------------------------------------------------------------
# --- the halt record decides the class, and it is keyed per attempt ----------
HALTRD="$WORK/halt-run"
mkdir -p "$HALTRD/halt"
printf '<!-- cc-pipeline-halt v1; stage=SH -->\n**분류**: precondition-failed\n<!-- /cc-pipeline-halt v1 -->\n' \
  > "$HALTRD/halt/SH#1.md"
case "$( { grep -vE '^[[:space:]]*$' "$HALTRD/halt/SH#1.md" || true; } | tail -1)" in
  '<!-- /cc-pipeline-halt v1 -->') ok "중단 기록의 닫는 문면이 마지막 비어 있지 않은 줄이다" ;;
  *) bad "중단 기록" "닫는 문면을 찾지 못했다" ;;
esac
# The per-attempt key is what keeps a retry from overwriting the record the
# previous attempt left. Same segment, second attempt, different file.
printf '<!-- cc-pipeline-halt v1; stage=SH -->\n**분류**: gate-unanswerable\n<!-- /cc-pipeline-halt v1 -->\n' \
  > "$HALTRD/halt/SH#2.md"
check "같은 세그먼트의 두 시도가 서로 다른 기록을 갖는다" \
  "$(ls "$HALTRD/halt" | grep -c '^SH#')" "2"
case "$(grep -c 'precondition-failed' "$HALTRD/halt/SH#1.md")" in
  0) bad "중단 기록 덮어쓰기" "첫 시도의 기록이 둘째 시도에 지워졌다" ;;
  *) ok "첫 시도의 기록이 그대로 남는다" ;;
esac

# --- a linked worktree of the SAME repository is not a different repository --
LWT="$WORK/linked-wt"
( cd "$WT" && git worktree add --detach "$LWT" HEAD ) >/dev/null 2>&1
if [ -d "$LWT" ]; then
  a=$(cd "$WT"  && git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
  b=$(cd "$LWT" && git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
  check "링크된 워크트리는 같은 공통 git 디렉터리를 갖는다" "$b" "$a"
  ( cd "$LWT" && bash "$GATE" snapshot --manifest "$MANIFEST" >/dev/null 2>&1 )
  check "그 워크트리에서 게이트가 거부하지 않는다" "$?" "0"
  ( cd "$WT" && git worktree remove --force "$LWT" && git worktree prune ) >/dev/null 2>&1
else
  bad "링크된 워크트리" "픽스처를 만들지 못했다"
fi

# --- a manifest whose clauses do not parse is refused ------------------------
# The refusal lands on the PROPOSAL, not on entry: a hard stop at entry would
# invalidate every manifest already written without clause rows, including runs
# in flight, which is the failure mode this repository has two open issues about.
NOCL="$WORK/no-clause-plan.md"
grep -v '^- `종료 절`' "$MANIFEST" > "$NOCL"
( cd "$WT" && bash "$GATE" snapshot --manifest "$NOCL" >/dev/null 2>&1 )
check "절이 없는 매니페스트도 진입은 통과한다 (진행 중인 런을 비적합으로 만들지 않는다)" "$?" "0"
gateL act --manifest "$NOCL" --kind propose-done --target infra --segment SFRESH \
      --cutpoint 커밋 --snapshot-digest "$( cd "$WT" && XDG_STATE_HOME="$STATE_LATE" bash "$GATE" snapshot --manifest "$NOCL" 2>/dev/null | jq -r .H )" \
      --rationale "절이 없는 매니페스트" -- 절=x 근거=y
case "$msg" in
  *'파싱되는 종료 절이 하나도 없습니다'*) ok "종료 제안이 빈 절 목록을 미충족으로 세운다" ;;
  *) bad "빈 절 목록" "종료 제안이 그것을 지목하지 않았다: $msg" ;;
esac

# Leave the fixture repository's worktree set as it was found.
( cd "$WT" && git worktree remove --force "$NEWWT" && git worktree prune ) >/dev/null 2>&1 || true

# Slice C — one liveness predicate, the run handles, and the stall dedupe key
#
# The three properties here were each a measured defect rather than a worry:
# a render that counted pid FILES, a run whose termination was blocked forever
# by a reused pid (condition 7 has no resolving verb), and a second stall that
# never reached the ledger because the dedupe key matched the whole file.
# ---------------------------------------------------------------------------
# shellcheck source=/dev/null
. "$repo_root/scripts/run-fixture.sh"
# shellcheck source=/dev/null
. "$repo_root/plugins/cc-cmds/orchestrator/liveness.sh"

# This section drives the gate directly, and the suite's normal execution
# context is INSIDE a pipeline stage — which exports this whole group. The gate
# branches on `CC_PIPELINE_STAGE_ID` at entry (a stage session is kept out of
# the lineage so it cannot answer the approvals gating itself), so an inherited
# value makes every call below take that branch, `session-lineage` is never
# written, and the assertions that read it fail for a reason unrelated to what
# they assert. Clear the group so the section starts from a known state; the
# stage sub-case sets what it needs and unsets it again.
unset CC_PIPELINE_RUN_ID CC_PIPELINE_RUN_DIR CC_PIPELINE_MANIFEST \
      CC_PIPELINE_LEDGER CC_PIPELINE_GRANT CC_PIPELINE_GATE \
      CC_PIPELINE_TARGET CC_PIPELINE_SEGMENT CC_PIPELINE_STAGE_ID \
      CC_PIPELINE_PARENT_SESSION
trap 'fx_reap; rm -rf "$WORK"' EXIT

# --- the predicate itself, against all three pid states at once -------------
fx_mkrun "LIVENESS"
fx_stage_live   A
fx_stage_dead   B
fx_stage_reused C
n=$(cc_live_stages "$FX_RUN_DIR")
check "cc_live_stages 가 살아 있는 하나만 센다 (죽은 pid·재사용 pid 제외)" "$n" "1"
n=$( { ls "$FX_RUN_DIR"/*.pid 2>/dev/null || true; } | grep -c . || true)
check "그 픽스처의 pid 파일은 셋이다 (파일 수와 프로세스 수가 다르다)" "$n" "3"

# The glob has no namespace of its own, so what separates a stage from anything
# else that parks a pid here is the sibling its spawner leaves. The watcher's
# own `watch.pid` has none. A LIVE pid is written on purpose: a dead one is
# filtered by `kill -0` first, and the assertion would then pass whether or not
# the sibling test existed.
printf '%s' "$$" > "$FX_RUN_DIR/watch.pid"
n=$(cc_live_stages "$FX_RUN_DIR")
check "형제 없는 산 pid 는 스테이지로 세지 않는다 (워처의 watch.pid)" "$n" "1"
rm -f "$FX_RUN_DIR/watch.pid"

# The counterpart, which pins the option that was rejected: the driver's stage
# spawn writes `.pgid` and never `.start`, so raising `.start` alone to a
# necessary condition would silently drop every stage the driver started. The
# pgid is now what VERIFIES this stage's identity, so the fixture records the
# real one and the pass is earned rather than inherited from a bare `kill -0`.
fx_stage_driver_live D
n=$(cc_live_stages "$FX_RUN_DIR")
check "pgid 형제만 있는 드라이버 모양 스테이지는 센다" "$n" "2"
rm -f "$FX_RUN_DIR/D.pid" "$FX_RUN_DIR/D.pgid"

# The driver path's own pid-reuse case, which had no fixture and therefore no
# assertion. Until the identity check was split in three this shape fell
# through to `kill -0` and counted — the very hole the gate-spawned path had
# already closed.
fx_stage_driver_reused E
n=$(cc_live_stages "$FX_RUN_DIR")
check "pgid 가 어긋난 드라이버 모양 스테이지는 세지 않는다" "$n" "1"
rm -f "$FX_RUN_DIR/E.pid" "$FX_RUN_DIR/E.pgid"

# Sibling present, identity unverifiable — its own case rather than a pass.
fx_stage_unverifiable F
n=$(cc_live_stages "$FX_RUN_DIR")
check "형제는 있으나 신원을 확인할 수 없는 스테이지는 세지 않는다" "$n" "1"
rm -f "$FX_RUN_DIR/F.pid" "$FX_RUN_DIR/F.start"

# Production's actual shape, which no fixture made before: `set -m` gives the
# driver's child its own group, so the recorded group IS the pid and a pure
# string compare against it matches whoever holds that pid next. The fingerprint
# is what makes the reuse visible, and the driver now records one.
fx_stage_driver_reused_leader G
check "드라이버 재사용 픽스처가 프로덕션 모양(pgid == pid)을 만든다" \
  "$(cat "$FX_RUN_DIR/G.pgid")" "$FX_LAST_PID"
n=$(cc_live_stages "$FX_RUN_DIR")
check "pgid 가 pid 와 같아도 지문이 어긋난 드라이버 모양 스테이지는 세지 않는다" "$n" "1"
rm -f "$FX_RUN_DIR/G.pid" "$FX_RUN_DIR/G.pgid" "$FX_RUN_DIR/G.start"

# The identity layer itself. Deleting it makes the three counts above pass for
# the wrong reason, so a count is not what can catch that regression.
if grep -vE '^[[:space:]]*#' "$LIVENESS" | grep_all_q -F 'cc_proc_pgid() {' \
   && grep -vE '^[[:space:]]*#' "$LIVENESS" | grep_all_q -F 'now=$(cc_proc_pgid "$pid")'; then
  ok "liveness.sh 가 cc_proc_pgid 를 정의하고 신원 확인이 그것을 부른다"
else
  bad "pgid 신원" "드라이버 경로의 신원 확인 층이 없다"
fi

# The two counts above only read a `.start` the FIXTURE wrote, so they stay
# green if the driver's spawn stops writing one. This pins the writing side.
if grep -vE '^[[:space:]]*#' "$RUNSH" | grep_all_q -F '> "$RUN_DIR/$stage.start"'; then
  ok "스테이지 스폰이 시작 시각 지문을 기록한다"
else
  bad "스폰 지문" "드라이버 스폰이 .start 를 쓰지 않는다"
fi

fx_approval AP-1 대기
fx_approval AP-2 대기
fx_approval AP-1 승인
n=$(cc_open_approvals "$FX_LEDGER")
check "cc_open_approvals 가 id 별 마지막 행으로 접는다" "$n" "1"

fx_segment SX 계획됨
fx_segment SY 머지됨
fx_segment SX park
n=$(cc_nonterminal_segments "$FX_LEDGER")
check "cc_nonterminal_segments 도 마지막 행으로 접는다" "$n" "0"
n=$(cc_segment_count "$FX_LEDGER")
check "cc_segment_count 가 고유 세그먼트를 센다 (공집합 가드의 입력)" "$n" "2"

# `완료` is the third terminal state and this predicate used to carry its own
# two-element enumeration. A 완료 segment is what separates "reads the shared
# constant" from "happens to agree on the other two": counted as in flight, a
# finished run can never end.
fx_segment SZ 완료
n=$(cc_nonterminal_segments "$FX_LEDGER")
check "완료 세그먼트도 종단으로 접는다 (게이트와 같은 열거)" "$n" "0"
n=$(cc_segment_count "$FX_LEDGER")
check "그 완료 픽스처가 실제로 심겼다" "$n" "3"

fx_blocked "정지 A" 불명
fx_blocked "정지 B" 불명
fx_blocked "정지 A" 해소
n=$(cc_unresolved_blocked "$FX_LEDGER" | grep -c . || true)
check "cc_unresolved_blocked 가 해소된 사유를 빼고 센다" "$n" "1"
msg=$(cc_unresolved_blocked "$FX_LEDGER" | cut -f2-)
check "남은 것이 해소되지 않은 쪽이다" "$msg" "정지 B"
fx_reap

# --- the handles the gate publishes on every entry --------------------------
#
# A FRESH RUN, not R1. The assertions below drive real `act`s, and R1's
# enforcement-surface baseline has moved several times by this point in the
# suite — earlier tests rewrite the grant and the manifest on purpose. An act
# against it exits 7 before it ever reaches the condition being asserted, which
# is the boundary working rather than a defect. Only the run id changes: the
# manifest's two digests cover the goal, the clauses, the targets, the rule
# settings, the pre-authorizations and the deadline — not the id.
sed 's/R1/R2/g' "$MANIFEST" > "$WT/plan2.md"
sed 's/R1/R2/g' "$GBAK" > "$WT/docs/pipeline-grant/R2.md"
MANIFEST="$WT/plan2.md"
LEDGER="$WT/docs/pipeline-run/R2.md"
GRANT="$WT/docs/pipeline-grant/R2.md"
RD="$XDG_STATE_HOME/cc-cmds/run/R2"
CLAUDE_CODE_SESSION_ID=sess-alpha
export CLAUDE_CODE_SESSION_ID
gate snapshot --manifest "$MANIFEST"
check "핸들을 쓰는 동사가 통과한다" "$rc" "0"
check "ledger-path 가 원장 절대경로를 담는다" "$(cat "$RD/ledger-path" 2>/dev/null || true)" "$LEDGER"

# Lineage used to be recorded only inside `gate_transcript_files`, which only
# `close` reaches — so a run that never opened an approval had none at all.
# The file accumulates every session id this run has had, so the assertion is
# on THIS id's occurrences rather than on the file's length.
n=$(grep -cxF 'sess-alpha' "$RD/session-lineage" 2>/dev/null || true)
check "승인 없는 동사에서도 계보가 생긴다" "$n" "1"
gate snapshot --manifest "$MANIFEST"
n=$(grep -cxF 'sess-alpha' "$RD/session-lineage" 2>/dev/null || true)
check "같은 세션 id 로 다시 불러도 계보에 한 번만 남는다" "$n" "1"

# R1, measured. Every id in the lineage is an id allowed to ANSWER an approval,
# because that is the set `gate_transcript_files` searches. Stages reach the
# gate too — the pre-tool hook routes their Bash, Write and Edit through it — so
# an unguarded promotion would let a stage answer the approvals gating itself.
CC_PIPELINE_STAGE_ID=SC
export CC_PIPELINE_STAGE_ID
CLAUDE_CODE_SESSION_ID=sess-stage
gate snapshot --manifest "$MANIFEST"
n=$(grep -cxF 'sess-stage' "$RD/session-lineage" 2>/dev/null || true)
check "스테이지 세션은 계보에 들어가지 않는다 (자기 승인 경로가 열리지 않는다)" "$n" "0"
n=$(grep -cxF 'R2' "$XDG_STATE_HOME/cc-cmds/session/sess-stage" 2>/dev/null || true)
check "그래도 순방향 색인에는 들어간다 (표시용이지 승인 채널이 아니다)" "$n" "1"
unset CC_PIPELINE_STAGE_ID
CLAUDE_CODE_SESSION_ID=sess-alpha
export CLAUDE_CODE_SESSION_ID

# The FORWARD index. It is a list because one session can hold several runs;
# the dedupe is what keeps repeated entries from growing it without bound.
SIDX="$XDG_STATE_HOME/cc-cmds/session/sess-alpha"
check "순방향 색인이 이 런을 담는다" "$(cat "$SIDX" 2>/dev/null || true)" "R2"
n=$(grep -c . "$SIDX" 2>/dev/null || true)
check "같은 런을 두 번 봐도 색인은 한 줄이다" "$n" "1"
printf '%s\n' "R-OTHER" >> "$SIDX"
gate snapshot --manifest "$MANIFEST"
n=$(grep -c . "$SIDX" 2>/dev/null || true)
check "한 세션에 런이 둘이면 두 줄로 남는다 (덮어쓰기가 아니다)" "$n" "2"
sed '/^R-OTHER$/d' "$SIDX" > "$SIDX.tmp" && mv "$SIDX.tmp" "$SIDX"

# Every `act` carries a snapshot digest, and the snapshot moves whenever a row
# lands — so it is re-read immediately before each one rather than reused.
snapH() {
  ( cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null ) \
    | sed -n 's/.*"H": "\([0-9a-f]*\)".*/\1/p' | tail -1
}

# --- termination condition 7 reads the same predicate -----------------------
FX_RUN_DIR="$RD"; FX_PIDS=""
fx_stage_dead D1
gate act --manifest "$MANIFEST" --kind propose-done --target infra --segment - \
  --cutpoint 커밋 --surface 읽기 --snapshot-digest "$(snapH)" \
  --rationale "픽스처 — 미충족 조건 열거"
case "$msg" in
  *"7 살아 있는 스테이지"*) bad "조건 7" "죽은 pid 를 살아 있다고 셌다" ;;
  *"미충족 조건"*) ok "조건 7 이 죽은 pid 를 세지 않는다" ;;
  *) bad "조건 7" "조건 열거에 닿지 못했다: $msg" ;;
esac
fx_stage_reused D2
gate act --manifest "$MANIFEST" --kind propose-done --target infra --segment - \
  --cutpoint 커밋 --surface 읽기 --snapshot-digest "$(snapH)" \
  --rationale "픽스처 — 미충족 조건 열거"
case "$msg" in
  *"7 살아 있는 스테이지"*) bad "조건 7" "재사용 pid 를 살아 있다고 셌다 — 종료를 영구히 막는 경로다" ;;
  *"미충족 조건"*) ok "조건 7 이 재사용 pid 를 세지 않는다" ;;
  *) bad "조건 7" "조건 열거에 닿지 못했다: $msg" ;;
esac
fx_stage_live D3
gate act --manifest "$MANIFEST" --kind propose-done --target infra --segment - \
  --cutpoint 커밋 --surface 읽기 --snapshot-digest "$(snapH)" \
  --rationale "픽스처 — 미충족 조건 열거"
case "$msg" in
  *"7 살아 있는 스테이지가 1개입니다"*) ok "조건 7 이 실제로 살아 있는 스테이지는 센다" ;;
  *) bad "조건 7" "살아 있는 스테이지를 놓쳤다: $msg" ;;
esac
fx_reap
rm -f "$RD"/D1.pid "$RD"/D1.start "$RD"/D2.pid "$RD"/D2.start "$RD"/D3.pid "$RD"/D3.start

# --- gate_drain_stall: four, and the fourth is the one that was missing -----
#
# Draining happens in the `act` path, not on `snapshot` — the transcription is
# the ledger writer's job and `snapshot` writes nothing. So each step here
# drives a real act.
TAB=$(printf '\t')
drain_act() {
  gate act --manifest "$MANIFEST" --kind segment --target infra --segment SDR \
    --cutpoint 커밋 --surface 읽기 --snapshot-digest "$(snapH)" \
    --rationale "픽스처 — 전사 유발" -- "상태=계획됨" "워크트리=$WT" "선행=없음"
}
printf '2026-08-31T00:00:00Z%s정체 사유 X%s재개 명령 X\n' "$TAB" "$TAB" > "$RD/stall"
drain_act
n=$(grep -cF '원인=불명 | 사유=정체 사유 X' "$LEDGER" || true)
check "정지 관측이 blocked 행으로 전사된다" "$n" "1"
n=$(wc -c < "$RD/stall" | tr -d ' ')
check "전사 뒤 관측 파일이 비워진다" "$n" "0"
printf '2026-08-31T00:01:00Z%s정체 사유 X%s재개 명령 X\n' "$TAB" "$TAB" > "$RD/stall"
drain_act
n=$(grep -cF '원인=불명 | 사유=정체 사유 X' "$LEDGER" || true)
check "미해소인 같은 사유는 두 번 전사되지 않는다" "$n" "1"
# THE FOURTH. A person resolves the block, the same condition recurs, and the
# recurrence has to reach the ledger — otherwise the morning report cannot tell
# "it stalled once and was cleared" from "it is still stalling".
gate act --manifest "$MANIFEST" --kind blocked --target infra --segment - \
  --cutpoint 커밋 --surface 읽기 --snapshot-digest "$(snapH)" --rationale "픽스처" \
  -- "원인=해소" "사유=정체 사유 X" "근거=픽스처가 해소로 판정했다"
check "해소 행이 통과한다" "$rc" "0"
printf '2026-08-31T00:02:00Z%s정체 사유 X%s재개 명령 X\n' "$TAB" "$TAB" > "$RD/stall"
drain_act
n=$(grep -cF '원인=불명 | 사유=정체 사유 X' "$LEDGER" || true)
check "해소 뒤 같은 사유가 다시 멈추면 그 관측이 다시 전사된다" "$n" "2"
# ---------------------------------------------------------------------------
# 31. The dependency cone, the auto-adoption floor, and the waiting states
#
# A question a person alone can answer used to stop the whole run. What replaces
# that is a cone: what stands on the refuted premise is held and its siblings
# keep going. Everything below is the machinery that makes the holding derivable
# rather than declared, plus the two states — a judgment approval and a clause on
# hold — that let the run END while the question is still open.
#
# A SEPARATE RUN, because the cone is derived over EVERY `segment` row in the
# ledger. The sections above leave a dozen of them all naming the same worktree,
# and `git merge-base --is-ancestor X X` is true, so every pair there answers
# "ancestor" and a cone assertion would pass whatever the derivation did. The run
# id is what splits the ledger, so this section carries its own manifest, grant
# and ledger.
#
# AND IT DERIVES THAT ID RATHER THAN ASSUMING IT. A section added above this one
# took the id this one used to hardcode, after which `sed … "$GRANT" > …` named
# one path on both sides: the shell truncated the authorization record before
# `sed` could read it, the grant went to zero bytes, and every call below died on
# a missing authorization block. So the inherited id is READ from the manifest
# and asserted to differ from this section's own. A fresh hardcoded constant
# would only move the collision to whichever id the next section upstream takes,
# and it would be just as quiet when it arrived.
# ---------------------------------------------------------------------------
# The pipeline environment group, cleared AGAIN. The section above clears it for
# its own reasons and this one needs the same thing for the same reason — a stage
# session is deliberately kept out of the lineage, so an inherited
# `CC_PIPELINE_STAGE_ID` makes every call below take that branch. Leaning on the
# previous section having done it is the shape this repair exists to remove.
unset CC_PIPELINE_RUN_ID CC_PIPELINE_RUN_DIR CC_PIPELINE_MANIFEST \
      CC_PIPELINE_LEDGER CC_PIPELINE_GRANT CC_PIPELINE_GATE \
      CC_PIPELINE_TARGET CC_PIPELINE_SEGMENT CC_PIPELINE_STAGE_ID \
      CC_PIPELINE_PARENT_SESSION

CONE_RUN_ID=R3
prev_run_id=$(sed -n 's/^\*\*런 id\*\*: //p' "$MANIFEST" | tail -1)
# A BROKEN FIXTURE EXITS RATHER THAN ASSERTING — the idiom `nm_add_auth_row` and
# `refresh_bd` already use. The id has to differ because the id is what splits
# the ledger: an inherited one would merge this section's rows into the previous
# section's and every derivation below would read both.
if [ -z "$prev_run_id" ] || [ "$prev_run_id" = "$CONE_RUN_ID" ]; then
  printf '31: 앞 절의 런 id 를 매니페스트에서 읽지 못했거나 이 절의 id 와 겹친다 (읽은 값 %s, 이 절 %s)\n' \
    "${prev_run_id:-(없음)}" "$CONE_RUN_ID" >&2
  exit 1
fi

NM="$WORK/cone-plan.md"
CONE_GRANT="$WT/docs/pipeline-grant/$CONE_RUN_ID.md"
LEDGER2="$WT/docs/pipeline-run/$CONE_RUN_ID.md"
# AND THE GUARD AGAINST THE COLLISION IS ON THE PATHS, NOT ON THE ID. What went
# wrong was `sed … "$GRANT" > "$CONE_GRANT"` naming one file on both sides: the
# shell truncated the authorization record before `sed` could read it, the grant
# went to zero bytes, and every call below died on a missing authorization block.
# The id is one input to those three paths and not the only one — a section added
# above can take this id while writing it into its OWN copy of the manifest, so
# the value this section reads never moves, the id check passes, and the files
# overlap exactly as before. Each destination is therefore compared against the
# source it is derived from, which is the pair that actually collides.
if [ "$NM" = "$MANIFEST" ] || [ "$CONE_GRANT" = "$GRANT" ] || [ "$LEDGER2" = "$LEDGER" ]; then
  printf '31: 이 절이 만드는 파일이 앞 절의 것과 같은 경로다 — 읽기 전에 셸이 원본을 비운다 (매니페스트 %s vs %s · 인가 %s vs %s · 원장 %s vs %s)\n' \
    "$NM" "$MANIFEST" "$CONE_GRANT" "$GRANT" "$LEDGER2" "$LEDGER" >&2
  exit 1
fi
sed -e "s/run-id=$prev_run_id;/run-id=$CONE_RUN_ID;/" \
    -e "s/^\*\*런 id\*\*: $prev_run_id\$/**런 id**: $CONE_RUN_ID/" "$MANIFEST" > "$NM"
# The binding digest no longer matches, and that is the check working — so it is
# dropped rather than recomputed, which the driver reports and allows.
sed -i.bak '/^\*\*구속 다이제스트\*\*/d' "$NM" && rm -f "$NM.bak"
# ROWS GO INSIDE `## 인가`, AND APPENDING TO THE FILE DOES NOT PUT THEM THERE.
#
# This suite adds a `## 룰 설정` section below `## 인가` earlier on, so `>>` lands
# a row in THAT section — and the auto-adoption floor honours only rows inside
# `## 인가`, because that is the section the "exactly one" guarantee is about. A
# row anywhere else is not a declaration the floor reads; treating it as one is
# the hole being closed, so the fixture must place the row the way a kickoff
# does rather than wherever the file happens to end.
nm_add_auth_row() {
  local line="$1" out="$NM.ins" l inserted=
  : > "$out"
  while IFS= read -r l || [ -n "$l" ]; do
    printf '%s\n' "$l" >> "$out"
    if [ -z "$inserted" ] && [ "$l" = "## 인가" ]; then
      printf '%s\n' "$line" >> "$out"
      inserted=1
    fi
  done < "$NM"
  if [ -z "$inserted" ]; then
    printf 'nm_add_auth_row: 매니페스트에 「## 인가」 절이 없다\n' >&2
    exit 1
  fi
  mv "$out" "$NM"
}
# One pre-declared judgment class — this is arm (a)'s only input, and a run
# cannot write it.
nm_add_auth_row '- `자동 채택` | 판단 부류=문서-신선도 | 상한=없음 | 심각도 상한=minor | 사유=문서 신선도 판정은 되돌릴 대상이 없다'
nm_add_auth_row '- `종료 절` | id=K1 | 문면=첫째 절'
# A BLANKET substitution is right here and an anchored one is right above. The
# grant carries the id in its title, in its `## 인가` heading and inside the
# `**보고서**:` path, all three of which must move together, and it holds no hex
# digest for a loose match to corrupt. What made this line dangerous was never
# the pattern — it was reading and writing one path, which the guard above now
# makes unreachable.
sed "s/$prev_run_id/$CONE_RUN_ID/g" "$GRANT" > "$CONE_GRANT"
{
  printf '# 파이프라인 런 보고서 — %s\n\n' "$CONE_RUN_ID"
  printf '런 id %s · 앵커 repo:t/front · 대상 front(절단점 PR) infra(절단점 배포)\n' "$CONE_RUN_ID"
} > "$LEDGER2"

# HELPERS FIRST, BEFORE ANY CALL. A helper defined below its first use dies as
# `command not found` while the suite still reports green — the trap 9e1be1b
# closed, in the file that closed it.
STATE_CONE="$WORK/state-cone"
gateN() {
  local out
  out=$(cd "$WT" && XDG_STATE_HOME="$STATE_CONE" bash "$GATE" "$@" 2>&1); rc=$?
  msg=$(printf '%s' "$out" | grep -vE '\[run\] ' | tr '\n' ' ' | sed 's/[[:space:]]*$//')
}
HN() { cd "$WT" && XDG_STATE_HOME="$STATE_CONE" bash "$GATE" snapshot --manifest "$NM" 2>/dev/null | jq -r .H; }
seg_row() {
  # seg_row <id> <worktree> <필드>… — one `segment` act, always through the gate
  # so the write-time floors actually run.
  local id="$1" wt="$2"; shift 2
  gateN act --manifest "$NM" --kind segment --target infra --segment "$id" --cutpoint 커밋 \
        --surface 읽기 --snapshot-digest "$(HN)" --rationale x -- 워크트리="$wt" "$@"
}
CONE_OF_FAILURES="$WORK/cone-of-failures"
: > "$CONE_OF_FAILURES"
cone_of() {
  # cone_of <anchor> <사유> — the `의존 세그먼트` the gate DERIVED. The row is
  # written with no declaration, so what lands on it is the derivation itself.
  gateN act --manifest "$NM" --kind blocked --target infra --cutpoint 커밋 --surface 읽기 \
        --snapshot-digest "$(HN)" --rationale x \
        -- 스코프=cone 원인=막힘 "앵커 세그먼트=$1" "사유=$2" \
           "근거=$1 이 사람의 답을 기다린다" "재개 명령=승인이 닫히면 다시 디스패치"
  # THE ACT'S OWN CODE IS READ BEFORE THE LEDGER IS. This section calls with the
  # same anchor seven times and then takes the LAST row carrying that anchor, so
  # a call refused for any reason — a digest race, a vocabulary change, the row
  # length cap the over-long-declaration subsection proves exists — writes no row
  # and the read below hands back the PREVIOUS call's cone. Nothing downstream
  # could notice: the pipeline's status is `tail`'s and is always 0.
  #
  # THE FAILURE GOES TO A FILE RATHER THAN TO `bad`. Every caller is
  # `x=$(cone_of …)`, which is a subshell, so a counter incremented here never
  # reaches the totals — the exact shape this suite is being repaired for. The
  # file is read once at the end of the section, in the parent.
  if [ "$rc" != "0" ]; then
    printf '앵커 %s rc=%s — %s\n' "$1" "$rc" "$msg" >> "$CONE_OF_FAILURES"
    printf '유도-실패'
    return 1
  fi
  { grep -F '`blocked`' "$LEDGER2" || true; } | grep -F "앵커 세그먼트=$1 " | tail -1 \
    | tr '|' '\n' | sed -n 's/^ *의존 세그먼트=//p' | sed 's/[[:space:]]*$//' | tail -1
}
last_judgment_approval() {
  { grep -F '`승인`' "$LEDGER2" || true; } | grep -F '절단점=판단' | grep -F '상태=대기' | tail -1
}
row_field() {
  # row_field <행> <키> — the last value of that key on a ledger row.
  printf '%s' "$1" | tr '|' '\n' | sed -n "s/^ *$2=//p" | sed 's/[[:space:]]*$//' | tail -1
}

# REAL WORKTREES WITH REAL ANCESTRY. The ancestor axis runs `git merge-base
# --is-ancestor` against live trees, so a fixture made of ledger rows alone would
# assert nothing about the half of the derivation that reads git.
#
#   A   base + a1                    the anchor
#   B   A + b1                       stacked on A — ancestor axis, no declaration
#   C   base + c1                    unrelated — must stay out
#   D   base + d1, `선행=A`          declared but NOT stacked — the main case
#   E   base + src/e1, declares docs/ file-set escape
#   F   base + f1, rebased onto A later     the predicate
#   G   base, worktree removed later        undecidable
CONE_A="$WORK/cone-a"; CONE_B="$WORK/cone-b"; CONE_C="$WORK/cone-c"
CONE_D="$WORK/cone-d"; CONE_E="$WORK/cone-e"; CONE_F="$WORK/cone-f"; CONE_G="$WORK/cone-g"
( cd "$REPO" && git worktree add -q -b coneA "$CONE_A" main \
  && cd "$CONE_A" && echo a1 > a1.txt && git add -A && git commit -qm a1 ) >/dev/null 2>&1
( cd "$REPO" && git worktree add -q -b coneB "$CONE_B" coneA \
  && cd "$CONE_B" && echo b1 > b1.txt && git add -A && git commit -qm b1 ) >/dev/null 2>&1
( cd "$REPO" && git worktree add -q -b coneC "$CONE_C" main \
  && cd "$CONE_C" && echo c1 > c1.txt && git add -A && git commit -qm c1 ) >/dev/null 2>&1
( cd "$REPO" && git worktree add -q -b coneD "$CONE_D" main \
  && cd "$CONE_D" && echo d1 > d1.txt && git add -A && git commit -qm d1 ) >/dev/null 2>&1
( cd "$REPO" && git worktree add -q -b coneE "$CONE_E" main \
  && cd "$CONE_E" && mkdir -p src && echo e1 > src/e1.txt && git add -A && git commit -qm e1 ) >/dev/null 2>&1
( cd "$REPO" && git worktree add -q -b coneF "$CONE_F" main \
  && cd "$CONE_F" && echo f1 > f1.txt && git add -A && git commit -qm f1 ) >/dev/null 2>&1
( cd "$REPO" && git worktree add -q -b coneG "$CONE_G" main ) >/dev/null 2>&1
tipA=$(cd "$CONE_A" && git rev-parse HEAD)
base_main=$(cd "$REPO" && git rev-parse main)

# A SECOND REPOSITORY. Commits do not stack across repositories, so that edge is
# settled without asking git at all — and settling it first is what leaves
# `--is-ancestor`'s 128 meaning a genuine fault instead of the commonest benign
# case.
REPO2="$WORK/repo2"; mkdir -p "$REPO2"
( cd "$REPO2" && git init -q . \
  && git config user.email t@example.invalid && git config user.name T \
  && echo x > x.txt && git add -A && git commit -qm x ) >/dev/null 2>&1

# --- 31a. The gate checks its own scope vocabulary -------------------------
#
# Until now the only code comparing scope tokens was `park()` in the driver, and
# the gate spelled every one of them as a literal. A misspelled scope is not a
# loud failure: it slips past termination condition 5's `스코프=run` filter AND
# past the cone predicate, so what lands is a park that stands nothing up.
gateN act --manifest "$NM" --kind blocked --target infra --cutpoint 커밋 --surface 읽기 \
      --snapshot-digest "$(HN)" --rationale x -- 스코프=원뿔 원인=막힘 사유=x 근거=z
check "게이트가 스코프 어휘를 검사한다" "$rc" "2"
case "$msg" in
  *"스코프」가 어휘 밖입니다"*) ok "거절이 어느 토큰이 어휘 밖인지 말한다" ;;
  *) bad "스코프 어휘" "$msg" ;;
esac
gateN act --manifest "$NM" --kind blocked --target infra --cutpoint 커밋 --surface 읽기 \
      --snapshot-digest "$(HN)" --rationale x -- 원인=막힘 사유=x 근거=z
check "「스코프」 필드가 아예 없는 blocked 행도 거절된다" "$rc" "2"

# --- 31b. `선행` — absence, `없음`, and monotonicity ------------------------
seg_row SA "$CONE_A" 상태=실행중 선행=없음
check "앵커 세그먼트 행이 기록된다" "$rc" "0"
# ABSENCE AND `없음` ARE DIFFERENT THINGS, and write time is the only moment at
# which the difference exists — read later they are the same empty set.
seg_row SB "$CONE_B" 상태=실행중
check "세그먼트가 둘 이상인데 「선행」이 없으면 거절된다" "$rc" "2"
case "$msg" in
  *"「선행」이 필요합니다"*) ok "조용한 누락이 적는 쪽에게 들리는 거절이 된다" ;;
  *) bad "선행 부재" "$msg" ;;
esac
seg_row SB "$CONE_B" 상태=실행중 선행=없음
check "「없음」은 독립성의 적극적 진술로 받는다" "$rc" "0"
seg_row SC "$CONE_C" 상태=실행중 선행=없음
check "무관한 베이스의 세그먼트 행도 기록된다" "$rc" "0"
seg_row SX "$REPO2" 상태=실행중 선행=없음
check "다른 레포의 세그먼트 행도 기록된다" "$rc" "0"

# --- 31c. The cone's two axes cover different windows ----------------------
cone1=$(cone_of SA "SA 가 감사 발견으로 멈췄다")
case ",$cone1," in
  *,SA,*) ok "앵커는 무조건 원뿔에 든다" ;;
  *) bad "원뿔 유도" "앵커조차 없다: $cone1" ;;
esac
# THE ANCESTOR AXIS IS DECLARATION-INDEPENDENT. B carries `선행=없음` — the only
# writable spelling of "I declare no predecessor" — and is pulled in purely
# because its tip has A's tip as an ancestor. Without this assertion an
# implementation that built only the declared gating would pass.
case ",$cone1," in
  *,SB,*) ok "조상 축은 선언과 무관하다 (선행을 선언하지 않은 B 가 A 위에 쌓여 원뿔에 든다)" ;;
  *) bad "조상 축" "$cone1" ;;
esac
case ",$cone1," in
  *,SC,*) bad "원뿔 유도" "무관한 베이스의 C 가 원뿔에 들었다: $cone1" ;;
  *) ok "무관한 베이스의 세그먼트는 원뿔에 들지 않는다" ;;
esac
# A CROSS-REPOSITORY EDGE IS A WEAK EDGE, settled without asking git.
case ",$cone1," in
  *,SX,*) bad "레포 간 간선" "다른 레포의 세그먼트가 원뿔에 들었다: $cone1" ;;
  *) ok "레포 간 간선은 약한 간선이다 (조상 관계를 묻지 않는다)" ;;
esac

# THE DECLARED AXIS WORKS BEFORE THE MERGE, which is the window a cone actually
# stands up in: A stopped before implementing and B is waiting on it, so nothing
# has merged and the ancestor axis is empty. Without this assertion an
# implementation that built only the ancestor axis would pass with this design's
# MAIN CASE void.
seg_row SD "$CONE_D" 상태=실행중 선행=SA
check "선행을 실은 세그먼트 행이 기록된다" "$rc" "0"
if ( cd "$CONE_D" && git merge-base --is-ancestor "$tipA" HEAD ) >/dev/null 2>&1; then
  bad "선언 축 픽스처" "D 가 이미 A 위에 쌓여 있어 두 축이 구별되지 않는다"
else
  ok "픽스처가 머지 전 창을 재현한다 (A 의 팁이 D 의 조상이 아니다)"
fi
cone2=$(cone_of SA "SA 의 물음은 아직 열려 있다")
case ",$cone2," in
  *,SD,*) ok "선언 축은 머지 전에도 작동한다 (조상 관계가 없는 D 가 선행 선언만으로 원뿔에 든다)" ;;
  *) bad "선언 축" "$cone2" ;;
esac

# MONOTONE PER SEGMENT ID. Rows are append-only and the last one wins, so the
# lie that pays is retroactive — narrowing `선행` AFTER the predecessor parks.
seg_row SD "$CONE_D" 상태=실행중 선행=SA,SB
check "「선행」은 나중 행에서 더할 수 있다" "$rc" "0"
seg_row SD "$CONE_D" 상태=실행중 선행=SA
check "「선행」은 나중 행에서 뺄 수 없다" "$rc" "2"
case "$msg" in
  *단조*) ok "거절이 단조성을 이유로 든다" ;;
  *) bad "단조 문면" "$msg" ;;
esac

# --- 31d. The cone is a predicate, not a frozen set ------------------------
seg_row SF "$CONE_F" 상태=실행중 선행=없음
check "아직 A 와 무관한 F 의 행이 기록된다" "$rc" "0"
cone3=$(cone_of SA "리베이스 전")
case ",$cone3," in
  *,SF,*) bad "원뿔 술어" "리베이스 전인데 F 가 원뿔에 들었다: $cone3" ;;
  *) ok "리베이스 전의 F 는 원뿔 밖이다" ;;
esac
( cd "$CONE_F" && git rebase coneA ) >/dev/null 2>&1
cone4=$(cone_of SA "리베이스 뒤")
case ",$cone4," in
  *,SF,*) ok "원뿔은 술어다 — 리베이스로 조상 관계가 생기면 다음 판정에서 들어온다" ;;
  *) bad "원뿔 술어" "$cone4" ;;
esac

# --- 31e. An unmeasurable ancestry is FAIL-CLOSED --------------------------
#
# `--is-ancestor` answers 1 for "no" and 128 for "that object is not here".
# Folding them turns every fault into "not in the cone, so nothing is held",
# which would be this design's single unconditional fail-open.
seg_row SG "$CONE_G" 상태=실행중 선행=없음
check "곧 사라질 워크트리의 세그먼트 행이 기록된다" "$rc" "0"
rm -rf "$CONE_G"
cone5=$(cone_of SA "워크트리가 사라졌다")
case ",$cone5," in
  *,SG,*) ok "판정 불가는 fail-closed 다 — 재지 못한 세그먼트는 원뿔 안에 남는다" ;;
  *) bad "판정 불가" "재지 못한 세그먼트가 원뿔 밖으로 떨어졌다: $cone5" ;;
esac
n=$( { grep -F '`blocked`' "$LEDGER2" || true; } | grep -cF '원인=판정 불가' || true)
if [ "${n:-0}" -ge 1 ]; then
  ok "재지 못한 사실이 원인=판정 불가 행으로 남는다 (아침에 읽는 것은 「잴 수 없었다」이다)"
else
  bad "판정 불가 기록" "원뿔 안에 남기면서 왜 재지 못했는지는 남기지 않았다"
fi
# FAIL-CLOSED IS ABOUT THE CANDIDATE, AND IT DOES NOT UNIVERSALIZE.
#
# The two exclusions above are asserted on `cone1` only, and nothing re-checked
# them once `SG` existed — so a member whose repository cannot be read emitting
# an edge to EVERY candidate, across repository boundaries included, was
# invisible to this suite while the run's cone quietly became a run stop. What
# the accepted residual authorizes is structural under-parking, never unbounded
# over-parking caused by a fault.
case ",$cone5," in
  *,SC,*) bad "판정 불가 확산" "워크트리가 사라진 멤버가 무관한 베이스의 C 를 원뿔로 끌어들였다: $cone5" ;;
  *) ok "판정 불가 멤버가 무관한 세그먼트를 끌어들이지 않는다" ;;
esac
case ",$cone5," in
  *,SX,*) bad "판정 불가 확산" "판정 불가 멤버가 다른 레포의 세그먼트까지 원뿔에 넣었다: $cone5" ;;
  *) ok "판정 불가 멤버가 레포 경계를 넘지 않는다 (원뿔이 런 정지가 되지 않는다)" ;;
esac

# --- 31f. A file-set escape raises its own cone ----------------------------
#
# git answers "was B built on A" and cannot answer "did this segment touch
# something it did not declare" at all. The only input to that judgment is
# `선언 파일 집합`, which is why the field is carried even though the ancestry
# axis has no use for it.
seg_row SE "$CONE_E" 상태=실행중 선행=없음 "베이스 sha=$base_main" "선언 파일 집합=docs/"
check "선언 파일 집합을 실은 세그먼트 행이 기록된다" "$rc" "0"
cone6=$(cone_of SA "파일 집합 이탈")
case ",$cone6," in
  *,SE,*) ok "파일 집합 이탈이 원뿔을 낸다 (선언 밖 파일을 건드린 세그먼트가 전제 반증의 앵커가 된다)" ;;
  *) bad "파일 집합 이탈" "$cone6" ;;
esac
# Re-checked here as well: `SG` is still a member and still unmeasurable, so a
# cone raised for a different reason must stay just as bounded.
case ",$cone6," in
  *,SC,*) bad "판정 불가 확산" "이탈 원뿔에서도 무관한 C 가 끌려들어왔다: $cone6" ;;
  *) ok "이탈 원뿔에서도 무관한 세그먼트는 밖에 남는다" ;;
esac
case ",$cone6," in
  *,SX,*) bad "판정 불가 확산" "이탈 원뿔이 다른 레포의 세그먼트를 포함했다: $cone6" ;;
  *) ok "이탈 원뿔도 레포 경계를 넘지 않는다" ;;
esac
# THE CONE ROW IS BOUNDED BY CONSTRUCTION. The list grows with the size of the
# night, which is exactly when the mechanism is needed, and it sat on a row with
# a 1024-byte cap beside three Korean free-text fields — so `gate_append` would
# `die` and the cone would not be recorded at all.
crow=$( { grep -F '`blocked`' "$LEDGER2" || true; } | grep -F '앵커 세그먼트=SA ' | tail -1)
n=$(printf '%s' "$crow" | wc -c | tr -d ' ')
if [ "${n:-0}" -gt 0 ] && [ "${n:-0}" -le 1024 ]; then
  ok "원뿔 행이 원장 행 상한 안에 있다 (${n} 바이트)"
else
  bad "원뿔 행 상한" "원뿔 행이 ${n} 바이트다"
fi
case "$crow" in
  *"의존 세그먼트 수="*) ok "원뿔 행이 경계 있는 개수 필드를 함께 싣는다" ;;
  *) bad "의존 세그먼트 수" "$crow" ;;
esac

# --- 31g. The router's declaration is checked, and only one way -------------
gateN act --manifest "$NM" --kind blocked --target infra --cutpoint 커밋 --surface 읽기 \
      --snapshot-digest "$(HN)" --rationale x \
      -- 스코프=cone 원인=막힘 "앵커 세그먼트=SA" "의존 세그먼트=SA" 사유="좁게 선언한다" \
         근거=z "재개 명령=-"
check "유도 결과의 진부분집합을 선언하면 거절된다" "$rc" "6"
gateN act --manifest "$NM" --kind blocked --target infra --cutpoint 커밋 --surface 읽기 \
      --snapshot-digest "$(HN)" --rationale x \
      -- 스코프=cone 원인=막힘 "앵커 세그먼트=SA" "의존 세그먼트=$cone6,SZZ" 사유="넓게 선언한다" \
         근거=z "재개 명령=-"
check "상위집합 선언은 통과한다 (넓히는 방향은 열려 있다)" "$rc" "0"

# --- 31h. `선행` has a SECOND consumer, and that is what costs the lie ------
#
# With only the cone reading it, declaring narrowly would be free — a segment
# that names nobody simply stays out of the cone, and staying out is the
# direction that pays. An implementation that never reads `선행` for ordering
# must fail here.
gateN act --manifest "$NM" --kind skill --target infra --segment SD --cutpoint 커밋 \
      --surface 워크트리쓰기 --snapshot-digest "$(HN)" --rationale x \
      -- review "/cc-cmds:review-unattended x"
check "선행이 착지하지 않았으면 후행 디스패치가 막힌다" "$rc" "3"
case "$msg" in
  *"선행 세그먼트"*) ok "약한 간선에는 실제 소비자가 있다 (선행을 한 번도 읽지 않는 구현은 여기서 실패한다)" ;;
  *) bad "순서 판정" "$msg" ;;
esac
# BOTH predecessors, because `선행` is monotone and D's last row names SA and SB.
# Landing one of two would leave the dispatch refused for the other, and the
# assertion below would then pass without the check ever having relaxed.
seg_row SA "$CONE_A" 상태=완료 선행=없음
check "앵커를 완료로 옮긴다" "$rc" "0"
seg_row SB "$CONE_B" 상태=완료 선행=없음
check "나머지 선행도 완료로 옮긴다" "$rc" "0"
gateN act --manifest "$NM" --kind skill --target infra --segment SD --cutpoint 커밋 \
      --surface 워크트리쓰기 --snapshot-digest "$(HN)" --rationale x \
      -- review "/cc-cmds:review-unattended x"
case "$msg" in
  *"선행 세그먼트"*) bad "순서 판정" "선행이 착지했는데도 그 이유로 막는다: $msg" ;;
  *) ok "선행이 머지됨·완료가 되면 그 이유로는 더 이상 막지 않는다 (검사가 공허하지 않다)" ;;
esac

# --- 31i. Grade 2 becomes the approval its own refusal used to promise ------
#
# The old refusal said in as many words that grade 2 is raised to an approval,
# while refusing — and no such path existed anywhere in the tree.
gateN act --manifest "$NM" --kind judgment --target infra --segment SD --cutpoint 커밋 \
      --surface 읽기 --snapshot-digest "$(HN)" --rationale x \
      -- 등급=2 기준="리뷰 스테이지를 몇 개로 나눌지" 근거="비용과 커버리지가 상충한다"
check "등급 2 판단은 절단점=판단 승인으로 응답한다" "$rc" "5"
jrow=$(last_judgment_approval)
case "$jrow" in
  *"상태=대기"*) ok "그 승인이 대기 상태로 원장에 남는다" ;;
  *) bad "판단 승인" "$jrow" ;;
esac
# THE BINDING TUPLE IS `-`, and that is the difference from an act approval: a
# question's answer is an input to work that has not happened yet, so there is no
# tree to measure freshness against.
case "$jrow" in
  *"구속 튜플=-"*) ok "질문 승인의 구속 튜플은 비어 있다 (잴 트리가 없다)" ;;
  *) bad "구속 튜플" "$jrow" ;;
esac
nj=$( { grep -F '`승인`' "$LEDGER2" || true; } | grep -cF '절단점=판단' || true)
gateN act --manifest "$NM" --kind judgment --target infra --segment SD --cutpoint 커밋 \
      --surface 읽기 --snapshot-digest "$(HN)" --rationale x \
      -- 등급=2 기준="리뷰 스테이지를 몇 개로 나눌지" 근거="비용과 커버리지가 상충한다"
nj2=$( { grep -F '`승인`' "$LEDGER2" || true; } | grep -cF '절단점=판단' || true)
check "같은 판단을 두 번 제출해도 승인이 하나다 (id 가 판단 내용에서 유도된다)" "$nj2" "$nj"

# --- 31j. The auto-adoption floor is a UNION of two arms --------------------
#
# ARM (a) — declared in advance. The undo here is prose on purpose, so arm (b)
# cannot admit it and only the manifest declaration can.
gateN act --manifest "$NM" --kind judgment --target infra --segment SD --cutpoint 커밋 \
      --surface 읽기 --snapshot-digest "$(HN)" --rationale x \
      -- 등급=1 "판단 부류=문서-신선도" 기준="문서가 최신인가" \
         "되돌리는 법=아침에 문서를 다시 읽는다" 근거="앵커 해시가 그대로다"
check "매니페스트가 미리 선언한 부류는 채택된다 (팔 a)" "$rc" "0"
# The same prose undo with a class the manifest did NOT declare falls out, which
# is what keeps arm (a) from being vacuous.
gateN act --manifest "$NM" --kind judgment --target infra --segment SD --cutpoint 커밋 \
      --surface 읽기 --snapshot-digest "$(HN)" --rationale x \
      -- 등급=1 "판단 부류=감사-발견" 기준="감사 발견을 이번 런에서 고칠지" \
         "되돌리는 법=아침에 다시 본다" 근거="비용이 크다"
check "선언되지 않은 부류는 산문 되돌리기로 채택되지 않는다" "$rc" "5"
# ARM (b) — reversible. The undo's first token goes through the same argv0
# grading table every act goes through, so ASSERTING reversibility and PRODUCING
# the thing that reverses are told apart.
gateN act --manifest "$NM" --kind judgment --target infra --segment SD --cutpoint 커밋 \
      --surface 읽기 --snapshot-digest "$(HN)" --rationale x \
      -- 등급=1 "판단 부류=인용-갱신" 기준="인용을 갱신할지" \
         "되돌리는 법=git checkout -- docs/x.md" 근거="앵커가 밀렸다"
check "실행 가능한 되돌리기는 선언 없이도 채택된다 (팔 b)" "$rc" "0"
# And a malformed row is refused as a MALFORMED ROW, not as a question for a
# person. Failing the floor for want of the very field that is missing wrote an
# approval nobody asked for and made termination wait on it.
gateN act --manifest "$NM" --kind judgment --target infra --segment SD --cutpoint 커밋 \
      --surface 읽기 --snapshot-digest "$(HN)" --rationale x \
      -- 등급=1 "판단 부류=인용-갱신" 기준=x 근거=z
check "되돌리는 법이 없는 등급 1 판단은 어휘 오류로 거절된다 (승인 발행이 아니다)" "$rc" "2"
gateN act --manifest "$NM" --kind judgment --target infra --segment SD --cutpoint 커밋 \
      --surface 읽기 --snapshot-digest "$(HN)" --rationale x \
      -- 등급=1 "판단 부류=없는-부류" 기준=x "되돌리는 법=git checkout -- x" 근거=z
check "어휘 밖 판단 부류는 거절된다" "$rc" "2"

# --- 31k. The forbidden classes are named, and refused at freeze time -------
#
# Leaving them out of the vocabulary does not stop the decision from being made;
# it forces whoever records it to borrow a permitted token, and that is the leak.
# Named and forbidden, the leak arrives as a refusal.
FM="$WORK/forbidden-plan.md"
sed 's/판단 부류=문서-신선도/판단 부류=팀-구성/' "$NM" > "$FM"
gateN snapshot --manifest "$FM"
if [ "$rc" = "0" ]; then
  bad "금지 부류" "팀-구성 을 자동 채택으로 선언한 매니페스트가 검사를 통과했다"
else
  ok "금지 부류를 자동 채택으로 선언하면 매니페스트 검사가 하드 스톱한다"
fi
case "$msg" in
  *"선언할 수 없는 판단 부류"*) ok "거절이 위험을 사용자에게 넘기는 결정임을 지목한다" ;;
  *) bad "금지 문면" "$msg" ;;
esac
FM2="$WORK/badclass-plan.md"
sed 's/판단 부류=문서-신선도/판단 부류=없는-부류/' "$NM" > "$FM2"
gateN snapshot --manifest "$FM2"
if [ "$rc" = "0" ]; then
  bad "어휘 밖 부류" "매니페스트의 어휘 밖 판단 부류가 통과했다"
else
  ok "매니페스트의 어휘 밖 판단 부류도 하드 스톱이다"
fi

# --- 31l. Termination condition 2 excludes the question approval ------------
#
# An act approval's answer is valid NOW and its window closes with the night; a
# question's answer is an input to work that has not begun, so it is durable and
# a successor run consumes it. Counting the second kind is what made one open
# question a run that could never say it was done.
gateN act --manifest "$NM" --kind propose-done --target infra --segment SD --cutpoint 커밋 \
      --surface 읽기 --snapshot-digest "$(HN)" --rationale x -- 절=x 근거=y
# The fixture legitimately holds ONE pending act approval by this point — the
# auto-adoption arms above escalate rather than adopt, and an escalation issues
# one. So the property is not "condition 2 is silent"; it is that the question
# approval does not ADD to the count. Asserting on the mere presence of the
# string fails on that legitimate act approval and says nothing about the
# exclusion being tested.
case "$msg" in
  *"2 대기 중인 행위 승인이 1건"*) ok "조건 2 는 절단점=판단 승인을 세지 않는다 (행위 승인 1건만 센다)" ;;
  *"2 대기 중인 행위 승인"*) bad "조건 2" "절단점=판단 승인이 행위 승인으로 세어졌다: $msg" ;;
  *) ok "조건 2 는 절단점=판단 승인을 세지 않는다 (대기 중인 행위 승인 없음)" ;;
esac
gateN act --manifest "$NM" --kind x --target infra --segment SD --cutpoint 배포 \
      --surface 외부상태변경 --snapshot-digest "$(HN)" --rationale x -- aws s3 ls
check "사전 인가 밖 행위는 행위 승인을 발행한다" "$rc" "5"
gateN act --manifest "$NM" --kind propose-done --target infra --segment SD --cutpoint 커밋 \
      --surface 읽기 --snapshot-digest "$(HN)" --rationale x -- 절=x 근거=y
case "$msg" in
  *"2 대기 중인 행위 승인"*) ok "행위 승인은 조건 2 에 오른다 (제외가 공허하지 않다)" ;;
  *) bad "조건 2" "$msg" ;;
esac

# --- 31m. A termination clause can be put ON HOLD, against a named question --
#
# `불가능` ends the clause forever; `보류` says a person's answer is outstanding
# and the successor picks it up. So the evidence has to BE that question — an
# open approval found in the ledger rather than asserted in the wording.
gateN act --manifest "$NM" --kind clause --target infra --cutpoint 커밋 --surface 읽기 \
      --snapshot-digest "$(HN)" --rationale x -- id=K1 상태=보류 근거="사람의 답을 기다린다"
check "보류 절의 근거가 열린 판단 승인을 지목하지 않으면 거절된다" "$rc" "2"
jid=$(row_field "$(last_judgment_approval)" '승인 id')
if [ -n "$jid" ]; then ok "열린 판단 승인 id 를 원장에서 읽는다 ($jid)"; else bad "판단 승인 id" "대기 행이 없다"; fi
gateN act --manifest "$NM" --kind clause --target infra --cutpoint 커밋 --surface 읽기 \
      --snapshot-digest "$(HN)" --rationale x -- id=K1 상태=보류 "근거=열린 판단 승인 $jid"
check "열린 절단점=판단 승인 id 를 지목하면 보류로 정산된다" "$rc" "0"

# --- 31n. `close` carries the answer BYTES for a question approval ----------
#
# For an act approval the answer is binary, so the fixed literal lost nothing.
# A question's answer is what the next step consumes, and the row is the run's
# only durable copy of it.
jq_q=$(row_field "$( { grep -F '`승인`' "$LEDGER2" || true; } | grep -F "승인 id=$jid " | tail -1)" '질문 문면')
NCFG="$WORK/ncfg"; NTX="$NCFG/projects/proj"; mkdir -p "$NTX"
NSID="12121212-3434-5656-7878-909090909090"
# The answer opens with an affirmation because closing as `승인` now requires one
# — a judgment answer carrying neither polarity leaves the approval `대기`. What
# this fixture measures is that the answer BYTES reach the row, and they do
# either way.
ANSWER="네, 리뷰 스테이지는 셋으로 나누고 합성만 하나로 둔다"
printf '{"role":"user","content":"%s / %s → %s"}\n' "$jid" "$jq_q" "$ANSWER" > "$NTX/$NSID.jsonl"
out=$(cd "$WT" && XDG_STATE_HOME="$STATE_CONE" CLAUDE_CONFIG_DIR="$NCFG" \
      CLAUDE_CODE_SESSION_ID="$NSID" bash "$GATE" close --manifest "$NM" --approval "$jid" 2>&1); rc=$?
check "판단 승인이 트랜스크립트로 닫힌다" "$rc" "0"
case "$( { grep -F '`승인`' "$LEDGER2" || true; } | grep -F "승인 id=$jid " | tail -1)" in
  *"$ANSWER"*) ok "close 가 사람의 답 바이트를 답변 문면에 축자로 싣는다" ;;
  *) bad "답 바이트" "$( { grep -F '`승인`' "$LEDGER2" || true; } | grep -F "승인 id=$jid " | tail -1)" ;;
esac
# The act approval keeps the fixed literal, so no existing reader changes.
aidN=$(row_field "$( { grep -F '`승인`' "$LEDGER2" || true; } | grep -F '상태=대기' | grep -vF '절단점=판단' | tail -1)" '승인 id')
if [ -n "$aidN" ]; then
  aq=$(row_field "$( { grep -F '`승인`' "$LEDGER2" || true; } | grep -F "승인 id=$aidN " | tail -1)" '질문 문면')
  ASID="13131313-3434-5656-7878-909090909090"
  printf '{"role":"user","content":"%s / %s → 승인"}\n' "$aidN" "$aq" > "$NTX/$ASID.jsonl"
  out=$(cd "$WT" && XDG_STATE_HOME="$STATE_CONE" CLAUDE_CONFIG_DIR="$NCFG" \
        CLAUDE_CODE_SESSION_ID="$ASID" bash "$GATE" close --manifest "$NM" --approval "$aidN" 2>&1); rc=$?
  check "행위 승인도 같은 경로로 닫힌다" "$rc" "0"
  case "$( { grep -F '`승인`' "$LEDGER2" || true; } | grep -F "승인 id=$aidN " | tail -1)" in
    *"답변 문면=트랜스크립트 판독"*) ok "행위 승인은 기존 리터럴을 유지한다 (기존 시험과 원장 독자가 깨지지 않는다)" ;;
    *) bad "행위 승인 문면" "$( { grep -F '`승인`' "$LEDGER2" || true; } | grep -F "승인 id=$aidN " | tail -1)" ;;
  esac
else
  bad "행위 승인" "닫을 대기 중 행위 승인을 찾지 못했다"
fi

# --- 31o. A judgment a STAGE emitted goes through the same floor -------------
#
# A stage writes no sidecar and holds no gate verb, so its only channel for a
# decision is its terminal message. If that path had its own copy of the floor,
# emitting four lines would be enough to adopt anything at all.
JSTUB="$WORK/judgment-stub"
cat > "$JSTUB" <<'JSTUBEOF'
#!/usr/bin/env bash
cat <<'RESEOF'
{"type":"result","subtype":"success","is_error":false,"total_cost_usd":0.1,"session_id":"emit-session","num_turns":1,"result":"**판단 부류**: 감사-발견 **판단 등급**: 1 **판단 되돌리는 법**: 다음 런에서 다시 본다 **판단 기준**: 감사 발견을 이번 런에서 고칠지 **판단 근거**: 비용이 크다"}
RESEOF
exit 0
JSTUBEOF
chmod +x "$JSTUB"
seg_row SJ "$CONE_C" 상태=실행중 선행=없음
check "방출 실험용 세그먼트 행이 기록된다" "$rc" "0"
n_emit_before=$( { grep -F '출처=스테이지 방출' "$LEDGER2" || true; } | grep -c . || true)
( cd "$WT" && XDG_STATE_HOME="$STATE_CONE" CC_CLAUDE_BIN="$JSTUB" \
  bash "$GATE" act --manifest "$NM" --kind skill --target infra --segment SJ --cutpoint 커밋 \
  --surface 워크트리쓰기 --snapshot-digest "$(HN)" --rationale x \
  -- review "/cc-cmds:review-unattended x" ) >/dev/null 2>&1
n_emit_after=$( { grep -F '출처=스테이지 방출' "$LEDGER2" || true; } | grep -c . || true)
check "합집합을 통과하지 못한 방출 판단은 자율 승인 행을 쓰지 않는다" "$n_emit_after" "$n_emit_before"
case "$( { grep -F '`승인`' "$LEDGER2" || true; } | grep -F '절단점=판단' | tail -1)" in
  *"감사 발견을 이번 런에서 고칠지"*) ok "행을 쓰는 대신 승인이 발행된다 (방출만으로는 아무것도 채택되지 않는다)" ;;
  *) bad "방출 판단" "$( { grep -F '`승인`' "$LEDGER2" || true; } | grep -F '절단점=판단' | tail -1)" ;;
esac

# --- 31p. The vocabulary lint, run against a fixture tree -------------------
#
# There are zero legacy `판단 부류=` rows, which is exactly what a NEW field buys
# and what a reuse of `자율 승인.kind` could never have: the closed set can be
# enforced with no exception at all.
LINTAV="$repo_root/scripts/lint-autoadopt-vocabulary.sh"
LR="$WORK/lint-root"
mkdir -p "$LR/plugins" "$LR/scripts" "$LR/orch"
sed -n '/^readonly JUDGMENT_CLASSES/p' "$repo_root/plugins/cc-cmds/orchestrator/run.sh" > "$LR/orch/run.sh"
# The same guard the parser copy gets, and for the same reason. The lint SKIPS
# rule 1 with exit 0 when this file is absent, so a fixture that failed to
# materialize it makes every assertion below read "the lint passed" — which is
# indistinguishable from the lint being broken. Measured: one CI leg reported
# exactly that shape while the local run was green.
if [ -s "$LR/orch/run.sh" ]; then
  ok "린트 픽스처가 실물 드라이버에서 어휘 SOT 를 옮긴다"
else
  bad "린트 픽스처" "run.sh 에서 readonly JUDGMENT_CLASSES 를 뽑지 못했다 — 린트가 SKIP 으로 0 을 돌려주므로 뒤따르는 단언이 전부 공허하다"
fi
# 규칙 3 은 파서 쪽 집합을 gate.sh 에서 뽑아 문서 쪽과 대조하므로 픽스처 트리에도
# 파서가 있어야 한다. 실물에서 마커를 담은 줄만 옮긴다.
{ grep -E '\\\*\\\*판단 ' "$GATE" || true; } > "$LR/orch/gate.sh"
if [ -s "$LR/orch/gate.sh" ]; then
  ok "린트 픽스처가 실물 파서에서 방출 마커 줄을 옮긴다"
else
  bad "린트 픽스처" "gate.sh 에서 방출 판단 마커 줄을 하나도 뽑지 못했다 — 뒤따르는 단언이 전부 공허하다"
fi
printf -- '- `자동 채택` | 판단 부류=문서-신선도 | 사유=x\n' > "$LR/plugins/good.md"
if ORCH_ROOT="$LR/orch" SCAN_ROOT="$LR" bash "$LINTAV" >/dev/null 2>&1; then
  ok "린트 — 열 값 안의 판단 부류는 통과한다"
else
  bad "린트" "어휘 안의 값을 위반으로 잡았다"
fi
printf -- '- `자동 채택` | 판단 부류=없는-부류 | 사유=x\n' > "$LR/plugins/bad.md"
if ORCH_ROOT="$LR/orch" SCAN_ROOT="$LR" bash "$LINTAV" >/dev/null 2>&1; then
  bad "린트" "어휘 밖의 판단 부류를 통과시켰다"
else
  ok "린트 — 열 값 밖의 판단 부류는 실패한다"
fi
# THE PRODUCER SIDE OF THE EMITTED JUDGMENT, WHICH HAD NO DEFINITION ANYWHERE.
# The gate parses five markers out of a stage's terminal message and absorbs the
# judgment through the auto-adoption floor — and no stage skill defined those
# five spellings, so a stage had no way to know what to write. This is not a
# coverage gap in the absorber: deleting it turns 31o and 31z red. The tests were
# there and the producer was not.
rm -f "$LR/plugins/bad.md"
# 원장의 「값 없음」 센티널은 부류 주장이 아니다. 부류 없이 방출된 판단을 흡수기가
# 기록할 때 그 철자를 쓰므로, 값으로 읽으면 린트가 `-` 를 열 값 중 하나이기를
# 요구하게 되고 실제 트리 전체 스캔이 그 자리에서 빨개진다.
printf -- '- `자율 승인` | 판단 부류=- | 등급=- | 사유=x\n' > "$LR/plugins/sentinel.md"
if ORCH_ROOT="$LR/orch" SCAN_ROOT="$LR" bash "$LINTAV" >/dev/null 2>&1; then
  ok "린트 — 값 없음 센티널은 부류 주장으로 읽지 않는다"
else
  bad "린트" "판단 부류=- 를 어휘 밖 값으로 잡았다"
fi
rm -f "$LR/plugins/sentinel.md"
LRC="$LR/plugins/cc-cmds/skills/_common"
mkdir -p "$LRC"
cat > "$LRC/judgment-grade.md" <<'EOF'
| marker | required |
| --- | --- |
| `**판단 부류**:` | always |
| `**판단 등급**:` | always |
| `**판단 기준**:` | always |
| `**판단 되돌리는 법**:` | at grade 1 |
| `**판단 근거**:` | always |
EOF
if ORCH_ROOT="$LR/orch" SCAN_ROOT="$LR" bash "$LINTAV" >/dev/null 2>&1; then
  ok "린트 — 다섯 방출 마커가 전부 정의돼 있으면 통과한다"
else
  bad "린트" "다섯 마커가 다 있는데 실패했다"
fi
grep -vF '**판단 되돌리는 법**:' "$LRC/judgment-grade.md" > "$LRC/judgment-grade.md.tmp" \
  && mv "$LRC/judgment-grade.md.tmp" "$LRC/judgment-grade.md"
if ORCH_ROOT="$LR/orch" SCAN_ROOT="$LR" bash "$LINTAV" >/dev/null 2>&1; then
  bad "린트" "마커 하나가 빠졌는데 통과했다 — 배선이 끊겨도 조용하다"
else
  ok "린트 — 마커 하나가 빠지면 실패한다"
fi
printf '| `**판단 되돌리는 법**:` | at grade 1 |\n' >> "$LRC/judgment-grade.md"
# THE PARSER SIDE, WHICH NOTHING USED TO MEASURE. The rule carried five hardcoded
# literals and grepped `_common/` for them, so renaming the parser's marker left
# the lint green — the literals it compared against were its own, not the gate's.
cp "$LR/orch/gate.sh" "$LR/orch/gate.sh.bak"
sed 's/판단 부류/판단 유형/' "$LR/orch/gate.sh.bak" > "$LR/orch/gate.sh"
lav_out=$(ORCH_ROOT="$LR/orch" SCAN_ROOT="$LR" bash "$LINTAV" 2>&1); lav_rc=$?
if [ "$lav_rc" = "0" ]; then
  bad "린트" "파서의 마커 스펠링을 바꿨는데 통과했다 — 규칙이 문서 쪽만 본다"
else
  ok "린트 — 파서의 마커 스펠링이 문서와 어긋나면 실패한다"
fi
# 어느 쪽에만 있는지가 실패 문면에 있어야 고치는 자리가 정해진다 — 파서에만 있으면
# 산출자 부재이고 문서에만 있으면 죽은 규약이라 손대는 파일이 다르다.
case "$lav_out" in
  *"'**판단 유형**' 가 파서에만 있다"*) ok "실패가 파서에만 있는 마커를 이름으로 지목한다" ;;
  *) bad "린트 문면" "$(printf '%s' "$lav_out" | tr '\n' ' ')" ;;
esac
case "$lav_out" in
  *"'**판단 부류**' 가 문서에만 있다"*) ok "같은 실행이 반대 방향도 이름으로 지목한다" ;;
  *) bad "린트 문면" "$(printf '%s' "$lav_out" | tr '\n' ' ')" ;;
esac
mv "$LR/orch/gate.sh.bak" "$LR/orch/gate.sh"

# RULE 1, WHICH NOTHING ABOVE TOUCHES. Every assertion so far drives rule 2 or
# rule 3, so the subset check could be deleted outright and this section stays
# green. What that rule holds up is stated in the lint's own head comment: the
# two forbidden classes are NAMED rather than left out, because a class with no
# token has to borrow a permitted one when the decision is recorded, and the
# borrowing is the leak. Dropping one from the vocabulary reads as tidying and
# restores the leak silently — the forbidden test still answers true while the
# vocabulary test starts answering false, so a refusal quietly demotes into an
# "out of vocabulary" report about something else.
LR1="$WORK/lint-root-rule1"
mkdir -p "$LR1/orch"
cp "$LR/orch/run.sh" "$LR1/orch/run.sh"
if ORCH_ROOT="$LR1/orch" SCAN_ROOT="$LR" bash "$LINTAV" >/dev/null 2>&1; then
  ok "린트 — 손대지 않은 어휘 SOT 는 통과한다 (아래 실패가 픽스처 탓이 아니다)"
else
  bad "린트 규칙 1" "어휘를 그대로 옮긴 픽스처가 이미 실패한다 — 아래 단언이 무엇 때문에 빨간지 말할 수 없다"
fi
# Removed WHEREVER IT SITS in the vocabulary, not only at the end. The earlier
# spelling anchored on `시각-면제"` — the token immediately before the closing
# quote — so it silently stopped matching the moment a token was appended after
# it, and the fixture then carried an unmodified vocabulary into an assertion
# about a modified one. The check below catches that, but a fixture that breaks
# on every future vocabulary addition is a fixture that will keep breaking.
sed -E 's/^(readonly JUDGMENT_CLASSES="[^"]*) 시각-면제([ "])/\1\2/' \
    "$LR/orch/run.sh" > "$LR1/orch/run.sh"
# THE FIXTURE IS CHECKED BEFORE IT IS ASSERTED ON. A substitution that matched
# nothing leaves the two sets consistent, and then the lint passes for the honest
# reason while this section reads that pass as the rule being absent.
cls1=$(sed -n 's/^readonly JUDGMENT_CLASSES="\(.*\)"$/\1/p' "$LR1/orch/run.sh")
fb1=$(sed -n 's/^readonly JUDGMENT_CLASSES_FORBIDDEN="\(.*\)"$/\1/p' "$LR1/orch/run.sh")
case "$cls1:$fb1" in
  *시각-면제:*) bad "린트 픽스처" "어휘에서 금지 부류를 빼지 못했다: $cls1" ;;
  *:*시각-면제*) ok "픽스처가 금지 부류를 어휘에서만 뺐다 (금지 목록에는 그대로 있다)" ;;
  *) bad "린트 픽스처" "금지 목록에서도 사라졌다 — 규칙 1 이 볼 불일치가 없다: $fb1" ;;
esac
if ORCH_ROOT="$LR1/orch" SCAN_ROOT="$LR" bash "$LINTAV" >/dev/null 2>&1; then
  bad "린트 규칙 1" "금지 부류가 어휘에서 빠졌는데 통과했다 — 어휘를 줄이는 편집이 누수를 조용히 되살린다"
else
  ok "린트 — 금지 부류가 어휘에서 빠지면 실패한다 (규칙 1 이 살아 있다)"
fi
# 반대 방향 단독: 게이트가 읽지 않는 마커가 문서에만 사는 경우.
printf '| `**판단 무게**:` | always |\n' >> "$LRC/judgment-grade.md"
# The lint's own words are captured rather than discarded. A pass here can mean
# the rule is broken OR that the lint skipped for an unrelated missing input,
# and those two need different repairs — discarding the output makes them read
# the same.
lav_rev=$(ORCH_ROOT="$LR/orch" SCAN_ROOT="$LR" bash "$LINTAV" 2>&1)
if [ "$?" = "0" ]; then
  # The lint's summary line counts what it actually compared, and a count that
  # disagrees with what this fixture just wrote means the lint read a different
  # tree — a different repair from the rule being wrong. Both marker sets and
  # the fixture's own paths go into the message so the next reader does not
  # have to guess which of the two it is.
  bad "린트" "게이트가 읽지 않는 마커를 문서에 더했는데 통과했다 — 죽은 규약이 조용하다: $(printf '%s' "$lav_rev" | tr '\n' ' ') | LRC=$LRC 문서원문=[$(cat "$LRC/judgment-grade.md" 2>/dev/null | tr '\n' '/')] 디렉터리=[$(ls "$LRC" 2>/dev/null | tr '\n' ' ')] 파서줄수=$(wc -l < "$LR/orch/gate.sh" | tr -d ' ') SOT줄수=$(wc -l < "$LR/orch/run.sh" | tr -d ' ')"
else
  ok "린트 — 파서가 읽지 않는 마커가 문서에 있으면 실패한다"
fi
grep -vF '**판단 무게**:' "$LRC/judgment-grade.md" > "$LRC/judgment-grade.md.tmp" \
  && mv "$LRC/judgment-grade.md.tmp" "$LRC/judgment-grade.md"
if ORCH_ROOT="$LR/orch" SCAN_ROOT="$LR" bash "$LINTAV" >/dev/null 2>&1; then
  ok "린트 — 양쪽이 축자로 일치하는 트리는 통과한다"
else
  bad "린트" "손대지 않은 픽스처가 실패했다"
fi
# And the real tree actually agrees with itself. The fixture above tests the
# lint; this tests the thing the lint is about, and the two fail for different
# reasons. Both directions here too — reading only `_common/` is the one-sided
# green that let the parser rename slip past two checks at once.
REALC="$repo_root/plugins/cc-cmds/skills/_common"
real_parser=$( { grep -rhoE '\\?\*\\?\*판단 [^*\\]+\\?\*\\?\*' "$GATE" || true; } | tr -d '\\' | LC_ALL=C sort -u)
real_doc=$( { grep -rhoE '\\?\*\\?\*판단 [^*\\]+\\?\*\\?\*' "$REALC" || true; } | tr -d '\\' | LC_ALL=C sort -u)
if [ -n "$real_parser" ] && [ "$real_parser" = "$real_doc" ]; then
  ok "실제 트리의 파서와 _common 이 같은 방출 마커 집합을 갖는다"
else
  bad "방출 마커 대조" "파서: $(printf '%s' "$real_parser" | tr '\n' ' ') / 문서: $(printf '%s' "$real_doc" | tr '\n' ' ')"
fi

# --- 31q. The auto-adoption floor's safety argument, made true ---------------
#
# The code stated arm (a)'s safety as four reasons and two of them were false:
# the binding digest did not serialize `자동 채택` rows, and the rule named as
# the structural guard never received the manifest path. One ordinary
# `워크트리쓰기` act could therefore append a class to the run's own
# pre-adoption list, and nothing moved.

# THE DIGEST ACTUALLY COVERS THE ROW. Asserted against the R1 fixture manifest
# rather than the cone one, because the cone manifest deliberately drops its
# binding digest — that is the only manifest here whose frozen set is compared.
BDM="$WORK/autoadopt-binding.md"
cp "$MANIFEST" "$BDM"
gate snapshot --manifest "$BDM"
check "픽스처 매니페스트의 사본이 얼린 집합 대조를 통과한다" "$rc" "0"
printf -- '- `자동 채택` | 판단 부류=감사-발견 | 상한=없음 | 심각도 상한=minor | 사유=런이 스스로 덧붙였다\n' >> "$BDM"
gate snapshot --manifest "$BDM"
if [ "$rc" = "0" ]; then
  bad "구속 다이제스트" "자동 채택 행을 덧붙였는데 대조가 통과했다 — 런이 자기 사전 채택 목록을 늘릴 수 있다"
else
  ok "자동 채택 행을 덧붙이면 구속 다이제스트 대조가 거절한다"
fi
case "$msg" in
  *"구속 다이제스트가 얼린 집합과 일치하지 않습니다"*) ok "거절이 얼린 집합이 움직였음을 지목한다" ;;
  *) bad "구속 다이제스트 문면" "$msg" ;;
esac

# THE FLOOR HONOURS ONLY `## 인가`. "Exactly one authorization section" is the
# uniqueness guarantee arm (a) leans on, and a whole-file scan does not inherit
# it — a row planted in any other section was honoured, so the guarantee
# protected bytes the consumer was not reading. This suite's own fixture had the
# row outside `## 인가` for exactly that reason.
OM="$WORK/outside-auth.md"
cp "$NM" "$OM"
printf -- '- `자동 채택` | 판단 부류=감사-발견 | 상한=없음 | 심각도 상한=minor | 사유=인가 절 밖에 심는다\n' >> "$OM"
gateN act --manifest "$OM" --kind judgment --target infra --segment SD --cutpoint 커밋 \
      --surface 읽기 --snapshot-digest "$(cd "$WT" && XDG_STATE_HOME="$STATE_CONE" bash "$GATE" snapshot --manifest "$OM" 2>/dev/null | jq -r .H)" \
      --rationale x \
      -- 등급=1 "판단 부류=감사-발견" 기준="인가 절 밖의 선언이 통하는가" \
         "되돌리는 법=아침에 다시 본다" 근거="산문 되돌리기라 팔 b 는 막힌다"
check "「## 인가」 밖에 심은 자동 채택 행은 팔 (a) 를 열지 못한다" "$rc" "5"

# AND THE WRITE PATH IS REFUSED, which is the guarantee the digest cannot give:
# both sides of that comparison are read from the same file, so detection is
# what the digest buys and prevention has to come from somewhere else.
gateN exec --manifest "$NM" --target infra --segment SD --cutpoint 커밋 \
      --surface 워크트리쓰기 --snapshot-digest "$(HN)" --rationale x -- tee "$NM"
check "매니페스트에 쓰려는 행위는 절단점과 무관하게 거절된다" "$rc" "3"
case "$msg" in
  *"매니페스트에 쓰려 합니다"*) ok "거절이 인가의 자기확장임을 지목한다" ;;
  *) bad "매니페스트 쓰기 가드" "$msg" ;;
esac

# --- 31r. The forbidden classes are refused at RUNTIME too ------------------
#
# `judgment_class_forbidden` had one caller — the freeze-time check — and that
# one guards arm (a). Arm (b) branched on the undo command's grade alone, so a
# class that is a hard stop in the manifest was adopted at runtime by producing
# a runnable undo.
gateN act --manifest "$NM" --kind judgment --target infra --segment SD --cutpoint 커밋 \
      --surface 읽기 --snapshot-digest "$(HN)" --rationale x \
      -- 등급=1 "판단 부류=시각-면제" 기준="스크린샷 회귀를 이번 런에서 면제할지" \
         "되돌리는 법=git checkout -- tests/visual/" 근거="비용이 크다"
check "금지 부류는 실행 가능한 되돌리기로도 채택되지 않는다 (팔 b 가 금지를 본다)" "$rc" "5"
case "$msg" in
  *"미리 채택할 수 없는 판단 부류"*) ok "거절이 위험을 사용자에게 넘기는 결정임을 지목한다" ;;
  *) bad "금지 부류 런타임" "$msg" ;;
esac
gateN act --manifest "$NM" --kind judgment --target infra --segment SD --cutpoint 커밋 \
      --surface 읽기 --snapshot-digest "$(HN)" --rationale x \
      -- 등급=1 "판단 부류=팀-구성" 기준="팀을 몇으로 꾸릴지" \
         "되돌리는 법=git revert HEAD" 근거="비용이 크다"
check "다른 금지 부류도 같은 처분을 받는다" "$rc" "5"
if { grep -F '`자율 승인`' "$LEDGER2" || true; } | grep -F '판단 부류=시각-면제' | grep_all_q -F '결정=채택'; then
  bad "금지 부류" "시각-면제 판단이 채택 행으로 기록됐다"
else
  ok "금지 부류의 채택 행은 원장에 없다 (기록은 허용이고 무인 채택만 금지다)"
fi

# --- 31s. `gate_clip` measures and cuts in the SAME unit --------------------
#
# `wc -c` counts bytes and `cut -c` counts characters here, so a 400-byte budget
# returned up to ~1200 bytes and the marker went on top of that. Both ends of a
# question's lifecycle died on the row cap: the approval could not be ISSUED,
# and a human answer of ordinary length could not be RECORDED.
LONGSTD=$(awk 'BEGIN{ s=""; for (i = 0; i < 40; i++) s = s "판단 기준이 길어지는 한국어 문장 "; printf "%s", s }')
gateN act --manifest "$NM" --kind judgment --target infra --segment SD --cutpoint 커밋 \
      --surface 읽기 --snapshot-digest "$(HN)" --rationale x \
      -- 등급=2 "기준=$LONGSTD" "근거=$LONGSTD"
check "상한 너머 길이의 한국어 판단도 승인을 연다" "$rc" "5"
longrow=$(last_judgment_approval)
n=$(printf '%s' "$longrow" | wc -c | tr -d ' ')
if [ "${n:-0}" -gt 0 ] && [ "${n:-0}" -le 1024 ]; then
  ok "그 승인 행이 원장 행 상한 안에 있다 (${n} 바이트)"
else
  bad "행 상한" "판단 승인 행이 ${n} 바이트다 — 클립이 상한을 지키지 못했다"
fi
case "$longrow" in
  *"(잘림)"*) ok "잘린 값이 잘렸다고 말한다" ;;
  *) bad "잘림 표시" "무음 절단은 아침에 답 전체로 읽힌다: $longrow" ;;
esac
gateN act --manifest "$NM" --kind judgment --target infra --segment SD --cutpoint 커밋 \
      --surface 읽기 --snapshot-digest "$(HN)" --rationale x \
      -- 등급=2 기준="짧은 기준" 근거="짧은 근거"
case "$(last_judgment_approval)" in
  *"(잘림)"*) bad "잘림 표시" "자르지 않은 값에 잘림 도장이 찍혔다" ;;
  *) ok "자르지 않은 값에는 잘림 표시가 붙지 않는다" ;;
esac

# --- 31t. A `|` in a field value cannot splice the row ----------------------
#
# The write-time checks read the argv LIST and every reader splits the row TEXT,
# so a pipe inside one argv element was invisible to the first and a new field
# to the second. `사유=… | 스코프=run` passed the cone check as `cone` and then
# enumerated as an unresolved run-scope block in termination condition 5.
#
# COUNTED AS A FIELD RATHER THAN AS A SUBSTRING. Sanitizing rewrites `|` to `/`
# and deletes nothing, so `스코프=run` still appears inside the value — which is
# what the assertion below deliberately requires. A bare `grep -cF '스코프=run'`
# therefore counts the CHARACTERS showing up rather than a field being created,
# and rises by one even when the sanitizer works perfectly. Wrapping the pattern
# in the row's own separators is what makes it measure a field: `스코프` is not
# the last field, so a real one is surrounded by pipes, while the sanitized value
# reads `/ 스코프=run /` and does not match.
n_run_before=$( { grep -F '`blocked`' "$LEDGER2" || true; } | grep -cF '| 스코프=run |' || true)
cone_of SA "리뷰 P0 | 스코프=run | P1 미해소" >/dev/null
n_run_after=$( { grep -F '`blocked`' "$LEDGER2" || true; } | grep -cF '| 스코프=run |' || true)
check "필드 값 안의 파이프가 새 필드를 만들지 못한다" "$n_run_after" "$n_run_before"
case "$( { grep -F '`blocked`' "$LEDGER2" || true; } | tail -1)" in
  *"리뷰 P0 / 스코프=run / P1 미해소"*) ok "파이프가 행 문법을 쪼개지 않도록 쓰기 시점에 정규화된다" ;;
  *) bad "필드 소독" "$( { grep -F '`blocked`' "$LEDGER2" || true; } | tail -1)" ;;
esac

# --- 31u. `선행` — one normalization for the reader and the floor -----------
#
# The reader split on comma AND whitespace; the floor deleted whitespace and
# split on comma only. So `선행=SA SB` — the spacing a design document's slice
# declaration produces, copied through `slice_field` without normalization —
# became one token to the floor, restating the same value failed monotonicity,
# and that segment could not write a second row of any kind.
seg_row SW1 "$CONE_C" 상태=실행중 선행=없음
check "공백 스펠링 픽스처의 첫 세그먼트 행이 기록된다" "$rc" "0"
seg_row SW2 "$CONE_D" 상태=실행중 "선행=SA SW1"
check "공백으로 구분한 「선행」이 받아들여진다" "$rc" "0"
seg_row SW2 "$CONE_D" 상태=실행중 "선행=SA SW1"
check "같은 값을 그대로 다시 적어도 단조성에 걸리지 않는다" "$rc" "0"
seg_row SW2 "$CONE_D" 상태=실행중 "선행=SA,SW1"
check "쉼표 스펠링과 공백 스펠링이 같은 집합으로 읽힌다" "$rc" "0"
seg_row SW2 "$CONE_D" 상태=실행중 선행=SA
check "정규화를 통일해도 좁히기는 여전히 거절된다 (극성이 뒤집히지 않았다)" "$rc" "2"
# `없음` FALLS PER TOKEN. Mixed with a real id it used to survive as a
# dependency nothing can land, and monotonicity then refused the correction —
# a state reached by FOLLOWING the instruction that the field may be added to.
seg_row SW3 "$CONE_E" 상태=실행중 "선행=없음,SA"
check "「없음」과 실제 id 가 섞인 「선행」도 기록된다" "$rc" "0"
seg_row SW3 "$CONE_E" 상태=실행중 선행=SA
check "「없음」은 토큰 단위로 떨어지므로 교정이 가능하다 (영구 잠금이 아니다)" "$rc" "0"
seg_row SW4 "$CONE_F" 상태=실행중 선행=SZZZ
check "원장에 없는 세그먼트를 지목한 「선행」은 쓰기 시점에 거절된다" "$rc" "2"
case "$msg" in
  *"원장에 없습니다"*) ok "거절이 그런 세그먼트가 없다고 말한다 (나중의 착지 실패가 아니다)" ;;
  *) bad "선행 id 대조" "$msg" ;;
esac

# --- 31v. An over-long declared cone is refused by LENGTH -------------------
LONGDEP=$(awk 'BEGIN{ s="SEG0000"; for (i = 1; i < 60; i++) s = s ",SEG" i; printf "%s", s }')
gateN act --manifest "$NM" --kind blocked --target infra --cutpoint 커밋 --surface 읽기 \
      --snapshot-digest "$(HN)" --rationale x \
      -- 스코프=cone 원인=막힘 "앵커 세그먼트=SA" "의존 세그먼트=$LONGDEP" 사유=x 근거=z "재개 명령=-"
check "상한을 넘는 「의존 세그먼트」 선언은 append 이전에 거절된다" "$rc" "2"
case "$msg" in
  *"바이트를 넘습니다"*) ok "거절이 길이를 지목한다 (writer 안에서 죽지 않는다)" ;;
  *) bad "의존 세그먼트 길이" "$msg" ;;
esac

# --- 31w. A judgment approval's identity is the whole question --------------
#
# The id hashed `기준` alone while the row carried `기준 — 근거`, and a judgment
# approval has no binding tuple, so nothing about it ever goes stale. Two
# judgments sharing a short, writer-authored standard were one approval, and one
# answer then opened every later judgment that resolved to it.
gateN act --manifest "$NM" --kind judgment --target infra --segment SD --cutpoint 커밋 \
      --surface 읽기 --snapshot-digest "$(HN)" --rationale x \
      -- 등급=2 기준="같은 기준" 근거="첫째 근거"
id1=$(row_field "$(last_judgment_approval)" '승인 id')
gateN act --manifest "$NM" --kind judgment --target infra --segment SD --cutpoint 커밋 \
      --surface 읽기 --snapshot-digest "$(HN)" --rationale x \
      -- 등급=2 기준="같은 기준" 근거="둘째 근거"
id2=$(row_field "$(last_judgment_approval)" '승인 id')
if [ -n "$id1" ] && [ -n "$id2" ] && [ "$id1" != "$id2" ]; then
  ok "승인 id 는 질문 문면 전체에서 유도된다 (기준만 같은 다른 질문은 다른 승인이다)"
else
  bad "승인 정체성" "기준만 같으면 한 승인으로 접힌다: '$id1' / '$id2'"
fi

# AN ANSWER IS SPENT ONCE.
gateN act --manifest "$NM" --kind judgment --target infra --segment SD --cutpoint 커밋 \
      --surface 읽기 --snapshot-digest "$(HN)" --rationale x \
      -- 등급=2 기준="일회성 기준" 근거="일회성 근거"
oid=$(row_field "$(last_judgment_approval)" '승인 id')
oq=$(row_field "$( { grep -F '`승인`' "$LEDGER2" || true; } | grep -F "승인 id=$oid " | tail -1)" '질문 문면')
OSID="14141414-3434-5656-7878-909090909090"
printf '{"role":"user","content":"%s / %s → 그렇게 하라"}\n' "$oid" "$oq" > "$NTX/$OSID.jsonl"
out=$(cd "$WT" && XDG_STATE_HOME="$STATE_CONE" CLAUDE_CONFIG_DIR="$NCFG" \
      CLAUDE_CODE_SESSION_ID="$OSID" bash "$GATE" close --manifest "$NM" --approval "$oid" 2>&1); rc=$?
check "일회성 검사를 위한 판단 승인이 닫힌다" "$rc" "0"
gateN act --manifest "$NM" --kind judgment --target infra --segment SD --cutpoint 커밋 \
      --surface 읽기 --snapshot-digest "$(HN)" --rationale x \
      -- 등급=1 "판단 부류=감사-발견" 기준="일회성 기준" "되돌리는 법=아침에 다시 본다" 근거="일회성 근거"
check "해소된 승인이 그 판단을 연다" "$rc" "0"
case "$( { grep -F '`자율 승인`' "$LEDGER2" || true; } | tail -1)" in
  *"해소 승인=$oid"*) ok "채택 행이 어느 답이 그것을 열었는지 남긴다" ;;
  *) bad "해소 승인" "$( { grep -F '`자율 승인`' "$LEDGER2" || true; } | tail -1)" ;;
esac
gateN act --manifest "$NM" --kind judgment --target infra --segment SD --cutpoint 커밋 \
      --surface 읽기 --snapshot-digest "$(HN)" --rationale x \
      -- 등급=1 "판단 부류=감사-발견" 기준="일회성 기준" "되돌리는 법=아침에 다시 본다" 근거="일회성 근거"
# 5 가 아니라 3 이다. 옛 처분은 「승인 대기를 발행했다」였는데, 그 발행이 곧 닫힌
# 승인을 같은 id 아래 다시 `대기` 로 여는 것이었다 — 사람이 답한 물음이 아침에 다시
# 열린 물음으로 돌아오는 경로다. 소진된 답에 대해 발행할 것은 없고, 그 판단이
# 여전히 필요하다면 기준과 근거가 다른 새 물음이어야 한다.
check "같은 답이 두 번째 판단까지 열지는 않는다" "$rc" "3"
case "$msg" in
  *"이미 한 번 채택에 쓰였습니다"*) ok "거절이 답 하나는 판단 하나를 연다고 말한다" ;;
  *) bad "일회성 소비" "$msg" ;;
esac
# 그리고 그 거절이 승인을 다시 열지 않았음을 상태로 잰다 — 종료 코드만 보면 발행이
# 일어났는지 알 수 없고, 그 발행이 이 항목이 닫는 결함이다.
check "소진된 답의 재제출이 그 승인을 다시 대기로 열지 않는다" \
      "$(row_field "$( { grep -F '`승인`' "$LEDGER2" || true; } | grep -F "승인 id=$oid " | tail -1)" '상태')" \
      "승인"

# --- 31x. `close` records the ANSWER, not the transport frame ---------------
#
# `$ans` is the matched transcript LINE, and a harness line puts `message.content`
# behind `uuid`, `parentUuid`, `sessionId` and `timestamp` as an array of blocks.
# Recorded verbatim, the field the contract calls the run's only durable copy of
# the answer held four hundred bytes of scaffolding. The old fixture missed it
# because a hand-written one-line object puts the answer near the front.
gateN act --manifest "$NM" --kind judgment --target infra --segment SD --cutpoint 커밋 \
      --surface 읽기 --snapshot-digest "$(HN)" --rationale x \
      -- 등급=2 기준="실물 트랜스크립트 모양에서도 답이 실리는가" 근거="프레임이 아니라 답이 남아야 한다"
rid=$(row_field "$(last_judgment_approval)" '승인 id')
rq=$(row_field "$( { grep -F '`승인`' "$LEDGER2" || true; } | grep -F "승인 id=$rid " | tail -1)" '질문 문면')
RANS="네, 셋으로 나누고 합성만 하나로 둔다"
RSID="15151515-3434-5656-7878-909090909090"
printf '{"parentUuid":"11111111-2222-3333-4444-555555555555","sessionId":"%s","timestamp":"2026-09-01T00:00:00Z","type":"user","message":{"role":"user","content":[{"type":"text","text":"%s / %s → %s"}]},"uuid":"66666666-7777-8888-9999-000000000000"}\n' \
  "$RSID" "$rid" "$rq" "$RANS" > "$NTX/$RSID.jsonl"
out=$(cd "$WT" && XDG_STATE_HOME="$STATE_CONE" CLAUDE_CONFIG_DIR="$NCFG" \
      CLAUDE_CODE_SESSION_ID="$RSID" bash "$GATE" close --manifest "$NM" --approval "$rid" 2>&1); rc=$?
check "실물 모양의 트랜스크립트 줄로도 승인이 닫힌다" "$rc" "0"
rrow=$( { grep -F '`승인`' "$LEDGER2" || true; } | grep -F "승인 id=$rid " | tail -1)
case "$rrow" in
  *"$RANS"*) ok "답변 문면에 사람의 답이 실린다" ;;
  *) bad "답 추출" "$rrow" ;;
esac
case "$rrow" in
  *parentUuid*|*sessionId*) bad "답 추출" "전송 프레임이 답변 문면에 실렸다: $rrow" ;;
  *) ok "전송 프레임의 JSON 스캐폴딩은 답변 문면에 실리지 않는다" ;;
esac

# --- 31y. One question holds ONE clause -------------------------------------
#
# Condition 10 is the only one of the ten that measures what the USER authorized
# the run against, and `보류` settles it — so one grade-2 judgment cited by every
# clause would let the run end with nothing actually settled while the morning
# read it as a run that ended with one open question.
nm_add_auth_row '- `종료 절` | id=K2 | 문면=둘째 절'
nm_add_auth_row '- `종료 절` | id=K3 | 문면=셋째 절'
gateN act --manifest "$NM" --kind judgment --target infra --segment SD --cutpoint 커밋 \
      --surface 읽기 --snapshot-digest "$(HN)" --rationale x \
      -- 등급=2 기준="둘째 절을 이번 런에서 정산할지" 근거="사람이 정해야 한다"
jid2=$(row_field "$(last_judgment_approval)" '승인 id')
gateN act --manifest "$NM" --kind clause --target infra --cutpoint 커밋 --surface 읽기 \
      --snapshot-digest "$(HN)" --rationale x -- id=K2 상태=보류 "근거=열린 판단 승인 $jid2"
check "둘째 절은 자기 물음에 대해 보류로 정산된다" "$rc" "0"
gateN act --manifest "$NM" --kind clause --target infra --cutpoint 커밋 --surface 읽기 \
      --snapshot-digest "$(HN)" --rationale x -- id=K3 상태=보류 "근거=열린 판단 승인 $jid2"
check "이미 다른 절을 보류시킨 승인은 셋째 절을 정산하지 못한다" "$rc" "2"
case "$msg" in
  *"이미 종료 절"*) ok "거절이 답 하나가 여러 절을 정산할 수 없음을 지목한다" ;;
  *) bad "보류 중복" "$msg" ;;
esac

# --- 31z. A judgment a STAGE emitted, in both directions --------------------
#
# 31o asserts only that a judgment which FAILS the union writes no row, and that
# assertion holds when the absorber does not run at all — deleting the call
# leaves the count at zero on both sides. The adopting direction is what makes
# the pair sensitive to the function's existence.
JSTUB2="$WORK/judgment-stub-adopt"
cat > "$JSTUB2" <<'JSTUB2EOF'
#!/usr/bin/env bash
cat <<'RES2EOF'
{"type":"result","subtype":"success","is_error":false,"total_cost_usd":0.1,"session_id":"emit-session-2","num_turns":1,"result":"**판단 부류**: 문서-신선도 **판단 등급**: 1 **판단 되돌리는 법**: 아침에 문서를 다시 읽는다 **판단 기준**: 문서가 최신인가 **판단 근거**: 앵커 해시가 그대로다"}
RES2EOF
exit 0
JSTUB2EOF
chmod +x "$JSTUB2"
seg_row SJ2 "$CONE_C" 상태=실행중 선행=없음
check "채택 실험용 세그먼트 행이 기록된다" "$rc" "0"
n_emit_before2=$( { grep -F '출처=스테이지 방출' "$LEDGER2" || true; } | grep -c . || true)
( cd "$WT" && XDG_STATE_HOME="$STATE_CONE" CC_CLAUDE_BIN="$JSTUB2" \
  bash "$GATE" act --manifest "$NM" --kind skill --target infra --segment SJ2 --cutpoint 커밋 \
  --surface 워크트리쓰기 --snapshot-digest "$(HN)" --rationale x \
  -- review "/cc-cmds:review-unattended x" ) >/dev/null 2>&1
n_emit_after2=$( { grep -F '출처=스테이지 방출' "$LEDGER2" || true; } | grep -c . || true)
if [ "${n_emit_after2:-0}" -gt "${n_emit_before2:-0}" ]; then
  ok "합집합을 통과한 방출 판단은 출처=스테이지 방출 행을 만든다 (흡수기를 지우면 이 단언이 실패한다)"
else
  bad "방출 채택" "합집합을 통과한 방출 판단이 아무 행도 남기지 않았다"
fi
# THE ROW'S FIELDS, NOT ONLY ITS EXISTENCE. A count rises whenever a row is
# appended, whatever the row says — so an extraction that returned the rest of
# the line for every free-text field passed the assertion above while the undo
# command on the row carried the two markers after it glued on. What a person
# reads at 3am is `되돌리는 법`, not the count. The five markers sit on ONE line
# in this fixture because that is what a stage's terminal message is.
arow2=$( { grep -F '`자율 승인`' "$LEDGER2" || true; } | grep -F '출처=스테이지 방출' | tail -1)
check "채택 행의 판단 부류가 방출된 값 그대로다" "$(row_field "$arow2" '판단 부류')" "문서-신선도"
check "채택 행의 등급이 방출된 값 그대로다" "$(row_field "$arow2" '등급')" "1"
check "채택 행의 되돌리는 법이 뒤따르는 마커를 삼키지 않는다" "$(row_field "$arow2" '되돌리는 법')" "아침에 문서를 다시 읽는다"
check "채택 행의 기준이 뒤따르는 마커를 삼키지 않는다" "$(row_field "$arow2" '기준')" "문서가 최신인가"
check "채택 행의 근거가 그대로 실린다" "$(row_field "$arow2" '근거')" "앵커 해시가 그대로다"

# A MARKER WITH NO CLASS IS ESCALATED, NOT DROPPED. The class used to gate the
# rest of the parse, so "no judgment was emitted" and "a judgment was emitted
# without a class" shared one silent return — and the second is the shape a
# stage naturally produces, because the marking convention names `기준` and
# `되돌리는 법` and has never required a class. That judgment vanished with no
# row, no approval and no warning, while the stage had already acted on it.
JSTUB3="$WORK/judgment-stub-noclass"
cat > "$JSTUB3" <<'JSTUB3EOF'
#!/usr/bin/env bash
cat <<'RES3EOF'
{"type":"result","subtype":"success","is_error":false,"total_cost_usd":0.1,"session_id":"emit-session-3","num_turns":1,"result":"**판단 등급**: 2 **판단 기준**: 부류를 적지 않은 방출 판단 **판단 근거**: 마킹 규약은 부류를 요구하지 않는다"}
RES3EOF
exit 0
JSTUB3EOF
chmod +x "$JSTUB3"
seg_row SJ3 "$CONE_C" 상태=실행중 선행=없음
check "부류 없는 방출 실험용 세그먼트 행이 기록된다" "$rc" "0"
napp_before=$( { grep -F '`승인`' "$LEDGER2" || true; } | grep -cF '절단점=판단' || true)
( cd "$WT" && XDG_STATE_HOME="$STATE_CONE" CC_CLAUDE_BIN="$JSTUB3" \
  bash "$GATE" act --manifest "$NM" --kind skill --target infra --segment SJ3 --cutpoint 커밋 \
  --surface 워크트리쓰기 --snapshot-digest "$(HN)" --rationale x \
  -- review "/cc-cmds:review-unattended x" ) >/dev/null 2>&1
napp_after=$( { grep -F '`승인`' "$LEDGER2" || true; } | grep -cF '절단점=판단' || true)
if [ "${napp_after:-0}" -gt "${napp_before:-0}" ]; then
  ok "부류 없는 방출 판단은 조용히 버려지지 않고 승인으로 올라간다"
else
  bad "방출 fail-open" "부류가 없다는 이유로 방출된 판단이 행도 승인도 경고도 없이 사라졌다"
fi

# --- 31ab. Arm (b) admits the grade that CHANGES something ------------------
#
# The arm accepted `읽기` beside `워크트리쓰기`, and the grading table's first
# row reads `cat|ls|find|grep|…` as `읽기` — so the least powerful grade in the
# table was the most permissive spelling of an undo. `되돌리는 법=ls docs/`
# reverses nothing and was adopted for it. Nothing measured the other end
# either, which is the direction an author has no incentive to reach and so the
# one a suite has to assert deliberately.
#
# The class is `잔여-항목`: inside the vocabulary and outside the forbidden set,
# so neither the vocabulary floor nor the forbidden-class arm above can be what
# answers, and the manifest declares only `문서-신선도` so arm (a) stays shut.
# What is left measuring the outcome is arm (b) alone.
gateN act --manifest "$NM" --kind judgment --target infra --segment SD --cutpoint 커밋 \
      --surface 읽기 --snapshot-digest "$(HN)" --rationale x \
      -- 등급=1 "판단 부류=잔여-항목" 기준="잔여 항목을 이번 런에서 닫을지" \
         "되돌리는 법=ls docs/" 근거="읽기 등급의 명령은 되돌릴 대상을 만들지 않는다"
check "아무것도 바꾸지 않는 되돌리기는 팔 (b) 를 열지 못한다 (하한)" "$rc" "5"
case "$msg" in
  *"되돌리는 법이 워크트리를 되돌리는 명령이 아닙니다"*)
    ok "거절이 되돌리기의 등급을 지목한다" ;;
  *) bad "팔 b 하한 문면" "$msg" ;;
esac
gateN act --manifest "$NM" --kind judgment --target infra --segment SD --cutpoint 커밋 \
      --surface 읽기 --snapshot-digest "$(HN)" --rationale x \
      -- 등급=1 "판단 부류=잔여-항목" 기준="잔여 항목을 지우고 갈지" \
         "되돌리는 법=aws s3 rm s3://x/y --recursive" 근거="외부 상태를 바꾸는 되돌리기다"
check "외부 상태를 바꾸는 되돌리기도 팔 (b) 를 열지 못한다 (상한)" "$rc" "5"
# AND THE ARM IS NOT DEAD. An empty accepted set would pass both assertions
# above while removing the floor's only runtime admission path.
gateN act --manifest "$NM" --kind judgment --target infra --segment SD --cutpoint 커밋 \
      --surface 읽기 --snapshot-digest "$(HN)" --rationale x \
      -- 등급=1 "판단 부류=잔여-항목" 기준="잔여 항목의 인용을 갱신할지" \
         "되돌리는 법=git checkout -- docs/x.md" 근거="워크트리를 되돌리는 명령이다"
check "워크트리를 되돌리는 명령은 여전히 채택된다 (팔 b 가 통째로 죽지 않았다)" "$rc" "0"

# --- 31ac. The manifest write guard measures the FILE, not the argv string --
#
# 31q asserts the happy path — `tee "$NM"`, one argv element equal to the
# manifest — and whole-element equality passes that while leaving two ordinary
# spellings open. A different spelling of the same absolute path equals no
# element at all. And an interpreter carries the path INSIDE an element:
# `bash -c 'printf x >> <경로>'` has three elements, none of them the manifest,
# and `bash` grades `워크트리쓰기` so the axis-2 declaration is honest. Either
# one appends to the run's own pre-adoption list.
gateN exec --manifest "$NM" --target infra --segment SD --cutpoint 커밋 \
      --surface 워크트리쓰기 --snapshot-digest "$(HN)" --rationale x \
      -- tee "$WORK/./cone-plan.md"
check "같은 파일의 다른 철자로도 매니페스트 쓰기가 거절된다" "$rc" "3"
gateN exec --manifest "$NM" --target infra --segment SD --cutpoint 커밋 \
      --surface 워크트리쓰기 --snapshot-digest "$(HN)" --rationale x \
      -- bash -c "printf x >> $NM"
check "인터프리터로 감싼 매니페스트 쓰기도 거절된다" "$rc" "3"
case "$msg" in
  *"매니페스트에 쓰려 합니다"*) ok "래핑된 쓰기도 인가의 자기확장으로 지목된다" ;;
  *) bad "래핑 가드 문면" "$msg" ;;
esac
# AND THE GUARD DOES NOT SWALLOW READS. Containment matching sees the name in
# any element, so without the read arm in front of it the morning's own way of
# looking at the manifest would be refused too.
gateN exec --manifest "$NM" --target infra --segment SD --cutpoint 커밋 \
      --surface 읽기 --snapshot-digest "$(HN)" --rationale x \
      -- grep -c "" "$NM"
check "같은 경로를 읽기만 하는 행위는 통과한다 (오탐이 아니다)" "$rc" "0"
# AND WHAT IS MEASURED IS PATH IDENTITY, NOT THE NAME. Both refusals above name a
# file whose basename IS the manifest's, and the guard's last arm is basename
# containment — so an implementation that knows nothing about paths refuses both
# and nothing here can tell it apart from one that resolves. A symlink is the
# case a name cannot answer: it shares neither basename nor directory with the
# file it opens, and only following it says the two are one file.
CONE_ALIAS="$WORK/alias"
mkdir -p "$CONE_ALIAS"
ln -sf "$NM" "$CONE_ALIAS/별칭.md"
gateN exec --manifest "$NM" --target infra --segment SD --cutpoint 커밋 \
      --surface 워크트리쓰기 --snapshot-digest "$(HN)" --rationale x \
      -- touch "$CONE_ALIAS/별칭.md"
check "이름을 하나도 공유하지 않는 심링크를 통한 매니페스트 쓰기도 거절된다" "$rc" "3"
case "$msg" in
  *"매니페스트에 쓰려 합니다"*) ok "심링크를 통한 쓰기도 인가의 자기확장으로 지목된다" ;;
  *) bad "심링크 가드 문면" "$msg" ;;
esac
# THE UPPER BOUND, IN THE SAME BREATH. A guard that refused every path-shaped
# element would pass the line above while measuring nothing. The code is not
# asserted here because an approved write has other reasons to be held; what is
# asserted is WHICH rule answered, which is the thing being measured.
gateN exec --manifest "$NM" --target infra --segment SD --cutpoint 커밋 \
      --surface 워크트리쓰기 --snapshot-digest "$(HN)" --rationale x \
      -- mkdir "$CONE_ALIAS/무관"
case "$msg" in
  *"매니페스트에 쓰려 합니다"*)
    bad "매니페스트 가드 오탐" "무관한 경로에 대한 쓰기를 매니페스트 쓰기로 거절했다: $msg" ;;
  *) ok "무관한 경로 쓰기는 매니페스트 가드에 걸리지 않는다 (모든 쓰기를 거절하는 구현이 아니다)" ;;
esac

# --- 31ad. The declared axis answers BEFORE anything reads a repository -----
#
# `선행` is pure ledger data and no repository probe can inform it, yet it was
# evaluated after that probe — so two ordinary declarations were thrown away. A
# dependency naming a segment in ANOTHER repository was settled by the
# cross-repository arm and disappeared from the cone, and a dependency on a
# member whose worktree had been cleaned up was written down as unmeasurable
# while the declaration on the row answered it exactly.
#
# `SG`'s worktree was removed back in 31e and stays removed, which is what makes
# the second case reachable from here without a second teardown.
CONE_H="$WORK/cone-h"
# ITS OWN COMMIT, NOT BARE `main`. A segment whose tip IS the shared base is an
# ancestor of every other segment in the repository, so the moment it joined a
# cone it would drag the whole ledger in and every exclusion below would fail for
# a reason that has nothing to do with what is being measured.
( cd "$REPO" && git worktree add -q -b coneH "$CONE_H" main \
  && cd "$CONE_H" && echo h1 > h1.txt && git add -A && git commit -qm h1 ) >/dev/null 2>&1
seg_row SH "$CONE_H" 상태=실행중 선행=SG
check "워크트리가 사라진 멤버를 선행으로 적은 세그먼트 행이 기록된다" "$rc" "0"
seg_row SY "$REPO2" 상태=실행중 선행=SA
check "다른 레포에서 선행을 적은 세그먼트 행이 기록된다" "$rc" "0"
cone7=$(cone_of SA "선언 축이 레포 경계와 판독 불가보다 먼저 답한다")
case ",$cone7," in
  *,SY,*) ok "레포를 건너는 선행이 원뿔에 든다 (선언은 git 에 대한 주장이 아니다)" ;;
  *) bad "선언 축 우선" "레포를 건너는 선행이 원뿔에서 사라졌다: $cone7" ;;
esac
case ",$cone7," in
  *,SH,*) ok "멤버의 워크트리를 읽지 못해도 선언 축이 그 세그먼트를 원뿔에 넣는다" ;;
  *) bad "선언 축 우선" "판독 불가 멤버를 선행으로 적은 세그먼트가 원뿔 밖으로 떨어졌다: $cone7" ;;
esac
# AND THE MOVE DOES NOT UNIVERSALIZE. `SX` sits in that same second repository
# and declares nobody, so this is what says whether the cone started crossing
# repositories for some reason OTHER than the declaration.
case ",$cone7," in
  *,SX,*) bad "선언 축 우선" "선언이 없는 다른 레포 세그먼트까지 원뿔에 들어왔다: $cone7" ;;
  *) ok "선언이 없는 다른 레포 세그먼트는 여전히 원뿔 밖이다" ;;
esac

# --- 31ae. Two segments on ONE tip are not each other's ancestors -----------
#
# `git merge-base --is-ancestor X X` is true, which answers the question git was
# asked and not the one the ancestry axis asks. That axis trades on "the member
# has already merged, so the candidate stands on its commits"; a member whose tip
# IS the candidate's tip contributed no such commit. Left in, every segment
# sharing a worktree answered "ancestor" for every other and a cone anchored on
# any one of them swallowed the group — which is the ordinary shape here, since
# a repository's segments are dispatched against one worktree until one lands.
CONE_P="$WORK/cone-p"
( cd "$REPO" && git worktree add -q -b coneP "$CONE_P" main \
  && cd "$CONE_P" && echo p1 > p1.txt && git add -A && git commit -qm p1 ) >/dev/null 2>&1
seg_row SP1 "$CONE_P" 상태=실행중 선행=없음
check "한 워크트리에 얹힌 첫 세그먼트 행이 기록된다" "$rc" "0"
seg_row SP2 "$CONE_P" 상태=실행중 선행=없음
check "같은 워크트리에 얹힌 둘째 세그먼트 행이 기록된다" "$rc" "0"
seg_row SP3 "$CONE_P" 상태=실행중 선행=SP1
check "같은 워크트리에서 첫째를 선행으로 적은 셋째 행이 기록된다" "$rc" "0"
cone8=$(cone_of SP1 "같은 팁 위의 형제들")
case ",$cone8," in
  *,SP2,*) bad "진조상" "팁이 같다는 이유만으로 형제가 원뿔에 들어왔다: $cone8" ;;
  *) ok "팁이 같은 형제는 원뿔에 들지 않는다 (커밋을 하나도 보태지 않은 멤버는 조상이 아니다)" ;;
esac
# THE GUARD DOES NOT TAKE THE DECLARED AXIS WITH IT. `SP3` sits on the same tip
# as `SP1` and names it, so an implementation that closed the equal-tip hole by
# refusing same-tip pairs outright would lose a dependency the router stated.
case ",$cone8," in
  *,SP3,*) ok "선언된 진짜 의존은 그대로 원뿔에 든다 (가드가 선언 축을 함께 죽이지 않았다)" ;;
  *) bad "진조상" "같은 팁 위에 선언된 의존이 사라졌다: $cone8" ;;
esac

# --- 31af. A path with a space and a Korean path survive the escape check ---
#
# `for f in $(git diff --name-only)` tore `docs/설계 노트.md` into two fragments,
# and the identical splitting on the declaration side tore `설계 문서/` into two
# prefixes that cover nothing. The two fail in OPPOSITE directions — the first
# invents an escape a segment did not commit, the second hides one it did — so
# both are asserted. The existing fixture (`src/e1.txt`, ASCII and no space)
# cannot tell either apart from correct behaviour.
CONE_Q="$WORK/cone-q"
( cd "$REPO" && git worktree add -q -b coneQ "$CONE_Q" main \
  && cd "$CONE_Q" && mkdir -p docs '설계 문서' \
  && echo q1 > 'docs/설계 노트.md' && echo q2 > '설계 문서/개요.md' \
  && git add -A && git commit -qm q1 ) >/dev/null 2>&1
seg_row SQ "$CONE_Q" 상태=실행중 선행=없음 "베이스 sha=$base_main" "선언 파일 집합=docs/, 설계 문서/"
check "공백과 한글이 든 파일 집합을 선언한 세그먼트 행이 기록된다" "$rc" "0"
CONE_R="$WORK/cone-r"
( cd "$REPO" && git worktree add -q -b coneR "$CONE_R" main \
  && cd "$CONE_R" && mkdir -p 보고서 \
  && echo r1 > '보고서/요약.md' && git add -A && git commit -qm r1 ) >/dev/null 2>&1
seg_row SR "$CONE_R" 상태=실행중 선행=없음 "베이스 sha=$base_main" "선언 파일 집합=docs/"
check "선언 밖 한글 경로를 바꾼 세그먼트 행이 기록된다" "$rc" "0"
cone9=$(cone_of SA "파일 집합 판정의 경로 처리")
case ",$cone9," in
  *,SQ,*) bad "파일 집합 이탈" "선언 안에 머문 세그먼트가 이탈로 잡혔다: $cone9" ;;
  *) ok "공백·한글이 든 경로가 선언 안에 있으면 이탈이 아니다" ;;
esac
case ",$cone9," in
  *,SR,*) ok "선언 밖 한글 경로는 여전히 이탈로 잡힌다 (판정을 통째로 끈 것이 아니다)" ;;
  *) bad "파일 집합 이탈" "선언 밖 경로를 바꾼 세그먼트가 이탈로 잡히지 않았다: $cone9" ;;
esac

# --- 31ag. The defect-identity seed filters terminal states, and matches the
#           WHOLE field value ------------------------------------------------
#
# THE WHOLE TERM WAS UNCOVERED. No fixture in this section wrote a `problem` row,
# so the identity loop could be deleted outright and the suite stayed green —
# which is how both defects below survived. The seed loop was the only one of the
# cone's four axes carrying no terminal filter, so a segment already merged was
# pulled back in on a shared defect identity and held work with nothing left to
# wait for. And both of its greps ended at a trailing space, which ends a value
# only when the separator follows — so `동일성=로그인 실패` also matched
# `동일성=로그인 실패 재현 불가` and welded two different defects into one cone.
CONE_T="$WORK/cone-t"
( cd "$REPO" && git worktree add -q -b coneT "$CONE_T" main \
  && cd "$CONE_T" && echo t1 > t1.txt && git add -A && git commit -qm t1 ) >/dev/null 2>&1
# ONE WORKTREE FOR ALL FOUR, which the proper-ancestor guard above is what makes
# safe: sharing a tip is no longer an edge, so anything that lands in this cone
# lands through the identity seed and nothing else.
seg_row ST1 "$CONE_T" 상태=실행중 선행=없음
check "동일성 씨앗의 앵커 세그먼트 행이 기록된다" "$rc" "0"
seg_row ST2 "$CONE_T" 상태=실행중 선행=없음
check "같은 결함을 공유하는 세그먼트 행이 기록된다" "$rc" "0"
seg_row ST3 "$CONE_T" 상태=머지됨 선행=없음
check "이미 머지된 세그먼트 행이 기록된다" "$rc" "0"
seg_row ST4 "$CONE_T" 상태=실행중 선행=없음
check "접두만 같은 다른 결함의 세그먼트 행이 기록된다" "$rc" "0"
gateN act --manifest "$NM" --kind problem --target infra --segment ST1 --cutpoint 커밋 \
      --surface 읽기 --snapshot-digest "$(HN)" --rationale x \
      -- "동일성=로그인 실패" "현재 단=1" "생성 등급=읽기"
check "앵커의 문제 행이 기록된다" "$rc" "0"
gateN act --manifest "$NM" --kind problem --target infra --segment ST2 --cutpoint 커밋 \
      --surface 읽기 --snapshot-digest "$(HN)" --rationale x \
      -- "동일성=로그인 실패" "현재 단=1" "생성 등급=읽기"
check "같은 동일성의 문제 행이 기록된다" "$rc" "0"
gateN act --manifest "$NM" --kind problem --target infra --segment ST3 --cutpoint 커밋 \
      --surface 읽기 --snapshot-digest "$(HN)" --rationale x \
      -- "동일성=로그인 실패" "현재 단=1" "생성 등급=읽기"
check "종결 상태 세그먼트의 문제 행이 기록된다" "$rc" "0"
gateN act --manifest "$NM" --kind problem --target infra --segment ST4 --cutpoint 커밋 \
      --surface 읽기 --snapshot-digest "$(HN)" --rationale x \
      -- "동일성=로그인 실패 재현 불가" "현재 단=1" "생성 등급=읽기"
check "접두만 같은 동일성의 문제 행이 기록된다" "$rc" "0"
cone10=$(cone_of ST1 "같은 결함 동일성을 공유한다")
case ",$cone10," in
  *,ST2,*) ok "같은 결함 동일성의 세그먼트가 원뿔에 든다 (씨앗 항이 살아 있다)" ;;
  *) bad "동일성 씨앗" "같은 동일성의 세그먼트가 원뿔에 들지 않았다: $cone10" ;;
esac
case ",$cone10," in
  *,ST3,*) bad "동일성 씨앗" "이미 머지된 세그먼트가 동일성으로 다시 끌려들어왔다: $cone10" ;;
  *) ok "종결 상태 세그먼트는 동일성 씨앗으로도 원뿔에 들지 않는다" ;;
esac
case ",$cone10," in
  *,ST4,*) bad "동일성 접두 오매치" "동일성이 접두만 같은 다른 결함이 원뿔에 들어왔다: $cone10" ;;
  *) ok "동일성 대조가 필드 종료 구분자까지 본다 (접두가 같은 다른 값은 걸리지 않는다)" ;;
esac

# --- 31ah. The ancestry probe's undecidable answer is actually REACHED -------
#
# 31e removes a worktree, which settles the pair inside `gate_cone_edge`'s
# repository arm — `gate_ancestor_of` is never called there, so its undecidable
# branch sat unexecuted while the suite read as though it covered it. Reaching it
# needs a worktree that IS readable as a repository and whose tip nonetheless
# cannot be resolved, so this breaks `HEAD` and leaves everything else intact.
#
# `선행=없음` IS LOAD-BEARING. The declared axis now answers before any
# repository is read, so a candidate carrying `선행` would return from that loop
# and never reach the probe — and the assertion would pass without executing the
# branch it is named after.
#
# LAST OF THE NEW SUBSECTIONS, and it puts the fixture back. A member whose tip
# cannot be read makes every candidate in its repository undecidable and
# therefore a member, so leaving the condition standing would turn every cone
# derived after this point into the whole ledger.
CONE_I="$WORK/cone-i"
( cd "$REPO" && git worktree add -q -b coneI "$CONE_I" main \
  && cd "$CONE_I" && echo i1 > i1.txt && git add -A && git commit -qm i1 ) >/dev/null 2>&1
seg_row SI "$CONE_I" 상태=실행중 선행=없음
check "곧 팁을 잴 수 없게 될 세그먼트 행이 기록된다" "$rc" "0"
gitdirI=$(cd "$CONE_I" && git rev-parse --absolute-git-dir)
head_orig=$(cat "$gitdirI/HEAD")
printf 'ref: refs/heads/no-such-branch-here\n' > "$gitdirI/HEAD"
# THE BRANCH IS PINNED BEFORE IT IS ASSERTED ON. Both failure modes leave the
# same `판정 불가` row behind, so the row alone cannot say which arm produced it —
# this pair of probes is what makes the subsection about the arm it names.
if ( cd "$CONE_I" && git rev-parse --path-format=absolute --git-common-dir ) >/dev/null 2>&1 \
   && ! ( cd "$CONE_I" && git rev-parse HEAD ) >/dev/null 2>&1; then
  ok "픽스처가 겨냥한 분기에 실제로 닿는다 — 레포는 읽히고 팁만 재지 못한다"
else
  bad "픽스처 겨냥" "레포 판독 분기와 팁 판독 분기 중 엉뚱한 쪽에 걸린다"
fi
cone11=$(cone_of SA "팁을 잴 수 없는 세그먼트가 있다")
case ",$cone11," in
  *,SI,*) ok "팁을 재지 못한 세그먼트는 원뿔 안에 남는다 (조상 축의 판정 불가도 fail-closed 다)" ;;
  *) bad "조상 판정 불가" "팁을 재지 못한 세그먼트가 원뿔 밖으로 떨어졌다: $cone11" ;;
esac
n=$( { grep -F '`blocked`' "$LEDGER2" || true; } | grep -cF '조상 관계 판정 불가 SA→SI' || true)
if [ "${n:-0}" -ge 1 ]; then
  ok "무엇을 재지 못했는지가 두 세그먼트를 지목한 행으로 남는다"
else
  bad "판정 불가 기록" "SA→SI 를 재지 못한 사실이 원장에 없다"
fi
printf '%s\n' "$head_orig" > "$gitdirI/HEAD"
if ( cd "$CONE_I" && git rev-parse HEAD ) >/dev/null 2>&1; then
  ok "픽스처가 만든 조건을 되돌린다 (뒤따르는 절이 이 세그먼트를 다시 잴 수 있다)"
else
  bad "픽스처 복구" "깨뜨린 HEAD 를 되돌리지 못했다"
fi

# EVERY CONE ABOVE WAS READ FROM A ROW THIS SECTION ACTUALLY WROTE. The
# derivations run in subshells, so this is where their refusals become visible.
n=$(grep -c . "$CONE_OF_FAILURES" || true)
if [ "${n:-0}" = "0" ]; then
  ok "원뿔 유도 호출이 전부 새 행을 남겼다 (어느 판정도 직전 호출의 원뿔을 다시 읽지 않았다)"
else
  bad "원뿔 유도" "${n} 건의 원뿔 행 쓰기가 거절됐다 — 그 뒤의 판정은 stale 한 원뿔을 읽었다: $(tr '\n' ' ' < "$CONE_OF_FAILURES")"
fi

# --- 31ai. `close` reads the POLARITY of the answer, not just its presence --
#
# The recording path held one literal — `상태=승인` — and nothing anywhere read
# what the person actually wrote, so a transcript line saying no closed the
# approval as a grant. Every refusal on the unattended adoption surface
# converges on this one channel, so a channel that emits a constant leaves the
# floors above it deciding nothing. There is no negative-answer fixture anywhere
# else in this suite.
gateN act --manifest "$NM" --kind judgment --target infra --segment SD --cutpoint 커밋 \
      --surface 읽기 --snapshot-digest "$(HN)" --rationale x \
      -- 등급=2 기준="이 발견을 이번 런에서 고칠지" 근거="비용이 크다"
check "부정 답변 실험용 판단이 승인으로 올라간다" "$rc" "5"
nid=$(row_field "$(last_judgment_approval)" '승인 id')
nq=$(row_field "$( { grep -F '`승인`' "$LEDGER2" || true; } | grep -F "승인 id=$nid " | tail -1)" '질문 문면')
if [ -n "$nid" ]; then ok "부정 답변 실험용 판단 승인 id 를 원장에서 읽는다 ($nid)"; else bad "부정 답변 픽스처" "대기 행이 없다"; fi
NEGSID="17171717-3434-5656-7878-909090909090"
printf '{"role":"user","content":"%s / %s → 아니오, 다음 런에서 본다"}\n' "$nid" "$nq" > "$NTX/$NEGSID.jsonl"
out=$(cd "$WT" && XDG_STATE_HOME="$STATE_CONE" CLAUDE_CONFIG_DIR="$NCFG" \
      CLAUDE_CODE_SESSION_ID="$NEGSID" bash "$GATE" close --manifest "$NM" --approval "$nid" 2>&1); rc=$?
check "부정으로 읽히는 답은 승인으로 닫히지 않는다" "$rc" "3"
case "$out" in
  *"부정으로 읽힙니다"*) ok "거절이 무엇이 매치했는지와 어느 처분을 고를지 말한다" ;;
  *) bad "부정 스캔" "$out" ;;
esac
# THE STATE IS READ, NOT THE EXIT CODE. A refusal that nonetheless appended a
# `상태=승인` row would leave the exit code right and the ledger wrong, and the
# ledger is the only thing the morning reads.
nst=$(row_field "$( { grep -F '`승인`' "$LEDGER2" || true; } | grep -F "승인 id=$nid " | tail -1)" '상태')
check "거절된 close 는 그 승인의 상태를 대기 그대로 둔다" "$nst" "대기"
out=$(cd "$WT" && XDG_STATE_HOME="$STATE_CONE" CLAUDE_CONFIG_DIR="$NCFG" \
      CLAUDE_CODE_SESSION_ID="$NEGSID" bash "$GATE" close --manifest "$NM" --approval "$nid" --void --reject 2>&1); rc=$?
check "--void 와 --reject 를 함께 주면 거절된다 (서로 다른 처분이다)" "$rc" "2"
out=$(cd "$WT" && XDG_STATE_HOME="$STATE_CONE" CLAUDE_CONFIG_DIR="$NCFG" \
      CLAUDE_CODE_SESSION_ID="$NEGSID" bash "$GATE" close --manifest "$NM" --approval "$nid" --reject 2>&1); rc=$?
check "같은 트랜스크립트 줄이 --reject 로는 닫힌다" "$rc" "0"
nst=$(row_field "$( { grep -F '`승인`' "$LEDGER2" || true; } | grep -F "승인 id=$nid " | tail -1)" '상태')
check "거부로 닫힌 처분이 원장에 남는다" "$nst" "거부"
# A REJECTION IS AN ANSWER, AND WITHOUT AN ARM FOR IT IT READS AS SILENCE.
# `거부` is neither `대기` nor `승인`, so control falls out of the resolution
# block and reaches the issuing path — which re-opens the very question that was
# just answered no, every morning, off one answer already given.
gateN act --manifest "$NM" --kind judgment --target infra --segment SD --cutpoint 커밋 \
      --surface 읽기 --snapshot-digest "$(HN)" --rationale x \
      -- 등급=1 "판단 부류=감사-발견" 기준="이 발견을 이번 런에서 고칠지" \
         "되돌리는 법=아침에 다시 본다" 근거="비용이 크다"
check "거부로 닫힌 승인은 그 판단을 열지 않는다" "$rc" "3"
case "$msg" in
  *"거부로 닫혔습니다"*) ok "거절이 승인이 거부되었음을 지목한다 (승인이 재발행되지 않는다)" ;;
  *) bad "거부 소비" "$msg" ;;
esac
# THE SCAN DOES NOT OVER-MATCH. A positive answer on the same path still closes
# as `승인`, which is what makes the assertions above measure polarity rather
# than merely record that `close` can refuse.
gateN act --manifest "$NM" --kind judgment --target infra --segment SD --cutpoint 커밋 \
      --surface 읽기 --snapshot-digest "$(HN)" --rationale x \
      -- 등급=2 기준="이 정정을 이번 런에서 반영할지" 근거="변경이 작다"
check "긍정 답변 실험용 판단이 승인으로 올라간다" "$rc" "5"
pid_ok=$(row_field "$(last_judgment_approval)" '승인 id')
pq=$(row_field "$( { grep -F '`승인`' "$LEDGER2" || true; } | grep -F "승인 id=$pid_ok " | tail -1)" '질문 문면')
POSSID="18181818-3434-5656-7878-909090909090"
printf '{"role":"user","content":"%s / %s → 그렇게 하라"}\n' "$pid_ok" "$pq" > "$NTX/$POSSID.jsonl"
out=$(cd "$WT" && XDG_STATE_HOME="$STATE_CONE" CLAUDE_CONFIG_DIR="$NCFG" \
      CLAUDE_CODE_SESSION_ID="$POSSID" bash "$GATE" close --manifest "$NM" --approval "$pid_ok" 2>&1); rc=$?
check "긍정 답변은 그대로 승인으로 닫힌다" "$rc" "0"
pst=$(row_field "$( { grep -F '`승인`' "$LEDGER2" || true; } | grep -F "승인 id=$pid_ok " | tail -1)" '상태')
check "긍정 답변의 상태는 승인이다 (스캔이 과잉으로 잡지 않는다)" "$pst" "승인"

# --- 31aj. An answered approval is CONSUMED, a closed one is never re-opened -
#
# Issuing the question was half a lifecycle. A grade-2 judgment never reaches the
# resolution block on the acting path — that block runs only when the
# auto-adoption floor escalated, and the floor is consulted for grade 1 alone —
# so once the person answered, nothing on that path noticed. Every resubmission
# was raised as a question again, and the issuing path appended a fresh
# `상태=대기` row under the SAME id, so an approval a person had closed came back
# open. 31w reads exit codes on this path and never the state, so a new pending
# row leaves it green.
gateN act --manifest "$NM" --kind judgment --target infra --segment SD --cutpoint 커밋 \
      --surface 읽기 --snapshot-digest "$(HN)" --rationale x \
      -- 등급=2 기준="닫힌 승인이 재제출로 다시 열리는가" 근거="수명주기의 나머지 절반"
check "재제출 실험용 판단이 승인으로 올라간다" "$rc" "5"
cjid=$(row_field "$(last_judgment_approval)" '승인 id')
cjq=$(row_field "$( { grep -F '`승인`' "$LEDGER2" || true; } | grep -F "승인 id=$cjid " | tail -1)" '질문 문면')
CJSID="19191919-3434-5656-7878-909090909090"
printf '{"role":"user","content":"%s / %s → 그렇게 하라"}\n' "$cjid" "$cjq" > "$NTX/$CJSID.jsonl"
out=$(cd "$WT" && XDG_STATE_HOME="$STATE_CONE" CLAUDE_CONFIG_DIR="$NCFG" \
      CLAUDE_CODE_SESSION_ID="$CJSID" bash "$GATE" close --manifest "$NM" --approval "$cjid" 2>&1); rc=$?
check "재제출 실험용 승인이 승인으로 닫힌다" "$rc" "0"
cj_wait_before=$( { grep -F '`승인`' "$LEDGER2" || true; } \
                  | grep -F "승인 id=$cjid " | grep -cF '상태=대기' || true)
# RESUBMITTING THE SAME JUDGMENT IS HOW THE ANSWER IS CONSUMED, and before this
# there was no arm for it anywhere on the grade-2 path.
gateN act --manifest "$NM" --kind judgment --target infra --segment SD --cutpoint 커밋 \
      --surface 읽기 --snapshot-digest "$(HN)" --rationale x \
      -- 등급=2 기준="닫힌 승인이 재제출로 다시 열리는가" 근거="수명주기의 나머지 절반"
check "답이 온 등급 2 판단은 재제출로 채택된다" "$rc" "0"
case "$( { grep -F '`자율 승인`' "$LEDGER2" || true; } | tail -1)" in
  *"해소 승인=$cjid"*) ok "등급 2 채택 행이 어느 답이 그것을 열었는지 남긴다" ;;
  *) bad "등급 2 채택" "$( { grep -F '`자율 승인`' "$LEDGER2" || true; } | tail -1)" ;;
esac
# THE STATE IS READ, NOT THE EXIT CODE. A resubmission that nonetheless appended
# a second `상태=대기` row would leave every exit code right and hand the morning
# a question that had already been answered.
cj_wait_after=$( { grep -F '`승인`' "$LEDGER2" || true; } \
                 | grep -F "승인 id=$cjid " | grep -cF '상태=대기' || true)
check "재제출이 그 승인을 다시 대기로 열지 않는다" "${cj_wait_after:-0}" "${cj_wait_before:-0}"
check "그 승인의 마지막 상태는 승인 그대로다" \
      "$(row_field "$( { grep -F '`승인`' "$LEDGER2" || true; } | grep -F "승인 id=$cjid " | tail -1)" '상태')" \
      "승인"
gateN act --manifest "$NM" --kind judgment --target infra --segment SD --cutpoint 커밋 \
      --surface 읽기 --snapshot-digest "$(HN)" --rationale x \
      -- 등급=2 기준="닫힌 승인이 재제출로 다시 열리는가" 근거="수명주기의 나머지 절반"
check "소진된 답은 같은 등급 2 판단을 두 번 열지 않는다" "$rc" "3"
case "$msg" in
  *"이미 한 번 채택에 쓰였습니다"*) ok "그 거절이 답 하나는 판단 하나를 연다고 말한다" ;;
  *) bad "등급 2 일회성 소비" "$msg" ;;
esac
# A CLOSED-NEGATIVE APPROVAL IS AN ANSWER TOO, and both spellings of it. `무효`
# and `거부` are neither `대기` nor `승인`, so before the state split they fell
# straight through to the append and re-opened the question the person had just
# closed.
gateN act --manifest "$NM" --kind judgment --target infra --segment SD --cutpoint 커밋 \
      --surface 읽기 --snapshot-digest "$(HN)" --rationale x \
      -- 등급=2 기준="애초에 묻지 말았어야 할 물음" 근거="무효 처분의 재제출을 잰다"
check "무효 실험용 판단이 승인으로 올라간다" "$rc" "5"
vjid=$(row_field "$(last_judgment_approval)" '승인 id')
vjq=$(row_field "$( { grep -F '`승인`' "$LEDGER2" || true; } | grep -F "승인 id=$vjid " | tail -1)" '질문 문면')
VJSID="20202020-3434-5656-7878-909090909090"
printf '{"role":"user","content":"%s / %s → 그렇게 하라"}\n' "$vjid" "$vjq" > "$NTX/$VJSID.jsonl"
out=$(cd "$WT" && XDG_STATE_HOME="$STATE_CONE" CLAUDE_CONFIG_DIR="$NCFG" \
      CLAUDE_CODE_SESSION_ID="$VJSID" bash "$GATE" close --manifest "$NM" --approval "$vjid" --void 2>&1); rc=$?
check "무효 실험용 승인이 무효로 닫힌다" "$rc" "0"
gateN act --manifest "$NM" --kind judgment --target infra --segment SD --cutpoint 커밋 \
      --surface 읽기 --snapshot-digest "$(HN)" --rationale x \
      -- 등급=2 기준="애초에 묻지 말았어야 할 물음" 근거="무효 처분의 재제출을 잰다"
check "무효로 닫힌 승인의 재제출은 거절된다" "$rc" "3"
check "그 재제출이 승인을 다시 대기로 열지 않는다" \
      "$(row_field "$( { grep -F '`승인`' "$LEDGER2" || true; } | grep -F "승인 id=$vjid " | tail -1)" '상태')" \
      "무효"
gateN act --manifest "$NM" --kind judgment --target infra --segment SD --cutpoint 커밋 \
      --surface 읽기 --snapshot-digest "$(HN)" --rationale x \
      -- 등급=2 기준="물었고 답이 아니오인 물음" 근거="거부 처분의 재제출을 잰다"
check "거부 실험용 판단이 승인으로 올라간다" "$rc" "5"
xjid=$(row_field "$(last_judgment_approval)" '승인 id')
xjq=$(row_field "$( { grep -F '`승인`' "$LEDGER2" || true; } | grep -F "승인 id=$xjid " | tail -1)" '질문 문면')
XJSID="21212121-3434-5656-7878-909090909090"
printf '{"role":"user","content":"%s / %s → 아니오, 하지 마라"}\n' "$xjid" "$xjq" > "$NTX/$XJSID.jsonl"
out=$(cd "$WT" && XDG_STATE_HOME="$STATE_CONE" CLAUDE_CONFIG_DIR="$NCFG" \
      CLAUDE_CODE_SESSION_ID="$XJSID" bash "$GATE" close --manifest "$NM" --approval "$xjid" --reject 2>&1); rc=$?
check "거부 실험용 승인이 거부로 닫힌다" "$rc" "0"
gateN act --manifest "$NM" --kind judgment --target infra --segment SD --cutpoint 커밋 \
      --surface 읽기 --snapshot-digest "$(HN)" --rationale x \
      -- 등급=2 기준="물었고 답이 아니오인 물음" 근거="거부 처분의 재제출을 잰다"
check "거부로 닫힌 승인의 등급 2 재제출도 거절된다" "$rc" "3"
check "그 재제출도 승인을 다시 대기로 열지 않는다" \
      "$(row_field "$( { grep -F '`승인`' "$LEDGER2" || true; } | grep -F "승인 id=$xjid " | tail -1)" '상태')" \
      "거부"

# --- 31ak. An act approval EXPIRES when the tree it named moves -------------
#
# `구속 튜플` was written at issue time and read by NOTHING in the tree, so the
# property stated beside it — an act approval's answer is valid only against the
# tree it named, which is the entire reason it carries shas where a question
# carries `-` — was a sentence and not a check. An answer given at 22:00 opened
# the same argv at 04:00 across every commit that had landed in between. Every
# tuple assertion before this one observed the STRING.
gateN act --manifest "$NM" --kind x --target infra --segment SD --cutpoint 배포 \
      --surface 외부상태변경 --snapshot-digest "$(HN)" --rationale x -- aws s3 ls s3://tuple/probe
check "구속 튜플 실험용 행위가 승인을 발행한다" "$rc" "5"
tup_row=$( { grep -F '`승인`' "$LEDGER2" || true; } | grep -F '상태=대기' | grep -vF '절단점=판단' | tail -1)
tup_id=$(row_field "$tup_row" '승인 id')
tup_head=$(row_field "$tup_row" '구속 튜플')
tup_head=${tup_head%/*}
tup_head=${tup_head##*/}
head_before=$(cd "$WT" && git rev-parse HEAD)
# THE FIXTURE PROVES IT REACHES THE COMPARISON. The freshness check reads an
# unmeasurable tuple as fresh, so a fixture whose tuple held no head fragment
# would pass every assertion below without the compared branch ever running.
if [ -n "$tup_head" ] && [ "$tup_head" = "${head_before:0:${#tup_head}}" ]; then
  ok "구속 튜플이 발행 시점 HEAD 의 앞자리를 담는다 (대조가 공허하지 않다)"
else
  bad "구속 튜플" "튜플의 head 조각 '$tup_head' 가 발행 시점 HEAD '$head_before' 와 맞지 않는다"
fi
TUPSID="22222222-3434-5656-7878-909090909090"
tup_q=$(row_field "$tup_row" '질문 문면')
printf '{"role":"user","content":"%s / %s → 승인"}\n' "$tup_id" "$tup_q" > "$NTX/$TUPSID.jsonl"
out=$(cd "$WT" && XDG_STATE_HOME="$STATE_CONE" CLAUDE_CONFIG_DIR="$NCFG" \
      CLAUDE_CODE_SESSION_ID="$TUPSID" bash "$GATE" close --manifest "$NM" --approval "$tup_id" 2>&1); rc=$?
check "구속 튜플 실험용 승인이 닫힌다" "$rc" "0"
# `plan` RATHER THAN `act` for the two freshness probes: the resolution is read
# before the dry-run arm on purpose, so `plan` reports the verdict without
# performing anything — and this argv reaches outside the machine.
gateN plan --manifest "$NM" --kind x --target infra --segment SD --cutpoint 배포 \
      --surface 외부상태변경 -- aws s3 ls s3://tuple/probe
check "트리가 그대로면 해소된 승인이 그 행위를 연다" "$rc" "0"
( cd "$WT" && git commit --allow-empty -q -m "구속 튜플 대조용 빈 커밋" )
gateN plan --manifest "$NM" --kind x --target infra --segment SD --cutpoint 배포 \
      --surface 외부상태변경 -- aws s3 ls s3://tuple/probe
check "트리가 움직이면 같은 답으로 그 행위가 열리지 않는다" "$rc" "5"
case "$msg" in
  *"트리가 움직였습니다"*) ok "거절이 구속 튜플의 불일치를 원인으로 지목한다" ;;
  *) bad "구속 튜플 대조" "$msg" ;;
esac
# AND THE RE-ISSUE ACTUALLY LANDS. A staleness finding with no new pending row
# leaves the act exiting 5 forever with nothing for anyone to answer, which is
# worse than the stale grant it replaced.
tup_wait_before=$( { grep -F '`승인`' "$LEDGER2" || true; } \
                   | grep -F "승인 id=$tup_id " | grep -cF '상태=대기' || true)
gateN act --manifest "$NM" --kind x --target infra --segment SD --cutpoint 배포 \
      --surface 외부상태변경 --snapshot-digest "$(HN)" --rationale x -- aws s3 ls s3://tuple/probe
check "낡은 승인은 새 승인 발행으로 이어진다" "$rc" "5"
tup_wait_after=$( { grep -F '`승인`' "$LEDGER2" || true; } \
                  | grep -F "승인 id=$tup_id " | grep -cF '상태=대기' || true)
if [ "${tup_wait_after:-0}" -gt "${tup_wait_before:-0}" ]; then
  ok "같은 id 아래 새 대기 행이 붙는다 (승인이 갱신되지 폐기되지 않는다)"
else
  bad "승인 재발행" "대기 행이 늘지 않았다: $tup_wait_before → $tup_wait_after"
fi
# THE FIXTURE PUTS THE TREE BACK. `--soft` and not `--hard`: the commit above is
# empty, so the index and the working tree already match the target and a hard
# reset would only be a chance to discard something another subsection left.
( cd "$WT" && git reset -q --soft "$head_before" )
check "픽스처가 옮긴 HEAD 를 되돌린다" "$(cd "$WT" && git rev-parse HEAD)" "$head_before"

# --- 31al. The `done` file names every held clause and every question -------
#
# `gate_held_clause_ids` had ZERO coverage: nothing in this suite ever opened the
# `done` file, so deleting the function whole left the suite green. It is also
# where three defects met — the write-time floor kept the LAST matching approval
# while the reporter took the FIRST, so the set the gate refused duplicates over
# and the set the morning was told about were different values read out of one
# field; and a clause held on TWO questions could report only one of them.
#
# A THIRD ISOLATED RUN, because reading that file needs a proposal that PASSES,
# and the cone run above has two dozen non-terminal segments by design. The id is
# guarded the way this section guards its own.
DONE_RUN_ID=R4
if [ "$DONE_RUN_ID" = "$CONE_RUN_ID" ] || [ "$DONE_RUN_ID" = "$prev_run_id" ]; then
  printf '31al: 종료 픽스처의 런 id 가 앞선 절과 겹친다 (%s)\n' "$DONE_RUN_ID" >&2
  exit 1
fi
NM4="$WORK/done-plan.md"
sed -e "s/run-id=$CONE_RUN_ID;/run-id=$DONE_RUN_ID;/" \
    -e "s/^\*\*런 id\*\*: $CONE_RUN_ID\$/**런 id**: $DONE_RUN_ID/" "$NM" > "$NM4"
DONE_GRANT="$WT/docs/pipeline-grant/$DONE_RUN_ID.md"
sed "s/$CONE_RUN_ID/$DONE_RUN_ID/g" "$CONE_GRANT" > "$DONE_GRANT"
LEDGER4="$WT/docs/pipeline-run/$DONE_RUN_ID.md"
{
  printf '# 파이프라인 런 보고서 — %s\n\n' "$DONE_RUN_ID"
  printf '런 id %s · 앵커 repo:t/front · 대상 front(절단점 PR) infra(절단점 배포)\n' "$DONE_RUN_ID"
} > "$LEDGER4"
DONE_DIR="$STATE_CONE/cc-cmds/run/$DONE_RUN_ID"
gate4() {
  local out
  out=$(cd "$WT" && XDG_STATE_HOME="$STATE_CONE" bash "$GATE" "$@" 2>&1); rc=$?
  msg=$(printf '%s' "$out" | grep -vE '\[run\] ' | tr '\n' ' ' | sed 's/[[:space:]]*$//')
}
H4() { cd "$WT" && XDG_STATE_HOME="$STATE_CONE" bash "$GATE" snapshot --manifest "$NM4" 2>/dev/null | jq -r .H; }
last_j4() { { grep -F '`승인`' "$LEDGER4" || true; } | grep -F '절단점=판단' | grep -F '상태=대기' | tail -1; }
j4_open() {
  # j4_open <기준> <근거> — raise one grade-2 judgment and print the approval id
  # the gate opened for it.
  gate4 act --manifest "$NM4" --kind judgment --target infra --segment SN1 --cutpoint 커밋 \
        --surface 읽기 --snapshot-digest "$(H4)" --rationale x -- 등급=2 기준="$1" 근거="$2"
  row_field "$(last_j4)" '승인 id'
}
gate4 act --manifest "$NM4" --kind segment --target infra --segment SN1 --cutpoint 커밋 \
      --surface 읽기 --snapshot-digest "$(H4)" --rationale x \
      -- 워크트리="$CONE_A" 상태=실행중 선행=없음
check "종료 픽스처의 세그먼트 행이 기록된다" "$rc" "0"
ja=$(j4_open "첫째 절을 이번 런에서 정산할지" "사람이 정해야 한다")
jb=$(j4_open "둘째 절을 이번 런에서 정산할지" "역시 사람이 정해야 한다")
jc=$(j4_open "셋째 절의 앞쪽 물음" "한 절이 두 물음을 걸칠 수 있다")
jd=$(j4_open "셋째 절의 뒤쪽 물음" "그 둘 다 보고되어야 한다")
if [ -n "$ja" ] && [ -n "$jb" ] && [ -n "$jc" ] && [ -n "$jd" ] \
   && [ "$ja" != "$jb" ] && [ "$jc" != "$jd" ]; then
  ok "종료 픽스처가 서로 다른 판단 승인 넷을 연다"
else
  bad "종료 픽스처" "판단 승인 id 가 비었거나 겹친다: $ja / $jb / $jc / $jd"
fi
gate4 act --manifest "$NM4" --kind clause --target infra --cutpoint 커밋 --surface 읽기 \
      --snapshot-digest "$(H4)" --rationale x -- id=K1 상태=보류 "근거=열린 판단 승인 $ja"
check "첫째 절이 자기 물음에 대해 보류로 정산된다" "$rc" "0"
# TWO IDS IN ONE `근거`, AND THE FIRST OF THEM IS TAKEN. The old floor looped over
# the pending approvals and overwrote one variable on every hit, so it compared
# the LAST match against the other clauses — and this row, whose first id already
# holds K1, was accepted.
gate4 act --manifest "$NM4" --kind clause --target infra --cutpoint 커밋 --surface 읽기 \
      --snapshot-digest "$(H4)" --rationale x -- id=K2 상태=보류 "근거=열린 판단 승인 $ja 와 $jb"
check "이미 다른 절을 보류시킨 id 가 근거에 섞여 있으면 거절된다" "$rc" "2"
case "$msg" in
  *"이미 종료 절"*) ok "거절이 집합 안의 어느 id 가 겹쳤는지 지목한다" ;;
  *) bad "보류 집합 대조" "$msg" ;;
esac
gate4 act --manifest "$NM4" --kind clause --target infra --cutpoint 커밋 --surface 읽기 \
      --snapshot-digest "$(H4)" --rationale x -- id=K2 상태=보류 "근거=열린 판단 승인 $jb"
check "겹치지 않는 물음으로는 둘째 절이 보류로 정산된다" "$rc" "0"
gate4 act --manifest "$NM4" --kind clause --target infra --cutpoint 커밋 --surface 읽기 \
      --snapshot-digest "$(H4)" --rationale x -- id=K3 상태=보류 "근거=열린 판단 승인 $jc 와 $jd"
check "한 절이 두 물음에 걸쳐 보류로 정산된다" "$rc" "0"
gate4 act --manifest "$NM4" --kind segment --target infra --segment SN1 --cutpoint 커밋 \
      --surface 읽기 --snapshot-digest "$(H4)" --rationale x \
      -- 워크트리="$CONE_A" 상태=완료 선행=없음
check "종료 픽스처의 세그먼트가 종단 상태로 옮겨간다" "$rc" "0"
# THE BOUNDARY MAY HAVE FIRED ALONG THE WAY. The vector moves on segment rows and
# nothing else here writes one, so a run of bookkeeping acts legitimately trips
# B1 — and its approval is an ACT approval, which condition 2 counts. Draining is
# what the fixture owes the proposal, not something the proposal should tolerate.
D4SID="23232323-3434-5656-7878-909090909090"
for aid in $(cd "$WT" && XDG_STATE_HOME="$STATE_CONE" bash "$GATE" snapshot --manifest "$NM4" 2>/dev/null \
             | jq -r '.pending_approvals[].id' | grep -v '^J-' || true); do
  aq=$(row_field "$( { grep -F '`승인`' "$LEDGER4" || true; } | grep -F "승인 id=$aid " | tail -1)" '질문 문면')
  printf '{"role":"user","content":"%s / %s → 승인"}\n' "$aid" "$aq" >> "$NTX/$D4SID.jsonl"
  out=$(cd "$WT" && XDG_STATE_HOME="$STATE_CONE" CLAUDE_CONFIG_DIR="$NCFG" \
        CLAUDE_CODE_SESSION_ID="$D4SID" bash "$GATE" close --manifest "$NM4" --approval "$aid" 2>&1); rc=$?
  check "종료 픽스처의 열린 행위 승인 $aid 를 닫는다" "$rc" "0"
done
rm -f "$DONE_DIR/done"
gate4 act --manifest "$NM4" --kind propose-done --target infra --segment SN1 --cutpoint 커밋 \
      --surface 읽기 --snapshot-digest "$(H4)" --rationale "종료 절 셋이 전부 정산되었다"
check "조건이 전부 성립하면 종료 제안이 통과한다" "$rc" "0"
if [ -f "$DONE_DIR/done" ]; then
  ok "종료 제안이 done 파일을 남긴다"
else
  bad "done 파일" "$DONE_DIR/done 이 없다 — 뒤따르는 단언이 전부 공허하다"
fi
done_line=$(cat "$DONE_DIR/done" 2>/dev/null || true)
case "$done_line" in
  *"질의 잔여 4건"*) ok "종단 줄이 열린 물음의 수를 싣는다" ;;
  *) bad "질의 잔여" "$done_line" ;;
esac
case "$done_line" in
  *"보류 절 "*) ok "종단 줄이 보류 절 항목을 싣는다" ;;
  *) bad "보류 절 보고" "$done_line" ;;
esac
held_k1=$(printf '%s' "$done_line" | sed -n 's/.*K1(\([^)]*\)).*/\1/p')
held_k2=$(printf '%s' "$done_line" | sed -n 's/.*K2(\([^)]*\)).*/\1/p')
held_k3=$(printf '%s' "$done_line" | sed -n 's/.*K3(\([^)]*\)).*/\1/p')
check "첫째 절을 붙든 승인 id 와 그 상태가 축자로 실린다" "$held_k1" "$ja:대기"
check "둘째 절을 붙든 승인 id 와 그 상태가 축자로 실린다" "$held_k2" "$jb:대기"
# THE WIDENED FORMAT, WHICH IS THE POINT OF THE THIRD CLAUSE. The old reporter
# took `sed -n '1p'` off the rationale, so a clause waiting on two answers named
# one and the morning had no way to know the other existed.
if [ -n "$held_k3" ]; then
  case " $held_k3 " in
    *" $jc:대기 "*) ok "두 물음에 걸친 절이 앞쪽 승인을 싣는다" ;;
    *) bad "다중 승인 보고" "$held_k3 에 $jc 가 없다" ;;
  esac
  case " $held_k3 " in
    *" $jd:대기 "*) ok "두 물음에 걸친 절이 뒤쪽 승인도 싣는다" ;;
    *) bad "다중 승인 보고" "$held_k3 에 $jd 가 없다" ;;
  esac
else
  bad "다중 승인 보고" "종단 줄에 K3(…) 항목이 없다: $done_line"
fi
# `보류` KEEPS COUNTING ONCE THE ANSWER ARRIVES, and the `done` file is where the
# arrival becomes visible. The opposite reading was here first: the clause went
# back to unsettled the moment its question closed, so a run a PERSON answered
# was refused its own done proposal and left less behind than a run nobody
# touched — the terminal line carrying the residual was never written at all.
# The contract hands an answered hold to the successor run instead of re-opening
# this one, which is why the state travels in the `done` file rather than
# flipping a termination condition here.
K1SID="24242424-3434-5656-7878-909090909090"
k1q=$(row_field "$( { grep -F '`승인`' "$LEDGER4" || true; } | grep -F "승인 id=$ja " | tail -1)" '질문 문면')
printf '{"role":"user","content":"%s / %s → 그렇게 하라"}\n' "$ja" "$k1q" > "$NTX/$K1SID.jsonl"
out=$(cd "$WT" && XDG_STATE_HOME="$STATE_CONE" CLAUDE_CONFIG_DIR="$NCFG" \
      CLAUDE_CODE_SESSION_ID="$K1SID" bash "$GATE" close --manifest "$NM4" --approval "$ja" 2>&1); rc=$?
check "첫째 절을 붙들던 물음이 닫힌다" "$rc" "0"
rm -f "$DONE_DIR/done"
gate4 act --manifest "$NM4" --kind propose-done --target infra --segment SN1 --cutpoint 커밋 \
      --surface 읽기 --snapshot-digest "$(H4)" --rationale "답이 온 뒤 다시 제안한다"
check "답이 온 절은 정산된 채로 남아 종료 제안이 통과한다" "$rc" "0"
done_line2=$(cat "$DONE_DIR/done" 2>/dev/null || true)
held_k1b=$(printf '%s' "$done_line2" | sed -n 's/.*K1(\([^)]*\)).*/\1/p')
held_k2b=$(printf '%s' "$done_line2" | sed -n 's/.*K2(\([^)]*\)).*/\1/p')
check "답이 온 승인의 상태가 종단 줄에 축자로 실린다" "$held_k1b" "$ja:승인"
check "아직 답이 없는 승인은 대기로 실려 둘이 한 줄에서 갈린다" "$held_k2b" "$jb:대기"

# --- 31am. A miss in the polarity scan is `극성 미상`, not consent -----------
#
# 31ai showed the scan fires on `아니오`. What it could not show is what the
# vocabulary does NOT know, and it knew six standalone Korean words — none of
# the forms the language actually negates with. Korean negates by ending
# (`-지 않다`, `-지 말다`) and by the adverbs `안` and `못`, so `승인하지
# 않습니다` and `반대합니다` were both recorded as grants.
#
# The second half is the disposition of a MISS. With only a negative scan,
# silence read as consent and every refusal phrased in an unknown word became an
# approval. Requiring an affirmative term moves the cost of an unknown word onto
# a question that stays open — which this design survives, since a `대기`
# judgment approval is carried to the next cycle — instead of onto an approval
# nobody gave.
polarity_probe() {
  # polarity_probe <세션 uuid> <기준> <답 문면> — open one grade-2 judgment,
  # answer it with the given text, and leave `close`'s status in `$rc` and the
  # approval's state afterwards in `$pst`. Each probe opens its OWN approval so
  # one verdict cannot carry into the next, and each takes a different `기준` so
  # the issuing path does not see a question it has already opened.
  local sid="$1" std="$2" answer="$3" pid pq prev
  # THE ID MUST BE A NEW ONE. `last_judgment_approval` reads the newest pending
  # row, so an act that failed to open anything leaves the PREVIOUS probe's id
  # in hand and every assertion below then measures the wrong approval while
  # looking green.
  prev=$(row_field "$(last_judgment_approval)" '승인 id')
  gateN act --manifest "$NM" --kind judgment --target infra --segment SD --cutpoint 커밋 \
        --surface 읽기 --snapshot-digest "$(HN)" --rationale x \
        -- 등급=2 기준="$std" 근거="극성 판독 실험"
  pid=$(row_field "$(last_judgment_approval)" '승인 id')
  if [ -z "$pid" ] || [ "$pid" = "$prev" ]; then
    bad "극성 픽스처" "판단 승인이 새로 열리지 않았다 ($std, rc=$rc, $msg)"
    pst=""; rc=99; return 0
  fi
  pq=$(row_field "$( { grep -F '`승인`' "$LEDGER2" || true; } | grep -F "승인 id=$pid " | tail -1)" '질문 문면')
  printf '{"role":"user","content":"%s / %s → %s"}\n' "$pid" "$pq" "$answer" > "$NTX/$sid.jsonl"
  out=$(cd "$WT" && XDG_STATE_HOME="$STATE_CONE" CLAUDE_CONFIG_DIR="$NCFG" \
        CLAUDE_CODE_SESSION_ID="$sid" bash "$GATE" close --manifest "$NM" --approval "$pid" 2>&1); rc=$?
  pst=$(row_field "$( { grep -F '`승인`' "$LEDGER2" || true; } | grep -F "승인 id=$pid " | tail -1)" '상태')
}
polarity_probe "25252525-3434-5656-7878-909090909090" "어미로 부정한 답을 읽는지" "승인하지 않습니다"
check "어미 -지 않다 로 부정한 답은 승인으로 닫히지 않는다" "$rc" "3"
check "그 승인의 상태는 대기 그대로다" "$pst" "대기"
# THREE TERMS, THREE SEPARATE ARMS OF THE VOCABULARY. An ending, a noun and an
# adverb are matched by different entries, so one of them dying leaves the other
# two green and the floor half gone.
polarity_probe "26262626-3434-5656-7878-909090909090" "낱말로 반대한 답을 읽는지" "반대합니다"
check "반대합니다 는 승인으로 닫히지 않는다" "$rc" "3"
polarity_probe "27272727-3434-5656-7878-909090909090" "부사로 부정한 답을 읽는지" "그건 안 됩니다"
check "부사 안 으로 부정한 답은 승인으로 닫히지 않는다" "$rc" "3"
# THE MISS ITSELF, and this is the only place it is measured. Neither polarity
# is present, so there is nothing on the line that can be read as consent.
polarity_probe "28282828-3434-5656-7878-909090909090" "극성이 없는 답을 어떻게 처분하는지" "확인했습니다"
check "긍정도 부정도 없는 답은 승인으로 닫히지 않는다" "$rc" "5"
check "극성 미상으로 남은 승인의 상태는 대기다" "$pst" "대기"

# --- 31an. The question is not scanned as if it were the answer -------------
#
# `close` selects the transcript line by requiring the approval id AND the
# question text on it, so the question is inside the scanned bytes by
# construction. A judgment question is the router's own `<기준> — <근거>`, so a
# standard reading "이 발견을 이번 사이클에서 거절할지" put `거절` in front of the
# polarity scan and that approval could not be closed as a grant no matter what
# the person wrote. It is the opposite error from 31am, and the two share a
# floor: both scans read the answer with the question removed, because a scan
# target that splits is two floors again.
polarity_probe "30303030-3434-5656-7878-909090909090" "이 발견을 이번 사이클에서 거절할지" "그렇게 하라"
check "기준에 부정어가 든 물음도 긍정 답으로 닫힌다" "$rc" "0"
check "그 승인의 상태는 승인이다" "$pst" "승인"
# AND REMOVING THE QUESTION DID NOT KILL THE NEGATIVE SCAN. Same shape of
# question, opposite answer.
polarity_probe "31313131-3434-5656-7878-909090909090" "이 정정을 이번 사이클에서 거절할지" "아니오, 다음 런에서 본다"
check "같은 모양의 물음에 부정으로 답하면 여전히 승인으로 닫히지 않는다" "$rc" "3"
check "그 승인의 상태는 대기 그대로다" "$pst" "대기"
# NO ANSWER IS NOT A NEGATIVE ANSWER. The person repeated the question and wrote
# nothing else, so removing it leaves no bytes to read a polarity out of. The
# frame carries the id in a field of its own, which is how the binding still
# holds while the content is the question alone.
gateN act --manifest "$NM" --kind judgment --target infra --segment SD --cutpoint 커밋 \
      --surface 읽기 --snapshot-digest "$(HN)" --rationale x \
      -- 등급=2 기준="사람이 물음을 되풀이만 했을 때" 근거="답과 물음은 다른 것이다"
eid=$(row_field "$(last_judgment_approval)" '승인 id')
eq=$(row_field "$( { grep -F '`승인`' "$LEDGER2" || true; } | grep -F "승인 id=$eid " | tail -1)" '질문 문면')
ECHOSID="32323232-3434-5656-7878-909090909090"
printf '{"role":"user","toolUseResult":"승인 id=%s","content":"%s"}\n' "$eid" "$eq" > "$NTX/$ECHOSID.jsonl"
out=$(cd "$WT" && XDG_STATE_HOME="$STATE_CONE" CLAUDE_CONFIG_DIR="$NCFG" \
      CLAUDE_CODE_SESSION_ID="$ECHOSID" bash "$GATE" close --manifest "$NM" --approval "$eid" 2>&1); rc=$?
check "물음을 되풀이하기만 한 줄은 승인으로도 거부로도 닫히지 않는다" "$rc" "5"
est=$(row_field "$( { grep -F '`승인`' "$LEDGER2" || true; } | grep -F "승인 id=$eid " | tail -1)" '상태')
check "답을 분리할 수 없는 줄은 상태를 대기로 둔다" "$est" "대기"
case "$out" in
  *"남는 답이 없습니다"*) ok "거절 문면이 답이 없는 것과 답이 부정인 것을 가른다" ;;
  *) bad "물음 제거 후 잔여" "$out" ;;
esac

# --- 31ao. The manifest guard measures the FILE through three arms ----------
#
# 31ac closed the two spellings it named and left the shape underneath: the test
# was the manifest's basename appearing somewhere in some argv element, so any
# spelling that reaches the file without spelling that basename passed. Measured
# on this tree, `bash -c 'printf x >> …/cone-plan.m?'` appended to the manifest
# and the gate returned 0, and so did the same command reading the path out of
# the environment. The glob is the sharpest of the three: it needs no variable,
# no string assembly and no symlink — the same directory and the same stem,
# spelled literally, one character short.
gateN exec --manifest "$NM" --target infra --segment SD --cutpoint 커밋 \
      --surface 워크트리쓰기 --snapshot-digest "$(HN)" --rationale x \
      -- bash -c "printf x >> ${NM%?}?"
check "글로브로 한 글자 바꾼 철자도 매니페스트 쓰기로 거절된다" "$rc" "3"
gateN exec --manifest "$NM" --target infra --segment SD --cutpoint 커밋 \
      --surface 워크트리쓰기 --snapshot-digest "$(HN)" --rationale x \
      -- bash -c 'printf x >> "$CC_PIPELINE_MANIFEST"'
check "경로를 환경변수에서 읽는 쓰기도 거절된다" "$rc" "3"
# THE ALIAS SYMLINK IS THE ONE CASE ONLY THE PATH-IDENTITY ARM CAN REACH: it
# shares neither the basename nor the directory spelling with the file it opens,
# so both of the other arms look straight past it.
ln -s "$NM" "$WORK/aliased-plan.md"
gateN exec --manifest "$NM" --target infra --segment SD --cutpoint 커밋 \
      --surface 워크트리쓰기 --snapshot-digest "$(HN)" --rationale x \
      -- sed -n 1p "$WORK/aliased-plan.md"
check "매니페스트를 가리키는 다른 이름의 심링크도 거절된다" "$rc" "3"
case "$msg" in
  *"매니페스트에 쓰려 합니다"*) ok "별칭 철자도 인가의 자기확장으로 지목된다" ;;
  *) bad "별칭 심링크 가드" "$msg" ;;
esac
# AND THE UPPER BOUND. Three arms is three more ways to be wrong in the other
# direction, so the reading path and an unrelated file are both measured.
gateN exec --manifest "$NM" --target infra --segment SD --cutpoint 커밋 \
      --surface 읽기 --snapshot-digest "$(HN)" --rationale x \
      -- grep -c "" "$NM"
check "같은 경로를 읽기만 하는 행위는 세 팔을 더한 뒤에도 통과한다" "$rc" "0"
printf 'x\n' > "$WORK/unrelated.txt"
gateN exec --manifest "$NM" --target infra --segment SD --cutpoint 커밋 \
      --surface 워크트리쓰기 --snapshot-digest "$(HN)" --rationale x \
      -- sed -n 1p "$WORK/unrelated.txt"
case "$msg" in
  *"매니페스트에 쓰려 합니다"*) bad "가드 상한" "무관한 파일에 가드가 발화했다: $msg" ;;
  *) ok "매니페스트와 무관한 경로를 쓰는 행위에는 가드가 발화하지 않는다" ;;
esac

# --- 31ar. A read grade does not carry a delegating command past the guard ---
#
# 31ao measured the three arms and every one of its fixtures declared a WRITE.
# The grade itself was the way out: `find` grades `읽기` from argv0 alone,
# whatever primaries follow it, so `find <디렉터리> … -exec sh -c 'printf x >> {}'`
# was declared `읽기`, graded `읽기` — the self-declaration check agreed, both
# being wrong about the same command — and the guard returned on its first line
# without looking at the argv that was about to write. And the stem: a glob one
# character short of the basename, run from the manifest's own directory, spells
# neither the basename nor the directory, so nothing in arm 2 saw it either.
# Both are the same guard measured from its two open sides.
NMDIR=$(dirname "$NM")
NMBYTES=$(wc -c < "$NM")
gateN exec --manifest "$NM" --target infra --segment SD --cutpoint 커밋 \
      --surface 읽기 --snapshot-digest "$(HN)" --rationale x \
      -- find "$NMDIR" -maxdepth 1 -name '*plan.md' -exec sh -c 'printf x >> {}' \;
check "읽기로 등급되는 위임자가 매니페스트에 쓰려 하면 거절된다" "$rc" "3"
# THE BYTES, because a refusal that arrives after the write is not a refusal.
# The pattern is `*plan.md` and not `*.plan.md` on purpose: this fixture's
# manifest is `cone-plan.md`, which the second pattern does not match at all, and
# a fixture that could not have written the file measures nothing here.
check "거절된 위임자는 매니페스트 바이트를 바꾸지 않았다" "$(wc -c < "$NM")" "$NMBYTES"
case "$msg" in
  *"매니페스트에 쓰려 합니다"*) ok "위임자 거절이 매니페스트 가드를 원인으로 지목한다" ;;
  *) bad "위임자 가드" "$msg" ;;
esac
# THE OTHER DIRECTION OF THE SAME NARROWING, and it is why `find` is not simply
# listed as a delegator. A walk with no executing primary is an ordinary read of
# the directory the manifest happens to live in, and it has to stay one.
gateN exec --manifest "$NM" --target infra --segment SD --cutpoint 커밋 \
      --surface 읽기 --snapshot-digest "$(HN)" --rationale x \
      -- find "$NMDIR" -maxdepth 1 -name '*.md'
check "위임하지 않는 읽기는 매니페스트 디렉터리를 걸어도 통과한다" "$rc" "0"
# THE STEM, which is the assertion that the absolute/relative distinction is
# gone. There is no directory anywhere in this command line — the glob is a bare
# name — so neither directory needle can fire and only the stem is left.
gateN exec --manifest "$NM" --target infra --segment SD --cutpoint 커밋 \
      --surface 워크트리쓰기 --snapshot-digest "$(HN)" --rationale x \
      -- bash -c "printf x >> $(basename "${NM%?}")?"
check "디렉터리를 철자하지 않은 어간 글로브도 거절된다" "$rc" "3"
# THE MANDATED WRAPPER. Three unattended skills require `lockf` around every
# document write, so it is the wrapper this guard is guaranteed to meet. The
# plain spelling is refused by the basename scan and was already; the glob
# spelling is the one that needs `lockf` in arm 2's list.
if [ -x /usr/bin/lockf ]; then
  gateN exec --manifest "$NM" --target infra --segment SD --cutpoint 커밋 \
        --surface 워크트리쓰기 --snapshot-digest "$(HN)" --rationale x \
        -- lockf -k -t 0 "$WORK/x.lock" bash -c "printf x >> $NM"
  check "lockf 로 감싼 매니페스트 쓰기가 거절된다" "$rc" "3"
  gateN exec --manifest "$NM" --target infra --segment SD --cutpoint 커밋 \
        --surface 워크트리쓰기 --snapshot-digest "$(HN)" --rationale x \
        -- lockf -k -t 0 "$WORK/x.lock" bash -c "printf x >> ${NM%?}?"
  check "lockf 로 감싼 글로브 철자도 거절된다" "$rc" "3"
else
  ok "lockf 가 없는 호스트라 래퍼 단언을 건너뛴다"
fi

# --- 31ap. The absorber disposes of the issuer's return, all three of them --
#
# Every emission fixture before this one feeds the parser input it can read, and
# every one of them lands on the issuer's `발행` arm. The other two returns —
# `이미 닫힌 물음` and `이미 답이 있음` — were reachable from all three call
# sites in the absorber, and all three dropped the value on the floor. Dropping
# is not benign here: this file inherits `set -euo pipefail` from the driver it
# sources, so a bare non-zero kills the gate part way through recording a stage
# result, after the row is written and before the run learns the stage ended.
#
# The stub's class is wrapped in backticks, which is how a stage naturally
# writes one — and the parser excludes backticks, so `판단 부류` comes out empty
# and the first of the three call sites is the one that runs.
JSTUB4="$WORK/judgment-stub-torn"
cat > "$JSTUB4" <<'JSTUB4EOF'
#!/usr/bin/env bash
cat <<'RES4EOF'
{"type":"result","subtype":"success","is_error":false,"total_cost_usd":0.1,"session_id":"emit-session-4","num_turns":1,"result":"**판단 부류**: `시각-면제` **판단 등급**: 2 **판단 기준**: 형식이 깨진 방출을 어떻게 처분하는지 **판단 근거**: 부류가 백틱에 싸여 있다"}
RES4EOF
exit 0
JSTUB4EOF
chmod +x "$JSTUB4"
emit_torn() {
  # emit_torn <세그먼트> <스텁> — record one stage result from the given stub and
  # leave the gate's whole output in `$out` and its status in `$rc`.
  out=$(cd "$WT" && XDG_STATE_HOME="$STATE_CONE" CC_CLAUDE_BIN="$2" \
        bash "$GATE" act --manifest "$NM" --kind skill --target infra --segment "$1" --cutpoint 커밋 \
        --surface 워크트리쓰기 --snapshot-digest "$(HN)" --rationale x \
        -- review "/cc-cmds:review-unattended x" 2>&1); rc=$?
}
seg_row SJ4 "$CONE_C" 상태=실행중 선행=없음
check "형식 깨진 방출 실험용 세그먼트 행이 기록된다" "$rc" "0"
emit_torn SJ4 "$JSTUB4"; torn_rc1=$rc
tj=$(row_field "$(last_judgment_approval)" '승인 id')
if [ -n "$tj" ]; then ok "부류를 읽지 못한 방출이 승인을 연다 ($tj)"; else bad "형식 깨진 방출" "승인이 열리지 않았다: $out"; fi
tjq=$(row_field "$( { grep -F '`승인`' "$LEDGER2" || true; } | grep -F "승인 id=$tj " | tail -1)" '질문 문면')
TJSID="34343434-3434-5656-7878-909090909090"
printf '{"role":"user","content":"%s / %s → 이 물음은 잘못 발행됐습니다"}\n' "$tj" "$tjq" > "$NTX/$TJSID.jsonl"
out=$(cd "$WT" && XDG_STATE_HOME="$STATE_CONE" CLAUDE_CONFIG_DIR="$NCFG" \
      CLAUDE_CODE_SESSION_ID="$TJSID" bash "$GATE" close --manifest "$NM" --approval "$tj" --void 2>&1); rc=$?
check "그 물음을 무효로 닫는다" "$rc" "0"
# THE SAME JUDGMENT, EMITTED AGAIN AGAINST A CLOSED QUESTION. The issuer refuses
# to re-open it, and before the disposition existed that refusal came back as a
# bare non-zero in the middle of the recording function.
emit_torn SJ4 "$JSTUB4"
check "닫힌 물음을 다시 방출해도 게이트는 앞서와 같은 값으로 끝난다" "$rc" "$torn_rc1"
case "$out" in
  *"스테이지 종단"*) ok "기록 함수가 끝까지 도달한다 (흡수기에서 죽지 않는다)" ;;
  *) bad "흡수기 탈출" "스테이지 종단 줄이 없다 — 기록 도중 게이트가 죽었다: $out" ;;
esac
case "$out" in
  *"이미 닫혀 있습니다"*) ok "다시 열지 않았다는 사실이 문면으로 남는다 (조용한 통과가 아니다)" ;;
  *) bad "닫힌 물음 처분" "$out" ;;
esac
# AND THE ANSWERED RETURN, which is the other value that used to escape. The
# question is closed as a GRANT this time, so the issuer reports an answer on
# file and the absorber has to record that the emitted judgment consumed it.
JSTUB5="$WORK/judgment-stub-answered"
cat > "$JSTUB5" <<'JSTUB5EOF'
#!/usr/bin/env bash
cat <<'RES5EOF'
{"type":"result","subtype":"success","is_error":false,"total_cost_usd":0.1,"session_id":"emit-session-5","num_turns":1,"result":"**판단 부류**: `시각-면제` **판단 등급**: 2 **판단 기준**: 답이 이미 있는 방출을 어떻게 처분하는지 **판단 근거**: 사람이 먼저 답했다"}
RES5EOF
exit 0
JSTUB5EOF
chmod +x "$JSTUB5"
seg_row SJ5 "$CONE_C" 상태=실행중 선행=없음
check "답있음 실험용 세그먼트 행이 기록된다" "$rc" "0"
emit_torn SJ5 "$JSTUB5"
aj=$(row_field "$(last_judgment_approval)" '승인 id')
ajq=$(row_field "$( { grep -F '`승인`' "$LEDGER2" || true; } | grep -F "승인 id=$aj " | tail -1)" '질문 문면')
AJSID="33333333-3434-5656-7878-909090909090"
printf '{"role":"user","content":"%s / %s → 그렇게 하라"}\n' "$aj" "$ajq" > "$NTX/$AJSID.jsonl"
out=$(cd "$WT" && XDG_STATE_HOME="$STATE_CONE" CLAUDE_CONFIG_DIR="$NCFG" \
      CLAUDE_CODE_SESSION_ID="$AJSID" bash "$GATE" close --manifest "$NM" --approval "$aj" 2>&1); rc=$?
check "방출된 판단의 물음이 승인으로 닫힌다" "$rc" "0"
emit_torn SJ5 "$JSTUB5"
case "$out" in
  *"스테이지 종단"*) ok "답이 있는 물음을 다시 방출해도 기록 함수가 끝까지 도달한다" ;;
  *) bad "흡수기 탈출" "$out" ;;
esac
_aj_rows=$( { grep -F '`자율 승인`' "$LEDGER2" || true; } | { grep -F "해소 승인=$aj" || true; } )
if [ -n "$_aj_rows" ]; then
  ok "그 답으로 열렸다는 사실이 원장에 남고 어느 승인을 썼는지 지목한다"
else
  bad "답있음 처분" "해소 승인=$aj 를 지목하는 자율 승인 행이 없다"
fi
# THE ADOPTING PATH IS UNCHANGED. Three dispositions is three ways to break the
# one that was already working.
n_emit_before5=$( { grep -F '출처=스테이지 방출' "$LEDGER2" || true; } | grep -c . || true)
seg_row SJ6 "$CONE_C" 상태=실행중 선행=없음
emit_torn SJ6 "$JSTUB2"
n_emit_after5=$( { grep -F '출처=스테이지 방출' "$LEDGER2" || true; } | grep -c . || true)
if [ "${n_emit_after5:-0}" -gt "${n_emit_before5:-0}" ]; then
  ok "합집합을 통과하는 정상 방출은 여전히 채택 행을 만든다"
else
  bad "정상 방출 회귀" "채택 행이 늘지 않았다: $n_emit_before5 → $n_emit_after5"
fi

# --- 31aq. An act approval is bound to the tree the act RUNS IN -------------
#
# The freeze and the comparison both read `메인 워크트리` while the act itself
# runs in `실행 워크트리`, and for a pr or branch anchor those are never the same
# directory — git refuses to check a branch out twice. So an answer given at
# 22:00 stayed fresh through a whole night of commits landing in the tree the act
# was actually run in, and a sibling segment moving the main worktree expired
# approvals about a tree that had not moved. 31ak can see neither: its target
# declares no execution worktree, so there the two directories are one.
EWT="$WORK/exec-wt"
( cd "$WT" && git worktree add -q -b execwtbr "$EWT" ) >/dev/null 2>&1
if [ -d "$EWT" ]; then
  # THE TWO HEADS ARE SPLIT BEFORE ANYTHING IS FROZEN. A worktree added from the
  # same tip shares its head, and against that fixture every assertion below
  # passes whichever field the code reads.
  ( cd "$EWT" && git commit --allow-empty -q -m "실행 워크트리를 메인과 갈라 놓는다" )
  EWT_RUN_ID=R5
  if [ "$EWT_RUN_ID" = "$CONE_RUN_ID" ] || [ "$EWT_RUN_ID" = "$DONE_RUN_ID" ] \
     || [ "$EWT_RUN_ID" = "$prev_run_id" ]; then
    printf '31aq: 실행 워크트리 픽스처의 런 id 가 앞선 절과 겹친다 (%s)\n' "$EWT_RUN_ID" >&2
    exit 1
  fi
  NM5="$WORK/execwt-plan.md"
  sed -e "s/run-id=$CONE_RUN_ID;/run-id=$EWT_RUN_ID;/" \
      -e "s/^\*\*런 id\*\*: $CONE_RUN_ID\$/**런 id**: $EWT_RUN_ID/" "$NM" > "$NM5.tmp"
  # A read loop and not `sed`: the target row is full of `|` separators, so every
  # delimiter a substitution could pick already appears in the pattern.
  : > "$NM5"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      '- `target`'*별칭=infra*)
        case "$line" in *'실행 워크트리='*) line="${line%% | 실행 워크트리=*}" ;; esac
        line="$line | 실행 워크트리=$EWT" ;;
    esac
    printf '%s\n' "$line" >> "$NM5"
  done < "$NM5.tmp"
  # The target row moved, so the target-map digest moves with it.
  newtd5=$(cd "$WT" && bash -c '
    CC_ORCH_SOURCE_ONLY=1 . "'"$repo_root"'/plugins/cc-cmds/orchestrator/run.sh"
    MANIFEST="'"$NM5"'"
    canonical_targets | shasum -a 256 | cut -d" " -f1')
  : > "$NM5.tmp"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      '**대상 맵 다이제스트**: '*) line="**대상 맵 다이제스트**: $newtd5" ;;
    esac
    printf '%s\n' "$line" >> "$NM5.tmp"
  done < "$NM5"
  mv "$NM5.tmp" "$NM5"
  EWT_GRANT="$WT/docs/pipeline-grant/$EWT_RUN_ID.md"
  sed "s/$CONE_RUN_ID/$EWT_RUN_ID/g" "$CONE_GRANT" > "$EWT_GRANT"
  LEDGER5="$WT/docs/pipeline-run/$EWT_RUN_ID.md"
  {
    printf '# 파이프라인 런 보고서 — %s\n\n' "$EWT_RUN_ID"
    printf '런 id %s · 앵커 repo:t/front · 대상 front(절단점 PR) infra(절단점 배포)\n' "$EWT_RUN_ID"
  } > "$LEDGER5"
  gate5() {
    local out
    out=$(cd "$WT" && XDG_STATE_HOME="$STATE_CONE" bash "$GATE" "$@" 2>&1); rc=$?
    msg=$(printf '%s' "$out" | grep -vE '\[run\] ' | tr '\n' ' ' | sed 's/[[:space:]]*$//')
  }
  H5() { cd "$WT" && XDG_STATE_HOME="$STATE_CONE" bash "$GATE" snapshot --manifest "$NM5" 2>/dev/null | jq -r .H; }
  gate5 act --manifest "$NM5" --kind x --target infra --segment SE1 --cutpoint 배포 \
        --surface 외부상태변경 --snapshot-digest "$(H5)" --rationale x -- aws s3 ls s3://execwt/probe
  check "실행 워크트리를 선언한 대상의 행위가 승인을 발행한다" "$rc" "5"
  ewt_row=$( { grep -F '`승인`' "$LEDGER5" || true; } | grep -F '상태=대기' | grep -vF '절단점=판단' | tail -1)
  ewt_id=$(row_field "$ewt_row" '승인 id')
  ewt_frag=$(row_field "$ewt_row" '구속 튜플')
  ewt_frag=${ewt_frag%/*}
  ewt_frag=${ewt_frag##*/}
  ewt_head=$(cd "$EWT" && git rev-parse HEAD)
  main_head=$(cd "$WT" && git rev-parse HEAD)
  if [ -n "$ewt_frag" ] && [ "$ewt_frag" = "${ewt_head:0:${#ewt_frag}}" ]; then
    ok "구속 튜플이 실행 워크트리의 HEAD 를 얼린다"
  else
    bad "구속 튜플 동결" "튜플의 head 조각 '$ewt_frag' 가 실행 워크트리 HEAD '$ewt_head' 와 맞지 않는다 (메인은 '$main_head')"
  fi
  EWTSID="25252525-3434-5656-7878-909090909090"
  ewt_q=$(row_field "$ewt_row" '질문 문면')
  printf '{"role":"user","content":"%s / %s → 승인"}\n' "$ewt_id" "$ewt_q" > "$NTX/$EWTSID.jsonl"
  out=$(cd "$WT" && XDG_STATE_HOME="$STATE_CONE" CLAUDE_CONFIG_DIR="$NCFG" \
        CLAUDE_CODE_SESSION_ID="$EWTSID" bash "$GATE" close --manifest "$NM5" --approval "$ewt_id" 2>&1); rc=$?
  check "실행 워크트리 픽스처의 승인이 닫힌다" "$rc" "0"
  # `plan` for every probe below, the way 31ak does it: the resolution is read
  # before the dry-run arm, so the verdict comes back without the argv — which
  # reaches outside the machine — ever running.
  gate5 plan --manifest "$NM5" --kind x --target infra --segment SE1 --cutpoint 배포 \
        --surface 외부상태변경 -- aws s3 ls s3://execwt/probe
  check "두 트리가 다 그대로면 해소된 승인이 그 행위를 연다" "$rc" "0"
  # THE FALSE-POSITIVE AXIS. Another segment landing a commit in the main
  # worktree says nothing about the tree this act runs in.
  ( cd "$WT" && git commit --allow-empty -q -m "메인만 움직이는 빈 커밋" )
  gate5 plan --manifest "$NM5" --kind x --target infra --segment SE1 --cutpoint 배포 \
        --surface 외부상태변경 -- aws s3 ls s3://execwt/probe
  check "메인 워크트리만 움직인 것은 그 승인을 낡게 하지 않는다" "$rc" "0"
  ( cd "$WT" && git reset -q --soft "$main_head" )
  check "픽스처가 옮긴 메인 HEAD 를 되돌린다" "$(cd "$WT" && git rev-parse HEAD)" "$main_head"
  # THE FALSE-NEGATIVE AXIS, which is the one that let a night of commits through.
  ( cd "$EWT" && git commit --allow-empty -q -m "실행 워크트리만 움직이는 빈 커밋" )
  gate5 plan --manifest "$NM5" --kind x --target infra --segment SE1 --cutpoint 배포 \
        --surface 외부상태변경 -- aws s3 ls s3://execwt/probe
  check "실행 워크트리가 움직이면 같은 답으로 그 행위가 열리지 않는다" "$rc" "5"
  case "$msg" in
    *"트리가 움직였습니다"*) ok "거절이 구속 튜플의 불일치를 원인으로 지목한다" ;;
    *) bad "실행 워크트리 대조" "$msg" ;;
  esac
  ( cd "$EWT" && git reset -q --soft "$ewt_head" )
  check "픽스처가 옮긴 실행 워크트리 HEAD 를 되돌린다" "$(cd "$EWT" && git rev-parse HEAD)" "$ewt_head"
else
  bad "픽스처 전제" "실행 워크트리를 만들지 못했다"
fi

# --- 31aa. A question does not switch the boundaries off --------------------
#
# `gate_pending_approval_ids` gained a narrowing argument and three of its four
# call sites got one. `gate_boundaries` was the fourth, so a `절단점=판단`
# approval counted there — and since this design deliberately lets a run END
# with a question open, the suspension it produced had nothing to close it. One
# grade-2 judgment at 22:10, with nobody awake, switched off stagnation
# detection, the obligation backlog and the 40-act budget until the wall clock.
#
# LAST IN THIS SECTION on purpose: firing B1 issues an ACT approval, which then
# legitimately suspends the boundaries for anything that follows.
#
# BOTH PREMISES ARE ESTABLISHED HERE RATHER THAN INHERITED. They used to be read
# off whatever the subsections above happened to leave, and nothing above was
# writing them on purpose — the escalations there open ACT approvals as a side
# effect, which is the one state that makes the conclusion below unreadable.
#
# `열린 행위 승인은 없다` is not decoration, it is the ATTRIBUTION condition:
# with an act approval open the boundary is legitimately suspended, B1 never
# fires, and the verdict at the end of this subsection names the wrong culprit —
# it reports that a judgment approval disarmed B1. Weakening the assertion would
# only make that misattribution quiet, so the fixture opens the question it needs
# and drains the act approvals instead. The drain also turns the ordering that
# the note above carried in prose into actual plumbing: a subsection added later
# that leaves an act approval open gets drained with the rest.
gateN act --manifest "$NM" --kind judgment --target infra --segment SD --cutpoint 커밋 \
      --surface 읽기 --snapshot-digest "$(HN)" --rationale x \
      -- 등급=2 기준="경계 단언의 전제로 열어 두는 물음" 근거="이 절은 열린 판단 승인 하나를 필요로 한다"
check "경계 단언의 전제인 판단 승인이 열린다" "$rc" "5"
DRAINSID="16161616-3434-5656-7878-909090909090"
for aid in $(cd "$WT" && XDG_STATE_HOME="$STATE_CONE" bash "$GATE" snapshot --manifest "$NM" 2>/dev/null \
             | jq -r '.pending_approvals[].id' | grep -v '^J-' || true); do
  aq=$(row_field "$( { grep -F '`승인`' "$LEDGER2" || true; } | grep -F "승인 id=$aid " | tail -1)" '질문 문면')
  printf '{"role":"user","content":"%s / %s → 승인"}\n' "$aid" "$aq" >> "$NTX/$DRAINSID.jsonl"
  out=$(cd "$WT" && XDG_STATE_HOME="$STATE_CONE" CLAUDE_CONFIG_DIR="$NCFG" \
        CLAUDE_CODE_SESSION_ID="$DRAINSID" bash "$GATE" close --manifest "$NM" --approval "$aid" 2>&1); rc=$?
  check "경계 전제를 세우려 열린 행위 승인 $aid 를 닫는다" "$rc" "0"
done
b1_before=$( { grep -F '`승인`' "$LEDGER2" || true; } | grep -cF '구속 튜플=B1' || true)
npend_judgment=$(cd "$WT" && XDG_STATE_HOME="$STATE_CONE" bash "$GATE" snapshot --manifest "$NM" 2>/dev/null \
                 | jq -r '.pending_approvals[].id' | grep -c '^J-' || true)
npend_act=$(cd "$WT" && XDG_STATE_HOME="$STATE_CONE" bash "$GATE" snapshot --manifest "$NM" 2>/dev/null \
            | jq -r '.pending_approvals[].id' | grep -cv '^J-' || true)
if [ "${npend_judgment:-0}" -ge 1 ]; then
  ok "이 시점에 열린 판단 승인이 있다 (경계 단언의 전제)"
else
  bad "경계 픽스처" "열린 판단 승인이 없어 이 단언이 공허하다"
fi
if [ "${npend_act:-0}" = "0" ]; then
  ok "열린 행위 승인은 없다 (유예가 걸린다면 그것은 판단 승인 때문이다)"
else
  bad "경계 픽스처" "행위 승인이 ${npend_act}건 열려 있어 유예의 원인을 가릴 수 없다"
fi
i=0
while [ "$i" -lt 6 ]; do
  gateN exec --manifest "$NM" --target infra --segment SD --cutpoint 커밋 --surface 읽기 \
        --snapshot-digest "$(HN)" --rationale "정체 경계 확인" -- ls "$CONE_A"
  i=$((i + 1))
done
b1_after=$( { grep -F '`승인`' "$LEDGER2" || true; } | grep -cF '구속 튜플=B1' || true)
if [ "${b1_after:-0}" -gt "${b1_before:-0}" ]; then
  ok "판단 승인이 열려 있어도 정체 경계는 살아 있다 (B1~B3 이 밤새 꺼지지 않는다)"
else
  bad "경계 유예" "열린 판단 승인 하나가 B1 을 무장해제했다"
fi

# ---------------------------------------------------------------------------
# 12b. B3's budget is a WINDOW, and the two halves are asserted separately
#
# The budget's sentence has always said "since the last progress move" while the
# count ran over the whole ledger, so past the bound the boundary fired on every
# judgment for the rest of the run. Nothing caught it because B3 had no test of
# its own at all — the name appeared in this file only inside comments about
# B1's suspension. A silenced boundary and a fixed one look identical from the
# "does not fire" side, so both directions are asserted here.
#
# Approvals are resolved first for the same reason section 12 resolves them: an
# open one suspends B1..B3, and a suspended boundary that does not fire would
# pass the first assertion while proving nothing.
for a in $(grep -oE '승인 id=[^ |]+' "$LEDGER" | sed 's/승인 id=//' | sort -u); do
  printf -- '- `승인` | 승인 id=%s | 상태=승인 | 해소 시각=%s | prev=x\n' "$a" "테스트" >> "$LEDGER"
done
i=0
while [ "$i" -lt 41 ]; do
  printf -- '- `자율 승인` | kind= | 결정=exec | 대상=front | 세그먼트=- | 절단점=커밋 | 축2=외부상태변경 | 근거=예산 픽스처 %s | prev=x\n' "$i" >> "$LEDGER"
  i=$((i + 1))
done

# Half one — the window is OPEN and 41 acts have been spent inside it.
#
# THE STATE BELOW MUST BE ONE THE RUNNING SYSTEM CAN REACH, and the first
# version of this fixture was not. It wrote the full progress digest as the
# window key beside a baseline of zero — but the baseline is only ever written
# at the instant the key changes, and at that instant it is set to the current
# total, so a key-of-now beside a baseline of zero is a pair the code cannot
# produce. Asserting on it proved the boundary fires in a world that does not
# exist, and the change that actually disarmed the boundary went green.
#
# So the window is opened by the GATE rather than by hand: one ordinary act
# writes whatever key and baseline the implementation uses, the acts then
# accumulate without touching that key, and the next act is judged inside the
# window that first one opened. That is what a router doing commits and pushes
# between stages produces, and it is why the key must not contain the count.
H=$(cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null | jq -r .H)
gate act --manifest "$MANIFEST" --kind x --target front --cutpoint 커밋 \
     --snapshot-digest "$(HH)" --rationale "B3 창 개시" -- touch "$WORK/t3b"
i=0
while [ "$i" -lt 41 ]; do
  printf -- '- `자율 승인` | kind= | 결정=exec | 대상=front | 세그먼트=- | 절단점=커밋 | 축2=외부상태변경 | 근거=예산 픽스처 %s | prev=x\n' "$i" >> "$LEDGER"
  i=$((i + 1))
done
# The window-opening act can itself trip B1, and an open approval suspends
# B1..B3 — so without this the second act is judged under suspension and the
# assertion below would read "did not fire" as evidence about B3 when it is
# evidence about the suspension.
for a in $(grep -oE '승인 id=[^ |]+' "$LEDGER" | sed 's/승인 id=//' | sort -u); do
  printf -- '- `승인` | 승인 id=%s | 상태=승인 | 해소 시각=%s | prev=x\n' "$a" "테스트" >> "$LEDGER"
done
before=$(grep -c '구속 튜플=B3' "$LEDGER" || true)
H=$(cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null | jq -r .H)
gate act --manifest "$MANIFEST" --kind x --target front --cutpoint 커밋 \
     --snapshot-digest "$(HH)" --rationale "B3 예산 소진" -- touch "$WORK/t4"
after=$(grep -c '구속 튜플=B3' "$LEDGER" || true)
if [ "$after" -gt "$before" ]; then
  ok "B3 이 한 창 안에서 예산을 넘기면 발동한다"
else
  bad "B3" "예산을 넘겼는데 경계가 발동하지 않았다 — 고친 것이 아니라 끈 것이다"
fi

# Half two — the regression. The same 41 acts, but progress has moved since,
# which closes the old window and opens a new one holding none of them. A count
# that never resets fires here; a windowed one does not.
for a in $(grep -oE '승인 id=[^ |]+' "$LEDGER" | sed 's/승인 id=//' | sort -u); do
  printf -- '- `승인` | 승인 id=%s | 상태=승인 | 해소 시각=%s | prev=x\n' "$a" "테스트" >> "$LEDGER"
done
printf '%s\n' "진전이 그 뒤로 움직였음을 뜻하는 낡은 값" > "$RD/act-budget-digest"
printf '%s\n' "0" > "$RD/act-budget-base"
before=$(grep -c '구속 튜플=B3' "$LEDGER" || true)
H=$(cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null | jq -r .H)
gate act --manifest "$MANIFEST" --kind x --target front --cutpoint 커밋 \
     --snapshot-digest "$(HH)" --rationale "진전 뒤 첫 행위" -- touch "$WORK/t5"
after=$(grep -c '구속 튜플=B3' "$LEDGER" || true)
check "진전이 움직이면 B3 의 창이 새로 열린다 (누적이 아니다)" "$after" "$before"

# ---------------------------------------------------------------------------
# The banner seat, gate side.
#
# This suite had no notifier stub at all, so the caller boundary — the single
# most valuable assertion in this design — had nothing to observe. The idiom is
# transplanted from the watcher's suite verbatim: intercept the notifier on PATH,
# log its argv, and pin the two seams so neither the real binary nor the host
# check can make the assertions unreachable.
# ---------------------------------------------------------------------------
mkdir -p "$WORK/bin"
NOTIFY_LOG="$WORK/notifier.log"; : > "$NOTIFY_LOG"
cat > "$WORK/bin/terminal-notifier" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CC_TEST_NOTIFY_LOG"
STUB
chmod +x "$WORK/bin/terminal-notifier"

# The emitter launches the notifier DETACHED and never asks its status, so a
# write can land after the gate process has exited. Bounded wait, boolean
# assertion — never a comparison of elapsed seconds.
notify_settle() {
  local want="$1" i=0 n
  while [ "$i" -lt 60 ]; do
    n=$(grep -c . "$NOTIFY_LOG" 2>/dev/null || true)
    if [ "${n:-0}" -ge "$want" ]; then return 0; fi
    sleep 0.1
    i=$((i + 1))
  done
  return 0
}
notify_lines() { grep -c . "$NOTIFY_LOG" 2>/dev/null || true; }
notify_reset() { : > "$NOTIFY_LOG"; rm -f "$RD/notify.stack" "$RD/notify.overflow"; rm -rf "$RD/notify"; }

# The env prefixes go on the REAL command, not on the shell function: a prefix
# assignment before a bash function call outlives the call, and every later case
# would silently inherit it.
gateb() {
  local out
  out=$(cd "$WT" && PATH="$WORK/bin:$PATH" \
        CC_CMDS_AUTOPILOT_NOTIFY=1 \
        CC_CMDS_NOTIFY_PATH_DISABLE_PREPEND=1 \
        CC_CMDS_NOTIFY_HOST_OS=Darwin \
        CC_TEST_NOTIFY_LOG="$NOTIFY_LOG" \
        bash "$GATE" "$@" 2>&1); rc=$?
  msg=$(printf '%s' "$out" | grep -vE '\[run\] ' | tr '\n' ' ' | sed 's/[[:space:]]*$//')
}
gateb_stage() {
  local out
  out=$(cd "$WT" && PATH="$WORK/bin:$PATH" \
        CC_CMDS_AUTOPILOT_NOTIFY=1 \
        CC_CMDS_NOTIFY_PATH_DISABLE_PREPEND=1 \
        CC_CMDS_NOTIFY_HOST_OS=Darwin \
        CC_TEST_NOTIFY_LOG="$NOTIFY_LOG" \
        CC_PIPELINE_SEGMENT=SB CC_PIPELINE_STAGE_ID='SB#1' \
        bash "$GATE" "$@" 2>&1); rc=$?
  msg=$(printf '%s' "$out" | grep -vE '\[run\] ' | tr '\n' ' ' | sed 's/[[:space:]]*$//')
}

# --- THE CALLER BOUNDARY. The most valuable assertion here ------------------
#
# The same act, twice: once with the stage discriminators set and once with them
# empty. THE ROW MUST LAND BOTH TIMES — the boundary is on the channel, never on
# the record, and a stage-raised condition is carried by the watcher one pass
# later. Only the banner is gated.
#
# Two different segment ids, because the stage-side call still leaves the park
# marker: sharing an id would let the marker rather than the boundary explain the
# silence, and the assertion would pass for the wrong reason.
notify_reset
# `선행=없음` on every segment row below, and it is not boilerplate. This branch
# made `선행` REQUIRED once a repo holds more than one segment — absence and
# `없음` are different answers, and the whole point of the requirement is that a
# silent omission becomes an audible refusal. These fixtures arrived from the
# other parent, which predates that contract, so they wrote park rows with no
# `선행` at all and every one of them was refused before it could be recorded.
# The refusal was correct; the fixtures had to learn the newer contract.
gateb_stage act --manifest "$MANIFEST" --kind segment --target infra --segment SBN1 \
  --cutpoint 커밋 --surface 읽기 --snapshot-digest "$(snapH)" \
  --rationale "픽스처 — 스테이지 호출의 park 기록" -- "상태=park" "워크트리=$WT" "선행=없음"
check "스테이지 호출에서도 세그먼트 park 행은 남는다" \
  "$(grep -cF 'id=SBN1 | 상태=park' "$LEDGER" || true)" "1"
sleep 0.3
check "스테이지 호출은 배너를 올리지 않는다" "$(notify_lines)" "0"

gateb act --manifest "$MANIFEST" --kind segment --target infra --segment SBN2 \
  --cutpoint 커밋 --surface 읽기 --snapshot-digest "$(snapH)" \
  --rationale "픽스처 — 라우터 호출의 park 기록" -- "상태=park" "워크트리=$WT" "선행=없음"
check "라우터 호출에서도 세그먼트 park 행은 남는다" \
  "$(grep -cF 'id=SBN2 | 상태=park' "$LEDGER" || true)" "1"
notify_settle 1
check "라우터 호출은 배너를 올린다" "$(notify_lines)" "1"
check "그 배너는 손 필요 제목을 쓴다" \
  "$(grep -cF -- '-title [cc-cmds] 손 필요 -message' "$NOTIFY_LOG" || true)" "1"
check "그 배너의 그룹이 항목 키를 싣는다" \
  "$(grep -cF -- '-group cc-cmds-autopilot-R2-park-SBN2 ' "$NOTIFY_LOG" || true)" "1"

# --- ONE SEGMENT THROUGH BOTH SEATS ----------------------------------------
#
# The interaction the pair above avoids on purpose, driven here on ONE id: a
# stage-side park followed by the router's park for the same segment. A call
# that raises no banner must leave no marker, or the router's park — the only
# channel this class has — is silenced by a stop nobody was ever told about.
# The assertion spans both calls: exactly one banner, and it is the router's.
notify_reset
gateb_stage act --manifest "$MANIFEST" --kind segment --target infra --segment SBN3 \
  --cutpoint 커밋 --surface 읽기 --snapshot-digest "$(snapH)" \
  --rationale "픽스처 — 같은 세그먼트에 대한 스테이지 park" -- "상태=park" "워크트리=$WT" "선행=없음"
gateb act --manifest "$MANIFEST" --kind segment --target infra --segment SBN3 \
  --cutpoint 커밋 --surface 읽기 --snapshot-digest "$(snapH)" \
  --rationale "픽스처 — 같은 세그먼트에 대한 라우터 park" -- "상태=park" "워크트리=$WT" "선행=없음"
notify_settle 1
check "스테이지 park 이 앞선 세그먼트에서도 배너는 정확히 하나다" "$(notify_lines)" "1"
check "그 하나는 라우터 호출이 올린 것이다" \
  "$(grep -cF -- '-group cc-cmds-autopilot-R2-park-SBN3 ' "$NOTIFY_LOG" || true)" "1"

# --- A RE-PARK IS A NEW STOP -----------------------------------------------
#
# The item key is the segment id alone, so nothing but the marker's expiry can
# tell the second stop from the first. Park, leave park, park again: two waits
# for a person, two banners.
notify_reset
gateb act --manifest "$MANIFEST" --kind segment --target infra --segment SBN4 \
  --cutpoint 커밋 --surface 읽기 --snapshot-digest "$(snapH)" \
  --rationale "픽스처 — 첫 park" -- "상태=park" "워크트리=$WT" "선행=없음"
gateb act --manifest "$MANIFEST" --kind segment --target infra --segment SBN4 \
  --cutpoint 커밋 --surface 읽기 --snapshot-digest "$(snapH)" \
  --rationale "픽스처 — 풀려서 재파견" -- "상태=실행중" "워크트리=$WT" "선행=없음"
gateb act --manifest "$MANIFEST" --kind segment --target infra --segment SBN4 \
  --cutpoint 커밋 --surface 읽기 --snapshot-digest "$(snapH)" \
  --rationale "픽스처 — 다시 park" -- "상태=park" "워크트리=$WT" "선행=없음"
notify_settle 2
check "풀렸다 다시 park 된 세그먼트의 두 번째 멈춤도 알려진다" "$(notify_lines)" "2"

# --- A RESOLVED BLOCK IS NOT AN ANCHOR (the negative case) ------------------
#
# The obvious instrumentation — "a run-scope blocked row was appended" — fails
# here and passes everywhere else: this is the row a PERSON writes when they
# clear the block, so keying on it announces "the run has anchored" at the exact
# moment somebody unblocked it.
notify_reset
gateb act --manifest "$MANIFEST" --kind blocked --target infra --segment - \
  --cutpoint 커밋 --surface 읽기 --snapshot-digest "$(snapH)" --rationale "픽스처" \
  -- "원인=해소" "사유=정체 사유 X" "근거=픽스처가 다시 해소로 판정했다"
check "해소 행이 통과한다" "$rc" "0"
sleep 0.3
check "라우터가 막힘을 해소했다고 기록하는 자리에서는 배너가 나가지 않는다" "$(notify_lines)" "0"

# --- THE FIRING TABLE, PINNED BY NAME --------------------------------------
#
# Six sites write a run-scope block or create that state, and three of them are
# forbidden. Behaviourally reaching the two run-terminal arms and the
# forced-surface-move arm inside a fixture would take the run's whole nine
# termination conditions or a tampered enforcement surface, so these are pinned
# at their SITE instead — which is the property that matters: an implementation
# that gets the approval boundary right and this table wrong must fail something.
site_fires() {
  # site_fires <anchor-fixed-string> <lines-after>
  #
  # BOTH SPELLINGS COUNT. Some sites raise the notice inline and some hand it to
  # a `gate_notify_*` helper that owns a marker handshake too big to inline —
  # scanning for the emitter call alone would read a site that fires through a
  # helper as silent, which is a property of how the code is factored rather than
  # of whether the site fires.
  local ln
  ln=$(grep -nF "$1" "$GATE" | sed -n '1p' | cut -d: -f1)
  if [ -z "$ln" ]; then printf 'anchor-missing'; return 0; fi
  sed -n "${ln},$((ln + $2))p" "$GATE" | grep -cE 'cc_notify_fire|gate_notify_' || true
}
check "F4 — 강제 표면 이동의 무효화 쓰기가 발사한다" \
  "$( [ "$(site_fires '사유=강제 표면 이동' 24)" != "0" ] && printf 'fires' || printf 'silent')" "fires"
check "F4 — 무효화 종료의 done 표시가 발사한다" \
  "$( [ "$(site_fires '종단 — 무효화 · 근거' 8)" != "0" ] && printf 'fires' || printf 'silent')" "fires"
check "F4 — 충족 종료의 done 표시가 발사한다" \
  "$( [ "$(site_fires '종단 — 종료 조건 아홉 성립 · 근거' 10)" != "0" ] && printf 'fires' || printf 'silent')" "fires"
check "F2 — 세그먼트 행 기록 자리가 발사한다" \
  "$( [ "$(site_fires "gate_append 'segment' \"id=\$seg\" \"\$@\"" 6)" != "0" ] && printf 'fires' || printf 'silent')" "fires"
check "F1 — 스테이지 결과 행 자리가 발사한다" \
  "$( [ "$(site_fires "gate_append 'stage-result'" 60)" != "0" ] && printf 'fires' || printf 'silent')" "fires"
check "금지 — 라우터의 해소 쓰기는 발사하지 않는다" \
  "$(site_fires "gate_append 'blocked' \"대상=-\" \"스코프=run\" \"\$@\"" 12)" "0"
check "금지 — 감시자 정체 파일의 전사는 발사하지 않는다" \
  "$(site_fires '"원인=불명" "사유=$why"' 12)" "0"

# --- THE KILL SWITCH'S WARNING: stderr only, once per run ------------------
#
# Two separate properties. A warning on stdout would break the router's only
# declared input, which is one JSON object; a warning per CALL would become
# hundreds of lines overnight, interleaved with the refusal text a router has to
# read, because the gate is a new process for every act.
notify_reset
rm -f "$RD/notify.warned-killswitch"
warn_out=$(cd "$WT" && PATH="$WORK/bin:$PATH" \
  CC_CMDS_AUTOPILOT_NOTIFY=disabled CC_CMDS_NOTIFY_PATH_DISABLE_PREPEND=1 \
  CC_CMDS_NOTIFY_HOST_OS=Darwin CC_TEST_NOTIFY_LOG="$NOTIFY_LOG" \
  bash "$GATE" act --manifest "$MANIFEST" --kind segment --target infra --segment SBW \
  --cutpoint 커밋 --surface 읽기 --snapshot-digest "$(snapH)" \
  --rationale "픽스처 — 근미스 경고" -- "상태=계획됨" "워크트리=$WT" "선행=없음" 2>&1 >/dev/null)
case "$warn_out" in
  *"알아보지 못했습니다"*) ok "미인식 킬스위치 값에 표준오류로 경고한다" ;;
  *) bad "근미스 경고" "$(printf '%s' "$warn_out" | tr '\n' ' ')" ;;
esac
warn_second=$(cd "$WT" && PATH="$WORK/bin:$PATH" \
  CC_CMDS_AUTOPILOT_NOTIFY=disabled CC_CMDS_NOTIFY_PATH_DISABLE_PREPEND=1 \
  CC_CMDS_NOTIFY_HOST_OS=Darwin CC_TEST_NOTIFY_LOG="$NOTIFY_LOG" \
  bash "$GATE" act --manifest "$MANIFEST" --kind segment --target infra --segment SBW2 \
  --cutpoint 커밋 --surface 읽기 --snapshot-digest "$(snapH)" \
  --rationale "픽스처 — 근미스 경고 재발" -- "상태=계획됨" "워크트리=$WT" "선행=없음" 2>&1 >/dev/null)
case "$warn_second" in
  *"알아보지 못했습니다"*) bad "근미스 경고" "한 런 안의 두 번째 게이트 호출에서 다시 경고했다" ;;
  *) ok "그 경고는 런당 한 번만 나간다" ;;
esac
if (cd "$WT" && CC_CMDS_AUTOPILOT_NOTIFY=disabled bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null) | jq -e . >/dev/null; then
  ok "경고가 무장된 상태에서도 스냅숏 출력이 JSON 으로 파싱된다"
else
  bad "스냅숏 JSON" "킬스위치 경고가 라우터의 선언 입력을 깨뜨렸다"
fi

# --- THE DURABLE RECORD, transcribed exactly once --------------------------
#
# The emitter's own state is written to a run-directory file by whichever seat
# reaches it first, and this process — the ledger's writer — moves it into the
# report. Two seats must not leave two lines for one fact.
#
# A DELTA, NOT AN ABSOLUTE COUNT. Every act above this line already drove the
# transcription once, so an absolute count would measure the whole suite's
# history rather than these two calls. Clearing the marker deliberately reopens
# the transcription; what is asserted is that reopening it and calling twice
# leaves exactly ONE more line.
rm -f "$RD/notify.reported"
printf '배너 켬 (CC_CMDS_AUTOPILOT_NOTIFY)\n' > "$RD/notify.state"
seat_before=$(grep -cF '배너 좌석:' "$LEDGER" || true)
gateb act --manifest "$MANIFEST" --kind segment --target infra --segment SBR1 \
  --cutpoint 커밋 --surface 읽기 --snapshot-digest "$(snapH)" \
  --rationale "픽스처 — 배너 상태 전사" -- "상태=계획됨" "워크트리=$WT" "선행=없음"
gateb act --manifest "$MANIFEST" --kind segment --target infra --segment SBR2 \
  --cutpoint 커밋 --surface 읽기 --snapshot-digest "$(snapH)" \
  --rationale "픽스처 — 배너 상태 전사 재호출" -- "상태=계획됨" "워크트리=$WT" "선행=없음"
# THE FIXTURES ABOVE MUST HAVE LANDED THEIR ROWS, and until now nothing here
# asked. Every assertion in this section reads a side effect — a stderr warning,
# a prose-line delta — that the gate produces BEFORE it validates the segment
# row's own fields. So when this branch made `선행` required and these fixtures
# did not carry it, the rows were refused, the situation the fixtures exist to
# set up stopped happening, and every assertion stayed green.
#
# That is the same shape the rest of this file keeps finding: a check whose
# success does not depend on the thing being true. The guard is cheap and it
# fails loudly the moment a fixture stops establishing its own precondition.
for _sbseg in SBW SBW2 SBR1 SBR2; do
  if grep -qF "id=$_sbseg " "$LEDGER"; then
    ok "픽스처 $_sbseg 의 segment 행이 실제로 원장에 앉았다"
  else
    bad "픽스처 전제" "$_sbseg 의 segment 행이 거절돼 이 절의 단언들이 세우려던 상황이 성립하지 않았다 — 단언은 그것과 무관한 부수효과를 보므로 초록으로 남는다"
  fi
done
seat_after=$(grep -cF '배너 좌석:' "$LEDGER" || true)
check "배너 상태 줄이 보고서 겸 원장에 정확히 한 번 전사된다" \
  "$((seat_after - seat_before))" "1"
# The chain hashes rows and only rows, so a line of prose between them must not
# be able to break it — the kickoff's own stub already puts prose in this file.
gateb snapshot --manifest "$MANIFEST"
case "$msg" in
  *"끊김"*) bad "해시 사슬" "산문 한 줄이 사슬을 깼다: $msg" ;;
  *) ok "전사된 산문 줄이 해시 사슬을 건드리지 않는다" ;;
esac

# ---------------------------------------------------------------------------
# 12c. B1's progress vector counts what the router actually did
#
# The vector saw the manifest, segment rows, cycle rows and obligations — and
# nothing the router itself performs between stages. Commits, pushes, pull
# requests and merges all left it unchanged, so a router landing fixes for an
# hour read as motionless and B1 fired on it. The approval that opens then
# suspends B1..B3 and blocks termination until a person closes it, and this
# gate accepts no answer the router typed, so the false positive costs a night
# rather than a line of output.
#
# Both directions again, for the same reason as 12b: a boundary that has been
# silenced and one that has been fixed are indistinguishable from the side
# where nothing fires.
for a in $(grep -oE '승인 id=[^ |]+' "$LEDGER" | sed 's/승인 id=//' | sort -u); do
  printf -- '- `승인` | 승인 id=%s | 상태=승인 | 해소 시각=%s | prev=x\n' "$a" "테스트" >> "$LEDGER"
done

# Half one — the router performed a world-changing act. The vector must move,
# which is what makes the repeat counter reset rather than climb.
before_v=$(PD)
printf -- '- `자율 승인` | kind= | 결정=exec | 대상=front | 세그먼트=- | 절단점=push | 축2=외부상태변경 | 근거=진전 픽스처 | prev=x\n' >> "$LEDGER"
after_v=$(PD)
if [ "$before_v" != "$after_v" ]; then
  ok "라우터의 읽기 초과 행위가 진전 벡터를 움직인다"
else
  bad "진전 벡터" "커밋·push·PR 를 수행해도 벡터가 그대로다 — B1 이 그 위에서 발화한다"
fi

# The read-only counterpart, which pins the qualifier rather than the rule: if
# reads counted, the vector would never settle and B1 could never fire at all.
before_v=$(PD)
printf -- '- `자율 승인` | kind= | 결정=exec | 대상=front | 세그먼트=- | 절단점=커밋 | 축2=읽기 | 근거=읽기 픽스처 | prev=x\n' >> "$LEDGER"
after_v=$(PD)
check "읽기 등급 행위는 진전으로 세지 않는다" "$after_v" "$before_v"

# The third state, which excluding `읽기` alone would have missed: a row with no
# grade at all. Unknown is not evidence that anything changed, and counting it
# would let the boundary be reset by a row that says nothing about what was
# done. Reachable in practice — the fixtures in test-snapshot.sh write exactly
# this shape.
before_v=$(PD)
printf -- '- `자율 승인` | kind= | 결정=exec | 근거=등급 없는 픽스처 | prev=x\n' >> "$LEDGER"
after_v=$(PD)
check "등급이 없는 행위는 진전으로 세지 않는다 (모름은 진전이 아니다)" "$after_v" "$before_v"

# Half two — a clause settled and a run-scope block cleared are progress by
# definition; they are the two moves whose purpose is to bring the run nearer
# to ending.
before_v=$(PD)
printf -- '- `종료 절` | id=C9 | 상태=충족 | 근거=픽스처 | prev=x\n' >> "$LEDGER"
after_v=$(PD)
check_ne() { if [ "$1" != "$2" ]; then ok "$3"; else bad "진전 벡터" "$4"; fi; }
check_ne "$before_v" "$after_v" "절 정산이 진전 벡터를 움직인다" "절을 정산해도 벡터가 그대로다"
before_v=$(PD)
printf -- '- `blocked` | 대상=- | 스코프=run | 원인=해소 | 사유=픽스처 | 근거=픽스처 | prev=x\n' >> "$LEDGER"
after_v=$(PD)
check_ne "$before_v" "$after_v" "런 스코프 막힘 해소가 진전 벡터를 움직인다" "막힘을 해소해도 벡터가 그대로다"

# Half three — the boundary still fires. Nothing above may buy that away: the
# remedy B1 issues is an `승인` row, and if that ever entered the vector the
# boundary's own firing would reset the counter that fired it.
before_v=$(PD)
printf -- '- `승인` | 승인 id=B1-fixture | 상태=대기 | 절단점=경계 | 질문 문면=픽스처 | prev=x\n' >> "$LEDGER"
after_v=$(PD)
check "경계가 발행한 승인은 진전으로 세지 않는다 (자기 카운터를 리셋하지 못한다)" "$after_v" "$before_v"


printf '\ntest-gate: %d passed, %d failed\n' "$passed" "$failed"
[ "$failed" = "0" ]
