#!/usr/bin/env bash
# Partition the sections of `scripts/test-gate.sh` into shards.
#
# THE PARTITION IS NEVER COMMITTED. Every shard job recomputes it from the
# suite's own `--list` and takes its own share, so a section added after the
# census was taken still lands somewhere. A committed partition would silently
# drop that section, and a workflow that names ids would need an edit nobody
# remembers to make — both lose coverage, which is the one direction this file
# must never fail in. What IS committed is the census (`scripts/gate-census.tsv`),
# and a stale census costs balance, never coverage.
#
# THE UNIT IS A CONNECTED COMPONENT, NOT A SECTION AND NOT A GROUP. Two sections
# joined by a `needs:` edge — declared on a banner, or found by the census — run
# in one cut, so they must land in one shard. Edges are taken as undirected: a
# mutual pair is real in this suite, and a component crosses groups whenever an
# edge does. A group that disagrees with a component loses.
#
# THE LOAD IS LPT: heaviest component first, onto the least-loaded shard. Ties
# are broken by component id (the lexicographically smallest member id, bytewise)
# and a load tie goes to the lowest shard number. That is not a detail: the jobs
# each recompute the partition independently, and without a total order two
# jobs can disagree and a section belongs to nobody.
#
# THE WEIGHT DOES NOT ASSUME ADDITIVITY. A census wall time is the whole
# invocation — head, family prelude and closure included — so summing those per
# section counts the head and the prelude once per section. The floor of a group
# (the smallest wall time any of its sections showed) approximates that shared
# cost; a component weighs the sum of what each member adds above its group's
# floor, plus each distinct group's floor once. A section the census does not
# know weighs the census maximum, so it is placed pessimistically and never
# skipped.
#
# A MEASURED WEIGHT REPLACES ALL OF THAT WHEN ONE IS GIVEN. `--timing PATH` reads
# the per-section times CI took from the boundary markers of its own shards
# (`scripts/gate-timing.sh merge` writes the file: a `# gate-timing v1 — source:
# <run id> <sha> generated: <UTC>` comment, a `id<TAB>ms<TAB>run` header, one row
# per section and one `@pre-<group>` row per prelude). A marker interval is the
# section's own share, not the whole invocation, so nothing is subtracted: a
# section weighs its ms (at least 1), and the table's load column is in ms.
#
# A SECTION THE FILE DOES NOT CARRY IS WEIGHED BY ITS LENGTH. Added since, or on
# a shard that died before reaching it, it has no ms of its own. Its span is the
# number of suite lines from its banner to the next banner or to the
# `# --- epilogue-begin ---` line, whichever comes first, and the measured
# sections give a rate in ms per span line; the 90th percentile of those rates
# (the ascending rate at rank ⌈0.9 n⌉) times the span is its estimate, and it
# weighs that estimate or the MEDIAN of the measured sections, whichever is
# larger. The median alone was too light for a long new section, which is the
# kind whose weight the balance depends on; the census maximum was too heavy for
# most. Each such section is reported on its own line with its span and
# estimate.
#
# A PRELUDE IS PAID ONCE PER SHARD AND GROUP. A component's weight for ordering
# and for the budget is the sum of its members plus each distinct group's
# `@pre-<group>` ms once. Placing it adds its members and the prelude of each of
# its groups the shard does not run yet, because a shard runs a group's prelude
# once however many of its components land there. Components, LPT and every tie
# rule are the same in both modes. A path that does not exist falls back to the
# census model, so the committed seed's absence costs balance and nothing else.
#
# A COMPONENT OVER BUDGET IS PLACED WHOLE AND REPORTED. The budget is 0.6/N of
# the total weight. It does not mean "split here" — splitting a component is the
# very thing the unit exists to prevent — it is the line past which the number
# must be said out loud rather than hidden.
#
# Usage:
#   bash scripts/gate-shard.sh --shards N --shard K    ids of shard K, comma-joined
#   bash scripts/gate-shard.sh --shards N --table      K<TAB>load<TAB>ids per shard
#   bash scripts/gate-shard.sh --shards N --digest     sha256 of the --table output
#   bash scripts/gate-shard.sh --shards N --shard K --from-table F
#                                                      ids of row K of a table
#                                                      already made (CI's plan job)
#   bash scripts/gate-shard.sh --shards N --check [--from-table F]
#                                                      the shards' union equals the
#                                                      --list set, no id twice, and
#                                                      the row ids are exactly 1..N
#   bash scripts/gate-shard.sh --self-test
#
#   --suite PATH    the suite to partition (default: scripts/test-gate.sh)
#   --census PATH   the census to weigh with (default: scripts/gate-census.tsv;
#                   a missing file weighs every section 1)
#   --timing PATH   weigh with measured ms instead (a missing file means the
#                   census model); `status` and `needs` still come from the
#                   census and the banners
#
# Exit codes: 0 done, 2 usage, 3 the suite could not be listed or the check
# failed, 4 the requested shard is empty.

set -uo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)

shard_usage() {
  printf 'gate-shard: 사용법 — --shards N 와 함께 --shard K / --table / --digest / --check 중 하나, 또는 --self-test (선택: --suite PATH, --census PATH, --timing PATH, --from-table F)\n' >&2
  exit 2
}

shard_sha256() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{ print $1 }'
  else
    sha256sum | awk '{ print $1 }'
  fi
}

