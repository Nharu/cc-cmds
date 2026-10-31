# pair-residue.awk — the pair-cleanup reader: one ledger in, the pairs whose
# cleanup has not succeeded out.
#
#   LC_ALL=C awk -f pair-residue.awk <ledger>
#   LC_ALL=C awk -v mode=pending [-v disp=<dispatch id>] -f pair-residue.awk <ledger>
#   LC_ALL=C awk -v mode=open-free -v disp=<dispatch id> -v row=<n> -f pair-residue.awk <ledger>
#   LC_ALL=C awk -v mode=start-free -v open=<line> -f pair-residue.awk <ledger>
#
# ONE READER OF THE `짝 정리` SERIES. The morning report and the gate's
# `pair-residue` verb print the default mode; the gate's cleanup picks its pairs
# with `pending` and decides its two conditional writes, inside the ledger lock,
# with `open-free` and `start-free`. A second copy of the pairing rule anywhere
# is a second answer to "which external state is still on".
#
# STATELESS. Nothing is written — no cache, no state file, no output other than
# stdout. Every call re-derives everything from the one ledger it is handed, so
# two calls on the same ledger print the same bytes.
#
# THE GRAMMAR IS THE POSIX AWK SUBSET, for the reason `stall-class.awk` gives:
# an exit 0 with a wrong answer is the failure nothing downstream catches. No
# GNU extensions, no regex interval expressions, no bracket character classes.
#
# THE ROWS READ ARE ONE SERIES AND NO OTHER: `- \`짝 정리\` |` rows. Fields are
# split on ` | `, a key is matched after its leading spaces are dropped, and a
# key that occurs twice in one row is read at its LAST value. Three states:
#   상태=열림  — 파견, 행, 정리: a pair opened right before the act ran;
#   상태=시작  — 열림=<line>: the cleanup of the open at that ledger line began;
#   상태=결과  — 열림=<line>, 결과=성공|실패, rc: how that cleanup ended.
# `열림=<n>` is the awk line number of the open row, which is how a start and a
# result are paired with their open. An open that repeats for the same unit
# after an earlier result is a new pair with its own line.
#
# The default mode prints one tab-separated line per open whose cleanup has no
# `결과=성공`, in ledger order:
#   dispatch id, row ordinal, cleanup argv, and one of
#   `실패 rc=<n|->` (a result row said 실패), `호출중단` (a start with no result:
#   the call is running or died mid-call), `미호출` (no start at all).
# `pending` prints `<line>\t<dispatch id>\t<row>\t<argv>` for each open with
# neither a start nor a result, narrowed to one dispatch id when `disp` is set.
# `open-free` exits 0 when no open of (disp, row) is still without a result,
# and 1 otherwise. `start-free` exits 0 when no start or result row names the
# open at line `open`, and 1 otherwise. A bad call exits 2.

BEGIN {
  if (mode == "") mode = "residue"
  if (mode != "residue" && mode != "pending" && mode != "open-free" && mode != "start-free") {
    print "pair-residue.awk: mode must be residue, pending, open-free or start-free: '" mode "'" > "/dev/stderr"
    bad = 1
    exit 2
  }
  # EXACTLY ONE LEDGER. Line numbers pair the rows, and two ledgers read as one
  # stream would number the second ledger's rows after the first's.
  nops = 0
  for (i = 1; i < ARGC; i++)
    if (ARGV[i] !~ /^[A-Za-z_][A-Za-z0-9_]*=/) nops++
  if (nops != 1) {
    print "pair-residue.awk: exactly one ledger operand is accepted, got " nops > "/dev/stderr"
    bad = 1
    exit 2
  }
  FS = " [|] "
  n = 0; taken = 0
}

index($0, "- `짝 정리` |") == 1 {
  st = ""; dp = ""; rw = ""; cl = ""; op = ""; res = ""; rc = ""
  for (i = 2; i <= NF; i++) {
    f = $i
    sub(/^ +/, "", f); sub(/ +$/, "", f)
    p = index(f, "=")
    if (p == 0) continue
    k = substr(f, 1, p - 1); v = substr(f, p + 1)
    if (k == "상태") st = v
    else if (k == "파견") dp = v
    else if (k == "행") rw = v
    else if (k == "정리") cl = v
    else if (k == "열림") op = v
    else if (k == "결과") res = v
    else if (k == "rc") rc = v
  }
  if (st == "열림") {
    n++; L[n] = NR; D[NR] = dp; W[NR] = rw; C[NR] = cl
    if (mode == "open-free" && dp == disp && rw == row) O[NR] = 1
  } else if (st == "시작") {
    S[op] = 1
    if (op == open) taken = 1
  } else if (st == "결과") {
    R[op] = res; RC[op] = rc
    if (op == open) taken = 1
  }
}

END {
  if (bad) exit 2
  if (mode == "open-free") {
    for (l in O) if (!(l in R)) exit 1
    exit 0
  }
  if (mode == "start-free") exit (taken ? 1 : 0)
  for (i = 1; i <= n; i++) {
    l = L[i]
    if (mode == "pending") {
      if ((l in S) || (l in R)) continue
      if (disp != "" && D[l] != disp) continue
      printf "%s\t%s\t%s\t%s\n", l, D[l], W[l], C[l]
      continue
    }
    if (l in R) {
      if (R[l] == "성공") continue
      state = "실패 rc=" (RC[l] == "" ? "-" : RC[l])
    } else if (l in S) {
      state = "호출중단"
    } else {
      state = "미호출"
    }
    printf "%s\t%s\t%s\t%s\n", D[l], W[l], C[l], state
  }
}
