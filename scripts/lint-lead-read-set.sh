#!/usr/bin/env bash
# Pin what the unattended discuss and audit leads Read before they dispatch.
#
# Both leads used to Read whole shared contracts (`design/SKILL.md`'s Step 3
# and Step 4 span, `_common/agent-team-protocol.md`, `_common/verification.md`,
# and for the audit lead the audited document itself) before their first
# spawn, and Read them again after every compaction. Each lead now declares,
# in one `## Lead read set` table, the parts it Reads and the phase it Reads
# them in. The source files are not edited: a row names a verbatim heading or
# line start in its source, so a retitle or duplicate there fails here
# instead of leaving the lead reading nothing.
#
#   Rule 1 (presence and place) — exactly one `## Lead read set` outside code
#     fences, its preceding `##` heading `## Control-Flow Invariants` and its
#     following one `## Workflow`; at least one `파견전` lead row; one
#     `**파견전 상한**` line; the compaction pointer sentence once inside the
#     CFI section.
#   Rule 2 (row grammar) — five cells, each from its closed set.
#   Rule 3 (resolution) — a file row names a file under the skills root; a
#     heading part equals exactly one whole line outside fences, any other part
#     starts exactly one line outside fences (leading whitespace ignored); an
#     `끝:` marker resolves to exactly one line after the part; no row names the
#     declaring lead's own files.
#   Rule 4 (spans) — each row's span is measured in `LC_ALL=C` bytes.
#   Rule 5 (direct coverage) — every Read directive in the lead naming
#     `${CLAUDE_SKILL_DIR}/../<file>.md` has a row for that file; one inside
#     `## Workflow` above the lead's boundary heading needs a `파견전` row.
#     A path mentioned with no Read verb, a path outside the skills root and a
#     non-`.md` path are not directives.
#   Rule 6 (transitive coverage) — a Read directive line inside a declared
#     span (prefixed or bare `_common/…`, `references/…`) names a file that has
#     a row; when that file has no `전체` row, the (span file, named file) pair
#     is one of the lead's override pairs and its override sentence is in the
#     lead verbatim. Only directive lines count: a path mentioned in prose
#     inside a span is not one.
#   Rule 7 (ceiling) — for each dispatcher, the lead's SKILL.md bytes plus the
#     `파견전` spans of `공통` and that dispatcher are at most the lead's
#     constant, and the declared `**파견전 상한**` equals the constant. Run
#     inputs (`입력:`) are outside the sum and only printed.
#   Rule 8 (no whole reads) — no `전체` row for a forbidden file; a Read
#     directive below the CFI heading naming one carries a part, `§` or the
#     fixed tail on its line; every `입력:` row is `전체`.
#   Rule 9 (audit whole read) — exactly one line of the audit lead's
#     `### Step 1: Resolve, validate, FREEZE` starts with
#     `2. **Read the whole document.**`: the deterministic checks take the
#     whole audited document as their input.
#   Rule 10 (skip) — a lead whose SKILL.md is absent is SKIPped.
#
# Text that carries backslashes (parts, fixed sentences) reaches awk through
# ENVIRON, never `-v`: `-v` expands escape sequences and would compare a
# different string.
#
# What this does not check: that a row is the RIGHT part for an obligation.
# That correspondence is the design's obligation table, read by hand.
#
# Usage:
#   bash scripts/lint-lead-read-set.sh
#   SKILLS_ROOT=<dir> bash scripts/lint-lead-read-set.sh            # fixture test
#   LEAD_READ_SET_CEILING=<bytes> SKILLS_ROOT=<dir> bash …           # fixture ceiling
#
# LEAD_READ_SET_CEILING replaces every lead's constant, so a fixture tree of a
# few kilobytes can exercise the ceiling rule; the real tree runs with the
# constants below.
#
# Exit codes:
#   0 — every present lead passes
#   1 — at least one violation
#
# Compatibility: bash 3.2 (macOS) — no associative arrays, no `mapfile`.

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
skills_root="${SKILLS_ROOT:-$repo_root/plugins/cc-cmds/skills}"
while [[ "$skills_root" == */ && "$skills_root" != "/" ]]; do
  skills_root="${skills_root%/}"
