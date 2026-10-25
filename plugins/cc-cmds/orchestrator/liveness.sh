#!/usr/bin/env bash
# liveness.sh — the shared read-only predicates about a run's state.
#
# WHY THIS FILE EXISTS. Three consumers asked "is this run still going?" and
# each answered it with its own code: the gate's render counted `*.pid` files
# without testing whether any process was behind them, `gate_live_stages()`
# tested `kill -0` but not pid reuse, and the watcher tested both. Measured: 21
# pid files, 5 live processes, and a render that reported "살아 있는 스테이지:
# 1개 / 런 상태: 진행 중" for a run whose recorded pid was dead. The divergence
# was not a bug in any one of them — it was three implementations of one
# predicate, which is a thing that cannot stay consistent.
#
# NOTHING HERE WRITES. That is the property that lets a status line call these
# on every render. `ledger_idle_seconds` is deliberately absent: computing an
# elapsed-since-last-growth needs somewhere to remember the previous size, the
# watcher remembers it in `watch.state`, and a write is exactly what a status
# line may not do.
#
# THE SETTLEMENT CANDIDATE PREDICATE AND THE `.settling` RECLAIM live in
# `cc_orphan_stages` below, and they are here rather than in the gate's prelude
# because three readers — the watcher's alarm, the snapshot's `orphan_stages[]`
# and the prelude that settles a lost dispatch as `외부 종료` — must see one
# list. A settler that pre-empts a record by renaming `<seg>.pid` to
# `<seg>.pid.settling.<pid>` and then dies leaves a name no `*.pid` glob walks,
# so a visible orphan would become an invisible one; the reclaim rule (a
# `.settling` marker older than 60 seconds is listed again) sits inside the
# enumeration so every reader inherits it without spelling it a second time.
#
# Compatibility: bash 3.2 — no associative arrays, no `mapfile`, no `wait -n`.

# Sibling resolution uses `$BASH_SOURCE` and not `$0`, because under a
# source-only seam `$0` is the SOURCING script.
CC_LIVENESS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
export CC_LIVENESS_DIR

cc_stage_is_live() {
  # cc_stage_is_live <run-dir> <segment> — succeeds when that segment's recorded
  # pid is still the process the run started.
  #
  # ONE STAGE AT A TIME, so that a consumer needing the answer about a single
  # segment — which name belongs beside a "running" glyph — can have it without
  # growing a judgement of its own. `cc_live_stages` below is this function in a
  # loop, and that is the whole relationship between them: the census and the
  # label cannot disagree because there is nothing for them to disagree about.
  #
  # `kill -0` on recorded pids, never `wait -n`: that builtin does not exist on
  # the interpreter floor, and a re-attached stage is not this shell's child so
  # `wait` would report a clean exit for a process it never reaped.
  #
  # The `.start` fingerprint is what separates "still running" from "that pid
  # belongs to something else now". A run directory deliberately survives a
  # reboot, so a recorded pid can come back pointing at an unrelated process.
  local run_dir="$1" seg="$2" f pid rec now
  [ -n "$run_dir" ] && [ -n "$seg" ] || return 1
  f="$run_dir/$seg.pid"
  [ -f "$f" ] || return 1
  # The fingerprint's shape must not depend on the sourcing script's locale, or
  # two of the four consumers compare different strings for the same process and
  # disagree about whether it is alive. Pinning it here is not enough on its own:
  # `LC_TIME` loses to `LC_ALL`, so a consumer launched from a shell that exports
  # `LC_ALL` kept reading the localised form while the writer — which clears
  # `LC_ALL` before it records — had written the C form. The capture itself
  # therefore pins `LC_ALL`, which nothing outranks; this stays for the callers
  # that read a fingerprint without going through the capture.
  local LC_TIME=C
  export LC_TIME
  # A pid file is a STAGE only if it carries a sibling one of the two spawners
  # leaves beside it: both write `<name>.start`, and the driver writes
  # `<stage>.pgid` on top of that. The glob its callers walk has no namespace,
  # and a run directory holds pids that are not stages — the watcher's
  # `watch.pid` is one — so without this the count answers a different question
  # than its name, and the run's termination condition, which has no resolving
  # verb, would never come true while a watcher ran. `.start` alone is NOT the
  # test, and the reason is no longer that the driver declines to write one: a
  # run directory laid down before the driver started recording fingerprints
  # carries only `.pgid`, so requiring `.start` would silently undercount every
  # stage in it.
  [ -f "$run_dir/$seg.start" ] || [ -f "$run_dir/$seg.pgid" ] || return 1
  pid=$(cat "$f" 2>/dev/null)
  [ -n "$pid" ] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  # IDENTITY IS VERIFIED, NEVER ASSUMED. The two spawners leave the SAME
  # handle — a start-time fingerprint — so this asks for it first, and its
  # absence now means an older run directory rather than a different spawner.
  # Skipping the check whenever that handle was missing is what left the
  # driver's stages on a bare `kill -0`, which is the pid-reuse hole this
  # file exists to close.
  rec=$(cat "$run_dir/$seg.start" 2>/dev/null || true)
  if [ -n "$rec" ]; then
    now=$(cc_proc_fingerprint "$pid")
    [ "$rec" = "$now" ] || return 1
    return 0
  fi
  # NOTHING TO COMPARE AGAINST — its own case, not a pass. That is what this
  # branch originally meant, and it means it again now that both spawners
  # record a fingerprint. An empty `.start` is reachable: either spawner's
  # redirection creates the file before `ps` writes into it. A missing one means
  # a run directory a driver laid down before it recorded fingerprints at all,
  # and the `.pgid` compare below is the FALLBACK for exactly those directories
  # — not the driver's regular path. An empty or unreadable `.pgid` is reachable
  # the same way. Not counting is the safe direction: the run's termination
  # condition has no resolving verb, so an over-count ends the run's ability to
  # finish permanently, while an under-count costs one render.
  rec=$( { cat "$run_dir/$seg.pgid" 2>/dev/null || true; } | tr -d '[:space:]')
  [ -n "$rec" ] || return 1
  now=$(cc_proc_pgid "$pid")
  [ -n "$now" ] || return 1
  [ "$rec" = "$now" ] || return 1
  return 0
}

cc_live_stages() {
  # cc_live_stages <run-dir> — count of stages actually running.
  #
  # The census, not the judgement: every decision about a single pid lives in
  # `cc_stage_is_live` above. The `if` is not stylistic — a bare `&&` here
  # returns non-zero on the last iteration when that stage is dead, and this
  # file is sourced by consumers running under `set -e`.
  local run_dir="$1" f seg n=0
  [ -n "$run_dir" ] || { printf '0'; return 0; }
  for f in "$run_dir"/*.pid; do
    [ -f "$f" ] || continue
    seg=${f##*/}; seg=${seg%.pid}
    if cc_stage_is_live "$run_dir" "$seg"; then n=$((n + 1)); fi
  done
  printf '%s' "$n"
}

cc_orphan_stages() {
  # cc_orphan_stages <run-dir> — the segment ids whose dispatch record outlived
  # the process it names, one per line.
  #
  # THIS IS THE FINGERPRINT OF A LOST DISPATCH, and it exists because that
  # failure was silent at every layer that could have spoken. `gate_launch_stage`
  # writes `<seg>.pid`, blocks on the stage, and then removes the record and
  # writes the `stage-result` row — in that order, in one function. So a record
  # that is still here while its process is gone means the line after the block
  # never ran, which means the outcome was never recorded and the stage's own
  # stream has no terminal line either. Nothing else in the run says so: the
  # dispatching shift ends normally, its stream carries a result line, and the
  # ledger shows a shift that finished and a stage that never was.
  #
  # Measured: three dispatches lost this way in one run, zero rows written, and
  # every layer reporting success. The dispatch had been issued in the
  # foreground, the harness moved it to a background task at the tool timeout
  # and reported that as a non-error, and the moved process died with the
  # shift's session.
  #
  # NARROWER THAN `! cc_stage_is_live`, deliberately. That predicate is also
  # false when a run directory predates fingerprint recording, and calling those
  # orphans would report an alarm on directories where nothing is wrong. What is
  # asked here is only "is the process this record names still here" — a dead
  # pid, or a live pid that is now somebody else. An unverifiable record is left
  # out; under-reporting costs a render, over-reporting teaches its reader to
  # ignore the alarm.
  #
  # NARROWER AGAIN WHERE A SUPERVISOR IS RECORDED. The gate's supervisor writes
  # the `stage-result` row FIRST and removes the record afterwards, so there is a
  # window — the CLI is gone, the row is being written — in which the pid alone
  # reads as an orphan, and a settler acting on that reading would write a false
  # `외부 종료` beside the real row about to land. So where `<seg>.sup` names a
  # supervisor, the record is an orphan only when the supervisor is gone too:
  # its pid dead, or — when `<seg>.sup.start` holds a fingerprint — reused. A
  # `.sup` with an empty or missing fingerprint is judged on `kill -0` alone,
  # the same reading the `.start` compare below applies to a CLI pid. A run
  # directory with no `.sup` at all behaves exactly as before.
  #
  # AND THE `.settling` RECLAIM. A settler pre-empts a record by renaming its
  # pid file to `<seg>.pid.settling.<pid>`; if it dies before appending its row
  # the record survives under a name no `*.pid` glob reaches. Those markers are
  # walked here too and listed once their mtime is older than 60 seconds — the
  # question for them is "is this PRE-EMPTION still alive", not "is the CLI",
  # so neither the pid nor the `.sup` condition applies to a reclaimed entry.
  local run_dir="$1" f seg pid rec now sup sup_rec sup_now mt nowts
  [ -n "$run_dir" ] || return 0
  for f in "$run_dir"/*.pid; do
    [ -f "$f" ] || continue
    seg=${f##*/}; seg=${seg%.pid}
    # THE RUN-SCOPE PROCESSES' OWN RECORDS LIVE HERE TOO AND ARE NOT STAGES.
    # `watch.pid` and `checks.pid` are written by loops the gate never dispatched
    # and never blocks on, so the reasoning above — "the line after the block
    # never ran" — has no counterpart for them. Left in, each normal exit of
    # either loop raises a false orphan alarm on every single run.
    #
    # THIS EXEMPTION IS BY NAME, AND IT IS A DIFFERENT MECHANISM FROM THE ONE
    # THE LIVE CENSUS USES. `cc_live_stages`/`cc_stage_is_live` above exempt the
    # same two files STRUCTURALLY — they require a `.start`/`.pgid` sibling and
    # neither loop writes one — so nothing there needs a name. Here the question
    # is only "is this pid still here", which any pid file answers, so the name
    # is the only handle there is. Reading the two exemptions as one mechanism
    # leads to deleting this line on the grounds that the structural check
    # already covers it, and then the alarm returns.
    case "$seg" in watch|checks) continue ;; esac
    pid=$(cat "$f" 2>/dev/null)
    [ -n "$pid" ] || continue
    if ! kill -0 "$pid" 2>/dev/null; then
      cc_supervisor_is_live "$run_dir" "$seg" || printf '%s\n' "$seg"
      continue
    fi
    # Alive, so the only remaining orphan is pid reuse — that pid is a different
    # process now. Judged only where a fingerprint was recorded to judge against.
    rec=$(cat "$run_dir/$seg.start" 2>/dev/null || true)
    if [ -n "$rec" ]; then
      now=$(cc_proc_fingerprint "$pid")
      if [ "$rec" != "$now" ]; then
        cc_supervisor_is_live "$run_dir" "$seg" || printf '%s\n' "$seg"
      fi
    fi
  done
  nowts=$(date -u +%s)
  for f in "$run_dir"/*.pid.settling*; do
    [ -f "$f" ] || continue
    seg=${f##*/}; seg=${seg%%.pid.settling*}
    [ -n "$seg" ] || continue
    mt=$(cc_mtime "$f")
    [ -n "$mt" ] || continue
    [ $((nowts - mt)) -gt 60 ] || continue
    printf '%s\n' "$seg"
  done
  return 0
}

cc_supervisor_is_live() {
  # cc_supervisor_is_live <run-dir> <segment> — succeeds when `<seg>.sup` names
  # a supervisor that is still the process the dispatch started.
  #
  # NO `.sup` IS "NO SUPERVISOR", i.e. failure: the caller asks this only after
  # the CLI pid has been judged gone, and a record without a supervisor is then
  # exactly what an orphan is. A `.sup` whose fingerprint file is empty or
  # absent is judged on `kill -0` alone — a supervisor that exited between pid
  # capture and fingerprint capture (a launch token it was refused, say) leaves
  # the file empty, and that is a recorded fact rather than a defect to hide.
  local run_dir="$1" seg="$2" sup rec now
  [ -f "$run_dir/$seg.sup" ] || return 1
  sup=$( { cat "$run_dir/$seg.sup" 2>/dev/null || true; } | tr -d '[:space:]')
  [ -n "$sup" ] || return 1
  kill -0 "$sup" 2>/dev/null || return 1
  rec=$(cat "$run_dir/$seg.sup.start" 2>/dev/null || true)
  [ -n "$rec" ] || return 0
  now=$(cc_proc_fingerprint "$sup")
  [ "$rec" = "$now" ]
}

cc_live_stage_records() {
  # cc_live_stage_records <run-dir> — one line per stage `cc_stage_is_live`
  # accepts: `<segment>\t<stage-id>\t<pid>\t<sup>\t<start>`.
  #
  # THE ONE SOURCE for the snapshot's `live_stages[]` and the render's list of
  # names beside "살아 있는 스테이지: N개". The census (`cc_live_stages`) is a
  # count and could not tell a router WHICH segment to `wait` on; this is the
  # same predicate returning the names, so the two cannot disagree. The stage id
  # is `<seg>#<attempt>` when `<seg>.attempt` exists and the bare segment when
  # it does not (a driver-spawned stage has no pin); `sup` is the supervisor's
  # pid from `<seg>.sup`, or `-` for a record the driver wrote.
  local run_dir="$1" f seg pid att sup start
  [ -n "$run_dir" ] || return 0
  for f in "$run_dir"/*.pid; do
    [ -f "$f" ] || continue
    seg=${f##*/}; seg=${seg%.pid}
    cc_stage_is_live "$run_dir" "$seg" || continue
    pid=$( { cat "$f" 2>/dev/null || true; } | tr -d '[:space:]')
    att=$( { cat "$run_dir/$seg.attempt" 2>/dev/null || true; } | tr -d '[:space:]')
    sup=$( { cat "$run_dir/$seg.sup" 2>/dev/null || true; } | tr -d '[:space:]')
    start=$( { cat "$run_dir/$seg.start" 2>/dev/null || true; } | tr -d '\n')
    printf '%s\t%s\t%s\t%s\t%s\n' "$seg" "$seg${att:+#$att}" "$pid" "${sup:--}" "$start"
  done
  return 0
}

