#!/usr/bin/env bash
# Test scripts/measure-read-chains.py against a synthetic runs root built under
# a mktemp directory.
#
# Nothing here reads a real home directory: the script takes the runs root as a
# required argument, and the fixture is generated below. Every expected value
# is counted by hand from the small streams the generator writes; the comments
# beside each request give the counts.
#
# Usage: bash scripts/test-measure-read-chains.sh

set -uo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
measure="$script_dir/measure-read-chains.py"

failures=0
passed=0

pass() { passed=$((passed + 1)); echo "PASS: $1"; }
fail() { failures=$((failures + 1)); echo "FAIL: $1" >&2; }
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 — got '$2', want '$3'"; fi; }

tmp=$(mktemp -d "${TMPDIR:-/tmp}/test-measure-read-chains.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

# ---- fixture generator -------------------------------------------------------

cat > "$tmp/gen.py" <<'PY'
import datetime, json, os, sys

base = sys.argv[1]
root = os.path.join(base, "runs")
GATE = "/x/plugin/cc-cmds/orchestrator/gate.sh"
T0 = datetime.datetime(2099, 11, 2, tzinfo=datetime.timezone.utc)


def sid(n):
    return "00000000-0000-4000-8000-%012d" % n


def ts(sec):
    return (T0 + datetime.timedelta(seconds=sec)).strftime("%Y-%m-%dT%H:%M:%S.000Z")


def exec_(cmd, surface="읽기"):
    return ("Bash", {"command": GATE + " exec --manifest \"$CC_PIPELINE_MANIFEST\" --cutpoint 커밋 "
                     "--surface " + surface + " --snapshot-digest 'h' --rationale 'a b' -- " + cmd})


def snapshot():
    return ("Bash", {"command": GATE + " snapshot --manifest \"$CC_PIPELINE_MANIFEST\" --fields H"})


def read(path, offset=None, limit=None):
    inp = {"file_path": path}
    if offset is not None:
        inp["offset"] = offset
    if limit is not None:
        inp["limit"] = limit
    return ("Read", inp)


def grep(pattern):
    return ("Grep", {"pattern": pattern})


def edit():
    return ("Edit", {"file_path": "/w/x.py", "old_string": "a", "new_string": "b"})


class S(object):
    def __init__(self, session):
        self.sid = session
        self.lines = [{"type": "system", "subtype": "init", "session_id": session}]

    def user(self, text, parent=None, at=None):
        o = {"type": "user", "parent_tool_use_id": parent, "session_id": self.sid,
             "message": {"role": "user", "content": text}}
        if at is not None:
            o["timestamp"] = ts(at)
        self.lines.append(o)

    def req(self, mid, tools=(), parent=None, text=None, at=None, cache=None):
        # One stream record per content block, all under the same message id,
        # as the real stream writes them. Only the last record carries the
        # final cache read value; earlier records carry 1.
        blocks = []
        if text is not None:
            blocks.append({"type": "text", "text": text})
        ids = []
        for k, (name, inp) in enumerate(tools, 1):
            ids.append("tu_%s_%d" % (mid, k))
            blocks.append({"type": "tool_use", "id": ids[-1], "name": name, "input": inp})
        blocks = blocks or [{"type": "text", "text": ""}]
        for n, b in enumerate(blocks):
            msg = {"id": mid, "role": "assistant", "content": [b]}
            if cache is not None:
                msg["usage"] = {"cache_read_input_tokens": cache if n == len(blocks) - 1 else 1}
            o = {"type": "assistant", "parent_tool_use_id": parent, "session_id": self.sid,
                 "message": msg}
            if at is not None:
                o["timestamp"] = ts(at)
            self.lines.append(o)
        return ids

    def result(self, tid, text, at=None, parent=None):
        o = {"type": "user", "parent_tool_use_id": parent, "session_id": self.sid,
             "message": {"role": "user", "content": [
                 {"type": "tool_result", "tool_use_id": tid, "content": [{"type": "text", "text": text}]}]}}
        if at is not None:
            o["timestamp"] = ts(at)
        self.lines.append(o)

    def write(self, path):
        with open(path, "w") as f:
            for o in self.lines:
                f.write(json.dumps(o, ensure_ascii=False) + "\n")


def run(name, started, ledger_rows, logs, plugin=None, ledger=True, under=None):
    d = os.path.join(under or root, name)
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

# Run R1 — 2099-11-02, plugin 3.50.1.
#
# Implement log IM#1: 13 lead requests (m1..m13); m3 carries two calls and m9
# none, so 11 single-call requests and 10 read-only ones.
im = S(sid(1))
# The first user text names /w/zz/q.txt, so m8's path token is known before C2
# and only its line range can make it dependent.
im.user("작업: /w/docs/design.md 를 읽는다 (참고 /w/zz/q.txt)", at=0)
# Chain C1 (m1..m3), broken by the Edit of m4.
t = im.req("m1", [exec_("git grep -n foo")], text="찾는다", at=0, cache=1000)
im.result(t[0], "/w/scripts/a.py:10:foo\n/w/docs/design.md:3:foo\n", at=3600)        # exec wait 1.0h
# A member's records sit inside the chain: they neither break it nor count.
mt = im.req("mm1", [read("/w/member.txt")], parent="toolu_member", at=100, cache=5)
im.result(mt[0], "lib/c.py:286: member only", parent="toolu_member", at=110)
t = im.req("m2", [read("/w/scripts/a.py")], at=3600, cache=1000)                     # dependent on m1 (exact path)
im.result(t[0], "     1\tfoo = 1\n", at=3960)
t = im.req("m3", [read("/w/docs/design.md"),                                          # independent: in the first user text
                  exec_("sed -n 1,5p /w/scripts/a.py")], at=3960, cache=1000)        # dependent on m1
im.result(t[0], "     1\t# design\n", at=4320)
im.result(t[1], "foo = 1\n", at=7200)                                                 # exec wait 0.9h
t = im.req("m4", [("Edit", {"file_path": "/w/x.py", "old_string": "a", "new_string": "b"})], at=7200)
im.result(t[0], "ok", at=7200)
# Chain C2 (m5..m8): m6 <- m5, m7 independent, m8 <- m6 → depth 3, reducible 1.
t = im.req("m5", [exec_("grep -n bar lib")], at=7200, cache=1000)
im.result(t[0], "lib/c.py:5:bar\n")                                                   # no timestamp: untimed
t = im.req("m6", [read("/w/lib/c.py")], at=7200, cache=1000)                          # last two path elements
im.result(t[0], "     1\timport util\n     2\t# see zz/q.txt:286: helper\n", at=7560)
t = im.req("m7", [snapshot()], at=7560, cache=1000)                                   # snapshot keeps the chain
im.result(t[0], "{\"H\":\"hh\"}", at=7920)
# m8: offset without limit is the one-line range 286-286; m6's result carries
# `zz/q.txt:286:` on one line, a marker attached to that file → dependent on m6.
t = im.req("m8", [read("/w/zz/q.txt", offset=286)], at=7920, cache=1000)
im.result(t[0], "   286\tq\n", at=8280)
im.req("m9", text="생각만 한 요청", at=8280)                                            # no call: breaks
t = im.req("m10", [read("/w/x1.txt")], at=8280)                                       # a run of two: no chain
im.result(t[0], "x1", at=8300)
t = im.req("m11", [read("/w/x2.txt")], at=8300)
im.result(t[0], "x2", at=8310)
t = im.req("m12", [exec_("touch /w/f.txt", surface="워크트리쓰기")], at=8310)          # a worktree write breaks
im.result(t[0], "", at=8320)
t = im.req("m13", [read("/w/x3.txt")], at=8320)
im.result(t[0], "x3", at=8330)

# Review log RV#1: one chain of three independent reads, no timestamps, no usage.
rv = S(sid(2))
rv.user("리뷰: 세 파일")
for k in (1, 2, 3):
    t = rv.req("r%d" % k, [read("/w/a%d.txt" % k)])
    rv.result(t[0], "content %d" % k)

un = S(sid(9))
t = un.req("u1", [read("/w/u.txt")])                                                  # unclassified
shift = S(sid(5))
shift.req("s1", [read("/w/s.txt")])                                                   # routing shift: not read
run("20991102-aaaaaaaa", (2099, 11, 2, 12),
    [("implement", "IM", "1", sid(1)), ("review", "RV", "1", sid(2))],
    [("IM#1.json", im), ("RV#1.json", rv), ("X#1.json", un), ("shift-1.json", shift)],
    plugin="3.50.1")

# Run R2 — 2099-10-01, plugin 3.49.0.
im2 = S(sid(3))
im2.req("m1", [read("/w/b.txt")])
run("20991001-bbbbbbbb", (2099, 10, 1), [("implement", "IM", "1", sid(3))], [("IM#1.json", im2)],
    plugin="3.49.0")

# Run R4 — 2099-12-01, no plugin copy.
rv4 = S(sid(4))
rv4.req("r1", [read("/w/c.txt")])
run("20991201-dddddddd", (2099, 12, 1), [("review", "RV", "1", sid(4))], [("RV#1.json", rv4)])

# Run R3 — no ledger-path: skipped as incomplete.
run("20991103-cccccccc", (2099, 11, 3), [], [("IM#1.json", S(sid(6)))], ledger=False)
# A plain file under the root is not a run and is not counted.
open(os.path.join(root, "README"), "w").write("x\n")

# Second runs root `runs-tok`: one run, one implement log TK#1 holding four
# chains for the line range, sub-token and subcommand rules. It sits under its
# own root so the counts asserted on `runs` above stay as they are. Each chain
# is broken from the next by an Edit request. Judged calls, counted by hand:
# T1 4 (t2 three, t3 one), T2 2, T3 4 (v2 three, v3 one), T4 3 (w2 two, w3
# one) = 13; independent ones: T1 2, T2 2, T3 2, T4 2 = 8.
tok_root = os.path.join(base, "runs-tok")
os.makedirs(tok_root)
tk = S(sid(7))
# Every Read path below is in this first user text, so no path token counts
# and only the line ranges decide T1 and T2.
tk.user("파일 /w/r/one.py 와 /w/r/two.py 와 /w/r/three.py 를 본다")
# T1 — line ranges.
t = tk.req("t1", [exec_("git grep -n alpha")])
tk.result(t[0], "/w/r/one.py:286:alpha\n")
t = tk.req("t2", [read("/w/r/one.py", offset=280, limit=20),      # 280-299 holds t1's `r/one.py:286:` on its line → dependent on t1
                  read("/w/r/two.py", offset=280, limit=20),      # t1's marker 286 is attached to one.py, not two.py → independent
                  read("/w/r/three.py")])                         # no offset: path token only, known before → independent
tk.result(t[0], "   280\tq\n")
tk.result(t[1], "   281\tq\n")
tk.result(t[2], "   285\tx\n   286\ty\n")
t = tk.req("t3", [read("/w/r/three.py", offset=286)])             # line head `   286\t` in t2's Read of the same file → dependent on t2
tk.result(t[0], "   286\ty\n")
t = tk.req("e1", [edit()])
tk.result(t[0], "ok")
# T2 — the marker in range is also in a result before the chain.
t = tk.req("u1", [exec_("git grep -n beta")])
tk.result(t[0], "/w/r/one.py:290:beta\n")
t = tk.req("u2", [read("/w/r/one.py", offset=285, limit=10)])     # 285-294: u1's 290 matches, but t1's `r/one.py:286:` came before → independent
tk.result(t[0], "   285\tq\n")
t = tk.req("u3", [snapshot()])                                    # no token → independent
tk.result(t[0], "{}")
t = tk.req("e2", [edit()])
tk.result(t[0], "ok")
# T3 — sub-tokens.
t = tk.req("v1", [exec_("cat /w/s/log.txt")])
tk.result(t[0], "hit Bar9 here\n15728: row\nbaz\n")
t = tk.req("v2", [grep("foo|Bar9|baz"),                            # piece Bar9 first in v1's result → dependent
                  grep("qux|baz"),                                 # only the lowercase piece baz is in v1's result → independent
                  exec_("awk 'NR == 15728' /w/s/data.txt")])       # piece 15728 first in v1's `15728:` → dependent
tk.result(t[0], "x")
tk.result(t[1], "x")
tk.result(t[2], "x")
t = tk.req("v3", [snapshot()])                                    # independent
tk.result(t[0], "{}")
t = tk.req("e3", [edit()])
tk.result(t[0], "ok")
# T4 — git and gh subcommands are not tokens.
t = tk.req("w1", [exec_("git log --oneline -1")])
tk.result(t[0], "worktree list status 1829\n")
t = tk.req("w2", [exec_("git worktree list"),                      # worktree and list are the subcommand → no token → independent
                  exec_("git status --short")])                    # status is the subcommand → independent
tk.result(t[0], "x")
tk.result(t[1], "x")
t = tk.req("w3", [exec_("gh pr view 1829")])                       # 1829 first in w1's result → dependent
tk.result(t[0], "x")
run("20991105-eeeeeeee", (2099, 11, 5), [("implement", "TK", "1", sid(7))], [("TK#1.json", tk)],
    plugin="3.50.1", under=tok_root)
PY
python3 -B "$tmp/gen.py" "$tmp"
R="$tmp/runs"
IM="20991102-aaaaaaaa/IM#1"

j() { jq -r "$1" <<< "$out"; }
v() { jq -r --arg id "$1" '.samples[] | select(.id == $id) | .verdict' <<< "$out"; }

# ---- the window holding R1 only ----------------------------------------------
out=$(python3 -B "$measure" --runs-root "$R" --since 2099-11-01 --until 2099-11-30 --json --sample 50 --seed 1); rc=$?
check "창: rc 0" "$rc" "0"
check "창: 읽은 런 하나" "$(j .scope.runs)" "1"
check "창: --since 와 --until 이 둘 다 시작일로 건너뛴다" "$(j .scope.skipped_since)" "2"
check "창: ledger-path 없는 런은 건너뛴 수에 든다" "$(j .scope.skipped_incomplete)" "1"
check "창: 시도 로그 셋 (시프트 로그는 세지 않는다)" "$(j .scope.attempt_logs)" "3"
check "창: 짝 없는 로그 하나가 미분류" "$(j .scope.unclassified_logs)" "1"
check "구현 리드 요청 (같은 메시지 id 는 한 요청, 구성원 제외)" "$(j .kinds.implement.lead_requests)" "13"
check "구현 호출 하나인 요청 비율" "$(j '.kinds.implement.single_tool_pct * 100 | round')" "8462"
check "구현 읽기 전용 요청 비율" "$(j '.kinds.implement.read_only_pct * 100 | round')" "7692"
check "연쇄 둘 (길이 2 구간과 홀로 선 읽기는 세지 않는다)" "$(j .kinds.implement.chains)" "2"
check "연쇄 안 요청 일곱" "$(j .kinds.implement.chain_requests)" "7"
check "판정한 호출 여섯" "$(j .kinds.implement.judged_calls)" "6"
check "묶을 수 있었던 호출 둘" "$(j .kinds.implement.batchable_calls)" "2"
check "줄일 수 있었던 요청 둘 (C1 1, C2 1)" "$(j .kinds.implement.reducible_requests)" "2"
check "게이트 exec 읽기 셋 (워크트리쓰기 exec 는 아님)" "$(j .kinds.implement.exec_reads)" "3"
check "전용 읽기 일곱" "$(j .kinds.implement.dedicated_reads)" "7"
check "snapshot 하나" "$(j .kinds.implement.snapshot_calls)" "1"
check "exec 읽기 대기 합 1.9h" "$(j '.kinds.implement.exec_read_wait_h * 10 | round')" "19"
check "연쇄 요청 벽시계 합 2.3h" "$(j '.kinds.implement.chain_wall_h * 10 | round')" "23"
check "시각 없는 호출 하나" "$(j .kinds.implement.untimed_calls)" "1"
check "연쇄 캐시 읽기 (id 마다 마지막 기록 값 한 번)" "$(j .kinds.implement.chain_cache_read_tokens)" "7000"
check "줄일 수 있었던 캐시 읽기 추정" "$(j '.kinds.implement.reducible_cache_read_est == 2000')" "true"
check "리뷰 연쇄 하나에 묶을 수 있었던 호출 둘" "$(j '[.kinds.review.chains, .kinds.review.batchable_calls] | join(",")')" "1,2"
check "리뷰 줄일 수 있었던 요청 둘 (깊이 1)" "$(j .kinds.review.reducible_requests)" "2"
check "리뷰 시각 없는 호출 셋, 벽시계 0" "$(j '[.kinds.review.untimed_calls, .kinds.review.chain_wall_h == 0] | join(",")')" "3,true"
check "리뷰 캐시 없음 → 추정 0" "$(j '.kinds.review.reducible_cache_read_est == 0')" "true"
check "요청 없는 종류의 비율은 null" "$(j .kinds.design.batchable_call_pct)" "null"
check "미분류 행이 그 로그의 요청을 싣는다" "$(j .unclassified.lead_requests)" "1"
check "합계는 분류된 종류만 더한다" "$(j .total.lead_requests)" "16"
check "합계 연쇄 셋" "$(j .total.chains)" "3"

# ---- mechanical verdicts -----------------------------------------------------
check "표본 N 초과 → 판정 대상 전부 (여덟)" "$(j '.samples | length')" "8"
check "둘째 요청의 경로가 첫 요청 결과에 처음 나옴 → 의존" "$(v "$IM/tu_m2_1")" "의존"
check "경로가 연쇄 앞 user 글에 있음 → 독립" "$(v "$IM/tu_m3_1")" "독립"
check "exec 읽기의 경로 인자 → 의존" "$(v "$IM/tu_m3_2")" "의존"
check "경로 끝 두 요소 맞춤 → 의존 (구성원 글은 원천이 아니다)" "$(v "$IM/tu_m6_1")" "의존"
check "snapshot 은 토큰이 없어 독립" "$(v "$IM/tu_m7_1")" "독립"
check "한 줄 범위 토큰 → 의존" "$(v "$IM/tu_m8_1")" "의존"
check "한 줄 범위 의존의 근거는 연쇄 둘째 요청 (경로는 연쇄 앞에 있어 근거가 아니다)" \
  "$(jq -r --arg id "$IM/tu_m8_1" '.samples[] | select(.id == $id) | .evidence | map("\(.token)@\(.request)") | join(",")' <<< "$out")" "286-286@2"
check "표본의 위치" \
  "$(jq -r --arg id "$IM/tu_m8_1" '.samples[] | select(.id == $id) | .position | "\(.chain_first_request),\(.chain_length),\(.request_in_chain),\(.call_in_request)"' <<< "$out")" "5,4,4,1"
check "앞 요청은 가까운 넷까지 (넷째 요청은 앞 셋)" \
  "$(jq -r --arg id "$IM/tu_m8_1" '.samples[] | select(.id == $id) | .previous | map(.request_in_chain) | join(",")' <<< "$out")" "1,2,3"
check "연쇄 앞 원천 글에 없는 토큰은 없음" \
  "$(jq -r --arg id "$IM/tu_m8_1" '.samples[] | select(.id == $id) | .tokens[] | select(.type == "range") | .before_chain' <<< "$out")" "없음"
check "줄 범위 토큰은 그 Read 의 파일을 든다" \
  "$(jq -r --arg id "$IM/tu_m8_1" '.samples[] | select(.id == $id) | .tokens[] | select(.type == "range") | "\(.token) \(.file)"' <<< "$out")" "286-286 /w/zz/q.txt"
check "연쇄 앞 원천 글에 있던 토큰은 그 자리를 싣는다" \
  "$(jq -r --arg id "$IM/tu_m3_1" '.samples[] | select(.id == $id) | .tokens[0].before_chain | test("작업: /w/docs/design.md")' <<< "$out")" "true"
all="$out"

# ---- line ranges, sub-tokens, subcommands (runs-tok) --------------------------
TK="20991105-eeeeeeee/TK#1"
out=$(python3 -B "$measure" --runs-root "$tmp/runs-tok" --json --sample 50 --seed 1); rc=$?
check "토큰 규칙 픽스처: rc 0" "$rc" "0"
check "토큰 규칙 픽스처: 판정한 호출 열셋" "$(j .kinds.implement.judged_calls)" "13"
check "토큰 규칙 픽스처: 묶을 수 있었던 호출 여덟" "$(j .kinds.implement.batchable_calls)" "8"
check "같은 줄에 그 파일이 붙은 표지가 줄 범위 안 → 의존" "$(v "$TK/tu_t2_1")" "의존"
check "줄 범위 의존의 근거" \
  "$(jq -r --arg id "$TK/tu_t2_1" '.samples[] | select(.id == $id) | .evidence | map("\(.token)@\(.request) \(.file)") | join(",")' <<< "$out")" "280-299@1 /w/r/one.py"
check "다른 파일에 붙은 표지 → 독립" "$(v "$TK/tu_t2_2")" "독립"
check "같은 파일 Read 결과의 줄 머리 → 의존" "$(v "$TK/tu_t3_1")" "의존"
check "범위 안 표지가 연쇄 앞의 같은 파일 결과에도 있음 → 독립" "$(v "$TK/tu_u2_1")" "독립"
check "하위 토큰 Bar9 → 의존" "$(v "$TK/tu_v2_1")" "의존"
check "소문자 조각만 앞 결과에 나옴 → 독립" "$(v "$TK/tu_v2_2")" "독립"
check "awk 조건의 하위 토큰 15728 → 의존" "$(v "$TK/tu_v2_3")" "의존"
check "git worktree list 는 앞 결과에 list 가 있어도 독립" "$(v "$TK/tu_w2_1")" "독립"
check "git status --short 는 앞 결과에 status 가 있어도 독립" "$(v "$TK/tu_w2_2")" "독립"
check "gh pr view 1829 의 1829 → 의존" "$(v "$TK/tu_w3_1")" "의존"
check "하위 명령 낱말은 토큰이 아니다" \
  "$(jq -r --arg id "$TK/tu_w3_1" '.samples[] | select(.id == $id) | [.tokens[].token] | join(",")' <<< "$out")" "1829"
printf '%s\n' "$out" > "$tmp/tok.json"
tlist=$(python3 -B "$measure" --render "$tmp/tok.json" --samples)
case "$tlist" in
  *'- 토큰 range "280-299" 파일 "/w/r/one.py":'*) pass "표본 목록이 줄 범위와 그 파일을 싣는다" ;;
  *) fail "표본 목록이 줄 범위와 그 파일을 싣는다 — $tlist" ;;
