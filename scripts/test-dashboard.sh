#!/usr/bin/env bash
# lint-bash-portability: self-skip
# The run dashboard: its read model over fixture runs, its HTTP contract, and
# its lifecycle commands.
#
# THIS SUITE DOES NOT RUN THE GATE, THE DRIVER OR THE WATCHER, and that is
# what keeps it outside the notifier leak predicate in
# `scripts/test-liveness-agreement.sh`. The lifecycle cases that must pass
# through the gate's run-open branch live in `scripts/test-gate.sh`.
#
# EVERY SERVER THIS SUITE STARTS IS STOPPED. The switch is turned back on only
# inside `dash`, with `CI` and the stage-seat markers removed and the state
# home pointed at this suite's scratch directory, and the exit trap stops every
# server any of those state homes recorded.
#
# Usage: bash scripts/test-dashboard.sh

set -uo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
ORCH="$repo_root/plugins/cc-cmds/orchestrator"
DASH="$ORCH/dashboard.py"
. "$repo_root/scripts/run-fixture.sh"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/cc-dashboard.XXXXXX")
XDG_STATE_HOME="$WORK/state"
export XDG_STATE_HOME
mkdir -p "$XDG_STATE_HOME"

passed=0; failed=0
ok()   { passed=$((passed + 1)); printf 'PASS: %s\n' "$1"; }
bad()  { failed=$((failed + 1)); printf 'FAIL: %s — %s\n' "$1" "${2:-}" >&2; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got '$2', want '$3'"; fi; }

if ! command -v python3 >/dev/null 2>&1; then
  bad "python3" "python3 를 찾지 못했다 — 이 스위트는 한 줄도 돌 수 없다"
  exit 1
fi
if ! command -v curl >/dev/null 2>&1; then
  bad "curl" "curl 을 찾지 못했다 — HTTP 계약을 잴 수 없다"
  exit 1
fi

pyq() { PYTHONDONTWRITEBYTECODE=1 python3 "$@"; }

dash() {
  # dash <state-home> <port> <verb> [args…] — the switch ON, for this call only.
  local xdg="$1" port="$2"; shift 2
  env -u CI -u CC_PIPELINE_SEGMENT -u CC_PIPELINE_STAGE_ID \
    XDG_STATE_HOME="$xdg" CC_CMDS_DASHBOARD=on CC_CMDS_DASHBOARD_PORT="$port" \
    CC_CMDS_DASHBOARD_IDLE="${DASH_IDLE:-600}" PYTHONDONTWRITEBYTECODE=1 \
    python3 "${DASH_PY:-$DASH}" "$@"
}

rec_file() { printf '%s/cc-cmds/dashboard/server' "$1"; }
rec_get() {
  pyq -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$(rec_file "$1")" "$2" 2>/dev/null
}
wait_gone() {
  local i=0
  while [ -n "${1:-}" ] && kill -0 "$1" 2>/dev/null && [ "$i" -lt 60 ]; do sleep 0.1; i=$((i + 1)); done
}
stop_in() {
  local pid
  pid=$(rec_get "$1" pid)
  [ -n "$pid" ] || return 0
  kill "$pid" 2>/dev/null
  wait_gone "$pid"
}
free_port() {
  pyq -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'
}
serve_count() {
  # serve_count <state-home> — servers recorded under that state home whose pid
  # is alive and still the process whose start fingerprint the record holds.
  #
  # NOT A HOST-WIDE `pgrep`. Every non-stage run open on this host starts a real
  # server that outlives the run, so a count of every `dashboard.py serve` on
  # the host fails these cases on a machine that uses the feature — on correct
  # code, every time. A replaced server is not in the record, so the case that
  # swaps one asserts separately that the old pid is gone.
  local f pid fp now n=0
  for f in $(find "$1" -path '*/cc-cmds/dashboard/server' 2>/dev/null); do
    pid=$(pyq -c 'import json,sys; print(json.load(open(sys.argv[1]))["pid"])' "$f" 2>/dev/null)
    fp=$(pyq -c 'import json,sys; print(json.load(open(sys.argv[1]))["fingerprint"])' "$f" 2>/dev/null)
    [ -n "$pid" ] && [ -n "$fp" ] || continue
    kill -0 "$pid" 2>/dev/null || continue
    now=$( { LC_ALL=C ps -o lstart= -p "$pid" 2>/dev/null || true; } | sed 's/[[:space:]]\{1,\}/ /g;s/^ //;s/ $//')
    if [ "$now" = "$fp" ]; then n=$((n + 1)); fi
  done
  printf '%s' "$n"
}
suite_serve_pids() {
  # Server processes started from this tree's dashboard.py, one pid per line,
  # sorted — the servers this suite and only this tree can have started.
  { pgrep -f "$DASH serve --fd" 2>/dev/null || true; } | sort
}
cleanup() {
  local f pid
  for f in $(find "$WORK" -path '*/cc-cmds/dashboard/server' 2>/dev/null); do
    pid=$(pyq -c 'import json,sys; print(json.load(open(sys.argv[1]))["pid"])' "$f" 2>/dev/null)
    [ -n "$pid" ] && kill "$pid" 2>/dev/null
  done
  [ -n "${HOLDER_PID:-}" ] && kill "$HOLDER_PID" 2>/dev/null
  # A `preview` server writes no record, so the loop above cannot find it; the
  # suite holds its pid itself.
  [ -n "${PREVIEW_PID:-}" ] && kill "$PREVIEW_PID" 2>/dev/null
  fx_reap
  rm -rf "$WORK"
}
trap cleanup EXIT

get() {
  # get <port> <path> [curl args…] — status code on stdout, body in $WORK/body.
  local port="$1" path="$2"; shift 2
  curl -s --path-as-is -o "$WORK/body" -D "$WORK/head" -w '%{http_code}' --max-time 10 \
    -H 'X-CC-Poll: 1' "$@" "http://127.0.0.1:$port$path"
}
etag_of() { sed -n 's/^[Ee][Tt][Aa][Gg]: *//p' "$WORK/head" | tr -d '\r'; }
jq_body() {
  pyq -c 'import json,sys
d=json.load(open(sys.argv[1]))
print(eval(sys.argv[2]))' "$WORK/body" "$1"
}

# ---------------------------------------------------------------------------
# Fixtures on the main root
# ---------------------------------------------------------------------------
fx_mkrun live-run; fx_ledger_path; fx_segment S1 실행중; fx_stage_live S1; fx_heartbeat 0 5
LIVE_DIR="$FX_RUN_DIR"
fx_mkrun done-run; fx_ledger_path; fx_segment S1 머지됨; fx_done
fx_mkrun dead-run; fx_ledger_path; fx_segment S1 실행중; fx_heartbeat 0 7200
mkdir -p "$XDG_STATE_HOME/cc-cmds/run/noledger"

# T3 — waiting on an approval, grown four days ago.
fx_mkrun old-pend; fx_ledger_path; fx_segment S1 실행중; fx_approval A1 대기; fx_heartbeat 0 345600

# T4 — no sup.log, a size-0 .err, one stage without its cost row.
fx_mkrun t4-run; fx_ledger_path
fx_row 'stage-result' '세그먼트=S1' '스테이지=S1' '종류=implement' '종료 코드=0' '실행 버전=1' '종단 부류=정상 완료'
fx_row 'cost' '누적 usd=1.5' '스테이지 수=1' "관측 시각=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
fx_row 'stage-result' '세그먼트=S2' '스테이지=S2' '종류=review' '종료 코드=1' '실행 버전=2' '종단 부류=외부 종료'
mkdir -p "$FX_RUN_DIR/log"
: > "$FX_RUN_DIR/log/S1#1.err"
fx_age_file "$FX_RUN_DIR/log/S1#1.err" 120

# T2 / T5 — a repository base with `.git`, a golden ledger with its run
# directory, and a reclaimed ledger without one.
BASE="$WORK/repo"
PR="$BASE/docs/pipeline-run"
mkdir -p "$BASE/.git" "$PR"
GOLD="$PR/golden-run.md"
{
  printf '# 파이프라인 런 보고서 — golden-run\n\n'
  printf '산문 줄 하나 — 행이 아니다.\n'
  printf -- '- `run` | 시작=2026-10-01T00:00:00Z | prev=x\n'
  printf -- '- `segment` | id=A1 | id=A1 | 상태=실행중 | 브랜치=`seg/a|1` | prev=x\n'
  printf -- '- `cycle` | 세그먼트=A1 | 사이클=1 | P0=1 | P1=2 | 모드=전체 | prev=x\n'
  printf '\n# 아침 보고서\n\n'
  printf -- '- `segment` | id=A1 | 상태=머지됨 | prev=x\n'
  printf -- '- `종료 절` | id=C1 | 상태=보류 | prev=x\n'
  printf -- '- `종료 절` | id=C1 | 상태=충족 | prev=x\n'
  printf -- '- `segment` | id=B1 | 상태=실행중 | prev=x'
} > "$GOLD"
{
  printf '# 매니페스트 — golden-run\n\n## 실행 계획\n\n```json\n'
  printf '{"steps":[{"id":"A","skill":"implement","summary":"s","depends_on":[]}]}\n'
  printf '```\n\n## 인가\n\n**종료 지점**: 모든 세그먼트 머지\n**비용 천장**: 50 USD\n'
  printf -- '- `종료 절` | id=C1 | 문면=모든 세그먼트가 머지된다 |\n'
  printf -- '- `종료 절` | id=C2 | 문면=리뷰 P0 가 0 이다 |\n'
} > "$PR/golden-run.plan.md"
mkdir -p "$XDG_STATE_HOME/cc-cmds/run/golden-run"
printf '%s\n' "$GOLD" > "$XDG_STATE_HOME/cc-cmds/run/golden-run/ledger-path"

{
  printf '# 파이프라인 런 보고서 — reclaimed-run\n\n'
  printf -- '- `segment` | id=R1 | 상태=머지됨 | prev=x\n'
  printf -- '- `cost` | 누적 usd=2.0 | 관측 시각=2026-09-20T00:00:00Z | prev=x\n'
} > "$PR/reclaimed-run.md"
# The side files carry the H1s they carry on this host. The interview record
# begins with the same three words as a ledger, so a prefix shorter than the
# ledger's own H1 would take it for one.
printf '# 매니페스트 — reclaimed-run\n' > "$PR/reclaimed-run.plan.md"
printf '# 파이프라인 런 인터뷰 기록 — reclaimed-run\n' > "$PR/reclaimed-run.interview.md"
printf '# 킥오프 — reclaimed-run\n' > "$PR/reclaimed-run.kickoff.md"
printf '# 인계 — 런 reclaimed-run 무효화 시점의 상태\n' > "$PR/HANDOFF-reclaimed-run.md"
printf '# 파이프라인 런 인터뷰 기록 — interview-only\n' > "$PR/interview-only.md"

# A base without `.git` — a leaked test repository. Its run is listed through
# its run directory; its orphan ledger is not reclaimed.
NOGIT="$WORK/nogit/docs/pipeline-run"
mkdir -p "$NOGIT"
printf '# 파이프라인 런 보고서 — nogit-run\n\n- `segment` | id=N1 | 상태=머지됨 | prev=x\n' > "$NOGIT/nogit-run.md"
printf '# 파이프라인 런 보고서 — nogit-orphan\n\n- `segment` | id=N2 | 상태=머지됨 | prev=x\n' > "$NOGIT/nogit-orphan.md"
mkdir -p "$XDG_STATE_HOME/cc-cmds/run/nogit-run"
printf '%s\n' "$NOGIT/nogit-run.md" > "$XDG_STATE_HOME/cc-cmds/run/nogit-run/ledger-path"

snapshot_tree() {
  pyq -c '
import hashlib, os, sys
h = hashlib.sha256()
for top in sys.argv[1:]:
    for d, dirs, files in os.walk(top):
        dirs.sort()
        for n in sorted(files) + sorted(dirs):
            p = os.path.join(d, n)
            st = os.lstat(p)
            h.update(("%s %d %d\n" % (p, st.st_size, st.st_mtime_ns)).encode())
print(h.hexdigest())' "$XDG_STATE_HOME/cc-cmds/run" "$BASE" "$WORK/nogit"
}

# ---------------------------------------------------------------------------
# T18 (no server) — the link names the port the next ensure would try.
# ---------------------------------------------------------------------------
P1=$(free_port)
check "T18 서버가 없으면 링크 뒤에 꺼져 있다는 안내가 붙는다" \
  "$(dash "$XDG_STATE_HOME" "$P1" url live-run)" \
  "http://127.0.0.1:$P1/run/live-run 서버가 꺼져 있습니다 — \`/cc-cmds:dashboard\`"

# ---------------------------------------------------------------------------
# One server over the main root
# ---------------------------------------------------------------------------
BEFORE=$(snapshot_tree)
dash "$XDG_STATE_HOME" "$P1" ensure; rc=$?
check "ensure 가 0 으로 끝난다" "$rc" "0"
check "서버가 덮어쓴 포트에 떴다" "$(rec_get "$XDG_STATE_HOME" port)" "$P1"
check "기록 파일의 모드가 600 이다" \
  "$(pyq -c 'import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777))' "$(rec_file "$XDG_STATE_HOME")")" "0o600"
check "T18 서버가 있으면 링크 한 줄이다" "$(dash "$XDG_STATE_HOME" "$P1" url live-run)" "http://127.0.0.1:$P1/run/live-run"

# T1
get "$P1" '/api/runs?days=3' >/dev/null
check "T1 살아 있는 런은 live 띠다" "$(jq_body '[r["band"] for r in d["runs"] if r["id"]=="live-run"]')" "['live']"
check "T1 살아 있는 런의 상태는 도는중이다" "$(jq_body '[r["state"] for r in d["runs"] if r["id"]=="live-run"]')" "['도는중']"
check "T1 종단 런은 recent 띠다" "$(jq_body '[r["band"] for r in d["runs"] if r["id"]=="done-run"]')" "['recent']"
check "T1 버려진 런은 기본 목록에 없다" "$(jq_body '[r["id"] for r in d["runs"] if r["id"] in ("dead-run","noledger")]')" "[]"
check "T1 숨긴 개수가 2 다" "$(jq_body 'd["hidden"]')" "2"
get "$P1" '/api/runs?days=3&dead=1' >/dev/null
check "T1 보이기로 두 껍데기가 나온다" \
  "$(jq_body 'sorted(r["id"] for r in d["runs"] if r.get("hidden"))')" "['dead-run', 'noledger']"

# T3
get "$P1" '/api/runs?days=all' >/dev/null
check "T3 오래된 승인대기는 older 띠다" "$(jq_body '[r["band"] for r in d["runs"] if r["id"]=="old-pend"]')" "['older']"
check "T3 토큰은 그대로 승인대기다" "$(jq_body '[r["state"] for r in d["runs"] if r["id"]=="old-pend"]')" "['승인대기']"
check "T3 승인대기(오래됨)으로 적힌다" "$(jq_body '[("승인대기(오래됨)" in r["notes"]) for r in d["runs"] if r["id"]=="old-pend"]')" "[True]"
live_api=$(jq_body 'len([r for r in d["runs"] if r["band"]=="live"])')
live_idle=$(cd "$ORCH" && pyq -c 'import dashboard_read as m; print(m.Model().live_count())')
check "T3 유휴 판정의 살아 있는 런 수가 위 띠의 수와 같다" "$live_idle" "$live_api"
OLDP_ROOT="$WORK/oldp/cc-cmds/run"
mkdir -p "$OLDP_ROOT"
cp -R "$XDG_STATE_HOME/cc-cmds/run/old-pend" "$OLDP_ROOT/"
printf '%s\n' "$OLDP_ROOT/old-pend/fixture-ledger.md" > "$OLDP_ROOT/old-pend/ledger-path"
cp -p "$XDG_STATE_HOME/cc-cmds/run/old-pend/watch.heartbeat" "$OLDP_ROOT/old-pend/watch.heartbeat"
check "T3 오래된 승인대기 하나뿐인 런 루트에서 유휴 판정의 살아 있는 런은 0 이다" \
  "$(cd "$ORCH" && pyq -c 'import dashboard_read as m,sys; print(m.Model(root=sys.argv[1]).live_count())' "$OLDP_ROOT")" "0"

# T4
get "$P1" '/api/runs/t4-run' >/dev/null
check "T4 sup.log 없이 크기 0 .err 의 시작 원천은 err 다" "$(jq_body 'd["timeline"][0]["start_src"]')" "err"
check "T4 cost 행이 있는 스테이지의 끝 원천은 cost 다" "$(jq_body 'd["timeline"][0]["end_src"]')" "cost"
check "T4 cost 행이 빠진 스테이지의 끝은 없음이다" "$(jq_body 'd["timeline"][1]["end_src"]')" "없음"
check "T4 그 스테이지의 비용은 0 이 아니라 불명이다" "$(jq_body 'd["timeline"][1]["usd"]')" "None"
check "T4 비용 불명 수가 1 이다" "$(jq_body 'd["cost"]["unknown"]')" "1"
check "T4 재부착 기록이 없는 런으로 표시된다" "$(jq_body 'd["has_sup"]')" "False"

# T5
get "$P1" '/api/runs?days=all' >/dev/null
check "T5 회수된 런이 이름 줄기를 런 id 로 목록에 있다" \
  "$(jq_body '[(r["band"], "런 디렉터리 회수됨" in r["notes"]) for r in d["runs"] if r["id"]=="reclaimed-run"]')" "[('older', True)]"
check "T5 부속 파일은 런으로 읽히지 않는다" \
  "$(jq_body 'sorted(r["id"] for r in d["runs"] if ("reclaimed-run" in r["id"] and r["id"]!="reclaimed-run") or r["id"]=="interview-only")')" "[]"
check "T5 .git 없는 바탕의 원장은 회수되지 않는다" \
  "$(jq_body '[r["id"] for r in d["runs"] if r["id"]=="nogit-orphan"]')" "[]"
check "T5 .git 없는 바탕의 런도 런 디렉터리로는 보인다" \
  "$(jq_body '[r["id"] for r in d["runs"] if r["id"]=="nogit-run"]')" "['nogit-run']"

# T2
get "$P1" '/api/runs/golden-run' >/dev/null
check "T2 세그먼트가 기대와 같다 (되풀이 키, 펜스 값, 두 H1, 반쪽 줄 제외)" \
  "$(jq_body '[(s["id"], s["state"], s["history"], s["branch"], s["cycles"]) for s in d["segments"]]')" \
  "[('A1', '머지됨', ['실행중', '머지됨'], 'seg/a|1', [{'cycle': '1', 'mode': '전체', 'p0': 1, 'p1': 2}])]"
check "T2 종료 절이 매니페스트 문면과 원장의 마지막 판정이다" \
  "$(jq_body '[(c["id"], c["text"], c["state"]) for c in d["clauses"]]')" \
  "[('C1', '모든 세그먼트가 머지된다', '충족'), ('C2', '리뷰 P0 가 0 이다', '미판정')]"
check "T2 단계 그래프가 매니페스트에서 온다" "$(jq_body '[s["id"] for s in d["manifest"]["steps"]]')" "['A']"
check "T2 런 시작은 run 행의 시작이다" "$(jq_body 'd["run_start"]')" "1790812800"
# The values below were taken from the read model before it numbered ledger
# lines and grew the new keys; only the five intended changes may move an
# existing key, and none of them reaches this run.
check "T2 골든 원장의 timeline 이 줄 번호를 더하기 전과 같다" "$(jq_body 'd["timeline"]')" "[]"
check "T2 골든 원장의 목록 키 값이 바뀌지 않는다" \
  "$(jq_body 'json.dumps({k: v for k, v in d["summary"].items() if k in ("band","cost_usd","goal","grade","hidden","id","live_stages","notes","seg","slug","state")}, ensure_ascii=False, sort_keys=True)')" \
  '{"band": "recent", "cost_usd": null, "goal": "모든 세그먼트 머지", "grade": 5, "hidden": false, "id": "golden-run", "live_stages": [], "notes": [], "seg": {"done": 0, "merged": 1, "open": 0, "park": 0, "total": 1}, "slug": null, "state": "종단"}'
check "T2 골든 원장의 상세 키 값이 바뀌지 않는다" \
  "$(jq_body 'json.dumps(dict({k: d[k] for k in ("clauses","derived","done_text","has_sup","manifest","run_start","segments","shifts")}, cost={k: d["cost"][k] for k in ("ceiling","external_end","ratio","unknown","usd")}), ensure_ascii=False, sort_keys=True)')" \
  '{"clauses": [{"id": "C1", "state": "충족", "text": "모든 세그먼트가 머지된다"}, {"id": "C2", "state": "미판정", "text": "리뷰 P0 가 0 이다"}], "cost": {"ceiling": 50.0, "external_end": 0, "ratio": null, "unknown": 0, "usd": null}, "derived": {"nonterminal_segments": [], "open_approvals": 0, "unresolved_blocks": 0}, "done_text": null, "has_sup": false, "manifest": {"ceiling": "50 USD", "deadline": null, "goal": "모든 세그먼트 머지", "steps": [{"depends_on": [], "id": "A", "skill": "implement"}]}, "run_start": 1790812800, "segments": [{"branch": "seg/a|1", "cycles": [{"cycle": "1", "mode": "전체", "p0": 1, "p1": 2}], "deps": [], "history": ["실행중", "머지됨"], "id": "A1", "state": "머지됨"}], "shifts": []}'
check "T2 골든 원장의 base 가 그대로다" "$(jq_body 'd["summary"]["base"]')" "$BASE"
printf '\n' >> "$GOLD"
# This suite just wrote the ledger; the no-write baseline restarts here.
BEFORE=$(snapshot_tree)
sleep 3.2
get "$P1" '/api/runs/golden-run' >/dev/null
check "T2 반쪽 줄은 다음 틱에 들어간다" "$(jq_body '[s["id"] for s in d["segments"]]')" "['A1', 'B1']"

# T6
check "T6 낯선 Host 는 403" "$(get "$P1" /api/runs -H "Host: evil.example:$P1")" "403"
check "T6 POST 는 405" "$(get "$P1" /api/runs -X POST)" "405"
check "T6 ../ 가 든 런 id 는 404" "$(get "$P1" '/api/runs/..%2F..%2Fetc')" "404"
check "T6 localhost 와 포트는 받는다" "$(get "$P1" /healthz -H "Host: localhost:$P1")" "200"
check "T6 CSP 가 붙는다" "$(grep -ci "^content-security-policy: default-src 'self'" "$WORK/head")" "1"
check "T6 CORS 머리가 없다" "$(grep -ci '^access-control-' "$WORK/head")" "0"

# T7
get "$P1" '/api/runs/live-run' >/dev/null
E1=$(etag_of)
check "T7 같은 틱의 둘째 요청은 304" "$(get "$P1" '/api/runs/live-run' -H "If-None-Match: $E1")" "304"
kill "$(cat "$LIVE_DIR/S1.pid")" 2>/dev/null
wait_gone "$(cat "$LIVE_DIR/S1.pid")"
sleep 3.2
check "T7 파일이 그대로여도 스테이지가 죽으면 앞 ETag 에 200" "$(get "$P1" '/api/runs/live-run' -H "If-None-Match: $E1")" "200"
check "T7 그 런의 상태가 바뀌어 있다" "$(jq_body 'd["summary"]["state"]')" "진행중"

# T13
get "$P1" '/' >/dev/null; get "$P1" '/run/golden-run' >/dev/null; get "$P1" '/app.js' >/dev/null
get "$P1" '/app.css' >/dev/null; get "$P1" '/api/runs?days=7&dead=1' >/dev/null
get "$P1" "/api/runs?days=30&base=$BASE" >/dev/null; get "$P1" /healthz >/dev/null
check "T13 API 를 모두 부른 뒤 런 루트와 원장 트리가 그대로다" "$(snapshot_tree)" "$BEFORE"
check "T13 레포에 __pycache__ 가 생기지 않는다" \
  "$(find "$repo_root/plugins" -name __pycache__ 2>/dev/null | grep -c . || true)" "0"

stop_in "$XDG_STATE_HOME"

# ---------------------------------------------------------------------------
# T8 — two ensures at once leave one server and one record.
# ---------------------------------------------------------------------------
S8="$WORK/s8"; mkdir -p "$S8"; P8=$(free_port)
B8=$(suite_serve_pids)
t0=$(pyq -c 'import time; print(time.time())')
dash "$S8" "$P8" ensure & e1=$!
dash "$S8" "$P8" ensure & e2=$!
wait "$e1"; r1=$?
wait "$e2"; r2=$?
t1=$(pyq -c 'import time; print(time.time())')
check "T8 두 ensure 가 모두 0 으로 끝난다" "$r1:$r2" "0:0"
check "T8 둘 다 3초 안에 끝난다" "$(pyq -c 'import sys; print(float(sys.argv[2])-float(sys.argv[1]) < 3.0)' "$t0" "$t1")" "True"
check "T8 서버가 하나다" "$(serve_count "$S8")" "1"
# A losing ensure that spawned anyway would leave a server the record does not
# name, which the count above cannot see; the processes this tree started
# during the race are read instead, less the recorded one.
check "T8 기록 밖에 남은 서버가 없다" \
  "$(comm -13 <(printf '%s\n' "$B8") <(suite_serve_pids) | grep -vx "$(rec_get "$S8" pid)" | grep -c . || true)" "0"
check "T8 기록 파일이 하나다" "$(find "$S8/cc-cmds/dashboard" -maxdepth 1 -type f \( -name server -o -name '.server.tmp*' \) | grep -c .)" "1"
check "T8 잠금이 남지 않는다" "$( [ -d "$S8/cc-cmds/dashboard/spawn.lock.d" ] && printf held || printf free )" "free"
stop_in "$S8"

# ---------------------------------------------------------------------------
# T9 — another listener holds the port.
# ---------------------------------------------------------------------------
S9="$WORK/s9"; mkdir -p "$S9"; P9=$(free_port)
pyq -c 'import socket,sys,time
s=socket.socket(); s.bind(("127.0.0.1",int(sys.argv[1]))); s.listen(8); time.sleep(60)' "$P9" &
HOLDER_PID=$!
sleep 0.5
dash "$S9" "$P9" ensure
p9=$(rec_get "$S9" port)
if [ -n "$p9" ] && [ "$p9" != "$P9" ]; then ok "T9 서버가 다른 포트로 떴다"; else bad "T9 포트" "기록의 포트가 '$p9' 다"; fi
check "T9 url 이 기록의 포트를 쓴다" "$(dash "$S9" "$P9" url r)" "http://127.0.0.1:$p9/run/r"
stop_in "$S9"
kill "$HOLDER_PID" 2>/dev/null; HOLDER_PID=""

# ---------------------------------------------------------------------------
# T10 — the newer version wins, and only the newer.
# ---------------------------------------------------------------------------
copy_plugin() {
  # copy_plugin <dir> <version> — a plugin tree carrying only the dashboard.
  mkdir -p "$1/.claude-plugin" "$1/orchestrator"
  printf '{"name":"cc-cmds","version":"%s"}\n' "$2" > "$1/.claude-plugin/plugin.json"
  cp "$ORCH/dashboard.py" "$ORCH/dashboard_read.py" "$1/orchestrator/"
  cp -R "$ORCH/dashboard" "$1/orchestrator/"
}
S10="$WORK/s10"; mkdir -p "$S10"; P10=$(free_port)
copy_plugin "$WORK/old" 0.0.1
copy_plugin "$WORK/high" 999.0.0
REAL_V=$(pyq -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$repo_root/plugins/cc-cmds/.claude-plugin/plugin.json")
DASH_PY="$WORK/old/orchestrator/dashboard.py" dash "$S10" "$P10" ensure
old_pid=$(rec_get "$S10" pid)
get "$(rec_get "$S10" port)" /healthz >/dev/null
check "T10 낮은 버전 서버가 떴다" "$(jq_body 'd["version"]')" "0.0.1"
dash "$S10" "$P10" ensure
wait_gone "$old_pid"
check "T10 낮으면 갈아 끼운 뒤 서버가 하나다" "$(serve_count "$S10")" "1"
get "$(rec_get "$S10" port)" /healthz >/dev/null
check "T10 /healthz 가 새 버전으로 답한다" "$(jq_body 'd["version"]')" "$REAL_V"
check "T10 옛 pid 는 끝나 있다" "$(kill -0 "$old_pid" 2>/dev/null && printf alive || printf gone)" "gone"
DASH_PY="$WORK/high/orchestrator/dashboard.py" dash "$S10" "$P10" ensure
high_pid=$(rec_get "$S10" pid)
dash "$S10" "$P10" ensure
check "T10 높게 답하는 서버는 둔다" "$(rec_get "$S10" pid)" "$high_pid"
get "$(rec_get "$S10" port)" /healthz >/dev/null
check "T10 그 서버가 높은 버전으로 계속 답한다" "$(jq_body 'd["version"]')" "999.0.0"
stop_in "$S10"

# ---------------------------------------------------------------------------
# T11 — idle exit; poll requests do not hold the server.
# ---------------------------------------------------------------------------
S11="$WORK/s11"; mkdir -p "$S11"; P11=$(free_port)
DASH_IDLE=2 dash "$S11" "$P11" ensure
pid11=$(rec_get "$S11" pid)
i=0
while [ "$i" -lt 12 ] && kill -0 "$pid11" 2>/dev/null; do
  get "$P11" '/api/runs' >/dev/null
  sleep 0.5; i=$((i + 1))
done
wait_gone "$pid11"
check "T11 폴링만 받는 서버가 유휴로 끝난다" "$(kill -0 "$pid11" 2>/dev/null && printf alive || printf gone)" "gone"
check "T11 기록 파일은 그대로다" "$( [ -f "$(rec_file "$S11")" ] && printf kept || printf gone )" "kept"

# ---------------------------------------------------------------------------
# T12 — the off switch and CI.
# ---------------------------------------------------------------------------
S12="$WORK/s12"; mkdir -p "$S12"; P12=$(free_port)
env -u CC_PIPELINE_SEGMENT -u CC_PIPELINE_STAGE_ID XDG_STATE_HOME="$S12" CC_CMDS_DASHBOARD=off \
  CC_CMDS_DASHBOARD_PORT="$P12" PYTHONDONTWRITEBYTECODE=1 python3 "$DASH" ensure; rc=$?
check "T12 끄개면 ensure 가 0 이다" "$rc" "0"
check "T12 끄개면 기록이 없다" "$( [ -e "$(rec_file "$S12")" ] && printf yes || printf no )" "no"
env -u CC_PIPELINE_SEGMENT -u CC_PIPELINE_STAGE_ID XDG_STATE_HOME="$S12" CC_CMDS_DASHBOARD=on CI=1 \
  CC_CMDS_DASHBOARD_PORT="$P12" PYTHONDONTWRITEBYTECODE=1 python3 "$DASH" ensure; rc=$?
check "T12 CI 면 ensure 가 0 이다" "$rc" "0"
check "T12 CI 면 기록이 없다" "$( [ -e "$(rec_file "$S12")" ] && printf yes || printf no )" "no"
check "T12 어느 쪽도 서버를 남기지 않는다" "$(serve_count "$S12")" "0"

# ---------------------------------------------------------------------------
# T15–T29 — what a person owes a run, the hiding and the period, results,
# steps, judgments, costs, the display zone and the preview entry. Their
# fixtures sit in a state home of their own, so the counts the cases above
# assert on the main root do not move.
# ---------------------------------------------------------------------------
NX="$WORK/nx"
MAIN_XDG="$XDG_STATE_HOME"
XDG_STATE_HOME="$NX"
mkdir -p "$NX/cc-cmds/run"
LIVENESS="$ORCH/liveness.sh"

nq() {
  # nq <expression> [<CC_CMDS_AUTOPILOT_TZ> [<now, ISO>]] — the expression's
  # value over this state home, `M` a fresh model, `m` the module and `now` the
  # request time. With no second argument the zone variable is unset.
  (cd "$ORCH" && env -u CC_CMDS_AUTOPILOT_TZ XDG_STATE_HOME="$NX" PYTHONDONTWRITEBYTECODE=1 python3 -c '
import json, os, sys, time
if len(sys.argv) > 2:
    os.environ["CC_CMDS_AUTOPILOT_TZ"] = sys.argv[2]
import dashboard_read as m
M = m.Model()
now = m.iso_epoch(sys.argv[3]) if len(sys.argv) > 3 else int(time.time())
print(eval(sys.argv[1]))' "$@")
}
row_of() {
  # row_of <run-id> <expression over r> [days] — one list row's value.
  nq "[($2) for r in M.runs(days='${3:-3}', dead=True, exp=True, now=now)['runs'] if r['id'] == '$1']"
}
halt_rec() {
  # halt_rec <path> <question line> <second line> — a halt record in the
  # gate's field shape, its question over two lines.
  mkdir -p "$(dirname "$1")"
  printf '<!-- cc-pipeline-halt -->\n**스킬**: implement-unattended\n**스텝**: Step 3 — 픽스처\n**분류**: gate-unanswerable\n**질문 문면**: %s\n%s\n**선택지**:\n- `재시도` — 다시 돈다\n**추천**: `재시도`\n<!-- /cc-pipeline-halt -->\n' \
    "$2" "$3" > "$1"
}
ids_in() {
  # ids_in <query> — sorted run ids of one list request.
  nq "sorted(r['id'] for r in M.runs($1, now=now)['runs'])"
}

fx_mkrun need-dead; fx_ledger_path; fx_segment S1 실행중; fx_heartbeat 0 7200
halt_rec "$FX_RUN_DIR/halt/S1#1.md" "어느 쪽으로   갈까요" "  둘째 줄입니다"
fx_mkrun need-old; fx_ledger_path; fx_segment S1 실행중; fx_heartbeat 0 432000
halt_rec "$FX_RUN_DIR/halt/shift/S1#1.md" "오래된 질문" ""
fx_age_file "$FX_LEDGER" 432000

fx_mkrun pend-run; fx_ledger_path; fx_segment S1 실행중; fx_heartbeat 0 5
for a in "P1|-" "P2|A"; do
  fx_row '승인' "승인 id=${a%%|*}" '상태=대기' '대상=cc-cmds' '절단점=머지' '유도 절단점=머지' \
    '행위 다이제스트=d1' "막는 세그먼트=${a#*|}" '질문 문면=사전 인가 밖 행위를 수행할까요' '답변 문면=-' \
    '발행 시각=2026-10-01T00:00:00Z' '해소 시각=-'
done
fx_row '승인' '승인 id=P3' '상태=대기' '대상=-' '절단점=판단' '질문 문면=어느 안을 고를까요' '답변 문면=-' \
  '발행 시각=2026-10-01T01:00:00Z' '해소 시각=-'
fx_approval B1 대기

for id in ended-left ended-old; do
  fx_mkrun "$id"; fx_ledger_path; fx_segment S1 머지됨; fx_approval Z1 대기; fx_done
  halt_rec "$FX_RUN_DIR/halt/S1#1.md" "끝난 뒤 남은 질문" ""
done
fx_age_file "$FX_RUN_DIR/done" 432000
fx_age_file "$FX_LEDGER" 432000

# A base with `.git`: two reclaimed ledgers, and the run directories whose
# ledgers live in it — the step, judgment and link fixture among them.
NB="$WORK/nbase"; NBP="$NB/docs/pipeline-run"
mkdir -p "$NB/.git" "$NBP"
{
  printf -- '# 파이프라인 런 보고서 — rec-pend\n\n- `segment` | id=S1 | 상태=실행중 | prev=x\n'
  printf -- '- `승인` | 승인 id=Q1 | 상태=대기 | 대상=- | 절단점=경계 | 질문 문면=회수 런의 질문 | 답변 문면=- | 발행 시각=2026-10-01T00:00:00Z | 해소 시각=- | prev=x\n'
} > "$NBP/rec-pend.md"
fx_age_file "$NBP/rec-pend.md" 432000
printf -- '# 파이프라인 런 보고서 — rec-done\n\n- `segment` | id=R1 | 상태=머지됨 | prev=x\n' > "$NBP/rec-done.md"

sr()  { fx_row 'stage-result' "$@" '종료 코드=0'; }
cst() { fx_row 'cost' "누적 usd=$1" "스테이지 수=1" "관측 시각=$2"; }

fx_mkrun nb-anchor; FX_LEDGER="$NBP/nb-anchor.md"; : > "$FX_LEDGER"; fx_ledger_path
{
  printf '# 파이프라인 런 매니페스트 — nb-anchor\n\n## 대상\n'
  printf -- '- `target` | 별칭=cc-cmds | 원격 슬러그=Nharu/cc-cmds | 절단점=머지\n\n## 실행 계획\n\n```json\n'
  printf '{"steps":[{"id":"D1","skill":"design"},{"id":"AU","skill":"design-audit"},{"id":"SP","skill":"split"},'
  printf '{"id":"V1","skill":"visual"},{"id":"I1","skill":"implement"},{"id":"R1","skill":"review"}]}\n```\n\n'
  printf '## 인가\n\n**벽시계 마감**: 2099-01-01T00:00:00Z\n'
} > "$NBP/nb-anchor.plan.md"
fx_row 'run' '시작=2026-10-01T00:00:00Z' '설계 문서=/d/doc.md' '보고서=/d/report.md'
fx_row 'segment' 'id=A' '상태=실행중' '브랜치=seg/a' 'PR=11' '레포=Other/repo'
fx_row 'segment' 'id=B' '상태=머지됨' '브랜치=seg/b' 'PR=12'
sr '세그먼트=-' '스테이지=D1' '종류=design' '실행 버전=1' '종단 부류=의도된 park'; cst 1.0 2026-10-01T01:00:00Z
sr '세그먼트=-' '스테이지=D1' '종류=design' '실행 버전=2' '종단 부류=정상 완료'; cst 2.0 2026-10-01T02:00:00Z
sr '세그먼트=-' '스테이지=S2' '실행 버전=1' '종단 부류=정상 완료'; cst 2.5 2026-10-01T03:00:00Z
sr '세그먼트=-' '스테이지=AU' '종류=reconverge' '실행 버전=1' '종단 부류=외부 종료'; cst 3.0 2026-10-01T04:00:00Z
sr '세그먼트=-' '스테이지=S2split' '종류=split' '실행 버전=1' '종단 부류=정상 완료'; cst 3.5 2026-10-01T05:00:00Z
sr '세그먼트=A' '스테이지=A' '종류=implement' '실행 버전=1' '종단 부류=정상 완료'; cst 4.5 2026-10-01T06:00:00Z
sr '세그먼트=A' '스테이지=S5' '실행 버전=1' '종단 부류=정상 완료'; cst 5.0 2026-10-01T07:00:00Z
sr '세그먼트=A' '스테이지=A' '종류=lead-fix' '실행 버전=2' '종단 부류=크래시 rc=1'; cst 5.25 2026-10-01T08:00:00Z
sr '세그먼트=A' '스테이지=S4' '실행 버전=2' '종단 부류=정상 완료'; cst 6.0 2026-10-01T09:00:00Z
sr '세그먼트=A' '스테이지=A' '종류=review' '실행 버전=3' '종단 부류=정상 완료'; cst 6.5 2026-10-01T10:00:00Z
sr '세그먼트=A' '스테이지=A' '종류=reconverge' '실행 버전=4' '종단 부류=정상 완료'; cst 7.0 2026-10-01T11:00:00Z
sr '세그먼트=B' '스테이지=B' '종류=implement' '실행 버전=1' '종단 부류=정상 완료'
fx_row '자율 승인' 'kind=exec' 'argv=x| kind=judgment |y' '계보=B:A#1'
fx_row '자율 승인' 'kind=judgment' '결정=채택' '세그먼트=A' '판단 부류=감사-발견' '등급=1' '기준=c1' '되돌리는 법=r1' \
  '근거=g1' '출처=implement' '해소 승인=-'
fx_row '자율 승인' 'kind=judgment' '결정=채택' '세그먼트=B' '판단 부류=잔여-항목' '등급=1' '기준=c2' '되돌리는 법=r2' \
  '근거=g2' '출처=review' '해소 승인=J1'
fx_row '승인' '승인 id=J1' '상태=대기' '대상=-' '절단점=판단' '질문 문면=q' '답변 문면=-' \
  '발행 시각=2026-10-01T04:30:00Z' '해소 시각=-'
fx_row '승인' '승인 id=J1' '상태=승인' '대상=-' '절단점=판단' '질문 문면=q' '답변 문면=채택' '처분 사유=자동 해소' \
  '발행 시각=2026-10-01T04:30:00Z' '해소 시각=2026-10-01T05:00:00Z'
for a in "좌석 실행|답한 주체=좌석|g3|06" "재시도|답한 주체=교대|g4|07" "보류|답한 주체=사람|g5|08" \
         "재수렴|-|자동 채택(구속-이탈) — 구속 티어|09"; do
  IFS='|' read -r pick by why hh <<EOF
$a
EOF
  if [ "$by" = "-" ]; then
    fx_row '중단 답' '세그먼트=A' '중단 기록=/x/nb-anchor/halt/A#1.md' "선택지=$pick" "근거=$why" \
      "기록 시각=2026-10-01T$hh:00:00Z"
  else
    fx_row '중단 답' '세그먼트=A' '중단 기록=/x/nb-anchor/halt/A#1.md' "선택지=$pick" "$by" "근거=$why" \
      "기록 시각=2026-10-01T$hh:00:00Z"
  fi
done
fx_row '승인' '승인 id=K1' '상태=대기' '대상=-' '절단점=경계' '질문 문면=k' '답변 문면=-' \
  '발행 시각=2026-10-01T09:30:00Z' '해소 시각=-'
fx_row '승인' '승인 id=K1' '상태=승인' '대상=-' '절단점=경계' '질문 문면=k' '답변 문면=보류' '처분 사유=자동 해소' \
  '발행 시각=2026-10-01T09:30:00Z' '해소 시각=2026-10-01T10:00:00Z'
fx_row 'cycle' '세그먼트=A' '사이클=1' 'P0=1' 'P1=2' '모드=전체' '리뷰 종결=수정' '리포트 경로=/r/a1.md'
fx_row 'cycle' '세그먼트=A' '사이클=2' 'P0=0' 'P1=0' '모드=확인'
fx_stage_live A; fx_stage_meta A review 4

fx_mkrun nb-two; FX_LEDGER="$NBP/nb-two.md"; : > "$FX_LEDGER"; fx_ledger_path; fx_heartbeat 0 5
{
  printf '# 파이프라인 런 매니페스트 — nb-two\n\n## 대상\n'
  printf -- '- `target` | 별칭=cc-cmds | 원격 슬러그=Nharu/cc-cmds | 절단점=머지\n'
  printf -- '- `target` | 별칭=other | 원격 슬러그=Nharu/other | 절단점=머지\n\n## 실행 계획\n\n```json\n'
  printf '{"steps":[{"id":"I1","skill":"implement"},{"id":"I2","skill":"implement"},{"id":"R1","skill":"review"}]}\n'
  printf '```\n\n## 인가\n\n**벽시계 마감**: 없음\n'
} > "$NBP/nb-two.plan.md"
fx_row 'segment' 'id=A' '상태=실행중' 'PR=21'
fx_row 'segment' 'id=B' '상태=실행중' 'PR=22' '레포=not a slug'
sr '세그먼트=A' '스테이지=A' '종류=implement' '실행 버전=1' '종단 부류=정상 완료'
sr '세그먼트=A' '스테이지=A' '종류=review' '실행 버전=1' '종단 부류=정상 완료'

# An experiment base: under `<state home>/cc-cmds/`, as a suite's scratch tree is.
EBP="$NX/cc-cmds/exp/repo/docs/pipeline-run"
mkdir -p "$EBP"
fx_mkrun exp-run; FX_LEDGER="$EBP/exp-run.md"; : > "$FX_LEDGER"; fx_ledger_path; fx_segment S1 머지됨
cst 7.0 "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
fx_mkrun exp-dead; FX_LEDGER="$EBP/exp-dead.md"; : > "$FX_LEDGER"; fx_ledger_path
fx_segment S1 실행중; fx_heartbeat 0 7200

fx_mkrun cache-end; fx_ledger_path; fx_segment S1 머지됨; fx_done
fx_mkrun cache-dead; fx_ledger_path; fx_segment S1 실행중; fx_heartbeat 0 7200
mkdir -p "$NX/cc-cmds/run/nx-shell"

for a in "res-ok|종료 조건 성립 · 근거 g" "res-bd|경계 마감 · 근거 g" "res-void|무효화 · 근거 g" \
         "res-q|질의 잔여 2건 · 승인 A · 근거 g" \
         "res-p0|P0 잔존 — 확인 리뷰 상한에서 P0 가 남은 세그먼트: A · 무효화 x · 근거 종료 조건 성립" \
         "res-unk|픽스처"; do
  fx_mkrun "${a%%|*}"; fx_ledger_path; fx_segment S1 머지됨
  printf '2026-10-02T00:00:00Z 종단 — %s\n' "${a#*|}" > "$FX_RUN_DIR/done"
done
fx_mkrun res-derived; fx_ledger_path; fx_segment S1 머지됨

TB="$WORK/tzbase"; mkdir -p "$TB/docs/pipeline-run"
fx_mkrun tz-run; FX_LEDGER="$TB/docs/pipeline-run/tz-run.md"; : > "$FX_LEDGER"; fx_ledger_path
fx_segment S1 머지됨
cst 1.0 2026-10-09T14:00:00Z; cst 3.0 2026-10-09T16:00:00Z; cst 6.0 2026-10-10T02:00:00Z; cst 10.0 2026-10-10T18:00:00Z
fx_done
pyq -c 'import calendar,os,sys,time
t = calendar.timegm(time.strptime(sys.argv[2], "%Y-%m-%dT%H:%M:%SZ")); os.utime(sys.argv[1], (t, t))' \
  "$FX_RUN_DIR/done" 2026-10-09T16:30:00Z

for id in lin-with lin-without; do fx_mkrun "$id"; fx_ledger_path; fx_segment S1 실행중; fx_heartbeat 0 5; done
fx_row '자율 승인' 'kind=exec' 'argv=x| kind=judgment |y' '계보=B:S1#1'

fx_mkrun tl-run; fx_ledger_path
{
  printf '# 파이프라인 런 보고서 — tl-run\n\n'
  printf -- '- `run` | 시작=2026-10-01T00:00:00Z | prev=x\n'
  printf -- '- `segment` | id=A | 상태=실행중 | prev=x\n'
  printf -- '- `stage-result` | 세그먼트=- | 스테이지=D1 | 종류=design | 종료 코드=0 | 실행 버전=1 | 종단 부류=정상 완료\n'
  printf -- '- `cost` | 누적 usd=1.0 | 관측 시각=2026-10-01T01:00:00Z | prev=x\n'
  printf -- '- `자율 승인` | kind=exec | 계보=B:A#1 | prev=x\n'
  printf -- '- `stage-result` | 세그먼트=A | 스테이지=S4 | 종료 코드=0 | 실행 버전=1 | 종단 부류=정상 완료\n'
  printf -- '- `cost` | 누적 usd=3.5 | 관측 시각=2026-10-01T02:00:00Z | prev=x\n'
  printf -- '- `stage-result` | 세그먼트=A | 스테이지=A | 종류=review | 종료 코드=1 | 실행 버전=2 | 종단 부류=외부 종료\n'
} > "$FX_LEDGER"

NEW_KEYS="['attention', 'deadline', 'deadline_left_s', 'elapsed_s', 'ended_day', 'experiment', 'now', 'prs', 'result', 'started_at', 'waiting']"

# T15 — a halt record makes an abandoned run need a person.
check "T15 답 없는 기록이 있는 두 시간 무성장 런은 버려짐·need 다" \
  "$(row_of need-dead '(r["state"], r["attention"], r["hidden"])' 3)" "[('버려짐', 'need', False)]"
check "T15 그 런이 기본 목록에 보인다" "$(nq "'need-dead' in [r['id'] for r in M.runs(now=now)['runs']]")" "True"
check "T15 waiting 에 기록의 질문 문면이 공백을 접어 담긴다" \
  "$(row_of need-dead '[(w["kind"], w["text"], w["returned"], w["recommend"]) for w in r["waiting"]]' 3)" \
  "[[('중단 기록', '어느 쪽으로 갈까요 둘째 줄입니다', False, '\`재시도\`')]]"
check "T15 기간 밖 need 런이 기본 목록에 보이고 band 는 그대로다" \
  "$(nq "[(r['attention'], r['band']) for r in M.runs(now=now)['runs'] if r['id'] == 'need-old']")" \
  "[('need', 'older')]"
check "T15 halt/shift/ 의 기록도 기다리는 것이다" \
  "$(row_of need-old '[w["ref"].endswith("/halt/shift/S1#1.md") for w in r["waiting"]]' all)" "[[True]]"

# T16 — open approvals: an action approval carries its target, cut point and
# blocked segment; judgment and boundary approvals carry their question as is.
check "T16 열린 승인 런은 승인대기·need 다" "$(row_of pend-run '(r["state"], r["attention"])' 3)" "[('승인대기', 'need')]"
check "T16 승인 문면 (행위 승인 덧붙임, 막는 세그먼트=- 생략, 판단·경계 그대로)" \
  "$(row_of pend-run '[(w["ref"], w["text"]) for w in r["waiting"]]' 3)" \
  "[[('B1', '픽스처'), ('P1', '사전 인가 밖 행위를 수행할까요 — 대상 cc-cmds · 절단점 머지'), ('P2', '사전 인가 밖 행위를 수행할까요 — 대상 cc-cmds · 절단점 머지 · 막는 세그먼트 A'), ('P3', '어느 안을 고를까요')]]"
check "T16 승인의 since 는 발행 시각이다" "$(row_of pend-run '[w["since"] for w in r["waiting"] if w["ref"] == "P1"]' 3)" "[[1790812800]]"
check "T16 목록의 waiting.text 는 400 바이트에서 자른다" \
  "$(nq "[len(m.clip_bytes(t).encode()) for t in ('가' * 200, 'a' * 401, 'ab')]")" "[399, 400, 2]"

# T17 — an ended run's leftovers are a side mark, not a need.
check "T17 끝난 런의 남은 기록은 ended 에 두 항목이다" \
  "$(row_of ended-left '(r["state"], r["attention"], sorted(w["kind"] for w in r["waiting"]))' 3)" \
  "[('종단', 'ended', ['승인', '중단 기록'])]"
check "T17 기간 밖의 끝난 런은 기본 목록에 없다" "$(nq "'ended-old' in [r['id'] for r in M.runs(now=now)['runs']]")" "False"

# T18 — reclaimed runs follow the state rule and never need a person.
check "T18 회수 런의 열린 승인은 승인대기·watch 이고 waiting 에 담긴다" \
  "$(row_of rec-pend '(r["state"], r["attention"], [w["ref"] for w in r["waiting"]], r["now"], r["result"])' all)" \
  "[('승인대기', 'watch', ['Q1'], None, None)]"
check "T18 오래 자라지 않은 회수 런은 기본 목록에 없다" "$(nq "'rec-pend' in [r['id'] for r in M.runs(now=now)['runs']]")" "False"
check "T18 모두 끝난 회수 런은 종단·ended·미상이다" \
  "$(row_of rec-done '(r["state"], r["attention"], r["result"])' all)" \
  "[('종단', 'ended', {'class': '미상', 'label': None, 'line': None})]"

# T19 — the two hiding reasons and the experiment toggle.
for t in "False False|2|2" "True False|3|0" "False True|1|2" "True True|1|0"; do
  q=${t%%|*}; e=${q% *}; d=${q#* }; rest=${t#*|}
  check "T19 exp=$e dead=$d 의 숨긴 수와 실험 숨긴 수" \
    "$(nq "(lambda R: (R['hidden'], R['hidden_experiment']))(M.runs(days='all', exp=$e, dead=$d, now=now))")" \
    "(${rest%|*}, ${rest#*|})"
  check "T19 exp=$e dead=$d 에서 실험 런은 exp 로만, 버려진 런은 dead 로만 보인다" \
    "$(nq "(lambda ids: [i in ids for i in ('exp-run', 'exp-dead', 'cache-dead')])([r['id'] for r in M.runs(days='all', exp=$e, dead=$d, now=now)['runs']])")" \
    "[$e, $( [ "$e" = True ] && [ "$d" = True ] && printf True || printf False ), $d]"
done
check "T19 실험 base 는 exp=0 의 bases 에 없고 exp=1 에 있다" \
  "$(nq "[any('/cc-cmds/exp/' in b for b in M.runs(days='all', exp=x, now=now)['bases']) for x in (False, True)]")" "[False, True]"
check "T19 실험 런의 비용은 exp=1 일 때만 합계에 든다" \
  "$(nq "[round(M.runs(days='all', exp=x, now=now)['totals']['period_usd'] - M.runs(days='all', now=now)['totals']['period_usd'], 6) for x in (False, True)]")" \
  "[0.0, 7.0]"
check "T19 base 없는 런이 섞여도 by_base 에 열쇠 - 가 있다" \
  "$(nq "'-' in M.runs(days='all', dead=True, now=now)['totals']['by_base']")" "True"
check "T19 고른 레포 밖의 런은 어느 숨긴 수에도 들지 않는다" \
  "$(nq "(lambda R: (R['hidden'], R['hidden_experiment']))(M.runs(days='all', base='$NB', now=now))")" "(1, 0)"

# T20 — results.
check "T20 결과 분류 (다섯 꼴, 알 수 없는 줄, 파생 종단, 무효화가 붙은 P0 잔존)" \
  "$(nq "[(r['id'], r['result']['class'], r['result']['label']) for r in M.runs(days='all', now=now)['runs'] if r['id'].startswith('res-')]" \
     | pyq -c 'import ast,sys; print(sorted(ast.literal_eval(sys.stdin.read())))')" \
  "[('res-bd', '경계', '경계 마감'), ('res-derived', '파생 종단', None), ('res-ok', '종료 조건 성립', None), ('res-p0', 'P0 잔존', None), ('res-q', '질의 잔여', None), ('res-unk', '미상', None), ('res-void', '무효화', None)]"
check "T20 결과의 line 은 done 첫 줄 원문이다" \
  "$(row_of res-bd 'r["result"]["line"]' all)" "['2026-10-02T00:00:00Z 종단 — 경계 마감 · 근거 g']"

# T21 — the day's cost and the display zone.
check "T21 KST 자정 앞뒤의 누적 차이가 오늘 쓴 비용이다" \
  "$(nq "(lambda R: (R['totals']['today_usd'], R['today'], R['tz_label'], R['tz_offset_s'], R['runs'][0]['ended_day']))(M.runs(days='all', base='$TB', now=now))" '' 2026-10-10T20:00:00Z)" \
  "(4.0, '2026-10-11', 'KST', 32400, '2026-10-10')"
check "T21 UTC 로 두면 자정과 날짜가 함께 옮겨진다" \
  "$(nq "(lambda R: (R['totals']['today_usd'], R['today'], R['tz_label'], R['tz_offset_s'], R['runs'][0]['ended_day']))(M.runs(days='all', base='$TB', now=now))" UTC 2026-10-10T20:00:00Z)" \
  "(7.0, '2026-10-10', 'UTC', 0, '2026-10-09')"
check "T21 상세 응답 머리의 tz_offset_s" \
  "$(nq "M.detail('tz-run', now=now)['tz_offset_s']" UTC)·$(nq "M.detail('tz-run', now=now)['tz_offset_s']" '')" "0·32400"

# T22 — every value of the zone table, against the shell's own reading.
dtz_shell() {
  # dtz_shell [<value>] — `cc_display_tz_load`'s two values; no argument leaves it unset.
  if [ "$#" -eq 0 ]; then
    env -u CC_CMDS_AUTOPILOT_TZ bash -c '. "$1"; cc_display_tz_load; printf "%s %s" "$CC_DTZ_OFF" "$CC_DTZ_LABEL"' _ "$ORCH/display-tz.sh"
  else
    CC_CMDS_AUTOPILOT_TZ="$1" bash -c '. "$1"; cc_display_tz_load; printf "%s %s" "$CC_DTZ_OFF" "$CC_DTZ_LABEL"' _ "$ORCH/display-tz.sh"
  fi
}
dtz_port() {
  if [ "$#" -eq 0 ]; then
    env -u CC_CMDS_AUTOPILOT_TZ PYTHONDONTWRITEBYTECODE=1 python3 "$ORCH/dashboard_read.py" display-tz
  else
    PYTHONDONTWRITEBYTECODE=1 python3 "$ORCH/dashboard_read.py" display-tz "$1"
  fi
}
check "T22 시간대 없음 — 포트" "$(dtz_port)" "32400 KST"
check "T22 시간대 없음 — 셸과 같다" "$(dtz_port)" "$(dtz_shell)"
NL_VALUE=$(printf -- '-05:30\nx'); NL_VALUE=${NL_VALUE%x}
WIDE_VALUE=$(printf -- '-\331\240\331\245:\331\243\331\240')
for t in "|32400 KST" "utc|0 UTC" "Z|0 UTC" "+09:00|32400 KST" "+00:00|0 UTC" "-05:30|-19800 UTC-05:30" \
         "+15:00|32400 KST" "Asia/Seoul|32400 KST" "+0900|32400 KST" "+9|32400 KST" \
         "-12:00|-43200 UTC-12:00" "+14:00|50400 UTC+14:00" "+05:59|21540 UTC+05:59" \
         "-12:01|32400 KST" "+14:01|32400 KST" "+05:60|32400 KST" "NL|32400 KST" "WIDE|32400 KST"; do
  v=${t%%|*}; want=${t#*|}; label="$v"
  case "$v" in NL) v="$NL_VALUE"; label='-05:30 + 개행' ;; WIDE) v="$WIDE_VALUE"; label='ASCII 가 아닌 숫자의 -05:30' ;; esac
  check "T22 시간대 '$label' — 포트" "$(dtz_port "$v")" "$want"
  check "T22 시간대 '$label' — 셸과 같다" "$(dtz_port "$v")" "$(dtz_shell "$v")"
done

# T23 — steps, from plan steps and `stage-result` rows in both writers' shapes.
STEPS=$(nq "[(s['id'], s['kind'], s['status'], s['attempts'], s['end_class']) for s in M.detail('nb-anchor', now=now)['steps']]")
check "T23 스텝 진행 (park 뒤 완료, S2 와 재수렴, 드라이버 이름만, 시도 없음, 세그먼트 두 꼴, .kind=review)" "$STEPS" \
  "[('D1', 'design', '끝남', 2, '정상 완료'), ('AU', 'reconverge', '실패', 2, '외부 종료'), ('SP', 'split', '끝남', 1, '정상 완료'), ('V1', None, '대기', 0, None), ('I1', 'implement', '끝남', 3, '정상 완료'), ('R1', 'review', '도는 중', 3, '정상 완료')]"
check "T23 세그먼트가 두 스텝에 자식으로 달린다" \
  "$(nq "[(s['id'], s['segments']) for s in M.detail('nb-anchor', now=now)['steps'] if s['segments']]")" \
  "[('I1', [{'id': 'A', 'status': '끝남', 'attempts': 2}, {'id': 'B', 'status': '끝남', 'attempts': 1}]), ('R1', [{'id': 'A', 'status': '도는 중', 'attempts': 3}, {'id': 'B', 'status': '끝남', 'attempts': 0}])]"
check "T23 스텝의 시작·끝·비용은 시도에서 온다" \
  "$(nq "[(s['id'], s['ended'], s['usd']) for s in M.detail('nb-anchor', now=now)['steps'] if s['id'] in ('D1', 'I1')]")" \
  "[('D1', 1790820000, 2.0), ('I1', 1790845200, 1.75)]"
check "T23 implement 스텝이 둘이면 implement 시도는 어느 스텝에도 달리지 않는다" \
  "$(nq "[(s['id'], s['attempts']) for s in M.detail('nb-two', now=now)['steps']]")" "[('I1', 0), ('I2', 0), ('R1', 1)]"
check "T23 now 는 살아 있는 스테이지의 이름·종류·시도다" \
  "$(row_of nb-anchor 'r["now"]' all)" "[{'stage': 'A', 'kind': 'review', 'attempt': '4', 'blocked': None}]"
check "T23 timeline 항목 모양이 그대로다" \
  "$(nq "sorted(set(k for t in M.detail('nb-anchor', now=now)['timeline'] for k in t))")" \
  "['attempt', 'class', 'duration_s', 'end', 'end_src', 'kind', 'rc', 'reattach', 'shift', 'stage', 'start', 'start_src', 'usd']"

# T24 — the cost breakdowns, each summing to the run's total.
check "T24 by_step (세그먼트 reconverge 비용은 기타)" \
  "$(nq "sorted((k, round(v, 6)) for k, v in M.detail('nb-anchor', now=now)['cost']['by_step'].items())")" \
  "[('AU', 1.0), ('D1', 2.0), ('I1', 1.75), ('R1', 1.25), ('SP', 0.5), ('기타', 0.5)]"
check "T24 세 분해의 합이 각각 usd 와 같다" \
  "$(nq "(lambda c: [round(sum(c[k].values()) - c['usd'], 6) for k in ('by_step', 'by_kind', 'by_segment')])(M.detail('nb-anchor', now=now)['cost'])")" \
  "[0.0, 0.0, 0.0]"
check "T24 by_segment" \
  "$(nq "sorted((k, round(v, 6)) for k, v in M.detail('nb-anchor', now=now)['cost']['by_segment'].items())")" \
  "[('A', 3.5), ('기타', 3.5)]"

# T25 — judgments: two judgments, three automatic answers and one automatic
# resolution; the execution row quoting `kind=judgment` and a person's answer
# are not among them.
check "T25 자율 판단 여섯 항목과 각 at" \
  "$(nq "[(j['source'], j['at'], j['결정'], j['해소 승인']) for j in M.detail('nb-anchor', now=now)['judgments']['items']]")" \
  "[('판단', None, '채택', '-'), ('판단', 1790830800, '채택', 'J1'), ('자동 답', 1790834400, '좌석 실행', None), ('자동 답', 1790838000, '재시도', None), ('자동 답', 1790845200, '재수렴', None), ('자동 해소', 1790848800, '보류', 'K1')]"
check "T25 판단 부류별 개수" "$(nq "M.detail('nb-anchor', now=now)['judgments']['by_class']")" "{'감사-발견': 1, '잔여-항목': 1}"

# T26 — reviews, links and PRs.
check "T26 리뷰 사이클 (옛 행의 빈 필드는 null)" \
  "$(nq "M.detail('nb-anchor', now=now)['reviews']")" \
  "[{'seg': 'A', 'cycles': [{'사이클': '1', 'P0': 1, 'P1': 2, '모드': '전체', '리뷰 종결': '수정', '리포트 경로': '/r/a1.md'}, {'사이클': '2', 'P0': 0, 'P1': 0, '모드': '확인', '리뷰 종결': None, '리포트 경로': None}]}]"
check "T26 PR 주소 (레포= 우선, 단일 대상 슬러그)" "$(row_of nb-anchor 'r["prs"]' all)" \
  "[[{'seg': 'A', 'number': 11, 'url': 'https://github.com/Other/repo/pull/11'}, {'seg': 'B', 'number': 12, 'url': 'https://github.com/Nharu/cc-cmds/pull/12'}]]"
check "T26 슬러그를 정할 수 없거나 꼴이 아니면 url 이 null 이다" \
  "$(row_of nb-two '[p["url"] for p in r["prs"]]' all)" "[[None, None]]"
check "T26 링크" \
  "$(nq "(lambda L: (L['branches'], L['design_doc'], L['report'], L['review_reports'], L['ledger'] == '$NBP/nb-anchor.md', L['manifest'] == '$NBP/nb-anchor.plan.md'))(M.detail('nb-anchor', now=now)['links'])")" \
  "([{'seg': 'A', 'branch': 'seg/a'}, {'seg': 'B', 'branch': 'seg/b'}], '/d/doc.md', '/d/report.md', [{'seg': 'A', 'cycle': '1', 'path': '/r/a1.md'}], True, True)"
check "T26 마감이 시각이면 epoch 이고 남은 초가 있다" \
  "$(row_of nb-anchor '(r["deadline"], r["deadline_left_s"] > 0, r["started_at"], r["elapsed_s"] > 0)' all)" \
  "[(4070908800, True, 1790812800, True)]"
check "T26 마감이 시각이 아니면 원문이고 남은 초는 null 이다" \
  "$(row_of nb-two '(r["deadline"], r["deadline_left_s"])' all)" "[('없음', None)]"

# T27 — line numbers.
check "T27 계보=B: 자율 승인 행이 섞여도 상태 토큰이 같다" \
  "$(nq "(lambda s: len(s) == 2 and s['lin-with'] == s['lin-without'])(dict((r['id'], (r['state'], r['band'], r['attention'])) for r in M.runs(days='all', dead=True, now=now)['runs'] if r['id'].startswith('lin-')))")" "True"
check "T27 그 행은 judgments 에 들지 않는다" "$(nq "M.detail('lin-with', now=now)['judgments']['items']")" "[]"
check "T27 timeline 이 줄 번호를 더하기 전과 같다" \
  "$(nq "json.dumps(M.detail('tl-run', now=now)['timeline'], ensure_ascii=False, sort_keys=True)")" \
  '[{"attempt": "1", "class": "정상 완료", "duration_s": null, "end": 1790816400, "end_src": "cost", "kind": "design", "rc": 0, "reattach": null, "shift": null, "stage": "D1", "start": null, "start_src": "없음", "usd": 1.0}, {"attempt": "1", "class": "정상 완료", "duration_s": null, "end": 1790820000, "end_src": "cost", "kind": null, "rc": 0, "reattach": null, "shift": null, "stage": "S4", "start": null, "start_src": "없음", "usd": 2.5}, {"attempt": "2", "class": "외부 종료", "duration_s": null, "end": null, "end_src": "없음", "kind": "review", "rc": 1, "reattach": null, "shift": null, "stage": "A", "start": null, "start_src": "없음", "usd": null}]'
LN="$WORK/ln/ln-run"; mkdir -p "$LN"; halt_rec "$LN/halt/S1.md" "되돌림 질문" ""
check "T27 원장을 나눠 읽어도 되돌림 판정이 한 번에 읽은 것과 같다" \
  "$(cd "$ORCH" && pyq -c '
import os, sys
import dashboard_read as m
rd = sys.argv[1]; lp = os.path.join(rd, "L.md")
with open(lp, "w") as f:
    f.write("# 파이프라인 런 보고서\n\n- `segment` | id=S1 | 상태=실행중\n- `중단 답` | 중단 기록=%s/halt/S1.md | 선택지=재시도\n" % rd)
led = m.Ledger(lp); led.refresh()
n = lambda L: len(m.unanswered_halt_records(rd, L.numbered()))
a = n(led)
with open(lp, "a") as f:
    f.write("- `blocked` | 스코프=cone | 원인=막힘 | 막힌 답 줄=4")
led.refresh(); b = n(led)
with open(lp, "a") as f:
    f.write("\n")
led.refresh(); c = n(led)
whole = m.Ledger(lp); whole.refresh()
print(a, b, c, n(whole))' "$LN")" "0 0 1 1"
check "T27 그 판정이 셸과 같다" \
  "$(bash -c '. "$1"; cc_unanswered_halts "$2" "$2/L.md"' _ "$LIVENESS" "$LN")" "1"

# T28 — the HTTP layer over this root: the toggle reaches the tick cache, the
# shell row, and the evaluation cache picking up a new halt record.
PN=$(free_port)
dash "$NX" "$PN" ensure
get "$PN" '/api/runs?days=all&exp=0' >/dev/null; B0=$(cat "$WORK/body"); E0=$(etag_of)
get "$PN" '/api/runs?days=all&exp=1' >/dev/null; B1=$(cat "$WORK/body"); E1x=$(etag_of)
check "T28 같은 틱의 exp=0 과 exp=1 은 본문이 다르다" "$( [ "$B0" != "$B1" ] && printf 다름 || printf 같음 )" "다름"
check "T28 같은 틱의 exp=0 과 exp=1 은 ETag 가 다르다" "$( [ "$E0" != "$E1x" ] && printf 다름 || printf 같음 )" "다름"
get "$PN" '/api/runs?days=all&dead=1' >/dev/null
check "T28 셸 행이 새 키를 모두 가진다" \
  "$(jq_body '[(r["attention"], r["waiting"], r["now"], r["result"], r["prs"], r["experiment"]) for r in d["runs"] if r["id"] == "nx-shell"]')" \
  "[('dead', [], None, None, [], False)]"
check "T28 모든 행이 새 키를 가진다" \
  "$(jq_body "sorted({k for r in d['runs'] for k in $NEW_KEYS if k not in r})")" "[]"
check "T28 버려진 런은 dead 다" "$(jq_body '[r["attention"] for r in d["runs"] if r["id"] == "cache-dead"]')" "['dead']"
check "T28 얼어 있는 끝난 런은 기록이 없을 때 waiting 이 비어 있다" \
  "$(jq_body '[(r["attention"], len(r["waiting"])) for r in d["runs"] if r["id"] == "cache-end"]')" "[('ended', 0)]"
halt_rec "$NX/cc-cmds/run/cache-end/halt/S1#1.md" "얼린 뒤 생긴 질문" ""
halt_rec "$NX/cc-cmds/run/cache-dead/halt/S1#1.md" "버려진 뒤 생긴 질문" ""
sleep 3.2
get "$PN" '/api/runs?days=all' >/dev/null
check "T28 얼어 있던 끝난 런에 기록을 더하면 waiting 이 바뀌고 ended 그대로다" \
  "$(jq_body '[(r["attention"], len(r["waiting"])) for r in d["runs"] if r["id"] == "cache-end"]')" "[('ended', 1)]"
check "T28 버려진 런에 기록을 더하면 다음 응답에서 need 다" \
  "$(jq_body '[r["attention"] for r in d["runs"] if r["id"] == "cache-dead"]')" "['need']"

# T29 — the preview entry: up inside a stage, the resident server untouched.
REC_BEFORE=$(cat "$(rec_file "$NX")")
PUB_PID=$(rec_get "$NX" pid)
PX="$WORK/px"; mkdir -p "$PX/cc-cmds/run"
PP=$(free_port)
env -u CI XDG_STATE_HOME="$PX" CC_PIPELINE_STAGE_ID='A#1' CC_PIPELINE_SEGMENT=A CC_CMDS_DASHBOARD_PORT="$PN" \
  PYTHONDONTWRITEBYTECODE=1 python3 "$DASH" preview --port "$PP" 2>"$WORK/preview.err" &
PREVIEW_PID=$!
i=0
while [ "$i" -lt 50 ] && [ "$(get "$PP" /healthz)" != "200" ]; do sleep 0.1; i=$((i + 1)); done
check "T29 스테이지 표지가 있어도 preview 가 /healthz 에 답한다" "$(get "$PP" /healthz)" "200"
check "T29 preview 가 / 를 내준다" "$(get "$PP" /)" "200"
check "T29 preview 가 /api/runs 를 내준다" "$(get "$PP" /api/runs)" "200"
check "T29 preview 는 공용 서버의 기록·잠금·로그를 만들지 않는다" \
  "$( [ -e "$PX/cc-cmds/dashboard" ] && printf 있음 || printf 없음 )" "없음"
check "T29 미리 띄운 공용 서버의 기록이 그대로다" "$(cat "$(rec_file "$NX")")" "$REC_BEFORE"
check "T29 미리 띄운 공용 서버가 그대로 돈다" "$(kill -0 "$PUB_PID" 2>/dev/null && printf alive || printf gone)" "alive"
kill "$PREVIEW_PID" 2>/dev/null
wait_gone "$PREVIEW_PID"
check "T29 preview 가 SIGTERM 으로 내려간다" "$(kill -0 "$PREVIEW_PID" 2>/dev/null && printf alive || printf gone)" "gone"
PREVIEW_PID=""
pv() { env -u CI XDG_STATE_HOME="$PX" CC_CMDS_DASHBOARD_PORT="$1" PYTHONDONTWRITEBYTECODE=1 \
         python3 "$DASH" preview --port "$2" 2>/dev/null; }
PQ=$(free_port)
pv "$PN" 0; rc=$?
check "T29 포트 0 이면 띄우지 않는다" "$( [ "$rc" -ne 0 ] && printf 비영 || printf 0 )" "비영"
pv "$PQ" "$PQ"; rc=$?
check "T29 공용 서버 포트면 띄우지 않는다" "$( [ "$rc" -ne 0 ] && printf 비영 || printf 0 )" "비영"
PH=$(free_port)
pyq -c 'import socket,sys,time
s=socket.socket(); s.bind(("127.0.0.1",int(sys.argv[1]))); s.listen(8); time.sleep(30)' "$PH" &
HOLDER_PID=$!
sleep 0.5
pv "$PN" "$PH"; rc=$?
check "T29 쓰이는 포트면 띄우지 않는다" "$( [ "$rc" -ne 0 ] && printf 비영 || printf 0 )" "비영"
kill "$HOLDER_PID" 2>/dev/null; HOLDER_PID=""
check "T29 거부된 preview 도 공용 서버의 기록을 만들지 않는다" \
  "$( [ -e "$PX/cc-cmds/dashboard" ] && printf 있음 || printf 없음 )" "없음"
stop_in "$NX"
XDG_STATE_HOME="$MAIN_XDG"

# ---------------------------------------------------------------------------
# T14 — Python 3.9 syntax, pinned by the parser rather than by the host.
# ---------------------------------------------------------------------------
for f in "$ORCH"/dashboard*.py; do
  r=$(pyq -c 'import ast,sys; ast.parse(open(sys.argv[1]).read(), feature_version=(3, 9)); print("ok")' "$f" 2>&1)
  check "T14 $(basename "$f") 는 Python 3.9 문법이다" "$r" "ok"
done

printf '\n통과 %s · 실패 %s\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
