#!/usr/bin/env bash
# worktree-cleanup.sh — the run-complete cleanup of segment worktrees and of
# the local branches of merged segments, and the gate's ledger readers that
# cleanup shares with the driver.
#
# ONE ROUTINE, THREE CALL SITES, ONE RULE. The gate calls `wtc_run 라우터` in
# the two arms that end a run with every termination condition met (an
# accepted `propose-done`, and an `act`/`exec` refused because no next
# obligation could be named), and run.sh calls `wtc_run 드라이버` at the end of
# its walk. Both paths read run completion off the same row — the earliest
# ending row of this run, as `gate_end_token_row` selects it — so a run counts
# as complete for cleanup only when that row carries `종료 부류=완료`. The
# driver adds four guards of its own on top (halt flag, run-scope blocks,
# budget/wall-clock parks, open judgment approvals), because its `완료` is
# decided from slice landings alone.
#
# WHAT IT DOES NOT DO. It writes nothing to `done`, parks nothing, raises no
# banner, adds no ledger row form and returns 0 whatever happens: a cleanup
# failure is reported, never escalated. It never passes `--force` to
# `git worktree remove` or `-D` to `git branch`, never prunes, never fetches,
# and never deletes a remote branch. Every git call runs in a subshell rooted
# at the declared target's main worktree, its exit status is captured and
# checked here, and its stderr is dropped — a `ls-remote` error can print the
# remote URL, and a URL can carry a credential.
#
# WHY THE GATE'S READERS LIVE HERE. run.sh sources this file and gate.sh
# sources run.sh, so a definition here is one definition for both processes.
# `gate_rows`, `gate_row_field` and `gate_pending_approval_ids` are defined
# here only; a second copy in gate.sh would shadow this one in the gate and
# leave the moved copy untested there. `gate_pending_approval_ids 사람` still
# calls run.sh's `judgment_class_person`, so that mode is only callable in a
# process that loaded run.sh.
#
# Compatibility: bash 3.2 — no associative arrays, no `mapfile`. Called under
# `set -euo pipefail` behind `|| true`, so errexit does not apply inside and
# every empty array or unset variable is expanded in a nounset-safe form.

# ---------------------------------------------------------------------------
# Ledger readers shared with the gate.
#
# A ledger that does not exist yet is the NORMAL state at the first act of a
# run, and `grep` answers a missing file with exit 2 — which `pipefail`
# promotes to the whole pipeline's status and `set -e` turns into a silent exit
# of the snapshot. The first act of the first run is exactly when a router most
# needs the snapshot to answer, so the tolerance is not defensive padding: it
# is the case that always happens.
#
# THE READ-ZONE MEMO. The four `GATE_ROWS_MEMO_*` names exist only as `local`s
# of a warming function (see `gate_ledger_warm`), so they are cleared here at
# load. A caller whose environment carried one of them in would otherwise have
# that scalar read as element 0 of the memo, and `gate_rows` would answer rows
# the ledger does not hold. This is the file's only statement run at load, and
# it runs in every process that loads run.sh, the driver included.
# ---------------------------------------------------------------------------
unset GATE_ROWS_MEMO_LEDGER GATE_ROWS_MEMO_N GATE_ROWS_MEMO_KINDS GATE_ROWS_MEMO_ROWS
gate_rows() {
  # gate_rows <series>
  #
  # Inside a warmed zone a series the zone warmed is answered from the memo,
  # with builtins only, so the read spawns no process. The memo is consulted
  # only while `LEDGER` is still the path it was filled from; a string compare,
  # not a freshness probe — a probe would be a process per call, the very cost
  # the memo removes. Everything else falls through to the grep, unchanged.
  if [ -n "${GATE_ROWS_MEMO_LEDGER:-}" ] && [ "$GATE_ROWS_MEMO_LEDGER" = "$LEDGER" ]; then
    local m=0
    while [ "$m" -lt "${GATE_ROWS_MEMO_N:-0}" ]; do
      if [ "${GATE_ROWS_MEMO_KINDS[$m]}" = "$1" ]; then
        [ -z "${GATE_ROWS_MEMO_ROWS[$m]}" ] || printf '%s\n' "${GATE_ROWS_MEMO_ROWS[$m]}"
        return 0
      fi
      m=$((m + 1))
    done
  fi
  grep -E "^- \`$1\`" "$LEDGER" 2>/dev/null || true
}

