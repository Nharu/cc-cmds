#!/usr/bin/env bash
# lint-bash-portability: self-skip
# Test the pacing actor: `fleet.sh sensor`, `fleet.sh dispatch <lane>` and
# `fleet.sh agent install|uninstall|status`.
#
# Everything the actor touches on a real host is stubbed on PATH or by env:
# `launchctl` and `plutil` are scripts under $WORK/bin, the lane probe is a
# script that prints a file and exits with a chosen code, the seat homes are
# directories under $WORK, and `gate.sh` / `watch.sh` / `run.sh` are stubs
# beside a COPY of fleet.sh — the actor resolves its siblings from its own
# directory, so the copy is what lets the dispatch path run end to end without
# a driver. `FLEET_NOW_EPOCH` fixes the clock so every tracker row and every
# backlog timestamp is written relative to one instant.
#
# What is asserted, and why each is its own check:
#   heartbeat before ladder   — a failing tick still leaves a fresh heartbeat,
#                               so "alive but failing" never reads as "dead"
#   atomic publish, tick_seq  — no temp file survives, and the sequence climbs
#   record fields, exhaustive — state.json and verdict-history carry exactly
#                               the documented keys; a key added or dropped
#                               silently is a contract change nobody sees
#   two token sets, unmixed   — a verdict never appears where a reason goes
#   schema mismatch = absence — a foreign schema is not "newer", it is nothing
#   degraded publish          — a probe past the budget drops the census only
#   truncated once per streak — three unavailable censuses leave ONE record
#   dispatch: three clauses   — brake / lane / window / burn each refuse and
#                               log, and the refusal never parks the record
#   dispatch: five parks      — each park token from its own evidence
#   dispatch: oversize skip   — a >4 KiB record is skipped, never parked
#   dispatch: launch shape    — stub, snapshot, ONE watcher line, run.sh, done
#   dispatch: one head, two   — two lanes racing for one pending record start
#             lanes             run.sh once; a stale claim lock is broken; a
#                               status flip whose line is gone does not overwrite
#   agent: idempotent install, half-installed refuse, running refuse,
#          per-label bootout on uninstall
#   source greps              — no detach helper, no notifier, one watcher line
#
# Usage: bash scripts/test-fleet.sh

set -uo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
ORCH="$repo_root/plugins/cc-cmds/orchestrator"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/cc-fleet-test.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

passed=0; failed=0
ok()   { passed=$((passed + 1)); printf 'PASS: %s\n' "$1"; }
bad()  { failed=$((failed + 1)); printf 'FAIL: %s — %s\n' "$1" "${2:-}" >&2; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got '$2', want '$3'"; fi; }
count_lines() { local n; n=$(grep -c '' "$1" 2>/dev/null || true); printf '%s' "${n:-0}"; }

# ---------------------------------------------------------------------------
# The fixture: a copy of fleet.sh with stub siblings, stub tools, two seats.
# ---------------------------------------------------------------------------
FX="$WORK/orch"; mkdir -p "$FX" "$WORK/bin" "$WORK/xdg" "$WORK/agents"
cp "$ORCH/fleet.sh" "$ORCH/fleet-agent.plist.in" "$FX/"
FLEET="$FX/fleet.sh"

cat > "$FX/gate.sh" <<'EOF'
#!/usr/bin/env bash
printf 'gate %s CLAUDE_CONFIG_DIR=%s\n' "$*" "${CLAUDE_CONFIG_DIR:-}" >> "$TEST_LOG_DIR/gate.log"
exit 0
EOF
cat > "$FX/watch.sh" <<'EOF'
#!/usr/bin/env bash
printf 'watch %s\n' "$*" >> "$TEST_LOG_DIR/watch.log"
exit 0
EOF
cat > "$FX/run.sh" <<'EOF'
#!/usr/bin/env bash
printf 'run %s CLAUDE_CONFIG_DIR=%s\n' "$*" "${CLAUDE_CONFIG_DIR:-}" >> "$TEST_LOG_DIR/run.log"
# With TEST_RUN_STEAL set the stub rewrites the dispatched record under the
# driver's feet, so the dispatcher's `done` flip finds no line to flip.
if [ -n "${TEST_RUN_STEAL:-}" ]; then
  sed 's/"dispatched"/"stolen"/' "$FLEET_PACE_ROOT/backlog.jsonl" > "$FLEET_PACE_ROOT/backlog.jsonl.new"
  mv -f "$FLEET_PACE_ROOT/backlog.jsonl.new" "$FLEET_PACE_ROOT/backlog.jsonl"
fi
exit 0
EOF
# The lane probe stub: prints $TEST_PROBE_OUT, sleeps $TEST_PROBE_SLEEP first,
# exits with $TEST_PROBE_RC.
cat > "$WORK/bin/lane-probe.sh" <<'EOF'
#!/usr/bin/env bash
[ -n "${TEST_PROBE_SLEEP:-}" ] && sleep "$TEST_PROBE_SLEEP"
[ -r "${TEST_PROBE_OUT:-/nonexistent}" ] && cat "$TEST_PROBE_OUT"
exit "${TEST_PROBE_RC:-0}"
EOF
# plutil stub: `-extract profiles_v3 raw -o - <plist>` prints base64 of
# $TEST_TRACKER_JSON; `-lint` passes.
cat > "$WORK/bin/plutil" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  -lint) exit 0 ;;
  -extract) [ -r "${TEST_TRACKER_JSON:-/nonexistent}" ] || exit 1; base64 < "$TEST_TRACKER_JSON"; exit 0 ;;
