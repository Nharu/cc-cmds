#!/usr/bin/env python3
"""Measure how the stage lead's context grows, per stage kind, over a ledger period.

    measure-lead-context.py --ledger-dir DIR [--ledger-dir DIR ...]
                            --transcripts DIR [--transcripts DIR ...]
                            --from YYYYMMDD --to YYYYMMDD [--json]

This is NOT a gate. Nothing here passes or fails a change; the output is the
input to a human judgment call about each stage kind's auto-compact window.
`make test` runs this script against synthetic fixtures only, never against
real session history.

What it reads:

  run ledgers      every `<YYYYMMDD>-<8 hex>.md` directly under each
                   `--ledger-dir` whose run id date lies in the period (both
                   ends included). Its `- `stage-result`` rows give each
                   session id its stage kind (the `종류` of the first row read
                   for that session), its terminal classes and its window.
                   "First" follows the order the `--ledger-dir` options were
                   given, then file name order inside one directory, then line
                   order inside one file. A ledger reached twice through
                   different directories is read once (real path).
  transcripts      `projects/*/<session id>.jsonl` under each `--transcripts`;
                   when one session id has several files, the largest is the
                   lead's main transcript.

Every input path is REQUIRED and has NO default pointing at a real home
directory. A default would make this script pass non-deterministically on a
machine that happens to have session history and fail on one that does not —
and the passing case is the worse of the two, because it certifies nothing
while looking like a pass.

It prints values, never a verdict. The two quality signals (A: re-reads right
after a compaction against a control window with no compaction; B: quality
failures of sessions that reached 200k with and without a compaction) are
printed with their samples, the difference d = p1 - p2 (p1 the compacted
side) and its Newcombe 95% interval built from two Wilson score intervals
(z = 1.96). Whether a window may change is decided by the person who reads
them. A signal line is a statement about the window written on that line: in a
period that holds one window value only, "no difference" at that window is not
evidence that a lower window is safe, so this script never prints a line that
reads as such a permission.

The weights are the weekly-limit weights of the weighted token expression in
`plugins/cc-cmds/orchestrator/fleet.sh` (input 1.0, output 5.0, cache read
0.1, 1h cache write 2.0, 5m cache write 1.25; a usage with no cache write
breakdown counts its whole cache write as 5m). The list price is weighted
million tokens x $15, which assumes every lead ran on opus (input $15/M).

`--json` prints one object with six top-level keys:

  scope        collected, with_transcript, excluded_kind, excluded_no_requests
  windows      {"all": {window: rows}, "<kind>": {window: rows}, ...}
  weights      input, output, read, write_1h, write_5m
  calibration  {"chars_per_token": float, "pairs": int}, or null with no pair
  kinds        {"<kind>": <kind object>} for design, audit, reconverge,
               implement, review, lead-fix
  total        a kind object over the six kinds together

A kind object holds: sessions, weighted_m, price_usd, write_1h_tokens,
write_5m_tokens, weighted_ge200k_pct, windows, window_mixed,
reread_paths {pairs, pairs_2plus, pct},
compaction {count, pre_median, post_median, summary_tokens_median,
            read_tokens_after_mean, reread_tokens_after_mean},
phase_split {sessions, requests_before, requests_after, edit_write_before,
             edit_write_after, bash_before, bash_after, read_before,
             read_after},
signal_a {boundaries, boundaries_reread, boundaries_reread_pct, compacted_n,
          compacted_reread, compacted_pct, control_n, control_reread,
          control_pct, diff_pp, ci_low_pp, ci_high_pp,
          history_median_compacted, history_median_control, sessions_in_both,
          reread_tokens_compacted_mean, reread_tokens_control_mean},
signal_b {compacted_n, compacted_fail, compacted_pct, uncompacted_n,
          uncompacted_fail, uncompacted_pct, diff_pp, ci_low_pp, ci_high_pp,
          classes_compacted, classes_uncompacted, fail_then_more_compacted,
          fail_then_more_uncompacted}.
A value that cannot be computed is null in JSON and `-` in the table.

Exit codes: 0 when at least one session was measured (one of the six kinds,
with a main transcript and at least one request), 1 when none was (the table
or object is still printed), 2 for a usage error. It writes to stdout only and
creates no file.
"""
import sys

sys.dont_write_bytecode = True

