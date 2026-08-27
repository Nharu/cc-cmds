#!/usr/bin/env bash
#
# gate.sh — the policy layer's only door.
#
# The router decides WHAT happens next; this decides whether it MAY. Those two
# jobs lived in the same `case` arms of run.sh, so neither could move without
# the other. Splitting them is the whole point of the redesign, and this file is
# the half that does not judge.
#
# THE ARGV IS THE SCHEMA. Under the old shape the driver bought a judgment with
# `claude -p --json-schema` and validated the returned bytes. When the router
# became the main session's own model that artifact disappeared — there is no
# longer a file whose bytes can be checked. So the decision is not an output at
# all: it is a call to this script, and this script's argument parser is what
# the schema check used to be. That is also what makes the router testable
# without a model in the loop — drive the verbs with bad argv against a fixture
# ledger and assert the exit code.
#
# WHY IT SOURCES run.sh RATHER THAN COPYING. `scripts/lint-cutpoint-vocabulary.sh`
# treats run.sh's `readonly CUTPOINTS=` as the single source of truth and does
# not scan siblings, so a second copy here would drift with no detector — which
# is the exact failure that vocabulary lint exists to prevent. Sourcing under
# `CC_ORCH_SOURCE_ONLY=1` (run.sh's own seam, already used by test-run.sh) gets
# the vocabulary, the manifest parsers, the ledger row grammar and the log
# helpers without a second copy of any of them.
#
# Verbs:
#   snapshot   emit the router's whole input as one JSON object
#   grade      dry run — what are this argv's two grades? changes nothing
#   plan       dry run — would this act pass? if not, which rule refuses it
#   act        check, record, perform a pipeline act
#   exec       check, record, perform one bash line (the unit B3 counts)
#   close      resolve a pending approval from the harness-written transcript
#
# Exit codes:
#   0  performed (or, for the dry-run verbs, answered)
#   1  hard stop — malformed invocation, unreadable ledger, failed precondition
#      Past the checks, the ACT's own status passes through, so a non-zero code
#      here can also be the act's. A refusal always carries a `gate:` line on
#      stderr and produces no output from the act; that, not the number, is what
#      separates the two.
#   2  vocabulary error — a token outside a closed set
#   3  rule refusal — a catalog rule said no
#   4  stale snapshot digest — the router judged against state that has moved
#   5  approval issued — the act is outside pre-authorization and irreversible
#   6  grade self-declaration mismatch — the claimed grade is not the graded one
#   7  enforcement surface moved — a file the boundary rests on was edited
#
# Usage:
#   gate.sh snapshot --manifest <path> [--render]
#   gate.sh grade    --manifest <path> -- <argv...>
#   gate.sh plan     --manifest <path> --kind <k> --target <alias> [--segment <id>]
#                    --cutpoint <token> -- <argv...>
#   gate.sh act      --manifest <path> --kind <k> --target <alias> [--segment <id>]
#                    --cutpoint <token> --snapshot-digest <hex> --rationale <text>
#                    -- <argv...>
#   gate.sh exec     --manifest <path> --target <alias> [--segment <id>]
#                    --cutpoint <token> --surface <token>
#                    --snapshot-digest <hex> --rationale <text> -- <argv...>
#   gate.sh close    --manifest <path> --approval <id>
#
# Compatibility: bash 3.2 (macOS stock under the sanitized PATH) — no
# associative arrays, no mapfile, no `wait -n`, no case-modification expansions.
# `scripts/lint-bash-portability.sh` scans this directory at maxdepth 1, so this
# file is linted on arrival with no registration.

# `$BASH_SOURCE` and not `$0`: under the source-only seam below `$0` is the
# SOURCING script, so the run.sh path and the rule catalog would both resolve
# relative to whoever sourced this file.
GATE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)

# Source the driver for its definitions only. This must happen before `set -e`
# considerations below: run.sh sets `-euo pipefail` itself and we keep it.
CC_ORCH_SOURCE_ONLY=1
export CC_ORCH_SOURCE_ONLY
# shellcheck source=/dev/null
. "$GATE_DIR/run.sh"
# The capability half of the boundary. Sourced rather than re-implemented: the
# gate is the one process that holds the write-scoped credential, and the code
# that decides which credential a child gets has to be the same code in both
# directions or the separation is decorative.
# shellcheck source=/dev/null
. "$GATE_DIR/credentials.sh"

readonly GATE_EXIT_VOCAB=2
readonly GATE_EXIT_RULE=3
readonly GATE_EXIT_STALE=4
readonly GATE_EXIT_APPROVAL=5
readonly GATE_EXIT_GRADE=6
readonly GATE_EXIT_SURFACE=7

readonly GATE_ROW_MAX=1024

