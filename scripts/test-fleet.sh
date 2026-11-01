#!/usr/bin/env bash
# lint-bash-portability: self-skip
# Test the pacing actor: `fleet.sh sensor`, `fleet.sh dispatch <id>` and
# `fleet.sh agent install|uninstall|status`.
#
# Everything the actor touches on a real host is stubbed on PATH, by env, or by
# the three directory seams HOME / XDG_CONFIG_HOME / XDG_STATE_HOME: `launchctl`
# and `plutil` are scripts under $WORK/bin, the lane probe is a script that
# prints a file and exits with a chosen code, the cc-lane inventory and usage
# file are written under the seams, the seat homes are `$WORK/home/.claude-<id>`,
# and `gate.sh` / `watch.sh` / `run.sh` are stubs beside a COPY of fleet.sh —
# the actor resolves its siblings from its own directory, so the copy is what
# lets the dispatch path run end to end without a driver. The router
# (`route.sh`) and the liveness predicates (`liveness.sh`) are copied for real:
# the fleet's eligibility and window judgement are the router's functions, and
# a stub would test the stub. `FLEET_NOW_EPOCH` fixes the clock so every usage
# row and every backlog timestamp is written relative to one instant.
#
# What is asserted, and why each is its own check:
#   sourcing                  — without route.sh nothing starts and the exit is
#                               non-zero
#   heartbeat before ladder   — a failing tick still leaves a fresh heartbeat
#   atomic publish, tick_seq  — no temp file survives, and the sequence climbs
#   record fields, exhaustive — state.json, seats[] and verdict-history carry
#                               exactly the documented keys
#   two token sets, unmixed   — a verdict never appears where a reason goes
#   seats and labels          — every inventory account is a seat; eligibility
#                               and its first reason, one per cause
#   allocation fields         — carried for a confirmed usage row, eligible or
#                               not; null for a mismatch and when the file is bad
#   capacity                  — one allowance per eligible group
#   burn scan                 — per home, eligible sum vs scanned sample, a
#                               truncated home, a v1 cache ignored
#   census join               — trailing `/`, placeholder rows, short rows
#   dispatch: id and eligibility, brake / lane / window / burn clauses with
#             their six-column refusal rows, the window input stage by stage,
#             run markers and the fleet ceiling (three heads, three lanes,
#             two started), lane mismatch, parks, launch shape, the claim race
#   agent: label set from the inventory, refused installs (violation, empty
#          set, orphan, half-installed, running), uninstall over the universe,
#          status with eligibility, orphans and live markers
#   master: the reading per (repository, base) — 진행 중 opens nothing, a
#           settled 빨강 opens one event whose id is the digest of its first
#           commit and signatures, 판정 불가 keeps the previous reading, a
#           settled 초록 resolves; logs read once per failure set; the skip;
#           one repair record per event; the repair state recomputed from the
#           record; the switch; a sticky render failure; the fix-PR hold and
#           its 7200 s; master.lock live, stale and dead
#   repair admission: its own seat beside the ceiling, the repair-seat,
#           window and switch refusals, an unrecognized record parked, the
#           observer child's launch while the lane's run goes on, the job's
#           wait, one run under a claim race, and the reading kept fresh
#   source greps              — no detach helper, no notifier, one watcher line,
#                               one run.sh / repair-run / master-watch launch,
#                               no write credential, none of the removed seat names
#
# Usage: bash scripts/test-fleet.sh

set -uo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
ORCH="$repo_root/plugins/cc-cmds/orchestrator"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/cc-fleet-test.XXXXXX")
BG_PIDS=""
trap 'for p in $BG_PIDS; do kill "$p" 2>/dev/null; done; rm -rf "$WORK"' EXIT

passed=0; failed=0
ok()   { passed=$((passed + 1)); printf 'PASS: %s\n' "$1"; }
bad()  { failed=$((failed + 1)); printf 'FAIL: %s — %s\n' "$1" "${2:-}" >&2; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got '$2', want '$3'"; fi; }
count_lines() { local n; n=$(grep -c '' "$1" 2>/dev/null || true); printf '%s' "${n:-0}"; }

# ---------------------------------------------------------------------------
# The fixture: a copy of fleet.sh with the real router and liveness beside it,
# stub siblings, stub tools, and seats under one fixture HOME.
# ---------------------------------------------------------------------------
FX="$WORK/orch"; mkdir -p "$FX" "$WORK/bin" "$WORK/xdg" "$WORK/cfg" "$WORK/agents"
cp "$ORCH/fleet.sh" "$ORCH/fleet-agent.plist.in" "$ORCH/route.sh" "$ORCH/liveness.sh" "$FX/"
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
cat > "$FX/checks.sh" <<'EOF'
#!/usr/bin/env bash
printf 'checks %s\n' "$*" >> "$TEST_LOG_DIR/checks.log"
exit 0
EOF
cat > "$FX/run.sh" <<'EOF'
#!/usr/bin/env bash
printf 'run %s CLAUDE_CONFIG_DIR=%s\n' "$*" "${CLAUDE_CONFIG_DIR:-}" >> "$TEST_LOG_DIR/run.log"
# A slow driver keeps the dispatch job — and its run marker — alive. A repair
# run (its manifest is an `rr-` one) sleeps TEST_REPAIR_RUN_SLEEP instead, so it
# can outlive the lane's own run.
case "$*" in
  */rr-*) [ -z "${TEST_REPAIR_RUN_SLEEP:-}" ] || sleep "$TEST_REPAIR_RUN_SLEEP" ;;
  *)      [ -z "${TEST_RUN_SLEEP:-}" ] || sleep "$TEST_RUN_SLEEP" ;;
esac
# With TEST_RUN_STEAL set the stub rewrites the dispatched record under the
# driver's feet, so the dispatcher's `done` flip finds no line to flip.
if [ -n "${TEST_RUN_STEAL:-}" ]; then
  sed 's/"dispatched"/"stolen"/' "$FLEET_PACE_ROOT/backlog.jsonl" > "$FLEET_PACE_ROOT/backlog.jsonl.new"
  mv -f "$FLEET_PACE_ROOT/backlog.jsonl.new" "$FLEET_PACE_ROOT/backlog.jsonl"
fi
exit 0
EOF
# The signature extractor is copied for real, so a reading's signatures are the
# ones the gate's match act would compute. The fixture repository is not
# cc-cmds, so the generic adapter names each failed step: `<check>|<step>`.
cp "$ORCH/ci-signature.sh" "$FX/"
# The repair renderer stub: the manifest the real one renders, cut to what the
# fleet reads — the run id, the origin worktree, the target row, the `수리 사건`
# row and the `(해당 없음)` design digest — and the key=value lines it prints.
# With TEST_REPAIR_FAIL set it fails with that line.
cat > "$FX/repair.sh" <<'EOF'
#!/usr/bin/env bash
printf 'repair %s\n' "$*" >> "$TEST_LOG_DIR/repair.log"
if [ -n "${TEST_REPAIR_FAIL:-}" ]; then printf 'repair: %s\n' "$TEST_REPAIR_FAIL" >&2; exit 1; fi
s=""; b=""; e=""; w=""
while [ $# -gt 0 ]; do
  case "$1" in --slug) s="$2"; shift ;; --base) b="$2"; shift ;; --event) e="$2"; shift ;; --worktree) w="$2"; shift ;; esac
  shift
done
mkdir -p "$TEST_REPAIR_DIR"
m="$TEST_REPAIR_DIR/rr-$e.plan.md"
at=$(jq -rn --argjson e "$TEST_NOW" '$e | todate'); dl=$(jq -rn --argjson e "$TEST_NOW" '$e + 21600 | todate')
{
  printf '<!-- cc-run-manifest v1; run-id=rr-%s; owner-doc=docs/master-repair-%s.md; origin-worktree=%s; -->\n\n' "$e" "$e" "$w"
  printf '**설계 문서 전체 sha256**: (해당 없음)\n\n'
  printf -- '- `target` | 별칭=repo | 메인 워크트리=%s | 베이스 브랜치=%s | 원격 슬러그=%s\n' "$w" "$b" "$s"
  printf -- '- `수리 사건` | %s | %s | %s | fp\n' "$s" "$b" "$e"
} > "$m"
printf 'manifest=%s\ngrant=%s/g.md\nrun_id=rr-%s\nrendered_at=%s\ndeadline=%s\ndoc_sha256=(해당 없음)\n' "$m" "$TEST_REPAIR_DIR" "$e" "$at" "$dl"
EOF
# The remote, from files under $TEST_GH: the tip, `runs.<sha>` (the check runs
# as the reader's --jq prints them), `steps.<job>`, `log.<job>`, `pulls` and
# `compare.<sha>`. Every call is logged; a path no file answers fails, and so
# does every call while `$TEST_GH/down` exists.
cat > "$WORK/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TEST_GH/calls"
[ ! -e "$TEST_GH/down" ] || exit 1
[ "${1:-}" = api ] || exit 1
shift
p=""; skip=""
for a in "$@"; do
  if [ -n "$skip" ]; then skip=""; continue; fi
  case "$a" in --jq) skip=1 ;; -*) ;; *) [ -n "$p" ] || p="$a" ;; esac
