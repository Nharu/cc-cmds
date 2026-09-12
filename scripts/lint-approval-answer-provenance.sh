#!/usr/bin/env bash
# lint-approval-answer-provenance: self-skip
# Lint approval closing rows for a transport frame recorded as the answer.
#
# For a stretch of runs `gate_close` recorded the matched transcript LINE — a
# JSON object starting `{"parentUuid":…` — in `답변 문면`, the field the
# contract calls the run's only durable copy of a person's answer. Twenty-seven
# closing rows in the local corpus carry that envelope. The path that wrote it
# is gone; this lint is what keeps it gone.
#
# Rule: no `승인` closing row's `답변 문면` begins with `{"parentUuid`.  [fail]
#
# THE AUTHORITATIVE INPUT IS THE TRACKED FIXTURE, NOT THE LOCAL CORPUS.
# `docs/` is gitignored in this repository, so `docs/pipeline-run/` exists on
# this machine and nowhere else — a lint keyed on it would fail for want of
# input on every fresh clone and CI runner, or count zero rows and pass
# vacuously. The ledger samples under `tests/fixtures/…/ledgers/` travel with
# the tree, and against them the requirement is exactly zero.
#
# The local corpus is a SECONDARY diagnostic, and it fixes no baseline number:
# every run appends a file to `docs/pipeline-run/`, so a count pinned at
# landing time is already wrong the next morning and the easiest repair is to
# raise it. Instead the files present at landing are listed in
# `exempt-at-landing.txt` beside this lint, and only files that appeared after
# that list was written must carry zero envelope rows.
#
# Counting is by PIPE-FIELD DECOMPOSITION, never by substring: a closing row's
# `답변 문면` may legitimately QUOTE an envelope (an answer about one), and a
# substring test reports that as a violation.
#
# Usage:
#   bash scripts/lint-approval-answer-provenance.sh
#
# Env overrides (fixture runner):
#   FIXTURE_ROOT=<dir>  # directory holding ledgers/*.md and exempt-at-landing.txt
#   SCAN_ROOT=<dir>     # tree whose docs/pipeline-run/ is the secondary input
#
# Exit codes:
#   0 — pass
#   1 — at least one violation
#   2 — fixture root missing
#
# Compatibility: bash 3.2 (macOS) — no associative arrays, no `mapfile`.

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
fixture_root="${FIXTURE_ROOT:-$repo_root/tests/fixtures/lint-approval-answer-provenance}"
scan_root="${SCAN_ROOT:-$repo_root}"

if [[ ! -d "$fixture_root/ledgers" ]]; then
  echo "FAIL: 권위 입력이 없다: $fixture_root/ledgers — 추적되는 원장 샘플이 이 린트의 입력이다" >&2
  exit 2
fi

fail=0

# envelope_rows <ledger> — the number of `승인` closing rows whose `답변 문면`
# field (decomposed on ` | `) begins with the transcript envelope.
envelope_rows() {
  awk -F' \\| ' '
    /^- `승인` \|/ {
      for (i = 1; i <= NF; i++) {
        f = $i
        if (index(f, "답변 문면=") == 1) {
          v = substr(f, length("답변 문면=") + 1)
          if (index(v, "{\"parentUuid") == 1) n++
        }
      }
    }
    END { print n + 0 }' "$1"
}

nfix=0
for led in "$fixture_root"/ledgers/*.md; do
  [[ -f "$led" ]] || continue
  nfix=$((nfix + 1))
  n=$(envelope_rows "$led")
  if [[ "$n" != "0" ]]; then
    echo "FAIL: ${led#"$repo_root"/} — 답변 문면이 전사 봉투로 시작하는 승인 종결 행 ${n}건 (요구: 0)" >&2
    fail=1
  fi
done
if [[ "$nfix" = "0" ]]; then
  echo "FAIL: $fixture_root/ledgers 에 원장 샘플이 하나도 없다 — 입력 없는 린트는 자명하게 통과한다" >&2
  exit 2
fi

# --- secondary diagnostic: the local corpus, minus the landing-time set -----
ncorpus=0; nexempt=0
corpus="$scan_root/docs/pipeline-run"
if [[ -d "$corpus" ]]; then
  exempt="$fixture_root/exempt-at-landing.txt"
  for led in "$corpus"/*.md; do
    [[ -f "$led" ]] || continue
    b=$(basename "$led")
    if [[ -f "$exempt" ]]; then
      ex=$(grep -xF -- "$b" "$exempt" || true)
      if [[ -n "$ex" ]]; then nexempt=$((nexempt + 1)); continue; fi
    fi
    ncorpus=$((ncorpus + 1))
    n=$(envelope_rows "$led")
    if [[ "$n" != "0" ]]; then
      echo "FAIL: docs/pipeline-run/$b — 착지 뒤에 생긴 원장에 전사 봉투 종결 행 ${n}건 (요구: 0)" >&2
      fail=1
    fi
  done
fi

if [[ "$fail" != "0" ]]; then
  echo "lint-approval-answer-provenance: violations found" >&2
  exit 1
fi

echo "OK:   approval answer provenance — 픽스처 원장 ${nfix}건 봉투 행 0, 코퍼스 ${ncorpus}건 검사(면제 ${nexempt}건)"
exit 0
