#!/usr/bin/env bash
# The paired re-review of the review's promoted seats: run the whole unattended
# review three times on the same bytes — twice with today's plugin (a promoted
# seat runs opus) and once with a plugin whose tier file keeps a promoted seat
# on its class model — and hand the reports to
# `scripts/review-seat-promotion-compare.sh pairs` for the verdict.
#
# Six stages; a second call skips work whose output already exists and goes on
# from where the first stopped:
#   1 select    candidates among <repo>/docs/reviews/*.md, quantile picks and
#               reserves → selection.tsv
#   2 branches  two detached clones of commit C with no remote: promo-opus is C,
#               promo-sonnet adds one local commit changing three sentences of
#               the tier file (fixed author and date)
#   3 prepare   per sample and branch a target clone with no remote, holding only
#               a local branch at the report's `리뷰 HEAD` and `refs/exp/base`,
#               the design document copied in, runs/<n>-<branch>/{cmd,inputs,halt/}
#   4 review    one headless session per branch, launched directly — not through
#               the gate — with exactly the environment of the closed list below
#   5 collect   validity per branch report → samples.tsv; one invalid branch
#               stops the slot, and its next reserve runs all three branches
#   6 verdict   review-seat-promotion-compare.sh pairs → report.md
#
# Usage:
#   scripts/review-seat-promotion-pair.sh [run] [--exp-id <id>] --budget-usd <N> [--repo <dir>] [--ref <commit>]
#   scripts/review-seat-promotion-pair.sh run --dry-run [--exp-id <id>] [--repo <dir>] [--ref <commit>]
#   scripts/review-seat-promotion-pair.sh run --pilot --budget-usd <N> [--exp-id <id>] [--repo <dir>] [--ref <commit>]
#   scripts/review-seat-promotion-pair.sh status --exp-id <id> [--repo <dir>]
#   scripts/review-seat-promotion-pair.sh --rerun-sample <n> --exp-id <id> --budget-usd <N> [--repo <dir>]
#
#   --exp-id      YYYYMMDD-<8 hex>; made on the first call when absent
#   --budget-usd  required by every call that may start billed work, no default:
#                 before each new review session, spent + RESERVE_RUN must not
#                 exceed it (spent is the costs.tsv sum, a `-` row counting the
#                 whole reserve)
#   --dry-run     select, branches and prepare, then print the 15 review command
#                 lines; the model CLI is never called
#   --pilot       select and branches, then prepare and review only the opus-1
#                 branch of quantile 1's pick and check it as collect does,
#                 then that the JSON has total_cost_usd and an empty
#                 permission_denials and that the witness hook logged no
#                 witness command it left undecided; pilot/result says `통과` or `실패 — <condition>`. The main run
#                 (`run`, `--rerun-sample`) stops with exit 1 before any billed
#                 call unless the same experiment's pilot/result says `통과`
#   --rerun-sample  discard slot n's state, runs and records and run it again
#                 from `선정 <n>`
#   --repo        the main checkout (default: the main worktree of this
#                 script's checkout — `docs/` is untracked and lives there only);
#                 without <repo>/docs/reviews/ the call ends with exit 2
#   --ref         commit C the branches are made from (default: HEAD of --repo)
#
# Environment:
#   PROMO_EXP_STATE_ROOT   clones, sessions, settings
#                          (default ${HOME}/.local/state/cc-cmds/review-seat-promotion-exp)
#   PROMO_EXP_CLAUDE_BIN   the model CLI (default `claude` on PATH); tests put a
#                          stub here
#   PROMO_EXP_GH_BIN       the GitHub CLI select reads a pull request's title,
#                          body and labels with (default `gh` on PATH); tests put
#                          a stub here
#   Every inherited CC_PIPELINE_* variable is unset at start: the review
#   sessions belong to no run.
#
# Records: <repo>/docs/review-seat-promotion-pair/<exp-id>/ holds selection.tsv,
# samples.tsv, costs.tsv, reports/, report.md, meta, session-env.tsv and, after a
# pilot, pilot/. The state root holds the clones, runs/, the settings files and
# the instruction files.
#
# RESERVE_RUN. 150 is the reserve the precedent runner
# (scripts/reader-model-pair-audit.sh) kept for one audit. Measured on this
# host on 2026-11-01 over the run ledgers of the main checkout
# (docs/pipeline-run/<run-id>.md): a review stage's cost, read as the rise of the
# cumulative `cost` row written right after a `stage-result` row of kind review,
# was at most 141.29 USD (run 20260906-5c32f10c) over 1283 such rows. The
# reserve stays at 150, above that maximum.
#
# Restoring the original review's inputs. Every branch of one sample gets the
# same inputs, read from the run that sent the original review — the run id
# and segment are read from the report's file name
# (`[seg-]<YYYYMMDD-8hex>-<segment>-(cycle|c)<n>.md`) — and from the report,
# except a pull request's title, body and labels, which neither keeps and which
# are read where the original review read them, on GitHub:
#
#   | field             | read from                                              | not received        | blocked (입력 복원 불가)                       |
#   | 설계 문서          | the run manifest's `**설계 문서**:`; `(없음)` → the       | (never — the review | the manifest is missing, or the document is    |
#   |                   | anchor brief rebuilt from that manifest (the driver's    | always gets one)    | not in the main checkout                       |
#   |                   | own layout)                                              |                     |                                                |
#   | --expand          | the manifest plan's `review_expand` list                 | empty list → 없음   | the plan JSON does not parse                   |
#   | PR 제목·본문·라벨   | the report's `- **PR**:` line: `#<N>` → today's title,  | no line, or a value | any other value; --repo's origin is not a      |
#   |                   | body and labels from `gh pr view <N> --repo             | starting `없음` or   | GitHub repository; the `gh pr view` call fails |
#   |                   | <owner>/<repo> --json title,body,labels`, <owner>/<repo> | `해당 없음` → 없음    | or its JSON does not parse                     |
#   |                   | from --repo's origin                                     |                     |                                                |
#   | --slice           | the report's `**슬라이스 범위**:` line: `슬라이스 <id>` →  | `적용 안 됨 — 인자   | the line is missing                            |
#   |                   | <id>; `적용 안 됨 — <other>` → the segment id             | 없음` → 없음         |                                                |
#   | --declared-files  | the ledger's first `segment` row of the segment,         | empty or `-` → 없음 | no such row, or a truncated value whose full   |
#   |                   | `선언 파일 집합=` (its full record when truncated)          |                     | record is gone                                 |
#   | 설계 문서 지시문    | `설계는 <the copy's absolute path>`, from the 설계 문서 row | (never)             | as 설계 문서                                    |
#
# The document is copied as it stands in the main checkout today; a document
# rewritten since the original review is copied as rewritten. inputs records the
# copy's sha256, so the three branches of one sample provably got the same bytes.
# A pull request's title, body and labels are likewise today's: a body or label
# edited since the original review is restored as edited, and inputs records
# the number, the title, the body's sha256 and the labels. That `gh pr view` is
# a GitHub read select makes, so a dry run makes it too; the review session
# never reaches GitHub (its target clone has no remote, and its settings refuse
# `gh`), and the restored metadata reaches it in the `-p` instructions because
# the local diff mode has no pull request to read.
#
# The review session's environment — the closed list. Nothing outside it is
# added to or removed from the environment the runner inherited, and no flag
# outside it is passed. `게이트` is the value the gate gives a review stage at
# commit C (run.sh `stage_launch_flags`, stage-wrapper.sh, gate.sh's launch and
# `gate_autocompact_argv_value`), read from the branch clone at prepare; a row
# marked 같음 whose two values differ stops the call with exit 1. prepare writes
# the list to session-env.tsv.
#
# CLAUDE_CONFIG_DIR is the caller's lane directory, `${CLAUDE_CONFIG_DIR:-$HOME/.claude}`
# resolved once to an absolute path, passed unchanged to all three branches, as
# the gate gives a stage the lane directory it is logged in with. The account's
# login comes with it. The runner never creates, removes or writes into that
# directory. An installed plugin of the same name is kept from winning over the
# --plugin-dir copy by the `enabledPlugins` of --settings, not by this
# directory. The cost: a review session shares the directory's harness state
# with the lane's other sessions and gets the lane's user settings (their allow
# rules, hooks and env) merged under --settings, as a gate stage does.
#
# Exit codes:
#   0 — a verdict was written (`판정 불가` included), a dry run finished, or the
#       pilot passed
#   1 — failure (a failed pilot included)
#   2 — usage error
#   4 — budget guard: the next session would pass --budget-usd; the slots not
#       finished are invalid and a verdict was written. The same command with a
#       larger budget carries them on.
#
# Compatibility: bash 3.2 (macOS) — no associative arrays, no mapfile.
# Non-ASCII literals follow a `${var}` brace, never a bare `$var`.

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)

SAMPLES=5
RESERVE_RUN=150
BRANCHES="opus-1 sonnet opus-2"
TIER_FILE="plugins/cc-cmds/skills/_common/team-model-tier.md"
COMPARE_REL="scripts/review-seat-promotion-compare.sh"
# The one local branch a target clone keeps, and the ref of the range's base.
TARGET_BRANCH="work"
BASE_REF="refs/exp/base"
WAIT_CEILING_MS=14400000
AUTOCOMPACT_REVIEW=300000
LEAD_MODEL="opus"
LEAD_EFFORT="medium"

# The three sentences of the tier file the sonnet branch changes, old and new.
SWAP_OLD_1='A promoted seat runs `opus`.'
SWAP_NEW_1='A promoted seat runs its class model; the record still writes `출처=승격` and its `지표`.'
SWAP_OLD_2='the triggers below keep its seat on `opus`'
SWAP_NEW_2='the triggers below mark its seat as promoted'
SWAP_OLD_3='promotes every `sonnet` seat'
SWAP_NEW_3='marks as promoted every `sonnet` seat'

usage() { echo "review-seat-promotion-pair: $1" >&2; exit 2; }
die() { echo "review-seat-promotion-pair: $1" >&2; exit 1; }
say() { echo "review-seat-promotion-pair: $1"; }

# ---------- arguments --------------------------------------------------------

cmd="run"
exp_id=""
budget=""
repo=""
ref=""
rerun=""
dry=0
pilot=0

while (( $# > 0 )); do
  case "$1" in
    run|status) cmd="$1"; shift ;;
    --rerun-sample) rerun="${2:-}"; cmd="rerun"; shift 2 || usage "--rerun-sample needs a sample number" ;;
    --dry-run) dry=1; shift ;;
    --pilot) pilot=1; shift ;;
    --exp-id) exp_id="${2:-}"; shift 2 || usage "--exp-id needs a value" ;;
    --budget-usd) budget="${2:-}"; shift 2 || usage "--budget-usd needs a value" ;;
    --repo) repo="${2:-}"; shift 2 || usage "--repo needs a value" ;;
    --ref) ref="${2:-}"; shift 2 || usage "--ref needs a value" ;;
    -h|--help) grep -E '^# ' "$0" | cut -c3-; exit 0 ;;
    *) usage "unknown argument: $1" ;;
  esac
done