esac
case "$tlist" in
  *독립*|*의존*) fail "토큰 규칙 표본 목록에 기계 판정 문자열이 없다 — $tlist" ;;
  *) pass "토큰 규칙 표본 목록에 기계 판정 문자열이 없다" ;;
esac

# ---- samples -----------------------------------------------------------------
s1=$(python3 -B "$measure" --runs-root "$R" --since 2099-11-01 --until 2099-11-30 --json --sample 3 --seed 7 | jq -c '[.samples[].id]')
s2=$(python3 -B "$measure" --runs-root "$R" --since 2099-11-01 --until 2099-11-30 --json --sample 3 --seed 7 | jq -c '[.samples[].id]')
check "같은 시드는 같은 표본" "$s1" "$s2"
check "표본 셋" "$(jq length <<< "$s1")" "3"
printf '%s\n' "$all" > "$tmp/all.json"
list=$(python3 -B "$measure" --render "$tmp/all.json" --samples); rc=$?
check "표본 목록: rc 0" "$rc" "0"
case "$list" in
  *독립*|*의존*) fail "표본 목록에 기계 판정 문자열이 없다 — $list" ;;
  *) pass "표본 목록에 기계 판정 문자열이 없다" ;;
esac
check "표본 목록에 표본 여덟" "$(grep -c '^## ' <<< "$list")" "8"
case "$list" in
  *"$IM/tu_m8_1"*"결과 앞 800자"*) pass "표본 목록에 id 와 앞 요청 발췌가 있다" ;;
  *) fail "표본 목록에 id 와 앞 요청 발췌가 있다 — $list" ;;
