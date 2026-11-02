#!/usr/bin/env bash
# Test plugins/cc-cmds/orchestrator/stage-rules.sh — the tag grammar of a
# person's global instruction file, the `[무인]` block the gate freezes at run
# open, the `status` report and the `migrate` proposal.
#
# EVERY INPUT IS A FIXTURE under a scratch directory. `HOME` and
# `CLAUDE_CONFIG_DIR` point there too, so the person's own instruction file,
# host map and acknowledgement store are never read.
#
# THE PIPELINE RUN ID IS UNSET FOR EVERY RUN except the case that sets it:
# `migrate` refuses under it, and inside an unattended stage every positive
# `migrate` case would otherwise fail for the wrong reason.

set -uo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
SR="$repo_root/plugins/cc-cmds/orchestrator/stage-rules.sh"

passed=0
failed=0
ok()   { passed=$((passed + 1)); printf 'PASS: %s\n' "$1"; }
bad()  { failed=$((failed + 1)); printf 'FAIL: %s — %s\n' "$1" "${2:-}" >&2; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got '$2', want '$3'"; fi; }
has()  { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "'$3' not in: $2" ;; esac; }
hasnt(){ case "$2" in *"$3"*) bad "$1" "'$3' found in: $2" ;; *) ok "$1" ;; esac; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/cc-stage-rules.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
FAKE_HOME="$WORK/home"
mkdir -p "$FAKE_HOME"

# sr <args...> — runs the script outside any run; sets RC, output in OUT / ERR.
OUTF="$WORK/sr.out"
ERRF="$WORK/sr.err"
sr() {
  env -u CC_PIPELINE_RUN_ID -u CC_GATE_STAGE_POLICY_SOURCES HOME="$FAKE_HOME" \
    CLAUDE_CONFIG_DIR="$FAKE_HOME/.claude" bash "$SR" "$@" > "$OUTF" 2> "$ERRF"
  RC=$?
  OUT=$(cat "$OUTF")
}
sha_of() { shasum -a 256 "$1" | cut -d' ' -f1; }

# ---------- tag grammar and extract ------------------------------------------

SRC="$WORK/tags.md"
printf '%s' '- [무인] alpha rule
    continued alpha
  - sub bullet of alpha
- [대화형] beta rule
- gamma untagged
- [무인]delta no space
- [무인 ] epsilon
- [unattended] zeta
# a heading outside every bullet
outside line
- [무인] eta rule
' > "$SRC"
WANT_BLOCK='- alpha rule
    continued alpha
  - sub bullet of alpha
- eta rule
'

sr extract --source "$SRC"
check "extract: rc 0" "$RC" "0"
check "extract: 태그만 지우고 하위 불릿과 이어지는 줄을 그대로 둔다, 불릿 밖 줄은 싣지 않는다" \
  "$(cat "$OUTF")" "$(printf '%s' "$WANT_BLOCK")"
check "extract: 블록 바이트 그대로 (끝 줄바꿈 포함)" "$(sha_of "$OUTF")" \
  "$(printf '%s' "$WANT_BLOCK" | shasum -a 256 | cut -d' ' -f1)"

BYTES=$(printf '%s' "$WANT_BLOCK" | wc -c | tr -d ' ')
TOK=$(awk -v b="$BYTES" 'BEGIN { printf "%d", b * 0.460 + 0.5 }')
WANT_STATUS="stage rules: ok unattended=2 bytes=$BYTES tokens~$TOK interactive=1 untagged=1 malformed=3"

RD="$WORK/run/instructions/personal"
sr extract --source "$SRC" --out-dir "$RD"
check "extract --out-dir: rc 0" "$RC" "0"
check "extract --out-dir: 상태 줄 하나" "$OUT" "$WANT_STATUS"
BSHA=$(printf '%s' "$WANT_BLOCK" | shasum -a 256 | cut -d' ' -f1)
check "extract --out-dir: 내용 주소 파일" "$( [ -f "$RD/$BSHA.md" ] && sha_of "$RD/$BSHA.md")" "$BSHA"
check "extract --out-dir: 포인터는 sha 와 원천 경로" "$(cat "$RD/current")" "$BSHA $SRC"
check "extract --out-dir: 임시 파일이 남지 않는다" "$(ls -A "$RD" | grep -c '^\.' || true)" "0"

# A second extract — another source — never replaces the published pointer.
SRC2="$WORK/tags2.md"
printf -- '- [무인] another rule\n' > "$SRC2"
sr extract --source "$SRC2" --out-dir "$RD"
check "extract --out-dir: 이미 있는 포인터를 덮지 않는다" "$(cat "$RD/current")" "$BSHA $SRC"
check "extract --out-dir: 경합에 진 쪽도 임시 파일을 남기지 않는다" "$(ls -A "$RD" | grep -c '^\.' || true)" "0"

UNT="$WORK/untagged.md"
printf -- '- one rule\n- two rule\n' > "$UNT"
sr extract --source "$UNT"
check "extract: 무태그 원천은 레거시 줄" "$OUT" "stage rules: untagged — legacy v6 policy"
LEG_SHA=$(sha_of "$OUTF")
RD2="$WORK/run2"
sr extract --source "$UNT" --out-dir "$RD2"
check "extract --out-dir: 무태그 상태 줄" "$OUT" "stage rules: untagged — legacy v6 policy"
check "extract --out-dir: 무태그 포인터" "$(cat "$RD2/current")" "legacy untagged"
check "extract --out-dir: 무태그면 스냅숏 파일이 없다" "$(ls "$RD2" | grep -c '\.md$' || true)" "0"

