#!/usr/bin/env bash
# Measure how many processes the resident orchestrator scripts spawn per unit
# of work, and count the exec sites in their source that no PATH stub can see.
#
# THE METRIC IS A PROCESS COUNT, NOT A DURATION, for the reason
# `measure-gate-cost.sh` gives: a count is a function of the input, so a slice's
# effect is an integer rather than a percentage with an error bar. This tool
# widens that apparatus from the gate's read paths to eight units of resident
# work — one full watch pass, a minute of the quiet watcher with its two
# companions, one checks pass, four feed cycles, one status-line draw, one
# run-pane draw, one PreToolUse hook call that ends on allow, and one gate
# `exec` from a stage.
#
# HOW A PROCESS IS COUNTED. Two recorders write one log:
#
#   - A directory of counting stubs goes on PATH first. Each stub appends
#     `<pid> exec <name> ppid=<ppid>` and execs the real binary, whose absolute
#     path the tool resolved before putting the stubs on PATH, so an external
#     command run by name costs the pid it would have cost anyway. The line
#     carries ` self` when the stub's pid equals the inherited `CC_SPAWN_SELF`,
#     and the stub exports its own pid as `CC_SPAWN_SELF` before it execs, so a
#     counted stub process that execs again in place (`bash -c 'cmd'`, a
#     script ending in `exec …`) marks the next stub line too.
#     `run.sh` puts the system directories in front of PATH when it is sourced
#     (the gate sources it), which would hide the stubs from every command after
#     that line; the DEBUG trap below puts the stub directory back in front
#     before each command, so the stubs stay first however a target edits PATH.
#   - A `BASH_ENV` file turns on `set -T` and a DEBUG trap. On the first command
#     a subshell runs, the trap records that subshell's pid with
#     `$(/bin/sh -c "/bin/ps -o ppid= -p \$PPID")` — the pid of the shell that
#     ran the trap, not of the trap's own command substitution — together with
#     `${FUNCNAME[*]}`, and exports that pid as `CC_SPAWN_SELF`. Every bash the
#     unit starts reads the same file, so a script that runs another script is
#     traced too.
#
# The count is the number of subshell entry lines plus the number of stub lines
# without the ` self` mark. A subshell that execs an external command in place
# keeps its pid and was already counted at its entry, so `$(sed …)` is one
# process, not two. The inherited `CC_SPAWN_SELF` is always the value the
# process itself or a living ancestor exported, so a pid the kernel reuses
# during a measurement is never folded into another process the way a count of
# distinct pids folds it: measured, two runs of one unit wrote the same 709
# entry lines and 614 stub lines and yet 1300 and 1297 distinct pids, over a pid
# range that wrapped. The distinct pid count is still reported, as
# `<unit>.distinct`, for diagnosis only. The main shell of each unit is started
# through the real bash, not the stub, and is not counted; a command run by
# absolute path from a traced shell is not counted either, which is what the
# static count below is for.
#
# ATTRIBUTION. For each command whose first word (after `exec`, `command` and
# assignment words) is a stub name that `type -t` reports as `file`, the trap
# writes `<pid> call <name> <FUNCNAME…>`. An assignment word that holds a
# command substitution ends the scan with no call line: `me=$(exec sh -c …)`
# runs `sh` in the substitution's own subshell, whose trap writes that call,
# and the word after the parent's `me=$(exec` is no command of the parent's.
# So does one whose quoted value does not close within the word: `BASH_COMMAND`
# is split at whitespace, and the `sh` of `A='bash sh zsh'` is text, not a
# command. A command after such an assignment writes no call line, and its
# stub line is then counted as unattributed rather than paired. A stub line pairs with the oldest
# unpaired call line of the same name whose pid is the stub's pid or its parent;
# a stub line with no partner — a command run by a tool such as `xargs`, or by a
# shell the trap did not see — is reported as `<unit>.unattributed`. `type -t`
# only runs for stub names, because no other first word can produce a stub line,
# and its answer is read back through a per-process file rather than a command
# substitution, which would fork inside the trap. Every command in the trap
# that can fail is followed by `|| :`, because a target running under `set -e`
# (the gate does) exits on a failing command inside its DEBUG trap.
#
# THE STATIC COUNT is host independent. For each of the eight target scripts it
# extracts every word in command position with a small shell tokenizer (quoted
# text, comments and here-document bodies are not commands; `case` patterns,
# arithmetic, `[[ … ]]`, `for` word lists and redirection targets are skipped;
# command substitutions, process substitutions and subshells are commands), and
# reports:
#
#   abspath.<script>   — exec sites the stubs cannot see. The rule: skip `exec`,
#                        `command` and assignment words; the site counts when
#                        the next word starts with `/`, or is a default-value
#                        parameter expansion whose default starts with `/`
#                        (`"${BASH:-/bin/bash}"`). An `exec` site counts.
#   outside.<script>   — names run through PATH that `runs/spec/stubs` does not
#                        list: not a builtin, not a keyword, not a function any
#                        orchestrator or hook file defines. Wrappers (`env`,
#                        `nohup`, `nice`, `timeout`, `xargs`, `sudo`) count, and
#                        so does the command they wrap.
#   pathrewrite.<script> — the lines that assign `PATH`, `none` when there is
#                        none.
#
# UNITS ARE DRIVEN BY SPEC FILES, `tests/fixtures/measure-spawn-count/runs/spec/U1`
# … `U8`, three tab-separated columns `kind key value`:
#
#   env      NAME VALUE      exported for the unit; `@UNSET@` unsets it. Every
#                            inherited `CC_PIPELINE_*` is unset first.
#   fixture  VERB ARGS       prepares the copy root before the window opens:
#                            `copy <dir> <dest>` copies `runs/<dir>`; `chain
#                            <ledger> <run-id>` fills the `prev=@PREV@` chain;
#                            `mkdir <dir>` and `chmod <file>` (executable) make
#                            what git does not carry;
#                            `live <prefix>` starts a stand-in stage process and
#                            writes `<prefix>.pid` and `.start`; `git <dir>`
#                            makes a repository of a copied directory; `manifest
#                            <file>` fills a run manifest's digests; `snapshot
#                            <file>` asks the gate for the snapshot digest;
#                            `gate <args>` runs one gate call as the router, to
#                            put the ledger rows the measured call needs;
#                            `stdin <file>` and `cwd <dir>` set the unit's input
#                            and working directory.
#   mtime    PATH SECONDS    sets the file's mtime to the unit's start plus
#                            SECONDS.
#   argv     LABEL WORD      one argument of the process LABEL, in order.
#   stop     KIND ARGS       `exit`; `stub-count <name> <n>`; `sleep-cycles <n>
#                            arg <v> limit <s>`, which ends the measurement on
#                            the stub `sleep`'s <n>th call whose arguments are
#                            exactly <v> and fails it when it takes longer than
#                            <s> seconds. `each` measures every argv label on
#                            its own, from a fresh copy root, and sums them.
#                            `rewrite <path> [<label>…]` rewrites the file as a
#                            fresh `quiet <epoch>` line every second, only while
#                            a listed label runs when labels are given. After
#                            it, `expect <label> <text>` checks an output,
#                            `file-has <path> <text>` a file, and `no-file
#                            <path>` that a file was not written.
#
# THE QUIET HOUR IS COUNTED IN CYCLES, NOT IN SECONDS. Each resident script
# ends its cycle with one `sleep "$INTERVAL"`; under `sleep-cycles` the stub
# `sleep` counts the calls whose argument is the interval, returns at once for
# all but the last, and on the last records its line and does not return. The
# count is cut at that line, so a unit holds exactly <n> cycles whatever the
# host's speed, and the interval stays the production value, so every threshold
# derived from it is the production one.
#
# Values may carry `@ROOT@` (the copy root), `@REPO@`, `@ORCH@`, `@HOOKS@`,
# `@EMPTY@` (a fresh empty directory), `@NOW@` (the unit's start epoch) and
# `@H@` (the digest `snapshot` obtained). The tool chooses fixtures only through
# `fixture copy`; it never lists `runs/` to choose one. Each measurement copies into a fresh
# `mktemp -d` root holding nothing else, so no sibling run is visible.
#
# Usage:
#   bash scripts/measure-spawn-count.sh                 static counts and every unit
#   bash scripts/measure-spawn-count.sh --unit U3       one unit
#   bash scripts/measure-spawn-count.sh --static        static counts only
#   bash scripts/measure-spawn-count.sh --names         every PATH name the targets run
#   bash scripts/measure-spawn-count.sh --calibrate     the six-process calibration
#   bash scripts/measure-spawn-count.sh --cond          the six measuring conditions
#   bash scripts/measure-spawn-count.sh --baseline      the baseline table on stdout
#   bash scripts/measure-spawn-count.sh --reproduce     re-measure and compare with
#                                                      baseline.tsv byte for byte
#
# Exit codes:
#   0  measured (for --reproduce: identical to baseline.tsv)
#   1  --reproduce measured something different from baseline.tsv
#   2  usage error, a unit that did not run as its spec says, a measurement
#      longer than its spec's wall-clock limit, a fixture changed by measuring,
#      or a fixture file git ignores (one no commit carries)
set -uo pipefail

