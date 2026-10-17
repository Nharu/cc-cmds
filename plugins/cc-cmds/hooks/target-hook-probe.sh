#!/usr/bin/env bash
#
# target-hook-probe.sh — the target repository's own Bash hooks, read and run
# from outside the harness. SOURCED ONLY; executed directly it does nothing.
#
# WHY A FILE OF ITS OWN. Two processes need the same answers — the run hook
# (`gate-pretool.sh`), which runs on every Bash call of a stage and must not
# start the whole gate to get them, and the gate, which records what they say.
# A second copy of "which hooks does this root load" or "what does this guard
# say about these bytes" in either place is the copy that drifts, so both
# source this one.
#
# WHAT A PREDICTION IS WORTH. The only verdict that counts is the one the
# harness gets when it hands the command to the target's hook itself; the deny
# of any loaded hook wins over the run hook's allow. So a prediction here can
# only ADD a refusal — record it before the real guard refuses, and say what to
# do instead — and never grants anything. So it adds only the refusals the real
# guard will make: a hook that answers `ask` counts as a refusal, and a hook
# that fails the way the harness counts a failure (exits with anything but 0 or
# 2, cannot start, prints JSON that does not parse) is a refusal only when its
# entry carries `onFailure: "block"`. Any other failure is `비차단 오류` — the
# harness runs the tool — and a hook that outlives the probe's bound is
# `시간 초과`, whose meaning each caller decides. What is read as closed is the
# probe's own failure: a root whose settings cannot be read is `판정 불가`,
# which no caller reads as a pass.
#
# NOTHING HERE EVER ANSWERS `ask` OR `defer`. An unattended run has no person to
# ask, and in `-p` a `defer` ends the session without running the tool. The
# hook that sources this file emits only `allow` and `deny`.
#
# Compatibility: bash 3.2 + jq — no associative arrays, no mapfile.

# THE SECONDS ONE HOOK MAY RUN. Short on purpose: the run hook waits on it in
# every gate call of a hooked root, and a guard slower than this is not waited
# on. It is far shorter than the harness's own bound, so what such a guard
# would answer is unknown: the run hook lets the call through to the real
# guard, and admit records a refusal rather than issue a ticket.
THP_TIMEOUT="${THP_TIMEOUT:-10}"

# ---------------------------------------------------------------------------
# Caller key and its file-name form.
# ---------------------------------------------------------------------------
thp_key_norm() {
  # thp_key_norm <key> — the one spelling of a caller key inside a file name.
  #
  # The gate's digest file and every file under `admit/` take their name from
  # this function. Stage ids carry `:` and `#`, and a hook that interpolated the
  # id while the gate sanitized it once agreed with the gate only for the
  # router — the one caller that never meets the hook.
  printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '-'
}

thp_caller_key() {
  # thp_caller_key — the stage id when there is one, else the shift id, else
  # nothing. A stage a shift dispatched carries both variables, so the other
  # order would file a stage's request under its shift's name.
  if [ -n "${CC_PIPELINE_STAGE_ID:-}" ]; then
    printf '%s' "$CC_PIPELINE_STAGE_ID"
  elif [ -n "${CC_PIPELINE_SHIFT_ID:-}" ]; then
    printf '%s' "$CC_PIPELINE_SHIFT_ID"
  fi
}

# ---------------------------------------------------------------------------
# Roots and settings.
# ---------------------------------------------------------------------------
thp_phys() {
  # thp_phys <dir> — the physical path of a directory, empty when it is none.
  ( cd "$1" 2>/dev/null && pwd -P ) || true
}

