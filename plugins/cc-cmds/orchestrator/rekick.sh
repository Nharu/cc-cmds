#!/usr/bin/env bash
#
# rekick.sh — the successor verdict, its stop predicates, the successor id, and
# the deriver that writes a successor run's three files.
#
# Usage
#   rekick.sh verdict <predecessor manifest> [--lane present|absent]
#                     [--pin usable|unusable|none]
#       → one line `<판정>\t<원인>\t<사유>` on stdout, exit 0.
#         <판정> is one of 자동 · 승인 · 사람 · 상한 · 진행 · 없음; <원인> is the
#         token a successor's `연쇄` row would carry, `-` when there is none.
#   rekick.sh id <재킥오프 시각 ISO Z> <선행 런> <순번>
#       → the successor run id.
#   rekick.sh derive --predecessor <manifest> --claim <claim directory>
#                    --verdict 자동|승인 [--approval <run>#<id> --answer-digest <hex>]
#       → `열림\t<id>\t<manifest>\t<문서 sha256>` and exit 0, or
#         `사람\t<사유>` and exit 4 (nothing written), or
#         `invalid\t<사유>` and exit 3.
#
# REFUSED INSIDE A PIPELINE STAGE. A stage carries `CC_PIPELINE_RUN_ID`, and a
# stage that could run this program could open a run nobody authorized. The
# check is a second layer only — one word in front of the command unsets the
# variable — and the boundaries that hold are the admission check's demand for
# the dispatcher's claim, the refused writes to the pace directory and to every
# run's authorization artifacts, and the grade this program's name gets.
#
# SOURCED, THIS FILE ONLY DEFINES FUNCTIONS. run.sh sources it so the admission
# check calls the same predicates the verdict does; the program mode below
# sources the gate for the readers it reuses rather than re-implementing them.
#
# What this program reads is the predecessor's manifest, authorization record,
# kickoff trace and ledger, the chain's earlier manifests and ledgers, the
# claim directory and the pace backlog. Nothing a person wrote ahead of time
# for a kickoff is read here: a successor is the root's consent carried
# forward, never a new answer.
#
# Compatibility: bash 3.2 — no associative arrays, no mapfile.

if [ "${BASH_SOURCE[0]}" = "$0" ] && [ "${CC_REKICK_SOURCE_ONLY:-0}" != "1" ] \
   && [ -n "${CC_PIPELINE_RUN_ID+x}" ]; then
  printf 'rekick.sh: 파이프라인 스테이지 안에서는 돌지 않습니다 (CC_PIPELINE_RUN_ID 가 설정돼 있음)\n' >&2
  exit 2
fi

# Plain assignments, not `readonly`: the program mode sources the gate, the
# gate sources the driver, and the driver sources this file a second time.
REKICK_ID_RE='^[0-9]{8}-[0-9a-f]{8}$'
REKICK_ISO_Z_RE='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'
REKICK_HEX_RE='^[0-9a-f]{64}$'
REKICK_TAB=$(printf '\t')

# ---------------------------------------------------------------------------
# Reading another run's files with this file's readers.
# ---------------------------------------------------------------------------

rekick_in() {
  # rekick_in <manifest> <command>... — run a manifest reader against another
  # manifest. In a child shell, with the memo off: the memo answers only for the
  # manifest it was taken from, and the caller's own memo must not leak into a
  # read of a different file.
  local m="$1"; shift
  ( MANIFEST="$m"; MANIFEST_MEMO_PATH=""; MANIFEST_MEMO=""; "$@" )
}

rekick_hdr() { rekick_in "$1" manifest_hdr_field "$2"; }
rekick_field() { rekick_in "$1" manifest_field "$2" "$3"; }

rekick_row_field() {
  # rekick_row_field <row> <key> — the last value of that key in one row.
  manifest_row_fields "$1" "$2" 1 | tail -1
}

rekick_chain_row() { rekick_in "$1" manifest_chain_rows | head -1; }
rekick_consent_row() { rekick_in "$1" manifest_rekick_rows | head -1; }

rekick_binding_digest() {
  # rekick_binding_digest <manifest> — the binding digest recomputed from that
  # manifest's bytes, not read from its field.
  rekick_in "$1" binding_set_bytes | shasum -a 256 | cut -d' ' -f1
}

rekick_paths() {
  # rekick_paths <manifest> — `<BASE>\t<GRANT>\t<LEDGER>\t<DOC>` by the one
  # derivation every entry uses.
  local m="$1"
  (
    MANIFEST="$m"; MANIFEST_MEMO_PATH=""; MANIFEST_MEMO=""
    RUN_ID=$(manifest_hdr_field 'run-id')
    ANCHOR_KEY=$(manifest_hdr_field 'anchor-key')
    derive_paths_from_manifest >/dev/null 2>&1 || exit 1
    printf '%s\t%s\t%s\t%s\n' "$BASE" "$GRANT" "$LEDGER" "$DOC"
  )
}

rekick_ledger_of() {
  # rekick_ledger_of <manifest> — the ledger path beside the manifest. The
  # contract puts both in one directory under one run id.
  local m="$1" id
  id=$(rekick_hdr "$m" 'run-id')
  [ -n "$id" ] || return 1
  printf '%s/%s.md' "$(dirname "$m")" "$id"
}

# ---------------------------------------------------------------------------
# One run's ending, read off its ledger.
# ---------------------------------------------------------------------------

rekick_end_token() {
  # rekick_end_token <ledger> — the end token, by the gate's own reader.
  ( LEDGER="$1"; gate_end_token )
}

rekick_end_row() {
  ( LEDGER="$1"; gate_end_token_row )
}

rekick_completed() {
  # rekick_completed <ledger> — the run ended as a normal completion: its end
  # token is `해당없음` and the row that settled it says `종료 부류=완료`.
  local row
  row=$(rekick_end_row "$1") || return 1
  [ "$(rekick_row_field "$row" '재킥 원인')" = "해당없음" ] || return 1
  [ "$(rekick_row_field "$row" '종료 부류')" = "완료" ]
}

rekick_fingerprint() {
  local row
  row=$(rekick_end_row "$1") || return 1
  rekick_row_field "$row" '재킥 지문'
}

rekick_park_causes() {
  # rekick_park_causes <ledger> — the distinct `대상미선언`·`슬라이싱` tokens of
  # the run's park rows, in first-written order. Rows carried in from another
  # ledger (`출처=`) are that other run's account and are not read.
  grep -E '^- `blocked` \| ' "$1" 2>/dev/null \
    | grep -v ' | 출처=' \
    | grep -oE ' \| 재킥 원인=(대상미선언|슬라이싱)( \||$)' \
    | sed -E 's/^ \| 재킥 원인=//; s/ \|$//' \
    | awk '!seen[$0]++' || true
}

rekick_park_rows() {
  grep -E '^- `blocked` \| ' "$1" 2>/dev/null \
    | grep -v ' | 출처=' \
    | grep -E ' \| 재킥 원인=(대상미선언|슬라이싱)( \||$)' || true
}