die2() { printf 'measure-spawn-count: %s\n' "$1" >&2; exit 2; }

REPO=$(cd "$(dirname "$0")/.." && pwd -P)
FIXD="$REPO/tests/fixtures/measure-spawn-count"
RUNS="$FIXD/runs"
SPECD="$RUNS/spec"
BASELINE="$FIXD/baseline.tsv"
ORCH="$REPO/plugins/cc-cmds/orchestrator"
HOOKS="$REPO/plugins/cc-cmds/hooks"
UNITS="U1 U2 U3 U4 U5 U6 U7 U8"
TARGETS="plugins/cc-cmds/orchestrator/watch.sh
plugins/cc-cmds/orchestrator/checks.sh
plugins/cc-cmds/orchestrator/feed.sh
plugins/cc-cmds/orchestrator/statusline.sh
plugins/cc-cmds/orchestrator/run-pane.sh
plugins/cc-cmds/orchestrator/gate.sh
plugins/cc-cmds/hooks/gate-pretool.sh
plugins/cc-cmds/orchestrator/liveness.sh"
# Builtins of bash 3.2, the bash the targets run on, so the static count does
# not move with the host's bash. The targets pass the portability lint, so no
# builtin that only later versions have appears in them.
BUILTINS=" . : [ alias bg bind break builtin caller cd command compgen complete compopt continue declare dirs disown echo enable eval exec exit export false fc fg getopts hash help history jobs kill let local logout popd printf pushd pwd read readonly return set shift shopt source suspend test times trap true type typeset ulimit umask unalias unset wait "
UNIT_TIMEOUT=900

MODE=all ONE=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --unit) [ "$#" -ge 2 ] || die2 "--unit 에 단위가 없습니다"; MODE=unit; ONE=$2; shift 2 ;;
    --static) MODE=static; shift ;;
    --names) MODE=names; shift ;;
    --extract) [ "$#" -ge 2 ] || die2 "--extract 에 파일이 없습니다"; MODE=extract; ONE=$2; shift 2 ;;
    --calibrate) MODE=calibrate; shift ;;
    --cond) MODE=cond; shift ;;
    --baseline) MODE=baseline; shift ;;
    --reproduce) MODE=reproduce; shift ;;
    -h|--help) sed -n '2,/^set -uo/p' "$0" | sed '$d'; exit 0 ;;
    *) die2 "알 수 없는 인자: $1" ;;
  esac
done
if [ "$MODE" = unit ]; then
  case " $UNITS " in *" $ONE "*) ;; *) die2 "알 수 없는 단위: $ONE" ;; esac
fi

REAL_BASH=$(type -P bash) || die2 "bash 를 PATH 에서 찾지 못했습니다"
ORIG_PATH=$PATH
WORK=$(mktemp -d "${TMPDIR:-/tmp}/cc-measure-spawn.XXXXXX") || die2 "mktemp 실패"
WORK=$(cd "$WORK" && pwd -P)
# `CC_MEASURE_SPAWN_KEEP` keeps the scratch directory (copies, logs, outputs)
# for reading after a failed unit, and names it on stderr.
if [ -n "${CC_MEASURE_SPAWN_KEEP:-}" ]; then
  printf 'measure-spawn-count: 작업 디렉터리를 남깁니다 — %s\n' "$WORK" >&2
else
  trap 'rm -rf "$WORK"' EXIT
fi

sha256() { shasum -a 256 | cut -d' ' -f1; }

# ---------------------------------------------------------------------------
# Fingerprints and measuring conditions
# ---------------------------------------------------------------------------

