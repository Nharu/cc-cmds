#!/usr/bin/env bash
# Run the paired re-audit of the audit-reader model: does a sonnet-reader audit
# adopt as many findings as an opus-reader audit of the same document bytes?
#
# One call runs the whole experiment in six stages, and calling it again
# resumes where it stopped — every stage skips work whose output already
# exists:
#
#   1 select    pick five opus-reader first audits (quantile sample over
#               unique-defect count) and put every other candidate in the bin
#               of its nearest pick as a reserve (`예비 <n>-<k>`)
#               → selection.tsv
#   2 branches  two independent clones at commit C (`gate-sonnet`,
#               `gate-opus`), detached and without `origin`; the opus clone
#               carries one local commit that sets only the model cell of the
#               `audit-reader` row back to opus
#   3 prepare   per document: the main checkout's current bytes of the
#               owner-doc and their sha256; per audit (opus-1, sonnet, opus-2)
#               a target clone at the original run's base commit, the bytes
#               copied in, an audit-run manifest and its grant record, checked
#               by that branch clone's own check_manifest
#   4 audit     each audit run, opened through ITS BRANCH CLONE's gate so the
#               plugin pin is that branch's commit, driven by a script seat
#               that issues `act --kind router-shift` until the run's first
#               audit report carries both fences (`수집됨`) or the run has
#               ended; the run's manifest declares a cost ceiling below any
#               stage's cost, so the gate ends the run once the audit stage
#               has been costed and launches no further stage in it
#   5 collect   each first report copied to reports/<n>-<branch>.md, its
#               validity checked, one docs.tsv row per document
#   6 verdict   scripts/reader-model-compare.sh pairs → report.md
#
# Stages 4 and 5 run document slot by slot. A branch that turns invalid — a
# halt no fixed policy answers, an approval, a deadline park, a missing or
# unreadable report — stops the slot's remaining branches; the document's
# invalid row is written, its state is moved aside as an attempt, and the slot
# runs all three branches again on the next reserve of its bin. A slot whose
# reserves are used up stays invalid. No stage waits on a person.
#
# No model CLI is called here; billing happens only when a branch gate's `act`
# launches a stage. The experiment measures today's production path.
#
# Usage:
#   scripts/reader-model-pair-audit.sh [run] [--exp-id <id>] --budget-usd <N> [--repo <dir>] [--ref <commit>]
#   scripts/reader-model-pair-audit.sh run --dry-run [--exp-id <id>] [--ref <commit>]
#   scripts/reader-model-pair-audit.sh status --exp-id <id>
#   scripts/reader-model-pair-audit.sh --rerun-doc <n> --exp-id <id> --budget-usd <N>
#
#   --exp-id      YYYYMMDD-<8 hex>; created on the first call when absent,
#                 required by `status` and `--rerun-doc`
#   --budget-usd  required by every call that may start billed work, with no
#                 default: before each new run, spent + 150 must not exceed
#                 it, and before resuming an opened run spent must be below it;
#                 a stage whose stream has no result line yet counts as 150,
#                 and one that died before writing it keeps counting so
#   --dry-run     select, make the branches, prepare and check the manifests,
#                 then stop; never calls the gate's act
#   --rerun-doc   discard one document slot's state, attempts and records and
#                 run it again from `선정 <n>`
#   --repo        the main repository (default: this script's checkout)
#   --ref         commit C the branches are made from (default: HEAD of --repo);
#                 its `audit-reader` row must be sonnet
#
# Environment:
#   READER_EXP_STATE_ROOT  clones and run state
#                          (default ${HOME}/.local/state/cc-cmds/reader-model-exp)
#   READER_EXP_GATE        a gate that opens every branch's runs instead of the
#                          branch clone's own gate.sh — for tests only: the pin
#                          of a real run must come from the branch clone's gate
#   CC_CMDS_AUTOPILOT_AUTO_RESOLVE  0, off, false or no keeps the seat from
#                          answering a halt record by the fixed policy
#
# Exit codes:
#   0 — a verdict was written (`판정 불가` included), or a dry run finished
#   1 — failure
#   2 — usage error
#   4 — budget guard: the next billed step would exceed --budget-usd; the
#       slots not finished are invalid and a verdict was written. The same
#       command with a larger budget carries them on.
#
# Compatibility: bash 3.2 (macOS) — no associative arrays, no mapfile.
# Non-ASCII literals follow a `${var}` brace, never a bare `$var`.

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)

DOCS=5
RESERVE_RUN=150
# The `**비용 천장**` of every audit run. One `router-shift` call is not one
# shift: the gate's relay launches the successor shift inside the same call as
# soon as the audit stage ends, so a seat that checks between calls cannot stop
# a skeletal first audit from being carried on to a re-convergence and a
# re-audit. The ceiling is what stops it. The gate appends the run's `cost` row
# when a stage ends, before the relay launches the successor shift; that shift
# still runs, and its first gated act or exec finds the row at the ceiling and
# ends the run. From then on the run launches no stage and the relay no further
# shift. A ceiling below any stage's cost makes the audit stage the one that
# ends it, whether it wrote its report or halted or stopped at its limit. The
# call that ends the run is not refused itself, so this relies on the router
# reading the audit's stream through the gate before it routes a
# re-convergence, which its skill requires; a stage launched anyway is counted
# by `spent` at the run reserve until its stream has a result line.
RUN_CEILING_USD=0.01
# A run that declares a cost ceiling is not closed by its wall-clock deadline;
# the manifest still carries one because the field is required.
DEADLINE_SECONDS=14400
SEAT_MAX="${READER_EXP_SEAT_MAX:-500}"
TARGET_ALIAS="exp"
# Not a repository on any remote: a router that reaches for a remote fails
# instead of acting on the real one. The cutpoint `커밋` keeps the run from
# pushing at all.
TARGET_SLUG="local/reader-model-exp"
BRANCHES="opus-1 sonnet opus-2"
TIER_FILE="plugins/cc-cmds/skills/_common/team-model-tier.md"

FENCE_BEGIN='<!-- cc-design-audit-disclosure v1 begin -->'
FENCE_END='<!-- /cc-design-audit-disclosure v1 end -->'
SKEL_BEGIN='<!-- cc-design-audit-skeletal v1 begin -->'
SKEL_END='<!-- /cc-design-audit-skeletal v1 end -->'

usage() { echo "reader-model-pair-audit: $1" >&2; exit 2; }
die() { echo "reader-model-pair-audit: $1" >&2; exit 1; }
say() { echo "reader-model-pair-audit: $1"; }

# ---------- arguments --------------------------------------------------------

cmd="run"
exp_id=""
budget=""
repo=""
ref=""
rerun=""
dry=0

while (( $# > 0 )); do
  case "$1" in
    run|status) cmd="$1"; shift ;;
    --rerun-doc) rerun="${2:-}"; cmd="rerun"; shift 2 || usage "--rerun-doc needs a document number" ;;
    --dry-run) dry=1; shift ;;
    --exp-id) exp_id="${2:-}"; shift 2 || usage "--exp-id needs a value" ;;
    --budget-usd) budget="${2:-}"; shift 2 || usage "--budget-usd needs a value" ;;
    --repo) repo="${2:-}"; shift 2 || usage "--repo needs a value" ;;
    --ref) ref="${2:-}"; shift 2 || usage "--ref needs a value" ;;
    -h|--help) grep -E '^# ' "$0" | cut -c3-; exit 0 ;;
    *) usage "unknown argument: $1" ;;
  esac
done

[[ -n "$repo" ]] || repo=$(cd "$script_dir/.." && pwd)
[[ -d "$repo/.git" || -f "$repo/.git" ]] || usage "not a git checkout: $repo"
repo=$(cd "$repo" && pwd)

if [[ -n "$exp_id" && ! "$exp_id" =~ ^[0-9]{8}-[0-9a-f]{8}$ ]]; then
  usage "--exp-id must be YYYYMMDD-<8 hex>: $exp_id"
fi
if [[ -n "$budget" && ! "$budget" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
  usage "--budget-usd must be a number: $budget"
fi
case "$cmd" in
  status) [[ -n "$exp_id" ]] || usage "status needs --exp-id" ;;
  rerun)
    [[ -n "$exp_id" ]] || usage "--rerun-doc needs --exp-id"
    [[ "$rerun" =~ ^[1-9][0-9]*$ ]] && (( rerun <= DOCS )) || usage "--rerun-doc needs 1..${DOCS}: $rerun"
    (( dry == 0 )) || usage "--rerun-doc and --dry-run do not combine"
    ;;
esac
if [[ "$cmd" != "status" && "$dry" == "0" && -z "$budget" ]]; then
  usage "--budget-usd <N> is required for a call that may start billed work (no default)"
fi

STATE_ROOT="${READER_EXP_STATE_ROOT:-$HOME/.local/state/cc-cmds/reader-model-exp}"
RUN_ROOT="${XDG_STATE_HOME:-$HOME/.local/state}/cc-cmds/run"
COMPARE="$script_dir/reader-model-compare.sh"
# Set per branch before each seat call; see run_seat_or_stop.
GATE=""
GATE_OVERRIDE="${READER_EXP_GATE:-}"

# A variable inherited from a pipeline stage would make the gate read THIS
# shell as a seat of that run. The experiment's runs are runs of their own.
for v in $(compgen -e | grep '^CC_PIPELINE_' || true); do unset "$v"; done

