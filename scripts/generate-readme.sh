#!/usr/bin/env bash
# Regenerate the Commands table and Options block in README.md from each
# SKILL.md's YAML frontmatter.
#
# Contract:
#   - Inputs: $SKILLS_DIR/<name>/SKILL.md (excludes _common/)
#   - Parses YAML frontmatter via mikefarah/yq:
#       name, description, when_to_use     → SKILLS_TABLE block
#       usage, options[], notes             → SKILLS_OPTIONS block
#   - Two splice passes against $README_PATH between marker pairs:
#       <!-- SKILLS_TABLE_START -->   ... <!-- SKILLS_TABLE_END -->
#       <!-- SKILLS_OPTIONS_START --> ... <!-- SKILLS_OPTIONS_END -->
#   - Each pass is independently idempotent; running twice produces byte-
#     identical output.
#
# Skill order (both blocks):
#   alphabetical by basename of skill directory.
# Within a skill, Options section sorts options:
#   1) kind: positional first, then kind: flag
#   2) within same kind, required: true first
#   3) otherwise YAML author order is preserved
# This keeps README diffs deterministic regardless of YAML field reordering.
#
# Empty render: when no skill defines `usage`/`options`, the SKILLS_OPTIONS
# block emits a single placeholder comment line. The block is still spliced
# (idempotent), `make check` passes, and the section becomes populated as
# skills migrate frontmatter in subsequent PRs.
#
# Environment overrides (used by tests):
#   SKILLS_DIR     — directory containing skill subdirectories (default: repo plugins path)
#   README_PATH    — README to splice (default: repo README.md)
#
# CI integration: `make readme && git diff --exit-code README.md` blocks drift.

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)

# shellcheck source=./_yq-preflight.sh
source "$script_dir/_yq-preflight.sh"
yq_preflight

readme="${README_PATH:-$repo_root/README.md}"
skills_dir="${SKILLS_DIR:-$repo_root/plugins/cc-cmds/skills}"

if [[ ! -f "$readme" ]]; then
  echo "generate-readme: $readme not found" >&2
  exit 1
fi

# ---------- Frontmatter helpers (yq) ------------------------------------------
# Parse a top-level scalar field from a SKILL.md frontmatter.
# Returns empty string if the key is missing or null.
frontmatter_field() {
  local file="$1" field="$2"
  yq eval ".${field} // \"\"" --front-matter=extract "$file"
}

# Returns "true" if `options` key exists in the frontmatter (even when [] or null).
has_options_key() {
  local file="$1"
  yq eval 'has("options")' --front-matter=extract "$file"
}

options_length() {
  local file="$1"
  yq eval '.options | length // 0' --front-matter=extract "$file"
}

option_field() {
  local file="$1" idx="$2" field="$3"
  yq eval ".options[${idx}].${field} // \"\"" --front-matter=extract "$file"
}

option_has_field() {
  local file="$1" idx="$2" field="$3"
  yq eval ".options[${idx}] | has(\"${field}\")" --front-matter=extract "$file"
}

option_bool() {
  local file="$1" idx="$2" field="$3"
  yq eval ".options[${idx}].${field} // false" --front-matter=extract "$file"
}

variants_length() {
  local file="$1" idx="$2"
  yq eval ".options[${idx}].variants | length // 0" --front-matter=extract "$file"
}

variant_field() {
  local file="$1" oi="$2" vi="$3" field="$4"
  yq eval ".options[${oi}].variants[${vi}].${field} // \"\"" --front-matter=extract "$file"
}

variant_has_field() {
  local file="$1" oi="$2" vi="$3" field="$4"
  yq eval ".options[${oi}].variants[${vi}] | has(\"${field}\")" --front-matter=extract "$file"
}

safety_summary_length() {
  local file="$1" idx="$2"
  yq eval ".options[${idx}].safety_summary | length // 0" --front-matter=extract "$file"
}

safety_summary_item() {
  local file="$1" oi="$2" si="$3"
  yq eval ".options[${oi}].safety_summary[${si}] // \"\"" --front-matter=extract "$file"
}

# Collapse a multiline string to single line by replacing internal newlines with
# a single space. Used in pipe-table cells and variant bullets, never in standalone
# blockquotes (notes / parse_note keep their original newlines).
collapse_lines() {
  local s="$1"
  printf '%s' "$s" | tr '\n' ' ' | sed 's/  */ /g; s/^ //; s/ $//'
}

