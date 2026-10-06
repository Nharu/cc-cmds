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
# IT. Two instances of one launchd label never overlap, so `state.json` has no
# lock directory: a lock would be a second mechanism guarding nothing. What the
# sensor does carry is a monotonic `tick_seq`, and it discards its own result
# rather than publish over a newer one. That comparison is not atomic with the
# rename that follows it; the residue is stated where the guard lives.
#
# THE BACKLOG HAS SEVERAL WRITERS, AND THAT IS WHY IT HAS A LOCK. One dispatch
# label per account in the label set shares one `backlog.jsonl`, and the labels
# are bootstrapped in one loop with the same `StartInterval`, so their timers
# fire together. Without a lock two lanes read the same `pending` head, both
# pass admission (the other lane's run directory does not exist yet), the first
# flips the record and the second's flip finds no line to flip — and a rewrite
# that returns 0 on "no such line" lets the second lane start the same manifest
# on a second seat. The
# claim, from head selection to the `dispatched` flip, runs under
# `backlog.lock` (a `mkdir`, the one atomic primitive bash 3.2 has), and the
# rewrite is a compare-and-swap that fails when the line it was asked to replace
# is gone. The lock is held for the admission block only — never across the
# foreground `run.sh` — so a lane that cannot take it within the wait simply
# ends this tick with nothing started; a lock older than the stale ceiling is a
# dead holder's and is broken.
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
# and whoever reports in the morning reads them. The dispatcher reads the
# verdict, the fleet capacity and the burn from `state.json` and recomputes none
# of them — the seat/allowance join the sensor made in one tick is not torn at
# dispatch time. What it does NOT take from `state.json` is the 5h window of its
# own account: that is judged on the spot from cc-lane's `usage.json`, because a
# stale `state.json` reads as no verdict, and a window figure carried through
# that path would come back as a pass exactly when it is oldest.
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
# is `유지`. Two admission clauses fail CLOSED, and neither is read from the
# sensor, so a dead sensor can open neither: lane occupancy and the fleet
# ceiling, measured live by `lane-probe.sh` and the run markers, and the 5h
# window, whose input — cc-lane's `usage.json` — blocks when it is absent,
# stale or unreadable rather than passing.
#
# Subcommands:
#   fleet.sh sensor                     # one tick: publish state, heartbeat, history
#   fleet.sh dispatch <id>              # start the backlog head on account <id>, blocking
#   fleet.sh agent install|uninstall|status
#
# Files (all under PACE_ROOT = ${XDG_STATE_HOME:-$HOME/.local/state}/cc-cmds/pace):
#   state.json             the last published tick (schema `cc-pace-state v1`)
#   verdict-history.jsonl  one record per verdict change (`cc-pace-verdict v1`)
#   seat-bindings.jsonl    one record per observed re-binding of a seat
#   backlog.jsonl          deferred launches (`cc-pace-backlog v1`); enqueuer
#                          appends, dispatcher rewrites status — never this
#                          sensor
#   backlog.lock/          the dispatcher's claim lock (mkdir), held from head
#                          selection to the `dispatched` flip and around every
#                          later status rewrite; contains the holder's pid
#   sensor.heartbeat       one UTC timestamp line, rewritten every tick
#   burn.cache             the per-home 4h burn scan, reused for FLEET_BURN_CACHE_TTL_SECONDS
#   refusals.tsv           dispatcher-written refusal log the night summary counts:
#                          iso, lane, clause, verdict, id, detail (six columns)
#   night-summary.md       rewritten once a day from the files above
#   lanes-streak           start tick of the current unavailable-census streak
#   busy/<id>.<pid>        one run marker per dispatch job that claimed a head:
#                          pid, its start fingerprint, run id
#
# Inputs read from cc-lane (never written here):
#   accounts.json          ${XDG_CONFIG_HOME:-$HOME/.config}/cc-lane/accounts.json —
#                          the seats, the label set and every config dir
#   usage.json             ${XDG_STATE_HOME:-$HOME/.local/state}/cc-lane/usage.json —
#                          the per-account 5h and 7d windows
#
# Env overrides (fixtures):
#   FLEET_PACE_ROOT        pace directory
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
readonly FLEET_USAGE_INTERVAL_MAX_SECONDS=300   # usage.json publish_interval_s above this is unreadable
readonly FLEET_USAGE_SKEW_SECONDS=60            # how far into the future a usage.json age may point
readonly FLEET_LANE_HORIZON_SECONDS=172800      # lane census mtime horizon, 48h
readonly FLEET_TRUNCATED_STREAK=3               # consecutive unavailable censuses -> truncated record
readonly FLEET_BACKLOG_RECORD_MAX=4096          # a longer backlog record is skipped, never parked
readonly FLEET_BACKLOG_LOCK_WAIT_SECONDS=10     # a lane waits this long for backlog.lock, then ends its tick
readonly FLEET_BACKLOG_LOCK_STALE_SECONDS=60    # a backlog.lock older than this is a dead holder's and is broken
readonly FLEET_SESSION_WINDOW_PCT_MAX=80        # 5h session window ceiling, admission and reseat alike
readonly FLEET_IDLE_SECONDS=1200                # fleet idle for 20 min -> 가속 rung
readonly FLEET_TARGET_CONCURRENCY=2             # ceiling on live runs the fleet started, across every lane
readonly FLEET_TARGET_CONCURRENCY_DEGRADED=1    # the lane rung's target while usage.json is unusable this tick
readonly FLEET_LANE_OCCUPANCY_MAX=1             # K: a lane admits a launch below this occupancy
readonly FLEET_SCAN_FILES_MAX=1000              # transcript scan caps, per home; over either -> that home is truncated
readonly FLEET_SCAN_BYTES_MAX=2147483648
# The burn calibration is a literal by decision, and it is not an integer, so the
# threshold lint does not own it: 0.104 %p of weekly quota per million weighted
# tokens over a 4h window.
readonly FLEET_BURN_PP_PER_MWT=0.104

readonly FLEET_STATE_SCHEMA='cc-pace-state v1'
readonly FLEET_VERDICT_SCHEMA='cc-pace-verdict v1'
readonly FLEET_BACKLOG_SCHEMA='cc-pace-backlog v1'
# v2 is the per-home shape. The cache is adopted by schema alone, so the bump is
# what keeps a v1 cache — one figure for every seat home together — from being
# read with the new meaning in the minutes after an upgrade.
readonly FLEET_BURN_SCHEMA='cc-pace-burn v2'
readonly FLEET_LABEL_PREFIX='com.nharu.cc-cmds.fleet'
# A label id: it becomes a plist file name on a case-insensitive volume, so
# upper case is refused rather than folded, and `sensor` is the sensor's label.
# `\A`/`\z` anchor the whole string: jq's `^`/`$` also match at a newline.
readonly FLEET_ID_RE='\A[a-z0-9][a-z0-9-]*\z'

PACE_ROOT="${FLEET_PACE_ROOT:-${XDG_STATE_HOME:-$HOME/.local/state}/cc-cmds/pace}"
USAGE_FILE="${XDG_STATE_HOME:-$HOME/.local/state}/cc-lane/usage.json"
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
# ---------------------------------------------------------------------------
# The router and the liveness predicates, sourced from this file's own
# directory as a consumer. Seats, eligibility and the window judgement are the
# router's pure functions; the run markers use the liveness fingerprint. A copy
# of this file without either sibling starts nothing and exits non-zero — the
# alternative is a dispatcher that guesses at eligibility.
# ---------------------------------------------------------------------------
# shellcheck disable=SC1091
[ -r "$FLEET_DIR/route.sh" ] || fleet_die "route.sh 가 없다: $FLEET_DIR/route.sh — 아무것도 띄우지 않는다"
. "$FLEET_DIR/route.sh" || fleet_die "route.sh 를 소싱하지 못했다 — 아무것도 띄우지 않는다"
[ -r "$FLEET_DIR/liveness.sh" ] || fleet_die "liveness.sh 가 없다: $FLEET_DIR/liveness.sh — 아무것도 띄우지 않는다"
. "$FLEET_DIR/liveness.sh" || fleet_die "liveness.sh 를 소싱하지 못했다 — 아무것도 띄우지 않는다"
command -v route_inventory_check >/dev/null && command -v route_usage_read >/dev/null \
  && command -v route__jq_lib >/dev/null && command -v cc_proc_fingerprint >/dev/null \
  || fleet_die "route.sh·liveness.sh 의 정의가 없다 — 아무것도 띄우지 않는다"

