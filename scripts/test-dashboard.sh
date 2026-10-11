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
# T14 — Python 3.9 syntax, pinned by the parser rather than by the host.
# ---------------------------------------------------------------------------
for f in "$ORCH"/dashboard*.py; do
  r=$(pyq -c 'import ast,sys; ast.parse(open(sys.argv[1]).read(), feature_version=(3, 9)); print("ok")' "$f" 2>&1)
  check "T14 $(basename "$f") 는 Python 3.9 문법이다" "$r" "ok"
done

printf '\n통과 %s · 실패 %s\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
