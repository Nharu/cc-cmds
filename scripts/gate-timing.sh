#!/usr/bin/env bash
# Turn the boundary markers of the gate shards into the per-section times the
# next partition is weighed with, and report how even this run actually was.
#
# A SHARD'S MARKER FILE IS A TIME LINE, NOT A TABLE. `make gate-shard` writes
# `@start` before it asks for its ids and `@end` after the suite returns, and
# the selector writes one `<id><TAB><epoch>` line in front of every section,
# every prelude it inserts (`@pre-<group>`) and the epilogue (`@epilogue`). A
# section's time is the interval from its own line to the next line of the same
# file, so the last section of a cut ends at `@epilogue`. A section whose line
# is the last one of its file was running when the shard died: it was NOT
# measured, and it keeps the value the source file gave it — a guess dressed as
# a measurement would be worse than the old value. The epoch is whatever the
# runner's bash printed: `EPOCHREALTIME` with a point or, under some locales, a
# comma, or whole seconds from `date +%s`; all three are read.
#
# THE HEAD AND THE ISOLATION MARKERS. The cut writes `@head` once, just before
# its first prelude or section marker, so `@start`→`@head` is the head time: the
# suite's preamble every process pays once. It is weighed like a prelude. A
# marker whose id begins with `@iso:` is isolation work — a section laid over a
# row it does not belong to, the prelude only such a section pulled in, or any
# marker of a solo cut, which runs after the row's `@end` — and its interval is
# never weighed. A file without `@head` (an older run) simply has no head row.
#
# THE NEW FILE IS THE WHOLE LIST, AND ONLY THE LIST. Every id of `--list` that
# this run measured takes the new value; every other id the source carried is
# taken over with the run id that measured it; an id the source carried that
# `--list` no longer has is dropped, so a removed section does not weigh the
# median forever. A prelude takes the mean over the shards that ran it, and an
# unmeasured prelude is taken over the same way; `@head` is weighed the same. A merged value is this run's
# latest one: the file a master push uploads says which run measured each row.
#
# THE PLAN IS WEIGHED WITH A MEDIAN OF RUNS, NOT WITH ONE RUN. A section's time
# moves from run to run on the same code, and one heavy run taken as the source
# skews the next partition by exactly that much. `median` reads the timing files
# of the latest master runs (up to three, newest first) and gives every id the
# median of the values it has: the middle one of three, the mean of two rounded
# up, the one value of one. `@pre-<group>` and `@head` rows follow the same rule. The `run`
# column lists the runs whose rows went into the value.
#
# Usage:
#   bash scripts/gate-timing.sh merge --list F --run ID --sha SHA --out F
#                                     [--source F] SHARD_FILE...
#   bash scripts/gate-timing.sh median --out F FILE...
#       one to three timing files, newest first; section rows in the order they
#       first appear, then the prelude rows sorted by id
#   bash scripts/gate-timing.sh report --table F --dir D
#       reads D/timing-<K>.tsv for each row K of the partition table, writes a
#       Markdown table to $GITHUB_STEP_SUMMARY (stdout when unset), warns past a
#       max/median of 1.5 and prints the sum of the shard times in seconds on
#       stdout, alone on its last line. A row's time leaves out its `@iso:`
#       intervals; the isolation time is written on a line of its own, and an
#       isolation-only row (empty third column, ids in column 4 or 5) is on that
#       line only — not in the table, the count, the warning or the sum. The
#       isolation sum is printed on stdout just before the last line
#   bash scripts/gate-timing.sh rows --table F --dir D [--slots S]
#       the run-row check: the rows of the table that carry ids in their third
#       column are exactly the distinct row ids of D/result-*.tsv whose summary
#       column is a suite total line, and the isolation-only rows are exactly
#       those whose summary is `격리 전용 행`; prints the missing and the extra
#       rows and exits 1 when they differ. With --slots the table's own row ids
#       must be exactly 1..S as well — S being the regular rows and the extra
#       isolation rows together
#   bash scripts/gate-timing.sh --self-test
#
# A ROW THAT RAN IS A ROW THAT PRINTED ITS TOTAL. `make gate-shard` writes one
# `result-<K>.tsv` per lane: `<K><TAB><exit code><TAB><summary>`, the summary
# being the suite's `test-gate: <n> passed, <n> failed` line, `빈 행` for a row
# the table left empty, `격리 전용 행` for a row that ran solo or laid-over cuts
# only, or `-` when the suite printed no total. A lane that died before its
# total, or whose file never got uploaded, is a row that did not run, whatever
# its exit code said. An empty row may stay empty; nothing else may.
#
# Exit codes: 0 done, 1 the run-row check failed, 2 usage, 3 an input could not
# be read.

set -uo pipefail

timing_usage() {
  printf 'gate-timing: 사용법 — merge --list F --run ID --sha SHA --out F [--source F] <샤드 표지 파일>... / median --out F <timing 파일 1~3개> / report --table F --dir D / rows --table F --dir D [--slots S] / --self-test\n' >&2
  exit 2
}

