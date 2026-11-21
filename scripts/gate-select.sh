#!/usr/bin/env bash
# The gate sections a change between two commits needs, read off the change.
#
# A PULL REQUEST RUNS THE SECTIONS THIS PICKS, NOT THE WHOLE SUITE. Its green is
# therefore not a whole-suite pass: the whole suite runs on master on a
# schedule (`scripts/gate-full.sh`), and that run is what catches a regression
# this selection did not reach.
#
# Only git objects are read: the changed paths come from `git diff`, every file
# from `git show <commit>:<path>` or `git archive`, and nothing in the working
# tree is looked at. The steps, in the order they are taken:
#
#   1. Changed files. Only paths the head commit's `gate.yml` names under
#      `pull_request.paths` count, matched with GitHub's glob meaning (`*` stays
#      inside one directory, `**` crosses them). The filter is read with
#      mikefarah/yq after `explode(.)`.
#   2. The files of the selection machinery itself mean the whole suite.
#   3. `Makefile`: a changed line, or the target or variable holding it, whose
#      name carries `gate`, `GATE` or `isolation` means the whole suite; any
#      other Makefile change is ignored.
#   4. `scripts/test-gate.sh`: a section whose body changed is picked, found by
#      comparing the `--digests` of the two commits (both indexed by the head's
#      code). In the head (before `# --- preamble-end ---`) comment and blank
#      lines are ignored; `pre_base` means the whole suite, `pre_<group>` the
#      sections of that group, any other head function the sections that name
#      it (following the head functions that call it), and a statement outside
#      every function the whole suite. The tail (after
#      `# --- epilogue-begin ---`) and a container block with no section marker
#      mean the whole suite.
#   5. Orchestrator files become nodes. `gate.sh` and the files it sources at
#      top level (read off its `. "$GATE_DIR/<file>"` lines) form the gate
#      process; their function definitions, top-level assignments (a
#      multi-line array runs to its `)` line) and the `case "$verb"` arms of
#      `gate_main` are nodes. Every other orchestrator file is one file node.
#      An added or changed line is placed in the head, a deleted one in the
#      base; comment and blank lines are ignored, and a top-level statement of
#      a gate-process file that is none of the above means the whole suite.
#   6. A section covers a node when its banner `covers:` names it (function
#      name, verb, a file's base name without its last extension), or when its
#      body holds the node's word (function name, variable name, file name) as
#      a whole word.
#   7. From each changed node the callers are walked breadth first. A caller is
#      a node whose body holds the node's word; function and variable words
#      only link gate-process nodes, a file name links any node. The walk stops
#      at a covered node and picks its sections. Reaching a gate-process node
#      no one calls, with no covered node on the way, means the whole suite. A
#      file node outside the gate process that no one names picks nothing: the
#      suite does not run it.
#   8. The picked sections are closed over the sections they `needs:`
#      (predecessors only).
#
# The banner fields and section boundaries are read here directly, and the set
# of section ids read that way must equal the head suite's own `--list`;
# otherwise the change cannot be judged. The closure of step 8 must equal the
# one the head suite's own reader gives for the same picks
# (`--sections <ids> --estimate`, which runs nothing), or the change cannot be
# judged either; a head suite that does not know `--estimate` leaves nothing
# to compare with, and the check is skipped with a line saying so.
#
# ONE CALL HAS A TIME CAP. A pull request calls this once and the failure
# report once per candidate merge, each over a suite of tens of thousands of
# lines, so a call that hangs would hold the job until the runner's own limit.
# Past `GATE_SELECT_TIMEOUT` seconds (300 by default) every process the call
# started is stopped and the call ends as a change that cannot be judged.
#
# Usage:
#   bash scripts/gate-select.sh --base <commit> [--head <commit>]
#       the head defaults to HEAD. The first stdout line is
#       `전량<TAB><reason>` or `절<TAB><comma-separated section ids>` (the list
#       may be empty); stderr carries one
#       `gate-select: <file>:<node> → <sections | 전량 — reason>` line per
#       changed unit
#   bash scripts/gate-select.sh --self-test
#
# Exit codes: 0 a verdict on stdout, 2 usage, or a change that cannot be judged
# (an unreadable commit, no usable yq, an index that disagrees with `--list`);
# the caller reads a nonzero exit as the whole suite.

set -uo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)

SEL_SUITE=scripts/test-gate.sh
SEL_ORCH=plugins/cc-cmds/orchestrator
SEL_MECH=".github/workflows/gate.yml scripts/gate-select.sh scripts/gate-full.sh scripts/gate-shard.sh scripts/gate-timing.sh scripts/gate-isolation.sh scripts/ci-duration.sh scripts/ci-duration-budget.tsv scripts/gate-timing.tsv"
sel_q="'"

sel_usage() {
  printf 'gate-select: 사용법 — --base <커밋> [--head <커밋>] / --self-test\n' >&2
  exit 2
}

sel_die() {
  printf 'gate-select: 판정할 수 없습니다 — %s\n' "$1" >&2
  exit 2
}

sel_unit() {
  printf 'gate-select: %s:%s → %s\n' "$1" "$2" "$3" >&2
}

# One unit that means the whole suite ends the selection.
sel_full() {
  sel_unit "$1" "$2" "전량 — $3"
  printf '전량\t%s\n' "$3"
  exit 0
}

sel_label() {
  case "$1" in
    F:*) printf '%s()' "${1#F:}" ;;
    V:*) printf '%s=' "${1#V:}" ;;
    B:*) printf 'gate_main %s)' "${1#B:}" ;;
    P:*) printf '(파일)' ;;
    *)   printf '%s' "$1" ;;
  esac
}

# GitHub `paths` semantics: `*` does not cross a separator, `**` does. The same
# conversion as `scripts/lint-ci-scope-binding.sh`, written out here because
# that file runs its checks at top level and cannot be sourced.
sel_glob_body() {
  local g=$1 out='' i=0 n c
  n=${#g}
  while [ "$i" -lt "$n" ]; do
    c=${g:$i:1}
    case "$c" in
      '*')
        if [ "${g:$((i + 1)):1}" = '*' ]; then
          out="$out.*"
          i=$((i + 2))
          continue
        fi
        out="$out[^/]*"
        ;;
      '?') out="$out[^/]" ;;
      '.'|'^'|'$'|'('|')'|'['|']'|'{'|'}'|'+'|'|'|'\\') out="$out\\$c" ;;
      *) out="$out$c" ;;
    esac
    i=$((i + 1))
  done
  printf '%s\n' "$out"
}

# The line numbers a change touches in one file: the deleted lines as base line
# numbers into <del>, the added lines as head line numbers into <add>.
sel_hunks() {
  local base="$1" head="$2" path="$3" del="$4" add="$5"
  : > "$del"; : > "$add"
  git -c core.quotepath=off diff --no-renames --no-ext-diff --no-color -U0 "$base" "$head" -- "$path" > "$W/hunk" || return 1
  awk -v D="$del" -v A="$add" '
    /^@@ / {
      m = $2; sub(/^-/, "", m); n = split(m, a, ","); s = a[1] + 0; c = (n > 1 ? a[2] + 0 : 1)
      for (i = 0; i < c; i++) print s + i > D
      m = $3; sub(/^\+/, "", m); n = split(m, a, ","); s = a[1] + 0; c = (n > 1 ? a[2] + 0 : 1)
      for (i = 0; i < c; i++) print s + i > A
    }' "$W/hunk"
}