thp_common_dir() {
  # thp_common_dir <dir> — the physical common git directory of the checkout
  # holding <dir>, empty outside a repository. Two checkouts of one repository
  # share it; that is what "the same target" means to the issuing-root rule.
  local d c
  d=$(thp_phys "$1"); [ -n "$d" ] || return 0
  c=$( cd "$d" && git rev-parse --git-common-dir 2>/dev/null ) || return 0
  [ -n "$c" ] || return 0
  case "$c" in /*) ;; *) c="$d/$c" ;; esac
  thp_phys "$c"
}

thp_settings_files() {
  # thp_settings_files <root> — the project settings files the harness loads for
  # a session started at <root>, one per line, existing files only: the root's
  # `.claude/settings.json` and `.claude/settings.local.json`, and — when the
  # root is a linked worktree — the main checkout's `settings.local.json`, which
  # the harness loads there too although a new worktree has no copy of its own.
  local root top gd cd main f
  root=$(thp_phys "$1"); [ -n "$root" ] || return 0
  for f in "$root/.claude/settings.json" "$root/.claude/settings.local.json"; do
    [ -f "$f" ] && printf '%s\n' "$f"
  done
  gd=$( cd "$root" && git rev-parse --git-dir 2>/dev/null ) || return 0
  case "$gd" in /*) ;; *) gd="$root/$gd" ;; esac
  gd=$(thp_phys "$gd")
  cd=$(thp_common_dir "$root")
  [ -n "$gd" ] && [ -n "$cd" ] && [ "$gd" != "$cd" ] || return 0
  case "$cd" in */.git) main="${cd%/.git}" ;; *) return 0 ;; esac
  top=$( cd "$root" && git rev-parse --show-toplevel 2>/dev/null ) || top=""
  [ -n "$top" ] && [ "$(thp_phys "$top")" = "$main" ] && return 0
  f="$main/.claude/settings.local.json"
  [ -f "$f" ] && printf '%s\n' "$f"
  return 0
}

