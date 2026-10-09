#!/usr/bin/env bash
# Lint the orchestrator's judgment-call schemas for a half-added field.
#
# Every `prompts/*.schema.json` is a closed object: `additionalProperties` is
# false and every property is listed in `required`. Nothing in the tree
# enforces that shape — the driver and the gate never read these files, and
# the only consumer is the kickoff's own `jq` self-check of the object it
# produced. So a field added to `properties` and not to `required` (or the
# reverse) passes every run and is caught by nobody: the model omits it, the
# self-check accepts the omission, and the downstream reader finds the key
# missing at 3am. This lint is the one mechanical check of that pairing.
#
# Rules:
#   1. For every top-level object with `additionalProperties: false`, the key
#      set of `.properties` equals the set in `.required` — both directions,
#      because each direction is a different silent failure (a required key
#      with no property definition rejects every output; a property with no
#      required entry lets the model drop it).
#   2. `entry-plan.schema.json` carries the design-tier pair: `design_tier`
#      and `design_tier_rationale` are in both sets, and the `design_tier`
#      enum is exactly `lead-solo` / `team-2` / `team-4`. The tier is a
#      configuration parameter of one stage, not a new entry skill, and the
#      enum is pinned so that a value the kickoff hands to the person cannot
#      appear or vanish without this lint noticing.
#   3. `entry-plan.schema.json` carries the work-class pair: `work_class`
#      and `work_class_rationale` are in both sets, and the `work_class`
#      enum is exactly `fix` / `feat` / `docs` / `other` / `unknown`. The
#      recorded value is the key a later reader groups history by, so a value
#      cannot appear or vanish without this lint noticing.
#   4. `entry-plan.schema.json` carries the design-scope pair: `design_scope`
#      and `design_scope_rationale` are in both sets, and the `design_scope`
#      enum is exactly `single` / `base`. The gate, the driver and both
#      routers branch on the value, so a third value would reach none of them.
#
# Usage:
#   bash scripts/lint-prompt-schemas.sh
#
# Env override:
#   SCHEMA_DIR=<dir>   directory holding *.schema.json (fixture runner)
#
# Exit codes:
#   0 — every schema passes
#   1 — at least one violation
#   2 — no schema found under the scan directory (never a verdict)
#
# Compatibility: bash 3.2 (macOS) — no associative arrays, no mapfile.

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
schema_dir="${SCHEMA_DIR:-$repo_root/plugins/cc-cmds/orchestrator/prompts}"

if ! command -v jq >/dev/null 2>&1; then
  echo "lint-prompt-schemas: jq is required" >&2
  exit 2
fi

SCHEMAS=()
while IFS= read -r f; do
  SCHEMAS+=("$f")
done < <(find "$schema_dir" -maxdepth 1 -name '*.schema.json' | sort)

