#!/usr/bin/env bash
# Extract the observations the team-budget rollback triggers need, one TSV row
# per session.
#
# This is NOT a gate. Nothing here passes or fails; the output is the input to
# a human judgment call — the stratified under-staffing review of trigger 1 and
# the counterfactual review of trigger 2's C2. `make test` runs this script
# against synthetic fixtures only, never against real session history.
#
# What it reads and why:
#
#   round-3 firing rate        ledger `round/phase` column. That column is not
#                              one of the four transient fields stripped from
#                              terminal rows, so it survives into the committed
#                              document and can be compared before/after.
#   witness body classification  reconstructed from the session transcript, NOT
#                              from the witness directory: a normally-completed
#                              workflow `rm -rf`s that directory, and the row's
#                              `scratchDir` is stripped, so even the path is
#                              gone afterwards. The transcript is the only
#                              surviving copy.
#   roster size                ledger row count, stratified by skill.
#   gate input (lines/files)   the narrowed review scope. What is recorded is
#                              the gate's INPUT, never its verdict: no ledger
#                              column holds a verdict and the review report does
#                              not write one, so a verdict would be exactly the
#                              kind of missing-source requirement that made the
#                              witness-directory plan unworkable. The verdict is
#                              recomputed afterwards from this input and the
#                              small-patch threshold.
#
# Transcript root is REQUIRED and has NO default pointing at a real home
# directory. A default would make this script pass non-deterministically on a
# machine that happens to have session history and fail on one that does not —
# and the passing case is the worse of the two, because it certifies nothing
# while looking like a pass.
#
# Scope defaults to this repo's own project directory rather than the whole
# transcript root: a global scan would mix unrelated sessions into the sample
# and read the user's other work.
#
# Usage:
#   scripts/measure-team-cost.sh --transcripts <dir> [--project <name>]
#   TRANSCRIPT_ROOT=<dir> PROJECT_SCOPE=<name> scripts/measure-team-cost.sh
#
# Exit codes:
#   0 — rows emitted (possibly zero data rows; the header is always printed)
#   2 — usage error / unreadable input

set -euo pipefail

transcript_root="${TRANSCRIPT_ROOT:-}"
project_scope="${PROJECT_SCOPE:-}"