# The jq program that selects PreToolUse blocks whose matcher matches `Bash`:
# an absent, empty or `*` matcher matches every tool, anything else is read as
# an anchored regular expression the way the harness reads it.
THP_JQ_BLOCKS='
  def bashy: (.matcher // "") as $m
    | ($m == "" or $m == "*" or ("Bash" | test("^(?:" + $m + ")$")));
  [ (.hooks.PreToolUse // [])[] | select(type == "object") | select(bashy) ]'

thp_bash_hook_entries() {
  # thp_bash_hook_entries <root> — the hook entries that judge a Bash call of a
  # session started at <root>, one per line as `<failure>\t<command>`:
  # `<failure>` is `block` when the entry carries `onFailure: "block"` and `-`
  # otherwise, and a newline inside a command becomes a space. Status 0 when
  # every settings file was read, 2 when one could not be — not JSON, a block
  # that is not a list, or a hook entry with no command string — and the caller
  # then says `판정 불가`, never "no hooks".
  local root f out rc=0
  root=$(thp_phys "$1"); [ -n "$root" ] || return 0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    out=$(jq -r "$THP_JQ_BLOCKS"'
      | .[] | (.hooks // error("no hooks")) | if type == "array" then . else error("hooks") end
      | .[] | if (.type // "command") != "command" then error("type")
              elif ((.command // "") | type) != "string" or (.command // "") == "" then error("command")
              else (if .onFailure == "block" then "block" else "-" end)
                   + "\t" + (.command | gsub("[\r\n]"; " ")) end' "$f" 2>/dev/null) || { rc=2; continue; }
    [ -n "$out" ] && printf '%s\n' "$out"
  done <<EOF
$(thp_settings_files "$root")
EOF
  return "$rc"
}

thp_bash_hooks() {
  # thp_bash_hooks <root> — the commands of `thp_bash_hook_entries`, one per
  # line, with its status.
  local out rc=0
  out=$(thp_bash_hook_entries "$1") || rc=$?
  [ -n "$out" ] && printf '%s\n' "$out" | cut -f2-
  return "$rc"
}

thp_hook_files() {
  # thp_hook_files <root> <hook command> — the files under <root> a hook command
  # names: split on blanks, quotes stripped, `$CLAUDE_PROJECT_DIR` and
  # `${CLAUDE_PROJECT_DIR}` read as the root, a relative word read against it;
  # a word that lands on a regular file under the root is one. What the guard
  # sources or imports is not followed.
  local root="$1" w p
  root=$(thp_phys "$root"); [ -n "$root" ] || return 0
  set -f
  # shellcheck disable=SC2086
  for w in $2; do
    w=$(printf '%s' "$w" | tr -d "\"'")
    case "$w" in
      '$CLAUDE_PROJECT_DIR'*) w="$root${w#\$CLAUDE_PROJECT_DIR}" ;;
      '${CLAUDE_PROJECT_DIR}'*) w="$root${w#\$\{CLAUDE_PROJECT_DIR\}}" ;;
    esac
    case "$w" in ''|-*) continue ;; /*) p="$w" ;; *) p="$root/$w" ;; esac
    [ -f "$p" ] && [ ! -L "$p" ] || continue
    p="$(thp_phys "$(dirname "$p")")/$(basename "$p")"
    case "$p" in "$root"/*) printf '%s\n' "$p" ;; esac
  done
  set +f
}

thp_hook_digest() {
  # thp_hook_digest <root> — prints `<digest> <count>`: the sha256 over the
  # matching blocks of every settings file and the bytes of every file their
  # commands name, and the number of hook commands. A root with no hook prints
  # `- 0`; a root whose settings could not be read prints the digest of the raw
  # settings bytes and `판정불가`, so the value still moves when a person edits
  # the file.
  local root f cmds n rc
  root=$(thp_phys "$1")
  [ -n "$root" ] || { printf -- '- 0\n'; return 0; }
  # `|| rc=$?`, not `; rc=$?`: the gate sources this file under `set -e`.
  rc=0; cmds=$(thp_bash_hooks "$root") || rc=$?
  if [ "$rc" -ne 0 ]; then
    printf '%s 판정불가\n' "$(
      while IFS= read -r f; do [ -n "$f" ] && { printf '%s\n' "$f"; cat "$f"; }; done <<EOF | shasum -a 256 | awk '{print $1}'
$(thp_settings_files "$root")
EOF
    )"
    return 0
  fi
  n=0
  [ -n "$cmds" ] && n=$(printf '%s\n' "$cmds" | grep -c '')
  [ "$n" -gt 0 ] || { printf -- '- 0\n'; return 0; }
  printf '%s %s\n' "$(
    {
      while IFS= read -r f; do
        [ -n "$f" ] || continue
        printf 'settings %s\n' "$f"
        jq -c "$THP_JQ_BLOCKS" "$f" 2>/dev/null
      done <<EOF
$(thp_settings_files "$root")
EOF
      printf '%s\n' "$cmds" | while IFS= read -r c; do
        thp_hook_files "$root" "$c"
      done | sort -u | while IFS= read -r f; do
        printf 'file %s\n' "$f"; cat "$f"
      done
    } | shasum -a 256 | awk '{print $1}'
  )" "$n"
}

# ---------------------------------------------------------------------------
# Running a hook.
# ---------------------------------------------------------------------------
thp_payload() {
  # thp_payload <command> <cwd> <tool_use_id> — the PreToolUse payload the
  # harness would hand a Bash hook for this call.
  jq -nc --arg c "$1" --arg d "$2" --arg t "$3" \
    '{hook_event_name:"PreToolUse", tool_name:"Bash", tool_input:{command:$c}, cwd:$d, tool_use_id:$t}'
}

thp_hook_failure() {
  # thp_hook_failure <failure> <what> <stderr file> — the verdict of a hook that
  # failed the way the harness counts a failure: `거절` when its entry blocks on
  # failure (`block`), else `비차단 오류` with the failure and the first line of
  # its standard error, since the harness runs the tool then.
  local why
  if [ "$1" = block ]; then
    why=$(tr '\n\r\t' '   ' <"$3" | cut -c1-600)
    printf '거절\n%s %s\n' "$2" "$why"
  else
    why=$(sed -n '1p' "$3" | tr '\r\t' '  ' | cut -c1-600)
    printf '비차단 오류\n비차단 오류 %s %s\n' "$2" "$why"
  fi
}

thp_run_hook() {
  # thp_run_hook <root> <hook command> <payload file> [<failure>] — runs one
  # hook under the time bound and prints `<verdict>` then the guard's text on
  # one line. <failure> is the entry's `block` or `-`, as
  # `thp_bash_hook_entries` prints it.
  local root="$1" hc="$2" pf="$3" fl="${4:--}" td of ef tf pid wpid rc dec why lead
  td=$(mktemp -d "${TMPDIR:-/tmp}/thp.XXXXXX") || { printf '판정 불가\n임시 디렉터리를 만들지 못했다\n'; return 0; }
  of="$td/out"; ef="$td/err"; tf="$td/timeout"
  ( cd "$root" 2>/dev/null || exit 126
    CLAUDE_PROJECT_DIR="$root" exec bash -c "$hc" ) <"$pf" >"$of" 2>"$ef" &
  pid=$!
  ( sleep "$THP_TIMEOUT"; : >"$tf"; kill -TERM "$pid" 2>/dev/null; sleep 1; kill -KILL "$pid" 2>/dev/null ) >/dev/null 2>&1 &
  wpid=$!
  rc=0; wait "$pid" || rc=$?
  kill "$wpid" 2>/dev/null || true
  wait "$wpid" 2>/dev/null || true
  # The first non-blank byte of the output: a `{` is JSON the harness parses,
  # and JSON it cannot parse is a failure; plain text is not.
  lead=$(sed -n '/[^[:space:]]/{s/^[[:space:]]*//;p;q;}' "$of" 2>/dev/null | cut -c1)
  if [ -e "$tf" ]; then
    printf '시간 초과\n시간 초과(%s초)\n' "$THP_TIMEOUT"
  elif [ "$rc" -eq 2 ]; then
    why=$(tr '\n\r\t' '   ' <"$ef" | cut -c1-600)
    printf '거절\n%s\n' "${why:-exit 2}"
  elif [ "$rc" -ne 0 ]; then
    thp_hook_failure "$fl" "exit $rc" "$ef"
  elif [ "$lead" = '{' ] && ! jq -e 'type == "object"' "$of" >/dev/null 2>&1; then
    thp_hook_failure "$fl" "읽히지 않는 JSON 출력" "$ef"
  else
    dec=""; why=""
    if jq -e 'type == "object"' "$of" >/dev/null 2>&1; then
      dec=$(jq -r '
        if (.hookSpecificOutput.permissionDecision // "") != "" then .hookSpecificOutput.permissionDecision
        elif (.decision // "") == "block" then "deny"
        elif .continue == false then "deny"
        else "" end' "$of" 2>/dev/null)
      why=$(jq -r '.hookSpecificOutput.permissionDecisionReason // .reason // .stopReason // ""' "$of" 2>/dev/null \
        | tr '\n\r\t' '   ' | cut -c1-600)
    fi
    case "$dec" in
      deny|ask) printf '거절\n%s\n' "${why:-$dec}" ;;
      defer)    printf '종단\ndefer\n' ;;
      ''|allow|approve) printf '통과\n\n' ;;
      *)        printf '거절\n알 수 없는 결정 %s\n' "$dec" ;;
    esac
  fi
  rm -rf "$td"
}

thp_probe() {
  # thp_probe <root> <command> <cwd> <tool_use_id> — what the Bash hooks of a
  # session started at <root> would say about <command>. Prints the merged
  # verdict on the first line — `통과`, `비차단 오류`, `시간 초과`, `거절`,
  # `종단` or `판정 불가` — and the winning guard's text on the second. Several
  # hooks merge as the harness merges them, a refusal over a defer, and either
  # over a timeout or a non-blocking failure; an unreadable settings file is
  # `판정 불가` unless some hook that could run already refuses or defers.
  local root cmds rc pf fl hc out v t r best="통과" btxt="" brank=0 undec=0 tab
  tab=$(printf '\t')
  root=$(thp_phys "$1")
  [ -n "$root" ] || { printf '판정 불가\n발행 루트가 디렉터리가 아니다\n'; return 0; }
  rc=0; cmds=$(thp_bash_hook_entries "$root") || rc=$?
  [ "$rc" -eq 0 ] || undec=1
  if [ -z "$cmds" ]; then
    if [ "$undec" -eq 1 ]; then printf '판정 불가\n설정 파일을 읽지 못했다\n'; else printf '통과\n\n'; fi
    return 0
  fi
  pf=$(mktemp "${TMPDIR:-/tmp}/thp-payload.XXXXXX") || { printf '판정 불가\n페이로드를 만들지 못했다\n'; return 0; }
  thp_payload "$2" "$3" "$4" >"$pf" 2>/dev/null || { rm -f "$pf"; printf '판정 불가\n페이로드를 만들지 못했다\n'; return 0; }
  while IFS="$tab" read -r fl hc; do
    [ -n "$hc" ] || continue
    out=$(thp_run_hook "$root" "$hc" "$pf" "$fl")
    v=$(printf '%s\n' "$out" | sed -n '1p'); t=$(printf '%s\n' "$out" | sed -n '2p')
    case "$v" in
      거절) r=4 ;;
      종단) r=3 ;;
      '시간 초과') r=2 ;;
      '비차단 오류') r=1 ;;
      '판정 불가') undec=1; r=0 ;;
      *) r=0 ;;
    esac
    if [ "$r" -gt "$brank" ]; then best="$v"; btxt="$t"; brank=$r; fi
  done <<EOF