if [[ -z "$exp_id" ]]; then
  [[ "$cmd" == "run" ]] || usage "--exp-id is required"
  exp_id="$(date -u +%Y%m%d)-$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
fi
EXP="$repo/docs/reader-model-pair-audit/$exp_id"
ST="$STATE_ROOT/$exp_id"

# ---------- small readers ----------------------------------------------------

# kv <file> <key> — the value of one key<TAB>value line.
kv() { [[ -f "$1" ]] && awk -F'\t' -v k="$2" '$1 == k { print substr($0, length(k) + 2); exit }' "$1" || true; }

# kv_set <file> <key> <value> — replace or append one key<TAB>value line.
kv_set() {
  local f="$1" tmp="$1.tmp.$$"
  touch "$f"
  awk -F'\t' -v k="$2" -v v="$3" 'BEGIN { OFS = "\t" } $1 == k { print k, v; done = 1; next } { print } END { if (!done) print k, v }' "$f" > "$tmp"
  mv "$tmp" "$f"
}

# kv_del <file> <key> — drop one key<TAB>value line.
kv_del() {
  [[ -f "$1" ]] || return 0
  local tmp="$1.tmp.$$"
  awk -F'\t' -v k="$2" '$1 != k' "$1" > "$tmp"
  mv "$tmp" "$1"
}

has_fence() { grep -qF -- "$FENCE_BEGIN" "$1"; }
has_skel() { grep -qF -- "$SKEL_BEGIN" "$1"; }

# fence_count <report> <line> — how many lines of the report begin with it.
fence_count() { awk -v l="$2" 'index($0, l) == 1 { n++ } END { print n + 0 }' "$1"; }

# hdr_field <file> <key> — `key=value;` from the machine header in the first lines.
hdr_field() {
  head -n 8 "$1" | grep -oE "$2=[^;]*" | head -n 1 | sed "s/^$2=//" || true
}

# bold_field <file> <key> — the value of a `**key**: value` line.
bold_field() {
  awk -v k="**$2**: " 'index($0, k) == 1 { print substr($0, length(k) + 1); exit }' "$1"
}

# report_fields <report> — the reader scripts/reader-model-compare.sh uses, one
# tab-separated line, `-` for an absent slot:
#   state why model unique rejected unremedied bytes reviewers sha256 skeletal synth freeze
# state is `ok`, `미상` (why names the failed pair check) or `울타리 없음`.
# Slots are read between the fences only; a fence present but not exactly one
# pair, or a `## 감사 개시` without exactly one `reader-model` line, reads unknown.
report_fields() {
  LC_ALL=C awk -v db="$FENCE_BEGIN" -v de="$FENCE_END" -v sb="$SKEL_BEGIN" -v se="$SKEL_END" '
    function grab(key, slot,   k, s) {
      k = "**" key "**: "
      if (index($0, k) == 1 && !(slot in v)) { s = substr($0, length(k) + 1); sub(/[[:space:]]+$/, "", s); v[slot] = s }
    }
    function f(slot) { return ((slot in v) && v[slot] != "") ? v[slot] : "-" }
    index($0, db) == 1 { ndb++; ind = 1; next }
    index($0, de) == 1 { nde++; ind = 0; next }
    index($0, sb) == 1 { nsb++; ins = 1; next }
    index($0, se) == 1 { nse++; ins = 0; next }
    /^## / { open = ($0 == "## 감사 개시") }
    open && match($0, /^(- )?(reader-model|\*\*reader-model\*\*): */) {
      nrm++; rm = substr($0, RLENGTH + 1); sub(/[[:space:]]+$/, "", rm)
    }
    fa == "" && match($0, /^(- )?(\*\*)?frozen-at(\*\*)?: */) { fa = substr($0, RLENGTH + 1); sub(/[[:space:]]+$/, "", fa) }
    ind { grab("고유 결함 수", "u"); grab("라우팅 — 기각", "r"); grab("미보강 잔여 수", "un"); grab("동결 문서 바이트", "b")
          grab("리뷰어 수", "rev"); grab("동결 문서 sha256", "sha"); grab("동결 시각", "at") }
    ins { grab("골격급 수", "k"); grab("합성 요구 골격급 수", "ks") }
    END {
      at = ("at" in v && v["at"] != "") ? v["at"] : fa
      if (at == "") at = "-"
      state = "ok"; why = "-"
      if (ndb + nde == 0) { state = "울타리 없음" }
      else if (ndb != 1 || nde != 1) { state = "미상"; why = "공시 울타리가 한 쌍이 아니다" }
      else if (nsb + nse > 0 && (nsb != 1 || nse != 1)) { state = "미상"; why = "골격급 울타리가 한 쌍이 아니다" }
      else if (nrm != 1) { state = "미상"; why = "reader-model 줄이 " (nrm + 0) "개다" }
      if (state != "ok") { printf "%s\t%s\t-\t-\t-\t-\t-\t-\t-\t-\t-\t%s\n", state, why, at; exit }
      sk = (nsb == 1) ? f("k") : "-"; sy = (nsb == 1) ? f("ks") : "-"
      printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", state, why, (rm == "" ? "-" : rm), \
        f("u"), f("r"), f("un"), f("b"), f("rev"), f("sha"), sk, sy, at
    }' "$1"
}

# iso_epoch <ISO 8601 with Z or ±HH:MM> — epoch seconds, empty when unparsable.
iso_epoch() {
  jq -rn --arg s "$1" '
    $s
    | if test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(Z|[+-][0-9]{2}:[0-9]{2})$") then
        ((.[0:19] + "Z") | fromdateiso8601) as $t
        | if .[19:] == "Z" then $t
          else ((.[20:22] | tonumber) * 3600 + (.[23:25] | tonumber) * 60) as $o
            | if .[19:20] == "+" then $t - $o else $t + $o end
          end
      else empty end' 2>/dev/null || true
}

epoch_iso() { jq -rn --argjson e "$1" '$e | todate'; }
now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

sha_of() { shasum -a 256 "$1" | cut -d' ' -f1; }

gen_run_id() { printf '%s-%s' "$(date -u +%Y%m%d)" "$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"; }

# report_name <document key> — the name the audit skill gives a document's
# report. Later audits of the same document follow no fixed naming, so the
# name alone does not tell the first audit.
report_name() { local k="${1%.md}"; printf '%s.md' "$(printf '%s' "$k" | tr '/' '-')"; }

# is_reader_copy <file name> — a reader's witness copy, not a lead report. The
# tail decides, so a lead report whose slug carries `reader-` stays.
is_reader_copy() { [[ "$1" =~ [.-]reader-[0-9]+(\.fanout)?\.md$ ]]; }

# freeze_at <report> — the disclosure block's 동결 시각, else the opening's
# `frozen-at` line in any of its four spellings.
freeze_at() { report_fields "$1" | awk -F'\t' '{ print ($12 == "-" ? "" : $12) }'; }

# audit_index <reports dir> — one line per report, reader copies left out:
# name, owner-doc, freeze epoch (empty when unreadable).
audit_index() {
  local r name
  find "$1" -maxdepth 1 -name '*.md' 2>/dev/null | LC_ALL=C sort | while IFS= read -r r; do
    name=$(basename "$r")
    if is_reader_copy "$name"; then continue; fi
    printf '%s\t%s\t%s\n' "$name" "$(hdr_field "$r" owner-doc)" "$(iso_epoch "$(freeze_at "$r")")"
  done
}

# first_audit <index> <owner-doc> — the name of the document's first audit:
# the report frozen earliest, with or without its block, ties broken by name.
# The name decides only when the report under report_name has no readable
# freeze time, because then the times cannot be compared. Empty when the
# document has no report.
first_audit() {
  awk -F'\t' -v o="$2" -v nm="$(report_name "$2")" '
    $2 != o { next }
    $1 == nm && $3 == "" { fallback = 1 }
    $3 != "" && (bn == "" || $3 + 0 < best || ($3 + 0 == best && $1 < bn)) { best = $3 + 0; bn = $1 }
    END { print (fallback ? nm : bn) }' "$1"
}

# tier_model <tier file> — the model cell of the `audit-reader` row.
tier_model() {
  awk 'index($0, "| `audit-reader` |") == 1 { n = split($0, c, "|"); s = c[n - 1]; gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); print s; exit }' "$1"
}

# ---------- cost guard -------------------------------------------------------

