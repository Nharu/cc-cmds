#!/usr/bin/env bash
# Run the gate sections a change touched in more than one context, and say
# whether each one behaves the same in all of them.
#
# A SECTION THAT LEANS ON ANOTHER ONE STILL PASSES IN THE FULL RUN. It fails, or
# passes while measuring less, only in a cut that leaves the other section out
# or puts a third one in front of it — and the shard partition decides which
# cut that is, so the failure turns up months later on someone else's change.
# This script makes those cuts on purpose for every changed section X: two solo
# runs of X and its needs closure, each a process of its own, the second under
# a TMPDIR whose path carries every run-id string the fixtures use; X's own row;
# and every row X was laid over. A solo that differs says X leans on another
# section's body or on the path it runs under; a laid-over row that differs says
# X leans on, or leaves behind, state another section makes.
#
# WHAT IS COMPARED. Each context's cut writes `rec.tsv` (one
# `<section><TAB><PASS|FAIL|SKIP|NOISE><TAB><label>` line per assertion and per
# oracle noise line) and, for the sections it traced, `trace-<id>.lines` (the
# (file, line) pairs the section executed, the cut itself written `CUT`) with
# `linemap.tsv` mapping the cut's lines back to the suite's. X's record lines
# are compared as they stand — in their order, duplicates kept, no path or time
# normalised away: the second solo's TMPDIR exists to make a path dependence
# show. A label that differs between the two solos is calibration (a label that
# carries a time or a temporary path) and is not compared at that position; a
# verdict that differs between them is a divergence. A line only one context
# has is a divergence, NOISE lines included, and so is SKIP against PASS. The
# line sets are compared on original line numbers, without the lines marked
# `# gate-isolation: 변동` and without the lines the two solos already differ in.
# A failure outside any section (a prelude, the epilogue) is X's in a solo cut
# and the row's own in a row, reported and not attributed. A failure of a
# regular section Y of a row X was laid over is X's: "Y failed in the row X was
# laid over".
#
# Usage:
#   bash scripts/gate-isolation.sh compare --dir D --plan F [--out F] [--suite F]
#       D/iso-<K>/ holds what row K of the plan table F ran (CI downloads the
#       `iso-<K>` artifacts there); prints `<id><TAB><같음|갈림|맥락 없음>
#       <TAB><context><TAB><first difference>` per changed section
#   bash scripts/gate-isolation.sh solos --out D --spec SPEC [--timing-out F]
#                                       [--bash B] [--suite F] [--tmp DIR]
#       runs the solos of one row (its fifth column, `<1|2>:<X>,<closure>`
#       entries joined by `;`) into D/solo<n>-<X>/, each between an
#       `@iso:@start` and an `@iso:@end` marker when --timing-out is given;
#       a solo's exit code is kept in its directory and never returned
#   bash scripts/gate-isolation.sh check --sections C [--with W] [--out D]
#                                       [--bash B] [--suite F] [--census F]
#       the local entry: the solos of each id of C and one cut of C (and W)
#   bash scripts/gate-isolation.sh sweep [--out D] [--chunk-s S] [--jobs J]
#                                       [--timing F] [--bash B]
#       every section: its solos, and the suite cut into runs of consecutive
#       sections of at most S seconds of planned load (default 5400), J at a
#       time (default 4); resumes in the same D
#   bash scripts/gate-isolation.sh capacity --base REV [--timing F]
#                                       [--shards S] [--iso-extra E]
#       the changed sections between REV and the tree, placed the way CI's
#       plan job would: exit 5 when their solos do not fit
#   bash scripts/gate-isolation.sh --self-test
#
# THE TRACE NEEDS BASH 4.1. `BASH_XTRACEFD` arrived there, so `check` and
# `sweep` refuse an older interpreter (exit 2) and name the variable that
# points them at a newer one. This script itself runs on bash 3.2.
#
# Exit codes: 0 every section the same, 1 a divergence, a missing context or
# fewer rows than the plan placed work on, 2 usage, an old bash or a missing
# input, 5 the isolation work did not fit ("격리 검사 용량 초과").

set -uo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)

# THE SECOND SOLO'S TMPDIR COMPONENT. Every run-id string of three bytes or
# fewer the suite's fixtures use (the `R<n>` placeholders), so a fixture that
# substitutes its run id over a whole file also rewrites a temporary path that
# file carries — the defect a random mktemp suffix only trips when it happens
# to contain the id, which only a short string can. The 17-byte date-and-hash
# ids never turn up in a path by chance, so they are left out: they would only
# lengthen the path, and a long TMPDIR puts the second solo in a context of its
# own (a section that fails on path length alone is no dependency on another
# section). The component stays at 60 bytes or fewer. The self-test checks that
# every short run-id string of scripts/test-gate.sh is in here and the length
# bound; a fixture that adds a new short one has to add it here too.
ISO_TOKEN='iso-R1R2R3R4R5R55R57R68'

iso_usage() {
  printf 'gate-isolation: 사용법 — compare --dir D --plan F [--out F] / solos --out D --spec S [--timing-out F] / check --sections C [--with W] [--out D] / sweep [--out D] [--chunk-s S] [--jobs J] / capacity --base REV / --self-test (공통: --bash B, --suite F, --census F, --timing F)\n' >&2
  exit 2
}

iso_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

# A comma list of section ids, or nothing. Anything outside the selector's own
# id charset is refused here rather than handed to it.
iso_ids_ok() {
  case "$1" in
    *[!A-Za-z0-9_,-]*) return 1 ;;
  esac
  return 0
}

# Whether the interpreter can trace: bash 4.1 or newer.
iso_bash_ok() {
  "$1" -c '[ "${BASH_VERSINFO[0]}" -gt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -ge 1 ]; }' 2>/dev/null
}

iso_bash_refuse() {
  printf 'gate-isolation: %s 는 bash 4.1 미만이라 절 범위 추적(BASH_XTRACEFD)을 할 수 없습니다 — ISO_BASH=<bash 4.1 이상의 경로> 로 다시 부르세요\n' "$1" >&2
  return 2
}