gate_row_field() {
  # gate_row_field <row-text> <key> — the last value with that key in ONE row.
  # `gate_field_of` reads an argv field LIST; carrying a value forward needs a
  # field of a row already written, and the two are not interchangeable.
  local row="$1" key="$2"
  printf '%s' "$row" | tr '|' '\n' | sed -n "s/^ *$key=//p" | sed 's/[[:space:]]*$//' | tail -1
}

gate_pending_approval_ids() {
  # gate_pending_approval_ids [act|판단] — pending approval ids, optionally
  # narrowed by whether the row's `절단점` is the literal `판단`.
  #
  # The narrowing exists because the two kinds of answer have different lifetimes
  # and only one of them expires with the night. An ACT approval's answer is
  # valid now — its binding tuple carries head and base shas and freshness is
  # re-derived against them — so a run may not end while one is open. A QUESTION
  # approval's answer is an input to work that has not started; it is durable,
  # and a successor run can consume it. Counting the second kind in termination
  # condition 2 is what made one open question a run that could never say it was
  # done, which is the defect this design exists to remove.
  #
  # `사람` NARROWS FURTHER, to the `판단` approvals whose class is in the person
  # set: the kind of question the run does not end around. Its answer is not an
  # input a successor consumes but the decision the held segment is waiting on,
  # so termination condition 2 counts these beside the act approvals.
  local want="${1:-}" id st row cut
  for id in $(gate_rows '승인' | tr '|' '\n' | sed -n 's/^ *승인 id=//p' | sed 's/[[:space:]]*$//' | sort -u); do
    [ -n "$id" ] || continue
    row=$( { gate_rows '승인' | grep -F "| 승인 id=$id |" || true; } | tail -1)
    st=$(gate_row_field "$row" '상태')
    [ "$st" = "대기" ] || continue
    if [ -n "$want" ]; then
      cut=$(gate_row_field "$row" '절단점')
      case "$want" in
        act)  [ "$cut" = "판단" ] && continue ;;
        판단) [ "$cut" = "판단" ] || continue ;;
        사람) [ "$cut" = "판단" ] || continue
              judgment_class_person "$(gate_row_field "$row" '판단 부류')" || continue ;;
      esac
    fi
    printf '%s\n' "$id"
  done
  return 0
}

# ---------------------------------------------------------------------------
# Run completion.
# ---------------------------------------------------------------------------
wtc_end_row_complete() {
  # wtc_end_row_complete — 0 when this run's earliest ending row carries the
  # whole field `종료 부류=완료`; otherwise 1, printing the first unmet
  # condition. The row is the one `gate_end_token_row` selects, the gate's
  # single selector for the end token, `종료 부류` and `재킥 지문`, so this
  # never reads a different row than the gate does. In the gate's process the
  # selector is a function of this shell; in the driver's it is reached through
  # `run_gate_call`, as `run_end_record` reaches `gate_end_token`. `done` is
  # not read: its first line has five forms, and the driver's normal end writes
  # a boundary form there.
  local row rc=0 cause kind
  if declare -F gate_end_token_row >/dev/null 2>&1; then
    row=$(gate_end_token_row 2>/dev/null) || rc=$?
  elif declare -F run_gate_call >/dev/null 2>&1; then
    row=$(run_gate_call gate_end_token_row 2>/dev/null) || rc=$?
  else
    rc=1; row=""
  fi
  if [ "$rc" -ne 0 ] || [ -z "${row:-}" ]; then
    printf '종료 행 없음'
    return 1
  fi
  case "$row | " in *" | 종료 부류=완료 | "*) return 0 ;; esac
  cause=$(wtc_row_field_exact "$row" '재킥 원인')
  kind=$(wtc_row_field_exact "$row" '종료 부류')
  printf '종료 행 재킥 원인 %s · 종료 부류 %s' "${cause:-없음}" "${kind:-없음}"
  return 1
}