done

export LC_ALL=C

LEADS=(design-discuss-unattended design-audit-unattended)

# --- constants ---------------------------------------------------------------

# Measured sum + at most 5%, rounded up to the next 1,000.
lead_ceiling() {
  case "$1" in
    design-discuss-unattended) echo 178000 ;;
    design-audit-unattended)   echo 149000 ;;
  esac
}

# The heading below which a Workflow directive is no longer pre-dispatch.
lead_boundary() {
  case "$1" in
    design-discuss-unattended) echo '### Step 5: `presentation.md` (seat dispatch only)' ;;
    design-audit-unattended)   echo '### Step 4: Witness collection (no resume)' ;;
  esac
}

lead_dispatchers() {
  case "$1" in
    design-discuss-unattended) echo '드라이버 시트' ;;
    design-audit-unattended)   echo '공통' ;;
  esac
}

lead_dispatch_set() {
  case "$1" in
    design-discuss-unattended) echo '공통 드라이버 시트' ;;
    design-audit-unattended)   echo '공통' ;;
  esac
}

FORBIDDEN_WHOLE=(
  "design/SKILL.md"
  "_common/agent-team-protocol.md"
  "_common/verification.md"
  "_common/sidecar.md"
  "_common/pipeline-sidecar.md"
)

STAGES='파견전 경계 라운드2+ 재진입 합성 워크스루 정합 감사:Step4 감사:Step5 감사:Step6 감사:Step7 팀원:verification 팀원:verification-실험 팀원:도메인'

# Literal text is read from a quoted heredoc with `read`, never `$(cat <<…)`:
# bash 3.2 parses a heredoc inside `$( )` for parentheses and quotes, and the
# fixed sentences carry quotes.
literal() {
  IFS= read -r -d '' "$1" || true
  printf -v "$1" '%s' "${!1%$'\n'}"
}

literal POINTER <<'EOF'
After any compaction, re-Read `## Lead read set`, then its `재진입` rows, then the rows of the phase you are in.
EOF

literal TAIL <<'EOF'
 — the parts listed in `## Lead read set` —
EOF

# Override pairs: "<lead>|<span file>|<named file>|<sentence>".
literal OVERRIDES <<'EOF'
design-discuss-unattended|design/SKILL.md|_common/agent-team-protocol.md|`design/SKILL.md`'s instruction to Read `_common/agent-team-protocol.md` is served by the parts of `_common/agent-team-protocol.md` in `## Lead read set`; do not Read `_common/agent-team-protocol.md` whole.
design-discuss-unattended|design/SKILL.md|_common/verification.md|`design/SKILL.md`'s instruction to Read `_common/verification.md` is served by the parts of `_common/verification.md` in `## Lead read set`; do not Read `_common/verification.md` whole.
design-audit-unattended|design-audit/references/02-deterministic-checks.md|_common/verification.md|`02-deterministic-checks.md`'s instruction to Read `_common/verification.md` is served by the rows of `## Lead read set`; that file is not Read whole.
EOF

AUDIT_LEAD='design-audit-unattended'
AUDIT_STEP='### Step 1: Resolve, validate, FREEZE'
literal AUDIT_WHOLE_READ <<'EOF'
2. **Read the whole document.**
EOF

# The three directive forms of Rule 5. The class is [^`], never [^.]: a
# sentence break between `Read` and the path is no reason to miss it.
DIRECTIVE_RE='Read[^`]{0,40}`\$\{CLAUDE_SKILL_DIR\}/\.\./[^`]+`|`\$\{CLAUDE_SKILL_DIR\}/\.\./[^`]+`[^`]{0,30}\(Read|Read `[^`]+` of `\$\{CLAUDE_SKILL_DIR\}/\.\./[^`]+`'
# Rule 6 adds the bare form; the path itself is narrowed to `_common/` and
# `references/`, which is where a borrowed span sends its reader.
T_PATH='(\$\{CLAUDE_SKILL_DIR\}/\.\./)?(_common|references)/[A-Za-z0-9_-]+\.md'
TRANSITIVE_RE="Read[^\`]{0,40}\`${T_PATH}|\`${T_PATH}\`[^\`]{0,30}\\(Read|Read \`[^\`]+\` of \`${T_PATH}"

