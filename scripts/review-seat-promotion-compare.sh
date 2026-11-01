#!/usr/bin/env bash
# Measure what the review's promoted seats are worth, from the reports' own
# seat attribution.
#
# Three subcommands read reports through the same reader function:
#
#   observe  count the P0 and P1 items of past review reports (default: the
#            `docs/reviews/` of this script's checkout, its `*.md` directly
#            under it, dot files excluded) by who raised them. It never
#            judges: the reports' bytes differ, so only the paired re-review
#            can.
#   pairs    the paired re-review's verdict. Reads only <exp>/samples.tsv and
#            <exp>/reports/<n>-<opus-1|sonnet|opus-2>.md — the exchange format
#            scripts/review-seat-promotion-pair.sh writes, never its state
#            root — and writes the verdict report (default <exp>/report.md).
#   scan     one report's reader output, tab-separated, for the pair runner's
#            collect stage (its validity and format checks).
#
# Deterministic: no model, no network. Nothing is modified but the --out file.
#
# Attribution of an item (a column-0 `- **[` line inside `## 🔴 P0` or
# `## 🟠 P1`):
#   - its first `    - **좌석**: 낸=<slug>[,<slug>] | 동의=<slug>[,<slug>]|-`
#     sub-bullet, every slug byte-equal to the first cell of a `모델 티어` row
#     of the same report; a line off that grammar or naming another slug counts
#     as `철자 불일치` and leaves the item `미상`;
#   - without that line, the tail after the item line's last ` — `:
#     `<names>[ (<clauses>)]`, names split on `·` or `, `, clauses split on
#     `, ` and only a clause ending ` 동의` read (its names are the agreeing
#     seats). A name is lowercased and loses a trailing `-reviewer`, then
#     matched against the report's slugs normalised the same way; one name
#     that does not match, or a tail off the grammar, leaves the item `미상`.
#     A clause that is only seat names, with no ` 동의`, is an agreement listed
#     with commas (`(logic, contract 동의)`) that the clause split cut apart;
#     it leaves the item `미상` too, so no listed name is dropped unseen.
#   An item line carrying `에서 상속` is inherited, counted as `상속 제외` and
#   not classified.
#
# Classification, P the slugs of the report's `출처=승격` rows, R the raising
# seats, A the agreeing seats; the first line that applies decides:
#   1 R ∪ A holds no seat of P                    → 표만
#   2 R ⊆ P and A holds no seat outside P         → 승격만
#   3 R holds a seat of P and a seat outside P    → 표도 냄
#   4 R holds no seat of P                        → 승격 동의
#   5 otherwise                                   → 표 동의
# `승격만` is also counted per trigger id: an item counts once for every id in
# the union of the `지표` of its raising seats.
#
# Rule of `pairs`, fixed before the experiment (the constants below and the
# golden test hold it). a, b and s are the P0+P1 counts of the opus-1, opus-2
# and sonnet reports of one sample, a0, b0 and s0 their P0 counts,
# o = (a + b) ÷ 2; the first line that applies decides:
#   1 valid samples ≠ SAMPLES_REQUIRED                             → 판정 불가(표본 수)
#   2 samples with s0 < min(a0, b0) ≥ VETO_SAMPLE_MIN and
#     Σ max(0, min(a0, b0) − s0) ≥ VETO_SUM_MIN                     → 유지
#   3 Σ o < SIGNAL_MIN                                             → 판정 불가(신호 부족)
#   4 W = median of |a − b| ÷ (o + 1) > NOISE_MAX                   → 판정 불가(변동 폭 과다)
#   5 D = median of (o − s) ÷ (o + 1) > max(DROP_FLOOR, NOISE_FACTOR × W) → 유지
#   6 otherwise                                                    → 축소 권고
# Equal to a threshold is not above it. The items a promoted seat raised and
# the `승격만` items are printed beside the rule with no threshold. Every act
# after the verdict is a person's: a separate change that narrows a trigger, or
# a separate change to the constants before a new experiment.
#
# Usage:
#   scripts/review-seat-promotion-compare.sh observe [--reports <dir>]… [--since YYYY-MM-DD] [--out <file>|-]
#   scripts/review-seat-promotion-compare.sh pairs --exp <dir> [--out <file>|-]
#   scripts/review-seat-promotion-compare.sh scan <report>
#
# Exit codes:
#   observe  0 report written, 1 no report to read (a directory that does not
#            exist is named with `디렉터리 없음`), 2 usage error
#   pairs    0 report written (`판정 불가` included), 1 a slot error or no
#            input, 2 usage error
#   scan     0 read, 1 no such file, 2 usage error
#
# Compatibility: bash 3.2 (macOS) — no associative arrays, no mapfile.
# Non-ASCII literals follow a `${var}` brace, never a bare `$var`.

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)