done
case "$p" in
  repos/*/commits/*/check-runs*) h=${p%/check-runs*}; f="$TEST_GH/runs.${h##*/}" ;;
  repos/*/commits/*) f="$TEST_GH/tip" ;;
  repos/*/actions/jobs/*/logs) j=${p%/logs}; f="$TEST_GH/log.${j##*/}" ;;
  repos/*/actions/jobs/*) f="$TEST_GH/steps.${p##*/}" ;;
  repos/*/pulls*) f="$TEST_GH/pulls" ;;
  repos/*/compare/*) f="$TEST_GH/compare.${p##*...}" ;;
  *) exit 1 ;;
esac
[ -r "$f" ] || exit 1
cat "$f"
EOF
# The lane probe stub: prints $TEST_PROBE_OUT, sleeps $TEST_PROBE_SLEEP first,
# exits with $TEST_PROBE_RC.
cat > "$WORK/bin/lane-probe.sh" <<'EOF'
#!/usr/bin/env bash
[ -n "${TEST_PROBE_SLEEP:-}" ] && sleep "$TEST_PROBE_SLEEP"
[ -r "${TEST_PROBE_OUT:-/nonexistent}" ] && cat "$TEST_PROBE_OUT"
exit "${TEST_PROBE_RC:-0}"
EOF
cat > "$WORK/bin/plutil" <<'EOF'
#!/usr/bin/env bash
case "$1" in -lint) exit 0 ;; esac
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

# The seats. `cc` is the interactive seat: disabled for unattended work and
# reserved, exactly as the inventory rule requires of a reserved account.
HOMEX="$WORK/home"
for i in cc u1 u2 u3; do mkdir -p "$HOMEX/.claude-$i/projects"; done
H_CC="$HOMEX/.claude-cc"; H1="$HOMEX/.claude-u1"; H2="$HOMEX/.claude-u2"; H3="$HOMEX/.claude-u3"
printf '{"oauthAccount":{"profileFetchedAt":"2026-09-19T00:00:00Z"}}\n' > "$H1/.claude.json"
INV="$WORK/cfg/cc-lane/accounts.json"
USAGE="$WORK/xdg/cc-lane/usage.json"
BORROW="$WORK/xdg/cc-lane/borrow.json"

NOW=$(date -u +%s)
iso() { jq -rn --argjson e "$1" '$e | todate'; }

export TEST_LOG_DIR="$WORK/logs"; mkdir -p "$TEST_LOG_DIR"
export TEST_LAUNCHD_LOG="$WORK/launchctl.log" TEST_LAUNCHD_STATE="$WORK/launchd.state" TEST_LAUNCHD_RUNNING="$WORK/launchd.running"
export TEST_PROBE_OUT="$WORK/probe.out" TEST_PROBE_RC=0 TEST_PROBE_SLEEP=""
: > "$WORK/probe.out"
export TEST_GH="$WORK/gh" TEST_REPAIR_DIR="$WORK/repair" TEST_NOW="$NOW"
mkdir -p "$TEST_GH"

inv_write() {
  # inv_write [<jq-filter>] — cc (reserved), u1, u2 enabled; the filter edits it.
  mkdir -p "$(dirname "$INV")"
  jq -n --arg h "$HOMEX" '
    def a($id; $u; $r): {id: $id, config_dir: ($h + "/.claude-" + $id), unattended: $u, interactive_reserved: $r};
    {schema: "cc-lane-accounts v1",
     accounts: [a("cc"; "disabled"; true), a("u1"; "enabled"; false), a("u2"; "enabled"; false)]}'"${1:+ | $1}" > "$INV"
}
acct_add_u3() { printf '.accounts += [{id: "u3", config_dir: ($h + "/.claude-u3"), unattended: "enabled", interactive_reserved: false}]'; }
usage_write() {
  # usage_write [<jq-filter>] — a fresh tracker row per account, each its own
  # org: 5h at 10% resetting in 2h, 7d at 50% resetting in 24h.
  mkdir -p "$(dirname "$USAGE")"
  jq -n --argjson now "$NOW" --arg h "$HOMEX" '
    def win($u; $r): {utilization: $u, resets_at_epoch: ($now + $r), observed_at_epoch: ($now - 10), source: "tracker"};
    def acct($id): {id: $id, config_dir: ($h + "/.claude-" + $id), org_hash: ("org-" + $id), login: "ok", status: "ok",
                    windows: {five_hour: win(0.10; 7200), seven_day: win(0.50; 86400)}};
    {schema: "cc-lane-usage v1", written_at_epoch: ($now - 10), publish_interval_s: 60,
     accounts: [acct("cc"), acct("u1"), acct("u2")]}'"${1:+ | $1}" > "$USAGE"
}
usage_u3() { printf '.accounts += [.accounts[1] | .id = "u3" | .config_dir = ($h + "/.claude-u3") | .org_hash = "org-u3"]'; }
usage_gone() { rm -f "$USAGE"; }

fresh_pace() {
  # A new pace root per scenario: burn.cache, markers and the streak file must
  # not leak. The inventory and usage file go back to their defaults.
  PACE="$WORK/pace-$1"; rm -rf "$PACE"; mkdir -p "$PACE"
  inv_write; usage_write; rm -f "$BORROW"
  : > "$TEST_PROBE_OUT"
}
fleet() {
  # fleet <args...> — the actor under the fixture's environment. The remote is
  # always the stub; FLEET_NOW_PIN set and empty runs on the real clock.
  FLEET_PACE_ROOT="$PACE" FLEET_PLUTIL="$WORK/bin/plutil" FLEET_LAUNCHCTL="$WORK/bin/launchctl" \
  FLEET_LAUNCH_AGENTS_DIR="$WORK/agents" FLEET_LANE_PROBE="$WORK/bin/lane-probe.sh" FLEET_NOW_EPOCH="${FLEET_NOW_PIN-$NOW}" \
  FLEET_GH="$WORK/bin/gh" \
  HOME="$HOMEX" XDG_CONFIG_HOME="$WORK/cfg" XDG_STATE_HOME="$WORK/xdg" \
  bash "${FLEET_UNDER_TEST:-$FLEET}" "$@"
}
burn_heavy() {
  # burn_heavy [<home>] [<output-tokens>] — one transcript under <home> ten
  # minutes ago. The default 5M output tokens: 25 Mwt x 0.104 / 4 = 0.65 %p/h,
  # above one seat's 100/168 = 0.595 cap.
  local h="${1:-$H1}" n="${2:-5000000}" t; t=$(iso $(( NOW - 600 )))
  mkdir -p "$h/projects/p"
  printf '{"timestamp":"%s","message":{"usage":{"input_tokens":0,"output_tokens":%s}}}\n' "$t" "$n" > "$h/projects/p/s.jsonl"
}
burn_none() { rm -rf "$H_CC/projects/p" "$H1/projects/p" "$H2/projects/p" "$H3/projects/p"; }
state_field() { jq -r "$1" "$PACE/state.json"; }
seat() { jq -r --arg i "$1" ".seats[] | select(.id == \$i) | $2" "$PACE/state.json"; }
fp_of() { { TZ=UTC0 LC_ALL=C ps -o lstart= -p "$1" 2>/dev/null || true; } | sed 's/[[:space:]]\{1,\}/ /g;s/^ //;s/ $//'; }

# ===========================================================================
# SOURCING
# ===========================================================================
fresh_pace src
NR="$WORK/orch-noroute"; mkdir -p "$NR"
cp "$FX/fleet.sh" "$FX/fleet-agent.plist.in" "$FX/liveness.sh" "$FX/gate.sh" "$FX/watch.sh" "$FX/run.sh" "$NR/"
printf '%s\n' "$(jq -cn --arg m "$WORK/none.md" '{schema:"cc-pace-backlog v1",id:"n1",status:"pending",manifest_path:$m}')" > "$PACE/backlog.jsonl"
rm -f "$TEST_LOG_DIR"/*.log
FLEET_UNDER_TEST="$NR/fleet.sh" fleet dispatch u1 >/dev/null 2>"$WORK/noroute.err"; rc=$?
[ "$rc" != "0" ] && ok "route.sh 가 없는 설치본의 dispatch 는 0 이 아닌 코드로 끝난다" || bad "route.sh 가 없는 설치본" "rc=$rc"
check "그리고 아무것도 띄우지 않는다" "$(count_lines "$TEST_LOG_DIR/run.log")" "0"
check "레코드는 그대로다" "$(jq -r .status "$PACE/backlog.jsonl")" "pending"

# ===========================================================================
# SENSOR
# ===========================================================================

# --- heartbeat before the ladder --------------------------------------------
fresh_pace hb
usage_gone; burn_none
mkdir -p "$PACE/verdict-history.jsonl"   # the history append fails; the tick fails after publishing
fleet sensor >/dev/null 2>&1; rc=$?
[ "$rc" != "0" ] && ok "실패하는 틱은 0이 아닌 코드로 끝난다" || bad "실패하는 틱은 0이 아닌 코드로 끝난다" "rc=$rc"
check "실패하는 틱에서도 하트비트는 먼저 쓰인다" "$(sed -n '1p' "$PACE/sensor.heartbeat" 2>/dev/null)" "$(iso "$NOW")"

# --- atomic publish and tick_seq --------------------------------------------
fresh_pace seq; usage_gone
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
check "seats[] 의 키 집합은 정확히 아홉이다" "$(jq -r '.seats[0] | keys_unsorted | join(",")' "$PACE/state.json")" "id,home,org,eligible,reason,allow,session_pct,ttr,burn_4h"
check "인벤토리의 모든 계정이 좌석이다 (예약 계정 포함, 인벤토리 순서)" "$(jq -r '[.seats[].id] | join(",")' "$PACE/state.json")" "cc,u1,u2"
check "좌석 home 은 인벤토리 config_dir 글자 그대로다" "$(seat u1 .home)" "$H1"
want_hist='schema,tick_seq,observed_at,verdict,prev_verdict,reason,seat_allowance,burn_4h,candidates_empty'
check "verdict-history 레코드의 키 집합은 정확히 아홉이다" "$(sed -n '1p' "$PACE/verdict-history.jsonl" | jq -r 'keys_unsorted | join(",")')" "$want_hist"
check "첫 레코드의 prev_verdict 는 null 이다" "$(sed -n '1p' "$PACE/verdict-history.jsonl" | jq -r '.prev_verdict')" "null"
check "판정이 같으면 둘째 틱은 레코드를 더하지 않는다" "$(count_lines "$PACE/verdict-history.jsonl")" "1"

# --- two token sets, never mixed ----------------------------------------------
tokens_ok() {
  jq -e '(.verdict | IN("가속","유지","제동")) and (.verdict_reason | IN("brake","idle","lanes-below-target","default","tracker-skip","truncated"))' "$1" >/dev/null 2>&1
}
tokens_ok "$PACE/state.json" && ok "판정과 사유가 각자의 토큰 집합에서 온다" || bad "판정과 사유가 각자의 토큰 집합에서 온다" "$(jq -c '{verdict,verdict_reason}' "$PACE/state.json")"
printf '{"verdict":"idle","verdict_reason":"가속"}\n' > "$WORK/cross.json"
tokens_ok "$WORK/cross.json" && bad "교차 픽스처는 토큰 검사에 걸린다" "passed" || ok "교차 픽스처는 토큰 검사에 걸린다"
check "센서스가 없고 소모 기록이 없으면 유휴 판정은 가속(idle)이다" "$(state_field '.verdict + " " + .verdict_reason')" "가속 idle"
check "usage.json 부재는 tracker=unavailable 로 발행된다" "$(state_field .tracker)" "unavailable"
check "usage.json 부재면 할당 필드는 null 이다" "$(seat u1 '[.allow, .session_pct, .ttr] | map(tostring) | join(",")')" "null,null,null"

# --- schema mismatch is absence ----------------------------------------------
fresh_pace schema
printf '{"schema":"cc-pace-state v2","tick_seq":99,"verdict":"제동","computed_at_epoch":%s}\n' "$NOW" > "$PACE/state.json"
fleet sensor >/dev/null 2>&1
check "다른 스키마의 state.json 은 부재로 읽혀 tick_seq 가 1 부터 간다" "$(state_field .tick_seq)" "1"

# --- the tracker key from the file-level judgement --------------------------
fresh_pace trk
fleet sensor >/dev/null 2>&1
check "신선한 usage.json 은 tracker=ok" "$(state_field .tracker)" "ok"
usage_write '.written_at_epoch = ($now - 181)'
fleet sensor >/dev/null 2>&1
check "3 x 발행 간격을 넘긴 usage.json 은 unavailable" "$(state_field .tracker)" "unavailable"
check "tracker 가 ok 가 아니면 사다리 사유는 tracker-skip 이거나 가속이다" \
  "$(state_field '.verdict_reason | IN("tracker-skip","idle","lanes-below-target")')" "true"
usage_write '.publish_interval_s = 301'
fleet sensor >/dev/null 2>&1
check "발행 간격이 300 을 넘으면 parse-error" "$(state_field .tracker)" "parse-error"
printf '{not json\n' > "$USAGE"
fleet sensor >/dev/null 2>&1
check "파싱되지 않는 usage.json 은 parse-error" "$(state_field .tracker)" "parse-error"
usage_write '.schema = "cc-lane-usage v9"'
fleet sensor >/dev/null 2>&1
check "다른 스키마의 usage.json 은 parse-error" "$(state_field .tracker)" "parse-error"
usage_write '.written_at_epoch = ($now + 120)'
fleet sensor >/dev/null 2>&1
check "60초 넘게 미래인 발행 시각은 unavailable (낡음과 같은 쪽)" "$(state_field .tracker)" "unavailable"

# --- degraded publish: the probe past the budget ------------------------------
fresh_pace overrun
TEST_PROBE_SLEEP=7 fleet sensor >/dev/null 2>&1
check "예산을 넘긴 센서스는 tick_overrun=true 로 발행된다" "$(state_field .tick_overrun)" "true"
check "예산을 넘긴 틱은 lanes=unavailable 이고 나머지는 발행된다" "$(state_field '.lanes + " " + .schema')" "unavailable cc-pace-state v1"

# --- truncated: one record per streak -----------------------------------------
fresh_pace streak
TEST_PROBE_RC=3 fleet sensor >/dev/null 2>&1
TEST_PROBE_RC=3 fleet sensor >/dev/null 2>&1
check "열거 실패 두 틱까지는 truncated 레코드가 없다" "$(grep -c '"reason":"truncated"' "$PACE/verdict-history.jsonl" || true)" "0"
TEST_PROBE_RC=3 fleet sensor >/dev/null 2>&1
TEST_PROBE_RC=3 fleet sensor >/dev/null 2>&1
check "세 틱 연속 열거 실패는 truncated 레코드를 정확히 하나 남긴다" "$(grep -c '"reason":"truncated"' "$PACE/verdict-history.jsonl" || true)" "1"
check "probe exit 3 은 tick_overrun 이 아니다" "$(state_field .tick_overrun)" "false"
check "lanes-streak 파일은 시작 틱과 기록 여부를 든다" "$(cat "$PACE/lanes-streak")" "1 1"
TEST_PROBE_RC=0 fleet sensor >/dev/null 2>&1
[ ! -e "$PACE/lanes-streak" ] && ok "센서스가 돌아오면 streak 파일이 지워진다" || bad "센서스가 돌아오면 streak 파일이 지워진다" "still there"

# --- seats: eligibility and its first reason ---------------------------------
fresh_pace seats
mkdir -p "$HOMEX/.claude-gone"; rmdir "$HOMEX/.claude-gone"
inv_write '.accounts += [
  {id: "dr", config_dir: ($h + "/.claude-dr"), unattended: "draining", interactive_reserved: false},
  {id: "nod", config_dir: ($h + "/.claude-gone"), unattended: "enabled", interactive_reserved: false},
  {id: "grp", config_dir: ($h + "/.claude-grp"), unattended: "enabled", interactive_reserved: false},
  {id: "mis", config_dir: ($h + "/.claude-mis"), unattended: "enabled", interactive_reserved: false},
  {id: "lg", config_dir: ($h + "/.claude-lg"), unattended: "enabled", interactive_reserved: false},
  {id: "ex", config_dir: ($h + "/.claude-ex"), unattended: "enabled", interactive_reserved: false},
  {id: "bor", config_dir: ($h + "/.claude-bor"), unattended: "enabled", interactive_reserved: false},
  {id: "Up", config_dir: ($h + "/.claude-up"), unattended: "enabled", interactive_reserved: false}]'
for i in dr grp mis lg ex bor up; do mkdir -p "$HOMEX/.claude-$i"; done
usage_write '.accounts += [
  (.accounts[1] | .id = "grp" | .config_dir = ($h + "/.claude-grp") | .org_hash = "org-cc"),
  (.accounts[1] | .id = "mis" | .config_dir = ($h + "/.claude-elsewhere") | .org_hash = "org-mis"),
  (.accounts[1] | .id = "lg" | .config_dir = ($h + "/.claude-lg") | .org_hash = "org-lg" | .login = "expired"),
  (.accounts[1] | .id = "ex" | .config_dir = ($h + "/.claude-ex") | .org_hash = "org-ex" | .windows.seven_day.utilization = 1.0),
  (.accounts[1] | .id = "bor" | .config_dir = ($h + "/.claude-bor") | .org_hash = "org-bor")]'
mkdir -p "$(dirname "$BORROW")"
jq -n --arg h "$HOMEX" '{schema: "cc-lane-borrow v1", state: "borrowed", lane_config_dir: ($h + "/.claude-lane"),
                          donor: {id: "bor", config_dir: ($h + "/.claude-bor")}}' > "$BORROW"
fleet sensor >/dev/null 2>&1
check "적격 계정은 eligible=true, reason=null" "$(seat u1 '"\(.eligible) \(.reason)"')" "true null"
check "대화형 예약 계정은 not-labelled" "$(seat cc .reason)" "not-labelled"
check "id 형식이 틀린 계정은 not-labelled" "$(seat Up .reason)" "not-labelled"
check "draining 계정은 not-enabled" "$(seat dr .reason)" "not-enabled"
check "config_dir 이 없는 계정은 no-config-dir" "$(seat nod .reason)" "no-config-dir"
check "예약 계정과 같은 조직이면 group-reserved" "$(seat grp .reason)" "group-reserved"
check "사용량 행의 config_dir 이 다르면 mismatch" "$(seat mis .reason)" "mismatch"
check "로그인이 ok 가 아니면 login" "$(seat lg .reason)" "login"
check "차용 기증 계정은 borrowed" "$(seat bor .reason)" "borrowed"
check "창이 소진된 계정은 exhausted" "$(seat ex .reason)" "exhausted"
check "할당 필드는 부적격이어도 확인된 행이면 싣는다 (예약 계정)" "$(seat cc '.allow | . * 1000 | floor')" "595"
check "mismatch 좌석의 할당 필드는 null 이다" "$(seat mis '[.allow, .session_pct] | map(tostring) | join(",")')" "null,null"
check "login 좌석의 할당 필드는 null 이다" "$(seat lg '.allow | tostring')" "null"
check "조직은 usage.json 의 org_hash 다" "$(seat u1 .org)" "org-u1"
check "session_pct 는 5h 의 bp/100 이다" "$(seat u1 .session_pct)" "10"
check "좌석 허용치는 min(rem/ttr, 100/168) 이다" "$(seat u1 '.allow | . * 1000 | floor')" "595"
check "ttr 은 7d 리셋까지의 시간이다" "$(seat u1 .ttr)" "24"
rm -f "$BORROW"

# --- capacity: one allowance per eligible group -------------------------------
fresh_pace cap
fleet sensor >/dev/null 2>&1
check "조직이 다른 적격 계정 둘은 허용치 둘을 더한다" "$(state_field '.fleet_capacity | . * 1000 | floor')" "1190"
usage_write '.accounts[2].org_hash = "org-u1"'
fleet sensor >/dev/null 2>&1
check "같은 조직의 두 계정은 용량에 한 번만 더해진다" "$(state_field '.fleet_capacity | . * 1000 | floor')" "595"
usage_write '.accounts[2].windows.seven_day.resets_at_epoch = ($now - 5)'
fleet sensor >/dev/null 2>&1
check "주간 리셋이 지난 계정은 100/168 이고 ttr 은 null" "$(seat u2 '"\(.allow * 1000 | floor) \(.ttr)"')" "595 null"
usage_write '.written_at_epoch = ($now - 400)'
fleet sensor >/dev/null 2>&1
check "usage.json 이 낡으면 용량은 null 이다" "$(state_field .fleet_capacity)" "null"

# --- the ladder: brake on the eligible burn ----------------------------------
#   u1's week is 99% used with 24h left: allow = 1/24 = 0.0417 %p/h. One
#   transcript of 1M output tokens: 5 Mwt x 0.104 / 4 = 0.13 %p/h. A
#   candidate needs an allowance of at least the per-stage burn (0.13), which a
#   fresh account's 100/168 clears.
fresh_pace ladder
inv_write '.accounts[2].unattended = "draining"'
LADDER_USAGE='.accounts[1].windows.seven_day.utilization = 0.99'
usage_write "$LADDER_USAGE"
burn_heavy "$H1" 1000000
fleet sensor >/dev/null 2>&1
check "용량 < 소진이고 후보가 없으면 제동(brake)" "$(state_field '.verdict + " " + .verdict_reason')" "제동 brake"
check "후보 목록은 비어 있다" "$(state_field .candidates_empty)" "true"
check "seat_allowance 는 홈을 키로 하는 객체다" "$(sed -n '1p' "$PACE/verdict-history.jsonl" | jq -r --arg h "$H1" '.seat_allowance[$h] | . * 1000 | floor')" "41"
usage_write "$(usage_u3) | $LADDER_USAGE"
rm -f "$PACE/burn.cache"
fleet sensor >/dev/null 2>&1
check "인벤토리 밖 사용량 행은 재배치 후보다 — 후보가 있으면 유지" "$(state_field '.verdict + " " + (.candidates_empty | tostring)')" "유지 false"
burn_none
usage_write
rm -f "$PACE/burn.cache"
fleet sensor >/dev/null 2>&1
check "소진이 사라지면 판정이 바뀌고 이력이 는다" "$(count_lines "$PACE/verdict-history.jsonl")" "3"
check "둘째 레코드의 prev_verdict 는 직전 판정이다" "$(sed -n '2p' "$PACE/verdict-history.jsonl" | jq -r '.prev_verdict')" "제동"
check "seat-bindings 는 좌석당 한 레코드로 시작한다" "$(jq -r .home "$PACE/seat-bindings.jsonl" | sort -u | count_lines /dev/stdin)" "3"
check "seat-bindings 레코드는 정확히 아홉 필드다" "$(sed -n '1p' "$PACE/seat-bindings.jsonl" | jq -r 'keys_unsorted | join(",")')" "observed_at,prev_observed_at,login_at,home,org_prev,org,label,via_cc_swap,slept"
check "seat-bindings 의 label 은 인벤토리 id, org 는 org_hash 다" "$(jq -r --arg h "$H1" 'select(.home == $h) | "\(.label) \(.org) \(.login_at)"' "$PACE/seat-bindings.jsonl" | sed -n '1p')" "u1 org-u1 2026-09-19T00:00:00Z"
[ -s "$PACE/night-summary.md" ] && ok "야간 요약이 쓰인다" || bad "야간 요약이 쓰인다" "absent"

# --- burn scan: per home ------------------------------------------------------
fresh_pace burn
inv_write '.accounts[2].unattended = "draining"'
burn_heavy "$H1"; burn_heavy "$H2"; burn_heavy "$H_CC"
fleet sensor >/dev/null 2>&1
check "최상위 burn_4h 는 적격 홈의 합이다 (draining 은 빠진다)" "$(state_field '.burn_4h * 100 | round')" "65"
check "단계당 소모는 스캔한 모든 홈의 표본이다 (enabled + draining)" "$(state_field '.burn_per_stage_4h * 100 | round')" "130"
check "좌석의 burn_4h 는 그 홈의 값이다" "$(seat u2 '.burn_4h * 100 | round')" "65"
check "예약 계정의 홈은 스캔하지 않는다 (null)" "$(seat cc '.burn_4h | tostring')" "null"
check "burn.cache 는 v2 이고 홈마다 값을 든다" "$(jq -r '"\(.schema) \(.homes | keys | length)"' "$PACE/burn.cache")" "cc-pace-burn v2 2"
burn_none
printf '{"schema":"cc-pace-burn v1","computed_at_epoch":%s,"burn_4h":99,"live_4h_avg":1,"last_usage_epoch":%s,"truncated":false}\n' "$NOW" "$NOW" > "$PACE/burn.cache"
fleet sensor >/dev/null 2>&1
check "v1 burn.cache 는 새 의미로 읽히지 않는다 (다시 스캔)" "$(state_field '.burn_4h')" "0"
i=0; mkdir -p "$H2/projects/many"
while [ "$i" -le 1000 ]; do : > "$H2/projects/many/f$i.jsonl"; i=$(( i + 1 )); done
inv_write
rm -f "$PACE/burn.cache"
fleet sensor >/dev/null 2>&1
check "파일 상한을 넘긴 홈은 그 홈만 잘린다 — 좌석 burn_4h 는 null" "$(seat u2 '.burn_4h | tostring')" "null"
check "잘리지 않은 홈의 좌석 값은 남는다" "$(seat u1 '.burn_4h | tostring')" "0"
check "잘린 홈이 있으면 burn_truncated" "$(state_field .burn_truncated)" "true"
rm -rf "$H2/projects/many"

# --- census join ---------------------------------------------------------------
fresh_pace census
TAB=$(printf '\t')
printf 'R1\t도는중\t1\t%s/\nR2\t아님\t0\t%s\nR3\t도는중\t1\t(미상)\nR4\t판정 불가\t?\n(비정규 이름)\t판정 불가\t?\t(미기록)\nR6\t도는중\t1\t%s\n' \
  "$H1" "$H2" "$H_CC" > "$TEST_PROBE_OUT"
fleet sensor >/dev/null 2>&1
check "끝 / 하나는 떼고 인벤토리 config_dir 과 맞춘다" "$(state_field '.lane_census[] | select(.run_id == "R1") | .lane')" "u1"
check "자리표시 레인은 unknown 이다" "$(state_field '.lane_census[] | select(.run_id == "R3") | .lane')" "unknown"
check "네 필드가 아닌 행은 버리지 않고 unknown/판정 불가 한 건이다" "$(state_field '[.lane_census[] | select(.run_id == null)] | map("\(.lane) \(.status)") | join(",")')" "unknown 판정 불가"
check "(비정규 이름) 행은 버린다" "$(state_field '.lane_census | length')" "5"
check "예약 계정 홈의 런은 그 계정에 귀속된다" "$(state_field '.lane_census[] | select(.run_id == "R6") | .lane')" "cc"
: > "$TEST_PROBE_OUT"

# ===========================================================================
# DISPATCH
# ===========================================================================
WT="$WORK/wt"; mkdir -p "$WT/docs"
( cd "$WT" && git init -q && git config user.email t@t && git config user.name t \
  && printf 'design\n' > docs/x.md && git add . && git commit -qm init ) >/dev/null 2>&1
BASE=$(cd "$WT" && git rev-parse HEAD)
# The report stub lands in the main worktree, named by the absolute git common
# dir — on this host that resolves the /var → /private/var symlink.
WT_MAIN=$(dirname "$(cd "$WT" && git rev-parse --path-format=absolute --git-common-dir)")
DOC_SHA=$(shasum -a 256 "$WT/docs/x.md" | cut -d' ' -f1)
MANIFEST="$WORK/R1.plan.md"
printf '<!-- cc-run-manifest v1; run-id=R1; owner-doc=docs/x.md; origin-worktree=%s; -->\n\n**설계 문서 전체 sha256**: %s\n' "$WT" "$DOC_SHA" > "$MANIFEST"
RUNDIR="$WORK/xdg/cc-cmds/run/R1"

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
  # write_state <verdict> <capacity|null> <burn|null> <candidates_empty>
  jq -cn --argjson now "$NOW" --arg v "$1" --argjson cap "$2" --argjson b "$3" --argjson ce "$4" '
    {schema: "cc-pace-state v1", tick_seq: 7, computed_at: ($now | todate), computed_at_epoch: $now,
     verdict: $v, fleet_capacity: $cap, burn_4h: $b, candidates_empty: $ce, seats: []}' > "$PACE/state.json"
}
backlog_status() { jq -r --arg id "$1" 'select(.id == $id) | .status' "$PACE/backlog.jsonl"; }
backlog_field() { jq -r --arg id "$1" "select(.id == \$id) | $2" "$PACE/backlog.jsonl"; }
clear_logs() { rm -f "$TEST_LOG_DIR"/*.log; }
d_fresh() {
  # d_fresh <name> — a dispatch scenario: fresh pace, an admitting state, one
  # pending head, no run directory left from the last scenario.
  fresh_pace "$1"; write_state 가속 null null true; set_backlog "$(backlog_record "$2")"; clear_logs
  rm -rf "$RUNDIR"
}

# --- id format and eligibility -------------------------------------------------
d_fresh d-id i1
fleet dispatch X.Y >/dev/null 2>&1; rc=$?
check "id 형식이 아닌 레인은 usage 오류(2)" "$rc" "2"
fleet dispatch xx >/dev/null 2>"$WORK/xx.err"; rc=$?
check "인벤토리에 없는 형식 맞는 id 는 not-labelled 로 0" "$rc" "0"
check "부적격은 로그 한 줄이다" "$(grep -c '부적격 — not-labelled' "$WORK/xx.err" || true)" "1"
fleet dispatch cc >/dev/null 2>"$WORK/cc.err"
check "대화형 예약 계정은 not-labelled" "$(grep -c '부적격 — not-labelled' "$WORK/cc.err" || true)" "1"
check "부적격은 거부 행을 남기지 않는다" "$(count_lines "$PACE/refusals.tsv")" "0"
check "부적격은 레코드를 건드리지 않는다" "$(backlog_status i1)" "pending"
inv_write '.accounts[1].unattended = "draining"'
fleet dispatch u1 >/dev/null 2>"$WORK/dr.err"
check "draining 계정은 not-enabled" "$(grep -c '부적격 — not-enabled' "$WORK/dr.err" || true)" "1"
rm -f "$INV"
fleet dispatch u1 >/dev/null 2>"$WORK/noinv.err"; rc=$?
check "인벤토리 부재는 inventory-broken 이고 0 으로 끝난다" "$rc $(grep -c '부적격 — inventory-broken' "$WORK/noinv.err" || true)" "0 1"
inv_write '.accounts[1].config_dir += "/"'
fleet dispatch u1 >/dev/null 2>"$WORK/badinv.err"
check "깨진 인벤토리(끝 /)도 inventory-broken" "$(grep -c '부적격 — inventory-broken' "$WORK/badinv.err" || true)" "1"
check "어느 경우도 아무것도 띄우지 않는다" "$(count_lines "$TEST_LOG_DIR/run.log")" "0"

# --- clause brake ------------------------------------------------------------
d_fresh d-brake b1; write_state 제동 null null true
fleet dispatch u1 >/dev/null 2>&1
check "제동 판정은 절 brake 로 거부한다" "$(backlog_field b1 .last_refusal_clause)" "brake"
check "거부는 레코드를 pending 으로 둔다" "$(backlog_status b1)" "pending"
check "거부 행은 여섯 열이다" "$(awk -F'\t' '{print NF}' "$PACE/refusals.tsv")" "6"
check "거부 행: 레인·절·판정·id·세부" "$(cut -f2-6 "$PACE/refusals.tsv")" "$(printf 'u1\tbrake\t제동\tb1\t-')"

# --- clause lane: the probe ------------------------------------------------------
d_fresh d-lane l1
printf 'R0\t도는중\t1\t%s\n' "$H1" > "$TEST_PROBE_OUT"
fleet dispatch u1 >/dev/null 2>&1
check "자기 레인에 도는 런이 있으면 lane/occupied" "$(cut -f3,6 "$PACE/refusals.tsv")" "$(printf 'lane\toccupied')"
printf 'R0\t도는중\t1\t%s\n' "$H2" > "$TEST_PROBE_OUT"
fleet dispatch u1 >/dev/null 2>&1
check "다른 레인의 런은 이 레인을 막지 않는다 (통과해 기동)" "$(backlog_status l1)" "done"
d_fresh d-lane2 l2
printf 'R0\t판정 불가\t?\t/nowhere\n' > "$TEST_PROBE_OUT"
fleet dispatch u1 >/dev/null 2>&1
check "귀속 불가(unknown) 행은 모든 레인에 청구된다" "$(cut -f3,6 "$PACE/refusals.tsv")" "$(printf 'lane\toccupied')"
printf 'R0\t도는중\t1\t%s\n' "$H_CC" > "$TEST_PROBE_OUT"
fleet dispatch u1 >/dev/null 2>&1
check "대화형 예약 계정에 귀속된 런은 레인을 점유하지 않는다" "$(backlog_status l2)" "done"
d_fresh d-lane3 l3
TEST_PROBE_RC=3 fleet dispatch u1 >/dev/null 2>&1
check "프로브 열거 실패는 닫힌다 (lane/probe-failed)" "$(cut -f3,6 "$PACE/refusals.tsv")" "$(printf 'lane\tprobe-failed')"

# --- run markers and the fleet ceiling ---------------------------------------------
d_fresh d-mark m1
sleep 30 & MP=$!; BG_PIDS="$BG_PIDS $MP"
mkdir -p "$PACE/busy"
printf '%s\n%s\n%s\n' "$MP" "$(fp_of "$MP")" "RX" > "$PACE/busy/u1.$MP"
fleet dispatch u1 >/dev/null 2>&1
check "같은 레인의 살아 있는 표지는 lane/occupied" "$(cut -f3,6 "$PACE/refusals.tsv")" "$(printf 'lane\toccupied')"
mv "$PACE/busy/u1.$MP" "$PACE/busy/u2.$MP"
printf '999999\nMon Jan 1 00:00:00 2001\nRDEAD\n' > "$PACE/busy/u2.999999"
fleet dispatch u1 >/dev/null 2>&1
check "다른 레인의 표지 하나는 상한(2) 아래라 기동한다" "$(backlog_status m1)" "done"
[ ! -e "$PACE/busy/u2.999999" ] && ok "죽은 표지는 잠금 안에서 지워진다" || bad "죽은 표지는 잠금 안에서 지워진다" "still there"
check "자기 표지는 파견이 끝나면 지워진다" "$(ls "$PACE/busy" | tr '\n' ' ')" "u2.$MP "
d_fresh d-ceil c1
mkdir -p "$PACE/busy"
printf '%s\n%s\n%s\n' "$MP" "$(fp_of "$MP")" "RA" > "$PACE/busy/u2.$MP"
printf '999998\nMon Jan 1 00:00:00 2001\nRB\n' > "$PACE/busy/u2.999998"
printf 'RB\t도는중\t1\t%s\n' "$H2" > "$TEST_PROBE_OUT"
fleet dispatch u1 >/dev/null 2>&1
check "pid 가 죽어도 프로브가 그 런을 도는중으로 보이면 표지는 산다 — 둘이면 lane/ceiling" \
  "$(cut -f3,6 "$PACE/refusals.tsv")" "$(printf 'lane\tceiling')"
kill "$MP" 2>/dev/null; wait "$MP" 2>/dev/null

# --- clause window: the input, stage by stage ------------------------------------
w_case() {
  # w_case <name> <usage-filter|-> <expected-detail>
  d_fresh "d-w-$1" "w$1"
  if [ "$2" = "-" ]; then usage_gone; else usage_write "$2"; fi
  fleet dispatch u1 >/dev/null 2>&1
  check "창 상한: $1 → window/$3" "$(cut -f3,6 "$PACE/refusals.tsv")" "$(printf 'window\t%s' "$3")"
}
w_case absent - unknown-absent
w_case file-stale '.written_at_epoch = ($now - 181)' unknown-stale
w_case file-future '.written_at_epoch = ($now + 61)' unknown-stale
w_case interval-zero '.publish_interval_s = 0' unknown-corrupt
w_case interval-big '.publish_interval_s = 301' unknown-corrupt
w_case interval-frac '.publish_interval_s = 60.5' unknown-corrupt
w_case schema '.schema = "cc-lane-usage v2"' unknown-corrupt
w_case no-row '.accounts |= map(select(.id != "u1"))' unknown-absent
w_case no-window '.accounts[1].windows |= del(.five_hour)' unknown-absent
w_case obs-stale '.accounts[1].windows.five_hour.observed_at_epoch = ($now - 1801)' unknown-stale
w_case obs-future '.accounts[1].windows.five_hour.observed_at_epoch = ($now + 61)' unknown-stale
w_case no-ttl '.accounts[1].windows.five_hour.source = "elsewhere"' unknown-stale
w_case negative '.accounts[1].windows.five_hour.utilization = -0.01' unknown-corrupt
w_case over '.accounts[1].windows.five_hour.utilization = 0.80' over
w_case group-newest '.accounts[2].org_hash = "org-u1" | .accounts[2].windows.five_hour.utilization = 0.90 | .accounts[2].windows.five_hour.observed_at_epoch = ($now - 5)' over
d_fresh d-w-reset wr
usage_write '.accounts[1].windows.five_hour.utilization = 0.95 | .accounts[1].windows.five_hour.resets_at_epoch = ($now - 1)'
fleet dispatch u1 >/dev/null 2>&1
check "창 상한: 리셋이 지난 창은 통과한다" "$(backlog_status wr)" "done"
d_fresh d-w-under wu
usage_write '.accounts[1].windows.five_hour.utilization = 0.7999'
fleet dispatch u1 >/dev/null 2>&1
check "창 상한: 80% 바로 아래는 통과한다" "$(backlog_status wu)" "done"
check "창 상한은 state.json 이 없어도 usage.json 으로 판정한다" "$(count_lines "$PACE/refusals.tsv")" "0"

# --- clause burn ---------------------------------------------------------------
d_fresh d-burn u1r; write_state 유지 0.5 0.7 true
fleet dispatch u1 >/dev/null 2>&1
check "용량 < 소진이고 후보가 없으면 절 burn" "$(cut -f3,6 "$PACE/refusals.tsv")" "$(printf 'burn\t-')"
d_fresh d-burn2 u2r; write_state 유지 0.5 0.7 false
fleet dispatch u1 >/dev/null 2>&1
check "후보가 있으면 burn 절은 열린다" "$(backlog_status u2r)" "done"
check "거부 로그의 절 열(3) 어휘는 그대로다" \
  "$(cat "$WORK"/pace-d-*/refusals.tsv 2>/dev/null | cut -f3 | sort -u | tr '\n' ' ')" "brake burn lane window "