wtc_row_field_exact() {
  # wtc_row_field_exact <row> <key> — the value of the first ` | `-delimited
  # field whose text begins with `<key>=`, or nothing. A whole-field read, so a
  # key that ends another key is not taken for it.
  printf '%s' "$1" | awk -v k="$2=" '
    { n = split($0, f, / \| /)
      for (i = 2; i <= n; i++) if (index(f[i], k) == 1) { print substr(f[i], length(k) + 1); exit } }'
}

wtc_router_should_run() {
  # The router path is called only in the two arms that end a run satisfied,
  # so completion is the whole predicate there.
  wtc_end_row_complete
}

wtc_driver_should_run() {
  # wtc_driver_should_run — the five conditions of the driver path, in order;
  # prints the first that fails. The second is the shared completion check;
  # the other four are guards the driver adds because its `완료` is decided
  # from slice landings and does not look at blocks or approvals.
  local out ids
  if [ "${RUN_HALTED:-0}" != "0" ]; then
    printf '런 정지(RUN_HALTED=%s)' "${RUN_HALTED:-}"
    return 1
  fi
  out=$(wtc_end_row_complete) || { printf '%s' "$out"; return 1; }
  out=$(cc_unresolved_blocked "${LEDGER:-}" 2>/dev/null | cut -f2 | awk 'NF' | LC_ALL=C sort -u | paste -s -d, - || true)
  if [ -n "$out" ]; then
    printf '풀리지 않은 run 막힘(%s)' "$(wtc_brief "$out")"
    return 1
  fi
  out=$( { grep -E '^- `blocked` ' "${LEDGER:-/dev/null}" 2>/dev/null || true; } \
       | awk '{ if (index($0 " | ", " | 사유=예산·벽시계 | ")) n++ } END { print n + 0 }')
  if [ "${out:-0}" != "0" ]; then
    printf '예산·벽시계 막힘 행'
    return 1
  fi
  ids=$(gate_pending_approval_ids 판단 2>/dev/null | awk 'NF' | paste -s -d, - || true)
  if [ -n "$ids" ]; then
    printf '열린 판단 승인(%s)' "$(wtc_brief "$ids")"
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Reporting. One prose line per act through run.sh's `report_append`, kept
# under 1024 bytes: concurrent appends above that splice field values. An id
# list is cut to its first five and `…(<n>개)`, and `사유=` always survives.
# ---------------------------------------------------------------------------
wtc_brief() {
  # wtc_brief <a,b,c,…> — the list, or its first five and `…(<n>개)`.
  local list="$1" n
  n=$(printf '%s' "$list" | tr ',' '\n' | awk 'NF' | wc -l | tr -d ' ')
  if [ "${n:-0}" -le 5 ]; then
    printf '%s' "$list"
  else
    printf '%s,…(%s개)' "$(printf '%s' "$list" | tr ',' '\n' | awk 'NF' | sed -n '1,5p' | paste -s -d, -)" "$n"
  fi
}

wtc_fit() {
  # wtc_fit <text> — the text, shortened before its ` · 사유=` part until the
  # whole report line stays under 1024 bytes.
  local text="$1" head tail max=940
  [ "$(printf '%s' "$text" | LC_ALL=C wc -c | tr -d ' ')" -le "$max" ] && { printf '%s' "$text"; return 0; }
  case "$text" in
    *" · 사유="*) head="${text%% · 사유=*}"; tail=" · 사유=${text#* · 사유=}" ;;
    *) head="$text"; tail="" ;;
  esac
  while [ -n "$head" ] && [ "$(printf '%s…%s' "$head" "$tail" | LC_ALL=C wc -c | tr -d ' ')" -gt "$max" ]; do
    if [ "${#head}" -gt 32 ]; then head="${head:0:$((${#head} - 32))}"; else head="${head:0:$((${#head} - 1))}"; fi
  done
  printf '%s…%s' "$head" "$tail"
}