esac

# ---- agreement ---------------------------------------------------------------
TAB=$(printf '\t')
jq -r '.samples[] | "\(.id)\t\(.verdict)"' "$tmp/all.json" > "$tmp/same.tsv"
{ echo "# 리드 판정"; echo; sed "s|^\($IM/tu_m7_1\)${TAB}독립\$|\1${TAB}의존|" "$tmp/same.tsv"; } > "$tmp/one-off.tsv"
out=$(python3 -B "$measure" --agreement "$tmp/one-off.tsv" "$tmp/all.json"); rc=$?
check "일치율: rc 0" "$rc" "0"
case "$out" in
  *"합계 | 8 | 7 | 87.5% | 1 | 0"*) pass "어긋남 하나 → 일치 일곱, 기계 독립·리드 의존 하나" ;;
  *) fail "어긋남 하나 → 일치 일곱, 기계 독립·리드 의존 하나 — $out" ;;
esac
head -n 7 "$tmp/same.tsv" > "$tmp/missing.tsv"
python3 -B "$measure" --agreement "$tmp/missing.tsv" "$tmp/all.json" >/dev/null 2>&1; rc=$?
check "빠진 id → rc 2" "$rc" "2"
sed "s|${TAB}독립\$|${TAB}모름|" "$tmp/same.tsv" > "$tmp/unknown.tsv"
python3 -B "$measure" --agreement "$tmp/unknown.tsv" "$tmp/all.json" >/dev/null 2>&1; rc=$?
check "모르는 값 → rc 2" "$rc" "2"
{ cat "$tmp/same.tsv"; head -n 1 "$tmp/same.tsv"; } > "$tmp/dup.tsv"
python3 -B "$measure" --agreement "$tmp/dup.tsv" "$tmp/all.json" >/dev/null 2>&1; rc=$?
check "겹친 id → rc 2" "$rc" "2"
{ cat "$tmp/same.tsv"; printf 'no/such/id\t독립\n'; } > "$tmp/extra.tsv"
python3 -B "$measure" --agreement "$tmp/extra.tsv" "$tmp/all.json" >/dev/null 2>&1; rc=$?
check "없는 id → rc 2" "$rc" "2"