# ---------------------------------------------------------------------------
# Axis 2 — the effect surface.
#
# The cutpoint ladder is a sequence of pipeline milestones, not a lattice of
# harm. Mapping `rm -rf ~/Documents`, a curl to a payments API and an unfamiliar
# `npx` onto `배포` means a run authorized to deploy is authorized to anything —
# the ladder collapses at its top rung. So an act carries a grade on each of two
# independent axes, and both are checked.
#
# Stored tokens carry no spaces, for the same reason the cutpoint vocabulary
# splits stored from display: a value with a space cannot round-trip through the
# `for x in $LIST` word-splitting this file and run.sh both rely on, and the one
# time that distinction was skipped the index lookup answered "unknown" and
# every act was silently denied.
# ---------------------------------------------------------------------------
readonly SURFACES="읽기 워크트리쓰기 트리밖쓰기 외부상태변경"

surface_display() {
  case "$1" in
    읽기)         printf '읽기' ;;
    워크트리쓰기) printf '워크트리 쓰기' ;;
    트리밖쓰기)   printf '워크트리 밖 쓰기' ;;
    외부상태변경) printf '외부 상태 변경' ;;
    *) return 1 ;;
  esac
}

# Same discipline as cutpoint_index: signal by return status, never by `die`.
# This is always called inside `$( )`, where an exit kills only the subshell and
# leaves the caller holding an empty string.
surface_index() {
  local want="$1" i=0 s
  for s in $SURFACES; do
    i=$((i + 1))
    [ "$s" = "$want" ] && { printf '%s' "$i"; return 0; }
  done
  warn "미인식 효과면 토큰: '${want}' — 허용 토큰: ${SURFACES}"
  return 1
}

# The grading table. An argv0 with no row gets `등급 미상` and NEVER `읽기` —
# reading an unknown thing as the safest value is the characteristic failure of
# this class of table.
surface_of_argv0() {
  case "$1" in
    cat|ls|find|grep|rg|head|tail|wc|stat|file|diff|which|command)
      printf '읽기' ;;
    git)
      case "$2" in
        status|log|show|diff|rev-parse|rev-list|merge-base|branch|worktree|config|blame|cat-file|ls-files)
          printf '읽기' ;;
        add|commit|checkout|switch|restore|rebase|merge|cherry-pick|stash|apply|am|reset|tag)
          printf '워크트리쓰기' ;;
        push|fetch|pull|clone|remote)
          printf '외부상태변경' ;;
        *) printf '등급 미상' ;;
      esac ;;
    gh)
      case "$2" in
        api) printf '등급 미상' ;;
        pr|issue|release|repo|workflow|run) printf '외부상태변경' ;;
        auth) printf '등급 미상' ;;
        *) printf '등급 미상' ;;
      esac ;;
    make|npm|npx|yarn|pnpm|pytest|go|cargo|bash|sh|zsh|python3|node)
      printf '워크트리쓰기' ;;
    mkdir|touch|cp|mv|rm|sed|tee|install)
      printf '워크트리쓰기' ;;
    curl|wget|ssh|scp|rsync|terraform|kubectl|aws|gcloud|docker)
      printf '외부상태변경' ;;
    *) printf '등급 미상' ;;
  esac
}

# ---------------------------------------------------------------------------
# Ledger append — serialized, capped, chained.
#
# run.sh's comment says the ledger has one writer, and that is true of the
# COMPONENT: one function appends. It is not true of the PROCESSES — every gate
# invocation is its own shell, so two acts in flight are two writers against one
# file. Concurrent appends splice field values above 1024 bytes of total line
# length while the line count stays correct, which no row-grammar check can see.
# Three things together close that: the lock makes interleaving rare, the cap
# keeps a row under the measured threshold, and the chain makes the rare case
# detectable rather than silent.
# ---------------------------------------------------------------------------
# Every read below goes through this. A ledger that does not exist yet is the
# NORMAL state at the first act of a run, and `grep` answers a missing file with
# exit 2 — which `pipefail` promotes to the whole pipeline's status and `set -e`
# turns into a silent exit of the snapshot. The first act of the first run is
# exactly when a router most needs the snapshot to answer, so the tolerance is
# not defensive padding: it is the case that always happens.
gate_rows() {
  # gate_rows <series>
  grep -E "^- \`$1\`" "$LEDGER" 2>/dev/null || true
}

gate_count() {
  # Count of non-empty lines on stdin. `grep -c` answers 0 with exit 1 on empty
  # input, so the usual `|| printf 0` fallback prints a SECOND zero and the
  # caller ends up interpolating `0\n0` — which produced a syntactically
  # invalid snapshot object rather than a wrong number, so nothing downstream
  # could even read far enough to notice.
  grep -c . || true
}

gate_chain_tip() {
  # The digest of the ledger's last non-empty line, or of the run block heading
  # when no row has been written yet.
  local last
  last=$(grep -v '^[[:space:]]*$' "$LEDGER" 2>/dev/null | tail -1)
  [ -n "$last" ] || last="## 실행 $RUN_ID"
  printf '%s' "$last" | shasum -a 256 | cut -d' ' -f1
}