SAMPLES_REQUIRED=5
VETO_SAMPLE_MIN=2
VETO_SUM_MIN=2
SIGNAL_MIN=5
DROP_FLOOR=0.20
NOISE_FACTOR=2
NOISE_MAX=0.25

BRANCHES="opus-1 sonnet opus-2"
CLASSES="승격만 표도냄 표동의 승격동의 표만"

usage() { echo "review-seat-promotion-compare: $1" >&2; exit 2; }
die() { echo "review-seat-promotion-compare: $1" >&2; exit 1; }

# ---------- arguments --------------------------------------------------------

cmd="${1:-}"
case "$cmd" in
  observe|pairs|scan) shift ;;
  -h|--help) grep -E '^# ' "$0" | cut -c3-; exit 0 ;;
  "") usage "a subcommand is required: observe, pairs or scan" ;;
  *) usage "unknown subcommand: $cmd" ;;
esac

exp_dir=""
reports=()
since=""
out=""
scan_file=""
while (( $# > 0 )); do
  case "$1" in
    --exp) [[ "$cmd" == "pairs" ]] || usage "--exp belongs to pairs"; exp_dir="${2:-}"; shift 2 || usage "--exp needs a value"; [[ -n "$exp_dir" ]] || usage "--exp needs a value" ;;
    --reports) [[ "$cmd" == "observe" ]] || usage "--reports belongs to observe"; [[ -n "${2:-}" ]] || usage "--reports needs a value"; reports+=("$2"); shift 2 ;;
    --since) [[ "$cmd" == "observe" ]] || usage "--since belongs to observe"; since="${2:-}"; shift 2 || usage "--since needs a value"
      [[ "$since" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || usage "--since must be YYYY-MM-DD: $since" ;;
    --out) [[ "$cmd" != "scan" ]] || usage "--out does not belong to scan"; out="${2:-}"; shift 2 || usage "--out needs a value"; [[ -n "$out" ]] || usage "--out needs a value" ;;
    -h|--help) grep -E '^# ' "$0" | cut -c3-; exit 0 ;;
    -*) usage "unknown argument: $1" ;;
    *) [[ "$cmd" == "scan" && -z "$scan_file" ]] || usage "unknown argument: $1"; scan_file="$1"; shift ;;
  esac
done

# ---------- the shared reader ------------------------------------------------