# The words of a line, one `<node><TAB><word>` row per word not yet seen for
# that node. A word is a run of characters between shell punctuation, with
# leading and trailing dots and dashes trimmed; a word holding a dot or a dash
# also yields its parts, so `run.sh` gives `run.sh`, `run` and `sh`. Bytes
# outside ASCII stay inside words, so a file name in Hangul is one word.
sel_awk_words='
function put(node, t,   k) {
  if (t == self) return
  k = node SUBSEP t
  if (k in seen) return
  seen[k] = 1
  print node "\t" t
}
function words(node, s,   n, a, i, t, m, b, j) {
  gsub(/[[:space:]"`$(){}<>|;&=,:\/!*?#@~^+%\\]/, " ", s)
  gsub(/\[/, " ", s); gsub(/\]/, " ", s); gsub(q, " ", s)
  n = split(s, a, " ")
  for (i = 1; i <= n; i++) {
    t = a[i]; sub(/^[.-]+/, "", t); sub(/[.-]+$/, "", t)
    if (t == "") continue
    put(node, t)
    if (t ~ /[.-]/) {
      m = split(t, b, /[.-]+/)
      for (j = 1; j <= m; j++) if (b[j] != "") put(node, b[j])
    }
  }
}
'

# The node map of a shell file. `map` prints `<line><TAB><class><TAB><name>`
# for each line number listed in <want>, the class being IGN (comment or
# blank), F (inside a function), V (a top-level assignment), B (a `case
# "$verb"` arm of `gate_main`) or TOP (any other top-level statement). `tok`
# prints the word rows of every F, V and B node, comment lines left out. A
# nonzero <stop> reads only the lines above it.
sel_shmap() {
  LC_ALL=C awk -v mode="$1" -v want="$3" -v maxl="$4" -v q="$sel_q" "$sel_awk_words"'
    BEGIN { if (mode == "map") while ((getline l < want) > 0) w[l + 0] = 1 }
    function out() {
      if (mode == "map") { if (NR in w) print NR "\t" (ign ? "IGN" : cls) "\t" nm; return }
      if (ign || cls == "TOP") return
      self = (cls == "B" ? "" : nm)
      words(cls ":" nm, line)
    }
    {
      if (maxl > 0 && NR >= maxl) exit
      line = $0
      ign = (line ~ /^[ \t]*$/ || line ~ /^[ \t]*#/)
      isdef = (line ~ /^(function[ \t]+)?[A-Za-z_][A-Za-z0-9_:.-]*[ \t]*\(\)/ || line ~ /^function[ \t]+[A-Za-z_][A-Za-z0-9_:.-]*[ \t]*\{/)
      if (isdef && !fcont && arr == "") {
        nm = line; sub(/^function[ \t]+/, "", nm); sub(/[ \t]*(\(\)|\{).*$/, "", nm)
        fn = nm; cls = "F"; incase = 0; verb = ""; paren = 0; end1 = 0
        rest = line; sub(/^[^({]*(\(\))?[ \t]*/, "", rest)
        if (rest ~ /\\$/) fcont = 1
        else if (rest ~ /^\{/ && rest ~ /\}[ \t]*(#.*)?$/) end1 = 1
        else if (rest ~ /^\(/) paren = 1
        out()
        if (end1) fn = ""
        next
      }
      if (fn != "") {
        cls = "F"; nm = fn
        if (fn == "gate_main") {
          if (line ~ /^  case "\$verb" in/) incase = 1
          else if (incase && line ~ /^  esac/) { incase = 0; verb = "" }
          else if (incase && line ~ /^    [^ \t#;)][^)]*\)/) { verb = line; sub(/^    \(?/, "", verb); sub(/\).*$/, "", verb) }
          if (incase && verb != "") { cls = "B"; nm = verb }
        }
        out()
        if (fcont) {
          if (line !~ /\\$/) { fcont = 0; if (line ~ /\}[ \t]*(#.*)?$/) fn = "" }
        } else if (paren ? (line ~ /^\)/) : (line ~ /^\}/)) fn = ""
        next
      }
      cls = "TOP"; nm = ""
      if (arr != "") {
        cls = "V"; nm = arr
        if (line ~ /^[ \t]*\)[ \t]*(#.*)?$/) arr = ""
        out(); next
      }
      if (vcont != "") {
        cls = "V"; nm = vcont
        if (line !~ /\\$/) vcont = ""
        out(); next
      }
      if (!ign && (line ~ /^((export|readonly|declare|typeset)([ \t]+-[A-Za-z]+)*[ \t]+)?[A-Za-z_][A-Za-z0-9_]*(\[[^=]*\])?\+?=/ || line ~ /^(export|readonly|declare|typeset)([ \t]+-[A-Za-z]+)*[ \t]+[A-Za-z_][A-Za-z0-9_]*[ \t]*$/)) {
        nm = line; sub(/^(export|readonly|declare|typeset)([ \t]+-[A-Za-z]+)*[ \t]+/, "", nm); sub(/[^A-Za-z0-9_].*$/, "", nm)
        cls = "V"
        if (line ~ /=\([^)]*$/) arr = nm
        else if (line ~ /\\$/) vcont = nm
      }
      out()
    }' "$2"
}

# The word rows of the file nodes: every file listed in <list>, named by its
# path with <prefix> taken off. Blank lines are skipped, and so are comment
# lines of the hash-comment languages.
sel_ptok() {
  LC_ALL=C awk -v list="$1" -v pre="$2" -v q="$sel_q" "$sel_awk_words"'
    BEGIN {
      self = ""
      while ((getline f < list) > 0) {
        p = substr(f, length(pre) + 1); node = "P:" p; hash = (p ~ /\.(sh|py|awk)$/)
        while ((getline l < f) > 0) {
          if (l ~ /^[ \t]*$/) continue
          if (hash && l ~ /^[ \t]*#/) continue
          words(node, l)
        }
        close(f)
      }
    }'
}

# How many of the lines listed in <want> carry content: not blank, and not a
# comment when <hash> is 1.
sel_sig() {
  LC_ALL=C awk -v want="$2" -v hash="$3" '
    BEGIN { while ((getline l < want) > 0) w[l + 0] = 1 }
    (FNR in w) && $0 !~ /^[ \t]*$/ && !(hash && $0 ~ /^[ \t]*#/) { c++ }
    END { print c + 0 }' "$1"
}

# The suite index, read with the boundary rules of the suite's own selector: a
# boxed section starts at the rule line above its numbered title, a dashed one
# at its banner line, and a section is addressable only when the line after
# its title is its `# --- section: ` marker. Rows:
#   PRE <line> / EPI <line>
#   SEC <start> <end> <id or -> <group or -> <title>
#   COV <id> <word>   one `covers:` entry
#   NED <id> <dep>    one `needs:` entry
# A file without both region markers prints ERR.
sel_tg_index() {
  LC_ALL=C awk '
    function field(t, k,   v) {
      if (t !~ ("\\|[ \t]*" k ":")) return ""
      v = t
      sub(/[ \t]*---[ \t]*$/, "", v)
      sub("^.*\\|[ \t]*" k ":[ \t]*", "", v)
      sub(/[ \t]*\|.*$/, "", v)
      sub(/[ \t]+$/, "", v)
      return v
    }
    {
      if ($0 ~ /^# --- preamble-end ---$/) pre = NR
      else if ($0 ~ /^# --- epilogue-begin ---$/) epi = NR
      else if ($0 ~ /^# --- section: /) mk[NR] = $0
      else if (prev ~ /^# -+$/ && $0 ~ /^# [0-9]+[a-z]*(-[0-9]+[a-z]*)?\. /) { nb++; bound[nb] = NR - 1; tline[nb] = NR; title[nb] = $0 }
      else if ($0 ~ /^# --- [0-9]+[a-z]*(-[0-9]+[a-z]*)?\. /) { nb++; bound[nb] = NR; tline[nb] = NR; title[nb] = $0 }
      prev = $0
    }
    END {
      if (pre == 0 || epi == 0) { print "ERR"; exit 0 }
      print "PRE " pre
      print "EPI " epi
      for (i = 1; i <= nb; i++) {
        s = bound[i]
        if (s <= pre) continue
        e = (i < nb ? bound[i + 1] - 1 : epi - 1)
        if (e >= epi) e = epi - 1
        id = "-"; grp = "-"; cov = ""; ned = ""
        if ((tline[i] + 1) in mk) {
          t = mk[tline[i] + 1]
          id = t
          sub(/^# --- section:[ \t]*/, "", id); sub(/[ \t]*\|.*$/, "", id); sub(/[ \t]*---[ \t]*$/, "", id)
          g = field(t, "group"); if (g != "") grp = g
          cov = field(t, "covers"); ned = field(t, "needs")
        }
        print "SEC " s " " e " " id " " grp " " title[i]
        if (id == "-") continue
        n = split(cov, a, ",")
        for (k = 1; k <= n; k++) { c = a[k]; gsub(/^[ \t]+|[ \t]+$/, "", c); if (c != "" && c != "-") print "COV " id " " c }
        n = split(ned, a, ",")
        for (k = 1; k <= n; k++) { c = a[k]; gsub(/^[ \t]+|[ \t]+$/, "", c); if (c != "" && c != "-") print "NED " id " " c }
      }
    }' "$1"
}

# The word rows of every addressable section of the suite: `<id><TAB><word>`.
sel_stok() {
  LC_ALL=C awk -v q="$sel_q" "$sel_awk_words"'
    FNR == NR { if ($1 == "SEC" && $4 != "-") { n++; s[n] = $2 + 0; e[n] = $3 + 0; id[n] = $4 }; next }
    FNR == 1 { i = 1; self = "" }
    {
      while (i <= n && FNR > e[i]) i++
      if (i <= n && FNR >= s[i]) words(id[i], $0)
    }' "$1" "$2"
}

# Where each line listed in <want> sits in the suite: HEAD, MARK (a region
# marker line), TAIL, SEC <id>, CONT <title> (a container), BLANK or GAP (a
# line between the head and the first section).
sel_region() {
  LC_ALL=C awk -v want="$2" '
    BEGIN { while ((getline l < want) > 0) w[l + 0] = 1 }
    FNR == NR {
      if ($1 == "PRE") pre = $2 + 0
      else if ($1 == "EPI") epi = $2 + 0
      else if ($1 == "SEC") { n++; s[n] = $2 + 0; e[n] = $3 + 0; id[n] = $4; t = $0; sub(/^SEC [0-9]+ [0-9]+ [^ ]+ [^ ]+ /, "", t); ti[n] = t }
      next
    }
    (FNR in w) {
      L = FNR
      if (L < pre) { print L "\tHEAD\t-"; next }
      if (L == pre || L == epi) { print L "\tMARK\t-"; next }
      if (L > epi) { print L "\tTAIL\t-"; next }
      r = "GAP"; inf = "-"
      for (i = 1; i <= n; i++) if (L >= s[i] && L <= e[i]) { if (id[i] == "-") { r = "CONT"; inf = ti[i] } else { r = "SEC"; inf = id[i] }; break }
      if (r == "GAP" && $0 ~ /^[ \t]*$/) r = "BLANK"
      print L "\t" r "\t" inf
    }' "$1" "$3"
}

# The owner of each Makefile line listed in <want>: `<line><TAB><owner><TAB><hit>`,
# the owner being the variable or target the line belongs to (empty for none)
# and <hit> 1 when the line or its owner names gate, GATE or isolation.
sel_mkmap() {
  LC_ALL=C awk -v want="$2" '
    BEGIN { while ((getline l < want) > 0) w[l + 0] = 1 }
    {
      line = $0
      if (cont) o = cur
      else if (indef) { o = defn; if (line ~ /^endef/) indef = 0 }
      else if (line ~ /^\t/) o = tgt
      else if (line ~ /^[ \t]*(#.*)?$/) o = ""
      else if (line ~ /^define[ \t]+/) { defn = line; sub(/^define[ \t]+/, "", defn); sub(/[ \t].*$/, "", defn); o = defn; indef = 1; tgt = "" }
      else if (line ~ /^(override[ \t]+|export[ \t]+)?[A-Za-z_][A-Za-z0-9_.-]*[ \t]*(::=|:=|\?=|\+=|!=|=)/) { o = line; sub(/^(override|export)[ \t]+/, "", o); sub(/[ \t]*(::=|:=|\?=|\+=|!=|=).*$/, "", o); tgt = "" }
      else if (line ~ /^[^ \t#][^=]*:/) { o = line; sub(/:.*$/, "", o); tgt = o }
      else { o = ""; tgt = "" }
      cur = o
      cont = (line ~ /\\$/)
      if (NR in w) print NR "\t" o "\t" ((line ~ /gate|GATE|isolation/ || o ~ /gate|GATE|isolation/) ? 1 : 0)
    }' "$1"
}

# The head-function walk of the suite: from each name in <starts>, the sections
# naming it and, through every head function calling it, the sections naming
# those. A caller `pre_base` means the whole suite, a caller `pre_<group>` adds
# that group's sections. Prints `<name><TAB>FULL` or `<name><TAB>SECS<TAB><ids>`.
sel_hclimb() {
  LC_ALL=C awk -F'\t' '
    FILENAME == ARGV[1] { if ($1 ~ /^F:/) { n = substr($1, 3); if ($2 != n) callers[$2] = callers[$2] " " n }; next }
    FILENAME == ARGV[2] { st[$2] = st[$2] " " $1; next }
    FILENAME == ARGV[3] { split($1, a, " "); if (a[1] == "SEC" && a[4] != "-" && a[5] != "-") grp[a[5]] = grp[a[5]] " " a[4]; next }
    FILENAME == ARGV[4] { ns++; start[ns] = $1; next }
    function climb(s,   q, vis, h, t, x, out, n, a, i, y, full) {
      h = 1; t = 1; q[1] = s; vis[s] = 1; out = ""; full = 0
      while (h <= t && !full) {
        x = q[h++]
        out = out st[x]
        n = split(callers[x], a, " ")
        for (i = 1; i <= n; i++) {
          y = a[i]
          if (y in vis) continue
          vis[y] = 1
          if (y == "pre_base") { full = 1; break }
          if (y ~ /^pre_/) out = out grp[substr(y, 5)]
          q[++t] = y
        }
      }
      if (full) print s "\tFULL"
      else print s "\tSECS\t" out
    }
    END { for (k = 1; k <= ns; k++) climb(start[k]) }
  ' "$@"
}

# The orchestrator walk: from each node in <starts>, callers breadth first
# until a covered node. Prints `<node><TAB>FULL<TAB><root>` or
# `<node><TAB>SECS<TAB><ids>`.
sel_climb() {
  LC_ALL=C awk -F'\t' '
    FILENAME == ARGV[1] { nodes_of[$2] = nodes_of[$2] "\n" $1; next }
    FILENAME == ARGV[2] { cov[$2] = cov[$2] " " $1; next }
    FILENAME == ARGV[3] { st[$2] = st[$2] " " $1; next }
    FILENAME == ARGV[4] { ns++; start[ns] = $1; next }
    function bname(p) { sub(/^.*\//, "", p); return p }
    function kind(x) { return substr(x, 1, 1) }
    function covering(x,   k, nm, out, n, a, i, v, b, e) {
      k = kind(x); nm = substr(x, 3); out = ""
      if (k == "F" || k == "V") out = cov[nm] st[nm]
      else if (k == "B") {
        n = split(nm, a, "|")
        for (i = 1; i <= n; i++) { v = a[i]; gsub(/[" ]/, "", v); out = out cov[v] }
      } else { b = bname(nm); e = b; sub(/\.[^.]*$/, "", e); out = cov[e] st[b] }
      return out
    }
    function edgeword(x,   k) {
      k = kind(x)
      if (k == "F" || k == "V") return substr(x, 3)
      if (k == "P") return bname(substr(x, 3))
      return ""
    }
    function climb(s,   q, vis, h, t, x, c, w, n, a, i, y, callers, sel, full) {
      h = 1; t = 1; q[1] = s; vis[s] = 1; sel = ""; full = ""
      while (h <= t) {
        x = q[h++]
        c = covering(x)
        if (c != "") { sel = sel c; continue }
        w = edgeword(x); callers = 0
        if (w != "" && (w in nodes_of)) {
          n = split(nodes_of[w], a, "\n")
          for (i = 1; i <= n; i++) {
            y = a[i]
            if (y == "" || y == x) continue
            if (kind(x) != "P" && kind(y) == "P") continue
            callers++
            if (!(y in vis)) { vis[y] = 1; q[++t] = y }
          }
        }
        if (callers == 0 && kind(x) != "P") { full = x; break }
      }
      if (full != "") print s "\tFULL\t" full
      else print s "\tSECS\t" sel
    }
    END { for (k = 1; k <= ns; k++) climb(start[k]) }
  ' "$@"
}

# The picked sections closed over their `needs:` predecessors, in suite order,
# comma-joined.
sel_close() {
  LC_ALL=C awk '
    FNR == NR {
      if ($1 == "SEC" && $4 != "-") { n++; ord[n] = $4 }
      else if ($1 == "NED") dep[$2] = dep[$2] " " $3
      next
    }
    { m = split($0, a, /[ ,]+/); for (i = 1; i <= m; i++) if (a[i] != "" && !(a[i] in pk)) { pk[a[i]] = 1; q[++t] = a[i] } }
    END {
      h = 1
      while (h <= t) {
        x = q[h++]; m = split(dep[x], a, " ")
        for (i = 1; i <= m; i++) if (!(a[i] in pk)) { pk[a[i]] = 1; q[++t] = a[i] }
      }
      out = ""
      for (i = 1; i <= n; i++) if (ord[i] in pk) out = out (out == "" ? "" : ",") ord[i]
      print out
    }' "$1" "$2"
}

sel_join() {
  tr ' ' '\n' | grep -v '^$' | sort -u | paste -s -d, -
}

# THE CLOSURE IS READ TWICE AND MUST AGREE. The `needs:` fields of step 8 come
# from this file's own banner reader, while a cut is closed by the suite's.
# Two readers that disagree send a picked section to CI without a predecessor
# it needs, or with one it does not, and the id sets of `--list` still match;
# so a disagreement is a change that cannot be judged. <want> is the closure
# step 8 computed, comma-joined.
sel_check_closure() {
  local want="$1" req rc=0
  req=$(tr ', ' '\n\n' < "$W/picked" | grep -v '^$' | sort -u | paste -s -d, -)
  bash "$W/h/$SEL_SUITE" --sections "$req" --estimate > "$W/est.out" 2> "$W/est.err" || rc=$?
  if [ "$rc" != 0 ]; then
    if grep -q -e '모르는 인자' "$W/est.err" "$W/est.out"; then
      sel_unit "$SEL_SUITE" "needs:" "(대조 생략) — 헤드 스위트가 --estimate 를 모릅니다"
      return 0
    fi
    sel_die "헤드 스위트의 --sections --estimate 가 실패했습니다 (종료 $rc)"
  fi
  # The estimate's rows are `<id><TAB><seconds><TAB><source>`; the head and the
  # group preludes are the `@` rows.
  awk -F'\t' 'NF >= 2 && $1 !~ /^@/ && $1 !~ /^test-gate:/ { print $1 }' "$W/est.out" | sort -u > "$W/est.ids"
  printf '%s\n' "$want" | tr ',' '\n' | grep -v '^$' | sort -u > "$W/own.ids"
  if ! cmp -s "$W/est.ids" "$W/own.ids"; then
    sel_die "직접 읽은 needs 폐포 [$(paste -s -d, - < "$W/own.ids")] 가 헤드 스위트의 폐포 [$(paste -s -d, - < "$W/est.ids")] 와 다릅니다"
  fi
}

# The whole call in a child of its own process group, so a cap that runs out
# stops every process the selection started rather than this shell alone, and
# the verdict goes through a file, so a stopped child leaves no half answer on
# stdout. The child's standard error is this one's.
sel_capped() {
  local cap="${GATE_SELECT_TIMEOUT:-300}" out pid rc=0 ticks=0
  case "$cap" in
    ''|*[!0-9]*|0) sel_die "GATE_SELECT_TIMEOUT 은 1 이상의 초 수여야 합니다: 「${cap}」" ;;
  esac
  out=$(mktemp "${TMPDIR:-/tmp}/gate-select-out.XXXXXX") || sel_die "임시 파일을 만들지 못했습니다"
  set -m
  GATE_SELECT_CAPPED=1 bash "$script_dir/$(basename "$0")" "$@" > "$out" &
  pid=$!
  set +m
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$ticks" -ge "$((cap * 5))" ]; then
      kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      rm -f "$out"
      sel_die "한 호출의 시간 상한 ${cap}초를 넘었습니다"
    fi
    sleep 0.2
    ticks=$((ticks + 1))
  done
  wait "$pid" || rc=$?
  cat "$out"
  rm -f "$out"
  exit "$rc"
}

# --- the steps ---------------------------------------------------------------

sel_makefile() {
  local row ln owner
  sel_hunks "$BASE" "$HEAD" Makefile "$W/mk.del" "$W/mk.add" || sel_die "Makefile 의 변경을 읽지 못했습니다"
  git show "$BASE:Makefile" > "$W/mk.base" 2>/dev/null || : > "$W/mk.base"
  git show "$HEAD:Makefile" > "$W/mk.head" 2>/dev/null || : > "$W/mk.head"
  { sel_mkmap "$W/mk.base" "$W/mk.del"; sel_mkmap "$W/mk.head" "$W/mk.add"; } > "$W/mk.rows"
  row=$(awk -F'\t' '$3 == 1 { print $1 "\t" $2; exit }' "$W/mk.rows")
  if [ -n "$row" ]; then
    ln=${row%%$'\t'*}; owner=${row#*$'\t'}
    sel_full Makefile "${owner:-줄 $ln}" "Makefile 의 gate 계열 줄·타깃·변수가 바뀌었습니다"
  fi
  awk -F'\t' '{ print ($2 == "" ? "-" : $2) }' "$W/mk.rows" | sort -u > "$W/mk.owners"
  while IFS= read -r owner; do
    sel_unit Makefile "$owner" "(없음) — gate 계열이 아닌 Makefile 변경"
  done < "$W/mk.owners"
}

# The head suite, its index and word tables, checked against its own `--list`.
sel_load_suite() {
  mkdir -p "$W/h/scripts"
  git show "$HEAD:$SEL_SUITE" > "$W/h/$SEL_SUITE" 2>/dev/null || sel_die "헤드에 $SEL_SUITE 이 없습니다"
  sel_tg_index "$W/h/$SEL_SUITE" > "$W/idx.head"
  grep -q '^ERR' "$W/idx.head" && sel_die "헤드 스위트에서 구역 표지를 찾지 못했습니다"
  bash "$W/h/$SEL_SUITE" --list > "$W/list" 2>"$W/list.err" || sel_die "헤드 스위트의 --list 가 실패했습니다"
  awk '{ print $1 }' "$W/list" | sort > "$W/ids.list"
  awk '$1 == "SEC" && $4 != "-" { print $4 }' "$W/idx.head" | sort > "$W/ids.own"
  cmp -s "$W/ids.list" "$W/ids.own" || sel_die "직접 읽은 절 id 집합이 헤드 스위트의 --list 와 다릅니다"
  awk '$1 == "COV" { print $2 "\t" $3 }' "$W/idx.head" > "$W/scov"
  sel_stok "$W/idx.head" "$W/h/$SEL_SUITE" > "$W/stok"
}

sel_suite() {
  local id ln reg inf cls nm r list pre
  if ! git show "$BASE:$SEL_SUITE" > "$W/tg.base" 2>/dev/null; then
    sel_full "$SEL_SUITE" "(파일)" "베이스에 스위트가 없습니다"
  fi
  sel_tg_index "$W/tg.base" > "$W/idx.base"
  grep -q '^ERR' "$W/idx.base" && sel_die "베이스 스위트에서 구역 표지를 찾지 못했습니다"

  # Section bodies: the digests of both commits, both indexed by the head's code.
  bash "$W/h/$SEL_SUITE" --digests > "$W/dig.head" 2>"$W/dig.err" || sel_die "헤드 스위트의 --digests 가 실패했습니다"
  bash "$W/h/$SEL_SUITE" --digests --from "$W/tg.base" > "$W/dig.base" 2>>"$W/dig.err" || sel_die "베이스 스위트의 --digests 가 실패했습니다"
  awk -F'\t' 'FNR == NR { b[$1] = $2; next } !($1 in b) || b[$1] != $2 { print $1 }' "$W/dig.base" "$W/dig.head" > "$W/tg.secs"
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    sel_unit "$SEL_SUITE" "$id" "$id"
    printf '%s\n' "$id" >> "$W/picked"
  done < "$W/tg.secs"

  # Every other changed line, placed in its own commit's index.
  sel_hunks "$BASE" "$HEAD" "$SEL_SUITE" "$W/tg.del" "$W/tg.add" || sel_die "스위트의 변경을 읽지 못했습니다"
  sel_region "$W/idx.base" "$W/tg.del" "$W/tg.base" > "$W/reg.base"
  sel_region "$W/idx.head" "$W/tg.add" "$W/h/$SEL_SUITE" > "$W/reg.head"
  for side in base head; do
    while IFS=$'\t' read -r ln reg inf; do
      case "$reg" in
        MARK) sel_full "$SEL_SUITE" "줄 $ln" "스위트의 구역 표지 줄이 바뀌었습니다" ;;
        TAIL) sel_full "$SEL_SUITE" "줄 $ln" "스위트의 꼬리(epilogue-begin 뒤)가 바뀌었습니다" ;;
        CONT) sel_full "$SEL_SUITE" "줄 $ln" "표지 없는 컨테이너 절 「${inf}」 이 바뀌었습니다" ;;
        GAP)  sel_full "$SEL_SUITE" "줄 $ln" "머리와 첫 절 사이의 줄이 바뀌었습니다" ;;
      esac
    done < "$W/reg.$side"
  done

  # The head: comment and blank lines aside, a function or a top-level statement.
  : > "$W/hstart"; : > "$W/hm.all"
  for side in base head; do
    awk -F'\t' '$2 == "HEAD" { print $1 }' "$W/reg.$side" > "$W/hw.$side"
    [ -s "$W/hw.$side" ] || continue
    if [ "$side" = base ]; then f="$W/tg.base"; idx="$W/idx.base"; else f="$W/h/$SEL_SUITE"; idx="$W/idx.head"; fi
    pre=$(awk '$1 == "PRE" { print $2 }' "$idx")
    sel_shmap map "$f" "$W/hw.$side" "$pre" >> "$W/hm.all"
  done
  # One unit per function, not one per changed line of it.
  awk -F'\t' '$2 != "F" || !seen[$3]++' "$W/hm.all" > "$W/hm.u"
  while IFS=$'\t' read -r ln cls nm; do
    case "$cls" in
      IGN) ;;
      F)
        case "$nm" in
          pre_base) sel_full "$SEL_SUITE" "pre_base()" "스위트 머리의 pre_base 가 바뀌었습니다" ;;
          pre_*)
            list=$(awk -v g="${nm#pre_}" '$1 == "SEC" && $4 != "-" && $5 == g { print $4 }' "$W/idx.head" | sel_join)
            sel_unit "$SEL_SUITE" "$nm()" "${list:-(없음)}"
            printf '%s\n' "$list" >> "$W/picked" ;;
          *) printf '%s\n' "$nm" >> "$W/hstart" ;;
        esac ;;
      *) sel_full "$SEL_SUITE" "줄 $ln" "스위트 머리의 함수 밖 최상위 문장이 바뀌었습니다" ;;
    esac
  done < "$W/hm.u"
  if [ -s "$W/hstart" ]; then
    sort -u "$W/hstart" -o "$W/hstart"
    pre=$(awk '$1 == "PRE" { print $2 }' "$W/idx.head")
    sel_shmap tok "$W/h/$SEL_SUITE" - "$pre" > "$W/htok"
    sel_hclimb "$W/htok" "$W/stok" "$W/idx.head" "$W/hstart" > "$W/hclimb"
    while IFS=$'\t' read -r nm r list; do
      if [ "$r" = FULL ]; then
        sel_full "$SEL_SUITE" "$nm()" "스위트 머리의 $nm 를 pre_base 가 부릅니다"
      fi
      list=$(printf '%s\n' "$list" | sel_join)
      sel_unit "$SEL_SUITE" "$nm()" "${list:-(없음)}"
      printf '%s\n' "$list" >> "$W/picked"
    done < "$W/hclimb"
  fi
}

sel_orch() {
  local f fb fh ln cls nm node r rest list file hash
  # The gate process: gate.sh and what it sources at top level, in either commit.
  git show "$HEAD:$SEL_ORCH/gate.sh" > "$W/gate.head" 2>/dev/null || : > "$W/gate.head"
  git show "$BASE:$SEL_ORCH/gate.sh" > "$W/gate.base" 2>/dev/null || : > "$W/gate.base"
  { printf '%s\n' "$SEL_ORCH/gate.sh"
    awk -v d="$SEL_ORCH" '/^(\.|source)[ \t]+"\$GATE_DIR\/[^"\/]+"/ { s = $0; sub(/^(\.|source)[ \t]+"\$GATE_DIR\//, "", s); sub(/".*$/, "", s); print d "/" s }' \
      "$W/gate.head" "$W/gate.base"
  } | sort -u > "$W/inproc"

  # The head tree of the orchestrator and its word table.
  mkdir -p "$W/t"
  git archive "$HEAD" "$SEL_ORCH" > "$W/orch.tar" 2>/dev/null || sel_die "헤드의 $SEL_ORCH 를 읽지 못했습니다"
  tar -x -f "$W/orch.tar" -C "$W/t" || sel_die "헤드의 $SEL_ORCH 를 풀지 못했습니다"
  : > "$W/ntok"
  while IFS= read -r f; do
    [ -f "$W/t/$f" ] || continue
    sel_shmap tok "$W/t/$f" - 0 >> "$W/ntok"
  done < "$W/inproc"
  find "$W/t/$SEL_ORCH" -type f | sort > "$W/all"
  awk -v pre="$W/t/" 'FNR == NR { inp[pre $0] = 1; next } !($0 in inp)' "$W/inproc" "$W/all" > "$W/pfiles"
  sel_ptok "$W/pfiles" "$W/t/" >> "$W/ntok"

  # The changed nodes.
  : > "$W/starts"
  while IFS= read -r f; do
    sel_hunks "$BASE" "$HEAD" "$f" "$W/o.del" "$W/o.add" || sel_die "$f 의 변경을 읽지 못했습니다"
    fb="$W/o.base"; fh="$W/o.head"
    git show "$BASE:$f" > "$fb" 2>/dev/null || : > "$fb"
    git show "$HEAD:$f" > "$fh" 2>/dev/null || : > "$fh"
    if grep -Fxq "$f" "$W/inproc"; then
      { sel_shmap map "$fb" "$W/o.del" 0; sel_shmap map "$fh" "$W/o.add" 0; } > "$W/o.rows"
      while IFS=$'\t' read -r ln cls nm; do
        case "$cls" in
          IGN) ;;
          TOP) sel_full "$f" "줄 $ln" "gate 프로세스 파일의 분류 밖 최상위 문장이 바뀌었습니다" ;;
          *) printf '%s:%s\t%s\n' "$cls" "$nm" "$f" >> "$W/starts" ;;
        esac
      done < "$W/o.rows"
    else
      hash=0
      case "$f" in *.sh|*.py|*.awk) hash=1 ;; esac
      if [ ! -s "$W/o.del" ] && [ ! -s "$W/o.add" ]; then
        printf 'P:%s\t%s\n' "$f" "$f" >> "$W/starts"
      elif [ "$(sel_sig "$fb" "$W/o.del" "$hash")" != "0" ] || [ "$(sel_sig "$fh" "$W/o.add" "$hash")" != "0" ]; then
        printf 'P:%s\t%s\n' "$f" "$f" >> "$W/starts"
      fi
    fi
  done < "$W/orch"
  [ -s "$W/starts" ] || return 0
  awk -F'\t' '!seen[$1]++' "$W/starts" > "$W/starts.u"
  sel_climb "$W/ntok" "$W/scov" "$W/stok" "$W/starts.u" > "$W/climb"
  while IFS=$'\t' read -r node r rest; do
    file=$(awk -F'\t' -v n="$node" '$1 == n { print $2; exit }' "$W/starts.u")
    if [ "$r" = FULL ]; then
      sel_full "$file" "$(sel_label "$node")" "덮인 노드 없이 gate 프로세스의 뿌리 $(sel_label "$rest") 에 닿았습니다"
    fi
    list=$(printf '%s\n' "$rest" | sel_join)
    sel_unit "$file" "$(sel_label "$node")" "${list:-(없음)}"
    printf '%s\n' "$rest" >> "$W/picked"
  done < "$W/climb"
}

sel_main() {
  local base="" head="HEAD" re g b f sel tg=0 mk=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --base) [ "$#" -ge 2 ] || sel_usage; base="$2"; shift 2 ;;
      --head) [ "$#" -ge 2 ] || sel_usage; head="$2"; shift 2 ;;
      *) sel_usage ;;
    esac
  done
  [ -n "$base" ] || sel_usage
  BASE=$(git rev-parse -q --verify "$base^{commit}" 2>/dev/null) || sel_die "베이스 커밋 $base 을 읽지 못했습니다"
  HEAD=$(git rev-parse -q --verify "$head^{commit}" 2>/dev/null) || sel_die "헤드 커밋 $head 을 읽지 못했습니다"
  W=$(mktemp -d "${TMPDIR:-/tmp}/gate-select.XXXXXX") || sel_die "임시 디렉터리를 만들지 못했습니다"
  trap 'rm -rf "$W"' EXIT
  # A stop from the cap still removes the scratch directory.
  trap 'exit 143' TERM

  # 1. The changed paths the gate filter names.
  git show "$HEAD:.github/workflows/gate.yml" > "$W/gate.yml" 2>/dev/null || sel_die "헤드에 .github/workflows/gate.yml 이 없습니다"
  # shellcheck source=scripts/_yq-preflight.sh
  . "$script_dir/_yq-preflight.sh"
  yq_preflight 2>/dev/null || sel_die "mikefarah/yq 가 없어 경로 필터를 읽지 못합니다"
  yq -r 'explode(.) | .["on"].pull_request.paths[]' "$W/gate.yml" > "$W/globs" 2>/dev/null || sel_die "gate.yml 의 pull_request.paths 를 읽지 못했습니다"
  [ -s "$W/globs" ] || sel_die "gate.yml 의 pull_request.paths 가 비었습니다"
  re=""
  while IFS= read -r g; do
    [ -n "$g" ] || continue
    b=$(sel_glob_body "$g")
    if [ -z "$re" ]; then re="$b"; else re="$re|$b"; fi
  done < "$W/globs"
  re="^($re)$"
  git -c core.quotepath=off diff --no-renames --name-only "$BASE" "$HEAD" > "$W/changed" || sel_die "바뀐 파일 목록을 읽지 못했습니다"
  : > "$W/files"
  while IFS= read -r f; do
    if [[ $f =~ $re ]]; then printf '%s\n' "$f" >> "$W/files"; fi
  done < "$W/changed"

  # 2. The selection machinery, and any filter path no step classifies.
  while IFS= read -r f; do
    case " $SEL_MECH " in
      *" $f "*) sel_full "$f" "(파일)" "선택 기계 장치 파일 $f 이 바뀌었습니다" ;;
    esac
  done < "$W/files"
  : > "$W/orch"; : > "$W/picked"
  while IFS= read -r f; do
    case "$f" in
      Makefile) mk=1 ;;
      "$SEL_SUITE") tg=1 ;;
      "$SEL_ORCH"/*) printf '%s\n' "$f" >> "$W/orch" ;;
      *) sel_full "$f" "(파일)" "선택 규칙이 분류하지 않는 필터 경로 $f 이 바뀌었습니다" ;;
    esac
  done < "$W/files"

  # 3. The Makefile.
  [ "$mk" = 0 ] || sel_makefile

  # 4 to 7. The suite and the orchestrator.
  if [ "$tg" = 1 ] || [ -s "$W/orch" ]; then
    sel_load_suite
    [ "$tg" = 0 ] || sel_suite
    [ ! -s "$W/orch" ] || sel_orch
  fi

  # 8. The needs closure, held to the suite's own.
  if [ -s "$W/picked" ] && [ -n "$(tr -d ', \n' < "$W/picked")" ]; then
    sel=$(sel_close "$W/idx.head" "$W/picked")
    sel_check_closure "$sel"
    printf '절\t%s\n' "$sel"
  else
    printf '절\t\n'
  fi
  exit 0
}

# --- self-test -----------------------------------------------------------------

sel_self_test() {
  local passed=0 failed=0 T R B0 self out rc s0 s1 spid
  ok()  { passed=$((passed + 1)); printf 'PASS: %s\n' "$1"; }
  bad() { failed=$((failed + 1)); printf 'FAIL: %s — %s\n' "$1" "${2:-}" >&2; }
  if ! command -v yq >/dev/null 2>&1 || ! command -v git >/dev/null 2>&1; then
    bad "gate-select 자기 시험" "yq 또는 git 이 없습니다"
    printf 'gate-select self-test: %d passed, %d failed\n' "$passed" "$failed"
    return 1
  fi
  self="$script_dir/$(basename "$0")"
  T=$(mktemp -d "${TMPDIR:-/tmp}/gate-select-selftest.XXXXXX")
  R="$T/repo"
  mkdir -p "$R/.github/workflows" "$R/scripts" "$R/plugins/cc-cmds/orchestrator"

  cat > "$R/.github/workflows/gate.yml" <<'EOF'
on:
  pull_request:
    paths:
      - scripts/test-gate.sh
      - scripts/gate-shard.sh
      - plugins/cc-cmds/orchestrator/**
      - Makefile
      - .github/workflows/gate.yml
jobs: {}
EOF
  printf 'echo shard\n' > "$R/scripts/gate-shard.sh"
  printf 'lint:\n\t@echo lint\ngate-run:\n\t@echo run\n' > "$R/Makefile"
  printf 'readme\n' > "$R/README.md"
  printf 'print("tool")\n' > "$R/plugins/cc-cmds/orchestrator/tool.py"
  cat > "$R/plugins/cc-cmds/orchestrator/gate.sh" <<'EOF'
#!/usr/bin/env bash
GATE_DIR=$(cd "$(dirname "$0")" && pwd)
. "$GATE_DIR/lib.sh"
GATE_LIMIT=3
alpha() {
  beta_helper
}
gamma() {
  echo "$GATE_LIMIT"
}
lonely() {
  echo lonely
}
gate_main() {
  local verb="$1"
  case "$verb" in
    snap)
      alpha
      ;;
    other)
      gamma
      ;;
  esac
}
gate_main "$@"
EOF
  cat > "$R/plugins/cc-cmds/orchestrator/lib.sh" <<'EOF'
beta_helper() {
  echo beta
}
LIB_MODE=on
echo top-level-in-lib
EOF
  # A miniature suite: the two read modes the selector calls, over the same
  # dashed banners the real suite uses.
  # The estimate mode prints the closure of the named sections the way the real
  # suite does; FX_EST_DROP_NEEDS makes its reader ignore `needs:` and
  # FX_EST_UNKNOWN makes it a suite older than the mode.
  cat > "$R/scripts/test-gate.sh" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "--sections" ] && [ "${3:-}" = "--estimate" ]; then
  if [ -n "${FX_EST_UNKNOWN:-}" ]; then echo "test-gate: 모르는 인자입니다: --estimate" >&2; exit 2; fi
  awk -v want="$2" -v drop="${FX_EST_DROP_NEEDS:-}" '
    /^# --- section: / { n = ""; if (drop == "" && match($0, /needs: [^ ]+/)) n = substr($0, RSTART + 7, RLENGTH - 7); dep[$4] = n }
    END {
      k = split(want, q, ","); t = 0
      for (i = 1; i <= k; i++) if (!(q[i] in pk)) { pk[q[i]] = 1; qq[++t] = q[i] }
      for (h = 1; h <= t; h++) { d = dep[qq[h]]; if (d != "" && !(d in pk)) { pk[d] = 1; qq[++t] = d } }
      for (h = 1; h <= t; h++) print qq[h] "\t1\t추정"
      print "@head\t1\t추정"
    }' "$0"
  exit 0
fi
if [ "${1:-}" = "--list" ] || [ "${1:-}" = "--digests" ]; then
  f=$0
  if [ "${2:-}" = "--from" ]; then f=$3; fi
  awk -v mode="$1" '
    /^# --- preamble-end ---$/ { pre = NR }
    /^# --- epilogue-begin ---$/ { epi = NR }
    /^# --- [0-9]+[a-z]*\. / { nb++; b[nb] = NR }
    /^# --- section: / { m[NR] = $4 }
    { body[NR] = $0 }
    END {
      for (i = 1; i <= nb; i++) {
        if (b[i] < pre) continue
        id = m[b[i] + 1]
        if (id == "") continue
        if (mode == "--list") { print id " title"; continue }
        e = (i < nb ? b[i + 1] - 1 : epi - 1)
        d = ""
        for (k = b[i]; k <= e; k++) d = d "|" body[k]
        gsub(/\t/, " ", d)
        print id "\t" d
      }
    }' "$f"
  exit 0
fi
helper_one() {
  echo one
}
helper_two() {
  helper_one
}
pre_base() {
  echo base
}
pre_grp() {
  echo grp
}
echo top
# --- preamble-end ---
# --- 1. first ---
# --- section: 1 | group: base | covers: snap ---
echo first
# --- 2. second ---
# --- section: 2 | group: grp | covers: - | needs: 1 ---
helper_two
gamma
# --- 3. third ---
# --- section: 3 | group: grp | covers: - ---
echo "$GATE_LIMIT"
# --- 4. container ---
# the container block carries no marker
# --- 5. fifth ---
# --- section: 5 | group: base | covers: alpha ---
echo fifth
# --- epilogue-begin ---
echo end
EOF
  g() { git -c user.name=gate-select -c user.email=gate-select@localhost -c commit.gpgsign=false -c core.hooksPath=/dev/null "$@"; }
  (cd "$R" && g init -q && g add -A && g commit -q -m base) || { bad "gate-select 자기 시험" "임시 레포를 만들지 못했습니다"; rm -rf "$T"; return 1; }
  B0=$(cd "$R" && git rev-parse HEAD)

  # Line edits on the fixture, by exact line text (ENVIRON keeps backslashes).
  fx_sub() { O="$2" N="$3" awk '$0 == ENVIRON["O"] { print ENVIRON["N"]; next } { print }' "$1" > "$1.new" && mv "$1.new" "$1"; }
  fx_after() { O="$2" N="$3" awk '{ print } $0 == ENVIRON["O"] { print ENVIRON["N"] }' "$1" > "$1.new" && mv "$1.new" "$1"; }
  fx_delfn() { O="$2() {" awk '$0 == ENVIRON["O"] { skip = 1 } skip { if ($0 == "}") skip = 0; next } { print }' "$1" > "$1.new" && mv "$1.new" "$1"; }

  # sc <label> <want> <edit...>: one commit on the base, then the selector over
  # it. <want> is the exact first stdout line, or `전량` for any whole verdict.
  sc() {
    local label="$1" want="$2"; shift 2
    if ! (cd "$R" && g checkout -q --detach "$B0" && "$@" && g add -A && g commit -q -m case); then
      bad "$label" "픽스처 커밋을 만들지 못했습니다"; return
    fi
    (cd "$R" && bash "$self" --base "$B0" --head HEAD) > "$T/out" 2>"$T/err"; rc=$?
    out=$(head -n 1 "$T/out")
    if [ "$want" = "전량" ]; then
      case "$out" in
        "전량"$'\t'*) [ "$rc" = 0 ] && { ok "$label"; return; } ;;
      esac
    elif [ "$rc" = 0 ] && [ "$out" = "$want" ]; then
      ok "$label"; return
    fi
    bad "$label" "rc=$rc 「${out}」 $(cat "$T/err")"
  }
  O="$R/plugins/cc-cmds/orchestrator"
  S="$R/scripts/test-gate.sh"
  tab=$'\t'

  sc "(a) 기계 장치 파일이 바뀌면 전량" 전량 fx_sub "$R/scripts/gate-shard.sh" 'echo shard' 'echo shard2'
  sc "(b) Makefile 의 gate 계열 타깃 안 줄이 바뀌면 전량" 전량 fx_sub "$R/Makefile" "${tab}@echo run" "${tab}@echo run2"
  sc "(b) Makefile 의 gate 계열 아닌 타깃 줄은 무시" "절${tab}" fx_sub "$R/Makefile" "${tab}@echo lint" "${tab}@echo lint2"
  sc "(c) 필터 밖 경로는 보지 않는다" "절${tab}" fx_sub "$R/README.md" 'readme' 'readme2'
  sc "(d) 스위트 머리의 주석 줄은 무시" "절${tab}" fx_after "$S" 'echo top' '# a note'
  sc "(d) 스위트 머리의 pre_base 안이면 전량" 전량 fx_sub "$S" '  echo base' '  echo base2'
  sc "(d) 스위트 머리의 pre_<group> 안이면 그 그룹 절과 선행 폐포" "절${tab}1,2,3" fx_sub "$S" '  echo grp' '  echo grp2'
  sc "(d) 스위트 머리의 다른 함수는 그 이름을 담은 절, 머리 함수 간 호출을 따라간다" "절${tab}1,2" fx_sub "$S" '  echo one' '  echo one2'
  sc "(d) 스위트 머리의 함수 밖 최상위 문장이면 전량" 전량 fx_sub "$S" 'echo top' 'echo top2'
  sc "(e) 스위트 꼬리가 바뀌면 전량" 전량 fx_sub "$S" 'echo end' 'echo end2'
  sc "(e) 표지 없는 컨테이너 절이 바뀌면 전량" 전량 fx_sub "$S" '# the container block carries no marker' '# the container block, changed'
  sc "(f) 절 본문의 변경은 다이제스트가 고른 절과 그 needs 선행" "절${tab}1,2" fx_sub "$S" 'gamma' 'gamma --again'
  sc "(g) 덮인 함수는 덮는 절을 고른다" "절${tab}5" fx_sub "$O/gate.sh" '  beta_helper' '  beta_helper --fast'
  sc "(h) 덮이지 않은 함수는 호출자를 거슬러 덮인 노드의 절을 고른다" "절${tab}5" fx_sub "$O/lib.sh" '  echo beta' '  echo beta2'
  if grep -q '^gate-select: plugins/cc-cmds/orchestrator/lib.sh:beta_helper() → 5$' "$T/err"; then
    ok "(h) 표준 오류에 바뀐 단위의 줄이 남는다"
  else
    bad "(h) 표준 오류에 바뀐 단위의 줄이 남는다" "$(cat "$T/err")"
  fi
  sc "(i) 변수 노드는 그 이름을 담은 절을 고른다" "절${tab}3" fx_sub "$O/gate.sh" 'GATE_LIMIT=3' 'GATE_LIMIT=4'
  sc "(j) 덮인 노드 없이 gate 프로세스의 뿌리에 닿으면 전량" 전량 fx_sub "$O/gate.sh" '  echo lonely' '  echo lonely2'
  sc "(k) gate 프로세스 밖 파일을 아무도 부르지 않으면 고르는 절이 없다" "절${tab}" fx_sub "$O/tool.py" 'print("tool")' 'print("tool2")'
  sc "(l) 지운 줄은 베이스에서 위치를 잡는다" "절${tab}1,2" fx_delfn "$O/gate.sh" gamma
  sc "(m) gate_main 의 동사 갈래는 covers 가 그 동사를 담은 절" "절${tab}1" fx_sub "$O/gate.sh" '      alpha' '      alpha --now'
  sc "(n) 소싱 파일의 분류 밖 최상위 문장이면 전량" 전량 fx_sub "$O/lib.sh" 'echo top-level-in-lib' 'echo top-level-in-lib2'
  sc "(o) 함수 안 주석 줄은 무시" "절${tab}" fx_after "$O/gate.sh" 'lonely() {' '  # a note'

  # Cases the selector cannot judge end nonzero.
  (cd "$R" && bash "$self" --base no-such-commit --head HEAD) > "$T/out" 2>"$T/err"; rc=$?
  if [ "$rc" != 0 ] && grep -q '판정할 수 없습니다' "$T/err"; then
    ok "(p) 읽지 못하는 커밋이면 0 이 아닌 종료"
  else
    bad "(p) 읽지 못하는 커밋이면 0 이 아닌 종료" "rc=$rc $(cat "$T/err")"
  fi
  mkdir -p "$T/stub"
  printf '#!/bin/sh\necho "yq 3.4.3"\n' > "$T/stub/yq"
  chmod +x "$T/stub/yq"
  (cd "$R" && PATH="$T/stub:$PATH" bash "$self" --base "$B0" --head HEAD) > "$T/out" 2>"$T/err"; rc=$?
  if [ "$rc" != 0 ] && grep -q 'mikefarah/yq' "$T/err"; then
    ok "(q) mikefarah/yq 가 아니면 0 이 아닌 종료"
  else
    bad "(q) mikefarah/yq 가 아니면 0 이 아닌 종료" "rc=$rc $(cat "$T/err")"
  fi

  # (r) The closure is held to the suite's own reader: a reader that drops
  # `needs:` disagrees and the change cannot be judged, while a suite that does
  # not know `--estimate` leaves the closure as computed, with a line saying so.
  if (cd "$R" && g checkout -q --detach "$B0" && fx_sub "$S" 'gamma' 'gamma --again' && g add -A && g commit -q -m case); then
    (cd "$R" && FX_EST_DROP_NEEDS=1 bash "$self" --base "$B0" --head HEAD) > "$T/out" 2>"$T/err"; rc=$?
    if [ "$rc" != 0 ] && [ ! -s "$T/out" ] && grep -q '직접 읽은 needs 폐포 \[1,2\] 가 헤드 스위트의 폐포 \[2\] 와 다릅니다' "$T/err"; then
      ok "(r) 스위트 판독기와 needs 폐포가 다르면 0 이 아닌 종료"
    else
      bad "(r) 스위트 판독기와 needs 폐포가 다르면 0 이 아닌 종료" "rc=$rc $(cat "$T/out") $(cat "$T/err")"
    fi
    (cd "$R" && FX_EST_UNKNOWN=1 bash "$self" --base "$B0" --head HEAD) > "$T/out" 2>"$T/err"; rc=$?
    if [ "$rc" = 0 ] && [ "$(head -n 1 "$T/out")" = "절${tab}1,2" ] && grep -q '^gate-select: scripts/test-gate.sh:needs: → (대조 생략)' "$T/err"; then
      ok "(r) --estimate 를 모르는 스위트면 대조를 건너뛰고 그 사실을 적는다"
    else
      bad "(r) --estimate 를 모르는 스위트면 대조를 건너뛰고 그 사실을 적는다" "rc=$rc $(cat "$T/out") $(cat "$T/err")"
    fi
  else
    bad "(r) needs 폐포 대조" "픽스처 커밋을 만들지 못했습니다"
    bad "(r) --estimate 를 모르는 스위트" "픽스처 커밋을 만들지 못했습니다"
  fi

  # (s) The time cap stops the call and every process it started: a yq that
  # hangs is stopped with it, and the call ends as one that cannot be judged.
  mkdir -p "$T/slow"
  printf '#!/bin/sh\necho $$ > "%s/slow/pid"\nexec sleep 30\n' "$T" > "$T/slow/yq"
  chmod +x "$T/slow/yq"
  s0=$(date +%s)
  (cd "$R" && GATE_SELECT_TIMEOUT=1 PATH="$T/slow:$PATH" bash "$self" --base "$B0" --head HEAD) > "$T/out" 2>"$T/err"; rc=$?
  s1=$(date +%s)
  sleep 0.5
  spid=$(cat "$T/slow/pid" 2>/dev/null)
  if [ "$rc" != 0 ] && [ ! -s "$T/out" ] && grep -q '한 호출의 시간 상한 1초를 넘었습니다' "$T/err" \
     && [ "$((s1 - s0))" -lt 10 ] && [ -n "$spid" ] && ! kill -0 "$spid" 2>/dev/null; then
    ok "(s) 시간 상한을 넘으면 그 호출이 띄운 프로세스까지 멈추고 0 이 아닌 종료"
  else
    bad "(s) 시간 상한을 넘으면 그 호출이 띄운 프로세스까지 멈추고 0 이 아닌 종료" "rc=$rc 걸린 $((s1 - s0))초 pid=${spid:-없음} $(cat "$T/err")"
    [ -z "$spid" ] || kill "$spid" 2>/dev/null
  fi
  (cd "$R" && GATE_SELECT_TIMEOUT=abc bash "$self" --base "$B0" --head HEAD) > "$T/out" 2>"$T/err"; rc=$?
  if [ "$rc" = 2 ] && grep -q 'GATE_SELECT_TIMEOUT 은 1 이상의 초 수여야 합니다' "$T/err"; then
    ok "(s) 초 수가 아닌 시간 상한은 0 이 아닌 종료"
  else
    bad "(s) 초 수가 아닌 시간 상한은 0 이 아닌 종료" "rc=$rc $(cat "$T/err")"
  fi

  rm -rf "$T"
  printf 'gate-select self-test: %d passed, %d failed\n' "$passed" "$failed"
  # A floor on the count, so a refactor that silently skips cases cannot pass.
  if [ "$passed" -lt 28 ]; then
    printf 'gate-select self-test: 통과 수 %d 가 하한 28 에 못 미칩니다\n' "$passed" >&2
    return 1
  fi
  [ "$failed" = "0" ]
}

# --- main --------------------------------------------------------------------

[ "$#" -ge 1 ] || sel_usage
case "$1" in
  --self-test) sel_self_test; exit $? ;;
  *)
    if [ -n "${GATE_SELECT_CAPPED:-}" ]; then sel_main "$@"; else sel_capped "$@"; fi ;;
esac
