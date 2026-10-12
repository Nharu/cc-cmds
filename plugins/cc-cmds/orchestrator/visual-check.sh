#!/usr/bin/env bash
# Machine check, size measure and implementation-approval predicate of the
# visual design skills.
#
# Subcommands:
#   scan <screen file>... [--bans <file>] [--lifts <system.md>]
#       Print one finding per (rule, line) as `<rule id> <file>:<line> <text>`.
#       Comments (`<!-- -->`, `/* */`, a script's `//` line-end comment) are
#       stripped first — a `/*` or `//` inside a quoted string is not one,
#       `</style`/`</script` ends its block whatever comment or string is open,
#       and a quote in a tag opens a value only right after `=` — and every
#       file is split into three streams that keep its line numbers:
#         css     — `<style>` content and `style="…"` attribute values
#         markup  — everything outside `<script>` (style text included)
#         script  — `<script>` content
#       Built-in rules:
#         token-color  a literal colour — hex, a colour function or a named
#                      colour in CSS, a colour attribute's quoted value in
#                      markup, a quoted hex / colour function / colour name in
#                      script. A `var(--x, #fff)` fallback is a literal too.
#         token-space  a literal px/rem/em length on a spacing property (CSS)
#         external-ref anything the screen would fetch from outside itself:
#                      every src/href/action/poster/data/srcset/xlink:href/
#                      background value, `url(…)` and `@import` that is not a
#                      fragment, `data:`, `./support.js` or a non-fetching
#                      scheme, and every quoted absolute URL in script
#       Each `마크업` ban item runs on the markup stream and each `스크립트`
#       item on the script stream, under its own id. A `**금지 해제**: <id> —`
#       line of --lifts skips that id. The two header lines, prefixed `# `,
#       state what the check cannot see and which ids were lifted.
#   size <screen file>
#       Print the number of start tags (`<` followed by a letter) outside
#       comments and script.
#   approval <design doc>
#       Print `승인 유효 <first 12 hex of the input bundle>` and exit 0 only when
#       the document's sidecar is `발행됨`, carries exactly one well-formed
#       `**구현 승인**` line, and the input bundle measured from the current
#       files equals the line's value. Otherwise print `승인 없음 — <reason>` or
#       `승인 무효 — <reason>` and exit 1.
#   bundle <design doc> [--lines]
#       Print the input bundle sha256 (with --lines, the bundle text itself):
#       `<screen id> <sha256>` per screen in screen-id order, then
#       `runtime <support.js sha256>` and `tokens <tokens.css sha256>`, with
#       `(없음)` for a file that does not exist.
#
# The sidecar is found the way every visual skill finds it: the document key is
# the document's path below `git rev-parse --show-toplevel`, the slug is the
# key without `.md` with `/` turned into `-`, and the base is the directory of
# the git common dir. Sidecar `<base>/docs/visual/<slug>.md`, screen
# `<base>/docs/visual/<slug>.<id>.html`, runtime `<base>/docs/visual/support.js`,
# tokens `<base>/docs/visual-system/tokens.css`.
#
# Exit codes:
#   0 — scan: no finding; approval: valid; other subcommands: success
#   1 — scan: at least one finding; approval: none or void; bundle: no sidecar
#   2 — usage error, an unreadable file, a malformed ban list or pattern, a
#       screen that ends inside a comment, a tag, a template string or an
#       unclosed <style>/<script>, or whose CSS or script block comment is
#       still open at its </style>/</script> or closing attribute quote
#       (scan and size)
#
# Compatibility: bash 3.2 (macOS) — no associative arrays, no `mapfile`; BSD
# and GNU userland alike; `grep -E` only.

set -euo pipefail

usage() {
  echo "사용법: visual-check.sh scan <화면>... [--bans <파일>] [--lifts <system.md>] | size <화면> | approval <설계 문서> | bundle <설계 문서> [--lines]" >&2
  exit 2
}

sha256_of() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

sha256_stdin() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  else
    sha256sum | awk '{print $1}'
  fi
}