# GitHub Slugger (subset matching jch/html-pipeline). Input is the heading TEXT
# (i.e. without the leading `### ` markdown prefix).
#   1) lowercase
#   2) drop characters that aren't [a-z0-9_- ] (ASCII range)
#   3) collapse whitespace runs to single hyphen
#   4) trim leading/trailing hyphens
slugify_heading() {
  local heading="$1"
  printf '%s' "$heading" \
    | tr '[:upper:]' '[:lower:]' \
    | sed 's/[^a-z0-9_ -]//g' \
    | sed -E 's/[[:space:]]+/-/g' \
    | sed -E 's/^-+//; s/-+$//'
}

# ---------- Build SKILLS_TABLE block ------------------------------------------

skills_table=$(mktemp)
trap 'rm -f "$skills_table" "$skills_options" 2>/dev/null || true' EXIT

# Iterate skill directories in alphabetical order by basename.
sorted_skill_paths=$(find "$skills_dir" -mindepth 2 -maxdepth 2 -name SKILL.md \
                    | awk -F/ '{print $(NF-1)"\t"$0}' | sort | cut -f2-)

{
  echo '<!-- SKILLS_TABLE_START -->'
  echo ''
  echo '| Command | Description | When to use |'
  echo '|---------|-------------|-------------|'
  while IFS= read -r skill_md; do
    [[ -z "$skill_md" ]] && continue
    skill_dir=$(dirname "$skill_md")
    skill_name=$(basename "$skill_dir")
    [[ "$skill_name" == "_common" ]] && continue

    name=$(frontmatter_field "$skill_md" "name")
    description=$(frontmatter_field "$skill_md" "description")
    when_to_use=$(frontmatter_field "$skill_md" "when_to_use")

    [[ -z "$name" ]] && name="$skill_name"
    [[ -z "$when_to_use" ]] && when_to_use="(미지정)"

    printf '| `/cc-cmds:%s` | %s | %s |\n' "$name" "$description" "$when_to_use"
  done <<< "$sorted_skill_paths"
  echo ''
  echo '<!-- SKILLS_TABLE_END -->'
} > "$skills_table"

# ---------- Build SKILLS_OPTIONS block ----------------------------------------

skills_options=$(mktemp)

# First pass: collect skills that actually contribute (have non-empty `usage` or `options`).
contributing=()
while IFS= read -r skill_md; do
  [[ -z "$skill_md" ]] && continue
  skill_dir=$(dirname "$skill_md")
  skill_name=$(basename "$skill_dir")
  [[ "$skill_name" == "_common" ]] && continue

  usage=$(frontmatter_field "$skill_md" "usage")
  has_opts=$(has_options_key "$skill_md")
  if [[ -n "$usage" || "$has_opts" == "true" ]]; then
    contributing+=("$skill_md")
  fi
done <<< "$sorted_skill_paths"

