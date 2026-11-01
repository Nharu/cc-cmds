#!/usr/bin/env bash
# Test scripts/measure-lead-context.py against synthetic run ledgers and
# synthetic lead transcripts built under a mktemp directory.
#
# Nothing here reads a real home directory: the script takes every input path
# as a required argument, and the fixtures are generated below. Pointing the
# test at real session history would fail on a machine with no history and pass
# non-deterministically on one that has it — the second outcome being the
# worse, since it certifies nothing while looking green.
#
# Every expected value is counted by hand from the small sessions the generator
# writes; the comments beside each session give the counts. The one
# calibration pair in the whole fixture is S1's first tool result (4000 chars
# over a context increase of 2000), so the calibration value is exactly 2.0 and
# every token estimate below is a character count halved.

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
measure="$script_dir/measure-lead-context.py"
fleet="$repo_root/plugins/cc-cmds/orchestrator/fleet.sh"

failures=0
passed=0

pass() { passed=$((passed + 1)); echo "PASS: $1"; }
fail() { failures=$((failures + 1)); echo "FAIL: $1" >&2; }

tmp=$(mktemp -d "${TMPDIR:-/tmp}/test-measure-lead-context.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

# ---- fixture generator -------------------------------------------------------

cat > "$tmp/gen.py" <<'PY'
import json, os, sys

root = sys.argv[1]


def sid(n):
    return "00000000-0000-4000-8000-%012d" % n


S1, S2, S3, W1 = sid(1), sid(2), sid(3), sid(4)
R1, R2, R3, R4, R5, R6 = (sid(n) for n in range(11, 17))
LF1, LF2, ROUTER, NOKIND, RC1, RC2 = sid(21), sid(22), sid(23), sid(24), sid(25), sid(26)
OUT1, OUT2, NOTE1 = sid(31), sid(32), sid(33)


class T(object):
    def __init__(self):
        self.lines = []
        self.n = 0

    def req(self, ctx, tools=(), out=10, usage=None, mid=None, side=False):
        self.n += 1
        u = usage or {"input_tokens": ctx, "output_tokens": out, "cache_read_input_tokens": 0,
                      "cache_creation_input_tokens": 0,
                      "cache_creation": {"ephemeral_5m_input_tokens": 0, "ephemeral_1h_input_tokens": 0}}
        content = [{"type": "tool_use", "name": n, "id": i, "input": ({"file_path": p} if p else {})}
                   for n, p, i in tools]
        o = {"type": "assistant", "message": {"id": mid or "m%d" % self.n, "usage": u, "content": content}}
        if side:
            o["isSidechain"] = True
        self.lines.append(o)

    def results(self, *pairs):
        self.lines.append({"type": "user", "message": {"content": [
            {"type": "tool_result", "tool_use_id": i, "content": "x" * n} for i, n in pairs]}})

    def boundary(self, pre, post, summary=None):
        self.lines.append({"type": "system", "subtype": "compact_boundary",
                           "compactMetadata": {"trigger": "auto", "preTokens": pre,
                                               "postTokens": post, "durationMs": 1}})
        if summary is not None:
            self.lines.append({"type": "user", "isCompactSummary": True,
                               "message": {"content": "y" * summary}})

    def write(self, base, s):
        d = os.path.join(root, base, "projects", "-fixture")
        if not os.path.isdir(d):
            os.makedirs(d)
        with open(os.path.join(d, s + ".jsonl"), "w") as f:
            for o in self.lines:
                f.write(json.dumps(o) + "\n")


# S1 design: two compactions, no control window (its first 200k request sits
# next to the first boundary). The only calibration pair: a1 4000 chars, context
# 50000 + output 10 + 2000 = 52010.
t = T()
t.req(50000, [("Read", "/a", "a1")])
t.results(("a1", 4000))
t.req(52010, [("Read", "/b", "b1"), ("Bash", None, "sh1")])
t.results(("b1", 1000), ("sh1", 10))
t.req(250000, [("Edit", "/a", "e1")])
t.results(("e1", 10))
t.boundary(260000, 20000, summary=4000)
t.req(30000, [("Read", "/a", "a2")])
t.results(("a2", 1800))
t.req(30000, [("Read", "/c", "c1")])
t.results(("c1", 1000))
t.req(30000, [("Write", "/w", "w1")])
t.results(("w1", 10))
t.req(30000, [("Bash", None, "sh2")])
t.results(("sh2", 10))
for _ in range(6):
    t.req(30000)
t.boundary(270000, 22000)
t.req(30000, [("Read", "/c", "c2")])
t.results(("c2", 500))
t.req(30000)
t.write("t1", S1)

# S2 design: control window from request 2 to 11, no re-read inside it. A
# smaller decoy file of the same name sits under the other transcript root.
t = T()
t.req(100000, [("Read", "/x", "x1")])
t.results(("x1", 500))
t.req(150000)
t.req(210000, [("Read", "/y", "y1"), ("Bash", None, "sh1")])
t.results(("y1", 600), ("sh1", 10))
t.req(220000, [("Edit", "/y", "e1")])
t.results(("e1", 10))
for _ in range(8):
    t.req(220000)
t.write("t2", S2)
t = T()
t.req(1000)
t.write("t1", S2)

# S3 implement: request 0 is split over two lines (first line's input counts,
# both lines' Reads count), a sidechain request in between is ignored, control
# at request 0 and one compaction at request 10 with ten requests after it.
t = T()
t.req(210000, [("Read", "/p", "p1")], out=3, mid="split")
t.req(999, [("Read", "/q", "q1")], out=7, mid="split")
t.results(("p1", 300), ("q1", 400))
t.req(205000, [("Read", "/p", "p2")])
t.results(("p2", 100))
t.req(50000, [("Read", "/p", "side1")], side=True)
for _ in range(8):
    t.req(205000)
t.boundary(280000, 30000, summary=1000)
t.req(30000, [("Read", "/q", "q2")])
t.results(("q2", 200))
for _ in range(9):
    t.req(30000)
t.write("t1", S3)

# W1 audit: the weights. 1000*1 + 100*5 + 10000*0.1 + 3000*2 + 2000*1.25
# + 4000*1.25 (no breakdown: all of it counts as a 5m write) = 16000.
t = T()
t.req(0, usage={"input_tokens": 1000, "output_tokens": 100, "cache_read_input_tokens": 10000,
                "cache_creation_input_tokens": 5000,
                "cache_creation": {"ephemeral_5m_input_tokens": 2000, "ephemeral_1h_input_tokens": 3000}})
t.req(0, usage={"input_tokens": 0, "output_tokens": 0, "cache_read_input_tokens": 0,
                "cache_creation_input_tokens": 4000})
t.write("t1", W1)

# Reviews: every one reaches 200k; R1 and R2 compact.
for s in (R1, R2):
    t = T()
    t.req(250000)
    t.boundary(260000, 20000, summary=100)
    t.req(20000)
    t.write("t1", s)
for s in (R3, R4, R5, R6):
    t = T()
    t.req(250000)
    t.write("t1", s)

for s in (LF1, LF2, ROUTER, OUT2, NOTE1):
    t = T()
    t.req(1000)
    t.write("t1", s)
t = T()
t.req(250000)
t.write("t1", OUT1)
t = T()
t.lines.append({"type": "user", "message": {"content": "hello"}})
t.write("t1", RC2)


def row(kind, s, cls, window, transient=None):
    parts = ["- `stage-result`", "교대=1", "세그먼트=A", "스테이지=A"]
    if kind is not None:
        parts.append("종류=" + kind)
    parts += ["세션 id=" + s, "압축 창=" + window, "종단 부류=" + cls]
    if transient is not None:
        parts.append("일시 원인=" + transient)
    parts.append("prev=0")
    return " | ".join(parts) + "\n"


LANE, ARGV = "300000(레인)", "300000(argv)"


def ledger(d, name, rows):
    p = os.path.join(root, d)
    if not os.path.isdir(p):
        os.makedirs(p)
    with open(os.path.join(p, name), "w") as f:
        f.write("# ledger\n- `run` | 교대=0 | run-id=x\n")
        f.writelines(rows)


ledger("l1", "20261024-aaaaaaaa.md", [
    row("design", S1, "정상 완료", LANE),
    row("implement", S3, "정상 완료", LANE),
    row("review", R1, "공허한 성공", ARGV),
    row("review", R2, "크래시", ARGV, transient="예"),
    row("audit", W1, "정상 완료", LANE),
    row(None, NOKIND, "정상 완료", LANE),
    row("router", ROUTER, "정상 완료", LANE),
    row("design", "-", "정상 완료", LANE),
    row("reconverge", RC1, "정상 완료", LANE),
    row("lead-fix", LF1, "정상 완료", LANE),
])
ledger("l1", "20261031-bbbbbbbb.md", [
    row("design", S2, "산출물 없는 정지", LANE),
    row("review", R3, "크래시", ARGV),
    row("review", R4, "외부 종료", ARGV),
    row("review", R4, "한도 종료", ARGV),
    row("review", R5, "한도-형상 회수", ARGV),
    row("review", R5, "거절 종료", ARGV),
    row("review", R5, "", ARGV),
    row("review", R6, "크래시", ARGV, transient="아니오"),
    row("reconverge", RC2, "정상 완료", LANE),
    row("lead-fix", LF2, "정상 완료", "230000(argv)"),
])
ledger("l1", "20261023-cccccccc.md", [row("design", OUT1, "공허한 성공", LANE)])
ledger("l1", "20261101-dddddddd.md", [row("design", OUT2, "정상 완료", LANE)])
ledger("l1", "notes.md", [row("design", NOTE1, "정상 완료", LANE)])
ledger("l2", "20261025-eeeeeeee.md", [row("lead-fix", R1, "정상 완료", LANE)])
os.symlink(os.path.join(root, "l1"), os.path.join(root, "l3"))
os.makedirs(os.path.join(root, "empty"))
PY

python3 -I "$tmp/gen.py" "$tmp"

# ---- checker -----------------------------------------------------------------
# Prints one PASS:/FAIL: line per assertion and DONE last, so a crash in the
# checker shows up as a missing DONE rather than as silence.

cat > "$tmp/check.py" <<'PY'
import json, math, re, sys

main = json.load(open(sys.argv[1]))
second = json.load(open(sys.argv[2]))
fleet = open(sys.argv[3]).read()


def check(name, got, want, tol=None):
    ok = (got is not None and abs(got - want) <= tol) if tol is not None else got == want
    print("%s: %s (got %r, want %r)" % ("PASS" if ok else "FAIL", name, got, want))


K = main["kinds"]
d, imp, rev, aud, lf, rc = K["design"], K["implement"], K["review"], K["audit"], K["lead-fix"], K["reconverge"]

check("top-level keys", sorted(main), sorted(["scope", "windows", "weights", "calibration", "kinds", "total"]))
check("kind keys", sorted(K), sorted(["design", "audit", "reconverge", "implement", "review", "lead-fix"]))
check("scope", main["scope"], {"collected": 16, "with_transcript": 14, "excluded_kind": 2,
                                "excluded_no_requests": 1})
check("calibration (one pair, 4000/2000)", main["calibration"], {"chars_per_token": 2.0, "pairs": 1})
check("windows all (symlinked ledger dir read once)", main["windows"]["all"],
      {"230000(argv)": 1, "300000(argv)": 9, "300000(레인)": 8})
check("windows lead-fix", main["windows"]["lead-fix"], {"230000(argv)": 1, "300000(레인)": 2})
check("lead-fix window mixed", lf["window_mixed"], True)
check("review window not mixed", rev["window_mixed"], False)

# Sessions: out-of-period ledgers, notes.md, a non-session id, a kind outside
# the six, a missing kind and a transcript with no request all stay out; R1's
# kind is its first row's (review), not its later lead-fix row's.
check("sessions per kind", [K[k]["sessions"] for k in ("design", "audit", "reconverge", "implement", "review", "lead-fix")],
      [2, 1, 0, 1, 6, 2])
check("total sessions", main["total"]["sessions"], 12)

# Weights against fleet.sh's jq expression, and the weighted sum of W1.
fw = {}
for key, field in (("input", r"\$u\.input_tokens"), ("output", r"\$u\.output_tokens"),
                   ("read", r"\$u\.cache_read_input_tokens"),
                   ("write_1h", r"\$u\.cache_creation\.ephemeral_1h_input_tokens"),
                   ("write_5m", r"\$u\.cache_creation\.ephemeral_5m_input_tokens"),
                   ("write_none", r"\$u\.cache_creation_input_tokens")):
    m = re.search(field + r" // 0\) \* ([0-9.]+)\)", fleet)
    fw[key] = float(m.group(1)) if m else None
check("weights equal fleet.sh", main["weights"],
      {k: fw[k] for k in ("input", "output", "read", "write_1h", "write_5m")})
check("fleet.sh no-breakdown weight equals 5m weight", fw["write_none"], main["weights"]["write_5m"])
check("audit weighted_m", aud["weighted_m"], 0.016, 1e-9)
check("audit price_usd", aud["price_usd"], 0.24, 1e-9)
check("audit 1h write tokens", aud["write_1h_tokens"], 3000)
check("audit 5m write tokens (no breakdown counts as 5m)", aud["write_5m_tokens"], 6000)
check("audit ge200k pct", aud["weighted_ge200k_pct"], 0.0, 1e-9)

# (가) (session, path) pairs: S1 /a /b /c (two read twice), S2 /x /y.
check("design reread paths", d["reread_paths"], {"pairs": 5, "pairs_2plus": 2, "pct": 40.0})
check("implement reread paths (split request reads both count)", imp["reread_paths"],
      {"pairs": 2, "pairs_2plus": 2, "pct": 100.0})

# (나) S1: pre 260000/270000, post 20000/22000, summaries 4000 and none (0).
c = d["compaction"]
check("design compaction count", c["count"], 2)
check("design pre median", c["pre_median"], 265000, 1e-9)
check("design post median", c["post_median"], 21000, 1e-9)
check("design summary tokens median (missing summary counts 0)", c["summary_tokens_median"], 1000.0, 1e-9)
check("design read tokens after mean", c["read_tokens_after_mean"], 825.0, 1e-9)
check("design reread tokens after mean", c["reread_tokens_after_mean"], 575.0, 1e-9)
check("implement compaction", [imp["compaction"][k] for k in ("count", "summary_tokens_median", "read_tokens_after_mean")],
      [1, 500.0, 100.0])

# (다) split at the first 200k request, in time order: S1's requests after its
# compaction (context 30000) fall in the after part.
p = d["phase_split"]
check("design phase requests", [p["sessions"], p["requests_before"], p["requests_after"]], [2, 4, 23])
check("design edit/write before", p["edit_write_before"], 0.0, 1e-9)
check("design edit/write after", p["edit_write_after"], 3 / 23.0, 1e-9)
check("design bash before", p["bash_before"], 0.25, 1e-9)
check("design bash after", p["bash_after"], 2 / 23.0, 1e-9)
check("design read before", p["read_before"], 0.75, 1e-9)
check("design read after", p["read_after"], 4 / 23.0, 1e-9)
check("implement phase (sidechain out, no request before)",
      [imp["phase_split"][k] for k in ("requests_before", "requests_after", "edit_write_before", "read_after")],
      [0, 20, None, 0.2])


def wilson(x, n, z=1.96):
    p = x / float(n)
    den = 1 + z * z / n
    cen = (p + z * z / (2 * n)) / den
    half = z * math.sqrt(p * (1 - p) / n + z * z / (4.0 * n * n)) / den
    return p, cen - half, cen + half


# Signal A. Design: S1's first boundary is the one sample (re-read), S2's
# control has none. 1/1 against 0/1 with w = 1.96^2 = 3.8416:
# Wilson(0,1) = [0, w/(1+w)] = [0, 0.79346], Wilson(1,1) = [0.20654, 1];
# low = 1 - sqrt((1 - 0.20654)^2 + 0.79346^2) = 1 - 1.12212 = -0.12212.
a = d["signal_a"]
check("design A descriptive", [a["boundaries"], a["boundaries_reread"], a["boundaries_reread_pct"]], [2, 2, 100.0])
check("design A samples", [a["compacted_reread"], a["compacted_n"], a["control_reread"], a["control_n"]], [1, 1, 0, 1])
check("design A diff", a["diff_pp"], 100.0, 1e-9)
check("design A ci low (hand value)", a["ci_low_pp"], -12.212, 0.001)
check("design A ci high (width not zero at a 0 or 1 rate)", a["ci_high_pp"], 100.0, 1e-9)
check("design A history medians", [a["history_median_compacted"], a["history_median_control"]], [2, 1])
check("design A reread tokens", [a["reread_tokens_compacted_mean"], a["reread_tokens_control_mean"]], [900.0, 0.0])
check("design A sessions in both", a["sessions_in_both"], 0)
a = imp["signal_a"]
check("implement A samples (control at request 0 survives)", [a["compacted_n"], a["control_n"], a["sessions_in_both"]], [1, 1, 1])
check("implement A history medians", [a["history_median_compacted"], a["history_median_control"]], [2, 0])
# S1's second boundary has two requests after it: in the descriptive values,
# not in the interval sample.
a = main["total"]["signal_a"]
check("total A boundaries all counted", [a["boundaries"], a["compacted_n"], a["control_n"]], [5, 2, 2])
a = rev["signal_a"]
check("review A no sample on either side", [a["compacted_n"], a["control_n"], a["diff_pp"], a["ci_low_pp"], a["ci_high_pp"]],
      [0, 0, None, None, None])

# Signal B.
b = d["signal_b"]
check("design B", [b["compacted_fail"], b["compacted_n"], b["uncompacted_fail"], b["uncompacted_n"]], [0, 1, 1, 1])
check("design B diff", b["diff_pp"], -100.0, 1e-9)
check("design B ci low", b["ci_low_pp"], -100.0, 1e-6)
check("design B ci high (mirror of design A low)", b["ci_high_pp"], 12.212, 0.001)
b = rev["signal_b"]
check("review B counts (quality failure list)", [b["compacted_fail"], b["compacted_n"], b["uncompacted_fail"], b["uncompacted_n"]],
      [1, 2, 2, 4])
p1, l1, u1 = wilson(1, 2)
p2, l2, u2 = wilson(2, 4)
check("review B diff", b["diff_pp"], 0.0, 1e-9)
check("review B ci low", b["ci_low_pp"], -100 * math.sqrt((p1 - l1) ** 2 + (u2 - p2) ** 2), 1e-6)
check("review B ci high", b["ci_high_pp"], 100 * math.sqrt((u1 - p1) ** 2 + (p2 - l2) ** 2), 1e-6)
check("review B classes compacted", b["classes_compacted"],
      {"공허한 성공": 1, "정상 완료": 1, "크래시(일시 원인=예)": 1})
check("review B classes uncompacted", b["classes_uncompacted"],
      {"(빈 부류)": 1, "거절 종료": 1, "외부 종료": 1, "크래시(일시 원인=아니오)": 1,
       "크래시(일시 원인=없음)": 1, "한도 종료": 1, "한도-형상 회수": 1})
check("review B failure then more rows", [b["fail_then_more_compacted"], b["fail_then_more_uncompacted"]], [1, 0])
b = imp["signal_b"]
check("implement B one side empty", [b["compacted_n"], b["uncompacted_n"], b["compacted_pct"], b["diff_pp"], b["ci_low_pp"], b["ci_high_pp"]],
      [1, 0, 0.0, None, None, None])

# A kind with no session prints nulls without failing.
check("reconverge empty", [rc["sessions"], rc["weighted_m"], rc["compaction"]["pre_median"], rc["signal_a"]["diff_pp"]],
      [0, None, None, None])

# No verdict key anywhere.
keys = []


def walk(o):
    if isinstance(o, dict):
        for k, v in o.items():
            keys.append(k)
            walk(v)


walk(main)
check("no verdict key", [k for k in keys if re.search(r"verdict|판정", k)], [])

# The second period starts after S1's ledger: no calibration pair at all.
check("no pair: calibration null", second["calibration"], None)
# R1 is read from the later ledger alone here, so its kind is lead-fix.
check("no pair: token estimates null", [second["kinds"]["lead-fix"]["compaction"]["summary_tokens_median"],
                                        second["kinds"]["design"]["signal_a"]["reread_tokens_control_mean"]], [None, None])
check("no pair: compaction still counted", second["kinds"]["lead-fix"]["compaction"]["count"], 1)
check("second period sessions", second["total"]["sessions"], 7)
print("DONE")
PY

# ---- run --------------------------------------------------------------------

common=(--ledger-dir "$tmp/l1" --ledger-dir "$tmp/l2" --ledger-dir "$tmp/l3"
        --transcripts "$tmp/t1" --transcripts "$tmp/t2")

set +e
python3 -I "$measure" "${common[@]}" --from 20261024 --to 20261031 --json > "$tmp/main.json" 2> "$tmp/main.err"
ec_json=$?
python3 -I "$measure" "${common[@]}" --from 20261024 --to 20261031 > "$tmp/main.txt" 2> "$tmp/main.err2"
ec_txt=$?
python3 -I "$measure" "${common[@]}" --from 20261025 --to 20261031 --json > "$tmp/second.json" 2>/dev/null
ec_second=$?
python3 -I "$measure" "${common[@]}" --from 20261025 --to 20261031 > "$tmp/second.txt" 2>/dev/null
set -e

if [[ "$ec_json" == "0" && "$ec_txt" == "0" ]]; then
  pass "fixture run exits 0 (json and table)"
else
  fail "fixture run exit codes json=$ec_json table=$ec_txt"
  cat "$tmp/main.err" "$tmp/main.err2" >&2 || true
fi
if [[ "$ec_second" == "0" ]]; then
  pass "period with no calibration pair exits 0"
else
  fail "period with no calibration pair should exit 0, got $ec_second"
fi

done_seen=0
while IFS= read -r line; do
  case "$line" in
    PASS:*) pass "${line#PASS: }" ;;
    FAIL:*) fail "${line#FAIL: }" ;;
    DONE) done_seen=1 ;;
  esac
