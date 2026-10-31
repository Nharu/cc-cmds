#!/usr/bin/env bash
# 설계 경로 효용 표 — 감사 판마다 표 하나, 다른 판 코호트는 따로.
#
# 이 스위트가 있는 이유. 두 설계 경로의 효용은 같은 감사 판끼리만 비교할 수 있다. 판을 섞은
# 표는 오류 없이 그럴듯한 수를 내므로, 단언은 「어느 판의 표에 어느 행이 들었는가」와 「옛 판의
# 코호트가 최근 판의 표에 섞이지 않는가」를 본다. 입력은 수집기가 쓰는 요약의 `design_paths`
# 모양을 손으로 쓴 것이다 — 집계 자체는 test-collect-run-metrics.sh 가 잰다.
#
# Usage: bash scripts/test-design-path-report.sh

set -uo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
REPORT="$repo_root/plugins/cc-cmds/orchestrator/design-path-report.sh"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/cc-design-path-report-test.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

passed=0; failed=0
ok()    { passed=$((passed + 1)); printf 'PASS: %s\n' "$1"; }
bad()   { failed=$((failed + 1)); printf 'FAIL: %s — %s\n' "$1" "${2:-}" >&2; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got '$2', want '$3'"; fi; }

LD="$WORK/docs/pipeline-run"
mkdir -p "$LD"

OUT=""; rc=0
report() { OUT=$(bash "$REPORT" "$@" 2>"$WORK/err"); rc=$?; }
# 줄 수는 grep -c 로 센다 — 조기 종료하는 grep -q 는 왼쪽을 SIGPIPE 로 죽인다.
count() { printf '%s\n' "$OUT" | grep -cF -- "$1" || true; }
# section <표제> — 그 표제 줄부터 다음 `## ` 표제 앞까지.
section() { printf '%s\n' "$OUT" | awk -v h="$1" '$0 == h { on = 1; print; next } on && /^##? / { exit } on { print }'; }

# --- 0. 인자와 종료 코드 -------------------------------------------------------------
report
check "0: --ledger-dir 없이 부르면 exit 2 다" "$rc" "2"
report --ledger-dir "$WORK/없는곳"
check "0: 원장 디렉터리가 없으면 exit 3 다" "$rc" "3"
report --ledger-dir "$LD" --모름
check "0: 모르는 인자는 exit 2 다" "$rc" "2"

# --- 1. 요약이 없으면 그 사실을 한 줄로 낸다 ----------------------------------------------
report --ledger-dir "$LD"
check "1: 요약이 없어도 exit 0 이다" "$rc" "0"
check "1: 요약이 없다는 줄을 낸다" "$(count 'design_paths 가 없습니다')" "1"

# --- 2. 감사 판마다 표 하나, 다른 판 코호트는 따로 ----------------------------------------
side() {
  # side <path> <edition> <last_run> <n> <고유 중앙값> <재수렴 비율> <재감사 n> [운영 노출 중앙값] [경량 중앙값]
  # — 마지막 둘이 없으면 하류 부류 필드가 생기기 전의 요약이라 두 칸이 비어 있다.
  jq -cn --arg p "$1" --arg e "$2" --arg r "$3" --argjson n "$4" --argjson u "$5" --argjson rr "$6" --argjson rn "$7" \
    --argjson ops "${8:-null}" --argjson light "${9:-null}" '
    def d($m): {min: $m, median: $m, max: $m};
    {path: $p, edition: $e, last_run: $r, n: $n,
     unique: d($u), unreinforced: d(1), skeletal: d(0), synth_candidates: d(0), bytes: d(2048),
     cls_ops: d($ops), light: d($light),
     unique_per_kb_median: (if $u == null then null else $u / 2 end), reconverge_rate: $rr,
     reaudit: {n: $rn, unique: d(null), unreinforced: d(null), skeletal: d(null), synth_candidates: d(null),
               bytes: d(null), unique_per_kb_median: null}}'
}
jq -n --argjson a "$(side solo-audit eeee22222222 20261010-aaaaaaa1 3 4 0.3333 1 1 2)" \
      --argjson b "$(side discuss-audit eeee22222222 20261009-aaaaaaa2 2 6 0 0)" \
      --argjson c "$(side solo-audit eeee11111111 20260901-aaaaaaa3 5 9 1 0)" \
      --argjson d "$(side solo-audit eeee00000000 20260801-aaaaaaa4 1 null null 0)" \
  '{design_paths: {("solo-audit|eeee22222222"): $a, ("discuss-audit|eeee22222222"): $b,
                   ("solo-audit|eeee11111111"): $c, ("solo-audit|eeee00000000"): $d}}' > "$LD/metrics.json"