# fixture_bytes [all] — every committed fixture file under runs/, as its
# repo-relative path followed by its bytes, in path order. Without `all` the
# spec directory is left out, which is the `fixture` condition.
fixture_bytes() {
  local f rel
  ( cd "$REPO" && find tests/fixtures/measure-spawn-count/runs -type f ) | LC_ALL=C sort |
    while IFS= read -r rel; do
      if [ "${1:-}" != all ]; then
        case "$rel" in tests/fixtures/measure-spawn-count/runs/spec/*) continue ;; esac
      fi
      f="$REPO/$rel"
      printf '%s\n' "$rel"
      cat "$f"
    done
}

cond_rows() {
  local u s bashv caller
  bashv=$("$REAL_BASH" -c 'printf %s "$BASH_VERSION"')
  s=$(for u in $UNITS; do cat "$SPECD/$u"; done | sha256)
  caller=dashboard
  if awk -F'\t' '$1 == "env" && $2 == "CC_PIPELINE_STAGE_ID" && $3 != "" && $3 != "@UNSET@" { f = 1 } END { exit !f }' "$SPECD/U8"; then
    caller=stage
  fi
  printf 'cond\tos\t%s\n' "$(uname -s)"
  printf 'cond\tbash\t%s\n' "$bashv"
  printf 'cond\tstubs\t%s\n' "$(sha256 < "$SPECD/stubs")"
  printf 'cond\tspec\t%s\n' "$s"
  printf 'cond\tfixture\t%s\n' "$(fixture_bytes | sha256)"
  printf 'cond\tu8-caller\t%s\n' "$caller"
}

# ---------------------------------------------------------------------------
# Static count
# ---------------------------------------------------------------------------

# The tokenizer. One record per line on stdout:
#   C <line> <word> <quoted>   a word in command position
#   U <line> <word>            the previous C was a function name after all
#   D <line> <name>            a function definition
#   P <line> <word>            an assignment to PATH, in any position
cat > "$WORK/extract.awk" <<'AWK'
function push(m) {
  sp++; M[sp] = m; AD[sp] = 0; BD[sp] = 0; KT[sp] = 0
  W[sp] = ""; IW[sp] = 0; Q[sp] = 0; QS[sp] = -1; CP[sp] = 1; RD[sp] = 0; FOR[sp] = 0
  PAT[sp] = 0; CD[sp] = 0; CW[sp] = 0; XB[sp] = 0; FN[sp] = 0; CO[sp] = 0
  WR[sp] = ""; WA[sp] = 0; TD[sp] = 0; ARR[sp] = 0; LW[sp] = ""; LL[sp] = 0
}
function pop() { if (M[sp] == "c") fin(sp); if (sp > 1) sp-- }
function cidx(   k) { for (k = sp; k > 1; k--) if (M[k] == "c") return k; return 1 }
function addc(t,   k) { k = cidx(); W[k] = W[k] t; IW[k] = 1 }
function qmark(k) { if (QS[k] < 0) QS[k] = length(W[k]); Q[k] = 1; IW[k] = 1 }
function emit(k, w, q) { print "C\t" NR "\t" w "\t" q; LW[k] = w; LL[k] = NR }
function cmdword(k, w, q, pre) {
  if (pre ~ /^[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?\+?=/) return
  if (!q) {
    if (w == "exec") return
    if (w == "command") { CO[k] = 1; return }
    if (CO[k] && w ~ /^-/) { if (w ~ /[vV]/) { CO[k] = 0; CP[k] = 0 } return }
    if (w ~ /^(if|then|else|elif|do|while|until|!|\{|time)$/) return
    if (w ~ /^(fi|done|\}|esac)$/) { CP[k] = 0; CO[k] = 0; return }
    if (w == "case") { CW[k] = 1; CP[k] = 0; return }
    if (w == "for" || w == "select") { FOR[k] = 1; CP[k] = 0; return }
    if (w == "function") { FN[k] = 1; CP[k] = 0; return }
    if (w == "[[") { XB[k] = 1; CP[k] = 0; return }
  }
  # A name after `command` bypasses functions, which the flag 2 says.
  if (CO[k]) q = 2
  CO[k] = 0
  emit(k, w, q); CP[k] = 0
  if (q != 1 && w ~ /^(env|nohup|nice|timeout|xargs|sudo)$/) { WR[k] = w; WA[k] = 0; TD[k] = 0; CP[k] = 1 }
}
function fin(k,   w, q, pre) {
  if (!IW[k]) return
  w = W[k]; q = Q[k]; pre = (QS[k] >= 0) ? substr(w, 1, QS[k]) : w
  W[k] = ""; IW[k] = 0; Q[k] = 0; QS[k] = -1
  if (pre ~ /^PATH\+?=/) print "P\t" NR "\t" w
  if (ARR[k]) return
  if (RD[k]) { if (RD[k] == 2) { HN++; HD[HN] = w; HDD[HN] = HDASH } RD[k] = 0; return }
  if (FN[k]) { FN[k] = 0; print "D\t" NR "\t" w; return }
  if (FOR[k]) { if (!q && w == "do") { FOR[k] = 0; CP[k] = 1 } return }
  if (CW[k] == 1) { CW[k] = 2; return }
  if (CW[k] == 2) { if (!q && w == "in") { CW[k] = 0; PAT[k] = 1; CD[k]++ } return }
  if (PAT[k]) { if (!q && w == "esac") { CD[k]--; PAT[k] = 0; CP[k] = 0 } return }
  if (XB[k]) { if (!q && w == "]]") XB[k] = 0; return }
  if (!CP[k]) return
  if (WR[k] != "") {
    if (WA[k] > 0) { WA[k]--; return }
    if (w ~ /^-/) {
      if (WR[k] == "xargs" && w ~ /^-[InLPdsE]$/) WA[k] = 1
      if (WR[k] == "nice" && w == "-n") WA[k] = 1
      if (WR[k] == "timeout" && w ~ /^-[sk]$/) WA[k] = 1
      if (WR[k] == "env" && w ~ /^-[uCS]$/) WA[k] = 1
      if (WR[k] == "sudo" && w ~ /^-[ugCDhpRrTU]$/) WA[k] = 1
      return
    }
    if (WR[k] == "env" && pre ~ /^[A-Za-z_][A-Za-z0-9_]*=/) return
    if (WR[k] == "timeout" && !TD[k]) { TD[k] = 1; return }
    WR[k] = ""; TD[k] = 0
  }
  cmdword(k, w, q, pre)
}
function sep(k) { fin(k); CP[k] = 1; WR[k] = ""; CO[k] = 0 }
BEGIN { sp = 0; push("c"); HN = 0; HI = 0; INHD = 0 }
{
  if (INHD) {
    t = $0
    if (HDD[HI]) sub(/^\t+/, "", t)
    if (t == HD[HI]) { HI++; if (HI > HN) { INHD = 0; HN = 0; HI = 0 } }
    next
  }
  s = $0 "\n"; n = length(s); j = 1; CONT = 0
  while (j <= n) {
    ch = substr(s, j, 1); nx = substr(s, j + 1, 1); m = M[sp]
    if (m == "s") { if (ch == "'") sp--; else addc(ch); j++; continue }
    if (m == "e") {
      if (ch == "\\") { addc(nx); j += 2; continue }
      if (ch == "'") sp--; else addc(ch)
      j++; continue
    }
    if (m == "d") {
      if (ch == "\\") { if (nx != "\n") addc(nx); j += 2; continue }
      if (ch == "\"") { sp--; j++; continue }
      if (ch == "$" && nx == "(" && substr(s, j + 2, 1) == "(") { addc("$"); push("a"); j += 3; continue }
      if (ch == "$" && nx == "(") { addc("$("); push("c"); j += 2; continue }
      if (ch == "$" && nx == "{") { addc("${"); push("b"); j += 2; continue }
      if (ch == "`") { addc("$("); push("c"); KT[sp] = 1; j++; continue }
      addc(ch); j++; continue
    }
    if (m == "b") {
      if (ch == "\\") { addc(ch nx); j += 2; continue }
      if (ch == "}") { if (BD[sp] > 0) { BD[sp]--; addc(ch) } else { addc("}"); sp-- } j++; continue }
      if (ch == "{") { BD[sp]++; addc(ch); j++; continue }
      if (ch == "\"") { push("d"); j++; continue }
      if (ch == "'" && M[sp - 1] != "d") { push("s"); j++; continue }
      if (ch == "$" && nx == "(" && substr(s, j + 2, 1) == "(") { addc("$"); push("a"); j += 3; continue }
      if (ch == "$" && nx == "(") { addc("$("); push("c"); j += 2; continue }
      if (ch == "$" && nx == "{") { addc("${"); push("b"); j += 2; continue }
      if (ch == "`") { addc("$("); push("c"); KT[sp] = 1; j++; continue }
      addc(ch); j++; continue
    }
    if (m == "a") {
      if (ch == "(") { AD[sp]++; j++; continue }
      if (ch == ")") {
        if (AD[sp] > 0) { AD[sp]--; j++; continue }
        sp--; j += (nx == ")") ? 2 : 1; continue
      }
      if (ch == "$" && nx == "(" && substr(s, j + 2, 1) != "(") { push("c"); j += 2; continue }
      if (ch == "`") { push("c"); KT[sp] = 1; j++; continue }
      j++; continue
    }
    i = sp
    if (ch == "\\") {
      if (nx == "\n") { CONT = 1; j += 2; continue }
      qmark(i); addc(nx); j += 2; continue
    }
    if (XB[i] && W[i] != "]]" && ch ~ /[()|&<>]/) { addc(ch); j++; continue }
    if (ch == " " || ch == "\t") { fin(i); j++; continue }
    if (ch == "\n") { sep(i); j++; continue }
    if (ch == "#" && !IW[i]) { j = n; continue }
    if (ch == "'") { qmark(i); push("s"); j++; continue }
    if (ch == "$" && nx == "'") { qmark(i); push("e"); j += 2; continue }
    if (ch == "\"") { qmark(i); push("d"); j++; continue }
    if (ch == "$" && nx == "(" && substr(s, j + 2, 1) == "(") { addc("$"); push("a"); j += 3; continue }
    if (ch == "$" && nx == "(") { addc("$("); push("c"); j += 2; continue }
    if (ch == "$" && nx == "{") { addc("${"); push("b"); j += 2; continue }
    if (ch == "`") {
      if (KT[i]) { pop(); j++; continue }
      addc("$("); push("c"); KT[sp] = 1; j++; continue
    }
    if (ch == "(") {
      rest = substr(s, j + 1)
      if (IW[i] && W[i] ~ /=$/) { push("c"); ARR[sp] = 1; j++; continue }
      if (rest ~ /^[ \t]*\)/ && (IW[i] || LL[i] == NR)) {
        if (IW[i]) { nm = W[i]; W[i] = ""; IW[i] = 0; Q[i] = 0 }
        else { nm = LW[i]; print "U\t" NR "\t" nm }
        print "D\t" NR "\t" nm
        FN[i] = 0; CP[i] = 1
        j = j + index(rest, ")") + 1; continue
      }
      if (PAT[i]) { j++; continue }
      if (!IW[i] && CP[i] && nx == "(") { push("a"); j += 2; continue }
      if (!IW[i] && CP[i]) { push("c"); j++; continue }
      addc(ch); j++; continue
    }
    if (ch == ")") {
      if (PAT[i]) { fin(i); PAT[i] = 0; CP[i] = 1; j++; continue }
      pop(); j++; continue
    }
    if (ch == ";") {
      fin(i)
      if (nx == ";") { j += 2; if (substr(s, j, 1) == "&") j++; if (CD[i] > 0) PAT[i] = 1; CP[i] = 0; continue }
      if (nx == "&") { j += 2; if (CD[i] > 0) PAT[i] = 1; CP[i] = 0; continue }
      if (!FOR[i]) CP[i] = 1
      WR[i] = ""; CO[i] = 0; j++; continue
    }
    if (ch == "&") {
      if (nx == ">") { fin(i); RD[i] = 1; j += 2; if (substr(s, j, 1) == ">") j++; continue }
      sep(i); j += (nx == "&") ? 2 : 1; continue
    }
    if (ch == "|") {
      if (PAT[i]) { fin(i); j++; continue }
      sep(i); j += (nx == "|" || nx == "&") ? 2 : 1; continue
    }
    if (ch == "<" || ch == ">") {
      if (IW[i] && !Q[i] && W[i] ~ /^[0-9]+$/) { W[i] = ""; IW[i] = 0 } else fin(i)
      if (nx == "(") { push("c"); j += 2; continue }
      if (ch == "<" && nx == "<" && substr(s, j + 2, 1) == "<") { RD[i] = 1; j += 3; continue }
      if (ch == "<" && nx == "<") {
        j += 2; HDASH = 0
        if (substr(s, j, 1) == "-") { HDASH = 1; j++ }
        RD[i] = 2; continue
      }
      j++; c2 = substr(s, j, 1)
      if (c2 == ">" || c2 == "&" || c2 == "|") j++
      RD[i] = 1; continue
    }
    addc(ch); j++
  }
  if (HN > 0 && !CONT && HI == 0) { INHD = 1; HI = 1 }
}
AWK

# extract <repo-relative file> — the tokenizer's records, prefixed with the file.
extract() {
  awk -v f="$1" -F'\t' 'BEGIN { OFS = "\t" } { print f, $0 }' \
    <(awk -f "$WORK/extract.awk" "$REPO/$1")
}

# The function names every orchestrator and hook file defines: a word that is
# one of them is a function call wherever it is defined, since the targets
# source each other's libraries. The suites (`test-*.sh`) are left out: they
# define stand-ins named like real commands, and no target sources them.
DEFS=""
static_defs() {
  local f
  [ -n "$DEFS" ] && return 0
  DEFS=" $( ( cd "$REPO" && find plugins/cc-cmds/orchestrator plugins/cc-cmds/hooks -type f -name '*.sh' ! -name 'test-*' ) | LC_ALL=C sort |
    while IFS= read -r f; do awk -f "$WORK/extract.awk" "$REPO/$f"; done |
    awk -F'\t' '$1 == "D" { print $3 }' | LC_ALL=C sort -u | tr '\n' ' ') "
}

# commands <file> — the file's C records with the undone ones removed, as
# `<line> <word>` lines.
commands() {
  extract "$1" | awk -F'\t' '
    $2 == "C" { n++; L[n] = $3; Wd[n] = $4 }
    $2 == "U" { for (k = n; k > 0; k--) if (L[k] == $3 && Wd[k] == $4) { Wd[k] = ""; break } }
    $2 == "C" { F[n] = $5 }
    END { for (k = 1; k <= n; k++) if (Wd[k] != "") print L[k] "\t" Wd[k] "\t" F[k] }'
}

# path_names <file> — the distinct names the file runs through PATH.
path_names() {
  static_defs
  commands "$1" | awk -F'\t' -v b="$BUILTINS" -v d="$DEFS" '
    $2 ~ /^[A-Za-z_][A-Za-z0-9_.+-]*$/ && index(b, " " $2 " ") == 0 && ($3 == 2 || index(d, " " $2 " ") == 0) { print $2 }' |
    LC_ALL=C sort -u
}

abspath_count() {
  commands "$1" | awk -F'\t' '$2 ~ /^\// || $2 ~ /^\$\{[A-Za-z_][A-Za-z0-9_]*:?[-=]\// { n++ } END { print n + 0 }'
}

static_report() {
  local t out lines
  for t in $TARGETS; do
    printf 'abspath.%s=%s\n' "$t" "$(abspath_count "$t")"
    out=$(path_names "$t" | LC_ALL=C comm -23 - <(LC_ALL=C sort -u "$SPECD/stubs") | tr '\n' ',' | sed 's/,$//')
    if [ -n "$out" ]; then
      printf 'outside.%s=%s\n' "$t" "$(printf '%s' "$out" | tr ',' '\n' | awk 'END { print NR }')"
      printf 'outside-names.%s=%s\n' "$t" "$out"
    else
      printf 'outside.%s=0\n' "$t"
    fi
    lines=$(extract "$t" | awk -F'\t' '$2 == "P" { printf "%s%s", s, $3; s = "," }')
    printf 'pathrewrite.%s=%s\n' "$t" "${lines:-none}"
  done
}

all_names() {
  local t
  for t in $TARGETS; do path_names "$t"; done | LC_ALL=C sort -u
}

# ---------------------------------------------------------------------------
# Counting apparatus
# ---------------------------------------------------------------------------

ENVF="$WORK/env.sh"
cat > "$ENVF" <<'ENVEOF'
set -T
__cc_last=0
__cc_in=
__cc_pid=$$
__cc_q="'"
trap '[ -n "$__cc_in" ] || { __cc_in=1; [ -z "$CC_SPAWN_STUBS" ] || case $PATH in "$CC_SPAWN_STUBS":*) ;; *) PATH="$CC_SPAWN_STUBS:$PATH" ;; esac; if [ "$BASH_SUBSHELL" != "$__cc_last" ]; then __cc_last=$BASH_SUBSHELL; __s=$(/bin/sh -c "/bin/ps -o ppid= -p \$PPID") || :; __cc_pid=${__s// /}; echo "$__cc_pid fork ${FUNCNAME[*]:-main}" >> "$CC_SPAWN_LOG"; export CC_SPAWN_SELF=$__cc_pid; fi; __cc_c=$BASH_COMMAND; __cc_w=; while [ -n "$__cc_c" ]; do __cc_w=${__cc_c%%[[:space:]]*}; case $__cc_w in [A-Za-z_]*=*\$\(*|[A-Za-z_]*=*\`*) __cc_c=; __cc_w= ;; [A-Za-z_]*=\"*\"|[A-Za-z_]*="$__cc_q"*"$__cc_q") __cc_c=${__cc_c#"$__cc_w"}; __cc_c=${__cc_c#"${__cc_c%%[![:space:]]*}"}; __cc_w= ;; [A-Za-z_]*=*\"*|[A-Za-z_]*=*"$__cc_q"*) __cc_c=; __cc_w= ;; [A-Za-z_]*=*|exec|command) __cc_c=${__cc_c#"$__cc_w"}; __cc_c=${__cc_c#"${__cc_c%%[![:space:]]*}"}; __cc_w= ;; *) break ;; esac; done; case "$__cc_w" in "") ;; *) case " $CC_SPAWN_NAMES " in *" $__cc_w "*) type -t "$__cc_w" > "$CC_SPAWN_T.$__cc_pid" 2>/dev/null || :; __cc_t=; read -r __cc_t < "$CC_SPAWN_T.$__cc_pid" || :; [ "$__cc_t" != file ] || echo "$__cc_pid call $__cc_w ${FUNCNAME[*]:-main}" >> "$CC_SPAWN_LOG" ;; esac ;; esac; __cc_in=; }; :' DEBUG
ENVEOF

# build_stubs <dir> <log> <names-file> [<gh responses dir>] — one stub per
# name that resolves on the original PATH. The notifiers always get a stub that
# does nothing, and `gh` a stub that answers from the fixture's responses; a
# name the host does not have gets no stub, so `command -v` still says so.
# Every stub begins with the same two lines: the ` self` mark when its pid is
# the inherited `CC_SPAWN_SELF`, and its log line. Nothing in a stub forks.
#
# `sleep` is the cycle counter when `CC_SPAWN_SLEEP_CYCLE` is set: a call whose
# arguments are exactly that value bumps the count in `CC_SPAWN_SLEEP_COUNTER`
# and logs ` arg=<v> cycle=<k>`; it returns 0 at once until the count reaches
# `CC_SPAWN_SLEEP_STOP`, and then touches `<counter>.stop` and sleeps for a day
# instead of returning, until the tool kills the unit. Any other call sleeps.
build_stubs() {
  local dir=$1 log=$2 names=$3 resp=${4:-} n real head
  mkdir -p "$dir"
  head='#!/bin/sh\ns=; [ "$$" != "${CC_SPAWN_SELF:-}" ] || s=" self"\n'
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    case "$n" in
      terminal-notifier|osascript)
        printf "$head"'echo "$$ exec %s ppid=$PPID$s" >> "%s"\nexit 0\n' "$n" "$log" > "$dir/$n" ;;
      sleep)
        real=$(PATH=$ORIG_PATH type -P sleep) || continue
        {
          printf "$head"
          printf 'if [ -n "${CC_SPAWN_SLEEP_CYCLE:-}" ] && [ "$*" = "$CC_SPAWN_SLEEP_CYCLE" ]; then\n'
          printf '  k=0; read -r k < "$CC_SPAWN_SLEEP_COUNTER" || :; k=$((k + 1))\n'
          printf '  printf "%%s\\n" "$k" > "$CC_SPAWN_SLEEP_COUNTER"\n'
          printf '  echo "$$ exec sleep ppid=$PPID$s arg=$* cycle=$k" >> "%s"\n' "$log"
          printf '  [ "$k" -ge "$CC_SPAWN_SLEEP_STOP" ] || exit 0\n'
          printf '  : > "$CC_SPAWN_SLEEP_COUNTER.stop"\n'
          printf '  CC_SPAWN_SELF=$$; export CC_SPAWN_SELF\n  exec "%s" 86400\nfi\n' "$real"
          printf 'echo "$$ exec sleep ppid=$PPID$s" >> "%s"\n' "$log"
          printf 'CC_SPAWN_SELF=$$; export CC_SPAWN_SELF\nexec "%s" "$@"\n' "$real"
        } > "$dir/$n" ;;
      gh)
        {
          printf "$head"'echo "$$ exec gh ppid=$PPID$s" >> "%s"\n' "$log"
          printf 'key="$*"\n'
          printf 'if [ -f "%s/gh.tsv" ]; then\n' "$resp"
          printf '  while IFS="\t" read -r k rc out; do\n'
          printf '    if [ "$k" = "$key" ]; then\n'
          printf '      if [ -n "$out" ] && [ "$out" != - ]; then %s "%s/$out"; fi\n' "$(PATH=$ORIG_PATH type -P cat)" "$resp"
          printf '      exit "$rc"\n    fi\n  done < "%s/gh.tsv"\nfi\n' "$resp"
          printf 'echo "$key" >> "%s.gh-miss"\n' "$log"
          printf 'echo "gh stub: no fixture response for: $key" >&2\nexit 1\n'
        } > "$dir/gh" ;;
      *)
        real=$(PATH=$ORIG_PATH type -P "$n") || continue
        printf "$head"'echo "$$ exec %s ppid=$PPID$s" >> "%s"\nCC_SPAWN_SELF=$$; export CC_SPAWN_SELF\nexec "%s" "$@"\n' \
          "$n" "$log" "$real" > "$dir/$n" ;;
    esac
    chmod +x "$dir/$n"
  done < "$names"
}

# tally <log> <lines> — `<count> <fork lines> <stub lines> <self lines>
# <unattributed> <bypass> <distinct>` over the first <lines> lines of the log.
# <count> is the fork lines plus the stub lines without the ` self` mark.
# <bypass> is the call lines no stub line paired with: a command the trap saw
# run by name that did not go through its stub, i.e. a process the count missed.
# A target that puts other directories in front of the stubs is what produces
# it. <distinct> is the number of distinct pids, for diagnosis only.
tally() {
  head -n "$2" "$1" | awk '
    $2 == "call" { q[$1 SUBSEP $3]++; next }
    $2 == "fork" { pid[$1] = 1; nf++; next }
    $2 == "exec" {
      pid[$1] = 1; ne++; pp = $4; sub(/^ppid=/, "", pp)
      for (i = 5; i <= NF; i++) if ($i == "self") { ns++; break }
      if (q[$1 SUBSEP $3] > 0) q[$1 SUBSEP $3]--
      else if (q[pp SUBSEP $3] > 0) q[pp SUBSEP $3]--
      else un++
    }
    END {
      for (p in pid) d++; for (k in q) by += q[k]
      printf "%d %d %d %d %d %d %d\n", nf + ne - ns, nf, ne, ns, un, by, d
    }'
}

lines_of() { awk 'END { print NR }' "$1" 2>/dev/null || echo 0; }

calibrate() {
  local d="$WORK/calibrate" log
  mkdir -p "$d"
  log="$d/log"; : > "$log"
  printf 'grep\nsed\ntr\n' > "$d/names"
  build_stubs "$d/stubs" "$log" "$d/names"
  cat > "$d/target.sh" <<'EOF'
a=$(printf x)
b=$(sed -n 1p /dev/null)
( : )
grep -c x /dev/null >/dev/null
f() { c=$(tr a b </dev/null); }
f
n=0; while [ $n -lt 3 ]; do n=$((n+1)); done
/usr/bin/true
EOF
  ( unset CC_SPAWN_SELF CC_SPAWN_SLEEP_CYCLE
    export BASH_ENV="$ENVF" CC_SPAWN_LOG="$log" CC_SPAWN_T="$d/t" CC_SPAWN_NAMES="grep sed tr" \
      CC_SPAWN_STUBS="$d/stubs"
    PATH="$d/stubs:$ORIG_PATH"; exec "$REAL_BASH" "$d/target.sh" ) || die2 "교정 대상이 실패했습니다"
  set -- $(tally "$log" "$(lines_of "$log")")
  printf 'calibrate=%s\ncalibrate.fork=%s\ncalibrate.exec=%s\ncalibrate.self=%s\ncalibrate.unattributed=%s\ncalibrate.distinct=%s\n' \
    "$1" "$2" "$3" "$4" "$5" "$7"
}

# ---------------------------------------------------------------------------
# Units
# ---------------------------------------------------------------------------

# subst <value> — the placeholders of the spec format, filled.
subst() {
  local v=$1
  v=${v//@ROOT@/$ROOT}; v=${v//@REPO@/$REPO}; v=${v//@ORCH@/$ORCH}; v=${v//@HOOKS@/$HOOKS}
  v=${v//@EMPTY@/$EMPTY}; v=${v//@NOW@/$NOW}; v=${v//@H@/$H}
  printf '%s' "$v"
}

# fill_tree <dir> — the placeholders filled in every copied file.
fill_tree() {
  local f
  find "$1" -type f | while IFS= read -r f; do
    grep -q '@[A-Z]*@' "$f" 2>/dev/null || continue
    LC_ALL=C sed -e "s|@ROOT@|$ROOT|g" -e "s|@REPO@|$REPO|g" -e "s|@NOW@|$NOW|g" \
      -e "s|@ORCH@|$ORCH|g" "$f" > "$f.fill" && mv "$f.fill" "$f"
  done
}

# chain <ledger> <run-id> — every `prev=@PREV@` replaced by the digest of the
# row before it, anchored on the block heading as `gate_chain_verify` is.
chain() {
  local f=$1 rid=$2 prev line out
  prev=$(printf '%s' "## 실행 ${rid}" | sha256)
  out="$f.chain"; : > "$out"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "- \`"*"prev=@PREV@")
        line=${line%@PREV@}$prev
        printf '%s\n' "$line" >> "$out"
        prev=$(printf '%s' "$line" | sha256) ;;
      *) printf '%s\n' "$line" >> "$out" ;;
    esac
  done < "$f"
  mv "$out" "$f"
}

# manifest_fill <manifest> — the target-map, plan and binding digests a
# kickoff writes, computed from the filled manifest.
manifest_fill() {
  local m=$1 td pd bd line
  td=$(grep '^- `target` ' "$m" | sed 's/[[:space:]]\{1,\}/ /g' | LC_ALL=C sort | sha256)
  pd=$(awk '/^```json$/ { f = 1; next } f && /^```$/ { exit } f' "$m" | sha256)
  LC_ALL=C sed -e "s|@TD@|$td|" -e "s|@PD@|$pd|" "$m" > "$m.fill" && mv "$m.fill" "$m"
  bd=$(cd "$(dirname "$m")" && CC_ORCH_SOURCE_ONLY=1 MANIFEST="$m" "$REAL_BASH" -c \
    '. "$1/run.sh"; MANIFEST="$2"; binding_set_bytes' _ "$ORCH" "$m" | sha256)
  [ -n "$bd" ] || die2 "구속 다이제스트 계산 실패: $m"
  : > "$m.fill"
  while IFS= read -r line || [ -n "$line" ]; do
    printf '%s\n' "$line" >> "$m.fill"
    [ "$line" = "## 인가" ] && printf '**구속 다이제스트**: %s\n' "$bd" >> "$m.fill"
  done < "$m"
  mv "$m.fill" "$m"
}

# kill_tree <pid…> — each launched target and its whole process group, by KILL.
# The count is already cut at a log line when this runs, so how a target tears
# down does not matter; and `checks.sh` answers TERM by releasing its pid file
# and carrying on, so a TERM would leave the wait below hanging.
kill_tree() {
  local p
  for p in "$@"; do kill -KILL -- "-$p" 2>/dev/null || kill -KILL "$p" 2>/dev/null; done
  for p in "$@"; do wait "$p" 2>/dev/null; done
}

# run_once <labels> — one measurement of the parsed spec (`K`, `V`, `A`, `NROWS`
# of `measure_unit`) with only the argv labels given, from a fresh copy root.
# Sets `R_COUNT R_FORK R_EXEC R_SELF R_UN R_BY R_DIST` from the tally and
# `R_EL`, the seconds the measured window took.
run_once() {
  local want_labels=$1 i label n=$NROWS cut t0 rc p
  ROOT=$(mktemp -d "$WORK/$U.XXXXXX") && ROOT=$(cd "$ROOT" && pwd -P) || die2 "mktemp 실패"
  EMPTY=$(mktemp -d "$WORK/$U-empty.XXXXXX") || die2 "mktemp 실패"
  NOW=$(date +%s); H=""
  local log="$WORK/$U.$NOW.$RANDOM.log" stubs in=/dev/null cwd="$ROOT" lives="" labels=$want_labels
  : > "$log"
  stubs="$log.stubs"

  for ((i = 0; i < n; i++)); do
    [ "${K[i]}" = env ] || continue
    if [ "${A[i]}" = @UNSET@ ]; then unset "${V[i]}"; else export "${V[i]}=$(subst "${A[i]}")"; fi
  done

  for ((i = 0; i < n; i++)); do
    [ "${K[i]}" = fixture ] || continue
    set -- $(subst "${A[i]}")
    case "${V[i]}" in
      copy)
        [ -d "$RUNS/$1" ] || die2 "${U}: 픽스처 디렉터리가 없습니다 — runs/$1"
        mkdir -p "$ROOT/$2" && cp -R "$RUNS/$1/." "$ROOT/$2/" && fill_tree "$ROOT/$2" ;;
      chain) chain "$ROOT/$1" "$2" ;;
      mkdir) mkdir -p "$ROOT/$1" ;;
      chmod) chmod +x "$ROOT/$1" ;;
      live)
        sleep 600 &
        p=$!
        disown "$p" 2>/dev/null
        lives="$lives $p"
        printf '%s' "$p" > "$ROOT/$1.pid"
        LC_ALL=C ps -o lstart= -p "$p" | sed 's/[[:space:]]\{1,\}/ /g;s/^ //;s/ $//' > "$ROOT/$1.start" ;;
      git)
        ( cd "$ROOT/$1" && git init -q . && git config user.email t@example.invalid \
            && git config user.name T && git add -A && git commit -qm fixture \
            && git branch -M main ) >/dev/null 2>&1 || die2 "${U}: git 픽스처 실패" ;;
      manifest) manifest_fill "$ROOT/$1" ;;
      snapshot)
        H=$(cd "$cwd" && "$REAL_BASH" "$ORCH/gate.sh" snapshot --manifest "$ROOT/$1" --fields H 2>"$WORK/$U.snapshot.err")
        [ -n "$H" ] || { sed 's/^/  /' "$WORK/$U.snapshot.err" >&2; die2 "${U}: 스냅숏 다이제스트를 얻지 못했습니다"; } ;;
      gate)
        ( cd "$cwd" && env -u CC_PIPELINE_STAGE_ID -u CC_PIPELINE_SEGMENT "$REAL_BASH" "$ORCH/gate.sh" "$@" ) \
          > "$WORK/$U.gate.$i" 2>&1 || {
          tail -n 20 "$WORK/$U.gate.$i" | sed 's/^/  /' >&2
          die2 "${U}: 준비 게이트 호출이 실패했습니다 — $*"
        } ;;
      stdin) in="$ROOT/$1" ;;
      cwd) cwd="$ROOT/$1" ;;
      *) die2 "${U}: 알 수 없는 fixture 동사 — ${V[i]}" ;;
    esac
  done

  for ((i = 0; i < n; i++)); do
    [ "${K[i]}" = mtime ] || continue
    perl -e 'my ($f, $t) = @ARGV; utime $t, $t, $f or die "utime $f: $!\n";' \
      "$ROOT/${V[i]}" "$((NOW + ${A[i]}))" || die2 "${U}: mtime 적용 실패 — ${V[i]}"
  done

  local stop="" sarg="" rfile="" rlabels="" rewrite=0
  for ((i = 0; i < n; i++)); do
    [ "${K[i]}" = stop ] || continue
    case "${V[i]}" in
      exit|stub-count|sleep-cycles) stop=${V[i]}; sarg=${A[i]} ;;
      rewrite)
        set -- ${A[i]}
        rfile="$ROOT/$1"; shift; rlabels=" $* " ;;
    esac
  done
  if [ -n "$rfile" ]; then
    rewrite=1
    if [ "$rlabels" != "  " ]; then
      rewrite=0
      for label in $labels; do
        case "$rlabels" in *" $label "*) rewrite=1 ;; esac
      done
    fi
  fi
  local cyc_n="" cyc_arg="" cyc_limit="" counter="$log.sleepn"
  if [ "$stop" = sleep-cycles ]; then
    set -- $sarg
    [ "$#" -eq 5 ] && [ "$2" = arg ] && [ "$4" = limit ] || die2 "${U}: sleep-cycles 꼴이 아닙니다 — $sarg"
    cyc_n=$1 cyc_arg=$3 cyc_limit=$5
    printf '0\n' > "$counter"
  fi

  build_stubs "$stubs" "$log" "$SPECD/stubs" "$ROOT/gh"
  local names pids="" p
  names=$(tr '\n' ' ' < "$SPECD/stubs")
  set -m
  for label in $labels; do
    local -a args=()
    for ((i = 0; i < n; i++)); do
      [ "${K[i]}" = argv ] && [ "${V[i]}" = "$label" ] && args[${#args[@]}]=$(subst "${A[i]}")
    done
    ( cd "$cwd" || exit 97
      unset CC_SPAWN_SELF CC_SPAWN_SLEEP_CYCLE CC_SPAWN_SLEEP_STOP CC_SPAWN_SLEEP_COUNTER
      export BASH_ENV="$ENVF" CC_SPAWN_LOG="$log" CC_SPAWN_T="$log.t" CC_SPAWN_NAMES="$names" \
        CC_SPAWN_STUBS="$stubs"
      if [ -n "$cyc_n" ]; then
        export CC_SPAWN_SLEEP_CYCLE="$cyc_arg" CC_SPAWN_SLEEP_STOP="$cyc_n" CC_SPAWN_SLEEP_COUNTER="$counter"
      fi
      PATH="$stubs:$PATH"
      exec "$REAL_BASH" "${args[@]}" ) < "$in" > "$WORK/$U.out.$label" 2> "$WORK/$U.err.$label" &
    pids="$pids $!"
  done
  set +m

  t0=$SECONDS rc=0
  case "$stop" in
    exit)
      for p in $pids; do
        while kill -0 "$p" 2>/dev/null; do
          [ $((SECONDS - t0)) -lt "$UNIT_TIMEOUT" ] || { kill_tree $pids; die2 "${U}: 끝나지 않았습니다"; }
          sleep 0.2
        done
        wait "$p"; p=$?
        [ "$p" -eq 0 ] || rc=$p
      done
      cut=$(lines_of "$log") ;;
    sleep-cycles)
      # The stub touches `<counter>.stop` on the last cycle's sleep; a target
      # that exits first, or a window longer than the spec's limit, fails the
      # measurement rather than yielding a count.
      local tick=$SECONDS alive
      while [ ! -f "$counter.stop" ]; do
        if [ "$rewrite" = 1 ] && [ "$SECONDS" -ne "$tick" ]; then
          tick=$SECONDS
          printf 'quiet %s\n' "$(date +%s)" > "$rfile"
        fi
        if [ $((SECONDS - t0)) -gt "$cyc_limit" ]; then
          kill_tree $pids
          die2 "${U}: ${labels# } 측정이 벽시계 상한 ${cyc_limit}초를 넘었습니다 (주기 $(cat "$counter")/${cyc_n})"
        fi
        alive=0
        for p in $pids; do kill -0 "$p" 2>/dev/null && alive=1; done
        if [ "$alive" = 0 ]; then
          [ -f "$counter.stop" ] && break
          for label in $labels; do tail -n 20 "$WORK/$U.err.$label" | sed 's/^/  /' >&2; done
          die2 "${U}: ${labels# } 이 ${cyc_n}번째 주기 대기 전에 끝났습니다 (주기 $(cat "$counter"))"
        fi
        sleep 0.05
      done
      cut=$(awk -v w="cycle=$cyc_n" '$2 == "exec" && $3 == "sleep" && $NF == w { print NR; exit }' "$log")
      kill_tree $pids
      [ -n "$cut" ] || die2 "${U}: ${cyc_n}번째 주기 대기 줄이 기록에 없습니다"
      [ $((SECONDS - t0)) -le "$cyc_limit" ] || die2 "${U}: ${labels# } 측정이 벽시계 상한 ${cyc_limit}초를 넘었습니다" ;;
    stub-count)
      set -- $sarg
      local sname=$1 want=$2 tick=$SECONDS
      while :; do
        n=$(grep -c " exec $sname " "$log")
        [ "$n" -ge "$want" ] && break
        if [ "$rewrite" = 1 ] && [ "$SECONDS" -ne "$tick" ]; then
          tick=$SECONDS
          printf 'quiet %s\n' "$(date +%s)" > "$rfile"
        fi
        [ $((SECONDS - t0)) -lt "$UNIT_TIMEOUT" ] || { kill_tree $pids; die2 "${U}: 스텁 기록이 ${want}번에 이르지 않았습니다"; }
        sleep 0.05
      done
      cut=$(awk -v s="$sname" -v w="$want" '$2 == "exec" && $3 == s { c++; if (c == w) { print NR; exit } }' "$log")
      kill_tree $pids ;;
    *) kill_tree $pids; die2 "${U}: stop 행이 없습니다" ;;
  esac
  R_EL=$((SECONDS - t0))
  [ -z "$lives" ] || kill $lives 2>/dev/null

  for label in $labels; do
    if [ -n "${CC_MEASURE_SPAWN_SHOW:-}" ]; then
      printf '%s %s 표준 출력:\n' "$U" "$label" >&2; sed 's/^/  /' "$WORK/$U.out.$label" >&2
      printf '%s %s 표준 오류:\n' "$U" "$label" >&2; sed 's/^/  /' "$WORK/$U.err.$label" >&2
    fi
    if [ "$rc" -ne 0 ]; then
      printf '%s %s 표준 오류 끝:\n' "$U" "$label" >&2
      tail -n 20 "$WORK/$U.err.$label" | sed 's/^/  /' >&2
    fi
  done
  [ "$rc" -eq 0 ] || die2 "${U}: 대상이 종료 코드 ${rc} 로 끝났습니다"
  if [ -s "$log.gh-miss" ]; then
    sed 's/^/  /' "$log.gh-miss" >&2
    die2 "${U}: gh 스텁에 픽스처 응답이 없는 호출이 있었습니다"
  fi
  # The unit's own evidence that it ran the path its spec names: an output that
  # carries a text, a file that carries one, a file that was not written.
  for ((i = 0; i < n; i++)); do
    [ "${K[i]}" = stop ] || continue
    set -- ${A[i]}
    case "${V[i]}" in
      expect)
        label=$1; shift
        case " $labels " in *" $label "*) ;; *) continue ;; esac
        grep -qF -- "$*" "$WORK/$U.out.$label" || {
          tail -n 20 "$WORK/$U.err.$label" | sed 's/^/  /' >&2
          die2 "${U}: $label 출력에 기대한 문자열이 없습니다 — $*"
        } ;;
      file-has)
        label=$1; shift
        grep -qF -- "$*" "$ROOT/$label" 2>/dev/null || die2 "${U}: ${label} 에 기대한 문자열이 없습니다 — $*" ;;
      no-file)
        [ ! -e "$ROOT/$1" ] || die2 "${U}: 생기지 말아야 할 파일이 생겼습니다 — $1" ;;
    esac
  done

  set -- $(tally "$log" "$cut")
  R_COUNT=$1 R_FORK=$2 R_EXEC=$3 R_SELF=$4 R_UN=$5 R_BY=$6 R_DIST=$7
  [ "$1" -ge 1 ] || die2 "${U}: 센 프로세스가 없습니다 — 계수 장치가 죽었습니다"
}

# measure_unit <U> — runs in a subshell; prints the unit's key=value lines.
# Under `stop each` every argv label is measured by its own `run_once` and the
# unit's values are the sums, with each label's count beside them as
# `<U>.<label>=`.
measure_unit() {
  U=$1
  local spec="$SPECD/$1" kind key val i n labels="" each=0 label
  local s_count=0 s_fork=0 s_exec=0 s_self=0 s_un=0 s_by=0 s_dist=0
  [ -f "$spec" ] || die2 "명세가 없습니다: $spec"

  for n in $(compgen -e); do
    case "$n" in CC_PIPELINE_*) unset "$n" ;; esac
  done
  export CC_CMDS_AUTOPILOT_NOTIFY=off

  i=0
  while IFS=$'\t' read -r kind key val || [ -n "$kind" ]; do
    case "$kind" in ''|'#'*) continue ;; esac
    K[i]="$kind"; V[i]="$key"; A[i]="$val"; i=$((i + 1))
  done < "$spec"
  NROWS=$i

  for ((i = 0; i < NROWS; i++)); do
    [ "${K[i]}" = stop ] && [ "${V[i]}" = each ] && each=1
    [ "${K[i]}" = argv ] || continue
    case " $labels " in *" ${V[i]} "*) ;; *) labels="$labels ${V[i]}" ;; esac
  done
  [ -n "$labels" ] || die2 "${U}: argv 행이 없습니다"

  if [ "$each" = 1 ]; then
    for label in $labels; do
      run_once "$label"
      printf '%s.%s=%s\n%s.%s.cycles-seconds=%s\n' "$U" "$label" "$R_COUNT" "$U" "$label" "$R_EL"
      s_count=$((s_count + R_COUNT)) s_fork=$((s_fork + R_FORK)) s_exec=$((s_exec + R_EXEC))
      s_self=$((s_self + R_SELF)) s_un=$((s_un + R_UN)) s_by=$((s_by + R_BY)) s_dist=$((s_dist + R_DIST))
    done
  else
    run_once "$labels"
    s_count=$R_COUNT s_fork=$R_FORK s_exec=$R_EXEC s_self=$R_SELF s_un=$R_UN s_by=$R_BY s_dist=$R_DIST
  fi
  printf '%s=%s\n%s.fork=%s\n%s.exec=%s\n%s.self=%s\n%s.unattributed=%s\n%s.bypass=%s\n%s.distinct=%s\n' \
    "$U" "$s_count" "$U" "$s_fork" "$U" "$s_exec" "$U" "$s_self" "$U" "$s_un" "$U" "$s_by" "$U" "$s_dist"
}

run_units() {
  local u
  for u in "$@"; do
    ( measure_unit "$u" ) || exit 2
  done
}

baseline_table() {
  local units t
  units=$(run_units $UNITS) || exit 2
  printf 'kind\tkey\tvalue\n'
  for t in $UNITS; do
    printf 'unit\t%s\t%s\n' "$t" "$(printf '%s\n' "$units" | sed -n "s/^$t=//p")"
  done
  for t in $TARGETS; do
    printf 'abspath\t%s\t%s\n' "$t" "$(abspath_count "$t")"
  done
  cond_rows
}

# A fixture file git ignores is hashed into `fixture` and copied by a spec
# here, but never reaches a commit: every other tree then measures without it
# and its test skips every run assertion. Refuse such a file wherever the
# fixtures are read. A tree with no `.git` (an archive) has nothing to
# compare; a git that fails inside a repository stops the tool, since an empty
# answer from it would read as "nothing ignored".
ignored_fixtures() {
  ( cd "$REPO" || exit 1
    [ -e .git ] || exit 0
    git ls-files --others --ignored --exclude-standard --directory -- tests/fixtures/measure-spawn-count/runs )
}
case "$MODE" in
  cond|unit|all|baseline|reproduce)
    IGN=$(ignored_fixtures) || die2 "무시된 픽스처를 git 으로 확인하지 못했습니다"
    [ -z "$IGN" ] || die2 "git 이 무시하는 픽스처가 있어 커밋된 트리에서 재현되지 않습니다 — $(printf '%s' "$IGN" | tr '\n' ' ')" ;;
esac

FP0=$(fixture_bytes all | sha256)
check_fixture() {
  [ "$(fixture_bytes all | sha256)" = "$FP0" ] || die2 "측정 뒤 커밋된 픽스처가 바뀌었습니다"
}

case "$MODE" in
  static) static_report ;;
  names) all_names ;;
  extract) extract "$ONE" ;;
  calibrate) calibrate ;;
  cond) cond_rows ;;
  unit) run_units "$ONE" || exit 2; check_fixture ;;
  all) static_report; calibrate; run_units $UNITS || exit 2; check_fixture ;;
  baseline) baseline_table || exit 2; check_fixture ;;
  reproduce)
    baseline_table > "$WORK/baseline.now" || exit 2
    check_fixture
    if cmp -s "$WORK/baseline.now" "$BASELINE"; then
      printf 'reproduce=same\n'
    else
      diff "$BASELINE" "$WORK/baseline.now" | sed 's/^/  /' >&2
      printf 'reproduce=different\n'
      exit 1
    fi ;;
esac
exit 0
