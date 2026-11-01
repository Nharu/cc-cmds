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
# single-writer rule above. One process does outlive this job all the same: the
# first `snapshot` of a new run passes the gate's run-open branch, which starts
# the run dashboard's server in its own session, and that server keeps serving
# after the dispatch job has exited. The start lives in the gate, not here.
#
# A WAITING JOB ALSO WATCHES THE BASE BRANCH, AND MAY START ONE REPAIR RUN. Beside
# the watcher and the CI poller, `fleet_start_watch` starts a master observer
# child (`fleet.sh master-watch`) that runs the master stage every
# FLEET_MASTER_INTERVAL_SECONDS while the job waits, so a host whose every lane
# holds a run still keeps its base-branch readings fresh. When a `pending`
# repair record is there, that child starts `fleet.sh repair-run` in the
# background — the one backgrounded launch of this file's own subcommands, and
# it stays inside the job's process group. `repair-run` claims the record under
# `backlog.lock` and runs `run.sh` in ITS foreground through the same function
# the backlog dispatch uses, so the repair run lives exactly as long as that
# process. The job's main process, once its own run is over, rewrites its
# record, drops its own marker and then waits — at most
# FLEET_REPAIR_WAIT_MAX_SECONDS — while a repair marker naming it as the job is
# alive. Launchd therefore never tears the group down under a repair run, and
# nothing outlives the job.
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
#   fleet.sh master-watch <id> <job pid> <job fingerprint>
#                                       # the master observer child of a waiting job
#   fleet.sh repair-run <id> <job pid>  # claim one repair record and run it, blocking
#   fleet.sh agent install|uninstall|status
#
# Files (all under PACE_ROOT = ${XDG_STATE_HOME:-$HOME/.local/state}/cc-cmds/pace):
#   state.json             the last published tick (schema `cc-pace-state v1`)
#   verdict-history.jsonl  one record per verdict change (`cc-pace-verdict v1`)
#   seat-bindings.jsonl    one record per observed re-binding of a seat
#   backlog.jsonl          deferred launches (`cc-pace-backlog v1`); two writers
#                          append — the kickoff seat, and the master stage,
#                          which appends `kind: master-repair` records only —
#                          and the dispatcher rewrites status; never this
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
#                          pid, its start fingerprint, run id; a repair run's
#                          marker adds `master-repair` and the waiting job's pid
#   master/<o>__<n>__<b>.json
#                          one base-branch reading per watched (repository,
#                          base branch) pair (`cc-master-state v1`), the three
#                          pieces percent-encoded as the gate reads them;
#                          `<same>.settled` holds the epoch of its last settled
#                          observation
#   master/watch.<pid>/    the observer child's claim on the job <pid>
#   master.lock/           the master stage's lock (mkdir), holding its pid
#   master-repair.off      the repair switch: present and empty turns repair
#                          runs off for every repository, one `owner/name` a
#                          line turns them off for those
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
#   FLEET_GH               the `gh` the master stage's read wrapper calls
#   FLEET_MASTER_INTERVAL_TEST_SECONDS
#                          a shorter observer period (never a longer one); the
#                          skip window shrinks to half of it
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
readonly FLEET_REENTRY_CALLS_MAX=12             # router-shift calls that launched no shift, at most, in one boot-time re-entry chain
readonly FLEET_REENTRY_QUICK_SECONDS=60         # a `대기` call back sooner than this with no launch is a quick return
readonly FLEET_MASTER_INTERVAL_SECONDS=120      # the observer child runs the master stage this often
readonly FLEET_MASTER_BUDGET_SECONDS=60         # one master stage, every pair together, at most this long
readonly FLEET_MASTER_SKIP_SECONDS=60           # a pair whose reading is younger than this is skipped (half the interval)
readonly FLEET_MASTER_LOCK_STALE_SECONDS=120    # a master.lock this old, or with a dead pid, is broken (twice the budget)
readonly FLEET_MASTER_FIX_PR_HOLD_SECONDS=7200  # a person's fix PR holds an event's repair run this long, once per event
readonly FLEET_MASTER_LOG_MAX_BYTES=8388608     # one job log is cut here (the gate's match act holds the same)
readonly FLEET_MASTER_GH_SECONDS=20             # one `gh api` read is abandoned after this long
readonly FLEET_MASTER_SETTLED_MAX_SECONDS=3600  # no settled reading for this long -> the reading stops being rewritten
readonly FLEET_REPAIR_SEATS=1                   # repair runs alive at once, beside the ceiling and lane occupancy
readonly FLEET_REPAIR_WAIT_MAX_SECONDS=22200    # a job waits on its repair run at most this long (the run's deadline + 600)
# The burn calibration is a literal by decision, and it is not an integer, so the
# threshold lint does not own it: 0.104 %p of weekly quota per million weighted
# tokens over a 4h window.
readonly FLEET_BURN_PP_PER_MWT=0.104