NAMED='aliceblue|antiquewhite|aqua|aquamarine|azure|beige|bisque|black|blanchedalmond|blue|blueviolet|brown|burlywood|cadetblue|chartreuse|chocolate|coral|cornflowerblue|cornsilk|crimson|cyan|darkblue|darkcyan|darkgoldenrod|darkgray|darkgreen|darkgrey|darkkhaki|darkmagenta|darkolivegreen|darkorange|darkorchid|darkred|darksalmon|darkseagreen|darkslateblue|darkslategray|darkslategrey|darkturquoise|darkviolet|deeppink|deepskyblue|dimgray|dimgrey|dodgerblue|firebrick|floralwhite|forestgreen|fuchsia|gainsboro|ghostwhite|gold|goldenrod|gray|green|greenyellow|grey|honeydew|hotpink|indianred|indigo|ivory|khaki|lavender|lavenderblush|lawngreen|lemonchiffon|lightblue|lightcoral|lightcyan|lightgoldenrodyellow|lightgray|lightgreen|lightgrey|lightpink|lightsalmon|lightseagreen|lightskyblue|lightslategray|lightslategrey|lightsteelblue|lightyellow|lime|limegreen|linen|magenta|maroon|mediumaquamarine|mediumblue|mediumorchid|mediumpurple|mediumseagreen|mediumslateblue|mediumspringgreen|mediumturquoise|mediumvioletred|midnightblue|mintcream|mistyrose|moccasin|navajowhite|navy|oldlace|olive|olivedrab|orange|orangered|orchid|palegoldenrod|palegreen|paleturquoise|palevioletred|papayawhip|peachpuff|peru|pink|plum|powderblue|purple|rebeccapurple|red|rosybrown|royalblue|saddlebrown|salmon|sandybrown|seagreen|seashell|sienna|silver|skyblue|slateblue|slategray|slategrey|snow|springgreen|steelblue|tan|teal|thistle|tomato|turquoise|violet|wheat|white|whitesmoke|yellow|yellowgreen'
HEX='#([0-9a-fA-F]{8}|[0-9a-fA-F]{6}|[0-9a-fA-F]{3,4})([^0-9A-Za-z_-]|$)'
SQ="'"
BT='`'
COLOR_FN='(rgba?|hsla?|hwb|lab|lch|oklab|oklch)\('

CSS_HEX="[:(, ]${HEX}"
CSS_SELECTOR='^[0-9]+:[[:space:]]*#[0-9a-fA-F]+[[:space:]]*[{,.:>+~[]'
CSS_FN="${COLOR_FN}[[:space:]]*[-0-9.]"
CSS_NAMED="(^|[^A-Za-z-])(color|background|background-color|border[a-z-]*|outline[a-z-]*|fill|stroke|box-shadow|text-shadow|caret-color|accent-color|text-decoration-color|column-rule[a-z-]*)[[:space:]]*:[^;{}]*[[:space:]:,(](${NAMED})([^A-Za-z0-9_-]|;|\$)"
CSS_SPACE='(^|[^A-Za-z-])(padding|margin|gap|row-gap|column-gap|inset|top|right|bottom|left)[a-z-]*[[:space:]]*:[^;{}]*[1-9][0-9]*(\.[0-9]+)?(px|rem|em)'
MK_ATTR_HEX="(fill|stroke|stop-color|flood-color|lighting-color|bgcolor|color)=[\"${SQ}]${HEX}"
MK_ATTR_NAMED="(fill|stroke|stop-color|flood-color|lighting-color|bgcolor|color)=[\"${SQ}](${NAMED})[\"${SQ}]"
JS_HEX="[:(, \"${SQ}${BT}=]${HEX}"
JS_FN="${COLOR_FN}[[:space:]]*([-0-9.\$]|[\"${SQ}${BT}])"
JS_NAMED="[\"${SQ}${BT}](${NAMED})[\"${SQ}${BT}]"
JS_URL="[\"${SQ}${BT}](https?:)?//[A-Za-z0-9[]"
REF_ATTR="(^|[^A-Za-z0-9_:-])(src|href|action|poster|data|srcset|xlink:href|background)[[:space:]]*=[[:space:]]*(\"[^\"]*\"|${SQ}[^${SQ}]*${SQ}|[^\"${SQ}[:space:]>]+)"
REF_URL="url\\([[:space:]]*(\"[^\"]*\"|${SQ}[^${SQ}]*${SQ}|[^)\"${SQ}[:space:]]*)"
REF_IMPORT="@import[[:space:]]+(\"[^\"]*\"|${SQ}[^${SQ}]*${SQ})"

