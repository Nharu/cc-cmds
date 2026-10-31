#!/usr/bin/env bash
# lint-attention-schema.sh — check attention event records and handled markers
# against schema version 1.
#
#   bash scripts/lint-attention-schema.sh            every tests/fixtures/attention/*.json
#   bash scripts/lint-attention-schema.sh <file>...  the named files only
#
# A record carrying a `cause` key is checked as a handled marker, any other as
# an event. Exit 0 when every file passes; 1 when any file fails, with the file
# and the reason on stderr; 1 also when `jq` is missing.
#
# THE TABLES ARE READ FROM THE SCHEMA DOCUMENT. The kind list, the cause list
# and the token and kind table live in
# `plugins/cc-cmds/skills/_common/attention-event.md`. The lists below are this
# lint's own copy, and every run compares them with the document's tables, so
# a row added to one side only fails here instead of passing records the other
# side would refuse.
#
# Run without arguments, the lint also checks that every kind and every cause
# has at least one fixture.

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
doc="$repo_root/plugins/cc-cmds/skills/_common/attention-event.md"
fixtures="$repo_root/tests/fixtures/attention"

KINDS=(auq question-form turn approval run-end run-stop run-blocked active-notify permission)
CAUSES=(clear return approval-closed dismiss reply-applied permission-settled)
# "<token> <kind>", or "<token> 없음" for a token that raises no event.
TOKEN_PAIRS=(
  "session-ask auq"
  "session-ask question-form"
  "session-turn turn"
  "answer approval"
  "ended run-end"
  "rekick run-stop"
  "resume run-stop"
  "hands run-blocked"
  "active-notify active-notify"
  "permission permission"
  "answer-run 없음"
  "overflow 없음"
  "focus-guide 없음"
)

if ! command -v jq >/dev/null 2>&1; then
  echo "lint-attention-schema: jq not found — records cannot be checked" >&2
  exit 1
fi

if [[ ! -f "$doc" ]]; then
  echo "lint-attention-schema: schema document missing: $doc" >&2
  exit 1
fi

fail=0

