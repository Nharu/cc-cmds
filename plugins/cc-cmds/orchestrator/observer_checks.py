"""observer_checks — the resident observer's `checks` job.

Every adopted run's CI poller used to be its own `checks.sh` loop, asking `gh`
two or three questions per PR every minute. This module asks GitHub about every
adopted run's PRs in one GraphQL query a minute (a few when there are more PRs
than one query holds), writes each run's share of the answer to
`<RUN_DIR>/checks.snapshot`, and runs the run's own pinned `checks.sh --once
--from-snapshot` only where that share moved. The judgment — transitions, the
rerun round, the `필수 집합` deferral, the line format — stays in the pinned
script, so a run judges with its own version's code whatever version this
observer is.

WHAT IT ASKS COMES FROM THE RUN. `checks.sh --spec` prints the segments a pass
would ask about (`<slug>\t<segment>\t<head branch>`), and it is asked again only
when the run's ledger or manifest moved.

THE FENCE. The one program this module runs besides the run's pinned scripts is
`gh api graphql`, and every query it builds starts with `query` and carries no
`mutation`. It writes no ledger, halt record, approval sidecar, grant or run
record, and it raises no notification. `scripts/test-observer-checks.sh` holds
the fence.

WHAT ONE QUERY CANNOT COVER IS HANDED BACK. A PR whose check contexts run past
one page is not something this snapshot can describe, so the run's job is let
go, `checks.fallback` says why, and the run's own `checks.sh` is started on the
arguments it was adopted with; it reads that file and runs its own loop, the
path a run without the protocol mark takes.

python3 3.9, standard library only.
"""

import json
import os
import subprocess
import threading
import time

JOB = "checks"
PID_FILE = "checks.pid"

SNAPSHOT = "checks.snapshot"
FALLBACK = "checks.fallback"
SNAPSHOT_HEAD = "checks-snapshot 1"
GH_TIMEOUT_S = 30.0
PRS_PER_QUERY = 50
CONTEXTS_PER_PR = 100
DEFAULT_INTERVAL = 60.0
# The same knobs `checks.sh` and `liveness.sh` read, with the same defaults.
DEFAULT_QUIET_EVERY = 4
DEFAULT_IDLE_EXIT_S = 86400.0

_mu = threading.Lock()
_runs = {}


class _State:
    def __init__(self, now):
        self.adopted = now
        self.changed = True
        self.spec = None          # [(slug, seg, branch)]
        self.spec_sig = None
        self.last_cycle = None
        self.last_query = None
        self.since_poll = 0
        self.quiet = False
        self.snap = None          # the bytes last written
        self.judged = None        # when the pinned pass last ran
        self.numbers = {}         # (slug, branch) -> PR number the list gave
        self.gone = False


def _env_num(name, default):
    try:
        v = float(os.environ.get(name, ""))
        return v if v > 0 else default
    except ValueError:
        return default


def _arg(args, name, default=None):
    for i, a in enumerate(args):
        if a == name and i + 1 < len(args):
            return args[i + 1]
    return default


def _file_sig(path):
    if not path:
        return None
    try:
        st = os.stat(path)
    except OSError:
        return None
    return (st.st_mtime_ns, st.st_size)


def _clean(v):
    if v is None:
        return ""
    s = str(v)
    for c in ("\t", "\n", "\r"):
        s = s.replace(c, " ")
    return s


def _write_atomic(path, data):
    tmp = "%s.tmp.%d" % (path, os.getpid())
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        os.write(fd, data.encode("utf-8"))
    finally:
        os.close(fd)
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)


# ---------------------------------------------------------------------------
# The module contract
# ---------------------------------------------------------------------------

def probes(run):
    # The ledger, `done` and the pid records are the observer's own probes.
    return []


def tick(ctx, run, changed, now):
    # An input of the run moved (or the job was just adopted): the next pass
    # judges the run even when its share of the answer did not move, because the
    # ledger is half of what the pinned script reads.
    with _mu:
        st = _runs.get(run)
        if st is not None:
            st.changed = True
    return None


