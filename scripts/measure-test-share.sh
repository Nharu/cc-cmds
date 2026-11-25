#!/usr/bin/env bash
# Measure how much of the cc-cmds stages went to running tests, in one of two
# modes:
#
#   no --ledger-dir and no --lane-root   the run-log report: every stage log under
#                                        the run root, grouped before and after
#                                        the time scripts/check-push-ci.tsv
#                                        entered origin/master
#   both of them                         the session table: one TSV row per
#                                        implement session, and a verdict
#
# This is NOT a gate. Nothing here blocks a run; the output is the evidence a
# person reads to decide whether the rerun discipline worked. `make test` runs
# it against synthetic fixtures only, never against real history.
#
# ---- the run-log report ----
#
# What it reads:
#
#   stage logs     `<run root>/<run>/log/<stage>#<attempt>.json`, the stream-json
#                  of one stage. `shift-<n>.json` is not a stage. The run root is
#                  `--run-root`, else ${XDG_STATE_HOME:-$HOME/.local/state}/
#                  cc-cmds/run; a default that does not exist is no sample. A
#                  test points XDG_STATE_HOME at its fixture.
#   run ledgers    `docs/pipeline-run/<run>.md` of the main checkout of the
#                  repository this script is in. The row whose `스테이지`·`실행
#                  버전` is the log's name gives the kind (`종류=`); a row with a
#                  segment counts only when that segment's `레포=` is
#                  Nharu/cc-cmds. implement, reconverge, review and lead-fix are
#                  reported (a base resolution is recorded as implement). A run
#                  starts at its first `run` row's `시작=`. A stage with no
#                  ledger or no row is counted in the kind row `없음` only.
#
# The boundary is the time scripts/check-push-ci.tsv entered the first-parent
# history of origin/master (HEAD without that ref), read without the network. A
# run that started at it or later is `이후`, an earlier one `이전`, and a stage
# that started after it in an earlier run is `걸침`, counted apart and in neither
# group. Without a boundary there is one group, `전체`. The window is from seven
# days before the boundary (before now without one) to now; `--since` and
# `--until` change it, and a run is in it by its start.
#
# How time is counted: only `assistant` and `user` records carry a time. A test
# is a Bash call the list below names. It ends at the later of its tool result
# and its task notification, whose time is that of the next timed record in the
# file. A background test with no notification runs to the last timed record and
# is counted apart. A call a hook or the gate refused did not run and is left
# out. Waiting is the part of a gap of 30 seconds or more between two records in
# which a test was running.
#
# A check-push that names no section and no goal is `고정 검사`. Any other test
# is compared with the earlier runs of the stage: the same command again is
# `같은 입력` with no edit (Edit, Write, MultiEdit, NotebookEdit, `git commit`)
# since its last run and `고친 뒤 전부 재실행` with one; another command of a tool
# that ran before is `고친 뒤 일부 재실행` with an edit since that tool's last
# run; everything else is `첫 실행`.
#
# A check-push ends by its notification, or its tool result in the foreground:
# `상한 잘림` when the limit stopped it, `종료 0`, `미완` when its output has the
# unfinished line, else `실패`; `알림 없음` when nothing told its end. The output
# is the tool result's text and the notification's output file while it exists.
#
# The report has no verdict and no target number. With no `이후` stage it says
# `이후 표본 없음`.
#
# ---- the session table ----
#
# What it reads:
#
#   run ledgers        `--ledger-dir`, only the files named
#                      `<8-digit date>-<8 lowercase hex>.md`. Every other file in
#                      that directory (plan, interview, kickoff and
#                      classification side files, handoff notes, aborted
#                      ledgers, metrics) is skipped without a word.
#   sessions           every `stage-result` row with `종류=implement` whose
#                      segment row in the same ledger names `--repo`. A session
#                      id seen twice is one session — a resumed attempt writes
#                      into the same transcript.
#   transcripts        `<lane>/projects/*/<session id>.jsonl`, where `<lane>` is
#                      the row's `레인=` with its leading `~` replaced by
#                      `--lane-root`. A session with no transcript is shown as
#                      `기록 없음`, left out of the sums and not counted by
#                      `--first`.
#   idle sessions      a session whose transcript holds no test command and no
#                      `git commit` call is shown with `제외` in the share
#                      column, left out of the sums and not counted by
#                      `--first`. Such a stage stopped before writing code —
#                      on a halt record, or after producing only a plan — so
#                      its time says nothing about how much of the work went
#                      to tests.
#
# This mode wants both `--ledger-dir` and `--lane-root`; one of them alone is a
# usage error. The lane root has NO default pointing at a real home directory:
# with a default, a fixture test that forgot the argument would read real session
# history and pass or fail depending on the machine. A call with neither reads no
# session history: it is the run-log report above.
#
# A run's start is the `시작=` of the ledger's first `run` row (shift 0). A run
# started before a cut-off and resumed after it therefore stays before it.
#
# What counts as a test command. The command is split into words honouring
# single and double quotes, then:
#   1. a command whose first word ends in `gate.sh` and whose second word is
#      `exec` is cut after the first unquoted `--` (the `--rationale` text is
#      quoted, so a ` -- ` inside it does not cut);
#   2. leading `VAR=value` assignments are skipped;
#   3. for `make`, the options `-C <dir>`, `-f <file>`, `-j<n>`, `-j <n>` and
#      `VAR=value` arguments are skipped, and the command is a test command when
#      any remaining word is one of the make targets in TEST_COMMANDS below;
#      for anything else the leading words must match an entry of that list.
#
# How time is counted:
#   - a foreground test runs from its tool call to the paired tool result;
#   - a background test runs from its tool call to the task notification that
#     names the task id its tool result reported. A notification counts only
#     when it was delivered: the string content of a `type: user` record, or
#     the `prompt` of a `queued_command` attachment. Notification text quoted
#     in assistant text, in a tool result or in any other record does not
#     count. With several notifications for one task id the earliest is used.
#     Without one it runs to the session's last event and is counted as
#     `unclosed`;
#   - test time is the union of those intervals;
#   - stage time is the sum of the gaps between consecutive session events,
#     leaving out every gap longer than 15 minutes unless a test interval spans
#     it;
#   - `same_set_relaunch` counts test launches whose normalised command equals
#     the previous test launch's, with no Edit/Write call and no `git commit` in
#     between. It is a diagnostic column, not part of the share.
#
# Output: a header, one row per session
#   run  segment  session  stage_min  test_min  share  bg_launches  same_set_relaunch  unclosed
# then two lines: `시험 몫 = <Σ test>/<Σ stage> = <percent>` and
# `판정: 달성|미달|표본 부족`. Below 30% is 달성. Fewer counted sessions
# (with a transcript and not idle) than `--first n` asked for is 표본 부족.
#
# How the release check is run. The sessions live under the Claude
# configuration home, which an unattended stage cannot read, so a person runs
# this from the main checkout:
#   - `--since` is the later of two UTC times, written YYYY-MM-DDTHH:MM:SSZ:
#     the release time, which is the committer time of the
#     `chore(release): vX.Y.Z` commit that shipped this script read in UTC
#     (`git log -1 --format=%cI <commit>`, converted to Z) — the CHANGELOG
#     heading carries only a date, and a day can hold more than one release —
#     and the time the person applied the rerun discipline to the repository's
#     instructions, which that person decides;
#   - `--first 10` takes the first ten cc-cmds implement stages that started
#     after it;
#   - the share must come out below 30%.
#   For example:
#     scripts/measure-test-share.sh --ledger-dir docs/pipeline-run \
#       --lane-root "$HOME" --since 2026-10-24T09:00:00Z --first 10
#
# Usage:
#   scripts/measure-test-share.sh [--run-root <dir>] [--since <date|time>]
#     [--until <date|time>]
#   scripts/measure-test-share.sh --ledger-dir <dir> --lane-root <dir>
#     [--repo <owner/name>] [--since <date|time>] [--until <date|time>]
#     [--first <n>] [--session <uuid>]
#   A bare date reads as 00:00:00Z for --since and 23:59:59Z for --until.
#
# Exit codes:
#   0 — the report, or the rows (possibly zero; the headers and the two lines of
#       the session table always print)
#   2 — usage error / unreadable input: one of --ledger-dir and --lane-root
#       without the other, --repo, --first or --session without them, --run-root
#       with either, a given --run-root that is not a directory