EMPTYU="$WORK/interactive-only.md"
printf -- '- [대화형] only interactive\n' > "$EMPTYU"
sr extract --source "$EMPTYU"
check "extract: 태그 모드인데 [무인] 이 비면 빈 출력" "$(wc -c < "$OUTF" | tr -d ' ')" "0"
check "extract: 무태그와 빈 [무인] 블록의 출력이 바이트로 다르다" \
  "$([ "$(sha_of "$OUTF")" != "$LEG_SHA" ] && echo differ || echo same)" "differ"

sr extract --source "$WORK/absent.md"
check "extract: 없는 원천은 빈 원천(무태그)" "$OUT" "stage rules: untagged — legacy v6 policy"

sr extract
check "extract: --source 없으면 rc 2" "$RC" "2"

# ---------- status -------------------------------------------------------------

sr status --source "$SRC"
check "status: rc 0" "$RC" "0"
has "status: 상태 줄" "$OUT" "$WANT_STATUS"
has "status: 무인 바이트와 토큰" "$OUT" "unattended: 2 bullet(s), $BYTES bytes, about $TOK tokens"
has "status: 태그 없는 불릿 목록" "$OUT" "untagged line 5: gamma untagged"
has "status: 공백 없는 태그는 형식 오류" "$OUT" "malformed tag line 6: [무인]delta no space"
has "status: [무인 ] 은 형식 오류" "$OUT" "malformed tag line 7: [무인 ] epsilon"
has "status: [unattended] 는 형식 오류" "$OUT" "malformed tag line 8: [unattended] zeta"
hasnt "status: 24576 이하면 알림 없음" "$OUT" "alert:"
has "status: 호스트 맵 없음" "$OUT" "host map: $FAKE_HOME/.config/cc-cmds/stage-policy-sources (absent)"
has "status: 맵이 없으면 작업공간 제외 줄 안내" "$OUT" "workspace<TAB><absolute path>"
hasnt "status: 태그 모드에서는 이관 안내 없음" "$OUT" "ClickUp 발행 슬라이스가 머지된 플러그인에서 이관"

# the first 40 characters, counted as characters
LONG="$WORK/long.md"
K40=""
i=0
while [ "$i" -lt 40 ]; do K40="${K40}가"; i=$((i + 1)); done
printf -- '- [무인] x\n- %s나나나\n' "$K40" > "$LONG"
sr status --source "$LONG"
has "status: 태그 없는 불릿은 앞 40자" "$OUT" "untagged line 2: $K40"$'\n'

# the 24576-byte alert, at the boundary: the block is `- ` + N bytes + newline
mkbig() { # mkbig <file> <block bytes>
  awk -v n="$(( $2 - 3 ))" 'BEGIN { printf "- [무인] "; for (i = 0; i < n; i++) printf "x"; printf "\n" }' > "$1"
}
mkbig "$WORK/b24575.md" 24575
sr status --source "$WORK/b24575.md"
has "status 24575: 바이트" "$OUT" "unattended: 1 bullet(s), 24575 bytes"
hasnt "status 24575: 알림 없음" "$OUT" "alert:"
mkbig "$WORK/b24577.md" 24577
sr status --source "$WORK/b24577.md"
has "status 24577: 알림" "$OUT" "alert: the [무인] block is 24577 bytes, past 24576"
check "status 24577: rc 0 (알림은 거부가 아니다)" "$RC" "0"

# a credential-shaped string is warned about and never printed
CRED="$WORK/cred.md"
printf -- '- [무인] the api_key = Zq81kT0pLm42xw\n- [대화형] password = Ab12Cd34Ef56Gh\n' > "$CRED"
sr status --source "$CRED"
has "status: 자격증명 모양 경고" "$OUT" "warning: line 1 — a [무인] bullet carries a credential-shaped string"
hasnt "status: 경고에 일치 내용이 없다" "$OUT" "Zq81kT0pLm42xw"
hasnt "status: [대화형] 불릿은 경고하지 않는다" "$OUT" "warning: line 2"

# legacy state: the fixed migration text and the migrate command
sr status --source "$UNT"
has "status 무태그: 레거시 상태" "$OUT" "mode: legacy untagged"
has "status 무태그: 고정 문면" "$OUT" "  - ClickUp 발행 슬라이스가 머지된 플러그인에서 이관"
has "status 무태그: migrate 안내" "$OUT" "stage-rules.sh migrate --source $UNT"
check "status 무태그: rc 0" "$RC" "0"

# the host map, through the gate's own seam
MAP="$WORK/map"
printf 'workspace\t/somewhere/CLAUDE.md\n' > "$MAP"
env -u CC_PIPELINE_RUN_ID HOME="$FAKE_HOME" CC_GATE_STAGE_POLICY_SOURCES="$MAP" \
  bash "$SR" status --source "$SRC" > "$OUTF" 2> "$ERRF"
