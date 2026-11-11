#!/usr/bin/env bash
# halt-question.sh — the seat's question for one halt record, rendered.
#
# WHAT THIS FILE IS. The seat asks a person a halt record's question in an
# `AskUserQuestion` dialog, whose question field shows one line of limited
# length. A long `**질문 문면**` (one measured record held 2,085 characters on
# one line) was cut there and shown as one unbroken block. This helper reads
# one record and prints what the seat shows instead: a question that fits the
# field, the record's whole question split into paragraphs as a message body
# shown right before the dialog, and the options with each one's risk.
#
#   bash halt-question.sh render --record <record path>
#
# prints one JSON object:
#   question — one line of at most HQ_QUESTION_MAX code points:
#              the folded question itself when it fits (`source` = `원문`),
#              else `[<record name>] <판정 요지>` (`source` = `요지`),
#              else `[<record name>] <fallback sentence>` (`source` = `대체`),
#              cut at a code point boundary and ended with HQ_MORE when over.
#   header   — the first 12 code points of the record name.
#   body     — markdown, parts separated by blank lines: the 판정 요지 line,
#              the 추천 and 추천 근거 lines, the question split into
#              paragraphs, the `**확인**: ` lines quoted after the question
#              block, the per-option risks, and `기록: <absolute path>`.
#   source   — `원문` | `요지` | `대체`.
#   options  — `{label, description, preview}` per option line, label and
#              description byte for byte; `preview` is the risk sentence of
#              that label's `**선택지 리스크**` part, present only when the
#              whole risk line splits into parts that each head with an
#              option label.
#
# READ ONLY, AND NOT THE GATE. This file never calls or sources the gate and
# writes nothing. The question block is read and folded by the same rule as
# the gate's `gate_halt_record_question` — from the `**질문 문면**:` line to
# the next field line or the closing fence, every run of white space made one
# space — and the option lines by the same block rule as its option reader;
# the morning report's suite, which sources the gate, asserts the two agree.
#
# THE PARAGRAPHS CHANGE WHITE SPACE ONLY. Removing every white space from the
# body's question part gives the same string as removing every white space
# from the folded question. That equality is what an auditor checks.
#
# Code points are counted as the bytes that are not UTF-8 continuation bytes
# (0x80-0xBF), with no reliance on the locale.
#
# Exit codes: 0 printed; 2 usage error, the record unreadable or `jq` missing;
# 3 not a complete halt record — its last non-empty line is not the closing
# fence `<!-- /cc-pipeline-halt v1 -->`, or it has no `**질문 문면**` line.
#
# Compatibility: bash 3.2.

# The dialog's question field holds one line of this many code points.
HQ_QUESTION_MAX=200
# The writers' limit for `**판정 요지**`; the 20 left to the field above are
# the `[<record name>] ` prefix of a stage key such as `S2P#5`.
HQ_GIST_MAX=180
# Appended to a question that was cut.
HQ_MORE='…(본문에 이어짐)'
# A question paragraph breaks after a sentence once it holds this many.
HQ_SPLIT_AT=160
HQ_FENCE='<!-- /cc-pipeline-halt v1 -->'

hq_die() { printf 'halt-question: %s\n' "$1" >&2; exit "${2:-2}"; }

# ---------------------------------------------------------------------------
# Code points.
# ---------------------------------------------------------------------------
HQ_AWK_LIB='
function cplen(s,  t) { t = s; return length(s) - gsub(/[\200-\277]/, "", t) }
function cpcut(s, k,  i, n) {
  n = 0
  for (i = 1; i <= length(s); i++)
    if (substr(s, i, 1) !~ /[\200-\277]/ && ++n > k) return substr(s, 1, i - 1)
  return s
}'

hq_cplen() {
  # hq_cplen <text> — its code point count.
  HQ_S="$1" LC_ALL=C awk "$HQ_AWK_LIB"' BEGIN { print cplen(ENVIRON["HQ_S"]) }'
}

hq_cpcut() {
  # hq_cpcut <text> <k> — its first <k> code points.
  HQ_S="$1" LC_ALL=C awk -v k="$2" "$HQ_AWK_LIB"' BEGIN { printf "%s", cpcut(ENVIRON["HQ_S"], k) }'
}

hq_fit() {
  # hq_fit <text> — the text when it fits the question field, else its head
  # cut so that HQ_MORE appended still fits.
  local n
  if [ "$(hq_cplen "$1")" -le "$HQ_QUESTION_MAX" ]; then
    printf '%s' "$1"
  else
    n=$((HQ_QUESTION_MAX - $(hq_cplen "$HQ_MORE")))
    printf '%s%s' "$(hq_cpcut "$1" "$n")" "$HQ_MORE"
  fi
}

