#!/usr/bin/env python3
"""Measure how much of an unattended stage lead's read-only request chains could
have been batched into fewer requests.

    measure-read-chains.py --runs-root DIR [--since YYYY-MM-DD] [--until YYYY-MM-DD]
                           [--min-plugin-version X.Y.Z]
                           [--json [--sample N --seed S]]
    measure-read-chains.py --render FILE [--samples]
    measure-read-chains.py --agreement VERDICTS FILE [FILE ...]

This is NOT a gate. Nothing here passes or fails a change; the output is a
measurement a person reads to decide whether stage leads should be told to
batch their independent reads. `make test` runs this script against synthetic
fixtures only, never against real run history.

What it reads, under `--runs-root` (REQUIRED, no default pointing at a real
home directory — a default would let the fixture test pass on a machine that
happens to hold run history):

  run directory    every directory directly under the root that holds both a
                   `ledger-path` file and a `log/` directory; any other entry
                   is skipped and counted. `started-at` (epoch seconds) gives
                   the run's UTC date for `--since` and `--until` (both
                   inclusive); a run without a readable one is skipped by
                   either. `plugin/cc-cmds/.claude-plugin/plugin.json` gives the
                   plugin version for `--min-plugin-version`; a run without one
                   is skipped by it.
  attempt log      `log/<stage>#<attempt>.json`, the stage session's stream
                   (one JSON object per line). Routing-shift logs
                   (`shift-<n>.json`) are not stage attempts and are not read.
  run ledger       the file `ledger-path` names. Its `- `stage-result`` rows
                   give each `세션 id` its `종류`. A log is joined to a row by
                   the `session_id` its stream carries; when one session id has
                   rows of several kinds, the row whose `스테이지` and `실행
                   버전` match the log's name decides. A log with no row is
                   counted under `unclassified`.

Requests, calls and chains. Only the lead's records count — a record without a
`parent_tool_use_id`; a member's records enter no figure and no source text.

  request          a distinct assistant `message.id` of the lead, ordered by
                   the line its id first appears on. Its calls are the
                   `tool_use` blocks of every record carrying that id.
  read-only call   a `Read`, `Grep` or `Glob` call; or a `Bash` call whose
                   command, split with `shlex.split`, has a first word ending
                   in `/orchestrator/gate.sh` and either the second word `exec`
                   with `--surface 읽기` (or `--surface=읽기`) before the first
                   `--`, or the second word `snapshot`. A command that cannot
                   be split is not read-only.
  read-only request  a request with at least one call, every one read-only. A
                   request with no call, or with any other call, breaks a
                   chain.
  chain            a maximal run of consecutive read-only requests, counted
                   only when it is at least 3 long.

Dependency (mechanical). Every call of the second and later requests of a
chain is judged; the first request's calls are not.

  tokens           `Read`: `file_path` (path) and an integer `offset` above 1
                   (line number). `Grep`: `pattern` and `glob` (string) and
                   `path` (path). `Glob`: `pattern` (string) and `path` (path).
                   A gate `exec` read: the words after the first `--` except
                   the first of them and those starting with `-` — a word
                   holding `/` is a path, any other a string. A gate
                   `snapshot` has none. A token shorter than 3 characters is
                   dropped.
  source text      the text of the lead's user records — string content,
                   `text` blocks and `tool_result` content (a string or its
                   `text` blocks) — in record order. Assistant text and
                   thinking are not sources.
  match            a string token matches as a substring. A path token matches
                   when the token itself, or — when it has two or more path
                   elements — its last two elements joined with `/`, appears
                   as a substring. A line number token `n` matches the regular
                   expression `(^|[^0-9])n[:-]` (multiline), the shape of
                   `grep -n` and `grep -A` output.
  rule             the call `c` of the chain's request `i` (i >= 2) depends on
                   the earlier request `j` of the same chain when a token of
                   `c` matches the result of a call of `j` and matches no
                   source text that comes before the chain's first request.
                   A call with any dependency is `의존`; one with none is
                   `독립` (it could have been batched).
  depth            the first request has depth 1; request `i` has 1 plus the
                   largest depth of the requests its calls depend on (1 with
                   none). A chain's reducible requests are its length minus its
                   largest depth.

Figures per kind (and for `unclassified`, and `total`, which adds the
classified kinds only):

  stages                    attempt logs joined to the kind
  lead_requests             lead requests
  single_tool_pct           requests with exactly one call / lead_requests
  read_only_pct             read-only requests / lead_requests
  chains                    chains of length 3 or more
  chain_requests            requests inside those chains
  chain_requests_pct        chain_requests / lead_requests
  judged_calls              calls judged
  batchable_calls           judged calls found `독립`
  batchable_call_pct        batchable_calls / judged_calls
  reducible_requests        the sum of the chains' reducible requests
  reducible_pct             reducible_requests / chain_requests
  exec_reads                gate `exec` read calls (inside chains or not)
  dedicated_reads           `Read`, `Grep` and `Glob` calls
  snapshot_calls            gate `snapshot` calls
  exec_read_wait_h          the sum over gate `exec` read calls of the result
                            record's timestamp minus the timestamp of the
                            assistant record carrying the call, in hours
  chain_wall_h              the sum over chain requests of the first call
                            record's timestamp to the last result record's
                            timestamp, in hours
  untimed_calls             calls left out of either wait because a timestamp
                            was missing or unreadable
  chain_cache_read_tokens   the sum over chain requests of
                            `usage.cache_read_input_tokens`, taking for each
                            message id the value of its last record
  reducible_cache_read_est  reducible_requests * (chain_cache_read_tokens /
                            chain_requests)

A value that cannot be computed is null in JSON and `-` in the table.

Output. By default a table: a first line naming the runs root and the
filters, a second line with the scope counts, then a markdown table (header
line, `--- | ...` separator line, rows). `--json` prints one object holding
`scope`, `kinds`, `unclassified` and `total`; with `--sample N --seed S` it
also holds `samples`: N judged calls of the window drawn with
`random.Random(S).sample` from all of them ordered by (run name, log name,
request order, call order), or all of them when there are fewer than N.
`--sample` without `--json` is a usage error.

  sample           `id` (`<run name>/<stage>#<attempt>/<tool_use id>`), the kind, the
                   position in the chain, the call's tool and input, the
                   mechanical verdict and its evidence (each matched token and
                   the chain request whose result held it), for up to four
                   nearest earlier requests of the chain every call's input
                   and the first 800 characters of its result, and for every
                   token the 120 characters around its first match in the
                   source text before the chain and in the chain's earlier
                   results (`없음` when there is none).

`--render FILE` reads an object `--json` printed and prints its table, or with
`--samples` the sample list — number, id, position, call, earlier-request
excerpts and token excerpts, without the mechanical verdict or its evidence,
so the reader judging the samples does not see it. `--agreement VERDICTS FILE
[FILE ...]` reads a verdict file — one `<id><TAB><독립|의존>` line per sample of
the given objects, blank lines and lines starting with `#` skipped — and prints
per object and in total the samples, the agreements, the agreement rate, and
the counts of `기계 독립·리드 의존` and `기계 의존·리드 독립`. A missing,
duplicate or unknown id, or any other value, is a usage error. Neither reads
run history.

Exit codes: 0 when at least one run was read or `--render` / `--agreement`
finished, 1 when no run was read (the table or object is still printed), 2 for
a usage error. It writes to stdout only and creates no file.
"""
import sys