# spent — every top-level `result` line of every run this experiment opened.
# Summing all result lines over-counts a resumed session; for a guard that is
# the safe direction. A stage stream with no result line is a stage still
# running (or one that died before its result), and its cost is not on disk
# yet, so it counts as the whole run reserve. Shift streams (`shift-<n>.json`)
# count their result lines only: no shift is live when the guard reads.
spent() {
  {
    if [[ -f "$ST/runs.list" ]]; then
      local rid f costs
      while IFS= read -r rid; do
        [[ -n "$rid" ]] || continue
        for f in "$RUN_ROOT/$rid"/log/*.json; do
          [[ -f "$f" ]] || continue
          costs=$(jq -R 'fromjson? | select(type == "object" and .type == "result") | (.total_cost_usd // 0)' "$f" 2>/dev/null || true)
          if [[ -z "$costs" ]]; then
            case "$(basename "$f")" in shift-*) ;; *) echo "$RESERVE_RUN" ;; esac
          else
            printf '%s\n' "$costs"
          fi
        done
      done < "$ST/runs.list"
    fi
  } | awk '{ s += $1 } END { printf "%.4f", s + 0 }'
}

# guard <reserve> <what> — before a billed step that could pass the budget,
# close the experiment on the budget (budget_close, exit 4).
guard() {
  local s msg
  s=$(spent)
  if awk -v s="$s" -v r="$1" -v b="$budget" 'BEGIN { exit !(s + r > b) }'; then
    msg="budget guard — spent ${s} + reserve $1 > budget ${budget}; not starting $2"
    echo "reader-model-pair-audit: ${msg}" >&2
    budget_close "$msg"
  fi
}

# guard_resume <what> — the same, before resuming an opened run once the
# spent amount has reached the budget. Its reserve was taken when it was
# opened.
guard_resume() {
  local s msg
  s=$(spent)
  if awk -v s="$s" -v b="$budget" 'BEGIN { exit !(s >= b) }'; then
    msg="budget guard — spent ${s} ≥ budget ${budget}; not resuming $1"
    echo "reader-model-pair-audit: ${msg}" >&2
    budget_close "$msg"
  fi
}

# docs_row_get <n> — document n's docs.tsv row, empty without one.
docs_row_get() { [[ -f "$EXP/docs.tsv" ]] && awk -F'\t' -v n="$1" 'NR > 1 && $1 == n { print; exit }' "$EXP/docs.tsv" || true; }

# docs_row_put <n> <row|""> — replace document n's docs.tsv row (drop it when
# the row is empty), the rows kept in n order.
docs_row_put() {
  local dt="$EXP/docs.tsv"
  [[ -f "$dt" ]] || printf 'n\towner-doc\t입력 sha256\topus-1\tsonnet\topus-2\t사유\n' > "$dt"
  {
    head -n 1 "$dt"
    { tail -n +2 "$dt" | awk -F'\t' -v n="$1" '$1 != n'
      [[ -z "$2" ]] || printf '%s\n' "$2"
    } | LC_ALL=C sort -t "$(printf '\t')" -k1,1n
  } > "$dt.tmp"
  mv "$dt.tmp" "$dt"
}

# slot_done <n> — the document slot needs no further work: collected, or
# invalid with its reserves used up.
slot_done() {
  local f="$ST/doc-$1/doc.state"
  if [[ "$(kv "$f" status)" == "무효" ]]; then [[ "$(kv "$f" exhausted)" == "1" ]]; return; fi
  [[ "$(kv "$f" status)" == "수집 완료" ]]
}

# budget_close <refusal> — every slot not finished gets an invalid docs.tsv row
# under `예산 상한 — <refusal>`, remembering what it was in budget_stop*, the
# verdict is written, and the call ends with exit 4. budget_restore undoes the
# marks on the next call, so a larger budget carries the slots on.
budget_close() {
  local why="예산 상한 — $1" n ds row
  for n in $(seq 1 "$DOCS"); do
    ds="$ST/doc-$n"
    slot_done "$n" && continue
    [[ -n "$(kv "$ds/doc.state" budget_stop)" ]] && continue
    mkdir -p "$ds"
    row=$(docs_row_get "$n")
    kv_set "$ds/doc.state" budget_stop "$(kv "$ds/doc.state" status)"
    kv_set "$ds/doc.state" budget_stop_why "$(kv "$ds/doc.state" invalid_reason)"
    kv_set "$ds/doc.state" budget_stop_row "${row:--}"
    docs_row_put "$n" "$(printf '%s\t%s\t%s\t무효\t무효\t무효\t%s' "$n" "$(kv "$ds/doc.state" doc)" "$(kv "$ds/doc.state" input_sha)" "$why")"
    kv_set "$ds/doc.state" status "무효"
    kv_set "$ds/doc.state" invalid_reason "$why"
    say "document ${n}: invalid — ${why}"
  done
  bash "$COMPARE" pairs --exp "$EXP" || die "reader-model-compare pairs failed"
  say "$(tail -n 1 "$EXP/report.md") → $EXP/report.md (closed on the budget; call again with a larger --budget-usd to carry on)"
  exit 4
}

# budget_restore — put back every slot budget_close marked.
budget_restore() {
  local n ds prev why row
  for n in $(seq 1 "$DOCS"); do
    ds="$ST/doc-$n"
    prev=$(kv "$ds/doc.state" budget_stop)
    [[ -n "$prev" ]] || continue
    why=$(kv "$ds/doc.state" budget_stop_why); row=$(kv "$ds/doc.state" budget_stop_row)
    kv_set "$ds/doc.state" status "$prev"
    if [[ -n "$why" ]]; then kv_set "$ds/doc.state" invalid_reason "$why"; else kv_del "$ds/doc.state" invalid_reason; fi
    if [[ "$row" == "-" ]]; then docs_row_put "$n" ""; else docs_row_put "$n" "$row"; fi
    kv_del "$ds/doc.state" budget_stop; kv_del "$ds/doc.state" budget_stop_why; kv_del "$ds/doc.state" budget_stop_row
  done
}

# ---------- stage 1: select --------------------------------------------------

select_docs() {
  local sel="$EXP/selection.tsv"
  [[ -f "$sel" ]] && return 0
  local ar="$repo/docs/design-audit" pr="$repo/docs/pipeline-run"
  [[ -d "$ar" ]] || die "no reports directory: $ar"

  # Index of every manifest once: id, owner-doc, kickoff epoch, design ok.
  local idx="$EXP/.manifests.tsv" m id ow ko ke led ok
  : > "$idx"
  for m in "$pr"/*.plan.md; do
    [[ -f "$m" ]] || continue
    id=$(basename "$m" .plan.md)
    ow=$(hdr_field "$m" owner-doc)
    ko=$(bold_field "$m" '킥오프 일시')
    ke=$(iso_epoch "$ko")
    led="$pr/$id.md"
    ok=0
    if [[ -f "$led" ]] && grep -E '^- `stage-result` ' "$led" | grep -F '| 종류=design |' \
         | grep -qE '\| 종단 부류=정상 완료( \||$)'; then ok=1; fi
    printf '%s\t%s\t%s\t%s\n' "$id" "$ow" "${ke:-}" "$ok" >> "$idx"
  done

  local aidx="$EXP/.audits.tsv"
  audit_index "$ar" > "$aidx"

  local rows="$EXP/.rows.tsv" r name owner first fe why run base tdoc tree pre nfz
  local st fwhy model u rest
  : > "$rows"
  while IFS= read -r r; do
    name=$(basename "$r")
    if is_reader_copy "$name"; then continue; fi
    owner=$(hdr_field "$r" owner-doc)
    IFS='	' read -r st fwhy model u rest <<<"$(report_fields "$r")"
    fe=$(iso_epoch "$(freeze_at "$r")")
    why=""; run="-"; base="-"; first=""
    [[ -z "$owner" ]] || first=$(first_audit "$aidx" "$owner")
    # A report without the block stays on record: when it is a first audit
    # that parked, it is what makes the later re-audit not the first one.
    if [[ "$st" == "울타리 없음" ]]; then why="공시 v1 울타리가 없다"
    elif [[ "$st" != "ok" ]]; then why="${fwhy} (모든 칸 미상)"
    elif [[ "$model" != "opus" ]]; then why="reader-model 이 opus 가 아니다 (${model})"
    elif [[ -z "$fe" ]]; then why="동결 시각을 읽을 수 없다"
    elif [[ ! "$u" =~ ^[0-9]+$ ]]; then why="고유 결함 수를 읽을 수 없다"
    elif [[ -z "$owner" ]]; then why="owner-doc= 이 없다"
    # Any report of the same document frozen earlier, with or without its
    # block and whatever its name, makes this one a re-audit.
    elif [[ -n "$first" && "$name" != "$first" ]]; then why="같은 owner-doc 의 첫 감사 보고서 ${first} 가 따로 있다 (재감사)"
    fi
    if [[ -z "$why" ]]; then
      tdoc="$repo/$owner"
      if [[ ! -f "$tdoc" ]]; then why="owner-doc 이 메인 체크아웃에 없다"
      else
        nfz=$(grep -cx '\*\*상태\*\*: 동결됨' "$tdoc" || true)
        [[ "$nfz" == "1" ]] || why="**상태**: 동결됨 줄이 ${nfz}개다"
      fi
    fi
    if [[ -z "$why" ]]; then
      run=$(awk -F'\t' -v o="$owner" -v f="$fe" '$2 == o && $4 == 1 && $3 != "" && $3 < f && $3 > best { best = $3; id = $1 } END { print id }' "$idx")
      if [[ -z "$run" ]]; then run="-"; why="원 런이 없다 (같은 owner-doc · 설계 정상 완료 · 동결 시각 이전 킥오프)"; fi
    fi
    if [[ -z "$why" ]]; then
      base=$(grep -m 1 -E '^- `run` ' "$pr/$run.md" | tr '|' '\n' | sed -n 's/^ *판본=//p' | sed 's/[[:space:]]*$//' || true)
      if [[ ! "$base" =~ ^[0-9a-f]{40}$ ]]; then why="원장 run 행에 판본= 이 없다"; base="-"
      elif ! ( cd "$repo" && git cat-file -e "${base}^{commit}" 2>/dev/null ); then why="기준 커밋이 저장소에 없다"
      else
        tree=$(bold_field "$tdoc" '기준 트리')
        pre=$(printf '%s\n' $tree | grep -m 1 -E '^[0-9a-f]{7,40}$' || true)
        if [[ -n "$pre" && "${base#"$pre"}" == "$base" ]]; then why="기준 트리 ${pre} 가 판본= 과 다르다"; fi
      fi
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "${owner:--}" "${fe:-}" "${u:--}" "$run" "$base" "${why:-}" >> "$rows"
  done < <(find "$ar" -maxdepth 1 -name '*.md' | LC_ALL=C sort)

  # The first audit per owner-doc: the earliest freeze among the candidates.
  local keep="$EXP/.keep.tsv"
  awk -F'\t' '$7 == "" { if (!($2 in best) || $3 < best[$2] || ($3 == best[$2] && $1 < nm[$2])) { best[$2] = $3; nm[$2] = $1 } }
    END { for (o in nm) print nm[o] }' "$rows" | LC_ALL=C sort > "$keep"

  local cands m_ j
  cands=$(awk -F'\t' 'NR == FNR { k[$1] = 1; next } $7 == "" && ($1 in k) { print $4 "\t" $1 }' "$keep" "$rows" \
    | LC_ALL=C sort -t "$(printf '\t')" -k1,1n -k2,2)
  m_=$(printf '%s' "$cands" | grep -c . || true)
  # picks: name<TAB>disposition. The five quantile positions are `선정 <j+1>`;
  # every other candidate goes to the bin of its nearest position (a tie goes
  # to the smaller j) and is `예비 <j+1>-<k>`, k counting up by distance, then
  # by rank.
  local picks=""
  if (( m_ >= DOCS )); then
    picks=$(printf '%s\n' "$cands" | awk -F'\t' -v m="$m_" -v p="$DOCS" '
      { nm[NR - 1] = $2 }
      END {
        for (j = 0; j < p; j++) { pos[j] = int((m - 1) * j / (p - 1) + 0.5); used[pos[j]] = 1; print nm[pos[j]] "\t선정 " (j + 1) }
        for (i = 0; i < m; i++) {
          if (i in used) continue
          bd = -1
          for (j = 0; j < p; j++) { d = i - pos[j]; if (d < 0) d = -d; if (bd < 0 || d < bd) { bd = d; bin[i] = j } }
          dist[i] = bd
        }
        for (j = 0; j < p; j++) {
          k = 0
          for (d = 1; d < m; d++) for (i = 0; i < m; i++) if (!(i in used) && bin[i] == j && dist[i] == d) { k++; print nm[i] "\t예비 " (j + 1) "-" k }
        }
      }')
  fi

  {
    printf '보고서\towner-doc\t동결 시각(UTC)\t고유 결함 수\t원 런\t기준 커밋\t처분\t사유\n'
    awk -F'\t' -v OFS='\t' 'FILENAME == ARGV[1] { k[$1] = 1; next }
      FILENAME == ARGV[2] { if ($1 != "") p[$1] = $2; next }
      {
        if ($7 != "") { d = "제외"; w = $7 }
        else if (!($1 in k)) { d = "제외"; w = "같은 owner-doc 의 더 이른 감사가 있다" }
        else if ($1 in p) { d = p[$1]; w = "-" }
        else { d = "후보"; w = "-" }
        print $1, $2, ($3 == "" ? "-" : $3), $4, $5, $6, d, w
      }' "$keep" <(printf '%s' "$picks") "$rows"
  } > "$sel.tmp"
  # Render the epoch column as UTC ISO.
  {
    head -n 1 "$sel.tmp"
    tail -n +2 "$sel.tmp" | while IFS='	' read -r c1 c2 c3 c4 c5 c6 c7 c8; do
      [[ -n "$c3" && "$c3" != "-" ]] && c3=$(epoch_iso "$c3")
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$c1" "$c2" "${c3:--}" "$c4" "$c5" "$c6" "$c7" "$c8"
    done
  } > "$sel"
  rm -f "$sel.tmp" "$rows" "$keep" "$idx" "$aidx"

  if (( m_ < DOCS )); then
    write_short_report "후보가 ${m_}건이다 — 선정 규칙은 ${DOCS}건을 요구한다 (후보 부족)"
    say "candidates: ${m_} < ${DOCS}; verdict 판정 불가 written to $EXP/report.md"
    exit 0
  fi
  say "selected ${DOCS} of ${m_} candidates → $sel"
}

write_short_report() {
  cat > "$EXP/report.md" <<EOF
# 판독자 모델 쌍 재감사 판정 보고서

- 실험: ${exp_id}

## 판정

**판정**: 판정 불가

- $1

# verdict: 판정 불가
EOF
}

# sample_row <disposition> — the selection.tsv row whose 처분 is
# `선정 <n>` or `예비 <n>-<k>`.
sample_row() { awk -F'\t' -v d="$1" '$7 == d { print; exit }' "$EXP/selection.tsv"; }

# selected_row <n> — the selection.tsv row of document n's main sample.
selected_row() { sample_row "선정 ${1}"; }

# ---------- stage 2: branches ------------------------------------------------

# gate_clone <model> — the branch clone whose gate opens that model's runs.
gate_clone() { printf '%s/gate-%s' "$ST" "$1"; }

make_branches() {
  local bs="$ST/branches.state"
  [[ "$(kv "$bs" ready)" == "1" ]] && return 0
  local c gs go oc got
  c=$(cd "$repo" && git rev-parse --verify --quiet "${ref:-HEAD}^{commit}") || die "--ref is not a commit of $repo: ${ref:-HEAD}"
  gs=$(gate_clone sonnet); go=$(gate_clone opus)
  rm -rf "$gs" "$go"
  mkdir -p "$ST"
  local d
  for d in "$gs" "$go"; do
    git clone --quiet --no-hardlinks "$repo" "$d" || die "branch clone failed: $d"
    # No origin: the pin cannot reach for a remote tip and takes this
    # clone's local HEAD, a clean tree.
    ( cd "$d" && git checkout --quiet --detach "$c" && git remote remove origin ) || die "detaching $d at $c failed"
  done
  got=$(tier_model "$gs/$TIER_FILE")
  if [[ "$got" != "sonnet" ]]; then
    rm -rf "$gs" "$go"
    die "the audit-reader row of commit ${c:0:12} is '${got:-없음}', not sonnet — the experiment compares a sonnet row against its opus restoration"
  fi
  # The opus branch: the model cell of that one row back to opus, nothing else,
  # as one local commit with a fixed author and date so its id is reproducible.
  awk 'index($0, "| `audit-reader` |") == 1 { n = split($0, c, "|"); c[n-1] = " opus "; s = ""; for (i = 1; i < n; i++) s = s c[i] "|"; print s; next } { print }' \
    "$go/$TIER_FILE" > "$go/$TIER_FILE.new" && mv "$go/$TIER_FILE.new" "$go/$TIER_FILE"
  ( cd "$go" && git add -- "$TIER_FILE" \
    && GIT_AUTHOR_NAME=reader-model-pair-audit GIT_AUTHOR_EMAIL=reader-model-pair-audit@localhost \
       GIT_AUTHOR_DATE=2026-01-01T00:00:00Z GIT_COMMITTER_NAME=reader-model-pair-audit \
       GIT_COMMITTER_EMAIL=reader-model-pair-audit@localhost GIT_COMMITTER_DATE=2026-01-01T00:00:00Z \
       git commit --quiet --no-verify -m "experiment: audit-reader row back to opus" ) || die "the opus branch commit failed"
  oc=$(cd "$go" && git rev-parse HEAD)
  got=$(cd "$go" && git diff --numstat "$c" "$oc")
  if [[ "$got" != "1	1	${TIER_FILE}" ]]; then
    die "the two branch commits differ by more than the one row: $(printf '%s' "$got" | tr '\n' ' ')"
  fi
  kv_set "$bs" c "$c"
  kv_set "$bs" sonnet_commit "$c"
  kv_set "$bs" opus_commit "$oc"
  kv_set "$bs" ready 1
  say "branches: sonnet ${c:0:12} · opus ${oc:0:12} (one row apart)"
}

branch_commit() { kv "$ST/branches.state" "$1_commit"; }

# ---------- stage 3: prepare -------------------------------------------------

# manifest_check <manifest> <clone> <run.sh> — the driver's own check, sourced
# from the branch clone's run.sh; never a stub.
manifest_check() {
  ( cd "$2" && CC_ORCH_SOURCE_ONLY=1 && . "$3" && MANIFEST="$1" && check_manifest )
}

manifest_digests() {
  ( cd "$2" && CC_ORCH_SOURCE_ONLY=1 && . "$3" && MANIFEST="$1" \
    && printf '%s\t%s\n' "$(canonical_targets | shasum -a 256 | cut -d' ' -f1)" "$(binding_set_bytes | shasum -a 256 | cut -d' ' -f1)" )
}

# write_run_files <n> <branch> — the manifest and the grant of one audit run,
# digests filled and checked by the branch's driver. Rewritten only while the
# run has not started, so a dry run's clock is never inherited by the real one.
write_run_files() {
  local n="$1" br="$2" ds="$ST/doc-$1" bst="$ST/doc-$1/$2.state" clone rid doc m g model runsh
  clone=$(kv "$bst" clone); rid=$(kv "$bst" run)
  doc=$(kv "$ds/doc.state" doc)
  model="${br%-*}"
  runsh="$(gate_clone "$model")/plugins/cc-cmds/orchestrator/run.sh"
  m="$clone/docs/pipeline-run/$rid.plan.md"
  g="$clone/docs/pipeline-grant/$rid.md"
  local now dl docsha confirm intent plan goal clause
  now=$(now_iso)
  dl=$(epoch_iso $(( $(date -u +%s) + DEADLINE_SECONDS )))
  confirm="reader-model-pair-audit ${exp_id} 문서 ${n} ${br} — 실행 스크립트가 연 실험 런"
  goal="설계 감사가 ${doc} 의 보고서를 공시 블록과 함께 남긴다"
  clause="감사 보고서가 공시 블록과 함께 남았다"
  docsha=$(sha_of "$clone/$doc")
  intent="동결된 ${doc} 를 설계 감사한다 (reader-model-pair-audit ${exp_id} 문서 ${n} ${br})"
  plan=$(jq -n --arg ak "$doc" --arg doc "$doc" --arg exp "$exp_id" --arg n "$n" --arg br "$br" \
    --arg alias "$TARGET_ALIAS" --arg slug "$TARGET_SLUG" '{
      anchor_kind: "doc", anchor_key: $ak, entry_skill: "design-audit",
      entry_rationale: ("판독자 모델 쌍 재감사 " + $exp + " 문서 " + $n + " " + $br + " — 동결된 " + $doc + " 를 감사한다."),
      design_required: false,
      design_rationale: "문서는 원 런이 동결했고 실험은 그 바이트를 그대로 감사한다.",
      design_tier: "solo", design_tier_judged: "solo", design_heavy_reasons: [], estimated_files: 0,
      design_tier_rationale: "설계 스텝이 없다.",
      design_scope: "single", design_scope_rationale: "단일 문서다.",
      work_class: "unknown", work_class_rationale: "감사까지만 돈다.",
      targets: [{alias: $alias, remote_slug: $slug, home: true, why: "기준 커밋에서 만든 실험 클론"}],
      steps: [{id: "A1", skill: "design-audit", summary: "동결 문서 감사", depends_on: []}],
      unresolved: [], notes: "reader-model-pair-audit 가 쓴 실험 런 매니페스트"
    }')
  local cg
  cg=$(cd "$clone" && git rev-parse --path-format=absolute --git-common-dir)
  mkdir -p "$clone/docs/pipeline-run" "$clone/docs/pipeline-grant"
  {
    printf '# 파이프라인 런 매니페스트 — %s\n' "$rid"
    printf '<!-- cc-run-manifest v1; writer=autopilot; reader=orchestrator; run-id=%s;\n' "$rid"
    printf '     anchor-kind=doc; anchor-key=%s;\n' "$doc"
    printf '     owner-doc=%s; origin-worktree=%s;\n' "$doc" "$clone"
    printf '     NOT a design doc; mechanism-local, never staged by a skill -->\n\n'
    printf '## 런 정체\n**킥오프 일시**: %s\n**런 id**: %s\n**앵커 종류**: doc\n**앵커 키**: %s\n**사용자 확인 문면**: %s\n\n' \
      "$now" "$rid" "$doc" "$confirm"
    printf '## 의도\n```text\n%s\n```\n\n' "$intent"
    printf '## 대상\n**대상 맵 다이제스트**: @TMD@\n'
    printf -- '- `target` | 별칭=%s | 메인 워크트리=%s | 공통 git 디렉터리=%s | 베이스 브랜치=exp-base | 홈=예 | 원격 슬러그=%s | 절단점=커밋 | 말단 행위 상한=없음\n\n' \
      "$TARGET_ALIAS" "$clone" "$cg" "$TARGET_SLUG"
    printf '## 요소\n**설계 문서**: %s\n**설계 문서 전체 sha256**: %s\n**리뷰 대상**: (없음)\n**적용 지점**: (없음)\n**적용 프로브**: (없음)\n**적용 주체**: (해당 없음)\n\n' \
      "$doc" "$docsha"
    printf '## 실행 계획\n**승인 문면**: reader-model-pair-audit 고정 계획\n```json\n%s\n```\n\n' "$plan"
    printf '## 인가\n**구속 다이제스트**: @BD@\n**런 최대 절단점**: 커밋\n**종료 지점**: %s\n**벽시계 마감**: %s\n' "$goal" "$dl"
    printf '**비용 천장**: %s\n**무진전 상한**: 없음\n**시각 정합 마커**: 없음\n**사다리 가용 단 수**: 4\n**미선언 상황 처분**: park\n' "$RUN_CEILING_USD"
    printf -- '- `종료 절` | id=C1 | 문면=%s\n' "$clause"
  } > "$m.tmp"
  local dg tmd bd
  dg=$(manifest_digests "$m.tmp" "$clone" "$runsh") || die "document ${n} ${br}: digest computation failed for $m"
  tmd=${dg%%	*}; bd=${dg##*	}
  sed -e "s/@TMD@/$tmd/" -e "s/@BD@/$bd/" "$m.tmp" > "$m"
  rm -f "$m.tmp"
  {
    printf '# 파이프라인 인가 기록 — %s\n' "$rid"
    printf '<!-- cc-pipeline-grant v1; writer=autopilot; reader=orchestrator; owner-doc=%s; origin-worktree=%s; NOT a design doc; mechanism-local, never staged by a skill -->\n\n' "$doc" "$clone"
    printf '## 인가 %s\n**인가 일시**: %s\n**종료 지점**: %s\n**권한 절단점**: 커밋\n**말단 행위 상한**: 없음\n**직렬 웨이브 고지**: 해당 없음\n**시각 정합 마커**: 없음\n**사용자 확인 문면**: %s\n**설계 문서 전체 sha256**: %s\n**보고서**: %s\n' \
      "$rid" "$now" "$goal" "$confirm" "$docsha" "$clone/docs/pipeline-run/$rid.md"
  } > "$g"
  if ! manifest_check "$m" "$clone" "$runsh" > "$ST/doc-$n/check-$br.log" 2>&1; then
    cat "$ST/doc-$n/check-$br.log" >&2
    die "document ${n} ${br}: the audit manifest fails check_manifest — $m"
  fi
  kv_set "$bst" manifest "$m"
}

# target_clone <dir> <base> — an independent clone at the base commit with
# nothing past it: the stages' worktrees share its refs, and git history is a
# leak. Only exp-base is left, with no remote, and the rest is pruned.
target_clone() {
  git clone --quiet --no-hardlinks "$repo" "$1" || return 1
  ( cd "$1" && git checkout --quiet -b exp-base "$2" ) || return 1
  ( cd "$1" \
    && git remote remove origin \
    && git for-each-ref --format='%(refname)' | while IFS= read -r r; do
         [[ "$r" == "refs/heads/exp-base" ]] || git update-ref -d "$r" || exit 1
       done \
    && git reflog expire --expire=now --all \
    && git gc --quiet --prune=now )
}

# prepare_doc <n> — the slot's sample (doc.state `sample`, `선정 <n>` when
# unset) prepared from its selection.tsv row.
prepare_doc() {
  local n="$1" ds="$ST/doc-$1" row name owner base orig br clone rid sample
  [[ "$(kv "$ds/doc.state" prepared)" == "1" ]] && return 0
  sample=$(kv "$ds/doc.state" sample)
  [[ -n "$sample" ]] || sample="선정 ${n}"
  row=$(sample_row "$sample")
  [[ -n "$row" ]] || die "document ${n}: ${sample} is not in selection.tsv"
  name=$(printf '%s' "$row" | cut -f1); owner=$(printf '%s' "$row" | cut -f2)
  orig=$(printf '%s' "$row" | cut -f5); base=$(printf '%s' "$row" | cut -f6)
  rm -rf "$ds"
  mkdir -p "$ds"
  # The bytes every branch audits: the main checkout's current file, kept here
  # so a later edit of the main checkout cannot split the branches.
  cp "$repo/$owner" "$ds/input.md"
  kv_set "$ds/doc.state" sample "$sample"
  kv_set "$ds/doc.state" doc "$owner"
  kv_set "$ds/doc.state" lead_report "$name"
  kv_set "$ds/doc.state" orig_run "$orig"
  kv_set "$ds/doc.state" base "$base"
  kv_set "$ds/doc.state" input_sha "$(sha_of "$ds/input.md")"
  for br in $BRANCHES; do
    target_clone "$ds/$br" "$base" || die "document ${n} ${br}: preparing the target clone at $base failed"
    clone=$(cd "$ds/$br" && pwd -P)
    mkdir -p "$(dirname "$clone/$owner")"
    cp "$ds/input.md" "$clone/$owner"
    rid=$(gen_run_id)
    while grep -qx "$rid" "$ST/runs.list" 2>/dev/null; do rid=$(gen_run_id); done
    printf '%s\n' "$rid" >> "$ST/runs.list"
    kv_set "$ds/$br.state" clone "$clone"
    kv_set "$ds/$br.state" run "$rid"
    write_run_files "$n" "$br"
    kv_set "$ds/$br.state" status "준비됨"
  done
  kv_set "$ds/doc.state" prepared 1
  kv_set "$ds/doc.state" status "준비됨"
  say "document ${n}: prepared ${sample} ${owner} (base ${base:0:12}, sha256 $(kv "$ds/doc.state" input_sha | cut -c1-12))"
}

# ---------- stage 4: the script seat ------------------------------------------

# latest_handoff_reason <ledger> — the 사유 of the run's latest handoff row.
latest_handoff_reason() {
  [[ -f "$1" ]] || return 0
  grep -E '^- `handoff` ' "$1" | tail -n 1 | tr '|' '\n' | sed -n 's/^ *사유=//p' | sed 's/[[:space:]]*$//' || true
}

# snapshot_h <manifest> <clone> <log> — the digest an acting call is bound to.
snapshot_h() {
  (cd "$2" && bash "$GATE" snapshot --manifest "$1" 2>>"$3" | jq -r '.H // empty' 2>/dev/null) || true
}

# unanswered_halts <run dir> <ledger> — the run's halt records that no
# `중단 답` row names yet, one absolute path per line.
unanswered_halts() {
  local f
  for f in "$1"/halt/*.md "$1"/halt/shift/*.md; do
    [[ -f "$f" ]] || continue
    case "$f" in *.answer.md) continue ;; esac
    if [[ -f "$2" ]] && grep -E '^- `중단 답` ' "$2" | grep -qF "중단 기록=${f} |"; then continue; fi
    printf '%s\n' "$f"
  done
}

# halt_key <record> — the key a halt record answers for: its header's stage=
# up to the `#`.
halt_key() {
  local s
  s=$(head -n 1 "$1" | sed -n 's/.*[; ]stage=\([^;]*\);.*/\1/p')
  printf '%s' "${s%%#*}"
}

# halt_policy <record> — the experiment's fixed answer to a halt record with
# no recommendation: the table row whose skill equals the record's **스킬** and
# whose step ERE matches its **스텝**, printed as label<TAB>reason when the
# label stands verbatim as a `- \`<label>\` — ` line under **선택지**. Prints
# nothing for a record outside the table. Every label keeps what the
# experiment measures — the frozen document and its first audit — unchanged.
halt_policy() {
  local f="$1" skill step sk re label why
  skill=$(bold_field "$f" '스킬'); step=$(bold_field "$f" '스텝')
  [[ -n "$skill" && -n "$step" ]] || return 0
  while IFS='	' read -r sk re label why; do
    [[ "$skill" == "$sk" ]] || continue
    grep -qE -- "$re" <<< "$step" || continue
    awk -v l="- \`${label}\` — " '
      /^\*\*선택지\*\*/ { on = 1; next }
      on && /^\*\*/ { exit }
      on && index($0, l) == 1 { hit = 1; exit }
      END { exit !hit }' "$f" || return 0
    printf '%s\t%s\n' "$label" "$why"
    return 0
  done <<'EOF'
design-audit-unattended	^Step 6.*CFI-3b	record in the unresolved-issues section	합성 질문을 미해결 이슈로 적으면 재수렴도 새 감사도 부르지 않아 첫 감사가 그대로다
design-audit-unattended	^Step 7 / 골격급 재발	미해결 이슈로 두고 계속	골격급 재발은 재감사에서만 나고 이 답은 재수렴을 부르지 않는다
design-solo-unattended	^Step 7U / ladder-unsettled	잔여로 두고 동결	단독 설계가 쓴 문서를 그대로 동결한다
EOF
}

# auto_resolve_on — the auto-resolve switch is not off (0, off, false or no,
# any case).
auto_resolve_on() {
  local v
  v=$(printf '%s' "${CC_CMDS_AUTOPILOT_AUTO_RESOLVE:-}" | tr '[:upper:]' '[:lower:]')
  case "$v" in 0|off|false|no) return 1 ;; esac
  return 0
}

