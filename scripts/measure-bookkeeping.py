#!/usr/bin/env python3
"""Measure how much of an unattended stage lead's work is bookkeeping gate execs.

    measure-bookkeeping.py --runs-root DIR [--since YYYY-MM-DD]
                           [--min-plugin-version X.Y.Z] [--json]

This is NOT a gate. Nothing here passes or fails a change; the output is a
baseline a person compares before and after a change to how stages read their
pipeline values and copy their design document. `make test` runs this script
against synthetic fixtures only, never against real run history.

What it reads, under `--runs-root` (REQUIRED, no default pointing at a real
home directory — a default would let the fixture test pass on a machine that
happens to hold run history):

  run directory    every directory directly under the root that holds both a
                   `ledger-path` file and a `log/` directory; any other entry
                   is skipped and counted. `started-at` (epoch seconds) gives
                   the run's UTC date for `--since`; a run without a readable
                   one is skipped by `--since`. `plugin/cc-cmds/.claude-plugin/
                   plugin.json` gives the plugin version for
                   `--min-plugin-version`; a run without one is skipped by it.
  attempt log      `log/<stage>#<attempt>.json`, the stage session's stream
                   (one JSON object per line). Routing-shift logs
                   (`shift-<n>.json`) are not stage attempts and are not read.
  run ledger       the file `ledger-path` names. Its `- `stage-result`` rows
                   give each `세션 id` its `종류`. A log is joined to a row by
                   the `session_id` its stream carries; when one session id has
                   rows of several kinds, the row whose `스테이지` and `실행
                   버전` match the log's name decides. A log with no row is
                   counted under `unclassified`.

What counts as bookkeeping: a `Bash` tool call whose command is the gate's
`exec` (first word ending in `/orchestrator/gate.sh`, second word `exec`) and
whose argv0 after ` -- ` has one of the basenames shasum, printenv, cp, date,
rm, openssl, mktemp, mv, lockf, wc, cc-team-witness-publish.sh,
cc-team-nonce.sh, or is `doc-tidy.py` with the subcommand `checkout` or
`publish`.

Inner command key: every gate `exec` with an argv0 after ` -- ` gets a key,
bookkeeping or not — the argv0's basename, or `doc-tidy.py <subcommand>` for
the doc-tidy helper. The breakdown counts each key per actor, so a command
outside the bookkeeping set (`mkdir`, `git`) shows up there without entering
any bookkeeping figure.

Lead and member: a stream record with a `parent_tool_use_id` belongs to an
agent the lead spawned (a member); one without it is the lead's. Only the
lead's calls enter the per-stage and per-request figures; the members'
bookkeeping execs are printed in their own column, because a member's calls
are not lead requests and the per-stage figure is the lead's turn cost.

Figures per kind:

  stages                 attempt logs joined to the kind
  lead_requests          distinct assistant message ids of the lead
  bookkeeping_only       lead requests that made at least one tool call, all
                         of them bookkeeping execs
  bookkeeping_only_pct   bookkeeping_only / lead_requests, in percent
  bookkeeping_execs      the lead's bookkeeping execs
  execs_per_stage        bookkeeping_execs / stages
  exec_ratio_pct         bookkeeping_execs / lead_requests, in percent (the
                         definition the ticket's figures used)
  member_bookkeeping     the members' bookkeeping execs
  digest_refusals        the lead's gate calls whose result is exit code 4
                         and whose output holds `stale snapshot digest`
                         (an auxiliary column)
  member_digest_refusals the same refusal on the members' gate calls
  by_command             inner command key -> bookkeeping (whether the key is
                         in the bookkeeping set), lead, member (gate execs of
                         that key per actor), lead_per_stage, member_per_stage;
                         ordered by lead + member, highest first, then by key

The table prints the per-kind figures first, then the breakdown, one row per
kind and inner command key; a kind with no stage prints no breakdown row.

A value that cannot be computed is null in JSON and `-` in the table.

Exit codes: 0 when at least one run was read, 1 when none was (the table or
object is still printed), 2 for a usage error. It writes to stdout only and
creates no file.
"""
import sys