# Split one file into the css / markup / script streams under $2, one output
# line per input line in each. Inside <style> and <script> the closing tag is
# looked for before anything else, as the HTML parser does, so a comment or a
# string can never carry past it; quoted strings and script regex literals are
# tracked so a `/*` or `//` inside one stays text. A file that ends inside a comment, a tag, a template
# string or an unclosed <style>/<script> has lost its parse, and so has one whose
# block comment is still open where its block or style attribute closes: the
# reason goes to stderr and the function fails with 2, so it is never read as
# "no finding".
# The parser walks bytes, so awk runs under the C locale: in a UTF-8 locale
# macOS awk aborts with `illegal byte sequence` on a substr that cuts a
# multi-byte character (Hangul in a string or comment) in half. A character's
# bytes always land in one stream, so the streams stay valid text.
split_streams() {
  LC_ALL=C awk -v out="$2" -v file="$1" '
    BEGIN { mode = "html"; hc = 0; cc = 0; jc = 0; intag = 0; q = ""; aeq = 0; aval = 0; sattr = 0; cq = ""; jq = ""; lost = "" }
    {
      line = $0; n = length(line); css = ""; mk = ""; js = ""; jline = 0; esc = 0; i = 1
      while (i <= n) {
        c = substr(line, i, 1)
        if (hc) { if (substr(line, i, 3) == "-->") { hc = 0; i += 3 } else i++; continue }
        if (mode == "html") {
          if (intag) {
            if (q != "") {
              if (c == q) {
                if (sattr && cc && lost == "") lost = "style 속성의 CSS 주석이 닫히지 않았다 (" NR "행)"
                q = ""; sattr = 0; cc = 0; cq = ""; mk = mk c; tag = tag c; i++; continue
              }
              if (sattr) {
                if (cc) { if (substr(line, i, 2) == "*/") { cc = 0; i += 2 } else i++; continue }
                if (cq != "") { if (c == cq) cq = "" }
                else if (c == "\"" || c == "\047") cq = c
                else if (substr(line, i, 2) == "/*") { cc = 1; i += 2; continue }
                css = css c
              }
              mk = mk c; tag = tag c; i++; continue
            }
            # As in the HTML tokenizer, a quote opens a value only where a value
            # starts — after `=` and optional whitespace. A quote inside an
            # unquoted value or an attribute name is text, so an apostrophe in
            # `alt=Bob<apostrophe>s` does not pair with one further down the file.
            if ((c == "\"" || c == "\047") && aeq) {
              q = c; aeq = 0
              if (tolower(tag) ~ /[[:space:]]style[[:space:]]*=[[:space:]]*$/) sattr = 1
              mk = mk c; tag = tag c; i++; continue
            }
            if (c == ">") {
              intag = 0; aeq = 0; aval = 0; mk = mk c; i++
              if (!closing && tagname == "style") mode = "style"
              else if (!closing && tagname == "script") { mode = "script"; jp = ""; jw = "" }
              continue
            }
            if (naming) { if (c ~ /[A-Za-z0-9-]/) tagname = tagname tolower(c); else naming = 0 }
            if (c ~ /[[:space:]]/) aval = 0
            else if (c == "=" && !aval) aeq = 1
            else if (aeq) { aeq = 0; aval = 1 }
            mk = mk c; tag = tag c; i++; continue
          }
          if (substr(line, i, 4) == "<!--") { hc = 1; i += 4; continue }
          nx = substr(line, i + 1, 1)
          if (c == "<" && (nx ~ /[A-Za-z]/ || nx == "/")) {
            intag = 1; closing = 0; tagname = ""; naming = 1; aeq = 0; aval = 0
            if (nx == "/") { closing = 1; mk = mk "</"; tag = "</"; i += 2; continue }
            mk = mk c; tag = "<"; i++; continue
          }
          mk = mk c; i++; continue
        }
        if (mode == "style") {
          if (tolower(substr(line, i, 7)) == "</style") {
            if (cc && lost == "") lost = "CSS 주석이 </style> 앞에서 닫히지 않았다 (" NR "행)"
            mode = "html"; cc = 0; cq = ""; continue
          }
          if (cc) { if (substr(line, i, 2) == "*/") { cc = 0; i += 2 } else i++; continue }
          if (cq != "") {
            if (c == "\\") { t = substr(line, i, 2); css = css t; mk = mk t; esc = (i == n); i += 2; continue }
            if (c == cq) cq = ""
            css = css c; mk = mk c; i++; continue
          }
          if (c == "\"" || c == "\047") { cq = c; css = css c; mk = mk c; i++; continue }
          if (substr(line, i, 2) == "/*") { cc = 1; i += 2; continue }
          css = css c; mk = mk c; i++; continue
        }
        # A block comment still open at the closing tag swallowed the rest of
        # the block: either the script is broken or a `/*` was misread, and
        # both are a lost parse, not a clean block.
        if (tolower(substr(line, i, 8)) == "</script") {
          if (jc && lost == "") lost = "스크립트 주석이 </script> 앞에서 닫히지 않았다 (" NR "행)"
          mode = "html"; jc = 0; jq = ""; jr = 0; jrc = 0; jline = 0; continue
        }
        if (jline) { i++; continue }
        if (jc) { if (substr(line, i, 2) == "*/") { jc = 0; i += 2 } else i++; continue }
        if (jq != "") {
          if (c == "\\") { js = js substr(line, i, 2); esc = (i == n); i += 2; continue }
          if (c == jq) jq = ""
          js = js c; i++; continue
        }
        # Inside a regex literal a `/*` or a quote is text; the literal ends at
        # the first unescaped `/` outside a [...] class.
        if (jr) {
          if (c == "\\") { js = js substr(line, i, 2); i += 2; continue }
          if (jrc) { if (c == "]") jrc = 0 }
          else if (c == "[") jrc = 1
          else if (c == "/") { jr = 0; jp = "a"; jw = "" }
          js = js c; i++; continue
        }
        if (c == "\"" || c == "\047" || c == "`") { jq = c; jp = "a"; jw = ""; js = js c; i++; continue }
        if (substr(line, i, 2) == "/*") { jc = 1; i += 2; continue }
        # Strings and regex literals are consumed above, so a `//` that gets
        # here is a line comment whatever stands before it (`"a"// note`).
        if (substr(line, i, 2) == "//") { jline = 1; i += 2; continue }
        # A `/` where no operand can stand (script start, after an operator or
        # an opening bracket, or after a keyword such as `return`) opens a
        # regex literal; after a name, a number or a closing bracket it divides.
        if (c == "/" && (jp == "" || index("(,=:[!&|?{};+-*%<>~^", jp) > 0 || jw ~ /^(return|typeof|case|do|else|in|of|new|delete|void|throw|instanceof|yield|await)$/)) {
          jr = 1; jrc = 0; js = js c; i++; continue
        }
        if (c ~ /[A-Za-z0-9_$]/) { jw = (jp ~ /[A-Za-z0-9_$]/ && !jsp) ? jw c : c; jp = c; jsp = 0 }
        else if (c ~ /[[:space:]]/) jsp = 1
        else { jp = c; jw = ""; jsp = 0 }
        js = js c; i++
      }
      if (intag) tag = tag " "
      # A quoted CSS or JS string ends at an unescaped line end; only a JS
      # template string carries on to the next line. A regex literal never
      # spans lines.
      if (!esc) { cq = ""; if (jq != "`") jq = "" }
      jr = 0; jrc = 0; jsp = 1
      print css > (out "/css"); print mk > (out "/markup"); print js > (out "/script")
    }
    END {
      why = ""
      if (lost != "") { print "visual-check.sh: " file " 파싱을 잃었다 — " lost > "/dev/stderr"; exit 2 }
      if (hc) why = "HTML 주석이 닫히지 않았다"
      else if (cc) why = "CSS 주석이 닫히지 않았다"
      else if (jc) why = "스크립트 주석이 닫히지 않았다"
      else if (jq == "`") why = "스크립트 템플릿 문자열이 닫히지 않았다"
      else if (intag) why = "태그가 닫히지 않았다"
      else if (mode == "style") why = "<style> 이 닫히지 않았다"
      else if (mode == "script") why = "<script> 가 닫히지 않았다"
      if (why != "") { print "visual-check.sh: " file " 파싱을 잃었다 — " why " (파일 끝)" > "/dev/stderr"; exit 2 }
    }
  ' "$1"
}