cc_stage_kind() {
  # cc_stage_kind <run-dir> <ledger> <segment> — the kind of that segment's
  # stage, or empty.
  #
  # THE RUNNING KIND FIRST. The gate writes `<seg>.kind` when it launches a stage
  # and removes it when it settles one, so while the file is there it names the
  # stage that is up NOW — which the ledger cannot, because `stage-result` is
  # written when a stage ends and so names the kind that ran LAST. The driver
  # leaves no `.kind`, so its stages fall through to the ledger. An empty
  # `.kind` is reachable — the gate writes `$kind` as given, and its own lost
  # dispatch settlement guards with `종류=${kind:-미상}` — and falls through too.
  #
  # THE ROW IS MATCHED BY ITS HEAD MARK, never by the words in it. A `자율 승인`
  # row whose `argv=` quotes `stage-result` and `세그먼트=<seg> ` is not a stage
  # result, and read as a substring it became the last one and emptied the slot.
  # The segment is a whole field for the same reason.
  #
  # The one source for the status line's kind slot and the pane's running
  # detail, so the two cannot name two kinds for one stage.
  local run_dir="$1" ledger="$2" seg="$3" k=""
  [ -n "$seg" ] || return 0
  if [ -n "$run_dir" ] && [ -f "$run_dir/$seg.kind" ]; then
    k=$( { cat "$run_dir/$seg.kind" 2>/dev/null || true; } | tr -d '[:space:]')
  fi
  if [ -n "$k" ]; then printf '%s' "$k"; return 0; fi
  [ -n "$ledger" ] && [ -f "$ledger" ] || return 0
  LC_ALL=C awk -F'|' -v seg="$seg" '
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    /^- `stage-result`/ {
      hit = 0; k = ""
      for (i = 2; i <= NF; i++) {
        f = trim($i)
        if (f == "세그먼트=" seg) hit = 1
        else if (substr(f, 1, 7) == "종류=") k = substr(f, 8)
      }
      if (hit) last = k
    }
    END { printf "%s", last }
  ' "$ledger" 2>/dev/null || true
  return 0
}

cc_shift_is_live() {
  # cc_shift_is_live <run-dir> — succeeds when `shift.live` names a shift child
  # that is still the process the launcher started.
  #
  # `shift.live` holds the pid on line 1 and its fingerprint on line 2. BOTH
  # ARE REQUIRED: without the fingerprint, pid reuse after the shift ends would
  # keep the watcher's `shift_active` true forever and permanently disarm its
  # after-stage arm. The name is outside the `*.pid` glob on purpose, so a live
  # shift is never counted as a live stage.
  local run_dir="$1" pid rec now
  [ -f "$run_dir/shift.live" ] || return 1
  pid=$(sed -n '1p' "$run_dir/shift.live" 2>/dev/null | tr -d '[:space:]')
  rec=$(sed -n '2p' "$run_dir/shift.live" 2>/dev/null || true)
  [ -n "$pid" ] && [ -n "$rec" ] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  now=$(cc_proc_fingerprint "$pid")
  [ "$rec" = "$now" ]
}

cc_relay_is_live() {
  # cc_relay_is_live <run-dir> — succeeds when `relay.live` names a relay that
  # is still the process that wrote it: the seat call's gate process, waiting
  # out of turn for a shift that ended `handoff 사유=대기`.
  #
  # PID AND FINGERPRINT ONLY, the same pair `shift.live` carries on its first
  # two lines. Freshness is not asked here: a relay that stopped refreshing still
  # holds the run, so the run-end verbs read this and the watcher reads
  # `cc_relay_is_effective` below. The file outlives its relay on purpose, so
  # its mere existence says nothing.
  local run_dir="$1" pid rec
  [ -f "$run_dir/relay.live" ] || return 1
  pid=$(sed -n '1p' "$run_dir/relay.live" 2>/dev/null | tr -d '[:space:]')
  rec=$(sed -n '2p' "$run_dir/relay.live" 2>/dev/null || true)
  cc_holder_is_live "$pid" "$rec"
}

cc_relay_field() {
  # cc_relay_field <run-dir> <name> — the value of the `<name>=` line of
  # `relay.live`, or empty. Names are this file's own literals.
  [ -f "$1/relay.live" ] || return 0
  { sed -n "s/^$2=//p" "$1/relay.live" 2>/dev/null || true; } | tail -1
}

cc_relay_wait_stages() {
  # cc_relay_wait_stages <run-dir> — the keys of the stages and supervisors that
  # are live now, comma-joined, or empty: the stage half of a relay's wait set.
  #
  # THE SAME LIVENESS `gate.sh wait` POLLS — `cc_stage_is_live ||
  # cc_supervisor_is_live` — so a stage the foreground wait would have waited on
  # is one the relay waits on, including a supervisor still waiting for an
  # account with no stage pid yet. The poller's and the watcher's own pid files
  # are not stages.
  local run_dir="$1" f k keys="" seen=" "
  [ -n "$run_dir" ] || return 0
  for f in "$run_dir"/*.pid "$run_dir"/*.sup; do
    [ -f "$f" ] || continue
    k=${f##*/}
    case "$k" in *.pid) k=${k%.pid} ;; *.sup) k=${k%.sup} ;; esac
    case "$k" in ''|watch|checks) continue ;; esac
    case "$seen" in *" $k "*) continue ;; esac
    seen="$seen$k "
    if cc_stage_is_live "$run_dir" "$k" || cc_supervisor_is_live "$run_dir" "$k"; then
      keys="${keys:+$keys,}$k"
    fi
  done
  printf '%s' "$keys"
}

cc_ci_round() {
  # cc_ci_round <ledger> <segment> <head sha> — the rerun round of that
  # `(segment, head sha)`, as `키=값` lines:
  #
  #   u=<n>      `CI 처분 처분=재실행 상태=요청` rows of the pair — the budget spent
  #   a=<state>  the state of the pair's highest `회차`: 없음 (no round) · 열림 · 수락 · 실패
  #   g=<n>      the highest `회차` of the pair's `상태=수락` rows, 0 when none
  #   f=<n>      the distinct `head sha` values of the segment's `처분=수정` rows
  #   fix=<0|1>  whether the pair itself carries a `처분=수정` row
  #   base=<v>   `기본 브랜치` of the `요청` row of round g, empty when none
  #   ad=<v>     `처분` of the highest `회차` — 재실행 or 라벨, empty when none
  #   ra=<state> the state of the pair's highest `처분=재실행` round, 없음 when none
  #   lab=<0|1>  whether the pair carries any `처분=라벨` row
  #   max=<n>    the highest `회차` of the pair whatever its `처분`, 0 when none
  #
  # ONE READER FOR FOUR CONSUMERS — the gate's CI layer, the merge check, the
  # poller's key and the relay's verdict reader — so none of them counts rounds
  # of its own and the four cannot derive different rounds from one ledger.
  #
  # A LABEL ROUND IS A ROUND, NOT A RERUN. `처분=라벨` rows — the label act's —
  # enter a, g and max exactly as rerun rows do, so a label that started a new
  # run moves the poller to a new round key and the merge check accepts only that
  # round's `통과`; they never enter u, the rerun budget. Rounds of both kinds
  # share one numbering, the next round being max + 1 whatever its kind, so a
  # rerun after an accepted label round opens a round of its own.
  #
  # THE ROUND RISES ON `수락` ONLY. A `요청` row opens a round and is written
  # before the POST, so a round GitHub never accepted — a gate that died after the
  # row, or a POST or confirmation that closed `실패` — keeps g where it was, and
  # what the poller sees in that window stays an observation of the earlier round
  # rather than reading as a re-failure. `요청` alone is what u counts, so one
  # rerun is never counted twice and a death after the row still spends it.
  local ledger="$1" seg="$2" sha="$3"
  if [ -z "$ledger" ] || [ ! -f "$ledger" ] || [ -z "$seg" ]; then
    printf 'u=0\na=없음\ng=0\nf=0\nfix=0\nbase=\nad=\nra=없음\nlab=0\nmax=0\n'
    return 0
  fi
  LC_ALL=C awk -F'|' -v seg="$seg" -v sha="$sha" '
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    function val(n,   i, f) {
      for (i = 2; i <= NF; i++) { f = trim($i); if (index(f, n "=") == 1) return substr(f, length(n) + 2) }
      return ""
    }
    /^- `CI 처분` / {
      if (val("세그먼트") != seg) next
      d = val("처분"); s = val("상태"); h = val("head sha"); k = val("회차")
      if (d == "수정") {
        if (h != "" && !(h in fixsha)) { fixsha[h] = 1; f++ }
        if (h == sha) fix = 1
        next
      }
      if ((d != "재실행" && d != "라벨") || h != sha) next
      if (d == "라벨") lab = 1
      if (k !~ /^[0-9]+$/) next
      k = k + 0
      if (s == "요청") {
        if (d == "재실행") { u++; if (k > rtop) rtop = k }
        if (!(k in st)) st[k] = "열림"
        disp[k] = d
        req_base[k] = val("기본 브랜치")
        if (k > top) top = k
      } else if (s == "수락") {
        st[k] = "수락"; disp[k] = d
        if (k > g) g = k
        if (k > top) top = k
        if (d == "재실행" && k > rtop) rtop = k
      } else if (s == "실패") {
        st[k] = "실패"; disp[k] = d
        if (k > top) top = k
        if (d == "재실행" && k > rtop) rtop = k
      }
    }
    END {
      ad = (top + 0 > 0) ? disp[top] : ""
      if (ad == "재실행" && u + 0 == 0) a = "없음"
      else a = (top + 0 > 0) ? st[top] : ""
      if (a == "") a = "없음"
      ra = (u + 0 > 0 && rtop + 0 > 0) ? st[rtop] : ""
      if (ra == "") ra = "없음"
      printf "u=%d\na=%s\ng=%d\nf=%d\nfix=%d\nbase=%s\nad=%s\nra=%s\nlab=%d\nmax=%d\n", u, a, g, f, fix, req_base[g], ad, ra, lab, top
    }
  ' "$ledger" 2>/dev/null || printf 'u=0\na=없음\ng=0\nf=0\nfix=0\nbase=\nad=\nra=없음\nlab=0\nmax=0\n'
}

cc_ci_round_get() {
  # cc_ci_round_get <cc_ci_round output> <key> — one value of it.
  printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -1
}

cc_ci_latest_verdict() {
  # cc_ci_latest_verdict <run-dir> <ledger> <segment> — `<상태>\t<관측>` of the
  # newest `checks` verdict of that segment's CURRENT ROUND, or nothing when the
  # segment has no verdict at all.
  #
  # THE THREE SOURCES IN THE POLLER'S OWN ORDER: the ledger's `checks` rows, then
  # every `checks.observed.draining.*` oldest first, then `checks.observed`. A
  # later source holds a later observation, so the last verdict found is the
  # newest. READ ONLY: no drain, no row, no `gh` — the relay and the watcher both
  # read through here, and the drain keeps its single caller on the act path.
  #
  # THE HEAD IS THE NEWEST VERDICT'S OWN SHA. This reader takes a segment id and
  # knows no worktree tip, so the pair whose round it reads is the one the newest
  # verdict was observed on, and g comes from `cc_ci_round` for that pair. Only
  # that `(segment, sha, g)` is counted: right after a rerun the earlier round's
  # `실패` does not wake the relay, and once a fix moves the head the new head's
  # first observation moves the pair, so the old head's rounds filter nothing on
  # it. A `실패` with checks still running reads `대기`, and so does a pair whose
  # current round has no verdict yet.
  #
  # THE RELAY'S WAKE DOES NOT READ ITS HEAD HERE. `cc_ci_relay_condition` takes
  # the head from the segment worktree and judges that head's round; this reader
  # stays for the callers that hold no worktree.
  local run_dir="$1" ledger="$2" seg="$3" recs="" last sha g pick st pend ob tab
  [ -n "$seg" ] || return 0
  tab=$(printf '\t')
  recs=$(cc_ci_records "$run_dir" "$ledger" "$seg")
  last=$(printf '%s\n' "$recs" | awk 'NF > 0' | tail -1)
  [ -n "$last" ] || return 0
  sha=${last%%"$tab"*}
  g=$(cc_ci_round_get "$(cc_ci_round "$ledger" "$seg" "$sha")" g)
  pick=$(printf '%s\n' "$recs" | LC_ALL=C awk -F'\t' -v sha="$sha" -v g="${g:-0}" \
    'NF > 0 && $1 == sha && $2 == g { p = $0 } END { printf "%s", p }')
  ob=$(printf '%s' "$last" | cut -f5)
  if [ -z "$pick" ]; then
    printf '대기\t%s' "$ob"
    return 0
  fi
  pend=$(printf '%s' "$pick" | cut -f3)
  st=$(printf '%s' "$pick" | cut -f4)
  ob=$(printf '%s' "$pick" | cut -f5)
  if [ "$st" = "실패" ] && [ "${pend:-0}" -gt 0 ] 2>/dev/null; then
    st="대기"
  fi
  printf '%s\t%s' "$st" "$ob"
}

cc_ci_records() {
  # cc_ci_records <run-dir> <ledger> <segment> — every verdict of that segment
  # from the three sources, oldest first, as
  # `<sha>\t<g>\t<진행 중>\t<상태>\t<관측>\t<원장 줄>` lines. The last column is
  # the ledger line number of a `checks` row, and `-` for an observation still
  # in a poller file: the relay's wake consumption compares a verdict's place in
  # the ledger with the last `교대 기동` row, and an observation not yet
  # transcribed has no place there.
  #
  # THE THREE SOURCES IN THE POLLER'S OWN ORDER: the ledger's `checks` rows, then
  # every `checks.observed.draining.*` oldest first, then `checks.observed`. An
  # empty <run-dir> reads the ledger alone, which is what the gate reads.
  local run_dir="$1" ledger="$2" seg="$3" f
  [ -n "$seg" ] || return 0
  if [ -n "$ledger" ] && [ -f "$ledger" ]; then
    LC_ALL=C awk -F'|' -v seg="$seg" '
      function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
      /^- `checks` / {
        hit = 0; st = ""; ob = ""; sh = ""; g = "0"; pd = "0"
        for (i = 2; i <= NF; i++) {
          f = trim($i)
          if (f == "세그먼트=" seg) hit = 1
          else if (index(f, "상태=") == 1) st = substr(f, length("상태=") + 1)
          else if (index(f, "관측=") == 1) ob = substr(f, length("관측=") + 1)
          else if (index(f, "head sha=") == 1) sh = substr(f, length("head sha=") + 1)
          else if (index(f, "재실행 회차=") == 1) g = substr(f, length("재실행 회차=") + 1)
          else if (index(f, "진행 중=") == 1) pd = substr(f, length("진행 중=") + 1)
        }
        if (g !~ /^[0-9]+$/) g = "0"
        if (pd !~ /^[0-9]+$/) pd = "0"
        if (hit && st != "") printf "%s\t%d\t%d\t%s\t%s\t%d\n", sh, g, pd, st, ob, NR
      }
    ' "$ledger" 2>/dev/null || true
  fi
  [ -n "$run_dir" ] || return 0
  while IFS= read -r f; do
    [ -n "$f" ] && [ -f "$f" ] || continue
    cc_ci_observed_records "$f" "$seg" | awk 'NF > 0 { print $0 "\t-" }'
  done <<EOF
$( { ls -tr "$run_dir"/checks.observed.draining.* 2>/dev/null || true; } )
EOF
  cc_ci_observed_records "$run_dir/checks.observed" "$seg" | awk 'NF > 0 { print $0 "\t-" }'
  return 0
}