rekick_progress_rows() {
  # rekick_progress_rows <ledger> — the rows that count as progress within one
  # link, printed: a newly satisfied termination clause, a segment newly merged
  # or completed at a PR cutpoint, a review cycle, and a design or audit stage
  # that completed normally (a newly frozen design or audit artifact). Imported
  # rows (`출처=`) are the predecessor's work and are not counted again.
  grep -E '^- `(종료 절|segment|cycle|stage-result)` \| ' "$1" 2>/dev/null \
    | grep -v ' | 출처=' \
    | awk '
        index($0, "- `종료 절` | ") == 1 { if ($0 ~ / \| 상태=충족( \||$)/) print; next }
        index($0, "- `segment` | ") == 1 { if ($0 ~ / \| 상태=(머지됨|완료)( \||$)/) print; next }
        index($0, "- `cycle` | ") == 1 { print; next }
        index($0, "- `stage-result` | ") == 1 {
          if ($0 ~ / \| 종단 부류=정상 완료( \||$)/ &&
              $0 ~ / \| (스테이지=(S1design|S2)|종류=(design|design-audit))( \||$)/) print
          next
        }' || true
}

rekick_recorded_doc_sha() {
  # rekick_recorded_doc_sha <ledger> — the design document digest the run
  # RECORDED, never one measured now: a value measured at commit time would
  # make the dispatcher's comparison the same file hashed twice. The sources
  # are the `run` row's `전체 sha256` and the gate's `문서 해시` rows (the
  # latest). Either alone is enough; both present and different, or neither
  # present, is no answer.
  local led="$1" a b
  a=$(grep -E '^- `run` \| ' "$led" 2>/dev/null | head -1 | tr '|' '\n' \
        | sed -n 's/^ *전체 sha256=//p' | sed 's/[[:space:]]*$//' | tail -1)
  b=$(grep -E '^- `문서 해시` \| ' "$led" 2>/dev/null | tail -1 | tr '|' '\n' \
        | sed -n 's/^ *sha256=//p' | sed 's/[[:space:]]*$//' | tail -1)
  printf '%s' "$a" | grep -Eq "$REKICK_HEX_RE" || a=""
  printf '%s' "$b" | grep -Eq "$REKICK_HEX_RE" || b=""
  if [ -n "$a" ] && [ -n "$b" ] && [ "$a" != "$b" ]; then return 1; fi
  [ -n "$a$b" ] || return 1
  printf '%s' "${b:-$a}"
}

# ---------------------------------------------------------------------------
# The chain, walked back from the predecessor to the root.
# ---------------------------------------------------------------------------

rekick_chain_links() {
  # rekick_chain_links <predecessor manifest> — one line per link, ROOT FIRST:
  # `<id>\t<manifest>\t<ledger|->\t<end token|->\t<지문|->\t<progress 1|0|->`.
  #
  # Every ledger is chain-verified as that run's own (`gate_chain_verify
  # <ledger> <run id>`) before one row of it is read, and a ledger that fails
  # makes the whole walk fail: a predicate answering from rows that may have
  # been rewritten answers for whoever rewrote them. A link with no ledger is
  # read as never started only where the link after it says so (`원인=연기마감`)
  # or where it is the predecessor itself; it is then no link for the progress
  # count. Anything else missing fails the walk.
  local m="$1" id led tok fp prog ch prev next_cause="" first=1 out="" guard=0
  while :; do
    guard=$((guard + 1))
    [ "$guard" -le 64 ] || return 1
    [ -f "$m" ] || return 1
    id=$(rekick_hdr "$m" 'run-id')
    printf '%s' "$id" | grep -Eq "$REKICK_ID_RE" || return 1
    led="$(dirname "$m")/$id.md"
    if [ -f "$led" ]; then
      ( LEDGER="$led"; RUN_ID="$id"; gate_chain_verify "$led" "$id" ) >/dev/null 2>&1 || return 1
      tok=$(rekick_end_token "$led" || true)
      fp=$(rekick_fingerprint "$led" || true)
      if [ -n "$(rekick_progress_rows "$led")" ]; then prog=1; else prog=0; fi
    else
      if [ "$first" != "1" ] && [ "$next_cause" != "연기마감" ]; then return 1; fi
      led="-"; tok=""; fp=""; prog="-"
    fi
    out=$(printf '%s\t%s\t%s\t%s\t%s\t%s\n%s' "$id" "$m" "$led" "${tok:--}" "${fp:--}" "$prog" "$out")
    ch=$(rekick_chain_row "$m")
    [ -n "$ch" ] || break
    prev=$(rekick_row_field "$ch" '선행 런')
    next_cause=$(rekick_row_field "$ch" '원인')
    printf '%s' "$prev" | grep -Eq "$REKICK_ID_RE" || return 1
    m="$(dirname "$m")/$prev.plan.md"
    first=0
  done
  printf '%s\n' "$out" | grep -v '^$'
}

rekick_started_links() {
  # Links that ran, root first — a never-started link counts for nothing.
  awk -F '\t' '$3 != "-"'
}

rekick_progress() {
  # rekick_progress <predecessor manifest> — true when the predecessor link
  # progressed. A walk that fails answers "no progress", the stopping side.
  local links last
  links=$(rekick_chain_links "$1") || return 1
  last=$(printf '%s\n' "$links" | tail -1)
  [ "$(printf '%s' "$last" | cut -f6)" = "1" ]
}

rekick_same_cause_stop() {
  # rekick_same_cause_stop <predecessor manifest> — true (stop) when the
  # predecessor and the link that ran before it both ended on `무진전`.
  local links two
  links=$(rekick_chain_links "$1") || return 0
  two=$(printf '%s\n' "$links" | rekick_started_links | tail -2 | cut -f4)
  [ "$(printf '%s\n' "$two" | grep -c '^무진전$')" -ge 2 ]
}

rekick_stop_reason() {
  # rekick_stop_reason <predecessor manifest> <end token> — prints why the chain
  # stops here and returns 0, or returns 1 when nothing stops it. One reading
  # for the verdict and for the admission check, so the run a sweep opened is
  # admitted on the same predicates that opened it.
  local m="$1" tok="$2"
  rekick_chain_links "$m" >/dev/null || { printf '연쇄의 원장 사슬 검증 실패'; return 0; }
  case "$tok" in
    천장|무진전|사이클예산)
      rekick_progress "$m" || { printf '진전 없이 끝난 고리'; return 0; } ;;
  esac
  if [ "$tok" = "무진전" ] && rekick_same_cause_stop "$m"; then
    printf '무진전이 연달아 두 번'; return 0
  fi
  if [ "$tok" = "결함" ] && rekick_fingerprint_stop "$m"; then
    printf '같은 지문의 결함이 연쇄 안에서 두 번째'; return 0
  fi
  return 1
}

rekick_fingerprint_stop() {
  # rekick_fingerprint_stop <predecessor manifest> — true (stop) when the
  # predecessor's `결함` carries a fingerprint an earlier link of the chain
  # already ended on, or carries none: a defect that cannot be told apart from
  # the last one is treated as the same one.
  local links last fp
  links=$(rekick_chain_links "$1") || return 0
  last=$(printf '%s\n' "$links" | tail -1)
  fp=$(printf '%s' "$last" | cut -f5)
  [ -n "$fp" ] && [ "$fp" != "-" ] || return 0
  printf '%s\n' "$links" | sed '$d' | rekick_started_links \
    | awk -F '\t' -v fp="$fp" '$4 == "결함" && $5 == fp { hit = 1 } END { exit hit ? 0 : 1 }'
}