wtc_say() {
  # wtc_say <부류> <text> — one report line, never a failure.
  report_append "$1" "$(wtc_fit "$2")" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# The routine.
# ---------------------------------------------------------------------------
wtc_norm() {
  # wtc_norm <path> — the `pwd -P` form of an existing directory, else the path.
  if [ -n "$1" ] && [ -d "$1" ]; then ( cd "$1" 2>/dev/null && pwd -P ) || printf '%s' "$1"
  else printf '%s' "$1"; fi
}

wtc_seg_field_values() {
  # wtc_seg_field_values <ledger> <sid> <key> [skip-state] — every value of
  # <key> on the segment rows whose `id` field is exactly <sid>, one per line,
  # in ledger order, skipping rows whose `상태` is [skip-state].
  { grep -E '^- `segment` ' "$1" 2>/dev/null || true; } | awk -v id="id=$2" -v k="$3=" -v skip="${4:-}" '
    { n = split($0, f, / \| /); hit = 0; st = ""; v = ""; have = 0
      for (i = 2; i <= n; i++) {
        if (f[i] == id) hit = 1
        if (index(f[i], "상태=") == 1) st = substr(f[i], length("상태=") + 1)
        if (index(f[i], k) == 1) { v = substr(f[i], length(k) + 1); have = 1 }
      }
      if (hit && have && !(skip != "" && st == skip)) print v }'
}

wtc_run() {
  # wtc_run <라우터|드라이버> — the only entry point. Always returns 0.
  local mode="${1:-라우터}" why caller mark
  caller=$(pwd -P 2>/dev/null || true)
  if [ "$mode" = "드라이버" ]; then
    why=$(wtc_driver_should_run) || { wtc_say '워크트리 정리' "생략 — ${why:-판정 실패}"; return 0; }
  else
    why=$(wtc_router_should_run) || { wtc_say '워크트리 정리' "생략 — ${why:-판정 실패}"; return 0; }
  fi
  if [ -z "${MANIFEST:-}" ]; then
    wtc_say '워크트리 정리' '생략 — 매니페스트 없음(--doc 모드)'
    return 0
  fi
  if [ -z "${LEDGER:-}" ] || [ "$(basename "$LEDGER")" != "${RUN_ID:-}.md" ] \
     || grep -q '^## 실행 ' "$LEDGER" 2>/dev/null; then
    wtc_say '워크트리 정리' '생략 — 원장이 이 런 하나의 파일이 아님'
    return 0
  fi
  mark="${RUN_DIR:-}/worktree-cleanup.once"
  if [ -n "${RUN_DIR:-}" ] && [ -d "$mark" ]; then
    wtc_say '워크트리 정리' '생략 — 이 런 디렉터리에서 이미 정리함'
    return 0
  fi
  [ -z "${RUN_DIR:-}" ] || mkdir "$mark" 2>/dev/null || true
  wtc_sweep "$mode" "$caller" || true
  return 0
}

wtc_sweep() {
  # wtc_sweep <mode> <caller cwd> — candidates, the worktree pass, the branch
  # pass and the summary line. Every list is a newline-separated string so
  # nothing here expands an empty array.
  local mode="$1" caller="$2" nl=$'\n' tab=$'\t'
  local states sid st verdict w line a root rc out p pn
  local roots="" porc="" porc_fail="" protect="" pairs="" cands=""
  local wt_rm=0 wt_keep=0 br_del=0 br_keep=0 outcomes=""
  states=$(cc_segment_states "$LEDGER" 2>/dev/null || true)

  # Candidates: every distinct `워크트리=` of each segment's rows other than
  # `상태=적용 준비`, paired with the segment that named it.
  while IFS="$tab" read -r sid st verdict; do
    [ -n "${sid:-}" ] || continue
    while IFS= read -r w; do
      [ -n "${w:-}" ] || continue
      pairs="${pairs}${w}${tab}${sid}${nl}"
    done <<EOF
$(wtc_seg_field_values "$LEDGER" "$sid" '워크트리' '적용 준비' | awk '!seen[$0]++')
EOF
  done <<EOF
$states
EOF
  cands=$(printf '%s' "$pairs" | cut -f1 | awk 'NF && !seen[$0]++')

  # Declared targets: their main roots, their registered worktrees, and the
  # paths that are never this run's to remove.
  for a in $(target_aliases 2>/dev/null || true); do
    root=$(alias_root "$a" 2>/dev/null) || root=""
    [ -n "$root" ] || continue
    root=$(wtc_norm "$root")
    roots="${roots}${a}${tab}${root}${nl}"
    protect="${protect}${root}${nl}"
    p=$(target_field "$a" '메인 워크트리' 2>/dev/null || true); [ -z "$p" ] || protect="${protect}$(wtc_norm "$p")${nl}"
    p=$(target_field "$a" '실행 워크트리' 2>/dev/null || true); [ -z "$p" ] || protect="${protect}$(wtc_norm "$p")${nl}"
    rc=0; out=$( cd "$root" && git worktree list --porcelain 2>/dev/null ) || rc=$?
    if [ "$rc" -ne 0 ]; then porc_fail="$rc"; continue; fi
    # One record per entry: <root> TAB <path> TAB <normalized> TAB <flags>,
    # flags being `main`, `locked`, `detached` and `head=<sha>`.
    porc="${porc}$(printf '%s\n' "$out" | awk -v r="$root" '
      function flush() { if (path != "") printf "%s\t%s\t%s\n", r, path, flags; path = ""; flags = "" }
      /^worktree / { flush(); path = substr($0, 10); flags = (seen ? "" : "main"); seen = 1; next }
      /^HEAD / { flags = flags " head=" substr($0, 6); next }
      /^detached$/ { flags = flags " detached"; next }
      /^locked/ { flags = flags " locked"; next }
      END { flush() }')${nl}"
  done
  p=$(manifest_hdr_field 'origin-worktree' 2>/dev/null || true); [ -z "$p" ] || protect="${protect}$(wtc_norm "$p")${nl}"
  [ -z "${BASE:-}" ] || protect="${protect}$(wtc_norm "$BASE")${nl}"
  porc=$(printf '%s' "$porc" | awk -F '\t' 'NF >= 2' | while IFS="$tab" read -r root p line; do
    printf '%s\t%s\t%s\t%s\n' "$root" "$p" "$(wtc_norm "$p")" "${line:-}"
  done)
  protect="${protect}$(printf '%s\n' "$porc" | awk -F '\t' '$4 ~ /(^| )main( |$)/ { print $3 }')${nl}"

  # The worktree pass.
  local segs_of entry eroot epath eflags reason sha
  while IFS= read -r w; do
    [ -n "${w:-}" ] || continue
    segs_of=$(printf '%s' "$pairs" | awk -F '\t' -v w="$w" '$1 == w { print $2 }' | awk '!seen[$0]++' | paste -s -d, -)
    pn=$(wtc_norm "$w")
    reason=""
    entry=$(printf '%s\n' "$porc" | awk -F '\t' -v a="$pn" -v b="$w" '$3 == a || $2 == b { print; exit }')
    eroot=""; epath=""; eflags=""
    [ -z "$entry" ] || IFS="$tab" read -r eroot epath _ eflags <<EOF
$entry
EOF
    case "-$(basename "$w")-" in *"-${RUN_ID}-"*) : ;; *) reason='런 id 없는 경로' ;; esac
    if [ -z "$reason" ] && [ -z "$entry" ]; then
      if [ -n "$porc_fail" ]; then reason="판정 읽기 실패(워크트리 목록 git 종료 $porc_fail)"
      elif [ -d "$w" ]; then reason='선언된 대상의 워크트리 아님'
      else outcomes="${outcomes}${w}${tab}N${nl}"; continue
      fi
    fi
    if [ -z "$reason" ]; then
      case "${nl}${protect}${nl}" in *"${nl}${pn}${nl}"*) reason='메인·실행 워크트리' ;; esac
    fi
    if [ -z "$reason" ] && [ -n "$caller" ]; then
      case "$caller/" in "$pn"/*) reason='호출자 작업 디렉터리' ;; esac
    fi
    [ -n "$reason" ] || reason=$(wtc_worktree_verdict "$w" "$pn" "$segs_of" "$states" "$eroot" "$eflags")
    if [ -n "$reason" ]; then
      wt_keep=$((wt_keep + 1)); outcomes="${outcomes}${w}${tab}P${nl}"
      wtc_say '워크트리 정리' "보존 · $w · 세그먼트 $(wtc_brief "$segs_of") · 사유=$reason"
      continue
    fi
    local existed=0 segdesc
    [ -d "$w" ] && existed=1
    segdesc=$(printf '%s\n' "$segs_of" | tr ',' '\n' | while IFS= read -r sid; do
      [ -n "$sid" ] || continue
      printf '%s(%s)\n' "$sid" "$(printf '%s\n' "$states" | awk -F '\t' -v s="$sid" '$1 == s { print $2; exit }')"
    done | paste -s -d, -)
    rc=0; ( cd "$eroot" && git worktree remove "$epath" >/dev/null 2>&1 ) || rc=$?
    if [ "$rc" -eq 0 ]; then
      wt_rm=$((wt_rm + 1)); outcomes="${outcomes}${w}${tab}R${nl}"
      if [ "$existed" = "1" ]; then
        wtc_say '워크트리 정리' "제거 · $w · 세그먼트 $(wtc_brief "$segdesc")"
      else
        wtc_say '워크트리 정리' "제거 · 이미 없음 · $w · 세그먼트 $(wtc_brief "$segdesc")"
      fi
    else
      wt_keep=$((wt_keep + 1)); outcomes="${outcomes}${w}${tab}P${nl}"
      wtc_say '워크트리 정리' "보존 · $w · 세그먼트 $(wtc_brief "$segs_of") · 사유=비강제 철거 거부(git 종료 $rc)"
    fi
  done <<EOF
$cands
EOF

  # The branch pass: only a terminal `머지됨` segment gets past step 1.
  local b kept rsha lsha after afail
  after=""; afail=""
  while IFS="$tab" read -r eroot; do
    [ -n "${eroot:-}" ] || continue
    rc=0; out=$( cd "$eroot" && git worktree list --porcelain 2>/dev/null ) || rc=$?
    if [ "$rc" -ne 0 ]; then afail="$rc"; else after="${after}${out}${nl}"; fi
  done <<EOF
$(printf '%s' "$roots" | cut -f2)
EOF
  while IFS="$tab" read -r sid st verdict; do
    [ -n "${sid:-}" ] || continue
    [ "$verdict" = "done" ] || continue
    b=$(wtc_seg_field_values "$LEDGER" "$sid" '브랜치' | awk 'NF && $0 != "-"' | tail -1)
    case "$st" in
      완료)
        br_keep=$((br_keep + 1))
        wtc_say '브랜치 정리' "보존 · ${b:--} · 세그먼트 $sid · 사유=완료 세그먼트(머지 대상 아님)"
        continue ;;
      머지됨) : ;;
      *) continue ;;
    esac
    reason=""
    if [ -z "$b" ]; then reason='브랜치 미상'; fi
    if [ -z "$reason" ]; then
      case "-${b##*/}-" in *"-${RUN_ID}-"*) : ;; *) reason='다른 런 브랜치' ;; esac
    fi
    if [ -z "$reason" ]; then
      kept=$(printf '%s' "$pairs" | awk -F '\t' -v s="$sid" '$2 == s { print $1 }' | while IFS= read -r w; do
        printf '%s\n' "$outcomes" | awk -F '\t' -v w="$w" '$1 == w { o = $2 } END { if (o == "" || o == "P") print "P" }'
      done | awk 'NR == 1')
      [ -z "$kept" ] || reason='워크트리 보존'
    fi
    if [ -z "$reason" ] && [ -n "$afail" ]; then reason="판정 읽기 실패(철거 뒤 워크트리 목록 git 종료 $afail)"; fi
    if [ -z "$reason" ]; then
      case "${nl}${after}${nl}" in *"${nl}branch refs/heads/${b}${nl}"*) reason='다른 워크트리에 체크아웃됨' ;; esac
    fi
    root=""; lsha=""
    if [ -z "$reason" ]; then
      while IFS="$tab" read -r a eroot; do
        [ -n "${eroot:-}" ] || continue
        lsha=$( cd "$eroot" && git rev-parse --verify --quiet "refs/heads/$b" 2>/dev/null ) || lsha=""
        if [ -n "$lsha" ]; then root="$eroot"; break; fi
      done <<EOF
