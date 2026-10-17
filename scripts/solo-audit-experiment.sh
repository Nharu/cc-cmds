#!/usr/bin/env bash
# Run the solo-design audit experiment: is "solo design + audit" about equal to
# "team design + audit" when the same ticket is designed both ways?
#
# One call runs the whole experiment in seven stages, and calling it again
# resumes where it stopped — every stage skips work whose output already
# exists:
#
#   1 select    pick five team-design audits from the 2026-10-10..16 window
#               (quantile sample over unique-defect count) → selection.tsv
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
#               for a person
#   7 verdict   scripts/solo-audit-compare.sh → report.md
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
#                 it, and before each classification call spent + 3
#   --dry-run     select, prepare and check the manifests, then stop; never
#                 calls the gate's act or the CLI
#   --rerun-pair  discard one pair's state and records and run it again
#   --repo        the main repository (default: this script's checkout)
#
# Environment:
#   SOLO_EXP_GATE         gate to open the runs with
#                         (default <repo>/plugins/cc-cmds/orchestrator/gate.sh)
#   SOLO_EXP_CLAUDE_BIN   CLI for the classification call (default: claude on PATH)
#   SOLO_EXP_STATE_ROOT   clones and run state
#                         (default ${HOME}/.local/state/cc-cmds/solo-audit-exp)
#
# Exit codes:
#   0 — a verdict was written (`판정 불가` included), or a dry run finished
#   1 — failure
#   2 — usage error
#   3 — waiting on a person (an ambiguous defect to judge, or an approval)
#   4 — budget guard: the next billed step would exceed --budget-usd
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
# report_name <document key> — the first audit's report file name.
report_name() { local k="${1%.md}"; printf '%s.md' "$(printf '%s' "$k" | tr '/' '-')"; }

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

# guard <reserve> <what> — exit 4 before a billed step that could pass the budget.
guard() {
  local s
  s=$(spent)
  if awk -v s="$s" -v r="$1" -v b="$budget" 'BEGIN { exit !(s + r > b) }'; then
    echo "solo-audit-experiment: budget guard — spent ${s} + reserve $1 > budget ${budget}; not starting $2" >&2
    exit 4
  fi
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

  local rows="$EXP/.rows.tsv" r name owner fa fe u why run base plan tier scope prow ipath isha tdoc tree pre
  : > "$rows"
  while IFS= read -r r; do
    name=$(basename "$r")
    case "$name" in *reader-*) continue ;; esac
    has_fence "$r" || continue
    owner=$(hdr_field "$r" owner-doc)
    fa=$(fence_get "$r" '동결 시각'); fe=$(iso_epoch "$fa")
    u=$(fence_get "$r" '고유 결함 수')
    why=""; run="-"; base="-"
    if [[ -z "$fe" ]]; then why="동결 시각을 읽을 수 없다"
    elif (( fe < fep || fe >= tep )); then why="창 밖 (UTC $(epoch_date "$fe"))"
    elif [[ ! "$u" =~ ^[0-9]+$ ]]; then why="고유 결함 수를 읽을 수 없다"
    elif [[ -z "$owner" ]]; then why="owner-doc= 이 없다"
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
  local picks=""
  if (( m_ >= PAIRS )); then
    for j in $(seq 0 $((PAIRS - 1))); do
      local i
      i=$(awk -v m="$m_" -v j="$j" -v p="$PAIRS" 'BEGIN { print int((m - 1) * j / (p - 1) + 0.5) }')
      picks="${picks}$(printf '%s\n' "$cands" | sed -n "$((i + 1))p" | cut -f2)	$((j + 1))