gate_append() {
  # gate_append <계열> <field=value> ...
  #
  # The writer hashes what it INTENDED to write, not a re-read of the file — a
  # chain built from a re-read certifies whatever landed, including a splice.
  local series="$1"; shift
  local prev line f
  prev=$(gate_chain_tip)
  line="- \`$series\`"
  for f in "$@"; do line="$line | $f"; done
  line="$line | prev=$prev"

  local n
  n=$(printf '%s\n' "$line" | wc -c | tr -d ' ')
  if [ "$n" -gt "$GATE_ROW_MAX" ]; then
    die "원장 행이 상한을 넘습니다 (${n} > ${GATE_ROW_MAX} 바이트) — 긴 값은 사이드카로 빼야 합니다: ${series}"
  fi

  local tool
  tool=$(lock_tool)
  if [ -n "$tool" ]; then
    "$tool" -k "$RUN_DIR/ledger.lock" \
      /bin/sh -c 'printf "%s\n" "$1" >> "$2"' _ "$line" "$LEDGER"
  else
    printf '%s\n' "$line" >> "$LEDGER"
  fi
}

# ---------------------------------------------------------------------------
# Progress vector and its digest.
#
# This is NOT the snapshot. The snapshot is what the router reads and is
# deliberately rich; P is what stagnation is measured over and is deliberately
# poor. Excluded on purpose: cost (monotone), recurrence counts (monotone),
# the no-progress counter itself (self-referential), timestamps, absolute paths,
# and — the one that is easy to get wrong — pending approvals.
#
# Pending approvals are excluded because every boundary that fires ISSUES one.
# With them inside, the boundary's own remedy mutates the hashed input and
# resets the counter that fired it, so the bound can never be reached. That is
# the same defect one layer up from the counter-inside-its-own-hash bug this
# design was written to remove.
# ---------------------------------------------------------------------------
gate_progress_vector() {
  local a
  printf 'goal=%s\n' "$(manifest_field '인가' '종료 지점' | shasum -a 256 | cut -d' ' -f1)"
  for a in $(target_aliases); do
    printf 'target=%s|%s|%s\n' "$a" \
      "$(target_field "$a" '원격 슬러그')" "$(target_field "$a" '절단점')"
  done | sort
  gate_rows 'segment' \
    | sed -n 's/.*id=\([^|]*\).*/\1/p' | sed 's/[[:space:]]*$//' | sort -u \
    | while IFS= read -r sid; do
        [ -n "$sid" ] || continue
        printf 'segment=%s|%s|%s\n' "$sid" \
          "$(gate_segment_field "$sid" '상태')" "$(gate_segment_field "$sid" '커밋')"
      done
  gate_open_obligations | sort
}

gate_progress_digest() {
  gate_progress_vector | shasum -a 256 | cut -d' ' -f1
}

gate_segment_field() {
  # Last row for this segment id wins — the append-only advance of contract 3.4.
  local sid="$1" key="$2"
  gate_rows 'segment' \
    | grep -F "id=$sid " | tail -1 \
    | tr '|' '\n' | sed -n "s/^ *$key=//p" | sed 's/[[:space:]]*$//' | tail -1
}

gate_open_obligations() {
  # An obligation is closed only by a LATER cycle row for the same segment whose
  # report no longer carries the identity — a `problem` row records an attempt,
  # not a resolution, so reading closure from it would mark every re-try as a fix.
  gate_rows 'problem' \
    | tr '|' '\n' | sed -n 's/^ *동일성=//p' | sed 's/[[:space:]]*$//' \
    | sort -u | while IFS= read -r ident; do
        [ -n "$ident" ] || continue
        printf 'obligation=%s\n' "$ident"
      done
}

gate_ledger_damage() {
  # Rows that do not parse as rows. Never silently zero: a skipped row could be
  # the cycle row carrying the P0 that the merge rule reads, and skipping it
  # makes a live defect look resolved.
  local n total
  n=$(grep -E '^- `[^`]+`( \|.*)?$' "$LEDGER" 2>/dev/null | gate_count)
  total=$(grep -E '^- `' "$LEDGER" 2>/dev/null | gate_count)
  printf '%s' $(( total - n ))
}

