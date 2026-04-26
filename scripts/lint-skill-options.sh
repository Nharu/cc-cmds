#!/usr/bin/env bash
# Lint SKILL.md frontmatter for the README options-rendering schema.
#
# Rules:
#   1  usage non-empty; options key present                          [fail]
#   2  options: [] ⇒ notes required                                  [fail]
#   3  Kind/field exclusivity matrix                                 [fail]
#   4  safety: true ⇒ safety_summary length ≥ 4 + each non-empty     [fail]
#   5  noop: true ⇒ safety absent/false                              [fail]
#   6  safety_summary[i] is single-line (no `\n` after deserialize)  [fail]
#   7  variants: label + behavior required; example missing → warn
#      (label == "(생략)" exempt from example warn)                  [fail/warn]
#   8  Within a skill: option `name` unique, variant `label` unique  [fail]
#
# Usage:
#   bash scripts/lint-skill-options.sh                  # lint all plugin skills
#   bash scripts/lint-skill-options.sh path/to/SKILL.md [more.md ...]
#
# Exit codes:
#   0 — no failures (warnings allowed)
#   1 — at least one failure
#   2 — invalid invocation
#
# Compatibility: bash 3.2 (macOS) — no associative arrays, no `mapfile`.

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)

# shellcheck source=./_yq-preflight.sh
source "$script_dir/_yq-preflight.sh"
yq_preflight

# ---------- Globals -----------------------------------------------------------

fail_count=0
warn_count=0

# ---------- yq helpers --------------------------------------------------------

fm() {
  local file="$1" expr="$2"
  yq eval "$expr" --front-matter=extract "$file"
}

has_key() {
  local file="$1" key="$2"
  fm "$file" "has(\"$key\")"
}

trim() {
  printf '%s' "$1" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//'
}

# ---------- Lint per file -----------------------------------------------------

# Use sentinel separator to capture errors/warnings without arrays.
SEP=$'\x1f'

emit_err() { printf '%s%s' "$1" "$SEP"; }
emit_warn() { printf '%s%s' "$1" "$SEP"; }