# One awk program reads every marker file and prints `<id> <ms>` per measured
# interval, files in the order given. A file name never reaches the output: what
# matters is which interval, not which shard. The interval from `@start` to
# `@head` is the head time — the suite's own preamble before the first prelude
# or section — and is printed as `@head`; the interval after `@head` belongs to
# nobody. An interval that begins at an `@iso:` marker is isolation work (a
# solo cut, or a section laid over a row it is not part of) and is never
# printed: it must not weigh the next partition.
timing_intervals() {
  LC_ALL=C awk -F '\t' '
    FNR == 1 { havep = 0 }
    {
      t = $2; gsub(/,/, ".", t)
      if ($1 == "" || t !~ /^[0-9]+(\.[0-9]+)?$/) next
      t = t + 0
      if (havep) {
        ms = int((t - pt) * 1000 + 0.5); if (ms < 0) ms = 0
        if (pid == "@start" && $1 == "@head") print "@head\t" ms
        else if (pid !~ /^@(start|end|epilogue|head)$/ && pid !~ /^@iso:/) print pid "\t" ms
      }
      pid = $1; pt = t; havep = 1
    }
  ' "$@"
}

timing_merge() {
  local list="" run="" sha="" out="" source=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --list)   [ "$#" -ge 2 ] || timing_usage; list="$2"; shift 2 ;;
      --run)    [ "$#" -ge 2 ] || timing_usage; run="$2"; shift 2 ;;
      --sha)    [ "$#" -ge 2 ] || timing_usage; sha="$2"; shift 2 ;;
      --out)    [ "$#" -ge 2 ] || timing_usage; out="$2"; shift 2 ;;
      --source) [ "$#" -ge 2 ] || timing_usage; source="$2"; shift 2 ;;
      --) shift; break ;;
      -*) printf 'gate-timing: 모르는 인자입니다: %s\n' "$1" >&2; timing_usage ;;
      *) break ;;
    esac
  done
  [ -n "$list" ] && [ -n "$run" ] && [ -n "$sha" ] && [ -n "$out" ] || timing_usage
  if [ ! -f "$list" ]; then printf 'gate-timing: 절 목록 파일이 없습니다: %s\n' "$list" >&2; return 3; fi
  local tmp f
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/gate-timing.XXXXXX")
  : > "$tmp/shards"
  # Each file is read on its own so an interval never spans two shards. A shard
  # whose marker file never got uploaded is simply absent: its sections keep
  # the source's values.
  for f in "$@"; do
    [ -f "$f" ] || continue
    timing_intervals "$f" >> "$tmp/shards"
  done
  if [ -n "$source" ] && [ -f "$source" ]; then cp "$source" "$tmp/source"; else : > "$tmp/source"; fi
  {
    printf '# gate-timing v1 — source: %s %s generated: %s\n' "$run" "$sha" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'id\tms\trun\n'
    LC_ALL=C awk -F '\t' -v RUN="$run" -v LIST="$list" -v SRC="$tmp/source" '
      BEGIN {
        while ((getline line < LIST) > 0) {
          split(line, a, /[ \t]+/)
          if (a[1] != "" && !(a[1] in inlist)) { inlist[a[1]] = 1; ids[++nid] = a[1] }
        }
        while ((getline line < SRC) > 0) {
          if (line ~ /^#/ || line == "") continue
          n = split(line, a, "\t")
          if (a[1] == "id" || a[2] !~ /^[0-9]+$/ || a[1] ~ /^@iso:/) continue
          sv[a[1]] = a[2]; sr[a[1]] = (n >= 3 && a[3] != "") ? a[3] : "-"
          if ((a[1] ~ /^@pre-/ || a[1] == "@head") && !(a[1] in seenp)) { seenp[a[1]] = 1; pres[++np] = a[1] }
        }
      }
      {
        if ($1 ~ /^@pre-/ || $1 == "@head") {
          psum[$1] += $2; pcnt[$1]++
          if (!($1 in seenp)) { seenp[$1] = 1; pres[++np] = $1 }
        } else if (!($1 in mv)) mv[$1] = $2
      }
      END {
        for (i = 1; i <= nid; i++) {
          id = ids[i]
          if (id in mv) print id "\t" mv[id] "\t" RUN
          else if (id in sv) print id "\t" sv[id] "\t" sr[id]
        }
        # Prelude rows sorted by id, so the file does not depend on shard order.
        for (i = 2; i <= np; i++) { v = pres[i]; j = i - 1; while (j >= 1 && pres[j] > v) { pres[j + 1] = pres[j]; j-- } pres[j + 1] = v }
        for (i = 1; i <= np; i++) {
          p = pres[i]
          if (p in pcnt) print p "\t" int(psum[p] / pcnt[p] + 0.5) "\t" RUN
          else if (p in sv) print p "\t" sv[p] "\t" sr[p]
        }
      }
    ' "$tmp/shards"
  } > "$tmp/out"
  mv "$tmp/out" "$out"
  rm -rf "$tmp"
  return 0
}

