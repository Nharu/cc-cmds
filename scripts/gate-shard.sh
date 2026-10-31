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
# ISOLATION WORK RIDES ON THE PARTITION, IT DOES NOT CHANGE IT. `--isolate C`
# takes the changed sections C and, with the regular rows exactly as they would
# be without it, adds two things for each X of C and its needs closure (banner
# and census edges, the graph the components are built from). The limit is F:
# the heaviest regular row with the head time — the `@head` row of the timing
# file, 0 without one — paid once, since every process pays it. First the
# solos: two per X, each a process of its own weighing the closure, the
# preludes of its groups and the head, X heaviest first, each onto the row with
# the most room and, when none has room, onto a new extra row S+1, S+2, … while
# there may be one (`--iso-extra`). A solo is never heavier than X's own row, so
# an empty extra row always takes it. Then the overlays: X and its closure laid
# into every other regular row that still has room, the roomiest first, a group
# the overlay pulls in adding its prelude. A row the overlay does not fit is an
# uncovered pair, reported and not an error. A solo that finds no row is: exit
# 5. A closure that reaches an id `--list` does not have is exit 2 — the
# selector runs everything for an unknown id.
#
# With `--isolate` every row has three more columns: the laid-over ids (4), the
# solos (5, `;`-separated, each `<1|2>:<X>,<closure>` — 2 being the solo the
# lane runs under the second TMPDIR) and the ids of C the row runs as its own
# (6). The extra rows follow the regular ones with an empty third column.
# Without `--isolate` the output is the three-column table, byte for byte.
#
# Usage:
#   bash scripts/gate-shard.sh --shards N --shard K    ids of shard K, comma-joined
#   bash scripts/gate-shard.sh --shards N --table      K<TAB>load<TAB>ids per shard
#   bash scripts/gate-shard.sh --shards N --digest     sha256 of the --table output
#   bash scripts/gate-shard.sh --shards N --shard K --from-table F [--extra E]
#                              [--overlay | --solo | --own]
#                                                      ids of row K of a table
#                                                      already made (CI's plan job),
#                                                      or its column 4, 5 or 6
#   bash scripts/gate-shard.sh --shards N --check [--from-table F --extra E]
#                                                      the shards' union equals the
#                                                      --list set, no id twice, and
#                                                      the row ids are exactly
#                                                      1..N+E
#   bash scripts/gate-shard.sh --timing F --weights   id<TAB>ms<TAB>표|추정 per
#                                                      section: the table's ms, or
#                                                      the span-rate estimate below
#   bash scripts/gate-shard.sh --self-test
#
#   --only IDS      partition only the components of the whole suite that hold
#                   one of these ids; a row lists the named ids it got and
#                   weighs them with their `needs:` closure, and there are
#                   min(N, components) rows (check-push's lanes)
#   --suite PATH    the suite to partition (default: scripts/test-gate.sh)
#   --census PATH   the census to weigh with (default: scripts/gate-census.tsv;
#                   a missing file weighs every section 1)
#   --timing PATH   weigh with measured ms instead (a missing file means the
#                   census model); `status` and `needs` still come from the
#                   census and the banners
#   --isolate C     place the isolation work of the comma list C (may be empty)
#   --iso-extra E   at most E extra rows for it (default 0)
#   --extra E       the extra rows a table already made carries (default 0)
#
# The coverage check counts the third column only: a laid-over id appears in
# several rows by design. An isolation-only row (empty third column, ids in 4
# or 5) answers `--shard K` with an empty line and exit 0; its caller runs no
# regular cut for it.
#
# Exit codes: 0 done, 2 usage or an isolation closure with an id --list does
# not have, 3 the suite could not be listed or the check failed, 4 the
# requested shard is empty (columns 3, 4 and 5), 5 the solos did not fit
# ("격리 검사 용량 초과").

set -uo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)