if [[ -z "$repo" ]]; then
  repo=$(cd "$script_dir" && git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || usage "cannot find the main worktree of $script_dir; pass --repo"
  repo=$(dirname "$repo")
fi
[[ -d "$repo" ]] || usage "--repo is not a directory: $repo"
repo=$(cd "$repo" && pwd)
[[ -d "$repo/docs/reviews" ]] || usage "no docs/reviews/ under $repo"

if [[ -n "$exp_id" && ! "$exp_id" =~ ^[0-9]{8}-[0-9a-f]{8}$ ]]; then
  usage "--exp-id must be YYYYMMDD-<8 hex>: $exp_id"
fi
if [[ -n "$budget" && ! "$budget" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
  usage "--budget-usd must be a number: $budget"
fi
(( dry == 0 || pilot == 0 )) || usage "--dry-run and --pilot do not combine"
case "$cmd" in
  status) [[ -n "$exp_id" ]] || usage "status needs --exp-id" ;;
  rerun)
    [[ -n "$exp_id" ]] || usage "--rerun-sample needs --exp-id"
    [[ "$rerun" =~ ^[1-9][0-9]*$ ]] && (( rerun <= SAMPLES )) || usage "--rerun-sample needs 1..${SAMPLES}: $rerun"
    (( dry == 0 && pilot == 0 )) || usage "--rerun-sample does not combine with --dry-run or --pilot"
    ;;
esac
if [[ "$cmd" != "status" && "$dry" == "0" && -z "$budget" ]]; then
  usage "--budget-usd <N> is required for a call that may start billed work (no default)"
fi

STATE_ROOT="${PROMO_EXP_STATE_ROOT:-$HOME/.local/state/cc-cmds/review-seat-promotion-exp}"
CLAUDE_BIN="${PROMO_EXP_CLAUDE_BIN:-claude}"
GH_BIN="${PROMO_EXP_GH_BIN:-gh}"

# A variable inherited from a pipeline stage would make the review session a
# seat of that run. The experiment's sessions belong to no run.
for v in $(compgen -e | grep '^CC_PIPELINE_' || true); do unset "$v"; done

# The caller's lane directory, absolute: the login the review sessions run
# with, the source of `enabledPlugins` and of the personal rules.
# A relative value is made absolute against the current directory; an absolute
# one is kept as spelled, symbolic links unresolved, because the CLI keys the
# lane's login on the directory as it is given.
LANE_CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
[[ "$LANE_CFG" == /* ]] || LANE_CFG="$PWD/$LANE_CFG"

if [[ -z "$exp_id" ]]; then
  [[ "$cmd" == "run" ]] || usage "--exp-id is required"
  exp_id="$(date -u +%Y%m%d)-$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
fi
EXP="$repo/docs/review-seat-promotion-pair/$exp_id"
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

kv_del() {
  [[ -f "$1" ]] || return 0
  local tmp="$1.tmp.$$"
  awk -F'\t' -v k="$2" '$1 != k' "$1" > "$tmp"
  mv "$tmp" "$1"
}

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
sha_of() { shasum -a 256 "$1" | cut -d' ' -f1; }

# bold_line <file> <label> — the value after the first `**<label>**: ` at the
# start of a line or after `- `.
bold_line() {
  awk -v l="**$2**: " '{ s = $0; sub(/^- /, "", s) } index(s, l) == 1 { print substr(s, length(l) + 1); exit }' "$1"
}

# shq <word> — the word quoted for a shell, single quotes.
shq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

COMPARE="$script_dir/review-seat-promotion-compare.sh"

# scan_h <report> — the header line fields of the compare script's reader.
scan_h() { { bash "$COMPARE" scan "$1" 2>/dev/null || true; } | awk -F'\t' '$1 == "H"'; }

# ---------- cost guard -------------------------------------------------------

costs_init() {
  mkdir -p "$EXP"
  [[ -f "$EXP/costs.tsv" ]] || printf 'n\t갈래\t시작\t끝\t종료 코드\ttotal_cost_usd\n' > "$EXP/costs.tsv"
}

# spent — the costs.tsv sum; a `-` row counts the whole reserve.
spent() {
  [[ -f "$EXP/costs.tsv" ]] || { printf '0.0000'; return 0; }
  awk -F'\t' -v r="$RESERVE_RUN" 'NR > 1 { s += ($6 == "-" ? r : $6) } END { printf "%.4f", s + 0 }' "$EXP/costs.tsv"
}

# over_budget — whether spent + reserve passes the budget.
over_budget() { awk -v s="$(spent)" -v r="$RESERVE_RUN" -v b="$budget" 'BEGIN { exit !(s + r > b) }'; }

samples_init() {
  mkdir -p "$EXP"
  [[ -f "$EXP/samples.tsv" ]] || printf 'n\t보고서\tbase\thead\t상태\t사유\t승격 좌석\n' > "$EXP/samples.tsv"
}

samples_get() { [[ -f "$EXP/samples.tsv" ]] && awk -F'\t' -v n="$1" 'NR > 1 && $1 == n { print; exit }' "$EXP/samples.tsv" || true; }

# samples_put <n> <row|""> — replace sample n's row (drop it when empty), rows
# kept in n order.
samples_put() {
  local f="$EXP/samples.tsv"
  samples_init
  {
    head -n 1 "$f"
    { tail -n +2 "$f" | awk -F'\t' -v n="$1" '$1 != n'
      [[ -z "$2" ]] || printf '%s\n' "$2"
    } | LC_ALL=C sort -t "$(printf '\t')" -k1,1n
  } > "$f.tmp"
  mv "$f.tmp" "$f"
}

slot_state() { printf '%s/slot-%s.state' "$ST" "$1"; }

slot_done() {
  local f; f=$(slot_state "$1")
  case "$(kv "$f" status)" in
    유효) return 0 ;;
    무효) [[ "$(kv "$f" exhausted)" == "1" ]]; return ;;
  esac
  return 1
}

verdict() {
  bash "$COMPARE" pairs --exp "$EXP" --out "$EXP/report.md.tmp" || die "review-seat-promotion-compare pairs failed"
  awk -v c="$(spent)" 'index($0, "- 실험: ") == 1 { print; print "- 비용 합계(costs.tsv, `-` 행은 예비 전액): " c " USD"; next } { print }' \
    "$EXP/report.md.tmp" > "$EXP/report.md"
  rm -f "$EXP/report.md.tmp"
}

# budget_close <refusal> — every slot not finished gets an invalid samples.tsv
# row under `예산 상한 — <refusal>`, its earlier row kept for budget_restore;
# then the verdict, exit 4.
budget_close() {
  local why="예산 상한 — $1" n f row
  for n in $(seq 1 "$SAMPLES"); do
    slot_done "$n" && continue
    f=$(slot_state "$n"); mkdir -p "$ST"
    [[ -n "$(kv "$f" budget_stop)" ]] && continue
    row=$(samples_get "$n")
    kv_set "$f" budget_stop "${row:--}"
    samples_put "$n" "$(printf '%s\t%s\t%s\t%s\t무효\t%s\t-' "$n" "$(kv "$f" sample)" "$(kv "$f" base)" "$(kv "$f" head)" "$why")"
    say "sample ${n}: invalid — ${why}"
  done
  verdict
  say "$(tail -n 1 "$EXP/report.md") → $EXP/report.md (closed on the budget; call again with a larger --budget-usd to carry on)"
  exit 4
}

budget_restore() {
  local n f row
  for n in $(seq 1 "$SAMPLES"); do
    f=$(slot_state "$n")
    row=$(kv "$f" budget_stop)
    [[ -n "$row" ]] || continue
    if [[ "$row" == "-" ]]; then samples_put "$n" ""; else samples_put "$n" "$row"; fi
    kv_del "$f" budget_stop
  done
}

guard() {
  if over_budget; then
    local msg="spent $(spent) + reserve ${RESERVE_RUN} > budget ${budget}; not starting $1"
    echo "review-seat-promotion-pair: budget guard — ${msg}" >&2
    budget_close "$msg"
  fi
}

# ---------- stage 1: select --------------------------------------------------

# report_range <report> — `<base> <head> <dots>` from the `리뷰 대상` line, or
# nothing.
report_range() {
  bold_line "$1" '리뷰 대상' | LC_ALL=C grep -oE '[0-9a-f]{7,40}\.\.\.?[0-9a-f]{7,40}' | head -n 1 \
    | awk '{ i = index($0, "..."); n = 3; if (!i) { i = index($0, ".."); n = 2 }
             print substr($0, 1, i - 1), substr($0, i + n), n }' || true
}

# stem_cycle <name> — `<stem>\t<cycle>`: the name without a trailing
# `-cycle<n>.md` or `-c<n>.md`, and n (0 when there is no such suffix).
stem_cycle() {
  local nm="$1"
  if [[ "$nm" =~ ^(.*)-(cycle|c)([0-9]+)\.md$ ]]; then
    printf '%s\t%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[3]}"
  else
    printf '%s\t0\n' "${nm%.md}"
  fi
}

# gh_slug — `<owner>/<repo>` of the GitHub repository --repo's origin names
# (https, ssh:// and scp-like URLs, a trailing `.git` dropped), or nothing.
gh_slug() {
  local u
  u=$(cd "$repo" && git remote get-url origin 2>/dev/null) || return 0
  u="${u%/}"; u="${u%.git}"
  if [[ "$u" =~ ^(https?|ssh|git)://([^@/]+@)?github\.com(:[0-9]+)?/([^/]+)/([^/]+)$ ]]; then
    printf '%s/%s' "${BASH_REMATCH[4]}" "${BASH_REMATCH[5]}"
  elif [[ "$u" =~ ^([^@/]+@)?github\.com:([^/]+)/([^/]+)$ ]]; then
    printf '%s/%s' "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
  fi
}

# GH_SLUG is resolved once, before select reads the reports.
GH_SLUG=""

# restore_pr <report> <out-prefix> — the PR field. Prints the key<TAB>value
# lines pr, pr_title, pr_body_sha and pr_labels (all empty when the original
# review got no pull request) and writes the body to <out-prefix>.pr-body; on a
# blocked field prints `<field>: <why>` and returns 1.
restore_pr() {
  local r="$1" body="$2.pr-body" v num js title labels
  v=$(bold_line "$r" 'PR')
  if [[ -z "$v" || "$v" == 없음* || "$v" == 해당\ 없음* ]]; then
    rm -f "$body"
    printf 'pr\t\npr_title\t\npr_body_sha\t\npr_labels\t\n'
    return 0
  fi
  if [[ ! "$v" =~ ^#([0-9]+) ]]; then
    echo "PR 제목·본문·라벨: 원 리뷰가 PR 을 받았는지 가릴 수 없다 (${v})"; return 1
  fi
  num="${BASH_REMATCH[1]}"
  [[ -n "$GH_SLUG" ]] || { echo "PR 제목·본문·라벨: --repo 의 origin 이 GitHub 저장소로 풀리지 않는다"; return 1; }
  js=$("$GH_BIN" pr view "$num" --repo "$GH_SLUG" --json title,body,labels 2>/dev/null) \
    && title=$(printf '%s' "$js" | jq -er '.title | strings' 2>/dev/null) \
    && labels=$(printf '%s' "$js" | jq -er '[.labels[]?.name | strings] | join(",")' 2>/dev/null) \
    && printf '%s' "$js" | jq -ej '.body // "" | strings' > "$body" 2>/dev/null \
    || { rm -f "$body"; echo "PR 제목·본문·라벨: gh pr view #${num} 조회 실패"; return 1; }
  title=$(printf '%s' "$title" | tr '\t\r\n' '   ')
  printf 'pr\t%s\npr_title\t%s\npr_body_sha\t%s\npr_labels\t%s\n' "$num" "$title" "$(sha_of "$body")" "$labels"
}

# restore_inputs <report> <out> — the original review's inputs, one
# key<TAB>value line each, written to <out>; on a blocked field prints
# `<field>: <why>` and returns 1. Keys: rid seg doc_src doc_rel expand slice
# declared pr pr_title pr_body_sha pr_labels; a received pull request's body is
# beside <out> as <out without .tsv>.pr-body.
restore_inputs() {
  local r="$1" out="$2" nm rid seg man led docv rel exp sl decl full pr
  nm=$(basename "$r")
  if [[ "$nm" =~ ^(seg-)?([0-9]{8}-[0-9a-f]{8})-(.+)-(cycle|c)[0-9]+\.md$ ]]; then
    rid="${BASH_REMATCH[2]}"; seg="${BASH_REMATCH[3]}"
  else
    echo "원 런: 파일 이름에서 런 id 와 세그먼트를 읽을 수 없다"; return 1
  fi
  man="$repo/docs/pipeline-run/$rid.plan.md"; led="$repo/docs/pipeline-run/$rid.md"
  [[ -f "$man" ]] || { echo "설계 문서: 원 런 매니페스트가 없다 ($rid)"; return 1; }
  [[ -f "$led" ]] || { echo "--declared-files: 원 런 원장이 없다 ($rid)"; return 1; }
  docv=$(awk -v l='**설계 문서**: ' 'index($0, l) == 1 { print substr($0, length(l) + 1); exit }' "$man")
  if [[ -z "$docv" ]]; then echo "설계 문서: 매니페스트에 설계 문서 칸이 없다"; return 1; fi
  if [[ "$docv" == "(없음)" ]]; then
    docv="anchor"
    rel="docs/anchor-brief-${rid}.md"
  else
    case "$docv" in /*) rel="${docv#"$repo"/}" ;; *) rel="$docv" ;; esac
    [[ "$rel" != /* && -f "$repo/$rel" ]] || { echo "설계 문서: 메인 체크아웃에 없다 ($docv)"; return 1; }
    docv="$repo/$rel"
  fi
  exp=$(awk '$0 == "```json" { inj = 1; next } inj && $0 == "```" { exit } inj { print }' "$man" \
    | jq -r '.review_expand | if type == "array" then [.[] | strings] | join(",") else "" end' 2>/dev/null) \
    || { echo "--expand: 매니페스트 계획 JSON 을 읽을 수 없다"; return 1; }
  sl=$(bold_line "$r" '슬라이스 범위')
  if [[ -z "$sl" ]]; then echo "--slice: 보고서에 슬라이스 범위 줄이 없다"; return 1
  elif [[ "$sl" =~ ^슬라이스\ ([^ ]+) ]]; then sl="${BASH_REMATCH[1]}"
  elif [[ "$sl" == "적용 안 됨 — 인자 없음" ]]; then sl=""
  elif [[ "$sl" == 적용\ 안\ 됨* ]]; then sl="$seg"
  else echo "--slice: 슬라이스 범위 줄을 읽을 수 없다 ($sl)"; return 1
  fi
  decl=$(awk -v s="$seg" 'index($0, "- `segment` ") == 1 && index($0, "| id=" s " |") > 0 && index($0, "| 선언 파일 집합=") > 0 { print; exit }' "$led")
  if [[ -z "$decl" ]]; then echo "--declared-files: 원장에 세그먼트 ${seg} 의 선언 파일 집합 행이 없다"; return 1; fi
  decl=$(printf '%s\n' "$decl" | awk -F' [|] ' '{ for (i = 1; i <= NF; i++) if (index($i, "선언 파일 집합=") == 1) { print substr($i, length("선언 파일 집합=") + 1); exit } }')
  if [[ "$decl" == *"(잘림) (전체: "*")" ]]; then
    full="${decl##*(전체: }"; full="${full%)}"
    [[ -f "$full" ]] || { echo "--declared-files: 잘린 값의 전체 기록이 없다 ($full)"; return 1; }
    decl=$(cat "$full")
  elif [[ "$decl" == *"(잘림)"* ]]; then
    echo "--declared-files: 잘린 값에 전체 기록 경로가 없다"; return 1
  fi
  # The row writes each path in backticks; the review's dispatch line carries
  # the same list bare, `a, b`.
  decl=$(printf '%s' "$decl" | tr -d '`' | sed -E 's/[[:space:]]+$//')
  [[ "$decl" != "-" && "$decl" != "없음" ]] || decl=""
  pr=$(restore_pr "$r" "${out%.tsv}") || { printf '%s\n' "$pr"; return 1; }
  {
    printf 'rid\t%s\nseg\t%s\ndoc_src\t%s\ndoc_rel\t%s\n' "$rid" "$seg" "$docv" "$rel"
    printf 'expand\t%s\nslice\t%s\ndeclared\t%s\n' "$exp" "$sl" "$decl"
    printf '%s\n' "$pr"
  } > "$out"
}

select_samples() {
  local sel="$EXP/selection.tsv"
  [[ -f "$sel" ]] && return 0
  mkdir -p "$EXP" "$ST/inputs"
  GH_SLUG=$(gh_slug)
  [[ -f "$EXP/meta" ]] || printf 'exp-id\t%s\nrepo\t%s\ncommit\t%s\nstarted\t%s\n' "$exp_id" "$repo" "$C" "$(now_iso)" > "$EXP/meta"
  local rows="$ST/.rows.tsv" r nm h ex date summ sp0 sp1 rhead pl rest mode why b hh dots base head p0p1 sc stem cy
  : > "$rows"
  # Pass 1: every report's own conditions, and the stems of the full reviews.
  local stems="$ST/.stems.tsv"; : > "$stems"
  while IFS= read -r r; do
    nm=$(basename "$r")
    case "$nm" in .*|*.lead-fix.md) continue ;; esac
    h=$(scan_h "$r")
    IFS='	' read -r _ ex date summ sp0 sp1 rhead pl rest <<<"$h"
    # A full review writes `전체` and often a gloss after it (`전체 (델타 아님)`,
    # `전체 — …`); a cap re-check also starts with `전체` and names `재확인`.
    mode=$(bold_line "$r" '리뷰 모드'); [[ -n "$mode" ]] || mode="전체"
    case "$mode" in *재확인*) ;; 전체|"전체 "*) mode="전체" ;; esac
    sc=$(stem_cycle "$nm"); stem="${sc%%	*}"; cy="${sc##*	}"
    why=""; base="-"; head="-"; p0p1="-"
    [[ "$summ" == "정규" ]] && p0p1=$((sp0 + sp1))
    if [[ -z "$pl" || "$pl" == "-" ]]; then why="출처=승격 행이 없다"
    elif [[ "$mode" != "전체" ]]; then why="리뷰 모드가 전체가 아니다 (${mode})"
    fi
    [[ "$mode" != "전체" ]] || printf '%s\t%s\t%s\n' "$stem" "$cy" "$nm" >> "$stems"
    # `-` stands for an empty field: `read` with a tab IFS folds two tabs into one.
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$nm" "${why:--}" "$stem" "$cy" "$p0p1" "${rhead:--}" >> "$rows"
  done < <(find "$repo/docs/reviews" -maxdepth 1 -name '*.md' | LC_ALL=C sort)

  # Pass 2: the stem rule, the range and its commits, the inputs.
  local rows2="$ST/.rows2.tsv" first
  : > "$rows2"
  while IFS='	' read -r nm why stem cy p0p1 rhead; do
    r="$repo/docs/reviews/$nm"; base="-"; head="-"
    [[ "$why" != "-" ]] || why=""
    if [[ -z "$why" ]]; then
      first=$(awk -F'\t' -v s="$stem" '$1 == s && (best == "" || $2 + 0 < best + 0 || ($2 + 0 == best + 0 && $3 < bn)) { best = $2; bn = $3 } END { print bn }' "$stems")
      [[ "$first" == "$nm" ]] || why="같은 세그먼트 뒤 사이클"
    fi
    if [[ -z "$why" ]] && grep -qx '## 상한 사이클 재확인' "$r"; then why="상한 사이클 재확인 절이 있다"; fi
    if [[ -z "$why" ]]; then
      read -r b hh dots <<<"$(report_range "$r")"
      if [[ -z "${b:-}" ]]; then why="리뷰 대상에 커밋 범위가 없다"
      elif [[ "$p0p1" == "-" ]]; then why="발견 요약이 정규가 아니다"
      elif (( p0p1 < 1 )); then why="P0+P1 이 0 이다"
      else
        base=$(cd "$repo" && git rev-parse --verify --quiet "${b}^{commit}" 2>/dev/null) || base=""
        head=$(cd "$repo" && git rev-parse --verify --quiet "${hh}^{commit}" 2>/dev/null) || head=""
        if [[ -z "$base" || -z "$head" ]]; then why="범위의 sha 를 풀 수 없다"; base="${base:--}"; head="${head:--}"
        else
          if [[ "$dots" == "3" ]]; then
            base=$(cd "$repo" && git merge-base "$base" "$head" 2>/dev/null) || { why="세 점 범위의 merge-base 가 없다"; base="-"; }
          fi
          if [[ -z "$why" && "$head" != "$rhead" ]]; then why="리뷰 HEAD 불일치 (${rhead})"
          elif [[ -z "$why" ]]; then
            if [[ -z "$(cd "$repo" && git for-each-ref --contains "$base" --count=1)" || -z "$(cd "$repo" && git for-each-ref --contains "$head" --count=1)" ]]; then
              why="ref 에서 닿지 않는 커밋"
            fi
          fi
        fi
      fi
    fi
    if [[ -z "$why" ]]; then
      local blocked
      if ! blocked=$(restore_inputs "$r" "$ST/inputs/$nm.tsv"); then why="입력 복원 불가 — ${blocked}"; fi
    fi
    printf '%s\t%s\t%s\t%s\t%s\n' "$nm" "${why:--}" "$base" "$head" "$p0p1" >> "$rows2"
  done < "$rows"

  # Quantile picks over the candidates (P0+P1 ascending, then name bytes): the
  # five positions int((m − 1) × j ÷ 4 + 0.5) are the picks of quantiles 1–5;
  # every other candidate is a reserve of its nearest position (a tie to the
  # smaller j), used by distance, then by rank.
  local cands m_ order="$ST/order.tsv"
  cands=$(awk -F'\t' '$2 == "-" { print $5 "\t" $1 }' "$rows2" | LC_ALL=C sort -t "$(printf '\t')" -k1,1n -k2,2)
  m_=$(printf '%s' "$cands" | grep -c . || true)
  : > "$order"
  if (( m_ >= SAMPLES )); then
    printf '%s\n' "$cands" | awk -F'\t' -v m="$m_" -v p="$SAMPLES" '
      { nm[NR - 1] = $2 }
      END {
        for (j = 0; j < p; j++) { pos[j] = int((m - 1) * j / (p - 1) + 0.5); used[pos[j]] = 1; print nm[pos[j]] "\t선정\t" (j + 1) "\t0" }
        for (i = 0; i < m; i++) {
          if (i in used) continue
          bd = -1
          for (j = 0; j < p; j++) { d = i - pos[j]; if (d < 0) d = -d; if (bd < 0 || d < bd) { bd = d; bin[i] = j } }
          dist[i] = bd
        }
        for (j = 0; j < p; j++) {
          k = 0
          for (d = 1; d < m; d++) for (i = 0; i < m; i++) if (!(i in used) && bin[i] == j && dist[i] == d) { k++; print nm[i] "\t예비\t" (j + 1) "\t" k }
        }
      }' > "$order"
  fi
  {
    printf '보고서\t처분\t사유\t분위\tbase\thead\tp0p1\n'
    awk -F'\t' -v OFS='\t' 'FILENAME == ARGV[1] { d[$1] = $2; q[$1] = $3; next }
      {
        if ($2 != "-") print $1, "제외", $2, "-", $3, $4, $5
        else if ($1 in d) print $1, d[$1], "-", q[$1], $3, $4, $5
        else print $1, "제외", "후보가 5건 미만이라 선정하지 않는다", "-", $3, $4, $5
      }' "$order" "$rows2"
  } > "$sel"
  rm -f "$rows" "$rows2" "$stems"
  if (( m_ < SAMPLES )); then
    samples_init
    verdict
    say "candidates: ${m_} < ${SAMPLES}; $(tail -n 1 "$EXP/report.md") → $EXP/report.md"
    exit 0
  fi
  say "selected ${SAMPLES} of ${m_} candidates → $sel"
}

# sample_name <slot> <k> — the report of slot n's k-th try: 0 the pick, k the
# k-th reserve; nothing when there is none.
sample_name() {
  if [[ "$2" == "0" ]]; then awk -F'\t' -v q="$1" '$2 == "선정" && $3 == q { print $1; exit }' "$ST/order.tsv"
  else awk -F'\t' -v q="$1" -v k="$2" '$2 == "예비" && $3 == q && $4 == k { print $1; exit }' "$ST/order.tsv"; fi
}

sel_field() { awk -F'\t' -v n="$1" -v c="$2" '$1 == n { print $c; exit }' "$EXP/selection.tsv"; }

# ---------- stage 2: branches ------------------------------------------------

# count_of <file> <text> — how many times the text occurs in the file.
count_of() { awk -v t="$2" '{ s = $0; while ((i = index(s, t)) > 0) { n++; s = substr(s, i + length(t)) } } END { print n + 0 }' "$1"; }

# swap_text <file> <old> <new> — every occurrence replaced.
swap_text() {
  awk -v o="$2" -v w="$3" '{ s = $0; out = ""; while ((i = index(s, o)) > 0) { out = out substr(s, 1, i - 1) w; s = substr(s, i + length(o)) } print out s }' "$1" > "$1.new"
  mv "$1.new" "$1"
}

clone_of() { kv "$ST/branches.state" "${1}_clone"; }
branch_clone() { case "$1" in sonnet) clone_of sonnet ;; *) clone_of opus ;; esac; }

make_branches() {
  local bs="$ST/branches.state"
  [[ "$(kv "$bs" ready)" == "1" ]] && return 0
  mkdir -p "$ST"
  local go="$ST/promo-opus" gs="$ST/promo-sonnet" d i o w sc got
  rm -rf "$go" "$gs"
  for d in "$go" "$gs"; do
    git clone --quiet --no-hardlinks "$repo" "$d" || die "branch clone failed: $d"
    ( cd "$d" && git checkout --quiet --detach "$C" && git remote remove origin ) || die "detaching $d at $C failed"
  done
  [[ -f "$go/$COMPARE_REL" ]] || { rm -rf "$go" "$gs"; die "commit ${C:0:12} has no $COMPARE_REL — the branches need the commit that adds this experiment"; }
  for i in 1 2 3; do
    eval "o=\$SWAP_OLD_$i"
    got=$(count_of "$gs/$TIER_FILE" "$o")
    [[ "$got" == "1" ]] || { rm -rf "$go" "$gs"; die "the tier file of ${C:0:12} holds '${o}' ${got} times, not once"; }
  done
  for i in 1 2 3; do
    eval "o=\$SWAP_OLD_$i; w=\$SWAP_NEW_$i"
    swap_text "$gs/$TIER_FILE" "$o" "$w"
  done
  ( cd "$gs" && git add -- "$TIER_FILE" \
    && GIT_AUTHOR_NAME=work GIT_AUTHOR_EMAIL=work@localhost \
       GIT_AUTHOR_DATE=2026-01-01T00:00:00Z GIT_COMMITTER_NAME=work \
       GIT_COMMITTER_EMAIL=work@localhost GIT_COMMITTER_DATE=2026-01-01T00:00:00Z \
       git commit --quiet --no-verify -m "chore: keep promoted seats on their class model" ) || die "the sonnet branch commit failed"
  sc=$(cd "$gs" && git rev-parse HEAD)
  got=$(cd "$gs" && git diff --numstat "$C" "$sc")
  [[ "$got" == "3	3	${TIER_FILE}" ]] || die "the sonnet branch commit changes more than the three sentences: $(printf '%s' "$got" | tr '\n' ' ')"
  kv_set "$bs" c "$C"
  kv_set "$bs" opus_clone "$go"
  kv_set "$bs" sonnet_clone "$gs"
  kv_set "$bs" opus_commit "$C"
  kv_set "$bs" sonnet_commit "$sc"
  kv_set "$bs" ready 1
  say "branches: promo-opus ${C:0:12} · promo-sonnet ${sc:0:12} (three sentences apart)"
}

# ---------- the closed list --------------------------------------------------

# gate_values — what the gate gives a review stage at commit C, read from the
# opus branch clone: `<key>\t<value>` lines.
gate_values() {
  local g; g=$(clone_of opus)/plugins/cc-cmds/orchestrator
  local flags wait ac wrapper
  flags=$( cd "$(clone_of opus)" && unset CC_ORCH_STAGE_EFFORT CC_ORCH_STAGE_MODEL && CC_ORCH_SOURCE_ONLY=1 && . "$g/run.sh" >/dev/null 2>&1 && stage_launch_flags review ) || flags=""
  wait=$(LC_ALL=C grep -m 1 -oE 'CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS="\$\{CC_ORCH_BG_WAIT_CEILING_MS:-[0-9]+\}"' "$g/gate.sh" | grep -oE '[0-9]+' | tail -n 1 || true)
  ac=$(awk '/^gate_autocompact_argv_value\(\)/ { in_f = 1 } in_f && /review\) printf/ { if (match($0, /[0-9]+/)) print substr($0, RSTART, RLENGTH); exit } in_f && /^}/ { exit }' "$g/gate.sh")
  wrapper="$g/stage-wrapper.sh"
  printf 'model\t%s\n' "$(printf '%s' "$flags" | awk '{ for (i = 1; i < NF; i++) if ($i == "--model") print $(i + 1) }')"
  printf 'effort\t%s\n' "$(printf '%s' "$flags" | awk '{ for (i = 1; i < NF; i++) if ($i == "--effort") print $(i + 1) }')"
  printf 'wait\t%s\n' "${wait:-}"
  printf 'autocompact\t%s\n' "${ac:-}"
  printf 'mds\t%s\n' "$(grep -q 'export CLAUDE_CODE_DISABLE_CLAUDE_MDS=1' "$wrapper" && echo 1)"
  printf 'subagent\t%s\n' "$(grep -q 'export CLAUDE_CODE_ENABLE_APPEND_SUBAGENT_PROMPT=1' "$wrapper" && echo 1)"
  printf 'strict\t%s\n' "$(grep -q -- '--strict-mcp-config' "$wrapper" && echo 실음)"
  printf 'exclude\t%s\n' "$(grep -q -- '--exclude-dynamic-system-prompt-sections' "$wrapper" && echo 실음)"
  printf 'append\t%s\n' "$(grep -q -- '--append-system-prompt-file' "$wrapper" && echo 게이트 합성 지시문)"
  printf 'append_sub\t%s\n' "$(grep -q -- '--append-subagent-system-prompt-file' "$wrapper" && echo 게이트 합성 구성원 지시문)"
}

# write_session_env — the closed list, the gate's values filled in, to
# session-env.tsv. A row marked 같음 whose two values differ stops the call.
write_session_env() {
  local gv="$ST/gate-values.tsv" f="$EXP/session-env.tsv"
  gate_values > "$gv"
  local gw ga gm ge gmds gsub gstrict gexcl gapp gappsub
  gw=$(kv "$gv" wait); ga=$(kv "$gv" autocompact); gm=$(kv "$gv" model); ge=$(kv "$gv" effort)
  gmds=$(kv "$gv" mds); gsub=$(kv "$gv" subagent); gstrict=$(kv "$gv" strict); gexcl=$(kv "$gv" exclude)
  gapp=$(kv "$gv" append); gappsub=$(kv "$gv" append_sub)
  {
    printf '칸\t종류\t실행기 값\t게이트 review 스테이지 값\t같음\t사유\n'
    printf 'CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS\t환경 변수\t%s\t%s\t같음\t-\n' "$WAIT_CEILING_MS" "${gw:-미상}"
    printf 'CC_CMDS_STATUSLINE_AUTOINSTALL\t환경 변수\t0\t(싣지 않음 — CC_PIPELINE_STAGE_ID 로 훅이 멈춘다)\t다름\t게이트는 CC_PIPELINE_STAGE_ID 로 상태 줄 훅을 멈추지만 실행기는 그 변수를 지운다\n'
    printf 'XDG_STATE_HOME\t환경 변수\truns/<n>-<갈래>/state 의 절대 경로\t(물려받은 값)\t다름\t증인 스크래치 루트를 갈래 디렉터리 아래로 옮긴다\n'
    printf 'CLAUDE_CODE_DISABLE_CLAUDE_MDS\t환경 변수\t1\t%s\t같음\t-\n' "${gmds:-미상}"
    printf 'CLAUDE_CODE_ENABLE_APPEND_SUBAGENT_PROMPT\t환경 변수\t1\t%s\t같음\t-\n' "${gsub:-미상}"
    printf 'CLAUDE_CONFIG_DIR\t환경 변수\t(호출자가 해석한 레인의 설정 디렉터리)\t(호출자가 해석한 레인의 설정 디렉터리)\t같음\t-\n'
    printf 'CC_PIPELINE_*\t환경 변수\t(지운다)\t(런 변수를 싣는다)\t다름\t리뷰 세션은 어떤 런에도 속하지 않는다\n'
    printf -- '--model\t플래그\t%s\t%s\t같음\t-\n' "$LEAD_MODEL" "${gm:-미상}"
    printf -- '--effort\t플래그\t%s\t%s\t같음\t-\n' "$LEAD_EFFORT" "${ge:-미상}"
    printf -- '--plugin-dir\t플래그\t<갈래 복제본>/plugins/cc-cmds\t<런의 고정 플러그인 사본>/plugins/cc-cmds\t같음\t-\n'
    printf -- '--settings\t플래그\t<상태 루트>/settings/<n>-<갈래>.json\t<런 설정 디렉터리>/review.json\t다름\t게이트 훅 대신 증인 발행 명령과 리드의 nonce 명령만 승인하는 훅 하나를 싣고, enabledPlugins 로 계정의 플러그인을 모두 끄며 --plugin-dir 사본만 남긴다\n'
    printf -- '--strict-mcp-config\t플래그\t실음\t%s\t같음\t-\n' "${gstrict:-미상}"
    printf -- '--append-system-prompt-file\t플래그\t<상태 루트>/instructions/<sha256>.md\t%s\t같음\t-\n' "${gapp:-미상}"
    printf -- '--append-subagent-system-prompt-file\t플래그\t<상태 루트>/instructions/<sha256>.md (구성원)\t%s\t같음\t-\n' "${gappsub:-미상}"
    printf -- '--exclude-dynamic-system-prompt-sections\t플래그\t실음\t%s\t같음\t-\n' "${gexcl:-미상}"
    printf -- '--autocompact\t플래그\t%s\t%s\t같음\t-\n' "$AUTOCOMPACT_REVIEW" "${ga:-미상}"
    printf -- '--no-session-persistence\t플래그\t실음\t(--session-id)\t다름\t세션 기록을 남기지 않는다; 재개 라운드가 막히지 않는지는 시범이 잰다\n'
    printf -- '--output-format\t플래그\tjson\tstream-json\t다름\t비용 기록을 실행기가 진다(result.json 의 total_cost_usd)\n'
    printf -- '--max-budget-usd\t플래그\t%s\t(싣지 않음)\t다름\t세션 예산을 실행기가 진다\n' "$RESERVE_RUN"
    printf -- '-p\t플래그\t리뷰 명령과 지시문\t리뷰 명령과 지시문\t다름\t게이트 밖 세션의 지시문(중단 기록 자리, 게이트·매니페스트 없음)을 더한다\n'
    printf '권한\t설정\tacceptEdits 모드, 대상 복제본 읽기·git 조회·하위 에이전트·플러그인 스크립트·리드의 증인 nonce 명령(openssl rand -hex 8), 쓰기는 아래 네 경로(Edit 규칙, 보고서는 파일 규칙, 팀 규약의 증인 발행 명령은 상태·중단 기록 디렉터리 아래에서 증인 승인 훅)\t(게이트 훅이 행위마다 판정)\t다름\t게이트 훅이 없어 설정 파일의 모드와 허용·거부 목록, 그리고 증인 발행 명령과 nonce 명령만 승인하는 훅이 범위를 정한다; 실행기 설정은 그 밖의 쓰기와 네트워크 쓰기를 열지 않고, 레인 사용자 설정의 규칙은 게이트 스테이지처럼 합쳐진다\n'
    printf '대상 복제본\t쓰기 경로\truns/<n>-<갈래>/target\t(세그먼트 워크트리)\t다름\t원격 없는 대상 복제본을 리뷰한다\n'
    printf -- '--report-path\t쓰기 경로\truns/<n>-<갈래>/report.md\t(게이트의 정본 보고서 경로)\t다름\t갈래마다 보고서 자리를 실행기가 정한다\n'
    printf 'XDG_STATE_HOME\t쓰기 경로\truns/<n>-<갈래>/state\t(물려받은 상태 루트)\t다름\t증인 스크래치를 갈래 디렉터리 아래에 둔다\n'
    printf '중단 기록\t쓰기 경로\truns/<n>-<갈래>/halt/\t(런 디렉터리의 halt/)\t다름\t런 디렉터리가 없다\n'
    printf '중단 기록 자리\t게이트 의존 지점\t지시문으로 runs/<n>-<갈래>/halt/ 를 알리고 collect 가 그 기록을 사유에 붙인다\tCC_PIPELINE_RUN_DIR·CC_PIPELINE_STAGE_ID 에서 유도\t다름\t실행기가 그 변수를 지우고 대상 복제본에 인가 기록이 없다\n'
    printf '보고서 형식 점검\t게이트 의존 지점\tcollect 가 report-check 와 같은 형식 점검을 한다\tgate.sh report-check\t다름\t매니페스트가 없어 그 단계가 실패한다\n'
    printf '무인 규칙의 게이트 경유 행위\t게이트 의존 지점\t지시문으로 이 모드에서 건너뛴다고 알린다\tgate.sh exec\t다름\t게이트도 훅도 없다\n'
    printf '라벨 인정\t게이트 의존 지점\t지시문으로 이 모드에서 건너뛴다고 알린다\t매니페스트를 읽는다\t다름\t매니페스트가 없다\n'
  } > "$f"
  local bad
  bad=$(awk -F'\t' 'NR > 1 && $5 == "같음" && $1 !~ /^--(plugin-dir|append)/ && $3 != $4 { print $1 " (실행기 " $3 ", 게이트 " $4 ")" }' "$f")
  [[ -z "$bad" ]] || die "the closed list disagrees with the gate of commit ${C:0:12}: $(printf '%s' "$bad" | tr '\n' ';')"
  bad=$(awk -F'\t' 'NR > 1 && $1 ~ /^--append/ && $4 == "미상" { print $1 }' "$f")
  [[ -z "$bad" ]] || die "the gate of commit ${C:0:12} no longer passes: $(printf '%s' "$bad" | tr '\n' ' ')"
}

# ---------- instructions -----------------------------------------------------

# make_instructions — the lead and members files, from the sources the gate's
# synthesis reads (policy, personal rules block, the ancestor instruction chain
# of --repo), into <state>/instructions/. Prints `<lead>\t<members>`.
make_instructions() {
  local out="$ST/instructions" g policy rules_bin cfg src pdir pline psha psnap slug rootp
  g=$(clone_of opus)/plugins/cc-cmds/orchestrator
  [[ -f "$ST/instructions.state" ]] && { printf '%s\t%s\n' "$(kv "$ST/instructions.state" lead)" "$(kv "$ST/instructions.state" members)"; return 0; }
  policy="$g/stage-policy.md"
  [[ -f "$policy" ]] || die "no stage policy in the branch clone: $policy"
  mkdir -p "$out"
  cfg="$LANE_CFG"
  src="$cfg/CLAUDE.md"
  pdir="$out/personal"; mkdir -p "$pdir"
  rules_bin="$g/stage-rules.sh"
  psnap=""
  if [[ -f "$rules_bin" ]] && ( umask 077; bash "$rules_bin" extract --source "$src" --out-dir "$pdir" > "$pdir/extract.out" 2> "$pdir/extract.err" ); then
    pline=$(head -n 1 "$pdir/current" 2>/dev/null || true); psha="${pline%% *}"
    if [[ ${#psha} == 64 && -f "$pdir/$psha.md" ]]; then psnap="$pdir/$psha.md"; fi
  fi
  if [[ -z "$psnap" ]]; then
    policy="$g/legacy/stage-policy.v6.md"
    [[ -f "$policy" ]] || die "no personal rules block and no frozen v6 policy: $policy"
  fi
  slug=$(cd "$repo" && git remote get-url origin 2>/dev/null | sed -E 's#^.*[:/]([^/:]+/[^/]+)$#\1#; s#\.git$##' || true)
  [[ -n "$slug" ]] || slug=$(basename "$repo")
  rootp=$(cd "$repo" && pwd -P)
  local cfgp="" excl=$'\n' map line p pp d name f files=() labels=() roots=()
  [[ -d "$cfg" ]] && cfgp=$(cd "$cfg" && pwd -P)
  map="${HOME}/.config/cc-cmds/stage-policy-sources"
  if [[ -f "$map" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      case "$line" in ''|'#'*|*'	'*'	'*) continue ;; esac
      [[ "$line" == *'	'* ]] || continue
      [[ "${line%%	*}" != "keep" ]] || continue
      p="${line#*	}"; [[ -e "$p" ]] || continue
      excl="$excl$(cd "$(dirname "$p")" && pwd -P)/$(basename "$p")"$'\n'
    done < "$map"
  fi
  d="$rootp"; local dirs=""
  while [[ -n "$d" && "$d" != "/" ]]; do dirs="$d"$'\n'"$dirs"; d=$(dirname "$d"); done
  while IFS= read -r d; do
    [[ -n "$d" ]] || continue
    for name in CLAUDE.md .claude/CLAUDE.md CLAUDE.local.md; do
      f="$d/$name"; [[ -f "$f" ]] || continue
      if [[ "$name" == ".claude/CLAUDE.md" && -n "$cfgp" && "$(cd "$d/.claude" && pwd -P)" == "$cfgp" ]]; then continue; fi
      pp="$(cd "$(dirname "$f")" && pwd -P)/$(basename "$f")"
      case "$excl" in *$'\n'"$pp"$'\n'*) continue ;; esac
      files[${#files[@]}]="$f"
      if [[ "$d" == "$rootp" ]]; then labels[${#labels[@]}]="$slug/$name"; roots[${#roots[@]}]=1
      else labels[${#labels[@]}]="$f"; roots[${#roots[@]}]=0; fi
    done
  done <<<"$dirs"
  local lt mt i lead members
  lt=$(mktemp "$out/.lead.XXXXXX"); mt=$(mktemp "$out/.member.XXXXXX")
  (
    umask 077
    {
      cat "$policy"
      [[ -z "$psnap" ]] || { printf '\n# Personal rules\n\n'; cat "$psnap"; }
      printf '\n# Repository instructions\n\nThe files below are the instruction chain of the target repository, root first. Each begins with a heading naming its file.\n'
      i=0; while (( i < ${#files[@]} )); do printf '\n---\n# %s\n\n' "${labels[$i]}"; cat "${files[$i]}"; i=$((i + 1)); done
    } > "$lt"
    {
      cat "$policy"
      [[ -z "$psnap" ]] || { printf '\n# Personal rules\n\n'; cat "$psnap"; }
      printf '\n# Repository instructions\n\nThe files below are the instruction chain of the target repository, root first. Each begins with a heading naming its file; the repository'"'"'s own files are given as paths to read, not as their text.\n'
      i=0; while (( i < ${#files[@]} )); do
        printf '\n---\n# %s\n\n' "${labels[$i]}"
        if [[ "${roots[$i]}" == 1 ]]; then printf '%s\n\nRead the parts that bear on a file before you judge or quote a rule about it.\n' "${files[$i]}"; else cat "${files[$i]}"; fi
        i=$((i + 1))
      done
    } > "$mt"
  )
  lead="$out/$(sha_of "$lt").md"; members="$out/$(sha_of "$mt").md"
  mv "$lt" "$lead"; mv "$mt" "$members"
  kv_set "$ST/instructions.state" lead "$lead"
  kv_set "$ST/instructions.state" members "$members"
  printf '%s\t%s\n' "$lead" "$members"
}

# ---------- stage 3: prepare -------------------------------------------------

# target_clone <dir> <head> <base> — an independent clone holding the local
# branch at <head> and refs/exp/base at <base>, nothing else: the commits past
# the review's head are what the original review's fixes added, and git
# history is a leak.
target_clone() {
  git clone --quiet --no-hardlinks "$repo" "$1" || return 1
  ( cd "$1" \
    && git checkout --quiet -b "$TARGET_BRANCH" "$2" \
    && git remote remove origin \
    && git update-ref "$BASE_REF" "$3" \
    && git for-each-ref --format='%(refname)' | while IFS= read -r r; do
         [[ "$r" == "refs/heads/${TARGET_BRANCH}" || "$r" == "$BASE_REF" ]] || git update-ref -d "$r" || exit 1
       done \
    && git reflog expire --expire=now --all \
    && git gc --quiet --prune=now )
}

# anchor_brief <manifest> <out> — the brief the driver writes for a run with no
# design document, rebuilt from the same manifest.
anchor_brief() {
  local m="$1"
  {
    printf '# 앵커 브리프 — 설계 문서 없는 런\n\n'
    printf '이 런에는 설계 문서가 없다. 런의 명세는 아래 매니페스트가 전부이며,\n'
    printf '설계 문서를 전제하는 절은 이 런에 존재하지 않는다.\n\n'
    printf -- '- 런 id: %s\n' "$(awk -v l='**런 id**: ' 'index($0, l) == 1 { print substr($0, length(l) + 1); exit }' "$m")"
    printf -- '- 앵커 종류: %s\n' "$(awk -v l='**앵커 종류**: ' 'index($0, l) == 1 { print substr($0, length(l) + 1); exit }' "$m")"
    printf -- '- 앵커 키: %s\n\n' "$(awk -v l='**앵커 키**: ' 'index($0, l) == 1 { print substr($0, length(l) + 1); exit }' "$m")"
    printf '## 매니페스트\n\n'
    cat "$m"
  } > "$2"
}

# witness_hook_write <file> — the PreToolUse hook write_settings registers.
witness_hook_write() {
  cat > "$1" <<'HOOK'
#!/usr/bin/env bash
# PreToolUse hook of the review sessions scripts/review-seat-promotion-pair.sh
# launches. Arguments: a log file, then the directories a witness command may
# name. It allows a Bash call made only of the team protocol's witness
# commands, separated by newlines, `&&` or `;`, each naming paths below one of
# those directories:
#   <var>=$(mktemp [-d] <path>)   mktemp [-d] <path>   mkdir -p <path>
#   mv [-n] <path|"$var"> <path>  echo "$var"   cat > <path|"$var"> <<'TAG'
#   openssl rand -hex 8           (the lead's witness nonce, names no path)
# A <path> or "$var" is either bare or wrapped in one pair of double quotes,
# never one-sided; a <path> may be spelled `"$(dirname <path>)/<rest>"` (a
# dirname operand ending in `/` or holding `//` is not resolved); "$var" is a
# variable an earlier mktemp of the same call assigned; `mkdir -p` may also
# name one of the directories itself; and the body of a quoted-delimiter
# heredoc opened at the end of a `cat >` command is not read. Any other call
# gets no decision, so the session's permission rules decide it. One that runs
# mktemp, or runs mv or mkdir naming one of the directories or a `$(dirname`,
# is also appended to the log as `<agent_id or ->\t<command>`, because a `-p`
# session refuses it and the pilot fails on a non-empty log; a call that only
# mentions those words, or a mv or mkdir elsewhere, is not logged.
set -u
log="${1:-}"
(( $# > 1 )) || exit 0
shift
roots=("$@")
in=$(cat)
cmd=$(printf '%s' "$in" | jq -r 'if .tool_name == "Bash" then (.tool_input.command // "") else "" end' 2>/dev/null) || exit 0
[[ -n "$cmd" ]] || exit 0
orig="$cmd"

c='[A-Za-z0-9._/+@%,:=-]'
v='[A-Za-z_][A-Za-z0-9_]*'
# A command word at the start of the call or after `;`, `&`, `|` or `(`.
re_runmk='(^|[;&|(])[[:space:]]*('"$v"'=\$\()?mktemp( |$)'
re_runmv='(^|[;&|(])[[:space:]]*(mv|mkdir)( |$)'

# miss — give no decision, logging a call that runs a witness command.
miss() {
  local flat r named=""
  flat=$(printf '%s' "$orig" | tr '\n' ';')
  for r in "${roots[@]}"; do
    case "$orig" in *"$r"*) named=1 ;; esac
  done
  case "$orig" in *'$(dirname'*) named=1 ;; esac
  if [[ $flat =~ $re_runmk ]] || { [[ -n "$named" ]] && [[ $flat =~ $re_runmv ]]; }; then
    printf '%s\t%s\n' "$(printf '%s' "$in" | jq -r '.agent_id // "-"' 2>/dev/null || echo -)" \
      "$(printf '%s' "$orig" | tr '\n\t' '  ')" >> "$log" 2>/dev/null || true
  fi
  exit 0
}

# unq <token> — a path token without its pair of double quotes.
unq() { local p="${1#\"}"; printf '%s' "${p%\"}"; }
# vname <token> — the variable name a "$var" token names.
vname() { local t="${1//[\"\$\{\}]/}"; printf '%s' "$t"; }

# under <path> — an absolute path below one of the roots, naming no `..`,
# no `//` and no trailing `/`.
under() {
  local p r
  p=$(unq "$1")
  case "$p" in /*) ;; *) return 1 ;; esac
  case "$p" in *..*|*//*|*/) return 1 ;; esac
  for r in "${roots[@]}"; do
    case "$p" in "$r"/*) return 0 ;; esac
  done
  return 1
}

# isroot <path> — one of the roots itself.
isroot() {
  local p r
  p=$(unq "$1")
  for r in "${roots[@]}"; do
    [[ "$p" != "$r" ]] || return 0
  done
  return 1
}

# A path or variable token is bare or wrapped in one pair of double quotes:
# the character class holds no quote, so a one-sided quote matches neither.
pth='("/'"$c"'+"|/'"$c"'+)'
vref='("\$\{?'"$v"'\}?"|\$\{?'"$v"'\}?)'
re_hd='cat > ('"$pth"'|'"$vref"') <<'"'"'('"$v"')'"'"'$'
re_dir='\$\(dirname ("/'"$c"'+"|/'"$c"'+)\)'
re_assign='^('"$v"')=\$\(mktemp( -d)? '"$pth"'\)$'
re_mktemp='^mktemp( -d)? '"$pth"'$'
re_mkdir='^mkdir -p '"$pth"'$'
re_mvvar='^mv( -n)? '"$vref"' '"$pth"'$'
re_mvpath='^mv( -n)? '"$pth"' '"$pth"'$'
re_echo='^echo '"$vref"'$'
re_catvar='^cat > '"$vref"'$'
re_catpath='^cat > '"$pth"'$'
re_nonce='^openssl rand -hex 8$'

# A quoted-delimiter heredoc's body is literal text: drop it, and the
# `<<'TAG'` that opens it. Only a line ending in `cat > <path|"$var"> <<'TAG'`
# opens one, so a quote left open on an earlier line cannot hide real commands
# as a body: the segments around that quote match no command below.
tag="" out=""
while IFS= read -r line; do
  if [[ -n "$tag" ]]; then
    [[ "$line" != "$tag" ]] || tag=""
    continue
  fi
  if [[ $line =~ $re_hd ]]; then
    tag="${BASH_REMATCH[4]}"
    line="${line%" <<'${tag}'"}"
  fi
  out="${out}${line}"$'\n'
done <<<"$cmd"
[[ -z "$tag" ]] || miss
cmd="$out"

# Each `$(dirname <path>)` becomes the directory it prints.
i=0
while [[ $cmd =~ $re_dir ]]; do
  i=$((i + 1)); (( i <= 20 )) || miss
  full="${BASH_REMATCH[0]}"; p=$(unq "${BASH_REMATCH[1]}")
  case "$p" in */|*//*) miss ;; esac
  d="${p%/*}"
  [[ -n "$d" ]] || miss
  cmd="${cmd%%"$full"*}${d}${cmd#*"$full"}"
done

segs=$(printf '%s\n' "$cmd" | awk '{ gsub(/&&|;/, "\n"); print }')
vars=" "
n=0
while IFS= read -r seg; do
  seg="${seg#"${seg%%[![:space:]]*}"}"
  seg="${seg%"${seg##*[![:space:]]}"}"
  [[ -n "$seg" ]] || continue
  if [[ $seg =~ $re_assign ]]; then
    under "${BASH_REMATCH[3]}" || miss
    vars="${vars}${BASH_REMATCH[1]} "
  elif [[ $seg =~ $re_mktemp ]]; then
    under "${BASH_REMATCH[2]}" || miss
  elif [[ $seg =~ $re_mkdir ]]; then
    under "${BASH_REMATCH[1]}" || isroot "${BASH_REMATCH[1]}" || miss
  elif [[ $seg =~ $re_mvvar ]]; then
    case "$vars" in *" $(vname "${BASH_REMATCH[2]}") "*) ;; *) miss ;; esac
    under "${BASH_REMATCH[3]}" || miss
  elif [[ $seg =~ $re_mvpath ]]; then
    under "${BASH_REMATCH[2]}" && under "${BASH_REMATCH[3]}" || miss
  elif [[ $seg =~ $re_echo || $seg =~ $re_catvar ]]; then
    case "$vars" in *" $(vname "${BASH_REMATCH[1]}") "*) ;; *) miss ;; esac
  elif [[ $seg =~ $re_catpath ]]; then
    under "${BASH_REMATCH[1]}" || miss
  elif [[ $seg =~ $re_nonce ]]; then
    :
  else
    miss
  fi
  n=$((n + 1))
