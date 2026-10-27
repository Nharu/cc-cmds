#!/usr/bin/env bash
# lint-bash-portability: self-skip
# Test the SessionStart hook that decides whether to install the status line.
#
# WHY THIS IS A SEPARATE FILE FROM `scripts/test-statusline.sh`. That suite owns
# the installer and the wrapper grammar — what gets written and when. This one
# owns the hook's own contract, which is orthogonal to all of it: what it may
# print, that it never fails a session start, that it reads its target fresh
# every time, and that the harness is wired to call it at exactly one event.
# The precedents are `scripts/test-active-notify-pretool-hook.sh` and
# `scripts/test-orchestrator-pretool-hook.sh`, which split for the same reason.
#
# THE WORD "배너" IS NOT USED ANYWHERE IN THIS FILE. A desktop notification and
# the one `systemMessage` line this hook is allowed to print are different
# things with different rules — one is forbidden outright and the other is
# required on exactly one verdict — and a single word covering both would make
# it impossible to say from the test names which one a case is about.
#
# Usage: bash scripts/test-statusline-hook.sh

set -uo pipefail

# THE RUN NOTIFIER IS OFF FOR THIS WHOLE PROCESS, for the reason the sibling
# suite records: the gate and the watcher raise real notifications and prepend
# their own PATH, so a stub cannot shadow an installed binary and an ordinary
# `make test` reaches the user.
CC_CMDS_AUTOPILOT_NOTIFY=0
export CC_CMDS_AUTOPILOT_NOTIFY

# AND THE STAGE GUARD IS CLEARED. The hook exits immediately inside a pipeline
# stage session, and this suite is run from one — every case would then observe a
# silent rc 0 and read it as the behaviour under test. The guard itself is driven
# deliberately in its own case below.
unset CC_PIPELINE_STAGE_ID
unset CC_CMDS_STATUSLINE_AUTOINSTALL
unset CC_CMDS_STATUSLINE_PATH_DISABLE_PREPEND

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
HOOK="$repo_root/plugins/cc-cmds/hooks/statusline-sessionstart.sh"
HOOKS_JSON="$repo_root/plugins/cc-cmds/hooks/hooks.json"
APPLY="$repo_root/plugins/cc-cmds/orchestrator/apply-statusline.sh"
SL="$repo_root/plugins/cc-cmds/orchestrator/statusline.sh"
CMDLIB="$repo_root/plugins/cc-cmds/orchestrator/statusline-command.sh"
LIVENESS="$repo_root/plugins/cc-cmds/orchestrator/liveness.sh"
. "$repo_root/scripts/run-fixture.sh"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/cc-statusline-hook-test.XXXXXX")
XDG_STATE_HOME="$WORK/state"
export XDG_STATE_HOME
mkdir -p "$XDG_STATE_HOME"
trap 'fx_reap; chmod -R u+rwX "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

passed=0; failed=0; skipped=0
ok()   { passed=$((passed + 1)); printf 'PASS: %s\n' "$1"; }
bad()  { failed=$((failed + 1)); printf 'FAIL: %s — %s\n' "$1" "${2:-}" >&2; }
skip() { skipped=$((skipped + 1)); printf 'SKIP: %s — %s\n' "$1" "${2:-}"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got '$2', want '$3'"; fi; }
differ(){ if [ "$2" != "$3" ]; then ok "$1"; else bad "$1" "두 값이 같다: '$2'"; fi; }
has()  { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "'$2' 에 '$3' 없음" ;; esac; }
hasnt(){ case "$2" in *"$3"*) bad "$1" "'$2' 에 '$3' 가 있음" ;; *) ok "$1" ;; esac; }

# ---------------------------------------------------------------------------
# Fixtures
#
# THE PLUGIN TREE IS A COPY, NOT THIS CHECKOUT. The installer parks on a linked
# git worktree and this repository is checked out as one about as often as not,
# so pointing the hook at its own tree would make every case here pass or park
# depending on where somebody happened to clone it.
#
# THE INSTALLER IS PART OF THE COPY. The hook resolves it out of `--plugin-dir`
# rather than being told where it is, so a tree without it ends every run at an
# exit code outside the verdict band — which looks exactly like a hook that
# decided to do nothing.
# ---------------------------------------------------------------------------
mk_plug() {
  # mk_plug <dir> — a complete plugin tree the hook can drive end to end.
  local d="$1"
  mkdir -p "$d/orchestrator"
  cp "$SL" "$LIVENESS" "$CMDLIB" "$APPLY" "$d/orchestrator/"
  chmod +x "$d/orchestrator/statusline.sh"
}

mk_plug_silent() {
  # mk_plug_silent <dir> — a tree whose status line emits nothing, so the
  # pre-commit verify run fails and the installer answers rc 40.
  local d="$1"
  mkdir -p "$d/orchestrator"
  cp "$CMDLIB" "$APPLY" "$d/orchestrator/"
  printf '#!/usr/bin/env bash\ncat >/dev/null\nprintf %s\n' "''" > "$d/orchestrator/statusline.sh"
  chmod +x "$d/orchestrator/statusline.sh"
}

PLUG="$WORK/plugin";  mk_plug "$PLUG"
PLUG2="$WORK/plugin2"; mk_plug "$PLUG2"
PLUG_SILENT="$WORK/plug-silent"; mk_plug_silent "$PLUG_SILENT"

# A tree that has the grammar but no executable status line: the installer parks
# with its own reason rather than the value's.
PLUG_NOBIT="$WORK/plug-nobit"
mk_plug "$PLUG_NOBIT"
chmod -x "$PLUG_NOBIT/orchestrator/statusline.sh"

# A tree missing the installer altogether — the hook reaches an exit code that is
# not in the verdict band, which must still be a quiet rc 0.
PLUG_NOAPPLY="$WORK/plug-noapply"
mkdir -p "$PLUG_NOAPPLY/orchestrator"
cp "$SL" "$CMDLIB" "$PLUG_NOAPPLY/orchestrator/"
chmod +x "$PLUG_NOAPPLY/orchestrator/statusline.sh"

# A plugin path that does not exist, standing in for the older cache version an
# installed wrapper still points at after a marketplace update.
OLDSL="$WORK/oldplug/orchestrator/statusline.sh"

