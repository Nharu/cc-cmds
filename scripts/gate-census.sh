#!/usr/bin/env bash
# Take the census of `scripts/test-gate.sh`: one record per section, and the
# expected assertion count of every shard.
#
# THE DIFFERENCE OF TWO RUNS IS THE PRIMARY INSTRUMENT, and the fixed-point walk
# is only its follow-up. The whole suite is run once, and the proposed shards are
# run once; every PASS and FAIL line is attributed to the section it ran under,
# and the two runs are compared section by section, IN ORDER. Two runs surface
# every edge the partition actually breaks — a section that silently ran less, a
# section that passed vacuously because an earlier one no longer set its world
# up — and what falls out as a by-product is the table of expected assertion
# counts per shard, which is what a timing verdict has to be gated on: a shard
# that ran less is faster, so a green median alone is biased toward "met".
#
# THE WALK IS NOT THE PRIMARY BECAUSE IT DOES NOT TERMINATE. `set -u` reports the
# FIRST unbound symbol only, so each run exposes at most one edge, and there is
# no signal that the last one has been found. Here it runs only on the sections
# the difference pointed at, in parallel (the suite isolates its own state), and
# under a per-section attempt cap. What the census promises is a bound on the
# largest component, not the whole graph.
#
# THE WALL TIME IS THE WHOLE INVOCATION — head, family prelude and `needs:`
# closure included. It is not the section's own share and nothing here pretends
# it is; the partitioner accounts for the shared cost, and the shard rows carry
# each shard's time measured whole.
#
# A SECTION THAT COULD NOT BE RUN STILL GETS A ROW. A missing row is a section
# that drops out of the matrix without a word, which is the failure this whole
# machine exists to prevent; the write refuses outright when the rows and
# `--list` are not the same set.
#
# THE INSTRUMENT MUST NOT MOVE WHAT IT MEASURES. Attribution needs a line per
# section boundary, so the full and shard runs use an instrumented COPY: one
# owner line after `set -uo pipefail`, and one stamp after each section marker.
# The stamp prints only in the suite's own process — a nested run that a section
# starts inherits the owner and has a different `$$` — and it goes after the
# marker line, so boundaries, marker ownership and cut ranges are untouched. The
# full run's PASS/FAIL sequence and totals are then compared with a baseline run
# of the uninstrumented suite, and a difference stops the census before it writes.
#
# Usage:
#   bash scripts/gate-census.sh [--repo P] [--out F] [--work D] [--jobs J]
#       [--shards N] [--timeout S] [--full-timeout S] [--max-iter M]
#       [--baseline LOG] [--phase solo|diff|iterate|write]
#   bash scripts/gate-census.sh --self-test
#
# Phases run in order solo → diff → iterate → write. The work directory keeps a
# completion mark per phase and every suite invocation's transcript, so calling
# again with the same `--work` resumes where a killed session stopped.
#
# Exit codes: 0 written (differences found are a report, not a failure),
# 2 usage, 3 a check failed and nothing was written — the instrument changed the
# suite, the rows are not the `--list` set, the partition would not settle, or
# the suite could not be listed.

set -uo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
SHARD="$script_dir/gate-shard.sh"

census_usage() {
  printf 'gate-census: 사용법 — [--repo P] [--out F] [--work D] [--jobs J] [--shards N] [--timeout S] [--full-timeout S] [--max-iter M] [--baseline LOG] [--phase solo|diff|iterate|write] | --self-test\n' >&2
  exit 2
}

census_log() { printf 'gate-census: %s\n' "$*" >&2; }

# The normaliser is the design's, verbatim. The sha rule demands at least one
# `a-f`: without it a pure digit run is erased too, and this suite's labels carry
# counts such as `(352바이트)` — a changed count would normalise away and the
# diff built to catch a false green would produce one.
census_norm() {
  perl -pe '
    s{/(?:private/)?(?:var|tmp)/[^ )"]+}{<TMP>}g;
    s{\d{4}-\d{2}-\d{2}T[\d:.+Z-]+}{<TS>}g;
    s{\b(?=[0-9a-f]{7,64}\b)(?=[0-9a-f]*[a-f])[0-9a-f]{7,64}\b}{<SHA>}g;
    s{\bpid[= ]\d+}{pid=<PID>}g;
  '
}

census_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

census_sha256() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 | awk '{ print $1 }'; else sha256sum | awk '{ print $1 }'; fi
}

# --- running the suite ---------------------------------------------------------

census_kill_tree() {
  local p="$1" c
  for c in $(ps -A -o pid= -o ppid= 2>/dev/null | awk -v p="$p" '$2 == p { print $1 }'); do
    census_kill_tree "$c"
  done
  kill -TERM "$p" 2>/dev/null || true
}

# One suite invocation, isolated: its own XDG_STATE_HOME and TMPDIR so siblings
# never clean each other's scratch, stdin closed (an empty `$LEDGER` turns a grep
# into a read of stdin that never returns), and none of the variables through
# which a caller's pipeline or selector state could leak into the fixtures.
census_run() {
  local dir="$1" suite="$2" limit="$3"
  shift 3
  local start end pid watcher rc
  rm -rf "$dir"
  mkdir -p "$dir/state" "$dir/tmp"
  printf '%s\n' "$*" > "$dir/args"
  start=$(date +%s)
  (
    unset CC_TEST_GATE_ORACLE_INNER CC_TEST_GATE_REPO_ROOT CC_GATE_CENSUS_OWNER
    for v in $(compgen -e); do
      case "$v" in CC_PIPELINE_*) unset "$v" ;; esac
    done
    if [ -n "${CENSUS_REPO_ROOT:-}" ]; then
      CC_TEST_GATE_REPO_ROOT="$CENSUS_REPO_ROOT"; export CC_TEST_GATE_REPO_ROOT
    fi
    XDG_STATE_HOME="$dir/state"; TMPDIR="$dir/tmp"
    export XDG_STATE_HOME TMPDIR
    exec bash "$suite" "$@"
  ) > "$dir/out" 2> "$dir/err" < /dev/null &
  pid=$!
  ( sleep "$limit"; : > "$dir/timeout"; census_kill_tree "$pid" ) > /dev/null 2>&1 &
  watcher=$!
  wait "$pid"; rc=$?
  end=$(date +%s)
  { census_kill_tree "$watcher"; wait "$watcher"; } > /dev/null 2>&1
  printf '%s\n' "$rc" > "$dir/rc"
  printf '%s\n' "$((end - start))" > "$dir/wall"
  rm -rf "$dir/state" "$dir/tmp"
}

# Resumable form: a transcript whose argv matches is not produced again.
census_run_once() {
  local dir="$1"
  shift
  local suite="$1" limit="$2"
  shift 2
  if [ -f "$dir/rc" ] && [ -f "$dir/args" ] && [ "$(cat "$dir/args")" = "$*" ]; then
    return 0
  fi
  census_run "$dir" "$suite" "$limit" "$@"
}

POOL=""
census_pool_reap() {
  local live="" p
  for p in $POOL; do
    if kill -0 "$p" 2>/dev/null; then live="$live $p"; else wait "$p" 2>/dev/null || true; fi
  done
  POOL="$live"
}
census_pool_count() { set -- $POOL; printf '%s\n' "$#"; }
census_pool_slot() {
  census_pool_reap
  while [ "$(census_pool_count)" -ge "$JOBS" ]; do sleep 1; census_pool_reap; done
}
census_pool_drain() {
  census_pool_reap
  while [ -n "${POOL// /}" ]; do sleep 1; census_pool_reap; done
}

