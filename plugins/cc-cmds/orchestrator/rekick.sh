#!/usr/bin/env bash
#
# rekick.sh — the autopilot kickoff's reader of a previous run, for a re-kickoff.
#
# When the same session calls the kickoff again after a run it opened has
# stopped, the kickoff may carry that run's answers into a new run instead of
# asking them again. This program finds that run, decides whether it may be
# carried, checks that its frozen files are intact, removes the steps the
# ledger proves finished, and renders the new manifest draft and the checks the
# draft must pass. It decides nothing a person has to answer: every value it
# renders is either byte-identical to the previous run, re-derived here, or an
# answer the kickoff passes in.
#
# IT WRITES NOTHING. Not into the previous run's directory, not into its ledger,
# not under `<base>`. The only files it makes are private copies in `TMPDIR`
# (mode 600, removed on exit), and every read of a previous run's manifest,
# authorization record and interview record is of such a copy — so the bytes it
# measured are the bytes it reads.
#
# `adopt`, `render-manifest` AND `verify-subset` READ THE DISK AND THE REMOTE.
# Whether an unlanded segment of the previous run may be adopted is read at the
# call: the segment's worktree and its git state on this machine, and its branch
# tip and pull request on GitHub, with the credentials of the calling shell.
# Those reads change nothing either — every git read here is
# `git --no-optional-locks`, and no gate function that writes a ledger row is
# called — so the sentence above stays true. `detect` reads no network.
#
# ONLY THE KICKOFF AND THE SEAT CALL THIS. Inside a pipeline run
# (`CC_PIPELINE_RUN_ID`, `CC_PIPELINE_STAGE_ID`, `CC_PIPELINE_SHIFT_ID` or
# `CC_PIPELINE_REENTRY` set) every mode, `judge` included, refuses with exit 3
# and an empty stdout before it reads anything.
#
# THE GATE IS NEVER SOURCED INTO THIS SHELL. `gate.sh` sources `run.sh` again,
# and `run.sh`'s top-level `readonly` lines die on a second source in a shell
# that already has them; a `( )` subshell inherits the attribute and does not
# help. The two gate functions this program asks — whether the gate ended the
# run, and whether the authorization record passes the gate's own check — run in
# a separate `bash` that sources only the gate through its definitions-only
# seam, the shape `run_gate_call` uses. That child compares the return with the
# gate's own `GATE_EXIT_RULE`, so the number is not written here. A child that
# cannot source the gate, or a return that is neither 0 nor that value, is "not
# decidable" and the run is reported `진행 중`.
#
# ONE LIVENESS, THE CLOSING VERB'S. `detect` asks the four predicates
# `gate.sh end-abandoned` refuses on — a live stage, a fresh waiting stage, a
# live shift, a live relay — so a run it offers for adoption is one the close
# at the end of the re-kickoff accepts. A run the gate has not ended and in
# which none of the four is alive is `대기`: it waits on something (an
# approval, a halt record, a usage limit) or on nothing, and the re-kickoff
# adopts it and closes it `이어받음`. Only the person's interactive re-kickoff
# reaches that: the kickoff and the seat call this program, the chain does not,
# and the seat's `judge` refuses an un-ended run.
#
# ONLY A RE-KICKOFF WORD ADOPTS AN UN-ENDED RUN. The close that follows an
# adoption cannot be undone, and an empty argument or a resume word (`이어서`,
# `재개`, `계속`, `resume`) is how a person comes back to a run that was cut. So
# those, and the intent verbatim, report such a run `진행 중` with what it waits
# on, and only `다시`, `재킥오프`, `다시 킥오프`, `rekick`, `again` or `retry`
# report it `대기`. A run the gate ended is a re-kickoff whatever the argument.
#
# Usage
#
#   rekick.sh detect --arg <인자>
#   rekick.sh judge --prev <id> --base <base> [--asked <파일>]
#   rekick.sh verify --prev <id> --base <base>
#   rekick.sh graph --prev <id> --base <base> [--expect-sha256 <hex>] [--accepted <별칭,…>]
#   rekick.sh render-manifest --prev <id> --base <base> --run-id <new> --kickoff-at <ISO8601>
#                             --deadline <ISO8601> --expect-sha256 <hex> --expect-grant-sha256 <hex>
#                             [--arg <인자>] [--asked <TSV>] [--visual-marker <값>]
#                             [--targets <파일>] [--rows <파일>] [--rule <키>=<켬|끔>]…
#                             [--bind-base <hex>] [--set <범위>:<키>=<값>]… [--auto] [--no-adopt]
#   rekick.sh adopt --prev <id> --base <base> --expect-sha256 <hex> [--targets <파일>] [--auto]
#   rekick.sh render-interview --prev <id> --base <base> [--expect-sha256 <hex>]
#   rekick.sh verify-subset <초안> <이전 매니페스트> --expect-sha256 <hex>
#                           --expect-grant-sha256 <hex> --asked <TSV> [--grant <블록 파일>]
#                           [--set <범위>:<키>=<값>]… [--blank-rows <파일>] [--auto]
#
# `judge` is the seat's verdict on a run that just ended, read-only like every
# other mode and reading neither the terminal nor stdin. It evaluates every
# prohibition line (L14 L1 L2 L3 L5 L6 L7 L9 L15 L10 L11 L12 L13) and prints
# each that fires; its only waits are the two questions `verify` asks, and a
# wait whose key the `--asked` file already holds is not printed — the answer
# is not read here, `verify-subset` measures what it allows. It never decides
# a deadline: that is the kickoff helper's `--carry --auto`. L13 reads only
# the manifests under this `<base>`; a source carried on from another base is
# not seen.
#
# `--auto` is the seat's link. `render-manifest --auto` fixes the approval text
# to `좌석 재킥오프` and the confirmation text to `좌석 재킥오프 <원천 id>` and
# each answer, takes no `--set` or `--accepted`, and adds `좌석 연쇄=<k> |
# 뿌리 런=<id> | 원인=<종료 토큰>` to the provenance row; a k past the consent
# row's `연쇄 상한`, and a graph `graph` would call changed, are refused with 3. `verify-subset --auto` wants that seven-field row exactly,
# the previous `재킥오프` row byte for byte, and a deadline that keeps either
# the previous interval or the consent row's `길이` from the draft's kickoff.
# Without `--auto` nothing of this changes: the four-field row only.
#
# `adopt` lists, for each segment of the previous run the gate's landing walk
# finds unlanded, whether this re-kickoff may adopt it: `입양후보` with the
# branch, worktree, pull request and head the adoption row will carry, or
# `입양불가` with the first condition that failed. The conditions are read in a
# fixed order — the ledger and the frozen document first, then the worktree,
# the remote tip, the pull request, and the gate's own planning-time adoption
# and halt-answer checks — and are the same for a person and the seat, except
# that the seat (`--auto`) does not adopt a segment whose last row is a `park`
# it never landed from. `render-manifest` writes a `세그먼트 입양` row inside
# `## 인가` for each candidate a person answered `이어받기` (`--asked` key
# `입양 <세그먼트>`), or under `--auto` for every candidate; it never copies the
# previous run's own adoption rows, and `--no-adopt` writes none. `verify-subset`
# derives the candidates again on the same branch and checks the rows against
# them (check `입양`). `detect` reads the ledger only and says, per unlanded
# segment, whether it is a candidate or why it is not.
#
# `--set` carries a value 5o confirmed for a `빈칸` row of `--carry`: `<범위>`
# is that row's scope (`런`, or a target named by its alias or by the remote
# slug `--carry` labels it with) and `<키>` its key, one of
# ladder-rungs · stagnation-bound · cost-ceiling · apply-probe · apply-actor ·
# apply-probe-codes (scope `런`) or cutpoint · review-ceiling · terminal-cap · dev-ids ·
# deploy-triggers (a target). The previous manifest must hold no value
# there; anything else is refused. `render-manifest` writes the value into the
# draft and `verify-subset` takes the same `--set` list, so the draft's value is
# compared with the confirmed one rather than exempted.
#
# The `적용 프로브 코드` row of `## 인가` is bound to the probe's hash, so
# `render-manifest` copies it byte for byte with the rest of the section and
# `verify-subset` refuses a draft whose row differs from the previous one —
# added, dropped or changed. The one exception is a previous manifest whose
# pipeline-run probe has no row, or a row carrying 2 (`apply_code_row_reask`):
# with no row only 불필요=0 is defined and a row with 2 is refused by the
# manifest check, so 5c is asked again. Then `render-manifest` drops the row,
# `--set 런:apply-probe-codes=<불필요>/<필요>` writes the confirmed mapping as a
# new row bound to the draft's probe bytes, and `verify-subset` accepts a row
# that differs from the previous one only as that `--set` value, and refuses a
# draft with no such value. The value is a `빈칸` row 5o confirmed, or — when
# `--carry` had no file value and named the key `다시 물음` — 5c's answer,
# recorded under `5c`. Nothing here writes the previous run's pinned plugin copy or its
# pin record; the draft is the only file this mode makes.
#
# `--blank-rows` is the `--carry` output 5o showed, saved byte for byte. It is
# required with `--set` in `verify-subset`: each entry must equal one of its
# `빈칸` rows in scope, key and value, so a value moved to another target or
# typed differently from the row the person confirmed does not pass. A row's
# scope is resolved against the previous manifest by the rule `--set` uses. It
# is required too when the draft holds a `플러그인 허용` row the previous run
# does not carry.
#
# THE `플러그인 허용` ROWS CARRY, judged again at each call. `render-manifest`
# and `graph` keep each previous row in place, byte for byte, unless its key is
# now in the seed beside this file or judged not installed in the account
# directories the kickoff reads; a row whose key cannot be judged, because an
# account file did not read, is carried, and `render-manifest` names each such
# row on stderr as `플러그인 알림<TAB>판정 불가 이월<TAB><키><TAB><경로>`.
# `--rows` may add rows for the plugin defaults 5o confirmed for a blank,
# `- \`플러그인 허용\` | 플러그인=<키> | 사유=킥오프 기본값`, written before the
# provenance row; a row of another shape, any such row under `--auto`, and a
# key given twice or already carried are refused. Any `--rows` still replaces
# every previous shape and auto-adoption row with its own, so a file that holds
# plugin rows alone drops them: it carries the previous rows it keeps.
# `verify-subset` checks them as `플러그인`: a person's draft holds every
# previous row whose key is on or cannot be judged now, and each other row is a
# confirmed default — that row shape, a `빈칸` row of `--blank-rows` for the
# key, the `--asked` key `5o <범위>:plugin-allow=<키>`, the answer
# `<범위>:plugin-allow=<키>` in the confirmation text, and the key on now. The
# seat's draft passes where a change of the account set between the two calls
# explains the difference, each named on stderr as `플러그인 알림<TAB>초안에
# 남은 미설치 행<TAB><키>`, `플러그인 알림<TAB>초안에서 빠진 켬 행<TAB><키>` or
# `플러그인 알림<TAB>초안에서 빠진 판정 불가 행<TAB><키><TAB><경로>`; a row
# that differs from every previous row, or whose key is in the seed, fails.
#
# `detect` takes no `<base>`: the kickoff resolves its own `<base>` only after
# the targets are settled, and this step runs before that. Each candidate's
# `<base>` comes from its run directory's `ledger-path`, and the `재킥오프`
# verdict carries it for the modes that follow.
#
# Output is TAB-separated and starts with the line `cc-rekick v1`, except
# `render-manifest` (the draft's bytes) and `render-interview` (the record's
# bytes), which print nothing else.
#
#   detect         판정  재킥오프|대기|새 런|없음|진행 중|완료  [<id>  [<base>]]
#                  갈래  게이트 종료|강제 표면 이동 무효화|대기 이어받기|완료 런 입양
#                  대기 원인  승인 대기|사람 대기|한도 대기|무기록|멈춤
#                  킥오프  <이전 킥오프 일시>
#                  종료 표시  <게이트가 남긴 종료 표시>
#                  고지  <한 줄>          굵게  <굵게 보일 한 줄>
#   judge          판정  허용|대기|금지
#                  금지선  <L>  <사유>
#                  대기  베이스설계|어휘  <--asked 키>  <질문 문면>
#                  사실  종료 토큰|연쇄|진전|열린 승인|미답 중단|종료 절|남은 단계  <값>
#   verify        검사  다이제스트|인터뷰|인가|머리  통과|실패  <사유>
#                  해시  매니페스트|인가 기록|인터뷰  <hex|->
#                  베이스설계  <문서>  <행 sha256>  <지금 sha256|->
#                  질문  베이스설계  <문서>  <행 sha256>  <지금 sha256>
#                  값  <이름>  <값>        대상  <대상 행>
#                  판정  통과|실패  [<실패한 검사, …>]
#   graph          범위  single|base       설계|감사  뺌|남음|없음  <근거>
#                  건너뜀  <id>  <skill>  <근거>     남음  <id>  <skill>  <depends_on|->
#                  계획  <JSON 한 줄>      문서해시  <hex|->
#                  대상추가  <별칭>  <원격 슬러그>  <메인 워크트리>  <공통 git 디렉터리>  <베이스 브랜치>
#                  그래프  순수 | 바뀜  <사유>
#   verify-subset  검사  <이름>  통과|실패  <사유>
#                  판정  통과|실패  [<실패한 검사, …>]
#   adopt          입양후보  <세그먼트>  <브랜치>  <워크트리>  <PR 번호>  <HEAD 40자>  [<꼬리 칸>…]
#                  입양불가  <세그먼트>  <PR 번호|->  <사유 토큰>
#
# An `입양후보` line's tail cells, each only when it applies and in this order:
# `마지막행=park` (a person's branch, the segment's last row is `park`), then
# one `원인=<행 종류>:<원장 줄>` per cause row the ledger holds for that park
# (`원인=없음` when none), `중단기록=<기록 이름,…>` (the previous run's
# unanswered halt records of that segment) and `이월=재수렴` (the gate would
# carry a `재수렴` answer into the new run). The reason tokens: park,
# 설계재실행, 슬라이스다름, 워크트리없음, PR기록없음, PR닫힘, HEAD불일치,
# 브랜치다름, 작업트리변경, PR판독불가, PR불일치, 포크PR, 베이스다름, 착지됨,
# 라이브, 원장없음, 중단답이월불가, and 판정불가 when the gate child could
# not answer.
#
# The `--asked` file lists the questions this re-kickoff actually asked, one
# `<키><TAB><답 축자>` per line. The keys the checks read: `대상확인 <별칭>`,
# `대상추가 <별칭>`, `5p`, `5q`, `5u <별칭> <체크>`, `5e`, `5e 값`, `5l`, `5o <범위>:<키>`,
# `7.7 절단점 <별칭>`, `7.7 룰 <키>`, `7.7 자동채택`, `7.8`, `입양 <세그먼트>`. Any other key covers
# nothing, and every answer, whatever its key, must stand verbatim in the
# draft's `사용자 확인 문면`. `5e` is the person's answer as given — a relative
# form such as `+8h` included — and `5e 값` the absolute instant the kickoff
# resolved it to once; the deadline check compares the draft with the latter as
# an instant. A key asked twice counts by its last line.
#
# Exit codes: 0 read (a `verify` or `verify-subset` that passed) · 1 a check
# failed (`verify`, `verify-subset`, `render-interview`, a hash that does not
# match) · 2 usage · 3 refused (inside a run, or a `render-manifest --auto`
# link the chain or the graph does not allow) or the driver's vocabulary could not be read. On 2 and 3, and on 1 from `render-manifest`, `render-interview`,
# `graph` and `adopt`, stdout is empty and stderr carries one line. `adopt` exits
# 0 when it lists no candidate.
#
# Compatibility: bash 3.2 — no associative arrays, no `mapfile`. Time is
# computed with jq only.

set -uo pipefail

RK_PROG='rekick.sh'
RK_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)

rk_refuse() { printf '%s: %s\n' "$RK_PROG" "$1" >&2; exit 3; }
rk_usage()  { printf '%s: %s\n' "$RK_PROG" "$1" >&2; exit 2; }
rk_fail()   { printf '%s: %s\n' "$RK_PROG" "$1" >&2; exit 1; }

for rk_v in CC_PIPELINE_RUN_ID CC_PIPELINE_STAGE_ID CC_PIPELINE_SHIFT_ID CC_PIPELINE_REENTRY; do
  eval "rk_val=\${$rk_v:-}"
  if [ -n "$rk_val" ]; then
    rk_refuse "파이프라인 런 안에서는 읽지 않습니다 — 재킥오프는 킥오프와 좌석만 읽습니다 ($rk_v 가 설정돼 있습니다)"
  fi
done

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------
RK_MODE="${1:-}"
[ $# -gt 0 ] && shift
RK_ARG=""; RK_ARG_GIVEN=0; RK_PREV=""; RK_BASE=""; RK_XSHA=""; RK_XGSHA=""
RK_ACCEPTED=""; RK_NEWID=""; RK_KAT=""; RK_DEADLINE=""; RK_ASKED=""
RK_VISUAL=""; RK_TARGETS=""; RK_ROWS=""; RK_RULES=""; RK_BIND=""; RK_GRANT_BLOCK=""
RK_POS1=""; RK_POS2=""; RK_SETS=""; RK_BLANKS=""; RK_AUTO=0; RK_NOADOPT=0

rk_need() { [ $# -ge 2 ] || rk_usage "$1 에 값이 없습니다"; }
while [ $# -gt 0 ]; do
  case "$1" in
    --arg)                 rk_need "$@"; RK_ARG="$2"; RK_ARG_GIVEN=1; shift 2 ;;
    --prev)                rk_need "$@"; RK_PREV="$2"; shift 2 ;;
    --base)                rk_need "$@"; RK_BASE="$2"; shift 2 ;;
    --expect-sha256)       rk_need "$@"; RK_XSHA="$2"; shift 2 ;;
    --expect-grant-sha256) rk_need "$@"; RK_XGSHA="$2"; shift 2 ;;
    --accepted)            rk_need "$@"; RK_ACCEPTED="$2"; shift 2 ;;
    --run-id)              rk_need "$@"; RK_NEWID="$2"; shift 2 ;;
    --kickoff-at)          rk_need "$@"; RK_KAT="$2"; shift 2 ;;
    --deadline)            rk_need "$@"; RK_DEADLINE="$2"; shift 2 ;;
    --asked)               rk_need "$@"; RK_ASKED="$2"; shift 2 ;;
    --visual-marker)       rk_need "$@"; RK_VISUAL="$2"; shift 2 ;;
    --targets)             rk_need "$@"; RK_TARGETS="$2"; shift 2 ;;
    --rows)                rk_need "$@"; RK_ROWS="$2"; shift 2 ;;
    --rule)                rk_need "$@"
                           case "$2" in
                             *=켬|*=끔) ;;
                             *) rk_usage "--rule 은 <키>=<켬|끔> 입니다: '$2'" ;;
                           esac
                           RK_RULES="${RK_RULES}${2}
"; shift 2 ;;
    --bind-base)           rk_need "$@"; RK_BIND="$2"; shift 2 ;;
    --grant)               rk_need "$@"; RK_GRANT_BLOCK="$2"; shift 2 ;;
    --blank-rows)          rk_need "$@"; RK_BLANKS="$2"; shift 2 ;;
    --auto)                RK_AUTO=1; shift ;;
    --no-adopt)            RK_NOADOPT=1; shift ;;
    --set)               rk_need "$@"
                           case "$2" in
                             *"$(printf '\t')"*|*'
'*) rk_usage "--set 값에 탭이나 줄바꿈이 있습니다" ;;
                             ?*:?*=?*) ;;
                             *) rk_usage "--set 은 <범위>:<키>=<값> 입니다: '$2'" ;;
                           esac
                           RK_SETS="${RK_SETS}${2}
"; shift 2 ;;
    --*)                  rk_usage "알 수 없는 인자입니다: $1" ;;
    *)
      if [ -z "$RK_POS1" ]; then RK_POS1="$1"
      elif [ -z "$RK_POS2" ]; then RK_POS2="$1"
      else rk_usage "위치 인자가 너무 많습니다: $1"; fi
      shift ;;
  esac
done

