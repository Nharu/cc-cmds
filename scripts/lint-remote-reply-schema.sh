#!/usr/bin/env bash
# lint-remote-reply-schema.sh — check remote reply envelopes, pick-up markers,
# applied records and their pairs, and the wake literal against schema 1.
#
#   bash scripts/lint-remote-reply-schema.sh                   every fixture
#   bash scripts/lint-remote-reply-schema.sh <file>...         the named files only
#   bash scripts/lint-remote-reply-schema.sh --doc <path> ...  read the tables from <path>
#   bash scripts/lint-remote-reply-schema.sh --fixtures <dir>  treat <dir> as the fixtures
#
# The file name's prefix decides what a file is:
#   envelope-<name>.json   an envelope (inbox/<addr>/<reply_id>.json)
#   picked-<name>.json     a pick-up marker (inbox/<addr>/<reply_id>.picked)
#   applied-<name>.json    an applied record (applied/<reply_id>.json), checked
#                          together with its pair in the same directory:
#     submit-<name>.txt    the bytes a question form submitted, whose sha256 is
#                          the record's answers_sha256
#     frame-<name>.jsonl   two transcript lines — the AskUserQuestion tool_use
#                          and the tool_result the harness wrote — which must pass
#                          the gate's frame conditions and reproduce the record's
#                          answers_sha256
#   wake-<name>.txt        the router-seat wake literal
# Naming a submit or frame file checks it through its applied record.
#
# Exit 0 when every file passes; 1 when any file fails, with the file and the
# reason on stderr; 1 also when `jq` or `shasum` is missing; 2 on a bad argument.
#
# THE TABLES ARE READ FROM THE RULE DOCUMENT. The envelope keys, the pick-up
# marker keys, the applied record keys and the address rule live in
# `plugins/cc-cmds/skills/_common/remote-reply.md` under the headings
# `## 봉투 키`, `## 수령 표지 키`, `## 적용 기록 키` and `## 주소 규칙`. The lists
# below are this lint's own copy, and every run compares them with the
# document's tables, so a row added to one side only fails here instead of
# passing records the other side would refuse.
#
# THE HASH IS THE GATE'S FORMULA. For a transcript pair the answers_sha256 is
# recomputed the way the gate will compute it: `jq -j` prints, for each question
# of the tool_use input in order, the question, byte 0x1F, the answer from
# `toolUseResult.answers`, byte 0x1E, and `shasum -a 256` hashes the bytes. An
# answer that is missing or is not a string never matches.
#
# Run without file arguments, the lint also checks that every fixture kind has
# at least one file: the four envelope shapes (auq single-select, auq with a
# multi-select question, question-form, approval), a marker without and with
# woken_at_ms, a submit pair, a frame pair for an ordinary question, a frame
# pair for an approval question, and a wake literal.

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
doc="$repo_root/plugins/cc-cmds/skills/_common/remote-reply.md"
fixtures="$repo_root/tests/fixtures/remote-reply"

ENVELOPE_KEYS=(schema reply_id event_id host kind target answers provenance expires_at_ms pickup_by_ms)
PICKED_KEYS=(schema reply_id session_id picked_at_ms apply_by_ms woken_at_ms)
APPLIED_KEYS=(schema tool_use_id session_id reply_id event_id answers_sha256 transport sender applied_at_ms)
# "<surface> <address>"
ADDRESS_PAIRS=(
  "approval r-<target.run_id>"
  "auq s-<safe_sid(target.session_id)>"
  "question-form s-<safe_sid(target.session_id)>"
)
COVERAGE=(
  envelope-auq-single
  envelope-auq-multi
  envelope-question-form
  envelope-approval
  picked-plain
  picked-woken
  pair-submit
  pair-frame-question
  pair-frame-approval
  wake
)
WAKE_RE='^<cc-remote-approval run=[A-Za-z0-9-]{1,64} id=[A-Za-z0-9_-]{1,55}-[0-9a-f]{8}/>$'
APPROVAL_Q_RE='^승인 [A-Za-z0-9_-]{1,55}-[0-9a-f]{8} — '