import argparse  # noqa: E402
import datetime  # noqa: E402
import glob  # noqa: E402
import json  # noqa: E402
import math  # noqa: E402
import os  # noqa: E402
import re  # noqa: E402
import statistics  # noqa: E402
from collections import Counter, OrderedDict  # noqa: E402

KINDS = ["design", "audit", "reconverge", "implement", "review", "lead-fix"]
WEIGHTS = OrderedDict([("input", 1.0), ("out", 5.0), ("read", 0.1), ("c1", 2.0), ("c5", 1.25)])
PRICE_PER_WEIGHTED_M = 15.0
EDITS = {"Edit", "Write", "MultiEdit", "NotebookEdit"}
FAIL_CLASSES = {"공허한 성공", "산출물 없는 정지"}
CRASH = "크래시"
THRESHOLD = 200000
AFTER = 10
CALIB_MIN_CHARS = 2000
CALIB_MIN_DELTA = 300
Z = 1.96
LEDGER_RE = re.compile(r"^(\d{8})-[0-9a-f]{8}\.md$")
SID_RE = re.compile(r"^[0-9a-f-]{36}$")
ROW_PREFIX = "- `stage-result`"


def date_arg(s):
    if not re.match(r"^\d{8}$", s):
        raise argparse.ArgumentTypeError("expected YYYYMMDD, got %r" % s)
    try:
        datetime.datetime.strptime(s, "%Y%m%d")
    except ValueError:
        raise argparse.ArgumentTypeError("not a calendar date: %r" % s)
    return s


def read_ledgers(dirs, lo, hi):
    """Session id -> {"kind", "rows": [(class, transient)]}, plus window rows."""
    sessions = OrderedDict()
    windows = {"all": Counter()}
    seen = set()
    for d in dirs:
        for name in sorted(os.listdir(d)):
            m = LEDGER_RE.match(name)
            if not m or not lo <= m.group(1) <= hi:
                continue
            path = os.path.join(d, name)
            real = os.path.realpath(path)
            if real in seen or not os.path.isfile(real):
                continue
            seen.add(real)
            with open(real, encoding="utf-8", errors="replace") as f:
                for line in f:
                    if not line.startswith(ROW_PREFIX):
                        continue
                    fl = {}
                    for p in line.rstrip("\n").split(" | ")[1:]:
                        if "=" in p:
                            k, v = p.split("=", 1)
                            fl[k.strip()] = v.strip()
                    sid = fl.get("세션 id", "")
                    if not SID_RE.match(sid):
                        continue
                    kind = fl.get("종류")
                    e = sessions.setdefault(sid, {"kind": kind, "rows": []})
                    e["rows"].append((fl.get("종단 부류", ""), fl.get("일시 원인")))
                    if kind in KINDS:
                        w = fl.get("압축 창", "-")
                        windows["all"][w] += 1
                        windows.setdefault(kind, Counter())[w] += 1
    return sessions, windows


def index_transcripts(dirs):
    idx = {}
    for d in dirs:
        for p in glob.glob(os.path.join(d, "projects", "*", "*.jsonl")):
            idx.setdefault(os.path.basename(p)[:-6], []).append(p)
    return idx


def text_len(c):
    if isinstance(c, str):
        return len(c)
    n = 0
    for b in c or []:
        if not isinstance(b, dict):
            continue
        if b.get("type") == "text":
            n += len(b.get("text") or "")
        else:
            n += len(json.dumps(b, ensure_ascii=False))
    return n