# ---------------------------------------------------------------------------
# Per-target cutpoint adjudication.
#
# `authorized()` is deliberately NOT used. It takes one argument, reads the
# grant's run-level maximum, and no call site passes a target — so a run
# declaring `frontend: PR` alongside `infra: 배포` authorizes deploy-grade acts
# against the front end. That is filed as Nharu/cc-cmds#208. The value that
# authorizes an act is the one on that act's target row, and this reads it there.
# ---------------------------------------------------------------------------
# The gate resolves the vocabulary — it holds run.sh's tables — and the catalog
# decides. Keeping the comparison here as well would put the same rule in two
# places, and the one that drifts is the one nobody is looking at.
gate_export_cutpoints() {
  # gate_export_cutpoints <alias> <act-token>
  local alias="$1" act="$2" tgt
  GATE_ACT_INDEX=$(cutpoint_index "$act") || return "$GATE_EXIT_VOCAB"
  tgt=$(target_field "$alias" '절단점')
  [ -n "$tgt" ] || { warn "대상 '$alias' 의 절단점이 매니페스트에 없습니다"; return 1; }
  GATE_TARGET_CUTPOINT="$tgt"
  GATE_TARGET_INDEX=$(cutpoint_index "$tgt") || return "$GATE_EXIT_VOCAB"
  export GATE_ACT_INDEX GATE_TARGET_CUTPOINT GATE_TARGET_INDEX
  return 0
}

# ---------------------------------------------------------------------------
# Rule catalog.
#
# A rule is a `.rule` declaration plus a checker script, and the loader reads
# the pair. A declaration whose checker is missing is not loaded at all, so
# "declared but unenforceable" is not a state this catalog can be in — which is
# the property the design asked for and the reason the catalog is a directory
# rather than a table.
# ---------------------------------------------------------------------------
gate_rules_dir() { printf '%s/rules' "$GATE_DIR"; }

gate_rule_order() {
  # Declaration paths, ascending by `순서:`. A declaration with no `순서:` sorts
  # last rather than being dropped — a rule missing one field is still a rule,
  # and silently unloading it is the "declared but unenforceable" state this
  # catalog is shaped to make impossible.
  local d f n
  d=$(gate_rules_dir)
  for f in "$d"/*.rule; do
    [ -f "$f" ] || continue
    n=$(sed -n 's/^순서: *\([0-9][0-9]*\).*/\1/p' "$f" | head -1)
    [ -n "$n" ] || n=999
    printf '%s\t%s\n' "$n" "$f"
  done | sort -n | cut -f2
}

gate_rule_enabled() {
  # A rule is on unless the manifest turns it off. Three ignore the setting:
  # `절단점 준수`, `사전 인가 대조` and `인가 자기확장 금지`. The authorization
  # record means nothing if the first two can be switched off, and a
  # self-widening ban that can be switched off is not a ban at all — after the
  # first time it is turned off, the record does not even say what was turned
  # off.
  local name="$1"
  case "$name" in
    절단점-준수|사전-인가-대조|인가-자기확장-금지) return 0 ;;
  esac
  local setting
  setting=$(manifest_field '룰 설정' "$name")
  [ "$setting" = "끔" ] && return 1
  return 0
}

gate_run_rules() {
  # gate_run_rules <act-token> <alias> <segment> <argv-string>
  # Returns 0 when every loaded rule passes, GATE_EXIT_RULE on the first refusal.
  local act="$1" alias="$2" seg="$3" argv="$4"
  local dir decl name checker
  dir=$(gate_rules_dir)
  [ -d "$dir" ] || return 0
  # Ordered by each declaration's `순서:` field, not by the glob. Glob order
  # over Korean filenames is arbitrary, and the first refusal is the one the
  # run reports — so under the shipped order a cutpoint violation came back as
  # "the ledger is unreadable", which sends a 3am reader to the wrong repair.
  # The cheapest and most fundamental checks go first so the reported reason is
  # the most fundamental one that holds.
  for decl in $(gate_rule_order); do
    [ -f "$decl" ] || continue
    name=$(basename "$decl" .rule)
    checker="$dir/$name.sh"
    if [ ! -f "$checker" ]; then
      warn "룰 '$name' 의 검사기가 없어 로드하지 않습니다 — 선언만으로는 강제되지 않습니다"
      continue
    fi
    gate_rule_enabled "$name" || continue
    local rc=0
    GATE_ACT="$act" GATE_ALIAS="$alias" GATE_SEGMENT="$seg" GATE_ARGV="$argv" \
      GATE_LEDGER="$LEDGER" GATE_MANIFEST="$MANIFEST" GATE_GRANT="$GRANT" \
      /bin/sh "$checker" || rc=$?
    [ "$rc" = "0" ] && continue
    # A checker may ask for an approval instead of refusing. Folding that into a
    # plain refusal is what turns "nobody is awake to ask" into "the answer is
    # no" — the collapse this design exists to undo.
    if [ "$rc" = "$GATE_EXIT_APPROVAL" ]; then
      warn "룰 '$name' 이 승인 대기를 요구합니다"
      return "$GATE_EXIT_APPROVAL"
    fi
    warn "룰 거부: $name"
    return "$GATE_EXIT_RULE"
  done
  return 0
}

