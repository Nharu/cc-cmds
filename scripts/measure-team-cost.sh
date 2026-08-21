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
    --transcripts) transcript_root="${2:-}"; shift 2 ;;
    --project)     project_scope="${2:-}"; shift 2 ;;
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
COMMAND_RE='(^|[^a-zA-Z0-9_-])(git|grep|rg|sed|awk|find|make|npm|npx|yarn|pnpm|node|python3?|bash|sh|shasum|openssl|jq|curl|gh|cargo|go|swift|flutter|dart|xcrun|test -f|wc)([[:space:]]+-{0,2}[a-zA-Z0-9]|[[:space:]]+[a-zA-Z0-9./_-]+)'

# flatten <file> — every string value in every JSON record, one record per line.
# Schema-agnostic on purpose: the transcript's envelope shape is not this
# script's contract, and a non-JSON line is skipped rather than fatal.
# Embedded newlines are collapsed so one record stays one line: a witness
# sentinel and the body it terminates live in the same string, and letting that
# string break across lines would separate every sentinel from its own body.
flatten() {
  jq -R -r 'fromjson? | [.. | strings] | join(" ") | gsub("\n"; " ")' "$1" 2>/dev/null || true
}

emit_na() { printf 'NA'; }

printf 'session\tskill\troster_size\tmax_round\tround3_fired\tr3_witness_cmd\tr2_final_witness_cmd\tnarrowed_additions\tnarrowed_deletions\tnarrowed_files\tscope_source\n'

while IFS= read -r main; do
  [[ -f "$main" ]] || continue
  session=$(basename "$main" .jsonl)

  # Read the main transcript only. Witness bodies land here anyway — the
  # protocol makes the witness file, not the return text, authoritative, so the
  # lead Reads every witness and the body arrives as a tool result in this
  # session's own records. The sibling `subagents/` directory is flat and
  # carries no session attribution, so folding it in would smear one session's
  # witnesses across every session in the scope.
  bundle=$(flatten "$main")

  skill=$(printf '%s\n' "$bundle" \
    | grep -oE 'cc-cmds:(design|design-lite|design-apply|design-analyze|design-audit|review|review-lite)' \
    | head -1 | sed 's/^cc-cmds://' || true)
  [[ -n "$skill" ]] || skill=NA

  # Ledger rows: `<agentId> | <state> | <round/phase> | ...`
  rows=$(printf '%s\n' "$bundle" \
    | grep -oE '[0-9a-f]{6,} \| (running|done|aborted) \| [^|]+' || true)

  roster_size=0
  if [[ -n "$rows" ]]; then
    roster_size=$(printf '%s\n' "$rows" | awk '{print $1}' | sort -u | grep -c '' || true)
  fi

  max_round=0
  round_tokens=$(printf '%s\n' "$rows" | grep -oE 'round-[0-9]+' | grep -oE '[0-9]+' || true)
  if [[ -n "$round_tokens" ]]; then
    max_round=$(printf '%s\n' "$round_tokens" | sort -n | tail -1)
  fi

  round3_fired=0
  (( max_round >= 3 )) && round3_fired=1

  # Witness bodies, keyed by the round the sentinel itself declares.
  r3_witness_cmd=$(emit_na)
  r2_final_witness_cmd=$(emit_na)
  witness_lines=$(printf '%s\n' "$bundle" | grep -F 'cc-witness:' || true)
  if [[ -n "$witness_lines" ]]; then
    r3_bodies=$(printf '%s\n' "$witness_lines" | grep -E 'cc-witness: [^ ]+ round-3 ' || true)
    if [[ -n "$r3_bodies" ]]; then
      if printf '%s\n' "$r3_bodies" | grep -qE "$COMMAND_RE"; then
        r3_witness_cmd=1
      else
        r3_witness_cmd=0
      fi
    fi
    # The round-2 witnesses matter only when the discussion stopped there: that
    # is the skipped-round-3 population trigger 2 has to separate.
    if (( round3_fired == 0 )); then
      r2_bodies=$(printf '%s\n' "$witness_lines" | grep -E 'cc-witness: [^ ]+ round-2 ' || true)
      if [[ -n "$r2_bodies" ]]; then
        if printf '%s\n' "$r2_bodies" | grep -qE "$COMMAND_RE"; then
          r2_final_witness_cmd=1
        else
          r2_final_witness_cmd=0
        fi
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
      read -r adds dels files <<EOF
$(printf '%s\n' "$numstat" | grep -oE '[0-9]+\t[0-9]+\t[^ ]+' | awk -F'\t' '{A+=$1; D+=$2; N++} END {printf "%d %d %d", A, D, N}')
EOF
      scope_source=numstat
    fi
  fi

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$session" "$skill" "$roster_size" "$max_round" "$round3_fired" \
    "$r3_witness_cmd" "$r2_final_witness_cmd" \
    "$adds" "$dels" "$files" "$scope_source"
done < <(find "$scope_dir" -maxdepth 1 -name '*.jsonl' | sort)