cc_ci_observed_records() {
  # cc_ci_observed_records <file> <segment> — every verdict of that segment in
  # one poller file as `<sha>\t<g>\t<진행 중>\t<상태>\t<관측>` lines, oldest
  # first. A status outside the poller's vocabulary is skipped, the way the drain
  # skips it. A line of the earlier seven-column shape (time, segment, PR, sha,
  # 상태, 필수 집합, 실패 체크) reads as round 0 with nothing running.
  [ -f "$1" ] || return 0
  LC_ALL=C awk -F'\t' -v seg="$2" '
    $2 == seg && ($5 == "대기" || $5 == "통과" || $5 == "실패" || $5 == "미등록" || $5 == "판정 불가") {
      g = 0; pd = 0
      if (NF >= 9 && $6 ~ /^[0-9]+$/ && $7 ~ /^[0-9]+$/) { g = $6 + 0; pd = $7 + 0 }
      printf "%s\t%d\t%d\t%s\t%s\n", $4, g, pd, $5, $1
    }
  ' "$1" 2>/dev/null || true
}

cc_ci_observed_verdict() {
  # cc_ci_observed_verdict <file> <segment> — the last verdict for that segment
  # in one poller file (tab-separated: time, segment, PR, sha, 상태, …), as
  # `<상태>\t<관측>`, or nothing. A status outside the poller's vocabulary is
  # skipped, the way the drain skips it.
  [ -f "$1" ] || return 0
  LC_ALL=C awk -F'\t' -v seg="$2" '
    $2 == seg && ($5 == "대기" || $5 == "통과" || $5 == "실패" || $5 == "미등록" || $5 == "판정 불가") { last = $5 "\t" $1 }
    END { printf "%s", last }
  ' "$1" 2>/dev/null || true
}

cc_relay_result_after_ref() {
  # cc_relay_result_after_ref <ledger> [<run-dir>] — succeeds when a
  # `stage-result` row follows the reference row: the ledger's latest `handoff
  # 사유=대기`, or — while the relay waits out a shift that died of the limit,
  # which the gate says by a `reset=교대#…` entry in `relay.live` — the latest
  # `handoff` of all, that shift's `무기록`.
  #
  # THE STAGE WAKE IS ALSO READ FROM THE LEDGER, NOT FROM LIVENESS ALONE. The
  # wait set is derived again at three moments — the handoff, the relay's start,
  # a seat re-entry — and a stage that ended between two of them has left the
  # live set without ever being seen to end. Its `stage-result` row is still
  # there, after the reference row.
  #
  # THE `무기록` REFERENCE IS WHY THE SECOND ARGUMENT EXISTS. Read from an older
  # shift's `대기`, the cut attempt's own `한도 종료` row — and after a reboot the
  # settlement's `외부 종료` rows — would stand after the reference and wake the
  # relay before the reset it is holding for. Whether the death was limit-shaped
  # is the gate's judgement, from the stream with jq; it reaches this file only
  # as the entry it wrote, so no stream is read here.
  local anyref=0
  [ -n "$1" ] && [ -f "$1" ] || return 1
  case ",$(cc_relay_field "${2:-}" reset)," in *,교대#*) anyref=1 ;; esac
  # `사유=이월` is a reference row too: the relay waits after it as after `대기`.
  LC_ALL=C awk -v anyref="$anyref" '
    /^- `handoff` / {
      if (anyref == 1 || index($0, " | 사유=대기 | ") > 0 || index($0, " | 사유=이월 | ") > 0) { ref = 1; after = 0 }
    }
    /^- `stage-result` / { if (ref) after = 1 }
    END { exit(after ? 0 : 1) }
  ' "$1"
}

# THE RESET GRACE — how long past a cut's `resetsAt` the relay waits before it
# wakes for that reset. Every one of 37 re-attachments after a reset found a
# first frame that was not `rejected`, the earliest 118 seconds after it, so 60
# is the floor that was measured to hold and nothing below it was. The test hook
# `CC_GATE_RESET_GRACE_TEST_SECONDS` may only shorten it, the shape of the
# relay's hold hook: a test waits less, and a real wait is never lengthened.
CC_RESET_GRACE_SECONDS=60

cc_reset_grace() {
  local t="${CC_GATE_RESET_GRACE_TEST_SECONDS:-}"
  case "$t" in
    ''|*[!0-9]*) printf '%s' "$CC_RESET_GRACE_SECONDS"; return 0 ;;
  esac
  t=$((10#$t))
  if [ "$t" -ge 0 ] && [ "$t" -lt "$CC_RESET_GRACE_SECONDS" ]; then
    printf '%s' "$t"
  else
    printf '%s' "$CC_RESET_GRACE_SECONDS"
  fi
}

cc_relay_cut_cleared_at() {
  # cc_relay_cut_cleared_at <ledger> <key> — the `기록 시각` epoch of the first
  # `한도 해제` row below the cut row of <key>, or empty. The cut row of a stage
  # key is that stage's latest `stage-result`; of `교대#<n>` it is that shift's
  # `무기록` handoff. The row is found by its fixed head, never by a substring
  # of the line, so a field that quotes the row name does not match.
  local ledger="$1" key="$2" at
  [ -n "$ledger" ] && [ -f "$ledger" ] && [ -n "$key" ] || return 0
  at=$(LC_ALL=C awk -F'|' -v key="$key" '
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    function has(f,   i) { for (i = 2; i <= NF; i++) if (trim($i) == f) return 1; return 0 }
    function val(n,   i, f) {
      for (i = 2; i <= NF; i++) { f = trim($i); if (index(f, n "=") == 1) return substr(f, length(n) + 2) }
      return ""
    }
    BEGIN { shift = (index(key, "교대#") == 1) ? substr(key, length("교대#") + 1) : "" }
    /^- `stage-result` / { if (shift == "" && has("스테이지=" key)) { cut = 1; at = "" } ; next }
    /^- `handoff` / { if (shift != "" && has("교대=" shift) && has("사유=무기록")) { cut = 1; at = "" } ; next }
    /^- `한도 해제` / { if (cut && at == "") at = val("기록 시각") }
    END { printf "%s", at }
  ' "$ledger" 2>/dev/null || true)
  [ -n "$at" ] || return 0
  cc_iso_to_epoch "$at"
}

# THE CI WAIT'S TWO CLOCKS, declared once and read by the gate, the relay and
# the watcher alike. On a CI join target (a routed run's segment whose cutpoint
# is `PR`, `머지` or `배포`):
#   - a round-0 verdict V reading `미등록` counts as "no CI" once its `관측` is
#     `CC_CI_UNREGISTERED_GRACE_SECONDS` old. The poller writes one row per
#     transition, so an unbroken `미등록` is one row and its `관측` is the first
#     sighting; a round that went `미등록` → `판정 불가` → `미등록` restarts the
#     grace at the last transition.
#   - every other wait for a verdict ends `CC_CI_WAIT_CAP_SECONDS` after the wait
#     clock (`cc_ci_wait_clock`), whatever its reason — no row, `대기`, a failure
#     still running, `판정 불가`, `미등록` — and `다음` then reads `CI 대기 한도`.
# The grace measured against one sample: CI started 33 seconds after the commit
# and the 60-second poller saw `대기` at 84, so 300 leaves three times that. The
# cap is three times a 25-40 minute CI, so a healthy one never reaches it.
CC_CI_UNREGISTERED_GRACE_SECONDS=300
CC_CI_WAIT_CAP_SECONDS=7200

cc_ci_segment_row_field() {
  # cc_ci_segment_row_field <ledger> <segment> <key> — <key> of the segment's
  # last `segment` row, the one whose `id` field equals <segment>, or empty.
  # The same row the gate's `gate_segment_field` reads.
  [ -n "$1" ] && [ -f "$1" ] && [ -n "$2" ] || return 0
  LC_ALL=C awk -F'|' -v seg="$2" -v key="$3" '
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    /^- `segment` / {
      hit = 0; v = ""
      for (i = 2; i <= NF; i++) {
        f = trim($i)
        if (f == "id=" seg) hit = 1
        else if (index(f, key "=") == 1) v = substr(f, length(key) + 2)
      }
      if (hit) last = v
    }
    END { printf "%s", last }
  ' "$1" 2>/dev/null || true
}

cc_ci_worktree_head() {
  # cc_ci_worktree_head <worktree> — the commit that worktree's HEAD names, or
  # empty. A local read: no fetch, no network.
  [ -n "$1" ] && [ -d "$1" ] || return 0
  ( cd "$1" 2>/dev/null && git --no-optional-locks rev-parse --verify --quiet 'HEAD^{commit}' 2>/dev/null ) || true
}

cc_ci_wait_clock() {
  # cc_ci_wait_clock <run-dir> <ledger> <segment> <head sha> <round> <worktree>
  # — `<UTC time>\t<evidence line>`: when the wait for round <round> of
  # (segment, head) began, and the ledger line of the row it was read from.
  # The sources, first that parses wins:
  #   1. the earliest verdict of that (segment, head, round) — its `관측`;
  #   2. on a round ≥ 1, the newest `CI 처분 처분=재실행 상태=수락` row of
  #      (segment, head) — its `관측`, which the gate stamps in UTC;
  #   3. the head's commit time, read in UTC, whatever the round.
  # The evidence line is `-` for a verdict still in a poller file and empty for
  # the commit time, which no row carries.
  #
  # THE EARLIEST ROW, NOT THE NEWEST: a round whose verdict goes back and forth
  # is measured from its first sighting, so the clock never moves back. A round
  # ≥ 1 opens on its acceptance rather than on the failure before it, so a rerun
  # accepted late does not start its round already past the cap.
  #
  # A SOURCE THAT DOES NOT PARSE IS ABSENT, and the commit time stands behind
  # every one, so on a head that resolves the clock is always set and one badly
  # written row cannot make the cap disappear. The commit time is read with
  # `format-local` under `TZ=UTC`: `cc_iso_to_epoch` drops any offset, and a
  # `%cI` of `+09:00` would shift the clock by nine hours.
  local run_dir="$1" ledger="$2" seg="$3" sha="$4" g="${5:-0}" wt="$6" r ob
  [ -n "$seg" ] && [ -n "$sha" ] || return 0
  r=$(cc_ci_records "$run_dir" "$ledger" "$seg" \
      | LC_ALL=C awk -F'\t' -v sha="$sha" -v g="$g" 'NF > 0 && $1 == sha && $2 == g { print; exit }')
  if [ -n "$r" ]; then
    ob=$(printf '%s' "$r" | cut -f5)
    if [ -n "$(cc_iso_to_epoch "$ob")" ]; then
      printf '%s\t%s' "$ob" "$(printf '%s' "$r" | cut -f6)"
      return 0
    fi
  fi
  if [ "$g" -ge 1 ] 2>/dev/null && [ -n "$ledger" ] && [ -f "$ledger" ]; then
    r=$(LC_ALL=C awk -F'|' -v seg="$seg" -v sha="$sha" '
      function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
      function val(n,   i, f) {
        for (i = 2; i <= NF; i++) { f = trim($i); if (index(f, n "=") == 1) return substr(f, length(n) + 2) }
        return ""
      }
      /^- `CI 처분` / {
        if (val("세그먼트") == seg && val("처분") == "재실행" && val("상태") == "수락" && val("head sha") == sha)
          p = val("관측") "\t" NR
      }
      END { printf "%s", p }
    ' "$ledger" 2>/dev/null || true)
    ob=$(printf '%s' "$r" | cut -f1)
    if [ -n "$r" ] && [ -n "$(cc_iso_to_epoch "$ob")" ]; then
      printf '%s' "$r"
      return 0
    fi
  fi
  [ -n "$wt" ] && [ -d "$wt" ] || return 0
  ob=$( ( cd "$wt" 2>/dev/null && TZ=UTC git --no-optional-locks log -1 \
          --date=format-local:%Y-%m-%dT%H:%M:%SZ --format=%cd "$sha" 2>/dev/null ) || true)
  [ -n "$(cc_iso_to_epoch "$ob")" ] || return 0
  printf '%s\t' "$ob"
}

cc_ci_unregistered_expired() {
  # cc_ci_unregistered_expired <상태> <round> <관측> [<now>] — succeeds when a
  # verdict is round 0's `미등록` and its `관측` is at least the grace old.
  local ep now="${4:-}"
  [ "$1" = "미등록" ] && [ "${2:-0}" = "0" ] || return 1
  ep=$(cc_iso_to_epoch "$3")
  [ -n "$ep" ] || return 1
  [ -n "$now" ] || now=$(date -u +%s)
  [ $((ep + CC_CI_UNREGISTERED_GRACE_SECONDS)) -le "$now" ]
}

cc_ci_wait_capped() {
  # cc_ci_wait_capped <wait clock time> [<now>] — succeeds when the cap has
  # passed since that clock.
  local ep now="${2:-}"
  ep=$(cc_iso_to_epoch "$1")
  [ -n "$ep" ] || return 1
  [ -n "$now" ] || now=$(date -u +%s)
  [ $((ep + CC_CI_WAIT_CAP_SECONDS)) -le "$now" ]
}

cc_ci_rerun_parked() {
  # cc_ci_rerun_parked <ledger> <segment> <head sha> — succeeds when a rerun
  # `도달 park` row of the segment stands below the first `checks` row of
  # (segment, head). The park row carries no head, so the head is tied to it by
  # line order: an older head's park sits above the new head's first verdict. A
  # head with no `checks` row in the ledger has no park of its own yet.
  [ -n "$1" ] && [ -f "$1" ] && [ -n "$2" ] && [ -n "$3" ] || return 1
  LC_ALL=C awk -F'|' -v seg="$2" -v sha="$3" '
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    function val(n,   i, f) {
      for (i = 2; i <= NF; i++) { f = trim($i); if (index(f, n "=") == 1) return substr(f, length(n) + 2) }
      return ""
    }
    /^- `checks` / { if (!first && val("세그먼트") == seg && val("head sha") == sha) first = NR; next }
    /^- `blocked` / {
      if (!first) next
      d = val("도달 판정")
      if (val("사유") == "도달 park" && val("세그먼트") == seg && (d == "재실행대상미상" || d == "재실행배포트리거")) hit = 1
    }
    END { exit(hit ? 0 : 1) }
  ' "$1" 2>/dev/null
}

cc_ci_relay_condition() {
  # cc_ci_relay_condition <run-dir> <ledger> <segment> [<now>] — the wake
  # conditions of a segment the relay waits on for CI, one
  # `<wake epoch>\t<evidence line>` line each in the order they stand, or
  # nothing when there is none:
  #   `통과`, or a failure with nothing running   wake at the verdict's `관측`
  #   round 0's `미등록` past the grace            wake at `관측 + grace`
  #   the wait cap reached                        wake at `wait clock + cap`
  # No verdict, `대기`, a failure still running, `판정 불가` and `미등록`
  # inside the grace do not wake before the cap.
  #
  # AN EXPIRED `미등록` IS FOLLOWED BY THE CAP. A shift that woke on the expiry
  # and still ended waiting on CI consumed that condition, and the same verdict
  # row still stands; the cap is then the wait's end, so its line comes after
  # and the caller takes the first one not consumed.
  #
  # THE HEAD IS THE SEGMENT WORKTREE'S TIP, read from the `워크트리` of the
  # segment's last `segment` row, so a verdict of another head never wakes. A
  # worktree that does not resolve falls back to the newest verdict's own sha.
  local run_dir="$1" ledger="$2" seg="$3" now="${4:-}" tab recs last wt h g v st pend ob ln ep clk
  [ -n "$seg" ] || return 0
  tab=$(printf '\t')
  [ -n "$now" ] || now=$(date -u +%s)
  recs=$(cc_ci_records "$run_dir" "$ledger" "$seg")
  wt=$(cc_ci_segment_row_field "$ledger" "$seg" '워크트리')
  h=$(cc_ci_worktree_head "$wt")
  if [ -z "$h" ]; then
    last=$(printf '%s\n' "$recs" | awk 'NF > 0' | tail -1)
    [ -n "$last" ] || return 0
    h=${last%%"$tab"*}
  fi
  g=$(cc_ci_round_get "$(cc_ci_round "$ledger" "$seg" "$h")" g)
  g=${g:-0}
  v=$(printf '%s\n' "$recs" | LC_ALL=C awk -F'\t' -v sha="$h" -v g="$g" \
    'NF > 0 && $1 == sha && $2 == g { p = $0 } END { printf "%s", p }')
  if [ -n "$v" ]; then
    pend=$(printf '%s' "$v" | cut -f3); st=$(printf '%s' "$v" | cut -f4)
    ob=$(printf '%s' "$v" | cut -f5); ln=$(printf '%s' "$v" | cut -f6)
    if [ "$st" = "통과" ] || { [ "$st" = "실패" ] && [ "${pend:-0}" -eq 0 ] 2>/dev/null; }; then
      printf '%s\t%s\n' "$(cc_iso_to_epoch "$ob")" "$ln"
      return 0
    fi
    if cc_ci_unregistered_expired "$st" "$g" "$ob" "$now"; then
      printf '%s\t%s\n' "$(( $(cc_iso_to_epoch "$ob") + CC_CI_UNREGISTERED_GRACE_SECONDS ))" "$ln"
    fi
  fi
  clk=$(cc_ci_wait_clock "$run_dir" "$ledger" "$seg" "$h" "$g" "$wt")
  [ -n "$clk" ] || return 0
  cc_ci_wait_capped "${clk%%"$tab"*}" "$now" || return 0
  ep=$(cc_iso_to_epoch "${clk%%"$tab"*}")
  printf '%s\t%s\n' "$((ep + CC_CI_WAIT_CAP_SECONDS))" "${clk#*"$tab"}"
}

cc_ci_early_condition() {
  # cc_ci_early_condition <run-dir> <ledger> <segment> — the relay's reading of
  # the early rerun predicate E, as `<wake epoch>\t<evidence line>`, or nothing:
  # a routed run (`<run-dir>/routing-guard` reads `1`), the segment neither
  # `머지됨` nor `park`, a live review stage on it, its worktree tip resolves,
  # no round of either kind on that head (max = 0, so an accepted label round,
  # which never raises u, ends it too), round 0's verdict a failure with
  # nothing running, and no rerun `도달 park` row below the head's first
  # `checks` row. The wake is that verdict's `관측`.
  #
  # THE CUTPOINT IS NOT READ. This file opens no manifest, and it need not: a
  # `checks` row exists only where a pull request does, and the router opens
  # one only at a cutpoint of `PR` or above, so a segment the rest of E holds
  # for is a CI join target. THE `라벨 인정` ROWS ARE NOT READ EITHER, for the
  # same reason, so this copy is a superset of the gate's `gate_ci_early`,
  # which also drops a failure of an acknowledged check. A shift woken for one
  # finds `ci_early[]` empty and takes no act, and the consumption rule wakes
  # it on that evidence once. The gate's clause only makes E false, so this
  # copy never misses a wake the gate's would give.
  local run_dir="$1" ledger="$2" seg="$3" st wt h mx recs v
  [ -n "$run_dir" ] && [ -n "$seg" ] || return 0
  [ "$( { sed -n '1p' "$run_dir/routing-guard" 2>/dev/null || true; } | tr -d '[:space:]')" = "1" ] || return 0
  st=$(cc_ci_segment_row_field "$ledger" "$seg" '상태')
  case "$st" in 머지됨|park) return 0 ;; esac
  cc_stage_is_live "$run_dir" "$seg" || return 0
  [ "$(cc_stage_kind "$run_dir" "$ledger" "$seg")" = "review" ] || return 0
  wt=$(cc_ci_segment_row_field "$ledger" "$seg" '워크트리')
  h=$(cc_ci_worktree_head "$wt")
  [ -n "$h" ] || return 0
  mx=$(cc_ci_round_get "$(cc_ci_round "$ledger" "$seg" "$h")" max)
  [ "${mx:-0}" = "0" ] || return 0
  recs=$(cc_ci_records "$run_dir" "$ledger" "$seg")
  v=$(printf '%s\n' "$recs" | LC_ALL=C awk -F'\t' -v sha="$h" \
    'NF > 0 && $1 == sha && $2 == 0 { p = $0 } END { printf "%s", p }')
  [ -n "$v" ] || return 0
  [ "$(printf '%s' "$v" | cut -f4)" = "실패" ] || return 0
  [ "$(printf '%s' "$v" | cut -f3)" = "0" ] || return 0
  if cc_ci_rerun_parked "$ledger" "$seg" "$h"; then return 0; fi
  printf '%s\t%s\n' "$(cc_iso_to_epoch "$(printf '%s' "$v" | cut -f5)")" "$(printf '%s' "$v" | cut -f6)"
}

cc_relay_last_shift_launch() {
  # cc_relay_last_shift_launch <ledger> — `<line>\t<기록 시각 epoch>` of the
  # ledger's last `교대 기동` row, or nothing.
  local r tab
  [ -n "$1" ] && [ -f "$1" ] || return 0
  tab=$(printf '\t')
  r=$(LC_ALL=C awk -F'|' '
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    /^- `교대 기동` / {
      at = ""
      for (i = 2; i <= NF; i++) { f = trim($i); if (index(f, "기록 시각=") == 1) at = substr(f, length("기록 시각=") + 1) }
      p = NR "\t" at
    }
    END { printf "%s", p }
  ' "$1" 2>/dev/null || true)
  [ -n "$r" ] || return 0
  printf '%s\t%s' "${r%%"$tab"*}" "$(cc_iso_to_epoch "${r#*"$tab"}")"
}

cc_relay_condition_consumed() {
  # cc_relay_condition_consumed <last launch line> <last launch epoch> <wake
  # epoch> <evidence line> — succeeds when the last `교대 기동` row stands below
  # the condition's evidence row (no such clause when the evidence is no row)
  # and was written at or after the wake time. Evidence still in a poller file
  # (`-`) is never consumed.
  #
  # THE PAIR THIS KEEPS. The relay waits only while a shift ended `대기` and
  # launches the next one when it wakes, so the last `교대 기동` belongs to the
  # shift that just waited. That shift's snapshot held every row above its
  # launch row, and a condition true at its launch stayed true for it, so it
  # acted on the condition, recorded that it could not, or chose to wait —
  # waking it again on the same evidence repeats the same turn. A row
  # transcribed below the launch row was not consumed and wakes once more.
  local sl="$1" se="$2" wake="$3" ev="$4"
  case "$sl" in ''|*[!0-9]*) return 1 ;; esac
  case "$ev" in
    -) return 1 ;;
    '') : ;;
    *[!0-9]*) return 1 ;;
    *) [ "$sl" -gt "$ev" ] || return 1 ;;
  esac
  [ -n "$wake" ] || return 0
  case "$se" in ''|*[!0-9]*) return 1 ;; esac
  [ "$se" -ge "$wake" ]
}