report --ledger-dir "$LD"
check "2: exit 0 이다" "$rc" "0"
check "2: 감사 판마다 표제 하나" "$(count '## 감사 판 ')" "3"
check "2: 가장 최근 판에 (최근) 이 붙는다" "$(count '## 감사 판 eeee22222222 (최근)')" "1"
check "2: 최근 판이 맨 앞 표다" "$(printf '%s\n' "$OUT" | grep -m1 '^## 감사 판 ')" "## 감사 판 eeee22222222 (최근)"
latest=$(section '## 감사 판 eeee22222222 (최근)')
check "2: 최근 판의 표에는 그 판의 두 경로가 든다" "$(printf '%s\n' "$latest" | grep -cE '^\| (solo|discuss)-audit \|' || true)" "2"
check "2: 최근 판의 표에 옛 판의 수가 섞이지 않는다" "$(printf '%s\n' "$latest" | grep -c '| solo-audit | 5 |' || true)" "0"
check "2: 재수렴 비율은 백분율이다" "$(printf '%s\n' "$latest" | grep -c '| 33% |' || true)" "1"
check "2: 첫 표 머리에 운영 노출 중앙값과 경량 중앙값이 합성 후보 중앙값 뒤에 있다" \
  "$(printf '%s\n' "$latest" | grep -c '| 합성 후보 중앙값 | 운영 노출 중앙값 | 경량 중앙값 | 바이트 중앙값 |' || true)" "1"
check "2: 운영 노출과 경량의 중앙값을 싣는다" "$(printf '%s\n' "$latest" | grep -c '^| solo-audit | 3 | 4 | 1 | 0 | 0 | 1 | 2 | 2048 |' || true)" "1"
check "2: 하류 부류 값이 없는 요약의 두 칸은 - 다" "$(printf '%s\n' "$latest" | grep -c '^| discuss-audit | 2 | 6 | 1 | 0 | 0 | - | - | 2048 |' || true)" "1"
others=$(section '## 다른 감사 판')
check "2: 다른 감사 판 표제가 따로 있다" "$(count '## 다른 감사 판')" "1"
check "2: 다른 판에서는 경로마다 가장 최근 코호트 하나다" "$(printf '%s\n' "$others" | grep -c '^| solo-audit |' || true)" "1"
check "2: 그 코호트는 최근 판 바로 앞 판이다" "$(printf '%s\n' "$others" | grep -c '| solo-audit | eeee11111111 | 5 |' || true)" "1"
check "2: 최근 판에만 있는 경로는 다른 판 표에 오르지 않는다" "$(printf '%s\n' "$others" | grep -c '^| discuss-audit |' || true)" "0"
old=$(section '## 감사 판 eeee00000000')
check "2: 값이 없는 칸은 - 다" "$(printf '%s\n' "$old" | grep -c '| solo-audit | 1 | - |' || true)" "1"

# --- 3. 감사가 하나도 없으면 그 사실을 낸다 -------------------------------------------------
printf '{"design_paths":{}}' > "$LD/metrics.json"
report --ledger-dir "$LD"
check "3: 빈 design_paths 도 exit 0 이다" "$rc" "0"
check "3: 감사 공시 행이 있는 런이 없다는 줄을 낸다" "$(count '감사 공시 행이 있는 런이 없습니다')" "1"