OUT=$(cat "$OUTF")
has "status: 호스트 맵 경로" "$OUT" "host map: $MAP"
has "status: 호스트 맵 항목" "$OUT" "$(printf '  workspace\t/somewhere/CLAUDE.md')"
hasnt "status: 맵의 workspace 줄이 있으면 제외 안내 없음" "$OUT" "workspace<TAB><absolute path>"

# the default source is the user-scope instruction file
mkdir -p "$FAKE_HOME/.claude"
cp "$SRC" "$FAKE_HOME/.claude/CLAUDE.md"
sr status
has "status: 기본 원천은 설정 디렉터리의 CLAUDE.md" "$OUT" "source: $FAKE_HOME/.claude/CLAUDE.md"

sr status --bogus
check "status: 모르는 인자는 rc 2" "$RC" "2"

# ---------- migrate --------------------------------------------------------------

TABLE="$WORK/table.tsv"
{
  printf 'source\tanchor\tsha256\tdisposition\tnote\n'
  printf 'user-scope\tpol anchor\t%064d\tpolicy:Conduct\t\n' 0
  printf 'user-scope\tskill anchor\t%064d\tskill:local-html\t\n' 0
  printf 'user-scope\texcl anchor\t%064d\texcluded:interactive-only\t\n' 0
  printf 'user-scope\tboth anchor\t%064d\tpolicy:Artifacts\t\n' 0
  printf 'user-scope\t이 파일이 사용자에게 알림 배너를\t%064d\tpolicy:Delegation\t\n' 0
  printf 'workspace\t# none anchor\t%064d\texcluded:workspace-local\t\n' 0
} > "$TABLE"
STORE="$WORK/ack"
mkdir -p "$STORE"
{
  printf 'source\tanchor\tsha256\tdisposition\tacked-at\n'
  printf 'user-scope\thost skill\t%064d\tskill:clickup-ops\t2026-10-19T00:00:00Z\n' 0
  printf 'user-scope\thost excl\t%064d\texcluded:interactive-only\t2026-10-19T00:00:00Z\n' 0
  printf 'user-scope\tboth anchor\t%064d\texcluded:interactive-only\t2026-10-19T00:00:00Z\n' 0
} > "$STORE/acks.tsv"
MSRC="$WORK/migrate-src.md"
printf '%s' '- pol anchor rule
    with a continuation
- skill anchor rule
- excl anchor rule
- both anchor rule
- host skill rule
- host excl rule
- none anchor rule
- 이 파일이 사용자에게 알림 배너를 띄우는 규칙
' > "$MSRC"
MSRC_SHA=$(sha_of "$MSRC")
MOUT="$WORK/proposed.md"
sr migrate --source "$MSRC" --legacy-table "$TABLE" --ack-store "$STORE" --out "$MOUT"
check "migrate: rc 0" "$RC" "0"
check "migrate: 여섯 갈래의 태그" "$(cat "$MOUT")" "$(printf '%s' '- [무인] pol anchor rule
    with a continuation
- [무인] skill anchor rule
- [대화형] excl anchor rule
- [무인] both anchor rule
- [무인] host skill rule
- [대화형] host excl rule
- none anchor rule
- [무인] 이 파일이 사용자에게 알림 배너를 띄우는 규칙
')"
has "migrate: 표 policy 근거" "$OUT" "$(printf 'line 1\t[무인]\ttable policy:Conduct')"
has "migrate: 표 skill 근거" "$OUT" "$(printf 'line 3\t[무인]\ttable skill:local-html')"
has "migrate: 표 excluded 근거" "$OUT" "$(printf 'line 4\t[대화형]\ttable excluded:interactive-only')"
has "migrate: 표가 호스트 행보다 우선" "$OUT" "$(printf 'line 5\t[무인]\ttable policy:Artifacts')"
has "migrate: 호스트 전용 skill" "$OUT" "$(printf 'line 6\t[무인]\thost skill:clickup-ops')"
has "migrate: 호스트 전용 excluded" "$OUT" "$(printf 'line 7\t[대화형]\thost excluded:interactive-only')"
has "migrate: 행 없음은 태그 없음" "$OUT" "$(printf 'line 8\t(none)\tno row')"
has "migrate: 불릿 바이트 보고" "$OUT" "$(printf 'line 1\t[무인]\ttable policy:Conduct\t42 bytes')"
has "migrate: 알림 배너 불릿 추천 줄" "$OUT" "recommend line 9: [대화형]"
has "migrate: 합계" "$OUT" "total: unattended=5"
has "migrate: 합계의 대화형과 태그 없음" "$OUT" "interactive=2"
check "migrate: 원천 sha 불변" "$(sha_of "$MSRC")" "$MSRC_SHA"

# the banner bullet is found by its anchor text, not by its line
MSRC2="$WORK/migrate-src2.md"
printf '%s' '- 이 파일이 사용자에게 알림 배너를 띄우는 규칙
- pol anchor rule
' > "$MSRC2"
sr migrate --source "$MSRC2" --legacy-table "$TABLE" --ack-store "$STORE" --out "$WORK/proposed2.md"
has "migrate: 옮긴 알림 배너 불릿도 앵커로 찾는다" "$OUT" "recommend line 1: [대화형]"