cc_relay_wake_keys() {
  # cc_relay_wake_keys <run-dir> <ledger> — one line per wake condition standing
  # now for the relay `relay.live` records: `<key>\t<epoch of its own clock>`,
  # the clock empty where the evidence carries none.
  #
  #   sr\t            a `stage-result` row after the reference row
  #   st:<key>\t      a stage or supervisor of the wait set is no longer live
  #   ci:<seg>\t<ep>  the CI wait of the segment's worktree tip ended: `통과` or
  #                   a settled failure (clock: `관측`), round 0's `미등록` past
  #                   the grace (clock: `관측 + grace`), or the wait cap
  #                   (clock: `wait clock + cap`) — `cc_ci_relay_condition`
  #   ce:<seg>\t<ep>  a live review stage's segment whose failure has settled
  #                   with no round of either kind — the early rerun predicate
  #                   (clock: that verdict's `관측`) — `cc_ci_early_condition`
  #   rl:<key>\t<ep>  a cut's reset plus the grace has passed (clock: that sum)
  #   lc:<key>\t<ep>  a `한도 해제` row stands below the cut row (clock: its
  #                   `기록 시각`)
  #   dl:이월\t<ep>   the `이월` hand-off's clock — the deadline plus one second —
  #                   has passed (clock: that time, the `defer=` line)
  #
  # ONE READER FOR THE RELAY AND THE WATCHER. The relay wakes when this prints
  # anything; the watcher asks how long each line has stood. A segment with no
  # verdict yet does not wake. The two reset keys carry their own clock, so the
  # watcher ages them by it and not by the pass that first saw them.
  #
  # A CI KEY STANDS ONCE PER CONDITION. A `ci:` or `ce:` condition is consumed
  # once the last `교대 기동` row stands below its evidence row and was written
  # at or after its wake time (`cc_relay_condition_consumed`): the shift that
  # launched on it has seen it, so the same evidence does not launch the same
  # shift again. Evidence still in a poller file is never consumed — the launch
  # drains it into the ledger above its own row, so the next shift sees it.
  local run_dir="$1" ledger="$2" k v tab now grace ep at sl se c
  [ -f "$run_dir/relay.live" ] || return 0
  tab=$(printf '\t')
  if cc_relay_result_after_ref "$ledger" "$run_dir"; then printf 'sr\t\n'; fi
  now=$(date -u +%s)
  grace=$(cc_reset_grace)
  for v in $(cc_relay_field "$run_dir" reset | tr ',' ' '); do
    [ "$v" != "-" ] || continue
    k=${v%:*}; ep=${v##*:}
    case "$ep" in ''|*[!0-9]*) continue ;; esac
    [ -n "$k" ] && [ "$k" != "$v" ] || continue
    if [ "$now" -ge $((ep + grace)) ]; then
      printf 'rl:%s\t%s\n' "$k" "$((ep + grace))"
    fi
    at=$(cc_relay_cut_cleared_at "$ledger" "$k")
    [ -z "$at" ] || printf 'lc:%s\t%s\n' "$k" "$at"
  done
  ep=$(cc_relay_field "$run_dir" defer)
  case "$ep" in
    ''|*[!0-9]*) : ;;
    *) [ "$now" -lt "$ep" ] || printf 'dl:이월\t%s\n' "$ep" ;;
  esac
  for k in $(cc_relay_field "$run_dir" stages | tr ',' ' '); do
    [ "$k" != "-" ] || continue
    if ! cc_stage_is_live "$run_dir" "$k" && ! cc_supervisor_is_live "$run_dir" "$k"; then
      printf 'st:%s\t\n' "$k"
    fi
  done
  c=$(cc_relay_last_shift_launch "$ledger")
  sl=${c%%"$tab"*}; se=""
  [ -z "$c" ] || se=${c#*"$tab"}
  for k in $(cc_relay_field "$run_dir" ci | tr ',' ' '); do
    [ "$k" != "-" ] || continue
    while IFS= read -r c; do
      [ -n "$c" ] || continue
      ep=${c%%"$tab"*}
      if cc_relay_condition_consumed "$sl" "$se" "$ep" "${c#*"$tab"}"; then continue; fi
      printf 'ci:%s\t%s\n' "$k" "$ep"
      break
    done <<EOF
$(cc_ci_relay_condition "$run_dir" "$ledger" "$k" "$now")
EOF
  done
  for k in $(cc_relay_field "$run_dir" stages | tr ',' ' '); do
    [ "$k" != "-" ] || continue
    c=$(cc_ci_early_condition "$run_dir" "$ledger" "$k")
    [ -n "$c" ] || continue
    ep=${c%%"$tab"*}
    if cc_relay_condition_consumed "$sl" "$se" "$ep" "${c#*"$tab"}"; then continue; fi
    printf 'ce:%s\t%s\n' "$k" "$ep"
  done
  return 0
}

cc_relay_seen_at() {
  # cc_relay_seen_at <run-dir> <relay-start> <key> — the epoch the watcher
  # first saw that wake key stand for that relay, from `watch.relay-seen`, or
  # empty. The watcher writes the file; nothing here does.
  [ -f "$1/watch.relay-seen" ] || return 0
  LC_ALL=C awk -F'\t' -v s="$2" -v k="$3" '$1 == s && $2 == k { print $3; exit }' \
    "$1/watch.relay-seen" 2>/dev/null || true
}

cc_relay_is_effective() {
  # cc_relay_is_effective <run-dir> <ledger> <silence> <after-stage> — succeeds
  # when a relay is live AND doing its job: pid and fingerprint, a `refreshed`
  # younger than <silence>, and no wake condition that has stood longer than
  # <after-stage> without a successor.
  #
  # THE WAKE CLOCK COMES FROM EVIDENCE THE RELAY DOES NOT WRITE. A relay that
  # stamped its own wake time would, hung, never stamp it, and this would never
  # turn false. A CI wake is timed by the verdict's `관측`; a stage wake by the
  # watcher pass that first saw it, kept per key in `watch.relay-seen` so the
  # clock survives `--once` and a restarted watcher. A key not yet seen cannot
  # be overdue.
  local run_dir="$1" ledger="$2" silence="$3" after="$4" now ref started k c
  cc_relay_is_live "$run_dir" || return 1
  now=$(date -u +%s)
  ref=$(cc_relay_field "$run_dir" refreshed)
  case "$ref" in ''|*[!0-9]*) return 1 ;; esac
  [ $((now - ref)) -lt "$silence" ] || return 1
  started=$(cc_relay_field "$run_dir" started)
  while IFS="$(printf '\t')" read -r k c; do
    [ -n "$k" ] || continue
    [ -n "$c" ] || c=$(cc_relay_seen_at "$run_dir" "$started" "$k")
    case "$c" in ''|*[!0-9]*) continue ;; esac
    [ $((now - c)) -le "$after" ] || return 1
  done <<EOF
$(cc_relay_wake_keys "$run_dir" "$ledger")
EOF
  return 0
}