done <<<"$segs"
(( n > 0 )) || miss
printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":"review-seat-promotion-pair: a witness command below the state home or the halt directory"}}'
HOOK
}

# write_settings <file> <target> <run dir> — the session's settings: the
# account's plugins all off, reads, git queries, sub-agents, the plugin's own
# scripts and the lead's nonce command allowed, writes only inside the target
# clone, the report path, the state home and the halt directory, network tools
# refused.
#
# The rules follow Claude Code's permission rules (code.claude.com/docs/en/permissions):
# file-write rules are `Edit(...)` rules, because `Write(path)` rules never match;
# a path rule uses gitignore syntax with `//` for an absolute path, so the report
# is opened by a rule naming the file itself (`<dir>/**` matches only what is
# under a directory); and a `-p` session in the default mode refuses every call
# that needs approval. `acceptEdits` approves file edits, and filesystem
# commands whose operands it can read, for paths in the working directory (the
# target clone) and in `additionalDirectories` — the state home and the halt
# directory only, so the rest of the run directory (the command line, the
# prompt, the inputs) stays closed. A bare `mktemp` naming one of those two
# directories is opened by a rule, quoted and unquoted; a rule's `*` matches any
# text, so a `mktemp` naming `..` is refused outright, and so is a second
# template after one ending in `X` (BSD `mktemp` takes several). The plugin's
# scripts are opened by `<plugin dir>/*` (a `:*` suffix would need a space after
# the directory's slash), a path naming `..` refused. Network tools are refused.
#
# A member publishes its witness with the team protocol's commands as written:
# `T=$(mktemp "$(dirname <witness>)/.<role>.<round>.XXXXXX")`, `mv -n "$T"
# <witness>`, and for the round-1 checkpoint `mkdir -p "$(dirname
# <witness>)/partial"` and a plain `mv`. No allow rule matches the first: a rule
# matches its text before the first `*` as written and never past an assignment
# to another variable, and `acceptEdits` checks no operand it cannot read
# before the command runs. So the settings also carry one PreToolUse hook
# (witness_hook_write) that allows a Bash call made only of those commands, each
# naming paths under the state home or the halt directory. A `"$T"` is known to
# it only inside the call whose mktemp assigned it — a session keeps no shell
# variable between Bash calls anyway — so a publish in a later call names the
# temp's literal path. Any other call gets no decision from it, and one running
# mktemp, or mv or mkdir on those directories, is logged to
# <run dir>/witness-misses.log, which the pilot requires empty. A hook's allow
# does not lift a deny rule.
#
# The lead mints each member's witness nonce with `openssl rand -hex 8`, a Bash
# call of its own that no plugin script makes for it and that neither the
# read-only defaults nor `acceptEdits` approve. A refused call lands in
# `permission_denials`, which fails the pilot, so that exact command is opened
# by a rule, and the hook also allows it as one of the commands of a call.
#
# These are the runner's own rules; the lane's user settings are merged in as
# they are for a gate stage, so its allow rules and hooks reach the session too.
write_settings() {
  local f="$1" t="$2" rd="$3" pd="$4" cfg keys hook hcmd
  cfg="$LANE_CFG"
  hook="$(dirname "$f")/witness-hook.sh"
  witness_hook_write "$hook"
  hcmd="bash $(shq "$hook") $(shq "$rd/witness-misses.log") $(shq "$rd/state") $(shq "$rd/halt")"
  keys=$(jq -c '(.enabledPlugins // {}) | with_entries(.value = false)' "$cfg/settings.json" 2>/dev/null || echo '{}')
  [[ -n "$keys" ]] || keys='{}'
  jq -n --arg t "$t" --arg rd "$rd" --arg pd "$pd" --arg hc "$hcmd" --argjson pl "$keys" '{
    permissions: {
      defaultMode: "acceptEdits",
      allow: ([
        "Read", "Glob", "Grep", "Agent", "Task", "TodoWrite",
        "Bash(git log:*)", "Bash(git diff:*)", "Bash(git show:*)", "Bash(git rev-parse:*)",
        "Bash(git merge-base:*)", "Bash(git status:*)", "Bash(git remote:*)", "Bash(git ls-files:*)",
        "Bash(git cat-file:*)", "Bash(git for-each-ref:*)", "Bash(git branch:*)", "Bash(git blame:*)",
        "Bash(git grep:*)", "Bash(git ls-tree:*)", "Bash(git rev-list:*)",
        "Bash(openssl rand -hex 8)",
        ("Bash(bash " + $pd + "/*)"), ("Bash(" + $pd + "/*)")
      ] + ([$t, ($rd + "/state"), ($rd + "/halt")] | map("Edit(/" + . + "/**)"))
        + ["Edit(/" + $rd + "/report.md)"]
        + ([($rd + "/state"), ($rd + "/halt")]
            | map(("Bash(mktemp " + . + "/*)"), ("Bash(mktemp \"" + . + "/*)"),
                  ("Bash(mktemp -d " + . + "/*)"), ("Bash(mktemp -d \"" + . + "/*)")))),
      deny: ["WebFetch", "WebSearch", "Bash(curl:*)", "Bash(wget:*)", "Bash(git push:*)",
             "Bash(git fetch:*)", "Bash(git pull:*)", "Bash(git clone:*)", "Bash(git ls-remote:*)",
             "Bash(gh:*)", "Bash(sudo:*)", "Bash(ssh:*)", "Bash(scp:*)", "Bash(rsync:*)", "Bash(nc:*)",
             "Bash(mktemp *..*)", "Bash(mktemp *X *)", "Bash(mktemp *X\" *)",
             ("Bash(bash " + $pd + "/*..*)"), ("Bash(" + $pd + "/*..*)")],
      additionalDirectories: [($rd + "/state"), ($rd + "/halt")]
    },
    hooks: {PreToolUse: [{matcher: "Bash", hooks: [{type: "command", command: $hc}]}]},
    enabledPlugins: $pl
  }' > "$f"
}

