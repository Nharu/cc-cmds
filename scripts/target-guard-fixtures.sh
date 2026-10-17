#!/usr/bin/env bash
# target-guard-fixtures.sh — target repositories that carry their own PreToolUse
# Bash guard, for the suites that check how the run's hook lives beside one.
#
# WHY A SHARED FILE. The run hook, the gate's admit path and the kickoff check
# all have to be held against the same guards, and a guard written per suite is
# where two suites end up asserting against two different rules under one name.
#
# WHY A SCRIPT WRITES THE SETTINGS. A stage of a run cannot write a target's
# `.claude/settings.json` with the Write tool, so the fixture repositories are
# made by the suite at run time, never checked in.
#
# The six guards:
#   guard_b0.py        the B0 rule quoted in issue #1291 (`mentions_git_surface`)
#                      with a quote-aware split, plus the sentence rules quoted
#                      with it — `gh pr merge` with `--admin`, `--auto` or
#                      `--delete-branch`, and a `gh api` write to a git ref —
#                      refusing with exit 2 and the reason on stderr
#   guard_b0_naive.py  the same rules over a naive blank split
#   guard_words.sh     refuses `merge`, `create` or `push` in a segment whose head
#                      is neither git nor gh, with a JSON deny — not B0, and a
#                      shape the bare form gets past
#   guard_nopush.sh    refuses `push` in any form — no shape gets past it
#   guard_outside.sh   refuses any word naming a path outside
#                      `$CLAUDE_PROJECT_DIR` — the gate's own path included
#   guard_defer.sh     answers a bare `git push` with a JSON `defer`
#
# This file is sourced, not executed. It defines functions and touches nothing
# until one is called.
#
# Compatibility: bash 3.2 — no associative arrays, no `mapfile`.

tgf_write_guard() {
  # tgf_write_guard <dir> <guard name> — writes the guard script to
  # `<dir>/.claude/hooks/<guard name>`.
  local d="$1/.claude/hooks" g="$2"
  mkdir -p "$d"
  case "$g" in
    guard_b0.py|guard_b0_naive.py)
      local split=shlex
      [ "$g" = guard_b0_naive.py ] && split=naive
      cat >"$d/$g" <<EOF
import json, re, shlex, sys

SPLIT = "$split"

def words(seg):
    if SPLIT == "naive":
        return seg.split()
    try:
        return shlex.split(seg)
    except ValueError:
        return seg.split()

def mentions_git_surface(cmd):
    for seg in re.split(r"&&|\|\||;|\|", cmd):
        toks = words(seg)
        if not toks:
            continue
        if toks[0] in ("git", "gh"):
            continue
        if "gh" in toks or ("git" in toks and "push" in toks):
            return True
    return False

def sentence_rule(cmd):
    for seg in re.split(r"&&|\|\||;|\|", cmd):
        toks = words(seg)
        if len(toks) >= 3 and toks[:3] == ["gh", "pr", "merge"]:
            for flag in ("--admin", "--auto", "--delete-branch"):
                if flag in toks:
                    return "gh pr merge " + flag + " is not allowed in this repository"
        if len(toks) >= 2 and toks[:2] == ["gh", "api"]:
            method = None
            for i, t in enumerate(toks):
                if t in ("-X", "--method") and i + 1 < len(toks):
                    method = toks[i + 1].upper()
                elif t.startswith("--method="):
                    method = t.split("=", 1)[1].upper()
            if method in ("POST", "PATCH", "DELETE") and any("/git/refs" in t for t in toks):
                return "gh api writes to git refs are not allowed in this repository"
    return None

def main():
    data = json.load(sys.stdin)
    if data.get("tool_name") != "Bash":
        return 0
    cmd = (data.get("tool_input") or {}).get("command") or ""
    if mentions_git_surface(cmd):
        sys.stderr.write("git and gh must be run directly, not through another program\n")
        return 2
    why = sentence_rule(cmd)
    if why:
        sys.stderr.write(why + "\n")
        return 2
    return 0

sys.exit(main())
EOF
      ;;
    guard_words.sh)
      cat >"$d/$g" <<'EOF'