sys.dont_write_bytecode = True

import argparse  # noqa: E402
import bisect  # noqa: E402
import datetime  # noqa: E402
import json  # noqa: E402
import os  # noqa: E402
import random  # noqa: E402
import re  # noqa: E402
import shlex  # noqa: E402
from collections import OrderedDict  # noqa: E402

KINDS = ["design", "audit", "reconverge", "implement", "review", "lead-fix"]
DEDICATED = {"Read", "Grep", "Glob"}
ROW_PREFIX = "- `stage-result`"
LOG_RE = re.compile(r"^(.+)#(\d+)\.json$")
TS_RE = re.compile(r"^(\d{4})-(\d\d)-(\d\d)T(\d\d):(\d\d):(\d\d)(\.\d+)?(Z|[+-]\d\d:\d\d)?$")
MIN_TOKEN = 3
CHAIN_MIN = 3
NEAREST = 4
HEAD = 800
AROUND = 120
NONE = "없음"
INDEPENDENT = "독립"
DEPENDENT = "의존"
VERDICTS = (INDEPENDENT, DEPENDENT)

FIELDS = ["stages", "lead_requests", "single_tool_pct", "read_only_pct", "chains",
          "chain_requests", "chain_requests_pct", "judged_calls", "batchable_calls",
          "batchable_call_pct", "reducible_requests", "reducible_pct", "exec_reads",
          "dedicated_reads", "snapshot_calls", "exec_read_wait_h", "chain_wall_h",
          "untimed_calls", "chain_cache_read_tokens", "reducible_cache_read_est"]
