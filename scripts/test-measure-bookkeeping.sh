#!/usr/bin/env bash
# Test scripts/measure-bookkeeping.py against a synthetic runs root built under
# a mktemp directory.
#
# Nothing here reads a real home directory: the script takes the runs root as a
# required argument, and the fixture is generated below. Every expected value
# is counted by hand from the small streams the generator writes; the comments
# beside each request give the counts.
#
# Usage: bash scripts/test-measure-bookkeeping.sh

set -uo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
measure="$script_dir/measure-bookkeeping.py"

failures=0
passed=0

pass() { passed=$((passed + 1)); echo "PASS: $1"; }
fail() { failures=$((failures + 1)); echo "FAIL: $1" >&2; }
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 — got '$2', want '$3'"; fi; }

tmp=$(mktemp -d "${TMPDIR:-/tmp}/test-measure-bookkeeping.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

# ---- fixture generator -------------------------------------------------------

cat > "$tmp/gen.py" <<'PY'
import datetime, json, os, sys

base = sys.argv[1]
root = os.path.join(base, "runs")
GATE = "/x/plugin/cc-cmds/orchestrator/gate.sh"


def sid(n):
    return "00000000-0000-4000-8000-%012d" % n


def gate(cmd):
    return GATE + " exec --manifest \"$CC_PIPELINE_MANIFEST\" --cutpoint 커밋 --surface 읽기 " \
        "--snapshot-digest 'h' --rationale 'a b' -- " + cmd


class S(object):
    def __init__(self, session):
        self.sid = session
        self.lines = [{"type": "system", "subtype": "init", "session_id": session}]
        self.t = 0

    def req(self, mid, tools=(), parent=None, text=None):
        # One stream record per content block, all under the same message id,
        # as the real stream writes them.
        blocks = []
        if text is not None:
            blocks.append({"type": "text", "text": text})
        for name, arg in tools:
            self.t += 1
            inp = {"command": arg} if name == "Bash" else {"file_path": arg}
            blocks.append({"type": "tool_use", "id": "tu_%s_%d" % (mid, self.t), "name": name, "input": inp})
        for b in blocks or [{"type": "text", "text": ""}]:
            self.lines.append({"type": "assistant", "parent_tool_use_id": parent, "session_id": self.sid,
                               "message": {"id": mid, "role": "assistant", "content": [b]}})
        return ["tu_%s_%d" % (mid, i) for i in range(self.t - len(tools) + 1, self.t + 1)]

    def result(self, tid, text, as_list=False, parent=None):
        content = [{"type": "text", "text": text}] if as_list else text
        self.lines.append({"type": "user", "parent_tool_use_id": parent, "session_id": self.sid,
                           "message": {"role": "user", "content": [
                               {"type": "tool_result", "tool_use_id": tid, "content": content,
                                "is_error": text.startswith("Exit code")}]}})

    def write(self, path):
        with open(path, "w") as f:
            for o in self.lines:
                f.write(json.dumps(o, ensure_ascii=False) + "\n")


def run(name, started, ledger_rows, logs, plugin=None, ledger=True):
    d = os.path.join(root, name)
    os.makedirs(os.path.join(d, "log"))
    if started:
        epoch = int(datetime.datetime(*started, tzinfo=datetime.timezone.utc).timestamp())
        open(os.path.join(d, "started-at"), "w").write("%d\n" % epoch)
    if ledger:
        lp = os.path.join(base, name + ".md")
        with open(lp, "w") as f:
            f.write("# 런\n\n")
            for kind, stage, attempt, session in ledger_rows:
                f.write("- `stage-result` | 교대=1 | 세그먼트=- | 스테이지=%s | 종류=%s | 종료 코드=0 | "
                        "실행 버전=%s | 세션 id=%s | 종단 부류=정상 완료 | prev=x\n" % (stage, kind, attempt, session))
        open(os.path.join(d, "ledger-path"), "w").write(lp + "\n")
    if plugin:
        pd = os.path.join(d, "plugin", "cc-cmds", ".claude-plugin")
        os.makedirs(pd)
        json.dump({"name": "cc-cmds", "version": plugin}, open(os.path.join(pd, "plugin.json"), "w"))
    for logname, s in logs:
        s.write(os.path.join(d, "log", logname))


os.makedirs(root)

# Run R1 — 2099-11-02, plugin 3.49.0.
au = S(sid(1))
au.req("m1", [("Bash", gate("shasum -a 256 doc.md")), ("Bash", gate("printenv CC_PIPELINE_RUN_ID"))])  # only, 2 bk
t2 = au.req("m2", [("Bash", gate("git status"))])                                       # gate, not bk
t3 = au.req("m3", [("Read", "/x/doc.md")])                                               # not a gate call
au.req("m4", text="생각만 한 요청")                                                         # no tool call
au.req("m5", [("Bash", gate("/p/orchestrator/doc-tidy.py checkout doc.md --prefix p --expect e")),
              ("Bash", gate("/p/orchestrator/doc-tidy.py apply doc.md"))])                # 1 bk, not only
au.req("m6", [("Bash", gate("cp a b"))], parent="toolu_member")                         # member bk
t7 = au.req("m7", [("Bash", gate("/usr/bin/lockf -k -t 0 l sed -n 1p doc.md"))])        # only, bk, refused
au.req("m8", [("Bash", "shasum -a 256 doc.md")])                                         # bare: not bk
t9 = au.req("m9", [("Bash", gate("mkdir -p /t/partial")), ("Bash", gate("mkdir -p /t/q"))],
            parent="toolu_member")                                                       # member, 2 × mkdir, not bk
t10 = au.req("m10", [("Bash", gate("/p/orchestrator/cc-team-witness-publish.sh /t/.r.round-1.0123456789abcdef /t/r.round-1.md"))],
             parent="toolu_member")                                                      # member bk, refused
au.req("m11", [("Bash", gate("/p/orchestrator/cc-team-nonce.sh r@round-1 r@round-1-rev1"))])  # only, bk
au.result(t7[0], "Exit code 4\n[run][warn] stale snapshot digest — take it again")
au.result(t2[0], "Exit code 4\n다른 거부")                                                # exit 4 without the phrase
au.result(t3[0], "Exit code 4\nstale snapshot digest", as_list=True)                     # not a gate call
au.result(t10[0], "Exit code 4\nstale snapshot digest", parent="toolu_member")           # member refusal
au.result(t9[1], "Exit code 4\n다른 거부", parent="toolu_member")                          # member exit 4 without the phrase
rc = S(sid(2))
rc.req("m1", [("Bash", gate("date -u +%s"))])                                            # only, bk
un = S(sid(9))
un.req("m1", [("Bash", gate("rm -f x"))])                                                # unclassified
two = S(sid(4))
two.req("m1", [("Bash", gate("wc -c doc.md"))])                                          # reconverge by stage+attempt
shift = S(sid(5))
shift.req("m1", [("Bash", gate("shasum x"))])                                            # routing shift: not read
run("20991102-aaaaaaaa", (2099, 11, 2, 12),
    [("audit", "AU", "1", sid(1)), ("reconverge", "RC", "1", sid(2)),
     ("audit", "A1", "1", sid(4)), ("reconverge", "A1", "2", sid(4))],
    [("AU#1.json", au), ("RC#1.json", rc), ("X#1.json", un), ("A1#2.json", two), ("shift-1.json", shift)],
    plugin="3.49.0")

# Run R2 — 2099-10-01, no plugin copy.
au2 = S(sid(3))
au2.req("m1", [("Bash", gate("mktemp -d /t/cc-proto-x.XXXXXX"))])                        # only, bk
run("20991001-bbbbbbbb", (2099, 10, 1), [("audit", "AU", "1", sid(3))], [("AU#1.json", au2)])

# Run R3 — no ledger-path: skipped as incomplete.
run("20991103-cccccccc", (2099, 11, 3), [], [("AU#1.json", S(sid(6)))], ledger=False)
# A plain file under the root is not a run and is not counted.
open(os.path.join(root, "README"), "w").write("x\n")
PY
python3 -B "$tmp/gen.py" "$tmp"
R="$tmp/runs"

j() { jq -r "$1" <<< "$out"; }

# ---- no filter ---------------------------------------------------------------
out=$(python3 -B "$measure" --runs-root "$R" --json); rc=$?
check "필터 없음: rc 0" "$rc" "0"
check "읽은 런 둘" "$(j .scope.runs)" "2"
check "ledger-path 없는 런은 건너뛴 수에 든다" "$(j .scope.skipped_incomplete)" "1"
check "시도 로그 다섯 (시프트 로그는 세지 않는다)" "$(j .scope.attempt_logs)" "5"
check "짝 없는 로그 하나가 미분류" "$(j .scope.unclassified_logs)" "1"
check "감사 스테이지 둘" "$(j .kinds.audit.stages)" "2"
check "감사 리드 요청 (같은 메시지 id 는 한 요청, 구성원 제외)" "$(j .kinds.audit.lead_requests)" "9"
check "감사 부기 전용 요청 (nonce 도우미 요청 포함)" "$(j .kinds.audit.bookkeeping_only)" "4"
check "감사 부기 전용 비율" "$(j '.kinds.audit.bookkeeping_only_pct * 1000 | floor')" "44444"
check "감사 부기 exec (게이트 밖 shasum·doc-tidy apply 는 아님)" "$(j .kinds.audit.bookkeeping_execs)" "6"
check "감사 스테이지당 부기 exec" "$(j '.kinds.audit.execs_per_stage == 3')" "true"
check "감사 exec 기준 비율" "$(j '.kinds.audit.exec_ratio_pct * 1000 | floor')" "66666"
check "구성원 부기 exec 는 따로 센다 (cp·게시 도우미, mkdir 는 아님)" "$(j .kinds.audit.member_bookkeeping)" "2"
check "리드 다이제스트 거부는 리드 게이트 호출의 종료 4 와 문구가 함께일 때만" "$(j .kinds.audit.digest_refusals)" "1"
check "구성원 다이제스트 거부는 따로 센다 (문구 없는 종료 4 는 아님)" "$(j .kinds.audit.member_digest_refusals)" "1"
check "같은 세션 id 의 두 종류는 스테이지·실행 버전으로 가른다" "$(j .kinds.reconverge.stages)" "2"
check "재수렴 부기 전용 비율" "$(j '.kinds.reconverge.bookkeeping_only_pct == 100')" "true"
check "미분류 행이 그 로그의 부기 exec 를 싣는다" "$(j .unclassified.bookkeeping_execs)" "1"
check "합계는 분류된 종류만 더한다" "$(j .total.bookkeeping_execs)" "8"
check "합계의 구성원 다이제스트 거부" "$(j .total.member_digest_refusals)" "1"
check "요청 없는 종류의 비율은 null" "$(j .kinds.design.exec_ratio_pct)" "null"

# ---- breakdown by inner command ----------------------------------------------
check "분해: 부기 밖 mkdir 도 구성원 몫으로 나온다" "$(j '.kinds.audit.by_command.mkdir | [.bookkeeping, .lead, .member] | @csv')" "false,0,2"
check "분해: 구성원 스테이지당 mkdir" "$(j '.kinds.audit.by_command.mkdir.member_per_stage == 1')" "true"
check "분해: 호출 합이 가장 많은 키가 먼저" "$(j '.kinds.audit.by_command | keys_unsorted | .[0]')" "mkdir"
check "분해: 합이 같으면 키 순" "$(j '.kinds.audit.by_command | keys_unsorted | .[1:4] | join(",")')" "cc-team-nonce.sh,cc-team-witness-publish.sh,cp"
check "분해: 게시 도우미는 구성원 부기" "$(j '.kinds.audit.by_command["cc-team-witness-publish.sh"] | [.bookkeeping, .lead, .member] | @csv')" "true,0,1"
check "분해: nonce 도우미는 리드 부기" "$(j '.kinds.audit.by_command["cc-team-nonce.sh"] | [.bookkeeping, .lead, .member] | @csv')" "true,1,0"
check "분해: doc-tidy 는 하위 명령으로 가른다 (checkout 은 부기)" "$(j '.kinds.audit.by_command["doc-tidy.py checkout"].bookkeeping')" "true"
check "분해: doc-tidy apply 는 부기 밖" "$(j '.kinds.audit.by_command["doc-tidy.py apply"] | [.bookkeeping, .lead] | @csv')" "false,1"
check "분해: 부기 밖 git 도 리드 몫으로 나온다" "$(j '.kinds.audit.by_command.git | [.bookkeeping, .lead] | @csv')" "false,1"
check "분해: 게이트 밖 shasum 은 들지 않는다" "$(j '.kinds.audit.by_command.shasum.lead')" "1"
check "분해: 부기 키의 리드 합이 부기 exec 와 같다" "$(j '[.kinds.audit.by_command[] | select(.bookkeeping) | .lead] | add')" "6"
check "분해: 합계는 종류의 분해를 더한다" "$(j '.total.by_command | [.date.lead, .wc.lead, .mkdir.member] | @csv')" "1,1,2"
check "분해: 미분류는 합계 분해에 들지 않는다" "$(j '.total.by_command.rm')" "null"
check "분해: 스테이지 없는 종류는 빈 분해" "$(j '.kinds.design.by_command | length')" "0"

# ---- --since -----------------------------------------------------------------
out=$(python3 -B "$measure" --runs-root "$R" --since 2099-11-01 --json); rc=$?
check "--since: rc 0" "$rc" "0"
check "--since 는 앞선 런을 건너뛴다" "$(j .scope.skipped_since)" "1"
check "--since 뒤 감사 스테이지 하나" "$(j .kinds.audit.stages)" "1"
check "--since 뒤 감사 exec 기준 비율" "$(j '.kinds.audit.exec_ratio_pct')" "62.5"
check "--since 뒤 감사 스테이지당 부기 exec" "$(j '.kinds.audit.execs_per_stage == 5')" "true"
check "--since 뒤 감사 분해에 앞선 런의 mktemp 가 없다" "$(j '.kinds.audit.by_command.mktemp')" "null"

# ---- --min-plugin-version ----------------------------------------------------
out=$(python3 -B "$measure" --runs-root "$R" --min-plugin-version 3.49.0 --json); rc=$?
check "--min-plugin-version: 사본 없는 런을 건너뛴다" "$(j .scope.skipped_version)" "1"
check "--min-plugin-version: 읽은 런 하나" "$(j .scope.runs)" "1"
out=$(python3 -B "$measure" --runs-root "$R" --min-plugin-version 3.50.0 --json); rc=$?
check "읽은 런이 없으면 rc 1" "$rc" "1"
check "읽은 런이 없어도 객체를 낸다" "$(j .scope.skipped_version)" "2"

# ---- table -------------------------------------------------------------------
out=$(python3 -B "$measure" --runs-root "$R"); rc=$?
check "표: rc 0" "$rc" "0"
case "$out" in
  *"audit | 2 | 9 | 4 | 44.4% | 6 | 3.0 | 66.7% | 2 | 1 | 1"*) pass "표에 감사 행이 있다 (끝 열이 구성원 다이제스트 거부)" ;;
  *) fail "표에 감사 행이 있다 — $out" ;;