if [[ ${#SCHEMAS[@]} -eq 0 ]]; then
  echo "lint-prompt-schemas: no *.schema.json under $schema_dir" >&2
  exit 2
fi

fail=0

# ---------- Rule 1: properties <-> required, both directions ------------------

for schema in "${SCHEMAS[@]}"; do
  rel=${schema#"$repo_root/"}
  if ! jq empty "$schema" 2>/dev/null; then
    echo "FAIL: $rel — not valid JSON" >&2
    fail=1
    continue
  fi
  closed=$(jq -r 'if .additionalProperties == false then "yes" else "no" end' "$schema")
  if [[ "$closed" != "yes" ]]; then
    echo "OK:   $rel — open object, pairing rule does not apply"
    continue
  fi
  # Keys in `properties` that `required` does not list.
  missing_required=$(jq -r '
    (.properties // {} | keys) as $p
    | (.required // []) as $r
    | $p - $r | .[]' "$schema")
  # Keys in `required` that `properties` does not define.
  missing_property=$(jq -r '
    (.properties // {} | keys) as $p
    | (.required // []) as $r
    | $r - $p | .[]' "$schema")
  if [[ -n "$missing_required" ]]; then
    while IFS= read -r k; do
      [[ -n "$k" ]] || continue
      echo "FAIL: $rel — property '$k' is not in .required (the model may drop it and the self-check accepts that)" >&2
    done <<< "$missing_required"
    fail=1
  fi
  if [[ -n "$missing_property" ]]; then
    while IFS= read -r k; do
      [[ -n "$k" ]] || continue
      echo "FAIL: $rel — required key '$k' has no .properties entry (every output is rejected)" >&2
    done <<< "$missing_property"
    fail=1
  fi
  if [[ -z "$missing_required" && -z "$missing_property" ]]; then
    echo "OK:   $rel — .properties and .required name the same keys"
  fi
done

# ---------- Rule 2: the design-tier pair in entry-plan ------------------------

ENTRY="$schema_dir/entry-plan.schema.json"
if [[ -f "$ENTRY" ]] && jq empty "$ENTRY" 2>/dev/null; then
  rel=${ENTRY#"$repo_root/"}
  for key in design_tier design_tier_rationale; do
    in_props=$(jq -r --arg k "$key" '(.properties // {}) | has($k)' "$ENTRY")
    in_req=$(jq -r --arg k "$key" '(.required // []) | index($k) != null' "$ENTRY")
    if [[ "$in_props" != "true" ]]; then
      echo "FAIL: $rel — '$key' is missing from .properties" >&2
      fail=1
    fi
    if [[ "$in_req" != "true" ]]; then
      echo "FAIL: $rel — '$key' is missing from .required" >&2
      fail=1
    fi
  done
  tier_enum=$(jq -c '.properties.design_tier.enum // []' "$ENTRY")
  if [[ "$tier_enum" != '["lead-solo","team-2","team-4"]' ]]; then
    echo "FAIL: $rel — design_tier enum must be exactly [\"lead-solo\",\"team-2\",\"team-4\"], found $tier_enum" >&2
    fail=1
  else
    echo "OK:   $rel — design_tier pair present on both sides, enum pinned"
  fi
fi

# ---------- Rule 3: the work-class pair in entry-plan -------------------------

if [[ -f "$ENTRY" ]] && jq empty "$ENTRY" 2>/dev/null; then
  rel=${ENTRY#"$repo_root/"}
  class_ok=1
  for key in work_class work_class_rationale; do
    in_props=$(jq -r --arg k "$key" '(.properties // {}) | has($k)' "$ENTRY")
    in_req=$(jq -r --arg k "$key" '(.required // []) | index($k) != null' "$ENTRY")
    if [[ "$in_props" != "true" ]]; then
      echo "FAIL: $rel — '$key' is missing from .properties" >&2
      class_ok=0
    fi
    if [[ "$in_req" != "true" ]]; then
      echo "FAIL: $rel — '$key' is missing from .required" >&2
      class_ok=0
    fi
  done
  class_enum=$(jq -c '.properties.work_class.enum // []' "$ENTRY")
  if [[ "$class_enum" != '["fix","feat","docs","other","unknown"]' ]]; then
    echo "FAIL: $rel — work_class enum must be exactly [\"fix\",\"feat\",\"docs\",\"other\",\"unknown\"], found $class_enum" >&2
    class_ok=0
  fi
  if [[ "$class_ok" == "1" ]]; then
    echo "OK:   $rel — work_class pair present on both sides, enum pinned"
  else
    fail=1
  fi
fi

# ---------- Rule 4: the design-scope pair in entry-plan -----------------------

if [[ -f "$ENTRY" ]] && jq empty "$ENTRY" 2>/dev/null; then
  rel=${ENTRY#"$repo_root/"}
  scope_ok=1
  for key in design_scope design_scope_rationale; do
    in_props=$(jq -r --arg k "$key" '(.properties // {}) | has($k)' "$ENTRY")
    in_req=$(jq -r --arg k "$key" '(.required // []) | index($k) != null' "$ENTRY")
    if [[ "$in_props" != "true" ]]; then
      echo "FAIL: $rel — '$key' is missing from .properties" >&2
      scope_ok=0
    fi
    if [[ "$in_req" != "true" ]]; then
      echo "FAIL: $rel — '$key' is missing from .required" >&2
      scope_ok=0
    fi
  done
  scope_enum=$(jq -c '.properties.design_scope.enum // []' "$ENTRY")
  if [[ "$scope_enum" != '["single","base"]' ]]; then
    echo "FAIL: $rel — design_scope enum must be exactly [\"single\",\"base\"], found $scope_enum" >&2
    scope_ok=0
  fi
  if [[ "$scope_ok" == "1" ]]; then
    echo "OK:   $rel — design_scope pair present on both sides, enum pinned"
  else
    fail=1
  fi
fi

if [[ "$fail" != "0" ]]; then
  echo "lint-prompt-schemas: violations found" >&2
  exit 1
fi
exit 0