cc_iso_to_epoch() {
  # `YYYY-MM-DDTHH:MM:SSZ` → epoch seconds, or empty when it does not parse.
  #
  # NEITHER `date -d` NOR `date -j -f` MAY BE USED. The first is GNU, the second
  # BSD, and the portability lint denies both — the same wall the gate's deadline
  # check hit, which it got around by comparing digit strings because it only
  # needed an ordering. This caller needs a DIFFERENCE against a threshold in
  # seconds, and no digit-string compare yields one, so the conversion is done in
  # the shell.
  #
  # The arithmetic is the standard civil-to-days one. Every intermediate stays
  # non-negative for years at or after 1970, which is what lets `$(( ))`'s
  # truncating division stand in for floor. `10#` on every field because `08` and
  # `09` are invalid octal and would abort the expansion.
  local s="$1" digits y m d hh mm ss era yoe doy doe days
  digits=$(printf '%s' "$s" | tr -cd '0-9')
  [ ${#digits} -ge 14 ] || return 0
  y=$((10#$(printf '%s' "$digits" | cut -c1-4)))
  m=$((10#$(printf '%s' "$digits" | cut -c5-6)))
  d=$((10#$(printf '%s' "$digits" | cut -c7-8)))
  hh=$((10#$(printf '%s' "$digits" | cut -c9-10)))
  mm=$((10#$(printf '%s' "$digits" | cut -c11-12)))
  ss=$((10#$(printf '%s' "$digits" | cut -c13-14)))
  [ "$y" -ge 1970 ] || return 0
  [ "$m" -ge 1 ] && [ "$m" -le 12 ] || return 0
  [ "$d" -ge 1 ] && [ "$d" -le 31 ] || return 0
  # March-based year: January and February belong to the preceding one, which is
  # what removes the leap day from the middle of the count.
  if [ "$m" -le 2 ]; then y=$((y - 1)); fi
  era=$((y / 400))
  yoe=$((y - era * 400))
  if [ "$m" -gt 2 ]; then
    doy=$(( (153 * (m - 3) + 2) / 5 + d - 1 ))
  else
    doy=$(( (153 * (m + 9) + 2) / 5 + d - 1 ))
  fi
  doe=$(( yoe * 365 + yoe / 4 - yoe / 100 + doy ))
  days=$(( era * 146097 + doe - 719468 ))
  printf '%s' $(( days * 86400 + hh * 3600 + mm * 60 + ss ))
}

cc_epoch_to_iso() {
  # Epoch seconds → `YYYY-MM-DDTHH:MM:SSZ`, or empty when it is not a
  # non-negative integer. The inverse of `cc_iso_to_epoch`, in the shell for the
  # same reason: `date -r` is BSD, `date -d @` is GNU, and the portability lint
  # denies both.
  local e="${1:-}" days secs z era doe yoe y doy mp d m
  case "$e" in ''|*[!0-9]*) return 0 ;; esac
  e=$((10#$e))
  days=$((e / 86400)); secs=$((e % 86400))
  z=$((days + 719468))
  era=$((z / 146097))
  doe=$((z - era * 146097))
  yoe=$(( (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365 ))
  y=$((yoe + era * 400))
  doy=$((doe - (365 * yoe + yoe / 4 - yoe / 100)))
  mp=$(( (5 * doy + 2) / 153 ))
  d=$((doy - (153 * mp + 2) / 5 + 1))
  if [ "$mp" -lt 10 ]; then m=$((mp + 3)); else m=$((mp - 9)); fi
  if [ "$m" -le 2 ]; then y=$((y + 1)); fi
  printf '%04d-%02d-%02dT%02d:%02d:%02dZ' "$y" "$m" "$d" \
    $((secs / 3600)) $((secs % 3600 / 60)) $((secs % 60))
}

cc_pid_exists() {
  # cc_pid_exists <pid> — succeeds when some process holds that pid, and says
  # nothing about WHICH process that is.
  #
  # A BARE EXISTENCE TEST, and the name says so, because every other predicate
  # here answers "is it still the process that was started" and this one cannot:
  # its caller is the gate's `checks` drain lock, whose owner line records a pid
  # and a time and no start fingerprint. It lives here rather than inline because
  # a `kill -0` written in the gate is a liveness judgement of the gate's own,
  # which is the divergence this file exists to prevent. Pid reuse is bounded by
  # that caller instead: it also takes a lock over on age, so a recycled pid
  # keeps a dead owner's lock for at most the sixty seconds that arm allows.
  [ -n "${1:-}" ] || return 1
  kill -0 "$1" 2>/dev/null
}

cc_holder_is_live() {
  # cc_holder_is_live <pid> <fingerprint> — succeeds when that pid is still the
  # process whose start fingerprint was recorded beside it. The holder records
  # of a dispatch lock and a waiting marker are judged here, so the gate keeps
  # no liveness test of its own.
  local pid="${1:-}" fp="${2:-}"
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  [ -n "$fp" ] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  [ "$(cc_proc_fingerprint "$pid")" = "$fp" ]
}

cc_proc_fingerprint() {
  # cc_proc_fingerprint <pid> — the pid's start time, whitespace-normalised.
  # The pair (pid, start time) is the identity; the pid alone is not.
  #
  # `LC_ALL` rather than `LC_TIME`, because this string is compared across
  # process boundaries and the two sides do not share an environment. `ps -o
  # lstart=` is a localised date — under a Korean locale it reads `2026년 9월 4일
  # 금요일 00시 35분 25초` where the C locale reads `Fri Sep 4 00:35:25 2026` —
  # and `LC_TIME` is overridden by an inherited `LC_ALL`, so a writer that had
  # cleared `LC_ALL` and a reader that had not produced different strings for one
  # live process. The reader then called it dead. `LC_ALL` as a command prefix
  # outranks every other locale variable and does not leak past this line.
  #
  # A DEAD PID IS AN ANSWER, NOT A FAILURE, and the `|| true` is what says so to
  # the caller's shell. `ps` exits 1 when the pid is gone, and under the
  # `set -euo pipefail` this file is sourced into, `pipefail` raises that status
  # out of the pipeline and `errexit` ends the caller on the spot. The callers
  # are supervisors and liveness probes, and asking about a process that has
  # already been reaped is their ordinary case — measured: a stage that exited
  # before its supervisor reached this line took the supervisor down with it,
  # leaving no terminal row, no cleanup and a record nothing could settle. The
  # empty string this returns for a dead pid is what every caller already treats
  # as "no fingerprint"; swallowing the status here covers all of them at once.
  { LC_ALL=C ps -o lstart= -p "$1" 2>/dev/null || true; } \
    | sed 's/[[:space:]]\{1,\}/ /g;s/^ //;s/ $//'
}

cc_proc_pgid() {
  # cc_proc_pgid <pid> — the pid's process group id, or empty.
  # THIS IS A FALLBACK, NOT AN IDENTITY. The driver now records a start-time
  # fingerprint beside the pid as well, so the only records that reach here are
  # the ones written before it did. What the compare still filters out is a
  # stale record with no live group leader behind it; what it cannot filter out
  # is pid reuse, because the driver spawns under job control and the child then
  # leads its own group — the recorded value IS the pid, so anything that holds
  # that pid next matches as long as it leads a group of its own.
  ps -o pgid= -p "$1" 2>/dev/null | tr -d '[:space:]'
}

# ---------------------------------------------------------------------------
# The wake chain — when the machine last woke, and the host seam it rests on.
#
# IT MOVED HERE WHOLE, from the driver. A waiting stage's freshness is measured
# from the later of its own refresh and the machine's wake, and the readers of
# that freshness — the watcher, the status line, the snapshot — source this file
# and not the driver. Moving one function would have cut the chain: the wake
# reading needs its source, the source needs the platform test, the platform
# test needs the host. The driver sources this file, so its callers are the same.
#
# THE HOST IS READ, NEVER ASSIGNED, HERE. The driver assigns `ORCH_HOST_OS` once
# at its top level and other places read that variable directly, and the test
# harness assigns it too. This file is sourced on every status-line render, so a
# top-level assignment would start `uname` per render, and an assignment inside
# the function is lost whenever the function runs in a substitution. A shell
# that sourced only this file reads the injection seam, then `uname`.
# ---------------------------------------------------------------------------
platform_supported() { [ "${ORCH_HOST_OS:-${CC_CMDS_ORCH_HOST_OS:-$(uname -s)}}" = "Darwin" ]; }

# Source selection is seam-driven, so it is exercised under injection on any
# runner. Whether the selected binary EXISTS is a separate question, and it is
# one only the darwin leg can answer.
#
# A KEY THE TEST HOOK NAMES IS SELECTED ON ANY HOST. The hook below answers it
# without the kernel, so the host does not decide whether it is read; tying it
# to the host test left it unread wherever the caller's `ORCH_HOST_OS` does not
# reach the reading — a gate entered in-process restores the host it was
# sourced on, over the value the call set.
sysctl_source() {
  case ",${CC_SYSCTL_TEST_VALUES:-}," in *",$1="*) printf '%s' "$1"; return 0 ;; esac
  platform_supported && printf '%s' "$1" || printf ''
}
boot_source() { sysctl_source kern.boottime; }
wake_source() { sysctl_source kern.waketime; }
sleep_source() { sysctl_source kern.sleeptime; }

# Sleep discriminator. Closing the lid leaves a stage alive with a stalled
# transcript, which the resume table would otherwise read as the limit-exhaustion
# shape and act on — killing and re-running on false evidence. Wall-clock moves
# across a sleep; the wake timestamp records that it happened.
sysctl_sec() {
  # No key selected (non-darwin) means no reading, not a reading of zero. The
  # pipeline is guarded so a missing key cannot abort a caller running under
  # `set -e`.
  #
  # THE TEST HOOK OVERRIDES ALL THREE KERNEL VALUES AT ONE SEAM.
  # `CC_SYSCTL_TEST_VALUES` holds `<key>=<epoch>` pairs joined by `,` —
  # `kern.boottime=…,kern.sleeptime=…,kern.waketime=…` — and a key it names is
  # answered from there instead of the kernel, so the boot marker of a
  # boot-time re-entry and the measured fields of a re-attachment pass through
  # the same reading the tests set. A key it does not name is still read live.
  [ -n "$1" ] || return 0
  local t
  case ",${CC_SYSCTL_TEST_VALUES:-}," in
    *",$1="*)
      t=",${CC_SYSCTL_TEST_VALUES},"; t=${t#*",$1="}; t=${t%%,*}
      case "$t" in ''|*[!0-9]*) return 0 ;; esac
      printf '%s\n' "$t"; return 0 ;;
  esac
  { sysctl -n "$1" 2>/dev/null || true; } \
    | awk -F'[ ,]+' '{for(i=1;i<=NF;i++) if($i=="sec"){print $(i+2); exit}}'
}
boot_epoch() { sysctl_sec "$(boot_source)"; }
wake_epoch() { sysctl_sec "$(wake_source)"; }
sleep_epoch() { sysctl_sec "$(sleep_source)"; }

machine_slept_since() {
  local since="$1" w
  w=$(wake_epoch)
  [ -n "$w" ] || return 1
  [ "$w" = "0" ] && return 1
  [ "$w" -gt "$since" ]
}

# ---------------------------------------------------------------------------
# The effective stall threshold, for a stage that waits for an account.
#
# A WAITER PACES ITS HEARTBEAT ON THE WATCHER'S THRESHOLD, so it has to read the
# value the watcher is actually using. The watcher rewrites `watch.stall` every
# pass — line 1 the threshold in seconds, line 2 its own pid, line 3 that pid's
# fingerprint — and the value counts only while that writer is still the same
# live process: a dead watcher's test value must not pull every wait down to it.
#
# WITHOUT A LIVE WRITER, THE SHIPPED DEFAULT IS READ FROM THE WATCHER ITSELF —
# its one default declaration, matched with the same expression the threshold-pin
# lint uses, in the watcher beside this file (the run's pinned copy when the gate
# sourced it). There is no second literal to drift. When that declaration is not
# exactly one, nothing is printed and the status is 1: the caller does not wait.
# ---------------------------------------------------------------------------
cc_effective_stall() {
  # cc_effective_stall <run-dir> — the threshold in seconds, or rc 1.
  local f="${1:-}/watch.stall" v pid rec now decl n
  if [ -n "${1:-}" ] && [ -f "$f" ]; then
    v=$( { sed -n '1p' "$f" 2>/dev/null || true; } | tr -d '[:space:]')
    pid=$( { sed -n '2p' "$f" 2>/dev/null || true; } | tr -d '[:space:]')
    rec=$(sed -n '3p' "$f" 2>/dev/null || true)
    case "$v:$pid" in
      *[!0-9:]*|:*|*:) ;;
      *)
        if [ "$((10#$v))" -gt 0 ] && [ -n "$rec" ] && kill -0 "$pid" 2>/dev/null; then
          now=$(cc_proc_fingerprint "$pid")
          if [ "$rec" = "$now" ]; then printf '%s' "$((10#$v))"; return 0; fi
        fi
        ;;
    esac
  fi
  decl=$(LC_ALL=C grep -oE '(^|[;[:space:]])STALL=[0-9]+' "$CC_LIVENESS_DIR/watch.sh" 2>/dev/null || true)
  [ -n "$decl" ] || return 1
  n=$(printf '%s\n' "$decl" | grep -c '' || true)
  [ "$n" = "1" ] || return 1
  v=${decl##*=}
  [ "$((10#$v))" -gt 0 ] || return 1
  printf '%s' "$((10#$v))"
}

cc_wait_chunk() {
  # cc_wait_chunk <stall> — half the threshold, never below one second. A row
  # every half threshold leaves the other half for the router call that comes
  # between two rows; the floor keeps a test-sized threshold from a busy loop.
  local s="$((10#${1:-0}))"
  s=$((s / 2))
  [ "$s" -ge 1 ] || s=1
  printf '%s' "$s"
}

# ---------------------------------------------------------------------------
# Stages that wait for an account before they spawn.
#
# A WAITING STAGE HAS NO PROCESS OF ITS OWN YET, so none of the predicates above
# can see it: no `<key>.pid`, so it is neither live nor an orphan. What it has is
# a marker, `<key>.waiting`, written by whoever waits — the gate's supervisor or
# the driver — as `key=value` lines: 보유자 (the waiting process), 지문 (its
# fingerprint), 기록자 (게이트 or 드라이버), 계보, 그룹, 까지 (epoch or `-`),
# 갱신 (epoch of the last heartbeat), 종류, 논스, 시도, 재파견, 예비 (the reset
# passes the wait has seen, a one-line JSON array the router reads back).
#
# MEMBERSHIP IS THE HOLDER'S LIFE, NOT A CLOCK. A key is waiting when the holder
# is still the process that wrote the marker, the key has no live stage, and the
# attempt has no terminal row — no `stage-result` and no `blocked` row naming its
# lineage. A refresh time is a wall clock, and a machine that slept two hours
# would otherwise drop a healthy waiter and let the key be dispatched again.
#
# FRESHNESS IS SEPARATE AND ONLY QUIETS ALARMS. A member is fresh while the later
# of its refresh and the machine's wake is younger than the effective stall
# threshold. A waiter whose refresh stopped while its holder lives is still a
# member — it is not dispatched again — but it no longer quiets the watcher;
# killing the holder is the recovery, and settlement then closes the attempt.
#
# None of these counts toward `cc_live_stages`: a waiting stage holds no
# account yet, and that census means running stages.
# ---------------------------------------------------------------------------
cc_waiting_field() {
  # cc_waiting_field <marker> <key> — the value of that key, or empty.
  { sed -n "s/^$2=//p" "$1" 2>/dev/null || true; } | tail -1
}

cc_rows_naming_lineage() {
  # cc_rows_naming_lineage <lineage> — the stdin rows that carry `계보=<lineage>`
  # as a whole value. `B:S1#1` must not match inside `B:S1#10`, so the character
  # after the value has to end it.
  awk -v pat="계보=$1" '{
    s = $0
    while ((i = index(s, pat)) > 0) {
      c = substr(s, i + length(pat), 1)
      if (c !~ /[0-9A-Za-z_.#:-]/) { print; next }
      s = substr(s, i + length(pat))
    }
  }'
}

cc_waiting_is_member() {
  # cc_waiting_is_member <run-dir> <ledger> <key> — succeeds when that key is a
  # waiting stage.
  local run_dir="$1" ledger="$2" key="$3" f pid fp now att lin
  [ -n "$run_dir" ] && [ -n "$key" ] || return 1
  f="$run_dir/$key.waiting"
  [ -f "$f" ] || return 1
  pid=$(cc_waiting_field "$f" '보유자' | tr -d '[:space:]')
  fp=$(cc_waiting_field "$f" '지문')
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  [ -n "$fp" ] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  now=$(cc_proc_fingerprint "$pid")
  [ "$fp" = "$now" ] || return 1
  if cc_stage_is_live "$run_dir" "$key"; then return 1; fi
  [ -n "$ledger" ] && [ -f "$ledger" ] || return 0
  att=$(cc_waiting_field "$f" '시도' | tr -d '[:space:]')
  lin=$(cc_waiting_field "$f" '계보')
  if [ -n "$att" ] \
     && [ -n "$( { grep -E '^- `stage-result`' "$ledger" 2>/dev/null || true; } \
                 | { grep -F -e "세그먼트=$key " -e "스테이지=$key " || true; } \
                 | { grep -F "실행 버전=$att " || true; } )" ]; then
    return 1
  fi
  if [ -n "$lin" ] \
     && [ -n "$( { grep -E '^- `blocked`' "$ledger" 2>/dev/null || true; } | cc_rows_naming_lineage "$lin")" ]; then
    return 1
  fi
  return 0
}

cc_waiting_age_base() {
  # cc_waiting_age_base <refreshed> <wake> — the epoch freshness is measured
  # from: the later of the two, the refresh alone when the wake is empty or 0.
  local r="${1:-0}" w="${2:-}"
  case "$r" in ''|*[!0-9]*) r=0 ;; esac
  case "$w" in ''|*[!0-9]*) w=0 ;; esac
  if [ "$w" -gt "$r" ]; then printf '%s' "$w"; else printf '%s' "$r"; fi
}

cc_waiting_records() {
  # cc_waiting_records <run-dir> <ledger> [stall] — one line per waiting stage:
  # `<key>\t<lineage>\t<group>\t<until>\t<refreshed>\t<holder>\t<writer>\t<fresh>`,
  # `<fresh>` being `true` or `false`. The stall threshold defaults to the
  # effective one; with none, no member is fresh.
  local run_dir="$1" ledger="$2" stall="${3:-}" f key wake now base fresh upd
  [ -n "$run_dir" ] || return 0
  for f in "$run_dir"/*.waiting; do
    [ -f "$f" ] || continue
    key=${f##*/}; key=${key%.waiting}
    cc_waiting_is_member "$run_dir" "$ledger" "$key" || continue
    if [ -z "${now:-}" ]; then
      now=$(date -u +%s)
      wake=$(wake_epoch)
      [ -n "$stall" ] || stall=$(cc_effective_stall "$run_dir" || true)
    fi
    upd=$(cc_waiting_field "$f" '갱신' | tr -d '[:space:]')
    base=$(cc_waiting_age_base "$upd" "$wake")
    fresh=false
    if [ -n "$stall" ] && [ "$base" -gt 0 ] && [ $((now - base)) -lt "$stall" ]; then fresh=true; fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$key" "$(cc_waiting_field "$f" '계보')" \
      "$(cc_waiting_field "$f" '그룹')" "$(cc_waiting_field "$f" '까지')" "$upd" \
      "$(cc_waiting_field "$f" '보유자' | tr -d '[:space:]')" "$(cc_waiting_field "$f" '기록자')" "$fresh"
  done
  return 0
}

cc_waiting_fresh_count() {
  # cc_waiting_fresh_count <run-dir> <ledger> [stall] — how many waiting stages
  # are fresh. The readers that count a live stage count these beside it.
  local n
  n=$(cc_waiting_records "$@" | awk -F'\t' '$8 == "true"' | grep -c . || true)
  printf '%s' "${n:-0}"
}

cc_open_approvals() {
  # cc_open_approvals <ledger> — count of approvals still waiting.
  # Last row per id wins: the ledger is append-only, so a resolution is a later
  # row rather than an edit of the earlier one.
  #
  # The id is matched as a whole field, `| 승인 id=<id> |`. A later row that
  # quotes a waiting id in its question text belongs to another approval, and
  # read as a substring it became the waiting id's last row and hid it.
  local ledger="$1" id st n=0
  [ -n "$ledger" ] || { printf '0'; return 0; }
  for id in $( { grep -E '^- `승인`' "$ledger" 2>/dev/null || true; } \
               | tr '|' '\n' | sed -n 's/^ *승인 id=//p' | sed 's/[[:space:]]*$//' | sort -u); do
    [ -n "$id" ] || continue
    st=$( { grep -E '^- `승인`' "$ledger" 2>/dev/null | grep -F "| 승인 id=$id |" || true; } | tail -1 \
          | tr '|' '\n' | sed -n 's/^ *상태=//p' | sed 's/[[:space:]]*$//' | tail -1)
    [ "$st" = "대기" ] && n=$((n + 1))
  done
  printf '%s' "$n"
}

# `완료` is the third terminal state, and its absence forced every honest
# router into a false statement. A stage that produced its output and had
# nothing to merge — an audit, a review, a census — could only be recorded as
# `머지됨` (claiming a merge that did not happen) or `park` (recording a success
# as a blockage, which the morning report then cannot tell from a real one). And
# the termination condition demands every segment reach a terminal state, so
# declining to choose left the run unable to end at all.
#
# THE ENUMERATION LIVES HERE, once. It used to be declared beside the gate's
# termination check while this file carried a two-element copy in a `case`, so
# the same segment was terminal to one reader and in flight to the other.
#
# `readonly` under a guard, because this file is sourced by more than one
# consumer and a second `source` in one shell would otherwise abort with
# "readonly variable". The guard admits the canonical value and overwrites any
# other, so a caller cannot pre-seed a different terminal set.
case " ${TERMINAL_SEGMENT_STATES:-} " in
  " 머지됨 완료 park ") ;;
  *) readonly TERMINAL_SEGMENT_STATES="머지됨 완료 park" ;;
esac

cc_nonterminal_segments() {
  # cc_nonterminal_segments <ledger> — count of segments not in a terminal state.
  # `TERMINAL_SEGMENT_STATES` above is the enumeration; everything else is in
  # flight. The membership test is the gate's, verbatim, because a second
  # spelling of it is how the two readers diverged in the first place.
  #
  # A `머지됨` CARRYING `적용=대기` IS IN FLIGHT. The gate's segment arm writes
  # that marker on the merge of a segment that still owes its apply — a fact
  # derived from the manifest, which this reader does not open — so the marker
  # is how the gate's condition 1 and this count agree on such a segment.
  local ledger="$1" sid row st ap n=0
  [ -n "$ledger" ] || { printf '0'; return 0; }
  for sid in $( { grep -E '^- `segment`' "$ledger" 2>/dev/null || true; } \
                | sed -n 's/.*id=\([^|]*\).*/\1/p' | sed 's/[[:space:]]*$//' | sort -u); do
    [ -n "$sid" ] || continue
    row=$( { grep -E '^- `segment`' "$ledger" 2>/dev/null | grep -F "id=$sid " || true; } | tail -1)
    st=$(printf '%s' "$row" | tr '|' '\n' | sed -n 's/^ *상태=//p' | sed 's/[[:space:]]*$//' | tail -1)
    ap=$(printf '%s' "$row" | tr '|' '\n' | sed -n 's/^ *적용=//p' | sed 's/[[:space:]]*$//' | tail -1)
    if [ "$st" = "머지됨" ] && [ "$ap" = "대기" ]; then
      n=$((n + 1)); continue
    fi
    case " $TERMINAL_SEGMENT_STATES " in
      *" $st "*) ;;
      *) n=$((n + 1)) ;;
    esac
  done
  printf '%s' "$n"
}

cc_segment_count() {
  # cc_segment_count <ledger> — distinct segment ids the run has opened.
  # The terminal predicate needs this as a guard: with no segments at all,
  # "every segment is terminal" is vacuously true and a run that has not begun
  # would render as finished.
  local ledger="$1"
  [ -n "$ledger" ] || { printf '0'; return 0; }
  { grep -E '^- `segment`' "$ledger" 2>/dev/null || true; } \
    | sed -n 's/.*id=\([^|]*\).*/\1/p' | sed 's/[[:space:]]*$//' | sort -u \
    | grep -c . || true
}

cc__blocked_fold() {
  # cc__blocked_fold <ledger> — one line per unresolved block that holds the
  # whole run, as `<사유><TAB><원인><TAB><스코프><TAB><앵커 세그먼트>`, sorted
  # by 사유. `cc_unresolved_blocked` and `cc_unresolved_blocked_where` below are
  # its only readers.
  #
  # THE RULE IS "LAST ROW PER 사유", NOT "ANY ROW". Counting raw rows made the
  # gate's termination condition a one-way latch: a ledger row is never deleted,
  # so a single run-scope block — including one a watcher raised on a false
  # positive — took the run's ability to propose done away permanently.
  #
  # The caller counts (`| wc -l`) and the caller decides what each 원인 means;
  # this function only applies the fold. That is what lets the gate's condition
  # 5 and the status line read the same rule instead of two copies of it.
  local ledger="$1"
  [ -n "$ledger" ] && [ -f "$ledger" ] || return 0
  # EVERY grep in this pipeline needs its own guard, not just the first. A middle
  # `grep` that matches nothing exits 1, `pipefail` promotes that to the whole
  # pipeline, and the caller runs this as a BARE statement under `set -e` — so a
  # ledger with no run-scope block at all, which is the ordinary case, killed the
  # gate's verb with status 1 and NO message. Every other refusal in this file
  # carries a sentence naming the repair; this path was the one that said nothing,
  # and a silent failure is the only kind a router cannot recover from.
  #
  # `LC_ALL=C` on the sort, because `사유` is Korean free text by contract and
  # this sort is a SET operation — it decides how many distinct run-scope blocks
  # the ledger holds, which is what the termination conditions and the status
  # line both read. Under `en_US.UTF-8` the collation gives every Hangul
  # syllable the same weight, so two reasons with the same non-Hangul shape and
  # the same syllable counts compare equal and one is dropped. Measured on this
  # host: `강제 표면 이동` and `자동 채택 미달` are one line under that locale and
  # two under C — and both of those are values this field is written with, so
  # the fold is reachable without anybody adding a word. Losing either is bad;
  # losing the first is worst, because it is
  # the block the gate raises when a file its boundary rests on was edited — and
  # a resolved block surviving in its place makes the run eligible to propose an
  # ending with the strongest block still open, reporting nothing.
  #
  # THE TARGET SET IS RUN-SCOPE ROWS AND STEP-ANCHORED CONE ROWS. A deadline
  # park on a design step has no segment to anchor to, so its cone row names the
  # step id in `앵커 세그먼트` — and a step stands in front of every segment, so
  # that row holds the whole run exactly as a run-scope row would. The anchor is
  # read from that field alone, never from `대상`: the driver's own cone rows
  # carry no such field (the `원인=무효화` row and the `대상=<결함>` row among
  # them), and reading "not a segment id" off `대상` would turn each of them into
  # a run stop that condition 5 then reports as unresolvable. A segment anchor
  # always has its `segment` row before its first dispatch, so "the field is set
  # and names no segment" is decidable from the ledger alone.
  #
  # The fold — last row per `사유` — runs inside that set, so an act-scope row
  # that reuses a run block's `사유` neither hides it nor stands in for it.
  #
  # A STEP CONE IS ALSO RELEASED BY A LATER ATTEMPT OF THE SAME KEY. Its `근거`
  # carries `계보=B:<키>#<N>`; when the resume command re-dispatches that key,
  # the new attempt's `stage-wait` or `stage-lease` row carries `계보=B:<키>#<M>`
  # with M > N, and that row is the evidence the park was acted on. A row whose
  # lineage is not of that shape — every driver lineage — is released by
  # `원인=해소` alone.
  LC_ALL=C awk '
    function fld(line, name,   n, i, a, s, v) {
      n = split(line, a, /\|/); v = ""
      for (i = 2; i <= n; i++) {
        s = a[i]; sub(/^[ \t]+/, "", s)
        if (index(s, name "=") == 1) { v = substr(s, length(name) + 2); sub(/[ \t]+$/, "", v) }
      }
      return v
    }
    function lineages(line,   s, out, p) {
      s = line; out = ""; p = length("계보=B:")
      while (match(s, /계보=B:[^ |#]+#[0-9]+/)) {
        out = out " " substr(s, RSTART + p, RLENGTH - p)
        s = substr(s, RSTART + RLENGTH)
      }
      return out
    }
    { lin[NR] = lineages($0) }
    /^- `segment`/ { id = fld($0, "id"); if (id != "") seg[id] = 1; next }
    /^- `blocked`/ {
      nb++; bnr[nb] = NR; bscope[nb] = fld($0, "스코프"); bwhy[nb] = fld($0, "사유")
      banchor[nb] = fld($0, "앵커 세그먼트"); bcause[nb] = fld($0, "원인")
    }
    END {
      # Segment ids are known only once the whole ledger is read, so the set is
      # filtered here rather than row by row.
      for (b = 1; b <= nb; b++) {
        why = bwhy[b]
        if (why == "") continue
        if (bscope[b] == "run") step = 0
        else if (bscope[b] == "cone" && banchor[b] != "" && !(banchor[b] in seg)) step = 1
        else continue
        last[why] = bnr[b]; lastcause[why] = bcause[b]; laststep[why] = step
        lastscope[why] = bscope[b]; lastanchor[why] = banchor[b]
      }
      for (why in last) {
        if (lastcause[why] == "해소") continue
        if (laststep[why] && split(lin[last[why]], own, " ") > 0) {
          k = own[1]; sub(/#[0-9]+$/, "", k); nn = own[1]; sub(/^.*#/, "", nn)
          released = 0
          for (j = last[why] + 1; j <= NR && !released; j++) {
            m = split(lin[j], later, " ")
            for (x = 1; x <= m; x++) {
              lk = later[x]; sub(/#[0-9]+$/, "", lk); ln = later[x]; sub(/^.*#/, "", ln)
              if (lk == k && ln + 0 > nn + 0) { released = 1; break }
            }
          }
          if (released) continue
        }
        printf "%s\t%s\t%s\t%s\n", why, lastcause[why], lastscope[why], lastanchor[why]
      }
    }
  ' "$ledger" | LC_ALL=C sort
}

cc_unresolved_blocked() {
  # cc_unresolved_blocked <ledger> — one line per unresolved block that holds
  # the whole run — a run-scope row, or a cone row anchored on a design step —
  # as `<원인><TAB><사유>`. The fold is `cc__blocked_fold`'s.
  cc__blocked_fold "$1" | LC_ALL=C awk -F '\t' '{ printf "%s\t%s\n", $2, $1 }'
}

cc_unresolved_blocked_where() {
  # cc_unresolved_blocked_where <ledger> — the same set as
  # `cc_unresolved_blocked`, as `<사유><TAB><스코프><TAB><앵커 세그먼트>` of the
  # row the fold kept. The snapshot projects these two fields; reading them off
  # the row the fold chose — not off "the last row of that 사유" — is what keeps
  # a later act-scope row with the same 사유 from relabelling a run block.
  cc__blocked_fold "$1" | LC_ALL=C awk -F '\t' '{ printf "%s\t%s\t%s\n", $1, $3, $4 }'
}

cc_open_approval_rows() {
  # cc_open_approval_rows <ledger> — one line per approval still waiting, as
  # `<id><TAB><절단점>`, with `-` when the row carries no 절단점.
  #
  # THE ROWS BEHIND `cc_open_approvals`, NOT A SECOND FOLD. The id collection,
  # the whole-field match and the last-row-per-id rule are that function's,
  # spelled the same way, so the line count here and its number are one answer.
  # `scripts/test-liveness-agreement.sh` holds the two together. The count stays
  # where it is rather than becoming `| wc -l` over this, because the run state
  # and the status line read it and are not to move.
  local ledger="$1" id row st cp
  [ -n "$ledger" ] || return 0
  for id in $( { grep -E '^- `승인`' "$ledger" 2>/dev/null || true; } \
               | tr '|' '\n' | sed -n 's/^ *승인 id=//p' | sed 's/[[:space:]]*$//' | sort -u); do
    [ -n "$id" ] || continue
    row=$( { grep -E '^- `승인`' "$ledger" 2>/dev/null | grep -F "| 승인 id=$id |" || true; } | tail -1)
    st=$(printf '%s' "$row" | tr '|' '\n' | sed -n 's/^ *상태=//p' | sed 's/[[:space:]]*$//' | tail -1)
    [ "$st" = "대기" ] || continue
    cp=$(printf '%s' "$row" | tr '|' '\n' | sed -n 's/^ *절단점=//p' | sed 's/[[:space:]]*$//' | tail -1)
    printf '%s\t%s\n' "$id" "${cp:--}"
  done
  return 0
}

cc_segment_states() {
  # cc_segment_states <ledger> — one line per segment, as
  # `<id><TAB><last 상태><TAB><open|done>`.
  #
  # THE THIRD FIELD IS THE VERDICT AND READERS TAKE IT FROM HERE. It is the
  # membership test of `cc_nonterminal_segments`, `머지됨` carrying `적용=대기`
  # included, and that case cannot be told from the 상태 field alone — so a
  # reader that re-applied `TERMINAL_SEGMENT_STATES` to the second field would
  # be the second copy that function's comment says split two readers before.
  # The `open` lines number exactly what that function counts.
  local ledger="$1" sid row st ap verdict
  [ -n "$ledger" ] || return 0
  for sid in $( { grep -E '^- `segment`' "$ledger" 2>/dev/null || true; } \
                | sed -n 's/.*id=\([^|]*\).*/\1/p' | sed 's/[[:space:]]*$//' | sort -u); do
    [ -n "$sid" ] || continue
    row=$( { grep -E '^- `segment`' "$ledger" 2>/dev/null | grep -F "id=$sid " || true; } | tail -1)
    st=$(printf '%s' "$row" | tr '|' '\n' | sed -n 's/^ *상태=//p' | sed 's/[[:space:]]*$//' | tail -1)
    ap=$(printf '%s' "$row" | tr '|' '\n' | sed -n 's/^ *적용=//p' | sed 's/[[:space:]]*$//' | tail -1)
    verdict=open
    if [ "$st" != "머지됨" ] || [ "$ap" != "대기" ]; then
      case " $TERMINAL_SEGMENT_STATES " in
        *" $st "*) verdict=done ;;
      esac
    fi
    printf '%s\t%s\t%s\n' "$sid" "${st:--}" "$verdict"
  done
  return 0
}

cc_cone_blocked() {
  # cc_cone_blocked <ledger> — one line per cone-scope block still standing, as
  # `<held|unresolved><TAB><subject><TAB><원인><TAB><사유><TAB><관측|->`.
  #
  # ITS CONSUMERS ARE `run-pane.sh` AND THE GATE SNAPSHOT'S `cone_blocks[]`,
  # which projects these lines as they are. `cc_run_state`, `cc_run_grade`, the
  # gate's termination conditions and `statusline.sh` do not call it, and a
  # cone block is deliberately not part of any run verdict: no ledger field
  # records whether a cone block is still in force and no verb resolves one, so
  # what this returns is a display rule, not a judgement a run may end on.
  #
  # THE SUBJECT is `앵커 세그먼트`, or `대상` when the row has no anchor. The
  # driver's `park()` writes no anchor and puts the concrete reason in `관측`
  # under a generic `사유`, so that field is carried out too.
  #
  # THE FOLD keeps the last row per (subject, 사유). It runs in awk under
  # `LC_ALL=C`, so two keys are one only when their bytes are — the same reason
  # `cc_unresolved_blocked` pins its sort: 사유 is Korean free text and a
  # collating comparison merges distinct reasons.
  #
  # A ROW IS HIDDEN when a `segment` row for its subject that is not `park`
  # appears anywhere after it — any one, not the last one. A cone row, then
  # park, then 실행중, then a park with no new cone row stays hidden: the later
  # park did not come from that reason. A re-dispatch that parks again makes
  # the driver write a fresh cone row, which shows on its own.
  #
  # A SUBJECT WITH NO `segment` ROW AT ALL is `unresolved` — an alias such as a
  # `판정 불가` subject or a review finding id the driver parked. Whether it
  # still stands cannot be read off the ledger, so the caller counts these
  # rather than listing them.
  #
  # Output is in ledger order of each kept row; 원인 is passed through as
  # written.
  local ledger="$1"
  [ -n "$ledger" ] && [ -f "$ledger" ] || return 0
  LC_ALL=C awk -F'|' '
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    function field(name,   i, f, n) {
      n = length(name)
      for (i = 2; i <= NF; i++) {
        f = trim($i)
        if (substr(f, 1, n) == name) return substr(f, n + 1)
      }
      return ""
    }
    /^- `segment`/ {
      id = field("id=")
      if (id == "") next
      seen[id] = 1
      if (field("상태=") != "park") moved[id] = NR
      next
    }
    /^- `blocked`/ {
      if (field("스코프=") != "cone") next
      subj = field("앵커 세그먼트=")
      if (subj == "") subj = field("대상=")
      if (subj == "") next
      reason = field("사유=")
      key = subj SUBSEP reason
      if (!(key in last)) order[++nk] = key
      last[key] = NR
      kSubj[key] = subj; kReason[key] = reason
      kCause[key] = field("원인="); kObs[key] = field("관측=")
    }
    END {
      for (i = 1; i <= nk; i++) {
        key = order[i]; s = kSubj[key]
        if (!(s in seen)) kind = "unresolved"
        else if ((s in moved) && moved[s] > last[key]) continue
        else kind = "held"
        obs = kObs[key]; if (obs == "") obs = "-"
        printf "%d\t%s\t%s\t%s\t%s\t%s\n", last[key], kind, s, kCause[key], kReason[key], obs
      }
    }
  ' "$ledger" 2>/dev/null | LC_ALL=C sort -n -k1,1 | cut -f2- || true
  return 0
}

cc_mtime() {
  # cc_mtime <path> — epoch seconds, or empty.
  # `stat` diverges between BSD and GNU on the very flag this needs, so neither
  # spelling is used. `date -r` is present on both and takes the file directly.
  [ -f "$1" ] || return 0
  date -u -r "$1" +%s 2>/dev/null || true
}

cc_ledger_size() {
  # cc_ledger_size <ledger> — the ledger's size in bytes, or empty.
  #
  # SIZE, NOT MTIME. An mtime moves without a byte changing, and a restored file
  # carries an old one. Size is what the watcher already measures, and having
  # the status line measure the same quantity is the point of this function
  # existing at all.
  [ -f "$1" ] || return 0
  wc -c < "$1" 2>/dev/null | tr -d ' ' || true
}

cc_ledger_growth_at() {
  # cc_ledger_growth_at <run-dir> [ledger] — epoch seconds when the ledger last
  # grew, or empty when nothing about this run has been recorded at all.
  #
  # THE HEARTBEAT FIELD IS THE RULE NOW, AND ITS ABSENCE IS THE EXCEPTION.
  # Measured 2026-09-07: 113 of 167 heartbeats on this host carry `마지막성장`.
  # The watcher publishes it, so a run with a live or recent watcher has it.
  #
  # THE LEDGER MTIME IS THE FALLBACK, AND IT IS OPTIONAL BY POSITION so that a
  # one-argument call — every caller before this second parameter existed —
  # keeps its old meaning. Reaching for it is not the same claim: the heartbeat
  # says "the watcher saw the ledger grow at T", the mtime says "the file was
  # last written at T". Both are facts about the RUN rather than about the
  # watcher, which is what lets a single value stand behind both.
  #
  # EMPTY IS STILL A VERDICT. When neither exists, nothing has been recorded
  # about this run — and `cc_run_state` reads that as 버려짐 rather than as
  # 진행중, because "no clock to judge by" is not evidence of progress.
  local run_dir="$1" ledger="${2:-}" hb v
  [ -n "$run_dir" ] || return 0
  hb="$run_dir/watch.heartbeat"
  if [ -f "$hb" ]; then
    v=$(sed -n 's/.*마지막성장=\([0-9][0-9]*\).*/\1/p' "$hb" 2>/dev/null | tail -1 || true)
    [ -n "$v" ] && { printf '%s' "$v"; return 0; }
  fi
  [ -n "$ledger" ] || return 0
  cc_mtime "$ledger"
}

cc_run_ends_on_done() {
  # cc_run_ends_on_done <run-dir> — succeeds when the run carries the
  # `ends-on-done` marker: the gate writes it once, when the seat's
  # `router-shift` actually launches a shift. Such a run settles its exit
  # clauses after the last segment and ends on `done`, so the ledger-derived
  # terminal conjunction does not end it. A run without the marker — an old
  # run, a driver run, a seat run that never launched a shift — keeps the
  # derived rule.
  [ -e "$1/ends-on-done" ]
}

cc_run_end_settled() {
  # cc_run_end_settled <run-dir> — succeeds when `done` exists and the
  # settlement is over: the run has no marker, or no shift is alive.
  #
  # SAME ANSWER FROM EVERY PROCESS. `cc_shift_is_live` reads only `shift.live`
  # and the process table, so the status line, the reaper, the watcher and the
  # gate's shift-return site all see the same moment. A reader that cannot see
  # the shift's process reads "no shift" and shows 종단 at `done`, which is
  # early by the done-tail only.
  [ -f "$1/done" ] || return 1
  cc_run_ends_on_done "$1" || return 0
  ! cc_shift_is_live "$1"
}

cc_run_settle_stuck() {
  # cc_run_settle_stuck <run-dir> <ledger> — succeeds when a marker-bearing run
  # sits in the settlement window with nobody settling it: no `done`, no live
  # stage, no pending approval, every segment terminal and at least one of
  # them, no unresolved run-scope block, and no live shift.
  #
  # Only the reaper reads this. Such a run never reads as 종단, so without it
  # the reaper would keep it forever; with it the run is reaped after the same
  # retention a 종단 run gets.
  local run_dir="$1" ledger="$2" n
  cc_run_ends_on_done "$run_dir" || return 1
  [ -f "$run_dir/done" ] && return 1
  n=$(cc_live_stages "$run_dir")
  [ "${n:-0}" -eq 0 ] 2>/dev/null || return 1
  n=$(cc_open_approvals "$ledger")
  [ "${n:-0}" -eq 0 ] 2>/dev/null || return 1
  n=$(cc_nonterminal_segments "$ledger")
  [ "${n:-0}" -eq 0 ] 2>/dev/null || return 1
  n=$(cc_segment_count "$ledger")
  [ "${n:-0}" -ge 1 ] 2>/dev/null || return 1
  n=$(cc_unresolved_blocked "$ledger" | grep -c . || true)
  [ "${n:-0}" -eq 0 ] 2>/dev/null || return 1
  ! cc_shift_is_live "$run_dir"
}

cc_run_idle_seconds() {
  # cc_run_idle_seconds <run-dir> <ledger> [now] — seconds since the ledger last
  # grew, clamped at zero, or empty when there is no clock at all.
  #
  # ONE IDLE FOR EVERY JUDGE. `cc_run_state` crosses into 버려짐 on this value and
  # `cc_run_settled_for_report` settles a run on it; two subtractions would let
  # one run be abandoned to the status line and still unsettled to the reporter.
  #
  # Clamped, because a ledger mtime in the future is not hypothetical — one run
  # on this host measured 28 seconds ahead. A negative idle would otherwise read
  # as the freshest run on the screen.
  local run_dir="$1" ledger="${2:-}" now="${3:-}" grew idle
  grew=$(cc_ledger_growth_at "$run_dir" "$ledger")
  [ -n "$grew" ] || return 0
  [ -n "$now" ] || now=$(date -u +%s)
  idle=$((now - grew))
  [ "$idle" -lt 0 ] && idle=0
  printf '%s' "$idle"
}

cc_run_settled_for_report() {
  # cc_run_settled_for_report <run-dir> <ledger> [abandon-seconds] — succeeds
  # when the run has settled, i.e. whatever is still unresolved in it is not
  # going to resolve on its own.
  #
  #   settled ⟺ state = 종단   ∧ idle ≥ 600
  #           ∨ state = 버려짐
  #           ∨ state = 승인대기 ∧ idle ≥ abandon
  #
  # THE THIRD ARM IS WHY THIS IS NOT `cc_run_state = 버려짐`. That function returns
  # 승인대기 before it looks at the clock, so a run holding an approval nobody
  # answers would never settle and its wait would never be reported.
  #
  # NO NEW TOKEN. This is a predicate over the existing ones (정산중, a run still
  # settling its exit clauses, is not settled here), so `cc_run_grade` and
  # the render's arms stay exactly as they are. `abandon` is inherited from
  # `cc_run_state`'s declaration when the caller passes none.
  #
  # 600 SECONDS AFTER 종단, because a finished run's log is still being written
  # for a while after `done` and a report taken inside that window reads a
  # ledger that is about to change.
  local run_dir="$1" ledger="$2" abandon="${3:-}" s idle
  if [ -n "$abandon" ]; then
    s=$(cc_run_state "$run_dir" "$ledger" "" "$abandon")
  else
    s=$(cc_run_state "$run_dir" "$ledger")
    abandon=3600
  fi
  idle=$(cc_run_idle_seconds "$run_dir" "$ledger")
  # No clock reads as infinitely idle, the same reading `cc_run_state` gives it.
  case "$s" in
    버려짐) return 0 ;;
    종단)     [ -z "$idle" ] && return 0; [ "$idle" -ge 600 ] 2>/dev/null ;;
    승인대기) [ -z "$idle" ] && return 0; [ "$idle" -ge "$abandon" ] 2>/dev/null ;;
    *)        return 1 ;;
  esac
}

cc_run_grade() {
  # cc_run_grade <token> — the selection rank of a state token, 1 (best) to 9.
  #
  # PURE, AND THAT IS THE WHOLE POINT. A version of this that took a run
  # directory and re-derived the state would walk the predicates a second time
  # on every render; measured 2026-09-07 that second pass costs 60–120ms per run
  # and a twelve-run session already spends 1.5s on one render. So the caller
  # grades the token it already has, and this function does no I/O.
  #
  # SIX RANKS, NOT TWO CLASSES. The old comparison ranked on "no sign of having
  # finished", which let a run that never opened a segment — permanently
  # non-terminal by construction — hold a session forever. Ranking on evidence
  # instead: a live stage beats a waiting approval, which beats a ledger that
  # moved inside `stall`, which beats a ledger that passed `stall` but not
  # `abandon`, which beats a finished run, which beats one that has gone quiet
  # past `abandon`. Six ranks carry seven tokens: 정산중 shares rank 3 with
  # 진행중, because a run settling its exit clauses deserves the same attention
  # as a run in progress.
  #
  # 정지경고 OUTRANKS 종단, and that is the rank this table exists to get right.
  # A run between two stages is still a run, and the gap between one stage ending
  # and the next being dispatched routinely passes `stall` — so while 정지경고 sat
  # below 종단, every one of those gaps handed the line to a run that finished
  # yesterday. Quiet is not finished. The still-going run keeps the screen and the
  # glyph is what says it has gone quiet.
  #
  # 버려짐 STAYS BELOW 종단, so `abandon` now separates the ORDER as well as the
  # glyph and the wording. Crossing that mark is exactly what drops a quiet run
  # beneath every finished one, which is the difference between "nobody has
  # written for three minutes" and "nobody has written for an hour".
  #
  # THE DEFAULT ARM IS THE WORST RANK ON PURPOSE — an unknown token must not
  # take the screen. It is also SILENT, so a token added to `cc_run_state`
  # without an arm here would quietly sink instead of failing; that is what
  # `scripts/lint-statusline-token-arms.sh` exists to catch on the render side,
  # and this function has to grow with the vocabulary in the same edit.
  #
  # THIS GRADE HAS TWO CONSUMERS, `statusline.sh` and the dashboard's port in
  # `dashboard_read.py`, and `scripts/test-liveness-agreement.sh` binds them: it
  # compares the port's grade against this function on each token this function
  # ranks, the list derived from the arms below, and on an unknown one. A token
  # added here needs its arm in the port in the same edit, or that suite fails.
  case "$1" in
    도는중)   printf '1' ;;
    승인대기) printf '2' ;;
    진행중)   printf '3' ;;
    정산중)   printf '3' ;;
    정지경고) printf '4' ;;
    종단)     printf '5' ;;
    버려짐)   printf '6' ;;
    *)        printf '9' ;;
  esac
}

