#!/usr/bin/env bash
#
# ci-signature.sh — turns the log of one failed CI job into a sorted list of
# failure SIGNATURES, so two failures can be compared by what failed rather than
# by the name of the check that carried them. The gate's `ci-match` act feeds it
# a segment's failed jobs and compares the result with the signatures the master
# reading recorded; the fleet's master step feeds it the base branch's failed
# jobs.
#
# A SIGNATURE IS `<check base name>|[<suite>|]<failure name>`. The check base name
# is the check name with its shard tail ` (<n>)` removed, so `gate-shards (3)` and
# `gate-shards (11)` name the same thing: which shard a section lands on moves
# with the partition, and the failure does not. The suite piece is there when the
# log names the suite the failure printed under — `rest-tests` runs many scripts
# in one job, and two of them may use the same assertion name.
#
# THE ADAPTER IS CHOSEN BY THE REMOTE SLUG, AND THE TABLE LIVES HERE. Only this
# repository's change carries code, so a repository that wants assertion-level
# comparison gets an entry in `cs_adapter` below and nothing in its own tree.
#
#   cc-cmds — reads `FAIL: <name> — <detail>` lines, the shape every test script
#             here prints through its `bad` helper (`printf 'FAIL: %s — %s\n'`).
#             Precision `단언`.
#   일반    — reads nothing from the log. It emits one signature per failed step
#             name the caller passes with `--step`, and precision `단계`.
#
# WHERE THE NAME ENDS. The helper prints the name, ` — `, then the detail, and
# both may carry ` — ` of their own: a name such as `83c: X — 칸 Y 에서 park 한다`,
# a detail that quotes a gate refusal. The suites here open a detail in one of
# two fixed ways — `got '<value>', want '<value>'` from the `check` helpers and
# `rc=<code> <output>` from the direct `bad` calls — and no name carries either
# opening. So the line is cut, in this order:
#
#   1. at its first ` — rc=`;
#   2. at its first ` — got '`;
#   3. at its LAST ` — `.
#
# The first two drop a detail whole however many ` — ` it quotes, and keep a
# name's inner ` — ` on the name. The third is for a detail in free text: two
# names that differ only after an inner ` — ` stay two signatures, and a detail
# that itself carries ` — ` leaves its head on the name. The normalisation below
# keeps that head stable across reruns where it is a path, a line number, a
# digest or a time, and where it is not, the cost is a signature that does not
# match, which reads as `초과` and never as a false subset.
#
# WHAT IS NORMALISED IN THE NAME. A `<file>:<line>` line number, a temporary path,
# a 40- or 64-digit hex digest and an ISO time are replaced by fixed placeholders:
# they change between two runs of the same failure, and a signature that changes
# with them would make every rerun a new failure.
#
# A LOG THAT DOES NOT FINISH IS NOT READ AT ASSERTION PRECISION, AND COMPLETENESS
# IS JUDGED PER SUITE. The failures a suite printed are all of its failures only
# when the suite ran to its end, and one job may run many suites at once —
# `rest-tests` runs its shard under `make -j`, and one suite's total says
# nothing about another's. The shard's sub-make holds each goal's output and
# writes it whole (`REST_OUTPUT_SYNC` in the Makefile), so a suite's lines sit
# between its own start and end lines; a make without output sync interleaves
# them, and the rules below then read the job at step precision. When the log
# carries suite-guard lines, every suite is followed from its start line (the
# `bash scripts/suite-guard.sh <args>` make echoes) to its end line
# (`suite-guard[<args>]: 종료 rc=<rc> …`), and the check stays at assertion
# precision only when all of these hold:
#
#   - every suite that started ended, and no `::error::suite-guard:` line
#     (`##[error]suite-guard:` once Actions has rewritten the workflow command
#     in the stored log) says the wrapper reaped or refused one;
#   - every `FAIL:` line and every total line falls while exactly one suite is
#     open, so the line is that suite's — two open suites make the line
#     unattributable, and a `FAIL:` line outside every suite is the same;
#   - every suite that ended with a non-zero rc printed at least one `FAIL:`
#     line and its total line — a suite that died with no `FAIL:` line, or
#     after some of them, is otherwise hidden by its neighbours;
#   - no make error line (`make[<n>]: *** [<target>] …`) names a target other
#     than a `run/<suite>` goal, unless a deeper make's error line came before
#     it — that is the recursive make passing a failure up. The same shard runs
#     goals no suite-guard wraps (the `--self-test` goals), and their failure is
#     seen nowhere else;
#   - when the log names the shard's goals (`rest shard <n>/<m>: <goal>…`) and
#     a make error line shows make stopped, every listed goal started: a
#     `run/<suite>` goal by its suite-guard start line, a `run-<x>-selftest`
#     goal by the `bash scripts/<x>.sh --self-test` line make echoes. The
#     sub-make runs with `-k` and starts every goal after a failure; a goal
#     that never started still leaves no line at all, and that is what a make
#     stopped by a signal, or one run without `-k`, leaves behind.
#
# A `<name> self-test: <n> passed, …` total comes from such an unwrapped goal,
# so it is never taken as the total of the one wrapped suite open beside it.
#
# A log with no suite-guard line is one suite: it needs one total line. A total
# line is a line that is a total and nothing else, `[<name>: ]<n> passed, <m>
# failed[, …]`, never a `FAIL:` line whose detail quotes one. `--truncated`,
# which the gate passes when it cut the log at its byte cap, fails the check
# outright: a cut between two suites leaves nothing in the kept part that says
# one is missing.
#
# Any other log falls to step precision, the same as a check that printed no
# `FAIL:` line at all (a lint, a build step). A lint that prints `FAIL:` lines
# without a total — `lint-pace-threshold-pins.sh` does — lands here too, which
# is what keeps its file-only names from merging distinct failures at assertion
# precision.
#
# Usage:
#   ci-signature.sh extract --repo <owner/name> --check <check name>
#                           [--step <failed step name>]... [--truncated]  < job log
#   ci-signature.sh fingerprint                               < signature list
#
# `extract` prints `정밀도: 단언` or `정밀도: 단계` first, then the signatures
# sorted and de-duplicated, one per line. No signature at all prints the precision
# line alone and exits 0 — whether that is `판정 불가` is the caller's call.
# `fingerprint` prints the sha256 of the sorted, de-duplicated signature lines of
# its input, ignoring a precision line.
#
# Exit codes:
#   0 — printed
#   2 — bad arguments
#
# Compatibility: bash 3.2 (macOS) — no associative arrays, no `mapfile`. The
# interval expressions are in `sed -E` rather than awk, because Ubuntu's mawk
# does not read `{n}`.