timing_median() {
  local out="" f
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --out) [ "$#" -ge 2 ] || timing_usage; out="$2"; shift 2 ;;
      --) shift; break ;;
      -*) printf 'gate-timing: 모르는 인자입니다: %s\n' "$1" >&2; timing_usage ;;
      *) break ;;
    esac
  done
  [ -n "$out" ] && [ "$#" -ge 1 ] && [ "$#" -le 3 ] || timing_usage
  local files=()
  for f in "$@"; do [ -f "$f" ] && files+=("$f"); done
  if [ "${#files[@]}" -eq 0 ]; then printf 'gate-timing: 읽을 timing 파일이 없습니다: %s\n' "$*" >&2; return 3; fi
  local tmp
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/gate-timing-median.XXXXXX")
  LC_ALL=C awk -F '\t' -v NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
    FILENAME != cur { cur = FILENAME; fno++ }
    FNR == 1 {
      if ($0 ~ /^# gate-timing v1 — source: /) {
        s = $0; sub(/^# gate-timing v1 — source: /, "", s); sub(/[ \t].*$/, "", s)
        if (s != "") srcs = srcs (srcs == "" ? "" : " ") s
      }
    }
    /^#/ || $0 == "" { next }
    $1 == "id" || $2 !~ /^[0-9]+$/ { next }
    ((fno SUBSEP $1) in seen) { next }
    {
      seen[fno, $1] = 1
      if (!($1 in n)) {
        n[$1] = 0
        if ($1 ~ /^@pre-/ || $1 == "@head") pres[++np] = $1; else if ($1 !~ /^@/) ids[++nid] = $1
      }
      n[$1]++; v[$1, n[$1]] = $2 + 0
      r = ($3 != "") ? $3 : "-"
      if (!(($1 SUBSEP r) in rs)) { rs[$1, r] = 1; runs[$1] = runs[$1] (runs[$1] == "" ? "" : ",") r }
    }
    function med(id,   a, b, c, t) {
      if (n[id] == 1) return v[id, 1]
      if (n[id] == 2) return int((v[id, 1] + v[id, 2] + 1) / 2)
      a = v[id, 1]; b = v[id, 2]; c = v[id, 3]
      if (a > b) { t = a; a = b; b = t }
      if (b > c) { t = b; b = c; c = t }
      if (a > b) { t = a; a = b; b = t }
      return b
    }
    END {
      printf "# gate-timing v1 — source: median of %s generated: %s\n", (srcs == "" ? "-" : srcs), NOW
      print "id\tms\trun"
      for (i = 1; i <= nid; i++) print ids[i] "\t" med(ids[i]) "\t" runs[ids[i]]
      for (i = 2; i <= np; i++) { p = pres[i]; j = i - 1; while (j >= 1 && pres[j] > p) { pres[j + 1] = pres[j]; j-- } pres[j + 1] = p }
      for (i = 1; i <= np; i++) print pres[i] "\t" med(pres[i]) "\t" runs[pres[i]]
    }
  ' "${files[@]}" > "$tmp/out"
  mv "$tmp/out" "$out"
  rm -rf "$tmp"
  return 0
}

