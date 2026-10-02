# stall-class.awk — the stall classifier: one ledger in, the stall labels of
# each segment out.
#
#   LC_ALL=C awk -v mode=last -v root=<root> -f stall-class.awk <ledger>
#   LC_ALL=C awk -v mode=all  -v root=<root> -f stall-class.awk <ledger>
#
# THREE CALLERS, ONE FILE. The gate's snapshot builder runs `mode=last` for the
# `stalls` array, the morning report runs `mode=all` for the label history, and
# a replay after landing runs either. A second copy of these rules anywhere is a
# second answer to "which segments are stalled".
#
# STATELESS. Nothing is written — no cache, no state file, no output other than
# stdout. Every call re-derives everything from the one ledger it is handed, so
# two calls on the same ledger print the same bytes.
#
# FAILURE IS OPEN, AND IT IS THE CALLER'S TO SHOW. A non-zero exit is read by the
# gate as an empty `stalls` array plus one warning line. A wrong answer that
# exits 0 is the failure that nothing downstream can catch, so the grammar below
# is held to the POSIX awk subset that every host awk reads the same way: none
# of the GNU extensions (the replacement, sorting and time functions, the length
# of an array), no word-boundary escapes, no regex interval expressions, no
# character classes in brackets. The test suite greps this file for each of
# those spellings. An awk without interval support reads an interval as literal text, so
# a hex check spelled with one makes every review HEAD malformed, every row a
# break row, and the array silently empty — an exit 0. Lengths are taken with
# `length()` and hex is tested with a negated bracket instead.
#
# THE ROWS READ ARE TWO SERIES AND NO OTHER: `- \`cycle\` |` rows, and
# `- \`stage-result\` |` rows whose `종류` is `implement`. `segment` rows, the
# manifest, git and the worktree are never read. A key that occurs twice in one
# row is read at its LAST value, and the key is matched after its leading spaces
# are dropped, which is how the gate's own row reader reads a field.
#
# `mode=last` prints the body of the `stalls` array: one JSON object per
# (segment, class) that holds on the segment's last remaining row and has not
# been consumed, objects separated by a comma and a newline. `mode=all` prints
# one tab-separated line per labelled (segment, row, class):
#   segment, ledger line, cycle, class, consuming line or `-`, `현재` or `-`.
# Projecting the `현재` lines of `mode=all` onto (segment, class, cycle) gives
# `mode=last` in the same order, because both are printed by the one loop in END.

BEGIN {
  bad = 0
  if (mode != "last" && mode != "all") {
    print "stall-class.awk: mode must be last or all: '" mode "'" > "/dev/stderr"
    bad = 1
    exit 2
  }
  # EXACTLY ONE LEDGER. Segment ids repeat across runs, so two ledgers read as
  # one stream would splice two runs' review lineages into one sequence.
  nops = 0
  for (i = 1; i < ARGC; i++)
    if (ARGV[i] !~ /^[A-Za-z_][A-Za-z0-9_]*=/) nops++
  if (nops != 1) {
    print "stall-class.awk: exactly one ledger operand is accepted, got " nops > "/dev/stderr"
    bad = 1
    exit 2
  }
  CLS[1] = "NO_DRIFT"; CLS[2] = "SPINNING"; CLS[3] = "OSCILLATION"; CLS[4] = "DIMINISHING_RETURNS"
  for (i = 1; i < 32; i++) CTL[i] = sprintf("%c", i)
  nseg = 0; R = 0; NIR = 0
}

function trim(x) { sub(/^[ \t]+/, "", x); sub(/[ \t]+$/, "", x); return x }

function isint(x) { return (x ~ /^[0-9]+$/) }

function hexok(h) { return (length(h) >= 7 && length(h) <= 40 && h !~ /[^0-9a-f]/) }

function hasctl(x,   i) {
  for (i = 1; i < 32; i++) if (index(x, CTL[i]) > 0) return 1
  return 0
}

# Two review HEADs name the same commit when the shorter is a prefix of the
# longer. git is never called.
function same(a, b) {
  if (length(a) <= length(b)) return (substr(b, 1, length(a)) == a)
  return (substr(a, 1, length(b)) == b)
}

function parse(s,   n, P, j, f, e, k, v) {
  for (k in F) delete F[k]
  n = split(s, P, "|")
  for (j = 2; j <= n; j++) {
    f = P[j]
    sub(/^ */, "", f)
    e = index(f, "=")
    if (e == 0) continue
    k = substr(f, 1, e - 1)
    v = substr(f, e + 1)
    sub(/[ \t\r]+$/, "", v)
    F[k] = v
  }
}