# --- lane mismatch: a run already recorded on another account ---------------------
d_fresh d-lm lm1
mkdir -p "$RUNDIR"; printf '%s\n' "$H2" > "$RUNDIR/config-dir"
fleet dispatch u1 >/dev/null 2>&1
check "다른 레이블 레인의 홈에 기록된 런은 lane/lane-mismatch" "$(cut -f3,6 "$PACE/refusals.tsv")" "$(printf 'lane\tlane-mismatch')"
check "그 레코드는 pending 으로 남는다 (그 레인을 기다린다)" "$(backlog_status lm1)" "pending"
check "기록은 다시 쓰지 않는다" "$(cat "$RUNDIR/config-dir")" "$H2"
printf '%s/\n' "$H1" > "$RUNDIR/config-dir"
fleet dispatch u1 >/dev/null 2>&1
check "자기 홈(끝 / 하나 차이)이면 기동한다" "$(backlog_status lm1)" "done"
d_fresh d-lm2 lm2
mkdir -p "$RUNDIR"; printf '%s\n' "$H_CC" > "$RUNDIR/config-dir"
fleet dispatch u1 >/dev/null 2>&1
check "레이블 집합 밖 홈에 기록된 런은 park lane-record" "$(backlog_field lm2 '.status + " " + .park_reason')" "parked lane-record"
d_fresh d-lm3 lm3; inv_write '.accounts[2].unattended = "draining"'
mkdir -p "$RUNDIR"; printf '%s\n' "$H2" > "$RUNDIR/config-dir"
fleet dispatch u1 >/dev/null 2>&1
check "레이블 집합을 떠난(draining) 계정의 홈에 기록된 런은 park lane-record" "$(backlog_field lm3 '.status + " " + .park_reason')" "parked lane-record"
check "그 런은 거부 행을 남기지 않는다" "$(count_lines "$PACE/refusals.tsv")" "0"
d_fresh d-lm4 lm4; usage_write '.accounts[2].windows.five_hour.utilization = 0.95'
mkdir -p "$RUNDIR"; printf '%s\n' "$H2" > "$RUNDIR/config-dir"
fleet dispatch u1 >/dev/null 2>&1
check "5시간 창을 넘은 레이블 계정의 홈이면 파킹하지 않고 lane/lane-mismatch" "$(cut -f3,6 "$PACE/refusals.tsv")" "$(printf 'lane\tlane-mismatch')"
check "그 레코드는 pending 으로 남는다" "$(backlog_status lm4)" "pending"
rm -rf "$RUNDIR"

# --- absent state is 유지 and admits; the launch shape ----------------------------
d_fresh d-absent a1; rm -f "$PACE/state.json"
fleet dispatch u1 >/dev/null 2>&1
check "state.json 부재는 유지로 읽혀 기동한다" "$(backlog_status a1)" "done"
check "기동은 좌석 홈으로 gate.sh snapshot 을 한 번 부른다" "$(count_lines "$TEST_LOG_DIR/gate.log")" "1"
check "snapshot 은 매니페스트를 받고 인벤토리 config_dir 을 CLAUDE_CONFIG_DIR 로 받는다" "$(sed -n '1p' "$TEST_LOG_DIR/gate.log")" "gate snapshot --manifest $MANIFEST CLAUDE_CONFIG_DIR=$H1"
sleep 0.3
check "워처는 정확히 한 번 기동된다" "$(count_lines "$TEST_LOG_DIR/watch.log")" "1"
check "워처 인자는 autopilot 의 기동 줄과 같은 임계를 싣는다 (--silence 300 포함)" "$(sed -n '1p' "$TEST_LOG_DIR/watch.log")" "watch --run-dir $RUNDIR --ledger $WT_MAIN/docs/pipeline-run/R1.md --stall 1200 --interval 60 --after-stage 120 --run-open 300 --silence 300"
check "run.sh 는 앞단에서 그 계정의 홈으로 돈다" "$(sed -n '1p' "$TEST_LOG_DIR/run.log")" "run --manifest $MANIFEST CLAUDE_CONFIG_DIR=$H1"
check "집은 레인(인벤토리 id)이 레코드에 적힌다" "$(backlog_field a1 .dispatched_lane)" "u1"
[ -s "$WT_MAIN/docs/pipeline-run/R1.md" ] && ok "보고서 스텁이 없으면 만든다" || bad "보고서 스텁이 없으면 만든다" "absent"
check "기동이 끝나면 실행 표지가 남지 않는다" "$(ls "$PACE/busy" 2>/dev/null | count_lines /dev/stdin)" "0"

