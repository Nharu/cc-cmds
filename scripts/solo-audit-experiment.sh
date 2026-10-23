#!/usr/bin/env bash
# Run the solo-design audit experiment: is "solo design + audit" about equal to
# "team design + audit" when the same ticket is designed both ways?
#
# One call runs the whole experiment in seven stages, and calling it again
# resumes where it stopped — every stage skips work whose output already
# exists:
#
#   1 select    pick five team-design audits from the 2026-10-10..16 window
#               (quantile sample over unique-defect count) and put every
#               other candidate in the bin of its nearest pick as a reserve
#               (`예비 <n>-<k>`) → selection.tsv
#   2 prepare   per pair: an independent clone at the original design's base
#               commit, a solo design-run manifest that binds the original
#               frozen interview record, an audit-run manifest, the grant
#               records; both manifests must pass the driver's own
#               check_manifest
#   3 design    the design run, opened through THIS checkout's gate, driven by
#               a script seat that issues `act --kind router-shift` until the
#               run's `done` exists; then the frozen-line and contamination
#               checks
#   4 audit     the audit run on the frozen document, same seat
#   5 collect   both reports' disclosure-block values and plugin pins
#   6 classify  one judgment call per report, cross-checked against the
#               disclosure block; ambiguous defects go to classify/review.tsv
#               with a blank judgment, and the verdict reads them as
#               `판정 불가` until it is filled
#   7 verdict   scripts/solo-audit-compare.sh → report.md
#
# Stages 3 to 6 run slot by slot. A pair that turns invalid — a halt no fixed
# policy answers, an approval, a deadline, contamination, a failed cross-check
# — is moved aside as an attempt and its slot runs again on the next reserve
# of its bin; a slot whose reserves are used up stays invalid. No stage waits
# on a person.
#
# The design skill is not touched and no stage is launched outside the gate:
# the experiment measures today's production path, nothing else.
#
# Usage:
#   scripts/solo-audit-experiment.sh [run] [--exp-id <id>] --budget-usd <N> [--repo <dir>]
#   scripts/solo-audit-experiment.sh run --dry-run [--exp-id <id>] [--budget-usd <N>]
#   scripts/solo-audit-experiment.sh status --exp-id <id>
#   scripts/solo-audit-experiment.sh --rerun-pair <n> --exp-id <id> --budget-usd <N>
#
#   --exp-id      YYYYMMDD-<8 hex>; created on the first call when absent,
#                 required by `status` and `--rerun-pair`
#   --budget-usd  required by every call that may start billed work, with no
#                 default: before each billed run, spent + 150 must not exceed
#                 it, before resuming an opened run spent must be below it,
#                 and before each classification call spent + 3
#   --dry-run     select, prepare and check the manifests, then stop; never
#                 calls the gate's act or the CLI
#   --rerun-pair  discard one pair's state, attempts and records and run its
#                 slot again from `선정 <n>`
#   --repo        the main repository (default: this script's checkout)
#
# Environment:
#   SOLO_EXP_GATE         gate to open the runs with
#                         (default <repo>/plugins/cc-cmds/orchestrator/gate.sh)
#   SOLO_EXP_CLAUDE_BIN   CLI for the classification call (default: claude on PATH)
#   SOLO_EXP_STATE_ROOT   clones and run state
#                         (default ${HOME}/.local/state/cc-cmds/solo-audit-exp)
#   CC_CMDS_AUTOPILOT_AUTO_RESOLVE  0, off, false or no keeps the seat from
#                         answering a halt record by the fixed policy
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

WINDOW_FROM="2026-10-10"
WINDOW_TO="2026-10-16"
PAIRS=5
RESERVE_RUN=150
RESERVE_CLASSIFY=3
CLASSIFY_BUDGET=3
DEADLINE_SECONDS=14400
SEAT_MAX="${SOLO_EXP_SEAT_MAX:-500}"
TARGET_ALIAS="exp"
# Not a repository on any remote: a router that reaches for a remote fails
# instead of acting on the real one. The cutpoint `커밋` keeps the run from
# pushing at all.
TARGET_SLUG="local/solo-audit-exp"

FENCE_BEGIN='<!-- cc-design-audit-disclosure v1 begin -->'
FENCE_END='<!-- /cc-design-audit-disclosure v1 end -->'
ROUTES="조정 패스 적용|미해결 이슈|implement 사전 게이트|design-conformance|기각"

usage() { echo "solo-audit-experiment: $1" >&2; exit 2; }
die() { echo "solo-audit-experiment: $1" >&2; exit 1; }
say() { echo "solo-audit-experiment: $1"; }

# ---------- arguments --------------------------------------------------------

cmd="run"
exp_id=""
budget=""
repo=""
rerun=""
dry=0

while (( $# > 0 )); do
  case "$1" in
    run|status) cmd="$1"; shift ;;
    --rerun-pair) rerun="${2:-}"; cmd="rerun"; shift 2 || usage "--rerun-pair needs a pair number" ;;
    --dry-run) dry=1; shift ;;
    --exp-id) exp_id="${2:-}"; shift 2 || usage "--exp-id needs a value" ;;
    --budget-usd) budget="${2:-}"; shift 2 || usage "--budget-usd needs a value" ;;
    --repo) repo="${2:-}"; shift 2 || usage "--repo needs a value" ;;
    -h|--help) grep -E '^# ' "$0" | cut -c3-; exit 0 ;;
    *) usage "unknown argument: $1" ;;
  esac
done

[[ -n "$repo" ]] || repo=$(cd "$script_dir/.." && pwd)
[[ -d "$repo/.git" || -f "$repo/.git" ]] || usage "not a git checkout: $repo"
repo=$(cd "$repo" && pwd)
repo_p=$(cd "$repo" && pwd -P)

if [[ -n "$exp_id" && ! "$exp_id" =~ ^[0-9]{8}-[0-9a-f]{8}$ ]]; then
  usage "--exp-id must be YYYYMMDD-<8 hex>: $exp_id"
fi
if [[ -n "$budget" && ! "$budget" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
  usage "--budget-usd must be a number: $budget"
fi
case "$cmd" in
  status) [[ -n "$exp_id" ]] || usage "status needs --exp-id" ;;
  rerun)
    [[ -n "$exp_id" ]] || usage "--rerun-pair needs --exp-id"
    [[ "$rerun" =~ ^[1-9][0-9]*$ ]] && (( rerun <= PAIRS )) || usage "--rerun-pair needs 1..${PAIRS}: $rerun"
    (( dry == 0 )) || usage "--rerun-pair and --dry-run do not combine"
    ;;
esac
if [[ "$cmd" != "status" && "$dry" == "0" && -z "$budget" ]]; then
  usage "--budget-usd <N> is required for a call that may start billed work (no default)"
fi

GATE="${SOLO_EXP_GATE:-$repo/plugins/cc-cmds/orchestrator/gate.sh}"
CLAUDE_BIN="${SOLO_EXP_CLAUDE_BIN:-$(command -v claude || true)}"
STATE_ROOT="${SOLO_EXP_STATE_ROOT:-$HOME/.local/state/cc-cmds/solo-audit-exp}"
RUN_ROOT="${XDG_STATE_HOME:-$HOME/.local/state}/cc-cmds/run"
# The driver whose check the manifests must pass: this script's own checkout,
# which is the main repository unless --repo points elsewhere (the tests do).
RUN_SH="$script_dir/../plugins/cc-cmds/orchestrator/run.sh"
COMPARE="$script_dir/solo-audit-compare.sh"
PROMPT="$script_dir/solo-audit-classify.md"
SCHEMA="$script_dir/solo-audit-classify.schema.json"