def batch(ctx, runs, now):
    with _mu:
        for rd in list(_runs):
            if rd not in runs:
                del _runs[rd]
        for rd in runs:
            if rd not in _runs:
                _runs[rd] = _State(now)
        states = {rd: _runs[rd] for rd in runs}

    due = []
    for rd, st in states.items():
        if st.gone:
            continue
        args = ctx.args(rd)
        if not _refresh_spec(ctx, rd, st, args):
            continue
        if not _cycle_due(st, args, now):
            continue
        due.append((rd, st, args))
    if not due:
        return

    entries = []
    for rd, st, args in due:
        for slug, _seg, branch in st.spec:
            key = (slug, branch)
            if key not in entries and "/" in slug:
                entries.append(key)
    known = {}
    for rd, st, args in due:
        known.update(st.numbers)

    answers = _ask(ctx, entries, known)

    for rd, st, args in due:
        _finish_run(ctx, rd, st, args, answers, now)


# ---------------------------------------------------------------------------
# Spec and cadence
# ---------------------------------------------------------------------------

def _refresh_spec(ctx, rd, st, args):
    """The run's query spec, asked again only when its ledger or manifest moved."""
    sig = (_file_sig(_arg(args, "--ledger")), _file_sig(_arg(args, "--manifest")))
    if st.spec is not None and sig == st.spec_sig:
        return True
    rc, out = ctx.call(rd, ["checks.sh", "--spec"] + _base_args(rd, args))
    if rc != 0:
        return False
    spec = []
    for line in out.split("\n"):
        parts = line.split("\t")
        if len(parts) == 3 and all(parts):
            spec.append((parts[0], parts[1], parts[2]))
    st.spec = spec
    st.spec_sig = sig
    return True


def _interval(args):
    try:
        v = float(_arg(args, "--interval", DEFAULT_INTERVAL))
        return v if v > 0 else DEFAULT_INTERVAL
    except (TypeError, ValueError):
        return DEFAULT_INTERVAL


def _cycle_due(st, args, now):
    """The loop's cadence: a cycle every `--interval`, and on a run the last pass
    judged quiet only every `CC_QUIET_PASS_EVERY` cycles unless the ledger moved
    since the last question."""
    iv = _interval(args)
    if st.last_cycle is not None and now - st.last_cycle < iv:
        return False
    first = st.last_cycle is None
    st.last_cycle = now
    if not first and st.quiet:
        every = int(_env_num("CC_QUIET_PASS_EVERY", DEFAULT_QUIET_EVERY))
        led = _file_sig(_arg(args, "--ledger"))
        moved = led is not None and st.last_query is not None and led[0] > int(st.last_query * 1e9)
        if st.since_poll < every - 1 and not moved:
            st.since_poll += 1
            return False
    st.since_poll = 0
    st.last_query = now
    return True


def _base_args(rd, args):
    out = ["--run-dir", rd]
    for name in ("--ledger", "--manifest"):
        v = _arg(args, name)
        if v is not None:
            out += [name, v]
    return out


# ---------------------------------------------------------------------------
# The question
# ---------------------------------------------------------------------------

def _gql_str(s):
    # A JSON string is a GraphQL string. A name that happens to spell the word
    # the fence refuses keeps its value with the first letter escaped, so the
    # query text still never carries it.
    return json.dumps(s).replace("mutation", "\\u006dutation")


def _repo(slug):
    owner, _, name = slug.partition("/")
    return "repository(owner:%s,name:%s)" % (_gql_str(owner), _gql_str(name))


def _list_field(slug, branch):
    return ("%s{pullRequests(headRefName:%s,states:OPEN,first:1,"
            "orderBy:{field:CREATED_AT,direction:DESC}){nodes{number headRefOid}}}"
            % (_repo(slug), _gql_str(branch)))


def _rollup_field(slug, number):
    n = int(number)
    return ("%s{pullRequest(number:%d){headRefOid commits(last:1){nodes{commit{"
            "statusCheckRollup{contexts(first:%d){pageInfo{hasNextPage} nodes{__typename "
            "...on CheckRun{name status conclusion startedAt isRequired(pullRequestNumber:%d) "
            "checkSuite{workflowRun{event workflow{name}}}} "
            "...on StatusContext{context state createdAt isRequired(pullRequestNumber:%d)}"
            "}}}}}}}}" % (_repo(slug), n, CONTEXTS_PER_PR, n, n))


def build_query(fields):
    """`fields` is [(alias, field)]; the query is read-only by construction."""
    body = " ".join("%s:%s" % (a, f) for a, f in fields)
    return "query{%s}" % body