$cmds
EOF
  rm -f "$pf"
  if [ "$brank" -le 2 ] && [ "$undec" -eq 1 ]; then
    best='판정 불가'; btxt='설정 파일을 읽지 못했다'
  fi
  printf '%s\n%s\n' "$best" "$btxt"
}

# ---------------------------------------------------------------------------
# The closed word grammar and the wrapped form's inner argv.
# ---------------------------------------------------------------------------
thp_closed_words() {
  # thp_closed_words <bytes> — splits a plain command line into words, printed
  # NUL-terminated, or returns 2 when the line is not one this grammar reads.
  #
  # Words split on blanks; `'…'` is read verbatim; `"…"` only when it holds no
  # `$`, backtick, `\` or `!`; outside quotes a byte is one of
  # `[A-Za-z0-9_@%+=:,./-]` or not ASCII; an unquoted `=` never stands where
  # the word has no byte yet, empty quotes before it included;
  # the first word is no `NAME=`. Every line it accepts splits the way bash and
  # zsh split it — the session's shell may be either, the suite holds them side
  # by side, and zsh turns a leading unquoted `=name` into the path of `name` —
  # and every line it refuses is one whose meaning would need a shell to know.
  local s="$1" n i c st=u w="" have=0 first=1 LC_ALL=C tab
  local -a out=()
  tab=$(printf '\t')
  n=${#s}; i=0
  [ "$n" -gt 0 ] || return 2
  while [ "$i" -lt "$n" ]; do
    c=${s:$i:1}
    case "$st" in
      u)
        case "$c" in
          ' '|"$tab")
            if [ "$have" -eq 1 ]; then
              if [ "$first" -eq 1 ]; then
                case "$w" in [A-Za-z_]*=*) case "${w%%=*}" in *[!A-Za-z0-9_]*) ;; *) return 2 ;; esac ;; esac
                first=0
              fi
              out[${#out[@]}]="$w"; w=""; have=0
            fi ;;
          "'") st=s; have=1 ;;
          '"') st=d; have=1 ;;
          # zsh reads an empty quoted pair before it as nothing: `''=ls`
          # expands as `=ls` does.
          '=') [ -n "$w" ] || return 2
               w="$w$c"; have=1 ;;
          [A-Za-z0-9_@%+:,./-]) w="$w$c"; have=1 ;;
          *)
            case "$c" in
              [[:print:]]|[[:cntrl:]]|[[:space:]]) return 2 ;;
            esac
            w="$w$c"; have=1 ;;
        esac ;;
      s)
        case "$c" in "'") st=u ;; *) w="$w$c" ;; esac ;;
      d)
        case "$c" in
          '"') st=u ;;
          '$'|'`'|'\'|'!') return 2 ;;
          *) w="$w$c" ;;
        esac ;;
    esac
    i=$((i+1))
  done
  [ "$st" = u ] || return 2
  if [ "$have" -eq 1 ]; then
    if [ "$first" -eq 1 ]; then
      case "$w" in [A-Za-z_]*=*) case "${w%%=*}" in *[!A-Za-z0-9_]*) ;; *) return 2 ;; esac ;; esac
    fi
    out[${#out[@]}]="$w"
  fi
  # Nothing is printed before the whole line has been read: a caller reading
  # through a pipe sees the status of the last command, so a refusal must not
  # leave the words before it behind.
  [ "${#out[@]}" -gt 0 ] || return 2
  for w in "${out[@]}"; do printf '%s\0' "$w"; done
  return 0
}

thp_after_dashdash() {
  # thp_after_dashdash <bytes> — what follows the first `--` that stands alone
  # outside quotes, or status 1 when there is none. Only quote pairs are
  # tracked; what comes before the `--` is never parsed further.
  local s="$1" n i c st=u prev=' ' nx tab LC_ALL=C
  tab=$(printf '\t')
  n=${#s}; i=0
  while [ "$i" -lt "$n" ]; do
    c=${s:$i:1}
    case "$st" in
      u)
        case "$c" in
          "'") st=s ;;
          '"') st=d ;;
          '-')
            nx=${s:$((i+1)):1}
            if [ "$nx" = '-' ]; then
              case "$prev" in ' '|"$tab")
                c=${s:$((i+2)):1}
                case "$c" in ''|' '|"$tab")
                  printf '%s' "${s:$((i+3))}"
                  return 0 ;;
                esac ;;
              esac
            fi ;;
        esac ;;
      s) [ "$c" = "'" ] && st=u ;;
      d) [ "$c" = '"' ] && st=u ;;
    esac
    prev="$c"
    i=$((i+1))
  done
  return 1
}

