#!/usr/bin/env bash
# lint-approval-state-vocabulary: self-skip
# Lint the approval-state vocabulary against its single source of truth.
#
# `승인.상태` is what every reader of the `승인` series takes as current — the
# last row's value, compared against literals — so a value outside the closed
# set is not a row that says something odd, it is an approval no reader can see
# as open, closed, or anything. `CUTPOINTS` and `판단 부류` each have a lint
# holding the tree to their SOT; this vocabulary had none, so a new state could
# arrive in one writer and be invisible to every reader.
#
# Rules:
#   1  `APPROVAL_STATES` in gate.sh has exactly six tokens and `철회` is one
#      of them                                                          [fail]
#   2  every literal `상태=<값>` written in an approval-row context under
#      `plugins/` and `scripts/` names one of the six                    [fail]
#   3  the contract's `승인.상태` vocabulary row equals the SOT set, as a
#      set, in both directions                                           [fail]
#
# Rule 1 pins the count at six ON PURPOSE. `기각` is written by nothing and
# stays: the contract table is the authority and it does not drop a value for
# being unobserved. `철회` is ACCEPTED here and REQUIRED nowhere — the
# transition into it lands with the boundary predicates, and the vocabulary
# admits the token ahead of its writer so that writer finds a token instead of
# improvising one. A set of five is a vocabulary that lost a state; a set of
# seven is a state that arrived without this file being told.
#
# What is an approval-row context: a line that also carries the approval id key
# (`승인 id=`). `상태=` is shared with `segment`, `종료 절`, `리뷰 의무` and
# others, and every `승인` row — a ledger literal, a `gate_append '승인' …` call
# — carries `승인 id=` on the same line. The shapes that are not value claims
# follow the sibling vocabulary lint: a shell expansion (`상태=$label`), a
# printf slot (`상태=%s`), a schema placeholder (`상태=<…>`), a parser pattern
# (`s/^ *상태=//p`) and the ledger's "no value" sentinel (`상태=-`). A value ends
# at a terminator — a quote, a backtick, a `|`, a `)` — and the field is
# compared whole.
#
# Residual, stated rather than hidden: a file carrying the `self-skip` marker in
# its first five lines is not scanned, and `scripts/test-gate.sh` carries one
# because asserting that an out-of-vocabulary state is REFUSED requires writing
# one down.
#
# Usage:
#   bash scripts/lint-approval-state-vocabulary.sh
#
# Env overrides (fixture runner):
#   ORCH_ROOT=<dir>    # directory holding gate.sh (the vocabulary's SOT)
#   SCAN_ROOT=<dir>    # tree to scan for `상태=` literals (plugins/, scripts/)
#   SKILLS_ROOT=<dir>  # directory holding _common/pipeline-sidecar.md
#
# Posture: if gate.sh is absent the whole check is a silent skip.
#
# Exit codes:
#   0 — pass (or skipped)
#   1 — at least one violation
#
# Compatibility: bash 3.2 (macOS) — no associative arrays, no `mapfile`.

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
orch_root="${ORCH_ROOT:-$repo_root/plugins/cc-cmds/orchestrator}"
scan_root="${SCAN_ROOT:-$repo_root}"
skills_root="${SKILLS_ROOT:-$repo_root/plugins/cc-cmds/skills}"
GATE_SH="$orch_root/gate.sh"
CONTRACT="$skills_root/_common/pipeline-sidecar.md"

if [[ ! -f "$GATE_SH" ]]; then
  echo "SKIP: gate.sh not found under $orch_root — 승인 상태 어휘 SOT 부재"
  exit 0
fi

# --- SOT extraction --------------------------------------------------------
states=$(sed -n 's/^readonly APPROVAL_STATES="\(.*\)"$/\1/p' "$GATE_SH")
if [[ -z "$states" ]]; then
  echo "FAIL: gate.sh — readonly APPROVAL_STATES=\"…\" 를 찾지 못했다 (어휘 SOT 부재)" >&2
  exit 1
fi

fail=0

in_vocab() {
  local t
  for t in $states; do [[ "$t" == "$1" ]] && return 0; done
  return 1
}