# --- a linked worktree as the origin: the ledger is the main worktree's ---------
# run.sh writes the run ledger under the parent of the git common dir, so a run
# started from a linked worktree records into the main worktree's docs/. The
# stub, the watcher and the poller must name that same file.
LWT="$WORK/wt-linked"
( cd "$WT" && git worktree add -q "$LWT" -b linked ) >/dev/null 2>&1
LMAN="$WORK/R2.plan.md"
printf '<!-- cc-run-manifest v1; run-id=R2; owner-doc=docs/x.md; origin-worktree=%s; -->\n\n**설계 문서 전체 sha256**: %s\n' "$LWT" "$DOC_SHA" > "$LMAN"
d_fresh d-linked lk1
set_backlog "$(backlog_record lk1 ".manifest_path = \"$LMAN\"")"
rm -f "$TEST_LOG_DIR/checks.log"
fleet dispatch u1 >/dev/null 2>&1
sleep 0.3
check "연결 워크트리 매니페스트도 기동한다" "$(backlog_status lk1)" "done"
[ -s "$WT_MAIN/docs/pipeline-run/R2.md" ] && ok "연결 워크트리 런의 스텁은 메인 워크트리에 생긴다" || bad "연결 워크트리 런의 스텁은 메인 워크트리에 생긴다" "absent"
[ ! -e "$LWT/docs/pipeline-run/R2.md" ] && ok "연결 워크트리 아래에는 스텁이 생기지 않는다" || bad "연결 워크트리 아래에는 스텁이 생기지 않는다" "present"
check "감시자의 --ledger 는 메인 워크트리의 원장이다" \
  "$(sed -n '1p' "$TEST_LOG_DIR/watch.log" | sed -n 's/.*--ledger \([^ ]*\) .*/\1/p')" "$WT_MAIN/docs/pipeline-run/R2.md"
check "폴러의 --ledger 는 메인 워크트리의 원장이다" \
  "$(sed -n '1p' "$TEST_LOG_DIR/checks.log" | sed -n 's/.*--ledger \([^ ]*\) .*/\1/p')" "$WT_MAIN/docs/pipeline-run/R2.md"
rm -rf "$WORK/xdg/cc-cmds/run/R2"

# --- two lanes, one head: the claim is locked and the flip is a CAS -----------
d_fresh d-race r1
TEST_PROBE_SLEEP=1 fleet dispatch u1 >/dev/null 2>"$WORK/race-u1.err" &
race_pid=$!
sleep 0.4
fleet dispatch u2 >/dev/null 2>"$WORK/race-u2.err"
wait "$race_pid" || true
check "같은 pending 을 두 레인이 동시에 집어도 run.sh 는 한 번만 돈다" "$(count_lines "$TEST_LOG_DIR/run.log")" "1"
check "기동한 쪽은 먼저 잠금을 잡은 레인이다" "$(sed -n '1p' "$TEST_LOG_DIR/run.log")" "run --manifest $MANIFEST CLAUDE_CONFIG_DIR=$H1"
check "레코드는 하나이고 done 이다" "$(backlog_status r1 | tr '\n' ' ')" "done "
check "집은 시각이 레코드에 적힌다" "$(backlog_field r1 .dispatched_at)" "$(iso "$NOW")"
check "둘째 레인은 pending 이 없다고 끝난다" "$(grep -c 'pending 레코드가 없다' "$WORK/race-u2.err" || true)" "1"
[ -d "$PACE/backlog.lock" ] && bad "잠금은 파견 뒤 풀려 있다" "backlog.lock 이 남아 있다" || ok "잠금은 파견 뒤 풀려 있다"

# --- Three heads, three lanes at once, the fleet ceiling at two -------------------
d_fresh d-ceil q1
inv_write "$(acct_add_u3)"; usage_write "$(usage_u3)"
set_backlog "$(backlog_record q1 ".enqueued_at = \"$(iso $(( NOW - 3700 )))\"")" \
            "$(backlog_record q2 ".enqueued_at = \"$(iso $(( NOW - 3650 )))\"")" \
            "$(backlog_record q3)"
for l in u1 u2 u3; do
  TEST_RUN_SLEEP=12 fleet dispatch "$l" >/dev/null 2>"$WORK/ceil-$l.err" &
  eval "ceil_$l=\$!"
done
wait "$ceil_u1" "$ceil_u2" "$ceil_u3" 2>/dev/null
check "상한: 세 레인이 동시에 파견해도 기동은 둘이다" "$(count_lines "$TEST_LOG_DIR/run.log")" "2"
check "상한: 레코드 둘이 done, 하나가 pending" "$(jq -r .status "$PACE/backlog.jsonl" | sort | tr '\n' ' ')" "done done pending "
check "상한: 거부 행은 lane/ceiling 하나다" "$(cut -f3,6 "$PACE/refusals.tsv")" "$(printf 'lane\tceiling')"
check "상한: 끝난 뒤 실행 표지가 남지 않는다" "$(ls "$PACE/busy" 2>/dev/null | count_lines /dev/stdin)" "0"

# A stale lock is a dead holder's: it is broken, not waited on.
d_fresh d-stale-lock k1
mkdir -p "$PACE/backlog.lock"; touch -t 202001010000 "$PACE/backlog.lock"
fleet dispatch u1 >/dev/null 2>"$WORK/stale-lock.err"
check "묵은 backlog.lock 은 깨고 기동한다" "$(backlog_status k1)" "done"
check "깬 사실을 로그에 남긴다" "$(grep -c '죽은 소유자' "$WORK/stale-lock.err" || true)" "1"
d_fresh d-steal t1
TEST_RUN_STEAL=1 fleet dispatch u1 >/dev/null 2>"$WORK/steal.err"
check "원본 줄이 사라진 done 재작성은 덮어쓰지 않는다" "$(backlog_status t1)" "stolen"
check "실패한 교환은 로그에 남는다" "$(grep -c 'done 재작성이 실패했다' "$WORK/steal.err" || true)" "1"

# --- parks ---------------------------------------------------------------------
d_fresh d-park p0
set_backlog "$(backlog_record p-manifest '.manifest_path = "/nonexistent/x.md"')"
fleet dispatch u1 >/dev/null 2>&1
check "매니페스트 부재 → park manifest-missing" "$(backlog_field p-manifest '.status + " " + .park_reason')" "parked manifest-missing"
NORUN="$WORK/norun.plan.md"
printf '<!-- cc-run-manifest v1; owner-doc=docs/x.md; origin-worktree=%s; -->\n\n**설계 문서 전체 sha256**: %s\n' "$WT" "$DOC_SHA" > "$NORUN"
set_backlog "$(backlog_record p-norun ".manifest_path = \"$NORUN\"")"
fleet dispatch u1 >/dev/null 2>&1
check "run-id 가 없는 매니페스트 → park manifest-missing" "$(backlog_field p-norun '.status + " " + .park_reason')" "parked manifest-missing"
set_backlog "$(backlog_record p-clock ".authorized_at = \"$(iso $(( NOW - 60 )))\"")"
fleet dispatch u1 >/dev/null 2>&1
check "인가가 인큐보다 늦으면 → park clock-incoherent" "$(backlog_field p-clock .park_reason)" "clock-incoherent"
set_backlog "$(backlog_record p-deadline ".deadline = \"$(iso $(( NOW - 60 )))\"")"
fleet dispatch u1 >/dev/null 2>&1
check "마감이 지났으면 → park deadline-passed" "$(backlog_field p-deadline .park_reason)" "deadline-passed"
set_backlog "$(backlog_record p-doc '.doc_sha256 = "0000"')"
fleet dispatch u1 >/dev/null 2>&1
check "설계 문서 해시가 다르면 → park doc-changed" "$(backlog_field p-doc .park_reason)" "doc-changed"
set_backlog "$(backlog_record p-base '.base_commit = "ffffffffffffffffffffffffffffffffffffffff"')"
fleet dispatch u1 >/dev/null 2>&1
check "베이스가 HEAD 의 조상이 아니면 → park base-moved" "$(backlog_field p-base .park_reason)" "base-moved"
check "park 는 refusals.tsv 에 남지 않는다" "$(count_lines "$PACE/refusals.tsv")" "0"

# --- oversize record is skipped, never parked; oldest pending goes first ------
d_fresh d-size s0
PAD=$(head -c 5000 /dev/zero | tr '\0' 'x')
set_backlog "$(backlog_record big ".enqueued_at = \"$(iso $(( NOW - 9000 )))\" | .authorized_at = \"$(iso $(( NOW - 9500 )))\" | .pad = \"$PAD\"")" \
            "$(backlog_record newer)" \
            "$(backlog_record older ".enqueued_at = \"$(iso $(( NOW - 8000 )))\" | .authorized_at = \"$(iso $(( NOW - 8500 )))\"")"
fleet dispatch u1 >/dev/null 2>&1
check "4 KiB 를 넘는 레코드는 건너뛴다 — parked 로 두지 않는다" "$(backlog_status big)" "pending"
check "가장 오래된 pending 이 먼저 간다" "$(backlog_status older)" "done"
check "나머지 pending 은 그대로다" "$(backlog_status newer)" "pending"
check "재작성은 다른 줄을 축자로 보존한다" "$(count_lines "$PACE/backlog.jsonl")" "3"

# --- the stale-state and foreign-schema readings ----------------------------------
d_fresh d-stale s1
jq -cn --argjson now "$NOW" '{schema: "cc-pace-state v1", tick_seq: 1, computed_at_epoch: ($now - 181), verdict: "제동", seats: []}' > "$PACE/state.json"
fleet dispatch u1 >/dev/null 2>&1
check "181초 낡은 제동 상태는 부재로 읽혀 기동한다" "$(backlog_status s1)" "done"
d_fresh d-foreign f1
jq -cn --argjson now "$NOW" '{schema: "cc-pace-state v2", tick_seq: 1, computed_at_epoch: $now, verdict: "제동", seats: []}' > "$PACE/state.json"
fleet dispatch u1 >/dev/null 2>&1
check "다른 스키마의 제동 상태는 부재로 읽혀 기동한다" "$(backlog_status f1)" "done"

# --- boot-time re-entry: the branch at the top of the dispatch tick ----------------
# Seven fixture runs under the fixture state home, each recorded by a seat on the
# interactive lane, and a fake pinned gate beside its own watcher and poller
# stubs. The kernel's boot time is the test value. The fake gate logs every call
# into one file, in order: a snapshot settles a run that carries `needs-settle`
# (it writes the dead shift's `무기록`), and a `router-shift` leaves `상한` on the
# first call and `중단` on the second. The source-only seam answers the `대기`
# state the way the real gate does for a hand-back.
T2O="$WORK/t2orch"; mkdir -p "$T2O"
cat > "$T2O/gate.sh" <<'EOF'
#!/usr/bin/env bash
if [ "${CC_GATE_SOURCE_ONLY:-0}" = "1" ]; then
  gate_relay_reentry_allowed() {
    [ "$(awk '/^- `handoff` /{w=(index($0," | 사유=대기 | ")>0)?"w":"x"} /^- `교대 기동` /{w="x"} END{printf "%s",w}' "$LEDGER" 2>/dev/null)" = w ]
  }
  return 0 2>/dev/null || exit 0
fi
verb=$1; shift
man=""; kind=""; first=""
while [ $# -gt 0 ]; do
  case "$1" in
    --manifest) man=$2; shift 2 ;;
    --kind) kind=$2; shift 2 ;;
    --) shift; first=${1:-}; break ;;
    *) shift ;;
  esac
done
rid=$(sed -n 's/.*run-id=\([^;]*\);.*/\1/p' "$man" | sed -n '1p')
rd="$XDG_STATE_HOME/cc-cmds/run/$rid"
led=$(cat "$rd/ledger-path")
if [ "$kind" = "router-shift" ]; then
  # The watcher's line must already be there; waiting for it keeps a watcher
  # launched before this call from losing the race to it in the log, and a
  # watcher launched after this call still lands after this line.
  i=0; while [ "$i" -lt 30 ] && ! grep -q "^watch $rid\$" "$TEST_LOG_DIR/t2.log" 2>/dev/null; do sleep 0.1; i=$((i + 1)); done