PCT_FIELDS = {"single_tool_pct", "read_only_pct", "chain_requests_pct",
              "batchable_call_pct", "reducible_pct"}
HOUR_FIELDS = {"exec_read_wait_h", "chain_wall_h"}
COUNTS = ["stages", "lead_requests", "single", "read_only", "chains", "chain_requests",
          "judged_calls", "batchable_calls", "reducible_requests", "exec_reads",
          "dedicated_reads", "snapshot_calls", "exec_wait_s", "chain_wall_s",
          "untimed_calls", "chain_cache_read_tokens"]


class UsageError(Exception):
    pass


def date_arg(s):
    try:
        return datetime.datetime.strptime(s, "%Y-%m-%d").date()
    except ValueError:
        raise argparse.ArgumentTypeError("expected YYYY-MM-DD, got %r" % s)


def version_tuple(s):
    if not isinstance(s, str) or not re.match(r"^\d+\.\d+\.\d+$", s):
        return None
    return tuple(int(x) for x in s.split("."))


def version_arg(s):
    v = version_tuple(s)
    if v is None:
        raise argparse.ArgumentTypeError("expected X.Y.Z, got %r" % s)
    return v


def count_arg(s):
    try:
        n = int(s)
    except ValueError:
        n = -1
    if n < 0:
        raise argparse.ArgumentTypeError("expected a non-negative integer, got %r" % s)
    return n