ours_command() {
  # ours_command <target> — a guarded wrapper aimed at <target>, with a named
  # fallback behind it.
  #
  # PRODUCED BY THE SHARED GRAMMAR RATHER THAN TYPED OUT. Exactly two files in
  # this tree may hold a hand-written copy of that grammar and a lint holds the
  # set closed; this suite is not one of them and does not need to be, because it
  # asserts nothing about the SHAPE of the value — only about what the hook
  # decides when it meets one. The sibling suite owns the shape.
  ( SL_PATH="$1"; . "$CMDLIB"; sl_wrapper_prefix; printf '%s' "printf 'USER-CMD'" )
}

cfg_empty()   { mkdir -p "$1"; jq -n '{theme: "dark", model: "opus", cleanupPeriodDays: 30}' > "$1/settings.json"; }
cfg_foreign() { mkdir -p "$1"; jq -n --arg c "printf 'PRE-APPLY-LITERAL'" \
                  '{theme: "dark", statusLine: {type: "command", command: $c}}' > "$1/settings.json"; }
cfg_ours()    { mkdir -p "$1"; jq -n --arg c "$(ours_command "$OLDSL")" \
                  '{theme: "dark", statusLine: {type: "command", command: $c}}' > "$1/settings.json"; }

sha_of()   { shasum -a 256 "$1" 2>/dev/null | cut -d' ' -f1; }
mtime_of() { perl -e 'print((stat($ARGV[0]))[9])' "$1" 2>/dev/null; }
cmd_of()   { jq -r '.statusLine.command // ""' "$1/settings.json" 2>/dev/null; }
mk_field() {
  # mk_field <cfg> <field> — one field out of the marker line, or the empty
  # string when there is no marker.
  local c="$1" f="$2"
  [ -f "$c/settings.json.cc-statusline" ] || return 0
  sed -e "s/.*|$f=//" -e 's/|.*//' "$c/settings.json.cc-statusline"
}

HOOK_RC=0
OUT_FILE="$WORK/hook.out"
ERR_FILE="$WORK/hook.err"
run_hook() {
  # run_hook <config-dir> <plugin-dir> — one startup. stdout and stderr are
  # captured to separate files: the whole point of several cases below is that
  # the two channels are not interchangeable, and a merged capture would assert
  # an empty stderr along with an empty stdout.
  local c="$1" p="$2"
  CLAUDE_CONFIG_DIR="$c" bash "$HOOK" --plugin-dir "$p" > "$OUT_FILE" 2> "$ERR_FILE"
  HOOK_RC=$?
}
out_bytes() { wc -c < "$OUT_FILE" | tr -d ' '; }

# ---------------------------------------------------------------------------
# L1 · L2 — the hook parses, succeeds, and never fails a session start
# ---------------------------------------------------------------------------
if bash -n "$HOOK" 2>/dev/null; then ok "훅이 파싱된다"; else bad "훅 파싱" "bash -n 실패"; fi

L1="$WORK/cfg-l1"; cfg_empty "$L1"
run_hook "$L1" "$PLUG"
check "L1 유효한 입력에 rc 0" "$HOOK_RC" "0"
check "L1 상태줄이 실제로 설치된다" "$(jq -r 'has("statusLine")' "$L1/settings.json")" "true"

# L2. THE INSTALLER FAILING IS NOT THE HOOK FAILING. Three shapes of failure,
# and the hook's return code is 0 in all of them.
L2A="$WORK/cfg-l2a"; cfg_empty "$L2A"
run_hook "$L2A" "$PLUG_NOBIT"
check "L2 설치기가 park 해도 훅의 rc 는 0" "$HOOK_RC" "0"
L2B="$WORK/cfg-l2b"; cfg_empty "$L2B"
run_hook "$L2B" "$PLUG_NOAPPLY"
check "L2 설치기가 아예 없어도 훅의 rc 는 0" "$HOOK_RC" "0"
check "L2 밴드 밖 종료는 마커를 남기지 않는다" \
  "$([ -f "$L2B/settings.json.cc-statusline" ] && printf y || printf n)" "n"
L2C="$WORK/cfg-l2c"; mkdir -p "$L2C"; printf '{ this is not json' > "$L2C/settings.json"
run_hook "$L2C" "$PLUG"
check "L2 깨진 설정 JSON 에도 훅의 rc 는 0" "$HOOK_RC" "0"

# ---------------------------------------------------------------------------
# L3 — an stdin that never closes does not hold the session start
#
# The hook does not read stdin at all; the matcher has already answered the only
# question it could have asked. This case is what keeps that true — a `cat` added
# for diagnostics would hang every startup until the harness gave up.
# ---------------------------------------------------------------------------
L3="$WORK/cfg-l3"; cfg_empty "$L3"
L3FIFO="$WORK/l3.fifo"
mkfifo "$L3FIFO"
sleep 5 > "$L3FIFO" &
FX_PIDS="${FX_PIDS:-}$! "
CLAUDE_CONFIG_DIR="$L3" bash "$HOOK" --plugin-dir "$PLUG" < "$L3FIFO" >/dev/null 2>/dev/null &
l3_pid=$!
l3_i=0
while [ "$l3_i" -lt 30 ]; do
  kill -0 "$l3_pid" 2>/dev/null || break
  sleep 0.1
  l3_i=$((l3_i + 1))
done
if kill -0 "$l3_pid" 2>/dev/null; then
  kill "$l3_pid" 2>/dev/null
  bad "L3 닫히지 않는 stdin" "훅이 3초 안에 끝나지 않았다"
else
  wait "$l3_pid" 2>/dev/null
  ok "L3 닫히지 않는 stdin 에도 멈추지 않는다"
fi