is_metasyntax() {
  case "$1" in
    '$'*) return 0 ;;   # a shell expansion
    '%'*) return 0 ;;   # a printf slot
    '<'*) return 0 ;;   # a schema placeholder
    */*)  return 0 ;;   # a parser's own sed pattern
    '-')  return 0 ;;   # the ledger's "no value" sentinel
    '')   return 0 ;;
  esac
  return 1
}

# --- Rule 1: exactly six, and `철회` among them -----------------------------
nst=0; for t in $states; do nst=$((nst + 1)); done
if [[ "$nst" != "6" ]]; then
  echo "FAIL: APPROVAL_STATES 는 여섯 토큰이어야 한다 (관측 ${nst}: $states) — 다섯이면 상태를 잃은 어휘, 일곱이면 이 린트에 알리지 않고 온 상태다" >&2
  fail=1
fi
if ! in_vocab 철회; then
  echo "FAIL: APPROVAL_STATES 에 철회 가 없다 — 경계 술어가 쓸 토큰을 어휘가 먼저 받아들여야 한다" >&2
  fail=1
fi

# --- Rule 2: every approval-row literal names one of the six ---------------
VALUE_TERMINATORS="\"'\`|)"
files=$(find "$scan_root/plugins" "$scan_root/scripts" -type f 2>/dev/null | sort || true)
scanned=0
hits=0
while IFS= read -r f; do
  [[ -n "$f" ]] || continue
  [[ -f "$f" ]] || continue
  selfskip=$(sed -n '1,5p' "$f" | grep -cF 'lint-approval-state-vocabulary: self-skip' || true)
  if [[ "${selfskip:-0}" != "0" ]]; then
    continue
  fi
  grep -qF '승인 id=' "$f" 2>/dev/null || continue
  scanned=$((scanned + 1))
  while IFS= read -r n; do
    [[ -n "$n" ]] || continue
    line="${n#*:}"
    lno="${n%%:*}"
    case "$line" in *'상태='*) ;; *) continue ;; esac
    # EVERY `상태=` ON THE LINE, not the first: a ledger literal carries one, but
    # a call site that appends two rows on one line would carry two.
    rest="$line"
    while :; do
      case "$rest" in *'상태='*) ;; *) break ;; esac
      rest="${rest#*상태=}"
      field=${rest%%[$VALUE_TERMINATORS]*}
      # A printf format string ends its value at `\n`; the backslash cannot sit
      # in the bracket expression above, so it is cut here.
      field=${field%%\\*}
      v=$(printf '%s' "$field" | sed 's/[[:space:]]*$//')
      if is_metasyntax "$v"; then continue; fi
      hits=$((hits + 1))
      if ! in_vocab "$v"; then
        echo "FAIL: ${f#"$scan_root"/}:${lno} — 승인 행의 상태 '$v' 가 어휘 밖이다" >&2
        echo "       허용: $states" >&2
        fail=1
      fi
    done
  done <<EOF
$(grep -nF '승인 id=' "$f" 2>/dev/null || true)
EOF
done <<EOF
$files
EOF

# --- Rule 3: the contract row equals the SOT set ---------------------------
nrow=0
if [[ ! -f "$CONTRACT" ]]; then
  echo "SKIP: _common/pipeline-sidecar.md 가 없어 계약 어휘 행 대조를 건너뛴다"
else
  # `sed -n '1p'` and not `head -1`: an early-exiting reader on the right of a
  # pipe kills the writer under `pipefail`.
  row=$(grep -F '| `승인.상태` |' "$CONTRACT" | sed -n '1p' || true)
  if [[ -z "$row" ]]; then
    echo "FAIL: pipeline-sidecar.md 에 | \`승인.상태\` | 어휘 행이 없다" >&2
    fail=1
  else
    # The cell after the key: tokens are backtick-quoted and separated by `\|`.
    cell=${row#*'| `승인.상태` |'}
    cell=${cell%|*}
    # Every odd field after splitting on backticks is between-token filler and
    # every even one is a token.
    doc_states=$(printf '%s' "$cell" | awk -F'`' '{ for (i = 2; i <= NF; i += 2) print $i }')
    for t in $doc_states; do
      nrow=$((nrow + 1))
      if ! in_vocab "$t"; then
        echo "FAIL: pipeline-sidecar.md 의 승인.상태 행이 '$t' 를 싣는데 gate.sh 의 APPROVAL_STATES 에는 없다" >&2
        fail=1
      fi
    done
    for t in $states; do
      hit=$(printf '%s\n' "$doc_states" | grep -xF -- "$t" || true)
      if [[ -z "$hit" ]]; then
        echo "FAIL: gate.sh 의 APPROVAL_STATES 가 '$t' 를 싣는데 pipeline-sidecar.md 의 승인.상태 행에는 없다" >&2
        fail=1
      fi
    done
  fi
fi

if [[ "$fail" != "0" ]]; then
  echo "lint-approval-state-vocabulary: violations found" >&2
  exit 1
fi

echo "OK:   approval-state vocabulary — 토큰 ${nst}개, 파일 ${scanned}건에서 리터럴 ${hits}건 대조, 계약 행 토큰 ${nrow}개 양방향 대조"
exit 0