shard_usage() {
  printf 'gate-shard: 사용법 — --shards N 와 함께 --shard K / --table / --digest / --check 중 하나, --timing PATH 와 함께 --weights, 또는 --self-test (선택: --suite PATH, --census PATH, --timing PATH, --from-table F, --only IDS, --isolate C, --iso-extra E, --extra E, --overlay / --solo / --own)\n' >&2
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
  local suite="$1" census="$2" shards="$3" timing="${4:-}" only="${5:-}" iso_on="${6:-0}" iso="${7:-}" iso_extra="${8:-0}"
  local tmp ids_f ban_f cen_f tim_f rc
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

  LC_ALL=C awk -F '\t' -v N="$shards" -v IDS="$ids_f" -v BAN="$ban_f" -v CEN="$cen_f" -v TIM="$tim_f" -v ONLY="$only" \
      -v ISOON="$iso_on" -v ISO="$iso" -v EXTRA="$iso_extra" '
    # What one section adds to a cut, and what a group adds the first time the
    # cut runs it: the same two terms the partition sums, so a solo or an
    # overlay is weighed in the unit of the rows it is compared with.
    function idw(id,   a) { if (tm) return w[id]; a = w[id] - ((grp[id] in fl) ? fl[grp[id]] : 0); return (a < 1) ? 1 : a }
    function grpw(g) { if (tm) return (g in pre) ? pre[g] : 0; return (g in fl) ? fl[g] : 0 }
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
      tm = 0; hd = 0
      if (TIM != "") {
        tm = 1
        while ((getline line < TIM) > 0) {
          if (line ~ /^#/ || line == "") continue
          split(line, f, "\t")
          if (f[1] == "id" || f[2] !~ /^[0-9]+(\.[0-9]+)?$/) continue
          if (f[1] == "@head") { hd = int(f[2] + 0); continue }
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
        for (i = 1; i <= nid; i++) { id = ids[i]; print "X\t" id "\t" w[id] "\t" ((id in tw) ? "표" : "추정") }
      }
      for (i = 1; i <= nid; i++) {
        id = ids[i]
        if (id in bned) edges(id, bned[id])
        if (id in cned) edges(id, cned[id])
      }
      # A SUBSET KEEPS THE WHOLE SUITE`S COMPONENTS. The components above are the
      # full graph`s, so two named ids that CI would put in one shard land in one
      # row here too; only the components holding a named id are kept. A row
      # lists only named ids, and weighs them with the sections their `needs:`
      # closure pulls into the cut, each once. The row count is the smaller of
      # N and the components kept, so no row comes out empty.
      if (ONLY != "") {
        no = split(ONLY, oa, ",")
        for (k = 1; k <= no; k++) {
          x = oa[k]; gsub(/[ \t]/, "", x)
          if (x == "") continue
          if (!(x in known)) { print "O\t지명한 절 id " x " 가 --list 에 없습니다"; bad_only = 1; continue }
          named[x] = 1
          if (!(x in act)) { act[x] = 1; qn++; qa[qn] = x }
        }
        for (k = 1; k <= qn; k++) {
          x = qa[k]
          if (!(x in bned) || bned[x] == "-") continue
          nn = split(bned[x], nda, ",")
          for (m = 1; m <= nn; m++) {
            d = nda[m]
            if (d == "" || d == "-" || !(d in known) || (d in act)) continue
            act[d] = 1; qn++; qa[qn] = d
          }
        }
        if (bad_only) exit
      }
      nc = 0
      for (i = 1; i <= nid; i++) {
        id = ids[i]
        if (ONLY != "" && !(id in act)) continue
        r = find(id)
        if (!(r in cidx)) { nc++; cidx[r] = nc; cid[nc] = id; cwt[nc] = 0; cn[nc] = 0 }
        c = cidx[r]
        if (id < cid[c]) cid[c] = id
        if (ONLY == "" || (id in named)) { cn[c]++; cmem[c, cn[c]] = id }
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
      if (ONLY != "" && nc < N) N = nc
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
      ne = 0
      if (ISOON) {
        # The changed sections, each with its needs closure along the same
        # graph the components were built from: banner needs and census needs.
        # A closure that reaches an id --list does not have is an error, not a
        # warning: the selector runs everything for an unknown id, so one solo
        # would become a full run.
        ebad = 0; nx = 0
        na = split(ISO, xa, ",")
        for (i = 1; i <= na; i++) {
          x = xa[i]
          if (x == "" || (x in seenx)) continue
          seenx[x] = 1
          if (!(x in known)) { print "E\t바뀐 절 " x " 이 --list 에 없습니다 — 격리 배치를 하지 않습니다"; ebad = 1; continue }
          xs[++nx] = x
        }
        for (i = 1; i <= nx; i++) {
          x = xs[i]
          split("", vis); vis[x] = 1; ns = 1; stk[1] = x
          while (ns > 0) {
            id = stk[ns]; ns--
            lst = ((id in bned) ? bned[id] : "-") "," ((id in cned) ? cned[id] : "-")
            m = split(lst, da, ",")
            for (j = 1; j <= m; j++) {
              d = da[j]; gsub(/[ \t]/, "", d)
              if (d == "" || d == "-" || (d in vis)) continue
              vis[d] = 1
              if (!(d in known)) { print "E\t바뀐 절 " x " 의 needs 폐포에 --list 에 없는 id " d " 가 있습니다 — 격리 배치를 하지 않습니다"; ebad = 1; continue }
              stk[++ns] = d
            }
          }
          # X first, the rest of the closure in --list order.
          cl[x] = x; cc[x] = 1; cm[x, 1] = x
          for (j = 1; j <= nid; j++) { id = ids[j]; if (id != x && (id in vis)) { cl[x] = cl[x] "," id; cc[x]++; cm[x, cc[x]] = id } }
          split("", tg); xw[x] = 0
          for (j = 1; j <= cc[x]; j++) {
            id = cm[x, j]; xw[x] += idw(id)
            if (!(grp[id] in tg)) { tg[grp[id]] = 1; xw[x] += grpw(grp[id]) }
          }
        }
        if (ebad) exit
        # Heaviest first, then by id bytewise.
        for (i = 2; i <= nx; i++) {
          v = xs[i]; j = i - 1
          while (j >= 1 && (xw[xs[j]] < xw[v] || (xw[xs[j]] == xw[v] && xs[j] > v))) { xs[j + 1] = xs[j]; j-- }
          xs[j + 1] = v
        }
        # F is the heaviest regular row with the head paid once. A row with no
        # ids runs no process, so it carries nothing.
        F = 0
        for (k = 1; k <= N; k++) {
          cur[k] = (sn[k] > 0) ? load[k] + hd : 0
          if (cur[k] > F) F = cur[k]
          for (m = 1; m <= sn[k]; m++) { id = smem[k, m]; rowof[id] = k; rg[k, grp[id]] = 1 }
        }
        # Solos first, two per changed section, each a process of its own that
        # pays the head once: onto the row with the most room (the lowest row
        # number on a tie), else onto a new extra row while there may be one.
        rows = N; ncap = 0; capl = ""
        for (i = 1; i <= nx; i++) {
          x = xs[i]; s = xw[x] + hd
          for (rep = 1; rep <= 2; rep++) {
            best = 1
            for (k = 2; k <= rows; k++) if (cur[k] < cur[best]) best = k
            if (F - cur[best] < s) {
              if (ne < EXTRA + 0 && s <= F) { ne++; rows = N + ne; best = rows; cur[best] = 0 }
              else { if (!(x in capx)) { capx[x] = 1; ncap++; capl = capl (ncap > 1 ? "," : "") x } continue }
            }
            cur[best] += s
            solo[best] = solo[best] (solo[best] == "" ? "" : ";") rep ":" cl[x]
          }
        }
        if (ncap) { print "C\t격리 검사 용량 초과 — 단독을 싣지 못한 바뀐 절: " capl " (F " F ", 추가 행 상한 " (EXTRA + 0) ")"; exit }
        # Then the overlays, into the room the solos left: each changed section
        # onto every regular row it does not belong to, the roomiest row first,
        # as long as no row passes F. A group the overlay pulls into a row adds
        # its prelude. A row it does not fit is an uncovered pair.
        for (i = 1; i <= nx; i++) {
          x = xs[i]; own = rowof[x]; no = 0
          for (k = 1; k <= N; k++) {
            if (sn[k] == 0 || k == own) continue
            v = k; j = no
            while (j >= 1 && (cur[ro[j]] > cur[v] || (cur[ro[j]] == cur[v] && ro[j] > v))) { ro[j + 1] = ro[j]; j-- }
            ro[j + 1] = v; no++
          }
          split("", ux)
          for (j = 1; j <= no; j++) {
            k = ro[j]; split("", tg); a = 0
            for (m = 1; m <= cc[x]; m++) {
              id = cm[x, m]
              if (rowof[id] == k || ((k SUBSEP id) in ovs)) continue
              a += idw(id)
              if (!((k SUBSEP grp[id]) in rg) && !(grp[id] in tg)) { tg[grp[id]] = 1; a += grpw(grp[id]) }
            }
            if (cur[k] + a > F) { ux[k] = 1; continue }
            cur[k] += a
            for (m = 1; m <= cc[x]; m++) {
              id = cm[x, m]
              if (rowof[id] == k || ((k SUBSEP id) in ovs)) continue
              ovs[k, id] = 1; on[k]++; om[k, on[k]] = id; rg[k, grp[id]] = 1
            }
          }
          unc = ""
          for (k = 1; k <= N; k++) if (k in ux) unc = unc (unc == "" ? "" : ",") k
          if (unc != "") print "P\t덮지 못한 쌍 — " x ": 행 " unc
        }
      }
      nw = 0
      for (k = 1; k <= N; k++) {
        for (i = 2; i <= sn[k]; i++) {
          v = smem[k, i]; j = i - 1
          while (j >= 1 && smem[k, j] > v) { smem[k, j + 1] = smem[k, j]; j-- }
          smem[k, j + 1] = v
        }
        s = ""
        for (i = 1; i <= sn[k]; i++) s = s (i > 1 ? "," : "") smem[k, i]
        if (!ISOON) { print "T\t" k "\t" load[k] "\t" s; continue }
        for (i = 2; i <= on[k]; i++) {
          v = om[k, i]; j = i - 1
          while (j >= 1 && om[k, j] > v) { om[k, j + 1] = om[k, j]; j-- }
          om[k, j + 1] = v
        }
        ovl = ""; for (i = 1; i <= on[k]; i++) ovl = ovl (i > 1 ? "," : "") om[k, i]
        ownl = ""; for (i = 1; i <= sn[k]; i++) if (smem[k, i] in seenx) ownl = ownl (ownl == "" ? "" : ",") smem[k, i]
        if (ovl != "" || solo[k] != "" || ownl != "") nw++
        print "T\t" k "\t" load[k] "\t" s "\t" ovl "\t" solo[k] "\t" ownl
      }
      if (ISOON) {
        for (k = N + 1; k <= N + ne; k++) { nw++; print "T\t" k "\t" cur[k] "\t\t\t" solo[k] "\t" }
        print "I\t격리 배치 — 바뀐 절 " nx "개 · F " F " · 머리 " hd " · 추가 행 " ne "/" (EXTRA + 0) " · 격리 작업 행 " nw "개"
      }
    }
  ' < /dev/null > "$tmp/out"
  # A named id --list does not have is a subset that cannot be cut (exit 3);
  # an isolation closure that cannot be planned is exit 2, below.
  if grep -q '^O	' "$tmp/out"; then
    sed -n 's/^O	/gate-shard: /p' "$tmp/out" >&2
    rm -rf "$tmp"
    return 3
  fi
  sed -n 's/^X	//p' "$tmp/out" > "${SHARD_WEIGHTS_OUT:-/dev/null}" 2>/dev/null || true
  sed -n 's/^W	/gate-shard: /p' "$tmp/out" >&2
  sed -n 's/^U	/gate-shard: /p' "$tmp/out" >&2
  sed -n 's/^B	/gate-shard: 예산 초과 덩어리 — /p' "$tmp/out" >&2
  sed -n 's/^P	/gate-shard: /p' "$tmp/out" >&2
  sed -n 's/^I	/gate-shard: /p' "$tmp/out" >&2
  # An isolation that could not be planned prints no table at all: a table
  # without the solos would read as a run that checked nothing.
  rc=0
  if grep -q '^E	' "$tmp/out"; then
    sed -n 's/^E	/gate-shard: /p' "$tmp/out" >&2; rc=2
  elif grep -q '^C	' "$tmp/out"; then
    sed -n 's/^C	/gate-shard: /p' "$tmp/out" >&2; rc=5
  else
    sed -n 's/^T	//p' "$tmp/out"
  fi
  cp "$ids_f" "${SHARD_IDS_OUT:-/dev/null}" 2>/dev/null || true
  rm -rf "$tmp"
  return "$rc"
}

# One row of a table: the ids to run (column 3) by default, or the laid-over
# (4), solo (5) or own changed (6) column. A row whose columns 3, 4 and 5 are
# all empty is an empty row and exits 4 — an empty --sections is a full run.
# A row with an empty third column but laid-over or solo ids is an
# isolation-only row: its regular ids are an empty line and exit 0, and the
# caller must not hand that line to --sections. A chosen column 4, 5 or 6 that
# is empty is an empty line and exit 0.
shard_row() {
  local table="$1" k="$2" col="$3" shards="$4" line
  line=$(awk -F '\t' -v k="$k" -v c="$col" '$1 == k { print (($3 $4 $5) == "" ? "E" : "N") "\t" $c; exit }' "$table")
  if [ "$col" != "3" ]; then
    printf '%s\n' "${line#*	}"
    return 0
  fi
  case "$line" in
    N*) printf '%s\n' "${line#*	}"; return 0 ;;
  esac
  printf 'gate-shard: 표의 샤드 %s/%s 가 비었습니다 — 빈 --sections 는 전량 실행이므로 빈 목록을 내지 않습니다\n' "$k" "$shards" >&2
  return 4
}

# The coverage check reads the TABLE, not the partition's internals, so a table
# produced elsewhere (`--from-table`) is held to the same rule. It compares SETS:
# a count is satisfied by one id twice and another id never.
#
# THE ROW IDS ARE CHECKED AS A SET TOO. The table must carry exactly the rows
# 1..N of the `--shards` it is checked against, N counting the extra isolation
# rows when there are any. A range check alone lets a
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

  # (x) the weights a caller reads: the table's ms for a measured section and
  # the estimate (j) placed `n` with for the one the table lacks.
  out=$(bash "$0" --suite "$T/s8.sh" --census "$T/none.tsv" --timing "$T/t8.tsv" --weights 2>/dev/null)
  if [ "$out" = "$(printf 'a\t10\t표\nb\t30\t표\nc\t20\t표\nn\t30\t추정')" ]; then ok "(x) --weights 는 표에 있는 절은 표 값, 없는 절은 추정 값을 낸다"; else bad "(x) --weights 는 표에 있는 절은 표 값, 없는 절은 추정 값을 낸다" "「${out}」"; fi
  bash "$0" --suite "$T/s8.sh" --census "$T/none.tsv" --timing "$T/absent.tsv" --weights > /dev/null 2>&1; rc=$?
  if [ "$rc" = "2" ]; then ok "(x) 없는 표의 --weights 는 exit 2"; else bad "(x) 없는 표의 --weights 는 exit 2" "rc=$rc"; fi

  # (y) a subset is cut from the whole suite's components: p and z are joined by
  # a census edge alone and share a row; x's row weighs its closure y too but
  # lists only x; the unnamed component of q is dropped, so two rows come out
  # of four asked for.
  mk_suite "$T/s20.sh" 'x|g|y' 'y|g|-' 'z|g|-' 'p|g|-' 'q|g|-'
  mk_census "$T/c20.tsv" "p	g	ok	5	1	0	z	-"
  mk_timing "$T/t20.tsv" "x	10" "y	20" "z	40" "p	5" "q	99"
  out=$(bash "$0" --suite "$T/s20.sh" --census "$T/c20.tsv" --timing "$T/t20.tsv" --shards 4 --only x,z,p --table 2>/dev/null)
  if [ "$out" = "$(printf '1\t45\tp,z\n2\t30\tx')" ]; then ok "(y) --only 는 전체 성분을 지명 절로 투영하고 행 수는 성분 수를 넘지 않는다"; else bad "(y) --only 는 전체 성분을 지명 절로 투영하고 행 수는 성분 수를 넘지 않는다" "「${out}」"; fi
  bash "$0" --suite "$T/s20.sh" --census "$T/c20.tsv" --shards 2 --only x,ghost --table > /dev/null 2>&1; rc=$?
  if [ "$rc" = "3" ]; then ok "(y) --only 의 모르는 id 는 exit 3"; else bad "(y) --only 의 모르는 id 는 exit 3" "rc=$rc"; fi

  # (p) --isolate with nothing changed keeps the regular rows as they are and
  # only adds the three empty columns.
  out=$(bash "$0" --suite "$T/s7.sh" --census "$T/none.tsv" --timing "$T/t7.tsv" --shards 2 --table 2>/dev/null)
  out2=$(bash "$0" --suite "$T/s7.sh" --census "$T/none.tsv" --timing "$T/t7.tsv" --shards 2 --table --isolate '' --iso-extra 2 2>/dev/null)
  if [ "$(printf '%s\n' "$out2" | cut -f1-3)" = "$out" ] && [ "$(printf '%s\n' "$out2" | awk -F '\t' 'NF != 6' | grep -c .)" = "0" ]; then
    ok "(p) 빈 --isolate 는 정규 행을 그대로 두고 빈 열 셋만 더한다"
  else
    bad "(p) 빈 --isolate 는 정규 행을 그대로 두고 빈 열 셋만 더한다" "「${out}」 대 「${out2}」"
  fi

  # (q) F, the head and an extra row: rows p,x (55 + 10 + h's 2) and q,r
  # (30 + 20 + g's 5) give F = 67 + the head 3 = 70. A solo of x weighs 10 +
  # 2 + 3 = 15; row 2 has 70 - 58 = 12 of room, so both solos go to extra row 3.
  # The overlay of x on row 2 then adds 10 + h's 2 and fills it to exactly F.
  mk_suite "$T/s12.sh" 'p|g|-' 'q|g|-' 'r|g|-' 'x|h|-'
  mk_timing "$T/t12.tsv" "p	50" "q	30" "r	20" "x	10" "@pre-g	5" "@pre-h	2" "@head	3"
  out=$(bash "$0" --suite "$T/s12.sh" --census "$T/none.tsv" --timing "$T/t12.tsv" --shards 2 --table --isolate x --iso-extra 2 2>"$T/e12")
  if [ "$out" = "$(printf '1\t67\tp,x\t\t\tx\n2\t55\tq,r\tx\t\t\n3\t30\t\t\t1:x;2:x\t')" ]; then ok "(q) 여유가 없는 단독은 추가 행에 가고, 얹힘은 F 까지 채운다"; else bad "(q) 여유가 없는 단독은 추가 행에 가고, 얹힘은 F 까지 채운다" "「${out}」"; fi
  if grep -q '^gate-shard: 격리 배치 — 바뀐 절 1개 · F 70 · 머리 3 · 추가 행 1/2 · 격리 작업 행 3개$' "$T/e12"; then ok "(q) F 는 정규 행 부하에 @head 한 번을 더한 최댓값이다"; else bad "(q) F 는 정규 행 부하에 @head 한 번을 더한 최댓값이다" "$(cat "$T/e12")"; fi
  printf '%s\n' "$out" > "$T/p12.tsv"

  # (r) solos first: rows a (100), b (40), c,x (40), F 100. The solos of x take
  # rows 2 and 3 (the lowest number on the tie); the overlay of x then fits row
  # 2 and not row 1, which is reported.
  mk_suite "$T/s13.sh" 'a|g|-' 'b|g|-' 'c|g|-' 'x|g|-'
  mk_timing "$T/t13.tsv" "a	100" "b	40" "c	30" "x	10"
  out=$(bash "$0" --suite "$T/s13.sh" --census "$T/none.tsv" --timing "$T/t13.tsv" --shards 3 --table --isolate x --iso-extra 2 2>"$T/e13")
  if [ "$out" = "$(printf '1\t100\ta\t\t\t\n2\t40\tb\tx\t1:x\t\n3\t40\tc,x\t\t2:x\tx')" ]; then ok "(r) 단독이 먼저 정규 행의 여유를 쓰고 추가 행을 열지 않는다"; else bad "(r) 단독이 먼저 정규 행의 여유를 쓰고 추가 행을 열지 않는다" "「${out}」"; fi
  if grep -q '^gate-shard: 덮지 못한 쌍 — x: 행 1$' "$T/e13"; then ok "(r) 여유가 모자라 얹지 못한 행은 덮지 못한 쌍으로 적는다"; else bad "(r) 여유가 모자라 얹지 못한 행은 덮지 못한 쌍으로 적는다" "$(cat "$T/e13")"; fi

  # (s) capacity: the solos of (q) with no extra row allowed do not fit.
  out=$(bash "$0" --suite "$T/s12.sh" --census "$T/none.tsv" --timing "$T/t12.tsv" --shards 2 --table --isolate x --iso-extra 0 2>"$T/e14"); rc=$?
  if [ "$rc" = "5" ] && [ -z "$out" ] && grep -q '격리 검사 용량 초과 — 단독을 싣지 못한 바뀐 절: x ' "$T/e14"; then ok "(s) 단독을 다 싣지 못하면 표 없이 exit 5"; else bad "(s) 단독을 다 싣지 못하면 표 없이 exit 5" "rc=$rc 「${out}」 $(cat "$T/e14")"; fi

  # (t) a closure with an id --list does not have, and a changed id it does not
  # have, are exit 2 with no table.
  out=$(bash "$0" --suite "$T/s4.sh" --census "$T/none.tsv" --shards 2 --table --isolate m 2>"$T/e15"); rc=$?
  if [ "$rc" = "2" ] && [ -z "$out" ] && grep -q '폐포에 --list 에 없는 id ghost' "$T/e15"; then ok "(t) 폐포의 모르는 id 는 표 없이 exit 2"; else bad "(t) 폐포의 모르는 id 는 표 없이 exit 2" "rc=$rc 「${out}」 $(cat "$T/e15")"; fi
  bash "$0" --suite "$T/s4.sh" --census "$T/none.tsv" --shards 2 --table --isolate nope > /dev/null 2>&1; rc=$?
  if [ "$rc" = "2" ]; then ok "(t) --list 에 없는 바뀐 절은 exit 2"; else bad "(t) --list 에 없는 바뀐 절은 exit 2" "rc=$rc"; fi

  # (u) the closure follows census needs too: q needs p only in the census.
  out=$(bash "$0" --suite "$T/s3.sh" --census "$T/c3.tsv" --shards 4 --table --isolate q --iso-extra 2 2>/dev/null)
  if printf '%s\n' "$out" | cut -f5 | grep -q '1:q,p'; then ok "(u) 단독의 폐포는 센서스 needs 간선도 따른다"; else bad "(u) 단독의 폐포는 센서스 needs 간선도 따른다" "「${out}」"; fi

  # (v) the row check takes the extra rows: 1..N+E.
  if bash "$0" --suite "$T/s12.sh" --census "$T/none.tsv" --shards 2 --extra 1 --check --from-table "$T/p12.tsv" > /dev/null 2>&1; then ok "(v) --extra E 의 --check 는 행 1..N+E 를 받는다"; else bad "(v) --extra E 의 --check 는 행 1..N+E 를 받는다" "비영 종료"; fi
  bash "$0" --suite "$T/s12.sh" --census "$T/none.tsv" --shards 2 --check --from-table "$T/p12.tsv" > /dev/null 2>&1; rc=$?
  if [ "$rc" = "3" ]; then ok "(v) --extra 없이 추가 행이 있는 표는 --check 에서 실패한다"; else bad "(v) --extra 없이 추가 행이 있는 표는 --check 에서 실패한다" "rc=$rc"; fi
  if bash "$0" --suite "$T/s12.sh" --census "$T/none.tsv" --timing "$T/t12.tsv" --shards 2 --isolate x --iso-extra 2 --check > /dev/null 2>&1; then ok "(v) 표를 직접 짜는 --check 는 자기 추가 행을 센다"; else bad "(v) 표를 직접 짜는 --check 는 자기 추가 행을 센다" "비영 종료"; fi

  # (w) a row of a table already made, column by column.
  k1=$(bash "$0" --suite "$T/s6.sh" --shards 2 --extra 1 --shard 3 --from-table "$T/p12.tsv" 2>/dev/null); rc=$?
  if [ "$rc" = "0" ] && [ -z "$k1" ]; then ok "(w) 격리 전용 행의 --shard 는 빈 줄과 exit 0"; else bad "(w) 격리 전용 행의 --shard 는 빈 줄과 exit 0" "rc=$rc 「${k1}」"; fi
  k1=$(bash "$0" --suite "$T/s6.sh" --shards 2 --extra 1 --shard 3 --from-table "$T/p12.tsv" --solo 2>/dev/null)
  k2=$(bash "$0" --suite "$T/s6.sh" --shards 2 --extra 1 --shard 2 --from-table "$T/p12.tsv" --overlay 2>/dev/null)
  out=$(bash "$0" --suite "$T/s6.sh" --shards 2 --extra 1 --shard 1 --from-table "$T/p12.tsv" --own 2>/dev/null)
  if [ "$k1" = "1:x;2:x" ] && [ "$k2" = "x" ] && [ "$out" = "x" ]; then ok "(w) --solo·--overlay·--own 은 그 행의 5·4·6열을 낸다"; else bad "(w) --solo·--overlay·--own 은 그 행의 5·4·6열을 낸다" "「${k1}」「${k2}」「${out}」"; fi
  k1=$(bash "$0" --suite "$T/s6.sh" --shards 2 --extra 1 --shard 2 --from-table "$T/p12.tsv" --solo 2>/dev/null); rc=$?
  if [ "$rc" = "0" ] && [ -z "$k1" ]; then ok "(w) 고른 열이 비면 빈 줄과 exit 0"; else bad "(w) 고른 열이 비면 빈 줄과 exit 0" "rc=$rc 「${k1}」"; fi
  bash "$0" --suite "$T/s6.sh" --shards 2 --shard 3 --from-table "$T/p12.tsv" > /dev/null 2>&1; rc=$?
  if [ "$rc" = "2" ]; then ok "(w) --extra 없이 N 을 넘는 --shard 는 사용법 오류"; else bad "(w) --extra 없이 N 을 넘는 --shard 는 사용법 오류" "rc=$rc"; fi

  rm -rf "$T"
  printf 'gate-shard self-test: %d passed, %d failed\n' "$passed" "$failed"
  # A floor on the count, so a refactor that silently skips cases cannot pass.
  if [ "$passed" -lt 48 ]; then
    printf 'gate-shard self-test: 통과 수 %d 가 하한 48 에 못 미칩니다\n' "$passed" >&2
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
only=""
iso_on=0
iso=""
iso_extra=0
extra=0
col=3
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
    --only)       [ "$#" -ge 2 ] || shard_usage; only="$2"; shift 2 ;;
    --weights)    mode="weights"; shift ;;
    --isolate)    [ "$#" -ge 2 ] || shard_usage; iso_on=1; iso="$2"; shift 2 ;;
    --iso-extra)  [ "$#" -ge 2 ] || shard_usage; iso_extra="$2"; shift 2 ;;
    --extra)      [ "$#" -ge 2 ] || shard_usage; extra="$2"; shift 2 ;;
    --overlay)    col=4; shift ;;
    --solo)       col=5; shift ;;
    --own)        col=6; shift ;;
    --self-test)  mode="self-test"; shift ;;
    *) printf 'gate-shard: 모르는 인자입니다: %s\n' "$1" >&2; shard_usage ;;
  esac