fleet_inventory_path() {
  # The cc-lane inventory path, by the driver's rule: a non-empty
  # XDG_CONFIG_HOME, else $HOME/.config, then `cc-lane/accounts.json`. A root
  # that is not absolute is broken (rc 1) — judged on the value as given, so a
  # relative XDG_CONFIG_HOME does not quietly fall back to $HOME. Restated here
  # because this file does not source the driver, and two rules would let the
  # fleet and the driver read two inventories.
  local root
  if [ -n "${XDG_CONFIG_HOME:-}" ]; then root="$XDG_CONFIG_HOME"
  elif [ -n "${HOME:-}" ]; then root="$HOME/.config"
  else return 1; fi
  case "$root" in /*) ;; *) return 1 ;; esac
  printf '%s/cc-lane/accounts.json' "$root"
}
fleet_inventory_json() {
  # `{state, accounts}` — state `valid` only when the router's inventory check
  # passes; `absent` and `corrupt` carry no accounts. The check's own stderr
  # reason is kept: it names what is broken.
  local f rc=0
  if ! f=$(fleet_inventory_path); then printf '{"state":"corrupt","accounts":[]}'; return 0; fi
  route_inventory_check "$f" || rc=$?
  case "$rc" in
    0) jq -c '{state: "valid", accounts: .accounts}' "$f" 2>/dev/null || printf '{"state":"corrupt","accounts":[]}' ;;
    2) printf '{"state":"absent","accounts":[]}' ;;
    *) printf '{"state":"corrupt","accounts":[]}' ;;
  esac
}
fleet_dirs_json() {
  # fleet_dirs_json <inventory-json> — the ids whose config_dir is a directory
  # now. Measured by the shell because jq cannot stat.
  local inv="$1" id dir
  printf '%s' "$inv" | jq -r '.accounts[] | [.id, .config_dir] | @tsv' | while IFS=$'\t' read -r id dir; do
    if [ -d "$dir" ]; then printf '%s\n' "$id"; fi
  done | jq -R -s -c 'split("\n") | map(select(. != ""))'
}
fleet_label_ids() {
  # fleet_label_ids <inventory-json> <dirs-json> — the install-time label set,
  # one id per line in inventory order: unattended enabled, not interactive
  # reserved, a well-formed id, a config dir that renders safely and exists.
  printf '%s' "$1" | jq -r --argjson dirs "$2" --arg re "$FLEET_ID_RE" '
    .accounts[] | select(.unattended == "enabled" and .interactive_reserved == false
      and (.id | test($re)) and .id != "sensor" and ((.config_dir | test("[|&\\\\<>]")) | not)
      and (.id as $i | any($dirs[]; . == $i))) | .id'
}
fleet_label_violations() {
  # fleet_label_violations <inventory-json> — the accounts that WOULD be
  # labelled but cannot be: a malformed id, or a config dir carrying a character
  # the plist render would read as syntax. One `id: why` line each.
  printf '%s' "$1" | jq -r --arg re "$FLEET_ID_RE" '
    .accounts[] | select(.unattended == "enabled" and .interactive_reserved == false)
    | if ((.id | test($re)) | not) or .id == "sensor" then "\(.id): id 형식"
      elif (.config_dir | test("[|&\\\\<>]")) then "\(.id): config_dir 금지 문자"
      else empty end'
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

# The fleet's own jq definitions, appended to the router's library so that the
# window judgement and the seat view call the router's functions rather than
# restating them. Every piece of arithmetic is in here: bash `$(( ))` dies on a
# fractional epoch.
fleet__jq_defs() {
  cat <<'JQ'
# The file-level part of the window judgement, shared by every account: absent;
# unreadable (parse, schema, a publish interval outside [1, imax]); stale (an
# age outside [-skew, factor x interval]). The router's own freshness trusts
# whatever interval the file declares and has no future bound, so both are
# closed here, in front of it.
def fl_file($c; $imax; $skew):
  ($c.usage // {}) as $u
  | if $u.state == "absent" then "unknown-absent"
    elif $u.state != "valid" then "unknown-corrupt"
    elif ($u.publish_interval_s | rt_isint | not) or $u.publish_interval_s < 1 or $u.publish_interval_s > $imax then "unknown-corrupt"
    elif ($u.written_at_epoch | type) != "number" then "unknown-stale"
    elif ($c.now - $u.written_at_epoch) < (0 - $skew)
         or ($c.now - $u.written_at_epoch) > ($c.config.file_stale_factor * $u.publish_interval_s) then "unknown-stale"
    else "ok" end;
def fl_tracker($f): if $f == "ok" then "ok" elif $f == "unknown-corrupt" then "parse-error" else "unavailable" end;

# The router's candidate rows for one group and window (`rt_cands` with the
# file verdict as freshness and no stage-log frames), each kept with the id of
# the account it came from — the capacity needs to know whose row was chosen.
def fl_cands($c; $orgs; $g; $w):
  [rt_uaccts($c)[] | select(rt_group_of($orgs; .id) == $g) | .id as $id | (.windows[$w]? // null)
   | select((type == "object") and ((.utilization | type) == "number") and ((.observed_at_epoch | type) == "number"))
   | {id: $id, u: .utilization, resets_at: .resets_at_epoch, observed: .observed_at_epoch, source: .source}];

def fl_null($r): {result: $r, bp: null, ueff: null, rep: null, reset: false, resets_at: null};

# The window judgement for one account and one window: {result, bp, ueff} and
# the chosen row's account (`rep`). The order is the contract — a stale window
# blocks before its reset is looked at, so a reset that passed does not let an
# old reading through.
def fl_win($c; $file; $id; $w; $skew; $pct):
  if $file != "ok" then fl_null($file)
  else rt_orgs($c) as $orgs
    | ([rt_uaccts($c)[] | select(.id == $id)] | .[0]) as $ua
    | ([($c.inventory.accounts // [])[] | select(.id == $id)] | .[0]) as $a
    | if $ua != null and $a != null and (($ua.config_dir | type) == "string") and $ua.config_dir != $a.config_dir then fl_null("mismatch")
      elif $ua != null and (($ua.login | type) == "string") and $ua.login != "ok" then fl_null("login")
      else fl_cands($c; $orgs; rt_group_of($orgs; $id); $w) as $cs
        | if ($cs | length) == 0 then fl_null("unknown-absent")
          else ($cs | max_by([.observed, .u])) as $x
            | ($c.config.ttl_s[($x.source // "") | tostring]) as $ttl
            | ($c.now - $x.observed) as $age
            | if (($ttl | type) != "number") or $age < (0 - $skew) or $age > $ttl then fl_null("unknown-stale")
              elif $x.u < 0 then fl_null("unknown-corrupt")
              else ($x | rt_wstate($c)) as $ws
                | ($x.u | rt_bp) as $bp
                | ($ws.state == "reset_elapsed") as $reset
                | {result: (if $reset then "pass" elif $bp >= $pct * 100 then "over" else "pass" end),
                   bp: $bp, ueff: rt_ueff($ws), rep: $x.id, reset: $reset, resets_at: $x.resets_at}
              end
          end
      end
  end;

# The dispatch eligibility of one inventory account, as the first reason in a
# fixed order, or null. Label membership is structural — a well-formed id, not
# interactive reserved, a config dir that renders — so an account that left
# `enabled` after install reads `not-enabled`, not `not-labelled`. The router
# part is `rt_new_ok` spelled out reason by reason.
def fl_reason($p; $a; $dirs; $re):
  rt_av($p; $a.id) as $av
  | if (($a.id | test($re)) | not) or $a.id == "sensor" or $a.interactive_reserved != false
       or ($a.config_dir | test("[|&\\\\<>]")) then "not-labelled"
    elif $a.unattended != "enabled" then "not-enabled"
    elif (any($dirs[]; . == $a.id) | not) then "no-config-dir"
    elif $av == null then "inventory-broken"
    elif $av.group_reserved then "group-reserved"
    elif $av.mismatch then "mismatch"
    elif $av.login_bad then "login"
    elif ($av.borrowed // null) != null then "borrowed"
    elif $av.class == "X" then "exhausted"
    elif (rt_new_ok($av) | not) then "exhausted"
    else null end;

# The allocation fields say what this account's usage is, not whether the fleet
# may launch on it: they are carried whenever the usage row is confirmed to be
# this account's, eligible or not, and null otherwise — a reader that gets null
# reads "unknown" and closes. `session_pct` is the reset-adjusted basis point
# over 100, never a second rounding of it.
def fl_alloc($c; $file; $w5; $w7; $why):
  if $file == "ok" and ($w5.result | IN("pass", "over")) and ((($why // "") | IN("mismatch", "login", "inventory-broken")) | not)
  then
    (if ($w7.result | IN("pass", "over")) then
       ([100 - ($w7.ueff / 100), 0] | max) as $rem
       | if $w7.reset then {allow: (100 / 168), ttr: null}
         elif (($w7.resets_at | type) == "number") and ($w7.resets_at > $c.now) then
           (($w7.resets_at - $c.now) / 3600) as $ttr | {allow: ([$rem / $ttr, 100 / 168] | min), ttr: $ttr}
         else {allow: null, ttr: null} end
     else {allow: null, ttr: null} end) as $a7
    | {allow: $a7.allow, session_pct: ($w5.ueff / 100), ttr: $a7.ttr,
       horizon_h: ([$a7.ttr, (if (($w5.resets_at | type) == "number") and ($w5.reset | not)
                              then ($w5.resets_at - $c.now) / 3600 else null end)] | map(select(. != null)) | min)}
  else {allow: null, session_pct: null, ttr: null, horizon_h: null} end;

# One seat row per inventory account, with the internal fields the ladder needs
# (`w5`, `group`, `horizon_h`) dropped before publishing.
def fl_seat_row($c; $p; $file; $a; $dirs; $re; $skew; $pct):
  fl_win($c; $file; $a.id; "five_hour"; $skew; $pct) as $w5
  | fl_win($c; $file; $a.id; "seven_day"; $skew; $pct) as $w7
  | (if $c.inventory.state == "valid" then fl_reason($p; $a; $dirs; $re) else "inventory-broken" end) as $why
  | fl_alloc($c; $file; $w5; $w7; $why) as $al
  | {id: $a.id, home: $a.config_dir,
     org: ([rt_uaccts($c)[] | select(.id == $a.id)] | .[0].org_hash // null),
     eligible: ($why == null), reason: $why,
     allow: $al.allow, session_pct: $al.session_pct, ttr: $al.ttr, horizon_h: $al.horizon_h,
     w5: $w5, group: rt_group_of(rt_orgs($c); $a.id)};
JQ
}
fleet__lib() { route__jq_lib; fleet__jq_defs; }

fleet_context() {
  # fleet_context <now> <inventory-json> — the router context this file builds
  # for itself: the inventory, the usage file in the router's normal form, the
  # borrow record, an empty lease table, the router's own config (cap = the 5h
  # ceiling in basis points) and an integer now. `route_gather_context` is not
  # used: it leans on the driver's globals.
  local now="$1" inv="$2" usage borrow bpath cfg
  usage=$(route_usage_read "$USAGE_FILE" "$now" 2>/dev/null) || usage='{"state":"corrupt"}'
  [ -n "$usage" ] || usage='{"state":"corrupt"}'
  if bpath=$(route__borrow_path); then
    borrow=$(route_borrow_read "$bpath") || borrow='{"state":"corrupt"}'
  else
    borrow='{"state":"corrupt"}'
  fi
  cfg=$(route__config_json "$(( FLEET_SESSION_WINDOW_PCT_MAX * 100 ))")
  jq -cn --argjson now "$now" --argjson inv "$inv" --argjson usage "$usage" --argjson borrow "$borrow" --argjson cfg "$cfg" '
    {now: $now, request: {}, inventory: $inv, usage: $usage, frames: [],
     leases: {state: "valid", items: [], corrupt: []}, borrow: $borrow, config: $cfg, seat: {config_dir: null}}'
}
fleet_jq() {
  # fleet_jq <ctx> <dirs> <program> [jq args...] — run <program> against the
  # router library plus the fleet definitions, with the context and the pins
  # bound by name.
  local ctx="$1" dirs="$2" prog="$3"; shift 3
  jq -cn --argjson c "$ctx" --argjson dirs "$dirs" --arg re "$FLEET_ID_RE" --arg lschema "$ROUTE_LEASE_SCHEMA" \
     --argjson imax "$FLEET_USAGE_INTERVAL_MAX_SECONDS" --argjson skew "$FLEET_USAGE_SKEW_SECONDS" \
     --argjson pct "$FLEET_SESSION_WINDOW_PCT_MAX" "$@" "$(fleet__lib)
$prog"
}
fleet_cap_eval() {
  # fleet_cap_eval <ctx> <dirs> <id> — the 5h window judgement for one account:
  # {result, bp, ueff}. result is pass, over, unknown-absent, unknown-stale,
  # unknown-corrupt, or the account-level mismatch / login.
  fleet_jq "$1" "$2" 'fl_file($c; $imax; $skew) as $f | fl_win($c; $f; $id; "five_hour"; $skew; $pct) | {result, bp, ueff}' --arg id "$3"
}
fleet_reason_of() {
  # fleet_reason_of <ctx> <dirs> <id> — the first eligibility reason of <id>,
  # or empty when it is eligible. An id not in the inventory is `not-labelled`;
  # an inventory that is absent or broken is `inventory-broken`.
  fleet_jq "$1" "$2" '
    if $c.inventory.state != "valid" then "inventory-broken"
    else ([$c.inventory.accounts[] | select(.id == $id)] | .[0]) as $a
      | if $a == null then "not-labelled"
        else ($c | rt_prep($lschema)) as $p | fl_reason($p; $a; $dirs; $re) end
    end | . // ""' --arg id "$3" | jq -r '.'
}

fleet_scan_homes_json() {
  # fleet_scan_homes_json <inventory-json> — the homes the burn scan reads:
  # every account that may still be running unattended work (enabled or
  # draining) and is not reserved for interactive use, in inventory order.
  printf '%s' "$1" | jq -c '[.accounts[] | select((.unattended == "enabled" or .unattended == "draining")
                              and .interactive_reserved == false) | .config_dir]'
}

fleet_burn_scan() {
  # fleet_burn_scan <home> — the 4h burn from transcript `usage` lines under ONE
  # home, as JSON: {burn_4h, live_4h_avg, last_usage_epoch, truncated, files,
  # bytes}.
  #
  # `burn_4h` is %p of weekly quota per hour averaged over the window: weighted
  # tokens (0.1 cache_read + 2.0 write_1h + 1.25 write_5m + 5.0 output + 1.0
  # input, in millions) x FLEET_BURN_PP_PER_MWT / 4. `live_4h_avg` is the mean
  # concurrency over the same window — the sum of every session's active span
  # inside the window divided by the window — so the per-stage figure divides
  # two quantities from one window. The scan caps apply to this home alone; over
  # either it stops and marks the home `truncated`, and a truncated burn can
  # never produce 가속 because an undercounted burn is the input of a false one.
  local h="$1" now since mins f n=0 bytes=0 trunc=false sz list
  now=$(fleet_now); since=$(( now - FLEET_BURN_WINDOW_SECONDS ))
  mins=$(( FLEET_BURN_WINDOW_SECONDS / 60 ))
  list=$(mktemp) || return 1
  if [ -d "$h/projects" ]; then
    find "$h/projects" -type f -name '*.jsonl' -mmin "-$mins" 2>/dev/null > "$list" || true
  fi
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
          --argjson pp "$FLEET_BURN_PP_PER_MWT" --argjson trunc "$trunc" --argjson files "$n" --argjson bytes "$bytes" '
      map(select(.t >= $since and .t <= $now)) as $rows
      | ($rows | map(.w) | add // 0) as $mwt_raw
      | ($rows | group_by(.f) | map((map(.t) | max) - (map(.t) | min)) | add // 0) as $span
      | {burn_4h: (($mwt_raw / 1000000) * $pp / ($win / 3600)),
         live_4h_avg: ($span / $win),
         last_usage_epoch: ($rows | map(.t) | max),
         truncated: $trunc, files: $files, bytes: $bytes}'
}

fleet_burn_scan_all() {
  # fleet_burn_scan_all <homes-json> — {schema, computed_at_epoch, homes:
  # {<home>: <scan>}} over every home given.
  local homes="$1" h one acc='{}'
  while IFS= read -r h; do
    [ -n "$h" ] || continue
    one=$(fleet_burn_scan "$h") || return 1
    [ -n "$one" ] || return 1
    acc=$(jq -cn --argjson a "$acc" --arg h "$h" --argjson v "$one" '$a + {($h): $v}') || return 1
  done <<EOF
$(printf '%s' "$homes" | jq -r '.[]')
EOF
  jq -cn --arg schema "$FLEET_BURN_SCHEMA" --argjson now "$(fleet_now)" --argjson homes "$acc" \
    '{schema: $schema, computed_at_epoch: $now, homes: $homes}'
}

fleet_burn_cached() {
  # fleet_burn_cached <homes-json> — burn.cache within its TTL is reused when it
  # covers every home asked for; past the TTL (or missing a home) it is
  # recomputed and rewritten; when recomputation fails a cache younger than
  # 3 x TTL is still used; older than that it is absent. Age is by mtime, as
  # the gate measures.
  local homes="$1" f="$PACE_ROOT/burn.cache" mt age now cached fresh covers=false
  now=$(fleet_now)
  mt=$(fleet_mtime "$f"); age=$(( now - ${mt:-0} ))
  cached=$(jq -c --arg schema "$FLEET_BURN_SCHEMA" 'select(.schema == $schema and (.homes | type) == "object")' "$f" 2>/dev/null || true)
  if [ -n "$cached" ]; then
    covers=$(jq -n --argjson c "$cached" --argjson h "$homes" 'all($h[]; . as $x | $c.homes | has($x))' 2>/dev/null || printf 'false')
  fi
  if [ -n "$cached" ] && [ "$covers" = "true" ] && [ -n "$mt" ] && [ "$age" -le "$FLEET_BURN_CACHE_TTL_SECONDS" ]; then
    printf '%s' "$cached"; return 0
  fi
  if fresh=$(fleet_burn_scan_all "$homes") && [ -n "$fresh" ]; then
    printf '%s\n' "$fresh" | fleet_write_atomic "$f"
    printf '%s' "$fresh"; return 0
  fi
  if [ -n "$cached" ] && [ -n "$mt" ] && [ "$age" -le $(( FLEET_BURN_CACHE_TTL_SECONDS * 3 )) ]; then
    printf '%s' "$cached"; return 0
  fi
  printf 'null'
}

fleet_census_parse() {
  # fleet_census_parse <inventory-json> — stdin: lane-probe lines. Output: JSON
  # array of {run_id, status, live, config_dir, lane}, where lane is the
  # inventory id the row's config dir belongs to. Split on TAB and never on
  # whitespace — the status token holds a space and the last field is a path.
  #
  # The join is against the WHOLE inventory, one trailing `/` stripped on both
  # sides: a run a person started under an interactive-reserved home belongs to
  # that account and closes no lane. A home outside the inventory, and the
  # probe's three placeholder strings, are `unknown` and charged to every lane.
  # A row that is not exactly four fields is NOT dropped — a dropped row reads
  # as an empty lane — but becomes one `unknown`/`판정 불가`. `(비정규 이름)`
  # rows are dropped: that is a run directory whose name breaks the format, not
  # a run this fleet started.
  jq -R -c '
    select(. != "") | split("\t") | select(.[0] != "(비정규 이름)")
    | if length == 4 then {run_id: .[0], status: .[1], live: .[2], config_dir: .[3]}
      else {run_id: null, status: "판정 불가", live: "?", config_dir: null} end' 2>/dev/null \
  | jq -s -c --argjson inv "$1" '
    def strip1: if type == "string" and endswith("/") then .[0:-1] else . end;
    ($inv.accounts // []) as $acc
    | map(. as $r | ($r.config_dir | strip1) as $d
          | .lane = (([$acc[] | select((.config_dir | strip1) == $d) | .id] | .[0]) // "unknown"))'
}

fleet_lane_census() {
  # fleet_lane_census <budget-ms> <inventory-json> — prints `ok\t<array>` or
  # `unavailable\t[]`. The probe runs with the 48h horizon and is killed at the
  # budget: past it the census is dropped, never the tick. Exit 3 from the
  # probe is an enumeration failure and is unavailable too — its empty output
  # is indistinguishable from zero runs, and zero runs would open every lane.
  # The third field says WHY a census is unavailable — `budget` (nothing left
  # before the probe started), `timeout` (killed at the budget) or `exit`
  # (the probe refused, exit 3) — because only the first two are the tick's
  # own overrun; the third is the probe's verdict about the run root.
  local budget_ms="$1" inv="$2" out pid rc=0 start now_ms census
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
  census=$(fleet_census_parse "$inv" < "$out" || true)
  rm -f "$out"
  [ -n "$census" ] || census='[]'
  printf 'ok\t%s\t-' "$census"
}

fleet_seat_bindings_poll() {
  # fleet_seat_bindings_poll <seats-json> <slept> — append one record to
  # seat-bindings.jsonl for every seat whose org differs from the last record
  # for that home. The org is the one the sensor published for the seat (the
  # usage file's `org_hash`) and the label is the seat's inventory id, so the
  # fleet keeps one org source. `login_at` is the seat's own profile fetch time.
  # The fields are exactly these nine; no email, no accountUuid, no credential,
  # and the observation time is this tick's clock, never a file mtime.
  local seats="$1" slept="$2" f="$PACE_ROOT/seat-bindings.jsonl" now iso
  local home org login prev prev_org prev_at label swap_mark swap_at via
  now=$(fleet_now); iso=$(fleet_iso "$now")
  swap_mark="${FLEET_CC_SWAP_MARK:-${XDG_STATE_HOME:-$HOME/.local/state}/cc-cmds/cc-swap.last}"
  swap_at=$(sed -n '1p' "$swap_mark" 2>/dev/null | tr -d '[:space:]' || true)
  case "$swap_at" in ''|*[!0-9]*) swap_at="" ;; esac
  printf '%s' "$seats" | jq -c '.[]' | while IFS= read -r seat; do
    home=$(printf '%s' "$seat" | jq -r '.home')
    org=$(printf '%s' "$seat" | jq -r '.org // ""')
    label=$(printf '%s' "$seat" | jq -r '.id // ""')
    prev=$(jq -c --arg h "$home" 'select(.home == $h)' "$f" 2>/dev/null | tail -n 1 || true)
    prev_org=$(printf '%s' "$prev" | jq -r '.org // ""' 2>/dev/null || true)
    prev_at=$(printf '%s' "$prev" | jq -r '.observed_at // ""' 2>/dev/null || true)
    [ -n "$prev" ] && [ "$org" = "$prev_org" ] && continue
    login=$(jq -r '.oauthAccount.profileFetchedAt // .profileFetchedAt // empty' "$home/.claude.json" 2>/dev/null || true)
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
#   1. usage.json unusable   -> skip rung 2 only (a pass rule, not a verdict);
#                               published as `tracker` != ok, token tracker-skip
#   2. capacity < burn_4h    -> 제동 if the reseat candidate list is empty,
#                               else 유지 WITHOUT evaluating rungs 3 and 4
#   3. fleet idle 20 min     -> 가속
#   4. active lanes < target -> 가속 (degraded target while usage.json unusable)
#   5. otherwise             -> 유지
# A truncated burn scan blocks rungs 3 and 4 from producing 가속. `allow` is
# min(rem/ttr, 100/168) per account; the cap is what keeps the fleet capacity
# bounded by groups x 100/168 when a reset is hours away.
#
# Seats are joined to usage rows by inventory id, never by org — an org join
# hands one row to two accounts of one org and counts it twice. The capacity
# adds ONE allowance per eligible group (the router budgets a group as one),
# the allowance of the account whose row the window judgement chose for that
# group. The burn has two scopes on purpose: `burn_4h` is the eligible homes'
# sum, the same accounts the capacity covers; `burn_per_stage_4h` and
# `live_4h_avg` come from every scanned home, one sample, so the driver's
# per-stage need does not move with eligibility. Reseat candidates keep their
# meaning — usage rows of accounts that hold no seat — and with every inventory
# account a seat they are usually none.
readonly FLEET_LADDER_JQ='
  fl_file($c; $imax; $skew) as $file
  | fl_tracker($file) as $tracker
  | ($tracker == "ok") as $tok
  | ($c | rt_prep($lschema)) as $p
  | [($c.inventory.accounts // [])[] | fl_seat_row($c; $p; $file; .; $dirs; $re; $skew; $pct)] as $rows
  | (if $burn == null then {} else ($burn.homes // {}) end) as $bh
  | [$scan[] | . as $h | ($bh[$h] // null) | select(. != null)] as $scanned
  | (if $burn == null then null
     else ([$rows[] | select(.eligible) | .home | . as $h | ($bh[$h].burn_4h // empty)] | add // 0) end) as $b4
  | (if $burn == null then null else ([$scanned[] | .live_4h_avg] | add // 0) end) as $live
  | (if $burn == null then null else (([$scanned[] | .burn_4h] | add // 0) / ([$live, 1] | max)) end) as $bps
  | (if $burn == null then false else any($scanned[]; .truncated == true) end) as $trunc
  | (if $burn == null then null else ([$scanned[] | .last_usage_epoch | select(. != null)] | max) end) as $last
  | ($rows | map(. as $r | $r + {burn_4h: (if any($scan[]; . == $r.home) and ($bh[$r.home] != null) and ($bh[$r.home].truncated != true)
                                         then $bh[$r.home].burn_4h else null end)})) as $rows
  | ($rows | map(select(.eligible)) | group_by(.group)
     | map(.[0].w5.rep as $rep
           | (([$rows[] | select(.id == $rep) | .allow] | .[0]) // ([.[] | .allow | select(. != null)] | .[0])))
     | map(select(. != null))) as $contrib
  | (if $tok and ($contrib | length) > 0 then ($contrib | add) else null end) as $cap
  | ($rows | map({id, home, org, eligible, reason, allow, session_pct, ttr, burn_4h})) as $seats
  | (if $tok and $bps != null
     then ([rt_uaccts($c)[] | . as $u | select(all($rows[]; .id != $u.id))
            | fl_alloc($c; $file; fl_win($c; $file; $u.id; "five_hour"; $skew; $pct);
                       fl_win($c; $file; $u.id; "seven_day"; $skew; $pct); null) as $al
            | select($al.allow != null and $al.allow >= $bps and ($al.session_pct // 100) < $pct)
            | {org: ($u.org_hash // null), allow: $al.allow, horizon_h: ($al.horizon_h // 0)}]
           | sort_by(-.horizon_h)
           | map({home: (($rows | map(select(.allow == null or .allow < $bps)) | .[0].home) // null),
                  org, allow, horizon_h}))
     else [] end) as $cands
  | ($cands | length == 0) as $cempty
  | ($census | map(select(.status == "도는중" or .status == "판정 불가"))) as $occ
  | ([$rows[] | select(.eligible) | .id]
     | map(. as $l | select(any($occ[]; .lane == $l or .lane == "unknown")))
     | length) as $active
  | (if $tok then $target else $target_degraded end) as $tgt
  | (if $burn == null then false
     elif $last == null then true
     else ($now - $last) >= $idle_s end) as $idle
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
  local tracker inv dirs ctx scan burn lanes census census_why elapsed budget_ms overrun=false tick_ms state
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

  # SEATS FROM THE INVENTORY. An absent or broken inventory publishes a state
  # with no seats; it does not stop the tick.
  inv=$(fleet_inventory_json)
  dirs=$(fleet_dirs_json "$inv")
  ctx=$(fleet_context "$now" "$inv")
  scan=$(fleet_scan_homes_json "$inv")
  burn=$(fleet_burn_cached "$scan")
  [ -n "$burn" ] || burn=null

  # LANE CENSUS LAST, inside what is left of the budget. The credential-shaped
  # inputs above are always published; only this one is droppable.
  elapsed=$(( $(fleet_now_ms) - start_ms ))
  budget_ms=$(( FLEET_TICK_BUDGET_SECONDS * 1000 - elapsed ))
  IFS=$'\t' read -r lanes census census_why <<EOF
$(fleet_lane_census "$budget_ms" "$inv")
EOF
  [ -n "${census:-}" ] || census='[]'
  case "${census_why:-}" in budget|timeout) overrun=true ;; esac
  tick_ms=$(( $(fleet_now_ms) - start_ms ))
  [ "$tick_ms" -ge $(( FLEET_TICK_BUDGET_SECONDS * 1000 )) ] && overrun=true

  state=$(fleet_jq "$ctx" "$dirs" "$FLEET_LADDER_JQ" --argjson now "$now" --arg computed_at "$iso" \
      --argjson burn "$burn" --argjson scan "$scan" \
      --arg lanes "$lanes" --argjson census "$census" --argjson target "$FLEET_TARGET_CONCURRENCY" \
      --argjson target_degraded "$FLEET_TARGET_CONCURRENCY_DEGRADED" --argjson idle_s "$FLEET_IDLE_SECONDS" \
      --argjson tick_seq "$tick_seq" \
      --argjson tick_ms "$tick_ms" --argjson overrun "$overrun" --argjson slept "$slept" \
      --arg schema "$FLEET_STATE_SCHEMA")
  tracker=$(printf '%s' "$state" | jq -r '.tracker')

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
  fleet_seat_bindings_poll "$(printf '%s' "$state" | jq -c '.seats')" "$slept"

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
  #
  # A COMPARE-AND-SWAP, NOT A BLIND REWRITE. When the original line is not in
  # the file this returns 3 and writes nothing: the record was already flipped
  # by the other lane (or rewritten by hand), and a caller that reads 0 here
  # would go on to start work on a premise that no longer holds. The exact-line
  # test is `grep -x -F`, the same comparison the loop below makes.
  local f="$PACE_ROOT/backlog.jsonl" orig="$1" new="$2" line
  [ -r "$f" ] || return 1
  grep -qxF -- "$orig" "$f" || return 3
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$line" = "$orig" ]; then printf '%s\n' "$new"; else printf '%s\n' "$line"; fi
  done < "$f" | fleet_write_atomic "$f"
}

FLEET_BACKLOG_LOCKED=""
fleet_backlog_lock() {
  # Take `backlog.lock` or return 1 after FLEET_BACKLOG_LOCK_WAIT_SECONDS. A
  # lock directory older than FLEET_BACKLOG_LOCK_STALE_SECONDS is broken: the
  # lock is only ever held across the admission block, so a holder that old is
  # a job launchd tore down mid-claim. The stale age is measured against the
  # real clock, not `fleet_now` — a fixture that pins "now" must still see a
  # live holder as live.
  local d="$PACE_ROOT/backlog.lock" waited=0 mt age
  mkdir -p "$PACE_ROOT"
  while ! mkdir "$d" 2>/dev/null; do
    mt=$(fleet_mtime "$d")
    age=$(( $(date -u +%s) - ${mt:-0} ))
    if [ -n "$mt" ] && [ "$age" -gt "$FLEET_BACKLOG_LOCK_STALE_SECONDS" ]; then
      fleet_log "backlog.lock 이 ${age}초 묵었다 — 죽은 소유자의 것으로 보고 깬다"
      rm -rf "$d"
      continue
    fi
    [ "$waited" -lt "$FLEET_BACKLOG_LOCK_WAIT_SECONDS" ] || return 1
    sleep 1; waited=$(( waited + 1 ))
  done
  printf '%s\n' "$$" > "$d/pid" 2>/dev/null || true
  FLEET_BACKLOG_LOCKED=1
}
fleet_backlog_unlock() {
  # Only the holder releases. An EXIT trap calls this too, and a process that
  # already released must not remove the lock the other lane has since taken.
  [ -n "$FLEET_BACKLOG_LOCKED" ] || return 0
  FLEET_BACKLOG_LOCKED=""
  rm -rf "$PACE_ROOT/backlog.lock"
}
fleet_backlog_rewrite_locked() {
  # fleet_backlog_rewrite under the lock, for the rewrites made after the claim
  # was released (the `done` flip). Returns the rewrite's own status; a lock
  # that cannot be taken is 1, and the caller logs rather than retries.
  local rc=0
  fleet_backlog_lock || return 1
  fleet_backlog_rewrite "$1" "$2" || rc=$?
  fleet_backlog_unlock
  return "$rc"
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
  # fleet_dispatch_park_reason <record-json> — one of the five record-level
  # park tokens, or nothing when the record is dispatchable. The sixth token,
  # `lane-record`, needs the run directory and is judged by the caller after
  # this one. The order is the order in which
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

# ---------------------------------------------------------------------------
# RUN MARKERS. One file per dispatch job that claimed a head, written under the
# claim lock before it is released: `busy/<id>.<pid>` holding the job's pid,
# that pid's start fingerprint, and the run id. The marker is what counts a run
# in the window the probe cannot see — between the lock's release and the run
# directory's first stage — and the run id line keeps a run counted when only
# its dispatcher died. One marker per PROCESS, not per lane: a second dispatch
# on the same lane by hand writes its own and overwrites nothing.
# ---------------------------------------------------------------------------
FLEET_BUSY_MARK=""
fleet_busy_drop() {
  # The EXIT trap's half: remove this process's own marker and nothing else.
  if [ -n "$FLEET_BUSY_MARK" ]; then rm -f "$FLEET_BUSY_MARK"; fi
  FLEET_BUSY_MARK=""
}
fleet_busy_live() {
  # fleet_busy_live <marker> <census-json> — rc 0 when the marker counts: its
  # pid is alive AND still the process that wrote it, OR the probe shows its run
  # id running or undecidable.
  local f="$1" census="$2" pid fp run
  pid=$(sed -n '1p' "$f" 2>/dev/null | tr -d '[:space:]')
  fp=$(sed -n '2p' "$f" 2>/dev/null || true)
  run=$(sed -n '3p' "$f" 2>/dev/null | tr -d '[:space:]')
  if [ -n "$pid" ] && [ -n "$fp" ] && kill -0 "$pid" 2>/dev/null; then
    [ "$(TZ=UTC0 cc_proc_fingerprint "$pid")" = "$fp" ] && return 0
  fi
  [ -n "$run" ] || return 1
  printf '%s' "$census" | jq -e --arg r "$run" \
    'any(.[]; .run_id == $r and (.status == "도는중" or .status == "판정 불가"))' >/dev/null 2>&1
}
fleet_busy_count() {
  # fleet_busy_count <lane> <census-json> — `<all> <same-lane>` live markers.
  # Called under the claim lock, so a dead marker (dead or reused pid, and no
  # live row for its run) is removed here.
  local lane="$1" census="$2" f base all=0 same=0
  for f in "$PACE_ROOT/busy"/*; do
    [ -f "$f" ] || continue
    base=${f##*/}
    if fleet_busy_live "$f" "$census"; then
      all=$(( all + 1 ))
      [ "${base%.*}" = "$lane" ] && same=$(( same + 1 ))
    else
      rm -f "$f"
    fi
  done
  printf '%s %s' "$all" "$same"
}
fleet_busy_write() {
  # fleet_busy_write <lane> <run-id> — this process's marker, by temp file and
  # rename so a reader never sees two lines of three.
  local f="$PACE_ROOT/busy/$1.$$"
  mkdir -p "$PACE_ROOT/busy"
  printf '%s\n%s\n%s\n' "$$" "$(TZ=UTC0 cc_proc_fingerprint "$$")" "$2" | fleet_write_atomic "$f" || return 1
  FLEET_BUSY_MARK="$f"
}

