#!/usr/bin/env bash
# Pins the witness write discipline of the shared agent-team protocol.
#
#   1. The task-assignment header and the witness-file section prescribe one
#      Bash command per witness write — the publish helper — and the progress
#      checkpoint section prescribes no Bash command: no `mktemp`, `mv` or
#      `mkdir` there, and the helper call appears once in each of the two.
#   2. The protocol keeps none of the older prescription strings.
#   3. In plugins/ and scripts/, every file that still pins or reads an older
#      witness prescription (the temp-file publish, its temp name, the older
#      nonce command, the checkpoint published with a plain `mv`) is one of the
#      files the witness-write change declared. The list is a constant here:
#      when that change's declared files change, change it with them.
#   4. Every place that lists the per-reader or per-checkpoint substitutions
#      carries `{WITNESS_DRAFT}`.

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
cd "$repo_root"

proto=plugins/cc-cmds/skills/_common/agent-team-protocol.md

passed=0
failures=0
ok() { passed=$((passed + 1)); }
bad() { echo "FAIL: $1" >&2; failures=$((failures + 1)); }

# section <start heading> <stop regex> — print the protocol lines from the
# heading up to, not including, the first later line matching the stop regex.
section() {
  awk -v start="$1" -v stop="$2" '
    $0 == start { on = 1; print; next }
    on && $0 ~ stop { exit }
    on { print }
  ' "$proto"
}

header=$(section '## Task-assignment header (embed verbatim)' '^## ')
witness=$(section '## Witness file (member-written, durable, atomic publish)' '^## ')
checkpoint=$(section '### Parameter — progress checkpoint (opt-in)' '^### ')

for v in header witness checkpoint; do
  if [[ -n "${!v}" ]]; then ok; else bad "protocol section not found: $v"; fi
done

publish_call='<plugin root>/orchestrator/cc-team-witness-publish.sh {WITNESS_DRAFT} {WITNESS_PATH}'

