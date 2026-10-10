#!/usr/bin/env bash
#
# deadline-resolve.sh — the relative-deadline resolver, as pure functions.
#
# The kickoff resolves a deadline answer such as `+8h` or `다음 날 09:00` once,
# against the moment it resolves it, into an absolute wall-clock time with a
# `±HH:MM` offset. A successor run's deadline is that resolved length again,
# added to the moment the successor was claimed. Both sides must use one
# arithmetic, so it lives here and both source it.
#
# SOURCE ONLY. Sourcing defines functions and one constant and does nothing
# else: no file is read, no environment variable other than TZ is consulted,
# and no answer a person wrote ahead of time is opened.
#
# Functions
#
#   dr_resolve <value> <now-epoch>
#       → `ok<TAB><absolute><TAB><상대|절대><TAB><length>`
#         or `<reason token><TAB><reason text>`
#       <length> is the resolved deadline minus <now-epoch>, as an ISO 8601
#       duration in the normal form `PT<h>H<m>M<s>S`.
#   dr_abs_epoch <absolute>            → epoch seconds; `±HH:MM` or `Z`
#   dr_duration_seconds <duration>     → seconds of `P[nD][T[nH][nM][nS]]`
#   dr_add_duration <absolute> <duration> <±HH:MM>
#       → the instant <absolute> + <duration>, written with that fixed offset
#
# Every function prints nothing and returns 1 on input it does not accept.
#
# Compatibility: bash 3.2 — no associative arrays. Time is computed with jq
# only; `date` is not used, `%z` is not used.

# ---------------------------------------------------------------------------
# The UTC offset of an instant is measured, never formatted:
# `(e|localtime|mktime) - e`, rounded to the minute. `%z` reports the offset of
# a different instant in a daylight-saving zone, and `date` differs between BSD
# and GNU.
# ---------------------------------------------------------------------------
DR_JQ_TIME='
def pad2: if . < 10 then "0" + tostring else tostring end;
def off($e): ((((($e | localtime | mktime) - ($e | floor)) + 30) / 60) | floor) * 60;
def fmtoff($o): (if $o < 0 then "-" else "+" end) as $sg
  | (if $o < 0 then -$o else $o end) as $a
  | $sg + (($a / 3600 | floor) | pad2) + ":" + ((($a % 3600) / 60 | floor) | pad2);
def wall($e): ($e + off($e)) | strftime("%Y-%m-%dT%H:%M:%S");
def render($e): wall($e) + fmtoff(off($e));
def wallepoch($w): $w | strptime("%Y-%m-%dT%H:%M:%S") | mktime;
def resolve($w): wallepoch($w) as $L | ($L - off($now)) as $g | ($L - off($g)) as $e
  | if wall($e) == $w then {e: $e} else {err: "시각 없음", msg: ("벽시계 " + $w + " 는 일광절약 전환으로 이 시간대에 존재하지 않습니다")} end;
def localdate($d): (($now + off($now)) + ($d * 86400)) | strftime("%Y-%m-%d");
def hm_ok($h; $m): ($h >= 0 and $h <= 23 and $m >= 0 and $m <= 59);
def offsecs($o): ((($o[1:3] | tonumber) * 3600) + (($o[4:6] | tonumber) * 60))
  | if $o[0:1] == "-" then -. else . end;
def abs_epoch($s): ($s[0:19] | strptime("%Y-%m-%dT%H:%M:%S") | mktime) as $L
  | if $s[19:] == "Z" then $L else $L - offsecs($s[19:25]) end;
def iso_dur($n): ($n | floor) as $t
  | "PT" + (($t / 3600 | floor) | tostring) + "H" + ((($t % 3600) / 60 | floor) | tostring) + "M" + (($t % 60) | tostring) + "S";