lint_file() {
  local file="$1"

  if [[ ! -f "$file" ]]; then
    echo "FAIL: $file — file not found" >&2
    fail_count=$((fail_count + 1))
    return
  fi

  local errors=""
  local warnings=""

  # Rule 1 — usage non-empty + options key present
  local usage has_opts
  usage=$(fm "$file" '.usage // ""')
  usage=$(trim "$usage")
  has_opts=$(has_key "$file" "options")

  if [[ -z "$usage" ]]; then
    errors+="Rule 1: \`usage\` is missing or empty${SEP}"
  fi
  if [[ "$has_opts" != "true" ]]; then
    errors+="Rule 1: \`options\` key is missing${SEP}"
  fi

  # Rule 2 — options: [] ⇒ notes required
  if [[ "$has_opts" == "true" ]]; then
    local opts_len notes
    opts_len=$(fm "$file" '.options | length // 0')
    notes=$(fm "$file" '.notes // ""')
    notes=$(trim "$notes")
    if [[ "$opts_len" == "0" && -z "$notes" ]]; then
      errors+="Rule 2: \`options: []\` requires non-empty \`notes\`${SEP}"
    fi
  fi

  # Per-option Rules (3, 4, 5, 6, 7, 8)
  if [[ "$has_opts" == "true" ]]; then
    local opts_len i
    opts_len=$(fm "$file" '.options | length // 0')

    # Rule 8 — option name uniqueness via yq
    local dup_names
    dup_names=$(fm "$file" '[.options[].name] | group_by(.) | map(select(length > 1) | .[0]) | join(", ")')
    if [[ -n "$dup_names" ]]; then
      errors+="Rule 8: duplicate option name(s): $dup_names${SEP}"
    fi

    for ((i = 0; i < opts_len; i++)); do
      local oname kind
      oname=$(fm "$file" ".options[${i}].name // \"\"")
      kind=$(fm "$file" ".options[${i}].kind // \"\"")

      # Rule 3 — kind/field exclusivity
      local has_required has_default has_noop has_safety has_safety_summary has_variants has_summary
      has_required=$(fm "$file" ".options[${i}] | has(\"required\")")
      has_default=$(fm "$file" ".options[${i}] | has(\"default\")")
      has_noop=$(fm "$file" ".options[${i}] | has(\"noop\")")
      has_safety=$(fm "$file" ".options[${i}] | has(\"safety\")")
      has_safety_summary=$(fm "$file" ".options[${i}] | has(\"safety_summary\")")
      has_variants=$(fm "$file" ".options[${i}] | has(\"variants\")")
      has_summary=$(fm "$file" ".options[${i}] | has(\"summary\")")

      if [[ -z "$oname" ]]; then
        errors+="Rule 3: option[$i] missing \`name\`${SEP}"
      fi
      if [[ "$has_summary" != "true" ]]; then
        errors+="Rule 3: option[$i] (\`$oname\`) missing \`summary\`${SEP}"
      fi

      case "$kind" in
        positional)
          [[ "$has_required" == "true" ]] || errors+="Rule 3: positional \`$oname\` missing \`required\`${SEP}"
          [[ "$has_default" == "true" ]] && errors+="Rule 3: positional \`$oname\` must not have \`default\`${SEP}"
          [[ "$has_noop" == "true" ]] && errors+="Rule 3: positional \`$oname\` must not have \`noop\`${SEP}"
          [[ "$has_safety" == "true" ]] && errors+="Rule 3: positional \`$oname\` must not have \`safety\`${SEP}"
          [[ "$has_safety_summary" == "true" ]] && errors+="Rule 3: positional \`$oname\` must not have \`safety_summary\`${SEP}"
          ;;
        flag)
          [[ "$has_default" == "true" ]] || errors+="Rule 3: flag \`$oname\` missing \`default\`${SEP}"
          [[ "$has_required" == "true" ]] && errors+="Rule 3: flag \`$oname\` must not have \`required\`${SEP}"
          [[ "$has_variants" == "true" ]] && errors+="Rule 3: flag \`$oname\` must not have \`variants\`${SEP}"
          ;;
        *)
          errors+="Rule 3: option \`$oname\` has invalid kind \`$kind\` (must be 'positional' or 'flag')${SEP}"
          ;;
      esac

      # Rule 5 — noop: true ⇒ safety absent/false
      if [[ "$has_noop" == "true" && "$has_safety" == "true" ]]; then
        local noop_v safety_v
        noop_v=$(fm "$file" ".options[${i}].noop // false")
        safety_v=$(fm "$file" ".options[${i}].safety // false")
        if [[ "$noop_v" == "true" && "$safety_v" == "true" ]]; then
          errors+="Rule 5: option \`$oname\` cannot have both \`noop: true\` and \`safety: true\`${SEP}"
        fi
      fi

      # Rule 4 — safety: true ⇒ safety_summary present, length ≥ 4, all non-empty
      if [[ "$has_safety" == "true" ]]; then
        local safety_v
        safety_v=$(fm "$file" ".options[${i}].safety // false")
        if [[ "$safety_v" == "true" ]]; then
          if [[ "$has_safety_summary" != "true" ]]; then
            errors+="Rule 4: option \`$oname\` has \`safety: true\` but no \`safety_summary\`${SEP}"
          else
            local ss_len
            ss_len=$(fm "$file" ".options[${i}].safety_summary | length // 0")
            if (( ss_len < 4 )); then
              errors+="Rule 4: option \`$oname\` \`safety_summary\` length=$ss_len, must be ≥ 4${SEP}"
            fi
            local si
            for ((si = 0; si < ss_len; si++)); do
              local item item_t
              item=$(fm "$file" ".options[${i}].safety_summary[${si}] // \"\"")
              item_t=$(trim "$item")
              if [[ -z "$item_t" ]]; then
                errors+="Rule 4: option \`$oname\` \`safety_summary[$si]\` is empty${SEP}"
              fi
              # Rule 6a — safety_summary[i] must be single-line
              if [[ "$item" == *$'\n'* ]]; then
                errors+="Rule 6: option \`$oname\` \`safety_summary[$si]\` contains newlines (must be single-line)${SEP}"
              fi
            done
          fi
        fi
      fi

      # Rule 7 — variants
      if [[ "$has_variants" == "true" ]]; then
        local v_len vi
        v_len=$(fm "$file" ".options[${i}].variants | length // 0")

        # Rule 8 — variant label uniqueness via yq
        local dup_labels
        dup_labels=$(fm "$file" "[.options[${i}].variants[].label] | group_by(.) | map(select(length > 1) | .[0]) | join(\", \")")
        if [[ -n "$dup_labels" ]]; then
          errors+="Rule 8: option \`$oname\` has duplicate variant label(s): $dup_labels${SEP}"
        fi

        for ((vi = 0; vi < v_len; vi++)); do
          local label behavior has_example example
          label=$(fm "$file" ".options[${i}].variants[${vi}].label // \"\"")
          behavior=$(fm "$file" ".options[${i}].variants[${vi}].behavior // \"\"")
          has_example=$(fm "$file" ".options[${i}].variants[${vi}] | has(\"example\")")
          example=$(fm "$file" ".options[${i}].variants[${vi}].example // \"\"")
          local label_t behavior_t
          label_t=$(trim "$label")
          behavior_t=$(trim "$behavior")
          if [[ -z "$label_t" ]]; then
            errors+="Rule 7: option \`$oname\` variant[$vi] missing \`label\`${SEP}"
          fi
          if [[ -z "$behavior_t" ]]; then
            errors+="Rule 7: option \`$oname\` variant[$vi] (\`$label\`) missing \`behavior\`${SEP}"
          fi
          if [[ "$has_example" != "true" || -z "$example" ]]; then
            if [[ "$label" != "(생략)" ]]; then
              warnings+="Rule 7 (warn): option \`$oname\` variant \`$label\` missing \`example\`${SEP}"
            fi
          fi
        done
      fi
    done
  fi

  if [[ -z "$errors" && -z "$warnings" ]]; then
    echo "OK:   $file"
    return
  fi

  # Emit warnings
  if [[ -n "$warnings" ]]; then
    local w
    while IFS= read -r w; do
      [[ -z "$w" ]] && continue
      echo "WARN: $file — $w" >&2
      warn_count=$((warn_count + 1))
    done <<< "$(printf '%s' "$warnings" | tr "$SEP" '\n')"
  fi

  # Emit errors
  if [[ -n "$errors" ]]; then
    local e
    while IFS= read -r e; do
      [[ -z "$e" ]] && continue
      echo "FAIL: $file — $e" >&2
      fail_count=$((fail_count + 1))
    done <<< "$(printf '%s' "$errors" | tr "$SEP" '\n')"
  fi
}

# ---------- Collect inputs ----------------------------------------------------

if [[ $# -eq 0 ]]; then
  FILES=()
  while IFS= read -r line; do
    FILES+=("$line")
  done < <(find "$repo_root/plugins/cc-cmds/skills" \
                -mindepth 2 -maxdepth 2 -name SKILL.md | sort)
else
  FILES=("$@")
fi

if [[ ${#FILES[@]} -eq 0 ]]; then
  echo "lint-skill-options: no SKILL.md files to check" >&2
  exit 2
fi

for f in "${FILES[@]}"; do
  lint_file "$f"
done

if (( fail_count > 0 )); then
  echo "lint-skill-options: $fail_count failure(s), $warn_count warning(s)" >&2
  exit 1
fi

if (( warn_count > 0 )); then
  echo "lint-skill-options: 0 failures, $warn_count warning(s)"
fi

exit 0