rk_hex64() { case "$1" in *[!0-9a-f]*|'') return 1 ;; esac; [ "${#1}" = "64" ]; }
rk_id_ok() {
  case "$1" in ''|.|..|*/*|*[!A-Za-z0-9._-]*) return 1 ;; esac
  return 0
}
rk_need_prev() {
  rk_id_ok "$RK_PREV" || rk_usage "--prev 는 런 id 하나여야 합니다: '$RK_PREV'"
  case "$RK_BASE" in /*) ;; *) rk_usage "--base 는 절대 경로여야 합니다: '$RK_BASE'" ;; esac
}

case "$RK_MODE" in
  detect)
    [ "$RK_ARG_GIVEN" = "1" ] || rk_usage "detect 에는 --arg 가 필요합니다 (빈 인자는 --arg '')" ;;
  verify|render-interview|judge)
    rk_need_prev ;;
  graph)
    rk_need_prev
    [ -z "$RK_XSHA" ] || rk_hex64 "$RK_XSHA" || rk_usage "--expect-sha256 은 64자리 소문자 16진수입니다" ;;
  render-manifest)
    rk_need_prev
    rk_id_ok "$RK_NEWID" || rk_usage "--run-id 는 런 id 하나여야 합니다: '$RK_NEWID'"
    [ "$RK_NEWID" != "$RK_PREV" ] || rk_usage "--run-id 가 --prev 와 같습니다"
    [ -n "$RK_KAT" ] || rk_usage "render-manifest 에는 --kickoff-at 이 필요합니다"
    [ -n "$RK_DEADLINE" ] || rk_usage "render-manifest 에는 --deadline 이 필요합니다"
    rk_hex64 "$RK_XSHA" || rk_usage "--expect-sha256 은 64자리 소문자 16진수입니다"
    rk_hex64 "$RK_XGSHA" || rk_usage "--expect-grant-sha256 은 64자리 소문자 16진수입니다"
    [ -z "$RK_BIND" ] || rk_hex64 "$RK_BIND" || rk_usage "--bind-base 는 64자리 소문자 16진수입니다" ;;
  verify-subset)
    [ -n "$RK_POS1" ] && [ -n "$RK_POS2" ] || rk_usage "verify-subset 에는 <초안> 과 <이전 매니페스트> 가 필요합니다"
    rk_hex64 "$RK_XSHA" || rk_usage "--expect-sha256 은 64자리 소문자 16진수입니다"
    rk_hex64 "$RK_XGSHA" || rk_usage "--expect-grant-sha256 은 64자리 소문자 16진수입니다"
    [ -n "$RK_ASKED" ] || rk_usage "verify-subset 에는 --asked 가 필요합니다 (물은 것이 없으면 빈 파일)" ;;
  adopt)
    rk_need_prev
    rk_hex64 "$RK_XSHA" || rk_usage "--expect-sha256 은 64자리 소문자 16진수입니다" ;;
  '') rk_usage "모드가 없습니다 — detect | judge | verify | graph | render-manifest | render-interview | verify-subset | adopt" ;;
  *)  rk_usage "알 수 없는 모드입니다: $RK_MODE" ;;
esac
[ "$RK_NOADOPT" = "0" ] || [ "$RK_MODE" = "render-manifest" ] || rk_usage "--no-adopt 는 render-manifest 에만 씁니다"
if [ "$RK_AUTO" = "1" ]; then
  case "$RK_MODE" in
    render-manifest|verify-subset|adopt) ;;
    *) rk_usage "--auto 는 render-manifest·verify-subset·adopt 에만 씁니다" ;;
  esac
  [ -z "$RK_SETS" ] || rk_usage "--auto 에는 --set 을 넘기지 않습니다 — 좌석은 빈칸을 이전 값 그대로 둡니다"
  [ -z "$RK_ACCEPTED" ] || rk_usage "--auto 에는 --accepted 를 넘기지 않습니다 — 좌석은 대상을 더하지 않습니다"
fi
[ -z "$RK_ASKED" ] || [ -r "$RK_ASKED" ] || rk_usage "--asked 파일을 읽을 수 없습니다: $RK_ASKED"
[ -z "$RK_TARGETS" ] || [ -r "$RK_TARGETS" ] || rk_usage "--targets 파일을 읽을 수 없습니다: $RK_TARGETS"
[ -z "$RK_ROWS" ] || [ -r "$RK_ROWS" ] || rk_usage "--rows 파일을 읽을 수 없습니다: $RK_ROWS"
[ -z "$RK_GRANT_BLOCK" ] || [ -r "$RK_GRANT_BLOCK" ] || rk_usage "--grant 파일을 읽을 수 없습니다: $RK_GRANT_BLOCK"

# ---------------------------------------------------------------------------
# Vocabulary and readers — sourced from the driver, never copied.
# ---------------------------------------------------------------------------
[ -r "$RK_DIR/run.sh" ] || rk_refuse "run.sh 를 읽을 수 없습니다: $RK_DIR/run.sh"
# shellcheck disable=SC1091
CC_ORCH_SOURCE_ONLY=1 . "$RK_DIR/run.sh" >/dev/null 2>&1 || rk_refuse "run.sh 를 들여오지 못했습니다"
set +e +u
set +o pipefail
[ -n "${CUTPOINTS:-}" ] || rk_refuse "run.sh 에서 절단점 어휘를 읽지 못했습니다"
for rk_f in manifest_field manifest_hdr_field manifest_row_fields manifest_plan_json manifest_plan_field \
            manifest_targets manifest_rule_lines manifest_preauth_rows manifest_autoadopt_rows_anywhere \
            manifest_design_roster_rows_anywhere manifest_clause_rows_raw manifest_base_design_rows \
            manifest_design_scope manifest_apply_code_rows target_field target_aliases canonical_targets binding_set_bytes \
            check_manifest rundir_of_run_id deadline_instant cutpoint_index \
            judgment_class_ok judgment_class_forbidden \
            cc_live_stages cc_shift_is_live cc_relay_is_live cc_waiting_fresh_count cc_unanswered_halts cc_halt_answered \
            cc_unresolved_blocked cc_open_approval_rows cc_segment_states \
            dr_duration_seconds manifest_rekick_rows manifest_adoption_rows manifest_plugin_allow_rows slice_ids; do  command -v "$rk_f" >/dev/null 2>&1 || rk_refuse "run.sh 에 $rk_f 가 없습니다"
done

# The plugin judgment — the functions the kickoff judges its plugin defaults
# with, over the seed copy beside this file. Every judgment reads account files
# through jq, so without jq there is no judgment to carry rows by.
[ -r "$RK_DIR/plugin-isolation.sh" ] || rk_refuse "plugin-isolation.sh 를 읽을 수 없습니다: $RK_DIR/plugin-isolation.sh"
# shellcheck disable=SC1091
. "$RK_DIR/plugin-isolation.sh" >/dev/null 2>&1 || rk_refuse "plugin-isolation.sh 를 들여오지 못했습니다"
for rk_f in pi_kickoff_account_dirs pi_key_state pi_judge pi_seed_keys pi_kickoff_user_keys pi_kickoff_read_fail; do
  command -v "$rk_f" >/dev/null 2>&1 || rk_refuse "plugin-isolation.sh 에 $rk_f 가 없습니다"
done
command -v jq >/dev/null 2>&1 || rk_refuse "jq 가 없습니다 — 플러그인 허용 행의 설치 여부를 판정하지 못합니다"
RK_PI_SEED="$RK_DIR/plugin-allow.seed"

RK_TMP=$(mktemp -d "${TMPDIR:-/tmp}/cc-rekick.XXXXXX" 2>/dev/null) || rk_refuse "개인 임시 디렉터리를 만들지 못했습니다"
chmod 700 "$RK_TMP" 2>/dev/null || rk_refuse "개인 임시 디렉터리의 권한을 700 으로 두지 못했습니다"
trap 'rm -rf "$RK_TMP"' EXIT

TAB=$(printf '\t')

rk_sha() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" 2>/dev/null | awk '{ print $1 }'
  else
    sha256sum "$1" 2>/dev/null | awk '{ print $1 }'
  fi
}
rk_sha_stdin() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 | awk '{ print $1 }'
  else sha256sum | awk '{ print $1 }'; fi
}

# rk_copy <source> <name> — the private copy's path, or nothing. Mode 600.
rk_copy() {
  local dst="$RK_TMP/$2"
  [ -f "$1" ] && [ -r "$1" ] || return 1
  ( umask 077; cat -- "$1" > "$dst" ) 2>/dev/null || return 1
  chmod 600 "$dst" 2>/dev/null || return 1
  printf '%s' "$dst"
}

# rk_wide_instant <value> — epoch seconds, or nothing. A trailing `Z` and a
# trailing `±HHMM` are rewritten to `±HH:MM` first, and the driver's own reader
# decides the rest: it renders the value back to itself and refuses an offset
# beyond ±14:00, so no instant the gate would refuse is read here.
rk_wide_instant() {
  local s
  s=$(jq -rn --arg s "$1" '$s | sub("Z$"; "+00:00") | sub("(?<g>[+-])(?<h>[0-9]{2})(?<m>[0-9]{2})$"; "\(.g)\(.h):\(.m)")' 2>/dev/null) || s=''
  [ -n "$s" ] || return 0
  deadline_instant "$s"
}

rk_trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# rk_intent — the fenced text under `## 의도`, whole, of the current MANIFEST.
rk_intent() {
  awk '
    $0 == "## 의도" { inb = 1; next }
    inb && /^## / { exit }
    inb && /^```/ { if (fence) exit; fence = 1; next }
    inb && fence { print }
  ' "$MANIFEST"
}

# rk_prev_paths — the previous run's files, from its id and `<base>`.
rk_prev_paths() {
  RK_PM="$RK_BASE/docs/pipeline-run/$RK_PREV.plan.md"
  RK_PG="$RK_BASE/docs/pipeline-grant/$RK_PREV.md"
  RK_PL="$RK_BASE/docs/pipeline-run/$RK_PREV.md"
  RK_PRD=$(rundir_of_run_id "$RK_PREV" 2>/dev/null) || RK_PRD=""
}

# rk_interview_rows — the interview rows of the current MANIFEST.
rk_interview_rows() { manifest_preauth_rows | grep -E '^- `사전 인가` \| 인터뷰 기록=' || true; }
# rk_carry_rows — the provenance rows (first field `이어받은 런=`).
rk_carry_rows() { manifest_preauth_rows | grep -E '^- `사전 인가` \| 이어받은 런=' || true; }
# rk_shape_rows — the `사전 인가` rows that carry a shape.
rk_shape_rows() { manifest_preauth_rows | grep -E '^- `사전 인가` \| 형태=' || true; }

# rk_cut_max <rows…> — the highest cutpoint token over the given target rows,
# or nothing when none of them carries a token in the vocabulary.
rk_cut_max() {
  local row tok i best=0 besttok=""
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    tok=$(manifest_row_fields "$row" '절단점')
    i=$(cutpoint_index "$tok" 2>/dev/null) || continue
    if [ "$i" -gt "$best" ]; then best=$i; besttok=$tok; fi
  done <<EOF
$1
EOF
  printf '%s' "$besttok"
}

# ---------------------------------------------------------------------------
# The gate child. rk_gate <mode> <manifest> <run id> <run dir> <ledger> <grant>
# <stderr file> [<value>…] — prints one fixed token, or one value of a fixed
# shape.
#
#   ended · grant                     끝남|안끝남 · 통과|실패
#   landed <seg>                      착지됨|미착지 — the gate's landing walk
#                                     over the ledger's rows of that id
#   adopt-check <seg> <alias> <row>   통과|라이브|워크트리없음|브랜치다름|원장없음|착지됨
#                                     — the planning-time adoption check, its
#                                     warning mapped to a token
#   halt-source <seg>                 이월|없음|불가 — the halt-answer carry check
#   tip-of <dir> <slug> <branch>      <40 hex>|없음|미상
#   pr-of <dir> <slug> <branch> <head>
#                                     <번호>\t<OPEN|MERGED>\t<40 hex>, or the
#                                     three cells all 없음, 불일치 or 미상
#   pr-view <번호> <slug>             <state>\t<head branch>\t<head 40 hex>\t
#                                     <true|false>\t<owner>\t<base branch>, or 미상
#
# The context is the caller's to choose and the gate functions trust it: for
# `adopt-check` and `halt-source` the manifest is a private copy holding only
# the candidate's adoption row, and the run id, run directory, ledger and grant
# are the previous run's. Nothing outside a mode's tokens or shape passes: a
# token mode gives 판정불가, a value mode 미상. No mode calls a gate function
# that writes a ledger row.
# ---------------------------------------------------------------------------
rk_gate() {
  local g="$RK_DIR/gate.sh" out='' mode="$1" a b c x
  [ -r "$g" ] && out=$(CC_GATE_SOURCE_ONLY=1 bash -c '
    g=$1; mode=$2; mf=$3; rid=$4; rd=$5; led=$6; gr=$7; err=$8
    shift 8
    a1=${1:-}; a2=${2:-}; a3=${3:-}; a4=${4:-}
    set --
    . "$g" >/dev/null 2>&1 || { printf "판정불가"; exit 0; }
    set +e
    unset CC_GATE_SOURCE_ONLY CC_ORCH_SOURCE_ONLY
    MANIFEST=$mf; RUN_ID=$rid; RUN_DIR=$rd; LEDGER=$led; GRANT=$gr
    case "${GATE_EXIT_RULE:-}" in ""|*[!0-9]*) printf "판정불가"; exit 0 ;; esac
    rc=0
    case "$mode" in
      ended)
        gate_run_ended_ok skill - 2>"$err" || rc=$?
        if [ "$rc" = "0" ]; then printf "안끝남"
        elif [ "$rc" = "$GATE_EXIT_RULE" ]; then printf "끝남"
        else printf "판정불가"; fi ;;
      grant)
        gate_check_grant 2>"$err" || rc=$?
        if [ "$rc" = "0" ]; then printf "통과"; else printf "실패"; fi ;;
      landed)
        if gate_landing_walk gate_adoption_row_landed <<ROWS
$( { grep -E "^- \`segment\` " "$led" 2>/dev/null || true; } | { grep -F "| id=$a1 |" || true; })
ROWS
        then printf "착지됨"; else printf "미착지"; fi ;;
      adopt-check)
        gate_adoption_check "$a1" "$a2" "$a3" 2>"$err" || rc=$?
        if [ "$rc" = "0" ]; then printf "통과"; exit 0; fi
        w=$(cat "$err" 2>/dev/null)
        case "$w" in
          *"의 출처 런 원장이 없습니다"*) printf "원장없음" ;;
          *"착지한 세그먼트는 입양하지 않습니다"*) printf "착지됨" ;;
          *"의 스테이지가 아직 살아 있습니다"*) printf "라이브" ;;
          *"체크아웃된 브랜치가"*) printf "브랜치다름" ;;
          *"의 워크트리가 없습니다"*|*"의 레포가 아닙니다"*) printf "워크트리없음" ;;
          *) printf "판정불가" ;;
        esac ;;
      halt-source)
        gate_adoption_halt_source "$a1" 2>"$err" || rc=$?
        case "$rc" in 0) printf "이월" ;; 1) printf "없음" ;; 2) printf "불가" ;; *) printf "판정불가" ;; esac ;;
      tip-of)
        gate_remote_tip_of "$a2" "$a3" "$a1" 2>"$err" ;;
      pr-of)
        gate_remote_pr_of "$a2" "$a3" "$a1" "$a4" 2>"$err" ;;
      pr-view)
        gh=$(gate_remote_gh)
        json=$(GH_PROMPT_DISABLED=1 "$gh" pr view "$a1" -R "$a2" \
                 --json state,headRefName,headRefOid,isCrossRepository,headRepositoryOwner,baseRefName 2>"$err") \
          || { printf "미상"; exit 0; }
        printf "%s" "$json" | jq -r "
          if type != \"object\" then \"미상\" else
            [ (.state // \"\" | tostring), (.headRefName // \"\" | tostring), (.headRefOid // \"\" | tostring),
              (.isCrossRepository | tostring),
              (.headRepositoryOwner | if type == \"object\" then (.login // \"\") else (. // \"\" | tostring) end),
              (.baseRefName // \"\" | tostring) ] | join(\"\t\")
          end" 2>/dev/null || printf "미상" ;;
    esac
  ' _ "$g" "$@" 2>/dev/null)
  case "$mode" in
    ended|grant)
      case "$out" in 끝남|안끝남|통과|실패) ;; *) out='판정불가' ;; esac ;;
    landed)
      case "$out" in 착지됨|미착지) ;; *) out='판정불가' ;; esac ;;
    adopt-check)
      case "$out" in 통과|라이브|워크트리없음|브랜치다름|원장없음|착지됨) ;; *) out='판정불가' ;; esac ;;
    halt-source)
      case "$out" in 이월|없음|불가) ;; *) out='판정불가' ;; esac ;;
    tip-of)
      case "$out" in 없음|미상) ;; *) rk_sha40 "$out" || out='미상' ;; esac ;;
    pr-of)
      IFS="$TAB" read -r a b c x <<EOF
$out
EOF
      if [ -n "$x" ]; then out="미상${TAB}미상${TAB}미상"
      elif [ "$a" = "$b" ] && [ "$b" = "$c" ] && { [ "$a" = 없음 ] || [ "$a" = 불일치 ] || [ "$a" = 미상 ]; }; then :
      elif rk_num "$a" && { [ "$b" = OPEN ] || [ "$b" = MERGED ]; } && rk_sha40 "$c"; then :
      else out="미상${TAB}미상${TAB}미상"; fi ;;
    pr-view)
      rk_prview_ok "$out" || out='미상' ;;
    *) out='판정불가' ;;
  esac
  printf '%s' "$out"
}

rk_num() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; return 0; }
rk_sha40() { case "$1" in ''|*[!0-9a-f]*) return 1 ;; esac; [ "${#1}" = "40" ]; }
# rk_prview_ok <line> — six TAB cells: a state word, a branch, a 40-hex head,
# true|false, an owner and a base branch, none empty and none with a space.
rk_prview_ok() {
  local s br h cr ow bs x
  case "$1" in *' '*|'') return 1 ;; esac
  IFS="$TAB" read -r s br h cr ow bs x <<EOF
$1
EOF
  [ -z "$x" ] && [ -n "$bs" ] && [ -n "$br" ] && [ -n "$ow" ] || return 1
  case "$s" in *[!A-Z]*) return 1 ;; esac
  rk_sha40 "$h" || return 1
  case "$cr" in true|false) return 0 ;; esac
  return 1
}

# rk_end_mark <stderr file> — the mark between the gate's fixed prefix and fixed
# suffix. The mark itself carries parentheses, so it is never cut at a bracket;
# a mark of several lines yields its first line.
rk_end_mark() {
  local line m pre='the run has already terminated (' suf=') — no new stage is launched'
  line=$(grep -F "$pre" "$1" 2>/dev/null | head -n 1)
  [ -n "$line" ] || return 0
  m=${line#*"$pre"}
  case "$m" in *"$suf"*) m=${m%"$suf"*} ;; esac
  printf '%s' "$m"
}

# rk_ledger_last <ledger> <series> <field> <value> — the last row of that
# series whose field is exactly that value.
rk_ledger_last() {
  local row hit=""
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    [ "$(manifest_row_fields "$row" "$3" | head -n 1)" = "$4" ] && hit=$row
  done <<EOF
$(grep -E "^- \`$2\`" "$1" 2>/dev/null || true)
EOF
  printf '%s' "$hit"
}

# rk_clause_states <ledger> — `<id><TAB><상태|-><TAB><근거>` for each `종료 절`
# id of the current MANIFEST, from the last ledger row of that id.
rk_clause_states() {
  local row cid last st ev
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    cid=$(manifest_row_fields "$row" 'id' | head -n 1)
    [ -n "$cid" ] || continue
    last=$(rk_ledger_last "$1" '종료 절' 'id' "$cid")
    st=$(manifest_row_fields "$last" '상태' | head -n 1)
    ev=$(manifest_row_fields "$last" '근거' | head -n 1)
    printf '%s\t%s\t%s\n' "$cid" "${st:--}" "$ev"
  done <<EOF
$(manifest_clause_rows_raw)
EOF
}

# ---------------------------------------------------------------------------
# Shared predicates — `detect` and `judge` ask the same functions, over the run
# RK_PREV / RK_BASE / MANIFEST name, so the two never disagree on a run.
# ---------------------------------------------------------------------------

# rk_is_live — 0 when any of the four predicates `gate_verb_end_abandoned`
# refuses on holds, so nothing judged adoptable here is refused by the close. A
# count that is not a number reads as alive: a run that cannot be shown idle is
# not taken over.
rk_is_live() {
  local nlive nwait
  nlive=$(cc_live_stages "$RK_PRD" 2>/dev/null)
  case "$nlive" in 0) ;; *) return 0 ;; esac
  nwait=$(cc_waiting_fresh_count "$RK_PRD" "$RK_PL" 2>/dev/null)
  case "$nwait" in 0) ;; *) return 0 ;; esac
  if cc_shift_is_live "$RK_PRD" 2>/dev/null; then return 0; fi
  if cc_relay_is_live "$RK_PRD" 2>/dev/null; then return 0; fi
  return 1
}

# rk_clauses_all_met <states> — 0 when the manifest declares at least one
# `종료 절` and the ledger left every one of them `충족`.
rk_clauses_all_met() {
  local nclause=0 nmet=0 cid cst cev
  while IFS="$TAB" read -r cid cst cev; do
    [ -n "$cid" ] || continue
    nclause=$((nclause + 1))
    [ "$cst" = "충족" ] && nmet=$((nmet + 1))
  done <<EOF
$1
EOF
  [ "$nclause" -ge 1 ] && [ "$nclause" = "$nmet" ]
}

# rk_invalidated <unresolved blocked> — 0 when a forced surface move left the
# run's run-scope block `무효화`.
rk_invalidated() {
  printf '%s\n' "$1" | awk -F '\t' '$1 == "무효화" && $2 == "강제 표면 이동" { f = 1 } END { exit !f }'
}

# rk_gate_ended <stderr file> — 끝남 | 안끝남 | 판정불가, the gate's own word.
rk_gate_ended() {
  rk_gate ended "$MANIFEST" "$RK_PREV" "$RK_PRD" "$RK_PL" "$RK_PG" "$1"
}

# ---------------------------------------------------------------------------
# Adoption — which unlanded segments of the previous run (RK_PREV / RK_BASE,
# MANIFEST its private copy, RK_PL its ledger, RK_PRD its run directory) the new
# run may adopt. One function decides, for `adopt`, `render-manifest`,
# `verify-subset` and, through its offline layer only, `detect`.
# ---------------------------------------------------------------------------

# rk_adopt_row <segment> <branch> <worktree> <PR> — the `세그먼트 입양` row,
# naming the previous run as its source.
rk_adopt_row() {
  printf -- '- `세그먼트 입양` | 세그먼트=%s | 브랜치=%s | 워크트리=%s | 출처 런=%s | PR=%s' "$1" "$2" "$3" "$RK_PREV" "$4"
}

# rk_adopt_take_label / rk_adopt_redo_label <segment> <PR> [<branch> <head>] —
# the two answers a person may give to the adoption question.
rk_adopt_take_label() { printf '이어받기 — %s · PR #%s · %s · %s' "$1" "$2" "$3" "$(printf '%s' "$4" | cut -c1-12)"; }
rk_adopt_redo_label() { printf '다시 하기 — %s · PR #%s' "$1" "$2"; }

# rk_ledger_seg_rows <key> — the ledger's `segment` rows of that id, in order.
rk_ledger_seg_rows() {
  { grep -E '^- `segment` ' "$RK_PL" 2>/dev/null || true; } | { grep -F "| id=$1 |" || true; }
}

# rk_rows_last_field <rows> <field> — the last non-empty value of that field.
rk_rows_last_field() {
  local row v hit=""
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    v=$(manifest_row_fields "$row" "$2" | head -n 1)
    [ -n "$v" ] && hit=$v
  done <<EOF
$1
EOF
  printf '%s' "$hit"
}

# rk_adopt_manifest <row> <out> — the current MANIFEST with every
# `세그먼트 입양` row removed and this one row written at the end of `## 인가`.
# A source that adopted the segment itself carries its own adoption row, and
# the gate reads the first row of a segment only, so the old one must go.
rk_adopt_manifest() {
  ( umask 077; RA_ROW="$1" awk '
      function put() { if (!done && sec == "## 인가") { print ENVIRON["RA_ROW"]; done = 1 } }
      /^- `세그먼트 입양`/ { next }
      /^## / { put(); for (i = 1; i <= nb; i++) print ""; nb = 0; sec = $0; print; next }
      /^$/ { nb++; next }
      { for (i = 1; i <= nb; i++) print ""; nb = 0; print }
      END { put(); for (i = 1; i <= nb; i++) print "" }
    ' "$MANIFEST" > "$2" ) 2>/dev/null || return 1
  chmod 600 "$2" 2>/dev/null
}

# rk_adopt_causes <key> — the cause cells of a parked segment: one
# `원인=<행 종류>:<줄>` per `blocked` row anchored on it, `중단 답` row
# answering `세그먼트 park` on it, and `자율 승인` row consuming a refusal on
# it, in ledger order; `원인=없음` when there is none.
rk_adopt_causes() {
  local out
  out=$(RC_K="$1" awk '
    function fld(name,   n, i, a, s) {
      n = split($0, a, / \| /)
      for (i = 2; i <= n; i++) { s = a[i]; sub(/[[:space:]]+$/, "", s); if (s == name) return 1 }
      return 0
    }
    index($0, "- `blocked` | ") == 1 && fld("앵커 세그먼트=" ENVIRON["RC_K"]) { printf "\t원인=blocked:%d", NR }
    index($0, "- `중단 답` | ") == 1 && fld("세그먼트=" ENVIRON["RC_K"]) && fld("선택지=세그먼트 park") { printf "\t원인=중단 답:%d", NR }
    index($0, "- `자율 승인` | ") == 1 && fld("세그먼트=" ENVIRON["RC_K"]) && fld("결정=거절 소비") { printf "\t원인=자율 승인:%d", NR }
  ' "$RK_PL" 2>/dev/null)
  [ -n "$out" ] || out="${TAB}원인=없음"
  printf '%s' "$out"
}

# rk_adopt_halts <key> — the previous run's unanswered halt records whose stage
# the ledger's `stage-result` rows put on this segment, comma-joined. A record
# whose stage no row names stays with the run-wide count only.
rk_adopt_halts() {
  local name stage seg hits="" rest
  rk_unanswered_halt_names "$RK_PRD" "$RK_PL"
  rest="$RK_HALT_LIST"
  while [ -n "$rest" ]; do
    name=${rest%%, *}
    case "$rest" in *', '*) rest=${rest#*, } ;; *) rest='' ;; esac
    case "$name" in shift/*|'') continue ;; esac
    stage=${name%.md}; stage=${stage%%#*}
    seg=$(rk_rows_last_field "$( { grep -E '^- `stage-result` ' "$RK_PL" 2>/dev/null || true; } | { grep -F "| 스테이지=$stage |" || true; })" '세그먼트')
    [ "$seg" = "$1" ] && hits="${hits:+$hits,}$name"
  done
  printf '%s' "$hits"
}

# rk_adopt_candidates <target rows> <full|offline> — one line per segment of the
# previous ledger the gate's landing walk finds unlanded:
#   입양후보<TAB><seg><TAB><B><TAB><W><TAB><PR><TAB><HEAD>[<TAB><꼬리>…]
#   입양불가<TAB><seg><TAB><PR|-><TAB><사유>
# `offline` reads the ledger only (conditions 3 and 4) and is what `detect`
# asks; `full` reads the graph values (G_DESIGN_OUT, G_DOC_SHA, G_PLAN, set
# before), the worktree and the remote too. The first condition that fails
# names the reason. RK_AUTO selects the seat's branch.
rk_adopt_candidates() {
  local trows="$1" layer="$2" key keys rows last W B anchor n h wh rt ph ab slug al row tal
  local cg tcg tbase cur hd st tip prl pn ps ph2 pv vs vb vh vc vo vbase tail tok mcopy err doc docf dcopy first pre halts
  keys=$( { grep -E '^- `segment` ' "$RK_PL" 2>/dev/null || true; } | while IFS= read -r row; do manifest_row_fields "$row" 'id' | head -n 1; printf '\n'; done | awk 'NF && !seen[$0]++')
  err="$RK_TMP/adopt.err"
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    [ "$(rk_gate landed "$MANIFEST" "$RK_PREV" "$RK_PRD" "$RK_PL" "$RK_PG" "$err" "$key")" = "미착지" ] || continue
    rows=$(rk_ledger_seg_rows "$key")
    last=$(printf '%s\n' "$rows" | tail -n 1)
    anchor=$( { grep -E '^- `원격 판독` ' "$RK_PL" 2>/dev/null || true; } | { grep -F "| 세그먼트=$key |" || true; } \
              | { grep -vF '| 원격 팁=미상 |' || true; } | tail -n 1)
    n=$(manifest_row_fields "$anchor" 'PR' | head -n 1)
    rk_num "$n" || n=$(rk_rows_last_field "$rows" 'PR')
    rk_num "$n" || n='-'
    tok=''
    # 1 — the seat does not adopt a segment it last parked.
    if [ "$layer" = "full" ] && [ "$RK_AUTO" = "1" ] && [ "$(manifest_row_fields "$last" '상태' | head -n 1)" = "park" ]; then
      tok='park'
    fi
    # 2 — the new run plans no design step, and the key is a slice of the frozen
    # document the graph measured (or the plan's implement step, with no
    # slicing section).
    if [ -z "$tok" ] && [ "$layer" = "full" ]; then
      if [ "$G_DESIGN_OUT" != "1" ]; then tok='설계재실행'
      else
        doc=$(manifest_field '요소' '설계 문서'); docf="$RK_BASE/$doc"
        dcopy=$(rk_copy "$docf" adopt-doc.md) || dcopy=''
        if [ -z "$dcopy" ] || [ "$(rk_sha "$dcopy")" != "$G_DOC_SHA" ]; then tok='설계재실행'
        elif grep -qxF '## 구현 슬라이싱' "$dcopy"; then
          slice_ids "$dcopy" | grep -qxF -- "$key" || tok='슬라이스다름'
        else
          first=$(printf '%s' "$G_PLAN" | jq -r '[.steps[]? | select(type == "object" and .skill == "implement") | .id // empty][0] // empty' 2>/dev/null)
          [ -n "$first" ] && [ "$first" = "$key" ] || tok='슬라이스다름'
        fi
      fi
    fi
    # 3 — the worktree and branch the segment's rows recorded.
    W=$(rk_rows_last_field "$rows" '워크트리')
    B=$(rk_rows_last_field "$rows" '브랜치')
    ab=$(manifest_row_fields "$anchor" '브랜치' | head -n 1)
    [ -n "$B" ] || B=$ab
    [ -n "$tok" ] || [ -n "$W" ] || tok='워크트리없음'
    # 4 — the anchor: the gate's last readable `원격 판독` row of that key.
    if [ -z "$tok" ]; then
      wh=$(manifest_row_fields "$anchor" '워크트리 HEAD' | head -n 1)
      rt=$(manifest_row_fields "$anchor" '원격 팁' | head -n 1)
      ph=$(manifest_row_fields "$anchor" 'PR HEAD' | head -n 1)
      if [ -z "$anchor" ] || ! rk_num "$(manifest_row_fields "$anchor" 'PR' | head -n 1)"; then tok='PR기록없음'
      elif [ "$(manifest_row_fields "$anchor" 'PR 상태' | head -n 1)" != "OPEN" ]; then tok='PR닫힘'
      elif ! rk_sha40 "$wh" || [ "$wh" != "$rt" ] || [ "$wh" != "$ph" ]; then tok='HEAD불일치'
      elif [ "$ab" != "$B" ]; then tok='브랜치다름'
      fi
    fi
    h=$wh
    if [ -n "$tok" ]; then printf '입양불가\t%s\t%s\t%s\n' "$key" "$n" "$tok"; continue; fi
    if [ "$layer" != "full" ]; then printf '입양후보\t%s\t%s\t%s\t%s\t%s\n' "$key" "$B" "$W" "$n" "$h"; continue; fi

    # 5 — the worktree belongs to the segment's target and has B checked out.
    slug=$(rk_rows_last_field "$rows" '레포')
    al=''; tcg=''; tbase=''
    while IFS= read -r row; do
      [ -n "$row" ] || continue
      [ -n "$slug" ] && [ "$(manifest_row_fields "$row" '원격 슬러그' | head -n 1)" = "$slug" ] || continue
      al=$(manifest_row_fields "$row" '별칭' | head -n 1)
      tcg=$(manifest_row_fields "$row" '공통 git 디렉터리' | head -n 1)
      tbase=$(manifest_row_fields "$row" '베이스 브랜치' | head -n 1)
      break
    done <<EOF
$trows
EOF
    cg=''; cur=''; hd=''; st=''
    if [ -d "$W" ]; then
      cg=$( { cd "$W" && git --no-optional-locks rev-parse --path-format=absolute --git-common-dir; } 2>/dev/null)
      cur=$( { cd "$W" && git --no-optional-locks symbolic-ref --quiet --short HEAD; } 2>/dev/null)
      hd=$( { cd "$W" && git --no-optional-locks rev-parse HEAD; } 2>/dev/null)
      st=$( { cd "$W" && git --no-optional-locks status --porcelain --untracked-files=all; } 2>/dev/null || printf '읽지 못함')
    fi
    if [ -z "$al" ] || [ ! -d "$W" ] || [ -z "$cg" ] || [ "$cg" != "$tcg" ]; then tok='워크트리없음'
    elif [ "$cur" != "$B" ]; then tok='브랜치다름'
    # 6 — its HEAD is the anchor's, and nothing is uncommitted.
    elif [ "$hd" != "$h" ]; then tok='HEAD불일치'
    elif [ -n "$st" ]; then tok='작업트리변경'
    fi
    # 7 — the remote tip of B.
    if [ -z "$tok" ]; then
      tip=$(rk_gate tip-of "$MANIFEST" "$RK_PREV" "$RK_PRD" "$RK_PL" "$RK_PG" "$err" "$W" "$slug" "$B")
      case "$tip" in
        미상) tok='PR판독불가' ;;
        "$h") ;;
        *) tok='HEAD불일치' ;;
      esac
    fi
    # 8 — the gate's pull request of B: one open, the anchor's number.
    if [ -z "$tok" ]; then
      prl=$(rk_gate pr-of "$MANIFEST" "$RK_PREV" "$RK_PRD" "$RK_PL" "$RK_PG" "$err" "$W" "$slug" "$B" "$h")
      IFS="$TAB" read -r pn ps ph2 <<EOF
$prl
EOF
      case "$pn" in
        미상) tok='PR판독불가' ;;
        불일치) tok='PR불일치' ;;
        없음) tok='PR닫힘' ;;
        *) if [ "$ps" = "MERGED" ]; then tok='PR닫힘'; elif [ "$pn" != "$n" ]; then tok='PR불일치'; fi ;;
      esac
    fi
    # 9 — the pull request itself: open, from the target's own repository, on
    # B at h, against the target's base branch.
    if [ -z "$tok" ]; then
      pv=$(rk_gate pr-view "$MANIFEST" "$RK_PREV" "$RK_PRD" "$RK_PL" "$RK_PG" "$err" "$n" "$slug")
      if [ "$pv" = "미상" ]; then tok='PR판독불가'
      else
        IFS="$TAB" read -r vs vb vh vc vo vbase <<EOF
$pv
EOF
        if [ "$vs" != "OPEN" ]; then tok='PR닫힘'
        elif [ "$vb" != "$B" ]; then tok='PR불일치'
        elif [ "$vh" != "$h" ]; then tok='HEAD불일치'
        elif [ "$vc" != "false" ] || [ "$vo" != "${slug%%/*}" ]; then tok='포크PR'
        elif [ "$vbase" != "$tbase" ]; then tok='베이스다름'
        fi
      fi
    fi
    # 10 — the landing walk again, then the gate's planning-time adoption check
    # on a private copy carrying this one adoption row.
    row=$(rk_adopt_row "$key" "$B" "$W" "$n")
    mcopy="$RK_TMP/adopt.$key.plan.md"
    if [ -z "$tok" ]; then
      case "$(rk_gate landed "$MANIFEST" "$RK_PREV" "$RK_PRD" "$RK_PL" "$RK_PG" "$err" "$key")" in
        미착지) ;;
        착지됨) tok='착지됨' ;;
        *) tok='판정불가' ;;
      esac
    fi
    if [ -z "$tok" ]; then
      rk_adopt_manifest "$row" "$mcopy" || tok='판정불가'
    fi
    if [ -z "$tok" ]; then
      tal=$(rk_gate adopt-check "$mcopy" "$RK_PREV" "$RK_PRD" "$RK_PL" "$RK_PG" "$err" "$key" "$al" "$row")
      [ "$tal" = "통과" ] || tok=$tal
    fi
    # 11 — the gate's halt-answer carry check on the same copy.
    tail=''
    if [ -z "$tok" ]; then
      case "$(rk_gate halt-source "$mcopy" "$RK_PREV" "$RK_PRD" "$RK_PL" "$RK_PG" "$err" "$key")" in
        불가) tok='중단답이월불가' ;;
        이월) tail="${TAB}이월=재수렴" ;;
        없음) ;;
        *) tok='판정불가' ;;
      esac
    fi
    rm -f "$mcopy"
    if [ -n "$tok" ]; then printf '입양불가\t%s\t%s\t%s\n' "$key" "$n" "$tok"; continue; fi
    pre=''
    if [ "$RK_AUTO" != "1" ] && [ "$(manifest_row_fields "$last" '상태' | head -n 1)" = "park" ]; then
      pre="${TAB}마지막행=park$(rk_adopt_causes "$key")"
    fi
    halts=$(rk_adopt_halts "$key")
    [ -z "$halts" ] || pre="${pre}${TAB}중단기록=$halts"
    printf '입양후보\t%s\t%s\t%s\t%s\t%s%s%s\n' "$key" "$B" "$W" "$n" "$h" "$pre" "$tail"
  done <<EOF
$keys
EOF
  return 0
}

# ---------------------------------------------------------------------------
# detect
# ---------------------------------------------------------------------------
rk_detect() {
  local sid="${CLAUDE_CODE_SESSION_ID:-}" idx id rd lp b kat e best_id="" best_e="" best_base=""
  printf 'cc-rekick v1\n'
  case "$sid" in ''|.|..|*/*) rk_detect_none ;; esac
  idx="${XDG_STATE_HOME:-$HOME/.local/state}/cc-cmds/session/$sid"
  [ -f "$idx" ] || rk_detect_none
  while IFS= read -r id; do
    rk_id_ok "$id" || continue
    rd=$(rundir_of_run_id "$id" 2>/dev/null) || continue
    [ -d "$rd" ] || continue
    grep -qxF -- "$sid" "$rd/session-lineage" 2>/dev/null || continue
    # The candidate's `<base>` is its ledger path's, and nothing else: a path of
    # any other shape, or none, leaves the latest run undecidable.
    lp=$(head -n 1 "$rd/ledger-path" 2>/dev/null) || lp=""
    case "$lp" in
      /*/docs/pipeline-run/"$id".md) b=${lp%/docs/pipeline-run/"$id".md} ;;
      *) rk_detect_none ;;
    esac
    [ -f "$b/docs/pipeline-run/$id.plan.md" ] || continue
    kat=$(MANIFEST="$b/docs/pipeline-run/$id.plan.md" manifest_field '런 정체' '킥오프 일시')
    e=$(rk_wide_instant "$kat")
    case "$e" in ''|*[!0-9-]*) rk_detect_none ;; esac
    if [ -z "$best_e" ] || [ "$e" -ge "$best_e" ]; then
      best_id=$id; best_e=$e; best_base=$b
    fi
  done <<EOF
$(awk '!seen[$0]++' "$idx" 2>/dev/null)
EOF
  [ -n "$best_id" ] || rk_detect_none
  RK_PREV=$best_id; RK_BASE=$best_base
  rk_prev_paths
  MANIFEST=$(rk_copy "$RK_PM" prev.plan.md) || rk_detect_none

  # The argument.
  local raw n t intent rekick_word=0
  raw=$(rk_trim "$RK_ARG")
  n=$(printf '%s' "$raw" | LC_ALL=C tr 'A-Z' 'a-z' | LC_ALL=C tr -d '[:punct:]')
  for t in '해 주세요' '해줘' '하자' 'please'; do
    case "$n" in *"$t") n=${n%"$t"}; break ;; esac
  done
  n=$(rk_trim "$n")
  intent=$(rk_trim "$(rk_intent)")
  case "$n" in
    다시|재킥오프|'다시 킥오프'|rekick|again|retry) rekick_word=1 ;;
    ''|이어서|재개|계속|resume) ;;
    *)
      if [ -z "$intent" ] || [ "$raw" != "$intent" ]; then
        printf '판정\t새 런\t%s\n' "$RK_PREV"
        printf '고지\t이 세션이 연 런(%s)과 다른 의도로 보고 새 런으로 시작합니다 — 이어받으려면 인자 없이 다시 부르세요\n' "$RK_PREV"
        exit 0
      fi ;;
  esac

  # Eligibility, in order; the first branch that applies decides.
  local ub inv=0 gate_tok mark err states
  if rk_is_live; then rk_detect_open running; fi

  # A run that met every termination clause is done, unless a segment it left
  # unmerged still has the open pull request its ledger recorded: that segment
  # is adopted by a re-kickoff and reviewed from its pull request, and the run
  # goes on to the eligibility below as an ended one would. The candidates are
  # the offline layer's, so this reads no network either.
  local done_adopt=0 dcands dkind dseg df3 df4 dn nadopt=0 adopt_segs=""
  states=$(rk_clause_states "$RK_PL")
  if rk_clauses_all_met "$states"; then
    dcands=$(rk_adopt_candidates "$(manifest_targets)" offline)
    while IFS="$TAB" read -r dkind dseg _; do
      [ "$dkind" = "입양후보" ] || continue
      nadopt=$((nadopt + 1)); adopt_segs="${adopt_segs:+$adopt_segs, }$dseg"
    done <<EOF
$dcands
EOF
    if [ "$nadopt" -eq 0 ]; then
      printf '판정\t완료\t%s\n' "$RK_PREV"
      printf '고지\t이전 런 %s 은 완료 기준을 모두 채웠습니다 — 이어받을 남은 단계가 없습니다\n' "$RK_PREV"
      while IFS="$TAB" read -r dkind dseg df3 df4 _; do
        [ "$dkind" = "입양불가" ] || continue
        dn=$df3; [ "$dn" != "-" ] || dn='없음'
        printf '고지\t이전 런의 머지되지 않은 작업(%s PR %s)은 이어받지 않습니다(%s) — 이어받으려면 의도를 적어 새 킥오프에서 입양하세요\n' "$dseg" "$dn" "$df4"
      done <<EOF
$dcands
EOF
      printf '고지\t이어받지 않고 처음부터 묻게 하려면 의도를 적어 다시 부르세요\n'
      exit 0
    fi
    done_adopt=1
  fi

  ub=$(cc_unresolved_blocked "$RK_PL" 2>/dev/null) || ub=""
  if rk_invalidated "$ub"; then inv=1; fi
  err="$RK_TMP/gate.err"
  if [ "$inv" = "0" ]; then
    gate_tok=$(rk_gate_ended "$err")
    case "$gate_tok" in
      끝남) ;;
      # Not ended and nothing alive: adopted on a re-kickoff word, and held for
      # resuming on any other argument, provided the ledger the causes are read
      # from is a regular file. Any other ledger, or a gate that could not
      # answer, is not a run this program can show to be idle.
      안끝남)
        if [ -f "$RK_PL" ] && [ -r "$RK_PL" ]; then
          if [ "$rekick_word" = "1" ]; then rk_detect_wait "$states"; fi
          rk_detect_held
        fi
        rk_detect_open stopped ;;
      *) rk_detect_open stopped ;;
    esac
    mark=$(rk_end_mark "$err")
  fi

  printf '판정\t재킥오프\t%s\t%s\n' "$RK_PREV" "$RK_BASE"
  if [ "$inv" = "1" ]; then printf '갈래\t강제 표면 이동 무효화\n'
  elif [ "$done_adopt" = "1" ]; then printf '갈래\t완료 런 입양\n'
  else printf '갈래\t게이트 종료\n'; fi
  printf '킥오프\t%s\n' "$(manifest_field '런 정체' '킥오프 일시')"
  if [ "$inv" = "1" ]; then
    printf '굵게\t이전 런 %s 은 집행 표면이 옮겨져 무효화됐습니다 — 그 런은 재개하지 않습니다\n' "$RK_PREV"
  else
    printf '종료 표시\t%s\n' "$mark"
    # The limit sentence only when a budget boundary ended the source: a run
    # ended by anything else would meet nothing that runs out again.
    local etok
    etok=$(rk_end_token "$RK_PL")
    if [ -z "$etok" ]; then
      case "$mark" in '벽시계 마감 경과'*) etok='마감' ;; esac
    fi
    if [ "$done_adopt" = "1" ]; then
      printf '굵게\t이전 런 %s 은 완료 기준을 모두 채웠습니다 — 머지되지 않은 세그먼트 %s건(%s)을 열린 PR 과 함께 이어받아 그 PR 의 리뷰부터 다시 시작합니다\n' \
        "$RK_PREV" "$nadopt" "$adopt_segs"
    elif rk_budget_token "$etok"; then
      printf '굵게\t이전 런 %s 을 끝낸 경계는 같은 값으로 다시 주어집니다 (%s) — 같은 한도가 다시 바닥날 수 있습니다\n' "$RK_PREV" "$mark"
    else
      printf '굵게\t이전 런 %s 을 끝낸 경계는 같은 값으로 다시 주어집니다 (%s)\n' "$RK_PREV" "$mark"
    fi
    # An approval the source left waiting is listed, never closed or moved: the
    # answer belongs to the source's tree.
    rk_open_approvals "$RK_PL"
    [ "$RK_AP_N" -eq 0 ] || printf '굵게\t이전 런 %s 의 열린 승인 %s건(%s)은 닫거나 옮기지 않습니다 — 그 답은 원천 런에 남고, 이 새 런이 같은 자리에 이르면 다시 묻습니다\n' \
      "$RK_PREV" "$RK_AP_N" "$RK_AP_LIST"
    rk_deferred_halt_names "$RK_PL"
    rk_deferred_line 고지
    # An `이월` row is a block too, but what it holds comes over: it is named
    # above, never among the parks that do not.
    local parks np=0 why reasons=""
    parks=$(printf '%s\n' "$ub" | awk -F '\t' 'NF >= 2 && $2 != "" && index($2, "중단 답 이월 — ") != 1 { print $2 }')
    while IFS= read -r why; do
      [ -n "$why" ] || continue
      np=$((np + 1)); reasons="${reasons:+$reasons, }$why"
    done <<EOF
$parks
EOF
    if [ "$np" -gt 0 ]; then
      printf '굵게\t이전 런 %s 은 시스템이 끝냈습니다 (%s) — 남은 정박 %s건(%s)은 넘어오지 않고, 이 새 런이 해당 단계를 처음부터 다시 만납니다\n' \
        "$RK_PREV" "$mark" "$np" "$reasons"
    fi
  fi
  rk_clause_lines "$states"
  rk_detect_tail
}

# rk_clause_lines <states> — the `굵게` lines for termination clauses the source
# left `불가능` or `보류`.
rk_clause_lines() {
  local cid cst cev imp_ids="" imp_ev="" hold_ids=""
  while IFS="$TAB" read -r cid cst cev; do
    [ -n "$cid" ] || continue
    case "$cst" in
      불가능) imp_ids="${imp_ids:+$imp_ids, }$cid"; imp_ev="${imp_ev:+$imp_ev; }${cev%%\\n*}" ;;
      보류)   hold_ids="${hold_ids:+$hold_ids, }$cid" ;;
    esac
  done <<EOF
$1
EOF
  [ -z "$imp_ids" ] || printf '굵게\t이전 런 %s 은 종료 절 %s 를 불가능으로 끝냈습니다(%s) — 같은 조건이면 이 새 런도 같은 곳에서 멈출 수 있습니다\n' \
    "$RK_PREV" "$imp_ids" "$imp_ev"
  [ -z "$hold_ids" ] || printf '굵게\t이전 런 %s 의 종료 절 %s 는 보류(사람의 답 대기)로 끝났습니다 — 그 답은 이어받지 않으며 이 새 런이 다시 묻습니다\n' \
    "$RK_PREV" "$hold_ids"
  return 0
}

# rk_detect_tail — the unlanded-work notice and the way out, then exit 0. Every
# adopting verdict ends with these two lines.
rk_detect_tail() {
  # One line per segment the gate's landing walk finds unlanded, from the
  # ledger alone: no network is read here, so a segment passing these
  # conditions is only a candidate the re-kickoff reads again.
  local kind seg f3 f4 f5 n
  while IFS="$TAB" read -r kind seg f3 f4 f5 _; do
    case "$kind" in
      입양후보)
        printf '고지\t이전 런의 머지되지 않은 작업(%s PR %s)은 입양 후보입니다 — 재킥오프가 디스크와 원격을 다시 확인합니다\n' "$seg" "$f5" ;;
      입양불가)
        n=$f3; [ "$n" != "-" ] || n='없음'
        printf '고지\t이전 런의 머지되지 않은 작업(%s PR %s)은 이어받지 않습니다(%s) — 새 런이 그 세그먼트를 다시 하고 옛 PR 은 그대로 둡니다\n' "$seg" "$n" "$f4" ;;
    esac
  done <<EOF
$(rk_adopt_candidates "$(manifest_targets)" offline)
EOF
  printf '고지\t이어받지 않고 처음부터 묻게 하려면 의도를 적어 다시 부르세요\n'
  exit 0
}

rk_detect_none() {
  printf '판정\t없음\n'
  printf '고지\t이 세션이 연 런을 찾지 못했습니다 — 처음 킥오프처럼 묻습니다\n'
  exit 0
}

# rk_detect_open <running|stopped> — the `진행 중` verdict: shown, not adopted.
# `running` is a run with something alive in it; `stopped` is one the gate could
# not answer for, or whose ledger is not a regular file.
rk_detect_open() {
  printf '판정\t진행 중\t%s\n' "$RK_PREV"
  if [ "$1" = "running" ]; then
    printf '고지\t이전 런 %s 은 아직 돌고 있습니다\n' "$RK_PREV"
  else
    printf '고지\t이전 런 %s 은 멈춰 있지만 게이트에서 종료 여부를 판정하지 못했습니다 — 그 런을 재개해 끝내면 다음 호출에서 이어받습니다. 지금 처음부터 시작하려면 의도를 적어 부르세요\n' "$RK_PREV"
  fi
  # A resume command a still-open block left is quoted verbatim, after the
  # sentence that names both ways out.
  rk_resume_quotes
  exit 0
}

# rk_detect_held — the `진행 중` verdict for a run `rk_detect_wait` would adopt,
# called with an argument that is not a re-kickoff word: what it waits on is
# named, nothing is adopted, and the way to adopt it is said.
rk_detect_held() {
  local cause
  rk_open_approvals "$RK_PL"
  rk_unanswered_halt_names "$RK_PRD" "$RK_PL"
  cause=$(rk_wait_cause "$RK_PL")
  printf '판정\t진행 중\t%s\n' "$RK_PREV"
  printf '대기 원인\t%s\n' "$cause"
  printf '고지\t이전 런 %s 은 끝나지 않은 채 멈춰 있습니다(%s) — 이 호출은 재개로 보고 이어받지 않습니다. 그 런을 재개해 끝내거나, 새 런이 이어받고 원천을 이어받음으로 닫게 하려면 인자 「다시」 로 부르세요\n' "$RK_PREV" "$cause"
  [ "$RK_AP_N" -eq 0 ] || printf '고지\t이전 런 %s 의 열린 승인 %s건(%s)에 답하면 그 런이 이어집니다\n' \
    "$RK_PREV" "$RK_AP_N" "$RK_AP_LIST"
  [ "$RK_HALT_N" -eq 0 ] || printf '고지\t이전 런 %s 의 답 없는 정지 기록 %s건(%s)에 답하면 그 런이 이어집니다\n' \
    "$RK_PREV" "$RK_HALT_N" "$RK_HALT_LIST"
  # The carried-over answers are named for the adoption the way out offers.
  rk_deferred_halt_names "$RK_PL"
  rk_deferred_line 고지
  rk_resume_quotes
  exit 0
}

# rk_detect_wait <states> — the `대기` verdict: a run the gate has not ended,
# with nothing alive in it. The re-kickoff adopts it and closes it `이어받음`;
# nothing of it is carried, so what it waits on is named and left where it is.
rk_detect_wait() {
  local cause
  rk_open_approvals "$RK_PL"
  rk_unanswered_halt_names "$RK_PRD" "$RK_PL"
  cause=$(rk_wait_cause "$RK_PL")
  printf '판정\t대기\t%s\t%s\n' "$RK_PREV" "$RK_BASE"
  printf '갈래\t대기 이어받기\n'
  printf '대기 원인\t%s\n' "$cause"
  printf '킥오프\t%s\n' "$(manifest_field '런 정체' '킥오프 일시')"
  printf '굵게\t이전 런 %s 은 끝나지 않은 채 멈춰 있습니다(%s) — 이 새 런이 이어받고, 원천 런은 이어받음으로 닫습니다\n' "$RK_PREV" "$cause"
  case "$cause" in
    '한도 대기')
      printf '굵게\t이전 런 %s 은 사용 한도를 기다리며 멈췄습니다 — 같은 한도가 다시 바닥날 수 있습니다\n' "$RK_PREV" ;;
    무기록)
      printf '굵게\t이전 런 %s 의 마지막 교대가 인계 없이 끝났습니다 — 그 교대가 하던 일은 이 새 런이 처음부터 다시 만납니다\n' "$RK_PREV" ;;
    멈춤)
      if rk_last_handoff_waited "$RK_PL"; then
        printf '굵게\t이전 런 %s 의 마지막 교대는 스테이지·CI 결과를 기다리며 끝났고, 그 대기를 이어 갈 중계가 없습니다 — 남은 단계는 이 새 런이 이어 갑니다\n' "$RK_PREV"
      else
        printf '굵게\t이전 런 %s 은 기다리는 것 없이 멈췄습니다 — 남은 단계는 이 새 런이 이어 갑니다\n' "$RK_PREV"
      fi ;;
  esac
  [ "$RK_AP_N" -eq 0 ] || printf '굵게\t이전 런 %s 의 열린 승인 %s건(%s)은 옮기지 않습니다 — 그 답은 원천 런에 남고, 이 새 런이 같은 자리에 이르면 다시 묻습니다\n' \
    "$RK_PREV" "$RK_AP_N" "$RK_AP_LIST"
  [ "$RK_HALT_N" -eq 0 ] || printf '굵게\t이전 런 %s 의 답 없는 정지 기록 %s건(%s)은 옮기지 않습니다 — 그 기록은 원천 런에 남고, 이 새 런이 같은 자리에 이르면 다시 묻습니다\n' \
    "$RK_PREV" "$RK_HALT_N" "$RK_HALT_LIST"
  rk_deferred_halt_names "$RK_PL"
  rk_deferred_line 고지
  rk_clause_lines "$1"
  rk_resume_quotes
  rk_detect_tail
}

# rk_resume_quotes — one `고지` line per distinct resume command an unresolved
# block of the source left, verbatim.
rk_resume_quotes() {
  local ub cmds="" cmd why last
  ub=$(cc_unresolved_blocked "$RK_PL" 2>/dev/null) || ub=""
  while IFS="$TAB" read -r _ why; do
    [ -n "$why" ] || continue
    last=$(rk_ledger_last "$RK_PL" blocked '사유' "$why")
    cmd=$(manifest_row_fields "$last" '재개 명령' | tail -n 1)
    case "$cmd" in ''|'(없음)') continue ;; esac
    case "$cmds" in *"$TAB$cmd$TAB"*) continue ;; esac
    cmds="$cmds$TAB$cmd$TAB"
    printf '고지\t(이전 런이 남긴 재개 명령: %s)\n' "$cmd"
  done <<EOF
$ub
EOF
  return 0
}

# rk_open_approvals <ledger> — sets RK_AP_N and RK_AP_LIST: how many approvals
# still wait, and each one's question text (its id when the row has none), read
# off that id's last `승인` row.
rk_open_approvals() {
  local ap aid acut last q
  RK_AP_N=0; RK_AP_LIST=""
  ap=$(cc_open_approval_rows "$1" 2>/dev/null) || ap=""
  while IFS="$TAB" read -r aid acut; do
    [ -n "$aid" ] || continue
    RK_AP_N=$((RK_AP_N + 1))
    last=$( { grep -E '^- `승인`' "$1" 2>/dev/null | grep -F "| 승인 id=$aid |" || true; } | tail -n 1)
    q=$(manifest_row_fields "$last" '질문 문면' | tail -n 1)
    RK_AP_LIST="${RK_AP_LIST:+$RK_AP_LIST, }${q:-$aid}"
  done <<EOF
$ap
EOF
  return 0
}

# rk_unanswered_halt_names <run dir> <ledger> — sets RK_HALT_N and RK_HALT_LIST:
# the halt records no `중단 답` row names, or whose answer was returned to a
# person, by their name under `halt/`. The selection is `cc_unanswered_halts`'s
# — answer attachments skipped, `halt/shift/` scanned, the `중단 기록=` field
# matched on its tail from the run directory's name down, and the answered
# test `cc_halt_answered` itself — so the count here is that function's.
rk_unanswered_halt_names() {
  local rd="${1%/}" led="$2" f name rel tail
  RK_HALT_N=0; RK_HALT_LIST=""
  [ -n "$rd" ] && [ -d "$rd/halt" ] || return 0
  for f in "$rd"/halt/*.md "$rd"/halt/shift/*.md; do
    [ -f "$f" ] || continue
    case "$f" in *.answer.md) continue ;; esac
    name=${f##*/}
    case "$f" in
      "$rd"/halt/shift/*) rel="shift/$name" ;;
      *) rel="$name" ;;
    esac
    tail="/${rd##*/}/halt/$rel"
    if [ -n "$led" ] && cc_halt_answered "$led" "$tail"; then
      continue
    fi
    RK_HALT_N=$((RK_HALT_N + 1))
    RK_HALT_LIST="${RK_HALT_LIST:+$RK_HALT_LIST, }$rel"
  done
  return 0
}