# ---------------------------------------------------------------------------
# L4 · L4b · L5 — the plugin path comes from argv, is normalised once, and is
# never cached
# ---------------------------------------------------------------------------
# L4. The behavioural half and the structural half do not cover each other: with
# an environment fallback present the hook would install here and the case would
# still be green if it only asserted rc 0.
L4="$WORK/cfg-l4"; cfg_empty "$L4"
l4_sha=$(sha_of "$L4/settings.json")
CLAUDE_PLUGIN_ROOT="$PLUG" CLAUDE_CONFIG_DIR="$L4" bash "$HOOK" >/dev/null 2>/dev/null
check "L4 환경에만 플러그인 경로가 있으면 rc 0 으로 물러난다" "$?" "0"
check "L4 그리고 아무것도 쓰지 않는다" "$(sha_of "$L4/settings.json")" "$l4_sha"
check "L4 (구조) 훅에 CLAUDE_PLUGIN_ROOT 조회가 0 건이다" \
  "$(grep -c 'CLAUDE_PLUGIN_ROOT' "$HOOK" || true)" "0"
check "L4 (구조) 설치기에도 CLAUDE_PLUGIN_ROOT 조회가 0 건이다" \
  "$(grep -c 'CLAUDE_PLUGIN_ROOT' "$APPLY" || true)" "0"

# L4b. A trailing slash resolves to the same directory, so every filesystem test
# passes it — and the string still differs byte for byte. Only a comparison of
# what got RECORDED can tell an implementation that normalises from one that
# does not.
L4BA="$WORK/cfg-l4b-a"; cfg_empty "$L4BA"
L4BB="$WORK/cfg-l4b-b"; cfg_empty "$L4BB"
run_hook "$L4BA" "$PLUG"
run_hook "$L4BB" "$PLUG/"
check "L4b 두 철자의 마커 경로 필드가 바이트 동일하다" \
  "$(mk_field "$L4BA" path)" "$(mk_field "$L4BB" path)"
check "L4b 두 철자의 설치된 명령도 바이트 동일하다" "$(cmd_of "$L4BA")" "$(cmd_of "$L4BB")"

# L5. Read fresh on every startup: the second run is handed a different tree and
# re-points to it.
L5="$WORK/cfg-l5"; cfg_empty "$L5"
run_hook "$L5" "$PLUG"
has "L5 첫 기동은 넘겨받은 트리를 겨눈다" "$(cmd_of "$L5")" "$PLUG/orchestrator/statusline.sh"
run_hook "$L5" "$PLUG2"
has "L5 값이 바뀌면 그 기동에서 다시 겨눈다 — 캐시하지 않는다" "$(cmd_of "$L5")" "$PLUG2/orchestrator/statusline.sh"
hasnt "L5 옛 트리가 명령에 남지 않는다" "$(cmd_of "$L5")" "$PLUG/orchestrator"

# ---------------------------------------------------------------------------
# L6 — the registration
#
# The matcher is what bounds the cost. `SessionStart` also fires on resume,
# clear, compact and fork, and a long unattended run compacts many times — a
# wider matcher would repeat the whole decision dozens of times inside one run.
# ---------------------------------------------------------------------------
if jq -e '.hooks | has("SessionStart")' "$HOOKS_JSON" >/dev/null 2>&1; then
  check "L6 SessionStart 블록이 정확히 하나다" \
    "$(jq -r '.hooks.SessionStart | length' "$HOOKS_JSON")" "1"
  check "L6 매처가 startup 하나뿐이다" \
    "$(jq -r '.hooks.SessionStart[0].matcher' "$HOOKS_JSON")" "startup"
  check "L6 훅 항목이 정확히 하나다" \
    "$(jq -r '.hooks.SessionStart[0].hooks | length' "$HOOKS_JSON")" "1"
  check "L6 timeout 이 10 이다" \
    "$(jq -r '.hooks.SessionStart[0].hooks[0].timeout' "$HOOKS_JSON")" "10"
  has "L6 명령이 이 훅을 부른다" \
    "$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$HOOKS_JSON")" "hooks/statusline-sessionstart.sh"
  has "L6 플러그인 루트를 argv 로 넘긴다" \
    "$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$HOOKS_JSON")" "--plugin-dir"
  check "L6 기존 PreToolUse 형제 키가 그대로 있다" \
    "$(jq -r '.hooks | has("PreToolUse")' "$HOOKS_JSON")" "true"
else
  bad "L6 SessionStart 등록" "hooks.json 에 SessionStart 형제 키가 없다"
fi

# ---------------------------------------------------------------------------
# L7 · L7b · L7c · L7d — stdout
#
# `SessionStart` stdout is injected into the session context and, when it parses
# as JSON, read as a control channel. So the enumeration of what this hook may
# print is closed at two values: nothing, and one fixed line.
# ---------------------------------------------------------------------------
L7_BAD=0
l7_quiet() {
  # l7_quiet <label> <config-dir> <plugin-dir> — one startup that must print
  # nothing at all on stdout.
  local label="$1" c="$2" p="$3" n
  run_hook "$c" "$p"
  n=$(out_bytes)
  if [ "$n" = "0" ]; then
    ok "L7 stdout 0바이트 — $label"
  else
    L7_BAD=$((L7_BAD + 1))
    bad "L7 stdout — $label" "$n 바이트"
  fi
}

# park / foreign — the installer is never called.
L7F="$WORK/cfg-l7-foreign"; cfg_foreign "$L7F"
l7_quiet "park(foreign)" "$L7F" "$PLUG"

# adopt-repoint — a hand-installed wrapper aimed at an older path, no history.
# D12 names this the verdict every pre-existing installation leaves on the first
# startup after this ships, and rc 11 is where an implementation is likeliest to
# print something.
L7AR="$WORK/cfg-l7-adoptrepoint"; cfg_ours "$L7AR"
l7_quiet "adopt-repoint" "$L7AR" "$PLUG"

# adopted — ours already, byte-identical to what we would render, no history.
L7AD="$WORK/cfg-l7-adopted"
cfg_empty "$L7AD"; run_hook "$L7AD" "$PLUG"
rm -f "$L7AD/settings.json.cc-statusline"
L7AD_OWNED="$L7AD/settings.json.cc-statusline-owned"
rm -f "$L7AD_OWNED"
l7_quiet "adopted" "$L7AD" "$PLUG"

# converged — the same value with the history in place.
rm -f "$L7AD/settings.json.cc-statusline"
l7_quiet "converged" "$L7AD" "$PLUG"