# the proposal is the source plus tags: headings, paragraphs, a column-0 line
# after a bullet and a last line without a newline all stay in place
MSRC3="$WORK/migrate-src3.md"
printf '%s' '# Personal instructions

An intro paragraph before the first bullet.

## Section one

- pol anchor rule
column-0 line after a bullet
- [대화형] already interactive
  - sub bullet kept

## Section two

- none anchor rule
- excl anchor rule
A closing paragraph without a newline' > "$MSRC3"
MSRC3_SHA=$(sha_of "$MSRC3")
MOUT3="$WORK/proposed-mixed.md"
sr migrate --source "$MSRC3" --legacy-table "$TABLE" --ack-store "$STORE" --out "$MOUT3"
check "migrate 혼합 원천: rc 0" "$RC" "0"
check "migrate 혼합 원천: 제안본은 원천에 태그만 더한 것" "$(sha_of "$MOUT3")" \
  "$(printf '%s' '# Personal instructions

An intro paragraph before the first bullet.

## Section one

- [무인] pol anchor rule
column-0 line after a bullet
- [대화형] already interactive
  - sub bullet kept

## Section two

- none anchor rule
- [대화형] excl anchor rule
A closing paragraph without a newline' | shasum -a 256 | cut -d' ' -f1)"
check "migrate 혼합 원천: 바뀐 줄은 태그를 단 첫 줄 둘뿐" \
  "$(diff "$MSRC3" "$MOUT3" | grep -c '^[<>]' || true)" "4"
has "migrate 혼합 원천: 불릿 밖 줄 수 보고" "$OUT" "outside: 6 line(s) outside every bullet, kept in the proposal as written"
check "migrate 혼합 원천: 원천 sha 불변" "$(sha_of "$MSRC3")" "$MSRC3_SHA"

# --out that is the source itself, by the same path or through a link
sr migrate --source "$MSRC3" --legacy-table "$TABLE" --ack-store "$STORE" --out "$MSRC3"
check "migrate: --out 이 원천이면 rc 2" "$RC" "2"
has "migrate: 같은 경로 거부 문구" "$(cat "$ERRF")" "--out is the source itself"
ln -s "$MSRC3" "$WORK/src-link.md"
sr migrate --source "$MSRC3" --legacy-table "$TABLE" --ack-store "$STORE" --out "$WORK/src-link.md"
check "migrate: 원천을 가리키는 링크도 rc 2" "$RC" "2"
check "migrate: 거부되면 원천 sha 불변" "$(sha_of "$MSRC3")" "$MSRC3_SHA"

# an absent store reads as empty: host-only rows give no tag
sr migrate --source "$MSRC" --legacy-table "$TABLE" --ack-store "$WORK/no-store" --out "$WORK/proposed3.md"
check "migrate: 확인 저장소 없음 rc 0" "$RC" "0"
has "migrate: 확인 저장소가 없으면 호스트 전용 불릿은 태그 없음" "$OUT" "$(printf 'line 6\t(none)\tno row')"

# refused under a run, before --out is written
ROUT="$WORK/run-proposed.md"
env CC_PIPELINE_RUN_ID=x HOME="$FAKE_HOME" bash "$SR" migrate --source "$MSRC" \
  --legacy-table "$TABLE" --ack-store "$STORE" --out "$ROUT" > "$OUTF" 2> "$ERRF"
RC=$?
check "migrate: 런 id 아래 rc 2" "$RC" "2"
check "migrate: 런 id 아래 --out 없음" "$([ -e "$ROUT" ] && echo written || echo none)" "none"
has "migrate: 거부 문구" "$(cat "$ERRF")" "refusing under CC_PIPELINE_RUN_ID"
check "migrate: 런 id 아래에서도 원천 불변" "$(sha_of "$MSRC")" "$MSRC_SHA"

sr migrate --source "$MSRC" --out "$WORK/p4.md"
check "migrate: 필수 인자 없으면 rc 2" "$RC" "2"

# ---------- enforcement ----------------------------------------------------------
#
# The script runs as a copy under a scratch plugin root outside the
# repository, so a `plugin:` location resolves against that root, and the
# default source is a scratch CLAUDE_CONFIG_DIR. No host map exists anywhere
# here, which is the other user's environment the command has to work in.

EP="$WORK/eplug"
mkdir -p "$EP/orchestrator" "$EP/hooks"
cp "$SR" "$EP/orchestrator/stage-rules.sh"
ESR="$EP/orchestrator/stage-rules.sh"
ECFG="$WORK/ecfg"
mkdir -p "$ECFG"
printf 'guard push here\n-x dash anchor\n' > "$EP/hooks/guard.sh"
EU="$ECFG/CLAUDE.md"
TB=$'\t'

# esr <args...> — the scratch copy, outside any run; sets RC, OUT.
esr() {
  env -u CC_PIPELINE_RUN_ID -u CC_GATE_STAGE_POLICY_SOURCES HOME="$FAKE_HOME" \
    CLAUDE_CONFIG_DIR="$ECFG" bash "$ESR" "$@" > "$OUTF" 2> "$ERRF"
  RC=$?
  OUT=$(cat "$OUTF")
}
# esr_in <stdin> <args...> — the same with standard input.
esr_in() {
  local in="$1"; shift
  printf '%s' "$in" | env -u CC_PIPELINE_RUN_ID -u CC_GATE_STAGE_POLICY_SOURCES HOME="$FAKE_HOME" \
    CLAUDE_CONFIG_DIR="$ECFG" bash "$ESR" "$@" > "$OUTF" 2> "$ERRF"
  RC=$?
  OUT=$(cat "$OUTF")
}