# rk_deferred_halt_names <ledger> — sets RK_DEF_N and RK_DEF_LIST: the answers
# the source carried over to the next run, one per `중단 답` line an `이월` row
# (`blocked` with `사유=중단 답 이월 — …`) names, as `<record under halt/>:
# <option>`. These are answered records, so `rk_unanswered_halt_names` does not
# count them and the wait cause never reads them as waiting on a person: the
# follow-up run brings each one in the first time it dispatches that step, and
# its routing shift hands it on with a carry act instead of asking again.
rk_deferred_halt_names() {
  local led="$1" r ln row rec opt seen=" "
  RK_DEF_N=0; RK_DEF_LIST=""
  [ -f "$led" ] || return 0
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    ln=$(manifest_row_fields "$r" '중단 답 줄' | tail -n 1)
    rk_num "$ln" || continue
    case "$seen" in *" $ln "*) continue ;; esac
    seen="$seen$ln "
    row=$(sed -n "${ln}p" "$led")
    case "$row" in '- `중단 답` '*) ;; *) continue ;; esac
    rec=$(manifest_row_fields "$row" '중단 기록' | tail -n 1)
    opt=$(manifest_row_fields "$row" '선택지' | tail -n 1)
    RK_DEF_N=$((RK_DEF_N + 1))
    RK_DEF_LIST="${RK_DEF_LIST:+$RK_DEF_LIST, }${rec##*/halt/}: ${opt:--}"
  done <<EOF