set -euo pipefail

# The fixed list of test commands. A `make` entry names one target pattern; a
# `bash` entry names the script it runs; any other entry names the program.
# `*` matches within one word. A path entry also matches with a directory in
# front of it, so an absolute path to the same script counts.
TEST_COMMANDS=(
  'make check'
  'make check-*'
  'make test'
  'make test-*'
  'make lint'
  'make lint-*'
  'make run/scripts/test-*.sh'
  'make run-*-selftest'
  'make rest-shard'
  'bash scripts/test-*.sh'
  'bash scripts/lint-*.sh'
  'bash scripts/check-push.sh'
  'bash plugins/cc-cmds/orchestrator/test-run.sh'
  'scripts/suite-guard.sh'
  'gate-shard'
)

mode="sessions"
ledger_dir=""
lane_root=""
old_roots=""
run_root=""
run_root_set=""
old_only=""
repo="Nharu/cc-cmds"
since=""
until_t=""
first=""
only_session=""

usage_die() { echo "measure-test-share: $1" >&2; exit 2; }

while (( $# > 0 )); do
  case "$1" in
    --ledger-dir) ledger_dir="${2:-}"; old_roots=1; shift 2 ;;
    --lane-root)  lane_root="${2:-}"; old_roots=1; shift 2 ;;
    --run-root)
      (( $# >= 2 )) || usage_die "--run-root takes a directory"
      run_root="$2"; run_root_set=1; shift 2
      ;;
    --repo)       repo="${2:-}"; old_only="$1"; shift 2 ;;
    --since)      since="${2:-}"; shift 2 ;;
    --until)      until_t="${2:-}"; shift 2 ;;
    --first)      first="${2:-}"; old_only="$1"; shift 2 ;;
    --session)    only_session="${2:-}"; old_only="$1"; shift 2 ;;
    -h|--help)
      grep -E '^# ' "$0" | cut -c3-
      exit 0
      ;;
    *) usage_die "unknown argument: $1" ;;
  esac
done

if [[ -z "$old_roots" ]]; then
  mode="runs"
  [[ -z "$old_only" ]] || usage_die "$old_only goes with --ledger-dir and --lane-root"
  if [[ -n "$run_root_set" ]]; then
    [[ -d "$run_root" ]] || usage_die "run root not found: $run_root"
  else
    run_root="${XDG_STATE_HOME:-${HOME:-}/.local/state}/cc-cmds/run"
  fi
else
  [[ -z "$run_root_set" ]] || usage_die "--run-root does not go with --ledger-dir or --lane-root"
  [[ -n "$ledger_dir" ]] || usage_die "--ledger-dir <dir> is required with --lane-root"
  [[ -d "$ledger_dir" ]] || usage_die "ledger directory not found: $ledger_dir"
  [[ -n "$lane_root" ]] || usage_die "--lane-root <dir> is required with --ledger-dir — there is deliberately no default"
  [[ -d "$lane_root" ]] || usage_die "lane root not found: $lane_root"
fi
[[ -n "$repo" ]] || usage_die "--repo must not be empty"
if [[ -n "$first" ]] && ! [[ "$first" =~ ^[1-9][0-9]*$ ]]; then
  usage_die "--first takes a positive integer (got: $first)"
fi

