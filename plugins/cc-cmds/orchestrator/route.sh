#!/usr/bin/env bash
# route.sh — 스테이지를 어느 계정의 설정 디렉터리로 띄울지 정하는 라우터.
#
# 세 층으로 나뉜다.
#
#   순수 코어    표준 입력의 문맥 JSON 하나를 읽어 표준 출력에 답을 낸다. 시계도
#                환경도 파일도 읽지 않는다 — `now` 까지 문맥 필드다. 분수가 드는
#                연산은 전부 여기서 jq 로 하고, 척도는 정수 베이시스 포인트(bp)
#                하나다. bash 3.2 에는 정수 산술만 있고, 부동소수 비교는 이
#                라우터가 판정하는 바로 그 경계에서 틀린다.
#   수집·임대    인벤토리 스냅숏, 사용량 파일, 이 런의 스테이지 로그, 기기 임대 표를
#                읽어 문맥을 모으고, 락 아래에서만 임대 파일을 쓴다.
#   진입         `route_resolve` — 휴면 가드를 보고 휴면 봉투나 활성 경로를 낸다.
#
# 최상위에는 함수 정의와 가드 붙은 `readonly` 상수뿐이다. 게이트는 호출마다
# `run.sh` 를 통해 이 파일을 소싱하므로 최상위 명령은 모든 게이트 진입의 비용이
# 되고, 이음매 시험은 소싱 전후의 스칼라 변수를 비교하면서 `readonly` 인 이름만
# 면제한다. 그래서 `$(…)` 도 `mkdir` 도 trap 도 최상위에 두지 않고, 파일의
# 디렉터리는 필요할 때 `route__dir` 로 구한다. 이름은 대입이 `ROUTE_`, 함수가
# `route_`(내부는 `route__`) 접두다 — 전역 충돌 린트는 하네스와 게이트 사이만 보고
# 게이트 쪽 파일끼리나 함수 이름끼리의 충돌은 보지 않는다.
#
# 드라이버는 스테이지를 띄울 때마다 `route_resolve` 를 부른다. 인벤토리 기준선을
# 받아 런의 라우팅 기록(`run.sh` 의 `run_routed`)이 1 인 런은 여기서 계정을 고르고,
# 기록이 없는 런과 이 파일만 소싱한 셸은 휴면 답을 받는다.
#
# Compatibility: bash 3.2 — no associative arrays, no `mapfile`, no `wait -n`.

# ---------------------------------------------------------------------------
# 출하 상수. 정규 값이면 두고 아니면 덮어쓰는 가드 모양이라 두 번 소싱돼도
# `readonly` 재선언으로 죽지 않고, 호출자가 다른 값을 미리 심을 수도 없다.
# 시험은 이 값들을 단언하지 않고 문맥으로 주입한다.
# ---------------------------------------------------------------------------
case "${ROUTE_K_SEVEN_DAY:-}" in
  2) ;;
  *) readonly ROUTE_K_SEVEN_DAY=2 ;;
esac
case "${ROUTE_K_FIVE_HOUR:-}" in
  1) ;;
  *) readonly ROUTE_K_FIVE_HOUR=1 ;;
esac
case "${ROUTE_K_SHIFT:-}" in
  1) ;;
  *) readonly ROUTE_K_SHIFT=1 ;;
esac
case "${ROUTE_C_FIVE_HOUR:-}" in
  0.15) ;;
  *) readonly ROUTE_C_FIVE_HOUR=0.15 ;;
esac
case "${ROUTE_C_SEVEN_DAY:-}" in
  0.02) ;;
  *) readonly ROUTE_C_SEVEN_DAY=0.02 ;;
esac
# 실측 비용 표. 칸의 표본은 끝난 지 `MAX_AGE_S` 안인 것 중 최신 `MAX_N` 개이고,
# `MIN_N` 개 미만이면 칸을 만들지 않는다. 대표값 아래로는 창별 바닥값을 쓴다 —
# 사용률이 0.01 단위로 와서 그냥 중앙값은 0 이 되고, 비용 0 은 입장을 무제한으로
# 연다. 위생 문턱은 창 하나의 표본이 중앙값에 들어갈 조건이다.
case "${ROUTE_COST_MAX_AGE_S:-}" in
  604800) ;;
  *) readonly ROUTE_COST_MAX_AGE_S=604800 ;;
esac
case "${ROUTE_COST_MAX_N:-}" in
  40) ;;
  *) readonly ROUTE_COST_MAX_N=40 ;;
esac
case "${ROUTE_COST_MIN_N:-}" in
  3) ;;
  *) readonly ROUTE_COST_MIN_N=3 ;;
esac
case "${ROUTE_COST_FLOOR_FIVE_HOUR:-}" in
  0.01) ;;
  *) readonly ROUTE_COST_FLOOR_FIVE_HOUR=0.01 ;;
esac
case "${ROUTE_COST_FLOOR_SEVEN_DAY:-}" in
  0.005) ;;
  *) readonly ROUTE_COST_FLOOR_SEVEN_DAY=0.005 ;;
esac
case "${ROUTE_COST_HYG_MIN_FRAMES:-}" in
  3) ;;
  *) readonly ROUTE_COST_HYG_MIN_FRAMES=3 ;;
esac
case "${ROUTE_COST_HYG_MIN_COVER:-}" in
  0.5) ;;
  *) readonly ROUTE_COST_HYG_MIN_COVER=0.5 ;;
esac
# 표본 저장소의 보존과 판독 상한. 문맥에 싣지 않는다 — 앞의 둘은 작성기 프로세스가,
# 뒤의 하나는 수집 쪽 셸이 그대로 쓴다.
case "${ROUTE_COST_KEEP_S:-}" in
  1209600) ;;
  *) readonly ROUTE_COST_KEEP_S=1209600 ;;
esac
case "${ROUTE_COST_KEEP_LINES:-}" in
  4000) ;;
  *) readonly ROUTE_COST_KEEP_LINES=4000 ;;
esac
case "${ROUTE_COST_READ_MAX_BYTES:-}" in
  8388608) ;;
  *) readonly ROUTE_COST_READ_MAX_BYTES=8388608 ;;
esac
# 스테이지 로그 출처의 TTL. 트래커 출처와 같은 값이지만 이름을 공유하지 않는다 —
# 한쪽을 고칠 때 다른 쪽이 따라 움직이면 안 된다.
case "${ROUTE_TTL_STAGE_LOG_S:-}" in
  1800) ;;
  *) readonly ROUTE_TTL_STAGE_LOG_S=1800 ;;
esac
case "${ROUTE_TTL_TRACKER_S:-}" in
  1800) ;;
  *) readonly ROUTE_TTL_TRACKER_S=1800 ;;
esac
case "${ROUTE_FILE_STALE_FACTOR:-}" in
  3) ;;
  *) readonly ROUTE_FILE_STALE_FACTOR=3 ;;
esac
case "${ROUTE_LEASE_LOCK_WAIT_S:-}" in
  5) ;;
  *) readonly ROUTE_LEASE_LOCK_WAIT_S=5 ;;
esac
case "${ROUTE_LEASE_LOCK_ORPHAN_S:-}" in
  60) ;;
  *) readonly ROUTE_LEASE_LOCK_ORPHAN_S=60 ;;
esac
case "${ROUTE_LEASE_SCHEMA:-}" in
  'cc-cmds-lease v1') ;;
  *) readonly ROUTE_LEASE_SCHEMA='cc-cmds-lease v1' ;;
esac
case "${ROUTE_INVENTORY_SCHEMA:-}" in
  'cc-lane-accounts v1') ;;
  *) readonly ROUTE_INVENTORY_SCHEMA='cc-lane-accounts v1' ;;
esac
case "${ROUTE_USAGE_SCHEMA:-}" in
  'cc-lane-usage v1') ;;
  *) readonly ROUTE_USAGE_SCHEMA='cc-lane-usage v1' ;;
esac
case "${ROUTE_BORROW_SCHEMA:-}" in
  'cc-lane-borrow v1') ;;
  *) readonly ROUTE_BORROW_SCHEMA='cc-lane-borrow v1' ;;
esac
case "${ROUTE_COST_SCHEMA:-}" in
  'cc-cmds-cost-sample v1') ;;
  *) readonly ROUTE_COST_SCHEMA='cc-cmds-cost-sample v1' ;;
esac

route__dir() { cd "$(dirname "${BASH_SOURCE[0]}")" && pwd; }

route__warn() {
  # `run.sh` 의 `warn` 이 있으면 그것을 쓴다 — 드라이버의 표준 오류는 한 모양이어야
  # 아침 감사가 한 문법으로 읽는다. route.sh 만 소싱한 셸에는 없다.
  if declare -F warn >/dev/null 2>&1; then
    warn "$@"
  else
    printf '[route][warn] %s\n' "$*" >&2
  fi
}

# ---------------------------------------------------------------------------
# 시험 교차 지점. 제품에서는 아무것도 하지 않는다. 시험은 이 파일을 소싱한 래퍼
# 프로세스에서 이 함수들을 재정의한 뒤 `route__main` 을 불러 순서를 고정한다.
# 환경 변수로 여는 시험 갈래는 두지 않는다 — 환경은 스테이지가 게이트에 닿는
# 통로라 그대로 위조 통로가 된다.
# ---------------------------------------------------------------------------
route__hook_locked() { :; }
route__hook_listed() { :; }
route__hook_decided() { :; }
route__hook_written() { :; }
route__hook_revalidate() { :; }