# The banner fields are read with the selector's own rules: the id is what
# precedes the first `|`, and a field is `| <key>: <value>` up to the next `|`
# or the closing `---`. Only `group:` and `needs:` are wanted here. The fourth
# column is the span: the line distance from the banner to the next banner or
# to the first whole-line `# --- epilogue-begin ---` after it, whichever is
# nearer, or to one past the last line when neither follows. The end marker is
# matched as the whole line, because a comment in the suite starts with the
# same words.
shard_banners() {
  awk '
    $0 == "# --- epilogue-begin ---" { ne++; el[ne] = NR }
    /^# --- section: / {
      id = $0
      sub(/^# --- section:[ \t]*/, "", id); sub(/[ \t]*\|.*$/, "", id); sub(/[ \t]*---[ \t]*$/, "", id)
      grp = "-"
      if ($0 ~ /\|[ \t]*group:/) {
        grp = $0
        sub(/[ \t]*---[ \t]*$/, "", grp); sub(/^.*\|[ \t]*group:[ \t]*/, "", grp); sub(/[ \t]*\|.*$/, "", grp); sub(/[ \t]+$/, "", grp)
        if (grp == "") grp = "-"
      }
      ned = "-"
      if ($0 ~ /\|[ \t]*needs:/) {
        ned = $0
        sub(/[ \t]*---[ \t]*$/, "", ned); sub(/^.*\|[ \t]*needs:[ \t]*/, "", ned); sub(/[ \t]*\|.*$/, "", ned); gsub(/[ \t]/, "", ned)
        if (ned == "") ned = "-"
      }
      nb++; bl[nb] = NR; bid[nb] = id; bg[nb] = grp; bn[nb] = ned
    }
    END {
      e = 1
      for (i = 1; i <= nb; i++) {
        while (e <= ne && el[e] <= bl[i]) e++
        nx = NR + 1
        if (i < nb) nx = bl[i + 1]
        if (e <= ne && el[e] < nx) nx = el[e]
        printf "%s\t%s\t%s\t%d\n", bid[i], bg[i], bn[i], nx - bl[i]
      }
    }
  ' "$1"
}

