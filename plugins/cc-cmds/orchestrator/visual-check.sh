#!/usr/bin/env bash
# Machine check, size measure and implementation-approval predicate of the
# visual design skills.
#
# Subcommands:
#   scan <screen file>... [--bans <file>] [--lifts <system.md>] [--tokens <tokens.css>]
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
#         token-undefined  a custom property referenced as `var(--x…)` in the
#                      css or script stream (not in a markup attribute value)
#                      that the file never defines — one finding per name, on
#                      the line that first references it. A definition is
#                      `--x` followed by optional whitespace and `:` in css
#                      (style attribute values included), `@property --x`, or
#                      a quoted `'--x'` / `"--x"` / `` `--x` `` in script (a
#                      value set at run time with setProperty is out of sight,
#                      so its name counts as defined). A `var(--x, …)` with a
#                      fallback is still a reference. Runs with or without
#                      --tokens.
#         token-block  (only with --tokens) the screen's token block — the
#                      raw line whose trimmed text is exactly
#                      `<style data-cc-tokens>` up to the first raw line after
#                      it whose trimmed text is exactly `</style>`; an opening
#                      line with no such line after it is no block — must be
#                      there exactly once with content equal, line by line and
#                      byte for byte, to the tokens file (a missing final
#                      newline of the tokens file is no difference). No block
#                      → a finding on line 1; two or more → one on the second
#                      opening line; different content → one on the opening
#                      line. Lines inside comments and script strings count;
#                      the position is not checked. Only when the block is
#                      there once and equal are the token-color and
#                      token-space findings on its content lines dropped;
#                      external-ref and ban item findings there stay.
#       Each `마크업` ban item runs on the markup stream and each `스크립트`
#       item on the script stream, under its own id. A `**금지 해제**: <id> —`
#       line of --lifts skips that id. The three header lines, prefixed `# `,
#       state what the check cannot see, which ids were lifted and which
#       tokens file the token block was compared with.
#   size <screen file>
#       Print the number of start tags (`<` followed by a letter) outside
#       comments and script.
#   approval <design doc>
#       Print `승인 유효 <first 12 hex of the input bundle>` and exit 0 only when
#       the document's sidecar is `발행됨`, carries exactly one well-formed
#       `**구현 승인**` line, and the input bundle measured from the current
#       files equals the line's value. Otherwise print `승인 없음 — <reason>` or
#       `승인 무효 — <reason>` and exit 1. The line may end in the provenance
#       tail ` — 사람 답 <file name>`, the name of the halt record under the
#       run's `halt/` whose person's answer the line was written on
#       (`[A-Za-z0-9._#-]+\.md`: no path separator, no space). When it does, a
#       valid approval prints a second line `출처 사람 답 <file name>`; whether
#       that record and its answer stand is the gate's to check, not this one's.
#       The `**확인**` line of `system.md` is not read here: an unattended
#       consumer reads `confirm` beside this verdict, an interactive one does
#       not. After those checks the `**문서 반영**` line is read (see
#       `reflection_verdict`): none, `불요` or `완료` keeps the approval valid,
#       `대기` prints `승인 보류 — 설계 문서 반영 대기`, `실패` prints
#       `승인 보류 — 설계 문서 반영 실패 — <사유>`, and a misplaced, repeated
#       or malformed line prints `승인 무효 — 문서 반영 줄 형식 오류`; those
#       three exit 1.
#   drift <design doc>
#       Print `어긋남 <n>건 · sha256 <hex>` for the sidecar's
#       `### 설계 문서 어긋남` block: n is 0 for a body of the one line `없음`,
#       else the number of `- ` lines; the sha256 is over the body (the line
#       after the heading up to the next `### ` heading or the end of the file)
#       normalized as the binding digest is. Exit 1 when there is no block.
#       Each line `- <id> · <section title> · 「<document text>」 → 「…」` is
#       split at the first ` · `, the first ` · 「` and the first `」 → `; its
#       title must be a heading of the document exactly once and its document
#       text (not `(없음)`) must be inside that heading's section verbatim.
#       Lines that fail are printed and the exit code is 2.
#   bundle <design doc> [--lines]
#       Print the input bundle sha256 (with --lines, the bundle text itself):
#       `<screen id> <sha256>` per screen in screen-id order, then
#       `runtime <support.js sha256>` and `tokens <tokens.css sha256>`, with
#       `(없음)` for a file that does not exist.
#   binding <design doc>
#       Print the design document's binding digest the sidecar's
#       `**설계 문서 구속 다이제스트**` carries: the driver's `binding_digest`
#       filter (run.sh) with the `## 시각 정합 기준` section dropped besides.
#   system <design doc> [--owner]
#       Without --owner, print the normalized digest of the repository's
#       `system.md` — the sha256 of the file with every line that starts with
#       `**아티팩트**: ` replaced by `**아티팩트**: (미발행)`, every line that
#       starts with `**확인**: ` removed, and every other byte kept, the final
#       newline or its absence included — or `(없음)` when there is no
#       `system.md`. A file without an artifact or confirmation line has the
#       same normalized digest as its whole-file hash, and removing a
#       confirmation line leaves the bytes of the same file without it. This
#       is the value a sidecar's `**디자인 시스템 sha256**` carries.
#       With --owner, decide whether `system.md` is this document's. When
#       `confirm` reads `사람 승인 — 문서 <this document>`, print
#       `이 문서의 디자인 시스템 — 사람 확인` and exit 0 whatever the sidecar
#       holds, as long as the `**tokens.css sha256**` line equals the current
#       `tokens.css`. Otherwise (no line, a waiting or malformed line, another
#       document's key) print `이 문서의 디자인 시스템` and exit 0 when `system.md`
#       exists, the
#       document's sidecar exists with a `cc-visual v1` header whose
#       `owner-doc` is this document (any state, any `**기록**`), its
#       `**디자인 시스템 sha256**` equals the normalized digest or the
#       whole-file hash, and the `**tokens.css sha256**` line of `system.md`
#       equals the current `tokens.css`; otherwise print
#       `이 문서의 디자인 시스템 아님 — <reason>` for the first that fails and
#       exit 1. `owner-repo` is not compared here.
#   confirm <design doc>
#       Print the confirmation state of `system.md`: `확인 없음` (no file or
#       no `**확인**: ` line), `확인 대기 — 문서 <key>` for
#       `**확인**: 대기 — 문서 <key> — 런 <run id>`, `사람 승인 — 문서 <key>` for
#       `**확인**: 사람 승인 — 문서 <key> — tokens.css sha256 <hex> — 사람 답
#       <file name> — 런 <run id> — <ISO8601 UTC>` whose hash equals the
#       current `tokens.css` (`확인 대기 — 문서 <key>` when it differs), and
#       `확인 형식 오류` for two or more confirmation lines or one that fits
#       neither form. A consumer
#       reads a stop as output starting with `확인 대기 — 문서 ` or equal to
#       `확인 형식 오류`, and an approval by comparing the whole line with
#       `사람 승인 — 문서 <its key>`; it never splits the line on `—`. Exits 0.
#   system-users <design doc> [--also <hex>]
#       Print one line `<document key> — 상태 <state> — 구현 승인 있음|없음`
#       for every other document's sidecar under the same `docs/visual/`
#       whose `**디자인 시스템 sha256**` equals the current normalized digest
#       or whole-file hash of `system.md`, or the --also digest; `없음` when
#       there is none. Exits 0.
#   run-state <design doc> --run-dir <dir> --ledger <file> --manifest <file>
#       Print the run's design system phase state on seven fixed lines —
#       whether the plan has `S2P`, the latest `디자인-시스템-판정` and
#       `시각-판정` records with a person's last answer to each, the revision
#       count, and the `confirm` line (see `cmd_run_state`). The generation and
#       publish stages and the gate read the phase state here and nowhere
#       else. Exits 0.
#   reuse <design doc> --record <interview record>
#       Decide whether a run may take the document's sidecar as its visual
#       stage's finished work. Conditions in order: the sidecar exists, its
#       header is `cc-visual v1` and `owner-doc` is this document; its state
#       is `검토 통과` or `발행됨`; the `**기록**` sha256 equals the record
#       file's (the path is not compared); `**설계 문서 구속 다이제스트**`
#       equals `binding`; `**디자인 시스템 sha256**` is `(없음)` when there
#       is no `system.md` and otherwise equals its normalized digest or its
#       whole-file hash (an older sidecar carries the latter); the
#       `**tokens.css sha256**` line of an existing `system.md` equals the
#       current `tokens.css` (a missing line or file is a mismatch); every
#       screen block's `**대상 경로**` file exists with the block's
#       `**sha256**`. Print `재사용 <상태>` and exit 0 when all hold, otherwise
#       `재사용 불가 — <reason>` for the first that fails and exit 1. Writes
#       nothing.
#
# The sidecar is found the way every visual skill finds it: the document key is
# the document's path below `git rev-parse --show-toplevel`, the slug is the
# key without `.md` with `/` turned into `-`, and the base is the directory of
# the git common dir. Sidecar `<base>/docs/visual/<slug>.md`, screen
# `<base>/docs/visual/<slug>.<id>.html`, runtime `<base>/docs/visual/support.js`,
# tokens `<base>/docs/visual-system/tokens.css`.
#
# Exit codes:
#   0 — scan: no finding; approval: valid; reuse: reusable; system --owner:
#       this document's; other subcommands: success
#   1 — scan: at least one finding; approval: none, void or held; drift: no
#       block; bundle: no sidecar;
#       reuse: not reusable; system --owner: not this document's
#   2 — usage error, an unreadable file, a malformed ban list or pattern, a
#       --tokens file that is missing or contains `</style` (any case), a
#       screen that ends inside a comment, a tag, a template string or an
#       unclosed <style>/<script>, or whose CSS or script block comment is
#       still open at its </style>/</script> or closing attribute quote
#       (scan and size); drift: a block line whose document side was not
#       found
#
# Compatibility: bash 3.2 (macOS) — no associative arrays, no `mapfile`; BSD
# and GNU userland alike; `grep -E` only.