fi
printf '%s %s %s CLAUDE_CONFIG_DIR=%s REENTRY=%s\n' "${kind:-$verb}" "$rid" "${first:--}" "${CLAUDE_CONFIG_DIR:-}" "${CC_PIPELINE_REENTRY:-}" >> "$TEST_LOG_DIR/t2.log"
case "$verb:$kind" in
  snapshot:)
    if [ -e "$rd/needs-settle" ]; then
      rm -f "$rd/needs-settle"
      printf -- '- `handoff` | 교대=1 | 사유=무기록 | 버린 선택지=- | 막힌 지점=- | 다음 후보=- | 대상=infra | 기록 시각=%s | 종료 코드=- | 행위 수=0\n' "$(date -u +%FT%TZ)" >> "$led"
    fi
    printf '{"H":"h-%s"}\n' "$rid" ;;
  act:router-shift)
    # A run carrying `handback` comes back as a relay that met a return
    # condition at once: no shift, no row.
    [ ! -e "$rd/handback" ] || exit 0
    # `t2.caps` holds how many calls leave `상한` before the `중단`, one when absent.
    n=$(cat "$rd/t2.calls" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$rd/t2.calls"
    if [ "$n" -le "$(cat "$rd/t2.caps" 2>/dev/null || echo 1)" ]; then r=상한; else r=중단; fi
    printf -- '- `교대 기동` | 서수=%s\n- `handoff` | 교대=%s | 사유=%s | 대상=infra\n' "$n" "$n" "$r" >> "$led" ;;
esac
exit 0
EOF
cat > "$T2O/watch.sh" <<'EOF'
#!/usr/bin/env bash
printf 'watch %s\n' "$(basename "$2")" >> "$TEST_LOG_DIR/t2.log"
exit 0
EOF
cat > "$T2O/checks.sh" <<'EOF'
#!/usr/bin/env bash
printf 'checks %s\n' "$(basename "$2")" >> "$TEST_LOG_DIR/t2-checks.log"
exit 0
EOF
chmod +x "$T2O"/*.sh
T2BOOT=$(( NOW - 600 ))
t2_run() {
  # t2_run <run-id> <ledger rows…> — a run the seat opened on the interactive lane.
  local rid="$1" rd="$WORK/xdg/cc-cmds/run/$1" led="$WORK/t2led/$1.md" man="$WORK/t2man/$1.plan.md"; shift
  rm -rf "$rd"; mkdir -p "$rd" "$WORK/t2led" "$WORK/t2man"
  printf '<!-- cc-run-manifest v1; run-id=%s; owner-doc=docs/x.md; origin-worktree=%s; -->\n' "$rid" "$WT" > "$man"
  printf '# 파이프라인 런 %s\n\n' "$rid" > "$led"
  for row in "$@"; do printf '%s\n' "$row" >> "$led"; done
  printf '1\n' > "$rd/ends-on-done"
  printf '%s\n' "$H_CC" > "$rd/config-dir"
  printf '%s\n' "$led" > "$rd/ledger-path"
  printf 'manifest=%s\ntarget=infra\ngate=%s\ncutpoint=머지\nsurface=워크트리쓰기\n' "$man" "$T2O/gate.sh" > "$rd/seat-call"
  # The seat's last call was before the boot: the boot cut this run.
  touch -t 202001010000 "$rd/seat-call"
}
T2_LAUNCH='- `교대 기동` | 서수=1'
T2_SETTLED="- \`stage-result\` | 세그먼트=A | 스테이지=A | 종단 부류=외부 종료 | 관측=파견 기록이 프로세스보다 오래 살았고 종단 result 줄이 없다 — 정산 시각 $(iso $(( NOW - 300 )))"
T2_OLD="- \`stage-result\` | 세그먼트=A | 스테이지=A | 종단 부류=외부 종료 | 관측=파견 기록이 프로세스보다 오래 살았고 종단 result 줄이 없다 — 정산 시각 $(iso $(( NOW - 3600 )))"
d_fresh d-t2 t2h
t2_run T2A "$T2_LAUNCH"; : > "$WORK/xdg/cc-cmds/run/T2A/needs-settle"
t2_run T2B '- `handoff` | 교대=1 | 사유=중단 | 대상=infra' "$T2_SETTLED"
t2_run T2C "$T2_LAUNCH"; : > "$WORK/xdg/cc-cmds/run/T2C/needs-settle"; : > "$WORK/xdg/cc-cmds/run/T2C/done"
t2_run T2D "$T2_SETTLED" '- `handoff` | 교대=1 | 사유=승인 | 대상=infra'
t2_run T2E "$T2_SETTLED"
sleep 300 & t2_relay=$!; BG_PIDS="$BG_PIDS $t2_relay"
printf '%s\n%s\n' "$t2_relay" "$(bash -c '. "$1" && cc_proc_fingerprint "$2"' _ "$ORCH/liveness.sh" "$t2_relay")" > "$WORK/xdg/cc-cmds/run/T2E/relay.live"
t2_run T2F "$T2_SETTLED"
mkdir -p "$PACE/reentry"; printf '%s\n' "$T2BOOT" > "$PACE/reentry/T2F.boot"
t2_run T2G '- `handoff` | 교대=1 | 사유=중단 | 대상=infra' "$T2_OLD"
# Runs this boot did not cut, each in a state every other condition admits —
# dead relay and shift, latest handoff `대기`, no boot marker. T2H's seat called
# after the boot (a run born this boot); T2J's seat-call is from before it, but
# a relay of this boot handed the turn back and left `relay.live`.
T2_WAIT='- `handoff` | 교대=1 | 사유=대기 | 대상=infra'
( exit 0 ) & t2_dead=$!; wait "$t2_dead" 2>/dev/null || true
t2_run T2H "$T2_LAUNCH" "$T2_WAIT"; touch "$WORK/xdg/cc-cmds/run/T2H/seat-call"
t2_run T2J "$T2_LAUNCH" "$T2_WAIT"
printf '%s\nx\nhandback=%s\n' "$t2_dead" "$NOW" > "$WORK/xdg/cc-cmds/run/T2J/relay.live"
# A run the boot cut whose relay keeps coming back at once with no shift — the
# poller of a CI wait is dead and stays dead.
t2_run T2I "$T2_LAUNCH" "$T2_WAIT"; : > "$WORK/xdg/cc-cmds/run/T2I/handback"
# A run the boot cut on another label's account (u2): this label leaves it.
t2_run T2K "$T2_LAUNCH"; : > "$WORK/xdg/cc-cmds/run/T2K/needs-settle"
printf '%s\n' "$H2" > "$WORK/xdg/cc-cmds/run/T2K/config-dir"
# A run whose every call launches a shift and comes back on its cap, past the
# twelve calls the chain allows a call that launched nothing.
t2_run T2L "$T2_LAUNCH"; : > "$WORK/xdg/cc-cmds/run/T2L/needs-settle"
printf '14\n' > "$WORK/xdg/cc-cmds/run/T2L/t2.caps"
rm -f "$TEST_LOG_DIR/t2.log" "$TEST_LOG_DIR/t2-checks.log"
FLEET_REENTRY_PAUSE_TEST_SECONDS=0 CC_SYSCTL_TEST_VALUES="kern.boottime=$T2BOOT" ORCH_HOST_OS=Darwin fleet dispatch u1 >/dev/null 2>"$WORK/t2-1.err"; rc=$?
t2n() { grep -c "^$1 $2 " "$TEST_LOG_DIR/t2.log" 2>/dev/null || true; }
t2line() { grep -n "^$1 $2\( \|\$\)" "$TEST_LOG_DIR/t2.log" 2>/dev/null | sed -n '1p' | cut -d: -f1; }
check "재진입: 틱은 0 으로 끝난다" "$rc" "0"
check "재진입: 두 대상 런에 재진입 행 호출이 한 번씩" "$(t2n reentry T2A):$(t2n reentry T2B)" "1:1"
check "재진입: 재진입 행의 사유는 정산 뒤 원장에서 읽은 중단이다" \
  "$(grep '^reentry T2A ' "$TEST_LOG_DIR/t2.log" | cut -d' ' -f3)" "사유=중단"
check "재진입: 대상 런의 router-shift 는 두 번이고 둘째는 상한이다" \
  "$(grep '^router-shift T2A ' "$TEST_LOG_DIR/t2.log" | cut -d' ' -f3 | tr '\n' ' ')" "중단 상한 "
check "재진입: 정산 행이 이미 있는 런도 교대를 부른다" "$(t2n router-shift T2B)" "2"
t2_c2() {
  local r w s
  r=$(t2line reentry "$1"); w=$(t2line watch "$1"); s=$(t2line router-shift "$1")
  [ -n "$r" ] && [ -n "$w" ] && [ -n "$s" ] && [ "$r" -lt "$w" ] && [ "$w" -lt "$s" ] && printf 'ok' || printf '%s<%s<%s' "$r" "$w" "$s"
}
check "재진입 C2: 재진입 행 호출이 감시자와 router-shift 보다 같은 틱 안에서 먼저 (T2A)" "$(t2_c2 T2A)" "ok"
check "재진입 C2: 재진입 행 호출이 감시자와 router-shift 보다 같은 틱 안에서 먼저 (T2B)" "$(t2_c2 T2B)" "ok"
check "재진입: 감시자 기동은 대상 런마다 한 번" "$(grep -c '^watch T2A$' "$TEST_LOG_DIR/t2.log" || true):$(grep -c '^watch T2B$' "$TEST_LOG_DIR/t2.log" || true)" "1:1"
check "재진입: 폴러도 대상 런마다 한 번" "$(grep -c '^checks T2A$' "$TEST_LOG_DIR/t2-checks.log" || true)" "1"
check "재진입: router-shift 의 CLAUDE_CONFIG_DIR 는 런의 config-dir 이다" \
  "$(grep '^router-shift T2A ' "$TEST_LOG_DIR/t2.log" | sed -n '1p' | sed -n 's/.* CLAUDE_CONFIG_DIR=\([^ ]*\) .*/\1/p')" "$H_CC"
check "재진입: router-shift 의 CC_PIPELINE_REENTRY 는 <run-id>@<부팅 값> 이다" \
  "$(grep '^router-shift T2A ' "$TEST_LOG_DIR/t2.log" | sed -n '1p' | sed -n 's/.* REENTRY=\(.*\)$/\1/p')" "T2A@$T2BOOT"
check "재진입: done·승인·살아 있는 relay·처리한 부팅 값의 런에는 호출이 없다" \
  "$(grep -c -E '^[a-z-]+ T2[CDEF] ' "$TEST_LOG_DIR/t2.log" || true)" "0"
check "재진입: 정산할 것 없는 중단 런은 스냅숏 하나뿐이다" \
  "$(grep -E '^[a-z-]+ T2G ' "$TEST_LOG_DIR/t2.log" | cut -d' ' -f1 | tr '\n' ' ')" "snapshot "
check "재진입: 이번 부팅에 좌석이 부른 런과 이번 부팅에 hand-back 한 런에는 스냅숏도 호출도 감시자도 없다" \
  "$(grep -c -E '^[a-z-]+ T2[HJ]( |$)' "$TEST_LOG_DIR/t2.log" || true):$(grep -c -E '^checks T2[HJ]$' "$TEST_LOG_DIR/t2-checks.log" || true)" "0:0"
check "재진입: 이번 부팅이 끊지 않은 런에는 부팅 표지를 남기지 않는다" \
  "$( { [ -e "$PACE/reentry/T2H.boot" ] || [ -e "$PACE/reentry/T2J.boot" ]; } && printf marked || printf none)" "none"
check "재진입: 곧바로 돌아오는 대기는 두 번째에서 사슬을 멈춘다" \
  "$(grep '^router-shift T2I ' "$TEST_LOG_DIR/t2.log" | cut -d' ' -f3 | tr '\n' ' ')" "대기 대기 "
check "재진입: 첫 번째 곧바로 돌아온 대기 뒤 죽은 폴러만 다시 띄운다" \
  "$(grep -c '^watch T2I$' "$TEST_LOG_DIR/t2.log" || true):$(grep -c '^checks T2I$' "$TEST_LOG_DIR/t2-checks.log" || true)" "1:2"
check "재진입: 다른 레이블 계정의 런에는 스냅숏도 호출도 감시자도 부팅 표지도 없다" \
  "$(grep -c -E '^[a-z-]+ T2K( |$)' "$TEST_LOG_DIR/t2.log" || true):$( [ -e "$PACE/reentry/T2K.boot" ] && printf marked || printf none)" "0:none"
check "재진입: 교대를 띄운 상한 호출은 세지 않아 사슬이 열두 번에서 멈추지 않는다" \
  "$(t2n router-shift T2L):$(grep '^router-shift T2L ' "$TEST_LOG_DIR/t2.log" | tail -1 | cut -d' ' -f3)" "15:상한"
check "재진입: 재진입을 돌린 틱은 백로그를 집지 않는다" "$(backlog_status t2h)" "pending"
check "재진입: 런마다의 점유는 풀려 있다" "$(ls -d "$PACE"/reentry/*.lock 2>/dev/null | count_lines /dev/stdin)" "0"
t2_before=$(count_lines "$TEST_LOG_DIR/t2.log")
FLEET_REENTRY_PAUSE_TEST_SECONDS=0 CC_SYSCTL_TEST_VALUES="kern.boottime=$T2BOOT" ORCH_HOST_OS=Darwin fleet dispatch u1 >/dev/null 2>"$WORK/t2-2.err"
check "재진입: 같은 부팅의 두 번째 틱에서는 호출 0" "$(( $(count_lines "$TEST_LOG_DIR/t2.log") - t2_before ))" "0"
check "재진입: 두 번째 틱은 백로그로 간다" "$(backlog_status t2h)" "done"
kill "$t2_relay" 2>/dev/null || true
rm -rf "$WORK"/xdg/cc-cmds/run/T2?

# --- usage ----------------------------------------------------------------------
fresh_pace d-usage
fleet dispatch >/dev/null 2>&1; rc=$?
check "레인 없는 dispatch 는 usage 오류(2)" "$rc" "2"
fleet >/dev/null 2>&1; rc=$?
check "부속 명령 없이 부르면 usage 오류(2)" "$rc" "2"

# ===========================================================================
# AGENT
# ===========================================================================
agent_reset() { : > "$TEST_LAUNCHD_STATE"; : > "$TEST_LAUNCHD_RUNNING"; : > "$TEST_LAUNCHD_LOG"; rm -rf "$WORK/agents"; mkdir -p "$WORK/agents"; }
L=com.nharu.cc-cmds.fleet
fresh_pace agent; agent_reset
fleet agent install >/dev/null 2>&1; rc=$?
check "install 은 성공한다" "$rc" "0"
check "레이블은 센서 + 레이블 집합 계정마다 하나다 (예약 계정 제외)" "$(sort "$TEST_LAUNCHD_STATE" | tr '\n' ' ')" "$L.dispatch.u1 $L.dispatch.u2 $L.sensor "
check "세 plist 가 렌더된다" "$(ls "$WORK/agents" | wc -l | tr -d ' ')" "3"
SENSOR_PLIST="$WORK/agents/$L.sensor.plist"
DISP_PLIST="$WORK/agents/$L.dispatch.u1.plist"
check "센서 plist 의 StartInterval 은 fleet.sh 의 선언값이다" "$(sed -n '/<key>StartInterval<\/key>/{n;s/.*<integer>\(.*\)<\/integer>.*/\1/p;}' "$SENSOR_PLIST")" "55"
check "파견 plist 의 StartInterval 은 파견 선언값이다" "$(sed -n '/<key>StartInterval<\/key>/{n;s/.*<integer>\(.*\)<\/integer>.*/\1/p;}' "$DISP_PLIST")" "120"
check "센서 plist 에는 레인 줄이 없다" "$(grep -c -e '@LANE@' -e 'CLAUDE_CONFIG_DIR' "$SENSOR_PLIST" || true)" "0"
check "파견 plist 는 인벤토리 config_dir 을 CLAUDE_CONFIG_DIR 로 싣는다" "$(grep -c "<string>$H1</string>" "$DISP_PLIST" || true)" "1"
check "파견 plist 의 레인 인자는 인벤토리 id 다" "$(grep -c '<string>u1</string>' "$DISP_PLIST" || true)" "1"
check "렌더된 plist 에 자리표시자가 남지 않는다" "$(cat "$WORK/agents"/*.plist | grep -c '@[A-Z_]*@' || true)" "0"
check "부재 키 셋은 렌더본에도 없다" "$(cat "$WORK/agents"/*.plist | grep -c -e '<key>KeepAlive</key>' -e '<key>AbandonProcessGroup</key>' -e '<key>ProcessType</key>' || true)" "0"
n_before=$(count_lines "$TEST_LAUNCHD_LOG")
fleet agent install >/dev/null 2>&1; rc=$?
check "install 은 멱등이다 (재실행 성공)" "$rc" "0"
check "재설치는 레이블마다 bootout 뒤 bootstrap 한다" "$(sed -n "$(( n_before + 1 )),\$p" "$TEST_LAUNCHD_LOG" | grep -c -e '^bootout' -e '^bootstrap' || true)" "6"
# half-installed: one plist missing while all three are registered
rm -f "$DISP_PLIST"
fleet agent install >/dev/null 2>"$WORK/half.err"; rc=$?
check "반설치(plist 2/3, 등록 3/3)는 거부한다" "$rc" "1"
grep -q '반쯤 설치된' "$WORK/half.err" && ok "반설치 거부 문면은 uninstall 을 처방한다" || bad "반설치 거부 문면은 uninstall 을 처방한다" "$(cat "$WORK/half.err")"
# running dispatch label refuses install and uninstall
fleet agent uninstall >/dev/null 2>&1
fleet agent install >/dev/null 2>&1
printf '%s.dispatch.u1\n' "$L" > "$TEST_LAUNCHD_RUNNING"
fleet agent install >/dev/null 2>&1; rc=$?
check "도는 중인 파견 레이블은 install 을 거부한다" "$rc" "1"
fleet agent uninstall >/dev/null 2>&1; rc=$?
check "도는 중인 파견 레이블은 uninstall 을 거부한다" "$rc" "1"
check "status 는 running 을 표시한다" "$(fleet agent status 2>/dev/null | grep -c 'dispatch.u1: 등록됨 (running)' || true)" "1"
: > "$TEST_LAUNCHD_RUNNING"

# status: eligibility as the sensor published it, orphans, live markers
usage_write '.accounts[2].login = "expired"'
fleet sensor >/dev/null 2>&1
sleep 30 & SP=$!; BG_PIDS="$BG_PIDS $SP"
mkdir -p "$PACE/busy"; printf '%s\n%s\n%s\n' "$SP" "$(fp_of "$SP")" "RS" > "$PACE/busy/u1.$SP"
fleet agent status > "$WORK/status.out" 2>/dev/null
check "status 는 적격 레인을 적격으로 찍는다" "$(grep -c "^$L.dispatch.u1: 등록됨 — 적격$" "$WORK/status.out" || true)" "1"
check "status 는 부적격 레인의 사유를 그대로 찍는다" "$(grep -c "^$L.dispatch.u2: 등록됨 — 부적격: login$" "$WORK/status.out" || true)" "1"
check "status 는 살아 있는 실행 표지를 찍는다" "$(grep -c "^실행 표지: u1.$SP (런 RS)$" "$WORK/status.out" || true)" "1"
check "status 는 상한 대비 표지 수를 찍는다" "$(grep -c '^살아 있는 실행 표지: 1 / 상한 2$' "$WORK/status.out" || true)" "1"
kill "$SP" 2>/dev/null; wait "$SP" 2>/dev/null; rm -rf "$PACE/busy"
usage_write '.accounts[1].login = "expired" | .accounts[2].login = "expired"'
fleet sensor >/dev/null 2>&1
check "적격 레인이 0 이면 status 가 경고한다" "$(fleet agent status 2>/dev/null | grep -c '^경고: 적격 레인이 없다' || true)" "1"
usage_write

# orphans: an account that left the label set keeps its plist until uninstall
inv_write '.accounts[2].unattended = "disabled"'
check "status 는 레이블 집합 밖 plist 를 고아로 찍는다" "$(fleet agent status 2>/dev/null | grep -c "^$L.dispatch.u2: 등록됨 — 고아" || true)" "1"
fleet agent install >/dev/null 2>"$WORK/orphan.err"; rc=$?
check "고아가 있으면 install 을 거부한다" "$rc" "1"
check "고아 거부 문면은 그 id 와 uninstall 을 말한다" "$(grep -c 'u2 .*uninstall' "$WORK/orphan.err" || true)" "1"
: > "$TEST_LAUNCHD_LOG"
fleet agent uninstall >/dev/null 2>&1; rc=$?
check "uninstall 은 성공한다" "$rc" "0"
check "uninstall 은 레이블 우주(센서 + 집합 + 디스크의 plist)마다 bootout 한다" "$(grep -c '^bootout' "$TEST_LAUNCHD_LOG" || true)" "3"
check "uninstall 뒤 등록이 없다" "$(count_lines "$TEST_LAUNCHD_STATE")" "0"
check "uninstall 뒤 plist 가 없다 (고아 포함)" "$(ls "$WORK/agents" 2>/dev/null | wc -l | tr -d ' ')" "0"
check "status 는 미등록과 하트비트 있음을 말한다" "$(fleet agent status 2>/dev/null | grep -c '미등록' || true)" "2"
inv_write
# a plist file name that is not an id is never handed to launchctl
touch "$WORK/agents/$L.dispatch.Bad_Name.plist"
: > "$TEST_LAUNCHD_LOG"
fleet agent uninstall >/dev/null 2>&1
check "형식이 틀린 plist 이름은 launchctl 에 넘기지 않는다" "$(grep -c 'Bad_Name' "$TEST_LAUNCHD_LOG" || true)" "0"
rm -f "$WORK/agents/$L.dispatch.Bad_Name.plist"
# files present but nothing registered is also half-installed
fleet agent install >/dev/null 2>&1
: > "$TEST_LAUNCHD_STATE"
fleet agent install >/dev/null 2>&1; rc=$?
check "plist 3/3 에 등록 0/3 도 반설치로 거부한다" "$rc" "1"

# refused installs leave no plist behind
refused_install() {
  # refused_install <name> <inventory-filter|-> — install on a clean slate with
  # that inventory must exit 1 and render nothing.
  agent_reset
  if [ "$2" = "-" ]; then rm -f "$INV"; else inv_write "$2"; fi
  fleet agent install >/dev/null 2>"$WORK/refused-$1.err"; rc=$?
  check "install 거부: $1 → 1" "$rc" "1"
  check "install 거부: $1 → plist 0 개" "$(ls "$WORK/agents" | wc -l | tr -d ' ')" "0"
}
refused_install id-format '.accounts += [{id: "U_X", config_dir: ($h + "/.claude-u1x"), unattended: "enabled", interactive_reserved: false}]'
check "형식 위반 거부 문면은 그 id 를 적는다" "$(grep -c 'U_X: id 형식' "$WORK/refused-id-format.err" || true)" "1"
refused_install forbidden-char '.accounts[1].config_dir = ($h + "/.claude-u1&x")'
check "금지 문자 거부 문면은 그 id 를 적는다" "$(grep -c 'u1: config_dir 금지 문자' "$WORK/refused-forbidden-char.err" || true)" "1"
refused_install empty-set '.accounts |= map(.unattended = "disabled")'
refused_install no-inventory -
refused_install broken-inventory '.accounts[1].config_dir += "/"'
inv_write

# ===========================================================================
# LENDING
# ===========================================================================
# cc 가 대여에 등록되면(interactive_lending auto · 예약 · 무인 꺼짐) 그 레인이 라벨을
# 얻고, 열린 대여 결정과 라우터의 대여 검사를 모두 통과할 때만 무인 런을 띄운다.
# 픽스처의 cc 는 5시간 10%·7일 50% 이고, 결정은 열림·상한 9000·리셋은 사용량 행과 같다.
LEND_INV='.accounts[0].interactive_lending = "auto"'
LEND_DEC='{state: "open", mode: "auto", evaluated_at_epoch: ($now - 30), net_armed: true, donor_ready: true, resets_at_epoch: ($now + 86400), ceiling_bp: 9000}'
lend_use() { usage_write ".accounts[0].lending = $LEND_DEC${1:+ | $1}"; }
borrow_none() { mkdir -p "$(dirname "$BORROW")"; jq -n '{schema: "cc-lane-borrow v1", state: "none"}' > "$BORROW"; }
l_fresh() {
  # l_fresh <name> <head-id> [<usage-filter>] — d_fresh 에 대여 등록 인벤토리, 열린 결정, 차용 없음.
  d_fresh "$1" "$2"; inv_write "$LEND_INV"; lend_use "${3:-}"; borrow_none
}
mark() { mkdir -p "$PACE/busy"; printf '%s\n%s\n%s\n' "$2" "$(fp_of "$2")" "$3" > "$PACE/busy/$1.$2"; }

# --- labels: install and the end of enrolment -----------------------------------
fresh_pace l-agent; agent_reset
fleet agent install >/dev/null 2>&1
u_plists_before=$(cd "$WORK/agents" && cat "$L.dispatch.u1.plist" "$L.dispatch.u2.plist" "$L.sensor.plist" | cksum)
u_status() { fleet sensor >/dev/null 2>&1; fleet agent status 2>/dev/null | grep -E "^$L\\.dispatch\\.u[12]:|^살아 있는 실행 표지:|^경고:"; }
u_status_before=$(u_status)
fleet agent uninstall >/dev/null 2>&1; agent_reset
inv_write "$LEND_INV"; lend_use; borrow_none
fleet agent install >/dev/null 2>&1; rc=$?
check "대여 등록: u 레인의 상태 출력 줄은 등록 전과 같다" "$(u_status)" "$u_status_before"
check "대여 등록: 그 비교는 공허하지 않다 (u 레인 두 줄과 상한 줄)" "$(printf '%s\n' "$u_status_before" | count_lines /dev/stdin)" "3"
check "대여 등록: install 은 성공한다" "$rc" "0"
check "대여 등록: 레이블 집합에 cc 가 든다" "$(sort "$TEST_LAUNCHD_STATE" | tr '\n' ' ')" "$L.dispatch.cc $L.dispatch.u1 $L.dispatch.u2 $L.sensor "
check "대여 등록: cc plist 는 cc 홈을 CLAUDE_CONFIG_DIR 로 싣는다" "$(grep -c "<string>$H_CC</string>" "$WORK/agents/$L.dispatch.cc.plist" || true)" "1"
check "대여 등록: u 레인과 센서의 plist 바이트는 그대로다" \
  "$(cd "$WORK/agents" && cat "$L.dispatch.u1.plist" "$L.dispatch.u2.plist" "$L.sensor.plist" | cksum)" "$u_plists_before"
inv_write
check "등록 해제: cc 는 고아로 찍힌다" "$(fleet agent status 2>/dev/null | grep -c "^$L.dispatch.cc: 등록됨 — 고아" || true)" "1"
check "등록 해제: u 레인은 고아가 아니다" "$(fleet agent status 2>/dev/null | grep -c "^$L.dispatch.u[12]: 등록됨 — 고아" || true)" "0"
: > "$TEST_LAUNCHD_LOG"
fleet agent uninstall >/dev/null 2>&1
check "등록 해제: uninstall 은 cc 를 제거 대상으로 bootout 한다" "$(grep -c "^bootout .*$L.dispatch.cc$" "$TEST_LAUNCHD_LOG" || true)" "1"
fleet agent install >/dev/null 2>&1
check "등록 해제 뒤 install 은 u 레인과 센서만 깐다" "$(sort "$TEST_LAUNCHD_STATE" | tr '\n' ' ')" "$L.dispatch.u1 $L.dispatch.u2 $L.sensor "
fleet agent uninstall >/dev/null 2>&1; agent_reset

# --- sensor: eligibility, the lending reasons, allocation -------------------------
fresh_pace l-sensor; inv_write "$LEND_INV"; lend_use; borrow_none
fleet sensor >/dev/null 2>&1
check "센서: 열린 대여의 cc 는 적격이다" "$(seat cc '"\(.eligible) \(.reason)"')" "true null"
check "센서: 대여 행은 좌석 목록의 맨 뒤다" "$(state_field '[.seats[].id] | join(",")')" "u1,u2,cc"
check "센서: 게시 좌석의 칸 집합은 그대로다" "$(state_field '.seats[-1] | keys_unsorted | join(",")')" "id,home,org,eligible,reason,allow,session_pct,ttr,burn_4h"
lend_use '.accounts[0].lending.ceiling_bp = 5500'
fleet sensor >/dev/null 2>&1
check "센서: 대여 행의 남은 양은 ceiling_bp − ueff7 이다 ((5500−5000)/100/24)" "$(seat cc '.allow | . * 1000 | floor')" "208"
check "센서: 다른 행의 남은 양은 그대로다" "$(seat u1 '.allow | . * 1000 | floor')" "595"
lend_use '.accounts[0].lending.state = "closed"'
fleet sensor >/dev/null 2>&1
check "센서: 닫힌 결정은 lending-closed" "$(seat cc .reason)" "lending-closed"
lend_use '.accounts[0].lending.ceiling_bp = 5300'
fleet sensor >/dev/null 2>&1
check "센서: 7일 상한을 넘는 입장은 lend-ceiling" "$(seat cc .reason)" "lend-ceiling"
lend_use '.accounts[0].windows.five_hour.utilization = 0.40'
fleet sensor >/dev/null 2>&1
check "센서: 5시간 5000 을 넘는 입장은 lend-cap" "$(seat cc .reason)" "lend-cap"
rm -f "$BORROW"; lend_use
fleet sensor >/dev/null 2>&1
check "센서: 차용 기록이 none 이 아니면 lending-closed" "$(seat cc .reason)" "lending-closed"
inv_write '.accounts[0].interactive_lending = "off"'; borrow_none
fleet sensor >/dev/null 2>&1
check "센서: 대여 off 의 cc 는 오늘처럼 not-labelled 이고 맨 앞이다" "$(seat cc .reason) $(state_field '.seats[0].id')" "not-labelled cc"

# --- the ladder: a run on the lending lane is not an active lane --------------------
fresh_pace l-ladder; inv_write "$LEND_INV"; lend_use; borrow_none
burn_heavy "$H1" 1000
printf 'R1\t도는중\t1\t%s\nR6\t도는중\t1\t%s\n' "$H1" "$H_CC" > "$TEST_PROBE_OUT"
fleet sensor >/dev/null 2>&1
check "사다리: cc 런 하나와 u 런 하나면 활성 레인은 하나라 목표 아래다" "$(state_field '.verdict + " " + .verdict_reason')" "가속 lanes-below-target"
printf 'R1\t도는중\t1\t%s\nR2\t도는중\t1\t%s\n' "$H1" "$H2" > "$TEST_PROBE_OUT"
fleet sensor >/dev/null 2>&1
check "사다리: u 런 둘이면 목표에 닿는다 (대조)" "$(state_field '.verdict_reason')" "default"
: > "$TEST_PROBE_OUT"; burn_none

# --- the ladder: a lending row adds nothing to the capacity -------------------------
#   The brake fixture of the u-only ladder above, with cc enrolled and open: cc's
#   home is reserved, so its burn is never scanned, and its 100/168 must not be
#   counted against the u burn either.
fresh_pace l-brake; inv_write "$LEND_INV | .accounts[2].unattended = \"draining\""
usage_write ".accounts[0].lending = $LEND_DEC | $LADDER_USAGE"; borrow_none
burn_heavy "$H1" 1000000
fleet sensor >/dev/null 2>&1
check "용량: 대여 행이 적격이어도 (공허 방지)" "$(seat cc '"\(.eligible) \(.allow * 1000 | floor)"')" "true 595"
check "용량: 열린 대여 행의 허용치는 fleet 용량에 더해지지 않는다" "$(state_field '.fleet_capacity | . * 1000 | floor')" "41"
check "용량: u 소진이 u 용량을 넘으면 대여가 열려 있어도 제동이다" "$(state_field '.verdict + " " + .verdict_reason')" "제동 brake"
burn_none

# --- dispatch: the lending lane starts, and carries its pin --------------------------
l_fresh d-l-open lo1
fleet dispatch cc >/dev/null 2>"$WORK/l-open.err"
check "대여 디스패치: 열린 cc 레인은 기동한다" "$(backlog_status lo1)" "done"
check "대여 디스패치: run.sh 는 cc 홈으로 돈다" "$(sed -n '1p' "$TEST_LOG_DIR/run.log")" "run --manifest $MANIFEST CLAUDE_CONFIG_DIR=$H_CC"
check "대여 디스패치: 런 디렉터리에 fleet-lane=cc 가 쓰인다" "$(cat "$RUNDIR/fleet-lane" 2>/dev/null)" "cc"
check "대여 디스패치: 집은 레인은 cc 다" "$(backlog_field lo1 .dispatched_lane)" "cc"
l_fresh d-l-u lu1
fleet dispatch u1 >/dev/null 2>&1
check "대여 등록 인벤토리의 u 레인도 기동한다" "$(backlog_status lu1)" "done"
[ ! -e "$RUNDIR/fleet-lane" ] && ok "u 레인 디스패치에는 fleet-lane 이 없다" || bad "u 레인 디스패치에는 fleet-lane 이 없다" "$(cat "$RUNDIR/fleet-lane")"
l_fresh d-l-pinfail lp1
mkdir -p "$RUNDIR"; chmod 555 "$RUNDIR"
fleet dispatch cc >/dev/null 2>"$WORK/l-pinfail.err"
chmod 755 "$RUNDIR"
check "고정 기록을 못 쓰면 기동하지 않는다" "$(count_lines "$TEST_LOG_DIR/run.log")" "0"
check "고정 기록을 못 쓰면 레코드는 pending 으로 돌아간다" "$(backlog_status lp1)" "pending"
check "고정 기록 실패는 로그에 남는다" "$(grep -c '대여 좌석 고정 기록을 쓰지 못했다' "$WORK/l-pinfail.err" || true)" "1"

# --- dispatch: the lending reasons, before the lock -----------------------------------
l_case() {
  # l_case <name> <usage-filter> <reason> — 잠금 전 적격에서 그 사유로 끝나고 아무것도 띄우지 않는다.
  l_fresh "d-l-$1" "l$1" "$2"
  fleet dispatch cc >/dev/null 2>"$WORK/l-$1.err"
  check "대여 부적격: $1 → $3" "$(grep -c "부적격 — $3 " "$WORK/l-$1.err" || true)/$(count_lines "$TEST_LOG_DIR/run.log")/$(backlog_status "l$1")" "1/0/pending"
}
l_case closed '.accounts[0].lending.state = "closed"' lending-closed
l_case stale '.accounts[0].lending.evaluated_at_epoch = ($now - 181)' lending-closed
l_case ceiling '.accounts[0].lending.ceiling_bp = 5300' lend-ceiling
l_case cap '.accounts[0].windows.five_hour.utilization = 0.40' lend-cap
l_fresh d-l-broken lb1; inv_write "$LEND_INV | .accounts[1].config_dir += \"/\""
fleet dispatch cc >/dev/null 2>"$WORK/l-broken.err"
check "무효 인벤토리의 대여 레인은 lending-unrouted" "$(grep -c '부적격 — lending-unrouted' "$WORK/l-broken.err" || true)" "1"
fleet dispatch u2 >/dev/null 2>"$WORK/l-broken-u.err"
check "무효 인벤토리의 u 레인은 오늘처럼 inventory-broken" "$(grep -c '부적격 — inventory-broken' "$WORK/l-broken-u.err" || true)" "1"

# --- (i) the real lease table, for the lending lane only --------------------------------
l_fresh d-l-table lt1
printf 'not a table\n' > "$PACE/leases"
fleet dispatch cc >/dev/null 2>"$WORK/l-table.err"
check "(i) 임대 표를 읽을 수 없으면 lending-unrouted 이고 띄우지 않는다" \
  "$(grep -c '부적격 — lending-unrouted' "$WORK/l-table.err" || true)/$(count_lines "$TEST_LOG_DIR/run.log")" "1/0"
fleet dispatch u1 >/dev/null 2>&1
check "(i) u 레인은 임대 표를 읽지 않는다 — 같은 표에서 기동한다" "$(backlog_status lt1)" "done"
l_fresh d-l-lease ll1
sleep 60 & LHP=$!; BG_PIDS="$BG_PIDS $LHP"
LHFP=$( . "$FX/liveness.sh"; TZ=UTC0 cc_proc_fingerprint "$LHP" )
mkdir -p "$PACE/leases"
jq -cn --argjson pid "$LHP" --arg fp "$LHFP" --arg h "$H_CC" --argjson now "$NOW" \
  '{schema: "cc-cmds-lease v1", kind: "grant", run_id: "rl", lineage: "s1", nonce: "n-rl", seq: 1, account: "cc",
    config_dir: $h, holders: [{pid: $pid, fp: $fp}], granted_at_epoch: $now,
    reservation_bp: {five_hour: 100, seven_day: 4000}, admitted_as: "known", basis: "first", observed: "tracker@1"}' \
  > "$PACE/leases/rl+s1.lease"
