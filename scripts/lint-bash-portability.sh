#!/usr/bin/env bash
# lint-bash-portability: self-skip
# Lint shell scripts for BSD/GNU divergent idioms that break across the
# macOS-default Bash and Linux-default Bash. The denylist catches a known
# set of single-platform flags / commands; the enumeration is intentional
# (not exhaustive) and grows when new hits surface.
#
# Background: macOS ships BSD coreutils while Linux ships GNU coreutils.
# Many flags (`date -d` vs `date -j`, `stat -c` vs `stat -f`, `grep -P` vs
# none, etc.) work on one platform and fail on the other. A script that
# uses a single-platform idiom passes lint+test on its native CI leg but
# breaks silently on the other. This lint is the floor coverage; the macOS
# CI runner is the ceiling.
#
# Second axis — the interpreter itself. The shebang does not pin a version:
# `#!/usr/bin/env bash` resolves to 5.x on an interactive PATH and to macOS's
# stock **3.2.57** under a sanitized one (`PATH=/usr/bin:/bin`). A bash-4-only
# builtin therefore behaves worse than a divergent flag — the coreutils rows
# above die in `make lint`, but `wait -n` / `declare -A` / `mapfile` pass lint,
# pass every hand-run test, and die only in the detached run. The rows tagged
# `bash4 *` below close that gap; `setsid` is here for the same reason (the
# binary is simply absent on darwin, though the syscall is not).
#
# Usage:
#   bash scripts/lint-bash-portability.sh                  # lint default file set
#   bash scripts/lint-bash-portability.sh path/to/file.sh  # lint specific files
#
# Env override:
#   SCAN_ROOT=<dir> bash scripts/lint-bash-portability.sh  # test fixture runner
#                                                          # scans *.sh in <dir>
#
# Self-skip sentinel:
#   A file whose first 5 lines contain the literal token
#   `# lint-bash-portability: self-skip` is excluded from scanning. Used by
#   this script and its test fixture runner to avoid recursive lint hits.
#
# Same-line escape comment:
#   A line containing `# lint-bash-portability: disable=<id>` suppresses the
#   matching idiom <id> on that line only (shellcheck convention). Multi-idiom
#   suppression on one line is not supported — split into two lines if needed.
#
# Exit codes:
#   0 — all inputs pass
#   1 — at least one violation found
#   2 — no scannable files found

set -euo pipefail