# halt_answer_act <manifest> <clone> <key> <log> <field>... — one halt-answer
# call, sent again while the gate returns 4, at most four times. Returns the
# gate's status.
halt_answer_act() {
  local m="$1" clone="$2" key="$3" log="$4" rc=4 k=0 h
  shift 4
  while [[ "$rc" == "4" ]] && (( k < 4 )); do
    k=$((k + 1)); rc=0
    h=$(snapshot_h "$m" "$clone" "$log")
    ( cd "$clone" && bash "$GATE" act --manifest "$m" --kind halt-answer --target "$TARGET_ALIAS" --segment "$key" \
        --cutpoint 커밋 --surface 읽기 --snapshot-digest "$h" -- "$@" ) < /dev/null >> "$log" 2>&1 || rc=$?
  done
  return "$rc"
}

# seat_answer_halts <manifest> <clone> <run id> <log> — what the seat does on
# a 중단 handoff, never asking anyone. Each unanswered halt record:
#   - whose **추천** names an option is answered with that option, as
#     `답한 주체=좌석`, with the record's grounds attached. Whether a record
#     admits a seat answer is the gate's call, and a refusal is never answered
#     again by the policy;
#   - with no recommendation is answered by halt_policy's label, as
#     `답한 주체=사람` whose 근거 and attachment say it is the experiment's
#     fixed policy, unless the auto-resolve switch is off.
# A record left unanswered gets its outcome — `표 밖`, `스위치 꺼짐` or
# `게이트 거절 rc=<n>` — in the seat log and in $ST/seat/<run id>.tsv, where
# stop_reason reads it. Returns 0 when at least one answer was written.
seat_answer_halts() {
  local m="$1" clone="$2" rid="$3" log="$4" f key gl parts part kinds ans pol label why rc got=1 oc
  local out="$ST/seat/$rid.tsv"
  mkdir -p "$ST/seat"
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    key=$(halt_key "$f")
    ans="${f%.md}.answer.md"
    rc=0; oc=""
    if grep -qE '^\*\*추천\*\*: `' "$f"; then
      [[ -n "$key" ]] || { kv_set "$out" "$f" "게이트 거절 rc=-"; echo "seat: unanswered $f — 게이트 거절 rc=- (no stage key)" >> "$log"; continue; }
      gl=$(grep -nE '^\*\*추천 근거\*\*: ' "$f" | head -n 1 || true)
      parts="${gl#*: }"; kinds=""
      {
        printf '# 좌석 답 — %s\n\n' "$(basename "$f")"
        printf '중단 기록의 추천을 받았다. 추천 근거 (%s:%s):\n\n' "$f" "${gl%%:*}"
        while [[ -n "$parts" ]]; do
          part="${parts%% / *}"
          printf -- '- %s\n' "$part"
          kinds="${kinds:+${kinds},}${part%%:*}"
          [[ "$parts" == *" / "* ]] && parts="${parts#* / }" || parts=""
        done
        printf '\n되돌리는 법: 같은 기록에 다른 선택지로 다시 답하거나, 스테이지가 이 답으로 만든 커밋을 되돌린다.\n'
      } > "$ans"
      halt_answer_act "$m" "$clone" "$key" "$log" \
        "중단 기록=${f}" "답한 주체=좌석" "근거=중단 기록의 추천을 받았다 — 근거 종류 ${kinds:-미상}" "첨부=${ans}" || rc=$?
      if [[ "$rc" == "0" ]]; then
        got=0; echo "seat: answered $f with its recommendation" >> "$log"; continue
      fi
      oc="게이트 거절 rc=${rc}"
    elif ! auto_resolve_on; then
      oc="스위치 꺼짐"
    else
      pol=$(halt_policy "$f")
      if [[ -z "$pol" || -z "$key" ]]; then
        oc="표 밖"
      else
        label="${pol%%	*}"; why="${pol#*	}"
        {
          printf '# 정책 답 — %s\n\n' "$(basename "$f")"
          printf '실험 고정 정책 표의 줄을 적용했다. 사람이 이 기록을 읽고 답한 것이 아니다.\n\n'
          printf -- '- 스킬: %s\n' "$(bold_field "$f" '스킬')"
          printf -- '- 스텝: %s\n' "$(bold_field "$f" '스텝')"
          printf -- '- 라벨: %s\n' "$label"
          printf -- '- 이유: %s\n' "$why"
          printf '\n되돌리는 법: 같은 기록에 다른 선택지로 다시 답하거나, 그 문서를 --rerun-doc 로 처음부터 다시 돌린다.\n'
        } > "$ans"
        halt_answer_act "$m" "$clone" "$key" "$log" \
          "중단 기록=${f}" "선택지=${label}" "답한 주체=사람" "근거=실험 고정 정책 — ${why}; 사람이 이 기록을 읽고 답한 것이 아니다" "첨부=${ans}" || rc=$?
        if [[ "$rc" == "0" ]]; then
          got=0; echo "seat: answered $f by the fixed policy with ${label}" >> "$log"; continue
        fi
        oc="게이트 거절 rc=${rc}"
      fi
    fi
    [[ "$oc" == "게이트 거절"* ]] && rm -f "$ans"
    kv_set "$out" "$f" "$oc"
    echo "seat: unanswered $f — ${oc}" >> "$log"
  done < <(unanswered_halts "$RUN_ROOT/$rid" "$clone/docs/pipeline-run/$rid.md")
  return "$got"
}