usage() {
  echo "usage: lint-remote-reply-schema.sh [--doc <path>] [--fixtures <dir>] [<file>...]" >&2
  exit 2
}

files=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --doc)
      [[ $# -ge 2 ]] || usage
      doc="$2"
      shift 2
      ;;
    --fixtures)
      [[ $# -ge 2 ]] || usage
      fixtures="$2"
      shift 2
      ;;
    --)
      shift
      files+=("$@")
      break
      ;;
    -*) usage ;;
    *)
      files+=("$1")
      shift
      ;;
  esac
done

for tool in jq shasum; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "lint-remote-reply-schema: $tool not found — records cannot be checked" >&2
    exit 1
  fi
done

if [[ ! -f "$doc" ]]; then
  echo "lint-remote-reply-schema: rule document missing: $doc" >&2
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

compare_table "envelope key" "$(printf '%s\n' "${ENVELOPE_KEYS[@]}")" "$(doc_table "봉투 키" | awk '{ print $1 }')"
compare_table "pick-up marker key" "$(printf '%s\n' "${PICKED_KEYS[@]}")" "$(doc_table "수령 표지 키" | awk '{ print $1 }')"
compare_table "applied record key" "$(printf '%s\n' "${APPLIED_KEYS[@]}")" "$(doc_table "적용 기록 키" | awk '{ print $1 }')"
compare_table "address rule" "$(printf '%s\n' "${ADDRESS_PAIRS[@]}")" "$(doc_table "주소 규칙")"

# The run-address surface, read back from this lint's address list: an
# envelope whose address is r-<...> carries pickup_by_ms, every other does not.
run_surfaces=()
for p in "${ADDRESS_PAIRS[@]}"; do
  case "${p#* }" in
    r-*) run_surfaces+=("${p%% *}") ;;
  esac
done

to_json_array() {
  printf '%s\n' "$@" | jq -R . | jq -sc .
}
surfaces_json=$(to_json_array "${ADDRESS_PAIRS[@]%% *}")
run_surfaces_json=$(to_json_array "${run_surfaces[@]}")

# Shared definitions. Every check prints `E <reason>` per violation and
# `K <kind>` naming what the record is, for the coverage check.
defs='
def nestr: type == "string" and length > 0;
def int: type == "number" and . == floor;
def posint: int and . > 0;
def re($r): type == "string" and test($r);
def reply_id_ok: re("\\A[a-z0-9-]{1,32}\\.[0-9]+\\.[0-9a-f]{8}\\z");
def labels_ok: type == "array" and length >= 1 and all(.[]; type == "object" and (.label | type) == "string");
def one_value: if length != 1 then error("the file does not hold exactly one JSON value") else .[0] end;
'

envelope_prog="$defs"'
def target_errors:
  if type != "object" then "target is not an object"
  elif (.surface | type) != "string" or (. as $t | any($surfaces[]; . == $t.surface) | not)
  then "target.surface is not one of auq, question-form, approval"
  elif .surface == "auq" then
    (if (.session_id | nestr) and (.tool_use_id | nestr) then empty
     else "auq target lacks a non-empty session_id or tool_use_id" end),
    (if (.questions | type) == "array" and (.questions | length) >= 1
        and all(.questions[]; type == "object" and (.question | type) == "string"
                and (.header | type) == "string" and (.multi_select | type) == "boolean"
                and (.options | labels_ok))
     then empty else "auq target questions are not {question, header, multi_select, options[{label}]}" end)
  elif .surface == "question-form" then
    (if (.session_id | nestr) and (.form_id | nestr) then empty
     else "question-form target lacks a non-empty session_id or form_id" end),
    (if (.questions | type) == "array" and (.questions | length) >= 1
        and all(.questions[]; type == "object" and (.id | nestr) and (.question | type) == "string"
                and (.options | labels_ok))
     then empty else "question-form target questions are not {id, question, options[{label}]}" end)
  else
    (if (.run_id | re("\\A[A-Za-z0-9-]{1,64}\\z")) then empty else "approval target run_id is malformed" end),
    (if (.approval_id | re("\\A[A-Za-z0-9_-]{1,55}-[0-9a-f]{8}\\z")) then empty
     else "approval target approval_id is malformed" end),
    (. as $t
     | if ($t.question | type) == "string" and ($t.approval_id | type) == "string"
          and ($t.question | startswith("승인 " + $t.approval_id + " — "))
     then empty else "approval target question is not 승인 <approval_id> — <질문>" end),
    (if (.options | type) == "array" and (.options | length) >= 1 and all(.options[]; type == "string")
     then empty else "approval target options is not a non-empty array of strings" end)
  end;