# THE SELECTOR RUNS ITS CUT WITH THE `bash` ON PATH, so naming an interpreter
# is not enough: a directory holding only a `bash` link to it goes in front of
# PATH for every suite this process starts. Nothing else on PATH moves.
ISO_SHIM=""
iso_use_bash() {
  local b="$1" p
  [ "$b" != "bash" ] || return 0
  [ -z "$ISO_SHIM" ] || return 0
  p=$(command -v "$b" 2>/dev/null) || return 1
  case "$p" in /*) ;; *) p="$(pwd)/$p" ;; esac
  ISO_SHIM=$(mktemp -d "${TMPDIR:-/tmp}/gate-iso-bash.XXXXXX") || return 1
  ln -s "$p" "$ISO_SHIM/bash" || return 1
  PATH="$ISO_SHIM:$PATH"; export PATH
  trap 'rm -rf "$ISO_SHIM"' EXIT
}

# A temporary directory whose path carries no run-id placeholder, for the first
# solo and the rows: a random suffix that happens to hold `R1` would trip the
# very defect the second solo is there to show, in every context at once.
iso_clean_tmp() {
  local base="$1" d i=0
  while [ "$i" -lt 8 ]; do
    d=$(mktemp -d "$base/gate-iso.XXXXXX") || return 1
    case "$d" in
      *R[0-9]*) rm -rf "$d"; i=$((i + 1)) ;;
      *) printf '%s\n' "$d"; return 0 ;;
    esac
  done
  return 1
}

iso_abs() {
  case "$1" in
    /*) printf '%s\n' "$1" ;;
    *) printf '%s/%s\n' "$(pwd)" "$1" ;;
  esac
}

# --- compare -----------------------------------------------------------------

# One changed section against its contexts. CTX has one
# `<name><TAB><solo|own|ovl><TAB><dir><TAB><regular ids of the row>` line per
# context, the two solos first. MARKS has the suite's line numbers that carry
# the `# gate-isolation: 변동` mark.
iso_compare_one() {
  local x="$1" ctx="$2" marks="$3"
  LC_ALL=C awk -v X="$x" -v CTX="$ctx" -v MARKS="$marks" '
    function div(c, m) { if (st != "갈림") { st = "갈림"; wh = nm[c]; fd = m } }
    function miss(c, m) { if (st == "") { st = "맥락 없음"; wh = nm[c]; fd = m } }
    function rec(c, i) { return vv[c, i] " 「" ll[c, i] "」" }
    function seqmsg(a, b, i) { return i "번째 기록 — " nm[a] " " rec(a, i) " · " nm[b] " " rec(b, i) }
    function onlymsg(a, b, i,   w) {
      w = (len[a] > len[b] ? a : b)
      return "한 맥락에만 있는 기록 — " nm[w] " 의 " i "번째 " rec(w, i)
    }
    # Compare context c with the reference r; calibrated positions skip labels.
    function cmpseq(r, c,   i, m) {
      m = (len[r] < len[c] ? len[r] : len[c])
      for (i = 1; i <= m; i++) {
        if (vv[r, i] != vv[c, i]) return seqmsg(r, c, i)
        if (ll[r, i] != ll[c, i] && !(i in cal)) return seqmsg(r, c, i)
      }
      if (len[r] != len[c]) return onlymsg(r, c, m + 1)
      return ""
    }
    # The line set of context c, on original coordinates. 0 when there is none.
    function lsload(c,   f, l, a, r, j, nm_, o, k, n) {
      f = dr[c] "/linemap.tsv"; nm_ = 0
      while ((r = (getline l < f)) > 0) { split(l, a, "\t"); nm_++; ms[nm_] = a[1] + 0; me[nm_] = a[2] + 0; mo[nm_] = a[3] + 0 }
      close(f)
      f = dr[c] "/trace-" X ".lines"
      r = (getline l < f)
      if (r < 0) return 0
      n = 0
      while (r > 0) {
        split(l, a, "\t")
        if (a[1] == "CUT") {
          o = 0
          for (j = 1; j <= nm_; j++) if (a[2] + 0 >= ms[j] && a[2] + 0 <= me[j]) { o = mo[j] + a[2] - ms[j]; break }
          if (o == 0 || (o in mk)) { r = (getline l < f); continue }
          k = "test-gate.sh 줄 " o
        } else k = a[1] " 줄 " a[2]
        if (!((c, k) in ls)) { ls[c, k] = 1; n++; lk[c, n] = k }
        r = (getline l < f)
      }
      close(f)
      nk[c] = n
      return 1
    }
    BEGIN {
      if (MARKS != "") while ((getline l < MARKS) > 0) mk[l + 0] = 1
      n = 0
      while ((getline l < CTX) > 0) { n++; split(l, a, "\t"); nm[n] = a[1]; kd[n] = a[2]; dr[n] = a[3]; rg[n] = a[4] }
      st = ""; wh = ""; fd = ""
      for (c = 1; c <= n; c++) {
        len[c] = 0; got[c] = 0
        if (dr[c] == "") { miss(c, "계획에 이 맥락이 없습니다"); continue }
        f = dr[c] "/rec.tsv"
        r = (getline l < f)
        if (r < 0) { miss(c, "기록 파일이 없습니다 — 그 실행이 돌지 않았거나 기록 고리가 꺼졌습니다"); continue }
        got[c] = 1
        while (r > 0) {
          k = split(l, a, "\t"); s = a[1]; v = a[2]; lb = (k >= 3 ? a[3] : "")
          if (s == X) { len[c]++; vv[c, len[c]] = v; ll[c, len[c]] = lb }
          else if (v == "FAIL" && (s ~ /^@/ || s == "-")) {
            if (kd[c] == "solo") div(c, "절 밖 실패 — " s " 「" lb "」")
            else print "gate-isolation: " nm[c] " 의 절 밖 실패(" s ")는 행 자신의 실패라 " X " 에 귀속하지 않습니다 — " lb > "/dev/stderr"
          }
          else if (v == "FAIL" && kd[c] == "ovl" && index("," rg[c] ",", "," s ",") > 0) div(c, X " 가 실린 행에서 " s " 실패 — 「" lb "」")
          r = (getline l < f)
        }
        close(f)
      }
      ref = 0; for (c = 1; c <= n; c++) if (got[c]) { ref = c; break }
      both = (n >= 2 && kd[1] == "solo" && kd[2] == "solo" && got[1] && got[2])
      if (both) {
        m = (len[1] < len[2] ? len[1] : len[2]); stop = 0
        for (i = 1; i <= m; i++) {
          if (vv[1, i] != vv[2, i]) { div(2, seqmsg(1, 2, i)); stop = 1; break }
          if (ll[1, i] != ll[2, i]) cal[i] = 1
        }
        if (!stop && len[1] != len[2]) div(2, onlymsg(1, 2, m + 1))
      }
      if (ref) for (c = 1; c <= n; c++) {
        if (c == ref || !got[c] || (both && c == 2)) continue
        d = cmpseq(ref, c)
        if (d != "") div(c, d)
      }
      # The line sets, when the reference context traced X.
      if (ref && lsload(ref)) {
        for (c = 1; c <= n; c++) {
          if (c == ref || !got[c]) continue
          if (!lsload(c)) { miss(c, "줄 집합 파일이 없습니다"); continue }
        }
        if (both) {
          for (i = 1; i <= nk[1]; i++) if (!((2, lk[1, i]) in ls)) vary[lk[1, i]] = 1
          for (i = 1; i <= nk[2]; i++) if (!((1, lk[2, i]) in ls)) vary[lk[2, i]] = 1
        }
        for (c = 1; c <= n; c++) {
          if (c == ref || !got[c] || !(c in nk) || (both && c == 2)) continue
          best = ""; bw = ""
          for (i = 1; i <= nk[c]; i++) { k = lk[c, i]; if (!((ref, k) in ls) && !(k in vary) && (best == "" || k < best)) { best = k; bw = c } }
          for (i = 1; i <= nk[ref]; i++) { k = lk[ref, i]; if (!((c, k) in ls) && !(k in vary) && (best == "" || k < best)) { best = k; bw = ref } }
          if (best != "") div(c, "줄 집합 — " best " 이 " nm[bw] " 에서만 실행됐습니다")
        }
      }
      if (st == "") { st = "같음"; wh = "맥락 " n "개"; fd = "-" }
      printf "%s\t%s\t%s\t%s\n", X, st, wh, fd
    }
  ' < /dev/null
}

iso_compare() {
  local dir="" plan="" out="" suite="$repo_root/scripts/test-gate.sh"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --dir)   [ "$#" -ge 2 ] || iso_usage; dir="$2"; shift 2 ;;
      --plan)  [ "$#" -ge 2 ] || iso_usage; plan="$2"; shift 2 ;;
      --out)   [ "$#" -ge 2 ] || iso_usage; out="$2"; shift 2 ;;
      --suite) [ "$#" -ge 2 ] || iso_usage; suite="$2"; shift 2 ;;
      *) iso_usage ;;
    esac
  done
  [ -n "$dir" ] && [ -n "$plan" ] || iso_usage
  if [ ! -f "$plan" ]; then printf 'gate-isolation: 계획 표가 없습니다: %s\n' "$plan" >&2; return 2; fi
  local T rc=0 xs x k
  T=$(mktemp -d "${TMPDIR:-/tmp}/gate-iso-cmp.XXXXXX") || return 2
  grep -n '# gate-isolation: 변동' "$suite" 2>/dev/null | cut -d: -f1 > "$T/marks"

  # Every row the plan put isolation work on has to have come back: a row whose
  # artifact is missing would otherwise drop its contexts without a word.
  awk -F '\t' '$4 != "" || $5 != "" || $6 != "" { print $1 }' "$plan" > "$T/work"
  : > "$T/gone"
  while read -r k; do
    [ -n "$k" ] || continue
    [ -d "$dir/iso-$k" ] || printf '%s\n' "$k" >> "$T/gone"
  done < "$T/work"
  if [ -s "$T/gone" ]; then
    printf 'gate-isolation: 받은 격리 작업 행 %s개가 계획의 %s개보다 적습니다 — 빠진 행: %s\n' \
      "$(( $(grep -c . "$T/work") - $(grep -c . "$T/gone") ))" "$(grep -c . "$T/work")" "$(tr '\n' ' ' < "$T/gone")" >&2
    rc=1
  fi

  # The changed sections: every X with a solo, in the order the plan names them.
  xs=$(awk -F '\t' '{ n = split($5, s, ";"); for (i = 1; i <= n; i++) { e = s[i]; sub(/^[0-9]+:/, "", e); sub(/,.*$/, "", e); if (e != "" && !(e in seen)) { seen[e] = 1; print e } } }' "$plan")
  : > "$T/result"
  for x in $xs; do
    awk -F '\t' -v X="$x" -v D="$dir" '
      {
        n = split($5, s, ";")
        for (i = 1; i <= n; i++) {
          e = s[i]; r = e; sub(/:.*$/, "", r); l = e; sub(/^[^:]*:/, "", l); sub(/,.*$/, "", l)
          if (l == X) sol[r] = D "/iso-" $1 "/solo" r "-" X
        }
        if (index("," $6 ",", "," X ",") > 0) rows = rows "행 " $1 " (제 행)\town\t" D "/iso-" $1 "/row\t" $3 "\n"
        if (index("," $4 ",", "," X ",") > 0) rows = rows "행 " $1 " (얹힘)\tovl\t" D "/iso-" $1 "/row\t" $3 "\n"
      }
      END { printf "단독 1\tsolo\t%s\t\n단독 2\tsolo\t%s\t\n%s", sol[1], sol[2], rows }
    ' "$plan" > "$T/ctx"
    iso_compare_one "$x" "$T/ctx" "$T/marks" >> "$T/result"
  done
  cat "$T/result"
  [ -z "$out" ] || cp "$T/result" "$out"
  local same div none
  same=$(awk -F '\t' '$2 == "같음"' "$T/result" | grep -c . || true)
  div=$(awk -F '\t' '$2 == "갈림"' "$T/result" | grep -c . || true)
  none=$(awk -F '\t' '$2 == "맥락 없음"' "$T/result" | grep -c . || true)
  printf 'gate-isolation: 바뀐 절 %s개 — 같음 %s · 갈림 %s · 맥락 없음 %s\n' \
    "$(grep -c . "$T/result" || true)" "${same:-0}" "${div:-0}" "${none:-0}" >&2
  if [ "${div:-0}" != "0" ] || [ "${none:-0}" != "0" ]; then rc=1; fi
  rm -rf "$T"
  return "$rc"
}

# --- solos -------------------------------------------------------------------

iso_solos() {
  local out="" spec="" tm="" bsh="${ISO_BASH:-bash}" suite="$repo_root/scripts/test-gate.sh" tbase="${TMPDIR:-/tmp}"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --out)        [ "$#" -ge 2 ] || iso_usage; out="$2"; shift 2 ;;
      --spec)       [ "$#" -ge 2 ] || iso_usage; spec="$2"; shift 2 ;;
      --timing-out) [ "$#" -ge 2 ] || iso_usage; tm="$2"; shift 2 ;;
      --bash)       [ "$#" -ge 2 ] || iso_usage; bsh="$2"; shift 2 ;;
      --suite)      [ "$#" -ge 2 ] || iso_usage; suite="$2"; shift 2 ;;
      --tmp)        [ "$#" -ge 2 ] || iso_usage; tbase="$2"; shift 2 ;;
      *) iso_usage ;;
    esac
  done
  [ -n "$out" ] || iso_usage
  iso_use_bash "$bsh" || return 2
  out=$(iso_abs "$out"); mkdir -p "$out" || return 2
  local e rep list x d base t rc
  local IFS_OLD="$IFS"
  IFS=';'; set -- $spec; IFS="$IFS_OLD"
  for e in "$@"; do
    [ -n "$e" ] || continue
    rep=${e%%:*}; list=${e#*:}; x=${list%%,*}
    case "$rep" in 1|2) ;; *) printf 'gate-isolation: 단독 항목의 회차가 1 이나 2 가 아닙니다: %s\n' "$e" >&2; return 2 ;; esac
    if [ -z "$x" ] || ! iso_ids_ok "$list"; then printf 'gate-isolation: 단독 항목을 읽을 수 없습니다: %s\n' "$e" >&2; return 2; fi
    d="$out/solo$rep-$x"
    base=$(iso_clean_tmp "$tbase") || { printf 'gate-isolation: 단독의 임시 디렉터리를 만들지 못했습니다\n' >&2; return 2; }
    t="$base"
    if [ "$rep" = "2" ]; then t="$base/$ISO_TOKEN"; mkdir -p "$t" || return 2; fi
    [ -z "$tm" ] || printf '@iso:@start\t%s\n' "$(date +%s)" >> "$tm"
    rc=0
    if [ -n "$tm" ]; then
      env -u CC_GATE_ISO_OVERLAY CC_GATE_TIMING_OUT="$tm" CC_GATE_ISO_OUT="$d" CC_GATE_ISO_TRACE="$x" CC_GATE_ISO_SOLO=1 TMPDIR="$t" \
        "$bsh" "$suite" --sections "$list" > "$d.out" 2>&1 || rc=$?
    else
      env -u CC_GATE_ISO_OVERLAY -u CC_GATE_TIMING_OUT CC_GATE_ISO_OUT="$d" CC_GATE_ISO_TRACE="$x" CC_GATE_ISO_SOLO=1 TMPDIR="$t" \
        "$bsh" "$suite" --sections "$list" > "$d.out" 2>&1 || rc=$?
    fi
    [ -z "$tm" ] || printf '@iso:@end\t%s\n' "$(date +%s)" >> "$tm"
    mkdir -p "$d" && printf '%s\n' "$rc" > "$d/rc"
    rm -rf "$base"
  done
  return 0
}

# The solo entries for the comma list C, with the needs closure the plan job
# would give them: one row holding the whole suite leaves no room, so every
# solo lands on an extra row and the fifth column of those rows is the answer.
iso_solo_spec() {
  local suite="$1" census="$2" c="$3" n
  n=$(printf '%s\n' "$c" | tr ',' '\n' | grep -c . || true)
  bash "$script_dir/gate-shard.sh" --suite "$suite" --census "$census" --shards 1 --table \
    --isolate "$c" --iso-extra "$(( 2 * n ))" 2>/dev/null \
    | awk -F '\t' '$5 != "" { printf "%s%s", (o++ ? ";" : ""), $5 }'
  return "${PIPESTATUS[0]}"
}

# --- check -------------------------------------------------------------------

iso_check() {
  local sections="" with="" out="" bsh="${ISO_BASH:-bash}" suite="$repo_root/scripts/test-gate.sh" census="$repo_root/scripts/gate-census.tsv"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --sections) [ "$#" -ge 2 ] || iso_usage; sections="$2"; shift 2 ;;
      --with)     [ "$#" -ge 2 ] || iso_usage; with="$2"; shift 2 ;;
      --out)      [ "$#" -ge 2 ] || iso_usage; out="$2"; shift 2 ;;
      --bash)     [ "$#" -ge 2 ] || iso_usage; bsh="$2"; shift 2 ;;
      --suite)    [ "$#" -ge 2 ] || iso_usage; suite="$2"; shift 2 ;;
      --census)   [ "$#" -ge 2 ] || iso_usage; census="$2"; shift 2 ;;
      *) iso_usage ;;
    esac
  done
  if [ -z "$sections" ] || ! iso_ids_ok "$sections" || ! iso_ids_ok "$with"; then
    printf 'gate-isolation: --sections 에 절 id 의 쉼표 목록을 주세요 (ISO_SECTIONS)\n' >&2; return 2
  fi
  iso_bash_ok "$bsh" || { iso_bash_refuse "$bsh"; return 2; }
  iso_use_bash "$bsh" || return 2
  if [ -z "$out" ]; then out=$(mktemp -d "${TMPDIR:-/tmp}/gate-isolation.XXXXXX") || return 2; fi
  out=$(iso_abs "$out"); mkdir -p "$out/iso-1" || return 2
  local spec rc ids tbase
  spec=$(iso_solo_spec "$suite" "$census" "$sections"); rc=$?
  if [ "$rc" != "0" ] || [ -z "$spec" ]; then
    printf 'gate-isolation: 단독의 needs 폐포를 풀지 못했습니다 (gate-shard 종료 %s)\n' "$rc" >&2; return 2
  fi
  ids=$(printf '%s,%s\n' "$sections" "$with" | tr ',' '\n' | awk 'NF && !s[$0]++' | paste -sd, -)
  printf '1\t0\t%s\t\t%s\t%s\n' "$ids" "$spec" "$sections" > "$out/plan.tsv"
  printf 'gate-isolation: 맥락 — 단독 %s개 · 한 컷 「%s」 · 결과 %s\n' "$(printf '%s' "$spec" | tr ';' '\n' | grep -c .)" "$ids" "$out" >&2
  tbase=$(iso_clean_tmp "${TMPDIR:-/tmp}") || return 2
  rc=0
  env -u CC_GATE_ISO_OVERLAY -u CC_GATE_ISO_SOLO -u CC_GATE_TIMING_OUT CC_GATE_ISO_OUT="$out/iso-1/row" CC_GATE_ISO_TRACE="$sections" TMPDIR="$tbase" \
    "$bsh" "$suite" --sections "$ids" > "$out/iso-1/row.out" 2>&1 || rc=$?
  printf '%s\n' "$rc" > "$out/iso-1/row.rc"
  rm -rf "$tbase"
  iso_solos --out "$out/iso-1" --spec "$spec" --bash "$bsh" --suite "$suite" || return $?
  iso_compare --dir "$out" --plan "$out/plan.tsv" --out "$out/result.tsv" --suite "$suite"
}

# --- timing source -----------------------------------------------------------

# The measured times the plan job would weigh with: ISO_TIMING when given, the
# median of the latest master artifacts otherwise. Prints the file's path.
iso_timing() {
  local given="$1" work="$2" got id c files=""
  if [ -n "$given" ]; then
    if [ -f "$given" ]; then printf '%s\n' "$given"; return 0; fi
    printf 'gate-isolation: 타이밍 표가 없습니다: %s\n' "$given" >&2; return 2
  fi
  mkdir -p "$work/src"
  if got=$(bash "$script_dir/ci-duration.sh" fetch-base --name gate-timing --workflow gate.yml --count 3 --out "$work/src" 2>/dev/null); then
    while read -r id c; do
      [ -n "$id" ] && [ -f "$work/src/$id/gate-timing.tsv" ] && files="$files $work/src/$id/gate-timing.tsv"
    done <<EOF
$got
EOF
  fi
  # shellcheck disable=SC2086
  if [ -n "$files" ] && bash "$script_dir/gate-timing.sh" median --out "$work/timing.tsv" $files >/dev/null 2>&1; then
    printf '%s\n' "$work/timing.tsv"; return 0
  fi
  printf 'gate-isolation: 타이밍 원천(gate-timing 아티팩트)을 받지 못했습니다 — ISO_TIMING=<타이밍 표 파일> 로 주세요\n' >&2
  return 2
}

# --- capacity ----------------------------------------------------------------

iso_capacity() {
  local base="" timing="${ISO_TIMING:-}" shards=26 extra=8 suite="$repo_root/scripts/test-gate.sh"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --base)      [ "$#" -ge 2 ] || iso_usage; base="$2"; shift 2 ;;
      --timing)    [ "$#" -ge 2 ] || iso_usage; timing="$2"; shift 2 ;;
      --shards)    [ "$#" -ge 2 ] || iso_usage; shards="$2"; shift 2 ;;
      --iso-extra) [ "$#" -ge 2 ] || iso_usage; extra="$2"; shift 2 ;;
      *) iso_usage ;;
    esac
  done
  [ -n "$base" ] || { printf 'gate-isolation: --base 에 비교할 리비전을 주세요 (BASE)\n' >&2; return 2; }
  local T rc c tf
  T=$(mktemp -d "${TMPDIR:-/tmp}/gate-iso-cap.XXXXXX") || return 2
  if ! (cd "$repo_root" && git show "$base:scripts/test-gate.sh") > "$T/base.sh" 2>/dev/null \
     || ! bash "$suite" --digests --from "$T/base.sh" > "$T/base.dig" 2>/dev/null \
     || ! bash "$suite" --digests > "$T/head.dig" 2>/dev/null; then
    printf 'gate-isolation: 격리 검사 불가 — 베이스 없음 (%s 의 scripts/test-gate.sh 다이제스트를 내지 못했습니다)\n' "$base" >&2
    rm -rf "$T"; return 2
  fi
  c=$(awk -F '\t' 'FNR == NR { b[$1] = $2; next } !($1 in b) || b[$1] != $2 { printf "%s%s", (n++ ? "," : ""), $1 }' "$T/base.dig" "$T/head.dig")
  printf 'gate-isolation: 바뀐 절 — %s\n' "${c:-없음}"
  if [ -z "$c" ]; then rm -rf "$T"; return 0; fi
  tf=$(iso_timing "$timing" "$T") || { rm -rf "$T"; return 2; }
  rc=0
  bash "$script_dir/gate-shard.sh" --suite "$suite" --shards "$shards" --timing "$tf" --table --isolate "$c" --iso-extra "$extra" \
    > "$T/table" 2> "$T/err" || rc=$?
  grep -E '격리|덮지' "$T/err" | sed 's/^gate-shard: /gate-isolation: /'
  rm -rf "$T"
  if [ "$rc" = "5" ]; then printf 'gate-isolation: 격리 검사 용량 초과 — 바뀐 절을 줄이거나 GATE_ISO_EXTRA 를 올려야 합니다\n' >&2; return 5; fi
  [ "$rc" = "0" ] || return 2
  return 0
}

# --- sweep -------------------------------------------------------------------

# One run of consecutive sections as a row of its own, traced whole. A run that
# dies before its total is cut in two at its middle in file order and both
# halves run again; a single section left alone is replaced by its first solo,
# which is the same cut. Each outcome is a line of `chunks.tsv`.
iso_sweep_chunk() {
  local O="$1" k="$2" ids="$3" bsh="$4" suite="$5" d n tb rc first last h a b
  d="$O/iso-$k"
  n=$(printf '%s\n' "$ids" | tr ',' '\n' | grep -c .)
  first=${ids%%,*}; last=${ids##*,}
  # A run finished in an earlier sweep of the same directory says its line again.
  if [ -f "$d/split" ]; then
    cat "$d/line" >> "$O/chunks.tsv"
    a=$(cut -f1 "$d/split"); b=$(cut -f2 "$d/split")
    iso_sweep_chunk "$O" "$k.1" "$a" "$bsh" "$suite"; iso_sweep_chunk "$O" "$k.2" "$b" "$bsh" "$suite"; return 0
  fi
  if [ -f "$d/done" ]; then cat "$d/line" >> "$O/chunks.tsv"; return 0; fi
  mkdir -p "$d"
  tb=$(iso_clean_tmp "${TMPDIR:-/tmp}") || return 1
  rc=0
  env -u CC_GATE_ISO_OVERLAY -u CC_GATE_ISO_SOLO -u CC_GATE_TIMING_OUT CC_GATE_ISO_OUT="$d/row" CC_GATE_ISO_TRACE="$ids" TMPDIR="$tb" \
    "$bsh" "$suite" --sections "$ids" > "$d/row.out" 2>&1 || rc=$?
  rm -rf "$tb"
  if grep -qE '^test-gate: [0-9]+ passed, [0-9]+ failed$' "$d/row.out"; then
    printf '%s\t%s\t%s\t%s\t%s\t완료\n' "$k" "$first" "$last" "$n" "$ids" > "$d/line"
    cat "$d/line" >> "$O/chunks.tsv"
    printf '%s\n' "$rc" > "$d/done"; return 0
  fi
  if [ "$n" -le 1 ]; then
    printf '%s\t%s\t%s\t%s\t%s\t갈음\n' "$k" "$first" "$last" "$n" "$ids" > "$d/line"
    cat "$d/line" >> "$O/chunks.tsv"
    rm -rf "$d/row"; printf 'replaced\n' > "$d/done"; return 0
  fi
  h=$(( n / 2 ))
  a=$(printf '%s\n' "$ids" | tr ',' '\n' | head -n "$h" | paste -sd, -)
  b=$(printf '%s\n' "$ids" | tr ',' '\n' | tail -n "+$(( h + 1 ))" | paste -sd, -)
  printf '%s\t%s\t%s\t%s\t%s\t나눔 %s|%s\n' "$k" "$first" "$last" "$n" "$ids" "${a##*,}" "${b%%,*}" > "$d/line"
  cat "$d/line" >> "$O/chunks.tsv"
  rm -rf "$d/row"
  printf '%s\t%s\n' "$a" "$b" > "$d/split"
  iso_sweep_chunk "$O" "$k.1" "$a" "$bsh" "$suite"
  iso_sweep_chunk "$O" "$k.2" "$b" "$bsh" "$suite"
}

iso_sweep() {
  local O="${ISO_OUT:-}" chunk="${ISO_CHUNK_S:-5400}" jobs=4 timing="${ISO_TIMING:-}" bsh="${ISO_BASH:-bash}"
  local suite="$repo_root/scripts/test-gate.sh" census="$repo_root/scripts/gate-census.tsv"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --out)     [ "$#" -ge 2 ] || iso_usage; O="$2"; shift 2 ;;
      --chunk-s) [ "$#" -ge 2 ] || iso_usage; chunk="$2"; shift 2 ;;
      --jobs)    [ "$#" -ge 2 ] || iso_usage; jobs="$2"; shift 2 ;;
      --timing)  [ "$#" -ge 2 ] || iso_usage; timing="$2"; shift 2 ;;
      --bash)    [ "$#" -ge 2 ] || iso_usage; bsh="$2"; shift 2 ;;
      --suite)   [ "$#" -ge 2 ] || iso_usage; suite="$2"; shift 2 ;;
      --census)  [ "$#" -ge 2 ] || iso_usage; census="$2"; shift 2 ;;
      *) iso_usage ;;
    esac
  done
  case "$chunk$jobs" in *[!0-9]*) iso_usage ;; esac
  iso_bash_ok "$bsh" || { iso_bash_refuse "$bsh"; return 2; }
  iso_use_bash "$bsh" || return 2
  if [ -z "$O" ]; then O=$(mktemp -d "${TMPDIR:-/tmp}/gate-isolation-sweep.XXXXXX") || return 2; fi
  O=$(iso_abs "$O"); mkdir -p "$O" || return 2
  local commit sha
  commit=$(cd "$repo_root" && git rev-parse HEAD 2>/dev/null || echo -)
  sha=$(iso_sha256 "$suite")
  if [ -f "$O/sweep.meta" ]; then
    if [ "$(cat "$O/sweep.meta")" != "$(printf 'commit\t%s\nsuite\t%s' "$commit" "$sha")" ]; then
      printf 'gate-isolation: %s 는 다른 커밋이나 다른 스위트의 쓸기입니다 — 새 ISO_OUT 을 주세요\n' "$O" >&2
      cat "$O/sweep.meta" >&2; return 2
    fi
    printf 'gate-isolation: %s 에서 이어 돕니다\n' "$O" >&2
  else
    printf 'commit\t%s\nsuite\t%s\n' "$commit" "$sha" > "$O/sweep.meta"
  fi
  local tf ids spec
  tf=$(iso_timing "$timing" "$O") || return 2
  ids=$(bash "$suite" --list 2>/dev/null | cut -d' ' -f1 | paste -sd, -)
  [ -n "$ids" ] || { printf 'gate-isolation: 스위트의 절 목록을 읽지 못했습니다\n' >&2; return 2; }
  if [ ! -s "$O/solos.spec" ]; then
    spec=$(iso_solo_spec "$suite" "$census" "$ids") || { printf 'gate-isolation: 단독의 needs 폐포를 풀지 못했습니다\n' >&2; return 2; }
    printf '%s\n' "$spec" > "$O/solos.spec"
  fi
  spec=$(cat "$O/solos.spec")
  # The runs of consecutive sections, by planned load in file order. An id the
  # timing file does not carry weighs the median of those it does.
  if [ ! -s "$O/chunks.plan" ]; then
    printf '%s\n' "$ids" | tr ',' '\n' | awk -F '\t' -v TF="$tf" -v LIM="$(( chunk * 1000 ))" '
      BEGIN {
        while ((getline l < TF) > 0) { split(l, a, "\t"); if (a[1] !~ /^(#|id$|@)/ && a[2] ~ /^[0-9]+$/) { w[a[1]] = a[2] + 0; v[++nv] = a[2] + 0 } }
        for (i = 2; i <= nv; i++) { x = v[i]; for (j = i - 1; j >= 1 && v[j] > x; j--) v[j + 1] = v[j]; v[j + 1] = x }
        med = (nv ? v[int((nv + 1) / 2)] : 1)
      }
      NF {
        x = ($1 in w ? w[$1] : med)
        if (cur != "" && sum + x > LIM) { print ++k "\t" sum "\t" cur; cur = ""; sum = 0 }
        cur = cur (cur == "" ? "" : ",") $1; sum += x
      }
      END { if (cur != "") print ++k "\t" sum "\t" cur }
    ' > "$O/chunks.plan"
  fi
  printf 'gate-isolation: 쓸기 — 절 %s개 · 구간 %s개 · 동시 %s · 결과 %s\n' \
    "$(printf '%s\n' "$ids" | tr ',' '\n' | grep -c .)" "$(grep -c . "$O/chunks.plan")" "$jobs" "$O" >&2
  local k load cids e IFS_OLD="$IFS"
  : > "$O/chunks.tsv"
  while IFS="$(printf '\t')" read -r k load cids; do
    [ -n "$k" ] || continue
    while [ "$(jobs -rp | grep -c .)" -ge "$jobs" ]; do sleep 1; done
    iso_sweep_chunk "$O" "$k" "$cids" "$bsh" "$suite" &
  done < "$O/chunks.plan"
  IFS=';'; set -- $spec; IFS="$IFS_OLD"
  for e in "$@"; do
    [ -n "$e" ] || continue
    [ -f "$O/iso-solo/solo${e%%:*}-$(printf '%s' "${e#*:}" | cut -d, -f1)/rc" ] && continue
    while [ "$(jobs -rp | grep -c .)" -ge "$jobs" ]; do sleep 1; done
    iso_solos --out "$O/iso-solo" --spec "$e" --bash "$bsh" --suite "$suite" &
  done
  wait
  # The plan the comparison reads: the solo row, and every run that finished
  # with its total — a run that was cut in two or replaced is not a context.
  {
    printf 'solo\t0\t\t\t%s\t\n' "$spec"
    awk -F '\t' '$6 == "완료" { print $1 "\t0\t" $5 "\t\t\t" $5 }' "$O/chunks.tsv"
  } > "$O/plan.tsv"
  awk -F '\t' '$6 != "완료" { print "gate-isolation: 구간 " $1 " (" $2 " … " $3 ", 절 " $4 "개) — " $6 }' "$O/chunks.tsv" >&2
  iso_compare --dir "$O" --plan "$O/plan.tsv" --out "$O/result.tsv" --suite "$suite"
}

# --- self-test ---------------------------------------------------------------

iso_self_test() {
  local passed=0 failed=0 skipped=0 T out rc bsh="${ISO_BASH:-bash}"
  ok()   { passed=$((passed + 1)); printf 'PASS: %s\n' "$1"; }
  bad()  { failed=$((failed + 1)); printf 'FAIL: %s — %s\n' "$1" "${2:-}" >&2; }
  skip() { skipped=$((skipped + 1)); printf 'SKIP: %s\n' "$1"; }
  T=$(mktemp -d "${TMPDIR:-/tmp}/gate-iso-st.XXXXXX") || return 1

  # --- the comparator on made-up records --------------------------------------
  # mk <dir> <rec lines...>: one context directory with the given record lines.
  mk() { local d="$1"; shift; mkdir -p "$d"; : > "$d/rec.tsv"; for l in "$@"; do printf '%s\n' "$l" >> "$d/rec.tsv"; done; }
  tab=$(printf '\t')
  # plan: row 1 runs a,x (x own), row 2 runs b with x laid over, row 3 holds the solos.
  printf '1\t0\ta,x\t\t\tx\n2\t0\tb\tx\t\t\n3\t0\t\t\t1:x;2:x\t\n' > "$T/plan"
  base() {
    rm -rf "$T/d"; mkdir -p "$T/d"
    mk "$T/d/iso-3/solo1-x" "x${tab}PASS${tab}one 101" "x${tab}PASS${tab}two"
    mk "$T/d/iso-3/solo2-x" "x${tab}PASS${tab}one 202" "x${tab}PASS${tab}two"
    mk "$T/d/iso-1/row" "a${tab}PASS${tab}a1" "x${tab}PASS${tab}one 303" "x${tab}PASS${tab}two"
    mk "$T/d/iso-2/row" "b${tab}PASS${tab}b1" "x${tab}PASS${tab}one 404" "x${tab}PASS${tab}two"
  }
  cmp_() { out=$(bash "$0" compare --dir "$T/d" --plan "$T/plan" --suite /dev/null 2>"$T/err"); rc=$?; }

  base; cmp_
  if [ "$rc" = "0" ] && [ "$out" = "$(printf 'x\t같음\t맥락 4개\t-')" ]; then ok "비교기: 두 단독에서 갈리는 이름은 보정 집합이라 같음이다"; else bad "비교기 보정 집합" "rc=$rc 「${out}」"; fi

  base; mk "$T/d/iso-3/solo2-x" "x${tab}PASS${tab}one 202" "x${tab}FAIL${tab}two"; cmp_
  if [ "$rc" = "1" ] && printf '%s' "$out" | grep -q "^x${tab}갈림${tab}단독 2${tab}2번째 기록"; then ok "비교기: 두 단독의 판정이 갈리면 갈림이다"; else bad "비교기 단독 판정 갈림" "rc=$rc 「${out}」"; fi

  base; mk "$T/d/iso-2/row" "b${tab}PASS${tab}b1" "x${tab}PASS${tab}one 404" "x${tab}NOISE${tab}line 9: x: unbound variable" "x${tab}PASS${tab}two"; cmp_
  if [ "$rc" = "1" ] && printf '%s' "$out" | grep -q "^x${tab}갈림${tab}행 2 (얹힘)${tab}2번째 기록"; then ok "비교기: 한 맥락에만 있는 NOISE 줄은 갈림이다"; else bad "비교기 NOISE" "rc=$rc 「${out}」"; fi

  base; mk "$T/d/iso-1/row" "a${tab}PASS${tab}a1" "x${tab}PASS${tab}one 303" "x${tab}SKIP${tab}two"; cmp_
  if [ "$rc" = "1" ] && printf '%s' "$out" | grep -q "^x${tab}갈림${tab}행 1 (제 행)"; then ok "비교기: SKIP 대 PASS 는 갈림이다"; else bad "비교기 SKIP 대 PASS" "rc=$rc 「${out}」"; fi

  base; mk "$T/d/iso-1/row" "a${tab}PASS${tab}a1" "x${tab}PASS${tab}one 303" "x${tab}PASS${tab}two" "x${tab}PASS${tab}three"; cmp_
  if [ "$rc" = "1" ] && printf '%s' "$out" | grep -q "한 맥락에만 있는 기록 — 행 1 (제 행) 의 3번째 PASS 「three」"; then ok "비교기: 한 맥락에만 있는 기록 줄은 갈림이다"; else bad "비교기 한쪽에만 있는 줄" "rc=$rc 「${out}」"; fi

  base; mk "$T/d/iso-1/row" "a${tab}PASS${tab}a1" "x${tab}PASS${tab}one 303" "x${tab}PASS${tab}twice"; cmp_
  if [ "$rc" = "1" ] && printf '%s' "$out" | grep -q "^x${tab}갈림${tab}행 1 (제 행)${tab}2번째 기록"; then ok "비교기: 보정 집합 밖의 이름이 갈리면 갈림이다"; else bad "비교기 보정 밖 이름" "rc=$rc 「${out}」"; fi

  base; mk "$T/d/iso-2/row" "b${tab}FAIL${tab}b1" "x${tab}PASS${tab}one 404" "x${tab}PASS${tab}two"; cmp_
  if [ "$rc" = "1" ] && printf '%s' "$out" | grep -q "x 가 실린 행에서 b 실패"; then ok "비교기: 얹힌 행의 다른 절 실패는 X 에 귀속한다"; else bad "비교기 얹힌 행 Y 실패" "rc=$rc 「${out}」"; fi

  base; mk "$T/d/iso-1/row" "a${tab}FAIL${tab}a1" "x${tab}PASS${tab}one 303" "x${tab}PASS${tab}two" "@epilogue${tab}FAIL${tab}tail"; cmp_
  if [ "$rc" = "0" ] && grep -q '행 1 (제 행) 의 절 밖 실패(@epilogue)는 행 자신의 실패라 x 에 귀속하지 않습니다' "$T/err"; then ok "비교기: 제 행의 다른 절 실패와 행의 절 밖 실패는 귀속하지 않고 보고한다"; else bad "비교기 행 자신의 실패" "rc=$rc 「${out}」 $(cat "$T/err")"; fi

  base; mk "$T/d/iso-3/solo1-x" "@pre-cone${tab}FAIL${tab}pre" "x${tab}PASS${tab}one 101" "x${tab}PASS${tab}two"; cmp_
  if [ "$rc" = "1" ] && printf '%s' "$out" | grep -q "^x${tab}갈림${tab}단독 1${tab}절 밖 실패 — @pre-cone"; then ok "비교기: 단독의 절 밖 실패는 X 에 귀속한다"; else bad "비교기 단독 절 밖 실패" "rc=$rc 「${out}」"; fi

  base; rm -rf "$T/d/iso-2/row"; mkdir -p "$T/d/iso-2"; cmp_
  if [ "$rc" = "1" ] && printf '%s' "$out" | grep -q "^x${tab}맥락 없음${tab}행 2 (얹힘)"; then ok "비교기: 기록이 없는 맥락은 맥락 없음이다"; else bad "비교기 맥락 없음" "rc=$rc 「${out}」"; fi

  base; rm -rf "$T/d/iso-2"; cmp_
  if [ "$rc" = "1" ] && grep -q '받은 격리 작업 행 2개가 계획의 3개보다 적습니다 — 빠진 행: 2 ' "$T/err"; then ok "비교기: 받은 행 수가 계획의 격리 작업 행 수보다 적으면 실패한다"; else bad "비교기 받은 행 수" "rc=$rc $(cat "$T/err")"; fi

  # Line sets: the same original lines at different cut offsets are the same;
  # a line only one row ran is not; a line the two solos differ in and a line
  # marked `변동` are left out.
  lsbase() {
    base
    printf '1\t10\t1\n11\t20\t100\n' > "$T/d/iso-3/solo1-x/linemap.tsv"
    printf '1\t10\t1\n13\t22\t100\n' > "$T/d/iso-3/solo2-x/linemap.tsv"
    printf '1\t10\t1\n15\t24\t100\n' > "$T/d/iso-1/row/linemap.tsv"
    printf '1\t10\t1\n17\t26\t100\n' > "$T/d/iso-2/row/linemap.tsv"
    printf 'CUT\t11\nCUT\t12\nCUT\t3\nCUT\t14\n' > "$T/d/iso-3/solo1-x/trace-x.lines"
    printf 'CUT\t13\nCUT\t14\nCUT\t3\nCUT\t17\n' > "$T/d/iso-3/solo2-x/trace-x.lines"
    printf 'CUT\t15\nCUT\t16\nCUT\t3\nCUT\t12\n' > "$T/d/iso-1/row/trace-x.lines"
    printf 'CUT\t17\nCUT\t18\nCUT\t3\nCUT\t21\n' > "$T/d/iso-2/row/trace-x.lines"
  }
  lsbase; cmp_
  if [ "$rc" = "0" ] && printf '%s' "$out" | grep -q "^x${tab}같음"; then ok "비교기: 원본 좌표가 같은 줄 집합은 같음이다 (두 단독의 차이 줄은 뺀다)"; else bad "비교기 줄 집합 같음" "rc=$rc 「${out}」"; fi
  lsbase; printf 'CUT\t17\nCUT\t18\nCUT\t3\nCUT\t5\n' > "$T/d/iso-2/row/trace-x.lines"; cmp_
  if [ "$rc" = "1" ] && printf '%s' "$out" | grep -q "^x${tab}갈림${tab}행 2 (얹힘)${tab}줄 집합 — test-gate.sh 줄 5 이 행 2 (얹힘) 에서만"; then ok "비교기: 한 행에서만 실행된 줄은 갈림이다"; else bad "비교기 줄 집합 갈림" "rc=$rc 「${out}」"; fi
  printf 'l1\nl2\nl3\nl4\nl5 # gate-isolation: 변동\n' > "$T/marked.sh"
  out=$(bash "$0" compare --dir "$T/d" --plan "$T/plan" --suite "$T/marked.sh" 2>/dev/null); rc=$?
  if [ "$rc" = "0" ]; then ok "비교기: 변동 표지 줄은 줄 집합 비교에서 뺀다"; else bad "비교기 변동 표지" "rc=$rc 「${out}」"; fi
  lsbase; rm -f "$T/d/iso-1/row/trace-x.lines"; cmp_
  if [ "$rc" = "1" ] && printf '%s' "$out" | grep -q "^x${tab}맥락 없음${tab}행 1 (제 행)${tab}줄 집합 파일이 없습니다"; then ok "비교기: 기준 맥락이 추적됐는데 줄 집합이 없는 맥락은 맥락 없음이다"; else bad "비교기 줄 집합 없음" "rc=$rc 「${out}」"; fi

  # --- the second solo's TMPDIR component ------------------------------------
  # Every run-id string of three bytes or fewer the suite's fixtures use is in
  # the component: the short placeholders a grant heading, a run-id field or a
  # run directory names, gathered with the full ids and then cut by length.
  local want miss=""
  want=$( { grep -oE '\b20[0-9]{6}-[0-9a-f]{8}\b' "$repo_root/scripts/test-gate.sh"
            grep -oE '(## 인가 |run-id=|RUN_ID=|/run/)R[0-9]+\b' "$repo_root/scripts/test-gate.sh" | grep -oE 'R[0-9]+$'; } | LC_ALL=C awk 'length($0) <= 3' | sort -u)
  for w in $want; do case "$ISO_TOKEN" in *"$w"*) ;; *) miss="$miss $w" ;; esac; done
  if [ -n "$want" ] && [ -z "$miss" ]; then ok "토막: 스위트의 픽스처 런 id 꼴 문자열 가운데 3바이트 이하인 것 $(printf '%s\n' "$want" | grep -c .)개를 모두 담는다"; else bad "토막에 빠진 런 id" "${miss:-스위트에서 3바이트 이하인 것을 하나도 찾지 못함}"; fi
  local tok_bytes
  tok_bytes=$(printf '%s' "$ISO_TOKEN" | LC_ALL=C wc -c | tr -d ' ')
  if [ "$tok_bytes" -le 60 ]; then ok "토막은 60바이트 이하다 (${tok_bytes}바이트)"; else bad "토막 길이" "${tok_bytes}바이트 > 60"; fi

  # --- reduced suites cut by the real selector ------------------------------
  # The real head and tail around made-up sections: the selector, the fixture
  # and the recording hooks are the suite's own, only the sections are ours.
  if ! iso_bash_ok "$bsh"; then
    skip "축소 스위트 경우 — $bsh 가 bash 4.1 미만이라 추적할 수 없습니다 (ISO_BASH=<bash 4.1 이상의 경로>)"
    skip "축소 스위트 경우 — 선언 없는 의존"
    skip "축소 스위트 경우 — needs 선언"
    skip "축소 스위트 경우 — 런 id 치환"
  else
    local src pre epi
    src="$repo_root/scripts/test-gate.sh"
    pre=$(grep -n '^# --- preamble-end ---$' "$src" | cut -d: -f1)
    epi=$(grep -n '^# --- epilogue-begin ---$' "$src" | cut -d: -f1)
    # suite <dir> <needs of 902 and 903, or empty>
    suite() {
      local d="$1" nd="$2"
      mkdir -p "$d"
      {
        sed -n "1,${pre}p" "$src"
        cat <<'EOS'

# ---------------------------------------------------------------------------
# 901. P defines a helper in its body and makes a file
# --- section: 901 | group: - | covers: - | anchors: P 가 헬퍼와 파일을 만든다 ---
# ---------------------------------------------------------------------------
iso_p_helper() { echo 7; }
printf 'made\n' > "${TMPDIR:-/tmp}/iso-p-made"
ok "P 가 헬퍼와 파일을 만든다"

# ---------------------------------------------------------------------------
# 902. Q calls P's helper
EOS
        printf '# --- section: 902 | group: - | covers: - | anchors: Q 는 P 의 헬퍼를 부른다%s ---\n' "${nd:+ | needs: $nd}"
        cat <<'EOS'
# ---------------------------------------------------------------------------
check "Q 는 P 의 헬퍼를 부른다" "$(iso_p_helper 2>/dev/null || echo 없음)" "7"

# ---------------------------------------------------------------------------
# 903. Q2 reads P's file and passes through its case either way
EOS
        printf '# --- section: 903 | group: - | covers: - | anchors: Q2 는 P 가 만든 파일에서 깨진 값을 찾지 않는다%s ---\n' "${nd:+ | needs: $nd}"
        cat <<'EOS'
# ---------------------------------------------------------------------------
if [ -f "${TMPDIR:-/tmp}/iso-p-made" ]; then
  iso_q2=$(cat "${TMPDIR:-/tmp}/iso-p-made")
else
  iso_q2=""
fi
case "$iso_q2" in
  *broken*) bad "Q2 는 P 가 만든 파일에서 깨진 값을 찾지 않는다" "$iso_q2" ;;
  *) ok "Q2 는 P 가 만든 파일에서 깨진 값을 찾지 않는다" ;;
esac

# ---------------------------------------------------------------------------
# 904. a fixture run id substituted over a whole file that names a path
# --- section: 904 | group: - | covers: - | anchors: 치환한 기록의 경로가 그대로 남는다 ---
# ---------------------------------------------------------------------------
iso_r6=$(mktemp -d "${TMPDIR:-/tmp}/iso-r6.XXXXXX")
printf 'run-id=R1 dir=%s\n' "$iso_r6" > "$iso_r6/grant"
sed "s/R1/20990101-00000000/g" "$iso_r6/grant" > "$iso_r6/out"
iso_r6_dir=$(sed -n 's/^.* dir=//p' "$iso_r6/out")
check "치환한 기록의 경로가 그대로 남는다" "$([ -d "$iso_r6_dir" ] && echo yes || echo no)" "yes"
rm -rf "$iso_r6"

EOS
        sed -n "${epi},\$p" "$src"
      } > "$d/test-gate.sh"
    }
    verdict() { awk -F '\t' -v X="$2" '$1 == X { print $2 }' "$1/result.tsv" 2>/dev/null; }
    rec_v() { awk -F '\t' -v X="$2" '$1 == X { printf "%s%s", (n++ ? " " : ""), $2 }' "$1/rec.tsv" 2>/dev/null; }

    suite "$T/s0" ""
    out=$(env CC_TEST_GATE_REPO_ROOT="$repo_root" ISO_BASH="$bsh" bash "$0" check --suite "$T/s0/test-gate.sh" --census /dev/null \
      --sections 902,903 --with 901 --out "$T/c0" 2>"$T/c0.err"); rc=$?
    if [ "$rc" = "1" ] && [ "$(verdict "$T/c0" 902)" = "갈림" ] && [ "$(rec_v "$T/c0/iso-1/solo1-902" 902)" = "FAIL" ]; then
      ok "R3: 선언 없이 P 본문의 헬퍼를 부르는 Q 는 단독에서 실패해 갈림이다"
    else bad "R3 선언 없음 Q" "rc=$rc 「${out}」 $(tail -n 3 "$T/c0.err")"; fi
    if [ "$(verdict "$T/c0" 903)" = "갈림" ] && grep -q "^903${tab}갈림${tab}[^${tab}]*${tab}줄 집합 — " "$T/c0/result.tsv"; then
      ok "R3: P 의 파일이 없으면 case 의 통과 갈래로 빠지는 Q2 는 판정이 같아도 줄 집합 차이로 갈림이다"
    else bad "R3 선언 없음 Q2" "「$(cat "$T/c0/result.tsv" 2>/dev/null)」"; fi

    suite "$T/s1" "901"
    out=$(env CC_TEST_GATE_REPO_ROOT="$repo_root" ISO_BASH="$bsh" bash "$0" check --suite "$T/s1/test-gate.sh" --census /dev/null \
      --sections 902,903 --with 901 --out "$T/c1" 2>"$T/c1.err"); rc=$?
    if [ "$rc" = "0" ] && [ "$(verdict "$T/c1" 902)" = "같음" ] && [ "$(verdict "$T/c1" 903)" = "같음" ]; then
      ok "R3: needs: 901 로 선언하면 Q 와 Q2 가 모든 맥락에서 같음이다"
    else bad "R3 needs 선언" "rc=$rc 「${out}」 $(tail -n 3 "$T/c1.err")"; fi

    out=$(env CC_TEST_GATE_REPO_ROOT="$repo_root" ISO_BASH="$bsh" bash "$0" check --suite "$T/s1/test-gate.sh" --census /dev/null \
      --sections 904 --out "$T/c2" 2>"$T/c2.err"); rc=$?
    if [ "$(rec_v "$T/c2/iso-1/solo1-904" 904)" = "PASS" ] && [ "$(rec_v "$T/c2/iso-1/solo2-904" 904)" = "FAIL" ] \
       && [ "$rc" = "1" ] && [ "$(verdict "$T/c2" 904)" = "갈림" ]; then
      ok "R6: 런 id 를 전역 치환하는 절은 첫 단독 통과·둘째 단독 실패로 갈림이다"
    else bad "R6 런 id 치환" "rc=$rc 「${out}」 1=$(rec_v "$T/c2/iso-1/solo1-904" 904) 2=$(rec_v "$T/c2/iso-1/solo2-904" 904)"; fi
  fi

  local rcb
  rcb=0; bash "$0" check --sections 902 --bash /bin/sh >/dev/null 2>"$T/old.err" || rcb=$?
  if [ "$rcb" = "2" ] && grep -q 'ISO_BASH=<bash 4.1 이상의 경로>' "$T/old.err"; then ok "bash 4.1 미만이면 exit 2 와 ISO_BASH 문장"; else bad "옛 bash 거절" "rc=$rcb $(cat "$T/old.err")"; fi
  rcb=0; ISO_TIMING="$T/none.tsv" bash "$0" sweep --out "$T/sw" --bash "$bsh" >/dev/null 2>"$T/sw.err" || rcb=$?
  if ! iso_bash_ok "$bsh"; then skip "타이밍 원천이 없으면 쓸기는 exit 2 — bash 4.1 미만"
  elif [ "$rcb" = "2" ] && grep -q '타이밍 표가 없습니다' "$T/sw.err"; then ok "타이밍 원천을 받지 못하면 exit 2"; else bad "타이밍 원천 없음" "rc=$rcb $(cat "$T/sw.err")"; fi

  rm -rf "$T"
  printf 'gate-isolation self-test: %d passed, %d failed, %d skipped\n' "$passed" "$failed" "$skipped"
  # A floor on the count, so a refactor that silently skips cases cannot pass.
  # A skipped case counts toward it: the suite cases need bash 4.1 and say so.
  if [ "$(( passed + skipped ))" -lt 23 ]; then
    printf 'gate-isolation self-test: 통과·건너뜀 수 %d 가 하한 23 에 못 미칩니다\n' "$(( passed + skipped ))" >&2
    return 1
  fi
  [ "$failed" = "0" ]
}

# --- main --------------------------------------------------------------------

[ "$#" -ge 1 ] || iso_usage
cmd="$1"; shift
case "$cmd" in
  compare)     iso_compare "$@"; exit $? ;;
  solos)       iso_solos "$@"; exit $? ;;
  check)       iso_check "$@"; exit $? ;;
  sweep)       iso_sweep "$@"; exit $? ;;
  capacity)    iso_capacity "$@"; exit $? ;;
  --self-test) iso_self_test; exit $? ;;
  *) printf 'gate-isolation: 모르는 하위명령입니다: %s\n' "$cmd" >&2; iso_usage ;;
esac