# ---------------------------------------------------------------------------
# The successor id and the chain position.
# ---------------------------------------------------------------------------

rekick_successor_id() {
  # rekick_successor_id <재킥오프 시각 ISO Z> <선행 런> <순번> —
  # `<UTC YYYYMMDD>-<first 8 hex of sha256("rekick|<선행 런>|<순번>")>`. The same
  # predecessor and position always give the same id, so a retried sweep cannot
  # mint a second successor.
  local at="${1:-}" pred="${2:-}" seq="${3:-}" day h
  printf '%s' "$at" | grep -Eq "$REKICK_ISO_Z_RE" || return 1
  case "$seq" in ''|*[!0-9]*|0*) return 1 ;; esac
  [ -n "$pred" ] || return 1
  day=$(printf '%s' "${at%%T*}" | tr -d '-')
  h=$(printf 'rekick|%s|%s' "$pred" "$seq" | shasum -a 256 | cut -c1-8)
  printf '%s-%s' "$day" "$h"
}

rekick_position() {
  # rekick_position <predecessor manifest> — `<root>\t<next 순번>\t<연쇄 상한>`.
  local m="$1" id ch root seq rk cap
  id=$(rekick_hdr "$m" 'run-id')
  rk=$(rekick_consent_row "$m")
  [ -n "$rk" ] || return 1
  cap=$(rekick_row_field "$rk" '연쇄 상한')
  ch=$(rekick_chain_row "$m")
  if [ -n "$ch" ]; then
    root=$(rekick_row_field "$ch" '뿌리 런')
    seq=$(( $(rekick_row_field "$ch" '순번') + 1 ))
  else
    root="$id"; seq=1
  fi
  printf '%s\t%s\t%s\n' "$root" "$seq" "$cap"
}

# ---------------------------------------------------------------------------
# Root provenance: the chain starts only from a manifest that ran under the
# gate, or from a record the dispatcher parked for having missed its deadline.
# ---------------------------------------------------------------------------

rekick_root_provenance() {
  # rekick_root_provenance <predecessor manifest> — prints the reason and
  # returns 1 when the root does not qualify.
  local m="$1" root dir kick last led bl
  root=$(rekick_position "$m" | cut -f1)
  dir=$(dirname "$m")
  [ -f "$dir/$root.plan.md" ] || { printf '뿌리 런 매니페스트 없음: %s' "$root"; return 1; }
  kick="$dir/$root.kickoff.md"
  [ -f "$kick" ] || { printf '뿌리 런 킥오프 기록 없음: %s' "$root"; return 1; }
  last=$(grep -E '^- [^|]+ \| 단계=' "$kick" | tail -1 | sed -E 's/^- [^|]+ \| 단계=//; s/ \|.*$//')
  case "$last" in
    '매니페스트 기록'|'기동 직전'|'연기') ;;
    *) printf '뿌리 런 킥오프 기록의 마지막 단계가 「%s」 입니다' "$last"; return 1 ;;
  esac
  led="$dir/$root.md"
  if [ -f "$led" ]; then
    grep -E '^- `run` \| ' "$led" | grep -F " | run-id=$root | " | grep -qF ' | 구속면 다이제스트=' \
      || { printf '뿌리 런 원장에 게이트가 쓴 run 행이 없습니다'; return 1; }
    return 0
  fi
  [ "$last" = "연기" ] || { printf '뿌리 런 원장 없음: %s' "$root"; return 1; }
  bl="$(run_pace_root)/backlog.jsonl"
  jq -e -s --arg mp "$dir/$root.plan.md" \
      'map(select(.manifest_path == $mp and .park_reason == "deadline-passed")) | length > 0' \
      "$bl" >/dev/null 2>&1 \
    || { printf '시작하지 않은 뿌리 런을 deadline-passed 로 park 한 백로그 레코드가 없습니다'; return 1; }
}

# ---------------------------------------------------------------------------
# The verdict.
# ---------------------------------------------------------------------------

rekick_integer_terminal_cap() {
  # True when any target of the manifest carries an integer `말단 행위 상한`.
  # Nothing on a successor's path reads that field, so a successor could not
  # keep the cap; such a root does not chain until a reader exists.
  local m="$1" a v
  for a in $(rekick_in "$m" target_aliases); do
    v=$(rekick_in "$m" target_field "$a" '말단 행위 상한')
    case "$v" in ''|*[!0-9]*) ;; *) return 0 ;; esac
  done
  return 1
}

rekick_grant_ok() {
  # rekick_grant_ok <manifest> — the gate's own check of the authorization
  # record, run as that manifest's: absent, foreign or malformed all fail.
  local m="$1" p
  p=$(rekick_paths "$m") || return 1
  (
    MANIFEST="$m"; MANIFEST_MEMO_PATH=""; MANIFEST_MEMO=""
    RUN_ID=$(manifest_hdr_field 'run-id')
    ANCHOR_KEY=$(manifest_hdr_field 'anchor-key')
    GRANT=$(printf '%s' "$p" | cut -f2)
    gate_check_grant
  ) >/dev/null 2>&1
}

rekick_surface_verdict() {
  # rekick_surface_verdict <predecessor manifest> <ledger> — `<판정>\t<사유>`
  # for a run that ended on `표면이동`. The per-file list beside the aggregate
  # digest says what moved; the base branch tip says whether a moved target
  # setting is history or an edit nobody committed.
  local m="$1" led="$2" rd list kind rest sha path cur moved="" root alias base start
  local wt tip ids seg c chain_touch=0 aliases
  rd=$(grep -E '^- `run` \| ' "$led" | head -1 | tr '|' '\n' | sed -n 's/^ *RUN_DIR=//p' | sed 's/[[:space:]]*$//')
  list="$rd/surface-digest.files"
  [ -n "$rd" ] && [ -f "$list" ] || { printf '사람\t파일별 표면 목록이 없어 무엇이 움직였는지 가를 수 없습니다'; return 0; }
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    kind=${line%%"$REKICK_TAB"*}; rest=${line#*"$REKICK_TAB"}
    sha=${rest%%  *}; path=${rest#*  }
    if [ -f "$path" ]; then cur=$(shasum -a 256 "$path" | cut -d' ' -f1); else cur="(없음)"; fi
    [ "$cur" = "$sha" ] && continue
    case "$kind" in
      런설정) ;;
      대상설정) moved="$moved$path
" ;;
      *) printf '사람\t표면 목록의 부류를 읽지 못했습니다: %s' "$kind"; return 0 ;;
    esac
  done < "$list"
  [ -n "$moved" ] || { printf '자동\t런 설정만 움직였습니다'; return 0; }
  start=$(grep -E '^- `run` \| ' "$led" | head -1 | tr '|' '\n' | sed -n 's/^ *시작=//p' | sed 's/[[:space:]]*$//')
  ids=$(rekick_chain_links "$m" | cut -f1) || { printf '사람\t연쇄 원장 검증 실패'; return 0; }
  aliases=$(rekick_in "$m" target_aliases)
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    root=${path%/.claude/settings.json}
    [ "$root" != "$path" ] || { printf '사람\t대상 설정 경로가 아닙니다: %s' "$path"; return 0; }
    base=""
    for alias in $aliases; do
      wt=$(rekick_in "$m" target_field "$alias" '메인 워크트리')
      [ "$wt" = "$root" ] && base=$(rekick_in "$m" target_field "$alias" '베이스 브랜치')
    done
    [ -n "$base" ] || { printf '사람\t움직인 설정 파일의 대상을 찾지 못했습니다: %s' "$path"; return 0; }
    if [ -n "$( { cd "$root" && git --no-optional-locks status --porcelain -- .claude/settings.json; } 2>/dev/null)" ]; then
      printf '진행\t커밋 대기 — 이력에 없는 설정 변경: %s — 커밋하거나 되돌리세요' "$path"; return 0
    fi
    tip=$( { cd "$root" && git show "$base:.claude/settings.json"; } 2>/dev/null | shasum -a 256 | cut -d' ' -f1)
    [ "$tip" = "$(shasum -a 256 "$path" 2>/dev/null | cut -d' ' -f1)" ] \
      || { printf '사람\t설정 파일이 베이스 브랜치 %s 끝과 다릅니다: %s' "$base" "$path"; return 0; }
    for c in $( { cd "$root" && git log --format=%H ${start:+--since="$start"} "$base" -- .claude/settings.json; } 2>/dev/null); do
      for seg in $ids; do
        if [ -n "$( { cd "$root" && git branch --list "seg/$seg-*" --contains "$c"; } 2>/dev/null)" ] \
           || { cd "$root" && git log -1 --format=%B "$c"; } 2>/dev/null | grep -qF "seg/$seg-"; then
          chain_touch=1
        fi
      done
    done
  done <<EOF