# drift-repair — ours, history present, aimed somewhere stale.
L7DR="$WORK/cfg-l7-driftrepair"
cfg_empty "$L7DR"; run_hook "$L7DR" "$PLUG"
jq --arg c "$(ours_command "$OLDSL")" \
  '.statusLine.command = $c' "$L7DR/settings.json" > "$L7DR/t" && mv "$L7DR/t" "$L7DR/settings.json"
rm -f "$L7DR/settings.json.cc-statusline"
l7_quiet "drift-repair" "$L7DR" "$PLUG"

# deleted — owned once, empty now. The installer is never called.
L7DL="$WORK/cfg-l7-deleted"
cfg_empty "$L7DL"; run_hook "$L7DL" "$PLUG"
jq 'del(.statusLine)' "$L7DL/settings.json" > "$L7DL/t" && mv "$L7DL/t" "$L7DL/settings.json"
rm -f "$L7DL/settings.json.cc-statusline"
l7_quiet "deleted" "$L7DL" "$PLUG"

# verify-failed, lock contention, and an error that never reaches a verdict.
L7VF="$WORK/cfg-l7-verifyfail"; cfg_empty "$L7VF"
l7_quiet "verify-failed" "$L7VF" "$PLUG_SILENT"
L7LK="$WORK/cfg-l7-lock"; cfg_empty "$L7LK"
mkdir "$L7LK/settings.json.cc-statusline.lock"
l7_quiet "락 경합" "$L7LK" "$PLUG"
rmdir "$L7LK/settings.json.cc-statusline.lock"
L7ER="$WORK/cfg-l7-error"; mkdir -p "$L7ER"; printf '{ broken' > "$L7ER/settings.json"
l7_quiet "오류" "$L7ER" "$PLUG"

check "L7 installed 를 제외한 모든 판정에서 stdout 이 비어 있다" "$L7_BAD" "0"

# L7b. The diagnostics are on stderr, and they are actually there — an assertion
# that only demanded an empty stdout would be satisfied by a hook that says
# nothing anywhere.
#
# A FRESH CONFIGURATION DIRECTORY, because the previous run left a marker and the
# front gate would then skip the whole slow path — correctly — and there would be
# no diagnostics to read.
L7B="$WORK/cfg-l7b"; cfg_empty "$L7B"
run_hook "$L7B" "$PLUG_SILENT"
check "L7b 진단이 흐르는 실행에서도 stdout 은 0바이트다" "$(out_bytes)" "0"
if [ -s "$ERR_FILE" ]; then ok "L7b 진단은 stderr 로 나간다"; else bad "L7b 진단 채널" "stderr 가 비어 있다"; fi

# L7c · L7d. The one line, its bytes, its shape, and its one-shot property.
L7C="$WORK/cfg-l7c"; cfg_empty "$L7C"
run_hook "$L7C" "$PLUG"
check "L7c installed 판정의 마커가 실제로 installed 다" "$(mk_field "$L7C" verdict)" "installed"
L7C_OUT="$WORK/l7c-installed.out"
cp "$OUT_FILE" "$L7C_OUT"
check "L7c 그 stdout 이 하네스가 파싱할 수 있는 JSON 이다" \
  "$(jq -r 'has("systemMessage")' < "$L7C_OUT" 2>/dev/null)" "true"
check "L7c 최상위 키가 systemMessage 하나뿐이다" \
  "$(jq -r 'keys | length' < "$L7C_OUT" 2>/dev/null)" "1"
run_hook "$L7C" "$PLUG"
check "L7c 같은 기기의 두 번째 세션은 다시 0바이트다" "$(out_bytes)" "0"

# L7d (1). BYTES, NOT A SUBSTRING. A substring test cannot see a second line
# appended after the JSON, and a second line is what turns one message into a
# control payload followed by unparsable noise.
L7D_WANT="$WORK/l7d.want"
printf '{"systemMessage":"cc-cmds 가 상태줄을 설치했습니다. 상태줄이 있으면 화면 하단의 키보드 힌트가 대부분 가려집니다. 다음부터 자동 설치를 원치 않으면 CC_CMDS_STATUSLINE_AUTOINSTALL=0 을 설정하세요. 지금 설치된 상태줄을 없애는 방법은 README 의 Uninstall 절에 있습니다."}\n' > "$L7D_WANT"
if cmp -s "$L7C_OUT" "$L7D_WANT"; then
  ok "L7d (1) 안내문이 축자 리터럴 + 개행 하나와 바이트 동일하다"
else
  bad "L7d (1) 안내문 바이트" "리터럴과 다르다"
fi

# L7d (2). STRUCTURE. The byte test only covers the path that was walked; this
# one covers the ones that were not, because a value can only be interpolated by
# a form that appears in the source.
L7D_LINE=$(grep -n 'systemMessage' "$HOOK" | grep -v ':[[:space:]]*#' || true)
check "L7d (2) systemMessage 를 담은 줄이 정확히 하나다" \
  "$(printf '%s\n' "$L7D_LINE" | grep -c . || true)" "1"
L7D_SRC=${L7D_LINE#*:}
hasnt "L7d (2) 그 줄에 달러 기호가 없다" "$L7D_SRC" '$'
hasnt "L7d (2) 그 줄에 형식 지정자가 없다" "$L7D_SRC" '%s'
hasnt "L7d (2) 그 줄에 명령 치환이 없다" "$L7D_SRC" '$('
check "L7d (2) 그 줄에 역따옴표가 없다" "$(printf '%s' "$L7D_SRC" | grep -c '`' || true)" "0"

# L7d (3). THE NEGATIVE VOCABULARY, and it is the only leg not mediated by the
# literal — the first compares against the literal itself and so is blind to a
# re-pin, and the second only looks at how a value could arrive.
L7D_BAD=0
# The wrapper's exec token is ASSEMBLED rather than typed, for the same reason
# the fixture above is generated: the file-set lint allows a hand-written copy of
# the grammar in two files and this is not one of them. The assembled value is
# the same bytes the check needs.
L7D_EXEC="exec"" bash"
for forbidden in '.orig' '.prev' '복원' '백업' "$L7D_EXEC" '[ -x' 'orchestrator/statusline.sh'; do
  case "$(cat "$L7C_OUT")$L7D_SRC" in
    *"$forbidden"*) L7D_BAD=$((L7D_BAD + 1)); printf '  L7d: 금지 문면 %s\n' "$forbidden" >&2 ;;
  esac