thp_act_digest() {
  # thp_act_digest <bytes> — the act digest of a recorded command line: the
  # sha256 of its words joined by single spaces, the definition the ledger's
  # `행위 다이제스트` already carries; the sha256 of the bytes themselves when
  # the line is not one the closed grammar reads.
  local j
  if thp_closed_words "$1" >/dev/null; then
    j=$(thp_closed_words "$1" | tr '\0' ' '; printf x); j="${j%x}"
    printf '%s' "${j% }" | shasum -a 256 | awk '{print $1}'
  else
    printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  fi
}

# ---------------------------------------------------------------------------
# The ticket's seal and the repository state it is bound to.
# ---------------------------------------------------------------------------
thp_ticket_seal() {
  # thp_ticket_seal — reads a ticket's JSON on standard input and prints the
  # 24 hex digits that end its id: the sha256 of every field but `id` and
  # `line`, keys sorted. The gate writes the id with this seal into the admit
  # row before the ticket exists, and the run hook honours a ticket only when
  # its id seals its contents and that row names the id. A file written under
  # `admit/ticket/` by any other hand either carries an id no row names, or an
  # id whose seal its contents do not match.
  jq -cS 'del(.id, .line)' 2>/dev/null | shasum -a 256 | cut -c1-24
}

thp_refs_digest() {
  # thp_refs_digest <dir> — the sha256 over everything a push run from <dir>
  # resolves its source and destination from: the HEAD of the checkout holding
  # <dir>, every ref of its repository (branches, tags, remote-tracking refs,
  # the stash), `FETCH_HEAD`, `ORIG_HEAD` and `MERGE_HEAD`, and the remote,
  # branch, push and url settings of the repository's own config file — read
  # `--local`, because the gate and the hook run under different environments
  # and settings an environment carries would differ between the two reads;
  # empty when <dir> is no checkout. A push
  # resolves its source from these when it runs, not when the gate graded it,
  # so a ticket for a push carries this value and the run hook reads it again
  # before letting the push through: a commit, a fetch, a moved tag or a changed
  # push setting between the admit and the issue changes it.
  local d out
  d=$(thp_phys "$1"); [ -n "$d" ] || return 0
  out=$( cd "$d" || exit 1
         git rev-parse HEAD 2>/dev/null || exit 1
         git for-each-ref --format='%(objectname) %(refname)' 2>/dev/null || exit 1
         for p in FETCH_HEAD ORIG_HEAD MERGE_HEAD; do
           printf '%s %s\n' "$p" "$(git rev-parse --verify -q "$p" 2>/dev/null)"
         done
         git config --local --get-regexp '^(remote|branch|push|url)\.' 2>/dev/null
         true ) || return 0
  printf '%s\n' "$out" | shasum -a 256 | awk '{print $1}'
}