# ---------------------------------------------------------------------------
# Snapshot — the router's entire declared input.
#
# JSON on stdout rather than a table: a table cannot express arrays, cannot be
# canonically serialized, and cannot be validated. `--render` turns the same
# object into the human form for the terminal.
#
# Two fields are unbounded in run length and are therefore capped, with their
# true totals reported separately. Truncating a list while reporting the real
# total is safe; truncating the total is how a router concludes a P0 is gone.
# ---------------------------------------------------------------------------
readonly GATE_OBLIGATION_CAP=50

gate_json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

gate_snapshot() {
  local a total shown
  printf '{\n'
  printf '  "run_id": "%s",\n' "$(gate_json_escape "$RUN_ID")"
  printf '  "goal": "%s",\n' "$(gate_json_escape "$(manifest_field '인가' '종료 지점')")"
  printf '  "goal_digest": "%s",\n' \
    "$(manifest_field '인가' '종료 지점' | shasum -a 256 | cut -d' ' -f1)"

  printf '  "targets": [\n'
  local first=1
  for a in $(target_aliases); do
    [ "$first" = "1" ] || printf ',\n'
    first=0
    printf '    {"alias": "%s", "slug": "%s", "cutpoint": "%s", "home": "%s"}' \
      "$(gate_json_escape "$a")" \
      "$(gate_json_escape "$(target_field "$a" '원격 슬러그')")" \
      "$(gate_json_escape "$(target_field "$a" '절단점')")" \
      "$(gate_json_escape "$(target_field "$a" '홈')")"
  done
  [ "$first" = "1" ] || printf '\n'
  printf '  ],\n'

  printf '  "obligations": [\n'
  total=$(gate_open_obligations | gate_count)
  shown=0
  first=1
  gate_open_obligations | head -"$GATE_OBLIGATION_CAP" | while IFS= read -r o; do
    [ -n "$o" ] || continue
    [ "$shown" = "0" ] || printf ',\n'
    shown=1
    printf '    "%s"' "$(gate_json_escape "${o#obligation=}")"
  done
  [ "$first" = "1" ] && [ "$total" = "0" ] || printf '\n'
  printf '  ],\n'
  printf '  "obligations_total": %s,\n' "$total"

  printf '  "pending_approvals": [\n'
  gate_pending_approvals_json
  printf '  ],\n'

  printf '  "ledger_damage": %s,\n' "$(gate_ledger_damage)"
  printf '  "H": "%s"\n' "$(gate_progress_digest)"
  printf '}\n'
}

gate_pending_approvals_json() {
  local ids id state first=1
  ids=$(gate_rows '승인' \
        | tr '|' '\n' | sed -n 's/^ *승인 id=//p' | sed 's/[[:space:]]*$//' | sort -u)
  for id in $ids; do
    state=$(gate_rows '승인' | grep -F "승인 id=$id " | tail -1 \
            | tr '|' '\n' | sed -n 's/^ *상태=//p' | sed 's/[[:space:]]*$//' | tail -1)
    [ "$state" = "대기" ] || continue
    [ "$first" = "1" ] || printf ',\n'
    first=0
    printf '    {"id": "%s", "blocks": "%s"}' \
      "$(gate_json_escape "$id")" \
      "$(gate_json_escape "$(gate_rows '승인' | grep -F "승인 id=$id " | tail -1 \
          | tr '|' '\n' | sed -n 's/^ *막는 세그먼트=//p' | sed 's/[[:space:]]*$//' | tail -1)")"
  done
  [ "$first" = "1" ] || printf '\n'
}

gate_render_snapshot() {
  local a
  printf '목표      : %s\n' "$(manifest_field '인가' '종료 지점')"
  printf '진전 해시 : %s\n' "$(gate_progress_digest)"
  printf '원장 손상 : %s\n' "$(gate_ledger_damage)"
  printf '대상      :\n'
  for a in $(target_aliases); do
    printf '  %-12s %-24s 절단점 %s\n' "$a" \
      "$(target_field "$a" '원격 슬러그')" "$(target_field "$a" '절단점')"
  done
  printf '미해결 의무: %s건\n' "$(gate_open_obligations | gate_count)"
}

# ---------------------------------------------------------------------------
# Run settings — one file per stage kind, written by the gate, injected by the
# wrapper.
#
# This file is the premise of three separate decisions and had no producing step
# in any of them; two of those decisions also disagreed about its shape, one
# calling for a single shared file and the other for a `design`-specific variant.
# It is settled here: a DIRECTORY under the run directory with one file per stage
# kind, the common gate hook in every variant, and the network-fetch denial in
# the `design` variant only.
#
# The whole directory is an enforcement surface, not one file inside it — the
# digest set the gate re-derives on every hook consultation takes the directory
# as its element, because adding a variant must not be a way to escape the
# comparison.
# ---------------------------------------------------------------------------
readonly STAGE_KINDS="design implement review audit reconverge generic"

gate_settings_dir() { printf '%s/settings' "$RUN_DIR"; }

gate_settings_file() {
  # gate_settings_file <stage-kind>
  local k="$1"
  case " $STAGE_KINDS " in
    *" $k "*) : ;;
    *) k="generic" ;;
  esac
  printf '%s/%s.json' "$(gate_settings_dir)" "$k"
}