"
    done
  fi

  {
    printf '보고서\towner-doc\t동결 시각(UTC)\t고유 결함 수\t원 런\t기준 커밋\t처분\t사유\n'
    awk -F'\t' -v OFS='\t' 'FILENAME == ARGV[1] { k[$1] = 1; next }
      FILENAME == ARGV[2] { if ($1 != "") p[$1] = $2; next }
      {
        if ($7 != "") { d = "제외"; w = $7 }
        else if (!($1 in k)) { d = "제외"; w = "같은 owner-doc 의 더 이른 감사가 있다" }
        else if ($1 in p) { d = "선정 " p[$1]; w = "-" }
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
  rm -f "$rows" "$keep" "$idx"

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

# selected_row <n> — the selection.tsv row of pair n.
selected_row() { awk -F'\t' -v d="선정 $1" '$7 == d { print; exit }' "$EXP/selection.tsv"; }

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

prepare_pair() {
  local n="$1" ps="$ST/pair-$1" row name owner base orig ipath clone
  [[ "$(kv "$ps/pair.state" prepared)" == "1" ]] && return 0
  row=$(selected_row "$n")
  [[ -n "$row" ]] || die "pair ${n} is not in selection.tsv"
  name=$(printf '%s' "$row" | cut -f1); owner=$(printf '%s' "$row" | cut -f2)
  orig=$(printf '%s' "$row" | cut -f5); base=$(printf '%s' "$row" | cut -f6)
  ipath=$(grep -m 1 -E '^- `사전 인가` \| 인터뷰 기록=' "$repo/docs/pipeline-run/$orig.plan.md" \
    | tr '|' '\n' | sed -n 's/^ *인터뷰 기록=//p' | sed 's/[[:space:]]*$//')
  rm -rf "$ps"
  mkdir -p "$ps"
  git clone --quiet --no-hardlinks "$repo" "$ps/clone" || die "pair ${n}: clone failed"
  clone=$(cd "$ps/clone" && pwd -P)
  ( cd "$clone" && git checkout --quiet -b exp-base "$base" ) || die "pair ${n}: checkout of $base failed"
  local drid arid
  drid=$(gen_run_id); arid=$(gen_run_id)
  while [[ "$arid" == "$drid" ]]; do arid=$(gen_run_id); done
  printf '%s\n%s\n' "$drid" "$arid" >> "$ST/runs.list"
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
  say "pair ${n}: prepared ${clone} (base ${base:0:12}, design run ${drid}, audit run ${arid})"
}

# ---------- stages 3·4: the script seat --------------------------------------

# latest_handoff_reason <ledger> — the 사유 of the run's latest handoff row.
latest_handoff_reason() {
  [[ -f "$1" ]] || return 0
  grep -E '^- `handoff` ' "$1" | tail -n 1 | tr '|' '\n' | sed -n 's/^ *사유=//p' | sed 's/[[:space:]]*$//' || true
}

# seat <manifest> <clone> <run id> <log> — issue `router-shift` as the seat does
# until the run's done file exists. Returns 0 on done, 5 on an approval for a
# person, any other status on a failure.
seat() {
  local m="$1" clone="$2" rid="$3" log="$4" rd="$RUN_ROOT/$3" reason="상한" i=0 rc k h
  while :; do
    [[ -e "$rd/done" ]] && return 0
    i=$((i + 1))
    if (( i > SEAT_MAX )); then echo "seat: ${SEAT_MAX} calls without done" >> "$log"; return 1; fi
    rc=4; k=0
    while [[ "$rc" == "4" ]] && (( k < 4 )); do
      k=$((k + 1)); rc=0
      h=$( (cd "$clone" && bash "$GATE" snapshot --manifest "$m" 2>>"$log" | jq -r '.H // empty' 2>/dev/null) || true)
      ( cd "$clone" && bash "$GATE" act --manifest "$m" --kind router-shift --target "$TARGET_ALIAS" \
          --cutpoint 커밋 --surface 워크트리쓰기 --snapshot-digest "$h" \
          -- "$reason" -p "/cc-cmds:autopilot-router-shift $m" ) < /dev/null >> "$log" 2>&1 || rc=$?
    done
    case "$rc" in
      0) ;;
      *) return "$rc" ;;
    esac
    [[ -e "$rd/done" ]] && return 0
    if [[ "$(latest_handoff_reason "$clone/docs/pipeline-run/$rid.md")" == "상한" ]]; then reason="상한"; else reason="대기"; fi
  done
}

mark_invalid() {
  local n="$1" why="$2"
  kv_set "$ST/pair-$n/pair.state" status "무효"
  kv_set "$ST/pair-$n/pair.state" invalid_reason "$why"
  mkdir -p "$EXP/pairs/$n"
  kv_set "$EXP/pairs/$n/pair.tsv" status "무효"
  kv_set "$EXP/pairs/$n/pair.tsv" invalid_reason "$why"
  say "pair ${n}: invalid — ${why} (rerun with --rerun-pair ${n})"
}

pair_invalid() { [[ "$(kv "$ST/pair-$1/pair.state" status)" == "무효" ]]; }

