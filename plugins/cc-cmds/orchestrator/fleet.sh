#!/usr/bin/env bash
#
# fleet.sh — the host-resident pacing actor: one sensor tick, one blocking
# dispatch per lane, and the launchd registration that keeps both alive.
#
# WHY ONE PROGRAM HOLDS ALL THREE. The sensor computes the pacing verdict and
# publishes it; the dispatcher reads that verdict and starts backlog work; the
# agent subcommand registers both with launchd so that neither depends on a run
# or a terminal being open. Split across three owners, each reads the absence of
# the other two as a normal state — a watcher that does not know the lifetime
# reads silence as idle, a dispatcher that does not know the sensor reads a stale
# verdict as current — and every one of those misreadings stops dispatch
# QUIETLY, which is indistinguishable from having no pacing at all.
#
# THE SENSOR IS THE SINGLE WRITER OF `state.json`, AND LAUNCHD IS WHAT ENFORCES
# IT. Two instances of one launchd label never overlap, so there is no lock
# directory here: a lock would be a second mechanism guarding nothing. What the
# sensor does carry is a monotonic `tick_seq`, and it discards its own result
# rather than publish over a newer one. That comparison is not atomic with the
# rename that follows it; the residue is stated where the guard lives.
#
# THE TICK'S OWN CEILING IS DEGRADATION, NOT ABORT. A tick that reaches its
# budget drops ONLY the lane census and still publishes, marked `tick_overrun`
# with `lanes: "unavailable"`. Aborting would leave `state.json` older than three
# periods and every reader would fall to `유지` — pacing quietly disabled, the
# same endpoint this design closes elsewhere. And a run of unavailable censuses
# is counted: after `FLEET_TRUNCATED_STREAK` consecutive ticks the sensor leaves
# one `reason=truncated` record in `verdict-history.jsonl` so that a ceiling
# firing every tick cannot pin the lane rung dead without anyone seeing it.
#
# THE HEARTBEAT IS WRITTEN BEFORE THE LADDER, on a degraded or failing tick as
# well. Otherwise "alive but failing" collapses into "dead", and the two have
# different remedies. Its readers are `fleet.sh agent status` and the gate's
# snapshot, which name three distinct absences from file evidence alone and
# never call `launchctl` on the hot path.
#
# THE SENSOR CAN AT MOST DECLINE TO START NEW WORK. It kills nothing but itself,
# it never reads or writes the backlog, and it raises no banner: it writes files,
# and whoever reports in the morning reads them. The dispatcher is a pure reader
# of `state.json` — it recomputes nothing, because a recomputation at dispatch
# time would spend the seconds this design exists to save on exactly the path it
# is widening, and would tear the seat/allowance join the sensor made in one
# tick.
#
# THE DISPATCH JOB BLOCKS. It runs `run.sh --manifest` in the FOREGROUND of its
# own launchd job and waits, because launchd tears down a job's process group
# when the main process exits — a child started with `&` and abandoned does not
# survive. This is also how the driver's "there is no --detach" invariant is
# preserved: nothing here detaches; `run.sh` simply runs under a different
# parent. So this file never calls the driver's detach helper, and never
# backgrounds work that must outlive it (`scripts/test-fleet.sh` greps for the
# helper's name and for any notifier and must find neither). A double fork
# would end the process launchd is tracking
# and break the single-instance guarantee that is the sole enforcement of the
# single-writer rule above.
#
# THE PACING SENSOR CAN NEVER STOP DISPATCH BY BEING ABSENT. `state.json` that
# is missing, stale, or of an unknown schema is read as no verdict at all, which
# is `유지`; the one admission clause that fails CLOSED is lane occupancy, and
# it is measured live by `lane-probe.sh` rather than read from the sensor, so a
# dead sensor cannot open it either.
#
# Subcommands:
#   fleet.sh sensor                     # one tick: publish state, heartbeat, history
#   fleet.sh dispatch <lane>            # start the backlog head on <lane>, blocking
#   fleet.sh agent install|uninstall|status
#
# Files (all under PACE_ROOT = ${XDG_STATE_HOME:-$HOME/.local/state}/cc-cmds/pace):
#   state.json             the last published tick (schema `cc-pace-state v1`)
#   verdict-history.jsonl  one record per verdict change (`cc-pace-verdict v1`)
#   seat-bindings.jsonl    one record per observed re-binding of a seat
#   backlog.jsonl          deferred launches (`cc-pace-backlog v1`); enqueuer
#                          appends, dispatcher rewrites status — never this
#                          sensor
#   sensor.heartbeat       one UTC timestamp line, rewritten every tick
#   burn.cache             the 4h burn scan, reused for FLEET_BURN_CACHE_TTL_SECONDS
#   refusals.tsv           dispatcher-written refusal log the night summary counts
#   night-summary.md       rewritten once a day from the files above
#   lanes-streak           start tick of the current unavailable-census streak
#
# Env overrides (fixtures):
#   FLEET_PACE_ROOT        pace directory
#   FLEET_SEAT_HOMES       colon-separated seat homes (default ~/.claude-cc:~/.claude-cci)
#   FLEET_TRACKER_PLIST    tracker preferences plist
#   FLEET_LANE_PROBE       lane-probe.sh path
#   FLEET_LAUNCHCTL / FLEET_PLUTIL   command paths (default: found on PATH)
#   FLEET_LAUNCH_AGENTS_DIR          ~/Library/LaunchAgents
#   FLEET_NOW_EPOCH        fixed "now" in epoch seconds
#   FLEET_CC_SWAP_MARK     file whose first line is the epoch of the last cc-swap
#
# Exit codes:
#   0  the subcommand completed (a refused dispatch is a completed dispatch)
#   1  refused: half-installed agent, running dispatch label, missing tool
#   2  usage error
#
# Compatibility: bash 3.2 (macOS) — no associative arrays, no mapfile.

set -euo pipefail

FLEET_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
[ -n "$FLEET_DIR" ] || exit 1

# ---------------------------------------------------------------------------
# THRESHOLDS. Every number pacing depends on is declared here, once, as a single
# `readonly <NAME>=<digits>` line — `scripts/lint-pace-threshold-pins.sh`
# extracts them by that exact shape and refuses a restatement elsewhere that
# disagrees, so none of these may be split across lines or declared twice.
# ---------------------------------------------------------------------------
readonly FLEET_START_INTERVAL=55                # launchd StartInterval of the sensor label
readonly FLEET_DISPATCH_START_INTERVAL=120      # launchd StartInterval of each dispatch label
readonly FLEET_TICK_BUDGET_SECONDS=5            # the tick's own ceiling
readonly FLEET_STATE_STALE_SECONDS=180          # 3 x (55 + 5): state.json / heartbeat staleness
readonly FLEET_BURN_WINDOW_SECONDS=14400        # 4h burn window
readonly FLEET_BURN_CACHE_TTL_SECONDS=300       # burn.cache TTL; 3 x TTL and it is absent
readonly FLEET_TRACKER_STALE_SECONDS=1800       # no lastUpdated within 30 min -> tracker unavailable
readonly FLEET_LANE_HORIZON_SECONDS=172800      # lane census mtime horizon, 48h
readonly FLEET_TRUNCATED_STREAK=3               # consecutive unavailable censuses -> truncated record
readonly FLEET_BACKLOG_RECORD_MAX=4096          # a longer backlog record is skipped, never parked
readonly FLEET_SESSION_WINDOW_PCT_MAX=80        # 5h session window ceiling, admission and reseat alike
readonly FLEET_COCOA_EPOCH_OFFSET=978307200     # tracker times are seconds since 2001-01-01
readonly FLEET_IDLE_SECONDS=1200                # fleet idle for 20 min -> 가속 rung
readonly FLEET_TARGET_CONCURRENCY=2             # = dispatch labels = lanes; higher can never be met
readonly FLEET_TARGET_CONCURRENCY_DEGRADED=1    # the lane rung's target while the tracker is not ok
readonly FLEET_LANE_OCCUPANCY_MAX=1             # K: a lane admits a launch below this occupancy
readonly FLEET_SCAN_FILES_MAX=1000              # transcript scan caps; over either -> burn_truncated
readonly FLEET_SCAN_BYTES_MAX=2147483648
# The burn calibration is a literal by decision, and it is not an integer, so the
# threshold lint does not own it: 0.104 %p of weekly quota per million weighted
# tokens over a 4h window.
readonly FLEET_BURN_PP_PER_MWT=0.104

