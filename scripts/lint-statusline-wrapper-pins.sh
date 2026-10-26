#!/usr/bin/env bash
# Pin the status line's wrapper grammar where it is written by hand, and hold the
# shared function set closed.
#
# THE GRAMMAR HAS EXACTLY ONE IMPLEMENTATION AND EXACTLY TWO HAND-WRITTEN COPIES.
# `plugins/cc-cmds/orchestrator/statusline-command.sh` owns it; the hook and the
# installer both source that file rather than restating it, because two
# recognisers that disagree make the hook say "proceed" while the installer
# parks, on every startup, with nothing written anywhere to say so. The one
# licensed copy is `scripts/test-statusline.sh`: a suite that sourced the
# implementation it is testing would turn every comparison into a tautology.
#
# A FILE SET, NOT A COUNT. The number of hand-written lines is already stale the
# moment somebody adds a case, so what is pinned here is WHICH FILES may hold
# one. Check (3) below is the whole of that guarantee.
#
# WHY THE CLOSED FUNCTION SET LIVES IN THIS FILE. The design document names the
# seven shared functions, but this repository does not track `docs/`, so a check
# that read the document would never run in CI. The checkable copy of the closed
# enumeration is therefore the literal list in check (4), matched against the
# `sl_*` definitions in the owning file IN BOTH DIRECTIONS: a function added to
# the file without touching this list is red, and so is a name in this list that
# has left the file. That is also where the boundary between the shared grammar
# and the hook's own derivations is enforced — a hook-only helper that migrated
# into the shared file reddens here.
#
# THE ROOT IS A SEAM, AND THE SEAM IS THE CONTRACT. Without it every run scans
# the real tree, the paired suite's FAIL fixtures all come back rc 0, and the
# fixture that is supposed to demonstrate a broken shared-function set cannot be
# built at all. Fifteen of this repository's eighteen lints take one; the name
# follows `scripts/lint-design-audit-pins.sh`.
#
# Usage:
#   bash scripts/lint-statusline-wrapper-pins.sh
#   STATUSLINE_PINS_ROOT=<dir> bash scripts/lint-statusline-wrapper-pins.sh
#
# Exit codes:
#   0 — all pins intact (or the owning file and the suite are both absent → skip)
#   1 — at least one pin broken

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
root="${STATUSLINE_PINS_ROOT:-$repo_root}"

CMDLIB="$root/plugins/cc-cmds/orchestrator/statusline-command.sh"
SUITE="$root/scripts/test-statusline.sh"
README="$root/README.md"
SELF="$script_dir/lint-statusline-wrapper-pins.sh"

if [[ ! -f "$CMDLIB" && ! -f "$SUITE" ]]; then
  echo "SKIP: neither the shared grammar nor the suite found under $root"
  exit 0
fi

fail=0

# ---------- (1) and (2) — the suite's hand-written copies ---------------------
#
# TWO PRODUCTION RULES MEAN TWO PINS. The recogniser accepts a guarded wrapper
# and a bare call, and pinning only the first lets the second drift away from the
# grammar in silence — the suite would go on passing against its own stale idea
# of what a bare call looks like.

# The guard form's middle, which is the part no path can vary: the closing quote
# of the tested path, the `&&`, and `exec bash` opening the second quote.
GUARD_PIN='\" ] && exec bash \"'

# The bare form's enumeration, carrying every alternative the rule allows —
# quoted, `bash `-prefixed, `sh `-prefixed, `exec `-prefixed, and naked.
BARE_PIN='"\"$OLDSL\"" "bash \"$OLDSL\"" "sh $OLDSL" "exec bash $OLDSL" "$OLDSL"'

if [[ -f "$SUITE" ]]; then
  if ! grep -Fq -- "$GUARD_PIN" "$SUITE"; then
    echo "FAIL: scripts/test-statusline.sh — guard-form pin missing: $GUARD_PIN" >&2
    fail=1
  fi
  if ! grep -Fq -- "$BARE_PIN" "$SUITE"; then
    echo "FAIL: scripts/test-statusline.sh — bare-form pin missing: $BARE_PIN" >&2
    fail=1
  fi