# review_prompt <run dir> <inputs> <target> — the `-p` text.
review_prompt() {
  local rd="$1" in="$2" t="$3" line doc
  doc="$t/$(kv "$in" doc_rel)"
  line="/cc-cmds:review-unattended ${TARGET_BRANCH} --base-sha $(kv "$in" base) --report-path ${rd}/report.md"
  [[ -z "$(kv "$in" slice)" ]] || line="$line --slice $(kv "$in" slice)"
  [[ -z "$(kv "$in" declared)" ]] || line="$line --declared-files \"$(kv "$in" declared)\""
  [[ -z "$(kv "$in" expand)" ]] || line="$line --expand $(kv "$in" expand)"
  line="$line \"설계는 ${doc}\""
  if [[ -n "$(kv "$in" pr)" ]]; then
    local body labels
    body=$(cat "${in%.tsv}.pr-body" 2>/dev/null || true)
    labels=$(kv "$in" pr_labels); [[ -n "$labels" ]] || labels="없음"
    line="$line \"$(printf '%s' "이 대상은 로컬 diff 모드라 PR 이 없으므로, 원 리뷰가 받은 PR 메타데이터를 여기 싣는다 — PR #$(kv "$in" pr), 제목: $(kv "$in" pr_title), 라벨: ${labels}, 본문: ${body}" | sed 's/"/\\"/g')\""
  fi
  line="$line \"이 세션은 파이프라인 런 밖에서 직접 띄운 리뷰다 — 게이트·런 매니페스트·인가 기록이 없다. 중단 기록은 ${rd}/halt/review.md 에 쓴다(CC_PIPELINE_RUN_DIR·CC_PIPELINE_STAGE_ID·pipeline-grant 에서 유도하지 않는다). 무인 규칙 가운데 행위를 gate.sh exec 로 하라는 규칙, Step 5 의 gate.sh report-check, 매니페스트를 읽는 라벨 인정은 이 세션에서 건너뛴다.\""
  printf '%s' "$line"
}