done < <(python3 -I "$tmp/check.py" "$tmp/main.json" "$tmp/second.json" "$fleet" 2>&1)
if [[ "$done_seen" == "1" ]]; then
  pass "json checker ran to the end"
else
  fail "json checker did not finish"
fi

# ---- table ------------------------------------------------------------------

if grep -q '^적용 범위: 모은 세션 16 · 주 전사 있음 14 · 여섯 종류 밖이거나 종류 없음 2 · 요청 없음 1 · 측정 12$' "$tmp/main.txt"; then
  pass "table scope line"
else
  fail "table scope line"
fi
if grep -q '^압축 창 분포: 전체 {230000(argv)=1, 300000(argv)=9, 300000(레인)=8}' "$tmp/main.txt"; then
  pass "table window distribution line"
else
  fail "table window distribution line"
fi
if grep -q '^보정값: 2.000 문자/토큰 (쌍 1)$' "$tmp/main.txt"; then
  pass "table calibration line"
else
  fail "table calibration line"
fi
if grep -q '^  신호 A \[창 230000(argv), 300000(레인) · 창 혼재 — 창별 효과를 가르지 않음\]' "$tmp/main.txt"; then
  pass "table mixed-window marker on lead-fix"
else
  fail "table mixed-window marker on lead-fix"