def questions_of:
  if .surface == "approval" then [{q: .question, labels: .options, multi: false}]
  else [.questions[] | {q: .question, labels: [.options[].label], multi: (.multi_select == true)}] end;
def has_sep: contains("\u001e") or contains("\u001f");
def answer_errors($qs; $surface):
  ($qs | length) as $n
  | if (.answers | type) != "array" then "answers is not an array"
    elif any(.answers[]; type != "object" or (keys != ["labels", "question_index"])
             or (.question_index | int | not) or (.labels | type) != "array"
             or any(.labels[]; type != "string"))
    then "an answer is not {question_index, labels[<string>]}"
    elif [.answers[].question_index] != [range(0; $n)]
    then "answers do not cover every question once in ascending question_index"
    else
      .answers[] as $a
      | $qs[$a.question_index] as $q
      | (if all($a.labels[]; . as $l | any($q.labels[]; . == $l)) then empty
         else "question \($a.question_index): a label is not byte-equal to one of its options"
              + (if $surface == "approval" then " (target.options)" else "" end) end),
        (if $q.multi then
           (if ($a.labels | length) >= 1 then empty else "question \($a.question_index): a multi-select answer has no label" end),
           (if ($a.labels | unique | length) == ($a.labels | length) then empty
            else "question \($a.question_index): a multi-select answer repeats a label" end)
         elif ($a.labels | length) == 1 then empty
         else "question \($a.question_index): a single-select answer does not carry exactly one label" end)
    end;