readonly FLEET_STATE_SCHEMA='cc-pace-state v1'
readonly FLEET_VERDICT_SCHEMA='cc-pace-verdict v1'
readonly FLEET_BACKLOG_SCHEMA='cc-pace-backlog v1'
readonly FLEET_BURN_SCHEMA='cc-pace-burn v1'
readonly FLEET_LABEL_PREFIX='com.nharu.cc-cmds.fleet'

PACE_ROOT="${FLEET_PACE_ROOT:-${XDG_STATE_HOME:-$HOME/.local/state}/cc-cmds/pace}"
SEAT_HOMES="${FLEET_SEAT_HOMES:-$HOME/.claude-cc:$HOME/.claude-cci}"
TRACKER_PLIST="${FLEET_TRACKER_PLIST:-$HOME/Library/Preferences/HamedElfayome.Claude-Usage.plist}"
LANE_PROBE="${FLEET_LANE_PROBE:-$FLEET_DIR/lane-probe.sh}"
LAUNCH_AGENTS_DIR="${FLEET_LAUNCH_AGENTS_DIR:-$HOME/Library/LaunchAgents}"
# `launchctl` and `plutil` are macOS-only and are looked up rather than spelled,
# so a fixture can shadow them on PATH or name a stub outright.
LAUNCHCTL="${FLEET_LAUNCHCTL:-$(command -v launchctl 2>/dev/null || true)}"
PLUTIL="${FLEET_PLUTIL:-$(command -v plutil 2>/dev/null || true)}"

# ---------------------------------------------------------------------------
# Small helpers. Everything time-shaped goes through jq: `date -d`, `date -j`
# and `date -r <seconds>` all diverge between BSD and GNU, and jq is required
# here anyway.
# ---------------------------------------------------------------------------
fleet_log() { printf '%s [fleet] %s\n' "$(date -u +%FT%TZ)" "$*" >&2; }
fleet_die() { fleet_log "$*"; exit 1; }
fleet_usage() { printf 'fleet.sh: %s\n' "$*" >&2; exit 2; }

fleet_now() { printf '%s' "${FLEET_NOW_EPOCH:-$(date -u +%s)}"; }
fleet_now_ms() { jq -n 'now * 1000 | floor'; }
fleet_iso() {
  # fleet_iso <epoch> — UTC ISO 8601 without fractions.
  jq -rn --argjson e "$1" '$e | todate'
}
fleet_iso_epoch() {
  # fleet_iso_epoch <iso> — epoch seconds, or empty when the string is not an
  # ISO 8601 timestamp with a zone (`Z` or `+HH:MM`). Fractions are dropped.
  jq -rn --arg s "$1" '
    ($s | capture("^(?<d>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})([.][0-9]+)?(?<z>Z|[+-][0-9]{2}:?[0-9]{2})$")) as $c
    | (($c.d + "Z") | fromdateiso8601) as $u
    | if $c.z == "Z" then $u
      else ($c.z[0:1]) as $sg
        | ($c.z[1:] | gsub(":"; "")) as $hm
        | (($hm[0:2] | tonumber) * 3600 + ($hm[2:4] | tonumber) * 60) as $off
        | if $sg == "-" then $u + $off else $u - $off end
      end' 2>/dev/null || true
}
fleet_mtime() {
  # Epoch mtime, or empty. `date -u -r <file>` is the one spelling both
  # platforms share (the gate's `gate_mtime` makes the same choice).
  [ -e "$1" ] || return 0
  date -u -r "$1" +%s 2>/dev/null || true
}
fleet_sha256() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1
  else sha256sum "$1" | cut -d' ' -f1; fi
}
fleet_write_atomic() {
  # fleet_write_atomic <dst> — stdin to a temp file in the same directory, then
  # `mv`. Readers see the old file or the new one and never a partial write.
  local dst="$1" dir tmp
  dir=$(dirname "$dst")
  mkdir -p "$dir"
  tmp=$(mktemp "$dir/.tmp.XXXXXX") || return 1
  if ! cat > "$tmp"; then rm -f "$tmp"; return 1; fi
  mv -f "$tmp" "$dst"
}
fleet_lane_of_home() {
  # ~/.claude-cc -> cc, ~/.claude-cci -> cci, ~/.claude -> default
  local b; b=${1##*/}
  case "$b" in
    .claude-*) printf '%s' "${b#.claude-}" ;;
    .claude)   printf 'default' ;;
    *)         printf '%s' "$b" ;;
  esac
}
fleet_seat_homes_list() {
  # One seat home per line, in SEAT_HOMES order. Read with `while IFS= read -r`
  # rather than word-split, so a home with a space in its path stays whole.
  printf '%s\n' "$SEAT_HOMES" | tr ':' '\n' | sed '/^$/d'
}
fleet_home_of_lane() {
  local h
  while IFS= read -r h; do
    [ "$(fleet_lane_of_home "$h")" = "$1" ] && { printf '%s' "$h"; return 0; }
  done <<EOF
$(fleet_seat_homes_list)
EOF
  return 1
}
fleet_seat_homes_json() {
  # [{home, lane, org, login_at}] — org and login_at read live from each seat's
  # `.claude.json`. Nothing else from that file is copied anywhere.
  local h org login
  fleet_seat_homes_list | while IFS= read -r h; do
    org=$(jq -r '.oauthAccount.organizationUuid // empty' "$h/.claude.json" 2>/dev/null || true)
    login=$(jq -r '.oauthAccount.profileFetchedAt // .profileFetchedAt // empty' "$h/.claude.json" 2>/dev/null || true)
    jq -cn --arg home "$h" --arg lane "$(fleet_lane_of_home "$h")" --arg org "$org" --arg login "$login" \
      '{home: $home, lane: $lane, org: (if $org == "" then null else $org end), login_at: (if $login == "" then null else $login end)}'
  done | jq -cs '.'
}
fleet_state_read() {
  # fleet_state_read [<max-age>] — the published state, printed only when it
  # parses, carries the schema by EQUALITY, and (when a max age is given) its
  # `computed_at_epoch` is not older than that. Anything else is absence.
  local f="$PACE_ROOT/state.json" max="${1:-}" s age
  [ -r "$f" ] || return 0
  s=$(jq -c --arg schema "$FLEET_STATE_SCHEMA" 'select(.schema == $schema)' "$f" 2>/dev/null) || return 0
  [ -n "$s" ] || return 0
  if [ -n "$max" ]; then
    age=$(printf '%s' "$s" | jq --argjson now "$(fleet_now)" '$now - (.computed_at_epoch // 0)')
    [ "$age" -le "$max" ] 2>/dev/null || return 0
  fi
  printf '%s' "$s"
}

