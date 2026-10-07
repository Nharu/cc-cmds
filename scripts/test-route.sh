#!/usr/bin/env bash
# lint-bash-portability: self-skip
# 계정 라우터 `plugins/cc-cmds/orchestrator/route.sh` 의 시험.
#
# 라우터는 휴면 스위치 아래에 실려 있어 제품 경로 어디에서도 불리지 않는다. 그래서
# 이 파일이 그 코드의 유일한 실행자이고, 뒤 슬라이스는 이 파일을 고칠 수 없으므로
# 스위치가 1 로 뒤집힌 뒤에도 같은 단언이 초록이어야 한다.
#
# 무엇을 왜 단언하는가:
#   정적 검사        — route.sh 가 있고 `run.sh` 소싱 뒤 `route_resolve` 가 정의된다.
#                      파일이 지워져도 소싱 줄은 비영만 내고 계속되므로 이 단언이 잡는다.
#                      이름 접두, 단독 진입 분기, pipefail 아래의 `| grep -q` 부재.
#   가드와 휴면 계약 — 가드 0·1 × 인벤토리 부재·유효·깨짐, 출하 값을 읽는 사례 하나,
#                      미리 심은 스위치, 해석기 네 단의 바이트 동일 행렬과 계약 (a)–(e),
#                      후행 개행과 잘못된 UTF-8 값, 해석기 한 번, 휴면 경로의 임대 입출력 0.
#                      이 절은 스위치를 1 로 뒤집은 스크래치 사본으로 한 번 더 돌고
#                      두 실행의 단언 수가 같아야 한다.
#   입력 판독        — 인벤토리 분류기의 사유별 거부, 사용량 두 신선도 층과 재정의,
#                      차용 기록의 여섯 상태와 무부작용·문맥 수집, 로그 프레임의
#                      필드·관측 시각·귀속, 판독 시점 병합과 그룹.
#   선택 규칙        — 부류 순위, 그룹 예약 전파, draining, 재개·유지·한도 회수, 후보
#                      없음, 교대, 마감, FIFO, 차용 기증자·그룹 배제와 좌석 표시.
#   예약 산술        — 정수 bp 경계, 창마다 독립인 `k`, 5시간 상한, `c` 의 낙하, 미지
#                      그룹 동시 1, 리셋이 돌려주지 않는 예약, 출하 상수의 전달.
#                      `k`·`c`·상한은 문맥으로 주입하고 출하 리터럴을 단언하지 않는다.
#   임대 표          — 세 상태와 처분, 대기 프리미티브, 생존 네 갈래, 반납·보유자 규칙,
#                      stale-깨짐, 모르는 kind, 키 인코더, 락과 거래 프로세스, 재검증과
#                      경합, 임대 쓰기 뒤 차용 재판독과 복원, 실패 경로, 지문의 TZ 고정.
#   전역 충돌 린트   — 소스 줄 파생의 네 스크래치 트리와 case 갈래 머리 이름 추출.
#
# 격리: HOME·XDG_CONFIG_HOME·XDG_STATE_HOME·RUN_PACE_ROOT 를 $WORK 아래로 두고
# CLAUDE_CONFIG_DIR 을 지운다. `run.sh` 는 부분 셸에서 소싱만 하고 `bash` 로 부르지
# 않는다. 모음 끝에 실제 HOME 의 pace 디렉터리에 임대 표가 생기지 않았음을 본다.
#
# 부분 셸에서 난 단언도 세야 하므로 결과는 파일 한 줄씩으로 모은다.
#
# Usage: bash scripts/test-route.sh
#        TEST_ROUTE_QUIET=1 bash scripts/test-route.sh   # 실패와 요약만 출력

set -uo pipefail

# run.sh 를 소싱만 하고 드라이버로 돌리지 않지만, 소싱한 함수가 알림 경로에 닿는
# 날이 와도 배너가 사용자 화면에 가지 않도록 채널을 프로세스 수준에서 끈다.
CC_CMDS_AUTOPILOT_NOTIFY=0
export CC_CMDS_AUTOPILOT_NOTIFY

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
TR_ORCH="$repo_root/plugins/cc-cmds/orchestrator"
TR_ROUTE="$TR_ORCH/route.sh"
# 소싱할 run.sh 는 이 한 변수에서 정한다. 가드 절은 이 경로와, 스위치를 뒤집은
# 스크래치 사본의 경로로 각각 한 번씩 돈다.
TR_RUN_SH="$TR_ORCH/run.sh"
TR_LINT="$script_dir/lint-harness-global-collisions.sh"
LEASE_SCHEMA='cc-cmds-lease v1'

TR_REAL_PACE="${XDG_STATE_HOME:-$HOME/.local/state}/cc-cmds/pace"
TR_REAL_PACE_EXISTED=0
[ -e "$TR_REAL_PACE" ] && TR_REAL_PACE_EXISTED=1
TR_REAL_LEASES_EXISTED=0
[ -e "$TR_REAL_PACE/leases" ] && TR_REAL_LEASES_EXISTED=1

WORK=$(mktemp -d "${TMPDIR:-/tmp}/cc-route-test.XXXXXX")
TR_PIDS=""
tr_cleanup() {
  local p
  for p in $TR_PIDS; do kill "$p" 2>/dev/null; done
  chmod -R u+rwx "$WORK" 2>/dev/null
  rm -rf "$WORK"
}
trap tr_cleanup EXIT

export HOME="$WORK/home"
export XDG_CONFIG_HOME="$WORK/xdg-config"
export XDG_STATE_HOME="$WORK/state"
export RUN_PACE_ROOT="$WORK/state/cc-cmds/pace"
unset CLAUDE_CONFIG_DIR RUN_DIR
mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_STATE_HOME"

# 실측 571(root 가 아닐 때). root 는 권한 사례 여섯을 건너뛴다.
ASSERTION_FLOOR=550
RESULTS="$WORK/results"
SEEN="$WORK/seen"
: > "$RESULTS"
: > "$SEEN"

ok()    { printf 'PASS\t%s\n' "$1" >> "$RESULTS"; [ -n "${TEST_ROUTE_QUIET:-}" ] || printf 'PASS: %s\n' "$1"; }
bad()   { printf 'FAIL\t%s\n' "$1" >> "$RESULTS"; printf 'FAIL: %s — %s\n' "$1" "${2:-}" >&2; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got '$2', want '$3'"; fi; }
seen()  {
  printf '%s' "$1" | jq -r 'select(type == "object" and (.verdict | type) == "string")
    | "\(.verdict) \(.basis // .reason // "")"' >> "$SEEN" 2>/dev/null || true
}
# expect <이름> <JSON> <jq 식> — 식이 참이어야 한다. 봉투의 판정 토큰을 부류 포괄에 적는다.
expect() {
  if printf '%s' "$2" | jq -e "$3" >/dev/null 2>&1; then ok "$1"; else bad "$1" "$3 가 거짓: $2"; fi
  seen "$2"
}
count_results() { local n; n=$(grep -c "^$1	" "$RESULTS" 2>/dev/null || true); printf '%s' "${n:-0}"; }
count_files() { local n=0 f; for f in "$1"/*.lease; do [ -e "$f" ] && n=$((n + 1)); done; printf '%s' "$n"; }

# 보유자 픽스처. 살아 있는 보유자는 부모가 거두지 않도록 떼어 낸 `sleep` 이다 —
# 거두지 않은 자식은 죽어도 좀비로 남아 `kill -0` 과 `ps` 에 산 것처럼 보인다.
tr_spawn() { ( sleep 600 >/dev/null 2>&1 & printf '%s' "$!" > "$WORK/spawn.pid" ); cat "$WORK/spawn.pid"; }
TR_HOLDER=$(tr_spawn)
TR_PIDS="$TR_PIDS $TR_HOLDER"
TR_HOLDER_FP=$( . "$TR_ORCH/liveness.sh"; TZ=UTC0 cc_proc_fingerprint "$TR_HOLDER" )
sleep 0 &
TR_DEAD=$!
wait "$TR_DEAD" 2>/dev/null
TR_DEAD_FP='Thu Jan 1 00:00:00 1970'

NOW=$(date -u +%s)

# epoch → `touch -t` 형식(UTC). BSD 는 `date -r <초>`, GNU 는 `date -d @<초>`.
tr_stamp() { date -u -r "$1" +%Y%m%d%H%M.%S 2>/dev/null || date -u -d "@$1" +%Y%m%d%H%M.%S; }
tr_age() { TZ=UTC0 touch -t "$(tr_stamp "$2")" "$1"; }

tr_key() { ( . "$TR_ROUTE"; route__key "$1" "$2" ); }
tr_table_json() { ( . "$TR_ORCH/liveness.sh"; . "$TR_ROUTE"; route__table_read "$1" "${2:-}" ); }

# 주입 설정. 출하 상수와 같을 필요가 없고, 단언은 이 변수들로만 기대값을 만든다.
TK5=1; TK7=3; TKS=1
TC5=0.3; TC7=0.08; TC5_BP=3000; TC7_BP=800
TCAP=8000
TR5=$((TK5 * TC5_BP)); TR7=$((TK7 * TC7_BP))
RES_JSON="{\"five_hour\":$TR5,\"seven_day\":$TR7}"

TR_JQ='
def W($u; $r): {utilization: $u, resets_at_epoch: $r, observed_at_epoch: ($now - 60), source: "tracker"};
def A($id): {id: $id, config_dir: ("/h/.claude-" + $id), label: $id, interactive_reserved: false, unattended: "enabled", added_at: 0};
def UW($id; $w5; $w7): {id: $id, config_dir: ("/h/.claude-" + $id), login: "ok", status: "allowed", windows: {five_hour: $w5, seven_day: $w7}};
def UA($id; $u5; $u7): UW($id; W($u5; $now + 3600); W($u7; $now + 86400));
def UB($id; $b5; $b7): UA($id; $b5 / 10000; $b7 / 10000);
def RES: {five_hour: $r5, seven_day: $r7};
def LR($run; $lin; $acct; $kind; $res; $live; $seq):
  {schema: $schema, kind: $kind, run_id: $run, lineage: $lin, nonce: ("n-" + $run + "-" + $lin), seq: $seq,
   account: $acct, config_dir: ("/h/.claude-" + $acct), holders: [{pid: 1, fp: "x"}], granted_at_epoch: $now,
   live: $live, path: ("/t/" + $run + "+" + $lin + ".lease")}
  + (if $res == null then {} else {reservation_bp: $res} end)
  + (if $kind == "grant" then {admitted_as: "known", basis: "first", observed: "tracker@1"} else {} end);
def LG($run; $lin; $acct; $live): LR($run; $lin; $acct; "grant"; RES; $live; 1);
def base:
  {now: $now, request: {run_id: "r1", lineage: "S1", event: "first", kind: "implement"},
   inventory: {state: "valid", accounts: [A("a"), A("b")]},
   usage: {state: "valid", written_at_epoch: $now, publish_interval_s: 300, fresh: true,
           accounts: [UA("a"; 0.1; 0.1), UA("b"; 0.2; 0.2)]},
   frames: [], leases: {state: "valid", items: [], corrupt: [], stale_corrupt: []}, sticky: [],
   seat: {config_dir: "/seat"},
   config: {k: {default: {five_hour: $k5, seven_day: $k7}, shift: {five_hour: $ks, seven_day: $ks}},
            c: {five_hour: {default: $c5, by_kind: {}, by_group: {}}, seven_day: {default: $c7, by_kind: {}, by_group: {}}},
            cap_bp: $cap, ttl_s: {"stage-log": 1800, tracker: 1800}, file_stale_factor: 3},
   borrow_path: $bp};
def ONLY($ids): .inventory.accounts = [$ids[] | A(.)];
def REQ($o): .request += $o;
def ITEMS($xs): .leases.items = $xs;
def USE($xs): .usage.accounts = $xs;
def BRW($st; $id; $dir): {state: $st, lane_config_dir: "/seat", donor: {id: $id, config_dir: $dir}};
def LEND($id): .borrow = BRW("borrowed"; $id; ("/h/.claude-" + $id));
'
# 거래 문맥의 차용 기록 경로. 작업 디렉터리 아래의 없는 파일이라 재판독은 부재를 본다.
TR_NO_BORROW="$WORK/no-borrow/cc-lane/borrow.json"
ctx() {
  jq -cn --argjson now "$NOW" --arg schema "$LEASE_SCHEMA" \
    --argjson k5 "$TK5" --argjson k7 "$TK7" --argjson ks "$TKS" --argjson c5 "$TC5" --argjson c7 "$TC7" \
    --argjson cap "$TCAP" --argjson r5 "$TR5" --argjson r7 "$TR7" --arg bp "$TR_NO_BORROW" "$TR_JQ base | $1"
}
decide() { ctx "$1" | bash "$TR_ROUTE" decide; }
admit1() { ctx "$1" | bash "$TR_ROUTE" admit | jq -c --arg id "${2:-a}" '.[] | select(.account == $id)'; }
classify() { ctx "$1" | bash "$TR_ROUTE" classify; }
# txn <표> <문맥 필터> [추가 인자…] — 살아 있는 보유자 하나로 거래 프로세스를 돌린다.
txn() {
  local t="$1" f="$2"
  shift 2
  ctx "$f" | bash "$TR_ROUTE" lease-txn --table "$t" --now "$NOW" --boot-epoch "" --holder "$TR_HOLDER" "$@"
}
# put_lease <표> <run> <lineage> <kind> <계정> <예약 JSON|null> <pid> <fp> [seq] [nonce]
put_lease() {
  local t="$1" key
  key=$(tr_key "$2" "$3") || return 1
  mkdir -p "$t"
  jq -cn --arg schema "$LEASE_SCHEMA" --arg run "$2" --arg lin "$3" --arg kind "$4" --arg acct "$5" \
    --argjson res "$6" --argjson pid "$7" --arg fp "$8" --argjson seq "${9:-1}" --arg nonce "${10:-n-$2-$3}" \
    --argjson now "$NOW" \
    '{schema: $schema, kind: $kind, run_id: $run, lineage: $lin, nonce: $nonce, seq: $seq, account: $acct,
      config_dir: ("/h/.claude-" + $acct), holders: [{pid: $pid, fp: $fp}], granted_at_epoch: $now}
     + (if $res == null then {} else {reservation_bp: $res} end)
     + (if $kind == "grant" then {admitted_as: "known", basis: "first", observed: "tracker@1"} else {} end)' \
    > "$t/$key.lease"
}
live_lease() { put_lease "$1" "$2" "$3" grant "$4" "$RES_JSON" "$TR_HOLDER" "$TR_HOLDER_FP" "${5:-1}" "${6:-n-$2-$3}"; }
dead_lease() { put_lease "$1" "$2" "$3" grant "$4" "$RES_JSON" "$TR_DEAD" "$TR_DEAD_FP" "${5:-1}" "${6:-n-$2-$3}"; }

# 시험 전용 래퍼. route.sh 를 소싱하고 교차 지점을 환경이 준 조각으로 바꾼 뒤
# 분배기를 부른다. 이 갈래는 시험 파일에만 있다 — route.sh 는 환경으로 여는 시험
# 갈래를 두지 않는다.
WRAP="$WORK/wrap.sh"
cat > "$WRAP" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
. "$TRH_ORCH/liveness.sh"
. "$TRH_ORCH/route.sh"
trh_e() { local i=0; while [ ! -e "$1" ] && [ "$i" -lt 400 ]; do sleep 0.05; i=$((i + 1)); done; }
trh_s() { local i=0; while [ ! -s "$1" ] && [ "$i" -lt 400 ]; do sleep 0.05; i=$((i + 1)); done; }
route__hook_locked() { eval "${TRH_LOCKED:-:}"; }
route__hook_listed() { eval "${TRH_LISTED:-:}"; }
route__hook_decided() { eval "${TRH_DECIDED:-:}"; }
route__hook_written() { eval "${TRH_WRITTEN:-:}"; }
route__hook_revalidate() { eval "${TRH_REVALIDATE:-:}"; }
if [ -n "${TRH_NOLOCK:-}" ]; then
  route__lock_acquire() { ROUTE_LOCK_DIR=""; return 0; }
fi
if [ -n "${TRH_FP_EMPTY_PID:-}" ]; then
  route__fp() { [ "$1" = "$TRH_FP_EMPTY_PID" ] && return 0; TZ=UTC0 cc_proc_fingerprint "$1"; }
fi
case "${TRH_REVAL:-}" in
  fail) route__revalidate() { return 1; } ;;
  tiebreak)
    eval "trh_revalidate_real() $(declare -f route__revalidate | sed '1d')"
    route__revalidate() {
      trh_revalidate_real "$@" && return 0
      local key
      key="$(route__key "$(printf '%s' "$3" | jq -r .run_id)" "$(printf '%s' "$3" | jq -r .lineage)").lease"
      printf '%s' "$2" | jq -e --argjson r "$3" --arg k "$key" \
        '[.items[] | select(.live == true and .kind == "grant" and .account == $r.account)
          | [.granted_at_epoch, (.path | sub("^.*/"; ""))]] | min == [$r.granted_at_epoch, $k]' >/dev/null
    } ;;
esac
route__main "$@"
EOF
export TRH_ORCH="$TR_ORCH"

# ===========================================================================
# 정적 검사
# ===========================================================================
if [ -f "$TR_ROUTE" ]; then ok "route.sh 가 있다"; else bad "route.sh 가 있다" "$TR_ROUTE"; fi

got=$( CC_ORCH_SOURCE_ONLY=1; . "$TR_RUN_SH"; set +e; declare -F route_resolve run_routed )
check "run.sh 소싱 뒤 route_resolve 와 run_routed 가 정의된다" "$got" "route_resolve
run_routed"

rc=0; env PATH=/usr/bin:/bin bash -n "$TR_ROUTE" || rc=$?
check "정화한 PATH 아래 bash -n route.sh" "$rc" 0

got=$(grep -n -E 'grep[[:space:]]+(-[A-Za-z]*q|--quiet)' "$TR_ROUTE" || true)
check "route.sh 에 pipefail 아래 소비되는 grep -q 가 없다" "$got" ""

got=$(grep -n -E '^[A-Za-z_][A-Za-z0-9_]*\(\)' "$TR_ROUTE" | grep -v -E ':route_' || true)
check "route.sh 의 함수 정의는 모두 route_ 접두" "$got" ""

want=$(grep -o -E '^route_[A-Za-z0-9_]*\(\)' "$TR_ROUTE" | sed 's/()$//' | sort -u)
got=$( CC_ORCH_SOURCE_ONLY=1; . "$TR_RUN_SH"; set +e; declare -F | awk '{print $3}' | grep '^route_' | sort -u )
check "run.sh 소싱 뒤 route_ 함수는 route.sh 가 정의한 것뿐" "$got" "$want"

mkdir -p "$WORK/standalone"
got=$( cd "$WORK/standalone" && . "$TR_ROUTE" 2>&1 )
check "route.sh 를 소싱하면 아무것도 출력하지 않는다" "$got" ""
check "route.sh 를 소싱하면 파일을 만들지 않는다" "$(ls -A "$WORK/standalone")" ""
check "단독 진입 lineage 는 .retry 를 모두 뗀다" "$(bash "$TR_ROUTE" lineage S1.retry.retry)" "S1"
rc=0; bash "$TR_ROUTE" no-such-subcommand >/dev/null 2>&1 || rc=$?
check "모르는 서브커맨드는 rc 2" "$rc" 2

# 린트의 게이트 쪽 이름 추출을 route.sh 하나에 적용한다. 하니스에 route.sh 의
# 모든 `NAME=` 철자를 대입해 두면 보고되는 충돌이 곧 추출된 이름 전부다.
R19="$WORK/r19"
mkdir -p "$R19/scripts" "$R19/plugins/cc-cmds/orchestrator"
cp "$TR_ROUTE" "$R19/plugins/cc-cmds/orchestrator/route.sh"
{
  printf '%s\n' '#!/usr/bin/env bash' 'export GATE="$root/gate.sh"'
  grep -o -E '[A-Z][A-Z0-9_]*=' "$TR_ROUTE" | sort -u | sed 's/=$/=x/'
} > "$R19/scripts/test-gate.sh"
ROOT="$R19" GATE_FILES="plugins/cc-cmds/orchestrator/route.sh" bash "$TR_LINT" >"$WORK/r19.out" 2>"$WORK/r19.err"
names=$(sed -n 's#^FAIL: \[충돌\] \([^ ]*\) — .*$#\1#p' "$WORK/r19.err" | sort -u)
check "린트 G 추출이 route.sh 에서 ROUTE_ 아닌 이름을 내지 않는다" "$(printf '%s\n' "$names" | grep -v -E '^(ROUTE_|$)' || true)" ""
case " $(printf '%s ' $names)" in
  *" ROUTE_K_SEVEN_DAY "*) ok "린트 G 추출이 case 갈래 머리 뒤 readonly 상수를 읽는다" ;;
  *) bad "린트 G 추출이 case 갈래 머리 뒤 readonly 상수를 읽는다" "추출: $names" ;;