# hits <rule> <stream file> <regex> [i] — append `<rule>\t<line>` per match.
hits() {
  local opt=-nE
  [ "${4:-}" = i ] && opt=-niE
  { grep "$opt" -- "$3" "$2" || true; } | cut -d: -f1 | awk -v r="$1" '{print r "\t" $1}' >> "$FOUND"
}

ext_refs() {
  {
    grep -noiE -- "$REF_ATTR" "$1" || true
    grep -noiE -- "$REF_URL" "$1" || true
    grep -noiE -- "$REF_IMPORT" "$1" || true
  } | LC_ALL=C awk '
    {
      ln = $0; sub(/:.*/, "", ln); m = substr($0, length(ln) + 2); v = m
      if (tolower(m) ~ /^@import/) sub(/^@[Ii][Mm][Pp][Oo][Rr][Tt][[:space:]]*/, "", v)
      else sub(/^[^=(]*[=(]/, "", v)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
      if (v ~ /^["\047]/) { v = substr(v, 2); sub(/["\047]$/, "", v) }
      gsub(/^[[:space:]]+/, "", v); sub(/[[:space:]].*$/, "", v)
      lv = tolower(v)
      if (v == "" || v ~ /^#/ || v == "./support.js") next
      if (lv ~ /^(data|mailto|tel|javascript|about|blob):/) next
      print "external-ref\t" ln
    }
  ' >> "$FOUND"
}

# Parse a ban file into "<id>\t<kind>\t<pattern>" lines on stdout; exit 2 on a
# malformed line or a pattern grep -E cannot read.
load_bans() {
  local line id kind rest pat grc lno=0
  while IFS= read -r line || [ -n "$line" ]; do
    lno=$((lno + 1))
    case "$line" in ''|'#'*) continue ;; esac
    case "$line" in *' | '*' | '*' | '*) ;; *)
      echo "visual-check.sh: 금지 목록 ${lno}번 줄이 '<id> | <종류> | <설명> | <패턴>' 꼴이 아니다" >&2; exit 2 ;;
    esac
    id=${line%%' | '*}; rest=${line#*' | '}
    kind=${rest%%' | '*}; rest=${rest#*' | '}
    pat=${rest#*' | '}
    printf '%s' "$id" | grep -qE '^[a-z0-9][a-z0-9-]*$' \
      || { echo "visual-check.sh: 금지 목록 ${lno}번 줄의 id '${id}' 가 [a-z0-9-] 꼴이 아니다" >&2; exit 2; }
    case "$kind" in
      판단) continue ;;
      마크업|스크립트)
        grc=0
        grep -E -- "$pat" </dev/null >/dev/null 2>&1 || grc=$?
        [ "$grc" != 2 ] || { echo "visual-check.sh: 금지 목록 ${lno}번 줄(${id})의 패턴이 grep -E 로 읽히지 않는다" >&2; exit 2; }
        printf '%s\t%s\t%s\n' "$id" "$kind" "$pat"
        ;;
      *) echo "visual-check.sh: 금지 목록 ${lno}번 줄의 종류 '${kind}' 는 마크업·스크립트·판단 밖이다" >&2; exit 2 ;;
    esac
  done < "$1"
}