# ===========================================================================
# SENSOR
# ===========================================================================

fleet_tracker_read() {
  # Prints `<status>\t<rows>` where status is ok | unavailable | parse-error
  # and rows is the JSON array of tracker rows alive within
  # FLEET_TRACKER_STALE_SECONDS, reduced to the allow-listed fields.
  #
  # Four failures, two labels. Absence (no plist, extraction failed) and
  # staleness (rows parse, none is fresh, AND the plist itself is old) are
  # `unavailable`: the tracker is legitimately not running. A shape change (no
  # `profiles_v3`, zero numeric rows) and a DECODING DEFECT (every row fails the
  # liveness test while the plist mtime is fresh) are `parse-error`: the tracker
  # runs and we cannot read it, which is our defect and must look like one. The
  # Cocoa epoch offset is applied before any comparison — without it every row
  # is about 31 years stale and the defect would print as `unavailable`.
  local raw rows alive now mt age
  if [ ! -r "$TRACKER_PLIST" ] || [ -z "$PLUTIL" ]; then
    printf 'unavailable\t[]'; return 0
  fi
  if ! raw=$("$PLUTIL" -extract profiles_v3 raw -o - "$TRACKER_PLIST" 2>/dev/null); then
    printf 'unavailable\t[]'; return 0
  fi
  raw=$(printf '%s' "$raw" | base64 --decode 2>/dev/null || true)
  rows=$(printf '%s' "$raw" | jq -c '
      (if type == "array" then . elif type == "object" then [.[]] else [] end)
      | map(select((.claudeUsage.weeklyPercentage | type) == "number")
            | {name: (.name // null), organizationId: (.organizationId // null),
               weeklyPercentage: .claudeUsage.weeklyPercentage,
               weeklyResetTime: (.claudeUsage.weeklyResetTime // null),
               sessionPercentage: (.claudeUsage.sessionPercentage // null),
               sessionResetTime: (.claudeUsage.sessionResetTime // null),
               lastUpdated: (.claudeUsage.lastUpdated // null)})' 2>/dev/null || true)
  if [ -z "$rows" ] || [ "$rows" = "[]" ]; then
    printf 'parse-error\t[]'; return 0
  fi
  now=$(fleet_now)
  alive=$(printf '%s' "$rows" | jq -c --argjson now "$now" --argjson off "$FLEET_COCOA_EPOCH_OFFSET" \
            --argjson stale "$FLEET_TRACKER_STALE_SECONDS" \
            'map(select((.lastUpdated | type) == "number" and ($now - (.lastUpdated + $off)) <= $stale))')
  if [ "$alive" = "[]" ]; then
    mt=$(fleet_mtime "$TRACKER_PLIST"); age=$(( now - ${mt:-0} ))
    if [ "$age" -le "$FLEET_TRACKER_STALE_SECONDS" ]; then printf 'parse-error\t[]'
    else printf 'unavailable\t[]'; fi
    return 0
  fi
  printf 'ok\t%s' "$alive"
}

fleet_burn_scan() {
  # The 4h burn from transcript `usage` lines under every seat home, as JSON:
  # {schema, computed_at_epoch, burn_4h, burn_truncated, live_4h_avg,
  #  last_usage_epoch, files, bytes}.
  #
  # `burn_4h` is %p of weekly quota per hour averaged over the window: weighted
  # tokens (0.1 cache_read + 2.0 write_1h + 1.25 write_5m + 5.0 output + 1.0
  # input, in millions) x FLEET_BURN_PP_PER_MWT / 4. `live_4h_avg` is the mean
  # concurrency over the same window — the sum of every session's active span
  # inside the window divided by the window — so the per-stage figure divides
  # two quantities from one window. The scan is capped by file count and bytes;
  # over either it stops and marks `burn_truncated`, and a truncated burn can
  # never produce 가속 because an undercounted burn is the input of a false one.
  local now since mins h f n=0 bytes=0 trunc=false sz list
  now=$(fleet_now); since=$(( now - FLEET_BURN_WINDOW_SECONDS ))
  mins=$(( FLEET_BURN_WINDOW_SECONDS / 60 ))
  list=$(mktemp) || return 1
  fleet_seat_homes_list | while IFS= read -r h; do
    [ -d "$h/projects" ] || continue
    find "$h/projects" -type f -name '*.jsonl' -mmin "-$mins" 2>/dev/null
  done > "$list"
  local files=()
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if [ "$n" -ge "$FLEET_SCAN_FILES_MAX" ]; then trunc=true; break; fi
    sz=$(wc -c < "$f" | tr -d '[:space:]')
    if [ $(( bytes + sz )) -gt "$FLEET_SCAN_BYTES_MAX" ]; then trunc=true; break; fi
    bytes=$(( bytes + sz )); n=$(( n + 1 ))
    files[${#files[@]}]="$f"
  done < "$list"
  rm -f "$list"
  {
    if [ "${#files[@]}" -gt 0 ]; then
      LC_ALL=C grep -H '"usage"' -- "${files[@]}" 2>/dev/null || true
    fi
  } | jq -R -c '
      (index(":{")) as $i | select($i != null)
      | {f: .[0:$i], l: (.[$i+1:] | try fromjson catch null)}
      | select(.l != null)
      | (.l.message.usage // .l.usage) as $u | select($u != null)
      | (.l.timestamp // "" | sub("[.][0-9]+"; "") | try fromdateiso8601 catch null) as $t
      | select($t != null)
      | {f, t: $t,
         w: ((($u.input_tokens // 0) * 1.0)
             + (($u.output_tokens // 0) * 5.0)
             + (($u.cache_read_input_tokens // 0) * 0.1)
             + (if $u.cache_creation then
                  (($u.cache_creation.ephemeral_1h_input_tokens // 0) * 2.0)
                  + (($u.cache_creation.ephemeral_5m_input_tokens // 0) * 1.25)
                else (($u.cache_creation_input_tokens // 0) * 1.25) end))}' 2>/dev/null \
  | jq -s --argjson now "$now" --argjson since "$since" --argjson win "$FLEET_BURN_WINDOW_SECONDS" \
          --argjson pp "$FLEET_BURN_PP_PER_MWT" --argjson trunc "$trunc" --argjson files "$n" --argjson bytes "$bytes" \
          --arg schema "$FLEET_BURN_SCHEMA" '
      map(select(.t >= $since and .t <= $now)) as $rows
      | ($rows | map(.w) | add // 0) as $mwt_raw
      | ($rows | group_by(.f) | map((map(.t) | max) - (map(.t) | min)) | add // 0) as $span
      | {schema: $schema, computed_at_epoch: $now,
         burn_4h: (($mwt_raw / 1000000) * $pp / ($win / 3600)),
         burn_truncated: $trunc,
         live_4h_avg: ($span / $win),
         last_usage_epoch: ($rows | map(.t) | max),
         files: $files, bytes: $bytes}'
}

fleet_burn_cached() {
  # burn.cache within its TTL is reused; past the TTL it is recomputed and
  # rewritten; when recomputation fails a cache younger than 3 x TTL is still
  # used; older than that it is absent. Age is by mtime, as the gate measures.
  local f="$PACE_ROOT/burn.cache" mt age now cached fresh
  now=$(fleet_now)
  mt=$(fleet_mtime "$f"); age=$(( now - ${mt:-0} ))
  cached=$(jq -c --arg schema "$FLEET_BURN_SCHEMA" 'select(.schema == $schema)' "$f" 2>/dev/null || true)
  if [ -n "$cached" ] && [ -n "$mt" ] && [ "$age" -le "$FLEET_BURN_CACHE_TTL_SECONDS" ]; then
    printf '%s' "$cached"; return 0
  fi
  if fresh=$(fleet_burn_scan) && [ -n "$fresh" ]; then
    printf '%s\n' "$fresh" | fleet_write_atomic "$f"
    printf '%s' "$fresh"; return 0
  fi
  if [ -n "$cached" ] && [ -n "$mt" ] && [ "$age" -le $(( FLEET_BURN_CACHE_TTL_SECONDS * 3 )) ]; then
    printf '%s' "$cached"; return 0
  fi
  printf 'null'
}

fleet_census_parse() {
  # stdin: lane-probe lines. Output: JSON array of {run_id, status, live,
  # config_dir, lane}. Split on TAB and never on whitespace — the status token
  # holds a space and the last field is a path. `(비정규 이름)` rows are dropped;
  # a live row whose lane cannot be attributed is `unknown` and is charged to
  # every lane by the readers.
  jq -R -c '
    split("\t") | select(length == 4) | select(.[0] != "(비정규 이름)")
    | {run_id: .[0], status: .[1], live: .[2], config_dir: .[3]}' 2>/dev/null \
  | jq -s -c --argjson seats "$1" '
    map(. as $r | .lane = (($seats | map(select(.home == $r.config_dir)) | .[0].lane) // "unknown"))'
}

fleet_lane_census() {
  # fleet_lane_census <budget-ms> <seats-json> — prints `ok\t<array>` or
  # `unavailable\t[]`. The probe runs with the 48h horizon and is killed at the
  # budget: past it the census is dropped, never the tick. Exit 3 from the
  # probe is an enumeration failure and is unavailable too — its empty output
  # is indistinguishable from zero runs, and zero runs would open every lane.
  # The third field says WHY a census is unavailable — `budget` (nothing left
  # before the probe started), `timeout` (killed at the budget) or `exit`
  # (the probe refused, exit 3) — because only the first two are the tick's
  # own overrun; the third is the probe's verdict about the run root.
  local budget_ms="$1" seats="$2" out pid rc=0 start now_ms census
  if [ "$budget_ms" -le 0 ]; then printf 'unavailable\t[]\tbudget'; return 0; fi
  out=$(mktemp) || { printf 'unavailable\t[]\texit'; return 0; }
  LANE_PROBE_HORIZON_SECONDS="$FLEET_LANE_HORIZON_SECONDS" bash "$LANE_PROBE" > "$out" 2>/dev/null &
  pid=$!
  start=$(fleet_now_ms)
  while kill -0 "$pid" 2>/dev/null; do
    now_ms=$(fleet_now_ms)
    if [ $(( now_ms - start )) -ge "$budget_ms" ]; then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      rm -f "$out"
      printf 'unavailable\t[]\ttimeout'; return 0
    fi
    sleep 0.1
  done
  wait "$pid" || rc=$?
  if [ "$rc" != "0" ]; then rm -f "$out"; printf 'unavailable\t[]\texit'; return 0; fi
  census=$(fleet_census_parse "$seats" < "$out" || true)
  rm -f "$out"
  [ -n "$census" ] || census='[]'
  printf 'ok\t%s\t-' "$census"
}

fleet_seat_bindings_poll() {
  # fleet_seat_bindings_poll <seats-json> <rows-json> <slept> — append one
  # record to seat-bindings.jsonl for every seat whose org differs from the
  # last record for that home. The fields are exactly these nine; no email, no
  # accountUuid, no credential, and the observation time is this tick's clock,
  # never a file mtime.
  local seats="$1" rows="$2" slept="$3" f="$PACE_ROOT/seat-bindings.jsonl" now iso
  local home org login prev prev_org prev_at label swap_mark swap_at via
  now=$(fleet_now); iso=$(fleet_iso "$now")
  swap_mark="${FLEET_CC_SWAP_MARK:-${XDG_STATE_HOME:-$HOME/.local/state}/cc-cmds/cc-swap.last}"
  swap_at=$(sed -n '1p' "$swap_mark" 2>/dev/null | tr -d '[:space:]' || true)
  case "$swap_at" in ''|*[!0-9]*) swap_at="" ;; esac
  printf '%s' "$seats" | jq -c '.[]' | while IFS= read -r seat; do
    home=$(printf '%s' "$seat" | jq -r '.home')
    org=$(printf '%s' "$seat" | jq -r '.org // ""')
    login=$(printf '%s' "$seat" | jq -r '.login_at // ""')
    prev=$(jq -c --arg h "$home" 'select(.home == $h)' "$f" 2>/dev/null | tail -n 1 || true)
    prev_org=$(printf '%s' "$prev" | jq -r '.org // ""' 2>/dev/null || true)
    prev_at=$(printf '%s' "$prev" | jq -r '.observed_at // ""' 2>/dev/null || true)
    [ -n "$prev" ] && [ "$org" = "$prev_org" ] && continue
    label=$(printf '%s' "$rows" | jq -r --arg o "$org" 'map(select(.organizationId == $o)) | .[0].name // empty')
    via=false
    if [ -n "$swap_at" ] && [ -n "$prev_at" ]; then
      [ "$swap_at" -ge "$(fleet_iso_epoch "$prev_at")" ] 2>/dev/null && via=true
    fi
    jq -cn --arg observed_at "$iso" --arg prev_observed_at "$prev_at" --arg login_at "$login" \
       --arg home "$home" --arg org_prev "$prev_org" --arg org "$org" --arg label "$label" \
       --argjson via_cc_swap "$via" --argjson slept "$slept" '
      def nz: if . == "" then null else . end;
      {observed_at: $observed_at, prev_observed_at: ($prev_observed_at | nz), login_at: ($login_at | nz),
       home: $home, org_prev: ($org_prev | nz), org: ($org | nz), label: ($label | nz),
       via_cc_swap: $via_cc_swap, slept: $slept}' >> "$f"
  done
}

# The verdict ladder, evaluated in jq over the tick's inputs so that every rung
# reads the same snapshot of them. Top rung that holds is the verdict.
#   1. tracker not ok        -> skip rung 2 only (a pass rule, not a verdict)
#   2. capacity < burn_4h    -> 제동 if the reseat candidate list is empty,
#                               else 유지 WITHOUT evaluating rungs 3 and 4
#   3. fleet idle 20 min     -> 가속
#   4. active lanes < target -> 가속 (degraded target while tracker not ok)
#   5. otherwise             -> 유지
# A truncated burn scan blocks rungs 3 and 4 from producing 가속. `allow` is
# min(rem/ttr, 100/168) per account; the cap is what keeps the fleet capacity
# bounded by accounts x 100/168 when a reset is hours away.
readonly FLEET_LADDER_JQ='
  def alive_row: (100 - .weeklyPercentage) as $rem
    | (((.weeklyResetTime + $off) - $now) / 3600) as $ttr
    | ((((.sessionResetTime // .weeklyResetTime) + $off) - $now) / 3600) as $sh
    | select($ttr > 0)
    | . + {allow: ([$rem / $ttr, 100 / 168] | min), ttr: $ttr, horizon_h: ([$ttr, $sh] | min)};
  ($rows | map(select((.weeklyResetTime | type) == "number") | alive_row)) as $alive
  | ($tracker == "ok") as $tok
  | (if $tok and ($alive | length) > 0 then ($alive | map(.allow) | add) else null end) as $cap
  | (if $burn == null then null else $burn.burn_4h end) as $b4
  | (if $burn == null then null else $burn.live_4h_avg end) as $live
  | (if $b4 == null then null else ($b4 / ([($live // 0), 1] | max)) end) as $bps
  | ($seats_in | map(. as $s | ($alive | map(select(.organizationId == $s.org)) | .[0]) as $p
      | {home: $s.home, org: $s.org, allow: ($p.allow // null),
         session_pct: ($p.sessionPercentage // null), ttr: ($p.ttr // null)})) as $seats
  | ($seats | map(.org)) as $seated
  | (if $tok and $bps != null
     then ($alive
           | map(select(.allow >= $bps and (.sessionPercentage // 100) < $pct_max
                        and (.organizationId as $o | ($seated | map(select(. == $o)) | length) == 0)))
           | sort_by(-.horizon_h)
           | map({home: (($seats | map(select(.allow == null or .allow < $bps)) | .[0].home) // null),
                  org: .organizationId, allow: .allow, horizon_h: .horizon_h}))
     else [] end) as $cands
  | ($cands | length == 0) as $cempty
  | ($census | map(select(.status == "도는중" or .status == "판정 불가"))) as $occ
  | ($seats_in | map(.lane)
     | map(. as $l | select(($occ | map(select(.lane == $l or .lane == "unknown")) | length) > 0))
     | length) as $active
  | (if $tok then $target else $target_degraded end) as $tgt
  | (if $burn == null then false else ($burn.burn_truncated // false) end) as $trunc
  | (if $burn == null then false
     elif $burn.last_usage_epoch == null then true
     else ($now - $burn.last_usage_epoch) >= $idle_s end) as $idle
  | ($lanes == "ok" and $active < $tgt) as $below
  | (if ($cap != null and $b4 != null and $cap < $b4)
     then (if $cempty then {verdict: "제동", reason: "brake"} else {verdict: "유지", reason: "default"} end)
     elif $idle and ($trunc | not) then {verdict: "가속", reason: "idle"}
     elif $below and ($trunc | not) then {verdict: "가속", reason: "lanes-below-target"}
     elif $trunc and ($idle or $below) then {verdict: "유지", reason: "truncated"}
     elif ($tok | not) then {verdict: "유지", reason: "tracker-skip"}
     else {verdict: "유지", reason: "default"} end) as $v
  | {schema: $schema, tick_seq: $tick_seq, computed_at: $computed_at, computed_at_epoch: $now,
     tick_ms: $tick_ms, tick_overrun: $overrun, slept: $slept, tracker: $tracker,
     burn_4h: $b4, burn_truncated: $trunc, burn_per_stage_4h: $bps, live_4h_avg: $live,
     fleet_capacity: $cap, candidates_empty: $cempty, seats: $seats, reseat_candidates: $cands,
     lanes: $lanes, lane_census: $census, verdict: $v.verdict, verdict_reason: $v.reason}'

fleet_sensor() {
  local start_ms now iso prev_state prev_seq tick_seq slept=false hb_prev hb_age
  local tracker rows burn lanes census census_why seats elapsed budget_ms overrun=false tick_ms state
  local inplace_seq prev_verdict streak_f streak_start streak_written record
  command -v jq >/dev/null 2>&1 || fleet_die "jq 가 없습니다 — 센서는 jq 없이 아무것도 계산하지 않습니다"
  mkdir -p "$PACE_ROOT"
  start_ms=$(fleet_now_ms)
  now=$(fleet_now); iso=$(fleet_iso "$now")

  # SLEPT: the bracket since the previous heartbeat spans a host sleep when it
  # is wider than the staleness threshold — launchd misses fires during sleep,
  # so a gap that wide was not scheduled, it was slept through.
  hb_prev=$(fleet_iso_epoch "$(sed -n '1p' "$PACE_ROOT/sensor.heartbeat" 2>/dev/null || true)")
  if [ -n "$hb_prev" ]; then
    hb_age=$(( now - hb_prev ))
    [ "$hb_age" -gt "$FLEET_STATE_STALE_SECONDS" ] && slept=true
  fi

  # HEARTBEAT FIRST. Everything below may degrade or fail; this line must not.
  printf '%s\n' "$iso" | fleet_write_atomic "$PACE_ROOT/sensor.heartbeat"

  prev_state=$(fleet_state_read || true)
  prev_seq=$(printf '%s' "${prev_state:-null}" | jq -r '.tick_seq // 0')
  case "$prev_seq" in ''|*[!0-9]*) prev_seq=0 ;; esac
  tick_seq=$(( prev_seq + 1 ))
  prev_verdict=$(printf '%s' "${prev_state:-null}" | jq -r '.verdict // empty')

  seats=$(fleet_seat_homes_json)
  IFS=$'\t' read -r tracker rows <<EOF
$(fleet_tracker_read)
EOF
  [ -n "${rows:-}" ] || rows='[]'
  fleet_seat_bindings_poll "$seats" "$rows" "$slept"
  burn=$(fleet_burn_cached)
  [ -n "$burn" ] || burn=null

  # LANE CENSUS LAST, inside what is left of the budget. The credential-shaped
  # inputs above are always published; only this one is droppable.
  elapsed=$(( $(fleet_now_ms) - start_ms ))
  budget_ms=$(( FLEET_TICK_BUDGET_SECONDS * 1000 - elapsed ))
  IFS=$'\t' read -r lanes census census_why <<EOF
$(fleet_lane_census "$budget_ms" "$seats")
EOF
  [ -n "${census:-}" ] || census='[]'
  case "${census_why:-}" in budget|timeout) overrun=true ;; esac
  tick_ms=$(( $(fleet_now_ms) - start_ms ))
  [ "$tick_ms" -ge $(( FLEET_TICK_BUDGET_SECONDS * 1000 )) ] && overrun=true

  state=$(jq -cn --argjson now "$now" --arg computed_at "$iso" --argjson off "$FLEET_COCOA_EPOCH_OFFSET" \
      --arg tracker "$tracker" --argjson rows "$rows" --argjson seats_in "$seats" --argjson burn "$burn" \
      --arg lanes "$lanes" --argjson census "$census" --argjson target "$FLEET_TARGET_CONCURRENCY" \
      --argjson target_degraded "$FLEET_TARGET_CONCURRENCY_DEGRADED" --argjson idle_s "$FLEET_IDLE_SECONDS" \
      --argjson pct_max "$FLEET_SESSION_WINDOW_PCT_MAX" --argjson tick_seq "$tick_seq" \
      --argjson tick_ms "$tick_ms" --argjson overrun "$overrun" --argjson slept "$slept" \
      --arg schema "$FLEET_STATE_SCHEMA" "$FLEET_LADDER_JQ")

  # TICK_SEQ GUARD. Re-read the in-place file just before publishing and give
  # way to anything newer. NOT ATOMIC with the `mv` below: a competing tick can
  # publish between this read and the rename. launchd never runs two instances
  # of one label, so the window is not reachable in operation; it is stated
  # here because the guard is a comparison and not a lock.
  inplace_seq=$(fleet_state_read | jq -r '.tick_seq // 0' 2>/dev/null || printf '0')
  case "$inplace_seq" in ''|*[!0-9]*) inplace_seq=0 ;; esac
  if [ "$tick_seq" -le "$inplace_seq" ]; then
    fleet_log "tick_seq $tick_seq 은 제자리 값 $inplace_seq 보다 크지 않아 발행하지 않는다"
    return 0
  fi
  printf '%s\n' "$state" | fleet_write_atomic "$PACE_ROOT/state.json"

  # VERDICT HISTORY: one record per change (the first tick has no previous
  # verdict and is a change), plus one `truncated` record per streak of
  # unavailable censuses — written once, at the streak's Nth tick.
  record=$(printf '%s' "$state" | jq -c --arg schema "$FLEET_VERDICT_SCHEMA" --arg prev "$prev_verdict" '
    {schema: $schema, tick_seq, observed_at: .computed_at, verdict, prev_verdict: (if $prev == "" then null else $prev end),
     reason: .verdict_reason, seat_allowance: (.seats | map({key: .home, value: .allow}) | from_entries),
     burn_4h, candidates_empty}')
  if [ "$(printf '%s' "$state" | jq -r .verdict)" != "$prev_verdict" ]; then
    printf '%s\n' "$record" >> "$PACE_ROOT/verdict-history.jsonl"
  fi
  streak_f="$PACE_ROOT/lanes-streak"
  if [ "$lanes" = "ok" ]; then
    rm -f "$streak_f"
  else
    streak_start=$(sed -n '1p' "$streak_f" 2>/dev/null | cut -d' ' -f1 || true)
    streak_written=$(sed -n '1p' "$streak_f" 2>/dev/null | cut -d' ' -f2 || true)
    case "$streak_start" in ''|*[!0-9]*) streak_start="$tick_seq"; streak_written=0 ;; esac
    if [ "${streak_written:-0}" != "1" ] && [ $(( tick_seq - streak_start + 1 )) -ge "$FLEET_TRUNCATED_STREAK" ]; then
      printf '%s\n' "$record" | jq -c '.reason = "truncated"' >> "$PACE_ROOT/verdict-history.jsonl"
      streak_written=1
    fi
    printf '%s %s\n' "$streak_start" "${streak_written:-0}" | fleet_write_atomic "$streak_f"
  fi

  fleet_night_summary "$now"
  fleet_log "tick $tick_seq 발행 — 판정 $(printf '%s' "$state" | jq -r '"\(.verdict) (\(.verdict_reason))"') tracker=$tracker lanes=$lanes ${tick_ms}ms"
}

fleet_night_summary() {
  # Rewritten once per (UTC) day: the tick_seq growth, the degraded-census
  # intervals and the refusal counts by clause over the last 24h. The refusal
  # log is the dispatcher's; the sensor reads it here and nowhere touches the
  # backlog.
  local now="$1" today f="$PACE_ROOT/night-summary.md" have since
  today=$(fleet_iso "$now" | cut -c1-10)
  have=$(sed -n '1p' "$f" 2>/dev/null | sed -n 's/.*date=\([0-9-]*\).*/\1/p' || true)
  [ "$have" = "$today" ] && return 0
  since=$(( now - 86400 ))
  {
    printf '<!-- cc-pace-night-summary v1; date=%s -->\n' "$today"
    printf '# 야간 페이싱 요약 %s\n\n' "$today"
    if [ -r "$PACE_ROOT/verdict-history.jsonl" ]; then
      jq -r -s --argjson since "$since" --argjson now "$now" '
        map(select((.observed_at | sub("[.][0-9]+"; "") | try fromdateiso8601 catch 0) >= $since)) as $h
        | "- 판정 레코드: \($h | length)건 (tick \(($h | map(.tick_seq) | min) // "-") → \(($h | map(.tick_seq) | max) // "-"))",
          "- 판정별: " + ($h | group_by(.verdict) | map("\(.[0].verdict)=\(length)") | join(", ")),
          "- 사유별: " + ($h | group_by(.reason) | map("\(.[0].reason)=\(length)") | join(", ")),
          "- 레인 센서스 열화 구간(truncated): \($h | map(select(.reason == "truncated")) | length)건"' \
        "$PACE_ROOT/verdict-history.jsonl" 2>/dev/null || printf -- '- 판정 이력을 읽지 못했다\n'
    else
      printf -- '- 판정 이력 없음\n'
    fi
    if [ -r "$PACE_ROOT/refusals.tsv" ]; then
      printf -- '- 거부 절별: %s\n' "$(cut -f3 "$PACE_ROOT/refusals.tsv" | sort | uniq -c | awk '{printf "%s%s=%s", (NR>1?", ":""), $2, $1}')"
    else
      printf -- '- 거부 기록 없음\n'
    fi
  } | fleet_write_atomic "$f"
}

# ===========================================================================
# DISPATCH
# ===========================================================================

fleet_backlog_rewrite() {
  # fleet_backlog_rewrite <original-line> <new-line> — replace exactly that
  # line, byte for byte, in a whole-file rewrite published by rename. Every
  # other line, including records this reader skips, is copied verbatim.
  local f="$PACE_ROOT/backlog.jsonl" orig="$1" new="$2" line
  [ -r "$f" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$line" = "$orig" ]; then printf '%s\n' "$new"; else printf '%s\n' "$line"; fi
  done < "$f" | fleet_write_atomic "$f"
}

fleet_backlog_head() {
  # The oldest `pending` record by `enqueued_at`, as `<line>` verbatim. Records
  # over FLEET_BACKLOG_RECORD_MAX bytes or of another schema are SKIPPED — not
  # parked, not modified — because refusing an oversize record is the
  # enqueuer's job, in front of a person, and a dispatcher that parked it would
  # do so with nobody watching.
  local f="$PACE_ROOT/backlog.jsonl" line best="" best_at="" at
  [ -r "$f" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    [ "${#line}" -le "$FLEET_BACKLOG_RECORD_MAX" ] || continue
    at=$(printf '%s' "$line" | jq -r --arg schema "$FLEET_BACKLOG_SCHEMA" \
          'select(.schema == $schema and .status == "pending") | .enqueued_at // empty' 2>/dev/null || true)
    [ -n "$at" ] || continue
    if [ -z "$best_at" ] || [ "$at" \< "$best_at" ]; then best="$line"; best_at="$at"; fi
  done < "$f"
  printf '%s' "$best"
}

fleet_manifest_field() {
  # fleet_manifest_field <manifest> <key> — `key=value` from the header comment.
  sed -n "s/.*[[:space:];]$2=\([^;]*\);*.*/\1/p" "$1" | sed -n '1p' | sed 's/[[:space:]]*$//'
}

fleet_dispatch_park_reason() {
  # fleet_dispatch_park_reason <record-json> — one of the five park tokens, or
  # nothing when the record is dispatchable. The order is the order in which
  # the evidence is cheapest to read; every failure to resolve parks, because a
  # launch whose premises cannot be re-verified is not a launch.
  local rec="$1" now manifest enq auth dl e_enq e_auth e_dl base wt doc doc_sha
  now=$(fleet_now)
  manifest=$(printf '%s' "$rec" | jq -r '.manifest_path // empty')
  [ -n "$manifest" ] && [ -r "$manifest" ] || { printf 'manifest-missing'; return 0; }
  enq=$(printf '%s' "$rec" | jq -r '.enqueued_at // empty')
  auth=$(printf '%s' "$rec" | jq -r '.authorized_at // empty')
  dl=$(printf '%s' "$rec" | jq -r '.deadline // empty')
  e_enq=$(fleet_iso_epoch "$enq"); e_auth=$(fleet_iso_epoch "$auth"); e_dl=$(fleet_iso_epoch "$dl")
  if [ -z "$e_enq" ] || [ -z "$e_auth" ] || [ "$e_auth" -gt "$e_enq" ] || [ "$e_enq" -gt "$now" ]; then
    printf 'clock-incoherent'; return 0
  fi
  if [ -z "$e_dl" ] || [ "$e_dl" -lt "$now" ]; then printf 'deadline-passed'; return 0; fi
  wt=$(fleet_manifest_field "$manifest" origin-worktree)
  doc=$(fleet_manifest_field "$manifest" owner-doc)
  doc_sha=$(printf '%s' "$rec" | jq -r '.doc_sha256 // empty')
  if [ -n "$wt" ] && [ -n "$doc" ] && [ -r "$wt/$doc" ]; then
    [ "$(fleet_sha256 "$wt/$doc")" = "$doc_sha" ] || { printf 'doc-changed'; return 0; }
  else
    [ "$(sed -n 's/^\*\*설계 문서 전체 sha256\*\*: *//p' "$manifest" | sed -n '1p')" = "$doc_sha" ] \
      || { printf 'doc-changed'; return 0; }
  fi
  base=$(printf '%s' "$rec" | jq -r '.base_commit // empty')
  if [ -z "$wt" ] || [ -z "$base" ] || ! (cd "$wt" 2>/dev/null && git merge-base --is-ancestor "$base" HEAD 2>/dev/null); then
    printf 'base-moved'; return 0
  fi
}

fleet_dispatch() {
  local lane="$1" home state verdict head rec id line line2 clause="" park probe rc=0 occ
  local manifest run_id run_dir wt ledger seat_pct now iso
  command -v jq >/dev/null 2>&1 || fleet_die "jq 가 없습니다"
  home=$(fleet_home_of_lane "$lane") || fleet_usage "알 수 없는 레인: $lane (좌석 홈 $SEAT_HOMES 에 없다)"
  mkdir -p "$PACE_ROOT"
  now=$(fleet_now); iso=$(fleet_iso "$now")

  # A PURE READER. Missing, stale or foreign-schema state is no verdict, which
  # is 유지 — the sensor's absence never closes dispatch.
  state=$(fleet_state_read "$FLEET_STATE_STALE_SECONDS" || true)
  [ -n "$state" ] || state='null'
  verdict=$(printf '%s' "$state" | jq -r '.verdict // "유지"')

  head=$(fleet_backlog_head)
  if [ -z "$head" ]; then fleet_log "dispatch $lane: 백로그에 pending 레코드가 없다"; return 0; fi
  rec="$head"
  id=$(printf '%s' "$rec" | jq -r '.id // "?"')

  park=$(fleet_dispatch_park_reason "$rec")
  if [ -n "$park" ]; then
    line=$(printf '%s' "$rec" | jq -c --arg r "$park" '.status = "parked" | .park_reason = $r')
    fleet_backlog_rewrite "$head" "$line"
    fleet_log "dispatch $lane: $id park — $park"
    return 0
  fi

  # ADMISSION. Only clause (1) fails closed, and it is measured live because a
  # machine whose state cannot be read must not receive unbounded launches.
  if [ "$verdict" = "제동" ]; then
    clause=brake
  else
    # (1) own lane only: 도는중 and 판정 불가 rows count; unattributed rows are
    #     charged to every lane; an enumeration failure closes the lane.
    probe=$(LANE_PROBE_HORIZON_SECONDS="$FLEET_LANE_HORIZON_SECONDS" bash "$LANE_PROBE" 2>/dev/null) || rc=$?
    if [ "$rc" != "0" ]; then
      clause=lane
    else
      occ=$(printf '%s\n' "$probe" | fleet_census_parse "$(fleet_seat_homes_json)" \
            | jq --arg l "$lane" 'map(select((.status == "도는중" or .status == "판정 불가") and (.lane == $l or .lane == "unknown"))) | length')
      [ "${occ:-0}" -lt "$FLEET_LANE_OCCUPANCY_MAX" ] || clause=lane
    fi
    # (2) the seat's 5h window under the ceiling; unknown passes.
    if [ -z "$clause" ]; then
      seat_pct=$(printf '%s' "$state" | jq -r --arg h "$home" '(.seats // []) | map(select(.home == $h)) | .[0].session_pct // empty')
      if [ -n "$seat_pct" ] && jq -en --argjson p "$seat_pct" --argjson m "$FLEET_SESSION_WINDOW_PCT_MAX" '$p >= $m' >/dev/null 2>&1; then
        clause=window
      fi
    fi
    # (3) the fleet arm is not braking: capacity >= burn OR candidates exist;
    #     unknown capacity passes. Same conjunction as the ladder's rung 2.
    if [ -z "$clause" ]; then
      if jq -en --argjson s "$state" '$s != null and $s.fleet_capacity != null and $s.burn_4h != null
                                        and $s.fleet_capacity < $s.burn_4h and $s.candidates_empty == true' >/dev/null 2>&1; then
        clause=burn
      fi
    fi
  fi
  if [ -n "$clause" ]; then
    line=$(printf '%s' "$rec" | jq -c --arg at "$iso" --arg v "$verdict" --arg c "$clause" \
            '.last_refusal_at = $at | .last_refusal_verdict = $v | .last_refusal_clause = $c')
    fleet_backlog_rewrite "$head" "$line"
    printf '%s\t%s\t%s\t%s\t%s\n' "$iso" "$lane" "$clause" "$verdict" "$id" >> "$PACE_ROOT/refusals.tsv"
    fleet_log "dispatch $lane: $id 거부 — 절 $clause (판정 $verdict)"
    return 0
  fi

  line=$(printf '%s' "$rec" | jq -c '.status = "dispatched"')
  fleet_backlog_rewrite "$head" "$line"

  # THE THREE PREPARATION STEPS, IN THIS ORDER: the report stub, then one
  # snapshot so the run directory exists, THEN the watcher — a watcher started
  # before the directory exists reads its absence as "the run went away" and
  # exits quietly. Then `run.sh` in the foreground, and this job waits.
  manifest=$(printf '%s' "$rec" | jq -r '.manifest_path')
  run_id=$(fleet_manifest_field "$manifest" run-id)
  wt=$(fleet_manifest_field "$manifest" origin-worktree)
  [ -n "$run_id" ] || fleet_die "dispatch $lane: 매니페스트에 run-id 가 없다: $manifest"
  run_dir="${XDG_STATE_HOME:-$HOME/.local/state}/cc-cmds/run/$run_id"
  ledger="$wt/docs/pipeline-run/$run_id.md"
  if [ -n "$wt" ] && [ ! -e "$ledger" ]; then
    mkdir -p "$(dirname "$ledger")"
    printf '# 파이프라인 런 %s\n\n런 id: %s · 파견 레인: %s · 파견 시각: %s\n' "$run_id" "$run_id" "$lane" "$iso" > "$ledger"
  fi
  CLAUDE_CONFIG_DIR="$home" bash "$FLEET_DIR/gate.sh" snapshot --manifest "$manifest" >/dev/null || true
  mkdir -p "$run_dir"
  bash "$FLEET_DIR/watch.sh" --run-dir "$run_dir" --ledger "$ledger" --stall 1200 --interval 60 --after-stage 120 --run-open 300 > "$run_dir/watch.log" 2>&1 < /dev/null &
  fleet_log "dispatch $lane: $id 기동 — run $run_id (매니페스트 $manifest)"
  CLAUDE_CONFIG_DIR="$home" bash "$FLEET_DIR/run.sh" --manifest "$manifest" || rc=$?
  line2=$(printf '%s' "$line" | jq -c '.status = "done"')
  fleet_backlog_rewrite "$line" "$line2"
  fleet_log "dispatch $lane: $id 종료 rc=$rc"
  return 0
}

# ===========================================================================
# AGENT — launchd registration
# ===========================================================================

fleet_labels() {
  # sensor first, then one dispatch label per lane in SEAT_HOMES order.
  local h; local IFS=':'
  printf '%s.sensor\n' "$FLEET_LABEL_PREFIX"
  for h in $SEAT_HOMES; do printf '%s.dispatch.%s\n' "$FLEET_LABEL_PREFIX" "$(fleet_lane_of_home "$h")"; done
}
fleet_label_loaded() { "$LAUNCHCTL" print "gui/$(id -u)/$1" >/dev/null 2>&1; }
fleet_label_running() {
  # Counted rather than `grep -q`: an early-exiting reader kills the writer with
  # SIGPIPE and under `pipefail` a found match would then read as "not running".
  local n
  n=$("$LAUNCHCTL" print "gui/$(id -u)/$1" 2>/dev/null | LC_ALL=C grep -c 'state = running' || true)
  [ "${n:-0}" -gt 0 ] 2>/dev/null
}
fleet_render_plist() {
  # fleet_render_plist <label> <subcommand> <lane|""> <config-dir|""> <interval> <dst>
  local label="$1" sub="$2" lane="$3" cfg="$4" interval="$5" dst="$6" tpl="$FLEET_DIR/fleet-agent.plist.in"
  [ -r "$tpl" ] || fleet_die "템플릿이 없다: $tpl"
  mkdir -p "$PACE_ROOT/log"
  {
    sed -e "s|@LABEL@|$label|g" -e "s|@FLEET_SH@|$FLEET_DIR/fleet.sh|g" -e "s|@SUBCOMMAND@|$sub|g" \
        -e "s|@START_INTERVAL@|$interval|g" -e "s|@LOG_DIR@|$PACE_ROOT/log|g" -e "s|@PATH@|$PATH|g" "$tpl" \
    | if [ -n "$lane" ]; then sed -e "s|@LANE@|$lane|g" -e "s|@CLAUDE_CONFIG_DIR@|$cfg|g"
      else sed -e '/@LANE@/d' -e '/@CLAUDE_CONFIG_DIR@/d'; fi
  } | fleet_write_atomic "$dst"
  if [ -n "$PLUTIL" ]; then "$PLUTIL" -lint -s "$dst" >/dev/null || fleet_die "렌더된 plist 가 lint 를 통과하지 못했다: $dst"; fi
}
fleet_agent_install() {
  local label n_files=0 n_loaded=0 n=0 h lane dst
  [ -n "$LAUNCHCTL" ] || fleet_die "launchctl 을 찾을 수 없다 (FLEET_LAUNCHCTL 로 지정할 수 있다)"
  for label in $(fleet_labels); do
    n=$(( n + 1 ))
    [ -e "$LAUNCH_AGENTS_DIR/$label.plist" ] && n_files=$(( n_files + 1 ))
    fleet_label_loaded "$label" && n_loaded=$(( n_loaded + 1 ))
    case "$label" in
      *.dispatch.*) fleet_label_running "$label" && fleet_die "파견 레이블 $label 이 도는 중이다 — 그 잡이 앞단으로 돌리는 run.sh 를 끊게 되므로 install 을 거부한다" ;;
    esac
  done
  # Half-installed is refused rather than repaired: it looks installed and is
  # not, and `install` silently completing it would hide which half failed.
  if { [ "$n_files" -ne 0 ] && [ "$n_files" -ne "$n" ]; } || { [ "$n_loaded" -ne 0 ] && [ "$n_loaded" -ne "$n" ]; } \
     || { [ "$n_files" -eq "$n" ] && [ "$n_loaded" -eq 0 ]; } || { [ "$n_loaded" -eq "$n" ] && [ "$n_files" -eq 0 ]; }; then
    fleet_die "반쯤 설치된 상태다 (plist $n_files/$n, 등록 $n_loaded/$n) — fleet.sh agent uninstall 로 지운 뒤 다시 설치한다"
  fi
  mkdir -p "$LAUNCH_AGENTS_DIR"
  for label in $(fleet_labels); do
    dst="$LAUNCH_AGENTS_DIR/$label.plist"
    fleet_label_loaded "$label" && { "$LAUNCHCTL" bootout "gui/$(id -u)/$label" >/dev/null 2>&1 || true; }
    case "$label" in
      *.sensor) fleet_render_plist "$label" sensor "" "" "$FLEET_START_INTERVAL" "$dst" ;;
      *.dispatch.*)
        lane=${label##*.}; h=$(fleet_home_of_lane "$lane")
        fleet_render_plist "$label" dispatch "$lane" "$h" "$FLEET_DISPATCH_START_INTERVAL" "$dst" ;;
    esac
    "$LAUNCHCTL" bootstrap "gui/$(id -u)" "$dst" || fleet_die "등록 실패: $label"
    fleet_log "등록 $label"
  done
}
fleet_agent_uninstall() {
  local label
  [ -n "$LAUNCHCTL" ] || fleet_die "launchctl 을 찾을 수 없다 (FLEET_LAUNCHCTL 로 지정할 수 있다)"
  for label in $(fleet_labels); do
    case "$label" in
      *.dispatch.*) fleet_label_running "$label" && fleet_die "파견 레이블 $label 이 도는 중이다 — uninstall 을 거부한다" ;;
    esac
  done
  for label in $(fleet_labels); do
    fleet_label_loaded "$label" && { "$LAUNCHCTL" bootout "gui/$(id -u)/$label" >/dev/null 2>&1 || true; }
    rm -f "$LAUNCH_AGENTS_DIR/$label.plist"
    fleet_log "해제 $label"
  done
}
fleet_agent_status() {
  local label now hb st age
  now=$(fleet_now)
  hb=$(fleet_iso_epoch "$(sed -n '1p' "$PACE_ROOT/sensor.heartbeat" 2>/dev/null || true)")
  if [ -n "$hb" ]; then printf '하트비트  : %s초 전\n' "$(( now - hb ))"; else printf '하트비트  : 없음\n'; fi
  st=$(fleet_state_read || true)
  if [ -n "$st" ]; then
    age=$(printf '%s' "$st" | jq --argjson now "$now" '$now - .computed_at_epoch')
    printf 'state.json: tick %s, %s초 전, 판정 %s\n' "$(printf '%s' "$st" | jq -r .tick_seq)" "$age" "$(printf '%s' "$st" | jq -r .verdict)"
  else
    printf 'state.json: 없음 또는 판본 불일치\n'
  fi
  for label in $(fleet_labels); do
    if [ -n "$LAUNCHCTL" ] && fleet_label_loaded "$label"; then
      if fleet_label_running "$label"; then printf '%s: 등록됨 (running)\n' "$label"; else printf '%s: 등록됨\n' "$label"; fi
    else
      printf '%s: 미등록\n' "$label"
    fi
  done
}

main() {
  case "${1:-}" in
    sensor)   fleet_sensor ;;
    dispatch) [ -n "${2:-}" ] || fleet_usage "dispatch <lane> — 레인이 필요하다"; fleet_dispatch "$2" ;;
    agent)
      case "${2:-}" in
        install)   fleet_agent_install ;;
        uninstall) fleet_agent_uninstall ;;
        status)    fleet_agent_status ;;
        *) fleet_usage "agent install|uninstall|status" ;;
      esac ;;
    *) fleet_usage "sensor | dispatch <lane> | agent install|uninstall|status" ;;
  esac
}

main "$@"