esac

# ===========================================================================
# 가드와 휴면 계약. 한 run.sh 경로를 받아 돌고, 스크래치 사본으로 다시 돈다.
# ===========================================================================
tr_in_run() {
  # tr_in_run <run.sh> <함수> [인자…] — run.sh 를 부분 셸에서 소싱하고 시험 함수를 부른다.
  local rs="$1"
  shift
  (
    CC_ORCH_SOURCE_ONLY=1
    . "$rs"
    set +e
    "$@"
  )
}

tr_req() { printf '{"run_id":"r1","lineage":"S1","event":"first","kind":"implement","holders":[%s]}' "$TR_HOLDER"; }
tr_dormant() { jq -cn --arg d "$1" '{verdict: "GRANT", basis: "single-seat", account: null, config_dir: $d, dormant: true}'; }

tr_write_inv() {
  # tr_write_inv <absent|valid|corrupt|noenabled> <파일>
  case "$1" in
    absent) rm -f "$2" ;;
    corrupt) printf '{"schema":' > "$2" ;;
    valid|noenabled)
      jq -cn --arg h "$HOME" --arg u "$( [ "$1" = valid ] && printf enabled || printf disabled )" \
        '{schema: "cc-lane-accounts v1", accounts: [{id: "a", config_dir: ($h + "/.claude-a"), label: "a",
          interactive_reserved: false, unattended: $u, added_at: 0}]}' > "$2" ;;
  esac
}