def dur_secs($d): ($d | capture("^P((?<d>[0-9]+)D)?(T((?<h>[0-9]+)H)?((?<m>[0-9]+)M)?((?<s>[0-9]+)S)?)?$")) as $c
  | (($c.d // "0") | tonumber) * 86400 + (($c.h // "0") | tonumber) * 3600
    + (($c.m // "0") | tonumber) * 60 + (($c.s // "0") | tonumber);
def at_offset($e; $o): (($e + offsecs($o)) | strftime("%Y-%m-%dT%H:%M:%S")) + $o;
def future($r): if $r.err then $r
  elif $r.e <= $now then {err: "과거 시각", msg: ("풀린 시각 " + render($r.e) + " 이 지금 이후가 아닙니다")}
  else $r end;
def at($d; $h; $m): resolve(localdate($d) + "T" + ($h | pad2) + ":" + ($m | pad2) + ":00");
def kind_rel: {kind: "상대"};
def solve($s):
  if ($s | test("Z$")) then {err: "형식 오류", msg: "Z 표기는 받지 않습니다 — ±HH:MM 오프셋을 붙여 쓰십시오"}
  elif ($s | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}[+-][0-9]{2}:[0-9]{2}$")) then
    ((try abs_epoch($s) catch null) as $e
     | if $e == null then {err: "형식 오류", msg: "절대 시각으로 읽히지 않습니다"}
       elif $e <= $now then {err: "과거 시각", msg: ("절대 시각 " + $s + " 이 지금 이후가 아닙니다")}
       else {e: $e, abs: $s, kind: "절대"} end)
  elif ($s | test("^\\+[0-9]+h([0-9]+m)?$")) then
    ($s | capture("^\\+(?<h>[0-9]+)h((?<m>[0-9]+)m)?$")) as $c
    | ($c.h | tonumber) as $h | (($c.m // "0") | tonumber) as $m
    | if $h < 1 or $h > 168 or $m > 59 then {err: "범위 초과", msg: "+Nh[Mm] 의 N 은 1..168, M 은 0..59 입니다"}
      else future({e: ($now + $h * 3600 + $m * 60)}) + kind_rel end
  elif ($s | test("^\\+[0-9]+m$")) then
    ($s | capture("^\\+(?<m>[0-9]+)m$") | .m | tonumber) as $m
    | if $m < 1 or $m > 10080 then {err: "범위 초과", msg: "+Mm 의 M 은 1..10080 입니다"}
      else future({e: ($now + $m * 60)}) + kind_rel end
  elif ($s | test("^[0-9]{2}:[0-9]{2}$")) then
    ($s[0:2] | tonumber) as $h | ($s[3:5] | tonumber) as $m
    | if (hm_ok($h; $m) | not) then {err: "형식 오류", msg: "HH:MM 의 시는 00..23, 분은 00..59 입니다"}
      else
        ((wallepoch(localdate(0) + "T" + $s + ":00") - off($now)) <= $now) as $passed
        | future(at(if $passed then 1 else 0 end; $h; $m)) + kind_rel
      end
  elif ($s | test("^(\\+[0-9]+d|다음 ?날) [0-9]{2}:[0-9]{2}$")) then
    ($s | capture("^(\\+(?<d>[0-9]+)d|다음 ?날) (?<hh>[0-9]{2}):(?<mm>[0-9]{2})$")) as $c
    | (($c.d // "1") | tonumber) as $d | ($c.hh | tonumber) as $h | ($c.mm | tonumber) as $m
    | if (hm_ok($h; $m) | not) then {err: "형식 오류", msg: "HH:MM 의 시는 00..23, 분은 00..59 입니다"}
      elif $d > 7 then {err: "범위 초과", msg: "+Dd 의 D 는 0..7 입니다"}
      else future(at($d; $h; $m)) + kind_rel end
  else {err: "형식 오류", msg: "받는 형태: +Nh[Mm] · +Mm · HH:MM · +Dd HH:MM · 다음 날 HH:MM · YYYY-MM-DDTHH:MM:SS±HH:MM"}
  end;
'

DR_ABS_RE='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(Z|[+-][0-9]{2}:[0-9]{2})$'
DR_DUR_RE='^P([0-9]+D)?(T([0-9]+H)?([0-9]+M)?([0-9]+S)?)?$'

# dr_resolve <value> <now-epoch>. jq inherits TZ exactly as it is: an unset TZ
# means the system zone, while an empty one means UTC to libc, so the variable
# is never re-exported here.
dr_resolve() {
  local out
  case "${2:-}" in ''|*[!0-9]*) return 1 ;; esac
  out=$(jq -nr --arg s "$1" --argjson now "$2" "$DR_JQ_TIME"'
    solve($s) | if .err then "\(.err)\t\(.msg)"
                else "ok\t\(.abs // render(.e))\t\(.kind)\t\(iso_dur(.e - $now))" end' 2>/dev/null) || out=''
  [ -n "$out" ] || out="형식 오류	마감을 해석하지 못했습니다"
  printf '%s' "$out"
}

dr_abs_epoch() {
  local e
  printf '%s\n' "${1:-}" | grep -E "$DR_ABS_RE" >/dev/null || return 1
  e=$(jq -nr --arg s "$1" --argjson now 0 "$DR_JQ_TIME"' abs_epoch($s) | floor' 2>/dev/null) || return 1
  case "$e" in ''|*[!0-9-]*) return 1 ;; esac
  printf '%s' "$e"
}

dr_duration_seconds() {
  local n
  case "${1:-}" in P|PT) return 1 ;; esac
  printf '%s\n' "${1:-}" | grep -E "$DR_DUR_RE" >/dev/null || return 1
  n=$(jq -nr --arg d "$1" --argjson now 0 "$DR_JQ_TIME"' dur_secs($d)' 2>/dev/null) || return 1
  case "$n" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$n"
}

dr_add_duration() {
  local e n out
  printf '%s\n' "${3:-}" | grep -E '^[+-][0-9]{2}:[0-9]{2}$' >/dev/null || return 1
  e=$(dr_abs_epoch "${1:-}") || return 1
  n=$(dr_duration_seconds "${2:-}") || return 1
  out=$(jq -nr --argjson e "$((e + n))" --arg o "$3" --argjson now 0 "$DR_JQ_TIME"' at_offset($e; $o)' 2>/dev/null) || return 1
  printf '%s\n' "$out" | grep -E "$DR_ABS_RE" >/dev/null || return 1
  printf '%s' "$out"
}
