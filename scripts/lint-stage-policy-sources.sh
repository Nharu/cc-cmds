#!/usr/bin/env bash
# Pin what the repository controls about the stage policy.
#
# `plugins/cc-cmds/orchestrator/stage-policy.md` is the English policy the gate
# injects into every unattended stage in place of automatic CLAUDE.md loading.
# It holds only the rules the plugin owns; the person's own rules reach a
# stage as the `# Personal rules` block, verbatim from the bullets they tagged
# in their global instruction file, and nothing in the repository mirrors
# them. `legacy/stage-policy.v6.md` beside it is the frozen policy a host with
# no tagged bullet still gets. This lint checks:
#
#   (i)    both policy files exist and are ASCII apart from tab and newline —
#          the injected block is the cache-stable head of every stage prompt,
#          and a stray non-ASCII byte is the kind of edit that goes unnoticed;
#   (ii)   both are at most `MAX_BYTES` (8192) bytes — the policy rides on
#          every request of every stage and every team member;
#   (iii)  the policy carries no volatile token (a date, a `run-<n>`, a
#          `/Users/` path) — one would make the bytes differ per host or per
#          run and break the shared cache head;
#   (iv)   the two sentences the team-delivery contract rests on each appear
#          on exactly one line of the current policy: the harness delivers the
#          policy, the personal rules and the repository instructions to
#          Agent-tool members (so leads must not paste them), and a team the
#          stage skill prescribes is itself the instruction to spawn it (so the
#          delegation rule cannot be read as "review alone").
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
LEGACY="$policy_root/legacy/stage-policy.v6.md"
# Raised from 8000 when the delegation, re-read and repository-instruction
# sentences were rewritten for the member prefix: the rule is to measure after
# an edit and raise the ceiling to 8192 rather than cut a safety sentence to
# fit, and a policy past 8192 is a stop, not a further raise.
MAX_BYTES=8192
PIN_HARNESS='Agents spawned with the Agent tool receive this policy, the personal rules and the repository instructions from the harness (the target repository'"'"'s own files by path); do not paste them.'
PIN_TEAM='a team the stage skill prescribes is itself the instruction to spawn it'

fail=0
checked=0

failf() { echo "FAIL: $*" >&2; fail=1; }

# ---------- (i) both files exist, ASCII only ---------------------------------

for f in "$POLICY" "$LEGACY"; do
  checked=$((checked + 1))
  if [[ ! -f "$f" ]]; then
    failf "${f#"$policy_root"/} not found: $f"
  fi
done
if (( fail == 1 )); then
  exit 1
fi

for f in "$POLICY" "$LEGACY"; do
  # CAPTURED, NOT `grep -q`: an early-exiting reader kills the writer with
  # SIGPIPE and `pipefail` then reports the pipeline as failed even on a match.
  non_ascii=$(LC_ALL=C grep -c -a -E '[^	 -~]' "$f" || true)
  if [[ "${non_ascii:-0}" != "0" ]]; then
    failf "${f#"$policy_root"/} — $non_ascii line(s) carry a byte outside printable ASCII, tab and newline"
  fi
done

# ---------- (ii) size --------------------------------------------------------

for f in "$POLICY" "$LEGACY"; do
  checked=$((checked + 1))
  bytes=$(wc -c < "$f" | tr -d ' ')
  if (( bytes > MAX_BYTES )); then
    failf "${f#"$policy_root"/} — $bytes bytes exceeds the $MAX_BYTES-byte ceiling"
  fi
done
policy_bytes=$(wc -c < "$POLICY" | tr -d ' ')
legacy_bytes=$(wc -c < "$LEGACY" | tr -d ' ')

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

if (( fail == 0 )); then
  echo "OK:   stage policy — $checked check(s) passed, policy $policy_bytes bytes, legacy v6 $legacy_bytes bytes"
fi

exit "$fail"