# --- reading a transcript -------------------------------------------------------

# `NAME kind` of the first crash symbol on stderr, kind `var` or `cmd`. The
# oracle's own lines and FAIL lines are excluded — a FAIL diagnostic may quote a
# captured `unbound variable` that is not this run's abort. Both message
# catalogues are read: the wrapper pins LC_MESSAGES=C, but a transcript taken
# without it speaks the host's language.
census_symbol() {
  grep -Ev '^(FAIL|test-gate):' "$1" 2>/dev/null \
    | sed -n -E \
        -e 's/^.*: ([A-Za-z_][A-Za-z0-9_]*): (unbound variable|바인딩 해제한 변수)$/\1 var/p' \
        -e 's/^.*: ([A-Za-z_][A-Za-z0-9_]*): (command not found|명령을 찾을 수 없음)$/\1 cmd/p' \
    | awk 'NR == 1'
}

# One eight-field record from a transcript directory.
#
#   blocked   no verdict line, the selector refused (rc 2), the catalogue probe
#             failed (rc 6), or the time limit killed it — nothing was measured
#   crash     no totals line, or the oracle itself says crash
#   fail      a failed assertion, FAIL lines that disagree with the totals, or
#             noise the oracle enforces
#   ok        everything else
census_record() {
  local dir="$1" id="$2" grp="$3" needs="$4"
  local rc wall verdict tot passed failed npass nfail status sym symk
  rc=$(cat "$dir/rc" 2>/dev/null || true)
  wall=$(cat "$dir/wall" 2>/dev/null || true)
  case "$wall" in ''|*[!0-9]*) wall="-" ;; esac
  verdict=$(sed -n 's/^test-gate: 판정=\([a-z]*\).*$/\1/p' "$dir/err" 2>/dev/null | awk 'END { print }')
  tot=$(grep -E '^test-gate: [0-9]+ passed, [0-9]+ failed$' "$dir/out" 2>/dev/null | awk 'END { print }')
  npass=$(grep -c '^PASS:' "$dir/out" 2>/dev/null || true); npass=${npass:-0}
  nfail=$(grep -c '^FAIL:' "$dir/err" 2>/dev/null || true); nfail=${nfail:-0}
  symk=$(census_symbol "$dir/err")
  sym=${symk%% *}
  passed="-"; failed="-"
  if [ -f "$dir/timeout" ]; then
    status="blocked"; sym="timeout"
  elif [ "$rc" = "2" ]; then
    status="blocked"; sym="refused"
  elif [ "$rc" = "6" ] || [ "$verdict" = "probe" ]; then
    status="blocked"; sym="probe"
  elif [ -z "$verdict" ]; then
    status="blocked"; sym="no-verdict"
  elif [ -z "$tot" ] || [ "$verdict" = "crash" ]; then
    status="crash"
    if [ -n "$tot" ]; then
      passed=$(printf '%s\n' "$tot" | sed -E 's/^test-gate: ([0-9]+) passed, ([0-9]+) failed$/\1/')
      failed=$(printf '%s\n' "$tot" | sed -E 's/^test-gate: ([0-9]+) passed, ([0-9]+) failed$/\2/')
    else
      passed="$npass"; failed="$nfail"
    fi
    [ -n "$sym" ] || sym="?"
  else
    passed=$(printf '%s\n' "$tot" | sed -E 's/^test-gate: ([0-9]+) passed, ([0-9]+) failed$/\1/')
    failed=$(printf '%s\n' "$tot" | sed -E 's/^test-gate: ([0-9]+) passed, ([0-9]+) failed$/\2/')
    case "$verdict" in
      noise|swallowed|fail) status="fail" ;;
      *)
        if [ "$failed" != "0" ] || [ "$nfail" != "$failed" ]; then status="fail"; else status="ok"; fi ;;
    esac
    [ -n "$sym" ] || sym="-"
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "${grp:--}" "$status" "$wall" "$passed" "$failed" "${needs:--}" "$sym"
}

# --- the instrumented copy -------------------------------------------------------

census_instrument() {
  local src="$1" dst="$2" n_mark n_stamp n_own
  awk -v sq="'" '
    { print }
    !own && $0 == "set -uo pipefail" {
      print "if [ -n \"${CC_TEST_GATE_ORACLE_INNER:-}\" ] && [ -z \"${CC_GATE_CENSUS_OWNER:-}\" ]; then CC_GATE_CENSUS_OWNER=$$; export CC_GATE_CENSUS_OWNER; fi"
      own = 1
      next
    }
    /^# --- section: / {
      id = $0
      sub(/^# --- section:[ \t]*/, "", id); sub(/[ \t]*\|.*$/, "", id); sub(/[ \t]*---[ \t]*$/, "", id)
      print "if [ \"${CC_GATE_CENSUS_OWNER:-}\" = \"$$\" ]; then printf " sq "CENSUS: %s\\n" sq " " sq id sq "; printf " sq "CENSUS: %s\\n" sq " " sq id sq " >&2; fi"
    }
  ' "$src" > "$dst"
  n_mark=$(grep -c '^# --- section: ' "$src" || true)
  n_stamp=$(grep -c '^if \[ "${CC_GATE_CENSUS_OWNER:-}" = "\$\$" \]; then printf' "$dst" || true)
  n_own=$(grep -c '^if \[ -n "${CC_TEST_GATE_ORACLE_INNER:-}" \] && \[ -z "${CC_GATE_CENSUS_OWNER:-}" \]' "$dst" || true)
  if [ "$n_own" != "1" ] || [ "$n_mark" != "$n_stamp" ]; then
    census_log "계측 사본을 만들지 못했습니다 — 소유자 줄 ${n_own}개(1이어야 함), 마커 ${n_mark}개 대 표지 ${n_stamp}개"
    return 3
  fi
  return 0
}

# `<id> <kind> <line>` in stream order: kind M for a stamp, P for a PASS on
# stdout, F for a FAIL on stderr. Lines before the first stamp are `(head)`.
census_attribute() {
  local out="$1" err="$2"
  awk 'BEGIN { cur = "(head)" }
       /^CENSUS: / { cur = substr($0, 9); print cur "\tM\t"; next }
       /^PASS:/    { print cur "\tP\t" $0 }' "$out" 2>/dev/null
  awk 'BEGIN { cur = "(head)" }
       /^CENSUS: / { cur = substr($0, 9); next }
       /^FAIL:/    { print cur "\tF\t" $0 }' "$err" 2>/dev/null
}