$roots
EOF
      [ -n "$root" ] || continue
      rc=0; out=$( cd "$root" && GIT_TERMINAL_PROMPT=0 git ls-remote --exit-code --heads origin "refs/heads/$b" </dev/null 2>/dev/null ) || rc=$?
      if [ "$rc" -eq 2 ]; then reason='원격 없음'
      elif [ "$rc" -ne 0 ]; then reason='원격 조회 실패'
      else
        rsha=$(printf '%s\n' "$out" | awk -F '\t' -v r="refs/heads/$b" '$2 == r { print $1 }')
        if [ "$(printf '%s' "$rsha" | awk 'NF' | wc -l | tr -d ' ')" != "1" ]; then reason='원격 조회 실패'; fi
      fi
    fi
    if [ -z "$reason" ]; then
      if ! ( cd "$root" && git cat-file -e "${rsha}^{commit}" ) >/dev/null 2>&1; then
        reason='원격과 다른 커밋'
      else
        rc=0; ( cd "$root" && git merge-base --is-ancestor "$lsha" "$rsha" ) >/dev/null 2>&1 || rc=$?
        case "$rc" in
          0) : ;;
          1) reason='원격과 다른 커밋' ;;
          *) reason="판정 읽기 실패(원격 조상 git 종료 $rc)" ;;
        esac
      fi
    fi
    if [ -z "$reason" ]; then
      rc=0; ( cd "$root" && git branch -d "$b" ) >/dev/null 2>&1 || rc=$?
      if [ "$rc" -eq 0 ]; then
        br_del=$((br_del + 1))
        wtc_say '브랜치 정리' "삭제 · $b · 세그먼트 $sid · origin 같은 커밋 $(printf '%s' "$rsha" | cut -c1-12)"
        continue
      fi
      reason="비강제 삭제 거부(git 종료 $rc)"
    fi
    br_keep=$((br_keep + 1))
    wtc_say '브랜치 정리' "보존 · ${b:--} · 세그먼트 $sid · 사유=$reason"
  done <<EOF