# scan_report <report> [since] — the reader output, tab-separated:
#   H  <exclusion|-> <리뷰 날짜|-> <요약 정규|비정규|복구|없음> <P0|-> <P1|->
#      <리뷰 HEAD|-> <promoted seats slug=model=triggers;…|-> <tier rows>
#      <non-inherited items without a 좌석 line> <format problems>
#   I  <P0|P1> <class> <formal 0|1> <spelling 0|1> <promoted raised 0|1>
#      <triggers a,b|->
# exclusion is `모델 티어 없음`, `날짜 없음`, `날짜 범위 밖` or `머리형 항목`, in
# that order. format problems mirror the gate's `report-check` reader: the
# count of `비불릿`, `앵커 없음`, `태그 밖`, `항목 수`, `요약 없음` and `HEAD 줄 없음`
# findings, `-` when there are none, else `<kind>:<n>,…`.
scan_report() {
  LC_ALL=C awk -v since="${2:-}" '
    BEGIN {
      R = "\360\237\224\264"; O = "\360\237\237\240"; Y = "\360\237\237\241"; G = "\360\237\237\242"
      MID = "\302\267"; DASH = " \342\200\224 "
      split("security performance code-quality logic error-handling type-safety testing api-contract concurrency data-integrity design-conformance", cl, " ")
      for (i in cl) okcat[cl[i]] = 1
      sec = ""; nt = 0; ni = 0; cur = 0; intier = 0
    }
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t\r]+$/, "", s); return s }
    function norm(s) { s = tolower(s); sub(/-reviewer$/, "", s); return s }
    function prob(kind) { if (!(kind in pk)) po[++np] = kind; pk[kind]++ }
    function category(s,   t) {
      while (match(s, /\*\*\[[^]]*\]\*\*/)) {
        t = substr(s, RSTART + 3, RLENGTH - 6); s = substr(s, RSTART + RLENGTH)
        if (t == "CI-CONFIRMED" || t == "차단" || t == "이월 가능") continue
        return t
      }
      return ""
    }
    function anchor(s,   t) {
      while (match(s, /`[^`]*`/)) {
        t = substr(s, RSTART + 1, RLENGTH - 2); s = substr(s, RSTART + RLENGTH)
        if (t == "[CI-CONFIRMED]") continue
        return t
      }
      return ""
    }
    # namelist <text> <out> — split on "·" or ", " into out[1..n]; 0 when a
    # name is empty or holds a character a name never holds.
    function namelist(s, out,   n, i, p, t, m) {
      gsub(/, /, "\001", s); gsub(MID, "\001", s)
      n = split(s, p, "\001"); m = 0
      for (i = 1; i <= n; i++) {
        t = trim(p[i])
        if (t == "" || t ~ /[ ()|=]/) return 0
        out[++m] = t
      }
      return m
    }
    function lastdash(s,   i, j) {
      j = 0
      while ((i = index(substr(s, j + 1), DASH)) > 0) j += i
      return j
    }
    function flush() { if (cur) cur = 0 }
    { line = $0; sub(/[ \t\r]+$/, "", line) }
    index(line, "- **모델 티어**:") == 1 { intier = 1; next }
    intier && index(line, "    - ") == 1 {
      row = substr(line, 7); nf = split(row, f, " [|] ")
      if (nf >= 2 && index(f[2], "부류=") == 1) {
        s = trim(f[1]); nt++; tslug[nt] = s; known[s] = 1
        for (i = 2; i <= nf; i++) {
          k = f[i]; e = index(k, "=")
          if (e > 0) { kk = substr(k, 1, e - 1); vv = substr(k, e + 1); tv[s, kk] = vv }
        }
        ns = norm(s); if (ns in tnorm && tnorm[ns] != s) tnorm[ns] = "\002"; else tnorm[ns] = s
      }
      next
    }
    intier { intier = 0 }
    date == "" && index(line, "- **리뷰 날짜**: ") == 1 {
      d = substr(line, length("- **리뷰 날짜**: ") + 1)
      if (d ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/) date = substr(d, 1, 10)
    }
    head == "" && index(line, "- **리뷰 HEAD**: ") == 1 {
      h = substr(line, length("- **리뷰 HEAD**: ") + 1); gsub(/`/, "", h); h = trim(h)
      if (h ~ /^[0-9a-f]+$/) head = h
    }
    summ == "" && index(line, "- **발견 요약") == 1 {
      if (index(line, "- **발견 요약(부분 복구)**") == 1) summ = "복구"
      else if (match(line, "^- \\*\\*발견 요약\\*\\*: " R " P0 [0-9]+건 [|] " O " P1 [0-9]+건 [|] " Y " P2 [0-9]+건 [|] " G " P3 [0-9]+건$")) {
        summ = "정규"; t = line
        sub("^- \\*\\*발견 요약\\*\\*: " R " P0 ", "", t); sp0 = t + 0
        sub("^[0-9]+건 [|] " O " P1 ", "", t); sp1 = t + 0
      } else summ = "비정규"
    }
    index(line, "## ") == 1 {
      flush()
      if (index(line, "## " R " P0") == 1) sec = "P0"
      else if (index(line, "## " O " P1") == 1) sec = "P1"
      else sec = ""
      next
    }
    sec == "" { next }
    index(line, "### ") == 1 { headform = 1; prob("비불릿"); next }
    index(line, "- **[") == 1 {
      flush(); ni++; cur = ni; isec[ni] = sec; itext[ni] = line; iseat[ni] = ""
      if (sec == "P0") n0++; else n1++
      c = category(line); if (!(c in okcat)) prob("태그 밖")
      a = anchor(line); if (a !~ /^[^ `]+:[0-9]+(-[0-9]+)?$/) prob("앵커 없음")
      next
    }
    cur && iseat[cur] == "" && index(line, "    - **좌석**: ") == 1 {
      iseat[cur] = substr(line, length("    - **좌석**: ") + 1); hasseat[cur] = 1
    }
    function promoted(s) { return ((s, "출처") in tv) && tv[s, "출처"] == "승격" }
    END {
      if (summ == "" || summ == "비정규") prob("요약 없음")
      if (summ == "정규" && (n0 + 0 != sp0 || n1 + 0 != sp1)) prob("항목 수")
      if (summ != "복구" && head == "") prob("HEAD 줄 없음")
      excl = "-"
      if (nt == 0) excl = "모델 티어 없음"
      else if (date == "") excl = "날짜 없음"
      else if (since != "" && date < since) excl = "날짜 범위 밖"
      else if (headform) excl = "머리형 항목"
      pl = ""
      for (i = 1; i <= nt; i++) if (promoted(tslug[i])) {
        pl = pl (pl == "" ? "" : ";") tslug[i] "=" tv[tslug[i], "모델"] "=" tv[tslug[i], "지표"]
      }
      missing = 0
      for (i = 1; i <= ni; i++) {
        inh = index(itext[i], "에서 상속") > 0
        delete Rs; delete As; nr = 0; na = 0; ok = 1; spell = 0
        if (inh) { cls = "상속제외" }
        else if (hasseat[i]) {
          s = trim(iseat[i])
          if (s !~ /^낸=[^ |]+ [|] 동의=[^ |]+$/) { ok = 0; spell = 1 }
          else {
            split(s, pp, " [|] "); rs = substr(pp[1], length("낸=") + 1); as = substr(pp[2], length("동의=") + 1)
            m = split(rs, q, ",")
            for (j = 1; j <= m; j++) { if (q[j] == "" || !(q[j] in known)) { ok = 0; spell = 1 } else Rs[++nr] = q[j] }
            if (as != "-") {
              m = split(as, q, ",")
              for (j = 1; j <= m; j++) { if (q[j] == "" || !(q[j] in known)) { ok = 0; spell = 1 } else As[++na] = q[j] }
            }
          }
        } else {
          missing++
          p = lastdash(itext[i])
          if (p == 0) ok = 0
          else {
            tail = trim(substr(itext[i], p + length(DASH))); par = ""
            if (match(tail, / \([^()]*\)$/)) { par = substr(tail, RSTART + 2, RLENGTH - 3); tail = substr(tail, 1, RSTART - 1) }
            if (tail ~ /[()]/) ok = 0
            delete nm; m = namelist(tail, nm); if (m == 0) ok = 0
            for (j = 1; j <= m && ok; j++) { x = norm(nm[j]); if (!(x in tnorm) || tnorm[x] == "\002") ok = 0; else Rs[++nr] = tnorm[x] }
            if (ok && par != "") {
              nc = split(par, cs, ", ")
              for (j = 1; j <= nc && ok; j++) {
                cc = trim(cs[j]); L = length(" 동의")
                if (length(cc) > L && substr(cc, length(cc) - L + 1) == " 동의") {
                  delete nm2; m2 = namelist(substr(cc, 1, length(cc) - L), nm2); if (m2 == 0) ok = 0
                  for (k = 1; k <= m2 && ok; k++) { x = norm(nm2[k]); if (!(x in tnorm) || tnorm[x] == "\002") ok = 0; else As[++na] = tnorm[x] }
                } else {
                  # A clause that is nothing but seat names is the front of an
                  # agreement listed with commas, `(logic, contract 동의)`: the
                  # split above cut it from its ` 동의`, so the item is `미상`
                  # rather than read with those names dropped.
                  delete nm2; m2 = namelist(cc, nm2); named = (m2 > 0)
                  for (k = 1; k <= m2 && named; k++) { x = norm(nm2[k]); if (!(x in tnorm)) named = 0 }
                  if (named) ok = 0
                }
              }
            }
          }
        }
        trig = "-"; praised = 0
        if (!inh && ok) {
          delete inR; rp = 0; rn = 0
          for (j = 1; j <= nr; j++) { inR[Rs[j]] = 1; if (promoted(Rs[j])) { rp++; praised = 1 } else rn++ }
          ap = 0; an = 0
          for (j = 1; j <= na; j++) { if (As[j] in inR) continue; if (promoted(As[j])) ap++; else an++ }
          if (rp == 0 && ap == 0) cls = "표만"
          else if (rn == 0 && an == 0) cls = "승격만"
          else if (rp > 0 && rn > 0) cls = "표도냄"
          else if (rp == 0) cls = "승격동의"
          else cls = "표동의"
          if (cls == "승격만") {
            delete seen; trig = ""
            for (j = 1; j <= nr; j++) {
              m = split(tv[Rs[j], "지표"], q, ",")
              for (k = 1; k <= m; k++) { q[k] = trim(q[k]); if (q[k] != "-" && q[k] != "" && !(q[k] in seen)) { seen[q[k]] = 1; trig = trig (trig == "" ? "" : ",") q[k] } }
            }
            if (trig == "") trig = "-"
          }
        } else if (!inh) cls = "미상"
        printf "I\t%s\t%s\t%d\t%d\t%d\t%s\n", isec[i], cls, hasseat[i] ? 1 : 0, spell, praised, trig
      }
      fp = ""
      for (i = 1; i <= np; i++) fp = fp (fp == "" ? "" : ",") po[i] ":" pk[po[i]]
      printf "H\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%d\t%d\t%s\n", excl, (date == "" ? "-" : date), (summ == "" ? "없음" : summ), \
        (summ == "정규" ? sp0 : "-"), (summ == "정규" ? sp1 : "-"), (head == "" ? "-" : head), (pl == "" ? "-" : pl), nt, missing, (fp == "" ? "-" : fp)
    }' "$1"
}

emit() {
  if [[ "$out" == "-" ]]; then
    cat "$1"
  else
    local t="${out}.tmp.$$"
    cat "$1" > "$t"
    mv "$t" "$out"
  fi
}

work=$(mktemp -d "${TMPDIR:-/tmp}/review-seat-promotion-compare.XXXXXX")
trap 'rm -rf "$work"' EXIT

# ---------- scan -------------------------------------------------------------

run_scan() {
  [[ -n "$scan_file" ]] || usage "scan needs a report path"
  [[ -f "$scan_file" ]] || die "no such report: $scan_file"
  scan_report "$scan_file"
}

# ---------- observe ----------------------------------------------------------

run_observe() {
  (( ${#reports[@]} > 0 )) || reports=("$script_dir/../docs/reviews")
  [[ -n "$out" ]] || out="-"
  local d abs heads="" rows="$work/rows.tsv" excl="$work/excl.tsv" items="$work/items.tsv" leadfix=0
  : > "$rows"; : > "$excl"; : > "$items"
  for d in "${reports[@]}"; do
    [[ -d "$d" ]] || die "${d}: 디렉터리 없음"
  done
  local f name n lf hline ex date summ sp0 sp1 head pl ntier miss fp
  for d in "${reports[@]}"; do
    abs=$(cd "$d" && pwd)
    n=0; lf=0
    while IFS= read -r f; do
      name=$(basename "$f")
      case "$name" in .*) continue ;; esac
      if [[ "$name" == *.lead-fix.md ]]; then lf=$((lf + 1)); continue; fi
      n=$((n + 1))
      scan_report "$f" "$since" > "$work/one.tsv"
      hline=$(grep '^H	' "$work/one.tsv")
      IFS='	' read -r _ ex date summ sp0 sp1 head pl ntier miss fp <<<"$hline"
      if [[ "$ex" != "-" ]]; then
        printf '%s\t%s\n' "$f" "$ex" >> "$excl"
        continue
      fi
      awk -F'\t' -v f="$f" -v date="$date" -v pl="$pl" '
        $1 == "I" { c[$3]++; formal += $4; spell += $5 }
        END {
          printf "%s\t%s\t%s\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\n", f, date, pl, c["승격만"], c["표도냄"], c["표동의"], c["승격동의"], c["표만"], c["미상"], spell, formal, c["상속제외"]
        }' "$work/one.tsv" >> "$rows"
      grep '^I	' "$work/one.tsv" >> "$items" || true
    done < <(find "$abs" -maxdepth 1 -name '*.md' | LC_ALL=C sort)
    heads="${heads}- 디렉터리: ${abs} — 보고서 ${n}건 (리드 수정 기록 ${lf}건은 보고서가 아니어서 읽지 않음)
"
    leadfix=$((leadfix + lf))
  done
  [[ -s "$rows" ]] || { [[ ! -s "$excl" ]] || awk -F'\t' '{ printf "review-seat-promotion-compare: 제외 — %s: %s\n", $1, $2 }' "$excl" >&2; die "보고서 0건 — 읽을 보고서가 하나도 없다"; }

  local table extab totals trigtab last
  table=$(awk -F'\t' '{
      pl = $3; gsub(/;/, ", ", pl)
      printf "| %s | %s | %s | %d | %d | %d | %d | %d | %d | %d | %d | %d |\n", $1, $2, pl, $4, $5, $6, $7, $8, $9, $10, $11, $12 }' "$rows")
  extab=$(awk -F'\t' '{ printf "- %s — %s\n", $1, $2 }' "$excl")
  [[ -n "$extab" ]] || extab="- 없음"
  totals=$(awk -F'\t' '{ r++; for (i = 4; i <= 12; i++) t[i] += $i }
    END { printf "%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\n", r, t[4], t[5], t[6], t[7], t[8], t[9], t[10], t[11], t[12] }' "$rows")
  local nrep c1 c2 c3 c4 c5 cu csp cf cinh nitems
  IFS='	' read -r nrep c1 c2 c3 c4 c5 cu csp cf cinh <<<"$totals"
  nitems=$((c1 + c2 + c3 + c4 + c5 + cu))
  trigtab=$(awk -F'\t' '$3 == "승격만" && $7 != "-" { m = split($7, q, ","); for (k = 1; k <= m; k++) { if (!(q[k] in t)) o[++n] = q[k]; t[q[k]]++ } }
    END { for (i = 1; i <= n; i++) for (j = i + 1; j <= n; j++) if (o[j] < o[i]) { x = o[i]; o[i] = o[j]; o[j] = x }
          for (i = 1; i <= n; i++) printf "| %s | %d |\n", o[i], t[o[i]] }' "$items")
  [[ -n "$trigtab" ]] || trigtab="| - | 0 |"
  last="# observe: 보고서=${nrep} 항목=${nitems} 승격만=${c1} 표도냄=${c2} 표동의=${c3} 승격동의=${c4} 표만=${c5} 미상=${cu} 상속제외=${cinh}"

  cat > "$work/observe.md" <<EOF
# 리뷰 승격 좌석 관찰 집계

${heads}- 기간: ${since:-처음부터}
- 항목은 P0·P1 절의 0열 \`- **[\` 줄이다. 귀속은 \`**좌석**\` 줄, 없으면 항목 줄 끝 꼬리에서 읽는다. 이 집계는 판정을 내지 않는다 — 판정은 쌍 재리뷰가 한다

## 보고서별

| 보고서 | 리뷰 날짜 | 승격 좌석(모델=지표) | 승격만 | 표도 냄 | 표 동의 | 승격 동의 | 표만 | 미상 | 철자 불일치 | 정식 필드 | 상속 제외 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
${table}

## 제외한 보고서

${extab}

## 합계

| 보고서 | 항목 | 승격만 | 표도 냄 | 표 동의 | 승격 동의 | 표만 | 미상 | 철자 불일치 | 정식 필드 | 상속 제외 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| ${nrep} | ${nitems} | ${c1} | ${c2} | ${c3} | ${c4} | ${c5} | ${cu} | ${csp} | ${cf} | ${cinh} |

## 승격만 — 지표별 (한 항목은 낸 승격 좌석들의 지표 합집합의 지표마다 한 번)

| 지표 | 항목 |
| --- | --- |
${trigtab}

${last}
EOF
  emit "$work/observe.md"
}

# ---------- pairs ------------------------------------------------------------

run_pairs() {
  [[ -n "$exp_dir" ]] || usage "pairs needs --exp <dir>"
  [[ -d "$exp_dir" ]] || die "experiment directory not found: $exp_dir"
  exp_dir=$(cd "$exp_dir" && pwd)
  [[ -n "$out" ]] || out="$exp_dir/report.md"
  local samples="$exp_dir/samples.tsv"
  [[ -f "$samples" ]] || die "no samples.tsv in $exp_dir"

  local table="" reasons="" rows="" valid=0 diffsets=0 praised_t=0 only_t=0
  local n rep base head st why seats br f hline ex date summ sp0 sp1 rhead pl ntier miss fp pr po
  while IFS='	' read -r n rep base head st why seats; do
    [[ "$n" =~ ^[0-9]+$ ]] || continue
    if [[ "$st" != "유효" ]]; then
      reasons="${reasons}- 표본 ${n} (${rep}): 무효 — ${why:-사유 없음}
"
      table="${table}| ${n} | ${rep} | - | 무효 | - | - | - | - |
"
      continue
    fi
    local line="${n}"
    for br in $BRANCHES; do
      f="$exp_dir/reports/${n}-${br}.md"
      [[ -f "$f" ]] || die "sample ${n} is valid but has no report: $f"
      scan_report "$f" > "$work/one.tsv"
      hline=$(grep '^H	' "$work/one.tsv")
      IFS='	' read -r _ ex date summ sp0 sp1 rhead pl ntier miss fp <<<"$hline"
      [[ "$summ" == "정규" ]] || die "sample ${n} ${br}: the 발견 요약 line is not regular (${summ})"
      pr=$(awk -F'\t' '$1 == "I" && $3 != "상속제외" && $6 == 1 { c++ } END { print c + 0 }' "$work/one.tsv")
      po=$(awk -F'\t' '$1 == "I" && $3 == "승격만" { c++ } END { print c + 0 }' "$work/one.tsv")
      praised_t=$((praised_t + pr)); only_t=$((only_t + po))
      table="${table}| ${n} | ${rep} | ${br} | 유효 | ${sp0} | ${sp1} | ${pr} | ${po} |
"
      line="${line}	$((sp0 + sp1))	${sp0}"
    done
    if [[ -n "$seats" && "$seats" != "-" ]]; then
      if awk -v s="$seats" 'BEGIN {
          m = split(s, g, ";")
          for (i = 1; i <= m; i++) { e = index(g[i], "="); v = substr(g[i], e + 1); k = split(v, q, ",")
            for (a = 1; a <= k; a++) for (b = a + 1; b <= k; b++) if (q[b] < q[a]) { t = q[a]; q[a] = q[b]; q[b] = t }
            w = ""; for (a = 1; a <= k; a++) w = w "," q[a]; set[i] = w }
          for (i = 2; i <= m; i++) if (set[i] != set[1]) exit 0
          exit 1 }'; then diffsets=$((diffsets + 1)); fi
    fi
    valid=$((valid + 1))
    rows="${rows}${line}
"
  done < "$samples"

  # rows: n a a0 s s0 b b0 (branch order opus-1 sonnet opus-2)
  local verdict why_text veto_section noise_section calc
  if (( valid != SAMPLES_REQUIRED )); then
    reasons="${reasons}- 유효 표본이 ${valid}건이다 — 판정은 정확히 ${SAMPLES_REQUIRED}건일 때만 낸다
"
    verdict="판정 불가(표본 수)"
    veto_section="계산하지 않음 — 판정 불가 사유가 있다."
    noise_section="계산하지 않음 — 판정 불가 사유가 있다."
    why_text="$reasons"
  else
    calc=$(printf '%s' "$rows" | awk -F'\t' -v vsm_="$VETO_SAMPLE_MIN" -v vsum="$VETO_SUM_MIN" -v sig="$SIGNAL_MIN" \
      -v df="$DROP_FLOOR" -v nf="$NOISE_FACTOR" -v nm="$NOISE_MAX" '
      function med(x, c,   i, j, t, a) {
        for (i = 1; i <= c; i++) a[i] = x[i]
        for (i = 1; i <= c; i++) for (j = i + 1; j <= c; j++) if (a[j] < a[i]) { t = a[i]; a[i] = a[j]; a[j] = t }
        return (c % 2 == 1) ? a[(c + 1) / 2] : (a[c / 2] + a[c / 2 + 1]) / 2
      }
      NF >= 7 {
        c++
        a = $2; a0 = $3; s = $4; s0 = $5; b = $6; b0 = $7
        o = (a + b) / 2; so += o
        var[c] = (a > b ? a - b : b - a) / (o + 1)
        drop[c] = (o - s) / (o + 1)
        m0 = (a0 < b0 ? a0 : b0)
        if (s0 < m0) { vd++; vs += m0 - s0 }
        printf "D\t%s\t%d\t%d\t%d\t%d\t%d\t%d\t%.1f\t%.3f\t%.3f\n", $1, a, b, s, a0, b0, s0, o, var[c], drop[c]
      }
      END {
        W = med(var, c); D = med(drop, c)
        T = nf * W; if (T < df) T = df
        veto = (vd + 0 >= vsm_ && vs + 0 >= vsum) ? 1 : 0
        # A threshold met exactly is not crossed; the margin absorbs float noise.
        if (veto) v = "유지:veto"
        else if (so < sig - 1e-9) v = "판정 불가(신호 부족):signal"
        else if (W > nm + 1e-9) v = "판정 불가(변동 폭 과다):noise"
        else if (D > T + 1e-9) v = "유지:drop"
        else v = "축소 권고:keep"
        printf "S\t%d\t%d\t%d\t%.1f\t%.3f\t%.3f\t%.3f\t%s\n", vd + 0, vs + 0, veto, so, W, D, T, v
      }')
    local vd vs veto so W D T vv tag dtab=""
    IFS='	' read -r _ vd vs veto so W D T vv <<<"$(printf '%s\n' "$calc" | grep '^S	')"
    while IFS='	' read -r _ dn da db ds da0 db0 ds0 do_ dvar ddrop; do
      dtab="${dtab}| ${dn} | ${da} | ${db} | ${ds} | ${da0} | ${db0} | ${ds0} | ${do_} | ${dvar} | ${ddrop} |
"
    done < <(printf '%s\n' "$calc" | grep '^D	')
    verdict="${vv%%:*}"; tag="${vv##*:}"
    local vword="아니오"; (( veto == 1 )) && vword="예"
    veto_section="- s0 < min(a0, b0) 인 표본: ${vd} (문턱 ${VETO_SAMPLE_MIN} 이상)
- Σ max(0, min(a0, b0) − s0): ${vs} (문턱 ${VETO_SUM_MIN} 이상)
- 발동: ${vword}"
    noise_section="| 표본 | a (opus-1) | b (opus-2) | s (sonnet) | a0 | b0 | s0 | o | 변동 | 하락 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
${dtab}
- Σ o: ${so} (하한 ${SIGNAL_MIN})
- W = 변동 중앙값: ${W} (문턱 ${NOISE_MAX})
- D = 하락 중앙값: ${D} (문턱 max(${DROP_FLOOR}, ${NOISE_FACTOR} × W) = ${T})"
    case "$tag" in
      veto) why_text="- P0 거부권이 발동했다 — 판정 순서상 신호·변동 폭 검사보다 앞선다" ;;
      signal) why_text="- 신호 부족 — Σ o = ${so} 가 하한 ${SIGNAL_MIN} 보다 작다" ;;
      noise) why_text="- 변동 폭 과다 — W = ${W} 가 문턱 ${NOISE_MAX} 를 넘는다" ;;
      drop) why_text="- 하락 D = ${D} 가 문턱 ${T} 를 넘는다" ;;
      *) why_text="- 거부권이 발동하지 않았고 Σ o = ${so} 는 하한 이상, W = ${W} 는 ${NOISE_MAX} 이하, D = ${D} 는 ${T} 이하다" ;;
    esac
    why_text="${why_text}
"
  fi

  cat > "$work/report.md" <<EOF
# 리뷰 승격 좌석 쌍 재리뷰 판정 보고서

- 실험: $(basename "$exp_dir")
- 상수: SAMPLES_REQUIRED=${SAMPLES_REQUIRED} · VETO_SAMPLE_MIN=${VETO_SAMPLE_MIN} · VETO_SUM_MIN=${VETO_SUM_MIN} · SIGNAL_MIN=${SIGNAL_MIN} · DROP_FLOOR=${DROP_FLOOR} · NOISE_FACTOR=${NOISE_FACTOR} · NOISE_MAX=${NOISE_MAX}
- 주 지표는 갈래 보고서 \`발견 요약\` 의 P0+P1 수, 거부권은 P0 수다

## 표본별 지표

| 표본 | 보고서 | 갈래 | 상태 | P0 | P1 | 승격 좌석이 낸 항목 | 승격만 |
| --- | --- | --- | --- | --- | --- | --- | --- |
${table}
## P0 거부권

${veto_section}

## 신호·변동 폭과 하락

${noise_section}

## 보조 지표 (문턱 없음)

- 승격 좌석이 낸 항목 수(유효 표본 갈래 합): ${praised_t}
- 승격만 항목 수(유효 표본 갈래 합): ${only_t}
- 갈래끼리 승격 좌석 집합이 다른 유효 표본: ${diffsets}

## 판정

**판정**: ${verdict}

${why_text}
# verdict: ${verdict}
EOF
  emit "$work/report.md"
}

case "$cmd" in
  observe) run_observe ;;
  pairs) run_pairs ;;
  scan) run_scan ;;
esac
exit 0