# prepare_branch <n> <branch> <report> <run dir> — the target clone, the
# inputs, the settings and the command line of one branch of one sample.
prepare_branch() {
  local n="$1" br="$2" nm="$3" rd="$4" bst t in base head docs rel man instr lead members pd
  bst="$rd/branch.state"
  [[ "$(kv "$bst" prepared)" == "1" ]] && return 0
  base=$(sel_field "$nm" 5); head=$(sel_field "$nm" 6)
  rm -rf "$rd"; mkdir -p "$rd/halt" "$rd/state"
  t="$rd/target"
  target_clone "$t" "$head" "$base" || die "sample ${n} ${br}: the target clone failed ($nm)"
  in="$ST/inputs/$nm.tsv"
  [[ -f "$in" ]] || die "sample ${n}: no restored inputs for $nm"
  rel=$(kv "$in" doc_rel); docs=$(kv "$in" doc_src)
  mkdir -p "$t/$(dirname "$rel")"
  if [[ "$docs" == "anchor" ]]; then
    man="$repo/docs/pipeline-run/$(kv "$in" rid).plan.md"
    anchor_brief "$man" "$t/$rel"
  else
    cp "$docs" "$t/$rel"
  fi
  {
    printf '설계 문서\t%s\t%s\n' "$rel" "$(sha_of "$t/$rel")"
    printf -- '--expand\t%s\n' "$(kv "$in" expand | sed 's/^$/없음/')"
    if [[ -z "$(kv "$in" pr)" ]]; then
      printf 'PR 제목·본문·라벨\t없음\n'
    else
      printf 'PR 제목·본문·라벨\t#%s\t%s\t본문 sha256 %s\t라벨 %s\n' "$(kv "$in" pr)" "$(kv "$in" pr_title)" \
        "$(kv "$in" pr_body_sha)" "$(kv "$in" pr_labels | sed 's/^$/없음/')"
    fi
    printf -- '--slice\t%s\n' "$(kv "$in" slice | sed 's/^$/없음/')"
    printf -- '--declared-files\t%s\n' "$(kv "$in" declared | sed 's/^$/없음/')"
    printf '설계 문서 지시문\t설계는 <대상 복제본>/%s\n' "$rel"
  } > "$rd/inputs"
  kv_set "$in" base "$base"
  instr=$(make_instructions); lead="${instr%%	*}"; members="${instr##*	}"
  pd="$(branch_clone "$br")/plugins/cc-cmds"
  mkdir -p "$ST/settings"
  write_settings "$ST/settings/${n}-${br}.json" "$t" "$rd" "$pd"
  local prompt; prompt=$(review_prompt "$rd" "$in" "$t")
  kv_set "$bst" target "$t"
  kv_set "$bst" plugin "$pd"
  kv_set "$bst" settings "$ST/settings/${n}-${br}.json"
  kv_set "$bst" lead "$lead"
  kv_set "$bst" members "$members"
  printf '%s' "$prompt" > "$rd/prompt"
  {
    printf 'cd %s && ' "$(shq "$t")"
    printf 'CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=%s CC_CMDS_STATUSLINE_AUTOINSTALL=0 XDG_STATE_HOME=%s ' "$WAIT_CEILING_MS" "$(shq "$rd/state")"
    printf 'CLAUDE_CODE_DISABLE_CLAUDE_MDS=1 CLAUDE_CODE_ENABLE_APPEND_SUBAGENT_PROMPT=1 CLAUDE_CONFIG_DIR=%s ' "$(shq "$LANE_CFG")"
    printf '%s -p %s' "$(shq "$CLAUDE_BIN")" "$(shq "$prompt")"
    printf ' --plugin-dir %s --settings %s' "$(shq "$pd")" "$(shq "$ST/settings/${n}-${br}.json")"
    printf ' --model %s --effort %s --strict-mcp-config --autocompact %s' "$LEAD_MODEL" "$LEAD_EFFORT" "$AUTOCOMPACT_REVIEW"
    printf ' --append-system-prompt-file %s --append-subagent-system-prompt-file %s' "$(shq "$lead")" "$(shq "$members")"
    printf ' --exclude-dynamic-system-prompt-sections --no-session-persistence --output-format json --max-budget-usd %s\n' "$RESERVE_RUN"
  } > "$rd/cmd"
  kv_set "$bst" prepared 1
}