fi
mixed_lines=$(grep -c '창 혼재' "$tmp/main.txt" || true)
if [[ "$mixed_lines" == "4" ]]; then
  pass "mixed-window marker only on lead-fix and the six-kind total (4 signal lines)"
else
  fail "mixed-window marker should sit on 4 signal lines, got $mixed_lines"
fi
if grep -q '^\[reconverge\] 세션 0$' "$tmp/main.txt" && grep -A1 '^\[reconverge\] 세션 0$' "$tmp/main.txt" | grep -q '가중 합계 -M'; then
  pass "table prints - for a kind with no session"
else
  fail "table prints - for a kind with no session"
fi
if grep -q '(opus 입력 \$15/M 가정)' "$tmp/main.txt"; then
  pass "table names the opus list price assumption"
else
  fail "table names the opus list price assumption"
fi
if grep -q '처음 200k 이전 → 이후' "$tmp/main.txt"; then
  pass "table names the time-ordered split"
else
  fail "table names the time-ordered split"
fi
if grep -q '^보정값: - — 보정 쌍이 하나도 없어' "$tmp/second.txt"; then
  pass "table states why token estimates are missing"
else
  fail "table states why token estimates are missing"
fi
if grep -E -q '판정|verdict|신호 있음|신호 없음' "$tmp/main.txt" "$tmp/main.json" "$tmp/second.txt"; then
  fail "output carries a verdict line or key"