# ---------------------------------------------------------------------------
# Reading the record — one pass, one tagged line per value.
# ---------------------------------------------------------------------------
hq_parse() {
  # hq_parse <record> — tagged lines `<tag>\t<value>`:
  #   Q folded question · L one question block line, folded (blank ones left
  #   out) · G the first 판정 요지 line, whole · O an option line · R the 추천
  #   line · B the 추천 근거 line · K the 선택지 리스크 value · S 스킬 · T 스텝 ·
  #   F 금지 후보 · D the count of 「」 pairs in 미결 결정 항목 · C a `**확인**: `
  #   line after the question block and before the option block.
  LC_ALL=C awk '
    function fold(x) { gsub(/[ \t\r]+/, " ", x); sub(/^ /, "", x); sub(/ $/, "", x); return x }
    function val(x, h) { x = substr(x, length(h) + 1); sub(/[ \t\r]+$/, "", x); return x }
    function chunk(x) { x = fold(x); if (x != "") L[++nl] = x }
    stop { next }
    $0 == "<!-- /cc-pipeline-halt v1 -->" { stop = 1 }
    !q && index($0, "**질문 문면**:") == 1 {
      q = 1; nl = 0; s = substr($0, length("**질문 문면**:") + 1); chunk(s)
      next
    }
    q && (/^\*\*[^*][^*]*\*\*:/ || index($0, "<!-- /cc-pipeline-halt") == 1) { q = 0; done = 1; after = 1 }
    q && !done { s = s " " $0; chunk($0); next }
    stop { next }
    after && !opt && index($0, "**확인**: ") == 1 { C[++nc] = $0 }
    inb && /^\*\*/ { inb = 0 }
    /^\*\*선택지\*\*:[ \t]*$/ { inb = 1; opt = 1; next }
    inb && /^- `[^`]+`$/ { O[++no] = $0; next }
    inb && /^- `[^`]+` — / { O[++no] = $0; next }
    !g && index($0, "**판정 요지**:") == 1 { g = 1; G = $0 }
    !r && index($0, "**추천**: ") == 1 { r = 1; R = $0 }
    !b && index($0, "**추천 근거**: ") == 1 { b = 1; B = $0 }
    !k && index($0, "**선택지 리스크**: ") == 1 { k = 1; K = val($0, "**선택지 리스크**: ") }
    !sk && index($0, "**스킬**: ") == 1 { sk = 1; S = val($0, "**스킬**: ") }
    !st && index($0, "**스텝**: ") == 1 { st = 1; T = val($0, "**스텝**: ") }
    !fb && index($0, "**금지 후보**: ") == 1 { fb = 1; F = val($0, "**금지 후보**: ") }
    !dd && index($0, "**미결 결정 항목**:") == 1 {
      # By index, not a bracket expression: under LC_ALL=C a bracket holds
      # bytes, and the bytes of 」 recur inside Hangul syllables.
      dd = 1; x = $0
      while ((i = index(x, "「")) && (j = index(substr(x, i + 3), "」"))) { D++; x = substr(x, i + 3 + j + 2) }
    }
    END {
      gsub(/[ \t\r]+/, " ", s); sub(/^ /, "", s); sub(/ $/, "", s)
      printf "Q\t%s\n", s
      for (i = 1; i <= nl; i++) printf "L\t%s\n", L[i]
      if (g) printf "G\t%s\n", G
      for (i = 1; i <= no; i++) printf "O\t%s\n", O[i]
      if (r) printf "R\t%s\n", R
      if (b) printf "B\t%s\n", B
      if (k) printf "K\t%s\n", K
      if (sk) printf "S\t%s\n", S
      if (st) printf "T\t%s\n", T
      if (fb) printf "F\t%s\n", F
      printf "D\t%d\n", D
      for (i = 1; i <= nc; i++) printf "C\t%s\n", C[i]
    }' "$1"
}

hq_first_url() {
  # hq_first_url <text> — its first `https://` address: printable ASCII up to
  # a space, a non-ASCII byte or one of )]>"'` — with trailing .,;:!? dropped.
  HQ_S="$1" LC_ALL=C awk 'BEGIN {
    s = ENVIRON["HQ_S"]; i = index(s, "https://"); if (!i) exit
    s = substr(s, i); u = ""
    for (j = 1; j <= length(s); j++) {
      c = substr(s, j, 1)
      if (c < "!" || c > "~" || index(")]>\"\047`", c)) break
      u = u c
    }
    sub(/[.,;:!?]+$/, "", u); printf "%s", u
  }'
}