# Denylist rows: <regex>|<idiom_id>|<advice>
# Regex uses POSIX ERE word boundaries. `\b` matches `$md5` (false positive
# on variable names) — design accepts this as a known limitation: intentional
# use suppresses via the same-line escape comment.
PATTERNS=(
  '\bdate[[:space:]]+-j\b|date -j|BSD-only; portable timestamp arithmetic via date -u +%s or a perl/python shim'
  '\bdate[[:space:]]+-d\b|date -d|GNU-only; portable parsing via date -j -f <fmt> <input> (BSD) or a perl/python shim'
  '\bfind[[:space:]]+-E\b|find -E|BSD-only; portable regex find via -regex (BRE) or pipe through grep -E'
  '\bstat[[:space:]]+-f\b|stat -f|BSD-only; for portable file metadata branch by OS or use wc -c (size)'
  '\bstat[[:space:]]+-c\b|stat -c|GNU-only; mirror of stat -f — branch by OS'
  '\btail[[:space:]]+-r\b|tail -r|BSD-only; portable reverse via awk one-liner or sed pipeline'
  '\btac\b|tac|GNU-only; portable reverse via tail -r (BSD) or awk pipeline'
  '\bxargs[[:space:]]+-r\b|xargs -r|GNU-only; portable --no-run-if-empty semantics via `if [ -n "$x" ]; then ... | xargs ... fi`'
  '\bmd5sum\b|md5sum|GNU-only; portable hash via `openssl md5` or branch by OS'
  '\bmd5\b|md5|BSD-only; portable hash via `openssl md5` or `cksum`'
  '\bgrep[[:space:]]+-P\b|grep -P|GNU-only Perl-compat regex; rewrite as ERE with grep -E or use perl one-liner'
  '\breadlink[[:space:]]+-f\b|readlink -f|GNU-only; portable canonical path via `cd "$(dirname "$f")" && pwd -P`'
  '\bls[[:space:]]+-G\b|ls -G|BSD color flag; for portability drop coloring or branch by OS'
  '\bls[[:space:]]+--color\b|ls --color|GNU color flag; same advice as ls -G'
  '\bsetsid\b|setsid|Linux-only binary, absent on darwin; detach with nohup (SIGHUP immunity) and own the process tree with per-stage `set -m`'
  '\bwait[[:space:]]+-n\b|bash4 wait -n|bash 4+ only (rc=2 on 3.2); poll recorded child pids with `kill -0` instead'
  '\bdeclare[[:space:]]+-A\b|bash4 assoc-array|bash 4+ only (rc=2 on 3.2); use parallel indexed arrays or a key=value line store'
  '\blocal[[:space:]]+-A\b|bash4 assoc-array|bash 4+ only; same advice as declare -A'
  '\bmapfile\b|bash4 mapfile|bash 4+ builtin, absent on 3.2 (rc=127); use `while IFS= read -r` appending to an indexed array'
  '\breadarray\b|bash4 mapfile|bash 4+ alias of mapfile, absent on 3.2; same replacement'
  '\$\{[A-Za-z_][A-Za-z0-9_]*\^\^?\}|bash4 case-expansion|bash 4+ case conversion; use `tr [:lower:] [:upper:]`'
  '\$\{[A-Za-z_][A-Za-z0-9_]*,,?\}|bash4 case-expansion|bash 4+ case conversion; use `tr [:upper:] [:lower:]`'
)
# Quoted-literal idioms that need substring (not word-boundary) matching.
# Patterns that must be matched under the C locale, because what they are about
# is BYTES rather than characters. Kept in their own table so the locale pin is
# scoped to them: under a UTF-8 locale a Korean bracket is `[:punct:]` and the
# rule below would not fire at all.
C_LOCALE_PATTERNS=(
  '\$[A-Za-z_][A-Za-z0-9_]*[^ -~]|var-then-multibyte|bash reads the first byte of the following multibyte character as part of the VARIABLE NAME, so the lookup fails as unbound under set -u; brace it — ${var} — whenever a non-ASCII character follows'
)

LITERAL_PATTERNS=(
  "sed -i ''|sed -i ''|BSD-only single-quoted backup-extension argument; portable: write to tmp + mv, or branch by OS"
  "awk 'gensub(|awk gensub|GNU awk only; portable: use match() + substr() composition"
)

# Resolve scan root + default file list.
script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)

collect_default_files() {
  {
    [[ -d "$repo_root/plugins/cc-cmds/skills/active-notify/scripts" ]] \
      && find "$repo_root/plugins/cc-cmds/skills/active-notify/scripts" -maxdepth 1 -name "*.sh"
    [[ -d "$repo_root/plugins/cc-cmds/hooks" ]] \
      && find "$repo_root/plugins/cc-cmds/hooks" -maxdepth 1 -name "*.sh"
    [[ -d "$repo_root/scripts" ]] \
      && find "$repo_root/scripts" -maxdepth 1 -name "*.sh"
    [[ -d "$repo_root/plugins/cc-cmds/orchestrator" ]] \
      && find "$repo_root/plugins/cc-cmds/orchestrator" -maxdepth 1 -name "*.sh"
  } | sort
}

collect_scan_root_files() {
  find "$SCAN_ROOT" -maxdepth 1 -name "*.sh" | sort
}