$moved
EOF
  if [ "$chain_touch" = "1" ]; then
    printf '승인\t연쇄 자신의 머지가 대상 설정을 바꿨습니다 — 변경분 없이 받아들임만'
  else
    printf '자동\t대상 설정이 베이스 브랜치 끝과 같고 연쇄의 머지가 건드리지 않았습니다'
  fi
}

cc_rekick_verdict() {
  # cc_rekick_verdict <predecessor manifest> [--lane present|absent]
  #                   [--pin usable|unusable|none]
  # → `<판정>\t<원인>\t<사유>`. The order of the checks is the contract; see
  # the numbered comments. Inputs only a sweep knows — the lane and the plugin
  # pin — arrive as arguments, and one that did not arrive sends the run to a
  # person rather than being assumed.
  local m="${1:-}" lane="" pin="" led tok park p doc pos seq cap sv
  shift || true
  while [ $# -gt 0 ]; do
    case "$1" in
      --lane) lane="${2:-}"; shift 2 ;;
      --pin)  pin="${2:-}"; shift 2 ;;
      *) printf '사람\t-\t알 수 없는 인자: %s\n' "$1"; return 0 ;;
    esac
  done
  out() { printf '%s\t%s\t%s\n' "$1" "$2" "$3"; }

  [ -f "$m" ] || { out 사람 - "매니페스트가 없습니다: $m"; return 0; }
  m="$(cd "$(dirname "$m")" && pwd)/$(basename "$m")"
  # 1. No consent row: not a candidate at all.
  [ -n "$(rekick_consent_row "$m")" ] || { out 없음 - "재킥오프 행이 없는 매니페스트"; return 0; }
  # 2. The authorization record and the design document.
  rekick_grant_ok "$m" || { out 사람 - "새 인가 필요 — 인가 기록이 없거나 이 런의 것이 아닙니다"; return 0; }
  p=$(rekick_paths "$m") || { out 사람 - "새 인가 필요 — 경로를 유도하지 못했습니다"; return 0; }
  doc=$(printf '%s' "$p" | cut -f4)
  doc_is_frozen "$doc" || { out 사람 - "새 인가 필요 — 설계 문서가 동결되지 않았습니다"; return 0; }
  # 3. An integer terminal-act cap anywhere, before any cause.
  rekick_integer_terminal_cap "$m" && { out 사람 - "새 인가 필요 — 정수 말단 행위 상한을 가진 뿌리"; return 0; }

  led=$(rekick_ledger_of "$m")
  if [ ! -f "$led" ]; then
    # A link that never started: only a record parked for its deadline counts.
    if [ -f "$(run_pace_root)/backlog.jsonl" ] && jq -e -s --arg mp "$m" \
         'map(select(.manifest_path == $mp and .park_reason == "deadline-passed")) | length > 0' \
         "$(run_pace_root)/backlog.jsonl" >/dev/null 2>&1; then
      tok="연기마감"
    else
      out 진행 - "원장이 없고 마감으로 park 된 레코드도 없습니다"; return 0
    fi
  else
    # 4. No end token: the run has not ended.
    tok=$(rekick_end_token "$led") || { out 진행 - "종료 토큰 없음"; return 0; }
    # 5. A normal completion.
    rekick_completed "$led" && { out 없음 - "정상 완료"; return 0; }
    park=$(rekick_park_causes "$led")
    # 6. An unclassified stop goes to a person, park rows and all.
    if [ "$tok" = "해당없음" ]; then
      out 사람 해당없음 "분류 없이 멈춘 런${park:+ — park 행 변경분: $(printf '%s' "$park" | tr '\n' ' ')}"
      return 0
    fi
  fi
  # The lane and the pin, known only to the sweep.
  [ "$lane" = "present" ] || { out 사람 "$tok" "레인이 없는 호스트이거나 레인을 알지 못합니다"; return 0; }
  case "$pin" in
    usable|none) ;;
    *) out 사람 "$tok" "쓸 수 없는 플러그인 핀이거나 핀을 알지 못합니다"; return 0 ;;
  esac
  # 7. A park row comes before the token that ended the run.
  if [ -n "${park:-}" ]; then
    out 승인 "$(printf '%s\n' "$park" | head -1)" "park 행의 변경분을 담은 재인가 승인: $(printf '%s' "$park" | tr '\n' ' ')"
    return 0
  fi
  # 8. The chain cap and the stop predicates.
  pos=$(rekick_position "$m") || { out 사람 "$tok" "재킥오프 행을 읽지 못했습니다"; return 0; }
  seq=$(printf '%s' "$pos" | cut -f2); cap=$(printf '%s' "$pos" | cut -f3)
  [ "$seq" -le "$cap" ] || { out 상한 "$tok" "연쇄 상한 $cap 에 닿았습니다"; return 0; }
  sv=$(rekick_stop_reason "$m" "$tok") && { out 상한 "$tok" "$sv"; return 0; }
  # 9. Per token.
  case "$tok" in
    마감|연기마감|천장|무진전|사이클예산|결함) out 자동 "$tok" "자동 재킥 — $tok" ;;
    판단정지) out 승인 "$tok" "판단 정지의 답변을 담은 재인가 승인" ;;
    말단상한) out 사람 "$tok" "새 인가 필요 — 말단 행위 상한 소진" ;;
    표면이동)
      sv=$(rekick_surface_verdict "$m" "$led")
      out "${sv%%"$REKICK_TAB"*}" "$tok" "${sv#*"$REKICK_TAB"}" ;;
    *) out 사람 "$tok" "알 수 없는 종료 토큰" ;;
  esac
}