esac
exit 1
EOF
# launchctl stub: loaded labels live in $TEST_LAUNCHD_STATE, running ones in
# $TEST_LAUNCHD_RUNNING; every call is logged.
cat > "$WORK/bin/launchctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TEST_LAUNCHD_LOG"
state="$TEST_LAUNCHD_STATE"; running="$TEST_LAUNCHD_RUNNING"
touch "$state" "$running"
case "$1" in
  print)
    label=${2##*/}
    grep -qxF "$label" "$state" || exit 113
    if grep -qxF "$label" "$running"; then printf 'state = running\n'; else printf 'state = waiting\n'; fi
    exit 0 ;;
  bootstrap)
    label=$(sed -n '/<key>Label<\/key>/{n;s/.*<string>\(.*\)<\/string>.*/\1/p;}' "$3")
    grep -qxF "$label" "$state" || printf '%s\n' "$label" >> "$state"
    exit 0 ;;
  bootout)
    label=${2##*/}
    grep -vxF "$label" "$state" > "$state.new" || true; mv "$state.new" "$state"
    exit 0 ;;
esac
exit 1
EOF
chmod +x "$FX"/*.sh "$WORK/bin"/*

SEATS="$WORK/seats"; HCC="$SEATS/.claude-cc"; HCCI="$SEATS/.claude-cci"
mkdir -p "$HCC/projects" "$HCCI/projects"
printf '{"oauthAccount":{"organizationUuid":"org-cc","profileFetchedAt":"2026-09-19T00:00:00Z"}}\n' > "$HCC/.claude.json"
printf '{"oauthAccount":{"organizationUuid":"org-cci"}}\n' > "$HCCI/.claude.json"

NOW=$(date -u +%s)
OFF=978307200
iso() { jq -rn --argjson e "$1" '$e | todate'; }

export TEST_LOG_DIR="$WORK/logs"; mkdir -p "$TEST_LOG_DIR"
export TEST_LAUNCHD_LOG="$WORK/launchctl.log" TEST_LAUNCHD_STATE="$WORK/launchd.state" TEST_LAUNCHD_RUNNING="$WORK/launchd.running"
export TEST_TRACKER_JSON="$WORK/tracker.json"
export TEST_PROBE_OUT="$WORK/probe.out" TEST_PROBE_RC=0 TEST_PROBE_SLEEP=""
touch "$WORK/tracker.plist"
: > "$WORK/probe.out"

fresh_pace() {
  # A new pace root per scenario: burn.cache and the streak file must not leak.
  PACE="$WORK/pace-$1"; rm -rf "$PACE"; mkdir -p "$PACE"
}
fleet() {
  # fleet <args...> — the actor under the fixture's environment.
  FLEET_PACE_ROOT="$PACE" FLEET_SEAT_HOMES="$HCC:$HCCI" FLEET_TRACKER_PLIST="$WORK/tracker.plist" \
  FLEET_PLUTIL="$WORK/bin/plutil" FLEET_LAUNCHCTL="$WORK/bin/launchctl" FLEET_LAUNCH_AGENTS_DIR="$WORK/agents" \
  FLEET_LANE_PROBE="$WORK/bin/lane-probe.sh" FLEET_NOW_EPOCH="$NOW" XDG_STATE_HOME="$WORK/xdg" \
  HOME="$WORK/home" bash "$FLEET" "$@"
}
tracker_ok() {
  # tracker_ok <weekly-pct> [<session-pct>] — one fresh row for org-cc.
  jq -cn --argjson now "$NOW" --argjson off "$OFF" --argjson wp "$1" --argjson sp "${2:-10}" '
    [{name: "cc", organizationId: "org-cc",
      claudeUsage: {weeklyPercentage: $wp, weeklyResetTime: ($now - $off + 86400),
                    sessionPercentage: $sp, sessionResetTime: ($now - $off + 7200),
                    lastUpdated: ($now - $off - 10)}}]' > "$TEST_TRACKER_JSON"
  touch "$WORK/tracker.plist"
}
tracker_gone() { rm -f "$TEST_TRACKER_JSON"; }
burn_heavy() {
  # One transcript under the cc seat with 5M output tokens ten minutes ago:
  # 25 Mwt x 0.104 / 4 = 0.65 %p/h, above one seat's 100/168 = 0.595 cap.
  local t; t=$(iso $(( NOW - 600 )))
  mkdir -p "$HCC/projects/p"
  printf '{"timestamp":"%s","message":{"usage":{"input_tokens":0,"output_tokens":5000000}}}\n' "$t" > "$HCC/projects/p/s.jsonl"
}
burn_none() { rm -rf "$HCC/projects/p"; }
state_field() { jq -r "$1" "$PACE/state.json"; }

# ===========================================================================
# SENSOR
# ===========================================================================

# --- heartbeat before the ladder --------------------------------------------
fresh_pace hb
tracker_gone; burn_none
mkdir -p "$PACE/verdict-history.jsonl"   # the history append fails; the tick fails after publishing
fleet sensor >/dev/null 2>&1; rc=$?
[ "$rc" != "0" ] && ok "실패하는 틱은 0이 아닌 코드로 끝난다" || bad "실패하는 틱은 0이 아닌 코드로 끝난다" "rc=$rc"
check "실패하는 틱에서도 하트비트는 먼저 쓰인다" "$(sed -n '1p' "$PACE/sensor.heartbeat" 2>/dev/null)" "$(iso "$NOW")"

# --- atomic publish and tick_seq --------------------------------------------
fresh_pace seq
fleet sensor >/dev/null 2>&1
check "첫 틱은 tick_seq 1 을 발행한다" "$(state_field .tick_seq)" "1"
fleet sensor >/dev/null 2>&1
check "둘째 틱은 tick_seq 2 로 단조 증가한다" "$(state_field .tick_seq)" "2"
check "발행 뒤 임시 파일이 남지 않는다" "$(find "$PACE" -name '.tmp.*' | wc -l | tr -d ' ')" "0"
check "state.json 은 스키마를 축자로 싣는다" "$(state_field .schema)" "cc-pace-state v1"
check "computed_at 은 고정한 시계와 같다" "$(state_field .computed_at)" "$(iso "$NOW")"

# --- record fields, exhaustive ------------------------------------------------
want_state='schema,tick_seq,computed_at,computed_at_epoch,tick_ms,tick_overrun,slept,tracker,burn_4h,burn_truncated,burn_per_stage_4h,live_4h_avg,fleet_capacity,candidates_empty,seats,reseat_candidates,lanes,lane_census,verdict,verdict_reason'
check "state.json 의 키 집합은 정확히 문서화된 20개다" "$(jq -r 'keys_unsorted | join(",")' "$PACE/state.json")" "$want_state"
check "seats[] 의 키 집합은 정확히 다섯이다" "$(jq -r '.seats[0] | keys_unsorted | join(",")' "$PACE/state.json")" "home,org,allow,session_pct,ttr"
want_hist='schema,tick_seq,observed_at,verdict,prev_verdict,reason,seat_allowance,burn_4h,candidates_empty'
check "verdict-history 레코드의 키 집합은 정확히 아홉이다" "$(sed -n '1p' "$PACE/verdict-history.jsonl" | jq -r 'keys_unsorted | join(",")')" "$want_hist"
check "첫 레코드의 prev_verdict 는 null 이다" "$(sed -n '1p' "$PACE/verdict-history.jsonl" | jq -r '.prev_verdict')" "null"
check "판정이 같으면 둘째 틱은 레코드를 더하지 않는다" "$(count_lines "$PACE/verdict-history.jsonl")" "1"

# --- two token sets, never mixed ----------------------------------------------
tokens_ok() {
  # tokens_ok <state-json> — verdict from one set, reason from the other.
  jq -e '(.verdict | IN("가속","유지","제동")) and (.verdict_reason | IN("brake","idle","lanes-below-target","default","tracker-skip","truncated"))' "$1" >/dev/null 2>&1
}
tokens_ok "$PACE/state.json" && ok "판정과 사유가 각자의 토큰 집합에서 온다" || bad "판정과 사유가 각자의 토큰 집합에서 온다" "$(jq -c '{verdict,verdict_reason}' "$PACE/state.json")"
printf '{"verdict":"idle","verdict_reason":"가속"}\n' > "$WORK/cross.json"
tokens_ok "$WORK/cross.json" && bad "교차 픽스처는 토큰 검사에 걸린다" "passed" || ok "교차 픽스처는 토큰 검사에 걸린다"
check "센서스가 없고 트래커가 없으면 유휴 판정은 가속(idle)이다" "$(state_field '.verdict + " " + .verdict_reason')" "가속 idle"
check "트래커 부재는 unavailable 로 발행된다" "$(state_field .tracker)" "unavailable"

# --- schema mismatch is absence ----------------------------------------------
fresh_pace schema
printf '{"schema":"cc-pace-state v2","tick_seq":99,"verdict":"제동","computed_at_epoch":%s}\n' "$NOW" > "$PACE/state.json"
fleet sensor >/dev/null 2>&1
check "다른 스키마의 state.json 은 부재로 읽혀 tick_seq 가 1 부터 간다" "$(state_field .tick_seq)" "1"

# --- degraded publish: the probe past the budget ------------------------------
fresh_pace overrun
TEST_PROBE_SLEEP=7 fleet sensor >/dev/null 2>&1
check "예산을 넘긴 센서스는 tick_overrun=true 로 발행된다" "$(state_field .tick_overrun)" "true"
check "예산을 넘긴 틱은 lanes=unavailable 이고 나머지는 발행된다" "$(state_field '.lanes + " " + .schema')" "unavailable cc-pace-state v1"
check "센서스 열화는 가속을 막지 않는다 (burn 절단이 아니다)" "$(state_field .verdict)" "가속"

# --- truncated: one record per streak -----------------------------------------
fresh_pace streak
TEST_PROBE_RC=3 fleet sensor >/dev/null 2>&1
TEST_PROBE_RC=3 fleet sensor >/dev/null 2>&1
check "열거 실패 두 틱까지는 truncated 레코드가 없다" "$(jq -r 'select(.reason == "truncated") | .tick_seq' "$PACE/verdict-history.jsonl" | count_lines /dev/stdin)" "0"
TEST_PROBE_RC=3 fleet sensor >/dev/null 2>&1
TEST_PROBE_RC=3 fleet sensor >/dev/null 2>&1
check "세 틱 연속 열거 실패는 truncated 레코드를 정확히 하나 남긴다" "$(grep -c '"reason":"truncated"' "$PACE/verdict-history.jsonl" || true)" "1"
check "probe exit 3 은 tick_overrun 이 아니다" "$(state_field .tick_overrun)" "false"
check "lanes-streak 파일은 시작 틱과 기록 여부를 든다" "$(cat "$PACE/lanes-streak")" "1 1"
TEST_PROBE_RC=0 fleet sensor >/dev/null 2>&1
[ ! -e "$PACE/lanes-streak" ] && ok "센서스가 돌아오면 streak 파일이 지워진다" || bad "센서스가 돌아오면 streak 파일이 지워진다" "still there"

# --- the ladder with a tracker ---------------------------------------------------
fresh_pace ladder
tracker_ok 50 10; burn_heavy
fleet sensor >/dev/null 2>&1
check "트래커 행이 살아 있으면 tracker=ok" "$(state_field .tracker)" "ok"
check "좌석 허용치는 min(rem/ttr, 100/168) 이다" "$(state_field '.seats[0].allow | . * 1000 | floor')" "595"
check "용량 < 소진이고 후보가 없으면 제동(brake)" "$(state_field '.verdict + " " + .verdict_reason')" "제동 brake"
check "후보 목록은 비어 있다" "$(state_field .candidates_empty)" "true"
check "판정 변화는 verdict-history 에 prev_verdict=null 로 남는다 (첫 틱)" "$(sed -n '1p' "$PACE/verdict-history.jsonl" | jq -r '.verdict')" "제동"
check "seat_allowance 는 홈을 키로 하는 객체다" "$(sed -n '1p' "$PACE/verdict-history.jsonl" | jq -r --arg h "$HCC" '.seat_allowance[$h] | . * 1000 | floor')" "595"
burn_none
rm -f "$PACE/burn.cache"
fleet sensor >/dev/null 2>&1
check "소진이 사라지면 판정이 바뀌고 이력이 한 건 는다" "$(count_lines "$PACE/verdict-history.jsonl")" "2"
check "둘째 레코드의 prev_verdict 는 직전 판정이다" "$(sed -n '2p' "$PACE/verdict-history.jsonl" | jq -r '.prev_verdict')" "제동"
check "seat-bindings 는 좌석당 한 레코드로 시작한다" "$(count_lines "$PACE/seat-bindings.jsonl")" "2"
check "seat-bindings 레코드는 정확히 아홉 필드다" "$(sed -n '1p' "$PACE/seat-bindings.jsonl" | jq -r 'keys_unsorted | join(",")')" "observed_at,prev_observed_at,login_at,home,org_prev,org,label,via_cc_swap,slept"
[ -s "$PACE/night-summary.md" ] && ok "야간 요약이 쓰인다" || bad "야간 요약이 쓰인다" "absent"
tracker_gone

# ===========================================================================
# DISPATCH
# ===========================================================================
WT="$WORK/wt"; mkdir -p "$WT/docs"
( cd "$WT" && git init -q && git config user.email t@t && git config user.name t \
  && printf 'design\n' > docs/x.md && git add . && git commit -qm init ) >/dev/null 2>&1
BASE=$(cd "$WT" && git rev-parse HEAD)
DOC_SHA=$(shasum -a 256 "$WT/docs/x.md" | cut -d' ' -f1)
MANIFEST="$WORK/R1.plan.md"
printf '<!-- cc-run-manifest v1; run-id=R1; owner-doc=docs/x.md; origin-worktree=%s; -->\n\n**설계 문서 전체 sha256**: %s\n' "$WT" "$DOC_SHA" > "$MANIFEST"

backlog_record() {
  # backlog_record <id> [<jq-overrides>] — one pending record, timestamps
  # relative to NOW: authorized 2h ago, enqueued 1h ago, deadline in 24h.
  jq -cn --arg id "$1" --arg m "$MANIFEST" --arg sha "$DOC_SHA" --arg base "$BASE" \
     --arg enq "$(iso $(( NOW - 3600 )))" --arg auth "$(iso $(( NOW - 7200 )))" --arg dl "$(iso $(( NOW + 86400 )))" \
     '{schema: "cc-pace-backlog v1", id: $id, status: "pending", enqueued_at: $enq, authorized_at: $auth,
       deadline: $dl, manifest_path: $m, doc_sha256: $sha, base_commit: $base}'"${2:+ | $2}"
}
set_backlog() { printf '%s\n' "$@" > "$PACE/backlog.jsonl"; }
write_state() {
  # write_state <verdict> <cc-session-pct|null> <capacity|null> <burn|null> <candidates_empty>
  jq -cn --argjson now "$NOW" --arg v "$1" --argjson sp "$2" --argjson cap "$3" --argjson b "$4" --argjson ce "$5" --arg h "$HCC" '
    {schema: "cc-pace-state v1", tick_seq: 7, computed_at: ($now | todate), computed_at_epoch: $now,
     verdict: $v, fleet_capacity: $cap, burn_4h: $b, candidates_empty: $ce,
     seats: [{home: $h, org: "org-cc", allow: 0.5, session_pct: $sp, ttr: 24}]}' > "$PACE/state.json"
}
backlog_status() { jq -r --arg id "$1" 'select(.id == $id) | .status' "$PACE/backlog.jsonl"; }
backlog_field() { jq -r --arg id "$1" "select(.id == \$id) | $2" "$PACE/backlog.jsonl"; }
clear_logs() { rm -f "$TEST_LOG_DIR"/*.log; }

# --- clause brake ------------------------------------------------------------
fresh_pace d-brake; write_state 제동 10 null null true; set_backlog "$(backlog_record b1)"
fleet dispatch cc >/dev/null 2>&1
check "제동 판정은 절 brake 로 거부한다" "$(backlog_field b1 .last_refusal_clause)" "brake"
check "거부는 레코드를 pending 으로 둔다" "$(backlog_status b1)" "pending"
check "거부는 refusals.tsv 에 한 줄 남는다" "$(cut -f2,3,4 "$PACE/refusals.tsv")" "$(printf 'cc\tbrake\t제동')"

# --- clause lane (live probe, fails closed) -------------------------------------
fresh_pace d-lane; write_state 가속 10 null null true; set_backlog "$(backlog_record l1)"
printf 'R0\t도는중\t1\t%s\n' "$HCC" > "$TEST_PROBE_OUT"
fleet dispatch cc >/dev/null 2>&1
check "자기 레인에 도는 런이 있으면 절 lane" "$(backlog_field l1 .last_refusal_clause)" "lane"
printf 'R0\t도는중\t1\t%s\n' "$HCCI" > "$TEST_PROBE_OUT"
fleet dispatch cc >/dev/null 2>&1
check "다른 레인의 런은 이 레인을 막지 않는다 (통과해 기동)" "$(backlog_status l1)" "done"
fresh_pace d-lane2; write_state 가속 10 null null true; set_backlog "$(backlog_record l2)"
printf 'R0\t판정 불가\t?\t/nowhere\n' > "$TEST_PROBE_OUT"
fleet dispatch cc >/dev/null 2>&1
check "귀속 불가(unknown) 행은 모든 레인에 청구된다" "$(backlog_field l2 .last_refusal_clause)" "lane"
: > "$TEST_PROBE_OUT"
TEST_PROBE_RC=3 fleet dispatch cc >/dev/null 2>&1
check "프로브 열거 실패는 닫힌다 (절 lane)" "$(cut -f3 "$PACE/refusals.tsv" | sed -n '2p')" "lane"

# --- clause window -------------------------------------------------------------
fresh_pace d-window; write_state 유지 85 null null true; set_backlog "$(backlog_record w1)"
fleet dispatch cc >/dev/null 2>&1
check "세션 창 80% 이상이면 절 window" "$(backlog_field w1 .last_refusal_clause)" "window"

# --- clause burn ---------------------------------------------------------------
fresh_pace d-burn; write_state 유지 10 0.5 0.7 true; set_backlog "$(backlog_record u1)"
fleet dispatch cc >/dev/null 2>&1
check "용량 < 소진이고 후보가 없으면 절 burn" "$(backlog_field u1 .last_refusal_clause)" "burn"
fresh_pace d-burn2; write_state 유지 10 0.5 0.7 false; set_backlog "$(backlog_record u2)"
fleet dispatch cc >/dev/null 2>&1
check "후보가 있으면 burn 절은 열린다" "$(backlog_status u2)" "done"

# --- absent state is 유지 and admits -------------------------------------------
fresh_pace d-absent; set_backlog "$(backlog_record a1)"; clear_logs
fleet dispatch cc >/dev/null 2>&1
check "state.json 부재는 유지로 읽혀 기동한다" "$(backlog_status a1)" "done"
check "기동은 좌석 홈으로 gate.sh snapshot 을 한 번 부른다" "$(count_lines "$TEST_LOG_DIR/gate.log")" "1"
check "snapshot 은 매니페스트를 받고 좌석 홈을 CLAUDE_CONFIG_DIR 로 받는다" "$(sed -n '1p' "$TEST_LOG_DIR/gate.log")" "gate snapshot --manifest $MANIFEST CLAUDE_CONFIG_DIR=$HCC"
sleep 0.3
check "워처는 정확히 한 번 기동된다" "$(count_lines "$TEST_LOG_DIR/watch.log")" "1"
check "워처 인자는 autopilot 의 기동 줄과 같은 네 임계를 싣는다" "$(sed -n '1p' "$TEST_LOG_DIR/watch.log")" "watch --run-dir $WORK/xdg/cc-cmds/run/R1 --ledger $WT/docs/pipeline-run/R1.md --stall 1200 --interval 60 --after-stage 120 --run-open 300"
check "run.sh 는 앞단에서 좌석 홈으로 돈다" "$(sed -n '1p' "$TEST_LOG_DIR/run.log")" "run --manifest $MANIFEST CLAUDE_CONFIG_DIR=$HCC"
[ -s "$WT/docs/pipeline-run/R1.md" ] && ok "보고서 스텁이 없으면 만든다" || bad "보고서 스텁이 없으면 만든다" "absent"
[ -s "$WORK/xdg/cc-cmds/run/R1/watch.log" ] || [ -e "$WORK/xdg/cc-cmds/run/R1/watch.log" ] && ok "워처 로그는 런 디렉터리 아래로 리디렉션된다" || bad "워처 로그는 런 디렉터리 아래로 리디렉션된다" "absent"

# --- two lanes, one head: the claim is locked and the flip is a CAS -----------
#
# The two dispatch labels fire together, so both read the same `pending` head
# unless the claim is serialized. The probe stub sleeps inside the first lane's
# admission block while the second lane arrives; with the lock the second lane
# waits, then finds no `pending` head, and `run.sh` is invoked exactly once.
fresh_pace d-race; write_state 가속 10 null null true; set_backlog "$(backlog_record r1)"; clear_logs
: > "$TEST_PROBE_OUT"
TEST_PROBE_SLEEP=1 fleet dispatch cc >/dev/null 2>"$WORK/race-cc.err" &
race_pid=$!
sleep 0.2
fleet dispatch cci >/dev/null 2>"$WORK/race-cci.err"
wait "$race_pid" || true
check "같은 pending 을 두 레인이 동시에 집어도 run.sh 는 한 번만 돈다" "$(count_lines "$TEST_LOG_DIR/run.log")" "1"
check "기동한 쪽은 먼저 잠금을 잡은 레인이다" "$(sed -n '1p' "$TEST_LOG_DIR/run.log")" "run --manifest $MANIFEST CLAUDE_CONFIG_DIR=$HCC"
check "레코드는 하나이고 done 이다" "$(backlog_status r1 | tr '\n' ' ')" "done "
check "집은 레인이 레코드에 적힌다" "$(backlog_field r1 .dispatched_lane)" "cc"
check "집은 시각이 레코드에 적힌다" "$(backlog_field r1 .dispatched_at)" "$(iso "$NOW")"
check "둘째 레인은 pending 이 없다고 끝난다" "$(grep -c 'pending 레코드가 없다' "$WORK/race-cci.err" || true)" "1"
[ -d "$PACE/backlog.lock" ] && bad "잠금은 파견 뒤 풀려 있다" "backlog.lock 이 남아 있다" || ok "잠금은 파견 뒤 풀려 있다"
# A stale lock is a dead holder's: it is broken, not waited on.
fresh_pace d-stale-lock; write_state 가속 10 null null true; set_backlog "$(backlog_record k1)"; clear_logs
mkdir -p "$PACE/backlog.lock"; touch -t 202001010000 "$PACE/backlog.lock"
fleet dispatch cc >/dev/null 2>"$WORK/stale-lock.err"
check "묵은 backlog.lock 은 깨고 기동한다" "$(backlog_status k1)" "done"
check "깬 사실을 로그에 남긴다" "$(grep -c '죽은 소유자' "$WORK/stale-lock.err" || true)" "1"
# The flip after the run is a CAS too: a record rewritten under the driver's
# feet is not blindly overwritten, and the failed swap is logged.
fresh_pace d-steal; write_state 가속 10 null null true; set_backlog "$(backlog_record t1)"; clear_logs
TEST_RUN_STEAL=1 fleet dispatch cc >/dev/null 2>"$WORK/steal.err"
check "원본 줄이 사라진 done 재작성은 덮어쓰지 않는다" "$(backlog_status t1)" "stolen"
check "실패한 교환은 로그에 남는다" "$(grep -c 'done 재작성이 실패했다' "$WORK/steal.err" || true)" "1"

# --- five parks ----------------------------------------------------------------
fresh_pace d-park; write_state 가속 10 null null true
set_backlog "$(backlog_record p-manifest '.manifest_path = "/nonexistent/x.md"')"
fleet dispatch cc >/dev/null 2>&1
check "매니페스트 부재 → park manifest-missing" "$(backlog_field p-manifest '.status + " " + .park_reason')" "parked manifest-missing"
set_backlog "$(backlog_record p-clock ".authorized_at = \"$(iso $(( NOW - 60 )))\"")"
fleet dispatch cc >/dev/null 2>&1
check "인가가 인큐보다 늦으면 → park clock-incoherent" "$(backlog_field p-clock .park_reason)" "clock-incoherent"
set_backlog "$(backlog_record p-deadline ".deadline = \"$(iso $(( NOW - 60 )))\"")"
fleet dispatch cc >/dev/null 2>&1
check "마감이 지났으면 → park deadline-passed" "$(backlog_field p-deadline .park_reason)" "deadline-passed"
set_backlog "$(backlog_record p-doc '.doc_sha256 = "0000"')"
fleet dispatch cc >/dev/null 2>&1
check "설계 문서 해시가 다르면 → park doc-changed" "$(backlog_field p-doc .park_reason)" "doc-changed"
set_backlog "$(backlog_record p-base '.base_commit = "ffffffffffffffffffffffffffffffffffffffff"')"
fleet dispatch cc >/dev/null 2>&1
check "베이스가 HEAD 의 조상이 아니면 → park base-moved" "$(backlog_field p-base .park_reason)" "base-moved"
check "park 는 refusals.tsv 에 남지 않는다" "$(count_lines "$PACE/refusals.tsv")" "0"

# --- oversize record is skipped, never parked; oldest pending goes first ------
fresh_pace d-size; write_state 가속 10 null null true
PAD=$(head -c 5000 /dev/zero | tr '\0' 'x')
set_backlog "$(backlog_record big ".enqueued_at = \"$(iso $(( NOW - 9000 )))\" | .authorized_at = \"$(iso $(( NOW - 9500 )))\" | .pad = \"$PAD\"")" \
            "$(backlog_record newer)" \
            "$(backlog_record older ".enqueued_at = \"$(iso $(( NOW - 8000 )))\" | .authorized_at = \"$(iso $(( NOW - 8500 )))\"")"
fleet dispatch cc >/dev/null 2>&1
check "4 KiB 를 넘는 레코드는 건너뛴다 — parked 로 두지 않는다" "$(backlog_status big)" "pending"
check "가장 오래된 pending 이 먼저 간다" "$(backlog_status older)" "done"
check "나머지 pending 은 그대로다" "$(backlog_status newer)" "pending"
check "재작성은 다른 줄을 축자로 보존한다" "$(count_lines "$PACE/backlog.jsonl")" "3"

# --- the stale-state and foreign-schema readings ----------------------------------
fresh_pace d-stale; set_backlog "$(backlog_record s1)"
jq -cn --argjson now "$NOW" '{schema: "cc-pace-state v1", tick_seq: 1, computed_at_epoch: ($now - 181), verdict: "제동", seats: []}' > "$PACE/state.json"
fleet dispatch cc >/dev/null 2>&1
check "181초 낡은 제동 상태는 부재로 읽혀 기동한다" "$(backlog_status s1)" "done"
fresh_pace d-foreign; set_backlog "$(backlog_record f1)"
jq -cn --argjson now "$NOW" '{schema: "cc-pace-state v2", tick_seq: 1, computed_at_epoch: $now, verdict: "제동", seats: []}' > "$PACE/state.json"
fleet dispatch cc >/dev/null 2>&1
check "다른 스키마의 제동 상태는 부재로 읽혀 기동한다" "$(backlog_status f1)" "done"

# --- usage ----------------------------------------------------------------------
fresh_pace d-usage
fleet dispatch xx >/dev/null 2>&1; rc=$?
check "모르는 레인은 usage 오류(2)" "$rc" "2"
fleet >/dev/null 2>&1; rc=$?
check "부속 명령 없이 부르면 usage 오류(2)" "$rc" "2"

# ===========================================================================
# AGENT
# ===========================================================================
fresh_pace agent
: > "$TEST_LAUNCHD_STATE"; : > "$TEST_LAUNCHD_RUNNING"; : > "$TEST_LAUNCHD_LOG"; rm -rf "$WORK/agents"
fleet agent install >/dev/null 2>&1; rc=$?
check "install 은 성공한다" "$rc" "0"
check "세 레이블이 등록된다" "$(sort "$TEST_LAUNCHD_STATE" | tr '\n' ' ')" "com.nharu.cc-cmds.fleet.dispatch.cc com.nharu.cc-cmds.fleet.dispatch.cci com.nharu.cc-cmds.fleet.sensor "
check "세 plist 가 렌더된다" "$(ls "$WORK/agents" | wc -l | tr -d ' ')" "3"
SENSOR_PLIST="$WORK/agents/com.nharu.cc-cmds.fleet.sensor.plist"
DISP_PLIST="$WORK/agents/com.nharu.cc-cmds.fleet.dispatch.cc.plist"
check "센서 plist 의 StartInterval 은 fleet.sh 의 선언값이다" "$(sed -n '/<key>StartInterval<\/key>/{n;s/.*<integer>\(.*\)<\/integer>.*/\1/p;}' "$SENSOR_PLIST")" "55"
check "파견 plist 의 StartInterval 은 파견 선언값이다" "$(sed -n '/<key>StartInterval<\/key>/{n;s/.*<integer>\(.*\)<\/integer>.*/\1/p;}' "$DISP_PLIST")" "120"
check "센서 plist 에는 레인 줄이 없다" "$(grep -c -e '@LANE@' -e 'CLAUDE_CONFIG_DIR' "$SENSOR_PLIST" || true)" "0"
check "파견 plist 는 좌석 홈을 CLAUDE_CONFIG_DIR 로 싣는다" "$(grep -c "<string>$HCC</string>" "$DISP_PLIST" || true)" "1"
check "렌더된 plist 에 자리표시자가 남지 않는다" "$(cat "$WORK/agents"/*.plist | grep -c '@[A-Z_]*@' || true)" "0"
check "부재 키 셋은 렌더본에도 없다" "$(cat "$WORK/agents"/*.plist | grep -c -e '<key>KeepAlive</key>' -e '<key>AbandonProcessGroup</key>' -e '<key>ProcessType</key>' || true)" "0"
n_before=$(count_lines "$TEST_LAUNCHD_LOG")
fleet agent install >/dev/null 2>&1; rc=$?
check "install 은 멱등이다 (재실행 성공)" "$rc" "0"
check "재설치는 레이블마다 bootout 뒤 bootstrap 한다" "$(sed -n "$(( n_before + 1 )),\$p" "$TEST_LAUNCHD_LOG" | grep -c -e '^bootout' -e '^bootstrap' || true)" "6"
check "재설치 뒤에도 등록은 셋이다" "$(count_lines "$TEST_LAUNCHD_STATE")" "3"
# half-installed: one plist missing while all three are registered
rm -f "$DISP_PLIST"
fleet agent install >/dev/null 2>"$WORK/half.err"; rc=$?
check "반설치(plist 2/3, 등록 3/3)는 거부한다" "$rc" "1"
grep -q '반쯤 설치된' "$WORK/half.err" && ok "반설치 거부 문면은 uninstall 을 처방한다" || bad "반설치 거부 문면은 uninstall 을 처방한다" "$(cat "$WORK/half.err")"
# running dispatch label refuses install and uninstall
fleet agent uninstall >/dev/null 2>&1
fleet agent install >/dev/null 2>&1
printf 'com.nharu.cc-cmds.fleet.dispatch.cc\n' > "$TEST_LAUNCHD_RUNNING"
fleet agent install >/dev/null 2>&1; rc=$?
check "도는 중인 파견 레이블은 install 을 거부한다" "$rc" "1"
fleet agent uninstall >/dev/null 2>&1; rc=$?
check "도는 중인 파견 레이블은 uninstall 을 거부한다" "$rc" "1"
check "status 는 running 을 표시한다" "$(fleet agent status 2>/dev/null | grep -c 'dispatch.cc: 등록됨 (running)' || true)" "1"
: > "$TEST_LAUNCHD_RUNNING"
: > "$TEST_LAUNCHD_LOG"
fleet agent uninstall >/dev/null 2>&1; rc=$?
check "uninstall 은 성공한다" "$rc" "0"
check "uninstall 은 레이블마다 bootout 한다" "$(grep -c '^bootout' "$TEST_LAUNCHD_LOG" || true)" "3"
check "uninstall 뒤 등록이 없다" "$(count_lines "$TEST_LAUNCHD_STATE")" "0"
check "uninstall 뒤 plist 가 없다" "$(ls "$WORK/agents" 2>/dev/null | wc -l | tr -d ' ')" "0"
check "status 는 미등록과 하트비트 없음을 말한다" "$(fleet agent status 2>/dev/null | grep -c -e '미등록' -e '하트비트  : 없음' || true)" "4"
# files present but nothing registered is also half-installed
fleet agent install >/dev/null 2>&1
: > "$TEST_LAUNCHD_STATE"
fleet agent install >/dev/null 2>&1; rc=$?
check "plist 3/3 에 등록 0/3 도 반설치로 거부한다" "$rc" "1"

# ===========================================================================
# SOURCE GREPS
# ===========================================================================
check "fleet.sh 는 드라이버의 분리 실행 헬퍼를 부르지 않는다" "$(grep -c 'cc_detach_exec' "$ORCH/fleet.sh" || true)" "0"
check "fleet.sh 는 알림기를 부르지 않는다" "$(grep -c -i -e 'notify' -e 'terminal-notifier' "$ORCH/fleet.sh" || true)" "0"
check "fleet.sh 는 nohup 을 쓰지 않는다" "$(grep -c 'nohup' "$ORCH/fleet.sh" || true)" "0"
check "워처 기동 줄은 정확히 하나다" "$(grep -c 'watch\.sh" --run-dir' "$ORCH/fleet.sh" || true)" "1"
check "run.sh 는 앞단(&) 없이 불린다" "$(grep -c 'run\.sh" --manifest "\$manifest".*&$' "$ORCH/fleet.sh" || true)" "0"

printf '\ntest-fleet: %d passed, %d failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