gate_write_settings() {
  # Writes every variant. Called at run start and idempotent — a re-run after a
  # session cut must find the same bytes, because those bytes are in the
  # enforcement-surface digest set and a regenerated-but-different file would
  # read as tampering.
  local dir hook k f deny_extra
  dir=$(gate_settings_dir)
  mkdir -p "$dir"
  hook="$(dirname "$GATE_DIR")/hooks/gate-pretool.sh"
  [ -f "$hook" ] || die "게이트 훅 스크립트가 없습니다: $hook"

  for k in $STAGE_KINDS; do
    f=$(gate_settings_file "$k")
    # `design` alone loses the network-fetch tools. The per-stage spend cap that
    # motivates it cannot be enforced by the argv0 grading table at all — a
    # `WebFetch` call has no argv0 and never reaches the gate — so the only
    # enforcement point available is the settings file the wrapper injects.
    deny_extra=""
    [ "$k" = "design" ] && deny_extra='"WebFetch", "WebSearch", '
    cat > "$f" <<JSON
{
  "permissions": { "deny": [ ${deny_extra}"Bash(sudo:*)" ] },
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash|Write|Edit|MultiEdit|NotebookEdit",
        "hooks": [
          {
            "type": "command",
            "command": "bash '$hook' --run-dir '$RUN_DIR' --gate '$GATE_DIR/gate.sh' --ledger '$LEDGER' --grant '$GRANT'"
          }
        ]
      }
    ]
  }
}
JSON
  done
  printf '%s\n' "$(gate_surface_digest)" > "$RUN_DIR/surface-digest"
  log "런 설정 생성: $dir (강제 표면 기준선 기록)"
}

gate_surface_check() {
  # Compared on every act, not only at run start. The four surfaces the hook
  # cannot deny a write to get after-the-fact detection only, and after-the-fact
  # is still before the NEXT act — which is the difference between one act
  # slipping through and the rest of the night doing so.
  local base now
  base=$(cat "$RUN_DIR/surface-digest" 2>/dev/null || true)
  [ -n "$base" ] || return 0
  now=$(gate_surface_digest)
  [ "$now" = "$base" ] && return 0
  warn "강제 표면이 런 개시 이후 바뀌었습니다 (기준선 ${base}, 현재 ${now}) — 설정·룰·훅·프로젝트 설정 중 하나가 편집됐습니다"
  return "$GATE_EXIT_SURFACE"
}

gate_surface_digest() {
  # The extension is re-derived on every call rather than listed once: the
  # fourth element is "the project-scope settings of every worktree the manifest
  # and the target-addition rows name", and targets are added at RUNTIME. A
  # fixed file list would stop covering a target the moment one was added, and
  # would not report that it had stopped.
  local a wt
  {
    find "$(gate_settings_dir)" -type f 2>/dev/null | sort
    find "$(gate_rules_dir)" -type f 2>/dev/null | sort
    printf '%s\n' "$(dirname "$GATE_DIR")/hooks/gate-pretool.sh"
    for a in $(target_aliases); do
      wt=$(target_field "$a" '메인 워크트리')
      [ -n "$wt" ] || continue
      printf '%s\n' "$wt/.claude/settings.json"
    done
  } | while IFS= read -r f; do
        [ -f "$f" ] || continue
        printf '%s  %s\n' "$(shasum -a 256 "$f" | cut -d' ' -f1)" "$f"
      done | shasum -a 256 | cut -d' ' -f1
}

# ---------------------------------------------------------------------------
# Verb dispatch
# ---------------------------------------------------------------------------
gate_usage() {
  sed -n '/^# Usage:/,/^#$/p' "$0" | sed 's/^# \{0,1\}//'
}