def parse_transcript(path, calib):
    """Requests in order, compaction boundaries and tool result lengths.

    Calibration pairs found on the way are appended to `calib`.
    """
    reqs, order, bounds, res = {}, [], [], {}
    users = []
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            try:
                o = json.loads(line)
            except ValueError:
                continue
            if not isinstance(o, dict) or o.get("isSidechain"):
                continue
            msg = o.get("message") or {}
            if not isinstance(msg, dict):
                msg = {}
            if o.get("type") == "system" and o.get("subtype") == "compact_boundary":
                md = o.get("compactMetadata") or {}
                bounds.append({"k": len(order), "pre": md.get("preTokens"),
                               "post": md.get("postTokens"), "summ": None})
                users = None
            elif o.get("type") == "assistant" and msg.get("id"):
                u = msg.get("usage") or {}
                r = reqs.get(msg["id"])
                if r is None:
                    cc = u.get("cache_creation") or {}
                    c5 = cc.get("ephemeral_5m_input_tokens")
                    c1 = cc.get("ephemeral_1h_input_tokens")
                    if c5 is None and c1 is None:
                        c5, c1 = u.get("cache_creation_input_tokens") or 0, 0
                    r = reqs[msg["id"]] = {
                        "input": u.get("input_tokens") or 0, "c5": c5 or 0, "c1": c1 or 0,
                        "read": u.get("cache_read_input_tokens") or 0,
                        "out": u.get("output_tokens") or 0, "tools": []}
                    r["ctx"] = r["input"] + r["c5"] + r["c1"] + r["read"]
                    if order and users is not None and len(users) == 1 \
                            and users[0] and users[0] >= CALIB_MIN_CHARS:
                        prev = reqs[order[-1]]
                        delta = r["ctx"] - prev["ctx"] - prev["out"]
                        if delta > CALIB_MIN_DELTA:
                            calib.append(users[0] / float(delta))
                    order.append(msg["id"])
                    users = []
                r["out"] = max(r["out"], u.get("output_tokens") or 0)
                for b in msg.get("content") or []:
                    if isinstance(b, dict) and b.get("type") == "tool_use":
                        inp = b.get("input") or {}
                        r["tools"].append((b.get("name"),
                                           inp.get("file_path") if isinstance(inp, dict) else None,
                                           b.get("id")))
            elif o.get("type") == "user":
                if o.get("isCompactSummary") and bounds and bounds[-1]["summ"] is None:
                    bounds[-1]["summ"] = text_len(msg.get("content"))
                    continue
                c = msg.get("content")
                blocks = c if isinstance(c, list) else []
                tr = [b for b in blocks if isinstance(b, dict) and b.get("type") == "tool_result"]
                for b in tr:
                    res[b.get("tool_use_id")] = text_len(b.get("content"))
                if users is not None:
                    users.append(text_len(tr[0].get("content"))
                                 if len(tr) == 1 and len(blocks) == 1 else None)
    return [reqs[i] for i in order], bounds, res


def reads(r):
    return [(p, i) for n, p, i in r["tools"] if n == "Read" and p]


def window_after(R, res, k0):
    """(any re-read, read chars, re-read chars, history size) of R[k0:k0+10]."""
    before = set(p for r in R[:k0] for p, _ in reads(r))
    hits = [(p in before, res.get(i, 0)) for r in R[k0:k0 + AFTER] for p, i in reads(r)]
    return (any(h for h, _ in hits), sum(c for _, c in hits),
            sum(c for h, c in hits if h), len(before))


def is_quality_failure(row):
    cls, transient = row
    return cls in FAIL_CLASSES or (cls == CRASH and transient != "예")


def class_label(row):
    cls, transient = row
    if cls == CRASH:
        return "%s(일시 원인=%s)" % (CRASH, transient if transient is not None else "없음")
    return cls if cls else "(빈 부류)"