cmd_scan() {
  local files='' bans='' lifts='' f
  local -a fl=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --bans) [ $# -ge 2 ] || usage; bans=$2; shift 2 ;;
      --lifts) [ $# -ge 2 ] || usage; lifts=$2; shift 2 ;;
      --*) usage ;;
      *) fl+=("$1"); shift ;;
    esac
  done
  [ "${#fl[@]}" -gt 0 ] || usage
  for f in "${fl[@]}"; do
    [ -f "$f" ] || { echo "visual-check.sh scan: 화면 파일이 없다: $f" >&2; exit 2; }
  done
  [ -z "$bans" ] || [ -f "$bans" ] || { echo "visual-check.sh scan: 금지 목록 파일이 없다: $bans" >&2; exit 2; }
  [ -z "$lifts" ] || [ -f "$lifts" ] || { echo "visual-check.sh scan: system.md 가 없다: $lifts" >&2; exit 2; }

  WORK=$(mktemp -d "${TMPDIR:-/tmp}/visual-check.XXXXXX")
  trap 'rm -rf "$WORK"' EXIT
  local banlist="$WORK/bans" lifted=''
  : > "$banlist"
  [ -z "$bans" ] || load_bans "$bans" > "$banlist"
  if [ -n "$lifts" ]; then
    lifted=$(sed -nE 's/^\*\*금지 해제\*\*:[[:space:]]*([a-z0-9-]+)[[:space:]]+—.*$/\1/p' "$lifts" | LC_ALL=C sort -u | tr '\n' ' ' | sed 's/ $//')
  fi

  echo "# 검사 밖: 계산된 색(스크립트가 실행 중에 값을 이어 만드는 색)은 이 검사가 보지 못한다"
  if [ -n "$lifted" ]; then
    echo "# 금지 해제: $(printf '%s' "$lifted" | sed 's/ /, /g')"
  else
    echo "# 금지 해제: 없음"
  fi

  local any=0 s id kind pat
  for f in "${fl[@]}"; do
    s="$WORK/s"
    rm -rf "$s"; mkdir "$s"
    FOUND="$WORK/found"
    : > "$FOUND"
    split_streams "$f" "$s" || exit 2

    { grep -nE -- "$CSS_HEX" "$s/css" || true; } | { grep -vE -- "$CSS_SELECTOR" || true; } \
      | cut -d: -f1 | awk '{print "token-color\t" $1}' >> "$FOUND"
    hits token-color "$s/css" "$CSS_FN" i
    hits token-color "$s/css" "$CSS_NAMED" i
    hits token-color "$s/markup" "$MK_ATTR_HEX" i
    hits token-color "$s/markup" "$MK_ATTR_NAMED" i
    hits token-color "$s/script" "$JS_HEX"
    hits token-color "$s/script" "$JS_FN" i
    hits token-color "$s/script" "$JS_NAMED" i
    hits token-space "$s/css" "$CSS_SPACE"
    ext_refs "$s/markup"
    hits external-ref "$s/script" "$JS_URL" i

    while IFS="$(printf '\t')" read -r id kind pat; do
      [ -n "$id" ] || continue
      case " $lifted " in *" $id "*) continue ;; esac
      if [ "$kind" = 마크업 ]; then
        hits "$id" "$s/markup" "$pat"
      else
        hits "$id" "$s/script" "$pat"
      fi
    done < "$banlist"

    if [ -s "$FOUND" ]; then
      any=1
      LC_ALL=C sort -u "$FOUND" | LC_ALL=C sort -t "$(printf '\t')" -k2,2n -k1,1 \
        | awk -F '\t' -v file="$f" '
            NR == FNR { t = $0; gsub(/^[[:space:]]+|[[:space:]]+$/, "", t); src[FNR] = t; next }
            { print $1 " " file ":" $2 " " src[$2] }
          ' "$f" -
    fi
  done
  [ "$any" = 0 ] || exit 1
}