# Compare the full run with the shard runs, section by section.
#
#   same              every run of the section produced the same PASS and FAIL
#                     text in the same order as the full run
#   differs           some shard run of it did not
#   missing-in-shard  its own shard never reached it
#   missing-in-full   the full run never reached it
#
# NO SORTING, ANYWHERE. Sorting both sides turns an order check into a multiset
# check, and order is exactly what a positional coupling moves.
census_compare() {
  local ids="$1" full="$2" table="$3" shards_dir="$4" n="$5" k
  local files=""
  k=1
  while [ "$k" -le "$n" ]; do
    files="$files $shards_dir/shard-$k/attr.norm"
    k=$((k + 1))
  done
  # shellcheck disable=SC2086
  awk -F '\t' -v N="$n" -v IDS="$ids" -v TABLE="$table" -v FULL="$full" '
    BEGIN {
      while ((getline l < TABLE) > 0) { split(l, f, "\t"); m = split(f[3], a, ","); for (i = 1; i <= m; i++) own[a[i]] = f[1] }
      while ((getline l < FULL) > 0) {
        split(l, f, "\t"); t = substr(l, length(f[1]) + length(f[2]) + 3)
        if (f[2] == "M") m1[f[1]] = 1; else s1[f[1], f[2]] = s1[f[1], f[2]] t "\001"
      }
    }
    {
      k = FILENAME; sub(/\/attr\.norm$/, "", k); sub(/^.*shard-/, "", k)
      t = substr($0, length($1) + length($2) + 3)
      if ($2 == "M") ms[k, $1] = 1; else ss[k, $1, $2] = ss[k, $1, $2] t "\001"
    }
    END {
      while ((getline id < IDS) > 0) {
        if (id == "") continue
        res = "same"; det = ""
        if (!(id in m1)) { res = "missing-in-full" }
        else if (!((id in own) && ((own[id] SUBSEP id) in ms))) { res = "missing-in-shard"; det = "shard-" own[id] }
        else {
          for (k = 1; k <= N; k++) {
            if (!((k SUBSEP id) in ms)) continue
            if (ss[k, id, "P"] != s1[id, "P"] || ss[k, id, "F"] != s1[id, "F"]) { res = "differs"; det = det (det == "" ? "" : ",") "shard-" k }
          }
        }
        printf "%s\t%s\t%s\n", id, res, (det == "" ? "-" : det)
      }
    }
  ' $files < /dev/null
}

