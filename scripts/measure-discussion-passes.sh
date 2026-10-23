#!/usr/bin/env bash
# Retroactive measurement of the design team's late passes — one TSV row per
# witness corpus, with the same values the gate's `토론 패스` row carries.
#
# This is NOT a gate. Nothing here passes or fails; the output is the input to
# a human reading of how often round 3 opens, why, and what the fidelity and
# coherence passes find. `make test` runs this script against synthetic
# fixtures only (scripts/test-measure-discussion-passes.sh), never against the
# real corpora under the state home.
#
# CORPORA. Two roots are read and the row says which one it came from:
#   run   — <run root>/*/design/*/witness   (unattended runs)
#   seat  — <seat root>/*/witness           (interactive design seats)
# A subdirectory of a `witness/` directory (another team's corpus for the same
# document, `witness/redesign-<date>/`) is a corpus of its own. A corpus with
# no `*.round-1.md` gets no row, as the gate writes none for the solo branch.
#
# READING RULES — the gate's `gate_record_discussion_passes` reads the same way:
#   * Key grammar `{role-slug}.<round/phase>[-rev<k>].md`; per (member,
#     round/phase) the largest k wins, the original only when no revision
#     exists, and the two are never counted together. A file outside the
#     grammar (`*.coherence.epoch-6.md`, `*.coherence.prompt.md`) is not a
#     witness; the `문법 밖` column counts them. `SWEEP.md` and `INDEX.md` are
#     outside the grammar but are not counted there.
#   * An R2 witness's declaration is its last line that is exactly
#     `round-3: none` or starts `round-3: measure — `, chosen across both forms.
#   * `R3 사유` is the first of: closed with a measurement named `지명 미개방`,
#     any other closed `해당 없음`, open with a measurement named `측정 지명`,
#     an R2 witness without a declaration `미상`, the rest `선언 없음`.
#   * `스윕 반박` counts `SWEEP.md` lines starting `round-3: sweep — `; no file
#     is `미상`.
#   * A pass's findings are the sum of each seat's last exact `findings: <n>`
#     line. A seat without that line falls back to the older reading — its
#     `- type:` lines, and for fidelity `Fidelity confirmed` with none of them
#     as 0. The `판독` column says which reading was used (`줄`, `옛`, `섞임`,
#     `-` with no seat); a seat without the line is read the older way whether
#     or not that reading counts it. A seat neither reading can count, or no seat at all,
#     makes the sum `미상`: a partial sum reads like a number.
#   * `R3 분` is the modification-time gap between the last chosen R2 witness and
#     the last chosen R3 witness, floored to minutes, read with `date -u -r`.
#
# AUDIT JOIN. The audit reports `docs/design-audit/<slug>.md` are not tracked,
# so they exist only in the main worktree. The default directory is found from
# the parent of `git rev-parse --path-format=absolute --git-common-dir`, never
# `--show-toplevel`: from a linked worktree that finds no report and joins
# nothing. `--audit-dir` overrides it.
#
# Usage:
#   scripts/measure-discussion-passes.sh [--run-root <dir>] [--seat-root <dir>]
#                                        [--audit-dir <dir>]
#
# Exit codes:
#   0 — rows emitted (the header is always printed)
#   2 — usage error
#
# Compatibility: bash 3.2 (macOS) — no associative arrays, no mapfile.

set -euo pipefail

state_home="${XDG_STATE_HOME:-$HOME/.local/state}"
run_root="$state_home/cc-cmds/run"
seat_root="$state_home/cc-cmds/design"
audit_dir=""

while [ $# -gt 0 ]; do
  case "$1" in
    --run-root)  [ $# -ge 2 ] || { echo "measure-discussion-passes: --run-root needs a value" >&2; exit 2; }; run_root="$2"; shift 2 ;;
    --seat-root) [ $# -ge 2 ] || { echo "measure-discussion-passes: --seat-root needs a value" >&2; exit 2; }; seat_root="$2"; shift 2 ;;
    --audit-dir) [ $# -ge 2 ] || { echo "measure-discussion-passes: --audit-dir needs a value" >&2; exit 2; }; audit_dir="$2"; shift 2 ;;
    -h|--help) grep -E '^# ' "$0" | cut -c3-; exit 0 ;;
    *) echo "measure-discussion-passes: unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [ -z "$audit_dir" ]; then
  common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)
  [ -z "$common" ] || audit_dir="$(dirname "$common")/docs/design-audit"
