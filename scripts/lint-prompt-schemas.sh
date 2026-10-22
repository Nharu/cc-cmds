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
#   2. `entry-plan.schema.json` carries the design-tier keys: `design_tier`,
#      `design_tier_judged`, `design_heavy_reasons`, `estimated_files` and
#      `design_tier_rationale` are in both sets, and the `design_tier` and
#      `design_tier_judged` enums are exactly `solo` / `team-4`. The tier is a
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
#   5. `entry-plan.check.jq` reads no key the schema does not define. The
#      checker is run by the kickoff, `check_manifest` and the C4 test section,
#      and a key it misspells reads as null — every assertion on it then
#      passes, silently. So every key the checker names (`$p.<key>`,
#      `has("<key>")`, `.steps`) must be a schema property, and the keys its
#      three assertions rest on must each appear in it.
#   6. `entry-plan.md` judges the tier without a closed list. The sentences of
#      the old closed rule (the risk-indicator list and the more-than-one-target
#      rule) and the retired tier names `lead-solo` and `team-2` are absent, and
#      the graph rule that a `solo` graph carries no audit step is present —
#      the producer states the shape the checker's (c) asserts.
#   7. `entry-plan.schema.json` carries `design_path` in both sets, and its
#      enum is exactly `solo-audit` / `discuss-audit` / `none`. The key names
#      who writes a heavy single document, `manifest_design_skill` branches on
#      it and the checker's (d) asserts on it, so a value cannot appear or
#      vanish without this lint noticing.
#
# Usage:
#   bash scripts/lint-prompt-schemas.sh
#
# Env override:
#   SCHEMA_DIR=<dir>   directory holding *.schema.json, entry-plan.check.jq
#                      and entry-plan.md (fixture runner)
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
  tier_ok=1
  for key in design_tier design_tier_judged design_heavy_reasons estimated_files design_tier_rationale; do
    in_props=$(jq -r --arg k "$key" '(.properties // {}) | has($k)' "$ENTRY")
    in_req=$(jq -r --arg k "$key" '(.required // []) | index($k) != null' "$ENTRY")
    if [[ "$in_props" != "true" ]]; then
      echo "FAIL: $rel — '$key' is missing from .properties" >&2
      tier_ok=0
    fi
    if [[ "$in_req" != "true" ]]; then
      echo "FAIL: $rel — '$key' is missing from .required" >&2
      tier_ok=0
    fi
  done
  for key in design_tier design_tier_judged; do
    tier_enum=$(jq -c --arg k "$key" '.properties[$k].enum // []' "$ENTRY")
    if [[ "$tier_enum" != '["solo","team-4"]' ]]; then
      echo "FAIL: $rel — $key enum must be exactly [\"solo\",\"team-4\"], found $tier_enum" >&2
      tier_ok=0
    fi
  done
  reasons_type=$(jq -r '.properties.design_heavy_reasons.type // ""' "$ENTRY")
  files_type=$(jq -r '.properties.estimated_files.type // ""' "$ENTRY")
  if [[ "$reasons_type" != "array" ]]; then
    echo "FAIL: $rel — design_heavy_reasons must be an array of free sentences, found type '$reasons_type'" >&2
    tier_ok=0
  fi
  if [[ "$files_type" != "integer" ]]; then
    echo "FAIL: $rel — estimated_files must be an integer, found type '$files_type'" >&2
    tier_ok=0
  fi
  if [[ "$tier_ok" == "1" ]]; then
    echo "OK:   $rel — design-tier keys present on both sides, enums pinned"
  else
    fail=1
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

# ---------- Rule 5: the checker reads only keys the schema defines ------------