readonly FLEET_STATE_SCHEMA='cc-pace-state v1'
readonly FLEET_VERDICT_SCHEMA='cc-pace-verdict v1'
readonly FLEET_BACKLOG_SCHEMA='cc-pace-backlog v1'
readonly FLEET_MASTER_SCHEMA='cc-master-state v1'
readonly FLEET_REPAIR_KIND='master-repair'
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
  # one id per line in inventory order: unattended enabled and not interactive
  # reserved, or enrolled for interactive-seat lending (the lending lane, for as
  # long as the enrolment stands), and a well-formed id, a config dir that
  # renders safely and exists.
  printf '%s' "$1" | jq -r --argjson dirs "$2" --arg re "$FLEET_ID_RE" '
    .accounts[] | select(((.unattended == "enabled" and .interactive_reserved == false)
        or (.interactive_lending == "auto" and .interactive_reserved == true and .unattended == "disabled"))
      and (.id | test($re)) and .id != "sensor" and ((.config_dir | test("[|&\\\\<>]")) | not)
      and (.id as $i | any($dirs[]; . == $i))) | .id'
}
fleet_label_violations() {
  # fleet_label_violations <inventory-json> — the accounts that WOULD be
  # labelled but cannot be: a malformed id, or a config dir carrying a character
  # the plist render would read as syntax. One `id: why` line each.
  printf '%s' "$1" | jq -r --arg re "$FLEET_ID_RE" '
    .accounts[] | select((.unattended == "enabled" and .interactive_reserved == false)
        or (.interactive_lending == "auto" and .interactive_reserved == true and .unattended == "disabled"))
    | if ((.id | test($re)) | not) or .id == "sensor" then "\(.id): id 형식"
      elif (.config_dir | test("[|&\\\\<>]")) then "\(.id): config_dir 금지 문자"
      else empty end'
}
fleet_lend_ids() {
  # fleet_lend_ids <inventory-json> — the ids enrolled for interactive-seat
  # lending, as a JSON array in inventory order, by the router's own row
  # predicate. An absent or broken inventory carries no accounts and so none.
  printf '%s' "$1" | jq -c "$(route__jq_lib)"'
    [(.accounts // [])[] | select(type == "object" and rt_enrolled) | .id]'
}
fleet_lend_lane_raw() {
  # fleet_lend_lane_raw <lane> — rc 0 when the inventory FILE, read as it is
  # whatever the router's check says of it, enrols <lane> for lending. It tells
  # a lending lane under a broken inventory from any other lane, which cannot
  # be told from `fleet_inventory_json` once it has dropped every account. A
  # file that does not parse enrols nobody.
  local f
  f=$(fleet_inventory_path) || return 1
  [ -r "$f" ] || return 1
  jq -e --arg i "$1" "$(route__jq_lib)"'
    any((.accounts? // [])[]?; type == "object" and .id == $i and rt_enrolled)' "$f" >/dev/null 2>&1
}
fleet_lend_home() {
  # fleet_lend_home <inventory-json> <dir> — rc 0 when <dir>, one trailing `/`
  # aside, is the config dir of a row enrolled for lending.
  printf '%s' "$1" | jq -e --arg d "$2" "$(route__jq_lib)"'
    any((.accounts // [])[]; type == "object" and rt_enrolled
        and ((.config_dir | tostring | if endswith("/") then .[0:-1] else . end) == $d))' >/dev/null 2>&1
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
#
# A row enrolled for lending is reserved and disabled for unattended work by
# definition, so neither of those reads `not-labelled`, `not-enabled` or
# `group-reserved` on it. What closes it is the router's lending admission,
# named by its cause: the 7-day ceiling, the 5h cap, or anything else that
# keeps lending shut.
def fl_lend_reason($why):
  if $why == "ceiling" then "lend-ceiling"
  elif $why == "five-hour-cap" then "lend-cap"
  else "lending-closed" end;
def fl_reason($p; $a; $dirs; $re):
  rt_av($p; $a.id) as $av
  | ($a | rt_enrolled) as $lend
  | if (($a.id | test($re)) | not) or $a.id == "sensor" or (($lend | not) and $a.interactive_reserved != false)
       or ($a.config_dir | test("[|&\\\\<>]")) then "not-labelled"
    elif ($lend | not) and $a.unattended != "enabled" then "not-enabled"
    elif (any($dirs[]; . == $a.id) | not) then "no-config-dir"
    elif $av == null then "inventory-broken"
    elif ($lend | not) and $av.group_reserved then "group-reserved"
    elif $av.mismatch then "mismatch"
    elif $av.login_bad then "login"
    elif ($lend | not) and ($av.borrowed // null) != null then "borrowed"
    elif $av.class == "X" then "exhausted"
    elif (rt_new_ok($av) | not) then (if $lend then fl_lend_reason($av.lend.why) else "exhausted" end)
    else null end;

# The allocation fields say what this account's usage is, not whether the fleet
# may launch on it: they are carried whenever the usage row is confirmed to be
# this account's, eligible or not, and null otherwise — a reader that gets null
# reads "unknown" and closes. `session_pct` is the reset-adjusted basis point
# over 100, never a second rounding of it. `$ceil` is the published lending
# ceiling of a row enrolled for lending and null on every other row: what such
# a row has left this week is what remains under the ceiling, the same figure
# the router ranks its lending tier by.
def fl_alloc($c; $file; $w5; $w7; $why; $ceil):
  if $file == "ok" and ($w5.result | IN("pass", "over")) and ((($why // "") | IN("mismatch", "login", "inventory-broken")) | not)
  then
    (if ($w7.result | IN("pass", "over")) then
       (if $ceil != null then [($ceil - $w7.ueff) / 100, 0] else [100 - ($w7.ueff / 100), 0] end | max) as $rem
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
# (`w5`, `group`, `horizon_h`, `lend`) dropped before publishing. A lending row
# with no numeric ceiling in its decision has nothing to lend, so its ceiling
# reads as zero rather than as the whole week.
def fl_seat_row($c; $p; $file; $a; $dirs; $re; $skew; $pct):
  fl_win($c; $file; $a.id; "five_hour"; $skew; $pct) as $w5
  | fl_win($c; $file; $a.id; "seven_day"; $skew; $pct) as $w7
  | ($a | rt_enrolled) as $lend
  | (if $c.inventory.state == "valid" then fl_reason($p; $a; $dirs; $re) else "inventory-broken" end) as $why
  | (if $lend then ((rt_av($p; $a.id).lend.dec.ceiling_bp? // null) | if type == "number" then . else 0 end)
     else null end) as $ceil
  | fl_alloc($c; $file; $w5; $w7; $why; $ceil) as $al
  | {id: $a.id, home: $a.config_dir,
     org: ([rt_uaccts($c)[] | select(.id == $a.id)] | .[0].org_hash // null),
     eligible: ($why == null), reason: $why,
     allow: $al.allow, session_pct: $al.session_pct, ttr: $al.ttr, horizon_h: $al.horizon_h,
     w5: $w5, group: rt_group_of(rt_orgs($c); $a.id), lend: $lend};
JQ
}
fleet__lib() { route__jq_lib; fleet__jq_defs; }

fleet_context() {
  # fleet_context <now> <inventory-json> [<lease-table-json>] — the router
  # context this file builds for itself: the inventory, the usage file in the
  # router's normal form, the borrow record, a lease table, the router's own
  # config (cap = the 5h ceiling in basis points) and an integer now.
  # `route_gather_context` is not used: it leans on the driver's globals. The
  # lease table is empty unless the caller passes the router's reading of the
  # real one — only a lending lane's dispatch does, since lending admission
  # counts the reservations of live leases and every other judgement here keeps
  # the empty table it always had.
  local now="$1" inv="$2" leases="${3:-}" usage borrow bpath cfg
  [ -n "$leases" ] || leases='{"state":"valid","items":[],"corrupt":[]}'
  usage=$(route_usage_read "$USAGE_FILE" "$now" 2>/dev/null) || usage='{"state":"corrupt"}'
  [ -n "$usage" ] || usage='{"state":"corrupt"}'
  if bpath=$(route__borrow_path); then
    borrow=$(route_borrow_read "$bpath") || borrow='{"state":"corrupt"}'
  else
    borrow='{"state":"corrupt"}'
  fi
  cfg=$(route__config_json "$(( FLEET_SESSION_WINDOW_PCT_MAX * 100 ))")
  jq -cn --argjson now "$now" --argjson inv "$inv" --argjson usage "$usage" --argjson borrow "$borrow" --argjson cfg "$cfg" \
     --argjson leases "$leases" '
    {now: $now, request: {}, inventory: $inv, usage: $usage, frames: [],
     leases: $leases, borrow: $borrow, config: $cfg, seat: {config_dir: null}}'
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
fleet_lend_leases() {
  # fleet_lend_leases — the router's reading of the real lease table, the same
  # call `route_gather_context` makes. rc 1 when it cannot be read or reads as
  # corrupt: lending admission counts what live leases reserve, and a table it
  # cannot count is not an empty one.
  local t
  t=$(route__table_read "$PACE_ROOT/leases" "$(boot_epoch 2>/dev/null || true)" 2>/dev/null) || return 1
  printf '%s' "$t" | jq -e '.state == "absent" or .state == "valid"' >/dev/null 2>&1 || return 1
  printf '%s' "$t"
}
fleet_lend_driver_ctx() {
  # fleet_lend_driver_ctx <ctx> <dirs> <lane> — <ctx> with one more live grant
  # on <lane>: the reservation of the run's driver and shift sessions, which
  # spend on the lane's account outside every stage lease. It is added to the
  # table as the router has finished reading it, so liveness is not recomputed
  # over it, and it never passes the lease-file check it would fail. Its size
  # is one stage's default reservation from the router's own config.
  fleet_jq "$1" "$2" '
    $c | .leases.items = ((.leases.items // []) + [{kind: "grant", account: $id, live: true,
      run_id: "fleet-driver", lineage: "fleet-driver", reservation_bp: rt_res($c; rt_group_of(rt_orgs($c); $id))}])' \
    --arg id "$3"
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
  # A lending row goes last, the order the router ranks its lending tier in;
  # with no row enrolled the order is the inventory order as before. Its lane is
  # not an active lane either: the lending lane runs beside the ceiling, and a
  # run on it must not hold the unattended lanes off 가속.
  | ([$rows[] | select(.lend | not)] + [$rows[] | select(.lend)]) as $rows
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
  # A lending row stays out of the capacity as it stays out of the burn: its
  # home is reserved, so the burn scan never reads it, and an allowance with no
  # burn beside it would only push the brake back.
  | ($rows | map(select(.eligible and (.lend | not))) | group_by(.group)
     | map(.[0].w5.rep as $rep
           | (([$rows[] | select(.id == $rep) | .allow] | .[0]) // ([.[] | .allow | select(. != null)] | .[0])))
     | map(select(. != null))) as $contrib
  | (if $tok and ($contrib | length) > 0 then ($contrib | add) else null end) as $cap
  | ($rows | map({id, home, org, eligible, reason, allow, session_pct, ttr, burn_4h})) as $seats
  | (if $tok and $bps != null
     then ([rt_uaccts($c)[] | . as $u | select(all($rows[]; .id != $u.id))
            | fl_alloc($c; $file; fl_win($c; $file; $u.id; "five_hour"; $skew; $pct);
                       fl_win($c; $file; $u.id; "seven_day"; $skew; $pct); null; null) as $al
            | select($al.allow != null and $al.allow >= $bps and ($al.session_pct // 100) < $pct)
            | {org: ($u.org_hash // null), allow: $al.allow, horizon_h: ($al.horizon_h // 0)}]
           | sort_by(-.horizon_h)
           | map({home: (($rows | map(select(.allow == null or .allow < $bps)) | .[0].home) // null),
                  org, allow, horizon_h}))
     else [] end) as $cands
  | ($cands | length == 0) as $cempty
  | ($census | map(select(.status == "도는중" or .status == "판정 불가"))) as $occ
  | ([$rows[] | select(.eligible and (.lend | not)) | .id]
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
  #
  # A REPAIR RECORD IS NEVER THIS HEAD. With a first argument `repair` the
  # head is the oldest pending `kind: master-repair` record instead; without
  # one, those records are skipped, so a repair run is admitted only through
  # the repair admission and never takes an ordinary seat.
  local f="$PACE_ROOT/backlog.jsonl" line best="" best_at="" at want="${1:-}"
  [ -r "$f" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    [ "${#line}" -le "$FLEET_BACKLOG_RECORD_MAX" ] || continue
    at=$(printf '%s' "$line" | jq -r --arg schema "$FLEET_BACKLOG_SCHEMA" --arg k "$FLEET_REPAIR_KIND" --arg w "$want" \
          'select(.schema == $schema and .status == "pending"
                  and ((.kind == $k) == ($w == "repair"))) | .enqueued_at // empty' 2>/dev/null || true)
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
fleet_busy_is_repair() {
  # fleet_busy_is_repair <marker> — rc 0 for a repair run's marker: its fourth
  # line is FLEET_REPAIR_KIND. Readers of the first three lines never see it.
  [ "$(sed -n '4p' "$1" 2>/dev/null)" = "$FLEET_REPAIR_KIND" ]
}
fleet_busy_count() {
  # fleet_busy_count <lane> <census-json> [<lend-ids-json>] — `<all> <same-lane>
  # <not-lending> <repair>` live markers, the third leaving out the markers of
  # the lanes the JSON array names. With no array it equals the first. Called
  # under the claim lock, so a dead marker (dead or reused pid, and no live row
  # for its run) is removed here.
  #
  # A REPAIR MARKER COUNTS ONLY IN THE FOURTH FIGURE. The repair run has a seat
  # of its own (FLEET_REPAIR_SEATS) beside the ceiling and lane occupancy, so
  # while it runs the ordinary backlog keeps every seat it had.
  local lane="$1" census="$2" lend="${3:-[]}" f base all=0 same=0 non=0 rep=0
  for f in "$PACE_ROOT/busy"/*; do
    [ -f "$f" ] || continue
    base=${f##*/}
    if fleet_busy_live "$f" "$census"; then
      if fleet_busy_is_repair "$f"; then rep=$(( rep + 1 )); continue; fi
      all=$(( all + 1 ))
      [ "${base%.*}" = "$lane" ] && same=$(( same + 1 ))
      printf '%s' "$lend" | jq -e --arg l "${base%.*}" 'any(.[]; . == $l)' >/dev/null 2>&1 || non=$(( non + 1 ))
    else
      rm -f "$f"
    fi
  done
  printf '%s %s %s %s' "$all" "$same" "$non" "$rep"
}
fleet_busy_repair_live() {
  # fleet_busy_repair_live [<job pid>] — the live repair markers, one path a
  # line; with a pid, only those whose fifth line names that job. Judged on the
  # pid and its fingerprint alone: the marker's owner is the process waiting on
  # the repair run, so it is alive exactly as long as the run.
  local f pid fp
  for f in "$PACE_ROOT/busy"/*; do
    [ -f "$f" ] && fleet_busy_is_repair "$f" || continue
    [ -z "${1:-}" ] || [ "$(sed -n '5p' "$f")" = "$1" ] || continue
    pid=$(sed -n '1p' "$f" 2>/dev/null | tr -d '[:space:]' || true); fp=$(sed -n '2p' "$f" 2>/dev/null || true)
    if [ -n "$pid" ] && [ -n "$fp" ] && kill -0 "$pid" 2>/dev/null \
       && [ "$(TZ=UTC0 cc_proc_fingerprint "$pid")" = "$fp" ]; then
      printf '%s\n' "$f"
    fi
  done
}
fleet_busy_write() {
  # fleet_busy_write <lane> <run-id> [<job pid>] — this process's marker, by
  # temp file and rename so a reader never sees a partial one. With a job pid
  # it is a repair run's marker: `master-repair` on line four and the pid of the
  # dispatch job that waits on it on line five.
  local f="$PACE_ROOT/busy/$1.$$"
  mkdir -p "$PACE_ROOT/busy"
  if [ -n "${3:-}" ]; then
    printf '%s\n%s\n%s\n%s\n%s\n' "$$" "$(TZ=UTC0 cc_proc_fingerprint "$$")" "$2" "$FLEET_REPAIR_KIND" "$3" \
      | fleet_write_atomic "$f" || return 1
  else
    printf '%s\n%s\n%s\n' "$$" "$(TZ=UTC0 cc_proc_fingerprint "$$")" "$2" | fleet_write_atomic "$f" || return 1
  fi
  FLEET_BUSY_MARK="$f"
}

fleet_label_homes_json() {
  # fleet_label_homes_json <inventory-json> <dirs-json> — [{id, home}] of the
  # label set exactly as fleet_label_ids draws it, whatever the router thinks
  # of each account this tick; home has one trailing `/` stripped for
  # comparison. A wider set would hold a head for an account whose own lane
  # ends before the lock (not-enabled, no-config-dir) and so never takes it.
  local ids
  ids=$(fleet_label_ids "$1" "$2" | jq -R -s -c 'split("\n") | map(select(. != ""))')
  printf '%s' "$1" | jq -c --argjson ids "$ids" '
    [.accounts[] | select(.id as $i | any($ids[]; . == $i))
     | {id, home: (.config_dir | if endswith("/") then .[0:-1] else . end)}]'
}

fleet_start_watch() {
  # fleet_start_watch <config home> <plugin dir> <manifest> <run dir> <ledger> —
  # one snapshot so the run directory exists, then the watcher, then the CI
  # poller, both in the background. The backlog dispatch passes the label's
  # account home and this checkout; a boot-time re-entry passes the run's own
  # `config-dir` and the directory of the run's pinned gate, because the run
  # it re-enters was opened there and not here. ONE FUNCTION, SO ONE WATCHER
  # LAUNCH LINE in this file, which `lint-watch-threshold-pins.sh` holds to one.
  # The optional sixth argument is the re-entry marker for the snapshot, which
  # is a gate call of the re-entry like any other; the watcher and the poller
  # do not carry it. A seventh argument `poller` starts the poller alone: a
  # re-entry whose relay came back because the poller died restarts that one
  # and not a second watcher beside the first. A seventh argument `no-master`
  # starts everything but the master observer child: a repair run started by
  # an observer child is watched by that child already.
  #
  # THE OBSERVER CHILD is `fleet.sh master-watch`, from this copy of the file
  # and not the run's pinned gate directory, on the lane this job dispatches
  # for (FLEET_LANE). It is started once per job — its own claim directory
  # refuses a second — and ends when this job's process is gone. The job's
  # fingerprint is taken as `cc_holder_is_live` takes it, with no TZ of its own:
  # the child inherits this environment, so both sides read one clock zone.
  local home="$1" pdir="$2" manifest="$3" run_dir="$4" ledger="$5" mark="${6:-}" only="${7:-}"
  if [ "$only" != "poller" ]; then
    CLAUDE_CONFIG_DIR="$home" CC_PIPELINE_REENTRY="$mark" bash "$pdir/gate.sh" snapshot --manifest "$manifest" >/dev/null || true
    mkdir -p "$run_dir"
    bash "$pdir/watch.sh" --run-dir "$run_dir" --ledger "$ledger" --stall 1200 --interval 60 --after-stage 120 --run-open 300 --silence 300 > "$run_dir/watch.log" 2>&1 < /dev/null &
  fi
  if [ "$only" = "" ] && [ -n "${FLEET_LANE:-}" ]; then
    bash "$FLEET_DIR/fleet.sh" master-watch "$FLEET_LANE" "$$" "$(cc_proc_fingerprint "$$")" > "$run_dir/master-watch.log" 2>&1 < /dev/null &
  fi
  # THE POLLER BELONGS ON THIS PATH, NOT ONLY ON THE SUPERVISED ONE. The CI
  # merge refusal it feeds is the only thing standing between a red check and a
  # merged branch, and this timer-driven path is the one with no session and no
  # terminal — the path where nobody would notice the refusal never fired. It
  # writes nothing to the ledger itself; the gate transcribes `checks.observed`
  # on its next act. A run with no poller leaves no `checks` row, and no row
  # reads as "nothing recorded", which the gate passes — so the absence is
  # byte-identical to a green night. Interval is pinned to 60 for the same
  # reason the watcher's is: they are one threshold, not two.
  bash "$pdir/checks.sh" --run-dir "$run_dir" --ledger "$ledger" --manifest "$manifest" --interval 60 > "$run_dir/checks.log" 2>&1 < /dev/null &
  return 0
}

# ===========================================================================
# BOOT-TIME RE-ENTRY — a run the reboot cut, called again from a dispatch tick
#
# A reboot kills the seat's gate, the shift and the watcher together, and
# nothing that survives it re-issues the seat's `router-shift`: the run waits on
# a person until morning. The dispatch labels run at login and every tick, so
# the first tick after a boot looks for such runs and issues that one call for
# each, as the seat would have. IT DECIDES NOTHING: the reason it issues is read
# off the ledger the gate has just settled, and the shift it starts does the
# routing. One call per run per boot value, and only on the run's own lane — the
# `config-dir` the run recorded — since the session it resumes lives there.
# ===========================================================================

fleet_reentry_dir() { printf '%s/reentry' "$PACE_ROOT"; }

fleet_reentry_lock() {
  # fleet_reentry_lock <lock dir> — take the per-run claim for as long as this
  # re-entry lives: `mkdir`, then an owner line `<pid> <fingerprint>`. TAKEN
  # OVER ONLY FROM A DEAD OWNER, never by age: the claim is held across a call
  # that runs for hours, so an age rule would let the next label's tick steal a
  # live claim. A pid from before the boot is dead by this test, since its
  # recorded start time cannot match the process that holds the pid now.
  local lk="$1" pid fp
  if mkdir "$lk" 2>/dev/null; then
    printf '%s %s\n' "$$" "$(cc_proc_fingerprint "$$")" > "$lk/owner"
    return 0
  fi
  pid=$(sed -n '1s/ .*//p' "$lk/owner" 2>/dev/null || true)
  fp=$(sed -n '1s/^[^ ]* //p' "$lk/owner" 2>/dev/null || true)
  if [ -n "$pid" ] && cc_holder_is_live "$pid" "$fp"; then return 1; fi
  # An owner line not written yet is a claim being taken this instant.
  [ -f "$lk/owner" ] || return 1
  mv "$lk" "$lk.stale.$$" 2>/dev/null || return 1
  rm -rf "$lk.stale.$$"
  mkdir "$lk" 2>/dev/null || return 1
  printf '%s %s\n' "$$" "$(cc_proc_fingerprint "$$")" > "$lk/owner"
}

fleet_reentry_unlock() { rm -rf "$1"; }

fleet_reentry_latest_handoff() {
  # fleet_reentry_latest_handoff <ledger> — the `사유` of the latest `handoff`
  # row, or empty.
  LC_ALL=C awk -F'|' '
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    /^- `handoff` / {
      for (i = 2; i <= NF; i++) { f = trim($i); if (index(f, "사유=") == 1) r = substr(f, length("사유=") + 1) }
    }
    END { printf "%s", r }
  ' "$1" 2>/dev/null || true
}

fleet_reentry_launches() {
  # fleet_reentry_launches <ledger> — how many `교대 기동` rows the ledger holds.
  grep -c '^- `교대 기동` ' "$1" 2>/dev/null || true
}

fleet_reentry_poller_live() {
  # fleet_reentry_poller_live <run dir> — the gate's test for the CI poller
  # (`gate_relay_poller_live`): a bare pid in `checks.pid` that exists.
  local p
  p=$( { cat "$1/checks.pid" 2>/dev/null || true; } | tr -d '[:space:]')
  case "$p" in ''|*[!0-9]*) return 1 ;; esac
  cc_pid_exists "$p"
}

fleet_reentry_driven_since() {
  # fleet_reentry_driven_since <run dir> <boot epoch> — succeeds when the seat,
  # a relay or a shift wrote this run's `seat-call`, `relay.live` or
  # `shift.live` at or after the boot. Those three are rewritten on every seat
  # launch, every relay poll and hand-back, and every shift launch, so a run
  # with any of them from this boot was being driven after the boot and the
  # boot did not cut it: it sits in the gap between two seat calls — after a
  # relay hand-back, a shift's return, a limit-shaped `무기록` — which is the
  # seat's to fill. A run born this boot is the plainest case.
  local f mt
  for f in seat-call relay.live shift.live; do
    mt=$(fleet_mtime "$1/$f")
    [ -n "$mt" ] && [ "$mt" -ge "$2" ] && return 0
  done
  return 1
}

fleet_reentry_candidate() {
  # fleet_reentry_candidate <run dir> <boot epoch> — succeeds for a run this
  # boot cut: it ends on `done` and has not, the seat recorded how it calls,
  # neither a shift nor a relay holds it, nothing drove it since the boot, this
  # boot value was not handled for it yet, and it is not waiting on a person's
  # answer to an approval. THE BOOT MUST HAVE CUT IT: without the evidence that
  # its last drive predates the boot, an unhandled boot value alone admits a
  # run this boot started, and the re-entry would then trigger on "every
  # process is dead" on an awake host — the trigger the design turned down as a
  # second decider.
  local rd="$1" boot="$2" ledger
  [ -f "$rd/ends-on-done" ] && [ ! -e "$rd/done" ] || return 1
  [ -s "$rd/config-dir" ] && [ -s "$rd/ledger-path" ] && [ -s "$rd/seat-call" ] || return 1
  if cc_shift_is_live "$rd" || cc_relay_is_live "$rd"; then return 1; fi
  if fleet_reentry_driven_since "$rd" "$boot"; then return 1; fi
  [ "$(sed -n '1p' "$(fleet_reentry_dir)/$(basename "$rd").boot" 2>/dev/null)" != "$boot" ] || return 1
  ledger=$(sed -n '1p' "$rd/ledger-path" 2>/dev/null)
  [ -f "$ledger" ] || return 1
  [ "$(fleet_reentry_latest_handoff "$ledger")" != "승인" ]
}

fleet_reentry_settled_since() {
  # fleet_reentry_settled_since <ledger> <boot epoch> — succeeds when some gate
  # call of this boot settled something the boot cut: a `stage-result` row
  # ending `외부 종료` whose settlement time is after the boot, or the dead-shift
  # `무기록` (exit code `-`) recorded after it. Not only this re-entry's own
  # snapshot: any gate call after the boot settles first, and an earlier
  # re-entry may have died between its settlement and its launch. Read only
  # for a candidate, which nothing drove since the boot, so a row settled after
  # the boot is of a dispatch from before it and not a plain cut of this boot.
  local ts e
  for ts in $(LC_ALL=C awk -F'|' '
      function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
      /^- `stage-result` / && index($0, "종단 부류=외부 종료") > 0 {
        if (match($0, /정산 시각 [0-9TZ:-]+/)) print substr($0, RSTART + length("정산 시각 "), RLENGTH - length("정산 시각 "))
      }
      /^- `handoff` / && index($0, " | 사유=무기록 | ") > 0 && index($0, " | 종료 코드=- ") > 0 {
        for (i = 2; i <= NF; i++) { f = trim($i); if (index(f, "기록 시각=") == 1) print substr(f, length("기록 시각=") + 1) }
      }' "$1" 2>/dev/null); do
    e=$(fleet_iso_epoch "$ts")
    [ -n "$e" ] && [ "$e" -gt "$2" ] && return 0
  done
  return 1
}

fleet_reentry_reason_wait() {
  # fleet_reentry_reason_wait <run dir> <ledger> — succeeds in the two states
  # the run's own pinned gate takes `대기` in, asked of that gate.
  bash -c 'CC_GATE_SOURCE_ONLY=1 . "$1" </dev/null; RUN_DIR="$2"; LEDGER="$3"; gate_relay_reentry_allowed' \
    _ "$R_GATE" "$1" "$2" >/dev/null 2>&1
}

fleet_reentry_reason() {
  # fleet_reentry_reason <run dir> <ledger> <boot epoch> — the reason
  # the re-entry issues, read off the settled ledger, or empty for none.
  # `대기` in the two states the gate takes it in — the latest handoff `대기`
  # with no launch after it, or a limit-shaped `무기록` whose shift's stream
  # yields a reset within the horizon — asked of the run's own pinned gate so
  # the two never disagree. Otherwise `중단`, but only when this boot's
  # settlement added a row: a run a person left at `중단` is not restarted on
  # every boot.
  local rd="$1" ledger="$2" boot="$3"
  if fleet_reentry_reason_wait "$rd" "$ledger"; then
    printf '대기'
  elif fleet_reentry_settled_since "$ledger" "$boot"; then
    printf '중단'
  fi
}

fleet_reentry_snap() {
  # fleet_reentry_snap — a fresh digest from the run's gate, empty on failure.
  ( cd "$R_WT" 2>/dev/null || cd /
    CLAUDE_CONFIG_DIR="$R_HOME" CC_PIPELINE_REENTRY="$R_MARK" \
      bash "$R_GATE" snapshot --manifest "$R_MAN" 2>/dev/null | jq -r '.H // empty' 2>/dev/null ) || true
}

fleet_reentry_act() {
  # fleet_reentry_act <act args...> — one act on the run's gate with a digest
  # taken just before it; exit 4 (the ledger moved under the digest) takes a
  # new one and issues the same call again, three times at most, as the router
  # does. Returns the gate's status.
  local h rc=4 n=0
  while [ "$rc" = "4" ] && [ "$n" -lt 4 ]; do
    n=$((n + 1)); rc=0
    h=$(fleet_reentry_snap)
    ( cd "$R_WT" 2>/dev/null || cd /
      CLAUDE_CONFIG_DIR="$R_HOME" CC_PIPELINE_REENTRY="$R_MARK" \
        bash "$R_GATE" act --manifest "$R_MAN" "$@" --snapshot-digest "$h" ) < /dev/null || rc=$?
  done
  return "$rc"
}

fleet_reentry_run() {
  # fleet_reentry_run <lane> <run dir> <boot epoch> — re-enter one run.
  # Succeeds when it issued the call. IN THIS ORDER, IN ONE TICK: settle, the
  # `재진입` row, the watcher and poller, the call. The row is the base time of
  # a reboot-class delay, so it goes before the call; the watcher goes before
  # the call because the call runs in the foreground for hours, and a relay
  # waiting on CI hands back at once when no poller is alive.
  local lane="$1" rd="$2" boot="$3" id lk mk reason rc ledger pdir latest hb
  local R_HOME R_GATE R_MAN R_WT R_MARK R_TGT R_CP R_SF
  id=$(basename "$rd")
  mkdir -p "$(fleet_reentry_dir)"
  lk="$(fleet_reentry_dir)/$id.lock"; mk="$(fleet_reentry_dir)/$id.boot"
  fleet_reentry_lock "$lk" || return 1
  if [ "$(sed -n '1p' "$mk" 2>/dev/null)" = "$boot" ]; then fleet_reentry_unlock "$lk"; return 1; fi
  R_HOME=$(sed -n '1p' "$rd/config-dir" 2>/dev/null); R_HOME=${R_HOME%/}
  R_MAN=$(sed -n 's/^manifest=//p' "$rd/seat-call" | tail -1)
  R_TGT=$(sed -n 's/^target=//p' "$rd/seat-call" | tail -1)
  R_GATE=$(sed -n 's/^gate=//p' "$rd/seat-call" | tail -1)
  R_CP=$(sed -n 's/^cutpoint=//p' "$rd/seat-call" | tail -1)
  R_SF=$(sed -n 's/^surface=//p' "$rd/seat-call" | tail -1)
  R_MARK="$id@$boot"
  ledger=$(sed -n '1p' "$rd/ledger-path" 2>/dev/null)
  if [ -z "$R_HOME" ] || [ -z "$R_MAN" ] || [ -z "$R_TGT" ] || [ ! -f "$R_GATE" ] || [ -z "$R_CP" ] || [ -z "$R_SF" ]; then
    printf '%s\n' "$boot" > "$mk"
    fleet_reentry_unlock "$lk"
    fleet_log "재진입 $lane: $id 의 seat-call 이 온전하지 않다 — 이 부팅에는 다시 부르지 않는다"
    return 1
  fi
  R_WT=$(fleet_manifest_field "$R_MAN" origin-worktree)
  pdir=$(dirname "$R_GATE")

  # SETTLE FIRST: every verb but `plan` settles lost dispatches and dead shifts
  # in its preamble, so one snapshot leaves the boot's cuts in the ledger.
  fleet_reentry_snap >/dev/null
  reason=$(fleet_reentry_reason "$rd" "$ledger" "$boot")
  if [ -z "$reason" ]; then
    printf '%s\n' "$boot" > "$mk"
    fleet_reentry_unlock "$lk"
    fleet_log "재진입 $lane: $id — 이 부팅이 끊은 것이 없다, 사람을 기다린다"
    return 1
  fi
  fleet_reentry_act --kind reentry --target "$R_TGT" --cutpoint "$R_CP" --surface 읽기 \
    -- "사유=$reason" "레이블=$lane" > /dev/null 2>&1 \
    || fleet_log "재진입 $lane: $id 의 재진입 행을 쓰지 못했다 — 호출은 그대로 낸다"
  ( cd "$R_WT" 2>/dev/null || cd /; fleet_start_watch "$R_HOME" "$pdir" "$R_MAN" "$rd" "$ledger" "$R_MARK" )
  fleet_log "재진입 $lane: $id — 사유 $reason 로 교대를 부른다 (레인 $R_HOME)"

  # THE CALL, IN THE FOREGROUND: the label template does not abandon its
  # process group, so a background call would die with the job. Issued again
  # as the seat would: `대기` on a hand-back or a limit-shaped `무기록`, `상한`
  # when the shift came back on its cap. Anything else ends the chain and
  # leaves the run to the ledger and the watcher.
  #
  # BOUNDED, BECAUSE A HAND-BACK WRITES NO ROW. The ledger stays in the `대기`
  # state across a hand-back, so the re-issue test stays true whatever came
  # back, and each call still appends its act rows. A relay that holds hands
  # back after its hold; one that comes back sooner with no shift launched met
  # a return condition that will stand on the next call too — the poller of a
  # CI wait is dead, or the gate keeps failing. The first quick return restarts
  # a dead poller and waits one quick period before the next call; a second in
  # a row ends the chain. FLEET_REENTRY_CALLS_MAX caps the calls that launched
  # no shift, above the calls a reset at the far end of the horizon needs. A
  # call that launched one worked, so it is not counted: a `상한` chain runs as
  # long as the night does, and ends on the floor's approval, a quick return
  # or `done`.
  local calls=0 quick=0 t0 launches after pause
  pause=$FLEET_REENTRY_QUICK_SECONDS
  case "${FLEET_REENTRY_PAUSE_TEST_SECONDS:-}" in
    ''|*[!0-9]*) : ;;
    *) [ "$FLEET_REENTRY_PAUSE_TEST_SECONDS" -lt "$pause" ] && pause=$FLEET_REENTRY_PAUSE_TEST_SECONDS ;;
  esac
  while :; do
    rc=0
    t0=$(date -u +%s); launches=$(fleet_reentry_launches "$ledger")
    fleet_reentry_act --kind router-shift --target "$R_TGT" --cutpoint "$R_CP" --surface "$R_SF" \
      -- "$reason" -p "/cc-cmds:autopilot-router-shift $R_MAN" || rc=$?
    after=$(fleet_reentry_launches "$ledger")
    [ "$after" != "$launches" ] || calls=$((calls + 1))
    # 3: another launcher holds the run, or a rule refused. 4: still stale
    # after three fresh digests. 5: an approval for a person.
    case "$rc" in 3|4|5) break ;; esac
    [ ! -e "$rd/done" ] || break
    if [ "$calls" -ge "$FLEET_REENTRY_CALLS_MAX" ]; then
      fleet_log "재진입 $lane: $id — 교대를 띄우지 않은 호출이 ${calls}번에 이르러 사슬을 멈춘다"
      break
    fi
    if fleet_reentry_reason_wait "$rd" "$ledger"; then
      if [ $(( $(date -u +%s) - t0 )) -lt "$FLEET_REENTRY_QUICK_SECONDS" ] \
        && [ "$after" = "$launches" ]; then
        quick=$((quick + 1))
        if [ "$quick" -ge 2 ]; then
          fleet_log "재진입 $lane: $id — 교대 없이 곧바로 돌아온 대기가 두 번 이어져 사슬을 멈춘다"
          break
        fi
        if ! fleet_reentry_poller_live "$rd"; then
          ( cd "$R_WT" 2>/dev/null || cd /; fleet_start_watch "$R_HOME" "$pdir" "$R_MAN" "$rd" "$ledger" "$R_MARK" poller )
        fi
        sleep "$pause"
      else
        quick=0
      fi
      reason=대기; continue
    fi
    quick=0
    latest=$(fleet_reentry_latest_handoff "$ledger")
    if [ "$rc" = "0" ] && [ "$latest" = "상한" ]; then reason=상한; continue; fi
    break
  done
  hb=$(fleet_reentry_latest_handoff "$ledger")
  printf '%s\n' "$boot" > "$mk"
  fleet_reentry_unlock "$lk"
  fleet_log "재진입 $lane: $id 종료 — 마지막 rc=$rc, 최신 handoff ${hb:--}"
  return 0
}

fleet_reentry_tick() {
  # fleet_reentry_tick <lane> — re-enter every run this boot cut on this
  # label's account. Succeeds when at least one call was issued, and the tick
  # then dispatches no backlog head. No boot reading — a host whose kernel
  # gives none — is no re-entry.
  #
  # A RUN ON ANOTHER LABEL'S ACCOUNT IS THAT LABEL'S. The chain holds the tick
  # for hours, so a label that took it would dispatch nothing on its own idle
  # account all that time, while the run's own label is held off its backlog
  # by the run's lane occupancy anyway. A run whose account no label holds —
  # the interactive lane — has no label of its own, and any label takes it.
  local lane="$1" boot rd ran=1 inv home homes rh
  boot=$(boot_epoch 2>/dev/null || true)
  case "$boot" in ''|0|*[!0-9]*) return 1 ;; esac
  inv=$(fleet_inventory_json)
  home=$(printf '%s' "$inv" | jq -r --arg i "$lane" '.accounts[] | select(.id == $i) | .config_dir')
  home=${home%/}
  homes=$(fleet_label_homes_json "$inv" "$(fleet_dirs_json "$inv")")
  for rd in "${XDG_STATE_HOME:-$HOME/.local/state}/cc-cmds/run"/*; do
    [ -d "$rd" ] || continue
    fleet_reentry_candidate "$rd" "$boot" || continue
    rh=$(sed -n '1p' "$rd/config-dir" 2>/dev/null); rh=${rh%/}
    if [ "$rh" != "$home" ] \
      && printf '%s' "$homes" | jq -e --arg d "$rh" 'any(.[]; .home == $d)' >/dev/null 2>&1; then
      continue
    fi
    if fleet_reentry_run "$lane" "$rd" "$boot"; then ran=0; fi
  done
  return "$ran"
}

# ===========================================================================
# MASTER — the base-branch reading, its events, and the repair runs
#
# THE READING IS THE GATE'S INPUT, NOT A VERDICT OF THIS FILE. For every
# (repository, base branch) pair a queued or live run names, the master stage
# reads the base tip's check runs and, for each failed Actions job, its failed
# steps and its log, and turns them into signatures with `ci-signature.sh` —
# the calls the gate's own CI match act makes, in the same order, so the two
# compare like for like. It writes one `cc-master-state v1` file per pair; the
# gate reads it and decides what a waiting segment does.
#
# ONLY A SETTLED OBSERVATION MOVES EVENTS. `초록` and `빨강` are settled. A check
# still running is `진행 중`, which may carry the new tip; anything this stage
# could not read is `판정 불가`, which keeps the previous tip, signatures and
# events. An event opens on a settled `빨강` whose signatures no open event
# holds, and resolves on a settled reading that holds none of its signatures.
#
# THE REMOTE IS READ, NEVER WRITTEN. `fleet_master_gh` passes `gh api` GETs
# only, with the read-scoped token when the credential store has one and the
# active login otherwise; the pipeline's write credential is never asked for.
#
# EACH EVENT'S REPAIR STATE IS RECOMPUTED EVERY ROUND from its backlog record
# and the record's run directory, so the file never carries a state that
# stopped being true. Only the stage starts nothing: it renders and enqueues a
# record, and the dispatch path claims it.
# ===========================================================================

fleet_master_dir() { printf '%s/master' "$PACE_ROOT"; }
fleet_master_enc() {
  # The gate's encoding of one path piece: `%`, `/` and `_` are escaped, so a
  # `__` in the file name can only be the separator.
  printf '%s' "$1" | sed -e 's/%/%25/g' -e 's#/#%2F#g' -e 's/_/%5F/g'
}
fleet_master_file() {
  # fleet_master_file <owner/name> <base branch> — the pair's reading.
  printf '%s/%s__%s__%s.json' "$(fleet_master_dir)" "$(fleet_master_enc "${1%%/*}")" \
    "$(fleet_master_enc "${1#*/}")" "$(fleet_master_enc "$2")"
}
fleet_master_real_now() { date -u +%s; }
fleet_master_in_budget() { [ "$(fleet_master_real_now)" -lt "$1" ]; }
fleet_master_interval() {
  # The observer child's period. FLEET_MASTER_INTERVAL_TEST_SECONDS may only
  # shorten it, for a fixture.
  local t="${FLEET_MASTER_INTERVAL_TEST_SECONDS:-}"
  case "$t" in ''|*[!0-9]*|0) printf '%s' "$FLEET_MASTER_INTERVAL_SECONDS"; return 0 ;; esac
  if [ "$t" -lt "$FLEET_MASTER_INTERVAL_SECONDS" ]; then printf '%s' "$t"; else printf '%s' "$FLEET_MASTER_INTERVAL_SECONDS"; fi
}
fleet_master_skip() {
  # Half the period: a pair read that recently is not read again this round.
  local i; i=$(fleet_master_interval)
  if [ "$i" -lt "$FLEET_MASTER_INTERVAL_SECONDS" ]; then printf '%s' $(( i / 2 )); else printf '%s' "$FLEET_MASTER_SKIP_SECONDS"; fi
}

fleet_master_kill_tree() {
  # The process and everything under it: the read runs a subshell deep.
  local c
  for c in $(pgrep -P "$1" 2>/dev/null || true); do fleet_master_kill_tree "$c"; done
  kill "$1" 2>/dev/null || true
}

fleet_master_gh() {
  # fleet_master_gh <out file> api <args…> — one GET into the file, abandoned
  # after FLEET_MASTER_GH_SECONDS (rc 124). Anything but `gh api`, an argument
  # that carries a request body, or a method other than GET is refused before
  # it runs (rc 2). `FLEET_GH` names the program, for a fixture.
  local out="$1" a prev="" pid t=0 lim gh="${FLEET_GH:-gh}"
  shift
  if [ "${1:-}" != api ]; then fleet_log "master: 읽기 래퍼는 gh api 만 부른다 — ${1:-}"; return 2; fi
  for a in "$@"; do
    case "$prev" in
      -X|--method) if [ "$a" != GET ]; then fleet_log "master: GET 이 아닌 메서드를 거부한다 — $a"; return 2; fi ;;
    esac
    case "$a" in
      -f|-F|--field|--raw-field|--input|-f?*|-F?*|--field=*|--raw-field=*|--input=*)
        fleet_log "master: 본문을 싣는 인자를 거부한다 — $a"; return 2 ;;
      -X?*|--method=*)
        if [ "$a" != -XGET ] && [ "$a" != --method=GET ]; then fleet_log "master: GET 이 아닌 메서드를 거부한다 — $a"; return 2; fi ;;
    esac
    prev="$a"
  done
  (
    unset GH_REPO GH_HOST
    if [ -r "$FLEET_DIR/credentials.sh" ]; then
      envl=$( ( . "$FLEET_DIR/credentials.sh" && cred_readonly_env ) 2>/dev/null ) || envl=""
      while IFS= read -r a; do
        case "$a" in GH_TOKEN=?*|GITHUB_TOKEN=*|GH_CONFIG_DIR=?*) export "${a?}" ;; esac
      done <<EOF
$envl
EOF
    fi
    exec "$gh" "$@"
  ) > "$out" 2>/dev/null &
  pid=$!
  lim=$(( FLEET_MASTER_GH_SECONDS * 5 ))
  while cc_pid_exists "$pid"; do
    if [ "$t" -ge "$lim" ]; then
      fleet_master_kill_tree "$pid"
      wait "$pid" 2>/dev/null || true
      return 124
    fi
    sleep 0.2; t=$(( t + 1 ))
  done
  wait "$pid"
}

fleet_master_obs_json() {
  # fleet_master_obs_json <state> <precision> <signatures> <failed check
  # names> <failed run ids> <every check name> — the lists one item a line.
  jq -cn --arg st "$1" --arg p "$2" --arg s "$3" --arg c "$4" --arg f "$5" --arg n "${6:-}" '
    def lines($x): $x | split("\n") | map(select(. != "")) | unique;
    {state: $st, precision: (if $p == "" then "-" else $p end), signatures: lines($s),
     checks: lines($c), failed_runs: lines($f), names: lines($n)}'
}

fleet_master_observe_sha() {
  # fleet_master_observe_sha <slug> <sha> <deadline epoch> <tmp dir> [<previous
  # reading>] — one observation of a commit's checks, as fleet_master_obs_json.
  # `진행 중` when no check run exists yet or one is not completed; `초록` when
  # every completed run passed; `빨강` when every failed run is an Actions job
  # whose signatures came out; `판정 불가` otherwise (a read failed, a failure
  # is not an Actions job, an extraction was empty, the budget ran out).
  #
  # THE LOGS ARE READ ONCE PER FAILURE SET. When the previous reading was a
  # settled `빨강` of the same tip over the same failed runs, its signatures
  # are this one's: a rerun is a new run id and is read afresh.
  local slug="$1" h="$2" dl="$3" d="$4" prev="${5:-null}" line cid name concl app durl job s outp p
  local sigs="" prec="" fc="" fr="" names="" incomplete=""
  fleet_master_in_budget "$dl" || { fleet_master_obs_json '판정 불가' '' '' '' ''; return 0; }
  if ! fleet_master_gh "$d/runs" api --paginate "repos/$slug/commits/$h/check-runs?per_page=100" \
         --jq '.check_runs[] | [(.id | tostring), .name, (.status // ""), (.conclusion // ""), (.app.slug // ""), (.details_url // "")] | join("\t")'; then
    fleet_master_obs_json '판정 불가' '' '' '' ''; return 0
  fi
  names=$(cut -f2 "$d/runs")
  if ! grep -q . "$d/runs" || awk -F'\t' 'NF && $3 != "completed" { f = 1 } END { exit !f }' "$d/runs"; then
    fleet_master_obs_json '진행 중' '' '' '' '' "$names"; return 0
  fi
  # `cut`, never `read`, so an empty field does not shift the ones after it.
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    concl=$(printf '%s' "$line" | cut -f4)
    case "$concl" in success|neutral|skipped|'') continue ;; esac
    fc=$(printf '%s\n%s' "$fc" "$(printf '%s' "$line" | cut -f2)")
    fr=$(printf '%s\n%s' "$fr" "$(printf '%s' "$line" | cut -f1)")
  done < "$d/runs"
  if [ -z "$fr" ]; then fleet_master_obs_json '초록' '' '' '' '' "$names"; return 0; fi
  if printf '%s' "$prev" | jq -e --arg t "$h" --arg f "$fr" '
       .tip == $t and .state == "빨강"
       and ((.failed_runs // []) == ($f | split("\n") | map(select(. != "")) | unique))' >/dev/null 2>&1; then
    printf '%s' "$prev" | jq -c --arg n "$names" '{state, precision, signatures, checks: (.checks // []),
      failed_runs, names: ($n | split("\n") | map(select(. != "")) | unique)}'
    return 0
  fi
  while IFS= read -r line <&3; do
    [ -n "$line" ] || continue
    [ -z "$incomplete" ] || break
    cid=$(printf '%s' "$line" | cut -f1);    name=$(printf '%s' "$line" | cut -f2)
    concl=$(printf '%s' "$line" | cut -f4);  app=$(printf '%s' "$line" | cut -f5)
    durl=$(printf '%s' "$line" | cut -f6)
    case "$concl" in success|neutral|skipped|'') continue ;; esac
    fleet_master_in_budget "$dl" || { incomplete=1; continue; }
    if [ "$app" != "github-actions" ]; then incomplete=1; continue; fi
    job=$(printf '%s' "$durl" | sed -n 's#.*/job/\([0-9][0-9]*\).*#\1#p')
    [ -n "$job" ] || job="$cid"
    case "$job" in ''|*[!0-9]*) incomplete=1; continue ;; esac
    if ! fleet_master_gh "$d/steps" api "repos/$slug/actions/jobs/$job" \
           --jq '.steps[]? | select(.conclusion == "failure") | .name'; then
      incomplete=1; continue
    fi
    if ! fleet_master_gh "$d/log.full" api --allow-escape-sequences "repos/$slug/actions/jobs/$job/logs"; then
      incomplete=1; continue
    fi
    head -c "$FLEET_MASTER_LOG_MAX_BYTES" "$d/log.full" > "$d/log" 2>/dev/null || : > "$d/log"
    set --
    s=$(wc -c < "$d/log.full" 2>/dev/null | tr -d ' ')
    [ "${s:-0}" -le "$FLEET_MASTER_LOG_MAX_BYTES" ] || set -- --truncated
    while IFS= read -r s; do [ -z "$s" ] || set -- "$@" --step "$s"; done < "$d/steps"
    outp=$(bash "$FLEET_DIR/ci-signature.sh" extract --repo "$slug" --check "$name" "$@" < "$d/log" 2>/dev/null) \
      || { incomplete=1; continue; }
    p=$(printf '%s\n' "$outp" | sed -n '1s/^정밀도: //p')
    s=$(printf '%s\n' "$outp" | tail -n +2 | { grep -v '^$' || true; })
    if [ -z "$s" ]; then incomplete=1; continue; fi
    sigs=$(printf '%s\n%s' "$sigs" "$s")
    case "$p" in 단언) [ -n "$prec" ] || prec='단언' ;; *) prec='단계' ;; esac
  done 3< "$d/runs"
  if [ -n "$incomplete" ]; then fleet_master_obs_json '판정 불가' '' '' '' '' "$names"; return 0; fi
  fleet_master_obs_json '빨강' "$prec" "$sigs" "$fc" "$fr" "$names"
}

fleet_master_event_id() {
  # fleet_master_event_id <first commit> <signatures, a line each> — the
  # event's id: the first 12 hex of the sha256 of the bytes `<first commit,
  # 40 hex>\n` followed by the signatures `LC_ALL=C sort -u`, each line ending
  # in `\n`. The same failure first seen on the same commit is the same event.
  { printf '%s\n' "$1"; printf '%s\n' "$2" | { grep -v '^$' || true; } | LC_ALL=C sort -u; } \
    | fleet_sha256_stdin | cut -c1-12
}
fleet_sha256_stdin() { shasum -a 256 2>/dev/null | cut -d' ' -f1; }

fleet_master_switch_off() {
  # fleet_master_switch_off <owner/name> — rc 0 when repair runs are off for
  # the repository: `master-repair.off` present with no non-blank line turns
  # them off everywhere; otherwise a line holding the slug turns that one off.
  local f="$PACE_ROOT/master-repair.off" lines
  [ -f "$f" ] || return 1
  lines=$(sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$f" | { grep -v '^$' || true; })
  [ -n "$lines" ] || return 0
  printf '%s\n' "$lines" | grep -qxF -- "$1"
}

fleet_master_record_of() {
  # fleet_master_record_of <event id> — the newest repair record of that
  # event, verbatim (the line a compare-and-swap needs), or nothing.
  local f="$PACE_ROOT/backlog.jsonl"
  [ -r "$f" ] || return 0
  jq -rR --arg s "$FLEET_BACKLOG_SCHEMA" --arg k "$FLEET_REPAIR_KIND" --arg e "$1" \
    '. as $l | (fromjson? // {}) | select(.schema == $s and .kind == $k and .event_id == $e) | $l' "$f" 2>/dev/null \
    | tail -n 1
}
fleet_master_repair_run_ids() {
  # The run ids of every repair record, one a line.
  local f="$PACE_ROOT/backlog.jsonl" m
  [ -r "$f" ] || return 0
  jq -rR --arg s "$FLEET_BACKLOG_SCHEMA" --arg k "$FLEET_REPAIR_KIND" \
    'fromjson? // {} | select(.schema == $s and .kind == $k) | .manifest_path // empty' "$f" 2>/dev/null \
    | while IFS= read -r m; do [ -r "$m" ] && fleet_manifest_field "$m" run-id; done
}
fleet_master_run_marker_live() {
  # fleet_master_run_marker_live <run id> — rc 0 while a live repair marker
  # carries that run id.
  local f
  for f in $(fleet_busy_repair_live); do
    [ "$(sed -n '3p' "$f" | tr -d '[:space:]')" = "$1" ] && return 0
  done
  return 1
}

fleet_master_fix_pr() {
  # fleet_master_fix_pr <slug> <base> <event json> <tmp dir> <deadline> — the
  # number of an open pull request into the base that looks like a person's
  # fix of the event, or nothing. A candidate is not a repair run's own branch,
  # contains the base (`ahead` or `identical`), has a settled reading of its
  # head in which every check the event failed in has run, and fails with
  # none of the event's signatures.
  local slug="$1" base="$2" ev="$3" d="$4" dl="$5" line num ref sha rid ids obs
  fleet_master_in_budget "$dl" || return 0
  fleet_master_gh "$d/pulls" api "repos/$slug/pulls?state=open&base=$base&per_page=100" \
    --jq '.[] | [(.number | tostring), .head.ref, .head.sha] | join("\t")' || return 0
  ids=$(fleet_master_repair_run_ids || true)
  while IFS= read -r line <&4; do
    [ -n "$line" ] || continue
    num=$(printf '%s' "$line" | cut -f1); ref=$(printf '%s' "$line" | cut -f2); sha=$(printf '%s' "$line" | cut -f3)
    case "$num" in ''|*[!0-9]*) continue ;; esac
    printf '%s' "$sha" | grep -qE '^[0-9a-f]{40}$' || continue
    case "$ref" in
      seg/*) rid=${ref#seg/}; rid=${rid%-*}
             if [ -n "$ids" ] && printf '%s\n' "$ids" | grep -qxF -- "$rid"; then continue; fi ;;
    esac
    fleet_master_in_budget "$dl" || return 0
    fleet_master_gh "$d/cmp" api "repos/$slug/compare/$base...$sha" --jq .status || continue
    case "$(tr -d '[:space:]' < "$d/cmp")" in ahead|identical) ;; *) continue ;; esac
    mkdir -p "$d/pr"
    obs=$(fleet_master_observe_sha "$slug" "$sha" "$dl" "$d/pr")
    if printf '%s' "$obs" | jq -e --argjson e "$ev" '
         def basename: sub(" \\([0-9]+\\)$"; "");
         . as $o
         | ($o.state == "초록" or $o.state == "빨강")
           and ([$o.names[] | basename] as $have | all(($e.checks // [])[] | basename; . as $c | any($have[]; . == $c)))
           and all($e.signatures[]; . as $s | (any(($o.signatures // [])[]; . == $s) | not))' >/dev/null 2>&1; then
      printf '%s' "$num"; return 0
    fi
  done 4< "$d/pulls"
  return 0
}

fleet_master_enqueue() {
  # fleet_master_enqueue <slug> <base> <worktree> <event json> <tmp dir> —
  # render the event's repair run and append its record, under `backlog.lock`
  # and only when no record of the event is there. Prints the run id (rc 0);
  # rc 3 the lock was not taken, 4 the render failed (its last line printed),
  # 5 the append failed, 6 a record of the event is already there.
  local slug="$1" base="$2" wt="$3" ev="$4" d="$5" id out rc=0 m rid at dl dsha bc rec
  id=$(printf '%s' "$ev" | jq -r .id)
  fleet_backlog_lock || return 3
  if [ -n "$(fleet_master_record_of "$id")" ]; then fleet_backlog_unlock; return 6; fi
  printf '%s' "$ev" | jq -r '.signatures[]' > "$d/sigs"
  out=$(bash "$FLEET_DIR/repair.sh" render --slug "$slug" --base "$base" --event "$id" --signatures "$d/sigs" \
          --first-commit "$(printf '%s' "$ev" | jq -r .first_commit)" --worktree "$wt" 2>&1) || rc=$?
  if [ "$rc" != 0 ]; then
    fleet_backlog_unlock
    printf '%s' "$(printf '%s\n' "$out" | { grep -v '^$' || true; } | tail -n 1)"
    return 4
  fi
  m=$(printf '%s\n' "$out" | sed -n 's/^manifest=//p' | sed -n '1p')
  rid=$(printf '%s\n' "$out" | sed -n 's/^run_id=//p' | sed -n '1p')
  at=$(printf '%s\n' "$out" | sed -n 's/^rendered_at=//p' | sed -n '1p')
  dl=$(printf '%s\n' "$out" | sed -n 's/^deadline=//p' | sed -n '1p')
  dsha=$(printf '%s\n' "$out" | sed -n 's/^doc_sha256=//p' | sed -n '1p')
  bc=$( (cd "$wt" && git rev-parse HEAD) 2>/dev/null || true)
  rec=$(jq -cn --arg schema "$FLEET_BACKLOG_SCHEMA" --arg k "$FLEET_REPAIR_KIND" --arg e "$id" --arg slug "$slug" \
          --arg base "$base" --arg at "$at" --arg dl "$dl" --arg bc "$bc" --arg dsha "$dsha" --arg m "$m" '
          {schema: $schema, id: ("mr-" + $e), kind: $k, event_id: $e, slug: $slug, base: $base,
           status: "pending", enqueued_at: $at, authorized_at: $at, deadline: $dl, base_commit: $bc,
           doc_sha256: $dsha, manifest_path: $m, lane: ""}')
  if [ -z "$m" ] || [ -z "$rid" ] || ! printf '%s\n' "$rec" >> "$PACE_ROOT/backlog.jsonl"; then
    fleet_backlog_unlock; return 5
  fi
  fleet_backlog_unlock
  printf '%s' "$rid"
}

fleet_master_end_token() {
  # fleet_master_end_token <ledger> — the `재킥 원인` of the run's earliest end
  # row, or `-`.
  local t
  t=$(grep -E '^- `자율 승인`' "$1" 2>/dev/null | grep -F '결정=종료' | sed -n '1p' \
        | sed -n 's/.*재킥 원인=\([^ |]*\).*/\1/p' || true)
  printf '%s' "${t:--}"
}

fleet_master_event_repair() {
  # fleet_master_event_repair <slug> <base> <worktree> <event json> <settled
  # 1|0> <round epoch> <tmp dir> <deadline> — the event with its `repair`
  # recomputed, as one JSON line.
  local slug="$1" base="$2" wt="$3" ev="$4" settled="$5" round="$6" d="$7" dl="$8"
  local id rec st reason pr="" runid="" status m now hold he out rc rd ledger n done_e e_auth e_dl
  id=$(printf '%s' "$ev" | jq -r .id)
  now=$(fleet_now)
  rec=$(fleet_master_record_of "$id")
  st=""; reason=""
  if [ -z "$rec" ]; then
    local pst preason
    pst=$(printf '%s' "$ev" | jq -r '.repair.state // "대기"')
    preason=$(printf '%s' "$ev" | jq -r '.repair.reason // ""')
    if [ "$pst" = "띄울 수 없음" ] && [ "${preason#렌더 실패}" != "$preason" ]; then
      printf '%s' "$ev"; return 0
    fi
    if fleet_master_switch_off "$slug"; then
      st="띄울 수 없음"; reason="끄는 스위치"
    elif [ "$settled" != 1 ]; then
      # Nothing new starts on a reading that is not settled.
      case "$pst" in 보류) st="보류"; pr=$(printf '%s' "$ev" | jq -r '.repair.pr // ""') ;; *) st="대기" ;; esac
    else
      hold=$(printf '%s' "$ev" | jq -r '.hold_started_at // ""')
      he=""; [ -z "$hold" ] || he=$(fleet_iso_epoch "$hold")
      if [ -z "$he" ] || [ $(( now - he )) -lt "$FLEET_MASTER_FIX_PR_HOLD_SECONDS" ]; then
        pr=$(fleet_master_fix_pr "$slug" "$base" "$ev" "$d" "$dl")
      fi
      if [ -n "$pr" ]; then
        st="보류"
        [ -n "$hold" ] || ev=$(printf '%s' "$ev" | jq -c --arg at "$(fleet_iso "$now")" '.hold_started_at = $at')
      else
        rc=0; out=$(fleet_master_enqueue "$slug" "$base" "$wt" "$ev" "$d") || rc=$?
        case "$rc" in
          0) st="띄움"; runid="$out" ;;
          4) st="띄울 수 없음"; reason="렌더 실패 — $out" ;;
          5) st="띄울 수 없음"; reason="백로그 적재 실패" ;;
          *) st="대기" ;;
        esac
      fi
    fi
  else
    status=$(printf '%s' "$rec" | jq -r '.status // ""')
    m=$(printf '%s' "$rec" | jq -r '.manifest_path // ""')
    runid=$( [ -r "$m" ] && fleet_manifest_field "$m" run-id || true)
    case "$status" in
      pending)
        e_dl=$(fleet_iso_epoch "$(printf '%s' "$rec" | jq -r '.deadline // ""')")
        if [ -z "$e_dl" ] || [ "$e_dl" -lt "$now" ]; then st="띄울 수 없음"; reason="마감 지난 레코드"
        else st="띄움"; fi ;;
      parked)
        st="띄울 수 없음"; reason="park $(printf '%s' "$rec" | jq -r '.park_reason // "?"')" ;;
      dispatched|done)
        rd="${XDG_STATE_HOME:-$HOME/.local/state}/cc-cmds/run/$runid"
        if [ "$status" = dispatched ] && [ ! -d "$rd" ] && ! fleet_master_run_marker_live "$runid"; then
          # A claim whose run never opened and whose claimant is gone: the
          # record goes back to pending, by compare-and-swap.
          if fleet_backlog_lock; then
            fleet_backlog_rewrite "$rec" "$(printf '%s' "$rec" | jq -c '.status = "pending" | del(.dispatched_lane, .dispatched_at)')" \
              || fleet_log "master: $id 의 pending 되돌림이 원본 줄을 찾지 못했다"
            fleet_backlog_unlock
          fi
          st="띄움"
        else
          ledger=$(sed -n '1p' "$rd/ledger-path" 2>/dev/null || true)
          n=0
          if [ -n "$ledger" ] && [ -d "$rd/halt" ]; then n=$(cc_unanswered_halts "$rd" "$ledger" 2>/dev/null || printf 0); fi
          done_e=""
          if [ -e "$rd/done" ]; then done_e=$(fleet_mtime "$rd/done"); elif [ "$status" = done ]; then done_e=0; fi
          e_auth=$(fleet_iso_epoch "$(printf '%s' "$rec" | jq -r '.authorized_at // ""')")
          if [ "${n:-0}" -gt 0 ] 2>/dev/null; then
            st="정지"
          elif [ -n "$done_e" ]; then
            if [ "$settled" = 1 ] && [ "$round" -gt "${done_e:-0}" ]; then
              st="띄울 수 없음"; reason="수리 런이 해소 없이 끝남 ($(fleet_master_end_token "$ledger"))"
            else
              st="띄움"
            fi
          elif ! fleet_master_run_marker_live "$runid" && [ -n "$e_auth" ] \
               && [ "$now" -gt $(( e_auth + FLEET_REPAIR_WAIT_MAX_SECONDS )) ]; then
            st="띄울 수 없음"; reason="수리 런이 대기 상한 안에 끝나지 않음"
          else
            st="띄움"
          fi
        fi ;;
      *) st="대기" ;;
    esac
  fi
  printf '%s' "$ev" | jq -c --arg st "$st" --arg r "$reason" --arg pr "$pr" --arg run "$runid" '
    def cut160: if (. | utf8bytelength) <= 160 then . else .[0:length - 1] | cut160 end;
    .repair = {state: $st,
               pr: (if $pr == "" then null else ($pr | tonumber) end),
               run_id: (if $run == "" then null else $run end),
               reason: (if $r == "" then null else ($r | gsub("[\\n\\r\\t]"; " ") | cut160) end)}'
}