# the positive control first: one live `plugin:` item covers an [대화형] bullet
printf '%s' '- [대화형] alpha guarded
    강제: 훅 plugin:hooks/guard.sh#push
' > "$EU"
esr enforcement
check "enforcement 양성 대조: rc 0" "$RC" "0"
check "enforcement 양성 대조: stderr 비어 있음" "$(cat "$ERRF")" ""
check "enforcement 양성 대조: 전체 출력" "$OUT" "source: $EU
scope: user
rules: total=1 enforced=1 partial=0 prose=0
line 1${TB}enforced${TB}alpha guarded${TB}훅 plugin:hooks/guard.sh#push
prose-only:
  (none)
partial gaps:
  (none)
dead means:
  (none)"

# the verdict table over the default source
printf '%s' '- [무인] beta unattended only
    강제: 훅 plugin:hooks/guard.sh @무인
- gamma no marker
- delta prose
    산문: no means yet
- [무인] eps gate
    강제: 게이트 plugin:hooks/guard.sh
- [대화형] zeta gate
    강제: 게이트 plugin:hooks/guard.sh
- [무인] eta hook
    강제: 훅 plugin:hooks/guard.sh
- [대화형] theta human gate
    강제: 게이트 plugin:hooks/guard.sh @대화형
' > "$EU"
esr enforcement
check "enforcement 판정: rc 0" "$RC" "0"
has "enforcement 판정: 합계" "$OUT" "rules: total=7 enforced=2 partial=2 prose=3"
has "enforcement 판정: @무인 만 덮은 [무인] 불릿은 partial" "$OUT" \
  "line 1${TB}partial${TB}beta unattended only${TB}훅 plugin:hooks/guard.sh @무인"
has "enforcement 판정: partial gaps 의 빈 경로와 by" "$OUT" \
  "  line 1${TB}beta unattended only${TB}covered 무인 by 훅 plugin:hooks/guard.sh @무인; uncovered 대화형"
has "enforcement 판정: partial 불릿은 prose-only 에도 오른다" "$OUT" \
  "  line 1${TB}beta unattended only${TB}partial, uncovered 대화형"
has "enforcement 판정: 표지 없는 불릿은 no marker" "$OUT" "  line 3${TB}gamma no marker${TB}no marker"
has "enforcement 판정: 표지 없는 불릿의 수단 요약은 -" "$OUT" "line 3${TB}prose${TB}gamma no marker${TB}-"
has "enforcement 판정: 산문 표지" "$OUT" "  line 4${TB}delta prose${TB}marked prose: no means yet"
has "enforcement 판정: 경로 표시 없는 게이트는 [무인] 불릿을 partial 로" "$OUT" \
  "  line 6${TB}eps gate${TB}partial, uncovered 대화형"
has "enforcement 판정: 경로 표시 없는 게이트만 단 [대화형] 불릿은 uncovered 대화형" "$OUT" \
  "  line 8${TB}zeta gate${TB}uncovered 대화형"
has "enforcement 판정: 경로 표시 없는 훅은 [무인] 불릿을 enforced 로" "$OUT" \
  "line 10${TB}enforced${TB}eta hook${TB}훅 plugin:hooks/guard.sh"
has "enforcement 판정: 사람이 @대화형 을 단 게이트는 대화형을 덮는다" "$OUT" \
  "line 12${TB}enforced${TB}theta human gate"
has "enforcement 판정: 죽은 수단 없음" "$OUT" "dead means:
  (none)"

# the source kind: another file needs both paths whatever its tags
OTHER="$WORK/other-src.md"
printf '%s' '- untagged repo rule
    강제: 훅 plugin:hooks/guard.sh @대화형
' > "$OTHER"
esr enforcement --source "$OTHER"
has "enforcement 원천 종류: 다른 파일은 scope other" "$OUT" "scope: other"
has "enforcement 원천 종류: other 의 무태그 불릿은 무인 경로도 필요하다" "$OUT" \
  "  line 1${TB}untagged repo rule${TB}partial, uncovered 무인"
cp "$OTHER" "$EU"
esr enforcement --source "$EU"
has "enforcement 원천 종류: default_source 경로를 주면 scope user" "$OUT" "scope: user"
has "enforcement 원천 종류: user 의 무태그 불릿은 대화형만 필요하다" "$OUT" \
  "line 1${TB}enforced${TB}untagged repo rule"
ln -s "$EU" "$WORK/eu-link.md"
esr enforcement --source "$WORK/eu-link.md"
has "enforcement 원천 종류: default_source 를 가리키는 링크도 scope user (-ef)" "$OUT" "scope: user"

# done when the means is gone: a missing file, a lost anchor, an unknown kind
printf 'gone\n' > "$EP/hooks/gone.sh"
LOST="$WORK/lost.md"
printf '%s' '- [대화형] means rule
    강제: 훅 plugin:hooks/gone.sh
