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
# THE NEW FILE IS THE WHOLE LIST, AND ONLY THE LIST. Every id of `--list` that
# this run measured takes the new value; every other id the source carried is
# taken over with the run id that measured it; an id the source carried that
# `--list` no longer has is dropped, so a removed section does not weigh the
# median forever. A prelude takes the mean over the shards that ran it, and an
# unmeasured prelude is taken over the same way. Values are the latest ones,
# never smoothed: one source line says where every weight came from.
#
# Usage:
#   bash scripts/gate-timing.sh merge --list F --run ID --sha SHA --out F
#                                     [--source F] SHARD_FILE...
#   bash scripts/gate-timing.sh report --table F --dir D
#       reads D/timing-<K>.tsv for each row K of the partition table, writes a
#       Markdown table to $GITHUB_STEP_SUMMARY (stdout when unset), warns past a
#       max/median of 1.5 and prints the sum of the shard times in seconds on
#       stdout, alone on its last line
#   bash scripts/gate-timing.sh --self-test
#
# Exit codes: 0 done, 2 usage, 3 an input could not be read.

set -uo pipefail

timing_usage() {
  printf 'gate-timing: 사용법 — merge --list F --run ID --sha SHA --out F [--source F] <샤드 표지 파일>... / report --table F --dir D / --self-test\n' >&2
  exit 2
}