sys.dont_write_bytecode = True

import argparse  # noqa: E402
import datetime  # noqa: E402
import json  # noqa: E402
import os  # noqa: E402
import re  # noqa: E402
import shlex  # noqa: E402
from collections import OrderedDict  # noqa: E402

KINDS = ["design", "audit", "reconverge", "implement", "review", "lead-fix"]
BOOKKEEPING = {"shasum", "printenv", "cp", "date", "rm", "openssl", "mktemp", "mv", "lockf", "wc",
               "cc-team-witness-publish.sh", "cc-team-nonce.sh"}
DOC_TIDY_VERBS = {"checkout", "publish"}
STALE = "stale snapshot digest"
ROW_PREFIX = "- `stage-result`"
LOG_RE = re.compile(r"^(.+)#(\d+)\.json$")


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


def exec_key(command):
    """(key, bookkeeping, gate call) of COMMAND: the inner command key of a
    gate exec with an argv0 after ` -- ` (None otherwise), whether that key is
    bookkeeping, and whether COMMAND calls the gate at all."""
    if not isinstance(command, str):
        return None, False, False
    try:
        argv = shlex.split(command, posix=True)
    except ValueError:
        return None, False, False
    if len(argv) < 2 or not argv[0].endswith("/orchestrator/gate.sh"):
        return None, False, False
    if argv[1] != "exec" or "--" not in argv:
        return None, False, True
    rest = argv[argv.index("--") + 1:]
    if not rest:
        return None, False, True
    base = os.path.basename(rest[0])
    if base == "doc-tidy.py":
        sub = rest[1] if len(rest) > 1 else None
        return ("doc-tidy.py %s" % sub if sub else base), sub in DOC_TIDY_VERBS, True
    return base, base in BOOKKEEPING, True


def is_bookkeeping(command):
    """(bookkeeping, gate call): whether COMMAND is a gate exec whose argv0
    after ` -- ` is bookkeeping, and whether it calls the gate at all."""
    _, bk, gate = exec_key(command)
    return bk, gate


def result_text(content):
    if isinstance(content, str):
        return content
    out = []
    for b in content or []:
        if isinstance(b, dict) and b.get("type") == "text":
            out.append(b.get("text") or "")
    return "\n".join(out)


def read_log(path):
    """Session id and the lead/member counts of one attempt log."""
    sid = None
    reqs = OrderedDict()    # lead message id -> [bookkeeping flag per tool call]
    gate_calls = set()      # lead tool_use ids that called the gate
    member_gate_calls = set()
    c = {"bookkeeping_execs": 0, "member_bookkeeping": 0, "digest_refusals": 0,
         "member_digest_refusals": 0, "by_command": {}}
    results = []
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            try:
                o = json.loads(line)
            except ValueError:
                continue
            if not isinstance(o, dict):
                continue
            if sid is None and isinstance(o.get("session_id"), str):
                sid = o["session_id"]
            msg = o.get("message") if isinstance(o.get("message"), dict) else {}
            lead = not o.get("parent_tool_use_id")
            if o.get("type") == "assistant" and msg.get("id"):
                calls = reqs.setdefault(msg["id"], []) if lead else None
                for b in msg.get("content") or []:
                    if not isinstance(b, dict) or b.get("type") != "tool_use":
                        continue
                    key, bk, gate = None, False, False
                    if b.get("name") == "Bash":
                        inp = b.get("input") if isinstance(b.get("input"), dict) else {}
                        key, bk, gate = exec_key(inp.get("command"))
                    if key is not None:
                        e = c["by_command"].setdefault(key, {"bookkeeping": bk, "lead": 0, "member": 0})
                        e["lead" if lead else "member"] += 1
                    if lead:
                        calls.append(bk)
                        if bk:
                            c["bookkeeping_execs"] += 1
                        if gate:
                            gate_calls.add(b.get("id"))
                    else:
                        if bk:
                            c["member_bookkeeping"] += 1
                        if gate:
                            member_gate_calls.add(b.get("id"))
            elif o.get("type") == "user":
                cont = msg.get("content")
                for b in cont if isinstance(cont, list) else []:
                    if isinstance(b, dict) and b.get("type") == "tool_result":
                        results.append((b.get("tool_use_id"), result_text(b.get("content"))))
    for tid, text in results:
        if not (text.startswith("Exit code 4") and STALE in text):
            continue
        if tid in gate_calls:
            c["digest_refusals"] += 1
        elif tid in member_gate_calls:
            c["member_digest_refusals"] += 1
    c["lead_requests"] = len(reqs)
    c["bookkeeping_only"] = sum(1 for calls in reqs.values() if calls and all(calls))
    return sid, c