# --- awk programs ------------------------------------------------------------

# Shared fence tracker: F[i] is 1 for a fence line or a line inside a fence.
# A fence closes on a line of the same character at least as long, so a
# four-backtick block may hold three-backtick lines.
FENCE_AWK='
function lstrip(s) { sub(/^[ \t]+/, "", s); return s }
function track(raw,   s, c, k) {
  s = lstrip(raw)
  if (fch == "") {
    if (s ~ /^```/ || s ~ /^~~~/) {
      c = substr(s, 1, 1); k = 0
      while (substr(s, k + 1, 1) == c) k++
      fch = c; flen = k
      return 1
    }
    return 0
  }
  k = 0
  while (substr(s, k + 1, 1) == fch) k++
  if (k >= flen && substr(s, k + 1) ~ /^[ \t]*$/) { fch = ""; flen = 0 }
  return 1
}
function hlevel(s,   t) { if (s !~ /^#+ /) return 0; t = s; sub(/ .*/, "", t); return length(t) }
'

# Print the file with every fenced line blanked, keeping line numbers.
BLANK_AWK="$FENCE_AWK"'
{ if (track($0)) print ""; else print }
'

# Resolve one part: prints "OK <bytes> <start> <end>" or "ERR <message>".
RESOLVE_AWK="$FENCE_AWK"'
function indent(s,   t) { t = s; sub(/[^ \t].*$/, "", t); return length(t) }
BEGIN { part = ENVIRON["LRS_PART"]; kind = ENVIRON["LRS_KIND"]; endp = ENVIRON["LRS_ENDP"] }
{ n++; L[n] = $0; B[n] = length($0) + 1; F[n] = track($0) }
END {
  if (kind == "전체") { t = 0; for (i = 1; i <= n; i++) t += B[i]; print "OK", t, 1, n; exit }
  heading = (part ~ /^#/)
  m = 0
  for (i = 1; i <= n; i++) {
    if (F[i]) continue
    if (heading) { if (L[i] == part) { m++; at = i } }
    else if (index(lstrip(L[i]), part) == 1) { m++; at = i }
  }
  if (m != 1) { print "ERR 부분이 울타리 밖에서 " m "줄에 맞는다(정확히 1줄이어야 한다)"; exit }
  st = at; en = n
  if (kind == "절" || kind == "본문만") {
    if (!heading) { print "ERR 범위 " kind " 는 표제 부분에만 쓴다"; exit }
    lv = hlevel(L[at])
    for (j = at + 1; j <= n; j++) {
      if (F[j]) continue
      h = hlevel(L[j])
      if (h > 0 && (kind == "본문만" || h <= lv)) { en = j - 1; break }
    }
  } else if (kind == "항목") {
    s = lstrip(L[at])
    en = at
    if (s ~ /^([-*+]|[0-9]+[.)])[ \t]/) {
      ind = indent(L[at])
      for (j = at + 1; j <= n; j++) {
        if (L[j] ~ /^[ \t]*$/) continue
        if (indent(L[j]) > ind) en = j; else break
      }
    } else {
      for (j = at + 1; j <= n; j++) { if (L[j] ~ /^[ \t]*$/) break; en = j }
    }
  } else if (kind == "끝") {
    m2 = 0
    for (j = at + 1; j <= n; j++) {
      if (F[j]) continue
      if (index(lstrip(L[j]), endp) == 1) { m2++; if (m2 == 1) e1 = j }
    }
    if (m2 != 1) { print "ERR 끝 표지가 부분 줄 뒤에서 " m2 "줄에 맞는다(정확히 1줄이어야 한다)"; exit }
    en = e1 - 1
  }
  t = 0
  for (i = st; i <= en; i++) t += B[i]
  print "OK", t, st, en
}
'

# Read the lead file's structure and its table. Tab-separated records:
#   NSEC <count>, PREV <heading>, NEXT <heading>, CEIL <count> <value>,
#   CFI <start> <end>, WF <start> <end>, BND <line>, PTR <count>,
#   ROW <line> <stage> <dispatch> <file> <part> <kind> <endp>, BAD <line> <msg>
TABLE_AWK="$FENCE_AWK"'
function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
function unwrap(c) {
  if (c ~ /^`` .+ ``$/) return substr(c, 4, length(c) - 6)
  if (c ~ /^`[^`]+`$/) return substr(c, 2, length(c) - 2)
  return "\002"
}
function instage(s,   k) {
  if (s ~ /^트리거:/) { k = s; sub(/^트리거:/, "", k); return (k != "" && k !~ /·/ && k !~ /\|/) }
  return (index(" " stages " ", " " s " ") > 0)
}
BEGIN { ptr = ENVIRON["LRS_PTR"]; bnd = ENVIRON["LRS_BND"] }
{ n++; L[n] = $0; F[n] = track($0) }
END {
  OFS = "\t"
  nsec = 0
  for (i = 1; i <= n; i++) {
    if (F[i]) continue
    if (L[i] ~ /^## /) { H2[++nh] = i }
    if (L[i] == "## Lead read set") { nsec++; if (nsec == 1) sec = i }
    if (L[i] == "## Control-Flow Invariants" && !cfi) cfi = i
    if (L[i] == "## Workflow" && !wf) wf = i
    if (L[i] == bnd && !bl) bl = i
  }
  print "NSEC", nsec
  # section ends: next ## heading after a start
  for (k = 1; k <= nh; k++) NX[H2[k]] = (k < nh ? H2[k + 1] - 1 : n)
  if (cfi) {
    print "CFI", cfi, NX[cfi]
    p = 0
    for (i = cfi; i <= NX[cfi]; i++) if (index(L[i], ptr) > 0) p++
    print "PTR", p
  } else print "CFI", 0, 0
  if (wf) print "WF", wf, NX[wf]; else print "WF", 0, 0
  print "BND", (bl ? bl : 0)
  if (!sec) exit
  prev = ""; nxt = ""
  for (k = 1; k <= nh; k++) if (H2[k] == sec) { if (k > 1) prev = L[H2[k - 1]]; if (k < nh) nxt = L[H2[k + 1]] }
  print "PREV", prev
  print "NEXT", nxt
  ce = 0; cv = ""
  for (i = sec; i <= NX[sec]; i++) {
    if (L[i] ~ /^\*\*파견전 상한\*\*: [0-9]+ 바이트$/) { ce++; cv = L[i]; sub(/^\*\*파견전 상한\*\*: /, "", cv); sub(/ 바이트$/, "", cv) }
  }
  print "CEIL", ce, cv
  state = 0
  for (i = sec + 1; i <= NX[sec]; i++) {
    if (F[i]) continue
    line = L[i]
    if (state == 0) {
      if (line ~ /^\|/) {
        if (line != "| 단계 | 디스패치 | 파일 | 부분 | 범위 |") { print "BAD", i, "표의 머리줄이 「| 단계 | 디스패치 | 파일 | 부분 | 범위 |」가 아니다"; exit }
        state = 1
      }
      continue
    }
    if (state == 1) {
      if (line !~ /^\|( *:?-+:? *\|){5}$/) { print "BAD", i, "표의 구분줄이 다섯 칸이 아니다"; exit }
      state = 2; continue
    }
    if (line !~ /^\|/) break
    work = line
    gsub(/\\\|/, "\001", work)
    nf = split(work, C, "|")
    if (nf != 7 || trim(C[1]) != "" || trim(C[7]) != "") { print "BAD", i, "행의 칸이 다섯이 아니다"; continue }
    for (k = 2; k <= 6; k++) { C[k] = trim(C[k]); gsub(/\001/, "|", C[k]) }
    stage = C[2]; disp = C[3]; file = C[4]; part = C[5]; rng = C[6]
    if (!instage(stage)) { print "BAD", i, "모르는 단계: " stage; continue }
    if (index(" " dispset " ", " " disp " ") == 0) { print "BAD", i, "이 리드가 쓰지 않는 디스패치: " disp; continue }
    f = unwrap(file)
    if (f == "\002") { print "BAD", i, "파일 칸이 백틱으로 싸여 있지 않다: " file; continue }
    if (part == "—") pp = "—"
    else { pp = unwrap(part); if (pp == "\002") { print "BAD", i, "부분 칸이 백틱으로 싸여 있지 않다: " part; continue } }
    endp = ""
    if (rng == "절" || rng == "본문만" || rng == "항목" || rng == "전체") kd = rng
    else {
      r = rng
      if (r ~ /^`` .+ ``$/) r = substr(r, 4, length(r) - 6)
      if (r ~ /^끝:`.+`$/) { kd = "끝"; endp = r; sub(/^끝:`/, "", endp); sub(/`$/, "", endp) }
      else { print "BAD", i, "모르는 범위: " rng; continue }
    }
    isin = (f ~ /^입력:/)
    if (isin && kd != "전체") { print "BAD", i, "입력: 행의 범위는 전체다: " rng; continue }
    if ((kd == "전체") != (pp == "—")) { print "BAD", i, "부분 — 는 범위 전체에만, 전체는 부분 — 에만 쓴다"; continue }
    if (isin && f == "입력:") { print "BAD", i, "입력: 뒤에 이름이 없다"; continue }
    print "ROW", i, stage, disp, f, pp, kd, endp
  }
}
'

# The lines of one section (heading through the next heading of the same or a
# higher level), fence-aware for the heading scan.
SECTION_AWK="$FENCE_AWK"'
{ n++; L[n] = $0; F[n] = track($0) }
END {
  for (i = 1; i <= n; i++) if (!F[i] && L[i] == head) { at = i; break }
  if (!at) exit
  lv = hlevel(head); en = n
  for (j = at + 1; j <= n; j++) { if (F[j]) continue; h = hlevel(L[j]); if (h > 0 && h <= lv) { en = j - 1; break } }
  for (i = at; i <= en; i++) print L[i]
}
'

# --- helpers -----------------------------------------------------------------

tmp=$(mktemp -d "${TMPDIR:-/tmp}/lint-lead-read-set.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

blanked() {
  # Fence-blanked copy of a file under the skills root, cached by path.
  local rel="$1" key
  key=$(printf '%s' "$rel" | tr '/' '_')
  if [[ ! -f "$tmp/blank.$key" ]]; then
    awk "$BLANK_AWK" "$skills_root/$rel" > "$tmp/blank.$key"
  fi
  printf '%s\n' "$tmp/blank.$key"
}

is_forbidden() {
  local f
  for f in "${FORBIDDEN_WHOLE[@]}"; do
    [[ "$1" == "$f" ]] && return 0
  done
  return 1
}

fail=0
checked=0
skipped=0
rows_total=0
banner_sums=""

for lead in "${LEADS[@]}"; do
  lf="$skills_root/$lead/SKILL.md"
  if [[ ! -f "$lf" ]]; then
    echo "SKIP: $lead — SKILL.md 없음"
    skipped=$((skipped + 1))
    continue
  fi
  checked=$((checked + 1))
  lead_fail=0
  ceiling="${LEAD_READ_SET_CEILING:-$(lead_ceiling "$lead")}"
  bnd=$(lead_boundary "$lead")
  dispset=$(lead_dispatch_set "$lead")

  LRS_PTR="$POINTER" LRS_BND="$bnd" awk -v stages="$STAGES" -v dispset="$dispset" \
    "$TABLE_AWK" "$lf" > "$tmp/struct"

  field() { awk -F '\t' -v k="$1" -v c="$2" '$1 == k { print $c; exit }' "$tmp/struct"; }

  # Rule 1 — presence and place.
  nsec=$(field NSEC 2)
  if [[ "$nsec" != "1" ]]; then
    echo "FAIL: $lead — 울타리 밖 '## Lead read set' 이 ${nsec}개다(정확히 1개여야 한다)" >&2
    fail=1
    continue
  fi
  prev=$(field PREV 2)
  next_h=$(field NEXT 2)
  if [[ "$prev" != "## Control-Flow Invariants" || "$next_h" != "## Workflow" ]]; then
    echo "FAIL: $lead — '## Lead read set' 은 '## Control-Flow Invariants' 와 '## Workflow' 사이에 있어야 한다(앞: '$prev', 뒤: '$next_h')" >&2
    lead_fail=1
  fi
  ceil_count=$(field CEIL 2)
  ceil_value=$(field CEIL 3)
  if [[ "$ceil_count" != "1" ]]; then
    echo "FAIL: $lead — '**파견전 상한**: <N> 바이트' 줄이 ${ceil_count}개다(정확히 1개여야 한다)" >&2
    lead_fail=1
  elif [[ "$ceil_value" != "$ceiling" ]]; then
    echo "FAIL: $lead — 선언된 파견전 상한 $ceil_value 이 린트 상수 $ceiling 과 다르다" >&2
    lead_fail=1
  fi
  cfi_start=$(field CFI 2)
  if [[ "$cfi_start" == "0" ]]; then
    echo "FAIL: $lead — '## Control-Flow Invariants' 절이 없다" >&2
    lead_fail=1
  else
    ptr_count=$(field PTR 2)
    if [[ "$ptr_count" != "1" ]]; then
      echo "FAIL: $lead — CFI 절 안의 압축 포인터 문장이 ${ptr_count}번이다(정확히 1번이어야 한다)" >&2
      lead_fail=1
    fi
  fi
  wf_start=$(field WF 2)
  wf_end=$(field WF 3)
  bnd_line=$(field BND 2)
  if [[ "$bnd_line" == "0" ]]; then
    echo "FAIL: $lead — 경계 표제가 없다: $bnd" >&2
    lead_fail=1
  fi

  # Rule 2 — row grammar.
  bad=$(awk -F '\t' '$1 == "BAD" { print "       :" $2 " " $3 }' "$tmp/struct")
  if [[ -n "$bad" ]]; then
    echo "FAIL: $lead — 표의 행 문법 위반" >&2
    printf '%s\n' "$bad" >&2
    lead_fail=1
  fi
  awk -F '\t' '$1 == "ROW"' "$tmp/struct" > "$tmp/rows"
  nrows=0
  [[ -s "$tmp/rows" ]] && nrows=$(awk 'END { print NR }' "$tmp/rows")
  if [[ "$nrows" == "0" ]]; then
    echo "FAIL: $lead — '## Lead read set' 의 표에 행이 없다" >&2
    fail=1
    continue
  fi
  pre_rows=$(awk -F '\t' '$3 == "파견전" && $5 !~ /^입력:/ { c++ } END { print c + 0 }' "$tmp/rows")
  if [[ "$pre_rows" == "0" ]]; then
    echo "FAIL: $lead — 파견전 리드 행이 없다" >&2
    lead_fail=1
  fi

  # Rules 3, 4, 8 — resolve every row; record spans.
  : > "$tmp/resolved"
  inputs=""
  while IFS=$'\t' read -r _ ln stage disp file part kind endp; do
    rows_total=$((rows_total + 1))
    case "$file" in
      "$lead"/*)
        echo "FAIL: $lead — :$ln 행이 선언하는 갈래 자신의 파일을 이름한다: $file" >&2
        lead_fail=1; continue ;;
      입력:*)
        # Rule 8: the grammar already refused an `입력:` row that is not `전체`.
        inputs="$inputs $file($stage/$disp/$kind)"
        continue ;;
    esac
    if [[ "$file" == /* || "$file" == *..* || ! -f "$skills_root/$file" ]]; then
      echo "FAIL: $lead — :$ln 행의 파일이 스킬 루트 아래에 없다: $file" >&2
      lead_fail=1; continue
    fi
    if [[ "$kind" == "전체" ]] && is_forbidden "$file"; then
      echo "FAIL: $lead — :$ln 금지 파일을 전체로 읽는 행: $file" >&2
      lead_fail=1; continue
    fi
    res=$(LRS_PART="$part" LRS_KIND="$kind" LRS_ENDP="$endp" awk "$RESOLVE_AWK" "$skills_root/$file")
    case "$res" in
      OK\ *)
        set -- $res
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$ln" "$stage" "$disp" "$file" "$part" "$kind" "$2" "$3 $4" >> "$tmp/resolved" ;;
      *)
        echo "FAIL: $lead — :$ln $file 「${part}」: ${res#ERR }" >&2
        lead_fail=1 ;;
    esac
  done < "$tmp/rows"

  has_row() {
    # A lead row (not a member row) for file $1; with $2, only that stage.
    awk -F '\t' -v f="$1" -v s="${2:-}" '$4 == f && $2 !~ /^팀원:/ && (s == "" || $2 == s) { c++ } END { exit !(c > 0) }' "$tmp/resolved"
  }
  has_whole() {
    awk -F '\t' -v f="$1" '$4 == f && $6 == "전체" && $2 !~ /^팀원:/ { c++ } END { exit !(c > 0) }' "$tmp/resolved"
  }

  # Rules 5 and 8 — directives in the lead itself.
  lb=$(blanked "$lead/SKILL.md")
  grep -n -o -E "$DIRECTIVE_RE" "$lb" > "$tmp/directives" || true
  while IFS= read -r hit; do
    [[ -n "$hit" ]] || continue
    ln="${hit%%:*}"
    path=$(printf '%s\n' "$hit" | sed -E 's/.*\$\{CLAUDE_SKILL_DIR\}\/\.\.\/([^`]*).*/\1/')
    case "$path" in
      ../*) continue ;;
      *.md) ;;
      *) continue ;;
    esac
    if [[ "$wf_start" != "0" && "$ln" -gt "$wf_start" && "$ln" -le "$wf_end" && "$bnd_line" != "0" && "$ln" -lt "$bnd_line" ]]; then
      if ! has_row "$path" "파견전"; then
        echo "FAIL: $lead — :$ln 경계 표제 위 Read 지시가 파견전 행이 없는 파일을 이름한다: $path" >&2
        lead_fail=1
      fi
    elif ! has_row "$path"; then
      echo "FAIL: $lead — :$ln Read 지시가 행이 없는 파일을 이름한다: $path" >&2
      lead_fail=1
    fi
    if [[ "$cfi_start" != "0" && "$ln" -gt "$cfi_start" ]] && is_forbidden "$path"; then
      text=$(sed -n "${ln}p" "$lb")
      if [[ "$text" != *'`#'* && "$text" != *'§'* && "$text" != *"$TAIL"* ]]; then
        echo "FAIL: $lead — :$ln 금지 파일 Read 지시에 부분·§·고정 꼬리가 없다: $path" >&2
        lead_fail=1
      fi
    fi
  done < "$tmp/directives"

  # Rule 6 — directives inside declared spans.
  : > "$tmp/seen"
  while IFS=$'\t' read -r ln stage disp file part kind bytes span; do
    case "$stage" in 팀원:*) continue ;; esac
    st="${span% *}"; en="${span#* }"
    sb=$(blanked "$file")
    sed -n "${st},${en}p" "$sb" | grep -o -E "$TRANSITIVE_RE" > "$tmp/thits" || true
    while IFS= read -r th; do
      [[ -n "$th" ]] || continue
      name=$(printf '%s\n' "$th" | sed -E 's/.*(_common|references)\/([A-Za-z0-9_-]+\.md).*/\1\/\2/')
      case "$name" in
        references/*) target="${file%%/*}/$name" ;;
        *) target="$name" ;;
      esac
      [[ "$target" == "$file" ]] && continue
      pair="$file|$target"
      if grep -q -x -F -- "$pair" "$tmp/seen"; then continue; fi
      printf '%s\n' "$pair" >> "$tmp/seen"
      if ! has_row "$target"; then
        echo "FAIL: $lead — $file 의 선언 구간 안 Read 지시가 행이 없는 파일을 이름한다: $target" >&2
        lead_fail=1
        continue
      fi
      has_whole "$target" && continue
      sentence=$(printf '%s\n' "$OVERRIDES" | awk -F '|' -v l="$lead" -v s="$file" -v t="$target" '$1 == l && $2 == s && $3 == t { sub(/^[^|]*\|[^|]*\|[^|]*\|/, ""); print; exit }')
      if [[ -z "$sentence" ]]; then
        echo "FAIL: $lead — $file 가 $target 을 Read 하라는데 전체 행도 덮어쓰기 쌍도 없다" >&2
        lead_fail=1
      else
        sc=$(grep -c -F -- "$sentence" "$lf" || true)
        if [[ "${sc:-0}" == "0" ]]; then
          echo "FAIL: $lead — ($file → $target) 덮어쓰기 문장이 본문에 없다: $sentence" >&2
          lead_fail=1
        fi
      fi
    done < "$tmp/thits"
  done < "$tmp/resolved"

  # Rule 9 — the audit lead Reads the audited document whole in Step 1.
  if [[ "$lead" == "$AUDIT_LEAD" ]]; then
    awk -v head="$AUDIT_STEP" "$SECTION_AWK" "$lf" > "$tmp/step1"
    if [[ ! -s "$tmp/step1" ]]; then
      echo "FAIL: $lead — '$AUDIT_STEP' 절이 없다" >&2
      lead_fail=1
    else
      cnt=$(LRS_LIT="$AUDIT_WHOLE_READ" awk '{ s = $0; sub(/^[ \t]+/, "", s); if (index(s, ENVIRON["LRS_LIT"]) == 1) c++ } END { print c + 0 }' "$tmp/step1")
      if [[ "$cnt" != "1" ]]; then
        echo "FAIL: $lead — Step 1 에서 '$AUDIT_WHOLE_READ' 로 시작하는 줄이 ${cnt}개다(정확히 1개여야 한다)" >&2
        lead_fail=1
      fi
    fi
  fi

  # Rule 7 — ceiling per dispatcher.
  skill_bytes=$(wc -c < "$lf" | tr -d ' ')
  sums=""
  for d in $(lead_dispatchers "$lead"); do
    spans=$(awk -F '\t' -v d="$d" '$2 == "파견전" && ($3 == "공통" || $3 == d) { k = $4 "\t" $5 "\t" $6; if (!(k in seen)) { seen[k] = 1; t += $7 } } END { print t + 0 }' "$tmp/resolved")
    total=$((skill_bytes + spans))
    sums="$sums $d=$total"
    if (( total > ceiling )); then
      echo "FAIL: $lead — 파견전 합($d) $total 바이트(SKILL.md $skill_bytes + 구간 $spans)가 상한 $ceiling 을 넘는다" >&2
      lead_fail=1
    fi
  done
  [[ -n "$inputs" ]] && echo "입력: $lead —$inputs (크기는 런마다 달라 상한 밖)"

  if [[ "$lead_fail" -ne 0 ]]; then
    fail=1
  else
    ndir=0; ntrans=0
    [[ -s "$tmp/directives" ]] && ndir=$(awk 'END { print NR }' "$tmp/directives")
    [[ -s "$tmp/seen" ]] && ntrans=$(awk 'END { print NR }' "$tmp/seen")
    echo "OK:   $lead — ${nrows} row(s) resolved, ${ndir} directive(s), ${ntrans} transitive pair(s), 파견전 합${sums} / 상한 $ceiling"
  fi
  banner_sums="$banner_sums $lead(${sums# }/$ceiling)"
done

if [[ "$fail" -ne 0 ]]; then
  echo "lint-lead-read-set: violations found" >&2
  exit 1
fi

echo "lint-lead-read-set: OK — ${checked} lead(s) checked, ${skipped} absent, ${rows_total} row(s);${banner_sums}"
exit 0
