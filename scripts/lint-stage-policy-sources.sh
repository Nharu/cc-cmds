#!/usr/bin/env bash
# Pin the repository half of the stage-policy drift contract.
#
# `plugins/cc-cmds/orchestrator/stage-policy.md` is the English policy the gate
# injects into every unattended stage in place of automatic CLAUDE.md loading,
# and `stage-policy.sources.tsv` beside it is the only link between that policy
# and the hand-edited files it was distilled from. The source half of the
# check — whether those files still say what the manifest recorded — is
# `plugins/cc-cmds/orchestrator/stage-policy-drift.sh`, deliberately NOT run
# here: a person editing their global CLAUDE.md must not turn an unrelated
# unattended stage's `make check` red. This lint checks only what the
# repository itself controls:
#
#   (i)    the policy file exists and is ASCII apart from tab and newline —
#          the injected block is the cache-stable head of every stage prompt,
#          and a stray non-ASCII byte is the kind of edit that goes unnoticed;
#   (ii)   the policy is at most 8000 bytes — it rides on every request of
#          every stage and every team member;
#   (iii)  the policy carries no volatile token (a date, a `run-<n>`, a
#          `/Users/` path) — one would make the bytes differ per host or per
#          run and break the shared cache head;
#   (iv)   the two sentences the team-delivery contract rests on each appear
#          on exactly one line: the harness delivers the policy to Agent-tool
#          members (so leads must not paste it), and a team the stage skill
#          prescribes is itself the instruction to spawn it (so the delegation
#          rule cannot be read as "review alone");
#   (v)    the manifest is well formed: the exact header, five tab-separated
#          columns, `source` in {user-scope, workspace, memory}, `disposition`
#          in the closed vocabulary;
#   (vi)   every `policy:<heading>` disposition names a `## ` heading that
#          exists in the policy;
#   (vii)  every `## ` heading of the policy is named by at least one row —
#          a section nothing maps to is a rule with no source;
#   (viii) every `user-scope` anchor is unique within the manifest;
#   (ix)   `memory` rows carry hash `-` and every other row a 64-hex sha256.
#
# Usage:
#   bash scripts/lint-stage-policy-sources.sh
#   POLICY_ROOT=<dir> bash scripts/lint-stage-policy-sources.sh   # fixture test
#
# Exit codes:
#   0 — every check passed
#   1 — at least one check failed (one line per failure on stderr)

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
policy_root="${POLICY_ROOT:-$repo_root/plugins/cc-cmds/orchestrator}"
while [[ "$policy_root" == */ && "$policy_root" != "/" ]]; do
  policy_root="${policy_root%/}"
done

POLICY="$policy_root/stage-policy.md"
MANIFEST="$policy_root/stage-policy.sources.tsv"
MAX_BYTES=8000
PIN_HARNESS='Agents spawned with the Agent tool receive this policy and the repository instructions from the harness; do not paste them.'
PIN_TEAM='a team the stage skill prescribes is itself the instruction to spawn it'
MANIFEST_HEADER=$'source\tanchor\tsha256\tdisposition\tnote'
DISPOSITION_RE='^(policy:[^	]+|skill:[^	]+|repo:CLAUDE\.md|excluded:(mcp-unavailable|interactive-only|driver-owned|superseded|host-mutation|workspace-local|no-stage-login))$'

fail=0
checked=0

failf() { echo "FAIL: $*" >&2; fail=1; }

# ---------- (i) policy exists, ASCII only ------------------------------------

checked=$((checked + 1))
if [[ ! -f "$POLICY" ]]; then
  failf "stage-policy.md not found: $POLICY"
fi
checked=$((checked + 1))
if [[ ! -f "$MANIFEST" ]]; then
  failf "stage-policy.sources.tsv not found: $MANIFEST"
fi
if (( fail == 1 )); then
  exit 1
fi

# CAPTURED, NOT `grep -q`: an early-exiting reader kills the writer with
# SIGPIPE and `pipefail` then reports the pipeline as failed even on a match.
non_ascii=$(LC_ALL=C grep -c -a -E '[^	 -~]' "$POLICY" || true)
if [[ "${non_ascii:-0}" != "0" ]]; then
  failf "stage-policy.md — $non_ascii line(s) carry a byte outside printable ASCII, tab and newline"
fi

# ---------- (ii) size --------------------------------------------------------

checked=$((checked + 1))
policy_bytes=$(wc -c < "$POLICY" | tr -d ' ')
if (( policy_bytes > MAX_BYTES )); then
  failf "stage-policy.md — $policy_bytes bytes exceeds the $MAX_BYTES-byte ceiling"
fi

# ---------- (iii) volatile tokens --------------------------------------------

checked=$((checked + 1))
volatile=$(grep -n -E '20[0-9][0-9]-[0-9][0-9]-|run-[0-9]|/Users/' "$POLICY" || true)
if [[ -n "$volatile" ]]; then
  while IFS= read -r hit; do
    [[ -n "$hit" ]] || continue
    failf "stage-policy.md:${hit%%:*} — volatile token (date, run id or /Users/ path): ${hit#*:}"
  done <<< "$volatile"