# Emits the partition as records: `T <K> <load> <ids>` per shard, `W <message>`
# per ignored edge, `B <message>` per component over budget. Everything runs
# under LC_ALL=C so that every string comparison is bytewise on every awk.
shard_partition() {
  local suite="$1" census="$2" shards="$3" timing="${4:-}"
  local tmp ids_f ban_f cen_f tim_f
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/gate-shard.XXXXXX")
  ids_f="$tmp/ids"; ban_f="$tmp/banners"; cen_f="$tmp/census"; tim_f=""
  if ! bash "$suite" --list < /dev/null > "$tmp/list" 2> "$tmp/list.err"; then
    printf 'gate-shard: 절 목록을 얻지 못했습니다 (%s --list 실패) — 분할을 추측하지 않습니다\n' "$suite" >&2
    sed 's/^/  /' "$tmp/list.err" >&2
    rm -rf "$tmp"
    return 3
  fi
  awk '{ print $1 }' "$tmp/list" > "$ids_f"
  if [ ! -s "$ids_f" ]; then
    printf 'gate-shard: 절 목록이 비었습니다 (%s --list) — 분할을 추측하지 않습니다\n' "$suite" >&2
    rm -rf "$tmp"
    return 3
  fi
  shard_banners "$suite" > "$ban_f"
  if [ -f "$census" ]; then cp "$census" "$cen_f"; else : > "$cen_f"; fi
  if [ -n "$timing" ] && [ -f "$timing" ]; then tim_f="$tmp/timing"; cp "$timing" "$tim_f"; fi

  LC_ALL=C awk -F '\t' -v N="$shards" -v IDS="$ids_f" -v BAN="$ban_f" -v CEN="$cen_f" -v TIM="$tim_f" '
    function find(x,   r) { r = x; while (par[r] != r) r = par[r]; while (par[x] != r) { nx = par[x]; par[x] = r; x = nx } return r }
    function unite(a, b,   ra, rb) { ra = find(a); rb = find(b); if (ra != rb) { if (rb < ra) par[ra] = rb; else par[rb] = ra } }
    function edges(id, list,   n, k, arr, d) {
      if (list == "" || list == "-") return
      n = split(list, arr, ",")
      for (k = 1; k <= n; k++) {
        d = arr[k]; gsub(/[ \t]/, "", d)
        if (d == "" || d == "-") continue
        if (d in known) unite(id, d)
        else if (!((id SUBSEP d) in warned)) { warned[id, d] = 1; print "W\t절 " id " 의 needs 가 모르는 id " d " 를 가리킵니다 — 이 간선은 분할에 쓰지 않습니다" }
      }
    }
    BEGIN {
      while ((getline line < IDS) > 0) { if (line != "" && !(line in known)) { nid++; ids[nid] = line; known[line] = 1 } }
      while ((getline line < BAN) > 0) { split(line, f, "\t"); bgrp[f[1]] = f[2]; bned[f[1]] = f[3]; if (f[4] ~ /^[0-9]+$/ && f[4] > 0) bspan[f[1]] = f[4] + 0 }
      while ((getline line < CEN) > 0) {
        if (line ~ /^#/ || line == "") continue
        nf = split(line, f, "\t")
        if (f[1] == "id" || f[1] ~ /^@/) continue
        cgrp[f[1]] = f[2]; cned[f[1]] = (nf >= 7 ? f[7] : "-")
        if (f[4] ~ /^[0-9]+$/) cw[f[1]] = f[4] + 0
      }
      tm = 0
      if (TIM != "") {
        tm = 1
        while ((getline line < TIM) > 0) {
          if (line ~ /^#/ || line == "") continue
          split(line, f, "\t")
          if (f[1] == "id" || f[2] !~ /^[0-9]+(\.[0-9]+)?$/) continue
          if (f[1] ~ /^@pre-/) { pre[substr(f[1], 6)] = int(f[2] + 0); continue }
          if (f[1] ~ /^@/) continue
          tw[f[1]] = int(f[2] + 0)
        }
      }
      maxw = 0
      for (i = 1; i <= nid; i++) { id = ids[i]; if ((id in cw) && cw[id] > maxw) maxw = cw[id] }
      if (maxw < 1) maxw = 1
      for (i = 1; i <= nid; i++) {
        id = ids[i]; par[id] = id
        g = "-"
        if ((id in cgrp) && cgrp[id] != "" && cgrp[id] != "-") g = cgrp[id]
        else if (id in bgrp) g = bgrp[id]
        grp[id] = g
        w[id] = (id in cw) ? cw[id] : maxw
        if (id in cw) { if (!(g in fl) || cw[id] < fl[g]) fl[g] = cw[id] }
      }
      if (tm) {
        # The median of the measured sections of this list, by insertion sort:
        # the runner awk is mawk, which has no asort.
        nm = 0
        for (i = 1; i <= nid; i++) {
          id = ids[i]
          if (!(id in tw)) continue
          v = tw[id]; if (v < 1) v = 1
          j = nm; while (j >= 1 && mv[j] > v) { mv[j + 1] = mv[j]; j-- }
          mv[j + 1] = v; nm++
        }
        med = 1
        if (nm > 0) med = (nm % 2) ? mv[(nm + 1) / 2] : int((mv[nm / 2] + mv[nm / 2 + 1]) / 2)
        if (med < 1) med = 1
        # The 90th percentile of ms per span line over the measured sections
        # of this list that have a span, at rank ceil(0.9 n) in integers.
        nr = 0
        for (i = 1; i <= nid; i++) {
          id = ids[i]
          if (!(id in tw) || !(id in bspan)) continue
          v = ((tw[id] < 1) ? 1 : tw[id]) / bspan[id]
          j = nr; while (j >= 1 && rv[j] > v) { rv[j + 1] = rv[j]; j-- }
          rv[j + 1] = v; nr++
        }
        rate = (nr > 0) ? rv[int((9 * nr + 9) / 10)] : 0
        un = 0; uids = ""; nul = 0
        for (i = 1; i <= nid; i++) {
          id = ids[i]
          if (id in tw) { w[id] = (tw[id] < 1) ? 1 : tw[id]; continue }
          est = "-"; w[id] = med
          if ((id in bspan) && nr > 0) { est = int(bspan[id] * rate + 0.5); if (est > w[id]) w[id] = est }
          un++; uids = uids (un > 1 ? "," : "") id
          ul[++nul] = "U\t미측정 절 " id " — 범위 " ((id in bspan) ? bspan[id] : "-") "줄, 추정 " est " ms, 적재 " w[id] " ms"
        }
        print "U\t실측 없는 절 " un "개 — 실측 절 " nm "개의 중앙값 " med " ms 와 본문 길이 추정(줄당 p90 " sprintf("%.1f", rate) " ms) 가운데 큰 값으로 적재합니다" (un ? ": " uids : "")
        for (i = 1; i <= nul; i++) print ul[i]
      }
      for (i = 1; i <= nid; i++) {
        id = ids[i]
        if (id in bned) edges(id, bned[id])
        if (id in cned) edges(id, cned[id])
      }
      nc = 0
      for (i = 1; i <= nid; i++) {
        id = ids[i]; r = find(id)
        if (!(r in cidx)) { nc++; cidx[r] = nc; cid[nc] = id; cwt[nc] = 0; cn[nc] = 0 }
        c = cidx[r]
        if (id < cid[c]) cid[c] = id
        cn[c]++
        cmem[c, cn[c]] = id
        if (tm) {
          cwt[c] += w[id]; cms[c] += w[id]
          if (!((c SUBSEP grp[id]) in cg)) {
            cg[c, grp[id]] = 1; cng[c]++; cgl[c, cng[c]] = grp[id]
            if (grp[id] in pre) cwt[c] += pre[grp[id]]
          }
          continue
        }
        f0 = (grp[id] in fl) ? fl[grp[id]] : 0
        ex = w[id] - f0; if (ex < 1) ex = 1
        cwt[c] += ex
        if (!((c SUBSEP grp[id]) in cg)) { cg[c, grp[id]] = 1; cwt[c] += f0 }
      }
      total = 0
      for (c = 1; c <= nc; c++) { ord[c] = c; total += cwt[c] }
      # Insertion sort: weight descending, component id ascending.
      for (i = 2; i <= nc; i++) {
        v = ord[i]; j = i - 1
        while (j >= 1 && (cwt[ord[j]] < cwt[v] || (cwt[ord[j]] == cwt[v] && cid[ord[j]] > cid[v]))) { ord[j + 1] = ord[j]; j-- }
        ord[j + 1] = v
      }
      for (k = 1; k <= N; k++) { load[k] = 0; sn[k] = 0 }
      for (i = 1; i <= nc; i++) {
        c = ord[i]; best = 1
        for (k = 2; k <= N; k++) if (load[k] < load[best]) best = k
        if (tm) {
          # A prelude is paid once per shard and group, not once per component.
          add = cms[c]
          for (m = 1; m <= cng[c]; m++) {
            g = cgl[c, m]
            if ((best SUBSEP g) in sg) continue
            sg[best, g] = 1
            if (g in pre) add += pre[g]
          }
          load[best] += add
        } else load[best] += cwt[c]
        for (m = 1; m <= cn[c]; m++) { sn[best]++; smem[best, sn[best]] = cmem[c, m] }
        if (cwt[c] * N * 10 > total * 6) {
          print "B\t덩어리 " cid[c] " — 무게 " cwt[c] ", 절 " cn[c] "개, 샤드 예산 " int(total * 6 / (N * 10)) " (총무게 " total " 의 0.6/" N ") 을 넘어 쪼개지 않고 샤드 " best " 에 넣었습니다"
        }
      }
      for (k = 1; k <= N; k++) {
        for (i = 2; i <= sn[k]; i++) {
          v = smem[k, i]; j = i - 1
          while (j >= 1 && smem[k, j] > v) { smem[k, j + 1] = smem[k, j]; j-- }
          smem[k, j + 1] = v
        }
        s = ""
        for (i = 1; i <= sn[k]; i++) s = s (i > 1 ? "," : "") smem[k, i]
        print "T\t" k "\t" load[k] "\t" s
      }
    }
  ' < /dev/null > "$tmp/out"
  sed -n 's/^W	/gate-shard: /p' "$tmp/out" >&2
  sed -n 's/^U	/gate-shard: /p' "$tmp/out" >&2
  sed -n 's/^B	/gate-shard: 예산 초과 덩어리 — /p' "$tmp/out" >&2
  sed -n 's/^T	//p' "$tmp/out"
  cp "$ids_f" "${SHARD_IDS_OUT:-/dev/null}" 2>/dev/null || true
  rm -rf "$tmp"
  return 0
}

# The coverage check reads the TABLE, not the partition's internals, so a table
# produced elsewhere (`--from-table`) is held to the same rule. It compares SETS:
# a count is satisfied by one id twice and another id never.
#
# THE ROW IDS ARE CHECKED AS A SET TOO. The table must carry exactly the rows
# 1..N of the `--shards` it is checked against. A range check alone lets a
# 13-row table pass under `--shards 26`: rows 14..26 are then simply absent, the
# run-row check counts only rows that carry ids, and the lane that should run
# them is skipped in silence.
shard_check() {
  local table="$1" ids_f="$2" n="$3"
  local tmp rc=0
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/gate-shard-check.XXXXXX")
  awk -F '\t' '{ print $1 }' "$table" | LC_ALL=C sort > "$tmp/rows"
  seq 1 "$n" | LC_ALL=C sort > "$tmp/rows-want"
  if ! cmp -s "$tmp/rows" "$tmp/rows-want"; then
    rc=3; printf 'gate-shard: 표의 행 id 가 1..%s 와 다름 — 표 [%s]\n' "$n" "$(sort -n "$tmp/rows" | tr '\n' ' ')" >&2
  fi
  awk -F '\t' '{ n = split($3, a, ","); for (i = 1; i <= n; i++) if (a[i] != "") print a[i] }' "$table" > "$tmp/all"
  LC_ALL=C sort "$tmp/all" | uniq -d > "$tmp/dup"
  LC_ALL=C sort -u "$tmp/all" > "$tmp/have"
  LC_ALL=C sort -u "$ids_f" > "$tmp/want"
  LC_ALL=C comm -13 "$tmp/have" "$tmp/want" > "$tmp/missing"
  LC_ALL=C comm -23 "$tmp/have" "$tmp/want" > "$tmp/extra"
  if [ -s "$tmp/dup" ]; then
    rc=3; printf 'gate-shard: 두 샤드 이상에 든 절 — %s\n' "$(tr '\n' ' ' < "$tmp/dup")" >&2
  fi
  if [ -s "$tmp/missing" ]; then
    rc=3; printf 'gate-shard: 어느 샤드에도 없는 절 — %s\n' "$(tr '\n' ' ' < "$tmp/missing")" >&2
  fi
  if [ -s "$tmp/extra" ]; then
    rc=3; printf 'gate-shard: --list 에 없는 절이 샤드에 있음 — %s\n' "$(tr '\n' ' ' < "$tmp/extra")" >&2
  fi
  if [ "$rc" = "0" ]; then
    printf 'gate-shard: 커버리지 일치 — 절 %s개, 샤드 합집합이 --list 집합과 같고 중복 없음\n' "$(grep -c . "$tmp/want")"
  fi
  rm -rf "$tmp"
  return "$rc"
}

# --- self-test ---------------------------------------------------------------

shard_self_test() {
  local passed=0 failed=0 T out out2 err rc
  ok()  { passed=$((passed + 1)); printf 'PASS: %s\n' "$1"; }
  bad() { failed=$((failed + 1)); printf 'FAIL: %s — %s\n' "$1" "${2:-}" >&2; }
  T=$(mktemp -d "${TMPDIR:-/tmp}/gate-shard-selftest.XXXXXX")

  # A fake suite: `--list` answers from a heredoc and the banners sit below the
  # exit, where nothing executes them but the partitioner's reader sees them.
  # A spec is `id|group|needs`, or `id|group|needs|L` to put L comment lines
  # after the banner; without L the banners are consecutive and every span is 1.
  mk_suite() {
    local f="$1"; shift
    {
      printf '#!/usr/bin/env bash\n'
      printf 'if [ "${1:-}" = "--list" ]; then\n'
      local s
      for s in "$@"; do printf "  printf '%%s # %%s\\\\n' '%s' '%s'\n" "${s%%|*}" "${s%%|*}"; done
      printf '  exit 0\nfi\nexit 1\n'
      for s in "$@"; do
        local id="${s%%|*}" rest="${s#*|}"
        local g="${rest%%|*}" n="${rest#*|}" body=0 l
        case "$n" in *'|'*) body="${n#*|}"; n="${n%%|*}" ;; esac
        if [ "$n" = "-" ]; then
          printf '# --- section: %s | group: %s | covers: - | anchors: x ---\n' "$id" "$g"
        else
          printf '# --- section: %s | group: %s | covers: - | needs: %s | anchors: x ---\n' "$id" "$g" "$n"
        fi
        l=0; while [ "$l" -lt "$body" ]; do printf '# body of %s\n' "$id"; l=$((l + 1)); done
      done
    } > "$f"
  }
  mk_census() {
    local f="$1"; shift
    { printf '# gate-census v1\n'; printf 'id\tgroup\tstatus\twall_seconds\tpassed\tfailed\tneeds\tcrash_symbol\n'
      local r; for r in "$@"; do printf '%s\n' "$r"; done; } > "$f"
  }

  # (a) determinism, (b) an uncensused section, (c) coverage
  mk_suite "$T/s1.sh" 'a|g1|-' 'b|g1|-' 'c|g2|-' 'd|g2|-' 'e|g2|-' 'new|g1|-'
  mk_census "$T/c1.tsv" "a	g1	ok	30	1	0	-	-" "b	g1	ok	10	1	0	-	-" \
    "c	g2	ok	20	1	0	-	-" "d	g2	ok	5	1	0	-	-" "e	g2	ok	5	1	0	-	-"
  out=$(bash "$0" --suite "$T/s1.sh" --census "$T/c1.tsv" --shards 2 --table 2>/dev/null)
  out2=$(bash "$0" --suite "$T/s1.sh" --census "$T/c1.tsv" --shards 2 --table 2>/dev/null)
  if [ -n "$out" ] && [ "$out" = "$out2" ]; then ok "(a) 같은 입력의 --table 두 번이 바이트 동일"; else bad "(a) 같은 입력의 --table 두 번이 바이트 동일" "「${out}」 대 「${out2}」"; fi
  d1=$(bash "$0" --suite "$T/s1.sh" --census "$T/c1.tsv" --shards 2 --digest 2>/dev/null)
  d2=$(printf '%s\n' "$out" | shard_sha256)
  if [ "$d1" = "$d2" ]; then ok "(a) --digest 는 --table 출력의 sha256"; else bad "(a) --digest 는 --table 출력의 sha256" "$d1 대 $d2"; fi
  # new weighs the census maximum (30) minus g1 floor (10) plus the floor = 30.
  case "$out" in
    *new*) ok "(b) 센서스 행이 없는 절도 어느 샤드엔가 들어간다" ;;
    *) bad "(b) 센서스 행이 없는 절도 어느 샤드엔가 들어간다" "$out" ;;
  esac
  load_new=$(printf '%s\n' "$out" | awk -F '\t' '$3 ~ /(^|,)new(,|$)/ { print $1 }')
  load_a=$(printf '%s\n' "$out" | awk -F '\t' '$3 ~ /(^|,)a(,|$)/ { print $1 }')
  if [ -n "$load_new" ] && [ "$load_new" != "$load_a" ]; then ok "(b) 미측정 절은 최대 시간으로 적재되어 가장 무거운 절과 다른 샤드에 간다"; else bad "(b) 미측정 절은 최대 시간으로 적재되어 가장 무거운 절과 다른 샤드에 간다" "$out"; fi
  if bash "$0" --suite "$T/s1.sh" --census "$T/c1.tsv" --shards 2 --check > /dev/null 2>&1; then ok "(c) --check 가 합집합 = --list 집합을 확인한다"; else bad "(c) --check 가 합집합 = --list 집합을 확인한다" "비영 종료"; fi
  printf '1\t1\ta,b,c\n2\t1\tc,d,new\n' > "$T/badtable"
  err=$(bash "$0" --suite "$T/s1.sh" --census "$T/c1.tsv" --shards 2 --check --from-table "$T/badtable" 2>&1 >/dev/null); rc=$?
  if [ "$rc" = "3" ] && printf '%s' "$err" | grep -q '두 샤드 이상에 든 절 — c' && printf '%s' "$err" | grep -q '어느 샤드에도 없는 절 — e'; then
    ok "(c) 중복과 누락을 집합으로 잡는다 (개수가 같아도)"
  else
    bad "(c) 중복과 누락을 집합으로 잡는다 (개수가 같아도)" "rc=$rc err=$err"
  fi

  # (d) ties: four equal singletons over two shards go a,c / b,d
  mk_suite "$T/s2.sh" 'd|g|-' 'c|g|-' 'b|g|-' 'a|g|-'
  mk_census "$T/c2.tsv" "a	g	ok	10	1	0	-	-" "b	g	ok	10	1	0	-	-" "c	g	ok	10	1	0	-	-" "d	g	ok	10	1	0	-	-"
  out=$(bash "$0" --suite "$T/s2.sh" --census "$T/c2.tsv" --shards 2 --table 2>/dev/null)
  want=$(printf '1\t22\ta,c\n2\t22\tb,d')
  if [ "$out" = "$want" ]; then ok "(d) 동률은 덩어리 id 사전순, 적재 동률은 낮은 샤드 번호"; else bad "(d) 동률은 덩어리 id 사전순, 적재 동률은 낮은 샤드 번호" "「${out}」"; fi
  k2=$(bash "$0" --suite "$T/s2.sh" --census "$T/c2.tsv" --shards 2 --shard 2 2>/dev/null)
  if [ "$k2" = "b,d" ]; then ok "(d) --shard K 는 --sections 에 바로 쓸 한 줄"; else bad "(d) --shard K 는 --sections 에 바로 쓸 한 줄" "「${k2}」"; fi

  # (e) a mutual pair and a cross-group edge (banner and census) make one component
  mk_suite "$T/s3.sh" 'x|g1|y' 'y|g1|x' 'z|g2|x' 'p|g2|-' 'q|g3|-'
  mk_census "$T/c3.tsv" "x	g1	ok	5	1	0	-	-" "y	g1	ok	5	1	0	-	-" "z	g2	ok	5	1	0	-	-" \
    "p	g2	ok	5	1	0	-	-" "q	g3	crash	5	-	-	p	FOO"
  out=$(bash "$0" --suite "$T/s3.sh" --census "$T/c3.tsv" --shards 4 --table 2>/dev/null)
  if printf '%s\n' "$out" | grep -q '	x,y,z$'; then ok "(e) 상호 needs 쌍과 교차 그룹 간선이 한 덩어리"; else bad "(e) 상호 needs 쌍과 교차 그룹 간선이 한 덩어리" "$out"; fi
  if printf '%s\n' "$out" | grep -q '	p,q$'; then ok "(e) 센서스 needs 간선도 덩어리를 묶는다"; else bad "(e) 센서스 needs 간선도 덩어리를 묶는다" "$out"; fi

  # (f) an unknown needs id warns and is ignored
  mk_suite "$T/s4.sh" 'm|g|ghost' 'n|g|-'
  err=$(bash "$0" --suite "$T/s4.sh" --census "$T/none.tsv" --shards 2 --table 2>&1 >/dev/null); rc=$?
  out=$(bash "$0" --suite "$T/s4.sh" --census "$T/none.tsv" --shards 2 --table 2>/dev/null)
  if [ "$rc" = "0" ] && printf '%s' "$err" | grep -q '모르는 id ghost' && [ "$(printf '%s\n' "$out" | grep -c .)" = "2" ]; then
    ok "(f) 모르는 needs id 는 경고 후 무시"
  else
    bad "(f) 모르는 needs id 는 경고 후 무시" "rc=$rc err=$err out=$out"
  fi

  # (g) a component over budget is reported and still placed
  mk_suite "$T/s5.sh" 'big|g|-' 's1|h|-' 's2|h|-' 's3|h|-'
  mk_census "$T/c5.tsv" "big	g	ok	100	1	0	-	-" "s1	h	ok	1	1	0	-	-" "s2	h	ok	1	1	0	-	-" "s3	h	ok	1	1	0	-	-"
  err=$(bash "$0" --suite "$T/s5.sh" --census "$T/c5.tsv" --shards 4 --table 2>&1 >/dev/null)
  out=$(bash "$0" --suite "$T/s5.sh" --census "$T/c5.tsv" --shards 4 --table 2>/dev/null)
  if printf '%s' "$err" | grep -q '예산 초과 덩어리 — 덩어리 big' && printf '%s\n' "$out" | grep -q '	big$'; then
    ok "(g) 예산 초과 덩어리는 쪼개지 않고 넣고 보고한다"
  else
    bad "(g) 예산 초과 덩어리는 쪼개지 않고 넣고 보고한다" "err=$err out=$out"
  fi
  bash "$0" --suite "$T/s2.sh" --census "$T/c2.tsv" --shards 9 --shard 9 > /dev/null 2>&1; rc=$?
  if [ "$rc" = "4" ]; then ok "빈 샤드의 --shard 는 빈 목록이 아니라 exit 4 (빈 --sections 는 전량이다)"; else bad "빈 샤드의 --shard 는 빈 목록이 아니라 exit 4 (빈 --sections 는 전량이다)" "rc=$rc"; fi

  # (h) a suite that cannot list refuses to partition
  printf '#!/usr/bin/env bash\nexit 1\n' > "$T/s6.sh"
  bash "$0" --suite "$T/s6.sh" --census "$T/c1.tsv" --shards 2 --table > /dev/null 2>&1; rc=$?
  if [ "$rc" = "3" ]; then ok "(h) --list 실패 시 비영 종료"; else bad "(h) --list 실패 시 비영 종료" "rc=$rc"; fi

  # (i) measured weights: deterministic, and a prelude counts once per group of
  # a component — x and y share g1 and one component, so g1's 5 ms is added
  # once to their 30, and z carries g2's 7 on its own 40.
  mk_timing() {
    local f="$1"; shift
    { printf '# gate-timing v1 — source: 1 abc generated: 2026-01-01T00:00:00Z\n'; printf 'id\tms\trun\n'
      local r; for r in "$@"; do printf '%s\t1\n' "$r"; done; } > "$f"
  }
  mk_suite "$T/s7.sh" 'x|g1|y' 'y|g1|-' 'z|g2|-'
  mk_timing "$T/t7.tsv" "x	10" "y	20" "z	40" "@pre-g1	5" "@pre-g2	7"
  out=$(bash "$0" --suite "$T/s7.sh" --census "$T/none.tsv" --timing "$T/t7.tsv" --shards 2 --table 2>/dev/null)
  out2=$(bash "$0" --suite "$T/s7.sh" --census "$T/none.tsv" --timing "$T/t7.tsv" --shards 2 --table 2>/dev/null)
  if [ -n "$out" ] && [ "$out" = "$out2" ]; then ok "(i) 실측 모드의 --table 두 번이 바이트 동일"; else bad "(i) 실측 모드의 --table 두 번이 바이트 동일" "「${out}」 대 「${out2}」"; fi
  want=$(printf '1\t47\tz\n2\t35\tx,y')
  if [ "$out" = "$want" ]; then ok "(i) 덩어리 무게는 절 ms 합에 그룹당 프렐류드 ms 한 번"; else bad "(i) 덩어리 무게는 절 ms 합에 그룹당 프렐류드 ms 한 번" "「${out}」"; fi

  # (j) an unmeasured section weighs the larger of the median of the measured
  # ones (20 of 10, 20, 30) and its span times the p90 rate. Every span is 1, so
  # the rates are 10, 20, 30, the p90 is 30 and one shard carries
  # 10 + 30 + 20 + 30; `gone` is not in the list and adds no rate.
  mk_suite "$T/s8.sh" 'a|g|-' 'b|g|-' 'c|g|-' 'n|g|-'
  mk_timing "$T/t8.tsv" "a	10" "b	30" "c	20" "gone	99"
  out=$(bash "$0" --suite "$T/s8.sh" --census "$T/none.tsv" --timing "$T/t8.tsv" --shards 1 --table 2>/dev/null)
  if [ "$out" = "$(printf '1\t90\ta,b,c,n')" ]; then ok "(j) 실측 없는 절은 중앙값과 본문 길이 추정 가운데 큰 값으로 적재된다"; else bad "(j) 실측 없는 절은 중앙값과 본문 길이 추정 가운데 큰 값으로 적재된다" "「${out}」"; fi
  err=$(bash "$0" --suite "$T/s8.sh" --census "$T/none.tsv" --timing "$T/t8.tsv" --shards 1 --table 2>&1 >/dev/null)
  if printf '%s' "$err" | grep -q '^gate-shard: 실측 없는 절 1개.*중앙값 20 ms.*줄당 p90 30\.0 ms.*: n$'; then ok "(j) 실측 없는 절의 수와 id 를 보고한다"; else bad "(j) 실측 없는 절의 수와 id 를 보고한다" "$err"; fi
  # Each unmeasured id has its own line, and none of them starts the way the
  # head line does: the workflow takes every line starting that way into the
  # job summary.
  if printf '%s\n' "$err" | grep -q '^gate-shard: 미측정 절 n — 범위 1줄, 추정 30 ms, 적재 30 ms$' \
     && [ "$(printf '%s\n' "$err" | grep -c '^gate-shard: 실측 없는 절 ')" = "1" ]; then
    ok "(j) 미측정 id 별 줄은 실측 없는 절 머리 줄과 다르게 시작한다"
  else
    bad "(j) 미측정 id 별 줄은 실측 없는 절 머리 줄과 다르게 시작한다" "$err"
  fi
  out=$(bash "$0" --suite "$T/s1.sh" --census "$T/c1.tsv" --timing "$T/absent.tsv" --shards 2 --table 2>/dev/null)
  out2=$(bash "$0" --suite "$T/s1.sh" --census "$T/c1.tsv" --shards 2 --table 2>/dev/null)
  if [ -n "$out" ] && [ "$out" = "$out2" ]; then ok "(j) 없는 실측 파일은 센서스 모델로 돌아간다"; else bad "(j) 없는 실측 파일은 센서스 모델로 돌아간다" "「${out}」 대 「${out2}」"; fi

  # (k) a shard taken from a table already made
  printf '1\t5\ta,b\n2\t0\t\n' > "$T/plan.tsv"
  k1=$(bash "$0" --suite "$T/s6.sh" --shards 2 --shard 1 --from-table "$T/plan.tsv" 2>/dev/null)
  if [ "$k1" = "a,b" ]; then ok "(k) --from-table 의 --shard 는 표의 그 행을 내고 분할하지 않는다"; else bad "(k) --from-table 의 --shard 는 표의 그 행을 내고 분할하지 않는다" "「${k1}」"; fi
  bash "$0" --suite "$T/s6.sh" --shards 2 --shard 2 --from-table "$T/plan.tsv" > /dev/null 2>&1; rc=$?
  if [ "$rc" = "4" ]; then ok "(k) --from-table 의 빈 행은 exit 4"; else bad "(k) --from-table 의 빈 행은 exit 4" "rc=$rc"; fi

  # (l) a long unmeasured section is weighed by its span: big's banner is
  # followed by 50 lines, so its span is 51 and at 10 ms a line it weighs 510
  # where the median would have given it 10 — it takes a shard alone.
  mk_suite "$T/s9.sh" 'a|g|-' 'b|g|-' 'c|g|-' 'd|g|-' 'big|g|-|50'
  mk_timing "$T/t9.tsv" "a	10" "b	10" "c	10" "d	10"
  out=$(bash "$0" --suite "$T/s9.sh" --census "$T/none.tsv" --timing "$T/t9.tsv" --shards 3 --table 2>/dev/null)
  if [ "$out" = "$(printf '1\t510\tbig\n2\t20\ta,c\n3\t20\tb,d')" ]; then ok "(l) 본문이 긴 미측정 절은 본문 길이로 적재되어 한 행에 혼자 놓인다"; else bad "(l) 본문이 긴 미측정 절은 본문 길이로 적재되어 한 행에 혼자 놓인다" "「${out}」"; fi

  # (m) a short unmeasured section stays at the median: the rates are 10, 20
  # and 30 ms a line over spans of 10, so s (span 1) is estimated at 30 and
  # weighs the median 200.
  mk_suite "$T/s10.sh" 'a|g|-|9' 'b|g|-|9' 'c|g|-|9' 's|g|-'
  mk_timing "$T/t10.tsv" "a	100" "b	200" "c	300"
  err=$(bash "$0" --suite "$T/s10.sh" --census "$T/none.tsv" --timing "$T/t10.tsv" --shards 1 --table 2>&1 >/dev/null)
  out=$(bash "$0" --suite "$T/s10.sh" --census "$T/none.tsv" --timing "$T/t10.tsv" --shards 1 --table 2>/dev/null)
  if [ "$out" = "$(printf '1\t800\ta,b,c,s')" ] && printf '%s\n' "$err" | grep -q '^gate-shard: 미측정 절 s — 범위 1줄, 추정 30 ms, 적재 200 ms$'; then
    ok "(m) 본문이 짧은 미측정 절은 중앙값 무게에 머문다"
  else
    bad "(m) 본문이 짧은 미측정 절은 중앙값 무게에 머문다" "out=${out} err=${err}"
  fi

  # (n) a prelude is added once per shard and group: p lands alone on shard 1
  # with g's 5 ms; q and r both land on shard 2, which pays g's prelude once,
  # so it carries 30 + 20 + 5 and not 30 + 5 + 20 + 5.
  mk_suite "$T/s11.sh" 'p|g|-' 'q|g|-' 'r|g|-'
  mk_timing "$T/t11.tsv" "p	50" "q	30" "r	20" "@pre-g	5"
  out=$(bash "$0" --suite "$T/s11.sh" --census "$T/none.tsv" --timing "$T/t11.tsv" --shards 2 --table 2>/dev/null)
  if [ "$out" = "$(printf '1\t55\tp\n2\t55\tq,r')" ]; then ok "(n) 프렐류드는 행마다 그룹당 한 번 더해진다"; else bad "(n) 프렐류드는 행마다 그룹당 한 번 더해진다" "「${out}」"; fi

  # (o) a slot table: N runners × L lanes are S = N × L rows, and the table and
  # its check take S. The rows are exactly 1..S; a 13-row table checked under
  # `--shards 26` fails, though every id it carries is in range; and a row past
  # the runner count is still a row, not a usage error.
  out=$(bash "$0" --suite "$T/s1.sh" --census "$T/c1.tsv" --shards 26 --table 2>/dev/null)
  if [ "$(printf '%s\n' "$out" | awk -F '\t' '{ print $1 }' | tr '\n' ' ')" = "$(seq 1 26 | tr '\n' ' ')" ] \
     && bash "$0" --suite "$T/s1.sh" --census "$T/c1.tsv" --shards 26 --check > /dev/null 2>&1; then
    ok "(o) --shards 26 의 표는 행 id 가 정확히 1..26 이고 --check 가 통과한다"
  else
    bad "(o) --shards 26 의 표는 행 id 가 정확히 1..26 이고 --check 가 통과한다" "「${out}」"
  fi
  bash "$0" --suite "$T/s1.sh" --census "$T/c1.tsv" --shards 13 --table > "$T/t13.tsv" 2>/dev/null
  err=$(bash "$0" --suite "$T/s1.sh" --census "$T/c1.tsv" --shards 26 --check --from-table "$T/t13.tsv" 2>&1 >/dev/null); rc=$?
  if [ "$rc" = "3" ] && printf '%s' "$err" | grep -q '표의 행 id 가 1..26 와 다름'; then
    ok "(o) --shards 26 아래 13행 표는 --check 에서 실패한다"
  else
    bad "(o) --shards 26 아래 13행 표는 --check 에서 실패한다" "rc=$rc err=$err"
  fi
  seq 1 26 | awk '{ print $1 "\t" ($1 == 14 ? "5\ta,b" : "0\t") }' > "$T/t26.tsv"
  k1=$(bash "$0" --suite "$T/s6.sh" --shards 26 --shard 14 --from-table "$T/t26.tsv" 2>/dev/null); rc=$?
  if [ "$rc" = "0" ] && [ "$k1" = "a,b" ]; then ok "(o) --shards 26 --shard 14 --from-table 은 사용법 오류 없이 행을 낸다"; else bad "(o) --shards 26 --shard 14 --from-table 은 사용법 오류 없이 행을 낸다" "rc=$rc 「${k1}」"; fi

  rm -rf "$T"
  printf 'gate-shard self-test: %d passed, %d failed\n' "$passed" "$failed"
  # A floor on the count, so a refactor that silently skips cases cannot pass.
  if [ "$passed" -lt 27 ]; then
    printf 'gate-shard self-test: 통과 수 %d 가 하한 27 에 못 미칩니다\n' "$passed" >&2
    return 1
  fi
  [ "$failed" = "0" ]
}

