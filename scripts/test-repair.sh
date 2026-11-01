#!/usr/bin/env bash
# Test `repair.sh render`, the renderer of the run the fleet's master stage
# starts to fix a failure on a repository's base branch.
#
# WHAT IS MEASURED. The rendered manifest and authorization record pass the
# driver's manifest and grant checks and the gate's grant check from the target
# repository's worktree; the driver, with every stage stubbed, walks the fixed
# graph from that manifest — the solo design is dispatched once to the document
# path the manifest names, the audit is skipped without parking, and the run
# reaches its segment cycle with the merge authorized by the rendered record; a
# confirmation text changed by one character
# and one more preauthorization row are each refused by the gate's grant check.
# The inputs are refused at the shapes the renderer holds them to, and the
# signatures reach the manifest only as a path, a count and a digest.
#
# Usage: bash scripts/test-repair.sh

set -uo pipefail

# THE RUN NOTIFIER IS OFF FOR THIS WHOLE PROCESS. This suite runs the gate's
# grant check and the driver, both of which can fire a banner.
CC_CMDS_AUTOPILOT_NOTIFY=0
export CC_CMDS_AUTOPILOT_NOTIFY
# The dashboard server is off too: the driver's run-open branch would start it.
CC_CMDS_DASHBOARD=off
export CC_CMDS_DASHBOARD
# And the inherited pipeline names are cleared by prefix, so a run inside a
# stage never reads the stage's own ledger and manifest.
for v in $(compgen -e | grep '^CC_PIPELINE_' || true); do unset "$v"; done

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
ORCH="$repo_root/plugins/cc-cmds/orchestrator"
REPAIR="$ORCH/repair.sh"
DRIVER="$ORCH/run.sh"
GATE_SH="$ORCH/gate.sh"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/cc-repair-test.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