timing_report() {
  local table="" dir=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --table) [ "$#" -ge 2 ] || timing_usage; table="$2"; shift 2 ;;
      --dir)   [ "$#" -ge 2 ] || timing_usage; dir="$2"; shift 2 ;;
      *) printf 'gate-timing: 모르는 인자입니다: %s\n' "$1" >&2; timing_usage ;;
    esac
  done
  [ -n "$table" ] && [ -n "$dir" ] || timing_usage
  if [ ! -f "$table" ]; then printf 'gate-timing: 분할표가 없습니다: %s\n' "$table" >&2; return 3; fi
  local tmp k load f kind
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/gate-timing-report.XXXXXX")
  : > "$tmp/rows"
  # A row whose third column is empty but which carries laid-over or solo ids
  # runs isolation work only: it is kind I, kept out of the shard table, the
  # count, the balance warning and the sum, and appears on the isolation line
  # alone. Every other row is kind R. A row's time is `@end - @start` less the
  # `@iso:` intervals that ran before its `@end`; everything after `@end` is the
  # solos, whose `@iso:` intervals are counted as isolation time only.
  # The kind is read by awk, not by `read`: a tab is whitespace to IFS, so
  # `read` would fold an empty third column into the next one.
  LC_ALL=C awk -F '\t' '$1 != "" { print $1 "|" $2 "|" (($3 == "" && ($4 != "" || $5 != "")) ? "I" : "R") }' "$table" > "$tmp/kinds"
  while IFS='|' read -r k load kind; do
    f="$dir/timing-$k.tsv"
    if [ -f "$f" ]; then
      LC_ALL=C awk -F '\t' -v K="$k" -v L="$load" -v KIND="$kind" '
        { t = $2; gsub(/,/, ".", t); if ($1 == "" || t !~ /^[0-9]+(\.[0-9]+)?$/) next; t = t + 0
          if (havep && pid ~ /^@iso:/ && pid != "@iso:@end") {
            iso += t - pt; if (!ended) isoin += t - pt; hasiso = 1
          }
          if ($1 == "@start" && s == "") s = t
          else if ($1 == "@end" && e == "") { e = t; ended = 1 }
          else if ($1 == "@epilogue" && !ended) p = t
          pid = $1; pt = t; havep = 1 }
        END {
          d = (s != "" && e != "") ? int(e - s - isoin + 0.5) : "-"
          q = (p != "" && e != "") ? int(e - p + 0.5) : "-"
          i = hasiso ? int(iso + 0.5) : "-"
          print K "\t" L "\t" d "\t" q "\t" i "\t" KIND
        }' "$f" >> "$tmp/rows"
    else
      printf '%s\t%s\t-\t-\t-\t%s\n' "$k" "$load" "$kind" >> "$tmp/rows"
    fi
  done < "$tmp/kinds"
  LC_ALL=C awk -F '\t' '
    $6 == "I" || $5 != "-" { ni++; ik[ni] = $1; iv[ni] = $5; if ($5 != "-") isum += $5 }
    $6 == "I" { next }
    { nr++; k[nr] = $1; l[nr] = $2; d[nr] = $3; q[nr] = $4
      if ($3 != "-") { n++; v = $3 + 0; sum += v; j = n - 1; while (j >= 1 && sv[j] > v) { sv[j + 1] = sv[j]; j-- } sv[j + 1] = v } }
    END {
      print "### gate 샤드 실측 소요"
      print ""
      print "| 샤드 | 예측 적재 | 실측 소요(초) | 에필로그(초) |"
      print "| --- | --- | --- | --- |"
      for (i = 1; i <= nr; i++) print "| " k[i] " | " l[i] " | " d[i] " | " q[i] " |"
      print ""
      if (ni > 0) {
        line = ""
        for (i = 1; i <= ni; i++) line = line (i > 1 ? " · " : "") "행 " ik[i] " " iv[i] (iv[i] == "-" ? "" : "초")
        printf "격리 시간 — %s · 격리 합 %d초\n", line, isum
        print ""
      }
      print "ISUM\t" (isum + 0)
      if (n == 0) { print "실측 소요를 읽은 샤드가 없습니다."; print "SUM\t0"; exit 0 }
      mid = (n % 2) ? sv[(n + 1) / 2] : (sv[n / 2] + sv[n / 2 + 1]) / 2
      r = (mid > 0) ? sv[n] / mid : 0
      printf "샤드 %d개 실측 · 최대 %d초 · 중앙값 %s초 · 최대/중앙값 %.2f · 합 %d초\n", n, sv[n], mid, r, sum
      if (n < nr) printf "실측 소요를 읽지 못한 샤드 %d개\n", nr - n
      printf "RATIO\t%.2f\n", r
      print "SUM\t" sum
    }' "$tmp/rows" > "$tmp/report"
  sed -n '/^RATIO	/d; /^SUM	/d; /^ISUM	/d; p' "$tmp/report" >> "${GITHUB_STEP_SUMMARY:-/dev/stdout}"
  local ratio sum isum
  ratio=$(sed -n 's/^RATIO	//p' "$tmp/report")
  sum=$(sed -n 's/^SUM	//p' "$tmp/report")
  isum=$(sed -n 's/^ISUM	//p' "$tmp/report")
  if [ -n "$ratio" ] && awk -v r="$ratio" 'BEGIN { exit !(r > 1.5) }'; then
    printf '::warning::gate 샤드 실측 소요의 최대/중앙값이 %s 로 1.5 를 넘습니다 — 잡 요약의 샤드 표를 보세요\n' "$ratio"
  fi
  rm -rf "$tmp"
  printf 'gate-timing: 격리 합 %s초\n' "${isum:-0}"
  printf '%s\n' "${sum:-0}"
  return 0
}