# stop_reason <clone> <run id> <rc> — the invalid reason for a seat that
# returned 5 or 6: the approval, the first unanswered halt record's outcome,
# the deadline park of the run's latest `blocked` row, or a 중단 with nothing
# to answer.
stop_reason() {
  local clone="$1" rid="$2" rc="$3" led f oc sk sp at
  if [[ "$rc" == "5" ]]; then printf '승인 대기'; return 0; fi
  led="$clone/docs/pipeline-run/$rid.md"
  f=$(unanswered_halts "$RUN_ROOT/$rid" "$led" | awk 'NR == 1')
  if [[ -n "$f" ]]; then
    oc=$(kv "$ST/seat/$rid.tsv" "$f")
    sk=$(bold_field "$f" '스킬'); sp=$(bold_field "$f" '스텝')
    case "$oc" in
      "스위치 꺼짐") printf '추천 없는 중단 — 자동 답 스위치가 꺼져 있다' ;;
      "게이트 거절"*) printf '중단 — 게이트가 좌석 답을 거절했다 (%s / %s)' "${sk:--}" "${sp:--}" ;;
      *) printf '추천 없는 중단 — 고정 정책 밖 (%s / %s)' "${sk:--}" "${sp:--}" ;;
    esac
    return 0
  fi
  at=""
  if [[ -f "$led" ]]; then
    at=$(grep -E '^- `blocked` ' "$led" | awk 'END { print }' | sed -n 's/.*마감 초과 — ready_at \([^ |]*\).*/\1/p' || true)
  fi
  if [[ -n "$at" ]]; then printf '마감 초과 — ready_at %s' "$at"; else printf '중단 — 답할 중단 기록이 없다'; fi
}