esac
case "$out" in
  *"미분류 | 1 | 1 | 1 | 100.0% | 1 |"*) pass "표에 미분류 행이 있다" ;;
  *) fail "표에 미분류 행이 있다 — $out" ;;
esac
case "$out" in
  *"| 다이제스트 거부(보조) | 구성원 다이제스트 거부"*) pass "주 표 머리의 끝 열" ;;
  *) fail "주 표 머리의 끝 열 — $out" ;;
esac
case "$out" in
  *"종류 | 안쪽 명령 | 부기 | 리드 | 구성원 | 리드 스테이지당 | 구성원 스테이지당"*) pass "분해 표 머리" ;;
  *) fail "분해 표 머리 — $out" ;;
esac
case "$out" in
  *"audit | mkdir | 아니오 | 0 | 2 | 0.0 | 1.0"*) pass "분해 표에 부기 밖 mkdir 행" ;;
  *) fail "분해 표에 부기 밖 mkdir 행 — $out" ;;
esac
case "$out" in
  *"audit | cc-team-witness-publish.sh | 예 | 0 | 1 | 0.0 | 0.5"*) pass "분해 표에 게시 도우미 행" ;;
  *) fail "분해 표에 게시 도우미 행 — $out" ;;
esac
case "$out" in
  *"합계 | mkdir | 아니오 | 0 | 2 |"*) pass "분해 표에 합계 행" ;;
  *) fail "분해 표에 합계 행 — $out" ;;
esac
n=$(grep -c '^design | [^0-9]' <<< "$out")
check "스테이지 없는 종류는 분해 행을 내지 않는다" "$n" "0"

# ---- usage -------------------------------------------------------------------
python3 -B "$measure" --json >/dev/null 2>&1; rc=$?
check "--runs-root 없으면 rc 2" "$rc" "2"
python3 -B "$measure" --runs-root "$R" --since 2099/11/01 >/dev/null 2>&1; rc=$?
check "잘못된 --since 는 rc 2" "$rc" "2"
python3 -B "$measure" --runs-root "$tmp/없음" >/dev/null 2>&1; rc=$?
check "없는 런 루트는 rc 2" "$rc" "2"

printf '\n%d passed, %d failed\n' "$passed" "$failures"
[ "$failures" -eq 0 ]