CHECK="$schema_dir/entry-plan.check.jq"
if [[ -f "$ENTRY" ]] && jq empty "$ENTRY" 2>/dev/null; then
  rel=${CHECK#"$repo_root/"}
  if [[ ! -f "$CHECK" ]]; then
    echo "FAIL: $rel — the entry-plan checker is missing" >&2
    fail=1
  else
    check_ok=1
    # Every top-level key the checker names. Step-level keys (`.skill`) are
    # read through `plan_steps` and are not top-level, so they are not here.
    read_keys=$(
      {
        grep -oE '\$p\.[a-z_]+' "$CHECK" | sed -E 's/^\$p\.//'
        grep -oE 'has\("[a-z_]+"\)' "$CHECK" | sed -E 's/^has\("//; s/"\)$//'
        grep -oE '\.steps\[' "$CHECK" | sed -E 's/^\.//; s/\[$//'
      } | sort -u
    )
    while IFS= read -r k; do
      [[ -n "$k" ]] || continue
      in_props=$(jq -r --arg k "$k" '(.properties // {}) | has($k)' "$ENTRY")
      if [[ "$in_props" != "true" ]]; then
        echo "FAIL: $rel — the checker reads '$k', which entry-plan.schema.json does not define (a misspelt key reads as null and every assertion on it passes)" >&2
        check_ok=0
      fi
    done <<< "$read_keys"
    for k in design_tier_judged design_heavy_reasons design_tier design_required design_scope steps; do
      if ! grep -qxF "$k" <<<"$read_keys"; then
        echo "FAIL: $rel — the checker does not read '$k', on which its assertions rest" >&2
        check_ok=0
      fi
    done
    if [[ "$check_ok" == "1" ]]; then
      echo "OK:   $rel — every key the checker reads is a schema property"
    else
      fail=1
    fi
  fi
fi

# ---------- Rule 6: the entry prompt judges the tier without a closed list ----

PROMPT="$schema_dir/entry-plan.md"
if [[ -f "$PROMPT" ]]; then
  rel=${PROMPT#"$repo_root/"}
  prompt_ok=1
  for gone in 'risk indicators outrank the size row' 'More than one entry in `targets` is also `team-4`' 'lead-solo' 'team-2'; do
    if grep -qF -- "$gone" "$PROMPT"; then
      echo "FAIL: $rel — still carries '$gone' (the tier is judged without a closed list, on solo | team-4)" >&2
      prompt_ok=0
    fi
  done
  if ! grep -qF -- 'a `solo` graph carries no audit step' "$PROMPT"; then
    echo "FAIL: $rel — the graph rule that a \`solo\` graph carries no audit step is missing" >&2
    prompt_ok=0
  fi
  if [[ "$prompt_ok" == "1" ]]; then
    echo "OK:   $rel — no closed tier list, no retired tier, solo graph rule stated"
  else
    fail=1
  fi
fi

# ---------- Rule 7: the design-path key in entry-plan -------------------------

if [[ -f "$ENTRY" ]] && jq empty "$ENTRY" 2>/dev/null; then
  rel=${ENTRY#"$repo_root/"}
  path_ok=1
  in_props=$(jq -r '(.properties // {}) | has("design_path")' "$ENTRY")
  in_req=$(jq -r '(.required // []) | index("design_path") != null' "$ENTRY")
  if [[ "$in_props" != "true" ]]; then
    echo "FAIL: $rel — 'design_path' is missing from .properties" >&2
    path_ok=0
  fi
  if [[ "$in_req" != "true" ]]; then
    echo "FAIL: $rel — 'design_path' is missing from .required" >&2
    path_ok=0
  fi
  path_enum=$(jq -c '.properties.design_path.enum // []' "$ENTRY")
  if [[ "$path_enum" != '["solo-audit","discuss-audit","none"]' ]]; then
    echo "FAIL: $rel — design_path enum must be exactly [\"solo-audit\",\"discuss-audit\",\"none\"], found $path_enum" >&2
    path_ok=0
  fi
  if [[ "$path_ok" == "1" ]]; then
    echo "OK:   $rel — design_path present on both sides, enum pinned"
  else
    fail=1
  fi
fi

if [[ "$fail" != "0" ]]; then
  echo "lint-prompt-schemas: violations found" >&2
  exit 1
fi
exit 0