function field(k) { return ((k in F) ? F[k] : "") }

# Only `\` and `"` are escaped. A segment carrying a byte below 0x20 is a break
# row and never reaches the output, so no control byte needs an escape here.
function jesc(x,   i, c, o) {
  o = ""
  for (i = 1; i <= length(x); i++) {
    c = substr(x, i, 1)
    if (c == "\\") o = o "\\\\"
    else if (c == "\"") o = o "\\\""
    else o = o c
  }
  return o
}

function member(u, r) { MB[u, ++NM[u]] = r; G[r] = u }

# The classes that hold with row `r` as the segment's last remaining row.
# Called once per row, at the moment the row arrives, so `mode=all` judges each
# row as the last row of its own time.
function judge(s, r,   k, pu, a, nf, j, u, x, ph, FE, ok) {
  k = NQ[s]
  # NO_DRIFT reads the unfolded sequence: two rows of one commit ARE its
  # condition. Neighbours, so the row before must not be a break row.
  if (k >= 2) {
    pu = Q[s, k - 1]
    if (!UB[pu]) {
      a = URP[pu]
      if (same(rhead[a], rhead[r]) && rrep[a] != rrep[r] && rcycn[r] > rcycn[a]) H[r, 1] = 1
    }
  }
  # The other three fold neighbouring rows of one commit into the last of them
  # first, walking back from the last row and stopping at a break row.
  nf = 0; ph = ""
  for (j = k; j >= 1; j--) {
    u = Q[s, j]
    if (UB[u]) break
    x = URP[u]
    if (nf > 0 && same(rhead[x], ph)) { ph = rhead[x]; continue }
    FE[++nf] = x
    ph = rhead[x]
    if (nf == 4) break
  }
  if (nf >= 3) {
    ok = 1
    for (j = 1; j <= 3; j++) {
      x = FE[j]
      if (rfabs[x] || rfp[x] != rfp[FE[1]] || rp0n[x] + rp1n[x] <= 0) ok = 0
    }
    if (ok) H[r, 2] = 1
    if (rp0n[FE[1]] == 0 && rp0n[FE[2]] == 0 && rp0n[FE[3]] == 0 \
        && rp1n[FE[3]] > 0 && rp1n[FE[1]] > 0 && rp1n[FE[1]] >= rp1n[FE[3]]) H[r, 4] = 1
  }
  if (nf >= 4) {
    if (!rfabs[FE[1]] && !rfabs[FE[2]] && !rfabs[FE[3]] && !rfabs[FE[4]] \
        && rfp[FE[1]] == rfp[FE[3]] && rfp[FE[2]] == rfp[FE[4]] && rfp[FE[1]] != rfp[FE[2]]) H[r, 3] = 1
  }
}

index($0, "- `stage-result` |") == 1 {
  parse($0)
  if (field("종류") != "implement") next
  s = field("세그먼트")
  d = field("plan_sha256")
  NIR++
  IRL[NIR] = NR
  # A digest consumes only when it is new to this segment: a process B or a
  # re-attachment carrying the same digest again did not read a label.
  IOK[NIR] = (length(d) == 64 && d !~ /[^0-9a-f]/ && !((s, d) in SEEND))
  if (d != "") SEEND[s, d] = 1
  IL[s, ++NIS[s]] = NIR
  next
}