# first_report <clone> <owner-doc> — the path of the clone's first audit of the
# document, empty when there is none.
first_report() {
  local idx first
  idx=$(audit_index "$1/docs/design-audit")
  [[ -n "$idx" ]] || return 0
  first=$(first_audit <(printf '%s\n' "$idx") "$2")
  [[ -n "$first" && -f "$1/docs/design-audit/$first" ]] && printf '%s' "$1/docs/design-audit/$first"
  return 0
}

# collected <clone> <owner-doc> — the first audit report carries both fences.
# The experiment reads the first audit only, so a run that has it needs no
# further shift: a skeletal finding would carry it on to a reconvergence and a
# re-audit whose cost and halts are no part of the experiment.
collected() {
  local r
  r=$(first_report "$1" "$2")
  [[ -n "$r" ]] && has_fence "$r" && has_skel "$r"
}

# seat <manifest> <clone> <run id> <log> <owner-doc> — issue `router-shift` as
# the seat does until the run's first audit report is collected or its done
# file exists — the run's cost ceiling writes it once the audit stage is
# costed, inside the call that ran the stage, at the successor shift's first
# gated call. Returns 0 on either — also when the call that found it failed —
# 5 on an approval (a seat cannot close one),
# 6 on a shift that handed off with 중단 and left nothing seat_answer_halts
# could answer, any other status on a failure. After a 승인 or 중단 handoff
# the seat does not send 대기 — the gate would refuse it.
seat() {
  local m="$1" clone="$2" rid="$3" log="$4" doc="$5" rd="$RUN_ROOT/$3" reason="상한" i=0 rc k h
  while :; do
    collected "$clone" "$doc" && return 0
    [[ -e "$rd/done" ]] && return 0
    i=$((i + 1))
    if (( i > SEAT_MAX )); then echo "seat: ${SEAT_MAX} calls without done" >> "$log"; return 1; fi
    rc=4; k=0
    while [[ "$rc" == "4" ]] && (( k < 4 )); do
      k=$((k + 1)); rc=0
      h=$(snapshot_h "$m" "$clone" "$log")
      ( cd "$clone" && bash "$GATE" act --manifest "$m" --kind router-shift --target "$TARGET_ALIAS" \
          --cutpoint 커밋 --surface 워크트리쓰기 --snapshot-digest "$h" \
          -- "$reason" -p "/cc-cmds:autopilot-router-shift $m" ) < /dev/null >> "$log" 2>&1 || rc=$?
    done
    # A run that ended while the gate held the wait — its deadline or its
    # ceiling reached while the host slept — refuses the next `대기` with 3.
    # Its report or its done file is the outcome, read by the caller.
    collected "$clone" "$doc" && return 0
    [[ -e "$rd/done" ]] && return 0
    case "$rc" in
      0) ;;
      *) return "$rc" ;;
    esac
    case "$(latest_handoff_reason "$clone/docs/pipeline-run/$rid.md")" in
      상한) reason="상한" ;;
      승인) return 5 ;;
      중단)
        if seat_answer_halts "$m" "$clone" "$rid" "$log"; then reason="중단"; else return 6; fi ;;
      *) reason="대기" ;;
    esac
  done
}