fleet_label_homes_json() {
  # fleet_label_homes_json <inventory-json> — [{id, home}] of every account
  # that can hold a label (well-formed id, not interactive reserved, a config
  # dir that renders), whatever its state this tick; home has one trailing `/`
  # stripped for comparison.
  printf '%s' "$1" | jq -c --arg re "$FLEET_ID_RE" '
    [.accounts[] | select((.id | test($re)) and .id != "sensor" and .interactive_reserved == false
                          and ((.config_dir | test("[|&\\\\<>]")) | not))
     | {id, home: (.config_dir | if endswith("/") then .[0:-1] else . end)}]'
}

fleet_dispatch() {
  local lane="$1" home state verdict head rec id line line2 clause="" detail="-" park probe rc=0 occ
  local manifest run_id run_dir wt ledger now iso inv dirs ctx why rec_dir other census busy res
  command -v jq >/dev/null 2>&1 || fleet_die "jq 가 없습니다"
  # (1) THE ID. A malformed id is a usage error, not a lane: it can never have
  #     been rendered into a label.
  case "$lane" in
    ''|-*|*[!a-z0-9-]*|sensor) fleet_usage "레인 id 형식이 아니다: $lane — 소문자·숫자·하이픈, 첫 글자는 소문자나 숫자, sensor 제외" ;;
  esac
  mkdir -p "$PACE_ROOT"
  now=$(fleet_now); iso=$(fleet_iso "$now")

  # (2) ELIGIBILITY, BEFORE THE LOCK. A lane that may not work now ends with one
  #     log line and no refusal row: that is "this lane is idle", not a verdict
  #     on the head record, and a row per tick would bury every real refusal.
  #     The router part is the router's own new-run predicate over a context
  #     this file builds.
  inv=$(fleet_inventory_json)
  dirs=$(fleet_dirs_json "$inv")
  ctx=$(fleet_context "$now" "$inv")
  why=$(fleet_reason_of "$ctx" "$dirs" "$lane")
  if [ -n "$why" ]; then
    fleet_log "dispatch $lane: 부적격 — $why (아무것도 띄우지 않는다)"
    return 0
  fi
  home=$(printf '%s' "$inv" | jq -r --arg i "$lane" '.accounts[] | select(.id == $i) | .config_dir')

  # The verdict, the capacity and the burn come from the sensor. Missing,
  # stale or foreign-schema state is no verdict, which is 유지 — the sensor's
  # absence never closes dispatch. The 5h window does NOT come from here.
  state=$(fleet_state_read "$FLEET_STATE_STALE_SECONDS" || true)
  [ -n "$state" ] || state='null'
  verdict=$(printf '%s' "$state" | jq -r '.verdict // "유지"')

  # (3) THE CLAIM IS ONE CRITICAL SECTION: head selection, the park and
  # refusal rewrites, the run markers and the `dispatched` flip all happen
  # under `backlog.lock`, so no other lane can pick the same head, or count the
  # same free seat, between this lane's read and its flip. Every exit from the
  # section releases the lock, and the EXIT trap covers a `fleet_die` inside
  # it; the same trap removes this process's own marker, whichever way the job
  # ends. The lock is released BEFORE `run.sh` runs: the claim is seconds, the
  # run is hours, and a lock held across the run would serialize the lanes this
  # file exists to run side by side.
  trap 'fleet_backlog_unlock; fleet_busy_drop' EXIT
  if ! fleet_backlog_lock; then
    fleet_log "dispatch $lane: backlog.lock 을 ${FLEET_BACKLOG_LOCK_WAIT_SECONDS}초 안에 잡지 못했다 — 다른 레인이 집는 중이므로 이번 틱은 시작하지 않는다"
    return 0
  fi
  head=$(fleet_backlog_head)
  if [ -z "$head" ]; then fleet_backlog_unlock; fleet_log "dispatch $lane: 백로그에 pending 레코드가 없다"; return 0; fi
  rec="$head"
  id=$(printf '%s' "$rec" | jq -r '.id // "?"')

  park=$(fleet_dispatch_park_reason "$rec")
  # The manifest is read here, inside the lock and before the flip, because the
  # lane-record test below needs the run directory. A manifest with no run id
  # cannot name one; it is parked as an unusable manifest rather than left
  # pending for every lane to trip on every tick.
  if [ -z "$park" ]; then
    manifest=$(printf '%s' "$rec" | jq -r '.manifest_path')
    run_id=$(fleet_manifest_field "$manifest" run-id)
    wt=$(fleet_manifest_field "$manifest" origin-worktree)
    if [ -z "$run_id" ]; then
      park=manifest-missing
      fleet_log "dispatch $lane: 매니페스트에 run-id 가 없다: $manifest"
    fi
  fi
  if [ -z "$park" ]; then
    run_dir="${XDG_STATE_HOME:-$HOME/.local/state}/cc-cmds/run/$run_id"
    # (4) A RUN ALREADY RECORDED ON ANOTHER ACCOUNT. The driver adopts an
    #     existing `config-dir` record without checking it against its
    #     environment, so starting this run here would split it across two
    #     accounts. Another labelled lane's home: refuse, and the head waits for
    #     its lane — eligibility moves tick by tick, parking is forever. A home
    #     no label holds: park. The record is never rewritten here.
    rec_dir=$(sed -n '1p' "$run_dir/config-dir" 2>/dev/null || true)
    rec_dir=${rec_dir%/}
    if [ -n "$rec_dir" ] && [ "$rec_dir" != "${home%/}" ]; then
      other=$(fleet_label_homes_json "$inv" | jq -r --arg d "$rec_dir" '[.[] | select(.home == $d) | .id] | .[0] // empty')
      if [ -n "$other" ]; then clause=lane; detail=lane-mismatch
      else park=lane-record; fi
    fi
  fi
  if [ -n "$park" ]; then
    line=$(printf '%s' "$rec" | jq -c --arg r "$park" '.status = "parked" | .park_reason = $r')
    fleet_backlog_rewrite "$head" "$line" || fleet_log "dispatch $lane: $id 의 park 재작성이 원본 줄을 찾지 못했다 (rc=$?)"
    fleet_backlog_unlock
    fleet_log "dispatch $lane: $id park — $park"
    return 0
  fi

  # ADMISSION. Three clauses fail closed — lane occupancy, the fleet ceiling
  # and the 5h window — because none of them may open on a machine whose state
  # cannot be read.
  # (5) the sensor's brake.
  if [ -z "$clause" ] && [ "$verdict" = "제동" ]; then clause=brake; fi
  if [ -z "$clause" ]; then
    # (6) ONE probe for this dispatch; an enumeration failure closes the lane.
    #     Then the markers: a live marker of this lane, or as many live markers
    #     as the fleet ceiling, refuses.
    probe=$(LANE_PROBE_HORIZON_SECONDS="$FLEET_LANE_HORIZON_SECONDS" bash "$LANE_PROBE" 2>/dev/null) || rc=$?
    if [ "$rc" != "0" ]; then
      clause=lane; detail=probe-failed
    else
      census=$(printf '%s\n' "$probe" | fleet_census_parse "$inv")
      [ -n "$census" ] || census='[]'
      busy=$(fleet_busy_count "$lane" "$census")
      if [ "${busy#* }" -gt 0 ]; then
        clause=lane; detail=occupied
      elif [ "${busy%% *}" -ge "$FLEET_TARGET_CONCURRENCY" ]; then
        clause=lane; detail=ceiling
      else
        # (7) the same probe output: this lane's own rows, plus every row no
        #     account can be attributed to.
        occ=$(printf '%s' "$census" \
              | jq --arg l "$lane" 'map(select((.status == "도는중" or .status == "판정 불가") and (.lane == $l or .lane == "unknown"))) | length')
        [ "${occ:-0}" -lt "$FLEET_LANE_OCCUPANCY_MAX" ] || { clause=lane; detail=occupied; }
      fi
    fi
  fi
  if [ -z "$clause" ]; then
    # (8) the 5h window of this account's group, judged now from usage.json.
    #     Absent, stale or unreadable input blocks. A mismatch or a bad login
    #     here means the file was republished since step 2: the same answer as
    #     an ineligible lane, reached inside the lock.
    ctx=$(fleet_context "$(fleet_now)" "$inv")
    res=$(fleet_cap_eval "$ctx" "$dirs" "$lane" | jq -r '.result')
    case "$res" in
      pass) ;;
      mismatch|login)
        fleet_backlog_unlock
        fleet_log "dispatch $lane: 부적격 — $res (사용량 파일이 다시 발행됐다; 아무것도 띄우지 않는다)"
        return 0 ;;
      *) clause=window; detail="$res" ;;
    esac
  fi
  if [ -z "$clause" ]; then
    # (9) the fleet arm is not braking: capacity >= burn OR candidates exist;
    #     unknown capacity passes. Same conjunction as the ladder's rung 2,
    #     over the same eligible accounts.
    if jq -en --argjson s "$state" '$s != null and $s.fleet_capacity != null and $s.burn_4h != null
                                      and $s.fleet_capacity < $s.burn_4h and $s.candidates_empty == true' >/dev/null 2>&1; then
      clause=burn
    fi
  fi
  if [ -n "$clause" ]; then
    line=$(printf '%s' "$rec" | jq -c --arg at "$iso" --arg v "$verdict" --arg c "$clause" \
            '.last_refusal_at = $at | .last_refusal_verdict = $v | .last_refusal_clause = $c')
    fleet_backlog_rewrite "$head" "$line" || fleet_log "dispatch $lane: $id 의 거부 재작성이 원본 줄을 찾지 못했다 (rc=$?)"
    fleet_backlog_unlock
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$iso" "$lane" "$clause" "$verdict" "$id" "$detail" >> "$PACE_ROOT/refusals.tsv"
    fleet_log "dispatch $lane: $id 거부 — 절 $clause/$detail (판정 $verdict)"
    return 0
  fi

  # (10) THE FLIP IS THE CLAIM. The record says which lane took it and when,
  # so a `dispatched` record can be told apart from another lane's, and a
  # failed swap means the head was taken between this lane's read and now —
  # nothing is started on it. The marker goes down before the lock is released,
  # so the next lane to take the lock counts this run.
  line=$(printf '%s' "$rec" | jq -c --arg l "$lane" --arg at "$iso" \
          '.status = "dispatched" | .dispatched_lane = $l | .dispatched_at = $at')
  if ! fleet_backlog_rewrite "$head" "$line"; then
    fleet_backlog_unlock
    fleet_log "dispatch $lane: $id 는 이미 다른 레인이 집었다 (원본 줄이 없다) — 기동하지 않는다"
    return 0
  fi
  fleet_busy_write "$lane" "$run_id" || fleet_log "dispatch $lane: 실행 표지를 쓰지 못했다 — 이 런은 프로브에 행이 생기기 전까지 상한에 세어지지 않는다"
  fleet_backlog_unlock

  # THE FOUR PREPARATION STEPS, IN THIS ORDER: the report stub, then one
  # snapshot so the run directory exists, THEN the watcher — a watcher started
  # before the directory exists reads its absence as "the run went away" and
  # exits quietly — and THEN the CI poller, which reads the directory the same
  # way and so carries the same ordering debt. Then `run.sh` in the foreground,
  # and this job waits.
  ledger="$wt/docs/pipeline-run/$run_id.md"
  if [ -n "$wt" ] && [ ! -e "$ledger" ]; then
    mkdir -p "$(dirname "$ledger")"
    printf '# 파이프라인 런 %s\n\n런 id: %s · 파견 레인: %s · 파견 시각: %s\n' "$run_id" "$run_id" "$lane" "$iso" > "$ledger"
  fi
  CLAUDE_CONFIG_DIR="$home" bash "$FLEET_DIR/gate.sh" snapshot --manifest "$manifest" >/dev/null || true
  mkdir -p "$run_dir"
  bash "$FLEET_DIR/watch.sh" --run-dir "$run_dir" --ledger "$ledger" --stall 1200 --interval 60 --after-stage 120 --run-open 300 > "$run_dir/watch.log" 2>&1 < /dev/null &
  # THE POLLER BELONGS ON THIS PATH, NOT ONLY ON THE SUPERVISED ONE. The CI
  # merge refusal it feeds is the only thing standing between a red check and a
  # merged branch, and this timer-driven path is the one with no session and no
  # terminal — the path where nobody would notice the refusal never fired. It
  # writes nothing to the ledger itself; the gate transcribes `checks.observed`
  # on its next act. A run with no poller leaves no `checks` row, and no row
  # reads as "nothing recorded", which the gate passes — so the absence is
  # byte-identical to a green night. Interval is pinned to 60 for the same
  # reason the watcher's is: they are one threshold, not two.
  bash "$FLEET_DIR/checks.sh" --run-dir "$run_dir" --ledger "$ledger" --manifest "$manifest" --interval 60 > "$run_dir/checks.log" 2>&1 < /dev/null &
  fleet_log "dispatch $lane: $id 기동 — run $run_id (매니페스트 $manifest)"
  CLAUDE_CONFIG_DIR="$home" bash "$FLEET_DIR/run.sh" --manifest "$manifest" || rc=$?
  line2=$(printf '%s' "$line" | jq -c '.status = "done"')
  fleet_backlog_rewrite_locked "$line" "$line2" || fleet_log "dispatch $lane: $id 의 done 재작성이 실패했다 (rc=$?) — 레코드는 dispatched 로 남는다"
  fleet_log "dispatch $lane: $id 종료 rc=$rc"
  return 0
}