hq_fallback() {
  # hq_fallback <skill> <step> <ban candidate> <open decision count> — the
  # sentence saying what a record without a 판정 요지 asks to decide.
  local skill="$1" step="$2"
  case "$skill" in
    visual-publish-unattended)
      case "$step" in
        '시각-판정'|'시각-판정 — '*) printf '%s' '캔버스의 화면을 구현 기준으로 승인할지 판정합니다'; return ;;
        '디자인-시스템-판정'|'디자인-시스템-판정 — '*) printf '%s' '디자인 시스템(팔레트와 토큰)을 승인할지 판정합니다'; return ;;
        '발행-실패'|'발행-실패 — '*) printf '%s' '실패한 발행을 다시 할지 판정합니다'; return ;;
        '금지-후보'|'금지-후보 — '*) printf '금지 후보 %s 를 금지 목록에 넣을지 판정합니다' "${3:-미기재}"; return ;;
      esac ;;
    autopilot-router-shift)
      case "$step" in
        '결정 수거 — 구현 전 결정'*) printf '구현 전 결정 항목 %s개를 어떻게 닫을지 판정합니다' "$4"; return ;;
        '교대 정지 — '*) printf '%s 교대 정지를 어떻게 처리할지 판정합니다' "${step#'교대 정지 — '}"; return ;;
      esac ;;
  esac
  printf '%s 의 %s 정지에 답합니다' "${skill:-미기재}" "${step:-미기재}"
}

hq_paragraphs() {
  # hq_paragraphs <folded block lines> — each line its own paragraph, and a
  # paragraph broken after `.`, `?` or `!` (not after a digit) once it holds
  # HQ_SPLIT_AT code points. Only white space changes.
  HQ_S="$1" LC_ALL=C awk -v at="$HQ_SPLIT_AT" "$HQ_AWK_LIB"'
    function emit(x) { out = out (out == "" ? "" : "\n\n") x }
    BEGIN {
      n = split(ENVIRON["HQ_S"], ch, "\n"); out = ""
      for (i = 1; i <= n; i++) {
        if (ch[i] == "") continue
        m = split(ch[i], w, " "); p = w[1]
        for (j = 2; j <= m; j++) {
          e = substr(p, length(p), 1)
          d = length(p) > 1 ? substr(p, length(p) - 1, 1) : ""
          if ((e == "." || e == "?" || e == "!") && d !~ /[0-9]/ && cplen(p) >= at + 0) { emit(p); p = w[j] }
          else p = p " " w[j]
        }
        emit(p)
      }
      printf "%s", out
    }'
}

hq_risk_parts() {
  # hq_risk_parts <risk value> <labels, one per line> — `<label>\t<risk>` per
  # part when every part heads with a distinct option label; nothing otherwise.
  HQ_S="$1" HQ_L="$2" LC_ALL=C awk 'BEGIN {
    nl = split(ENVIRON["HQ_L"], ls, "\n"); for (i = 1; i <= nl; i++) if (ls[i] != "") lab[ls[i]] = 1
    n = split(ENVIRON["HQ_S"], ps, " / ")
    for (i = 1; i <= n; i++) {
      if (ps[i] !~ /^`[^`]+` — /) exit
      l = substr(ps[i], 2); l = substr(l, 1, index(l, "`") - 1)
      if (!(l in lab) || (l in seen)) exit
      # `<label>` — : two backticks, two spaces and the three bytes of the dash.
      seen[l] = 1; L[i] = l; R[i] = substr(ps[i], length(l) + 8)
    }
    for (i = 1; i <= n; i++) printf "%s\t%s\n", L[i], R[i]
  }'
}

# ---------------------------------------------------------------------------
# Rendering.
# ---------------------------------------------------------------------------
hq_render() {
  local rec="$1" abs name last tag v line nl=$'\n' tab=$'\t'
  local q='' chunks='' nchunks=0 gist_line='' gist='' opts='' rec_l='' basis='' risk='' skill='' step='' ban='' ndec=0 confirms=''
  local question source fb url body part labels parts ol lab desc pv json
  [ -f "$rec" ] && [ -r "$rec" ] || hq_die "기록을 읽지 못했습니다: $rec"
  command -v jq >/dev/null 2>&1 || hq_die 'jq 가 없어 출력을 만들지 못합니다'
  last=$(LC_ALL=C awk 'NF { l = $0 } END { print l }' "$rec")
  [ "$last" = "$HQ_FENCE" ] || hq_die "닫는 울타리가 마지막 줄이 아닙니다: $rec" 3
  LC_ALL=C grep -q '^\*\*질문 문면\*\*:' "$rec" || hq_die "질문 문면이 없습니다: $rec" 3
  abs="$(cd "$(dirname "$rec")" && pwd)/$(basename "$rec")"
  name=$(basename "$rec"); name=${name%.md}

  while IFS= read -r line; do
    tag=${line%%"$tab"*}; v=${line#*"$tab"}
    case "$tag" in
      Q) q=$v ;;
      L) chunks="$chunks$v$nl"; nchunks=$((nchunks + 1)) ;;
      G) gist_line=$v ;;
      O) opts="$opts$v$nl" ;;
      R) rec_l=$v ;;
      B) basis=$v ;;
      K) risk=$v ;;
      S) skill=$v ;;
      T) step=$v ;;
      F) ban=$v ;;
      D) ndec=$v ;;
      C) confirms="$confirms$v$nl" ;;
    esac
  done <<EOF