fleet dispatch cc >/dev/null 2>"$WORK/l-lease.err"
check "(i) 실제 표의 살아 있는 cc 임대가 7일 상한을 채우면 lend-ceiling" "$(grep -c '부적격 — lend-ceiling' "$WORK/l-lease.err" || true)" "1"
kill "$LHP" 2>/dev/null; wait "$LHP" 2>/dev/null
fleet dispatch cc >/dev/null 2>&1
check "(i) 그 보유자가 죽으면 같은 표에서 기동한다" "$(backlog_status ll1)" "done"

# --- (ii) the driver's reservation, counted at step 8 -----------------------------------
l_fresh d-l-driver ld1 '.accounts[0].windows.five_hour.utilization = 0.25'
fleet dispatch cc >/dev/null 2>"$WORK/l-driver.err"
check "(ii) 빈 표 + 드라이버 예약이면 5시간 5000 을 넘어 lend-cap" \
  "$(grep -c '부적격 — lend-cap (드라이버 예약을 센' "$WORK/l-driver.err" || true)/$(count_lines "$TEST_LOG_DIR/run.log")/$(backlog_status ld1)" "1/0/pending"
check "(ii) 드라이버 예약 거부는 거부 행을 남기지 않는다" "$(count_lines "$PACE/refusals.tsv")" "0"
l_fresh d-l-driver2 ld2 '.accounts[0].windows.five_hour.utilization = 0.19'
fleet dispatch cc >/dev/null 2>&1
check "(ii) 드라이버 예약을 세고도 5000 아래면 기동한다" "$(backlog_status ld2)" "done"

# --- markers: the ceiling is the u lanes', the lending lane holds one run ----------------
l_fresh d-l-ceil lc1
sleep 30 & MP1=$!; sleep 30 & MP2=$!; BG_PIDS="$BG_PIDS $MP1 $MP2"
mark u1 "$MP1" RA; mark u2 "$MP2" RB
fleet dispatch cc >/dev/null 2>&1
check "상한 면제: u 레인 둘이 살아 있어도 열린 cc 레인은 기동한다" "$(backlog_status lc1)" "done"
inv_write "$LEND_INV | $(acct_add_u3)"; lend_use "$(usage_u3)"
set_backlog "$(backlog_record lc2)"
fleet dispatch u3 >/dev/null 2>&1
check "상한 면제: 같은 때 u 셋째는 lane/ceiling" "$(cut -f3,6 "$PACE/refusals.tsv")" "$(printf 'lane\tceiling')"
rm -f "$PACE/busy/u2.$MP2"; mark cc "$MP2" RC
: > "$PACE/refusals.tsv"
fleet dispatch u3 >/dev/null 2>&1
check "E1: cc 표지는 u 레인의 상한에 세지 않는다 (u 하나 + cc 하나 → 기동)" "$(backlog_status lc2)" "done"
set_backlog "$(backlog_record lc3)"; rm -rf "$RUNDIR"
fleet dispatch cc >/dev/null 2>&1
check "E1: 자기 표지만 있는 cc 레인은 같은 레인 둘째 런을 lane/occupied 로 거부한다" "$(cut -f3,6 "$PACE/refusals.tsv")" "$(printf 'lane\toccupied')"

