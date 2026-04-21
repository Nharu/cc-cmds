#!/usr/bin/env bash
# Regenerate the Commands table in README.md from each SKILL.md's frontmatter.
#
# Contract:
#   - Inputs: plugins/cc-cmds/skills/<name>/SKILL.md (excludes _common/)
#   - Parses YAML frontmatter fields: name, description, when_to_use
#   - Replaces content between <!-- SKILLS_TABLE_START --> and <!-- SKILLS_TABLE_END -->
#   - Idempotent: running twice produces byte-identical output
#
# CI integration: `make readme && git diff --exit-code README.md` blocks drift.

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
readme="$repo_root/README.md"
skills_dir="$repo_root/plugins/cc-cmds/skills"

if [[ ! -f "$readme" ]]; then
  echo "generate-readme: $readme not found" >&2
  exit 1
fi

# Parse frontmatter field from a SKILL.md file.
# Usage: frontmatter_field <file> <field-name>
frontmatter_field() {
  local file="$1" field="$2"
  awk -v field="$field" '
    BEGIN { in_fm=0 }
    /^---$/ {
      if (in_fm == 0) { in_fm=1; next }
      else { exit }
    }
    in_fm == 1 {
      idx = index($0, ":")
      if (idx == 0) next
      key = substr($0, 1, idx-1)
      val = substr($0, idx+1)
      sub(/^[ \t]+/, "", key); sub(/[ \t]+$/, "", key)
      sub(/^[ \t]+/, "", val); sub(/[ \t]+$/, "", val)
      # Strip optional surrounding quotes
      if ((substr(val,1,1) == "\"" && substr(val,length(val),1) == "\"") \
          || (substr(val,1,1) == "'\''" && substr(val,length(val),1) == "'\''")) {
        val = substr(val, 2, length(val)-2)
      }
      if (key == field) { print val; exit }
    }
  ' "$file"
}

# Build the new table body
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

{
  echo '<!-- SKILLS_TABLE_START -->'
  echo ''
  echo '| Command | Description | When to use |'
  echo '|---------|-------------|-------------|'

  # Iterate over skill directories with a SKILL.md, alphabetically by skill name
  # (sort by basename of parent dir — not full path, so `design` precedes `design-review`).
  # Skip _common/ which has no SKILL.md anyway.
  for skill_md in $(find "$skills_dir" -mindepth 2 -maxdepth 2 -name SKILL.md \
                    | awk -F/ '{print $(NF-1)"\t"$0}' | sort | cut -f2-); do
    skill_dir=$(dirname "$skill_md")
    skill_name=$(basename "$skill_dir")
    [[ "$skill_name" == "_common" ]] && continue

    name=$(frontmatter_field "$skill_md" "name")
    description=$(frontmatter_field "$skill_md" "description")
    when_to_use=$(frontmatter_field "$skill_md" "when_to_use")

    # Fallback: if name field missing, use directory name
    [[ -z "$name" ]] && name="$skill_name"
    [[ -z "$when_to_use" ]] && when_to_use="(미지정)"

    printf '| `/cc-cmds:%s` | %s | %s |\n' "$name" "$description" "$when_to_use"
  done

  echo ''
  echo '<!-- SKILLS_TABLE_END -->'
} > "$tmp"

# Splice the new table into README.md between the markers.
# If the markers don't exist yet, append them after the "## Commands" heading.
if ! grep -q '<!-- SKILLS_TABLE_START -->' "$readme"; then
  echo "generate-readme: markers not found in README — inserting after '## Commands' heading" >&2
  awk -v marker_block_file="$tmp" '
    BEGIN { inserted=0 }
    /^## Commands[[:space:]]*$/ && inserted == 0 {
      print
      print ""
      while ((getline line < marker_block_file) > 0) print line
      inserted=1
      next
    }
    { print }
  ' "$readme" > "$readme.new"
  mv "$readme.new" "$readme"
else
  # Replace existing block between markers
  awk -v marker_block_file="$tmp" '
    BEGIN { in_block=0 }
    /<!-- SKILLS_TABLE_START -->/ {
      while ((getline line < marker_block_file) > 0) print line
      in_block=1
      next
    }
    /<!-- SKILLS_TABLE_END -->/ {
      in_block=0
      next
    }
    in_block == 0 { print }
  ' "$readme" > "$readme.new"
  mv "$readme.new" "$readme"
fi

echo "generate-readme: updated $readme"