gate_main() {
  [ $# -ge 1 ] || { gate_usage >&2; exit 2; }
  local verb="$1"; shift
  local kind="" alias="" segment="-" cutpoint="" surface="" snapdig="" rationale=""
  local approval="" render=0
  MANIFEST=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --manifest)        MANIFEST="$2"; shift 2 ;;
      --kind)            kind="$2"; shift 2 ;;
      --target)          alias="$2"; shift 2 ;;
      --segment)         segment="$2"; shift 2 ;;
      --cutpoint)        cutpoint="$2"; shift 2 ;;
      --surface)         surface="$2"; shift 2 ;;
      --snapshot-digest) snapdig="$2"; shift 2 ;;
      --rationale)       rationale="$2"; shift 2 ;;
      --approval)        approval="$2"; shift 2 ;;
      --render)          render=1; shift ;;
      --)                shift; break ;;
      *) printf 'gate: 알 수 없는 인자: %s\n' "$1" >&2; exit 2 ;;
    esac
  done

  [ -n "$MANIFEST" ] || { printf 'gate: --manifest 가 필요합니다\n' >&2; exit 2; }
  check_manifest
  derive_paths_from_manifest
  rundir_init
  # Run start is "the settings directory does not exist yet". Regenerating on
  # every invocation would rewrite files that are themselves in the digest set,
  # and a surface that changes because the gate touched it is a surface whose
  # comparison means nothing.
  [ -d "$(gate_settings_dir)" ] || gate_write_settings

  case "$verb" in
    snapshot)
      if [ "$render" = "1" ]; then gate_render_snapshot; else gate_snapshot; fi
      ;;
    grade)
      [ $# -ge 1 ] || { printf 'gate: grade 는 -- 뒤에 argv 가 필요합니다\n' >&2; exit 2; }
      local g
      g=$(surface_of_argv0 "$1" "${2:-}")
      printf '축2=%s\n' "$g"
      # `[ … ] && exit` as the arm's last command hands the FALSE test's status
      # to the caller — a successful grade then exits 1 and reads as a refusal.
      if [ "$g" = "등급 미상" ]; then exit "$GATE_EXIT_VOCAB"; fi
      ;;
    plan|act|exec)
      gate_verb_act "$verb" "$kind" "$alias" "$segment" "$cutpoint" "$surface" \
                    "$snapdig" "$rationale" "$@"
      ;;
    close)
      [ -n "$approval" ] || { printf 'gate: close 는 --approval 이 필요합니다\n' >&2; exit 2; }
      gate_close "$approval"
      ;;
    *)
      printf 'gate: 알 수 없는 동사: %s\n' "$verb" >&2; exit 2 ;;
  esac
}

gate_verb_act() {
  local verb="$1" kind="$2" alias="$3" segment="$4" cutpoint="$5" surface="$6"
  local snapdig="$7" rationale="$8"; shift 8
  local argv="$*"

  [ -n "$alias" ]    || { printf 'gate: --target 이 필요합니다\n' >&2; exit 2; }
  [ -n "$cutpoint" ] || { printf 'gate: --cutpoint 이 필요합니다\n' >&2; exit 2; }
  [ $# -ge 1 ]       || { printf 'gate: -- 뒤에 argv 가 필요합니다\n' >&2; exit 2; }

  # Vocabulary first, and by return status rather than `die` — see surface_index.
  cutpoint_index "$cutpoint" >/dev/null || exit "$GATE_EXIT_VOCAB"
  case " $(target_aliases | tr '\n' ' ') " in
    *" $alias "*) : ;;
    *) printf 'gate: 매니페스트에 없는 대상: %s\n' "$alias" >&2; exit "$GATE_EXIT_VOCAB" ;;
  esac

  # The router's declared surface is a CHECKED CLAIM, not a self-grant. A
  # mismatch is exit 6 — the same idiom the slicing declaration's `슬라이스 수`
  # already uses, where a value the writer supplies is compared against one the
  # reader derives instead of being trusted.
  local graded
  graded=$(surface_of_argv0 "$1" "${2:-}")
  if [ -n "$surface" ]; then
    surface_index "$surface" >/dev/null || exit "$GATE_EXIT_VOCAB"
    if [ "$surface" != "$graded" ]; then
      warn "축2 자기선언 불일치: 선언 '$surface' vs 등급 '$graded'"
      exit "$GATE_EXIT_GRADE"
    fi
  fi
  if [ "$graded" = "등급 미상" ]; then
    warn "축2 등급 미상 — 등급표에 없는 argv0 는 읽기로 떨어지지 않습니다: $1"
    [ "$verb" = "plan" ] || exit "$GATE_EXIT_VOCAB"
  fi

  # Snapshot binding. Under parallel segments a background stage can land a row
  # between the router reading the snapshot and calling here; the main session
  # also compacts, and a compacted router carrying a remembered digest is a
  # correctness failure that is otherwise invisible. Exit 4 turns both into a
  # loud re-read.
  if [ "$verb" != "plan" ]; then
    [ -n "$snapdig" ] || { printf 'gate: --snapshot-digest 가 필요합니다\n' >&2; exit 2; }
    local now
    now=$(gate_progress_digest)
    if [ "$snapdig" != "$now" ]; then
      warn "낡은 스냅숏 다이제스트: 관측 '$snapdig' vs 현재 '$now'"
      exit "$GATE_EXIT_STALE"
    fi
  fi

  gate_export_cutpoints "$alias" "$cutpoint" || exit $?
  GATE_SURFACE="$graded"; export GATE_SURFACE

  gate_run_rules "$cutpoint" "$alias" "$segment" "$argv" || exit $?

  if [ "$verb" = "plan" ]; then
    printf '통과 예상: kind=%s target=%s 절단점=%s 축2=%s\n' \
      "$kind" "$alias" "$cutpoint" "$graded"
    return 0
  fi

  gate_surface_check || exit $?

  gate_append '자율 승인' "kind=$kind" "결정=$verb" "대상=$alias" "세그먼트=$segment" \
    "절단점=$cutpoint" "축2=$graded" "근거=$rationale"
  log "게이트 통과 — $verb $cutpoint ($alias)"

  # ---- and now PERFORM it -------------------------------------------------
  #
  # Recording without performing is what the first cut of this file did, and it
  # makes the whole layer unreachable: layer 1 denies every bash line that is
  # not this script, so if this script does not run the line, nothing runs at
  # all. The row is written BEFORE the act, deliberately — a row with no act is
  # an over-report a person can see in the morning, and an act with no row is
  # the thing this design exists to prevent.
  local rc=0
  case "$verb" in
    exec)
      # The stage's own credential set: read-scoped, so a `gh pr merge` spelled
      # here fails at the API rather than at a string match.
      gate_run_readonly "$@" || rc=$?
      ;;
    act)
      case "$kind" in
        skill) gate_launch_stage "$segment" "$@" || rc=$? ;;
        *)     gate_run_readonly "$@" || rc=$? ;;
      esac
      ;;
  esac
  # The act's own status passes through, the way `env` and `nice` pass one
  # through. A gate REFUSAL is 2..7 and always arrives with a `gate:` line on
  # stderr and no output from the act, so the two are told apart by what came
  # with the code rather than by the code alone — which is the honest reading,
  # since an act is free to exit 3 for its own reasons and no remapping can
  # both preserve its status and reserve a band.
  #
  # A failure gets a SECOND row. The first is written before the act so that a
  # crash mid-act still leaves a record; adding the outcome to that row would
  # mean holding it until the act returned, which is the property being bought
  # by writing early.
  if [ "$rc" != "0" ]; then
    warn "행위가 실패했습니다 (rc=$rc) — 행은 이미 원장에 있습니다"
    gate_append '자율 승인' "kind=$kind" "결정=결과" "대상=$alias" "세그먼트=$segment" \
      "절단점=$cutpoint" "축2=$graded" "근거=rc=$rc"
  fi
  return "$rc"
}