def envelope_errors:
  . as $e
  | (["schema","reply_id","event_id","host","kind","target","answers","provenance","expires_at_ms"]) as $base
  | ($e.target | type == "object" and (.surface | type) == "string"
     and (. as $t | any($run_surfaces[]; . == $t.surface))) as $run
  | (if has("text") or has("decision") then "an option envelope carries text or decision" else empty end),
    (($e | keys) - $base - ["pickup_by_ms", "text", "decision"]) as $extra
    | (if ($extra | length) == 0 then empty else "unknown key(s): \($extra | join(", "))" end),
    (($base - ($e | keys))) as $missing
    | (if ($missing | length) == 0 then empty else "missing key(s): \($missing | join(", "))" end),
    (if $run and (has("pickup_by_ms") | not) then "a run-address envelope lacks pickup_by_ms"
     elif ($run | not) and has("pickup_by_ms") then "a session-address envelope carries pickup_by_ms"
     else empty end),
    (if .schema == 1 then empty else "schema is not 1" end),
    (if (.host | re("\\A[a-z0-9-]{1,32}\\z")) then empty else "host is malformed" end),
    (if (.reply_id | reply_id_ok) and (.host | type) == "string" and (.reply_id | startswith($e.host + "."))
     then empty else "reply_id is not <host_id>.<epoch_ms>.<8 hex> starting with host" end),
    (if (.event_id | nestr) and (.host | type) == "string" and (.event_id | startswith($e.host + "."))
     then empty else "event_id does not start with <host>." end),
    (if .kind == "option" then empty else "kind is not option" end),
    (if (.provenance | type) == "object"
        and (.provenance | keys) == ["received_at_ms", "sender", "transport", "transport_ref"]
     then
       (if (.provenance.transport | re("\\A[a-z0-9-]{1,32}\\z")) then empty else "provenance.transport is malformed" end),
       (if (.provenance.sender | re("\\A[A-Za-z0-9_.@:-]{1,64}\\z")) then empty else "provenance.sender is malformed" end),
       (if (.provenance.transport_ref | nestr) and (.provenance.transport_ref | test("[\n\r]") | not)
        then empty else "provenance.transport_ref is empty or holds a line break" end),
       (if (.provenance.received_at_ms | posint) then empty else "provenance.received_at_ms is not a positive integer" end)
     else "provenance does not have exactly transport, sender, received_at_ms, transport_ref" end),
    (if (.expires_at_ms | int) and (.provenance | type) == "object"
        and (.provenance.received_at_ms | type) == "number" and .expires_at_ms > .provenance.received_at_ms
     then empty else "expires_at_ms is not an integer greater than received_at_ms" end),
    (if has("pickup_by_ms") | not then empty
     elif (.pickup_by_ms | int) and (.provenance | type) == "object"
          and (.provenance.received_at_ms | type) == "number" and (.expires_at_ms | type) == "number"
          and .provenance.received_at_ms < .pickup_by_ms and .pickup_by_ms <= .expires_at_ms
     then empty else "pickup_by_ms is not in received_at_ms < pickup_by_ms <= expires_at_ms" end),
    ([.target | target_errors]) as $te
    | if ($te | length) > 0 then $te[]
      else
        (.target | questions_of) as $qs
        | (if any($qs[]; (.q | has_sep) or any(.labels[]; has_sep))
           then "a question or label holds byte 0x1E or 0x1F" else empty end),
          (if $e.target.surface == "auq" and ($qs | map(.q) | unique | length) != ($qs | length)
           then "two auq questions have the same text" else empty end),
          (if any($qs[]; (.labels | unique | length) != (.labels | length))
           then "a question has two options with the same label" else empty end),
          (if any($qs[]; .multi and any(.labels[]; contains(", ")))
           then "a multi-select question has an option label holding \", \"" else empty end),
          answer_errors($qs; $e.target.surface)
      end;
def envelope_kind:
  if (.target | type) != "object" then "unknown"
  elif .target.surface == "auq" then
    (if any(.target.questions[]?; .multi_select == true) then "envelope-auq-multi" else "envelope-auq-single" end)
  else "envelope-" + (.target.surface | tostring) end;
one_value
| if type != "object" then "E the record is not a JSON object"
  else (envelope_errors | "E " + .), ("K " + envelope_kind) end
'

picked_prog="$defs"'
one_value
| if type != "object" then "E the record is not a JSON object"
  else
    . as $p
    | (["apply_by_ms","picked_at_ms","reply_id","schema","session_id"]) as $base
    | (if (keys - ["woken_at_ms"]) == $base then empty
       else "keys are not exactly schema, reply_id, session_id, picked_at_ms, apply_by_ms and an optional woken_at_ms" end
       | "E " + .),
      (if .schema == 1 then empty else "E schema is not 1" end),
      (if (.reply_id | reply_id_ok) then empty else "E reply_id is not <host_id>.<epoch_ms>.<8 hex>" end),
      (if (.session_id | nestr) then empty else "E session_id is not a non-empty string" end),
      (if (.picked_at_ms | posint) then empty else "E picked_at_ms is not a positive integer" end),
      (if (.picked_at_ms | type) == "number" and (.apply_by_ms | int) and .apply_by_ms == .picked_at_ms + 120000
       then empty else "E apply_by_ms is not picked_at_ms + 120000" end),
      (if has("woken_at_ms") | not then empty
       elif (.woken_at_ms | int) and (.picked_at_ms | type) == "number" and .woken_at_ms >= .picked_at_ms then empty
       else "E woken_at_ms is not an integer at or after picked_at_ms" end),
      (if has("woken_at_ms") then "K picked-woken" else "K picked-plain" end)
  end
'