cc_run_state() {
  # cc_run_state <run-dir> <ledger> [stall-seconds] [abandon-seconds] — one token.
  #
  # Tokens: 도는중 · 승인대기 · 종단 · 정지경고 · 진행중 · 정산중 · 버려짐
  #
  # TERMINAL IS JUDGED BEFORE THE STALL WARNING. A run that has finished has no
  # live stage and a ledger that stopped growing, which is also exactly the
  # shape of a stalled one; ordering the tests the other way labels every clean
  # finish a stall.
  #
  # THAT IS A TEST ORDER AND NOT A RANK. `cc_run_grade` puts 정지경고 ABOVE 종단,
  # which is the opposite direction, and the two do not conflict: this block
  # decides which token a run gets, the grade decides which of two runs holds the
  # line. Reading one as the other is what the two headings are spelled out to
  # prevent.
  #
  # AND 버려짐 IS JUDGED AFTER BOTH, for a sharper reason than tidiness. The
  # watcher's pass-side terminal arm compares this token against `종단` to
  # announce a run without the `ends-on-done` marker that ended by derivation;
  # a marker-bearing run is announced by the gate when its shift returns, or by
  # the watcher's loop exit on `done`, neither of which reads this token. An
  # idle arm placed before the terminal block would turn finished runs into
  # 버려짐 and silence the pass-side announcement. So the two arms that can
  # return 버려짐 both sit BELOW the terminal block and the 승인대기 test, and the
  # token is only ever carved out of 진행중, 정산중 and 정지경고. That is what
  # keeps the `종단` set byte-identical without opening `watch.sh` to check.
  #
  # `abandon` is declared here, once, and every consumer passes it explicitly or
  # inherits this default. Two consumers reading one run with two thresholds
  # would grade it differently and nobody would see the disagreement.
  #
  # For a run without the `ends-on-done` marker, `done` is a shortcut, not the
  # definition. Measured 2026-09-07: 99 of 202 run directories had the file,
  # because many runs never reach the propose-done path — so a predicate that
  # only read `done` would answer "진행 중" forever for runs that had plainly
  # ended. A run WITH the marker is the opposite case: its seat writes `done`
  # when the exit clauses are settled, so there `done` (with no live shift) is
  # the definition, and the ledger-derived conjunction reads as 정산중.
  local run_dir="$1" ledger="$2" stall="${3:-180}" abandon="${4:-3600}"
  local live pend nonterm n_seg blocked_n idle settle=0

  # A FRESH WAITER IS FOLDED INTO THE LIVE COUNT, never given a token of its
  # own: every token this function can return needs an arm in the status line,
  # and a stage waiting for an account is, to a reader of the run, a run that
  # is still going. Its freshness is judged on the watcher's effective
  # threshold, not on `stall` above, because the waiter paces its refresh on
  # that one.
  live=$(cc_live_stages "$run_dir")
  live=$(( ${live:-0} + $(cc_waiting_fresh_count "$run_dir" "$ledger") ))
  [ "$live" -gt 0 ] 2>/dev/null && { printf '도는중'; return 0; }

  blocked_n=$(cc_unresolved_blocked "$ledger" | grep -c . || true)
  pend=$(cc_open_approvals "$ledger")
  nonterm=$(cc_nonterminal_segments "$ledger")
  n_seg=$(cc_segment_count "$ledger")

  # terminal ⟺ no unresolved run-scope block ∧ ( settled done ∨ ( no
  # `ends-on-done` marker ∧ live = 0 ∧ pend = 0 ∧ nonterm = 0 ∧ n_seg ≥ 1 ) )
  #
  # A RUN CARRYING THE MARKER ENDS ON `done` AND ON NOTHING ELSE. Its seat
  # settles the exit clauses after the last segment, so the ledger-derived
  # conjunction only opens the settlement window (`settle=1`), which walks the
  # same age ladder as a run in progress and prints 정산중 where that run would
  # print 진행중. A `done` whose shift is still alive is the done-tail: 정산중
  # with no age ladder, because the shift has not handed the seat its turn yet.
  if [ "${blocked_n:-0}" -eq 0 ] 2>/dev/null; then
    if [ -f "$run_dir/done" ]; then
      if cc_run_end_settled "$run_dir"; then printf '종단'; else printf '정산중'; fi
      return 0
    fi
    if [ "${pend:-0}" -eq 0 ] 2>/dev/null \
       && [ "${nonterm:-0}" -eq 0 ] 2>/dev/null \
       && [ "${n_seg:-0}" -ge 1 ] 2>/dev/null; then
      if cc_run_ends_on_done "$run_dir"; then settle=1; else printf '종단'; return 0; fi
    fi
  fi

  [ "${pend:-0}" -gt 0 ] 2>/dev/null && { printf '승인대기'; return 0; }

  idle=$(cc_run_idle_seconds "$run_dir" "$ledger")
  # NO CLOCK AT ALL IS THE STRONGEST IDLE SIGNAL, not the weakest. Neither the
  # watcher's field nor a ledger file means nothing has ever been recorded about
  # this run, and the honest reading of that is 버려짐 rather than 진행중.
  [ -n "$idle" ] || { printf '버려짐'; return 0; }
  [ "$idle" -ge "$abandon" ] 2>/dev/null && { printf '버려짐'; return 0; }
  [ "$idle" -ge "$stall" ] 2>/dev/null && { printf '정지경고'; return 0; }

  [ "$settle" = 1 ] && { printf '정산중'; return 0; }
  printf '진행중'
}