$( { grep '^- `blocked` ' "$led" 2>/dev/null || true; } | { grep -F '| 사유=중단 답 이월 — ' || true; })
EOF
  return 0
}

# rk_deferred_line <kind> — the line naming the source's carried-over answers,
# after `rk_deferred_halt_names`; nothing when there are none.
rk_deferred_line() {
  [ "$RK_DEF_N" -eq 0 ] || printf '%s\t이전 런 %s 의 이월된 중단 답 %s건(%s)은 이 새 런이 같은 스텝을 처음 파견할 때 운반으로 이어받습니다 — 다시 묻지 않습니다\n' \
    "$1" "$RK_PREV" "$RK_DEF_N" "$RK_DEF_LIST"
}

# rk_wait_cause <ledger> — what an un-ended quiet run waits on, the first that
# holds: an open approval, an unanswered halt record (RK_AP_N and RK_HALT_N are
# set before), a usage limit, a shift lost without a handoff, nothing. Rows are
# compared on whole fields between ` | ` separators, never as substrings.
#
# A usage limit is read only off a stage cut by it — the last `stage-result`
# whose `종단 부류` is `한도 종료` or `한도-형상 회수` with no `한도 해제` or
# `교대 기동` row after it. A `handoff 사유=대기` is not one: a shift writes it
# when all that is left is a live stage's result or a CI verdict, so a run idle
# after it waited on those, never on a limit.
rk_wait_cause() {
  if [ "$RK_AP_N" -gt 0 ]; then printf '승인 대기'; return 0; fi
  if [ "$RK_HALT_N" -gt 0 ]; then printf '사람 대기'; return 0; fi
  awk '
    function fld(name,   i, s) {
      for (i = 2; i <= nf; i++) {
        s = f[i]; sub(/[[:space:]]+$/, "", s)
        if (index(s, name "=") == 1) return substr(s, length(name) + 2)
      }
      return ""
    }
    { nf = split($0, f, / \| /) }
    index($0, "- `handoff` | ") == 1      { lh = NR; lhw = fld("사유") }
    index($0, "- `stage-result` | ") == 1 { ls = NR; lsk = fld("종단 부류") }
    index($0, "- `한도 해제` | ") == 1 || index($0, "- `교대 기동` | ") == 1 { lr = NR }
    END {
      if (ls && (lsk == "한도 종료" || lsk == "한도-형상 회수") && lr < ls) { printf "한도 대기"; exit }
      if (lh && lhw == "무기록") { printf "무기록"; exit }
      printf "멈춤"
    }' "$1" 2>/dev/null || printf '멈춤'
}

# rk_last_handoff_waited <ledger> — succeeds when the ledger's last `handoff`
# carries `사유=대기` or `사유=이월` as a whole field. `이월` waits too: the
# seat call's relay holds it until one second past the deadline, and the shift
# it then launches ends the run.
rk_last_handoff_waited() {
  awk '
    index($0, "- `handoff` | ") == 1 {
      w = 0; n = split($0, f, / \| /)
      for (i = 2; i <= n; i++) { s = f[i]; sub(/[[:space:]]+$/, "", s); if (s == "사유=대기" || s == "사유=이월") w = 1 }
    }
    END { exit !w }' "$1" 2>/dev/null
}

# rk_end_token <ledger> — the end token the gate reads: `재킥 원인` of the first
# ending row (`자율 승인` with `결정=종료`) or run-scope `blocked` row, skipping
# the two causes that park a slice and do not end the run. The selection is
# `gate_end_token_row`'s; the earliest row wins, as there.
rk_end_token() {
  awk '
    (index($0, "- `자율 승인` | ") == 1 && index($0, " | 결정=종료 | ") > 0) ||
    (index($0, "- `blocked` | ") == 1 && index($0, " | 스코프=run | ") > 0) {
      blk = (index($0, "- `blocked` | ") == 1)
      n = split($0, f, / \| /)
      for (i = 2; i <= n; i++) {
        if (index(f[i], "재킥 원인=") == 1) {
          v = f[i]; sub(/^재킥 원인=/, "", v); sub(/[[:space:]]+$/, "", v)
          if (blk && (v == "대상미선언" || v == "슬라이싱")) break
          print v; exit
        }
      }
    }' "$1" 2>/dev/null || true
}

# rk_end_row <ledger> — `<재킥 원인><TAB><종료 부류>` of the row rk_end_token
# reads, each empty when absent. The selection is rk_end_token's, line for line.
rk_end_row() {
  awk '
    (index($0, "- `자율 승인` | ") == 1 && index($0, " | 결정=종료 | ") > 0) ||
    (index($0, "- `blocked` | ") == 1 && index($0, " | 스코프=run | ") > 0) {
      blk = (index($0, "- `blocked` | ") == 1)
      n = split($0, f, / \| /); v = ""; k = ""; hit = 0
      for (i = 2; i <= n; i++) {
        s = f[i]; sub(/[[:space:]]+$/, "", s)
        if (index(s, "재킥 원인=") == 1) { v = substr(s, length("재킥 원인=") + 1); hit = 1 }
        else if (index(s, "종료 부류=") == 1) k = substr(s, length("종료 부류=") + 1)
      }
      if (!hit) next
      if (blk && (v == "대상미선언" || v == "슬라이싱")) next
      printf "%s\t%s\n", v, k; exit
    }' "$1" 2>/dev/null || true
}

# rk_progress_rows <ledger> — the rows that show a run moved: a `종료 절` met, a
# segment merged or done, any `cycle`, and a normal completion of a design or
# design-audit stage. A row carrying `출처=` is a copy from elsewhere and does
# not count.
rk_progress_rows() {
  grep -E '^- `(종료 절|segment|cycle|stage-result)` \| ' "$1" 2>/dev/null \
    | grep -v ' | 출처=' \
    | awk '
        index($0, "- `종료 절` | ") == 1 { if ($0 ~ / \| 상태=충족( \||$)/) print; next }
        index($0, "- `segment` | ") == 1 { if ($0 ~ / \| 상태=(머지됨|완료)( \||$)/) print; next }
        index($0, "- `cycle` | ") == 1 { print; next }
        index($0, "- `stage-result` | ") == 1 {
          if ($0 ~ / \| 종단 부류=정상 완료( \||$)/ &&
              $0 ~ / \| (스테이지=(S1design|S2)|종류=(design|design-audit))( \||$)/) print
          next
        }' || true
}

# rk_chain <source manifest> <source ledger> <source id> — the seat chain the
# next link would carry. Sets RK_CH_K (the next link's count, empty when the
# source's provenance row is malformed), RK_CH_ROOT, RK_CH_CAUSE (the source's
# end token), RK_CH_PREVCAUSE (the `원인=` the source's own row carries, if
# any), RK_CH_CAP (`연쇄 상한` of the consent row, empty without one) and
# RK_CH_WHY (why the provenance row could not be read).
#
# A source without a provenance row, or with the four-field row a person's
# re-kickoff writes, starts the count: the next link is 1. A seven-field row
# carries the count on.
rk_chain() {
  local mf="$1" led="$2" sid="$3" rows n row rk
  RK_CH_K=""; RK_CH_ROOT="$sid"; RK_CH_CAUSE=""; RK_CH_PREVCAUSE=""; RK_CH_CAP=""; RK_CH_WHY=""
  RK_CH_CAUSE=$(rk_end_token "$led")
  rk=$(MANIFEST="$mf" manifest_rekick_rows | head -n 1)
  [ -z "$rk" ] || RK_CH_CAP=$(manifest_row_fields "$rk" '연쇄 상한' | head -n 1)
  case "$RK_CH_CAP" in ''|*[!0-9]*) RK_CH_CAP="" ;; esac
  rows=$(MANIFEST="$mf" rk_carry_rows)
  n=$(printf '%s' "$rows" | grep -c . || true)
  case "${n:-0}" in
    0) RK_CH_K=1; return 0 ;;
    1) row=$rows ;;
    *) RK_CH_WHY="원천 출처 행이 ${n}개입니다"; return 0 ;;
  esac
  local out
  out=$(printf '%s\n' "$row" | awk '
    function hex(v) { return v ~ /^[0-9a-f]+$/ && length(v) == 64 }
    function idok(v) { return v ~ /^[A-Za-z0-9._-]+$/ && v != "." && v != ".." }
    {
      n = split($0, f, / \| /)
      if (n != 4 && n != 7) { print "bad\t출처 행의 필드 수가 맞지 않습니다"; exit }
      if (f[1] != "- `사전 인가`") { print "bad\t출처 행의 머리가 다릅니다"; exit }
      split("이어받은 런,매니페스트 sha256,인가 기록 sha256,좌석 연쇄,뿌리 런,원인", want, ",")
      for (i = 2; i <= n; i++) {
        p = index(f[i], "=")
        if (p == 0 || substr(f[i], 1, p - 1) != want[i - 1]) { print "bad\t출처 행의 필드 이름이나 순서가 다릅니다"; exit }
        v[i - 1] = substr(f[i], p + 1)
      }
      if (!idok(v[1]) || !hex(v[2]) || !hex(v[3])) { print "bad\t출처 행의 런 id 나 해시가 형식에 맞지 않습니다"; exit }
      if (n == 4) { print "ok\t0\t\t"; exit }
      if (v[4] !~ /^[1-9][0-9]*$/) { print "bad\t출처 행의 좌석 연쇄가 양의 정수가 아닙니다"; exit }
      if (!idok(v[5])) { print "bad\t출처 행의 뿌리 런이 런 id 가 아닙니다"; exit }
      if (v[6] == "" || v[6] ~ /[ \t]/) { print "bad\t출처 행의 원인이 비었거나 형식에 맞지 않습니다"; exit }
      printf "ok\t%s\t%s\t%s\n", v[4], v[5], v[6]
    }')
  case "$out" in
    ok"$TAB"*)
      local seat root pc
      IFS="$TAB" read -r _ seat root pc <<EOF
$out
EOF
      RK_CH_K=$((seat + 1))
      [ -z "$root" ] || RK_CH_ROOT=$root
      RK_CH_PREVCAUSE=$pc ;;
    *) RK_CH_WHY=${out#bad"$TAB"} ;;
  esac
  [ -n "$RK_CH_K" ] || [ -n "$RK_CH_WHY" ] || RK_CH_WHY="출처 행을 읽지 못했습니다"
  return 0
}

# rk_seat_token <token> — succeeds for the end tokens a seat may carry on: the
# budget a new link is handed again.
rk_seat_token() {
  case "$1" in 마감|천장|무진전) return 0 ;; esac
  return 1
}

# ---------------------------------------------------------------------------
# judge — the seat's verdict on the run it just saw end. Every prohibition is
# evaluated and printed; nothing is written and nothing is asked.
# ---------------------------------------------------------------------------
rk_judge() {
  local sid="${CLAUDE_CODE_SESSION_ID:-}" lines="" waits="" ub gate_tok states
  local endrow etok ekind nprog nclause=0 nmet=0 cid cst cev remain
  rk_prev_paths
  MANIFEST=$(rk_copy "$RK_PM" prev.plan.md) || rk_fail "원천 매니페스트를 읽을 수 없습니다: $RK_PM"
  rk_fire() { lines="${lines}금지선${TAB}$1${TAB}$2
"; }

  # L14 — the run belongs to this session's lineage.
  if [ -z "$sid" ] || [ -z "$RK_PRD" ] || ! grep -qxF -- "$sid" "$RK_PRD/session-lineage" 2>/dev/null; then
    rk_fire L14 "이 세션은 원천 런 $RK_PREV 의 계보에 없습니다"
  fi

  # L1 — the run ended. An invalidated run is L10's, not this line's.
  ub=$(cc_unresolved_blocked "$RK_PL" 2>/dev/null) || ub=""
  if rk_is_live; then
    rk_fire L1 "원천 런 $RK_PREV 은 아직 살아 있습니다"
  elif ! rk_invalidated "$ub"; then
    gate_tok=$(rk_gate_ended "$RK_TMP/judge-gate.err")
    case "$gate_tok" in
      끝남) ;;
      안끝남) rk_fire L1 "원천 런 $RK_PREV 은 게이트가 끝내지 않았습니다 (보류·대기)" ;;
      *) rk_fire L1 "원천 런 $RK_PREV 의 종료를 게이트에서 판정하지 못했습니다" ;;
    esac
  fi

  # L2 — the run completed.
  endrow=$(rk_end_row "$RK_PL")
  etok=${endrow%%"$TAB"*}; ekind=${endrow#*"$TAB"}
  [ -n "$endrow" ] || { etok=""; ekind=""; }
  states=$(rk_clause_states "$RK_PL")
  while IFS="$TAB" read -r cid cst cev; do
    [ -n "$cid" ] || continue
    nclause=$((nclause + 1))
    [ "$cst" = "충족" ] && nmet=$((nmet + 1))
  done <<EOF
$states
EOF
  if rk_clauses_all_met "$states"; then
    rk_fire L2 "원천 런 $RK_PREV 은 종료 절을 모두 채웠습니다"
  elif [ "$etok" = "해당없음" ] && [ "$ekind" = "완료" ]; then
    rk_fire L2 "원천 런 $RK_PREV 은 정상 완료로 끝났습니다"
  fi

  # L3 — a person gave it up, or another run took it over.
  case "$ekind" in
    포기|이어받음) rk_fire L3 "원천 런 $RK_PREV 의 종료 부류가 $ekind 입니다" ;;
  esac

  # L5 — nothing the source still waits on.
  rk_open_approvals "$RK_PL"
  rk_unanswered_halt_names "$RK_PRD" "$RK_PL"
  if [ "$RK_AP_N" -gt 0 ] || [ "$RK_HALT_N" -gt 0 ]; then
    rk_fire L5 "원천 런 $RK_PREV 에 열린 승인 ${RK_AP_N}건·답 없는 중단 기록 ${RK_HALT_N}건이 있습니다"
  fi

  # L6 · L7 — the chain's count against the consent row's cap, and the row.
  rk_chain "$MANIFEST" "$RK_PL" "$RK_PREV"
  if [ -n "$RK_CH_WHY" ]; then
    rk_fire L6 "연쇄 수를 낼 수 없습니다 — $RK_CH_WHY"
  elif [ -n "$RK_CH_CAP" ] && [ "$RK_CH_K" -gt "$RK_CH_CAP" ]; then
    rk_fire L6 "좌석 연쇄 $RK_CH_K 가 연쇄 상한 $RK_CH_CAP 을 넘습니다"
  fi
  [ -n "$(manifest_rekick_rows)" ] || rk_fire L7 "원천 매니페스트에 재킥오프 동의 행이 없습니다"

  # L9 — a budget end with nothing moved.
  nprog=$(rk_progress_rows "$RK_PL" | grep -c . || true)
  if rk_seat_token "$etok" && [ "${nprog:-0}" = "0" ]; then
    rk_fire L9 "원천 런 $RK_PREV 은 $etok 로 끝났지만 진전 행이 없습니다"
  fi

  # L15 — no progress twice in a row inside the seat chain.
  if [ "$etok" = "무진전" ] && [ "$RK_CH_PREVCAUSE" = "무진전" ]; then
    rk_fire L15 "좌석 연쇄 안에서 무진전이 두 번 연속입니다"
  fi

  # L10 · L11 — the end token.
  if [ "$etok" = "표면이동" ] || rk_invalidated "$ub"; then
    rk_fire L10 "원천 런 $RK_PREV 은 집행 표면 이동으로 끝났습니다"
  elif ! rk_seat_token "$etok"; then
    if [ "$etok" = "해당없음" ] && [ "$ekind" = "완료" ]; then :
    else rk_fire L11 "종료 토큰 '${etok:-}' 은 좌석이 이어 가는 끝(마감·천장·무진전)이 아닙니다"; fi
  fi

  # L12 — the source's frozen files, through `verify`. Its two questions are
  # the only waits.
  ( rk_verify ) > "$RK_TMP/judge-verify.out" 2>/dev/null
  if awk -F '\t' '$1 == "판정" && $2 == "실패" { f = 1 } END { exit !f }' "$RK_TMP/judge-verify.out"; then
    rk_fire L12 "verify 가 실패했습니다 ($(awk -F '\t' '$1 == "판정" { print $3; exit }' "$RK_TMP/judge-verify.out"))"
  elif ! grep -q "^판정${TAB}통과" "$RK_TMP/judge-verify.out"; then
    rk_fire L12 "verify 의 판정을 읽지 못했습니다"
  fi
  local qk qkind qa qb qc qd
  while IFS="$TAB" read -r qk qkind qa qb qc qd; do
    [ "$qk" = "질문" ] || continue
    case "$qkind" in
      베이스설계)
        rk_judge_asked '7.8' && continue
        waits="${waits}대기${TAB}베이스설계${TAB}7.8${TAB}베이스 설계 문서 $qa 이 원천을 얼린 뒤 바뀌었습니다 (행 sha256 $(printf '%.12s' "$qb") → 지금 $(printf '%.12s' "$qc")) — 지금 해시로 묶을까요?