# --- E4: status splits the lending lane's markers ------------------------------------------
fleet agent status > "$WORK/l-status.out" 2>/dev/null
check "E4: 상한 줄은 대여 레인을 뺀 수다" "$(grep -c '^살아 있는 실행 표지: 1 / 상한 2$' "$WORK/l-status.out" || true)" "1"
check "E4: cc 레인 줄이 따로 찍힌다" "$(grep -c '^cc 레인 살아 있는 실행 표지: 1 / 점유 상한 1$' "$WORK/l-status.out" || true)" "1"
check "E4: 실행 표지 줄은 cc 표지도 찍는다" "$(grep -c "^실행 표지: cc.$MP2 (런 RC)$" "$WORK/l-status.out" || true)" "1"
check "E4: 등록이 없으면 레인 줄이 없다" "$(grep -c '레인 살아 있는 실행 표지' "$WORK/status.out" || true)" "0"
kill "$MP1" "$MP2" 2>/dev/null; wait "$MP1" "$MP2" 2>/dev/null; rm -rf "$PACE/busy"

# --- the backlog head: a cc-seat record, and a lending pin ------------------------------
d_fresh d-l-rec0 lr0
mkdir -p "$RUNDIR"; printf '%s\n' "$H_CC" > "$RUNDIR/config-dir"
fleet dispatch u1 >/dev/null 2>&1
check "등록 전: cc 좌석 기록 머리는 park lane-record" "$(backlog_field lr0 '.status + " " + .park_reason')" "parked lane-record"
for l in cc u1; do
  l_fresh "d-l-rec-$l" "lr-$l"
  mkdir -p "$RUNDIR"; printf '%s\n' "$H_CC" > "$RUNDIR/config-dir"
  fleet dispatch "$l" >/dev/null 2>&1
  check "등록 후: fleet-lane 없는 cc 좌석 기록 머리는 $l 레인에서 park lane-record" "$(backlog_field "lr-$l" '.status + " " + .park_reason')" "parked lane-record"
done
l_fresh d-l-pin-u lpu
mkdir -p "$RUNDIR"; printf '%s\n' "$H_CC" > "$RUNDIR/config-dir"; printf 'cc\n' > "$RUNDIR/fleet-lane"
fleet dispatch u1 >/dev/null 2>&1
check "fleet-lane=cc 머리는 u 레인에서 lane/lane-mismatch" "$(cut -f3,6 "$PACE/refusals.tsv")/$(backlog_status lpu)" "$(printf 'lane\tlane-mismatch')/pending"
fleet dispatch cc >/dev/null 2>&1
check "fleet-lane=cc 머리는 cc 레인이 받는다" "$(backlog_status lpu)" "done"
l_fresh d-l-new ln1
fleet dispatch cc >/dev/null 2>&1
check "기록 없는 새 머리는 cc 레인이 받고 fleet-lane 을 남긴다" "$(backlog_status ln1)/$(cat "$RUNDIR/fleet-lane" 2>/dev/null)" "done/cc"
rm -rf "$RUNDIR"

# --- (iii) the pin is written on the dispatch path only -------------------------------------
fn_body() { awk -v fn="$2" '$0 ~ "^" fn "\\(\\) *\\{" { on = 1 } on { print } on && /^}/ { exit }' "$1"; }
check "(iii) fleet-lane 을 쓰는 자리는 하나다" "$(grep -c 'fleet_write_atomic "\$run_dir/fleet-lane"' "$ORCH/fleet.sh" || true)" "1"
check "(iii) 그 자리는 공유 실행 함수 fleet_run_record 안이다" "$(fn_body "$ORCH/fleet.sh" fleet_run_record | grep -c 'fleet_write_atomic "\$run_dir/fleet-lane"' || true)" "1"
check "(iii) fleet_dispatch 와 repair-run 은 그 함수로 런을 돌린다" \
  "$(fn_body "$ORCH/fleet.sh" fleet_dispatch | grep -c '^ *fleet_run_record ' || true)/$(fn_body "$ORCH/fleet.sh" fleet_repair_run | grep -c '^ *fleet_run_record ' || true)" "2/1"
check "(iii) fleet_start_watch 는 fleet-lane 을 쓰지 않는다" "$(fn_body "$ORCH/fleet.sh" fleet_start_watch | grep -c 'fleet-lane' || true)" "0"
check "(iii) 부팅 재진입 경로는 fleet-lane 을 쓰지 않는다" \
  "$(for f in $(grep -oE '^fleet_reentry_[a-z_]+' "$ORCH/fleet.sh" | sort -u); do fn_body "$ORCH/fleet.sh" "$f"; done | grep -c 'fleet-lane' || true)" "0"

# ===========================================================================
# MASTER — the base-branch reading and the repair record it enqueues
# ===========================================================================
SLUG=o/n
TIP1=$(printf '%040d' 1); TIP2=$(printf '%040d' 2)
PRA=$(printf '%040d' 7); PRB=$(printf '%040d' 8); PRC=$(printf '%040d' 9)
MMAN="$WORK/M1.plan.md"
m_manifest() {
  # m_manifest <file> <run id> — a run manifest whose target row names o/n master.
  printf '<!-- cc-run-manifest v1; run-id=%s; owner-doc=docs/x.md; origin-worktree=%s; -->\n\n**설계 문서 전체 sha256**: %s\n\n- `target` | 별칭=repo | 메인 워크트리=%s | 공통 git 디렉터리=%s/.git | 베이스 브랜치=master | 홈=예 | 원격 슬러그=%s\n' \
    "$2" "$WT" "$DOC_SHA" "$WT" "$WT" "$SLUG" > "$1"
}
m_manifest "$MMAN" M1
MFILE_REL="master/o__n__master.json"
mf() { jq -r "$1" "$PACE/$MFILE_REL" 2>/dev/null; }
eid_of() { printf '%s\n%s\n' "$1" "$2" | shasum -a 256 | cut -c1-12; }
E1=$(eid_of "$TIP1" 'build|Run tests')
gh_tip() { printf '%s\n' "$1" > "$TEST_GH/tip"; }
gh_red() {
  # gh_red <sha> <job> — one failed Actions job on that commit, its failed
  # step `Run tests`, and a log.
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "1$2" 'build (1)' completed failure github-actions "https://github.com/$SLUG/actions/runs/5/job/$2" > "$TEST_GH/runs.$1"
  printf 'Run tests\n' > "$TEST_GH/steps.$2"
  printf 'log of %s\n' "$2" > "$TEST_GH/log.$2"
}
gh_green() { printf '%s\t%s\t%s\t%s\t%s\t%s\n' 21 'build (1)' completed success github-actions '' > "$TEST_GH/runs.$1"; }
gh_running() { printf '%s\t%s\t%s\t%s\t%s\t%s\n' 31 'build (1)' in_progress '' github-actions '' > "$TEST_GH/runs.$1"; }
gh_calls() { grep -c -- "$1" "$TEST_GH/calls" 2>/dev/null || true; }
m_fresh() {
  # m_fresh <name> — an admitting scenario whose one pending record's manifest
  # names o/n master, a clean remote at TIP1, and no repair manifests or runs.
  d_fresh "$1" m1; set_backlog "$(backlog_record m1 ".manifest_path = \"$MMAN\"")"
  rm -rf "$TEST_GH" "$TEST_REPAIR_DIR" "$WORK/xdg/cc-cmds/run"/rr-*; mkdir -p "$TEST_GH"; : > "$TEST_GH/pulls"
  : > "$WORK/master.err"
  gh_tip "$TIP1"
}
m_round() {
  # One master stage, through a lane that is not eligible: the stage runs at
  # the top of every dispatch tick, before eligibility. The reading is aged
  # first so the round does not skip the pair.
  [ ! -e "$PACE/$MFILE_REL" ] || touch -t 202001010000 "$PACE/$MFILE_REL"
  fleet dispatch cc >/dev/null 2>>"$WORK/master.err"
}
repair_recs() { jq -r 'select(.kind == "master-repair") | .id' "$PACE/backlog.jsonl" | count_lines /dev/stdin; }
rec_set() {
  # rec_set <jq> — rewrite the E1 repair record in place.
  jq -c --arg id "mr-$E1" "if .id == \$id then $1 else . end" "$PACE/backlog.jsonl" > "$PACE/backlog.new" \
    && mv "$PACE/backlog.new" "$PACE/backlog.jsonl"
}
young() { local m; m=$(date -u -r "$1" +%s 2>/dev/null || printf 0); [ $(( $(date -u +%s) - m )) -lt 60 ] && printf yes || printf no; }

# --- a settled reading opens an event; 진행 중 opens nothing ---------------------
m_fresh m-open
gh_running "$TIP1"; m_round
check "진행 중 판독은 새 tip 을 싣고 사건을 열지 않는다" \
  "$(mf '.schema + "/" + .state + "/" + .tip + "/" + (.events | length | tostring)')" "cc-master-state v1/진행 중/$TIP1/0"
gh_red "$TIP1" 101; m_round
check "빨강 판독은 서명과 정밀도를 싣는다 (범용 어댑터: 단계)" "$(mf '.state + "/" + .precision + "/" + (.signatures | join(","))')" "빨강/단계/build|Run tests"
check "사건 하나가 열린다 — id 는 첫 커밋 줄과 정렬된 서명 줄의 sha256 앞 12자" \
  "$(mf '[.events[] | .id + "/" + .first_commit + "/" + (.checks | join(","))] | join(" ")')" "$E1/$TIP1/build (1)"
check "관측 시각은 라운드 시각이다" "$(mf '.observed_at + "/" + (.observed_at_epoch | tostring)')" "$(iso "$NOW")/$NOW"
check "수리 런이 렌더되어 사건은 띄움이고 run_id 는 렌더한 런이다" "$(mf '.events[0].repair | .state + "/" + .run_id')" "띄움/rr-$E1"
check "수리 레코드 하나가 pending 으로 적재된다" \
  "$(backlog_field "mr-$E1" '.kind + "/" + .status + "/" + .event_id + "/" + .slug + "/" + .base + "/" + .doc_sha256 + "/" + .lane')" \
  "master-repair/pending/$E1/o/n/master/(해당 없음)/"
check "레코드의 적재·인가 시각은 렌더 시각이고 기준 커밋은 워크트리 HEAD 다" \
  "$(backlog_field "mr-$E1" '[.enqueued_at == .authorized_at, .enqueued_at, .base_commit] | map(tostring) | join("/")')" "true/$(iso "$NOW")/$BASE"
check "렌더러는 사건 id·첫 커밋·워크트리를 받는다" "$(grep -c -- "--event $E1 .*--first-commit $TIP1 --worktree $WT" "$TEST_LOG_DIR/repair.log" || true)" "1"
check "실패 job 의 로그는 한 번 읽힌다" "$(gh_calls '/logs')" "1"
m_round
check "같은 tip 의 같은 실패 묶음은 로그를 다시 읽지 않는다" "$(gh_calls '/logs')" "1"
check "열린 사건의 서명은 사건을 다시 열지 않는다" "$(mf '.events | length')" "1"
check "사건마다 레코드는 하나다 — 렌더도 다시 하지 않는다" "$(repair_recs)/$(count_lines "$TEST_LOG_DIR/repair.log")" "1/1"
calls=$(count_lines "$TEST_GH/calls")
fleet dispatch cc >/dev/null 2>&1
check "주기 절반보다 젊은 판독의 쌍은 그 라운드에 읽지 않는다" "$(count_lines "$TEST_GH/calls")" "$calls"
touch "$TEST_GH/down"; m_round; rm -f "$TEST_GH/down"
check "판정 불가는 앞 판독의 tip·서명·사건을 그대로 둔다" \
  "$(mf '.state + "/" + .tip + "/" + (.signatures | join(",")) + "/" + (.events | length | tostring) + "/" + (.events[0].resolved_at | tostring)')" \
  "판정 불가/$TIP1/build|Run tests/1/null"
gh_tip "$TIP2"; gh_running "$TIP2"; m_round
check "진행 중은 새 tip 을 싣되 사건을 해소하지 않는다" "$(mf '.state + "/" + .tip + "/" + (.events[0].resolved_at | tostring)')" "진행 중/$TIP2/null"
gh_green "$TIP2"; m_round
check "결론 난 초록은 사건을 해소한다" \
  "$(mf '.state + "/" + .events[0].resolved_commit + "/" + .events[0].repair.state + "/" + (.events[0].resolved_at != null | tostring)')" "초록/$TIP2/해소/true"

# --- the repair state follows the record, every round ---------------------------
m_fresh m-rec; gh_red "$TIP1" 101; m_round
rec_set ".deadline = \"$(iso $(( NOW - 60 )))\""; m_round
check "마감이 지난 pending 레코드 → 띄울 수 없음" "$(mf '.events[0].repair | .state + "/" + .reason')" "띄울 수 없음/마감 지난 레코드"
rec_set '.status = "parked" | .park_reason = "doc-changed"'; m_round
check "park 된 레코드 → 띄울 수 없음, 사유는 park 토큰" "$(mf '.events[0].repair | .state + "/" + .reason')" "띄울 수 없음/park doc-changed"
rec_set '.status = "dispatched" | .dispatched_lane = "u1"'; m_round
check "런 디렉터리도 산 표지도 없는 dispatched 는 pending 으로 되돌아가고 띄움이다" \
  "$(backlog_status "mr-$E1")/$(backlog_field "mr-$E1" '.dispatched_lane | tostring')/$(mf '.events[0].repair.state')" "pending/null/띄움"
rec_set '.status = "done"'; mkdir -p "$WORK/xdg/cc-cmds/run/rr-$E1"; touch -t 202001010000 "$WORK/xdg/cc-cmds/run/rr-$E1/done"; m_round
check "해소 없이 끝난 수리 런 → 띄울 수 없음, 끝 행의 원인 토큰과 함께" "$(mf '.events[0].repair | .state + "/" + .reason')" "띄울 수 없음/수리 런이 해소 없이 끝남 (-)"
check "어느 라운드도 같은 사건의 레코드를 다시 적재하지 않는다" "$(repair_recs)" "1"

# --- the switch, and a render failure that stays -----------------------------------
m_fresh m-switch; : > "$PACE/master-repair.off"; gh_red "$TIP1" 101; m_round
check "빈 master-repair.off 는 모든 저장소의 수리 런을 막는다" "$(mf '.events[0].repair | .state + "/" + .reason')/$(repair_recs)" "띄울 수 없음/끄는 스위치/0"
printf 'other/repo\n' > "$PACE/master-repair.off"; m_round
check "다른 슬러그만 적힌 스위치는 이 저장소를 막지 않는다" "$(mf '.events[0].repair.state')/$(repair_recs)" "띄움/1"
m_fresh m-render; gh_red "$TIP1" 101
TEST_REPAIR_FAIL='템플릿을 읽지 못했다' m_round
check "렌더 실패 → 띄울 수 없음, 사유는 렌더러의 마지막 줄" "$(mf '.events[0].repair | .state + "/" + .reason')" "띄울 수 없음/렌더 실패 — repair: 템플릿을 읽지 못했다"
m_round
check "렌더 실패는 다음 라운드에 다시 렌더하지 않는다" "$(count_lines "$TEST_LOG_DIR/repair.log")/$(repair_recs)/$(mf '.events[0].repair.state')" "1/0/띄울 수 없음"

# --- a person's fix PR holds the repair run, 7200 seconds once per event ----------
m_fresh m-pr; gh_red "$TIP1" 101
printf '8\tbehind-branch\t%s\n7\tfix-branch\t%s\n' "$PRB" "$PRA" > "$TEST_GH/pulls"
printf 'behind\n' > "$TEST_GH/compare.$PRB"; gh_green "$PRB"
printf 'ahead\n' > "$TEST_GH/compare.$PRA"; gh_green "$PRA"
m_round
check "사건의 체크가 돌고 그 서명이 없는 베이스 포함 PR 은 수리 런을 보류한다" \
  "$(mf '.events[0] | .repair.state + "/" + (.repair.pr | tostring) + "/" + .hold_started_at')/$(repair_recs)" "보류/7/$(iso "$NOW")/0"
NOW_SAVE=$NOW
NOW=$(( NOW_SAVE + 3600 )); m_round
check "보류 시작 시각은 한 번만 적힌다" "$(mf '.events[0] | .hold_started_at + "/" + .repair.state')" "$(iso "$NOW_SAVE")/보류"
NOW=$(( NOW_SAVE + 7300 )); m_round; NOW=$NOW_SAVE
check "보류 7200초가 지나면 PR 이 있어도 수리 런을 적재한다" "$(mf '.events[0].repair | .state + "/" + (.pr | tostring)')/$(repair_recs)" "띄움/null/1"
m_fresh m-pr-red; gh_red "$TIP1" 101
printf '9\tstill-red\t%s\n' "$PRC" > "$TEST_GH/pulls"; printf 'ahead\n' > "$TEST_GH/compare.$PRC"; gh_red "$PRC" 102
m_round
check "사건의 서명으로 실패하는 PR 은 보류하지 않는다" "$(mf '.events[0].repair.state')/$(repair_recs)" "띄움/1"

# --- master.lock: a live holder skips the round, a dead or stale one is broken ------
m_fresh m-lock; gh_red "$TIP1" 101
sleep 30 & LKP=$!; BG_PIDS="$BG_PIDS $LKP"
mkdir -p "$PACE/master.lock"; printf '%s\n' "$LKP" > "$PACE/master.lock/pid"
m_round
[ -e "$PACE/$MFILE_REL" ] && bad "산 보유자의 젊은 master.lock 이면 그 라운드는 아무것도 읽지 않는다" "판독이 쓰였다" \
  || ok "산 보유자의 젊은 master.lock 이면 그 라운드는 아무것도 읽지 않는다"
