#!/usr/bin/env bash
#
# lint-gate-banner-fields.sh — the machine-readable section banners of
# scripts/test-gate.sh may declare only the fields the selector reads, spelled
# exactly the way the selector reads them.
#
# The selector parses a banner with loose patterns: a field is found by
# `| <key>:` and anything it does not look for is skipped. So a misspelt field
# — `need: 9`, `needs : 9`, ` needs: 9` without its bar — is not an error
# anywhere. It is silently not a declaration: the author wrote a dependency, the
# cut does not carry it, and the section fails in a narrowed run for a reason
# its banner says was handled. This lint turns that silence into a failure.
#
# Rules, on every line that starts with `# --- section: `:
#
#   1  the line closes with ` ---`
#   2  the first field is `section: <id>`, the id in the selector's charset
#   3  every field is `<key>: <value>` — a lower-case key, one colon, one space,
#      a non-empty value with no surrounding blanks — and fields are separated
#      by ` | ` exactly
#   4  every key after the first is one of the closed set group, covers, needs,
#      anchors
#   5  no key appears twice on one banner
#   6  every id a `needs:` names is a section id declared in the same file, and
#      is not the banner's own id
#
# Usage: bash scripts/lint-gate-banner-fields.sh
#
# Env override (fixture runner):
#   GATE_BANNER_FIELDS_TARGET=<file>   file to lint (default scripts/test-gate.sh)
#
# Exit codes:
#   0  the banners were read and none violates a rule
#   1  at least one violation
#   2  the check COULD NOT BE CARRIED OUT — the target is missing or carries no
#      banner at all. That is not "checked and clean": a renamed marker would
#      otherwise turn this lint green over a file it never read.
#
# No awk: the anchors are Korean, and a multibyte-unsafe awk build on one CI
# host is exactly the kind of difference that reports a clean file as broken or
# the reverse. Field splitting is done with shell parameter expansion on ASCII
# delimiters only.
#
# Compatibility: bash 3.2 (macOS) — no associative arrays, no mapfile.

set -uo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
target="${GATE_BANNER_FIELDS_TARGET:-$repo_root/scripts/test-gate.sh}"
label=$(basename "$target")

if [ ! -f "$target" ]; then
  printf 'ERR: 대상 파일이 없다: %s\n' "$target" >&2
  exit 2
fi

banners=$(grep -n '^# --- section: ' "$target" || true)
if [ -z "$banners" ]; then
  printf 'ERR: %s — `# --- section: ` 배너가 하나도 없다 — 읽은 것이 없으므로 통과로 보고하지 않는다\n' "$label" >&2
  exit 2
fi

fail=0
viol() {
  # $1 line number, $2 message
  printf 'FAIL: %s:%s: %s\n' "$label" "$1" "$2" >&2
  fail=1
}

