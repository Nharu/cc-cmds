#!/usr/bin/env bash
# Measure how much of each cc-cmds implement stage went to running tests, one
# TSV row per session, from the run ledgers and the stage sessions' transcripts.
#
# This is NOT a gate. Nothing here blocks a run; the output is the evidence a
# person reads to decide whether the rerun discipline worked. `make test` runs
# it against synthetic fixtures only, never against real session history.
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
#
# The lane root is REQUIRED and has NO default pointing at a real home
# directory: with a default, a fixture test that forgot the argument would read
# real session history and pass or fail depending on the machine.
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
# `판정: 달성|미달|표본 부족`. Below 30% is 달성. Fewer sessions with a
# transcript than `--first n` asked for is 표본 부족.
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
#   scripts/measure-test-share.sh --ledger-dir <dir> --lane-root <dir>
#     [--repo <owner/name>] [--since <date|time>] [--until <date|time>]
#     [--first <n>] [--session <uuid>]
#   A bare date reads as 00:00:00Z for --since and 23:59:59Z for --until.
#
# Exit codes:
#   0 — rows emitted (possibly zero; the header and the two lines always print)
#   2 — usage error / unreadable input

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

ledger_dir=""
lane_root=""
repo="Nharu/cc-cmds"
since=""
until_t=""
first=""
only_session=""

usage_die() { echo "measure-test-share: $1" >&2; exit 2; }

while (( $# > 0 )); do
  case "$1" in
    --ledger-dir) ledger_dir="${2:-}"; shift 2 ;;
    --lane-root)  lane_root="${2:-}"; shift 2 ;;
    --repo)       repo="${2:-}"; shift 2 ;;
    --since)      since="${2:-}"; shift 2 ;;
    --until)      until_t="${2:-}"; shift 2 ;;
    --first)      first="${2:-}"; shift 2 ;;
    --session)    only_session="${2:-}"; shift 2 ;;
    -h|--help)
      grep -E '^# ' "$0" | cut -c3-
      exit 0
      ;;
    *) usage_die "unknown argument: $1" ;;
  esac
done

[[ -n "$ledger_dir" ]] || usage_die "--ledger-dir <dir> is required"
[[ -d "$ledger_dir" ]] || usage_die "ledger directory not found: $ledger_dir"
[[ -n "$lane_root" ]] || usage_die "--lane-root <dir> is required — there is deliberately no default"
[[ -d "$lane_root" ]] || usage_die "lane root not found: $lane_root"
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

# measure_events — reads the event stream, prints
# stage_sec test_sec bg_launches same_set_relaunch unclosed
measure_events() {
  # The list goes through the environment: BSD awk refuses a newline inside a
  # `-v` value.
  MTS_TEST_COMMANDS=$(printf '%s\n' "${TEST_COMMANDS[@]}") \
  awk -F '\t' -v sq="'" '
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
    # normalised command either way.
    function classify(cmd,    n, s, k, i, w, j, first) {
      n = tokenize(cmd)
      s = 1
      if (n >= 2 && TOK[1] ~ /gate\.sh$/ && TOK[2] == "exec") {
        s = 0
        for (k = 3; k <= n; k++) if (TOK[k] == "--" && !TQ[k]) { s = k + 1; break }
        if (s == 0) { NORM = cmd; return 0 }
      }
      while (s <= n && is_assign(TOK[s])) s++
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
      printf "%d\t%d\t%d\t%d\t%d\n", stage, test, bg + 0, same + 0, unclosed + 0
    }
  '
}

minutes() { awk -v s="$1" 'BEGIN { printf "%.1f", s / 60 }'; }
percent() { awk -v a="$1" -v b="$2" 'BEGIN { if (b > 0) printf "%.1f%%", a * 100 / b; else printf "-" }'; }

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

  IFS="$(printf '\t')" read -r stage_s test_s bg same unclosed <<EOF
$(events_of "$transcript" | measure_events)
EOF
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