$states
EOF

  wtc_say '워크트리 정리' "런 완주($mode) — 워크트리 제거 $wt_rm · 보존 $wt_keep · 브랜치 삭제 $br_del · 보존 $br_keep"
  return 0
}

wtc_worktree_verdict() {
  # wtc_worktree_verdict <W> <W normalized> <segs> <states> <root> <flags> —
  # the first reason to keep an owned worktree, or nothing to remove it.
  local w="$1" pn="$2" segs="$3" states="$4" root="$5" flags="$6"
  local dir others l rid hits sids sid park="" open="" rc out sha n tab=$'\t'
  dir=$(dirname "${LEDGER:-.}")
  # 1. Another run's ledger names it for a parked or open segment.
  others=""
  for l in "$dir"/*.md; do
    [ -f "$l" ] || continue
    case "$(basename "$l")" in "$(basename "$LEDGER")") continue ;; esac
    case "$(basename "$l")" in
      [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f].md) : ;;
      *) continue ;;
    esac
    hits=$( { grep -E '^- `segment` ' "$l" 2>/dev/null || true; } | awk -v a="워크트리=$w" -v b="워크트리=$pn" '
      { n = split($0, f, / \| /); hit = 0; id = ""
        for (i = 2; i <= n; i++) { if (f[i] == a || f[i] == b) hit = 1; if (index(f[i], "id=") == 1) id = substr(f[i], 4) }
        if (hit && id != "") print id }' | awk '!seen[$0]++')
    [ -n "$hits" ] || continue
    rid=$(basename "$l" .md)
    sids=$(cc_segment_states "$l" 2>/dev/null || true)
    while IFS= read -r sid; do
      [ -n "$sid" ] || continue
      if printf '%s\n' "$sids" | awk -F '\t' -v s="$sid" '$1 == s && ($2 == "park" || $3 == "open") { f = 1 } END { exit f ? 0 : 1 }'; then
        others="${others:+$others,}$rid:$sid"
      fi
    done <<EOF
$hits
EOF
  done
  if [ -n "$others" ]; then printf '다른 런 원장이 지목(%s)' "$(wtc_brief "$others")"; return 0; fi
  # 2. Mixed states among this run's segments that named it.
  while IFS= read -r sid; do
    [ -n "$sid" ] || continue
    l=$(printf '%s\n' "$states" | awk -F '\t' -v s="$sid" '$1 == s { print $2 "\t" $3; exit }')
    case "$l" in
      "park${tab}done") park="${park:+$park,}$sid" ;;
      *"${tab}open") open="${open:+$open,}$sid" ;;
    esac
  done <<EOF
$(printf '%s' "$segs" | tr ',' '\n')
EOF
  if [ -n "$park" ]; then printf 'park 세그먼트 공유(%s)' "$(wtc_brief "$park")"; return 0; fi
  if [ -n "$open" ]; then printf '비종단 세그먼트(%s)' "$(wtc_brief "$open")"; return 0; fi
  # 3. Locked.
  case " $flags " in *" locked "*) printf '잠김'; return 0 ;; esac
  # 4. A detached HEAD no branch or remote-tracking ref contains.
  case " $flags " in
    *" detached "*)
      sha=$(printf '%s' "$flags" | tr ' ' '\n' | sed -n 's/^head=//p' | awk 'NR == 1')
      rc=0; out=$( cd "$root" && git for-each-ref --contains "$sha" refs/heads refs/remotes 2>/dev/null ) || rc=$?
      if [ "$rc" -ne 0 ]; then printf '판정 읽기 실패(브랜치 밖 커밋 git 종료 %s)' "$rc"; return 0; fi
      [ -n "$out" ] || { printf '브랜치 밖 커밋'; return 0; } ;;
  esac
  # 5. Ignored content, which a non-forced remove would delete silently.
  if [ -d "$w" ]; then
    rc=0; out=$( cd "$w" && git ls-files -o -i --exclude-standard --directory 2>/dev/null ) || rc=$?
    if [ "$rc" -ne 0 ]; then printf '판정 읽기 실패(무시된 파일 git 종료 %s)' "$rc"; return 0; fi
    n=$(printf '%s' "$out" | awk 'NF' | wc -l | tr -d ' ')
    if [ "${n:-0}" -gt 0 ]; then printf '무시된 파일(%s)' "$n"; return 0; fi
  fi
  return 0
}