touch -t 202001010000 "$PACE/master.lock"; m_round
check "보유자가 살아 있어도 묵은 master.lock 은 깨고 읽는다" "$(mf .state)" "빨강"
kill "$LKP" 2>/dev/null; wait "$LKP" 2>/dev/null
mkdir -p "$PACE/master.lock"; printf '%s\n' "$LKP" > "$PACE/master.lock/pid"; : > "$WORK/master.err"
m_round
check "죽은 pid 의 master.lock 은 그 라운드에 깨지고 판독이 다시 쓰인다" \
  "$(grep -c 'master.lock 을 깬다' "$WORK/master.err" || true)/$(young "$PACE/$MFILE_REL")" "1/yes"
[ -d "$PACE/master.lock" ] && bad "라운드가 끝나면 master.lock 이 남지 않는다" "남아 있다" || ok "라운드가 끝나면 master.lock 이 남지 않는다"

# ===========================================================================
# REPAIR ADMISSION — the repair run's own seat, beside the ceiling
# ===========================================================================
r_fresh() {
  # r_fresh <name> [only] — one rendered pending repair record for E1; with
  # `only` the ordinary record is dropped so an ordinary tick has no head.
  m_fresh "$1"; gh_red "$TIP1" 101; m_round; clear_logs
  if [ "${2:-}" = only ]; then
    jq -c 'select(.kind == "master-repair")' "$PACE/backlog.jsonl" > "$PACE/backlog.new" && mv "$PACE/backlog.new" "$PACE/backlog.jsonl"
  fi
}
r_fresh r-ceil
sleep 60 & RP1=$!; sleep 60 & RP2=$!; BG_PIDS="$BG_PIDS $RP1 $RP2"
mark u1 "$RP1" X1; mark u2 "$RP2" X2
fleet dispatch u1 >/dev/null 2>&1
check "상한이 찬 함대에서도 수리 레코드는 자기 자리로 기동한다" "$(backlog_field "mr-$E1" '.status + "/" + .dispatched_lane')" "done/u1"
check "기동한 것은 수리 매니페스트의 런 하나다" \
  "$(grep -c "run --manifest $TEST_REPAIR_DIR/rr-$E1.plan.md" "$TEST_LOG_DIR/run.log" || true)/$(count_lines "$TEST_LOG_DIR/run.log")" "1/1"
check "그 틱은 보통 머리를 기동하지 않는다" "$(backlog_status m1)" "pending"
check "끝나면 수리 표지가 남지 않는다" "$(ls "$PACE/busy" | tr '\n' ' ')" "u1.$RP1 u2.$RP2 "
kill "$RP1" "$RP2" 2>/dev/null; wait "$RP1" "$RP2" 2>/dev/null

r_fresh r-seat only
sleep 60 & RP3=$!; BG_PIDS="$BG_PIDS $RP3"
mark u2 "$RP3" rr-other; printf 'master-repair\n1\n' >> "$PACE/busy/u2.$RP3"
fleet dispatch u1 >/dev/null 2>"$WORK/r-seat.err"
check "산 수리 표지가 자리 수만큼이면 거부 행 repair-seat, 판정 칸은 -" "$(cut -f2-4,6 "$PACE/refusals.tsv")" "$(printf 'u1\trepair-seat\t-\t-')"
check "거부된 수리 레코드는 pending 으로 남고 거부 절을 싣는다" \
  "$(backlog_field "mr-$E1" '.status + "/" + .last_refusal_clause + "/" + .last_refusal_verdict')" "pending/repair-seat/-"
check "보통 머리는 수리 레코드를 집지 않는다" "$(grep -c 'pending 레코드가 없다' "$WORK/r-seat.err" || true)/$(count_lines "$TEST_LOG_DIR/run.log")" "1/0"
kill "$RP3" 2>/dev/null; wait "$RP3" 2>/dev/null
fleet dispatch u1 >/dev/null 2>&1
check "수리 자리가 비면 다음 틱에 기동한다" "$(backlog_status "mr-$E1")" "done"

repair_append() {
  # repair_append <event id> — render with the stub and append the record the
  # master stage would, under backlog.lock (the lanes may be rewriting it).
  local out m at dl rec n=0
  out=$(bash "$FX/repair.sh" render --slug "$SLUG" --base master --event "$1" --worktree "$WT")
  m=$(printf '%s\n' "$out" | sed -n 's/^manifest=//p'); at=$(printf '%s\n' "$out" | sed -n 's/^rendered_at=//p')
  dl=$(printf '%s\n' "$out" | sed -n 's/^deadline=//p')
  rec=$(jq -cn --arg e "$1" --arg m "$m" --arg at "$at" --arg dl "$dl" --arg bc "$BASE" '
    {schema: "cc-pace-backlog v1", id: ("mr-" + $e), kind: "master-repair", event_id: $e, slug: "o/n", base: "master",
     status: "pending", enqueued_at: $at, authorized_at: $at, deadline: $dl, base_commit: $bc,
     doc_sha256: "(해당 없음)", manifest_path: $m, lane: ""}')
  until mkdir "$PACE/backlog.lock" 2>/dev/null; do [ "$n" -lt 50 ] || return 1; sleep 0.2; n=$(( n + 1 )); done
  printf '%s\n' "$rec" >> "$PACE/backlog.jsonl"; rm -rf "$PACE/backlog.lock"
}
EA=aaaaaaaaaaa1; EB=bbbbbbbbbbb2; EX=ccccccccccc3
wait_for() {
  # wait_for <seconds> <command…> — poll the fixture until the command succeeds.
  local lim=$(( $1 * 5 )) n=0; shift
  until "$@"; do [ "$n" -lt "$lim" ] || return 1; sleep 0.2; n=$(( n + 1 )); done
}
run_started() { [ "$(count_lines "$TEST_LOG_DIR/run.log")" != 0 ]; }
rec_there() { [ -n "$(backlog_field "mr-$E1" .status 2>/dev/null)" ]; }
fx_procs() { pgrep -f "$FX/fleet.sh (master-watch|repair-run)" | count_lines /dev/stdin; }
r_dispatched() { [ "$(backlog_status "mr-$1")" = dispatched ] || [ "$(backlog_status "mr-$1")" = done ]; }

# Two live runs fill the ceiling; two repair records: the first takes the
# repair seat, the second is refused while the first runs.
m_fresh r-two; set_backlog
sleep 60 & RP4=$!; sleep 60 & RP5=$!; BG_PIDS="$BG_PIDS $RP4 $RP5"
mark u1 "$RP4" X1; mark u2 "$RP5" X2
repair_append "$EA"; repair_append "$EB"
TEST_REPAIR_RUN_SLEEP=4 fleet dispatch u1 >/dev/null 2>"$WORK/r-two-u1.err" &
r2_u1=$!; BG_PIDS="$BG_PIDS $r2_u1"
wait_for 10 r_dispatched "$EA"
fleet dispatch u2 >/dev/null 2>"$WORK/r-two-u2.err"
check "상한이 찬 함대에서 첫 수리 레코드는 dispatched" "$(backlog_field "mr-$EA" '.status + "/" + .dispatched_lane')" "dispatched/u1"
check "같은 때 둘째 수리 레코드는 repair-seat 거부 행을 남기고 pending 이다" \
  "$(awk -F'\t' -v id="mr-$EB" '$3 == "repair-seat" && $5 == id { n++ } END { print (n > 0) ? "있다" : "없다" }' "$PACE/refusals.tsv")/$(backlog_status "mr-$EB")" "있다/pending"
wait "$r2_u1"
check "첫 수리 런은 끝나 done 이고 둘째는 그동안 뜨지 않았다" \
  "$(backlog_status "mr-$EA")/$(grep -c "rr-$EB" "$TEST_LOG_DIR/run.log" || true)" "done/0"
kill "$RP4" "$RP5" 2>/dev/null; wait "$RP4" "$RP5" 2>/dev/null

r_fresh r-window only; usage_write '.accounts[1].windows.five_hour.utilization = 0.80'
fleet dispatch u1 >/dev/null 2>&1
check "5시간 창이 닫힌 계정에서는 수리 레코드도 거부된다 (window)" "$(cut -f3,4,6 "$PACE/refusals.tsv")/$(backlog_status "mr-$E1")" "$(printf 'window\t-\tover')/pending"
r_fresh r-switch only; printf 'o/n\n' > "$PACE/master-repair.off"
fleet dispatch u1 >/dev/null 2>&1
check "스위치가 끈 저장소의 수리 레코드는 거부된다 (switch)" "$(cut -f3,6 "$PACE/refusals.tsv")/$(backlog_status "mr-$E1")" "$(printf 'switch\t-')/pending"
d_fresh r-unrec x0
set_backlog "$(backlog_record mr-x '.kind = "master-repair" | .event_id = "abcdef012345" | .slug = "o/n" | .base = "master"')"
fleet dispatch u1 >/dev/null 2>&1
check "수리 사건 행이 없는 매니페스트의 수리 레코드는 park repair-unrecognized" \
  "$(backlog_field mr-x '.status + " " + .park_reason')/$(count_lines "$TEST_LOG_DIR/run.log")" "parked repair-unrecognized/0"

# --- the observer child: a repair run while every lane's own run is going ---------
# Both lanes hold a run; a repair record appended meanwhile is taken by one of
# their observer children, and the repair run outlives both lane runs.
m_fresh r-both; gh_green "$TIP1"; m_manifest "$WORK/M2.plan.md" M2
set_backlog "$(backlog_record m1 ".manifest_path = \"$MMAN\"")" "$(backlog_record m2 ".manifest_path = \"$WORK/M2.plan.md\"")"
for l in u1 u2; do
  TEST_RUN_SLEEP=3 TEST_REPAIR_RUN_SLEEP=8 FLEET_MASTER_INTERVAL_TEST_SECONDS=2 fleet dispatch "$l" >/dev/null 2>"$WORK/r-both-$l.err" &
  eval "rb_$l=\$!"; eval "BG_PIDS=\"\$BG_PIDS \$rb_$l\""
done
runs_two() { [ "$(count_lines "$TEST_LOG_DIR/run.log")" -ge 2 ]; }
wait_for 10 runs_two
repair_append "$EX"
wait_for 15 r_dispatched "$EX"
check "두 레인이 모두 런을 쥔 동안 덧붙인 수리 레코드는 몇 회차 안에 dispatched 다" "$(r_dispatched "$EX" && echo 예 || echo 아니오)" "예"
rl=$(backlog_field "mr-$EX" .dispatched_lane)
other=u1; [ "$rl" != u1 ] || other=u2
eval "wait \"\$rb_$rl\""
check "수리 런을 띄운 잡은 자기 런이 끝난 뒤에도 수리 런이 끝날 때까지 남는다 — 그 잡이 끝난 때 레코드는 done" \
  "$(backlog_status "mr-$EX")" "done"
eval "wait \"\$rb_$other\""
check "두 레인의 런과 수리 런이 한 번씩 돈다" \
  "$(backlog_status m1)/$(backlog_status m2)/$(grep -c "run --manifest $TEST_REPAIR_DIR/rr-$EX.plan.md" "$TEST_LOG_DIR/run.log" || true)" "done/done/1"
check "잡이 끝나면 master-watch·repair-run 프로세스가 남지 않는다" "$(fx_procs)" "0"
check "잡이 끝나면 실행 표지와 관측 자식의 자리가 남지 않는다" "$(ls "$PACE/busy" 2>/dev/null | count_lines /dev/stdin)/$(ls -d "$PACE/master"/watch.* 2>/dev/null | count_lines /dev/stdin)" "0/0"

# The base breaking while one lane runs: the observer child's own reading
# enqueues the record, and an idle lane's tick races the child for it.
m_fresh r-race; gh_green "$TIP1"
TEST_RUN_SLEEP=5 FLEET_MASTER_INTERVAL_TEST_SECONDS=2 fleet dispatch u1 >/dev/null 2>"$WORK/r-race.err" &
rr_u1=$!; BG_PIDS="$BG_PIDS $rr_u1"
wait_for 10 run_started
gh_red "$TIP1" 101
wait_for 15 rec_there
TEST_RUN_SLEEP=5 fleet dispatch u2 >/dev/null 2>"$WORK/r-race-u2.err" &
rr_u2=$!; BG_PIDS="$BG_PIDS $rr_u2"
wait "$rr_u1" "$rr_u2"
check "쉬는 레인의 틱과 관측 자식이 함께 집어도 수리 런은 한 번 돈다" \
  "$(grep -c "run --manifest $TEST_REPAIR_DIR/rr-$E1.plan.md" "$TEST_LOG_DIR/run.log" || true)/$(backlog_status "mr-$E1")" "1/done"
check "경합 뒤에도 프로세스가 남지 않는다" "$(fx_procs)" "0"

# --- the observer child keeps the reading fresh; one stage at a time ---------------
# The real clock, so each round's observed_at is its own.
NOW=$(date -u +%s); export TEST_NOW="$NOW"
m_fresh r5; m_manifest "$WORK/M2.plan.md" M2
set_backlog "$(backlog_record m1 ".manifest_path = \"$MMAN\"")" "$(backlog_record m2 ".manifest_path = \"$WORK/M2.plan.md\"")"
gh_red "$TIP1" 101
for l in u1 u2; do
  FLEET_NOW_PIN='' TEST_RUN_SLEEP=8 FLEET_MASTER_INTERVAL_TEST_SECONDS=2 fleet dispatch "$l" >/dev/null 2>"$WORK/r5-$l.err" &
  eval "r5_$l=\$!"; eval "BG_PIDS=\"\$BG_PIDS \$r5_$l\""
done
seen=""; holders=0
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14; do
  sleep 0.5
  o=$(mf .observed_at); [ -z "$o" ] || seen=$(printf '%s\n%s' "$seen" "$o")
  if [ -d "$PACE/master.lock" ]; then
    h=$(count_lines "$PACE/master.lock/pid"); [ "$h" -le "$holders" ] || holders=$h
  fi
done
wait "$r5_u1" "$r5_u2"
n_seen=$(printf '%s\n' "$seen" | grep -v '^$' | sort -u | count_lines /dev/stdin)
[ "$n_seen" -ge 3 ] && ok "관측 자식이 도는 동안 observed_at 이 두 번 이상 바뀐다 ($n_seen 가지)" \
  || bad "관측 자식이 도는 동안 observed_at 이 두 번 이상 바뀐다" "값 $n_seen 가지"
[ "$holders" -le 1 ] && ok "master.lock 의 보유자는 언제나 하나 이하다" || bad "master.lock 의 보유자는 언제나 하나 이하다" "$holders"
check "런이 끝나면 master-watch 프로세스가 남지 않는다" "$(fx_procs)" "0"
[ -d "$PACE/master.lock" ] && bad "런이 끝나면 master.lock 이 남지 않는다" "남아 있다" || ok "런이 끝나면 master.lock 이 남지 않는다"

# ===========================================================================
# SOURCE GREPS
# ===========================================================================
check "fleet.sh 는 드라이버의 분리 실행 헬퍼를 부르지 않는다" "$(grep -c 'cc_detach_exec' "$ORCH/fleet.sh" || true)" "0"
check "fleet.sh 는 알림기를 부르지 않는다" "$(grep -c -i -e 'notify' -e 'terminal-notifier' "$ORCH/fleet.sh" || true)" "0"
check "fleet.sh 는 nohup 을 쓰지 않는다" "$(grep -c 'nohup' "$ORCH/fleet.sh" || true)" "0"
check "워처 기동 줄은 정확히 하나다" "$(grep -c 'watch\.sh" --run-dir' "$ORCH/fleet.sh" || true)" "1"
check "run.sh 는 앞단(&) 없이 불린다" "$(grep -c 'run\.sh" --manifest "\$manifest".*&$' "$ORCH/fleet.sh" || true)" "0"
check "run.sh 를 부르는 줄은 공유 실행 함수 안의 하나다" \
  "$(grep -c 'bash "\$FLEET_DIR/run\.sh"' "$ORCH/fleet.sh" || true)/$(fn_body "$ORCH/fleet.sh" fleet_run_record | grep -c 'bash "\$FLEET_DIR/run\.sh"' || true)" "1/1"
check "repair-run 배경 기동 줄은 하나이고 수리 기동 함수 안에 있다" \
  "$(grep -c 'fleet\.sh" repair-run .*&$' "$ORCH/fleet.sh" || true)/$(fn_body "$ORCH/fleet.sh" fleet_master_repair_launch | grep -c 'fleet\.sh" repair-run .*&$' || true)" "1/1"
check "master-watch 배경 기동 줄은 하나이고 fleet_start_watch 안에 있다" \
  "$(grep -c 'fleet\.sh" master-watch .*&$' "$ORCH/fleet.sh" || true)/$(fn_body "$ORCH/fleet.sh" fleet_start_watch | grep -c 'fleet\.sh" master-watch .*&$' || true)" "1/1"
check "master 읽기 래퍼는 쓰기 자격 함수를 부르지 않는다" "$(grep -c 'cred_gate_env' "$ORCH/fleet.sh" || true)" "0"
for gone in cci HamedElfayome 978307200 FLEET_SEAT_HOMES TRACKER_PLIST; do
  check "fleet.sh 에 $gone 이 없다" "$(grep -c "$gone" "$ORCH/fleet.sh" || true)" "0"
done

printf '\ntest-fleet: %d passed, %d failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