rekick_cause_of() {
  # rekick_cause_of <predecessor manifest> <판정> — the `원인` a successor's
  # `연쇄` row carries: a park token for an approval behind park rows, the
  # deadline park for a link that never started, the end token otherwise.
  local m="$1" v="$2" led park
  led=$(rekick_ledger_of "$m")
  if [ ! -f "$led" ]; then printf '연기마감'; return 0; fi
  if [ "$v" = "승인" ]; then
    park=$(rekick_park_causes "$led" | head -1)
    [ -n "$park" ] && { printf '%s' "$park"; return 0; }
  fi
  rekick_end_token "$led"
}

rekick_chain_doc_sha() {
  # The recorded document digest, from the nearest link that ran; a chain none
  # of whose links ran falls back to the root manifest's own recorded field.
  local m="$1" links led sha root
  links=$(rekick_chain_links "$m") || return 1
  for led in $(printf '%s\n' "$links" | awk -F '\t' '$3 != "-" { print $3 }' | awk '{ a[NR] = $0 } END { for (i = NR; i >= 1; i--) print a[i] }'); do
    sha=$(rekick_recorded_doc_sha "$led") || return 1
    printf '%s' "$sha"; return 0
  done
  root=$(printf '%s\n' "$links" | head -1 | cut -f2)
  sha=$(rekick_field "$root" '요소' '설계 문서 전체 sha256')
  printf '%s' "$sha" | grep -Eq "$REKICK_HEX_RE" || return 1
  printf '%s' "$sha"
}

# ---------------------------------------------------------------------------
# The deriver.
# ---------------------------------------------------------------------------

rekick_put() {
  # rekick_put <path> <content file> — create-only. An existing file with the
  # same bytes is a resumed derivation and passes; different bytes are refused.
  local dst="$1" src="$2" tmp
  if [ -e "$dst" ]; then
    cmp -s "$dst" "$src" && return 0
    return 1
  fi
  tmp="$(dirname "$dst")/.$(basename "$dst").rekick.$$"
  cp "$src" "$tmp" || { rm -f "$tmp"; return 1; }
  if ! ln "$tmp" "$dst" 2>/dev/null; then
    rm -f "$tmp"
    cmp -s "$dst" "$src"; return $?
  fi
  rm -f "$tmp"
}

rekick_offset_of() {
  # The offset notation of an absolute time: `Z` or `±HH:MM`.
  case "$1" in
    *Z) printf 'Z' ;;
    *) printf '%s' "$1" | grep -oE '[+-][0-9]{2}:[0-9]{2}$' ;;
  esac
}

rekick_deadline() {
  # rekick_deadline <재킥오프 시각> <길이> <notation> — the successor deadline in
  # the predecessor's notation, by the kickoff's own arithmetic.
  local at="$1" len="$2" note="$3" out
  if [ "$note" = "Z" ]; then
    out=$(dr_add_duration "$at" "$len" '+00:00') || return 1
    printf '%sZ' "${out%+00:00}"
  else
    dr_add_duration "$at" "$len" "$note"
  fi
}

rekick_manifest_bytes() {
  # rekick_manifest_bytes <predecessor manifest> <선행 런> <후속 런> <킥오프 일시>
  #                       <벽시계 마감> <연쇄 행> <구속 다이제스트> — the successor
  # manifest on stdout: the predecessor's bytes with exactly the allowed changes
  # — the run id in its three places, the kickoff time, the deadline, the chain
  # row (replaced, or put right after the consent row on the first link) and
  # the binding digest. The deriver writes these bytes and the admission check
  # compares a successor against them, so "identical but for the allowed
  # changes" has one definition. Read twice: the first pass only learns whether
  # a chain row is already there.
  awk -v old="$2" -v new="$3" -v at="$4" -v dl="$5" -v ch="$6" -v bd="$7" '
    NR == FNR { if (index($0, "- `연쇄` | ") == 1) had = 1; next }
    FNR == 1 { if ($0 == "# 파이프라인 런 매니페스트 — " old) { print "# 파이프라인 런 매니페스트 — " new; next } }
    FNR == 2 { s = $0; k = "run-id=" old ";"; i = index(s, k)
               if (i > 0) s = substr(s, 1, i - 1) "run-id=" new ";" substr(s, i + length(k))
               print s; next }
    /^## / { sec = $0 }
    sec == "## 런 정체" && /^\*\*킥오프 일시\*\*: / { print "**킥오프 일시**: " at; next }
    sec == "## 런 정체" && $0 == "**런 id**: " old { print "**런 id**: " new; next }
    sec == "## 인가" && /^\*\*벽시계 마감\*\*: / { print "**벽시계 마감**: " dl; next }
    sec == "## 인가" && /^\*\*구속 다이제스트\*\*: / { print "**구속 다이제스트**: " bd; next }
    index($0, "- `연쇄` | ") == 1 { print ch; next }
    { print }
    !had && index($0, "- `재킥오프` | ") == 1 { print ch }
  ' "$1" "$1"
}

rekick_grant_bytes() {
  # rekick_grant_bytes <predecessor grant> <선행 런> <후속 런> <뿌리 런> — the
  # successor authorization record on stdout: the predecessor's block renamed,
  # its report path moved to the successor's ledger, and the derivation stated
  # in the header (`writer=rekick; derived-from=…; root=…`). Nothing else.
  awk -v old="$2" -v new="$3" -v root="$4" '
    NR == 1 { if ($0 == "# 파이프라인 인가 기록 — " old) { print "# 파이프라인 인가 기록 — " new; next } }
    NR == 2 { s = $0
              gsub(/ derived-from=[^;]*;/, "", s); gsub(/ root=[^;]*;/, "", s)
              sub(/writer=[^;]*;/, "writer=rekick; derived-from=" old "; root=" root ";", s)
              print s; next }
    $0 == "## 인가 " old { print "## 인가 " new; next }
    /^\*\*보고서\*\*: / { s = $0; k = "/" old ".md"
                          if (substr(s, length(s) - length(k) + 1) == k) s = substr(s, 1, length(s) - length(k)) "/" new ".md"
                          print s; next }
    { print }
  ' "$1"
}