done
check "L7d (3) 안내문과 그 소스 줄에 복구·주입 어휘가 0 건이다" "$L7D_BAD" "0"
check "L7d (3) 64자리 16진수도 0 건이다" \
  "$(cat "$L7C_OUT" | grep -cE '[0-9a-f]{64}' || true)" "0"
hasnt "L7d (3) 설정 파일 경로의 값도 실리지 않는다" "$(cat "$L7C_OUT")" "$L7C"

# ---------------------------------------------------------------------------
# L8 — the hook does not reach the user by any channel other than stdout
#
# THIS CASE ASSERTS NOTHING ABOUT STDOUT. Its owners are L7, L7c, L7d and L11;
# if this one overlapped them the two would end up asserting opposites.
# ---------------------------------------------------------------------------
check "L8 (구조) 데스크탑 알림 도구와 제어 터미널 리디렉션이 0 건이다" \
  "$(grep -cE 'terminal-notifier|osascript|notify-send|notify\.sh|/dev/tty' "$HOOK" || true)" "0"

L8_STUB="$WORK/stub"
mkdir -p "$L8_STUB"
L8_LOG="$WORK/notifier.log"
: > "$L8_LOG"
for n in terminal-notifier osascript notify-send; do
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s"\n' "$L8_LOG" > "$L8_STUB/$n"
  chmod +x "$L8_STUB/$n"