# --- main --------------------------------------------------------------------

suite="$repo_root/scripts/test-gate.sh"
census="$repo_root/scripts/gate-census.tsv"
shards=""
mode=""
shard_k=""
from_table=""
timing=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --suite)      [ "$#" -ge 2 ] || shard_usage; suite="$2"; shift 2 ;;
    --census)     [ "$#" -ge 2 ] || shard_usage; census="$2"; shift 2 ;;
    --timing)     [ "$#" -ge 2 ] || shard_usage; timing="$2"; shift 2 ;;
    --shards)     [ "$#" -ge 2 ] || shard_usage; shards="$2"; shift 2 ;;
    --shard)      [ "$#" -ge 2 ] || shard_usage; mode="shard"; shard_k="$2"; shift 2 ;;
    --table)      mode="table"; shift ;;
    --digest)     mode="digest"; shift ;;
    --check)      mode="check"; shift ;;
    --from-table) [ "$#" -ge 2 ] || shard_usage; from_table="$2"; shift 2 ;;
    --self-test)  mode="self-test"; shift ;;
    *) printf 'gate-shard: 모르는 인자입니다: %s\n' "$1" >&2; shard_usage ;;
  esac
done

if [ "$mode" = "self-test" ]; then
  shard_self_test
  exit $?
