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

    def result(self, tid, text, as_list=False):
        content = [{"type": "text", "text": text}] if as_list else text
        self.lines.append({"type": "user", "parent_tool_use_id": None, "session_id": self.sid,
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
au.result(t7[0], "Exit code 4\n[run][warn] stale snapshot digest — take it again")
au.result(t2[0], "Exit code 4\n다른 거부")                                                # exit 4 without the phrase
au.result(t3[0], "Exit code 4\nstale snapshot digest", as_list=True)                     # not a gate call
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
check "감사 리드 요청 (같은 메시지 id 는 한 요청, 구성원 제외)" "$(j .kinds.audit.lead_requests)" "8"
check "감사 부기 전용 요청" "$(j .kinds.audit.bookkeeping_only)" "3"
check "감사 부기 전용 비율" "$(j .kinds.audit.bookkeeping_only_pct)" "37.5"
check "감사 부기 exec (게이트 밖 shasum·doc-tidy apply 는 아님)" "$(j .kinds.audit.bookkeeping_execs)" "5"
check "감사 스테이지당 부기 exec" "$(j .kinds.audit.execs_per_stage)" "2.5"
check "감사 exec 기준 비율" "$(j .kinds.audit.exec_ratio_pct)" "62.5"
check "구성원 부기 exec 는 따로 센다" "$(j .kinds.audit.member_bookkeeping)" "1"
check "다이제스트 거부는 게이트 호출의 종료 4 와 문구가 함께일 때만" "$(j .kinds.audit.digest_refusals)" "1"
check "같은 세션 id 의 두 종류는 스테이지·실행 버전으로 가른다" "$(j .kinds.reconverge.stages)" "2"
check "재수렴 부기 전용 비율" "$(j '.kinds.reconverge.bookkeeping_only_pct == 100')" "true"
check "미분류 행이 그 로그의 부기 exec 를 싣는다" "$(j .unclassified.bookkeeping_execs)" "1"
check "합계는 분류된 종류만 더한다" "$(j .total.bookkeeping_execs)" "7"
check "요청 없는 종류의 비율은 null" "$(j .kinds.design.exec_ratio_pct)" "null"

# ---- --since -----------------------------------------------------------------
out=$(python3 -B "$measure" --runs-root "$R" --since 2099-11-01 --json); rc=$?
check "--since: rc 0" "$rc" "0"
check "--since 는 앞선 런을 건너뛴다" "$(j .scope.skipped_since)" "1"
check "--since 뒤 감사 스테이지 하나" "$(j .kinds.audit.stages)" "1"
check "--since 뒤 감사 exec 기준 비율" "$(j '.kinds.audit.exec_ratio_pct * 1000 | floor')" "57142"
check "--since 뒤 감사 스테이지당 부기 exec" "$(j '.kinds.audit.execs_per_stage == 4')" "true"

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
  *"audit | 2 | 8 | 3 | 37.5% | 5 | 2.5 | 62.5% | 1 | 1"*) pass "표에 감사 행이 있다" ;;
  *) fail "표에 감사 행이 있다 — $out" ;;
esac
case "$out" in
  *"미분류 | 1 | 1 | 1 | 100.0% | 1 |"*) pass "표에 미분류 행이 있다" ;;
  *) fail "표에 미분류 행이 있다 — $out" ;;
esac

# ---- usage -------------------------------------------------------------------
python3 -B "$measure" --json >/dev/null 2>&1; rc=$?
check "--runs-root 없으면 rc 2" "$rc" "2"
python3 -B "$measure" --runs-root "$R" --since 2099/11/01 >/dev/null 2>&1; rc=$?
check "잘못된 --since 는 rc 2" "$rc" "2"
python3 -B "$measure" --runs-root "$tmp/없음" >/dev/null 2>&1; rc=$?
check "없는 런 루트는 rc 2" "$rc" "2"

printf '\n%d passed, %d failed\n' "$passed" "$failures"
[ "$failures" -eq 0 ]