# norm_time <value> <time for a bare date> — the UTC form the ledger writes.
norm_time() {
  if [[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    printf '%sT%sZ' "$1" "$2"
  elif [[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
    printf '%s' "$1"
  else
    return 1
  fi
}
if [[ -n "$since" ]]; then
  since=$(norm_time "$since" 00:00:00) || usage_die "--since takes YYYY-MM-DD or YYYY-MM-DDTHH:MM:SSZ (got: $since)"
fi
if [[ -n "$until_t" ]]; then
  until_t=$(norm_time "$until_t" 23:59:59) || usage_die "--until takes YYYY-MM-DD or YYYY-MM-DDTHH:MM:SSZ (got: $until_t)"
fi

command -v jq >/dev/null 2>&1 || usage_die "jq is required"

# ---- sessions from the ledgers ---------------------------------------------
# One line per implement session: start, run id, order in the ledger, segment,
# session id, lane.
sessions_of_ledger() {
  awk -v want_repo="$1" -v run_id="$2" '
    function field(row, key,    n, parts, i, kv) {
      n = split(row, parts, / \| /)
      for (i = 2; i <= n; i++) {
        kv = parts[i]
        if (index(kv, key "=") == 1) return substr(kv, length(key) + 2)
      }
      return ""
    }
    /^- `run` \| / {
      if (start == "") start = field($0, "시작")
      next
    }
    /^- `segment` \| / {
      id = field($0, "id"); r = field($0, "레포")
      if (id != "" && r != "") repo_of[id] = r
      next
    }
    /^- `stage-result` \| / {
      if (field($0, "종류") != "implement") next
      nres++
      seg[nres] = field($0, "세그먼트")
      sid[nres] = field($0, "세션 id")
      lane[nres] = field($0, "레인")
      next
    }
    END {
      if (start == "") exit
      for (i = 1; i <= nres; i++) {
        if (sid[i] == "" || sid[i] == "-") continue
        if (repo_of[seg[i]] != want_repo) continue
        printf "%s\t%s\t%d\t%s\t%s\t%s\n", start, run_id, i, seg[i], sid[i], lane[i]
      }
    }
  ' "$3"
}

all_sessions=$(
  for f in "$ledger_dir"/*.md; do
    [[ -f "$f" ]] || continue
    name=$(basename "$f")
    [[ "$name" =~ ^[0-9]{8}-[0-9a-f]{8}\.md$ ]] || continue
    sessions_of_ledger "$repo" "${name%.md}" "$f"
  done | sort -t "$(printf '\t')" -k1,1 -k2,2 -k3,3n
)

# ---- one transcript → events ------------------------------------------------
# E <epoch>                         any record with a timestamp
# B <epoch> <id> <bg> <command>     a Bash tool call
# M <epoch>                         an Edit/Write tool call
# R <epoch> <tool_use_id> <task id> a tool result (task id or -)
# N <epoch> <task id>               a delivered task notification (user string
#                                   content or queued_command attachment prompt)
events_of() {
  jq -R -r '
    def epoch: sub("\\.[0-9]+"; "") | fromdateiso8601;
    def texts: if type == "string" then .
               elif type == "array" then map(if type == "object" then (.text // .content // "" | if type == "string" then . else tostring end) else tostring end) | join(" ")
               else "" end;
    def notes($t): strings | select(test("<task-notification>"))
                   | [scan("<task-id>([^<]+)</task-id>")[0]] | .[] | "N\t\($t)\t\(.)";
    fromjson? | select(type == "object") | select(.timestamp != null)
    | (.timestamp | epoch | tostring) as $t
    | "E\t\($t)",
      ( if .type == "attachment" then
          ( select((.attachment | type) == "object" and .attachment.type == "queued_command")
            | .attachment.prompt | notes($t) )
        else
          ( (.message.content // empty) as $c
            | if ($c | type) == "array" then
                ( $c[] | select(type == "object") |
                  if .type == "tool_use" and .name == "Bash" then
                    "B\t\($t)\t\(.id)\t\(if .input.run_in_background == true then 1 else 0 end)\t\(.input.command // "" | gsub("[\t\n\r]"; " "))"
                  elif .type == "tool_use" and (.name == "Edit" or .name == "Write" or .name == "MultiEdit" or .name == "NotebookEdit") then
                    "M\t\($t)"
                  elif .type == "tool_result" then
                    (.content | texts) as $x
                    | "R\t\($t)\t\(.tool_use_id)\t\(($x | capture("with ID: (?<i>[A-Za-z0-9_-]+)") | .i) // "-")"
                  else empty end )
              elif .type == "user" then
                ( $c | notes($t) )
              else empty end )
        end )
  ' "$1" 2>/dev/null || true
}

# ---- the classifier both modes share ----------------------------------------
# awk functions and a BEGIN block. They want `-v sq="'"` and the list in the
# environment as MTS_TEST_COMMANDS: BSD awk refuses a newline inside a `-v`
# value.
AWK_CLASSIFY='
    function tokenize(s,    i, c, n, cur, has, q, inq, L) {
      n = 0; cur = ""; has = 0; q = 0; inq = ""; L = length(s)
      for (i = 1; i <= L; i++) {
        c = substr(s, i, 1)
        if (inq == sq) {
          if (c == sq) inq = ""; else cur = cur c
        } else if (inq == "\"") {
          if (c == "\\" && i < L && index("\"\\$`", substr(s, i + 1, 1)) > 0) { i++; cur = cur substr(s, i, 1) }
          else if (c == "\"") inq = ""
          else cur = cur c
        } else if (c == " " || c == "\t") {
          if (has) { n++; TOK[n] = cur; TQ[n] = q }
          cur = ""; has = 0; q = 0
        } else if (c == sq || c == "\"") {
          inq = c; has = 1; q = 1
        } else if (c == "\\" && i < L) {
          i++; cur = cur substr(s, i, 1); has = 1
        } else {
          cur = cur c; has = 1
        }
      }
      if (has) { n++; TOK[n] = cur; TQ[n] = q }
      return n
    }
    function glob_re(g,    r) {
      r = g
      gsub(/\./, "\\.", r)
      gsub(/\*/, "[^ ]*", r)
      return r
    }
    function is_assign(w) { return w ~ /^[A-Za-z_][A-Za-z0-9_]*=/ }
    function path_match(w, re) { return w ~ ("^" re "$") || w ~ ("/" re "$") }
    # classify(cmd) — 1 when the command is a test command; NORM gets the
    # normalised command either way. LEAD gets the assignments in front of it,
    # GATED is 1 for a gate call, and TOK[CS..CN] are the words of the command.
    function classify(cmd,    n, s, k, i, w, j, first) {
      n = tokenize(cmd)
      s = 1; LEAD = ""; GATED = 0; CS = 1; CN = n
      if (n >= 2 && TOK[1] ~ /gate\.sh$/ && TOK[2] == "exec") {
        s = 0; GATED = 1
        for (k = 3; k <= n; k++) if (TOK[k] == "--" && !TQ[k]) { s = k + 1; break }
        if (s == 0) { NORM = cmd; return 0 }
      }
      while (s <= n && is_assign(TOK[s])) { LEAD = LEAD TOK[s] " "; s++ }
      CS = s
      NORM = ""
      for (k = s; k <= n; k++) NORM = NORM (k > s ? " " : "") TOK[k]
      if (s > n) return 0
      first = TOK[s]
      if (first == "make" || first ~ /\/make$/) {
        for (i = s + 1; i <= n; i++) {
          w = TOK[i]
          if (w == "-C" || w == "-f") { i++; continue }
          if (w == "-j") { if (i < n && TOK[i + 1] ~ /^[0-9]+$/) i++; continue }
          if (w ~ /^-j[0-9]+$/ || is_assign(w)) continue
          for (j = 1; j <= nmake; j++) if (w ~ ("^" MAKE_RE[j] "$")) return 1
        }
        return 0
      }
      if (first == "bash") {
        if (s + 1 > n) return 0
        for (j = 1; j <= nbash; j++) if (path_match(TOK[s + 1], BASH_RE[j])) return 1
        return 0
      }
      for (j = 1; j <= nexe; j++) if (path_match(first, EXE_RE[j])) return 1
      return 0
    }
    BEGIN {
      m = split(ENVIRON["MTS_TEST_COMMANDS"], L, "\n")
      for (i = 1; i <= m; i++) {
        if (L[i] == "") continue
        sp = index(L[i], " ")
        if (sp > 0 && substr(L[i], 1, sp - 1) == "make") MAKE_RE[++nmake] = glob_re(substr(L[i], sp + 1))
        else if (sp > 0 && substr(L[i], 1, sp - 1) == "bash") BASH_RE[++nbash] = glob_re(substr(L[i], sp + 1))
        else EXE_RE[++nexe] = glob_re(L[i])
      }
    }
'

# measure_events — reads the event stream, prints
# stage_sec test_sec bg_launches same_set_relaunch unclosed test_launches commits
measure_events() {
  MTS_TEST_COMMANDS=$(printf '%s\n' "${TEST_COMMANDS[@]}") \
  awk -F '\t' -v sq="'" "$AWK_CLASSIFY"'
    $1 == "E" { ev[++nev] = $2 + 0; if ($2 + 0 > last) last = $2 + 0; next }
    $1 == "M" { mod = 1; next }
    $1 == "B" {
      cmd = $5
      for (k = 6; k <= NF; k++) cmd = cmd "\t" $k
      if (classify(cmd)) {
        nt++
        tid[nt] = $3; tstart[nt] = $2 + 0; tbg[nt] = $4 + 0; tend[nt] = -1
        idx[$3] = nt
        if ($4 + 0) bg++
        if (havePrev && NORM == prevNorm && !mod) same++
        prevNorm = NORM; havePrev = 1; mod = 0
      } else if (cmd ~ /(^|[^A-Za-z0-9_-])git +commit([^A-Za-z0-9_-]|$)/) {
        mod = 1
        commits++
      }
      next
    }
    $1 == "R" {
      if (!($3 in idx)) next
      k = idx[$3]
      if (!tbg[k]) { if (tend[k] < 0) tend[k] = $2 + 0 }
      else if ($4 != "-") task[$4] = k
      next
    }
    $1 == "N" {
      if (!($3 in task)) next
      k = task[$3]
      if (tend[k] < 0 || $2 + 0 < tend[k]) tend[k] = $2 + 0
      next
    }
    END {
      for (k = 1; k <= nt; k++) if (tend[k] < 0) { tend[k] = last; unclosed++ }
      # union of the test intervals: sort by start, then merge
      for (i = 1; i <= nt; i++) { S[i] = tstart[i]; F[i] = tend[i] }
      for (i = 2; i <= nt; i++) {
        a = S[i]; b = F[i]; j = i - 1
        while (j >= 1 && S[j] > a) { S[j + 1] = S[j]; F[j + 1] = F[j]; j-- }
        S[j + 1] = a; F[j + 1] = b
      }
      nu = 0
      for (i = 1; i <= nt; i++) {
        if (nu > 0 && S[i] <= UF[nu]) { if (F[i] > UF[nu]) UF[nu] = F[i] }
        else { nu++; US[nu] = S[i]; UF[nu] = F[i] }
      }
      test = 0
      for (i = 1; i <= nu; i++) if (UF[i] > US[i]) test += UF[i] - US[i]
      for (i = 2; i <= nev; i++) {
        a = ev[i]; j = i - 1
        while (j >= 1 && ev[j] > a) { ev[j + 1] = ev[j]; j-- }
        ev[j + 1] = a
      }
      stage = 0
      for (i = 2; i <= nev; i++) {
        g = ev[i] - ev[i - 1]
        if (g <= 900) { stage += g; continue }
        for (j = 1; j <= nu; j++) if (US[j] <= ev[i - 1] && UF[j] >= ev[i]) { stage += g; break }
      }
      printf "%d\t%d\t%d\t%d\t%d\t%d\t%d\n", stage, test, bg + 0, same + 0, unclosed + 0, nt + 0, commits + 0
    }
  '
}

minutes() { awk -v s="$1" 'BEGIN { printf "%.1f", s / 60 }'; }
percent() { awk -v a="$1" -v b="$2" 'BEGIN { if (b > 0) printf "%.1f%%", a * 100 / b; else printf "-" }'; }

# ---- the run-log report -----------------------------------------------------
# run_events_of <log> — one stream-json stage log as event lines, in file order:
# E <epoch> <iso>                       an assistant or user record
# B <epoch> <id> <bg> <command>         a Bash tool call
# M <epoch>                             an Edit/Write tool call
# R <epoch> <id> <bg> <code> <refused>  a tool result. bg is 1 when the text says
#                                       the command went to the background; code
#                                       is the exit code, `t` for a timeout or
#                                       `-`; refused is 1 for a hook refusal, 2
#                                       for an error with no line saying the gate
#                                       let the command through
# N <id> <status> <code> <output file>  a task notification (it has no time)
# O <id> <line>                         a `check-push: ` line of a tool result
run_events_of() {
  jq -R -r '
    def texts: if type == "string" then .
               elif type == "array" then map(if type == "object" then (.text // "" | tostring) else tostring end) | join("\n")
               else "" end;
    def flat: tostring | gsub("[\t\n\r]"; " ");
    fromjson? | select(type == "object")
    | if (.type == "assistant" or .type == "user") and (.timestamp | type) == "string" then
        (.timestamp | sub("\\.[0-9]+"; "")) as $iso
        | ($iso | try fromdateiso8601 catch null) as $t
        | select($t != null)
        | "E\t\($t)\t\($iso)",
          ( .message.content? | arrays | .[] | objects
            | if .type == "tool_use" and .name == "Bash" then
                "B\t\($t)\t\(.id)\t\(if .input.run_in_background == true then 1 else 0 end)\t\(.input.command // "" | flat)"
              elif .type == "tool_use" and (.name == "Edit" or .name == "Write" or .name == "MultiEdit" or .name == "NotebookEdit") then
                "M\t\($t)"
              elif .type == "tool_result" then
                .tool_use_id as $id | (.is_error == true) as $e | (.content | texts) as $x
                | "R\t\($t)\t\($id)\t\(if ($x[0:600] | test("background[^\n]*with ID: ")) then 1 else 0 end)\t\(
                    if ($e | not) then "0"
                    elif ($x | test("\\A(Exit code [0-9]+\n)?Command timed out")) then "t"
                    else ($x | capture("\\AExit code (?<c>[0-9]+)") | .c) // "-" end)\t\(
                    if ($e | not) then 0
                    elif ($x | startswith("PreToolUse:")) then 1
                    elif ($x | contains("게이트 통과") or contains("output omitted")) then 0
                    else 2 end)",
                  ( $x | split("\n")[] | select(startswith("check-push: ")) | "O\t\($id)\t\(flat)" )
              else empty end )
      elif .type == "system" and .subtype == "task_notification" then
        "N\t\(.tool_use_id // "-")\t\(.status // "-")\t\((.summary // "" | capture("exit code (?<c>[0-9]+)") | .c) // "-")\t\(.output_file // "" | if . == "" then "-" else flat end)"
      else empty end
  ' "$1" 2>/dev/null || true
}

# measure_run_events — reads those lines, prints nothing for a log with no timed
# record, else
# S <wall> <test> <wait> <unnotified> <start iso>
# T <tool> <rerun class> <sec>          one per test that ran
# P <check-push end> <sec>              one per check-push that ran
# C <n>                                 `CI 몫` lines of goals the first attempt
#                                       deferred, one goal once per check-push
measure_run_events() {
  MTS_TEST_COMMANDS=$(printf '%s\n' "${TEST_COMMANDS[@]}") \
  awk -F '\t' -v sq="'" "$AWK_CLASSIFY"'
    function is_test_target(w,    j) {
      for (j = 1; j <= nmake; j++) if (w ~ ("^" MAKE_RE[j] "$")) return 1
      return 0
    }
    # The tool of the command classify() just called a test.
    function tool_of(    i, w, b) {
      w = TOK[CS]
      if (w == "make" || w ~ /\/make$/) {
        for (i = CS + 1; i <= CN; i++) {
          w = TOK[i]
          if (w == "-C" || w == "-f") { i++; continue }
          if (is_assign(w) || !is_test_target(w)) continue
          if (w == "check-push" || w == "check-items" || w == "check-cheap") return w
          if (w ~ /^lint(-|$)/) return "lint"
          if (w == "check" || w == "test") return "test-gate"
          return "목표"
        }
        return "목표"
      }
      if (w == "bash") {
        b = TOK[CS + 1]; sub(/^.*\//, "", b)
        w = (CS + 2 <= CN) ? TOK[CS + 2] : "run"
        if (b == "check-push.sh") {
          if (w == "run") return "check-push"
          if (w == "items") return "check-items"
          return "스위트"
        }
        if (b == "test-gate.sh") return "test-gate"
        if (b ~ /^lint-/) return "lint"
        return "스위트"
      }
      if (w ~ /(^|\/)gate-shard$/) return "test-gate"
      return "스위트"
    }
    # 1 when a check-push names no section and no goal.
    function names_nothing(    s) {
      s = " " LEAD NORM
      return s !~ / CHECK_PUSH_(SECTIONS|GOALS)=[^ ]/
    }
    function note_line(k, line,    p, g) {
      if (index(line, "check-push: 판정 — 미완") == 1 || index(line, "check-push: items 미완") == 1) unfin[k] = 1
      if (index(line, "check-push: CI 몫 — ") != 1) return
      p = index(line, " (유도로만 들어왔고")
      if (p == 0) return
      g = substr(line, 1, p - 1)
      if (!((k, g) in seen)) { seen[k, g] = 1; nci[k]++ }
    }
    # The output file of a notification, when it is still there.
    function read_output(k,    line, f, got, let) {
      f = tfile[k]
      if (f == "" || f == "-") return
      while ((getline line < f) > 0) {
        got = 1
        if (index(line, "게이트 통과") > 0) let = 1
        note_line(k, line)
      }
      close(f)
      if (got && !let && tgate[k] && tstat[k] == "failed") skip[k] = 1
    }
    $1 == "E" {
      t = $2 + 0
      ev[++nev] = t
      if (nev == 1 || t < firstt) { firstt = t; firsti = $3 }
      if (nev == 1 || t > last) last = t
      for (i = 1; i <= npend; i++) tnote[pend[i]] = t
      npend = 0
      next
    }
    $1 == "M" { mods++; next }
    $1 == "B" {
      cmd = $5
      if (classify(cmd)) {
        nt++
        idx[$3] = nt
        tstart[nt] = $2 + 0; tbg[nt] = $4 + 0; tres[nt] = -1; tnote[nt] = -1
        ttool[nt] = tool_of(); tkey[nt] = LEAD NORM; tmod[nt] = mods + 0
        tgate[nt] = GATED; tfix[nt] = (ttool[nt] == "check-push" && names_nothing())
      } else if (NORM ~ /(^|[^A-Za-z0-9_-])git +commit([^A-Za-z0-9_-]|$)/) mods++
      next
    }
    $1 == "R" {
      if (!($3 in idx)) next
      k = idx[$3]
      tres[k] = $2 + 0
      if ($4 + 0) tbg[k] = 1
      if (!tbg[k]) tcode[k] = $5
      if ($6 == 1 || ($6 == 2 && tgate[k])) skip[k] = 1
      next
    }
    $1 == "N" {
      if (!($2 in idx)) next
      k = idx[$2]
      noted[k] = 1; tstat[k] = $3; tfile[k] = $5
      if ($4 != "-") tncode[k] = $4
      pend[++npend] = k
      next
    }
    $1 == "O" { if ($2 in idx) note_line(idx[$2], $3); next }
    END {
      if (nev == 0) exit
      for (i = 1; i <= npend; i++) tnote[pend[i]] = last
      nu = 0; m = 0
      for (k = 1; k <= nt; k++) {
        if (ttool[k] == "check-push" || tstat[k] == "failed") read_output(k)
        if (skip[k]) continue
        e = tres[k]
        if (tbg[k] && !noted[k]) { e = last; unnoted++ }
        else if (tnote[k] > e) e = tnote[k]
        if (e < 0) e = last
        if (e < tstart[k]) e = tstart[k]
        sec = e - tstart[k]
        key = tkey[k]; tool = ttool[k]
        if (tfix[k]) cls = "고정 검사"
        else if (key in keymod) cls = (keymod[key] == tmod[k]) ? "같은 입력" : "고친 뒤 전부 재실행"
        else if ((tool in toolmod) && toolmod[tool] != tmod[k]) cls = "고친 뒤 일부 재실행"
        else cls = "첫 실행"
        keymod[key] = tmod[k]; toolmod[tool] = tmod[k]
        printf "T\t%s\t%s\t%d\n", tool, cls, sec
        if (tool == "check-push") {
          code = (k in tncode) ? tncode[k] : tcode[k]
          if (tstat[k] == "stopped" || code == "t") end = "상한 잘림"
          else if (code == "0") end = "종료 0"
          else if (unfin[k]) end = "미완"
          else if (tbg[k] && !noted[k]) end = "알림 없음"
          else end = "실패"
          printf "P\t%s\t%d\n", end, sec
          ci += nci[k]
        }
        m++; S[m] = tstart[k]; F[m] = e
      }
      for (i = 2; i <= m; i++) {
        a = S[i]; b = F[i]; j = i - 1
        while (j >= 1 && S[j] > a) { S[j + 1] = S[j]; F[j + 1] = F[j]; j-- }
        S[j + 1] = a; F[j + 1] = b
      }
      for (i = 1; i <= m; i++) {
        if (nu > 0 && S[i] <= UF[nu]) { if (F[i] > UF[nu]) UF[nu] = F[i] }
        else { nu++; US[nu] = S[i]; UF[nu] = F[i] }
      }
      for (i = 1; i <= nu; i++) test += UF[i] - US[i]
      for (i = 2; i <= nev; i++) {
        a = ev[i]; j = i - 1
        while (j >= 1 && ev[j] > a) { ev[j + 1] = ev[j]; j-- }
        ev[j + 1] = a
      }
      # A gap of 30 seconds or more between two records is waiting as far as a
      # test was running in it.
      for (i = 2; i <= nev; i++) {
        if (ev[i] - ev[i - 1] < 30) continue
        for (j = 1; j <= nu; j++) {
          a = (US[j] > ev[i - 1]) ? US[j] : ev[i - 1]
          b = (UF[j] < ev[i]) ? UF[j] : ev[i]
          if (b > a) wait += b - a
        }
      }
      printf "S\t%d\t%d\t%d\t%d\t%s\n", last - firstt, test + 0, wait + 0, unnoted + 0, firsti
      printf "C\t%d\n", ci + 0
    }
  '
}

# ledger_index <ledger> — what the report needs from one run ledger:
# START <iso>                       the first run row
# ROW <stage>#<version> <kind> <1|0> the stage, and whether it is counted: a row
#                                   with a segment only when that segment is
#                                   this repository's
# CI <iso>                          a counted `CI 처분` row and when it was seen
ledger_index() {
  awk -v want_repo="$repo" '
    function field(row, key,    n, parts, i, kv) {
      n = split(row, parts, / \| /)
      for (i = 2; i <= n; i++) {
        kv = parts[i]
        if (index(kv, key "=") == 1) return substr(kv, length(key) + 2)
      }
      return ""
    }
    function mine(seg) { return seg == "-" || seg == "" || repo_of[seg] == want_repo }
    /^- `run` \| / { if (start == "") start = field($0, "시작"); next }
    /^- `segment` \| / {
      id = field($0, "id"); r = field($0, "레포")
      if (id != "" && r != "") repo_of[id] = r
      next
    }
    /^- `stage-result` \| / {
      n++
      key[n] = field($0, "스테이지") "#" field($0, "실행 버전")
      kind[n] = field($0, "종류"); seg[n] = field($0, "세그먼트")
      next
    }
    /^- `CI 처분` \| / { c++; cseg[c] = field($0, "세그먼트"); cat[c] = field($0, "관측"); next }
    END {
      if (start == "") exit
      printf "START\t%s\n", start
      for (i = 1; i <= n; i++) printf "ROW\t%s\t%s\t%d\n", key[i], kind[i], mine(seg[i])
      for (i = 1; i <= c; i++) if (mine(cseg[i])) printf "CI\t%s\n", cat[i]
    }
  ' "$1"
}

# When scripts/check-push-ci.tsv entered the first-parent history of
# origin/master, or of HEAD in a repository without that ref; empty when it did
# not.
boundary_time() {
  (
    cd "$repo_root" 2>/dev/null || exit 0
    ref=refs/remotes/origin/master
    git rev-parse -q --verify "$ref^{commit}" >/dev/null 2>&1 || ref=HEAD
    TZ=UTC git log --first-parent --date=format-local:%Y-%m-%dT%H:%M:%SZ --format=%cd "$ref" -- scripts/check-push-ci.tsv 2>/dev/null | tail -n 1
  ) || true
}

in_window() { # iso
  [[ -z "$since" || ! "$1" < "$since" ]] && [[ -z "$until_t" || ! "$1" > "$until_t" ]]
}

# report_runs — the whole report of a call without --ledger-dir and --lane-root.
report_runs() {
  local work boundary common main_dir ledgers d run_id have start log name key kind counted bucket stage_start seen_at stage_re
  stage_re='^[^/]+#[0-9]+$'
  repo_root=$(cd "$(dirname "$0")/.." && pwd)
  boundary=$(boundary_time)
  if [[ -z "$since" ]]; then
    since=$(jq -n -r --arg b "$boundary" '(if $b == "" then now | floor else $b | fromdateiso8601 end) - 604800 | todate')
  fi
  common=$( (cd "$repo_root" && git rev-parse --path-format=absolute --git-common-dir) 2>/dev/null || true)
  main_dir="$repo_root"
  if [[ -n "$common" ]]; then main_dir=$(dirname "$common"); fi
  ledgers="$main_dir/docs/pipeline-run"

  work=$(mktemp -d "${TMPDIR:-/tmp}/measure-test-share.XXXXXX")
  # shellcheck disable=SC2064
  trap "rm -rf '$work'" EXIT
  : > "$work/rows"

  if [[ -d "$run_root" ]]; then
    for d in "$run_root"/*/; do
      [[ -d "$d/log" ]] || continue
      run_id=$(basename "$d")
      : > "$work/idx"
      if [[ -f "$ledgers/$run_id.md" ]]; then ledger_index "$ledgers/$run_id.md" > "$work/idx"; fi
      start=$(awk -F '\t' '$1 == "START" { print $2; exit }' "$work/idx")
      have=""
      if [[ -n "$start" ]]; then
        in_window "$start" || continue
        have=1
        if [[ -z "$boundary" ]]; then bucket="전체"
        elif [[ "$start" < "$boundary" ]]; then bucket="이전"
        else bucket="이후"; fi
        while IFS="$(printf '\t')" read -r _tag seen_at; do
          if [[ "$bucket" == "이전" && -n "$seen_at" && ! "$seen_at" < "$boundary" ]]; then
            printf 'I\t걸침\n'
          else
            printf 'I\t%s\n' "$bucket"
          fi
        done < <(awk -F '\t' '$1 == "CI"' "$work/idx") >> "$work/rows"
      fi
      for log in "$d"log/*.json; do
        [[ -f "$log" ]] || continue
        name=$(basename "$log" .json)
        case "$name" in shift-*) continue ;; esac
        [[ "$name" =~ $stage_re ]] || continue
        kind=""
        counted=""
        if [[ -n "$have" ]]; then
          key=$(awk -F '\t' -v k="$name" '$1 == "ROW" && $2 == k { r = $3 "\t" $4 } END { print r }' "$work/idx")
          kind=${key%%"$(printf '\t')"*}
          counted=${key##*"$(printf '\t')"}
        fi
        if [[ -n "$kind" ]]; then
          [[ "$counted" == 1 ]] || continue
          case "$kind" in implement|reconverge|review|lead-fix) ;; *) continue ;; esac
        fi
        run_events_of "$log" | measure_run_events > "$work/one"
        [[ -s "$work/one" ]] || continue
        stage_start=$(awk -F '\t' '$1 == "S" { print $6 }' "$work/one")
        if [[ -z "$kind" ]]; then
          if [[ -z "$have" ]]; then in_window "$stage_start" || continue; fi
          awk -F '\t' '$1 == "S" { print "K\t-\t없음\t" $2 "\t" $3 "\t" $4 "\t" $5 }' "$work/one" >> "$work/rows"
          continue
        fi
        if [[ "$bucket" == "이전" && ! "$stage_start" < "$boundary" ]]; then
          printf 'G\n' >> "$work/rows"
          continue
        fi
        awk -F '\t' -v b="$bucket" -v kind="$kind" '
          $1 == "S" { print "K\t" b "\t" kind "\t" $2 "\t" $3 "\t" $4 "\t" $5 }
          $1 == "T" { print "T\t" b "\t" $2 "\t" $3 "\t" $4 }
          $1 == "P" { print "P\t" b "\t" $2 "\t" $3 }
          $1 == "C" { print "C\t" b "\t" $2 }
        ' "$work/one" >> "$work/rows"
      done
    done
  fi

  printf '창: %s ~ %s · 경계: %s\n' "$since" "${until_t:-지금}" "${boundary:-없음}"
  awk -F '\t' -v split_at="$boundary" -v ledger_dir="$([[ -d "$ledgers" ]] && echo 1 || echo 0)" '
    function mins(s) { return sprintf("%.1f", s / 60) }
    function pct(a, b) { return (b > 0) ? sprintf("%.1f%%", a * 100 / b) : "-" }
    function per(s, n) { return (n > 0) ? sprintf("%.1f", s / 60 / n) : "-" }
    $1 == "K" { k = $2 SUBSEP $3; n[k]++; wall[k] += $4; test[k] += $5; wt[k] += $6; un[k] += $7; if ($2 != "-") { st[$2]++; bw[$2] += $6 } next }
    $1 == "T" { k = $2 SUBSEP $3 SUBSEP $4; tn[k]++; ts[k] += $5; tool[$2 SUBSEP $3] += $5; next }
    $1 == "P" { k = $2 SUBSEP $3; pn[k]++; ps[k] += $4; next }
    $1 == "C" { ci[$2] += $3; next }
    $1 == "G" { cross++; next }
    $1 == "I" { iv[$2]++; next }
    END {
      nb = split(split_at == "" ? "전체" : "이전|이후", B, "|")
      nk = split("implement|reconverge|review|lead-fix", K, "|")
      nl = split("check-push|check-items|check-cheap|lint|test-gate|스위트|목표", L, "|")
      nc = split("첫 실행|같은 입력|고친 뒤 일부 재실행|고친 뒤 전부 재실행|고정 검사", C, "|")
      ne = split("종료 0|실패|미완|상한 잘림|알림 없음", E, "|")
      print "\n## 스테이지 종류"
      print "묶음\t종류\t수\t벽시계(분)\t시험(분)\t시험 몫\t대기(분)\t알림 없는 배경 시험"
      for (i = 1; i <= nb; i++) for (j = 1; j <= nk; j++) {
        k = B[i] SUBSEP K[j]
        if (k in n) printf "%s\t%s\t%d\t%s\t%s\t%s\t%s\t%d\n", B[i], K[j], n[k], mins(wall[k]), mins(test[k]), pct(test[k], wall[k]), mins(wt[k]), un[k]
      }
      k = "-" SUBSEP "없음"
      if (k in n) printf "-\t없음\t%d\t%s\t%s\t%s\t%s\t%d\n", n[k], mins(wall[k]), mins(test[k]), pct(test[k], wall[k]), mins(wt[k]), un[k]
      if (split_at != "") printf "걸침\t스테이지 %d개 (어느 묶음에도 넣지 않음)\n", cross + 0
      print "\n## 도구와 되풀이 갈래"
      print "묶음\t도구\t갈래\t횟수\t분"
      for (i = 1; i <= nb; i++) for (j = 1; j <= nl; j++) for (c = 1; c <= nc; c++) {
        k = B[i] SUBSEP L[j] SUBSEP C[c]
        if (k in tn) printf "%s\t%s\t%s\t%d\t%s\n", B[i], L[j], C[c], tn[k], mins(ts[k])
      }
      print "\n## check-push 의 끝"
      print "묶음\t끝\t횟수\t분"
      for (i = 1; i <= nb; i++) for (j = 1; j <= ne; j++) {
        k = B[i] SUBSEP E[j]
        if (k in pn) printf "%s\t%s\t%d\t%s\n", B[i], E[j], pn[k], mins(ps[k])
      }
      print "\n## 원인 (스테이지당 분)"
      print "묶음\t스테이지\t가 CI 몫 줄\t가 check-push\t나 check-push 같은 입력\t다 check-push 고친 뒤 전부 재실행\t라 lint 같은 입력\t마 워크트리 test-gate·스위트\t바 대기"
      for (i = 1; i <= nb; i++) {
        b = B[i]; s = st[b] + 0
        printf "%s\t%d\t%d\t%s\t%s\t%s\t%s\t%s\t%s\n", b, s, ci[b] + 0, per(tool[b SUBSEP "check-push"], s), \
          per(ts[b SUBSEP "check-push" SUBSEP "같은 입력"], s), per(ts[b SUBSEP "check-push" SUBSEP "고친 뒤 전부 재실행"], s), \
          per(ts[b SUBSEP "lint" SUBSEP "같은 입력"], s), per(tool[b SUBSEP "test-gate"] + tool[b SUBSEP "스위트"], s), per(bw[b], s)
      }
      print "\n## 원장의 CI 처분 행"
      print "묶음\t행"
      for (i = 1; i <= nb; i++) printf "%s\t%s\n", B[i], ledger_dir ? iv[B[i]] + 0 : "없음"
      if (split_at != "" && ledger_dir) printf "걸침\t%d\n", iv["걸침"] + 0
      if (st["이후"] + 0 == 0) print "\n이후 표본 없음"
    }
  ' "$work/rows"
}

if [[ "$mode" == runs ]]; then
  report_runs
  exit 0
fi

printf 'run\tsegment\tsession\tstage_min\ttest_min\tshare\tbg_launches\tsame_set_relaunch\tunclosed\n'

sum_stage=0
sum_test=0
counted=0
seen=" "
while IFS="$(printf '\t')" read -r start run_id _order seg sid lane; do
  [[ -n "$sid" ]] || continue
  [[ -z "$since" || ! "$start" < "$since" ]] || continue
  [[ -z "$until_t" || ! "$start" > "$until_t" ]] || continue
  [[ -z "$only_session" || "$sid" == "$only_session" ]] || continue
  case "$seen" in *" $sid "*) continue ;; esac
  seen="$seen$sid "
  if [[ -n "$first" ]] && (( counted >= first )); then break; fi

  lane_dir="$lane"
  case "$lane_dir" in "~"*) lane_dir="$lane_root${lane_dir#\~}" ;; esac
  transcript=""
  for t in "$lane_dir"/projects/*/"$sid".jsonl; do
    if [[ -f "$t" ]]; then transcript="$t"; break; fi
  done
  if [[ -z "$transcript" ]]; then
    printf '%s\t%s\t%s\t기록 없음\t-\t-\t-\t-\t-\n' "$run_id" "$seg" "$sid"
    continue
  fi

  IFS="$(printf '\t')" read -r stage_s test_s bg same unclosed launches commits <<EOF
$(events_of "$transcript" | measure_events)
EOF
  if (( launches == 0 && commits == 0 )); then
    printf '%s\t%s\t%s\t%s\t%s\t제외\t%s\t%s\t%s\n' "$run_id" "$seg" "$sid" \
      "$(minutes "$stage_s")" "$(minutes "$test_s")" "$bg" "$same" "$unclosed"
    continue
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$run_id" "$seg" "$sid" \
    "$(minutes "$stage_s")" "$(minutes "$test_s")" "$(percent "$test_s" "$stage_s")" \
    "$bg" "$same" "$unclosed"
  sum_stage=$((sum_stage + stage_s))
  sum_test=$((sum_test + test_s))
  counted=$((counted + 1))
done <<EOF
$all_sessions
EOF

printf '시험 몫 = %s분/%s분 = %s\n' "$(minutes "$sum_test")" "$(minutes "$sum_stage")" "$(percent "$sum_test" "$sum_stage")"
if (( counted == 0 )) || { [[ -n "$first" ]] && (( counted < first )); }; then
  verdict="표본 부족"
elif awk -v a="$sum_test" -v b="$sum_stage" 'BEGIN { exit !(b > 0 && a * 100 < b * 30) }'; then
  verdict="달성"
else
  verdict="미달"
fi
printf '판정: %s\n' "$verdict"