gate_run_readonly() {
  # Runs the act under the READ-scoped credential. A `gh pr merge` spelled here
  # then fails at the GitHub API rather than at a string match, and that failure
  # is unforgeable — which is the property no string matcher can have. Acts that
  # genuinely need the write-scoped credential do not come through this door;
  # they are performed by the gate's own verbs.
  local line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    export "$line"
  done <<CREDS
$(cred_readonly_env 2>/dev/null || true)
CREDS
  "$@"
}

gate_launch_stage() {
  # gate_launch_stage <segment> <stage-kind> <cli args...>
  #
  # The wrapper's only legitimate caller, stated in one place. It is an argv
  # laundering tool for whoever holds an allow-list entry, so the set of callers
  # is a design commitment rather than an accident — and this is it.
  local seg="$1" kind="$2"; shift 2
  local wrapper="$GATE_DIR/stage-wrapper.sh"
  [ -f "$wrapper" ] || { warn "스테이지 래퍼가 없습니다: $wrapper"; return 127; }
  local plugin_dir
  plugin_dir=$(cd "$(dirname "$GATE_DIR")" && pwd)
  /bin/sh "$wrapper" \
    --settings "$(gate_settings_file "$kind")" \
    --plugin-dir "$plugin_dir" \
    --session-id "$(session_uuid "$seg")" \
    -- "$@"
}

gate_close() {
  # Resolving an approval reads the harness-written transcript rather than the
  # router's prose, so the entity that asks is not the entity that records. That
  # channel is only meaningful while the hook denies Write and Edit to the
  # transcript directory, which is the run settings' job rather than this
  # script's — this verb's contract is that it never accepts an answer the
  # router typed.
  local id="$1"
  warn "close 는 라우터가 붙는 단계에서 완성됩니다 — 지금은 트랜스크립트 판독기가 없습니다"
  printf 'gate: close 미구현 (승인 id=%s)\n' "$id" >&2
  exit 1
}

# The same seam run.sh carries, for the same reason: the tests need the
# definitions without a manifest, a run directory, or a verb. `test-snapshot.sh`
# calls `gate_progress_digest` directly against a fixture ledger, which is the
# only way to assert that issuing an approval leaves the digest unchanged — the
# regression that guards the boundary counters against resetting themselves.
if [ "${CC_GATE_SOURCE_ONLY:-0}" = "1" ]; then
  return 0 2>/dev/null || exit 0
fi

gate_main "$@"