cmd_size() {
  [ $# -eq 1 ] || usage
  [ -f "$1" ] || { echo "visual-check.sh size: 화면 파일이 없다: $1" >&2; exit 2; }
  WORK=$(mktemp -d "${TMPDIR:-/tmp}/visual-check.XXXXXX")
  trap 'rm -rf "$WORK"' EXIT
  split_streams "$1" "$WORK" || exit 2
  { grep -oE '<[A-Za-z]' "$WORK/markup" || true; } | wc -l | tr -d ' '
}

# --- sidecar location ---------------------------------------------------------
# Sets DOC_KEY SLUG BASE SIDECAR, or prints the reason and returns 1.
locate_sidecar() {
  local doc=$1 dir top docp gcd
  [ -f "$doc" ] || { echo "설계 문서가 없다"; return 1; }
  dir=$(cd "$(dirname "$doc")" && pwd -P)
  top=$(cd "$dir" && git rev-parse --show-toplevel 2>/dev/null) || { echo "설계 문서가 git 트리 밖이다"; return 1; }
  top=$(cd "$top" && pwd -P)
  docp="$dir/$(basename "$doc")"
  DOC_KEY=${docp#"$top"/}
  SLUG=$(printf '%s' "${DOC_KEY%.md}" | tr '/' '-')
  gcd=$(cd "$dir" && git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || { echo "베이스를 풀 수 없다"; return 1; }
  BASE=$(dirname "$gcd")
  SIDECAR="$BASE/docs/visual/${SLUG}.md"
}

screen_ids() {
  sed -nE 's/^### 화면 ([^[:space:]]+)[[:space:]]*$/\1/p' "$SIDECAR" | LC_ALL=C sort -u
}

bundle_text() {
  local id fp
  for id in $(screen_ids); do
    fp="$BASE/docs/visual/${SLUG}.${id}.html"
    if [ -f "$fp" ]; then
      printf '%s %s\n' "$id" "$(sha256_of "$fp")"
    else
      printf '%s %s\n' "$id" '(없음)'
    fi
  done
  fp="$BASE/docs/visual/support.js"
  if [ -f "$fp" ]; then printf 'runtime %s\n' "$(sha256_of "$fp")"; else printf 'runtime (없음)\n'; fi
  fp="$BASE/docs/visual-system/tokens.css"
  if [ -f "$fp" ]; then printf 'tokens %s\n' "$(sha256_of "$fp")"; else printf 'tokens (없음)\n'; fi
}

cmd_bundle() {
  local doc='' lines=0 why
  while [ $# -gt 0 ]; do
    case "$1" in
      --lines) lines=1; shift ;;
      --*) usage ;;
      *) [ -z "$doc" ] || usage; doc=$1; shift ;;
    esac
  done
  [ -n "$doc" ] || usage
  if ! why=$(locate_sidecar "$doc"); then
    echo "입력 묶음 없음 — ${why}"; exit 1
  fi
  locate_sidecar "$doc" >/dev/null
  [ -f "$SIDECAR" ] || { echo "입력 묶음 없음 — 사이드카 없음 (${SIDECAR})"; exit 1; }
  if [ "$lines" = 1 ]; then
    bundle_text
  else
    bundle_text | sha256_stdin
  fi
}

cmd_approval() {
  [ $# -eq 1 ] || usage
  local doc=$1 why owner state n line want id now
  if ! why=$(locate_sidecar "$doc"); then
    echo "승인 없음 — ${why}"; exit 1
  fi
  locate_sidecar "$doc" >/dev/null
  [ -f "$SIDECAR" ] || { echo "승인 없음 — 사이드카 없음 (${SIDECAR})"; exit 1; }
  # The machine header is line 2 under the human H1, or line 1 of a sidecar
  # written without one; nothing below line 2 is read as the header.
  owner=$(sed -n '1,2p' "$SIDECAR" | { grep -E '^<!-- cc-visual v1;' || true; } | sed -n '1p' \
    | sed -nE 's/^.*owner-doc=([^;]*);.*$/\1/p' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
  [ "$owner" = "$DOC_KEY" ] || { echo "승인 없음 — 사이드카의 owner-doc 이 이 문서가 아니다"; exit 1; }
  state=$(sed -nE 's/^\*\*상태\*\*:[[:space:]]*(.*[^[:space:]])[[:space:]]*$/\1/p' "$SIDECAR" | head -n 1)
  [ "$state" = 발행됨 ] || { echo "승인 없음 — 상태가 발행됨이 아니다 (${state:-없음})"; exit 1; }
  n=$({ grep -E '^\*\*구현 승인\*\*:' "$SIDECAR" || true; } | grep -c . || true)
  [ "$n" != 0 ] || { echo "승인 없음 — 구현 승인 줄 없음"; exit 1; }
  [ "$n" = 1 ] || { echo "승인 무효 — 구현 승인 줄이 ${n}개다"; exit 1; }
  line=$(grep -E '^\*\*구현 승인\*\*:' "$SIDECAR")
  printf '%s\n' "$line" | grep -qE '^\*\*구현 승인\*\*: [^[:space:]]+ — 입력 묶음 [0-9a-f]{64} — 금지 목록 [0-9a-f]{64} — 기계 검사 수용 (없음|[a-z0-9-]+(, [a-z0-9-]+)*)[[:space:]]*$' \
    || { echo "승인 무효 — 구현 승인 줄의 형식이 틀렸다"; exit 1; }
  want=$(printf '%s\n' "$line" | sed -E 's/^.* — 입력 묶음 ([0-9a-f]{64}) — .*$/\1/')
  [ -n "$(screen_ids)" ] || { echo "승인 무효 — 사이드카에 화면이 없다"; exit 1; }
  for id in $(screen_ids); do
    [ -f "$BASE/docs/visual/${SLUG}.${id}.html" ] || { echo "승인 무효 — 화면 파일 없음 (${id})"; exit 1; }
  done
  now=$(bundle_text | sha256_stdin)
  [ "$now" = "$want" ] || { echo "승인 무효 — 입력 묶음이 달라졌다 (줄 ${want:0:12}, 지금 ${now:0:12})"; exit 1; }
  echo "승인 유효 ${now:0:12}"
}

[ $# -ge 1 ] || usage
sub=$1
shift
case "$sub" in
  scan) cmd_scan "$@" ;;
  size) cmd_size "$@" ;;
  approval) cmd_approval "$@" ;;
  bundle) cmd_bundle "$@" ;;
  *) usage ;;
esac