# ===========================================================================
# AGENT — launchd registration
# ===========================================================================

fleet_labels() {
  # fleet_labels <inventory-json> — sensor first, then one dispatch label per
  # account in the label set, in inventory order.
  local inv="$1" id
  printf '%s.sensor\n' "$FLEET_LABEL_PREFIX"
  fleet_label_ids "$inv" "$(fleet_dirs_json "$inv")" | while IFS= read -r id; do
    printf '%s.dispatch.%s\n' "$FLEET_LABEL_PREFIX" "$id"
  done
}
fleet_glob_ids() {
  # The ids of every dispatch plist on disk, one per line, whatever installed
  # them. A name that is not a well-formed id is reported once on stderr and
  # never handed to launchctl.
  local f id
  for f in "$LAUNCH_AGENTS_DIR/$FLEET_LABEL_PREFIX".dispatch.*.plist; do
    [ -e "$f" ] || continue
    id=${f##*/}; id=${id#"$FLEET_LABEL_PREFIX".dispatch.}; id=${id%.plist}
    case "$id" in
      ''|-*|*[!a-z0-9-]*|sensor) fleet_log "형식이 맞지 않는 파견 plist 이름은 건드리지 않는다: $f" ;;
      *) printf '%s\n' "$id" ;;
    esac
  done
}
fleet_orphan_ids() {
  # fleet_orphan_ids <inventory-json> — dispatch plists on disk whose id is not
  # in the current label set.
  local inv="$1" set id
  set=$(fleet_labels "$inv")
  fleet_glob_ids | while IFS= read -r id; do
    printf '%s\n' "$set" | grep -qxF "$FLEET_LABEL_PREFIX.dispatch.$id" || printf '%s\n' "$id"
  done
}
fleet_label_universe() {
  # fleet_label_universe <inventory-json> — the sensor, the current label set
  # and every dispatch plist on disk, without repeats. Uninstall acts on this:
  # an account dropped from the inventory still has a plist that wakes.
  local inv="$1" id
  {
    fleet_labels "$inv"
    fleet_glob_ids | while IFS= read -r id; do printf '%s.dispatch.%s\n' "$FLEET_LABEL_PREFIX" "$id"; done
  } | awk '!seen[$0]++'
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
  local label n_files=0 n_loaded=0 n=0 h lane dst inv bad orphans labels
  [ -n "$LAUNCHCTL" ] || fleet_die "launchctl 을 찾을 수 없다 (FLEET_LAUNCHCTL 로 지정할 수 있다)"
  inv=$(fleet_inventory_json)
  [ "$(printf '%s' "$inv" | jq -r '.state')" = "valid" ] \
    || fleet_die "cc-lane 인벤토리가 없거나 깨졌다 ($(fleet_inventory_path 2>/dev/null || printf '경로 유도 실패')) — 레이블 집합이 비어 install 을 거부한다"
  # Every refusal below comes before the first plist is written, so a refused
  # install leaves none behind.
  bad=$(fleet_label_violations "$inv")
  if [ -n "$bad" ]; then
    fleet_die "레이블이 될 계정이 형식을 어긴다 — install 을 거부한다: $(printf '%s' "$bad" | tr '\n' ';')"
  fi
  labels=$(fleet_labels "$inv")
  [ "$(printf '%s\n' "$labels" | grep -c '\.dispatch\.' || true)" -gt 0 ] \
    || fleet_die "레이블 집합이 비었다 (무인 허용·대화형 예약 아님·디렉터리 있음인 계정이 없다) — install 을 거부한다"
  orphans=$(fleet_orphan_ids "$inv")
  if [ -n "$orphans" ]; then
    fleet_die "레이블 집합에 없는 파견 plist 가 있다: $(printf '%s' "$orphans" | tr '\n' ' ') — fleet.sh agent uninstall 로 지운 뒤 다시 설치한다"
  fi
  for label in $labels; do
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
  for label in $labels; do
    dst="$LAUNCH_AGENTS_DIR/$label.plist"
    fleet_label_loaded "$label" && { "$LAUNCHCTL" bootout "gui/$(id -u)/$label" >/dev/null 2>&1 || true; }
    # One render call per subcommand, whatever the number of labels: the pin
    # lint counts these two call sites.
    case "$label" in
      *.sensor) fleet_render_plist "$label" sensor "" "" "$FLEET_START_INTERVAL" "$dst" ;;
      *.dispatch.*)
        lane=${label##*.dispatch.}
        h=$(printf '%s' "$inv" | jq -r --arg i "$lane" '.accounts[] | select(.id == $i) | .config_dir')
        fleet_render_plist "$label" dispatch "$lane" "$h" "$FLEET_DISPATCH_START_INTERVAL" "$dst" ;;
    esac
    "$LAUNCHCTL" bootstrap "gui/$(id -u)" "$dst" || fleet_die "등록 실패: $label"
    fleet_log "등록 $label"
  done
  # Zero eligible lanes this tick is not a reason to refuse — eligibility moves
  # with group bindings and needs no reinstall — but it is said.
  if [ "$(fleet_state_read | jq -r '[(.seats // [])[] | select(.eligible == true)] | length' 2>/dev/null || printf '?')" = "0" ]; then
    fleet_log "경고: 마지막 센서 틱 기준으로 적격 레인이 없다 — fleet.sh agent status 로 사유를 본다"
  fi
}
fleet_agent_uninstall() {
  local label inv universe
  [ -n "$LAUNCHCTL" ] || fleet_die "launchctl 을 찾을 수 없다 (FLEET_LAUNCHCTL 로 지정할 수 있다)"
  inv=$(fleet_inventory_json)
  universe=$(fleet_label_universe "$inv")
  for label in $universe; do
    fleet_label_running "$label" && fleet_die "레이블 $label 이 도는 중이다 — uninstall 을 거부한다"
  done
  for label in $universe; do
    fleet_label_loaded "$label" && { "$LAUNCHCTL" bootout "gui/$(id -u)/$label" >/dev/null 2>&1 || true; }
    rm -f "$LAUNCH_AGENTS_DIR/$label.plist"
    fleet_log "해제 $label"
  done
}
fleet_agent_status() {
  local label now hb st age inv orphans f n_live=0 id
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
  # Registration per label, then the lane's eligibility as the sensor last
  # published it — the reason is printed, never recomputed here.
  inv=$(fleet_inventory_json)
  orphans=$(fleet_orphan_ids "$inv")
  for label in $(fleet_label_universe "$inv"); do
    if [ -n "$LAUNCHCTL" ] && fleet_label_loaded "$label"; then
      if fleet_label_running "$label"; then printf '%s: 등록됨 (running)' "$label"; else printf '%s: 등록됨' "$label"; fi
    else
      printf '%s: 미등록' "$label"
    fi
    case "$label" in
      *.dispatch.*)
        id=${label##*.dispatch.}
        if printf '%s\n' "$orphans" | grep -qxF "$id"; then
          printf ' — 고아 (레이블 집합에 없다; uninstall 로 지운다)'
        elif [ -n "$st" ]; then
          printf '%s' "$st" | jq -r --arg i "$id" '
            ([.seats[]? | select(.id == $i)] | .[0]) as $s
            | if $s == null then " — 적격성: 센서 기록 없음"
              elif $s.eligible == true then " — 적격"
              else " — 부적격: \($s.reason // "?")" end' | tr -d '\n'
        else
          printf ' — 적격성: 센서 기록 없음'
        fi ;;
    esac
    printf '\n'
  done
  if [ -n "$st" ] && [ "$(printf '%s' "$st" | jq -r '[(.seats // [])[] | select(.eligible == true)] | length')" = "0" ]; then
    printf '경고: 적격 레인이 없다 — 이 틱에는 아무 레인도 띄우지 않는다\n'
  fi
  for f in "$PACE_ROOT/busy"/*; do
    [ -f "$f" ] || continue
    if fleet_busy_live "$f" '[]'; then
      n_live=$(( n_live + 1 ))
      printf '실행 표지: %s (런 %s)\n' "${f##*/}" "$(sed -n '3p' "$f")"
    fi
  done
  printf '살아 있는 실행 표지: %s / 상한 %s\n' "$n_live" "$FLEET_TARGET_CONCURRENCY"
}

main() {
  case "${1:-}" in
    sensor)   fleet_sensor ;;
    dispatch) [ -n "${2:-}" ] || fleet_usage "dispatch <id> — 레인(인벤토리 id)이 필요하다"; fleet_dispatch "$2" ;;
    agent)
      case "${2:-}" in
        install)   fleet_agent_install ;;
        uninstall) fleet_agent_uninstall ;;
        status)    fleet_agent_status ;;
        *) fleet_usage "agent install|uninstall|status" ;;
      esac ;;
    *) fleet_usage "sensor | dispatch <id> | agent install|uninstall|status" ;;
  esac
}

main "$@"