# ---------- stage 4: review --------------------------------------------------

# review_branch <n|pilot> <branch> <run dir> — one session, its cost row.
review_branch() {
  local n="$1" br="$2" rd="$3" bst t start end rc=0 cost
  bst="$rd/branch.state"
  [[ -f "$rd/result.json" ]] && return 0
  guard "the review of sample ${n} ${br}"
  t=$(kv "$bst" target)
  start=$(now_iso)
  (
    cd "$t"
    export CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS="$WAIT_CEILING_MS"
    export CC_CMDS_STATUSLINE_AUTOINSTALL=0
    export XDG_STATE_HOME="$rd/state"
    export CLAUDE_CODE_DISABLE_CLAUDE_MDS=1
    export CLAUDE_CODE_ENABLE_APPEND_SUBAGENT_PROMPT=1
    export CLAUDE_CONFIG_DIR="$LANE_CFG"
    exec "$CLAUDE_BIN" -p "$(cat "$rd/prompt")" \
      --plugin-dir "$(kv "$bst" plugin)" --settings "$(kv "$bst" settings)" \
      --model "$LEAD_MODEL" --effort "$LEAD_EFFORT" --strict-mcp-config --autocompact "$AUTOCOMPACT_REVIEW" \
      --append-system-prompt-file "$(kv "$bst" lead)" --append-subagent-system-prompt-file "$(kv "$bst" members)" \
      --exclude-dynamic-system-prompt-sections --no-session-persistence --output-format json \
      --max-budget-usd "$RESERVE_RUN" < /dev/null
  ) > "$rd/result.json.tmp" 2> "$rd/stderr.log" || rc=$?
  end=$(now_iso)
  mv "$rd/result.json.tmp" "$rd/result.json"
  cost=$(jq -r 'if type == "object" and (.total_cost_usd | type) == "number" then .total_cost_usd else empty end' "$rd/result.json" 2>/dev/null || true)
  costs_init
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$n" "$br" "$start" "$end" "$rc" "${cost:--}" >> "$EXP/costs.tsv"
  say "sample ${n} ${br}: exit ${rc}, cost ${cost:--}"
}