done

if [ "$mode" = "self-test" ]; then
  shard_self_test
  exit $?
fi
[ -n "$mode" ] || shard_usage
# The weights are the measured model's, so they need a table to fit it to; the
# census model has no per-section weight that a caller could read as seconds.
if [ "$mode" = "weights" ]; then
  if [ -z "$timing" ] || [ ! -f "$timing" ]; then
    printf 'gate-shard: --weights 는 있는 --timing 표와 함께 씁니다 (받은 것: 「%s」)\n' "$timing" >&2
    exit 2
  fi
  work=$(mktemp -d "${TMPDIR:-/tmp}/gate-shard-main.XXXXXX")
  trap 'rm -rf "$work"' EXIT
  SHARD_WEIGHTS_OUT="$work/weights" shard_partition "$suite" "$census" 1 "$timing" > /dev/null
  prc=$?
  [ "$prc" = "0" ] || exit "$prc"
  cat "$work/weights"
  exit 0
fi
case "$only" in
  ''|*[!A-Za-z0-9_,-]*)
    if [ -n "$only" ]; then
      printf 'gate-shard: --only 의 id 에 쓸 수 없는 문자가 있습니다: %s\n' "$only" >&2
      exit 2
    fi ;;
esac
if [ -n "$only" ] && [ "$mode" = "check" ]; then
  printf 'gate-shard: --only 는 --check 와 함께 쓰지 않습니다 (덮는 범위 검사는 --list 전체를 본다)\n' >&2
  exit 2
