#!/usr/bin/env bash
#
# credentials.sh — capability separation for the run.
#
# A PreToolUse hook that matches command strings is a misuse detector, not a
# boundary: a script file, an alias, `env`, or a here-doc defeats it without
# ingenuity. What it CAN do is refuse a command it recognizes; what it cannot do
# is stop a process from doing the same thing by another spelling.
#
# Capability separation is the other half, and the two compose asymmetrically —
# which is why neither is redundant. A hook is not inherited by a nested
# process; a credential is. So the residual a hook leaves at unbounded nesting
# depth is exactly what a credential closes, and the acts a credential does not
# govern (a local file write, say) are exactly what the hook covers.
#
# The shape: the gate holds the write-scoped credential and nothing else does.
# The router and every stage process run with a read-only one. A `gh pr merge`
# outside the gate then fails at the GitHub API rather than at a string match,
# and that failure is unforgeable — which is the property a string matcher can
# never have.
#
# WHAT THIS FILE DOES NOT DO. It does not create credentials, and it does not
# read them from the repository. It reads what the operator placed in the
# keychain or the environment and hands the right one to the right process. A
# design in which this script could mint a write-scoped token would hand the
# all-night process a path to widening its own authorization, which is the one
# property the writer partition exists to remove.
#
# Usage:
#   . credentials.sh                       # source for the functions below
#   cred_readonly_env                      # print `KEY=VALUE` lines for a stage
#   cred_gate_env                          # print them for a gate-performed act
#   cred_check                             # report what is available, change nothing
#   cred_store_has <name>                  # does the declared store hold <name>? existence only
#   credentials.sh store-has <name>        # the same, as a command — prints 있음/없음
#
# Env override:
#   CC_GATE_TOKEN_RO     read-scoped token; falls back to the keychain lookup
#   CC_GATE_TOKEN_RW     write-scoped token; falls back to the keychain lookup
#   CC_GATE_KEYCHAIN     keychain service name (default `cc-cmds-autopilot`)
#   CC_CMDS_CRED_STORE   directory of the declared credential store (default `~/.config/cc-cmds`)
#
# Exit codes (when run rather than sourced):
#   0  both credentials resolve            (no subcommand)
#   1  a credential is missing — reported, never invented
#   `store-has`: 0 the store holds the name · 1 it does not · 2 the name is not a bare name
#
# Compatibility: bash 3.2 — no associative arrays, no mapfile.

CRED_KEYCHAIN="${CC_GATE_KEYCHAIN:-cc-cmds-autopilot}"
CRED_STORE="${CC_CMDS_CRED_STORE:-$HOME/.config/cc-cmds}"

cred_from_keychain() {
  # cred_from_keychain <account>
  # Absent is not an error here — the caller decides whether absence is fatal,
  # because a run whose cutpoint stops at `PR` never needs the write-scoped one.
  command -v security >/dev/null 2>&1 || return 1
  security find-generic-password -s "$CRED_KEYCHAIN" -a "$1" -w 2>/dev/null
}

cred_readonly_token() {
  if [ -n "${CC_GATE_TOKEN_RO:-}" ]; then printf '%s' "$CC_GATE_TOKEN_RO"; return 0; fi
  cred_from_keychain readonly
}

cred_write_token() {
  if [ -n "${CC_GATE_TOKEN_RW:-}" ]; then printf '%s' "$CC_GATE_TOKEN_RW"; return 0; fi
  cred_from_keychain write
}

cred_readonly_env() {
  # The environment a stage process gets. `GH_TOKEN` is set to the read-scoped
  # value and `GITHUB_TOKEN` is cleared rather than left alone — `gh` falls back
  # through several names, and leaving one populated makes the separation a
  # decoration.
  local t
  t=$(cred_readonly_token) || {
    printf 'credentials: 읽기 전용 자격을 찾지 못했습니다\n' >&2
    return 1
  }
  printf 'GH_TOKEN=%s\n' "$t"
  printf 'GITHUB_TOKEN=\n'
  printf 'GH_CONFIG_DIR=%s\n' "${RUN_DIR:-${TMPDIR:-/tmp}}/gh-ro"
}

cred_gate_env() {
  local t
  t=$(cred_write_token) || {
    printf 'credentials: 쓰기 자격을 찾지 못했습니다 — 이 런은 push 이상을 수행할 수 없습니다\n' >&2
    return 1
  }
  printf 'GH_TOKEN=%s\n' "$t"
  printf 'GITHUB_TOKEN=\n'
}

cred_check() {
  # Reports availability without printing either secret. The point of the report
  # is that a run whose cutpoint reaches `머지` with no write-scoped credential
  # should learn that at kickoff and not at 3am.
  local ro=0 rw=0
  cred_readonly_token >/dev/null 2>&1 && ro=1
  cred_write_token    >/dev/null 2>&1 && rw=1
  printf '읽기 전용 자격: %s\n' "$([ "$ro" = "1" ] && printf '있음' || printf '없음')"
  printf '쓰기 자격    : %s\n' "$([ "$rw" = "1" ] && printf '있음' || printf '없음')"
  [ "$ro" = "1" ] && [ "$rw" = "1" ]
}

cred_store_has() {
  # cred_store_has <name> — the declared store holds a regular file of that
  # name with mode 600. EXISTENCE ONLY, and the shape is what enforces it: the
  # file is never opened, so no value can reach stdout, a ledger row or a
  # transcript through this function. Same posture as `cred_check` above, which
  # answers 있음/없음 and prints neither secret.
  #
  # This is the second rung of the unattended design stage's residual-item
  # ladder: a verification item that names a credential is settled without a
  # person when the store already holds it. The gate grades commands by their
  # first word and `test -f` / `[ -f ]` have no row, so the stage cannot spell
  # this check inline — it calls this script by name, and that spelling is what
  # a manifest's `사전 인가` row targets.
  #
  # The slot is a NAME, not a path. A name carrying `/` or `..` would let the
  # caller probe an arbitrary path with the same authorization, so it is
  # refused (exit 2) rather than resolved.
  local name="$1" f perm
  case "$name" in ''|*/*|*..*) return 2 ;; esac
  f="$CRED_STORE/$name"
  [ -f "$f" ] || return 1
  # `ls -l`'s mode column is the one spelling BSD and GNU share; `stat` differs.
  perm=$(ls -ld "$f" 2>/dev/null | cut -c1-10) || return 1
  [ "$perm" = "-rw-------" ]
}

# Running the file rather than sourcing it performs the report and nothing else —
# or, with `store-has`, the existence check and nothing else.
case "${0##*/}" in
  credentials.sh)
    case "${1:-}" in
      '') cred_check ;;
      store-has)
        rc=0; cred_store_has "${2:-}" || rc=$?
        case "$rc" in
          0) printf '있음\n' ;;
          1) printf '없음\n' ;;
          *) printf 'credentials: 저장소 이름은 경로 구분자와 `..` 없는 이름이어야 합니다\n' >&2 ;;
        esac
        exit "$rc" ;;
      *) printf 'credentials: 알 수 없는 서브커맨드: %s\n' "$1" >&2; exit 2 ;;
    esac ;;
esac