FILES=()
if [[ $# -gt 0 ]]; then
  FILES=("$@")
elif [[ -n "${SCAN_ROOT:-}" ]]; then
  while IFS= read -r f; do FILES+=("$f"); done < <(collect_scan_root_files)
else
  while IFS= read -r f; do FILES+=("$f"); done < <(collect_default_files)
fi

if [[ ${#FILES[@]} -eq 0 ]]; then
  echo "lint-bash-portability: no scannable files found" >&2
  exit 2
fi

violation_count=0
violation_files=0
total_files=0

for file in "${FILES[@]}"; do
  total_files=$((total_files + 1))

  if [[ ! -f "$file" ]]; then
    echo "FAIL: $file — file not found" >&2
    violation_count=$((violation_count + 1))
    violation_files=$((violation_files + 1))
    continue
  fi

  # Self-skip sentinel detection: first 5 lines.
  if head -5 "$file" 2>/dev/null | grep -qF "# lint-bash-portability: self-skip"; then
    echo "SKIP: $file (self-skip sentinel)"
    continue
  fi

  file_violations=0
  line_no=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    line_no=$((line_no + 1))

    # Skip comment-only lines (leading whitespace + #).
    case "$line" in
      ''|*[!\ ]*) ;;
    esac
    if printf '%s' "$line" | grep -qE '^[[:space:]]*#'; then
      continue
    fi

    # Strip trailing comment for code analysis, preserve original for
    # disable-comment detection. Naive `#` split is acceptable for our
    # scripts (no `#` inside literal strings in lint scope).
    code_part="${line%%#*}"
    comment_part=""
    if [[ "$line" == *"#"* ]]; then
      comment_part="#${line#*#}"
    fi

    # Regex-anchored idioms.
    for row in "${PATTERNS[@]}"; do
      regex="${row%%|*}"
      rest="${row#*|}"
      idiom_id="${rest%%|*}"
      advice="${rest#*|}"

      if printf '%s' "$code_part" | grep -qE "$regex"; then
        # Check same-line disable comment.
        if printf '%s' "$comment_part" \
            | grep -qF "lint-bash-portability: disable=${idiom_id}"; then
          continue
        fi
        echo "FAIL: BSD/GNU divergent idiom '${idiom_id}' detected in $file:$line_no" >&2
        echo "       advice: ${advice}" >&2
        echo "       see CLAUDE.md \"## macOS-CI escalation triggers\" for context" >&2
        file_violations=$((file_violations + 1))
      fi
    done

    # C-locale byte idioms. The locale is pinned HERE rather than for the whole
    # run: what these match is a byte range, and a UTF-8 locale classifies the
    # very characters at issue as ordinary punctuation.
    for row in "${C_LOCALE_PATTERNS[@]}"; do
      regex="${row%%|*}"
      rest="${row#*|}"
      idiom_id="${rest%%|*}"
      advice="${rest#*|}"

      if printf '%s' "$code_part" | LC_ALL=C grep -qE "$regex"; then
        if printf '%s' "$comment_part" \
            | grep -qF "lint-bash-portability: disable=${idiom_id}"; then
          continue
        fi
        echo "FAIL: BSD/GNU divergent idiom '${idiom_id}' detected in $file:$line_no" >&2
        echo "       advice: ${advice}" >&2
        echo "       see CLAUDE.md \"## macOS-CI escalation triggers\" for context" >&2
        file_violations=$((file_violations + 1))
      fi
    done

    # Literal-substring idioms.
    for row in "${LITERAL_PATTERNS[@]}"; do
      literal="${row%%|*}"
      rest="${row#*|}"
      idiom_id="${rest%%|*}"
      advice="${rest#*|}"

      if [[ "$code_part" == *"$literal"* ]]; then
        if printf '%s' "$comment_part" \
            | grep -qF "lint-bash-portability: disable=${idiom_id}"; then
          continue
        fi
        echo "FAIL: BSD/GNU divergent idiom '${idiom_id}' detected in $file:$line_no" >&2
        echo "       advice: ${advice}" >&2
        echo "       see CLAUDE.md \"## macOS-CI escalation triggers\" for context" >&2
        file_violations=$((file_violations + 1))
      fi
    done
  done < "$file"

  if (( file_violations > 0 )); then
    violation_count=$((violation_count + file_violations))
    violation_files=$((violation_files + 1))
  else
    echo "OK: $file"
  fi
done

if (( violation_count == 0 )); then
  echo "lint-bash-portability: all ${total_files} file(s) passed"
  exit 0
else
  echo "lint-bash-portability: ${violation_count} violation(s) in ${violation_files} file(s)" >&2
  exit 1
fi