# --- 4. 쓰지 않는다 ---------------------------------------------------------------------
check "4: 원장 디렉터리에 새 파일을 쓰지 않는다" "$(find "$LD" -type f | wc -l | tr -d ' ')" "1"

# --- 5. 토론 패스와 판정 — 같은 판의 전후 행, 판이 갈린 행, 기준선 부족 ----------------------
# 판정 덩어리는 수집기의 `--verdict` 가 런별 기록에서 계산하므로, 입력은 기록 모양을 손으로
# 쓴 것이다. 계산 규칙은 test-collect-run-metrics.sh 가 잰다 — 여기서는 어느 판의 줄에 무엇이
# 나오는가를 본다.
rec() {
  # rec <run-id> <감사 판> <플러그인 버전> <고유> <R3 열림 true|false>
  mkdir -p "$LD/metrics"
  jq -n --arg r "$1" --arg e "$2" --arg v "$3" --argjson u "$4" --argjson o "$5" '
    {run_id: $r, stages: [], shifts: [],
     design: {path: "discuss-audit", audits: [{stage: "A1", attempt: 1, path: "discuss-audit", pass: "최초", edition: $e,
                                              plugin: ($v + "@abcdefabcdef"), unique: $u, bytes: 10000}],
              discussion: [{stage: "D1", attempt: 1, path: "discuss-audit", r3_open: $o,
                            reason: (if $o then "측정 지명" else "해당 없음" end)}]}}' > "$LD/metrics/$1.json"
}
for i in 1 2 3 4 5; do rec "20261003-aaaaaab$i" ffff11111111 2.99.0 10 false; done
for i in 1 2 3 4 5; do rec "20261003-aaaaaac$i" ffff11111111 2.104.1 12 false; done
rec 20261003-aaaaaad1 ffff22222222 2.104.1 30 true
jq -n '{design_paths: {}, discussion_passes: {"discuss-audit": {n: 11, r3_open: 1, reasons: {"측정 지명": 1, "해당 없음": 10},
        r3_minutes_median: null, fidelity_findings_median: 2, coherence_findings_median: 3}}}' > "$LD/metrics.json"
report --ledger-dir "$LD" --release-boundary 2.100.0
check "5: exit 0 이다" "$rc" "0"
check "5: 토론 패스 집계를 경로마다 한 줄 낸다" "$(count '| discuss-audit | 11 | 1 | 측정 지명 1, 해당 없음 10 | - | 2 | 3 |')" "1"
verdict=$(section '# 판정 — 감사 판별')
check "5: 경계 버전을 적는다" "$(printf '%s\n' "$verdict" | grep -c '^경계 버전 2.100.0 ' || true)" "1"
check "5: 같은 판의 전후 행이 한 줄에 놓이고 문턱 안이면 유지다" "$(printf '%s\n' "$verdict" | grep -c '^| ffff11111111 | 5 | 5 | 판정 | 유지 | 10 | 12 | 1 | 1.2 | 1.2 | 1.2 | 0% | 0% | 성립 |' || true)" "1"
check "5: 판이 갈린 행은 그 판의 줄에만 들고 기준선이 모자라면 기준선 부족이다" "$(printf '%s\n' "$verdict" | grep -c '^| ffff22222222 | 0 | 1 | 기준선 부족 | - |' || true)" "1"
report --ledger-dir "$LD"
check "5: 경계를 주지 않으면 기본값(빈 값)으로 모두 기준선이다" "$(count '| ffff11111111 | 10 | 0 | 판정 보류 | - |')" "1"
report --ledger-dir "$LD" --release-boundary v2
check "5: 숫자 버전이 아닌 경계는 exit 2 다" "$rc" "2"
check "5: 판정 덩어리를 계산해도 원장 디렉터리에 새 파일을 쓰지 않는다" "$(find "$LD" -type f | wc -l | tr -d ' ')" "12"

printf '\n통과 %s · 실패 %s\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