rekick_derive() {
  local pred="" claim="" verdict="" appr="" adig=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --predecessor)   pred="${2:-}"; shift 2 ;;
      --claim)         claim="${2:-}"; shift 2 ;;
      --verdict)       verdict="${2:-}"; shift 2 ;;
      --approval)      appr="${2:-}"; shift 2 ;;
      --answer-digest) adig="${2:-}"; shift 2 ;;
      *) printf 'invalid\t알 수 없는 인자: %s\n' "$1"; return 3 ;;
    esac
  done
  inval() { printf 'invalid\t%s\n' "$1"; return 3; }
  human() { printf '사람\t%s\n' "$1"; return 4; }

  [ -f "$pred" ] || { inval "앞 런 매니페스트가 없습니다: $pred"; return 3; }
  [ -d "$claim" ] || { inval "클레임 디렉터리가 없습니다: $claim"; return 3; }
  case "$verdict" in
    자동) [ -z "$appr$adig" ] || { inval "자동 판정에는 승인 인자가 없습니다"; return 3; } ;;
    승인) printf '%s' "$appr" | grep -Eq '^[0-9]{8}-[0-9a-f]{8}#[^ |]+$' \
            && printf '%s' "$adig" | grep -Eq "$REKICK_HEX_RE" \
            || { inval "승인 판정에는 --approval <런>#<승인 id> 와 --answer-digest <64자리 hex> 가 필요합니다"; return 3; } ;;
    *) inval "파생하는 판정은 자동과 승인뿐입니다: $verdict"; return 3 ;;
  esac

  local dir pid at pos root seq cap rk len cause nid bd_stored bd_now dl_old note dl_new
  local chain_row p grant ngrant nman nkick docsha work
  dir=$(cd "$(dirname "$pred")" && pwd)
  pred="$dir/$(basename "$pred")"
  pid=$(rekick_hdr "$pred" 'run-id')
  printf '%s' "$pid" | grep -Eq "$REKICK_ID_RE" || { inval "앞 런 id 를 읽지 못했습니다"; return 3; }
  at=$(tr -d '\n' < "$claim/at" 2>/dev/null)
  printf '%s' "$at" | grep -Eq "$REKICK_ISO_Z_RE" || { inval "클레임 at 이 ISO Z 시각이 아닙니다"; return 3; }
  rk=$(rekick_consent_row "$pred")
  [ -n "$rk" ] || { inval "재킥오프 행이 없는 매니페스트"; return 3; }
  pos=$(rekick_position "$pred") || { inval "연쇄 위치를 읽지 못했습니다"; return 3; }
  root=$(printf '%s' "$pos" | cut -f1); seq=$(printf '%s' "$pos" | cut -f2); cap=$(printf '%s' "$pos" | cut -f3)
  [ "$seq" -le "$cap" ] || { inval "연쇄 상한 $cap 을 넘는 순번 $seq"; return 3; }
  len=$(rekick_row_field "$rk" '길이')

  local why
  why=$(rekick_root_provenance "$pred") || { human "뿌리 출처 확인 실패 — $why"; return 4; }
  docsha=$(rekick_chain_doc_sha "$pred") || { human "기록된 문서 해시 없음"; return 4; }

  cause=$(rekick_cause_of "$pred" "$verdict") || { inval "앞 런의 원인을 읽지 못했습니다"; return 3; }
  ( gate_rekick_cause_ok "$cause" ) || { inval "원인이 닫힌 토큰이 아닙니다: $cause"; return 3; }
  nid=$(rekick_successor_id "$at" "$pid" "$seq") || { inval "후속 런 id 를 계산하지 못했습니다"; return 3; }

  bd_stored=$(rekick_field "$pred" '인가' '구속 다이제스트')
  bd_now=$(rekick_binding_digest "$pred")
  [ -n "$bd_stored" ] && [ "$bd_stored" = "$bd_now" ] \
    || { inval "앞 런 매니페스트의 구속 다이제스트가 그 바이트와 맞지 않습니다"; return 3; }
  dl_old=$(rekick_field "$pred" '인가' '벽시계 마감')
  note=$(rekick_offset_of "$dl_old")
  [ -n "$note" ] || { inval "앞 런 벽시계 마감의 오프셋을 읽지 못했습니다: $dl_old"; return 3; }
  dl_new=$(rekick_deadline "$at" "$len" "$note") || { inval "후속 마감을 계산하지 못했습니다"; return 3; }

  chain_row="- \`연쇄\` | 뿌리 런=$root | 선행 런=$pid | 순번=$seq | 선행 구속 다이제스트=$bd_stored | 재킥오프 시각=$at | 원인=$cause"
  [ "$verdict" = "승인" ] && chain_row="$chain_row | 재인가 승인=$appr | 답변 다이제스트=$adig"

  p=$(rekick_paths "$pred") || { inval "앞 런 경로를 유도하지 못했습니다"; return 3; }
  grant=$(printf '%s' "$p" | cut -f2)
  [ -f "$grant" ] && grep -qxF "## 인가 $pid" "$grant" || { human "새 인가 필요 — 앞 런 인가 블록이 없습니다"; return 4; }
  ngrant="$(dirname "$grant")/$nid.md"
  nman="$dir/$nid.plan.md"
  nkick="$dir/$nid.kickoff.md"

  work=$(mktemp -d "${TMPDIR:-/tmp}/cc-rekick.XXXXXX") || { inval "임시 디렉터리를 만들지 못했습니다"; return 3; }

  # The manifest: the predecessor's bytes with exactly the allowed changes, the
  # binding digest a placeholder until the bytes it covers exist.
  rekick_manifest_bytes "$pred" "$pid" "$nid" "$at" "$dl_new" "$chain_row" '@@BINDING@@' > "$work/m1" \
    || { rm -rf "$work"; inval "매니페스트 변환 실패"; return 3; }
  grep -c '@@BINDING@@' "$work/m1" | grep -qx 1 || { rm -rf "$work"; inval "구속 다이제스트 줄이 하나가 아닙니다"; return 3; }
  local bd_new
  bd_new=$(rekick_binding_digest "$work/m1")
  awk -v d="$bd_new" '{ sub(/@@BINDING@@/, d); print }' "$work/m1" > "$work/manifest"

  rekick_grant_bytes "$grant" "$pid" "$nid" "$root" > "$work/grant" \
    || { rm -rf "$work"; inval "인가 기록 변환 실패"; return 3; }

  {
    printf '<!-- cc-run-kickoff v1; writer=rekick; reader=autopilot (kickoff resume, next kickoff Step 2, --report); run-id=%s; derived-from=%s; root=%s; NOT a design doc; mechanism-local, never staged by a skill -->\n' "$nid" "$pid" "$root"
    printf -- '- %s | 단계=매니페스트 기록\n' "$at"
    printf -- '- %s | 단계=연기\n' "$at"
  } > "$work/kickoff"

  rekick_put "$nman" "$work/manifest" || { rm -rf "$work"; inval "다른 바이트의 매니페스트가 이미 있습니다: $nman"; return 3; }
  rekick_put "$ngrant" "$work/grant" || { rm -rf "$work"; inval "다른 바이트의 인가 기록이 이미 있습니다: $ngrant"; return 3; }
  rekick_put "$nkick" "$work/kickoff" || { rm -rf "$work"; inval "다른 바이트의 킥오프 기록이 이미 있습니다: $nkick"; return 3; }
  rm -rf "$work"
  printf '열림\t%s\t%s\t%s\n' "$nid" "$nman" "$docsha"
}

# ---------------------------------------------------------------------------
# Admission: what `check_manifest` asks of a manifest that carries a `연쇄` row.
# Each check prints its reason and returns 1 on the first mismatch; the caller
# turns that into a `lineage-invalid` stop.
# ---------------------------------------------------------------------------