set -euo pipefail

usage() {
  echo "사용법: visual-check.sh scan <화면>... [--bans <파일>] [--lifts <system.md>] [--tokens <tokens.css>] | size <화면> | approval <설계 문서> | drift <설계 문서> | bundle <설계 문서> [--lines] | binding <설계 문서> | system <설계 문서> [--owner] | confirm <설계 문서> | system-users <설계 문서> [--also <hex>] | run-state <설계 문서> --run-dir <런 디렉터리> --ledger <원장> --manifest <매니페스트> | reuse <설계 문서> --record <기록>" >&2
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
# string can never carry past it; quoted strings, the `${…}` substitutions of a
# template string and script regex literals are tracked so a `/*` or `//`
# inside one stays text. A file that ends inside a comment, a tag, a template
# string or an unclosed <style>/<script> has lost its parse, and so has one whose
# block comment or template string is still open where its block or style
# attribute closes: the reason goes to stderr and the function fails with 2, so
# it is never read as "no finding".
# The parser walks bytes, so awk runs under the C locale: in a UTF-8 locale
# macOS awk aborts with `illegal byte sequence` on a substr that cuts a
# multi-byte character (Hangul in a string or comment) in half. A character's
# bytes always land in one stream, so the streams stay valid text.
split_streams() {
  LC_ALL=C awk -v out="$2" -v file="$1" '
    BEGIN { mode = "html"; hc = 0; cc = 0; jc = 0; intag = 0; q = ""; aeq = 0; aval = 0; sattr = 0; cq = ""; jq = ""; tk = 0; lost = "" }
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
            # As in the HTML tokenizer, a tag name ends only at whitespace (a
            # line end included, below), `/` or `>`: `<script.x>` is not a
            # script, and `<script` with its attributes on the next line is.
            if (naming) { if (c ~ /[[:space:]]/ || c == "/") naming = 0; else tagname = tagname tolower(c) }
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
          # A closing tag is its name followed by whitespace, a line end, `/`
          # or `>`; `</stylex>` is text.
          if (tolower(substr(line, i, 7)) == "</style" && substr(line, i + 7, 1) ~ /^([[:space:]]|\/|>)?$/) {
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
        if (tolower(substr(line, i, 8)) == "</script" && substr(line, i + 8, 1) ~ /^([[:space:]]|\/|>)?$/) {
          if (jc && lost == "") lost = "스크립트 주석이 </script> 앞에서 닫히지 않았다 (" NR "행)"
          if ((jq == "`" || tk > 0) && lost == "") lost = "스크립트 템플릿 문자열이 </script> 앞에서 닫히지 않았다 (" NR "행)"
          mode = "html"; jc = 0; jq = ""; tk = 0; jr = 0; jrc = 0; jline = 0; continue
        }
        if (jline) { i++; continue }
        if (jc) { if (substr(line, i, 2) == "*/") { jc = 0; i += 2 } else i++; continue }
        if (jq != "") {
          if (c == "\\") { js = js substr(line, i, 2); esc = (i == n); i += 2; continue }
          # A `${` in a template string opens a code substitution, which can
          # hold strings, comments and nested templates of its own; the
          # template text resumes only at the `}` that closes it (tb counts
          # the braces opened inside each of the tk open substitutions).
          if (jq == "`" && substr(line, i, 2) == "${") {
            tk++; tb[tk] = 0; jq = ""; jp = "{"; jw = ""; js = js "${"; i += 2; continue
          }
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
        if (tk > 0 && c == "{") tb[tk]++
        else if (tk > 0 && c == "}") {
          if (tb[tk] == 0) { tk--; jq = "`"; js = js c; i++; continue }
          tb[tk]--
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
      if (intag) { tag = tag " "; if (q == "") { naming = 0; aval = 0 } }
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
      else if (jq == "`" || tk > 0) why = "스크립트 템플릿 문자열이 닫히지 않았다"
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

# token_undefined <stream dir> — print `token-undefined\t<line>` for every
# custom property the css or script stream references with `var(` but the file
# never defines, on the line of its first reference.
token_undefined() {
  LC_ALL=C awk '
    function refs(line, ln,   r, nm) {
      r = line
      while (match(r, /var\([[:space:]]*--[A-Za-z0-9_-]+/)) {
        nm = substr(r, RSTART, RLENGTH); sub(/^var\([[:space:]]*/, "", nm)
        if (!(nm in first) || ln < first[nm]) first[nm] = ln
        r = substr(r, RSTART + RLENGTH)
      }
    }
    FILENAME == ARGV[1] {
      refs($0, FNR)
      r = $0
      while (match(r, /--[A-Za-z0-9_-]+[[:space:]]*:/)) {
        nm = substr(r, RSTART, RLENGTH); sub(/[[:space:]]*:$/, "", nm); def[nm] = 1
        r = substr(r, RSTART + RLENGTH)
      }
      r = $0
      while (match(r, /@property[[:space:]]+--[A-Za-z0-9_-]+/)) {
        nm = substr(r, RSTART, RLENGTH); sub(/^@property[[:space:]]+/, "", nm); def[nm] = 1
        r = substr(r, RSTART + RLENGTH)
      }
      next
    }
    {
      refs($0, FNR)
      r = $0
      while (match(r, /["\047`]--[A-Za-z0-9_-]+["\047`]/)) {
        def[substr(r, RSTART + 1, RLENGTH - 2)] = 1
        r = substr(r, RSTART + RLENGTH)
      }
    }
    END { for (nm in first) if (!(nm in def)) print "token-undefined\t" first[nm] }
  ' "$1/css" "$1/script"
}

# token_block <screen file> <tokens file> <range file> — print the
# `token-block\t<line>` finding, if any, for the screen's token block, and
# write `<opening line> <closing line>` to the range file when the block is
# there exactly once and equals the tokens file line by line.
token_block() {
  LC_ALL=C awk -v ex="$3" '
    FILENAME == ARGV[1] { t[++tn] = $0; next }
    {
      s = $0; gsub(/^[[:space:]]+|[[:space:]]+$/, "", s)
      if (!inb) { if (s == "<style data-cc-tokens>") { inb = 1; o = FNR; cn = 0; ok = 1 }; next }
      if (s == "</style>") {
        if (cn != tn) ok = 0
        k++
        if (k == 1) { bo = o; bc = FNR; bok = ok } else if (k == 2) second = o
        inb = 0; next
      }
      cn++
      if (cn > tn || $0 != t[cn]) ok = 0
    }
    END {
      if (k == 0) print "token-block\t1"
      else if (k >= 2) print "token-block\t" second
      else if (!bok) print "token-block\t" bo
      else print bo " " bc > ex
    }
  ' "$2" "$1"
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
  local files='' bans='' lifts='' tokens='' f
  local -a fl=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --bans) [ $# -ge 2 ] || usage; bans=$2; shift 2 ;;
      --lifts) [ $# -ge 2 ] || usage; lifts=$2; shift 2 ;;
      --tokens) [ $# -ge 2 ] || usage; tokens=$2; shift 2 ;;
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
  if [ -n "$tokens" ]; then
    [ -f "$tokens" ] || { echo "visual-check.sh scan: 토큰 파일이 없다: $tokens" >&2; exit 2; }
    if LC_ALL=C grep -qiF '</style' "$tokens"; then
      echo "visual-check.sh scan: 토큰 파일이 </style 를 담아 화면의 토큰 블록에 넣을 수 없다: $tokens" >&2; exit 2
    fi
  fi

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
  if [ -n "$tokens" ]; then
    echo "# 토큰 블록: $tokens 와 대조"
  else
    echo "# 토큰 블록: 대조 안 함 (--tokens 없음)"
  fi

  local any=0 s id kind pat bo bc
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

    token_undefined "$s" >> "$FOUND"
    if [ -n "$tokens" ]; then
      rm -f "$WORK/range"
      token_block "$f" "$tokens" "$WORK/range" >> "$FOUND"
      if [ -s "$WORK/range" ]; then
        read -r bo bc < "$WORK/range"
        awk -F '\t' -v o="$bo" -v c="$bc" \
          '!(($1 == "token-color" || $1 == "token-space") && $2 + 0 > o + 0 && $2 + 0 < c + 0)' \
          "$FOUND" > "$WORK/kept"
        mv "$WORK/kept" "$FOUND"
      fi
    fi

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

# sidecar_owner — the `owner-doc` of the sidecar's `cc-visual v1` header, or
# nothing when there is no such header. The machine header is line 2 under the
# human H1, or line 1 of a sidecar written without one; nothing below line 2 is
# read as the header.
sidecar_owner() {
  sed -n '1,2p' "$SIDECAR" | { grep -E '^<!-- cc-visual v1;' || true; } | sed -n '1p' \
    | sed -nE 's/^.*owner-doc=([^;]*);.*$/\1/p' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
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
  local doc=$1 why owner state n line want id now src
  if ! why=$(locate_sidecar "$doc"); then
    echo "승인 없음 — ${why}"; exit 1
  fi
  locate_sidecar "$doc" >/dev/null
  [ -f "$SIDECAR" ] || { echo "승인 없음 — 사이드카 없음 (${SIDECAR})"; exit 1; }
  owner=$(sidecar_owner)
  [ "$owner" = "$DOC_KEY" ] || { echo "승인 없음 — 사이드카의 owner-doc 이 이 문서가 아니다"; exit 1; }
  state=$(sed -nE 's/^\*\*상태\*\*:[[:space:]]*(.*[^[:space:]])[[:space:]]*$/\1/p' "$SIDECAR" | head -n 1)
  [ "$state" = 발행됨 ] || { echo "승인 없음 — 상태가 발행됨이 아니다 (${state:-없음})"; exit 1; }
  n=$({ grep -E '^\*\*구현 승인\*\*:' "$SIDECAR" || true; } | grep -c . || true)
  [ "$n" != 0 ] || { echo "승인 없음 — 구현 승인 줄 없음"; exit 1; }
  [ "$n" = 1 ] || { echo "승인 무효 — 구현 승인 줄이 ${n}개다"; exit 1; }
  line=$(grep -E '^\*\*구현 승인\*\*:' "$SIDECAR")
  printf '%s\n' "$line" | grep -qE '^\*\*구현 승인\*\*: [^[:space:]]+ — 입력 묶음 [0-9a-f]{64} — 금지 목록 [0-9a-f]{64} — 기계 검사 수용 (없음|[a-z0-9-]+(, [a-z0-9-]+)*)( — 사람 답 [A-Za-z0-9._#-]+\.md)?[[:space:]]*$' \
    || { echo "승인 무효 — 구현 승인 줄의 형식이 틀렸다"; exit 1; }
  want=$(printf '%s\n' "$line" | sed -E 's/^.* — 입력 묶음 ([0-9a-f]{64}) — .*$/\1/')
  src=$(printf '%s\n' "$line" | sed -nE 's/^.* — 사람 답 ([A-Za-z0-9._#-]+\.md)[[:space:]]*$/\1/p')
  [ -n "$(screen_ids)" ] || { echo "승인 무효 — 사이드카에 화면이 없다"; exit 1; }
  for id in $(screen_ids); do
    [ -f "$BASE/docs/visual/${SLUG}.${id}.html" ] || { echo "승인 무효 — 화면 파일 없음 (${id})"; exit 1; }
  done
  now=$(bundle_text | sha256_stdin)
  [ "$now" = "$want" ] || { echo "승인 무효 — 입력 묶음이 달라졌다 (줄 ${want:0:12}, 지금 ${now:0:12})"; exit 1; }
  reflection_verdict || exit 1
  echo "승인 유효 ${now:0:12}"
  [ -z "$src" ] || echo "출처 사람 답 ${src}"
}

# reflection_verdict — read the sidecar's `**문서 반영**` line once the six
# approval checks have passed. No line, `불요` or `완료 — 문서 sha256 <hex>`
# returns 0 and prints nothing (the `완료` hash is not compared: a later
# re-convergence may edit the document again, as the input bundle does not hold
# the document either). `대기 — 어긋남 <n>건` prints
# `승인 보류 — 설계 문서 반영 대기`, `실패 — <사유>` prints
# `승인 보류 — 설계 문서 반영 실패 — <사유>`; two or more lines, a line that is
# not directly under the `**구현 승인**` line, or any other value prints
# `승인 무효 — 문서 반영 줄 형식 오류`; all three return 1. Each value may end in
# the tail ` — 사람 답 <file name>`, read from the line's last ` — 사람 답 `; its
# file name is checked for shape only, never against the approval line's tail.
reflection_verdict() {
  local n prev value body tail
  n=$({ grep -E '^\*\*문서 반영\*\*:' "$SIDECAR" || true; } | grep -c . || true)
  [ "$n" != 0 ] || return 0
  [ "$n" = 1 ] || { echo "승인 무효 — 문서 반영 줄 형식 오류"; return 1; }
  prev=$(LC_ALL=C awk 'index($0, "**문서 반영**:") == 1 { print p; exit } { p = $0 }' "$SIDECAR")
  case "$prev" in '**구현 승인**:'*) ;; *) echo "승인 무효 — 문서 반영 줄 형식 오류"; return 1 ;; esac
  value=$(grep -E '^\*\*문서 반영\*\*:' "$SIDECAR" | sed -e 's/^\*\*문서 반영\*\*: //' -e 's/[[:space:]]*$//')
  body=$value
  case "$value" in
    *' — 사람 답 '*)
      body=${value%' — 사람 답 '*}
      tail=${value##*' — 사람 답 '}
      printf '%s\n' "$tail" | grep -qE '^[A-Za-z0-9._#-]+\.md$' \
        || { echo "승인 무효 — 문서 반영 줄 형식 오류"; return 1; }
      ;;
  esac
  case "$body" in *' — 사람 답 '*) echo "승인 무효 — 문서 반영 줄 형식 오류"; return 1 ;; esac
  if [ "$body" = 불요 ] || printf '%s\n' "$body" | grep -qE '^완료 — 문서 sha256 [0-9a-f]{64}$'; then
    return 0
  fi
  if printf '%s\n' "$body" | grep -qE '^대기 — 어긋남 [0-9]+건$'; then
    echo "승인 보류 — 설계 문서 반영 대기"; return 1
  fi
  case "$body" in
    '실패 — '?*) echo "승인 보류 — 설계 문서 반영 실패 — ${body#'실패 — '}"; return 1 ;;
  esac
  echo "승인 무효 — 문서 반영 줄 형식 오류"
  return 1
}

# norm_lines — the line-end normalization the binding digest uses: CR and
# trailing blanks removed, repeated blank lines collapsed to one, leading and
# trailing blank lines dropped.
norm_lines() {
  tr -d '\r' \
    | sed 's/[[:space:]]*$//' \
    | awk '{ if ($0 == "") { blank = 1; next } if (blank && seen) print ""; blank = 0; seen = 1; print }'
}

# drift_block — the body of the sidecar's first `### 설계 문서 어긋남` block:
# from the line after that heading up to the next `### ` heading, or the end of
# the file. Prints nothing and returns 1 when there is no such heading.
drift_block() {
  LC_ALL=C awk '
    on && /^### / { exit }
    on { print; next }
    /^### 설계 문서 어긋남[[:space:]]*$/ { on = 1; found = 1 }
    END { exit found ? 0 : 1 }
  ' "$SIDECAR"
}

# doc_heading_count <doc> / doc_section <doc> — headings are lines of one or
# more `#` and a space outside code fences, their title the rest of the line
# without trailing blanks, compared with $DRIFT_TITLE byte for byte. The
# section runs from the line after the heading to the next heading of the same
# or a higher level, fenced lines and lower headings' bodies included.
doc_heading_count() {
  LC_ALL=C awk '
    BEGIN { t = ENVIRON["DRIFT_TITLE"] }
    /^ *(```|~~~)/ { fence = !fence; next }
    fence { next }
    match($0, /^#+ /) { h = substr($0, RLENGTH + 1); sub(/[ \t]+$/, "", h); if (h == t) n++ }
    END { print n + 0 }
  ' "$1"
}

doc_section() {
  LC_ALL=C awk '
    BEGIN { t = ENVIRON["DRIFT_TITLE"] }
    /^ *(```|~~~)/ { fence = !fence; if (on) print; next }
    fence { if (on) print; next }
    match($0, /^#+ /) {
      lv = RLENGTH - 1
      if (on && lv <= onlv) exit
      h = substr($0, RLENGTH + 1); sub(/[ \t]+$/, "", h)
      if (!on && h == t) { on = 1; onlv = lv; next }
    }
    on { print }
  ' "$1"
}

# cmd_drift <design doc> — the count and digest of the sidecar's
# `### 설계 문서 어긋남` block, after checking that every line's document side
# is really in the document.
cmd_drift() {
  [ $# -eq 1 ] || usage
  local doc=$1 why body n=0 bad='' l rest after title t2 text sha
  [ -f "$doc" ] || { echo "visual-check.sh drift: 설계 문서가 없다: $doc" >&2; exit 2; }
  if ! why=$(locate_sidecar "$doc"); then
    echo "어긋남 블록 없음 — ${why}"; exit 1
  fi
  locate_sidecar "$doc" >/dev/null
  [ -f "$SIDECAR" ] || { echo "어긋남 블록 없음 — 사이드카 없음 (${SIDECAR})"; exit 1; }
  body=$(drift_block) || { echo "어긋남 블록 없음 — 사이드카에 ### 설계 문서 어긋남 이 없다"; exit 1; }
  body=$(printf '%s\n' "$body" | norm_lines)
  if [ -n "$body" ]; then sha=$(printf '%s\n' "$body" | sha256_stdin); else sha=$(printf '' | sha256_stdin); fi
  if [ "$body" != 없음 ]; then
    while IFS= read -r l; do
      case "$l" in '- '*) ;; *) continue ;; esac
      n=$((n + 1))
      rest=${l#- }
      case "$rest" in *' · '*) ;; *) bad="${bad}${l}"$'\n'; continue ;; esac
      after=${rest#*' · '}
      case "$after" in *' · 「'*) ;; *) bad="${bad}${l}"$'\n'; continue ;; esac
      title=${after%%' · 「'*}
      t2=${after#*' · 「'}
      case "$t2" in *'」 → '*) ;; *) bad="${bad}${l}"$'\n'; continue ;; esac
      text=${t2%%'」 → '*}
      if [ -z "$title" ] || [ "$(DRIFT_TITLE=$title doc_heading_count "$doc")" != 1 ]; then
        bad="${bad}${l}"$'\n'; continue
      fi
      [ "$text" = '(없음)' ] && continue
      DRIFT_TITLE=$title doc_section "$doc" | LC_ALL=C grep -qF -e "$text" \
        || bad="${bad}${l}"$'\n'
    done <<EOF
$body
EOF
  fi
  if [ -n "$bad" ]; then
    printf '%s' "$bad"
    exit 2
  fi
  echo "어긋남 ${n}건 · sha256 ${sha}"
}

# binding_text <design doc> — the document the binding digest hashes: the
# driver's `binding_digest` filter (the grade and note lines inside
# `## 구현 시 검증 항목`, then CR, trailing blanks, repeated and leading blank
# lines) with the `## 시각 정합 기준` section dropped whole besides.
binding_text() {
  awk '
    /^## / {
      insec = ($0 ~ /^## 구현 시 검증 항목[[:space:]]*$/) ? 1 : 0
      invis = ($0 ~ /^## 시각 정합 기준[[:space:]]*$/) ? 1 : 0
    }
    invis { next }
    insec && /^(- )?(\*\*검증 등급\*\*|검증 등급): / { next }
    insec && /^(- )?(\*\*구현 시 검증 기록\*\*|구현 시 검증 기록): / { next }
    { print }
  ' "$1" | norm_lines
}

cmd_binding() {
  [ $# -eq 1 ] || usage
  [ -f "$1" ] || { echo "visual-check.sh binding: 설계 문서가 없다: $1" >&2; exit 2; }
  binding_text "$1" | sha256_stdin
}

# sidecar_field <name> — the value of the first `**<name>**:` line of the
# sidecar's document-level fields (above the first `### ` block).
sidecar_field() {
  awk -v k="**$1**:" '
    /^### / { exit }
    index($0, k) == 1 { v = substr($0, length(k) + 1); sub(/^[[:space:]]+/, "", v); sub(/[[:space:]]+$/, "", v); print v; exit }
  ' "$SIDECAR"
}

# system_norm_sha <system.md> — the sha256 of the file with every line that
# starts with `**아티팩트**: ` replaced by `**아티팩트**: (미발행)`, every line
# that starts with `**확인**: ` removed, and every other byte kept. Lines are
# joined by the count of lines written, not the input line number, so a
# removed line leaves the same bytes as a file that never had it. The final
# newline is reproduced only when the file has one, so BSD and GNU hosts hash
# the same bytes; awk runs under the C locale so the Hangul prefixes are
# compared byte for byte.
system_norm_sha() {
  local nl=1
  [ -z "$(tail -c 1 "$1")" ] || nl=0
  LC_ALL=C awk -v nl="$nl" '
    index($0, "**확인**: ") == 1 { next }
    index($0, "**아티팩트**: ") == 1 { $0 = "**아티팩트**: (미발행)" }
    { if (w > 0) printf "\n"; printf "%s", $0; w++ }
    END { if (w > 0 && nl) printf "\n" }
  ' "$1" | sha256_stdin
}

# confirm_state <system.md> — the confirmation state of the design system:
# `확인 없음` when the file is absent or carries no confirmation line,
# `확인 대기 — 문서 <key>` for one waiting line, `사람 승인 — 문서 <key>` for one
# approval line whose `tokens.css sha256` equals the sha256 of the
# `tokens.css` beside the file, `확인 대기 — 문서 <key>` for an approval line
# whose hash differs (or whose `tokens.css` is gone): the approval was given
# to other tokens, so it does not stand. `확인 형식 오류` for two or more
# confirmation lines or one that fits neither form. A confirmation line is
# any line whose key is `**확인**:`, a bullet or leading space before it or
# no space after the colon included, so a variant spelling surfaces as
# `확인 형식 오류` instead of passing as `확인 없음`. Every consumer reads
# `확인 형식 오류` as `확인 대기`.
confirm_state() {
  local lines n key want tf now
  [ -f "$1" ] || { echo '확인 없음'; return 0; }
  lines=$(LC_ALL=C grep -E '^[[:space:]]*(-[[:space:]]+)?\*\*확인\*\*:' "$1" || true)
  n=$(printf '%s' "$lines" | grep -c . || true)
  [ "$n" != 0 ] || { echo '확인 없음'; return 0; }
  [ "$n" = 1 ] || { echo '확인 형식 오류'; return 0; }
  if printf '%s\n' "$lines" | grep -qE '^\*\*확인\*\*: 대기 — 문서 [^[:space:]]+ — 런 [^[:space:]]+[[:space:]]*$'; then
    key=$(printf '%s\n' "$lines" | sed -E 's/^\*\*확인\*\*: 대기 — 문서 ([^[:space:]]+) — 런 .*$/\1/')
    echo "확인 대기 — 문서 ${key}"
  elif printf '%s\n' "$lines" | grep -qE '^\*\*확인\*\*: 사람 승인 — 문서 [^[:space:]]+ — tokens\.css sha256 [0-9a-f]{64} — 사람 답 [A-Za-z0-9._#-]+\.md — 런 [^[:space:]]+ — [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z[[:space:]]*$'; then
    key=$(printf '%s\n' "$lines" | sed -E 's/^\*\*확인\*\*: 사람 승인 — 문서 ([^[:space:]]+) — tokens\.css sha256 .*$/\1/')
    want=$(printf '%s\n' "$lines" | sed -E 's/^.* — tokens\.css sha256 ([0-9a-f]{64}) — .*$/\1/')
    tf="$(dirname "$1")/tokens.css"
    now=''
    [ ! -f "$tf" ] || now=$(sha256_of "$tf")
    if [ -n "$now" ] && [ "$now" = "$want" ]; then
      echo "사람 승인 — 문서 ${key}"
    else
      echo "확인 대기 — 문서 ${key}"
    fi
  else
    echo '확인 형식 오류'
  fi
}

# confirm_waiting <state> — succeed when the state stops screen work: a
# waiting line whatever document it names, or a malformed one.
confirm_waiting() {
  case "$1" in
    '확인 대기 — 문서 '*|'확인 형식 오류') return 0 ;;
  esac
  return 1
}

# system_tokens_line <system.md> — the value of its first
# `**tokens.css sha256**:` line, or nothing when there is none.
system_tokens_line() {
  sed -nE 's/^\*\*tokens\.css sha256\*\*:[[:space:]]*([^[:space:]]*)[[:space:]]*$/\1/p' "$1" | head -n 1
}

# system_tokens_match — succeed when the `**tokens.css sha256**` line of the
# base's system.md equals the sha256 of the base's tokens.css. A missing line
# or file is a mismatch. Sets TOK_LINE and TOK_FILE (`(없음)` when absent).
system_tokens_match() {
  local tf="$BASE/docs/visual-system/tokens.css"
  TOK_LINE=$(system_tokens_line "$BASE/docs/visual-system/system.md")
  [ -n "$TOK_LINE" ] || TOK_LINE='(없음)'
  if [ -f "$tf" ]; then TOK_FILE=$(sha256_of "$tf"); else TOK_FILE='(없음)'; fi
  [ "$TOK_LINE" != '(없음)' ] && [ "$TOK_FILE" != '(없음)' ] && [ "$TOK_LINE" = "$TOK_FILE" ]
}

cmd_system() {
  local doc='' owner_mode=0 why sys want norm full owner
  while [ $# -gt 0 ]; do
    case "$1" in
      --owner) owner_mode=1; shift ;;
      --*) usage ;;
      *) [ -z "$doc" ] || usage; doc=$1; shift ;;
    esac
  done
  [ -n "$doc" ] || usage
  [ -f "$doc" ] || { echo "visual-check.sh system: 설계 문서가 없다: $doc" >&2; exit 2; }
  if ! why=$(locate_sidecar "$doc"); then
    echo "visual-check.sh system: ${why}" >&2; exit 2
  fi
  locate_sidecar "$doc" >/dev/null
  sys="$BASE/docs/visual-system/system.md"
  if [ "$owner_mode" = 0 ]; then
    if [ -f "$sys" ]; then system_norm_sha "$sys"; else echo '(없음)'; fi
    return 0
  fi
  [ -f "$sys" ] || { echo "이 문서의 디자인 시스템 아님 — system.md 없음"; exit 1; }
  # A person's approval line that names this document makes the design system
  # this document's whatever its sidecar says; the tokens line is still
  # compared. A waiting line has no branch of its own and takes the sidecar
  # judgment below. The generation stage reaches this call over a waiting line
  # only on a resumed turn that chose to make screens on the unconfirmed
  # palette; the halt an exit 1 gives it there carries that earlier answer
  # forward, so the next turn does not ask the first question again.
  if [ "$(confirm_state "$sys")" = "사람 승인 — 문서 ${DOC_KEY}" ]; then
    system_tokens_match \
      || { echo "이 문서의 디자인 시스템 아님 — tokens.css sha256 줄이 실제 tokens.css 와 다르다"; exit 1; }
    echo "이 문서의 디자인 시스템 — 사람 확인"
    return 0
  fi
  [ -f "$SIDECAR" ] || { echo "이 문서의 디자인 시스템 아님 — 사이드카 없음"; exit 1; }
  owner=$(sidecar_owner)
  [ -n "$owner" ] || { echo "이 문서의 디자인 시스템 아님 — 사이드카 머리가 cc-visual v1 이 아니다"; exit 1; }
  [ "$owner" = "$DOC_KEY" ] || { echo "이 문서의 디자인 시스템 아님 — 사이드카의 owner-doc 이 이 문서가 아니다"; exit 1; }
  want=$(sidecar_field '디자인 시스템 sha256')
  norm=$(system_norm_sha "$sys")
  full=$(sha256_of "$sys")
  [ "$want" = "$norm" ] || [ "$want" = "$full" ] \
    || { echo "이 문서의 디자인 시스템 아님 — 디자인 시스템 다이제스트가 다르다"; exit 1; }
  system_tokens_match \
    || { echo "이 문서의 디자인 시스템 아님 — tokens.css sha256 줄이 실제 tokens.css 와 다르다"; exit 1; }
  echo "이 문서의 디자인 시스템"
}

cmd_confirm() {
  [ $# -eq 1 ] || usage
  local why
  [ -f "$1" ] || { echo "visual-check.sh confirm: 설계 문서가 없다: $1" >&2; exit 2; }
  if ! why=$(locate_sidecar "$1"); then
    echo "visual-check.sh confirm: ${why}" >&2; exit 2
  fi
  locate_sidecar "$1" >/dev/null
  confirm_state "$BASE/docs/visual-system/system.md"
}

cmd_system_users() {
  local doc='' also='' why sys norm='' full='' f owner want state appr any=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --also) [ $# -ge 2 ] || usage; also=$2; shift 2 ;;
      --*) usage ;;
      *) [ -z "$doc" ] || usage; doc=$1; shift ;;
    esac
  done
  [ -n "$doc" ] || usage
  [ -z "$also" ] || printf '%s' "$also" | grep -qE '^[0-9a-f]{64}$' \
    || { echo "visual-check.sh system-users: --also 값이 64자리 16진수가 아니다: $also" >&2; exit 2; }
  [ -f "$doc" ] || { echo "visual-check.sh system-users: 설계 문서가 없다: $doc" >&2; exit 2; }
  if ! why=$(locate_sidecar "$doc"); then
    echo "visual-check.sh system-users: ${why}" >&2; exit 2
  fi
  locate_sidecar "$doc" >/dev/null
  sys="$BASE/docs/visual-system/system.md"
  if [ -f "$sys" ]; then norm=$(system_norm_sha "$sys"); full=$(sha256_of "$sys"); fi
  for f in "$BASE"/docs/visual/*.md; do
    [ -f "$f" ] || continue
    SIDECAR=$f
    owner=$(sidecar_owner)
    [ -n "$owner" ] && [ "$owner" != "$DOC_KEY" ] || continue
    want=$(sidecar_field '디자인 시스템 sha256')
    [ -n "$want" ] || continue
    { [ -n "$norm" ] && { [ "$want" = "$norm" ] || [ "$want" = "$full" ]; }; } \
      || { [ -n "$also" ] && [ "$want" = "$also" ]; } || continue
    state=$(sed -nE 's/^\*\*상태\*\*:[[:space:]]*(.*[^[:space:]])[[:space:]]*$/\1/p' "$f" | head -n 1)
    if grep -qE '^\*\*구현 승인\*\*:' "$f"; then appr='구현 승인 있음'; else appr='구현 승인 없음'; fi
    printf '%s — 상태 %s — %s\n' "$owner" "${state:-없음}" "$appr"
    any=1
  done
  [ "$any" = 1 ] || echo '없음'
}

# halt_step_has_prefix <halt record> <prefix> — the record's first `**스텝**`
# value is the prefix, or starts with `<prefix> — `. The driver's function of
# the same name reads the same field the same way.
halt_step_has_prefix() {
  local step
  [ -f "$1" ] || return 1
  step=$(sed -n 's/^\*\*스텝\*\*: //p' "$1" 2>/dev/null | sed -n 1p | sed 's/[[:space:]]*$//')
  [ "$step" = "$2" ] && return 0
  case "$step" in "$2 — "*) return 0 ;; esac
  return 1
}

# run_answer_rows <ledger> <run id> — this run's `중단 답` rows, scoped as the
# driver's `run_section_rows` scopes them: the block under `## 실행 <run id>`
# when the ledger carries such headings, the whole file when it carries none
# and is named `<run id>.md`, and nothing otherwise.
run_answer_rows() {
  local scope
  [ -f "$1" ] || return 0
  if grep -qE '^## 실행 ' "$1" 2>/dev/null; then
    scope=블록
  elif [ "$(basename "$1")" = "$2.md" ]; then
    scope=파일
  else
    return 0
  fi
  awk -v h="## 실행 $2" -v scope="$scope" '
    BEGIN { whole = (scope == "파일"); inblk = whole }
    !whole && $0 == h { inblk = 1; next }
    !whole && substr($0, 1, 3) == "## " { inblk = 0 }
    inblk && index($0, "- `중단 답`") == 1 { print }
  ' "$1"
}

# row_field <row> <key> — the last `<key>=` value of a ledger row.
row_field() {
  printf '%s' "$1" | tr '|' '\n' | sed -n "s/^ *$2=//p" | sed 's/[[:space:]]*$//' | tail -1
}

# person_answer <rows file> <halt record> — the option of the last row that
# answers the record (its `중단 기록` names the same file) and was given by a
# person; nothing when there is none. The driver's
# `visual_publish_person_answer` reads the same rows the same way.
person_answer() {
  local row f by opt=''
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    f=$(row_field "$row" '중단 기록')
    [ "${f##*/}" = "${2##*/}" ] || continue
    by=$(row_field "$row" '답한 주체')
    [ "$by" = 사람 ] || continue
    opt=$(row_field "$row" '선택지')
  done < "$1"
  printf '%s' "$opt"
}

# latest_record <halt dir> <prefix> — the `S2P#<n>.md` record under the halt
# directory whose step has the prefix and whose attempt number is largest.
latest_record() {
  local f b n best='' bestn=-1
  [ -d "$1" ] || return 0
  for f in "$1"/S2P#*.md; do
    [ -f "$f" ] || continue
    b=${f##*/}; n=${b#S2P#}; n=${n%.md}
    case "$n" in ''|*[!0-9]*) continue ;; esac
    halt_step_has_prefix "$f" "$2" || continue
    if [ "$((10#$n))" -gt "$bestn" ]; then bestn=$((10#$n)); best=$f; fi
  done
  printf '%s' "$best"
}

# cmd_run_state <design doc> --run-dir <dir> --ledger <file> --manifest <file>
# — the design system phase state of one run, on seven fixed lines:
#   S2P 있음|없음
#   디자인-시스템-판정 기록 <file name>|없음
#   디자인-시스템-판정 사람 답 <option>|없음
#   시각-판정 기록 <file name>|없음
#   시각-판정 사람 답 <option>|없음
#   수정 횟수 <n>
#   확인 <the line `confirm` prints>
# `S2P` is the plan's step whose `skill` is `visual-publish`, read from the
# fenced JSON block under `## 실행 계획`. The two records are the latest of
# each site in the run's `halt/`, and an answer is a person's last `중단 답`
# row for that record. The revision count is the number of `S2P` records whose
# person's last answer is `수정 요청` (a `디자인-시스템-판정` record) or
# `디자인 시스템 다시 열기` (a `시각-판정` record), less those a
# `디자인-시스템-판정` record names with `입력 없음=<file name>`. The run id is
# the run directory's base name. Exits 0; 2 on a usage error or an unreadable
# document, like `confirm`.
cmd_run_state() {
  local doc='' rdir='' ledger='' manifest='' why rid halt rows s2p ds dsa vv vva f a n=0 skip
  while [ $# -gt 0 ]; do
    case "$1" in
      --run-dir) [ $# -ge 2 ] || usage; rdir=$2; shift 2 ;;
      --ledger) [ $# -ge 2 ] || usage; ledger=$2; shift 2 ;;
      --manifest) [ $# -ge 2 ] || usage; manifest=$2; shift 2 ;;
      --*) usage ;;
      *) [ -z "$doc" ] || usage; doc=$1; shift ;;
    esac
  done
  [ -n "$doc" ] && [ -n "$rdir" ] && [ -n "$ledger" ] && [ -n "$manifest" ] || usage
  [ -f "$doc" ] || { echo "visual-check.sh run-state: 설계 문서가 없다: $doc" >&2; exit 2; }
  if ! why=$(locate_sidecar "$doc"); then
    echo "visual-check.sh run-state: ${why}" >&2; exit 2
  fi
  locate_sidecar "$doc" >/dev/null
  rid=$(basename "$rdir")
  halt="$rdir/halt"
  s2p=없음
  if [ -f "$manifest" ] && command -v jq >/dev/null 2>&1; then
    if [ "$(awk '
          $0 == "## 실행 계획" { inb=1; next }
          inb && /^## / { exit }
          inb && !fence && /^```json/ { fence=1; next }
          inb && fence && /^```/ { exit }
          inb && fence { print }
        ' "$manifest" \
        | jq -r '[.steps[]? | select(type == "object" and .skill == "visual-publish")] | length' 2>/dev/null \
        || true)" = 1 ]; then
      s2p=있음
    fi
  fi
  WORK=$(mktemp -d "${TMPDIR:-/tmp}/visual-check.XXXXXX")
  trap 'rm -rf "$WORK"' EXIT
  rows="$WORK/rows"
  run_answer_rows "$ledger" "$rid" > "$rows"
  ds=$(latest_record "$halt" '디자인-시스템-판정')
  vv=$(latest_record "$halt" '시각-판정')
  dsa=''; vva=''
  [ -z "$ds" ] || dsa=$(person_answer "$rows" "$ds")
  [ -z "$vv" ] || vva=$(person_answer "$rows" "$vv")
  : > "$WORK/skip"
  for f in "$halt"/S2P#*.md; do
    [ -f "$f" ] || continue
    halt_step_has_prefix "$f" '디자인-시스템-판정' || continue
    { grep -oE '입력 없음=[A-Za-z0-9._#-]+\.md' "$f" || true; } | sed 's/^입력 없음=//' >> "$WORK/skip"
  done
  for f in "$halt"/S2P#*.md; do
    [ -f "$f" ] || continue
    skip=0
    grep -qxF -- "${f##*/}" "$WORK/skip" && skip=1
    [ "$skip" = 0 ] || continue
    a=$(person_answer "$rows" "$f")
    if halt_step_has_prefix "$f" '디자인-시스템-판정'; then
      [ "$a" != '수정 요청' ] || n=$((n + 1))
    elif halt_step_has_prefix "$f" '시각-판정'; then
      [ "$a" != '디자인 시스템 다시 열기' ] || n=$((n + 1))
    fi
  done
  [ -z "$ds" ] || ds=${ds##*/}
  [ -z "$vv" ] || vv=${vv##*/}
  echo "S2P ${s2p}"
  echo "디자인-시스템-판정 기록 ${ds:-없음}"
  echo "디자인-시스템-판정 사람 답 ${dsa:-없음}"
  echo "시각-판정 기록 ${vv:-없음}"
  echo "시각-판정 사람 답 ${vva:-없음}"
  echo "수정 횟수 ${n}"
  echo "확인 $(confirm_state "$BASE/docs/visual-system/system.md")"
}

cmd_reuse() {
  local doc='' rec='' why owner state recf recsha want now full sys blocks id path bsha fp
  while [ $# -gt 0 ]; do
    case "$1" in
      --record) [ $# -ge 2 ] || usage; rec=$2; shift 2 ;;
      --*) usage ;;
      *) [ -z "$doc" ] || usage; doc=$1; shift ;;
    esac
  done
  [ -n "$doc" ] && [ -n "$rec" ] || usage
  [ -f "$doc" ] || { echo "visual-check.sh reuse: 설계 문서가 없다: $doc" >&2; exit 2; }
  [ -f "$rec" ] || { echo "visual-check.sh reuse: 기록 파일이 없다: $rec" >&2; exit 2; }
  if ! why=$(locate_sidecar "$doc"); then
    echo "재사용 불가 — ${why}"; exit 1
  fi
  locate_sidecar "$doc" >/dev/null
  # 1 — the sidecar is there, its header is `cc-visual v1` and names this document.
  [ -f "$SIDECAR" ] || { echo "재사용 불가 — 사이드카 없음 (${SIDECAR})"; exit 1; }
  owner=$(sidecar_owner)
  [ -n "$owner" ] || { echo "재사용 불가 — 사이드카 머리가 cc-visual v1 이 아니다"; exit 1; }
  [ "$owner" = "$DOC_KEY" ] || { echo "재사용 불가 — 사이드카의 owner-doc 이 이 문서가 아니다"; exit 1; }
  # 2 — the state is one a visual stage may end on.
  state=$(sed -nE 's/^\*\*상태\*\*:[[:space:]]*(.*[^[:space:]])[[:space:]]*$/\1/p' "$SIDECAR" | head -n 1)
  case "$state" in
    '검토 통과'|발행됨) ;;
    *) echo "재사용 불가 — 상태가 검토 통과·발행됨이 아니다 (${state:-없음})"; exit 1 ;;
  esac
  # 3 — the record's hash; its path is not compared.
  recf=$(sidecar_field '기록')
  recsha=$(printf '%s\n' "$recf" | sed -nE 's/^.*\(sha256 ([0-9a-f]{64})\)$/\1/p')
  now=$(sha256_of "$rec")
  [ -n "$recsha" ] || { echo "재사용 불가 — 사이드카의 기록 필드에 sha256 이 없다 (${recf:-없음})"; exit 1; }
  [ "$recsha" = "$now" ] || { echo "재사용 불가 — 기록의 sha256 이 다르다 (사이드카 ${recsha:0:12}, 기록 ${now:0:12})"; exit 1; }
  # 4 — the design document's binding digest.
  want=$(sidecar_field '설계 문서 구속 다이제스트')
  now=$(binding_text "$doc" | sha256_stdin)
  [ "$want" = "$now" ] || { echo "재사용 불가 — 설계 문서 구속 다이제스트가 다르다 (사이드카 ${want:0:12}, 지금 ${now:0:12})"; exit 1; }
  # 5a — the design system file as it is now, with its artifact line put back
  # to unpublished; an older sidecar's whole-file hash is taken too.
  want=$(sidecar_field '디자인 시스템 sha256')
  sys="$BASE/docs/visual-system/system.md"
  if [ -f "$sys" ]; then
    now=$(system_norm_sha "$sys"); full=$(sha256_of "$sys")
  else
    now='(없음)'; full='(없음)'
  fi
  [ "$want" = "$now" ] || [ "$want" = "$full" ] \
    || { echo "재사용 불가 — 디자인 시스템 sha256 이 다르다 (사이드카 ${want:0:12}, 지금 ${now:0:12})"; exit 1; }
  # 5b — the tokens line of an existing system.md names the tokens file as it is.
  if [ -f "$sys" ] && ! system_tokens_match; then
    echo "재사용 불가 — tokens.css 가 system.md 의 tokens.css sha256 줄과 다르다 (줄 ${TOK_LINE:0:12}, 파일 ${TOK_FILE:0:12})"; exit 1
  fi
  # 6 — every screen block's file is there with the block's sha256.
  blocks=$(awk '
    /^### 화면 / { if (id != "") print id "\t" p "\t" s; id = $3; p = ""; s = ""; next }
    /^### / { if (id != "") print id "\t" p "\t" s; id = ""; next }
    id != "" && index($0, "**대상 경로**:") == 1 { p = substr($0, length("**대상 경로**:") + 1); gsub(/^[[:space:]]+|[[:space:]]+$/, "", p) }
    id != "" && index($0, "**sha256**:") == 1 { s = substr($0, length("**sha256**:") + 1); gsub(/^[[:space:]]+|[[:space:]]+$/, "", s) }
    END { if (id != "") print id "\t" p "\t" s }
  ' "$SIDECAR")
  [ -n "$blocks" ] || { echo "재사용 불가 — 사이드카에 화면이 없다"; exit 1; }
  while IFS="$(printf '\t')" read -r id path bsha; do
    [ -n "$id" ] || continue
    [ -n "$path" ] || { echo "재사용 불가 — 화면 ${id} 의 대상 경로가 없다"; exit 1; }
    fp="$BASE/$path"
    [ -f "$fp" ] || { echo "재사용 불가 — 화면 파일 없음 (${id})"; exit 1; }
    now=$(sha256_of "$fp")
    [ "$now" = "$bsha" ] || { echo "재사용 불가 — 화면 ${id} 의 sha256 이 다르다 (블록 ${bsha:0:12}, 파일 ${now:0:12})"; exit 1; }
  done <<EOF
$blocks
EOF
  echo "재사용 ${state}"
}

[ $# -ge 1 ] || usage
sub=$1
shift
case "$sub" in
  scan) cmd_scan "$@" ;;
  size) cmd_size "$@" ;;
  approval) cmd_approval "$@" ;;
  drift) cmd_drift "$@" ;;
  bundle) cmd_bundle "$@" ;;
  binding) cmd_binding "$@" ;;
  system) cmd_system "$@" ;;
  confirm) cmd_confirm "$@" ;;
  system-users) cmd_system_users "$@" ;;
  run-state) cmd_run_state "$@" ;;
  reuse) cmd_reuse "$@" ;;
  *) usage ;;
esac