# A variable inherited from a pipeline stage would make the gate read THIS
# shell as a seat of that run. The experiment's runs are runs of their own.
for v in $(compgen -e | grep '^CC_PIPELINE_' || true); do unset "$v"; done

if [[ -z "$exp_id" ]]; then
  [[ "$cmd" == "run" ]] || usage "--exp-id is required"
  exp_id="$(date -u +%Y%m%d)-$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
fi
EXP="$repo/docs/solo-audit-experiment/$exp_id"
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

# fence_get <report> <slot key> — one slot of the v1 disclosure block, read
# only between the fences. There is no prose fallback (same rule as
# scripts/measure-audit-findings.sh).
fence_get() {
  LC_ALL=C awk -v b="$FENCE_BEGIN" -v e="$FENCE_END" -v k="**$2**: " '
    index($0, b) == 1 { inf = 1; next }
    index($0, e) == 1 { inf = 0; next }
    inf && index($0, k) == 1 { print substr($0, length(k) + 1); exit }
  ' "$1"
}

has_fence() { grep -qF -- "$FENCE_BEGIN" "$1"; }

# hdr_field <file> <key> — `key=value;` from the machine header in the first lines.
hdr_field() {
  head -n 8 "$1" | grep -oE "$2=[^;]*" | head -n 1 | sed "s/^$2=//" || true
}