else
  echo "FAIL: the suite is missing but the shared grammar is present: $SUITE" >&2
  fail=1
fi

# ---------- (3) — no third copy anywhere under plugins/ or scripts/ -----------
#
# THE MARKER IS THE GUARD'S JOINT, `] && exec bash`. `exec bash` alone is not
# specific: other scripts in this tree replace their own process with a shell,
# some of them by writing one-line shims named `statusline.sh`. What only a copy
# of this grammar writes is that verb behind a test bracket. This file is
# excluded because the pins above are literally it, and when the seam points at
# a fixture this file is outside the scanned root anyway.

scan_roots=()
[[ -d "$root/plugins" ]] && scan_roots+=("$root/plugins")
[[ -d "$root/scripts" ]] && scan_roots+=("$root/scripts")

if (( ${#scan_roots[@]} > 0 )); then
  while IFS= read -r f; do
    case "$f" in
      "$CMDLIB"|"$SUITE"|"$SELF") continue ;;
    esac
    if grep -Fq -- '] && exec bash' "$f" 2>/dev/null; then
      echo "FAIL: ${f#"$root/"} — a third hand-written copy of the wrapper grammar; source the shared file instead" >&2
      fail=1
    fi
  done < <(find "${scan_roots[@]}" -type f 2>/dev/null | sort)
fi

# ---------- (4) — the shared function set, matched in both directions ---------

SHARED=(
  sl_wrapper_prefix
  sl_unwrap_once
  sl_unwrap
  sl_is_bare_ours
  sl_classify
  sl_desired_command
  sl_render_desired
)

if [[ -f "$CMDLIB" ]]; then
  defined=$(grep -oE '^sl_[A-Za-z0-9_]+\(\)' "$CMDLIB" | sed 's/()$//' | sort -u || true)

  for name in "${SHARED[@]}"; do
    if ! printf '%s\n' "$defined" | grep -Fqx -- "$name"; then
      echo "FAIL: statusline-command.sh — '$name' is on this lint's shared list but is not defined there" >&2
      fail=1
    fi
  done

  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    found=0
    for want in "${SHARED[@]}"; do
      [[ "$name" == "$want" ]] && found=1 && break
    done
    if (( found == 0 )); then
      echo "FAIL: statusline-command.sh — '$name' is defined there but is not on this lint's shared list; add it here or move it to the process that owns it" >&2
      fail=1
    fi
  done <<< "$defined"
else
  echo "FAIL: the shared grammar is missing but the suite is present: $CMDLIB" >&2
  fail=1
fi

# ---------- (5) — README's Uninstall section keeps the snapshots in recovery ---
#
# THE FIRST-WRITE SNAPSHOT IS NOT A WAY TO TURN THE STATUS LINE OFF. Restoring it
# takes back the theme, the model, the approved permissions and the `env` block
# along with the status line, so a reader who arrives wanting the status line
# gone and follows it lands on the worst ending in the section. That is how the
# defect got in the first time, and a decision that only changes prose has no
# other place to be held.
#
# VACUOUSLY GREEN UNTIL THE SECTION EXISTS, which is harmless: the check has
# nothing to be wrong about until somebody writes the lines it reads.

if [[ -f "$README" ]]; then
  uninstall_body=$(awk '
    incap && /^## / { exit }
    /^## Uninstall[[:space:]]*$/ { incap = 1; next }
    incap { print }
  ' "$README")

  current_sub=""
  while IFS= read -r line; do
    case "$line" in
      '### '*) current_sub="$line" ;;
    esac
    case "$line" in
      *'settings.json.orig'*|*'settings.json.prev'*)
        case "$current_sub" in
          *복구*) ;;
          *)
            echo "FAIL: README.md ## Uninstall — a backup slot is named outside the recovery subsection (under '${current_sub:-<no subsection>}'); restoring one is not a way to turn the status line off" >&2
            fail=1
            ;;
        esac
        ;;
    esac
  done <<< "$uninstall_body"
fi

if (( fail == 0 )); then
  echo "OK:   statusline wrapper pins — 2 grammar pins + file-set closure + ${#SHARED[@]} shared functions (both directions) + README Uninstall context"
fi

exit "$fail"