def measure_session(sid, rows, R, bounds, res):
    s = {"sid": sid, "requests": len(R)}
    s["w"] = sum(WEIGHTS[k] * r[k] for r in R for k in WEIGHTS)
    s["w200"] = sum(WEIGHTS[k] * r[k] for r in R if r["ctx"] >= THRESHOLD for k in WEIGHTS)
    s["c1"] = sum(r["c1"] for r in R)
    s["c5"] = sum(r["c5"] for r in R)
    per = Counter(p for r in R for p, _ in reads(r))
    s["paths"] = len(per)
    s["paths2"] = sum(1 for v in per.values() if v >= 2)
    s["bounds"] = []
    for b in bounds:
        hit, rc, rrc, _ = window_after(R, res, b["k"])
        s["bounds"].append({"pre": b["pre"], "post": b["post"], "summ": b["summ"] or 0,
                            "hit": hit, "rc": rc, "rrc": rrc})
    s["comp_sample"] = None
    for b in bounds:
        if b["k"] + AFTER <= len(R):
            hit, _, rrc, hist = window_after(R, res, b["k"])
            s["comp_sample"] = {"hit": hit, "rrc": rrc, "hist": hist}
            break
    s["reached"] = max(r["ctx"] for r in R) >= THRESHOLD
    s["ctrl_sample"] = None
    s["phase"] = None
    s["b_side"] = None
    if s["reached"]:
        k0 = next(i for i, r in enumerate(R) if r["ctx"] >= THRESHOLD)
        if k0 + AFTER <= len(R) and not any(k0 - AFTER <= b["k"] < k0 + AFTER for b in bounds):
            hit, _, rrc, hist = window_after(R, res, k0)
            s["ctrl_sample"] = {"hit": hit, "rrc": rrc, "hist": hist}
        ph = Counter()
        for i, r in enumerate(R):
            z = "after" if i >= k0 else "before"
            ph["req_" + z] += 1
            for name, _, _ in r["tools"]:
                if name in EDITS:
                    ph["edit_" + z] += 1
                elif name == "Bash":
                    ph["bash_" + z] += 1
                elif name == "Read":
                    ph["read_" + z] += 1
        s["phase"] = ph
        s["b_side"] = "cmp" if bounds else "nocmp"
        fails = [i for i, row in enumerate(rows) if is_quality_failure(row)]
        s["b_fail"] = bool(fails)
        s["b_fail_then_more"] = bool(fails) and fails[0] < len(rows) - 1
        s["b_classes"] = sorted(set(class_label(row) for row in rows))
    return s


def median(xs):
    xs = [x for x in xs if x is not None]
    return statistics.median(xs) if xs else None


def mean(xs):
    return sum(xs) / float(len(xs)) if xs else None


def ratio(x, n):
    return 100.0 * x / n if n else None


def per_request(x, n):
    return x / float(n) if n else None


def wilson(x, n):
    p = x / float(n)
    denom = 1 + Z * Z / n
    center = (p + Z * Z / (2 * n)) / denom
    half = Z * math.sqrt(p * (1 - p) / n + Z * Z / (4.0 * n * n)) / denom
    return p, center - half, center + half


def newcombe(x1, n1, x2, n2):
    """(d, low, high) in percentage points, or (None, None, None) with an empty side."""
    if not n1 or not n2:
        return None, None, None
    p1, l1, u1 = wilson(x1, n1)
    p2, l2, u2 = wilson(x2, n2)
    d = p1 - p2
    lo = d - math.sqrt((p1 - l1) ** 2 + (u2 - p2) ** 2)
    hi = d + math.sqrt((u1 - p1) ** 2 + (p2 - l2) ** 2)
    return 100.0 * d, 100.0 * lo, 100.0 * hi


def tokens(chars, cal):
    return chars / cal if (chars is not None and cal) else None