def read_file(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.read()
    except OSError:
        return None


def run_date(run):
    s = (read_file(os.path.join(run, "started-at")) or "").strip()
    if not s.isdigit():
        return None
    return datetime.datetime.fromtimestamp(int(s), datetime.timezone.utc).date()


def plugin_version(run):
    s = read_file(os.path.join(run, "plugin", "cc-cmds", ".claude-plugin", "plugin.json"))
    try:
        return version_tuple(json.loads(s).get("version")) if s else None
    except (ValueError, AttributeError):
        return None


def read_ledger(path):
    """Session id -> [(kind, stage, attempt)] from the `stage-result` rows."""
    rows = {}
    text = read_file(path) if path else None
    for line in (text or "").splitlines():
        if not line.startswith(ROW_PREFIX):
            continue
        fl = {}
        for p in line.split(" | ")[1:]:
            if "=" in p:
                k, v = p.split("=", 1)
                fl[k.strip()] = v.strip()
        sid = fl.get("세션 id")
        if sid and fl.get("종류"):
            rows.setdefault(sid, []).append((fl["종류"], fl.get("스테이지"), fl.get("실행 버전")))
    return rows


def kind_of(rows, sid, stage, attempt):
    cands = rows.get(sid) or []
    kinds = []
    for k, _, _ in cands:
        if k not in kinds:
            kinds.append(k)
    if len(kinds) == 1:
        return kinds[0]
    for k, st, at in cands:
        if st == stage and at == attempt:
            return k
    return kinds[0] if kinds else None


def result_text(content):
    if isinstance(content, str):
        return content
    out = []
    for b in content or []:
        if isinstance(b, dict) and b.get("type") == "text":
            out.append(b.get("text") or "")
    return "\n".join(out)


def timestamp(o):
    """Epoch seconds of a record's `timestamp`, or None."""
    s = o.get("timestamp")
    m = TS_RE.match(s) if isinstance(s, str) else None
    if not m:
        return None
    try:
        dt = datetime.datetime(*(int(m.group(i)) for i in range(1, 7)), tzinfo=datetime.timezone.utc)
    except ValueError:
        return None
    secs = dt.timestamp() + (float(m.group(7)) if m.group(7) else 0.0)
    tz = m.group(8)
    if tz and tz != "Z":
        sign = 1 if tz[0] == "+" else -1
        secs -= sign * (int(tz[1:3]) * 3600 + int(tz[4:6]) * 60)
    return secs


def gate_argv(command):
    """The split command when it calls the gate, else None."""
    if not isinstance(command, str):
        return None
    try:
        argv = shlex.split(command, posix=True)
    except ValueError:
        return None
    if len(argv) < 2 or not argv[0].endswith("/orchestrator/gate.sh"):
        return None
    return argv


def classify(name, inp):
    """`dedicated`, `exec_read`, `snapshot` or `other`."""
    if name in DEDICATED:
        return "dedicated"
    if name != "Bash":
        return "other"
    argv = gate_argv(inp.get("command"))
    if argv is None:
        return "other"
    if argv[1] == "snapshot":
        return "snapshot"
    if argv[1] != "exec":
        return "other"
    pre = argv[:argv.index("--")] if "--" in argv else argv
    for i, w in enumerate(pre):
        if w == "--surface=읽기" or (w == "--surface" and i + 1 < len(pre) and pre[i + 1] == "읽기"):
            return "exec_read"
    return "other"


def call_tokens(call):
    """[(type, value)] of a call, `type` one of str / path / line."""
    inp, out = call["input"], []

    def add(t, v):
        if isinstance(v, str) and len(v) >= MIN_TOKEN and (t, v) not in out:
            out.append((t, v))

    name, cls = call["name"], call["cls"]
    if name == "Read":
        add("path", inp.get("file_path"))
        off = inp.get("offset")
        if isinstance(off, str) and off.isdigit():
            off = int(off)
        if isinstance(off, int) and not isinstance(off, bool) and off > 1:
            add("line", str(off))
    elif name == "Grep":
        add("str", inp.get("pattern"))
        add("str", inp.get("glob"))
        add("path", inp.get("path"))
    elif name == "Glob":
        add("str", inp.get("pattern"))
        add("path", inp.get("path"))
    elif cls == "exec_read":
        argv = gate_argv(inp.get("command")) or []
        rest = argv[argv.index("--") + 1:] if "--" in argv else []
        for w in rest[1:]:
            if not w.startswith("-"):
                add("path" if "/" in w else "str", w)
    return out


def find(tok, text, end=None):
    """Index of the token's first match in text[:end], or -1."""
    t, v = tok
    if end is None:
        end = len(text)
    if t == "line":
        m = re.compile(r"(^|[^0-9])" + re.escape(v) + r"[:-]", re.M).search(text, 0, end)
        return m.start() + len(m.group(1)) if m else -1
    hits = [text.find(v, 0, end)]
    if t == "path":
        elems = [e for e in v.split("/") if e]
        if len(elems) >= 2:
            hits.append(text.find("/".join(elems[-2:]), 0, end))
    hits = [h for h in hits if h >= 0]
    return min(hits) if hits else -1


def excerpt(tok, text, end=None):
    p = find(tok, text, end)
    if p < 0:
        return None
    return text[max(0, p - AROUND):p + len(tok[1]) + AROUND]


def parse_log(path):
    """The lead's requests, results and source text of one attempt log."""
    sid = None
    reqs = OrderedDict()   # message id -> request
    results = {}           # tool_use id -> (text, timestamp)
    parts, src_ords, src_ends, size = [], [], [], 0
    with open(path, encoding="utf-8", errors="replace") as f:
        for n, line in enumerate(f):
            try:
                o = json.loads(line)
            except ValueError:
                continue
            if not isinstance(o, dict):
                continue
            if sid is None and isinstance(o.get("session_id"), str):
                sid = o["session_id"]
            if o.get("parent_tool_use_id"):
                continue
            msg = o.get("message") if isinstance(o.get("message"), dict) else {}
            ts = timestamp(o)
            if o.get("type") == "assistant" and msg.get("id"):
                r = reqs.get(msg["id"])
                if r is None:
                    r = reqs[msg["id"]] = {"ord": n, "calls": [], "cache": None}
                usage = msg.get("usage") if isinstance(msg.get("usage"), dict) else {}
                if isinstance(usage.get("cache_read_input_tokens"), int):
                    r["cache"] = usage["cache_read_input_tokens"]
                for b in msg.get("content") or []:
                    if not isinstance(b, dict) or b.get("type") != "tool_use":
                        continue
                    inp = b.get("input") if isinstance(b.get("input"), dict) else {}
                    r["calls"].append({"id": b.get("id"), "name": b.get("name"), "input": inp,
                                       "ts": ts, "cls": classify(b.get("name"), inp)})
            elif o.get("type") == "user":
                cont = msg.get("content")
                texts = []
                if isinstance(cont, str):
                    texts.append(cont)
                for b in cont if isinstance(cont, list) else []:
                    if not isinstance(b, dict):
                        continue
                    if b.get("type") == "text":
                        texts.append(b.get("text") or "")
                    elif b.get("type") == "tool_result":
                        t = result_text(b.get("content"))
                        texts.append(t)
                        if b.get("tool_use_id") not in results:
                            results[b.get("tool_use_id")] = (t, ts)
                for t in texts:
                    parts.append(t)
                    size += len(t) + 1
                    src_ords.append(n)
                    src_ends.append(size)
    return {"sid": sid, "reqs": list(reqs.values()), "results": results,
            "src": "\n".join(parts) + ("\n" if parts else ""), "src_ords": src_ords,
            "src_ends": src_ends}


def read_only(req):
    return bool(req["calls"]) and all(c["cls"] != "other" for c in req["calls"])


def chains_of(log):
    """Every chain: its first request index, length, judged calls and depth."""
    reqs, results, out = log["reqs"], log["results"], []
    spans, start = [], None
    for i, r in enumerate(reqs + [None]):
        if r is not None and read_only(r):
            if start is None:
                start = i
            continue
        if start is not None and i - start >= CHAIN_MIN:
            spans.append((start, i - start))
        start = None
    for start, length in spans:
        k = bisect.bisect_left(log["src_ords"], reqs[start]["ord"])
        end = log["src_ends"][k - 1] if k else 0
        rtext = [None] + ["\n".join(results[c["id"]][0] for c in reqs[start + p]["calls"]
                                    if c["id"] in results) for p in range(length)]
        depth, judged = [None, 1], []
        for i in range(2, length + 1):
            deps_of_req = set()
            for ci, c in enumerate(reqs[start + i - 1]["calls"]):
                toks, evidence = call_tokens(c), []
                for tok in toks:
                    hits = [j for j in range(1, i) if find(tok, rtext[j]) >= 0]
                    if hits and find(tok, log["src"], end) < 0:
                        evidence += [{"token": tok[1], "request": j} for j in hits]
                deps_of_req.update(e["request"] for e in evidence)
                judged.append({"req": start + i - 1, "call": ci, "request_in_chain": i,
                               "tokens": toks, "evidence": evidence,
                               "verdict": DEPENDENT if evidence else INDEPENDENT})
            depth.append(1 + max([depth[j] for j in deps_of_req] or [0]))
        out.append({"start": start, "length": length, "judged": judged, "end": end,
                    "rtext": rtext, "max_depth": max(depth[1:])})
    return out


def empty():
    return dict((k, 0) for k in COUNTS)


def measure(log):
    """The per-log counts and the judged calls' (request, call) indices."""
    c = empty()
    reqs, results = log["reqs"], log["results"]
    untimed = set()
    c["lead_requests"] = len(reqs)
    for r in reqs:
        if len(r["calls"]) == 1:
            c["single"] += 1
        if read_only(r):
            c["read_only"] += 1
        for call in r["calls"]:
            if call["cls"] == "dedicated":
                c["dedicated_reads"] += 1
            elif call["cls"] == "snapshot":
                c["snapshot_calls"] += 1
            elif call["cls"] == "exec_read":
                c["exec_reads"] += 1
                rt = results.get(call["id"], (None, None))[1]
                if call["ts"] is None or rt is None:
                    untimed.add(id(call))
                else:
                    c["exec_wait_s"] += rt - call["ts"]
    chains = chains_of(log)
    judged = []
    for ch in chains:
        c["chains"] += 1
        c["chain_requests"] += ch["length"]
        c["reducible_requests"] += ch["length"] - ch["max_depth"]
        for r in reqs[ch["start"]:ch["start"] + ch["length"]]:
            if r["cache"] is not None:
                c["chain_cache_read_tokens"] += r["cache"]
            timed = []
            for call in r["calls"]:
                rt = results.get(call["id"], (None, None))[1]
                if call["ts"] is None or rt is None:
                    untimed.add(id(call))
                else:
                    timed.append((call["ts"], rt))
            if timed:
                c["chain_wall_s"] += max(t for _, t in timed) - min(t for t, _ in timed)
        for j in ch["judged"]:
            c["judged_calls"] += 1
            if j["verdict"] == INDEPENDENT:
                c["batchable_calls"] += 1
            judged.append((j["req"], j["call"]))
    c["untimed_calls"] = len(untimed)
    return c, judged


def add(acc, c):
    acc["stages"] += 1
    for key in COUNTS[1:]:
        acc[key] += c[key]


def pct(x, n):
    return 100.0 * x / n if n else None


def finish(a):
    k = OrderedDict()
    k["stages"] = a["stages"]
    k["lead_requests"] = a["lead_requests"]
    k["single_tool_pct"] = pct(a["single"], a["lead_requests"])
    k["read_only_pct"] = pct(a["read_only"], a["lead_requests"])
    k["chains"] = a["chains"]
    k["chain_requests"] = a["chain_requests"]
    k["chain_requests_pct"] = pct(a["chain_requests"], a["lead_requests"])
    k["judged_calls"] = a["judged_calls"]
    k["batchable_calls"] = a["batchable_calls"]
    k["batchable_call_pct"] = pct(a["batchable_calls"], a["judged_calls"])
    k["reducible_requests"] = a["reducible_requests"]
    k["reducible_pct"] = pct(a["reducible_requests"], a["chain_requests"])
    k["exec_reads"] = a["exec_reads"]
    k["dedicated_reads"] = a["dedicated_reads"]
    k["snapshot_calls"] = a["snapshot_calls"]
    k["exec_read_wait_h"] = a["exec_wait_s"] / 3600.0
    k["chain_wall_h"] = a["chain_wall_s"] / 3600.0
    k["untimed_calls"] = a["untimed_calls"]
    k["chain_cache_read_tokens"] = a["chain_cache_read_tokens"]
    k["reducible_cache_read_est"] = (float(a["reducible_requests"]) * a["chain_cache_read_tokens"]
                                     / a["chain_requests"] if a["chain_requests"] else None)
    return k


def fmt(v, digits=1, pct_=False):
    if v is None:
        return "-"
    s = ("{:,.%df}" % digits).format(v) if isinstance(v, float) else "{:,}".format(v)
    return s + ("%" if pct_ else "")


def cell(field, v):
    if field in PCT_FIELDS:
        return fmt(v, pct_=True)
    if field in HOUR_FIELDS:
        return fmt(v, digits=2)
    if field == "reducible_cache_read_est":
        return fmt(v, digits=0)
    return fmt(v)


def render_table(doc):
    sc = doc["scope"]
    head = "measure-read-chains: 런 루트 %s" % sc.get("runs_root")
    if sc.get("since"):
        head += " · 시작일 %s 이후" % sc["since"]
    if sc.get("until"):
        head += " · 시작일 %s 까지" % sc["until"]
    if sc.get("min_plugin_version"):
        head += " · 플러그인 %s 이상" % sc["min_plugin_version"]
    lines = [head, "적용 범위: 읽은 런 %d · ledger-path 나 log/ 가 없어 건너뜀 %d · 시작일로 건너뜀 %d · "
             "플러그인 판으로 건너뜀 %d · 시도 로그 %d · 미분류 %d" % (
                 sc["runs"], sc["skipped_incomplete"], sc["skipped_since"],
                 sc["skipped_version"], sc["attempt_logs"], sc["unclassified_logs"])]
    lines.append(" | ".join(["종류"] + FIELDS))
    lines.append(" | ".join(["---"] * (len(FIELDS) + 1)))
    body = list(doc["kinds"].items()) + [("미분류", doc["unclassified"]), ("합계", doc["total"])]
    for name, k in body:
        lines.append(" | ".join([name] + [cell(f, k.get(f)) for f in FIELDS]))
    return "\n".join(lines)


def j1(v):
    return json.dumps(v, ensure_ascii=False, sort_keys=True)


def render_samples(doc):
    samples = doc.get("samples")
    if not isinstance(samples, list):
        raise UsageError("the object holds no samples (run --json with --sample N --seed S)")
    lines = ["measure-read-chains: 표본 %d개 — 기계 판정과 그 근거는 싣지 않는다" % len(samples)]
    for n, s in enumerate(samples, 1):
        p = s["position"]
        lines.append("")
        lines.append("## %d. %s" % (n, s["id"]))
        lines.append("- 종류: %s" % (s.get("kind") or "미분류"))
        lines.append("- 위치: 로그의 %d 번째 요청에서 시작한 길이 %d 연쇄의 %d 번째 요청, 그 요청의 %d 번째 호출" % (
            p["chain_first_request"], p["chain_length"], p["request_in_chain"], p["call_in_request"]))
        lines.append("- 호출: %s %s" % (s["tool"], j1(s["input"])))
        for prev in s["previous"]:
            lines.append("- 앞 요청 %d:" % prev["request_in_chain"])
            for c in prev["calls"]:
                lines.append("  - %s %s" % (c["tool"], j1(c["input"])))
                lines.append("    결과 앞 %d자: %s" % (HEAD, j1(c["result_head"])))
        if not s["tokens"]:
            lines.append("- 토큰: %s" % NONE)
        for t in s["tokens"]:
            lines.append("- 토큰 %s %s:" % (t["type"], j1(t["token"])))
            lines.append("  - 연쇄 앞 원천 글: %s" % (t["before_chain"] if t["before_chain"] == NONE
                                                 else j1(t["before_chain"])))
            lines.append("  - 연쇄 결과: %s" % (t["chain_results"] if t["chain_results"] == NONE
                                             else j1(t["chain_results"])))
    return "\n".join(lines)


def build_samples(population, n, seed):
    """Draw N judged calls and describe each from a second read of its log."""
    picked = sorted(random.Random(seed).sample(range(len(population)), min(n, len(population))))
    by_log = OrderedDict()
    for i in picked:
        by_log.setdefault(population[i][2], []).append(population[i])
    out = []
    for path, refs in by_log.items():
        log = parse_log(path)
        reqs, results = log["reqs"], log["results"]
        index = {}
        for ch in chains_of(log):
            for j in ch["judged"]:
                index[(j["req"], j["call"])] = (ch, j)
        for run, logname, _, kind, ri, ci in refs:
            ch, j = index[(ri, ci)]
            call, i = reqs[ri]["calls"][ci], j["request_in_chain"]
            prev = []
            for pj in range(max(1, i - NEAREST), i):
                prev.append({"request_in_chain": pj, "calls": [
                    {"tool": c["name"], "input": c["input"],
                     "result_head": results.get(c["id"], ("", None))[0][:HEAD]}
                    for c in reqs[ch["start"] + pj - 1]["calls"]]})
            toks = []
            for tok in j["tokens"]:
                before = excerpt(tok, log["src"], ch["end"])
                found = None
                for pj in range(1, i):
                    found = excerpt(tok, ch["rtext"][pj])
                    if found is not None:
                        break
                toks.append({"type": tok[0], "token": tok[1],
                             "before_chain": NONE if before is None else before,
                             "chain_results": NONE if found is None else found})
            out.append(OrderedDict([
                ("id", "%s/%s/%s" % (run, logname[:-len(".json")], call["id"])), ("kind", kind),
                ("position", OrderedDict([("chain_first_request", ch["start"] + 1),
                                          ("chain_length", ch["length"]),
                                          ("request_in_chain", i), ("call_in_request", ci + 1)])),
                ("tool", call["name"]), ("input", call["input"]),
                ("verdict", j["verdict"]), ("evidence", j["evidence"]),
                ("previous", prev), ("tokens", toks)]))
    return out


def load_object(path):
    text = read_file(path)
    try:
        doc = json.loads(text) if text is not None else None
    except ValueError:
        doc = None
    if not isinstance(doc, dict):
        raise UsageError("not an object --json printed: %s" % path)
    return doc


def agreement(vpath, paths):
    objs = []
    machine = {}
    for p in paths:
        doc = load_object(p)
        if not isinstance(doc.get("samples"), list):
            raise UsageError("the object holds no samples: %s" % p)
        ids = []
        for s in doc["samples"]:
            machine[s["id"]] = s["verdict"]
            ids.append(s["id"])
        objs.append((p, ids))
    text = read_file(vpath)
    if text is None:
        raise UsageError("cannot read the verdict file: %s" % vpath)
    lead = {}
    for n, line in enumerate(text.splitlines(), 1):
        if not line.strip() or line.startswith("#"):
            continue
        parts = line.split("\t")
        if len(parts) != 2:
            raise UsageError("line %d: expected <id><TAB><verdict>" % n)
        sid, v = parts[0], parts[1].strip()
        if v not in VERDICTS:
            raise UsageError("line %d: unknown verdict %r" % (n, v))
        if sid not in machine:
            raise UsageError("line %d: no sample has the id %r" % (n, sid))
        if sid in lead:
            raise UsageError("line %d: the id %r appears twice" % (n, sid))
        lead[sid] = v
    missing = [i for i in machine if i not in lead]
    if missing:
        raise UsageError("no verdict for %d sample(s), first %r" % (len(missing), missing[0]))

    def row(name, ids):
        agree = sum(1 for i in ids if machine[i] == lead[i])
        mi = sum(1 for i in ids if machine[i] == INDEPENDENT and lead[i] == DEPENDENT)
        md = sum(1 for i in ids if machine[i] == DEPENDENT and lead[i] == INDEPENDENT)
        return "%s | %d | %d | %s | %d | %d" % (name, len(ids), agree,
                                               fmt(pct(agree, len(ids)), pct_=True), mi, md)

    lines = ["measure-read-chains: 일치율 — 판정 파일 %s" % vpath,
             "객체 | 표본 | 일치 | 일치율 | 기계 독립·리드 의존 | 기계 의존·리드 독립",
             " | ".join(["---"] * 6)]
    for p, ids in objs:
        lines.append(row(p, ids))
    lines.append(row("합계", [i for _, ids in objs for i in ids]))
    return "\n".join(lines)


def measure_runs(args):
    scope = OrderedDict([
        ("runs_root", args.runs_root),
        ("since", args.since.isoformat() if args.since else None),
        ("until", args.until.isoformat() if args.until else None),
        ("min_plugin_version", ".".join(map(str, args.min_plugin_version))
         if args.min_plugin_version else None),
        ("runs", 0), ("skipped_incomplete", 0), ("skipped_since", 0),
        ("skipped_version", 0), ("attempt_logs", 0), ("unclassified_logs", 0)])
    accs = OrderedDict((k, empty()) for k in KINDS)
    unclassified = empty()
    population = []
    for name in sorted(os.listdir(args.runs_root)):
        run = os.path.join(args.runs_root, name)
        if not os.path.isdir(run):
            continue
        logdir = os.path.join(run, "log")
        if not os.path.isfile(os.path.join(run, "ledger-path")) or not os.path.isdir(logdir):
            scope["skipped_incomplete"] += 1
            continue
        if args.since is not None or args.until is not None:
            d = run_date(run)
            if d is None or (args.since and d < args.since) or (args.until and d > args.until):
                scope["skipped_since"] += 1
                continue
        if args.min_plugin_version is not None:
            v = plugin_version(run)
            if v is None or v < args.min_plugin_version:
                scope["skipped_version"] += 1
                continue
        scope["runs"] += 1
        rows = read_ledger((read_file(os.path.join(run, "ledger-path")) or "").strip())
        for logname in sorted(os.listdir(logdir)):
            m = LOG_RE.match(logname)
            if not m:
                continue
            scope["attempt_logs"] += 1
            path = os.path.join(logdir, logname)
            log = parse_log(path)
            c, judged = measure(log)
            kind = kind_of(rows, log["sid"], m.group(1), m.group(2)) if log["sid"] else None
            if kind is None:
                scope["unclassified_logs"] += 1
                add(unclassified, c)
            else:
                add(accs.setdefault(kind, empty()), c)
            if args.sample is not None:
                population += [(name, logname, path, kind, ri, ci) for ri, ci in judged]

    total = empty()
    for acc in accs.values():
        for key in total:
            total[key] += acc[key]
    doc = OrderedDict([("scope", scope),
                       ("kinds", OrderedDict((k, finish(a)) for k, a in accs.items())),
                       ("unclassified", finish(unclassified)), ("total", finish(total))])
    if args.sample is not None:
        doc["samples"] = build_samples(population, args.sample, args.seed)
    return doc


def main(argv=None):
    ap = argparse.ArgumentParser(prog="measure-read-chains.py", allow_abbrev=False,
                                 description="Measure batchable read-only chains of unattended stage leads.")
    ap.add_argument("--runs-root")
    ap.add_argument("--since", type=date_arg)
    ap.add_argument("--until", type=date_arg)
    ap.add_argument("--min-plugin-version", type=version_arg)
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--sample", type=count_arg)
    ap.add_argument("--seed", type=int)
    ap.add_argument("--render", metavar="FILE")
    ap.add_argument("--samples", action="store_true")
    ap.add_argument("--agreement", nargs="+", metavar="FILE")
    args = ap.parse_args(argv)

    measuring = (args.runs_root is not None or args.since is not None or args.until is not None
                 or args.min_plugin_version is not None or args.json or args.sample is not None
                 or args.seed is not None)
    modes = [m for m in (args.runs_root is not None, args.render is not None,
                         args.agreement is not None) if m]
    if len(modes) != 1:
        ap.error("give exactly one of --runs-root, --render, --agreement")
    if args.samples and args.render is None:
        ap.error("--samples needs --render")
    if args.render is not None or args.agreement is not None:
        if measuring:
            ap.error("--render and --agreement take no measuring option")
    if args.sample is not None and not args.json:
        ap.error("--sample needs --json")
    if args.sample is not None and args.seed is None:
        ap.error("--sample needs --seed")
    if args.seed is not None and args.sample is None:
        ap.error("--seed needs --sample")
    if args.agreement is not None and len(args.agreement) < 2:
        ap.error("--agreement needs VERDICTS and at least one FILE")

    try:
        if args.render is not None:
            doc = load_object(args.render)
            print(render_samples(doc) if args.samples else render_table(doc))
            return 0
        if args.agreement is not None:
            print(agreement(args.agreement[0], args.agreement[1:]))
            return 0
    except (UsageError, KeyError, TypeError) as e:
        sys.stderr.write("measure-read-chains.py: error: %s\n" % e)
        return 2

    if not os.path.isdir(args.runs_root):
        ap.error("not a directory: %s" % args.runs_root)
    doc = measure_runs(args)
    print(json.dumps(doc, ensure_ascii=False, indent=2) if args.json else render_table(doc))
    return 0 if doc["scope"]["runs"] else 1


if __name__ == "__main__":
    sys.exit(main())