tr_g_cells() {
  local lb="$1" b="$2" st g rc out ans
  unset CLAUDE_CONFIG_DIR
  export XDG_STATE_HOME="$b/state"
  mkdir -p "$XDG_STATE_HOME"
  check "$lb: 휴면 봉투의 모양" "$(route__dormant /x)" '{"verdict":"GRANT","basis":"single-seat","account":null,"config_dir":"/x","dormant":true}'
  for st in absent valid corrupt; do
    export RUN_DIR="$b/cells-$st"
    mkdir -p "$RUN_DIR"
    tr_write_inv "$st" "$RUN_DIR/inventory.json"
    ans=$(resolve_account)
    for g in 0 1; do
      export RUN_PACE_ROOT="$b/pace-$st-$g"
      rc=0
      out=$(route__resolve_as "$g" "$(tr_req)" 2>/dev/null) || rc=$?
      case "$g/$st" in
        0/*|1/absent) check "$lb: 가드 ${g}·인벤토리 $st → 휴면 봉투" "$rc:$out" "0:$(tr_dormant "$ans")" ;;
        1/valid) expect "$lb: 가드 1·인벤토리 유효 → 활성 경로" "$out" \
          '.verdict == "GRANT" and .dormant == false and .account == "a" and .basis == "first"' ;;
        1/corrupt) expect "$lb: 가드 1·인벤토리 깨짐 → PARK inventory-corrupt" "$out" \
          '.verdict == "PARK" and .reason == "inventory-corrupt" and .recovery == "cc-lane account check"' ;;
      esac
      seen "$out"
    done
  done
  export RUN_DIR="$b/cells-noenabled"
  mkdir -p "$RUN_DIR"
  tr_write_inv noenabled "$RUN_DIR/inventory.json"
  export RUN_PACE_ROOT="$b/pace-noenabled"
  out=$(route__resolve_as 1 "$(tr_req)" 2>/dev/null)
  expect "$lb: enabled 없는 유효 인벤토리 → PARK no-enabled-account" "$out" '.verdict == "PARK" and .reason == "no-enabled-account"'
  check "$lb: 활성 거래가 끝난 뒤 락이 남지 않는다" "$(ls -A "$b/pace-valid-1/leases" | grep -c '^\.lock$' || true)" 0

  # 차용 표시. 둘째 인자는 판독기의 정규형이다.
  local d0 bx='{"state":"borrowed","lane_config_dir":"/x","donor":{"id":"u3","config_dir":"/h/.claude-u3"}}'
  d0='{"verdict":"GRANT","basis":"single-seat","account":null,"config_dir":"/x","dormant":true}'
  check "$lb: 휴면 봉투의 차용 표시" "$(route__dormant /x "$bx")" "${d0%\}},\"borrow\":{\"state\":\"borrowed\",\"donor\":\"u3\"}}"
  check "$lb: 다른 lane 의 기록은 표시하지 않는다" \
    "$(route__dormant /x '{"state":"borrowed","lane_config_dir":"/y","donor":{"id":"u3","config_dir":"/h/.claude-u3"}}')" "$d0"
  check "$lb: 끝 슬래시 좌석은 lane 과 다르다" "$(route__dormant "/x/" "$bx")" "$(route__dormant "/x/")"
  check "$lb: 손상 기록의 휴면 표시" "$(route__dormant /x '{"state":"corrupt"}')" "${d0%\}},\"borrow\":{\"state\":\"corrupt\",\"donor\":null}}"
  check "$lb: 파싱되지 않는 둘째 인자는 표시하지 않는다" "$(route__dormant /x 'not-json')" "$d0"
  check "$lb: 빈 둘째 인자는 표시하지 않는다" "$(route__dormant /x '')" "$d0"
  # 해석 경로. 매트릭스와 다른 상태 루트에 기록을 두고 해석기의 답을 lane 으로 쓴다.
  local erc grc
  export RUN_DIR="$b/cells-borrow" XDG_STATE_HOME="$b/bstate"
  mkdir -p "$RUN_DIR" "$XDG_STATE_HOME/cc-lane"
  erc=0; ans=$(resolve_account 2>"$b/b.e.err") || erc=$?
  jq -cn --arg l "$ans" '{schema: "cc-lane-borrow v1", state: "intent", lane_config_dir: $l, donor: {id: "u3", config_dir: "/h/.claude-u3"}}' \
    > "$XDG_STATE_HOME/cc-lane/borrow.json"
  grc=0; out=$(route__resolve_as 0 "$(tr_req)" 2>"$b/b.g.err") || grc=$?
  expect "$lb: 해석 경로의 휴면 봉투에 차용 표시" "$out" '.dormant == true and .borrow == {state: "intent", donor: "u3"}'
  check "$lb: 해석 경로의 rc·표준 오류는 해석기와 같다" "$grc|$(sed 's/^[^ ]* //' "$b/b.g.err")" "$erc|$(sed 's/^[^ ]* //' "$b/b.e.err")"
  # 경로를 유도할 수 없는 환경. 해석기는 1단으로 선다.
  for st in nohome relxdg; do
    (
      export CLAUDE_CONFIG_DIR="$b/cfg-$st"
      if [ "$st" = nohome ]; then unset XDG_STATE_HOME; export HOME=''; else export XDG_STATE_HOME=rel; fi
      erc=0; resolve_account >/dev/null 2>"$b/u-$st.e.err" || erc=$?
      grc=0; route__resolve_as 0 "$(tr_req)" >"$b/u-$st.g.out" 2>"$b/u-$st.g.err" || grc=$?
      printf '%s %s' "$grc" "$erc" > "$b/u-$st.rc"
    )
    expect "$lb: 경로 유도 불가($st)의 휴면 봉투는 손상 표시" "$(cat "$b/u-$st.g.out")" '.dormant == true and .borrow == {state: "corrupt", donor: null}'
    check "$lb: 경로 유도 불가($st)의 rc·표준 오류는 해석기와 같다" \
      "$(cut -d' ' -f1 "$b/u-$st.rc")|$(sed 's/^[^ ]* //' "$b/u-$st.g.err")" "$(cut -d' ' -f2 "$b/u-$st.rc")|$(sed 's/^[^ ]* //' "$b/u-$st.e.err")"
  done
}

tr_tier() {
  # tr_tier <단> <디렉터리> — 해석기의 한 단을 세운다. 2x·3x 는 비-디렉터리 기록이다.
  local d="$2"
  unset CLAUDE_CONFIG_DIR
  export RUN_DIR="$d/run" XDG_CONFIG_HOME="$d/xdg" XDG_STATE_HOME="$d/state"
  export RUN_PACE_ROOT="$d/state/cc-cmds/pace"
  mkdir -p "$RUN_DIR" "$XDG_CONFIG_HOME/cc-cmds" "$XDG_STATE_HOME"
  case "$1" in
    1) export CLAUDE_CONFIG_DIR="$HOME/.claude-x y/" ;;
    2) mkdir -p "$HOME/.claude-t2"; printf '%s\n' "$HOME/.claude-t2" > "$RUN_DIR/config-dir" ;;
    3) mkdir -p "$HOME/.claude-t3"; printf '%s\n' "$HOME/.claude-t3" > "$XDG_CONFIG_HOME/cc-cmds/config-dir" ;;
    4) ;;
    2x) printf '%s\n' "$d/not-a-dir" > "$RUN_DIR/config-dir" ;;
    3x) printf '%s\n' "$d/not-a-dir" > "$XDG_CONFIG_HOME/cc-cmds/config-dir" ;;
  esac
}

tr_contract() {
  # tr_contract <이름> <디렉터리> — 가드 0 의 휴면 경로가 계약 (a)–(e) 를 지키는지.
  local n="$1" d="$2" erc=0 grc=0 eout gv
  eout=$(resolve_account 2>"$d/e.err") || erc=$?
  route__resolve_as 0 "$(tr_req)" >"$d/g.out" 2>"$d/g.err" || grc=$?
  check "$n (a) rc" "$grc" "$erc"
  if [ "$erc" = "0" ]; then
    gv=$(route__resolve_as 0 "$(tr_req)" 2>/dev/null | jq -j '.config_dir')
    check "$n (b) 치환 값" "$gv" "$eout"
  else
    check "$n (c) 빈 표준 출력" "$(wc -c < "$d/g.out" | tr -d ' ')" 0
  fi
  check "$n (d) 표준 오류" "$(sed 's/^[^ ]* //' "$d/g.err")" "$(sed 's/^[^ ]* //' "$d/e.err")"
  check "$n (e) 상태 루트" "$(find "$XDG_STATE_HOME" -mindepth 1 | head -n 1)" ""
}

tr_g_matrix() {
  local lb="$1" b="$2" tier st d rc out eout gv el
  mkdir -p "$b"
  for tier in 1 2 3 4 2x 3x; do
    for st in absent valid corrupt; do
      d="$b/$tier-$st"
      tr_tier "$tier" "$d"
      tr_write_inv "$st" "$RUN_DIR/inventory.json"
      tr_contract "$lb: 단 ${tier}·인벤토리 $st" "$d"
    done
  done

  # 후행 개행 값: 치환 값은 같고 날 표준 출력은 다르다.
  d="$b/nl"
  tr_tier 4 "$d"
  export CLAUDE_CONFIG_DIR="$HOME/.claude-nl
"
  eout=$(resolve_account)
  gv=$(route__resolve_as 0 "$(tr_req)" | jq -j '.config_dir')
  check "$lb: 후행 개행 값의 치환 값이 같다" "$gv" "$eout"
  route__resolve_as 0 "$(tr_req)" > "$d/raw-g"
  resolve_account > "$d/raw-e"
  if cmp -s "$d/raw-g" "$d/raw-e"; then bad "$lb: 후행 개행 값의 날 표준 출력이 다르다" "같았다"
  else ok "$lb: 후행 개행 값의 날 표준 출력이 다르다"; fi

  # 잘못된 UTF-8 1단 값: 계약의 예외 칸.
  d="$b/badutf"
  tr_tier 4 "$d"
  CLAUDE_CONFIG_DIR=$(printf 'a\377b')
  export CLAUDE_CONFIG_DIR
  rc=0
  route__resolve_as 0 "$(tr_req)" >"$d/out" 2>"$d/err" || rc=$?
  check "$lb: 잘못된 UTF-8 값 → rc 1" "$rc" 1
  check "$lb: 잘못된 UTF-8 값 → 빈 표준 출력" "$(wc -c < "$d/out" | tr -d ' ')" 0
  check "$lb: 잘못된 UTF-8 값 → 경고 한 줄" "$(grep -c '' "$d/err")" 1
  check "$lb: 잘못된 UTF-8 값의 경고 문면" "$(grep -c '바이트 그대로 실을 수 없다' "$d/err")" 1
  unset CLAUDE_CONFIG_DIR

  # 독이 든 표에서도 휴면 호출은 표를 건드리지 않는다.
  for st in absent valid corrupt; do
    d="$b/poison-$st"
    tr_tier 4 "$d"
    tr_write_inv "$st" "$RUN_DIR/inventory.json"
    mkdir -p "$RUN_PACE_ROOT/leases/.lock"
    printf 'not json\n' > "$RUN_PACE_ROOT/leases/bad.lease"
    printf '%s\n%s\n' "$TR_HOLDER" "$TR_HOLDER_FP" > "$RUN_PACE_ROOT/leases/.lock/owner"
    tr_age "$RUN_PACE_ROOT/leases/bad.lease" 978307200
    tr_age "$RUN_PACE_ROOT/leases/.lock/owner" 978307200
    tr_age "$RUN_PACE_ROOT/leases/.lock" 978307200
    tr_age "$RUN_PACE_ROOT/leases" 978307200
    : > "$d/marker"
    eout=$(resolve_account)
    SECONDS=0
    rc=0
    out=$(route__resolve_as 0 "$(tr_req)" 2>/dev/null) || rc=$?
    el=$SECONDS
    gv=$(route__resolve_as 0 "$(tr_req)" 2>/dev/null | jq -j '.config_dir')
    if [ "$el" -lt 2 ]; then ok "$lb: 독이 든 표·인벤토리 $st — 락 대기 없이 끝난다"
    else bad "$lb: 독이 든 표·인벤토리 $st — 락 대기 없이 끝난다" "${el}초"; fi
    check "$lb: 독이 든 표·인벤토리 $st — rc" "$rc" 0
    check "$lb: 독이 든 표·인벤토리 $st — 설정 디렉터리" "$gv" "$eout"
    check "$lb: 독이 든 표·인벤토리 $st — 바뀐 파일 없음" "$(find "$RUN_PACE_ROOT" -newer "$d/marker" | head -n 1)" ""
  done
}

tr_g_once() {
  local lb="$1" b="$2" st g n rc out
  mkdir -p "$b"
  resolve_account() { printf 'x' >> "$TRG_COUNT"; printf '%s' "$HOME/.claude"; }
  for st in absent valid corrupt noenabled; do
    export RUN_DIR="$b/run-$st"
    mkdir -p "$RUN_DIR"
    tr_write_inv "$st" "$RUN_DIR/inventory.json"
    for g in 0 1; do
      export RUN_PACE_ROOT="$b/pace-$st-$g"
      TRG_COUNT="$b/count-$st-$g"
      : > "$TRG_COUNT"
      route__resolve_as "$g" "$(tr_req)" >/dev/null 2>&1
      n=$(wc -c < "$TRG_COUNT" | tr -d ' ')
      check "$lb: 가드 ${g}·인벤토리 $st — 해석기 한 번" "$n" 1
    done
  done
  resolve_account() { printf 'x' >> "$TRG_COUNT"; return 3; }
  for g in 0 1; do
    export RUN_DIR="$b/run-valid" RUN_PACE_ROOT="$b/pace-fail-$g"
    TRG_COUNT="$b/count-fail-$g"
    : > "$TRG_COUNT"
    rc=0
    out=$(route__resolve_as "$g" "$(tr_req)" 2>/dev/null) || rc=$?
    check "$lb: 가드 $g — 해석기 실패의 rc 와 빈 출력" "$rc:$out" "3:"
    check "$lb: 가드 $g — 실패해도 해석기 한 번" "$(wc -c < "$TRG_COUNT" | tr -d ' ')" 1
  done
}

tr_g_shipped() {
  # 런마다의 판정: 기록 `1` 인 런에서만 route_resolve 가 활성 답을 낸다. route.sh 만
  # 소싱한 셸은 기록이 있어도 휴면이다.
  local lb="$1" b="$2" rec x y
  export RUN_PACE_ROOT="$b/pace"
  for rec in none 0 1; do
    export RUN_DIR="$b/run-$rec"
    mkdir -p "$RUN_DIR"
    tr_write_inv corrupt "$RUN_DIR/inventory.json"
    [ "$rec" = none ] || printf '%s\n' "$rec" > "$RUN_DIR/routing-guard"
    x=$(route_resolve "$(tr_req)" 2>/dev/null)
    y=$(route__resolve_as "$( [ "$rec" = 1 ] && printf 1 || printf 0 )" "$(tr_req)" 2>/dev/null)
    check "$lb: 런 기록 $rec 의 route_resolve 와 명시 가드가 같다" "$x" "$y"
    seen "$x"
  done
  x=$( unset -f run_routed; route_resolve "$(tr_req)" 2>/dev/null )
  check "$lb: run_routed 없는 셸은 기록 1 의 런에서도 휴면 답" "$x" "$(route__resolve_as 0 "$(tr_req)" 2>/dev/null)"
}

tr_guard_sections() {
  local rs="$1" lb="$2" b
  b="$WORK/guard-$lb"
  mkdir -p "$b"
  tr_in_run "$rs" tr_g_cells "$lb" "$b/cells"
  tr_in_run "$rs" tr_g_matrix "$lb" "$b/m0"
  tr_in_run "$rs" tr_g_once "$lb" "$b/once"
  tr_in_run "$rs" tr_g_shipped "$lb" "$b/shipped"
}

tr_guard_sections "$TR_RUN_SH" "원본"
check "오케스트레이터에 빌드 스위치 이름이 남지 않는다" \
  "$(grep -l -r 'ROUTE_ROUTING_BUILD_COMPLETE' "$TR_ORCH" || true)" ""

# ===========================================================================
# 입력 판독 — 인벤토리 분류기
# ===========================================================================
INV="$WORK/inv"
mkdir -p "$INV"
inv_case() {
  # inv_case <이름> <jq 변형> <기대 rc> [기대 사유]
  local f="$INV/$1.json" rc=0
  jq -cn --arg h "$HOME" '{schema: "cc-lane-accounts v1", accounts: [
      {id: "a", config_dir: ($h + "/.claude-a"), label: "a", interactive_reserved: false, unattended: "enabled", added_at: 0},
      {id: "c", config_dir: ($h + "/.claude-c"), label: "c", interactive_reserved: true, unattended: "disabled", added_at: 0}]}
    | '"$2" > "$f"
  bash "$TR_ROUTE" inventory-check "$f" 2>"$f.err" || rc=$?
  check "인벤토리 $1 → rc $3" "$rc" "$3"
  if [ -n "${4:-}" ]; then
    check "인벤토리 $1 → 사유 $4" "$(grep -c "($4)" "$f.err")" 1
  fi
}
inv_case "유효" '.' 0
inv_case "스키마 불일치" '.schema = "cc-lane-accounts v2"' 1 schema
inv_case "id 중복" '.accounts[1].id = "a"' 1 id-duplicate
inv_case "접두 밖 config_dir" '.accounts[0].config_dir = "/tmp/.claude-a"' 1 config_dir-prefix
inv_case "끝 슬래시" '.accounts[0].config_dir += "/"' 1 config_dir-trailing-slash
inv_case "unattended 값 밖" '.accounts[0].unattended = "on"' 1 unattended
inv_case "interactive_reserved 비불리언" '.accounts[0].interactive_reserved = "no"' 1 interactive_reserved
inv_case "예약인데 disabled 아님" '.accounts[1].unattended = "draining"' 1 reserved-not-disabled
printf '{"schema":' > "$INV/parse.json"
rc=0; bash "$TR_ROUTE" inventory-check "$INV/parse.json" 2>"$INV/parse.err" || rc=$?
check "인벤토리 파싱 불가 → rc 1" "$rc" 1
check "인벤토리 파싱 불가 → 사유 parse" "$(grep -c '(parse)' "$INV/parse.err")" 1
rc=0; bash "$TR_ROUTE" inventory-check "$INV/absent.json" 2>/dev/null || rc=$?
check "인벤토리 부재 → rc 2" "$rc" 2
out=$(decide '.inventory.accounts = [A("a") + {config_dir: "/h/.claude-a//x/./"}] | ONLY(["a"]) | .inventory.accounts[0].config_dir = "/h/.claude-a//x/." | .usage.accounts = []')
expect "config_dir 는 정규화하지 않고 축자로 싣는다" "$out" '.config_dir == "/h/.claude-a//x/."'

# ===========================================================================
# 입력 판독 — 사용량
# ===========================================================================
USG="$WORK/usage"
mkdir -p "$USG"
usage_file() {
  # usage_file <파일> <jq 변형>
  jq -cn --argjson now "$NOW" '{schema: "cc-lane-usage v1", written_at_epoch: $now, publish_interval_s: 300,
    accounts: [{id: "a", config_dir: "/h/.claude-a", org_hash: "h1", login: "ok", status: "allowed",
      windows: {five_hour: {utilization: 0.1, resets_at_epoch: ($now + 3600), observed_at_epoch: ($now - 60), source: "tracker"},
                seven_day: {utilization: 0.1, resets_at_epoch: ($now + 86400), observed_at_epoch: ($now - 60), source: "tracker"}}}]}
    | '"$2" > "$1"
}
check "사용량 부재" "$(bash "$TR_ROUTE" usage-read "$USG/none.json" "$NOW")" '{"state":"absent"}'
printf 'garbage' > "$USG/garbage.json"
check "사용량 깨짐" "$(bash "$TR_ROUTE" usage-read "$USG/garbage.json" "$NOW")" '{"state":"corrupt"}'
usage_file "$USG/schema.json" '.schema = "cc-lane-usage v9"'
check "사용량 다른 스키마" "$(bash "$TR_ROUTE" usage-read "$USG/schema.json" "$NOW")" '{"state":"corrupt"}'
for kind in absent corrupt; do
  out=$(decide ".usage = {state: \"$kind\"}")
  expect "사용량 $kind 에서도 라우팅은 꺼지지 않는다" "$out" '.verdict == "GRANT" and .basis == "first" and .admitted_as == "unknown"'
done
usage_file "$USG/stale.json" '.written_at_epoch = ($now - 901) | .accounts[0].login = "expired"'
out=$(bash "$TR_ROUTE" usage-read "$USG/stale.json" "$NOW" 2>"$USG/stale.err")
expect "낡은 파일은 창 값을 빼고 식별 필드를 남긴다" "$out" \
  '.fresh == false and (.accounts[0] | has("windows") | not) and .accounts[0].org_hash == "h1" and .accounts[0].config_dir == "/h/.claude-a"'
check "낡은 파일의 비-ok 로그인은 경고한다" "$(grep -c '로그인' "$USG/stale.err")" 1
out=$(decide "ONLY([\"a\"]) | .usage = $out")
expect "낡은 로그인은 ok 로 다룬다" "$out" '.verdict == "GRANT" and .account == "a"'
usage_file "$USG/fresh-3x.json" '.written_at_epoch = ($now - 900)'
expect "3 × 주기 경계는 아직 신선하다" "$(bash "$TR_ROUTE" usage-read "$USG/fresh-3x.json" "$NOW")" '.fresh == true and (.accounts[0] | has("windows"))'
usage_file "$USG/nowritten.json" 'del(.written_at_epoch)'
expect "written_at_epoch 결측은 낡음" "$(bash "$TR_ROUTE" usage-read "$USG/nowritten.json" "$NOW")" '.fresh == false and (.accounts[0] | has("windows") | not)'
out=$(decide '.usage.accounts[0].login = "expired"')
expect "신선한 비-ok 로그인 계정은 후보에서 빠진다" "$out" '.verdict == "GRANT" and .account == "b"'
out=$(classify 'ONLY(["a"]) | USE([UW("a"; W(0.1; $now + 3600) + {observed_at_epoch: ($now - 1801)}; W(0.1; $now + 86400))])')
expect "TTL 을 넘긴 창은 unknown" "$out" '.groups[0].windows.five_hour.state == "unknown" and .accounts[0].class == "U"'
out=$(classify 'ONLY(["a"]) | USE([UW("a"; W(0.1; $now + 3600) + {source: "mystery"}; W(0.1; $now + 86400))])')
expect "모르는 source 의 창은 unknown" "$out" '.groups[0].windows.five_hour.state == "unknown"'
out=$(classify 'ONLY(["a"]) | USE([UW("a"; W(0.9; $now - 10) + {observed_at_epoch: ($now - 9000)}; W(0.1; $now + 86400))])')
expect "now ≥ resets_at 인 창은 낡았어도 reset_elapsed" "$out" '.groups[0].windows.five_hour.state == "reset_elapsed" and .accounts[0].class == "R"'
out=$(classify 'ONLY(["a"]) | USE([UA("a"; 0.1; 0.1) + {exhausted_until_epoch: ($now + 100)}])')
expect "exhausted_until_epoch > now 는 소진" "$out" '.accounts[0].class == "X"'
out=$(classify 'ONLY(["a"]) | USE([UA("a"; 0.1; 1.3)])')
expect "utilization ≥ 1.0 은 소진이고 클램프하지 않는다" "$out" '.groups[0].windows.seven_day.state == "exhausted" and .groups[0].windows.seven_day.u_bp == 13000'
out=$(decide '.usage.accounts[0].config_dir = "/h/.claude-a/"')
expect "같은 id 의 config_dir 불일치는 그 계정만 뺀다" "$out" '.verdict == "GRANT" and .account == "b"'
out=$(classify '.usage.accounts[0].config_dir = "/h/.claude-a/"')
expect "불일치는 그 계정에만 표시된다" "$out" '([.accounts[] | select(.mismatch)] | map(.id)) == ["a"]'

# ===========================================================================
# 입력 판독 — 차용 기록
# ===========================================================================
BRD="$WORK/borrow"
BRO="$WORK/borrow-out"
mkdir -p "$BRD" "$BRO"
bfile() {
  # bfile <파일> <jq 변형> — 유효한 차용 중 기록(기증자 u3)을 변형해 쓴다.
  mkdir -p "${1%/*}"
  jq -cn '{schema: "cc-lane-borrow v1", state: "borrowed", lane_config_dir: "/lane",
    donor: {id: "u3", config_dir: "/h/.claude-u3"}, since_epoch: 1} | '"$2" > "$1"
}
br_read() { ( . "$TR_ROUTE"; route_borrow_read "$@" ); }
br_tree() { find "$BRD" 2>/dev/null | LC_ALL=C sort; }
br_case() {
  # br_case <이름> <파일> <기대 한 줄> — 출력, rc 0, 빈 표준 오류, 트리 무변화를 한 단언으로 본다.
  local before rc=0 out
  before=$(br_tree)
  out=$(br_read "$2" 2>"$BRO/err") || rc=$?
  check "차용 기록 $1" "$rc|$out|$(wc -c < "$BRO/err" | tr -d ' ')|$([ "$(br_tree)" = "$before" ] && printf same || printf changed)" \
    "0|$3|0|same"
}
CORRUPT='{"state":"corrupt"}'
mkdir -p "$BRD/a1"
br_case "부재" "$BRD/a1/cc-lane/borrow.json" '{"state":"absent"}'
bfile "$BRD/none.json" '.state = "none" | .donor = null'
br_case "none" "$BRD/none.json" '{"state":"none"}'
bfile "$BRD/none-d.json" '.state = "none"'
br_case "none 이 기증자를 지명" "$BRD/none-d.json" '{"state":"none"}'
for st in intent borrowed returning; do
  bfile "$BRD/$st.json" ".state = \"$st\""
  br_case "$st" "$BRD/$st.json" "{\"state\":\"$st\",\"lane_config_dir\":\"/lane\",\"donor\":{\"id\":\"u3\",\"config_dir\":\"/h/.claude-u3\"}}"
done
printf '{"schema":' > "$BRD/broken.json"
br_case "깨진 JSON" "$BRD/broken.json" "$CORRUPT"
bfile "$BRD/schema.json" '.schema = "cc-lane-borrow v2"'
br_case "모르는 스키마" "$BRD/schema.json" "$CORRUPT"
: > "$BRD/empty.json"
br_case "빈 파일" "$BRD/empty.json" "$CORRUPT"
bfile "$BRD/one.json" '.'
cat "$BRD/one.json" "$BRD/one.json" > "$BRD/two.json"
br_case "두 문서" "$BRD/two.json" "$CORRUPT"
bfile "$BRD/array.json" '[.]'
br_case "배열" "$BRD/array.json" "$CORRUPT"
bfile "$BRD/nodir.json" '.donor.config_dir = ""'
br_case "빈 donor.config_dir" "$BRD/nodir.json" "$CORRUPT"
bfile "$BRD/nolane.json" '.lane_config_dir = ""'
br_case "빈 lane_config_dir" "$BRD/nolane.json" "$CORRUPT"
mkdir -p "$BRD/isdir.json"
br_case "경로에 디렉터리" "$BRD/isdir.json" "$CORRUPT"
ln -s "$BRD/one.json" "$BRD/link.json"
br_case "유효 파일을 가리키는 심링크" "$BRD/link.json" "$CORRUPT"
ln -s "$BRD/missing.json" "$BRD/dangling.json"
br_case "끊긴 심링크" "$BRD/dangling.json" "$CORRUPT"
br_case "상대 경로 인자" "one.json" "$CORRUPT"
# FIFO 는 열면 막힌다. 감시 프로세스가 시간 제한을 걸고, 판독기는 그 전에 끝나야 한다.
mkfifo "$BRD/fifo.json"
before=$(br_tree)
br_read "$BRD/fifo.json" > "$BRO/fifo.out" 2>"$BRO/fifo.err" &
p=$!
( sleep 5; kill "$p" 2>/dev/null ) &
w=$!
rc=0; wait "$p" || rc=$?
kill "$w" 2>/dev/null; wait "$w" 2>/dev/null
check "차용 기록 FIFO 는 열지 않고 곧바로 손상" \
  "$rc|$(cat "$BRO/fifo.out")|$(wc -c < "$BRO/fifo.err" | tr -d ' ')|$([ "$(br_tree)" = "$before" ] && printf same || printf changed)" \
  "0|$CORRUPT|0|same"
if [ "$(id -u)" = "0" ]; then
  ok "차용 기록 mode 000 파일(root 는 권한을 우회하므로 생략)"
  ok "차용 기록 mode 000 상위(root 는 권한을 우회하므로 생략)"
else
  bfile "$BRD/perm1/borrow.json" '.'
  chmod 000 "$BRD/perm1/borrow.json"
  br_case "mode 000 파일" "$BRD/perm1/borrow.json" "$CORRUPT"
  chmod 644 "$BRD/perm1/borrow.json"
  bfile "$BRD/perm2/cc-lane/borrow.json" '.'
  chmod 000 "$BRD/perm2/cc-lane"
  br_case "mode 000 상위" "$BRD/perm2/cc-lane/borrow.json" "$CORRUPT"
  chmod 755 "$BRD/perm2/cc-lane"
fi

brr() { bash "$TR_ROUTE" borrow-read "$@"; }
check "borrow-read 부재" "$(brr "$BRD/a1/cc-lane/borrow.json")" '{"state":"absent","donor":null}'
check "borrow-read none" "$(brr "$BRD/none.json")" '{"state":"none","donor":null}'
check "borrow-read none 의 기증자는 null" "$(brr "$BRD/none-d.json")" '{"state":"none","donor":null}'
for st in intent borrowed returning; do
  check "borrow-read $st" "$(brr "$BRD/$st.json")" "{\"state\":\"$st\",\"donor\":\"u3\"}"
done
check "borrow-read 손상" "$(brr "$BRD/broken.json")" '{"state":"corrupt","donor":null}'
check "borrow-read 는 정확히 한 줄" "$(brr "$BRD/borrowed.json" | wc -l | tr -d ' ')" 1
bfile "$BRD/tab.json" '.donor.id = "u\t3"'
check "borrow-read 제어 문자는 JSON 이스케이프" "$(brr "$BRD/tab.json")" '{"state":"borrowed","donor":"u\t3"}'
check "borrow-read 기본 경로를 유도할 수 없으면 손상" "$(env XDG_STATE_HOME= HOME= bash "$TR_ROUTE" borrow-read)" '{"state":"corrupt","donor":null}'
bfile "$BRD/xdg/cc-lane/borrow.json" '.'
check "borrow-read 기본 경로는 XDG_STATE_HOME 아래" "$(env XDG_STATE_HOME="$BRD/xdg" bash "$TR_ROUTE" borrow-read)" '{"state":"borrowed","donor":"u3"}'
mkdir -p "$BRO/noarg"
rc=0; out=$(cd "$BRO/noarg" && br_read) || rc=$?
check "판독기 인자 없음 → rc 2, 빈 표준 출력, 만든 것 없음" "$rc|$out|$(ls -A "$BRO/noarg")" "2||"
rc=0; out=$(brr a b 2>"$BRO/usage.err") || rc=$?
check "borrow-read 인자 초과 → rc 2, 사용법은 표준 오류" "$rc|$out|$(grep -c '^usage: route.sh borrow-read' "$BRO/usage.err")" "2||1"

tr_borrow_ctx_case() {
  local b="$WORK/borrow-ctx" cfg req='{"run_id":"r1","lineage":"S1","event":"first","kind":"implement"}'
  export RUN_DIR="$b/run" RUN_PACE_ROOT="$b/pace"
  mkdir -p "$RUN_DIR" "$b/cwd"
  cd "$b/cwd" || return
  tr_write_inv valid "$RUN_DIR/inventory.json"
  bfile "$b/xdg/cc-lane/borrow.json" '.state = "intent"'
  cfg=$(XDG_STATE_HOME="$b/xdg" route_gather_context "$req" /seat)
  expect "문맥 수집: 절대 XDG_STATE_HOME 의 기록과 경로" "$cfg" \
    ".borrow.state == \"intent\" and .borrow.donor.id == \"u3\" and .borrow_path == \"$b/xdg/cc-lane/borrow.json\""
  cfg=$(XDG_STATE_HOME=rel route_gather_context "$req" /seat)
  expect "문맥 수집: 상대 XDG_STATE_HOME → 손상, 경로 null" "$cfg" '.borrow.state == "corrupt" and .borrow_path == null'
  cfg=$(unset XDG_STATE_HOME; HOME='' route_gather_context "$req" /seat)
  expect "문맥 수집: XDG 없음 + 빈 HOME → 손상, 경로 null" "$cfg" '.borrow.state == "corrupt" and .borrow_path == null'
  cfg=$(unset XDG_STATE_HOME; HOME=relhome route_gather_context "$req" /seat)
  expect "문맥 수집: XDG 없음 + 상대 HOME → 손상, 경로 null" "$cfg" '.borrow.state == "corrupt" and .borrow_path == null'
  cfg=$(XDG_STATE_HOME='' HOME="$b/home" route_gather_context "$req" /seat)
  expect "문맥 수집: XDG 빈 값 + 절대 HOME" "$cfg" \
    ".borrow.state == \"absent\" and .borrow_path == \"$b/home/.local/state/cc-lane/borrow.json\""
}
tr_in_run "$TR_RUN_SH" tr_borrow_ctx_case

# ===========================================================================
# 입력 판독 — 로그 프레임
# ===========================================================================
FR="$WORK/frames"
mkdir -p "$FR"
ts_line() { jq -cn --argjson e "$1" '{type: "assistant", timestamp: ($e | todate | sub("Z$"; ".123Z"))}'; }
rl_line() {
  jq -cn --argjson a "$1" --argjson b "$2" --argjson now "$NOW" '{type: "rate_limit_event",
    rate_limit_info: {rateLimitType: "seven_day", utilization: 0.99,
      unifiedWindows: ({} + (if $a == null then {} else {five_hour: {utilization: $a, resetsAt: ($now + 3600)}} end)
                          + (if $b == null then {} else {seven_day: {utilization: $b, resetsAt: ($now + 86400)}} end))}}'
}
{ ts_line $((NOW - 100)); rl_line 0.2 0.3; } > "$FR/f1.json"
out=$(bash "$TR_ROUTE" frames "$FR/f1.json")
expect "프레임은 unifiedWindows 만 읽고 최상위 값을 무시한다" "$out" \
  ".five_hour.u == 0.2 and .seven_day.u == 0.3 and .five_hour.observed_at_epoch == $((NOW - 100))"
{ rl_line 0.2 0.3; ts_line $((NOW - 100)); } > "$FR/f2.json"
check "앞에 타임스탬프가 없는 프레임은 버린다" "$(bash "$TR_ROUTE" frames "$FR/f2.json")" '{"five_hour":null,"seven_day":null}'
{ ts_line $((NOW - 300)); ts_line $((NOW - 200)); rl_line 0.4 null; ts_line $((NOW - 100)); } > "$FR/f3.json"
out=$(bash "$TR_ROUTE" frames "$FR/f3.json")
expect "관측 시각은 직전 타임스탬프 프레임의 것이고 한 창만 실린 프레임은 그 창만 낸다" "$out" \
  ".five_hour.observed_at_epoch == $((NOW - 200)) and .five_hour.u == 0.4 and .seven_day == null"
{ ts_line $((NOW - 300)); rl_line 0.1 0.1; ts_line $((NOW - 200)); rl_line 0.5 null; } > "$FR/f4.json"
out=$(bash "$TR_ROUTE" frames "$FR/f4.json")
expect "창마다 마지막 판독을 남긴다" "$out" \
  ".five_hour.u == 0.5 and .five_hour.observed_at_epoch == $((NOW - 200)) and .seven_day.u == 0.1 and .seven_day.observed_at_epoch == $((NOW - 300))"

tr_frames_read_case() {
  local b="$FR/read" out
  export RUN_DIR="$b/run"
  mkdir -p "$RUN_DIR/log" "$b/t"
  { ts_line $((NOW - 100)); rl_line 0.2 0.3; } > "$RUN_DIR/log/S1.json"
  { ts_line $((NOW - 50)); rl_line 0.25 null; } > "$RUN_DIR/log/S1.retry.json"
  { ts_line $((NOW - 90)); rl_line 0.6 0.7; } > "$RUN_DIR/log/shift-1.json"
  { ts_line $((NOW - 80)); rl_line 0.9 0.9; } > "$RUN_DIR/log/S2.json"
  live_lease "$b/t" r1 S1 a
  live_lease "$b/t" "r1" "shift#1" b
  live_lease "$b/t" r2 S2 c
  out=$(route_frames_read "$b/t" r1)
  expect "프레임은 이 런의 임대 계정에 귀속된다" "$out" '([.[].account] | unique) == ["a", "b"] and length == 5'
  expect "임대 없는 로그는 버린다" "$out" 'all(.[]; all(.windows[]; .u != 0.9))'
  expect "교대 임대 키에서 shift-<n> 로그를 찾는다" "$out" 'any(.[]; .account == "b" and .windows.seven_day.u == 0.7)'
  expect ".retry 로그도 계보에 귀속된다" "$out" 'any(.[]; .account == "a" and .windows.five_hour.u == 0.25)'
}
tr_in_run "$TR_RUN_SH" tr_frames_read_case

# ===========================================================================
# 입력 판독 — 병합
# ===========================================================================
out=$(classify 'ONLY(["a"]) | USE([UA("a"; 0.5; 0.1) | .windows.five_hour.observed_at_epoch = ($now - 100)])
  | .frames = [{account: "a", observed_at_epoch: ($now - 50), windows: {five_hour: {u: 0.2, resets_at: ($now + 3600)}}}]')
expect "더 신선한 프레임이 이긴다" "$out" '.groups[0].windows.five_hour.u_bp == 2000 and .groups[0].windows.five_hour.source == "stage-log"'
out=$(classify 'ONLY(["a"]) | USE([UA("a"; 0.5; 0.1) | .windows.five_hour.observed_at_epoch = ($now - 100)])
  | .frames = [{account: "a", observed_at_epoch: ($now - 200), windows: {five_hour: {u: 0.2, resets_at: ($now + 3600)}}}]')
expect "더 신선한 사용량 창이 이긴다" "$out" '.groups[0].windows.five_hour.u_bp == 5000'
out=$(classify 'ONLY(["a"]) | USE([UA("a"; 0.5; 0.1) | .windows.five_hour.observed_at_epoch = ($now - 100)])
  | .frames = [{account: "a", observed_at_epoch: ($now - 100), windows: {five_hour: {u: 0.3, resets_at: ($now + 3600)}}}]')
expect "관측 시각이 같으면 큰 쪽이 이긴다" "$out" '.groups[0].windows.five_hour.u_bp == 5000'
out=$(classify 'USE([(UA("a"; 0.5; 0.1) + {org_hash: "h"} | .windows.five_hour.observed_at_epoch = ($now - 100)),
                   (UA("b"; 0.3; 0.1) + {org_hash: "h"} | .windows.five_hour.observed_at_epoch = ($now - 30))])
  | ITEMS([LG("r2"; "S1"; "a"; true), LG("r3"; "S1"; "b"; true)])')
expect "같은 org_hash 는 한 그룹이다" "$out" \
  "(.groups | length) == 1 and .groups[0].group == \"org:h\" and .groups[0].count == 2 and .groups[0].sigma.seven_day == $((2 * TR7))"
expect "그룹 창 값은 구성원 중 가장 신선한 판독" "$out" '.groups[0].windows.five_hour.u_bp == 3000'
out=$(classify '.')
expect "org_hash 없는 계정은 단일 그룹" "$out" '([.groups[].group]) == ["acct:a", "acct:b"]'

# ===========================================================================
# 선택 규칙
# ===========================================================================
MIX='.inventory.accounts = [A("a-u"), A("b-k"), A("c-r"), A("d-x")]
  | USE([UA("b-k"; 0.1; 0.1), UW("c-r"; W(0.9; $now - 10); W(0.05; $now + 86400)), UA("d-x"; 0.1; 1.2)])'
out=$(classify "$MIX")
expect "네 부류가 규칙대로 붙는다" "$out" '[.accounts[] | .class] == ["U", "K", "R", "X"]'
expect "R 이 K·U·X 를 앞선다" "$(decide "$MIX")" '.account == "c-r" and .basis == "first"'
expect "K 가 U 를 앞선다" "$(decide "$MIX | .inventory.accounts |= map(select(.id != \"c-r\"))")" '.account == "b-k"'
expect "U 는 X 를 앞선다" "$(decide "$MIX | .inventory.accounts |= map(select(.id == \"a-u\" or .id == \"d-x\"))")" '.account == "a-u" and .admitted_as == "unknown"'
out=$(decide "$MIX | .inventory.accounts |= map(select(.id == \"d-x\"))")
expect "X 만 남으면 group-exhausted 로 기다린다" "$out" ".verdict == \"WAIT\" and .reason == \"group-exhausted\" and .group == \"acct:d-x\" and .until_epoch == $((NOW + 86400))"
out=$(decide '.inventory.accounts = [A("a-u"), A("z-r")] | USE([UW("z-r"; W(0.9; $now - 10); W(0.6; $now + 86400))])')
expect "reset_elapsed 는 잔여가 적어도 U 아래로 밀리지 않는다" "$out" '.account == "z-r"'

out=$(decide '.inventory.accounts = [A("a"), A("c") + {interactive_reserved: true, unattended: "disabled"}]
  | USE([UA("a"; 0.1; 0.1) + {org_hash: "h"}, UA("c"; 0.1; 0.1) + {org_hash: "h"}])')
expect "interactive_reserved 는 그룹으로 전파된다" "$out" '.verdict == "WAIT"'
out=$(decide '.inventory.accounts = [A("a"), A("c") + {interactive_reserved: true, unattended: "disabled"}]
  | USE([UA("a"; 0.1; 0.1), UA("c"; 0.1; 0.1)])')
expect "다른 그룹의 예약은 막지 않는다" "$out" '.verdict == "GRANT" and .account == "a"'

DRAIN='.inventory.accounts = [A("a") + {unattended: "draining"}] | USE([UA("a"; 0.1; 0.1)])'
expect "draining 은 새 부여에서 빠진다" "$(decide "$DRAIN")" '.verdict == "WAIT"'
expect "draining 은 살아 있는 임대의 유지에 남는다" "$(decide "$DRAIN | REQ({event: \"crash-retry\"}) | ITEMS([LG(\"r1\"; \"S1\"; \"a\"; true)])")" \
  '.verdict == "GRANT" and .basis == "sticky" and .account == "a"'
expect "draining 은 살아 있는 임대의 재개에 남는다" "$(decide "$DRAIN | REQ({event: \"resume\"}) | ITEMS([LG(\"r1\"; \"S1\"; \"a\"; true)])")" \
  '.verdict == "GRANT" and .basis == "resume-bound" and .account == "a"'
out=$(decide "$DRAIN | REQ({event: \"resume\", bound_account: \"a\"})")
expect "반납 뒤 draining 계정의 재개는 PARK" "$out" '.verdict == "PARK" and .reason == "resume-bound-ineligible"'

ONE='ONLY(["a", "b"]) | USE([UA("a"; 0.1; 0.6), UA("b"; 0.1; 0.1)])'
FULL_A='ITEMS([LG("r2"; "S1"; "a"; true)])'
out=$(decide "$ONE | $FULL_A | .leases.items += [LG(\"r1\"; \"S1\"; \"a\"; true)] | REQ({event: \"resume\"})")
expect "살아 있는 자기 임대의 재개는 입장 없이 같은 임대" "$out" \
  '.verdict == "GRANT" and .basis == "resume-bound" and .account == "a" and .nonce == "n-r1-S1" and .txn.op == "hold"'
out=$(decide "$ONE | REQ({event: \"resume\", bound_account: \"a\"})")
expect "반납된 계보의 재개는 묶인 계정에 새로 입장한다" "$out" '.verdict == "GRANT" and .basis == "resume-bound" and .account == "a" and .txn.op == "write"'
out=$(decide "$ONE | $FULL_A | REQ({event: \"resume\", bound_account: \"a\"})")
expect "묶인 계정에 자리가 없으면 옮기지 않고 기다린다" "$out" \
  '.verdict == "WAIT" and .reason == "resume-bound-no-room" and .account == "a" and .group == "acct:a"'
out=$(decide "$ONE | ITEMS([LG(\"r1\"; \"S1\"; \"a\"; false)]) | REQ({event: \"resume\", bound_account: \"a\"})")
expect "stale 자기 임대의 재개도 새 입장이다" "$out" '.verdict == "GRANT" and .basis == "resume-bound" and .txn.op == "write" and .nonce == null'
out=$(decide "$ONE | REQ({event: \"resume\", bound_account: \"zz\"})")
expect "인벤토리에 없는 묶인 계정 → PARK" "$out" '.verdict == "PARK" and .reason == "resume-bound-unknown-account"'
expect "묶인 계정이 없으면 → PARK" "$(decide "$ONE | REQ({event: \"resume\"})")" '.verdict == "PARK" and .reason == "resume-unbound"'
out=$(decide "$ONE | .usage.accounts[0].login = \"expired\" | REQ({event: \"resume\", bound_account: \"a\"})")
expect "로그인이 끊긴 묶인 계정 → PARK" "$out" '.verdict == "PARK" and .reason == "resume-logged-out"'
expect "살아 있는 자기 임대의 계정 로그인이 끊기면 → PARK" "$(decide "$ONE | .usage.accounts[0].login = \"expired\" | ITEMS([LG(\"r1\"; \"S1\"; \"a\"; true)]) | REQ({event: \"resume\"})")" \
  '.verdict == "PARK" and .reason == "resume-logged-out"'
expect "살아 있는 자기 임대의 계정이 소진이면 그 계정으로 기다린다" "$(decide "$ONE | .usage.accounts[0].windows.seven_day.utilization = 1.1 | ITEMS([LG(\"r1\"; \"S1\"; \"a\"; true)]) | REQ({event: \"resume\"})")" \
  '.verdict == "WAIT" and .reason == "resume-bound-exhausted" and .account == "a"'

out=$(decide "$ONE | $FULL_A | .leases.items += [LG(\"r1\"; \"S1\"; \"a\"; true)] | REQ({event: \"crash-retry\"})")
expect "살아 있는 자기 임대의 crash-retry 는 입장 없이 sticky" "$out" '.verdict == "GRANT" and .basis == "sticky" and .account == "a" and .nonce == "n-r1-S1" and .txn.op == "hold"'
out=$(decide "$ONE | ITEMS([LG(\"r1\"; \"S1\"; \"a\"; true)]) | REQ({event: \"hollow-retry\"})")
expect "hollow-retry 도 유지 부류" "$out" '.basis == "sticky" and .account == "a"'
out=$(decide "$ONE | .usage.accounts[0].windows.seven_day.utilization = 1.1 | ITEMS([LG(\"r1\"; \"S1\"; \"a\"; true)]) | REQ({event: \"crash-retry\"})")
expect "유지 부적격이면 reassigned-no-room 으로 옮긴다" "$out" '.verdict == "GRANT" and .basis == "reassigned-no-room" and .account == "b" and .txn.op == "write"'
out=$(decide "$ONE | ITEMS([LG(\"r1\"; \"S1\"; \"a\"; false)]) | REQ({event: \"crash-retry\"})")
expect "stale 자기 임대의 재시도는 같은 계정 재입장이 첫 선호" "$out" '.basis == "sticky" and .account == "a" and .txn.op == "write"'
out=$(decide "$ONE | $FULL_A | .leases.items += [LG(\"r1\"; \"S1\"; \"a\"; false)] | REQ({event: \"crash-retry\"})")
expect "stale 자기 임대 계정에 자리가 없으면 reassigned-no-room" "$out" '.basis == "reassigned-no-room" and .account == "b"'
LIM='USE([UA("a"; 0.1; 0.1), UA("b"; 0.2; 0.2)])'
out=$(decide "$LIM | ITEMS([LG(\"r1\"; \"S1\"; \"a\"; true)]) | REQ({event: \"limit-reclaim\"})")
expect "한도 회수는 직전 계정을 뺀다" "$out" '.verdict == "GRANT" and .basis == "reassigned-after-limit" and .account == "b"'
out=$(decide "$LIM | REQ({event: \"first-reject\", bound_account: \"a\"})")
expect "첫 요청 거부도 직전 계정을 뺀다" "$out" '.basis == "reassigned-after-limit" and .account == "b"'
out=$(decide "$LIM | ONLY([\"a\"]) | ITEMS([LG(\"r1\"; \"S1\"; \"a\"; true)]) | REQ({event: \"limit-reclaim\"})")
expect "직전 계정뿐이면 기다린다" "$out" '.verdict == "WAIT" and .reason == "no-room"'
expect "after_wait 이면 근거 after-wait" "$(decide 'REQ({after_wait: true})')" '.verdict == "GRANT" and .basis == "after-wait"'
expect "sticky 계정이 동률을 깬다" "$(decide 'USE([UA("a"; 0.1; 0.1), UA("b"; 0.1; 0.1)]) | .sticky = ["b"]')" '.account == "b"'

NOROOM='USE([UW("a"; W(0.1; $now + 3600); W(0.95; $now + 5000)), UW("b"; W(0.1; $now + 3600); W(0.95; $now + 3000))])'
out=$(decide "$NOROOM")
expect "후보가 없으면 최소 ready_at 의 그룹으로 기다린다" "$out" \
  ".verdict == \"WAIT\" and .reason == \"no-room\" and .group == \"acct:b\" and .until_epoch == $((NOW + 3000)) and .account == null"
UCC='USE([]) | ITEMS([LG("r2"; "S1"; "a"; true), LG("r3"; "S1"; "b"; true)])'
out=$(decide "$UCC")
expect "미지 동시로만 막히면 until 없이 기다린다" "$out" '.verdict == "WAIT" and .reason == "unknown-concurrency" and .until_epoch == null and .group == "acct:a"'
out=$(decide "$NOROOM | REQ({kind: \"shift\", lineage: \"shift#1\"})")
expect "교대는 기다리지 않고 좌석으로 떨어진다" "$out" '.verdict == "GRANT" and .basis == "shift-seat-fallback" and .config_dir == "/seat" and .account == null and .txn.op == "none"'
out=$(decide "REQ({kind: \"shift\", lineage: \"shift#1\"}) | .leases = {state: \"corrupt\", items: [], corrupt: [{path: \"/t/x.lease\", key: \"r9+x\", why: \"schema\"}], stale_corrupt: []}")
expect "깨진 임대 표에서도 교대는 좌석 폴백" "$out" '.basis == "shift-seat-fallback"'
out=$(decide '.inventory = {state: "absent", accounts: []}')
expect "라우팅 꺼짐은 좌석 single-seat" "$out" '.verdict == "GRANT" and .basis == "single-seat" and .config_dir == "/seat" and .dormant == false'
out=$(decide '.inventory = {state: "corrupt", accounts: []} | REQ({kind: "shift", lineage: "shift#1"})')
expect "깨진 인벤토리는 교대에도 PARK" "$out" '.verdict == "PARK" and .reason == "inventory-corrupt"'

out=$(decide "$NOROOM | .deadline = {deadline_epoch: ($NOW + 3100), expected_duration_s: 200}")
expect "until + 기대 소요 > 마감 → PARK deadline" "$out" ".verdict == \"PARK\" and .reason == \"deadline\" and .ready_at == $((NOW + 3000))"
out=$(decide "$NOROOM | .deadline = {deadline_epoch: ($NOW + 3300), expected_duration_s: 200}")
expect "마감 안이면 기다린다" "$out" '.verdict == "WAIT"'
out=$(decide "$UCC | .deadline = {deadline_epoch: ($NOW + 1), expected_duration_s: 200}")
expect "until 이 없으면 마감이 있어도 기다린다" "$out" '.verdict == "WAIT" and .until_epoch == null'
out=$(decide "$ONE | $FULL_A | REQ({event: \"resume\", bound_account: \"a\"}) | .deadline = {deadline_epoch: ($NOW + 100), expected_duration_s: 200}")
expect "재개 대기도 마감을 넘기면 PARK deadline" "$out" '.verdict == "PARK" and .reason == "deadline"'

FIFO='ONLY(["a"]) | USE([UA("a"; 0.1; 0.1)])'
out=$(decide "$FIFO | ITEMS([LR(\"r2\"; \"S7\"; \"a\"; \"wait\"; null; true; 1)])")
expect "더 이른 대기자가 있으면 신참은 fifo-yield" "$out" '.verdict == "WAIT" and .reason == "fifo-yield" and .group == "acct:a"'
out=$(decide "$FIFO | ITEMS([LR(\"r1\"; \"S1\"; \"a\"; \"wait\"; null; true; 1), LR(\"r2\"; \"S7\"; \"a\"; \"wait\"; null; true; 2)])")
expect "맨 앞 대기자는 입장한다" "$out" '.verdict == "GRANT" and .account == "a" and .txn.record.seq == 3'
out=$(decide "$FIFO | ITEMS([LR(\"r2\"; \"S7\"; \"a\"; \"wait\"; null; false; 1)])")
expect "죽은 대기자는 막지 않는다" "$out" '.verdict == "GRANT"'

# 차용 기록. 문맥의 borrow 를 직접 지정한다.
for ev in first crash-retry resume shift classify; do
  run=decide
  case "$ev" in
    first) f='.' ;;
    crash-retry) f='ITEMS([LG("r1"; "S1"; "a"; true)]) | REQ({event: "crash-retry"})' ;;
    resume) f='ITEMS([LG("r1"; "S1"; "a"; true)]) | REQ({event: "resume"})' ;;
    shift) f="$NOROOM | REQ({kind: \"shift\", lineage: \"shift#1\"})" ;;
    classify) f='.'; run=classify ;;
  esac
  want=$($run "$f")
  check "차용 기록 부재·none 의 $ev 출력은 키 없는 출력과 바이트가 같다" \
    "$($run "$f | .borrow = {state: \"absent\"}")
$($run "$f | .borrow = {state: \"none\"}")" "$want
$want"
done
check "none 이 기증자를 지명해도 기록 부재와 바이트가 같다" \
  "$(decide '.borrow = {state: "none", donor: {id: "a", config_dir: "/h/.claude-a"}}')" "$(decide '.')"
expect "차용 중 기증자는 풀에서 빠진다" "$(decide 'LEND("a")')" '.verdict == "GRANT" and .account == "b"'
BGRP='.inventory.accounts = [A("a"), A("b"), A("c")]
  | USE([UA("a"; 0.2; 0.2) + {org_hash: "h"}, UA("b"; 0.3; 0.3), UA("c"; 0.1; 0.1) + {org_hash: "h"}])'
expect "차용이 없으면 그룹 h 가 먼저다" "$(decide "$BGRP")" '.account == "a"'
expect "기증자와 그룹을 공유하는 계정도 풀에서 빠지고 다른 그룹은 남는다" "$(decide "$BGRP | LEND(\"a\")")" '.verdict == "GRANT" and .account == "b"'
expect "분류는 기증자와 그룹 동료를 표시한다" "$(classify "$BGRP | LEND(\"a\")")" '[.accounts[] | .borrowed // null] == ["donor", null, "group"]'
out=$(decide "$BGRP | LEND(\"a\") | ITEMS([LG(\"r1\"; \"S1\"; \"c\"; false)]) | REQ({event: \"crash-retry\"})")
expect "그룹 동료 위 재시도 재진입도 빠진다" "$out" '.verdict == "GRANT" and .basis == "reassigned-no-room" and .account == "b"'
expect "기증자는 id 만 일치해도 기증자" "$(decide '.borrow = BRW("borrowed"; "a"; "/elsewhere")')" '.account == "b"'
expect "기증자는 config_dir 만 일치해도 기증자" "$(decide '.borrow = BRW("borrowed"; "zz"; "/h/.claude-a")')" '.account == "b"'
expect "끝 슬래시가 붙은 기증자 디렉터리는 일치가 아니다" "$(decide '.borrow = BRW("borrowed"; "zz"; "/h/.claude-a/")')" '.account == "a"'
for acct in a c; do
  for f in 'REQ({nonce: "n-r1-S1"})' 'REQ({event: "crash-retry"})' 'REQ({event: "resume"})'; do
    g="$BGRP | ITEMS([LG(\"r1\"; \"S1\"; \"$acct\"; true)]) | $f"
    out=$(decide "$g | LEND(\"a\")")
    check "차용 중 $acct 위의 이어 가기 $f 는 기록 부재와 같다" "$out" "$(decide "$g")"
    seen "$out"
  done
done
out=$(decide "$BGRP | LEND(\"a\") | REQ({event: \"resume\", bound_account: \"c\"})")
expect "그룹 동료의 비생존 바인딩 재개 → PARK resume-bound-ineligible" "$out" '.verdict == "PARK" and .reason == "resume-bound-ineligible"'
BC='.borrow = {state: "corrupt"}'
expect "손상 차용 기록: 풀 → PARK borrow-record-corrupt" "$(decide "$BC")" '.verdict == "PARK" and .reason == "borrow-record-corrupt"'
out=$(decide "$BC | ITEMS([LG(\"r1\"; \"S1\"; \"a\"; false)]) | REQ({event: \"crash-retry\"})")
expect "손상 차용 기록: 재시도 재진입 → PARK" "$out" '.verdict == "PARK" and .reason == "borrow-record-corrupt"'
out=$(decide "$BC | REQ({event: \"resume\", bound_account: \"a\"})")
expect "손상 차용 기록: 바인딩 재개 → PARK" "$out" '.verdict == "PARK" and .reason == "borrow-record-corrupt"'
for f in 'REQ({nonce: "n-r1-S1"})' '.' 'REQ({event: "crash-retry"})' 'REQ({event: "resume"})'; do
  out=$(decide "$BC | ITEMS([LG(\"r1\"; \"S1\"; \"a\"; true)]) | $f")
  expect "손상 차용 기록에서도 살아 있는 자기 임대의 이어 가기 $f 는 진행" "$out" '.verdict == "GRANT" and .account == "a" and .nonce == "n-r1-S1"'
done
out=$(decide "$BC | REQ({kind: \"shift\", lineage: \"shift#1\"})")
expect "손상 차용 기록의 교대는 손상 표시 좌석" "$out" '.basis == "shift-seat-fallback" and .borrow == {state: "corrupt", donor: null}'
out=$(decide "$BC | .leases = {state: \"corrupt\", items: [], corrupt: [{path: \"/t/x.lease\", key: \"r9+x\", why: \"schema\"}], stale_corrupt: []}")
expect "손상 차용 기록과 깨진 표가 겹치면 lease-table-corrupt" "$out" '.verdict == "PARK" and .reason == "lease-table-corrupt"'
SEAT='.inventory = {state: "absent", accounts: []}'
out=$(decide "$SEAT | .borrow = BRW(\"borrowed\"; \"u3\"; \"/h/.claude-u3\")")
expect "좌석 == lane 이면 single-seat 봉투 끝에 borrow" "$out" \
  '.basis == "single-seat" and .borrow == {state: "borrowed", donor: "u3"} and (keys_unsorted | map(select(. != "txn")) | last) == "borrow"'
check "좌석 == lane + / 이면 표시하지 않는다" "$(decide "$SEAT | .borrow = (BRW(\"borrowed\"; \"u3\"; \"/h/.claude-u3\") | .lane_config_dir = \"/seat/\")")" "$(decide "$SEAT")"
check "좌석 ≠ lane 이면 표시하지 않는다" "$(decide "$SEAT | .borrow = (BRW(\"borrowed\"; \"u3\"; \"/h/.claude-u3\") | .lane_config_dir = \"/other\")")" "$(decide "$SEAT")"
expect "손상 기록의 좌석 표시" "$(decide "$SEAT | $BC")" '.basis == "single-seat" and .borrow == {state: "corrupt", donor: null}'

# ===========================================================================
# 예약 산술
# ===========================================================================
B7=$((10000 - TK7 * TC7_BP))
expect "합이 정확히 10000 이면 입장" "$(admit1 "ONLY([\"a\"]) | USE([UB(\"a\"; 1000; $B7)])")" '.admitted == true and .admitted_as == "known"'
expect "1 bp 넘으면 거부" "$(admit1 "ONLY([\"a\"]) | USE([UB(\"a\"; 1000; $((B7 + 1)))])")" '.admitted == false and .failed == ["seven_day"]'
S7=1000
B7S=$((10000 - S7 - TK7 * TC7_BP))
SIG="ITEMS([LR(\"r2\"; \"S1\"; \"a\"; \"grant\"; {five_hour: 0, seven_day: $S7}; true; 1)])"
expect "Σ 를 포함한 경계에서 입장" "$(admit1 "ONLY([\"a\"]) | USE([UB(\"a\"; 1000; $B7S)]) | $SIG")" '.admitted == true'
expect "Σ 를 포함한 경계 + 1 bp 에서 거부" "$(admit1 "ONLY([\"a\"]) | USE([UB(\"a\"; 1000; $((B7S + 1)))]) | $SIG")" '.admitted == false'
B5=$((10000 - TK5 * TC5_BP))
SWAPCTX="ONLY([\"a\"]) | USE([UB(\"a\"; $B5; 1000)]) | .config.cap_bp = 10000"
expect "창마다의 k 로 입장" "$(admit1 "$SWAPCTX")" '.admitted == true'
out=$(admit1 "$SWAPCTX | .config.k.default = {five_hour: $TK7, seven_day: $TK5}")
expect "두 창의 k 를 바꾸면 판정이 바뀐다" "$out" '.admitted == false and (.failed | index("five_hour") != null)'
expect "저장되는 예약은 k·c" "$(admit1 "$SWAPCTX")" ".reservation_bp == {five_hour: $TR5, seven_day: $TR7}"

CAPC=".config.c.five_hour.default = 0.01 | .config.cap_bp = $TCAP | ONLY([\"a\"])"
expect "5시간 0.7999 는 상한 아래" "$(admit1 "$CAPC | USE([UA(\"a\"; 0.7999; 0.1)])")" '.admitted == true'
expect "5시간 0.80 은 상한에서 거부" "$(admit1 "$CAPC | USE([UA(\"a\"; 0.80; 0.1)])")" '.admitted == false and .failed == ["cap"]'
expect "5시간 0.8001 은 거부" "$(admit1 "$CAPC | USE([UA(\"a\"; 0.8001; 0.1)])")" '.admitted == false and .failed == ["cap"]'
check "0.57 은 곱해 내리면 경계를 놓치는 표본이다" "$(jq -n '0.57 * 10000 | floor')" 5699
expect "0.57 표본은 반올림으로 상한 5700 에서 거부" "$(admit1 ".config.c.five_hour.default = 0.01 | .config.cap_bp = 5700 | ONLY([\"a\"]) | USE([UA(\"a\"; 0.57; 0.1)])")" \
  '.admitted == false and .failed == ["cap"]'
expect "reset_elapsed 5시간 창은 상한을 통과한다" "$(admit1 "$CAPC | USE([UW(\"a\"; W(0.95; \$now - 10); W(0.1; \$now + 86400))])")" '.admitted == true'
out=$(decide "$CAPC | USE([UA(\"a\"; 0.9; 0.1)]) | ITEMS([LG(\"r1\"; \"S1\"; \"a\"; true)]) | REQ({event: \"crash-retry\"})")
expect "상한은 살아 있는 임대의 유지에 걸리지 않는다" "$out" '.verdict == "GRANT" and .basis == "sticky"'
rc=0; ctx 'del(.config.cap_bp)' | bash "$TR_ROUTE" decide >/dev/null 2>&1 || rc=$?
check "cap_bp 가 없으면 rc 2" "$rc" 2

expect "c 는 default 로 떨어진다" "$(admit1 'ONLY(["a"])')" ".reservation_bp.seven_day == $((TK7 * TC7_BP))"
expect "c 는 by_kind 가 default 를 이긴다" "$(admit1 'ONLY(["a"]) | .config.c.seven_day.by_kind.implement = 0.05')" ".reservation_bp.seven_day == $((TK7 * 500))"
expect "c 는 by_group 이 by_kind 를 이긴다" "$(admit1 'ONLY(["a"]) | .config.c.seven_day.by_kind.implement = 0.05 | .config.c.seven_day.by_group["acct:a"] = 0.1')" \
  ".reservation_bp.seven_day == $((TK7 * 1000))"

UNK='ONLY(["a"]) | USE([])'
expect "미지 그룹의 첫 입장은 unknown 이고 예약을 싣는다" "$(admit1 "$UNK")" \
  ".admitted == true and .admitted_as == \"unknown\" and .reservation_bp == {five_hour: $TR5, seven_day: $TR7}"
expect "미지 그룹에 살아 있는 부여가 있으면 거부" "$(admit1 "$UNK | ITEMS([LG(\"r2\"; \"S1\"; \"a\"; true)])")" '.admitted == false and .failed == ["unknown-concurrency"]'
expect "미지 그룹에 예약 없는 대기자가 있어도 거부" "$(admit1 "$UNK | ITEMS([LR(\"r2\"; \"S1\"; \"a\"; \"wait\"; null; true; 1)])")" '.admitted == false'
out=$(admit1 "$UNK | ITEMS([LR(\"r2\"; \"S1\"; \"a\"; \"future\"; {five_hour: 1, seven_day: 1}; true; 1)])")
expect "예약 있는 모르는 kind 는 미지 상한에 센다" "$out" '.admitted == false'
expect "예약 없는 모르는 kind 는 무시한다" "$(admit1 "$UNK | ITEMS([LR(\"r2\"; \"S1\"; \"a\"; \"future\"; null; true; 1)])")" '.admitted == true'
expect "죽은 항목은 미지 상한에 세지 않는다" "$(admit1 "$UNK | ITEMS([LG(\"r2\"; \"S1\"; \"a\"; false)])")" '.admitted == true'

RST='ONLY(["a"]) | USE([UW("a"; W(0.9; $now - 10); W(0.9; $now - 10))])'
out=$(classify "$RST | ITEMS([LR(\"r2\"; \"S1\"; \"a\"; \"grant\"; {five_hour: 5000, seven_day: 5000}; true; 1)])")
expect "리셋이 지나도 저장된 예약은 Σ 에 남는다" "$out" '.groups[0].sigma == {five_hour: 5000, seven_day: 5000}'
out=$(classify "$RST | ITEMS([LR(\"r2\"; \"S1\"; \"a\"; \"grant\"; {five_hour: 5000, seven_day: 5000}; false; 1)])")
expect "보유자가 모두 죽은 예약은 Σ 에서 빠진다" "$out" '.groups[0].sigma == {five_hour: 0, seven_day: 0}'

tr_consts_case() {
  local cfg want
  cfg=$(route__config_json "$((RUN_PACE_SESSION_WINDOW_PCT_MAX * 100))")
  for pair in K_FIVE_HOUR:.k.default.five_hour K_SEVEN_DAY:.k.default.seven_day K_SHIFT:.k.shift.seven_day \
              C_FIVE_HOUR:.c.five_hour.default C_SEVEN_DAY:.c.seven_day.default \
              TTL_STAGE_LOG_S:'.ttl_s["stage-log"]' TTL_TRACKER_S:.ttl_s.tracker FILE_STALE_FACTOR:.file_stale_factor; do
    want=$(sed -n "s/^  \*) readonly ROUTE_${pair%%:*}=\(.*\) ;;\$/\1/p" "$TR_ROUTE")
    check "config 가 상수 ROUTE_${pair%%:*} 를 그대로 옮긴다" "$(printf '%s' "$cfg" | jq -r "${pair#*:}")" "$want"
  done
  want=$(sed -n 's/^readonly RUN_PACE_SESSION_WINDOW_PCT_MAX=\([0-9]*\).*$/\1/p' "$TR_RUN_SH")
  export RUN_DIR="$WORK/consts/run" RUN_PACE_ROOT="$WORK/consts/pace"
  mkdir -p "$RUN_DIR"
  tr_write_inv valid "$RUN_DIR/inventory.json"
  cfg=$(route_gather_context '{"run_id":"r1","lineage":"S1","event":"first","kind":"implement"}' "$HOME/.claude")
  check "gather 의 cap_bp 는 run.sh 상한 × 100" "$(printf '%s' "$cfg" | jq -r '.config.cap_bp')" "$((want * 100))"
  check "gather 는 좌석을 인자로 받는다" "$(printf '%s' "$cfg" | jq -r '.seat.config_dir')" "$HOME/.claude"
  check "gather 는 표를 만들지 않는다" "$([ -e "$RUN_PACE_ROOT" ] && printf 있음 || printf 없음)" "없음"
}
tr_in_run "$TR_RUN_SH" tr_consts_case

# ===========================================================================
# 임대 표
# ===========================================================================
T="$WORK/lt"
mkdir -p "$T"
tnew() { local d="$T/$1"; rm -rf "$d"; printf '%s' "$d"; }

d=$(tnew absent)
out=$(txn "$d" 'USE([UA("a"; 0.1; 1.2), UA("b"; 0.1; 1.2)])')
expect "부재 표에서 쓰지 않는 결정" "$out" '.verdict == "WAIT" and (has("txn") | not)'
check "쓰지 않는 결정 뒤 표 디렉터리가 없다" "$([ -e "$d" ] && printf 있음 || printf 없음)" "없음"
out=$(txn "$d" '.')
expect "부재 표에서 첫 부여" "$out" '.verdict == "GRANT" and .basis == "first" and (.nonce | test("^[0-9a-f]{32}$"))'
check "첫 부여 뒤 임대 파일 하나" "$(count_files "$d")" 1
f=$(ls "$d"/*.lease)
expect "임대 파일은 보유자와 부여 필드를 싣는다" "$(cat "$f")" \
  ".kind == \"grant\" and .holders[0].pid == $TR_HOLDER and .schema == \"$LEASE_SCHEMA\" and .run_id == \"r1\" and .lineage == \"S1\""
check "임대 파일 이름은 인코딩된 키" "$(basename "$f")" "r1+%531.lease"

corrupt_case() {
  # corrupt_case <이름> <파일 내용을 쓰는 명령>
  local d
  d=$(tnew "c-$1")
  mkdir -p "$d"
  eval "$2"
  out=$(txn "$d" '.')
  expect "깨진 표($1) → PARK lease-table-corrupt" "$out" \
    '.verdict == "PARK" and .reason == "lease-table-corrupt" and (.recovery | test("mv .*[.]quarantine"))'
}
corrupt_case "파싱 불가" 'printf "{" > "$d/r9+x.lease"'
corrupt_case "모르는 스키마" 'put_lease "$d" r9 S9 grant a "$RES_JSON" "$TR_HOLDER" "$TR_HOLDER_FP"; f=$(ls "$d"/*.lease); jq -c ".schema = \"cc-cmds-lease v9\"" "$f" > "$f.n"; mv "$f.n" "$f"'
corrupt_case "잘린 파일" 'put_lease "$d" r9 S9 grant a "$RES_JSON" "$TR_HOLDER" "$TR_HOLDER_FP"; f=$(ls "$d"/*.lease); head -c 40 "$f" > "$f.n"; mv "$f.n" "$f"'
corrupt_case "키 불일치" 'put_lease "$d" r9 S9 grant a "$RES_JSON" "$TR_HOLDER" "$TR_HOLDER_FP"; mv "$d"/*.lease "$d/r9+%538.lease"'
corrupt_case "정수 아닌 예약" 'put_lease "$d" r9 S9 grant a "{\"five_hour\":1.5,\"seven_day\":2}" "$TR_HOLDER" "$TR_HOLDER_FP"'
d=$(tnew c-shift)
mkdir -p "$d"
printf '{' > "$d/r9+x.lease"
expect "깨진 표에서 교대는 좌석 폴백" "$(txn "$d" 'REQ({kind: "shift", lineage: "shift#1"})')" '.verdict == "GRANT" and .basis == "shift-seat-fallback"'
check "좌석 폴백은 임대를 쓰지 않는다" "$(count_files "$d")" 1
d=$(tnew c-own)
mkdir -p "$d"
printf '{' > "$d/$(tr_key r1 S1).lease"
expect "자기 파일이 깨지면 PARK own-lease-corrupt" "$(txn "$d" '.')" '.verdict == "PARK" and .reason == "own-lease-corrupt"'
d=$(tnew c-own-shift)
mkdir -p "$d"
printf '{' > "$d/$(tr_key r1 'shift#1').lease"
expect "교대 자기 파일이 깨지면 좌석 폴백" "$(txn "$d" 'REQ({kind: "shift", lineage: "shift#1"})')" '.basis == "shift-seat-fallback"'
d=$(tnew c-live)
live_lease "$d" r1 S1 a
printf '{' > "$d/r9+x.lease"
expect "깨진 표에서도 살아 있는 자기 임대의 유지는 진행한다" "$(txn "$d" 'REQ({event: "crash-retry"})')" '.verdict == "GRANT" and .basis == "sticky"'
expect "깨진 표에서도 살아 있는 자기 임대의 재개는 진행한다" "$(txn "$d" 'REQ({event: "resume"})')" '.verdict == "GRANT" and .basis == "resume-bound"'
d=$(tnew c-stale)
dead_lease "$d" r1 S1 a
printf '{' > "$d/r9+x.lease"
expect "깨진 표에서 stale 자기 임대의 재시도는 PARK" "$(txn "$d" 'REQ({event: "crash-retry"})')" '.verdict == "PARK" and .reason == "lease-table-corrupt"'
expect "깨진 표에서 stale 자기 임대의 재개는 PARK" "$(txn "$d" 'REQ({event: "resume", bound_account: "a"})')" '.verdict == "PARK" and .reason == "lease-table-corrupt"'
d=$(tnew c-oldschema)
put_lease "$d" r9 S9 grant a "$RES_JSON" "$TR_HOLDER" "$TR_HOLDER_FP"
f=$(ls "$d"/*.lease)
jq -c '.schema = "cc-cmds-lease v0"' "$f" > "$f.n"
mv "$f.n" "$f"
tr_age "$f" 978307200
expect "부팅 전 mtime 이어도 파싱되는 모르는 스키마는 깨짐" "$(txn "$d" '.' --boot-epoch "$((NOW - 10))")" '.verdict == "PARK" and .reason == "lease-table-corrupt"'

# stale-깨짐: 부팅 전 파싱 불가 파일은 제외·보고·보존, 현 부팅이면 PARK.
d=$(tnew stale-corrupt)
mkdir -p "$d"
printf '' > "$d/r9+x.lease"
tr_age "$d/r9+x.lease" 978307200
out=$(txn "$d" '.' --boot-epoch "$((NOW - 10))")
expect "부팅 전 파싱 불가 파일은 PARK 없이 보고된다" "$out" ".verdict == \"GRANT\" and .stale_corrupt == [\"$d/r9+x.lease\"]"
check "부팅 전 파싱 불가 파일은 디스크에 남는다" "$([ -f "$d/r9+x.lease" ] && printf 있음)" "있음"
d=$(tnew stale-corrupt-noboot)
mkdir -p "$d"
printf '' > "$d/r9+x.lease"
tr_age "$d/r9+x.lease" 978307200
expect "부팅 시각이 비면 건너뛰지 않고 PARK" "$(txn "$d" '.')" '.verdict == "PARK" and .reason == "lease-table-corrupt"'
d=$(tnew stale-corrupt-current)
mkdir -p "$d"
printf '' > "$d/r9+x.lease"
expect "현 부팅의 파싱 불가 파일은 PARK" "$(txn "$d" '.' --boot-epoch "$((NOW - 10))")" '.verdict == "PARK" and .reason == "lease-table-corrupt"'

# 대기 항목과 대기 프리미티브.
d=$(tnew waits)
wput() { bash "$TR_ROUTE" lease-wait-put --table "$d" --now "$NOW" --run-id "$1" --lineage "$2" --account a --config-dir /h/.claude-a --holder "$TR_HOLDER"; }
w1=$(wput r1 S1)
w2=$(wput r1 S2)
check "lease-wait-put 의 seq 는 1 씩 는다" "$(printf '%s' "$w1" | jq -r .seq),$(printf '%s' "$w2" | jq -r .seq)" "1,2"
expect "대기 항목은 예약을 싣지 않는다" "$w1" '.kind == "wait" and (has("reservation_bp") | not)'
w1b=$(wput r1 S1)
check "같은 키의 대기 항목은 자리를 지킨다" "$(printf '%s' "$w1b" | jq -r .seq)" 1
leases=$(tr_table_json "$d")
expect "예약 없는 대기 항목만 있는 표는 유효" "$leases" '.state == "valid" and (.items | length) == 2'
out=$(ctx 'ONLY(["a"]) | USE([UA("a"; 0.1; 0.1)]) | REQ({run_id: "r5"})' | jq -c --argjson l "$leases" '.leases = $l' | bash "$TR_ROUTE" classify)
expect "예약 없는 대기 항목은 Σ 에 0" "$out" '.groups[0].sigma == {five_hour: 0, seven_day: 0} and .groups[0].count == 2'
out=$(ctx 'ONLY(["a"]) | USE([]) | REQ({run_id: "r5"})' | jq -c --argjson l "$leases" '.leases = $l' | bash "$TR_ROUTE" admit)
expect "예약 없는 대기 항목도 미지 그룹 상한에 센다" "$out" '.[0].admitted == false and .[0].failed == ["unknown-concurrency"]'
rc=0; bash "$TR_ROUTE" lease-wait-drop "$d" r1 S2 wrong-nonce || rc=$?
check "nonce 가 다른 lease-wait-drop 은 rc 0" "$rc" 0
check "nonce 가 다른 lease-wait-drop 은 지우지 않는다" "$(count_files "$d")" 2
bash "$TR_ROUTE" lease-wait-drop "$d" r1 S2 "$(printf '%s' "$w2" | jq -r .nonce)"
check "맞는 nonce 의 lease-wait-drop 은 지운다" "$(count_files "$d")" 1
live_lease "$d" r1 S3 a
rc=0; wput r1 S3 >/dev/null 2>&1 || rc=$?
check "부여가 있는 키의 lease-wait-put 은 거부" "$rc" 1

# `--group` 은 그룹의 대표 계정(그 그룹에 드는 enabled 계정 중 가장 작은 id)을 고른다.
GW="$WORK/gwait"
mkdir -p "$GW/state/cc-lane"
jq -cn --arg h "$HOME" '{schema: "cc-lane-accounts v1", accounts: [
    {id: "c", config_dir: ($h + "/.claude-c"), label: "c", interactive_reserved: false, unattended: "enabled", added_at: 0},
    {id: "b", config_dir: ($h + "/.claude-b"), label: "b", interactive_reserved: false, unattended: "enabled", added_at: 0},
    {id: "a", config_dir: ($h + "/.claude-a"), label: "a", interactive_reserved: false, unattended: "disabled", added_at: 0}]}' > "$GW/inv.json"
jq -cn --argjson now "$NOW" --arg h "$HOME" '{schema: "cc-lane-usage v1", written_at_epoch: $now, publish_interval_s: 300,
    accounts: [("a", "b") as $i | {id: $i, config_dir: ($h + "/.claude-" + $i), org_hash: "h1", login: "ok", status: "allowed"}]}' \
  > "$GW/state/cc-lane/usage.json"
gput() {
  # gput <키 lineage> <그룹> [추가 인자…]
  local lin="$1" g="$2"
  shift 2
  XDG_STATE_HOME="$GW/state" bash "$TR_ROUTE" lease-wait-put --table "$GW/t" --now "$NOW" --run-id r1 --lineage "$lin" \
    --group "$g" --inventory "$GW/inv.json" --holder "$TR_HOLDER" "$@"
}
out=$(gput G1 org:h1)
expect "--group 조직 그룹의 대표는 enabled 중 가장 작은 id" "$out" '.kind == "wait" and .account == "b" and (.config_dir | endswith("/.claude-b"))'
out=$(gput G2 acct:c)
expect "--group 단독 계정 그룹의 대표는 그 계정" "$out" '.account == "c"'
check "--group 대기 항목도 도착 순서의 seq" "$(printf '%s' "$out" | jq -r .seq)" 2
rc=0; gput G3 acct:a >/dev/null 2>&1 || rc=$?
check "--group 에 enabled 계정이 없으면 rc 3" "$rc" 3
rc=0; gput G4 org:zz >/dev/null 2>&1 || rc=$?
check "--group 에 드는 계정이 없으면 rc 3" "$rc" 3
check "고를 계정이 없는 --group 은 쓰지 않는다" "$(count_files "$GW/t")" 2
rc=0; gput G5 org:h1 --account b >/dev/null 2>&1 || rc=$?
check "--group 과 --account 를 함께 주면 rc 2" "$rc" 2
rc=0; XDG_STATE_HOME="$GW/state" bash "$TR_ROUTE" lease-wait-put --table "$GW/t" --now "$NOW" --run-id r1 --lineage G6 \
  --group org:h1 --holder "$TR_HOLDER" >/dev/null 2>&1 || rc=$?
check "--group 에 --inventory 가 없으면 rc 2" "$rc" 2
printf '{"schema":' > "$GW/bad.json"
rc=0; XDG_STATE_HOME="$GW/state" bash "$TR_ROUTE" lease-wait-put --table "$GW/t" --now "$NOW" --run-id r1 --lineage G7 \
  --group org:h1 --inventory "$GW/bad.json" --holder "$TR_HOLDER" >/dev/null 2>&1 || rc=$?
check "--group 의 인벤토리가 깨지면 rc 3" "$rc" 3
d=$(tnew wait-null)
live_lease "$d" r2 S1 a
live_lease "$d" r3 S1 b
out=$(txn "$d" 'USE([])')
expect "until 없는 대기" "$out" '.verdict == "WAIT" and .until_epoch == null'
check "until 없는 대기는 파일을 쓰지 않는다" "$(count_files "$d")" 2
d=$(tnew wait-grant)
put_lease "$d" r1 S1 wait a null "$TR_HOLDER" "$TR_HOLDER_FP" 1 n-wait
out=$(txn "$d" 'ONLY(["a"]) | USE([UA("a"; 0.1; 0.6)])')
expect "대기자가 부여로 바뀐다" "$out" '.verdict == "GRANT" and .nonce != "n-wait"'
check "대기에서 부여로 바뀌어도 파일은 하나" "$(count_files "$d")" 1
leases=$(tr_table_json "$d")
out=$(ctx 'ONLY(["a"]) | USE([UA("a"; 0.1; 0.6)]) | REQ({run_id: "r5"})' | jq -c --argjson l "$leases" '.leases = $l' | bash "$TR_ROUTE" classify)
expect "대기 → 부여 뒤 Σ 는 부여 예약 한 번" "$out" ".groups[0].sigma.seven_day == $TR7 and .groups[0].count == 1"

# 교대의 락 대기 초과·재검증 실패는 좌석 폴백, 나머지는 WAIT.
d=$(tnew force-reval)
out=$(ctx '.' | env TRH_REVAL=fail bash "$WRAP" lease-txn --table "$d" --now "$NOW" --boot-epoch "" --holder "$TR_HOLDER")
expect "재검증 실패 → WAIT lease-contention" "$out" '.verdict == "WAIT" and .reason == "lease-contention"'
check "재검증 실패 뒤 자기 항목이 지워진다" "$(count_files "$d")" 0
out=$(ctx 'REQ({kind: "shift", lineage: "shift#1"}) | USE([])' | env TRH_REVAL=fail bash "$WRAP" lease-txn --table "$d" --now "$NOW" --boot-epoch "" --holder "$TR_HOLDER")
expect "교대의 재검증 실패는 좌석 폴백" "$out" '.verdict == "GRANT" and .basis == "shift-seat-fallback"'
check "교대 좌석 폴백 뒤 임대가 없다" "$(count_files "$d")" 0

# 생존 네 갈래와 Σ.
tr_alive_case() {
  local d="$T/alive" leases rc
  . "$TR_ORCH/liveness.sh"
  . "$TR_ROUTE"
  mkdir -p "$d"
  put_lease "$d" r2 L1 grant a "$RES_JSON" "$TR_HOLDER" "$TR_HOLDER_FP"
  put_lease "$d" r2 L2 grant a "$RES_JSON" "$TR_DEAD" "$TR_DEAD_FP"
  put_lease "$d" r2 L3 grant a "$RES_JSON" "$TR_HOLDER" "Thu Jan 1 00:00:00 1970"
  leases=$(route__table_read "$d" "")
  expect "살아 있는 보유자의 임대는 산다" "$leases" 'any(.items[]; .lineage == "L1" and .live == true)'
  expect "죽은 pid 의 임대는 stale" "$leases" 'any(.items[]; .lineage == "L2" and .live == false)'
  expect "지문이 다른 pid 는 재사용이라 stale" "$leases" 'any(.items[]; .lineage == "L3" and .live == false)'
  out=$(ctx 'ONLY(["a"]) | USE([UA("a"; 0.1; 0.1)]) | REQ({run_id: "r5"})' | jq -c --argjson l "$leases" '.leases = $l' | bash "$TR_ROUTE" classify)
  expect "Σ 는 살아 있는 임대만 센다" "$out" ".groups[0].sigma.seven_day == $TR7"
  rm -f "$d/$(route__key r2 L1).lease"
  leases=$(route__table_read "$d" "")
  expect "반납된 임대는 표에서 빠진다" "$leases" '([.items[] | select(.live)] | length) == 0'
  route__fp() { :; }
  rc=0; route__alive "$TR_HOLDER" "whatever" || rc=$?
  check "빈 지문과 kill -0 성공은 산다" "$rc" 0
  rc=0; route__alive "$TR_DEAD" "whatever" || rc=$?
  check "빈 지문과 kill -0 실패는 죽음" "$rc" 1
}
( tr_alive_case )

# 반납, release-run, 재부여, 멱등 부여, route_lease_of.
d=$(tnew release)
live_lease "$d" r1 S1 a
rc=0; bash "$TR_ROUTE" lease-release "$d" r1 S1 wrong || rc=$?
check "nonce 불일치 반납은 rc 0" "$rc" 0
check "nonce 불일치 반납은 지우지 않는다" "$(count_files "$d")" 1
rc=0; bash "$TR_ROUTE" lease-release "$d" r1 S9 n-r1-S9 || rc=$?
check "없는 임대의 반납은 rc 0" "$rc" 0
bash "$TR_ROUTE" lease-release "$d" r1 S1 n-r1-S1
check "맞는 nonce 의 반납은 지운다" "$(count_files "$d")" 0
check "반납 뒤 락이 남지 않는다" "$([ -e "$d/.lock" ] && printf 있음 || printf 없음)" "없음"
d=$(tnew release-run)
live_lease "$d" r1 S1 a
live_lease "$d" r1 S2 a
live_lease "$d" r1x S1 a
live_lease "$d" r2 S1 a
bash "$TR_ROUTE" lease-release-run "$d" r1
check "release-run 은 그 런의 임대만 지운다" "$(ls "$d" | sort | tr '\n' ' ')" "r1x+%531.lease r2+%531.lease "
rc=0; bash "$TR_ROUTE" lease-release-run "$d" .hidden || rc=$?
check "점으로 시작하는 run_id 는 거부" "$rc" 2
d=$(tnew reassign)
live_lease "$d" r1 S1 a
out=$(txn "$d" 'USE([UA("a"; 0.1; 0.1), UA("b"; 0.2; 0.2)]) | REQ({event: "limit-reclaim"})')
expect "재부여는 같은 키를 교체한다" "$out" '.verdict == "GRANT" and .basis == "reassigned-after-limit" and .account == "b"'
expect "재부여는 nonce 를 새로 낸다" "$(cat "$d/$(tr_key r1 S1).lease")" '.account == "b" and .nonce != "n-r1-S1" and (.nonce | length) == 32'
check "재부여 뒤 파일은 하나" "$(count_files "$d")" 1
d=$(tnew idem)
live_lease "$d" r1 S1 a
S="$WORK/sync-idem"
mkdir -p "$S"
out=$(ctx 'REQ({nonce: "n-r1-S1"})' | env TRH_REVALIDATE="touch '$S/with'" bash "$WRAP" lease-txn --table "$d" --now "$NOW" --boot-epoch "" --holder "$TR_HOLDER")
expect "nonce 를 든 멱등 부여는 같은 임대" "$out" '.verdict == "GRANT" and .nonce == "n-r1-S1" and .account == "a"'
check "nonce 를 든 멱등 부여는 재검증하지 않는다" "$([ -e "$S/with" ] && printf 있음 || printf 없음)" "없음"
out=$(ctx '.' | env TRH_REVALIDATE="touch '$S/without'" bash "$WRAP" lease-txn --table "$d" --now "$NOW" --boot-epoch "" --holder "$TR_HOLDER")
expect "nonce 없는 멱등 반환도 같은 임대" "$out" '.verdict == "GRANT" and .nonce == "n-r1-S1"'
check "nonce 없는 멱등 반환은 재검증을 거친다" "$([ -e "$S/without" ] && printf 있음 || printf 없음)" "있음"
expect "route_lease_of 는 그 계보의 임대" "$(bash "$TR_ROUTE" lease-of "$d" r1 S1)" '.account == "a" and .run_id == "r1"'
rc=0; out=$(bash "$TR_ROUTE" lease-of "$d" r1 S9) || rc=$?
check "없는 계보의 route_lease_of 는 빈 값 rc 0" "$rc:$out" "0:"
printf '{' > "$d/$(tr_key r1 S8).lease"
rc=0; out=$(bash "$TR_ROUTE" lease-of "$d" r1 S8) || rc=$?
check "깨진 기록의 route_lease_of 는 빈 값 rc 1" "$rc:$out" "1:"

# 보유자 규칙.
d=$(tnew holders)
ctx '.' > "$WORK/ctx-plain.json"
rc=0; bash -c 'exec bash "$0" lease-txn --table "$1" --now "$2" --boot-epoch "" --holder "$$" < "$3"' "$TR_ROUTE" "$d" "$NOW" "$WORK/ctx-plain.json" >/dev/null 2>&1 || rc=$?
check "자기 \$\$ 보유자는 rc 2" "$rc" 2
rc=0; bash "$TR_ROUTE" lease-txn --table "$d" --now "$NOW" --boot-epoch "" --holder "$TR_DEAD" < "$WORK/ctx-plain.json" >/dev/null 2>&1 || rc=$?
check "죽은 보유자는 rc 2" "$rc" 2
rc=0; env TRH_FP_EMPTY_PID="$TR_HOLDER" bash "$WRAP" lease-txn --table "$d" --now "$NOW" --boot-epoch "" --holder "$TR_HOLDER" < "$WORK/ctx-plain.json" >/dev/null 2>&1 || rc=$?
check "지문을 읽을 수 없는 보유자는 rc 2" "$rc" 2
rc=0; bash "$TR_ROUTE" lease-txn --table "$d" --now "$NOW" --boot-epoch "" < "$WORK/ctx-plain.json" >/dev/null 2>&1 || rc=$?
check "보유자 없는 거래는 rc 2" "$rc" 2
check "거부된 거래는 아무것도 쓰지 않는다" "$([ -e "$d" ] && printf 있음 || printf 없음)" "없음"

# 모르는 kind.
out=$(decide "ONLY([\"a\", \"b\"]) | USE([UA(\"a\"; 0.1; 0.1), UA(\"b\"; 0.2; 0.2)]) | ITEMS([LR(\"r2\"; \"S9\"; \"a\"; \"future\"; {five_hour: 0, seven_day: 7000}; true; 1)])")
expect "예약 있는 모르는 kind 는 Σ 에 센다" "$out" '.verdict == "GRANT" and .account == "b"'
out=$(decide "ONLY([\"a\", \"b\"]) | USE([UA(\"a\"; 0.1; 0.1), UA(\"b\"; 0.2; 0.2)]) | ITEMS([LR(\"r2\"; \"S9\"; \"a\"; \"future\"; null; true; 1)])")
expect "예약 없는 모르는 kind 는 무시한다" "$out" '.verdict == "GRANT" and .account == "a"'
d=$(tnew future)
put_lease "$d" r2 S9 future a '{"five_hour":0,"seven_day":7000}' "$TR_HOLDER" "$TR_HOLDER_FP"
put_lease "$d" r3 S9 future b null "$TR_HOLDER" "$TR_HOLDER_FP"
expect "모르는 kind 가 든 표는 깨짐이 아니다" "$(tr_table_json "$d")" '.state == "valid" and (.items | length) == 2'
out=$(txn "$d" 'USE([UA("a"; 0.1; 0.1), UA("b"; 0.2; 0.2)])')
expect "거래도 예약 있는 모르는 kind 를 센다" "$out" '.verdict == "GRANT" and .account == "b"'

# 키 인코더.
tr_enc_case() {
  . "$TR_ROUTE"
  local s e all="" folded n ok_all=1
  for s in S1 s1 'shift#1' shift_1 'a+b' 'a%2Bb' 'a b' 'a/b' 'Ab' 'aB' 'run.id' '-x' '~y' 'Ä'; do
    e=$(route__enc "$s")
    case "$e" in
      *[!a-z0-9._~%-]*) [ -n "$(printf '%s' "$e" | sed -E 's/%[0-9A-F]{2}//g' | tr -d 'a-z0-9._~-')" ] && ok_all=0 ;;
    esac
    [ "$(route__dec "$e")" = "$s" ] || ok_all=0
    all=$(printf '%s\n%s' "$all" "$e")
  done
  check "인코딩은 [a-z0-9._~-] 와 %XX 뿐이고 디코드가 항등" "$ok_all" 1
  n=$(printf '%s\n' "$all" | grep -c -v '^$')
  folded=$(printf '%s\n' "$all" | grep -v '^$' | tr 'A-Z' 'a-z' | sort -u | grep -c '')
  check "대소문자를 접어도 인코딩이 단사" "$folded" "$n"
  check "S1 과 s1 은 다른 이름" "$(route__key r1 S1) $(route__key r1 s1)" "r1+%531 r1+s1"
  rc=0; route__key "" S1 >/dev/null || rc=$?
  check "빈 run_id 키는 거부" "$rc" 2
}
( tr_enc_case )

d=$(tnew dotfile)
mkdir -p "$d"
printf 'garbage' > "$d/.r1+%531.lease.tmp.999"
expect "점 파일 임시 이름은 목록에 오르지 않는다" "$(tr_table_json "$d")" '.state == "absent" and (.corrupt | length) == 0'
live_lease "$d" r2 S1 a
expect "점 파일 임시 이름이 있어도 표는 유효" "$(tr_table_json "$d")" '.state == "valid" and (.items | length) == 1'

# 락.
d=$(tnew lock-busy)
mkdir -p "$d/.lock"
printf '%s\n%s\n' "$TR_HOLDER" "$TR_HOLDER_FP" > "$d/.lock/owner"
tr_age "$d/.lock" 978307200
SECONDS=0
out=$(txn "$d" '.')
el=$SECONDS
expect "살아 있는 락 소유자 → 제한 대기 뒤 WAIT lease-lock-busy" "$out" '.verdict == "WAIT" and .reason == "lease-lock-busy"'
if [ "$el" -ge 4 ]; then ok "락 대기는 예산만큼 기다린다"; else bad "락 대기는 예산만큼 기다린다" "${el}초"; fi
check "오래됐어도 살아 있는 소유자의 락은 깨지 않는다" "$(sed -n 1p "$d/.lock/owner")" "$TR_HOLDER"
expect "교대의 락 대기 초과는 좌석 폴백" "$(txn "$d" 'REQ({kind: "shift", lineage: "shift#1"})')" '.verdict == "GRANT" and .basis == "shift-seat-fallback"'
d=$(tnew lock-dead)
mkdir -p "$d/.lock"
printf '%s\n%s\n' "$TR_DEAD" "$TR_DEAD_FP" > "$d/.lock/owner"
out=$(txn "$d" '.')
expect "죽은 소유자의 락은 mtime 과 무관하게 깬다" "$out" '.verdict == "GRANT"'
check "거래가 끝난 뒤 락이 없다" "$([ -e "$d/.lock" ] && printf 있음 || printf 없음)" "없음"
tr_lock_break_case() {
  . "$TR_ORCH/liveness.sh"
  . "$TR_ROUTE"
  local d="$T/lock-orphan" rc
  mkdir -p "$d/.lock"
  tr_age "$d/.lock" "$(( $(date -u +%s) - 30 ))"
  rc=0; route__lock_try_break "$d/.lock" || rc=$?
  check "기록 없는 락은 경계 앞에서 깨지 않는다" "$rc:$([ -e "$d/.lock" ] && printf 있음)" "1:있음"
  tr_age "$d/.lock" "$(( $(date -u +%s) - 120 ))"
  rc=0; route__lock_try_break "$d/.lock" || rc=$?
  check "기록 없는 락은 경계 뒤에 깬다" "$rc:$([ -e "$d/.lock" ] && printf 있음 || printf 없음)" "0:없음"
  mkdir -p "$d/.lock"
  printf '%s\n%s\n' "$TR_DEAD" "$TR_DEAD_FP" > "$d/.lock/owner"
  rc=0; route__lock_try_break "$d/.lock" || rc=$?
  check "새 mtime 이어도 죽은 소유자의 락은 깬다" "$rc:$([ -e "$d/.lock" ] && printf 있음 || printf 없음)" "0:없음"
}
( tr_lock_break_case )

# 거래 프로세스가 자기 pid 로 락을 쥔다.
d=$(tnew owner)
S="$WORK/sync-owner"
mkdir -p "$S"
out=$(ctx '.' | env TRH_LOCKED="cp \"\$1/.lock/owner\" '$S/owner'; printf '%s' \"\$\$\" > '$S/self'" bash "$WRAP" lease-txn --table "$d" --now "$NOW" --boot-epoch "" --holder "$TR_HOLDER")
check "락 소유자는 거래 프로세스" "$(sed -n 1p "$S/owner")" "$(cat "$S/self")"
if [ "$(sed -n 1p "$S/owner")" != "$$" ]; then ok "락 소유자는 부모가 아니다"; else bad "락 소유자는 부모가 아니다" "$$"; fi
check "거래가 끝난 뒤 락이 없다(소유자 확인)" "$([ -e "$d/.lock" ] && printf 있음 || printf 없음)" "없음"

# 강제 교차: 락을 건너뛴 두 거래. A 는 계보 S2, B 는 S1 이라 B 의 키가 낮다.
ctx 'ONLY(["a"]) | USE([UA("a"; 0.1; 0.6)]) | REQ({lineage: "S2"})' > "$WORK/ctx-A.json"
ctx 'ONLY(["a"]) | USE([UA("a"; 0.1; 0.6)]) | REQ({lineage: "S1"})' > "$WORK/ctx-B.json"
cross() {
  # cross <이름> <A 결정 뒤> <A 쓰기 뒤> <A 재검증 앞> <B 결정 뒤> <B 쓰기 뒤> <B 재검증 앞> [재검증 규칙] [문맥 A] [문맥 B]
  local n="$1" d S pa pb
  d=$(tnew "x-$n")
  S="$WORK/sync-$n"
  rm -rf "$S"
  mkdir -p "$S" "$d"
  if [ -n "${CROSS_SETUP:-}" ]; then eval "$CROSS_SETUP"; fi
  env TRH_NOLOCK=1 TRH_REVAL="${8:-}" TRH_DECIDED="${2//@S/$S}" TRH_WRITTEN="${3//@S/$S}" TRH_REVALIDATE="${4//@S/$S}" \
    bash "$WRAP" lease-txn --table "$d" --now "$NOW" --boot-epoch "" --holder "$TR_HOLDER" < "${9:-$WORK/ctx-A.json}" > "$S/A.out" 2>"$S/A.err" &
  pa=$!
  env TRH_NOLOCK=1 TRH_REVAL="${8:-}" TRH_DECIDED="${5//@S/$S}" TRH_WRITTEN="${6//@S/$S}" TRH_REVALIDATE="${7//@S/$S}" \
    bash "$WRAP" lease-txn --table "$d" --now "$NOW" --boot-epoch "" --holder "$TR_HOLDER" < "${10:-$WORK/ctx-B.json}" > "$S/B.out" 2>"$S/B.err" &
  pb=$!
  wait "$pa" "$pb"
  CROSS_DIR="$d"
  CROSS_S="$S"
  CROSS_LIVE=$(count_files "$d")
  CROSS_WAITS=$(cat "$S/A.out" "$S/B.out" | grep -c '"verdict":"WAIT"' || true)
  seen "$(cat "$S/A.out")"
  seen "$(cat "$S/B.out")"
}
cross i1 "touch @S/A.d; trh_e @S/B.d" "touch @S/A.w; trh_e @S/B.w" ":" \
         "touch @S/B.d; trh_e @S/A.w" "touch @S/B.w; trh_s @S/A.out" ":"
check "쓰기 → 상대 쓰기 → 재검증: 살아남는 임대 하나" "$CROSS_LIVE" 1
expect "먼저 재검증한 쪽이 자기를 철회한다" "$(cat "$CROSS_S/A.out")" '.verdict == "WAIT" and .reason == "lease-contention"'
cross i2 "touch @S/A.d; trh_e @S/B.d" ":" ":" "touch @S/B.d; trh_s @S/A.out" ":" ":"
check "쓰기·재검증 → 상대 쓰기·재검증: 살아남는 임대 하나" "$CROSS_LIVE" 1
cross i2t "touch @S/A.d; trh_e @S/B.d" ":" ":" "touch @S/B.d; trh_s @S/A.out" ":" ":" tiebreak
check "낮은 쪽이 남는 타이브레이크 변형은 둘을 남긴다" "$CROSS_LIVE" 2
cross i3 "touch @S/A.d; trh_e @S/B.d" "touch @S/A.w; trh_e @S/B.w" "touch @S/A.r; trh_e @S/B.r" \
         "touch @S/B.d; trh_e @S/A.d" "touch @S/B.w; trh_e @S/A.w" "touch @S/B.r; trh_e @S/A.r"
check "이중 보유의 서로 물러섬: 살아남는 임대 없음" "$CROSS_LIVE" 0
if [ "$CROSS_WAITS" -le 2 ]; then ok "물러섬은 한 번(WAIT 둘 이하)"; else bad "물러섬은 한 번(WAIT 둘 이하)" "$CROSS_WAITS"; fi
out=$(ctx 'ONLY(["a"]) | USE([UA("a"; 0.1; 0.6)]) | REQ({lineage: "S3"})' | bash "$TR_ROUTE" lease-txn --table "$CROSS_DIR" --now "$NOW" --boot-epoch "" --holder "$TR_HOLDER")
expect "물러선 다음 결정은 입장한다" "$out" '.verdict == "GRANT"'
ctx 'ONLY(["a"]) | USE([UA("a"; 0.1; 0.6)]) | REQ({lineage: "S2", event: "crash-retry"})' > "$WORK/ctx-A-retry.json"
ctx 'ONLY(["a"]) | USE([UA("a"; 0.1; 0.6)]) | REQ({lineage: "S1", event: "crash-retry"})' > "$WORK/ctx-B-retry.json"
CROSS_SETUP='dead_lease "$d" r1 S1 a; dead_lease "$d" r1 S2 a'
cross ri "touch @S/A.d; trh_e @S/B.d" "touch @S/A.w; trh_e @S/B.w" "touch @S/A.r; trh_e @S/B.r" \
         "touch @S/B.d; trh_e @S/A.d" "touch @S/B.w; trh_e @S/A.w" "touch @S/B.r; trh_e @S/A.r" "" \
         "$WORK/ctx-A-retry.json" "$WORK/ctx-B-retry.json"
if [ "$CROSS_LIVE" -le 1 ]; then ok "stale 자기 임대 위 재시도 재입장의 교차: 살아남는 임대 하나 이하"
else bad "stale 자기 임대 위 재시도 재입장의 교차: 살아남는 임대 하나 이하" "$CROSS_LIVE"; fi
ctx 'ONLY(["a"]) | USE([UA("a"; 0.1; 0.6)]) | REQ({lineage: "S2", event: "resume", bound_account: "a"})' > "$WORK/ctx-A-resume.json"
ctx 'ONLY(["a"]) | USE([UA("a"; 0.1; 0.6)]) | REQ({lineage: "S1", event: "resume", bound_account: "a"})' > "$WORK/ctx-B-resume.json"
cross rr "touch @S/A.d; trh_e @S/B.d" "touch @S/A.w; trh_e @S/B.w" ":" \
         "touch @S/B.d; trh_e @S/A.w" "touch @S/B.w; trh_s @S/A.out" ":" "" \
         "$WORK/ctx-A-resume.json" "$WORK/ctx-B-resume.json"
check "stale 자기 임대 위 재개 재입장의 교차: 살아남는 임대 하나" "$CROSS_LIVE" 1
CROSS_SETUP=""

# 재개·유지·hold 의 경합.
d=$(tnew r20-1)
out=$(txn "$d" 'ONLY(["a"]) | USE([UA("a"; 0.1; 0.6)]) | REQ({run_id: "r2"})')
expect "반납된 계보의 자리를 다른 런이 가져간다" "$out" '.verdict == "GRANT"'
out=$(txn "$d" 'ONLY(["a"]) | USE([UA("a"; 0.1; 0.6)]) | REQ({event: "resume", bound_account: "a"})')
expect "반납 뒤 재개는 입장 없이 부여되지 않는다" "$out" '.verdict == "WAIT" and .reason == "resume-bound-no-room"'

d=$(tnew r20-2)
H2=$(tr_spawn)
TR_PIDS="$TR_PIDS $H2"
H2_FP=$( . "$TR_ORCH/liveness.sh"; TZ=UTC0 cc_proc_fingerprint "$H2" )
put_lease "$d" r1 S1 grant a "$RES_JSON" "$H2" "$H2_FP"
S="$WORK/sync-r20"
mkdir -p "$S"
ctx 'ONLY(["a"]) | USE([UA("a"; 0.1; 0.6)]) | REQ({event: "resume"})' \
  | env TRH_DECIDED="kill $H2; touch '$S/A.d'; sleep 2" bash "$WRAP" lease-txn --table "$d" --now "$NOW" --boot-epoch "" --holder "$TR_HOLDER" > "$S/A.out" 2>&1 &
pa=$!
i=0; while [ ! -e "$S/A.d" ] && [ "$i" -lt 200 ]; do sleep 0.05; i=$((i + 1)); done
ctx 'ONLY(["a"]) | USE([UA("a"; 0.1; 0.6)]) | REQ({run_id: "r2"})' \
  | bash "$TR_ROUTE" lease-txn --table "$d" --now "$NOW" --boot-epoch "" --holder "$TR_HOLDER" > "$S/B.out" 2>&1 &
pb=$!
wait "$pa" "$pb"
expect "마지막 보유자가 판정 도중 죽어도 재개는 같은 임계 구역에서 hold 한다" "$(cat "$S/A.out")" '.verdict == "GRANT" and .basis == "resume-bound"'
expect "그 사이 다른 런은 그 여유로 부여받지 못한다" "$(cat "$S/B.out")" '.verdict == "WAIT"'
expect "hold 뒤 임대의 보유자에 재개 프로세스가 든다" "$(cat "$d/$(tr_key r1 S1).lease")" "any(.holders[]; .pid == $TR_HOLDER)"

d=$(tnew r20-3)
dead_lease "$d" r1 S1 a
H3=$(tr_spawn)
TR_PIDS="$TR_PIDS $H3"
rc=0; bash "$TR_ROUTE" lease-hold "$d" r1 S1 n-r1-S1 "$H3" >/dev/null 2>&1 || rc=$?
check "stale 임대에 대한 hold 는 구별되는 rc 5" "$rc" 5
live_lease "$d" r1 S2 a
rc=0; bash "$TR_ROUTE" lease-hold "$d" r1 S2 wrong "$H3" >/dev/null 2>&1 || rc=$?
check "nonce 가 다른 hold 는 rc 1" "$rc" 1
rc=0; out=$(bash "$TR_ROUTE" lease-hold "$d" r1 S2 n-r1-S2 "$H3") || rc=$?
check "살아 있는 임대의 hold 는 rc 0" "$rc" 0
expect "hold 는 보유자를 더한다" "$out" '(.holders | length) == 2'

d=$(tnew r20-4)
live_lease "$d" r1 S1 a
out=$(txn "$d" 'ONLY(["a"]) | USE([UA("a"; 0.1; 0.6)]) | REQ({event: "crash-retry"})')
expect "살아 있는 임대의 crash-retry 는 같은 예약" "$out" ".verdict == \"GRANT\" and .basis == \"sticky\" and .reservation_bp.seven_day == $TR7"
leases=$(tr_table_json "$d")
out=$(ctx 'ONLY(["a"]) | USE([UA("a"; 0.1; 0.6)]) | REQ({run_id: "r5"})' | jq -c --argjson l "$leases" '.leases = $l' | bash "$TR_ROUTE" classify)
expect "유지는 Σ 에 자기를 한 번만 센다" "$out" ".groups[0].sigma.seven_day == $TR7 and .groups[0].count == 1"

# 임대 쓰기 뒤 차용 재판독.
LB="$WORK/lb"
mkdir -p "$LB"
lb_rec() {
  # lb_rec <파일> <state> <기증자 id> [기증자 config_dir] — 좌석 /seat 의 차용 기록을 쓴다.
  mkdir -p "${1%/*}"
  jq -cn --arg st "$2" --arg id "$3" --arg dir "${4:-/h/.claude-$3}" \
    '{schema: "cc-lane-borrow v1", state: $st, lane_config_dir: "/seat", donor: {id: $id, config_dir: $dir}}' > "$1"
}
lb_rec "$LB/intent-a.json" intent a
lb_rec "$LB/intent-b.json" intent b
lb_rec "$LB/id-a.json" intent a /elsewhere
lb_rec "$LB/dir-a.json" intent zz /h/.claude-a
printf '{' > "$LB/broken.json"
lb_bp() { rm -rf "$LB/$1"; mkdir -p "$LB/$1"; printf '%s' "$LB/$1/borrow.json"; }
# lbx <표> <기록 경로> <문맥 필터> <TRH_WRITTEN 조각> [환경 할당…] — 래퍼로 거래를 돌린다.
# 보유자는 LBH, 없으면 TR_HOLDER 다.
lbx() {
  local t="$1" bp="$2" f="$3" w="$4"
  shift 4
  ctx "$f | .borrow_path = \"$bp\"" | env TRH_WRITTEN="$w" "$@" bash "$WRAP" lease-txn --table "$t" --now "$NOW" --boot-epoch "" --holder "${LBH:-$TR_HOLDER}"
}
K1="$(tr_key r1 S1).lease"
H4=$(tr_spawn)
TR_PIDS="$TR_PIDS $H4"
WAITC='.verdict == "WAIT" and .reason == "lease-contention"'

d=$(tnew bp-missing)
mkdir -p "$d"
rc=0; ctx 'del(.borrow_path)' | bash "$TR_ROUTE" lease-txn --table "$d" --now "$NOW" --boot-epoch "" --holder "$TR_HOLDER" >/dev/null 2>&1 || rc=$?
check "borrow_path 키 없음(표 있음) → rc 2, 임대 없음" "$rc:$(count_files "$d")" "2:0"
i=0
for f in 'del(.borrow_path)' '.borrow_path = "rel/borrow.json"' '.borrow_path = 5'; do
  i=$((i + 1))
  d=$(tnew "bp-bad-$i")
  rc=0; ctx "$f" | bash "$TR_ROUTE" lease-txn --table "$d" --now "$NOW" --boot-epoch "" --holder "$TR_HOLDER" >/dev/null 2>&1 || rc=$?
  check "문맥 경로 계약 위반 $f(표 부재) → rc 2, 표를 만들지 않는다" "$rc:$([ -e "$d" ] && printf 있음 || printf 없음)" "2:없음"
done
d=$(tnew bp-null)
out=$(txn "$d" '.borrow_path = null')
expect "경로 null 의 새 배치 → PARK borrow-record-corrupt" "$out" '.verdict == "PARK" and .reason == "borrow-record-corrupt"'
check "경로 null 의 새 배치는 임대를 남기지 않는다" "$(count_files "$d")" 0
d=$(tnew bp-null-hold)
live_lease "$d" r1 S1 a
out=$(txn "$d" '.borrow_path = null | REQ({nonce: "n-r1-S1"})')
expect "경로 null 의 nonce 같은 멱등 보유 → GRANT" "$out" '.verdict == "GRANT" and .nonce == "n-r1-S1"'
check "경로 null 의 멱등 보유는 임대를 유지한다" "$(count_files "$d")" 1

d=$(tnew bd-dekker)
BP=$(lb_bp dekker)
out=$(lbx "$d" "$BP" '.' "cp '$LB/intent-a.json' '$BP'")
expect "Dekker: 쓴 계정을 지명하는 intent → WAIT lease-contention" "$out" "$WAITC"
check "Dekker: 임대가 남지 않는다" "$(count_files "$d")" 0
BP=$(lb_bp dekker)
out=$(lbx "$d" "$BP" 'REQ({kind: "shift", lineage: "shift#1"})' "cp '$LB/intent-a.json' '$BP'")
expect "Dekker 의 교대는 새 표시의 좌석" "$out" '.basis == "shift-seat-fallback" and .borrow == {state: "intent", donor: "a"}'
check "Dekker 의 교대도 임대를 남기지 않는다" "$(count_files "$d")" 0
for rec in id-a dir-a; do
  d=$(tnew "bd-$rec")
  BP=$(lb_bp "$rec")
  out=$(lbx "$d" "$BP" '.' "cp '$LB/$rec.json' '$BP'")
  expect "재판독 적중 갈래 $rec → WAIT lease-contention" "$out" "$WAITC"
  check "재판독 적중 갈래 $rec → 임대 없음" "$(count_files "$d")" 0
done
d=$(tnew bd-other)
BP=$(lb_bp other)
out=$(lbx "$d" "$BP" '.' "cp '$LB/intent-b.json' '$BP'")
expect "다른 계정을 지명하는 intent 는 부여를 막지 않는다" "$out" '.verdict == "GRANT" and .account == "a"'
check "다른 계정 지명 뒤 임대 유지" "$(count_files "$d")" 1
d=$(tnew bd-stale)
BP=$(lb_bp stale)
lb_rec "$BP" borrowed a
out=$(lbx "$d" "$BP" '.borrow = {state: "none"}' ":")
expect "낡은 문맥(none)과 디스크의 borrowed → 되돌림" "$out" "$WAITC"
check "낡은 문맥의 되돌림 뒤 임대 없음" "$(count_files "$d")" 0
d=$(tnew bd-chain)
BP=$(lb_bp chain)
lb_rec "$BP" borrowed a
out=$(lbx "$d" "$BP" '.borrow = BRW("borrowed"; "u3"; "/h/.claude-u3")' ":")
expect "문맥 기증자 u3, 디스크 기증자 a 의 체인 → 되돌림" "$out" "$WAITC"
check "체인의 되돌림 뒤 임대 없음" "$(count_files "$d")" 0
d=$(tnew bd-corrupt)
BP=$(lb_bp corrupt)
out=$(lbx "$d" "$BP" '.' "cp '$LB/broken.json' '$BP'")
expect "새 배치의 손상 재판독 → PARK borrow-record-corrupt" "$out" '.verdict == "PARK" and .reason == "borrow-record-corrupt"'
check "새 배치의 손상 재판독 뒤 임대 없음" "$(count_files "$d")" 0
BP=$(lb_bp corrupt)
out=$(lbx "$d" "$BP" 'REQ({kind: "shift", lineage: "shift#1"})' "cp '$LB/broken.json' '$BP'")
expect "손상 재판독의 교대는 손상 표시 좌석" "$out" '.basis == "shift-seat-fallback" and .borrow == {state: "corrupt", donor: null}'
for f in '.' 'REQ({event: "crash-retry"})'; do
  d=$(tnew bd-corrupt-cont)
  live_lease "$d" r1 S1 a
  BP=$(lb_bp corrupt-cont)
  out=$(lbx "$d" "$BP" "$f" "cp '$LB/broken.json' '$BP'")
  expect "이어 가는 쓰기 $f 는 손상 재판독에서도 진행" "$out" '.verdict == "GRANT" and .account == "a" and .nonce == "n-r1-S1"'
  check "이어 가는 쓰기 $f 뒤 임대 유지" "$(count_files "$d")" 1
done

# 복원. 파일 비교는 cmp 다.
d=$(tnew bd-hold)
live_lease "$d" r1 S1 a
cp "$d/$K1" "$LB/hold.before"
BP=$(lb_bp hold)
out=$(LBH=$H4 lbx "$d" "$BP" 'REQ({event: "crash-retry"})' "cp '$LB/intent-a.json' '$BP'")
expect "보유 적중·이전 보유자 살아 있음 → WAIT lease-contention" "$out" "$WAITC"
rc=0; cmp -s "$LB/hold.before" "$d/$K1" || rc=$?
check "보유 적중 뒤 임대 파일은 트랜잭션 전 사본과 cmp 같다" "$rc" 0
expect "복원된 임대는 이전 보유자와 이전 nonce 만 지닌다" "$(cat "$d/$K1")" ".nonce == \"n-r1-S1\" and [.holders[].pid] == [$TR_HOLDER]"
d=$(tnew bd-die)
H5=$(tr_spawn)
TR_PIDS="$TR_PIDS $H5"
H5_FP=$( . "$TR_ORCH/liveness.sh"; TZ=UTC0 cc_proc_fingerprint "$H5" )
put_lease "$d" r1 S1 grant a "$RES_JSON" "$H5" "$H5_FP"
BP=$(lb_bp die)
out=$(ctx "REQ({event: \"resume\"}) | .borrow_path = \"$BP\"" \
  | env TRH_DECIDED="kill $H5; cp '$LB/intent-a.json' '$BP'" bash "$WRAP" lease-txn --table "$d" --now "$NOW" --boot-epoch "" --holder "$TR_HOLDER")
expect "보유 중 보유자가 죽어도 적중이면 WAIT lease-contention" "$out" "$WAITC"
expect "복원된 기록은 죽은 보유자만 지니고 요청 보유자가 없다" "$(cat "$d/$K1")" "[.holders[].pid] == [$H5]"
d=$(tnew bd-window)
live_lease "$d" r1 S1 a
cp "$d/$K1" "$LB/window.before"
BP=$(lb_bp window)
lb_rec "$BP" intent a
for f in 'REQ({nonce: "n-r1-S1"})' 'REQ({event: "crash-retry"})' 'REQ({event: "resume"})'; do
  out=$(LBH=$H4 lbx "$d" "$BP" ".borrow = BRW(\"intent\"; \"a\"; \"/h/.claude-a\") | $f" ":")
  expect "intent 창의 이어 가기 $f → WAIT lease-contention" "$out" "$WAITC"
  rc=0; cmp -s "$LB/window.before" "$d/$K1" || rc=$?
  check "intent 창의 이어 가기 $f 뒤 임대 파일이 사본과 cmp 같다" "$rc" 0
done
d=$(tnew bd-cover)
live_lease "$d" r1 S1 a
cp "$d/$K1" "$LB/cover.before"
BP=$(lb_bp cover)
out=$(lbx "$d" "$BP" 'REQ({event: "limit-reclaim"})' "cp '$LB/intent-b.json' '$BP'")
expect "살아 있는 자기 임대를 덮은 재부여의 적중 → WAIT lease-contention" "$out" "$WAITC"
rc=0; cmp -s "$LB/cover.before" "$d/$K1" || rc=$?
check "덮은 재부여의 되돌림은 이전 계정의 기록을 cmp 같게 되쓴다" "$rc" 0
# 복원 실패: 복원의 임시 파일 자리를 디렉터리로 막는다. 훅은 거래 셸 안에서 eval 되어 $$ 가 같다.
d=$(tnew bd-undo-fail)
live_lease "$d" r1 S1 a
BP=$(lb_bp undo-fail)
rc=0
out=$(LBH=$H4 lbx "$d" "$BP" 'REQ({event: "crash-retry"})' "cp '$LB/intent-a.json' '$BP'; mkdir \"\$1/.$K1.tmp.\$\$\"") || rc=$?
check "복원 실패 → rc 4, 빈 출력" "$rc:$out" "4:"
expect "복원 실패 뒤 파일은 방금 쓴 기록(요청 보유자 포함)" "$(cat "$d/$K1")" "any(.holders[]; .pid == $H4)"
out=$(txn "$d" 'REQ({event: "crash-retry"})')
expect "복원 실패 뒤 다음 거래는 잠금 바쁨이 아니다" "$out" '.reason != "lease-lock-busy"'
find "$d" -name ".$K1.tmp.*" -type d -exec rm -rf {} +
# 우선순위: 손상 판정과 적중 되돌림은 재검증보다 앞선다.
d=$(tnew bd-prio-c)
BP=$(lb_bp prio-c)
out=$(lbx "$d" "$BP" '.' "cp '$LB/broken.json' '$BP'" TRH_REVAL=fail)
expect "재검증 실패 강제 + 새 배치의 손상 → PARK borrow-record-corrupt" "$out" '.verdict == "PARK" and .reason == "borrow-record-corrupt"'
d=$(tnew bd-prio-h)
live_lease "$d" r1 S1 a
cp "$d/$K1" "$LB/prio.before"
BP=$(lb_bp prio-h)
out=$(lbx "$d" "$BP" '.' "cp '$LB/intent-a.json' '$BP'" TRH_REVAL=fail)
expect "재검증 실패 강제 + nonce 없는 멱등 재부여의 적중 → WAIT lease-contention" "$out" "$WAITC"
rc=0; cmp -s "$LB/prio.before" "$d/$K1" || rc=$?
check "적중이 재검증보다 앞서 살아 있는 자기 임대가 cmp 같게 남는다" "$rc" 0
# 차용이 없을 때 nonce 없는 멱등 재부여의 강제 재검증 실패는 nonce 로 지운다.
d=$(tnew bd-reval)
live_lease "$d" r1 S1 a
out=$(ctx '.' | env TRH_REVAL=fail bash "$WRAP" lease-txn --table "$d" --now "$NOW" --boot-epoch "" --holder "$TR_HOLDER")
expect "nonce 없는 멱등 재부여의 강제 재검증 실패 → WAIT lease-contention" "$out" "$WAITC"
check "그 실패는 호출자의 살아 있는 임대를 지운다" "$(count_files "$d")" 0
# 문맥 경로 우선: 거래 프로세스는 자기 환경으로 경로를 다시 계산하지 않는다.
lb_rec "$LB/envstate/cc-lane/borrow.json" intent a
d=$(tnew bd-ctxpath)
out=$(ctx '.' | env XDG_STATE_HOME="$LB/envstate" bash "$WRAP" lease-txn --table "$d" --now "$NOW" --boot-epoch "" --holder "$TR_HOLDER")
expect "환경의 상태 루트에 기록이 있어도 문맥 경로가 부재면 GRANT" "$out" '.verdict == "GRANT" and .account == "a"'
d=$(tnew bd-ctxpath2)
out=$(ctx ".borrow_path = \"$LB/envstate/cc-lane/borrow.json\"" | env XDG_STATE_HOME="$LB/nowhere" bash "$WRAP" lease-txn --table "$d" --now "$NOW" --boot-epoch "" --holder "$TR_HOLDER")
expect "환경의 상태 루트가 비어 있어도 문맥 경로의 intent 를 본다" "$out" "$WAITC"

# 실패 경로.
if [ "$(id -u)" = "0" ]; then
  ok "쓰기 실패 경로(root 는 권한을 우회하므로 생략)"
  ok "나열할 수 없는 표(root 는 권한을 우회하므로 생략)"
else
  d=$(tnew wfail)
  mkdir -p "$d"
  rc=0
  out=$(ctx '.' | env TRH_LOCKED='chmod 555 "$1"' bash "$WRAP" lease-txn --table "$d" --now "$NOW" --boot-epoch "" --holder "$TR_HOLDER" 2>/dev/null) || rc=$?
  chmod 755 "$d"
  check "임시 파일 쓰기 실패 → 오류 rc 와 빈 출력" "$rc:$out" "4:"
  check "쓰기 실패 뒤 임시 파일이 남지 않는다" "$(ls -A "$d" | grep -c 'tmp' || true)" 0
  check "쓰기 실패 뒤 임대가 없다" "$(count_files "$d")" 0
  # 쓸 수 없는 표에서는 락 디렉터리 자체를 지우지 못해 소유자 기록 없는 락이 남을
  # 수 있다. 그 락은 고아 경계를 넘기면 다음 거래가 깬다.
  check "쓰기 실패 뒤 락에 소유자 기록이 남지 않는다" "$([ -e "$d/.lock/owner" ] && printf 있음 || printf 없음)" "없음"
  if [ -d "$d/.lock" ]; then tr_age "$d/.lock" 978307200; fi
  expect "쓰기 실패가 남긴 락은 고아 경계 뒤 다음 거래가 깬다" "$(txn "$d" '.')" '.verdict == "GRANT"'
  d=$(tnew nolockdir)
  live_lease "$d" r1 S1 a
  chmod 555 "$d"
  SECONDS=0
  rc=0; bash "$TR_ROUTE" lease-release "$d" r1 S1 n-r1-S1 2>/dev/null || rc=$?
  el=$SECONDS
  chmod 755 "$d"
  check "락을 만들 수 없는 표 → 곧바로 rc 4" "$rc" 4
  if [ "$el" -lt 2 ]; then ok "락을 만들 수 없는 표에서 헛돌지 않는다"; else bad "락을 만들 수 없는 표에서 헛돌지 않는다" "${el}초"; fi
  d=$(tnew unlistable)
  live_lease "$d" r2 S1 b
  chmod 300 "$d"
  out=$(txn "$d" '.')
  chmod 755 "$d"
  expect "나열할 수 없는 표 → PARK lease-table-corrupt" "$out" '.verdict == "PARK" and .reason == "lease-table-corrupt"'
fi
d=$(tnew vanish)
live_lease "$d" r2 S5 a
out=$(ctx 'ONLY(["a"]) | USE([UA("a"; 0.1; 0.6)])' | env TRH_LISTED='rm -f "$1"/r2+*.lease' bash "$WRAP" lease-txn --table "$d" --now "$NOW" --boot-epoch "" --holder "$TR_HOLDER")
expect "목록과 판독 사이에 사라진 파일은 반납이고 깨짐이 아니다" "$out" '.verdict == "GRANT"'

# 지문의 TZ 고정과 두 진입 형태.
tr_fp_case() {
  . "$TR_ORCH/liveness.sh"
  . "$TR_ROUTE"
  local fu fs rec rc ru rs rec2 dd
  fu=$(TZ=UTC route__fp "$TR_HOLDER")
  fs=$(TZ=Asia/Seoul route__fp "$TR_HOLDER")
  check "route__fp 는 TZ 와 무관하다" "$fu" "$fs"
  rc=0; TZ=Asia/Seoul route__alive "$TR_HOLDER" "$fu" || rc=$?
  check "UTC 에서 잡은 보유자를 서울 판정자가 산다고 본다" "$rc" 0
  ru=$(TZ=UTC cc_proc_fingerprint "$TR_HOLDER")
  rs=$(TZ=Asia/Seoul cc_proc_fingerprint "$TR_HOLDER")
  if [ "$ru" != "$rs" ]; then ok "고정하지 않은 지문은 TZ 에 따라 어긋난다"; else bad "고정하지 않은 지문은 TZ 에 따라 어긋난다" "$ru"; fi
  dd="$T/fp"
  rec2=$(bash "$TR_ROUTE" lease-wait-put --table "$dd" --now "$NOW" --run-id r9 --lineage fp --account a --config-dir /h/.claude-a --holder "$TR_HOLDER")
  check "프로세스 안과 단독 서브커맨드의 지문이 같다" "$(printf '%s' "$rec2" | jq -r '.holders[0].fp')" "$fu"
}
( tr_fp_case )

# 활성 경로의 거래도 락을 남기지 않는다(명령 치환 안의 route_resolve).
tr_active_lock_case() {
  local x
  export RUN_DIR="$WORK/active/run" RUN_PACE_ROOT="$WORK/active/pace"
  mkdir -p "$RUN_DIR"
  tr_write_inv valid "$RUN_DIR/inventory.json"
  x=$(route__resolve_as 1 "$(tr_req)" 2>/dev/null)
  expect "명령 치환 안의 활성 경로 부여" "$x" '.verdict == "GRANT"'
  check "명령 치환 안의 활성 경로 뒤 락이 없다" "$([ -e "$RUN_PACE_ROOT/leases/.lock" ] && printf 있음 || printf 없음)" "없음"
}
tr_in_run "$TR_RUN_SH" tr_active_lock_case

# ===========================================================================
# 전역 충돌 린트 파생
# ===========================================================================
LT="$WORK/lint"
mk_tree() {
  # mk_tree <dir> <harness 본문> <gate.sh 본문>
  local dir="$1"
  mkdir -p "$dir/scripts" "$dir/plugins/cc-cmds/orchestrator"
  printf '%s\n' '#!/usr/bin/env bash' 'export GATE="$root/gate.sh"' "$2" > "$dir/scripts/test-gate.sh"
  printf '%s\n' '#!/usr/bin/env bash' 'RUN_DIR="$1"' "$3" > "$dir/plugins/cc-cmds/orchestrator/gate.sh"
  printf '%s\n' '#!/usr/bin/env bash' 'LEDGER=""' > "$dir/plugins/cc-cmds/orchestrator/run.sh"
}
lint_case() {
  # lint_case <이름> <dir> <기대 rc> [출력에 있어야 할 문면]
  local rc=0
  ROOT="$2" bash "$TR_LINT" >"$2.out" 2>"$2.err" || rc=$?
  check "린트 $1 → rc $3" "$rc" "$3"
  if [ -n "${4:-}" ]; then
    check "린트 $1 → $4" "$(cat "$2.out" "$2.err" | grep -c -F "$4")" 1
  fi
}
mk_tree "$LT/t1" 'MANIFEST="a"' 'ORCH_DIR=x
. "$ORCH_DIR/sib.sh"'
printf '%s\n' 'MANIFEST=""' > "$LT/t1/plugins/cc-cmds/orchestrator/sib.sh"
lint_case "하네스 이름을 대입하는 형제를 소싱" "$LT/t1" 1 "[충돌] MANIFEST"
rm -f "$LT/t1/plugins/cc-cmds/orchestrator/sib.sh"
lint_case "형제를 지운 같은 트리" "$LT/t1" 0
mk_tree "$LT/t3" 'MANIFEST="a"' 'for g in x; do
  . "$g"
done'
lint_case "비리터럴 소스 줄" "$LT/t3" 2
mk_tree "$LT/t4" 'MANIFEST="a"' 'for g in x; do
  . "$g"  # lint-harness-global-collisions: child-shell
done
. "$ORCH_DIR/sib.sh"  # lint-harness-global-collisions: child-shell'
printf '%s\n' 'MANIFEST=""' > "$LT/t4/plugins/cc-cmds/orchestrator/sib.sh"
lint_case "자식 셸 표지가 붙은 소스 줄" "$LT/t4" 0 "파생 없음"
mk_tree "$LT/arm" 'GUARD_X=1
GUARD_Y=1' 'case "${GUARD_X:-}" in
  0) ;;
  *) readonly GUARD_X=0 ;;
esac
  case "${GUARD_Y:-}" in 0) ;; *) readonly GUARD_Y=0 ;; esac'
lint_case "case 갈래 머리 뒤 readonly 이름 추출" "$LT/arm" 1
check "case 갈래 머리 뒤 이름 둘 다 보고" "$(sed -n 's#^FAIL: \[충돌\] \([^ ]*\) — .*$#\1#p' "$LT/arm.err" | sort | tr '\n' ' ')" "GUARD_X GUARD_Y "
rc=0; bash "$TR_LINT" >"$LT/real.out" 2>&1 || rc=$?
check "실제 트리에서 린트가 초록" "$rc" 0

# ===========================================================================
# 모음 전역 검사
# ===========================================================================
if [ "$TR_REAL_PACE_EXISTED" = "0" ]; then
  check "실제 HOME 의 pace 디렉터리가 생기지 않았다" "$([ -e "$TR_REAL_PACE" ] && printf 있음 || printf 없음)" "없음"
fi
if [ "$TR_REAL_LEASES_EXISTED" = "0" ]; then
  check "실제 HOME 에 임대 표가 생기지 않았다" "$([ -e "$TR_REAL_PACE/leases" ] && printf 있음 || printf 없음)" "없음"
fi

# 부류 포괄: 봉투의 모든 판정 토큰이 어느 사례에서든 관측됐는가. 목록은 봉투
# 계약의 어휘이고, 각 토큰이 route.sh 에 실제로 철자돼 있는지도 함께 본다.
for tok in \
  "PARK inventory-corrupt" "PARK no-enabled-account" "PARK lease-table-corrupt" "PARK own-lease-corrupt" \
  "PARK resume-unbound" "PARK resume-logged-out" "PARK resume-bound-ineligible" "PARK resume-bound-unknown-account" \
  "PARK deadline" "PARK borrow-record-corrupt" \
  "WAIT group-exhausted" "WAIT no-room" "WAIT unknown-concurrency" "WAIT resume-bound-exhausted" \
  "WAIT resume-bound-no-room" "WAIT lease-lock-busy" "WAIT lease-contention" "WAIT fifo-yield" \
  "GRANT first" "GRANT sticky" "GRANT resume-bound" "GRANT reassigned-after-limit" "GRANT reassigned-no-room" \
  "GRANT after-wait" "GRANT shift-seat-fallback" "GRANT single-seat"; do
  if grep -F -x "$tok" "$SEEN" >/dev/null; then ok "부류 포괄: $tok 관측"; else bad "부류 포괄: $tok 관측" "어느 사례에서도 나오지 않았다"; fi
  if grep -F "\"${tok#* }\"" "$TR_ROUTE" >/dev/null; then :; else bad "부류 포괄: ${tok#* } 가 route.sh 에 없다"; fi
done

passed=$(count_results PASS)
failed=$(count_results FAIL)
assertions=$((passed + failed))
if [ "$assertions" -lt "$ASSERTION_FLOOR" ]; then
  bad "단언 하한" "실행된 단언 $assertions 개가 하한 $ASSERTION_FLOOR 미만이다 — 사례 순회가 무너졌다"
  failed=$((failed + 1))
fi
printf 'test-route: %d passed, %d failed, %d assertions\n' "$passed" "$failed" "$assertions"
[ "$failed" -eq 0 ]