done
# The prepend is disabled so the stub really is first: the hook puts the Homebrew
# directories ahead of whatever it inherits, which would shadow a stub with an
# installed binary. `jq` still resolves — it is on this process's own PATH.
L8A="$WORK/cfg-l8a"; cfg_empty "$L8A"
L8B="$WORK/cfg-l8b"; cfg_foreign "$L8B"
L8C="$WORK/cfg-l8c"; cfg_ours "$L8C"
L8D="$WORK/cfg-l8d"; cfg_empty "$L8D"
for pair in "$L8A::$PLUG" "$L8B::$PLUG" "$L8C::$PLUG" "$L8D::$PLUG_SILENT"; do
  l8c=${pair%::*}; l8p=${pair##*::}
  CC_CMDS_STATUSLINE_PATH_DISABLE_PREPEND=1 PATH="$L8_STUB:$PATH" \
    CLAUDE_CONFIG_DIR="$l8c" bash "$HOOK" --plugin-dir "$l8p" >/dev/null 2>/dev/null
done
check "L8 (행동) installed 를 포함한 모든 판정에서 알림 도구가 불리지 않는다" \
  "$(wc -c < "$L8_LOG" | tr -d ' ')" "0"
check "L8 전제 — 그 실행 중 하나는 실제로 설치였다" \
  "$(mk_field "$L8A" verdict)" "installed"

# ---------------------------------------------------------------------------
# L10 — the hook sources the grammar and defines none of it
#
# NOT "THE HOOK DEFINES NO FUNCTIONS". Two are the hook's own by design — the
# target derivation and the front gate — and reading this case more widely makes
# it red, whose natural fix is to move the derivation into the shared file and
# undo the boundary decision it was moved out of.
# ---------------------------------------------------------------------------
check "L10 훅이 래퍼 문법 함수를 정의하지 않는다" \
  "$(grep -cE '^(sl_wrapper_prefix|sl_unwrap_once|sl_unwrap|sl_is_bare_ours|sl_classify)\(\)' "$HOOK" || true)" "0"
check "L10 훅이 공유 파일을 소스한다" \
  "$(grep -c 'statusline-command\.sh' "$HOOK" || true)" "1"
check "L10 대상 경로 도출은 훅 자신 안에 있다" \
  "$(grep -c '^sl_settings_path()' "$HOOK" || true)" "1"
check "L10 앞단 게이트도 훅 자신 안에 있다" \
  "$(grep -c '^sl_gate_converged()' "$HOOK" || true)" "1"
check "L10 그 둘이 공유 파일에는 없다" \
  "$(grep -cE '^(sl_settings_path|sl_gate_converged)\(\)' "$CMDLIB" || true)" "0"

# ---------------------------------------------------------------------------
# L11 — the installer itself prints nothing, at every terminal
#
# INCLUDING THE SUCCESS TERMINALS. That is the point of the case: the success
# path is exactly where output used to be produced, and only an assertion that
# names it can tell whether the removal actually happened.
# ---------------------------------------------------------------------------
L11_BAD=0
l11() {
  # l11 <label> <expected rc> <settings> <plugin-dir> <require-state>
  local label="$1" want="$2" s="$3" p="$4" st="$5" o rc
  o="$WORK/l11.out"
  bash "$APPLY" --apply --settings "$s" --plugin-dir "$p" --require-state "$st" > "$o" 2>/dev/null
  rc=$?
  check "L11 종단 $label 의 종료 코드" "$rc" "$want"
  if [ -s "$o" ]; then
    L11_BAD=$((L11_BAD + 1))
    bad "L11 종단 $label 의 stdout" "$(wc -c < "$o" | tr -d ' ') 바이트"
  fi
}
L11DIR="$WORK/l11"; mkdir -p "$L11DIR"
jq -n '{theme:"dark"}' > "$L11DIR/install.json"
l11 "INSTALLED"          10 "$L11DIR/install.json" "$PLUG" empty
l11 "REPOINTED"          11 "$L11DIR/install.json" "$PLUG2" ours
l11 "CONVERGED"           0 "$L11DIR/install.json" "$PLUG2" ours
jq -n --arg c "printf 'SOMEBODY-ELSE'" '{statusLine:{type:"command",command:$c}}' > "$L11DIR/foreign.json"
l11 "PARK_FOREIGN"       20 "$L11DIR/foreign.json" "$PLUG" empty
jq -n '{theme:"dark"}' > "$L11DIR/mismatch.json"
l11 "PARK_REQUIRE_STATE" 21 "$L11DIR/mismatch.json" "$PLUG" ours
l11 "PARK_SL_MISSING"    24 "$L11DIR/mismatch.json" "$PLUG_NOBIT" empty
l11 "PARK_PLUGIN_DIR"    26 "$L11DIR/mismatch.json" "$PLUG/" empty
ln -s "$L11DIR/mismatch.json" "$L11DIR/linked.json"
l11 "PARK_LINKED"        27 "$L11DIR/linked.json" "$PLUG" empty
jq -n '{theme:"dark"}' > "$L11DIR/verify.json"
l11 "VERIFY_FAILED"      40 "$L11DIR/verify.json" "$PLUG_SILENT" empty
jq -n '{theme:"dark"}' > "$L11DIR/busy.json"
mkdir "$L11DIR/busy.json.cc-statusline.lock"
l11 "LOCK_BUSY"          30 "$L11DIR/busy.json" "$PLUG" empty
rmdir "$L11DIR/busy.json.cc-statusline.lock"
printf '{ broken' > "$L11DIR/broken.json"
l11 "ERROR"               1 "$L11DIR/broken.json" "$PLUG" empty
check "L11 열거한 모든 종단에서 설치기의 stdout 이 0바이트다" "$L11_BAD" "0"

# ---------------------------------------------------------------------------
# L13 — a failed pre-commit verify is remembered
#
# WITHOUT THE LAST CLAUSE THIS CASE MISSES THE REGRESSION IT EXISTS FOR. A
# machine with a broken status line script that leaves no marker pays the verify
# run's one-second poll on every single session start, forever.
# ---------------------------------------------------------------------------
L13="$WORK/cfg-l13"; cfg_empty "$L13"
l13_sha=$(sha_of "$L13/settings.json")
run_hook "$L13" "$PLUG_SILENT"
check "L13 사전 verify 실패의 판정이 기록된다" "$(mk_field "$L13" verdict)" "verify-failed"
check "L13 그 사유는 verify 다" "$(mk_field "$L13" reason)" "verify"
check "L13 소유 비트는 만들어지지 않는다" \
  "$([ -e "$L13/settings.json.cc-statusline-owned" ] && printf y || printf n)" "n"
check "L13 설정 파일의 바이트도 그대로다" "$(sha_of "$L13/settings.json")" "$l13_sha"
# Both files are pushed into the past so the settings file is older than the
# marker — the mtime comparison is second-resolution, so two writes inside one
# second are indistinguishable to it.
fx_age_file "$L13/settings.json" 10
fx_age_file "$L13/settings.json.cc-statusline" 5
l13_mk_m=$(mtime_of "$L13/settings.json.cc-statusline")
run_hook "$L13" "$PLUG_SILENT"
check "L13 바로 다음 기동은 앞단 게이트가 건너뛴다 — 마커가 다시 쓰이지 않는다" \
  "$(mtime_of "$L13/settings.json.cc-statusline")" "$l13_mk_m"

# ---------------------------------------------------------------------------
# L14 — `jq` is looked up AFTER the PATH prepend
#
# Three legs. The negative one alone is satisfied by a hook that never prepends
# at all, and without the third an implementation comparing the switch against a
# literal `1` would pass while diverging from all four sibling switches.
# ---------------------------------------------------------------------------
L14NOJQ="$WORK/nojq"; mkdir -p "$L14NOJQ"
L14A="$WORK/cfg-l14a"; cfg_empty "$L14A"
l14a_sha=$(sha_of "$L14A/settings.json")
CC_CMDS_STATUSLINE_PATH_DISABLE_PREPEND=1 PATH="$L14NOJQ" \
  CLAUDE_CONFIG_DIR="$L14A" /bin/bash "$HOOK" --plugin-dir "$PLUG" >/dev/null 2>/dev/null
check "L14 (음성) 앞붙임을 끄고 jq 를 감추면 rc 0 으로 물러난다" "$?" "0"
check "L14 (음성) 그리고 아무것도 쓰지 않는다" "$(sha_of "$L14A/settings.json")" "$l14a_sha"

L14C="$WORK/cfg-l14c"; cfg_empty "$L14C"
l14c_sha=$(sha_of "$L14C/settings.json")
CC_CMDS_STATUSLINE_PATH_DISABLE_PREPEND=0 PATH="$L14NOJQ" \
  CLAUDE_CONFIG_DIR="$L14C" /bin/bash "$HOOK" --plugin-dir "$PLUG" >/dev/null 2>/dev/null
check "L14 (비-1 음성) 차단 변수가 0 이어도 앞붙임은 꺼진다" "$(sha_of "$L14C/settings.json")" "$l14c_sha"

# The positive leg needs `jq` to actually live in one of the four directories the
# hook prepends; on a machine where it is somewhere else this proves nothing and
# says so rather than passing vacuously.
L14_JQ_DIR=$(dirname "$(command -v jq 2>/dev/null || printf /nowhere)")
case "$L14_JQ_DIR" in
  /opt/homebrew/bin|/usr/local/bin|/usr/bin|/bin)
    L14B="$WORK/cfg-l14b"; cfg_empty "$L14B"
    PATH="$L14NOJQ" CLAUDE_CONFIG_DIR="$L14B" /bin/bash "$HOOK" --plugin-dir "$PLUG" >/dev/null 2>/dev/null
    check "L14 (양성) 앞붙임이 겨냥하는 자리에만 jq 가 있어도 설치가 일어난다" \
      "$(jq -r 'has("statusLine")' "$L14B/settings.json")" "true"
    ;;
  *)
    skip "L14 (양성) 앞붙임이 jq 를 찾아낸다" "이 기기의 jq 가 앞붙임 대상 밖($L14_JQ_DIR)에 있다"
    ;;
esac

# ---------------------------------------------------------------------------
# L15 — the ownership bit is read BEFORE the installer is called
#
# The installer creates it while it runs, so an observation taken afterwards
# reports "had history" for the very run that established it — and `adopted` and
# `converged` swap places on every machine.
# ---------------------------------------------------------------------------
L15_READ=$(awk -v p='[ -e "$OWNED" ]' 'index($0, p) { print NR; exit }' "$HOOK")
L15_CALL=$(awk -v p='apply-statusline.sh" --apply' 'index($0, p) { print NR; exit }' "$HOOK")
if [ -n "$L15_READ" ] && [ -n "$L15_CALL" ] && [ "$L15_READ" -lt "$L15_CALL" ]; then
  ok "L15 (구조) 소유 비트를 읽는 줄이 설치기 호출보다 앞이다"