timing_rows() {
  local table="" dir="" slots=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --table) [ "$#" -ge 2 ] || timing_usage; table="$2"; shift 2 ;;
      --dir)   [ "$#" -ge 2 ] || timing_usage; dir="$2"; shift 2 ;;
      --slots) [ "$#" -ge 2 ] || timing_usage; slots="$2"; shift 2 ;;
      *) printf 'gate-timing: 모르는 인자입니다: %s\n' "$1" >&2; timing_usage ;;
    esac
  done
  [ -n "$table" ] && [ -n "$dir" ] || timing_usage
  case "$slots" in ''|[1-9]|[1-9][0-9]|[1-9][0-9][0-9]) ;; *) timing_usage ;; esac
  if [ ! -f "$table" ]; then printf 'gate-timing: 분할표가 없습니다: %s\n' "$table" >&2; return 3; fi
  local tmp rc=0 f
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/gate-timing-rows.XXXXXX")
  # A row with ids in its third column must print the suite total. A row whose
  # third column is empty but which carries laid-over or solo ids (columns 4
  # and 5) runs no regular cut, so it has no total: its result must say
  # `격리 전용 행` instead. A row with none of the three is empty.
  awk -F '\t' '$3 != "" { print $1 }' "$table" | LC_ALL=C sort -u > "$tmp/want"
  awk -F '\t' '$3 == "" && ($4 != "" || $5 != "") { print $1 }' "$table" | LC_ALL=C sort -u > "$tmp/want-iso"
  : > "$tmp/ran"; : > "$tmp/ran-iso"
  for f in "$dir"/result-*.tsv; do
    [ -f "$f" ] || continue
    awk -F '\t' '$3 ~ /^test-gate: [0-9]+ passed, [0-9]+ failed$/ { print $1 }' "$f" >> "$tmp/ran"
    awk -F '\t' '$3 == "격리 전용 행" { print $1 }' "$f" >> "$tmp/ran-iso"
  done
  LC_ALL=C sort -u "$tmp/ran" -o "$tmp/ran"
  LC_ALL=C sort -u "$tmp/ran-iso" -o "$tmp/ran-iso"
  LC_ALL=C comm -23 "$tmp/want" "$tmp/ran" > "$tmp/missing"
  LC_ALL=C comm -13 "$tmp/want" "$tmp/ran" > "$tmp/extra"
  LC_ALL=C comm -23 "$tmp/want-iso" "$tmp/ran-iso" > "$tmp/missing-iso"
  LC_ALL=C comm -13 "$tmp/want-iso" "$tmp/ran-iso" > "$tmp/extra-iso"
  if [ -s "$tmp/missing" ]; then
    rc=1; printf 'gate-timing: 합계 줄을 내지 않은 행 — %s\n' "$(sort -n "$tmp/missing" | tr '\n' ' ')" >&2
  fi
  if [ -s "$tmp/extra" ]; then
    rc=1; printf 'gate-timing: 표에서 비었거나 없는 행이 합계 줄을 냈음 — %s\n' "$(sort -n "$tmp/extra" | tr '\n' ' ')" >&2
  fi
  if [ -s "$tmp/missing-iso" ]; then
    rc=1; printf 'gate-timing: 격리 전용 행 결과를 내지 않은 행 — %s\n' "$(sort -n "$tmp/missing-iso" | tr '\n' ' ')" >&2
  fi
  if [ -s "$tmp/extra-iso" ]; then
    rc=1; printf 'gate-timing: 격리 전용 행이 아닌 행이 격리 전용 행 결과를 냈음 — %s\n' "$(sort -n "$tmp/extra-iso" | tr '\n' ' ')" >&2
  fi
  if [ -n "$slots" ]; then
    awk -F '\t' '{ print $1 }' "$table" | LC_ALL=C sort > "$tmp/rows"
    seq 1 "$slots" | LC_ALL=C sort > "$tmp/rows-want"
    if ! cmp -s "$tmp/rows" "$tmp/rows-want"; then
      rc=1; printf 'gate-timing: 표의 행 id 가 1..%s 와 다름 — 표 [%s]\n' "$slots" "$(sort -n "$tmp/rows" | tr '\n' ' ')" >&2
    fi
  fi
  if [ "$rc" = "0" ]; then
    printf 'gate-timing: 실행 행 일치 — 비지 않은 행 %s개가 모두 합계 줄을 냈다' "$(grep -c . "$tmp/want")"
    if [ -s "$tmp/want-iso" ]; then printf ' · 격리 전용 행 %s개가 모두 결과를 냈다' "$(grep -c . "$tmp/want-iso")"; fi
    printf '\n'
  fi
  rm -rf "$tmp"
  return "$rc"
}

# --- self-test ---------------------------------------------------------------