passed=0; failed=0
ok()   { passed=$((passed + 1)); printf 'PASS: %s\n' "$1"; }
bad()  { failed=$((failed + 1)); printf 'FAIL: %s — %s\n' "$1" "${2:-}" >&2; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got '$2', want '$3'"; fi; }

# A target repository with an origin, so the base branch resolves to a remote
# tracking ref the way the driver's preflight reads it.
REPO="$WORK/repo"; ORIGIN="$WORK/origin.git"
git init -q --bare -b main "$ORIGIN"
git init -q -b main "$REPO"
( cd "$REPO" && git config user.email t@example.invalid && git config user.name T \
    && printf 'x\n' > x.txt && git add -A && git commit -qm init \
    && git remote add origin "$ORIGIN" && git push -q origin main && git fetch -q origin ) >/dev/null 2>&1
REPO=$(cd "$REPO" && pwd -P)

STATE="$WORK/state"; mkdir -p "$STATE"
SIGS="$WORK/sigs.txt"
printf 'rest-tests|test-x|a 가 b 다\nrest-tests|test-x|c\n' > "$SIGS"
EVENT=0123456789ab
FIRST=$(printf '%040d' 0 | tr 0 a)

render() { XDG_STATE_HOME="$STATE" bash "$REPAIR" render "$@"; }
out=$(render --slug Nharu/cc-cmds --base main --event "$EVENT" --signatures "$SIGS" \
        --first-commit "$FIRST" --worktree "$REPO" 2>"$WORK/render.err"); rc=$?
check "렌더가 성공한다" "$rc" "0"
kv() { printf '%s\n' "$out" | sed -n "s/^$1=//p"; }
M=$(kv manifest); G=$(kv grant); RID=$(kv run_id)
check "매니페스트와 인가 기록이 대상 레포의 킥오프 자리에 있다" \
  "$( [ -f "$M" ] && [ -f "$G" ] && printf '%s|%s' "${M#"$REPO"/}" "${G#"$REPO"/}")" \
  "docs/pipeline-run/$RID.plan.md|docs/pipeline-grant/$RID.md"
check "런 id 는 킥오프의 모양이다" "$(printf '%s' "$RID" | grep -cE '^[0-9]{8}-[0-9a-f]{8}$')" "1"
dl_e=$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$(kv deadline)" +%s 2>/dev/null || date -u -d "$(kv deadline)" +%s)
rt_e=$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$(kv rendered_at)" +%s 2>/dev/null || date -u -d "$(kv rendered_at)" +%s)
check "마감은 렌더 시각에 REPAIR_DEADLINE_SECONDS 를 더한 값이다" \
  "$((dl_e - rt_e))" "$(sed -n 's/^readonly REPAIR_DEADLINE_SECONDS=\([0-9]*\)$/\1/p' "$REPAIR")"

# The intent carries the signatures by path, count and digest, never a line.
check "의도에 서명 줄이 없고 경로·개수·sha256 만 있다" \
  "$(grep -c -F 'a 가 b 다' "$M")|$(grep -c -F '서명 개수: 2' "$M")|$(grep -c -F "서명 파일: $STATE/cc-cmds/repair/$RID.signatures.txt" "$M")" "0|1|1"
FP=$(bash "$ORCH/ci-signature.sh" fingerprint < "$SIGS")
check "수리 사건 행의 다섯째 칸은 사건 서명의 지문이다" \
  "$(grep -c -x -F -- "- \`수리 사건\` | Nharu/cc-cmds | main | $EVENT | $FP" "$M")" "1"
DOCKEY="docs/master-repair-$EVENT.md"
check "설계 문서·두 헤더 owner-doc= 는 사건의 수리 문서 키다" \
  "$(sed -n 's/^\*\*설계 문서\*\*: //p' "$M")|$(sed -n 's/.*owner-doc=\([^;]*\);.*/\1/p' "$M")|$(sed -n '2p' "$G" | sed -n 's/.*owner-doc=\([^;]*\);.*/\1/p')" \
  "$DOCKEY|$DOCKEY|$DOCKEY"
check "설계 문서 전체 sha256 은 매니페스트와 인가 블록 모두 (해당 없음) 이다" \
  "$(sed -n 's/^\*\*설계 문서 전체 sha256\*\*: //p' "$M")|$(sed -n 's/^\*\*설계 문서 전체 sha256\*\*: //p' "$G")|$(kv doc_sha256)" \
  "(해당 없음)|(해당 없음)|(해당 없음)"
check "렌더한 실행 계획은 킥오프의 계획 검사에 걸리지 않는다" \
  "$(awk '/^```json$/ { f = 1; next } /^```$/ { f = 0 } f' "$M" | jq -f "$ORCH/prompts/entry-plan.check.jq" 2>&1; printf 'rc=%s' "$?")" "rc=0"
check "사전 인가 행은 git push·gh pr·gh api -X PUT 셋뿐이다" \
  "$(grep -E '^- `사전 인가`' "$M" | sed -n 's/^.*형태=\([^|]*\) |.*/\1/p' | tr '\n' ',')" "git push,gh pr,gh api -X PUT,"

# drv_check <manifest> <grant> — the driver's manifest and grant checks, from the
# target's worktree.
drv_check() {
  ( cd "$REPO" && CC_ORCH_SOURCE_ONLY=1 && . "$DRIVER" >/dev/null 2>&1 && set +e \
      && MANIFEST="$1" && MANIFEST_MEMO_PATH="" && MANIFEST_MEMO="" && RUN_ID="$RID" && GRANT="$2" \
      && check_manifest >/dev/null 2>&1 && check_grant >/dev/null 2>&1 && printf 'ok' ) 2>/dev/null || printf 'refused'
}
# gate_grant <manifest> <grant> — the gate's grant check; prints its rc.
gate_grant() {
  ( cd "$REPO" && CC_GATE_SOURCE_ONLY=1 bash -c 'g=$1; m=$2; gr=$3; rid=$4; set --; . "$g" >/dev/null 2>&1 || exit 9; set +e
      MANIFEST=$m; GRANT=$gr; RUN_ID=$rid; GATE_GRANT_MEMO_PATH=""; MANIFEST_MEMO_PATH=""; MANIFEST_MEMO=""
      gate_check_grant >/dev/null 2>&1; printf "%s" "$?"' _ "$GATE_SH" "$1" "$2" "$RID" ) 2>/dev/null
}
check "원본은 드라이버의 매니페스트·인가 검사를 통과한다" "$(drv_check "$M" "$G")" "ok"
check "원본은 게이트의 인가 검사를 통과한다" "$(gate_grant "$M" "$G")" "0"

# One character of the confirmation text, and one more preauthorization row.
GX="$WORK/grant-consent.md"
sed 's/^\*\*사용자 확인 문면\*\*: 호스트 수리 런 — 플러그인 기본 동의$/**사용자 확인 문면**: 호스트 수리 런 — 플러그인 기본 동이/' "$G" > "$GX"
check "변조본이 실제로 문면 한 글자만 다르다 (아래가 공허하지 않다)" \
  "$(diff "$G" "$GX" | grep -c '^[<>]')" "2"
check "승인 문면을 한 글자 바꾸면 게이트의 인가 검사가 거절한다" \
  "$( r=$(gate_grant "$M" "$GX"); [ "$r" != "0" ] && printf 'refused' || printf 'passed')" "refused"
MX="$WORK/manifest-preauth.md"
awk '{ print } index($0, "- `수리 사건`") == 1 { print "- `사전 인가` | 형태=docker build | 사유=x" }' "$M" > "$MX"
check "사전 인가 행을 하나 더하면 게이트의 인가 검사가 거절한다" \
  "$( r=$(gate_grant "$MX" "$G"); [ "$r" != "0" ] && printf 'refused' || printf 'passed')" "refused"
check "그 행은 결박 지문도 깨서 드라이버의 매니페스트 검사가 거절한다" "$(drv_check "$MX" "$G")" "refused"

# The driver walks the fixed graph from the rendered manifest. Every stage is a
# stub that ends `정상 완료`, and the design stub writes a frozen document at the
# path the manifest names; the segment plan is where this walk stops, and
# reaching it without a park is the pass.
D="$WORK/drive"; mkdir -p "$D/run/log" "$D/run/halt"
(
  cd "$REPO" || exit 9
  CC_ORCH_SOURCE_ONLY=1; . "$DRIVER" >/dev/null 2>&1; set +e
  MANIFEST="$M"; MANIFEST_MEMO_PATH=""; MANIFEST_MEMO=""; RUN_ID="$RID"
  ANCHOR_KIND=$(manifest_field '런 정체' '앵커 종류'); ANCHOR_KEY=$(manifest_field '런 정체' '앵커 키')
  derive_paths_from_manifest
  RUN_DIR="$D/run"; LEDGER="$D/ledger.md"; LEDGER_SCOPE=파일; : > "$LEDGER"
  CLI_BIN=true
  printf '%s\n' "$DOC" > "$D/doc"
  dispatch_stage() {
    printf '%s\t%s\n' "$1" "$3" >> "$D/dispatched"
    case "$3" in
      /cc-cmds:design-solo-unattended\ *)
        printf '# 수리 설계\n\n**상태**: 동결됨\n\n## 합의된 아키텍처\n- 고친다\n' > "$DOC" ;;
    esac
    printf '0' > "$RUN_DIR/$1.rc"
  }
  classify_termination() { printf '정상 완료'; }
  predicate_audit() { return 0; }
  stage_session_id() { printf 'sid'; }
  stage_parent_id() { printf 'parent'; }
  report_append() { printf '%s\n' "$*" >> "$D/report"; }
  park() { printf '%s\n' "$*" >> "$D/parked"; }
  absorb_stage_judgment() { :; }
  spawn_lineage_release() { :; }
  report_path() { printf '%s' "$D/report"; }
  # The segment plan is one segment; its cycle is where the merge disposition is
  # taken, and the stub records whether the rendered grant authorizes the merge.
  slicing_branch() { printf 'S3\n' >> "$D/s3"; printf '선언통치'; }
  plan_from_declaration() {
    printf 'RA\t-\t-\t-\t-\n' > "$RUN_DIR/plan.tsv"; : > "$RUN_DIR/done.txt"; : > "$RUN_DIR/decl-defects.tsv"
  }
  segment_cycle() {
    printf '%s|%s\n' "$1" "$(authorized 머지 && printf '머지 인가' || printf '머지 불가')" >> "$D/cycled"
    return 0
  }
  past_deadline() { return 1; }
  in_halted_radius() { return 1; }
  cross_repo_deps() { :; }
  whole_digest() { printf x; }; generation_now() { printf 1; }
  run_cycle_budget() { printf 10; }
  spawn_lease_release_run() { :; }; report_run_residual() { :; }
  main_loop
) > "$D/out" 2>&1
check "드라이버의 설계 문서 경로는 매니페스트가 지명한 경로다" \
  "$(cat "$D/doc" 2>/dev/null)" "$REPO/$DOCKEY"
check "드라이버가 그 경로로 단독 설계 스테이지를 한 번 띄운다" \
  "$( { cut -f2 "$D/dispatched" 2>/dev/null || true; } | { grep -c -F "/cc-cmds:design-solo-unattended $REPO/$DOCKEY" || true; })" "1"
check "S2 는 park 없이 감사를 건너뛴다" \
  "$(grep -c 'S2 감사 건너뜀 — solo 티어 런이 설계한 동결 문서다' "$D/out")|$( { cut -f2 "$D/dispatched" 2>/dev/null || true; } | { grep -c 'design-audit' || true; })" "1|0"
check "드라이버가 park 없이 세그먼트 계획에 이른다" \
  "$( [ -f "$D/s3" ] && printf '도달' || printf '없음')|$( [ -s "$D/parked" ] && sed -n '1p' "$D/parked" || printf 'park 없음')" \
  "도달|park 없음"
check "마지막 단계인 세그먼트 사이클이 돌고 그 머지 처분은 렌더한 인가로 인가된다" \
  "$(cat "$D/cycled" 2>/dev/null)" "RA|머지 인가"

# The inputs are held to their shapes.
refused() { render "$@" >/dev/null 2>&1 && printf 'passed' || printf 'refused'; }
check "모양 밖의 slug·브랜치·사건 id·커밋·상대 경로는 거절된다" \
  "$(refused --slug 'a|b/c' --base main --event "$EVENT" --signatures "$SIGS" --first-commit "$FIRST" --worktree "$REPO")|$(refused --slug Nharu/cc-cmds --base 'ma`in' --event "$EVENT" --signatures "$SIGS" --first-commit "$FIRST" --worktree "$REPO")|$(refused --slug Nharu/cc-cmds --base main --event 0123 --signatures "$SIGS" --first-commit "$FIRST" --worktree "$REPO")|$(refused --slug Nharu/cc-cmds --base main --event "$EVENT" --signatures "$SIGS" --first-commit abc --worktree "$REPO")|$(refused --slug Nharu/cc-cmds --base main --event "$EVENT" --signatures "$SIGS" --first-commit "$FIRST" --worktree repo)" \
  "refused|refused|refused|refused|refused"
EV2=fedcba987654
mkdir -p "$REPO/docs"; printf '# 있던 문서\n' > "$REPO/docs/master-repair-$EV2.md"
check "수리 설계 문서 자리에 파일이 이미 있으면 렌더가 실패한다" \
  "$(refused --slug Nharu/cc-cmds --base main --event "$EV2" --signatures "$SIGS" --first-commit "$FIRST" --worktree "$REPO")" "refused"
rm -f "$REPO/docs/master-repair-$EV2.md"
LONG="$WORK/long.txt"
{ printf 'a\033[31mb\n'; awk 'BEGIN { for (i = 0; i < 300; i++) printf "x"; print ""; for (i = 0; i < 150; i++) print "l" i }'; } > "$LONG"
out2=$(render --slug Nharu/cc-cmds --base main --event 00000000000a --signatures "$LONG" --first-commit "$FIRST" --worktree "$REPO" 2>/dev/null)
S2F="$STATE/cc-cmds/repair/$(printf '%s\n' "$out2" | sed -n 's/^run_id=//p').signatures.txt"
check "서명 사본은 제어 문자를 빼고 줄 200 바이트·100 줄로 자른다" \
  "$(LC_ALL=C grep -c "$(printf '\033')" "$S2F")|$(LC_ALL=C awk '{ if (length($0) > m) m = length($0) } END { print m }' "$S2F")|$(grep -c . "$S2F")" \
  "0|200|100"

printf 'test-repair: %d passed, %d failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