def aggregate(sessions, win, cal):
    k = OrderedDict()
    k["sessions"] = len(sessions)
    w = sum(s["w"] for s in sessions)
    k["weighted_m"] = w / 1e6 if sessions else None
    k["price_usd"] = w / 1e6 * PRICE_PER_WEIGHTED_M if sessions else None
    k["write_1h_tokens"] = sum(s["c1"] for s in sessions) if sessions else None
    k["write_5m_tokens"] = sum(s["c5"] for s in sessions) if sessions else None
    k["weighted_ge200k_pct"] = ratio(sum(s["w200"] for s in sessions), w) if w else None
    k["windows"] = OrderedDict(sorted(win.items()))
    k["window_mixed"] = len(win) > 1
    pairs = sum(s["paths"] for s in sessions)
    pairs2 = sum(s["paths2"] for s in sessions)
    k["reread_paths"] = OrderedDict([("pairs", pairs), ("pairs_2plus", pairs2),
                                     ("pct", ratio(pairs2, pairs))])
    bs = [b for s in sessions for b in s["bounds"]]
    summ = median([b["summ"] for b in bs])
    k["compaction"] = OrderedDict([
        ("count", len(bs)),
        ("pre_median", median([b["pre"] for b in bs])),
        ("post_median", median([b["post"] for b in bs])),
        ("summary_tokens_median", tokens(summ, cal)),
        ("read_tokens_after_mean", tokens(mean([b["rc"] for b in bs]), cal)),
        ("reread_tokens_after_mean", tokens(mean([b["rrc"] for b in bs]), cal))])
    reached = [s for s in sessions if s["reached"]]
    ph = Counter()
    for s in reached:
        ph.update(s["phase"])
    k["phase_split"] = OrderedDict([
        ("sessions", len(reached)),
        ("requests_before", ph["req_before"]), ("requests_after", ph["req_after"]),
        ("edit_write_before", per_request(ph["edit_before"], ph["req_before"])),
        ("edit_write_after", per_request(ph["edit_after"], ph["req_after"])),
        ("bash_before", per_request(ph["bash_before"], ph["req_before"])),
        ("bash_after", per_request(ph["bash_after"], ph["req_after"])),
        ("read_before", per_request(ph["read_before"], ph["req_before"])),
        ("read_after", per_request(ph["read_after"], ph["req_after"]))])
    comp = [s["comp_sample"] for s in sessions if s["comp_sample"]]
    ctrl = [s["ctrl_sample"] for s in sessions if s["ctrl_sample"]]
    x1, n1 = sum(1 for c in comp if c["hit"]), len(comp)
    x2, n2 = sum(1 for c in ctrl if c["hit"]), len(ctrl)
    d, lo, hi = newcombe(x1, n1, x2, n2)
    k["signal_a"] = OrderedDict([
        ("boundaries", len(bs)),
        ("boundaries_reread", sum(1 for b in bs if b["hit"])),
        ("boundaries_reread_pct", ratio(sum(1 for b in bs if b["hit"]), len(bs))),
        ("compacted_n", n1), ("compacted_reread", x1), ("compacted_pct", ratio(x1, n1)),
        ("control_n", n2), ("control_reread", x2), ("control_pct", ratio(x2, n2)),
        ("diff_pp", d), ("ci_low_pp", lo), ("ci_high_pp", hi),
        ("history_median_compacted", median([c["hist"] for c in comp])),
        ("history_median_control", median([c["hist"] for c in ctrl])),
        ("sessions_in_both", sum(1 for s in sessions if s["comp_sample"] and s["ctrl_sample"])),
        ("reread_tokens_compacted_mean", tokens(mean([c["rrc"] for c in comp]), cal)),
        ("reread_tokens_control_mean", tokens(mean([c["rrc"] for c in ctrl]), cal))])
    cmp_ = [s for s in reached if s["b_side"] == "cmp"]
    nocmp = [s for s in reached if s["b_side"] == "nocmp"]
    x1, n1 = sum(1 for s in cmp_ if s["b_fail"]), len(cmp_)
    x2, n2 = sum(1 for s in nocmp if s["b_fail"]), len(nocmp)
    d, lo, hi = newcombe(x1, n1, x2, n2)

    def classes(side):
        c = Counter(label for s in side for label in s["b_classes"])
        return OrderedDict(sorted(c.items()))

    k["signal_b"] = OrderedDict([
        ("compacted_n", n1), ("compacted_fail", x1), ("compacted_pct", ratio(x1, n1)),
        ("uncompacted_n", n2), ("uncompacted_fail", x2), ("uncompacted_pct", ratio(x2, n2)),
        ("diff_pp", d), ("ci_low_pp", lo), ("ci_high_pp", hi),
        ("classes_compacted", classes(cmp_)), ("classes_uncompacted", classes(nocmp)),
        ("fail_then_more_compacted", sum(1 for s in cmp_ if s["b_fail_then_more"])),
        ("fail_then_more_uncompacted", sum(1 for s in nocmp if s["b_fail_then_more"]))])
    return k


def fmt(v, digits=1, pct=False, signed=False):
    if v is None:
        return "-"
    if isinstance(v, float):
        s = ("{:+,.%df}" if signed else "{:,.%df}") % digits
        s = s.format(v)
    else:
        s = "{:+,}".format(v) if signed else "{:,}".format(v)
    return s + ("%" if pct else "")


def fmt_counts(c):
    return "{" + ", ".join("%s=%d" % (k, v) for k, v in c.items()) + "}" if c else "{}"


def window_tag(k):
    tag = ", ".join(k["windows"].keys()) or "-"
    if k["window_mixed"]:
        tag += " · 창 혼재 — 창별 효과를 가르지 않음"
    return "[창 %s]" % tag


