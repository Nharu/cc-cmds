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
# WHERE THE NAME ENDS. The helper prints the name, ` — `, then the detail, and a
# name may itself carry ` — `. So the line is cut at its LAST ` — `: two names
# that differ only after an inner ` — ` stay two signatures, and the detail —
# got/want values that change between reruns — is dropped. A detail that itself
# carries ` — ` leaves its head on the name; the normalisation below keeps that
# head stable across reruns where it is a path, a line number, a digest or a
# time, and where it is not, the cost is a signature that does not match, which
# reads as `초과` and never as a false subset.
#
# WHAT IS NORMALISED IN THE NAME. A `<file>:<line>` line number, a temporary path,
# a 40- or 64-digit hex digest and an ISO time are replaced by fixed placeholders:
# they change between two runs of the same failure, and a signature that changes
# with them would make every rerun a new failure.
#
# A LOG THAT DOES NOT FINISH IS NOT READ AT ASSERTION PRECISION. When the cc-cmds
# adapter finds `FAIL:` lines but no suite total line (`<n> passed, <m> failed`),
# the suite died part way or the log was cut, and the failures it printed are
# not all of them. The check then falls to step precision, the same as a check
# that printed no `FAIL:` line at all (a lint, a build step). A lint that prints
# `FAIL:` lines without a total — `lint-pace-threshold-pins.sh` does — lands here
# too, which is what keeps its file-only names from merging distinct failures at
# assertion precision.
#
# Usage:
#   ci-signature.sh extract --repo <owner/name> --check <check name>
#                           [--step <failed step name>]...   < job log
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

# Reads a job log on stdin. Prints `T` when the log carries a suite total line,
# `F` otherwise, on the first line, then one `[<suite>|]<name>` per FAIL line.
cs_read_fail_lines() {
  LC_ALL=C awk '
    function lastsep(s, sep,    p, i, off) {
      p = 0; off = 0
      while ((i = index(substr(s, off + 1), sep)) > 0) { p = off + i; off = p }
      return p
    }
    {
      sub(/\r$/, "")
      if (NR == 1) sub(/^\357\273\277/, "")
      gsub(/\033\[[0-9;]*[A-Za-z]/, "")
      sub(/^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9:.]+Z /, "")
      line = $0
      if (line ~ /^bash scripts\/suite-guard\.sh / || line ~ /^run\//) {
        rest = line
        sub(/^bash scripts\/suite-guard\.sh /, "", rest)
        sub(/^run\//, "", rest)
        sub(/ .*$/, "", rest)
        n = split(rest, parts, "/")
        suite = parts[n]
        next
      }
      if (line ~ /[0-9]+ passed, [0-9]+ failed/) total = 1
      if (substr(line, 1, 6) == "FAIL: ") {
        body = substr(line, 7)
        p = lastsep(body, " \342\200\224 ")
        name = (p > 0) ? substr(body, 1, p - 1) : body
        sub(/[ \t]+$/, "", name)
        if (name == "") next
        nf++
        out[nf] = (suite != "") ? suite "|" name : name
      }
    }
    END {
      print (total ? "T" : "F")
      for (i = 1; i <= nf; i++) print out[i]
    }
  '
}

cs_extract() {
  local repo="" check="" adapter base raw total sigs="" steps=() s
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo)  [ $# -ge 2 ] || cs_die '--repo 에 값이 없습니다'; repo="$2"; shift 2 ;;
      --check) [ $# -ge 2 ] || cs_die '--check 에 값이 없습니다'; check="$2"; shift 2 ;;
      --step)  [ $# -ge 2 ] || cs_die '--step 에 값이 없습니다'; steps+=("$2"); shift 2 ;;
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
    if [ -n "$sigs" ] && [ "$total" = "T" ]; then
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

[ $# -ge 1 ] || cs_die '사용법: ci-signature.sh extract --repo <slug> --check <이름> [--step <단계>]... | fingerprint'
cmd="$1"; shift
case "$cmd" in
  extract)     cs_extract "$@" ;;
  fingerprint) cs_fingerprint "$@" ;;
  *) cs_die "알 수 없는 하위 명령: $cmd" ;;
esac