# --- pass 1: the declared ids ----------------------------------------------
# Collected before any `needs:` is judged, so a banner may name a section that
# is declared further down the file.
ids=" "
while IFS= read -r row; do
  [ -n "$row" ] || continue
  body=${row#*:}
  body=${body#'# --- section: '}
  id=${body%%|*}
  id=${id%' ---'}
  id=${id%' '}
  ids="$ids$id "
done <<EOF
$banners
EOF

# --- pass 2: every banner, field by field ----------------------------------
needs_rows=""
nbanner=0
while IFS= read -r row; do
  [ -n "$row" ] || continue
  nbanner=$((nbanner + 1))
  ln=${row%%:*}
  line=${row#*:}

  case "$line" in
    *' ---') ;;
    *) viol "$ln" "배너가 ' ---' 로 닫히지 않는다"; continue ;;
  esac
  rest=${line#'# --- '}
  rest=${rest%' ---'}

  idx=0
  seen=" "
  own_id=""
  while :; do
    case "$rest" in
      *'|'*) field=${rest%%|*}; rest=${rest#*|}; more=1 ;;
      *)     field=$rest; more=0 ;;
    esac
    idx=$((idx + 1))

    if [ "$idx" -gt 1 ]; then
      case "$field" in
        ' '[!' ']*) field=${field#' '} ;;
        *) viol "$ln" "필드 ${idx} 앞의 구분자가 ' | ' 가 아니다: 「${field}」"; [ "$more" = 1 ] || break; continue ;;
      esac
    fi
    if [ "$more" = 1 ]; then
      case "$field" in
        *[!' ']' ') field=${field%' '} ;;
        *) viol "$ln" "필드 ${idx} 뒤의 구분자가 ' | ' 가 아니다: 「${field}」"; continue ;;
      esac
    fi

    case "$field" in
      *:*) ;;
      *) viol "$ln" "필드 ${idx} 에 키가 없다: 「${field}」"; [ "$more" = 1 ] || break; continue ;;
    esac
    key=${field%%:*}
    value=${field#*:}
    case "$key" in
      ''|*[!a-z]*)
        viol "$ln" "키 표기가 소문자 단어가 아니다(공백·대문자 포함): 「${key}」"
        [ "$more" = 1 ] || break; continue ;;
    esac
    case "$value" in
      ' '[!' ']*) value=${value#' '} ;;
      *) viol "$ln" "'${key}:' 뒤가 공백 하나 + 값이 아니다: 「${field}」"; [ "$more" = 1 ] || break; continue ;;
    esac
    case "$value" in
      *' ') viol "$ln" "'${key}:' 의 값이 공백으로 끝난다"; [ "$more" = 1 ] || break; continue ;;
    esac
    # A field glued on without its bar — `group: base needs: 9` — reads as one
    # field whose value swallowed the next declaration, so the selector's
    # `| needs:` never sees it. Anchor labels may carry a colon of their own
    # (`4c: …`), so what is refused is a KNOWN KEY in key position, not any colon.
    case " $value" in
      *' section: '*|*' group: '*|*' covers: '*|*' needs: '*|*' anchors: '*)
        viol "$ln" "'${key}:' 의 값 안에 다른 필드가 ' | ' 없이 붙어 있다: 「${value}」"
        [ "$more" = 1 ] || break; continue ;;
    esac

    if [ "$idx" = 1 ]; then
      if [ "$key" != "section" ]; then
        viol "$ln" "첫 필드가 'section:' 이 아니다: 「${key}」"
      else
        case "$value" in
          -|*[!A-Za-z0-9_-]*) viol "$ln" "절 id 가 선택자의 문자 집합 밖이다: 「${value}」" ;;
          *) own_id=$value ;;
        esac
      fi
    else
      case "$key" in
        group|covers|needs|anchors) ;;
        *) viol "$ln" "모르는 키다 — 선택자가 읽지 않으므로 선언이 조용히 무시된다: 「${key}」 (허용: group, covers, needs, anchors)" ;;
      esac
    fi

    case "$seen" in
      *" $key "*) viol "$ln" "같은 키가 두 번 있다: 「${key}」" ;;
      *) seen="$seen$key " ;;
    esac

    # `|` as the row delimiter: a banner field cannot contain one (it is the
    # field separator), and a whitespace IFS would fold an empty own id away.
    if [ "$key" = "needs" ] && [ "$idx" -gt 1 ]; then
      needs_rows="$needs_rows$ln|$own_id|$value
"
    fi

    [ "$more" = 1 ] || break
  done
done <<EOF
$banners
EOF

# --- rule 6: what `needs:` names -------------------------------------------
while IFS='|' read -r ln own list; do
  [ -n "$ln" ] || continue
  rest="$list,"
  while [ -n "$rest" ]; do
    item=${rest%%,*}
    rest=${rest#*,}
    item=${item#"${item%%[![:space:]]*}"}
    item=${item%"${item##*[![:space:]]}"}
    if [ -z "$item" ]; then
      viol "$ln" "needs: 에 빈 항목이 있다: 「${list}」"
      continue
    fi
    case "$ids" in
      *" $item "*) ;;
      *) viol "$ln" "needs: 가 이 파일에 없는 절 id 를 가리킨다: 「${item}」"; continue ;;
    esac
    if [ -n "$own" ] && [ "$item" = "$own" ]; then
      viol "$ln" "needs: 가 자기 자신을 가리킨다: 「${item}」"
    fi
  done
done <<EOF
$needs_rows
EOF

if [ "$fail" -ne 0 ]; then
  printf 'FAIL: gate-banner-fields — %s 배너 %d개 중 위반이 있다\n' "$label" "$nbanner" >&2
  exit 1
fi

printf 'OK:   gate-banner-fields — %s 배너 %d개, 필드 어휘·needs 대상 일치\n' "$label" "$nbanner"
exit 0