else
  bad "L15 소유 비트 읽기 순서" "읽기=${L15_READ:-없음} 호출=${L15_CALL:-없음}"
fi

L15="$WORK/cfg-l15"
cfg_empty "$L15"; run_hook "$L15" "$PLUG"
rm -f "$L15/settings.json.cc-statusline"
L15_OWNED="$L15/settings.json.cc-statusline-owned"
rm -f "$L15_OWNED"
run_hook "$L15" "$PLUG"
check "L15 (행동) 이력 없는 우리 값은 채택으로 이름 붙는다" "$(mk_field "$L15" verdict)" "adopted"
rm -f "$L15/settings.json.cc-statusline"
run_hook "$L15" "$PLUG"
check "L15 (행동) 이력이 생긴 뒤 같은 값은 수렴이다" "$(mk_field "$L15" verdict)" "converged"

# ---------------------------------------------------------------------------
# L16 — the kill switch
#
# THE RETURN CODE CANNOT SEPARATE THESE. The hook answers 0 on every path, so an
# implementation that ignores the variable entirely is rc 0 too. What separates
# "did nothing" from "did something with the same result" is the settings file's
# own mtime.
# ---------------------------------------------------------------------------
L16OFF="$WORK/cfg-l16-off"; cfg_empty "$L16OFF"
fx_age_file "$L16OFF/settings.json" 5
l16_m=$(mtime_of "$L16OFF/settings.json")
CC_CMDS_STATUSLINE_AUTOINSTALL=0 CLAUDE_CONFIG_DIR="$L16OFF" bash "$HOOK" --plugin-dir "$PLUG" >/dev/null 2>/dev/null
check "L16 (1) 끄는 값이면 rc 0 으로 물러난다" "$?" "0"
check "L16 (1) 설정 파일의 mtime 이 움직이지 않는다" "$(mtime_of "$L16OFF/settings.json")" "$l16_m"
check "L16 (1) 마커도 생기지 않는다" \
  "$([ -e "$L16OFF/settings.json.cc-statusline" ] && printf y || printf n)" "n"
check "L16 (1) 소유 비트도 생기지 않는다" \
  "$([ -e "$L16OFF/settings.json.cc-statusline-owned" ] && printf y || printf n)" "n"

# (2) The value vocabulary is ONE token. Testing only the disabling value would
# pass an implementation that also treats `false` as off.
l16_on_bad=0
l16_i=0
for v in 1 false ''; do
  l16_i=$((l16_i + 1))
  d="$WORK/cfg-l16-on-$l16_i"; cfg_empty "$d"
  CC_CMDS_STATUSLINE_AUTOINSTALL="$v" CLAUDE_CONFIG_DIR="$d" bash "$HOOK" --plugin-dir "$PLUG" >/dev/null 2>/dev/null
  [ "$(jq -r 'has("statusLine")' "$d/settings.json")" = "true" ] || l16_on_bad=$((l16_on_bad + 1))
done
d="$WORK/cfg-l16-on-unset"; cfg_empty "$d"
run_hook "$d" "$PLUG"
[ "$(jq -r 'has("statusLine")' "$d/settings.json")" = "true" ] || l16_on_bad=$((l16_on_bad + 1))
check "L16 (2) 1·false·빈값·미설정 넷 모두에서 정상 설치가 일어난다" "$l16_on_bad" "0"

check "L16 (3) 옛 접두의 이름이 0 건이다" "$(grep -c 'CC_SL_' "$HOOK" || true)" "0"
check "L16 (3) 새 이름을 값으로 읽는 자리가 정확히 하나다" \
  "$(grep -c '\${CC_CMDS_STATUSLINE_AUTOINSTALL' "$HOOK" || true)" "1"

# ---------------------------------------------------------------------------
# L17 — neither the configuration directory nor the home directory is set
#
# Implemented in the order the architecture draws it — derivation ahead of the
# gate and ahead of the sourcing — this is quiet. Implemented with the gate
# first, it dies on an unset variable, and the unconditional `exit 0` is gone.
# ---------------------------------------------------------------------------
L17_OUT="$WORK/l17.out"; L17_ERR="$WORK/l17.err"
env -u CLAUDE_CONFIG_DIR -u HOME bash "$HOOK" --plugin-dir "$PLUG" > "$L17_OUT" 2> "$L17_ERR"
check "L17 설정 디렉터리와 홈이 모두 없으면 rc 0 이다" "$?" "0"
check "L17 그 실행의 stdout 도 0바이트다" "$(wc -c < "$L17_OUT" | tr -d ' ')" "0"
hasnt "L17 미설정 변수로 죽지 않는다" "$(cat "$L17_ERR")" "unbound variable"
env CLAUDE_CONFIG_DIR= HOME= bash "$HOOK" --plugin-dir "$PLUG" >/dev/null 2>"$L17_ERR"
check "L17 두 변수가 빈 문자열일 때도 rc 0 이다" "$?" "0"
hasnt "L17 빈 문자열에서도 미설정 변수로 죽지 않는다" "$(cat "$L17_ERR")" "unbound variable"

# ---------------------------------------------------------------------------
# L18 — the state the hook hands over is the classifier's own answer
#
# The structural half is what makes the behavioural half mean something: with the
# token typed on one side only, every call parks, and a case that only read "it
# parked" would be green.
# ---------------------------------------------------------------------------
l18_cls() {
  # l18_cls <settings> — what the shared classifier says about a value, called
  # the same way the hook calls it.
  ( set -uo pipefail; . "$CMDLIB"; sl_classify "$1" ) 2>/dev/null
}
L18E="$WORK/cfg-l18-empty"; cfg_empty "$L18E"
L18O="$WORK/cfg-l18-ours";  cfg_ours "$L18O"
check "L18 빈 상태 픽스처의 분류" "$(l18_cls "$L18E/settings.json")" "empty"
check "L18 우리 값 픽스처의 분류" "$(l18_cls "$L18O/settings.json")" "ours"
run_hook "$L18E" "$PLUG"
check "L18 빈 상태에서 훅이 넘긴 상태가 받아들여진다 (rc 21 이 아니다)" "$(mk_field "$L18E" verdict)" "installed"
run_hook "$L18O" "$PLUG"
check "L18 우리 값에서 훅이 넘긴 상태가 받아들여진다 (rc 21 이 아니다)" "$(mk_field "$L18O" verdict)" "adopt-repoint"
differ "L18 어느 쪽도 상태 불일치로 park 하지 않는다" "$(mk_field "$L18O" reason)" "require-state"
check "L18 (구조) 훅이 넘기는 상태가 분류기의 반환값 그대로다" \
  "$(grep -c -- '--require-state "\$CLS"' "$HOOK" || true)" "1"