applied_prog="$defs"'
one_value
| if type != "object" then "E the record is not a JSON object"
  else
    (if keys == ["answers_sha256","applied_at_ms","event_id","reply_id","schema","sender","session_id","tool_use_id","transport"]
     then empty else "E keys are not exactly the nine applied record keys" end),
    (if .schema == 1 then empty else "E schema is not 1" end),
    (if (.tool_use_id | nestr) then empty else "E tool_use_id is not a non-empty string" end),
    (if (.session_id | nestr) then empty else "E session_id is not a non-empty string" end),
    (if (.reply_id | reply_id_ok) then empty else "E reply_id is not <host_id>.<epoch_ms>.<8 hex>" end),
    (if (.event_id | nestr) then empty else "E event_id is not a non-empty string" end),
    (if (.answers_sha256 | re("\\A[0-9a-f]{64}\\z")) then empty else "E answers_sha256 is not 64 lowercase hex digits" end),
    (if (.transport | re("\\A[a-z0-9-]{1,32}\\z")) then empty else "E transport is malformed" end),
    (if (.sender | re("\\A[A-Za-z0-9_.@:-]{1,64}\\z")) then empty else "E sender is malformed" end),
    (if (.applied_at_ms | posint) then empty else "E applied_at_ms is not a positive integer" end),
    ("T " + (.tool_use_id | tostring)),
    ("H " + (.answers_sha256 | tostring))
  end
'

seen=" "
checked=0

# report <file> <jq output> — print the E lines, collect the K lines.
# Returns 1 when the output held a violation.
report() {
  local f="$1" out="$2" line bad=0
  while IFS= read -r line; do
    case "$line" in
      'E '*)
        echo "FAIL: $f — ${line#E }" >&2
        bad=1
        ;;
      'K '*) seen="$seen${line#K } " ;;
    esac
  done <<< "$out"
  if [[ "$bad" -eq 1 ]]; then
    fail=1
    return 1
  fi
  return 0
}

violation() {
  echo "FAIL: $1 — $2" >&2
  fail=1
}

run_prog() {
  local f="$1" prog="$2" out
  if ! out=$(jq -rs \
      --argjson surfaces "$surfaces_json" \
      --argjson run_surfaces "$run_surfaces_json" \
      "$prog" "$f" 2>&1); then
    violation "$f" "not readable as one JSON value: $out"
    return 1
  fi
  printf '%s' "$out"
}

check_envelope() {
  local out
  out=$(run_prog "$1" "$envelope_prog") || return 0
  report "$1" "$out" || true
}

check_picked() {
  local out
  out=$(run_prog "$1" "$picked_prog") || return 0
  report "$1" "$out" || true
}

check_wake() {
  local f="$1" records lines first
  records=$(awk 'END { print NR }' "$f")
  lines=$(wc -l < "$f" | tr -d ' ')
  if [[ "$records" != 1 || "$lines" -gt 1 ]]; then
    violation "$f" "the wake file is not exactly one line"
    return 0
  fi
  first=$(sed -n 1p "$f")
  if ! printf '%s\n' "$first" | LC_ALL=C grep -Eq "$WAKE_RE"; then
    violation "$f" "the line is not <cc-remote-approval run=<run_id> id=<approval_id>/>"
    return 0
  fi
  seen="${seen}wake "
}

# check_submit <applied> <submit> <hash>
check_submit() {
  local applied="$1" submit="$2" want="$3" got
  got=$(shasum -a 256 < "$submit" | awk '{ print $1 }')
  if [[ "$got" != "$want" ]]; then
    violation "$applied" "answers_sha256 is not the sha256 of $(basename "$submit") ($got)"
    return 0
  fi
  seen="${seen}pair-submit "
}