def render_kind(name, k, cal_ok):
    out = []
    out.append("[%s] 세션 %d" % (name, k["sessions"]))
    out.append("  비용: 가중 합계 %sM · 정가 $%s (opus 입력 $15/M 가정) · 1시간 쓰기 %s · 5분 쓰기 %s · 200k 이상 가중 비율 %s" % (
        fmt(k["weighted_m"]), fmt(k["price_usd"], 0), fmt(k["write_1h_tokens"]),
        fmt(k["write_5m_tokens"]), fmt(k["weighted_ge200k_pct"], pct=True)))
    rp = k["reread_paths"]
    out.append("  (가) 두 번 이상 Read 한 파일 비율: %s (쌍 %d/%d)" % (
        fmt(rp["pct"], pct=True), rp["pairs_2plus"], rp["pairs"]))
    c = k["compaction"]
    out.append("  (나) 압축 %d회 · 압축 전/후 중앙값 %s / %s · 압축 1회 출력 추정 중앙값 %s · 압축 뒤 10요청 Read 토큰 평균 %s · 그중 재읽기 %s" % (
        c["count"], fmt(c["pre_median"], 0), fmt(c["post_median"], 0),
        fmt(c["summary_tokens_median"], 0) if cal_ok else "-",
        fmt(c["read_tokens_after_mean"], 0) if cal_ok else "-",
        fmt(c["reread_tokens_after_mean"], 0) if cal_ok else "-"))
    p = k["phase_split"]
    out.append("  (다) 처음 200k 이전 → 이후 (세션 %d, 요청 %d → %d): 요청당 Edit·Write %s → %s · Bash %s → %s · Read %s → %s" % (
        p["sessions"], p["requests_before"], p["requests_after"],
        fmt(p["edit_write_before"], 3), fmt(p["edit_write_after"], 3),
        fmt(p["bash_before"], 3), fmt(p["bash_after"], 3),
        fmt(p["read_before"], 3), fmt(p["read_after"], 3)))
    a = k["signal_a"]
    out.append("  신호 A %s: 서술 — 경계 %d, 재읽기 경계 비율 %s · 구간용 — 압축 %d/%d (%s) 대 대조 %d/%d (%s) · 차이 %s · 95%% 구간 %s ~ %s" % (
        window_tag(k), a["boundaries"], fmt(a["boundaries_reread_pct"], pct=True),
        a["compacted_reread"], a["compacted_n"], fmt(a["compacted_pct"], pct=True),
        a["control_reread"], a["control_n"], fmt(a["control_pct"], pct=True),
        fmt(a["diff_pp"], signed=True) + ("%p" if a["diff_pp"] is not None else ""),
        fmt(a["ci_low_pp"], signed=True), fmt(a["ci_high_pp"], signed=True)
        + ("%p" if a["ci_high_pp"] is not None else "")))
    out.append("      이력 크기 중앙값 압축 %s 대 대조 %s · 두 쪽에 함께 든 세션 %d · 재읽기 토큰 평균 압축 %s 대 대조 %s" % (
        fmt(a["history_median_compacted"]), fmt(a["history_median_control"]), a["sessions_in_both"],
        fmt(a["reread_tokens_compacted_mean"], 0) if cal_ok else "-",
        fmt(a["reread_tokens_control_mean"], 0) if cal_ok else "-"))
    b = k["signal_b"]
    out.append("  신호 B %s: 품질 실패 압축 있음 %d/%d (%s) 대 없음 %d/%d (%s) · 차이 %s · 95%% 구간 %s ~ %s" % (
        window_tag(k), b["compacted_fail"], b["compacted_n"], fmt(b["compacted_pct"], pct=True),
        b["uncompacted_fail"], b["uncompacted_n"], fmt(b["uncompacted_pct"], pct=True),
        fmt(b["diff_pp"], signed=True) + ("%p" if b["diff_pp"] is not None else ""),
        fmt(b["ci_low_pp"], signed=True), fmt(b["ci_high_pp"], signed=True)
        + ("%p" if b["ci_high_pp"] is not None else "")))
    out.append("      종단 부류별 세션 수 압축 있음 %s · 없음 %s · 품질 실패 행 뒤에 행이 더 있는 세션 압축 있음 %d · 없음 %d" % (
        fmt_counts(b["classes_compacted"]), fmt_counts(b["classes_uncompacted"]),
        b["fail_then_more_compacted"], b["fail_then_more_uncompacted"]))
    return out