# Owner of each line of the suite, by the selector's own boundary rules: a
# section begins at a boxed rule line or a dashed title, and belongs to the
# marker on the line after its title. `(head)` above `preamble-end`, `(tail)` from
# `epilogue-begin`, `(container)` for a range no marker owns.
census_line_owners() {
  local suite="$1" lines="$2"
  awk -v LF="$lines" '
    BEGIN { while ((getline l < LF) > 0) if (l != "") want[l + 0] = 1 }
    {
      if ($0 ~ /^# --- preamble-end ---$/) pre = NR
      else if ($0 ~ /^# --- epilogue-begin ---$/) epi = NR
      else if ($0 ~ /^# --- section: /) {
        id = $0; sub(/^# --- section:[ \t]*/, "", id); sub(/[ \t]*\|.*$/, "", id); sub(/[ \t]*---[ \t]*$/, "", id)
        mk[NR] = id
      }
      else if (prev ~ /^# -+$/ && $0 ~ /^# [0-9]+[a-z]*(-[0-9]+[a-z]*)?\. /) { nb++; bound[nb] = NR - 1; tl[nb] = NR }
      else if ($0 ~ /^# --- [0-9]+[a-z]*(-[0-9]+[a-z]*)?\. /) { nb++; bound[nb] = NR; tl[nb] = NR }
      prev = $0
    }
    END {
      for (k in want) {
        # Array keys are strings; compared as strings "7" sorts after "12".
        l = k + 0
        if (pre == 0 || l <= pre) o = "(head)"
        else if (epi > 0 && l >= epi) o = "(tail)"
        else {
          b = 0
          for (i = 1; i <= nb; i++) if (bound[i] <= l) b = i
          if (b == 0 || bound[b] <= pre) o = "(container)"
          else o = ((tl[b] + 1) in mk) ? mk[tl[b] + 1] : "(container)"
        }
        print l "\t" o
      }
    }
  ' "$suite" < /dev/null
}

# Lines that bind a symbol at the start of a statement: an assignment (plain,
# exported, readonly, declared) for a variable, a definition for a command. A
# statement starts at the line's start or after `;`, `&&`, `||`, `{` or `(` —
# measured: `NCFG="$WORK/ncfg"; NTX="$NCFG/projects/proj"` binds NTX as the
# second statement of its line, and a line-anchored pattern reported the symbol
# as undefined for eleven sections. `local` is left out on purpose — it binds
# nothing a later section can read.
census_def_lines() {
  local suite="$1" sym="$2" kind="$3"
  if [ "$kind" = "cmd" ]; then
    grep -nE "(^|[;&|{(])[[:space:]]*(function[[:space:]]+)?${sym}[[:space:]]*\(\)" "$suite" | cut -d: -f1
  else
    grep -nE "(^|[;&|{(])[[:space:]]*(export[[:space:]]+|readonly[[:space:]]+|declare[[:space:]]+(-[A-Za-z]+[[:space:]]+)*)?${sym}(\[[^]]*\])?\+?=" "$suite" | cut -d: -f1
  fi
}

# --- the phases ----------------------------------------------------------------

census_banner_of() {
  # `<group>\t<needs>` of one id from the banner table
  awk -F '\t' -v id="$1" '$1 == id { print $2 "\t" $3; exit }' "$W/banners.tsv"
}

census_prepare() {
  mkdir -p "$W"
  if [ ! -f "$W/ids.txt" ]; then
    if ! ( unset CC_TEST_GATE_ORACLE_INNER CC_TEST_GATE_REPO_ROOT; bash "$SUITE" --list < /dev/null ) > "$W/list.txt" 2> "$W/list.err"; then
      census_log "절 목록을 얻지 못했습니다 ($SUITE --list)"
      sed 's/^/  /' "$W/list.err" >&2
      return 3
    fi
    awk '{ print $1 }' "$W/list.txt" > "$W/ids.tmp" && mv "$W/ids.tmp" "$W/ids.txt"
  fi
  if [ ! -s "$W/ids.txt" ]; then census_log "절 목록이 비었습니다"; return 3; fi
  awk '
    /^# --- section: / {
      id = $0; sub(/^# --- section:[ \t]*/, "", id); sub(/[ \t]*\|.*$/, "", id); sub(/[ \t]*---[ \t]*$/, "", id)
      grp = "-"
      if ($0 ~ /\|[ \t]*group:/) { grp = $0; sub(/[ \t]*---[ \t]*$/, "", grp); sub(/^.*\|[ \t]*group:[ \t]*/, "", grp); sub(/[ \t]*\|.*$/, "", grp); sub(/[ \t]+$/, "", grp); if (grp == "") grp = "-" }
      ned = "-"
      if ($0 ~ /\|[ \t]*needs:/) { ned = $0; sub(/[ \t]*---[ \t]*$/, "", ned); sub(/^.*\|[ \t]*needs:[ \t]*/, "", ned); sub(/[ \t]*\|.*$/, "", ned); gsub(/[ \t]/, "", ned); if (ned == "") ned = "-" }
      printf "%s\t%s\t%s\n", id, grp, ned
    }
  ' "$SUITE" > "$W/banners.tsv"
  return 0
}

census_header() {
  printf 'id\tgroup\tstatus\twall_seconds\tpassed\tfailed\tneeds\tcrash_symbol\n'
}

census_phase_solo() {
  local total id n=0 gn
  total=$(grep -c . "$W/ids.txt")
  census_log "단계 solo — 절 ${total}개를 --run-one 으로 따로 돌립니다 (동시 ${JOBS}, 상한 ${TIMEOUT}초)"
  mkdir -p "$W/solo"
  POOL=""
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    n=$((n + 1))
    census_pool_slot
    census_run_once "$W/solo/$id" "$SUITE" "$TIMEOUT" --run-one "$id" &
    POOL="$POOL $!"
    if [ $((n % 20)) = 0 ]; then census_log "  solo ${n}/${total} 착수"; fi
  done < "$W/ids.txt"
  census_pool_drain
  : > "$W/records.tmp"
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    gn=$(census_banner_of "$id")
    census_record "$W/solo/$id" "$id" "$(printf '%s' "$gn" | cut -f1)" "$(printf '%s' "$gn" | cut -f2)" >> "$W/records.tmp"
  done < "$W/ids.txt"
  mv "$W/records.tmp" "$W/records.tsv"
  { printf '# gate-census v1 — interim, solo records only\n'; census_header; cat "$W/records.tsv"; } > "$W/census-solo.tsv"
  : > "$W/solo.done"
  census_log "단계 solo 끝 — $(awk -F '\t' '{ c[$3]++ } END { for (s in c) printf "%s %d ", s, c[s] }' "$W/records.tsv")"
}

# Run the shards of one partition against the instrumented copy, all at once.
census_shards() {
  local tag="$1" census="$2" dir k ids
  dir="$W/diff/$tag"
  mkdir -p "$dir"
  if ! bash "$SHARD" --suite "$SUITE" --census "$census" --shards "$SHARDS" --table > "$dir/table" 2> "$dir/table.err"; then
    census_log "분할을 계산하지 못했습니다"; sed 's/^/  /' "$dir/table.err" >&2
    return 3
  fi
  census_sha256 < "$dir/table" > "$dir/digest"
  POOL=""
  k=1
  while [ "$k" -le "$SHARDS" ]; do
    ids=$(awk -F '\t' -v k="$k" '$1 == k { print $3 }' "$dir/table")
    if [ -n "$ids" ]; then
      CENSUS_REPO_ROOT="$REPO" census_run_once "$dir/shard-$k" "$W/diff/instr/test-gate.sh" "$FULL_TIMEOUT" --sections "$ids" &
      POOL="$POOL $!"
    fi
    k=$((k + 1))
  done
  census_pool_drain
  k=1
  while [ "$k" -le "$SHARDS" ]; do
    mkdir -p "$dir/shard-$k"
    census_attribute "$dir/shard-$k/out" "$dir/shard-$k/err" | census_norm > "$dir/shard-$k/attr.norm"
    k=$((k + 1))
  done
  census_compare "$W/ids.txt" "$W/diff/full/attr.norm" "$dir/table" "$dir" "$SHARDS" > "$dir/compare.tsv"
  return 0
}

census_phase_diff() {
  local rc
  census_log "단계 diff — 계측 사본의 전량 1회와 샤드 ${SHARDS}개 1회를 절별로 비교합니다"
  mkdir -p "$W/diff/instr"
  census_instrument "$SUITE" "$W/diff/instr/test-gate.sh" || return 3
  # The copy must index exactly like the original: a stamp that displaced a
  # marker would make the selector refuse, or resolve an id to a neighbour.
  ( unset CC_TEST_GATE_ORACLE_INNER CC_TEST_GATE_REPO_ROOT; CC_TEST_GATE_REPO_ROOT="$REPO" bash "$W/diff/instr/test-gate.sh" --list < /dev/null ) > "$W/diff/instr/list.txt" 2>&1
  rc=$?
  if [ "$rc" != "0" ] || ! cmp -s "$W/diff/instr/list.txt" "$W/list.txt"; then
    census_log "계측 사본의 --list 가 원본과 다릅니다 (rc=$rc) — 계측이 절 색인을 바꿨으므로 쓰지 않습니다"
    return 3
  fi

  census_log "  실행 1: 전량 (상한 ${FULL_TIMEOUT}초)"
  CENSUS_REPO_ROOT="$REPO" census_run_once "$W/diff/full" "$W/diff/instr/test-gate.sh" "$FULL_TIMEOUT"
  census_attribute "$W/diff/full/out" "$W/diff/full/err" > "$W/diff/full/attr"
  census_norm < "$W/diff/full/attr" > "$W/diff/full/attr.norm"
  census_harmless || return 3

  census_log "  실행 2: 샤드 ${SHARDS}개 동시"
  census_shards "run2" "$W/census-solo.tsv" || return 3
  printf 'run2\n' > "$W/diff/latest"
  : > "$W/diff.done"
  census_log "단계 diff 끝 — $(awk -F '\t' '{ c[$2]++ } END { for (s in c) printf "%s %d ", s, c[s] }' "$W/diff/run2/compare.tsv")"
}

# The instrument's self-check. With a baseline, the full run's PASS sequence,
# FAIL sequence and totals must equal the baseline's after normalisation, in
# order. Without one, the run must be green and every PASS it printed must be
# attributed, which at least says the stamps swallowed nothing.
#
# ONE KIND OF DIFFERENCE IS TOLERATED, AND IT IS NAMED IN THE REPORT: the same
# assertion, at the same position, with a different decimal number in its label
# — nothing else may differ, the FAIL sequence must be identical and the totals
# equal. Measured: a baseline taken from a copy under /tmp and an instrumented
# run in the worktree differed in exactly two PASS lines, one counting the base
# worktree's ancestor CLAUDE.md files (9 against 10 — the path has one more
# ancestor) and one counting the appends a deliberately racy control loses (728
# against 752 — and 741 in the run before that). Neither number is something a
# `printf` after a marker line can move, and refusing on them would make the
# census unwritable on every host whose baseline was taken anywhere else. What
# the instrument could do — drop an assertion, reorder two, break the totals —
# still fails, because those are not a number inside an otherwise equal label.
census_harmless() {
  local d="$W/diff/full" tot_a tot_b pa n_pairs n_bad
  grep '^PASS:' "$d/out" | census_norm > "$d/seq.pass"
  grep '^FAIL:' "$d/err" | census_norm > "$d/seq.fail"
  tot_a=$(grep -E '^test-gate: [0-9]+ passed, [0-9]+ failed$' "$d/out" | awk 'END { print }')
  if [ -n "$BASELINE" ]; then
    grep '^PASS:' "$BASELINE" | census_norm > "$d/base.pass"
    grep '^FAIL:' "$BASELINE" | census_norm > "$d/base.fail"
    tot_b=$(grep -E '^test-gate: [0-9]+ passed, [0-9]+ failed$' "$BASELINE" | awk 'END { print }')
    if ! diff "$d/base.pass" "$d/seq.pass" > "$d/harmless.diff" || ! diff "$d/base.fail" "$d/seq.fail" >> "$d/harmless.diff" || [ "$tot_a" != "$tot_b" ]; then
      n_pairs=""; n_bad="1"
      if [ "$tot_a" = "$tot_b" ] && cmp -s "$d/base.fail" "$d/seq.fail" \
         && [ "$(grep -c . "$d/base.pass")" = "$(grep -c . "$d/seq.pass")" ]; then
        paste -d '	' "$d/base.pass" "$d/seq.pass" \
          | awk -F '\t' '$1 != $2 { a = $1; b = $2; gsub(/[0-9]+/, "<N>", a); gsub(/[0-9]+/, "<N>", b)
                                     if (a == b) { n++; print "  기준선: " $1 > "/dev/stderr"; print "  계측본: " $2 > "/dev/stderr" } else bad++ }
                          END { printf "%d %d\n", n, bad }' 2> "$d/harmless.pairs" > "$d/harmless.count"
        n_pairs=$(cut -d ' ' -f1 "$d/harmless.count"); n_bad=$(cut -d ' ' -f2 "$d/harmless.count")
      fi
      if [ "$n_bad" != "0" ]; then
        census_log "무해성 검사 실패 — 계측된 전량 실행이 기준선과 다릅니다 (총계 「${tot_a}」 대 「${tot_b}」, 차이는 $d/harmless.diff)"
        printf '무해성: 실패 — 총계 「%s」 대 기준선 「%s」\n' "$tot_a" "$tot_b" > "$W/harmless.txt"
        return 3
      fi
      census_log "무해성 검사 통과(수치 차이 ${n_pairs}쌍) — 같은 단언의 라벨 안 수만 다르고 순서·FAIL·총계는 기준선과 같습니다"
      { printf '무해성: 통과 — 기준선과 PASS 순서·FAIL 순서·총계가 같고, 같은 자리 단언 %s쌍의 라벨 안 수만 다름 (%s)\n' "$n_pairs" "$tot_a"
        cat "$d/harmless.pairs"; } > "$W/harmless.txt"
      return 0
    fi
    printf '무해성: 통과 — 기준선과 PASS %s줄·FAIL %s줄·총계가 순서까지 같음 (%s)\n' \
      "$(grep -c . "$d/seq.pass")" "$(grep -c . "$d/seq.fail")" "$tot_a" > "$W/harmless.txt"
  else
    pa=$(awk -F '\t' '$2 == "P"' "$d/attr" | grep -c . || true)
    if ! grep -q '^test-gate: 판정=pass' "$d/err" || [ "$tot_a" != "test-gate: $pa passed, 0 failed" ]; then
      census_log "무해성 검사 실패 — 기준선 없이: 판정=pass 가 아니거나 귀속된 PASS ${pa}개가 총계 「${tot_a}」 와 다릅니다"
      printf '무해성: 실패 — 기준선 없음, 총계 「%s」 귀속 PASS %s\n' "$tot_a" "$pa" > "$W/harmless.txt"
      return 3
    fi
    printf '무해성: 기준선 없이 약한 검사만 통과 — 판정=pass, 귀속 PASS %s = 총계\n' "$pa" > "$W/harmless.txt"
  fi
  return 0
}

# The walk for one section: start from its solo run, and while the run names a
# crash symbol, find the one section that binds it, add it, run again.
census_iterate_one() {
  local x="$1" d="$W/iterate/$1" set="$1" seen=" " n=0 confirmed="" reason="" status run symk sym kind owners owner cnt newk
  mkdir -p "$d"
  run="$W/solo/$x"
  status=$(awk -F '\t' -v id="$x" '$1 == id { print $3; exit }' "$W/records.tsv")
  while :; do
    if [ "$status" = "blocked" ]; then reason="막힘"; break; fi
    symk=$(census_symbol "$run/err")
    if [ -z "$symk" ]; then
      if [ "$status" = "ok" ]; then reason="수렴"; else reason="심볼 없는 $status"; fi
      break
    fi
    sym=${symk%% *}; kind=${symk##* }
    case "$seen" in *" $sym "*) reason="같은 심볼 반복: $sym"; break ;; esac
    seen="$seen$sym "
    census_def_lines "$SUITE" "$sym" "$kind" > "$d/def-$sym"
    if [ ! -s "$d/def-$sym" ]; then reason="정의 없음: $sym"; break; fi
    owners=$(census_line_owners "$SUITE" "$d/def-$sym" | cut -f2 | LC_ALL=C sort -u)
    cnt=$(printf '%s\n' "$owners" | grep -c .)
    case "
$owners
" in
      *"
(head)
"*) reason="머리 정의: $sym"; break ;;
    esac
    if [ "$cnt" != "1" ]; then reason="모호: $sym → $(printf '%s' "$owners" | tr '\n' ' ')"; break; fi
    owner="$owners"
    case "$owner" in '('*) reason="귀속 불가: $sym → $owner"; break ;; esac
    case ",$set," in *",$owner,"*) reason="생산자 이미 포함: $sym ← $owner"; break ;; esac
    n=$((n + 1))
    if [ "$n" -gt "$MAX_ITER" ]; then reason="상한 도달(${MAX_ITER})"; break; fi
    set="$set,$owner"
    run="$d/iter-$n"
    census_run_once "$run" "$SUITE" "$TIMEOUT" --sections "$set"
    status=$(census_record "$run" "$x" - - | cut -f3)
    newk=$(census_symbol "$run/err")
    if [ "${newk%% *}" != "$sym" ]; then confirmed="$confirmed${confirmed:+,}$owner"; fi
  done
  printf '%s\t%s\t%s\t%s\n' "$x" "${confirmed:--}" "$reason" "$set" > "$d/result"
}

census_phase_iterate() {
  local latest x
  latest=$(cat "$W/diff/latest")
  awk -F '\t' '$2 != "same" { print $1 }' "$W/diff/$latest/compare.tsv" > "$W/flagged.txt"
  census_log "단계 iterate — 차분이 지목한 절 $(grep -c . "$W/flagged.txt" || true)개 (동시 ${JOBS}, 절마다 시도 상한 ${MAX_ITER})"
  mkdir -p "$W/iterate"
  POOL=""
  while IFS= read -r x; do
    [ -n "$x" ] || continue
    census_pool_slot
    census_iterate_one "$x" &
    POOL="$POOL $!"
  done < "$W/flagged.txt"
  census_pool_drain
  : > "$W/iterate.tsv"
  while IFS= read -r x; do
    [ -n "$x" ] || continue
    cat "$W/iterate/$x/result" >> "$W/iterate.tsv"
  done < "$W/flagged.txt"
  : > "$W/iterate.done"
}

# The final section rows: the solo records, with every confirmed producer added
# to the consumer's `needs`. Banners are not edited — the suite is not this
# tool's to change; the added edges are proposed in the report.
census_final_rows() {
  awk -F '\t' -v OFS='\t' -v IT="$W/iterate.tsv" '
    BEGIN { while ((getline l < IT) > 0) { split(l, f, "\t"); if (f[2] != "-") add[f[1]] = f[2] } }
    {
      if ($1 in add) {
        n = ($7 == "-" ? "" : $7)
        m = split(add[$1], a, ",")
        for (i = 1; i <= m; i++) if (("," n ",") !~ ("," a[i] ",")) n = n (n == "" ? "" : ",") a[i]
        $7 = (n == "" ? "-" : n)
      }
      print
    }
  ' "$W/records.tsv"
}

census_write_tsv() {
  # <out> <ids> <rows> <shard-rows> <header lines...>
  local out="$1" ids="$2" rows="$3" srows="$4"
  shift 4
  local tmp
  if ! cmp -s <(LC_ALL=C sort -u "$ids") <(cut -f1 "$rows" | LC_ALL=C sort -u) \
     || [ "$(grep -c . "$rows")" != "$(grep -c . "$ids")" ]; then
    census_log "절 행 id 집합이 --list 집합과 다릅니다 — 쓰지 않습니다"
    return 3
  fi
  if awk -F '\t' 'NF != 8 { bad = 1 } END { exit bad ? 0 : 1 }' "$rows" "$srows"; then
    census_log "8열이 아닌 행이 있습니다 — 쓰지 않습니다"
    return 3
  fi
  tmp="$out.tmp.$$"
  { for h in "$@"; do printf '%s\n' "$h"; done; census_header; cat "$rows" "$srows"; } > "$tmp" && mv "$tmp" "$out"
}

census_phase_write() {
  local latest tries=0 digest_new digest_run k dir rec rev
  latest=$(cat "$W/diff/latest")
  census_final_rows > "$W/rows.tsv"
  { printf '# gate-census v1 — interim\n'; census_header; cat "$W/rows.tsv"; } > "$W/census-final.tsv"
  while :; do
    digest_new=$(bash "$SHARD" --suite "$SUITE" --census "$W/census-final.tsv" --shards "$SHARDS" --digest 2> "$W/write-shard.err")
    digest_run=$(cat "$W/diff/$latest/digest")
    [ "$digest_new" != "$digest_run" ] || break
    tries=$((tries + 1))
    if [ "$tries" -gt 2 ]; then
      census_log "새 needs 로 바뀐 분할이 두 번 다시 돌린 뒤에도 가라앉지 않습니다 — 쓰지 않습니다"
      return 3
    fi
    census_log "새 needs 가 분할을 바꿨습니다 — 샤드 실행을 다시 돕니다 (${tries}/2)"
    latest="rerun-$tries"
    census_shards "$latest" "$W/census-final.tsv" || return 3
    printf '%s\n' "$latest" > "$W/diff/latest"
  done
  dir="$W/diff/$latest"
  : > "$W/shard-rows.tsv"
  k=1
  while [ "$k" -le "$SHARDS" ]; do
    if [ -f "$dir/shard-$k/rc" ]; then
      rec=$(census_record "$dir/shard-$k" "@shard-$k-of-$SHARDS" "@shard" "-")
    else
      rec=$(printf '@shard-%s-of-%s\t@shard\tblocked\t-\t-\t-\t-\tempty' "$k" "$SHARDS")
    fi
    printf '%s\n' "$rec" >> "$W/shard-rows.tsv"
    k=$((k + 1))
  done
  rev=$(cd "$REPO" && git rev-parse --short HEAD 2>/dev/null || printf 'unknown')
  census_write_tsv "$OUT" "$W/ids.txt" "$W/rows.tsv" "$W/shard-rows.tsv" \
    "# gate-census v1 — generated by scripts/gate-census.sh; do not edit by hand" \
    "# source: $rev host: $(uname -sm) jobs: $JOBS generated: $(census_now)" \
    "# shard-partition: N=$SHARDS sha256=$digest_new" || return 3
  census_report "$dir" > "$W/report.txt"
  cat "$W/report.txt"
  : > "$W/write.done"
  census_log "썼습니다 — $OUT"
}

census_report() {
  local dir="$1"
  printf 'gate-census 보고서 — %s\n' "$(census_now)"
  printf '대상: %s\n' "$SUITE"
  printf '절 %s개 — %s\n' "$(grep -c . "$W/rows.tsv")" "$(awk -F '\t' '{ c[$3]++ } END { for (s in c) printf "%s %d  ", s, c[s] }' "$W/rows.tsv")"
  cat "$W/harmless.txt" 2>/dev/null
  printf '\n[단독으로 서는 절]\n'
  awk -F '\t' '$3 == "ok" { printf "%s ", $1 } END { print "" }' "$W/rows.tsv"
  printf '\n[못 서는 절과 사유] id / status / crash_symbol / passed / failed\n'
  awk -F '\t' '$3 != "ok" { printf "  %s\t%s\t%s\t%s\t%s\n", $1, $3, $8, $5, $6 }' "$W/rows.tsv"
  printf '\n[절별 시간] 호출 전체의 벽시계, 긴 순\n'
  sort -t "$(printf '\t')" -k4,4nr "$W/rows.tsv" | awk -F '\t' '{ printf "  %s\t%s\t%s\n", $1, $2, $4 }'
  printf '\n[샤드별 기대 단언 수와 벽시계] (%s)\n' "$(basename "$dir")"
  awk -F '\t' '{ printf "  %s\tstatus=%s\tpassed=%s\tfailed=%s\twall=%s\tcrash_symbol=%s\n", $1, $3, $5, $6, $4, $8 }' "$W/shard-rows.tsv"
  awk -F '\t' '{ n = split($3, a, ","); printf "  shard-%s 적재=%s 절=%d개\n", $1, $2, n }' "$dir/table"
  printf '\n[차분이 지목한 절] id / 결과 / 샤드\n'
  awk -F '\t' '$2 != "same" { printf "  %s\t%s\t%s\n", $1, $2, $3 }' "$dir/compare.tsv"
  printf '  (same %s개)\n' "$(awk -F '\t' '$2 == "same"' "$dir/compare.tsv" | grep -c . || true)"
  printf '\n[고정점 반복] id / 확인된 생산자 / 멈춘 사유 / 마지막 집합\n'
  awk -F '\t' '{ printf "  %s\t%s\t%s\t%s\n", $1, $2, $3, $4 }' "$W/iterate.tsv"
  printf '\n[제안 needs 간선] 소비 절 ← 생산 절 (배너에는 쓰지 않았음)\n'
  awk -F '\t' '$2 != "-" { n = split($2, a, ","); for (i = 1; i <= n; i++) printf "  %s ← %s\n", $1, a[i] }' "$W/iterate.tsv"
  printf '\n[예산 초과 덩어리와 분할 경고]\n'
  sed 's/^/  /' "$W/write-shard.err" 2>/dev/null
}

# --- self-test ------------------------------------------------------------------

census_self_test() {
  local passed=0 failed=0 T d got rows
  ok()  { passed=$((passed + 1)); printf 'PASS: %s\n' "$1"; }
  bad() { failed=$((failed + 1)); printf 'FAIL: %s — %s\n' "$1" "${2:-}" >&2; }
  check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got '$2', want '$3'"; fi; }
  T=$(mktemp -d "${TMPDIR:-/tmp}/gate-census-selftest.XXXXXX")

  mkcap() { # <name> <rc> <out> <err>
    d="$T/cap/$1"; mkdir -p "$d"
    printf '%s\n' "$2" > "$d/rc"; printf '7\n' > "$d/wall"
    printf '%b' "$3" > "$d/out"; printf '%b' "$4" > "$d/err"
  }
  st() { census_record "$T/cap/$1" x g - | cut -f"$2"; }

  # (a) the status map
  mkcap ok 0 'PASS: a\n\ntest-gate: 1 passed, 0 failed\n' 'test-gate: 판정=pass 범위=전량 — …\n'
  check "(a) 정상 → ok" "$(st ok 3)" "ok"
  check "(a) 정상의 passed 는 총계 값" "$(st ok 5)" "1"
  mkcap crash 1 'PASS: a\nPASS: b\n' 'x.sh: line 3: FX_LAST_PID: unbound variable\ntest-gate: 판정=crash 범위=좁힌 실행 — …\n'
  check "(a) 총계 부재 → crash" "$(st crash 3)" "crash"
  check "(a) 총계 부재의 passed 는 관측한 PASS 줄 수" "$(st crash 5)" "2"
  mkcap mism 1 'test-gate: 3 passed, 0 failed\n' 'FAIL: z — y\ntest-gate: 판정=swallowed 범위=전량 — …\n'
  check "(a) FAIL 줄과 총계 불일치 → fail" "$(st mism 3)" "fail"
  mkcap fail 1 'test-gate: 3 passed, 1 failed\n' 'FAIL: z — y\ntest-gate: 판정=fail 범위=전량 — …\n'
  check "(a) 단언 실패 → fail" "$(st fail 3)" "fail"
  mkcap noise 3 'test-gate: 3 passed, 0 failed\n' 'x.sh: line 9: foo: command not found\ntest-gate: 판정=noise 범위=전량 — …\n'
  check "(a) 강제 노이즈 → fail" "$(st noise 3)" "fail"
  mkcap refused 2 '' 'test-gate: --run-one 에 모르는 절 id 입니다: q\n'
  check "(a) rc 2 → blocked" "$(st refused 3)" "blocked"
  check "(a) rc 2 의 사유 토큰" "$(st refused 8)" "refused"
  check "(a) blocked 의 passed 는 -" "$(st refused 5)" "-"
  mkcap nov 1 'PASS: a\n' 'boom\n'
  check "(a) 판정 줄 없음 → blocked" "$(st nov 3)" "blocked"
  mkcap slow 143 'PASS: a\n' ''
  : > "$T/cap/slow/timeout"
  check "(a) 시간 초과 → blocked timeout" "$(st slow 3):$(st slow 8)" "blocked:timeout"
  if [ "$(census_record "$T/cap/ok" x g - | awk -F '\t' '{ print NF }')" = "8" ]; then ok "(a) 레코드는 8필드"; else bad "(a) 레코드는 8필드" "$(census_record "$T/cap/ok" x g -)"; fi

  # (b) the crash symbol
  check "(b) unbound variable 의 이름" "$(st crash 8)" "FX_LAST_PID"
  check "(b) command not found 의 이름" "$(st noise 8)" "foo"
  mkcap ko 1 'PASS: a\n' '/t/x.sh: 줄 4: fx_stage_live: 명령을 찾을 수 없음\ntest-gate: 판정=crash 범위=좁힌 실행 — …\n'
  check "(b) 한국어 문면도 읽는다" "$(st ko 8)" "fx_stage_live"
  mkcap nosym 1 'PASS: a\n' 'FAIL: q — x.sh: line 1: HIDDEN: unbound variable\ntest-gate: 판정=crash 범위=전량 — …\n'
  check "(b) 심볼 없는 crash 는 ? (FAIL 줄 안의 문면은 제외)" "$(st nosym 8)" "?"

  # (c) attribution
  printf 'PASS: h1\nCENSUS: a\nPASS: a1\nPASS: a2\nCENSUS: b\nPASS: b1\n' > "$T/att.out"
  printf 'FAIL: h — x\nCENSUS: a\nCENSUS: b\nFAIL: b — y\n' > "$T/att.err"
  got=$(census_attribute "$T/att.out" "$T/att.err" | awk -F '\t' '{ printf "%s/%s;", $1, $2 }')
  check "(c) 표지 귀속과 (head)" "$got" "(head)/P;a/M;a/P;a/P;b/M;b/P;(head)/F;b/F;"

  # (d) the normaliser
  got=$(printf 'PASS: 크기 (352바이트) sha 1a2b3c4d path /tmp/cc-x/y ts 2026-09-15T01:02:03Z pid=42\n' | census_norm)
  check "(d) norm 은 수를 남기고 sha·경로·시각·pid 를 지운다" "$got" "PASS: 크기 (352바이트) sha <SHA> path <TMP> ts <TS> pid=<PID>"
  got=$(printf 'PASS: 1234567\n' | census_norm)
  check "(d) a-f 없는 숫자열은 sha 가 아니다" "$got" "PASS: 1234567"

  # (e) the in-order comparison
  mkdir -p "$T/cmp/shard-1" "$T/cmp/shard-2"
  printf 'a\nb\nc\nd\n' > "$T/cmp/ids"
  printf '1\t1\ta,b\n2\t1\tc,d\n' > "$T/cmp/table"
  printf 'a\tM\t\na\tP\tPASS: 1\na\tP\tPASS: 2\nb\tM\t\nb\tP\tPASS: 3\nc\tM\t\nc\tP\tPASS: 4\nd\tM\t\n' > "$T/cmp/full"
  printf 'a\tM\t\na\tP\tPASS: 2\na\tP\tPASS: 1\nb\tM\t\nb\tP\tPASS: 3\n' > "$T/cmp/shard-1/attr.norm"
  printf 'c\tM\t\nc\tP\tPASS: 4\n' > "$T/cmp/shard-2/attr.norm"
  got=$(census_compare "$T/cmp/ids" "$T/cmp/full" "$T/cmp/table" "$T/cmp" 2 | awk -F '\t' '{ printf "%s=%s;", $1, $2 }')
  check "(e) 순서 뒤바뀜은 differs, 같은 순서는 same, 도달 못 한 절은 missing-in-shard" "$got" "a=differs;b=same;c=same;d=missing-in-shard;"

  # (f)(g) the instrumented copy on a synthetic suite
  cat > "$T/suite.sh" <<'SUITE'
#!/usr/bin/env bash
set -uo pipefail
# --- preamble-end ---
# ---------------------------------------------------------------------------
# 1. first
# --- section: 1 | group: g | covers: - | anchors: one ---
printf 'PASS: one\n'
if [ "${1:-}" != "nested" ]; then bash "$0" nested; fi
# --- 1b. dashed ---
# --- section: 1b | group: g | covers: - | anchors: two ---
printf 'PASS: two\n'
# --- epilogue-begin ---
SUITE
  census_instrument "$T/suite.sh" "$T/inst.sh"; got=$?
  check "(f) 계측이 성공한다" "$got" "0"
  got=$(awk '/^# --- section: / { m = NR } /^if \[ "\$\{CC_GATE_CENSUS_OWNER:-\}" = "\$\$" \]/ { if (NR == m + 1) ok++; else badn++ } END { printf "%d/%d", ok, badn }' "$T/inst.sh")
  check "(f) 표지 줄 수 = 마커 수, 모두 마커 바로 다음 줄" "$got" "2/0"
  got=$(awk 'prev ~ /^# -+$/ && $0 ~ /^# [0-9]+[a-z]*\. / { t = NR } /^# --- [0-9]+[a-z]*\. / { t = NR } /^# --- section: / { if (NR == t + 1) ok++ } { prev = $0 } END { print ok }' "$T/inst.sh")
  check "(f) 마커는 여전히 번호 줄 바로 다음 줄" "$got" "2"
  got=$(CC_TEST_GATE_ORACLE_INNER=1 bash "$T/inst.sh" 2>/dev/null | tr '\n' ';')
  check "(g) 표지는 스위트 자신의 프로세스에서만, 중첩 bash 에서는 찍지 않는다" "$got" "CENSUS: 1;PASS: one;PASS: one;PASS: two;CENSUS: 1b;PASS: two;"
  got=$(bash "$T/inst.sh" 2>/dev/null | grep -c '^CENSUS:' || true)
  check "(g) 래퍼 자식이 아닌 실행에서는 표지가 없다" "$got" "0"
  printf 'no set line\n# --- section: 1 | group: g ---\n' > "$T/bad-suite.sh"
  census_instrument "$T/bad-suite.sh" "$T/bad-inst.sh" 2>/dev/null; got=$?
  check "(f) 소유자 줄을 넣을 자리가 없으면 계측을 거부한다" "$got" "3"

  # the harmlessness check against a baseline
  W="$T/hw"; mkdir -p "$W/diff/full"
  printf 'PASS: a (9개)\nPASS: b\n\ntest-gate: 2 passed, 0 failed\n' > "$W/diff/full/out"
  printf 'test-gate: 판정=pass 범위=전량 — …\n' > "$W/diff/full/err"
  printf 'PASS: a (10개)\nPASS: b\ntest-gate: 2 passed, 0 failed\n' > "$T/base1.log"
  BASELINE="$T/base1.log"; census_harmless 2>/dev/null; got=$?
  check "무해성: 같은 자리 단언의 라벨 안 수만 다르면 통과하고 보고한다" "$got:$(grep -c '기준선: PASS: a (10개)' "$W/harmless.txt")" "0:1"
  printf 'PASS: a (9개)\nPASS: c\ntest-gate: 2 passed, 0 failed\n' > "$T/base2.log"
  BASELINE="$T/base2.log"; census_harmless 2>/dev/null; got=$?
  check "무해성: 라벨 문면이 다르면 실패" "$got" "3"
  printf 'PASS: b\nPASS: a (9개)\ntest-gate: 2 passed, 0 failed\n' > "$T/base3.log"
  BASELINE="$T/base3.log"; census_harmless 2>/dev/null; got=$?
  check "무해성: 순서가 다르면 실패 (정렬하지 않는다)" "$got" "3"
  printf 'PASS: a (9개)\nPASS: b\nPASS: c\ntest-gate: 3 passed, 0 failed\n' > "$T/base4.log"
  BASELINE="$T/base4.log"; census_harmless 2>/dev/null; got=$?
  check "무해성: 단언이 빠지면 실패" "$got" "3"
  BASELINE=""; W=""

  # definition lines, for the walk
  printf 'A=1\nB="$A"; NTX="$B/x"; mkdir -p "$NTX"\n  export C=2\nlocal NTX=3\nfoo "$NTX=4"\nD=$NTX\ncmd() { :; }\nx && bar() { :; }\n' > "$T/defs.sh"
  got=$(census_def_lines "$T/defs.sh" NTX var | tr '\n' ',')
  check "정의 줄: 문장 시작의 대입만, 줄 가운데 두 번째 문장도 잡고 local·인용 안은 제외" "$got" "2,"
  got=$(census_def_lines "$T/defs.sh" C var | tr '\n' ',')
  check "정의 줄: export 대입" "$got" "3,"
  got=$(census_def_lines "$T/defs.sh" bar cmd | tr '\n' ',')
  check "정의 줄: && 뒤의 함수 정의" "$got" "8,"

  # line owners, for the walk
  printf '3\n7\n11\n' > "$T/lines"
  got=$(census_line_owners "$T/suite.sh" "$T/lines" | LC_ALL=C sort -n | awk -F '\t' '{ printf "%s=%s;", $1, $2 }')
  check "정의 줄의 소유 절 — 머리 / 박스 절 / 대시 절" "$got" "3=(head);7=1;11=1b;"

  # (h) the TSV
  printf 'a\nb\n' > "$T/ids"
  printf 'a\tg\tok\t3\t1\t0\t-\t-\nb\tg\tcrash\t4\t0\t0\t-\t?\n' > "$T/rows"
  printf '@shard-1-of-1\t@shard\tok\t9\t1\t0\t-\t-\n' > "$T/srows"
  census_write_tsv "$T/out.tsv" "$T/ids" "$T/rows" "$T/srows" "# gate-census v1 — test" "# shard-partition: N=1 sha256=x" 2>/dev/null; got=$?
  check "(h) 집합이 같으면 쓴다" "$got" "0"
  got=$(awk -F '\t' '!/^#/ { print NF }' "$T/out.tsv" | LC_ALL=C sort -u | tr '\n' ' ')
  check "(h) 헤더와 모든 행이 8열" "$got" "8 "
  got=$(grep -c '^id	group	status	wall_seconds	passed	failed	needs	crash_symbol$' "$T/out.tsv")
  check "(h) 헤더 문면" "$got" "1"
  got=$(grep -c '^@shard-1-of-1	@shard	' "$T/out.tsv")
  check "(h) @shard 행" "$got" "1"
  printf 'a\nb\nc\n' > "$T/ids3"
  census_write_tsv "$T/out3.tsv" "$T/ids3" "$T/rows" "$T/srows" "# x" 2>/dev/null; got=$?
  if [ "$got" = "3" ] && [ ! -e "$T/out3.tsv" ]; then ok "(h) --list 집합과 다르면 쓰지 않는다"; else bad "(h) --list 집합과 다르면 쓰지 않는다" "rc=$got"; fi

  rm -rf "$T"
  printf 'gate-census self-test: %d passed, %d failed\n' "$passed" "$failed"
  if [ "$passed" -lt 40 ]; then
    printf 'gate-census self-test: 통과 수 %d 가 하한 40 에 못 미칩니다\n' "$passed" >&2
    return 1
  fi
  [ "$failed" = "0" ]
}

# --- main ------------------------------------------------------------------------

REPO=$(cd "$script_dir/.." && pwd)
OUT=""
W=""
JOBS=4
SHARDS=4
TIMEOUT=900
FULL_TIMEOUT=7200
MAX_ITER=6
BASELINE=""
PHASE=""
SELFTEST=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo)         [ "$#" -ge 2 ] || census_usage; REPO="$2"; shift 2 ;;
    --out)          [ "$#" -ge 2 ] || census_usage; OUT="$2"; shift 2 ;;
    --work)         [ "$#" -ge 2 ] || census_usage; W="$2"; shift 2 ;;
    --jobs)         [ "$#" -ge 2 ] || census_usage; JOBS="$2"; shift 2 ;;
    --shards)       [ "$#" -ge 2 ] || census_usage; SHARDS="$2"; shift 2 ;;
    --timeout)      [ "$#" -ge 2 ] || census_usage; TIMEOUT="$2"; shift 2 ;;
    --full-timeout) [ "$#" -ge 2 ] || census_usage; FULL_TIMEOUT="$2"; shift 2 ;;
    --max-iter)     [ "$#" -ge 2 ] || census_usage; MAX_ITER="$2"; shift 2 ;;
    --baseline)     [ "$#" -ge 2 ] || census_usage; BASELINE="$2"; shift 2 ;;
    --phase)        [ "$#" -ge 2 ] || census_usage; PHASE="$2"; shift 2 ;;
    --self-test)    SELFTEST=1; shift ;;
    *) printf 'gate-census: 모르는 인자입니다: %s\n' "$1" >&2; census_usage ;;
  esac