fi

select_pass() {
  # select_pass <witness dir> <round/phase> — the chosen witness of each member,
  # one path per line, sorted. A directory with no *.md leaves the glob
  # unexpanded; `|| continue` keeps that from becoming the loop's exit status,
  # which pipefail would carry out of the pipeline and errexit would end on.
  local d="$1" p="$2" f
  for f in "$d"/*.md; do
    [ -f "$f" ] || continue
    printf '%s\n' "${f##*/}"
  done | awk -v p="$p" -v d="$d" '
    { n = substr($0, 1, length($0) - 3); k = 0
      if (match(n, /-rev[0-9]+$/)) { k = substr(n, RSTART + 4) + 0; n = substr(n, 1, RSTART - 1) }
      s = "." p
      if (length(n) <= length(s) || substr(n, length(n) - length(s) + 1) != s) next
      r = substr(n, 1, length(n) - length(s))
      if (r !~ /^[A-Za-z0-9_-]+$/) next
      if (!(r in best) || k > best[r]) { best[r] = k; file[r] = $0 } }
    END { for (r in file) print d "/" file[r] }' | LC_ALL=C sort
}

off_grammar() {
  # off_grammar <witness dir> — regular files outside the key grammar, with
  # SWEEP.md and INDEX.md left out. An empty directory, or a subdirectory as
  # the last entry, skips through `|| continue` as in select_pass.
  local d="$1" f
  for f in "$d"/*; do
    [ -f "$f" ] || continue
    printf '%s\n' "${f##*/}"
  done | awk '
    $0 == "SWEEP.md" || $0 == "INDEX.md" { next }
    { n = $0
      if (substr(n, length(n) - 2) != ".md") { c++; next }
      n = substr(n, 1, length(n) - 3)
      sub(/-rev[0-9]+$/, "", n)
      if (n !~ /^[A-Za-z0-9_-]+\.(round-[0-9]+|fidelity|coherence)$/) c++ }
    END { printf "%d", c }'
}

read_witnesses() {
  # read_witnesses <what> [<pass>] — reads witness paths on stdin and prints:
  #   declarations — `<measure> <undeclared>`
  #   findings     — `<sum|미상> <줄|옛|섞임|->` for <pass> fidelity|coherence
  #   reopens      — the `- type: decision-reopen` line count, `미상` with none
  awk -v what="$1" -v pass="${2:-}" '
    $0 == "" { next }
    { f = $0; n++; d = ""; v = ""; t = 0; ok = 0
      while ((getline line < f) > 0) {
        sub(/\r$/, "", line)
        if (line == "round-3: none") d = "none"
        else if (index(line, "round-3: measure — ") == 1) d = "measure"
        if (line ~ /^findings: [0-9]+$/) v = substr(line, 11)
        if (line ~ /^[[:space:]]*-[[:space:]]*type:/) t++
        if (index(line, "Fidelity confirmed") > 0) ok = 1
        s = line; sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s)
        if (s == "- type: decision-reopen") reopen++
      }
      close(f)
      if (d == "measure") measure++; else if (d == "") undeclared++
      if (v != "") { bylines++; sum += v }
      else if (t > 0) { byold++; sum += t }
      else if (pass == "fidelity" && ok) { byold++ }
      else { byold++; missing++ } }
    END {
      if (what == "declarations") { printf "%d %d", measure, undeclared; exit }
      if (what == "reopens") { if (n == 0) printf "미상"; else printf "%d", reopen; exit }
      mode = (n == 0) ? "-" : (bylines && byold) ? "섞임" : bylines ? "줄" : "옛"
      if (n == 0 || missing) printf "미상 %s", mode; else printf "%d %s", sum, mode }'
}

last_mtime() {
  # last_mtime — the latest modification time, in epoch seconds, of the paths
  # on stdin; empty when none can be read.
  local f t m=''
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    t=$(date -u -r "$f" +%s 2>/dev/null || true)
    case "$t" in ''|*[!0-9]*) continue ;; esac
    { [ -z "$m" ] || [ "$t" -gt "$m" ]; } && m=$t
  done
  printf '%s' "$m"
}