# ---------- stage 5: collect -------------------------------------------------

# halt_note <run dir> — ` — <분류> <질문 문면 first line>` of the first halt
# record in the branch's halt directory, or nothing.
halt_note() {
  local h cls q
  for h in "$1"/halt/*.md; do
    [[ -f "$h" ]] || continue
    cls=$(awk -v l='**분류**: ' '{ s = $0; sub(/^- /, "", s) } index(s, l) == 1 { print substr(s, length(l) + 1); exit }' "$h")
    q=$(awk -v l='**질문 문면**:' '{ s = $0; sub(/^- /, "", s) }
      got && NF { print; exit }
      index(s, l) == 1 { v = substr(s, length(l) + 1); sub(/^ +/, "", v); if (v != "") { print v; exit } got = 1 }' "$h")
    printf ' — %s %s' "${cls:-분류 없음}" "${q:-질문 문면 없음}"
    return 0
  done
}

# branch_reason <run dir> <branch> <head> — the first invalid reason of the
# branch report, nothing when it is valid. Also leaves the promoted slugs in
# <run dir>/promoted.
branch_reason() {
  local rd="$1" br="$2" head="$3" rp h ex date summ sp0 sp1 rhead pl ntier miss fp want bad kinds
  rp="$rd/report.md"
  : > "$rd/promoted"
  [[ -f "$rp" ]] || { echo "보고서 없음"; return 0; }
  h=$(scan_h "$rp")
  IFS='	' read -r _ ex date summ sp0 sp1 rhead pl ntier miss fp <<<"$h"
  [[ "$pl" == "-" ]] || printf '%s' "$pl" | tr ';' '\n' | awk -F'=' '{ print $1 }' | paste -sd, - > "$rd/promoted"
  kinds=$(printf '%s' "$fp" | tr ',' '\n' | awk -F: '$1 != "-" && $1 != "요약 없음" && $1 != "HEAD 줄 없음" { print $1 }' | paste -sd, -)
  if [[ -n "$kinds" ]]; then echo "보고서 형식 (${kinds})"; return 0; fi
  if [[ "$rhead" != "$head" ]]; then echo "리뷰 HEAD 불일치"; return 0; fi
  case "$summ" in 비정규|없음) echo "발견 요약 비정규"; return 0 ;; esac
  if [[ "$summ" == "복구" || "$ntier" == "0" ]]; then echo "부분 복구"; return 0; fi
  if [[ "$pl" == "-" ]]; then echo "승격 행 없음"; return 0; fi
  want="opus"; [[ "$br" != "sonnet" ]] || want="sonnet"
  bad=$(printf '%s' "$pl" | tr ';' '\n' | awk -F'=' -v w="$want" '$2 != w { print $1 "=" $2 }' | paste -sd, -)
  if [[ -n "$bad" ]]; then echo "승격 모델 불일치 (${bad})"; return 0; fi
  if [[ "$miss" != "0" ]]; then echo "좌석 줄 누락 (${miss}건)"; return 0; fi
}

seats_cell() {
  local n="$1" br out="" s
  for br in $BRANCHES; do
    s=$(cat "$ST/runs/${n}-${br}/promoted" 2>/dev/null || true)
    out="${out}${out:+;}${br}=${s:--}"
  done
  printf '%s' "$out"
}

# ---------- slots and reserves -----------------------------------------------

# run_slot <n> — the slot's current sample, all three branches, until it is
# valid or its reserves are used up.
run_slot() {
  local n="$1" f k nm rd br reason base head note
  f=$(slot_state "$n")
  while ! slot_done "$n"; do
    k=$(kv "$f" try); [[ -n "$k" ]] || { k=0; kv_set "$f" try 0; }
    nm=$(sample_name "$n" "$k")
    if [[ -z "$nm" ]]; then
      kv_set "$f" status "무효"; kv_set "$f" exhausted 1
      local last; last=$(samples_get "$n")
      [[ -n "$last" ]] || samples_put "$n" "$(printf '%s\t-\t-\t-\t무효\t선정과 예비가 모두 무효다\t-' "$n")"
      say "sample ${n}: no reserve left"
      return 0
    fi
    base=$(sel_field "$nm" 5); head=$(sel_field "$nm" 6)
    kv_set "$f" sample "$nm"; kv_set "$f" base "$base"; kv_set "$f" head "$head"
    reason=""
    for br in $BRANCHES; do
      rd="$ST/runs/${n}-${br}"
      [[ "$(kv "$rd/branch.state" sample)" == "$nm" ]] || rm -rf "$rd"
      prepare_branch "$n" "$br" "$nm" "$rd"
      kv_set "$rd/branch.state" sample "$nm"
      review_branch "$n" "$br" "$rd"
      mkdir -p "$EXP/reports"
      if [[ -f "$rd/report.md" ]]; then cp "$rd/report.md" "$EXP/reports/${n}-${br}.md"; else rm -f "$EXP/reports/${n}-${br}.md"; fi
      reason=$(branch_reason "$rd" "$br" "$head")
      if [[ -n "$reason" ]]; then
        note=$(halt_note "$rd")
        reason="${br}: ${reason}${note}"
        break
      fi
    done
    if [[ -z "$reason" ]]; then
      samples_put "$n" "$(printf '%s\t%s\t%s\t%s\t유효\t-\t%s' "$n" "$nm" "$base" "$head" "$(seats_cell "$n")")"
      kv_set "$f" status "유효"
      say "sample ${n}: valid ($nm)"
    else
      samples_put "$n" "$(printf '%s\t%s\t%s\t%s\t무효\t%s\t%s' "$n" "$nm" "$base" "$head" "$reason" "$(seats_cell "$n")")"
      say "sample ${n}: invalid — ${reason}; next reserve"
      for br in $BRANCHES; do rm -rf "$ST/runs/${n}-${br}"; rm -f "$EXP/reports/${n}-${br}.md"; done
      kv_set "$f" try $((k + 1))
    fi
  done
}

# ---------- pilot, status, rerun ---------------------------------------------

pilot_ok() { [[ "$(head -n 1 "$EXP/pilot/result" 2>/dev/null || true)" == "통과" ]]; }

run_pilot() {
  mkdir -p "$EXP/pilot"
  if pilot_ok; then say "pilot already passed → $EXP/pilot/result"; exit 0; fi
  local nm rd head reason cost den why
  nm=$(sample_name 1 0)
  rd="$ST/pilot/opus-1"
  rm -rf "$rd"
  write_session_env
  prepare_branch pilot opus-1 "$nm" "$rd"
  head=$(sel_field "$nm" 6)
  review_branch pilot opus-1 "$rd"
  [[ ! -f "$rd/report.md" ]] || cp "$rd/report.md" "$EXP/pilot/report.md"
  cost=$(jq -r 'if type == "object" and (.total_cost_usd | type) == "number" then .total_cost_usd else empty end' "$rd/result.json" 2>/dev/null || true)
  # A refused tool call — a witness command the settings did not open, say —
  # is a seat working around its instructions, which the pair would compare.
  den=$(jq -r 'if type == "object" and (.permission_denials | type) == "array"
    then ([.permission_denials | length | tostring] + [.permission_denials[] | .tool_name // "?"] | join(" ")) else empty end' "$rd/result.json" 2>/dev/null || true)
  why=""
  if [[ -n "$(halt_note "$rd")" ]]; then why="중단 기록이 있다$(halt_note "$rd")"
  else
    reason=$(branch_reason "$rd" opus-1 "$head")
    if [[ -n "$reason" ]]; then why="$reason"
    elif [[ -z "$cost" ]]; then why="total_cost_usd 가 JSON 에 없다"
    elif [[ -z "$den" ]]; then why="permission_denials 가 JSON 에 없다"
    elif [[ "${den%% *}" != "0" ]]; then why="거부된 도구 호출 ${den%% *}건 (${den#* })"
    elif [[ -s "$rd/witness-misses.log" ]]; then why="증인 명령 미승인 $(awk 'END { print NR }' "$rd/witness-misses.log")건"
    fi
  fi
  if [[ -z "$why" ]]; then
    printf '통과\n비용\t%s\n보고서\t%s\n' "$cost" "$nm" > "$EXP/pilot/result"
    say "pilot passed (cost ${cost}) → $EXP/pilot/result"; exit 0
  fi
  printf '실패 — %s\n비용\t%s\n보고서\t%s\n' "$why" "${cost:--}" "$nm" > "$EXP/pilot/result"
  say "pilot failed — ${why} → $EXP/pilot/result"; exit 1
}

show_status() {
  [[ -d "$EXP" ]] || die "no experiment record: $EXP"
  say "experiment $exp_id — $EXP"
  [[ -f "$EXP/meta" ]] && cat "$EXP/meta"
  [[ -f "$EXP/pilot/result" ]] && { echo "--- pilot"; cat "$EXP/pilot/result"; }
  [[ -f "$EXP/samples.tsv" ]] && { echo "--- samples.tsv"; cat "$EXP/samples.tsv"; }
  echo "--- 비용 합계: $(spent) USD (costs.tsv, \`-\` 행은 예비 전액)"
  [[ -f "$EXP/report.md" ]] && tail -n 1 "$EXP/report.md"
  return 0
}

discard_slot() {
  local n="$1" br
  for br in $BRANCHES; do rm -rf "$ST/runs/${n}-${br}"; rm -f "$EXP/reports/${n}-${br}.md"; done
  rm -f "$(slot_state "$n")"
  samples_put "$n" ""
}

# ---------- main -------------------------------------------------------------

if [[ "$cmd" == "status" ]]; then show_status; exit 0; fi

C=$(cd "$repo" && git rev-parse --verify --quiet "${ref:-HEAD}^{commit}") || usage "--ref is not a commit of $repo: ${ref:-HEAD}"
if [[ -f "$EXP/meta" && "$(kv "$EXP/meta" commit)" != "$C" ]]; then
  die "experiment $exp_id was opened at commit $(kv "$EXP/meta" commit), not $C"
fi
mkdir -p "$EXP" "$ST"
costs_init
select_samples
make_branches

if (( pilot == 1 )); then run_pilot; fi

if (( dry == 1 )); then
  write_session_env
  n=0
  for n in $(seq 1 "$SAMPLES"); do
    nm=$(sample_name "$n" 0)
    for br in $BRANCHES; do
      rd="$ST/runs/${n}-${br}"
      prepare_branch "$n" "$br" "$nm" "$rd"
      kv_set "$rd/branch.state" sample "$nm"
      cat "$rd/cmd"
    done
  done
  say "dry run: ${SAMPLES} samples × 3 branches prepared; the model CLI was not called"
  exit 0
fi

pilot_ok || die "pilot/result of $exp_id is not 통과 — run \`run --pilot\` first; no billed call was made"
write_session_env
samples_init
budget_restore
if [[ "$cmd" == "rerun" ]]; then
  discard_slot "$rerun"
  run_slot "$rerun"
else
  for n in $(seq 1 "$SAMPLES"); do run_slot "$n"; done
fi
verdict
say "$(tail -n 1 "$EXP/report.md") → $EXP/report.md"
exit 0
