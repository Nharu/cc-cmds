#!/usr/bin/env bash
# Check a kickoff interview record before the kickoff freezes it, and print
# the record's whole-file hash when it passes.
#
# The kickoff's 5m takes the record's hash from this script and from nothing
# else, so a record that fails here is never frozen. What it checks is the
# `## 검증 선결` section of `pipeline-sidecar.md` `### 2b.5`:
#
#   - the section exists;
#   - its first non-blank line is
#       `**검증 규약**: _common/verification.md sha256=<64 hex>`
#     and the hash equals the whole-file hash of the verification convention
#     beside this script (`../skills/_common/verification.md`) — the line is
#     the trace that the kickoff read the convention it judged under;
#   - the `판정:` value of every `- 전제:` item begins with `확인됨 — `,
#     `반증됨 — ` or `미확인 — `;
#   - `시험:`, `동의:` and `관측:` are on an item all together or not at all;
#   - the `문 <n>` of each `동의:` names a `### 문 <n>` of `## 요구사항 문답`.
#
# A record without `## 요구사항 문답` holds the visual direction alone and no
# interview, so there is nothing to check and only the hash is printed.
#
# Usage: interview-check.sh <record path>
#
# Exit codes:
#   0  passed; stdout is one line `sha256=<hex>`, the record's whole-file hash
#   1  at least one violation; one reason per line on stderr, nothing on stdout
#   2  no argument, the record cannot be read, or the convention beside this
#      script cannot be read
#
# Compatibility: bash 3.2 (macOS) — no associative arrays, no mapfile.

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
CONV_REL="_common/verification.md"
CONV="$script_dir/../skills/$CONV_REL"
KEY='**검증 규약**'

sha256_of() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

if [[ $# -ne 1 || -z "$1" ]]; then
  echo "interview-check: usage: interview-check.sh <record path>" >&2
  exit 2
fi
rec="$1"
if [[ ! -f "$rec" || ! -r "$rec" ]]; then
  echo "interview-check: 기록을 읽을 수 없다 — $rec" >&2
  exit 2
fi
if [[ ! -f "$CONV" || ! -r "$CONV" ]]; then
  echo "interview-check: 기준 판 검증 규약을 읽을 수 없다 — $CONV" >&2
  exit 2
fi

rec_hash=$(sha256_of "$rec")

if ! grep -qxF '## 요구사항 문답' "$rec"; then
  echo "sha256=$rec_hash"
  exit 0
fi

conv_hash=$(sha256_of "$CONV")

reasons=$(awk -v Q='## 요구사항 문답' -v V='## 검증 선결' \
  -v keyp="$KEY: $CONV_REL sha256=" -v want="$conv_hash" '
  function err(m) { print m }
  function flush() {
    if (!in_item) return
    if (!has_p) err("전제 「" prem "」 에 판정: 줄이 없다")
    n = has_t + has_c + has_o
    if (n != 0 && n != 3)
      err("전제 「" prem "」 의 시험:·동의:·관측: 이 함께 있지 않다 (시험 " has_t ", 동의 " has_c ", 관측 " has_o ")")
    in_item = 0
  }
  /^## / {
    if (sec == V && vcount == 1) flush()
    sec = $0
    if (sec == V) vcount++
    next
  }
  sec == Q && /^### 문 [0-9]+$/ { asked[substr($0, length("### 문 ") + 1)] = 1; next }
  sec == V && vcount == 1 {
    if (!first_seen) {
      if ($0 ~ /^[ \t]*$/) next
      first_seen = 1
      first = $0
      if (index($0, keyp) == 1) next
    }
    if (index($0, "- 전제:") == 1) {
      flush()
      in_item = 1
      prem = substr($0, length("- 전제:") + 1)
      sub(/^ /, "", prem)
      has_p = 0; has_t = 0; has_c = 0; has_o = 0
      next
    }
    if (!in_item) next
    if (index($0, "  판정:") == 1) {
      has_p = 1
      v = substr($0, length("  판정:") + 1)
      sub(/^ /, "", v)
      if (index(v, "확인됨 — ") != 1 && index(v, "반증됨 — ") != 1 && index(v, "미확인 — ") != 1)
        err("전제 「" prem "」 의 판정 값이 확인됨 — · 반증됨 — · 미확인 — 가운데 하나로 시작하지 않는다: " v)
      next
    }
    if (index($0, "  시험:") == 1) { has_t = 1; next }
    if (index($0, "  관측:") == 1) { has_o = 1; next }
    if (index($0, "  동의:") == 1) {
      has_c = 1
      v = substr($0, length("  동의:") + 1)
      sub(/^ /, "", v)
      if (v !~ /^문 [0-9]+$/) {
        err("전제 「" prem "」 의 동의: 값이 문 <n> 꼴이 아니다: " v)
      } else {
        nc++
        cref[nc] = substr(v, length("문 ") + 1)
        cprem[nc] = prem
      }
      next
    }
  }
  END {
    if (sec == V && vcount == 1) flush()
    if (vcount == 0) { err("## 검증 선결 절이 없다"); exit }
    if (!first_seen || index(first, keyp) != 1) {
      err("## 검증 선결 의 첫 줄이 **검증 규약**: _common/verification.md sha256=<hex> 줄이 아니다 — 검증 규약을 읽고 규약 읽기 흔적을 남긴 뒤 이 줄을 쓴다")
    } else {
      h = substr(first, length(keyp) + 1)
      if (length(h) != 64 || h ~ /[^0-9a-f]/)
        err("**검증 규약** 줄의 sha256 값이 64자 16진수가 아니다: " h)
      else if (h != want)
        err("**검증 규약** 줄의 sha256 " h " 이 지금 플러그인의 _common/verification.md 해시 " want " 와 다르다")
    }
    for (i = 1; i <= nc; i++)
      if (!(cref[i] in asked))
        err("전제 「" cprem[i] "」 의 동의: 문 " cref[i] " 에 해당하는 ### 문 " cref[i] " 이 ## 요구사항 문답 에 없다")
  }
' "$rec")

if [[ -n "$reasons" ]]; then
  printf '%s\n' "$reasons" | sed 's/^/interview-check: /' >&2
  exit 1
fi
echo "sha256=$rec_hash"
exit 0