{
  echo '<!-- SKILLS_OPTIONS_START -->'
  echo ''

  if [[ ${#contributing[@]} -eq 0 ]]; then
    # Placeholder line — keeps splice idempotent. No internal Phase numbering.
    echo '<!-- SKILLS_OPTIONS: auto-populated from SKILL.md frontmatter once skills define `usage`/`options`. -->'
    echo ''
  else
    # Command ToC (in-page navigation). Slug derived from `### /cc-cmds:<name>` heading.
    # Bash 3.2 compatibility: track seen slugs via newline-delimited string instead of
    # associative array.
    toc_seen=$'\n'
    for skill_md in "${contributing[@]}"; do
      skill_name=$(basename "$(dirname "$skill_md")")
      name=$(frontmatter_field "$skill_md" "name")
      [[ -z "$name" ]] && name="$skill_name"
      heading_text="/cc-cmds:${name}"
      base_slug=$(slugify_heading "$heading_text")
      slug="$base_slug"
      n=1
      while [[ "$toc_seen" == *$'\n'"$slug"$'\n'* ]]; do
        slug="${base_slug}-${n}"
        n=$((n + 1))
      done
      toc_seen+="$slug"$'\n'
      printf -- '- [/cc-cmds:%s](#%s)\n' "$name" "$slug"
    done
    echo ''

    # Per-skill section
    for skill_md in "${contributing[@]}"; do
      skill_name=$(basename "$(dirname "$skill_md")")
      name=$(frontmatter_field "$skill_md" "name")
      [[ -z "$name" ]] && name="$skill_name"
      usage=$(frontmatter_field "$skill_md" "usage")
      notes=$(frontmatter_field "$skill_md" "notes")
      opts_len=$(options_length "$skill_md")

      printf '### /cc-cmds:%s\n\n' "$name"
      if [[ -n "$usage" ]]; then
        printf '**Usage**: `%s`\n\n' "$usage"
      fi

      if [[ "$opts_len" == "0" ]]; then
        if [[ -n "$notes" ]]; then
          # Render notes as a single italic line (newlines collapsed so the
          # markdown italic span stays well-formed).
          notes_line=$(collapse_lines "$notes")
          printf '_%s_\n\n' "$notes_line"
        fi
        continue
      fi

      # Compute render order: positional first, then flag; required:true first; YAML order otherwise.
      order=""
      # Pass 1: positional, required=true
      for ((i = 0; i < opts_len; i++)); do
        kind=$(option_field "$skill_md" "$i" "kind")
        req=$(option_bool "$skill_md" "$i" "required")
        if [[ "$kind" == "positional" && "$req" == "true" ]]; then
          order+="$i "
        fi
      done
      # Pass 2: positional, required=false
      for ((i = 0; i < opts_len; i++)); do
        kind=$(option_field "$skill_md" "$i" "kind")
        req=$(option_bool "$skill_md" "$i" "required")
        if [[ "$kind" == "positional" && "$req" != "true" ]]; then
          order+="$i "
        fi
      done
      # Pass 3: flag (required is forbidden on flags by lint Rule 3, so no inner sort)
      for ((i = 0; i < opts_len; i++)); do
        kind=$(option_field "$skill_md" "$i" "kind")
        if [[ "$kind" == "flag" ]]; then
          order+="$i "
        fi
      done
      # Pass 4: anything else (kind missing or unknown — still emitted to keep output deterministic)
      for ((i = 0; i < opts_len; i++)); do
        kind=$(option_field "$skill_md" "$i" "kind")
        if [[ "$kind" != "positional" && "$kind" != "flag" ]]; then
          order+="$i "
        fi
      done

      # Options table
      echo '| Option | Default | Summary |'
      echo '| --- | --- | --- |'
      for i in $order; do
        oname=$(option_field "$skill_md" "$i" "name")
        kind=$(option_field "$skill_md" "$i" "kind")
        summary=$(option_field "$skill_md" "$i" "summary")
        summary_cell=$(collapse_lines "$summary")
        if [[ "$kind" == "positional" ]]; then
          req=$(option_bool "$skill_md" "$i" "required")
          if [[ "$req" == "true" ]]; then
            default_cell="(required)"
          else
            default_cell="_(optional)_"
          fi
        else
          default_val=$(option_field "$skill_md" "$i" "default")
          noop=$(option_bool "$skill_md" "$i" "noop")
          if [[ "$noop" == "true" ]]; then
            default_cell="_${default_val}_"
          else
            default_cell="$default_val"
          fi
        fi
        printf '| `%s` | %s | %s |\n' "$oname" "$default_cell" "$summary_cell"
      done
      echo ''

      # Variants blocks (in option order)
      for i in $order; do
        v_len=$(variants_length "$skill_md" "$i")
        if [[ "$v_len" == "0" ]]; then continue; fi
        oname=$(option_field "$skill_md" "$i" "name")
        printf '**`%s` 입력 형태별 처리:**\n\n' "$oname"
        for ((vi = 0; vi < v_len; vi++)); do
          label=$(variant_field "$skill_md" "$i" "$vi" "label")
          behavior=$(variant_field "$skill_md" "$i" "$vi" "behavior")
          behavior_line=$(collapse_lines "$behavior")
          has_example=$(variant_has_field "$skill_md" "$i" "$vi" "example")
          example=$(variant_field "$skill_md" "$i" "$vi" "example")
          if [[ "$has_example" == "true" && -n "$example" ]]; then
            printf -- '- **%s** — `%s` → %s\n' "$label" "$example" "$behavior_line"
          else
            printf -- '- **%s** — %s\n' "$label" "$behavior_line"
          fi
        done
        echo ''
      done

      # parse_note blockquotes (in option order)
      for i in $order; do
        has_pn=$(option_has_field "$skill_md" "$i" "parse_note")
        if [[ "$has_pn" != "true" ]]; then continue; fi
        pn=$(option_field "$skill_md" "$i" "parse_note")
        if [[ -z "$pn" ]]; then continue; fi
        oname=$(option_field "$skill_md" "$i" "name")
        # parse_note preserves newlines but the entire content renders as a single
        # italic blockquote line per design §5.3 — collapse to a single line for
        # blockquote consistency.
        pn_line=$(collapse_lines "$pn")
        printf -- '> _Parsing (`%s`): %s_\n\n' "$oname" "$pn_line"
      done

      # Safety blocks (in option order)
      for i in $order; do
        safety=$(option_bool "$skill_md" "$i" "safety")
        if [[ "$safety" != "true" ]]; then continue; fi
        oname=$(option_field "$skill_md" "$i" "name")
        summary=$(option_field "$skill_md" "$i" "summary")
        summary_line=$(collapse_lines "$summary")
        printf '**Safety** — %s (`%s`):\n\n' "$summary_line" "$oname"
        ss_len=$(safety_summary_length "$skill_md" "$i")
        for ((si = 0; si < ss_len; si++)); do
          item=$(safety_summary_item "$skill_md" "$i" "$si")
          printf -- '- %s\n' "$item"
        done
        echo ''
      done
    done
  fi

  echo '<!-- SKILLS_OPTIONS_END -->'
} > "$skills_options"

# ---------- Splice helpers ----------------------------------------------------

splice_block() {
  # $1 = README path (in-place), $2 = block file, $3 = START marker pattern,
  # $4 = END marker pattern, $5 = fallback heading text exact match (for insertion),
  # $6 = "before" or "after" (relative to fallback heading),
  # $7 = optional pre-insert literal H2 line (e.g. "## Options") inserted just before block when fallback fires
  local readme_path="$1" block_file="$2" start_pat="$3" end_pat="$4" fallback_heading="$5" position="$6" pre_insert="${7:-}"

  if grep -q "$start_pat" "$readme_path"; then
    awk -v block_file="$block_file" -v start_pat="$start_pat" -v end_pat="$end_pat" '
      BEGIN { in_block=0 }
      $0 ~ start_pat {
        while ((getline line < block_file) > 0) print line
        close(block_file)
        in_block=1
        next
      }
      $0 ~ end_pat { in_block=0; next }
      in_block == 0 { print }
    ' "$readme_path" > "$readme_path.new"
    mv "$readme_path.new" "$readme_path"
  else
    # Fallback insertion. If pre_insert is provided and the heading already
    # exists in README, insert markers only (heading stays as-is). If heading
    # is missing, prepend the synthetic heading.
    awk -v block_file="$block_file" -v fb_heading="$fallback_heading" -v pos="$position" -v pre_insert="$pre_insert" '
      BEGIN { inserted=0; pre_inserted=0 }
      {
        if (inserted == 0 && index($0, fb_heading) == 1 && length($0) == length(fb_heading)) {
          if (pos == "after") {
            print
            print ""
            while ((getline line < block_file) > 0) print line
            close(block_file)
            inserted=1
            next
          } else {
            # pos == "before"
            if (pre_insert != "" && pre_inserted == 0) {
              print pre_insert
              print ""
            }
            while ((getline line < block_file) > 0) print line
            close(block_file)
            print ""
            print
            inserted=1
            next
          }
        }
        print
      }
    ' "$readme_path" > "$readme_path.new"
    mv "$readme_path.new" "$readme_path"
  fi
}

# Pass 1: SKILLS_TABLE — fallback inserts after `## Commands`
splice_block "$readme" "$skills_table" \
  '<!-- SKILLS_TABLE_START -->' '<!-- SKILLS_TABLE_END -->' \
  '## Commands' 'after' ''

# Pass 2: SKILLS_OPTIONS — fallback inserts before `## License` (with `## Options` H2 if absent)
# If `## Options` H2 is already present in README, splice_block's start-marker branch
# is the path normally taken; the fallback branch inserts the H2 + markers atomically.
if grep -q '<!-- SKILLS_OPTIONS_START -->' "$readme"; then
  splice_block "$readme" "$skills_options" \
    '<!-- SKILLS_OPTIONS_START -->' '<!-- SKILLS_OPTIONS_END -->' \
    '## License' 'before' '## Options'
elif grep -q '^## Options[[:space:]]*$' "$readme"; then
  # Heading exists but markers do not — insert markers right after the heading.
  splice_block "$readme" "$skills_options" \
    '<!-- SKILLS_OPTIONS_START -->' '<!-- SKILLS_OPTIONS_END -->' \
    '## Options' 'after' ''
else
  splice_block "$readme" "$skills_options" \
    '<!-- SKILLS_OPTIONS_START -->' '<!-- SKILLS_OPTIONS_END -->' \
    '## License' 'before' '## Options'
fi

echo "generate-readme: updated $readme"