else
  pass "no verdict line or key in table or json"
fi

# ---- exit codes -------------------------------------------------------------

expect_exit() {
  local want=$1 label=$2 ec
  shift 2
  set +e
  python3 -I "$measure" "$@" >/dev/null 2>&1
  ec=$?
  set -e
  if [[ "$ec" == "$want" ]]; then
    pass "$label exits $want"
  else
    fail "$label should exit $want, got $ec"
  fi
}

expect_exit 2 "missing --ledger-dir" --transcripts "$tmp/t1" --from 20261024 --to 20261031
expect_exit 2 "missing --transcripts" --ledger-dir "$tmp/l1" --from 20261024 --to 20261031
expect_exit 2 "missing --from" --ledger-dir "$tmp/l1" --transcripts "$tmp/t1" --to 20261031
expect_exit 2 "missing directory" --ledger-dir "$tmp/no-such" --transcripts "$tmp/t1" --from 20261024 --to 20261031
expect_exit 2 "seven-digit date" --ledger-dir "$tmp/l1" --transcripts "$tmp/t1" --from 2026102 --to 20261031
expect_exit 2 "impossible date" --ledger-dir "$tmp/l1" --transcripts "$tmp/t1" --from 20261332 --to 20261231
expect_exit 2 "--from later than --to" --ledger-dir "$tmp/l1" --transcripts "$tmp/t1" --from 20261031 --to 20261024
expect_exit 1 "no transcript for any session" --ledger-dir "$tmp/l1" --transcripts "$tmp/empty" --from 20261024 --to 20261031
expect_exit 1 "no ledger in the period" --ledger-dir "$tmp/l1" --transcripts "$tmp/t1" --from 20250101 --to 20250131
expect_exit 0 "single-day period on both ends" --ledger-dir "$tmp/l1" --transcripts "$tmp/t1" --from 20261101 --to 20261101

echo "test-measure-lead-context: $passed passed, $failures failed"

if (( failures > 0 )); then
  exit 1
fi
exit 0