timing_self_test() {
  local passed=0 failed=0 T out sum rc
  ok()  { passed=$((passed + 1)); printf 'PASS: %s\n' "$1"; }
  bad() { failed=$((failed + 1)); printf 'FAIL: %s — %s\n' "$1" "${2:-}" >&2; }
  T=$(mktemp -d "${TMPDIR:-/tmp}/gate-timing-selftest.XXXXXX")
  row() { awk -F '\t' -v id="$1" '$1 == id { print $2 "\t" $3 }' "$2"; }

  printf 'a # x\nb # x\nc # x\nd # x\nnew # x\n' > "$T/list"
  { printf '# gate-timing v1 — source: 7 old generated: 2026-01-01T00:00:00Z\n'; printf 'id\tms\trun\n'
    printf 'a\t9\t7\nb\t9\t7\nc\t500\t7\ngone\t40\t7\n@pre-g\t9\t7\n@pre-h\t30\t7\n'; } > "$T/source"
  # Shard 1: a and b, the last ending at the epilogue; the point decimal; a
  # head of 250 ms.
  printf '@start\t100\n@head\t100.25\n@pre-g\t100.5\na\t101.0\nb\t103.25\n@epilogue\t104.5\n@end\t105\n' > "$T/s1"
  # Shard 2: the comma decimal; c's line is the last one, so the shard died in
  # c. An older file: no head marker.
  printf '@start\t200\n@pre-g\t200,25\nd\t200,75\nc\t202,75\n' > "$T/s2"
  # Shard 3: a head of 750 ms, then isolation work only — `new` laid over the
  # row with the prelude it pulled in, then a solo cut after `@end`.
  printf '@start\t300\n@head\t300.75\n@iso:@pre-h\t301\n@iso:new\t302\n@epilogue\t305\n@end\t305.5\n@iso:@start\t306\n@iso:@head\t306.5\n@iso:new\t307\n@iso:@epilogue\t308\n@iso:@end\t308.5\n' > "$T/s3"
  bash "$0" merge --list "$T/list" --run 42 --sha abc --source "$T/source" --out "$T/out.tsv" "$T/s1" "$T/s2" "$T/s3" 2>"$T/err"
  out="$T/out.tsv"
  if head -1 "$out" | grep -q '^# gate-timing v1 — source: 42 abc generated: '; then ok "머리 주석에 출처 실행과 sha 가 있다"; else bad "머리 주석" "$(head -1 "$out")"; fi
  if [ "$(sed -n 2p "$out")" = "$(printf 'id\tms\trun')" ]; then ok "열 머리가 id ms run 이다"; else bad "열 머리" "$(sed -n 2p "$out")"; fi
  if [ "$(row b "$out")" = "$(printf '1250\t42')" ]; then ok "마지막 절의 끝은 @epilogue 다"; else bad "마지막 절의 끝" "$(row b "$out")"; fi
  if [ "$(row a "$out")" = "$(printf '2250\t42')" ]; then ok "절 구간은 다음 표지까지다"; else bad "절 구간" "$(row a "$out")"; fi
  if [ "$(row d "$out")" = "$(printf '2000\t42')" ]; then ok "쉼표 소수점 표기를 읽는다"; else bad "쉼표 소수점" "$(row d "$out")"; fi
  if [ "$(row c "$out")" = "$(printf '500\t7')" ]; then ok "끝 표지가 없는 절은 재지 않은 것으로 두고 출처 값을 이어받는다"; else bad "끝 표지 없는 절" "$(row c "$out")"; fi
  if [ -z "$(row gone "$out")" ]; then ok "--list 에 없는 id 는 버린다"; else bad "사라진 id" "$(row gone "$out")"; fi
  if [ -z "$(row new "$out")" ]; then ok "어디서도 재지 않은 절은 행이 없다"; else bad "미측정 절" "$(row new "$out")"; fi
  if [ "$(row @pre-g "$out")" = "$(printf '500\t42')" ]; then ok "프렐류드는 샤드들의 평균이다"; else bad "프렐류드 평균" "$(row @pre-g "$out")"; fi
  if [ "$(row @pre-h "$out")" = "$(printf '30\t7')" ]; then ok "재지 않은 프렐류드는 출처 값을 이어받는다"; else bad "프렐류드 이어받기" "$(row @pre-h "$out")"; fi
  if ! grep -qE '^@(start|end|epilogue)	' "$out"; then ok "@start·@end·@epilogue 는 행이 되지 않는다"; else bad "구간 표지 행" "$(cat "$out")"; fi
  if [ "$(row @head "$out")" = "$(printf '500\t42')" ]; then ok "@head 는 @start 부터의 구간이고 그것을 남긴 샤드들의 평균이다"; else bad "@head 평균" "$(row @head "$out")"; fi
  if ! grep -q '^@iso:' "$out" && [ -z "$(row new "$out")" ]; then ok "@iso: 표지의 구간은 무게가 되지 않는다"; else bad "@iso: 구간" "$(cat "$out")"; fi
  bash "$0" merge --list "$T/list" --run 43 --sha abc --out "$T/nosrc.tsv" "$T/s2" 2>/dev/null
  if [ "$(awk -F '\t' 'NR > 2' "$T/nosrc.tsv" | cut -f1 | tr '\n' ' ')" = "d @pre-g " ]; then ok "출처가 없으면 이번에 잰 것만 남는다"; else bad "출처 없는 합치기" "$(cat "$T/nosrc.tsv")"; fi
  if bash "$0" merge --list "$T/missing" --run 1 --sha x --out "$T/x.tsv" "$T/s1" 2>/dev/null; then bad "목록 없는 합치기" "exit 0"; else ok "절 목록 파일이 없으면 비영 종료"; fi

  # report: shard 1 took 5 s, shard 2 30 s, shard 3 10 s — median 10, ratio 3.
  mkdir -p "$T/rep"
  printf '1\t5000\ta,b\n2\t5000\tc,d\n3\t5000\te\n4\t0\t\n' > "$T/table"
  printf '@start\t100\n@epilogue\t103\n@end\t105\n' > "$T/rep/timing-1.tsv"
  printf '@start\t100\n@end\t130\n' > "$T/rep/timing-2.tsv"
  printf '@start\t100,0\n@end\t110,0\n' > "$T/rep/timing-3.tsv"
  out=$(GITHUB_STEP_SUMMARY="$T/summary" bash "$0" report --table "$T/table" --dir "$T/rep")
  sum=$(printf '%s\n' "$out" | tail -1)
  if [ "$sum" = "45" ]; then ok "report 는 마지막 줄에 샤드 소요 합을 낸다"; else bad "샤드 소요 합" "「${out}」"; fi
  if printf '%s\n' "$out" | grep -q '^::warning::.*3\.00 로 1\.5 를 넘습니다'; then ok "최대/중앙값이 1.5 를 넘으면 경고 주석을 낸다"; else bad "균형 경고" "「${out}」"; fi
  if grep -q '최대/중앙값 3\.00' "$T/summary" && grep -q '^| 1 | 5000 | 5 | 2 |$' "$T/summary" && grep -q '^| 4 | 0 | - | - |$' "$T/summary"; then
    ok "요약 표에 샤드별 예측 적재·실측 소요·에필로그 구간이 있다"
  else
    bad "요약 표" "$(cat "$T/summary")"
  fi
  rm -f "$T/rep/timing-2.tsv"
  out=$(GITHUB_STEP_SUMMARY="$T/summary2" bash "$0" report --table "$T/table" --dir "$T/rep")
  if ! printf '%s\n' "$out" | grep -q '^::warning::'; then ok "1.5 이하면 경고하지 않는다"; else bad "균형 경고 오발" "「${out}」"; fi

  # report with isolation work: row 1 lays x over its cut (2 s before `@end`)
  # and runs two solos after it (5 s and 3 s); row 2 is plain; row 3 is an
  # isolation-only row (empty third column, a solo id) of 40 s.
  mkdir -p "$T/irep"
  printf '1\t5000\ta,b\tx\t\ta\n2\t5000\tc\t\t\t\n3\t900\t\t\tx\t\n' > "$T/itable"
  printf '@start\t100\n@head\t101\na\t102\n@iso:x\t104\nb\t106\n@epilogue\t108\n@end\t110\n@iso:@start\t111\n@iso:@head\t112\n@iso:x\t113\n@iso:@epilogue\t115\n@iso:@end\t116\n@iso:@start\t117\n@iso:@end\t120\n' > "$T/irep/timing-1.tsv"
  printf '@start\t200\n@end\t212\n' > "$T/irep/timing-2.tsv"
  printf '@start\t300\n@end\t300\n@iso:@start\t301\n@iso:@end\t341\n' > "$T/irep/timing-3.tsv"
  out=$(GITHUB_STEP_SUMMARY="$T/isummary" bash "$0" report --table "$T/itable" --dir "$T/irep")
  if [ "$(printf '%s\n' "$out" | tail -1)" = "20" ] && grep -q '^| 1 | 5000 | 8 | 2 |$' "$T/isummary"; then ok "report 의 행 시간과 합은 @end 앞의 @iso: 구간을 뺀다"; else bad "격리 구간 제외" "「${out}」 $(cat "$T/isummary")"; fi
  if ! grep -q '^| 3 |' "$T/isummary" && grep -q '샤드 2개 실측' "$T/isummary"; then ok "격리 전용 행은 샤드 표와 행 수에 들지 않는다"; else bad "격리 전용 행 제외" "$(cat "$T/isummary")"; fi
  if grep -q '^격리 시간 — 행 1 10초 · 행 3 40초 · 격리 합 50초$' "$T/isummary"; then ok "격리 시간 줄에 행별 격리 시간과 격리 합이 있다"; else bad "격리 시간 줄" "$(cat "$T/isummary")"; fi
  if [ "$(printf '%s\n' "$out" | tail -2 | head -1)" = "gate-timing: 격리 합 50초" ]; then ok "report 는 마지막 줄 바로 앞에 격리 합을 낸다"; else bad "격리 합 줄" "「${out}」"; fi

  # median: x is in all three files, y in two, z in one; the newest file is m1.
  { printf '# gate-timing v1 — source: 103 c3 generated: 2026-01-03T00:00:00Z\n'; printf 'id\tms\trun\n'
    printf 'x\t10\t103\ny\t10\t103\n@pre-g\t5\t103\n@pre-h\t3\t103\n@head\t6\t103\nbad\tx\t103\n'; } > "$T/m1"
  { printf '# gate-timing v1 — source: 102 c2 generated: 2026-01-02T00:00:00Z\n'; printf 'id\tms\trun\n'
    printf 'z\t7\t90\nx\t30\t102\ny\t15\t102\n@pre-g\t9\t102\n@pre-h\t4\t102\n@head\t8\t102\n'; } > "$T/m2"
  { printf '# gate-timing v1 — source: 101 c1 generated: 2026-01-01T00:00:00Z\n'; printf 'id\tms\trun\n'
    printf 'x\t20\t101\n@pre-g\t1\t101\n'; } > "$T/m3"
  bash "$0" median --out "$T/med.tsv" "$T/m1" "$T/m2" "$T/m3" 2>/dev/null
  out="$T/med.tsv"
  if head -1 "$out" | grep -q '^# gate-timing v1 — source: median of 103 102 101 generated: '; then ok "median 의 머리 주석에 입력 실행들이 있다"; else bad "median 머리 주석" "$(head -1 "$out")"; fi
  if [ "$(row x "$out")" = "$(printf '20\t103,102,101')" ]; then ok "세 파일에 있는 id 는 가운데 값이다"; else bad "세 값의 중앙값" "$(row x "$out")"; fi
  if [ "$(row y "$out")" = "$(printf '13\t103,102')" ]; then ok "두 파일에 있는 id 는 평균을 올림한다"; else bad "두 값의 평균 올림" "$(row y "$out")"; fi
  if [ "$(row z "$out")" = "$(printf '7\t90')" ]; then ok "한 파일에만 있는 id 는 그 값이다"; else bad "한 값" "$(row z "$out")"; fi
  if [ "$(row @pre-g "$out")" = "$(printf '5\t103,102,101')" ] && [ "$(row @pre-h "$out")" = "$(printf '4\t103,102')" ]; then ok "프렐류드 행도 같은 규칙이다"; else bad "프렐류드 중앙값" "$(row @pre-g "$out") / $(row @pre-h "$out")"; fi
  if [ "$(row @head "$out")" = "$(printf '7\t103,102')" ]; then ok "@head 행도 프렐류드와 같은 규칙이다"; else bad "@head 중앙값" "$(row @head "$out")"; fi
  if [ "$(awk -F '\t' 'NR > 2' "$out" | cut -f1 | tr '\n' ' ')" = "x y z @head @pre-g @pre-h " ]; then ok "절 행은 처음 나온 순서, 프렐류드·@head 행은 그 뒤에 id 순이다"; else bad "median 행 순서" "$(cat "$out")"; fi
  bash "$0" median --out "$T/none.tsv" "$T/absent1" "$T/absent2" > /dev/null 2>&1; rc=$?
  if [ "$rc" = "3" ] && [ ! -e "$T/none.tsv" ]; then ok "읽을 파일이 없으면 종료 3 이고 출력이 없다"; else bad "median 입력 없음" "rc=$rc"; fi
  bash "$0" median --out "$T/none.tsv" > /dev/null 2>&1; rc=$?
  if [ "$rc" = "2" ]; then ok "median 에 파일이 없으면 사용법 오류다"; else bad "median 사용법" "rc=$rc"; fi

  # rows: rows 1..3 carry ids and row 4 is empty. Every non-empty row printed
  # its total and the empty one says so — the check passes. Row 2 then loses
  # its total (exit code 0 notwithstanding) and the check fails on it. A table
  # whose row ids are not 1..S fails under --slots S.
  mkdir -p "$T/res"
  printf '1\t50\ta\n2\t50\tb\n3\t50\tc\n4\t0\t\n' > "$T/rtable"
  printf '1\t0\ttest-gate: 3 passed, 0 failed\n' > "$T/res/result-1.tsv"
  printf '2\t0\ttest-gate: 2 passed, 0 failed\n' > "$T/res/result-2.tsv"
  printf '3\t1\ttest-gate: 4 passed, 1 failed\n' > "$T/res/result-3.tsv"
  printf '4\t0\t빈 행\n' > "$T/res/result-4.tsv"
  if bash "$0" rows --table "$T/rtable" --dir "$T/res" --slots 4 > /dev/null 2>&1; then ok "rows: 비지 않은 행이 모두 합계 줄을 내고 빈 행은 비어 있으면 통과한다"; else bad "rows 통과" "비영 종료"; fi
  printf '2\t0\t-\n' > "$T/res/result-2.tsv"
  out=$(bash "$0" rows --table "$T/rtable" --dir "$T/res" --slots 4 2>&1 >/dev/null); rc=$?
  if [ "$rc" = "1" ] && printf '%s' "$out" | grep -q '합계 줄을 내지 않은 행 — 2 $'; then ok "rows: 비지 않은 행이 합계 줄을 내지 않으면 실패한다"; else bad "rows 빠진 행" "rc=$rc 「${out}」"; fi
  printf '2\t0\ttest-gate: 2 passed, 0 failed\n' > "$T/res/result-2.tsv"
  out=$(bash "$0" rows --table "$T/rtable" --dir "$T/res" --slots 6 2>&1 >/dev/null); rc=$?
  if [ "$rc" = "1" ] && printf '%s' "$out" | grep -q '표의 행 id 가 1..6 와 다름'; then ok "rows: 표의 행 id 집합이 1..S 와 다르면 실패한다"; else bad "rows 행 id 집합" "rc=$rc 「${out}」"; fi

  # rows with an isolation-only row 5 (empty third column, a solo id): it must
  # say `격리 전용 행`, and a total is not asked of it.
  mkdir -p "$T/ires"
  cp "$T/res"/result-*.tsv "$T/ires/"
  printf '1\t50\ta\n2\t50\tb\n3\t50\tc\n4\t0\t\n5\t20\t\t\tx\t\n' > "$T/irtable"
  printf '5\t0\t격리 전용 행\n' > "$T/ires/result-5.tsv"
  if bash "$0" rows --table "$T/irtable" --dir "$T/ires" --slots 5 > /dev/null 2>&1; then ok "rows: 격리 전용 행은 합계 줄 대신 격리 전용 행 결과로 통과한다"; else bad "rows 격리 전용 행 통과" "비영 종료"; fi
  printf '5\t0\t-\n' > "$T/ires/result-5.tsv"
  out=$(bash "$0" rows --table "$T/irtable" --dir "$T/ires" --slots 5 2>&1 >/dev/null); rc=$?
  if [ "$rc" = "1" ] && printf '%s' "$out" | grep -q '격리 전용 행 결과를 내지 않은 행 — 5 $'; then ok "rows: 격리 전용 행이 결과를 내지 않으면 실패한다"; else bad "rows 격리 전용 행 빠짐" "rc=$rc 「${out}」"; fi

  rm -rf "$T"
  printf 'gate-timing self-test: %d passed, %d failed\n' "$passed" "$failed"
  # A floor on the count, so a refactor that silently skips cases cannot pass.
  if [ "$passed" -lt 37 ]; then
    printf 'gate-timing self-test: 통과 수 %d 가 하한 37 에 못 미칩니다\n' "$passed" >&2
    return 1
  fi
  [ "$failed" = "0" ]
}

# --- main --------------------------------------------------------------------

[ "$#" -ge 1 ] || timing_usage
cmd="$1"; shift
case "$cmd" in
  merge)       timing_merge "$@"; exit $? ;;
  median)      timing_median "$@"; exit $? ;;
  report)      timing_report "$@"; exit $? ;;
  rows)        timing_rows "$@"; exit $? ;;
  --self-test) timing_self_test; exit $? ;;
  *) printf 'gate-timing: 모르는 하위명령입니다: %s\n' "$cmd" >&2; timing_usage ;;
esac