set -uo pipefail

cs_die() { printf 'ci-signature: %s\n' "$*" >&2; exit 2; }

cs_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{ print $1 }'
  else
    shasum -a 256 | awk '{ print $1 }'
  fi
}

# The adapter for a slug. GitHub reads slugs without regard to case, and so does
# this table.
cs_adapter() {
  local s
  s=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  case "$s" in
    nharu/cc-cmds) printf 'cc-cmds' ;;
    *)             printf '일반' ;;
  esac
}

# The check name without its shard tail.
cs_check_base() { printf '%s' "$1" | sed -E 's/ \([0-9]+\)$//'; }

# Placeholders for the parts of a name that change between two runs of one
# failure. Run under the C locale: the input is bytes from a remote log, and a
# byte sequence that is not valid UTF-8 must not stop the substitution.
cs_normalise() {
  LC_ALL=C sed -E \
    -e 's/[0-9]{4}-[0-9]{2}-[0-9]{2}[T ][0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?Z?/<시각>/g' \
    -e 's/[0-9a-f]{64}/<sha256>/g' \
    -e 's/[0-9a-f]{40}/<sha>/g' \
    -e 's#(/private)?/var/folders/[^ :]*#<임시>#g' \
    -e 's#/home/runner/work/_temp/[^ :]*#<임시>#g' \
    -e 's#/tmp/[^ :]*#<임시>#g' \
    -e 's/tmp\.[A-Za-z0-9]{6,}/tmp.<임시>/g' \
    -e 's/([A-Za-z0-9_.-]+\.[A-Za-z0-9]+):[0-9]+/\1:<줄>/g' \
    -e 's/[[:space:]]+$//'
}