def _gh_graphql(ctx, query):
    """(ok, data) — `data` is the response's `data` object, aliases may be None."""
    if not query.startswith("query") or "mutation" in query:
        return False, None
    try:
        p = subprocess.run(["gh", "api", "graphql", "-f", "query=" + query],
                           stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                           stderr=subprocess.PIPE, timeout=GH_TIMEOUT_S, cwd="/",
                           env={k: v for k, v in os.environ.items()
                                if not k.startswith("CC_PIPELINE_") and k != "CC_OBSERVER_PID"})
    except (OSError, subprocess.SubprocessError) as e:
        ctx.log("gh api graphql 실패: %s" % e)
        return False, None
    try:
        doc = json.loads(p.stdout.decode("utf-8", "replace"))
    except ValueError:
        ctx.log("gh api graphql 응답이 JSON 이 아니다 (rc=%d)" % p.returncode)
        return False, None
    data = doc.get("data") if isinstance(doc, dict) else None
    if not isinstance(data, dict):
        ctx.log("gh api graphql 응답에 data 가 없다 (rc=%d)" % p.returncode)
        return False, None
    return True, data


def _chunks(seq, n):
    for i in range(0, len(seq), n):
        yield seq[i:i + n]


def _ask(ctx, entries, known):
    """{(slug, branch): answer}. An answer is a dict with `state` one of
    `ok` / `none` / `fail` / `overflow`, and for `ok` the `number`, `sha` and
    `contexts`. A pair missing from the result was in a query that broke."""
    answers = {}
    rollups = {}
    for part in _chunks(entries, PRS_PER_QUERY):
        fields = []
        for i, (slug, branch) in enumerate(part):
            fields.append(("l%d" % i, _list_field(slug, branch)))
            n = known.get((slug, branch))
            if n is not None:
                fields.append(("p%d" % i, _rollup_field(slug, n)))
        ok, data = _gh_graphql(ctx, build_query(fields))
        if not ok:
            continue
        for i, key in enumerate(part):
            answers[key] = _read_list(data.get("l%d" % i))
            n = known.get(key)
            if n is not None:
                rollups[(key, n)] = data.get("p%d" % i)

    # A number the list gave that the query did not already ask about: those PRs
    # alone, asked once more in the same cycle.
    again = []
    for key, a in answers.items():
        if a["state"] == "ok" and (key, a["number"]) not in rollups:
            again.append((key, a["number"]))
    for part in _chunks(again, PRS_PER_QUERY):
        fields = [("p%d" % i, _rollup_field(key[0], n)) for i, (key, n) in enumerate(part)]
        ok, data = _gh_graphql(ctx, build_query(fields))
        if not ok:
            for key, n in part:
                answers.pop(key, None)
            continue
        for i, (key, n) in enumerate(part):
            rollups[(key, n)] = data.get("p%d" % i)

    for key, a in list(answers.items()):
        if a["state"] != "ok":
            continue
        _read_rollup(a, rollups.get((key, a["number"])))
    return answers


def _read_list(node):
    try:
        nodes = node["pullRequests"]["nodes"]
    except (TypeError, KeyError):
        return {"state": "fail"}
    if not isinstance(nodes, list):
        return {"state": "fail"}
    if not nodes:
        return {"state": "none"}
    first = nodes[0] or {}
    n = first.get("number")
    if not isinstance(n, int):
        return {"state": "fail"}
    return {"state": "ok", "number": n, "sha": first.get("headRefOid") or ""}


def _read_rollup(a, node):
    try:
        pr = node["pullRequest"]
        if not isinstance(pr, dict):
            raise KeyError
    except (TypeError, KeyError):
        a["state"] = "fail"
        return
    contexts = []
    commits = ((pr.get("commits") or {}).get("nodes") or [])
    commit = (commits[0] or {}).get("commit") if commits else None
    rollup = (commit or {}).get("statusCheckRollup")
    if rollup:
        page = rollup.get("contexts") or {}
        if (page.get("pageInfo") or {}).get("hasNextPage"):
            a["state"] = "overflow"
            return
        for c in page.get("nodes") or []:
            if not isinstance(c, dict):
                continue
            req = "1" if c.get("isRequired") else "0"
            if c.get("__typename") == "StatusContext":
                contexts.append(("StatusContext", c.get("context"), "", "", "",
                                 c.get("state"), c.get("createdAt"), req))
            elif c.get("__typename") == "CheckRun":
                wr = ((c.get("checkSuite") or {}).get("workflowRun") or {})
                contexts.append(("CheckRun", c.get("name"), (wr.get("workflow") or {}).get("name"),
                                 wr.get("event"), c.get("status"), c.get("conclusion"),
                                 c.get("startedAt"), req))
    a["contexts"] = contexts