fi
[ -n "$mode" ] || shard_usage
case "$shards" in ''|*[!0-9]*|0) shard_usage ;; esac
if [ "$mode" = "shard" ]; then
  case "$shard_k" in ''|*[!0-9]*|0) shard_usage ;; esac
  [ "$shard_k" -le "$shards" ] || shard_usage
fi

# A SHARD TAKEN FROM A TABLE DOES NOT PARTITION AGAIN. CI makes the table once,
# in its plan job, and every shard job reads its own row of that one file: a
# shard that recomputed could see a different input than its siblings did, and
# a section would then belong to no shard. The coverage job checks the same file
# with `--check --from-table`, which does partition, for the `--list` set.
if [ "$mode" = "shard" ] && [ -n "$from_table" ]; then
  if [ ! -f "$from_table" ]; then
    printf 'gate-shard: 표 파일이 없습니다: %s\n' "$from_table" >&2
    exit 3
  fi
  ids=$(awk -F '\t' -v k="$shard_k" '$1 == k { print $3 }' "$from_table")
  if [ -z "$ids" ]; then
    printf 'gate-shard: 표 %s 의 샤드 %s/%s 가 비었습니다 — 빈 --sections 는 전량 실행이므로 빈 목록을 내지 않습니다\n' "$from_table" "$shard_k" "$shards" >&2
    exit 4
  fi
  printf '%s\n' "$ids"
  exit 0
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/gate-shard-main.XXXXXX")
trap 'rm -rf "$work"' EXIT
SHARD_IDS_OUT="$work/ids" shard_partition "$suite" "$census" "$shards" "$timing" > "$work/table"
prc=$?
[ "$prc" = "0" ] || exit "$prc"

case "$mode" in
  table)  cat "$work/table" ;;
  digest) shard_sha256 < "$work/table" ;;
  shard)
    ids=$(awk -F '\t' -v k="$shard_k" '$1 == k { print $3 }' "$work/table")
    if [ -z "$ids" ]; then
      printf 'gate-shard: 샤드 %s/%s 가 비었습니다 — 빈 --sections 는 전량 실행이므로 빈 목록을 내지 않습니다\n' "$shard_k" "$shards" >&2
      exit 4
    fi
    printf '%s\n' "$ids" ;;
  check)
    if [ -n "$from_table" ]; then
      shard_check "$from_table" "$work/ids" "$shards"
    else
      shard_check "$work/table" "$work/ids" "$shards"
    fi
    exit $? ;;
esac