fleet_master_pairs() {
  # The watched pairs, `<slug>\t<base>\t<main worktree>` once each, the first
  # worktree seen for a pair kept: every target row of the manifest of a
  # pending record, of a dispatched record whose run has not ended, and of a
  # run directory that has not ended and moved within FLEET_LANE_HORIZON_SECONDS.
  local f="$PACE_ROOT/backlog.jsonl" mans="" m rd mt rid now
  now=$(fleet_master_real_now)
  if [ -r "$f" ]; then
    while IFS= read -r m; do
      [ -n "$m" ] && [ -r "$m" ] || continue
      rid=$(fleet_manifest_field "$m" run-id)
      [ -z "$rid" ] || [ ! -e "${XDG_STATE_HOME:-$HOME/.local/state}/cc-cmds/run/$rid/done" ] || continue
      mans=$(printf '%s\n%s' "$mans" "$m")
    done <<EOF
$(jq -rR --arg s "$FLEET_BACKLOG_SCHEMA" 'fromjson? // {} | select(.schema == $s and (.status == "pending" or .status == "dispatched")) | .manifest_path // empty' "$f" 2>/dev/null)
EOF
  fi
  for rd in "${XDG_STATE_HOME:-$HOME/.local/state}/cc-cmds/run"/*; do
    [ -d "$rd" ] && [ ! -e "$rd/done" ] || continue
    mt=$(fleet_mtime "$rd")
    [ -n "$mt" ] && [ $(( now - mt )) -le "$FLEET_LANE_HORIZON_SECONDS" ] || continue
    m=$(sed -n 's/^manifest=//p' "$rd/seat-call" 2>/dev/null | sed -n '1p' || true)
    [ -n "$m" ] && [ -r "$m" ] || continue
    mans=$(printf '%s\n%s' "$mans" "$m")
  done
  printf '%s\n' "$mans" | { grep -v '^$' || true; } | while IFS= read -r m; do
    LC_ALL=C awk -F' [|] ' '
      index($0, "- `target` ") == 1 {
        s = ""; b = ""; w = ""
        for (i = 2; i <= NF; i++) {
          v = $i
          if (sub(/^원격 슬러그=/, "", v)) s = v
          else if (sub(/^베이스 브랜치=/, "", v)) b = v
          else if (sub(/^메인 워크트리=/, "", v)) w = v
        }
        if (s != "" && b != "") printf "%s\t%s\t%s\n", s, b, w
      }' "$m" 2>/dev/null || true
  done | while IFS="$(printf '\t')" read -r s b w; do
    printf '%s' "$s" | grep -qE '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' || continue
    git check-ref-format --branch "$b" >/dev/null 2>&1 || continue
    printf '%s\t%s\t%s\n' "$s" "$b" "$w"
  done | awk -F'\t' '!seen[$1 FS $2]++'
}

fleet_master_pair() {
  # fleet_master_pair <slug> <base> <worktree> <round epoch> <deadline epoch> —
  # observe one pair and rewrite its reading.
  local slug="$1" base="$2" wt="$3" round="$4" dl="$5" f sf prev d tip="" obs st settled=0 last mt
  local newsigs ev=null eid json
  f=$(fleet_master_file "$slug" "$base"); sf="$f.settled"
  mkdir -p "$(fleet_master_dir)"
  mt=$(fleet_mtime "$f")
  if [ -n "$mt" ] && [ $(( $(fleet_master_real_now) - mt )) -lt "$(fleet_master_skip)" ]; then return 0; fi
  prev=$(jq -c --arg s "$FLEET_MASTER_SCHEMA" 'select(.schema == $s)' "$f" 2>/dev/null || true)
  [ -n "$prev" ] || prev=null
  d=$(mktemp -d "${TMPDIR:-/tmp}/fleet-master.XXXXXX") || return 0
  if fleet_master_in_budget "$dl" && fleet_master_gh "$d/tip" api "repos/$slug/commits/$base" --jq .sha; then
    tip=$(tr -d '[:space:]' < "$d/tip")
  fi
  printf '%s' "$tip" | grep -qE '^[0-9a-f]{40}$' || tip=""
  if [ -n "$tip" ]; then obs=$(fleet_master_observe_sha "$slug" "$tip" "$dl" "$d" "$prev")
  else obs=$(fleet_master_obs_json '판정 불가' '' '' '' ''); fi
  st=$(printf '%s' "$obs" | jq -r .state)
  # THE SETTLED CLOCK. A pair with no settled reading for
  # FLEET_MASTER_SETTLED_MAX_SECONDS stops being rewritten, so its file ages
  # into the gate's staleness rather than reading as fresh and undecided.
  case "$st" in 초록|빨강) settled=1; printf '%s\n' "$round" | fleet_write_atomic "$sf" ;; esac
  last=$(sed -n '1p' "$sf" 2>/dev/null | tr -d '[:space:]' || true)
  case "$last" in ''|*[!0-9]*) last="$round"; printf '%s\n' "$round" | fleet_write_atomic "$sf" ;; esac
  if [ $(( round - last )) -gt "$FLEET_MASTER_SETTLED_MAX_SECONDS" ]; then
    fleet_log "master: $slug $base — 결론 난 판독이 ${FLEET_MASTER_SETTLED_MAX_SECONDS}초 넘게 없다; 판독을 다시 쓰지 않는다"
    rm -rf "$d"; return 0
  fi
  if [ "$prev" = null ] && [ -z "$tip" ]; then rm -rf "$d"; return 0; fi
  case "$st" in
    초록|빨강)
      newsigs=$(jq -rn --argjson p "$prev" --argjson o "$obs" '
        [(($p // {}).events // [])[] | select(.resolved_at == null) | .signatures[]?] as $open
        | $o.signatures[] | select(. as $s | (any($open[]; . == $s) | not))')
      if [ -n "$newsigs" ]; then
        eid=$(fleet_master_event_id "$tip" "$newsigs")
        ev=$(jq -cn --arg id "$eid" --arg t "$tip" --arg s "$newsigs" --argjson o "$obs" '
          {id: $id, first_commit: $t, signatures: ($s | split("\n") | map(select(. != "")) | unique),
           checks: $o.checks, resolved_at: null, resolved_commit: null, hold_started_at: null,
           repair: {state: "대기", pr: null, run_id: null, reason: null}}')
      fi
      json=$(jq -cn --argjson p "$prev" --argjson o "$obs" --argjson ev "$ev" --arg t "$tip" --arg iso "$(fleet_iso "$round")" '
        [(($p // {}).events // [])[]
          | if .resolved_at == null and all(.signatures[]?; . as $s | (any($o.signatures[]; . == $s) | not))
            then .resolved_at = $iso | .resolved_commit = $t | .repair.state = "해소" | .repair.reason = null
            else . end] as $evs
        | {tip: $t, state: $o.state, precision: $o.precision, signatures: $o.signatures,
           failed_runs: $o.failed_runs,
           events: ($evs + (if $ev == null or any($evs[]; .id == $ev.id) then [] else [$ev] end))}') ;;
    '진행 중')
      json=$(jq -cn --argjson p "$prev" --arg t "$tip" '
        {tip: $t, state: "진행 중", precision: (($p // {}).precision // "-"),
         signatures: (($p // {}).signatures // []), failed_runs: (($p // {}).failed_runs // []),
         events: (($p // {}).events // [])}') ;;
    *)
      json=$(jq -cn --argjson p "$prev" --arg t "$tip" '
        {tip: (($p // {}).tip // $t), state: "판정 불가", precision: (($p // {}).precision // "-"),
         signatures: (($p // {}).signatures // []), failed_runs: (($p // {}).failed_runs // []),
         events: (($p // {}).events // [])}') ;;
  esac
  # Every unresolved event's repair state, recomputed.
  local id e
  for id in $(printf '%s' "$json" | jq -r '.events[] | select(.resolved_at == null) | .id'); do
    e=$(printf '%s' "$json" | jq -c --arg id "$id" '[.events[] | select(.id == $id)][0]')
    e=$(fleet_master_event_repair "$slug" "$base" "$wt" "$e" "$settled" "$round" "$d" "$dl")
    json=$(printf '%s' "$json" | jq -c --argjson e "$e" '.events |= map(if .id == $e.id then $e else . end)')
  done
  # Every unresolved event and the newest ten resolved ones, the unresolved
  # last: the gate reads the tail of the list.
  printf '%s' "$json" | jq --arg schema "$FLEET_MASTER_SCHEMA" --arg iso "$(fleet_iso "$round")" --argjson ep "$round" '
    {schema: $schema, observed_at: $iso, observed_at_epoch: $ep} + .
    | .events = ((.events | map(select(.resolved_at != null)) | .[-10:]) + (.events | map(select(.resolved_at == null))))' \
    | fleet_write_atomic "$f" || fleet_log "master: $f 를 쓰지 못했다"
  rm -rf "$d"
}

fleet_master_stage() {
  # One round over every watched pair, under `master.lock`. Run it in a
  # subshell of its own: its EXIT trap releases what it holds, whichever way
  # it ends. A lock whose pid is gone, or older than
  # FLEET_MASTER_LOCK_STALE_SECONDS on the real clock, is broken; a live one
  # means another round is running and this one does nothing.
  local lockd holder mt round dl pairs slug base wt
  command -v jq >/dev/null 2>&1 || return 0
  mkdir -p "$PACE_ROOT"
  lockd="$PACE_ROOT/master.lock"
  # The traps are set before the lock is taken and remove it only once it is
  # this round's, so a signal between the two neither leaves it nor takes
  # another round's.
  FLEET_MASTER_LOCKD=""
  trap 'fleet_backlog_unlock; [ -z "$FLEET_MASTER_LOCKD" ] || rm -rf "$FLEET_MASTER_LOCKD"' EXIT
  # A signal ends the round through `exit`, so the EXIT trap above still runs.
  trap 'exit 143' TERM INT
  if ! mkdir "$lockd" 2>/dev/null; then
    holder=$(sed -n '1p' "$lockd/pid" 2>/dev/null | tr -d '[:space:]' || true)
    mt=$(fleet_mtime "$lockd")
    if { [ -z "$holder" ] || cc_pid_exists "$holder"; } \
       && [ -n "$mt" ] && [ $(( $(fleet_master_real_now) - mt )) -le "$FLEET_MASTER_LOCK_STALE_SECONDS" ]; then
      return 0
    fi
    fleet_log "master: master.lock 을 깬다 (보유 pid ${holder:-?})"
    rm -rf "$lockd"
    mkdir "$lockd" 2>/dev/null || return 0
  fi
  FLEET_MASTER_LOCKD="$lockd"
  printf '%s\n' "$$" > "$lockd/pid"
  round=$(fleet_now)
  dl=$(( $(fleet_master_real_now) + FLEET_MASTER_BUDGET_SECONDS ))
  pairs=$(fleet_master_pairs)
  while IFS="$(printf '\t')" read -r slug base wt <&5; do
    [ -n "$slug" ] || continue
    fleet_master_pair "$slug" "$base" "$wt" "$round" "$dl" || fleet_log "master: $slug $base 관측이 실패했다"
  done 5<<EOF
$pairs
EOF
}

# ---------------------------------------------------------------------------
# REPAIR RUNS — the claim, the shared run function, the observer child and the
# job's wait.
# ---------------------------------------------------------------------------

fleet_repair_recognized() {
  # fleet_repair_recognized <record json> — rc 0 when the record's manifest
  # carries a `수리 사건` row whose fourth cell is the record's event id. A
  # record that only says `kind: master-repair` is not a repair run.
  local m e
  m=$(printf '%s' "$1" | jq -r '.manifest_path // empty')
  e=$(printf '%s' "$1" | jq -r '.event_id // empty')
  [ -n "$m" ] && [ -r "$m" ] && [ -n "$e" ] || return 1
  grep -E '^- `수리 사건` ' "$m" 2>/dev/null | awk -F'|' -v e="$e" '
    { v = $4; gsub(/^[ \t]+|[ \t]+$/, "", v); if (v == e) f = 1 } END { exit !f }'
}

FLEET_CLAIM_ORIG=""; FLEET_CLAIM_LINE=""; FLEET_CLAIM_MANIFEST=""; FLEET_CLAIM_RUN_ID=""; FLEET_CLAIM_WT=""
fleet_repair_claim() {
  # fleet_repair_claim <lane> <job pid> <inventory json> <dirs json> <home> —
  # claim the oldest pending repair record for this lane under `backlog.lock`.
  # rc 0 with FLEET_CLAIM_* set and this process's repair marker written; rc 1
  # when nothing was claimed. THE REPAIR ADMISSION: the record is a repair run
  # by its manifest's row, passes the park checks, is not recorded on another
  # account, its repository's switch is not off, fewer than
  # FLEET_REPAIR_SEATS repair runs are alive, and this account's 5h window
  # passes. The fleet ceiling and lane occupancy are not asked: the repair run
  # has its own seat.
  local lane="$1" jpid="$2" inv="$3" dirs="$4" home="$5" head rec id park="" clause="" detail="-"
  local manifest="" run_id="" wt="" run_dir rec_dir slug n leases="" ctx res now iso line
  now=$(fleet_now); iso=$(fleet_iso "$now")
  fleet_backlog_lock || return 1
  head=$(fleet_backlog_head repair)
  if [ -z "$head" ]; then fleet_backlog_unlock; return 1; fi
  rec="$head"; id=$(printf '%s' "$rec" | jq -r '.id // "?"')
  fleet_repair_recognized "$rec" || park=repair-unrecognized
  [ -n "$park" ] || park=$(fleet_dispatch_park_reason "$rec")
  if [ -z "$park" ]; then
    manifest=$(printf '%s' "$rec" | jq -r '.manifest_path')
    run_id=$(fleet_manifest_field "$manifest" run-id)
    wt=$(fleet_manifest_field "$manifest" origin-worktree)
    [ -n "$run_id" ] || park=manifest-missing
  fi
  if [ -n "$park" ]; then
    line=$(printf '%s' "$rec" | jq -c --arg r "$park" '.status = "parked" | .park_reason = $r')
    fleet_backlog_rewrite "$head" "$line" || fleet_log "repair $lane: $id 의 park 재작성이 원본 줄을 찾지 못했다 (rc=$?)"
    fleet_backlog_unlock
    fleet_log "repair $lane: $id park — $park"
    return 1
  fi
  run_dir="${XDG_STATE_HOME:-$HOME/.local/state}/cc-cmds/run/$run_id"
  rec_dir=$(sed -n '1p' "$run_dir/config-dir" 2>/dev/null || true); rec_dir=${rec_dir%/}
  if [ -n "$rec_dir" ] && [ "$rec_dir" != "${home%/}" ]; then clause=lane; detail=lane-mismatch; fi
  slug=$(printf '%s' "$rec" | jq -r '.slug // ""')
  if [ -z "$clause" ] && fleet_master_switch_off "$slug"; then clause=switch; fi
  if [ -z "$clause" ]; then
    n=$(fleet_busy_repair_live | grep -c . || true)
    [ "${n:-0}" -lt "$FLEET_REPAIR_SEATS" ] || clause=repair-seat
  fi
  if [ -z "$clause" ]; then
    if fleet_lend_ids "$inv" | jq -e --arg l "$lane" 'any(.[]; . == $l)' >/dev/null 2>&1; then
      leases=$(fleet_lend_leases) || { clause=window; detail=lending-unrouted; }
    fi
    if [ -z "$clause" ]; then
      ctx=$(fleet_context "$now" "$inv" "$leases")
      res=$(fleet_cap_eval "$ctx" "$dirs" "$lane" | jq -r '.result')
      [ "$res" = pass ] || { clause=window; detail="${res:-unknown}"; }
    fi
  fi
  if [ -n "$clause" ]; then
    line=$(printf '%s' "$rec" | jq -c --arg at "$iso" --arg c "$clause" \
            '.last_refusal_at = $at | .last_refusal_verdict = "-" | .last_refusal_clause = $c')
    fleet_backlog_rewrite "$head" "$line" || fleet_log "repair $lane: $id 의 거부 재작성이 원본 줄을 찾지 못했다 (rc=$?)"
    fleet_backlog_unlock
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$iso" "$lane" "$clause" "-" "$id" "$detail" >> "$PACE_ROOT/refusals.tsv"
    fleet_log "repair $lane: $id 거부 — 절 $clause/$detail"
    return 1
  fi
  line=$(printf '%s' "$rec" | jq -c --arg l "$lane" --arg at "$iso" \
          '.status = "dispatched" | .dispatched_lane = $l | .dispatched_at = $at')
  if ! fleet_backlog_rewrite "$head" "$line"; then
    fleet_backlog_unlock
    fleet_log "repair $lane: $id 는 이미 다른 쪽이 집었다 — 기동하지 않는다"
    return 1
  fi
  fleet_busy_write "$lane" "$run_id" "$jpid" || fleet_log "repair $lane: 수리 표지를 쓰지 못했다"
  fleet_backlog_unlock
  FLEET_CLAIM_ORIG="$rec"; FLEET_CLAIM_LINE="$line"; FLEET_CLAIM_MANIFEST="$manifest"
  FLEET_CLAIM_RUN_ID="$run_id"; FLEET_CLAIM_WT="$wt"
  return 0
}

fleet_run_record() {
  # fleet_run_record <lane> <home> <original line> <dispatched line>
  # <manifest> <run id> <origin worktree> <lending 0|1> [no-master] — the run
  # of one claimed record, the backlog dispatch's and a repair run's alike:
  # the report stub, the watchers, the lending pin, `run.sh` in the
  # foreground, and the `done` rewrite.
  #
  # THE FOUR PREPARATION STEPS, IN THIS ORDER: the report stub, then one
  # snapshot so the run directory exists, THEN the watcher — a watcher started
  # before the directory exists reads its absence as "the run went away" and
  # exits quietly — and THEN the CI poller, which reads the directory the same
  # way and so carries the same ordering debt. Then `run.sh` in the foreground,
  # and this process waits.
  # THE LEDGER IS WHERE `run.sh` WRITES IT: under the parent of the git common
  # dir measured from the origin worktree, not under the worktree itself. From
  # the main worktree the two are the same file; from a linked one they are
  # not, and the stub, the watcher and the poller then watched a file the run
  # never wrote — the watcher's silence arm fired on a healthy run. A path that
  # is not a git worktree keeps the worktree-relative ledger.
  local lane="$1" home="$2" orig="$3" line="$4" manifest="$5" run_id="$6" wt="$7" lend="$8" only="${9:-}"
  local run_dir lbase="" ledger rc=0 line2 id iso
  run_dir="${XDG_STATE_HOME:-$HOME/.local/state}/cc-cmds/run/$run_id"
  id=$(printf '%s' "$orig" | jq -r '.id // "?"')
  iso=$(fleet_iso "$(fleet_now)")
  if [ -n "$wt" ]; then
    lbase=$( { cd "$wt" 2>/dev/null && git rev-parse --path-format=absolute --git-common-dir 2>/dev/null; } || true)
    [ -z "$lbase" ] || lbase=$(dirname "$lbase")
  fi
  ledger="${lbase:-$wt}/docs/pipeline-run/$run_id.md"
  if [ -n "$wt" ] && [ ! -e "$ledger" ]; then
    mkdir -p "$(dirname "$ledger")"
    printf '# 파이프라인 런 %s\n\n런 id: %s · 파견 레인: %s · 파견 시각: %s\n' "$run_id" "$run_id" "$lane" "$iso" > "$ledger"
  fi
  fleet_start_watch "$home" "$FLEET_DIR" "$manifest" "$run_dir" "$ledger" "" "$only"
  # THE LENDING PIN, HERE ONLY. The router reads it as the run's seat and
  # admits the run on the lending account alone. It is written here and not in
  # `fleet_start_watch`, which a boot-time re-entry also calls on a run a
  # person supervised. A run that cannot carry the pin is not started: the
  # record goes back to pending for a later tick.
  if [ "$lend" = 1 ] && ! printf '%s\n' "$lane" | fleet_write_atomic "$run_dir/fleet-lane"; then
    fleet_backlog_rewrite_locked "$line" "$orig" || fleet_log "run $lane: $id 의 pending 되돌림이 원본 줄을 찾지 못했다 (rc=$?)"
    fleet_log "run $lane: $id 의 대여 좌석 고정 기록을 쓰지 못했다 — 기동하지 않는다"
    return 0
  fi
  fleet_log "run $lane: $id 기동 — run $run_id (매니페스트 $manifest)"
  CLAUDE_CONFIG_DIR="$home" bash "$FLEET_DIR/run.sh" --manifest "$manifest" || rc=$?
  line2=$(printf '%s' "$line" | jq -c '.status = "done"')
  fleet_backlog_rewrite_locked "$line" "$line2" || fleet_log "run $lane: $id 의 done 재작성이 실패했다 (rc=$?) — 레코드는 dispatched 로 남는다"
  fleet_log "run $lane: $id 종료 rc=$rc"
  return 0
}

FLEET_REPAIR_CHILD=""
fleet_master_repair_launch() {
  # fleet_master_repair_launch <lane> <job pid> <log> — THE ONE BACKGROUND
  # LAUNCH OF THIS FILE'S OWN SUBCOMMANDS besides the observer child. It stays
  # in the job's process group, and the job waits on the run it claims.
  bash "$FLEET_DIR/fleet.sh" repair-run "$1" "$2" > "$3" 2>&1 < /dev/null &
  FLEET_REPAIR_CHILD=$!
}

FLEET_MW_DIR=""; FLEET_MW_STAGE=""
fleet_master_watch_exit() {
  # The stage releases master.lock in its own EXIT trap, so it is waited for:
  # a child that ended first would leave the lock behind it.
  if [ -n "$FLEET_MW_STAGE" ]; then
    fleet_master_kill_tree "$FLEET_MW_STAGE"
    wait "$FLEET_MW_STAGE" 2>/dev/null || true
  fi
  [ -z "$FLEET_MW_DIR" ] || rm -rf "$FLEET_MW_DIR"
}
fleet_master_watch() {
  # fleet_master_watch <lane> <job pid> <job fingerprint> — the observer child
  # of a waiting dispatch job: the master stage every period while that job is
  # alive, and a repair run when a pending repair record is there and no
  # repair run this child started is still alive.
  local lane="$1" jpid="$2" jfp="$3" d opid ofp mt rp="" rfp="" i n log
  case "$lane" in ''|-*|*[!a-z0-9-]*|sensor) fleet_usage "master-watch <id> <잡 pid> <잡 지문> — 레인 id 형식이 아니다: $lane" ;; esac
  case "$jpid" in ''|*[!0-9]*) fleet_usage "master-watch <id> <잡 pid> <잡 지문> — 잡 pid 가 숫자가 아니다: $jpid" ;; esac
  [ -n "$jfp" ] || fleet_usage "master-watch <id> <잡 pid> <잡 지문> — 지문이 비었다"
  command -v jq >/dev/null 2>&1 || fleet_die "jq 가 없습니다"
  mkdir -p "$(fleet_master_dir)"
  d="$(fleet_master_dir)/watch.$jpid"
  if ! mkdir "$d" 2>/dev/null; then
    opid=$(sed -n '1p' "$d/owner" 2>/dev/null | tr -d '[:space:]' || true); ofp=$(sed -n '2p' "$d/owner" 2>/dev/null || true)
    mt=$(fleet_mtime "$d")
    if { [ -n "$opid" ] && cc_holder_is_live "$opid" "$ofp"; } \
       || { [ -z "$opid" ] && [ -n "$mt" ] && [ $(( $(fleet_master_real_now) - mt )) -lt 10 ]; }; then
      fleet_log "master-watch $lane: 잡 $jpid 의 관측 자식이 이미 있다"
      return 0
    fi
    rm -rf "$d"
    mkdir "$d" 2>/dev/null || return 0
  fi
  FLEET_MW_DIR="$d"
  trap 'fleet_master_watch_exit' EXIT
  trap 'exit 143' TERM INT
  printf '%s\n%s\n' "$$" "$(cc_proc_fingerprint "$$")" | fleet_write_atomic "$d/owner"
  log="$(fleet_master_dir)/repair-run.$jpid.log"
  while cc_holder_is_live "$jpid" "$jfp"; do
    ( fleet_master_stage ) &
    FLEET_MW_STAGE=$!
    wait "$FLEET_MW_STAGE" || true
    FLEET_MW_STAGE=""
    cc_holder_is_live "$jpid" "$jfp" || break
    if [ -n "$(fleet_backlog_head repair)" ] && ! { [ -n "$rp" ] && cc_holder_is_live "$rp" "$rfp"; }; then
      fleet_master_repair_launch "$lane" "$jpid" "$log"
      rp="$FLEET_REPAIR_CHILD"; rfp=$(cc_proc_fingerprint "$rp")
      printf '%s\n%s\n' "$rp" "$rfp" | fleet_write_atomic "$d/launch"
    fi
    i=0; n=$(fleet_master_interval)
    while [ "$i" -lt "$n" ] && cc_holder_is_live "$jpid" "$jfp"; do sleep 1; i=$(( i + 1 )); done
  done
  return 0
}

fleet_master_watch_stop() {
  # fleet_master_watch_stop <job pid> — end that job's observer child, and give
  # a repair run it had just started the time to claim or give up: a claim
  # made after the job's last look must still be waited for.
  local d pid fp lp="" lfp="" n=0
  d="$(fleet_master_dir)/watch.$1"
  # Either file may be absent — a job whose tick started no observer child, or
  # a child that launched nothing — and an absent file reads as empty.
  pid=$(sed -n '1p' "$d/owner" 2>/dev/null | tr -d '[:space:]' || true); fp=$(sed -n '2p' "$d/owner" 2>/dev/null || true)
  lp=$(sed -n '1p' "$d/launch" 2>/dev/null | tr -d '[:space:]' || true); lfp=$(sed -n '2p' "$d/launch" 2>/dev/null || true)
  if [ -n "$pid" ] && cc_holder_is_live "$pid" "$fp"; then
    kill -TERM "$pid" 2>/dev/null || true
    while cc_pid_exists "$pid" && [ "$n" -lt 50 ]; do sleep 0.2; n=$(( n + 1 )); done
  fi
  n=0
  if [ -n "$lp" ]; then
    while cc_holder_is_live "$lp" "$lfp" && [ -z "$(fleet_busy_repair_live "$1")" ] \
          && [ "$n" -lt $(( (FLEET_BACKLOG_LOCK_WAIT_SECONDS + 20) * 5 )) ]; do
      sleep 0.2; n=$(( n + 1 ))
    done
  fi
  return 0
}

fleet_job_wait_repairs() {
  # The job's main process, once its own run is over and its own marker is
  # gone: wait while a repair run naming this job is alive, then stop the
  # observer child, then look once more under the lock — a claim the child
  # made between the last look and its stop is waited for too. At most
  # FLEET_REPAIR_WAIT_MAX_SECONDS in all; launchd tears the group down when
  # this process returns, so nothing of the job's may still be running then.
  local start live
  start=$(fleet_master_real_now)
  while :; do
    while [ -n "$(fleet_busy_repair_live "$$")" ]; do
      if [ $(( $(fleet_master_real_now) - start )) -ge "$FLEET_REPAIR_WAIT_MAX_SECONDS" ]; then
        fleet_log "job $$: 수리 런을 ${FLEET_REPAIR_WAIT_MAX_SECONDS}초 기다렸다 — 기다림을 끝낸다"
        fleet_master_watch_stop "$$"
        return 0
      fi
      sleep 1
    done
    fleet_master_watch_stop "$$"
    live=""
    if fleet_backlog_lock; then live=$(fleet_busy_repair_live "$$"); fleet_backlog_unlock; fi
    [ -n "$live" ] || return 0
  done
}

fleet_repair_run() {
  # fleet_repair_run <lane> <job pid> — claim one repair record for this lane
  # and run it in this process's foreground. Started by the observer child of
  # the dispatch job <job pid>, whose wait keeps the group alive meanwhile.
  local lane="$1" jpid="$2" inv dirs home lend=0
  case "$lane" in ''|-*|*[!a-z0-9-]*|sensor) fleet_usage "repair-run <id> <잡 pid> — 레인 id 형식이 아니다: $lane" ;; esac
  case "$jpid" in ''|*[!0-9]*) fleet_usage "repair-run <id> <잡 pid> — 잡 pid 가 숫자가 아니다: $jpid" ;; esac
  command -v jq >/dev/null 2>&1 || fleet_die "jq 가 없습니다"
  mkdir -p "$PACE_ROOT"
  inv=$(fleet_inventory_json)
  dirs=$(fleet_dirs_json "$inv")
  home=$(printf '%s' "$inv" | jq -r --arg i "$lane" '.accounts[] | select(.id == $i) | .config_dir')
  if [ -z "$home" ]; then fleet_log "repair-run $lane: 인벤토리에 그 레인이 없다"; return 0; fi
  fleet_lend_ids "$inv" | jq -e --arg l "$lane" 'any(.[]; . == $l)' >/dev/null 2>&1 && lend=1
  trap 'fleet_backlog_unlock; fleet_busy_drop' EXIT
  fleet_repair_claim "$lane" "$jpid" "$inv" "$dirs" "$home" || return 0
  fleet_run_record "$lane" "$home" "$FLEET_CLAIM_ORIG" "$FLEET_CLAIM_LINE" "$FLEET_CLAIM_MANIFEST" \
    "$FLEET_CLAIM_RUN_ID" "$FLEET_CLAIM_WT" "$lend" no-master
}

fleet_dispatch() {
  local lane="$1" home state verdict head rec id line line2 clause="" detail="-" park probe rc=0 occ
  local manifest run_id run_dir wt ledger now iso inv dirs ctx why rec_dir other census busy res
  local lend_ids lend leases b_same b_non
  command -v jq >/dev/null 2>&1 || fleet_die "jq 가 없습니다"
  # (1) THE ID. A malformed id is a usage error, not a lane: it can never have
  #     been rendered into a label.
  case "$lane" in
    ''|-*|*[!a-z0-9-]*|sensor) fleet_usage "레인 id 형식이 아니다: $lane — 소문자·숫자·하이픈, 첫 글자는 소문자나 숫자, sensor 제외" ;;
  esac
  mkdir -p "$PACE_ROOT"
  now=$(fleet_now); iso=$(fleet_iso "$now")
  # The lane `fleet_start_watch` starts this job's master observer child for.
  FLEET_LANE="$lane"

  # (1b) BOOT-TIME RE-ENTRY, BEFORE ELIGIBILITY AND THE BACKLOG LOCK. The
  #      eligibility below is for a new run on this label's account, and a run
  #      this boot cut is re-entered on its own recorded lane whatever this
  #      label's state; the backlog lock and its EXIT trap must not wrap a call
  #      that runs for hours. A tick that re-entered a run starts no backlog
  #      head.
  if fleet_reentry_tick "$lane"; then
    fleet_log "dispatch $lane: 이번 틱은 재진입을 돌렸다 — 백로그는 다음 틱에 본다"
    fleet_job_wait_repairs
    return 0
  fi

  # (1c) THE MASTER STAGE, after the re-entry branch and before eligibility: a
  #      lane that may not start anything this tick still keeps the base-branch
  #      readings fresh. Its own subshell, so its lock and trap stay its own.
  ( fleet_master_stage ) || fleet_log "dispatch $lane: master 단계가 실패했다 (rc=$?)"

  # (2) ELIGIBILITY, BEFORE THE LOCK. A lane that may not work now ends with one
  #     log line and no refusal row: that is "this lane is idle", not a verdict
  #     on the head record, and a row per tick would bury every real refusal.
  #     The router part is the router's own new-run predicate over a context
  #     this file builds. A lane enrolled for lending is judged over the real
  #     lease table, and does not start when that table cannot be read or the
  #     inventory cannot be routed: either way the router's lending checks
  #     cannot be made.
  inv=$(fleet_inventory_json)
  dirs=$(fleet_dirs_json "$inv")
  lend_ids=$(fleet_lend_ids "$inv")
  lend=0
  printf '%s' "$lend_ids" | jq -e --arg l "$lane" 'any(.[]; . == $l)' >/dev/null 2>&1 && lend=1
  leases=""; why=""
  if [ "$lend" = 1 ]; then leases=$(fleet_lend_leases) || why=lending-unrouted; fi
  if [ -z "$why" ]; then
    ctx=$(fleet_context "$now" "$inv" "$leases")
    why=$(fleet_reason_of "$ctx" "$dirs" "$lane")
    if [ "$why" = inventory-broken ] && fleet_lend_lane_raw "$lane"; then why=lending-unrouted; fi
  fi
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
  # (2b) AN IDLE LANE TAKES A PENDING REPAIR RECORD FIRST, through the repair
  #      admission and not the backlog's: the repair run has its own seat.
  if fleet_repair_claim "$lane" "$$" "$inv" "$dirs" "$home"; then
    fleet_run_record "$lane" "$home" "$FLEET_CLAIM_ORIG" "$FLEET_CLAIM_LINE" "$FLEET_CLAIM_MANIFEST" \
      "$FLEET_CLAIM_RUN_ID" "$FLEET_CLAIM_WT" "$lend"
    fleet_busy_drop
    fleet_job_wait_repairs
    return 0
  fi
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
    #     no label holds, including an account that has left the label set since
    #     install (draining, disabled, config dir gone): park, because no lane
    #     would ever take it. The record is never rewritten here.
    #     A RUN RECORDED ON A LENDING HOME WITHOUT A LENDING PIN is a run a
    #     person supervised on that seat. It does not carry on as a lent run,
    #     so it parks on every lane, the lending lane included; a run this file
    #     started on the lending lane carries the pin and goes by the rule
    #     above. A head with neither record is a new run any lane may take.
    rec_dir=$(sed -n '1p' "$run_dir/config-dir" 2>/dev/null || true)
    rec_dir=${rec_dir%/}
    if [ -n "$rec_dir" ] && [ -z "$(sed -n '1p' "$run_dir/fleet-lane" 2>/dev/null || true)" ] \
       && fleet_lend_home "$inv" "$rec_dir"; then
      park=lane-record
    elif [ -n "$rec_dir" ] && [ "$rec_dir" != "${home%/}" ]; then
      other=$(fleet_label_homes_json "$inv" "$dirs" | jq -r --arg d "$rec_dir" '[.[] | select(.home == $d) | .id] | .[0] // empty')
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
    #     as the fleet ceiling, refuses. The ceiling counts the markers of the
    #     lanes not enrolled for lending, and a lending lane is not held to it:
    #     its own marker and its occupancy below still hold it to one run, and
    #     what it may spend is bounded by the router's lending checks.
    probe=$(LANE_PROBE_HORIZON_SECONDS="$FLEET_LANE_HORIZON_SECONDS" bash "$LANE_PROBE" 2>/dev/null) || rc=$?
    if [ "$rc" != "0" ]; then
      clause=lane; detail=probe-failed
    else
      census=$(printf '%s\n' "$probe" | fleet_census_parse "$inv")
      [ -n "$census" ] || census='[]'
      busy=$(fleet_busy_count "$lane" "$census" "$lend_ids")
      read -r _ b_same b_non _ <<EOF
$busy
EOF
      if [ "$b_same" -gt 0 ]; then
        clause=lane; detail=occupied
      elif [ "$lend" != 1 ] && [ "$b_non" -ge "$FLEET_TARGET_CONCURRENCY" ]; then
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
    #     an ineligible lane, reached inside the lock. A lending lane reads the
    #     lease table again here, and then asks the router's lending admission
    #     once more with the run's driver reservation counted: a refusal there
    #     is the same answer as an ineligible lane too.
    if [ "$lend" = 1 ] && ! leases=$(fleet_lend_leases); then
      fleet_backlog_unlock
      fleet_log "dispatch $lane: 부적격 — lending-unrouted (임대 표를 읽을 수 없다; 아무것도 띄우지 않는다)"
      return 0
    fi
    ctx=$(fleet_context "$(fleet_now)" "$inv" "$leases")
    res=$(fleet_cap_eval "$ctx" "$dirs" "$lane" | jq -r '.result')
    case "$res" in
      pass) ;;
      mismatch|login)
        fleet_backlog_unlock
        fleet_log "dispatch $lane: 부적격 — $res (사용량 파일이 다시 발행됐다; 아무것도 띄우지 않는다)"
        return 0 ;;
      *) clause=window; detail="$res" ;;
    esac
    if [ -z "$clause" ] && [ "$lend" = 1 ]; then
      why=lending-closed
      if ctx=$(fleet_lend_driver_ctx "$ctx" "$dirs" "$lane"); then
        why=$(fleet_reason_of "$ctx" "$dirs" "$lane") || why=lending-closed
      fi
      if [ -n "$why" ]; then
        fleet_backlog_unlock
        fleet_log "dispatch $lane: 부적격 — $why (드라이버 예약을 센 대여 입장; 아무것도 띄우지 않는다)"
        return 0
      fi
    fi
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

  # (11) THE RUN, through the function a repair run uses too. Then this job
  # drops its own marker — its run no longer holds a seat — and waits for any
  # repair run its observer child started.
  fleet_run_record "$lane" "$home" "$rec" "$line" "$manifest" "$run_id" "$wt" "$lend"
  fleet_busy_drop
  fleet_job_wait_repairs
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
  local label now hb st age inv orphans f n_live=0 id lend_ids n_lend
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
  # The ceiling line counts the lanes it binds. A lane enrolled for lending
  # runs beside it, bounded by its occupancy instead, and gets its own line.
  lend_ids=$(fleet_lend_ids "$inv")
  for f in "$PACE_ROOT/busy"/*; do
    [ -f "$f" ] || continue
    fleet_busy_is_repair "$f" && continue
    if fleet_busy_live "$f" '[]'; then
      id=${f##*/}; id=${id%.*}
      printf '%s' "$lend_ids" | jq -e --arg l "$id" 'any(.[]; . == $l)' >/dev/null 2>&1 || n_live=$(( n_live + 1 ))
      printf '실행 표지: %s (런 %s)\n' "${f##*/}" "$(sed -n '3p' "$f")"
    fi
  done
  printf '살아 있는 실행 표지: %s / 상한 %s\n' "$n_live" "$FLEET_TARGET_CONCURRENCY"
  for id in $(printf '%s' "$lend_ids" | jq -r '.[]'); do
    n_lend=0
    for f in "$PACE_ROOT/busy/$id".*; do
      [ -f "$f" ] || continue
      fleet_busy_is_repair "$f" && continue
      fleet_busy_live "$f" '[]' && n_lend=$(( n_lend + 1 ))
    done
    printf '%s 레인 살아 있는 실행 표지: %s / 점유 상한 %s\n' "$id" "$n_lend" "$FLEET_LANE_OCCUPANCY_MAX"
  done
  # The repair switch and the repair seat: one line, beside the ceiling it
  # does not count against.
  local sw="꺼짐 없음" n_rep
  if [ -f "$PACE_ROOT/master-repair.off" ]; then
    if [ -s "$PACE_ROOT/master-repair.off" ]; then
      sw="꺼짐: $(grep -v '^[[:space:]]*$' "$PACE_ROOT/master-repair.off" | tr '\n' ' ' | sed 's/ $//')"
    else
      sw="모든 저장소 꺼짐"
    fi
  fi
  n_rep=$(fleet_busy_repair_live | grep -c . || true)
  printf '수리 런: 스위치 %s · 살아 있는 수리 표지 %s / 자리 %s\n' "$sw" "${n_rep:-0}" "$FLEET_REPAIR_SEATS"
}

main() {
  case "${1:-}" in
    sensor)   fleet_sensor ;;
    dispatch) [ -n "${2:-}" ] || fleet_usage "dispatch <id> — 레인(인벤토리 id)이 필요하다"; fleet_dispatch "$2" ;;
    master-watch) fleet_master_watch "${2:-}" "${3:-}" "${4:-}" ;;
    repair-run)   fleet_repair_run "${2:-}" "${3:-}" ;;
    agent)
      case "${2:-}" in
        install)   fleet_agent_install ;;
        uninstall) fleet_agent_uninstall ;;
        status)    fleet_agent_status ;;
        *) fleet_usage "agent install|uninstall|status" ;;
      esac ;;
    *) fleet_usage "sensor | dispatch <id> | master-watch <id> <잡 pid> <잡 지문> | repair-run <id> <잡 pid> | agent install|uninstall|status" ;;
  esac
}

main "$@"