' > "$LOST"
esr enforcement --source "$LOST"
has "enforcement 수단 있음: 지우기 전 enforced" "$OUT" "line 1${TB}enforced${TB}means rule"
rm -f "$EP/hooks/gone.sh"
esr enforcement --source "$LOST"
has "enforcement 수단 사라짐: prose" "$OUT" "line 1${TB}prose${TB}means rule${TB}-"
has "enforcement 수단 사라짐: means lost" "$OUT" "  line 1${TB}means rule${TB}means lost"
has "enforcement 수단 사라짐: dead means 에 missing file" "$OUT" \
  "  line 1${TB}훅 plugin:hooks/gone.sh${TB}missing file"
printf '%s' '- [대화형] anchor rule
    강제: 훅 plugin:hooks/guard.sh#no-such-anchor
- [대화형] kind rule
    강제: 문서 plugin:hooks/guard.sh
' > "$LOST"
esr enforcement --source "$LOST"
has "enforcement 앵커 사라짐: anchor not found" "$OUT" \
  "  line 1${TB}훅 plugin:hooks/guard.sh#no-such-anchor${TB}anchor not found"
has "enforcement 모르는 종류: malformed" "$OUT" "  line 3${TB}문서 plugin:hooks/guard.sh${TB}malformed"
has "enforcement 죽은 수단만 있으면 prose" "$OUT" "rules: total=2 enforced=0 partial=0 prose=2"

# the location prefixes resolve in the scratch environment, never on this host
mkdir -p "$FAKE_HOME/.claude"
printf 'cfg means\n' > "$ECFG/cfg-means.sh"
printf 'home means\n' > "$FAKE_HOME/home-means.sh"
printf 'dot claude means\n' > "$FAKE_HOME/.claude/cfg-means.sh"
printf 'abs means\n' > "$WORK/abs-means.sh"
LOC="$WORK/loc.md"
printf '%s' "- [대화형] config rule
    강제: 훅 config:cfg-means.sh#cfg
- [대화형] home rule
    강제: 훅 ~/home-means.sh#home
- [대화형] absolute rule
    강제: 훅 $WORK/abs-means.sh#abs
" > "$LOC"
esr enforcement --source "$LOC"
has "enforcement 위치: config: 는 CLAUDE_CONFIG_DIR" "$OUT" "line 1${TB}enforced${TB}config rule"
has "enforcement 위치: ~/ 는 HOME" "$OUT" "line 3${TB}enforced${TB}home rule"
has "enforcement 위치: 절대 위치" "$OUT" "line 5${TB}enforced${TB}absolute rule"
env -u CC_PIPELINE_RUN_ID -u CLAUDE_CONFIG_DIR HOME="$FAKE_HOME" bash "$ESR" enforcement --source "$LOC" > "$OUTF" 2> "$ERRF"
RC=$?
OUT=$(cat "$OUTF")
check "enforcement 위치: CLAUDE_CONFIG_DIR 없이 rc 0" "$RC" "0"
has "enforcement 위치: CLAUDE_CONFIG_DIR 가 없으면 config: 는 HOME/.claude" "$OUT" \
  "  line 1${TB}훅 config:cfg-means.sh#cfg${TB}anchor not found"
env -u CC_PIPELINE_RUN_ID HOME= CLAUDE_CONFIG_DIR="$ECFG" bash "$ESR" enforcement --source "$LOC" > "$OUTF" 2> "$ERRF"
RC=$?
OUT=$(cat "$OUTF")
check "enforcement 위치: 빈 HOME 에서 rc 0" "$RC" "0"
has "enforcement 위치: 빈 HOME 에서 ~/ 는 malformed" "$OUT" "  line 3${TB}훅 ~/home-means.sh#home${TB}malformed"
has "enforcement 위치: 빈 HOME 에서도 config: 는 CLAUDE_CONFIG_DIR" "$OUT" "line 1${TB}enforced${TB}config rule"

# an absent source and an untagged one both exit 0
esr enforcement --source "$WORK/no-such-source.md"
check "enforcement 없는 원천: rc 0" "$RC" "0"
has "enforcement 없는 원천: 빈 파일로 읽는다" "$OUT" "source: $WORK/no-such-source.md (absent, read as empty)"
has "enforcement 없는 원천: 불릿 0" "$OUT" "rules: total=0 enforced=0 partial=0 prose=0"
printf '%s' '- plain rule
    강제: 훅 plugin:hooks/guard.sh @대화형
' > "$EU"
esr enforcement
check "enforcement 무태그 원천: rc 0" "$RC" "0"
has "enforcement 무태그 원천: 필요 경로는 대화형뿐" "$OUT" "line 1${TB}enforced${TB}plain rule"

# the marker lines stay in the extracted block
XSRC="$WORK/marker-extract.md"
printf '%s' '- [무인] kept rule
    강제: 훅 plugin:hooks/guard.sh
' > "$XSRC"
sr extract --source "$XSRC"
check "enforcement: extract 블록에 표지 줄이 그대로 있다" "$(cat "$OUTF")" "- kept rule
    강제: 훅 plugin:hooks/guard.sh"

# under a pipeline run the command still runs
env CC_PIPELINE_RUN_ID=20261031-deadbeef HOME="$FAKE_HOME" CLAUDE_CONFIG_DIR="$ECFG" \
  bash "$ESR" enforcement > "$OUTF" 2> "$ERRF"
