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
#   source greps              — no detach helper, no notifier, one watcher line,
#                               none of the removed seat names
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
# A slow driver keeps the dispatch job — and its run marker — alive.
[ -n "${TEST_RUN_SLEEP:-}" ] && sleep "$TEST_RUN_SLEEP"
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
  # fleet <args...> — the actor under the fixture's environment.
  FLEET_PACE_ROOT="$PACE" FLEET_PLUTIL="$WORK/bin/plutil" FLEET_LAUNCHCTL="$WORK/bin/launchctl" \
  FLEET_LAUNCH_AGENTS_DIR="$WORK/agents" FLEET_LANE_PROBE="$WORK/bin/lane-probe.sh" FLEET_NOW_EPOCH="$NOW" \
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
check "워처 인자는 autopilot 의 기동 줄과 같은 네 임계를 싣는다" "$(sed -n '1p' "$TEST_LOG_DIR/watch.log")" "watch --run-dir $RUNDIR --ledger $WT_MAIN/docs/pipeline-run/R1.md --stall 1200 --interval 60 --after-stage 120 --run-open 300"
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
# SOURCE GREPS
# ===========================================================================
check "fleet.sh 는 드라이버의 분리 실행 헬퍼를 부르지 않는다" "$(grep -c 'cc_detach_exec' "$ORCH/fleet.sh" || true)" "0"
check "fleet.sh 는 알림기를 부르지 않는다" "$(grep -c -i -e 'notify' -e 'terminal-notifier' "$ORCH/fleet.sh" || true)" "0"
check "fleet.sh 는 nohup 을 쓰지 않는다" "$(grep -c 'nohup' "$ORCH/fleet.sh" || true)" "0"
check "워처 기동 줄은 정확히 하나다" "$(grep -c 'watch\.sh" --run-dir' "$ORCH/fleet.sh" || true)" "1"
check "run.sh 는 앞단(&) 없이 불린다" "$(grep -c 'run\.sh" --manifest "\$manifest".*&$' "$ORCH/fleet.sh" || true)" "0"
for gone in cci HamedElfayome 978307200 FLEET_SEAT_HOMES TRACKER_PLIST; do
  check "fleet.sh 에 $gone 이 없다" "$(grep -c "$gone" "$ORCH/fleet.sh" || true)" "0"
done

printf '\ntest-fleet: %d passed, %d failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