index($0, "- `cycle` |") == 1 {
  parse($0)
  s = field("세그먼트")
  cyc = field("사이클"); p0 = field("P0"); p1 = field("P1"); head = field("리뷰 HEAD")
  rv = ("리포트 경로" in F) ? F["리포트 경로"] : field("리포트")
  rv = trim(rv)
  # Row rule 3: a report exists only as a path — it holds a `/` and ends in
  # `.md`. Anything else reads like an absent report. Relative paths are joined
  # to the root handed in, which is the gate's own logical root.
  if (index(rv, "/") > 0 && length(rv) >= 3 && substr(rv, length(rv) - 2) == ".md")
    rep = (substr(rv, 1, 1) == "/") ? rv : root "/" rv
  else
    rep = "-"
  # Row rule 4, BEFORE break marking: a rewrite of the row just before it in
  # the same segment is dropped, or two equal rows on either side of a break
  # row would become neighbours once the break row is taken out.
  key = (isint(cyc) ? cyc + 0 : cyc) SUBSEP (isint(p0) ? p0 + 0 : p0) SUBSEP (isint(p1) ? p1 + 0 : p1) SUBSEP rep
  if ((s in LASTK) && LASTK[s] == key) next
  LASTK[s] = key
  if (!(s in SEEN)) { SEEN[s] = 1; SEGS[++nseg] = s }

  r = ++R
  rline[r] = NR; rcyc[r] = cyc; rhead[r] = head; rrep[r] = rep
  rcycn[r] = cyc + 0; rp0n[r] = p0 + 0; rp1n[r] = p1 + 0
  if (("발견 지문" in F) && F["발견 지문"] != "-" && F["발견 지문"] != "(미상)") { rfabs[r] = 0; rfp[r] = F["발견 지문"] }
  else { rfabs[r] = 1; rfp[r] = "" }
  SURV[s, ++NS[s]] = r; SPOS[r] = NS[s]

  # Row rule 5: the break rows. Each test is a grammar the row either has or
  # has not; the values are numericized only after they pass.
  br = (rep == "-" || !isint(cyc) || !isint(p0) || !isint(p1) || !hexok(head) || hasctl(s))
  if (br) {
    u = ++NU; UB[u] = 1; URP[u] = r; member(u, r); Q[s, ++NQ[s]] = u
    next
  }
  # Row rule 5b: a break row right before this one, of a well-formed HEAD of
  # the same commit, is absorbed — it leaves the sequence and joins this row's
  # group instead of breaking the window.
  absorbed = 0
  if (NQ[s] >= 1) {
    pu = Q[s, NQ[s]]
    if (UB[pu] && hexok(rhead[URP[pu]]) && same(rhead[URP[pu]], head)) { absorbed = URP[pu]; NQ[s]-- }
  }
  # Row rule 6: one review counts once. The same cycle number or the same
  # report on the remaining row just before replaces that row, and the group's
  # representative is its last row.
  if (NQ[s] >= 1 && !UB[Q[s, NQ[s]]]) {
    pu = Q[s, NQ[s]]; a = URP[pu]
    if (rcycn[a] == rcycn[r] || rrep[a] == rep) {
      if (absorbed) member(pu, absorbed)
      member(pu, r); URP[pu] = r
      judge(s, r)
      next
    }
  }
  u = ++NU; UB[u] = 0; URP[u] = r
  if (absorbed) member(u, absorbed)
  member(u, r)
  Q[s, ++NQ[s]] = u
  judge(s, r)
  next
}

# The first new implement digest of segment `s` after line `from` and before
# line `to` (0 means the end of the ledger), or 0.
function consumer(s, from, to,   m, x) {
  for (m = 1; m <= NIS[s]; m++) {
    x = IL[s, m]
    if (IRL[x] <= from) continue
    if (to > 0 && IRL[x] >= to) break
    if (IOK[x]) return IRL[x]
  }
  return 0
}

END {
  if (bad) exit 2
  nout = 0
  for (si = 1; si <= nseg; si++) {
    s = SEGS[si]
    for (j = 1; j <= NQ[s]; j++) {
      u = Q[s, j]
      if (UB[u]) continue
      rep = URP[u]
      for (c = 1; c <= 4; c++) {
        # The window opens at the EARLIEST row of the group that already held
        # this class: a plan made between two rows that both held it saw the
        # label, and a plan made before a correction that first raised it did
        # not. The label's own row is the representative when it holds the
        # class, and otherwise the last earlier row that did.
        st = 0; lrow = 0
        for (m = 1; m <= NM[u]; m++) {
          x = MB[u, m]
          if ((x, c) in H) { if (!st) st = x; lrow = x }
        }
        if (!st) continue
        if ((rep, c) in H) lrow = rep
        p = SPOS[lrow]
        endl = (p < NS[s]) ? rline[SURV[s, p + 1]] : 0
        cons = consumer(s, rline[st], endl)
        cur = (j == NQ[s] && lrow == rep && cons == 0)
        if (mode == "all") {
          printf "%s\t%d\t%s\t%s\t%s\t%s\n", s, rline[lrow], rcyc[lrow], CLS[c], (cons ? cons : "-"), (cur ? "현재" : "-")
        } else if (cur) {
          if (nout++) printf ",\n"
          printf "    {\"세그먼트\": \"%s\", \"부류\": \"%s\", \"사이클\": \"%s\", \"처분\": \"지시\"}", jesc(s), CLS[c], rcyc[rep]
        }
      }
    }
  }
  if (nout) printf "\n"
}
