#!/usr/bin/env bash
#
# cc-team-witness-init.sh — mint one team's witness directory, as ONE act.
#
# The agent-team protocol needs three assignments and a stamp before any member
# is spawned: a root that prefers the driver's run directory, a sanitized stage
# tag, an `mktemp -d` under that root, and the raw stage id written into
# `.attempt` inside the directory it just made. Every one of those depends on
# the value the line before it produced.
#
# WHY THIS IS A SCRIPT AND NOT FOUR LINES OF PROSE. Shell state does not survive
# between Bash calls, so a lead running the four lines one call at a time loses
# `WITNESS_DIR` before it can stamp `.attempt` — and a lead that runs only the
# `mktemp` line drops the attempt discriminator without anything saying so. The
# prose therefore had to demand all four in a single call, and a single call of
# four statements is `bash -c`.
#
# That demand collided with the adjudication gate. The gate grades an act by the
# basename of its argv0, and `bash` is graded a worktree write unconditionally,
# with no inspection of what it wraps. The real effect here is an out-of-tree
# `mktemp -d` — nothing under the worktree is touched — so the honest surface is
# the out-of-tree one, and the gate compares the declared surface against the
# graded one by strict string equality. An honest declaration is refused
# identically to a dishonest one, leaving the caller a choice between declaring
# an effect that does not happen and not running at all.
#
# A script has a name of its own, so it takes a grade of its own, and the row
# the gate carries for it says what this actually does. The four statements stop
# being a contract the caller must execute perfectly and become an
# implementation detail of one command.
#
# Usage:  <plugin root>/orchestrator/cc-team-witness-init.sh <slug>
#
# INVOKED DIRECTLY, NEVER AS `bash <this script>`. The whole point of the file
# is that the gate sees this name as argv0; putting an interpreter in front puts
# `bash` there instead and reproduces exactly the grade this exists to avoid.
# The file therefore ships mode 755 with the shebang above, and a change that
# clears the executable bit silently re-opens the defect.
#
# THIS COMMENT IS NOT WHERE THAT RULE LIVES, because a header is read only after
# someone has already typed the wrong thing. The prohibition is stated at the
# four places a caller actually reads — the team protocol's Spawn section and
# the three review skills' witness bullets — and it is stated there against a
# pull, since the two other places in this plugin that run an orchestrator
# script from skill prose both write `bash <path>`. Do not delete it from those
# four on the grounds that it is written here.
#
# Prints the created directory to stdout and nothing else, so the caller can
# record the printed path literally. Diagnostics go to stderr.
#
# Environment:
#   CC_PIPELINE_RUN_DIR    — witness root when set; the system temp dir else.
#   CC_PIPELINE_STAGE_ID   — stage id. Sanitized into the directory name, and
#                            written raw into `.attempt`. Absent under an
#                            interactive run, in which case the name carries no
#                            tag and no `.attempt` is written — there is no
#                            attempt to discriminate.

set -euo pipefail

slug=${1:-}
if [ -z "$slug" ]; then
  printf 'cc-team-witness-init.sh: 슬러그가 없습니다 — 사용법: %s <slug>\n' "$0" >&2
  exit 2
fi

# The slug reaches an `mktemp` template, where a `/` would silently redirect the
# directory into a subtree that may not exist and a `%` or a space would make
# the template something other than the name the ledger is about to record. It
# is sanitized on the same character class as the stage tag rather than a
# narrower one, so both halves of the name are normalized the same way.
slug=$(printf '%s' "$slug" | tr -c 'A-Za-z0-9._-' '-')

# The trailing slash is stripped because the printed path is not just displayed
# — the caller records it verbatim as `scratchDir`, and the cleanup procedure
# feeds that recorded string to a path-guarded `rm -rf`. macOS exports a
# `TMPDIR` that ends in a slash, so the doubled separator is the ordinary
# interactive path rather than an edge case, and an implementer who normalizes
# it later is normalizing the input of a destructive command — which is the one
# branch that procedure forbids. Normalize once, here, where it is only a
# string.
WITNESS_ROOT="${CC_PIPELINE_RUN_DIR:-${TMPDIR:-/tmp}}"
WITNESS_ROOT="${WITNESS_ROOT%/}"
# The root is an environment value, so the stdout contract — exactly one line,
# and that line is the directory — rests on it until it is checked. An empty or
# non-directory root makes `mktemp` fail with its own message on stderr and this
# script exit non-zero, which is survivable; what is not survivable is the
# caller recording whatever came back and the cleanup procedure later feeding
# that string to a path-guarded `rm -rf`. Refuse here, where it is still only a
# string, and say which variable produced it.
if [ -z "$WITNESS_ROOT" ] || [ ! -d "$WITNESS_ROOT" ]; then
  printf 'cc-team-witness-init.sh: 위트니스 루트가 디렉터리가 아닙니다: %s (CC_PIPELINE_RUN_DIR 또는 TMPDIR 를 확인하세요)\n' \
    "${WITNESS_ROOT:-(빈 값)}" >&2
  exit 2
fi
STAGE_TAG=$(printf '%s' "${CC_PIPELINE_STAGE_ID:-}" | tr -c 'A-Za-z0-9._-' '-')
WITNESS_DIR=$(mktemp -d "${WITNESS_ROOT}/cc-team-witness-${slug}${STAGE_TAG:+.${STAGE_TAG}}.XXXXXX")

if [ -n "${CC_PIPELINE_STAGE_ID:-}" ]; then
  printf '%s\n' "$CC_PIPELINE_STAGE_ID" > "${WITNESS_DIR}/.attempt"
fi

printf '%s\n' "$WITNESS_DIR"