# One awk program reads every marker file and prints `<id> <ms>` per measured
# interval, files in the order given. A file name never reaches the output: what
# matters is which interval, not which shard.
timing_intervals() {
  LC_ALL=C awk -F '\t' '
    FNR == 1 { havep = 0 }
    {
      t = $2; gsub(/,/, ".", t)
      if ($1 == "" || t !~ /^[0-9]+(\.[0-9]+)?$/) next
      t = t + 0
      if (havep) {
        ms = int((t - pt) * 1000 + 0.5); if (ms < 0) ms = 0
        if (pid !~ /^@(start|end|epilogue)$/) print pid "\t" ms
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
          if (a[1] == "id" || a[2] !~ /^[0-9]+$/) continue
          sv[a[1]] = a[2]; sr[a[1]] = (n >= 3 && a[3] != "") ? a[3] : "-"
          if (a[1] ~ /^@pre-/ && !(a[1] in seenp)) { seenp[a[1]] = 1; pres[++np] = a[1] }
        }
      }
      {
        if ($1 ~ /^@pre-/) {
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
  local tmp k load f
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/gate-timing-report.XXXXXX")
  : > "$tmp/rows"
  while IFS="$(printf '\t')" read -r k load _; do
    [ -n "$k" ] || continue
    f="$dir/timing-$k.tsv"
    if [ -f "$f" ]; then
      LC_ALL=C awk -F '\t' -v K="$k" -v L="$load" '
        { t = $2; gsub(/,/, ".", t); if (t !~ /^[0-9]+(\.[0-9]+)?$/) next; t = t + 0
          if ($1 == "@start") s = t; else if ($1 == "@end") e = t; else if ($1 == "@epilogue") p = t }
        END {
          d = (s != "" && e != "") ? int(e - s + 0.5) : "-"
          q = (p != "" && e != "") ? int(e - p + 0.5) : "-"
          print K "\t" L "\t" d "\t" q
        }' "$f" >> "$tmp/rows"
    else
      printf '%s\t%s\t-\t-\n' "$k" "$load" >> "$tmp/rows"
    fi
  done < "$table"
  LC_ALL=C awk -F '\t' '
    { k[NR] = $1; l[NR] = $2; d[NR] = $3; q[NR] = $4
      if ($3 != "-") { n++; v = $3 + 0; sum += v; j = n - 1; while (j >= 1 && sv[j] > v) { sv[j + 1] = sv[j]; j-- } sv[j + 1] = v } }
    END {
      print "### gate 샤드 실측 소요"
      print ""
      print "| 샤드 | 예측 적재 | 실측 소요(초) | 에필로그(초) |"
      print "| --- | --- | --- | --- |"
      for (i = 1; i <= NR; i++) print "| " k[i] " | " l[i] " | " d[i] " | " q[i] " |"
      print ""
      if (n == 0) { print "실측 소요를 읽은 샤드가 없습니다."; print "SUM\t0"; exit 0 }
      mid = (n % 2) ? sv[(n + 1) / 2] : (sv[n / 2] + sv[n / 2 + 1]) / 2
      r = (mid > 0) ? sv[n] / mid : 0
      printf "샤드 %d개 실측 · 최대 %d초 · 중앙값 %s초 · 최대/중앙값 %.2f · 합 %d초\n", n, sv[n], mid, r, sum
      if (n < NR) printf "실측 소요를 읽지 못한 샤드 %d개\n", NR - n
      printf "RATIO\t%.2f\n", r
      print "SUM\t" sum
    }' "$tmp/rows" > "$tmp/report"
  sed -n '/^RATIO	/d; /^SUM	/d; p' "$tmp/report" >> "${GITHUB_STEP_SUMMARY:-/dev/stdout}"
  local ratio sum
  ratio=$(sed -n 's/^RATIO	//p' "$tmp/report")
  sum=$(sed -n 's/^SUM	//p' "$tmp/report")
  if [ -n "$ratio" ] && awk -v r="$ratio" 'BEGIN { exit !(r > 1.5) }'; then
    printf '::warning::gate 샤드 실측 소요의 최대/중앙값이 %s 로 1.5 를 넘습니다 — 잡 요약의 샤드 표를 보세요\n' "$ratio"
  fi
  rm -rf "$tmp"
  printf '%s\n' "${sum:-0}"
  return 0
}

# --- self-test ---------------------------------------------------------------

timing_self_test() {
  local passed=0 failed=0 T out sum
  ok()  { passed=$((passed + 1)); printf 'PASS: %s\n' "$1"; }
  bad() { failed=$((failed + 1)); printf 'FAIL: %s — %s\n' "$1" "${2:-}" >&2; }
  T=$(mktemp -d "${TMPDIR:-/tmp}/gate-timing-selftest.XXXXXX")
  row() { awk -F '\t' -v id="$1" '$1 == id { print $2 "\t" $3 }' "$2"; }

  printf 'a # x\nb # x\nc # x\nd # x\nnew # x\n' > "$T/list"
  { printf '# gate-timing v1 — source: 7 old generated: 2026-01-01T00:00:00Z\n'; printf 'id\tms\trun\n'
    printf 'a\t9\t7\nb\t9\t7\nc\t500\t7\ngone\t40\t7\n@pre-g\t9\t7\n@pre-h\t30\t7\n'; } > "$T/source"
  # Shard 1: a and b, the last ending at the epilogue; the point decimal.
  printf '@start\t100\n@pre-g\t100.5\na\t101.0\nb\t103.25\n@epilogue\t104.5\n@end\t105\n' > "$T/s1"
  # Shard 2: the comma decimal; c's line is the last one, so the shard died in c.
  printf '@start\t200\n@pre-g\t200,25\nd\t200,75\nc\t202,75\n' > "$T/s2"
  bash "$0" merge --list "$T/list" --run 42 --sha abc --source "$T/source" --out "$T/out.tsv" "$T/s1" "$T/s2" 2>"$T/err"
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

  rm -rf "$T"
  printf 'gate-timing self-test: %d passed, %d failed\n' "$passed" "$failed"
  # A floor on the count, so a refactor that silently skips cases cannot pass.
  if [ "$passed" -lt 17 ]; then
    printf 'gate-timing self-test: 통과 수 %d 가 하한 17 에 못 미칩니다\n' "$passed" >&2
    return 1
  fi
  [ "$failed" = "0" ]
}

# --- main --------------------------------------------------------------------

[ "$#" -ge 1 ] || timing_usage
cmd="$1"; shift
case "$cmd" in
  merge)       timing_merge "$@"; exit $? ;;
  report)      timing_report "$@"; exit $? ;;
  --self-test) timing_self_test; exit $? ;;
  *) printf 'gate-timing: 모르는 하위명령입니다: %s\n' "$cmd" >&2; timing_usage ;;
esac