# THE WATCHERS' IDLE-EXIT THRESHOLD, declared here once and read by both
# `watch.sh` and `checks.sh`. Neither declares a value of its own, and
# `scripts/lint-watch-threshold-pins.sh` holds that: two watchers of one run
# going quiet at two different moments would leave one of them behind for a
# reason nobody could read off either file.
#
# 24 HOURS, AND THE NUMBER IS CHOSEN TO BE LONGER THAN A NIGHT. A run that waits
# for a person overnight is in a legitimate state, and so is one that waits out
# a weekend morning; a shorter value would take the progress channel away from
# the very run somebody is about to answer. The predicate below already leaves
# out runs with an open approval or an unanswered halt record, so this number
# covers only the run that waits for nobody.
#
# NOT `readonly`: this file is sourced more than once in one shell, and a plain
# assignment also overwrites whatever a caller's environment carried.
CC_RUN_IDLE_EXIT_SECONDS=86400

cc__halt_answer_state() {
  # cc__halt_answer_state <ledger> <tail> — `없음` when no `중단 답` row names
  # the record whose `중단 기록=` ends in <tail>, `되돌림` when its last such row
  # is named by a later block's `막힌 답 줄`, and `답함` otherwise.
  #
  # Fields are matched whole between ` | ` separators, the record on its tail
  # for the reason `cc_unanswered_halts` gives.
  [ -n "$1" ] && [ -f "$1" ] || { printf '없음'; return 0; }
  awk -v t="$2" '
    { nf = split($0, f, / \| /) }
    index($0, "- `중단 답` | ") == 1 {
      for (i = 2; i <= nf; i++) {
        if (index(f[i], "중단 기록=") != 1) continue
        v = substr(f[i], length("중단 기록=") + 1)
        sub(/[[:space:]]+$/, "", v)
        if (length(v) >= length(t) && substr(v, length(v) - length(t) + 1) == t) last = NR
      }
    }
    index($0, "- `blocked` | ") == 1 {
      for (i = 2; i <= nf; i++) {
        s = f[i]; sub(/[[:space:]]+$/, "", s)
        if (index(s, "막힌 답 줄=") == 1) stamped[substr(s, length("막힌 답 줄=") + 1)] = 1
      }
    }
    END {
      if (!last) { printf "없음"; exit }
      if (stamped[last ""]) { printf "되돌림"; exit }
      printf "답함"
    }' "$1" 2>/dev/null || printf '없음'
}