fi

# ---------- (iv) the two team-delivery pins ----------------------------------

for pin in "$PIN_HARNESS" "$PIN_TEAM"; do
  checked=$((checked + 1))
  n=$(grep -cF -- "$pin" "$POLICY" || true)
  if [[ "${n:-0}" != "1" ]]; then
    failf "stage-policy.md — pinned sentence must appear on exactly 1 line, found ${n:-0}: $pin"
  fi
done

# ---------- (v) manifest shape -----------------------------------------------

checked=$((checked + 1))
header=$(head -n 1 "$MANIFEST")
if [[ "$header" != "$MANIFEST_HEADER" ]]; then
  failf "stage-policy.sources.tsv — header must be 'source<TAB>anchor<TAB>sha256<TAB>disposition<TAB>note'"
fi

bad_cols=$(awk -F'\t' 'NR > 1 && NF != 5 { print NR ": " NF " column(s)" }' "$MANIFEST")
if [[ -n "$bad_cols" ]]; then
  while IFS= read -r hit; do
    [[ -n "$hit" ]] || continue
    failf "stage-policy.sources.tsv:$hit — expected 5 tab-separated columns"
  done <<< "$bad_cols"
fi

policy_headings=$(grep -E '^## ' "$POLICY" | sed -E 's/^## //' || true)

lineno=0
while IFS= read -r row || [[ -n "$row" ]]; do
  lineno=$((lineno + 1))
  (( lineno > 1 )) || continue
  source=$(printf '%s\n' "$row" | awk -F'\t' '{ print $1 }')
  anchor=$(printf '%s\n' "$row" | awk -F'\t' '{ print $2 }')
  sha=$(printf '%s\n' "$row" | awk -F'\t' '{ print $3 }')
  disp=$(printf '%s\n' "$row" | awk -F'\t' '{ print $4 }')

  checked=$((checked + 1))
  case "$source" in
    user-scope|workspace|memory) : ;;
    *) failf "stage-policy.sources.tsv:$lineno — source must be user-scope, workspace or memory: '$source'" ;;
  esac
  if [[ -z "$anchor" ]]; then
    failf "stage-policy.sources.tsv:$lineno — empty anchor"
  fi
  if [[ ! "$disp" =~ $DISPOSITION_RE ]]; then
    failf "stage-policy.sources.tsv:$lineno — disposition outside the closed vocabulary: '$disp'"
  fi

  # (vi) a policy: disposition names a real heading
  if [[ "$disp" == policy:* ]]; then
    named="${disp#policy:}"
    # CAPTURED, NOT `grep -q` — same SIGPIPE/pipefail reason as above.
    hits=$(printf '%s\n' "$policy_headings" | grep -Fxc -- "$named" || true)
    if [[ "${hits:-0}" == "0" ]]; then
      failf "stage-policy.sources.tsv:$lineno — policy section not found in stage-policy.md: '## $named'"
    fi
  fi

  # (ix) hash column
  if [[ "$source" == memory ]]; then
    if [[ "$sha" != "-" ]]; then
      failf "stage-policy.sources.tsv:$lineno — a memory row carries hash '-', found '$sha'"
    fi
  elif [[ ! "$sha" =~ ^[0-9a-f]{64}$ ]]; then
    failf "stage-policy.sources.tsv:$lineno — sha256 must be 64 hex characters, found '$sha'"
  fi
done < "$MANIFEST"

# ---------- (vii) every policy heading is named by at least one row ---------

named_headings=$(awk -F'\t' 'NR > 1 && $4 ~ /^policy:/ { sub(/^policy:/, "", $4); print $4 }' "$MANIFEST" | sort -u)
while IFS= read -r heading; do
  [[ -n "$heading" ]] || continue
  checked=$((checked + 1))
  hits=$(printf '%s\n' "$named_headings" | grep -Fxc -- "$heading" || true)
  if [[ "${hits:-0}" == "0" ]]; then
    failf "stage-policy.md — section '## $heading' is named by no row of stage-policy.sources.tsv"
  fi
done <<< "$policy_headings"

# ---------- (viii) user-scope anchors unique within the manifest -------------

checked=$((checked + 1))
dupes=$(awk -F'\t' 'NR > 1 && $1 == "user-scope" { print $2 }' "$MANIFEST" | sort | uniq -d || true)
if [[ -n "$dupes" ]]; then
  while IFS= read -r d; do
    [[ -n "$d" ]] || continue
    failf "stage-policy.sources.tsv — user-scope anchor appears more than once: $d"
  done <<< "$dupes"
fi

if (( fail == 0 )); then
  echo "OK:   stage policy sources — $checked check(s) passed, policy $policy_bytes bytes"
fi

exit "$fail"
