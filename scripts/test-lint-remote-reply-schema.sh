#!/usr/bin/env bash
# Test scripts/lint-remote-reply-schema.sh against the remote reply fixtures.
#
# The fixtures pass as they are. Every other case copies them into its own
# scratch directory (`fresh`), breaks one thing, runs the lint over the copy
# with `--fixtures` and expects exit 1 with the reason the break should give.
#
# THE HASH IS COMPARED BYTE FOR BYTE. The general-question transcript pair
# carries an emoji, so one case prints the gate-side preimage with `jq -j`,
# checks with `od` that the emoji's UTF-8 bytes f0 9f 98 80 are in it, and
# checks that its sha256 equals both the sha256 of the same bytes written out
# with `printf` and the fixture record's answers_sha256.

set -uo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
LINT="$script_dir/lint-remote-reply-schema.sh"
DOC="$repo_root/plugins/cc-cmds/skills/_common/remote-reply.md"
SRC="$repo_root/tests/fixtures/remote-reply"

passed=0
failed=0
ok()   { passed=$((passed + 1)); printf 'PASS: %s\n' "$1"; }
bad()  { failed=$((failed + 1)); printf 'FAIL: %s — %s\n' "$1" "${2:-}" >&2; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got '$2', want '$3'"; fi; }

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not installed — the lint cannot read the records without it"
  echo "test-lint-remote-reply-schema: 0 passed, 0 failed"
  exit 0
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/cc-remote-reply.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

n=0
D=""
# fresh — a new copy of the fixtures in $D.
fresh() {
  n=$((n + 1))
  D="$WORK/c$n"
  mkdir "$D"
  cp "$SRC"/* "$D"/
}

# mutate <file> <jq filter> [jq option] — rewrite one fixture in $D.
mutate() {
  local f="$D/$1" filter="$2" tmp
  tmp=$(mktemp "$WORK/m.XXXXXX")
  jq ${3:-} "$filter" "$f" > "$tmp" && mv "$tmp" "$f"
}

# expect_fail <name> <reason> [lint arguments...] — exit 1 and the reason.
expect_fail() {
  local name="$1" reason="$2" rc=0 out
  shift 2
  if [[ $# -eq 0 ]]; then
    set -- --fixtures "$D"
  fi
  out=$(bash "$LINT" "$@" 2>&1) || rc=$?
  if [[ "$rc" -eq 1 && "$out" == *"$reason"* ]]; then
    ok "$name"
  else
    bad "$name" "rc=$rc, want 1 with '$reason'; output: $(printf '%s' "$out" | tr '\n' '|')"
  fi
}

# --- the fixtures as they are ---------------------------------------------

rc=0
out=$(bash "$LINT" 2>&1) || rc=$?
check "the fixtures pass" "$rc" 0
case "$out" in
  *"no violations"*) ok "the passing run says no violations" ;;
  *) bad "the passing run says no violations" "$out" ;;
esac

rc=0
out=$(bash "$LINT" "$SRC/envelope-approval.json" 2>&1) || rc=$?
check "one named file passes without the coverage check" "$rc" 0
case "$out" in
  *"1 file(s) checked"*) ok "a named file counts as one" ;;
  *) bad "a named file counts as one" "$out" ;;
esac

rc=0
bash "$LINT" "$SRC/frame-sopen.jsonl" >/dev/null 2>&1 || rc=$?
check "a named frame file is checked through its applied record" "$rc" 0

rc=0
bash "$LINT" --bogus >/dev/null 2>&1 || rc=$?
check "an unknown option exits 2" "$rc" 2

# --- the hash, byte for byte ------------------------------------------------

pre="$WORK/preimage"
jq -js '
  ([.[0].message.content[] | select(.type == "tool_use") | .input.questions] | first) as $qs
  | .[1].toolUseResult.answers as $a
  | $qs[] | .question, "\u001f", $a[.question], "\u001e"' "$SRC/frame-sopen.jsonl" > "$pre"
hex=$(od -An -tx1 "$pre" | tr -d ' \n')
case "$hex" in
  *f09f9880*) ok "the preimage holds the emoji's UTF-8 bytes" ;;
  *) bad "the preimage holds the emoji's UTF-8 bytes" "$hex" ;;
esac
gate_hash=$(shasum -a 256 < "$pre" | awk '{ print $1 }')
ref_hash=$(printf 'deploy now? \360\237\230\200\037yes\036run tests?\037later\036' | shasum -a 256 | awk '{ print $1 }')
rec_hash=$(jq -r .answers_sha256 "$SRC/applied-sopen.json")
check "the jq -j preimage hashes like the printf bytes" "$gate_hash" "$ref_hash"
check "the fixture record carries that hash" "$rec_hash" "$ref_hash"
form_hash=$(shasum -a 256 < "$SRC/submit-form.txt" | awk '{ print $1 }')
check "the form record carries the submit file's sha256" "$(jq -r .answers_sha256 "$SRC/applied-form.json")" "$form_hash"

# --- envelopes --------------------------------------------------------------

fresh; mutate envelope-auq-single.json '.extra = 1'
expect_fail "an unknown envelope key" "unknown key(s): extra"

fresh; mutate envelope-auq-single.json 'del(.event_id)'
expect_fail "a missing envelope key" "missing key(s): event_id"

fresh; mutate envelope-auq-single.json '.text = "자유 입력"'
expect_fail "an option envelope with text" "carries text or decision"

fresh; mutate envelope-approval.json 'del(.pickup_by_ms)'
expect_fail "a run-address envelope without pickup_by_ms" "lacks pickup_by_ms"

fresh; mutate envelope-auq-single.json '.pickup_by_ms = .expires_at_ms'
expect_fail "a session-address envelope with pickup_by_ms" "carries pickup_by_ms"

fresh; mutate envelope-auq-single.json '.schema = 2'
expect_fail "schema 2" "schema is not 1"

fresh; mutate envelope-auq-single.json '.reply_id = "host-b2.1793500000000.0a1b2c3d"'
expect_fail "a reply_id of another host" "reply_id is not"

fresh; mutate envelope-auq-single.json '.reply_id = "host-a1.1793500000000.0A1B2C3D"'
expect_fail "a reply_id with upper-case hex" "reply_id is not"

fresh; mutate envelope-auq-single.json '.event_id = "other.1793499990000.11223344"'
expect_fail "an event_id of another host" "event_id does not start with"

fresh; mutate envelope-auq-single.json '.kind = "text"'
expect_fail "kind text" "kind is not option"

fresh; mutate envelope-auq-single.json '.target.surface = "chat"'
expect_fail "an unknown surface" "target.surface is not one of"

fresh; mutate envelope-auq-single.json '.answers[0].labels = ["없는 선택지"]'
expect_fail "a label outside the options" "not byte-equal"

fresh; mutate envelope-approval.json '.answers[0].labels = ["보류"]'
expect_fail "an approval label outside target.options" "(target.options)"

fresh; mutate envelope-auq-single.json '.answers[0].labels = ["새 브랜치", "새 브랜치"]'
expect_fail "a single-select answer with two labels" "exactly one label"

fresh; mutate envelope-auq-multi.json '.answers[0].labels = ["시험", "시험"]'
expect_fail "a multi-select answer repeating a label" "repeats a label"

fresh; mutate envelope-auq-multi.json '.answers[0].labels = []'
expect_fail "a multi-select answer with no label" "has no label"

fresh; mutate envelope-auq-single.json '.answers = [.answers[1]]'
expect_fail "an answer missing for a question" "ascending question_index"

fresh; mutate envelope-auq-single.json '.answers = [.answers[1], .answers[0]]'
expect_fail "answers out of order" "ascending question_index"

fresh; mutate envelope-auq-multi.json '.target.questions[0].options[0].label = "린트, 시험" | .answers[0].labels = ["린트, 시험"]'
expect_fail "a multi-select label holding a comma and space" "holding \", \""

fresh; mutate envelope-auq-single.json '.target.questions[0].question += "\u001f"'
expect_fail "a question holding byte 0x1F" "0x1E or 0x1F"

fresh; mutate envelope-auq-single.json '.target.questions[1].question = .target.questions[0].question'
expect_fail "two auq questions with the same text" "the same text"

fresh; mutate envelope-auq-single.json '.target.questions[0].options[1].label = .target.questions[0].options[0].label'
expect_fail "two options with the same label" "the same label"

fresh; mutate envelope-approval.json '.target.question = "세그먼트 A 를 머지할까요?"'
expect_fail "an approval question without its approval id" "승인 <approval_id>"

fresh; mutate envelope-approval.json '.target.approval_id = "judg-0001"'
expect_fail "a malformed approval_id" "approval_id is malformed"

fresh; mutate envelope-auq-single.json '.provenance.sender = "tg 123"'
expect_fail "a sender with a space" "sender is malformed"

fresh; mutate envelope-auq-single.json '.provenance.extra = 1'
expect_fail "a fifth provenance key" "provenance does not have exactly"

fresh; mutate envelope-auq-single.json '.provenance.transport_ref = "a\nb"'
expect_fail "a transport_ref with a line break" "line break"

fresh; mutate envelope-auq-single.json '.expires_at_ms = .provenance.received_at_ms'
expect_fail "expires_at_ms not after received_at_ms" "expires_at_ms is not"

fresh; mutate envelope-approval.json '.pickup_by_ms = .expires_at_ms + 1'
expect_fail "pickup_by_ms after expires_at_ms" "pickup_by_ms is not in"

fresh; printf '{"schema":1}\n{"schema":1}\n' > "$D/envelope-auq-single.json"
expect_fail "two JSON values in one envelope" "exactly one JSON value"

# --- pick-up markers --------------------------------------------------------

fresh; mutate picked-plain.json '.apply_by_ms += 1'
expect_fail "apply_by_ms off picked_at_ms + 120000" "picked_at_ms + 120000"

fresh; mutate picked-woken.json '.woken_at_ms = .picked_at_ms - 1'
expect_fail "woken_at_ms before picked_at_ms" "woken_at_ms is not"

fresh; mutate picked-plain.json '.extra = 1'
expect_fail "an unknown marker key" "keys are not exactly"

# --- applied records and their pairs ----------------------------------------

fresh; mutate applied-form.json '.extra = 1'
expect_fail "a tenth applied record key" "nine applied record keys"

fresh; printf 'x' >> "$D/submit-form.txt"
expect_fail "a submit file that no longer hashes to the record" "not the sha256 of submit-form.txt"

fresh; mutate applied-sopen.json '.answers_sha256 = "abc"'
expect_fail "a short answers_sha256" "64 lowercase hex digits"

fresh; mutate frame-sopen.jsonl 'if .type == "user" then .toolUseResult.annotations = {} else . end' -c
expect_fail "a transcript pair with annotations" "carries annotations"

fresh; mutate frame-sopen.jsonl 'if .type == "user" then .message.content[0].is_error = true else . end' -c
expect_fail "a tool_result with is_error true" "is_error is not false"

fresh; mutate frame-sopen.jsonl 'if .type == "user" then .toolUseResult.answers["run tests?"] = 1 else . end' -c
expect_fail "a non-string answer" "is not a string"

fresh; mutate frame-sopen.jsonl 'if .type == "user" then .toolUseResult.answers["run tests?"] = "now" else . end' -c
expect_fail "an answer other than the recorded one" "does not match the transcript pair"

fresh; mutate frame-sopen.jsonl 'if .type == "user" then .message.content[0].tool_use_id = "toolu_other" else . end' -c
expect_fail "a tool_result joined to another tool_use" "tool_use_id"

fresh; mutate applied-sopen.json '.tool_use_id = "toolu_other"'
expect_fail "an applied record naming another tool_use" "tool_use_id is not the transcript's"

fresh; awk 'NR == 1 { sub(/"type":"assistant"/, "\"type\": \"assistant\"") } { print }' "$SRC/frame-sopen.jsonl" > "$D/frame-sopen.jsonl"
expect_fail "a transcript line that is not compact" "compact serialization"

fresh; printf '{}\n' >> "$D/frame-sopen.jsonl"
expect_fail "a transcript pair with a third line" "exactly two newline-terminated lines"

fresh; printf '%s' "$(cat "$SRC/frame-sopen.jsonl")" > "$D/frame-sopen.jsonl"
expect_fail "a transcript pair without its final newline" "exactly two newline-terminated lines"

fresh; cp "$SRC/frame-sopen.jsonl" "$D/frame-orphan.jsonl"
expect_fail "a transcript pair with no applied record" "no applied-orphan.json beside it"

fresh; cp "$SRC/submit-form.txt" "$D/submit-sopen.txt"
expect_fail "an applied record with two pairs" "a record has one pair"

fresh; rm "$D/frame-sopen.jsonl"
expect_fail "an applied record with no pair" "no submit-sopen.txt or frame-sopen.jsonl"

# --- the wake literal and file names ----------------------------------------

fresh; printf '<cc-remote-approval run=20261101-a5df83a0 id=judg-0001-1a2b3c4d/>\nextra\n' > "$D/wake-approval.txt"
expect_fail "a wake file with two lines" "not exactly one line"

fresh; printf '<cc-remote-approval run=20261101-a5df83a0 id=judg-0001/>\n' > "$D/wake-approval.txt"
expect_fail "a wake literal with a malformed id" "is not <cc-remote-approval"

fresh; printf ' <cc-remote-approval run=20261101-a5df83a0 id=judg-0001-1a2b3c4d/>\n' > "$D/wake-approval.txt"
expect_fail "a wake literal with a leading space" "is not <cc-remote-approval"

fresh; printf '{}\n' > "$D/notes.json"
expect_fail "a file of no known kind" "known fixture prefix"

# --- coverage and the document tables ---------------------------------------

fresh; rm "$D/envelope-approval.json"
expect_fail "no approval envelope" "no fixture of kind envelope-approval"

fresh; rm "$D/picked-woken.json"
expect_fail "no woken marker" "no fixture of kind picked-woken"

fresh; rm "$D/applied-sat.json" "$D/frame-sat.jsonl"
expect_fail "no approval transcript pair" "no fixture of kind pair-frame-approval"

fresh; rm "$D/wake-approval.txt"
expect_fail "no wake literal" "no fixture of kind wake"

drift="$WORK/doc-drift.md"
awk '
  /^## / { inside = ($0 == "## 봉투 키") }
  inside && index($0, "| `pickup_by_ms`") == 1 { next }
  { print }
' "$DOC" > "$drift"
if cmp -s "$DOC" "$drift"; then
  bad "the drift copy lost a row" "the pickup_by_ms row was not found under ## 봉투 키"
else
  expect_fail "an envelope key row missing from the document" "envelope key table" --doc "$drift"
fi

drift2="$WORK/doc-drift2.md"
awk '
  /^## / { inside = ($0 == "## 주소 규칙") }
  inside && index($0, "| `approval`") == 1 { sub(/r-<target\.run_id>/, "s-<target.run_id>") }
  { print }
' "$DOC" > "$drift2"
if cmp -s "$DOC" "$drift2"; then
  bad "the drift copy changed an address" "the approval row was not found under ## 주소 규칙"
else
  expect_fail "an address that differs in the document" "address rule table" --doc "$drift2"
fi

expect_fail "a missing rule document" "rule document missing" --doc "$WORK/none.md"

echo "test-lint-remote-reply-schema: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