rekick_admission_static() {
  # rekick_admission_static <manifest> — the checks that read only manifests and
  # authorization records, cheap enough for every gate entry.
  local m="$1" dir id rk ch n_rk n_ch pid root seq at ch_pd pm pd_stored pd_now
  local pch exp_root exp_seq cap len dl at_e dur dl_e kick bd pp sp pg sg
  dir=$(cd "$(dirname "$m")" && pwd) || { printf '매니페스트 디렉터리를 읽지 못했습니다'; return 1; }
  m="$dir/$(basename "$m")"
  id=$(rekick_hdr "$m" 'run-id')

  # (가) exactly one consent row and one chain row.
  n_rk=$(rekick_in "$m" manifest_rekick_rows | grep -c . || true)
  n_ch=$(rekick_in "$m" manifest_chain_rows | grep -c . || true)
  if [ "$n_rk" != "1" ] || [ "$n_ch" != "1" ]; then
    printf '(가) 재킥오프 행 %s개 · 연쇄 행 %s개 — 정확히 하나씩이어야 합니다' "$n_rk" "$n_ch"; return 1
  fi
  rk=$(rekick_consent_row "$m"); ch=$(rekick_chain_row "$m")
  pid=$(rekick_row_field "$ch" '선행 런'); root=$(rekick_row_field "$ch" '뿌리 런')
  seq=$(rekick_row_field "$ch" '순번'); at=$(rekick_row_field "$ch" '재킥오프 시각')
  ch_pd=$(rekick_row_field "$ch" '선행 구속 다이제스트')

  # (나) the predecessor's digest RECOMPUTED from its bytes, against both the
  # value it stores and the value this row carries. Comparing the two stored
  # fields alone passes a predecessor whose rows were rewritten after it ran
  # with the digest field left as it was — and (다) would then pass against the
  # rewritten bytes.
  pm="$dir/$pid.plan.md"
  [ -f "$pm" ] || { printf '(나) 앞 런 매니페스트가 없습니다: %s' "$pm"; return 1; }
  pd_stored=$(rekick_field "$pm" '인가' '구속 다이제스트')
  pd_now=$(rekick_binding_digest "$pm")
  if [ -z "$pd_stored" ] || [ "$pd_now" != "$pd_stored" ]; then
    printf '(나) 앞 런 매니페스트를 다시 계산한 구속 다이제스트가 그 매니페스트에 저장된 값과 다릅니다'; return 1
  fi
  [ "$pd_now" = "$ch_pd" ] \
    || { printf '(나) 연쇄 행의 선행 구속 다이제스트가 앞 런 매니페스트를 다시 계산한 값과 다릅니다'; return 1; }

  # (라) the position, the root and the ceiling.
  pch=$(rekick_chain_row "$pm")
  if [ -n "$pch" ]; then
    exp_root=$(rekick_row_field "$pch" '뿌리 런')
    exp_seq=$(( $(rekick_row_field "$pch" '순번') + 1 ))
  else
    exp_root="$pid"; exp_seq=1
  fi
  [ "$root" = "$exp_root" ] || { printf '(라) 뿌리 런이 %s 여야 합니다: %s' "$exp_root" "$root"; return 1; }
  [ "$seq" = "$exp_seq" ] || { printf '(라) 순번이 %s 여야 합니다: %s' "$exp_seq" "$seq"; return 1; }
  cap=$(rekick_row_field "$rk" '연쇄 상한')
  [ "$seq" -le "$cap" ] || { printf '(라) 순번 %s 이 연쇄 상한 %s 을 넘습니다' "$seq" "$cap"; return 1; }

  # (바) the id is the formula's.
  [ "$(rekick_successor_id "$at" "$pid" "$seq")" = "$id" ] \
    || { printf '(바) 런 id 가 재킥오프 시각·선행 런·순번으로 다시 계산한 값과 다릅니다'; return 1; }

  # (마) the deadline is the claim instant plus the length, compared as
  # instants: the row's time is ISO Z and the deadline keeps the root's offset.
  len=$(rekick_row_field "$rk" '길이')
  dl=$(rekick_field "$m" '인가' '벽시계 마감')
  at_e=$(dr_abs_epoch "$at") && dur=$(dr_duration_seconds "$len") && dl_e=$(dr_abs_epoch "$dl") \
    || { printf '(마) 재킥오프 시각·길이·벽시계 마감 중 하나를 읽지 못했습니다'; return 1; }
  [ "$dl_e" = "$((at_e + dur))" ] \
    || { printf '(마) 벽시계 마감 %s 이 재킥오프 시각 %s + 길이 %s 가 아닙니다' "$dl" "$at" "$len"; return 1; }

  # (다) identical but for the allowed changes: the predecessor run through the
  # deriver's own transform with this manifest's values for the fields that
  # may differ must give this manifest's bytes. The digest field is taken as
  # it stands; `check_manifest` has already compared it with these bytes.
  kick=$(rekick_field "$m" '런 정체' '킥오프 일시')
  bd=$(rekick_field "$m" '인가' '구속 다이제스트')
  rekick_manifest_bytes "$pm" "$pid" "$id" "$kick" "$dl" "$ch" "$bd" | cmp -s - "$m" \
    || { printf '(다) 매니페스트가 앞 런 매니페스트와 허용 변경분 밖에서 다릅니다'; return 1; }
  pp=$(rekick_paths "$pm") && sp=$(rekick_paths "$m") \
    || { printf '(다) 인가 기록 경로를 유도하지 못했습니다'; return 1; }
  pg=$(printf '%s' "$pp" | cut -f2); sg=$(printf '%s' "$sp" | cut -f2)
  [ -f "$pg" ] && [ -f "$sg" ] || { printf '(다) 앞 런 또는 이 런의 인가 기록이 없습니다'; return 1; }
  rekick_grant_bytes "$pg" "$pid" "$id" "$root" | cmp -s - "$sg" \
    || { printf '(다) 인가 기록이 앞 런 인가 기록과 writer=·derived-from=·root= 밖에서 다릅니다'; return 1; }
  return 0
}