# count_fixed <text> <needle> — occurrences of a fixed string.
count_fixed() {
  local text=$1 needle=$2 n=0 rest
  rest=$text
  while [[ "$rest" == *"$needle"* ]]; do
    n=$((n + 1))
    rest=${rest#*"$needle"}
  done
  printf '%s' "$n"
}

# 1. One Bash command per witness write; none per checkpoint.
for v in header witness; do
  n=$(count_fixed "${!v}" "$publish_call")
  if [[ "$n" == 1 ]]; then ok; else bad "$v: the publish helper call appears $n times (want 1)"; fi
done
for v in header checkpoint; do
  if printf '%s\n' "${!v}" | grep -qE '(^|[^A-Za-z_-])(mktemp|mkdir)([^A-Za-z_-]|$)'; then
    bad "$v prescribes mktemp or mkdir: $(printf '%s\n' "${!v}" | grep -nE '(^|[^A-Za-z_-])(mktemp|mkdir)([^A-Za-z_-]|$)' | head -3)"
  else
    ok
  fi
  if printf '%s\n' "${!v}" | grep -qE '(^|[^A-Za-z_.-])mv( |`)'; then
    bad "$v prescribes mv: $(printf '%s\n' "${!v}" | grep -nE '(^|[^A-Za-z_.-])mv( |`)' | head -3)"
  else
    ok
  fi
done
if printf '%s\n' "$witness" | grep -qE 'T=\$\(mktemp|mkdir -p|mv -n "\$T"'; then
  bad "witness section still prescribes a temp-file publish"
else
  ok
fi
if [[ "$header" == *'With the Write tool, write your **entire** round product'* ]]; then ok; else bad "header does not tell the member to write the draft with the Write tool"; fi
if [[ "$checkpoint" == *'Run no Bash command for a checkpoint.'* ]]; then ok; else bad "checkpoint clause does not say that no Bash command is run"; fi
if [[ "$checkpoint" == *'No Bash command is run for a checkpoint.'* ]]; then ok; else bad "checkpoint Write bullet does not say that no Bash command is run"; fi

# 2. No older prescription string anywhere in the protocol.
for s in 'T=$(mktemp' 'mv -n "$T" {WITNESS_PATH}' 'openssl rand -hex 8'; do
  if grep -qF -- "$s" "$proto"; then bad "protocol still carries: $s"; else ok; fi
done

# 3. Older prescriptions live only in the declared files.
declared=(
  plugins/cc-cmds/orchestrator/gate.sh
  scripts/test-gate.sh
  plugins/cc-cmds/orchestrator/cc-team-witness-publish.sh
  plugins/cc-cmds/orchestrator/cc-team-nonce.sh
  plugins/cc-cmds/orchestrator/cc-team-witness-init.sh
  scripts/test-team-witness-init.sh
  scripts/test-team-witness-publish.sh
  plugins/cc-cmds/orchestrator/test-run.sh
  Makefile
  plugins/cc-cmds/skills/_common/agent-team-protocol.md
  plugins/cc-cmds/skills/design/SKILL.md
  plugins/cc-cmds/skills/review/SKILL.md
  plugins/cc-cmds/skills/review-unattended/SKILL.md
  plugins/cc-cmds/skills/review-lite/SKILL.md
  plugins/cc-cmds/skills/review-unattended/references/recovery-arm.md
  plugins/cc-cmds/skills/design-audit/SKILL.md
  plugins/cc-cmds/skills/design-audit-unattended/SKILL.md
  plugins/cc-cmds/skills/design-audit/references/01-reader-prompt.md
  plugins/cc-cmds/orchestrator/collect-run-metrics.sh
  scripts/test-collect-run-metrics.sh
  scripts/lint-checkpoint-round-scope.sh
  scripts/lint-team-budget-pins.sh
  scripts/review-seat-promotion-pair.sh
  scripts/test-review-seat-promotion-pair.sh
  scripts/test-witness-write-exec.sh
  scripts/test-lint-team-budget-pins.sh
  plugins/cc-cmds/hooks/hooks.json
  plugins/cc-cmds/hooks/witness-write-pretool.sh
  plugins/cc-cmds/hooks/README.md
  scripts/test-witness-write-pretool-hook.sh
  scripts/countermeasure-records.md
)
old_witness='openssl rand -hex 8|mv -n "?\$T"? \{?WITNESS_PATH|\.\{role-slug\}\.\{round/phase\}\.XXXXXX|mv -n.*cc-team-witness|witness.*mv -n|mv -n.*witness'
# The checkpoint's older form is its publish sentence, not the `partial` path
# component or the `cc-partial` sentinel, which the current form keeps and
# which unrelated scripts use.
old_checkpoint='publish with plain `?mv`? \(never `?mv -n`?\) at|sibling temp in it and publish with plain|mkdir -p "\$\(dirname \{WITNESS_PATH\}\)/partial"'
hits=$(grep -rlE -- "$old_witness|$old_checkpoint" plugins scripts | sort -u) || hits=''
if [[ -n "$hits" ]]; then ok; else bad "the older-prescription scan found no file at all (this test pins its own patterns, so the scan is broken)"; fi
while IFS= read -r f; do
  [[ -n "$f" ]] || continue
  in=0
  for d in "${declared[@]}"; do
    [[ "$f" == "$d" ]] && { in=1; break; }
  done
  if [[ $in -eq 1 ]]; then ok; else bad "older witness prescription outside the declared files: $f — $(grep -nE -- "$old_witness|$old_checkpoint" "$f" | head -2)"; fi
done <<<"$hits"

# 4. Substitution lists carry {WITNESS_DRAFT}.
# line_has <file> <fixed anchor> — the one line holding the anchor also holds
# {WITNESS_DRAFT}.
line_has() {
  local f=$1 anchor=$2 lines n
  lines=$(grep -F -- "$anchor" "$f") || lines=''
  n=$(printf '%s' "$lines" | grep -c '' || true)
  if [[ "$n" != 1 ]]; then
    bad "$f: anchor found on $n lines (want 1): $anchor"
    return
  fi
  if [[ "$lines" == *'{WITNESS_DRAFT}'* ]]; then ok; else bad "$f: the substitution list at «${anchor}» lacks {WITNESS_DRAFT}"; fi
}
line_has plugins/cc-cmds/skills/design-audit/SKILL.md '**MUST — byte-identical prompts, and one model.**'
line_has plugins/cc-cmds/skills/design-audit-unattended/SKILL.md '**MUST — byte-identical prompts, and one model.**'
line_has plugins/cc-cmds/skills/design-audit/references/01-reader-prompt.md '**MUST — the rendered prompts are byte-identical across readers**'
line_has plugins/cc-cmds/skills/design-audit/references/01-reader-prompt.md '- `{role-slug}`: `reader-<k>`.'
line_has plugins/cc-cmds/skills/design-audit/references/01-reader-prompt.md '**Only `{WITNESS_PATH}`'
line_has "$proto" 'When dispatching or resuming a member, embed this self-contained header'
line_has "$proto" '**Progress checkpoint (MUST — round 1 only)**'
line_has "$proto" '- **Nothing new is minted** — no phase token, no nonce (the witness nonce is reused verbatim, and the draft token'
for f in plugins/cc-cmds/skills/review/SKILL.md plugins/cc-cmds/skills/review-unattended/SKILL.md plugins/cc-cmds/skills/review-lite/SKILL.md; do
  line_has "$f" '**Progress checkpoint — this skill opts in.**'
done
if [[ "$checkpoint" == *'the clause substitutes the same five the header substitutes'* ]]; then ok; else bad "checkpoint section does not say the clause substitutes the header's five values"; fi

echo "witness-write-exec: $passed passed, $failures failed"
[[ $failures -eq 0 ]]