# run_seat_or_stop <n> <branch> — seat the branch's run. An approval or a 중단
# the seat could not answer makes the branch invalid with stop_reason's text
# and returns 0, so the document slot moves on to its next reserve; a failure
# of the seat itself stops the experiment.
run_seat_or_stop() {
  local n="$1" br="$2" bst="$ST/doc-$1/$2.state" m clone rid doc rc=0
  m=$(kv "$bst" manifest); clone=$(kv "$bst" clone); rid=$(kv "$bst" run)
  doc=$(kv "$ST/doc-$n/doc.state" doc)
  GATE="${GATE_OVERRIDE:-$(gate_clone "${br%-*}")/plugins/cc-cmds/orchestrator/gate.sh}"
  [[ -f "$GATE" ]] || die "no gate for the ${br%-*} branch: $GATE"
  # A run not yet opened gets fresh manifest times, so a dry run's deadline is
  # never inherited.
  if [[ ! -d "$RUN_ROOT/$rid" ]]; then write_run_files "$n" "$br"; m=$(kv "$bst" manifest); fi
  # Every seat entry is guarded: a resumed run starts new billed shifts too.
  if [[ -d "$RUN_ROOT/$rid" ]]; then guard_resume "the ${br} audit of document ${n}"
  else guard "$RESERVE_RUN" "the ${br} audit of document ${n}"; fi
  seat "$m" "$clone" "$rid" "$ST/doc-$n/seat-$br.log" "$doc" || rc=$?
  case "$rc" in
    0) return 0 ;;
    5|6)
      local why
      why=$(stop_reason "$clone" "$rid" "$rc")
      kv_set "$bst" status "무효"
      kv_set "$bst" invalid_reason "$why"
      say "document ${n} ${br}: invalid — ${why}"
      return 0 ;;
    *)
      kv_set "$bst" status "실패"
      echo "reader-model-pair-audit: document ${n} ${br}: the seat call ended with status ${rc}; see $ST/doc-$n/seat-$br.log" >&2
      exit 1 ;;
  esac
}

audit_branch() {
  local n="$1" br="$2" bst="$ST/doc-$1/$2.state" clone doc
  case "$(kv "$bst" status)" in 수집됨|종료됨|무효) return 0 ;; esac
  run_seat_or_stop "$n" "$br"
  [[ "$(kv "$bst" status)" == "무효" ]] && return 0
  clone=$(kv "$bst" clone); doc=$(kv "$ST/doc-$n/doc.state" doc)
  # A run collected between calls, with its audit stage still running, is left
  # as it is: no seat call follows, so no further shift is launched, and with no
  # later gated call the run stays open. A run that ended without a collected
  # report — its audit halted or stopped at its limit, and the ceiling ended the
  # run — is 종료됨, and branch_invalid reads it as 감사 보고서 없음.
  if collected "$clone" "$doc"; then kv_set "$bst" status "수집됨"; else kv_set "$bst" status "종료됨"; fi
}

# ---------- stage 5: collect -------------------------------------------------

# pin_commit <run dir> — the commit of the run's plugin pin, empty without one.
pin_commit() { kv "$1/plugin-pin" commit; }

# branch_invalid <n> <branch> <report|""> — the reason the audit is not valid,
# empty when it is. A branch the seat made invalid gives its own reason first,
# and a branch never seated reads `돌리지 않음`.
branch_invalid() {
  local n="$1" br="$2" rep="$3" bst="$ST/doc-$1/$2.state" st fwhy model u r un b rev sha rest pc want
  case "$(kv "$bst" status)" in
    무효) printf '%s' "$(kv "$bst" invalid_reason)"; return 0 ;;
    준비됨|"") printf '돌리지 않음'; return 0 ;;
  esac
  [[ -n "$rep" ]] || { printf '감사 보고서 없음'; return 0; }
  [[ "$(fence_count "$rep" "$FENCE_BEGIN")" == "1" && "$(fence_count "$rep" "$FENCE_END")" == "1" ]] \
    || { printf '공시 울타리가 하나가 아니다'; return 0; }
  [[ "$(fence_count "$rep" "$SKEL_BEGIN")" == "1" && "$(fence_count "$rep" "$SKEL_END")" == "1" ]] \
    || { printf '골격급 울타리가 하나가 아니다'; return 0; }
  IFS='	' read -r st fwhy model u r un b rev sha rest <<<"$(report_fields "$rep")"
  [[ "$st" == "ok" ]] || { printf '%s' "$fwhy"; return 0; }
  [[ "$rev" == "3" ]] || { printf '리뷰어 수가 %s 다' "$rev"; return 0; }
  [[ "$model" == "${br%-*}" ]] || { printf 'reader-model 이 %s 다 (갈래 %s)' "$model" "${br%-*}"; return 0; }
  [[ "$sha" == "$(kv "$ST/doc-$n/doc.state" input_sha)" ]] || { printf '동결 문서 sha256 이 입력과 다르다'; return 0; }
  pc=$(pin_commit "$RUN_ROOT/$(kv "$bst" run)")
  want=$(branch_commit "${br%-*}")
  [[ -n "$pc" && "$pc" == "$want" ]] || { printf 'plugin-pin commit %s 이 갈래 커밋 %s 가 아니다' "${pc:0:12}" "${want:0:12}"; return 0; }
  return 0
}