cc_halt_returned() {
  # cc_halt_returned <ledger> <tail> — succeeds when the record's answer was
  # returned to a person: its last `중단 답` row is the one a later routing
  # block names by `막힌 답 줄`, and no `중단 답` naming the record follows.
  #
  # A RETURNED RECORD IS UNANSWERED AGAIN. The shift could not carry the answer
  # out and wrote a block saying so; the gate stamped that block with the
  # answer's line. Every reader of "is this record still waiting for a person"
  # — this file's count, rekick's list, the snapshot's `returned_halts[]` and
  # the automatic-answer bound — asks this one function, so none of them can
  # read the record as answered while another reads it as waiting. A person's
  # new `중단 답` ends the state, because the new row is the last one and no
  # block names it.
  [ "$(cc__halt_answer_state "$1" "$2")" = "되돌림" ]
}

cc_halt_answered() {
  # cc_halt_answered <ledger> <tail> — succeeds when a `중단 답` row names the
  # record and its answer was not returned (`cc_halt_returned`).
  [ "$(cc__halt_answer_state "$1" "$2")" = "답함" ]
}

cc_unanswered_halts() {
  # cc_unanswered_halts <run-dir> <ledger> — count of halt records under
  # `<run-dir>/halt/` that no `중단 답` row names, or whose answer was returned
  # to a person (`cc_halt_returned`).
  #
  # A HALT RECORD IS A QUESTION TO A PERSON, and until a row answers it the run
  # is waiting rather than idle. The answer attachment the seat writes beside a
  # record (`<record>.answer.md`) is not a question and is not counted.
  #
  # MATCHED ON THE WHOLE FIELD, and on the path's tail from the run directory's
  # own name down. The gate writes `중단 기록=<its run dir>/halt/<name>.md`, and a
  # watcher may have been handed the same directory under another spelling (a
  # trailing slash, a symlinked state home); the run id and the record name are
  # what both spellings share. The ledger is this run's own, so the tail is
  # unique in it.
  #
  # `halt/shift/` IS SCANNED TOO. The gate writes a routing shift's halt record
  # there, one level down, and it is as much a question to a person as a
  # stage's; its tail keeps the `shift/` component, which is what the gate's
  # row carries.
  local run_dir="${1%/}" ledger="$2" f name tail n=0
  [ -n "$run_dir" ] && [ -d "$run_dir/halt" ] || { printf '0'; return 0; }
  for f in "$run_dir"/halt/*.md "$run_dir"/halt/shift/*.md; do
    [ -f "$f" ] || continue
    case "$f" in *.answer.md) continue ;; esac
    name=${f##*/}
    case "$f" in
      "$run_dir"/halt/shift/*) tail="/${run_dir##*/}/halt/shift/$name" ;;
      *) tail="/${run_dir##*/}/halt/$name" ;;
    esac
    if [ -n "$ledger" ] && cc_halt_answered "$ledger" "$tail"; then
      continue
    fi
    n=$((n + 1))
  done
  printf '%s' "$n"
}

cc_run_idle_exit() {
  # cc_run_idle_exit <run-dir> [T] [ledger] [since] — succeeds when the run's
  # watchers have nothing left to watch: no live shift, no live stage and no
  # fresh waiter; no open approval; no unanswered halt record; and a ledger that
  # has not grown for T seconds, nor been watched by this caller for less than
  # T. T defaults to `CC_RUN_IDLE_EXIT_SECONDS`, the ledger to the caller's
  # `LEDGER`; `since` is the epoch the caller started watching.
  #
  # THIS IS NOT `버려짐`, and the difference is the whole reason it exists.
  # `cc_run_state` reads a run that waits on a halt record as abandoned after
  # an hour, because it never looks at `halt/`; a watcher that went quiet on
  # that token would leave a person's unanswered question with no progress
  # channel behind it. The two conditions that mean "a person owes this run an
  # answer" are tested here first, and only a run that waits for nobody can
  # pass.
  #
  # THE RUN STAYS OPEN. Nothing here writes, and a watcher that leaves on this
  # predicate writes no `done`: closing a run that another run took over, or that
  # a person gave up, is `gate.sh end-abandoned`. A run that moves again later
  # gets its watchers back from the seat when it launches the next shift.
  #
  # UNREADABLE GROWTH IS NOT IDLENESS. When neither the heartbeat field nor the
  # ledger's mtime can be read, the answer is "not idle", so a reader that
  # cannot see the clock keeps watching rather than leaving.
  #
  # THE CLOCK IS THE LATEST OF THREE, NOT THE HEARTBEAT ALONE. A watcher that
  # left on this predicate stops writing `watch.heartbeat`, so its `마지막성장`
  # stays a day old for good; read first, as `cc_ledger_growth_at` does, it made
  # a watcher the seat had just started again leave on its first iteration — a
  # row appended since then could not move it, and the seat starts the watcher
  # before the shift that would make anything live. So the ledger's own mtime
  # counts beside the field, and the optional fourth argument — the epoch the
  # caller started watching — counts too: a watcher leaves only after watching
  # this run for T seconds itself, never on a clock a previous watcher left.
  local run_dir="$1" t="${2:-}" ledger="${3:-${LEDGER:-}}" since="${4:-}" n grew v now idle
  [ -n "$t" ] || t="$CC_RUN_IDLE_EXIT_SECONDS"
  case "$t" in ''|*[!0-9]*) return 1 ;; esac
  [ -n "$run_dir" ] && [ -d "$run_dir" ] || return 1
  cc_shift_is_live "$run_dir" && return 1
  n=$(cc_live_stages "$run_dir")
  n=$(( ${n:-0} + $(cc_waiting_fresh_count "$run_dir" "$ledger") ))
  [ "$n" -eq 0 ] 2>/dev/null || return 1
  n=$(cc_open_approvals "$ledger")
  [ "${n:-0}" -eq 0 ] 2>/dev/null || return 1
  n=$(cc_unanswered_halts "$run_dir" "$ledger")
  [ "${n:-0}" -eq 0 ] 2>/dev/null || return 1
  grew=$(cc_ledger_growth_at "$run_dir" "$ledger")
  [ -n "$grew" ] || return 1
  case "$grew" in *[!0-9]*) return 1 ;; esac
  for v in "$(cc_mtime "$ledger")" "$since"; do
    case "$v" in ''|*[!0-9]*) continue ;; esac
    [ "$v" -gt "$grew" ] && grew=$v
  done
  now=$(date -u +%s)
  idle=$((now - grew))
  [ "$idle" -lt 0 ] && idle=0
  [ "$idle" -ge "$t" ]
}