# ---------------------------------------------------------------------------
# 순수 코어의 jq 라이브러리. 함수 본문이 내보내는 문자열이라 최상위 전역을 만들지
# 않는다. 이 본문의 어느 줄도 `.` 나 `source` 뒤 공백으로 시작하지 않는다 — 전역
# 충돌 린트가 그런 줄을 소스 줄로 읽는다.
# ---------------------------------------------------------------------------
route__jq_lib() {
  # 표본 스키마는 위의 가드가 문자 그대로 고정한 값이라 따옴표 안에 그대로 넣는다.
  # 판독기가 판정 경로 안에 있어 인자로 넘기면 모든 호출자가 같은 인자를 날라야 한다.
  printf 'def rt_cost_schema: "%s";\n' "$ROUTE_COST_SCHEMA"
  cat <<'JQ'
def rt_wins: ["five_hour", "seven_day"];
def rt_bp: (. * 10000 | round);
def rt_isint: type == "number" and (. == floor);
def rt_hex2: [(. / 16 | floor), (. % 16)] | map(. as $d | "0123456789ABCDEF" | .[$d:($d + 1)]) | add;
def rt_enc: explode | map(if . >= 65 and . <= 90 then "%" + rt_hex2 else ([.] | implode | @uri) end) | join("");
def rt_key($run; $lin): ($run | rt_enc) + "+" + ($lin | rt_enc);

def rt_lease_why($key; $schema):
  if type != "object" then "not-object"
  elif .schema != $schema then "schema"
  elif ((.kind | type) != "string") or .kind == "" then "kind"
  elif ((.run_id | type) != "string") or .run_id == "" or ((.lineage | type) != "string") or .lineage == "" then "key-fields"
  elif rt_key(.run_id; .lineage) != $key then "key-mismatch"
  elif ((.nonce | type) != "string") or .nonce == "" then "nonce"
  elif (.seq | rt_isint | not) then "seq"
  elif ((.account | type) != "string") or .account == "" or ((.config_dir | type) != "string") then "account"
  elif ((.holders | type) != "array") or (.holders | length) == 0
       or any(.holders[]; (type != "object") or ((.pid | rt_isint) | not) or ((.fp | type) != "string") or .fp == "") then "holders"
  elif (.reservation_bp != null)
       and (((.reservation_bp | type) != "object") or ((.reservation_bp.five_hour | rt_isint) | not) or ((.reservation_bp.seven_day | rt_isint) | not)) then "reservation"
  elif .kind == "grant"
       and ((.reservation_bp == null) or ((.basis | type) != "string") or ((.admitted_as == "known" or .admitted_as == "unknown") | not) or ((.observed | type) != "string")) then "grant-fields"
  else null end;

def rt_parse_table($raw; $names; $schema):
  reduce $names[] as $n ({items: [], corrupt: [], unparsed: []};
    ($n | sub("^.*/"; "") | sub("[.]lease$"; "")) as $key
    | if ($raw[$n] | type) != "array" then .unparsed += [$n]
      else ($raw[$n] | join("\n")) as $text
        | (if ($text | test("^[[:space:]]*$")) then null else (try {v: ($text | fromjson)} catch null) end) as $w
        | if $w == null then .unparsed += [$n]
          else ($w.v | rt_lease_why($key; $schema)) as $why
            | if $why == null then .items += [$w.v + {path: $n}]
              else .corrupt += [{path: $n, key: $key, why: $why}] end
          end
      end);

def rt_table_final($parsed; $stale; $bad; $live):
  ($live | split("\n") | map(select(. != "") | tonumber)) as $l
  | ($parsed.items | to_entries | map(.key as $i | .value + {live: any($l[]; . == $i)})) as $items
  | ($parsed.corrupt
     + ($bad | split("\n") | map(select(. != "") | {path: ., key: (sub("^.*/"; "") | sub("[.]lease$"; "")), why: "unparseable"}))) as $corrupt
  | {state: (if ($corrupt | length) > 0 then "corrupt" else "valid" end),
     items: $items, corrupt: $corrupt,
     stale_corrupt: ($stale | split("\n") | map(select(. != "")))};

def rt_inventory_why($schema; $pfx):
  if length != 1 then "documents"
  else first(.[])
    | if type != "object" then "not-object"
      elif .schema != $schema then "schema"
      elif (.accounts | type) != "array" then "accounts"
      elif any(.accounts[]; type != "object") then "account-not-object"
      elif any(.accounts[]; ((.id | type) != "string") or .id == "") then "id"
      elif ([.accounts[].id] | length) != ([.accounts[].id] | unique | length) then "id-duplicate"
      elif any(.accounts[]; (.config_dir | type) != "string") then "config_dir"
      elif any(.accounts[]; .config_dir | test("[[:cntrl:]]")) then "config_dir-control"
      elif any(.accounts[]; (.config_dir | startswith($pfx)) | not) then "config_dir-prefix"
      elif any(.accounts[]; .config_dir | endswith("/")) then "config_dir-trailing-slash"
      elif ([.accounts[].config_dir] | length) != ([.accounts[].config_dir] | unique | length) then "config_dir-duplicate"
      elif any(.accounts[]; (.unattended == "enabled" or .unattended == "draining" or .unattended == "disabled") | not) then "unattended"
      elif any(.accounts[]; (.interactive_reserved | type) != "boolean") then "interactive_reserved"
      elif any(.accounts[]; .interactive_reserved == true and .unattended != "disabled") then "reserved-not-disabled"
      else "ok" end
  end;

def rt_usage_read($now; $factor; $schema):
  if length != 1 then {state: "corrupt"}
  else first(.[])
    | if type != "object" or .schema != $schema or ((.accounts | type) != "array") then {state: "corrupt"}
      else (((.written_at_epoch | type) == "number") and ((.publish_interval_s | type) == "number")
            and (($now - .written_at_epoch) <= ($factor * .publish_interval_s))) as $fresh
        | {state: "valid", written_at_epoch, publish_interval_s, fresh: $fresh,
           accounts: [.accounts[] | select(type == "object") | if $fresh then . else del(.windows) end]}
      end
  end;

def rt_borrowing: (.state == "intent") or (.state == "borrowed") or (.state == "returning");
def rt_borrow_read($schema):
  if length != 1 then {state: "corrupt"}
  else first(.[])
    | if type != "object" or .schema != $schema then {state: "corrupt"}
      elif .state == "none" then {state: "none"}
      elif (rt_borrowing | not) then {state: "corrupt"}
      elif ((.lane_config_dir | type) != "string") or .lane_config_dir == ""
           or ((.donor | type) != "object")
           or ((.donor.id | type) != "string") or .donor.id == ""
           or ((.donor.config_dir | type) != "string") or .donor.config_dir == "" then {state: "corrupt"}
      else {state: .state, lane_config_dir: .lane_config_dir, donor: {id: .donor.id, config_dir: .donor.config_dir}} end
  end;
def rt_borrow_mark($cfg; $b):
  if ($b | type) != "object" then {}
  elif ($b | rt_borrowing) and ($cfg == $b.lane_config_dir) then {borrow: {state: $b.state, donor: ($b.donor.id? // null)}}
  elif $b.state == "corrupt" then {borrow: {state: "corrupt", donor: null}}
  else {} end;

def rt_frames_of_file:
  reduce (inputs | (fromjson? // null)) as $f ({ts: null, five_hour: null, seven_day: null};
    if ($f | type) != "object" then .
    else
      (if $f.type == "rate_limit_event" and .ts != null then
         ($f.rate_limit_info.unifiedWindows? // null) as $uw
         | reduce rt_wins[] as $w (.;
             if ($uw | type) == "object" and ($uw[$w] | type) == "object" and ($uw[$w].utilization | type) == "number"
             then .[$w] = {u: $uw[$w].utilization, resets_at: $uw[$w].resetsAt, observed_at_epoch: .ts}
             else . end)
       else . end)
      | if ($f.timestamp | type) == "string" then
          ($f.timestamp | sub("[.][0-9]+"; "") | try fromdateiso8601 catch null) as $e
          | if $e != null then .ts = $e else . end
        else . end
    end)
  | {five_hour, seven_day};

# 비용 표본의 닫힌 부류와 계정 판정. 계정 판정은 원장의 `run_ledger_account_ok` 를 jq
# 술어로 옮긴 것이고 작성기와 판독기가 함께 쓴다.
def rt_cost_kinds: ["design", "audit", "split", "implement", "review", "reconverge"];
def rt_cost_acct_ok: (type == "string") and test("^[A-Za-z0-9._:#+-]{1,64}$") and . != "-" and . != "(미상)";

# 로그 한 번을 지나며 창별 첫·끝 판독을 모은다. `rt_frames_of_file` 은 창마다 마지막
# 프레임만 남기므로 따로 둔다. 프레임 관측 시각은 같은 규칙(바로 앞의 타임스탬프
# 줄)이고, 사용률과 리셋 시각이 둘 다 숫자인 프레임만 센다.
def rt_cost_of_log:
  reduce (inputs | (fromjson? // null)) as $f ({first: null, last: null, dur: null, usd: null, cli: null, w: {five_hour: null, seven_day: null}};
    if ($f | type) != "object" then .
    else
      (if $f.type == "rate_limit_event" and .last != null then
         ($f.rate_limit_info.unifiedWindows? // null) as $uw
         | .last as $t
         | reduce rt_wins[] as $w (.;
             if ($uw | type) == "object" and ($uw[$w] | type) == "object"
                and ($uw[$w].utilization | type) == "number" and ($uw[$w].resetsAt | type) == "number"
             then $uw[$w].utilization as $u | $uw[$w].resetsAt as $r
               | .w[$w] = (if .w[$w] == null then {u0: $u, u1: $u, r0: $r, r1: $r, n: 1, t0: $t, t1: $t}
                           else .w[$w] + {u1: $u, r1: $r, n: (.w[$w].n + 1), t1: $t} end)
             else . end)
       else . end)
      | (if $f.type == "result" and ($f.duration_ms | type) == "number" then
           .dur = $f.duration_ms | .usd = (if ($f.total_cost_usd | type) == "number" then $f.total_cost_usd else null end)
         else . end)
      | (if $f.type == "system" and $f.subtype == "init" and .cli == null and ($f.claude_code_version | type) == "string"
         then .cli = $f.claude_code_version else . end)
      | if ($f.timestamp | type) == "string" then
          ($f.timestamp | sub("[.][0-9]+"; "") | try fromdateiso8601 catch null) as $e
          | if $e != null then .last = $e | .first = (.first // $e) else . end
        else . end
    end);

# 모은 판독에서 표본 한 줄. 끝은 마지막 타임스탬프, 시작은 끝에서 `duration_ms` 를 뺀
# 값이되 첫 타임스탬프보다 이르면 첫 타임스탬프다. 타임스탬프나 결과 줄이 없으면
# 구간을 정할 수 없으므로 null — 결과 줄이 없는 로그는 정상 종료에 닿지 않은 시도다.
def rt_cost_line($run; $lin; $log; $kind; $acct; $schema):
  if .last == null or .first == null or .dur == null then null
  else
    {schema: $schema, run_id: $run, lineage: $lin, log: $log, kind: $kind, account: $acct,
     t_start: ([(.last - (.dur / 1000)), .first] | max), t_end: .last, duration_ms: .dur, usd: .usd, cli: .cli,
     windows: (.w | with_entries(select(.value != null)))}
  end;

# 저장소 정리. 입력은 기존 파일의 날 줄들이다. 파싱되지 않거나 스키마가 다른 줄을
# 버리고, 같은 키(런·로그 이름)의 줄을 새 줄로 바꾸고, `t_end` 가 보존 기간보다
# 오래된 줄을 지운 뒤 `t_end` 기준 최신 `$keep_n` 줄을 남긴다.
def rt_cost_store($new; $now; $keep_s; $keep_n; $schema):
  [inputs | (fromjson? // null) | select(type == "object" and .schema == $schema)
   | select((.run_id != $new.run_id) or (.log != $new.log))]
  + [$new]
  | map(select((.t_end | type) == "number" and .t_end >= ($now - $keep_s)))
  | sort_by(.t_end) | .[-$keep_n:] | .[];

def rt_uaccts($c):
  if ($c.usage.state // "") == "valid"
  then [($c.usage.accounts // [])[] | select(type == "object" and ((.id | type) == "string"))]
  else [] end;
def rt_fresh($c):
  ($c.usage // {}) as $u
  | ($u.state == "valid") and (($u.written_at_epoch | type) == "number") and (($u.publish_interval_s | type) == "number")
    and (($c.now - $u.written_at_epoch) <= ($c.config.file_stale_factor * $u.publish_interval_s));
def rt_orgs($c):
  reduce rt_uaccts($c)[] as $a ({};
    if (($a.org_hash | type) == "string") and $a.org_hash != "" then .[$a.id] = $a.org_hash else . end);
def rt_group_of($orgs; $id): if ($orgs[$id] | type) == "string" then "org:" + $orgs[$id] else "acct:" + $id end;

def rt_cands($c; $orgs; $fresh; $g; $w):
  [rt_uaccts($c)[] | select(rt_group_of($orgs; .id) == $g) | (.windows[$w]? // null)
    | select($fresh and (type == "object") and ((.utilization | type) == "number") and ((.observed_at_epoch | type) == "number"))
    | {u: .utilization, resets_at: .resets_at_epoch, observed: .observed_at_epoch, source: .source}]
  + [($c.frames // [])[] | select((.account | type) == "string") | select(rt_group_of($orgs; .account) == $g)
    | .observed_at_epoch as $t | (.windows[$w]? // null)
    | select((type == "object") and ((.u | type) == "number") and (($t | type) == "number"))
    | {u: .u, resets_at: .resets_at, observed: $t, source: "stage-log"}];

def rt_wstate($c):
  if . == null then {state: "unknown", u_bp: null, resets_at: null, observed: null, source: null}
  elif ((.resets_at | type) == "number") and ($c.now >= .resets_at) then
    {state: "reset_elapsed", u_bp: 0, resets_at: .resets_at, observed: .observed, source: .source}
  elif ((($c.config.ttl_s[(.source // "") | tostring]) | type) != "number")
       or (($c.now - .observed) > $c.config.ttl_s[(.source // "") | tostring]) then
    {state: "unknown", u_bp: null, resets_at: .resets_at, observed: .observed, source: .source}
  else (.u | rt_bp) as $b
    | {state: (if $b >= 10000 then "exhausted" else "known" end), u_bp: $b, resets_at: .resets_at, observed: .observed, source: .source}
  end;

def rt_counted: (.kind == "grant") or (.kind == "wait") or ((.reservation_bp | type) == "object");
def rt_items($c):
  [($c.leases.items // [])[] | select(.live == true)
    | select(((.run_id == $c.request.run_id) and (.lineage == $c.request.lineage)) | not)
    | select(rt_counted)];

# 그룹의 보유 리셋권. 신선한 사용량 파일의 것만 센다 — 낡은 파일에서 정규화기는 창만
# 지우고 `reset_passes` 는 남기며, 스테이지 로그 창은 신선도와 무관하게 합쳐진다.
# 구성 계정 어느 쪽 것을 눌러도 공유 카운터가 채워지므로 id 로 합친다. 형이 틀린
# 기록은 빈 목록이다 — 이 정의는 fleet 도 부르는 `rt_prep` 안에서 돈다.
def rt_gpasses($c; $orgs; $fresh; $g):
  if $fresh | not then []
  else [rt_uaccts($c)[] | select(rt_group_of($orgs; .id) == $g) | .id as $id
         | (if ((.reset_passes | type) == "object") and ((.reset_passes.held | type) == "array") then .reset_passes.held[] else empty end)
         | select(type == "object")
         | select(((.id | type) == "string") and ((.kind | type) == "string")
                  and ((.expires_at_epoch | type) == "number") and (.expires_at_epoch > $c.now))
         | . + {account: $id}]
       | unique_by(.id) | sort_by([.expires_at_epoch, .id]) end;

def rt_gview($c; $orgs; $fresh; $inv; $items; $g):
  [$items[] | select(rt_group_of($orgs; .account) == $g)] as $gi
  | {group: $g,
     windows: (reduce rt_wins[] as $w ({};
       .[$w] = (rt_cands($c; $orgs; $fresh; $g; $w) | (if length == 0 then null else max_by([.observed, .u]) end) | rt_wstate($c)))),
     sigma: (reduce rt_wins[] as $w ({}; .[$w] = ([$gi[] | (.reservation_bp[$w]? // 0)] | add // 0))),
     count: ($gi | length),
     reserved: any($inv[]; (rt_group_of($orgs; .id) == $g) and (.interactive_reserved == true)),
     passes: rt_gpasses($c; $orgs; $fresh; $g)};

def rt_class_of($G; $ex):
  if $ex != null or any($G.windows[]; .state == "exhausted") then "X"
  elif any($G.windows[]; .state == "unknown") then "U"
  elif any($G.windows[]; .state == "reset_elapsed") then "R"
  else "K" end;
def rt_ueff($x): if $x.state == "reset_elapsed" then 0 else $x.u_bp end;
def rt_rem($G):
  [rt_wins[] as $w | ($G.windows[$w]) as $x
    | 10000 - (if $x.state == "reset_elapsed" then 0 elif $x.state == "unknown" then 10000 else $x.u_bp end) - $G.sigma[$w]]
  | min;

def rt_aview($c; $orgs; $fresh; $gv; $donors; $bgroups):
  (.) as $a
  | ([rt_uaccts($c)[] | select(.id == $a.id)] | .[0]) as $ua
  | rt_group_of($orgs; $a.id) as $g
  | $gv[$g] as $G
  | (if $ua != null and (($ua.exhausted_until_epoch | type) == "number") and ($ua.exhausted_until_epoch > $c.now)
     then $ua.exhausted_until_epoch else null end) as $ex
  | {id: $a.id, config_dir: $a.config_dir, unattended: $a.unattended, interactive_reserved: $a.interactive_reserved,
     group: $g, group_reserved: $G.reserved, exhausted_until: $ex,
     mismatch: ($ua != null and (($ua.config_dir | type) == "string") and ($ua.config_dir != $a.config_dir)),
     login_bad: ($fresh and $ua != null and (($ua.login | type) == "string") and ($ua.login != "ok")),
     class: rt_class_of($G; $ex),
     remaining_bp: rt_rem($G)}
  + (if any($donors[]; . == $a.id) then {borrowed: "donor"}
     elif any($bgroups[]; . == $g) then {borrowed: "group"}
     else {} end);

def rt_prep($schema):
  (.) as $c
  | if ($c.now | rt_isint | not) then error("now") else . end
  | rt_fresh($c) as $fresh
  | rt_orgs($c) as $orgs
  | (if $c.inventory.state == "valid" then [($c.inventory.accounts // [])[]] else [] end) as $inv
  | rt_items($c) as $items
  | ([($c.leases.items // [])[] | select((.run_id == $c.request.run_id) and (.lineage == $c.request.lineage))] | .[0]) as $own
  | ([$inv[] | rt_group_of($orgs; .id)] + [$items[] | rt_group_of($orgs; .account)]
     + (if $own != null then [rt_group_of($orgs; $own.account)] else [] end)
     + (if (($c.request.bound_account | type) == "string") and $c.request.bound_account != "" then [rt_group_of($orgs; $c.request.bound_account)] else [] end)
     | unique) as $gids
  | (reduce $gids[] as $g ({}; .[$g] = rt_gview($c; $orgs; $fresh; $inv; $items; $g))) as $gv
  | ($c.borrow // {"state": "absent"}) as $b
  | (if ($b | rt_borrowing)
     then [$inv[] | select((.id == $b.donor.id) or (.config_dir == $b.donor.config_dir)) | .id]
     else [] end) as $donors
  | (if ($b | rt_borrowing)
     then ([$donors[] | rt_group_of($orgs; .)] + [rt_group_of($orgs; $b.donor.id)] | unique)
     else [] end) as $bgroups
  | {c: $c, schema: $schema, fresh: $fresh, orgs: $orgs, items: $items, groups: $gv,
     accounts: ([$inv[] | rt_aview($c; $orgs; $fresh; $gv; $donors; $bgroups)] | sort_by(.id)),
     okey: (if (($c.request.run_id | type) == "string") and (($c.request.lineage | type) == "string")
            then rt_key($c.request.run_id; $c.request.lineage) else null end),
     own: $own,
     own_corrupt: ([($c.leases.corrupt // [])[] | select(.key != null)] as $cs
                   | if (($c.request.run_id | type) == "string") and (($c.request.lineage | type) == "string")
                     then ([$cs[] | select(.key == rt_key($c.request.run_id; $c.request.lineage)) | .path] | .[0])
                     else null end),
     table_corrupt: ($c.leases.state == "corrupt"),
     borrow_corrupt: ($b.state == "corrupt"),
     shift: ($c.request.kind == "shift")};

def rt_need_cap: if (.config.cap_bp | rt_isint | not) then error("config.cap_bp") else . end;
def rt_kv($c; $kind; $w):
  ($c.config.k[$kind][$w] // $c.config.k.default[$w]) | if rt_isint then . else error("config.k") end;
# 단계 비용 조회. 그룹·부류 칸 → 부류 칸 → 기본값의 첫 숫자와 그 출처다. 그룹 칸은
# 부류마다 따로이므로 한 그룹에 다른 부류 표본만 있으면 그 값이 새지 않는다.
def rt_cost($c; $w; $kind; $g):
  ($c.config.c[$w]) as $cw
  | (if (($cw.by_group // null) | type) == "object" and (($cw.by_group[$g] // null) | type) == "object"
        and ($cw.by_group[$g][$kind] // null) != null
     then {v: $cw.by_group[$g][$kind], source: "group-kind"}
     elif ($cw.by_kind[$kind] // null) != null then {v: $cw.by_kind[$kind], source: "kind"}
     else {v: $cw.default, source: "default"} end)
  | if (.v | type) == "number" then {bp: (.v | rt_bp), source: .source} else error("config.c") end;

# 비용 표 — 저장소의 표본에서 창마다 부류 칸과 그룹·부류 칸의 값. 순수하다. 설정이
# 없거나 숫자가 아니거나 표본 원문이 문자열이 아니면 빈 표이고, 그러면 조회는 모두
# 기본값으로 떨어진다 — 추정기의 결함이 판정을 막지 않는다.
def rt_cost_empty: {five_hour: {by_kind: {}, by_group: {}}, seven_day: {by_kind: {}, by_group: {}}};
def rt_cost_cfg_ok:
  if type != "object" then false
  elif ((.floor | type) != "object") or ((.hygiene | type) != "object") then false
  else (.max_age_s | type) == "number" and (.max_n | rt_isint) and .max_n >= 1 and (.min_n | rt_isint) and .min_n >= 1
       and ((.floor.five_hour | type) == "number") and ((.floor.seven_day | type) == "number")
       and ((.hygiene.min_frames | type) == "number") and ((.hygiene.min_cover | type) == "number") end;
def rt_cost_win_ok:
  (type == "object") and ((.u0 | type) == "number") and ((.u1 | type) == "number") and .u0 >= 0 and .u1 <= 1
  and (.n | rt_isint) and .n >= 0 and ((.r0 | type) == "number") and ((.r1 | type) == "number");
def rt_cost_sample_ok($now):
  if type != "object" or .schema != rt_cost_schema then false
  elif ((.run_id | type) != "string") or ((.log | type) != "string") then false
  elif (.kind as $k | any(rt_cost_kinds[]; . == $k)) | not then false
  elif (.account | rt_cost_acct_ok) | not then false
  elif ((.t_start | type) != "number") or ((.t_end | type) != "number") then false
  elif .t_start > .t_end or .t_end > ($now + 300) then false
  elif (.windows | type) != "object" then false
  else (.windows) as $ws | all(rt_wins[]; ($ws[.] // null) as $x | $x == null or ($x | rt_cost_win_ok)) end;

# 같은 그룹 표본의 구간 겹침으로 정한 분모 m = (길이 + 겹침 합) / 길이. 입력은 한
# 그룹의 표본 배열이다. 시작 순으로 늘어놓고 앞으로 훑다가 시작이 자기 끝을 넘는
# 표본에서 멈춘다. 길이 0 인 표본의 m 은 1 이다(위생에서 빠진다).
def rt_cost_m:
  sort_by(.t_start) | . as $s | length as $n
  | (reduce range(0; $n) as $i ([range(0; $n) | 0];
       reduce (label $out | range($i + 1; $n) as $j
               | if $s[$j].t_start >= $s[$i].t_end then break $out
                 else {j: $j, o: (([$s[$i].t_end, $s[$j].t_end] | min) - $s[$j].t_start)} end) as $x
         (.; .[$i] += $x.o | .[$x.j] += $x.o))) as $ov
  | [range(0; $n) as $i | $s[$i] + {m: (if $s[$i].len > 0 then ($s[$i].len + $ov[$i]) / $s[$i].len else 1 end)}];

# 창 판독 하나의 위생. 나눗셈 없이 쓴다 — 길이 0 인 표본이 오류 없이 빠지도록.
def rt_cost_hyg($h; $x):
  ($x.n >= $h.min_frames) and (.len > 0) and (($x.t0 | type) == "number") and (($x.t1 | type) == "number")
  and (($x.t1 - $x.t0) >= ($h.min_cover * .len)) and ($x.r0 == $x.r1) and ($x.u1 >= $x.u0);

# 칸 하나. 입력은 `{t_end, v}` 배열이다. 최신 `max_n` 개의 중앙값(짝수면 가운데 둘의
# 평균)을 창 바닥값 아래로 내리지 않는다. 표본이 `min_n` 개보다 적으면 null.
def rt_cost_cell($k; $w):
  (sort_by(.t_end) | .[-$k.max_n:]) as $xs
  | if ($xs | length) < $k.min_n then null
    else ($xs | map(.v) | sort) as $v | ($v | length) as $n
      | (if $n % 2 == 1 then $v[($n - 1) / 2] else ($v[$n / 2 - 1] + $v[$n / 2]) / 2 end) as $med
      | {value: ([$k.floor[$w], $med] | max), n: $n, oldest: ($xs | map(.t_end) | min)} end;

def rt_cost_table($c):
  ($c.config.cost // null) as $k
  | if (($k | rt_cost_cfg_ok) | not) or (($c.cost_samples | type) != "string") or (($c.now | type) != "number") then rt_cost_empty
    else rt_orgs($c) as $orgs
      | [$c.cost_samples | split("\n")[] | (fromjson? // null) | select(rt_cost_sample_ok($c.now))]
      | (reduce .[] as $s ({}; .[[$s.run_id, $s.log] | tojson] = $s)) | [.[]]
      | map(. + {g: rt_group_of($orgs; .account), len: (.t_end - .t_start)})
      | [group_by(.g)[] | rt_cost_m[]]
      | map(select(.t_end >= ($c.now - $k.max_age_s))) as $live
      | reduce rt_wins[] as $w (rt_cost_empty;
          [$live[] | (.) as $s | ($s.windows[$w] // null) as $x
            | select($x != null) | select($s | rt_cost_hyg($k.hygiene; $x))
            | {g: $s.g, kind: $s.kind, t_end: $s.t_end, v: (($x.u1 - $x.u0) / $s.m)}] as $vs
          | reduce ($vs | group_by(.kind))[] as $kv (.;
              ($kv | rt_cost_cell($k; $w)) as $cell
              | if $cell == null then . else .[$w].by_kind[$kv[0].kind] = $cell end)
          | reduce ($vs | group_by([.g, .kind]))[] as $gv (.;
              ($gv | rt_cost_cell($k; $w)) as $cell
              | if $cell == null then . else .[$w].by_group[$gv[0].g][$gv[0].kind] = $cell end))
    end;

# 표를 문맥의 `config.c` 위에 얹는다. 표의 칸이 주입된 같은 칸을 이긴다. 빈 창은
# 건드리지 않는다.
def rt_cost_apply:
  rt_cost_table(.) as $t
  | reduce rt_wins[] as $w (.;
      if ($t[$w].by_kind == {}) and ($t[$w].by_group == {}) then .
      else .config.c[$w].by_kind = ((.config.c[$w].by_kind // {}) + ($t[$w].by_kind | map_values(.value)))
        | .config.c[$w].by_group = ((.config.c[$w].by_group // {}) * ($t[$w].by_group | map_values(map_values(.value))))
      end);

def rt_admit_core($c; $G; $ex):
  (($c.request.kind // "") | tostring) as $kind
  | (reduce rt_wins[] as $w ({}; .[$w] = rt_cost($c; $w; $kind; $G.group))) as $cost
  | (reduce rt_wins[] as $w ({}; .[$w] = (rt_kv($c; $kind; $w) * $cost[$w].bp))) as $res
  | $G.windows as $W
  | (if $ex != null or any($W[]; .state == "exhausted") then
      {admitted: false, admitted_as: null, reservation_bp: $res, failed: ["exhausted"],
       ready_at: (if $ex != null then $ex
                  else ([$W[] | select(.state == "exhausted") | .resets_at] | if any(.[]; type != "number") then null else max end) end)}
    elif any($W[]; .state == "unknown") then
      {admitted: ($G.count == 0), admitted_as: "unknown", reservation_bp: $res,
       failed: (if $G.count == 0 then [] else ["unknown-concurrency"] end), ready_at: null}
    else
      ([rt_wins[] as $w | select(rt_ueff($W[$w]) + $G.sigma[$w] + $res[$w] > 10000) | $w]
       + (if rt_ueff($W.five_hour) >= $c.config.cap_bp then ["cap"] else [] end)) as $f
      | {admitted: (($f | length) == 0), admitted_as: "known", reservation_bp: $res, failed: $f,
         ready_at: (if ($f | length) == 0 then null
                    else ([$f[] | (if . == "cap" then "five_hour" else . end) as $w | $W[$w].resets_at]
                          | if any(.[]; (type != "number") or (. <= $c.now)) then null else max end) end)}
    end)
  + {cost: $cost};

# 버려질 한도 W7(bp). 최대 속도 ρ7 로 써도 주간 정기 리셋 때 남아 사라지는 양이다.
# ρ7 은 비용표의 주간/5시간 비율에 5시간 상한을 곱한 속도이고, 리셋 전에 만료되는
# 주간 리셋권은 만료 직전에 눌러 다시 차는 양 U(E) 만큼 공급을 늘린다. 리셋권을 더해도
# 줄지 않도록 리셋권 없는 값과의 최댓값을 쓰고, 정수로 반올림해 `remaining_bp` 동률
# 깨기를 가로채지 않는다.
def rt_w7($c; $G; $cost):
  $G.windows.seven_day as $x
  | if ($x.state != "known") or (($x.resets_at | type) != "number") or ($x.resets_at <= $c.now)
       or ((($cost.five_hour.bp // 0) > 0) | not) then 0
    else (10000 - $x.u_bp - $G.sigma.seven_day) as $r7
      | ($x.resets_at - $c.now) as $t
      | (($cost.seven_day.bp / $cost.five_hour.bp) * $c.config.cap_bp / 18000) as $rho
      | ([($G.passes // [])[]
          | select((.kind == "seven_day" or .kind == "both") and (.expires_at_epoch > $c.now) and (.expires_at_epoch < $x.resets_at))
          | ([10000, (10000 - $r7) + $rho * (.expires_at_epoch - $c.now)] | min) as $u
          | ([0, $r7 + $u - $rho * $t] | max)]
         + [([0, $r7 - $rho * $t] | max)])
      | max | round
    end;

# 리셋권 종류가 덮는 창. 모르는 종류는 아무 창도 덮지 않는다.
def rt_pass_wins($kind):
  if $kind == "five_hour" then ["five_hour"]
  elif $kind == "seven_day" then ["seven_day"]
  elif $kind == "both" then rt_wins
  else [] end;

# 이 종류의 리셋권을 누르면 오늘의 입장 규칙을 통과하는가. 덮는 창만 리셋 경과로 바꾼
# 사본에 바꾸지 않은 입장 판정을 돌린다. 계정 단위 소진은 넘기지 않는다 — 발행기의
# 소진 시각은 창에서만 오고, 리셋권이 덮지 않는 소진 창은 사본에서도 소진으로 남는다.
def rt_press_ok($c; $G; $kind):
  rt_pass_wins($kind) as $ws
  | if (($ws | length) == 0) or any($G.windows[]; .state == "unknown") then false
    else (reduce $ws[] as $w ($G; .windows[$w] |= {state: "reset_elapsed", u_bp: 0, resets_at, observed, source}))
      | rt_admit_core($c; .; null) | .admitted
    end;

# 예비 공급으로 쓸 리셋권. 인식된 종류마다 만료가 가장 이른 것 하나를 보고, 누를 수
# 있는 것 중 만료·종류·id 가 가장 앞선 것이다. 없으면 null.
def rt_pass_pick($c; $G):
  [($G.passes // []) | group_by(.kind)[] | select(.[0].kind as $k | any(rt_pass_wins($k)[]; true))
    | min_by([.expires_at_epoch, .id]) | select(rt_press_ok($c; $G; .kind))]
  | sort_by([.expires_at_epoch, .kind, .id]) | .[0];

def rt_classify($schema): rt_prep($schema) as $p | {accounts: $p.accounts, groups: ([$p.groups[]] | sort_by(.group))};
def rt_admit_all($schema):
  rt_need_cap | rt_cost_apply | rt_prep($schema) as $p
  | [$p.accounts[] | (.) as $a
      | rt_admit_core($p.c; $p.groups[$a.group]; $a.exhausted_until) + {account: $a.id, group: $a.group, class: $a.class}];

def rt_av($p; $id): [$p.accounts[] | select(.id == $id)] | .[0];
def rt_policy_ok($a):
  $a != null and ($a.unattended == "enabled") and ($a.group_reserved | not) and ($a.login_bad | not) and ($a.mismatch | not)
  and (($a.borrowed // null) == null);
def rt_new_ok($a): rt_policy_ok($a) and ($a.class != "X");
def rt_hold_ok($a):
  $a != null and ($a.unattended == "enabled" or $a.unattended == "draining")
  and ($a.group_reserved | not) and ($a.class != "X") and ($a.login_bad | not);
def rt_fifo_blocked($p; $g):
  ($p.own | if . != null and .kind == "wait" and .live == true then .seq else null end) as $mine
  | any($p.items[]; (.kind == "wait") and (rt_group_of($p.orgs; .account) == $g) and ($mine == null or .seq < $mine));
def rt_observed($G):
  [$G.windows[] | select(.observed != null)]
  | if length == 2 then (min_by(.observed) | "\(.source // "none")@\(.observed)") else "none" end;
def rt_past_deadline($c; $until):
  ($c.deadline // null) as $d
  | (($d | type) == "object") and (($d.deadline_epoch | type) == "number") and (($d.expected_duration_s | type) == "number")
    and (($until | type) == "number") and ($until + $d.expected_duration_s > $d.deadline_epoch);
def rt_corrupt_path($p): [($p.c.leases.corrupt // [])[] | .path] | sort | .[0];
def rt_mv($path): "\($path) 를 확인하고 옮기십시오: mv '\($path)' '\($path).quarantine'";

def rt_env($e; $op; $rec): $e + {txn: {op: $op, record: $rec}};
def rt_park($reason; $recovery): {verdict: "PARK", reason: $reason, recovery: $recovery};
def rt_park_borrow_corrupt:
  rt_park("borrow-record-corrupt"; "cc-lane 차용 기록을 읽을 수 없다 — 파일을 지우거나 옮기지 말고 cc-lane 이 기록을 다시 쓰기를 기다리거나 cc-lane borrow status 로 확인한다");
def rt_park_deadline($until):
  {verdict: "PARK", reason: "deadline", ready_at: $until, recovery: "마감 안에 끝낼 수 없다 — 마감을 늘리거나 ready_at 뒤에 다시 시작한다"};
# 대기 봉투의 `cost` 는 그 대기를 정한 입장 판정의 창별 비용이고, 그런 판정이 없는
# 대기(FIFO 양보·미상 동시성·후보 없음·거래 실패)는 null 이다.
def rt_wait_c($g; $acct; $until; $reason; $cost):
  {verdict: "WAIT", group: $g, account: $acct, until_epoch: $until, reason: $reason, cost: $cost};
def rt_wait($g; $acct; $until; $reason): rt_wait_c($g; $acct; $until; $reason; null);
# 예비 공급 대기. 오늘이면 마감 PARK 일 자리에서 누를 수 있는 리셋권이 있을 때, 같은
# 사유와 비용에 마감 없이 기다리고 어느 리셋권을 기다리는지 덧붙인다.
def rt_wait_reserve($g; $acct; $reason; $cost; $pass):
  rt_wait_c($g; $acct; null; $reason; $cost)
  + {reserve: {group: $g, account: $acct, pass_id: $pass.id, kind: $pass.kind, expires_at_epoch: $pass.expires_at_epoch}};
def rt_seat_of($cfg; $basis; $b):
  {verdict: "GRANT", basis: $basis, account: null, config_dir: $cfg, group: null, reservation_bp: null,
   admitted_as: null, observed: null, lease_key: null, nonce: null, dormant: false}
  + rt_borrow_mark($cfg; $b);
def rt_seat($p; $basis): rt_seat_of($p.c.seat.config_dir; $basis; $p.c.borrow);
def rt_grant_lease($p; $o; $basis):
  {verdict: "GRANT", basis: $basis, account: $o.account, config_dir: $o.config_dir, group: rt_group_of($p.orgs; $o.account),
   reservation_bp: ($o.reservation_bp // null), admitted_as: ($o.admitted_as // null), observed: ($o.observed // null),
   lease_key: $p.okey, nonce: $o.nonce, dormant: false, cost: null};
def rt_grant_new($p; $a; $adm; $basis):
  {verdict: "GRANT", basis: $basis, account: $a.id, config_dir: $a.config_dir, group: $a.group,
   reservation_bp: $adm.reservation_bp, admitted_as: $adm.admitted_as, observed: rt_observed($p.groups[$a.group]),
   lease_key: $p.okey, nonce: ($p.c.fresh_nonce // null), dormant: false, cost: $adm.cost};
def rt_nextseq($p): ((([($p.c.leases.items // [])[] | .seq | select(type == "number")] | max) // 0) + 1);
def rt_rec_new($p; $e):
  {schema: $p.schema, kind: "grant", run_id: $p.c.request.run_id, lineage: $p.c.request.lineage, nonce: $e.nonce,
   seq: rt_nextseq($p), account: $e.account, config_dir: $e.config_dir, reservation_bp: $e.reservation_bp,
   admitted_as: $e.admitted_as, basis: $e.basis, observed: $e.observed, granted_at_epoch: $p.c.now,
   holders: ($p.c.request.holders // [])};
def rt_rec_hold($p):
  $p.own | del(.live, .path) | .holders = ((.holders + ($p.c.request.holders // [])) | unique_by(.pid));

def rt_resume($p):
  $p.own as $o
  | if $o != null and $o.kind == "grant" and $o.live == true then
      rt_av($p; $o.account) as $a
      | $p.groups[rt_group_of($p.orgs; $o.account)] as $G
      | (if $a != null then $a.class else rt_class_of($G; null) end) as $cls
      | if $cls == "X" then
          rt_admit_core($p.c; $G; ($a.exhausted_until? // null)) as $adm
          | rt_env(rt_wait_c($G.group; $o.account; $adm.ready_at; "resume-bound-exhausted"; $adm.cost); "none"; null)
        elif $a != null and $a.login_bad then
          rt_env(rt_park("resume-logged-out"; "묶인 계정의 로그인이 끊겼다 — 그 설정 디렉터리에서 claude /login 을 한다"); "none"; null)
        else rt_env(rt_grant_lease($p; $o; "resume-bound"); "hold"; rt_rec_hold($p)) end
    else
      $p.c.request.bound_account as $b
      | if (($b | type) != "string") or $b == "" then
          rt_env(rt_park("resume-unbound"; "재개할 세션의 계정 기록이 없다 — 계보를 새로 시작한다"); "none"; null)
        else rt_av($p; $b) as $a
          | if $a == null then
              rt_env(rt_park("resume-bound-unknown-account"; "묶인 계정이 인벤토리에 없다 — cc-lane account check"); "none"; null)
            elif ($a.unattended != "enabled") or $a.group_reserved or $a.mismatch or (($a.borrowed // null) != null) then
              rt_env(rt_park("resume-bound-ineligible"; "묶인 계정이 무인 사용 대상이 아니다 — 계정 정책을 확인하거나 계보를 새로 시작한다"); "none"; null)
            elif $a.login_bad then
              rt_env(rt_park("resume-logged-out"; "묶인 계정의 로그인이 끊겼다 — 그 설정 디렉터리에서 claude /login 을 한다"); "none"; null)
            elif $p.table_corrupt then
              rt_env(rt_park("lease-table-corrupt"; rt_mv(rt_corrupt_path($p))); "none"; null)
            elif $p.borrow_corrupt then rt_env(rt_park_borrow_corrupt; "none"; null)
            else rt_admit_core($p.c; $p.groups[$a.group]; $a.exhausted_until) as $adm
              | (if $adm.failed == ["exhausted"] then "resume-bound-exhausted" else "resume-bound-no-room" end) as $why
              | if $adm.admitted then
                  rt_grant_new($p; $a; $adm; "resume-bound") as $e | rt_env($e; "write"; rt_rec_new($p; $e))
                elif rt_past_deadline($p.c; $adm.ready_at) then
                  rt_pass_pick($p.c; $p.groups[$a.group]) as $pass
                  | if $pass != null and (rt_past_deadline($p.c; $p.c.now) | not) then
                      rt_env(rt_wait_reserve($a.group; $a.id; $why; $adm.cost; $pass); "none"; null)
                    else rt_env(rt_park_deadline($adm.ready_at); "none"; null) end
                else rt_env(rt_wait_c($a.group; $a.id; $adm.ready_at; $why; $adm.cost); "none"; null)
                end
            end
        end
    end;

def rt_waitpick($p; $b; $reason):
  ([$b[] | select((.ready | type) == "number")] | sort_by([.ready, .g]) | .[0]) as $m
  | (if $m != null then $m.ready else null end) as $until
  | (if $m != null then $m.g else ([$b[].g] | sort | .[0]) end) as $g
  | if rt_past_deadline($p.c; $until) then
      # 지명은 `$m` 과 다른 그룹일 수 있으므로 그룹과 비용을 지명된 항목에서 꺼낸다.
      ([$b[] | (.) as $e | rt_pass_pick($p.c; $p.groups[$e.g]) as $pass | select($pass != null) | {e: $e, pass: $pass}]
       | sort_by([.pass.expires_at_epoch, .e.g]) | .[0]) as $n
      | if $n != null and (rt_past_deadline($p.c; $p.c.now) | not) then
          rt_env(rt_wait_reserve($n.e.g; null; $reason; $n.e.cost; $n.pass); "none"; null)
        else rt_env(rt_park_deadline($until); "none"; null) end
    else rt_env(rt_wait_c($g; null; $until; $reason; (if $m != null then $m.cost else null end)); "none"; null) end;

def rt_nocand($p; $pool):
  [$pool[] | {g: .a.group,
              why: (if .a.class == "X" or .adm.failed == ["exhausted"] then "x"
                    elif .adm.admitted and .fifo then "fifo"
                    elif .adm.failed == ["unknown-concurrency"] then "ucc"
                    else "room" end),
              ready: (if .adm.admitted then null else .adm.ready_at end), cost: .adm.cost}] as $b
  | if ($b | length) == 0 then rt_env(rt_wait(null; null; null; "no-room"); "none"; null)
    elif all($b[]; .why == "x") then rt_waitpick($p; $b; "group-exhausted")
    elif all($b[]; .why == "ucc") then rt_env(rt_wait(([$b[].g] | sort | .[0]); null; null; "unknown-concurrency"); "none"; null)
    elif any($b[]; .why == "fifo") then
      rt_env(rt_wait(([$b[] | select(.why == "fifo") | .g] | sort | .[0]); null; null; "fifo-yield"); "none"; null)
    else rt_waitpick($p; $b; "no-room") end;

def rt_new($p; $basis0; $excl):
  $p.own as $o
  | (if $p.c.request.after_wait == true then "after-wait" else $basis0 end) as $basis
  | (($p.c.request.event == "first") and $o != null and ($o.kind == "grant") and ($o.live == true)
     and rt_hold_ok(rt_av($p; $o.account))) as $idem
  | if $idem and ($p.c.request.nonce == $o.nonce) then
      rt_env(rt_grant_lease($p; $o; $o.basis); "hold"; rt_rec_hold($p))
    elif $p.table_corrupt then rt_env(rt_park("lease-table-corrupt"; rt_mv(rt_corrupt_path($p))); "none"; null)
    elif $idem then rt_env(rt_grant_lease($p; $o; $o.basis); "write"; rt_rec_hold($p))
    elif $p.borrow_corrupt then rt_env(rt_park_borrow_corrupt; "none"; null)
    else
      [$p.accounts[] | select(rt_policy_ok(.)) | select(.id != $excl) | (.) as $a
        | rt_admit_core($p.c; $p.groups[$a.group]; $a.exhausted_until) as $adm
        | {a: $a, adm: $adm, fifo: rt_fifo_blocked($p; $a.group),
           w7: rt_w7($p.c; $p.groups[$a.group]; $adm.cost)}] as $pool
      | [$pool[] | select(.adm.admitted and (.fifo | not))] as $cands
      | if ($cands | length) > 0 then
          ($cands | sort_by([(if .a.class == "U" then 1 else 0 end), (0 - .w7), (0 - .a.remaining_bp),
                             (.a.id as $id | if any(($p.c.sticky // [])[]; . == $id) then 0 else 1 end), .a.id])
                  | .[0]) as $best
          | rt_grant_new($p; $best.a; $best.adm; $basis) as $e
          | rt_env($e; "write"; rt_rec_new($p; $e))
        elif $p.shift then rt_env(rt_seat($p; "shift-seat-fallback"); "none"; null)
        else rt_nocand($p; $pool) end
    end;

def rt_retry($p):
  $p.own as $o
  | (if $o != null and $o.kind == "grant" then rt_av($p; $o.account) else null end) as $a
  | if $o != null and $o.kind == "grant" and $o.live == true and rt_hold_ok($a) then
      rt_env(rt_grant_lease($p; $o; "sticky"); "hold"; rt_rec_hold($p))
    elif $o != null and $o.kind == "grant" and ($o.live != true) and rt_new_ok($a) and ($p.table_corrupt | not)
         and ($p.borrow_corrupt | not)
         and (rt_admit_core($p.c; $p.groups[$a.group]; $a.exhausted_until) | .admitted) then
      rt_admit_core($p.c; $p.groups[$a.group]; $a.exhausted_until) as $adm
      | rt_grant_new($p; $a; $adm; "sticky") as $e | rt_env($e; "write"; rt_rec_new($p; $e))
    else rt_new($p; "reassigned-no-room"; null) end;

def rt_prev($p):
  ((if $p.own != null and $p.own.kind == "grant" then $p.own.account else null end) // $p.c.request.bound_account) // null;

def rt_decide($schema):
  rt_need_cap
  | if ((.request.run_id | type) != "string") or .request.run_id == "" or (.request.run_id | startswith("."))
       or ((.request.lineage | type) != "string") or .request.lineage == "" then error("request.key") else . end
  | rt_cost_apply
  | rt_prep($schema) as $p
  | $p.c as $c
  | (if $c.inventory.state == "corrupt" then rt_env(rt_park("inventory-corrupt"; "cc-lane account check"); "none"; null)
     elif $c.inventory.state != "valid" then rt_env(rt_seat($p; "single-seat"); "none"; null)
     elif $p.own_corrupt != null then
       (if $p.shift then rt_env(rt_seat($p; "shift-seat-fallback"); "none"; null)
        else rt_env(rt_park("own-lease-corrupt"; rt_mv($p.own_corrupt)); "none"; null) end)
     elif $c.request.event == "resume" then rt_resume($p)
     elif $c.request.event == "crash-retry" or $c.request.event == "hollow-retry" then rt_retry($p)
     elif $c.request.event == "first" then rt_new($p; "first"; null)
     elif $c.request.event == "limit-reclaim" or $c.request.event == "first-reject" then
       rt_new($p; "reassigned-after-limit"; rt_prev($p))
     else error("request.event") end)
  | (if $p.shift and ((.verdict == "WAIT") or ((.verdict == "PARK") and (.reason != "inventory-corrupt")))
     then rt_env(rt_seat($p; "shift-seat-fallback"); "none"; null) else . end)
  | (if (($c.leases.stale_corrupt // []) | length) > 0 then . + {stale_corrupt: $c.leases.stale_corrupt} else . end);

def rt_revalidate($schema; $rec):
  (.request = ((.request // {}) + {run_id: $rec.run_id, lineage: $rec.lineage, bound_account: $rec.account}))
  | rt_prep($schema) as $p
  | $p.groups[rt_group_of($p.orgs; $rec.account)] as $G
  | if any($G.windows[]; .state == "unknown") then $G.count == 0
    else all(rt_wins[]; (.) as $w | (rt_ueff($G.windows[$w]) + $G.sigma[$w] + ($rec.reservation_bp[$w] // 0)) <= 10000) end;

def rt_txn_fallback($reason; $rec):
  if .request.kind == "shift" then rt_seat_of(.seat.config_dir; "shift-seat-fallback"; .borrow)
  elif $reason == "borrow-record-corrupt" then rt_park_borrow_corrupt
  else rt_orgs(.) as $o
    | rt_wait((if $rec != null then rt_group_of($o; $rec.account) else null end); null; null; $reason) end;

def rt_wait_record($leases; $run; $lin; $acct; $dir; $nonce; $now; $holders; $schema):
  ([$leases.items[] | select(.run_id == $run and .lineage == $lin)] | .[0]) as $own
  | if $own != null and $own.kind == "grant" then error("grant-held")
    else {schema: $schema, kind: "wait", run_id: $run, lineage: $lin, nonce: $nonce,
          seq: (if $own != null and ($own.seq | rt_isint) then $own.seq
                else ((([$leases.items[] | .seq | select(type == "number")] | max) // 0) + 1) end),
          account: $acct, config_dir: $dir, granted_at_epoch: $now, holders: $holders} end;
JQ
}

# ---------------------------------------------------------------------------
# 순수 코어. 표준 입력의 문맥 하나 → 표준 출력. jq 가 실패하면(필수 설정 결측,
# 형이 틀린 필드) 입력 계약 위반으로 rc 2 다 — 닫힌 쪽이다. 5시간 상한
# `config.cap_bp` 가 없거나 정수가 아닌 것도 여기에 든다. 상한을 끈 채 부여하는
# 쪽으로 열리지 않는다.
# ---------------------------------------------------------------------------
route_lineage_of() {
  # route_lineage_of <dispatch-id> — 끝의 `.retry` 를 모두 뗀 계보 id.
  local d="${1:-}"
  while :; do
    case "$d" in
      *.retry) d=${d%.retry} ;;
      *) break ;;
    esac
  done
  printf '%s\n' "$d"
}

route_classify() {
  jq -c --arg schema "$ROUTE_LEASE_SCHEMA" "$(route__jq_lib)"' rt_classify($schema)' || return 2
}

route_admit() {
  jq -c --arg schema "$ROUTE_LEASE_SCHEMA" "$(route__jq_lib)"' rt_admit_all($schema)' || return 2
}

route_decide() {
  # 봉투 옆의 `txn` 은 임대 거래가 할 일(`none`/`hold`/`write`)과 쓸 기록이다.
  # 거래는 그것을 떼고 봉투만 낸다.
  jq -c --arg schema "$ROUTE_LEASE_SCHEMA" "$(route__jq_lib)"' rt_decide($schema)' || return 2
}

route__enc() {
  jq -rn --arg s "${1:-}" "$(route__jq_lib)"' $s | rt_enc'
}

route__dec() {
  # 인코딩 결과에는 날 `%` 와 날 백슬래시가 없으므로 `%XX` 를 `\xXX` 로 바꿔
  # `printf '%b'` 에 넘기면 바이트가 그대로 돌아온다.
  local s="${1:-}"
  s=${s//\%/\\x}
  printf '%b' "$s"
}

route__key() {
  # route__key <run_id> <lineage> — 임대 파일 이름의 키. `run_id` 가 비었거나 `.`
  # 로 시작하면 거부한다 — 점 파일이 되어 셸 글롭에서 사라진다.
  case "${1:-}" in
    ''|.*) return 2 ;;
  esac
  [ -n "${2:-}" ] || return 2
  jq -rn --arg r "$1" --arg l "$2" "$(route__jq_lib)"' rt_key($r; $l)'
}

# ---------------------------------------------------------------------------
# 입력 판독.
# ---------------------------------------------------------------------------
route_inventory_check() {
  # route_inventory_check <file> — rc 0 유효 / 1 깨짐(사유는 표준 오류) / 2 부재.
  # `lane_record_read` 의 세 값과 같은 순서다. `config_dir` 는 정규화하지 않는다 —
  # 끝 슬래시도 깨짐이다. 다시 쓰면 같은 디렉터리를 두 문자열로 부르게 된다.
  local f="${1:-}" why
  if [ -z "$f" ] || [ ! -e "$f" ]; then return 2; fi
  why=$(jq -r -s --arg schema "$ROUTE_INVENTORY_SCHEMA" --arg pfx "${HOME:-}/.claude-" \
        "$(route__jq_lib)"' rt_inventory_why($schema; $pfx)' "$f" 2>/dev/null) || why="parse"
  [ "$why" = "ok" ] && return 0
  printf '[route] 인벤토리가 깨졌다: %s (%s)\n' "$f" "${why:-parse}" >&2
  return 1
}

route_usage_read() {
  # route_usage_read <file> <now> — 사용량 파일의 정규형. 부재·깨짐·다른 스키마는
  # 모든 계정이 미지라는 뜻이고 라우팅을 끄지 않는다. 파일 층에서 낡았으면 창 값을
  # 빼되 식별 필드는 남긴다 — 조직과 디렉터리는 나이를 먹지 않는다. `status` 는
  # 읽지 않는다.
  local f="${1:-}" now="${2:-}" out
  case "$now" in
    ''|*[!0-9]*) return 2 ;;
  esac
  if [ -z "$f" ] || [ ! -e "$f" ]; then
    printf '%s\n' '{"state":"absent"}'
    return 0
  fi
  out=$(jq -c -s --argjson now "$now" --argjson factor "$ROUTE_FILE_STALE_FACTOR" --arg schema "$ROUTE_USAGE_SCHEMA" \
        "$(route__jq_lib)"' rt_usage_read($now; $factor; $schema)' "$f" 2>/dev/null) || out='{"state":"corrupt"}'
  [ -n "$out" ] || out='{"state":"corrupt"}'
  if [ "$(printf '%s' "$out" | jq -r '(.fresh == false) and any((.accounts // [])[]; (.login | type) == "string" and .login != "ok")')" = "true" ]; then
    route__warn "사용량 파일이 낡아 로그인 상태를 ok 로 읽는다: ${f}"
  fi
  printf '%s\n' "$out"
}

route__borrow_path() {
  # route__borrow_path — cc-lane 차용 기록의 절대 경로. 기준은 비어 있지 않은
  # `XDG_STATE_HOME`, 아니면 비어 있지 않은 `HOME` 의 `.local/state` 다. 기준이 절대
  # 경로가 아니거나 둘 다 비면 출력 없이 rc 1 이다 — 조합 전에 검사해야 빈 `HOME` 이
  # `/.local/state` 로 통과하지 않는다. cc-lane 도 빈 값을 미설정으로 보고 상대 경로를
  # 거부한다. 이 경로를 쓰는 자리는 모두 이 함수 하나를 쓴다.
  local base
  if [ -n "${XDG_STATE_HOME:-}" ]; then
    base="$XDG_STATE_HOME"
  elif [ -n "${HOME:-}" ]; then
    base="$HOME"
  else
    return 1
  fi
  case "$base" in
    /*) ;;
    *) return 1 ;;
  esac
  if [ -z "${XDG_STATE_HOME:-}" ]; then base="$base/.local/state"; fi
  printf '%s\n' "$base/cc-lane/borrow.json"
}

route_borrow_read() {
  # route_borrow_read <file> — 차용 기록의 정규형 한 줄: absent·none·corrupt, 또는
  # 차용 중 세 상태의 `{state, lane_config_dir, donor: {id, config_dir}}`. 인자가
  # 없으면 rc 2, 그 밖에는 rc 0 이고 아무것도 만들지 않으며 표준 오류에 쓰지 않는다.
  # 첫 일치가 이긴다. 심링크·일반 파일이 아닌 것(디렉터리·FIFO)은 jq 로 열지 않고
  # 손상이다. 부재는 가장 가까운 존재하는 상위가 검색 가능한 디렉터리일 때만이다 —
  # 검색할 수 없는 상위 아래의 파일도 `-e` 가 거짓이라, 존재 검사 하나로는 열린 쪽으로
  # 실패한다. jq 는 읽기 실패에서도 표준 출력에 `[]` 를 내므로 rc 로 가른다. `none`
  # 기록의 `donor` 는 보지 않는다.
  local f p out
  [ $# -ge 1 ] || return 2
  f="$1"
  case "$f" in
    /*) ;;
    *) printf '%s\n' '{"state":"corrupt"}'; return 0 ;;
  esac
  if [ -L "$f" ]; then
    printf '%s\n' '{"state":"corrupt"}'
    return 0
  fi
  if [ -e "$f" ]; then
    if [ ! -f "$f" ]; then
      printf '%s\n' '{"state":"corrupt"}'
      return 0
    fi
  else
    p="$f"
    while :; do
      p="${p%/*}"
      [ -n "$p" ] || p=/
      if [ -e "$p" ] || [ -L "$p" ] || [ "$p" = / ]; then break; fi
    done
    if [ -d "$p" ] && [ -x "$p" ]; then
      printf '%s\n' '{"state":"absent"}'
    else
      printf '%s\n' '{"state":"corrupt"}'
    fi
    return 0
  fi
  out=$(jq -c -s --arg schema "$ROUTE_BORROW_SCHEMA" "$(route__jq_lib)"' rt_borrow_read($schema)' "$f" 2>/dev/null) \
    || out='{"state":"corrupt"}'
  [ -n "$out" ] || out='{"state":"corrupt"}'
  printf '%s\n' "$out"
}

route__borrow_now() {
  # route__borrow_now — 지금 이 셸의 상태 루트에서 읽은 차용 기록. 경로를 유도할 수
  # 없으면 손상이다.
  local f
  if f=$(route__borrow_path); then
    route_borrow_read "$f"
  else
    printf '%s\n' '{"state":"corrupt"}'
  fi
}

route__borrow_read_main() {
  # borrow-read [<file>] — `{"state":S,"donor":<id|null>}` 한 줄과 rc 0. 인자가
  # 없으면 `route__borrow_path` 의 경로를 읽는다. `donor` 는 차용 중 세 상태에서만
  # 기증자 id 다.
  local r
  if [ $# -gt 1 ]; then
    printf '%s\n' 'usage: route.sh borrow-read [<file>]' >&2
    return 2
  fi
  if [ $# -eq 1 ]; then
    r=$(route_borrow_read "$1") || return 2
  else
    r=$(route__borrow_now) || return 2
  fi
  printf '%s' "$r" | jq -c "$(route__jq_lib)"' {state: .state, donor: (if rt_borrowing then .donor.id else null end)}'
}

route__frames_of_file() {
  # route__frames_of_file <log> — 로그 한 파일의 창별 마지막 판독. 최상위
  # `utilization`·`rateLimitType` 은 읽지 않는다. 관측 시각은 그 프레임 앞의 마지막
  # 타임스탬프 프레임의 것이고, 앞에 타임스탬프가 없는 프레임은 버린다. 파일
  # mtime 은 쓰지 않는다 — 살아 있는 스테이지의 로그는 프레임 뒤에도 자라서 미지여야
  # 할 창을 알려진 창으로 만든다.
  local f="${1:-}"
  if [ -z "$f" ] || [ ! -f "$f" ]; then
    printf '%s\n' '{"five_hour":null,"seven_day":null}'
    return 0
  fi
  jq -n -R -c "$(route__jq_lib)"' rt_frames_of_file' "$f" 2>/dev/null \
    || printf '%s\n' '{"five_hour":null,"seven_day":null}'
}

route__stage_ids_of() {
  # route__stage_ids_of <lineage> — 그 계보의 로그를 `stage_log_path` 에 물을 이름들.
  # 교대 계보 `shift#<n>` 의 로그는 드라이버가 `shift-<n>` 으로 부른다. 이 변환이
  # 사는 자리는 여기 하나다.
  case "${1:-}" in
    '') return 0 ;;
    'shift#'*) printf '%s\n' "shift-${1#shift#}" ;;
    *) printf '%s\n%s\n' "$1" "$1.retry" ;;
  esac
}

route_frames_read() {
  # route_frames_read <table> <run_id> — 이 런의 자기 임대 키에서 시작해 로그
  # 프레임을 그 임대의 계정에 귀속한 배열. 임대 없는 로그는 버린다 — 런의 좌석으로
  # 귀속하면 A 의 사용량이 B 에 붙고, 그것은 모르는 것보다 나쁘다. stale 임대도
  # 귀속에는 쓴다. 표는 락 없이 한 번 읽는다.
  local t="${1:-}" run="${2:-}" pfx f lin acct sid p fr out=""
  if [ -z "$run" ] || [ -z "${RUN_DIR:-}" ] || [ ! -d "$t" ]; then
    printf '[]\n'
    return 0
  fi
  pfx=$(route__enc "$run") || { printf '[]\n'; return 0; }
  for f in "$t/$pfx+"*.lease; do
    [ -f "$f" ] || continue
    lin=$(jq -r '.lineage // empty' "$f" 2>/dev/null) || continue
    acct=$(jq -r '.account // empty' "$f" 2>/dev/null) || continue
    if [ -z "$lin" ] || [ -z "$acct" ]; then continue; fi
    while IFS= read -r sid; do
      [ -n "$sid" ] || continue
      p=$(stage_log_path "$sid" 2>/dev/null) || continue
      [ -f "$p" ] || continue
      fr=$(route__frames_of_file "$p") || continue
      fr=$(printf '%s' "$fr" | jq -c --arg a "$acct" \
        '(.) as $r | ("five_hour", "seven_day") as $w | select(($r[$w] | type) == "object")
         | {account: $a, observed_at_epoch: $r[$w].observed_at_epoch, windows: {($w): {u: $r[$w].u, resets_at: $r[$w].resets_at}}}') || continue
      out=$(printf '%s\n%s' "$out" "$fr")
    done <<EOF
$(route__stage_ids_of "$lin")
EOF
  done
  printf '%s\n' "$out" | jq -s -c '.'
}

route__config_json() {
  # route__config_json <cap_bp|null> — 출하 상수를 값 그대로 옮긴 `config`.
  jq -cn \
    --argjson k5 "$ROUTE_K_FIVE_HOUR" --argjson k7 "$ROUTE_K_SEVEN_DAY" --argjson ks "$ROUTE_K_SHIFT" \
    --argjson c5 "$ROUTE_C_FIVE_HOUR" --argjson c7 "$ROUTE_C_SEVEN_DAY" \
    --argjson tl "$ROUTE_TTL_STAGE_LOG_S" --argjson tt "$ROUTE_TTL_TRACKER_S" \
    --argjson ff "$ROUTE_FILE_STALE_FACTOR" --argjson cap "${1:-null}" \
    --argjson ca "$ROUTE_COST_MAX_AGE_S" --argjson cn "$ROUTE_COST_MAX_N" --argjson cm "$ROUTE_COST_MIN_N" \
    --argjson f5 "$ROUTE_COST_FLOOR_FIVE_HOUR" --argjson f7 "$ROUTE_COST_FLOOR_SEVEN_DAY" \
    --argjson hf "$ROUTE_COST_HYG_MIN_FRAMES" --argjson hc "$ROUTE_COST_HYG_MIN_COVER" \
    '{k: {default: {five_hour: $k5, seven_day: $k7}, shift: {five_hour: $ks, seven_day: $ks}},
      c: {five_hour: {default: $c5, by_kind: {}, by_group: {}}, seven_day: {default: $c7, by_kind: {}, by_group: {}}},
      cost: {max_age_s: $ca, max_n: $cn, min_n: $cm, floor: {five_hour: $f5, seven_day: $f7},
             hygiene: {min_frames: $hf, min_cover: $hc}},
      cap_bp: $cap, ttl_s: {"stage-log": $tl, tracker: $tt}, file_stale_factor: $ff}'
}

route_cost_samples_read() {
  # route_cost_samples_read <dir> — 문맥 조립이 `--rawfile` 로 읽을 표본 파일의 경로.
  # 파일이 없으면 /dev/null 이고, 일반 파일이 아니거나 읽을 수 없거나
  # `ROUTE_COST_READ_MAX_BYTES` 를 넘으면 경고하고 /dev/null 이다. 디렉터리를 만들지
  # 않는다. 표본은 인자로 넘기지 않는다 — 상한까지 찬 저장소는 `ARG_MAX` 를 넘는다.
  local f="${1:-}/samples.jsonl" sz
  if [ ! -e "$f" ]; then
    printf '%s\n' /dev/null
    return 0
  fi
  if [ ! -f "$f" ] || [ ! -r "$f" ]; then
    route__warn "비용 표본을 읽을 수 없어 기본값으로 판정한다: $f"
    printf '%s\n' /dev/null
    return 0
  fi
  sz=$(wc -c < "$f" 2>/dev/null | tr -d '[:space:]')
  case "$sz" in
    ''|*[!0-9]*)
      route__warn "비용 표본의 크기를 읽을 수 없어 기본값으로 판정한다: $f"
      printf '%s\n' /dev/null
      return 0 ;;
  esac
  if [ "$sz" -gt "$ROUTE_COST_READ_MAX_BYTES" ]; then
    route__warn "비용 표본이 ${ROUTE_COST_READ_MAX_BYTES} 바이트를 넘어 기본값으로 판정한다: $f (${sz})"
    printf '%s\n' /dev/null
    return 0
  fi
  printf '%s\n' "$f"
}

route_cost_table() {
  # 표준 입력의 문맥 하나 → 그 문맥으로 계산한 비용 표. 칸마다 값·표본 수·가장
  # 오래된 `t_end` 를 낸다.
  jq -c "$(route__jq_lib)"' rt_cost_table(.)' || return 2
}

route_gather_context() {
  # route_gather_context <request-json> <seat-config-dir> — 활성 경로의 문맥.
  # 좌석 디렉터리는 호출자가 이미 얻은 `resolve_account` 의 답이다 — 해석기를
  # 다시 부르지 않는다. 5시간 상한은 호출 시점의 `RUN_PACE_SESSION_WINDOW_PCT_MAX`
  # 에서 bp 로 옮긴다. 그 변수가 없는 셸에서는 null 이 되고 결정은 rc 2 로 닫힌다.
  # 비용 표본은 원문 그대로 `cost_samples` 에 싣고, 저장소 때문에 rc 2 로 닫지 않는다.
  local req="${1:-}" seat="${2:-}" now inv irc=0 inventory usage table leases frames run_id cap cfg bpath borrow bpj
  local costs prog out
  now=$(date -u +%s) || return 2
  printf '%s' "$req" | jq -e 'type == "object"' >/dev/null 2>&1 || return 2
  inv="${RUN_DIR:-}/inventory.json"
  if [ -n "${RUN_DIR:-}" ]; then
    route_inventory_check "$inv" 2>/dev/null || irc=$?
  else
    irc=2
  fi
  case "$irc" in
    0) inventory=$(jq -c '{state: "valid", accounts: .accounts}' "$inv") || return 2 ;;
    1) inventory='{"state":"corrupt","accounts":[]}' ;;
    *) inventory='{"state":"absent","accounts":[]}' ;;
  esac
  usage=$(route_usage_read "${XDG_STATE_HOME:-$HOME/.local/state}/cc-lane/usage.json" "$now") || return 2
  # 차용 기록과 그 경로. 경로는 `lease-txn` 의 잠금 아래 재판독이 같은 파일을 보도록
  # 문맥으로 넘긴다 — 그 프로세스가 자기 환경으로 다시 계산하면 다른 파일을 볼 수 있다.
  if bpath=$(route__borrow_path); then
    borrow=$(route_borrow_read "$bpath") || return 2
    bpj=$(jq -cn --arg p "$bpath" '$p') || return 2
  else
    borrow='{"state":"corrupt"}'
    bpj=null
  fi
  table="$(run_pace_root)/leases"
  leases=$(route__table_read "$table" "$(boot_epoch 2>/dev/null || true)") || return 2
  run_id=$(printf '%s' "$req" | jq -r '.run_id // ""') || return 2
  frames=$(route_frames_read "$table" "$run_id") || return 2
  case "${RUN_PACE_SESSION_WINDOW_PCT_MAX:-}" in
    ''|*[!0-9]*) cap=null ;;
    *) cap=$((RUN_PACE_SESSION_WINDOW_PCT_MAX * 100)) ;;
  esac
  cfg=$(route__config_json "$cap") || return 2
  costs=$(route_cost_samples_read "$(run_pace_root)/costs")
  prog='{now: $now, request: $req, inventory: $inv, usage: $usage, frames: $frames, leases: $leases,
      sticky: ([$leases.items[] | select(.run_id == $req.run_id and .kind == "grant" and .live == true) | .account] | unique),
      seat: {config_dir: $seat}, config: $cfg, deadline: ($req.deadline // null),
      borrow: $borrow, borrow_path: $bp, cost_samples: $cost_samples}'
  set -- --argjson now "$now" --argjson req "$req" --argjson inv "$inventory" --argjson usage "$usage" \
    --argjson leases "$leases" --argjson frames "$frames" --argjson cfg "$cfg" --arg seat "$seat" \
    --argjson borrow "$borrow" --argjson bp "$bpj"
  # 판독 사이에 파일이 사라지거나 바뀌어 읽기가 실패하면 표본 없이 한 번 더 조립한다.
  if ! out=$(jq -cn "$@" --rawfile cost_samples "$costs" "$prog" 2>/dev/null); then
    [ "$costs" = /dev/null ] && return 2
    route__warn "비용 표본을 읽지 못해 기본값으로 판정한다: $costs"
    out=$(jq -cn "$@" --rawfile cost_samples /dev/null "$prog") || return 2
  fi
  printf '%s\n' "$out"
}

# ---------------------------------------------------------------------------
# 기기 임대 표. 파일 하나가 계보 하나다: `<enc(run_id)>+<enc(lineage)>.lease`.
# 임시 이름 `.<key>.lease.tmp.<pid>` 는 점 파일이라 목록 글롭에 오르지 않고 결코
# `.lease` 로 끝나지 않는다 — cc-lane 이 이 표를 읽기 전용으로 보므로 계약의
# 일부다. 목록은 셸 글롭이지 `find` 가 아니다. `find -name` 은 점 파일도 나열한다.
# ---------------------------------------------------------------------------
route__fp() { TZ=UTC0 cc_proc_fingerprint "$1"; }

route__alive() {
  # route__alive <pid> <recorded-fp> — 네 갈래. 지금 지문이 있고 기록과 같으면 산다
  # (남의 사용자 프로세스에서 `kill -0` 이 EPERM 으로 실패해도). 있고 다르면 pid
  # 재사용이라 죽음. 지문을 못 읽었으면 `kill -0` 이 판정한다 — 모르는 것은 센다.
  local now_fp
  now_fp=$(route__fp "$1")
  if [ -n "$now_fp" ]; then
    [ "$now_fp" = "${2:-}" ]
    return
  fi
  kill -0 "$1" 2>/dev/null
}

route__nonce() { od -An -N16 -tx1 /dev/urandom | tr -d ' \n'; }

route__dir_mtime() {
  # 디렉터리의 mtime. `cc_mtime` 은 파일 전용이라 디렉터리에 빈 값을 낸다.
  [ -e "${1:-}" ] || return 0
  date -u -r "$1" +%s 2>/dev/null || true
}

route__holders_json() {
  # route__holders_json <pid>... — 보유자 배열. 자기 `$$`, 살아 있지 않은 pid,
  # 지문을 읽을 수 없는 pid 는 거부한다(rc 2). 보유자는 명시적으로만 들어온다.
  local p fp one out="" sep=""
  for p in "$@"; do
    case "$p" in
      ''|0|*[!0-9]*) return 2 ;;
    esac
    [ "$p" != "$$" ] || return 2
    fp=$(route__fp "$p")
    [ -n "$fp" ] || return 2
    one=$(jq -cn --argjson pid "$p" --arg fp "$fp" '{pid: $pid, fp: $fp}') || return 2
    out="${out}${sep}${one}"
    sep=","
  done
  [ -n "$sep" ] || return 2
  printf '[%s]\n' "$out"
}

route__lock_try_break() {
  # rc 0 이면 락이 없어졌거나 깼다. 소유자가 죽었을 때만 깬다 — 나이로 깨면 잠든
  # 기기에서 깨어난 뒤 살아 있는 락을 깬다. `rm -rf` 직전에 소유자 기록을 다시 읽어
  # 바뀌지 않았을 때만 지운다. 기록이 없는 락(획득 도중의 창)은 살아 있는 것으로
  # 보되 오래되면 깬다.
  local lk="$1" o="$1/owner" rec rec2 pid fp mt now
  if [ -f "$o" ]; then
    rec=$(cat "$o" 2>/dev/null) || return 1
    pid=$(printf '%s\n' "$rec" | sed -n '1p')
    fp=$(printf '%s\n' "$rec" | sed -n '2p')
    case "$pid" in
      ''|*[!0-9]*) ;;
      *)
        if [ -n "$fp" ]; then
          route__alive "$pid" "$fp" && return 1
        else
          kill -0 "$pid" 2>/dev/null && return 1
        fi
        rec2=$(cat "$o" 2>/dev/null) || return 1
        [ "$rec" = "$rec2" ] || return 1
        rm -rf "$lk"
        return 0 ;;
    esac
  fi
  [ -e "$lk" ] || return 0
  mt=$(route__dir_mtime "$lk")
  [ -n "$mt" ] || return 1
  now=$(date -u +%s)
  [ $((now - mt)) -gt "$ROUTE_LEASE_LOCK_ORPHAN_S" ] || return 1
  if [ -f "$o" ]; then
    rec2=$(cat "$o" 2>/dev/null) || return 1
    [ "${rec:-}" = "$rec2" ] || return 1
  fi
  rm -rf "$lk"
  return 0
}

route__lock_acquire() {
  # route__lock_acquire <table> — rc 0 쥠 / 3 대기 초과 / 4 표에 락을 만들 수 없음.
  # 소유자는 이 프로세스의 `$$` 다 — 명령 치환 안에서 잡으면 드라이버가 소유자로
  # 적혀, 치환이 죽어도 락이 살아 있는 것처럼 남는다. trap 은 쥔 경우에만 놓는다.
  # 락이 없는데 `mkdir` 이 실패하면 기다려도 풀리지 않으므로 곧바로 rc 4 다. 깨기가
  # 성공한 뒤에도 예산을 다시 본다 — 깨기와 재획득이 계속 엇갈려도 끝이 있어야 한다.
  local lk="$1/.lock" start now
  start=$(date -u +%s)
  while :; do
    now=$(date -u +%s)
    [ $((now - start)) -lt "$ROUTE_LEASE_LOCK_WAIT_S" ] || return 3
    if mkdir "$lk" 2>/dev/null; then
      if printf '%s\n%s\n' "$$" "$(route__fp "$$")" > "$lk/owner.tmp.$$" 2>/dev/null; then
        mv -f "$lk/owner.tmp.$$" "$lk/owner" 2>/dev/null || rm -f "$lk/owner.tmp.$$" 2>/dev/null
      fi
      ROUTE_LOCK_DIR="$lk"
      trap 'route__lock_release' EXIT
      trap 'route__lock_release; exit 130' INT
      trap 'route__lock_release; exit 143' TERM
      return 0
    fi
    if [ ! -e "$lk" ] && [ ! -w "$1" ]; then
      return 4
    fi
    if route__lock_try_break "$lk"; then
      continue
    fi
    sleep 1
  done
}

route__lock_release() {
  local lk="${ROUTE_LOCK_DIR:-}" pid
  [ -n "$lk" ] || return 0
  ROUTE_LOCK_DIR=""
  trap - EXIT INT TERM
  pid=$(sed -n '1p' "$lk/owner" 2>/dev/null) || pid=""
  if [ "$pid" = "$$" ]; then
    rm -rf "$lk"
  fi
  return 0
}

route__table_read() {
  # route__table_read <table> <boot-epoch> — 표의 판독: `state`(absent|valid|corrupt),
  # 생존이 붙은 `items`, `corrupt`, `stale_corrupt`. 목록과 판독 사이에 사라진 파일은
  # 반납으로 읽는다. 파싱되지 않는 파일 중 mtime 이 부팅 시각보다 이른 것은
  # stale-깨짐이다 — 그 보유자는 부팅과 함께 모두 죽었으니 예약을 알 수 없는 것이
  # 아니라 살아 있지 않은 것이다. 부팅 시각이 빈 값이면 건너뛰기가 없다.
  local t="${1:-}" boot="${2:-}" f raw parsed p mt k lines i pid fp stale="" bad="" live="" tab
  local files=()
  tab=$(printf '\t')
  case "$boot" in
    *[!0-9]*) boot="" ;;
  esac
  if [ ! -e "$t" ] && [ ! -L "$t" ]; then
    printf '%s\n' '{"state":"absent","items":[],"corrupt":[],"stale_corrupt":[]}'
    return 0
  fi
  if [ ! -d "$t" ] || [ ! -r "$t" ] || [ ! -x "$t" ]; then
    jq -cn --arg p "$t" '{state: "corrupt", items: [], corrupt: [{path: $p, key: null, why: "unlistable"}], stale_corrupt: []}'
    return 0
  fi
  for f in "$t"/*.lease; do
    if [ -e "$f" ] || [ -L "$f" ]; then
      files+=("$f")
    fi
  done
  route__hook_listed "$t"
  if [ "${#files[@]}" -eq 0 ]; then
    printf '%s\n' '{"state":"absent","items":[],"corrupt":[],"stale_corrupt":[]}'
    return 0
  fi
  raw=$(jq -n -R -c 'reduce inputs as $l ({}; .[input_filename] += [$l])' "${files[@]}" 2>/dev/null) || true
  [ -n "$raw" ] || raw='{}'
  parsed=$(jq -cn --argjson raw "$raw" --arg schema "$ROUTE_LEASE_SCHEMA" \
           "$(route__jq_lib)"' rt_parse_table($raw; $ARGS.positional; $schema)' --args "${files[@]}") || return 2
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    if [ ! -e "$p" ] && [ ! -L "$p" ]; then continue; fi
    mt=$(cc_mtime "$p")
    if [ -n "$boot" ] && [ -n "$mt" ] && [ "$mt" -lt "$boot" ]; then
      stale=$(printf '%s\n%s' "$stale" "$p")
    else
      bad=$(printf '%s\n%s' "$bad" "$p")
    fi
  done <<EOF
$(printf '%s' "$parsed" | jq -r '.unparsed[]')
EOF
  lines=$(printf '%s' "$parsed" | jq -r '.items | to_entries[] | .key as $i | .value.holders[] | "\($i)\t\(.pid)\t\(.fp)"') || return 2
  while IFS="$tab" read -r i pid fp; do
    [ -n "$i" ] || continue
    case " $live " in
      *" $i "*) continue ;;
    esac
    if route__alive "$pid" "$fp"; then
      live="$live $i"
    fi
  done <<EOF
$lines
EOF
  k=$(printf '%s' "$live" | tr ' ' '\n')
  jq -cn --argjson parsed "$parsed" --arg stale "$stale" --arg bad "$bad" --arg live "$k" \
    "$(route__jq_lib)"' rt_table_final($parsed; $stale; $bad; $live)'
}

route__lease_read() {
  # route__lease_read <file> <key> — 유효한 기록이면 그 JSON, 아니면 rc 1.
  [ -f "${1:-}" ] || return 1
  jq -c -e --arg key "$2" --arg schema "$ROUTE_LEASE_SCHEMA" \
    "$(route__jq_lib)"' if rt_lease_why($key; $schema) == null then . else error("invalid") end' "$1" 2>/dev/null
}

route__lease_is_live() {
  # route__lease_is_live <record-json> — 보유자 하나라도 살아 있으면 산다.
  local lines pid fp tab
  tab=$(printf '\t')
  lines=$(printf '%s' "$1" | jq -r '.holders[] | "\(.pid)\t\(.fp)"') || return 1
  while IFS="$tab" read -r pid fp; do
    [ -n "$pid" ] || continue
    if route__alive "$pid" "$fp"; then return 0; fi
  done <<EOF
$lines
EOF
  return 1
}

route__lease_put() {
  # route__lease_put <table> <key> <record-json> — 임시 파일에 쓰고 판독자와 같은
  # 스키마 검사를 통과한 뒤에만 `mv -f` 로 제자리에 옮긴다. 제자리 `> file` 은 락을
  # 잡지 않는 판독자에게 잘린 창을 보인다. 실패하면 임시 파일을 지우고 rc 4.
  local t="$1" key="$2" tmp="$1/.$2.lease.tmp.$$"
  if ! printf '%s\n' "$3" > "$tmp" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null
    return 4
  fi
  if ! jq -e --arg key "$key" --arg schema "$ROUTE_LEASE_SCHEMA" \
       "$(route__jq_lib)"' rt_lease_why($key; $schema) == null' "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp" 2>/dev/null
    return 4
  fi
  if ! mv -f "$tmp" "$t/$key.lease" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null
    return 4
  fi
  return 0
}

route__lease_cmp_delete() {
  # route__lease_cmp_delete <file> <nonce> [kind] — nonce 가 같을 때만 지운다.
  # 없거나 다르면 성공한 무동작이다.
  local n k
  [ -f "${1:-}" ] || return 0
  n=$(jq -r '.nonce // empty' "$1" 2>/dev/null) || return 0
  [ -n "$n" ] && [ "$n" = "${2:-}" ] || return 0
  if [ -n "${3:-}" ]; then
    k=$(jq -r '.kind // empty' "$1" 2>/dev/null) || return 0
    [ "$k" = "$3" ] || return 0
  fi
  rm -f "$1"
  return 0
}

route__decide_with() {
  # route__decide_with <ctx-json> <leases-json> — 표를 끼운 문맥으로 순수 결정.
  printf '%s' "$1" | jq -c --argjson leases "$2" --arg schema "$ROUTE_LEASE_SCHEMA" \
    "$(route__jq_lib)"' .leases = $leases | rt_decide($schema)'
}

route__revalidate() {
  # route__revalidate <ctx-json> <leases-json> <record-json> — 쓴 뒤 다시 읽은 표에서
  # 자기 항목을 포함한 합이 부등식과 미지 그룹 상한을 지키는지. rc 0 지킴 / 1 어김 /
  # 2 판정 불가. 락 소유자 하나가 죽어 두 깨기 주체가 겨루면 락 두 개가 동시에
  # 쥐어질 수 있고, 그때 과다 입장을 닫는 것이 이 판정이다.
  local r
  r=$(printf '%s' "$1" | jq -c --argjson leases "$2" --argjson rec "$3" --arg schema "$ROUTE_LEASE_SCHEMA" \
      "$(route__jq_lib)"' .leases = $leases | rt_revalidate($schema; $rec)') || return 2
  [ "$r" = "true" ] && return 0
  return 1
}

route__txn_fallback() {
  # route__txn_fallback <ctx-json> <reason> <record-json|null> — 거래가 결정을 끝까지
  # 가져가지 못했을 때의 봉투. 교대는 좌석으로 떨어진다 — 교대는 기다리지 않는다.
  printf '%s' "$1" | jq -c --arg reason "$2" --argjson rec "${3:-null}" \
    "$(route__jq_lib)"' rt_txn_fallback($reason; $rec)'
}

route__emit() { printf '%s' "$1" | jq -c 'del(.txn)'; }

route__txn_undo() {
  # route__txn_undo <table> <key> <prior-json|''> <record-json> — 차용 때문에 방금 쓴
  # 임대를 되돌린다. 잠금 아래 판독에서 그 키에 살아 있던 자기 기록이 있으면 그것을
  # 되쓴다 — 쓴 기록이 이전 nonce 를 지닐 수 있어 nonce 로 지우면 아직 도는 이전
  # 보유자의 울타리까지 지운다. 없으면 쓴 기록의 nonce 로 지운다. 되쓰기가 실패하면
  # rc 4 이고 쓴 파일은 그대로 둔다 — 지우면 살아 있는 이전 보유자의 울타리가 사라진다.
  if [ -n "$3" ]; then
    route__lease_put "$1" "$2" "$3" || return 4
    return 0
  fi
  route__lease_cmp_delete "$1/$2.lease" "$(printf '%s' "$4" | jq -r '.nonce')"
}

route__txn_main() {
  # lease-txn --table <dir> --now <n> --boot-epoch <n|''> --holder <pid>...
  # 표준 입력의 문맥 → 표준 출력의 봉투. 락 아래에서 표를 다시 읽고 결정한다.
  # 모든 임대 쓰기(보유 포함) 뒤에는 문맥의 `borrow_path` 에서 차용 기록을 디스크로
  # 다시 읽는다 — cc-lane 은 intent 를 쓴 뒤 이 표를 읽으므로, 둘 중 하나는 반드시
  # 상대를 본다. 쓴 임대가 기증자 계정이거나 기증자 디렉터리이면 되돌리고 경합으로
  # 물러서고, 새로 놓는 쓰기가 손상 기록을 보면 되돌리고 PARK 한다. 되돌리기는 잠금
  # 아래 판독에서 살아 있던 자기 기록의 복원이 먼저이고, 없을 때만 nonce 로 지운다.
  # 예산을 더하는 쓰기(새 부여, 재부여, 살아 있지 않은 자기 임대 위의 재입장,
  # 호출자가 아직 받지 못한 기존 임대의 멱등 반환)는 그 뒤 표를 다시 읽어 재검증하고,
  # 어기면 자기 항목을 nonce 로 지운 뒤 WAIT 를 낸다. 타이브레이크는 두지 않는다 —
  # 어긴 집합을 본 재검증자가 자기를 철회하는 규칙만이 이중 보유에서도 안전하다.
  # 표 디렉터리가 없으면 락 없이 빈 표로 결정하고, 쓰기가 필요할 때만 만든 뒤 락
  # 아래에서 다시 결정한다.
  local table="" now="" boot="" ctx holders nonce out op rec key rc leases absent bpath prior bnew bv ctx2 urc
  local hs=()
  absent='{"state":"absent","items":[],"corrupt":[],"stale_corrupt":[]}'
  while [ $# -gt 0 ]; do
    [ $# -ge 2 ] || return 2
    case "$1" in
      --table) table="$2" ;;
      --now) now="$2" ;;
      --boot-epoch) boot="$2" ;;
      --holder) hs+=("$2") ;;
      *) return 2 ;;
    esac
    shift 2
  done
  [ -n "$table" ] || return 2
  case "$now" in
    ''|*[!0-9]*) return 2 ;;
  esac
  case "$boot" in
    *[!0-9]*) return 2 ;;
  esac
  ctx=$(cat) || return 2
  holders=$(route__holders_json ${hs[@]+"${hs[@]}"}) || return 2
  nonce=$(route__nonce)
  [ -n "$nonce" ] || return 4
  # `borrow_path` 는 키가 있어야 하고 `null` 이거나 절대 경로 문자열이다. 이 검사는
  # 표 부재 갈래보다 앞이라 두 갈래 모두에 걸린다.
  ctx=$(printf '%s' "$ctx" | jq -c --argjson now "$now" --argjson h "$holders" --arg n "$nonce" \
        'if type == "object" and has("borrow_path")
            and ((.borrow_path == null) or (((.borrow_path | type) == "string") and (.borrow_path | startswith("/"))))
         then (.now = $now | .request.holders = $h | .fresh_nonce = $n) else error("ctx") end') || return 2
  bpath=$(printf '%s' "$ctx" | jq -j '.borrow_path // empty') || return 2

  if [ ! -e "$table" ] && [ ! -L "$table" ]; then
    out=$(route__decide_with "$ctx" "$absent") || return 2
    op=$(printf '%s' "$out" | jq -r '.txn.op')
    if [ "$op" = "none" ]; then
      route__emit "$out"
      return 0
    fi
    mkdir -p "$table" 2>/dev/null || return 4
  fi

  rc=0
  route__lock_acquire "$table" || rc=$?
  if [ "$rc" != "0" ]; then
    [ "$rc" = "3" ] || return "$rc"
    route__txn_fallback "$ctx" "lease-lock-busy" null
    return 0
  fi
  route__hook_locked "$table"
  leases=$(route__table_read "$table" "$boot") || { route__lock_release; return 2; }
  out=$(route__decide_with "$ctx" "$leases") || { route__lock_release; return 2; }
  route__hook_decided "$table"
  op=$(printf '%s' "$out" | jq -r '.txn.op') || { route__lock_release; return 2; }
  case "$op" in
    none) ;;
    hold|write)
      rec=$(printf '%s' "$out" | jq -c '.txn.record') || { route__lock_release; return 2; }
      key=$(printf '%s' "$out" | jq -r '.lease_key') || { route__lock_release; return 2; }
      # 복원 원본: 잠금 아래 판독에서 이 키의 파일이고 살아 있던 자기 기록. nonce 로
      # 고르지 않는다 — 새로 놓는 재부여가 살아 있는 자기 임대를 덮는 경우를 놓친다.
      prior=$(printf '%s' "$ctx" | jq -c --argjson leases "$leases" --arg path "$table/$key.lease" \
              '.request as $r
               | [($leases.items // [])[] | select((.run_id == $r.run_id) and (.lineage == $r.lineage))
                  | select((.live == true) and (.path == $path))] | .[0]
               | if . == null then empty else del(.live, .path) end') || { route__lock_release; return 2; }
      if ! route__lease_put "$table" "$key" "$rec"; then
        route__lock_release
        return 4
      fi
      route__hook_written "$table"
      # 차용 재판독. 판정은 위에서부터: 새로 놓는 쓰기의 손상 > 기증자 적중 > 진행.
      # 이어 가는 쓰기(보유, 멱등 재부여)는 손상에서도 진행한다.
      bv=""
      if [ -n "$bpath" ]; then
        bnew=$(route_borrow_read "$bpath") || bv=fail
      else
        bnew='{"state":"corrupt"}'
      fi
      if [ -z "$bv" ]; then
        ctx2=$(printf '%s' "$ctx" | jq -c --argjson b "$bnew" '.borrow = $b') || bv=fail
      fi
      if [ -z "$bv" ]; then
        bv=$(printf '%s' "$ctx2" | jq -r --argjson rec "$rec" "$(route__jq_lib)"'
              .borrow as $b
              | if $b.state == "corrupt" then (if $rec.nonce == .fresh_nonce then "corrupt" else "go" end)
                elif ($b | rt_borrowing) and (($rec.account == $b.donor.id) or ($rec.config_dir == $b.donor.config_dir)) then "hit"
                else "go" end') || bv=fail
      fi
      if [ "$bv" != "go" ]; then
        urc=0
        route__txn_undo "$table" "$key" "$prior" "$rec" || urc=$?
        route__lock_release
        [ "$urc" = "0" ] || return 4
        case "$bv" in
          corrupt) route__txn_fallback "$ctx2" "borrow-record-corrupt" "$rec" ;;
          hit) route__txn_fallback "$ctx2" "lease-contention" "$rec" ;;
          *) return 2 ;;
        esac
        return
      fi
      if [ "$op" = "write" ]; then
        rc=0
        leases=$(route__table_read "$table" "$boot") || rc=2
        route__hook_revalidate "$table"
        if [ "$rc" = "0" ]; then
          route__revalidate "$ctx" "$leases" "$rec" || rc=$?
        fi
        if [ "$rc" != "0" ]; then
          route__lease_cmp_delete "$table/$key.lease" "$(printf '%s' "$rec" | jq -r '.nonce')"
          route__lock_release
          [ "$rc" = "1" ] || return 2
          route__txn_fallback "$ctx2" "lease-contention" "$rec"
          return 0
        fi
      fi ;;
    *)
      route__lock_release
      return 2 ;;
  esac
  route__lock_release
  route__emit "$out"
}

route__hold_main() {
  # lease-hold <table> <run_id> <lineage> <nonce> <pid> — 락 아래 nonce 비교 뒤
  # 보유자를 더한다. rc 0 더함 / 1 없음·nonce 불일치·깨짐 / 5 stale / 2 인자·보유자
  # 거부 / 3 락 대기 초과 / 4 쓰기 실패. stale 임대는 되살리지 않는다 — 합에서 빠진
  # 예약이 입장 없이 돌아오면 안 된다. 호출자는 다시 입장한다.
  local t="${1:-}" key f rec h rc=0
  [ $# -eq 5 ] || return 2
  [ -n "$4" ] || return 2
  key=$(route__key "$2" "$3") || return 2
  h=$(route__holders_json "$5") || return 2
  [ -d "$t" ] || return 1
  route__lock_acquire "$t" || return $?
  f="$t/$key.lease"
  rec=$(route__lease_read "$f" "$key") || { route__lock_release; return 1; }
  if [ "$(printf '%s' "$rec" | jq -r '.nonce')" != "$4" ]; then
    route__lock_release
    return 1
  fi
  if ! route__lease_is_live "$rec"; then
    route__lock_release
    return 5
  fi
  rec=$(printf '%s' "$rec" | jq -c --argjson h "$h" '.holders = ((.holders + $h) | unique_by(.pid))') || rc=2
  if [ "$rc" = "0" ] && ! route__lease_put "$t" "$key" "$rec"; then rc=4; fi
  route__lock_release
  [ "$rc" = "0" ] || return "$rc"
  printf '%s\n' "$rec"
}

route__release_main() {
  # lease-release <table> <run_id> <lineage> <nonce> — 락 아래 nonce 비교 삭제.
  local key
  [ $# -eq 4 ] || return 2
  key=$(route__key "$2" "$3") || return 2
  [ -d "$1" ] || return 0
  route__lock_acquire "$1" || return $?
  route__lease_cmp_delete "$1/$key.lease" "$4"
  route__lock_release
  return 0
}

route__release_run_main() {
  # lease-release-run <table> <run_id> — 런 스코프 park·중단에서 그 런의 임대 전부.
  # `enc(run_id)` 에는 날 `+` 가 없으므로 `<enc>+` 접두는 그 런의 키만 맞는다.
  local pfx f
  [ $# -eq 2 ] || return 2
  case "$2" in
    ''|.*) return 2 ;;
  esac
  pfx=$(route__enc "$2") || return 2
  [ -d "$1" ] || return 0
  route__lock_acquire "$1" || return $?
  for f in "$1/$pfx+"*.lease; do
    if [ -e "$f" ] || [ -L "$f" ]; then rm -f "$f"; fi
  done
  route__lock_release
  return 0
}

route__wait_put_main() {
  # lease-wait-put --table <dir> --now <n> --run-id <r> --lineage <l> --account <id>
  #                --config-dir <dir> --holder <pid>...
  # 락 아래에서 `kind: wait` 항목을 쓴다. `seq` 는 표 안 최댓값 + 1 이고, 같은 키의
  # 대기 항목이 이미 있으면 그 자리를 지킨다. 예약은 싣지 않는다. 같은 키에 부여가
  # 있으면 거부한다(rc 1).
  #
  # `--group <g> --inventory <file>` 은 `--account`·`--config-dir` 대신 그룹의 대표
  # 계정을 고른다 — 그 인벤토리에서 새 부여를 받을 수 있는(`enabled`) 계정 중 그
  # 그룹에 드는 가장 작은 id. WAIT 봉투는 조직 그룹이면 계정을 싣지 않으므로, 항목이
  # 그룹으로 세어지려면 그 그룹에 속한 계정 하나가 있어야 한다. 고를 계정이 없으면
  # rc 3 이고 아무것도 쓰지 않는다.
  local t="" now="" run="" lin="" acct="" dir="" grp="" invf="" key holders nonce leases rec rc=0 usage pick
  local hs=()
  while [ $# -gt 0 ]; do
    [ $# -ge 2 ] || return 2
    case "$1" in
      --table) t="$2" ;;
      --now) now="$2" ;;
      --run-id) run="$2" ;;
      --lineage) lin="$2" ;;
      --account) acct="$2" ;;
      --config-dir) dir="$2" ;;
      --group) grp="$2" ;;
      --inventory) invf="$2" ;;
      --holder) hs+=("$2") ;;
      *) return 2 ;;
    esac
    shift 2
  done
  case "$now" in
    ''|*[!0-9]*) return 2 ;;
  esac
  if [ -n "$grp" ]; then
    [ -z "$acct" ] && [ -z "$dir" ] && [ -n "$invf" ] || return 2
    route_inventory_check "$invf" >/dev/null 2>&1 || return 3
    usage=$(route_usage_read "${XDG_STATE_HOME:-$HOME/.local/state}/cc-lane/usage.json" "$now") || return 2
    pick=$(jq -r --argjson usage "$usage" --arg g "$grp" "$(route__jq_lib)"'
             rt_orgs({usage: $usage}) as $o
             | [(.accounts // [])[] | select(.unattended == "enabled") | select(rt_group_of($o; .id) == $g)]
             | sort_by(.id) | .[0] // empty | "\(.id)\t\(.config_dir)"' "$invf" 2>/dev/null) || return 2
    [ -n "$pick" ] || return 3
    acct=${pick%%"$(printf '\t')"*}
    dir=${pick#*"$(printf '\t')"}
  fi
  if [ -z "$t" ] || [ -z "$acct" ] || [ -z "$dir" ]; then return 2; fi
  key=$(route__key "$run" "$lin") || return 2
  holders=$(route__holders_json ${hs[@]+"${hs[@]}"}) || return 2
  nonce=$(route__nonce)
  [ -n "$nonce" ] || return 4
  mkdir -p "$t" 2>/dev/null || return 4
  route__lock_acquire "$t" || return $?
  leases=$(route__table_read "$t" "") || rc=2
  if [ "$rc" = "0" ]; then
    rec=$(jq -cn --argjson leases "$leases" --arg run "$run" --arg lin "$lin" --arg acct "$acct" --arg dir "$dir" \
          --arg nonce "$nonce" --argjson now "$now" --argjson holders "$holders" --arg schema "$ROUTE_LEASE_SCHEMA" \
          "$(route__jq_lib)"' rt_wait_record($leases; $run; $lin; $acct; $dir; $nonce; $now; $holders; $schema)' 2>/dev/null) || rc=1
  fi
  if [ "$rc" = "0" ] && ! route__lease_put "$t" "$key" "$rec"; then rc=4; fi
  route__lock_release
  [ "$rc" = "0" ] || return "$rc"
  printf '%s\n' "$rec"
}

route__wait_drop_main() {
  # lease-wait-drop <table> <run_id> <lineage> <nonce> — 대기 항목만 nonce 비교 삭제.
  local key
  [ $# -eq 4 ] || return 2
  key=$(route__key "$2" "$3") || return 2
  [ -d "$1" ] || return 0
  route__lock_acquire "$1" || return $?
  route__lease_cmp_delete "$1/$key.lease" "$4" wait
  route__lock_release
  return 0
}

route__cost_put_main() {
  # cost-sample-put <costs-dir> --run-id <r> --lineage <l> --kind <k> --account <id> --log <file>
  # 스테이지 로그 한 파일을 요약해 저장소에 한 줄을 쓴다. 단독 프로세스라 저장소
  # 위치를 첫 인자로 받는다. 닫힌 여섯 부류 밖의 부류와 구간을 정할 수 없는 로그는
  # 쓰지 않고 rc 0 이다. 디렉터리가 없으면 그것만 만든다. 락을 못 잡으면 표본을 버리고
  # 그 rc 다. 로그는 락 밖에서 읽는다 — 수백 MB 로그를 읽는 동안 다른 작성기를 막지
  # 않는다.
  local d="${1:-}" run="" lin="" kind="" acct="" log="" line now rc=0 src tmp
  [ $# -ge 1 ] || return 2
  shift
  while [ $# -gt 0 ]; do
    [ $# -ge 2 ] || return 2
    case "$1" in
      --run-id) run="$2" ;;
      --lineage) lin="$2" ;;
      --kind) kind="$2" ;;
      --account) acct="$2" ;;
      --log) log="$2" ;;
      *) return 2 ;;
    esac
    shift 2
  done
  if [ -z "$d" ] || [ -z "$run" ] || [ -z "$lin" ] || [ -z "$log" ]; then return 2; fi
  jq -en --arg k "$kind" "$(route__jq_lib)"' any(rt_cost_kinds[]; . == $k)' >/dev/null 2>&1 || return 0
  jq -en --arg a "$acct" "$(route__jq_lib)"' $a | rt_cost_acct_ok' >/dev/null 2>&1 || return 2
  [ -f "$log" ] || return 2
  now=$(date -u +%s)
  line=$(jq -n -R -c --arg run "$run" --arg lin "$lin" --arg log "$(basename "$log")" --arg kind "$kind" --arg acct "$acct" \
         --arg schema "$ROUTE_COST_SCHEMA" "$(route__jq_lib)"' rt_cost_of_log | rt_cost_line($run; $lin; $log; $kind; $acct; $schema)' \
         "$log" 2>/dev/null) || return 2
  [ -n "$line" ] || return 2
  [ "$line" != "null" ] || return 0
  if [ ! -d "$d" ]; then
    mkdir "$d" 2>/dev/null || [ -d "$d" ] || return 4
  fi
  route__lock_acquire "$d" || {
    rc=$?
    route__warn "비용 표본 락을 잡지 못해 표본을 버린다 ($d, rc=$rc)"
    return "$rc"
  }
  src="$d/samples.jsonl"
  [ -f "$src" ] || src=/dev/null
  tmp="$d/.samples.jsonl.tmp.$$"
  if jq -n -R -c --argjson new "$line" --argjson now "$now" --argjson ks "$ROUTE_COST_KEEP_S" \
       --argjson kn "$ROUTE_COST_KEEP_LINES" --arg schema "$ROUTE_COST_SCHEMA" \
       "$(route__jq_lib)"' rt_cost_store($new; $now; $ks; $kn; $schema)' "$src" > "$tmp" 2>/dev/null \
     && mv -f "$tmp" "$d/samples.jsonl" 2>/dev/null; then
    rc=0
  else
    rm -f "$tmp" 2>/dev/null
    rc=4
  fi
  route__lock_release
  return "$rc"
}

route_lease_of() {
  # route_lease_of <table> <run_id> <lineage> — 그 계보의 임대 JSON, 없으면 빈 값.
  # 깨진 기록은 빈 값과 rc 1 이다. 읽기만 하므로 락도 자기 프로세스도 필요 없다.
  local key
  [ $# -eq 3 ] || return 2
  key=$(route__key "$2" "$3") || return 2
  [ -e "$1/$key.lease" ] || return 0
  route__lease_read "$1/$key.lease" "$key" || return 1
}

# 임대를 바꾸는 API 는 모두 자기 프로세스로 돈다. 명령 치환 안에서 bash 3.2 의
# `$$` 는 부모의 pid 이고, 프로세스 안에서 락을 잡으면 드라이버가 소유자로 적힌다.
route_lease_hold() { bash "$(route__dir)/route.sh" lease-hold "$@"; }
route_lease_release() { bash "$(route__dir)/route.sh" lease-release "$@"; }
route_lease_release_run() { bash "$(route__dir)/route.sh" lease-release-run "$@"; }
route_lease_wait_put() { bash "$(route__dir)/route.sh" lease-wait-put "$@"; }
route_lease_wait_drop() { bash "$(route__dir)/route.sh" lease-wait-drop "$@"; }
route_cost_sample_put() { bash "$(route__dir)/route.sh" cost-sample-put "$@"; }

# ---------------------------------------------------------------------------
# 진입.
# ---------------------------------------------------------------------------
route__dormant() {
  # route__dormant <answer> [<borrow-json>] — 휴면 봉투 한 줄. 만든 봉투에서 값을
  # 되읽어 해석기의 답과 같은지 본다. jq 는 잘못된 UTF-8 을 대치 문자로 바꿔 쓰므로
  # 1단 값 하나가 봉투에 바이트 그대로 실리지 않을 수 있고, 그때 다른 경로를 조용히
  # 돌려주는 대신 아무것도 내지 않고 닫힌다. 그 밖에는 표준 오류에 한 바이트도 쓰지
  # 않는다. 둘째 인자는 호출자가 읽은 차용 기록이고, 좌석이 그 기록의 차용 좌석이거나
  # 기록이 손상이면 맨 끝에 `borrow` 를 단다. 없거나 파싱되지 않으면 인자 하나일 때와
  # 바이트가 같다.
  local ans="$1" mark='{}' env back
  if [ -n "${2:-}" ]; then
    mark=$(printf '%s' "$2" | jq -c -s --arg d "$ans" "$(route__jq_lib)"' if length == 1 then rt_borrow_mark($d; .[0]) else {} end' 2>/dev/null) \
      || mark='{}'
    [ -n "$mark" ] || mark='{}'
  fi
  env=$(jq -cn --arg d "$ans" --argjson m "$mark" '{verdict: "GRANT", basis: "single-seat", account: null, config_dir: $d, dormant: true} + $m') || return 1
  back=$(printf '%s\n' "$env" | jq -j '.config_dir') || back=""
  if [ "$back" != "$ans" ]; then
    route__warn "설정 디렉터리를 바이트 그대로 실을 수 없다"
    return 1
  fi
  printf '%s\n' "$env"
}

route__resolve_as() {
  # route__resolve_as <guard> <request-json> — 진입의 전부. `resolve_account` 를 가장
  # 먼저, 호출마다 정확히 한 번 부른다. 실패하면 표준 출력을 비우고 그 rc 다.
  #
  #   가드 0                 → 휴면 봉투. 인벤토리·사용량·프레임·임대 표를 읽지 않고,
  #                            차용 기록만 한 번 읽어 봉투에 기증자를 적는다.
  #   가드 1, 인벤토리 부재   → 휴면 봉투(오늘과 같은 답).
  #   가드 1, 인벤토리 깨짐   → PARK inventory-corrupt. 좌석으로 떨어지면 뒷문이다.
  #   가드 1, 유효·enabled 0 → PARK no-enabled-account.
  #   가드 1, 유효            → 문맥을 모아 `lease-txn` 프로세스에 넘긴다.
  local guard="${1:-0}" req="${2:-}" ans rc=0 irc=0 inv ctx now table boot pids p
  local hs=()
  ans=$(resolve_account) || rc=$?
  if [ "$rc" != "0" ]; then return "$rc"; fi
  if [ "$guard" != "1" ]; then
    route__dormant "$ans" "$(route__borrow_now)" || return 1
    return 0
  fi
  inv="${RUN_DIR:-}/inventory.json"
  if [ -z "${RUN_DIR:-}" ] || [ ! -e "$inv" ]; then
    route__dormant "$ans" "$(route__borrow_now)" || return 1
    return 0
  fi
  route_inventory_check "$inv" || irc=$?
  case "$irc" in
    0) ;;
    1)
      printf '%s\n' '{"verdict":"PARK","reason":"inventory-corrupt","recovery":"cc-lane account check"}'
      return 0 ;;
    *)
      route__dormant "$ans" "$(route__borrow_now)" || return 1
      return 0 ;;
  esac
  if ! jq -e 'any(.accounts[]; .unattended == "enabled")' "$inv" >/dev/null 2>&1; then
    printf '%s\n' '{"verdict":"PARK","reason":"no-enabled-account","recovery":"무인 사용이 켜진 계정이 없다 — cc-lane 에서 계정 하나의 unattended 를 enabled 로 바꾼다"}'
    return 0
  fi
  ctx=$(route_gather_context "$req" "$ans") || return 2
  now=$(printf '%s' "$ctx" | jq -r '.now') || return 2
  table="$(run_pace_root)/leases"
  boot=$(boot_epoch 2>/dev/null) || boot=""
  pids=$(printf '%s' "$req" | jq -r '(.holders // [])[] | tostring') || return 2
  while IFS= read -r p; do
    if [ -n "$p" ]; then hs+=(--holder "$p"); fi
  done <<EOF
$pids
EOF
  printf '%s' "$ctx" | bash "$(route__dir)/route.sh" lease-txn --table "$table" --now "$now" --boot-epoch "$boot" \
    ${hs[@]+"${hs[@]}"} || return $?
  return 0
}

route_resolve() {
  # route_resolve <request-json> — 스테이지를 띄울 설정 디렉터리의 봉투.
  #
  # 활성 경로의 GRANT·WAIT·PARK 는 모두 rc 0 이다. 비영은 해석기 실패(그 rc, 빈
  # 출력), 입력 계약 위반(rc 2), 내부 오류뿐이다. 그러므로 호출자는 `.verdict` 를
  # 먼저 읽어야 한다 — `jq -j .config_dir` 한 줄만 배선하면 WAIT·PARK 에서 `null`
  # 네 글자를 설정 디렉터리로 받는다.
  #
  # 런마다의 라우팅 판정은 `run.sh` 의 `run_routed` 에 산다. 그 함수가 정의돼 있고
  # 참일 때만 활성이다 — route.sh 만 소싱한 셸은 결코 라우팅을 켤 수 없고, 정규
  # 인벤토리는 있으나 라우팅 기록이 없는 런(기록 이전에 열린 런, 기록 생성이 실패한
  # 런)도 휴면 답을 받는다.
  if declare -F run_routed >/dev/null 2>&1 && run_routed; then
    route__resolve_as 1 "$@"
  else
    route__resolve_as 0 "$@"
  fi
}

route__usage() {
  printf '%s\n' 'usage: route.sh <lineage|classify|admit|decide|inventory-check|usage-read|frames|lease-txn|lease-hold|lease-release|lease-release-run|lease-of|lease-wait-put|lease-wait-drop|borrow-read|cost-sample-put|cost-table> [args]' >&2
}

route__main() {
  # 단독 진입의 분배기. 단독 프로세스는 `run.sh` 의 설정을 하나도 갖지 않으므로
  # 표 위치·상한·부팅 시각·현재 시각은 모두 인자나 문맥으로 받는다. 휴면 스위치를
  # 읽는 서브커맨드는 없다.
  local cmd="${1:-}"
  [ $# -gt 0 ] && shift
  case "$cmd" in
    lineage) route_lineage_of "$@" ;;
    classify) route_classify ;;
    admit) route_admit ;;
    decide) route_decide ;;
    inventory-check) route_inventory_check "$@" ;;
    usage-read) route_usage_read "$@" ;;
    frames) route__frames_of_file "$@" ;;
    lease-txn) route__txn_main "$@" ;;
    lease-hold) route__hold_main "$@" ;;
    lease-release) route__release_main "$@" ;;
    lease-release-run) route__release_run_main "$@" ;;
    lease-of) route_lease_of "$@" ;;
    lease-wait-put) route__wait_put_main "$@" ;;
    lease-wait-drop) route__wait_drop_main "$@" ;;
    borrow-read) route__borrow_read_main "$@" ;;
    cost-sample-put) route__cost_put_main "$@" ;;
    cost-table) route_cost_table ;;
    *)
      route__usage
      return 2 ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -uo pipefail
  . "$(dirname "$0")/liveness.sh"  # lint-harness-global-collisions: child-shell
  route__main "$@"
  exit $?
fi