# collect_doc <n> — document n's docs.tsv row from its three branches; a
# branch that did not run is invalid as `돌리지 않음`. A row with an invalid
# cell makes the document invalid under the row's reasons.
collect_doc() {
  local n="$1" ds="$ST/doc-$1" br rep why cells="" reasons="" doc
  case "$(kv "$ds/doc.state" status)" in 수집\ 완료|무효) return 0 ;; esac
  doc=$(kv "$ds/doc.state" doc)
  mkdir -p "$EXP/reports"
  for br in $BRANCHES; do
    rep=$(first_report "$(kv "$ds/$br.state" clone)" "$doc")
    # Copied valid or not: the verdict reads the copies, never the state root.
    rm -f "$EXP/reports/$n-$br.md"
    [[ -z "$rep" ]] || cp "$rep" "$EXP/reports/$n-$br.md"
    why=$(branch_invalid "$n" "$br" "$rep")
    if [[ -z "$why" ]]; then cells="${cells}	유효"
    else cells="${cells}	무효"; reasons="${reasons:+${reasons}; }${br}: ${why}"; fi
  done
  docs_row_put "$n" "$(printf '%s\t%s\t%s%s\t%s' "$n" "$doc" "$(kv "$ds/doc.state" input_sha)" "$cells" "${reasons:--}")"
  if [[ -n "$reasons" ]]; then
    kv_set "$ds/doc.state" status "무효"
    kv_set "$ds/doc.state" invalid_reason "$reasons"
    say "document ${n}: invalid — ${reasons}"
  else
    kv_set "$ds/doc.state" status "수집 완료"
  fi
}

# ---------- slots and reserves -----------------------------------------------

doc_invalid() { [[ "$(kv "$ST/doc-$1/doc.state" status)" == "무효" ]]; }

# replace_slot <n> — move document slot n's invalid attempt aside to
# doc-<n>.try<k>, log it in attempts.tsv (n, attempt, sample, owner-doc,
# invalid reason, kept path), drop its docs.tsv row and report copies, and
# prepare the next reserve of the slot's bin. With no reserve left the invalid
# reason gains ` — 예비 소진` in the state and the docs.tsv row, the slot is
# final, and it returns 1.
replace_slot() {
  local n="$1" ds="$ST/doc-$1" cur next k why doc try=1 row br
  cur=$(kv "$ds/doc.state" sample)
  [[ -n "$cur" ]] || cur="선정 ${n}"
  if [[ "$cur" == "선정 "* ]]; then k=1; else k=$(( ${cur##*-} + 1 )); fi
  next="예비 ${n}-${k}"
  why=$(kv "$ds/doc.state" invalid_reason)
  if [[ -z "$(sample_row "$next")" ]]; then
    why="${why} — 예비 소진"
    kv_set "$ds/doc.state" invalid_reason "$why"
    kv_set "$ds/doc.state" exhausted 1
    row=$(docs_row_get "$n")
    if [[ -n "$row" ]]; then
      docs_row_put "$n" "$(printf '%s' "$row" | awk -F'\t' -v OFS='\t' '{ $7 = $7 " — 예비 소진"; print }')"
    else
      docs_row_put "$n" "$(printf '%s\t%s\t%s\t무효\t무효\t무효\t%s' "$n" "$(kv "$ds/doc.state" doc)" "$(kv "$ds/doc.state" input_sha)" "$why")"
    fi
    say "document ${n}: invalid — ${why}"
    return 1
  fi
  while [[ -e "$ST/doc-$n.try$try" ]]; do try=$((try + 1)); done
  doc=$(kv "$ds/doc.state" doc)
  mv "$ds" "$ST/doc-$n.try$try"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$n" "$try" "$cur" "${doc:--}" "$why" "$ST/doc-$n.try$try" >> "$EXP/attempts.tsv"
  docs_row_put "$n" ""
  for br in $BRANCHES; do rm -f "$EXP/reports/$n-$br.md"; done
  mkdir -p "$ds"
  kv_set "$ds/doc.state" sample "$next"
  say "document ${n}: attempt ${try} (${cur}) kept in $ST/doc-$n.try$try; replacing it with ${next}"
  prepare_doc "$n"
}

# run_slot <n> — document slot n's branches in order, stopping at the first
# invalid one, then its row; an invalid document is replaced with the next
# reserve until the slot is collected or invalid with no reserve left.
run_slot() {
  local n="$1" br bst
  while :; do
    if doc_invalid "$n"; then
      [[ "$(kv "$ST/doc-$n/doc.state" exhausted)" == "1" ]] && return 0
      replace_slot "$n" || return 0
    fi
    if [[ "$(kv "$ST/doc-$n/doc.state" status)" != "수집 완료" ]]; then
      for br in $BRANCHES; do
        bst="$ST/doc-$n/$br.state"
        audit_branch "$n" "$br"
        [[ -z "$(branch_invalid "$n" "$br" "$(first_report "$(kv "$bst" clone)" "$(kv "$ST/doc-$n/doc.state" doc)")")" ]] || break
      done
    fi
    collect_doc "$n"
    doc_invalid "$n" || return 0
  done
}

# ---------- status, rerun ----------------------------------------------------

show_status() {
  [[ -d "$EXP" ]] || die "no experiment directory: $EXP"
  echo "experiment ${exp_id}"
  echo "  directory: $EXP"
  echo "  selection: $([[ -f "$EXP/selection.tsv" ]] && echo done || echo pending)"
  echo "  branches: $([[ "$(kv "$ST/branches.state" ready)" == "1" ]] && printf 'sonnet %s · opus %s' "$(branch_commit sonnet | cut -c1-12)" "$(branch_commit opus | cut -c1-12)" || echo pending)"
  local n br st line
  for n in $(seq 1 "$DOCS"); do
    st=$(kv "$ST/doc-$n/doc.state" status)
    line="  document ${n}: ${st:-pending}"
    [[ "$st" != "무효" ]] || line="${line} — $(kv "$ST/doc-$n/doc.state" invalid_reason)"
    for br in $BRANCHES; do
      line="${line} · ${br} $(kv "$ST/doc-$n/$br.state" status)"
    done
    echo "$line"
  done
  echo "  spent usd: $(spent)"
  if [[ -f "$EXP/report.md" ]]; then echo "  $(tail -n 1 "$EXP/report.md")"; else echo "  verdict: pending"; fi
}

rerun_doc() {
  local n="$1" dt="$EXP/docs.tsv" at="$EXP/attempts.tsv" d
  # The slot's attempts go with it, so it starts again from `선정 <n>`.
  for d in "$ST/doc-$n" "$ST/doc-$n".try*; do
    [[ -e "$d" ]] || continue
    case "$d" in "$STATE_ROOT"/*) rm -rf "$d" ;; esac
  done
  rm -f "$EXP/reports/$n-opus-1.md" "$EXP/reports/$n-sonnet.md" "$EXP/reports/$n-opus-2.md"
  if [[ -f "$dt" ]]; then
    awk -F'\t' -v n="$n" 'NR == 1 || $1 != n' "$dt" > "$dt.tmp" && mv "$dt.tmp" "$dt"
  fi
  if [[ -f "$at" ]]; then
    awk -F'\t' -v n="$n" '$1 != n' "$at" > "$at.tmp" && mv "$at.tmp" "$at"
  fi
  rm -f "$EXP/report.md"
  say "document ${n}: discarded; running it again"
}

# ---------- main -------------------------------------------------------------

if [[ "$cmd" == "status" ]]; then show_status; exit 0; fi

mkdir -p "$EXP" "$ST"
if [[ ! -f "$EXP/meta" ]]; then
  {
    printf 'exp_id\t%s\n' "$exp_id"
    printf 'created\t%s\n' "$(now_iso)"
    printf 'repo_head\t%s\n' "$(cd "$repo" && git rev-parse HEAD)"
    printf 'ref\t%s\n' "${ref:-HEAD}"
    printf 'budget_usd\t%s\n' "${budget:--}"
  } > "$EXP/meta"
fi
printf 'call\t%s\t%s\t%s\t%s\n' "$(now_iso)" "$cmd$( (( dry == 1 )) && printf ' --dry-run' )" \
  "$(cd "$repo" && git rev-parse HEAD)" "${budget:--}" >> "$EXP/meta"

[[ "$cmd" == "rerun" ]] && rerun_doc "$rerun"
budget_restore

select_docs
make_branches
for n in $(seq 1 "$DOCS"); do prepare_doc "$n"; done

if (( dry == 1 )); then
  for n in $(seq 1 "$DOCS"); do
    for br in $BRANCHES; do
      say "document ${n} ${br}: $(kv "$ST/doc-$n/$br.state" manifest)"
    done
  done
  say "dry run: selection, branches, preparation and manifest checks done; no run was started"
  exit 0
fi

for n in $(seq 1 "$DOCS"); do run_slot "$n"; done
bash "$COMPARE" pairs --exp "$EXP" || die "reader-model-compare pairs failed"
say "$(tail -n 1 "$EXP/report.md") → $EXP/report.md"
exit 0