check "enforcement: CC_PIPELINE_RUN_ID 아래에서도 rc 0" "$?" "0"

# the marker grammar, branch by branch
printf 'abc\n' > "$WORK/dash-anchor.sh"
GR="$WORK/grammar.md"
printf '%s' "- [대화형] empty anchor
    강제: 훅 plugin:hooks/guard.sh#
- [대화형] two marks
    강제: 훅 plugin:hooks/guard.sh @무인 @대화형
- [대화형] empty item
    강제: 훅 plugin:hooks/guard.sh;
- [대화형] dash anchor
    강제: 훅 plugin:hooks/guard.sh#-x
- [무인] two force lines
    강제: 훅 plugin:hooks/guard.sh @무인
    강제: 린트 plugin:hooks/guard.sh @대화형
- [대화형] two prose lines
    산문: first reason
    산문: second reason
- [무인] marker under a sub bullet
  - a sub bullet
      강제: 훅 plugin:hooks/guard.sh
- [대화형] dot dot
    강제: 훅 plugin:../eplug/hooks/guard.sh
- [대화형] no location
    강제: 훅
- [대화형] unknown prefix
    강제: 훅 hooks/guard.sh
- [대화형] unknown mark
    강제: 훅 plugin:hooks/guard.sh @nightly
- [대화형] glued colon
    강제:훅 plugin:hooks/guard.sh
- [대화형] bare force
    강제:
- [대화형] blank prose
    산문:
- [대화형] extra word
    강제: 훅 plugin:hooks/guard.sh extra
- [대화형] dash anchor missing
    강제: 훅 $WORK/dash-anchor.sh#-x
" > "$GR"
esr enforcement --source "$GR"
check "enforcement 문법: rc 0" "$RC" "0"
has "enforcement 문법: 빈 앵커는 malformed" "$OUT" "  line 1${TB}훅 plugin:hooks/guard.sh#${TB}malformed"
has "enforcement 문법: 경로 표시 둘은 malformed" "$OUT" \
  "  line 3${TB}훅 plugin:hooks/guard.sh @무인 @대화형${TB}malformed"
has "enforcement 문법: 빈 항목은 malformed 하나" "$OUT" "  line 5${TB}${TB}malformed"
has "enforcement 문법: 빈 항목 옆 살아 있는 항목은 산다" "$OUT" \
  "line 5${TB}enforced${TB}empty item${TB}훅 plugin:hooks/guard.sh"
has "enforcement 문법: - 로 시작하는 앵커를 고정 문자열로 찾는다" "$OUT" \
  "line 7${TB}enforced${TB}dash anchor${TB}훅 plugin:hooks/guard.sh#-x"
has "enforcement 문법: 강제 줄 둘의 항목이 합쳐진다" "$OUT" \
  "line 9${TB}enforced${TB}two force lines${TB}훅 plugin:hooks/guard.sh @무인; 린트 plugin:hooks/guard.sh @대화형"
has "enforcement 문법: 산문 줄이 둘이면 첫 사유" "$OUT" "  line 12${TB}two prose lines${TB}marked prose: first reason"
has "enforcement 문법: 하위 불릿 아래 강제 줄은 최상위 불릿의 표지" "$OUT" \
  "line 15${TB}enforced${TB}marker under a sub bullet"
has "enforcement 문법: plugin: 의 .. 성분은 malformed" "$OUT" \
  "  line 18${TB}훅 plugin:../eplug/hooks/guard.sh${TB}malformed"
has "enforcement 문법: 위치 없음은 malformed" "$OUT" "  line 20${TB}훅${TB}malformed"
has "enforcement 문법: 모르는 위치 접두는 malformed" "$OUT" "  line 22${TB}훅 hooks/guard.sh${TB}malformed"
has "enforcement 문법: 모르는 경로 표시는 malformed" "$OUT" \
  "  line 24${TB}훅 plugin:hooks/guard.sh @nightly${TB}malformed"
has "enforcement 문법: 콜론 뒤 공백 없는 강제 줄도 표지" "$OUT" "line 26${TB}enforced${TB}glued colon"
has "enforcement 문법: 항목 없는 강제 줄은 malformed 하나" "$OUT" "  line 28${TB}${TB}malformed"
has "enforcement 문법: 사유가 빈 산문 줄은 표지가 아니다" "$OUT" "  line 30${TB}blank prose${TB}no marker"
has "enforcement 문법: 남는 낱말은 malformed" "$OUT" \
  "  line 32${TB}훅 plugin:hooks/guard.sh extra${TB}malformed"
has "enforcement 문법: - 로 시작하는 앵커가 없는 파일은 anchor not found" "$OUT" \
  "  line 34${TB}훅 $WORK/dash-anchor.sh#-x${TB}anchor not found"

# a means file that cannot be read is a missing file — unless running as root
printf 'locked\n' > "$WORK/locked-means.sh"
chmod 000 "$WORK/locked-means.sh"
if [ -r "$WORK/locked-means.sh" ]; then
  echo "SKIP: 읽을 수 없는 수단 파일 — 이 사용자는 권한을 걷어도 읽는다 (root)"
else
  printf '%s' "- [대화형] locked rule
    강제: 훅 $WORK/locked-means.sh