fi
case "$shards" in ''|*[!0-9]*|0) shard_usage ;; esac
case "$iso_extra" in ''|*[!0-9]*) shard_usage ;; esac
case "$extra" in ''|*[!0-9]*) shard_usage ;; esac
case "$iso" in *[!A-Za-z0-9,._-]*) shard_usage ;; esac
[ "$col" = "3" ] || [ "$mode" = "shard" ] || shard_usage
# The rows past --shards are the extra isolation rows: --extra says how many a
# table already made has, and a table made here may have up to --iso-extra.
rows_max=$((shards + extra))
if [ "$iso_on" = "1" ] && [ -z "$from_table" ] && [ "$iso_extra" -gt "$extra" ]; then rows_max=$((shards + iso_extra)); fi
if [ "$mode" = "shard" ]; then
  case "$shard_k" in ''|*[!0-9]*|0) shard_usage ;; esac
  [ "$shard_k" -le "$rows_max" ] || shard_usage
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
  shard_row "$from_table" "$shard_k" "$col" "$shards"
  exit $?
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/gate-shard-main.XXXXXX")
trap 'rm -rf "$work"' EXIT
SHARD_IDS_OUT="$work/ids" shard_partition "$suite" "$census" "$shards" "$timing" "$only" "$iso_on" "$iso" "$iso_extra" > "$work/table"
prc=$?
[ "$prc" = "0" ] || exit "$prc"

case "$mode" in
  table)  cat "$work/table" ;;
  digest) shard_sha256 < "$work/table" ;;
  shard)
    shard_row "$work/table" "$shard_k" "$col" "$shards"
    exit $? ;;
  check)
    if [ -n "$from_table" ]; then
      shard_check "$from_table" "$work/ids" "$((shards + extra))"
    else
      shard_check "$work/table" "$work/ids" "$((shards + $(awk -F '\t' -v n="$shards" '$1 > n' "$work/table" | grep -c .)))"
    fi
    exit $? ;;
esac