check "L18 (구조) 훅이 그 어휘를 리터럴로 넘기는 자리가 0 건이다" \
  "$(grep -cE -- '--require-state (empty|ours)' "$HOOK" || true)" "0"
# A comparison, an assignment or a `case` arm that spells either token is a
# second source of the spelling. Comment lines are excluded; the shared file is
# not scanned, because it is the one source.
L18_LIT="^[^#]*((=|!=)[[:space:]]*['\"]?(empty|ours)['\"]?([^A-Za-z0-9_-]|\$)|(^|[[:space:]|(])['\"]?(empty|ours)['\"]?[[:space:]]*[|)])"
check "L18 (구조) 훅이 그 어휘를 비교 리터럴로 적은 자리가 0 건이다" \
  "$(grep -cE -- "$L18_LIT" "$HOOK" || true)" "0"
check "L18 (구조) 설치기가 그 어휘를 비교 리터럴로 적은 자리가 0 건이다" \
  "$(grep -cE -- "$L18_LIT" "$APPLY" || true)" "0"
check "L18 (구조) 그 패턴은 분류기 자신의 철자를 실제로 잡는다" \
  "$(grep -cE -- "$L18_LIT" "$CMDLIB" | awk '{print ($1 > 0) ? "잡는다" : "못 잡는다"}')" "잡는다"

# ---------------------------------------------------------------------------
# L19 — a command joined to ours without spaces is somebody else's
#
# The value starts with an absolute path and ends in our suffix, so only the
# operator in between says it runs another program first. Adopting it would drop
# that program from the fallback, on every machine that has such a value, at the
# first startup — so the hook must park on it without calling the installer.
# ---------------------------------------------------------------------------
l19_i=0
for v in "/usr/bin/true;$OLDSL" "/opt/a/bin/x|$OLDSL" "/opt/a&&$OLDSL" "/opt/setup.sh
$OLDSL"; do
  l19_i=$((l19_i + 1))
  L19="$WORK/cfg-l19-$l19_i"; mkdir -p "$L19"
  jq -n --arg c "$v" '{theme: "dark", statusLine: {type: "command", command: $c}}' > "$L19/settings.json"
  l19_sha=$(sha_of "$L19/settings.json")
  check "L19 연산자로 이은 값 $l19_i 의 분류" "$(l18_cls "$L19/settings.json")" "foreign"
  run_hook "$L19" "$PLUG"
  check "L19 연산자로 이은 값 $l19_i — 설정 파일이 바이트 동일" "$(sha_of "$L19/settings.json")" "$l19_sha"
  check "L19 연산자로 이은 값 $l19_i — park(foreign) 로 기억된다" \
    "$(mk_field "$L19" verdict)|$(mk_field "$L19" reason)" "park|foreign"
done

# ---------------------------------------------------------------------------
# L20 — a settings file managed through a symbolic link is parked and remembered
#
# The installer's commit is a rename, which would turn the link into a plain
# file and leave its source behind. It parks with rc 27 instead, and that code is
# inside the verdict band — so the marker is written and the next startup skips
# at the front gate rather than walking the slow path again on every session.
# ---------------------------------------------------------------------------
L20="$WORK/cfg-l20"; mkdir -p "$L20"
jq -n '{theme: "dark", model: "opus", cleanupPeriodDays: 30}' > "$L20/settings-src.json"
ln -s "$L20/settings-src.json" "$L20/settings.json"
l20_sha=$(sha_of "$L20/settings-src.json")
run_hook "$L20" "$PLUG"
check "L20 링크된 설정 파일 — park(linked) 로 기억된다" \
  "$(mk_field "$L20" verdict)|$(mk_field "$L20" reason)" "park|linked"
check "L20 링크된 설정 파일 — 첫 기동 뒤에도 링크다" "$([ -L "$L20/settings.json" ] && printf y || printf n)" "y"
check "L20 링크된 설정 파일 — 링크 원본의 바이트가 그대로다" "$(sha_of "$L20/settings-src.json")" "$l20_sha"
# Aged as L13 does: the gate compares mtimes at one-second grain, and `utime`
# follows the link, so it is the source the gate reads that is pushed back.
fx_age_file "$L20/settings.json" 10
fx_age_file "$L20/settings.json.cc-statusline" 5
l20_mk_m=$(mtime_of "$L20/settings.json.cc-statusline")
run_hook "$L20" "$PLUG"
check "L20 두 번째 기동은 앞단 게이트가 건너뛴다 — 마커가 다시 쓰이지 않는다" \
  "$(mtime_of "$L20/settings.json.cc-statusline")" "$l20_mk_m"
check "L20 두 번째 기동 뒤에도 링크다" "$([ -L "$L20/settings.json" ] && printf y || printf n)" "y"
check "L20 두 번째 기동 뒤에도 원본 바이트가 그대로다" "$(sha_of "$L20/settings-src.json")" "$l20_sha"

# L9 is deliberately absent: what a hook does in a workspace whose trust has not
# been accepted cannot be decided from inside the hook, and the observation that
# would settle it is a residual item on the design rather than a test.
skip "L9 신뢰되지 않은 워크스페이스에서의 동작" "R1 의 정산 행위를 기다린다"

printf '\n통과 %s · 실패 %s · 건너뜀 %s\n' "$passed" "$failed" "$skipped"
[ "$failed" -eq 0 ]