# Reads a job log on stdin. Prints `T` when the log is complete by the rules in
# the header, `F` otherwise, on the first line, then one `[<suite>|]<name>` per
# FAIL line.
cs_read_fail_lines() {
  LC_ALL=C awk '
    function lastsep(s, sep,    p, i, off) {
      p = 0; off = 0
      while ((i = index(substr(s, off + 1), sep)) > 0) { p = off + i; off = p }
      return p
    }
    function base(k,    n, parts, first) {
      first = k; sub(/ .*$/, "", first)
      n = split(first, parts, "/")
      return parts[n]
    }
    # The one open suite, or "" when none or more than one is open.
    function sole(    i, k) {
      if (nopen != 1) return ""
      for (i = 1; i <= nk; i++) { k = keys[i]; if (open[k] > 0) return k }
      return ""
    }
    BEGIN {
      SG = "bash scripts/suite-guard.sh "
      END_MARK = "]: \354\242\205\353\243\214 rc="
    }
    {
      sub(/\r$/, "")
      if (NR == 1) sub(/^\357\273\277/, "")
      gsub(/\033\[[0-9;]*[A-Za-z]/, "")
      sub(/^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9:.]+Z /, "")
      line = $0
      if (substr(line, 1, length(SG)) == SG) {
        k = substr(line, length(SG) + 1); sub(/[ \t]+$/, "", k)
        if (!(k in open)) { nk++; keys[nk] = k; open[k] = 0 }
        open[k]++; nopen++; guarded = 1
        next
      }
      if (substr(line, 1, 12) == "suite-guard[" && (p = index(line, END_MARK)) > 0) {
        k = substr(line, 13, p - 13)
        rc = substr(line, p + length(END_MARK)); sub(/[^0-9].*$/, "", rc)
        if ((k in open) && open[k] > 0) {
          open[k]--; nopen--
          if (rc != "0") failed_rc[k] = 1
        } else {
          broken = 1
        }
        next
      }
      if (substr(line, 1, 21) == "::error::suite-guard:" || substr(line, 1, 21) == "##[error]suite-guard:") { broken = 1; next }
      if (line ~ /^rest shard [0-9]+\/[0-9]+: /) {
        n = split(substr(line, index(line, ": ") + 2), words, " ")
        for (i = 1; i <= n; i++) {
          if (substr(words[i], 1, 4) == "run/") { listed[substr(words[i], 5)] = 1; nlisted++ }
          else if (words[i] ~ /^run-[A-Za-z0-9_.-]+-selftest$/) { listed_self[words[i]] = 1; nlisted++ }
        }
        next
      }
      if (line ~ /^bash scripts\/[A-Za-z0-9_.-]+\.sh --self-test$/) {
        g = line; sub(/^bash scripts\//, "", g); sub(/\.sh --self-test$/, "", g)
        self_started["run-" g "-selftest"] = 1
        next
      }
      if (line ~ /^g?make(\[[0-9]+\])?: \*\*\* \[/) {
        mkerr = 1
        lvl = 0
        if (match(line, /^g?make\[[0-9]+\]/)) { lvl = substr(line, 1, RLENGTH); sub(/^g?make\[/, "", lvl); sub(/\]$/, "", lvl); lvl += 0 }
        t = substr(line, index(line, "*** [") + 5); sub(/\][^]]*$/, "", t)
        p = lastsep(t, ": "); if (p > 0) t = substr(t, p + 2)
        if (substr(t, 1, 4) != "run/" && !(mkdeep > lvl)) unguarded_failed = 1
        if (lvl > mkdeep) mkdeep = lvl
        next
      }
      if (line ~ /^run\//) {
        rest = line; sub(/^run\//, "", rest)
        suite = base(rest)
        next
      }
      if (substr(line, 1, 6) == "FAIL: ") {
        body = substr(line, 7)
        p = index(body, " \342\200\224 rc=")
        if (p == 0) p = index(body, " \342\200\224 got \047")
        if (p == 0) p = lastsep(body, " \342\200\224 ")
        name = (p > 0) ? substr(body, 1, p - 1) : body
        sub(/[ \t]+$/, "", name)
        if (name == "") next
        nf++
        if (guarded) {
          k = sole()
          if (k == "") { unattributed = 1; out[nf] = name; next }
          fails[k]++
          out[nf] = base(k) "|" name
        } else {
          prefail = 1
          out[nf] = (suite != "") ? suite "|" name : name
        }
        next
      }
      if (line ~ /^([A-Za-z0-9_.-]+( self-test)?: )?[0-9]+ passed, [0-9]+ failed([,( ].*)?$/) {
        total = 1
        if (guarded && line !~ /^[A-Za-z0-9_.-]+ self-test: /) { k = sole(); if (k != "") totals[k] = 1 }
      }
    }
    END {
      ok = total
      if (guarded) {
        ok = !broken && !unattributed && !prefail && !unguarded_failed && nopen == 0
        for (i = 1; ok && i <= nk; i++) {
          k = keys[i]
          if ((k in failed_rc) && (!fails[k] || !(k in totals))) ok = 0
        }
      }
      if (ok && nlisted && mkerr) {
        for (k in listed) if (!(k in open)) ok = 0
        for (k in listed_self) if (!(k in self_started)) ok = 0
      }
      print (ok ? "T" : "F")
      for (i = 1; i <= nf; i++) print out[i]
    }
  '
}

cs_extract() {
  local repo="" check="" adapter base raw total sigs="" steps=() s truncated=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo)  [ $# -ge 2 ] || cs_die '--repo 에 값이 없습니다'; repo="$2"; shift 2 ;;
      --check) [ $# -ge 2 ] || cs_die '--check 에 값이 없습니다'; check="$2"; shift 2 ;;
      --step)  [ $# -ge 2 ] || cs_die '--step 에 값이 없습니다'; steps+=("$2"); shift 2 ;;
      --truncated) truncated=1; shift ;;
      *) cs_die "알 수 없는 인자: $1" ;;
    esac
  done
  [ -n "$repo" ]  || cs_die '--repo 는 필수입니다'
  [ -n "$check" ] || cs_die '--check 는 필수입니다'
  adapter=$(cs_adapter "$repo")
  base=$(cs_check_base "$check")

  if [ "$adapter" = "cc-cmds" ]; then
    raw=$(cs_read_fail_lines)
    total=$(printf '%s\n' "$raw" | head -n 1)
    sigs=$(printf '%s\n' "$raw" | tail -n +2 | grep -v '^$' || true)
    if [ -n "$sigs" ] && [ "$total" = "T" ] && [ -z "$truncated" ]; then
      printf '정밀도: 단언\n'
      printf '%s\n' "$sigs" | while IFS= read -r s; do printf '%s|%s\n' "$base" "$s"; done \
        | cs_normalise | grep -v '^$' | LC_ALL=C sort -u
      return 0
    fi
  else
    # The generic adapter reads nothing from the log; drain it so a writer on
    # the other end of the pipe does not die of SIGPIPE.
    cat > /dev/null
  fi

  printf '정밀도: 단계\n'
  [ "${#steps[@]}" -gt 0 ] || return 0
  for s in "${steps[@]}"; do printf '%s|%s\n' "$base" "$s"; done \
    | cs_normalise | grep -v '^$' | LC_ALL=C sort -u
  return 0
}

cs_fingerprint() {
  [ $# -eq 0 ] || cs_die "fingerprint 는 인자를 받지 않습니다: $*"
  { grep -v -e '^정밀도: ' -e '^$' || true; } | LC_ALL=C sort -u | cs_sha256
}

[ $# -ge 1 ] || cs_die '사용법: ci-signature.sh extract --repo <slug> --check <이름> [--step <단계>]... [--truncated] | fingerprint'
cmd="$1"; shift
case "$cmd" in
  extract)     cs_extract "$@" ;;
  fingerprint) cs_fingerprint "$@" ;;
  *) cs_die "알 수 없는 하위 명령: $cmd" ;;
esac