# ---------------------------------------------------------------------------
# One run's share
# ---------------------------------------------------------------------------

def snapshot_text(spec, answers):
    """The run's snapshot, or None when a pair's question broke (no snapshot and
    no judging call, as a poll whose `gh` call broke)."""
    lines = [SNAPSHOT_HEAD]
    seen = set()
    for slug, _seg, branch in spec:
        key = (slug, branch)
        if key in seen:
            continue
        seen.add(key)
        a = answers.get(key)
        if a is None:
            return None
        if a["state"] == "none":
            lines.append("pr\t%s\t%s\t없음\t" % (_clean(slug), _clean(branch)))
        elif a["state"] != "ok":
            lines.append("pr\t%s\t%s\t실패\t" % (_clean(slug), _clean(branch)))
        else:
            lines.append("pr\t%s\t%s\t%d\t%s" % (_clean(slug), _clean(branch), a["number"], _clean(a["sha"])))
            for c in a["contexts"]:
                lines.append("\t".join(["ctx", _clean(slug), _clean(branch)] + [_clean(v) for v in c]))
    return "\n".join(lines) + "\n"


def _finish_run(ctx, rd, st, args, answers, now):
    over = [k for k in {(s, b) for s, _g, b in st.spec} if (answers.get(k) or {}).get("state") == "overflow"]
    if over:
        _hand_back(ctx, rd, st, args, "컨텍스트가 한 페이지(%d개)를 넘는 PR: %s" % (
            CONTEXTS_PER_PR, ", ".join("%s@%s" % k for k in sorted(over))))
        return
    for slug, _seg, branch in st.spec:
        a = answers.get((slug, branch)) or {}
        if a.get("state") == "ok":
            st.numbers[(slug, branch)] = a["number"]
        elif a.get("state") == "none":
            st.numbers.pop((slug, branch), None)
    text = snapshot_text(st.spec, answers)
    if text is None:
        return
    path = os.path.join(rd, SNAPSHOT)
    try:
        _write_atomic(path, text)
    except OSError as e:
        ctx.log("스냅숏 기록 실패 %s: %s" % (rd, e))
        return
    with _mu:
        changed, st.changed = st.changed, False
    idle = _env_num("CC_RUN_IDLE_EXIT_SECONDS", DEFAULT_IDLE_EXIT_S)
    stale = st.judged is not None and now - st.judged >= idle
    if text == st.snap and not changed and st.judged is not None and not stale:
        return
    st.snap = text
    st.judged = now
    argv = (["checks.sh", "--once", "--from-snapshot", path] + _base_args(rd, args)
            + ["--interval", "%g" % _interval(args), "--started", "%d" % int(st.adopted)])
    rc, out = ctx.call(rd, argv)
    for line in out.split("\n"):
        if line.startswith("quiet="):
            st.quiet = line == "quiet=1"
    if rc == 3:
        st.gone = True
        ctx.drop(rd)
    elif rc != 0:
        # The pass did not finish: the next cycle judges again.
        with _mu:
            st.changed = True
        ctx.log("판정 호출 실패 %s rc=%s" % (rd, rc))


def _hand_back(ctx, rd, st, args, reason):
    st.gone = True
    try:
        _write_atomic(os.path.join(rd, FALLBACK), reason + "\n")
    except OSError as e:
        ctx.log("checks.fallback 기록 실패 %s: %s" % (rd, e))
    ctx.drop(rd)
    script = os.path.join(rd, "plugin", "cc-cmds", "orchestrator", "checks.sh")
    env = {k: v for k, v in os.environ.items()
           if not k.startswith("CC_PIPELINE_") and k != "CC_OBSERVER_PID"}
    try:
        logf = os.open(os.path.join(rd, "checks.log"), os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
    except OSError:
        logf = subprocess.DEVNULL
    try:
        p = subprocess.Popen(["bash", script] + list(args), stdin=subprocess.DEVNULL,
                             stdout=logf, stderr=logf, cwd="/", env=env,
                             start_new_session=True, close_fds=True)
    except OSError as e:
        ctx.log("기존 경로 기동 실패 %s: %s" % (rd, e))
        return
    finally:
        if isinstance(logf, int) and logf >= 0:
            os.close(logf)
    threading.Thread(target=p.wait, daemon=True).start()
    ctx.log("기존 경로로 넘김 %s — %s" % (rd, reason))