# ---------------------------------------------------------------------------
# The per-target paragraph both launchers append.
# ---------------------------------------------------------------------------
thp_instruction_paragraph() {
  # thp_instruction_paragraph — the paragraph a session started at a hooked
  # root receives. One text, read by the gate's launch and the driver's alike.
  cat <<'EOF'
## Remote commands under this repository's own Bash hook

The repository this session starts in has its own PreToolUse Bash hook, and that hook judges the command string you run — a remote command wrapped in a gate call may be refused by it. So issue a remote command (pushing a branch, opening or reading a pull request, checks, a merge) bare, as the plain command itself. The run's hook refuses that first issue and records it as a request; then call the gate's `admit --request last` with `--manifest`, `--target`, `--segment`, `--surface`, `--reach`, `--snapshot-digest` and `--rationale`, and without `--cutpoint` — the gate derives the cell. When it answers with a ticket, issue the very same command again, byte for byte; that issue runs. A bare command runs in this session's own directory, which may not be the segment's worktree, so a push names the remote and the segment's branch; the gate refuses a push that names no branch, or names `HEAD` or `@`, from outside that worktree, and a push with anything before `git` (`env`, `command`, `nice` and the like) from anywhere. Keep command words out of the gate's free-text arguments: the `--rationale` text says why in plain words and does not name the program or its verbs.
EOF
}