# frame_answers_hash <frame> — the gate's answers_sha256 for a transcript pair,
# or nothing when an answer is missing or is not a string.
frame_answers_hash() {
  local f="$1" ok
  ok=$(jq -rs '
    ([.[0].message.content[]? | select(type == "object" and .type == "tool_use" and .name == "AskUserQuestion")
      | .input.questions] | first) as $qs
    | .[1].toolUseResult.answers as $a
    | if ($qs | type) == "array" and ($a | type) == "object"
         and all($qs[]; (.question | type) == "string" and ($a[.question] | type) == "string")
      then "ok" else "bad" end' "$f" 2>/dev/null) || ok=bad
  [[ "$ok" == ok ]] || return 0
  jq -js '
    ([.[0].message.content[]? | select(type == "object" and .type == "tool_use" and .name == "AskUserQuestion")
      | .input.questions] | first) as $qs
    | .[1].toolUseResult.answers as $a
    | $qs[] | .question, "\u001f", $a[.question], "\u001e"' "$f" | shasum -a 256 | awk '{ print $1 }'
}

# check_frame <applied> <frame> <tool_use_id> <hash>
check_frame() {
  local applied="$1" f="$2" want_tid="$3" want="$4"
  local records lines l1 l2 n compact tid ok got appr
  records=$(awk 'END { print NR }' "$f")
  lines=$(wc -l < "$f" | tr -d ' ')
  if [[ "$records" != 2 || "$lines" != 2 ]]; then
    violation "$f" "the transcript pair is not exactly two newline-terminated lines"
    return 0
  fi
  l1=$(sed -n 1p "$f")
  l2=$(sed -n 2p "$f")
  for n in 1 2; do
    if [[ "$n" == 1 ]]; then compact="$l1"; else compact="$l2"; fi
    if ! ok=$(printf '%s' "$compact" | jq -c . 2>/dev/null); then
      violation "$f" "line $n is not JSON"
      return 0
    fi
    if [[ "$ok" != "$compact" ]]; then
      violation "$f" "line $n is not the compact serialization jq -c writes"
    fi
  done

  tid=$(printf '%s' "$l1" | jq -r '
    if .type != "assistant" then ""
    else [.message.content[]? | select(type == "object" and .type == "tool_use" and .name == "AskUserQuestion") | .id]
         | if length == 1 and (.[0] | type) == "string" then .[0] else "" end end')
  if [[ -z "$tid" ]]; then
    violation "$f" "line 1 is not an assistant line with exactly one AskUserQuestion tool_use"
    return 0
  fi
  for s in '"name":"AskUserQuestion"' "\"id\":\"$tid\"" '"type":"tool_use"'; do
    if [[ "$l1" != *"$s"* ]]; then
      violation "$f" "line 1 does not hold the gate's selector substring $s"
    fi
  done
  for s in "\"tool_use_id\":\"$tid\"" '"answers":{'; do
    if [[ "$l2" != *"$s"* ]]; then
      violation "$f" "line 2 does not hold the gate's selector substring $s"
    fi
  done
  ok=$(printf '%s' "$l2" | jq -r --arg tid "$tid" '
    [.message.content[]? | select(type == "object" and .type == "tool_result")] as $r
    | if .type != "user" then "line 2 type is not user"
      elif ($r | length) != 1 or $r[0].tool_use_id != $tid then "the tool_result does not join the AskUserQuestion tool_use"
      elif $r[0].is_error != false then "the tool_result is_error is not false"
      elif (.toolUseResult.answers | type) != "object" then "toolUseResult.answers is not an object"
      elif (.toolUseResult | has("annotations")) then "toolUseResult carries annotations, which a remote answer never fills"
      else "ok" end')
  if [[ "$ok" != ok ]]; then
    violation "$f" "$ok"
  fi
  if [[ "$tid" != "$want_tid" ]]; then
    violation "$applied" "tool_use_id is not the transcript's tool_use id $tid"
  fi

  # An approval question carries its approval id; the id is on both lines and
  # the answers map has a key holding it.
  appr=$(printf '%s' "$l1" | jq -r --arg re "$APPROVAL_Q_RE" '
    [.message.content[]? | select(type == "object" and .type == "tool_use") | .input.questions[]?
     | .question | select(type == "string" and test($re)) | capture("^승인 (?<id>[^ ]+) ").id] | first // ""')
  if [[ -n "$appr" ]]; then
    if [[ "$l2" != *"$appr"* ]] || ! printf '%s' "$l2" | jq -e --arg id "$appr" \
        '.toolUseResult.answers | keys | any(contains($id))' >/dev/null 2>&1; then
      violation "$f" "no toolUseResult.answers key holds the approval id $appr"
    fi
  fi

  got=$(frame_answers_hash "$f")
  if [[ -z "$got" ]]; then
    violation "$applied" "an answer is missing or is not a string, so answers_sha256 cannot match"
  elif [[ "$got" != "$want" ]]; then
    violation "$applied" "answers_sha256 does not match the transcript pair ($got)"
  fi
  if [[ -n "$appr" ]]; then
    seen="${seen}pair-frame-approval "
  else
    seen="${seen}pair-frame-question "
  fi
}

# check_applied <applied> — the record and its pair.
check_applied() {
  local f="$1" dir name out tid="" hash="" line submit frame
  out=$(run_prog "$f" "$applied_prog") || return 0
  report "$f" "$out" || true
  while IFS= read -r line; do
    case "$line" in
      'T '*) tid="${line#T }" ;;
      'H '*) hash="${line#H }" ;;
    esac
  done <<< "$out"
  dir=$(dirname "$f")
  name=$(basename "$f" .json)
  name="${name#applied-}"
  submit="$dir/submit-$name.txt"
  frame="$dir/frame-$name.jsonl"
  if [[ -f "$submit" && -f "$frame" ]]; then
    violation "$f" "both submit-$name.txt and frame-$name.jsonl exist; a record has one pair"
  elif [[ -f "$submit" ]]; then
    check_submit "$f" "$submit" "$hash"
  elif [[ -f "$frame" ]]; then
    check_frame "$f" "$frame" "$tid" "$hash"
  else
    violation "$f" "no submit-$name.txt or frame-$name.jsonl pair beside it"
  fi
}

# partner <file> <prefix> <suffix> — the applied record beside a pair file.
partner() {
  local name
  name=$(basename "$1" "$3")
  printf '%s/applied-%s.json' "$(dirname "$1")" "${name#"$2"}"
}

coverage=0
if [[ ${#files[@]} -eq 0 ]]; then
  coverage=1
  if [[ ! -d "$fixtures" ]]; then
    echo "FAIL: fixtures directory missing: $fixtures" >&2
    fail=1
  else
    for f in "$fixtures"/*; do
      [[ -f "$f" ]] && files+=("$f")
    done
    if [[ ${#files[@]} -eq 0 ]]; then
      echo "FAIL: no fixtures under $fixtures" >&2
      fail=1
    fi
  fi
fi

for f in ${files[@]+"${files[@]}"}; do
  checked=$((checked + 1))
  if [[ ! -f "$f" ]]; then
    violation "$f" "not a file"
    continue
  fi
  base=$(basename "$f")
  case "$base" in
    envelope-*.json) check_envelope "$f" ;;
    picked-*.json) check_picked "$f" ;;
    applied-*.json) check_applied "$f" ;;
    wake-*.txt) check_wake "$f" ;;
    submit-*.txt | frame-*.jsonl)
      case "$base" in
        submit-*) p=$(partner "$f" submit- .txt) ;;
        *) p=$(partner "$f" frame- .jsonl) ;;
      esac
      if [[ ! -f "$p" ]]; then
        violation "$f" "no $(basename "$p") beside it"
      elif [[ "$coverage" -eq 0 ]]; then
        check_applied "$p"
      fi
      ;;
    *) violation "$f" "the name does not start with a known fixture prefix" ;;
  esac
done

if [[ "$coverage" -eq 1 ]]; then
  for k in "${COVERAGE[@]}"; do
    case "$seen" in
      *" $k "*) ;;
      *)
        echo "FAIL: no fixture of kind $k under $fixtures" >&2
        fail=1
        ;;
    esac
  done
fi

if [[ "$fail" -ne 0 ]]; then
  echo "lint-remote-reply-schema: violations found" >&2
  exit 1
fi
echo "lint-remote-reply-schema: $checked file(s) checked, no violations"
exit 0