done

if [ "$SELFTEST" = "1" ]; then
  census_self_test
  exit $?
fi

for v in "$JOBS" "$SHARDS" "$TIMEOUT" "$FULL_TIMEOUT" "$MAX_ITER"; do
  case "$v" in ''|*[!0-9]*|0) census_usage ;; esac
done
case "$PHASE" in ''|solo|diff|iterate|write) ;; *) census_usage ;; esac
REPO=$(cd "$REPO" 2>/dev/null && pwd) || { census_log "--repo 가 디렉터리가 아닙니다"; exit 2; }
SUITE="$REPO/scripts/test-gate.sh"
[ -f "$SUITE" ] || { census_log "스위트가 없습니다: $SUITE"; exit 2; }
[ -n "$OUT" ] || OUT="$REPO/scripts/gate-census.tsv"
if [ -n "$BASELINE" ] && [ ! -f "$BASELINE" ]; then census_log "기준선 로그가 없습니다: $BASELINE"; exit 2; fi
[ -n "$W" ] || W=$(mktemp -d "${TMPDIR:-/tmp}/gate-census-work.XXXXXX")
command -v perl > /dev/null 2>&1 || { census_log "perl 이 필요합니다 (정규화)"; exit 2; }
census_log "작업 디렉터리: $W"

census_prepare || exit 3

census_want() {
  # run the phase if it was asked for by name, or if no phase was named and it
  # has not completed yet
  if [ -n "$PHASE" ]; then [ "$PHASE" = "$1" ]; else [ ! -f "$W/$1.done" ]; fi
}
census_need() {
  [ -f "$W/$1.done" ] || { census_log "단계 $1 가 끝나지 않았습니다 — 먼저 돌리세요"; exit 3; }
}

if census_want solo; then census_phase_solo; fi
if [ -z "$PHASE" ] || [ "$PHASE" != "solo" ]; then
  if census_want diff; then census_need solo; census_phase_diff || exit 3; fi
fi
if [ -z "$PHASE" ] || [ "$PHASE" = "iterate" ] || [ "$PHASE" = "write" ]; then
  if census_want iterate; then census_need diff; census_phase_iterate; fi
fi
if [ -z "$PHASE" ] || [ "$PHASE" = "write" ]; then
  census_need iterate
  census_phase_write || exit 3
fi
exit 0