def pct(x, n):
    return 100.0 * x / n if n else None


def per(x, n):
    return float(x) / n if n else None


def finish(acc):
    k = OrderedDict()
    k["stages"] = acc["stages"]
    k["lead_requests"] = acc["lead_requests"]
    k["bookkeeping_only"] = acc["bookkeeping_only"]
    k["bookkeeping_only_pct"] = pct(acc["bookkeeping_only"], acc["lead_requests"])
    k["bookkeeping_execs"] = acc["bookkeeping_execs"]
    k["execs_per_stage"] = per(acc["bookkeeping_execs"], acc["stages"])
    k["exec_ratio_pct"] = pct(acc["bookkeeping_execs"], acc["lead_requests"])
    k["member_bookkeeping"] = acc["member_bookkeeping"]
    k["digest_refusals"] = acc["digest_refusals"]
    k["member_digest_refusals"] = acc["member_digest_refusals"]
    by = OrderedDict()
    for key, e in sorted(acc["by_command"].items(), key=lambda kv: (-(kv[1]["lead"] + kv[1]["member"]), kv[0])):
        by[key] = OrderedDict([("bookkeeping", e["bookkeeping"]), ("lead", e["lead"]), ("member", e["member"]),
                               ("lead_per_stage", per(e["lead"], acc["stages"])),
                               ("member_per_stage", per(e["member"], acc["stages"]))])
    k["by_command"] = by
    return k


COUNTS = ("lead_requests", "bookkeeping_only", "bookkeeping_execs",
          "member_bookkeeping", "digest_refusals", "member_digest_refusals")


def empty():
    acc = {key: 0 for key in COUNTS}
    acc["stages"] = 0
    acc["by_command"] = {}
    return acc


def merge(acc, c):
    for key in COUNTS:
        acc[key] += c[key]
    for key, e in c["by_command"].items():
        t = acc["by_command"].setdefault(key, {"bookkeeping": e["bookkeeping"], "lead": 0, "member": 0})
        t["lead"] += e["lead"]
        t["member"] += e["member"]


def add(acc, c):
    acc["stages"] += 1
    merge(acc, c)


def fmt(v, digits=1, pct_=False):
    if v is None:
        return "-"
    s = ("{:,.%df}" % digits).format(v) if isinstance(v, float) else "{:,}".format(v)
    return s + ("%" if pct_ else "")