# doc_table <heading> — print "<first> <second>" for each row of the table
# under `## <heading>`, with backticks and cell padding removed. Rows are the
# lines that begin with "| `", so the header and separator rows are skipped.
doc_table() {
  awk -v h="## $1" '
    $0 == h { inside = 1; next }
    inside && /^## / { exit }
    inside && /^\| `/ {
      split($0, c, "|")
      a = c[2]; b = c[3]
      gsub(/`/, "", a); gsub(/`/, "", b)
      gsub(/^[ \t]+|[ \t]+$/, "", a); gsub(/^[ \t]+|[ \t]+$/, "", b)
      print a " " b
    }
  ' "$doc"
}

# compare_table <label> <expected-lines> <document-lines>
compare_table() {
  local label="$1" want="$2" got="$3"
  want=$(printf '%s\n' "$want" | LC_ALL=C sort)
  got=$(printf '%s\n' "$got" | LC_ALL=C sort)
  if [[ "$want" != "$got" ]]; then
    echo "FAIL: $doc — the $label table differs from this lint's list" >&2
    echo "  lint:     $(printf '%s' "$want" | tr '\n' ',')" >&2
    echo "  document: $(printf '%s' "$got" | tr '\n' ',')" >&2
    fail=1
  fi
}

doc_kinds=$(doc_table "Kinds" | awk '{ print $1 }')
doc_causes=$(doc_table "Handled causes" | awk '{ print $1 }')
doc_pairs=$(doc_table "Tokens and kinds")
compare_table "kind" "$(printf '%s\n' "${KINDS[@]}")" "$doc_kinds"
compare_table "cause" "$(printf '%s\n' "${CAUSES[@]}")" "$doc_causes"
compare_table "token and kind" "$(printf '%s\n' "${TOKEN_PAIRS[@]}")" "$doc_pairs"

to_json_array() {
  printf '%s\n' "$@" | jq -R . | jq -sc .
}
kinds_json=$(to_json_array "${KINDS[@]}")
causes_json=$(to_json_array "${CAUSES[@]}")
pairs_json=$(to_json_array "${TOKEN_PAIRS[@]}")

# The record check. Prints `E <reason>` for each violation, and `K <kind>` or
# `C <cause>` naming what the record is, for the coverage check.
prog='
def nestr: type == "string" and length > 0;
def posint: type == "number" and . > 0 and . == floor;
def re($r): type == "string" and test($r);
def has_str($k): has($k) and (.[$k] | type == "string");
def has_nestr($k): has($k) and (.[$k] | nestr);
def labels_ok: type == "array" and all(.[]; type == "object" and has_str("label"));
def reply_ok($kind):
  type == "object" and .surface == $kind and
  (if $kind == "auq" then
     has_nestr("session_id") and has_nestr("tool_use_id")
     and (.questions | type == "array")
     and all(.questions[]; type == "object" and has_str("question") and has_str("header")
             and (.multi_select | type == "boolean") and (.options | labels_ok))
   elif $kind == "question-form" then
     has_nestr("session_id") and has_nestr("form_id")
     and (.questions | type == "array")
     and all(.questions[]; type == "object" and has_nestr("id") and has_str("question")
             and (.options | labels_ok))
   elif $kind == "approval" then
     has_str("run_id") and has_str("approval_id") and has_str("question")
     and (.options | type == "array") and all(.options[]; type == "string")
   elif $kind == "permission" then
     has_nestr("session_id") and has_nestr("tool_name") and has_str("input_summary")
   else false end);
def repo_ok:
  re("\\A[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9_.-]{1,100}\\z")
  and ((split("/") | .[1]) as $n | $n != "." and $n != "..");
def ordinary_id($host):
  re("\\A[a-z0-9-]{1,32}\\.[0-9]+\\.[0-9a-f]{8}\\z") and startswith($host + ".");
def actionable_shape($r):
  ($r.reply | reply_ok($r.kind)) and
  (if $r.kind == "auq" then
     ($r.reply.questions | length) >= 1 and all($r.reply.questions[]; (.options | length) >= 1)
   elif $r.kind == "question-form" then
     all($r.reply.questions[]; (.id | nestr) and (.options | length) >= 1)
   elif $r.kind == "approval" then
     ($r.reply.options | length) >= 1
   else false end);
def approval_id_errors($r):
  if (($r.id | type) == "string" and ($r.host | type) == "string"
      and ($r.id | startswith($r.host + ".appr."))) | not
  then "approval id does not start with <host>.appr."
  else
    ($r.id[(($r.host + ".appr.") | length):] | split(".")) as $p
    | if ($p | length) != 2 then "approval id is not <host>.appr.<run_id>.<approval_id>"
      elif ($p[0] | re("\\A[A-Za-z0-9-]{1,64}\\z") | not) then "approval id run_id is malformed"
      elif ($p[1] | re("\\A[A-Za-z0-9_-]{1,55}-[0-9a-f]{8}\\z") | not) then "approval id approval_id is malformed"
      elif $r.slot != ("cc-cmds-autopilot-" + $p[0] + "-" + $p[1]) then "slot is not cc-cmds-autopilot-<run_id>-<approval_id>"
      elif $r.reply != null and ($r.reply | type) == "object"
           and ($r.reply.run_id != $p[0] or $r.reply.approval_id != $p[1])
      then "reply run_id or approval_id does not match the id"
      elif $r.reply != null and ($r.reply | type) == "object" and $r.reply.question != $r.body
      then "reply.question is not byte-equal to body"
      elif ($r.body | nestr | not) then "approval body is empty"
      else empty end
  end;
def event_errors:
  . as $r
  | (if keys == $ekeys then empty else "keys are not exactly the thirteen event keys" end),
    (if .schema == 1 then empty else "schema is not 1" end),
    (if (.host | re("\\A[a-z0-9-]{1,32}\\z")) then empty else "host is malformed" end),
    (if (.created_at_ms | posint) then empty else "created_at_ms is not a positive integer" end),
    (if (.kind | type) == "string" and any($kinds[]; . == $r.kind) then empty else "unknown kind" end),
    (if (.token | type) == "string" and (.kind | type) == "string"
        and any($pairs[]; . == ($r.token + " " + $r.kind))
     then empty else "(token, kind) is not a pair of the token table" end),
    (if (.slot | nestr) then empty else "slot is not a non-empty string" end),
    (if (.title | type) == "string" and (.body | type) == "string" then empty else "title or body is not a string" end),
    (if (.actionable | type) == "boolean" then empty else "actionable is not a boolean" end),
    (if .accepts == (if .actionable == true then ["option"] else [] end) then empty
     else "accepts does not follow actionable" end),
    (if (.origin | type) == "object" and (.origin | keys) == $okeys
        and (.origin.config_dir | type) == "string"
        and all(.origin | (.session_id, .run_id, .cwd, .repo, .tmux_pane); . == null or type == "string")
     then empty else "origin does not have the six keys with their types" end),
    (if (.origin | type) == "object" and (.origin.repo == null or (.origin.repo | repo_ok)) then empty
     else "origin.repo is neither null nor <owner>/<name>" end),
    (if .reply == null or (.reply | reply_ok($r.kind)) then empty
     else "reply does not match the kind surface or lacks a required field" end),
    (if .actionable != true or actionable_shape($r) then empty
     else "actionable is true but the reply does not allow an answer" end),
    (if .kind != "permission" or .actionable == false then empty else "a permission event is actionable" end),
    (if .kind == "approval" then approval_id_errors($r)
     elif (.id | type) == "string" and (.host | type) == "string" and (.id | ordinary_id($r.host)) then empty
     else "id is not <host>.<epoch_ms>.<8 hex>" end);
def handled_errors:
  . as $r
  | (if keys == $hkeys then empty else "keys are not exactly the seven handled keys" end),
    (if .schema == 1 then empty else "schema is not 1" end),
    (if (.host | re("\\A[a-z0-9-]{1,32}\\z")) then empty else "host is malformed" end),
    (if (.id | type) == "string" and (.host | type) == "string" and (.id | ordinary_id($r.host)) then empty
     else "id is not <host>.<epoch_ms>.<8 hex>" end),
    (if (.at_ms | posint) then empty else "at_ms is not a positive integer" end),
    (if (.slot | nestr) then empty else "slot is not a non-empty string" end),
    (if (.prefix | type) == "boolean" then empty else "prefix is not a boolean" end),
    (if .prefix != true or ((.slot | type) == "string" and (.slot | endswith("@"))) then empty
     else "a prefix marker slot does not end with @" end),
    (if (.cause | type) == "string" and any($causes[]; . == $r.cause) then empty else "unknown cause" end);

if length != 1 then "E the file does not hold exactly one JSON value"
else
  .[0]
  | if type != "object" then "E the record is not a JSON object"
    elif has("cause") then (handled_errors | "E " + .), ("C " + (.cause | tostring))
    else (event_errors | "E " + .), ("K " + (.kind | tostring))
    end
end
'

ekeys='["accepts","actionable","body","created_at_ms","host","id","kind","origin","reply","schema","slot","title","token"]'
okeys='["config_dir","cwd","repo","run_id","session_id","tmux_pane"]'
hkeys='["at_ms","cause","host","id","prefix","schema","slot"]'

coverage=0
if [[ $# -gt 0 ]]; then
  files=("$@")
else
  coverage=1
  files=()
  for f in "$fixtures"/*.json; do
    [[ -f "$f" ]] && files+=("$f")
  done
  if [[ ${#files[@]} -eq 0 ]]; then
    echo "FAIL: no fixtures under $fixtures" >&2
    fail=1
  fi
fi

seen_kinds=" "
seen_causes=" "
checked=0
for f in ${files[@]+"${files[@]}"}; do
  checked=$((checked + 1))
  if [[ ! -f "$f" ]]; then
    echo "FAIL: $f — not a file" >&2
    fail=1
    continue
  fi
  if ! out=$(jq -rs \
      --argjson kinds "$kinds_json" \
      --argjson causes "$causes_json" \
      --argjson pairs "$pairs_json" \
      --argjson ekeys "$ekeys" \
      --argjson okeys "$okeys" \
      --argjson hkeys "$hkeys" \
      "$prog" "$f" 2>&1); then
    echo "FAIL: $f — not readable as JSON: $out" >&2
    fail=1
    continue
  fi
  file_bad=0
  while IFS= read -r line; do
    case "$line" in
      'E '*)
        echo "FAIL: $f — ${line#E }" >&2
        file_bad=1
        ;;
      'K '*) seen_kinds="$seen_kinds${line#K } " ;;
      'C '*) seen_causes="$seen_causes${line#C } " ;;
    esac
  done <<< "$out"
  if [[ "$file_bad" -eq 1 ]]; then
    fail=1
  fi
done

if [[ "$coverage" -eq 1 ]]; then
  for k in "${KINDS[@]}"; do
    case "$seen_kinds" in
      *" $k "*) ;;
      *)
        echo "FAIL: no fixture for kind $k under $fixtures" >&2
        fail=1
        ;;
    esac
  done
  for c in "${CAUSES[@]}"; do
    case "$seen_causes" in
      *" $c "*) ;;
      *)
        echo "FAIL: no fixture for cause $c under $fixtures" >&2
        fail=1
        ;;
    esac
  done
fi

if [[ "$fail" -ne 0 ]]; then
  echo "lint-attention-schema: violations found" >&2
  exit 1
fi
echo "lint-attention-schema: $checked file(s) checked, no violations"
exit 0