$(hq_parse "$rec")
EOF
  if [ -n "$gist_line" ]; then
    gist=${gist_line#'**판정 요지**:'}
    gist=$(printf '%s' "$gist" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
  fi

  # The question field.
  fb='' url=''
  if [ "$(hq_cplen "$q")" -le "$HQ_QUESTION_MAX" ]; then
    question=$q; source='원문'
  elif [ -n "$gist" ]; then
    question=$(hq_fit "[$name] $gist"); source='요지'
  else
    source='대체'
    fb=$(hq_fallback "$skill" "$step" "$ban" "$ndec")
    url=$(hq_first_url "$q")
    question="[$name] $fb"
    if [ "$(hq_cplen "$question")" -gt "$HQ_QUESTION_MAX" ]; then
      question=$(hq_fit "$question")
    elif [ -n "$url" ] && [ "$(hq_cplen "$question — 주소: $url")" -le "$HQ_QUESTION_MAX" ]; then
      question="$question — 주소: $url"
      [ "$(hq_cplen "$question (원문은 위 본문)")" -gt "$HQ_QUESTION_MAX" ] || question="$question (원문은 위 본문)"
    elif [ -z "$url" ] && [ "$(hq_cplen "$question (원문은 위 본문)")" -le "$HQ_QUESTION_MAX" ]; then
      question="$question (원문은 위 본문)"
    fi
  fi

  # The body, part by part.
  body=''
  hq_add() { [ -z "$1" ] || body="$body${body:+$nl$nl}$1"; }
  if [ -n "$gist" ]; then
    hq_add "$gist_line"
  elif [ "$source" = "대체" ]; then
    hq_add "**판정 요지**(기록에 없어 좌석 도우미가 만든 문장): $fb${url:+ — 주소: $url}"
  fi
  hq_add "$rec_l"
  hq_add "$basis"
  if [ "$source" != "원문" ] || [ "$nchunks" -ge 2 ]; then
    hq_add "**질문 원문**"
    hq_add "$(hq_paragraphs "$chunks")"
  fi
  if [ -n "$confirms" ]; then
    hq_add "**질문 뒤 인용 줄**"
    while IFS= read -r line; do hq_add "$line"; done <<EOF
$confirms
EOF
  fi
  labels=$(printf '%s' "$opts" | LC_ALL=C awk '{ l = substr($0, 4); sub(/`.*/, "", l); print l }')
  parts=''
  if [ -n "$risk" ]; then
    parts=$(hq_risk_parts "$risk" "$labels")
    if [ -n "$parts" ]; then
      part='**선택지 리스크**'
      while IFS= read -r line; do
        part="$part$nl- \`${line%%"$tab"*}\` — ${line#*"$tab"}"
      done <<EOF
$parts
EOF
      hq_add "$part"
    else
      hq_add "**선택지 리스크**: $risk"
    fi
  fi
  hq_add "기록: $abs"

  # The options, byte for byte, with each label's risk as its preview.
  json='[]'
  while IFS= read -r ol; do
    [ -n "$ol" ] || continue
    lab=${ol#'- `'}; lab=${lab%%\`*}
    desc=''
    case "$ol" in *'` — '*) desc=${ol#*'` — '} ;; esac
    pv=''
    [ -z "$parts" ] || pv=$(printf '%s\n' "$parts" | LC_ALL=C awk -F'\t' -v l="$lab" '$1 == l { print substr($0, length(l) + 2); exit }')
    json=$(printf '%s' "$json" | jq -c --arg l "$lab" --arg d "$desc" --arg p "$pv" \
      '. + [{label: $l, description: $d} + (if $p == "" then {} else {preview: $p} end)]') || hq_die '선택지를 JSON 으로 만들지 못했습니다'
  done <<EOF
$opts
EOF
  jq -n --arg question "$question" --arg header "$(hq_cpcut "$name" 12)" --arg body "$body" \
    --arg source "$source" --argjson options "$json" \
    '{question: $question, header: $header, body: $body, source: $source, options: $options}'
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  if [ "$#" -ne 3 ] || [ "$1" != "render" ] || [ "$2" != "--record" ]; then
    printf 'usage: halt-question.sh render --record <record path>\n' >&2
    exit 2
  fi
  hq_render "$3"
fi
