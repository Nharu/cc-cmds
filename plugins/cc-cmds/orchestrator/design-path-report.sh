#!/usr/bin/env bash
# 설계 경로 효용 표 — 무거운 단일 설계를 리드 혼자 쓰고 감사하는 경로(`solo-audit`)와 토론
# 팀이 쓰고 감사하는 경로(`discuss-audit`)를 감사가 낸 수로 나란히 놓는다.
#
# This is NOT a gate. Nothing here passes or fails; the output is the input to
# a human reading — 게이트·라우터·스테이지 어디에서도 부르지 않고, 사람이 필요할 때
# 부른다. 어떤 원장 디렉터리나 그 레포에도 쓰지 않는다.
#
# 입력: `--ledger-dir <dir>`. <dir> 은 `<레포>/docs/pipeline-run` 꼴의 원장 디렉터리이고,
# 읽는 것은 `collect-run-metrics.sh` 가 그 안에 쓴 요약 `metrics.json` 의 `design_paths`
# 하나다. 집계를 여기서 다시 하지 않는다 — 두 곳에서 세면 두 수가 갈라질 수 있다. 요약이
# 없거나 `design_paths` 가 없으면 그 사실을 한 줄로 내고 끝난다.
#
# 비교는 같은 감사 판끼리만 한다. 감사 판이 다르면 감사 지침이 달라 같은 문서에서도 다른 수가
# 나오므로, 판마다 표를 따로 낸다. 가장 최근의 판(키의 `last_run` 이 가장 큰 판)이 맨 앞이고
# 「(최근)」이 붙는다. 그 뒤 「다른 감사 판」 표제 아래, 경로마다 최근 판이 아닌 판 가운데
# 가장 최근 코호트 하나를 따로 보인다 — 최근 판에 아직 표본이 적은 경로를 읽는 사람이 옛 판의
# 수를 최근 판의 수로 읽지 않게 하려는 것이다. 표의 수는 최초 감사의 것이고, 재감사 수는 따로
# 한 칸에 둔다. 값이 없는 칸은 `-` 다.
#
# Usage:
#   design-path-report.sh --ledger-dir <dir>
#
# Exit codes:
#   0 — 출력함 (요약이 없어도 그 사실을 낸다)
#   2 — 인자 오류 (--ledger-dir 없음 · 모르는 인자)
#   3 — 원장 디렉터리 없음
#
# Compatibility: bash 3.2 (macOS) — no associative arrays, no mapfile. 수치 계산과
# 표 렌더링은 전부 jq 가 한다.

set -euo pipefail

dp_diag() { printf 'design-path-report: %s\n' "$1" >&2; }
dp_usage() { dp_diag "usage: design-path-report.sh --ledger-dir <dir>"; }

LEDGER_DIR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --ledger-dir) [ $# -ge 2 ] || { dp_usage; exit 2; }; LEDGER_DIR="$2"; shift 2 ;;
    *) dp_usage; exit 2 ;;
  esac
done
[ -n "$LEDGER_DIR" ] || { dp_usage; exit 2; }
[ -d "$LEDGER_DIR" ] || { dp_diag "원장 디렉터리가 없습니다: $LEDGER_DIR"; exit 3; }

SUMMARY="$LEDGER_DIR/metrics.json"
if [ ! -f "$SUMMARY" ] || ! jq -e 'type == "object" and has("design_paths")' "$SUMMARY" >/dev/null 2>&1; then
  printf '설계 경로 효용 — 요약에 design_paths 가 없습니다(collect-run-metrics.sh 가 아직 이 디렉터리를 모으지 않았습니다): %s\n' "$SUMMARY"
  exit 0
fi

jq -r '
  def cell: if . == null then "-" elif type == "number" then (. * 100 | round / 100 | tostring) else tostring end;
  def rate: if . == null then "-" else ((. * 100 | round | tostring) + "%") end;
  def head: "| 경로 | n | 고유 중앙값 | 미보강 중앙값 | 골격급 중앙값 | 합성 후보 중앙값 | 바이트 중앙값 | 고유/KB 중앙값 | 재수렴 비율 | 재감사 n | 재감사 고유 중앙값 |",
            "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |";
  def row: "| \(.path) | \(.n) | \(.unique.median | cell) | \(.unreinforced.median | cell) | \(.skeletal.median | cell) | \(.synth_candidates.median | cell) | \(.bytes.median | cell) | \(.unique_per_kb_median | cell) | \(.reconverge_rate | rate) | \(.reaudit.n) | \(.reaudit.unique.median | cell) |";
  [.design_paths | to_entries[] | .value] as $all
  | if ($all | length) == 0 then "설계 경로 효용 — 감사 공시 행이 있는 런이 없습니다"
    else
      ($all | max_by(.last_run) | .edition) as $latest
      | ($all | group_by(.edition) | sort_by([.[].last_run] | max) | reverse) as $eds
      | "# 설계 경로 효용 — 감사 판별",
        "",
        "같은 감사 판끼리만 비교합니다. 수는 최초 감사의 것이고, 재감사는 따로 셉니다.",
        ( $eds[]
          | . as $g
          | "",
            "## 감사 판 \($g[0].edition)\(if $g[0].edition == $latest then " (최근)" else "" end)",
            "",
            head,
            ($g | sort_by(.path)[] | row) ),
        "",
        "## 다른 감사 판",
        "",
        ( [$all[] | select(.edition != $latest)] as $others
          | if ($others | length) == 0 then "최근 판(\($latest)) 밖의 감사가 없습니다."
            else
              "경로마다 최근 판(\($latest))이 아닌 판 가운데 가장 최근 코호트입니다 — 최근 판의 수와 섞어 읽지 마세요.",
              "",
              "| 경로 | 감사 판 | n | 고유 중앙값 | 미보강 중앙값 | 골격급 중앙값 | 재수렴 비율 |",
              "| --- | --- | --- | --- | --- | --- | --- |",
              ( $others | group_by(.path)[] | max_by(.last_run)
                | "| \(.path) | \(.edition) | \(.n) | \(.unique.median | cell) | \(.unreinforced.median | cell) | \(.skeletal.median | cell) | \(.reconverge_rate | rate) |" )
            end )
    end' "$SUMMARY"