# bold_field <file> <key> — the value of a `**key**: value` line.
bold_field() {
  awk -v k="**$2**: " 'index($0, k) == 1 { print substr($0, length(k) + 1); exit }' "$1"
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

epoch_date() { jq -rn --argjson e "$1" '$e | todate | .[0:10]'; }
epoch_iso() { jq -rn --argjson e "$1" '$e | todate'; }
now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# plan_json <manifest> — the first ```json fence under `## 실행 계획`.
plan_json() {
  awk '
    /^## 실행 계획$/ { sec = 1; next }
    sec && /^## / { exit }
    sec && !inj && $0 == "```json" { inj = 1; next }
    inj && $0 == "```" { exit }
    inj { print }
  ' "$1"
}

# intent_text <manifest> — the body of the ```text fence under `## 의도`.
intent_text() {
  awk '
    /^## 의도$/ { sec = 1; next }
    sec && /^## / { exit }
    sec && !inb && $0 == "```text" { inb = 1; next }
    inb && $0 == "```" { exit }
    inb { print }
  ' "$1"
}

sha_of() { shasum -a 256 "$1" | cut -d' ' -f1; }

gen_run_id() { printf '%s-%s' "$(date -u +%Y%m%d)" "$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"; }

doc_slug() { local b; b=$(basename "$1"); printf '%s' "${b%.md}"; }
# report_name <document key> — the name the audit skill gives a document's
# report. Later audits of the same document follow no fixed naming: a suffix
# inside the name, a run id, a date, or the earlier report moved aside to
# `<name>.prior-<hash>.md` while the re-audit takes this name. So the name
# alone does not tell the first audit.
report_name() { local k="${1%.md}"; printf '%s.md' "$(printf '%s' "$k" | tr '/' '-')"; }

# freeze_at <report> — when the audited document was frozen: the disclosure
# block's 동결 시각, else the `frozen-at` line of the report's opening, which a
# report without the block carries too, spelled `frozen-at: v`, `- frozen-at:
# v`, `**frozen-at**: v` or `- **frozen-at**: v`.
freeze_at() {
  local v=""
  if has_fence "$1"; then v=$(fence_get "$1" '동결 시각'); fi
  [[ -n "$v" ]] || v=$(grep -m 1 -E '^(- )?(\*\*)?frozen-at(\*\*)?: ' "$1" | sed -E 's/^(- )?(\*\*)?frozen-at(\*\*)?: *//' || true)
  printf '%s' "$v" | sed 's/[[:space:]]*$//'
}

# audit_index <reports dir> — one line per report, reader copies left out:
# name, owner-doc, freeze epoch (empty when unreadable).
audit_index() {
  local r name
  find "$1" -maxdepth 1 -name '*.md' 2>/dev/null | LC_ALL=C sort | while IFS= read -r r; do
    name=$(basename "$r")
    case "$name" in *reader-*) continue ;; esac
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

# ---------- cost guard -------------------------------------------------------

# spent — every top-level `result` line of every run this experiment opened,
# plus every classification call. Summing all result lines over-counts a
# resumed session; for a guard that is the safe direction.
spent() {
  {
    if [[ -f "$ST/runs.list" ]]; then
      local rid f
      while IFS= read -r rid; do
        [[ -n "$rid" ]] || continue
        for f in "$RUN_ROOT/$rid"/log/*.json; do
          [[ -f "$f" ]] || continue
          jq -R 'fromjson? | select(type == "object" and .type == "result") | (.total_cost_usd // 0)' "$f" 2>/dev/null || true
        done
      done < "$ST/runs.list"
    fi
    local g
    for g in "$EXP"/classify/*.raw.json; do
      [[ -f "$g" ]] || continue
      jq '.total_cost_usd // 0' "$g" 2>/dev/null || true
    done
  } | awk '{ s += $1 } END { printf "%.4f", s + 0 }'
}

# guard <reserve> <what> — before a billed step that could pass the budget,
# close the experiment on the budget (budget_close, exit 4).
guard() {
  local s msg
  s=$(spent)
  if awk -v s="$s" -v r="$1" -v b="$budget" 'BEGIN { exit !(s + r > b) }'; then
    msg="budget guard — spent ${s} + reserve $1 > budget ${budget}; not starting $2"
    echo "solo-audit-experiment: ${msg}" >&2
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
    echo "solo-audit-experiment: ${msg}" >&2
    budget_close "$msg"
  fi
}

# slot_done <n> — the slot needs no further work: valid and classified, or
# invalid with its reserves used up.
slot_done() {
  local f="$ST/pair-$1/pair.state"
  if [[ "$(kv "$f" status)" == "무효" ]]; then [[ "$(kv "$f" exhausted)" == "1" ]]; return; fi
  [[ "$(kv "$f" classified)" == "1" ]]
}

# budget_close <refusal> — every slot not finished becomes invalid under
# `예산 상한 — <refusal>`, remembering what it was in budget_stop*, the verdict
# is written, and the call ends with exit 4. budget_restore undoes the marks
# on the next call, so a larger budget carries the slots on.
budget_close() {
  local why="예산 상한 — $1" n ps pt
  for n in $(seq 1 "$PAIRS"); do
    ps="$ST/pair-$n"; pt="$EXP/pairs/$n/pair.tsv"
    slot_done "$n" && continue
    [[ -n "$(kv "$ps/pair.state" budget_stop)" ]] && continue
    mkdir -p "$ps"
    kv_set "$ps/pair.state" budget_stop "$(kv "$ps/pair.state" status)"
    kv_set "$ps/pair.state" budget_stop_why "$(kv "$ps/pair.state" invalid_reason)"
    if [[ -f "$pt" ]]; then kv_set "$ps/pair.state" budget_stop_tsv "$(kv "$pt" status)"; else kv_set "$ps/pair.state" budget_stop_tsv "-"; fi
    mark_invalid "$n" "$why"
  done
  bash "$COMPARE" --exp "$EXP" || die "solo-audit-compare failed"
  say "$(tail -n 1 "$EXP/report.md") → $EXP/report.md (closed on the budget; call again with a larger --budget-usd to carry on)"
  exit 4
}

# budget_restore — put back every slot budget_close marked.
budget_restore() {
  local n ps pt prev why tprev
  for n in $(seq 1 "$PAIRS"); do
    ps="$ST/pair-$n"; pt="$EXP/pairs/$n/pair.tsv"
    prev=$(kv "$ps/pair.state" budget_stop)
    [[ -n "$prev" ]] || continue
    why=$(kv "$ps/pair.state" budget_stop_why); tprev=$(kv "$ps/pair.state" budget_stop_tsv)
    kv_set "$ps/pair.state" status "$prev"
    if [[ -n "$why" ]]; then kv_set "$ps/pair.state" invalid_reason "$why"; else kv_del "$ps/pair.state" invalid_reason; fi
    if [[ "$tprev" == "-" || -z "$tprev" ]]; then
      rm -f "$pt"
    else
      kv_set "$pt" status "$tprev"
      if [[ -n "$why" ]]; then kv_set "$pt" invalid_reason "$why"; else kv_del "$pt" invalid_reason; fi
    fi
    kv_del "$ps/pair.state" budget_stop; kv_del "$ps/pair.state" budget_stop_why; kv_del "$ps/pair.state" budget_stop_tsv
  done
}

# ---------- stage 1: select --------------------------------------------------

select_pairs() {
  local sel="$EXP/selection.tsv"
  [[ -f "$sel" ]] && return 0
  local ar="$repo/docs/design-audit" pr="$repo/docs/pipeline-run"
  [[ -d "$ar" ]] || die "no reports directory: $ar"
  local fep tep
  fep=$(iso_epoch "${WINDOW_FROM}T00:00:00Z"); tep=$(( $(iso_epoch "${WINDOW_TO}T00:00:00Z") + 86400 ))

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

  local rows="$EXP/.rows.tsv" r name owner first fa fe u why run base plan tier scope prow ipath isha tdoc tree pre
  : > "$rows"
  while IFS= read -r r; do
    name=$(basename "$r")
    case "$name" in *reader-*) continue ;; esac
    owner=$(hdr_field "$r" owner-doc)
    # A report without the block stays on record: when it is a first audit
    # that parked, it is what makes the later re-audit not the first one.
    if ! has_fence "$r"; then
      printf '%s\t%s\t-\t-\t-\t-\t%s\t%s\n' "$name" "${owner:--}" "공시 블록이 없다" "$r" >> "$rows"
      continue
    fi
    fa=$(fence_get "$r" '동결 시각'); fe=$(iso_epoch "$fa")
    u=$(fence_get "$r" '고유 결함 수')
    why=""; run="-"; base="-"; first=""
    [[ -z "$owner" ]] || first=$(first_audit "$aidx" "$owner")
    if [[ -z "$fe" ]]; then why="동결 시각을 읽을 수 없다"
    elif (( fe < fep || fe >= tep )); then why="창 밖 (UTC $(epoch_date "$fe"))"
    elif [[ ! "$u" =~ ^[0-9]+$ ]]; then why="고유 결함 수를 읽을 수 없다"
    elif [[ -z "$owner" ]]; then why="owner-doc= 이 없다"
    # Any report of the same document frozen earlier, with or without its
    # block and whatever its name, makes this one a re-audit.
    elif [[ -n "$first" && "$name" != "$first" ]]; then why="같은 owner-doc 의 첫 감사 보고서 ${first} 가 따로 있다 (재감사)"
    fi
    if [[ -z "$why" ]]; then
      run=$(awk -F'\t' -v o="$owner" -v f="$fe" '$2 == o && $4 == 1 && $3 != "" && $3 < f && $3 > best { best = $3; id = $1 } END { print id }' "$idx")
      if [[ -z "$run" ]]; then run="-"; why="원 런이 없다 (같은 owner-doc · 설계 정상 완료 · 동결 시각 이전 킥오프)"; fi
    fi
    if [[ -z "$why" ]]; then
      base=$(grep -m 1 -E '^- `run` ' "$pr/$run.md" | tr '|' '\n' | sed -n 's/^ *판본=//p' | sed 's/[[:space:]]*$//' || true)
      plan=$(plan_json "$pr/$run.plan.md")
      tier=$(printf '%s' "$plan" | jq -r '.design_tier // empty' 2>/dev/null || true)
      scope=$(printf '%s' "$plan" | jq -r '.design_scope // "single"' 2>/dev/null || true)
      prow=$(grep -m 1 -E '^- `사전 인가` \| 인터뷰 기록=' "$pr/$run.plan.md" || true)
      ipath=$(printf '%s' "$prow" | tr '|' '\n' | sed -n 's/^ *인터뷰 기록=//p' | sed 's/[[:space:]]*$//')
      isha=$(printf '%s' "$prow" | tr '|' '\n' | sed -n 's/^ *sha256=//p' | sed 's/[[:space:]]*$//')
      if [[ "$tier" != "team-2" && "$tier" != "team-4" ]]; then why="팀 티어가 아니다 (${tier:-없음})"
      elif [[ "$scope" == "base" ]]; then why="design_scope 가 base 다"
      elif [[ -z "$ipath" || ! -f "$repo/$ipath" ]]; then why="인터뷰 기록이 없다"
      elif ! grep -qF 'cc-run-interview v2' "$repo/$ipath"; then why="인터뷰 기록이 v2 가 아니다"
      elif [[ "$(sha_of "$repo/$ipath")" != "$isha" ]]; then why="인터뷰 기록 해시가 사전 인가 행과 다르다"
      elif [[ ! "$base" =~ ^[0-9a-f]{40}$ ]]; then why="원장 run 행에 판본= 이 없다"
      elif ! ( cd "$repo" && git cat-file -e "${base}^{commit}" 2>/dev/null ); then why="기준 커밋이 저장소에 없다"
      fi
    fi
    if [[ -z "$why" ]]; then
      tdoc="$repo/$owner"
      if [[ -f "$tdoc" ]]; then
        tree=$(bold_field "$tdoc" '기준 트리')
        pre=$(printf '%s\n' $tree | grep -m 1 -E '^[0-9a-f]{7,40}$' || true)
        if [[ -n "$pre" && "${base#"$pre"}" == "$base" ]]; then why="기준 트리 ${pre} 가 판본= 과 다르다"; fi
      fi
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "${owner:--}" "${fe:-}" "${u:--}" "$run" "$base" "${why:-}" "$r" >> "$rows"
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
  if (( m_ >= PAIRS )); then
    picks=$(printf '%s\n' "$cands" | awk -F'\t' -v m="$m_" -v p="$PAIRS" '
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
  rm -f "$sel.tmp"
  awk -F'\t' '{ print $1 "\t" $8 }' "$rows" > "$EXP/.paths.tsv"
  rm -f "$rows" "$keep" "$idx" "$aidx"

  if (( m_ < PAIRS )); then
    write_short_report "후보가 ${m_}건이다 — 선정 규칙은 ${PAIRS}건을 요구한다 (후보 부족)"
    say "candidates: ${m_} < ${PAIRS}; verdict 판정 불가 written to $EXP/report.md"
    exit 0
  fi
  say "selected ${PAIRS} of ${m_} candidates → $sel"
}

write_short_report() {
  cat > "$EXP/report.md" <<EOF
# 단독 설계 감사 실험 판정 보고서

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

# selected_row <n> — the selection.tsv row of pair n's main sample.
selected_row() { sample_row "선정 ${1}"; }

# ---------- stage 2: prepare -------------------------------------------------

# manifest_check <manifest> <clone> — the driver's own check, sourced from this
# checkout's run.sh; never a stub.
manifest_check() {
  ( cd "$2" && CC_ORCH_SOURCE_ONLY=1 && . "$RUN_SH" && MANIFEST="$1" && check_manifest )
}

manifest_digests() {
  ( cd "$2" && CC_ORCH_SOURCE_ONLY=1 && . "$RUN_SH" && MANIFEST="$1" \
    && printf '%s\t%s\n' "$(canonical_targets | shasum -a 256 | cut -d' ' -f1)" "$(binding_set_bytes | shasum -a 256 | cut -d' ' -f1)" )
}

# write_run_files <kind design|audit> <n> — the manifest and the grant of one
# experiment run, digests filled and checked. Rewritten only while the run has
# not started, so a dry run's clock is never inherited by the real one.
write_run_files() {
  local kind="$1" n="$2" ps="$ST/pair-$2" clone rid doc orig slug m g goal clause anchor_kind anchor_key
  clone=$(kv "$ps/pair.state" clone)
  rid=$(kv "$ps/pair.state" "${kind}_run")
  doc=$(kv "$ps/pair.state" doc)
  orig=$(kv "$ps/pair.state" orig_run)
  slug=$(doc_slug "$doc")
  m="$clone/docs/pipeline-run/$rid.plan.md"
  g="$clone/docs/pipeline-grant/$rid.md"
  local now dl docsha confirm intent plan preauth=""
  now=$(now_iso)
  dl=$(epoch_iso $(( $(date -u +%s) + DEADLINE_SECONDS )))
  confirm="solo-audit-experiment ${exp_id} 짝 ${n} — 실행 스크립트가 연 실험 런"
  if [[ "$kind" == "design" ]]; then
    anchor_kind="intent"; anchor_key="$slug"
    goal="단독 설계 스테이지가 ${doc} 를 동결한다"
    clause="설계 문서가 동결됐다"
    docsha="(해당 없음)"
    intent=$(intent_text "$repo/docs/pipeline-run/$orig.plan.md")
    [[ -n "$intent" ]] || intent="원 런 ${orig} 의 동결 인터뷰 기록으로 ${doc} 를 단독 설계한다"
    local icopy="docs/pipeline-run/$rid.interview.md"
    preauth="- \`사전 인가\` | 인터뷰 기록=${icopy} | sha256=$(sha_of "$clone/$icopy")"
    plan=$(jq -n --arg ak "$anchor_key" --arg orig "$orig" --arg doc "$doc" --arg exp "$exp_id" --arg n "$n" \
      --arg alias "$TARGET_ALIAS" --arg slug "$TARGET_SLUG" '{
        anchor_kind: "intent", anchor_key: $ak, entry_skill: "design",
        entry_rationale: ("단독 설계 감사 실험 " + $exp + " 짝 " + $n + " — 원 런 " + $orig + " 의 동결 인터뷰 기록으로 " + $doc + " 를 단독 설계한다."),
        design_required: true,
        design_rationale: "실험 프로토콜이 같은 인터뷰 기록의 단독 설계를 요구한다.",
        design_tier: "solo", design_tier_judged: "solo", design_heavy_reasons: [], estimated_files: 0,
        design_tier_rationale: "실험 프로토콜이 단독 설계 스테이지를 고정한다.",
        design_scope: "single", design_scope_rationale: "원 설계와 같은 단일 문서다.",
        work_class: "unknown", work_class_rationale: "설계까지만 돈다.",
        targets: [{alias: $alias, remote_slug: $slug, home: true, why: "기준 커밋에서 만든 실험 클론"}],
        steps: [{id: "D1", skill: "design", summary: "원 인터뷰 기록으로 단독 설계", depends_on: []}],
        unresolved: [], notes: "solo-audit-experiment 가 쓴 실험 런 매니페스트"
      }')
  else
    anchor_kind="doc"; anchor_key="$doc"
    goal="설계 감사가 ${doc} 의 보고서를 공시 블록과 함께 남긴다"
    clause="감사 보고서가 공시 블록과 함께 남았다"
    if [[ -f "$clone/$doc" ]]; then docsha=$(sha_of "$clone/$doc"); else docsha="(해당 없음)"; fi
    intent="동결된 ${doc} 를 설계 감사한다 (solo-audit-experiment ${exp_id} 짝 ${n})"
    plan=$(jq -n --arg ak "$anchor_key" --arg doc "$doc" --arg exp "$exp_id" --arg n "$n" \
      --arg alias "$TARGET_ALIAS" --arg slug "$TARGET_SLUG" '{
        anchor_kind: "doc", anchor_key: $ak, entry_skill: "design-audit",
        entry_rationale: ("단독 설계 감사 실험 " + $exp + " 짝 " + $n + " — 동결된 " + $doc + " 를 감사한다."),
        design_required: false,
        design_rationale: "문서는 앞선 실험 런이 동결했다.",
        design_tier: "solo", design_tier_judged: "solo", design_heavy_reasons: [], estimated_files: 0,
        design_tier_rationale: "설계 스텝이 없다.",
        design_scope: "single", design_scope_rationale: "단일 문서다.",
        work_class: "unknown", work_class_rationale: "감사까지만 돈다.",
        targets: [{alias: $alias, remote_slug: $slug, home: true, why: "기준 커밋에서 만든 실험 클론"}],
        steps: [{id: "A1", skill: "design-audit", summary: "동결 문서 감사", depends_on: []}],
        unresolved: [], notes: "solo-audit-experiment 가 쓴 실험 런 매니페스트"
      }')
  fi
  local cg
  cg=$(cd "$clone" && git rev-parse --path-format=absolute --git-common-dir)
  mkdir -p "$clone/docs/pipeline-run" "$clone/docs/pipeline-grant"
  {
    printf '# 파이프라인 런 매니페스트 — %s\n' "$rid"
    printf '<!-- cc-run-manifest v1; writer=autopilot; reader=orchestrator; run-id=%s;\n' "$rid"
    printf '     anchor-kind=%s; anchor-key=%s;\n' "$anchor_kind" "$anchor_key"
    printf '     owner-doc=%s; origin-worktree=%s;\n' "$doc" "$clone"
    printf '     NOT a design doc; mechanism-local, never staged by a skill -->\n\n'
    printf '## 런 정체\n**킥오프 일시**: %s\n**런 id**: %s\n**앵커 종류**: %s\n**앵커 키**: %s\n**사용자 확인 문면**: %s\n\n' \
      "$now" "$rid" "$anchor_kind" "$anchor_key" "$confirm"
    printf '## 의도\n```text\n%s\n```\n\n' "$intent"
    printf '## 대상\n**대상 맵 다이제스트**: @TMD@\n'
    printf -- '- `target` | 별칭=%s | 메인 워크트리=%s | 공통 git 디렉터리=%s | 베이스 브랜치=exp-base | 홈=예 | 원격 슬러그=%s | 절단점=커밋 | 말단 행위 상한=없음\n\n' \
      "$TARGET_ALIAS" "$clone" "$cg" "$TARGET_SLUG"
    printf '## 요소\n**설계 문서**: %s\n**설계 문서 전체 sha256**: %s\n**리뷰 대상**: (없음)\n**적용 지점**: (없음)\n**적용 프로브**: (없음)\n**적용 주체**: (해당 없음)\n\n' \
      "$doc" "$docsha"
    printf '## 실행 계획\n**승인 문면**: solo-audit-experiment 고정 계획\n```json\n%s\n```\n\n' "$plan"
    printf '## 인가\n**구속 다이제스트**: @BD@\n**런 최대 절단점**: 커밋\n**종료 지점**: %s\n**벽시계 마감**: %s\n' "$goal" "$dl"
    printf '**비용 천장**: 없음\n**무진전 상한**: 없음\n**시각 정합 마커**: 없음\n**사다리 가용 단 수**: 4\n**미선언 상황 처분**: park\n'
    printf -- '- `종료 절` | id=C1 | 문면=%s\n' "$clause"
    [[ -z "$preauth" ]] || printf '%s\n' "$preauth"
  } > "$m.tmp"
  local dg tmd bd
  dg=$(manifest_digests "$m.tmp" "$clone") || die "pair ${n}: digest computation failed for $m"
  tmd=${dg%%	*}; bd=${dg##*	}
  sed -e "s/@TMD@/$tmd/" -e "s/@BD@/$bd/" "$m.tmp" > "$m"
  rm -f "$m.tmp"
  {
    printf '# 파이프라인 인가 기록 — %s\n' "$rid"
    printf '<!-- cc-pipeline-grant v1; writer=autopilot; reader=orchestrator; owner-doc=%s; origin-worktree=%s; NOT a design doc; mechanism-local, never staged by a skill -->\n\n' "$doc" "$clone"
    printf '## 인가 %s\n**인가 일시**: %s\n**종료 지점**: %s\n**권한 절단점**: 커밋\n**말단 행위 상한**: 없음\n**직렬 웨이브 고지**: 해당 없음\n**시각 정합 마커**: 없음\n**사용자 확인 문면**: %s\n**설계 문서 전체 sha256**: %s\n**보고서**: %s\n' \
      "$rid" "$now" "$goal" "$confirm" "$docsha" "$clone/docs/pipeline-run/$rid.md"
  } > "$g"
  if ! manifest_check "$m" "$clone" > "$ps/check-$kind.log" 2>&1; then
    cat "$ps/check-$kind.log" >&2
    die "pair ${n}: the ${kind} manifest fails check_manifest — $m"
  fi
  kv_set "$ps/pair.state" "${kind}_manifest" "$m"
}

# prepare_pair <n> — the slot's sample (pair.state `sample`, `선정 <n>` when
# unset) prepared from its selection.tsv row.
prepare_pair() {
  local n="$1" ps="$ST/pair-$1" row name owner base orig ipath clone sample
  [[ "$(kv "$ps/pair.state" prepared)" == "1" ]] && return 0
  sample=$(kv "$ps/pair.state" sample)
  [[ -n "$sample" ]] || sample="선정 ${n}"
  row=$(sample_row "$sample")
  [[ -n "$row" ]] || die "pair ${n}: ${sample} is not in selection.tsv"
  name=$(printf '%s' "$row" | cut -f1); owner=$(printf '%s' "$row" | cut -f2)
  orig=$(printf '%s' "$row" | cut -f5); base=$(printf '%s' "$row" | cut -f6)
  ipath=$(grep -m 1 -E '^- `사전 인가` \| 인터뷰 기록=' "$repo/docs/pipeline-run/$orig.plan.md" \
    | tr '|' '\n' | sed -n 's/^ *인터뷰 기록=//p' | sed 's/[[:space:]]*$//')
  rm -rf "$ps"
  mkdir -p "$ps"
  git clone --quiet --no-hardlinks "$repo" "$ps/clone" || die "pair ${n}: clone failed"
  clone=$(cd "$ps/clone" && pwd -P)
  ( cd "$clone" && git checkout --quiet -b exp-base "$base" ) || die "pair ${n}: checkout of $base failed"
  # Nothing past the base commit stays in the clone: the stages' worktrees
  # share its refs, and git history is a leak the contamination check cannot
  # see. Only exp-base is left, with no remote, and the rest is pruned.
  ( cd "$clone" \
    && git remote remove origin \
    && git for-each-ref --format='%(refname)' | while IFS= read -r r; do
         [[ "$r" == "refs/heads/exp-base" ]] || git update-ref -d "$r" || exit 1
       done \
    && git reflog expire --expire=now --all \
    && git gc --quiet --prune=now ) || die "pair ${n}: removing history past $base from the clone failed"
  local drid arid
  drid=$(gen_run_id); arid=$(gen_run_id)
  while [[ "$arid" == "$drid" ]]; do arid=$(gen_run_id); done
  printf '%s\n%s\n' "$drid" "$arid" >> "$ST/runs.list"
  kv_set "$ps/pair.state" sample "$sample"
  kv_set "$ps/pair.state" clone "$clone"
  kv_set "$ps/pair.state" doc "$owner"
  kv_set "$ps/pair.state" team_report "$name"
  kv_set "$ps/pair.state" orig_run "$orig"
  kv_set "$ps/pair.state" base "$base"
  kv_set "$ps/pair.state" design_run "$drid"
  kv_set "$ps/pair.state" audit_run "$arid"
  mkdir -p "$clone/docs/pipeline-run"
  cp "$repo/$ipath" "$clone/docs/pipeline-run/$drid.interview.md"
  write_run_files design "$n"
  write_run_files audit "$n"
  kv_set "$ps/pair.state" prepared 1
  kv_set "$ps/pair.state" status "준비됨"
  say "pair ${n}: prepared ${sample} ${owner} in ${clone} (base ${base:0:12}, design run ${drid}, audit run ${arid})"
}

# ---------- stages 3·4: the script seat --------------------------------------

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
          printf '\n되돌리는 법: 같은 기록에 다른 선택지로 다시 답하거나, 그 짝을 --rerun-pair 로 처음부터 다시 돌린다.\n'
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

# closed_by_deadline <run dir> — the run's done names the wall-clock deadline
# as the boundary that ended it.
closed_by_deadline() {
  [[ -s "$1/done" ]] && head -n 1 "$1/done" | grep -q '종단 — 경계 마감 '
}

# seat <manifest> <clone> <run id> <log> — issue `router-shift` as the seat does
# until the run's done file exists. Returns 0 on done, 5 on an approval (a
# seat cannot close one), 6 on a shift that handed off with 중단 and left
# nothing seat_answer_halts could answer, any other status on a failure. After
# a 승인 or 중단 handoff the seat does not send 대기 — the gate would refuse
# it: a 중단 handoff whose records the seat answered relaunches with 중단,
# anything else ends the seat with 5 or 6.
seat() {
  local m="$1" clone="$2" rid="$3" log="$4" rd="$RUN_ROOT/$3" reason="상한" i=0 rc k h
  while :; do
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
    case "$rc" in
      0) ;;
      *) return "$rc" ;;
    esac
    [[ -e "$rd/done" ]] && return 0
    case "$(latest_handoff_reason "$clone/docs/pipeline-run/$rid.md")" in
      상한) reason="상한" ;;
      승인) return 5 ;;
      중단)
        if seat_answer_halts "$m" "$clone" "$rid" "$log"; then reason="중단"; else return 6; fi ;;
      *) reason="대기" ;;
    esac
  done
}

mark_invalid() {
  local n="$1" why="$2"
  kv_set "$ST/pair-$n/pair.state" status "무효"
  kv_set "$ST/pair-$n/pair.state" invalid_reason "$why"
  mkdir -p "$EXP/pairs/$n"
  kv_set "$EXP/pairs/$n/pair.tsv" status "무효"
  kv_set "$EXP/pairs/$n/pair.tsv" invalid_reason "$why"
  say "pair ${n}: invalid — ${why}"
}

pair_invalid() { [[ "$(kv "$ST/pair-$1/pair.state" status)" == "무효" ]]; }

# run_seat_or_stop <n> <design|audit> — seat the run. An approval or a 중단
# the seat could not answer makes the pair invalid with stop_reason's text and
# returns 0, so the slot moves on to its next reserve; a failure of the seat
# itself stops the experiment.
run_seat_or_stop() {
  local n="$1" kind="$2" ps="$ST/pair-$1" m clone rid rc=0
  m=$(kv "$ps/pair.state" "${kind}_manifest"); clone=$(kv "$ps/pair.state" clone); rid=$(kv "$ps/pair.state" "${kind}_run")
  # A run not yet opened gets fresh manifest times, so a dry run's deadline is
  # never inherited.
  if [[ ! -d "$RUN_ROOT/$rid" ]]; then write_run_files "$kind" "$n"; m=$(kv "$ps/pair.state" "${kind}_manifest"); fi
  # Every seat entry is guarded: a resumed run starts new billed shifts too.
  if [[ -d "$RUN_ROOT/$rid" ]]; then guard_resume "the ${kind} run of pair ${n}"
  else guard "$RESERVE_RUN" "the ${kind} run of pair ${n}"; fi
  seat "$m" "$clone" "$rid" "$ps/seat-$kind.log" || rc=$?
  case "$rc" in
    0) return 0 ;;
    5|6)
      mark_invalid "$n" "$(stop_reason "$clone" "$rid" "$rc")"
      return 0 ;;
    *)
      kv_set "$ps/pair.state" status "실패"
      echo "solo-audit-experiment: pair ${n}: the ${kind} run's seat call ended with status ${rc}; see $ps/seat-$kind.log" >&2
      exit 1 ;;
  esac
}

design_pair() {
  local n="$1" ps="$ST/pair-$1" clone doc rid orig rd hits
  [[ -n "$(kv "$ps/pair.state" design_done)" ]] && return 0
  pair_invalid "$n" && return 0
  run_seat_or_stop "$n" design
  pair_invalid "$n" && return 0
  clone=$(kv "$ps/pair.state" clone); doc=$(kv "$ps/pair.state" doc)
  rid=$(kv "$ps/pair.state" design_run); orig=$(kv "$ps/pair.state" orig_run)
  rd="$RUN_ROOT/$rid"
  kv_set "$ps/pair.state" design_done 1
  if closed_by_deadline "$rd"; then
    mark_invalid "$n" "벽시계 마감으로 닫힘"
    return 0
  fi
  if [[ ! -f "$clone/$doc" ]] || [[ "$(grep -cx '\*\*상태\*\*: 동결됨' "$clone/$doc" || true)" != "1" ]]; then
    mark_invalid "$n" "동결 문서 없음"
    return 0
  fi
  # Contamination: the solo stage may read other local repositories, so the
  # team's document, its audit and its ledger are reachable by absolute path.
  # The original run id alone is not a hit — the copied interview record
  # carries it in its header.
  mkdir -p "$EXP/pairs/$n"
  local pats="$ps/contamination.pats" f
  : > "$pats"
  for root in "$repo" "$repo_p"; do
    printf '%s\n' "$root/$doc" "$root/docs/design-audit/" "$root/docs/pipeline-run/$orig.md" >> "$pats"
  done
  hits=""
  for f in "$rd"/log/D1#*.json; do
    [[ -f "$f" ]] || continue
    hits="${hits}$(grep -nF -f "$pats" "$f" | cut -c1-400 | sed "s|^|$(basename "$f"):|" || true)"
  done
  if [[ -n "$hits" ]]; then
    printf '%s\n' "$hits" > "$EXP/pairs/$n/contamination.txt"
    mark_invalid "$n" "오염 의심"
    return 0
  fi
  kv_set "$ps/pair.state" status "설계 완료"
}

audit_pair() {
  local n="$1" ps="$ST/pair-$1" clone doc
  [[ -n "$(kv "$ps/pair.state" audit_done)" ]] && return 0
  pair_invalid "$n" && return 0
  run_seat_or_stop "$n" audit
  pair_invalid "$n" && return 0
  clone=$(kv "$ps/pair.state" clone); doc=$(kv "$ps/pair.state" doc)
  kv_set "$ps/pair.state" audit_done 1
  if closed_by_deadline "$RUN_ROOT/$(kv "$ps/pair.state" audit_run)"; then
    mark_invalid "$n" "벽시계 마감으로 닫힘"
    return 0
  fi
  # The solo side's report is picked by the same first-audit rule as the
  # team side's.
  local first rep
  audit_index "$clone/docs/design-audit" > "$ps/audits.tsv"
  first=$(first_audit "$ps/audits.tsv" "$doc")
  rep="$clone/docs/design-audit/$first"
  if [[ -z "$first" || ! -f "$rep" ]]; then
    mark_invalid "$n" "감사 보고서 없음"
    return 0
  fi
  if ! has_fence "$rep"; then
    mark_invalid "$n" "첫 감사가 공시 블록 없이 멈춤 (${first})"
    return 0
  fi
  kv_set "$ps/pair.state" solo_report "$rep"
  kv_set "$ps/pair.state" status "감사 완료"
}

# ---------- stage 5: collect -------------------------------------------------

# pin_of <run dir> — `<version>@<commit 12>` from the run's plugin pin.
pin_of() {
  local p="$1/plugin-pin" v c
  [[ -f "$p" ]] || { printf '(미상)'; return 0; }
  v=$(kv "$p" version); c=$(kv "$p" commit)
  printf '%s@%s' "${v:-?}" "${c:0:12}"
}

label_of() { sha_of "$1" | cut -c1-12; }

collect_pair() {
  local n="$1" ps="$ST/pair-$1" pt="$EXP/pairs/$1/pair.tsv" tr sr side f k
  pair_invalid "$n" && return 0
  [[ "$(kv "$pt" status)" == "유효" ]] && return 0
  mkdir -p "$EXP/pairs/$n"
  tr="$repo/docs/design-audit/$(kv "$ps/pair.state" team_report)"
  sr=$(kv "$ps/pair.state" solo_report)
  : > "$pt.tmp"
  for side in team solo; do
    if [[ "$side" == "team" ]]; then f="$tr"; else f="$sr"; fi
    printf '%s_report\t%s\n' "$side" "$f" >> "$pt.tmp"
    printf '%s_label\t%s\n' "$side" "$(label_of "$f")" >> "$pt.tmp"
    printf '%s_unique\t%s\n' "$side" "$(fence_get "$f" '고유 결함 수')" >> "$pt.tmp"
    printf '%s_bytes\t%s\n' "$side" "$(fence_get "$f" '동결 문서 바이트')" >> "$pt.tmp"
    printf '%s_unremedied\t%s\n' "$side" "$(fence_get "$f" '미보강 잔여 수')" >> "$pt.tmp"
    printf '%s_reviewers\t%s\n' "$side" "$(fence_get "$f" '리뷰어 수')" >> "$pt.tmp"
    local IFS_S="$IFS"; IFS='|'
    for k in $ROUTES; do
      IFS="$IFS_S"
      printf '%s_route_%s\t%s\n' "$side" "$k" "$(fence_get "$f" "라우팅 — $k")" >> "$pt.tmp"
      IFS='|'
    done
    IFS="$IFS_S"
  done
  printf 'team_plugin\t%s\n' "$(pin_of "$RUN_ROOT/$(kv "$ps/pair.state" orig_run)")" >> "$pt.tmp"
  printf 'solo_plugin\t%s\n' "$(pin_of "$RUN_ROOT/$(kv "$ps/pair.state" audit_run)")" >> "$pt.tmp"
  printf 'solo_design_plugin\t%s\n' "$(pin_of "$RUN_ROOT/$(kv "$ps/pair.state" design_run)")" >> "$pt.tmp"
  printf 'status\t유효\n' >> "$pt.tmp"
  mv "$pt.tmp" "$pt"
  kv_set "$ps/pair.state" status "수집 완료"
}

# ---------- stage 6: classify ------------------------------------------------

# classify_input <report> <clone> — `## 결정론적 검사` to the end, the
# disclosure block removed, absolute roots replaced by <ROOT>.
classify_input() {
  awk -v b="$FENCE_BEGIN" -v e="$FENCE_END" -v r1="$repo" -v r2="$repo_p" -v r3="$2" '
    function lit(s, a,   o, i) { o = ""; while ((i = index(s, a)) > 0) { o = o substr(s, 1, i - 1) "<ROOT>"; s = substr(s, i + length(a)) } return o s }
    $0 == "## 결정론적 검사" { on = 1 }
    !on { next }
    index($0, b) == 1 { skip = 1; next }
    index($0, e) == 1 { skip = 0; next }
    skip { next }
    { s = $0; if (r3 != "") s = lit(s, r3); s = lit(s, r2); s = lit(s, r1); print s }
  ' "$1"
}

# crosscheck <result json> <report> — the classification against the report's
# own disclosure block. Prints the first disagreement and fails on one.
crosscheck() {
  local j="$1" r="$2" u got k want have
  u=$(fence_get "$r" '고유 결함 수')
  got=$(jq -r '[.defects[]?] | length' "$j")
  [[ "$got" == "$u" ]] || { echo "id 수 ${got} ≠ 고유 결함 수 ${u}"; return 1; }
  got=$(jq -r '[.defects[]?.id] | unique | length' "$j")
  [[ "$got" == "$u" ]] || { echo "서로 다른 id 가 ${got}개다 (고유 결함 수 ${u})"; return 1; }
  local IFS_S="$IFS"; IFS='|'
  for k in $ROUTES; do
    IFS="$IFS_S"
    want=$(fence_get "$r" "라우팅 — $k")
    have=$(jq -r --arg k "$k" '[.defects[]? | select(.routing == $k)] | length' "$j")
    [[ "$have" == "$want" ]] || { IFS="$IFS_S"; echo "라우팅 ${k}: ${have} ≠ 공시 ${want}"; return 1; }
    IFS='|'
  done
  IFS="$IFS_S"
  got=$(jq -r '[.defects[]? | select((.routing == "기각") != (.class == "제외"))] | length' "$j")
  [[ "$got" == "0" ]] || { echo "기각과 제외가 맞물리지 않는 결함이 ${got}건이다"; return 1; }
  return 0
}

classify_report() {
  local n="$1" side="$2" pt="$EXP/pairs/$1/pair.tsv" rep label raw out clone why
  rep=$(kv "$pt" "${side}_report"); label=$(kv "$pt" "${side}_label")
  clone=$(kv "$ST/pair-$n/pair.state" clone)
  out="$EXP/classify/$label.json"; raw="$EXP/classify/$label.raw.json"
  mkdir -p "$EXP/classify"
  if [[ ! -f "$out" ]]; then
    [[ -n "$CLAUDE_BIN" ]] || die "no CLI for the classification call (set SOLO_EXP_CLAUDE_BIN or put claude on PATH)"
    guard "$RESERVE_CLASSIFY" "the classification of report ${label}"
    local input
    input=$(classify_input "$rep" "$clone")
    if [[ -f "$raw" ]]; then mv "$raw" "$EXP/classify/$label.$(date -u +%s).raw.json"; fi
    ( cd "$EXP/classify" && "$CLAUDE_BIN" -p "$(cat "$PROMPT")

--- INPUT ---
${input}" --json-schema "$(cat "$SCHEMA")" --output-format json --strict-mcp-config --tools "" \
        --no-session-persistence --max-budget-usd "$CLASSIFY_BUDGET" ) > "$raw" 2>"$EXP/classify/$label.stderr" \
      || die "pair ${n}: the classification call for ${label} failed; see $EXP/classify/$label.stderr"
    if [[ "$(jq -r '.subtype // empty' "$raw" 2>/dev/null)" != "success" ]] \
       || ! jq -e '.structured_output | type == "object"' "$raw" >/dev/null 2>&1; then
      die "pair ${n}: the classification call for ${label} returned no structured output; see $raw"
    fi
    jq '.structured_output' "$raw" > "$out.tmp" && mv "$out.tmp" "$out"
  fi
  if ! why=$(crosscheck "$out" "$rep"); then
    mark_invalid "$n" "분류 교차 검사 실패 (${side} ${label}: ${why})"
    return 1
  fi
  # Ambiguous defects get a row with a blank judgment, which the verdict reads
  # as `판정 불가` until it is filled. A row already judged is kept.
  local rv="$EXP/classify/review.tsv"
  [[ -f "$rv" ]] || printf '표지\tid\t라우팅\t모델 사유\t사람 판정\n' > "$rv"
  jq -r --arg l "$label" '.defects[]? | select(.class == "애매") | [$l, .id, .routing, (.reason | gsub("[\t\n\r]"; " ")), ""] | @tsv' "$out" \
    | while IFS= read -r line; do
        id=$(printf '%s' "$line" | cut -f2)
        awk -F'\t' -v l="$label" -v i="$id" 'NR > 1 && $1 == l && $2 == i { f = 1 } END { exit !f }' "$rv" || printf '%s\n' "$line" >> "$rv"
      done
  return 0
}

# classify_pair <n> — both reports of a collected pair classified and
# cross-checked; a disagreement makes the pair invalid. A blank judgment in
# review.tsv stops nothing.
classify_pair() {
  local n="$1"
  pair_invalid "$n" && return 0
  [[ "$(kv "$ST/pair-$n/pair.state" classified)" == "1" ]] && return 0
  [[ "$(kv "$EXP/pairs/$n/pair.tsv" status)" == "유효" ]] || return 0
  classify_report "$n" team || return 0
  classify_report "$n" solo || return 0
  kv_set "$ST/pair-$n/pair.state" classified 1
}

# ---------- slots and reserves -----------------------------------------------

# drop_review_rows <label> — remove one report's rows from review.tsv.
drop_review_rows() {
  local rv="$EXP/classify/review.tsv"
  [[ -n "$1" && -f "$rv" ]] || return 0
  awk -F'\t' -v l="$1" 'NR == 1 || $1 != l' "$rv" > "$rv.tmp"
  mv "$rv.tmp" "$rv"
}

# replace_slot <n> — move slot n's invalid attempt aside to pair-<n>.try<k>,
# log it in pairs/<n>/attempts.tsv (attempt, sample, owner-doc, invalid
# reason, kept path) and prepare the next reserve of the slot's bin. With no
# reserve left the invalid reason gains ` — 예비 소진`, the slot is final, and
# it returns 1.
replace_slot() {
  local n="$1" ps="$ST/pair-$1" pd="$EXP/pairs/$1" cur next k why doc try=1 l
  cur=$(kv "$ps/pair.state" sample)
  [[ -n "$cur" ]] || cur="선정 ${n}"
  if [[ "$cur" == "선정 "* ]]; then k=1; else k=$(( ${cur##*-} + 1 )); fi
  next="예비 ${n}-${k}"
  why=$(kv "$ps/pair.state" invalid_reason)
  if [[ -z "$(sample_row "$next")" ]]; then
    mark_invalid "$n" "${why} — 예비 소진"
    kv_set "$ps/pair.state" exhausted 1
    return 1
  fi
  while [[ -e "$ST/pair-$n.try$try" ]]; do try=$((try + 1)); done
  doc=$(kv "$ps/pair.state" doc)
  mv "$ps" "$ST/pair-$n.try$try"
  mkdir -p "$pd"
  printf '%s\t%s\t%s\t%s\t%s\n' "$try" "$cur" "${doc:--}" "$why" "$ST/pair-$n.try$try" >> "$pd/attempts.tsv"
  for l in "$(kv "$pd/pair.tsv" team_label)" "$(kv "$pd/pair.tsv" solo_label)"; do drop_review_rows "$l"; done
  rm -f "$pd/pair.tsv"
  if [[ -f "$pd/contamination.txt" ]]; then mv "$pd/contamination.txt" "$pd/contamination.try$try.txt"; fi
  mkdir -p "$ps"
  kv_set "$ps/pair.state" sample "$next"
  say "pair ${n}: attempt ${try} (${cur}) kept in $ST/pair-$n.try$try; replacing it with ${next}"
  prepare_pair "$n"
}

# run_slot <n> — slot n's stages in order, replacing an invalid attempt with
# the next reserve, until the slot is valid and classified or invalid with no
# reserve left.
run_slot() {
  local n="$1"
  while :; do
    if pair_invalid "$n"; then
      [[ "$(kv "$ST/pair-$n/pair.state" exhausted)" == "1" ]] && return 0
      replace_slot "$n" || return 0
    fi
    design_pair "$n"
    audit_pair "$n"
    collect_pair "$n"
    classify_pair "$n"
    pair_invalid "$n" || return 0
  done
}

# ---------- status, rerun ----------------------------------------------------

show_status() {
  [[ -d "$EXP" ]] || die "no experiment directory: $EXP"
  echo "experiment ${exp_id}"
  echo "  directory: $EXP"
  echo "  selection: $([[ -f "$EXP/selection.tsv" ]] && echo done || echo pending)"
  local n st
  for n in $(seq 1 "$PAIRS"); do
    st=$(kv "$ST/pair-$n/pair.state" status)
    echo "  pair ${n}: ${st:-pending}$( [[ "$st" == "무효" ]] && printf ' — %s' "$(kv "$ST/pair-$n/pair.state" invalid_reason)" )"
  done
  echo "  spent usd: $(spent)"
  if [[ -f "$EXP/report.md" ]]; then echo "  $(tail -n 1 "$EXP/report.md")"; else echo "  verdict: pending"; fi
}

rerun_pair() {
  local n="$1" pt="$EXP/pairs/$1/pair.tsv" l
  for l in "$(kv "$pt" team_label)" "$(kv "$pt" solo_label)"; do
    [[ -n "$l" ]] || continue
    rm -f "$EXP/classify/$l.json" "$EXP/classify/$l.stderr"
    drop_review_rows "$l"
  done
  # Raw call results are kept: their cost stays in the guard's sum. The
  # slot's attempts go with it, so it starts again from `선정 <n>`.
  local d
  for d in "$ST/pair-$n" "$ST/pair-$n".try*; do
    [[ -e "$d" ]] || continue
    case "$d" in "$STATE_ROOT"/*) rm -rf "$d" ;; esac
  done
  case "$EXP/pairs/$n" in "$repo/docs/solo-audit-experiment/"*) rm -rf "$EXP/pairs/$n" ;; esac
  rm -f "$EXP/report.md"
  say "pair ${n}: discarded; running it again"
}

# ---------- main -------------------------------------------------------------

if [[ "$cmd" == "status" ]]; then show_status; exit 0; fi

mkdir -p "$EXP" "$ST"
dirty="아니오"
[[ -z "$(cd "$repo" && git status --porcelain -- plugins/cc-cmds)" ]] || dirty="예"
if [[ ! -f "$EXP/meta" ]]; then
  {
    printf 'exp_id\t%s\n' "$exp_id"
    printf 'created\t%s\n' "$(now_iso)"
    printf 'repo_head\t%s\n' "$(cd "$repo" && git rev-parse HEAD)"
    printf 'plugin_dirty\t%s\n' "$dirty"
    printf 'budget_usd\t%s\n' "${budget:--}"
  } > "$EXP/meta"
fi
printf 'call\t%s\t%s\t%s\t%s\t%s\n' "$(now_iso)" "$cmd$( (( dry == 1 )) && printf ' --dry-run' )" \
  "$(cd "$repo" && git rev-parse HEAD)" "$dirty" "${budget:--}" >> "$EXP/meta"

[[ "$cmd" == "rerun" ]] && rerun_pair "$rerun"
budget_restore

select_pairs
for n in $(seq 1 "$PAIRS"); do prepare_pair "$n"; done

if (( dry == 1 )); then
  for n in $(seq 1 "$PAIRS"); do
    say "pair ${n}: $(kv "$ST/pair-$n/pair.state" design_manifest) · $(kv "$ST/pair-$n/pair.state" audit_manifest)"
  done
  say "dry run: selection, preparation and manifest checks done; no run was started"
  exit 0
fi

if [[ "$dirty" == "예" ]]; then
  die "plugins/cc-cmds has uncommitted changes — the plugin a run pins could not be re-derived; billed stages not started"
fi
[[ -f "$GATE" ]] || die "no gate: $GATE"

for n in $(seq 1 "$PAIRS"); do run_slot "$n"; done
bash "$COMPARE" --exp "$EXP" || die "solo-audit-compare failed"
say "$(tail -n 1 "$EXP/report.md") → $EXP/report.md"
rv="$EXP/classify/review.tsv"
blank=0
[[ -f "$rv" ]] && blank=$(awk -F'\t' 'NR > 1 && $5 == "" { n++ } END { print n + 0 }' "$rv")
if (( blank > 0 )); then
  say "${blank} ambiguous defect(s) have a blank 사람 판정 (골격급 or 비골격) in $rv"
  say "\`review.tsv\` 를 채우고 같은 명령을 다시 부르면 새 과금 없이 다시 판정한다"
fi
exit 0