run_seat_or_stop() {
  local n="$1" kind="$2" ps="$ST/pair-$1" m clone rid rc=0
  m=$(kv "$ps/pair.state" "${kind}_manifest"); clone=$(kv "$ps/pair.state" clone); rid=$(kv "$ps/pair.state" "${kind}_run")
  # A run not yet opened gets fresh manifest times, so a dry run's deadline is
  # never inherited.
  if [[ ! -d "$RUN_ROOT/$rid" ]]; then write_run_files "$kind" "$n"; m=$(kv "$ps/pair.state" "${kind}_manifest"); fi
  [[ -d "$RUN_ROOT/$rid" ]] || guard "$RESERVE_RUN" "the ${kind} run of pair ${n}"
  seat "$m" "$clone" "$rid" "$ps/seat-$kind.log" || rc=$?
  case "$rc" in
    0) return 0 ;;
    5)
      kv_set "$ps/pair.state" status "사람 대기"
      echo "solo-audit-experiment: pair ${n}: the ${kind} run is waiting on an approval for a person (exit 5 from the gate). Answer it at the run's seat, then call the same command again." >&2
      exit 3 ;;
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
  clone=$(kv "$ps/pair.state" clone); doc=$(kv "$ps/pair.state" doc)
  rid=$(kv "$ps/pair.state" design_run); orig=$(kv "$ps/pair.state" orig_run)
  rd="$RUN_ROOT/$rid"
  kv_set "$ps/pair.state" design_done 1
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
  clone=$(kv "$ps/pair.state" clone); doc=$(kv "$ps/pair.state" doc)
  kv_set "$ps/pair.state" audit_done 1
  local rep="$clone/docs/design-audit/$(report_name "$doc")"
  if [[ ! -f "$rep" ]] || ! has_fence "$rep"; then
    mark_invalid "$n" "감사 보고서 없음 (공시 블록 있는 보고서)"
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
  # Ambiguous defects go to a person. A row a person already judged is kept.
  local rv="$EXP/classify/review.tsv"
  [[ -f "$rv" ]] || printf '표지\tid\t라우팅\t모델 사유\t사람 판정\n' > "$rv"
  jq -r --arg l "$label" '.defects[]? | select(.class == "애매") | [$l, .id, .routing, (.reason | gsub("[\t\n\r]"; " ")), ""] | @tsv' "$out" \
    | while IFS= read -r line; do
        id=$(printf '%s' "$line" | cut -f2)
        awk -F'\t' -v l="$label" -v i="$id" 'NR > 1 && $1 == l && $2 == i { f = 1 } END { exit !f }' "$rv" || printf '%s\n' "$line" >> "$rv"
      done
  return 0
}

classify_all() {
  local n
  for n in $(seq 1 "$PAIRS"); do
    pair_invalid "$n" && continue
    [[ "$(kv "$EXP/pairs/$n/pair.tsv" status)" == "유효" ]] || continue
    classify_report "$n" team || continue
    classify_report "$n" solo || continue
  done
  local rv="$EXP/classify/review.tsv" blank
  [[ -f "$rv" ]] || return 0
  blank=$(awk -F'\t' 'NR > 1 && $5 == "" { n++ } END { print n + 0 }' "$rv")
  if (( blank > 0 )); then
    echo "solo-audit-experiment: ${blank} ambiguous defect(s) wait on a person." >&2
    echo "  fill the 사람 판정 column (골격급 or 비골격) in: $rv" >&2
    echo "  then call again: scripts/solo-audit-experiment.sh run --exp-id ${exp_id} --budget-usd ${budget}" >&2
    exit 3
  fi
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
    if [[ -f "$EXP/classify/review.tsv" ]]; then
      awk -F'\t' -v l="$l" 'NR == 1 || $1 != l' "$EXP/classify/review.tsv" > "$EXP/classify/review.tsv.tmp"
      mv "$EXP/classify/review.tsv.tmp" "$EXP/classify/review.tsv"
    fi
  done
  # Raw call results are kept: their cost stays in the guard's sum.
  case "$ST/pair-$n" in "$STATE_ROOT"/*) rm -rf "$ST/pair-$n" ;; esac
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

for n in $(seq 1 "$PAIRS"); do
  design_pair "$n"
  audit_pair "$n"
  collect_pair "$n"
done
classify_all
bash "$COMPARE" --exp "$EXP" || die "solo-audit-compare failed"
say "$(tail -n 1 "$EXP/report.md") → $EXP/report.md"
exit 0