" > "$LOST"
  esr enforcement --source "$LOST"
  has "enforcement: 읽을 수 없는 수단 파일은 missing file" "$OUT" \
    "  line 1${TB}훅 $WORK/locked-means.sh${TB}missing file"
fi
chmod 600 "$WORK/locked-means.sh"

# --notice-for: the bullets this edit touched, filtered by the notice table
NT="$WORK/notice.md"
printf '%s' '- [대화형] new bare rule
- [대화형] old bare rule
- [대화형] prose rule
    산문: decided later
- [대화형] guarded rule
    강제: 훅 plugin:hooks/guard.sh
- [대화형] guarded with a dead item
    강제: 훅 plugin:hooks/guard.sh; 훅 plugin:hooks/none.sh
- [대화형] prose with a dead item
    산문: decided later
    강제: 훅 plugin:hooks/none.sh @무인
- [대화형] twin rule
- [대화형] twin rule
' > "$NT"
esr_in '- [대화형] new bare rule
' enforcement --source "$NT" --notice-for -
check "notice-for: rc 0" "$RC" "0"
check "notice-for: 첫 줄이 같은 표지 없는 불릿만 찍힌다" "$OUT" "line 1${TB}new bare rule${TB}no marker"
esr_in '    산문: decided later
- [대화형] guarded rule
' enforcement --source "$NT" --notice-for -
check "notice-for: 산문 불릿과 죽은 수단 없는 enforced 불릿은 안 찍히고, 같은 표지 줄의 죽은 수단 불릿은 찍힌다" "$OUT" \
  "line 9${TB}prose with a dead item${TB}means lost; dead 훅 plugin:hooks/none.sh @무인 missing file"
esr_in '    강제: 훅 plugin:hooks/guard.sh; 훅 plugin:hooks/none.sh
' enforcement --source "$NT" --notice-for -
check "notice-for: 죽은 수단을 가진 enforced 불릿은 표지 줄로 찍힌다" "$OUT" \
  "line 7${TB}guarded with a dead item${TB}dead 훅 plugin:hooks/none.sh missing file"
esr_in '' enforcement --source "$NT" --notice-for -
check "notice-for: 빈 입력은 출력 없음" "$OUT" ""
esr_in '- [대화형] twin rule
' enforcement --source "$NT" --notice-for -
check "notice-for: 같은 첫 줄의 불릿 둘이 모두 찍힌다" "$OUT" "line 12${TB}twin rule${TB}no marker
line 13${TB}twin rule${TB}no marker"
esr_in 'x' enforcement --source "$NT" --notice-for x
check "notice-for: - 가 아닌 피연산자는 rc 2" "$RC" "2"
esr enforcement --bogus
check "enforcement: 모르는 인자는 rc 2" "$RC" "2"
printf 'x\n' > "$WORK/unreadable-src.md"
chmod 000 "$WORK/unreadable-src.md"
if [ -r "$WORK/unreadable-src.md" ]; then
  echo "SKIP: 읽을 수 없는 원천 — 이 사용자는 권한을 걷어도 읽는다 (root)"
else
  esr enforcement --source "$WORK/unreadable-src.md"
  check "enforcement: 읽을 수 없는 원천은 rc 2" "$RC" "2"
fi
chmod 600 "$WORK/unreadable-src.md"

# --notice-line: the bullet holding a line of the source
NL2="$WORK/notice-line.md"
printf '%s' 'heading outside every bullet
- [대화형] lined rule
    a continuation line
- [대화형] lined guarded rule
    강제: 훅 plugin:hooks/guard.sh
' > "$NL2"
esr_in '' enforcement --source "$NL2" --notice-for - --notice-line 3
check "notice-line: 연속 줄 번호로 불릿을 고른다" "$OUT" "line 2${TB}lined rule${TB}no marker"
esr_in '' enforcement --source "$NL2" --notice-for - --notice-line 2
check "notice-line: 첫 줄 번호도 같다" "$OUT" "line 2${TB}lined rule${TB}no marker"
esr_in '- [대화형] lined rule
' enforcement --source "$NL2" --notice-for - --notice-line 3 --notice-line 2
check "notice-line: 입력 줄과 함께 고른 불릿은 한 번만" "$OUT" "line 2${TB}lined rule${TB}no marker"
esr_in '' enforcement --source "$NL2" --notice-for - --notice-line 5
check "notice-line: 죽은 수단 없는 enforced 불릿은 출력 없음" "$OUT" ""
esr_in '' enforcement --source "$NL2" --notice-for - --notice-line 1 --notice-line 99 --notice-line 12345678901234
check "notice-line: 불릿 밖 줄과 파일보다 큰 번호는 출력 없음" "$OUT" ""
check "notice-line: 그때도 rc 0" "$RC" "0"
esr_in '' enforcement --source "$NL2" --notice-for - --notice-line 0
check "notice-line: 0 은 rc 2" "$RC" "2"
esr_in '' enforcement --source "$NL2" --notice-for - --notice-line two
check "notice-line: 숫자가 아니면 rc 2" "$RC" "2"
esr enforcement --source "$NL2" --notice-line 2
check "notice-line: --notice-for 없이 rc 2" "$RC" "2"

printf 'test-stage-rules: %s passed, %s failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