while (( $# > 0 )); do
  case "$1" in
    # `shift 2` on a flag with no value fails under `set -e` and exits 1, which
    # is this script's "measured nothing" code rather than its usage code. Guard
    # the arity so a typo is reported as usage (2) instead of masquerading.
    --transcripts)
      [[ $# -ge 2 ]] || { echo "measure-team-cost: --transcripts needs a value" >&2; exit 2; }
      transcript_root="$2"; shift 2 ;;
    --project)
      [[ $# -ge 2 ]] || { echo "measure-team-cost: --project needs a value" >&2; exit 2; }
      project_scope="$2"; shift 2 ;;
    -h|--help)
      grep -E '^# ' "$0" | cut -c3-
      exit 0
      ;;
    *)
      echo "measure-team-cost: unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

if [[ -z "$transcript_root" ]]; then
  echo "measure-team-cost: --transcripts <dir> (or TRANSCRIPT_ROOT) is required — there is deliberately no default" >&2
  exit 2
fi
if [[ ! -d "$transcript_root" ]]; then
  echo "measure-team-cost: transcript root not found: $transcript_root" >&2
  exit 2
fi

if [[ -z "$project_scope" ]]; then
  # Claude Code names a project directory after the absolute repo path with the
  # separators flattened. Derive this repo's name rather than scanning them all.
  script_dir=$(cd "$(dirname "$0")" && pwd)
  repo_root=$(cd "$script_dir/.." && pwd)
  project_scope=$(printf '%s' "$repo_root" | tr '/' '-')
fi

scope_dir="$transcript_root/$project_scope"
if [[ ! -d "$scope_dir" ]]; then
  echo "measure-team-cost: project scope not found: $scope_dir" >&2
  echo "measure-team-cost: pass --project <name> to name it explicitly" >&2
  exit 2
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "measure-team-cost: jq is required" >&2
  exit 2
fi

# A witness body "names a command" when it cites something runnable rather than
# describing an intention. This is the observable that separates lever 04's two
# residuals: a skipped round 3 whose witness named a command is a wording
# problem and is fixable, while one that named nothing is the residual accepted
# without a mechanism.
#
# Precision-first, two tiers plus a code-span pass:
#   TIER 1 — tokens that are not ordinary English words. A bare mention is
#            enough; requiring an operand here loses real positives such as
#            "we ran git bisect on it".
#   TIER 2 — homographs (`find`, `make`, `go`, `node`, `test`). These need a
#            shell-shaped operand, or every sentence containing the English
#            word scores as a command.
#   SPAN   — anything the author wrapped in backticks. A code span is an
#            explicit citation, so it passes regardless of tier.
#
# Tier 1 stays deliberately loose. Tightening it would filter one false
# positive of the "jq is required" shape at the cost of three true positives,
# and this column feeds a human judgment call rather than a gate.
COMMAND_TIER1='(^|[^a-zA-Z0-9_./-])(git|grep|ggrep|rg|sed|awk|jq|npm|npx|yarn|pnpm|xcrun|shasum|openssl|curl|gh|cargo|flutter|dart|pytest|eslint|tsc|melos|simctl)([^a-zA-Z0-9_-]|$)'
COMMAND_TIER2='(^|[^a-zA-Z0-9_./-])(find|make|go|node|test|wc|sh|bash|python3?|swift|diff|cat|ls)[[:space:]]+(-{1,2}[a-zA-Z0-9][a-zA-Z0-9-]*|[a-zA-Z0-9._/-]+)([[:space:]]|$)'
COMMAND_SPAN='`[^`]*(git|grep|sed|awk|jq|npm|npx|make|find|node|go|test|wc|bash|sh|python|swift|flutter|dart|curl|gh|shasum|openssl)[^`]*`'

# names_command <text> — the three arms OR'd. Kept as a function so the arms
# stay separately readable and separately tunable.
names_command() {
  printf '%s\n' "$1" | grep -qE "$COMMAND_TIER1" && return 0
  printf '%s\n' "$1" | grep -qE "$COMMAND_TIER2" && return 0
  printf '%s\n' "$1" | grep -qE "$COMMAND_SPAN" && return 0
  return 1
}

# flatten <file> — every string value in every JSON record, one record per line.
# Schema-agnostic on purpose: the transcript's envelope shape is not this
# script's contract, and a non-JSON line is skipped rather than fatal.
# Embedded newlines are collapsed so one record stays one line: a witness
# sentinel and the body it terminates live in the same string, and letting that
# string break across lines would separate every sentinel from its own body.
READ_ERROR_SENTINEL='CC_MEASURE_READ_ERROR'

flatten() {
  local out
  if [[ ! -r "$1" ]] || ! out=$(jq -R -r 'fromjson? | [.. | strings] | join(" ") | gsub("\n"; " ")' "$1" 2>/dev/null); then
    # An unreadable transcript is not an empty one. Returning "" here would
    # make every column read as a measured zero, which is the shape of the
    # fabrication this script exists to avoid.
    printf '%s\n' "$READ_ERROR_SENTINEL"
    return
  fi
  printf '%s\n' "$out"
}

emit_na() { printf 'NA'; }

# Column note — `gate_input_*` is the review gate's INPUT, not its verdict, and
# `scope_source` says which reading produced it. Only `per-file` reflects a
# Step-1c narrowing; a `pr-summary` row carries the PRE-narrowing number and
# must not be read as the gate's effective scope. The columns were once named
# `narrowed_*`, which asserted something the `pr-summary` path cannot deliver.
printf 'session\tskill\troster_size\tmax_round\tround3_fired\tr3_witness_cmd\tr2_final_witness_cmd\tgate_input_additions\tgate_input_deletions\tgate_input_files\tscope_source\n'

# ---------- pass 1: nonce → session attribution -------------------------------
#
# Witness bodies do not live in the main transcript. Measured over the real
# corpus, more than 94% of sentinel-bearing files sit under `subagents/`, and a
# main-transcript-only read reaches roughly 5.7% of the nonce-bearing
# transcripts. Joining on the nonce inverts that loss rather than trimming it.
#
# **The key is a SET, not a single value.** A session mints a fresh nonce per
# member per round, so harvesting one nonce per session and joining on it would
# silently drop every round carrying a different value — reproducing the same
# ~94% loss under a name that looks repaired. A nonce resolving to more than
# one main transcript is left UNATTRIBUTED rather than resolved to the first
# match: guessing would double-count that witness into two populations.

WORK=$(mktemp -d "${TMPDIR:-/tmp}/cc-measure.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

# nonces_of <flattened-text> — every nonce the text mentions, deduplicated.
# Sentinels carry one explicitly; dispatch prompts often carry the bare hex or
# the round-tagged compound form without a sentinel.
nonces_of() {
  {
    printf '%s\n' "$1" | grep -oE 'cc-witness: [^ ]+ [^ ]+ complete [0-9a-f]+' | awk '{print $NF}'
    printf '%s\n' "$1" | grep -oE 'round-[0-9]+:[0-9a-f]+' | sed 's/.*://'
    printf '%s\n' "$1" | grep -oE '[0-9a-f]{16}'
  } 2>/dev/null | sort -u || true
}

while IFS= read -r m; do
  [[ -f "$m" ]] || continue
  s=$(basename "$m" .jsonl)
  b=$(flatten "$m")
  printf '%s\n' "$b" > "$WORK/main.$s.txt"
  nonces_of "$b" | while IFS= read -r nz; do
    [[ -n "$nz" ]] && printf '%s\t%s\n' "$nz" "$s"
  done
done < <(find "$scope_dir" -maxdepth 1 -name '*.jsonl' | sort) | sort -u > "$WORK/nonce-map.tsv"

# Keep only nonces owned by exactly one session. Collisions become NA.
awk -F'\t' '{c[$1]++; s[$1]=$2} END {for (n in c) if (c[n] == 1) print n "\t" s[n]}' \
  "$WORK/nonce-map.tsv" > "$WORK/nonce-owner.tsv"

# Harvest every subagent witness line, keyed by the nonce its sentinel declares.
: > "$WORK/sub-witness.tsv"
while IFS= read -r sub; do
  [[ -f "$sub" ]] || continue
  flatten "$sub" | grep -F 'cc-witness:' | while IFS= read -r wl; do
    nz=$(printf '%s\n' "$wl" | grep -oE 'cc-witness: [^ ]+ [^ ]+ complete [0-9a-f]+' | awk '{print $NF}' | head -1)
    [[ -n "$nz" ]] || continue
    printf '%s\t%s\n' "$nz" "$wl"
  done
done < <(find "$scope_dir/subagents" -name '*.jsonl' 2>/dev/null | sort) >> "$WORK/sub-witness.tsv"

# ---------- pass 2: one row per session ---------------------------------------

while IFS= read -r main; do
  [[ -f "$main" ]] || continue
  session=$(basename "$main" .jsonl)
  bundle=$(cat "$WORK/main.$session.txt")

  # An unreadable transcript is stamped, not measured. Every column says so.
  if printf '%s\n' "$bundle" | grep -Fq -- "$READ_ERROR_SENTINEL"; then
    printf '%s\tNA\tNA\tNA\tNA\tNA\tNA\tNA\tNA\tNA\tREAD-ERROR\n' "$session"
    continue
  fi

  # Longest name first AND a right anchor. ERE alternation is left-biased, so
  # `design` alone would win against `cc-cmds:design-lite` and every lite
  # session would be filed under the base skill — a mislabel that survives
  # every other check in this row.
  skill=$(printf '%s\n' "$bundle" \
    | grep -oE 'cc-cmds:(design-analyze|design-apply|design-audit|design-ingest|design-lite|design-prompt|design-system|design-upgrade|review-lite|review-upgrade|design|review)([^a-z-]|$)' \
    | head -1 | sed -e 's/^cc-cmds://' -e 's/[^a-z-]*$//' || true)
  [[ -n "$skill" ]] || skill=NA

  # Ledger rows: `<agentId> | <state> | <round/phase> | ...` for the document
  # ledger, plus `design-analyze`'s `work.json` shape, whose rows are JSON
  # objects rather than pipe-delimited text. Without the second branch that
  # skill reports an empty roster and prices its own saving at zero.
  rows=$(printf '%s\n' "$bundle" \
    | grep -oE '[0-9a-f]{6,} \| (running|done|aborted) \| [^|]+' || true)
  json_rows=$(printf '%s\n' "$bundle" \
    | grep -oE '"agentId"[[:space:]]*:[[:space:]]*"[0-9a-f]{6,}"' || true)

  # NA floor: an absent ledger is "not measured", never "measured zero". A
  # numeric 0 here is indistinguishable from a real single-agent run, and it is
  # the same confident-zero this script exists to stop emitting.
  roster_size=$(emit_na)
  if [[ -n "$rows" ]]; then
    roster_size=$(printf '%s\n' "$rows" | awk '{print $1}' | sort -u | grep -c '' || true)
  elif [[ -n "$json_rows" ]]; then
    roster_size=$(printf '%s\n' "$json_rows" | grep -oE '[0-9a-f]{6,}' | sort -u | grep -c '' || true)
  fi

  max_round=$(emit_na)
  round3_fired=$(emit_na)
  round_tokens=$(printf '%s\n' "$bundle" | grep -oE 'round-[0-9]+' | grep -oE '[0-9]+' || true)
  if [[ -n "$round_tokens" ]]; then
    max_round=$(printf '%s\n' "$round_tokens" | sort -n | tail -1)
    round3_fired=0
    (( max_round >= 3 )) && round3_fired=1
  fi

  # Witness pool = this session's own sentinel lines PLUS every subagent
  # witness whose nonce resolves uniquely to this session (pass 1).
  own_nonces=$(awk -F'\t' -v s="$session" '$2 == s {print $1}' "$WORK/nonce-owner.tsv" || true)
  sub_lines=""
  if [[ -n "$own_nonces" ]]; then
    sub_lines=$(awk -F'\t' 'NR == FNR { own[$0] = 1; next } ($1 in own) { print $2 }' \
      <(printf '%s\n' "$own_nonces") "$WORK/sub-witness.tsv" || true)
  fi
  witness_lines=$( { printf '%s\n' "$bundle" | grep -F 'cc-witness:' || true
                     printf '%s\n' "$sub_lines"; } | grep -F 'cc-witness:' || true)

  r3_witness_cmd=$(emit_na)
  r2_final_witness_cmd=$(emit_na)
  if [[ -n "$witness_lines" ]]; then
    r3_bodies=$(printf '%s\n' "$witness_lines" | grep -E 'cc-witness: [^ ]+ round-3 ' || true)
    if [[ -n "$r3_bodies" ]]; then
      if names_command "$r3_bodies"; then r3_witness_cmd=1; else r3_witness_cmd=0; fi
    fi
    # The round-2 witnesses matter only when the discussion stopped there: that
    # is the skipped-round-3 population trigger 2 has to separate.
    if [[ "$round3_fired" == "0" ]]; then
      r2_bodies=$(printf '%s\n' "$witness_lines" | grep -E 'cc-witness: [^ ]+ round-2 ' || true)
      if [[ -n "$r2_bodies" ]]; then
        if names_command "$r2_bodies"; then r2_final_witness_cmd=1; else r2_final_witness_cmd=0; fi
      fi
    fi
  fi

  # Gate input. Preference order matters: the per-file array is the only source
  # that can reflect a Step-1c narrowing, so a row sourced from `pr-summary` is
  # the pre-narrowing number and must be read as such.
  adds=$(emit_na); dels=$(emit_na); files=$(emit_na); scope_source=NA
  perfile=$(printf '%s\n' "$bundle" \
    | grep -oE '\{"path":"[^"]+","additions":[0-9]+,"deletions":[0-9]+\}' || true)
  if [[ -n "$perfile" ]]; then
    read -r adds dels files <<EOF
$(printf '%s\n' "$perfile" | awk -F'"additions":' '{split($2,a,","); split($0,d,"\"deletions\":"); split(d[2],b,"}"); A+=a[1]; D+=b[1]; N++} END {printf "%d %d %d", A, D, N}')
EOF
    scope_source=per-file
  else
    numstat=$(printf '%s\n' "$bundle" | grep -F -- '--numstat' || true)
    summary=$(printf '%s\n' "$bundle" \
      | grep -oE '"additions":[0-9]+,"deletions":[0-9]+,"changedFiles":[0-9]+' | head -1 || true)
    if [[ -n "$summary" ]]; then
      adds=$(printf '%s' "$summary" | grep -oE '"additions":[0-9]+' | grep -oE '[0-9]+')
      dels=$(printf '%s' "$summary" | grep -oE '"deletions":[0-9]+' | grep -oE '[0-9]+')
      files=$(printf '%s' "$summary" | grep -oE '"changedFiles":[0-9]+' | grep -oE '[0-9]+')
      scope_source=pr-summary
    elif [[ -n "$numstat" ]]; then
      # The pattern uses a LITERAL tab, not the ERE escape `\t`. BSD grep
      # accepts `\t` there and GNU grep warns "stray \ before t" and matches
      # nothing — and the only CI leg that runs this file is the GNU one. The
      # `END` block is guarded so a no-match input yields NA instead of the
      # confident `0 0 0` that used to be stamped `scope_source=numstat`.
      read -r adds dels files <<EOF
$(printf '%s\n' "$numstat" | grep -oE '[0-9]+	[0-9]+	[^ ]+' \
  | awk -F'\t' '{A+=$1; D+=$2; N++} END {if (N > 0) printf "%d %d %d", A, D, N; else printf "NA NA NA"}')
EOF
      if [[ "$adds" == "NA" ]]; then
        # Self-contradiction: the source was present but nothing parsed out of
        # it. Say which reading failed rather than leaving a confident label on
        # values it did not produce.
        scope_source=numstat-unreadable
      else
        scope_source=numstat
      fi
    fi
  fi

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$session" "$skill" "$roster_size" "$max_round" "$round3_fired" \
    "$r3_witness_cmd" "$r2_final_witness_cmd" \
    "$adds" "$dels" "$files" "$scope_source"
done < <(find "$scope_dir" -maxdepth 1 -name '*.jsonl' | sort)