fence() {
  # fence <report> <key> — the value after <key> inside the audit disclosure fence.
  awk -v k="$2" '
    index($0, "<!-- cc-design-audit-disclosure v1 begin -->") == 1 { i = 1; next }
    index($0, "<!-- /cc-design-audit-disclosure v1 end -->") == 1 { i = 0; next }
    i && index($0, k) == 1 { print substr($0, length(k) + 1); exit }' "$1"
}

measure_corpus() {
  # measure_corpus <source> <witness dir> <slug>
  local src="$1" wd="$2" slug="$3" r1 r2 r3 fid coh
  r1=$(select_pass "$wd" round-1)
  [ -n "$r1" ] || return 0
  r2=$(select_pass "$wd" round-2)
  r3=$(select_pass "$wd" round-3)
  fid=$(select_pass "$wd" fidelity)
  coh=$(select_pass "$wd" coherence)
  local open=0 m u named sweep why mins='미상' t2 t3 ff fm cf cm au='미상' ab='미상'
  [ -n "$r3" ] && open=1
  read -r m u <<EOF
$(printf '%s\n' "$r2" | read_witnesses declarations)
EOF
  named=$m
  [ "$m" -eq 0 ] && [ "$u" -gt 0 ] && named='미상'
  if [ -f "$wd/SWEEP.md" ]; then
    sweep=$(awk '{ sub(/\r$/, "") } index($0, "round-3: sweep — ") == 1 { c++ } END { printf "%d", c }' "$wd/SWEEP.md" 2>/dev/null) || sweep='미상'
  else
    sweep='미상'
  fi
  if [ "$open" -eq 0 ] && [ "$m" -ge 1 ]; then why='지명 미개방'
  elif [ "$open" -eq 0 ]; then why='해당 없음'
  elif [ "$m" -ge 1 ]; then why='측정 지명'
  elif [ "$u" -gt 0 ]; then why='미상'
  else why='선언 없음'
  fi
  if [ "$open" -eq 1 ] && [ -n "$r2" ]; then
    t2=$(printf '%s\n' "$r2" | last_mtime)
    t3=$(printf '%s\n' "$r3" | last_mtime)
    if [ -n "$t2" ] && [ -n "$t3" ] && [ "$t3" -ge "$t2" ]; then
      mins=$(( (t3 - t2) / 60 ))
    fi
  fi
  read -r ff fm <<EOF
$(printf '%s\n' "$fid" | read_witnesses findings fidelity)
EOF
  read -r cf cm <<EOF
$(printf '%s\n' "$coh" | read_witnesses findings coherence)
EOF
  if [ -n "$audit_dir" ] && [ -f "$audit_dir/$slug.md" ]; then
    au=$(fence "$audit_dir/$slug.md" '**고유 결함 수**: ')
    ab=$(fence "$audit_dir/$slug.md" '**동결 문서 바이트**: ')
    [ -n "$au" ] || au='미상'
    [ -n "$ab" ] || ab='미상'
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$src" "$wd" "$slug" "$(off_grammar "$wd")" "$(printf '%s\n' "$r1" | grep -c .)" \
    "$([ "$open" -eq 1 ] && printf '열림' || printf '닫힘')" "$named" "$sweep" "$why" "$mins" \
    "$(printf '%s\n' "$fid" | grep -c . || true)" "$ff" "$fm" \
    "$(printf '%s\n' "$fid" | read_witnesses reopens)" \
    "$(printf '%s\n' "$coh" | grep -c . || true)" "$cf" "$cm" "$au" "$ab"
}

measure_tree() {
  # measure_tree <source> <witness dir> — the corpus itself, then each
  # subdirectory as a corpus of its own, all joined on the document slug.
  local src="$1" wd="$2" slug sub
  slug=$(basename "$(dirname "$wd")")
  measure_corpus "$src" "$wd" "$slug"
  for sub in "$wd"/*/; do
    [ -d "$sub" ] || continue
    measure_corpus "$src" "${sub%/}" "$slug"
  done
}

printf '출처\t말뭉치\t슬러그\t문법 밖\t팀원\tR3\t측정 지명\t스윕 반박\tR3 사유\tR3 분\t충실도 좌석\t충실도 발견\t충실도 판독\t충실도 재개\t정합 좌석\t정합 발견\t정합 판독\t감사 고유\t감사 바이트\n'
for wd in "$run_root"/*/design/*/witness; do
  [ -d "$wd" ] && measure_tree run "$wd"
done
for wd in "$seat_root"/*/witness; do
  [ -d "$wd" ] && measure_tree seat "$wd"
done
exit 0