def main(argv=None):
    ap = argparse.ArgumentParser(prog="measure-lead-context.py", allow_abbrev=False,
                                 description="Measure stage lead context growth per stage kind.")
    ap.add_argument("--ledger-dir", action="append", required=True)
    ap.add_argument("--transcripts", action="append", required=True)
    ap.add_argument("--from", dest="date_from", required=True, type=date_arg)
    ap.add_argument("--to", dest="date_to", required=True, type=date_arg)
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args(argv)
    for d in args.ledger_dir + args.transcripts:
        if not os.path.isdir(d):
            ap.error("not a directory: %s" % d)
    if args.date_from > args.date_to:
        ap.error("--from %s is later than --to %s" % (args.date_from, args.date_to))

    rows, windows = read_ledgers(args.ledger_dir, args.date_from, args.date_to)
    idx = index_transcripts(args.transcripts)
    scope = OrderedDict([("collected", len(rows)),
                         ("with_transcript", sum(1 for sid in rows if idx.get(sid))),
                         ("excluded_kind", sum(1 for e in rows.values() if e["kind"] not in KINDS)),
                         ("excluded_no_requests", 0)])
    calib = []
    measured = {kind: [] for kind in KINDS}
    for sid, e in rows.items():
        if e["kind"] not in KINDS or not idx.get(sid):
            continue
        R, bounds, res = parse_transcript(max(idx[sid], key=os.path.getsize), calib)
        if not R:
            scope["excluded_no_requests"] += 1
            continue
        measured[e["kind"]].append(measure_session(sid, e["rows"], R, bounds, res))
    cal = statistics.median(calib) if calib else None
    kinds = OrderedDict((kind, aggregate(measured[kind], windows.get(kind, Counter()), cal))
                        for kind in KINDS)
    total = aggregate([s for kind in KINDS for s in measured[kind]], windows["all"], cal)
    n_measured = total["sessions"]

    if args.json:
        doc = OrderedDict([
            ("scope", scope),
            ("windows", OrderedDict([("all", OrderedDict(sorted(windows["all"].items())))]
                                    + [(kind, OrderedDict(sorted(windows.get(kind, Counter()).items())))
                                       for kind in KINDS])),
            ("weights", OrderedDict([("input", WEIGHTS["input"]), ("output", WEIGHTS["out"]),
                                     ("read", WEIGHTS["read"]), ("write_1h", WEIGHTS["c1"]),
                                     ("write_5m", WEIGHTS["c5"])])),
            ("calibration", OrderedDict([("chars_per_token", cal), ("pairs", len(calib))])
             if calib else None),
            ("kinds", kinds),
            ("total", total)])
        print(json.dumps(doc, ensure_ascii=False, indent=2))
    else:
        lines = ["measure-lead-context: 기간 %s ~ %s (런 id 날짜, 양끝 포함)" % (args.date_from, args.date_to)]
        lines.append("적용 범위: 모은 세션 %d · 주 전사 있음 %d · 여섯 종류 밖이거나 종류 없음 %d · 요청 없음 %d · 측정 %d" % (
            scope["collected"], scope["with_transcript"], scope["excluded_kind"],
            scope["excluded_no_requests"], n_measured))
        lines.append("압축 창 분포: 전체 %s · %s" % (
            fmt_counts(OrderedDict(sorted(windows["all"].items()))),
            " · ".join("%s %s" % (kind, fmt_counts(OrderedDict(sorted(windows.get(kind, Counter()).items()))))
                       for kind in KINDS)))
        if calib:
            lines.append("보정값: %.3f 문자/토큰 (쌍 %d)" % (cal, len(calib)))
        else:
            lines.append("보정값: - — 보정 쌍이 하나도 없어 (나)의 압축 1회 출력 추정과 Read·재읽기 토큰을 찍지 않는다")
        lines.append("가중치: 입력 1.0 · 출력 5.0 · 읽기 0.1 · 1시간 쓰기 2.0 · 5분 쓰기 1.25 · 정가는 가중 백만 토큰 × $15 (opus 입력 $15/M 가정)")
        for kind in KINDS:
            lines.extend(render_kind(kind, kinds[kind], bool(calib)))
        lines.extend(render_kind("여섯 종류", total, bool(calib)))
        print("\n".join(lines))
    return 0 if n_measured else 1


if __name__ == "__main__":
    sys.exit(main())