#!/usr/bin/env bash
cmd=$(jq -r '.tool_input.command // empty')
printf '%s\n' "$cmd" | awk '{ gsub(/&&|\|\||;|\|/, "\n"); print }' | while IFS= read -r seg; do
  set -f
  # shellcheck disable=SC2086
  set -- $seg
  set +f
  [ $# -gt 0 ] || continue
  case "$1" in git|gh) continue ;; esac
  for w in "$@"; do
    w=$(printf '%s' "$w" | tr -d "\"'")
    case "$w" in merge|create|push)
      printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"the word %s may only follow git or gh"}}\n' "$w"
      break 2 ;;
    esac
  done
done | head -n 1
exit 0
EOF
      ;;
    guard_nopush.sh)
      cat >"$d/$g" <<'EOF'
#!/usr/bin/env bash
cmd=$(jq -r '.tool_input.command // empty')
case " $(printf '%s' "$cmd" | tr -c 'A-Za-z0-9_-' ' ') " in
  *' push '*) echo "pushing is not allowed from this repository" >&2; exit 2 ;;
esac
exit 0
EOF
      ;;
    guard_outside.sh)
      cat >"$d/$g" <<'EOF'
#!/usr/bin/env bash
cmd=$(jq -r '.tool_input.command // empty')
root=$(cd "${CLAUDE_PROJECT_DIR:-.}" && pwd -P)
set -f
for w in $cmd; do
  w=$(printf '%s' "$w" | tr -d "\"'")
  case "$w" in
    /*) case "$w" in "$root"|"$root"/*) ;; *) echo "path outside the project: $w" >&2; exit 2 ;; esac ;;
  esac
done
exit 0
EOF
      ;;
    guard_defer.sh)
      cat >"$d/$g" <<'EOF'
#!/usr/bin/env bash
cmd=$(jq -r '.tool_input.command // empty')
case "$cmd" in
  'git push'|'git push '*)
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"defer"}}\n' ;;
esac
exit 0
EOF
      ;;
    *) echo "tgf_write_guard: unknown guard $g" >&2; return 2 ;;
  esac
}

tgf_hook_command() {
  # tgf_hook_command <guard name> — the hook command string the settings carry.
  case "$1" in
    *.py) printf 'python3 -I "$CLAUDE_PROJECT_DIR/.claude/hooks/%s"' "$1" ;;
    *)    printf 'bash "$CLAUDE_PROJECT_DIR/.claude/hooks/%s"' "$1" ;;
  esac
}

tgf_install() {
  # tgf_install <dir> <guard name> [settings.json|settings.local.json] — writes
  # the guard and a settings file whose PreToolUse block (matcher `Bash`) runs
  # it. The default is the tracked `settings.json`.
  local dir="$1" g="$2" which="${3:-settings.json}"
  tgf_write_guard "$dir" "$g" || return
  mkdir -p "$dir/.claude"
  jq -n --arg c "$(tgf_hook_command "$g")" \
    '{hooks:{PreToolUse:[{matcher:"Bash", hooks:[{type:"command", command:$c}]}]}}' \
    >"$dir/.claude/$which"
}

tgf_install_local() {
  # tgf_install_local <dir> <guard name> — the same in `settings.local.json`.
  tgf_install "$1" "$2" settings.local.json
}

tgf_repo() {
  # tgf_repo <dir> [<guard name> [settings file]] — a git repository with one
  # commit on `master`, and the guard when one is named. The guard files are
  # written after the commit and stay untracked, as a person's local guard
  # would; the settings file is committed when it is `settings.json`.
  local dir="$1"
  mkdir -p "$dir"
  ( cd "$dir" && git init -q -b master . && git config user.email fx@example.invalid \
      && git config user.name fx && printf 'fixture\n' >README && git add README \
      && git commit -q -m init ) || return
  if [ -n "${2:-}" ]; then
    tgf_install "$dir" "$2" "${3:-settings.json}" || return
    if [ "${3:-settings.json}" = settings.json ]; then
      # `-f`: a person's global ignore file often names `.claude`, and the
      # fixture must not depend on whose machine runs the suite.
      ( cd "$dir" && git add -f .claude/settings.json && git commit -q -m guard ) || return
    fi
  fi
}