# ---- filters -----------------------------------------------------------------
out=$(python3 -B "$measure" --runs-root "$R" --json); rc=$?
check "필터 없음: 읽은 런 셋" "$(j .scope.runs)" "3"
check "필터 없음: 구현 스테이지 둘" "$(j .kinds.implement.stages)" "2"
out=$(python3 -B "$measure" --runs-root "$R" --until 2099-11-30 --json); rc=$?
check "--until 은 뒤의 런을 건너뛴다" "$(j '[.scope.runs, .scope.skipped_since] | join(",")')" "2,1"
out=$(python3 -B "$measure" --runs-root "$R" --min-plugin-version 3.50.0 --json); rc=$?
check "--min-plugin-version: 낮은 판과 사본 없는 런을 건너뛴다" "$(j '[.scope.runs, .scope.skipped_version] | join(",")')" "1,2"
out=$(python3 -B "$measure" --runs-root "$R" --min-plugin-version 9.0.0 --json); rc=$?
check "읽은 런이 없으면 rc 1" "$rc" "1"
check "읽은 런이 없어도 객체를 낸다" "$(j .scope.skipped_version)" "3"

# ---- table -------------------------------------------------------------------
direct=$(python3 -B "$measure" --runs-root "$R" --since 2099-11-01 --until 2099-11-30); rc=$?
check "표: rc 0" "$rc" "0"
check "표: 구분줄" "$(sed -n 4p <<< "$direct" | cut -c1-9)" "--- | ---"
case "$direct" in
  *"implement | 1 | 13 | 84.6% | 76.9% | 2 | 7 | 53.8% | 6 | 2 | 33.3% | 2 | 28.6% | 3 | 7 | 1 | 1.90 | 2.30 | 1 | 7,000 | 2,000"*)
    pass "표에 구현 행이 있다" ;;
  *) fail "표에 구현 행이 있다 — $direct" ;;
esac
python3 -B "$measure" --runs-root "$R" --since 2099-11-01 --until 2099-11-30 --json > "$tmp/w.json"
rendered=$(python3 -B "$measure" --render "$tmp/w.json"); rc=$?
check "--render: rc 0" "$rc" "0"
check "--render 표가 직접 낸 표와 같다" "$rendered" "$direct"

# ---- usage -------------------------------------------------------------------
python3 -B "$measure" --json >/dev/null 2>&1; rc=$?
check "--runs-root 없으면 rc 2" "$rc" "2"
python3 -B "$measure" --runs-root "$R" --since 2099/11/01 >/dev/null 2>&1; rc=$?
check "잘못된 날짜는 rc 2" "$rc" "2"
python3 -B "$measure" --runs-root "$tmp/없음" >/dev/null 2>&1; rc=$?
check "없는 런 루트는 rc 2" "$rc" "2"
python3 -B "$measure" --runs-root "$R" --sample 3 --seed 1 >/dev/null 2>&1; rc=$?
check "--json 없는 --sample 은 rc 2" "$rc" "2"

printf '\n%d passed, %d failed\n' "$passed" "$failures"
[ "$failures" -eq 0 ]