def main(argv=None):
    ap = argparse.ArgumentParser(prog="measure-bookkeeping.py", allow_abbrev=False,
                                 description="Measure bookkeeping gate execs of unattended stage leads.")
    ap.add_argument("--runs-root", required=True)
    ap.add_argument("--since", type=date_arg)
    ap.add_argument("--min-plugin-version", type=version_arg)
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args(argv)
    if not os.path.isdir(args.runs_root):
        ap.error("not a directory: %s" % args.runs_root)

    scope = OrderedDict([("runs", 0), ("skipped_incomplete", 0), ("skipped_since", 0),
                         ("skipped_version", 0), ("attempt_logs", 0), ("unclassified_logs", 0)])
    accs = OrderedDict((k, empty()) for k in KINDS)
    unclassified = empty()
    for name in sorted(os.listdir(args.runs_root)):
        run = os.path.join(args.runs_root, name)
        if not os.path.isdir(run):
            continue
        logdir = os.path.join(run, "log")
        if not os.path.isfile(os.path.join(run, "ledger-path")) or not os.path.isdir(logdir):
            scope["skipped_incomplete"] += 1
            continue
        if args.since is not None:
            d = run_date(run)
            if d is None or d < args.since:
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
            sid, c = read_log(os.path.join(logdir, logname))
            kind = kind_of(rows, sid, m.group(1), m.group(2)) if sid else None
            if kind is None:
                scope["unclassified_logs"] += 1
                add(unclassified, c)
            else:
                add(accs.setdefault(kind, empty()), c)

    total = empty()
    for acc in accs.values():
        total["stages"] += acc["stages"]
        merge(total, acc)
    kinds = OrderedDict((k, finish(a)) for k, a in accs.items())

    if args.json:
        doc = OrderedDict([("scope", scope), ("kinds", kinds),
                           ("unclassified", finish(unclassified)), ("total", finish(total))])
        print(json.dumps(doc, ensure_ascii=False, indent=2))
    else:
        lines = ["measure-bookkeeping: 런 루트 %s%s%s" % (
            args.runs_root,
            " · 시작일 %s 이후" % args.since.isoformat() if args.since else "",
            " · 플러그인 %s 이상" % ".".join(map(str, args.min_plugin_version))
            if args.min_plugin_version else "")]
        lines.append("적용 범위: 읽은 런 %d · ledger-path 나 log/ 가 없어 건너뜀 %d · 시작일로 건너뜀 %d · 플러그인 판으로 건너뜀 %d · 시도 로그 %d · 미분류 %d" % tuple(scope.values()))
        lines.append("리드만 셈 (parent_tool_use_id 없는 기록). 구성원의 부기 exec 는 따로 적고 스테이지당 수에 넣지 않는다.")
        lines.append("종류 | 스테이지 | 리드 요청 | 부기 전용 요청 | 부기 전용 비율 | 부기 exec | 스테이지당 부기 exec | exec 기준 비율 | 구성원 부기 exec | 다이제스트 거부(보조) | 구성원 다이제스트 거부")
        body = list(kinds.items()) + [("미분류", finish(unclassified)), ("합계", finish(total))]
        for name, k in body:
            lines.append("%s | %d | %d | %d | %s | %d | %s | %s | %d | %d | %d" % (
                name, k["stages"], k["lead_requests"], k["bookkeeping_only"],
                fmt(k["bookkeeping_only_pct"], pct_=True), k["bookkeeping_execs"],
                fmt(k["execs_per_stage"]), fmt(k["exec_ratio_pct"], pct_=True),
                k["member_bookkeeping"], k["digest_refusals"], k["member_digest_refusals"]))
        lines.append("")
        lines.append("안쪽 명령별 분해 (게이트 exec 의 -- 뒤 명령, 부기 집합 밖의 명령도 포함):")
        lines.append("종류 | 안쪽 명령 | 부기 | 리드 | 구성원 | 리드 스테이지당 | 구성원 스테이지당")
        for name, k in body:
            if not k["stages"]:
                continue
            for key, e in k["by_command"].items():
                lines.append("%s | %s | %s | %d | %d | %s | %s" % (
                    name, key, "예" if e["bookkeeping"] else "아니오", e["lead"], e["member"],
                    fmt(e["lead_per_stage"]), fmt(e["member_per_stage"])))
        print("\n".join(lines))
    return 0 if scope["runs"] else 1


if __name__ == "__main__":
    sys.exit(main())