" ;;
      자동채택)
        rk_judge_asked '7.7 자동채택' && continue
        waits="${waits}대기${TAB}어휘${TAB}7.7 자동채택${TAB}이 자동 채택 행의 판단 부류는 지금 어휘가 받지 않습니다: $qa — 어떻게 할까요?
" ;;
    esac
  done < "$RK_TMP/judge-verify.out"

  # L13 — another manifest under this base already carried the source on.
  local m
  for m in "$RK_BASE"/docs/pipeline-run/*.plan.md; do
    [ -f "$m" ] || continue
    [ "$m" = "$RK_PM" ] && continue
    if grep -E '^- `사전 인가` \| ' "$m" 2>/dev/null | awk -v p="이어받은 런=$RK_PREV" '
         { n = split($0, f, / \| /); for (i = 2; i <= n; i++) { s = f[i]; sub(/[[:space:]]+$/, "", s); if (s == p) h = 1 } }
         END { exit !h }'; then
      rk_fire L13 "다른 매니페스트가 이미 원천 런 $RK_PREV 을 이어받았습니다: ${m#"$RK_BASE"/}"
    fi
  done

  rk_graph_compute
  remain=$(printf '%s' "$G_PLAN" | jq -r '[.steps[]? | select(type == "object") | .id] | join(",")' 2>/dev/null)

  printf 'cc-rekick v1\n'
  if [ -n "$lines" ]; then printf '판정\t금지\n'
  elif [ -n "$waits" ]; then printf '판정\t대기\n'
  else printf '판정\t허용\n'; fi
  printf '%s' "$lines"
  printf '%s' "$waits"
  printf '사실\t종료 토큰\t%s\n' "${etok:--}"
  printf '사실\t연쇄\t%s/%s\n' "${RK_CH_K:--}" "${RK_CH_CAP:--}"
  printf '사실\t진전\t%s\n' "${nprog:-0}"
  printf '사실\t열린 승인\t%s\n' "$RK_AP_N"
  printf '사실\t미답 중단\t%s\n' "$RK_HALT_N"
  printf '사실\t종료 절\t%s/%s\n' "$nmet" "$nclause"
  printf '사실\t남은 단계\t%s\n' "${remain:--}"
  exit 0
}

# rk_judge_asked <key> — the seat's `--asked` file has a line with that key.
# The answer itself is not read: what it allows, verify-subset measures again.
rk_judge_asked() {
  [ -n "$RK_ASKED" ] || return 1
  awk -F '\t' -v k="$1" '$1 == k { f = 1 } END { exit !f }' "$RK_ASKED"
}

# rk_budget_token <token> — succeeds for an end token that a budget ran out on,
# the ones a new run handed the same values can meet again.
rk_budget_token() {
  case "$1" in
    마감|천장|무진전|사이클예산|연기마감|말단상한) return 0 ;;
  esac
  return 1
}

# ---------------------------------------------------------------------------
# verify
# ---------------------------------------------------------------------------
rk_verify() {
  local failed="" pm_sha pg_sha iv_sha="-" why
  rk_prev_paths
  printf 'cc-rekick v1\n'
  MANIFEST=$(rk_copy "$RK_PM" prev.plan.md) || {
    printf '검사\t다이제스트\t실패\t원천 매니페스트를 읽을 수 없습니다\n판정\t실패\t다이제스트\n'; exit 1; }
  pm_sha=$(rk_sha "$MANIFEST")

  # (a) the two digests, re-derived.
  local tdig bdig td bd
  td=$(manifest_field '대상' '대상 맵 다이제스트'); bd=$(manifest_field '인가' '구속 다이제스트')
  tdig=$(canonical_targets | rk_sha_stdin); bdig=$(binding_set_bytes | rk_sha_stdin)
  if [ -z "$td" ] || [ "$td" != "$tdig" ]; then why="대상 맵 다이제스트가 대상 행과 다릅니다"
  elif [ -z "$bd" ]; then why="구속 다이제스트가 없습니다"
  elif [ "$bd" != "$bdig" ]; then why="구속 다이제스트가 얼린 집합과 다릅니다"
  else why=""; fi
  if [ -z "$why" ]; then printf '검사\t다이제스트\t통과\t-\n'
  else printf '검사\t다이제스트\t실패\t%s\n' "$why"; failed="${failed:+$failed, }다이제스트"; fi

  # (b) the interview record against its row.
  local irows nir ipath isha icopy
  irows=$(rk_interview_rows); nir=$(printf '%s' "$irows" | grep -c . || true)
  why=""
  if [ "${nir:-0}" -gt 1 ]; then why="인터뷰 행이 ${nir}개입니다"
  elif [ "${nir:-0}" = "1" ]; then
    ipath=$(manifest_row_fields "$irows" '인터뷰 기록' | head -n 1)
    isha=$(manifest_row_fields "$irows" 'sha256' | head -n 1)
    case "$ipath" in /*|*..*|'') why="인터뷰 행의 경로가 base 기준 경로가 아닙니다: $ipath" ;; esac
    if [ -z "$why" ]; then
      if icopy=$(rk_copy "$RK_BASE/$ipath" prev.interview.md); then
        iv_sha=$(rk_sha "$icopy")
        [ "$iv_sha" = "$isha" ] || why="인터뷰 기록의 sha256 이 행과 다릅니다"
      else
        why="인터뷰 행은 있는데 기록 파일이 없습니다: $ipath"
      fi
    fi
  else
    [ ! -e "$RK_BASE/docs/pipeline-run/$RK_PREV.interview.md" ] \
      || why="인터뷰 기록 파일은 있는데 매니페스트에 인터뷰 행이 없습니다"
  fi
  if [ -z "$why" ]; then printf '검사\t인터뷰\t통과\t-\n'
  else printf '검사\t인터뷰\t실패\t%s\n' "$why"; failed="${failed:+$failed, }인터뷰"; fi

  # (c) the authorization record, through the gate's own check.
  local gcopy tok
  if gcopy=$(rk_copy "$RK_PG" prev.grant.md); then
    pg_sha=$(rk_sha "$gcopy")
    tok=$(rk_gate grant "$MANIFEST" "$RK_PREV" "${RK_PRD:-$RK_TMP/no-run-dir}" "$RK_PL" "$gcopy" "$RK_TMP/grant.err")
    if [ "$tok" = "통과" ]; then printf '검사\t인가\t통과\t-\n'
    else
      why=$(sed -n 's/.*\[warn\] //p' "$RK_TMP/grant.err" 2>/dev/null | head -n 1)
      printf '검사\t인가\t실패\t%s\n' "${why:-게이트의 인가 검사가 통과하지 않았습니다 ($tok)}"
      failed="${failed:+$failed, }인가"
    fi
  else
    pg_sha="-"
    printf '검사\t인가\t실패\t원천 인가 기록이 없습니다\n'; failed="${failed:+$failed, }인가"
  fi

  # (d) the header's run id against the body's, and against the id asked for.
  local hr br
  hr=$(manifest_hdr_field 'run-id'); br=$(manifest_field '런 정체' '런 id')
  if [ -n "$hr" ] && [ "$hr" = "$br" ] && [ "$hr" = "$RK_PREV" ]; then printf '검사\t머리\t통과\t-\n'
  else printf '검사\t머리\t실패\t머리 run-id=%s · 본문 런 id=%s · 요청 %s\n' "$hr" "$br" "$RK_PREV"; failed="${failed:+$failed, }머리"; fi

  printf '해시\t매니페스트\t%s\n해시\t인가 기록\t%s\n해시\t인터뷰\t%s\n' "$pm_sha" "$pg_sha" "$iv_sha"

  # A base binding whose document moved is a question, not a failure.
  local bdrow bdoc bsha bnow
  bdrow=$(manifest_base_design_rows | head -n 1)
  if [ -n "$bdrow" ]; then
    bdoc=$(manifest_row_fields "$bdrow" '문서' | head -n 1)
    bsha=$(manifest_row_fields "$bdrow" 'sha256' | head -n 1)
    bnow=$(rk_sha "$RK_BASE/$bdoc"); [ -n "$bnow" ] || bnow="-"
    printf '베이스설계\t%s\t%s\t%s\n' "$bdoc" "$bsha" "$bnow"
    [ "$bnow" = "$bsha" ] || printf '질문\t베이스설계\t%s\t%s\t%s\n' "$bdoc" "$bsha" "$bnow"
  fi

  # An auto-adoption row whose class the driver no longer accepts is neither
  # carried nor dropped: the manifest check would refuse it at freeze time, and
  # dropping it silently would narrow what the person answered. It is a question.
  local cls row
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    cls=$(manifest_row_fields "$row" '판단 부류' | head -n 1)
    if judgment_class_forbidden "$cls" || ! judgment_class_ok "$cls"; then
      printf '질문\t자동채택\t%s\n' "$row"
    fi
  done <<EOF
$(manifest_autoadopt_rows_anywhere)
EOF

  # The values the one screen shows, so the kickoff never reads them itself.
  local ncl
  ncl=$(manifest_clause_rows_raw | grep -c . || true)
  printf '값\t의도\t%s\n' "$(rk_intent | awk 'NF { print; exit }')"
  printf '값\t킥오프 일시\t%s\n' "$(manifest_field '런 정체' '킥오프 일시')"
  printf '값\t종료 지점\t%s\n' "$(manifest_field '인가' '종료 지점')"
  printf '값\t종료 절 수\t%s\n' "${ncl:-0}"
  printf '값\t벽시계 마감\t%s\n' "$(manifest_field '인가' '벽시계 마감')"
  printf '값\t미선언 상황 처분\t%s\n' "$(manifest_field '인가' '미선언 상황 처분')"
  printf '값\t시각 정합 마커\t%s\n' "$(manifest_field '인가' '시각 정합 마커')"
  printf '값\t설계 문서\t%s\n' "$(manifest_field '요소' '설계 문서')"
  while IFS= read -r row; do
    [ -n "$row" ] && printf '대상\t%s\n' "$row"
  done <<EOF
$(manifest_targets)
EOF
  while IFS= read -r row; do
    [ -n "$row" ] && printf '로스터\t%s\n' "$row"
  done <<EOF
$(manifest_design_roster_rows_anywhere)
EOF

  if [ -z "$failed" ]; then printf '판정\t통과\n'; exit 0; fi
  printf '판정\t실패\t%s\n' "$failed"
  exit 1
}

# ---------------------------------------------------------------------------
# graph — which steps the ledger proves finished, and the plan without them.
# Sets G_PLAN (compact JSON), G_REMOVED, G_SKIPS, G_DESIGN_OUT, G_DOC_SHA,
# G_DESIGN_NOTE, G_AUDIT_NOTE, G_SCOPE. Reads the current MANIFEST (a copy).
# ---------------------------------------------------------------------------
rk_graph_compute() {
  local plan doc docf docsha did aid lastn hashrow hsha frozen
  plan=$(manifest_plan_json)
  G_SCOPE=$(manifest_design_scope)
  G_REMOVED=""; G_SKIPS=""; G_DESIGN_OUT=0; G_DOC_SHA="-"
  G_DESIGN_NOTE="없음${TAB}계획에 설계 단계가 없습니다"; G_AUDIT_NOTE="없음${TAB}계획에 감사 단계가 없습니다"
  doc=$(manifest_field '요소' '설계 문서')
  case "$doc" in ''|'(없음)') docf="" ;; *) docf="$RK_BASE/$doc" ;; esac
  docsha=""; [ -n "$docf" ] && docsha=$(rk_sha "$docf")
  did=$(printf '%s' "$plan" | jq -r '[.steps[]? | select(type == "object" and .skill == "design") | .id // empty] | if length == 1 then .[0] else empty end' 2>/dev/null)
  aid=$(printf '%s' "$plan" | jq -r '[.steps[]? | select(type == "object" and .skill == "design-audit") | .id // empty] | if length == 1 then .[0] else empty end' 2>/dev/null)

  if [ "$G_SCOPE" = "base" ]; then
    [ -z "$did" ] || G_DESIGN_NOTE="남음${TAB}base 범위 런의 그래프는 빼지 않습니다"
    [ -z "$aid" ] || G_AUDIT_NOTE="남음${TAB}base 범위 런의 그래프는 빼지 않습니다"
    G_PLAN=$(printf '%s' "$plan" | jq -c . 2>/dev/null)
    return 0
  fi

  # The design: the frozen line, exactly once.
  if [ -n "$did" ]; then
    if [ -n "$docf" ] && [ -f "$docf" ]; then
      frozen=$(grep -cxF '**상태**: 동결됨' "$docf" 2>/dev/null || true)
    else
      frozen=0
    fi
    if [ "${frozen:-0}" = "1" ]; then
      G_REMOVED="$did"; G_DESIGN_OUT=1; G_DOC_SHA="$docsha"
      G_DESIGN_NOTE="뺌${TAB}설계 문서에 **상태**: 동결됨 줄이 정확히 하나입니다"
      G_SKIPS="${G_SKIPS}${did}${TAB}design${TAB}설계 문서 $doc 에 **상태**: 동결됨 줄이 정확히 하나입니다
"
    else
      G_DESIGN_NOTE="남음${TAB}설계 문서에 동결 줄이 정확히 하나가 아닙니다 (${frozen:-0}개)"
    fi
  fi

  # The audit: a normal completion of that step, and the latest document hash
  # recorded before the last such completion equal to the document now. That
  # last completion must have concluded — one that asked for its skeletal
  # re-convergence (`재수렴 요청=예`), or one a re-convergence on the key came
  # after, leaves the step in, as the gate reads it before it plans segments.
  # An audit row that ended another way after it changes nothing. This file
  # does not source the gate, so the conditions are spelled here. Only
  # after the design is out — an audit of a design that runs again proves
  # nothing about the document that design will write.
  if [ -n "$aid" ]; then
    if [ -n "$did" ] && [ "$G_DESIGN_OUT" != "1" ]; then
      G_AUDIT_NOTE="남음${TAB}설계 단계가 남아 감사도 다시 돕니다"
    elif [ -z "$docsha" ]; then
      G_AUDIT_NOTE="남음${TAB}설계 문서를 읽을 수 없습니다"
    else
      lastn=$(awk -v aid="$aid" '
        function fld(line, name,   n, i, a, s, v) {
          n = split(line, a, /\|/); v = ""
          for (i = 2; i <= n; i++) {
            s = a[i]; sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s)
            if (index(s, name "=") == 1) { v = substr(s, length(name) + 2) }
          }
          return v
        }
        /^- `stage-result`/ && fld($0, "스테이지") == aid && fld($0, "관측") != "스폰 전 대기 중" {
          k = fld($0, "종류")
          if (k == "reconverge") last = "-"
          if (k == "audit" && fld($0, "종단 부류") == "정상 완료") {
            seen = 1
            last = (fld($0, "재수렴 요청") != "예") ? NR : "-"
          }
        }
        END { if (seen) print last }' "$RK_PL" 2>/dev/null)
      if [ "$lastn" = "-" ]; then
        G_AUDIT_NOTE="남음${TAB}감사 단계 $aid 의 마지막 행이 결론 난 감사가 아닙니다 (재수렴 요청 또는 그 뒤 재수렴)"
      elif [ -z "$lastn" ]; then
        G_AUDIT_NOTE="남음${TAB}감사 단계 $aid 의 정상 완료 행이 없습니다"
      else
        hashrow=$(awk -v aid="$aid 이후" -v lim="$lastn" '
          function fld(line, name,   n, i, a, s, v) {
            n = split(line, a, /\|/); v = ""
            for (i = 2; i <= n; i++) {
              s = a[i]; sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s)
              if (index(s, name "=") == 1) { v = substr(s, length(name) + 2) }
            }
            return v
          }
          NR >= lim { exit }
          /^- `문서 해시`/ && fld($0, "스테이지") == aid { h = fld($0, "sha256") }
          END { print h }' "$RK_PL" 2>/dev/null)
        hsha=$hashrow
        if [ -n "$hsha" ] && [ "$hsha" = "$docsha" ]; then
          G_REMOVED="${G_REMOVED:+$G_REMOVED }$aid"
          G_AUDIT_NOTE="뺌${TAB}감사 정상 완료 앞의 문서 해시가 지금 문서와 같습니다"
          G_SKIPS="${G_SKIPS}${aid}${TAB}design-audit${TAB}정상 완료 앞의 문서 해시 ${hsha%"${hsha#????????????}"} 가 지금 문서와 같습니다
"
        else
          G_AUDIT_NOTE="남음${TAB}감사가 본 문서 해시와 지금 문서 해시가 다릅니다"
        fi
      fi
    fi
  fi

  G_PLAN=$(printf '%s' "$plan" | jq -c --arg rm "$G_REMOVED" --arg dout "$G_DESIGN_OUT" '
    ($rm | split(" ") | map(select(. != ""))) as $r
    | if ($r | length) == 0 then . else
        .steps = [ .steps[]?
                   | select(((type == "object") and ((.id // "") as $i | ([$r[] | select(. == $i)] | length) > 0)) | not)
                   | if type == "object" then .depends_on = ([(.depends_on // [])[] | select(. as $d | ([$r[] | select(. == $d)] | length) == 0)]) else . end ]
        | (if (.steps | length) > 0 then .entry_skill = (.steps[0] | if type == "object" then .skill else . end) else . end)
        | (if $dout == "1" then .design_required = false else . end)
      end' 2>/dev/null)
}

# rk_plan_shape <json> — the step-graph shape the kickoff checks before it
# writes: ids present and unique, every dependency names a step that is there,
# at most one design step, and a `split` step only in a base run.
rk_plan_shape() {
  printf '%s' "$1" | jq -e --arg scope "$2" '
    [.steps[]? | select(type == "object")] as $s
    | ([$s[].id // ""] | map(select(. == "")) | length) == 0
    and ([$s[].id] | unique | length) == ($s | length)
    and ([$s[] | (.depends_on // [])[]] - [$s[].id] | length) == 0
    and ([$s[] | select(.skill == "design")] | length) <= 1
    and ($scope == "base" or ([$s[] | select(.skill == "split")] | length) == 0)
  ' >/dev/null 2>&1
}

rk_added_targets() {
  # The ledger's `대상 추가` rows, one per alias, as the fields a question needs.
  local row al rows
  rows=$(grep -F -- '- `대상 추가`' "$RK_PL" 2>/dev/null | awk '!seen[$0]++')
  while IFS= read -r row; do
    case "$row" in '- `대상 추가`'*) ;; *) continue ;; esac
    al=$(manifest_row_fields "$row" '별칭' | head -n 1)
    [ -n "$al" ] || continue
    printf '대상추가\t%s\t%s\t%s\t%s\t%s\n' "$al" \
      "$(manifest_row_fields "$row" '원격 슬러그' | head -n 1)" \
      "$(manifest_row_fields "$row" '메인 워크트리' | head -n 1)" \
      "$(manifest_row_fields "$row" '공통 git 디렉터리' | head -n 1)" \
      "$(manifest_row_fields "$row" '베이스 브랜치' | head -n 1)"
  done <<EOF
$rows
EOF
}

rk_graph() {
  rk_prev_paths
  MANIFEST=$(rk_copy "$RK_PM" prev.plan.md) || rk_fail "원천 매니페스트를 읽을 수 없습니다: $RK_PM"
  if [ -n "$RK_XSHA" ] && [ "$(rk_sha "$MANIFEST")" != "$RK_XSHA" ]; then
    rk_fail "원천 매니페스트가 검증한 해시와 다릅니다 — 검증 뒤에 바뀐 파일은 이어받지 않습니다"
  fi
  rk_graph_compute
  [ -n "$G_PLAN" ] || rk_fail "원천 매니페스트의 실행 계획을 읽지 못했습니다"
  local line id sk deps why shape_ok=1
  {
    printf 'cc-rekick v1\n'
    printf '범위\t%s\n' "$G_SCOPE"
    printf '설계\t%s\n감사\t%s\n' "$G_DESIGN_NOTE" "$G_AUDIT_NOTE"
    printf '%s' "$G_SKIPS" | while IFS= read -r line; do [ -n "$line" ] && printf '건너뜀\t%s\n' "$line"; done
    printf '%s' "$G_PLAN" | jq -r '.steps[]? | select(type == "object") | "남음\t\(.id)\t\(.skill)\t\(if ((.depends_on // []) | length) == 0 then "-" else ((.depends_on // []) | join(",")) end)"' 2>/dev/null
    printf '계획\t%s\n' "$G_PLAN"
    printf '문서해시\t%s\n' "$G_DOC_SHA"
    rk_added_targets
  } > "$RK_TMP/graph.out"

  why=""
  rk_plan_shape "$G_PLAN" "$G_SCOPE" || why="빼고 난 그래프가 모양 검사를 통과하지 않습니다"
  if [ -z "$why" ] && [ -n "$G_REMOVED" ]; then
    # The manifest the removal would freeze, with this run's own identity, put
    # through the driver's own manifest check.
    rk_render "$RK_TMP/graph-draft.md" "$RK_PREV" \
      "$(manifest_field '런 정체' '킥오프 일시')" "$(manifest_field '인가' '벽시계 마감')" \
      "$(manifest_field '런 정체' '사용자 확인 문면')" "$(manifest_field '실행 계획' '승인 문면')" \
      "$(rk_sha "$MANIFEST")" "-" \
      || why="빼고 난 매니페스트를 그리지 못했습니다"
    if [ -z "$why" ]; then rk_check_manifest "$RK_TMP/graph-draft.md" || why="빼고 난 매니페스트가 매니페스트 검사를 통과하지 않습니다"; fi
  fi
  if [ -z "$why" ] && [ -n "$RK_ACCEPTED" ]; then why="받아들인 대상 추가가 있습니다 ($RK_ACCEPTED)"; fi
  cat "$RK_TMP/graph.out"
  if [ -z "$why" ]; then printf '그래프\t순수\n'; else printf '그래프\t바뀜\t%s\n' "$why"; fi
  exit 0
}

# rk_check_manifest <file> — the driver's `check_manifest`, in a subshell, from
# the worktree the manifest names as its origin.
rk_check_manifest() {
  local m="$1" ow
  ow=$(MANIFEST="$m" manifest_hdr_field 'origin-worktree')
  ( [ -n "$ow" ] && cd "$ow" 2>/dev/null; MANIFEST="$m"; check_manifest ) >/dev/null 2>"$RK_TMP/check.err"
}

# ---------------------------------------------------------------------------
# Plugin rows. A previous `플러그인 허용` row is carried byte for byte unless its
# key is now in the seed or judged not installed; a row whose key cannot be
# judged, because an account file did not read, is carried too. The judgment
# reads the account directories of this call, so `verify-subset` derives it
# again instead of taking the render's.
# ---------------------------------------------------------------------------
rk_pa_key() { manifest_row_fields "$1" '플러그인' | head -n 1; }

# rk_pa_judge — reads the seed and the account set once, for rk_pa_state.
rk_pa_judge() {
  RK_PA_SEEDK=$(pi_seed_keys "$RK_PI_SEED")
  RK_PA_USERK=$(pi_kickoff_user_keys)
  RK_PA_FAIL=$(pi_kickoff_read_fail)
}
# rk_pa_state <key> — `시드`, `켬`, `미설치` or `판정 불가<TAB><경로>`.
rk_pa_state() { pi_judge "$RK_PA_SEEDK" "$RK_PA_USERK" "$RK_PA_FAIL" "$1"; }

# rk_plugin_carry — over the current MANIFEST's rows: RK_PA_KEPT the rows that
# carry, RK_PA_DROP the keys whose rows do not, and RK_PA_UNSURE one
# `<키><TAB><경로>` per row carried because its key cannot be judged; each
# newline-separated.
rk_plugin_carry() {
  local r k st
  RK_PA_KEPT=''; RK_PA_DROP=''; RK_PA_UNSURE=''
  rk_pa_judge
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    k=$(rk_pa_key "$r"); st=$(rk_pa_state "$k")
    case "$st" in
      시드|미설치) RK_PA_DROP="$RK_PA_DROP$k
" ;;
      *)
        RK_PA_KEPT="$RK_PA_KEPT$r
"
        case "$st" in '판정 불가'*) RK_PA_UNSURE="$RK_PA_UNSURE$k$TAB${st#*"$TAB"}
" ;; esac ;;
    esac
  done <<EOF
$(manifest_plugin_allow_rows)
EOF
}

# rk_plugin_rows <out> — the `플러그인 허용` rows of `--rows`, written to <out>
# in order; each one is a row a person confirmed at 5o for a blank `--carry`
# showed. Prints the first refusal and returns 1 for a row of another shape, a
# row under `--auto` (the seat confirms nothing), and a key given twice or
# already carried. Reads RK_PA_KEPT.
rk_plugin_rows() {
  local out="$1" r k seen=''
  : > "$out"
  [ -n "$RK_ROWS" ] || return 0
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    [ "$RK_AUTO" != "1" ] || { printf '%s' "--auto 의 --rows 에 플러그인 허용 행이 있습니다 — 좌석은 기본값을 확정하지 않습니다: $r"; return 1; }
    printf '%s\n' "$r" | grep -qE '^- `플러그인 허용` \| 플러그인=[A-Za-z0-9_.-]+@[A-Za-z0-9_.-]+ \| 사유=[^|]*[^ |]$' \
      || { printf '%s' "--rows 의 플러그인 허용 행 형식이 어긋났습니다: $r"; return 1; }
    k=$(rk_pa_key "$r")
    case "$k" in *@inline|*@builtin) printf '%s' "--rows 의 플러그인 허용 행이 $k 를 켭니다 — @inline·@builtin 키는 허용 행으로 다루지 않습니다"; return 1 ;; esac
    case "$seen" in *" $k "*) printf '%s' "--rows 에 플러그인 $k 의 행이 둘 이상입니다"; return 1 ;; esac
    seen="$seen $k "
    printf '%s' "$RK_PA_KEPT" | while IFS= read -r kr; do [ -n "$kr" ] && rk_pa_key "$kr" && printf '\n'; done \
      | grep -qxF -- "$k" && { printf '%s' "--rows 의 플러그인 $k 는 앞선 런에서 이어 쓰는 행이 이미 있습니다"; return 1; }
    printf '%s\n' "$r" >> "$out"
  done <<EOF
$(grep -E '^- `플러그인 허용`' "$RK_ROWS" 2>/dev/null || true)
EOF
  return 0
}

# ---------------------------------------------------------------------------
# The draft. rk_render <out> <new id> <kickoff at> <deadline> <confirmation>
# <approval> <previous manifest sha256> <previous grant sha256> — reads the
# current MANIFEST (the previous run's copy) and the G_* graph values, and the
# RK_TARGETS / RK_ROWS / RK_RULES / RK_BIND / RK_VISUAL options. The two
# digests are derived last, by the driver's own serializers, over the draft.
# ---------------------------------------------------------------------------
rk_render() {
  local out="$1" newid="$2" kat="$3" dl="$4" confirm="$5" approval="$6" pmsha="$7" pgsha="$8"
  local trows maxcut planf="" prov tdig bdig
  if [ -n "$RK_TARGETS" ]; then trows=$(grep -E '^- `target`' "$RK_TARGETS" 2>/dev/null || true); else trows=$(manifest_targets); fi
  maxcut=$(rk_cut_max "$trows")
  [ -n "$maxcut" ] || maxcut=$(manifest_field '인가' '런 최대 절단점')
  if [ -n "$G_REMOVED" ]; then
    planf="$RK_TMP/plan.json"
    printf '%s' "$G_PLAN" | jq . > "$planf" 2>/dev/null || return 1
  fi
  prov="- \`사전 인가\` | 이어받은 런=$RK_PREV | 매니페스트 sha256=$pmsha | 인가 기록 sha256=$pgsha${RK_PROV_SEAT:-}"
  printf '%s' "$trows" > "$RK_TMP/targets.rows"
  # Whenever `--rows` is given, its shape and auto-adoption rows replace the
  # previous ones, none included: the file is the whole set the person kept.
  if [ -n "$RK_ROWS" ]; then
    grep -E '^- `(사전 인가` \| 형태=|자동 채택`|라벨 인정`)' "$RK_ROWS" > "$RK_TMP/shape.rows" 2>/dev/null || : > "$RK_TMP/shape.rows"
  fi
  rk_plugin_carry
  printf '%s' "$RK_PA_DROP" > "$RK_TMP/plugin.drop"
  RK_RENDER_WHY=$(rk_plugin_rows "$RK_TMP/plugin.rows") || return 1
  printf '%s' "$RK_RULES" > "$RK_TMP/rules.kv"
  [ -f "$RK_TMP/sets.tsv" ] || : > "$RK_TMP/sets.tsv"
  # A mapping row that cannot be carried is dropped, and a confirmed mapping is
  # written as a new row bound to the probe the draft will carry: the confirmed
  # `apply-probe` when one is set, the previous value otherwise.
  local acdrop="" acrow="" acv acprobe
  if apply_code_row_reask; then
    acdrop=1
    acv=$(awk -F '\t' '$5 == "apply-probe-codes" { print $4 }' "$RK_TMP/sets.tsv")
    if [ -n "$acv" ]; then
      acprobe=$(awk -F '\t' '$2 == "요소" && $3 == "적용 프로브" { print $4 }' "$RK_TMP/sets.tsv")
      [ -n "$acprobe" ] || acprobe=$(manifest_field '요소' '적용 프로브')
      acrow="- \`적용 프로브 코드\` | 불필요=${acv%%/*} | 필요=${acv#*/} | 프로브 sha256=$(apply_probe_sha "$(apply_unquote "$acprobe")")"
    fi
  fi
  R_ACDROP="$acdrop" R_ACROW="$acrow" \
  R_SETS="$RK_TMP/sets.tsv" R_NEWID="$newid" R_KAT="$kat" R_DL="$dl" R_CONFIRM="$confirm" R_APPROVAL="$approval" \
  R_MAXCUT="$maxcut" R_VISUAL="$RK_VISUAL" R_DOUT="$G_DESIGN_OUT" R_DOCSHA="$G_DOC_SHA" \
  R_PLANF="$planf" R_PROV="$prov" R_TFILE="$( [ -n "$RK_TARGETS" ] && printf '%s' "$RK_TMP/targets.rows")" \
  R_RFILE="$( [ -n "$RK_ROWS" ] && printf '%s' "$RK_TMP/shape.rows")" R_RULES="$RK_TMP/rules.kv" \
  R_PADROP="$RK_TMP/plugin.drop" R_PFILE="$( [ -s "$RK_TMP/plugin.rows" ] && printf '%s' "$RK_TMP/plugin.rows")" \
  R_BIND="$RK_BIND" R_IVPATH="docs/pipeline-run/$newid.interview.md" R_ADOPT="${RK_ADOPT_ROWS:-}" \
  awk '
    function field(line,   p) { p = index(line, "**: "); return substr(line, 3, p - 3) }
    # What a section must still carry is written when it closes, before the
    # blank lines that separate it from the next one.
    function close_sec(   key, a) {
      # A confirmed blank whose line the previous manifest did not carry at all.
      for (key in rset) {
        split(key, a, SUBSEP)
        if (("## " a[1]) == sec && !(key in rdone)) { print "**" a[2] "**: " rset[key]; rdone[key] = 1 }
      }
      if (sec == "## 인가") {
        if (!rows_done && rfile != "") { while ((getline l < rfile) > 0) print l; close(rfile); rows_done = 1 }
        if (!adopt_done && ENVIRON["R_ADOPT"] != "") { while ((getline l < ENVIRON["R_ADOPT"]) > 0) print l; close(ENVIRON["R_ADOPT"]); adopt_done = 1 }
        if (!acrow_done && ENVIRON["R_ACROW"] != "") { print ENVIRON["R_ACROW"]; acrow_done = 1 }
        if (!plugin_done && pfile != "") { while ((getline l < pfile) > 0) print l; close(pfile); plugin_done = 1 }
        if (!prov_done) { print ENVIRON["R_PROV"]; prov_done = 1 }
      }
      if (sec == "## 요소" && ENVIRON["R_DOUT"] == "1" && !docsha_done) {
        print "**설계 문서 전체 sha256**: " ENVIRON["R_DOCSHA"]; docsha_done = 1
      }
    }
    function flush_blank() { for (i = 1; i <= nblank; i++) print ""; nblank = 0 }
    # A target row with the confirmed blanks of its alias written in: an empty
    # field takes the value, an absent one is appended.
    function tapply(line,   al, key, a, pat, p) {
      if (!match(line, /별칭=[^ |]*/)) return line
      al = substr(line, RSTART + length("별칭="), RLENGTH - length("별칭="))
      for (key in tset) {
        split(key, a, SUBSEP)
        if (a[1] != al) continue
        pat = "| " a[2] "="
        if ((p = index(line, pat " |")) > 0) { line = substr(line, 1, p + length(pat) - 1) tset[key] substr(line, p + length(pat)) }
        else if (substr(line, length(line) - length(pat) + 1) == pat) { line = line tset[key] }
        else line = line " | " a[2] "=" tset[key]
      }
      return line
    }
    BEGIN {
      newid = ENVIRON["R_NEWID"]; tfile = ENVIRON["R_TFILE"]; rfile = ENVIRON["R_RFILE"]
      planf = ENVIRON["R_PLANF"]; pfile = ENVIRON["R_PFILE"]; hdr = 1
      while ((getline l < ENVIRON["R_PADROP"]) > 0) if (l != "") padrop[l] = 1
      close(ENVIRON["R_PADROP"])
      while ((getline l < ENVIRON["R_RULES"]) > 0) { p = index(l, "="); if (p) rule[substr(l, 1, p - 1)] = substr(l, p + 1) }
      close(ENVIRON["R_RULES"])
      while ((getline l < ENVIRON["R_SETS"]) > 0) {
        n = split(l, s, "\t"); if (n < 4) continue
        if (s[2] == "대상") tset[s[1], s[3]] = s[4]; else rset[s[2], s[3]] = s[4]
      }
      close(ENVIRON["R_SETS"])
    }
    NR == 1 { print "# 파이프라인 런 매니페스트 — " newid; next }
    hdr {
      line = $0
      if (match(line, /run-id=[^;]*;/)) line = substr(line, 1, RSTART - 1) "run-id=" newid ";" substr(line, RSTART + RLENGTH)
      print line
      if (index($0, "-->")) hdr = 0
      next
    }
    fence {
      if (/^```/) { fence = 0; if (skipjson) { skipjson = 0 } ; print; next }
      if (!skipjson) print
      next
    }
    /^```/ {
      fence = 1
      if (sec == "## 실행 계획" && planf != "" && /^```json/) {
        print; while ((getline l < planf) > 0) print l; close(planf); skipjson = 1; next
      }
      print; next
    }
    /^## / { close_sec(); flush_blank(); sec = $0; print; next }
    /^$/ { nblank++; next }
    nblank > 0 { flush_blank() }
    /^- `사전 인가` \| 이어받은 런=/ { next }
    # The adoption rows of the previous run are never carried: an adoption row
    # of this run is one derived again at this call, written when the section
    # closes.
    /^- `세그먼트 입양`/ { next }
    # The plugin rows of the previous run are carried in place, byte for byte,
    # except a row whose key is now in the seed or judged not installed.
    # Dropping a row only narrows the successor.
    /^- `플러그인 허용`/ {
      if (match($0, /플러그인=[^ |]*/) && (substr($0, RSTART + length("플러그인="), RLENGTH - length("플러그인=")) in padrop)) next
      print; next
    }
    # A mapping row the pipeline cannot run on is not carried; 5c answers it
    # again and the confirmed row is written when the section closes.
    /^- `적용 프로브 코드`/ { if (ENVIRON["R_ACDROP"] == "1") next; print; next }
    /^- `사전 인가` \| 인터뷰 기록=/ {
      if (ENVIRON["R_DOUT"] == "1") next
      line = $0; sub(/인터뷰 기록=[^|]*\|/, "인터뷰 기록=" ENVIRON["R_IVPATH"] " |", line); print line; next
    }
    /^- `설계 로스터`/ { if (ENVIRON["R_DOUT"] == "1") next; print; next }
    /^- `(사전 인가` \| 형태=|자동 채택`|라벨 인정`)/ {
      if (rfile == "") { print; next }
      if (!rows_done) { while ((getline l < rfile) > 0) print l; close(rfile); rows_done = 1 }
      next
    }
    /^- `베이스 설계`/ {
      line = $0
      if (ENVIRON["R_BIND"] != "") sub(/sha256=[0-9a-f]+/, "sha256=" ENVIRON["R_BIND"], line)
      print line; next
    }
    /^- `target`/ {
      if (tfile == "") { print tapply($0); next }
      if (!targets_done) { while ((getline l < tfile) > 0) print tapply(l); close(tfile); targets_done = 1 }
      next
    }
    /^\*\*[^*]+\*\*: / {
      f = field($0)
      if (sec == "## 런 정체" && f == "킥오프 일시") { print "**킥오프 일시**: " ENVIRON["R_KAT"]; next }
      if (sec == "## 런 정체" && f == "런 id") { print "**런 id**: " newid; next }
      if (sec == "## 런 정체" && f == "사용자 확인 문면") { print "**사용자 확인 문면**: " ENVIRON["R_CONFIRM"]; next }
      if (sec == "## 대상" && f == "대상 맵 다이제스트") { print "**대상 맵 다이제스트**: @RK_TDIG@"; next }
      if (sec == "## 요소" && f == "설계 문서 전체 sha256" && ENVIRON["R_DOUT"] == "1") { print "**설계 문서 전체 sha256**: " ENVIRON["R_DOCSHA"]; docsha_done = 1; next }
      if (sec == "## 실행 계획" && f == "승인 문면") { print "**승인 문면**: " ENVIRON["R_APPROVAL"]; next }
      if (sec == "## 인가" && f == "구속 다이제스트") { print "**구속 다이제스트**: @RK_BDIG@"; next }
      if (sec == "## 인가" && f == "런 최대 절단점") { print "**런 최대 절단점**: " ENVIRON["R_MAXCUT"]; next }
      if (sec == "## 인가" && f == "벽시계 마감") { print "**벽시계 마감**: " ENVIRON["R_DL"]; next }
      if (sec == "## 인가" && f == "시각 정합 마커" && ENVIRON["R_VISUAL"] != "") { print "**시각 정합 마커**: " ENVIRON["R_VISUAL"]; next }
      if ((f in rule) && $0 ~ /\*\*: (켬|끔)$/) { print "**" f "**: " rule[f]; next }
      if ((substr(sec, 4), f) in rset) { print "**" f "**: " rset[substr(sec, 4), f]; rdone[substr(sec, 4), f] = 1; next }
      print; next
    }
    { print }
    END { close_sec(); flush_blank() }
  ' "$MANIFEST" > "$out.tmp" || return 1
  local saved="$MANIFEST"
  MANIFEST="$out.tmp"
  tdig=$(canonical_targets | rk_sha_stdin)
  bdig=$(binding_set_bytes | rk_sha_stdin)
  MANIFEST="$saved"
  sed -e "s/@RK_TDIG@/$tdig/" -e "s/@RK_BDIG@/$bdig/" "$out.tmp" > "$out" || return 1
  rm -f "$out.tmp"
}

# rk_confirm_text — the new `사용자 확인 문면`: this call's argument verbatim
# (`/cc-cmds:autopilot` when it was empty), then each answer this re-kickoff
# asked, then each `--set` entry as given, joined with ` / `. The 5o answer
# itself is 「이대로」, so the confirmed values are written beside it. Built from
# this call's own `--set` list, the text proves nothing about that list; it is
# what `verify-subset` compares a second, independent `--set` list with, and
# the `빈칸` rows are what that list is bound to.
rk_confirm_text() {
  local s k a e
  s=$(rk_trim "$RK_ARG"); [ -n "$s" ] || s='/cc-cmds:autopilot'
  if [ -n "$RK_ASKED" ]; then
    while IFS="$TAB" read -r k a; do
      [ -n "$k" ] || continue
      s="$s / $a"
    done < "$RK_ASKED"
  fi
  while IFS= read -r e; do
    [ -n "$e" ] || continue
    s="$s / $e"
  done <<EOF
$RK_SETS
EOF
  printf '%s' "$s"
}

# rk_seat_confirm_text <source id> — the seat link's `사용자 확인 문면`:
# `좌석 재킥오프 <source id>`, then each answer the seat asked, joined with
# ` / `. The seat's own words never stand where a person's approval would.
rk_seat_confirm_text() {
  local s="좌석 재킥오프 $1" k a
  if [ -n "$RK_ASKED" ]; then
    while IFS="$TAB" read -r k a; do
      [ -n "$k" ] || continue
      s="$s / $a"
    done < "$RK_ASKED"
  fi
  printf '%s' "$s"
}

rk_asked_answer() {
  # rk_asked_answer <key> — the answer recorded for that key, the last one.
  [ -n "$RK_ASKED" ] || return 0
  awk -F '\t' -v k="$1" '$1 == k { a = substr($0, length($1) + 2) } END { if (a != "") print a }' "$RK_ASKED"
}

# rk_set_field <key> — where a `--set` key lands: `<section><TAB><field>`.
rk_set_field() {
  case "$1" in
    ladder-rungs)     printf '인가\t사다리 가용 단 수' ;;
    stagnation-bound) printf '인가\t무진전 상한' ;;
    cost-ceiling)     printf '인가\t비용 천장' ;;
    apply-probe)      printf '요소\t적용 프로브' ;;
    apply-actor)      printf '요소\t적용 주체' ;;
    cutpoint)         printf '대상\t절단점' ;;
    review-ceiling)   printf '대상\t리뷰 정책 상한' ;;
    terminal-cap)     printf '대상\t말단 행위 상한' ;;
    dev-ids)          printf '대상\tdev 식별자' ;;
    deploy-triggers)  printf '대상\t배포트리거 식별자' ;;
    *) return 1 ;;
  esac
}

# rk_target_of <label> — the alias of the target a scope label names in the
# current MANIFEST. `--carry` labels a target by its remote slug when it has
# one, so a 5o row carried verbatim names the slug; it stands for the one
# target that declares it, and a slug no target or several targets declare is
# refused rather than guessed. Returns 1 for none and 2 for several.
rk_target_of() {
  local al hit=""
  if target_aliases | grep -qxF -- "$1"; then printf '%s' "$1"; return 0; fi
  for al in $(target_aliases); do
    [ "$(target_field "$al" '원격 슬러그')" = "$1" ] || continue
    [ -z "$hit" ] || return 2
    hit=$al
  done
  [ -n "$hit" ] || return 1
  printf '%s' "$hit"
}

# rk_sets_resolve <out> — reads RK_SETS against the current MANIFEST (the
# previous run's copy) and writes
# `<범위><TAB><섹션><TAB><필드><TAB><값><TAB><키><TAB><적힌 범위>` per entry —
# `<범위>` is the target's alias even when the entry named its remote slug, and
# `<적힌 범위>` is the scope as the entry wrote it, which is what the user
# confirmation line repeats. Prints the first refusal and returns 1 when an
# entry names an unknown key, a scope that does not fit it, a target the previous manifest
# does not hold, a value the previous manifest already has, a value a target
# row cannot carry, or the same place twice.
rk_sets_resolve() {
  local out="$1" e sc rest k v loc sec f pv hit rsc
  : > "$out"
  while IFS= read -r e; do
    [ -n "$e" ] || continue
    sc=${e%%:*}; rest=${e#*:}; k=${rest%%=*}; v=${rest#*=}; rsc=$sc
    # The mapping is a row, not a field: it is a blank only where the previous
    # row cannot be carried, and its value is held to the manifest check's rule.
    if [ "$k" = "apply-probe-codes" ]; then
      [ "$sc" = "런" ] || { printf '%s' "--set $k 의 범위는 런입니다"; return 1; }
      apply_code_value_ok "${v%%/*}" && apply_code_value_ok "${v#*/}" && [ "${v%%/*}" != "${v#*/}" ] \
        && [ "${v%%/*}/${v#*/}" = "$v" ] \
        || { printf '%s' "--set 런:$k 의 값은 <불필요>/<필요> 이고, 두 값은 0–125 의 서로 다른 정수이며 1·2 가 아닙니다: $v"; return 1; }
      apply_code_row_reask \
        || { printf '%s' "--set 런:$k — 원천 매니페스트의 적용 프로브 코드 행을 그대로 이어받으므로 빈칸이 아닙니다"; return 1; }
      awk -F '\t' -v k="$k" '$5 == k { d = 1 } END { exit !d }' "$out" \
        && { printf '%s' "--set 런:$k 가 두 번 주어졌습니다"; return 1; }
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$sc" '인가 행' '적용 프로브 코드' "$v" "$k" "$rsc" >> "$out"
      continue
    fi
    loc=$(rk_set_field "$k") || { printf '%s' "--set 의 키를 모릅니다: $k"; return 1; }
    sec=${loc%%"$TAB"*}; f=${loc#*"$TAB"}
    if [ "$sec" = "대상" ]; then
      [ "$sc" != "런" ] || { printf '%s' "--set $k 의 범위는 대상 별칭입니다"; return 1; }
      hit=$(rk_target_of "$sc"); case $? in
        0) sc=$hit ;;
        2) printf '%s' "--set 의 대상 $sc 를 원격 슬러그로 선언한 대상이 여럿입니다"; return 1 ;;
        *) printf '%s' "--set 의 대상 $sc 가 원천 매니페스트에 없습니다"; return 1 ;;
      esac
      case "$v" in *'|'*) printf '%s' "--set $sc:$k 값에 | 가 있습니다"; return 1 ;; esac
      pv=$(target_field "$sc" "$f")
    else
      [ "$sc" = "런" ] || { printf '%s' "--set $k 의 범위는 런입니다"; return 1; }
      pv=$(manifest_field "$sec" "$f")
    fi
    [ -z "$pv" ] || { printf '%s' "--set $sc:$k — 원천 매니페스트에 이미 값이 있어 빈칸이 아닙니다"; return 1; }
    awk -F '\t' -v s="$sc" -v f="$f" '$1 == s && $3 == f { d = 1 } END { exit !d }' "$out" \
      && { printf '%s' "--set $sc:$k 가 두 번 주어졌습니다"; return 1; }
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$sc" "$sec" "$f" "$v" "$k" "$rsc" >> "$out"
  done <<EOF
$RK_SETS
EOF
  return 0
}

rk_render_manifest() {
  rk_prev_paths
  MANIFEST=$(rk_copy "$RK_PM" prev.plan.md) || rk_fail "원천 매니페스트를 읽을 수 없습니다: $RK_PM"
  [ "$(rk_sha "$MANIFEST")" = "$RK_XSHA" ] \
    || rk_fail "원천 매니페스트가 검증한 해시와 다릅니다 — 검증 뒤에 바뀐 파일은 이어받지 않습니다"
  local gcopy
  gcopy=$(rk_copy "$RK_PG" prev.grant.md) || rk_fail "원천 인가 기록을 읽을 수 없습니다: $RK_PG"
  [ "$(rk_sha "$gcopy")" = "$RK_XGSHA" ] \
    || rk_fail "원천 인가 기록이 검증한 해시와 다릅니다 — 검증 뒤에 바뀐 파일은 이어받지 않습니다"
  [ -n "$(rk_wide_instant "$RK_DEADLINE")" ] || rk_fail "--deadline 을 시각으로 읽지 못했습니다: '$RK_DEADLINE'"
  local setwhy
  setwhy=$(rk_sets_resolve "$RK_TMP/sets.tsv") || rk_fail "$setwhy"
  rk_graph_compute
  [ -n "$G_PLAN" ] || rk_fail "원천 매니페스트의 실행 계획을 읽지 못했습니다"
  local confirm approval
  if [ "$RK_AUTO" = "1" ]; then
    # The seat's link: the texts are fixed here, not written by the seat, and
    # the provenance row carries the chain on. A link past the consent row's
    # cap is refused before anything is drawn.
    rk_chain "$MANIFEST" "$RK_PL" "$RK_PREV"
    [ -z "$RK_CH_WHY" ] || rk_refuse "좌석 연쇄를 낼 수 없습니다 — $RK_CH_WHY"
    [ -n "$RK_CH_CAP" ] || rk_refuse "원천 매니페스트에 재킥오프 동의 행이 없습니다"
    [ "$RK_CH_K" -le "$RK_CH_CAP" ] || rk_refuse "좌석 연쇄 $RK_CH_K 가 연쇄 상한 $RK_CH_CAP 을 넘습니다"
    [ -n "$RK_CH_CAUSE" ] || rk_refuse "원천 런의 종료 토큰을 읽지 못했습니다"
    # The graph `graph` calls changed has no approval a seat may give: a plan
    # that fails the shape check is refused here, as the removal's manifest
    # check is after the draft is drawn.
    rk_plan_shape "$G_PLAN" "$G_SCOPE" || rk_refuse "빼고 난 그래프가 모양 검사를 통과하지 않습니다 — 좌석은 바뀐 그래프를 승인하지 않습니다"
    RK_PROV_SEAT=" | 좌석 연쇄=$RK_CH_K | 뿌리 런=$RK_CH_ROOT | 원인=$RK_CH_CAUSE"
    confirm=$(rk_seat_confirm_text "$RK_PREV")
    approval='좌석 재킥오프'
  else
    confirm=$(rk_confirm_text)
    approval=$(rk_asked_answer '5l')
    if [ -z "$approval" ]; then approval=$(rk_trim "$RK_ARG"); [ -n "$approval" ] || approval='/cc-cmds:autopilot'; fi
  fi
  # The adoption rows, derived again here over the targets the draft carries:
  # every candidate on the seat's link, and each candidate a person answered
  # `이어받기` otherwise.
  if [ "$RK_NOADOPT" != "1" ]; then
    local trows kind seg cb cw cn ch
    if [ -n "$RK_TARGETS" ]; then trows=$(grep -E '^- `target`' "$RK_TARGETS" 2>/dev/null || true); else trows=$(manifest_targets); fi
    RK_ADOPT_ROWS="$RK_TMP/adopt.rows"
    : > "$RK_ADOPT_ROWS"
    while IFS="$TAB" read -r kind seg cb cw cn ch _; do
      [ "$kind" = "입양후보" ] || continue
      if [ "$RK_AUTO" != "1" ] && [ "$(rk_asked_answer "입양 $seg")" != "$(rk_adopt_take_label "$seg" "$cn" "$cb" "$ch")" ]; then
        continue
      fi
      { rk_adopt_row "$seg" "$cb" "$cw" "$cn"; printf '\n'; } >> "$RK_ADOPT_ROWS"
    done <<EOF
$(rk_adopt_candidates "$trows" full)
EOF
  fi
  RK_RENDER_WHY=''
  rk_render "$RK_TMP/draft.md" "$RK_NEWID" "$RK_KAT" "$RK_DEADLINE" "$confirm" "$approval" "$RK_XSHA" "$RK_XGSHA" \
    || rk_fail "${RK_RENDER_WHY:-매니페스트 초안을 그리지 못했습니다}"
  if [ "$RK_AUTO" = "1" ] && [ -n "$G_REMOVED" ]; then
    rk_check_manifest "$RK_TMP/draft.md" \
      || rk_refuse "빼고 난 매니페스트가 매니페스트 검사를 통과하지 않습니다 — 좌석은 바뀐 그래프를 승인하지 않습니다"
  fi
  # One fixed-head line on stderr per row carried because its key could not be
  # judged, so the kickoff can show what it carried blind and why.
  local pn_k pn_p
  while IFS="$TAB" read -r pn_k pn_p; do
    [ -n "$pn_k" ] || continue
    printf '플러그인 알림\t판정 불가 이월\t%s\t%s\n' "$pn_k" "$pn_p" >&2
  done <<EOF
$RK_PA_UNSURE
EOF
  cat "$RK_TMP/draft.md"
  exit 0
}

# ---------------------------------------------------------------------------
# render-interview — the previous record's bytes, after the row's hash.
# ---------------------------------------------------------------------------
rk_render_interview() {
  rk_prev_paths
  MANIFEST=$(rk_copy "$RK_PM" prev.plan.md) || rk_fail "원천 매니페스트를 읽을 수 없습니다: $RK_PM"
  if [ -n "$RK_XSHA" ] && [ "$(rk_sha "$MANIFEST")" != "$RK_XSHA" ]; then
    rk_fail "원천 매니페스트가 검증한 해시와 다릅니다 — 검증 뒤에 바뀐 파일은 이어받지 않습니다"
  fi
  local irows nir ipath isha icopy
  irows=$(rk_interview_rows); nir=$(printf '%s' "$irows" | grep -c . || true)
  [ "${nir:-0}" = "1" ] || rk_fail "원천 매니페스트의 인터뷰 행이 ${nir:-0}개입니다 — 정확히 하나여야 복사합니다"
  ipath=$(manifest_row_fields "$irows" '인터뷰 기록' | head -n 1)
  isha=$(manifest_row_fields "$irows" 'sha256' | head -n 1)
  case "$ipath" in /*|*..*|'') rk_fail "인터뷰 행의 경로가 base 기준 경로가 아닙니다: $ipath" ;; esac
  icopy=$(rk_copy "$RK_BASE/$ipath" prev.interview.md) || rk_fail "원천 인터뷰 기록을 읽을 수 없습니다: $ipath"
  [ "$(rk_sha "$icopy")" = "$isha" ] || rk_fail "원천 인터뷰 기록의 sha256 이 행과 다릅니다 — 복사하지 않습니다"
  cat "$icopy"
  exit 0
}

# ---------------------------------------------------------------------------
# verify-subset — the draft widens nothing the previous run froze.
# ---------------------------------------------------------------------------
VS_FAILED=""
vs_check() {
  # vs_check <name> <reason|empty>
  if [ -z "$2" ]; then printf '검사\t%s\t통과\t-\n' "$1"
  else printf '검사\t%s\t실패\t%s\n' "$1" "$2"; VS_FAILED="${VS_FAILED:+$VS_FAILED, }$1"; fi
}

# vs_in <needle> <haystack lines> — the needle is one whole line of the list.
vs_in() { printf '%s\n' "$2" | grep -qxF -- "$1"; }

# vs_set_is <scope> <field> <draft value> — a `--set` entry names this place,
# and the draft carries exactly its value. That the entry is one 5o confirmed
# is check 2b's to show, not this exemption's.
VS_SETS=""
vs_set_is() {
  [ -n "$VS_SETS" ] && [ -s "$VS_SETS" ] || return 1
  awk -F '\t' -v s="$1" -v f="$2" -v d="$3" '$1 == s && $3 == f { ok = ($4 == d); hit = 1 } END { exit !(hit && ok) }' "$VS_SETS"
}

# vs_blank_has <alias|런> <key> <value> — a `빈칸` row of the saved 5o output
# has this key and value, and its scope cell resolves in the current MANIFEST
# to this scope. Key and value compare as bytes.
VS_BLANKS=""
# vs_load_blanks <what needs them> — copies `--blank-rows` to blanks.tsv and
# checks its head line. Prints why and returns 1 when it cannot; the caller
# sets VS_BLANKS, since this runs in a command substitution.
vs_load_blanks() {
  if [ -z "$RK_BLANKS" ]; then printf '%s' "$1 에는 5o 에서 확인한 빈칸 행(--blank-rows)이 필요합니다"; return 1; fi
  local b
  b=$(rk_copy "$RK_BLANKS" blanks.tsv) || { printf '%s' "빈칸 행 파일을 읽을 수 없습니다: $RK_BLANKS"; return 1; }
  [ "$(head -n 1 "$b")" = "cc-kickoff-defaults v1" ] || { printf '%s' "빈칸 행 파일의 머리가 cc-kickoff-defaults v1 이 아닙니다"; return 1; }
  return 0
}
vs_blank_has() {
  local lsc al
  while IFS= read -r lsc; do
    [ -n "$lsc" ] || continue
    al=$lsc
    if [ "$lsc" != "런" ]; then al=$(rk_target_of "$lsc") || continue; fi
    [ "$al" = "$1" ] && return 0
  done <<EOF
$(VB_K="$2" VB_V="$3" awk -F '\t' '$1 == "빈칸" && $3 == ENVIRON["VB_K"] && $4 == ENVIRON["VB_V"] { print $2 }' "$VS_BLANKS")
EOF
  return 1
}

rk_verify_subset() {
  local draft prev pbase pid pgrant why
  draft=$(rk_copy "$RK_POS1" draft.md) || rk_fail "초안을 읽을 수 없습니다: $RK_POS1"
  prev=$(rk_copy "$RK_POS2" prev.plan.md) || rk_fail "이전 매니페스트를 읽을 수 없습니다: $RK_POS2"
  printf 'cc-rekick v1\n'
  if [ "$(rk_sha "$prev")" != "$RK_XSHA" ]; then
    vs_check 원천해시 "이전 매니페스트가 검증한 해시와 다릅니다"
    printf '판정\t실패\t%s\n' "$VS_FAILED"; exit 1
  fi
  pid=$(MANIFEST="$prev" manifest_hdr_field 'run-id')
  pbase=$(cd "$(dirname "$RK_POS2")/../.." 2>/dev/null && pwd)
  pgrant="$pbase/docs/pipeline-grant/$pid.md"
  RK_BASE="$pbase"; RK_PREV="$pid"
  local setwhy
  VS_SETS="$RK_TMP/vsets.tsv"
  setwhy=$(MANIFEST="$prev" rk_sets_resolve "$VS_SETS") || : > "$VS_SETS"

  # Values read from both files.
  local D_ID D_KAT D_DL D_CONFIRM P_KAT P_DL
  D_ID=$(MANIFEST="$draft" manifest_field '런 정체' '런 id')
  D_KAT=$(MANIFEST="$draft" manifest_field '런 정체' '킥오프 일시')
  D_DL=$(MANIFEST="$draft" manifest_field '인가' '벽시계 마감')
  D_CONFIRM=$(MANIFEST="$draft" manifest_field '런 정체' '사용자 확인 문면')
  P_KAT=$(MANIFEST="$prev" manifest_field '런 정체' '킥오프 일시')
  P_DL=$(MANIFEST="$prev" manifest_field '인가' '벽시계 마감')

  # 1 — the target rows.
  local prow drow al dal paliases daliases f pv dv cutans
  why=""
  paliases=$(MANIFEST="$prev" target_aliases | sort)
  daliases=$(MANIFEST="$draft" target_aliases | sort)
  while IFS= read -r al; do
    [ -n "$al" ] || continue
    vs_in "$al" "$paliases" && continue
    [ -n "$(rk_asked_answer "대상추가 $al")" ] || why="${why:+$why; }대상 $al 은 원천에 없고 확인된 대상 추가가 아닙니다"
  done <<EOF
$daliases
EOF
  while IFS= read -r al; do
    [ -n "$al" ] || continue
    vs_in "$al" "$daliases" || { why="${why:+$why; }원천 대상 $al 이 초안에 없습니다"; continue; }
    prow=$(MANIFEST="$prev" manifest_targets | grep -F "별칭=$al " | head -n 1)
    drow=$(MANIFEST="$draft" manifest_targets | grep -F "별칭=$al " | head -n 1)
    [ "$prow" = "$drow" ] && continue
    cutans=$(rk_asked_answer "7.7 절단점 $al")
    for f in 별칭 홈 절단점 '리뷰 정책 상한' '말단 행위 상한' 'dev 식별자' '배포트리거 식별자'; do
      pv=$(manifest_row_fields "$prow" "$f" | head -n 1); dv=$(manifest_row_fields "$drow" "$f" | head -n 1)
      [ "$pv" = "$dv" ] && continue
      if [ "$f" = "절단점" ] && [ -n "$cutans" ] && [ "$dv" = "$cutans" ]; then continue; fi
      if [ -z "$pv" ] && vs_set_is "$al" "$f" "$dv"; then continue; fi
      why="${why:+$why; }대상 $al 의 $f 가 원천과 다릅니다"
    done
    if [ -z "$(rk_asked_answer "대상확인 $al")" ]; then
      for f in '메인 워크트리' '공통 git 디렉터리' '베이스 브랜치' '원격 슬러그' '실행 워크트리'; do
        pv=$(manifest_row_fields "$prow" "$f" | head -n 1); dv=$(manifest_row_fields "$drow" "$f" | head -n 1)
        [ "$pv" = "$dv" ] || why="${why:+$why; }대상 $al 의 $f 가 다시 확인 없이 바뀌었습니다"
      done
    fi
  done <<EOF
$paliases
EOF
  vs_check 대상 "$why"

  # 2 — values that are byte-identical to the previous run.
  local k pval dval ks
  why=""
  [ "$(MANIFEST="$prev" rk_intent)" = "$(MANIFEST="$draft" rk_intent)" ] || why="${why:+$why; }## 의도 가 다릅니다"
  [ "$(MANIFEST="$prev" manifest_field '인가' '종료 지점')" = "$(MANIFEST="$draft" manifest_field '인가' '종료 지점')" ] \
    || why="${why:+$why; }종료 지점이 다릅니다"
  [ "$(MANIFEST="$prev" manifest_clause_rows_raw)" = "$(MANIFEST="$draft" manifest_clause_rows_raw)" ] \
    || why="${why:+$why; }종료 절 행이 다릅니다"
  # A field the previous run left empty may differ only by the value 5o
  # confirmed for it (`--set`); the draft is compared with that value.
  for ks in '인가:비용 천장' '인가:무진전 상한' '인가:사다리 가용 단 수' '인가:미선언 상황 처분' \
            '요소:적용 지점' '요소:적용 프로브' '요소:적용 주체'; do
    k=${ks#*:}
    pval=$(MANIFEST="$prev" manifest_field "${ks%%:*}" "$k"); dval=$(MANIFEST="$draft" manifest_field "${ks%%:*}" "$k")
    [ "$pval" = "$dval" ] && continue
    if [ -z "$pval" ] && vs_set_is 런 "$k" "$dval"; then continue; fi
    why="${why:+$why; }$k 가 원천과 다릅니다"
  done
  # The apply mapping row is the previous row, or none — except where the
  # previous row cannot be carried, and then the draft's row is 5c's answer,
  # compared with the confirmed `--set` value. A draft there with no such value
  # is refused: it would freeze with only 불필요=0 defined, and every needed
  # apply of the new run would stop before its command.
  local acset dac
  if MANIFEST="$prev" apply_code_row_reask; then
    acset=$(awk -F '\t' '$5 == "apply-probe-codes" { print $4 }' "$VS_SETS" 2>/dev/null)
    dac=$(MANIFEST="$draft" manifest_apply_code_rows)
    if [ -n "$acset" ]; then
      [ -n "$dac" ] && [ "$(manifest_row_fields "$dac" '불필요' 1 | head -1)/$(manifest_row_fields "$dac" '필요' 1 | head -1)" = "$acset" ] \
        || why="${why:+$why; }적용 프로브 코드 행이 확인한 대응 $acset 과 다릅니다"
    else
      why="${why:+$why; }원천의 적용 프로브 코드 행을 이어받을 수 없어 5c 로 다시 물은 대응(--set 런:apply-probe-codes)이 필요합니다"
    fi
  else
    [ "$(MANIFEST="$prev" manifest_apply_code_rows)" = "$(MANIFEST="$draft" manifest_apply_code_rows)" ] \
      || why="${why:+$why; }적용 프로브 코드 행이 원천과 다릅니다"
  fi
  local prules drules rl rk rv
  prules=$(MANIFEST="$prev" manifest_rule_lines | sort); drules=$(MANIFEST="$draft" manifest_rule_lines | sort)
  if [ "$prules" != "$drules" ]; then
    while IFS= read -r rl; do
      [ -n "$rl" ] || continue
      vs_in "$rl" "$prules" && continue
      rk=${rl#\*\*}; rk=${rk%%\*\**}; rv=${rl##*: }
      [ "$(rk_asked_answer "7.7 룰 $rk")" = "$rv" ] && continue
      why="${why:+$why; }룰 설정 줄이 원천과 다릅니다: $rl"
    done <<EOF
$drules
EOF
    while IFS= read -r rl; do
      [ -n "$rl" ] || continue
      vs_in "$rl" "$drules" && continue
      rk=${rl#\*\*}; rk=${rk%%\*\**}
      [ -n "$(rk_asked_answer "7.7 룰 $rk")" ] && continue
      why="${why:+$why; }원천 룰 설정 줄이 빠졌습니다: $rl"
    done <<EOF
$prules
EOF
  fi
  vs_check 고정값 "$why"

  # 2b — each value 5o confirmed: the same scope, key and value as one `빈칸`
  # row 5o showed, asked at 5o for that scope, written whole beside the answers,
  # and carried by the draft where the previous run had none.
  local ssc ssec sf sv sk sdv srsc
  why="$setwhy"
  if [ -z "$why" ] && [ -s "$VS_SETS" ]; then
    why=$(vs_load_blanks '--set') || :
    [ -n "$why" ] || VS_BLANKS="$RK_TMP/blanks.tsv"
  fi
  if [ -z "$why" ]; then
    while IFS="$TAB" read -r ssc ssec sf sv sk srsc; do
      [ -n "$ssc" ] || continue
      # The mapping has a second source: where 5o offered no `빈칸` row for it
      # (no file value, so `--carry` named the key `다시 물음`) or the person did
      # not confirm the offered one, 5c is asked and its answer, recorded under
      # `5c`, is the value — the same one `--set` carries.
      if [ "$sk" = "apply-probe-codes" ] && [ -n "$(rk_asked_answer '5c')" ]; then
        [ "$(rk_asked_answer '5c')" = "$sv" ] || why="${why:+$why; }$srsc:$sk 의 확정값이 5c 답과 다릅니다"
      else
        MANIFEST="$prev" vs_blank_has "$ssc" "$sk" "$sv" \
          || why="${why:+$why; }$srsc:$sk 의 확정값이 5o 에서 확인한 빈칸 행과 다릅니다"
        [ -n "$(rk_asked_answer "5o $srsc:$sk")" ] || why="${why:+$why; }$srsc:$sk 는 5o 에서 묻지 않은 값입니다"
      fi
      case " / $D_CONFIRM / " in *" / $srsc:$sk=$sv / "*) ;; *) why="${why:+$why; }$ssc:$sk 의 확정값이 사용자 확인 문면에 없습니다" ;; esac
      if [ "$ssec" = "대상" ]; then sdv=$(MANIFEST="$draft" target_field "$ssc" "$sf")
      elif [ "$sk" = "apply-probe-codes" ]; then
        dac=$(MANIFEST="$draft" manifest_apply_code_rows | head -n 1)
        sdv="$(manifest_row_fields "$dac" '불필요' 1 | head -1)/$(manifest_row_fields "$dac" '필요' 1 | head -1)"
      else sdv=$(MANIFEST="$draft" manifest_field "$ssec" "$sf"); fi
      [ "$sdv" = "$sv" ] || why="${why:+$why; }초안의 $ssc:$sk 가 확정값이 아닙니다"
    done < "$VS_SETS"
  fi
  vs_check 확정값 "$why"

  # 3 — exactly one provenance row, naming the previous run and its hashes.
  # Under `--auto` the row is the seven-field one recomputed here from the
  # previous manifest and its ledger; without it, only the four-field row.
  local crow ncr wantrow
  crow=$(MANIFEST="$draft" rk_carry_rows); ncr=$(printf '%s' "$crow" | grep -c . || true)
  wantrow="- \`사전 인가\` | 이어받은 런=$pid | 매니페스트 sha256=$RK_XSHA | 인가 기록 sha256=$RK_XGSHA"
  why=""
  if [ "$RK_AUTO" = "1" ]; then
    rk_chain "$prev" "$pbase/docs/pipeline-run/$pid.md" "$pid"
    if [ -n "$RK_CH_WHY" ]; then why="좌석 연쇄를 다시 낼 수 없습니다 — $RK_CH_WHY"
    elif [ -z "$RK_CH_CAUSE" ]; then why="원천 런의 종료 토큰을 읽지 못했습니다"
    else wantrow="$wantrow | 좌석 연쇄=$RK_CH_K | 뿌리 런=$RK_CH_ROOT | 원인=$RK_CH_CAUSE"; fi
  fi
  if [ -n "$why" ]; then :
  elif [ "${ncr:-0}" != "1" ]; then why="출처 행이 ${ncr:-0}개입니다"
  elif [ "$crow" != "$wantrow" ]; then
    why="출처 행이 이전 런과 그 해시를 가리키지 않습니다"
  fi
  vs_check 출처 "$why"

  # 3b — the consent row is the previous one, byte for byte, so neither the cap
  # nor the length widens along the seat's chain.
  if [ "$RK_AUTO" = "1" ]; then
    why=""
    [ "$(MANIFEST="$prev" manifest_rekick_rows)" = "$(MANIFEST="$draft" manifest_rekick_rows)" ] \
      || why="재킥오프 동의 행이 원천과 다릅니다"
    vs_check 동의 "$why"
  fi

  # 4 — the base binding.
  local pbd dbd bind bdoc bnow
  pbd=$(MANIFEST="$prev" manifest_base_design_rows); dbd=$(MANIFEST="$draft" manifest_base_design_rows)
  why=""
  if [ "$pbd" != "$dbd" ]; then
    bind=$(rk_asked_answer '7.8')
    bdoc=$(manifest_row_fields "$pbd" '문서' | head -n 1)
    bnow=""; [ -n "$bdoc" ] && bnow=$(rk_sha "$pbase/$bdoc")
    case "$bind" in
      묶는다*)
        [ -n "$bnow" ] && [ "$(printf '%s' "$pbd" | sed "s/sha256=[0-9a-f]*/sha256=$bnow/")" = "$dbd" ] \
          || why="베이스 설계 행이 지금 해시로 묶은 것과 다릅니다" ;;
      *) why="베이스 설계 행이 원천과 다릅니다" ;;
    esac
  fi
  vs_check 베이스설계 "$why"

  # 5 — every answer stands verbatim in the confirmation text.
  local qk qa
  why=""
  while IFS="$TAB" read -r qk qa; do
    [ -n "$qk" ] || continue
    case "$D_CONFIRM" in *"$qa"*) ;; *) why="${why:+$why; }$qk 의 답이 사용자 확인 문면에 없습니다" ;; esac
  done < "$RK_ASKED"
  vs_check 확인문면 "$why"

  # 6 — the roster is a subset of the previous one.
  local prost row
  prost=$(MANIFEST="$prev" manifest_design_roster_rows_anywhere)
  why=""
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    vs_in "$row" "$prost" || why="${why:+$why; }원천에 없는 설계 로스터 행: $row"
  done <<EOF
$(MANIFEST="$draft" manifest_design_roster_rows_anywhere)
EOF
  vs_check 로스터 "$why"

  # 7 — `사전 인가`, `자동 채택` and `라벨 인정` rows are the previous ones, or
  # covered. 5u is one question per (target, check) pair and its answer is the
  # option label, so a `라벨 인정` row is covered by the last answer recorded
  # under its own pair key, `5u <별칭> <체크>`, reading 「인정함」.
  local prows a5p a5q a77 tail la_key
  prows=$( { MANIFEST="$prev" rk_shape_rows; MANIFEST="$prev" manifest_autoadopt_rows_anywhere; MANIFEST="$prev" manifest_label_ack_rows; } )
  a5p=$(awk -F '\t' '$1 == "5p" { print substr($0, 4) }' "$RK_ASKED")
  a5q=$(awk -F '\t' '$1 == "5q" { print substr($0, 4) }' "$RK_ASKED")
  a77=$(awk -F '\t' '$1 == "7.7 자동채택" { print substr($0, length($1) + 2) }' "$RK_ASKED")
  why=""
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    vs_in "$row" "$prows" && continue
    tail=${row#*\` | }
    case "$row" in
      '- `사전 인가`'*) [ -n "$a5p" ] && case "$a5p" in *"$tail"*) true ;; *) false ;; esac && continue ;;
      '- `자동 채택`'*)
        { [ -n "$a5q" ] && case "$a5q" in *"$tail"*) true ;; *) false ;; esac; } && continue
        { [ -n "$a77" ] && case "$a77" in *"$tail"*) true ;; *) false ;; esac; } && continue ;;
      '- `라벨 인정`'*)
        la_key="5u $(manifest_row_fields "$row" '대상' | head -n 1) $(manifest_row_fields "$row" '체크' | head -n 1)"
        [ "$(rk_asked_answer "$la_key")" = "인정함" ] && continue ;;
    esac
    why="${why:+$why; }원천에 없고 답으로 덮이지 않은 행: $row"
  done <<EOF
$( { MANIFEST="$draft" rk_shape_rows; MANIFEST="$draft" manifest_autoadopt_rows_anywhere; MANIFEST="$draft" manifest_label_ack_rows; } )
EOF
  # The seat neither asks 5u nor adds a `라벨 인정` row: a row is a
  # pre-authorization that opens the label act with no person, so in seat mode
  # a 5u key of its own is refused and the draft's rows are the previous ones
  # byte for byte, in order.
  if [ "$RK_AUTO" = "1" ]; then
    [ -n "$RK_ASKED" ] && awk -F '\t' '$1 ~ /^5u / { f = 1 } END { exit !f }' "$RK_ASKED" \
      && why="${why:+$why; }좌석은 5u 를 묻지 않습니다 — --asked 에 5u 키가 있습니다"
    [ "$(MANIFEST="$draft" manifest_label_ack_rows)" = "$(MANIFEST="$prev" manifest_label_ack_rows)" ] \
      || why="${why:+$why; }좌석은 라벨 인정 행을 바꾸지 않습니다 — 초안의 라벨 인정 행이 원천과 바이트 단위로 다릅니다"
  fi
  vs_check 행 "$why"

  # 7b — the `플러그인 허용` rows. P is the previous rows whose key is on or
  # cannot be judged now, derived again here from this call's own reading of
  # the account set; D is the draft's rows. A person's draft holds every row of
  # P byte for byte, and any other row is a default 5o confirmed for a blank.
  # The seat's draft may differ from P only where a change of the account set
  # between the render and this call explains it: each such row is named on
  # stderr and passes, and any other difference fails.
  local pa_prev pa_p pa_d pa_k pa_st pa_sc pa_dups pa_bwhy=''
  why=""
  rk_pa_judge
  pa_prev=$(MANIFEST="$prev" manifest_plugin_allow_rows)
  pa_d=$(MANIFEST="$draft" manifest_plugin_allow_rows)
  pa_p=''
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    case "$(rk_pa_state "$(rk_pa_key "$row")")" in 켬|'판정 불가'*) pa_p="$pa_p$row
" ;; esac
  done <<EOF
$pa_prev
EOF
  pa_dups=$(printf '%s\n' "$pa_d" | while IFS= read -r row; do [ -n "$row" ] && rk_pa_key "$row" && printf '\n'; done | sort | uniq -d | paste -sd, -)
  [ -z "$pa_dups" ] || why="${why:+$why; }초안에 같은 플러그인의 행이 둘 이상입니다: $pa_dups"
  if [ "$RK_AUTO" = "1" ]; then
    while IFS= read -r row; do
      [ -n "$row" ] || continue
      vs_in "$row" "$pa_p" && continue
      pa_k=$(rk_pa_key "$row"); pa_st=$(rk_pa_state "$pa_k")
      if vs_in "$row" "$pa_prev" && [ "$pa_st" = "미설치" ]; then
        printf '플러그인 알림\t초안에 남은 미설치 행\t%s\n' "$pa_k" >&2
      else
        why="${why:+$why; }앞선 런의 행을 다시 판정한 결과로 설명되지 않는 행입니다 (지금 ${pa_st%%"$TAB"*}): $row"
      fi
    done <<EOF
$pa_d
EOF
    while IFS= read -r row; do
      [ -n "$row" ] || continue
      vs_in "$row" "$pa_d" && continue
      pa_k=$(rk_pa_key "$row"); pa_st=$(rk_pa_state "$pa_k")
      case "$pa_st" in
        켬) printf '플러그인 알림\t초안에서 빠진 켬 행\t%s\n' "$pa_k" >&2 ;;
        *)  printf '플러그인 알림\t초안에서 빠진 판정 불가 행\t%s\t%s\n' "$pa_k" "${pa_st#*"$TAB"}" >&2 ;;
      esac
    done <<EOF
$pa_p
EOF
  else
    while IFS= read -r row; do
      [ -n "$row" ] || continue
      vs_in "$row" "$pa_d" || why="${why:+$why; }앞선 런에서 이어 써야 할 행이 초안에 없습니다: $row"
    done <<EOF
$pa_p
EOF
    while IFS= read -r row; do
      [ -n "$row" ] || continue
      vs_in "$row" "$pa_p" && continue
      pa_k=$(rk_pa_key "$row")
      if [ "$row" != "- \`플러그인 허용\` | 플러그인=$pa_k | 사유=킥오프 기본값" ]; then
        why="${why:+$why; }앞선 런에 없고 5o 에서 확정한 기본값의 행 모양이 아닙니다: $row"; continue
      fi
      if [ -z "$VS_BLANKS" ] && [ -z "$pa_bwhy" ]; then
        pa_bwhy=$(vs_load_blanks '앞선 런에 없는 플러그인 허용 행') || :
        if [ -n "$pa_bwhy" ]; then why="${why:+$why; }$pa_bwhy"; else VS_BLANKS="$RK_TMP/blanks.tsv"; fi
      fi
      [ -n "$VS_BLANKS" ] || continue
      pa_sc=$(PK="$pa_k" awk -F '\t' '$1 == "빈칸" && $3 == "plugin-allow" && $4 == ENVIRON["PK"] { print $2; exit }' "$VS_BLANKS")
      if [ -z "$pa_sc" ]; then why="${why:+$why; }플러그인 $pa_k 는 5o 가 보인 빈칸 행이 아닙니다"; continue; fi
      [ -n "$(rk_asked_answer "5o $pa_sc:plugin-allow=$pa_k")" ] || why="${why:+$why; }$pa_sc:plugin-allow=$pa_k 는 5o 에서 묻지 않은 값입니다"
      case " / $D_CONFIRM / " in *" / $pa_sc:plugin-allow=$pa_k / "*) ;; *) why="${why:+$why; }$pa_sc:plugin-allow=$pa_k 가 사용자 확인 문면에 없습니다" ;; esac
      pa_st=$(rk_pa_state "$pa_k")
      [ "$pa_st" = "켬" ] || why="${why:+$why; }플러그인 $pa_k 가 지금 켬이 아닙니다 (${pa_st%%"$TAB"*})"
    done <<EOF
$pa_d
EOF
  fi
  vs_check 플러그인 "$why"

  # 8 — the interview row: exactly one when the design step stays, none when it
  # is out, and the previous row with only its path renamed.
  local dplan hasd piv div want niv
  dplan=$(MANIFEST="$draft" manifest_plan_json)
  hasd=$(printf '%s' "$dplan" | jq -r '[.steps[]? | select(type == "object" and .skill == "design")] | length' 2>/dev/null)
  piv=$(MANIFEST="$prev" rk_interview_rows); div=$(MANIFEST="$draft" rk_interview_rows)
  niv=$(printf '%s' "$div" | grep -c . || true)
  why=""
  if [ "${hasd:-0}" -ge 1 ]; then
    if [ "${niv:-0}" != "1" ]; then why="설계 단계가 남는데 인터뷰 행이 ${niv:-0}개입니다"
    else
      want=$(printf '%s' "$piv" | awk -v p="docs/pipeline-run/$D_ID.interview.md" '{ sub(/인터뷰 기록=[^|]*\|/, "인터뷰 기록=" p " |"); print }')
      [ -n "$piv" ] && [ "$div" = "$want" ] || why="인터뷰 행이 원천 행에서 경로만 새 런으로 바꾼 것이 아닙니다"
    fi
  else
    [ "${niv:-0}" = "0" ] || why="설계 단계가 빠졌는데 인터뷰 행이 남았습니다"
  fi
  vs_check 인터뷰 "$why"

  # 9 — re-asked pre-authorization belongs to a confirmed added target.
  why=""
  if [ -n "$a5p$a5q" ] && ! awk -F '\t' '$1 ~ /^대상추가 / { f = 1 } END { exit !f }' "$RK_ASKED"; then
    why="5p·5q 답이 있는데 확인된 대상 추가가 없습니다"
  fi
  # A 5u answer is asked again for an added target or for a target whose
  # cutpoint 7.7 raised to a merge or above, and for nothing else: every
  # `5u <별칭> <체크>` key needs a `대상추가 <별칭>` or `7.7 절단점 <별칭>` key
  # for the same alias, compared whole.
  local la_bare=""
  [ -n "$RK_ASKED" ] && la_bare=$(awk -F '\t' '
    $1 ~ /^(대상추가|7\.7 절단점) / { a = $1; sub(/^(대상추가|7\.7 절단점) /, "", a); ok[a] = 1; next }
    $1 ~ /^5u / { a = substr($1, 4); sub(/ .*/, "", a); n++; t[n] = a }
    END { for (i = 1; i <= n; i++) if (!(t[i] in ok)) print t[i] }' "$RK_ASKED" | sort -u | tr '\n' ' ')
  if [ -n "$la_bare" ]; then
    why="${why:+$why; }5u 답이 있는데 그 대상의 확인된 대상 추가도 7.7 절단점 답도 없습니다: ${la_bare% }"
  fi
  vs_check 대상추가 "$why"

  # 10 — the deadline keeps the interval, unless 5e was asked. Then the draft's
  # deadline is the instant the answer was resolved to (`5e 값`), compared as an
  # instant: the answer itself may be a relative form no draft can equal.
  local a5e v5e pe pk de dk ve
  a5e=$(rk_asked_answer '5e'); v5e=$(rk_asked_answer '5e 값')
  why=""
  if [ -n "$a5e" ] || [ -n "$v5e" ]; then
    de=$(rk_wide_instant "$D_DL"); ve=$(rk_wide_instant "$v5e")
    if [ -z "$a5e" ]; then why="5e 값은 있는데 5e 답이 없습니다"
    elif [ -z "$v5e" ]; then why="5e 를 물었는데 해석한 마감(5e 값)이 없습니다"
    elif [ -z "$de" ] || [ -z "$ve" ]; then why="마감이나 5e 값을 시각으로 읽지 못했습니다"
    elif [ "$de" != "$ve" ]; then why="5e 를 물었는데 마감이 그 답을 해석한 시각이 아닙니다"
    fi
  elif [ "$RK_AUTO" = "1" ]; then
    # The seat's deadline is the previous interval, or the consent row's
    # length — what the kickoff helper's `--carry --auto` falls back to — both
    # measured from the draft's kickoff. A previous deadline the reader cannot
    # place does not fail first: the length still decides.
    local plen lsec
    pe=$(rk_wide_instant "$P_DL"); pk=$(rk_wide_instant "$P_KAT")
    de=$(rk_wide_instant "$D_DL"); dk=$(rk_wide_instant "$D_KAT")
    plen=$(MANIFEST="$prev" manifest_rekick_rows | head -n 1)
    plen=$(manifest_row_fields "$plen" '길이' | head -n 1)
    lsec=""; [ -n "$plen" ] && lsec=$(dr_duration_seconds "$plen" 2>/dev/null)
    if [ -z "$de" ] || [ -z "$dk" ]; then why="초안의 마감이나 킥오프 일시를 시각으로 읽지 못했습니다"
    elif [ -n "$pe" ] && [ -n "$pk" ] && [ $((de - dk)) = $((pe - pk)) ]; then :
    elif [ -n "$lsec" ] && [ $((de - dk)) = "$lsec" ]; then :
    else why="마감 간격이 원천 간격과도 재킥오프 행의 길이와도 다릅니다 ($((de - dk)))"
    fi
  else
    pe=$(rk_wide_instant "$P_DL"); pk=$(rk_wide_instant "$P_KAT")
    de=$(rk_wide_instant "$D_DL"); dk=$(rk_wide_instant "$D_KAT")
    if [ -z "$pe" ] || [ -z "$pk" ] || [ -z "$de" ] || [ -z "$dk" ]; then why="마감이나 킥오프 일시를 시각으로 읽지 못했습니다"
    elif [ $((de - dk)) != $((pe - pk)) ]; then why="마감 간격이 원천과 다릅니다 ($((de - dk)) ≠ $((pe - pk)))"
    fi
  fi
  vs_check 마감 "$why"

  # 11·12 — no design step means no design required; no broken dependency.
  why=""
  if [ "${hasd:-0}" = "0" ] && [ "$(printf '%s' "$dplan" | jq -r '.design_required' 2>/dev/null)" = "true" ]; then
    why="설계 단계가 없는데 design_required 가 true 입니다"
  fi
  vs_check 설계 "$why"
  why=""
  printf '%s' "$dplan" | jq -e '[.steps[]? | select(type == "object")] as $s | ([$s[] | (.depends_on // [])[]] - [$s[].id] | length) == 0' >/dev/null 2>&1 \
    || why="지운 단계를 가리키는 depends_on 이 있습니다"
  vs_check 의존 "$why"

  # The new authorization block, when given.
  if [ -n "$RK_GRANT_BLOCK" ]; then
    local gid gcut dmax gf gv
    gid=$(sed -n 's/^## 인가 //p' "$RK_GRANT_BLOCK" | head -n 1 | sed 's/[[:space:]]*$//')
    why=""
    [ "$gid" = "$D_ID" ] || why="${why:+$why; }블록 id($gid)가 새 런 id($D_ID)가 아닙니다"
    for gf in '인가 일시' '종료 지점' '권한 절단점' '말단 행위 상한' '직렬 웨이브 고지' \
              '시각 정합 마커' '사용자 확인 문면' '설계 문서 전체 sha256' '보고서'; do
      gv=$(awk -v k="$gf" 'index($0, "**" k "**: ") == 1 { print substr($0, length(k) + 7); exit }' "$RK_GRANT_BLOCK")
      [ -n "$gv" ] || why="${why:+$why; }블록에 $gf 가 없습니다"
    done
    gcut=$(awk 'index($0, "**권한 절단점**: ") == 1 { print substr($0, length("권한 절단점") + 7); exit }' "$RK_GRANT_BLOCK")
    dmax=$(rk_cut_max "$(MANIFEST="$draft" manifest_targets)")
    [ -n "$gcut" ] && [ "$gcut" = "$(MANIFEST="$draft" manifest_field '인가' '런 최대 절단점')" ] && [ "$gcut" = "$dmax" ] \
      || why="${why:+$why; }권한 절단점이 초안의 런 최대 절단점·대상 절단점의 최댓값과 다릅니다"
    for gf in '종료 지점:인가' '사용자 확인 문면:런 정체' '설계 문서 전체 sha256:요소'; do
      gv=$(awk -v k="${gf%%:*}" 'index($0, "**" k "**: ") == 1 { print substr($0, length(k) + 7); exit }' "$RK_GRANT_BLOCK")
      [ "$gv" = "$(MANIFEST="$draft" manifest_field "${gf#*:}" "${gf%%:*}")" ] \
        || why="${why:+$why; }${gf%%:*} 가 초안과 다릅니다"
    done
    vs_check 인가블록 "$why"
  fi

  # 13 — the adoption rows: inside `## 인가`, one per segment, naming the
  # previous run, and each the row a candidate derived again here, on the same
  # branch and over the draft's targets, would make. A person answered each
  # candidate with one of its two labels and the row stands exactly where the
  # answer took it; the seat asked nothing and wrote a subset of the candidates.
  local arows ain aout cands akey arow cline cb cw cn ch aans take redo
  why=""
  arows=$(MANIFEST="$draft" manifest_adoption_rows)
  ain=$(awk '/^## / { sec = $0; next } sec == "## 인가" && /^- `세그먼트 입양`/' "$draft")
  [ "$arows" = "$ain" ] || why="${why:+$why; }## 인가 밖에 세그먼트 입양 행이 있습니다"
  rk_prev_paths
  cands=$(MANIFEST="$prev"; rk_graph_compute; rk_adopt_candidates "$(MANIFEST="$draft" manifest_targets)" full)
  while IFS= read -r arow; do
    [ -n "$arow" ] || continue
    akey=$(manifest_row_fields "$arow" '세그먼트' | head -n 1)
    [ "$(printf '%s\n' "$arows" | { grep -F -- "| 세그먼트=$akey |" || true; } | grep -c .)" = "1" ] \
      || why="${why:+$why; }세그먼트 $akey 의 입양 행이 하나가 아닙니다"
    [ "$(manifest_row_fields "$arow" '출처 런' | head -n 1)" = "$pid" ] \
      || why="${why:+$why; }세그먼트 $akey 의 입양 행이 원천 런 $pid 를 출처로 적지 않습니다"
    cline=$(printf '%s\n' "$cands" | awk -F '\t' -v k="$akey" '$1 == "입양후보" && $2 == k')
    if [ -z "$cline" ]; then why="${why:+$why; }세그먼트 $akey 는 지금 다시 유도한 입양 후보가 아닙니다"; continue; fi
    IFS="$TAB" read -r _ _ cb cw cn ch _ <<EOF
$cline
EOF
    [ "$arow" = "$(RK_PREV=$pid rk_adopt_row "$akey" "$cb" "$cw" "$cn")" ] \
      || why="${why:+$why; }세그먼트 $akey 의 입양 행이 다시 유도한 행과 다릅니다"
  done <<EOF
$arows
EOF
  # A source that met every termination clause is re-kicked only to adopt a
  # segment it left unmerged: a draft that adopts none of its segments would
  # run the remaining graph of a finished run again.
  if rk_clauses_all_met "$(MANIFEST="$prev" rk_clause_states "$RK_PL")" \
    && ! printf '%s\n' "$arows" | awk -v p="$pid" '
        { n = split($0, a, / [|] /); for (i = 2; i <= n; i++) if (a[i] == "출처 런=" p) f = 1 }
        END { exit !f }'; then
    why="${why:+$why; }원천 런 $pid 은 완료 기준을 모두 채웠습니다 — 이어받는 세그먼트가 없는 초안은 받지 않습니다"
  fi
  if [ "$RK_AUTO" = "1" ]; then
    awk -F '\t' '$1 ~ /^입양 / { f = 1 } END { exit !f }' "$RK_ASKED" \
      && why="${why:+$why; }좌석은 입양을 묻지 않습니다 — --asked 에 입양 키가 있습니다"
  else
    while IFS="$TAB" read -r _ akey cb cw cn ch _; do
      [ -n "$akey" ] || continue
      take=$(rk_adopt_take_label "$akey" "$cn" "$cb" "$ch"); redo=$(rk_adopt_redo_label "$akey" "$cn")
      aans=$(rk_asked_answer "입양 $akey")
      arow=$(printf '%s\n' "$arows" | { grep -F -- "| 세그먼트=$akey |" || true; } | head -n 1)
      if [ -z "$aans" ]; then why="${why:+$why; }입양 후보 $akey 에 답이 없습니다"
      elif [ "$aans" = "$take" ]; then [ -n "$arow" ] || why="${why:+$why; }입양 $akey 의 답이 이어받기인데 입양 행이 없습니다"
      elif [ "$aans" = "$redo" ]; then [ -z "$arow" ] || why="${why:+$why; }입양 $akey 의 답이 다시 하기인데 입양 행이 있습니다"
      else why="${why:+$why; }입양 $akey 의 답이 두 라벨 어느 것과도 같지 않습니다"
      fi
    done <<EOF
$(printf '%s\n' "$cands" | awk -F '\t' '$1 == "입양후보"')
EOF
    while IFS= read -r akey; do
      [ -n "$akey" ] || continue
      printf '%s\n' "$cands" | awk -F '\t' -v k="$akey" '$1 == "입양후보" && $2 == k { f = 1 } END { exit !f }' \
        || why="${why:+$why; }입양 $akey 는 입양 후보가 아닌 세그먼트의 키입니다"
    done <<EOF
$(awk -F '\t' '$1 ~ /^입양 / { print substr($1, length("입양 ") + 1) }' "$RK_ASKED" | awk '!seen[$0]++')
EOF
  fi
  vs_check 입양 "$why"

  # Last — the previous files measured again, against the provenance row.
  why=""
  [ "$(rk_sha "$RK_POS2")" = "$RK_XSHA" ] || why="${why:+$why; }이전 매니페스트가 바뀌었습니다"
  [ "$(rk_sha "$pgrant")" = "$RK_XGSHA" ] || why="${why:+$why; }이전 인가 기록이 바뀌었습니다"
  vs_check 원천해시 "$why"

  if [ -z "$VS_FAILED" ]; then printf '판정\t통과\n'; exit 0; fi
  printf '판정\t실패\t%s\n' "$VS_FAILED"
  exit 1
}

# ---------------------------------------------------------------------------
# adopt — the candidate lines, read-only.
# ---------------------------------------------------------------------------
rk_adopt() {
  rk_prev_paths
  MANIFEST=$(rk_copy "$RK_PM" prev.plan.md) || rk_fail "원천 매니페스트를 읽을 수 없습니다: $RK_PM"
  [ "$(rk_sha "$MANIFEST")" = "$RK_XSHA" ] \
    || rk_fail "원천 매니페스트가 검증한 해시와 다릅니다 — 검증 뒤에 바뀐 파일은 이어받지 않습니다"
  rk_graph_compute
  [ -n "$G_PLAN" ] || rk_fail "원천 매니페스트의 실행 계획을 읽지 못했습니다"
  local trows
  if [ -n "$RK_TARGETS" ]; then trows=$(grep -E '^- `target`' "$RK_TARGETS" 2>/dev/null || true); else trows=$(manifest_targets); fi
  rk_adopt_candidates "$trows" full > "$RK_TMP/adopt.out"
  printf 'cc-rekick v1\n'
  cat "$RK_TMP/adopt.out"
  exit 0
}

case "$RK_MODE" in
  adopt)            rk_adopt ;;
  detect)           rk_detect ;;
  judge)            rk_judge ;;
  verify)           rk_verify ;;
  graph)            rk_graph ;;
  render-manifest)  rk_render_manifest ;;
  render-interview) rk_render_interview ;;
  verify-subset)    rk_verify_subset ;;
esac