rekick_admission_history() {
  # rekick_admission_history <manifest> — (사): the checks that read the
  # predecessor's ledger, the chain's ledgers, the sibling manifests and the
  # dispatcher's claim. Computed once per manifest digest; see the memo below.
  local m="$1" dir id ch pid cause at led pm tok f fch claim sv appr arun aid aled arow adig
  dir=$(cd "$(dirname "$m")" && pwd) || { printf '(사) 매니페스트 디렉터리를 읽지 못했습니다'; return 1; }
  m="$dir/$(basename "$m")"
  id=$(rekick_hdr "$m" 'run-id')
  ch=$(rekick_chain_row "$m")
  pid=$(rekick_row_field "$ch" '선행 런'); cause=$(rekick_row_field "$ch" '원인')
  at=$(rekick_row_field "$ch" '재킥오프 시각')
  pm="$dir/$pid.plan.md"; led="$dir/$pid.md"

  # The predecessor ended, and on the token this row names.
  if [ "$cause" = "연기마감" ]; then
    [ ! -f "$led" ] || { printf '(사) 원인이 연기마감인데 앞 런 원장이 있습니다 — 시작한 런입니다'; return 1; }
    jq -e -s --arg mp "$pm" \
        'map(select(.manifest_path == $mp and .park_reason == "deadline-passed")) | length > 0' \
        "$(run_pace_root)/backlog.jsonl" >/dev/null 2>&1 \
      || { printf '(사) 앞 런을 deadline-passed 로 park 한 백로그 레코드가 없습니다'; return 1; }
  else
    [ -f "$led" ] || { printf '(사) 앞 런 원장이 없습니다: %s' "$led"; return 1; }
    tok=$(rekick_end_token "$led") || { printf '(사) 앞 런의 종료 토큰이 없습니다 — 끝나지 않은 런'; return 1; }
    [ "$tok" != "해당없음" ] || { printf '(사) 앞 런이 분류 없이 멈췄습니다'; return 1; }
    case "$cause" in
      대상미선언|슬라이싱)
        rekick_park_causes "$led" | grep -qxF "$cause" \
          || { printf '(사) 원인 %s 의 park 행이 앞 런 원장에 없습니다' "$cause"; return 1; } ;;
      *)
        [ "$tok" = "$cause" ] || { printf '(사) 앞 런의 종료 토큰 %s 이 원인 %s 과 다릅니다' "$tok" "$cause"; return 1; } ;;
    esac
  fi

  # No other manifest names the same predecessor.
  for f in "$dir"/*.plan.md; do
    [ -f "$f" ] && [ "$f" != "$m" ] || continue
    grep -q '^- `연쇄` | ' "$f" 2>/dev/null || continue
    fch=$(rekick_chain_row "$f")
    [ "$(rekick_row_field "$fch" '선행 런')" != "$pid" ] \
      || { printf '(사) 같은 선행 런 %s 을 가진 다른 매니페스트가 있습니다: %s' "$pid" "$f"; return 1; }
  done

  # The dispatcher's claim names this run and this instant.
  claim="$(run_pace_root)/rekick/$pid"
  [ "$(tr -d '\n' < "$claim/successor" 2>/dev/null)" = "$id" ] \
    || { printf '(사) 클레임의 successor 가 이 런을 가리키지 않습니다: %s' "$claim"; return 1; }
  [ "$(tr -d '\n' < "$claim/at" 2>/dev/null)" = "$at" ] \
    || { printf '(사) 클레임의 at 이 재킥오프 시각과 다릅니다: %s' "$claim"; return 1; }

  # The stop predicates, on chain-verified ledgers, as the verdict reads them:
  # a park cause and a never-started link were decided before any of them.
  rekick_chain_links "$pm" >/dev/null || { printf '(사) 연쇄의 원장 사슬 검증 실패'; return 1; }
  case "$cause" in
    대상미선언|슬라이싱|연기마감) ;;
    *) if sv=$(rekick_stop_reason "$pm" "$cause"); then printf '(사) %s' "$sv"; return 1; fi ;;
  esac

  rekick_integer_terminal_cap "$m" \
    && { printf '(사) 정수 말단 행위 상한을 가진 대상이 있습니다'; return 1; }

  # An approval cause needs a person's close. An automatic close also leaves
  # `상태=승인`, so the state alone does not say a person answered.
  appr=$(rekick_row_field "$ch" '재인가 승인')
  if [ -z "$appr" ]; then
    case "$cause" in
      대상미선언|슬라이싱|판단정지)
        printf '(사) 원인 %s 은 재인가 승인이 있어야 합니다' "$cause"; return 1 ;;
      표면이동)
        sv=$(rekick_surface_verdict "$pm" "$led")
        [ "${sv%%"$REKICK_TAB"*}" = "자동" ] \
          || { printf '(사) 승인 없는 표면이동이 자동 조건을 채우지 않습니다 — %s' "${sv#*"$REKICK_TAB"}"; return 1; } ;;
    esac
    return 0
  fi
  arun=${appr%%#*}; aid=${appr#*#}
  aled="$dir/$arun.md"
  [ -f "$aled" ] || { printf '(사) 재인가 승인의 원장이 없습니다: %s' "$aled"; return 1; }
  ( LEDGER="$aled"; RUN_ID="$arun"; gate_chain_verify "$aled" "$arun" ) >/dev/null 2>&1 \
    || { printf '(사) 재인가 승인의 원장이 사슬 검증을 지나지 못합니다'; return 1; }
  arow=$(grep -E '^- `승인` \| ' "$aled" | awk -v a=" | 승인 id=$aid | " -v b=" | 승인 id=$appr | " \
           'index($0, a) || index($0, b) { r = $0 } END { print r }')
  [ -n "$arow" ] || { printf '(사) 재인가 승인 %s 의 행이 없습니다' "$appr"; return 1; }
  [ "$(rekick_row_field "$arow" '상태')" = "승인" ] \
    || { printf '(사) 재인가 승인 %s 이 승인으로 닫히지 않았습니다' "$appr"; return 1; }
  case "$(rekick_row_field "$arow" '응답 토큰')" in
    ''|-) printf '(사) 재인가 승인 %s 에 사람의 응답 토큰이 없습니다' "$appr"; return 1 ;;
  esac
  [ "$(rekick_row_field "$arow" '처분 사유')" != "자동 해소" ] \
    || { printf '(사) 재인가 승인 %s 은 자동 해소로 닫혔습니다' "$appr"; return 1; }
  adig=$(rekick_row_field "$ch" '답변 다이제스트')
  [ "$(rekick_row_field "$arow" '답변 다이제스트')" = "$adig" ] \
    || { printf '(사) 연쇄 행의 답변 다이제스트가 재인가 승인의 답변과 다릅니다'; return 1; }
}

# The memo of (사). `check_manifest` runs before the run directory may be
# written, so it only READS the memo; the caller that prepared the run
# directory writes it. The key is the manifest's own digest, so a manifest that
# changed is computed again.
rekick_memo_path() {
  local rd
  rd=$(rundir_of_run_id "$1") || return 1
  printf '%s/lineage-admitted' "$rd"
}

rekick_memo_hit() {
  # rekick_memo_hit <run id> <manifest sha256>
  local p
  p=$(rekick_memo_path "$1") || return 1
  [ -f "$p" ] && [ "$(head -1 "$p" 2>/dev/null)" = "$2" ]
}

rekick_memo_write() {
  # rekick_memo_write <run id> <manifest sha256> — after the run directory
  # exists. A failure is reported and costs only a recomputation next entry.
  local p tmp
  p=$(rekick_memo_path "$1") || return 1
  [ -d "$(dirname "$p")" ] || return 1
  tmp="$p.tmp.$$"
  printf '%s\n' "$2" > "$tmp" && mv -f "$tmp" "$p" || { rm -f "$tmp"; return 1; }
}

# ---------------------------------------------------------------------------
# Sourced: definitions only.
# ---------------------------------------------------------------------------
if [ "${BASH_SOURCE[0]}" != "$0" ] || [ "${CC_REKICK_SOURCE_ONLY:-0}" = "1" ]; then
  return 0 2>/dev/null || exit 0
fi

# The program. The gate's definitions, and through it the driver's: the
# manifest readers, `binding_set_bytes`, the end-token reader and the chain
# verifier are reused, never re-implemented. The guard variable keeps the
# driver's own source of this file from re-entering the program below. A shell
# that sourced this file returned above, so this line runs only in rekick.sh's
# own process.
CC_REKICK_SOURCE_ONLY=1
CC_GATE_SOURCE_ONLY=1
# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/gate.sh" # lint-harness-global-collisions: child-shell
set +e

case "${1:-}" in
  verdict) shift; cc_rekick_verdict "$@" ;;
  id)      shift; nid=$(rekick_successor_id "$@") || { printf 'rekick.sh: id 인자가 맞지 않습니다\n' >&2; exit 2; }; printf '%s\n' "$nid" ;;
  derive)  shift; rekick_derive "$@"; exit $? ;;
  *) printf 'rekick.sh: 하위 명령은 verdict · id · derive 입니다\n' >&2; exit 2 ;;
esac
